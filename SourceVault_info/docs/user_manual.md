# SourceVault ユーザーマニュアル

SourceVault は、Wolfram Language / Mathematica 上で動作する **Source-First Knowledge Vault** エンジンです。  
文書 (URL / arXiv / PDF / Notebook / テキスト) を first-class source として ingest し、snapshot lifecycle・claim 抽出・Evidence Bundle・Notebook Management を一貫した状態機械として管理します。さらに、`ClaudeEval` の定型プロンプトを deterministic な関数呼び出しとして再実行する **PromptRouter** を備えます。

---

## 概要

SourceVault の役割は「source の同一性とライフサイクル管理」に限定されています。  
LLM への問い合わせ・式の安全性検証・実行ループは [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime) を通じて行われ、Notebook セルへのアクセス・編集は [NBAccess](https://github.com/transreal/NBAccess) の semantic API を通じて行われます。  
通常のユーザーは、ingest した source を `SourceVaultSpan` / `SourceVaultContext` で参照したり、`SourceVaultExtract` で構造化 claim を取得したり、`SourceVaultIndexNotebook` で notebook の状態を deterministic に追跡します。

タスク分解・マルチエージェント機構は [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) が担います。SourceVault には NBAccess hook (P1〜P4) が用意されており、ClaudeOrchestrator のワークフローに source 参照を組み込めます。  
SourceVault のロード時には ClaudeOrchestrator / ClaudeRuntime の存在を `Quiet @ Needs[]` + `Names[]` チェックで確認し、不足機能はグレースフルに無効化されます (詳細は「ClaudeOrchestrator との連携」節を参照)。

### PromptRouter — ClaudeEval の式提案契約

`ClaudeEval["今日から3日間のスケジュールを"]` のような **日常的な定型プロンプト**を、毎回重量級 LLM に再解釈させるのではなく、保存された PromptRoute や notebook cache を用いて deterministic な関数呼び出しとして再実行するのが PromptRouter です。

ここで重要なのは、`ClaudeEval` の基本契約です。`ClaudeEval` は「ユーザーに見せる最終値」を直接返す関数ではなく、ユーザーの要求を満たす **Mathematica 式を提案し、その式を ClaudeRuntime が head 検査してから実行する**機構です。PromptRouter もこの契約に従い、評価済みの `Association` や `Grid` を返すのではなく、**未評価の式**を返します。

```
ClaudeEval["今日から3日間のスケジュールを"]
   ↓ SourceVaultProposePromptRoute (未評価式を構築)
HoldComplete[ SourceVaultUpcomingSchedule["Period" -> Quantity[3,"Days"], ...] ]
   ↓ head 検査 (ReadOnly callable allowlist) → ReleaseHold で評価
SourceVaultUpcomingSchedule 本来の装飾付き Grid
```

したがって `ClaudeEval` のスケジュール系プロンプトの出力は、内部診断 `Association` でも独自の簡易表でもなく、`SourceVaultUpcomingSchedule` 本来の装飾付き Grid (Title link・tooltip・date styling 付き) になります。詳細は「PromptRouter の使い方」節を参照してください。

---

## SourceVaultIngest の使い方

### SourceVaultIngest とは

`SourceVaultIngest` は、テキスト / PDF / URL / arXiv ID を first-class source として登録する関数です。  
内容ハッシュ (SHA-256) で重複を自動検知し、同じファイルを再度 ingest しても `"AlreadyCurrent"` が返り、無駄な複製は作りません。

### Source ID と Snapshot ID

すべての source は 2 種類の識別子を持ちます。

| 種類 | 形式 | 役割 |
|---|---|---|
| `sourceId` | `src-<hash16>` / `nb-src-<hash16>` 等 | source の **同一性** (path や URL でユニーク) |
| `snapshotId` | `snap-sha256-<hash64>` | **特定時点のバイト列** (content hash でユニーク) |

```
src-<hash16>                          ← Source ID (path / URL に対して安定)
  ├── snap-sha256-aaaa...             ← Snapshot ID (v1、内容が変わるとここが変わる)
  ├── snap-sha256-bbbb...             ← Snapshot ID (v2、refresh で新版)
  └── snap-sha256-cccc...             ← Snapshot ID (v3、最新)
                                          ↑
                                        CurrentSnapshotId
```

source レコードは `meta/sources/<sourceId>.json` に、snapshot レコードは `meta/snapshots/<snapshotId>.json` に deterministic な JSON で保存されます。

> **注意**: `SourceVaultIndexNotebook` は mtime ベース cache を備えています。バージョン情報は `$SourceVaultVersion` 変数で確認できます。

依存関係の構成は以下のとおりです。

```
NBAccess.wl
   ↑
   │  (semantic API)
   │
claudecode.wl ─────────→ ClaudeRuntime.wl ─────────→ SourceVault.wl
                              ↑
                              │ (LLM 要約・claim 抽出時のみ)
                              │
                         ClaudeTestKit.wl
                         (mock provider / mock adapter)
```

- **deterministic 経路** (LLM 不要): ingest / Index / extract (deterministic schema) / Lint / FindNotebooks / PromptRouter のスケジュール提案
- **LLM 経路** (ClaudeRuntime 必須): `SourceVaultExtract` (LLM schema) / `SourceVaultNotebookSummary`

#### ロード時に有効になる機能

SourceVault をロードすると、以下が自動的に有効になります。

| 機能 | 内容 |
|---|---|
| PromptRouter 拡張の自動ロード | 同ディレクトリの `SourceVault_promptrouter.wl` を自動ロード |
| NBAccess semantic API | `NBReadHeader` / `NBReadTodos` / `NBFindCellByPredicate` + 書き込み系 4 個 |
| `SourceVaultIndexNotebook` mtime cache | 透過的キャッシュ (`"Cached"` / `"SourceMTime"` 戻り値、`"ForceReindex" -> True` で無効化) |
| Header parser MakeExpression 第一選択 | InitializationCell の副作用を回避 |
| Header フィルタ | TodoItem cell の TaggingRules を Header と誤認しない |

> **メモ:** 書き込み系 API (NBWriteTodoStatus / SourceVaultMarkTodo) はデフォルト `DryRun -> True` です。実際にファイルを変更する場合は明示的に `"DryRun" -> False` を渡してください。atomic write (tmp + Rename) で保護されており、書き込み途中での中断にも耐性があります。

### 基本的な使い方

#### 例 1 — URL から ingest

```mathematica
r = SourceVaultIngest["https://arxiv.org/abs/2401.12345"]
```

LLM は不要です。`URLRead` で取得し、内容ハッシュで snapshot を生成します。

```
<|"Status" -> "OK",
  "SourceId" -> "src-...",
  "SnapshotId" -> "snap-sha256-...",
  "Title" -> "Quantum Computing Review",
  "RawContentHash" -> "sha256-..."|>
```

#### 例 2 — arXiv ID で ingest（shorthand）

```mathematica
SourceVaultIngest["arXiv:2401.12345"]
```

`iCanonicalizeURL` が `https://arxiv.org/abs/2401.12345` に正規化するので、URL 形式と同一視されます。

#### 例 3 — テキストファイルを ingest

```mathematica
SourceVaultIngest["C:\\path\\to\\memo.txt"]
```

#### 例 4 — Notebook を ingest

```mathematica
SourceVaultIndexNotebook["C:\\path\\to\\research.nb"]
```

Header (whitelist 経由 safe parse) + Todo (3 値判定) + Lint (7 種) + Snapshot がまとめて生成されます。

### 実行中の状態確認

ingest した source の状況は以下で確認できます。

```mathematica
(* snapshot のメタ情報 *)
SourceVaultStatus[snapshotId]
(* → <|"Status" -> "OK",
       "SnapshotId" -> "snap-sha256-...",
       "SourceId" -> "src-...",
       "LifecycleStatus" -> "Current",
       "PageCount" -> 12,
       "RawContentHash" -> "sha256-..."|> *)

(* 全 source の一覧 *)
Dataset[SourceVaultListSources[]]

(* 全 snapshot の一覧 *)
Dataset[SourceVaultListSnapshots[]]

(* 特定 source の全 snapshot バージョン *)
SourceVaultListSnapshotsForSource[sourceId]
```

---

## Notebook Management

Mathematica notebook (`.nb`) を first-class source として扱う機能群です。

### 概要

`SourceVaultIndexNotebook[path]` は以下を deterministic に取得します:

- **Header** (whitelist 経由 safe parse): Keywords / Status / Deadline / NextReview / Owner / PathHint / Title
- **Todo** (3 値判定 Open/Done/Pass): TaggingRules > StrikeThrough > Default の優先順位
- **Lint** (7 種): HeaderStatusTodoButNoOpenTodos / DeadlinePast / NextReviewPast / TodoCellStatusHeuristicOnly 等
- **Snapshot**: NotebookSemanticHash + RawContentHash で deduplication

NBAccess には高レベル semantic API 7 個があり、`.nb` ファイルを **FrontEnd 不要** で直接編集できます。`SourceVaultMarkTodo` はこれの薄いラッパーです。

### SourceVault で使うノートブックの書式

SourceVault が index・管理するノートブックは、次の 3 つの慣用に従って作成します。これらに従っておくと、Header / Todo の読み取り、スケジュール表示、新規ノートブック生成がすべて自動で機能します。

#### 1. ファイル名: `yyyymmdd-<<ノートブックタイトル>>.nb`

ファイル名は **日付プレフィックス + タイトル** の形式を慣用します。

```
20260601-オープンキャンパス.nb
20260605-離散数学.nb
20260607-Canememo.nb
```

- 先頭の `yyyymmdd`（8 桁の年月日）は、作成日や対象日を表します。`SourceVaultFindNotebooks` の `"Scope" -> "Today"` は、NextReview / Deadline に加えてこのファイル名の日付も照合に使います。
- 続く `-` の後がタイトルです。Header に `Title` が無い場合は、このファイル名（拡張子と日付を除いた部分）がタイトルとして使われます。

#### 2. ヘッダ情報: `NotebookStatus` スタイルのセル

Keywords / Deadline / NextReview / Status といったヘッダ情報は、**`NotebookStatus` という専用スタイルのセル**に、Association リテラルとして保持します。

```mathematica
<|"Keywords" -> {"オープンキャンパス"},
  "Deadline" -> DateObject[{2026, 7, 18}],
  "NextReview" -> DateObject[{2026, 6, 2}],
  "Status" -> "Todo"|>
```

- セルのスタイルを `"NotebookStatus"` にして、上記のような `<|...|>` を入力しておきます。
- `Deadline` / `NextReview` は `DateObject[{y, m, d}]` 形式で記述します。`NextReview` は `Quantity[1, "Weeks"]` のような相対指定も可能で、その場合は index 時に「今日からの相対日付」として解決されます。
- `Status` は `"Todo"` / `"Done"` など、ノートブック全体の状態を表す文字列です。
- `NBReadHeader[path]` はこの `NotebookStatus` セルを最優先で読み取ります（`Source` が `"NotebookStatus"` になります）。`NotebookStatus` セルが無いノートブックは、従来方式（Input cell の BoxData / TaggingRules）に自動でフォールバックします。

> `NotebookStatus` スタイルは、後述の専用スタイルシート `SourceVault default.nb` に定義されています。スタイルシートを適用していないノートブックでもセルスタイル名として指定はできますが、見た目を整えるにはスタイルシートのインストールを推奨します（後述）。

#### 3. Todo 項目: `TodoItem_x` スタイルのセル

ノートブック内の個別の Todo（やることリスト）は、**`TodoItem_1` / `TodoItem_2` / `TodoItem_3` …** というスタイルのセルに 1 項目 1 セルで保持します。

```
Cell["卒論の章立てを確認する", "TodoItem_1"]
Cell["参考文献を追加する",     "TodoItem_2"]
```

- 各 Todo の完了状態は 3 値（Open / Done / Pass）で、セルの装飾（取り消し線 StrikeThrough + 文字色 FontColor）または TaggingRules で表します。
  - 取り消し線なし → **Open**（未完了）
  - 取り消し線あり + 緑 → **Done**（完了）
  - 取り消し線あり + 灰 → **Pass**（見送り）
- `NBReadTodos[path]` / `SourceVaultExtractNotebookTodos[path]` がこれらを列挙し、`SourceVaultFindTodos[...]` は条件に合う Todo を横断的にフラットなリストとして返します。
- `SourceVaultMarkTodo` で完了状態を書き換えられます（`NBWriteTodoStatus` の薄いラッパー）。

### テンプレートからの新規ノートブック作成

上記の書式（`NotebookStatus` セル + `TodoItem_x` セル）を備えた**テンプレートノートブック**を `Templates` フォルダに置いておくと、`ClaudeEval` から新規ノートブックを生成できます。

```mathematica
ClaudeEval["新規ノートブックを"]
ClaudeEval["新しいノートブックを"]
```

これらのプロンプトは PromptRouter 経由で `SourceVaultNewNotebook[]` にルーティングされ、次の処理を行います。

- `$packageDirectory/Templates/SourceVault notebook template.nb` をテンプレートとして読み込む。
- テンプレートの `NotebookStatus` セルの `Deadline` と `NextReview` を**その日の日付**（今日）に置換する。日付は `DateObject[{2026, 6, 1}]` のような**編集可能な入力式**として挿入されるので、後から書き直せます。
- `NotebookPut` で**未保存の新規ウィンドウ**として開く（ファイルには保存しません）。保存先・ファイル名はユーザーが任意に決められます。

`SourceVaultNewNotebook` を直接呼び出すこともできます。

```mathematica
(* 今日の日付で新規ノートブックを開く *)
SourceVaultNewNotebook[]

(* タイトルや日付を指定 *)
SourceVaultNewNotebook["Title" -> "研究会メモ", "Date" -> DateObject[{2026, 6, 10}]]
```

| オプション | 既定 | 説明 |
|---|---|---|
| `"TemplatePath"` | `Automatic` | テンプレート `.nb`。既定は `$packageDirectory/Templates/SourceVault notebook template.nb` |
| `"Title"` | `Automatic` | ウィンドウタイトル。既定は `"新規ノート"` |
| `"Date"` | `Automatic` | Deadline / NextReview に入れる日付。既定は今日 |

戻り値は `<|"Status" -> "OK", "Notebook" -> _NotebookObject, "Saved" -> False, "StatusCellReplaced" -> True, ...|>` です。開いたノートブックを保存するときは、ファイル名を上記の `yyyymmdd-<<タイトル>>.nb` の慣用に合わせると、以降の index・スケジュール表示が自然に機能します。

> 新規ノートブック作成を使うには、あらかじめテンプレート `SourceVault notebook template.nb` を `$packageDirectory/Templates/` に用意しておく必要があります。スタイルシートをテンプレートとして流用する手順は後述の「ノートブック用スタイルシートの配置」を参照してください。

### mtime ベース cache

`SourceVaultIndexNotebook[path]` は冒頭で `UnixTime[FileDate[path, "Modification"]]` と snapshot record の `"SourceMTime"` フィールドを比較し、一致なら **完全な Index 結果を再構築して返す** (透過的キャッシュ)。

```mathematica
(* 1 回目: reindex 実行 *)
r1 = SourceVaultIndexNotebook[nbPath];
{r1["Cached"], r1["SourceMTime"]}
(* {False, 1779243606} *)

(* 2 回目: cache hit *)
r2 = SourceVaultIndexNotebook[nbPath];
{r2["Cached"], r2["SourceMTime"]}
(* {True, 1779243606} *)

(* 強制 reindex *)
r3 = SourceVaultIndexNotebook[nbPath, "ForceReindex" -> True];
r3["Cached"]
(* False *)
```

ファイルを編集すると mtime が変わり、自動的に reindex されます。

### Header の 3 経路 fallback

`NBReadHeader[path]` は Header を 3 つの経路で探索し、最初に見つかったものを返します。

```mathematica
h = NBReadHeader[nbPath];
h["Source"]
```

| Source 値 | 取得経路 |
|---|---|
| `"TaggingRules"` | Notebook 全体の `TaggingRules -> <\|"SourceVault" -> <\|...\|>\|>` |
| `"HeaderCell"` | 個別 Cell の TaggingRules (Header フィルタ通過のみ) |
| `"BoxData"` | Input cell の BoxData → `MakeExpression[box, StandardForm]` で Association 化 |
| `"None"` | どの経路でも見つからず |

**Header フィルタ** (`iNBIsHeaderLikeAssoc`) は、Keywords / Status / Deadline / NextReview / Owner / PathHint / Title のいずれかを含む Association のみ Header と認めます。これにより `SourceVaultMarkTodo` が書き込んだ `<|"TodoStatus" -> "Done"|>` のような Todo metadata を Header と誤認しません。

### 注意事項

- 書き込み系 API (`SourceVaultMarkTodo` / `NBWriteHeader` / `NBWriteTodoStatus` 等) は **AccessLevel >= 0.7 が必須** です。デフォルトの `AccessSpec` (AccessLevel 0.5) では拒否されます。
- 書き込み系のデフォルトは `DryRun -> True` です。誤って実ファイルを変更しないように、明示的に `"DryRun" -> False` を渡す必要があります。
- mtime cache は cache hit 時に **完全な Index 結果** を返しますが、これは snapshot record の persisted データから再構築されます。Header / Todo は再抽出するため、ファイル内容が外部で変更され mtime も同時に手動で巻き戻された場合などはキャッシュ整合性に注意してください。
- `NBReadTodos` / `NBFindCellByPredicate` は `CellPath` (List of Integer) を返します。これは Cell[CellGroupData[{...}]] ネストに対応した nested index で、書き戻し時にそのまま使えます。

### ノートブック用スタイルシートの配置

`NotebookStatus` セルや `TodoItem_x` セルを正しい見た目で表示するには、専用スタイルシート **`SourceVault default.nb`** が必要です。これは Mathematica のスタイルシートディレクトリに配置されています。

このスタイルシートを**新規ノートブックのテンプレート**として流用するには、以下を実行して `Templates` フォルダにコピーします。テンプレートには `NotebookStatus` セルと `TodoItem` セルの雛形が含まれているため、`SourceVaultNewNotebook` / `ClaudeEval["新規ノートブックを"]` の元ファイルとして使えます。

```mathematica
CopyFile[
 FileNameJoin[{$UserBaseDirectory, "SystemFiles", "FrontEnd",
   "StyleSheets", "SourceVault default.nb"}],
 FileNameJoin[$packageDirectory, "Templates",
  "SourceVault notebook template.nb"]]
```

> `Templates` フォルダが存在しない場合は、あらかじめ `CreateDirectory[FileNameJoin[{$packageDirectory, "Templates"}]]` で作成してください。
>
> コピー後、テンプレートの `NotebookStatus` セルが既定の書式（`<|"Keywords" -> {"template"}, "Deadline" -> DateObject[...], "NextReview" -> Quantity[1, "Weeks"], "Status" -> "Todo"|>`）になっていることを確認してください。`SourceVaultNewNotebook` は、この `Deadline` / `NextReview` を生成日に置換した新規ノートブックを開きます。

---

## PromptRouter の使い方

PromptRouter は、`ClaudeEval` のスケジュール系プロンプトを `SourceVaultUpcomingSchedule` の呼び出し式に変換する機構です。

### 式提案契約

`ClaudeEval` の基本契約は「未評価の Mathematica 式を提案し、ClaudeRuntime が head を検査してから実行する」ことです。PromptRouter はこの契約に従い、`SourceVaultProposePromptRoute` がプロンプトを未評価の `HoldComplete[...]` 式に解決します。`ClaudeEval` 側のブリッジは、その式の head が ReadOnly callable allowlist にあることを確認してから `ReleaseHold` で評価し、評価結果を返します。

そのため PromptRouter は、内部診断 `Association` を返したり、評価済みの `Grid` を独自に組み立てたりはしません。表示は `SourceVaultUpcomingSchedule` 本来の装飾付き Grid に委ねられます。

### スケジュールの問い合わせ

ClaudeOrchestrator をロードしておくと、`ClaudeEval` のスケジュール系プロンプトが PromptRouter 経由で処理されます。

```mathematica
(* 単純な期間指定: 期間の幅が Period オプションになる *)
ClaudeEval["今日から3日間のスケジュールを"]
ClaudeEval["7日間のスケジュールを"]
ClaudeEval["今週のスケジュールを"]
ClaudeEval["6月の予定を"]
```

期間を表す表現 (「今日から N 日間」「N日間」「今週」「今月」「M/D」「M月」) は `SourceVaultUpcomingSchedule` の `"Period"` オプションに変換されます。

### 絞り込み付きの問い合わせ

「Todo が残っているもの」のような絞り込みは、`"FilterSpec"` オプションの構造化述語に変換されます。

```mathematica
ClaudeEval["7日間のスケジュールのうちTodoが残っているものを"]
(* → SourceVaultUpcomingSchedule["Period" -> Quantity[7,"Days"],
       "FilterSpec" -> <|"Kind" -> "Field",
         "Field" -> "OpenTodoCount", "Op" -> "Greater", "Value" -> 0|>, ...] *)
```

### 提案式の確認

PromptRouter がどんな式を提案するかを確認したい場合は `SourceVaultProposePromptRoute` を直接呼びます。式は評価されません。

```mathematica
p = SourceVaultProposePromptRoute["今日から3日間のスケジュールを"];
p["Status"]
(* "Proposed" *)
p["ProposedExpression"]
(* HoldComplete[SourceVaultUpcomingSchedule[
     "Scope" -> $onWork, "Period" -> Quantity[3, "Days"],
     "Refresh" -> "Never", "FallbackToCloud" -> "Deny"]] *)
p["Decision"]
(* <|"RouteId" -> "seed-sourcevault-upcoming-schedule-v1",
     "Method" -> "DeterministicSchedule",
     "PeriodDays" -> 3, "HasFilterSpec" -> False, ...|> *)
```

スケジュール以外のプロンプトには `Status -> "NotDispatched"` が返り、`ClaudeEval` は従来経路へ fallback します。

### FilterSpec の述語 DSL

`SourceVaultUpcomingSchedule` の `"FilterSpec"` オプションは、**閉じた DSL** の構造化述語を受け取ります。任意コードは含み得ません。

| 要素 | 許可される値 |
|---|---|
| `Kind` | `"And"` / `"Or"` / `"Not"` / `"Field"` |
| `Op` | `"Equal"` / `"NotEqual"` / `"Greater"` / `"GreaterEqual"` / `"Less"` / `"LessEqual"` / `"Contains"` / `"DateWithin"` / `"NonEmpty"` |
| `Field` | スキーマ allowlist にあるフィールド名のみ (Deadline / NextReview / OpenTodoCount / DoneTodoCount / PassTodoCount / Status / Title / Keywords) |
| `Value` | `String` / `Integer` / `Real` / `True` / `False` / `Missing[...]` / `DateObject` |

```mathematica
(* And / Or / Not を組み合わせた絞り込み *)
SourceVaultUpcomingSchedule[
  "Period" -> Quantity[14, "Days"],
  "FilterSpec" -> <|
    "Kind" -> "And",
    "Clauses" -> {
      <|"Kind" -> "Field", "Field" -> "OpenTodoCount",
        "Op" -> "Greater", "Value" -> 0|>,
      <|"Kind" -> "Not", "Clause" ->
        <|"Kind" -> "Field", "Field" -> "Status",
          "Op" -> "Equal", "Value" -> "Done"|>|>
    }
  |>]
```

`Function` / `Slot` / `ToExpression` / `RunProcess` などを含む述語、算術式 (`1 + 1`)、文字列連結 (`"x" <> "y"`) は受け付けられず、無効な FilterSpec として `Status -> "Failed"` が返ります。

### SourceVaultUpcomingSchedule のオプション

| オプション | 値 | 説明 |
|---|---|---|
| `"Period"` | `Quantity[n, "Days"]` 等 | 対象期間 |
| `"Scope"` | `Automatic` / `$onWork` 等 | 対象スコープ |
| `"OpenTodos"` | `True` / `False` / `Missing[]` | open todo の有無で絞り込み |
| `"DateField"` | `"Both"` / `"Deadline"` / `"NextReview"` | 対象とする日付フィールド |
| `"FilterSpec"` | 構造化述語 `Association` / `Missing[]` | 閉じた DSL による絞り込み |
| `"OutputFormat"` | `"Dataset"` / `"Rows"` / `"Records"` | 出力形式。既定 `"Dataset"` は装飾付き Grid |

```mathematica
(* Select 可能な生レコードの List が欲しい場合 *)
recs = SourceVaultUpcomingSchedule[
  "Period" -> Quantity[7, "Days"], "OutputFormat" -> "Records"];
Select[recs, #["OpenTodos"] > 0 &]
```

---

## ClaudeOrchestrator との連携

### 概要

SourceVault には **NBAccess hook (P1〜P4)** が用意されており、ClaudeOrchestrator のワークフローに source 参照を組み込めます。各 hook は SourceVault.wl 側で 1 関数で enable/disable でき、ClaudeOrchestrator 本体には 5 行のフックポイントのみが入っています。

| Hook | 何をするか |
|---|---|
| **P1** ClaudeAttach 連動 | `ClaudeAttach` で notebook に添付した瞬間に SourceVault にも自動登録 |
| **P2** ClaudeAttachments 連動 | `ClaudeAttachments[]` の戻り値に `SnapshotId` を含める |
| **P3** WorkerPrompt 連動 | ClaudeOrchestrator のサブ worker prompt に source 抜粋を自動注入 |
| **P4** ParseProposal 連動 | LLM 応答内の `<source>...</source>` タグを次ターンで自動再注入 |

> ここでの P1〜P4 は hook の識別名であり、開発段階を表すものではありません。

### PromptWorkflow 拡張の自動ロード

`ClaudeOrchestrator.wl` をロードすると、同じディレクトリにある `ClaudeOrchestrator_promptworkflow.wl` (PromptWorkflow 拡張) が自動的にロードされます。これにより、`ClaudeEval` から PromptRoute だけでなく WorkflowRoute (登録済みの Petri-net workflow) への dispatch も有効になります。`ClaudeEval` から PromptRouter への自動 dispatch は、原則として ClaudeOrchestrator がロード済みのときに有効になります。

### 非同期実行への対応

ClaudeOrchestrator が発行する `ClaudeEval` 呼び出しは ClaudeRuntime によって DAG ジョブとして非同期化されています。各サブタスクから SourceVault API を呼び出した場合も、`SourceVaultIngest` 等は同期的に完了する deterministic API なので、サブタスク間でレースコンディションは起きません。

LLM を伴う `SourceVaultExtract` / `SourceVaultNotebookSummary` は、内部で `ClaudeEval` を呼ぶため非同期化されます。戻り値の `jobId` 経由で `ClaudeRuntimeState[runtimeId]` で状態確認できます。

```mathematica
(* ClaudeOrchestrator + SourceVault のフル機能を有効化 *)
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",            "NBAccess.wl"];
  Needs["ClaudeRuntime`",       "ClaudeRuntime.wl"];
  Needs["ClaudeOrchestrator`",  "ClaudeOrchestrator.wl"];
  Needs["SourceVault`",         "SourceVault.wl"]
]

