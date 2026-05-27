---

# SourceVault

Wolfram Language / Mathematica 上で動作する **Source-First Knowledge Vault** エンジンです。文書 (URL / arXiv / PDF / Notebook / テキスト) を first-class source として ingest し、snapshot lifecycle・claim 抽出・Evidence Bundle・Notebook Management を一貫した状態機械として管理します。さらに、`ClaudeEval` の定型プロンプトを deterministic な関数呼び出しとして再実行する **PromptRouter** を備えます。

## 設計思想と実装の概要

SourceVault は、「source の同一性とライフサイクル管理に専念する」という単一責任の原則に基づいて設計されています。LLM への問い合わせ・式の安全性検証・実行ループは [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime) に委譲され、Notebook セルへのアクセス・編集は [NBAccess](https://github.com/transreal/NBAccess) の semantic API に委譲されます。SourceVault 自身は **抽象 hook インターフェース** を通じてこれらの機能を利用し、source レコード・snapshot・claim・bundle の永続化と参照整合性のみを担います。

ingest した source は **`raw/by-hash/`** に内容ハッシュ単位で保存され、`meta/` 配下の deterministic な JSON レコードから参照されます。snapshot は immutable で、lifecycle (Current / Stale / Frozen / Invalidated) を経由してその後の参照可否が決まります。claim 抽出は per-source の JSONL に append-only で記録され、Compact で dedup できます。Evidence Bundle は claim と snapshot の依存関係を記録し、上流が stale になると自動的に passive consumer として再評価対象になります。

### ingest の構造

SourceVault の中核は **Source-First ingest パイプライン**です。各 source は以下のフェーズで取り込まれます。

1. **Resolve** — URL / arXiv ID / ローカルパスを正規化し、source ID を決定します。
2. **Fetch** — リモートの場合は `URLRead` 等で取得、ローカルなら `ReadByteArray` で読み込み、raw bytes を `raw/by-hash/sha256-<hash>` に書き込みます。
3. **Parse** — `parsed/by-snap/<snapshotId>/pages/NNNN.txt` にページ単位のテキストを抽出します (PDF は 3 種類の OCR backend で fallback)。
4. **Index** — `meta/sources/<sourceId>.json` と `meta/snapshots/<snapshotId>.json` に deterministic な JSON で記録します。
5. **Hook** — NBAccess hook (P1〜P4) を経由して ClaudeAttach や ClaudeOrchestrator に通知し、必要なら ClaudeAttachments への登録や worker prompt への注入を行います。

### claim 抽出と Evidence Bundle

`SourceVaultExtract[snapshotId, schema]` で LLM (ClaudeRuntime 経由) が source から構造化 claim を抽出します。各 claim は **content hash でユニーク化** されており、by-source / by-topic の 3 重 JSONL インデックスから引けます。`SourceVaultBundleCreate` で複数の claim をまとめた Evidence Bundle を作成すると、依存元 snapshot が stale 化したときに **lazy passive consumer** として自動的に再評価が促されます。

### Notebook Management

Mathematica notebook (`.nb`) も first-class source として扱えます。`SourceVaultIndexNotebook[path]` で先頭 Input セルの Header Association を **safe parse** (whitelist 経由) し、TodoItem cell の状態 (`Open` / `Done` / `Pass`) を TaggingRules > StrikeThrough > Default の優先順位で判定し、Deadline / NextReview の lint を生成します。

NBAccess には高レベル semantic API 7 個 (`NBReadHeader` / `NBReadTodos` / `NBFindCellByPredicate` + 書き込み系 4 個) があり、FrontEnd を起動せずに `.nb` ファイルを直接編集できる atomic-write パイプラインが整っています。SourceVault からは `SourceVaultMarkTodo` でこれを呼び出します。

```
.nb ファイル
   ↓ Import["Notebook"] + MakeExpression (副作用なし)
Header / Todo / Cells
   ↓ iFlattenCells で CellGroupData ネストを再帰展開
deterministic な index (sources/snapshots/todos/review/lint)
   ↓ mtime ベース cache (透過的)
2 回目以降は高速 hit
```

### PromptRouter — ClaudeEval の式提案契約

`ClaudeEval["今日から3日間のスケジュールを"]` のような **日常的な定型プロンプト**は、毎回重量級 LLM に再解釈させる必要はありません。PromptRouter は、保存された PromptRoute・WorkflowRoute・notebook cache を用いて、こうしたプロンプトを deterministic な関数呼び出しとして再実行する機構です。

PromptRouter の中核は **式提案契約**です。`ClaudeEval` は「ユーザーに見せる最終値」を直接返す関数ではなく、ユーザーの要求を満たす **Mathematica 式を提案し、その式を ClaudeRuntime が head 検査してから実行する**機構です。したがって PromptRouter も、評価済みの `Association` や `Grid` を返すのではなく、**未評価の式**を返します。

```
ClaudeEval["今日から3日間のスケジュールを"]
   ↓ SourceVaultProposePromptRoute (未評価式を構築)
HoldComplete[
  SourceVaultUpcomingSchedule[
    "Scope" -> $onWork, "Period" -> Quantity[3, "Days"],
    "Refresh" -> "Never", "FallbackToCloud" -> "Deny"]]
   ↓ head 検査 (ReadOnly callable allowlist)
   ↓ ReleaseHold で評価
SourceVaultUpcomingSchedule 本来の装飾付き Grid
```

これにより `ClaudeEval` の出力は、内部診断 `Association` でも PromptRouter 独自の簡易表でもなく、**allowlist 済み callable を評価した結果**(`SourceVaultUpcomingSchedule` 本来の Title link・tooltip・date styling 付きの表)になります。

### TabularQuery — スケジュールの絞り込み

「Todo が残っているもの」「Deadline が今週」のような **表に対する絞り込み**も、PromptRouter は評価済みの表を作らず、allowlist 済み callable の式として表現します。`SourceVaultUpcomingSchedule` には `"FilterSpec"` オプションがあり、構造化述語を literal Association として受け取ります。

```
ClaudeEval["7日間のスケジュールのうちTodoが残っているものを"]
   ↓
HoldComplete[
  SourceVaultUpcomingSchedule[
    "Scope" -> $onWork, "Period" -> Quantity[7, "Days"],
    "Refresh" -> "Never", "FallbackToCloud" -> "Deny",
    "FilterSpec" -> <|"Kind" -> "Field",
      "Field" -> "OpenTodoCount", "Op" -> "Greater", "Value" -> 0|>]]
```

`FilterSpec` の述語は **閉じた DSL** に限定されます。`Kind` は `And` / `Or` / `Not` / `Field`、`Op` は `Equal` / `NotEqual` / `Greater` / `GreaterEqual` / `Less` / `LessEqual` / `Contains` / `DateWithin` / `NonEmpty`、フィールド名はスキーマ allowlist にあるものだけです。`Function` / `Slot` / `ToExpression` / `RunProcess` などは一切受け付けません。`SourceVaultUpcomingSchedule` 内部でこの閉じた述語を record list に適用し、既存の Grid 整形経路に戻します。`Select` や `Function` が式表面に出ないため、Runtime の検証は `SourceVaultUpcomingSchedule` の head と literal option value を見るだけで済みます。

### snapshot lifecycle

snapshot には **LifecycleStatus** (Current / Stale / Frozen / Invalidated) が付与されます。`SourceVaultMarkSnapshotStale` / `Invalidated` / `RefreshSnapshot` は `events/source-events.jsonl` に lifecycle event を append-only で記録し、依存している Bundle 側は lazy に再評価します。これにより「上流の文書が更新されても、下流の引用が古いままになる」という事故を防ぎます。

### 経路統一

SourceVault をロードすると、以下が自動的に設定されます。

```
$SourceVaultRoots["PrivateVault"]    自動初期化 (PrivateVault ディレクトリの作成)
SourceVault_promptrouter.wl          同ディレクトリにあれば自動ロード
NBAccess semantic API                7 API が利用可能
SourceVaultIndexNotebook mtime cache 透過的 cache (ForceReindex -> True で無効化)
iNotebookHeaderParse の Source       MakeExpression 第一選択 (副作用回避)
```

`SourceVault.wl` をロードすると、同じディレクトリにある `SourceVault_promptrouter.wl` (PromptRouter 拡張) も自動的に読み込まれます。同様に `ClaudeOrchestrator.wl` をロードすると `ClaudeOrchestrator_promptworkflow.wl` (PromptWorkflow 拡張) が自動ロードされます。いずれも本体のロードを壊さないよう `Quiet @ Check` で保護されています。

加えてロード時に、依存関係のあるパッケージ (NBAccess / claudecode / ClaudeRuntime) が読み込まれているかを `Quiet @ Needs[]` + `Names[]` チェックで確認し、不足機能はグレースフルに `Missing["PackageNotAvailable"]` を返します。

### 予算管理とポリシー

LLM 呼び出しを伴う API (`SourceVaultExtract` / `SourceVaultNotebookSummary` 等) は ClaudeRuntime の `ClaudeRetryPolicy` プロファイルに従って動作します。`MaxTotalSteps` / `MaxProposalIterations` / `MaxTransportRetries` などで上限を管理し、予算切れは `BudgetExhausted` イベントとして記録されます。

### 安全設計の不変条件

設計仕様書 (SourceVault PromptRouter 統合仕様書、および NBAccess / claudecode / ClaudeRuntime 向けプライバシー・アクセス制御仕様) に基づき、以下の不変条件が維持されます。

- raw bytes と parsed pages はローカル PrivateVault にのみ保存され、外部 LLM へはサニタイズ済み snippet のみ渡されます。
- Notebook の Header 取り出しは **whitelist** (String / Integer / Bool / Missing / DateObject / List of String / Association) を通過したものだけが採用され、`RunProcess` / `Get` / `Import` / `URLRead` を含む式は `UnsafeExpression` で拒否されます。
- Notebook ファイルへの書き込みは NBAccess の AccessLevel >= 0.7 が必須で、デフォルトは DryRun = True です。
- claim 抽出は NBAccess の 2 段階 authorization を経由し、`Permit` / `Screen` でのみ続行します。
- PromptRouter が `ClaudeEval` に返す提案式は、head が ReadOnly callable allowlist にあるものだけが `ReleaseHold` され評価されます。allowlist 外の head を持つ式は評価されません。`FilterSpec` の述語は閉じた DSL に限定され、任意コードを含み得ません。

### 永続化レイアウト

すべての永続化は `<PrivateVault>` 配下に集約されます。

```
<PrivateVault>/
  raw/by-hash/sha256-<hash>            (raw bytes、deduplicated)
  meta/sources/<sourceId>.json         (source レコード)
  meta/snapshots/<snapshotId>.json     (snapshot レコード)
  parsed/by-snap/<snapshotId>/pages/<NNNN>.txt
  parsed/by-snap/<snapshotId>/page-hashes.json   (snapshot diff 基盤)
  claims/claims.jsonl                  (master、append-only)
  claims/by-topic/<topic>.jsonl
  claims/by-source/<sourceId>.jsonl
  bundles/bundle-<safeName>-<ts>-<rnd>.json
  events/source-events.jsonl           (lifecycle events)
  seeds/<topic>-seed.json              (registry bootstrap)
  compiled/public/<topic>.json         (registry production)
  compiled/private/<topic>.json        (registry user override)
  notebooks/sources/nb-src-<hash16>.json
  notebooks/snapshots/snap-sha256-<hash>.json
  notebooks/todos/by-notebook/nb-src-<...>.jsonl
  notebooks/review/overdue.jsonl
  notebooks/lint/notebook-lint.jsonl
  promptrouter/runs/prompt-runs.jsonl  (PromptRun ストア、append-only)
  promptrouter/artifacts/wf-code/      (WorkflowRoute コード artifact)
```

---

## 詳細説明

### 動作環境

| 項目 | 要件 |
|------|------|
| Mathematica | 13.2 以降（14.x 推奨） |
| OS | Windows 11（64-bit） |
| Anthropic API キー | 任意（LLM 要約・claim 抽出機能を使う場合のみ） |

**依存パッケージ（先にインストールが必要）:**

- [NBAccess](https://github.com/transreal/NBAccess) — ノートブックアクセス制御・semantic API
- [claudecode](https://github.com/transreal/claudecode) — LLMGraph DAG スケジューラ・`$Path` 自動設定

**オプションパッケージ:**

- [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime) — LLM 要約・claim 抽出機能を `ClaudeEval` 経由で実行する場合に必要。SourceVault 単体では index・extract（deterministic 経路）・lint・FindNotebooks クエリなど LLM を使わない機能のみ動作します。
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) — 複数 notebook の一括処理を agentic に並列実行する場合に追加でロード。SourceVault の NBAccess hook (P1〜P4) で ClaudeAttach / Attachments / WorkerPrompt / ParseProposal にフックできます。また `ClaudeEval` から PromptRoute / WorkflowRoute へ自動 dispatch する機能は、原則として ClaudeOrchestrator がロード済みのときに有効になります。
- [github](https://github.com/transreal/github) — パッケージのインストール・更新を簡略化します（`setup.md` 参照）。

### インストール

`github` パッケージがインストール済みの場合は、`GitHubInstallPackage` でリポジトリから直接インストールできます。手動配置の手順とあわせて `setup.md` を参照してください。

#### 1. パッケージファイルの配置

`SourceVault.wl` を `$packageDirectory` 直下に配置します。PromptRouter 拡張 `SourceVault_promptrouter.wl` も同じディレクトリに置きます。

```
$packageDirectory\
  SourceVault.wl                 ← 本体
  SourceVault_promptrouter.wl    ← PromptRouter 拡張 (本体ロード時に自動ロード)
  NBAccess.wl
  claudecode.wl
  ...
```

サブフォルダには配置しないでください。

#### 2. `$Path` の設定

claudecode を使用している場合、`$Path` は自動的に設定されます。手動で設定する場合は以下のとおりです。

```mathematica
(* 正しい例: $packageDirectory 自体を追加する *)
If[!MemberQ[$Path, $packageDirectory],
  AppendTo[$Path, $packageDirectory]
]
```

```mathematica
(* 誤った例: サブディレクトリを指定しない *)
(* NG: AppendTo[$Path, "C:\\path\\to\\SourceVault"] *)
```

#### 3. パッケージのロード

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",    "NBAccess.wl"];
  Needs["SourceVault`", "SourceVault.wl"]
]
```

`SourceVault.wl` のロード時に、同ディレクトリの `SourceVault_promptrouter.wl` (PromptRouter 拡張) が自動的にロードされます。

LLM 要約・claim 抽出機能を使用する場合は、ClaudeRuntime もロードします。

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",      "NBAccess.wl"];
  Needs["ClaudeRuntime`", "ClaudeRuntime.wl"];
  Needs["SourceVault`",   "SourceVault.wl"]
]
```

`ClaudeEval` から PromptRoute / WorkflowRoute へ自動 dispatch する機能を使う場合は、ClaudeOrchestrator もロードします。`ClaudeOrchestrator.wl` のロード時に `ClaudeOrchestrator_promptworkflow.wl` (PromptWorkflow 拡張) が自動的にロードされます。

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",            "NBAccess.wl"];
  Needs["ClaudeRuntime`",       "ClaudeRuntime.wl"];
  Needs["ClaudeOrchestrator`",  "ClaudeOrchestrator.wl"];
  Needs["SourceVault`",         "SourceVault.wl"]
]
```

#### 4. API キーの設定

```mathematica
(* claudecode が提供するキー設定関数で登録する *)
ClaudeSetAPIKey["sk-ant-..."]
```

キーはノートブックにハードコードしないでください。詳細は [claudecode](https://github.com/transreal/claudecode) の `api-key-handling` ドキュメントを参照してください。

### クイックスタート

以下はテキストファイルを ingest して context を抽出する最小構成の例です。

```mathematica
(* 1. パッケージのロード *)
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",    "NBAccess.wl"];
  Needs["SourceVault`", "SourceVault.wl"]
]

