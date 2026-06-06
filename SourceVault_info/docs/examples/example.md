# SourceVault 使用例集

SourceVault パッケージは Claude 系ワークフローで「参照されるソース文書」をハッシュで一意に固定し、必要に応じて prompt や worker に抜粋を渡すための **snapshot 管理レイヤ**です。本ドキュメントは v2026-05-18-stage-3-integrated-p4 (P1〜P4 完全統合版) を前提に、代表的な使用例を順を追って示します。

このドキュメントは大きく 2 部構成です。

- **Part A. 基本機能** — `SourceVaultIngest` で文書を登録し、`SourceVaultSpan` / `SourceVaultContext` / `SourceVaultContextAssemble` で抜粋テキストを取り出すまでの一連の流れを体験します。
- **Part B. ClaudeOrchestrator 統合 (P1〜P4)** — `ClaudeAttach` / `ClaudeAttachments` / Worker prompt 注入 / parseProposal post-processing の 4 つの hook を順に有効化し、LLM ワークフローと SourceVault がどう連携するかを示します。

各例は前の例の結果をそのまま使う前提で書かれています。新規セッションで途中の例から走らせる場合は、依存する例を先に実行してください。

---

## 事前準備

```mathematica
(* メイン: ClaudeRuntime, ClaudeOrchestrator, SourceVault をロード *)
Block[{$CharacterEncoding = "UTF-8"},
  Get[FileNameJoin[{$packageDirectory, "ClaudeRuntime.wl"}]];
  Get[FileNameJoin[{$packageDirectory, "ClaudeOrchestrator.wl"}]];
  Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]];

(* バージョン確認 *)
{$ClaudeOrchestratorVersion,
 SourceVault`$SourceVaultVersion}
```

**期待される出力例:**

```
{"2026-04-28-phase36-lmstudio-worker-async",
 "2026-05-18-stage-3-integrated-p4"}
```

> **メモ:** P1〜P4 の hook を使うには `ClaudeOrchestrator.wl` が **A5 hook + iApplyA6Hook + 3 つの ParseProposal wrap を含む新版** である必要があります。古い版だと SourceVaultWorkerPromptIntegrationEnable / SourceVaultParseProposalIntegrationEnable は登録できても **実 workflow からは呼ばれません**。`Names["ClaudeOrchestrator\`A4InjectDirectivePrefix"]` が空でないかで Phase 34 以降かを確認できます。

---

# Part A. 基本機能 — Ingest から Context 抽出まで

このセクションでは、ローカルファイルを SourceVault に登録し、それを span 化して抜粋を取り出すまでの基本的な流れを体験します。

ストーリー:

> 「ある研究テーマについて 3 つの調査メモ (テキストファイル) を残してある。これらを SourceVault に登録し、ハッシュ識別子を付けて永続化したい。あとで LLM や他のツールにこれらを参照させる。」

---

## 例 A-1: テスト用調査メモを準備

```mathematica
$svExDir = FileNameJoin[{$TemporaryDirectory, "sv-examples"}];
Quiet[CreateDirectory[$svExDir, CreateIntermediateDirectories -> True]];

(* メモ 1: モンテカルロ法に関する調査 *)
note1 = FileNameJoin[{$svExDir, "note1-montecarlo.txt"}];
With[{s = OpenWrite[note1, CharacterEncoding -> "UTF-8"]},
  WriteString[s,
    "調査メモ #1: モンテカルロ法による π 近似\n\n" <>
    "ランダムに [0,1]^2 の点をサンプリングし、単位円内に落ちた割合から π を推定する。\n" <>
    "収束は O(1/sqrt(N)) と遅いが、並列化が容易で実装も単純。\n" <>
    "10万点で π ≈ 3.14 程度の精度が出る。\n"];
  Close[s]];

(* メモ 2: ライプニッツ級数 *)
note2 = FileNameJoin[{$svExDir, "note2-leibniz.txt"}];
With[{s = OpenWrite[note2, CharacterEncoding -> "UTF-8"]},
  WriteString[s,
    "調査メモ #2: ライプニッツ級数による π 近似\n\n" <>
    "π/4 = 1 - 1/3 + 1/5 - 1/7 + ...\n" <>
    "極めて単純だが収束は最遅。100万項で約 6 桁の精度。\n" <>
    "オイラー変換などで劇的に加速できる。\n"];
  Close[s]];

(* メモ 3: Wallis 積 *)
note3 = FileNameJoin[{$svExDir, "note3-wallis.txt"}];
With[{s = OpenWrite[note3, CharacterEncoding -> "UTF-8"]},
  WriteString[s,
    "調査メモ #3: Wallis 積による π 近似\n\n" <>
    "π/2 = (2/1)(2/3)(4/3)(4/5)(6/5)... の無限積。\n" <>
    "ライプニッツ級数より収束は速いが Brent-Salamin や AGM 系には及ばない。\n" <>
    "歴史的興味からの言及が多い。\n"];
  Close[s]];

(* 3 ファイルの存在確認 *)
FileExistsQ /@ {note1, note2, note3}
```

**期待される出力例:** `{True, True, True}`

---

## 例 A-2: SourceVaultIngest で 1 つ目を登録

`SourceVaultIngest[path, Topic -> ..., TrustLevel -> ...]` でファイルを SourceVault に登録します。内容のハッシュが計算され、`snap-sha256-...` という SnapshotId が発行されます。

```mathematica
r1 = SourceVaultIngest[note1,
  Topic -> "PiApproximation",
  TrustLevel -> "LocalFile"];
r1
```

**期待される出力例:**

```
<|"Status"      -> "Ingested",
  "SnapshotId"  -> "snap-sha256-3a7f...",
  "SourceId"    -> "src-local-3a7f...",
  "ContentHash" -> "sha256-3a7f...",
  "Bytes"       -> 174,
  "Topic"       -> "PiApproximation",
  "TrustLevel"  -> "LocalFile"|>
```

```mathematica
snap1 = r1["SnapshotId"];
src1  = r1["SourceId"]
```

**Status の意味:**

- `"Ingested"` — 新規ハッシュとして登録された
- `"AlreadyCurrent"` — 同じ内容が既に登録済み (dedup)
- `"Updated"` — 同じ source path だが内容が変わった (新 snapshot 作成)

---

## 例 A-3: 残り 2 つを登録 + 重複検知

```mathematica
r2 = SourceVaultIngest[note2,
  Topic -> "PiApproximation", TrustLevel -> "LocalFile"];
r3 = SourceVaultIngest[note3,
  Topic -> "PiApproximation", TrustLevel -> "LocalFile"];

{r1["Status"], r2["Status"], r3["Status"]}
```

**期待される出力例:** `{"Ingested", "Ingested", "Ingested"}`

同じファイルを再 ingest すると dedup が働きます。

```mathematica
r1Again = SourceVaultIngest[note1,
  Topic -> "PiApproximation", TrustLevel -> "LocalFile"];
{r1Again["Status"], r1Again["SnapshotId"] === snap1}
```

**期待される出力例:** `{"AlreadyCurrent", True}`

内容が同じなので新規 snapshot は作られず、既存の SnapshotId がそのまま返ります。

---

## 例 A-4: SourceVaultStatus で snapshot 情報を確認

```mathematica
SourceVaultStatus[snap1]
```

**期待される出力例:**

```
<|"SnapshotId"       -> "snap-sha256-3a7f...",
  "SourceId"         -> "src-local-3a7f...",
  "ContentHash"      -> "sha256-3a7f...",
  "Topic"            -> "PiApproximation",
  "TrustLevel"       -> "LocalFile",
  "OriginalPathOrURL"-> "/tmp/sv-examples/note1-montecarlo.txt",
  "Bytes"            -> 174,
  "IngestedAt"       -> "Mon 18 May 2026 ...",
  "LifecycleStatus"  -> "Current",
  "RawPath"          -> "/.../sourcevault/raw/by-hash/sha256-3a7f....txt"|>
```

`LifecycleStatus` が `"Current"` のうちは「pinned」状態で参照できます。同じ path で内容が更新されると古い snapshot は `"Stale"` になりますが、過去の SnapshotId を直接指定すれば引き続き参照できます (immutable snapshot)。

---

## 例 A-5: SourceVaultSpan で span を構築

抜粋を取るために、SnapshotId から `Span Association` を構築します。

```mathematica
span1 = SourceVaultSpan[snap1];
Keys[span1]
```

**期待される出力例:**

```
{"SnapshotId", "SourceId", "Locator", "Role", "Purpose"}
```

`Locator` 内に範囲情報 (Pages、EquationLabels) が入ります。指定しなければ「文書全体」。

```mathematica
span1
```

**期待される出力例:**

```
<|"SnapshotId" -> "snap-sha256-3a7f...",
  "SourceId"   -> "src-local-3a7f...",
  "Locator"    -> <|"Pages" -> All,
                    "EquationLabels" -> Missing["NotSpecified"]|>,
  "Role"       -> "ReferenceContext",
  "Purpose"    -> "Generic"|>
```

特定のページだけ抜き出す例 (PDF 等の場合に有効、テキストファイルでは All のままで使う):

```mathematica
span1Pages = SourceVaultSpan[snap1, "Pages" -> {1}];
span1Pages["Locator"]
```

**期待される出力例:**

```
<|"Pages" -> {1}, "EquationLabels" -> Missing["NotSpecified"]|>
```

> **メモ:** `Options[SourceVaultSpan]` は `{"Pages", "Role", "Purpose", "EquationLabels"}`。`"Lines"` や `"CharOffsets"` といった行・文字単位の範囲指定は現バージョンの API には含まれません (`MaxCharacters` による全体の切り詰めは `SourceVaultContext` 側で指定します)。

---

## 例 A-6: SourceVaultContext で抜粋テキスト

```mathematica
ctx1 = SourceVaultContext[span1, MaxCharacters -> 500];
Keys[ctx1]
```

**期待される出力例:**

```
{"Status", "Text", "Citations", "Freshness", "AccessDecision", "Warnings"}
```

```mathematica
ctx1["Status"]
ctx1["Text"]
```

**期待される出力例:**

```
"OK"

"調査メモ #1: モンテカルロ法による π 近似

ランダムに [0,1]^2 の点をサンプリングし、単位円内に落ちた割合から π を推定する。
収束は O(1/sqrt(N)) と遅いが、並列化が容易で実装も単純。
10万点で π ≈ 3.14 程度の精度が出る。
"
```

```mathematica
(* Citations: どこから来た抜粋かの情報 *)
ctx1["Citations"]
```

**期待される出力例:**

```
{<|"SnapshotId" -> "snap-sha256-3a7f...",
   "SourceId"   -> "src-local-3a7f...",
   "OriginalURI"-> "/tmp/sv-examples/note1-montecarlo.txt"|>}
```

`MaxCharacters` を超えるとテキストが truncate されます。`Freshness` は `"Pinned"` / `"Stale"` で、当該 snapshot が最新かどうかを示します。

---

## 例 A-7: SourceVaultContextAssemble で複数 span を結合

3 つのメモを一括で抜粋し、LLM に渡せる形にまとめます。

```mathematica
spans = SourceVaultSpan /@ {snap1, r2["SnapshotId"], r3["SnapshotId"]};

assembled = SourceVaultContextAssemble[spans,
  MaxCharacters    -> 4000,
  "Purpose"        -> "ComparisonReport",
  "IncludeCitations" -> True];

Keys[assembled]
```

**期待される出力例:**

```
{"Status", "Text", "Parts", "SourceSpans", "Citations",
 "AccessDecisions", "Warnings"}
```

```mathematica
assembled["Status"]
StringLength[assembled["Text"]]
Length[assembled["Citations"]]
Length[assembled["Parts"]]
```

**期待される出力例:**

```
"OK"
540     (* 3 メモの合計文字数 (実値は内容で変わる) *)
3       (* Citations: source 1 件あたり 1 *)
3       (* Parts: 内部 chunk 単位の構造 *)
```

```mathematica
(* Text の先頭 200 字 *)
StringTake[assembled["Text"], UpTo[200]]
```

**期待される出力例:**

```
"<source ix=\"1\" snapshot=\"snap-sha256-3a7f...\">
調査メモ #1: モンテカルロ法による π 近似

ランダムに [0,1]^2 の点をサンプリングし、単位円内に落ちた割合から π を推定する。
収束は O(1/sqrt(N)) と遅いが、並列化が容易で実装も単純。
..."
```

複数 source を統合する場合のセパレータは `"Separators"` オプションで `"ByPage"` / `"ByDocument"` / `"None"` に変更可能です。

> **メモ:** 戻り値のキーは **`"Text"`** (`"AssembledText"` ではない)。`SourceSpans` はリクエストした span の echo、`AccessDecisions` は trust gate の判定結果 (複数 source の access 可否) を保持します。

---

## 例 A-8: List 系 API で全 source / snapshot を俯瞰

```mathematica
(* 全 source ID を取得 *)
SourceVaultList[]
```

**期待される出力例:**

```
{"src-local-3a7f...", "src-local-9b21...", "src-local-c042..."}
```

```mathematica
(* 全 snapshot を取得 (string でも association でも、なんらかの引数を渡せば fall-through で全件) *)
SourceVaultSnapshots["all"]
```

**期待される出力例:**

```
{"snap-sha256-3a7f...", "snap-sha256-9b21...", "snap-sha256-c042..."}
```

```mathematica
(* 特定 source の snapshot 系列 *)
SourceVaultSnapshots[r1["SourceId"]]
```

**期待される出力例:**

```
{"snap-sha256-3a7f..."}   (* この source のすべての snapshot (新しい順) *)
```

```mathematica
(* Vault 全体の俯瞰 *)
SourceVaultStatus[]
```

**期待される出力例:**

```
<|"Roots"          -> <|"PrivateVault" -> "/.../sourcevault", ...|>,
  "SourceCount"    -> 3,
  "SnapshotCount"  -> 3,
  "RawFileCount"   -> 3,
  "RawTotalBytes"  -> 540,
  "Initialized"    -> True|>
```

> **メモ:** 現バージョンの API では:
> - `SourceVaultList[]` (引数なし) → **全 source ID**
> - `SourceVaultSnapshots[srcOrAny]` → src-... 指定なら該当 source の snapshot 系列、それ以外なら全 snapshot を fall-through
> - `SourceVaultStatus[]` → vault 全体の counts、`SourceVaultStatus[snap-...]` → 個別 snapshot の詳細
>
> Topic / TrustLevel でフィルタする統一 API は仕様 v0.13 にはまだ含まれません。必要なら結果を `Select` で絞ってください。

---

## 例 A-9: 内容を変えて再 ingest

note1 を編集して再 ingest すると、内容ハッシュが変わるので **新しい SnapshotId** が発行され、status は `"Updated"` になります (初回追記の場合)。古い snap1 は `"Stale"` 扱いになりますが、SnapshotId を直接指定すれば引き続きアクセスできます (immutable snapshot)。

```mathematica
(* 内容を編集 *)
With[{s = OpenAppend[note1, CharacterEncoding -> "UTF-8"]},
  WriteString[s, "\n追記: 準乱数 (Sobol 列) を使うと低次元では収束が改善。\n"];
  Close[s]];

r1New = SourceVaultIngest[note1,
  Topic -> "PiApproximation", TrustLevel -> "LocalFile"];
r1New["Status"]
```

**期待される出力例:**

```
"Updated"     (* 初回追記の場合 *)
```

> **メモ:** notebook を **複数回** 実行すると、2 回目以降は「同じ追記済みの内容」が既に SourceVault にあるので、status は `"AlreadyCurrent"` が返ります (`r1New["SnapshotId"]` は前回ノブの新 snapshot と同じ)。実装は内容ハッシュベース dedup なので、これは正しい振る舞いです。例 A-1 でファイルを再生成しているため、内容が前回と完全に同じなら何回 ingest しても `AlreadyCurrent` です。

```mathematica
(* SnapshotId と lifecycle を確認 *)
snap1New = r1New["SnapshotId"];
{snap1, snap1New, snap1 === snap1New}
```

**期待される出力例:**

```
{"snap-sha256-3a7f...",    (* 元 snap1 *)
 "snap-sha256-7e44...",    (* 編集後の新 snap *)
 False}                     (* 別物 *)
```

```mathematica
(* 古い snap1 と新 snap1New の LifecycleStatus を比べる *)
{SourceVaultStatus[snap1]["LifecycleStatus"],
 SourceVaultStatus[snap1New]["LifecycleStatus"]}
```

**期待される出力例:** `{"Stale", "Current"}`

最新 snapshot を Source 単位で取得するには `SourceVaultSpan["src-..."]` を使います。`SourceId` も内容ハッシュベース (`iMakeSourceId["local", hash[1..12]]`) なので、内容が変わると `SourceId` も変わります。

---

## 例 A-10: 内容ハッシュベース dedup の挙動

実装上、`SnapshotId` も `SourceId` も**両方とも内容ハッシュベース**で計算されます。

- `SnapshotId` = `"snap-sha256-"` + 完全 SHA-256 ハッシュ
- `SourceId` = `"src-"` + provenance type (`local` / `remote` 等) + `-` + ハッシュ先頭 12 文字

したがって:

- **同じ内容のファイル** → SnapshotId / SourceId とも同じ
- **異なる内容** → どちらも異なる

最も確実な確認方法は、同じファイルを再 ingest することです (例 A-3 でも実演済み):

```mathematica
rDedup = SourceVaultIngest[note1,
  Topic -> "PiApproximation", TrustLevel -> "LocalFile"];

{rDedup["Status"],
 rDedup["SnapshotId"] === r1New["SnapshotId"],
 rDedup["SourceId"]   === r1New["SourceId"]}
```

**期待される出力例:** `{"AlreadyCurrent", True, True}`

これによりディスク容量と LLM トークンを節約できます。

> **メモ:** `CopyFile` で別 path にコピーして ingest しても理論的には同じ SnapshotId が返るはずですが、OS や Mathematica の I/O 層でバイト列 (改行コードや BOM) が変換されることがあり、内容ハッシュが一致しない可能性があります。再現性の高いテストには上記のような **同一 path での再 ingest** が安全です。

---

# Part B. ClaudeOrchestrator 統合 (P1〜P4)

このセクションでは、Part A で登録した snapshot を ClaudeOrchestrator ワークフローと組み合わせて使う流れを示します。SourceVault は 4 つの hook (P1〜P4) で ClaudeCode / ClaudeOrchestrator の既存 API に**互換性を保ったまま**機能を追加できます。

| Patch | フック対象 | 効果 |
|---|---|---|
| **P1** | `ClaudeCode\`ClaudeAttach` | notebook に attach した瞬間に SourceVault へも自動 ingest |
| **P2** | `ClaudeCode\`ClaudeAttachments` | 戻り値が `Path` のリストから **Association list** (`SnapshotId` 含む) に拡張 |
| **P3** | ClaudeOrchestrator `A5InjectSourceVaultContext` | worker prompt の冒頭に `<attached-documents>抜粋テキスト</attached-documents>` を自動注入 (「依存 artifact 相当」として扱う旨の指示文を含む) |
| **P4** | ClaudeOrchestrator `A6PostProcessParseProposal` | LLM 応答内の `<source>snap-...</source>` XML タグを抽出して `result["SourceVaultRefs"]` に格納 |

ストーリー (Part A の続き):

> 「3 つの π 近似メモを `ClaudeAttach` で notebook に添付し、ClaudeOrchestrator で worker を 1 つ起動して比較レポートを書かせる。worker prompt には添付メモの内容が自動的に含まれてほしい。」

---

## 例 B-1: SourceVaultClaudeAttachIntegrationEnable (P1)

`ClaudeAttach[path]` を呼ぶと、本来の attachment 動作 (notebook の TaggingRule に cached path を記録) **に加えて**、SourceVault へも自動的に ingest される hook を有効化します。

```mathematica
SourceVaultClaudeAttachIntegrationEnable[]
```

**期待される出力例:**

```
[SourceVault] ClaudeAttach hook 有効化。

<|"Status" -> "Enabled", "OriginalDVCount" -> 2|>
```

`OriginalDVCount` は元の `ClaudeAttach` の DownValue 数。`Disable` 時にここに戻ります。

```mathematica
SourceVaultClaudeAttachIntegrationStatus[]
```

**期待される出力例:**

```
<|"Enabled" -> True,
  "OriginalSaved"    -> True,
  "OriginalDVCount"  -> 2,
  "HookTarget"       -> "ClaudeCode`ClaudeAttach"|>
```

---

## 例 B-2: ClaudeAttach 経由で 3 メモを添付

P1 hook が動作している間に `ClaudeAttach` を呼ぶと、cached path 確保 + TaggingRule 更新の通常動作に加えて、SourceVault `Ingest` が走り、結果が notebook の TaggingRule `claudeAttachSourceVaultRefs` にも記録されます。

```mathematica
nb = EvaluationNotebook[];

ClaudeAttach[note1];
ClaudeAttach[note2];
ClaudeAttach[note3];

(* 添付された cached path の一覧 (P1 hook が active なので String paths のまま) *)
ClaudeAttachments[]
```

**期待される出力例:**

```
{"/.../claude_attachments/note1-montecarlo.NNNNNNNN.txt",
 "/.../claude_attachments/note2-leibniz.MMMMMMMM.txt",
 "/.../claude_attachments/note3-wallis.PPPPPPPP.txt"}
```

> **メモ:** この時点では P2 hook はまだ無効なので、`ClaudeAttachments[]` は従来の **String paths のリスト**を返します。

---

## 例 B-3: SourceVaultGetClaudeAttachRefs で ingest 履歴

notebook の TaggingRule に記録された P1 ingest の履歴を取り出します。

```mathematica
refs = SourceVaultGetClaudeAttachRefs[nb];
Length[refs]
```

**期待される出力例:** `3`

```mathematica
First[refs]
```

**期待される出力例:**

```
<|"OriginalPathOrURL" -> "/tmp/sv-examples/note1-montecarlo.txt",
  "ExpandedPath"      -> "/tmp/sv-examples/note1-montecarlo.txt",
  "SnapshotId"        -> "snap-sha256-7e44...",
  "SourceId"          -> "src-local-3a7f...",
  "ContentHash"       -> "sha256-7e44...",
  "IngestStatus"      -> "AlreadyCurrent",
  "AttachedAt"        -> "Mon 18 May 2026 ..."|>
```

`IngestStatus` が `AlreadyCurrent` なのは、例 A-9 で既に ingest 済みのため。dedup が効いて再度 disk 書き込みは発生しません。

---

## 例 B-4: SourceVaultClaudeAttachmentsIntegrationEnable (P2)

`ClaudeAttachments[]` の戻り値を `List of String paths` から **Association list** (metadata + SourceVault 紐付け情報) に拡張します。

```mathematica
SourceVaultClaudeAttachmentsIntegrationEnable[]
```

**期待される出力例:**

```
[SourceVault] ClaudeAttachments hook 有効化。
  ClaudeAttachments[] / ClaudeAttachments[session] は Association list を返すようになる。
  各 entry: Path, DisplayName, Source, Keywords, Title, CachedAt,
              SnapshotId, SourceId, ContentHash, IngestStatus, AttachedAt
  無効化: SourceVaultClaudeAttachmentsIntegrationDisable[]

<|"Status" -> "Enabled", "OriginalDVCount" -> 2|>
```

```mathematica
attachments = ClaudeAttachments[];
Length[attachments]
Keys[First[attachments]]
```

**期待される出力例:**

```
3
{"Path", "DisplayName", "Source", "Keywords", "Title", "CachedAt",
 "FileExists", "ByteCount",
 "SnapshotId", "SourceId", "ContentHash", "IngestStatus", "AttachedAt"}
```

```mathematica
First[attachments]
```

**期待される出力例:**

```
<|"Path"        -> "/.../claude_attachments/note1-montecarlo.NNNNNNNN.txt",
  "DisplayName" -> "note1-montecarlo.NNNNNNNN.txt",
  "Source"      -> "/tmp/sv-examples/note1-montecarlo.txt",
  "Keywords"    -> {},
  "Title"       -> "note1-montecarlo.txt",
  "CachedAt"    -> "Mon 18 May 2026 ...",
  "FileExists"  -> True,
  "ByteCount"   -> 218,
  "SnapshotId"  -> "snap-sha256-7e44...",
  "SourceId"    -> "src-local-3a7f...",
  "ContentHash" -> "sha256-7e44...",
  "IngestStatus"-> "AlreadyCurrent",
  "AttachedAt"  -> "Mon 18 May 2026 ..."|>
```

通常の `metadata` 部分 (`Path` 〜 `ByteCount`) は claudecode の `_meta.json` を直接読んで取得しており、Private シンボル経由ではないので Imai 環境特有の "Private 不可視問題" の影響を受けません。

---

## 例 B-5: SourceVaultWorkerPromptIntegrationEnable (P3)

ClaudeOrchestrator の `iWorkerBuildSystemPrompt` 内の A5 hook を経由して、worker prompt に SourceVault 抜粋テキストを注入する hook を有効化します。

```mathematica
SourceVaultWorkerPromptIntegrationEnable[]
```

**期待される出力例:**

```
[SourceVault] WorkerPrompt hook 有効化。
  ClaudeOrchestrator の A5 hook に SourceVault context 注入関数を登録済み。
  明示指定:  task["SourceSpans"] = {SnapshotId or Span Assoc, ...}
  自動検出:  $SourceVaultWorkerPromptAutoDetect = True
  無効化:    SourceVaultWorkerPromptIntegrationDisable[]

<|"Status" -> "Enabled", "AutoDetect" -> True|>
```

A5 hook の動作には 3 つの sources 入口があります:

1. **明示指定**: `task["SourceSpans"] = {"snap-...", ...}`
2. **propagated** (P4 連携): `task["SourceVaultRefs"]` (前ターンの parseProposal が抽出したもの)
3. **自動検出**: `ClaudeAttach` 履歴 (`$SourceVaultWorkerPromptAutoDetect = True` 時)。検出経路は二段階:
   - **(A) Notebook TaggingRule** から `SourceVaultGetClaudeAttachRefs[EvaluationNotebook[]]` で取得
   - **(B) メモリレジストリ `$LastAttachedRefs`** — ClaudeOrchestrator の DAG worker のように **scheduled task コンテキストで `EvaluationNotebook[]` が Front End notebook を見られない**ケースのための fallback。P1 hook の side-channel ingest が attach 時に notebook と並行して記録します。

これらを `DeleteDuplicates` で merge し、各 SnapshotId に対して `SourceVaultContext` で抜粋を取得、`<attached-documents>...</attached-documents>` セクションに整形します。注入方式は **2 段階フォールバック**:

1. **(優先) ClaudeOrchestrator template の `{{DEPENDENCY_SECTION}}` ラベル置換** — worker prompt 中に `"依存 artifact なし。"` または `"No dependency artifacts."` の文字列が見つかれば、その位置を `<attached-documents>` セクションで**置換**します。これにより LLM は「依存 artifact = 添付ドキュメント」と素直に解釈し、「依存 artifact が渡されていない」と誤判断するのを防げます。
2. **(fallback) prompt 冒頭への prepend** — DEPENDENCY_SECTION ラベルが見つからない経路 (例: B-6 で `<||>` 空 task を渡した時、または既に依存 artifact がある場合) は、従来通り prompt の前に prepend します。

LLM 側が「これは sources であって依存 artifact ではない」と切り分けてしまわないよう、セクション冒頭に「依存 artifact 相当として扱ってください」という明示的指示文 (HTML コメント形式) も含めて注入します。

---

## 例 B-6: A5 hook を直接呼んで動作を確認

> **重要:** 例 B-6 を実行する前に **必ず例 B-5 (`SourceVaultWorkerPromptIntegrationEnable[]`) を実行**してください。これが呼ばれていないと、以下の `ClaudeOrchestrator\`A5InjectSourceVaultContext[...]` は **未評価のまま** 残り、`StringLength` などが「文字列ではない」というエラーを出します。実行済みであることは `SourceVaultWorkerPromptIntegrationStatus[]["Enabled"]` が `True` になっているかで確認できます。

実際の worker workflow を起動する前に、A5 hook 関数を直接呼んで挙動を確認できます。

```mathematica
basePrompt = "You are a worker. Compare the three π approximation methods\n" <>
             "and produce a brief summary.";

(* 空 task → 自動検出が ClaudeAttach 履歴の 3 snapshot を拾う *)
hookedPrompt = ClaudeOrchestrator`A5InjectSourceVaultContext[
  basePrompt, "worker", <||>];

StringLength /@ {basePrompt, hookedPrompt}
```

**期待される出力例:**

```
{88, 720}   (* basePrompt 88 字 → hookedPrompt 720 字 (実数値は内容とタグ長さで変わる)
              ここは空 task (<||>) を渡したので DEPENDENCY_SECTION ラベルが
              prompt に含まれず、fallback の prepend 経路が動く *)
```

```mathematica
(* hooked prompt 冒頭の attached-documents セクションを覗く *)
StringTake[hookedPrompt, UpTo[500]]
```

**期待される出力例:**

```
"<attached-documents count=\"3\">
<!-- 以下は worker タスクが参照すべき本文 (依存 artifact 相当)。Goal 達成にはこれらの内容を必ず参照し、詳細データが「実体」としてここに存在していると見なしてください。 -->
<document index=\"1\">
調査メモ #1: モンテカルロ法による π 近似

ランダムに [0,1]^2 の点をサンプリングし、...
</document>
<document index=\"2\">
調査メモ #2: ライプニッツ級数による π 近似

π/4 = 1 - 1/3 + 1/5 - 1/7 + ...
..."
```

> **メモ:** v2026-05-18 から、注入セクションのタグは `<sources>` ではなく **`<attached-documents>`** になり、LLM への明示的指示「依存 artifact 相当として扱う」を含むコメントが追加されています。これは ClaudeOrchestrator の worker template に `{{DEPENDENCY_SECTION}}` ("依存 artifact なし") が含まれる場合、LLM が `<sources>` と「依存 artifact」を別物と切り分けて応答する不具合への対策です。

明示指定で特定の snapshot だけ注入する例:

```mathematica
explicitPrompt = ClaudeOrchestrator`A5InjectSourceVaultContext[
  basePrompt, "worker",
  <|"SourceSpans" -> {snap1}|>];

StringContainsQ[explicitPrompt, "モンテカルロ"]
StringContainsQ[explicitPrompt, "ライプニッツ"]
```

**期待される出力例:**

```
True
False  (* 自動検出を off にしていなくても、明示指定で snap1 のみ → ただし auto も merge されて含まれる *)
```

`$SourceVaultWorkerPromptAutoDetect = False` にすれば明示指定のみになります:

```mathematica
$SourceVaultWorkerPromptAutoDetect = False;

onlySnap1Prompt = ClaudeOrchestrator`A5InjectSourceVaultContext[
  basePrompt, "worker",
  <|"SourceSpans" -> {snap1}|>];

{StringContainsQ[onlySnap1Prompt, "モンテカルロ"],
 StringContainsQ[onlySnap1Prompt, "ライプニッツ"]}

$SourceVaultWorkerPromptAutoDetect = True;   (* 元に戻す *)
```

**期待される出力例:** `{True, False}`

---

## 例 B-7: SourceVaultParseProposalIntegrationEnable (P4)

LLM 応答内に `<source>snap-...</source>` や `<source>src-...</source>` XML タグがあれば、parseProposal の戻り値に `SourceVaultRefs` キーが自動的に追加されるよう、A6 hook を有効化します。

```mathematica
SourceVaultParseProposalIntegrationEnable[]
```

**期待される出力例:**

```
[SourceVault] ParseProposal hook 有効化。
  ClaudeOrchestrator の A6 hook に parseProposal post-processing を登録済み。
  抽出 syntax: <source>snap-...</source> / <source>src-...</source>
  抽出結果は result["SourceVaultRefs"] に追加される。

<|"Status" -> "Enabled"|>
```

```mathematica
SourceVaultParseProposalIntegrationStatus[]
```

**期待される出力例:**

```
<|"Enabled"             -> True,
  "HookTarget"          -> "ClaudeOrchestrator`A6PostProcessParseProposal",
  "HookFunctionDefined" -> True,
  "DetectionPattern"    -> "<source>snap-...|src-...</source>"|>
```

---

## 例 B-8: A6 hook を直接呼んで抽出動作を確認

LLM が以下のような応答を返した場合を想定:

```mathematica
mockLLMResponse =
  "結論として、モンテカルロ法 (<source>" <> snap1 <> "</source>) は\n" <>
  "並列性で優位だが収束が遅い。Wallis 積 (<source>" <> r3["SnapshotId"] <> "</source>) は\n" <>
  "歴史的興味の範囲にとどまる。";