(* 4 hook を有効化 *)
SourceVaultClaudeAttachIntegrationEnable[]                (* P1 *)
SourceVaultClaudeAttachmentsIntegrationEnable[]           (* P2 *)
SourceVaultWorkerPromptIntegrationEnable[]                (* P3 *)
SourceVaultParseProposalIntegrationEnable[]               (* P4 *)
```

### Hook 状態の確認

```mathematica
SourceVaultIntegrationStatus[]
(* → <|"ClaudeAttach" -> "Enabled",
       "ClaudeAttachments" -> "Enabled",
       "WorkerPrompt" -> "Enabled",
       "ParseProposal" -> "Enabled"|> *)
```

### 注意事項

- P3 (WorkerPrompt) は P1 (ClaudeAttach) の TaggingRule を参照するため、P3 だけを enable しても期待通り動作しません。**P3 enable には P1 enable が前提**です。
- ClaudeOrchestrator なしで SourceVault 単体を使う場合、hook 関数は no-op となり警告は出ません。

---

## 初回セットアップ（暗号化・メール・アドレス帳）

暗号化・メール・2層アドレス帳サブシステムは、使う前に個人ごとの初期設定を**一度だけ**行う必要があります。設定の流れは次の通りです（詳細な手順とコード例はすべてプレースホルダ付きで [`setup.md` の「初回セットアップ（暗号化・メール・アドレス帳）」](setup.md) にまとめてあります）。

1. **鍵 backend を `SystemCredential` に設定**してから `SourceVault.wl` をロードする。`"Memory"`（既定）で暗号化すると鍵が揮発し、次回セッションで本文を復号できません（データ消失・不可逆）。
2. **暗号化を初期化**（`SourceVaultInitializeEncryption[]`）し、**鍵バンドルを Dropbox の外にバックアップ**（`SourceVaultExportKeyBundle[passphrase]`）。鍵はマシンローカル（SystemCredential/DPAPI）なので、別マシン移行・OS 再インストール復旧にはこのバンドルが要ります。
3. **オーナー（自分）をアドレス帳に登録**する。日本人名は漢字（正式）・ローマ字・かな（検索用）の3表記で登録し、`SourceVaultIdentityInitialize[]` で**オーナー実体 = ユーザデータベース #1** として確定します。

   ```mathematica
   SourceVault`SourceVaultAddressBookRegisterSelf["you@example.org",
      "DisplayName" -> "山田 太郎", "Kanji" -> "山田 太郎",
      "Romaji" -> "Taro Yamada", "Kana" -> "やまだ たろう"];
   SourceVault`SourceVaultIdentityInitialize[];
   SourceVault`SourceVaultSetOwnerLLMProfile["○○大学 ○○学科 ○○。専門: ..."];
   SourceVault`SourceVaultSetOwnerPrimaryEmail["you@example.org"];
   (* GUI で編集: SourceVault`SourceVaultEntityEditUI[1] *)
   ```

   オーナーの `LLMProfile` は派生処理（メールの優先度・概要推定）の受信者説明に、オーナーのメールは ReplyAll の自分除外に使われます。これらはソースにハードコードせず、すべて #1 に保持します。
4. **ローカル LLM（LM Studio）を登録**（`NBAccess`NBRegisterTrustedLocalServer[...]` + `$ClaudePrivateModel`）。機密メール（PrivacyLevel > 0.5）はここで処理します。
5. **IMAP アカウントを登録**する。パスワードは `SystemCredential["...KEY..."] = "..."` で手動設定し、`SourceVaultRegisterMailAccount[<|"MBox",...,"CredKey","Server","Port"|>]` で登録（`config/mailaccounts.jsonl` に永続化、パスワードは保存せず CredKey 名のみ）。
6. **重要度のグループ重みを設定**（任意、`SourceVaultSetPriorityGroupWeight["グループ名", 重み]`）。
7. **スタイルシート `SourceVault default.nb` を配置**（メール本文・返信ノートブックの見た目。「インストール手順」のスタイルシート節を参照）。

> **公開しない**: 上記のうち私的設定（メールアカウント・パスワード・氏名・所属・ローカルサーバ）を含む部分は、各自のローカル起動ファイル（`init.m` 等）にまとめ、GitHub などに公開しないでください。`RegisterMailAccount` / グループ重み / オーナープロフィールは vault config に永続化されるため、2 回目以降は backend 設定・パッケージロード・`IdentityInitialize`・パスワードの `SystemCredential` 設定だけで動きます。

---

## 暗号化基盤 (at-rest 暗号化)

SourceVault は、機密の本文・プロンプト・メール本文を **encrypt-then-MAC** で at-rest 暗号化して保存します。鍵は NBAccess 層 (KeyRef 間接参照) の中に閉じ込められ、**戻り値・ログ・record のいずれにも鍵材料は現れません**。プロンプト保存 (`SaveLastPrompt[..., "Encrypt" -> True]`) やメール本文の暗号化保存は、すべてこの基盤の上に乗っています。

> **設計メモ:** WL 14.3 には GCM/AEAD・組み込み HMAC・RSA-PSS が無いため、SourceVault は HMAC-SHA256 を手組みした encrypt-then-MAC を採用しています。record の判定駆動フィールド (Policy / Derived = PrivacyLevel / AccessTags など) も **AAD として MAC で認証**され、改ざんすると復号が `AuthenticationFailed` で拒否されます (静かに平文を返しません)。

### バックエンドの選択 (Memory / SystemCredential)

鍵ストアの実体は NBAccess の `$NBCredentialBackend` で切り替えます。**パッケージのロード前に**設定してください (鍵は復号のたびに backend から解決されます)。

| backend | 用途 | 永続性 |
|---|---|---|
| `"Memory"` | 開発・テスト | カーネル終了で鍵が消える (揮発) |
| `"SystemCredential"` | 本番・実データ | Windows DPAPI で永続化 (マシンローカル) |

```wolfram
(* 本番: 永続鍵で暗号化・復号する。必ずロード前に設定 *)
NBAccess`$NBCredentialBackend = "SystemCredential";
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",    "NBAccess.wl"];
  Needs["SourceVault`", "SourceVault.wl"]
]
```

> **重要 (データ損失に直結):** `"SystemCredential"` backend で暗号化したデータは、`"Memory"` backend のセッションでは **本文だけ復号できません** (ヘッダは平文なので表示されます)。実データを扱うセッションでは常に `SystemCredential` を、ロード前に設定してください。`Memory` のまま実 vault に書き込むと、揮発鍵で暗号化された本文がカーネル終了とともに永久に復号不能になります。

### 鍵の初期化と状態確認

`SourceVaultInitializeEncryption[]` は**冪等**な鍵 bootstrap です。欠落している標準鍵だけを生成し、既存鍵は破壊しません。

```wolfram
(* 不足している標準鍵だけを生成 (冪等)。鍵材料は返さない *)
SourceVaultInitializeEncryption[]
(* → <|"Status" -> "AlreadyInitialized" | "Initialized" | "Partial",
       "CreatedKeyRefs" -> {...}, "ExistingKeyRefs" -> {...},
       "KeyMaterialReturned" -> False, ...|> *)

