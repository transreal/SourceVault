# SourceVault_autotrigger API リファレンス

SourceVault の自動トリガースケジューラ。登録済み TriggerSpec を定期評価し、条件を満たしたものだけをジョブとして構築・ディスパッチする。`SourceVault`` コンテキストの拡張であり、`Get[]` 単独ロード可能・冪等リロード。context `SourceVault``。

## 概要

処理は「評価 → ジョブ構築 → ディスパッチ」の3層に分離されている。
- 評価層 (`ScheduleMatch` / `ConditionMatch` / `DiagnosticsGate` / `EvaluateTrigger`) は純粋・副作用なし・IOなし。
- Tick 層 (`Tick`) はレジストリを読み、評価し、構築済みジョブを append-only ログ (`autotrigger/jobs.jsonl`) に追記し、per-trigger の `LastCheck` 状態を進める。ディスパッチ・実行はしない。
- ディスパッチ層 (`DispatchJobs` / `DispatchAsync` / `DispatchWorkflows`) が実際にサブカーネルまたは Orchestrator ワークフローで実行する。

設計上の要点:
- レジストリファイルは `<triggerId>.wxf`（spec 3.1 の `.wl` ではない）。`.wl` を `Get[]` すると任意コード実行になるため、`ToExpression` せず WXF をデシリアライズするだけで安全にする方針。WXF は `Missing[...]` / `Automatic` / `All` / `Quantity[...]` を無損失で保持する。
- スケジュール判定は spec 4.7 の区間オーバーラップ意味論: 半開区間 `(lastCheck, now]` に発火時刻が存在するか。全ての時刻成分抽出は明示的な TimeZone を使う（ヘッドレスのタイムゾーン罠回避）。
- 条件 DSL は READ-ONLY。`SourceVaultEvent` アトムは spec の EventType 語彙 (`Updated`/`Deleted`/…) を実際のログ語彙 (`VersionedUpdate`/`Retraction`/…) にマップする。
- 診断ゲートはコンポーネントスコープ + マシンローカルの doctor をフォールバックに用いる。
- 実行配置 `SpecificMachine` はバリデーション（`RequiredMachineTags` 必須）+ ジョブへのタグ記録 + マシン別ディスパッチゲートで強制される。`jobs.jsonl` は vault root 共有なので、各マシンのディスパッチャがローカルに実行可否を判断する。
- サブカーネルは `LaunchKernels`（subprocess pool, 16 枠）を使う。`wolframscript`/`wolfram` の `StartProcess` はこの環境で FE 依存 init によりハングするため使わない。
- 現段階で実際に実行されるのは無害な自己テストターゲット `TargetType "PureComputation"` のみ。実 PromptRoute / Workflow executor の一部は未配線。

## バージョン変数

### $SourceVaultAutoTriggerVersion
型: String, 初期値: "0.1-phase1.2"
自動トリガーサブシステムのバージョン。

## ステータス・レジストリ操作

### SourceVaultAutoTriggerStatus[] → Association
サブシステム状態（バージョン / レジストリディレクトリ / 登録トリガー数）を返す。Phase 1 レジストリ基盤のみ。

### SourceVaultNewAutoTriggerId[] → String
`"autotrg-XXXXXXXXXXXX"` 形式の新規トリガー ID を返す。

### SourceVaultValidateAutoTrigger[spec_Association] → Association
TriggerSpec を構造的にバリデーションする。必須キー / Type / TargetType / Owner.Mode / Schedule.Kind / ExecutionPlacement.Mode の enum / Enabled boolean を検査。`ExecutionPlacement` の Mode `"SpecificMachine"` は非空の `RequiredMachineTags` リストを追加で必須とする（spec 3.1）。既知マシン（このマシン + 診断マシンレジストリ）に無いタグは warning のみ。ライブなターゲット存在確認・URI 解決はしない（ディスパッチ時層に委譲）。
→ `<|"Valid" -> Bool, "Issues" -> {...}, "Warnings" -> {...}, "TriggerId" -> _|>`

### SourceVaultRegisterAutoTrigger[spec_Association, opts]
TriggerSpec をバリデーションし、`"DryRun" -> False` のときだけ `compiled/auto-triggers/<TriggerId>.wxf` へアトミックに書き込む。
→ ステータス Association
Options: "DryRun" -> True (デフォルトは検証 + 対象パス報告のみ、書き込まない)

### SourceVaultListAutoTriggers[opts] → List
登録トリガーのサマリ（TriggerId / Name / Enabled / TargetType / UpdatedAt）を per-trigger レジストリファイルから読んで返す。

