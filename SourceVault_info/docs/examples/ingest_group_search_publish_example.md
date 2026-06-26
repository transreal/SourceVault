# SourceVault — ingest → グループ化 → 補足知識 → 検索 → ClaudeEval → Web 公開 実行例

このドキュメントは、**PDF / Web ページを取り込み（ingest）、グループ化して release context と補足知識を付け、検索し、ノートブック（ClaudeEval）から問い合わせ、最後に Web で公開する**までの一連の流れを、実際に動くコードで示します。

サービス起動の詳細は [servicemanager_example.md](servicemanager_example.md) を参照してください。本書はその前段（取り込み〜グループ化〜検索）に重点を置きます。

## 全体像

```
PDF / Web ページ / arXiv 論文
   │ pdfIndex / pdfIndexDirectory / pdfIndexURL   ← コレクションに取り込む
   ▼
コレクション(collection)
   │ + ReleaseContext (公開ポリシー)
   │ + PDFIndexProfile (検索プロファイル)
   │ + MigrationRule (legacy → release メタ付与)
   │ + CuratedKnowledge (凡例・補正・補足)
   ▼
グループ (= 検索単位)
   │ SourceVaultSources / SourceVaultSummaries     ← provider 横断一覧・検索
   │ SourceVaultArXiv                              ← arXiv 専用ビュー
   │ SourceVaultSearch (gate 付き検索)             ← 関数で検索
   │ ClaudeQuery + 検索                            ← ClaudeEval プロンプトで検索
   │ PDFGroupSearchProfile + StartHTTPProxy        ← Web 公開
   ▼
回答 / 検索結果 / Web UI
```

「グループ」は **1 コレクション ＋ release context ＋ profile ＋ migration rule ＋ 補足知識** の束です。複数グループを同じエンジンで扱えます。

---

## 0. ロード

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]];   (* core/searchindex/servicemanager/objectview を自動ロード *)
  Get[FileNameJoin[{$packageDirectory, "PDFIndex.wl"}]];       (* 検索バックエンド *)
  Get[FileNameJoin[{$packageDirectory, "NBAccess.wl"}]]];      (* LLM トークン *)
```

> **自動ロード**: `Get["SourceVault.wl"]` 単体で `SourceVault_core.wl` / `SourceVault_searchindex.wl` / `SourceVault_servicemanager.wl` / `SourceVault_mcp.wl` / **`SourceVault_objectview.wl`** が自動でロードされます。`$CharacterEncoding` を UTF-8 に固定することで、日本語リテラルが正しくロードされます。

### `$SourceVaultDefaultNotebookFolder`（新規）

```mathematica
$SourceVaultDefaultNotebookFolder::usage
(* => "the default folder for SourceVault notebooks." *)
```

`$SourceVaultDefaultNotebookFolder` は SourceVault がノートブックを保存・参照する際のデフォルトフォルダーです。既定値は `Automatic` で、実行時に `Global`$onWork` を参照し、未設定なら `$packageDirectory` にフォールバックします。`PresentationListener` の保存先としても使用されます。

```mathematica
(* 任意のフォルダーを明示的に設定する場合 *)
$SourceVaultDefaultNotebookFolder = "F:\\docs\\vaults\\main";
```

---

## 1. PDF / Web ページの ingest（コレクションに取り込む）

コレクション名でグループを分けます（例: `handbook` と `research`）。`Privacy` を省略すると LLM が推定しますが、公開資料は明示的に低く（例 0.1）しておくと gate 設計が単純です。

```mathematica
(* 単一 PDF *)
PDFIndex`pdfIndex["F:\\docs\\学生便覧2025.pdf",
  Collection -> "handbook", Title -> "学生便覧 2025", Privacy -> 0.1,
  Keywords -> {"履修", "卒業要件", "カリキュラム"}];

(* フォルダ内の全 PDF を一括 *)
PDFIndex`pdfIndexDirectory["F:\\docs\\handbook_pdfs",
  Collection -> "handbook", Privacy -> 0.1, FilePattern -> "*.pdf"];

(* PDF の URL から取り込み *)
PDFIndex`pdfIndexURL["https://example.ac.jp/handbook/2025.pdf",
  Collection -> "handbook", Privacy -> 0.1];

(* 別グループ (研究資料) は別コレクションに *)
PDFIndex`pdfIndexDirectory["F:\\docs\\papers",
  Collection -> "research", Privacy -> 0.0];
```

