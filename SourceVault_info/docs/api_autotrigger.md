## 概要

`SourceVault_autotrigger` は `SourceVault`` コンテキストに属する自動トリガースケジューラだ。`Get[]` ロード可能・単独動作・副作用フリー設計（ルール 11 / 30 / spec 2.3）。`Needs["ClaudeRuntime`"]` / `["ClaudeOrchestrator`"]` への依存なし。

レジストリ形式は `compiled/auto-triggers/<id>.wxf`（WXF はデシリアライズのみで評価されない → tampered ファイルによる任意コード実行を防ぐ。WXF は `Missing[...]` / `Automatic` / `All` / `Quantity[...]` をロスレスで往復できる）。

**実装フェーズ構成**（現バージョン `0.1-phase1.4`）:
- Phase 1.1: TriggerSpec バリデーション・レジストリ・スケジュール照合・条件照合・診断ゲート・per-trigger 評価・ティック・同期/非同期ディスパッチ・ワークフロー統合・スケジューラ・UI層
- Phase 1.2: `SpecificMachine` 配置の実効化（バリデーションの `RequiredMachineTags` 非空チェック + machine registry 照合警告、per-trigger 評価の Placement ステージ、ジョブへの `RequiredMachineTags`/`EligibleHere` 記録、ディスパッチ各経路での実行PCゲート）・プロンプト→TriggerSpec 変換（`SourceVaultParseAutoTriggerPrompt`、決定論優先 + 任意 LLM フック）・UI 実行PC列
- Phase 1.3: ジョブ/実行ログの多重マシン安全化（単一ライター原則: `autotrigger/jobs/<machineTag>.jsonl` / `runs/<machineTag>.jsonl` に自マシン分のみ追記し、旧共有ファイル + 全マシンファイルを統合して読む）・`CatalogWorkflow`（生成カタログワークフローを指定PCで実行）・リモート実行結果の往復（`SourceVaultRemoteWorkflowResult` / `SourceVaultAutoTriggerWatchRemoteRun`）
- Phase 1.4（現実装）: `SourceVaultAutoTriggerDispatchJobs` に `PromptRoute`（SourceVault_promptrouter のゲート済み安全機構経由 `ReleaseHold`）・`WorkflowRoute`/`WorkflowTemplate`（オーケストレータ非ブロッキング起動）の実エグゼキュータを配線・外部エグゼキュータ向けプロセス枠ガード（`DeferredLicenseSeatUnavailable`）

**TargetType と実行方式**:

TargetType | 実行方式 | AutoEligible
--- | --- | ---
`"PureComputation"` | サブカーネル非同期（SubprocessPool） | True
`"WorkflowRoute"` | メインカーネル非同期（ClaudeOrchestrator） | True（FE不要時）
`"WorkflowTemplate"` | テンプレート解決後 → 同上 | True（FE不要時）
`"PromptRoute"` | メインカーネル・手動起動のみ（`SourceVaultAutoTriggerDispatchJobs` から手動呼び出し時のみゲート付き実行、ティックからは自動起動しない） | False
`"CatalogWorkflow"` | 外部プロセス（`SourceVaultRunWorkflowAsync`）・`SpecificMachine` 配置限定 | True

**TriggerSpec 主要キー**: `TriggerId`(String), `Name`(String), `Enabled`(Bool), `Type`(String), `Owner`(Association), `Schedule`(Association), `Condition`(Association), `Target`(Association), `ExecutionPlacement`(Association), `DiagnosticsPolicy`(Association), `RunPolicy`(Association), `CreatedBy`(String)

## バージョン / 定数

### $SourceVaultAutoTriggerVersion
型: String, 初期値: `"0.1-phase1.4"`
パッケージバージョン文字列。

## レジストリ操作

### SourceVaultAutoTriggerStatus[] → Association
自動トリガーサブシステムのステータス（バージョン・レジストリディレクトリ・登録トリガー数）を返す。

### SourceVaultNewAutoTriggerId[] → String
`"autotrg-XXXXXXXXXXXX"` 形式の新規トリガーIDを生成して返す。

### SourceVaultValidateAutoTrigger[spec_Association] → Association
TriggerSpec を構造的にバリデートする（必須キー・Type / TargetType / Owner.Mode / Schedule.Kind / ExecutionPlacement.Mode 列挙値・Enabled 真偽値）。TargetType は `"PromptRoute"`/`"WorkflowRoute"`/`"WorkflowTemplate"`/`"PureComputation"`/`"CatalogWorkflow"` のいずれか。ライブターゲット存在確認・URI解決はディスパッチ時層に委ねる。
`ExecutionPlacement.Mode -> "SpecificMachine"` の場合は `RequiredMachineTags` 非空が必須（空/欠如は Issue `"SpecificMachineRequiresMachineTags"` → `Valid -> False`, spec 3.1）。既知マシン（自マシン + `SourceVault_diagnostics` の machine registry）に無いタグは Warning `"RequiredMachineTagUnknown:<tag>"` のみ（対象PCが後から登録する場合があるため）。照合は大文字小文字を無視する（Windows の `$MachineName` は小文字、spec/プロンプトは `ProArtPX13` 等の表示ケース）。
→ `<|"Valid" -> Bool, "Issues" -> {...}, "Warnings" -> {...}, "TriggerId" -> _|>`

### SourceVaultAutoTriggerKnownMachineTags[] → List
このバルトが認識するマシンタグを返す。内訳（すべて弱参照・union）: 自マシンのタグ + **`SourceVaultListRuntimeMachines[]`（権威=実際に vault を共有している PC。`runtime/` ツリー由来）** + `SourceVault_diagnostics` の machine registry の全 `MachineTag`（任意・古いテストエントリを含みうるので正本にしない）。servicemanager/diagnostics 不在時は自マシンのみ。`SpecificMachine` 配置バリデーションの未知タグ警告と `SourceVaultParseAutoTriggerPrompt` のプロンプト内マシン名検出に使う。

**共有 PC 一覧の正本は `SourceVaultListRuntimeMachines[]`（`SourceVault_servicemanager.wl`）**: `runtime/<machineTag>/` サブディレクトリのうち共有/レガシー予約名（`locks`/`proxies`/`services`）を除いたもの + 自機。手動レジストリ（`diagnostics/machines`）は健全性・heartbeat 用の別レイヤーで、登録漏れ（例: rapterlake4t）や実在しないテストエントリ（例: ProArtPX13-test）を含みうるため PC 一覧の権威にはしない。`"Details" -> True` で `<|MachineTag, IsSelf, HasServices, HasProxies|>` の一覧を返す。

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

EventType マッピング: `"Updated"/"Ingested"` → `{"VersionedUpdate"}`, `"Deleted"` → `{"SourceDeletion","Retraction"}`, `"Retracted"` → `{"Retraction"}`, `"MetadataChanged"` → `{"SchemaChange"}`, `"ClaimChanged"` → `{"ClaimChanged"}`, `"RegistryChanged"` → `{"RegistryChanged"}`, その他 → そのまま（前方互換）

URI→SourceId 解決: `SourceVaultAutoTriggerSourceIdResolver` フックが `Automatic` の場合は組み込みリゾルバーなし（`Missing["NoDefaultResolver"]`）。`SourceVaultAutoTriggerSourcesURIResolver` を割り当てるとオプトインで `SourceVaultSources` 経由の URI→SourceId 解決が有効になる。

例:
```
cond = <|"Combinator" -> "AllOf", "Children" -> {
  <|"Atom" -> "SourceVaultEvent", "SourceId" -> "src-001", "EventType" -> "Updated"|>}|>;