### SourceVaultGetAutoTrigger[triggerId_String] → Association | Missing
格納済みの完全な TriggerSpec Association を返す。無ければ `Missing["NotFound"]`。

## スケジュール判定（純粋・副作用なし）

### SourceVaultAutoTriggerScheduleMatch[schedule_Association, lastCheck, now] → Association
spec 4.7 の区間オーバーラップ意味論を実装。半開区間 `(lastCheck, now]` に発火時刻が存在するかを返す。`lastCheck` / `now` は ISO 日付文字列・DateObject・AbsoluteTime いずれも可。Schedule Kind `"Alarm"` / `"CalendarPattern"`（Fields + N週 Interval）/ `"Timer"`（anchor 必要）をサポート。
→ `<|"Matched" -> Bool, "FireTimes" -> {ISO...}, "Capped" -> Bool, "Notes" -> {...}|>`

### SourceVaultAutoTriggerNextFire[schedule_Association, from, opts]
`from` より厳密に後の次回発火時刻（ISO 文字列）を、horizon まで前方探索して返す。プレビュー用・純粋。
→ ISO String | `Missing["NoFireWithinHorizon"]`
Options: "HorizonDays" -> 366 (探索 horizon 日数)

## 条件判定（READ-ONLY）

### SourceVaultAutoTriggerConditionMatch[condition_Association, context_Association] → Association
Condition DSL ノード（spec 5）を評価。Boolean ノード `AllOf` / `AnyOf` / `Not`（空 AllOf = True、空 AnyOf = False）とアトム。`SourceVaultEvent` アトムは `context["Events"]`（合成イベントリスト、テスト用）または不在時はライブの `SourceVaultSourceEvents[]` ログ（弱参照）に対して評価。spec の EventType 語彙を実ログ語彙へマップし、SourceId でフィルタ、`context["WatermarkEventId"]`（その EventId 以降に追記されたイベント）で窓を切る。他のアトム型（SourceVaultPredicate / OrchestratorEvent / ApprovalState / QueueState）と URI→SourceId 解決は未実装で `"Notes"` に報告。
→ `<|"Matched" -> Bool, "Notes" -> {...}|>`

## 診断ゲート（判定のみ・ディスパッチしない）

### SourceVaultAutoTriggerDiagnosticsGate[spec_Association, context_Association:<||>] → Association
診断ヘルス（spec 3.3）を踏まえトリガーがディスパッチ可能かを判定。コンポーネントスコープ: ワークフローが必要とするコンポーネントのみ検査（`DiagnosticsPolicy.RequiredComponents`、Automatic → デフォルトは TargetType 依存: PureComputation→{"SubprocessPool"}, PromptRoute→{"LicensePool"}, Workflow系→{}, その他→{"LicensePool"}）。`RequiredHealth "OK"` は全必須コンポーネント OK を要求、`"DegradedAccepted"` は Degraded も許すが Failing は不可。doctor は `context["Doctor"]`（テスト用）またはライブ `SourceVaultDiagnosticsLightweightDoctor`（弱参照・マシンローカル）。`RequireDiagnosticsReady -> False`、または exempt な system-doctor ワークフロー（CreatedBy `"System"` / `context["Exempt"] -> True`）はゲートをバイパス。
→ `<|"Allowed" -> Bool, "Reason" -> _, "RequiredComponents" -> {...}, "BlockingComponents" -> {...}, ...|>`

## トリガー評価（純粋・ディスパッチなし）

### SourceVaultAutoTriggerEvaluateTrigger[spec_Association, context_Association:<||>] → Association
per-trigger の全判定を順に合成: Enabled → Owner → Schedule (spec 4.7) → Condition (spec 5) → DiagnosticsGate (spec 3.3) → Placement。純粋・IOなし・ディスパッチなし。全通過時は構築済み（未実行の）ジョブレコードを後段の dedup 用 `DispatchSlotKey` 付きで返す。context は `"Now"` / `"LastCheck"` (ISO) / `"MachineTag"` / `"Events"` / `"Doctor"`（全て安全なデフォルト付き任意）を供給。最初に失敗したステージで短絡する。
→ `<|"WouldFire" -> Bool, "Stage" -> _, "Reason" -> _, "Job" -> _ (WouldFire 時), ...|>`

## Tick 層（レジストリ IO・ディスパッチなし）