> **Web ページ（HTML）**: `pdfIndexURL` は PDF を想定します。HTML ページは **PDF に印刷保存してから `pdfIndex`** するのが、表・レイアウト保持の点で最も確実です。本文テキストだけで良ければ HTML をローカル保存して `pdfIndex` でも取り込めます。
>
> 取り込み後は `PDFIndex\`pdfStatus[]` / `PDFIndex\`pdfListDocs["handbook"]` で確認できます。埋め込みモデルは bge-m3（既定）。索引後に埋め込みモデルを変えたら `PDFIndex\`pdfReembed["handbook"]`。

> **arXiv 論文**: arXiv の論文 PDF を `pdfIndexURL` で取り込んだ場合、後述の `SourceVaultSources` / `SourceVaultSummaries` を `"FetchMetadata" -> Automatic` で呼び出すと、arXiv API（`export.arxiv.org`）から論文タイトル・著者・出版日・アブストラクトを自動取得してメタにキャッシュします。取得された `Authors`（著者リスト）はメタ情報の `"Authors"` フィールドとして検索結果からも参照できます。

### 1b. ingest 済みのプライバシーレベル是正（`SourceVaultReclassifyPublicPrivacy`）

arXiv 等の公開ソースがプライバシーレベル 0.5 以上に誤タグされていた場合、`SourceVaultReclassifyPublicPrivacy` で一括是正できます。本来の公開既定値（`OfficialDocs` / `OfficialAPI` = 0.0、`PublicWeb` = 0.4）に source・snapshot 両メタを書き換えます。

```mathematica
(* arXiv 等の公開ソースを本来の PrivacyLevel に是正する (冪等) *)
result = SourceVaultReclassifyPublicPrivacy[];
(* => <|"Status" -> "OK", "Count" -> n, "Changed" -> {<|"SourceId" -> ..., "From" -> 0.6, "To" -> 0.0|>, ...|>}|> *)
```

> **用途**: 旧版が arXiv 等の `OfficialDocs` を 0.6 と誤タグした件など、過去の誤設定を一度きり修正する保守関数です。通常の運用では不要ですが、公開ソースが誤って機密扱いになっている場合（`SourceVaultSources` に表示されない等）に使用します。

---

## 2. グループ化（release context / profile / migration rule）

取り込んだコレクションを「検索可能なグループ」にするには、次の 3 つを登録します。

```mathematica
(* 2-1. release context: 公開可否ポリシー *)
SourceVaultRegisterReleaseContext["campus-handbook-web", <|
  "MaxPrivacyLevel" -> 0.5,
  "RequiredTags" -> {"ReleaseContext:Campus:Handbook:Web"},
  "DenyTags" -> {"NoWeb", "Draft", "Personal"}|>];

(* 2-2. PDFIndex profile: どのコレクションを検索するか *)
SourceVaultRegisterPDFIndexProfile["student-handbook",
  <|"CollectionRoot" -> "handbook"|>];   (* 既定 collection を使うなら <||> *)

(* 2-3. migration rule: legacy 検索結果に release メタを付与 (無いと fail-closed で 0 件) *)
SourceVaultRegisterPDFIndexMigrationRule["student-handbook", <|
  "AssignReleaseContexts" -> {"ReleaseContext:Campus:Handbook:Web"},
  "AssignPrivacyLevel" -> 0.1,
  "AssignState" -> "Published"|>];
```

研究資料グループも同様に別名で登録します（`research-internal` / `research` profile など）。release context を分ければ、グループごとに公開範囲を変えられます。

### 2b. 不変スナップショット（Immutable Snapshot）のプライバシー管理

SourceVault は **content-addressed な不変スナップショット**をサポートしています。スナップショット ID は `snapshot:class:hex` または `sv://snapshot/..` 形式の URI で識別されます。

不変スナップショットは**本体ファイルを書き換えない**設計（content-addressed）になっており、プライバシーレベルの変更はサイドレコードへ委譲されます。

#### 主な API

| 関数 | 説明 |
|---|---|
| `SourceVaultImmutableSnapshotExistsQ[snapshotId]` | 指定した snapshotId の不変スナップショットが存在するか判定する。`True` / `False` を返す。 |
| `SourceVaultSetImmutableSnapshotPrivacyLevel[snapshotId, lv]` | 不変スナップショットのプライバシーレベルを `lv` に設定する。本体は書き換えずサイドレコードに記録される。 |