SourceVaultAutoTriggerConditionMatch[cond, <|"WatermarkEventId" -> "evt-42"|>]
```

## 診断ゲート

spec 3.3 に基づくディスパッチ許可判定。判定のみで実行しない。機械ローカル doctor を安全フォールバックとして使用（マルチPC集約は未接続）。

### SourceVaultAutoTriggerDiagnosticsGate[spec_Association, context_Association : <||>] → Association
トリガーがディスパッチしてよいかを診断健全性に基づいて判定する。コンポーネントスコープ（ワークフローが実際に必要とするコンポーネントのみ確認、`DiagnosticsPolicy.RequiredComponents` で明示可能）。`RequiredHealth "OK"` は全コンポーネント OK を要求、`"DegradedAccepted"` は Degraded も許容するが Failing は拒否する。`context["Doctor"]`（テスト用 Association）またはライブ `SourceVaultDiagnosticsLightweightDoctor` を使用する。`RequireDiagnosticsReady -> False` またはシステムドクターワークフロー（`CreatedBy "System"` / `context["Exempt"] -> True`）はゲートをバイパスする。
→ `<|"Allowed" -> Bool, "Reason" -> _, "RequiredComponents" -> {...}, "BlockingComponents" -> {...}, "RequiredHealth" -> _, "DoctorGlobalHealth" -> _|>`

TargetType 別デフォルト RequiredComponents（`DiagnosticsPolicy.RequiredComponents` 未指定時）: `"PureComputation"` → `{"SubprocessPool"}`, `"PromptRoute"` → `{"LicensePool"}`, `"WorkflowTemplate"`/`"WorkflowRoute"` → `{}`（メインカーネル共有ポーリングで動作しプロセス/サブプロセスのスロットを消費しないため）, その他（`"CatalogWorkflow"` を含む） → `{"LicensePool"}`

context キー: `"Doctor"` (Association, 省略時はライブ doctor), `"Exempt"` (Bool)

## per-trigger 評価

### SourceVaultAutoTriggerEvaluateTrigger[spec_Association, context_Association : <||>] → Association
spec 11.1 の完全な per-trigger 決定パイプラインを構成する（Enabled → Owner → Schedule → Condition → DiagnosticsGate → Placement）。純粋関数・IO なし・ディスパッチなし。全チェック通過時にジョブレコード（`Status "Built"`, `Dispatched False`）を構築して返す（実行しない）。最初に失敗したステージで短絡する。`Owner`（trigger 判定/job 作成を所有するPC）と `ExecutionPlacement`（実行できるPC）は別物であることに注意。ジョブ構築は実行PCに限定しない（owner PC が他PC実行のジョブも作る）。実行抑止はディスパッチ側の実行PCゲートで行う。
→ `<|"WouldFire" -> Bool, "Stage" -> _, "Reason" -> _, "Job" -> _ (WouldFireのとき), "ConditionNotes" -> {...}|>`

context キー（全て省略可・安全なデフォルトあり）: `"Now"` (ISO), `"LastCheck"` (ISO), `"MachineTag"` (String), `"Events"` (List), `"WatermarkEventId"` (String), `"Doctor"` (Association)

ステージと短絡条件:
1. `"Enabled"` — `Enabled -> False` で終了（Reason: `"NotEnabled"`）
2. `"Owner"` — OwnerMachineTag 不一致で終了（Reason: `"NotOwnerMachine"`）
3. `"Schedule"` — スケジュール不一致で終了（Reason: `"NoScheduleMatch"`）
4. `"Condition"` — 条件未達で終了（Reason: `"ConditionNotMet"`）
5. `"DiagnosticsGate"` — 診断ゲート拒否で終了
6. `"Placement"` — `SpecificMachine` かつ `RequiredMachineTags` 空で終了（Reason: `"SpecificMachineRequiresMachineTags"`）
7. `"Built"` — 全通過・ジョブ構築（Reason: `"AllChecksPassed"`）

ジョブレコード主要キー: `Type("AutoTriggerJob")`, `TriggerId`, `Target`, `FireTimes`, `DispatchSlotKey`(triggerId@firstFireTime), `MachineTag`, `PlacementMode`, `RequiredMachineTags`（`SpecificMachine` 指定タグ・それ以外は `{}`）, `EligibleHere`（このPCで実行可能か・`EnvironmentIndependent`/自PC指定は True）, `Priority`, `Status("Built")`, `BuiltAtUTC`, `Dispatched(False)`

## ティック / ジョブ管理

### SourceVaultAutoTriggerTick[opts]
有効トリガーをレジストリから読み込み、ライブコンテキスト（now / per-trigger LastCheck 状態 / ライブソースイベント / 機械ローカル doctor）に対して各トリガーを `SourceVaultAutoTriggerEvaluateTrigger` で評価し、通過したトリガーのジョブを追記専用ジョブログ（`autotrigger/jobs/<machineTag>.jsonl`）に追記し、per-trigger LastCheck 状態を進める。ディスパッチ・実行は行わない。同一 DispatchSlotKey は既存ログに対してデデュープされる。AsyncActive 中は no-op（defers）。初回ティックでは評価ウィンドウが空のため発火しない（`LastCheckOverride` で過去ウィンドウを指定可能）。
→ ティックサマリー Association
Options: `"DryRun" -> False` (True のとき評価のみ・書き込みなし), `"LastCheckOverride" -> Automatic` (ISO文字列で全トリガーの評価ウィンドウ下限を強制・テスト/手動キャッチアップ用)

### SourceVaultAutoTriggerJobQueue[opts] → List
追記専用ジョブログ（自マシン分の `autotrigger/jobs/<machineTag>.jsonl` 全ファイル + 旧共有 `autotrigger/jobs.jsonl`（読み取り専用の履歴）を統合）から構築済みジョブを返す。
Options: `"Status" -> All` (例: `"Built"` でフィルタ)

### SourceVaultAutoTriggerRunHistory[opts] → List
実行ログ（`autotrigger/runs/<machineTag>.jsonl` 全ファイル + 旧共有 `autotrigger/runs.jsonl` を統合）から実行レコードを返す。
Options: `"Status" -> All` (例: `"Completed"` でフィルタ)

## カタログワークフローを特定 PC で実行（CatalogWorkflow）

ワークフロー一覧パネルの slug（生成カタログワークフロー）を**選択した PC 上で**実行する経路。パネルの実行ボタンは自機なら即時 `SourceVaultRunWorkflowAsync`（外部プロセス・ローカル）、他 PC なら下記でキュー投入し、対象 PC のスケジューラが placement gate で拾って `SourceVaultRunWorkflowAsync` をそのローカルで実行する。WorkflowRoute/WorkflowTemplate（ClaudeRunWorkflow 経路）とは**別 executor**（カタログ slug は生成 Launch entry で走るため）。TargetType は `"CatalogWorkflow"`（`Target` は `<|"TargetType","TargetId"(=slug),"Form"(既定"run")|>`）。他ディスパッチャは target-type フィルタで CatalogWorkflow を無視し、`SourceVaultAutoTriggerDispatchCatalogRuns` だけが実行する。

### SourceVaultEnqueueWorkflowRun[slug_String, machineTag_String, opts] → Association
「slug を machineTag で実行」の一発ジョブを共有ジョブログに投入する（自己完結・登録トリガー不要・SpecificMachine placement）。パネルの実行ボタンが**非自機**選択時に呼ぶ。
→ `<|"Status" -> "Enqueued" | "EnqueueFailed", "Slug", "MachineTag", "DispatchSlotKey", "EligibleHere", "Note"|>`
Options: `"Form" -> "run"`
**前提**: 対象 PC で `SourceVaultAutoTriggerStartScheduler[]` が稼働していること（未起動ならジョブは拾われず待機）。

### SourceVaultRemoteWorkflowResult[dispatchSlotKey_String] → 結果 | Failure | Missing
リモート実行(他PCで実行された CatalogWorkflow)の結果を取り出す。実行PC側は外部ジョブ完了時に output.wxf を共有 `autotrigger/results/<safe-slot>-result.wxf` へ publish し(`iSVATPollCatalogRuns`、tick/Poll 結線)、per-machine runs に `CatalogRunCompleted` / `CatalogRunFailed`(Reason 付き。status.json Failed/Expired・起動後180s status 未出現・TTL 7200s 超)を記録する。本関数はどのPCからでも共有結果を import して返す。失敗時は `Failure["CatalogRunFailed", <|Reason, MachineTag, Slug, FinishedAtUTC|>]`、未完了は `Missing["StillRunning"|"ResultSyncing"|"NotFinished"|"NotFound", slot]`。

### SourceVaultAutoTriggerWatchRemoteRun[dispatchSlotKey, meta] → Association
依頼元PCでリモート実行を監視登録する(ワークフロー一覧パネルがリモート「実行」時に自動登録)。スケジューラ tick(`iSVATPollRemoteWatches`)が統合 runs から終端記録を検出すると、**NBAccess final action queue(WriteNotebookCell + TargetNotebook)経由**で発行元ノートブックへ書き込む: 完了=評価可能な `SourceVaultRemoteWorkflowResult["<slot>"]` セル、失敗/タイムアウト(`$iSVATRemoteWatchTTLSeconds` 既定 7200s)=赤の Text レポート。tick から生 `NotebookWrite` はしない(externalrunner と同じ single-committer 経路)。meta: `"Notebook"`(NotebookObject)/`"Slug"`/`"MachineTag"`。watch はセッションローカル(FE 再起動で消えるが、結果は Retriever でいつでも取得可)。

### SourceVaultAutoTriggerDispatchCatalogRuns[opts]
このマシンが実行を許可された（placement gate: `RequiredMachineTags` に自機を含む）CatalogWorkflow ジョブを `SourceVaultRunWorkflowAsync` で非ブロッキング起動し、`autotrigger/runs.jsonl` に `CatalogRunSubmitted`（spoken-for な終端 status＝再ディスパッチ抑止）として記録する。オーケストレータ非依存。スケジューラ tick に結線済み（スケジューラ稼働 PC は自機宛の run を自動で拾う）。
Options: `"MaxRuns" -> 4`

**プロセス枠ガード**: 外部エグゼキュータは独立 wolframscript プロセス＝**プロセスライセンス枠**を消費する（サブカーネル枠ではない）。枠が満杯（`SourceVaultDiagnosticsLicenseProbe[]["ProcessSlotsFree"] == 0`）だと子プロセスが起動直後に落ち、`status.json`/`output.wxf` を書けず**無言の NotReady**になる。これを防ぐため、dispatch は claim/実行の前に空き枠を確認し、0 なら **claim も run 記録もせず defer**（結果に `DeferredLicenseSeatUnavailable` を返し、ジョブは Built のまま＝枠が空いた次の tick で自動再試行、ログもスパムしない）。`iSVATExecuteCatalogWorkflow` にも同じ二重ガードあり。パネルのローカル実行ボタンも実行前に枠 0 を検出してダイアログで停止する。診断未ロード時（`Missing["Unknown"]`）はガードしない（不明で止めない）。

## ディスパッチ

**ジョブ/実行ログの多重マシン安全化（phase1.3、spec 3.1.1）**: 旧実装の単一共有 `jobs.jsonl`/`runs.jsonl` は複数PCの同時追記で **Dropbox 競合コピー→リモート追記の消失**を起こした（2026-07-07 実測）。現在は heartbeat と同じ**単一ライター原則**: 各PCは自分専用の `autotrigger/jobs/<machineTag>.jsonl`（`runs/<machineTag>.jsonl`）にのみ追記し、読み側は全マシンのファイル+旧共有ファイル（読み取り専用の履歴）を統合して読む。ファイル間の順序は問わない（dedup は DispatchSlotKey キー）。

**実行PCゲート（spec 7.2.1）**: ジョブログは共有バルトルート上にあり全PCのディスパッチャが全 Built ジョブを見る。`PlacementMode -> "SpecificMachine"` のジョブは `RequiredMachineTags` に自マシンのタグを含むPCだけが実行する（大文字小文字無視）。他PCはスキップ（`DispatchJobs` は `"NotEligibleMachine:SpecificMachine"`、`DispatchAsync`/`DispatchWorkflows` は Select で除外）し、ジョブは対象PCのディスパッチャのために Built のまま残る。タグ無しの `SpecificMachine` はどのPCでも実行不可（フェイルセーフ・バリデーションが拒否）。旧バージョンのジョブレコードには `RequiredMachineTags` フィールドが無いため、その場合は trigger spec の `ExecutionPlacement` にフォールバックする。`EnvironmentIndependent` / `WorkerPool` は全PSで実行可能（WorkerPool の負荷分散・failover は未実装）。

### SourceVaultAutoTriggerDispatchJobs[opts]
完了していない Built ジョブ（**TargetType によるフィルタなし・全種を対象**）を DispatchSlotKey で実行ログデデュープ後にディスパッチする。各ジョブに対して診断ゲートと**サブプロセス**シート残量（`iSVATSubprocessSlotsFree`、TargetType に関わらず一律チェック）を再確認し、スロットを確保して実行する。TargetType 別の実際の実行方式:
- `"PureComputation"`: **サブカーネル**（サブプロセスプール、メインカーネル外）でタイムコンストレイント付き実行し、サブカーネルの `$ProcessID` を返してアウトオブプロセス実行を証明する（有界純粋計算のみ）。
- `"PromptRoute"`: SourceVault_promptrouter の既存ゲート済み安全機構（ルート取得 → `iSVPRRouteAutoExecutableQ` による EnvironmentIndependent + head allowlist チェック → 暗号化ペイロードなら復号 → `ReplaySafety` 再検証）を通してから**メインカーネル**で `ReleaseHold` をタイムコンストレイント付き実行する（Backend `"MainKernelGated"`）。ゲート拒否は `"Blocked"`(Reason `"NotAutoExecutable"`/`"HeadOrSafetyRejected"`)。結果はメタデータのみ記録（Head/Length/ByteCount、内容は保存しない・プライバシー）。promptrouter 未ロード時は `"Skipped"`(Reason `"PromptRouterUnavailable"`)。
- `"WorkflowRoute"`/`"WorkflowTemplate"`: `ClaudeRunWorkflow Async` で非ブロッキングに起動する（`SourceVaultAutoTriggerDispatchWorkflows` と同じ実行経路）。FE 必須ターゲットは `"Deferred"`(Reason `"FrontendRequired"`)。
- それ以外（`"CatalogWorkflow"` 等）: `"ExecutorNotWired:<TargetType>"` として記録するのみ（実行しない・`SourceVaultAutoTriggerDispatchCatalogRuns` 等の専用ディスパッチャを使うこと）。

No LLM / FrontEnd / network / dangerous side effects（PromptRoute はローカル読み取り専用ゲートを通過したものだけを実行）。Placement gate: `ExecutionPlacement` が `"SpecificMachine"` のジョブは `RequiredMachineTags` に自マシンのタグを含むPCのみ実行し（大文字小文字無視）、他マシンはスキップする（`"NotEligibleMachine:SpecificMachine"`、jobs は共有バルトルート経由で全PCに見える）。**注意**: この関数はスケジューラ tick からは呼ばれない（tick は Poll → Tick → DispatchAsync → DispatchWorkflows → DispatchCatalogRuns の順で、DispatchJobs は含まれない）ため、`"PromptRoute"` の実行にはこの関数の手動呼び出しが必要。
→ ディスパッチサマリー Association
Options: `"DryRun" -> False`, `"MaxJobs" -> 1` (1呼び出しあたりジョブ上限), `"TimeConstraintSeconds" -> 30`

### SourceVaultAutoTriggerDispatchAsync[opts]
非同期対応の Built ジョブをメインカーネルをブロックせずにディスパッチする。各ジョブを持続的クリーンサブカーネル（`ParallelSubmit`、サブプロセスプール）に投入してバックグラウンド実行させ結果ファイルに書き込む。呼び出しは即時リターン。`TargetType "PureComputation"` のみ非同期対応（PromptRoute はメインカーネルゲート・手動のみ）。完了確認は `SourceVaultAutoTriggerPoll[]` で行う。
→ サブミットサマリー Association
Options: `"MaxConcurrent" -> 1`, `"TimeConstraintSeconds" -> 120`

### SourceVaultAutoTriggerPoll[] → Association
サブカーネルキュー・ワークフロー・カタログ実行・リモート監視を進め、結果が出現したジョブをファイナライズする（Completed/Failed 等を runs に記録してサブカーネルを回収）。TimeConstraint を超えたジョブは TimedOut として記録する。ノンブロッキング。共有ポーリングティックから呼ばれる。
→ `<|"Finalized" -> {...}, "StillRunning" -> {...}, "Subkernel" -> _, "Workflow" -> _, "CatalogPending" -> {...}, "RemoteWatches" -> {...}|>`

### SourceVaultAutoTriggerRunningJobs[] → List
現在実行中の非同期ジョブ（slot / trigger / 経過秒 / time constraint）を返す。

## スケジューラ

claudecode 共有ポーリングベース（`ClaudeRegisterPollingTick`）に乗る。ロード時は起動しない（オプトイン）。`ScheduledTask` は作成しない（ルール 95）。

### SourceVaultAutoTriggerStartScheduler[opts]
自動トリガースケジューラを claudecode の共有ポーリングベースに登録する。各発火（`"IntervalSeconds"` でスロットル）は非ブロッキングで: Poll（完了済みジョブ/ワークフロー/カタログ実行/リモート監視のファイナライズ） → Tick（有効トリガー評価・ジョブ構築） → DispatchAsync（非同期対応ジョブをサブカーネルに投入） → DispatchWorkflows（オーケストレータが存在する場合） → DispatchCatalogRuns（自機宛の CatalogWorkflow 実行） → PollCatalogRuns（実行側: 完了結果の共有vaultへの publish） → PollRemoteWatches（依頼側: 完了/失敗の発行元ノートブックへの通知）の順で実行する。`"PromptRoute"`（メインカーネルブロッキング）と `SourceVaultAutoTriggerDispatchJobs`（PureComputation/PromptRoute/Workflow を手動ディスパッチする別関数）はこのティックには含まれない。AsyncActive 中は defers。サブカーネルプールをここで事前起動してティック中のカーネル起動ブロックを防ぐ。claudecode の共有ポーリングベースが不在の場合は登録せず `"ClaudeCodeAbsent"` を返す。
→ `<|"Status" -> "Registered" | "ClaudeCodeAbsent", "Key" -> _, "IntervalSeconds" -> _|>`
Options: `"IntervalSeconds" -> 60`

### SourceVaultAutoTriggerStopScheduler[] → Association
自動トリガースケジューラを共有ポーリングベースから登録解除する。停止時に完了済み非同期ジョブをベストエフォートでファイナライズする（実行中ジョブは次回 Poll / StartScheduler まで追跡継続）。
→ `<|"Status" -> _, "Key" -> _, "StillRunning" -> {...}, "StillRunningWorkflows" -> {...}|>`

### SourceVaultAutoTriggerSchedulerStatus[] → Association
スケジューラが共有ティックに登録されているか・インターバル・最終スケジューラティックサマリー・実行中非同期ジョブを報告する。

## ワークフロー統合

[ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) へのアダプタ層。オーケストレータシンボルは完全コンテキストパス（`ClaudeOrchestrator`Workflow`...`）で参照する（このファイルはオーケストレータより先にロードされるため）。

### SourceVaultStartWorkflowForAutoTrigger[wid_String, metadata_Association : <||>] → Association
既存の wid を非ブロッキングで起動する（`ClaudeRunWorkflow[wid, "Async"->True]`、即時リターン・共有ポーリングティックで進行）。`SourceVaultStartWorkflowForAutoTrigger[spec_Association, metadata]` は `ClaudeCreateWorkflowNet[spec]` でネットをインスタンス化してから起動する。完了をブロックしない。完了確認は `SourceVaultAutoTriggerPoll[]` / `ClaudeAsyncJobInfo` で行う。
→ `<|"Status" -> _, "WorkflowId" -> _, ...|>`

### SourceVaultAutoTriggerDispatchWorkflows[opts]
Built の WorkflowRoute / WorkflowTemplate ジョブを `ClaudeRunWorkflow Async` で非ブロッキングに起動する（メインカーネル、LicensePool ゲート）。FE 必須ターゲットは延期（ティックから自動実行しない）。SpecificMachine ジョブで自マシンが RequiredMachineTags に含まれないものは対象外。
→ ディスパッチサマリー Association
Options: `"MaxConcurrent" -> 1`, `"TimeConstraintSeconds" -> 600`

### SourceVaultAutoTriggerRunningWorkflows[] → List
自動トリガーが起動しポーリング中のワークフロー実行（wid / trigger / 経過秒）を返す。

## プロンプト → TriggerSpec 変換

spec 10。自然文（日本語 / 英語）を TriggerSpec に変換する。決定論優先で、一般的な形式は LLM 不要（監査可能・ヘッドレステスト可能・プライバシー中立）。

### SourceVaultParseAutoTriggerPrompt[prompt_String, target_Association, opts] → Association
自然文のトリガー依頼を TriggerSpec に変換する。返る TriggerSpec は常に `Enabled -> False`（パース → ユーザー確認 → `SourceVaultRegisterAutoTrigger` → 有効化）。元プロンプトは `PromptSource.OriginalPromptStorage -> "HashOnly"`（SHA256 ハッシュのみ・プライバシー既定）。
→ `<|"Status" -> "OK" | "NeedsClarification" | "Failed", "TriggerSpec" -> spec, "Explanation" -> String, "Questions" -> {...}, "Warnings" -> {...}, "Notes" -> {...}, "Validation" -> _, "NextFirePreview" -> _|>`
Options: `"TimeZone" -> "Asia/Tokyo"`, `"KnownMachineTags" -> Automatic`（Automatic は `SourceVaultAutoTriggerKnownMachineTags[]`）, `"LLMFunction" -> Automatic`, `"Now" -> Automatic`（ISO文字列で再現可能テスト）

`target` は UI 行から渡す（`<|"TargetType" -> "WorkflowTemplate", "TargetId" -> slug|>` 等）。TargetType/TargetId が無い場合は Question `"TargetMissing"` を積む。

決定論レイヤーが解釈する形式:
- **スケジュール**: `毎週<曜日>HH:MM`・`隔週`/`2週間おき`（anchor 必要・無ければ Question）・`毎日`・`毎朝`(07:00 と仮定・確認 Question)・`毎月D日`・`N時間ごと`・`N分ごと`・ISO datetime/`YYYY年M月D日`（Alarm）・`N時間後`(Timer, anchor=パース時刻)・weekly/daily/every N hours
- **条件**: プロンプト内の `sv://` URI（+ `更新`/updated）→ `SourceVaultEvent` Updated 条件（複数 URI は `AnyOf`）
- **配置**: 既知マシンタグがプロンプト内に出現、または `<tag>で実行`/`<tag>上で`/`run on <tag>` → `ExecutionPlacement` `SpecificMachine` + `RequiredMachineTags`。sv:// URI の一部であるトークンは除外
- **RunPolicy**: 優先度語（最優先/critical→Critical、高優先/重要→High、低優先→Low）、`1回だけ`/only once → `MaxRunsPerWindow` 1/Day