### SourceVaultAutoTriggerTick[opts] → Association
レジストリの有効トリガーを読み、ライブ context（now / per-trigger LastCheck 状態 / ライブソースイベント / マシンローカル doctor）に対し `SourceVaultAutoTriggerEvaluateTrigger` で各々評価。全通過したものは構築済みジョブを append-only ジョブログ (`autotrigger/jobs.jsonl`) に追記し、per-trigger LastCheck 状態を進める。実行・ディスパッチはしない (`Dispatched -> False`)。同一 `DispatchSlotKey` は既存ログに対し dedup。ランタイムが AsyncActive のときは defer（no-op）。トリガー初回 tick は窓が空（状態が now にシード）で発火しない。back-window を評価するには `LastCheckOverride` を使う。
→ tick サマリ
Options: "DryRun" -> False (True で評価のみ・書き込まない), "LastCheckOverride" -> Automatic (ISO 文字列で全トリガーの評価窓下限を強制、テスト・手動キャッチアップ用)

### SourceVaultAutoTriggerJobQueue[opts] → List
append-only ジョブログ (`autotrigger/jobs.jsonl`) から構築済みジョブを返す。
Options: "Status" -> All (ジョブ Status でフィルタ、例 "Built")

## ディスパッチ層（同期サブカーネル実行）

### SourceVaultAutoTriggerDispatchJobs[opts] → Association
まだ完了していない構築済みジョブ（run ログに対し `DispatchSlotKey` で dedup）をディスパッチ。各々診断ゲートとサブプロセス枠予算を再チェックし、スロットを確保、ターゲットを時間制約下でサブカーネル（subprocess pool、決してメインカーネルでない）で実行、run を `autotrigger/runs.jsonl` に記録。この段階で実際に実行されるのは無害な自己テスト `TargetType "PureComputation"`（サブカーネルで有界純計算し、out-of-process 実行の証明にサブプロセス ID を返す）のみ。実 PromptRoute / Workflow executor は未配線で `"ExecutorNotWired"` として記録。LLM / Front End / network / 危険な副作用なし。配置ゲート: `ExecutionPlacement` が `"SpecificMachine"` のジョブは、タグが `RequiredMachineTags` にあるマシン（大小無視）のみで実行、他マシンはスキップ (`NotEligibleMachine`) し、必須マシンのディスパッチャ用に Built のまま残す。
→ ディスパッチサマリ
Options: "DryRun" -> False, "MaxJobs" -> 1 (呼び出しあたり上限), "TimeConstraintSeconds" -> 30

### SourceVaultAutoTriggerRunHistory[opts] → List
`autotrigger/runs.jsonl` の run レコードを返す。
Options: "Status" -> All (フィルタ、例 "Completed")

## 非同期ディスパッチ（永続クリーンサブカーネル）

### SourceVaultAutoTriggerDispatchAsync[opts] → Association
async 対象の構築済みジョブをメインカーネルをブロックせずにディスパッチ。各々永続クリーンサブカーネル（`ParallelSubmit`; subprocess pool）にサブミットし、バックグラウンド実行して結果ファイルを書く。呼び出しは即座に返る。ここで async 対象は `TargetType "PureComputation"` のみ（PromptRoute はメインカーネルゲート・手動のみ）。`RequiredMachineTags` がこのマシンを除外する SpecificMachine ジョブは拾わない。確定化には `SourceVaultAutoTriggerPoll` を使う。
Options: "MaxConcurrent" -> 1, "TimeConstraintSeconds" -> 120

### SourceVaultAutoTriggerPoll[] → Association
サブカーネルキューを進め、結果ファイルが出現した async ジョブを確定化（Completed/Failed を `runs.jsonl` に記録、サブカーネルを回収）。TimeConstraint 超過ジョブは TimedOut として記録。ノンブロッキング。共有ポーリング tick から呼ばれることを想定。

### SourceVaultAutoTriggerRunningJobs[] → List
現在飛行中の async ジョブ（slot / trigger / 経過秒 / 時間制約）を返す。

## スケジューラ（claudecode 共有ポーリング tick に相乗り・opt-in）

### SourceVaultAutoTriggerStartScheduler[opts] → Association
自動トリガースケジューラを claudecode の共有ポーリング基盤 (`ClaudeRegisterPollingTick`) に弱参照・OPT-IN で登録（ロード時には起動しない）。各発火（`IntervalSeconds` でスロットル）はノンブロッキングに Poll（終了 async ジョブ確定化）→ Tick（有効トリガー評価・ジョブ構築）→ DispatchAsync（async 対象をサブカーネルへ）を実行。メインカーネルゲートのターゲット (PromptRoute) はここで自動ディスパッチされない（手動のまま）。AsyncActive 中は defer。サブカーネルプールは tick がカーネル起動でブロックしないようここで事前起動。自前の ScheduledTask は作らない（rule 95）。
Options: "IntervalSeconds" -> 60