(* 計画だけ確認 (生成しない) *)
SourceVaultInitializeEncryption["DryRun" -> True]

(* 標準 KeyRef ごとの存在・種別・指紋 (鍵材料なし) *)
SourceVaultEncryptionKeyStatus[]
```

> **新マシンでの注意:** `SourceVaultInitializeEncryption[]` は鍵が無いと**新しい乱数鍵を生成**します。後述の鍵バンドルで別マシンの鍵を持ち込む場合は、**先に `SourceVaultImportKeyBundle` を実行してから** Initialize してください。逆順だと別々の鍵が生まれ split-brain になります。

### 暗号 record の put / get / decrypt

```wolfram
(* 機密オブジェクトを暗号化して保存 (平文は保存しない) *)
r = SourceVaultEncryptedPut[<|"Prompt" -> "secret text"|>,
  "PrivacyLevel" -> 0.9, "ContentType" -> "MailBody"];
rid = r["RecordId"]

(* 暗号 record を取り出す (plaintext は返らない) *)
rec = SourceVaultEncryptedGet[rid];
SourceVaultEncryptedRecordQ[rec]   (* True *)

(* MAC 検証して復号 *)
d = SourceVaultDecryptRecord[rec];
{d["Status"], d["Plaintext"]}
(* → {"Ok", <|"Prompt" -> "secret text"|>} *)
```

主なオプション (`SourceVaultEncryptedPut`):

| オプション | 既定 | 説明 |
|---|---|---|
| `"PrivacyLevel"` | `0.75` (`$SourceVaultPrivateThreshold`) | これ以上で平文 digest/index を抑制 |
| `"ContentType"` | `"Generic"` | record 種別ラベル |
| `"AccessTags"` | `{}` | アクセス制御タグ (AAD として認証) |
| `"CloudSendAllowed"` | `False` | cloud materialization の前提条件 |
| `"Persist"` | `True` | `False` で in-kernel store に保存せず record のみ返す |
| `"SensitiveFields"` | `{"Prompt","Memo","TargetExprString","ResolvedMaterial"}` | 漏洩検査の対象フィールド |

### 自己診断

```wolfram
(* この WL 環境の暗号能力 (GCM/RSA-PSS/HMAC) を実測 *)
SourceVaultCryptoCapabilityReport[]

