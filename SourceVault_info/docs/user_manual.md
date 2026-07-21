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

arXiv source の場合、タイトル・著者 (Authors)・出版日 (published) は **arXiv API (export.arxiv.org) から自動的に一括取得され、meta にキャッシュ**されます。`SourceVaultSummaries` でこれらを横断表示するときに `FetchMetadata -> Automatic` で未取得分のみ補完取得されます。

### Source ID と Snapshot ID

すべての source は 2 種類の識別子を持ちます。

| 種類 | 形式 | 役割 |
|---|---|---|
| `sourceId` | `src-<hash16>` / `nb-src-<hash16>` 等 | source の **同一性** (path や URL でユニーク) |
| `snapshotId` | `snap-sha256-<hash64>` | **特定時点のバイト列** (content hash でユニーク) |
| Immutable `snapshotId` | `snapshot:class:hex` / `sv://snapshot/...` | **content-addressed 不変スナップショット** (WebDocument / WebSearchRun / SimulationRun 等) |

```
src-<hash16>                          ← Source ID (path / URL に対して安定)
  ├── snap-sha256-aaaa...             ← Snapshot ID (v1、内容が変わるとここが変わる)
  ├── snap-sha256-bbbb...             ← Snapshot ID (v2、refresh で新版)
  └── snap-sha256-cccc...             ← Snapshot ID (v3、最新)
                                          ↑
                                        CurrentSnapshotId
```

source レコードは `meta/sources/<sourceId>.json` に、snapshot レコードは `meta/snapshots/<snapshotId>.json` に deterministic な JSON で保存されます。

> **Immutable snapshot の識別:** `snapshot:` プレフィックスまたは `sv://snapshot/` スキームで始まる snapshotId は content-addressed 不変スナップショットです。WebDocument や WebSearchRun、SimulationRun など、Web ingest やシミュレーション実行結果として保存されるオブジェクトがこの形式を使います。不変スナップショットは本体ファイルを書き換えないため、PrivacyLevel 等の可変メタはサイドレコードに委譲されます。`SourceVaultImmutableSnapshotExistsQ[snapshotId]` で存在確認ができます。

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

- **deterministic 経路** (LLM 不要): ingest / Index / extract (deterministic schema) / Lint / FindNotebooks / PromptRouter のスケジュール提案 / シミュレーション実行の記録・参照
- **LLM 経路** (ClaudeRuntime 必須): `SourceVaultExtract` (LLM schema) / `SourceVaultNotebookSummary`

#### ロード時に有効になる機能

SourceVault をロードすると、以下が自動的に有効になります。

| 機能 | 内容 |
|---|---|
| コアサブファイルの自動ロード | `SourceVault_core.wl` / `SourceVault_contracts.wl` / `SourceVault_wiring.wl` / `SourceVault_simrun.wl` / `SourceVault_searchindex.wl` / `SourceVault_searchview.wl` / `SourceVault_servicemanager.wl` / `SourceVault_webingest.wl` / `SourceVault_mcp.wl` / `SourceVault_llmlog.wl` / `SourceVault_mailstructure.wl` / `SourceVault_mailsuggest.wl` / `SourceVault_workflowregistry.wl` / `SourceVault_knowledgehome.wl` / `SourceVault_cognition.wl` / `SourceVault_adjudication.wl` / `SourceVault_capbroker.wl` / `SourceVault_taint.wl` / `SourceVault_anomaly.wl` / `SourceVault_routine.wl` / `SourceVault_routineplan.wl` / `SourceVault_mailagenda.wl` を依存順に自動ロード |
| Cane 認知支援基盤 (既定 observe-only) | `SourceVault_knowledgehome.wl` (Knowledge Home 閲覧・非破壊追記・位置づけ/近傍提案) / `SourceVault_cognition.wl` (認知系イベントの暗号化保存・Guard shadow・owner 入力支援) / `SourceVault_adjudication.wl` (複数 LLM 裁定コア + runnable driver) / `SourceVault_capbroker.wl` (capability broker・LLM boundary shadow/gate・観測設定の永続化) / `SourceVault_taint.wl` (入力信頼度評価・taint 伝播) / `SourceVault_anomaly.wl` (統計的異常検知、既定オフ)。いずれも既定は「判定を記録するだけ」(shadow/observe-only) で、明示的な owner 操作なしに送信をブロックしたり通知したりしない (詳細は後述の「Boundary Observation」コールアウトを参照) |
| シミュレーション実行基盤 | `SourceVault_simrun.wl` がマシンプロファイル共有・GPU/CUDA サポート・サブカーネル burst 管理・SimulationRun 記録 (実行フォルダ + immutable snapshot の 2 層設計) を提供 (詳細は「シミュレーション実行基盤」節を参照) |
| Claude Code セッションログ ingest | `SourceVault_llmlog.wl` が Claude Code のセッションログ (実行ログ) をソースとして取り込む機能を提供。`GitHubCommitLog` (コミット履歴) とは別種別として扱われる |
| 自動トリガスケジューラの自動起動 | Front End のメインカーネルでロードされたときに限り、`SourceVault_autotrigger.wl` のスケジューラを冪等に自動起動する (詳細は後述) |
| PromptRouter 拡張の自動ロード | 同ディレクトリの `SourceVault_promptrouter.wl`（暗号・身元・メール群を含む）を自動ロード |
| ワークフローレジストリの自動ロード | `SourceVault_workflowregistry.wl` を自動ロード（コード化ワークフローのオンデマンドローダ。`SourceVault_workflows/` 配下を解決） |
| sv:// オブジェクト解決 | `sv://` の実データ/プロパティ取得は `SourceVault_mcp.wl`、privacy 継承付きセル出力は `SourceVault_eagle.wl` に統合（旧 `SourceVault_objectview.wl` は廃止） |
| NBAccess semantic API | `NBReadHeader` / `NBReadTodos` / `NBFindCellByPredicate` + 書き込み系 4 個 |
| `SourceVaultIndexNotebook` mtime cache | 透過的キャッシュ (`"Cached"` / `"SourceMTime"` 戻り値、`"ForceReindex" -> True` で無効化) |
| Header parser MakeExpression 第一選択 | InitializationCell の副作用を回避 |
| Header フィルタ | TodoItem cell の TaggingRules を Header と誤認しない |