### SourceVaultAutoTriggerStopScheduler[] → Association
スケジューラを共有ポーリング基盤から登録解除する。

### SourceVaultAutoTriggerSchedulerStatus[] → Association
スケジューラが共有 tick に登録されているか、interval、直近スケジューラ tick サマリ、飛行中 async ジョブを報告する。

## ワークフロー実行（ClaudeOrchestrator 非ブロッキング）

### SourceVaultStartWorkflowForAutoTrigger[wid_String, metadata_Association] → Association
ClaudeOrchestrator への自動トリガーアダプタ。Orchestrator の可用性を弱チェックし、存在すれば `ClaudeRunWorkflow[wid, "Async"->True]` をキックオフ（ノンブロッキング・即座に返り、ワークフローは共有ポーリング tick で進む）。完了ブロックはしない。`SourceVaultAutoTriggerPoll` / `ClaudeAsyncJobInfo` でポーリングする。
→ `<|"Status", "WorkflowId", ...|>`

### SourceVaultStartWorkflowForAutoTrigger[spec_Association, metadata_Association] → Association
まず `ClaudeCreateWorkflowNet[spec]` でネットをインスタンス化してからキックオフする。

### SourceVaultAutoTriggerDispatchWorkflows[opts] → Association
Built な WorkflowRoute / WorkflowTemplate ジョブを `ClaudeRunWorkflow` Async 経由でノンブロッキングにキックオフ（メインカーネル、LicensePool ゲート）。FE 必須ターゲットは defer（tick から自動実行しない）。`RequiredMachineTags` がこのマシンを除外する SpecificMachine ジョブは拾わない。
Options: "MaxConcurrent" -> 1, "TimeConstraintSeconds" -> 600

### SourceVaultAutoTriggerRunningWorkflows[] → List
自動トリガーがキックオフしポーリング継続中のワークフロー run（wid / trigger / 経過）を返す。

## UI 層（spec 8 / 9）

### SourceVaultAutoTriggerCapability[spec_Association] → Association
トリガーのリスト表示分類を導出（spec 8）。`HeadlessAsync`（サブカーネル / workflow-async ターゲット）、`BlockingSyncUserInitiated`（メインカーネル PromptRoute）、`FrontendRequired`（FE 束縛ワークフロー）、`Unknown`（その他）。
→ `<|"AutoRunCapability", "ExecutionMode" (ラベル), "AutoEligible"|>`

### SourceVaultAutoTriggerListData[] → List
登録トリガーごとに UI 用の1行 Association を返す: TriggerId / Name / Enabled / ExecutionMode / Placement（実行PC ラベル: 環境非依存 | pool: <name> | 固定: <tags>）/ AutoRunCapability / AutoToggle (ON|OFF|不可) / Priority / NextFire / LastRunStatus / HasError / ErrorSummary（cloud-safe メタデータのみ）。純読み・ディスパッチなし。

### SourceVaultAutoTriggerPanel[] → Grid
登録トリガーを Grid でレンダリング（実行モード / 自動実行可否 / 自動トグル状態 / 色付き優先度バッジ / 次回発火 / 直近 run、直近 run 失敗トリガーには警告アイコン、クリックで保存済みメタデータのみのエラーサマリを開く）。`SourceVault_diagnostics` ロード時は上部に診断ステータスバンドを表示。

### SourceVaultAutoTriggerForTarget[targetType, targetId] → Association | Missing
Target が一致する登録トリガー（例: カタログ slug の WorkflowTemplate トリガー）の `SourceVaultAutoTriggerListData` 行を返す。無ければ `Missing["NoTrigger"]`。既存のワークフロー / 保存プロンプトリストが行ごとに自動実行ステータスを表示できるようにする。

### SourceVaultAutoTriggerStatusCell[targetType, targetId] → セル
そのターゲット上のトリガーのコンパクトセル（自動トグルバッジ + 優先度 + 警告アイコン）をレンダリング。未登録なら灰色のダッシュ。既存リスト Grid に差し込む用。

## リゾルバ・マシンタグ

