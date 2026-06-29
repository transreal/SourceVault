# SourceVault_autotrigger API リファレンス

GitHub: https://github.com/transreal/SourceVault_autotrigger

## 概要

`SourceVault_autotrigger` は `SourceVault`` コンテキストに属する自動トリガースケジューラだ。`Get[]` ロード可能・単独動作・副作用フリー設計（ルール 11 / 30 / spec 2.3）。`Needs["ClaudeRuntime`"]` / `["ClaudeOrchestrator`"]` への依存なし。

レジストリ形式は `compiled/auto-triggers/<id>.wxf`（WXF はデシリアライズのみで評価されない → tampered ファイルによる任意コード実行を防ぐ。WXF は `Missing[...]` / `Automatic` / `All` / `Quantity[...]` をロスレスで往復できる）。

**実装フェーズ構成**:
- Phase 1.1（現実装）: TriggerSpec バリデーション・レジストリ・スケジュール照合・条件照合・診断ゲート・per-trigger 評価・ティック・同期/非同期ディスパッチ・ワークフロー統合・スケジューラ・UI層

**TargetType と実行方式**:

TargetType | 実行方式 | AutoEligible
--- | --- | ---
`"PureComputation"` | サブカーネル非同期（SubprocessPool） | True
`"WorkflowRoute"` | メインカーネル非同期（ClaudeOrchestrator） | True（FE不要時）
`"WorkflowTemplate"` | テンプレート解決後 → 同上 | True（FE不要時）
`"PromptRoute"` | メインカーネル・手動起動のみ | False

**TriggerSpec 主要キー**: `TriggerId`(String), `Name`(String), `Enabled`(Bool), `Type`(String), `Owner`(Association), `Schedule`(Association), `Condition`(Association), `Target`(Association), `ExecutionPlacement`(Association), `DiagnosticsPolicy`(Association), `RunPolicy`(Association), `CreatedBy`(String)

## バージョン / 定数

### $SourceVaultAutoTriggerVersion
型: String, 初期値: `"0.1-phase1.1"`
パッケージバージョン文字列。

## レジストリ操作

### SourceVaultAutoTriggerStatus[] → Association
自動トリガーサブシステムのステータス（バージョン・レジストリディレクトリ・登録トリガー数）を返す。

### SourceVaultNewAutoTriggerId[] → String
`"autotrg-XXXXXXXXXXXX"` 形式の新規トリガーIDを生成して返す。

### SourceVaultValidateAutoTrigger[spec_Association] → Association
TriggerSpec を構造的にバリデートする（必須キー・Type / TargetType / Owner.Mode / Schedule.Kind / ExecutionPlacement.Mode 列挙値・Enabled 真偽値）。ライブターゲット存在確認・URI解決はディスパッチ時層に委ねる。
→ `<|"Valid" -> Bool, "Issues" -> {...}, "Warnings" -> {...}, "TriggerId" -> _|>`

### SourceVaultRegisterAutoTrigger[spec_Association, opts]
TriggerSpec をバリデートし、`"DryRun" -> False` のときのみ `compiled/auto-triggers/<TriggerId>.wxf` にアトミック書き込みする。
→ Association（ステータス）
Options: `"DryRun" -> True` (True のときバリデートと対象パス報告のみ・書き込みなし)

### SourceVaultListAutoTriggers[opts] → List
登録済みトリガーのサマリー（TriggerId / Name / Enabled / TargetType / UpdatedAt）を per-trigger レジストリファイルから読み取ってリストで返す。

### SourceVaultGetAutoTrigger[triggerId_String] → Association | Missing
指定 triggerId の完全な TriggerSpec Association を返す。存在しない場合は `Missing["NotFound"]`。

## スケジュール照合

純粋関数・副作用なし。spec 4 / 4.7 の半開区間オーバーラップ意味論を実装する。タイムゾーンはヘッドレス環境の罠を避けるため全コンポーネント抽出で明示する。

### SourceVaultAutoTriggerScheduleMatch[schedule_Association, lastCheck, now] → Association
`(lastCheck, now]` 半開区間内に発火時刻が存在するかを判定する。`lastCheck` / `now` は ISO日付文字列・DateObject・AbsoluteTime のいずれか。Schedule Kind `"Alarm"` / `"CalendarPattern"`（Fields + N週 Interval）/ `"Timer"`（アンカー必須）をサポートする。
→ `<|"Matched" -> Bool, "FireTimes" -> {ISO...}, "Capped" -> Bool, "Notes" -> {...}|>`

### SourceVaultAutoTriggerNextFire[schedule_Association, from, opts] → String | Missing
`from`（ISO文字列）より後の次回発火時刻を返す。ホライズン内に発火がなければ `Missing["NoFireWithinHorizon"]`。純粋関数・プレビュー用。
→ ISO String | Missing
Options: `"HorizonDays" -> 366` (前向き探索上限日数)

## 条件照合

読み取り専用。spec 5 の Condition DSL を評価する。

### SourceVaultAutoTriggerConditionMatch[condition_Association, context_Association] → Association
Condition DSL ノード（AllOf / AnyOf / Not ブール結合子 + アトム）を評価する。空の AllOf = True、空の AnyOf = False。`SourceVaultEvent` アトムは `context["Events"]`（テスト用合成イベントリスト）または不在時はライブ `SourceVaultSourceEvents[]` ログに対して評価する。spec の EventType 語彙（Updated/Deleted/...）を実際のログ語彙（VersionedUpdate/Retraction/...）にマップし SourceId でフィルタし `context["WatermarkEventId"]` でウィンドウする。他アトム型（SourceVaultPredicate / OrchestratorEvent / ApprovalState / QueueState）と URI→SourceId 解決は未実装（"Notes" に報告）。
→ `<|"Matched" -> Bool, "Notes" -> {...}|>`

context キー: `"Events"` (List, 省略時はライブログ), `"WatermarkEventId"` (String, 省略可・このEventId より後のイベントのみ照合)

EventType マッピング: `"Updated"/"Ingested"` → `{"VersionedUpdate"}`, `"Deleted"` → `{"SourceDeletion","Retraction"}`, `"Retracted"` → `{"Retraction"}`, `"MetadataChanged"` → `{"SchemaChange"}`, その他 → そのまま（前方互換）

例:
```
cond = <|"Combinator" -> "AllOf", "Children" -> {
  <|"Atom" -> "SourceVaultEvent", "SourceId" -> "src-001", "EventType" -> "Updated"|>}|>;