スケジュールが解釈できず LLM フックがある場合（Option `"LLMFunction" -> fn` またはフック `SourceVaultAutoTriggerPromptLLM`）のみ、LLM が欠けたスロットだけを埋める。LLM 出力は JSON（spec 10.2）で、RawJSON パース + キーホワイトリスト + `SourceVaultValidateAutoTrigger` を通す（`ToExpression` は絶対に使わない）。

`Status` 判定: TriggerSpec が invalid かスケジュール未解決 → Question があれば `NeedsClarification`、無ければ `Failed`。Question があれば `NeedsClarification`。それ以外 `OK`。

### SourceVaultAutoTriggerPromptLLM
型: `Automatic | (String -> String)`, 初期値: `Automatic`
設定可能フック。決定論レイヤーがスケジュールを解釈できない時に `SourceVaultParseAutoTriggerPrompt` が使う `fullPrompt -> jsonString` 関数。プライバシー: プロンプトは private な sv:// URI を含みうるため、クラウドセーフと分かっている場合を除きローカルモデルに配線すること（spec 10.2）。

例:
```
SourceVaultParseAutoTriggerPrompt[
  "毎週金曜日の03:00に、sv://source/blog/foo が更新されていたら起動。ProArtPX13で実行して",
  <|"TargetType" -> "WorkflowTemplate", "TargetId" -> "daily-blog-summary"|>]
(* Schedule=CalendarPattern(Friday 3:00), Condition=SourceVaultEvent(Updated),
   ExecutionPlacement=SpecificMachine{ProArtPX13}, Enabled=False *)
```