(* base mock の ParseProposal Function を直接呼ぶ *)
mockResult = <|"HeldExpr"        -> HoldComplete[True],
               "TextResponse"    -> mockLLMResponse,
               "HasProposal"     -> True,
               "ArtifactPayload" -> <|"Summary" -> mockLLMResponse|>|>;

(* iApplyA6Hook を経由 *)
hooked = ClaudeOrchestrator`Private`iApplyA6Hook[mockResult, mockLLMResponse];

Keys[hooked]
hooked["SourceVaultRefs"]
```

**期待される出力例:**

```
{"HeldExpr", "TextResponse", "HasProposal", "ArtifactPayload", "SourceVaultRefs"}

{"snap-sha256-7e44...", "snap-sha256-c042..."}
```

`<source>...</source>` 内に同じ ID が複数回現れても `DeleteDuplicates` されます。タグが 1 つも見つからなければ `SourceVaultRefs` キーは追加されず、戻り値は元の `result` のまま (no-op)。

---

## 例 B-9: P3 ↔ P4 連携 (use-case C)

P4 で抽出した `SourceVaultRefs` を次ターンの task に伝搬すると、P3 (A5 hook) がそれを自動的に sources に加えて prompt に注入します。

```mathematica
(* ターン 1: LLM が <source>snap-...</source> を含む応答を返した *)
turn1Refs = hooked["SourceVaultRefs"];

(* ターン 2 の task spec に伝搬 (caller 側の責務) *)
turn2Task = <|"Goal" -> "前回参照した手法をさらに掘り下げて比較",
              "SourceVaultRefs" -> turn1Refs|>;

(* P3 の A5 hook は task["SourceVaultRefs"] も sources として拾う *)
$SourceVaultWorkerPromptAutoDetect = False;  (* 純粋に propagated だけで試す *)

turn2Prompt = ClaudeOrchestrator`A5InjectSourceVaultContext[
  "Refine the comparison further.", "worker", turn2Task];

(* turn1 で参照された 2 snapshot の中身が turn2 prompt に含まれている *)
{StringContainsQ[turn2Prompt, "モンテカルロ"],
 StringContainsQ[turn2Prompt, "Wallis"]}

$SourceVaultWorkerPromptAutoDetect = True;
```

**期待される出力例:** `{True, True}`

この流れにより:

```
[LLM ターン 1] 応答に <source>snap-...</source> を含める
   ↓ parseProposal (A6 hook)
result["SourceVaultRefs"] = {"snap-...", ...}
   ↓ caller が turn 2 の task に伝搬
task["SourceVaultRefs"] = {"snap-...", ...}
   ↓ ClaudeOrchestrator の iWorkerBuildSystemPrompt (A5 hook)
turn 2 worker prompt に <attached-documents>抜粋</attached-documents> を prepend
```

「LLM が参照した文書を、次ターンでも prompt に含めて流れを継続する」という長期参照ループが構築できます。

---

## 例 B-10: 実 ClaudeOrchestrator ワークフローでの動作

A5/A6 hook が組み込まれた本物の ClaudeOrchestrator workflow を回す例。

```mathematica
$ClaudeOrchestratorRealLLMEndpoint = "ClaudeCode";   (* または "Anthropic" *)

(* π 近似の比較を依頼。SourceVault 添付メモが自動検出経由で含まれる *)
jobId = ClaudeRunOrchestrationAsync[
  "3 つの π 近似メモの内容を比較し、強みと弱みを表でまとめる",
  MaxTasks -> 2];

ClaudeOrchestrationWait[jobId, 60];

res = ClaudeOrchestrationResult[jobId];
res[["Status"]]
```

**期待される出力例:** `"Done"` (mock worker adapter で完走した場合)

> **メモ:** ClaudeOrchestrator のステータス遷移は `"Planning"` → `"Spawning"` → `"Reducing"` → `"Committing"` → **`"Done"`** です (`"Complete"` ではなく `"Done"`)。失敗時は `"SpawnFailed"` / `"ReduceFailed"` / `"CommitFailed"` 等が入ります。

```mathematica
(* Worker が出力した artifact を覗く *)
firstArtifact = First @ res[["SpawnResult", "Artifacts"]];
Lookup[firstArtifact["Payload"], "Summary", ""] // StringTake[#, UpTo[400]] &
```

**期待される出力例 (mock worker の場合):**

```
"[stub worker response for t1]"
```

mock worker は stub 応答を返すだけで、SourceVault 抜粋が prompt に注入されても LLM が読まないため反映されません。**実 LLM を使うには `WorkerAdapterBuilder -> "LLM"` を明示指定**します:

```mathematica
jobId = ClaudeRunOrchestrationAsync[
  "3 つの π 近似メモの内容を比較し、強みと弱みを表でまとめる",
  MaxTasks -> 2,
  "WorkerAdapterBuilder" -> "LLM",     (* 実 LLM Worker adapter *)
  Model -> "claude-opus-4-7"];          (* または "claude-sonnet-4-6" *)

ClaudeOrchestrationWait[jobId, 120];
res = ClaudeOrchestrationResult[jobId];
firstArtifact = First @ res[["SpawnResult", "Artifacts"]];
Lookup[firstArtifact["Payload"], "Summary", ""] // StringTake[#, UpTo[400]] &
```

**期待される出力例 (実 LLM の場合):**

```
"3 つの π 近似手法を比較した結果は以下の通り:

| 手法 | 収束速度 | 並列性 | 実装複雑度 |
|---|---|---|---|
| モンテカルロ法 | O(1/sqrt(N)) | 高 | 単純 |
| ライプニッツ級数 | 最遅 | 中 | 極めて単純 |
| Wallis 積 | 中 | 中 | 単純 |

詳細は <source>snap-sha256-7e44...</source> を参照。"
```

worker prompt に **SourceVault 抜粋が自動で含まれた**ため、LLM がメモ本体を参照できた。レスポンスに `<source>...</source>` が含まれていれば、P4 が次ターン用に refs を抽出します。

### LLM 応答に「依存 artifact が渡されていない」と書かれる場合

ClaudeOrchestrator の worker template には `{{DEPENDENCY_SECTION}}` セクションがあり、依存 artifact がない場合 `"依存 artifact なし。"` という文字列が埋め込まれます。SourceVault の A5 hook が `<attached-documents>` セクションを `{{DEPENDENCY_SECTION}}` ラベル位置で**置換**することで、LLM はこれを「依存 artifact = 添付ドキュメントの内容」と解釈し、本文を実体として参照します。

ただし、ClaudeOrchestrator の template ラベル文言が変更されると置換パターンが追従できず、フォールバックの prepend 動作になります。その場合 LLM が「(prompt 末尾の) 依存 artifact なし」を信じて応答することがあります。動作確認:

```mathematica
(* worker に渡される prompt を直接確認: 「依存 artifact なし。」が残っていなければ置換 OK、
   残っていれば置換パターンが update されている可能性 *)
testTask = <|"Goal" -> "test"|>;
testPrompt = "
GOAL: {test}

依存 artifact なし。

other";
ClaudeOrchestrator`A5InjectSourceVaultContext[testPrompt, "worker", testTask]
(* 期待: 「依存 artifact なし。」が <attached-documents>...</attached-documents> で置換される *)
```

### 実 LLM 呼び出しで Summary が空 (`""`) になる場合の診断

`$ClaudeOrchestratorRealLLMEndpoint`, `WorkerAdapterBuilder`, `Model` の組み合わせや LLM CLI/API の応答状況によって、worker artifact の Payload に `Summary` キーが入らないことがあります。診断ステップ:

```mathematica
(* Step 1: Status は Done か? *)
res[["Status"]]
(* Done なら spawn 〜 commit まで形上は完了。それ以外なら SpawnFailed / ReduceFailed 等 *)

(* Step 2: artifact の中身 *)
firstArtifact = First @ res[["SpawnResult", "Artifacts"]];
firstArtifact
(* 戻り値: TaskId, ArtifactType, Payload (keys 不定), Worker, Status etc *)

(* Step 3: Payload のキーを覗く *)
Keys @ firstArtifact["Payload"]
(* "Summary" が無く "RawResponse" / "Error" / "Output" などしか入っていない場合あり *)

(* Step 4: 実 LLM 呼び出しが行われたか (LLM 呼び出しログを観察) *)
ClaudeOrchestrator`$LastWorkerRawResponse   (* 実装によりキー名は変動 *)
```

> **メモ:**
> - `Model -> "claude-opus-4-7"` は ClaudeCode CLI provider の文字列。`$ClaudeOrchestratorRealLLMEndpoint` を `"Anthropic"` にする場合は API モデル名 (例: `"claude-opus-4-20250514"`) が必要なことがある。
> - 環境次第で worker LLM の応答が空になることがある (CLI 起動失敗、認証切れ、レート制限など)。SourceVault hook 自体は **prompt 構築段階で抜粋を注入することのみ責任**を持ち、LLM 応答品質には関与しません。
> - hook が正しく注入しているかは例 B-6 (`A5InjectSourceVaultContext` を直接呼ぶ) で確認可能です。これが OK で B-10 の Summary だけ空なら、原因は ClaudeOrchestrator / LLM 側にあります。

> **メモ:** mock worker (デフォルト) は SourceVault 抜粋を prompt にもらっても無視するので、A5/A6 hook の効果を最終出力で確認するには実 LLM endpoint + `WorkerAdapterBuilder -> "LLM"` が必須です。A5 hook が prompt 構築段階で抜粋を注入していること自体は例 B-6 で直接確認できます。

---

## 例 B-11: 一括 disable と cleanup

全 hook を一括で無効化する場合:

```mathematica
SourceVaultParseProposalIntegrationDisable[];     (* P4 *)
SourceVaultWorkerPromptIntegrationDisable[];      (* P3 *)
SourceVaultClaudeAttachmentsIntegrationDisable[]; (* P2 *)
SourceVaultClaudeAttachIntegrationDisable[];      (* P1 *)

{SourceVaultClaudeAttachIntegrationStatus[]["Enabled"],
 SourceVaultClaudeAttachmentsIntegrationStatus[]["Enabled"],
 SourceVaultWorkerPromptIntegrationStatus[]["Enabled"],
 SourceVaultParseProposalIntegrationStatus[]["Enabled"]}
```

**期待される出力例:** `{False, False, False, False}`

各 hook の Disable は冪等で、未 enable 状態で呼んでも安全 (no-op)。

```mathematica
(* テストファイルとサンプル directory を破棄 *)
Quiet[DeleteDirectory[$svExDir, DeleteContents -> True]];
```

ただし SourceVault の `raw/`, `meta/`, `logs/` 階層に登録された snapshot は残ります (永続化が目的なので)。これらをクリアするには SourceVault の管理 API (例: `SourceVaultPurgeStaleSnapshots`) を使うか、`$SourceVaultRoot` を手動で削除します。

---

# Part C. URL / arXiv ingest (Stage 4 Phase 4A)

Phase 4A から、ローカルファイルだけでなく **HTTPS URL や arXiv ID** を直接 ingest できます。Phase 4A は同期 fetch のみ (`Asynchronous -> False` がデフォルト)。`Asynchronous -> True` の LLMGraphDAG-based async 実装は Phase 4A-async で追加予定。

## 例 C-1: HTTPS URL から ingest (公式ドキュメント)

公式ドキュメント (Wolfram Reference 等) を直接 ingest します。`TrustLevel` は自動推定:

```mathematica
res = SourceVaultIngest["https://reference.wolfram.com/language/ref/NDSolve.html"];
res["Status"]
res["TrustLevel"]
res["SourceId"]
res["SnapshotId"]
```

**期待される出力例:**

```
"Ingested"
"OfficialDocs"     (* reference.wolfram.com → 自動 OfficialDocs *)
"src-url-5ebd8bac099a"   (* URL の SHA-256 先頭 12 桁 (実値は URL により異なる) *)
"snap-sha256-..."
```

`iAutoTrustLevel` は以下のホストを自動認識します:

| カテゴリ | 例 |
|---|---|
| **OfficialAPI** | `api.anthropic.com/...`, `api.openai.com/...`, `generativelanguage.googleapis.com/...` |
| **OfficialDocs** | `docs.anthropic.com`, `platform.openai.com/docs`, `reference.wolfram.com`, `arxiv.org`, `developer.mozilla.org`, `docs.python.org`, `en.wikipedia.org`, `ai.google.dev` |
| **PublicWeb** | その他 `https://...` / `http://...` |

明示指定で上書きする場合は `TrustLevel -> "PublicWeb"` 等を渡します。

## 例 C-2: arXiv ID で ingest (shorthand)

```mathematica
(* "arXiv:" prefix → 内部で https://arxiv.org/pdf/...pdf に canonicalize *)
res = SourceVaultIngest["arXiv:1706.03762"];   (* Attention Is All You Need *)
res["Status"]
res["URL"]
res["SourceId"]
```

**期待される出力例:**

```
"Ingested"
"https://arxiv.org/pdf/1706.03762.pdf"
"src-arxiv-1706.03762"
```

`arxiv:` で始まる ref は `iCanonicalizeURL` が `https://arxiv.org/pdf/<id>.pdf` に変換します。`SourceId` は arXiv ID ベース (`.` は保持) で **content hash に依存せず**安定化されるので、同じ論文の再 ingest は同じ `SourceId` を返します。

## 例 C-3: arXiv version-pinned

```mathematica
res = SourceVaultIngest["arXiv:1706.03762v5"];
res["URL"]
res["Status"]
```

**期待される出力例:**

```
"https://arxiv.org/pdf/1706.03762v5.pdf"
"Ingested"
```

v3 と v5 は別 ID として独立して保存されるので、版固定の比較分析に利用できます (Stage 5 Claim extraction の前提)。

## 例 C-4: 重複 ingest → AlreadyCurrent

```mathematica
res1 = SourceVaultIngest["arXiv:1706.03762"];
res2 = SourceVaultIngest["arXiv:1706.03762"];   (* 同じ URL 再 ingest *)
{res1["Status"], res2["Status"]}
{res1["SnapshotId"] === res2["SnapshotId"]}
```

**期待される出力例:**

```
{"Ingested", "AlreadyCurrent"}
{True}
```

**2 段階 dedup** が動作します:

1. **URL レベル dedup** (Phase 4A で追加): 同じ canonical URL を再 ingest した時、その URL から決まる `SourceId` の最新 snapshot が `LifecycleStatus -> "Current"` で raw ファイルが存在すれば、**fetch せずに** `"AlreadyCurrent"` で返します。これにより `arxiv.org` のように **同じ PDF URL でも HTTP response の bytes が毎回微妙に変わる** (timestamp 等が混入する) サーバでも、不要な re-fetch と新 snapshot 作成を防げます。
2. **Content hash dedup**: URL レベル dedup を抜けて新 fetch した場合でも、その content hash が既存 snapshot と一致すれば `"AlreadyCurrent"` を返します (異なる URL からたまたま同じ content が来た場合等)。

ローカルファイルの場合は content が安定なので content hash dedup だけで十分ですが、URL ソースでは URL レベルの安定 SourceId (arXiv ID または canonical URL の hash) が必須です。

## 例 C-5: TrustLevel 明示指定

```mathematica
(* 自動推定では "PublicWeb" だが、ユーザが信頼する個人ブログ等 *)
res = SourceVaultIngest["https://example.com/",
  TrustLevel -> "OfficialDocs",
  PrivacyLabel -> 0.5,
  Topic -> "personal-bookmark"];
{res["Status"], res["TrustLevel"]}
```

**期待される出力例:**

```
{"Ingested", "OfficialDocs"}
```

> **注:** `https://example.com/` は IANA 管理の公式テスト用ドメインで 200 OK を返します。`example.com/some-path` のような **存在しない** path を指定すると 404 になり `{"Failed", "HTTPError"}` が返ります (C-7 参照)。

## 例 C-6: ClaudeAttach で URL を添付 → P3 で worker prompt に注入

P1 hook が有効なら、`ClaudeAttach["arXiv:..."]` のように **URL / arXiv 文字列を引数に取れます**。`ClaudeAttach` 本体はローカルファイルのみ受け付ける仕様ですが、SourceVault P1 hook が **URL/arXiv 専用ブランチ** を提供します:

- ローカルファイル: 従来通り `ClaudeAttach` 本体 (ファイル添付) + SourceVault 経由の side-channel ingest 両方
- URL / arXiv: `ClaudeAttach` 本体は **呼ばずに** SourceVault 経由のみで attach。戻り値は `<|"Status" -> "AttachedViaSourceVault", "OriginalPathOrURL" -> ..., "Note" -> ...|>`

```mathematica
SourceVaultClaudeAttachIntegrationEnable[]
SourceVaultWorkerPromptIntegrationEnable[]

res = ClaudeAttach["arXiv:1706.03762"];
res["Status"]
res["OriginalPathOrURL"]
```

**期待される出力例:**

```
"AttachedViaSourceVault"
"arXiv:1706.03762"
```

その後 worker prompt に注入されることを確認:

```mathematica
(* worker prompt 生成時に <attached-documents> 経由で抜粋が注入される *)
hookedPrompt = ClaudeOrchestrator`A5InjectSourceVaultContext[
  "Goal: \:300cAttention Is All You Need\:300d\:306e\:610f\:7fa9\:3092\:7c21\:6f54\:306b\:8aac\:660e\:3057\:3066\u3002",
  "worker",
  <||>];   (* 空 task → 自動検出が ClaudeAttach 履歴を拾う *)

StringTake[hookedPrompt, UpTo[200]]
```

**期待される出力例:**

```
"<attached-documents count=\"1\">
<!-- \:4ee5\:4e0b\:306f worker \:30bf\:30b9\:30af\:304c\:53c2\:7167\:3059\:3079\:304d\:6587\:8108 (\:4f9d\:5b58 artifact \:76f8\:5f53)... -->
<document index=\"1\">
[arXiv PDF \:306e\:62b9\:7c8b\:30c6\:30ad\:30b9\:30c8 (Stage 4 Phase 4B \:5b9f\:88c5\:5f8c\:306f page \:5358\:4f4d)]
..."
```

> **注 1:** Phase 4A 時点では PDF のテキスト抽出は **まだ未実装** です (Phase 4B で実装)。Phase 4A で PDF を ingest した場合、`<document>` 内の本文は空または `[binary content]` 旨のプレースホルダになります。HTML / text/plain のように Wolfram が直接読める形式の URL は本文が入ります。
>
> **注 2:** B-2 等で既に attach 履歴がある状態だと、count は履歴の合計 (例: 過去 3 メモ + 今回 arXiv 1 件 = 4) になります。クリーンな状態で見たい時は `$LastAttachedRefs = {}` でリセット (ただし notebook の TaggingRule は別途残ります)。

## 例 C-7: 失敗ケース (HTTP 404 / Network unreachable / unrecognized URL)

```mathematica
(* 存在しない URL *)
res = SourceVaultIngest["https://example.com/this-does-not-exist-404.html"];
{res["Status"], res["Reason"]}

(* 不正な arXiv ID *)
res2 = SourceVaultIngest["arXiv:"];
{res2["Status"], res2["Reason"]}

(* protocol 不明 *)
res3 = SourceVaultIngest["ftp://example.com/file.pdf"];
{res3["Status"], res3["Reason"]}
```

**期待される出力例:**

```
{"Failed", "HTTPError"}       (* StatusCode: 404 *)
{"Failed", "InvalidArXivId: "}   (* iIngestArXiv 経由で空 ID は "InvalidArXivId: <空文字>" *)
{"Failed", "UnsupportedSourceType: Unknown"}
```

`Asynchronous -> True` を指定した場合も Phase 4A では Failed が返ります:

```mathematica
res = SourceVaultIngest["arXiv:1706.03762", "Asynchronous" -> True];
res["Reason"]
(* → "AsynchronousNotImplemented" *)
```

## 例 C-8: snapshot メタ確認 (URL ソース)

```mathematica
res = SourceVaultIngest["arXiv:1706.03762"];
meta = SourceVaultStatus[res["SnapshotId"]];
{meta["SourceType"], meta["Method"], meta["TrustLevel"], meta["ArXivId"]}
```

**期待される出力例:**

```
{"ArXiv", "URLDownload", "OfficialDocs", "1706.03762"}
```

`SourceType -> "ArXiv"`, `Method -> "URLDownload"`, `ArXivId` フィールドに version-pinned ID が記録されます。後段の Stage 4 Phase 4B (PDF page extraction) はこの `Path` (`raw/by-hash/sha256-....pdf`) を読んでページキャッシュを作ります。

## 例 C-9: 非同期 ingest (Phase 4A-async)

`Asynchronous -> True` を指定すると、`LLMGraphDAGCreate` (claudecode.wl の DAG ジョブスケジューラ) 経由で **JobId を即座に取得** できます。実体の fetch + snapshot 保存はジョブが裏側で実行します。

> **前提**: claudecode.wl がロード済みで `LLMGraphDAGCreate` / `iLLMGraphNode` が利用可能であること。これらが見つからない場合は `{"Status" -> "Failed", "Reason" -> "AsyncRequiresClaudeRuntime"}` が返ります。
>
> **設計上の注意**: Phase 4A-async は **rules/95 §C** に従い、独自 `ScheduledTask` を作らずに **`LLMGraphDAGCreate` の 1 ノード sync DAG** として実装されています。並列度は `taskDescriptor[categoryMap]` で `"ingest" -> "sync"` にマップ。今は「ジョブ機構経由の同期実行」ですが、API 経路は仕様書 §10 のとおりで、将来 `URLSubmit` ベースの真の並列化に置き換え可能です。

```mathematica
(* 1. \:5373\:5ea7\:306b JobId \:3092\:53d6\:5f97 *)
res = SourceVaultIngest["https://reference.wolfram.com/language/ref/NIntegrate.html",
  "Asynchronous" -> True];
res["Status"]
res["JobId"]
res["SourceId"]
res["SnapshotId"]
```

**期待される出力例:**

```
"Queued"
"job-..."        (* LLMGraphDAGCreate \:304b\:3089\:8fd4\:3055\:308c\:308b JobId *)
"src-url-..."    (* URL \:30d9\:30fc\:30b9\:3067\:4e8b\:524d\:5b89\:5b9a *)
Missing["Async"]  (* SnapshotId \:306f fetch \:5b8c\:4e86\:5f8c\:306b\:5224\:660e *)
```

ジョブ完了を待ってから snapshot を引きます。**`SourceVaultIngestWait`** が `LLMGraphDAGInspect` の内部構造を隠蔽してくれます:

```mathematica
(* 2. \:5b8c\:4e86\:5f85\:6a5f (\:6700\:5927 60 \:79d2\u3001SourceId \:306e snapshot \:5897\:52a0\:3092 polling) *)
waitResult = SourceVaultIngestWait[res, 60];
waitResult["Status"]            (* \[Rule] "Ready" (\:5b8c\:4e86) or "Timeout" *)
waitResult["SnapshotId"]
waitResult["WaitedSeconds"]

(* 3. SourceId \:7d4c\:7531\:3067 status \:3092\:78ba\:8a8d *)
status = SourceVaultStatus[res["SourceId"]];
Last[status["Snapshots"]]   (* \[Rule] "snap-sha256-..." *)
```

**期待される出力例:**

```
"Ready"
"snap-sha256-..."
4.2                          (* WaitedSeconds *)
"snap-sha256-..."
```

`SourceVaultIngestWait` は以下を自動判定します:

- `ingestResult["Status"]` が **`Ingested`/`AlreadyCurrent`/`RebuiltMetadata`** → sync で完了済みとして即時 return
- `Queued` → `SourceId` の `Snapshots` 数増加を 0.5 秒間隔で polling
- timeout 超過 → `Status: "Timeout"`
- `Failed`/`DeniedByNBAccess` → そのまま return

ジョブ完了後は通常の sync 経路と同じ snapshot / metadata が registry に保存されます。

### Async + URL レベル dedup

既に snapshot がある URL を `Asynchronous -> True` で投入すると、**ジョブを作らずに即座に `AlreadyCurrent`** を返します (`JobId -> None`):

```mathematica
res = SourceVaultIngest["arXiv:1706.03762", "Asynchronous" -> True];
res["Status"]
res["JobId"]
```

**期待される出力例:**

```
"AlreadyCurrent"
None
```

これにより複数の `ClaudeAttach["arXiv:..."]` 呼び出しが連続しても、最初の 1 回だけ実 fetch が走り、残りは即時 return します (P1 hook 経由の重複 attach 抑制)。

### 失敗ケース

```mathematica
(* LLMGraphDAGCreate \:304c\:898b\:3064\:304b\:3089\:306a\:3044 (claudecode.wl \:672a\:30ed\:30fc\:30c9) *)
res = SourceVaultIngest["https://example.com/", "Asynchronous" -> True];
res["Reason"]
(* \[Rule] "AsyncRequiresClaudeRuntime" *)
```

`AsynchronousNotImplemented` (Phase 4A 時点の暫定 reason) は **削除**され、claudecode.wl がロード済みなら必ずジョブが起動するようになりました。

## URL canonicalization のルール (`iCanonicalizeURL`)

| 入力 | 正規化後 | SourceKind |
|---|---|---|
| `arXiv:1706.03762` | `https://arxiv.org/pdf/1706.03762.pdf` | `"ArXiv"` |
| `arXiv:1706.03762v5` | `https://arxiv.org/pdf/1706.03762v5.pdf` | `"ArXiv"` |
| `https://arxiv.org/abs/1706.03762` | `https://arxiv.org/pdf/1706.03762.pdf` | `"ArXiv"` |
| `http://arxiv.org/pdf/1706.03762.pdf` | `https://arxiv.org/pdf/1706.03762.pdf` (HTTPS 昇格) | `"ArXiv"` |
| `https://reference.wolfram.com/...` | (そのまま) | `"Web"` |
| `https://example.com/page` | (そのまま) | `"Web"` |
| `ftp://...` / `file://...` | (失敗) | — |

---

# Part D. PDF page extraction (Stage 4 Phase 4B)

Phase 4B から **PDF を page 単位で抽出 + cache** できます:

- **キャッシュ**: 各 page は `parsed/by-snap/<snapshotId>/pages/NNNN.txt` に保存。2 回目以降は Import せず disk から読み込み。
- **page hash**: 各 page text の SHA-256 を `parsed/by-snap/<snapshotId>/page-hashes.json` に保存。Stage 8 (vN diff) や Stage 5 (claim → page span) の前提。
- **OCR hook**: スキャン PDF (Plaintext 抽出が 5 文字未満) で `$SourceVaultOCRHook` が定義されていれば呼ばれる。Phase 4B は hook 点のみ、実装は Phase 4C。

## 例 D-1: arXiv snapshot から指定ページを抽出

```mathematica
(* Part C で arXiv:1706.03762 を ingest 済みとする *)
res = SourceVaultIngest["arXiv:1706.03762"];   (* AlreadyCurrent *)
snapId = res["SnapshotId"];

pages3 = SourceVaultExtractPages[snapId, {3, 4, 5}];
pages3["Status"]
pages3["CachedFrom"]
pages3["CacheStats"]
StringLength[pages3["Pages"][3]]   (* page 3 \:306e\:6587\:5b57\:6570 *)
```

**期待される出力例 (初回実行):**

```
"OK"
"Fresh"
<|"TotalPages" -> 3, "FromCache" -> 0, "Fresh" -> 3, "OCRUsed" -> 0|>
1825                            (* page 3 の実文字数、内容次第で変動 *)
```

## 例 D-2: cache 再利用 (2 回目は瞬時)

```mathematica
pages3again = SourceVaultExtractPages[snapId, {3, 4, 5}];
pages3again["CachedFrom"]
pages3again["CacheStats"]
```

**期待される出力例:**

```
"Disk"
<|"TotalPages" -> 3, "FromCache" -> 3, "Fresh" -> 0, "OCRUsed" -> 0|>
```

すべての page が disk cache から読まれ、Import を一切行いません。実行時間は 100ms 未満。

明示的に再抽出したい場合は `"Force" -> True`:

```mathematica
pages3fresh = SourceVaultExtractPages[snapId, {3, 4, 5}, "Force" -> True];
pages3fresh["CachedFrom"]
(* \[Rule] "Fresh" *)
```

## 例 D-3: SourceId 経由 (latest snapshot を自動選択)

```mathematica
pages = SourceVaultExtractPages["src-arxiv-1706.03762", {1, 2}];
pages["SnapshotId"]   (* latest \:304c\:81ea\:52d5\:9078\:629e\:3055\:308c\:308b *)
Keys[pages["Pages"]]
```

**期待される出力例:**

```
"snap-sha256-..."
{1, 2}
```

## 例 D-4: page hash 確認

```mathematica
pages = SourceVaultExtractPages[snapId, {3}];
pages["Hashes"]            (* page \:6bce\:306e SHA-256 *)
pages["HashesPath"]        (* page-hashes.json \:306e path *)

(* json \:3092\:76f4\:63a5\:8aad\:3093\:3067 vN diff \:6e96\:5099 (Stage 8) *)
Import[pages["HashesPath"], "RawJSON"]
```

**期待される出力例:**

```
<|"0003" -> "sha256-..."|>     (* SourceVaultExtractPages の戻り値の Hashes は string 4 桁 key + sha256 string *)
"C:\\Users\\imai_\\Dropbox\\udb\\sourcevault\\parsed\\snap-sha256-.../page-hashes.json"
<|"0001" -> "sha256-...", "0002" -> ..., "0003" -> "sha256-..."|>     (* json には D-1/D-3 と累積で保存される *)
```

> **注**: `pages["Hashes"]` は **今回呼び出した page だけ** を含みますが、disk 上の `page-hashes.json` は **これまでの全 page** が累積保存されています。これは `Import["...", "RawJSON"]` で全 hash を読めるため、Stage 8 (vN diff) で 2 つの snapshot の page hash 集合を比較する用途に便利です。

## 例 D-5: 全ページ抽出 (PageCount 自動取得)

```mathematica
all = SourceVaultExtractPages[snapId, All];
all["CacheStats"]
Length[all["Pages"]]   (* \:5168\:30da\:30fc\:30b8\:6570 *)
```

**期待される出力例 (arXiv 1706.03762 で 15 page、D-1/D-3 で {1,2,3,4,5} cache 済の場合):**

```
<|"TotalPages" -> 15, "FromCache" -> 5, "Fresh" -> 10, "OCRUsed" -> 0|>
15
```

D-1, D-3 で {1, 2, 3, 4, 5} を cache 済みなら、それらは disk から (5 件)、残り 10 件は新規 (Fresh) になり、`CachedFrom` は `"Mixed"`。PageCount は論文 PDF 次第で変動 (Attention Is All You Need は 15 page)。

## 例 D-6: SourceVaultSpan + Pages 経由抽出 (Stage 3 連携)

`SourceVaultSpan["...", "Pages" -> {N}]` から `SourceVaultContext` を呼ぶ既存経路でも、Phase 4B の cache が **自動的に利用** されます (`iExtractTextPages` 内で snapshotId 経由 cache を使うように更新済み):

```mathematica
span = SourceVaultSpan[snapId, "Pages" -> {3, 4, 5}];
ctx = SourceVaultContext[span, MaxCharacters -> 5000];
ctx["Status"]
StringTake[ctx["Text"], UpTo[200]]
```

**期待される出力例:**

```
"OK"
"[Page 3]\nFigure 1: The Transformer - model architecture.\nThe Transformer follows this overall architecture using stacked self-attention and point-wise, fully\nconnected layers for both the encoder and "
```

`ctx["Citations"]` には `Pages` 情報がそのまま残るので、LLM 応答が「page 4 によれば」と参照する場合に逆引き可能。

## 例 D-7: OCR hook (Phase 4C 準備)

スキャン PDF (Plaintext 抽出が空に近い) でユーザが OCR を組み込む場合の hook:

```mathematica
(* Phase 4C \:307e\:3067\:306f\:30b9\:30b1\:30eb\:30c8\:30f3\:3060\:3051\u3001\:30e6\:30fc\:30b6\:304c\:5b9f\:88c5\:3092\:5dee\:3057\:8fbc\:3081\:308b *)
SourceVault`$SourceVaultOCRHook =
  Function[req,
    Module[{rawPath, page},
      rawPath = req["RawPath"];
      page = req["Page"];
      (* \:3053\:3053\:3067 Tesseract / Claude Vision \:7b49\:3092\:547c\:3076\u3002\:8fd4\:5024\:306f String\u3002 *)
      "[OCR placeholder for " <> FileNameTake[rawPath] <>
        " page " <> ToString[page] <> "]"
    ]];