(* 2. テキストファイルを準備 *)
testPath = FileNameJoin[{$TemporaryDirectory, "memo.txt"}];
Export[testPath,
  "斜方投射の最高到達点は v0^2 / (2g) で与えられる。" <>
  "射程は v0^2 sin(2θ) / g である。", "Text"];

(* 3. ingest *)
r = SourceVaultIngest[testPath];
sid = r["SnapshotId"]
(* "snap-sha256-..." *)

(* 4. context 抽出 *)
SourceVaultContext[sid, {1, 200}]

(* 5. snapshot 情報の確認 *)
SourceVaultStatus[sid]

(* 6. source の一覧 *)
Dataset[SourceVaultListSources[]]
```

**Notebook の場合:**

```mathematica
nbPath = "C:\\path\\to\\your\\notebook.nb";

(* index (deterministic、LLM 不要) *)
r = SourceVaultIndexNotebook[nbPath]

(* Header / Todo を semantic API 経由で読む *)
NBReadHeader[nbPath]
NBReadTodos[nbPath]

(* Todo の状態を変更 (DryRun = True なのでファイル変更なし) *)
SourceVaultMarkTodo[nbPath, 1, "Done"]

(* 実行 (atomic write) *)
SourceVaultMarkTodo[nbPath, 1, "Done", "DryRun" -> False]
```

**スケジュールの問い合わせ（PromptRouter）:**

ClaudeOrchestrator をロードしておくと、`ClaudeEval` のスケジュール系プロンプトが PromptRouter 経由で deterministic に処理されます。

```mathematica
(* 3 日間のスケジュール: SourceVaultUpcomingSchedule の装飾付き Grid が返る *)
ClaudeEval["今日から3日間のスケジュールを"]