> **自動トリガスケジューラの自動起動:** SourceVault をロードすると、実行環境が Front End のメインカーネル (`$FrontEnd =!= Null`) の場合に限り `SourceVaultAutoTriggerStartScheduler[]` が自動的に呼ばれます。これは「他 PC から『このマシンでこのワークフローを実行して』と依頼されたジョブを、このマシンが常に拾えるようにする」ためのものです。SourceVault.wl はサブカーネル・wolframscript の外部ジョブ・SourceVault サービスカーネル・MCP ゲートウェイカーネルなど、多くのプロセスからロードされますが、スケジューラは **1 マシンにつき 1 箇所 (対話的 FE) だけ**で起動するようガードされています。すべてのカーネルで無条件に起動すると、Wolfram ライセンスの同時カーネル席を浪費し、ジョブが多重ディスパッチされてしまいます。起動は冪等 (`StartScheduler` は同じ tick 登録を再登録するだけ) で、結果は `SourceVault\`Private\`$iSVAutoTriggerSchedulerAutoStartResult` に記録されます (同一カーネルセッション内では 1 回のみ実行)。FE-less の計算ノード (例: rapterlake4t) はこのガードの対象外で、代わりにサービス側の HEADLESS DISPATCH モード (`SourceVaultEnableHeadlessDispatch` によるマシン単位オプトイン) を使います。なお、スケジューラの起動箇所そのものを 1 台 1 箇所に絞るこのガードとは別に、ワークフローカタログの実際の起動 (dispatch) は複数プロセスから並行して呼ばれ得るため、内部の `SourceVaultAutoTriggerDispatchCatalogRuns` が per-slot の atomic dispatch claim によって同一ジョブの二重実行を防いでいます。
>
> オプトアウトしたい場合は、ロード前に次を設定します。
>
> ```mathematica
> SourceVault`Private`$iSVDisableAutoTriggerScheduler = True;
> Needs["SourceVault`", "SourceVault.wl"]
> ```
>
> 自動起動の結果は次のいずれかになります。
>
> ```mathematica
> <|"Status" -> "Skipped", "Reason" -> "DisabledByUser"|>          (* opt-out 済み *)
> <|"Status" -> "Skipped", "Reason" -> "NotFrontEndKernel"|>        (* $FrontEnd === Null (headless) *)
> <|"Status" -> "Skipped", "Reason" -> "AutoTriggerUnavailable"|>   (* SourceVault_autotrigger.wl 未ロード *)
> <|"Status" -> "Failed", "Reason" -> "AutoStartException"|>        (* 起動中に例外 *)
> ```
>
> 成功時は `SourceVaultAutoTriggerStartScheduler[]` 自体の戻り値 (`Association`) がそのまま入ります。スケジューラは claudecode の共有 polling tick に相乗りします。その base がまだロードされていない場合、`StartScheduler` は `ClaudeCodeAbsent` を返す安価な no-op となり (この結果も記録され)、次回の SourceVault (再) ロード時に base が揃った段階で起動します。

> **Boundary Observation (Cane 観測基盤) の永続設定:** SourceVault には、LLM 呼び出し境界の通過を記録する「LLM boundary shadow」と、`ClaudeEval` への入力を観測する「1G owner-input shadow recorder」という 2 つの **observe-only** (判定を記録するだけで、送信のブロックも通知もしない) モニタリング機構があります。既定はどちらも無効 (opt-in) です。owner が次を 1 回実行すると、設定はこのマシンのローカル状態 (`<LocalState>/capbroker/config/observation.json`) に永続化され、以後は **SourceVault ロードのたびに全カーネル (FE / service / headless) で自動的に適用**されます (`SourceVault.wl` ロード末尾の `SourceVaultApplyBoundaryObservation[]` 呼び出しによる)。
>
> ```mathematica
> SourceVaultSetBoundaryObservation[<|"Shadow" -> True, "OwnerInputShadow" -> True|>]
> ```
>
> - `"Shadow" -> True`: 全 18 箇所の LLM 呼び出し口 (直接 HTTP / claudecode 委譲 / injectable seam) で `LLMBoundaryShadowRecorded` イベントを記録します。内容は最小化され、プロンプト本文や token/MAC は記録されず、digest・provider・model・文字数のみが残ります。
> - `"OwnerInputShadow" -> True`: `ClaudeEval` への入力を `SourceVaultAssistOwnerInput` (決定的、LLM 不使用) で評価し `OwnerInputShadowRecorded` イベントを記録します。プロンプト本文は記録されません。`ClaudeCode\`ClaudeEval` 自体は無改変のまま常に元の引数で呼び出されるため、既存の課金・対話ホットパスへの影響はありません。
> - 現在の永続設定と実際にセッションへ適用されている状態は `SourceVaultBoundaryObservationConfig[]` (`"Config"` / `"Live"` を返す) で確認できます。
> - 内部的には `SourceVaultApplyBoundaryObservation[]` が永続設定をセッションへ適用します (owner が直接呼ぶ必要は通常ありません)。設定が一度も行われていないマシンでは `<|"Status" -> "NoConfig"|>` を返し、挙動を一切変更しません。
> - `SourceVault_capbroker.wl` が未ロード (旧バージョンとの混在など) の場合は fail-open で `<|"Status" -> "Skipped", "Reason" -> "CapBrokerUnavailable"|>` を返し、通常の SourceVault ロードは継続します。
> - **enforce (実ブロック) はここでは永続化されません**: `$SourceVaultLLMBoundaryMode` / `$SourceVaultLLMBoundaryEnforceList` はセッション内で owner が明示的に設定した場合のみ有効です (改ざん耐性のある trusted config が必要なため)。Enforce が有効な入口では、内部共有 LLM 呼び出し (`SourceVaultNotebookSummary` の要約生成や arXiv アブストラクト翻訳が経由する共有ハブ等) が `<|"Status" -> "Failed", "Reason" -> "LLMBoundaryRefused"|>` を返すことがあります。
>
> 記録された統計は `SourceVaultLLMBoundaryShadowStats[]` / `SourceVaultOwnerInputShadowStats[]` で確認できます。

> **メモ:** 書き込み系 API (NBWriteTodoStatus / SourceVaultMarkTodo) はデフォルト `DryRun -> True` です。実際にファイルを変更する場合は明示的に `"DryRun" -> False` を渡してください。atomic write (tmp + Rename) で保護されており、書き込み途中での中断にも耐性があります。

> **`$CharacterEncoding` の固定:** SourceVault はサブファイルのロード時に `$CharacterEncoding` を `"UTF-8"` に固定します。これにより、日本語リテラルを含むソースが正しくロードされます。`Get["SourceVault.wl"]` を `Block[{$CharacterEncoding = "UTF-8"}, ...]` で囲む慣用はこの仕組みと一致します。

> **テキストファイルの文字コード検出:** テキストファイルの ingest 時は、バイト列を UTF-8 として解析し、末尾の不完全なマルチバイトシーケンス (1〜3 バイト) を削って再試行し、それでも失敗する場合は Latin-1 にフォールバックします。これにより、非 ASCII 文字を含むファイルを幅広くサポートします。

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

`iCanonicalizeURL` が `https://arxiv.org/abs/2401.12345` に正規化するので、URL 形式と同一視されます。arXiv source は `Authors` フィールド (著者リスト) も meta にキャッシュされます。

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

### 非同期 ingest の完了待ち

`SourceVaultIngest[..., Asynchronous -> True]` は `LLMGraphDAGCreate` 経由でジョブをジョブキューに投入し、`JobId` を即時 return します。この非同期 ingest の完了を同期的に待ちたい場合は `SourceVaultIngestWait` を使います。