(* \:30b9\:30ad\:30e3\:30f3 PDF \:3092 ingest \:6e08\:307f\:3068\:4eee\:5b9a\u3001cache \:3092\:30af\:30ea\:30a2\:3057\:3066\:518d\:62bd\:51fa *)
pages = SourceVaultExtractPages[scannedSnapId, {1, 2}, "Force" -> True];
pages["CacheStats"]   (* OCRUsed \:304c\:30ab\:30a6\:30f3\:30c8\:3055\:308c\:308b *)
pages["Pages"][1]     (* OCR hook \:306e\:8fd4\:5024 *)
```

**期待される出力例 (hook 設定後):**

```
<|"TotalPages" -> 2, "FromCache" -> 0, "Fresh" -> 2, "OCRUsed" -> 2|>
"[OCR placeholder for scanned.pdf page 1]"
```

OCR hook は **plaintext 抽出が 5 文字未満** の時だけ呼ばれます (`iIsPDFLikelyScanned` の判定)。通常の text-based PDF では呼ばれないので、未スキャン PDF への性能影響はゼロ。

リセット (hook 無効化):

```mathematica
SourceVault`$SourceVaultOCRHook = None;
```

## Phase 4B の物理ストレージ

```
parsed/by-snap/<snapshotId>/
  pages/
    0001.txt       # page 1 text (UTF-8 plaintext or OCR)
    0002.txt
    ...
  page-hashes.json # {"0001": "sha256-...", "0002": "sha256-..."}
```

- ファイル名は **4 桁 0 パディング** (`0003.txt`)。`Sort` で自然順序になる
- page-hashes.json の key は 4 桁 0 パディング文字列 (JSON では数値 key が string 化されるため統一)
- transactional write で部分書き込みを防ぐ (`iTransactionalWrite`)

---

# Part E. OCR backends (Stage 4 Phase 4C)

Phase 4C で **OCR バックエンドの実装**が組み込まれました。Phase 4B の hook 点 (`$SourceVaultOCRHook`) に、3 種類のバックエンドのいずれかを enable できます:

| Backend | 説明 | 依存 |
|---|---|---|
| **`"ClaudeVision"`** | `ClaudeCode\`ClaudeQueryBg[{prompt, image}]` 経由で Claude API に page 画像を送信 (PDFIndex.wl の実証済みパターン)。大ページは自動で上下分割 + 30px overlap | claudecode.wl、Anthropic API key |
| **`"TextRecognize"`** | Mathematica 組込み `TextRecognize[img, Language -> ...]` | Mathematica のみ |
| **`"Custom"`** | ユーザ提供 Function を直接 hook に注入 | (任意) |

Page rasterization は **PyMuPDF 優先 (300 DPI)** → Wolfram native fallback (`Import[..., {"PageGraphics", n}]` → `Rasterize`) の 2 段階。

## 例 E-1: ClaudeVision を有効化

```mathematica
res = SourceVaultOCREnable["ClaudeVision"];
res["Status"]
res["Backend"]
res["Provider"]      (* anthropic / claudecode / openai *)
res["Warning"]       (* claudecode の時は警告メッセージ、それ以外は Null *)
SourceVaultOCRStatus[]
```

**期待される出力例 (provider が anthropic の場合):**

```
"Enabled"
"ClaudeVision"
"anthropic"
Null
<|"Backend" -> "ClaudeVision",
  "Mode" -> "Auto",
  "Verbose" -> False,
  "HookSet" -> True,
  "ClaudeQueryBgAvailable" -> True,
  "PythonAvailable" -> True|>
```

**期待される出力例 (provider が claudecode の場合):**

```
"Enabled"
"ClaudeVision"
"claudecode"
"$ClaudeModel uses provider 'claudecode' (CLI) which does NOT support vision. ..."
```

### ⚠️ 重要: ClaudeVision は Anthropic API (paid) のみ対応

claudecode.wl の **claudecode CLI provider (`{"claudecode", ...}`) では vision/multimodal API が未実装**です。`ClaudeVision` backend を使うには `$ClaudeModel` を切り替える必要があります:

```mathematica
(* OCR \:5b9f\:884c\:524d\:306b\:5207\:308a\:66ff\:3048 (\:6c38\:7d9a\:7684) *)
ClaudeCode`$ClaudeModel = {"anthropic", "claude-sonnet-4-20250514"}

(* \:307e\:305f\:306f\u3001\:30aa\:30fc\:30d7\:30f3 *)
SourceVaultOCREnable["ClaudeVision"]
SourceVaultExtractPages[snapId, {1}, "Force" -> True]
```

`anthropic` provider は **API 直叩き = 課金あり**。claudecode CLI (Pro/Max 契約) とは別の Anthropic API キーが必要。コストを避けたい場合は:

| 代替策 | 説明 |
|---|---|
| **`TextRecognize` backend** | Mathematica 組込み、Python・ネット不要、精度はやや低め |
| **`Custom` backend** | OpenAI GPT-4V、Gemini Vision、ローカル LLM (lmstudio) 等を自前で接続 |

エラー切り分け:

```mathematica
res = SourceVaultExtractPages[snapId, {1}, "Force" -> True]
res["OCRFailReasons"]
(* \[Rule] {"Error: multimodal API \:306f\:73fe\:5728 Anthropic \:306e\:307f\:5bfe\:5fdc..."} *)
```

`OCRFailReasons` に **claudecode 側のエラーメッセージがそのまま記録**されるので、何が起きているか一目で分かります。

`ClaudeQueryBgAvailable` が `False` なら claudecode.wl 未ロード — `SourceVaultOCREnable["ClaudeVision"]` は `Failed` を返します。

## 例 E-2: スキャン PDF で自動 OCR 起動

ClaudeVision を有効にした状態でスキャン PDF (Plaintext 抽出が空に近い) を `SourceVaultExtractPages` で抽出すると、`iIsPDFLikelyScanned` (text < 5 文字判定) が hook を発火させます:

```mathematica
(* \:30b9\:30ad\:30e3\:30f3 PDF \:3092 ingest \:6e08\:307f\:3068\:4eee\:5b9a *)
scanRes = SourceVaultIngest["C:\\path\\to\\scanned-document.pdf"];
scanSnapId = scanRes["SnapshotId"];

(* cache \:3092\:30af\:30ea\:30a2\:3057\:3066\:518d\:62bd\:51fa (Force \:5fc5\:9808) *)
ocrResult = SourceVaultExtractPages[scanSnapId, {1, 2}, "Force" -> True];
ocrResult["CacheStats"]
ocrResult["OCRCalled"]
ocrResult["Pages"][1]   (* OCR \:7d4c\:7531\:3067\:62bd\:51fa\:3055\:308c\:305f text *)
```

**期待される出力例:**

```
<|"TotalPages" -> 2, "FromCache" -> 0, "Fresh" -> 2, "OCRUsed" -> 2|>
True
"\:8ad6\:6587\:30bf\:30a4\:30c8\:30eb\n\:7b2c 1 \:7ae0\:3000\:5e8f\:8ad6\n\:73fe\:4ee3\:306e\:8a08\:7b97\:8ad6\:7406\:5b66\:306b\:304a\:3044\:3066\:3001\:53ef\:9006\:8a08\:7b97\:306f..."
```

`OCRUsed: 2` で 2 page とも Claude Vision で OCR が走り、結果が cache に保存されます。**2 回目以降は cache から瞬時に読み込まれる**ので、OCR の API コストは初回のみ。

## 例 E-3: TextRecognize backend (Python 不要)

Claude API を使えない環境では Mathematica 組込みの `TextRecognize`:

```mathematica
SourceVaultOCREnable["TextRecognize", "Language" -> "Japanese", "DPI" -> 200]
ocrResult = SourceVaultExtractPages[scanSnapId, {1}, "Force" -> True];
ocrResult["Pages"][1]
```

精度は Claude Vision より低めですが、**Python・ネットワーク不要**で動きます。日本語論文に対しては DPI を上げる (`"DPI" -> 300`) と改善する場合あり。

## 例 E-4: Custom backend (Claude API 直叩き、GPT-4V 等)

`ClaudeQueryBg` を使わず自前で実装したい場合 (例えば Anthropic SDK 経由、OpenAI Vision、Gemini Vision など):

```mathematica
SourceVaultOCREnable["Custom",
  "Hook" -> Function[req,
    Module[{rawPath, page, img, response},
      rawPath = req["RawPath"];
      page = req["Page"];
      
      (* page \:3092 image \:5316\u3002SourceVault \:306e\:5185\:90e8 helper \:3092\:4f7f\:3046\:5834\:5408: *)
      img = SourceVault`Private`iRasterizePagePDF[rawPath, page, 300];
      If[!ImageQ[img], Return[""]];
      
      (* \:3053\:3053\:3067\:81ea\:5206\:306e API \:3092\:547c\:3076\u3002\:4f8b: OpenAI Vision *)
      response = MyOpenAIVisionCall[img,
        "Please OCR this PDF page. Output only the extracted text."];
      
      If[StringQ[response], response, ""]
    ]]]
```

`SourceVault`Private`iRasterizePagePDF` は PyMuPDF 優先で Wolfram native fallback を行う共通ヘルパなので、Custom backend からも利用できます。

## 例 E-5: 状態確認と無効化

```mathematica
(* \:73fe\:5728\:306e\:8a2d\:5b9a *)
SourceVaultOCRStatus[]

(* OCR \:7121\:52b9\:5316 *)
SourceVaultOCRDisable[]
SourceVaultOCRStatus[]
```

**期待される出力例:**

```
<|"Backend" -> "ClaudeVision", "Mode" -> "Auto", "HookSet" -> True, "ClaudeQueryBgAvailable" -> True, "PythonAvailable" -> True|>
<|"Status" -> "Disabled"|>
<|"Backend" -> "Disabled", "Mode" -> "Auto", "HookSet" -> False, ...|>
```

## 例 E-6: 永続的な OCR 強制モード (`"Mode" -> "Force"`)

低品質 OCR テキスト層を持つ PDF (= スキャン判定をすり抜けるが内容が `\:ff6d` 混じり等の汚い PDF) では、**Mode -> "Force"** で全 page を OCR し直せます:

```mathematica
(* \:5e38\:306b OCR \:3092\:547c\:3076\:30e2\:30fc\:30c9\:3067\:6709\:52b9\:5316 *)
SourceVaultOCREnable["ClaudeVision", "Mode" -> "Force"]
SourceVaultOCRStatus[]

(* \:30c6\:30ad\:30b9\:30c8\:5c64\:304c\:3042\:308b PDF \:3067\:3082\u3001Force -> True \:3068\:7d44\:307f\:5408\:308f\:305b\:3066\:518d\:62bd\:51fa\:3059\:308b\:3068
   OCR \:304c\:8d70\:308b (cache \:7121\:8996 + \:30b9\:30ad\:30e3\:30f3\:5224\:5b9a\:30b9\:30ad\:30c3\:30d7) *)
res = SourceVaultExtractPages[snapId, {1, 2}, "Force" -> True]
res["CacheStats"]
res["OCRCalled"]
```

**期待される出力例:**

```
<|"Status" -> "Enabled", "Backend" -> "ClaudeVision", "Mode" -> "Force", "Options" -> <|...|>|>
<|"Backend" -> "ClaudeVision", "Mode" -> "Force", "HookSet" -> True, ...|>
<|"TotalPages" -> 2, "FromCache" -> 0, "Fresh" -> 2, "OCRUsed" -> 2|>
True
```

`Mode: "Force"` の間は `iIsPDFLikelyScanned` の閾値判定がスキップされ、cache miss の page は **必ず OCR を経由** します。OCR の結果は通常通り cache に保存されるので、2 回目以降は disk から瞬時。

「Auto モードに戻す」には:

```mathematica
SourceVaultOCREnable["ClaudeVision", "Mode" -> "Auto"]   (* \:660e\:793a\:7684\:306b Auto \:306b\:623b\:3059 *)
(* \:307e\:305f\:306f *)
SourceVaultOCRDisable[]                                  (* hook \:3054\:3068\:7121\:52b9\:5316 *)
```

## 例 E-7: 単発の OCR 強制 (`"ForceOCR" -> True`)

1 page だけ「今回の呼出だけ OCR したい」場合は `SourceVaultExtractPages` の `"ForceOCR" -> True`:

```mathematica
SourceVaultOCREnable["ClaudeVision"]   (* Mode -> "Auto" \:306e\:307e\:307e\:3067 OK *)

(* \:901a\:5e38\:6642\:306f Plaintext \:7d4c\:7531\:3060\:304c\u3001\:3053\:306e\:547c\:51fa\:3057\:3060\:3051 OCR \:3092\:5f37\:5236 *)
res = SourceVaultExtractPages[snapId, {3}, "ForceOCR" -> True]
res["OCRCalled"]
res["Pages"][3]
```

**期待される出力例:**

```
True
"\:8ad6\:6587\:30bf\:30a4\:30c8\:30eb (Claude Vision \:7d4c\:7531\:306e\:6e05\:7d14\:306a\:518d OCR \:7d50\:679c)..."
```

`"ForceOCR" -> True` を指定すると、内部で `"Force" -> True` も自動適用される (cache 読みをバイパスして OCR を実行) ので、明示的に両方書く必要はありません。

### `"Mode" -> "Force"` vs `"ForceOCR" -> True` の使い分け

| 状況 | 推奨 |
|---|---|
| 既知の低品質 PDF 群を **一括** で再 OCR | `SourceVaultOCREnable["ClaudeVision", "Mode" -> "Force"]` で永続切替 |
| 特定の 1〜数 page を **試しに** OCR してみたい | `SourceVaultExtractPages[..., "ForceOCR" -> True]` で単発実行 |
| 通常の運用 (スキャン PDF のみ OCR) | `Mode -> "Auto"` (デフォルト) |

両方を同時に使うことも可能 — `Mode: "Force"` の状態でも `"ForceOCR" -> True` は依然として cache をバイパスする働きがあるので、Mode を変えずに「特定 page だけ確実に再 OCR」できます。

## OCR の動作条件 (重要)

OCR hook が **発火する条件**は、永続モード (`$SourceVaultOCRMode`) と単発フラグ (`"ForceOCR"`) の組合せです:

```
OCR を呼ぶ ⇔ hook が設定済み AND (
  ForceOCR -> True
  OR
  $SourceVaultOCRMode === "Force"
  OR
  iIsPDFLikelyScanned[plaintext]    (* Plaintext 抽出が 5 文字未満 *)
)
```

つまり:

| PDF 種別 / 状況 | Auto モード | Force モード | ForceOCR フラグ |
|---|---|---|---|
| **text-based** (`arXiv` の通常論文) | Plaintext のみ | OCR | OCR |
| **スキャン PDF** (画像 only) | OCR | OCR | OCR |
| **低品質 OCR テキスト層** (`\:ff6d` 混じり) | Plaintext のみ ← **救えない** | **OCR** ✓ | **OCR** ✓ |
| **混在 PDF** | スキャン page のみ OCR | 全 page OCR | 全 page OCR |

- `Auto` (デフォルト) は **コスト最小**: text-based PDF では OCR が呼ばれない (API コスト 0)
- `Force` は **品質最優先**: text 層を信用せず常に画像 OCR を回す (API コスト高)
- `ForceOCR` フラグは **単発の品質確認**: 1 page だけ OCR して比べたい時

## Page rasterization の優先順位

`iRasterizePagePDF` の内部動作:

1. **PyMuPDF (Python + fitz)** で 300 DPI レンダリング (推奨、`get_pixmap(dpi=300)`)
2. 失敗時 **Wolfram native**: `Import[rawPath, {"PageGraphics", page}]` → `Rasterize[..., ImageResolution -> dpi]`
3. それも失敗時: `Import[rawPath, {"ImageList", page}]` で画像取得

PyMuPDF のインストール (推奨):

```bash
pip install pymupdf
```

PyMuPDF があれば画質が安定し、Wolfram の Import の癖 (page によって失敗、解像度不安定) を回避できます。

## OCR の診断 — `OCRCalled: False` が出る時

OCR を強制したのに `OCRCalled: False, OCRUsed: 0` で返ってくる場合、原因は通常 **hook 内部 (Claude Vision API 等) の失敗**です。Phase 4C-diagnostics で **試行と成功を区別する** フィールドが追加されました:

```mathematica
res = SourceVaultExtractPages[snapId, {1}, "Force" -> True, "ForceOCR" -> True]
res["OCRCalled"]         (* OCR \:6210\:529f\:3057\:305f\:304b *)
res["OCRAttempted"]      (* OCR \:3092\:8a66\:3057\:305f\:304b *)
res["OCRFailReasons"]    (* \:5931\:6557\:7406\:7531\:306e\:30ea\:30b9\:30c8 *)
res["CacheStats"]["OCRAttempted"]  (* \:8a66\:884c\:3055\:308c\:305f page \:6570 *)
```

**判別表**:

| OCRAttempted | OCRCalled | 意味 |
|---|---|---|
| False | False | hook が **呼ばれていない** (Mode=Auto かつ text が 5 文字以上) — 期待通り、または ForceOCR/Mode=Force の指定漏れ |
| True | False | hook は **呼ばれたが失敗** — `OCRFailReasons` を参照 |
| True | True | OCR 成功、cache に保存 |

**よくある `OCRFailReason`**:

- `"EmptyOrWhitespaceResponse"` — Claude Vision が **空文字** を返した (画像が大きすぎ・無関係内容と判断・タイムアウト等)
- `"HookReturned$Failed"` — `ClaudeQueryBg` がエラー終了
- `"HookReturnedFailure"` — `Failure[...]` を返した
- `"HookReturnedNonString:Symbol"` — 想定外の Head の戻り値

## Verbose モード — OCR 実行の進捗を可視化

`SourceVaultOCREnable[..., "Verbose" -> True]` で **OCR 各ステップの進捗を Print** 出力します:

```mathematica
SourceVaultOCREnable["ClaudeVision", "Mode" -> "Force", "Verbose" -> True]
SourceVaultExtractPages[snapId, {1}, "Force" -> True]
```

**Print される情報の例:**

```
[SourceVault OCR] page 1: plaintext extracted (1825 chars)
[SourceVault OCR] page 1: shouldCallOCR=True (mode=Force, forceOCR=False, isScanned=False)
[SourceVault OCR] page 1: calling hook...
[ClaudeVision] rasterizing page 1 at 300 DPI...
[ClaudeVision] rasterized: {1700, 2200}
[ClaudeVision] OCRing top half...
[ClaudeVision] top returned: 0 chars
[ClaudeVision] OCRing bottom half...
[ClaudeVision] bottom returned: $Failed
[ClaudeVision] both halves empty, returning empty
[SourceVault OCR] page 1: hook returned String(0 chars)
```

これで:
- `rasterized: {1700, 2200}` が出れば **PyMuPDF / Wolfram での page 画像化は成功**
- `top returned: 0 chars` や `$Failed` が出れば **ClaudeQueryBg API 呼出の問題**
- 画像化自体が失敗するなら `rasterization FAILED for page 1` が出る

問題箇所が一目で分かります。

### 手動で hook を呼んで切り分け

更に細かく調べたい場合は hook を直接呼べます:

```mathematica
SourceVaultOCREnable["ClaudeVision"]
hookFunc = SourceVault`$SourceVaultOCRHook;

(* OCR \:3092\:5358\:72ec\:3067\:5b9f\:884c *)
ret = hookFunc[<|
  "RawPath" -> "C:\\path\\to\\file.pdf",
  "Page" -> 1,
  "SnapshotId" -> "test-snap"
|>];
StringQ[ret]
StringLength[ret]
```

これで:
- `StringQ -> True, length > 0` なら **hook 自体は機能** → SourceVaultExtractPages 経路の問題
- `StringQ -> True, length 0` なら **Claude Vision の API 呼出問題**
- `StringQ -> False` なら **rasterization の問題**

### 画像化だけ単独で確認

```mathematica
img = SourceVault`Private`iRasterizePagePDF["C:\\path\\to\\file.pdf", 1, 300]
ImageQ[img]
ImageDimensions[img]
```

`ImageQ[img] -> True` なら画像化 OK。`$Failed` なら PyMuPDF と Wolfram native の両方が失敗。

## OCR cache の振る舞い

OCR 結果も Phase 4B の cache 機構にそのまま乗ります:

- `parsed/by-snap/<snapshotId>/pages/0001.txt` に OCR 結果が UTF-8 で保存
- `page-hashes.json` に SHA-256 が記録 (OCR 結果が変わると hash も変わる → vN diff で再 OCR を検出可能)
- 2 回目以降の `SourceVaultExtractPages` は **API call せず disk から読む** ので、Claude API のコストは初回のみ

OCR の再実行 (例えばプロンプトを変えた時):

```mathematica
SourceVaultOCREnable["ClaudeVision", "Prompt" -> "...new prompt..."]
SourceVaultExtractPages[snapId, {1, 2}, "Force" -> True]  (* cache を無視 *)
```

低品質 OCR テキスト層を持つ PDF を強制的に再 OCR:

```mathematica
SourceVaultOCREnable["ClaudeVision", "Mode" -> "Force"]    (* \:6c38\:7d9a\:7684 *)
SourceVaultExtractPages[snapId, All, "Force" -> True]      (* \:5168 page \:518d OCR *)
```

1 page だけ OCR の品質を比較したい:

```mathematica
res = SourceVaultExtractPages[snapId, {3}, "ForceOCR" -> True]   (* \:5358\:767a\:5f37\:5236 *)
res["Pages"][3]
```

---

# Part F. Claim extraction (Stage 5)

Stage 5 では **source span から構造化 claim を抽出**します。LLM が page text を読んで指定 schema に従った JSON を生成、それを Claim Association に正規化して JSONL ストアに保存する流れです。

```
SourceVaultSpan / Snapshot
  ↓ SourceVaultContext (Phase 4B page text cache)
LLM (Claude Code CLI via ClaudeQueryBg)
  ↓ JSON 応答パース
Claim Associations (正規化)
  ↓ append
parsed/.../claims/
  claims.jsonl              (master、全 claim)
  by-topic/<topic>.jsonl    (topic ごと)
  by-source/<sourceId>.jsonl (source ごと逆引き)
```

## ビルトイン schema

| 名前 | 用途 | フィールド |
|---|---|---|
| **`"FreeText"`** | 自由形式の主張抽出 | Statement (必須), Quote (任意) |
| **`"NumericFacts"`** | 数値ファクト抽出 | Quantity, Value, Unit, Context |
| **`"DefinitionList"`** | 用語と定義のペア | Term, Definition |

利用可能な schema 一覧:

```mathematica
SourceVaultListSchemas[]
(* \[Rule] {"FreeText", "NumericFacts", "DefinitionList"} *)

SourceVaultGetSchema["NumericFacts"]
(* \[Rule] <|"Name" -> "NumericFacts", "Description" -> "Extract numeric facts...",
            "Fields" -> {...}, "OutputShape" -> "List", ...|> *)
```

## 例 F-1: FreeText で論文 abstract から claim 抽出

```mathematica
(* Phase 4A で ingest 済みの arXiv:1706.03762 (Attention Is All You Need) *)
snapId = "snap-sha256-cd072e3f...";

res = SourceVaultExtract[
  SourceVaultSpan[snapId, "Pages" -> {1, 2}],
  "FreeText",
  "Topic" -> "transformer-architecture-claims"]

res["Status"]      (* "OK" *)
res["Count"]       (* 抽出された claim 数 *)
First[res["Claims"]]
```

**期待される出力例:**

```
"OK"
5
<|"ClaimId" -> "claim-transformer-archi-...-a3f8c2",
  "Topic" -> "transformer-architecture-claims",
  "Schema" -> "FreeText",
  "Fields" -> <|"Statement" -> "The Transformer is the first model relying entirely on self-attention...",
                "Quote" -> "We propose a new simple network architecture..."|>,
  "Subject" -> "The Transformer is the first model relying entirely on self-attention...",
  "Predicate" -> "FreeText",
  "Object" -> <|"Statement" -> "...", "Quote" -> "..."|>,
  "SourceSpan" -> <|"SnapshotId" -> "snap-sha256-...", "Pages" -> {1, 2}|>,
  "ExtractionMethod" -> "LLM",
  "Confidence" -> 0.7,
  "ValidationStatus" -> "Unreviewed",
  "ContentHash" -> "sha256-..."
 |>
```

## 例 F-2: NumericFacts で数値抽出

```mathematica
res = SourceVaultExtract[
  SourceVaultSpan[snapId, "Pages" -> {5, 6}],
  "NumericFacts",
  "Topic" -> "transformer-hyperparameters"]

res["Claims"][[All, "Fields"]]
```

**期待される出力例:**

```
{<|"Quantity" -> "model dimension d_model",
   "Value" -> 512, "Unit" -> Null,
   "Context" -> "Base model architecture"|>,
 <|"Quantity" -> "number of attention heads",
   "Value" -> 8, "Unit" -> Null,
   "Context" -> "Base model"|>,
 <|"Quantity" -> "dropout rate P_drop",
   "Value" -> 0.1, "Unit" -> Null,
   "Context" -> "Regularization, base model"|>,
 ...}
```

## 例 F-3: カスタム schema をインライン定義

```mathematica
res = SourceVaultExtract[
  SourceVaultSpan[snapId, "Pages" -> {3, 4}],
  <|"Name" -> "ArchitectureComponents",
    "Description" -> "Extract architectural components of the Transformer.",
    "Fields" -> {
      <|"Name" -> "Component", "Type" -> "String", "Required" -> True,
        "Description" -> "Name of the architectural component"|>,
      <|"Name" -> "Purpose", "Type" -> "String", "Required" -> True,
        "Description" -> "What this component does in the architecture"|>,
      <|"Name" -> "Position", "Type" -> "String", "Required" -> False,
        "Description" -> "Where it appears (Encoder/Decoder/Both)"|>
    },
    "OutputShape" -> "List"|>,
  "Topic" -> "transformer-components"]

res["Claims"][[All, "Fields"]]
```

**期待される出力例:**

```
{<|"Component" -> "Multi-Head Attention",
   "Purpose" -> "Allows the model to jointly attend to information from different representation subspaces",
   "Position" -> "Encoder and Decoder"|>,
 <|"Component" -> "Positional Encoding",
   "Purpose" -> "Injects information about token position since the model has no recurrence",
   "Position" -> "Input to Encoder and Decoder"|>,
 ...}
```

## 例 F-4: schema を永続登録 (再利用)

```mathematica
SourceVaultRegisterSchema["ProofObligation",
  <|"Description" -> "Extract proof obligations: each is a goal that must be shown.",
    "Fields" -> {
      <|"Name" -> "Goal", "Type" -> "String", "Required" -> True|>,
      <|"Name" -> "Assumptions", "Type" -> "Array", "Required" -> False|>,
      <|"Name" -> "ProofTechnique", "Type" -> "String", "Required" -> False|>
    },
    "OutputShape" -> "List"|>]

(* \:6b21\:56de\:4ee5\:964d\:306f\:540d\:524d\:3067\:53c2\:7167\:53ef\:80fd *)
SourceVaultListSchemas[]
(* \[Rule] {..., "ProofObligation"} *)

SourceVaultExtract[snapId, "ProofObligation", "Topic" -> "lemma-2-3"]
```

## 例 F-5: 抽出した claim を検索

```mathematica
(* topic 検索 *)
claims = SourceVaultClaimsForTopic["transformer-architecture-claims"];
Length[claims]
claims[[1]]["Fields"]["Statement"]

(* source 逆引き (snapshot or source ID) *)
SourceVaultClaimsForSource["src-arxiv-1706.03762"]
SourceVaultClaimsForSource[snapId]   (* snap- でも OK \u3001\:81ea\:52d5\:3067 source \:306b\:9006\:5f15\:304d *)

(* claim ID から 1 件取得 *)
SourceVaultClaim["claim-transformer-archi-...-a3f8c2"]
```

## 例 F-6: validation 付き抽出

`"Validation" -> "Required"` を指定すると、必須フィールドが欠けた claim は除外されます:

```mathematica
res = SourceVaultExtract[snapId, "NumericFacts",
  "Topic" -> "stats",
  "Validation" -> "Required"]

res["ValidationStatus"]
(* \[Rule] "Validated" \:307e\:305f\:306f "PartiallyValidated" *)

res["Errors"]
(* \[Rule] {"Validation failed for 2 claim(s)"} \:7b49 *)
```

## 例 F-7: claim を保存しない (dry run)

LLM 抽出だけ試して、ストアに書き込まない場合:

```mathematica
res = SourceVaultExtract[snapId, "FreeText",
  "StoreClaims" -> False]

res["Claims"]   (* \:8fd4\:5024\:306b\:306f\:5165\:3063\:3066\:3044\:308b\:304c\u3001JSONL \:306b\:306f append \:3055\:308c\:306a\:3044 *)
```

## ClaimStore の物理ストレージ

```
PrivateVault/parsed/.../   (\u203b SourceVault root \:4ee5\:4e0b)
claims/
  claims.jsonl              # \:5168 claim (master、append-only)
  by-topic/
    transformer-architecture-claims.jsonl
    transformer-hyperparameters.jsonl
    ...
  by-source/
    src-arxiv-1706.03762.jsonl   # source \:9006\:5f15\:304d
    src-arxiv-2401.01234.jsonl
    ...
```

- **append-only JSONL**: 1 行 1 claim、`ExportString[..., "RawJSON", "Compact" -> True]`
- **3 重インデックス**: master + topic + source → どの軸からも O(file size) で検索可能
- **content hash**: `ContentHash` フィールドで dedup 判定可能 (将来の dedup 用、現在は append-only で動作)

## prompt の中身 (`iBuildExtractionPrompt`)

LLM に送られる prompt は次のような構造:

```
You are extracting structured claims from a source document. Read the SOURCE TEXT below
and extract claims according to the SCHEMA.

## SCHEMA: NumericFacts
Extract numeric facts: each fact has a quantity name, numeric value, unit (if any), and context.

Fields to extract per claim:
1. Quantity (String, required): Name of the quantity (e.g., 'initial velocity', 'learning rate')
2. Value (Number, required): The numeric value
3. Unit (String, optional): Unit of measurement, or null if dimensionless
4. Context (String, optional): Brief context where this fact appears in the source

## OUTPUT FORMAT
Respond with ONLY a JSON array (no prose, no markdown code fences). Schema:
[
  {
    "Quantity": <string>,
    "Value": <number>,
    "Unit": <string>,
    "Context": <string>
  },
  ...
]

If no claims can be extracted, respond with [].

## SOURCE TEXT
[Page 5]
... (Phase 4B cache から取得した text) ...
```

LLM がコードフェンス (` ```json ... ``` `) で囲ってきても自動で剥がして JSON パースします。

## Stage 5 のデバッグ — `ParseFailed` が出た時

LLM 応答の JSON が壊れているケースを判別するための情報が `Status == "Failed"` 時の戻り値に含まれます:

```mathematica
res = SourceVaultExtract[snapId, "FreeText", "Topic" -> "test"]
res["Status"]
(* \:5931\:6557\:6642 *)
res["Reason"]              (* "ParseFailed" *)
res["RawResponseLength"]   (* LLM \:5fdc\:7b54\:306e\:5168\:9577 *)
res["RawResponseHead"]     (* \:5148\:982d 1500 \:6587\:5b57 *)
res["RawResponseTail"]     (* \:672b\:5c3e 1500 \:6587\:5b57 (\:5207\:3089\:308c\:305f\:5834\:5408\:78ba\:8a8d\:7528) *)
res["ParseResult"]         (* \:8a73\:7d30 *)
```

末尾が `"context": "...rate, base mod` のように切れていれば **応答 truncation**。末尾が `]` で正しく終わっていれば JSON 文法エラー (escape 等)。

### `$SourceVaultExtractVerbose -> True` で進捗を見る