(* canonical 決定性・EtM roundtrip・改ざん検出をまとめて検査 *)
SourceVaultCryptoSelfTest[]
```

---

## 可搬鍵バンドル (マルチ環境・災害復旧)

鍵は **マシンローカル** (SystemCredential / DPAPI) なので、Windows を再インストールすると暗号化本文を全損し、別マシンでは復号できません。これを避けるために、標準マスター鍵をパスフレーズで包んだ**可搬鍵バンドル** (`.svkeys`) をエクスポートし、別マシンや復旧時にインポートします。

KDF は scrypt (メモリ困難・PBKDF2 より強い)。各鍵は AES256 ラップ + encrypt-then-MAC で包まれ、**平文の鍵材料はバンドルにも戻り値にも現れません**。誤ったパスフレーズや改ざんは MAC 検証で fail-closed に拒否されます。

> **セーフティ:** バンドルは既定でホーム直下 (`$HomeDirectory\SourceVault_keybundle.svkeys`、**Dropbox の外**) に書かれます。バンドルは USB やパスワードマネージャで管理し、**同期フォルダ (Dropbox) には絶対に置かないでください**。Dropbox に置くと、機密性はパスフレーズ強度だけに縮退します。

### エクスポート / インポート

```wolfram
(* 鍵バンドルをエクスポート (パスフレーズは本人だけが知る秘密) *)
SourceVaultExportKeyBundle["correct horse battery staple xyz"]
(* → <|"Status" -> "Exported", "Path" -> "...\\SourceVault_keybundle.svkeys",
       "KeyCount" -> 10, "Fingerprints" -> {...}, "KDF" -> <|...scrypt...|>,
       "OnSyncFolderWarning" -> False, "KeyMaterialReturned" -> False|> *)