```mathematica
r = SourceVaultIngest["https://arxiv.org/abs/2401.12345", Asynchronous -> True];
SourceVaultIngestWait[r, 90]   (* 最大 90 秒待つ *)
```

- 第一引数は `SourceVaultIngest` の結果 `Association`、または `SourceId` の文字列です。
- すでに同期完了済み (`Status` が `"Ingested"` / `"AlreadyCurrent"` / `"RebuiltMetadata"`) の結果を渡すと、そのまま即座に return します。
- `Status` が `"Queued"` の場合は、その `SourceId` の snapshot 増加を polling し、新規 snapshot が出現したら完了とみなします。
- 第二引数のタイムアウト秒 (既定 60) を超過すると `Status -> "Timeout"` を返します。

### Claude Code セッションログの ingest

Claude Code の実行ログ (セッションログ) を `SourceVault_llmlog.wl` 経由でソースとして取り込むことができます。取り込まれたログは provider `"claudecode_sessions"` として扱われ、`SourceVaultSummaries` の横断検索に相乗りします。`GitHubCommitLog` (コミット履歴) や GitHub リポジトリ検索とは明確に区別される別種別のソースです。

```mathematica
SourceVaultIngestClaudeCodeLogs[]
```

> 補助 API ドキュメント (`api_llmlog.md`) は、タスクに「Claude Code」「実行ログ」「セッションログ」「作業ログ」等のキーワードが含まれるときのみ注入されます。単独の「ログ」だけではトリガーにならないよう意図的に外されています (over-match 防止)。詳細は「補助 API の条件付き注入」節を参照してください。

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
- **注意**: `<|...|>` の中にキーの無い裸の値 (例: `<|"Keywords" -> {...}, DateObject[{2025,11,12}], "Status" -> "Todo"|>` のように `Rule` になっていない要素) を混ぜないでください。これは復元時に不正な Association (`AssociationQ` が `False`) になります。SourceVault はこのようなヘッダも壊れないよう自動的にサニタイズして扱いますが (後述「mtime ベース cache」参照)、意図した Keywords/Deadline/NextReview/Status がすべて読み取れるとは限りません。

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

(* キーワードを指定して NotebookStatus の Keywords を上書き *)
SourceVaultNewNotebook["Title" -> "輪読メモ", "Keywords" -> {"論文読み", "輪読会"}]

(* キャプチャセッションへの逆リンクを埋め込む *)
SourceVaultNewNotebook["SessionID" -> "session-abc123"]
```

| オプション | 既定 | 説明 |
|---|---|---|
| `"TemplatePath"` | `Automatic` | テンプレート `.nb`。既定は `$packageDirectory/Templates/SourceVault notebook template.nb` |
| `"Title"` | `Automatic` | ウィンドウタイトル。既定は `"新規ノート"` |
| `"Date"` | `Automatic` | Deadline / NextReview に入れる日付。既定は今日 |
| `"Keywords"` | `Automatic` | NotebookStatus の `Keywords` フィールドを置換する文字列またはリスト。`Automatic` はテンプレートの値（例: `{"template"}`）をそのまま維持する |
| `"SessionID"` | `Automatic` | NotebookStatus に capture session への逆リンク（SessionID）を埋め込む文字列。`Automatic` は何も追加しない |

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

mtime が一致しても、内容が偶然入れ替わっている可能性を除外するため `SourceSize` (ファイルバイト数) または `RawContentHash` の一致もあわせて確認します。`SourceSize` を持つ新しい形式の snapshot では、キャッシュヒット時に `FileByteCount` だけの軽量な比較で済ませ、ファイル内容の再ハッシュ (`Import[path,"Text"]` + `Hash`。Dropbox 上では ~255ms/ファイルかかる) を省略します。`RawContentHash` しか持たない旧形式の snapshot では、従来どおりハッシュ照合にフォールバックします。

キャッシュから復元した Header (`HeaderCompressed`) が壊れている場合も自動的に扱われます。例えば `NotebookStatus` セルにキーの無い裸値を混ぜて書いてしまった場合 (`<|"Keywords" -> {...}, DateObject[{2025,11,12}], "Status" -> "Todo"|>` のように `Rule` になっていない要素があると、復元した式は `Head` こそ `Association` でも `AssociationQ` が `False` になる不正な値になります)、正しい `Rule`/`RuleDelayed` だけを残した安全な Association に自動整形してから返します。**この場合も再 index はしません**(壊れたデータをそのまま再生成して snapshot を毎回書き直す churn を避けるため)。圧縮フィールド自体が存在しない旧形式の snapshot に対しては、一度だけ `SourceVaultIndexNotebook[path, "ForceReindex" -> True]` を内部的に実行し、その結果を圧縮 Header/Todos 付きの最新形式へアップグレードしてから返します（以降の呼び出しはこの高速パスに乗ります）。

サイズ超過でスキップされた snapshot (`"Skipped" -> True`、または `snapshotId` が `snap-toolarge-*`) は Header/Todos を保持しないため復元できず、`"Header" -> <|"ParseStatus" -> "SkippedTooLarge"|>`・`"Todos" -> {}` のまま cache 済みとして返します。以前はこのケースでも mtime/size が一致するたびに `ForceReindex -> True` を実行し、同じスキップ状態の snapshot を毎回書き直していましたが、現在は一度だけ最新形式にアップグレードすれば以降は書き直されません。

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

### 補助 API の条件付き注入 ($ClaudePackageAuxKeywordMap)

Claude Code は `ClaudeCode\`$ClaudePackageAuxKeywordMap` を参照して、タスクの内容に応じて補助 API ドキュメントを選択的に注入します。SourceVault は以下のポリシーで動作します。

- **メール系 API (`api_maildb.md`)**: タスクに `"メール"` / `"mail"` / `"univ"` / `"受信"` / `"inbox"` / `"IMAP"` / `"返信"` / `"reply"` / `"差出人"` / `"宛先"` / `"件名"` のいずれかが含まれる場合のみ注入されます。メール無関係のタスクで 25KB 級の `api_maildb.md` が無条件注入されるのを防ぎます。
- **arXiv / 論文 / 横断検索系**: `"論文"` / `"arxiv"` / `"arXiv"` / `"横断検索"` などのキーワードが含まれる場合に SourceVault API が注入されます。
- **Claude Code セッションログ系 API (`api_llmlog.md`)**: タスクに `"Claude Code"` / `"ClaudeCode"` / `"実行ログ"` / `"セッションログ"` / `"作業ログ"` / `"過去のセッション"` / `"svcclog"` / `"SourceVaultClaudeCode"` / `"llmlog"` のいずれかが含まれる場合のみ注入されます。単独の `"ログ"` だけでは over-match するためトリガーに含めていません。`GitHubCommitLog` (コミット履歴) や GitHub リポジトリ検索と混同しないよう、別ドキュメントとして分離されています。
- **コア・暗号・PromptRouter 系**: 登録済みでない補助 API (core / crypto / promptrouter 等) は従来どおり常時注入されます。