## UI 層

### SourceVaultAutoTriggerCapability[spec_Association] → Association
トリガーのリスト表示分類を導出する（spec section 8）。
→ `<|"AutoRunCapability" -> _, "ExecutionMode" -> _, "AutoEligible" -> Bool|>`

TargetType | AutoRunCapability | ExecutionMode | AutoEligible
--- | --- | --- | ---
`"PureComputation"` | `"HeadlessAsync"` | `"別プロセス非ブロック"` | True
`"WorkflowRoute"`/`"WorkflowTemplate"`（FE不要）| `"HeadlessAsync"` | `"別カーネル非ブロック(workflow)"` | True
`"WorkflowRoute"`/`"WorkflowTemplate"`（FE必要）| `"FrontendRequired"` | `"FE必要"` | False
`"CatalogWorkflow"` | `"HeadlessAsync"` | `"別プロセス(カタログ)"` | True
`"PromptRoute"` | `"BlockingSyncUserInitiated"` | `"主カーネル(手動起動)"` | False
その他 | `"Unknown"` | `"不明"` | False

### SourceVaultAutoTriggerListData[] → List
登録済みトリガーごとに UI 用の行 Association を返す（純読み取り・ディスパッチなし）。
各行キー: `TriggerId`, `Name`, `Enabled`, `TargetType`, `TargetId`, `ExecutionMode`, `Placement`（実行PCラベル: `環境非依存` | `pool: <name>` | `固定: <tags>` | `未判定`）, `AutoRunCapability`, `AutoToggle`(ON|OFF|不可), `Priority`, `NextFire`, `LastRunStatus`, `HasError`, `ErrorSummary`（クラウドセーフなメタデータのみ・ルール 90）