(* 別マシン: 先にインポートしてから InitializeEncryption *)
SourceVaultImportKeyBundle["correct horse battery staple xyz"]
(* → <|"Status" -> "Imported", "RestoredCount" -> 10, "Backend" -> "SystemCredential", ...|> *)

(* パスフレーズ不要の非秘密メタだけ確認 *)
SourceVaultKeyBundleInfo[]
(* → <|"Status" -> "Ok", "Version" -> ..., "KeyCount" -> 10, "KDF" -> <|...|>|> *)
```

主なオプション (`SourceVaultExportKeyBundle`):

| オプション | 既定 | 説明 |
|---|---|---|
| `"Path"` | `Automatic` | 既定 `$HomeDirectory\SourceVault_keybundle.svkeys` (非 Dropbox) |
| `"ScryptN"` | `Automatic` | scrypt の N。既定 131072 (=2^17) |
| `"KeyRefs"` | `Automatic` | 既定で標準鍵すべて |
| `"Force"` | `False` | `True` で 12 文字未満の弱パスフレーズを許可 |

> **運用フロー:** 旧マシンで `SourceVaultExportKeyBundle[秘密]` → バンドルを安全な経路で新マシンへ → 新マシンで `SourceVaultImportKeyBundle[秘密]` → `SourceVaultInitializeEncryption[]` は `AlreadyInitialized` になり、同じ鍵で既存の暗号データを復号できます。

---

## メール管理 (MailDB / IMAP / Mail UI)

SourceVault は、旧 maildb の月次レコードや IMAP 新着を `SourceVaultMailSnapshot` に正規化し、**本文を暗号化**して保存・検索・派生・閲覧できます。

設計の要点:

- **本文は暗号化** (`SourceVaultEncryptedPut`、PL fail-safe 既定 0.85)。**ヘッダ (件名/差出人/宛先) は既定で平文 + token** です (Dropbox 同期を前提とした設計で、件名は意図的に暗号化しません)。`EncryptHeaders -> True` でヘッダも暗号化できます。
- snapshot は **mbox × 月のシャード**に分割保存され、1 通の追加で全体が再同期されないようになっています。
- RecordId / MessageIDToken は鍵に依存しない決定的な値で、再取得しても冪等です。
- **取り込み (IMAP) と派生処理 (ローカル LLM) は完全分離**。まず高速に取り込み、PL/優先度/概要は後から増分バッチで付けます。

### 既存スナップショットの読み込みと検索

```wolfram
(* 全シャードを読み込む (重い)。通常は EnsureLoaded で必要分だけ *)
SourceVaultMailStoreLoad[]

(* 必要な mbox・期間のシャードだけ遅延ロード *)
SourceVaultMailEnsureLoaded["work", 3]          (* 直近3ヶ月 *)
SourceVaultMailEnsureLoaded["work", "202601"]   (* 特定の年月 *)

(* キーワード + フィルタで検索 *)
SourceVaultSearchMailSnapshots["会議",
  "MinPriority" -> 0.5, "From" -> "@example.org",
  "HasAttachment" -> True, "SortBy" -> "Priority", "Limit" -> 20]
```

`SourceVaultSearchMailSnapshots` の主なオプション:

| オプション | 説明 |
|---|---|
| `From` | 差出人ヘッダの部分一致 |
| `MBox` / `DateFrom` / `DateTo` | mbox・日付範囲 |
| `MinPriority` / `MaxPriority` | 重要度の範囲 |
| `MinPrivacy` / `MaxPrivacy` | PrivacyLevel の範囲 |
| `HasAttachment` | 添付ありに限定 |
| `SortBy` | `"Date"` / `"Priority"` / `"PrivacyLevel"` |
| `SortOrder` | `"Desc"` (既定) / `"Asc"` |
| `Newest` | `True` (既定) で日付降順 |
| `Limit` | 件数制限 |

### 対話的なメール一覧 (Mail UI)

`SourceVaultMailView` は、各行に **✉本文表示 / 📎添付ポップアップ / ↩返信** のクリック操作を備えた表 (Dataset) を返します。件名はクリック可能で、ラベルは `$Language` に応じて日本語/英語に切り替わります。

```wolfram
(* 対話表示 (FrontEnd 必須)。列: 本文/添付/返信/日付/重要度/秘匿度/件名/差出人/概要 *)
SourceVaultMailView["会議", "Limit" -> 20]

(* ボタン無しの素の Dataset (列ソート用) *)
SourceVaultMailDataset["会議", "Limit" -> 20]
```

個別の FE 操作は次の関数で行えます。

```wolfram
SourceVaultMailGetBody[rid]            (* 本文を復号して取得 (Status/Body) *)
SourceVaultMailShowBody[rid]           (* 本文を新規ノートブックで表示 *)
SourceVaultMailAttachments[rid]        (* 添付 {Name, Path, Exists} のリスト *)
SourceVaultMailOpenAttachment[rid, "report.pdf"]  (* 添付を開く *)
SourceVaultMailComposeReply[rid, "ReplyAll" -> True]  (* 返信ドラフト生成 *)
SourceVaultMailOpenReplyNotebook[rid]  (* 返信ドラフトのノートブックを開く *)
```

> **安全ポリシー:** 返信は**ドラフト生成のみ** (DraftOnly) です。SourceVault は**メールを自動送信しません**。`SourceVaultMailComposeReply` は To / Cc / `Re:` 件名 / 引用本文 / `InReplyToToken` を組み立てるだけで、送信はユーザーが行います。`"ReplyAll" -> True` のときはオーナー (自分) のアドレスを Cc から自動除外します。

> 本文表示・返信ノートブックのスタイルは `$SourceVaultMailNotebookStyle` (既定 `"SourceVault default.nb"`) で指定します。表のフォントは `ClaudeCode\`$ClaudeStandardFont` を使います。

---

## IMAP 新着取得と派生処理 (取り込みと LLM の分離)

### IMAP アカウントの登録 (設定の外部化)

IMAP の接続情報は**ソースにハードコードせず**、`SourceVaultRegisterMailAccount` で vault config (`PrivateVault/config/mailaccounts.jsonl`) に登録します。**パスワードは保存されず**、SystemCredential 名 (`CredKey`) だけが永続化されます。これは NBAccess の `NBRegisterTrustedLocalServer` と同じ思想です。