```mathematica
(* スナップショット URI の形式例 *)
(* "snapshot:pdf:a3f2c1..." または "sv://snapshot/a3f2c1..." *)

(* 存在確認 *)
SourceVaultImmutableSnapshotExistsQ["snapshot:pdf:a3f2c1d4e5b6..."]
(* => True / False *)

(* プライバシーレベルの変更 (本体不変・サイドレコードに記録) *)
SourceVaultSetImmutableSnapshotPrivacyLevel["snapshot:pdf:a3f2c1d4e5b6...", 0.3];
```

> **設計上の注意**: 不変スナップショットは content-addressed であるため、本体ファイルは一切変更されません。`SourceVaultSetImmutableSnapshotPrivacyLevel` による変更はサイドレコードにのみ反映され、スナップショットのハッシュ値（整合性）は維持されます。リリース判定時にはサイドレコードのプライバシーレベルが優先参照されます。

---

## 3. 補足知識（凡例・補正・人手転記）を付ける

PDF に書かれていない凡例（②＝必修 等の慣例）や、OCR で崩れた表の補正は、**人手レビュー済みの補足知識**として登録します。検索時に PDF 根拠と一緒に使われ、永続化（`<CoreRoot>/curated/`）されます。

```mathematica
(* 凡例 (必修/選択の分類を解禁) *)
SourceVaultRegisterCuratedKnowledge["handbook-legend", <|
  "Text" -> "福山大学便覧の凡例: ②=必修科目, △N=選択必修, 通常数字=選択科目, ●=配当年次",
  "LegendMap" -> <|"②" -> "必修", "△" -> "選択必修", "●" -> "配当年次"|>,
  "ProvidesLegend" -> True,
  "Years" -> {2024, 2025},
  "ReleaseContexts" -> {"campus-handbook-web"},
  "ReviewState" -> "HumanReviewed"|>];

(* 崩れた表は LLM 転記ドラフト → 確認 → 登録 *)
PDFIndex`pdfLoadIndex["handbook"];
draft = SourceVaultDraftCuratedTranscription["情報工学科",
  "Collection" -> "handbook", "Limit" -> 4,
  "Years" -> {2025}, "ReleaseContexts" -> {"campus-handbook-web"}];
(* draft["CleanText"] を確認・修正してから承認登録 *)
SourceVaultRegisterCuratedKnowledge["handbook-r7-joho",
  Append[draft["ProposedCuratedSpec"], "ReviewState" -> "HumanReviewed"]];

SourceVaultListCuratedKnowledge[]   (* 登録済みを確認 *)
```

詳しい挙動（採用条件・分類解禁・Evidence Gap）は [servicemanager_example.md](servicemanager_example.md) §6b/§6c を参照。

---

## 4. 検索関数の使い方（`SourceVaultSearch`）

`SourceVaultSearch` は **release context gate 付き**で検索し、`Permit` のチャンクだけを `SearchResult` のリストで返します（raw local path は返しません）。

```mathematica
res = SourceVaultSearch["履修登録の手順",
  "ReleaseContext" -> "campus-handbook-web",
  "PDFIndexProfile" -> "student-handbook",
  "Limit" -> 8];