```mathematica
SourceVault`$SourceVaultExtractVerbose = True;
res = SourceVaultExtract[snapId, "FreeText", "Topic" -> "test"]
```

**Print 出力:**

```
[SourceVaultExtract] calling ClaudeQueryBg with prompt of 5234 chars (timeout=180s)...
[SourceVaultExtract] response in 18.3s: String(2847 chars)
```

これで:
- `prompt` の長さが正しいか (`MaxCharacters` で contextText を絞ったか)
- `response` 長さが妥当か (短すぎる/長すぎる)
- 応答時間 (Timeout 不足判定)
- が一目で判別できます。

### 自動 JSON 復旧機構 (Stage 5-fix1)

LLM 応答が次のいずれかでも自動でリカバリできます:

1. **解説文付き** (`Here are the claims:\n[...]\n\nNote: ...`) → bracket counting で `[...]` を切り出して parse
2. **応答が途中で切れている** (`[{...}, {...}, {"Quanti`) → 完全な object だけ拾って `Items` に返す。戻り値の `Note` に `"PartialRecovery: 2 object(s) recovered..."` が記録される
3. **markdown コードフェンス** (```` ```json [...] ``` ````) → 従来通り剥がす

つまり LLM 応答が完璧な JSON 配列でなくても、**含まれている valid object はすべて回収**します。

---

## Stage 5 のサニタイズ機構 (`iSanitizeForJSON`)

LLM 抽出された claim を JSONL に保存する前に、`iSanitizeForJSON` で **JSON 非互換な値を自動変換**します:

| Wolfram 型 | JSON 化 |
|---|---|
| `Missing[]`, `Missing["..."]` | `null` |
| `DateObject[...]` | `DateString` で文字列化 |
| `Automatic`, `None` | `ToString[..., InputForm]` 文字列化 |
| `Association`, `List`, `String`, 数値, `True/False/Null` | そのまま |

つまり `SourceSpan["Pages"] -> Missing[]` のような場合でも自動で `Null` に変換され、ClaimStore への保存が失敗しません。

## Stage 5 の制約と次のステップ

- **`StoreClaims` のオフだと検索 API では拾えない**: dry run で内容確認後、再度 `StoreClaims -> True` で実行する必要あり
- ~~**content hash dedup は未実装**~~: **Stage 6a で実装済み** (Part G 参照)。デフォルト `"Dedup" -> True` で、by-source ファイル単位の `ContentHash` 照合により重複 claim を自動 skip
- **Confidence は LLM が出力しない限り 0.7 固定**: schema に `Confidence` フィールドを含めれば LLM が返した値を使う
- **NBAuthorize は未統合**: 仕様書の `sendDecision / persistDecision` チェックは Stage 6d で追加予定

---


# Part G. Claim dedup と Compact (Stage 6a)

Stage 5 の既知制約だった「同じ内容の claim を 2 回 extract すると重複 append される」問題を解決した Stage 6a の使用例です。**書込み時の dedup** と **過去蓄積分の Compact** の 2 段構えです。

ストーリー:

> 「Stage 5 で抽出した claim の検証を繰り返しているうちに、同じ内容が ClaimStore に何重にも積もってしまった。再 extract のたびに dedup したいし、既存の重複もまとめて圧縮したい。」

---

## Stage 6a の概要

| 機能 | 場所 | 既定 |
|---|---|---|
| 書込み時 dedup (by-source 単位) | `SourceVaultExtract[..., "Dedup" -> True]` | **True** |
| 全体 dedup (master rebuild) | `SourceVaultClaimStoreCompact[]` | DryRun: False / Backup: True |
| Verbose | `SourceVault\`$SourceVaultExtractVerbose = True` | False |

書込み時 dedup は **by-source ファイル単位** で `ContentHash` を照合します。master 全体ではないので、同じ source への重複抽出だけが skip されます。**異なる source 間の重複は skip されません** (別 source として残ります)。

`ContentHash` は `Subject` + `Predicate` + `Object` + `SourceSpan` を JSON 化して SHA-256 を取った値です。LLM が同じ文章から同じ claim を抽出すれば一致します。

---

## 例 G-1: Stage 6a 機能の確認

```mathematica
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-6a-dedup-and-compact" *)

(* 機能の有無確認 *)
Options[SourceVaultExtract]
```

**期待される出力 (`"Dedup" -> True` が含まれていれば Stage 6a):**

```
{"Topic" -> Automatic, "ModelIntent" -> "extraction",
 "StoreClaims" -> True, "Dedup" -> True,
 "Validation" -> "None", MaxCharacters -> 8000, Timeout -> 180}
```

```mathematica
Names["SourceVault`SourceVaultClaimStoreCompact"]
(* → {"SourceVault`SourceVaultClaimStoreCompact"} *)
```

---

## 例 G-2: dedup の基本動作 — 同じ span を 2 回 extract

arXiv 論文 page 1 を **2 回** 同じ schema で extract します。`Dedup` がデフォルト True なので、2 回目は既存の hash を見て skip されます。

```mathematica
(* 事前に snapshot を ingest 済みとする *)
snapId = "snap-sha256-cd072e3fc3ac318ee354a9db3763aa7c27df0504ebc71c5356b38ddb3ca76f2f";
span = SourceVaultSpan[snapId, "Pages" -> {1}];

(* 状態確認 (現状の dedup 前カウント) *)
before = SourceVaultClaimStoreStatus[];
beforeCount = before["MasterClaims"]

(* 1 回目: 通常通り抽出 *)
res1 = SourceVaultExtract[span, "FreeText", "Topic" -> "dedup-demo"];
{res1["Status"], res1["Count"],
 res1["ExtractedCount"], res1["DedupSkipped"]}
(* → {"OK", 5, 5, 0}  — LLM が 5 件抽出、5 件新規 store、skip 0 *)

(* 2 回目: 同じ span を再 extract *)
res2 = SourceVaultExtract[span, "FreeText", "Topic" -> "dedup-demo"];
{res2["Status"], res2["Count"],
 res2["ExtractedCount"], res2["DedupSkipped"]}
(* → {"OK", 0, 5, 5}  — LLM はまた 5 件返したが、すべて既存と一致して skip *)

(* 最終 master 行数 = 1 回目の 5 件のみ *)
after = SourceVaultClaimStoreStatus[];
{before["MasterClaims"], after["MasterClaims"]}
```

`Count` (実 store 数) と `ExtractedCount` (LLM 抽出数) の差が `DedupSkipped` です。

> **メモ**: LLM の応答揺れで `Subject` 等が少し違うと別 claim として扱われます (hash が異なる)。テキストが完全一致する保証はないので、`DedupSkipped` が必ず `ExtractedCount` と一致するとは限りません。

---

## 例 G-3: Verbose で dedup の動作を可視化

```mathematica
SourceVault`$SourceVaultExtractVerbose = True;

res = SourceVaultExtract[span, "FreeText", "Topic" -> "dedup-demo"]
```

**Print 出力 (例):**

```
[SourceVaultExtract] calling ClaudeQueryBg with prompt of 5234 chars (timeout=180s)...
[SourceVaultExtract] response in 18.3s: String(2847 chars)
[SourceVaultExtract] Dedup: 5 claim(s) skipped (already in by-source/src-arxiv-1706.03762.jsonl)
```

dedup が走ったかどうか、いくつ skip されたかを実時間で確認できます。

```mathematica
SourceVault`$SourceVaultExtractVerbose = False;
```

---

## 例 G-4: dedup を意図的に切る

過去の調査記録を意図的に重複させたい場合や、dedup の影響を確認したい場合:

```mathematica
res = SourceVaultExtract[span, "FreeText",
  "Topic" -> "dedup-demo",
  "Dedup" -> False];

{res["Count"], res["ExtractedCount"], res["DedupSkipped"]}
(* → {5, 5, 0}  — Dedup スキップなし、全件 store *)
```

`"Dedup" -> False` は **Stage 5 以前の挙動と完全に同じ** になります。互換性のため、引数なしの `SourceVaultExtract` は dedup 有効 (新しい挙動) ですが、`"Dedup" -> False` を明示すれば古い挙動も得られます。

---

## 例 G-5: SourceVaultClaimStoreCompact — DryRun でまず確認

既存 ClaimStore に蓄積した重複を圧縮します。**まず DryRun で何件 remove されるかを確認** するのが推奨手順です:

```mathematica
SourceVaultClaimStoreCompact["DryRun" -> True]
```

**期待される出力:**

```
<|
  "Status" -> "OK",
  "BeforeCount" -> 47,
  "AfterCount" -> 38,
  "Removed" -> 9,
  "BackupPaths" -> {},
  "DryRun" -> True,
  "Errors" -> {}
|>
```

DryRun=True ではファイルには触らず、`ContentHash` で uniq した場合の件数だけ計算します。

---

## 例 G-6: SourceVaultClaimStoreCompact — 実行 (Backup あり)

```mathematica
SourceVaultClaimStoreCompact[]
```

**期待される出力:**

```
<|
  "Status" -> "OK",
  "BeforeCount" -> 47,
  "AfterCount" -> 38,
  "Removed" -> 9,
  "BackupPaths" -> {
    "...\\claims\\claims.jsonl.bak.20260519T123045",
    "...\\claims\\by-topic\\dedup-demo.jsonl.bak.20260519T123045",
    "...\\claims\\by-source\\src-arxiv-1706.03762.jsonl.bak.20260519T123045",
    ...
  },
  "DryRun" -> False,
  "Errors" -> {},
  "RewriteResult" -> <|"Errors" -> {}, "MasterLines" -> 38,
                       "TopicFiles" -> 1, "SourceFiles" -> 1|>
|>
```

実行内容:

1. `master.jsonl` を全読込
2. `ContentHash` で `DeleteDuplicatesBy` (古い方を残す: `Reverse → DeleteDuplicatesBy → Reverse` パターン)
3. `Backup -> True` なら master + by-topic + by-source 全ファイルを `.bak.<timestamp>` にコピー
4. tmp ファイルへ atomic write → rename で全インデックスを置換
5. by-topic / by-source は master から再分配 (古いファイルは削除して書き直し)

`Removed: 0` の場合は何もせず、Backup も作りません (`"Reason" -> "NoDuplicates"`)。

---

## 例 G-7: SourceVaultClaimStoreCompact — Backup を切る

頻繁に Compact する場合や、`.bak.<ts>` ファイルが溜まると困る場合:

```mathematica
SourceVaultClaimStoreCompact["Backup" -> False]
```

**非推奨**: Compact は内容を破壊的に変更します。Backup を切ると rollback できません。CI や自動化以外では `Backup -> True` を残すことを推奨します。

---

## 例 G-8: Compact 後の整合性確認

```mathematica
(* Before *)
b = SourceVaultClaimStoreStatus[];
b["MasterClaims"]    (* 47 *)

(* Compact *)
SourceVaultClaimStoreCompact[];

(* After *)
a = SourceVaultClaimStoreStatus[];
a["MasterClaims"]    (* 38 *)

(* 検索 API も整合性が取れているはず *)
Length @ SourceVaultClaimsForTopic["transformer-architecture"]
Length @ SourceVaultClaimsForSource["src-arxiv-1706.03762"]
```

`by-topic` / `by-source` は master の subset なので、Compact 後はどの軸で読んでも uniq された結果が得られます。

---

## 例 G-9: dedup の scope の検証 — 異なる source への抽出は dedup されない

Stage 6a の dedup は **by-source ファイル単位** です。`ContentHash` が同じでも source が違えば別 claim として扱われます。これは「異なる論文に同じ事実が書かれているケース」を別 evidence として残すための設計です。

```mathematica
(* source A から抽出 *)
spanA = SourceVaultSpan["snap-A...", "Pages" -> {1}];
resA = SourceVaultExtract[spanA, "NumericFacts",
  "Topic" -> "constants"];
resA["Count"]   (* 例: 4 *)

(* source B から (同じ事実が書かれている別論文) *)
spanB = SourceVaultSpan["snap-B...", "Pages" -> {1}];
resB = SourceVaultExtract[spanB, "NumericFacts",
  "Topic" -> "constants"];
resB["Count"]   (* 例: 4  — A と内容が被っていても dedup されない *)

(* master には 8 件、by-topic にも 8 件、by-source には A/B 各 4 件 *)
SourceVaultClaimStoreStatus[]["MasterClaims"]   (* 8 *)
Length @ SourceVaultClaimsForTopic["constants"]  (* 8 *)
Length @ SourceVaultClaimsForSource["src-A..."]  (* 4 *)
Length @ SourceVaultClaimsForSource["src-B..."]  (* 4 *)
```

これによって「どの source から得た事実か」が常に追跡可能になります。**source 横断の dedup が必要な場合は `SourceVaultClaimsForTopic` 結果を `GatherBy[..., "ContentHash"]` で後処理** してください。

---

## Stage 6a の物理ストレージ (新規)

```
PrivateVault/parsed/.../claims/
  claims.jsonl                       # master (dedup 済み)
  claims.jsonl.bak.20260519T123045   # Compact 時 backup
  by-topic/
    constants.jsonl
    constants.jsonl.bak.20260519T123045
    ...
  by-source/
    src-arxiv-1706.03762.jsonl
    src-arxiv-1706.03762.jsonl.bak.20260519T123045
    ...
```

`.bak.<timestamp>` は単純なファイルコピーです。問題があれば手動で `.bak.<ts>` を元のパスに rename すれば rollback できます。

```mathematica
(* 例: rollback (Mathematica 内で) *)
CopyFile[
  "....jsonl.bak.20260519T123045",
  "....jsonl",
  OverwriteTarget -> True]
```

定期的に古い `.bak.*` を掃除するスクリプトを別途用意することを推奨します (Stage 6a 本体には掃除機能はありません)。

---

## Compact の atomic 性について

`iClaimsAtomicWrite` は次の手順で書き込みます:

1. `path.tmp` に全 line を `BinaryWrite` (UTF-8、`\n` 終端)
2. `Close[strm]`
3. 既存 `path` を `DeleteFile`
4. `RenameFile[tmp, path]`
5. 失敗時は `<|"Status" -> "Failed", "Reason" -> "RenameFailed"|>` を返す

Windows では POSIX 流の atomic rename が無いため、Step 3 と 4 の間にクラッシュすると path が消えた状態になります。実際の運用ではほぼ無視できる確率ですが、Backup を取っていれば確実に復旧できます。

---

## Stage 6a の制約と次のステップ

- **dedup scope は by-source 単位**: 異なる source 間の dedup はしない (意図的な設計)
- **Compact は master 全件読込が必要**: 巨大 (10万件以上) になると遅くなる可能性あり。将来は `bloom filter` or `incremental compact` で改善予定
- **Backup の自動掃除はない**: `.bak.<timestamp>` ファイルは手動掃除が必要
- **dedup キーは固定** (Subject/Predicate/Object/SourceSpan): topic や schema を変えても hash は変わらない

**次のステップ候補 (Stage 6b/6c/6d/8)**:

- Stage 6b: Compiled Registry (model resolve の本格化)
- Stage 6c: EvidenceBundle (生成物 → claim 依存追跡)
- Stage 6d: NBAuthorize 統合 (sendDecision/persistDecision)
- Stage 8: vN diff (snapshot 間の page hash 差分)

---


# Part H. Evidence Bundle (Stage 6c)

仕様書 §4.6 / §5.7 / §12.2 / §17.5 の Evidence Bundle 実装です。生成物 (`.wl`/`.md`/`.tex` 等) が依存した source / claim をまとめて記録し、source の snapshot lifecycle が変わったら自動で stale 検出します。

ストーリー:

> 「ある論文をベースに ODE シミュレーションコード `simulation.wl` を生成した。元論文が arXiv v2 → v3 に更新されたら、このコードが古くなったことを自動で知りたい。」

---

## Stage 6c の概要

| 機能 | 用途 |
|---|---|
| `SourceVaultBundleCreate[name, deps]` | 生成物 → source/claim 依存 を bundle として保存 |
| `SourceVaultBundleStatus[bundleId]` | bundle の現在 status (Current/Stale/NeedsReview/Invalidated) |
| `SourceVaultBundleInvalidate[bundleId, reason]` | 手動 invalidate |
| `SourceVaultBundleGet[bundleId]` / `List[]` / `Delete[bundleId]` | 読込 / 一覧 / 削除 |

**Status の計算ロジック (重要)**:

1. **手動 Invalidate されていれば** `"Invalidated"` (最優先)
2. **参照する snapshot のいずれかが `"Invalidated"`** → bundle も `"Invalidated"`
3. **snapshot がストアから見つからない (削除済み)** → `"NeedsReview"`
4. **snapshot のいずれかが `"Stale"` / `"Frozen"`** → `"Stale"`
5. **すべて `"Current"`** → `"Current"`

`LifecycleStatus` は Stage 2 で snapshot meta に書かれているフィールドです。Stage 8 (vN diff) で arXiv 更新検出が入れば、自動で `"Stale"` 化されます。

---

## 例 H-1: Stage 6c 機能の確認

```mathematica
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-6c-evidence-bundle" *)

Names["SourceVault`SourceVaultBundle*"]
(* → {"SourceVaultBundleCreate", "SourceVaultBundleDelete",
       "SourceVaultBundleGet", "SourceVaultBundleInvalidate",
       "SourceVaultBundleList", "SourceVaultBundleStatus"} *)
```

---

## 例 H-2: bundle を作る — ODE シミュレーション例

Attention 論文の snapshot に依存した生成コード `simulation.wl` の依存記録:

```mathematica
(* 既存の snapshot / claim から bundle を組み立てる *)
result = SourceVaultBundleCreate["ODE-Simulation-Example",
  <|
    "GeneratedFiles" -> {"simulation.wl", "simulation.nb"},
    "Sources" -> {
      <|"SourceId" -> "src-arxiv-1706.03762",
        "SnapshotId" -> "snap-sha256-cd072e3fc3..."|>
    },
    "SourceSpans" -> {
      <|"SnapshotId" -> "snap-sha256-cd072e3fc3...",
        "Locator" -> <|"Pages" -> {3, 4}|>,
        "Role" -> "ExtractionInput"|>
    },
    "Claims" -> {
      (* Stage 5 で抽出した claim id を入れる *)
      "claim-transformer-test-1747613091000-a1b2c3"
    },
    "Generator" -> <|
      "Tool" -> "ClaudeOrchestrator",
      "WorkflowId" -> "wf-simulation-2026-05-19",
      "ModelIntent" -> "code-heavy",
      "ResolvedModel" -> "claude-sonnet-4-6"
    |>
  |>,
  "Kind" -> "SimulationExample"];

result["Status"]   (* → "OK" *)
result["BundleId"] (* → "bundle-ODE-Simulation-Example-...-xxxxxx" *)
result["Path"]     (* → "...\\bundles\\bundle-...-....json" *)
```

bundle id を覚えておきます (以降の例で使用):

```mathematica
bid = result["BundleId"];
```

---

## 例 H-3: 作った bundle を読み出す

```mathematica
b = SourceVaultBundleGet[bid];
Keys[b]
(* → {"BundleId", "Name", "Kind", "GeneratedAt", "GeneratedFiles",
       "Sources", "SourceSpans", "Claims", "Generator",
       "ManualInvalidation", "ParentBundle", "ChildBundles"} *)

b["Kind"]             (* → "SimulationExample" *)
b["GeneratedFiles"]   (* → {"simulation.wl", "simulation.nb"} *)
Length @ b["Sources"]
Length @ b["Claims"]
```

---

## 例 H-4: 一覧 (List)

```mathematica
SourceVaultBundleList[]
(* → {"bundle-ODE-Simulation-Example-...-xxxxxx", ...} *)
```

`bundles/` ディレクトリに置かれた全 `bundle-*.json` から id を抽出して返します。

---

## 例 H-5: Status 計算 — 健全な状態 ("Current")

```mathematica
SourceVaultBundleStatus[bid]
```

**期待される出力 (snapshot がすべて正常な場合):**

```mathematica
<|
  "Status" -> "Current",
  "Reason" -> "All snapshots are Current",
  "AffectedSnapshots" -> {},
  "AffectedClaims" -> {"claim-..."},
  "MissingSnapshots" -> {},
  "Lifecycles" -> {"Current"}
|>
```

参照する snapshot がすべて `LifecycleStatus -> "Current"` (default) なので `"Current"` 判定。

---

## 例 H-6: Status 計算 — snapshot lifecycle 更新時

Stage 2/Stage 8 で snapshot を `"Stale"` にすると、bundle も自動で `"Stale"` になります (実証用に手動で snapshot meta を書き換える例):

```mathematica
(* 実環境では Stage 8 が自動でやる作業 *)
snapId = "snap-sha256-cd072e3fc3...";
meta = SourceVault`Private`iSnapshotMetaLoad[snapId];
meta["LifecycleStatus"] = "Stale";  (* 注: 通常は SourceVault が管理 *)
SourceVault`Private`iSnapshotMetaSave[snapId, meta];

(* 再度 status を計算 *)
SourceVaultBundleStatus[bid]
(* → <|"Status" -> "Stale", "Reason" -> "One or more snapshots are Stale/Frozen", ...|> *)
```

**重要**: `Private` 経由の meta 書き換えはデモ用です。実運用では Stage 8 (vN diff) が自動で行うべき処理です。

---

## 例 H-7: 手動 Invalidate

claim 内容に問題があったり、生成コードに重大バグが見つかったとき、bundle を手動で invalidate:

```mathematica
SourceVaultBundleInvalidate[bid,
  "Generator had a bug in ODE step computation"]
(* → <|"Status" -> "OK", "BundleId" -> bid, "Reason" -> "Generator had a bug..."|> *)

(* 以降、Status は常に "Invalidated" を返す (snapshot lifecycle に関係なく最優先) *)
SourceVaultBundleStatus[bid]
(* → <|
       "Status" -> "Invalidated",
       "Reason" -> "Manual: Generator had a bug in ODE step computation",
       "AffectedSnapshots" -> {},
       "AffectedClaims" -> {"claim-..."},
       "InvalidatedAt" -> "...."
     |> *)
```

手動 Invalidate は **bundle JSON に `"ManualInvalidation"` フィールドを書き残す** 形で永続化されるので、再起動後も有効です。

---

## 例 H-8: 削除 (debug 用)

bundle を完全削除:

```mathematica
SourceVaultBundleDelete[bid]
(* → <|"Status" -> "Deleted", "BundleId" -> bid|> *)

SourceVaultBundleGet[bid]
(* → Missing["NotFound"] *)
```

**警告**: Delete は破壊的操作です。本番運用では Invalidate を推奨。

---

## 例 H-9: 親子 bundle (Phase 2 への布石)

Stage 6c Phase 1 では集約計算は未実装ですが、フィールドは予約済みです。`ParentBundle` / `ChildBundles` を deps に渡せばそのまま保存されます:

```mathematica
parent = SourceVaultBundleCreate["Paper-2026-Q2-Notebook",
  <|
    "GeneratedFiles" -> {"paper.nb"},
    "Sources" -> {},
    "Claims" -> {},
    "ChildBundles" -> {bid (* 例 H-2 で作った子 *)}
  |>,
  "Kind" -> "Notebook"];

(* 親 bundle から子を辿れる *)
SourceVaultBundleGet[parent["BundleId"]]["ChildBundles"]
(* → {"bundle-ODE-Simulation-Example-..."} *)
```

**現状**: `SourceVaultBundleStatus[parent["BundleId"]]` は自分自身の Sources/Claims しか見ません。子 bundle の status 集約 (`"AggregatedFromChildren"`) は将来実装予定 (Stage 6c Phase 2)。

---

## Bundle の物理ストレージ

```
PrivateVault/bundles/
  bundle-ODE-Simulation-Example-1747624123456-a1b2c3.json
  bundle-Paper-2026-Q2-Notebook-1747624234567-d4e5f6.json
  ...
```

JSON 形式 (1 bundle = 1 ファイル):

```json
{
  "BundleId": "bundle-ODE-Simulation-Example-1747624123456-a1b2c3",
  "Name": "ODE-Simulation-Example",
  "Kind": "SimulationExample",
  "GeneratedAt": "2026-05-19T12:34:56",
  "GeneratedFiles": ["simulation.wl", "simulation.nb"],
  "Sources": [{"SourceId": "src-arxiv-1706.03762", "SnapshotId": "snap-..."}],
  "SourceSpans": [{...}],
  "Claims": ["claim-..."],
  "Generator": {"Tool": "ClaudeOrchestrator", ...},
  "ManualInvalidation": null,
  "ParentBundle": null,
  "ChildBundles": []
}
```

- **`iSanitizeForJSON` 経由**: `Missing[]` → `null`、`DateObject` → 日付文字列、その他 → `InputForm` 文字列化 (Stage 5 と同じパターン)
- **読み込みは `ReadByteArray` 経路**: Windows 罠 #20 対応
- **集中編集なし**: 1 bundle = 1 ファイル、append/edit 競合は基本起こらない

---

## Status 計算の優先順位 (再確認)

| 条件 | 結果 |
|---|---|
| `ManualInvalidation` が設定済み | `"Invalidated"` |
| いずれかの snapshot が `"Invalidated"` | `"Invalidated"` |
| snapshot が見つからない (削除済み) | `"NeedsReview"` |
| いずれかの snapshot が `"Stale"` / `"Frozen"` | `"Stale"` |
| すべて `"Current"` または未定義 | `"Current"` |

**手動 Invalidate が最優先** — 一度 invalidate すれば、後で snapshot の lifecycle が `"Current"` に戻ろうとも bundle 自体は `"Invalidated"` のままです。やり直したい場合は `Delete → 再 Create` してください。

---

## Stage 6c の制約と次のステップ

**現状 (Phase 1)**:

- 単一 bundle の CRUD + status 計算のみ
- 親子 bundle は **保存はする**が集約計算は未実装
- claim/source のリンクは BundleId/SnapshotId/ClaimId 文字列のみ (lazy reference)
- `iBundleComputeStatus` は毎回 snapshot meta を読み込む (cache なし)

**Phase 2 (将来)**:

- 階層 bundle の status 集約 (`"AggregatedFromChildren"`)
- 双方向リンク (`SourceVaultBundlesForClaim[claimId]`, `BundlesForSource[sourceId]`)
- WorkflowRun 自動連携 (ClaudeOrchestrator から自動 bundle 生成)

**Phase 3 (将来)**:

- hash-based stale 検出: parsed text hash / extractor prompt hash の変化 (§12.2)
- contradiction 検出 (§12.3): 同じ subject/predicate に異なる object の claim 検出 → bundle 自動 `"NeedsReview"`

**次セッション候補 (Stage 6b/6d/8)**:

- Stage 6b: Compiled Registry (model resolve の本格化)
- Stage 6d: NBAuthorize 統合 (sendDecision/persistDecision)
- Stage 8: vN diff (snapshot 間の page hash 差分)

---


# Part I. vN diff + snapshot lifecycle (Stage 8)

仕様書 §4.2.1 (Source lifecycle events) と §5.2 (Refresh) の最小実装です。Stage 4B で蓄積していた `page-hashes.json` を活用して snapshot 間の差分を計算し、snapshot の `LifecycleStatus` を更新することで Stage 6c の Bundle が自動 stale 化される仕組みを提供します。

ストーリー:

> 「arXiv:1706.03762 v1 で simulation コードを書いたら、v2 が出てた。v2 で再 ingest したい。どのページが変わった?  既存の Bundle はどう扱う?」

---

## Stage 8 の概要

| 機能 | 用途 |
|---|---|
| `SourceVaultDiffVersions[v1, v2]` | snapshot 間の page hash 差分 (Added/Removed/Changed/Unchanged) |
| `SourceVaultMarkSnapshotStale[snap, reason]` | snapshot を手動 stale 化 → 参照 Bundle 自動 stale |
| `SourceVaultMarkSnapshotInvalidated[snap, reason]` | Retraction (公式取り下げ) |
| `SourceVaultRefreshSnapshot[old, new, reason]` | 高レベル refresh: diff + Stale + SupersededBy + event 一括 |
| `SourceVaultBundlesForSnapshot[snap]` | 影響を受ける bundle id 列挙 (Stage 6c Phase 2 の双方向リンク先取り) |
| `SourceVaultSourceEvents[opts]` / `SourceVaultSourceEventAppend[event]` | `events/source-events.jsonl` event log |

**Lifecycle Event の 4 種** (仕様書 §4.2.1):

| Event | 例 | API |
|---|---|---|
| `VersionedUpdate` | arXiv v2 → v3 | `MarkSnapshotStale` / `RefreshSnapshot` |
| `Retraction` | 論文公式取り下げ | `MarkSnapshotInvalidated` |
| `SourceDeletion` | URL 404 | (手動 event append) |
| `SchemaChange` | API 形式変更 | (手動 event append) |

---

## 例 I-1: Stage 8 機能の確認

```mathematica
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-8-vn-diff-and-lifecycle" *)

(* Stage 8 API 群 *)
Names["SourceVault`SourceVault*"] // Length
Names["SourceVault`SourceVault*Snapshot*"]
(* → {"SourceVaultBundlesForSnapshot", "SourceVaultMarkSnapshotInvalidated",
       "SourceVaultMarkSnapshotStale", "SourceVaultRefreshSnapshot",
       "SourceVaultSnapshots"} *)
```

---

## 例 I-2: 同一 snapshot の自己 diff (sanity check)

同じ snapshot を 2 つ指定すると、すべて Unchanged になるはず:

```mathematica
snapId = "snap-sha256-cd072e3fc3ac318ee354a9db3763aa7c27df0504ebc71c5356b38ddb3ca76f2f";

(* Stage 4B で page-hashes.json が作られている必要あり。なければ先に: *)
(* SourceVaultExtractPages[snapId, All] *)

diff = SourceVaultDiffVersions[snapId, snapId]
```

**期待される出力:**

```mathematica
<|
  "Status" -> "OK",
  "V1Snap" -> "snap-sha256-cd072e3fc3...",
  "V2Snap" -> "snap-sha256-cd072e3fc3...",
  "V1PageCount" -> 15,
  "V2PageCount" -> 15,
  "AddedPages" -> {},
  "RemovedPages" -> {},
  "ChangedPages" -> {},
  "UnchangedPages" -> {1, 2, 3, ..., 15}
|>
```

---

## 例 I-3: snapshot を手動で Stale 化 → Bundle が自動 stale 化

Stage 6c で作った Bundle が、ベースの snapshot が `"Stale"` になった瞬間に自動で `"Stale"` 判定になることを実証します。

```mathematica
(* 1. Bundle を作っておく (Part H 参照) *)
res = SourceVaultBundleCreate["Demo-Bundle",
  <|
    "GeneratedFiles" -> {"demo.wl"},
    "Sources" -> {<|"SourceId" -> "src-arxiv-1706.03762",
                    "SnapshotId" -> snapId|>},
    "Claims" -> {},
    "Generator" -> <|"Tool" -> "ClaudeOrchestrator"|>
  |>];
bid = res["BundleId"];

(* 2. 現在の status (Current のはず) *)
SourceVaultBundleStatus[bid]["Status"]
(* → "Current" *)

(* 3. snapshot を Stale 化 *)
SourceVaultMarkSnapshotStale[snapId, "arXiv v2 has been released"]
(* → <|"Status" -> "OK",
       "SnapshotId" -> ...,
       "LifecycleStatus" -> "Stale",
       "Reason" -> "arXiv v2 has been released",
       "Event" -> <|"EventType" -> "VersionedUpdate", ...|>|> *)

(* 4. Bundle status を再計算 *)
SourceVaultBundleStatus[bid]
(* → <|"Status" -> "Stale",
       "Reason" -> "One or more snapshots are Stale/Frozen",
       "AffectedSnapshots" -> {<|"SnapshotId" -> ..., "LifecycleStatus" -> "Stale"|>},
       ...|> *)
```

`MarkSnapshotStale` が snapshot meta を書き換えた瞬間、その snapshot を参照しているすべての Bundle が次回 `BundleStatus` 呼出で `"Stale"` を返します。**Bundle 側は何もしていない** のがポイントです (lazy evaluation)。

---

## 例 I-4: source-events.jsonl の event log

`MarkSnapshotStale` / `MarkSnapshotInvalidated` / `RefreshSnapshot` は自動で event を記録します:

```mathematica
SourceVaultSourceEvents[]
(* → {
   <|"EventId" -> "evt-...",
     "EventType" -> "VersionedUpdate",
     "SourceId" -> "src-arxiv-1706.03762",
     "OldSnapshotId" -> "snap-sha256-cd072e3fc3...",
     "NewSnapshotId" -> "Missing[NotProvided]",
     "Reason" -> "arXiv v2 has been released",
     "Timestamp" -> "..."|>,
   ...
} *)

(* 特定 source の event だけ *)
SourceVaultSourceEvents["SourceId" -> "src-arxiv-1706.03762"]

(* 特定 event type だけ *)
SourceVaultSourceEvents["EventType" -> "VersionedUpdate"]

(* 特定 snapshot 関連の event だけ (Old/NewSnapshotId のどちらかで照合) *)
SourceVaultSourceEvents["SnapshotId" -> snapId]
```

物理位置: `<PrivateVault>/events/source-events.jsonl` (append-only JSONL、Stage 5 と同じパターン)。

---

## 例 I-5: SourceVaultBundlesForSnapshot — 影響範囲の可視化

snapshot を Stale 化したとき、どの Bundle が影響を受けるかを事前に確認できます:

```mathematica
SourceVaultBundlesForSnapshot[snapId]
(* → {"bundle-Demo-Bundle-...", "bundle-ODE-Simulation-Example-...", ...} *)

(* 個別 Bundle の status を確認 *)
SourceVaultBundleStatus /@ SourceVaultBundlesForSnapshot[snapId]
```

**使い道**: 「v2 にアップグレードする前に、どの生成物に影響が出るか把握したい」というワークフロー。Stage 6c Phase 2 で双方向リンクが本実装されれば、O(1) で引けるようになる予定 (現状は全 bundle の Sources を線形スキャン)。

---

## 例 I-6: 高レベル refresh シミュレーション

実環境では `SourceVaultIngest["arxiv:1706.03762v2"]` で v2 を取得しますが、ここでは概念実証として既存の snapshot を「新版」に見立てます:

```mathematica
(* 仮想: 別の snapshot を新版扱い (本来は v2 ingest した結果) *)
oldSnap = snapId;
newSnap = "snap-sha256-some-other-...";  (* 実際の別 snapshot id *)

result = SourceVaultRefreshSnapshot[oldSnap, newSnap,
  "Upgraded from v1 to v2"];

result["Status"]              (* → "OK" *)
result["Diff"]                (* page hash diff *)
result["Event"]               (* 自動記録された event *)

(* oldSnap の meta を確認 — SupersededBy が設定されているはず *)
SourceVault`Private`iSnapshotMetaLoad[oldSnap]["LifecycleStatus"]
(* → "Stale" *)
SourceVault`Private`iSnapshotMetaLoad[oldSnap]["SupersededBy"]
(* → newSnap *)
```

`RefreshSnapshot` がやること:

1. `SourceVaultDiffVersions[old, new]` を呼んで差分計算
2. `old` snapshot の `LifecycleStatus` を `"Stale"` に + `"SupersededBy"` を `new` に設定
3. `events/source-events.jsonl` に `EventType: "VersionedUpdate"` を append
4. event の `DiffSummary` に diff の件数サマリも記録

---

## 例 I-7: Retraction (Invalidated)

論文が公式取り下げになった場合は `MarkSnapshotInvalidated`:

```mathematica
SourceVaultMarkSnapshotInvalidated[snapId,
  "Paper retracted: data fabrication detected"]

(* Bundle status は最上位の "Invalidated" になる *)
SourceVaultBundleStatus[bid]["Status"]
(* → "Invalidated" *)

(* event log には Retraction として記録 *)
SourceVaultSourceEvents["EventType" -> "Retraction"]
```

`"Stale"` と `"Invalidated"` の違い: `"Stale"` は「再現可能だが古い」、`"Invalidated"` は「もう信用してはいけない」。Bundle status の優先順位は `Manual > Invalidated > NeedsReview > Stale > Current` なので、`Invalidated` は強制力が最大です。

---

## 例 I-8: SourceVaultSourceEventAppend — 手動 event 記録

`SourceDeletion` (URL 404) や `SchemaChange` (API 変更) のように、現状の API ではカバーしていない event を手動で記録できます:

```mathematica
SourceVaultSourceEventAppend[<|
  "EventType" -> "SourceDeletion",
  "SourceId" -> "src-arxiv-1706.03762",
  "Reason" -> "arXiv URL returned 410 Gone"
|>]
(* EventId と Timestamp は自動付与 *)

(* または SchemaChange *)
SourceVaultSourceEventAppend[<|
  "EventType" -> "SchemaChange",
  "SourceId" -> "src-openai-models-api",
  "Reason" -> "API response field renamed: 'context_window' -> 'context_length'"
|>]
```

**現状**: これらは event log に記録するだけで、Bundle の Status には自動的には反映されません (現状の Bundle Status 計算は `LifecycleStatus` の `"Stale" / "Invalidated"` のみを見る)。

将来 (Stage 8 Phase 2) では event log を Bundle Status 計算で参照して、`SourceDeletion` であれば `"NeedsReview"`、`SchemaChange` であれば `"Frozen"` を返すように拡張予定です。

---

## 物理ストレージ (Stage 8 新規)

```
PrivateVault/
  events/
    source-events.jsonl       # append-only event log (Stage 8)
  raw/meta/
    snap-....json              # LifecycleStatus + SupersededBy (Stage 8 で更新)
  parsed/by-snap/
    <snapshotId>/page-hashes.json  # Stage 4B で蓄積、Stage 8 で diff
  bundles/                     # Stage 6c
  claims/                      # Stage 5/6a
```

event log の形式:

```json
{"EventId":"evt-1747625300000-a1b2c3","EventType":"VersionedUpdate","SourceId":"src-arxiv-1706.03762","OldSnapshotId":"snap-sha256-cd...","NewSnapshotId":"snap-sha256-xy...","Reason":"arXiv v2 has been released","Timestamp":"...","DiffSummary":{"AddedPages":2,"RemovedPages":0,"ChangedPages":3,"UnchangedPages":10}}
```

---

## Stage 8 → Stage 6c の自動連動 — まとめ

```
   [SourceVaultMarkSnapshotStale]
              ↓
   snapshot meta.LifecycleStatus = "Stale"
              ↓
              (lazy, on demand)
              ↓
   SourceVaultBundleStatus[bid]
              ↓
   iBundleComputeStatus が snapshot meta を毎回読込
              ↓
   いずれかの snapshot が "Stale" → bundle も "Stale"
```

**重要なポイント**: Bundle は snapshot lifecycle の **passive consumer**。Bundle 自体は何も変更されず、`BundleStatus` 呼出のたびに最新の snapshot lifecycle を読み取って計算します。これにより:

- snapshot を fixup したら Bundle が自動で `"Current"` に戻る
- Bundle を編集する必要がない (broadcast invalidation 不要)
- 一貫性が保証される

---

## Stage 8 の制約と次のステップ

**現状 (Phase 1)**:

- diff は page hash レベルのみ — equation block / table 単位は未対応
- claim-level diff は未実装 (どの claim が新規/変更/削除か)
- contradiction 検出 (§12.3) は未実装
- 自動 fetch (arXiv 定期 refresh) は network が必要なので未実装
- event log を Bundle Status 計算で参照していない (Lifecycle のみ)
- `SourceVaultBundlesForSnapshot` は線形スキャン (Bundle 件数が増えると遅くなる)

**Phase 2 (将来)**:

- claim-level diff: `SourceVaultDiffClaims[v1Snap, v2Snap, topic, schema]`
- event log を Bundle Status 計算で参照 (`SourceDeletion` → `NeedsReview`、`SchemaChange` → `Frozen`)
- 自動 fetch: `SourceVaultRefresh[sourceRef]` で arXiv API を叩いて最新 version 検出
- 双方向リンク cache (Bundle 検索 O(1) 化)
- Petri net 化 (Stage 7 と統合)

**Phase 3**:

- contradiction 検出 (§12.3): 同じ subject/predicate に異なる object → bundle 自動 `"NeedsReview"`
- `contradictions.md` レポート生成

---


# Part J. NBAuthorize 統合 (Stage 6d)

仕様書 §14.4 で要求されている **2 段階 authorization** (sendDecision + persistDecision) を `SourceVaultExtract` に組み込み、`SourceVaultContext` の Decision 処理も `RequireApproval` 対応に拡張しました。

ストーリー:

> 「機密性の高い source から claim を抽出するときは、LLM に送る前と保存する前で、NBAccess が許可するか必ず確認したい。Permit/Screen/RequireApproval/Deny を区別したい。」

---

## Stage 6d の概要

### 2 段階 authorization (`SourceVaultExtract`)

```
   sourceSpan
       ↓
   [iSpecFromSnapshotMeta → NBAuthorize] sendDecision
       ↓ (Permit/Screen のみ通す)
   context 取得 + LLM 抽出
       ↓
   [iSpecFromClaim → NBAuthorize] persistDecision (代表 claim で batch 判定)
       ↓ (Permit/Screen のみ通す)
   ClaimStore に保存
```

### Decision の扱い (仕様書 §14.4 準拠)

| Decision | 挙動 |
|---|---|
| `"Permit"` | そのまま続行 |
| `"Screen"` | Phase 1 では Permit と同等扱い (redaction は Phase 2) |
| `"RequireApproval"` | `Status -> "RequiresApproval"` で早期 return |
| `"Deny"` (or その他) | `Status -> "DeniedByNBAccess"` で早期 return |

### opt-out スイッチ

```mathematica
SourceVaultExtract[..., "AuthorizationCheck" -> False]
```

Stage 5 までの「素通し」挙動に戻せます (regression 回避用)。デフォルトは `True`。

---

## 例 J-1: Stage 6d 機能の確認

```mathematica
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-6d-nbauthorize-integration" *)

"AuthorizationCheck" /. Options[SourceVaultExtract]
(* → True (デフォルト ON) *)
```

---

## 例 J-2: AuthorizationCheck ON で通常実行

NBAccess が Permit を返す典型的な環境では、Stage 5/6a 時代と同じ挙動 + レスポンスに `AccessDecisions` フィールド追加:

```mathematica
snapId = "snap-sha256-cd072e3fc3ac318ee354a9db3763aa7c27df0504ebc71c5356b38ddb3ca76f2f";
span = SourceVaultSpan[snapId, "Pages" -> {1}];

res = SourceVaultExtract[span, "FreeText",
  "Topic" -> "stage6d-demo"];

res["Status"]               (* → "OK" *)
res["AccessDecisions"]
(* → <|
     "Send"    -> <|"Decision" -> "Permit", ...|>,
     "Persist" -> <|"Decision" -> "Permit", ...|>
   |> *)
```

`AccessDecisions["Send"]` と `["Persist"]` の両方が記録されているのが Stage 6d の証拠です。

---

## 例 J-3: Verbose で 2 段階 decision の動きを見る

```mathematica
SourceVault`$SourceVaultExtractVerbose = True;

res = SourceVaultExtract[span, "FreeText", "Topic" -> "stage6d-verbose"];
```

**Print 出力 (例)**:

```
[SourceVaultExtract] sendDecision: Permit
[SourceVaultExtract] calling ClaudeQueryBg with prompt of 5234 chars (timeout=180s)...
[SourceVaultExtract] response in 18.3s: String(2847 chars)
[SourceVaultExtract] persistDecision: Permit
```

```mathematica
SourceVault`$SourceVaultExtractVerbose = False;
```

---

## 例 J-4: AuthorizationCheck -> False で素通し

Stage 5/6a と完全に同じ挙動になります (regression 回避):

```mathematica
res = SourceVaultExtract[span, "FreeText",
  "Topic" -> "stage6d-skip",
  "AuthorizationCheck" -> False];

res["AccessDecisions"]
(* → <||> (空 Association — NBAuthorize 呼ばれていない) *)
```

---

## 例 J-5: SourceVaultContext の RequireApproval 拡張

Stage 5 以前: `Deny` のみ block。Stage 6d: `RequireApproval` も block:

```mathematica
(* NBAccess が RequireApproval を返す状況をシミュレートできる場合 *)
ctx = SourceVaultContext[span, "Purpose" -> "ClaimExtraction"];

(* Status 候補が 4 種に拡張: *)
(* "OK" | "Failed" | "DeniedByNBAccess" | "RequiresApproval" *)
```

`RequiresApproval` の場合のレスポンス:

```mathematica
<|
  "Status" -> "RequiresApproval",
  "Text" -> "",
  "SourceSpans" -> {span},
  "AccessDecision" -> <|"Decision" -> "RequireApproval", ...|>,
  "Reason" -> "Context retrieval requires approval"
|>
```

---

## NBClaim spec の構造 (`iSpecFromClaim`)

`persistDecision` で NBAuthorize に渡す Spec の構造 (仕様書 §14.2.3 準拠):

```mathematica
<|
  "ObjectClass" -> "Claim",
  "ClaimId" -> "claim-...",
  "Topic" -> "...",
  "Schema" -> "FreeText" | "NumericFacts" | ...,
  "SourceId" -> "src-...",
  "SnapshotId" -> "snap-...",
  "ContentHash" -> "sha256-...",
  "AccessLabel" -> <|
    "Confidentiality" -> "Public" | "Private" | ...,
    "Origin" -> "ArXiv" | "PublicWeb" | "LocalFile" | ...,
    ...
  |>,
  "AccessLevel" -> 0.0..1.0,
  "PrivacyLevel" -> 0.0..1.0,
  "Confidentiality" -> "Public" | "Private",
  "Origin" -> "Extracted"   (* claim 自体の origin *)
|>
```

`AccessLabel` は **claim の元 snapshot meta から派生** します (`iAccessLabelForSource` 経由)。例えば arXiv 論文由来の claim は `"Confidentiality" -> "Public"` で、ローカル PDF 由来の claim は `"Private"` になります。

---

## 2 段階 batch 判定について

仕様書 §14.4.2 では「各 claim に対して個別 authorize」とも読めますが、Phase 1 では **代表 claim (`First[claims]`) で batch 判定** しています。理由:

- 同じ source から抽出された claim はすべて同じ AccessLabel を持つはず
- N 件の claim でそれぞれ NBAuthorize 呼出は冗長 (typical N = 30-50)
- 必要なら呼出側で per-claim authorize を組める

Phase 2 で「claim ごとに異なる AccessLabel」が必要になったら per-claim 判定に拡張します。

---

## Stage 6d の制約と次のステップ

**現状 (Phase 1)**:

- `Screen` decision は Permit と同等扱い (redaction 未実装)
- `SourceVaultBundleCreate` の CreateBundle authorize は未統合 (Stage 6d Phase 2)
- principal/sink の細かい指定 (`"ExtractorSink"` 等) は固定値
- per-claim authorize ではなく batch (First 1 件で代表)

**Phase 2 (将来)**:

- `Screen` → redaction 実装 (`NBRedactExecutionResult` 呼出)
- `SourceVaultBundleCreate` / `BundleStatus` に authorize 追加 (仕様書 §14.4 表参照)
- per-claim 判定オプション
- principal/sink を caller から指定可能に

**残るコア Stage**:

- Stage 6b: Compiled Registry (model resolve の本格化、SourceVaultResolve / SourceVaultLookup の本実装)

---


# Part K. Compiled Registry (Stage 6b) — **Phase 1 最終 Stage**

仕様書 §4.5 (Compiled Registry Entry) / §5.4 (Lookup / Resolve) / §11 (compiled registry の配置) の最小実装。これで Phase 1 のコア機能がすべて揃いました。

ストーリー:

> 「Orchestrator や workflow から model resolve したい。LLM 呼出は嫌だ (低遅延が必要)。public registry と private user override を分離して、bootstrap seed が常に動くようにしたい。」

---

## Stage 6b の概要

| 機能 | 用途 |
|---|---|
| `SourceVaultLookup[topic, key, opts]` | 文字列キー / Association で registry を引く |
| `SourceVaultResolve[kind, query, opts]` | structured query で registry を引く |
| `ClaudeResolveModel[provider, intent]` | 仕様書 §5.4 互換 wrapper |
| `SourceVaultCompileRegistry[topic, entries, opts]` | entries を compiled/<channel>/<topic>.json に保存 |
| `SourceVaultRegisterSeed[topic, entries]` | seeds/<topic>-seed.json に bootstrap データ保存 |
| `SourceVaultListRegistries[opts]` | 登録済み topic 一覧 |
| `SourceVaultRegistryStatus[topic, opts]` | 個別 registry 状態 |

**Lookup ロジック**:
1. compiled/<channel>/<topic>.json を最初に検索
2. 見つからなければ seed (`AllowSeed -> True`、デフォルト) にフォールバック
3. 複数 match なら `Availability` / `Freshness` / `Class` の優先順位で sort

**channel 分離** (仕様書 §11):
- `public` — 公開知識 (model registry など)
- `private` — user routing override / 個人的な registry

---

## 例 K-1: 機能確認 + 自動 bootstrap

```mathematica
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-6b-compiled-registry" *)

(* Stage 6b API 群 *)
Names["SourceVault`SourceVaultLookup" | "SourceVault`SourceVaultResolve" |
      "SourceVault`ClaudeResolveModel" | "SourceVault`SourceVault*Registr*"]

(* パッケージロード時に自動 bootstrap される *)
SourceVaultListRegistries[]
(* → 少なくとも 1 件: {<|"Topic" -> "model-registry", "Channel" -> "seed", "Path" -> ...|>} *)
```

初回ロード時に `seeds/model-registry-seed.json` が自動生成され、デフォルト 6 entries (claudecode / anthropic / openai / lmstudio) が入ります。

---

## 例 K-2: ClaudeResolveModel 互換 wrapper

仕様書 §5.4 で定義された旧 `WikiDBResolveModel` の置き換え wrapper:

```mathematica
res = ClaudeResolveModel["claudecode", "extraction"]
(* → <|
     "Kind" -> "Model",
     "Provider" -> "claudecode",
     "Intent" -> "extraction",
     "ModelId" -> "claude-sonnet-4-6",
     "Availability" -> "Available",
     "Class" -> "Heavy-Local",
     "Capabilities" -> {"Reasoning", "Code"},
     "Freshness" -> "Fresh",
     "PolicySource" -> "seed:model-seed",
     "ResolvedFrom" -> "seed"
   |> *)

(* ModelId だけ取り出す *)
res["ModelId"]
(* → "claude-sonnet-4-6" *)
```

`"ResolvedFrom" -> "seed"` は **seed fallback された** ことを示します (まだ compiled registry が存在しないため)。

---

## 例 K-3: 各 provider/intent の解決

```mathematica
ClaudeResolveModel["anthropic", "heavy"]    [["ModelId"]]
(* → "claude-opus-4-7" *)

ClaudeResolveModel["openai", "heavy"]       [["ModelId"]]
(* → "gpt-5" *)

ClaudeResolveModel["lmstudio", "extraction"][["ModelId"]]
(* → "qwen-local" *)

ClaudeResolveModel["claudecode", "code-heavy"][["ModelId"]]
(* → "claude-opus-4-7" *)

(* 存在しない組み合わせ *)
ClaudeResolveModel["unknown", "heavy"]
(* → Missing["NotFound"] *)
```

---

## 例 K-4: SourceVaultLookup — 文字列キーと Association キー

```mathematica
(* 文字列キーで ModelId 検索 *)
SourceVaultLookup["model-registry", "claude-opus-4-7"]
(* → <|... "ModelId" -> "claude-opus-4-7" ...|> *)

(* Association キーで Resolve 同等 *)
SourceVaultLookup["model-registry",
  <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]
(* → ClaudeResolveModel["anthropic", "heavy"] と同じ *)
```

---

## 例 K-5: 独自 registry を compile

任意の topic に登録できます。例えば Mathematica オプション registry:

```mathematica
SourceVaultCompileRegistry["mathematica-graph-options",
  {
    <|"Key" -> "VertexShapeFunction",
      "Type" -> "Function",
      "Default" -> Automatic,
      "Description" -> "Vertex shape rendering"|>,
    <|"Key" -> "EdgeStyle",
      "Type" -> "Style",
      "Default" -> Automatic,
      "Description" -> "Edge visual style"|>
  },
  "Channel" -> "public",
  "PolicySource" -> "mathematica-14-docs"]
(* → <|"Status" -> "OK", "Topic" -> "mathematica-graph-options",
       "Channel" -> "public", "Path" -> "...", "Count" -> 2|> *)

(* lookup できる *)
SourceVaultLookup["mathematica-graph-options", "VertexShapeFunction"]
(* → <|"Key" -> "VertexShapeFunction", "Type" -> "Function", ...,
       "CompiledAt" -> "...", "Sources" -> {}, "PolicySource" -> "..."|> *)
```

各 entry には自動で `CompiledAt` / `Sources` / `PolicySource` が補われます。

---

## 例 K-6: Registry 状態の確認

```mathematica
SourceVaultRegistryStatus["model-registry"]
(* → <|
     "Topic" -> "model-registry",
     "Channel" -> "public",
     "CompiledPath" -> "...\\compiled\\public\\model-registry.json",
     "CompiledExists" -> False,    (* まだ compile していない *)
     "CompiledCount" -> 0,
     "SeedPath" -> "...\\seeds\\model-registry-seed.json",
     "SeedExists" -> True,
     "SeedCount" -> 6,
     "LastModified" -> Missing["NoCompiled"]
   |> *)

SourceVaultRegistryStatus["mathematica-graph-options"]
(* compile 後なら *)
(* → <|"CompiledExists" -> True, "CompiledCount" -> 2, ...|> *)
```

---

## 例 K-7: Compiled が seed より優先される

```mathematica
(* 現状は seed のみ → ResolvedFrom: "seed" *)
ClaudeResolveModel["anthropic", "heavy"]["ResolvedFrom"]
(* → "seed" *)

(* model-registry を compile する (production data として) *)
SourceVaultCompileRegistry["model-registry",
  {
    <|"Kind" -> "Model", "Provider" -> "anthropic", "Intent" -> "heavy",
      "ModelId" -> "claude-opus-4-7-experimental",   (* 別 model に置き換え *)
      "Availability" -> "Available", "Class" -> "Heavy-Cloud",
      "Capabilities" -> {"Reasoning", "Code", "ToolUse", "Vision"},
      "Freshness" -> "Fresh"|>
  },
  "Channel" -> "public"];

(* 今度は compiled が優先される *)
ClaudeResolveModel["anthropic", "heavy"]
(* → <|..., "ModelId" -> "claude-opus-4-7-experimental",
       "ResolvedFrom" -> "compiled"|> *)
```

`"ResolvedFrom"` を見れば、compiled vs seed のどちらから引いたか分かります。

---

## 例 K-8: private channel — user routing override

仕様書 §11 / §14.10 — public registry とは別に private routing を持てます:

```mathematica
SourceVaultCompileRegistry["model-registry",
  {
    <|"Kind" -> "Model", "Provider" -> "anthropic", "Intent" -> "heavy",
      "ModelId" -> "claude-haiku-4-5",        (* 個人的に安いモデルへ強制 *)
      "Availability" -> "Available", "Class" -> "Light-Cloud",
      "Freshness" -> "Fresh"|>
  },
  "Channel" -> "private"];

(* public channel (デフォルト) *)
ClaudeResolveModel["anthropic", "heavy"]["ModelId"]
(* → "claude-opus-4-7-experimental"  (public で compile したもの) *)

(* private channel を明示 *)
SourceVaultResolve["Model",
  <|"Provider" -> "anthropic", "Intent" -> "heavy"|>,
  "Channel" -> "private"]["ModelId"]
(* → "claude-haiku-4-5"  (private override) *)
```

これにより:
- public registry は team / プロジェクト全体で共有
- private registry は user 個人の routing / 開発実験用

を完全分離できます。

---

## 例 K-9: AllowSeed -> False — seed fallback を禁止

```mathematica
(* compiled が存在する topic は OK *)
ClaudeResolveModel["anthropic", "heavy"]    (* → ResolvedFrom: "compiled" *)

(* compiled が無く seed のみの topic で AllowSeed -> False にすると... *)
SourceVaultResolve["Model",
  <|"Provider" -> "openai", "Intent" -> "heavy"|>,
  "AllowSeed" -> False]
(* → Missing["NotFound"] *)
```

production 環境で「seed に頼らせない」厳格モードに使えます。

---

## 例 K-10: Resolve の優先順位

複数 entry が match したときの sort 順 (仕様書 §4.5):

```mathematica
SourceVaultCompileRegistry["model-registry",
  {
    <|"Provider" -> "anthropic", "Intent" -> "heavy",
      "ModelId" -> "claude-deprecated", "Availability" -> "Deprecated",
      "Class" -> "Heavy-Cloud", "Freshness" -> "Stale"|>,
    <|"Provider" -> "anthropic", "Intent" -> "heavy",
      "ModelId" -> "claude-opus-4-7", "Availability" -> "Available",
      "Class" -> "Heavy-Cloud", "Freshness" -> "Fresh"|>
  },
  "Channel" -> "public"];

ClaudeResolveModel["anthropic", "heavy"]["ModelId"]
(* → "claude-opus-4-7" — Available + Fresh が Deprecated + Stale より優先 *)
```

優先順位:
1. `Availability`: Available > Deprecated > Unknown > Other
2. `Freshness`: Fresh > Stale > Expired > Unusable
3. `Class`: Heavy-Cloud > Heavy-Local > Light-Cloud > Light-Local

`Availability == "Unavailable"` は最初の段階で除外されます。

---

## 物理ストレージ (Stage 6b 新規)

```
PrivateVault/
  seeds/
    model-registry-seed.json    # bootstrap 用、自動生成
  compiled/
    public/
      model-registry.json       # production model registry
      mathematica-graph-options.json
      ...
    private/
      model-registry.json       # user routing override
      ...
```

JSON entry の例 (model-registry):

```json
[
  {
    "Kind": "Model",
    "Provider": "anthropic",
    "Intent": "heavy",
    "ModelId": "claude-opus-4-7",
    "Availability": "Available",
    "Class": "Heavy-Cloud",
    "Capabilities": ["Reasoning", "Code", "ToolUse"],
    "Freshness": "Fresh",
    "CompiledAt": "...",
    "Sources": ["claim-..."],
    "PolicySource": "config/policies.wl"
  },
  ...
]
```

---

## Stage 6b の制約と次のステップ

**現状 (Phase 1)**:

- claim → registry の自動 compile はなし (entries を caller が直接渡す)
- channel 間の lint チェックなし (`Confidentiality != Public` の混入検出など、仕様書 §12)
- cloud mirror への materialize なし (仕様書 §11)
- revision / channel semantics の本格対応なし (仕様書 §24.5)

**Phase 2 (将来)**:

- `SourceVaultCompileFromClaims[topic, schema]` — ClaimStore から entries を集約して compile
- channel lint (private 由来の claim が public に混入していないか)
- cloud-safe projection の materialize
- registry の revision history

**コア機能 Phase 1 完成**:

| Stage | 状況 |
|---|---|
| 1〜5 | ✓ |
| 6a Claim dedup + Compact | ✓ |
| **6b Compiled Registry** | ✓ **(本セッション)** |
| 6c Evidence Bundle Phase 1 | ✓ |
| 6d NBAuthorize 2-stage | ✓ |
| 8 vN diff + lifecycle | ✓ |

**SourceVault の Phase 1 全体が完成しました**。残るは Phase 2/3 の深掘り作業のみです。

---


# Part L. Notebook Management (Stage 9 P0)

仕様書 `sourcevault_notebook_management_spec_v1.md` (v1.0 = Stage 9 P0 完成版) に基づき、Mathematica notebook を first-class source として扱う最小実装 (P0 = 優先度最高セット)。

v1.0 で **Status を 3 値 (Open / Done / Pass) に拡張**、Safe parse の実装も `Import[path, "Initialization"]` + `NotebookImport[path, style -> "Cell"]` (Wolfram 標準関数優先原則、ClaudeDirective rule 102) に全面置換しました。

ストーリー (添付 notebook `20260516-第14回オンライン語り交流会.nb` で実演):

> 「先頭セルに `<|"Deadline" -> ..., "NextReview" -> ..., "Status" -> "Todo"|>` がある。TodoItem セルは 3 種類: (1) StrikeThrough + 緑色 = Done、(2) StrikeThrough なし = Open、(3) StrikeThrough + 灰色 = Pass (該当せずスキップ)。Deadline / NextReview は過去で、Open Todo も残っている。これらを deterministic に検出してダッシュボードに出したい。」

---

## Stage 9 Phase 1 (P0) の概要

| 機能 | 用途 |
|---|---|
| `SourceVaultRegisterNotebook[path]` | NotebookSourceRecord 登録 |
| `SourceVaultIndexNotebook[path, opts]` | Header + Todo 抽出 + Snapshot + Index 一括更新 |
| `SourceVaultIndexNotebookFolder[dir, opts]` | folder 配下の .nb を全件 index |
| `SourceVaultExtractNotebookHeader[path]` | Safe parse で先頭 Input セルから Association を取り出す |
| `SourceVaultExtractNotebookTodos[path]` | TodoItem* セル列挙、**Status 3 値判定** (TaggingRules > StrikeThrough + FontColor) |
| `SourceVaultFindNotebooks[opts]` | LLM 不要の deterministic query |
| `SourceVaultNotebookLint[record \| path]` | **9 種 lint** 検出 |

**Safe parse の方針** (仕様書 v1.0 §5 / rule 102):

- **第一選択** (Header): `Import[path, "Initialization"]` で `InitializationCell` の Association を取得し、whitelist (String / Integer / Real / Bool / Missing / DateObject / List of String|Integer / Association 再帰) を通過した値だけ採用。
- **第一選択** (Todo): `NotebookImport[path, "TodoItem_1/2/3" -> "Cell"]` で `System`Cell[...]` を直接取得 (パターンマッチ不要、context 問題なし)。
- **第二フォールバック** (Header): `Import[path, "Notebook"]` で取り出した Cell の `BoxData` を `MakeExpression[box, StandardForm]` で `HoldComplete[expr]` へ変換 (`ToString` + `ToExpression` のラウンドトリップは罠 #22 で破綻するため禁止)。
- 評価される `Import["Initialization"]` でも、返り値の **値レベル** で whitelist 検証することで SourceVault 保存を防御 (実用性優先の妥協)。
- `RunProcess` / `Get` / `Import` / `URLRead` 等の式は値レベルで弾かれ `UnsafeExpression` になる。

**Todo Status 判定の優先順位** (仕様書 v1.0 §3.4 / §5.4):

1. `TaggingRules["TodoStatus"]` または `TaggingRules["SourceVault"]["TodoStatus"]` → `StatusSource: "TaggingRules"` (将来の標準)
2. `FontVariations -> {"StrikeThrough" -> True}` + `FontColor` **緑系** (RGB g > r, b) → **`"Done"`** (`StatusSource: "CellOptionGreen"`)
3. `FontVariations -> {"StrikeThrough" -> True}` + `FontColor` **灰系** (`GrayLevel[_]` / RGB r≈g≈b) → **`"Pass"`** (`StatusSource: "CellOptionGray"`)
4. `FontVariations -> {"StrikeThrough" -> True}` + その他 → `"Done"` (`StatusSource: "CellOption"`、後方互換)
5. それ以外 → `"Open"` (`StatusSource: "Default"`)

各 Todo record の `StatusSource` で判定根拠を追跡可能。`Pass` は「該当せず / 対象外 / スキップ」を `Done` と区別する。

---

## 例 L-1: 機能確認

```mathematica
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-9-notebook-management-p0" *)

Names["SourceVault`SourceVault*Notebook*"]
(* → {"SourceVaultExtractNotebookHeader", "SourceVaultExtractNotebookTodos",
       "SourceVaultFindNotebooks", "SourceVaultIndexNotebook",
       "SourceVaultIndexNotebookFolder", "SourceVaultNotebookLint",
       "SourceVaultRegisterNotebook"} *)
```

---

## 例 L-2: Header 抽出 (添付 notebook)

```mathematica
path = "C:\\path\\to\\20260516-第14回オンライン語り交流会.nb";

header = SourceVaultExtractNotebookHeader[path]
(* → <|
     "ParseStatus" -> "OK",
     "Keywords" -> {"みんなのケア情報学会", "オンライン語り交流会"},
     "NextReview" -> DateObject[{2026, 5, 13}, "Day"],
     "Deadline" -> DateObject[{2026, 5, 13}, "Day"],
     "Status" -> "Todo",
     "RawHeader" -> <|...|>
   |> *)
```

内部では `Import[path, "Initialization"]` で `InitializationCell` の Association を取得し、whitelist で値検証しています。`ParseStatus -> "OK"` は **whitelist 全通過** を意味します。`RunProcess[_]` のような危険式が値に混入していれば `"UnsafeExpression"` になります。

---

## 例 L-3: Todo 抽出 (添付 notebook、3 値判定)

```mathematica
todos = SourceVaultExtractNotebookTodos[path]
(* → {
     <|"Index" -> 1, "CellStyle" -> "TodoItem_1",
       "Text" -> "参加登録",
       "Status" -> "Done",
       "StatusSource" -> "CellOptionGreen",
       "StrikeThrough" -> True|>,
     <|"Index" -> 2, "CellStyle" -> "TodoItem_1",
       "Text" -> "サンプル",
       "Status" -> "Open",
       "StatusSource" -> "Default",
       "StrikeThrough" -> False|>,
     <|"Index" -> 3, "CellStyle" -> "TodoItem_2",
       "Text" -> "サンプル2",
       "Status" -> "Pass",
       "StatusSource" -> "CellOptionGray",
       "StrikeThrough" -> True|>
   } *)
```

3 件すべて `StatusSource` から判定根拠を追跡できます:

| Todo | StrikeThrough | FontColor | → Status | StatusSource |
|---|---|---|---|---|
| 参加登録 | True | 緑系 (RGB g > r, b) | **Done** | `CellOptionGreen` |
| サンプル | False | — | **Open** | `Default` |
| サンプル2 | True | 灰系 (`GrayLevel[0.75]`) | **Pass** | `CellOptionGray` |

将来 notebook 側で `TaggingRules -> <|"SourceVault" -> <|"TodoStatus" -> "Done"|>|>` を採用すれば `StatusSource -> "TaggingRules"` に変わり、`TodoCellStatusHeuristicOnly` lint も消えます (Phase 2 / P1)。

内部実装は `NotebookImport[path, "TodoItem_1" -> "Cell"]` 等を 3 スタイル順に呼び、`System`Cell[...]` を直接受け取って `SymbolName[Head[c]] === "Cell"` で context 非依存に判定します (罠 #23 回避)。

---

## 例 L-4: フル index (Index + Snapshot + Lint)

```mathematica
result = SourceVaultIndexNotebook[path]
(* → <|
     "Status" -> "OK",
     "NotebookRef" -> "nb-src-...",
     "SnapshotId" -> "snap-sha256-...",
     "Path" -> "C:\\...",
     "Header" -> <|"ParseStatus" -> "OK", "Status" -> "Todo", ...|>,
     "TodoCount" -> 3,
     "OpenTodoCount" -> 1,
     "DoneTodoCount" -> 1,
     "PassTodoCount" -> 1,             (* v1.0 で追加 *)
     "ReviewState" -> "Overdue",       (* NextReview 2026-05-13 < today *)
     "DeadlineState" -> "Overdue",     (* Deadline も過去 *)
     "Lint" -> {
       "DeadlinePast",
       "NextReviewPast",
       "TodoCellStatusHeuristicOnly"
     },
     "IndexedAt" -> "2026-05-19T..."
   |> *)
```

**3 つの lint** が一度に検出されています:

| Lint | 意味 |
|---|---|
| `DeadlinePast` | Deadline (2026-05-13) が過去 |
| `NextReviewPast` | NextReview (2026-05-13) が過去 |
| `TodoCellStatusHeuristicOnly` | TaggingRules の明示 status がなく、StrikeThrough + FontColor heuristic だけで Done/Pass 判定された — 将来 style 変更で壊れる可能性 |

**`HeaderStatusTodoButNoOpenTodos` は出ない**: Header `Status` は `Todo` ですが、Todo cell に **Open が 1 件残っている** ため整合が取れています (v1.0 §4.7 — `Done + Pass` の closedCount が 1 以上で openCount = 0 のときだけ発生)。仮にサンプル (Open) が完了して Done になっていたら、この lint も追加で立ちます。

これらは「**review すべき状態**」を示すフラグで、ダッシュボードに出すべき項目です。

---

## 例 L-5: Lint 単独実行

```mathematica
SourceVaultNotebookLint[path]
(* → {"DeadlinePast", "NextReviewPast", "TodoCellStatusHeuristicOnly"} *)
```

`record` を直接渡す形でも呼べます (3 値 Status 対応):

```mathematica
SourceVaultNotebookLint[<|
  "Header" -> <|"Status" -> "Todo", "Deadline" -> DateObject[{2025, 1, 1}]|>,
  "Todos" -> {
    <|"Status" -> "Done", "StatusSource" -> "CellOptionGreen"|>,
    <|"Status" -> "Pass", "StatusSource" -> "CellOptionGray"|>
  }|>]
(* → {"HeaderStatusTodoButNoOpenTodos", "DeadlinePast", "TodoCellStatusHeuristicOnly"} *)
(* Done + Pass で全 Todo が closed、Open は 0 → HeaderStatusTodoButNoOpenTodos が立つ *)
```

検出される 9 種 lint:

```
MissingHeader                       - 先頭セル発見できず
UnsafeHeaderExpression              - whitelist 違反
HeaderDeadlineMalformed             - Deadline が DateObject でない
HeaderNextReviewMalformed           - NextReview が DateObject でない
HeaderStatusTodoButNoOpenTodos      - Header Todo だが Open Todo がない (Done + Pass で全 closed)
HeaderStatusDoneButOpenTodosExist   - Header Done だが Open Todo が残っている
DeadlinePast                        - Deadline 過去
NextReviewPast                      - NextReview 過去
TodoCellStatusHeuristicOnly         - TaggingRules なし、CellOption* だけで判定
```

---

## 例 L-6: FindNotebooks — overdue 検索

```mathematica
SourceVaultFindNotebooks["NextReview" -> "Overdue"]
(* → 添付 notebook が含まれる (NextReview が過去なので) *)
```

このクエリは **LLM を使わず、index ファイルだけで結果を出す**。低遅延・非ネットワーク。

```mathematica
(* 未完了 Todo (Open) が残る notebook *)
SourceVaultFindNotebooks["OpenTodos" -> True]
(* → 添付 notebook は含まれる (サンプル = Open が 1 件残るため) *)

(* 全 Todo が closed (Done + Pass) の notebook *)
SourceVaultFindNotebooks["OpenTodos" -> False]
(* → 添付 notebook は含まれない *)

(* Header Status が "Todo" のまま放置 *)
SourceVaultFindNotebooks["Status" -> "Todo"]
(* → 添付 notebook は含まれる (Header の Status が "Todo") *)

(* Keywords 検索 *)
SourceVaultFindNotebooks["Keywords" -> {"オンライン語り交流会"}]
(* → 添付 notebook が含まれる *)

(* 複合: Deadline 過ぎていて Header Status が Todo のもの *)
SourceVaultFindNotebooks["Deadline" -> "Overdue", "Status" -> "Todo"]
(* → 添付 notebook が含まれる (まさに「締切過ぎ、未完了マーク」) *)
```

`OpenTodos -> True` は **Open Todo (= 実作業残) が 1 件以上ある** notebook を返します。`Pass` は closed として扱われるため含めません。

---

## 例 L-7: 重要なポイント — Header.Status と Todo cell 状態の独立保存

仕様書 v1.0 §1.2 の核心:

> 単に `Status -> "Todo"` だけを見ると「未完了 notebook」と誤判定する。Todo セル状態 (Open / Done / **Pass**)、ヘッダ Status、Deadline / NextReview を独立に保存し、後で合成判定するべきである。

```mathematica
(* 「未完了 Todo がある (Open)」と「Header Status が Todo」を区別 *)
SourceVaultFindNotebooks["OpenTodos" -> True]    (* 実作業残あり (Open Todo > 0) *)
SourceVaultFindNotebooks["Status" -> "Todo"]     (* Header メタデータ未更新 *)

(* 添付 notebook は両方に含まれる:
   - Open Todo "サンプル" が残っている (前者)
   - Header の Status が "Todo" のまま (後者)
   → ダッシュボードでは「実作業残」と「メタデータ不整合」を別カラムに表示すべき *)
```

**`Pass` 状態の意味**: `Done` は「やった」、`Pass` は「該当せず / 該当しないので飛ばす」を表します。たとえば「イベントには参加しなかったが Todo としては closed」のような状態。両者を合計した `closedCount = Done + Pass` を「クローズ済み」として扱い、`OpenTodoCount = 0` かつ `closedCount > 0` で `HeaderStatusTodoButNoOpenTodos` lint が立ちます (v1.0 §4.7)。

---

## 例 L-8: Folder ingest

複数 notebook を一括処理:

```mathematica
result = SourceVaultIndexNotebookFolder["C:\\Users\\imai_\\Documents\\notebooks",
  "Recursive" -> True];

result["Processed"]   (* → 成功した件数 *)
result["Failed"]      (* → 失敗した件数 *)
Length @ Select[result["Results"],
  Length[Lookup[#, "Lint", {}]] > 0 &]   (* lint がある notebook *)

(* Pass を多く持つ notebook の発見 *)
Select[result["Results"],
  Lookup[#, "PassTodoCount", 0] > 0 &]
```

---

## 例 L-9: Safe parse の防御

危険式が入った header は値レベルで弾かれます (whitelist 違反):

```mathematica
(* 仮想例: 先頭 Initialization cell が <|"Status" -> RunProcess["danger.sh"]|> だった場合 *)
SourceVaultExtractNotebookHeader["malicious.nb"]
(* → <|"ParseStatus" -> "UnsafeExpression", "RawHeader" -> <|...|>, ...|> *)
```

許可される型 (whitelist):

- 文字列 / 整数 / 実数 / `True` / `False`
- `Missing[___]`
- `DateObject[{y,m,d}]` または `DateObject[{y,m,d,h,m,s}]`
- 文字列のリスト / 整数のリスト
- Association of 上記 (再帰的に許可)

許可されない型 (例):

- `RunProcess[_]` / `Get[_]` / `Import[_]` / `URLRead[_]`
- 任意の関数呼び出し
- `NotebookWrite[_]` / `SetDirectory[_]`

**重要な注意 (v1.0 §6.2)**: `Import[path, "Initialization"]` は内部で `InitializationCell` を **評価** します。副作用ある式 (`RunProcess` 等) は実行されてしまう可能性があります。SourceVault は返り値を whitelist 検証して保存を防ぐだけで、評価そのものは止められません。完全に評価を回避したい場合は、第二フォールバックの `Import[path, "Notebook"]` + `MakeExpression[box, StandardForm]` 経路 (Phase 2 で第一選択化検討) を使ってください。

---

## 物理ストレージ (Stage 9 新規)

```
<PrivateVault>/notebooks/
  sources/
    nb-src-<hash16>.json              # NotebookSourceRecord (path-based ID)
  snapshots/
    snap-sha256-<hash>.json           # NotebookSnapshotRecord
  todos/
    by-notebook/
      nb-src-<...>.jsonl              # 各 notebook の Todo 一覧 (3 値 Status を保存)
  review/
    overdue.jsonl                     # Overdue review notebook の append-only log
                                      # (PassTodoCount フィールド含む)
  lint/
    notebook-lint.jsonl               # 全 lint event の append-only log
```

JSON 例 (`nb-src-<...>.json`):

```json
{
  "Type": "NotebookSource",
  "NotebookRef": "nb-src-a1b2c3d4e5f6...",
  "OriginalPath": "C:\\...\\20260516-第14回オンライン語り交流会.nb",
  "Title": "20260516-第14回オンライン語り交流会",
  "FileMTime": "...",
  "CurrentSnapshotId": "snap-sha256-...",
  "RegisteredAt": "...",
  "LastIndexedAt": "..."
}
```

JSONL 例 (`todos/by-notebook/nb-src-<...>.jsonl`、3 値 Status を含む):

```jsonl
{"Type":"NotebookTodo","TodoId":"todo-nb-src-...-1","Status":"Done","StatusSource":"CellOptionGreen","Text":"参加登録",...}
{"Type":"NotebookTodo","TodoId":"todo-nb-src-...-2","Status":"Open","StatusSource":"Default","Text":"サンプル",...}
{"Type":"NotebookTodo","TodoId":"todo-nb-src-...-3","Status":"Pass","StatusSource":"CellOptionGray","Text":"サンプル2",...}
```

---

## Stage 9 P0 の制約と次のステップ

**現状 (P0 = Phase 1)**:

- `NotebookSemanticHash` 未実装 (raw content hash のみ)
- `HeaderHash` / `TodoHash` / `CellHashes` 未実装
- Section / cell 単位の差分 summary 更新は未実装
- NBAccess privacy profile による route 分岐は未実装
- `SourceVaultNotebookSummary` (LLM 要約) 未実装
- `SourceVaultMarkTodo` (notebook への commit) 未実装
- `FindNotebooks` は毎回 re-index する (file mtime ベース skip は Phase 2)
- by-month / by-day pivot (`review/by-next-review/YYYY/MM/DD.jsonl`) は未実装、`overdue.jsonl` の単一 append-only log のみ
- `Import["Initialization"]` は値を評価する (副作用は走り得る) — whitelist で値レベル防御のみ

**Stage 9 Phase 2 (P1) ロードマップ** (引継ぎ書類 §9):

1. **`TaggingRules` 標準化** — `TaggingRules["SourceVault"]["TodoStatus"] -> "Open" | "Done" | "Pass"` を style notebook 側で正式採用。`TodoCellStatusHeuristicOnly` lint がデフォルトで消える
2. **`NotebookSemanticHash`** — 表示・cache・CellChangeTimes 除外
3. **`Import[path, "TaggingRules"]`** 経由のメタデータ取得 (Wolfram 標準関数優先原則の継続適用)
4. **Summary artifact の stale 判定** — Stage 8 lifecycle event と統合
5. **`SourceVaultNotebookSummary`** (LLM 要約)
6. **`SourceVaultMarkTodo`** — NBAccess approval 経由で notebook commit
7. **file mtime ベースの index skip** (`ForceReindex -> False` を活用)
8. **`MakeExpression` 第一選択化** — 副作用ある式を完全に排除

**Stage 9 Phase 3 (P2)**:

- ClaudeEval から自然言語 → SourceVault notebook query 変換
  - 「先月作業した notebook のうち、まだ Todo が残っているもの」
  - 「今週レビューする notebook を出して」
- `NotebookReviewDashboard` workflow template (ClaudeOrchestrator)
- Todo 更新 workflow (commit approval は NBAccess 経由)
- Summary refresh workflow (Stage 6c Bundle と統合)
- workflow run / prompt trace を SourceVault artifact として保存

---

## Stage 9 P1 Step 1 — TaggingRules 標準化 (実装着手)

引継ぎ書類 §9 のロードマップで最初に挙げられた **TaggingRules 標準化** の SourceVault.wl 側準備を完了 (`v2026-05-19-stage-9-p1-step1-taggingrules`)。

ファイル経由で notebook 全体および各 TodoItem cell の TaggingRules を deterministic に取得する API を追加しました。これにより、stylesheet 改修 (notebook 側 UI) で TaggingRules を埋め込めるようになれば、Stage 9 P0 の `iTodoStatusFromOptions` の **TaggingRules 経路 (最優先)** がそのまま機能し、`TodoCellStatusHeuristicOnly` lint がデフォルトで消えます。

### 設計方針 (rule 102 準拠)

`Import[path, "TaggingRules"]` という format option は Wolfram の標準サポートに **含まれません**。代わりに次の 2 経路で取得します:

| アクセス対象 | 使用関数 | 取得経路 |
|---|---|---|
| Notebook 全体の TaggingRules | `Import[path, "Notebook"]` | `Notebook[_List, opts___]` の opts から `TaggingRules -> _` を Cases で抽出 |
| Cell の TaggingRules | `NotebookImport[path, style -> "Cell"]` | 各 cell の options から `TaggingRules -> _` を抽出 |

いずれも Stage 9 P0 で確立した正規ルートと同じで、`SymbolName[Head[]]` / `SymbolName[Keys[]]` 比較で context 非依存 (罠 #23 回避)。

### 例 L-10: 機能確認

```mathematica
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-9-p1-step1-taggingrules" *)

Names["SourceVault`SourceVaultExtract*Tagging*"]
(* → {"SourceVaultExtractNotebookTaggingRules"} *)
```

### 例 L-11: 現状の添付 notebook (TaggingRules 未設定)

```mathematica
path = "C:\\path\\to\\20260516-第14回オンライン語り交流会.nb";

result = SourceVaultExtractNotebookTaggingRules[path]
(* → <|
     "Status" -> "OK",
     "Path" -> "C:\\...",
     "NotebookTaggingRules" -> <||>,           (* notebook 全体に TaggingRules なし *)
     "CellTaggingRules" -> {
       <|"Index" -> 1, "CellStyle" -> "TodoItem_1", "TaggingRules" -> <||>|>,
       <|"Index" -> 2, "CellStyle" -> "TodoItem_1", "TaggingRules" -> <||>|>,
       <|"Index" -> 3, "CellStyle" -> "TodoItem_2", "TaggingRules" -> <||>|>
     }
   |> *)
```

現状の添付 notebook では TaggingRules がまだ設定されていないため、すべての cell の TaggingRules が `<||>` です。このため Stage 9 P0 の TodoStatus 判定は StrikeThrough + FontColor heuristic に落ち、`TodoCellStatusHeuristicOnly` lint が立ちます。

### 例 L-12: TaggingRules を持つ notebook (将来の標準形)

P2 stylesheet 改修後、Todo cell が `TaggingRules -> <|"SourceVault" -> <|"TodoStatus" -> "Done"|>|>` を持つ想定:

```mathematica
(* notebook の Todo cell が:
     Cell["参加登録", "TodoItem_1",
       TaggingRules -> <|"SourceVault" -> <|"TodoStatus" -> "Done"|>|>,
       FontVariations -> {"StrikeThrough" -> True},
       FontColor -> RGBColor[0.525, 0.745, 0.196]] *)

result = SourceVaultExtractNotebookTaggingRules["future_notebook.nb"]
(* → <|
     "Status" -> "OK",
     "CellTaggingRules" -> {
       <|"Index" -> 1, "CellStyle" -> "TodoItem_1",
         "TaggingRules" -> <|"SourceVault" -> <|"TodoStatus" -> "Done"|>|>|>,
       ...
     }
   |> *)

(* このとき Stage 9 P0 の Todo 抽出は TaggingRules 経路で判定: *)
SourceVaultExtractNotebookTodos["future_notebook.nb"]
(* → {<|"Status" -> "Done", "StatusSource" -> "TaggingRules", "Text" -> "参加登録", ...|>, ...} *)

(* lint からも TodoCellStatusHeuristicOnly が消える: *)
SourceVaultNotebookLint["future_notebook.nb"]
(* → {"DeadlinePast", "NextReviewPast"}    (* TodoCellStatusHeuristicOnly なし *) *)
```

### Notebook 全体 TaggingRules のケース

stylesheet 側で「すべての Todo を一括管理する」設計を取る場合は、notebook 全体 TaggingRules に書き込む構造も可能:

```mathematica
(* Notebook[{...}, TaggingRules -> <|"SourceVault" -> <|"TodoIndex" -> <|"1" -> "Done", "2" -> "Open"|>|>|>] *)

result = SourceVaultExtractNotebookTaggingRules[path]
(* → <|
     "Status" -> "OK",
     "NotebookTaggingRules" -> <|
       "SourceVault" -> <|
         "TodoIndex" -> <|"1" -> "Done", "2" -> "Open"|>|>|>,
     "CellTaggingRules" -> {...}
   |> *)
```

この経路は **将来の設計選択肢** で、現状の Stage 9 P1 Step 1 では「ファイル経由でこの情報を取得できる」状態を整えるところまで。

### 既存 API への影響

Stage 9 P1 Step 1 は **既存 API の挙動を変更しません**:

- `SourceVaultExtractNotebookHeader[path]` — 不変
- `SourceVaultExtractNotebookTodos[path]` — Stage 9 P0 で既に TaggingRules を優先する仕様 (`iTodoStatusFromOptions`)。Step 1 で TaggingRules が立った cell があれば自動的に `StatusSource -> "TaggingRules"` を返す
- `SourceVaultIndexNotebook[path]` — 不変 (内部で `SourceVaultExtractNotebookTodos` を呼ぶので、TaggingRules が立てば lint が自動で消える)
- `SourceVaultNotebookLint[record]` — 不変 (`TodoCellStatusHeuristicOnly` は TaggingRules が 1 件もない場合のみ立つ)

新 API `SourceVaultExtractNotebookTaggingRules[path]` は **追加** のみで破壊的変更なし。

### 次のステップ — Step 2: NotebookSemanticHash

引継ぎ書類 §9 (2) の **NotebookSemanticHash** に着手します。設計の核心:

- 表示・cache・CellChangeTimes を **除外** したセマンティック内容のハッシュ
- これにより、formatting だけが変わった notebook を `Stale` に誤判定しない
- Stage 8 の page-hashes.json と同様、Bundle 自動 stale 判定に貢献

---

## Stage 9 P1 Step 2 — NotebookSemanticHash (実装完了)

引継ぎ書類 §9 (2) の **NotebookSemanticHash** を実装 (`v2026-05-19-stage-9-p1-step2-semantic-hash`)。表示や cache メタデータを除外した notebook の **意味的内容** だけのハッシュを計算する仕組みを提供します。

### 設計方針 (rule 102 準拠)

**除外リストアプローチ** で notebook 式を正規化してから `Hash[normalized, "SHA256", "HexString"]` を計算。意味的に重要な要素 (FontColor / FontVariations / Background / TaggingRules など Todo Status 判定の根拠) は **保持** し、表示・cache メタデータだけを除外します。

**Cell options の除外リスト** (`$iNotebookSemanticHashCellExcludeKeys`):

```
ExpressionUUID         - 評価ごとに変わる、意味なし
CellChangeTimes        - 編集タイムスタンプ
CellLabel              - "In[N]:=" / "Out[N]=" は評価で変わる
CellID                 - 双方向 link 用 ID
CellTags
FontFamily             - 表示設定
FontSize               - 表示設定
PageWidth              - 印刷設定
PageBreakBelow         - 印刷設定
PageBreakAbove
ShowCellTags
ShowCellLabel
ShowGroupOpener
```

**Notebook 全体 options の除外リスト** (`$iNotebookSemanticHashNotebookExcludeKeys`):

```
ExpressionUUID
FrontEndVersion        - Mathematica バージョンで変わる
WindowSize / WindowMargins / WindowFrame / WindowTitle
Saveable
DockedCells
StyleDefinitions
TaggingRules           - notebook 全体の TaggingRules は除外
                         (現状 cell 単位の TaggingRules は保持)
```

**意味的に保持される要素**:

| 要素 | 理由 |
|---|---|
| `Cell` の content (BoxData / TextData) | notebook の中身そのもの |
| `Cell` の style ("Input"/"Output"/"TodoItem_1"/...) | cell 種別 |
| `FontColor` | Todo Status (緑 = Done、灰 = Pass) の根拠 |
| `FontVariations` (`{"StrikeThrough" -> True}`) | Todo Status の根拠 |
| `Background` | 視覚的意味あり |
| Cell options の `TaggingRules` | Stage 9 P1 Step 1 で重要 |
| `CellGroupData` 構造 | ネスト構造 |

### 計算経路

```
Import[path, "Notebook"]              (Wolfram 標準、rule 102)
        ↓
iNormalizeNotebookForHash             (除外キーを取り除く)
        ↓
Hash[..., "SHA256", "HexString"]      (Wolfram 標準)
        ↓
"semhash-sha256-<64 char hex>"        (semhash- プレフィックス付き)
```

### 例 L-13: 機能確認 + 基本動作

```mathematica
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-9-p1-step2-semantic-hash" *)

path = "C:\\path\\to\\20260516-第14回オンライン語り交流会.nb";

result = SourceVaultNotebookSemanticHash[path]
(* → <|
     "Status" -> "OK",
     "Path" -> "C:\\...",
     "SemanticHash" -> "semhash-sha256-a1b2c3d4e5f6..."  (64 char hex)
   |> *)

result["SemanticHash"]
(* → "semhash-sha256-..." *)
```

### 例 L-14: SourceVaultIndexNotebook との統合

`SourceVaultIndexNotebook[path]` 内部で SemanticHash も自動的に計算され、`snapshots/snap-sha256-<...>.json` に保存されます:

```mathematica
SourceVaultIndexNotebook[path]
(* → <|
     "Status" -> "OK",
     "NotebookRef" -> "nb-src-...",
     "SnapshotId" -> "snap-sha256-...",
     ...
   |> *)

(* snapshot record を直接読み出すと SemanticHash フィールドが追加されている *)
snapshotPath = FileNameJoin[{
  SourceVault`$SourceVaultRoots["PrivateVault"], "notebooks", "snapshots",
  "snap-sha256-<...>.json"}];
Import[snapshotPath, "RawJSON"]
(* → <|
     "Type" -> "NotebookSnapshot",
     "SnapshotId" -> "snap-sha256-...",
     "NotebookRef" -> "nb-src-...",
     "RawContentHash" -> "sha256-...",      (* 既存 *)
     "SemanticHash" -> "semhash-sha256-...", (* P1 Step 2 で追加 *)
     "CellCount" -> _Integer,
     "LifecycleStatus" -> "Current",
     "CreatedAt" -> "..."
   |> *)
```

### 例 L-15: SemanticHash の安定性 (formatting 変更で不変)

`CellChangeTimes` や `ExpressionUUID` だけが変わった場合、`RawContentHash` は変わりますが `SemanticHash` は不変です:

```mathematica
(* シナリオ: notebook を開いて評価せず保存し直す *)
(* → CellChangeTimes 更新、ExpressionUUID 再発行、CellLabel 更新 *)
(* → RawContentHash: 変わる (テキスト内容が違う) *)
(* → SemanticHash: 不変 (意味的内容は同じ) *)

(* シナリオ: notebook 内の FontSize を 12 → 14 に変更 *)
(* → RawContentHash: 変わる *)
(* → SemanticHash: 不変 (FontSize は除外リスト) *)

(* シナリオ: Todo cell の StrikeThrough を解除 (Done → Open) *)
(* → RawContentHash: 変わる *)
(* → SemanticHash: 変わる (FontVariations は意味的要素として保持) *)
(* → Stage 8 の lifecycle で正しく Stale 化 *)
```

これにより、formatting のみの編集で snapshot を Stale 化することなく、Todo Status の変更のような **意味のある編集** だけを Stage 8 lifecycle event で検出できます。

### Stage 8 連携 (Phase 2 で本格化)

現状は SemanticHash を snapshot record に保存するだけ。Stage 8 の `SourceVaultDiffVersions` / `SourceVaultMarkSnapshotStale` 等で SemanticHash を比較基準として使う改修は **Stage 9 P1 Step 4 (Summary artifact の stale 判定)** で取り組みます。

### 既存 API への影響

Stage 9 P1 Step 2 は **既存 API の挙動を変更しません**:

- `SourceVaultRegisterNotebook[path]` — 不変
- `SourceVaultExtractNotebookHeader[path]` / `Todos[path]` / `TaggingRules[path]` — 不変
- `SourceVaultIndexNotebook[path]` — **snapshot record にフィールド追加** (`SemanticHash` が増えるだけ、戻り値構造は同一)
- `SourceVaultFindNotebooks[opts]` — 不変
- `SourceVaultNotebookLint[record]` — 不変

新 API `SourceVaultNotebookSemanticHash[path]` は **追加** のみで破壊的変更なし。

### 次のステップ — Step 3 は Step 1 に統合済み

引継ぎ書類 §9 (3) の `Import[path, "TaggingRules"]` 経由のメタデータ取得は、`Import[path, "TaggingRules"]` という format option が Wolfram に存在しないことから、**Step 1 (TaggingRules 標準化) に統合**して実装完了済み。

引き続き **Step 4 (Summary artifact の stale 判定 → Stage 8 統合)** に進みます。

---

## Stage 9 P1 Step 4 — Summary artifact stale 判定 (実装完了)

引継ぎ書類 §9 (4) の **Summary artifact stale 判定** を実装 (`v2026-05-19-stage-9-p1-step4-summary-stale`)。Summary artifact を notebook の **特定 snapshot** に紐づけ、**意味的変化** と **formatting のみの変化** を区別して stale 判定する枠組みを提供します。

### 設計方針

Stage 9 P1 Step 5 (LLM 要約) はまだ未実装ですが、Step 4 では **「枠組みだけ」** を整備します:

- Summary 文字列を **外部から受け取って** 保存する API (`SourceVaultRegisterNotebookSummary`)
- 取り出し API (`SourceVaultGetNotebookSummary`)
- stale 判定 API (`SourceVaultNotebookSummaryStatus`)
- 物理ストレージ `<PrivateVault>/notebooks/summaries/sum-<nbRef>.json`

Step 5 が来たときに `SourceVaultNotebookSummary[path]` (LLM 要約) は `RegisterNotebookSummary` を内部で呼ぶだけで lifecycle 管理に乗ります。

### Stale 判定ロジック (4 状態)

```
summary record 不在                                  → Missing
summary.BasedOnSnapshot == 現在の SnapshotId           → Current
summary.BasedOnSemanticHash == 現在の SemanticHash    → StaleFormattingOnly
それ以外                                            → Stale
```

`StaleFormattingOnly` の判定が **Step 2 (SemanticHash) の意義** を最大化します:

| 編集内容 | RawContentHash | SemanticHash | 旧 lifecycle (snapshot 一致のみ) | 新 lifecycle (Step 4) |
|---|---|---|---|---|
| 評価し直し (`In[N]:=` ラベル更新) | 変わる | 不変 | Stale (要再生成) | **StaleFormattingOnly** (再利用可) |
| FontSize 変更 | 変わる | 不変 | Stale | **StaleFormattingOnly** |
| Todo cell の StrikeThrough 解除 | 変わる | 変わる | Stale | **Stale** (要再生成) |
| Todo cell 追加 | 変わる | 変わる | Stale | **Stale** |
| 何も変更なし | 不変 | 不変 | Current | **Current** |

### 物理ストレージ

```
<PrivateVault>/notebooks/summaries/
  sum-nb-src-<hash16>.json    # 各 notebook の Summary record
```

JSON 例:

```json
{
  "Type": "NotebookSummary",
  "SummaryId": "sum-nb-src-5d9fd9f24923df19",
  "NotebookRef": "nb-src-5d9fd9f24923df19",
  "BasedOnSnapshot": "snap-sha256-0dde5ea27d07791726dc7976e0ede196452c1f8b14da36fe2128821f46d0de9f",
  "BasedOnSemanticHash": "semhash-sha256-7aadbb3d531220f92fcf98708f4b803b39d328eb67d830679240749306029ddf",
  "Summary": "第14回オンライン語り交流会の準備notebook。参加登録は完了済み。Deadline (2026-05-13) は過去。",
  "SummaryFormat": "text",
  "GeneratedBy": "manual",
  "CreatedAt": "2026-05-19T18:36:55"
}
```

### 例 L-16: 機能確認

```mathematica
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-9-p1-step4-summary-stale" *)

Names["SourceVault`SourceVault*NotebookSummary*"]
(* → {"SourceVaultGetNotebookSummary", "SourceVaultNotebookSummaryStatus"} *)

Names["SourceVault`SourceVaultRegisterNotebookSummary"]
(* → {"SourceVaultRegisterNotebookSummary"} *)
```

### 例 L-17: Summary 未登録の状態 (Missing)

```mathematica
path = "C:\\path\\to\\20260516-第14回オンライン語り交流会.nb";

(* 1. まず IndexNotebook を実行 (snapshot 必須) *)
SourceVaultIndexNotebook[path];

(* 2. Summary を取得しようとすると Missing *)
SourceVaultGetNotebookSummary[path]
(* → <|"Status" -> "Missing",
       "Reason" -> "SummaryNotFound",
       "NotebookRef" -> "nb-src-5d9fd9f24923df19"|> *)

(* 3. Stale 判定も Missing *)
SourceVaultNotebookSummaryStatus[path]
(* → <|"Status" -> "Missing",
       "Reason" -> "SummaryNotFound",
       "CurrentSnapshot" -> "snap-sha256-0dde5ea2...",
       "SummaryBasedOnSnapshot" -> Missing["NotApplicable"]|> *)
```

### 例 L-18: Summary 登録 + 直後の取得 (Current)

```mathematica
(* 1. 手動で summary を登録 (Step 5 LLM 要約が来るまでの暫定経路) *)
result = SourceVaultRegisterNotebookSummary[path,
  "第14回オンライン語り交流会の準備notebook。参加登録は完了済み。Deadline (2026-05-13) は過去。",
  "SummaryFormat" -> "text",
  "GeneratedBy" -> "manual"]
(* → <|"Status" -> "OK",
       "SummaryId" -> "sum-nb-src-...",
       "NotebookRef" -> "nb-src-...",
       "BasedOnSnapshot" -> "snap-sha256-...",
       "BasedOnSemanticHash" -> "semhash-sha256-7aadbb3d...",
       "Path" -> "<PrivateVault>/notebooks/summaries/sum-nb-src-....json",
       "CreatedAt" -> "2026-05-19T..."|> *)

(* 2. 登録直後は Current *)
SourceVaultNotebookSummaryStatus[path]
(* → <|"Status" -> "Current",
       "Reason" -> "SameSnapshot",
       "CurrentSnapshot" -> "snap-sha256-...",
       "SummaryBasedOnSnapshot" -> "snap-sha256-..."|> *)

(* 3. Get で内容確認 *)
SourceVaultGetNotebookSummary[path]
(* → <|"Status" -> "OK",
       "SummaryId" -> "sum-nb-src-...",
       "NotebookRef" -> "nb-src-...",
       "Summary" -> "第14回オンライン語り交流会の準備notebook。...",
       "SummaryFormat" -> "text",
       "BasedOnSnapshot" -> "snap-sha256-...",
       "BasedOnSemanticHash" -> "semhash-sha256-...",
       "GeneratedBy" -> "manual",
       "CreatedAt" -> "2026-05-19T..."|> *)
```

### 例 L-19: notebook を再評価 → StaleFormattingOnly

```mathematica
(* notebook を開いて全 cell を評価し直し (In[N]:= ラベル更新)、保存 *)
(* → CellChangeTimes / CellLabel / ExpressionUUID が更新される *)
(* → RawContentHash は変わるが SemanticHash は不変 *)

(* 再 index *)
SourceVaultIndexNotebook[path];

(* Summary は古い snapshot に紐づいたまま *)
SourceVaultNotebookSummaryStatus[path]
(* → <|"Status" -> "StaleFormattingOnly",
       "Reason" -> "SnapshotChangedButSemanticHashIdentical",
       "CurrentSnapshot" -> "snap-sha256-XXX(新)",
       "SummaryBasedOnSnapshot" -> "snap-sha256-XXX(古)"|> *)
```

この状態の意味: 「snapshot は変わったが意味的内容は同じなので、**Summary は再利用してよい**」。Stage 8 lifecycle event で `StaleFormattingOnly` は **警告レベル**、`Stale` は **再生成必須** として区別できます。

### 例 L-20: Todo cell を解除 → Stale

```mathematica
(* notebook で「参加登録」cell の StrikeThrough を解除 (Done → Open) *)
(* → SemanticHash が変わる *)

SourceVaultIndexNotebook[path];

SourceVaultNotebookSummaryStatus[path]
(* → <|"Status" -> "Stale",
       "Reason" -> "SemanticHashChanged",
       "CurrentSnapshot" -> "snap-sha256-NNN(新)",
       "SummaryBasedOnSnapshot" -> "snap-sha256-OOO(古)"|> *)

(* → Summary は「参加登録は完了済み」と書いてあるので意味的に古い、再生成必須 *)
```

### 既存 API への影響

Stage 9 P1 Step 4 は **既存 API の挙動を変更しません**:

- 既存の 7 個 API (RegisterNotebook / IndexNotebook / IndexNotebookFolder / ExtractNotebookHeader / ExtractNotebookTodos / FindNotebooks / NotebookLint) — すべて不変
- P1 Step 1/2 API — 不変
- 物理ストレージ — `notebooks/summaries/` ディレクトリが新設されるだけで既存ファイルに影響なし

新 API 3 個 (Register / Get / Status) は **追加** のみで破壊的変更なし。

### Step 5 への布石

Step 5 (LLM 要約 `SourceVaultNotebookSummary[path]`) が来たときの最小実装は:

```mathematica
SourceVaultNotebookSummary[path_String, opts:OptionsPattern[]] :=
  Module[{summaryText},
    (* LLM 呼び出しで notebook 内容を要約 *)
    summaryText = iCallSummaryLLM[path, opts];
    (* Step 4 の API でファイルに保存 + lifecycle 管理に乗せる *)
    SourceVaultRegisterNotebookSummary[path, summaryText,
      "GeneratedBy" -> "claude-" <> ToString[...]]
  ];
```

Step 4 の枠組みがあるので、Step 5 は LLM 呼び出しと prompt 設計に集中できます。

### Stage 8 lifecycle との関係 (将来の本格統合)

現状の Step 4 は **Summary 単独** の stale 判定だけ。本格的な Stage 8 lifecycle 統合は次のような拡張で実現可能 (Phase 3 候補):

- `Stage 8 SourceVaultDiffVersions[old, new]` の比較基準に `SemanticHash` を採用 (本セッションで saved 済み)
- snapshot lifecycle (`Current` → `Stale`) の自動遷移を SemanticHash 比較で判定
- summary record を Bundle の dependency graph に組み込む

これらは Stage 8 のリファクタを伴うため、Stage 9 P1 のスコープ外。Step 4 で基盤データ (SemanticHash の保存、Summary の snapshot 紐付け) を整えたところまでで本セッションは完了です。

---

## Stage 9 P1 Step 4 utf8fix — UTF-8 二重 encode バグ一括修正

result12.nb (Step 4 の手元テスト) で **Summary の日本語文字列が文字化け** することが判明 (`第14回オンライン...` → `Ç¬¬14...`)。原因は SourceVault.wl 全体に Stage 9 P0 時代から潜伏していた **UTF-8 二重 encode バグ** で、12 箇所すべて一括修正 (`v2026-05-19-stage-9-p1-step4-summary-stale-utf8fix`)。

### 文字化けの仕組み

```mathematica
(* 旧コード (12 箇所すべて同じパターン) *)
strm = OpenWrite[path, BinaryFormat -> True, CharacterEncoding -> "UTF-8"];
json = ExportString[record, "RawJSON"];        (* json は既に UTF-8 byte sequence String *)
BinaryWrite[strm,
  ExportString[json, "Text", CharacterEncoding -> "UTF-8"]];   (* もう一度 UTF-8 encode! *)
Close[strm];
```

`ExportString[..., "RawJSON"]` の戻り値は既に UTF-8 で encode 済みのバイト列を保持する String です。それを `ExportString[..., "Text", CharacterEncoding -> "UTF-8"]` に渡すと、Wolfram は「String の各文字を UTF-8 byte に encode」を **もう一度実行** します。結果は二重 encode された byte 列で、`Import["RawJSON"]` で 1 回 decode しても元には戻りません。

`第` (U+7B2C) の場合:
1. 元の文字: U+7B2C
2. 1 回目 UTF-8 encode: `0xE7 0xAC 0xAC` (これが json String に入る)
3. 2 回目 UTF-8 encode: 各 byte を Latin-1 文字と解釈 → `Ç ¬ ¬` (U+00E7 U+00AC U+00AC)、それぞれを UTF-8 encode → `0xC3 0xA7 0xC2 0xAC 0xC2 0xAC`
4. ファイルに記録される byte 列: `0xC3 0xA7 0xC2 0xAC 0xC2 0xAC`
5. `Import["RawJSON"]` が UTF-8 として 1 回 decode: `Ç ¬ ¬`

### 修正パターン

```mathematica
(* 新コード (12 箇所すべて同じパターンに統一) *)
strm = OpenWrite[path, BinaryFormat -> True, CharacterEncoding -> "UTF-8"];
json = ExportString[record, "RawJSON"];
BinaryWrite[strm, StringToByteArray[json, "UTF-8"]];           (* 1 回だけ UTF-8 encode *)
Close[strm];
```

`StringToByteArray[X, "UTF-8"]` は **String を 1 回だけ UTF-8 byte 列に変換** する Wolfram 標準関数 (rule 102)。`BinaryWrite` には byte sequence を直接渡せます。

### 修正された 12 箇所

| カテゴリ | 関数 | 内容 |
|---|---|---|
| 既存 | `iClaimsAppendJSONL` | Claims JSONL append |
| 既存 | `iBundleSave` | Bundle JSON save (Stage 6c) |
| 既存 | `iAppendSourceEvent` | Source event log append |
| 既存 | `iSaveRegistryEntries` | Registry entries JSON save |
| 既存 (内部) | `iLogFile` 系 append | Log line append |
| Stage 9 P0 | `SourceVaultRegisterNotebook` | NotebookSource JSON save |
| Stage 9 P0 | `SourceVaultIndexNotebook` (Source) | NotebookSource 再保存 |
| Stage 9 P0 | `SourceVaultIndexNotebook` (Snapshot) | NotebookSnapshot JSON save |
| Stage 9 P0 | `SourceVaultIndexNotebook` (Todo) | Todo JSONL append (3 値 Status を含む) |
| Stage 9 P0 | `SourceVaultIndexNotebook` (Lint) | Lint event JSONL append |
| Stage 9 P0 | `SourceVaultIndexNotebook` (Review) | Review overdue JSONL append |
| Stage 9 P1 Step 4 | `iSaveNotebookSummaryRecord` | Summary JSON save (本来の対象) |

### 影響範囲

**新規バグ混入の可能性は低い**:
- 修正は文字列パターン置換のみで、ロジック変更なし
- 旧コードでも ASCII のみのデータ (英数字/UUID/hash 文字列) は問題なく読めていた (二重 encode しても ASCII byte は不変)
- 日本語 / 中国語 / 韓国語 / 絵文字を含むデータでのみ顕在化
- Snapshot Id (`snap-sha256-...`) や NotebookRef (`nb-src-...`) などの ID 系フィールドは ASCII のみなので、これまでも正常動作していた

**今回の修正で正しく保存・読み込みできるようになる新規データ**:
- Summary の日本語本文 (今回の発端)
- Todo Text の日本語 (例: 「参加登録」「サンプル」「サンプル2」)
- Notebook タイトルの日本語 (`FileBaseName[abs]`)
- Header Keywords の日本語 (`{"みんなのケア情報学会", ...}`)
- Lint event の理由文字列で日本語を含む場合

これらは **これまで全て二重 encode された状態で書き込まれていた**ので、既存の JSON ファイルの内容は文字化け状態のままです。新規 index やすでに index 済み notebook の再 index で正しく上書きされます。

### 例 L-21: 修正検証 (Step 4 のテスト再実行)

```mathematica
(* バージョン更新確認 *)
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-9-p1-step4-summary-stale-utf8fix" *)

(* Summary 再登録 (上書き) *)
SourceVaultRegisterNotebookSummary[path,
  "第14回オンライン語り交流会の準備notebook。参加登録は完了済み。Deadline (2026-05-13) は過去。"]
(* → Status: "OK", ... *)

(* 取り出して内容確認 *)
SourceVaultGetNotebookSummary[path]["Summary"]
(* → "第14回オンライン語り交流会の準備notebook。参加登録は完了済み。Deadline (2026-05-13) は過去。"
     (旧版では Ç¬¬14... に化けていた) *)
```

### 副次効果 — Snapshot record の日本語フィールドも正常化

`SourceVaultIndexNotebook[path]` を再実行することで、`notebooks/sources/nb-src-<...>.json` や `notebooks/snapshots/snap-sha256-<...>.json` 内の `"Title"` フィールド (notebook ファイル名のベース部分) も正しく書き込まれるようになります:

```json
{
  "Type": "NotebookSource",
  ...
  "Title": "20260516-第14回オンライン語り交流会",   (旧: 文字化け; 新: 正常)
  ...
}
```

---

## Stage 9 P1 Step 4 utf8fix v2 — 読み出し側 (Import RawJSON) 修正

result13.nb のテストで **書き出し側だけの修正では文字化けが解消しなかった**ことが判明。原因は **読み出し側 `Import[path, "RawJSON"]`** にあった (`v2026-05-19-stage-9-p1-step4-summary-stale-utf8fix-v2`)。

### 文字化け継続の原因 (読み出し側)

Windows 環境では、`Import[path, "RawJSON"]` がデフォルトで OS のシステムエンコーディング (CP932 / Shift_JIS) としてファイルを読む場合があります。私が utf8fix で書き出し側を `BinaryWrite[strm, StringToByteArray[X, "UTF-8"]]` に直したことで、**ファイル自体は正しい UTF-8 で保存**されるようになりました。しかし `Import["RawJSON"]` が UTF-8 ファイルを CP932 として decode しようとすると、3 byte の UTF-8 文字 (例: `E7 AC AC` = `第`) が CP932 の 1 byte 文字 + 2 byte 文字として誤解釈され、`Ç¬¬` のような化けが発生します。

`SourceVaultFindNotebooks` (L5973) では既に **Imai 先生が UTF-8 問題を回避済み** で、`ReadByteArray + ByteArrayToString[..., "UTF-8"] + ImportString[..., "RawJSON"]` という Windows 環境耐性のあるパターンを使っていました。同じパターンを **新 helper として整理**し、`Import[path, "RawJSON"]` の他 5 箇所すべてに展開しました。

### 修正パターン

```mathematica
(* 新 helper: rule 102 準拠の Wolfram 標準関数のみで実装 *)
iLoadJSONFromFile[path_String] :=
  Module[{rawBytes, str, data},
    If[!FileExistsQ[path], Return[Null]];
    rawBytes = Quiet @ ReadByteArray[path];               (* OS encoding 非依存 *)
    If[!ByteArrayQ[rawBytes], Return[Null]];
    str = Quiet @ ByteArrayToString[rawBytes, "UTF-8"];   (* 明示的 UTF-8 decode *)
    If[!StringQ[str], Return[Null]];
    data = Quiet @ Developer`ReadRawJSONString[str];      (* String を JSON parse *)
    If[AssociationQ[data] || ListQ[data], data, Null]
  ];
```

`Import[path, "RawJSON"]` の 5 箇所を置換:

| 関数 | 役割 |
|---|---|
| `iLoadJSON` (汎用 JSON load) | `iLoadJSONFromFile` 経由に切替 |
| `iLoadNotebookSummaryRecord` | Step 4 で追加した Summary 読み出し |
| `SourceVaultRegisterNotebookSummary` (srcRec) | NotebookSource record 読み出し |
| `SourceVaultRegisterNotebookSummary` (snapshotRec) | Snapshot record 読み出し |
| `SourceVaultNotebookSummaryStatus` (srcRec) | NotebookSource record 読み出し |
| `SourceVaultNotebookSummaryStatus` (snapshotRec) | Snapshot record 読み出し |

合計 6 箇所 (1 つは `iLoadJSON` 経由なので外側 5 関数で計上)。

### 例 L-22: 修正検証 (Step 4 のテスト再実行 v2)

```mathematica
(* バージョン更新確認 *)
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-9-p1-step4-summary-stale-utf8fix-v2" *)

(* Summary を再登録 (utf8fix で正しく UTF-8 書き出し済みのファイルを、新読み出しで読み直す) *)
SourceVaultRegisterNotebookSummary[path,
  "第14回オンライン語り交流会の準備notebook。参加登録は完了済み。Deadline (2026-05-13) は過去。"]

(* 取り出して日本語が正しいか確認 *)
SourceVaultGetNotebookSummary[path]["Summary"]
(* → "第14回オンライン語り交流会の準備notebook。参加登録は完了済み。Deadline (2026-05-13) は過去。"
     (utf8fix では Ç¬¬14... に化けていた) *)
```

### なぜ書き出し側 utf8fix だけでは不十分だったか — 詳細分析

utf8fix 前 (Stage 9 P0 オリジナル):
- 書き出し: 二重 UTF-8 encode → ファイルに二重 encode された byte 列が保存
- 読み出し: `Import[path, "RawJSON"]` がデフォルトエンコーディングで読む
- 結果: 二重 encode された byte 列を CP932 として 1 回 decode → さらに JSON parse → 中途半端な化け表示

utf8fix (書き出し側のみ修正):
- 書き出し: **正しい UTF-8 1 回 encode** → ファイルに正常な UTF-8 byte 列が保存
- 読み出し: `Import[path, "RawJSON"]` がデフォルトエンコーディング (CP932) で読む
- 結果: 正しい UTF-8 byte 列を CP932 として decode → `第` (3 byte) が `Ç¬¬` (3 文字) に化ける → JSON parse はできるが化けが残る

utf8fix-v2 (書き出し + 読み出しの両方修正):
- 書き出し: 正しい UTF-8 1 回 encode → ファイルに正常な UTF-8 byte 列
- 読み出し: `ReadByteArray + ByteArrayToString[..., "UTF-8"]` で **明示的に UTF-8 として decode**
- 結果: 正常な日本語

### Windows 環境での挙動の根本原因

Wolfram Language の `Import[path, "RawJSON"]` は、内部で `Import[path, "JSON"]` と類似の経路を取りますが、 Windows 環境では:

1. ファイルの BOM (Byte Order Mark) を確認 → なし
2. システムロケール (Windows: CP932 in Japanese region) で decode を試みる
3. UTF-8 として decode を試みる

の順序で挙動が変わることがあります。BOM 無しの UTF-8 ファイルだと (2) が優先されて誤判定する可能性が高い。これは Wolfram ドキュメントには明記されていない実装依存の挙動です。

`ReadByteArray` は OS の生 byte 列を取得し、`ByteArrayToString[bytes, "UTF-8"]` で明示的に UTF-8 として解釈するため、この判定の影響を受けません (rule 102 準拠の堅牢な経路)。

### Stage 9 P0 由来の既存ファイル (二重 encode 版) の取り扱い

result11.nb 時点までに生成された JSON ファイルは **書き出し側で二重 encode された状態**。それを utf8fix-v2 の **読み出し側 (UTF-8 decode 前提)** で読むと、二重 encode の 1 段目分を「正しい UTF-8」として decode するため、依然として化けが残ります。

これらは:

```mathematica
(* notebooks/ 配下を完全クリアして index やり直し *)
DeleteDirectory[FileNameJoin[{
  SourceVault`$SourceVaultRoots["PrivateVault"], "notebooks"}],
  DeleteContents -> True];
SourceVaultIndexNotebook[path];   (* 正しい UTF-8 で書き出し *)
SourceVaultRegisterNotebookSummary[path, "..."];   (* 正しい UTF-8 で書き出し *)
```

または個別の notebook について:

```mathematica
SourceVaultIndexNotebook[path];   (* sources/, snapshots/, todos/ が上書きされる *)
SourceVaultRegisterNotebookSummary[path, "..."];   (* summaries/ が上書きされる *)
```

### ロード時メッセージ更新

ロード時メッセージに新セクションを追加:

```
Stage 9 P1 Step 4 utf8fix v2 (読み出し側修正):
  iLoadJSONFromFile[path] (新規 helper, Private) を追加
  Import[path, "RawJSON"] の 5 箇所を ReadByteArray + ByteArrayToString[UTF-8] + Developer`ReadRawJSONString へ置換
```

### 教訓 — Wolfram 標準関数優先原則 (rule 102) の確実な適用

Stage 9 P1 Step 4 で 2 回 utf8fix を出してしまった反省点:

1. **書き出しと読み出しは対称**: 書き出し側を `StringToByteArray + BinaryWrite` で修正したなら、読み出し側も `ReadByteArray + ByteArrayToString` の対称構造に揃えるべきだった
2. **既存コードに参考実装がある場合は最優先**: `SourceVaultFindNotebooks` (L5973) で Imai 先生が既に確立していた UTF-8 安全パターンに最初から気づくべきだった
3. **Imai 先生のメモリにヒントがあった**: 「MathWebServer.wl: URLRead["BodyByteArray"] + ByteArrayToString["UTF-8"] + Developer`ReadRawJSONString」というメモが既に存在し、File I/O にも同じ原理が適用できることを最初に確認すべきだった

Wolfram 標準関数優先原則 (rule 102) は、関数を「使う」だけでなく、**Wolfram の I/O 経路の挙動が OS 依存になり得る点を明示的に回避するためにこそ標準関数を組み合わせる**という意義を、本事例で再確認しました。

---

## Stage 9 P1 Step 4 utf8fix v3 — 2 箇所の追加修正

result14.nb で utf8fix v2 後も文字化けが解消しなかった原因として、**2 箇所の独立した問題**を特定して修正 (`v2026-05-19-stage-9-p1-step4-summary-stale-utf8fix-v3`)。

### 問題 (1): `BinaryFormat -> True + CharacterEncoding -> "UTF-8"` の同時指定

12 箇所の `OpenWrite/OpenAppend` で次のパターンが使われていました:

```mathematica
strm = OpenWrite[path, BinaryFormat -> True, CharacterEncoding -> "UTF-8"];
```

Wolfram のドキュメントでは、`BinaryFormat -> True` は **バイナリストリーム** (byte 単位の I/O) を作る指定で、`CharacterEncoding` はそのストリームでは無意味なはずです。しかし両者を同時に指定したときの挙動は明文化されておらず、`BinaryWrite[strm, byteArray]` の動作が実装依存になっている可能性があります。

仮説: バイナリモードと UTF-8 テキストモードがどちらも有効として扱われ、`BinaryWrite[strm, byteArray]` が ByteArray の各 byte を「すでに UTF-8 encode 済み」と解釈し、その byte 列を **さらに Latin-1 → UTF-8 として再 encode** している。これは `第` (UTF-8: `E7 AC AC`) が `Ç¬¬` (Latin-1 decode: `0xE7 0xAC 0xAC` → U+00E7 U+00AC U+00AC) に化ける挙動と完全に一致します。

修正: **`CharacterEncoding -> "UTF-8"` を削除**して `BinaryFormat -> True` のみにする。

```mathematica
(* 修正後 *)
strm = OpenWrite[path, BinaryFormat -> True];
BinaryWrite[strm, StringToByteArray[json, "UTF-8"]];   (* 確実に 1 回だけ encode *)
```

12 箇所すべてに適用。

### 問題 (2): `Developer\`ReadRawJSONString` (utf8fix-v2 の不確定 API)

utf8fix-v2 で読み出し helper を作る際、Imai 先生のメモリにあった `MathWebServer.wl` のパターン (`Developer\`ReadRawJSONString`) を流用しましたが、これは **未 documented な内部関数**でした。

L5973 (`SourceVaultFindNotebooks`) で Imai 先生が既に確立していた **動作確認済み** のパターンは:

```mathematica
ImportString[content, "RawJSON"]    (* documented API *)
```

修正: `iLoadJSONFromFile` の最終行を `Developer\`ReadRawJSONString[str]` から `ImportString[str, "RawJSON"]` に変更。L5973 と完全に同じパターンに揃える。

```mathematica
(* utf8fix v3 修正後 *)
iLoadJSONFromFile[path_String] :=
  Module[{rawBytes, str, data},
    If[!FileExistsQ[path], Return[Null]];
    rawBytes = Quiet @ ReadByteArray[path];
    If[!ByteArrayQ[rawBytes], Return[Null]];
    str = Quiet @ ByteArrayToString[rawBytes, "UTF-8"];   (* 明示的 UTF-8 decode *)
    If[!StringQ[str], Return[Null]];
    data = Quiet @ ImportString[str, "RawJSON"];          (* documented API *)
    If[AssociationQ[data] || ListQ[data], data, Null]
  ];
```

### 例 L-23: 修正検証 (Step 4 のテスト再実行 v3)

```mathematica
(* バージョン更新確認 *)
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-9-p1-step4-summary-stale-utf8fix-v3" *)

(* 既存の二重 encode / Latin-1 化け版 JSON ファイルを完全クリア *)
DeleteDirectory[FileNameJoin[{
  SourceVault`$SourceVaultRoots["PrivateVault"], "notebooks"}],
  DeleteContents -> True];

(* Index + Summary 登録を新規にやり直す *)
SourceVaultIndexNotebook[path];
SourceVaultRegisterNotebookSummary[path,
  "第14回オンライン語り交流会の準備notebook。参加登録は完了済み。"]

(* Get で日本語が正しく読めるか確認 *)
SourceVaultGetNotebookSummary[path]["Summary"]
(* → "第14回オンライン語り交流会の準備notebook。参加登録は完了済み。"
     (v1/v2 では Ç¬¬14... に化けていた) *)
```

### デバッグ補助 — 万一まだ化ける場合の確認手順

万一 utf8fix-v3 でも化けが続く場合、次のデバッグコードで根本原因を切り分けてください:

```mathematica
(* Step 1: ファイルの生 byte 列を確認 *)
summaryPath = FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"],
  "notebooks", "summaries", "sum-nb-src-5d9fd9f24923df19.json"}];