### SourceVaultAutoTriggerSourceIdResolver
型: 設定可能フック（関数 uri -> SourceId String）, 初期値: Automatic
`SourceVaultEvent` 条件が canonical `sv://` URI をイベントログのキーである内部 SourceId に照合するために使う。デフォルト Automatic（組み込みリゾルバなし）。配線までは URI アトムはその URI を直接持つイベントのみに一致する。

### SourceVaultAutoTriggerSourcesURIResolver[uri_String] → String | Missing
canonical `sv://` URI を `SourceVaultSources` 経由で SourceId に解決する（opt-in; `SourceVaultAutoTriggerSourceIdResolver` に代入すると `SourceVaultEvent` 条件が URI で一致できる）。URI が見つからない / sources リストが利用不可のときは Missing。

### SourceVaultAutoTriggerKnownMachineTags[] → List
この vault が知るマシンタグ（このマシンのタグ + 診断マシンレジストリの全 MachineTag、弱参照・レジストリ無しならこのマシンのみ）を返す。SpecificMachine 配置バリデーション（未知タグ warning）と `SourceVaultParseAutoTriggerPrompt`（プロンプト内のマシン名検出）が使う。

## プロンプト → TriggerSpec 変換（spec 10）

### SourceVaultParseAutoTriggerPrompt[prompt_String, target_Association, opts] → Association
自然言語のトリガー要求（日本語 / 英語）を TriggerSpec に変換。決定論優先で一般形には LLM 不要: schedule（毎週/隔週/毎日/毎月/N時間ごと/ISO alarm/N時間後 timer、weekly/daily/every N hours）、`sv://` URI + 更新 → `SourceVaultEvent` Updated 条件、マシン配置（"<tag>で実行" / "run on <tag>" / プロンプト中の既知マシンタグ → ExecutionPlacement SpecificMachine + RequiredMachineTags）、優先度ワード、"1回だけ" → MaxRunsPerWindow 1/day。SCHEDULE が解析できず LLM フックが利用可能なとき（option `"LLMFunction" -> fn` または設定可能フック `SourceVaultAutoTriggerPromptLLM`）、LLM は欠けたスロットのみ埋める: 命令+プロンプト1 String を受け JSON オブジェクト（spec 10.2）を返す。これは RawJSON パース（決して ToExpression しない）+ キーホワイトリスト。元プロンプトは HashOnly で格納（プライバシーデフォルト）。返る spec は常に `Enabled -> False`（レビュー後に `SourceVaultRegisterAutoTrigger`）。
→ `<|"Status" -> "OK"|"NeedsClarification"|"Failed", "TriggerSpec" -> spec, "Explanation", "Questions", "Warnings", "Validation", "NextFirePreview"|>`
Options: "TimeZone" -> "Asia/Tokyo", "KnownMachineTags" -> Automatic, "LLMFunction" -> Automatic, "Now" -> Automatic (再現テスト用 ISO 文字列)

### SourceVaultAutoTriggerPromptLLM
型: 設定可能フック（関数 fullPrompt_String -> jsonString）, 初期値: Automatic
決定論層がスケジュールを解析できないとき `SourceVaultParseAutoTriggerPrompt` が使う。デフォルト Automatic（LLM なし・決定論解析のみ）。プライバシー: プロンプトはプライベートな `sv://` URI を含みうるため、cloud-safe と分かっている場合を除きローカルモデルへルートすること（spec 10.2）。

### SourceVaultAutoTriggerWorkflowResolver
型: 設定可能フック（関数 slug -> wid_String | spec_Association | $Failed）, 初期値: Automatic
WorkflowTemplate の TargetId を `ClaudeRunWorkflow` が実行できるものに解決する。デフォルトはカタログ検索（インライン実行可能 spec を試み、無ければ未解決）。

## 関連パッケージ

- [SourceVault_diagnostics](https://github.com/transreal/SourceVault_diagnostics) — 診断 doctor / マシンレジストリ（ゲート・既知タグに弱参照）
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) — ワークフロー実行 (`ClaudeRunWorkflow` / `ClaudeCreateWorkflowNet`)
- [claudecode](https://github.com/transreal/claudecode) — 共有ポーリング tick 基盤 (`ClaudeRegisterPollingTick`)
- [SourceVault_workflowcatalog](https://github.com/transreal/SourceVault_workflowcatalog) — WorkflowTemplate 解決のカタログ (`SourceVaultWorkflowCatalogRecord`)
- [SourceVault](https://github.com/transreal/SourceVault) — ソースイベントログ (`SourceVaultSourceEvents` / `SourceVaultSources`)