> このキーワードマップは pkg レベルのメール系キーワードを包含するトリガー集合を使用しており、従来メール経路で注入されていたケースはすべて維持されます。

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
SourceVaultParseProposalIntegrationEnable[]                (* P4 *)
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

## SourceVault ワークフロー (コード化ワークフロー)

SourceVault は、`ClaudeOrchestrator\`Workflow\``（multi-token Petri net エンジン）と SourceVault の snapshot/pointer 版管理の上に組まれた **コード化ワークフロー** を `SourceVault_workflows/` 配下に収納し、**オンデマンドでロード**する仕組みを備えます。ワークフローは普段はロードされず、PromptRouter のルートやパレットなどから必要時にだけ読み込まれます。

> ワークフローは `ClaudeOrchestrator\`Workflow\`` と SourceVault を *利用するアプリ* です。ClaudeOrchestrator エンジン本体には統合しません（エンジンが SourceVault や外部 CLI へ依存逆転するのを避けるため）。

### 2 つの利用モード

| モード | 内容 |
|---|---|
| **(1) SourceVault 内 DB** | ワークフロー定義を `sv://` スナップショットで版管理し、PromptRouter のルートにリンクして起動する（主にオーナーが自分の環境で使う段階）。 |
| **(2) コード化 (.wl)** | 「枯れてきた」ワークフローを `.wl` パッケージに固め、他ユーザへ配布できる形にする。`SourceVault_workflows/<slug>/` に収納すると SourceVault コミットに同梱される。 |

### 収納構造

コード化ワークフローは「ミニパッケージ」として入れ子に置きます（通常パッケージと同じ構造）。

```
SourceVault_workflows/
  spec-review/                                 ← システムワークフロー（ルート据え置き, stage="system"）
    SVWorkflow_SpecReview.wl                    ← 本体（起動関数を定義）
    palette_driver.wls                          ← 付随する driver 等
    SVWorkflow_SpecReview_info/docs/examples/   ← ドキュメント
  spec-impl/                                   ← システムワークフロー
  testing/<slug>/                              ← 生成・テスト中
  production/<slug>/                           ← 生成・運用中
```

- 各ワークフローは **独立した context** にロードされます（slug `spec-review` → 文脈 `SourceVaultWorkflow\`SpecReview\``）。private は通常の `Begin["\`Private\`"]` で隔離されるため、**同一セッションに複数のワークフローを同時ロードしてもシンボルが衝突しません**。slug の一意性はディスク上のフォルダ名で担保されます。
- 各ワークフローは規約として `WorkflowInfo[]`（`Slug` / `Name` / `Version` / `Context` / `Launch` / `Routes`）を公開します。
- **テスト中 / 運用中の分離**: 仕様実装で生成されたワークフローは `testing/<slug>/`（新規は必ずここ）と `production/<slug>/`（テスト OK で昇格）に分けて格納します。システムワークフロー（`spec-review` / `spec-impl`）はルート直下のまま分類対象外です。slug は root / testing / production を通じて一意。stage 切替・束ねオブジェクト・横断検索・一覧 UI は [`api_workflowcatalog.md`](api_workflowcatalog.md) を参照。

### オンデマンド・ロード API

`SourceVault.wl` をロードすると、レジストリ（`SourceVault_workflowregistry.wl`）が自動的にロードされ、以下の公開関数が使えます。

| 関数 | 役割 |
|---|---|
| `SourceVaultWorkflowDirectory[]` | 収納ルート `<packageRoot>/SourceVault_workflows` を返す |
| `SourceVaultWorkflows[]` | 収納済みワークフローの一覧（`Slug` / `Stage` / `Path` / `MainFile` / `Context` / `Loaded`） |
| `SourceVaultWorkflowContext[slug]` | slug を正規化した context 文字列を返す（`"spec-review"` → `"SourceVaultWorkflow\`SpecReview\`"`） |
| `SourceVaultWorkflowFolder[slug]` | slug の実フォルダを root / testing / production を横断解決して返す |
| `SourceVaultLoadWorkflow[slug]` | 当該ワークフロー本体 `.wl` をオンデマンド Get（冪等。既ロードは `AlreadyLoaded` でスキップ。stage 移動も透過） |
| `SourceVaultWorkflowStatus[slug]` / `SourceVaultPromoteWorkflow` / `SourceVaultDemoteWorkflow` | stage の取得・運用/テストへの切替（フォルダ移動）。詳細は [`api_workflowcatalog.md`](api_workflowcatalog.md) |
| `SourceVaultWorkflowCatalog[]` / `SourceVaultWorkflowPanel[]` | 束ねオブジェクト一覧 / 起動・切替・検索 UI（claudecode パレットの「ワークフロー一覧」ボタンからも） |

```mathematica
(* 収納済みワークフローを一覧 *)
SourceVault`SourceVaultWorkflows[]
(* → {<|"Slug" -> "spec-review", "Context" -> "SourceVaultWorkflow`SpecReview`",
        "MainFile" -> "...SVWorkflow_SpecReview.wl", "Loaded" -> False|>} *)

(* 必要時にオンデマンドロード（依存 ClaudeOrchestrator`Workflow` は本体が自己ブートストラップ） *)
SourceVault`SourceVaultLoadWorkflow["spec-review"]
(* → <|"Status" -> "Loaded", "Slug" -> "spec-review",
       "Context" -> "SourceVaultWorkflow`SpecReview`", "Path" -> "...SVWorkflow_SpecReview.wl"|> *)

(* ワークフローのメタデータ（起動関数名・ルート定義） *)
SourceVaultWorkflow`SpecReview`WorkflowInfo[]
```

### 同梱されるワークフロー: spec-review

`spec-review` は **Codex↔Claude の仕様レビュー・改訂ループ**（旧 `OrchWorkflow`）です。context は `SourceVaultWorkflow\`SpecReview\``、起動関数は `RunSpecReview` / `BuildNet`。

```mathematica
SourceVault`SourceVaultLoadWorkflow["spec-review"];

SourceVaultWorkflow`SpecReview`RunSpecReview["myproject",
  "DraftPrompt" -> "Write a small Wolfram Language design spec.",
  "MaxRounds" -> 3]
```

ループは Codex が spec を起草 → Claude がレビュー → Approved なら承認・NeedsRevision なら改訂して次ラウンド・上限到達で Failed、という流れです。各ラウンドの spec/review は SourceVault に不変スナップショット + version pointer + handoff イベントとして保存され、`orch/<project>/spec` と `orch/<project>/review` のポインタ鎖を作り、`sv://` URI で交換されます。承認済み spec は `.wl` パッケージへ codegen することもできます。詳しい実行例は [`docs/examples/workflow_spec_review_example.md`](examples/workflow_spec_review_example.md) を参照してください。

#### パレット「仕様生成」との接続

SourceVault と ClaudeOrchestrator が両方ロードされていると、パレットの「仕様生成」ボタンはこの spec-review ワークフローを**バックグラウンド wolframscript driver**（`SourceVault_workflows/spec-review/palette_driver.wls`）で実行し、結果（合意 spec と `sv://` 鎖）をノートブックへ追記します。FE カーネルは重いループを直接実行せず、driver が `SourceVaultLoadWorkflow["spec-review"]` でオンデマンドロードして走らせます（FE カーネルの `$Language` も driver へ引き継がれ、出力言語が揃います）。