rawBytes = ReadByteArray[summaryPath];
Length[rawBytes]
(* → JSON ファイルのバイト数 *)

(* 先頭 80 byte を hex 表示 *)
IntegerString[Normal[rawBytes][[1;;Min[80, Length[rawBytes]]]], 16, 2]
(* "第" が含まれていれば、UTF-8 の場合 "e7 ac ac" が連続するはず
   Latin-1 二重 encode なら "c3 a7 c2 ac c2 ac" 等 *)

(* Step 2: UTF-8 decode の確認 *)
str = ByteArrayToString[rawBytes, "UTF-8"];
StringLength[str]    (* 文字数 *)
StringTake[str, 100] (* 先頭 100 文字 *)

(* Step 3: JSON parse の確認 *)
parsed = ImportString[str, "RawJSON"];
parsed["Summary"]
(* → これが化けていなければ Wolfram 経路は正常、Get 経路にバグ *)
(* → これが化けていれば Wolfram の ImportString or ByteArrayToString が問題 *)
```

このデバッグ手順で原因を特定できれば、次の修正に向けて確実な情報になります。

### 教訓の追加

utf8fix を 3 回出した反省:

1. **未 documented API の使用は避ける**: utf8fix-v2 で `Developer\`ReadRawJSONString` を使ったのは、Imai 先生のメモリで MathWebServer 文脈 (HTTP body 処理) の記述を見て即座に流用した結果。File I/O 文脈では documented `ImportString` が確実
2. **Wolfram option の組合せ挙動は実装依存**: `BinaryFormat -> True + CharacterEncoding -> "UTF-8"` のようにドキュメントで挙動が明示されていない組合せは避ける。**option は単一の意図** で使う
3. **L5973 のパターンを最初から横展開すべきだった**: Imai 先生が動作確認済みのコードが既に存在しているのに、私が新規 helper で `Developer\`ReadRawJSONString` を導入したのが余計な変動要因

