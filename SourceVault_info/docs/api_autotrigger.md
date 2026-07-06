# SourceVault_autotrigger API リファレンス

GitHub: https://github.com/transreal/SourceVault_autotrigger

## 概要

`SourceVault_autotrigger` は `SourceVault`` コンテキストに属する自動トリガースケジューラだ。`Get[]` ロード可能・単独動作・副作用フリー設計（ルール 11 / 30 / spec 2.3）。`Needs["ClaudeRuntime`"]` / `["ClaudeOrchestrator`"]` への依存なし。

レジストリ形式は `compiled/auto-triggers/<id>.wxf`（WXF はデシリアライズのみで評価されない → tampered ファイルによる任意コード実行を防ぐ。WXF は `Missing[...]` / `Automatic` / `All` / `Quantity[...]` をロスレスで往復できる）。

**実装フェーズ構成**:
- Phase 1.1: TriggerSpec バリデーション・レジストリ・スケジュール照合・条件照合・診断ゲート・per-trigger 評価・ティック・同期/非同期ディスパッチ・ワークフロー統合・スケジューラ・UI層
- Phase 1.2（現実装）: `SpecificMachine` 配置の実効化（バリデーションの `RequiredMachineTags` 非空チェック + machine registry 照合警告、per-trigger 評価の Placement ステージ、ジョブへの `RequiredMachineTags`/`EligibleHere` 記録、ディスパッチ3経路での実行PCゲート）・プロンプト→TriggerSpec 変換（`SourceVaultParseAutoTriggerPrompt`、決定論優先 + 任意 LLM フック）・UI 実行PC列

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
型: String, 初期値: `"0.1-phase1.2"`
パッケージバージョン文字列。

## レジストリ操作

### SourceVaultAutoTriggerStatus[] → Association
自動トリガーサブシステムのステータス（バージョン・レジストリディレクトリ・登録トリガー数）を返す。

### SourceVaultNewAutoTriggerId[] → String
`"autotrg-XXXXXXXXXXXX"` 形式の新規トリガーIDを生成して返す。

### SourceVaultValidateAutoTrigger[spec_Association] → Association
TriggerSpec を構造的にバリデートする（必須キー・Type / TargetType / Owner.Mode / Schedule.Kind / ExecutionPlacement.Mode 列挙値・Enabled 真偽値）。ライブターゲット存在確認・URI解決はディスパッチ時層に委ねる。
`ExecutionPlacement.Mode -> "SpecificMachine"` の場合は `RequiredMachineTags` 非空が必須（空/欠如は Issue `"SpecificMachineRequiresMachineTags"` → `Valid -> False`, spec 3.1）。既知マシン（自マシン + `SourceVault_diagnostics` の machine registry）に無いタグは Warning `"RequiredMachineTagUnknown:<tag>"` のみ（対象PCが後から登録する場合があるため）。照合は大文字小文字を無視する（Windows の `$MachineName` は小文字、spec/プロンプトは `ProArtPX13` 等の表示ケース）。
→ `<|"Valid" -> Bool, "Issues" -> {...}, "Warnings" -> {...}, "TriggerId" -> _|>`

### SourceVaultAutoTriggerKnownMachineTags[] → List
このバルトが認識するマシンタグ（自マシンのタグ + `SourceVault_diagnostics` の machine registry の全 `MachineTag`）を返す。registry 不在時は自マシンのみ。`SpecificMachine` 配置バリデーションの未知タグ警告と `SourceVaultParseAutoTriggerPrompt` のプロンプト内マシン名検出に使う。

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

TargetType 別デフォルト RequiredComponents（`DiagnosticsPolicy.RequiredComponents` 未指定時）: `"PureComputation"` → `{"SubprocessPool"}`, `"PromptRoute"` → `{"LicensePool"}`, `"WorkflowTemplate"`/`"WorkflowRoute"` → `{}`（メインカーネル共有ポーリングで動作しプロセス/サブプロセスのスロットを消費しないため）, その他 → `{"LicensePool"}`

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

**実行PCゲート（spec 7.2.1）**: `jobs.jsonl` は共有バルトルート上にあり全PCのディスパッチャが全 Built ジョブを見る。`PlacementMode -> "SpecificMachine"` のジョブは `RequiredMachineTags` に自マシンのタグを含むPCだけが実行する（大文字小文字無視）。他PCはスキップ（`DispatchJobs` は `"NotEligibleMachine:SpecificMachine"`、`DispatchAsync`/`DispatchWorkflows` は Select で除外）し、ジョブは対象PCのディスパッチャのために Built のまま残る。タグ無しの `SpecificMachine` はどのPCでも実行不可（フェイルセーフ・バリデーションが拒否）。旧バージョンのジョブレコードには `RequiredMachineTags` フィールドが無いため、その場合は trigger spec の `ExecutionPlacement` にフォールバックする。`EnvironmentIndependent` / `WorkerPool` は全PSで実行可能（WorkerPool の負荷分散・failover は未実装）。

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
自動トリガースケジューラを claudecode の共有ポーリングベースに登録する。各発火（`"IntervalSeconds"` でスロットル）は非ブロッキングで: Poll（完了済み非同期ジョブのファイナライズ） → Tick（有効トリガー評価・ジョブ構築） → DispatchAsync（非同期対応ジョブをサブカーネルに投入） → DispatchWorkflows（オーケストレータが存在する場合）の順で実行する。PromptRoute（メインカーネルブロッキング）は自動ディスパッチしない。AsyncActive 中は defers。サブカーネルプールをここで事前起動してティック中のカーネル起動ブロックを防ぐ。claudecode の共有ポーリングベースが不在の場合は登録せず `"ClaudeCodeAbsent"` を返す。
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
`"PromptRoute"` | `"BlockingSyncUserInitiated"` | `"主カーネル(手動起動)"` | False
その他 | `"Unknown"` | `"不明"` | False

### SourceVaultAutoTriggerListData[] → List
登録済みトリガーごとに UI 用の行 Association を返す（純読み取り・ディスパッチなし）。
各行キー: `TriggerId`, `Name`, `Enabled`, `TargetType`, `TargetId`, `ExecutionMode`, `Placement`（実行PCラベル: `環境非依存` | `pool: <name>` | `固定: <tags>` | `未判定`）, `AutoRunCapability`, `AutoToggle`(ON|OFF|不可), `Priority`, `NextFire`, `LastRunStatus`, `HasError`, `ErrorSummary`（クラウドセーフなメタデータのみ・ルール 90）

### SourceVaultAutoTriggerForTarget[targetType, targetId] → Association | Missing
ターゲットが一致する登録済みトリガーの `SourceVaultAutoTriggerListData` 行を返す（例: カタログスラッグに対する WorkflowTemplate トリガー）。一致するトリガーがない場合は `Missing["NoTrigger"]`。既存のワークフロー / 保存プロンプトリストが per-row で自動実行ステータスを表示するために使用する。

### SourceVaultAutoTriggerStatusCell[targetType, targetId] → 表示式
そのターゲットのトリガーのコンパクトセル（自動トグルバッジ + 優先度 + 警告アイコン）を描画する。トリガーが登録されていない場合はグレーのダッシュを返す。既存リスト Grid に埋め込む用途向け。

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