(* 各結果の読み方 *)
Dataset[<|
  "Title" -> Lookup[#Citation, "Title"],
  "Page" -> Lookup[#Citation, "Page"],
  "Score" -> #Score,
  "Decision" -> #ReleaseDecision,     (* Permit のみ返る *)
  "ChunkId" -> #ChunkId,
  "Snippet" -> StringTake[#Snippet, UpTo[60]]|> & /@ res]
```

各 `SearchResult` の主なキー: `Citation`(=`<|"Title","Page"|>`) / `Score` / `Snippet` / `ChunkId` / `EvidenceRef` / `ReleaseDecision`。

- **native projection index** を使う場合は `"Index" -> "<id>"`（`SourceVaultBuildProjectionIndex` で作成）。
- スニペットは短いので、本文が必要なら `PDFIndex\`pdfGetChunk[ToExpression[#ChunkId], "handbook"]`。
- **ungated の素の検索**（グループ/公開制御なしで動作確認したいとき）は `PDFIndex\`pdfSearch["クエリ", 10, Collection -> "handbook"]`。実運用の公開検索は必ず `SourceVaultSearch`（gate 付き）を使ってください。

---

## 5. ソース一覧・横断検索（`SourceVaultSources` / `SourceVaultSummaries`）

PDFIndex・Eagle 保存済みサマリー等、**登録済み provider を横断**してソースを一覧表示したり、クエリで絞り込んだりするには `SourceVaultSources` / `SourceVaultSummaries` を使います。gate 付き `SourceVaultSearch` が「チャンク単位の根拠検索」であるのに対し、こちらは「ソース（ドキュメント）単位の一覧・横断検索」です。

### 主なオプション

| オプション | 既定値 | 説明 |
|---|---|---|
| `"FetchMetadata"` | `Automatic` | `Automatic`：未取得のみ arXiv API 等から取得。`False`：ネットワークアクセスなし。`True`：強制再取得。 |
| `"Kind"` | `All` | `"arxiv"` / `"web"` / `"local"` / `All` でソース種別を絞り込む。 |
| `"Since"` / `"Until"` / `"On"` | - | ingest 日での絞り込み（日付文字列 `"yyyy-mm-dd"` / `Today` / `DateObject`）。`"On"` は単日、`"Since"` / `"Until"` は範囲（両端含む）。 |
| `"Author"` | - | 著者名の部分一致フィルタ。 |
| `"Format"` | `"Grid"` | `"Grid"`（UI 表示用グリッド）/ `"Dataset"`（Dataset 型）/ `"Rows"`（Association のリスト）。 |
| `"Limit"` | `Automatic` | 表示件数の上限。 |

```mathematica
(* 全ソースを Grid 形式で一覧表示 *)
SourceVaultSources["",
  "FetchMetadata" -> Automatic,
  "Format" -> "Grid"]

(* キーワードで横断検索 → Dataset で受け取る *)
SourceVaultSources["arXiv 機械学習",
  "FetchMetadata" -> Automatic,
  "Format" -> "Dataset",
  "Limit" -> 50]

(* 今日 ingest した arXiv ソースだけを表示 *)
SourceVaultSources["", "Kind" -> "arxiv", "On" -> Today]

(* 著者名で絞り込み *)
SourceVaultSources["可逆計算", "Author" -> "Bennett", "Format" -> "Grid"]

(* 期間指定（2025-06-01 以降に ingest） *)
SourceVaultSources["", "Since" -> "2025-06-01", "Format" -> "Dataset"]

(* Eagle 保存済みサマリー等も含めた統合表で横断検索 *)
SourceVaultSummaries["強化学習",
  "FetchMetadata" -> False,   (* ネットワーク不要な場合 *)
  "Format" -> "Grid"]
```

`SourceVaultSummaries` も同じ `"Since"` / `"Until"` / `"On"` / `"Author"` / `"Format"` オプションを受け付けます。さらに `"Providers" -> All | {"sources", "eagle", ...}` で横断対象の provider を絞り込めます。

### arXiv 専用ビュー（`SourceVaultArXiv`）

`SourceVaultArXiv` は arXiv ソースだけを共通スキーマ表で表示する薄ラッパです（`SourceVaultSources[query, "Kind" -> "arxiv", ...]` と等価）。`SourceVaultSources` と同じオプション（`"On"` / `"Since"` / `"Until"` / `"Author"` / `"Limit"` / `"Format"` 等）を受け付けます。

```mathematica
(* 今日 ingest した arXiv 論文を一覧 *)
SourceVaultArXiv["", "On" -> Today]

(* "可逆" かつ著者 "Bennett" で絞り込み *)
SourceVaultArXiv["可逆", "Author" -> "Bennett"]

(* 期間指定 + Dataset 形式 *)
SourceVaultArXiv["quantum", "Since" -> "2025-01-01", "Format" -> "Dataset"]
```

> **横断検索との連携**: `SourceVaultArXiv` は `SourceVaultSummaries` の横断検索にも相乗りしており、`SourceVaultSummaries["クエリ"]` を実行した際にも arXiv ソースが含まれます。

### arXiv 論文のメタ自動取得

arXiv 論文を取り込んでいる場合、`"FetchMetadata" -> Automatic`（または `True`）を指定すると arXiv API からタイトル・著者・出版日・アブストラクトを一括取得してメタにキャッシュします。取得済みであれば `Automatic` でも再取得しません。

```mathematica
(* arXiv 論文の著者・日付付き一覧 *)
rows = SourceVaultSources["arxiv",
  "FetchMetadata" -> Automatic,
  "Format" -> "Rows"];

Dataset[<|
  "Title"   -> Lookup[#, "Title", ""],
  "Authors" -> Lookup[#, "Authors", {}],   (* arXiv API から取得した著者リスト *)
  "Date"    -> Lookup[#, "Date", ""],
  "File"    -> Lookup[#, "File", ""]|> & /@ rows]
```

> **メタのキャッシュ**: 取得された `Authors`（著者名リスト）・タイトル・出版日・アブストラクトはメタに永続化されるため、次回以降は arXiv への通信なしに利用できます。オフライン環境では `"FetchMetadata" -> False` を指定してください。

### arXiv サマリーのバックフィル（`SourceVaultBackfillArXivSummaries`）

`SourceVaultBackfillArXivSummaries` は、既存の arXiv ソースのうち Summary が未設定（または過去の LLM エラー本文が保存されてしまったもの）に対して、arXiv アブストラクトを取得し `$Language` へ翻訳して Summary として付与します。ingest 時の自動付与と同じ処理です。

```mathematica
(* 未設定のサマリーを一括生成（翻訳は cloud LLM、arXiv は公開データなので PrivacyLevel 0.0） *)
result = SourceVaultBackfillArXivSummaries[];
(* => <|"Candidates" -> n, "Updated" -> k, "AlreadyPresent" -> m,
        "NoAbstract" -> 0, "Failed" -> 0, "Results" -> {...}|> *)

(* 既存 Summary も含めて強制再生成する場合 *)
SourceVaultBackfillArXivSummaries["Force" -> True]

(* 処理件数を上限 10 件に制限 *)
SourceVaultBackfillArXivSummaries["Limit" -> 10]
```

> **実行環境**: 翻訳に cloud LLM（arXiv は公開データなので PrivacyLevel 0.0）を使用します。`$Language` が `Japanese` のセッションで実行してください（headless では英語原文のまま格納されます）。

### サマリーノートを開く（`SourceVaultShowSourceSummary` / `SourceVaultOpenSourceFile`）

`SourceVaultSources` / `SourceVaultArXiv` / `SourceVaultSummaries` の表でタイトルまたはサマリーをクリックすると、`SourceVaultShowSourceSummary` が呼ばれ、ソースのサマリーを編集可能なノートブックで開きます。

```mathematica
(* タイトルクリックと同等の操作を手動実行する場合 *)
SourceVaultShowSourceSummary["src-xxxxxxxx"]

(* 保存版を無視して record から新規生成する場合 *)
SourceVaultShowSourceSummary["src-xxxxxxxx", "Fresh" -> True]
```

- **保存済みのユーザー追記版があればそれを開きます**（正本）。ノート内の「このノートを保存する」ボタンを押すと `<PrivateVault>/sources/summary-notes/` に保存され、以後はその保存版が正本として開かれます。
- 保存版がなければ、タイトル・著者・出版日・URL・要約から自動生成したノートを表示します。
- ノートのスタイルは `$SourceVaultSummaryNotebookStyle`（既定: `"SourceVault default.nb"`）で変更できます。

`SourceVaultOpenSourceFile` は ingest 済みソースの raw ファイル（PDF 等）を `SystemOpen` で開くユーティリティで、`SourceVaultSources` / `SourceVaultArXiv` の「▶ 開く」ボタンの実体です。保存時の絶対パスではなく `ContentHash` から現在の PC の vault パスを live 再算出するため、Dropbox 同期後の別 PC でも正しく開けます。

```mathematica
(* raw ファイルをシステムのデフォルトアプリで開く *)
SourceVaultOpenSourceFile["src-xxxxxxxx"]
```

### 共通スキーマ行（`SourceVaultSourceRow`）

`SourceVaultSourceRow` は 1 ソースの共通スキーマ行を Association として返します。`SourceVaultSources` / `SourceVaultArXiv` の各行や `SourceVaultSummaries` の統合表が内部で使用しており、横断データセットの join キーとして利用できます。

```mathematica
row = SourceVaultSourceRow["src-xxxxxxxx"]
(* =>
  <|"Kind" -> "arxiv",
    "Id"   -> "src-xxxxxxxx",
    "URI"  -> "sv://snapshot/sha256/<hex>",   (* 正準 URI: content-addressed *)
    "Title"   -> "...",
    "Authors" -> {...},
    "Published" -> "2024-03-15",
    "Summary"  -> "...",
    "URL"      -> "https://arxiv.org/abs/...",
    "File"     -> "F:\\...",
    "Date"     -> "2025-06-01",
    "PrivacyLevel" -> 0.0|> *)
```

> **`"URI"` フィールド**: `sv://snapshot/sha256/<hex>` 形式の content-addressed な正準 URI です。`SourceVaultEagleSummaryRow` と同じキーを共有しており、Eagle・arXiv・web・local など異種ソースを混在させたデータセットを `"URI"` キーで join・参照する際の共通識別子として使用します。

---

## 6. ClaudeEval のプロンプトで検索する

ノートブックで Claude（ClaudeEval）に問い合わせて、**グループ＋補足知識を根拠にした回答**を得る方法です。

### (a) プロンプトから Claude に検索させる

ノートブックのプロンプトで、例えば次のように依頼します。

```text
handbook グループ (ReleaseContext campus-handbook-web / PDFIndexProfile student-handbook) を
SourceVaultSearch で「卒業に必要な単位」を検索し、上位の Citation と要点を日本語でまとめて。
```

Claude は次のような WL を生成・実行します（＝あなたが手で書いてもよい）。

```mathematica
res = SourceVaultSearch["卒業に必要な単位",
  "ReleaseContext" -> "campus-handbook-web", "PDFIndexProfile" -> "student-handbook", "Limit" -> 8];
Column[("p." <> ToString[Lookup[#Citation,"Page"]] <> " " <> Lookup[#Citation,"Title"] <>
        " : " <> StringTake[#Snippet, UpTo[80]]) & /@ res]
```

### (b) 根拠を LLM に渡して回答合成（gate 越し）

検索（gate 付き）→ 上位チャンクのフル本文 → `ClaudeQuery` に根拠として渡す、が推奨パターンです（Web の `/pdfask` と同じ考え方）。

```mathematica
res = SourceVaultSearch["卒業に必要な単位",
  "ReleaseContext" -> "campus-handbook-web", "PDFIndexProfile" -> "student-handbook", "Limit" -> 6];
evidence = StringRiffle[
  MapIndexed[Function[{r, i},
    "[" <> ToString[First[i]] <> "] (p." <> ToString[Lookup[r["Citation"], "Page"]] <> " " <>
    Lookup[r["Citation"], "Title"] <> ")\n" <>
    StringTake[ToString @ PDFIndex`pdfGetChunk[ToExpression[r["ChunkId"]], "handbook"], UpTo[1500]]],
    res], "\n\n"];