「Wolfram 標準関数優先原則 (rule 102)」は documented API 優先という意味も含むことを、本事例で再確認しました。

---

## Stage 9 P1 Step 4 utf8fix v4 — ファイル自体の UTF-8 正常化

result15.nb で **画面表示** の文字化けは直りましたが、**JSON ファイル自体** は依然として二重 encode された状態でした (`v2026-05-19-stage-9-p1-step4-summary-stale-utf8fix-v4`)。

### Imai 先生の指摘 (重要)

```
"Summary":"ç¬¬14åãªã³ã©ã¤ã³èªãäº¤æµä¼ã®æºånotebookãåå ç»é²ã¯å®äºæ¸ã¿ã"
```

これは `第14回オンライン語り交流会の準備notebook。参加登録は完了済み。` の **二重 encode UTF-8**。ファイル汚染状態であり、SourceVault の他のツールや別環境 (Linux/Mac) で読むと化けたまま表示されるため、これは絶対に解決しなければならない問題です。

### 「画面では直って見えた」原因 (utf8fix v3 までの偶然の整合)

utf8fix-v3 までの状態:

1. 書き出し: `ExportString[record, "RawJSON"]` の戻り値 String を `StringToByteArray[X, "UTF-8"]` で byte 化してファイル保存 → **二重 encode**
2. 読み出し: `ReadByteArray + ByteArrayToString[UTF-8]` で 1 段戻して Latin-1 chars の String を取得
3. `ImportString[..., "RawJSON"]` が JSON 仕様で **String を UTF-8 byte sequence として再解釈** → 偶然元に戻る