(* 絞り込み付き: FilterSpec で OpenTodoCount > 0 のものだけ *)
ClaudeEval["7日間のスケジュールのうちTodoが残っているものを"]
```

**LLM 要約（ClaudeRuntime 必須）:**

```mathematica
SourceVaultNotebookSummary[nbPath]
```

### 主な機能

| 関数 / 変数 | 説明 |
|------------|------|
| `SourceVaultIngest[path, opts]` | テキスト / PDF / URL / arXiv ID を ingest し、source レコード + snapshot を生成。重複検知あり。 |
| `SourceVaultStatus[snapshotId]` | snapshot のメタ情報（hash / lifecycle / page count 等）を返す。 |
| `SourceVaultSpan[snapshotId, range]` | snapshot 内の span を構築。後続の context 抽出の単位。 |
| `SourceVaultContext[snapshotId, range]` | snapshot から抜粋テキストを取得。 |
| `SourceVaultContextAssemble[spans]` | 複数 span を 1 つの context に結合。 |
| `SourceVaultExtract[snapshotId, schema, opts]` | LLM (ClaudeRuntime 経由) で構造化 claim を抽出。2 段階 authorization 経由。 |
| `SourceVaultBundleCreate[name, claims, opts]` | Evidence Bundle を作成。snapshot/claim 依存を記録。 |
| `SourceVaultMarkSnapshotStale[snapshotId]` | snapshot を Stale 化し、依存 bundle の自動再評価を促す。 |
| `SourceVaultIndexNotebook[path, opts]` | notebook を index。Header / Todo / Snapshot / Lint を一括で生成。mtime ベース cache あり。 |
| `SourceVaultExtractNotebookHeader[path]` | Header Association を whitelist 経由で safe parse。`Source` フィールドで取得経路を明示。 |
| `SourceVaultExtractNotebookTodos[path]` | TodoItem cell を 3 値判定 (Open/Done/Pass) で抽出。 |
| `SourceVaultMarkTodo[path, target, newStatus, opts]` | Todo の Status を変更（NBAccess `NBWriteTodoStatus` への薄いラッパー）。DryRun デフォルト。 |
| `SourceVaultUpcomingSchedule[opts]` | 期限・レビュー予定の表を生成。`FilterSpec` / `Period` / `OpenTodos` / `DateField` / `OutputFormat` オプション対応。 |
| `SourceVaultNotebookSummary[path, opts]` | LLM で notebook の要約を生成。ClaudeRuntime 必須。 |
| `SourceVaultFindNotebooks[opts]` | deterministic クエリ（OpenTodos / NextReview / Deadline / Keywords / Status）。 |
| `SourceVaultNotebookLint[record \| path]` | 7 種 lint (HeaderStatusTodoButNoOpenTodos / DeadlinePast / NextReviewPast / TodoCellStatusHeuristicOnly 等) を検出。 |
| `SourceVaultProposePromptRoute[prompt, opts]` | `ClaudeEval` 接続用。プロンプトを未評価の提案式 `HoldComplete[...]` に解決し、`PromptRouteProposal` 連想で返す。式は評価しない。 |
| `SourceVaultExecutePromptRoute[prompt, opts]` | PromptRoute の手動 / テスト / 診断用 API。route を解決し、診断 `Association` を返す。 |
| `SourceVaultLookup[topic, key]` | Compiled Registry から値を取得。 |
| `SourceVaultResolve[topic, intent]` | Compiled Registry + Seed fallback で最適な値を返す。Availability / Freshness / Class 優先順位。 |
| `SourceVaultListModels[provider]` | 指定 provider の選択可能な全モデル ID を列挙（Compiled Registry 優先、Seed fallback）。`SourceVaultResolve` が intent 単位で 1 件を返すのに対し、カタログ全体を返す。 |
| `SourceVaultRefreshModelRegistry[opts]` | クラウド (anthropic/openai)・ローカル (LM Studio)・ChatGPT Codex CLI のエンドポイントからモデル一覧を取得し Compiled Model Registry を更新。`Providers` オプションで対象を限定。 |
| `ClaudeResolveModel[provider, intent]` | `SourceVaultResolve["Model", ...]` の互換 wrapper。provider と intent から具体的なモデルを解決。 |
| `SourceVaultClaimStoreCompact[]` | claim JSONL を dedup + 圧縮。 |
| `$SourceVaultVersion` | パッケージバージョン文字列。 |
| `$SourceVaultRoots` | PrivateVault のルートパス（Association）。 |

### ドキュメント一覧

| ファイル | 内容 |
|---------|------|
| `setup.md` | インストール手順・トラブルシューティング |
| `user_manual.md` | カテゴリ別ユーザーマニュアル（Notebook Management・PromptRouter・Evidence Bundle・Compiled Registry を含む） |
| `example.md` | 代表的な使用パターン集 |
| `design/` | SourceVault 仕様書・PromptRouter 統合仕様書・物理ストレージレイアウト |

---

## 使用例・デモ

### Source の ingest と context 抽出

`SourceVaultIngest` は、テキスト / PDF / URL / arXiv ID などを 1 つの first-class source として登録する関数です。重複は内容ハッシュ単位で自動的に検知されます。

#### `$SourceVaultRoots` の確認

SourceVault をロードすると `$SourceVaultRoots["PrivateVault"]` が自動初期化されます。

```mathematica
<< SourceVault`
$SourceVaultRoots["PrivateVault"]
```

