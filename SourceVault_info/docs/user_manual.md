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