```wolfram
(* IMAP アカウントを登録 (パスワードは SystemCredential に別途投入、ここには CredKey 名のみ) *)
SourceVaultRegisterMailAccount[<|
  "MBox" -> "work", "User" -> "you@example.org", "Email" -> "you@example.org",
  "CredKey" -> "WORK_IMAP_PASSWORD", "Server" -> "imap.example.org", "Port" -> 993|>]

SourceVaultMailAccounts[]                 (* 登録済み一覧 (パスワードは含まない) *)
SourceVaultGetMailAccount["work"]         (* 1件取得 *)
SourceVaultRemoveMailAccount["work"]      (* 削除 *)
```

### 新着の取得 (まず取り込み、LLM は後回し)

`SourceVaultMailFetchNew` は IMAP から新着のみ取得し、snapshot 化して store に保存します。既定は `"Process" -> False` で **LLM を回さず高速**に取り込みます。RecordId で既存と重複排除されるため、再取得しても二重登録されません。

```wolfram
(* 直近14日を取得 (LLM なし)。事前に RegisterMailAccount が必要 *)
SourceVaultMailFetchNew["work", "Period" -> "Latest"]
```

`"Period"` は次の形式を受け付けます: `"Latest"` (14日) / `n` (直近 n 日) / `{year, month}` / `{year, month, day}` / `"YYYYMM"` / `"YYYY"` / `{fromISO, toISO}`。

| オプション | 既定 | 説明 |
|---|---|---|
| `"Period"` | `"Latest"` | 取得期間 (上記の各形式) |
| `"Process"` | `False` | `True` でインライン派生も実行 |
| `"Overwrite"` | `False` | `True` で同一 RecordId も再保存 (修復・更新用) |
| `"Persist"` | `True` | ディスク保存 |
| `"MaxEmails"` | `Automatic` | 取得上限 |
| `"MessageSource"` | `Automatic` | 既定は実 IMAP (Python imaplib)。テストで注入可 |

### 派生 (PL / 優先度 / 概要) の増分バッチ

取り込んだ snapshot は最初 `DerivedStatus = "Pending"` です。`SourceVaultInferMailDerivedBatch` が本文を復号し、ローカル LLM (LM Studio, OpenAI 互換) で `<|WorkRequest, PrivacyLevel, Summary|>` を生成して in-place 更新します。**中断耐性**があり、`CheckpointEvery` 件ごとに保存し、処理済みは再処理しません。

```wolfram
(* 派生未処理の snapshot を確認 *)
SourceVaultMailDerivedPending[]

(* 50件ずつ派生を増分生成 (中断しても再開可) *)
SourceVaultInferMailDerivedBatch["Limit" -> 50, "CheckpointEvery" -> 20]
(* → <|"Status" -> ..., "PendingBefore" -> ..., "Processed" -> ...,
       "Failed" -> ..., "RemainingPending" -> ...|> *)
```

> ローカル LLM は `ClaudeCode\`$ClaudePrivateModel` のモデル/URL を使います (未設定なら `/v1/models` から取得、既定 `127.0.0.1:1234`)。本文の復号が必要なので、実データでは `SystemCredential` backend のセッションで実行してください。

### 重要度の構造的計算 (ハイブリッド)

優先度は LLM 任せにせず、**コードが決定的に計算**します。LLM が返すのは依頼度 (`WorkRequest`)・概要・PrivacyLevel だけで、優先度は `SourceVaultMailComputePriority` が次式で算出します。

```
Priority = Clip[senderWeight + 0.30*WorkRequest + posAdj + bulkAdj, {0, 1}]
  posAdj :  To → +0.15 / Cc → 0.0 / Bulk → -0.25
  bulkAdj:  bulk なら -0.15
```

`senderWeight` は、差出人の実体の `PriorityWeight` (数値) → 実体の `Group` に対するグループ重み → 既定 0.4 の順に解決されます。

```wolfram
(* 重要度の内訳 (Components) を確認 *)
SourceVaultMailExplainPriority[snap]

(* グループ重みを登録 (vault config に永続化) *)
SourceVaultSetPriorityGroupWeight["Colleagues", 0.8]
SourceVaultPriorityGroupWeights[]          (* group -> weight *)
SourceVaultGroupWeightFor["Colleagues"]    (* 0.8 *)
```

個別の差出人の `PriorityWeight` や `Group` は、後述の実体編集 UI (`SourceVaultEntityEditUI`) で設定します。

---

## 2層アドレス帳 (identity resolution)

「Uid = 人」という設計は破綻しやすい (同一人物が複数アドレスを持ち、アドレスは後から人に紐付く) ため、SourceVault は **識別子層 (Identifier)** と **実体層 (Entity)** を分離しています。

| 層 | 何を表すか | 作成タイミング |
|---|---|---|
| **第1層 Identifier** | 1つの raw email/SNS/URI | メール取込時に**自動作成** |
| **第2層 Entity** | 人/組織/Bot/ML/サービス | 後から作成・マージ |

オーナー (自分) は **EntityUid=1 / OwnerKind=Self** の特別な実体です。

### 初期化と所有者プロフィール

```wolfram
(* load + self(EntityUid=1) bootstrap (冪等)。初回アクセス時に自動ロードもされる *)
SourceVaultIdentityInitialize[]

(* 所有者プロフィール (派生プロンプトの受信者プロフィールに使われる) *)
SourceVaultSetOwnerLLMProfile["Affiliation, Title, research interests..."]
SourceVaultSetOwnerPrimaryEmail["you@example.org"]

SourceVaultOwnerEntity[]        (* オーナー実体 *)
SourceVaultOwnerEmails[]        (* リンク済み全アドレス *)
SourceVaultOwnerPrimaryEmail[]  (* プライマリメール *)
```

> オーナーの氏名・メール・所属は**ソースにハードコードされていません**。すべてユーザDB #1 (Self 実体) の `Names` / `PrimaryEmail` / `LLMProfile` に保持され、上記のセッターまたは `SourceVaultEntityEditUI[1]` で編集します。

### 識別子と実体の操作

```wolfram
(* 識別子を観測/登録 (メール取込で自動。手動 upsert も可) *)
SourceVaultObserveIdentifier["Email", "alice@example.org",
  "ObservedName" -> "Alice", "Persist" -> True]

(* ヘッダ文字列から全アドレスを識別子化 *)
SourceVaultIngestAddressHeader["Alice <alice@example.org>, bob@example.org"]

SourceVaultGetIdentifier[id]
SourceVaultListIdentifiers[]
SourceVaultFindIdentifier["Email", "alice@example.org"]
SourceVaultResolveIdentifierDisplay[id]   (* 実体名→観測名→raw の順 *)

(* 識別子から新規実体を作成 (観測名を DisplayName に継承) *)
SourceVaultIdentifierCreateEntity[id, "Kind" -> "Person"]

(* 既存実体にアドレスを追加 (マージ/付け替え) *)
SourceVaultLinkIdentifierToEntity[id, "ent-5"]
SourceVaultUnlinkIdentifier[id]

(* 実体の登録・取得・更新 *)
SourceVaultPutEntity[<|"Kind" -> "Organization", "DisplayName" -> "Example Lab"|>]
SourceVaultGetEntity[5]                              (* uid または EntityId *)
SourceVaultListEntities[]
SourceVaultUpdateEntity[5, <|"Group" -> "Colleagues", "PriorityWeight" -> 0.8|>]
```

### 既存メールからの識別子バックフィル

identity 導入前に取り込んだ大量のメールには識別子がありません。`SourceVaultMailStoreLoad[]` で全件ロードしてから次を実行すると、平文ヘッダ (From/To/Cc) を走査して識別子を一括生成します (再取込不要)。

```wolfram
SourceVaultMailStoreLoad[];
SourceVaultIdentityBackfillFromMail[]
```

### identity 関連の UI

```wolfram
SourceVaultAddressBookView[]      (* 連絡先の整形表 *)
SourceVaultIdentityLinkUI[]       (* 未リンク識別子→実体 (新規作成/既存マージ) *)
SourceVaultEntityView[]           (* 実体一覧 + 各行に編集ボタン *)
SourceVaultEntityEditUI[1]        (* 実体1件の編集フォーム (オーナーは uid=1) *)
```

`SourceVaultEntityEditUI` では、表示名 / 種別 (Person/Organization/Bot/MailingList/Service) / 漢字・ローマ字・かな / 分類 / Group / Weight / 所属 (MemberOf) / 信頼状態 / プライマリメール / LLMプロフィール を編集できます。

> **i18n:** UI のラベルは `$Language` で日本語/英語に切り替わります (日本語環境なら日本語、それ以外は英語)。一方、スキーマ・コードのキーは英語固定です。

---

## ファイル構成 (暗号/メール機能)

SourceVault の暗号・メール機能は、本体 `SourceVault.wl` のローダが依存順に Get する **4 つのサブファイル**に集約されています。