PrivateVault のパスを変更する場合は手動で設定します。

```mathematica
$SourceVaultRoots = <|"PrivateVault" -> "D:\\my-vault"|>;
Needs["SourceVault`", "SourceVault.wl"]
```

#### 例 1 — URL から ingest

```mathematica
r = SourceVaultIngest["https://arxiv.org/abs/2401.12345"];
r["SnapshotId"]
```

公式 URL の場合、`iCanonicalizeURL` が `https://arxiv.org/abs/<id>` 形式に正規化し、`arXiv:<id>` の shorthand とも同一視されます。

#### 例 2 — arXiv ID で ingest（shorthand）

```mathematica
SourceVaultIngest["arXiv:2401.12345"]
(* 既存と内容が同じなら "AlreadyCurrent" が返る *)
```

#### 例 3 — context 抽出と複数 span の結合

```mathematica
spans = {
  SourceVaultSpan[sid1, {1, 500}],
  SourceVaultSpan[sid2, {200, 800}]
};
SourceVaultContextAssemble[spans]
```

### Notebook Management

Mathematica notebook を first-class source として扱う機能群です。

#### 例 4 — Notebook の index（deterministic、LLM 不要）

```mathematica
nbPath = "C:\\Users\\me\\Documents\\research.nb";
r = SourceVaultIndexNotebook[nbPath]
(* → <|"Status" -> "OK",
       "NotebookRef" -> "nb-src-...",
       "SnapshotId" -> "snap-sha256-...",
       "Cached" -> False,
       "SourceMTime" -> 1779243606,
       "Header" -> <|..., "Source" -> "MakeExpression"|>,
       "TodoCount" -> 5,
       "OpenTodoCount" -> 2,
       "DoneTodoCount" -> 2,
       "PassTodoCount" -> 1,
       "ReviewState" -> "Current",
       "DeadlineState" -> "Future",
       "Lint" -> {...}|> *)
```