### SourceVaultAutoTriggerForTarget[targetType, targetId] → Association | Missing
ターゲットが一致する登録済みトリガーの `SourceVaultAutoTriggerListData` 行を返す（例: カタログスラッグに対する WorkflowTemplate トリガー）。一致するトリガーがない場合は `Missing["NoTrigger"]`。既存のワークフロー / 保存プロンプトリストが per-row で自動実行ステータスを表示するために使用する。**NextFire は常に `Missing["NotComputed"]`**（`SourceVaultAutoTriggerNextFire` はスケジュールホライズンスキャンで1トリガーあたり~3.5秒かかり、リスト行 × Dynamic 経由で呼ぶと FE 評価予算を超えて `$Aborted` になるため、意図的にスキップしている）。

### SourceVaultAutoTriggerStatusCell[targetType, targetId] → 表示式
そのターゲットのトリガーのコンパクトセル（自動トグルバッジ + 優先度 + 警告アイコン）を描画する。トリガーが登録されていない場合はグレーのダッシュを返す。既存リスト Grid に埋め込む用途向け。`targetType -> "Workflow"` は複合タイプとして扱い、`WorkflowTemplate` → `WorkflowRoute` の順で最初に一致したトリガーを使う（カタログ slug がどちらの TargetType で登録されているか不定なため）。