つまり書き出しの「二重 encode」が読み出しの「二重 decode」で相殺され、画面上は正常に見えていました。しかし **ファイル自体は壊れている**。

### 真の原因 — `ExportString[..., "RawJSON"]` の戻り値の特殊性

`ExportString[<|"x" -> "第"|>, "RawJSON"]` の戻り値 String を観察すると、`第` (U+7B2C) が **3 文字 `\[CCedilla]\[Not]\[Not]` (U+00E7 U+00AC U+00AC)** として持たれている。これは「第」の UTF-8 encode 結果 `e7 ac ac` の各 byte を Latin-1 文字とみなした Wolfram String 表現。

つまり Wolfram の `ExportString[..., "RawJSON"]` は **「UTF-8 byte sequence を 1 codepoint = 1 byte の String として保持する」** 仕様で動いています。これは JSON 仕様 (UTF-8 encoded text として扱う) との整合上、内部的にあえてこの表現を採用しているものと思われます。

このため、Wolfram の **`Export[path, record, "RawJSON"]` を直接呼べば、内部でこの Latin-1 表現 String を 1 byte ずつファイルに書き出す**ことになり、結果として正しい UTF-8 ファイルが生成されます。

しかし私たちは低レベル `OpenWrite + BinaryWrite` 経路を使っており、ここで `StringToByteArray[X, "UTF-8"]` を適用すると **各 Latin-1 文字をさらに UTF-8 encode** してしまい、二重 encode になっていました。

### 修正 (utf8fix-v4)

書き出し 12 箇所の `StringToByteArray[X, "UTF-8"]` を **`StringToByteArray[X, "ISO8859-1"]`** に変更。

```mathematica
(* 旧 (utf8fix-v3): 二重 encode *)
BinaryWrite[strm, StringToByteArray[json, "UTF-8"]];

(* 新 (utf8fix-v4): 1 codepoint = 1 byte で書き出し、ExportString が既に持っている UTF-8 byte sequence をそのままファイルへ *)
BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
```

`StringToByteArray[X, "ISO8859-1"]` は **Wolfram String の各 codepoint を下位 8 bit のみ取り出して byte 化** します。`ExportString[..., "RawJSON"]` の戻り値 String は各文字が既に UTF-8 byte の Latin-1 表現になっているため、`ISO8859-1` で byte 化することで **元の UTF-8 byte sequence が正しくファイルに書かれます**。

### 例 L-24: 真の修正検証

```mathematica
(* バージョン確認 *)
SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-9-p1-step4-summary-stale-utf8fix-v4" *)

(* 二重 encode された既存ファイルを完全クリア *)
DeleteDirectory[FileNameJoin[{
  SourceVault`$SourceVaultRoots["PrivateVault"], "notebooks"}],
  DeleteContents -> True];

(* Index + Summary 再登録 *)
SourceVaultIndexNotebook[path];
SourceVaultRegisterNotebookSummary[path,
  "第14回オンライン語り交流会の準備notebook。参加登録は完了済み。"]

(* 画面確認 *)
SourceVaultGetNotebookSummary[path]["Summary"]
(* → "第14回オンライン語り交流会の準備notebook。参加登録は完了済み。" *)