2 回目以降は mtime ベース cache で高速になります。

```mathematica
r2 = SourceVaultIndexNotebook[nbPath];
r2["Cached"]
(* True (ファイル未変更) *)
```

#### 例 5 — Todo の状態を変更（DryRun → 実行）

`SourceVaultMarkTodo` は NBAccess の `NBWriteTodoStatus` への薄いラッパーで、Cell options + TaggingRules を同時に更新します。

```mathematica
(* DryRun = True (default) で Before / After をプレビュー *)
SourceVaultMarkTodo[nbPath, 1, "Done"]
(* → <|"Status" -> "DryRunOK",
       "OldStatus" -> "Open", "NewStatus" -> "Done",
       "Before" -> HoldComplete[Cell[..., 
                     FontVariations -> {"StrikeThrough" -> False}, ...]],
       "After"  -> HoldComplete[Cell[..., 
                     FontVariations -> {"StrikeThrough" -> True}, ...]], ...|> *)

(* 実行 *)
SourceVaultMarkTodo[nbPath, 1, "Done", "DryRun" -> False]
(* → atomic write 発生、AutoReindex で SourceVaultIndexNotebook が自動呼び出し *)
```

target は Integer (Index) / String (TodoId) / Association を受け付けます。

```mathematica
(* Association で Index + Text 両方一致を要求（最安全） *)
SourceVaultMarkTodo[nbPath,
  <|"Index" -> 1, "Text" -> "参加登録"|>, "Done"]
```