ClaudeCode`ClaudeQuery[
  "次の【根拠】だけを使って『卒業に必要な単位』を日本語でまとめ、各事実に (p.ページ) を付けてください。\n\n【根拠】\n" <>
  evidence];
```

> トップレベルでないコンテキスト（スケジュールタスク内等）では `ClaudeCode\`ClaudeQueryBg`（同期・コンテキスト安全）を使います。

### (c) 組み込みの検索＋LLM（簡易・ungated）

`pdfAskLLM` はコレクションを検索して LLM にまとめさせる組み込みです。**gate を通さない**ので、社内確認用途向けです。

```mathematica
PDFIndex`pdfAskLLM["情報工学科のカリキュラムの特徴は?", Collection -> "handbook"]
```

公開・release 制御が要る場合は (b) または Web 公開（§7）を使ってください。

---

## 7. Web で公開する（一連の流れ）

グループ設定を `PDFGroupSearchProfile` に束ね、detached service ＋ Python proxy で公開します。

```mathematica
(* 7-1. グループの設定を 1 つの profile に束ねる (configuration-as-data) *)
SourceVaultCreatePDFGroupSearchProfile["handbook-web", <|
  "AppTitle" -> "学生便覧 検索",
  "ReleaseContext" -> "campus-handbook-web",
  "PDFIndexProfile" -> "student-handbook",
  "ChatModel" -> "cloud"|>];