SourceVaultAutoTriggerConditionMatch[cond, <|"WatermarkEventId" -> "evt-42"|>]
```

## 診断ゲート

spec 3.3 に基づくディスパッチ許可判定。判定のみで実行しない。機械ローカル doctor を安全フォールバックとして使用（マルチPC集約は未接続）。

### SourceVaultAutoTriggerDiagnosticsGate[spec_Association, context_Association : <||>] → Association
トリガーがディスパッチしてよいかを診断健全性に基づいて判定する。コンポーネントスコープ（ワークフローが実際に必要とするコンポーネントのみ確認）。`RequiredHealth "OK"` は全コンポーネント OK を要求、`"DegradedAccepted"` は Degraded も許容するが Failing は拒否する。`context["Doctor"]`（テスト用 Association）またはライブ `SourceVaultDiagnosticsLightweightDoctor` を使用する。`RequireDiagnosticsReady -> False` またはシステムドクターワークフロー（`CreatedBy "System"` / `context["Exempt"] -> True`）はゲートをバイパスする。
→ `<|"Allowed" -> Bool, "Reason" -> _, "RequiredComponents" -> {...}, "BlockingComponents" -> {...}, "RequiredHealth" -> _, "DoctorGlobalHealth" -> _|>`

TargetType 別デフォルト RequiredComponents: `"PureComputation"` → `{"SubprocessPool"}`, `"PromptRoute"` → `{"LicensePool"}`, `"WorkflowTemplate"`/`"WorkflowRoute"` → `{}`（メインカーネル共有ポーリングで動作しプロセス/サブプロセスのスロットを消費しないため）, その他 → `{"LicensePool"}`

context キー: `"Doctor"` (Association, 省略時はライブ doctor), `"Exempt"` (Bool)

## per-trigger 評価

### SourceVaultAutoTriggerEvaluateTrigger[spec_Association, context_Association : <||>] → Association
spec 11.1 の完全な per-trigger 決定パイプラインを構成する（Enabled → Owner → Schedule → Condition → DiagnosticsGate → Placement）。純粋関数・IO なし・ディスパッチなし。全チェック通過時にジョブレコード（`Status "Built"`, `Dispatched False`）を構築して返す（実行しない）。最初に失敗したステージで短絡する。
→ `<|"WouldFire" -> Bool, "Stage" -> _, "Reason" -> _, "Job" -> _ (WouldFireのとき), "ConditionNotes" -> {...}|>`

context キー（全て省略可・安全なデフォルトあり）: `"Now"` (ISO), `"LastCheck"` (ISO), `"MachineTag"` (String), `"Events"` (List), `"WatermarkEventId"` (String), `"Doctor"` (Association)

ステージと短絡条件:
1. `"Enabled"` — `Enabled -> False` で終了（Reason: `"NotEnabled"`）
2. `"Owner"` — OwnerMachineTag 不一致で終了（Reason: `"NotOwnerMachine"`）
3. `"Schedule"` — スケジュール不一致で終了（Reason: `"NoScheduleMatch"`）
4. `"Condition"` — 条件未達で終了（Reason: `"ConditionNotMet"`）
5. `"DiagnosticsGate"` — 診断ゲート拒否で終了
6. `"Built"` — 全通過・ジョブ構築（Reason: `"AllChecksPassed"`）

ジョブレコード主要キー: `Type("AutoTriggerJob")`, `TriggerId`, `Target`, `FireTimes`, `DispatchSlotKey`(triggerId@firstFireTime), `MachineTag`, `PlacementMode`, `Priority`, `Status("Built")`, `BuiltAtUTC`, `Dispatched(False)`

## ティック / ジョブ管理

### SourceVaultAutoTriggerTick[opts]
有効トリガーをレジストリから読み込み、ライブコンテキスト（now / per-trigger LastCheck 状態 / ライブソースイベント / 機械ローカル doctor）に対して各トリガーを `SourceVaultAutoTriggerEvaluateTrigger` で評価し、通過したトリガーのジョブを追記専用ジョブログ（`autotrigger/jobs.jsonl`）に追記し、per-trigger LastCheck 状態を進める。ディスパッチ・実行は行わない。同一 DispatchSlotKey は既存ログに対してデデュープされる。AsyncActive 中は no-op（defers）。初回ティックでは評価ウィンドウが空のため発火しない（`LastCheckOverride` で過去ウィンドウを指定可能）。
→ ティックサマリー Association
Options: `"DryRun" -> False` (True のとき評価のみ・書き込みなし), `"LastCheckOverride" -> Automatic` (ISO文字列で全トリガーの評価ウィンドウ下限を強制・テスト/手動キャッチアップ用)

### SourceVaultAutoTriggerJobQueue[opts] → List
追記専用ジョブログ（`autotrigger/jobs.jsonl`）から構築済みジョブを返す。
Options: `"Status" -> All` (例: `"Built"` でフィルタ)

### SourceVaultAutoTriggerRunHistory[opts] → List
実行ログ（`autotrigger/runs.jsonl`）から実行レコードを返す。
Options: `"Status" -> All` (例: `"Completed"` でフィルタ)

## ディスパッチ

### SourceVaultAutoTriggerDispatchJobs[opts]
完了していない Built ジョブを DispatchSlotKey で実行ログデデュープ後にディスパッチする。各ジョブに対して診断ゲートとサブプロセスシート残量を再確認し、スロットを確保して**サブカーネル**（サブプロセスプール、メインカーネル外）でターゲットをタイムコンストレイント付きで実行し、結果を `autotrigger/runs.jsonl` に記録する。現時点で実行されるのは `TargetType "PureComputation"` のみ（有界純粋計算、サブカーネルの `$ProcessID` を返してアウトオブプロセス実行を証明）。PromptRoute / Workflow エグゼキュータは未接続（`"ExecutorNotWired"` として記録）。LLM / FrontEnd / ネットワーク / 危険な副作用なし。
→ ディスパッチサマリー Association
Options: `"DryRun" -> False`, `"MaxJobs" -> 1` (1呼び出しあたりジョブ上限), `"TimeConstraintSeconds" -> 30`

### SourceVaultAutoTriggerDispatchAsync[opts]
非同期対応の Built ジョブをメインカーネルをブロックせずにディスパッチする。各ジョブを持続的クリーンサブカーネル（`ParallelSubmit`、サブプロセスプール）に投入してバックグラウンド実行させ結果ファイルに書き込む。呼び出しは即時リターン。`TargetType "PureComputation"` のみ非同期対応（PromptRoute はメインカーネルゲート・手動のみ）。完了確認は `SourceVaultAutoTriggerPoll[]` で行う。
→ サブミットサマリー Association
Options: `"MaxConcurrent" -> 1`, `"TimeConstraintSeconds" -> 120`

### SourceVaultAutoTriggerPoll[] → Association
サブカーネルキューを進め、結果ファイルが出現した非同期ジョブをファイナライズする（Completed/Failed を `runs.jsonl` に記録してサブカーネルを回収）。TimeConstraint を超えたジョブは TimedOut として記録する。ノンブロッキング。共有ポーリングティックからの呼び出しを想定する。

### SourceVaultAutoTriggerRunningJobs[] → List
現在実行中の非同期ジョブ（slot / trigger / 経過秒 / time constraint）を返す。

## スケジューラ

claudecode 共有ポーリングベース（`ClaudeRegisterPollingTick`）に乗る。ロード時は起動しない（オプトイン）。`ScheduledTask` は作成しない（ルール 95）。

### SourceVaultAutoTriggerStartScheduler[opts]
自動トリガースケジューラを claudecode の共有ポーリングベースに登録する。各発火（`"IntervalSeconds"` でスロットル）は非ブロッキングで: Poll（完了済み非同期ジョブのファイナライズ） → Tick（有効トリガー評価・ジョブ構築） → DispatchAsync（非同期対応ジョブをサブカーネルに投入） → DispatchWorkflows（オーケストレータが存在する場合）の順で実行する。PromptRoute（メインカーネルブロッキング）は自動ディスパッチしない。AsyncActive 中は defers。サブカーネルプールをここで事前起動してティック中のカーネル起動ブロックを防ぐ。
→ `<|"Status" -> "Registered" | "ClaudeCodeAbsent", "Key" -> _, "IntervalSeconds" -> _|>`
Options: `"IntervalSeconds" -> 60`

### SourceVaultAutoTriggerStopScheduler[] → Association
自動トリガースケジューラを共有ポーリングベースから登録解除する。停止時に完了済み非同期ジョブをベストエフォートでファイナライズする（実行中ジョブは次回 Poll / StartScheduler まで追跡継続）。
→ `<|"Status" -> _, "Key" -> _, "StillRunning" -> {...}, "StillRunningWorkflows" -> {...}|>`

### SourceVaultAutoTriggerSchedulerStatus[] → Association
スケジューラが共有ティックに登録されているか・インターバル・最終スケジューラティックサマリー・実行中非同期ジョブを報告する。

## ワークフロー統合

[ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) へのアダプタ層。オーケストレータシンボルは完全コンテキストパスで参照する（このファイルはオーケストレータより先にロードされるため）。

### SourceVaultStartWorkflowForAutoTrigger[wid_String, metadata_Association : <||>] → Association
既存の wid を非ブロッキングで起動する（`ClaudeRunWorkflow[wid, "Async"->True]`、即時リターン・共有ポーリングティックで進行）。`SourceVaultStartWorkflowForAutoTrigger[spec_Association, metadata]` は `ClaudeCreateWorkflowNet[spec]` でネットをインスタンス化してから起動する。完了をブロックしない。完了確認は `SourceVaultAutoTriggerPoll[]` / `ClaudeAsyncJobInfo` で行う。
→ `<|"Status" -> _, "WorkflowId" -> _, ...|>`

### SourceVaultAutoTriggerDispatchWorkflows[opts]
Built の WorkflowRoute / WorkflowTemplate ジョブを `ClaudeRunWorkflow Async` で非ブロッキングに起動する（メインカーネル、LicensePool ゲート）。FE 必須ターゲットは延期（ティックから自動実行しない）。
→ ディスパッチサマリー Association
Options: `"MaxConcurrent" -> 1`, `"TimeConstraintSeconds" -> 600`

### SourceVaultAutoTriggerRunningWorkflows[] → List
自動トリガーが起動しポーリング中のワークフロー実行（wid / trigger / 経過秒）を返す。

## UI 層

### SourceVaultAutoTriggerCapability[spec_Association] → Association
トリガーのリスト表示分類を導出する（spec section 8）。
→ `<|"AutoRunCapability" -> _, "ExecutionMode" -> _, "AutoEligible" -> Bool|>`

TargetType | AutoRunCapability | ExecutionMode | AutoEligible
--- | --- | --- | ---
`"PureComputation"` | `"HeadlessAsync"` | `"別プロセス非ブロック"` | True
`"WorkflowRoute"`/`"WorkflowTemplate"`（FE不要）| `"HeadlessAsync"` | `"別カーネル非ブロック(workflow)"` | True
`"WorkflowRoute"`/`"WorkflowTemplate"`（FE必要）| `"FrontendRequired"` | `"FE必要"` | False
`"PromptRoute"` | `"BlockingSyncUserInitiated"` | `"主カーネル(手動起動)"` | False
その他 | `"Unknown"` | `"不明"` | False

### SourceVaultAutoTriggerListData[] → List
登録済みトリガーごとに UI 用の行 Association を返す（純読み取り・ディスパッチなし）。
各行キー: `TriggerId`, `Name`, `Enabled`, `ExecutionMode`, `AutoRunCapability`, `AutoToggle`(ON|OFF|不可), `Priority`, `NextFire`, `LastRunStatus`, `HasError`, `ErrorSummary`（クラウドセーフなメタデータのみ・ルール 90）

### SourceVaultAutoTriggerPanel[] → 表示式
登録済みトリガーの Grid を描画する（実行モード / 自動実行可否 / 自動トグル状態 / 色付き優先度バッジ / 次回発火 / 最終実行、最終実行失敗時に警告アイコン → クリックでエラーサマリーダイアログ）。[SourceVault_diagnostics](https://github.com/transreal/SourceVault_diagnostics) がロード済みの場合はトップに診断ステータスバンドを表示する。

## フック / 設定可能変数

### SourceVaultAutoTriggerSourceIdResolver
型: `Automatic | (String -> String)`, 初期値: `Automatic`
設定可能フック。`uri -> SourceId` 変換関数。`SourceVaultEvent` 条件が正規 `sv://` URI をイベントログが使う内部 SourceId に照合するために使用する。`Automatic` のとき組み込みリゾルバーなし（URI は URI を直接保持するイベントとのみ一致）。プロデューサーが `SourceVaultAutoTriggerSourceIdResolver = (myResolver[#] &)` で配線する。

### SourceVaultAutoTriggerWorkflowResolver
型: `Automatic | (String -> String | Association | $Failed)`, 初期値: `Automatic`
設定可能フック。`slug -> (wid_String | spec_Association | $Failed)` 変換関数。`WorkflowTemplate` の TargetId を `ClaudeRunWorkflow` が実行できる形式に解決する。`Automatic` のとき [SourceVault_workflowcatalog](https://github.com/transreal/SourceVault_workflowcatalog) の `SourceVaultWorkflowCatalogRecord` を参照する。カタログレコードが `"WorkflowId"`（String）を持てば既存 wid として解決、`"WorkflowSpec"`（Association）を持てばインラインスペックとして解決、どちらもなければ FE 必須ノートブックベーステンプレートとして `$Failed` を返す。