### 新しいワークフローの追加手順

1. `SourceVault_workflows/<slug>/<Name>.wl` を作り、`BeginPackage["SourceVaultWorkflow\`<CanonicalSlug>\`", {"ClaudeOrchestrator\`Workflow\`", "SourceVault\`"}]` で起動関数を定義する。依存の解決基点（パッケージルート）は `$InputFileName` の親を辿るか `Global\`$packageDirectory` を使う。
2. `WorkflowInfo[]` を公開する（Slug / Launch / Routes など）。
3. 配布する場合、`SourceVault_info/upload_manifest.json` の `directories` に `SourceVault_workflows` が含まれていることを確認する（既定で含まれており、SourceVault コミット時に同梱されます）。

これだけで `SourceVaultLoadWorkflow["<slug>"]` から起動でき、PromptRouter のルートにリンクできます。なお、ワークフローが生成した通常ライブラリ（例: `RetryWithBackoff.wl`）は *ワークフローではない* ため `SourceVault_workflows/` 配下ではなく通常パッケージとして扱います。

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
- **秘匿度 (PrivacyLevel) 判定の正準ロジックは `SourceVault_privacy.wl` に集約**されています (詳細は後述の「ファイル構成」節を参照)。maildb はこれに弱結合しており、`SourceVault_privacy.wl` が未ロードの環境でも動作は継続しますが、その場合は秘匿度判定が旧来のテキスト走査 (キーワードベースの簡易判定) にフォールバックします。

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

>ローカル LLM は `ClaudeCode\`$ClaudePrivateModel` のモデル/URL を使います (未設定なら `/v1/models` から取得、既定 `127.0.0.1:1234`)。本文の復号が必要なので、実データでは `SystemCredential` backend のセッションで実行してください。

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

```mathematica
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

```mathematica
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

```mathematica
SourceVaultMailStoreLoad[];
SourceVaultIdentityBackfillFromMail[]
```

### identity 関連の UI

```mathematica
SourceVaultAddressBookView[]      (* 連絡先の整形表 *)
SourceVaultIdentityLinkUI[]       (* 未リンク識別子→実体 (新規作成/既存マージ) *)
SourceVaultEntityView[]           (* 実体一覧 + 各行に編集ボタン *)
SourceVaultEntityEditUI[1]        (* 実体1件の編集フォーム (オーナーは uid=1) *)
```

`SourceVaultEntityEditUI` では、表示名 / 種別 (Person/Organization/Bot/MailingList/Service) / 漢字・ローマ字・かな / 分類 / Group / Weight / 所属 (MemberOf) / 信頼状態 / プライマリメール / LLMプロフィール を編集できます。

> **i18n:** UI のラベルは `$Language` で日本語/英語に切り替わります (日本語環境なら日本語、それ以外は英語)。一方、スキーマ・コードのキーは英語固定です。

---

## ファイル構成 (暗号/メール機能)

SourceVault の暗号・メール機能は、本体 `SourceVault.wl` のローダが依存順に Get する **5 つのサブファイル**に集約されています。また、`Get["SourceVault.wl"]` 単体でのロード時には、コア機能 (`SourceVault_core.wl`)・契約定義 (`SourceVault_contracts.wl`)・ワイヤリング (`SourceVault_wiring.wl`)・検索インデックス (`SourceVault_searchindex.wl`)・検索ビュー (`SourceVault_searchview.wl`)・サービスマネージャ (`SourceVault_servicemanager.wl`) に加え、シミュレーション実行基盤・PromptRouter 拡張・Web ingest・MCP・Claude Code セッションログ・メール構造/提案のサブファイルが依存順に自動でロードされます。

| ファイル | 文脈 | 内容 |
|---|---|---|
| `NBAccess_crypto.wl` | `NBAccess\`` | 鍵隔離層 (KeyRef・credential backend)。別文脈なので分離維持 |
| `SourceVault_crypto.wl` | `SourceVault\`` | crypto + keys + keybundle + encryptedstore + release |
| `SourceVault_identity.wl` | `SourceVault\`` | addressbook + senderauth + identity + messagerelease |
| `SourceVault_privacy.wl` | `SourceVault\`` | privacy 判定の正準 exit (View/Core)。`SourceVault_maildb.wl` はこれに弱結合 |
| `SourceVault_maildb.wl` | `SourceVault\`` | maildb + imap + mailui |

> **SourceVault_privacy.wl (新規サブファイル):** メール本文や各種ノートの秘匿度 (PrivacyLevel) 判定を、View/Core 層に対する **正準な exit point** として切り出したモジュールです。公開関数は主に `SourceVaultPrivateView`（指定 record / note のプライバシー状態のビュー取得）と `SourceVaultNotePrivacyOf`（個別ノート・レコード単位の秘匿度判定コア）です。ロード順は `SourceVault_identity.wl` の後・`SourceVault_maildb.wl` の前で、`SourceVault_maildb.wl` はこれに **弱結合** しています — `SourceVault_privacy.wl` が (旧バージョンとの混在などで) 未ロードでも maildb 自体は動作を継続しますが、その場合の秘匿度判定は旧来のテキスト走査 (キーワードパターンによる簡易判定) にフォールバックし、`SourceVaultPrivateView` 経由の正準判定は使われません。