### SourceVaultAutoTriggerPanel[] → 表示式
登録済みトリガーの Grid を描画する（名前 / 実行モード / 実行PC / 自動実行可否 / 自動トグル状態 / 色付き優先度バッジ / 次回発火 / 最終実行、最終実行失敗時に警告アイコン → クリックでエラーサマリーダイアログ）。[SourceVault_diagnostics](https://github.com/transreal/SourceVault_diagnostics) がロード済みの場合はトップに診断ステータスバンドを表示する。

## フック / 設定可能変数

### SourceVaultAutoTriggerSourceIdResolver
型: `Automatic | (String -> String)`, 初期値: `Automatic`
設定可能フック。`uri -> SourceId` 変換関数。`SourceVaultEvent` 条件が正規 `sv://` URI をイベントログが使う内部 SourceId に照合するために使用する。`Automatic` のとき組み込みリゾルバーなし（URI は URI を直接保持するイベントとのみ一致）。プロデューサーが `SourceVaultAutoTriggerSourceIdResolver = (myResolver[#] &)` で配線する。opt-in で `SourceVaultAutoTriggerSourcesURIResolver` を割り当てることで SourceVaultSources 経由の URI→SourceId 解決が有効になる。

### SourceVaultAutoTriggerSourcesURIResolver[uri_String] → String | Missing
正規 `sv://` URI を `SourceVaultSources` 経由で SourceId に解決する（オプトイン）。URI が見つからない場合・sources listing が利用不可の場合は `Missing` を返す。`SourceVaultAutoTriggerSourceIdResolver = SourceVaultAutoTriggerSourcesURIResolver` で配線することで `SourceVaultEvent` 条件が URI で照合できるようになる（SourceId と URI の対応がバルトで成立することを確認してから有効化すること）。

### SourceVaultAutoTriggerWorkflowResolver
型: `Automatic | (String -> String | Association | $Failed)`, 初期値: `Automatic`
設定可能フック。`slug -> (wid_String | spec_Association | $Failed)` 変換関数。`WorkflowTemplate` の TargetId を `ClaudeRunWorkflow` が実行できる形式に解決する。`Automatic` のとき [SourceVault_workflowcatalog](https://github.com/transreal/SourceVault_workflowcatalog) の `SourceVaultWorkflowCatalogRecord` を参照する。カタログレコードが `"WorkflowId"`（String）を持てば既存 wid として解決、`"WorkflowSpec"`（Association）を持てばインラインスペックとして解決、どちらもなければ FE 必須ノートブックベーステンプレートとして `$Failed` を返す。