### Notebook Management — Header の 3 経路 fallback

`NBReadHeader` は Header を 3 つの経路で探索します。

```mathematica
h = NBReadHeader[nbPath];
h["Source"]
(* "TaggingRules" / "HeaderCell" / "BoxData" / "None" *)
```

| Source | 取得経路 |
|---|---|
| `"TaggingRules"` | Notebook 全体の `TaggingRules -> <\|"SourceVault" -> <\|...\|>\|>` |
| `"HeaderCell"` | 個別 Cell の TaggingRules（Header フィルタを通過したもの） |
| `"BoxData"` | Input cell の BoxData を `MakeExpression` で Association 化（whitelist なし） |
| `"None"` | どれにも該当せず |

Header フィルタ (`iNBIsHeaderLikeAssoc`) は Keywords / Status / Deadline / NextReview / Owner / PathHint / Title のいずれかを含む Association のみ Header と認め、TodoItem cell の `<|"TodoStatus" -> "Done"|>` のような Todo metadata を誤認しません。

### スケジュールの問い合わせ（PromptRouter / TabularQuery）

`ClaudeEval` のスケジュール系プロンプトは、PromptRouter が `SourceVaultUpcomingSchedule` の呼び出し式に変換します。`ClaudeEval` の出力は内部診断 `Association` ではなく、`SourceVaultUpcomingSchedule` 本来の装飾付き Grid です。