```
$packageDirectory\
  SourceVault.wl                   ← 本体 (ローダがサブファイルを Get)
  SourceVault_core.wl              ← コア機能 (自動ロード)
  SourceVault_contracts.wl         ← 契約・スキーマ定義 (自動ロード)
  SourceVault_wiring.wl            ← 依存ワイヤリング / 相互配線 (自動ロード)
  SourceVault_simrun.wl            ← シミュレーション実行基盤 (マシンプロファイル / GPU・CUDA / サブカーネル burst / SimulationRun 記録、自動ロード)
  SourceVault_searchindex.wl       ← 検索インデックス (自動ロード)
  SourceVault_searchview.wl        ← 検索ビュー / 横断検索の表示層 (自動ロード)
  SourceVault_servicemanager.wl    ← サービスマネージャ (自動ロード)
  SourceVault_promptrouter.wl      ← PromptRouter 拡張 (自動ロード)
  SourceVault_webingest.wl         ← Web 検索 / SearXNG / job 二層 / 参照イベント (自動ロード)
  SourceVault_mcp.wl               ← MCP tool schema・dispatch / sv:// オブジェクト解決 (自動ロード)
  SourceVault_llmlog.wl            ← Claude Code セッションログ ingest (自動ロード)
  SourceVault_mailstructure.wl     ← メール構造の正規化・解析 (自動ロード)
  SourceVault_mailsuggest.wl       ← メール返信文面などの提案機能 (自動ロード)
  SourceVault_workflowregistry.wl  ← コード化ワークフローのオンデマンドローダ (自動ロード)
  SourceVault_knowledgehome.wl     ← Cane Knowledge Home 閲覧・非破壊追記・位置づけ (自動ロード)
  SourceVault_cognition.wl         ← Cane 認知系イベントの暗号化保存・Guard shadow・owner 入力支援 (自動ロード)
  SourceVault_adjudication.wl      ← Cane 複数 LLM 裁定コア + runnable driver (自動ロード)
  SourceVault_capbroker.wl         ← Cane capability broker・LLM boundary shadow/gate・観測設定の永続化 (自動ロード)
  SourceVault_taint.wl             ← Cane 入力信頼度評価・taint 伝播 (自動ロード)
  SourceVault_anomaly.wl           ← Cane 統計的異常検知 (observe-only、既定オフ、自動ロード)
  SourceVault_routine.wl           ← Routine/obligation コア (deterministic、自動ロード)
  SourceVault_routineplan.wl       ← Routine/attention の計画層 (自動ロード)
  SourceVault_mailagenda.wl        ← メール由来のアジェンダ/議題項目管理 (自動ロード)
  SourceVault_eagle.wl             ← Eagle 連携 + privacy 継承付きセル出力 (旧 objectview を統合)
  NBAccess_crypto.wl               ← 鍵隔離 (NBAccess` 文脈)
  SourceVault_crypto.wl            ← 暗号 + 鍵 + 鍵バンドル + 暗号 record + release
  SourceVault_identity.wl          ← アドレス帳 + 送信者認証 + identity + release plan
  SourceVault_privacy.wl           ← privacy 判定の正準 exit (SourceVaultPrivateView / SourceVaultNotePrivacyOf)。maildb に弱結合
  SourceVault_maildb.wl            ← maildb adapter + IMAP + mail UI
  NBAccess.wl / claudecode.wl / ...
```

> 旧来の細分化ファイル (`SourceVault_keys.wl` / `_encryptedstore.wl` / `_addressbook.wl` / `_imap.wl` / `_mailui.wl` など) は上記 5 ファイルに統合済みです。`sv://` の実データ/プロパティ取得は `SourceVault_mcp.wl`、privacy 継承付きのセル出力は `SourceVault_eagle.wl` に統合され、旧 `SourceVault_objectview.wl` は廃止されました。詳細な関数シグネチャは API リファレンス (`api_crypto.md` / `api_identity.md` / `api_privacy.md` / `api_maildb.md` / `api_llmlog.md` / `api_knowledgehome.md` / `api_cognition.md` / `api_adjudication.md` / `api_capbroker.md` / `api_taint.md` / `api_anomaly.md`) を参照してください。

---

## Web 検索 / SearXNG / MCP ゲートウェイ

LM Studio などローカル LLM の Web 検索を、外部 API ではなく **ローカル SearXNG → SourceVault → MCP** ゲートウェイ経由にするサブシステムです。検索・本文取得が SourceVault に監査記録され、重要度・構造 Priority・クロスマシン集約・要約保存と連携します。セットアップ（SearXNG インストール、MCP 起動、LM Studio の `mcp.json`）は setup.md の「SearXNG + MCP Web 検索ゲートウェイのセットアップ」を参照してください。

### アーキテクチャ

```
LM Studio ──(remote MCP, /sv/mcp)──▶ Python HTTP/MCP proxy
                                          │ file command queue
                                          ▼
                              WL service kernel ── SourceVaultMCPDispatch
                                          │
   SourceVaultWebSearch ──▶ SearXNG (127.0.0.1:8888) ──▶ 結果正規化
                          └▶ 本文取得 (SourceVaultWebFetch) ─▶ WebDocument 不変 snapshot
   監査: WebSearchRun snapshot + 参照イベント (Searched/Ingested/...)
```

- `SourceVault_webingest.wl` — SearXNG クライアント / Web 検索 / 本文取得 / clean-text / job 二層 / 参照イベント / importance / 要約。
- `SourceVault_mcp.wl` — MCP tool schema・dispatch（protocol endpoint は Python proxy 側）。`sv://` オブジェクトの実データ/プロパティ解決もここに統合。
- `SourceVault_eagle.wl` — privacy 継承付きセル出力（WebDocument 等のオブジェクトビューを提供。旧 `SourceVault_objectview.wl` を統合）。
- いずれも **service-loadable**（FrontEnd / NBAccess 非依存）で、`SourceVault.wl` ロード時に自動読み込み。

### 検索

```mathematica
(* 生 SearXNG クライアント（記録しない・正規化のみ） *)
SourceVaultSearXNGSearch["query", "MaxResults" -> 10]

(* provenance + 監査記録つき検索（既定 StoreSearchRun -> True） *)
SourceVaultWebSearch["query"]
SourceVaultWebSearch["query", "FetchPages" -> True, "MaxFetch" -> 3]   (* 本文取得まで *)

(* 非同期（長時間 fetch をブロックしない。既定 $SourceVaultWebSearchAsync -> True） *)
job = SourceVaultWebSearchSubmit["query", "FetchPages" -> True];
SourceVaultWebJobStatus[job["JobId"]]
SourceVaultWebJobResult[job["JobId"]]                                 (* Ready -> True で Result *)
```

`SourceVaultWebSearch` は **WebSearchRun 不変 snapshot**（`<CoreRoot>/snapshots/WebSearchRun/`）と **"Searched" 参照イベント**を記録します。`FetchPages -> True` の各結果は `SourceVaultWebFetch` で本文取得され、**WebDocument 不変 snapshot** + **"Ingested" イベント** + 構造 Priority sidecar が作られます（非 2xx はスタブを成功保存せず `FetchFailed` 扱い）。

### 重要度と構造 Priority（mail 整合）

Web レコードは、mail の `Derived.Priority` に対応する **provenance ベースの構造的初期推定**（決定的・LLM 不要）と、参照イベントからの **使用ベース importance** の 2 面を持ちます。

```mathematica
(* ソースドメイン重み（mail のグループ重みに対応）。サブドメインは親を継承 *)
SourceVaultSetWebDomainWeight["nature.com", 0.9];
SourceVaultWebDomainWeights[]

(* 構造 Priority の決定的計算（ドメイン重み + 検索ランク + スコア + ユーザ明示 + 抽出品質） *)
SourceVaultWebComputePriority[provenance, doc]

(* recordId（snapshot Ref）の Priority sidecar / 使用 importance / 合成スコア *)
SourceVaultWebPriority[recordId]
SourceVaultRecordImportance[recordId]
SourceVaultWebImportance[recordId]            (* Priority + CurrentImportance → CombinedScore *)

(* 式・重みの変更を既取込レコードへ一括反映（LLM 不要） *)
SourceVaultWebRecomputePriorities[]
```

Priority は可変メタなので不変 snapshot には入れず、`<LocalState>/derived/web_priority/` の sidecar に置きます。

### 参照イベントのクロスマシン集約（rollup）