| ファイル | 文脈 | 内容 |
|---|---|---|
| `NBAccess_crypto.wl` | `NBAccess\`` | 鍵隔離層 (KeyRef・credential backend)。別文脈なので分離維持 |
| `SourceVault_crypto.wl` | `SourceVault\`` | crypto + keys + keybundle + encryptedstore + release |
| `SourceVault_identity.wl` | `SourceVault\`` | addressbook + senderauth + identity + messagerelease |
| `SourceVault_maildb.wl` | `SourceVault\`` | maildb + imap + mailui |

```
$packageDirectory\
  SourceVault.wl                 ← 本体 (ローダがサブファイルを Get)
  SourceVault_promptrouter.wl    ← PromptRouter 拡張
  NBAccess_crypto.wl             ← 鍵隔離 (NBAccess` 文脈)
  SourceVault_crypto.wl          ← 暗号 + 鍵 + 鍵バンドル + 暗号 record + release
  SourceVault_identity.wl        ← アドレス帳 + 送信者認証 + identity + release plan
  SourceVault_maildb.wl          ← maildb adapter + IMAP + mail UI
  NBAccess.wl / claudecode.wl / ...
```

> 旧来の細分化ファイル (`SourceVault_keys.wl` / `_encryptedstore.wl` / `_addressbook.wl` / `_imap.wl` / `_mailui.wl` など) は上記 4 ファイルに統合済みです。詳細な関数シグネチャは API リファレンス (`api_crypto.md` / `api_identity.md` / `api_maildb.md`) を参照してください。

---

## カテゴリ別リファレンス

### 1. Vault 管理

#### `$SourceVaultVersion`

パッケージのバージョン文字列を返します。

```mathematica
$SourceVaultVersion
(* "2026-05-19-stage-9-p1-step8-nbreadheader-boxdata-filter" など *)
```

---

#### `$SourceVaultRoots`

PrivateVault のルートパスを Association で返します。初回ロード時に自動初期化されます。

```mathematica
$SourceVaultRoots
(* <|"PrivateVault" -> "C:\\Users\\me\\Dropbox\\Mathematica\\PrivateVault"|> *)
```

カスタムパスに変更するには、SourceVault ロード前に手動設定します。

```mathematica
$SourceVaultRoots = <|"PrivateVault" -> "D:\\my-vault"|>;
Needs["SourceVault`", "SourceVault.wl"]
```

---

### 2. Source ingest

#### `SourceVaultIngest`

テキスト / PDF / URL / arXiv ID を first-class source として登録します。

**シグネチャ:**
```mathematica
SourceVaultIngest[path, opts]
```

**例:**

```mathematica
SourceVaultIngest["https://arxiv.org/abs/2401.12345"]

SourceVaultIngest["C:\\path\\to\\paper.pdf",
  "Title" -> "Custom Title", "TrustLevel" -> 0.7]

SourceVaultIngest["arXiv:2401.12345"]
(* shorthand、自動的に URL に正規化 *)
```

戻り値:
```mathematica
<|"Status" -> "OK" | "AlreadyCurrent",
  "SourceId" -> "src-...",
  "SnapshotId" -> "snap-sha256-..."|>
```

---

#### `SourceVaultIndexNotebook`

Mathematica notebook (`.nb`) を first-class source として index します。Header + Todo + Snapshot + Lint を一括生成。

**シグネチャ:**
```mathematica
SourceVaultIndexNotebook[path, opts]
```

**主なオプション:**

| オプション | デフォルト | 内容 |
|---|---|---|
| `"ForceReindex"` | `False` | True なら mtime check をスキップして必ず再 index |
| `"ExtractHeader"` | `True` | Header 抽出を行うか |
| `"ExtractTodos"` | `True` | Todo 抽出を行うか |

**例:**

```mathematica
r = SourceVaultIndexNotebook["C:\\path\\to\\research.nb"];
{r["Cached"], r["TodoCount"], r["OpenTodoCount"]}
(* {False, 5, 2} *)

(* 2 回目は cache hit *)
SourceVaultIndexNotebook["C:\\path\\to\\research.nb"]["Cached"]
(* True *)
```

---

### 3. Context 抽出

#### `SourceVaultSpan`

snapshot 内の参照範囲 (page / byte range) を表す span オブジェクトを構築します。

**シグネチャ:**
```mathematica
SourceVaultSpan[snapshotId, range]
```

**例:**

```mathematica
SourceVaultSpan[sid, {1, 500}]              (* バイト範囲 *)
SourceVaultSpan[sid, "Page" -> 3]            (* ページ番号 *)
SourceVaultSpan[sid, "Pages" -> {3, 5}]      (* 連続ページ *)
```

---

#### `SourceVaultContext`

snapshot から抜粋テキストを取得します。

**シグネチャ:**
```mathematica
SourceVaultContext[snapshotId, range]
SourceVaultContext[span]
```

**例:**

```mathematica
SourceVaultContext[sid, {1, 200}]
SourceVaultContext[SourceVaultSpan[sid, "Page" -> 3]]
```

---

#### `SourceVaultContextAssemble`

複数の span を 1 つの context に結合します。

**シグネチャ:**
```mathematica
SourceVaultContextAssemble[spans]
```

**例:**

```mathematica
spans = {
  SourceVaultSpan[sid1, {1, 500}],
  SourceVaultSpan[sid2, "Page" -> 3]
};
SourceVaultContextAssemble[spans]
```

---

### 4. Notebook semantic API

`NBAccess` パッケージで提供される高レベル semantic API（7 個）。

#### `NBReadHeader`

Notebook の SourceVault Header を 3 経路 fallback で抽出します。

**シグネチャ:**
```mathematica
NBReadHeader[path, opts]
```

**例:**

```mathematica
h = NBReadHeader["C:\\path\\to\\research.nb"];
h["Source"]
(* "TaggingRules" | "HeaderCell" | "BoxData" | "None" *)

h["Keywords"]
(* {"研究テーマ", "進捗管理"} *)
```

---

#### `NBReadTodos`

全 Todo cell を CellGroupData ネスト対応で抽出します (罠 #26 対応)。

**シグネチャ:**
```mathematica
NBReadTodos[path, opts]
```

**例:**

```mathematica
t = NBReadTodos["C:\\path\\to\\research.nb"];
t["Count"]
(* 5 *)

t["Todos"][[1]]["CellPath"]
(* {2, 1, 3} *)
```

---

#### `NBFindCellByPredicate`

任意の述語にマッチする cell を列挙します。

**シグネチャ:**
```mathematica
NBFindCellByPredicate[path, predicate, opts]
```

**例:**

```mathematica
NBFindCellByPredicate["C:\\path\\to\\research.nb",
  Function[c, MatchQ[c[[2]], "Title"]]]
(* <|"Matches" -> {<|"CellPath" -> {1, 1}, "Style" -> "Title", ...|>}|> *)
```

---

#### `SourceVaultMarkTodo`

Todo cell の Status を変更します (`NBWriteTodoStatus` への薄いラッパー)。

**シグネチャ:**
```mathematica
SourceVaultMarkTodo[path, target, newStatus, opts]
```

target は Integer (Index) / String (TodoId) / Association を受け付けます。

**例:**

```mathematica
(* DryRun (default) で Before / After を確認 *)
SourceVaultMarkTodo["C:\\path\\to\\research.nb", 1, "Done"]

(* 実行 (atomic write) *)
SourceVaultMarkTodo["C:\\path\\to\\research.nb", 1, "Done",
  "DryRun" -> False]

(* 最安全: Index + Text 両方一致 *)
SourceVaultMarkTodo["C:\\path\\to\\research.nb",
  <|"Index" -> 1, "Text" -> "参加登録"|>, "Done",
  "DryRun" -> False]
```

---

### 5. Claim 抽出と Bundle

#### `SourceVaultExtract`

LLM で構造化 claim を抽出します。NBAccess の 2 段階 authorization 経由。

**シグネチャ:**
```mathematica
SourceVaultExtract[snapshotId, schema, opts]
```

**例:**

```mathematica
SourceVaultExtract[sid,
  <|"Type" -> "Formula", "Topic" -> "physics"|>]
```

---

#### `SourceVaultBundleCreate`

複数の claim をまとめた Evidence Bundle を作成します。

**シグネチャ:**
```mathematica
SourceVaultBundleCreate[name, claims, opts]
```

**例:**

```mathematica
SourceVaultBundleCreate["projectile-motion-2026",
  {claim1, claim2, claim3}]