```mathematica
(* 単純な期間指定: Period オプションに変換される *)
ClaudeEval["今日から3日間のスケジュールを"]
(* → SourceVaultUpcomingSchedule["Period" -> Quantity[3,"Days"], ...] の評価結果 *)

(* 絞り込み付き: FilterSpec オプションに変換される *)
ClaudeEval["7日間のスケジュールのうちTodoが残っているものを"]
(* → "FilterSpec" -> <|"Kind" -> "Field",
       "Field" -> "OpenTodoCount", "Op" -> "Greater", "Value" -> 0|> *)
```

`SourceVaultUpcomingSchedule` を直接呼ぶこともできます。`FilterSpec` には閉じた DSL の構造化述語を渡します。

```mathematica
(* Todo が残っていて、かつ NextReview がある notebook だけ *)
SourceVaultUpcomingSchedule[
  "Period" -> Quantity[14, "Days"],
  "FilterSpec" -> <|
    "Kind" -> "And",
    "Clauses" -> {
      <|"Kind" -> "Field", "Field" -> "OpenTodoCount",
        "Op" -> "Greater", "Value" -> 0|>,
      <|"Kind" -> "Field", "Field" -> "NextReview",
        "Op" -> "NonEmpty"|>
    }
  |>]

(* 生レコードの List が欲しい場合 *)
SourceVaultUpcomingSchedule[
  "Period" -> Quantity[7, "Days"],
  "OutputFormat" -> "Records"]
```