(* 7-2. サービス prelude: バックエンドをロードし、グループ登録を再現 (サービスは別プロセス) *)
pkgDir = DirectoryName[FindFile["SourceVault_servicemanager.wl"]];
prelude = StringJoin[
  "Block[{$CharacterEncoding=\"UTF-8\"}, Get[", ToString[FileNameJoin[{pkgDir,"NBAccess.wl"}], InputForm], "]];\n",
  "Block[{$CharacterEncoding=\"UTF-8\"}, Get[", ToString[FileNameJoin[{pkgDir,"PDFIndex.wl"}], InputForm], "]];\n",
  "Block[{$CharacterEncoding=\"UTF-8\"}, Get[", ToString[FileNameJoin[{pkgDir,"WebServer.wl"}], InputForm], "]];\n",
  "SourceVault`SourceVaultRegisterReleaseContext[\"campus-handbook-web\", <|",
  "\"MaxPrivacyLevel\"->0.5, \"RequiredTags\"->{\"ReleaseContext:Campus:Handbook:Web\"}, ",
  "\"DenyTags\"->{\"NoWeb\",\"Draft\",\"Personal\"}|>];\n",
  "SourceVault`SourceVaultRegisterPDFIndexProfile[\"student-handbook\", <|\"CollectionRoot\"->\"handbook\"|>];\n",
  "SourceVault`SourceVaultRegisterPDFIndexMigrationRule[\"student-handbook\", <|",
  "\"AssignReleaseContexts\"->{\"ReleaseContext:Campus:Handbook:Web\"}, ",
  "\"AssignPrivacyLevel\"->0.1, \"AssignState\"->\"Published\"|>];\n",
  "PDFIndex`pdfLoadIndex[\"handbook\"];\n"];