参照イベントは machine-local の LocalState に append されます。`SourceVaultRollupReferenceEvents[]` が未集約分を `<CoreRoot>/rollup/reference_events/<host>/`（Dropbox 同期）へ低頻度バッチで追記し、別マシンの履歴も importance に合算されます（EventId で dedup、二重計上なし）。サービス稼働中は `$SourceVaultRollupIntervalSeconds`（既定 6h）間隔で自動実行されます。

```mathematica
SourceVaultRollupReferenceEvents[]            (* 未集約分を CoreRoot へ集約（追記のみ） *)
SourceVaultReferenceEventStoreStatus[]        (* LocalTotal / UnrolledEvents / RollupByHost *)
SourceVaultPruneRolledReferenceEvents[]       (* 集約済みの古い shard を削除（既定 DryRun） *)
```

### 要約と DerivedArtifact

ローカル LLM（LM Studio）で検索結果・本文を要約し、provenance 付きの不変成果物として永続化できます（MCP 経路からは再入回避のため自動では呼びません）。

```mathematica
SourceVaultSummarizeText[text]
SourceVaultSummarizeResults[run, "query"]                       (* 検索結果一覧を要約 *)
SourceVaultSummarizeResults[run, "query", "Persist" -> True]    (* DerivedArtifact として保存 *)

SourceVaultDerivedArtifactList["ArtifactType" -> "Summary"]
SourceVaultDerivedArtifactsForSource[recordId]                  (* 逆引き：この source の要約 *)
```

`Persist -> True` は要約を `DerivedArtifact` 不変 snapshot に保存し、SourceRefs の各 source に **"Summarized" 参照イベント**を emit します（要約された source の importance が上がる）。

### MCP サーバの制御

```mathematica
SourceVaultStartMCP[]              (* WL service + /sv/mcp proxy を一括起動 *)
SourceVaultMCPStatus[]             (* <|Running, ServiceState, ProxyState, Port, Url|> *)
SourceVaultMCPRunningQ[]           (* True / False *)
SourceVaultStopMCP[]
```

`ShowClaudePalette[]`（claudecode）のプライバシー直下に **MCP 起動/停止トグル**が出ます（実状態に追従）。これは claudecode の package-neutral レジストリ `$ClaudePaletteServiceControls`（`ClaudeRegisterPaletteServiceControl`）に SourceVault が登録する形で、claudecode は SourceVault に依存しません。

MCP が公開するツール：`sourcevault_web_search`（同期）/ `sourcevault_submit_web_search`（非同期・本文取得可）/ `sourcevault_job_status` / `sourcevault_job_result` / `sourcevault_get_document`。いずれの検索も `RequestChannel="MCP"`・`Actor=MCPClient` として監査記録されます。

> 詳細な関数シグネチャ・オプションは API リファレンス（`api_servicemanager.md`）を、規約は Claude Directives の `rules/105-sourcevault-web-mcp.md` を参照してください。**`.wl` を更新したら稼働中サービスは `SourceVaultRestartService` で再起動**しないと反映されません。

#### 運用上の注意（2026-06 追記）

- **正規ポートは 8731。** 全クライアント（Claude Code / Codex / LM Studio）の登録 URL を 8731 に揃えます。`9700` は旧テスト serviceId の名残で、残っていると `ECONNREFUSED` になります。
- **パレットのボタン状態は「真のサービス健全性」で判定します。** `SourceVaultMCPRunningQ[]` は proxy ポートが listen しているかではなく `/health` の `healthState=="OK"`（背後の WL サービスカーネルが心拍中か）を見ます。これにより「proxy だけ生きてサービスカーネルが死んでいる」状態を「実行中」と誤表示せず、トグルが逆に Stop する事故を防ぎます。`SourceVaultMCPStatus[]` の `healthState` / `heartbeatAgeSeconds` で実態を確認できます。
- **サービスカーネルは Wolfram ライセンスの同時メインカーネル席を 1 つ使います。** FE ＋ 並列 subkernel ＋ ネイティブ Wolfram MCP（Claude Code がセッション毎に起動）＋ wolframscript ジョブで席が埋まると、detached サービスカーネルが `unregistered` で即死します（`/health` は proxy 生存で緑のままなので気づきにくい＝`stdout.log` 末尾の *"The product exited … unregistered"* で確定）。席を空けるには、ネイティブ Wolfram MCP を**単一共有カーネルの HTTP ゲートウェイ**に集約する、claudecode の前置並列カーネルを `$ClaudeParallelKernelCount` で減らす、余分な Claude Code セッションを閉じる、等。
- **同じ理由で、SourceVault_autotrigger のスケジューラも FE メインカーネル 1 箇所でしか起動しません。** 前述（「ロード時に有効になる機能」節）のとおり、SourceVault.wl はサブカーネル・wolframscript ジョブ・サービスカーネル・MCP ゲートウェイカーネルなど多数のプロセスからロードされるため、どのカーネルでもスケジューラを起動すると同じ理由でライセンス席とジョブディスパッチが多重化します。`$FrontEnd =!= Null` のカーネルだけが起動するようガードされています。FE-less の計算ノードはこのガードで除外され、代わりにサービス側の HEADLESS DISPATCH モードを使います。
- **再起動後に自動で MCP を上げたい場合**は、proxy / service の `launch_hidden.vbs` を Windows の Startup フォルダから起動するショートカットを置きます（手順は `setup.md` の「ログオン時の自動起動」）。`SourceVaultStartMCP[]` をパレットから押す手間が不要になります。
- **当座の復旧**（proxy は生きているがサービスカーネルが死んでいる時）は `SourceVaultStartMCP["RestartService" -> True]`、または service の `launch_hidden.vbs` を `wscript //B //Nologo` で直接起動します。

---

## シミュレーション実行基盤 (SourceVault_simrun)

`SourceVault_simrun.wl` は、高負荷な数値シミュレーションワークフローを支える基盤機能を提供する**自動ロード**サブファイルです。マシンスペックの実測・共有、GPU/CUDA サポート、サブカーネル burst 管理、および「SimulationRun」という単位でのシミュレーション実行記録の保存・参照を扱います。

設計の要点:

- **バルク出力**（大量データ・画像・動画・フレーム列）は vault に保存せず、Dropbox 同期フォルダ（`<Dropbox>/udb/simruns/...`）に直接書き込みます（参照ベース原則）。
- **メタデータ・パラメータ・ファイル一覧**などの小さな要約のみを、immutable snapshot（class `"SimulationRun"`）として vault に保存します。

### マシンプロファイル

各 PC の実測スペック（CPU コア数・メモリ・GPU 有無・nvcc パス等）を取得・共有します。