PromptRouter の提案式そのものを確認したい場合は `SourceVaultProposePromptRoute` を使います。

```mathematica
p = SourceVaultProposePromptRoute["今日から3日間のスケジュールを"];
p["Status"]
(* "Proposed" *)
p["ProposedExpression"]
(* HoldComplete[SourceVaultUpcomingSchedule["Scope" -> $onWork,
     "Period" -> Quantity[3, "Days"], ...]] *)
```

### LLM 要約（ClaudeRuntime 経由）

```mathematica
(* ClaudeRuntime をロードしておく *)
SourceVaultNotebookSummary[nbPath]
(* → <|"Status" -> "OK", "Summary" -> "...", 
       "Source" -> "LLM", "Model" -> {"claudecode", ...}|> *)
```

`Source: "Cached"` が返る場合は前回の要約が `SemanticHash` と一致しており、LLM を再呼び出ししていないことを意味します。

### snapshot lifecycle と Evidence Bundle

```mathematica
(* snapshot を stale 化 *)
SourceVaultMarkSnapshotStale[sid]

(* 依存している bundle はその場では変更されないが、
   bundle status を取得すると "Stale" になる (lazy passive consumer) *)
SourceVaultBundleStatus[bundleId]
(* → "Stale" *)

(* 手動 invalidate *)
SourceVaultInvalidateBundle[bundleId, "Reason" -> "outdated"]
```

### 全 source / snapshot の一覧

```mathematica
Dataset[SourceVaultListSources[]]
Dataset[SourceVaultListSnapshots[]]
```

**出力例（Dataset）:**

| SourceId | Type | Title | CurrentSnapshotId | Status |
|---|---|---|---|---|
| src-... | URL | "Quantum Computing Review" | snap-sha256-... | Current |
| nb-src-... | Notebook | "research.nb" | snap-sha256-... | Current |
| src-... | arXiv:2401.12345 | "..." | snap-sha256-... | Stale |

### Notebook lint と FindNotebooks

```mathematica
(* lint 検出 *)
SourceVaultNotebookLint[nbPath]
(* → {"DeadlinePast", "TodoCellStatusHeuristicOnly", ...} *)

(* 期限切れ Todo を含む notebook を一覧 *)
SourceVaultFindNotebooks["DeadlineState" -> "Overdue"]

(* 特定キーワードを持つ notebook *)
SourceVaultFindNotebooks["Keywords" -> "オンライン語り交流会"]
```

### リポジトリ

- [SourceVault](https://github.com/transreal/SourceVault)
- [NBAccess](https://github.com/transreal/NBAccess)
- [claudecode](https://github.com/transreal/claudecode)
- [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime)
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)
- [ClaudeTestKit](https://github.com/transreal/ClaudeTestKit)
- [github](https://github.com/transreal/github)

---

## 免責事項

本ソフトウェアは "as is"（現状有姿）で提供されており、明示・黙示を問わずいかなる保証もありません。
本ソフトウェアの使用または使用不能から生じるいかなる損害についても責任を負いません。
今後の動作保証のための更新が行われるとは限りません。
本ソフトウェアとドキュメントはほぼすべてが生成AIによって生成されたものです。
Windows 11上での実行を想定しており、MacOS, LinuxのMathematicaでの動作検証は一切していません(生成AIの処理で対応可能と想定されます)。

---

## ライセンス

```
MIT License

Copyright (c) 2026 Katsunobu Imai

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