```

---

#### `SourceVaultBundleStatus`

Bundle のステータスを返します (lazy passive consumer pattern)。

**シグネチャ:**
```mathematica
SourceVaultBundleStatus[bundleId]
```

`Current` / `Stale` / `NeedsReview` / `Invalidated` のいずれか。

---

### 6. Lifecycle 管理

#### `SourceVaultMarkSnapshotStale`

snapshot を Stale 化し、event log に append します。依存 bundle は lazy に再評価対象になります。

**シグネチャ:**
```mathematica
SourceVaultMarkSnapshotStale[snapshotId, opts]
```

---

#### `SourceVaultInvalidateBundle`

Bundle を手動で Invalidated にします。

**シグネチャ:**
```mathematica
SourceVaultInvalidateBundle[bundleId, opts]
```

---

#### `SourceVaultRefreshSnapshot`

URL/arXiv source を再 fetch して新しい snapshot を作成します (旧 snapshot は Stale 化)。

**シグネチャ:**
```mathematica
SourceVaultRefreshSnapshot[sourceId, opts]
```

---

### 7. クエリ

#### `SourceVaultListSources`

全 source の一覧を返します。

```mathematica
Dataset[SourceVaultListSources[]]
```

---

#### `SourceVaultListSnapshots`

全 snapshot の一覧を返します。

```mathematica
Dataset[SourceVaultListSnapshots["LifecycleStatus" -> "Current"]]
```

---

#### `SourceVaultFindNotebooks`

deterministic な notebook クエリ。

**シグネチャ:**
```mathematica
SourceVaultFindNotebooks[opts]
```

**例:**

```mathematica
SourceVaultFindNotebooks["DeadlineState" -> "Overdue"]
SourceVaultFindNotebooks["OpenTodos" -> True]
SourceVaultFindNotebooks["Keywords" -> "研究テーマ"]
SourceVaultFindNotebooks["NextReviewState" -> "Overdue"]
SourceVaultFindNotebooks["Status" -> "Todo"]
```

---

### 8. Registry

#### `SourceVaultLookup`

Compiled Registry から値を取得します。

```mathematica
SourceVaultLookup["Model", "qwen3-coder-30b"]
```

---

#### `SourceVaultResolve`

Compiled Registry + Seed fallback で最適な値を返します。Availability / Freshness / Class 優先順位 sort。

```mathematica
SourceVaultResolve["Model", "code"]
```

---

#### `ClaudeResolveModel`

`SourceVaultResolve["Model", ...]` の wrapper (旧 `WikiDBResolveModel` 互換)。

```mathematica
ClaudeResolveModel["claudecode", "code"]
```

---

#### `SourceVaultListModels`

指定 provider の選択可能な全モデル ID を列挙します。`SourceVaultResolve` が intent 単位で最適 1 件を返すのに対し、こちらはカタログ全体（重複排除済み）を返します。Compiled Registry 優先・Seed fallback。パレットのモデル選択などで利用します。

```mathematica
SourceVaultListModels["chatgptcodex"]
(* -> {"gpt-5.5", "gpt-5.4", "gpt-5.3-codex", ...} *)
```

---

#### `SourceVaultRefreshModelRegistry`

クラウド (anthropic / openai)・ローカル (LM Studio)・ChatGPT Codex CLI のエンドポイントからモデル一覧を取得し、Compiled Model Registry を更新します。クラウドの API キーは NBAccess 経由で取得し、キーが無い provider はスキップします。ChatGPT Codex は HTTP エンドポイントではなく `codex debug models` コマンドからモデルカタログを取得します（provider 種別 `CodexCLI`）。

```mathematica
(* 全 provider を更新 *)
SourceVaultRefreshModelRegistry[]

(* ChatGPT Codex のみ更新 *)
SourceVaultRefreshModelRegistry["Providers" -> {"chatgptcodex"}]
```

取得したエントリは `Source -> "auto-fetch"` でマークされ、既存の seed / manual エントリは保全してマージされます。`DryRun -> True` で更新せず取得件数のみ確認できます。

---

### 9. メンテナンス

#### `SourceVaultClaimStoreCompact`

claim JSONL を dedup + 圧縮します (`.bak.<timestamp>` を自動生成)。

```mathematica
SourceVaultClaimStoreCompact[]
```

---

#### `SourceVaultNotebookLint`

notebook の lint (7 種) を検出します。

**シグネチャ:**
```mathematica
SourceVaultNotebookLint[record | path]
```

**例:**

```mathematica
SourceVaultNotebookLint["C:\\path\\to\\research.nb"]
(* {"DeadlinePast", "TodoCellStatusHeuristicOnly", "HeaderStatusTodoButNoOpenTodos"} *)
```

7 種の lint:
- `HeaderStatusTodoButNoOpenTodos` — Header Status が Todo なのに Open Todo がない
- `HeaderStatusDoneButOpenTodos` — Header Status が Done なのに Open Todo が残っている
- `DeadlinePast` — Deadline が過去
- `NextReviewPast` — NextReview が過去
- `MissingHeader` — Header が parse できなかった
- `MissingTodos` — TodoItem cell が見つからなかった
- `TodoCellStatusHeuristicOnly` — TaggingRules ベースではなく StrikeThrough heuristic で判定された Todo がある

---

---

## 機能マトリックス

SourceVault が提供する主な機能群です。

```
ingest                      テキスト / PDF / URL / arXiv の取り込み
NBAccess hook P1-P4         ClaudeOrchestrator ワークフローへの source 連携
Context 抽出                span 構築・抜粋・結合
URL / arXiv ingest          リモート source の取り込みと正規化
page extraction + cache     ページ単位のテキスト抽出とキャッシュ
3 OCR backends              PDF の OCR fallback
claim extraction            LLM による構造化 claim 抽出
claim dedup + Compact       claim JSONL の重複排除と圧縮
Compiled Registry           topic 別の値解決 (Lookup / Resolve)
Model Registry              provider 別モデルの一元管理 (ListModels / Refresh)
ChatGPT Codex 対応          codex debug models からのモデルカタログ取得
Evidence Bundle             claim と snapshot の依存記録・lazy 再評価
NBAuthorize 2-stage         claim 抽出の 2 段階 authorization
snapshot lifecycle + diff   Current / Stale / Frozen / Invalidated 管理
Notebook Management         .nb の Header / Todo / Lint / Snapshot 管理
NBAccess semantic API       FrontEnd 不要の .nb 直接編集 (7 API)
SourceVaultMarkTodo         Todo 状態の atomic write
mtime cache                 SourceVaultIndexNotebook の透過的キャッシュ
PromptRouter                ClaudeEval の式提案契約 (未評価式を提案)
TabularQuery / FilterSpec   スケジュールの閉じた DSL による絞り込み
mail subsystem              IMAP 取り込み・暗号化保存・検索・派生・Mail UI
```

`ClaudeEval` から PromptRoute / WorkflowRoute への自動 dispatch は、ClaudeOrchestrator がロード済みのときに有効になります。

---

## 診断コード例

```mathematica
(* バージョン確認 *)
$SourceVaultVersion

(* PrivateVault ルート確認 *)
$SourceVaultRoots["PrivateVault"]

(* NBAccess hook 状態 *)
SourceVaultIntegrationStatus[]

(* 全 source の一覧 *)
Dataset[SourceVaultListSources[]]

(* notebook の index 結果 + cache 確認 *)
r = SourceVaultIndexNotebook[nbPath];
{r["Cached"], r["SourceMTime"], r["Header"]["Source"]}

(* mtime cache が効いていない場合の診断 *)
r2 = SourceVaultIndexNotebook[nbPath, "ForceReindex" -> True];
r2["CacheCheck"]

(* NBAccess semantic API の動作確認 *)
h = NBReadHeader[nbPath];
t = NBReadTodos[nbPath];
{h["Status"], h["Source"], t["Count"]}

(* PromptRouter の提案式を確認 (式は評価されない) *)
p = SourceVaultProposePromptRoute["今日から3日間のスケジュールを"];
{p["Status"], p["ProposedExpression"]}

(* Bundle の status 一覧 *)
Dataset[
  Map[
    Function[bid,
      <|"BundleId" -> bid,
        "Status" -> SourceVaultBundleStatus[bid]|>],
    SourceVaultListBundles[]]]

(* event log の確認 *)
events = ReadByteArray[
  FileNameJoin[{$SourceVaultRoots["PrivateVault"],
    "events", "source-events.jsonl"}]];
Dataset[Map[ImportString[#, "RawJSON"] &,
  StringSplit[ByteArrayToString[events, "UTF-8"], "\n"]]]
```

---

## 関連パッケージ

- [NBAccess](https://github.com/transreal/NBAccess) — ノートブックセル・header / todo の読み書き semantic API、機密データ保持・アクセス可否判定
- [claudecode](https://github.com/transreal/claudecode) — Notebook UI・アダプター実装・LLMGraph DAG スケジューラ・`$Path` 自動設定
- [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime) — LLM ループの進行管理エンジン (`SourceVaultExtract` / `SourceVaultNotebookSummary` の LLM 経路で必要)
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) — タスク分解・マルチエージェント機構 (NBAccess hook で SourceVault と連携可能)
- [ClaudeTestKit](https://github.com/transreal/ClaudeTestKit) — モックプロバイダー・シナリオテスト基盤
- [github](https://github.com/transreal/github) — パッケージのインストール・更新の簡略化