(* 7-3. 起動 (補足知識 curated は <CoreRoot>/curated に永続化済みなので service が自動で読む) *)
SourceVaultStartService["handbook-web-svc",
  "Kind" -> "websearch", "HeartbeatIntervalSeconds" -> 1, "PreludeCode" -> prelude];
TimeConstrained[While[Lookup[SourceVaultServiceStatus["handbook-web-svc"], "State"] =!= "Running", Pause[2]], 120];

SourceVaultStartHTTPProxy["handbook-web-svc",
  "PDFGroupProfile" -> "handbook-web",   (* AppTitle/RC/Profile/ChatModel を profile から供給 *)
  "Port" -> 8080, "SearchTimeoutMs" -> 30000];
```

ブラウザで:
- `http://127.0.0.1:8080/sv/pdfsearch?q=履修登録` — gate 済み検索（LLM 非使用・即時）
- `http://127.0.0.1:8080/sv/pdfask?q=情報工学科R7入学生の必修科目` — gate 済み根拠＋補足知識を LLM が合成（非同期）

> 補足知識（§3 で登録した凡例・転記）は `<CoreRoot>/curated/` に永続化されているので、サービス側で自動的にマージされます。サービス起動の詳細・停止・トラブルシュートは [servicemanager_example.md](servicemanager_example.md)。

---

## 8. 別グループの横展開（clone）

研究資料グループを公開する場合、profile を clone して上書きするだけです（コード変更ゼロ）。

```mathematica
SourceVaultCreatePDFGroupSearchProfile["research-web", <|
  "AppTitle" -> "研究資料 検索", "ReleaseContext" -> "research-internal",
  "PDFIndexProfile" -> "research", "ChatModel" -> "cloud"|>];
(* 既存を雛形に差分だけ変える場合 *)
SourceVaultClonePDFGroupSearchProfile["handbook-web", "research-web2",
  <|"AppTitle" -> "研究資料 検索", "ReleaseContext" -> "research-internal", "PDFIndexProfile" -> "research"|>];

(* 別ポートで起動 (prelude は research コレクション/profile に差し替え) *)
SourceVaultStartHTTPProxy["research-web-svc", "PDFGroupProfile" -> "research-web",
  "Port" -> 8081, "SearchTimeoutMs" -> 30000];
```

---

## 9. まとめ（使用 API）