(* ファイル確認 (これが utf8fix-v4 の真の検証) *)
summaryPath = FileNameJoin[{
  SourceVault`$SourceVaultRoots["PrivateVault"], "notebooks",
  "summaries", "sum-nb-src-5d9fd9f24923df19.json"}];

(* 1. UTF-8 として読んで日本語が正しく出るか *)
ByteArrayToString[ReadByteArray[summaryPath], "UTF-8"]
(* → 正常な JSON 文字列が日本語含めて表示されるはず *)

(* 2. 先頭の生 byte 列 (16進) を確認: 「第」は UTF-8 で e7 ac ac *)
IntegerString[Normal[ReadByteArray[summaryPath]][[1;;200]], 16, 2]
(* → どこかに "e7" "ac" "ac" が連続する箇所があるはず
       (utf8fix-v3 までの二重 encode 版では "c3" "a7" "c2" "ac" "c2" "ac" だった) *)
```

### Wolfram の挙動についての追加注記

Wolfram の `Export[path, record, "RawJSON"]` を直接使えば、内部でこの問題を回避してくれた可能性があります (Wolfram 自身が `ExportString` の Latin-1 表現を理解してファイル書き出ししているはず)。なぜ低レベル `OpenWrite + BinaryWrite` 経路を採用していたかは Stage 9 P0 時点の設計判断に遡りますが、Step 6 (NBAccess approval 経由 commit) や atomic write 要件で必要になる可能性があるため、低レベル経路を維持しつつ encoding を正しくする方向で修正しました。

将来のリファクタリング候補として `Export[path, record, "RawJSON"]` 直接呼び (atomic write は不要なら) を検討する余地もあります。

### 教訓の追加 (utf8fix-v4)

4 回 utf8fix を出した反省:

1. **画面表示 ≠ ファイル正常性**: 「読み出して画面に出して化けがない」と「ファイル自体が標準的に正しい」は別問題。SourceVault のような **データ永続化システム** ではファイル自体が標準的でなければならない (他のツール・他環境・将来の処理ですべて読めるべき)
2. **Wolfram の API は内部表現の癖を持つ**: `ExportString[..., "RawJSON"]` のように一見「String を返す」関数でも、内部でその String の意味付け (Unicode codepoint vs UTF-8 byte sequence) が独特な場合がある
3. **早期にファイル byte レベル確認**: 文字化け系のバグは「画面表示」だけでなく `ReadByteArray + IntegerString[..., 16]` で **byte 列レベル** で確認すべき。例 L-23 のデバッグコードを最初から実行依頼すべきだった

これで Stage 9 P1 Step 4 utf8fix の累計 4 回の苦闘を終え、ファイル自体も画面表示も正しい UTF-8 を保つ状態に到達したはずです (要 result16.nb で検証)。

---

## Stage 9 P1 Step 5 — SourceVaultNotebookSummary (LLM 要約)

引継ぎ書類 §9 (5) の **`SourceVaultNotebookSummary` (LLM 要約)** を実装 (`v2026-05-19-stage-9-p1-step5-llm-summary`)。Step 4 で整えた lifecycle 管理の枠組みに LLM 要約経路を接続します。

### 設計方針

| 項目 | 内容 |
|---|---|
| API | `SourceVaultNotebookSummary[path, opts]` |
| LLM 呼び出し | `ClaudeQuerySync` (claudecode.wl 既存 API) |
| デフォルト Privacy | **`PrivacyLevel -> 1.0`** (notebook は個人ノートなので、ローカル LM 経由を default) |
| Prompt 構成 | Header (Keywords/Status/Deadline/NextReview) + Todos (Open/Done/Pass) + Lint flags + 最初の数 cell text |
| 保存経路 | Step 4 の `SourceVaultRegisterNotebookSummary` を内部呼び出し (lifecycle 管理に自動で乗る) |
| 既存 summary との連携 | `Current` ならスキップして既存を返す (Cached: True)。`Stale` / `Missing` で生成 |

### Privacy 設計の意図

notebook は個人作業ノート (スケジュール、メモ、Todo) を含むため、**デフォルトでは Claude API に内容を送らない**設計にしました:

```mathematica
Options[SourceVaultNotebookSummary] = {
  "PrivacyLevel" -> 1.0,    (* デフォルト: ローカル LM 経由 *)
  ...
};
```

`PrivacyLevel -> 1.0` のとき、`ClaudeQuerySync` は `$ClaudePrivateModel` (lmstudio + qwen 等) に振り分けます。**API 送信を許可したい場合は明示的に `PrivacyLevel -> 0.0` を指定**。

### オプション

| Option | Default | 用途 |
|---|---|---|
| `"ForceRefresh"` | `False` | `True` で既存 Current summary も再生成 |
| `"MaxLength"` | `500` | 要約の最大文字数 (LLM prompt で指定) |
| `"Language"` | `Automatic` | `"Japanese"` / `"English"` / `Automatic` |
| `"Model"` | `Automatic` | `{"provider", "model"}` で明示指定可 |
| `"PrivacyLevel"` | `1.0` | `0.0` (API 許可) 〜 `1.0` (ローカルのみ) |

### Prompt の構造

```
You are summarizing a Mathematica notebook for an index. 
Produce a concise summary in at most 500 characters. 
Respond in Japanese.

Focus on: what this notebook is about, its purpose, 
the current state of work (open/done/pass todos), 
any critical deadlines.

=== Notebook metadata ===
Title: 20260516-第14回オンライン語り交流会
Status (header): Todo
Deadline: DateObject[{2026, 5, 13}, "Day"]
Next review: DateObject[{2026, 5, 13}, "Day"]
Keywords: みんなのケア情報学会, オンライン語り交流会

=== Todos ===
Open (1): サンプル
Done (1): 参加登録
Pass (1): サンプル2

=== Lint flags ===
DeadlinePast, NextReviewPast, TodoCellStatusHeuristicOnly

=== First cells ===
[Title] 第14回オンライン語り交流会
[Subsection] 開催概要
[Text] 日時: 2026年5月16日(土) 14:00〜
...

=== Output ===
Provide only the summary text, nothing else.
```

### 例 L-25: 初回要約生成 (デフォルト = ローカル LM)

```mathematica
path = "C:\\path\\to\\20260516-第14回オンライン語り交流会.nb";

result = SourceVaultNotebookSummary[path]
(* → <|"Status" -> "OK",
       "SummaryId" -> "sum-nb-src-5d9fd9f24923df19",
       "Summary" -> "(LLM が生成した日本語要約)",
       "BasedOnSnapshot" -> "snap-sha256-...",
       "BasedOnSemanticHash" -> "semhash-sha256-...",
       "GeneratedBy" -> "claude-local-private",
       "Cached" -> False,
       "PromptLength" -> _Integer|> *)

(* 同じパスを再度呼ぶ → Cached: True *)
SourceVaultNotebookSummary[path]
(* → <|..., "Cached" -> True|> (新規 LLM 呼び出し無し) *)

(* SummaryStatus で確認 *)
SourceVaultNotebookSummaryStatus[path]
(* → <|"Status" -> "Current", "Reason" -> "SameSnapshot", ...|> *)
```

### 例 L-26: API モデル明示指定 (Claude Sonnet)

`PrivacyLevel -> 0.0` で Claude API を許可:

```mathematica
result = SourceVaultNotebookSummary[path,
  "Model" -> {"anthropic", "claude-sonnet-4-6"},
  "PrivacyLevel" -> 0.0,
  "MaxLength" -> 300,
  "Language" -> "Japanese"]
(* → "Summary" -> "(Claude Sonnet が生成した日本語要約)",
       "GeneratedBy" -> "claude-anthropic/claude-sonnet-4-6", ... *)
```

### 例 L-27: 強制再生成

```mathematica
SourceVaultNotebookSummary[path, "ForceRefresh" -> True]
(* → 既存 Current でも新規 LLM 呼び出しを実行、Cached: False *)
```

### 例 L-28: 編集 → 自動 stale 検出 → 再要約のワークフロー

```mathematica
(* 1. notebook を編集して Todo Status などが変わった *)
(* 2. 再 index で snapshot 更新 *)
SourceVaultIndexNotebook[path];

(* 3. summary が stale か確認 *)
status = SourceVaultNotebookSummaryStatus[path];
Switch[Lookup[status, "Status", ""],
  "Current",
    "Summary is up-to-date",
  "StaleFormattingOnly",
    "Only formatting changed, summary can be reused",
  "Stale" | "Missing",
    SourceVaultNotebookSummary[path]   (* 再生成 *)
]
```

### 既存 API への影響

Stage 9 P1 Step 5 は **既存 API の挙動を変更しません**。新 API `SourceVaultNotebookSummary[path, opts]` は **追加のみ** で破壊的変更なし。

### Step 4 との連携アーキテクチャ

```
SourceVaultNotebookSummary[path]
        ↓
[既存 summary が Current か確認 — Step 4 の SummaryStatus 経由]
        ↓ Stale または Missing
[Header / Todos / Lint / first cells を取得 — Step 1/2/4 の既存 API]
        ↓
[Prompt 構築 — iBuildNotebookSummaryPrompt]
        ↓
ClaudeQuerySync[prompt, Model -> ..., PrivacyLevel -> ...]
        ↓
SourceVaultRegisterNotebookSummary[path, llmResponse, ...]
        ↓
[Step 4 の lifecycle 管理に乗る]
```

Step 5 は **LLM prompt 設計と呼び出し経路だけを担当** し、ファイル保存・snapshot 紐付け・lifecycle 判定はすべて Step 4 の API が処理する薄いレイヤー設計です。

### LLM 接続前の準備

`SourceVaultNotebookSummary[path]` を実行するには、**`ClaudeQuerySync` が動作する状態**である必要があります:

| PrivacyLevel | 要件 |
|---|---|
| `1.0` (default) | ローカル LM (lmstudio) が起動済み + `$ClaudePrivateModel` 設定済み |
| `0.0` | `$AnthropicAPIKey` 等 API キー設定済み |
| `Automatic` | claudecode.wl の自動判定 (環境設定に依存) |

LLM が利用できない環境では `Status -> "Failed"`, `Reason -> "LLMQueryFailed"` が返ります。

### 次のステップ

Step 5 で notebook の自動要約パイプラインが整いました。次は引継ぎ書類 §9 (6) の **`SourceVaultMarkTodo` (NBAccess approval 経由で notebook commit)** が重要マイルストーン。これは **書き込み系操作で初めて NBAccess を経由する**ため、approval workflow との接続が中心の作業になります。

---

## Stage 9 P1 Step 5 pkgfix — パッケージコンテキスト修正

result17.nb のテストで `Status: "Failed", Reason: "LLMQueryFailed"` + `RawResponse: SourceVault\`Private\`ClaudeQuerySync[...]` という現象を確認 (`v2026-05-19-stage-9-p1-step5-llm-summary-pkgfix`)。

### 原因

`ClaudeQuerySync` は `ClaudeCode\`` パッケージで公開されているシンボルですが、SourceVault.wl の `BeginPackage["SourceVault\`", {"NBAccess\`"}]` は `ClaudeCode\`` を依存パッケージに含めていません。そのため SourceVault.wl の `Private` コンテキスト内で `ClaudeQuerySync` を参照すると、Wolfram は:

1. 現在のコンテキスト `SourceVault\`Private\`` を探す → なし
2. `$ContextPath` を探す → `ClaudeCode\`` が含まれていない場合は見つからない
3. **`SourceVault\`Private\`ClaudeQuerySync` という新規の空シンボルを作る**

結果として `ClaudeQuerySync[...]` 呼び出しが unevaluated な式として残り、`StringQ[response]` が False になって `LLMQueryFailed` が返ります。

### 修正

`iCallSummaryLLM` 内で **完全修飾形 `ClaudeCode\`ClaudeQuerySync`** を使用し、`Needs["ClaudeCode\`"]` でロードを保証:

```mathematica
iCallSummaryLLM[prompt_String, model_, privacyLevel_] :=
  Module[{response, modelOpt, privacyOpt},
    modelOpt = If[model === Automatic, Automatic, model];
    privacyOpt = If[privacyLevel === Automatic, Automatic, privacyLevel];
    Quiet @ Needs["ClaudeCode`"];               (* ロード保証 *)
    If[!ValueQ[ClaudeCode`ClaudeQuerySync],     (* 念のため未定義チェック *)
      Return[<|"Status" -> "Failed",
        "Reason" -> "ClaudeQuerySyncNotAvailable", ...|>]];
    response = Quiet @ ClaudeCode`ClaudeQuerySync[prompt,
      ClaudeCode`Model -> modelOpt,
      ClaudeCode`PrivacyLevel -> privacyOpt];   (* オプション名もシンボルなので完全修飾 *)
    ...
  ];
```

### 設計選択の理由

選択肢を 3 つ検討:

| 案 | 内容 | 採用? |
|---|---|---|
| A | `BeginPackage["SourceVault\`", {"NBAccess\`", "ClaudeCode\`"}]` に変更 | ✗ SourceVault に強依存追加、単独ロード不可 |
| B | `BeginPackage` 変更せず、完全修飾形 `ClaudeCode\`ClaudeQuerySync` を使用 | ✗ ロード保証なし、未ロード時に空シンボル化 |
| **C** | **B + `Needs["ClaudeCode\`"]` でロード保証** | ✅ **採用** |

案 C は SourceVault.wl 内で既に確立されているパターン (L867 の `StringStartsQ[c, "ClaudeCode\`"]`、L2943 の `Names["ClaudeCode\`ClaudeQueryBg"]` 等) と整合します。

### Quit[] 推奨

Imai 先生が前回のテスト (result17.nb) で実行した結果、現在のセッション内に `SourceVault\`Private\`ClaudeQuerySync` という **空のシンボル** が残っています。新版 SourceVault.wl をロードしても、Private コンテキスト内のシンボルは消えません。

新版コードは `ClaudeCode\`ClaudeQuerySync` を呼ぶため空シンボルは無関係ですが、念のため pkgfix のテスト前に `Quit[]` でセッションをリセットすることを強く推奨します。

### 例 L-29: pkgfix 修正後のテスト

```mathematica
Quit[]   (* セッションリセット推奨 *)

(* セッション再起動後 *)
<< claudecode.wl    (* SourceVault より先にロード *)
<< SourceVault.wl

SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-9-p1-step5-llm-summary-pkgfix" *)

(* 注意: ClaudeQuerySync 内部で $ClaudePrivateModel を参照するので、
   ローカル LM (lmstudio + qwen 等) が起動済みかつ
   $ClaudePrivateModel が設定済みである必要があります *)
$ClaudePrivateModel    (* → {"lmstudio", "..."} 等が表示されること *)

path = FileNameJoin[{$onWork, "20260516-第14回オンライン語り交流会",
  "20260516-第14回オンライン語り交流会.nb"}];

(* 要約生成 *)
SourceVaultNotebookSummary[path]
(* → Status: "OK", Summary: "(LLM が生成した日本語要約)", Cached: False *)
```

### LLM 未利用環境の確認

LLM が利用できない環境では新しい Failed が返ります:

```mathematica
(* claudecode.wl がロードされていない場合 *)
(* → Status: "Failed", Reason: "ClaudeQuerySyncNotAvailable" *)

(* ロード済みだが LLM 接続が失敗する場合 (lmstudio 未起動など) *)
(* → Status: "Failed", Reason: "LLMQueryFailed" *)
```

### 教訓

5 回目のサブ修正の反省:

1. **パッケージ間呼び出しでは常に完全修飾形を使う**: Private コンテキスト内で他パッケージのシンボルを参照すると shadow されるリスクがある
2. **SourceVault 内に既存パターンがあった**: L2943 の `Names["ClaudeCode\`ClaudeQueryBg"]` をもっと早く参照すべきだった
3. **オプション名もシンボル shadow の対象**: `Model`, `PrivacyLevel` などのオプション名も完全修飾 `ClaudeCode\`Model` で書く必要がある

---

## Stage 9 P1 Step 5 pkgfix-v2 — `ValueQ` の罠修正

result18.nb で `Status: "Failed", Reason: "ClaudeQuerySyncNotAvailable"` が返ったが、`$ClaudePrivateModel` (lmstudio) は設定済みで claudecode.wl もロード済み (バージョン文字列 pkgfix を返している = ロード成功している) という矛盾を発見。

### 原因 — Wolfram の `ValueQ` の罠

`ValueQ[f]` は **OwnValues** (`f = 5` のような直接代入) のみチェックし、**DownValues** (`f[x_] := ...` のような関数定義) には **False を返す**。

`ClaudeCode\`ClaudeQuerySync` は `ClaudeQuerySync[prompt_String, opts:OptionsPattern[]] := Module[...]` のように DownValues として定義された関数なので、`ValueQ[ClaudeCode\`ClaudeQuerySync]` は **常に False**。私のロード判定が誤動作し、せっかくロード済みの ClaudeQuerySync を呼ばずに即座に Failed を返していました。

### 修正

`ValueQ` を **`Length[Names["ClaudeCode\`ClaudeQuerySync"]] === 0`** に変更。これは SourceVault.wl 内で既に複数箇所で使われている確立パターン:

```mathematica
(* L2943 周辺の既存パターン *)
If[Length[Names["ClaudeCode`ClaudeQueryBg"]] === 0,
  ...]
```

`Names["ClaudeCode\`ClaudeQuerySync"]` は **シンボル名がそのコンテキストに登録されているか** を文字列マッチで確認するため、定義の種類 (OwnValues / DownValues) に関係なく確実に動作します。

### 例 L-30: pkgfix-v2 の最終テスト

```mathematica
Quit[]
<< claudecode.wl
<< SourceVault.wl

SourceVault`$SourceVaultVersion
(* → "2026-05-19-stage-9-p1-step5-llm-summary-pkgfix-v2" *)

(* $ClaudePrivateModel が設定されていることを確認 *)
$ClaudePrivateModel
(* → {"lmstudio", "qwen3.6-27b", "http://192.168.2.110:1234"} *)

(* 念のため Names で ClaudeQuerySync が見えていることを確認 *)
Names["ClaudeCode`ClaudeQuerySync"]
(* → {"ClaudeCode`ClaudeQuerySync"} *)

path = FileNameJoin[{$onWork, "20260516-第14回オンライン語り交流会",
  "20260516-第14回オンライン語り交流会.nb"}];

SourceVaultNotebookSummary[path]
(* → Status: "OK", Summary: 日本語要約, Cached: False *)
```

### 教訓 (追加)

Wolfram の罠 #25 (候補):

> **`ValueQ[f]` は DownValues を見ない** — 関数 `f` が `f[x_] := ...` で定義されている場合、`ValueQ[f]` は False を返す。関数の存在確認には `Length[Names["...Context\`f"]] > 0` を使う。

これは Wolfram の罠カタログに永続化候補。`ValueQ` の挙動はドキュメントには書いてあるが、見落としやすい仕様。

---

## Stage 9 P0 開発の教訓 (Wolfram 標準関数優先原則)

Stage 9 P0 は result6 → result7 → result8 → result9 の **4 サイクル**を経て確定実装に到達しました。試行錯誤の経緯は ClaudeDirective に永続記録されています:

- **rule `102-wolfram-stdlib-first`** (新規) — Notebook / 式の構造にアクセスするときは必ず先に Wolfram 標準関数を探す
- **skill `notebook-management-extraction`** (更新) — Stage 9 P0 設計詳細、Cycle 1-5 の経緯、3 値 Status 判定
- **skill `wolfram-syntax-pitfalls`** (更新) — 罠 #21 / #22 / #23 を追記

| サイクル | 試行 | 結果 |
|---|---|---|
| Cycle 1 | `Import[path, "Text"]` + `ToExpression[..., InputForm, HoldComplete]` | `NotANotebookFile` (罠 #21) |
| Cycle 2 | `Get[path]` → Cell パターンマッチ | `MissingHeader` (罠 #21) |
| Cycle 3 | `Import["Initialization"]` + `Import["Notebook"]` + パターンマッチ | Header ✓ / Todo ✗ (罠 #23: package private context で `Cell` が別シンボル化) |
| Cycle 4 | `NotebookImport[path, style -> "Cell"]` | Todo ✓ (ただし Status は 2 値の短絡判定) |
| **Cycle 5 (最終)** | **`NotebookImport` + 3 値判定 (StrikeThrough + FontColor)** | ✓ result9.nb で完全動作 |

| # | 罠 | 対策 |
|---|---|---|
| **#21** | `.nb` を `Get[path]` / `Import[path, "Text"]` + `ToExpression` でパースしない | `Import["Notebook"]` / `Import["Initialization"]` / `NotebookImport` を使う |
| **#22** | `ToString[box]` + `ToExpression` ラウンドトリップは box 用途で破綻 | `MakeExpression[box, StandardForm]` を使う |
| **#23** | Package private context で `Cell` / `Notebook` 等の生パターンマッチは別シンボル化 | `SymbolName[Head[c]] === "Cell"` 文字列比較 (context 非依存) |

「ノートブック情報にアクセスするときは、パターンマッチではなく **まず Mathematica 標準の関数を探す**」 — これが Stage 9 P0 から永続化された開発原則です。

---

## SourceVault Phase 1 完成 + Stage 9 P0

これで主要 deliverable がすべて出揃いました:

| Stage | Phase 1 |
|---|---|
| 1〜5 | ✓ |
| 6a Claim dedup + Compact | ✓ |
| 6b Compiled Registry | ✓ |
| 6c Evidence Bundle Phase 1 | ✓ |
| 6d NBAuthorize 2-stage | ✓ |
| 8 vN diff + lifecycle | ✓ |
| **9 Notebook Management P0** | ✓ **(本セッション)** |

残作業は各 Stage の Phase 2/3 と、Workflow Migration 完了後の Stage 7 (Petri net 化) のみ。

---


## hook 設計の概要

P1〜P4 はすべて **既存 API への破壊的変更ゼロ** で実装されています。

- **P1, P2**: `ClaudeCode\`ClaudeAttach` / `ClaudeAttachments` の **DownValues を一時退避** → 新定義を載せ替え → Disable 時に Block で元 DownValues を復元 (再入安全)
- **P3, P4**: ClaudeOrchestrator.wl 本体に **5 行 + iApplyA6Hook** という最小フック点を追加 (Phase 34 の A4 hook と同じパターン)。SourceVault.wl 側で `ClaudeOrchestrator\`A5/A6...` 関数を絶対コンテキストで定義/Clear

これにより:

- SourceVault.wl がロードされていなくても ClaudeOrchestrator は通常動作
- hook 関数定義が存在しないときは A5/A6 hook 行は `Names[]` チェックで skip
- Enable / Disable は SourceVault.wl 側の関数 1 つで完結

## 4 hook の組み合わせ早見表

| シナリオ | P1 | P2 | P3 | P4 |
|---|---|---|---|---|
| 単純に文書を ingest して抜粋取得 | — | — | — | — |
| notebook に attach した瞬間に SourceVault も自動登録 | ✓ | — | — | — |
| `ClaudeAttachments[]` から SnapshotId を取得したい | ✓ | ✓ | — | — |
| LLM worker に添付文書を自動的に prompt で渡したい | ✓ | — | ✓ | — |
| LLM 応答内の `<source>...</source>` を次ターンで自動再注入 | ✓ | — | ✓ | ✓ |
| フル機能 | ✓ | ✓ | ✓ | ✓ |

P3 だけ enable する場合でも、自動検出ソースは「P1 hook が記録した TaggingRule」を読むので、P1 enable が必須前提となります。

---

## 関連ドキュメント

- **`sourcevault-spec-v0_13.md`** — SourceVault 仕様書 (snapshot lifecycle, span 構造, trust model)
- **`sourcevault-physical-storage-extension-v0_13.md`** — 物理ストレージレイアウト (`raw/by-hash/`, `meta/`, `parsed/`, etc.)
- **`example.md`** — ClaudeOrchestrator 本体の使用例集 (本ドキュメントの兄弟)
- **`SourceVault.wl`** — 実装 (Sections 1-18 + Stage 0-3 + Stage 4 Phase 4A URL ingest)

---

# Part D. 暗号化・identity・メール管理

このパートでは、SourceVault の **at-rest 暗号化基盤・可搬鍵バンドル・2層アドレス帳 (identity)・メール (MailDB/IMAP/Mail UI)** をコピー&ペーストで試せる形で示します。すべての公開シンボルは context `SourceVault\`` にあります。

> **重要 (ロード前に backend を設定):** 実データを永続化するには `SystemCredential` backend が必須です。`SystemCredential` で暗号化したデータは `Memory` セッションでは本文を復号できません。**パッケージのロード前に** backend を設定してください。
>
> プレースホルダ値 (`you@example.org` / `WORK_IMAP_PASSWORD` / パスフレーズ等) は**ご自身の値に置き換えて**ください。

---

## 例 D-0: backend 設定 + ロード + 暗号鍵 bootstrap

```mathematica
(* 1. backend を必ずロード前に設定 (本番は SystemCredential) *)
NBAccess`$NBCredentialBackend = "SystemCredential";   (* 開発・テストは "Memory" *)

(* 2. ロード *)
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",    "NBAccess.wl"];
  Needs["SourceVault`", "SourceVault.wl"]];

(* 3. 冪等な鍵 bootstrap (欠落鍵だけ生成。鍵材料は返さない) *)
SourceVaultInitializeEncryption[]
(* → <|"Status" -> "AlreadyInitialized" | "Initialized",
       "KeyMaterialReturned" -> False, ...|> *)

(* 4. 標準 KeyRef の状態確認 (鍵材料なし) *)
SourceVaultEncryptionKeyStatus[]

(* 5. この WL 環境の暗号能力と自己診断 *)
SourceVaultCryptoCapabilityReport[];
SourceVaultCryptoSelfTest[]
```

---

## 例 D-1: 暗号 record の put → get → decrypt (roundtrip)

```mathematica
(* 機密オブジェクトを encrypt-then-MAC で保存 (平文は保存しない) *)
r = SourceVaultEncryptedPut[<|"Prompt" -> "secret text"|>,
  "PrivacyLevel" -> 0.9, "ContentType" -> "Demo"];
rid = r["RecordId"];
{r["Status"], r["PlaintextPersisted"]}
(* → {"Stored", False} *)

(* 暗号 record を取り出す (plaintext は返らない) *)
rec = SourceVaultEncryptedGet[rid];
SourceVaultEncryptedRecordQ[rec]
(* → True *)

(* MAC 検証して復号 *)
d = SourceVaultDecryptRecord[rec];
{d["Status"], d["Plaintext"]}
(* → {"Ok", <|"Prompt" -> "secret text"|>} *)
```

AAD (Policy/Derived) を改ざんすると復号は静かに失敗せず拒否されます。

```mathematica
(* PrivacyLevel を書き換えると MAC が一致せず AuthenticationFailed *)
tampered = rec;
tampered["Policy", "PrivacyLevel"] = 0.0;
SourceVaultDecryptRecord[tampered]["Status"]
(* → "Error" (Reason "AuthenticationFailed") *)
```

---

## 例 D-2: 可搬鍵バンドルのエクスポート / インポート

鍵はマシンローカル (DPAPI) なので、別マシンや復旧用に鍵バンドルを書き出します。**パスフレーズはご自身の秘密に置き換えてください。バンドルは Dropbox の外で管理します。**

```mathematica
(* 旧マシン: 標準鍵をパスフレーズで包んだバンドルをホーム直下に書く *)
ex = SourceVaultExportKeyBundle["correct horse battery staple xyz"];
{ex["Status"], ex["Path"], ex["KeyCount"], ex["OnSyncFolderWarning"]}
(* → {"Exported", "...\\SourceVault_keybundle.svkeys", 10, False} *)

(* パスフレーズ不要の非秘密メタだけ確認 *)
SourceVaultKeyBundleInfo[]
(* → <|"Status" -> "Ok", "KeyCount" -> 10, "KDF" -> <|...scrypt...|>, ...|> *)

(* 新マシン: 先にインポートしてから InitializeEncryption (順序が重要) *)
im = SourceVaultImportKeyBundle["correct horse battery staple xyz"];
{im["Status"], im["RestoredCount"], im["Backend"]}
(* → {"Imported", 10, "SystemCredential"} *)

SourceVaultInitializeEncryption[]   (* → "AlreadyInitialized" *)
```

> **メモ:** 既定の書き出し先は `$SourceVaultKeyBundleDefaultPath` (`$HomeDirectory\SourceVault_keybundle.svkeys`、Dropbox 外)。`"ScryptN" -> 131072` が既定。テストでは N を下げて高速化できますが、本番は既定のままにしてください。

---

## 例 D-3: 2層アドレス帳 (identity) の初期化と所有者プロフィール

```mathematica
(* load + self(EntityUid=1) bootstrap (冪等) *)
SourceVaultIdentityInitialize[]
(* → <|"Status" -> "Initialized", "SelfUid" -> 1, ...|> *)

(* 所有者プロフィール (派生プロンプトの受信者プロフィールに使われる) を設定 *)
SourceVaultSetOwnerLLMProfile["Affiliation, Title, research interests..."];
SourceVaultSetOwnerPrimaryEmail["you@example.org"];

{SourceVaultOwnerPrimaryEmail[], SourceVaultOwnerLLMProfile[]}
```

識別子の観測と実体への紐付け:

```mathematica
(* 識別子を観測 (メール取込では自動。ここでは手動 upsert) *)
id = SourceVaultObserveIdentifier["Email", "alice@example.org",
  "ObservedName" -> "Alice", "Persist" -> True];

(* 識別子から新規実体を作成 (観測名を DisplayName に継承) *)
SourceVaultIdentifierCreateEntity[id, "Kind" -> "Person"]

(* 実体に Group と PriorityWeight を設定 (重要度計算に効く) *)
ent = SourceVaultResolveIdentifierDisplay[id];     (* 表示名: 実体名→観測名→raw *)
SourceVaultListEntities[]
```

UI (FrontEnd 必須):

```mathematica
SourceVaultAddressBookView[]    (* 連絡先の整形表 *)
SourceVaultIdentityLinkUI[]     (* 未リンク識別子→実体 (新規/マージ) *)
SourceVaultEntityView[]         (* 実体一覧 + 編集ボタン *)
SourceVaultEntityEditUI[1]      (* オーナー(uid=1) の編集フォーム *)
```

---

## 例 D-4: 既存メールの読み込み・検索・対話表示

```mathematica
(* 必要な mbox・期間のシャードだけ遅延ロード (全件ロードは重い) *)
SourceVaultMailEnsureLoaded["work", 3];          (* 直近3ヶ月 *)
SourceVaultMailLoadedCount[]

(* キーワード + フィルタで検索 (プログラム用) *)
hits = SourceVaultSearchMailSnapshots["会議",
  "MinPriority" -> 0.5, "HasAttachment" -> True,
  "SortBy" -> "Priority", "Limit" -> 20];
Length[hits]

(* 対話的な一覧 (FrontEnd 必須)。各行に 本文✉/添付📎/返信↩ *)
SourceVaultMailView["会議", "Limit" -> 20]

(* ボタン無しの素の Dataset (列ソート用) *)
SourceVaultMailDataset["会議", "Limit" -> 20]
```

本文・添付・返信の FE 操作:

```mathematica
rid = hits[[1]]["RecordId"];
SourceVaultMailGetBody[rid]                  (* 本文を復号 (Status/Body) *)
SourceVaultMailShowBody[rid]                 (* 本文を新規ノートブックで表示 *)
SourceVaultMailAttachments[rid]              (* 添付 {Name, Path, Exists} *)
SourceVaultMailOpenAttachment[rid, "report.pdf"]

(* 返信ドラフト生成 (DraftOnly: 自動送信しない) *)
SourceVaultMailComposeReply[rid, "ReplyAll" -> True]
SourceVaultMailOpenReplyNotebook[rid]
```

> **メモ:** 本文の復号には `SystemCredential` backend のセッションが必要です。`Memory` セッションだと本文が空になり、`SourceVaultMailShowBody` は「復号できませんでした」という理由ノートブックを表示します (ヘッダは平文なので一覧自体は出ます)。

---

## 例 D-5: identity バックフィル (既存メールから識別子生成)

identity 導入前に取り込んだメールには識別子がありません。全件ロードしてから一括生成します (再取込不要)。

```mathematica
SourceVaultMailStoreLoad[];               (* 全シャードをロード *)
SourceVaultIdentityBackfillFromMail[]     (* 平文 From/To/Cc を走査して識別子化 *)
```

---

## 例 D-6: IMAP 新着取得 → 派生 (取り込みと LLM の分離)

### IMAP アカウント登録 (設定の外部化)

接続情報はソースに置かず vault config に登録します。**パスワードは保存されず、CredKey (SystemCredential 名) のみ**が永続化されます。

```mathematica
SourceVaultRegisterMailAccount[<|
  "MBox" -> "work", "User" -> "you@example.org", "Email" -> "you@example.org",
  "CredKey" -> "WORK_IMAP_PASSWORD", "Server" -> "imap.example.org", "Port" -> 993|>]

SourceVaultMailAccounts[]            (* 登録済み一覧 (パスワードは含まない) *)
```

### 新着取得 (まず高速取り込み、LLM は後回し)

```mathematica
(* 直近14日を取得 (既定 "Process" -> False で LLM なし)。RecordId で重複排除 *)
SourceVaultMailFetchNew["work", "Period" -> "Latest"]
(* → <|"Status" -> ..., "Stored" -> ..., "Fetched" -> ...|> *)

(* Period は複数形式: 直近n日 / {年,月} / "YYYYMM" / "YYYY" / {fromISO,toISO} *)
SourceVaultMailFetchNew["work", "Period" -> 7]
SourceVaultMailFetchNew["work", "Period" -> {2026, 1}]
```

### 派生 (PL/優先度/概要) の増分バッチ

```mathematica
(* 派生未処理 (Pending) の snapshot を確認 *)
Length[SourceVaultMailDerivedPending[]]

(* 50件ずつローカル LLM で派生生成 (中断しても再開可) *)
SourceVaultInferMailDerivedBatch["Limit" -> 50, "CheckpointEvery" -> 20]
(* → <|"Status" -> ..., "PendingBefore" -> ..., "Processed" -> ...,
       "RemainingPending" -> ...|> *)
```

> 揮発鍵で本文を壊してしまった場合などは `"Overwrite" -> True` で同一 RecordId を実鍵で再保存して修復できます: `SourceVaultMailFetchNew["work", "Period" -> 20, "Overwrite" -> True]`。

---

## 例 D-7: 重要度の構造的計算とグループ重み

優先度は LLM 任せにせず、コードが決定的に計算します。

```mathematica
(* グループ重みを登録 (vault config に永続化) *)
SourceVaultSetPriorityGroupWeight["Colleagues", 0.8];
SourceVaultPriorityGroupWeights[]           (* group -> weight *)
SourceVaultGroupWeightFor["Colleagues"]     (* 0.8 *)

(* 重要度の内訳 (Components) を確認 *)
snap = First[SourceVaultMailSnapshotList[]];
SourceVaultMailExplainPriority[snap]
(* → <|"Priority" -> _, "Components" -> <|"SenderWeight", "OwnerPosition",
       "Bulk", "WorkRequest", "PositionAdj", "BulkAdj"|>|> *)
```

計算式: `Priority = Clip[senderWeight + 0.30*WorkRequest + posAdj + bulkAdj, {0,1}]` (posAdj: To→+0.15 / Cc→0.0 / Bulk→-0.25、bulkAdj: bulk なら -0.15)。`senderWeight` は実体の `PriorityWeight` → `Group` のグループ重み → 既定 0.4 の順に解決されます。個別の差出人の重みは `SourceVaultEntityEditUI` で設定します。

---

## 例 D-8: 安全ポリシーのまとめ

| 不変条件 | 内容 |
|---|---|
| 鍵は外に出さない | 鍵材料は NBAccess (KeyRef) の中だけ。戻り値・ログ・record に現れない |
| encrypt-then-MAC | 改ざん (Policy/Derived の書き換え) は復号拒否 (`AuthenticationFailed`) |
| backend 必須 | 永続データには `SystemCredential`。`Memory` で実 vault に書かない |
| 本文暗号化・ヘッダ平文 | 本文は暗号化、ヘッダ (件名等) は平文 + token (設計上、件名は暗号化しない) |
| 鍵バンドルは Dropbox 外 | 同期フォルダに置かない (機密性がパスフレーズ強度に縮退する) |
| 返信は DraftOnly | メールは**自動送信しない**。返信はドラフト生成のみ |
| 私的データを脱ハードコード | オーナー identity・IMAP アカウントは vault に登録、ソースに置かない |