```mathematica
(* 現在のマシンの実測プロファイル (セッション内 memoize) *)
SourceVaultMachineProfile[]
(* → <|"MachineName"->..., "MachineTag"->..., "OS"->..., "ProcessorCount"->...,
       "MemoryGB"->..., "WolframVersion"->..., "GPUs"->{<|"Name","MemoryMB"|>...},
       "GPUAvailable"->..., "NvccAvailable"->..., "NvccPath"->...,
       "SubkernelTarget"->..., "ProbedAtUTC"->...|> *)

(* 再実測 *)
SourceVaultMachineProfile["Refresh" -> True]

(* 再実測して共有ストア <PrivateVault>/machines/<tag>.wl (Dropbox 同期) へ書き込む *)
SourceVaultMachineProfileRefresh[]

(* 共有ストアに記録された全マシンのプロファイル (現在のマシンは常に最新の実測で上書き) *)
SourceVaultMachineSpecs[]
(* → <|tag -> profile, ...|> *)

(* Dataset 表示版 *)
SourceVaultMachineSpecsView[]

(* 仕様生成プロンプトへの注入用の compact なテキスト表 *)
SourceVaultMachineSpecsText[]
```

各マシンで一度 `SourceVaultMachineProfileRefresh[]` を実行しておくと、以降は他マシンからも `SourceVaultMachineSpecs[]` で全マシンのスペックを参照できます。

### GPU / CUDA サポート

```mathematica
(* Nvidia GPU の有無 (nvidia-smi 実測、memoize) *)
SourceVaultGPUAvailableQ[]

(* nvcc 実行ファイルのパス (見つからなければ Missing["NotFound"]) *)
SourceVaultNvccPath[]

(* CUDA 実行の前提検査。ワークフロー冒頭で呼び、Failure ならそのまま return して graceful に停止する *)
SourceVaultCUDARequire[]
(* → <|"OK" -> True, "GPUs" -> {...}|> または
     Failure["NoNvidiaGPU", ...] (GPU を持つ既知マシン一覧を含む) *)

(* .cu を nvcc -O3 でコンパイル。出力はソース内容でキャッシュ (同一ソースは再利用) *)
SourceVaultCUDACompile["kernel.cu"]
SourceVaultCUDACompile["kernel.cu", "ExtraArgs" -> {"-arch=sm_86"}, "Force" -> True]
(* → 実行ファイルパス、または Failure["NvccUnavailable"|"CompileFailed", ...] *)
```

| オプション (`SourceVaultCUDACompile`) | 既定 | 説明 |
|---|---|---|
| `"ExtraArgs"` | `{}` | nvcc への追加引数 |
| `"Force"` | `False` | `True` でキャッシュを無視し再コンパイル |

出力先は `<LocalState>/cudabin/<name>-<srchash8>.exe` です（ソース内容のハッシュでキャッシュされ、同一ソースは再利用されます）。

### サブカーネル burst 管理

```mathematica
(* burst 時に目標とするサブカーネル数 (Min[$ProcessorCount, $SourceVaultSubkernelMax]) *)
SourceVaultSubkernelTarget[]

(* 使えるサブカーネルを全て起動して body を評価し、終了後は自分が起動した分だけ確実に停止する *)
SourceVaultWithSubkernels[
  ParallelTable[computeExpensiveStep[i], {i, 1, 1000}]
]

(* 目標基数を明示 *)
SourceVaultWithSubkernels[8,
  ParallelMap[f, data]
]
```

`SourceVaultWithSubkernels` の body 内では `ParallelMap` / `ParallelTable` / `DistributeDefinitions` / `ParallelEvaluate` がそのまま使えます（`HoldAll`）。既に起動済みのカーネルがあればそれも使いますが、終了時 (WithCleanup で保証) に停止するのは自分が起動した分だけです。

| 変数 | 既定 | 説明 |
|---|---|---|
| `$SourceVaultSubkernelMax` | `16` | サブカーネル burst の上限 (ライセンスの subkernel 席実測) |

### SimulationRun の記録

シミュレーション 1 回の実行を「SimulationRun」という単位で記録します。バルク出力は Dropbox 同期フォルダに直接書き、メタデータのみを immutable snapshot として vault に保存する 2 層設計です。

```mathematica
(* 実行フォルダを作成: <simrunroot>/<yyyymmddHHmm>-<machinetag>-<slug>/ *)
run = SourceVaultSimRunCreate["ising-sweep", <|"Beta" -> 0.5, "Steps" -> 10000|>];
run["Folder"]   (* このフォルダ配下にバルク出力を書く *)

(* ... シミュレーション実行、run["Folder"] にファイルを書き出す ... *)

(* 実行フォルダのファイル一覧を採取し、メタのみを immutable snapshot として保存 *)
result = SourceVaultSimRunFinalize[run,
  <|"Summary" -> <|"FinalEnergy" -> -123.4|>, "Status" -> "Done"|>];
result["URI"]   (* sv://snapshot/SimulationRun/<hex> *)

(* 記録済み SimulationRun を読む *)
SourceVaultSimRunRecord[result["URI"]]

(* 実行フォルダを現在のマシンの絶対パスへ解決 (Dropbox 未同期なら Missing["NotSynced", path]) *)
SourceVaultSimRunFolder[result["URI"]]

(* slug の実行履歴 (新しい順の URI リスト) *)
SourceVaultSimRuns["ising-sweep"]
```

| 関数 | 役割 |
|---|---|
| `SourceVaultSimRunCreate[slug, params]` | 実行フォルダを作成し run メタ (`RunId` / `Folder` / `Slug` / `Machine` / `Params` / `StartedAtUTC`) を返す |
| `SourceVaultSimRunFinalize[run, extra]` | ファイル一覧を採取して immutable snapshot 保存、pointer `simrun/<slug>/latest` を更新 |
| `SourceVaultSimRunRecord[uriOrRef]` | SimulationRun snapshot を読み Ref/URI 補完済み Association を返す |
| `SourceVaultSimRunFolder[uriOrRefOrRunId]` | 実行フォルダを現在のマシンの絶対パスへ解決 |
| `SourceVaultSimRuns[slug]` | slug の実行履歴 URI リスト (新しい順) |
| `SourceVaultSimRunRoot[]` | 解決済みの simrun root パス |

RunId の命名規則は `<yyyymmddHHmm>-<machinetag>-<slug>`（衝突時は `-<k>` 接尾辞を付与）です。

> **参照ベース原則:** `SourceVaultSimRunFinalize` の `extra` 引数には小さな要約のみを入れます。バルクデータ・画像・巨大リストを `extra` に入れてはいけません。実データは `run["Folder"]` 配下のファイルとして参照させ、vault には要約（`Status` / 集計値など）だけを保存します。

> **フォルダの位置付け:** `$SourceVaultSimRunRoot` の既定は `Automatic` で `<Dropbox>/udb/simruns`（PrivateVault の親 `udb` 直下）に解決されます。実行フォルダの記録は udb 相対パス（`FolderSymbolic`）で保存されるため、別マシン（Dropbox 同期先）でも `SourceVaultSimRunFolder` で絶対パスに解決できます（未同期の場合は `Missing["NotSynced", ...]`）。

---

続きの「カテゴリ別リファレンス」以降のセクション（関数リファレンス・機能マトリックス・診断コード例・関連パッケージ）は前回ドキュメントから変更がないため、既存内容をそのまま維持しています。以上でドキュメント全文の再掲を終わります。