| 段階 | API |
|---|---|
| 取り込み | `PDFIndex\`pdfIndex` / `pdfIndexDirectory` / `pdfIndexURL` / `pdfStatus` / `pdfListDocs` / `pdfReembed` |
| グループ化 | `SourceVaultRegisterReleaseContext` / `RegisterPDFIndexProfile` / `RegisterPDFIndexMigrationRule` |
| 補足知識 | `SourceVaultRegisterCuratedKnowledge` / `DraftCuratedTranscription` / `ListCuratedKnowledge` |
| 不変スナップショット | `SourceVaultImmutableSnapshotExistsQ`（存在確認）/ `SourceVaultSetImmutableSnapshotPrivacyLevel`（プライバシー設定・サイドレコード委譲）。URI 形式: `snapshot:class:hex` / `sv://snapshot/..` |
| ソース一覧・横断検索 | `SourceVaultSources` / `SourceVaultSummaries`（provider 横断。オプション: `"FetchMetadata"` / `"Kind"` / `"Since"` / `"Until"` / `"On"` / `"Author"` / `"Format"` / `"Limit"`） |
| arXiv 専用ビュー | `SourceVaultArXiv`（`SourceVaultSources["", "Kind"->"arxiv"]` の薄ラッパ。`"On"` / `"Author"` 等で絞り込み可） |
| サマリーノート | `SourceVaultShowSourceSummary`（ソースのサマリーを編集可能ノートで開く。タイトル/サマリークリックの既定アクション）/ `$SourceVaultSummaryNotebookStyle`（ノートスタイル） |
| ファイルを開く | `SourceVaultOpenSourceFile`（ContentHash から現 PC の vault パスを live 再算出して SystemOpen） |
| 共通スキーマ行 | `SourceVaultSourceRow`（キー: `"Kind"` / `"Id"` / `"URI"` / `"Title"` / `"Authors"` / `"Published"` / `"Summary"` / `"URL"` / `"File"` / `"Date"` / `"PrivacyLevel"`） |
| arXiv バックフィル | `SourceVaultBackfillArXivSummaries`（既存 arXiv ソースにアブストラクト翻訳を一括付与） |
| プライバシー是正 | `SourceVaultReclassifyPublicPrivacy`（公開ソースの誤タグを本来の既定値に是正） |
| 検索 | `SourceVaultSearch`（gate 付き） / `PDFIndex\`pdfSearch`（ungated） / `PDFIndex\`pdfGetChunk` |
| ClaudeEval 検索 | 上記 + `ClaudeCode\`ClaudeQuery` / `ClaudeQueryBg` / `PDFIndex\`pdfAskLLM`（簡易） |
| Web 公開 | `SourceVaultCreatePDFGroupSearchProfile` / `ClonePDFGroupSearchProfile` / `StartService` / `StartHTTPProxy` |
| グローバル設定 | `$SourceVaultDefaultNotebookFolder`（ノートブック保存先。Automatic → `$onWork` → `$packageDirectory` の順に解決） |
| メール（関連） | `SourceVaultMailEnsureLoaded` / `SourceVaultMailView` / `SourceVaultMailDataset` / `SourceVaultMailFetchNew` / `SourceVaultMailComposeReply` / `SourceVaultSearchMailSnapshots` / `SourceVaultInferMailDerivedBatch`（[SourceVault_maildb](https://github.com/transreal/SourceVault_maildb) サブシステム） |

要点:

- **グループ = コレクション ＋ release context ＋ profile ＋ migration rule ＋ 補足知識**。release context でグループごとに公開範囲を制御。
- **`Get["SourceVault.wl"]` で `SourceVault_objectview.wl` も自動ロード**されます（従来の core / searchindex / servicemanager / mcp に加えて追加）。
- **不変スナップショット**（URI: `snapshot:class:hex` / `sv://snapshot/..`）は content-addressed で本体不変。プライバシーレベルの変更は `SourceVaultSetImmutableSnapshotPrivacyLevel` でサイドレコードに委譲されます。存在確認は `SourceVaultImmutableSnapshotExistsQ`。
- **provider 横断の一覧・検索**は `SourceVaultSources` / `SourceVaultSummaries`。`"FetchMetadata" -> Automatic` で arXiv 論文のタイトル・著者・出版日・アブストラクトを自動取得してキャッシュします。`"On"` / `"Since"` / `"Until"` / `"Author"` / `"Kind"` でさらに絞り込めます。
- **arXiv 専用ビュー**は `SourceVaultArXiv`（`SourceVaultSources["", "Kind"->"arxiv"]` の薄ラッパ）。タイトルまたはサマリーをクリックすると `SourceVaultShowSourceSummary` が開き、編集可能なサマリーノートが表示されます。
- **arXiv サマリーの一括生成**は `SourceVaultBackfillArXivSummaries`。Summary 未設定のソースにアブストラクト翻訳を付与します（`$Language` = `Japanese` 推奨）。
- **共通スキーマ行**（`SourceVaultSourceRow`）は `"URI"` フィールド（`sv://snapshot/sha256/<hex>`）を含み、Eagle・arXiv・web・local など異種ソースを混在させたデータセットの join キーとして使用できます。
- **プライバシーの誤タグ是正**は `SourceVaultReclassifyPublicPrivacy`。公開ソース（arXiv 等）が 0.5 以上に誤設定されている場合に本来の既定値へ一括是正します（冪等）。
- 公開検索は必ず **`SourceVaultSearch`（gate 付き）**。`pdfSearch`/`pdfAskLLM` は ungated（確認用）。
- 凡例・崩れ表は **補足知識（人手レビュー済み）** で補う。永続化され service も自動利用。
- Web 公開は **`PDFGroupSearchProfile` 1 つ＋ start 2 ステップ**。別グループは clone で横展開。
- `$SourceVaultDefaultNotebookFolder` を設定すると、SourceVault ノートブックの保存先を一括で変更できます（Automatic 時は `Global`$onWork` → `$packageDirectory` の順に解決）。
- **メールサブシステム**（旧 maildb）は [SourceVault_maildb](https://github.com/transreal/SourceVault_maildb) として分離されており、`SourceVaultMailEnsureLoaded` でロードして利用できます。メール系キーワード（"メール"/"mail"/"受信"/"inbox" 等）を含むタスクでは、プロンプトルーターが自動的に maildb API を注入します。