# SourceVault / ClaudeOrchestrator 自動起動 Scheduler 仕様案 v0.1-r9

作成日: 2026-06-26  
改訂: 2026-06-26 review 反映。既存 `ClaudeRunWorkflow` / `ClaudeRegisterPollingTick` / NBAccess final action queue / SourceVault event log / マルチマシン同期制約に合わせて修正。  
再改訂: 2026-06-26 r1 review 反映。Dropbox lease の限界、per-trigger registry、実行 backend 安全モデル、致命エラー summary、優先度を追加。  
再々改訂: 2026-06-26 r2 review 反映。`SourceVault_diagnostics` を横断 SIEM 層として前提化し、包括診断 workflow を最初の自動実行 workflow として定義。  
第4改訂: 2026-06-26 r3 review 反映。diagnostics gate を component-scoped 化し、doctor を lightweight inline / comprehensive workflow に分離。FE 在席通知優先・メール fallback を追加。  
第5改訂: 2026-06-26 追加要件反映。複数PC共有 SourceVault 向けに、machine-local diagnostics、cloud sync heartbeat、aggregator PC、failover rollup を追加。  
第6改訂: 2026-06-26 追加要件反映。Mathematica 標準運用としての2台構成、追加ライセンス/追加常時稼働PC時の worker 冗長化、workflow / prompt の実行PC配置指定、負荷分散を追加。  
第7改訂: 2026-06-26 追加要件反映。Mathematica 間通信に Wolfram Cloud Channel / ChannelReceiverFunction / CloudExpression / CloudObject を使う cloud communication layer を追加し、SourceVault 更新だけに依存しない heartbeat / negotiation / job wakeup を定義。  
第8改訂: 2026-06-26 r4 review 反映。license capacity を宣言値ではなく `$LicenseProcesses` / `$MaxLicenseProcesses` / `$MaxLicenseSubprocesses` 実測で扱い、Subkernel 優先、job claim / best-effort exactly-once、machine-local gate fallback、clock skew 対策、Cloud listener watchdog、段階導入を追加。  
第9改訂: 2026-06-26 r8 review 反映。MCP 重複カーネルを回収可能 process 枠として能動検出し、単一 gateway 集約推奨・baseline policy・Phase 0 実装スライス・仕様 freeze 方針を追加。  
対象: `SourceVault.wl`, `SourceVault_promptrouter.wl`, `SourceVault_workflowcatalog.wl`, `SourceVault_workflowregistry.wl`, `ClaudeOrchestrator.wl`, `ClaudeOrchestrator_workflow.wl`, `ClaudeOrchestrator_promptworkflow.wl`, `ClaudeRuntime.wl`, `NBAccess.wl`  
位置づけ: SourceVault に保存された PromptRoute / WorkflowRoute / WorkflowTemplate を、安全な自動起動対象として登録・確認・実行するための実装仕様。

---

## 0. 結論

自動起動機能は `cron` そのものを巨大化させず、診断前提層を含む次の5層に分ける。

| 層 | 責務 | 置き場所 |
|---|---|---|
| Diagnostics / SIEM | health probe の集約、構造化ログ、doctor、エスカレーション、通知 | 新規 `SourceVault_diagnostics.wl` |
| Trigger Registry | 「いつ・何が起きたら・どの対象を起動するか」の宣言保存 | SourceVault compiled registry |
| Scheduler / Watcher | 時刻・SourceVault event・Orchestrator event を監視し、条件成立時に job を作る | 新規 `SourceVault_autotrigger.wl` |
| Job Queue | 実行予定・投入済み・完了/失敗観測の job を蓄積する。承認待ち・retry・resume の実体は Orchestrator / NBAccess 側に置く | SourceVault append-only log + current state |
| Executor | PromptRoute / WorkflowRoute / WorkflowTemplate を実行する | ClaudeOrchestrator / ClaudeRuntime / NBAccess |

`cron` 側は条件判定と job 投入までに限定する。  
「ブログ更新が遅れているので1時間待つ」「今日の更新なしとして終了する」「エラー後にどこから再開するか」「GitHub commit や mail 送信を最後にまとめる」といった業務判断は、自動実行対応 workflow 側が扱う。

SourceVault scheduler が持つ状態は trigger / job / event の宣言・観測であり、workflow の place、retry loop、pause / resume、approval waiting を所有しない。これらは ClaudeOrchestrator workflow と NBAccess final action queue の責務である。

包括的診断機構は自動実行の前提であり、最初に自動起動される workflow はユーザー業務 workflow ではなく `SourceVaultSystemDoctor` / `SourceVault_diagnostics` を使った system doctor workflow とする。任意の user workflow の `Enabled -> True` は、diagnostics 最小核が稼働し、その workflow が必要とする component の直近 health が `OK` または許容済み `Degraded` であることを前提にする。

複数PCが同一 SourceVault を共有する環境では、diagnostics は単一PCで全診断を重複実行しない。Mathematica の標準的なサブスクリプションを2台構成の運用前提とみなし、標準構成は「常時稼働PC 1台 + ノートPC 1台」とする。ただし license capacity は「2席」と決め打ちせず、各PCで `$LicenseProcesses` / `$MaxLicenseProcesses` / `$MaxLicenseSubprocesses` を実測して判定する。各PCは自PCが管轄する local component を診断して SourceVault に machine-local report を書き、通常は常時稼働PCが aggregator として global rollup を書く。2台構成では always-on role の真の冗長性はなく、常時稼働PCが落ちてノートPCが sleep していれば自動実行は停止する。3ライセンス以上または常時稼働PCが複数ある場合だけ、headless workflow / prompt の多重化、重いローカルモデル実行の分散、片系停止時の縮退運転を本格的に許可する。

Mathematica 間の低遅延通信・wakeup・ネゴシエーションには Wolfram Cloud の Channel-Based Communication を使える。ただし標準2台構成では既定 off のオプション層とし、SourceVault polling だけで成立する実装を先に作る。SourceVault / Dropbox / OneDrive 更新は durable source of truth と監査ログであり、Wolfram Cloud channel は fast path とする。Wolfram Cloud が使えない場合でも SourceVault polling へ degraded fallback できるよう、全ての cloud message は SourceVault job / diagnostics log に再構成可能な形で反映する。

health 語彙は既存 `SourceVaultServiceHealth` に合わせ、`OK` / `Degraded` / `Failing` を正準とする。`Critical` という語は Priority には使えるが、health 状態としては `Failing` の別名扱いに留める。

---

## 1. 設計原則

### 1.1 Scheduler は薄くする

Scheduler が行うこと:

- 時計・SourceVault event・Orchestrator event の監視
- TriggerSpec の validation
- 条件成立判定
- 多重起動抑止
- job queue への投入
- 実行 backend の可否確認
- 実行開始 API の呼び出し
- 実行履歴・失敗理由の記録

Scheduler が行わないこと:

- Web ページ更新遅延の業務判断
- 対象 source の内容解釈
- LLM での要約作成
- GitHub commit / mail 送信などの副作用の即時実行判断
- workflow 内 checkpoint / retry / resume の詳細判断
- 失敗した workflow の内部修復

### 1.2 自動実行は既定で opt-in

PromptRoute / WorkflowRoute / WorkflowTemplate は、保存されただけでは自動起動されない。

自動起動には次をすべて満たす必要がある。

1. TriggerSpec が registry に保存されている。
2. `Enabled -> True` である。
3. target の `AutoRunCapability` が `HeadlessAsync` または `HeadlessWithApproval` である。
4. NBAccess validation が `Permit` または事前承認済み `NeedsApproval` である。
5. 同じ trigger / target の concurrency policy に違反しない。
6. 自動 dispatch backend が主カーネルを占有しない別プロセス系である。

`FrontendRequired` / `ContextBound` target は registry に条件を保存できるが、tick から自動実行しない。FE 操作は final action として分離し、ユーザーがメインカーネル上の承認ボタンを評価した時だけ実行される。

`MainKernelAsync` は「安全な背景実行」とみなさない。自動 tick からの background dispatch は `SubkernelAsync` または `WolframScriptProcess` に限定する。主カーネル同期で走らせたい処理は、一覧で「主カーネルブロック（約N分・手動起動）」として明示し、ユーザーがボタンを押した場合だけ実行する。

### 1.3 Prompt から構成できるが、保存前に構造化確認する

ユーザーは次のように自然言語で指定できる。

```text
毎週金曜日の03:00に、sv://source/blog/foo が更新されていたら、
workflow:daily-blog-summary を起動する。ただし同じ日には1回だけ。
```

LLM はこの prompt を `TriggerSpec` に変換する。  
保存前には必ず以下を表示して、ユーザーが確認する。

- 人間向け説明
- 起動対象
- 日時条件
- SourceVault / Orchestrator 条件
- 自動実行可否
- 必要な承認
- 副作用リスク
- 次回予定時刻の preview

---

## 2. 新規ファイル

### 2.1 `SourceVault_autotrigger.wl`

SourceVault の extension として追加する。`SourceVault_promptrouter.wl` と同じ方針で、本体ロードを壊さない。

公開 API:

```wl
SourceVaultAutoTriggerStatus[]
SourceVaultRegisterAutoTrigger[spec_Association, opts]
SourceVaultListAutoTriggers[opts]
SourceVaultGetAutoTrigger[triggerId_String]
SourceVaultUpdateAutoTrigger[triggerId_String, patch_Association]
SourceVaultDeleteAutoTrigger[triggerId_String, opts]
SourceVaultSetAutoTriggerEnabled[triggerId_String, enabled_]
SourceVaultExplainAutoTrigger[specOrId_]
SourceVaultPreviewAutoTrigger[specOrId_, opts]
SourceVaultParseAutoTriggerPrompt[prompt_String, target_Association, opts]
SourceVaultValidateAutoTrigger[spec_Association, opts]
SourceVaultAutoTriggerTick[opts]
SourceVaultAutoTriggerJobQueue[opts]
SourceVaultAutoTriggerJobStatus[jobId_String]
SourceVaultCancelAutoTriggerJob[jobId_String]
SourceVaultRetryAutoTriggerJob[jobId_String, opts]
SourceVaultAutoTriggerSendCloudMessage[msg_Association, opts]
SourceVaultAutoTriggerHandleCloudMessage[msg_Association, opts]
```

内部 API:

```wl
iSVATNow[]
iSVATMatchScheduleQ[scheduleSpec_, now_, state_]
iSVATMatchConditionQ[conditionSpec_, context_, state_]
iSVATTargetCapability[target_]
iSVATEnqueueJob[trigger_, context_]
iSVATDispatchJob[job_]
iSVATRecordEvent[event_]
```

### 2.2 `SourceVault_diagnostics.wl`

自動実行に先行して導入する横断 diagnostics / SIEM 層。診断ロジックそのものを集中所有せず、各 producer package が持つ probe / health 判定 / log を弱参照で集約し、保存・マイニング・可視化・エスカレーションを担う。

公開 API 草案:

```wl
SourceVaultSystemDoctor[opts]
SourceVaultDiagnosticsRegisterProbe[id_String, probeFn_]
SourceVaultDiagnosticsLog[record_Association]
SourceVaultDiagnosticsStatus[opts]
SourceVaultDiagnosticsEscalate[event_Association]
SourceVaultDiagnosticsAcknowledge[id_String]
SourceVaultDiagnosticsPanel[]
SourceVaultDiagnosticsSinkAvailableQ[]
SourceVaultDiagnosticsMachineHeartbeat[opts]
SourceVaultDiagnosticsMachineReport[opts]
SourceVaultDiagnosticsRollup[opts]
SourceVaultDiagnosticsActiveAggregator[]
SourceVaultDiagnosticsLicenseProbe[opts]
SourceVaultDiagnosticsKernelProcessTopology[opts]
SourceVaultDiagnosticsReclaimableCapacity[opts]
SourceVaultDiagnosticsCloudCommsStatus[opts]
SourceVaultDiagnosticsCloudHeartbeat[opts]
SourceVaultDiagnosticsCloudRoundTripProbe[opts]
SourceVaultDiagnosticsCloudReceiverDeploy[opts]
```

役割:

- NBAccess / claudecode / Orchestrator / PDFIndex / SourceVault service manager / auto-trigger など producer の probe を弱参照で呼ぶ。
- `SourceVaultServiceHealth`, `SourceVaultServiceDoctor`, `SourceVaultLocalConfigDoctor`, `SourceVaultNoPersonalConfigDoctor`, `SourceVaultMCPRunningQ` など既存 doctor 部品を再利用する。
- WolframScript independent process / subkernel subprocess availability probe を提供し、auto-trigger dispatch 前 check と共有する。
- process 枠の内訳を分類し、重複 MCP kernel などの回収可能 capacity を `ReclaimableMCPKernels` / `ReclaimableProcessSlots` として診断する。
- machine heartbeat / cloud sync round-trip / aggregator rollup を管理する。
- Wolfram Cloud channel heartbeat / ack / receiver / CloudExpression coordination state を管理する。
- structured diagnostics log を append-only に保存し、reason code / machine tag / component / severity / health を統合する。
- High / Critical な auto-trigger failure や doctor `Failing` を escalation policy に渡す。

producer は SourceVault に hard dependency を持たない。`SourceVaultDiagnosticsSinkAvailableQ[]` または `Names[]` / `ValueQ` で sink 存在を弱判定し、存在しなければ diagnostics emit は no-op とする。これにより NBAccess 等の単体利用を壊さない。

### 2.3 自動ロード

`SourceVault.wl` 末尾で `SourceVault_promptrouter.wl` と同じ弱い auto-load を行う。

条件:

- `Needs["ClaudeRuntime`"]` / `Needs["ClaudeOrchestrator`"]` は自動実行しない。
- Runtime / Orchestrator availability は実行時に弱参照で判定する。
- ロード失敗は `SourceVault` 本体ロード失敗にしない。
- `Get` の複数回実行に対して idempotent。

---

## 3. 保存形式

### 3.1 TriggerSpec

TriggerSpec は SourceVault compiled registry に保存する。ただしマルチマシン lost-update を避けるため、正本は trigger 単位のファイルにする。

推奨 path:

```text
compiled/auto-triggers/<triggerId>.wl
```

1件の schema:

```wl
<|
  "Type" -> "AutoTrigger",
  "SchemaVersion" -> "0.1",
  "TriggerId" -> "autotrg-...",
  "Name" -> "毎朝ブログ要約",
  "Description" -> "...",
  "Target" -> <|
    "TargetType" -> "PromptRoute" | "WorkflowRoute" | "WorkflowTemplate",
    "TargetId" -> "...",
    "TargetURI" -> "sv://workflow/...",
    "DisplayName" -> "..."
  |>,
  "Enabled" -> False,
  "Owner" -> <|
    "Mode" -> "OwnerMachine" | "Lease",
    "OwnerMachineTag" -> Automatic,
    "LeaseTTLSeconds" -> 300
  |>,
  "Schedule" -> <| ... |>,
  "Condition" -> <| ... |>,
  "RunPolicy" -> <| ... |>,
  "ExecutionPolicy" -> <| ... |>,
  "ExecutionPlacement" -> <|
    "Mode" -> "EnvironmentIndependent" | "WorkerPool" | "SpecificMachine",
    "WorkerPool" -> "default-headless",
    "AllowedMachineTags" -> Automatic,
    "RequiredMachineTags" -> {},
    "PreferredMachineTags" -> {},
    "RequiredCapabilities" -> {"HeadlessAsync"},
    "ResourceHints" -> <|"LocalModel" -> Missing["None"], "EstimatedGPUVRAMGB" -> Missing["Unknown"]|>,
    "Failover" -> True,
    "LoadBalance" -> "LeastBusy" | "RoundRobin" | "PriorityThenLeastBusy"
  |>,
  "SafetyPolicy" -> <| ... |>,
  "RecoveryPolicy" -> <| ... |>,
  "DiagnosticsPolicy" -> <|
    "RequireDiagnosticsReady" -> True,
    "GateMode" -> "ComponentScoped",
    "RequiredComponents" -> Automatic,
    "RequiredHealth" -> "OK" | "DegradedAccepted",
    "LightweightFreshness" -> Quantity[5, "Minutes"],
    "ComprehensiveFreshness" -> Quantity[24, "Hours"],
    "EmitToDiagnostics" -> True,
    "EscalationProfile" -> Automatic
  |>,
  "PromptSource" -> <|
    "OriginalPromptStorage" -> "HashOnly" | "PrivateRaw" | "None",
    "OriginalPromptHash" -> "...",
    "ParsedBy" -> <|"Provider" -> "...", "Model" -> "..."|>
  |>,
  "Validation" -> <| ... |>,
  "ExpiresAt" -> Missing["None"],
  "ActiveWindow" -> All,
  "EnabledAudit" -> {},
  "LastSeen" -> <|"OwnerMachineTag" -> "...", "At" -> "..."|>,
  "LastError" -> Missing["None"],
  "LastDoctor" -> <|
    "GlobalHealth" -> "OK" | "Degraded" | "Failing",
    "Components" -> <|
      "NBAccessKeys" -> <|"Health" -> "OK", "At" -> "..."|>,
      "KernelSeat" -> <|"Health" -> "OK", "At" -> "..."|>
    |>,
    "At" -> "..."
  |>,
  "CreatedAt" -> "...",
  "UpdatedAt" -> "...",
  "CreatedBy" -> "User" | "WorkflowSpecGenerator"
|>
```

`OwnerMachineTag -> Automatic` は `Enabled -> True` を実行したマシンの tag に解決し、その事実を `EnabledAudit` に残す。登録だけでは owner を暗黙確定しない。

`ExecutionPlacement` は「どのPCで実行できるか」を表し、`Owner` は「誰が trigger 判定と job 投入を所有するか」を表す。両者を混同しない。標準2台構成では、多くの `EnvironmentIndependent` / `WorkerPool` target は常時稼働PCに配置される。3ライセンス以上で常時稼働 worker が複数ある場合だけ、`WorkerPool` による load balance / failover を本格的に使う。

配置 mode:

| Mode | 意味 |
|---|---|
| `EnvironmentIndependent` | PC環境に依存しない。registry / diagnostics が許す任意の always-on worker で実行できる |
| `WorkerPool` | 指定 pool に属する複数PCの中から scheduler が選ぶ。重いローカルモデルなどは pool / capability / capacity で絞る |
| `SpecificMachine` | 特定PCの resource / credential / notebook / device に依存する。指定PC以外では実行しない |

`SpecificMachine` の場合は `RequiredMachineTags` を空にしてはならない。`EnvironmentIndependent` でも credential / privacy / network scope の評価結果により、実行可能 machine が実質的に絞られることがある。

### 3.1.1 Registry 書き込み粒度

`compiled/auto-trigger-registry.wl` のような単一巨大ファイルを全マシンが read-modify-write すると、Dropbox conflict copy により lost-update が起きる。実装では trigger 単位のファイルを正とする。

```text
compiled/auto-triggers/<triggerId>.wl
compiled/auto-triggers/index.wl     optional, read-only cache
```

一覧用 index / compacted registry は cache とし、再生成可能にする。trigger 定義の真実源は per-trigger file または append-only operation log とする。compact / index 更新は単一 owner machine の保守タスクに限定し、通常の enable / disable / update が他 trigger を巻き込まないようにする。

### 3.2 Event log

高頻度イベントは append-only JSONL に保存する。ただし SourceVault の ingest / update / delete / schema change 等の source event は、既存の `<PrivateVault>/events/source-events.jsonl` を正準ソースとする。`autotrigger/events.jsonl` は scheduler 自身の観測ログに限定する。

```text
autotrigger/events.jsonl
autotrigger/jobs.jsonl
autotrigger/runs.jsonl
events/source-events.jsonl
```

用途:

- `events/source-events.jsonl`: SourceVault source event の正準ログ
- `autotrigger/events.jsonl`: schedule match / condition match / enqueue skip など Scheduler の観測イベント
- `jobs.jsonl`: job の作成・遅延・開始・終了・取消
- `runs.jsonl`: target 実行結果の summary、run id、checkpoint pointer

compiled registry には最新定義だけを置き、実行履歴を混ぜない。

### 3.3 Diagnostics bootstrap

自動実行の安全化は、scheduler より先に diagnostics が動くことを前提にする。diagnostics は二階層に分ける。

#### 軽量診断

軽量診断は共有 tick 内で実行できる純粋・短時間の check であり、新しい kernel / WolframScript を spawn しない。

対象:

- heartbeat 鮮度 / pid alive / stale running
- 直近 error rate
- owner machine last-seen
- 直近 comprehensive doctor の鮮度
- component health cache の期限切れ

軽量診断は scheduler に依存せず Phase 0 から動く。これにより「gate はあるが doctor を回す手段が無い」空白を作らない。

#### 包括診断 workflow

Phase 0 の最初の自動実行 workflow は、低頻度の包括診断である。

```text
workflow: sourcevault-system-doctor-autotrigger
target: SourceVaultSystemDoctor[]
schedule: 起動時 + 24時間ごと（既定）
priority: Critical
backend: SubkernelAsync または WolframScriptProcess
effect: read-only diagnostics
```

包括診断 workflow は、ユーザー業務 workflow を起動するための前提条件を点検する。頻繁に kernel を spawn して license process / subprocess 枠を圧迫しないよう、既定頻度は24時間ごととし、軽量診断が「包括診断の鮮度」を監視する。

- SourceVault roots / registry / per-trigger files
- SourceVault service health (`OK` / `Degraded` / `Failing`)
- MCP service liveness (`PidAlive` / heartbeat / `/health`)
- NBAccess keys / credential backend / privacy gate
- ClaudeRuntime / ClaudeOrchestrator availability
- WolframScript independent process / subkernel subprocess availability probe
- LM Studio / local model availability
- GitHub token / mail notification config / optional PDFIndex dependencies

任意の user trigger を `Enabled -> True` にする前に、必要 component の直近 doctor result が必要である。既定では必要 component がすべて `OK` のときだけ自動 dispatch を許可する。`Degraded` はユーザーが component ごとに accept した場合のみ許可する。関連 component が `Failing` の場合は High / Critical を含めてその workflow を dispatch しない。system doctor workflow 自身だけは例外として、`Failing` 状態でも実行を試みて診断を更新できる。

Global health が `Failing` でも、無関係 component の故障だけで全 user workflow を止めない。gate は workflow の `ExecutionPolicy` / `NetworkScope` / `CredentialRefs` / `FinalActionClasses` / backend から導出した required components に限定して適用する。

マルチPC構成では、global rollup を gate の単一 SPOF にしない。実行予定 machine 自身の required component（例: `Machine:<MachineTag>`, `CloudSync:<MachineTag>`, `WolframCloudAuth:<MachineTag>`, local model, credential backend, local kernel）は、その machine の machine-local report を優先して判定する。global rollup は cross-machine 情報、他PCの availability、worker pool の全体 view、通知用 summary に使う。global rollup が stale / split-brain / aggregator failover 中でも、自PCの machine-local report が required component を満たす `SpecificMachine` job または自PC配置済み job は dispatch できる。rollup stale を理由に全 user workflow を hard-block しない。

doctor 自身の停止検出も diagnostics の対象にする。軽量診断は包括診断 workflow の最終実行時刻と heartbeat を監視し、必要なら `DoctorStale` / `DoctorNotRunning` を diagnostics event として出す。外部 watchdog を導入する場合も、この health 語彙へ正規化する。

### 3.4 Multi-machine diagnostics topology

同一 SourceVault を複数PCが共有する場合、diagnostics は federated model とする。

標準 topology:

| 構成 | 前提 | 役割 |
|---|---|---|
| 標準2台構成 | Mathematica 標準サブスクリプションで実運用しやすい2台構成。license 枠は席数ではなく各PCで実測 | 常時稼働PC 1台を primary aggregator / primary worker、ノートPC 1台を intermittent worker / standby aggregator とする |
| 拡張3台以上構成 | 3ライセンス以上、または常時稼働PCを追加できる場合。license 枠は per-machine か global 共有かを実測で確定 | 常時稼働 worker PC を複数登録し、負荷分散・冗長化・重いローカルモデル workflow の分散を行う |

標準2台構成では、ノートPCは sleep / 持ち出し / 同期停止がありうる補助ノードとして扱い、通常の headless 自動実行は常時稼働PCに寄せる。ノートPCにしかない資源を使う workflow だけ、そのノートPCを required machine として指定する。2台構成では always-on role の自動 failover は best-effort であり、真の冗長化は常時稼働PCが2台以上ある拡張構成で扱う。

拡張3台以上構成では、複数の常時稼働PCを `WorkerPool` として扱える。片方が落ちた場合は残りのPCで queue を縮退処理する。ただし Mathematica license process / subprocess 枠、local model VRAM、credential、device、notebook context は machine-local resource でありうる。license 枠が per-machine か複数PC共有かは `$LicenseProcesses` / `$MaxLicenseProcesses` / `$MaxLicenseSubprocesses` の実測で確定し、配置可能性は workflow / prompt の `ExecutionPlacement` と machine registry の capability intersection で決める。

| 役割 | 責務 |
|---|---|
| Machine agent | 各PCで稼働し、自PCの heartbeat / cloud sync / local components を診断して machine-local report を書く |
| Aggregator | machine-local report 群を読み、global rollup / system health を SourceVault に書く |
| Standby aggregator | primary aggregator が stale / offline / sync failing の場合に rollup を代行する候補 |

各PCの診断範囲は、そのPCでしか正しく見られないものに限定する。

- local Wolfram kernel / WolframScript / license process / subkernel subprocess availability
- local LM Studio / local model endpoint
- local SourceVault service / MCP proxy
- local Dropbox / OneDrive sync state
- local NBAccess credential backend / key availability
- local FE presence / notebook availability

Aggregator は原則として local probe を再実行しない。各PCの report を読み、component health を集約し、conflict / stale / missing を検出する。

#### 3.4.1 Machine registry

関与するPCは machine registry に登録する。

```wl
<|
  "MachineTag" -> "ProArtPX13",
  "DisplayName" -> "ProArt PX13",
  "Roles" -> {"Worker", "AggregatorCandidate"},
  "AggregatorPriority" -> 10,
  "ExpectedAvailability" -> "AlwaysOn" | "Intermittent" | "Manual",
  "ManagedComponents" -> {"LocalKernel", "LMStudio", "MCPProxy"},
  "WorkerPools" -> {"default-headless", "local-llm-heavy"},
  "ExecutionCapabilities" -> {
    "HeadlessAsync",
    "WolframScriptProcess",
    "SubkernelAsync",
    "LocalModel:llama-70b-q4"
  },
  "ResourceCapacity" -> <|
    "MaxConcurrentJobs" -> 2,
    "ReservedCriticalSlots" -> 1,
    "LicenseAccounting" -> "ObservedPerMachine" | "ObservedGlobalPool" | "Unknown",
    "ObservedLicense" -> <|
      "LicenseType" -> Missing["Unmeasured"],
      "LicenseProcesses" -> Missing["Unmeasured"],
      "MaxLicenseProcesses" -> Missing["Unmeasured"],
      "MaxLicenseSubprocesses" -> Missing["Unmeasured"],
      "MeasuredAtUTC" -> Missing["Unmeasured"]
    |>,
    "SubkernelBudget" -> <|"AutoTriggerMax" -> Automatic, "CriticalReserved" -> 1|>,
    "ProcessBudget" -> <|"AutoTriggerMax" -> 0, "CriticalReserved" -> 0|>,
    "LocalModelSlots" -> <|"llama-70b-q4" -> 1|>
  |>,
  "CloudSyncProvider" -> "Dropbox" | "OneDrive" | "Other",
  "WolframCloudComms" -> <|
    "Enabled" -> False,
    "CloudBase" -> Automatic,
    "ChannelNamespace" -> "sourcevault/<VaultId>",
    "UseChannelListen" -> True,
    "UseCloudReceiver" -> True,
    "CloudStateObject" -> "cloud://sourcevault/<VaultId>/coordination",
    "AckTimeoutSeconds" -> 30
  |>,
  "HeartbeatIntervalSeconds" -> 60,
  "StaleAfterSeconds" -> 300,
  "FailoverAfterSeconds" -> 600
|>
```

ノートPCなど sleep しうる端末は `ExpectedAvailability -> "Intermittent"` とする。これにより、heartbeat stale を即 `Failing` とせず `OfflineOrSleeping` / `OwnerOffline` として扱える。

Mathematica license は machine registry の宣言値を信じない。lightweight diagnostics / comprehensive diagnostics は各PCで `$LicenseProcesses` / `$MaxLicenseProcesses` / `$MaxLicenseSubprocesses` を実測し、`ObservedLicense` を上書きする。dispatch 前 check はこの実測値だけを見る。`WolframScriptProcess` は independent process 枠を消費し、`SubkernelAsync` は subprocess 枠を消費するため、会計上は必ず分離する。

headless 自動実行は既定で `SubkernelAsync` を優先し、`WolframScriptProcess` は subprocess が使えない場合、隔離が必要な場合、または workflow が明示要求する場合の fallback とする。`$MaxLicenseProcesses` が大きくても、MCP gateway / SourceVault service kernel / FE / evaluation kernel が process 枠を使い切ることがあるため、process 枠は予約値でなく実測空きで判断する。`$MaxLicenseSubprocesses` が十分でも、メモリや `$ClaudeParallelKernelCount` などの local policy で subkernel 数を絞る。

diagnostics は process 枠の生カウントだけでなく、内訳を分類する。特に同一 vault / 同一 user session で `AgentTools StartMCPServer` 系の native stdio MCP kernel が複数立っている場合、単一共有 gateway (`wlmcp-gateway` など) に集約すれば回収できる process 枠として扱う。

```wl
"ProcessTopology" -> <|
  "ObservedProcesses" -> {
    <|"Class" -> "FrontEndEvaluationKernel", "Count" -> 1|>,
    <|"Class" -> "SourceVaultServiceKernel", "Count" -> 1|>,
    <|"Class" -> "MCPGatewayKernel", "Count" -> 1|>,
    <|"Class" -> "AgentToolsStartMCPServerKernel", "Count" -> 2|>
  },
  "ReclaimableMCPKernels" -> <|
    "Count" -> 1,
    "Reason" -> "Multiple native stdio MCP kernels; use single shared gateway",
    "Recommendation" -> "Route MCP clients through wlmcp-gateway"
  |>,
  "ReclaimableProcessSlots" -> 1
|>
```

Comprehensive doctor の baseline policy は「headless 自動実行用に常時1 process 枠以上を回収または確保できること」とする。実測 process 枠が飽和していても、重複 MCP kernel などの回収可能 slot がある場合は `Degraded` として具体的な回収推奨を出す。回収可能性がなく process 枠が飽和している場合は `Failing` とし、`WolframScriptProcess` fallback を使う workflow を dispatch しない。通常の `SubkernelAsync` dispatch は subprocess / memory policy を別に見る。

複数PCが license pool を共有しているか、activation ごとに独立しているかは仮定しない。各PCの実測値と dispatch 成否を diagnostics に蓄積し、per-machine pool と判定できる場合は machine-local capacity として扱い、global 共有の兆候がある場合は global license pool component を作って保守的に dispatch する。

`ExpectedAvailability -> "AlwaysOn"` のPCだけを通常の負荷分散対象にする。`Intermittent` PC は、明示的に required machine とされた workflow、ユーザーがそのPC上で `Enabled -> True` にした owner machine workflow、または failover 時の standby aggregator として使う。

#### 3.4.2 Machine heartbeat

各PCは trigger registry とは別に、自分専用 path へ heartbeat を書く。PCごとに別 path なので Dropbox conflict を避ける。

```text
diagnostics/machines/<MachineTag>/heartbeat.json
diagnostics/machines/<MachineTag>/local-report.jsonl
diagnostics/machines/<MachineTag>/sync-probes/<probeId>.json
```

heartbeat schema:

```wl
<|
  "Type" -> "MachineHeartbeat",
  "MachineTag" -> "...",
  "Sequence" -> 12345,
  "WrittenAtUTC" -> "...",
  "LocalMonotonicSeconds" -> 123456.7,
  "SourceVaultRootDigest" -> "...",
  "CloudSyncProvider" -> "Dropbox",
  "LocalSyncStatus" -> "Unknown" | "OK" | "Degraded" | "Failing",
  "ObservedRollupId" -> "...",
  "ObservedRollupAtUTC" -> "...",
  "LastAggregatorAck" -> <|"ProbeId" -> "...", "AtUTC" -> "..."|>,
  "LocalComponents" -> <|
    "LocalKernel" -> "OK",
    "LMStudio" -> "Degraded"
  |>
|>
```

heartbeat は liveness と cloud sync health の両方を担う。ただし「自分がローカルに書けた」だけではクラウド同期成功を意味しない。

マシン間 freshness 判定では、各PCが自己申告する `WrittenAtUTC` を直接比較しない。clock skew を避けるため、aggregator / receiver が観測した `ObservedAtUTC` と per-machine `Sequence` の単調増加を正準にする。`LocalMonotonicSeconds` は同一PC内の restart / stall 検出にだけ使う。

#### 3.4.3 Cloud storage sync health

Dropbox / OneDrive 同期停止は自動実行に直結する障害として診断対象にする。cloud sync health は双方向観測で判定する。

1. 各PCは自分の heartbeat / sync probe を machine-local path に書く。
2. Aggregator はそれを観測したら rollup または ack に `MachineTag`, `Sequence`, `ProbeId`, `ObservedAtUTC` を記録する。
3. 各PCは aggregator ack / rollup が自分のローカル同期フォルダへ戻ってくるかを見る。

判定:

| 状態 | 意味 |
|---|---|
| `CloudSyncOK` | 自分の heartbeat が aggregator に観測され、ack / rollup が戻ってきている |
| `LocalWritesOnly` | 自分は書けるが aggregator ack が返らない。ローカル同期停止または aggregator 不在の疑い |
| `RemoteNotSeeingThisMachine` | aggregator 側でその machine heartbeat が stale。対象PCのsleep / network / sync停止 |
| `RollupStaleLocally` | 自PCが最新 rollup を受け取れていない。自PCの受信同期停止の疑い |
| `CloudSyncFailing` | stale が閾値を超え、自動実行に使えない |

cloud storage の健全性は component health として `CloudSync:<MachineTag>` に保存する。workflow が特定PCで実行される場合、そのPCの `CloudSync` が required component になる。

stale / fresh の比較は aggregator が観測した `ObservedAtUTC` を基準に行う。複数 aggregator / receiver がある場合は、同一 rollup 内では同一観測者の時計で比較し、観測者が異なる timestamp を直接順位付けに使わない。

#### 3.4.4 Aggregator election / failover

Aggregator は machine registry の `AggregatorPriority` と heartbeat freshness から決める。

基本:

1. `AggregatorCandidate` role を持つPCだけが aggregator になれる。
2. 最も priority が高く、heartbeat が fresh で、`CloudSync:<MachineTag>` が `OK` または accept 済み `Degraded` のPCを active aggregator とする。
3. primary が `FailoverAfterSeconds` を超えて stale / sync failing になったら、次の候補が rollup を書く。

Dropbox / OneDrive は分散ロックではないため、aggregator election は強い単一 leader 保証をしない。split brain rollup は起こりうる。これを destructive action に使わず、diagnostics rollup の冪等な生成に限定する。

複数 rollup が存在する場合、consumer は次の deterministic rule で採用する。

1. `RollupEpoch` が最大
2. `GeneratedAtUTC` が新しい
3. `AggregatorPriority` が高い
4. `MachineTag` の辞書順

競合 rollup を検出した場合は `SplitBrainRollup` diagnostics event として記録する。

rollup path:

```text
diagnostics/rollups/<RollupEpoch>/<MachineTag>-<timestamp>.wl
diagnostics/rollups/current.wl      cache only
```

`current.wl` は cache であり、真実源は immutable rollup files とする。

#### 3.4.5 Global rollup schema

```wl
<|
  "Type" -> "DiagnosticsRollup",
  "RollupId" -> "...",
  "RollupEpoch" -> 42,
  "AggregatorMachineTag" -> "...",
  "GeneratedAtUTC" -> "...",
  "MachineHealth" -> <|
    "ProArtPX13" -> <|"Health" -> "OK", "LastSeenUTC" -> "...", "CloudSync" -> "OK"|>,
    "StrixHalo128" -> <|"Health" -> "OfflineOrSleeping", "LastSeenUTC" -> "...", "CloudSync" -> "Unknown"|>
  |>,
  "ComponentHealth" -> <|
    "CloudSync:ProArtPX13" -> <|"Health" -> "OK"|>,
    "KernelSeat:ProArtPX13" -> <|"Health" -> "Degraded"|>
  |>,
  "GlobalHealth" -> "OK" | "Degraded" | "Failing",
  "Conflicts" -> {},
  "SourceReports" -> {...}
|>
```

Global rollup は表示・gate・通知の入力になる。ただし gate は global health だけでなく required component health を見る。

### 3.5 Wolfram Cloud communication layer

Dropbox / OneDrive の SourceVault 更新だけで machine 間通信を行うと、同期停止・遅延・conflict copy によって heartbeat / negotiation / job wakeup が遅れる。Mathematica 間の通信には Wolfram Cloud の Channel-Based Communication を併用する。

役割分担:

| 経路 | 役割 | 永続性 |
|---|---|---|
| Wolfram Cloud Channel | 低遅延 heartbeat、job wakeup、ack、aggregator election hint、diagnostics event の即時通知 | fast path。受信確認はアプリ側 ack が必要 |
| ChannelReceiverFunction | cloud 側の軽量 broker / ack receiver / relay。ローカルPCが listening していない時も受信入口になる | cloud object として配置できるが、重い診断は行わない |
| CloudExpression / CloudObject | leader hint、latest rollup pointer、channel registry、small coordination state | 準 durable state。SourceVault の正本を置き換えない |
| SourceVault files / logs | trigger / job / diagnostics の正本、監査、再実行可能な evidence | durable source of truth |

基本方針:

- cloud channel は SourceVault polling の置き換えではなく、wake-up / negotiation / freshness acceleration として使う。
- cloud message は private prompt / credential / source 本文を含めない。message には `JobId`, `TriggerId`, `MachineTag`, `Sequence`, hash, SourceVault URI pointer だけを入れる。
- `ChannelSend` が返っても相手の処理完了を意味しないため、必ず application-level ack を使う。
- `ChannelListen` listener は Mathematica session の寿命に依存するため、常時稼働PC以外では missed message を前提に設計する。missed message は SourceVault polling で回復する。
- `ChannelListen` listener の死活は cloud outage とは別 component として診断する。常時稼働PCで listener が死んだ場合は `ChannelListener:<MachineTag>` を `Failing` にし、watchdog で再起動を試みる。
- Wolfram Cloud outage / auth failure / rate limit 時は `WolframCloudComms` component を `Degraded` または `Failing` にし、SourceVault-only mode へ落とす。

推奨 channel:

```text
sourcevault/<VaultId>/heartbeat
sourcevault/<VaultId>/diagnostics
sourcevault/<VaultId>/jobs
sourcevault/<VaultId>/acks
sourcevault/<VaultId>/election
```

message schema:

```wl
<|
  "Type" -> "Heartbeat" | "JobIntent" | "JobAck" | "DiagnosticsEvent" | "ElectionHint",
  "SchemaVersion" -> "0.1",
  "VaultId" -> "...",
  "MessageId" -> "...",
  "Sequence" -> 123,
  "FromMachineTag" -> "...",
  "ToMachineTag" -> All | "...",
  "AtUTC" -> "...",
  "Body" -> <|
    "JobId" -> "...",
    "TriggerId" -> "...",
    "RollupId" -> "...",
    "SourceVaultURI" -> "sv://...",
    "Digest" -> "..."
  |>,
  "AckRequired" -> True | False,
  "ExpiresAtUTC" -> "..."
|>
```

`Body` は privacy-safe な pointer に限定する。受信側は `MessageId` / `Digest` / `SourceVaultURI` を使って SourceVault の正本を読み、validation 後に処理する。cloud message を直接 `ToExpression` しない。

#### 3.5.1 Cloud heartbeat and wakeup

各PCは machine-local heartbeat file に加えて、Wolfram Cloud heartbeat channel に軽量 heartbeat を送る。

```wl
<|"Type" -> "Heartbeat",
  "FromMachineTag" -> "AlwaysOn-1",
  "Sequence" -> 12345,
  "LocalHealthDigest" -> "...",
  "ObservedRollupId" -> "...",
  "SourceVaultHeartbeatURI" -> "sv://diagnostics/machines/AlwaysOn-1/heartbeat"|>
```

Aggregator は channel heartbeat を使って stale 判定を早める。ただし final な health 判定は SourceVault heartbeat / diagnostics report / CloudExpression state を照合して決める。channel heartbeat だけで `OK` にしない。

job dispatch では、owner / aggregator が SourceVault job intent を書いた後、`sourcevault/<VaultId>/jobs` channel に `JobIntent` を送る。dispatch 先 machine は channel を受けたら即 SourceVault job を読み、`JobAck` を返す。channel を受け損ねた場合でも、dispatch 先 machine の tick が SourceVault polling で拾う。

#### 3.5.2 Cloud broker / receiver

常時稼働PCが落ちていても ack 入口を失わないよう、必要なら `ChannelReceiverFunction` を Wolfram Cloud に配置する。

用途:

- heartbeat / job ack の受信時に CloudExpression の last-seen を更新する
- 最新 rollup pointer を CloudObject / CloudExpression に保存する
- active aggregator の election hint を保存する
- emergency notification event を記録する

禁止:

- private prompt / source 本文 / credential を cloud receiver に送る
- local-only resource の診断を cloud receiver に任せる
- Cloud receiver から Git commit / mail / destructive action を直接実行する

Cloud receiver はローカルPCの代替 executor ではなく、message broker / coordination helper である。

listener 復帰時は CloudExpression / CloudObject の last-seen と SourceVault job log を照合し、missed `JobIntent` / diagnostics event を取り込む。Cloud receiver がある場合でも、蓄積状態は pointer / digest に限定し、SourceVault 正本を読んでから処理する。

#### 3.5.3 Cloud coordination state

小さな coordination state は CloudExpression または CloudObject に置ける。

```wl
<|
  "VaultId" -> "...",
  "ActiveAggregatorHint" -> "AlwaysOn-1",
  "AggregatorEpoch" -> 42,
  "MachineLastSeen" -> <|
    "AlwaysOn-1" -> <|"AtUTC" -> "...", "Sequence" -> 12345|>,
    "Laptop-1" -> <|"AtUTC" -> "...", "Sequence" -> 330|>
  |>,
  "LatestRollupURI" -> "sv://diagnostics/rollups/42/...",
  "LatestRollupDigest" -> "...",
  "ChannelNames" -> {...}
|>
```

Cloud coordination state は election の hint であり、SourceVault immutable rollup / machine report より優先しない。Cloud state と SourceVault state が矛盾した場合は、diagnostics event `CloudCoordinationConflict` を記録し、destructive action には使わない。

#### 3.5.4 Security / permissions

- channel / CloudObject は vault ごとに namespace を分ける。
- channel send / receive permission は関与PCの Wolfram ID または専用 service identity に限定する。
- message は WXF / JSON 相当の Association とし、任意コードを含めない。
- high privacy trigger では human-readable `sv://...` を cloud message に載せず、opaque pointer / hash / short-lived token を使う。受信側は SourceVault 内の private mapping で解決する。
- `MessageId` と `DispatchSlotKey` で idempotency を確保する。
- ack timeout を超えた `High` / `Critical` job は `CloudAckTimeout` として diagnostics に出すが、SourceVault polling fallback を試す。
- Wolfram Cloud token / auth state は `WolframCloudAuth:<MachineTag>` component として診断する。
- local listener の死活は `ChannelListener:<MachineTag>` component として診断し、SourceVault service / MCP proxy と同じ watchdog 管理対象にする。

#### 3.5.5 Useful applications

Wolfram Cloud communication layer は次に使う。

- SourceVault sync が遅い時でも job intent を即時に worker へ知らせる
- ノートPCが起動した瞬間に missed job / diagnostics request を受け取る
- aggregator failover の候補に、primary stale を早く知らせる
- local model worker の busy / free を軽量に共有し、重い workflow を空きPCへ振る
- user-visible diagnostics status を Wolfram Cloud 経由で別PCにも即時反映する
- SourceVault cloud sync round-trip 自体の診断と、Wolfram Cloud channel round-trip の診断を比較し、障害箇所を切り分ける

### 3.6 Diagnostics escalation とメール通報

AutoTrigger はメールを直接送らない。致命系 event を diagnostics sink に emit し、`SourceVault_diagnostics` が escalation policy に従って通知する。

通知の優先順は presence-aware とする。

1. FE 在席時は diagnostics status band / メッセージウィンドウ / パネル表示を優先する。
2. ユーザーが一定時間内に acknowledge した場合、メール送信は抑止する。
3. FE 不在、または未 acknowledge のまま escalation delay を超えた場合だけ、メールへ fallback する。

headless 側から直接 FE window を push しない。headless / scheduler は diagnostics に event と summary URI を保存し、FE reader がそれを読んで表示する。

content mail と error notification mail は別トラストクラスで扱う。

| | content mail | error notification mail |
|---|---|---|
| 送信主体 | workflow final action / `OutboundMailQueue` | `SourceVault_diagnostics` escalation channel |
| 承認 | 毎回承認 | 固定 operator 宛・metadata only・rate limited の範囲で事前承認 |
| 宛先 | 任意 | operator 自身の固定アドレスのみ。config / credential 由来でハードコードしない |
| 本文 | 任意。private encrypted storage 可 | reason code / trigger / machine tag / time / SummaryURI のみ |
| 失敗時 | workflow failure | diagnostics local log + doctor `Degraded`/`Failing`。メール失敗をメールで通知しない |

通知は dedup window / rate limit / digest / quiet hours を持つ。同一 `(component, reasonCode, triggerId)` は一定時間内で集約する。メール本文に source 本文、mail body、credential、生エラー文字列を入れない。

---

## 4. 日時指定 DSL

日時指定は、alarm / timer / cron / calendar pattern を統一して `Schedule` に保存する。

### 4.1 絶対日時

```wl
<|
  "Kind" -> "Alarm",
  "DateTime" -> "2026-07-01T03:00:00+09:00",
  "TimeZone" -> "Asia/Tokyo"
|>
```

### 4.2 相対 timer

```wl
<|
  "Kind" -> "Timer",
  "After" -> <|"Quantity" -> 2, "Unit" -> "Hours"|>,
  "Anchor" -> "CreatedAt" | "EnabledAt" | "LastFireAt"
|>
```

### 4.3 Calendar pattern

年月日曜日時刻の一部を wildcard にできる。

```wl
<|
  "Kind" -> "CalendarPattern",
  "TimeZone" -> "Asia/Tokyo",
  "Fields" -> <|
    "Year" -> All,
    "Month" -> All,
    "Day" -> All,
    "Weekday" -> "Friday",
    "Hour" -> 3,
    "Minute" -> 0,
    "Second" -> 0
  |>
|>
```

例: 毎週金曜日03:00。

### 4.4 値セット・範囲・ステップ

```wl
<|"Month" -> {1, 4, 7, 10}|>
<|"Day" -> <|"Range" -> {1, 7}|>|>
<|"Minute" -> <|"Every" -> 15, "Offset" -> 0|>|>
```

### 4.5 N週間おき

「二週間おき」は anchor を必須にする。anchor なしではユーザー確認に戻す。

```wl
<|
  "Kind" -> "CalendarPattern",
  "TimeZone" -> "Asia/Tokyo",
  "Fields" -> <|"Weekday" -> "Friday", "Hour" -> 3, "Minute" -> 0|>,
  "Interval" -> <|
    "Unit" -> "Weeks",
    "Every" -> 2,
    "AnchorDate" -> "2026-06-26"
  |>
|>
```

### 4.6 Cron 文字列互換

UI では自然言語と構造化表示を優先するが、実装用に cron 互換入力を受けてもよい。

```wl
<|
  "Kind" -> "Cron",
  "Expression" -> "0 3 * * Fri",
  "TimeZone" -> "Asia/Tokyo",
  "NormalizedTo" -> <|"Kind" -> "CalendarPattern", ...|>
|>
```

保存時は可能な限り `CalendarPattern` に正規化する。

### 4.7 マッチ意味論

tick は離散的であり、03:00ちょうどに評価される保証はない。`CalendarPattern` の match は、`now` のフィールド完全一致ではなく、`(LastCheckAt, now]` の区間内に pattern を満たす発火時刻が1つ以上存在することとして定義する。

同一区間に複数の発火時刻が含まれる場合は、`MisfirePolicy` で扱う。

- `Skip`: 最新1件も実行せず、missed として記録する。
- `RunOnceImmediately`: 1件だけ job 化する。
- `CatchUpLimited`: `CatchUpLimit` 件まで job 化する。

比較は ISO 文字列の辞書順ではなく `AbsoluteTime` 相当の数値で行う。`iSVATNow[]` は `$TimeZone` に暗黙依存せず、TriggerSpec の `TimeZone` を明示的に使う。

---

## 5. 条件 DSL

`Condition` は boolean algebra と atomic predicate の組み合わせにする。  
AND / OR / NOT を自然に表現できるよう、`AllOf`, `AnyOf`, `Not` を使う。

### 5.1 Boolean nodes

```wl
<|"AllOf" -> {cond1, cond2, cond3}|>
<|"AnyOf" -> {cond1, cond2}|>
<|"Not" -> cond|>
```

空の `AllOf` は True、空の `AnyOf` は False とする。  
保存時に空条件が意図通りか警告する。

UI では空条件を「追加条件: なし（時刻一致で必ず起動）」として明示表示する。

### 5.2 SourceVault event 条件

SourceVault への ingest / update / delete / metadata 更新 / claim 更新を扱う。初期実装では既存 `<PrivateVault>/events/source-events.jsonl` の EventId / SourceURI / EventType を読み、trigger ごとの watermark に EventId を保存する。自動起動専用の source event log を並行新設しない。

```wl
<|
  "Atom" -> "SourceVaultEvent",
  "URI" -> "sv://source/blog/foo",
  "EventType" -> "Ingested" | "Updated" | "Deleted" |
                 "MetadataChanged" | "ClaimChanged" |
                 "RegistryChanged",
  "Since" -> "LastSuccessfulFire" | "LastCheck" | "AbsoluteDateTime",
  "Debounce" -> <|"Quantity" -> 10, "Unit" -> "Minutes"|>
|>
```

`Since -> "LastSuccessfulFire"` を既定にする。  
これにより「前回自動実行後に更新されたら」が自然に書ける。

### 5.3 SourceVault data predicate

イベントではなく現在状態を問い合わせる条件。

```wl
<|
  "Atom" -> "SourceVaultPredicate",
  "URI" -> "sv://source/blog/foo",
  "Path" -> {"Metadata", "ETag"},
  "Operator" -> "ChangedSinceLastFire" | "Exists" | "NotExists" |
                "Equal" | "NotEqual" | "GreaterThan" | "LessThan" |
                "Contains" | "MatchesString",
  "Value" -> "...",
  "WatermarkKey" -> "etag"
|>
```

注意: 本文要約や意味判定はここで行わない。必要なら workflow 側で行う。

metadata predicate であっても private source / mail / local-only source を読む場合は、dispatch 前と同じ NBAccess / SourceVault privacy policy を通す。

### 5.4 Orchestrator event 条件

「ある workflow が走った後」「失敗した後」「承認済み final action が完了した後」などを扱う。

```wl
<|
  "Atom" -> "OrchestratorEvent",
  "EventType" -> "WorkflowStarted" | "WorkflowCompleted" |
                 "WorkflowFailed" | "WorkflowCancelled" |
                 "PromptRunCompleted" | "FinalActionCompleted",
  "WorkflowId" -> "workflow-...",
  "WorkflowTemplateId" -> "...",
  "RunId" -> Automatic,
  "Status" -> "Succeeded" | "Failed" | "Any",
  "Since" -> "LastSuccessfulFire"
|>
```

例: workflow A が成功した後に workflow B を起動。

```wl
<|
  "Atom" -> "OrchestratorEvent",
  "EventType" -> "WorkflowCompleted",
  "WorkflowTemplateId" -> "workflow-A",
  "Status" -> "Succeeded",
  "Since" -> "LastSuccessfulFire"
|>
```

### 5.5 手動承認・保留 queue 条件

危険な副作用を即実行しないため、承認や queue 状態も条件にできる。

```wl
<|
  "Atom" -> "ApprovalState",
  "ApprovalId" -> "...",
  "State" -> "Approved" | "Rejected" | "Expired"
|>
```

```wl
<|
  "Atom" -> "QueueState",
  "Queue" -> "FinalActionQueue" | "OutboundMailQueue" | "GitCommitQueue",
  "State" -> "Empty" | "HasPending" | "ApprovedBatchReady"
|>
```

---

## 6. 条件例

### 6.1 毎週金曜03:00、指定URIが更新されていたら

```wl
<|
  "Schedule" -> <|
    "Kind" -> "CalendarPattern",
    "TimeZone" -> "Asia/Tokyo",
    "Fields" -> <|"Weekday" -> "Friday", "Hour" -> 3, "Minute" -> 0|>
  |>,
  "Condition" -> <|
    "Atom" -> "SourceVaultEvent",
    "URI" -> "sv://source/blog/foo",
    "EventType" -> "Updated",
    "Since" -> "LastSuccessfulFire"
  |>
|>
```

### 6.2 2週間おき、複数sourceのどちらかが更新されていたら

```wl
<|
  "Schedule" -> <|
    "Kind" -> "CalendarPattern",
    "TimeZone" -> "Asia/Tokyo",
    "Fields" -> <|"Weekday" -> "Friday", "Hour" -> 3, "Minute" -> 0|>,
    "Interval" -> <|"Unit" -> "Weeks", "Every" -> 2,
      "AnchorDate" -> "2026-06-26"|>
  |>,
  "Condition" -> <|"AnyOf" -> {
    <|"Atom" -> "SourceVaultEvent", "URI" -> "sv://source/blog/foo",
      "EventType" -> "Updated", "Since" -> "LastSuccessfulFire"|>,
    <|"Atom" -> "SourceVaultEvent", "URI" -> "sv://source/youtube/bar",
      "EventType" -> "Updated", "Since" -> "LastSuccessfulFire"|>
  }|>
|>
```

### 6.3 workflow A 完了後、SourceVault ingest もある場合

```wl
<|
  "Condition" -> <|"AllOf" -> {
    <|"Atom" -> "OrchestratorEvent",
      "EventType" -> "WorkflowCompleted",
      "WorkflowTemplateId" -> "workflow-A",
      "Status" -> "Succeeded",
      "Since" -> "LastSuccessfulFire"|>,
    <|"Atom" -> "SourceVaultEvent",
      "URI" -> "sv://dataset/daily",
      "EventType" -> "Ingested",
      "Since" -> "LastSuccessfulFire"|>
  }|>
|>
```

---

## 7. RunPolicy / ExecutionPolicy

### 7.1 RunPolicy

```wl
<|
  "Priority" -> "Critical" | "High" | "Normal" | "Low",
  "PriorityRank" -> Automatic,
  "MisfirePolicy" -> "Skip" | "RunOnceImmediately" | "CatchUpLimited",
  "CatchUpLimit" -> 1,
  "MaxRunsPerWindow" -> <|"Count" -> 1, "Window" -> "Day"|>,
  "Concurrency" -> "Forbid" | "Allow" | "ReplacePending" | "Queue",
  "Debounce" -> <|"Quantity" -> 10, "Unit" -> "Minutes"|>,
  "Jitter" -> <|"Quantity" -> 0, "Unit" -> "Seconds"|>
|>
```

既定:

- `MisfirePolicy -> "Skip"`
- `Concurrency -> "Forbid"`
- `MaxRunsPerWindow -> 1/day`
- `Priority -> "Normal"`

`ExpiresAt` / `ActiveWindow` は trigger 全体の性質なので TriggerSpec トップレベルを正準とする。`RunPolicy["Debounce"]` は run 全体の最小間隔、`SourceVaultEvent["Debounce"]` は同一条件内の連続 event 抑制であり、層が異なる。

`MaxRunsPerWindow` は machine-local state ではなく共有 `runs.jsonl` / run index を `TriggerId` で集計する。owner 再割当後も同じ window 判定を維持する。

### 7.1.1 Priority

優先度は独立した飾りではなく、misfire 既定、dispatch 順序、資源競合時の扱い、miss の重大度分類をまとめて決める。

| Priority | MisfirePolicy 既定 | miss 分類 | 資源競合 | process / subprocess budget |
|---|---|---|---|---|
| `Critical` | `CatchUpLimited` | 致命系 | 最優先。未起動の低優先 pending を preempt 可 | 実測 pool 上で予約 slot を試みる |
| `High` | `RunOnceImmediately` | 致命系 | 低優先より優先 | 通常より先取り |
| `Normal` | `Skip` | 情報系。ただし設定で致命扱い可 | 通常 | 通常 |
| `Low` | `Skip` | 情報系。一回飛ばし可 | 高優先に譲る | 余席のみ |

「必ず指定時刻に実行」は物理的な絶対保証ではなく、可能な限り自発 skip / defer せず、資源競合で優先し、取りこぼしたら追走し、それでも実行不能なら致命エラーとしてユーザーに見せる、という意味で定義する。owner offline や license process / subprocess 枠枯渇は完全には消せない。

### 7.1.2 マルチマシン二重発火対策

Dropbox 同期下では複数マシンが同じ registry を読みうるため、単一カーネル内の `Concurrency -> "Forbid"` だけでは二重発火を防げない。TriggerSpec は必ず次のいずれかの ownership を持つ。

```wl
<|
  "Mode" -> "OwnerMachine",
  "OwnerMachineTag" -> "ProArtPX13"
|>
```

または:

```wl
<|
  "Mode" -> "Lease",
  "LeaseTTLSeconds" -> 300,
  "LockPath" -> "autotrigger/locks/<triggerId>.json"
|>
```

既定は `OwnerMachine` 方式とする。`OwnerMachineTag` が自マシンと一致しない trigger は tick で処理しない。これは Dropbox 同期下でも確実な単一実行に最も近い方式である。

`Lease` 方式は best-effort であり、Dropbox 越しのマルチマシン相互排他を保証しない。`RenameFile` / atomic write が不可分なのは単一ファイルシステム内だけであり、複数マシンがそれぞれローカルで lock 取得に成功し、後から conflict copy になる可能性がある。したがって、確実な単一実行が必要な trigger は `OwnerMachine` を使う。`Lease` は同一マシン内の複数 kernel / process の自己再入防止、または将来の単一 OS daemon 構成での補助に限定する。

二重発火の最終防波堤として、dispatch 時に冪等キーを作る。

```text
DispatchSlotKey = triggerId <> ":" <> scheduledTimeSlot
```

共有 run index / `runs.jsonl` に同じ `DispatchSlotKey` の started / completed / terminal run が既にあれば、新しい job は `DuplicateSlotSkipped` として skip する。lease が競合を取りこぼしても、同じ発火スロットの二重実行を実害化しない。

OwnerMachine がオフラインの間は、その trigger は評価機会を失う。これを通常の「条件不成立 skip」と区別し、`OwnerOffline` / `OwnerNoTick` として観測ログに残す。UI には owner と last-seen を表示し、長期 silent owner は再割当を促す。自動で lease へ降格しない。

`JobId` には machine tag を含める。

```text
job-<MachineTag>-<UTC timestamp>-<random>
```

### 7.1.3 Job claim とマシン間 best-effort exactly-once

マシン間 exactly-once は保証しない。Dropbox / OneDrive 上の claim file は分散 atomic lock ではなく、Wolfram Cloud ack も durable claim ではない。仕様上の保証レベルは best-effort at-most-once dispatch + workflow idempotency である。

worker は実行前に job claim を記録する。

```wl
<|
  "Type" -> "JobClaim",
  "JobId" -> "...",
  "DispatchSlotKey" -> "...",
  "WorkerMachineTag" -> "...",
  "ClaimedAtUTC" -> "...",
  "ClaimSequence" -> 1,
  "Backend" -> "SubkernelAsync" | "WolframScriptProcess"
|>
```

claim は `runs.jsonl` / job index に append-only で書く。既に同一 `DispatchSlotKey` の live claim / started / completed / terminal record がある場合、新しい worker は `DuplicateSlotSkipped` として実行しない。ただし同期遅延により複数 worker が同時に claim を書く可能性は残る。

最終防波堤:

- workflow は `DispatchSlotKey` / input digest / source version を idempotency key として扱う。
- 完了時には共有 run index を `DispatchSlotKey` で再照合し、複数 completion があれば後続を `DuplicateCompletionObserved` として diagnostics に出す。
- Git commit / mail / CloudDeploy / filesystem delete などの副作用は final action queue で idempotency key を持つ。
- `WorkerPool` または `Failover -> True` の target は `Idempotency -> "Idempotent"` または `CheckpointSupport -> True` が必須である。

in-flight job の worker が死んだ場合、failover 再実行できるのは idempotent または checkpoint/resume 可能な job だけである。非 idempotent job は silent 再実行せず、`InFlightWorkerDiedNeedsManualDecision` として致命エスカレーションする。これは scheduler ではなく Orchestrator workflow / NBAccess final action queue の recovery policy と連動して扱う。

### 7.2 ExecutionPolicy

```wl
<|
  "PreferredBackend" -> "SubkernelAsync" |
                        "WolframScriptProcess" |
                        "MainKernelAsync" |
                        "FrontendRequired",
  "AutoDispatchBackends" -> {"SubkernelAsync", "WolframScriptProcess"},
  "AllowFrontendRequired" -> False,
  "AllowBlockingFrontend" -> False,
  "AllowMainKernelAutoDispatch" -> False,
  "TimeConstraint" -> Quantity[30, "Minutes"],
  "SubkernelBudget" -> <|"AutoTriggerMax" -> Automatic, "CriticalReserved" -> 1|>,
  "ProcessBudget" -> <|"AutoTriggerMax" -> 0, "CriticalReserved" -> 0|>,
  "HeartbeatTimeout" -> Quantity[60, "Seconds"],
  "OutputMode" -> "Deferred",
  "RequiresNotebook" -> False,
  "CredentialRefs" -> {},
  "NetworkScope" -> {},
  "FileSystemScope" -> {}
|>
```

自動実行では `OutputMode -> "Deferred"` を既定にする。  
FE が必要な target は、一覧に `FE必要` と表示し、自動起動 toggle は既定無効にする。

自動 tick が dispatch できる headless job は `AutoDispatchBackends` に含まれる別プロセス系 backend に限定する。`MainKernelAsync` は同期 fallback によって主カーネルを占有しうるため、自動背景実行から除外する。主カーネルで実行したい workflow は `BlockingSyncUserInitiated` として手動ボタンからのみ実行する。

`TimeConstraint` は必須であり、宣言だけでなく実効化する。別プロセス job は wall-clock 監視で TTL 超過時に停止し、`TimeConstraintExceeded` を記録する。ユーザー起動の主カーネル同期実行では `TimeConstrained` 相当で上限を掛ける。

Subkernel / WolframScript を起動する前に、diagnostics が実測した process / subprocess 枠と local memory policy を確認する。`SubkernelAsync` は `$MaxLicenseSubprocesses` 側の budget、`WolframScriptProcess` は `$MaxLicenseProcesses - $LicenseProcesses` 側の budget を使う。不可なら spawn せず `LicenseSeatUnavailable` または `SubkernelUnavailable` として defer / error 記録する。dispatch 後も heartbeat / pid alive を監視し、heartbeat が無い job を `Running` のまま信用せず `BackendDiedSilently` に落とす。

`WolframScriptProcess` は worker 隔離には有用だが、independent process 枠を消費するため既定優先にしない。通常の headless workflow / prompt は `SubkernelAsync` を第一候補にし、process 枠は SourceVault service kernel / MCP gateway / FE / evaluation kernel のために温存する。

### 7.2.1 ExecutionPlacement

`ExecutionPlacement` は target をどのPCで実行できるかを決める。scheduler は trigger が成立した後、job を作る前に eligible machine set を計算する。

eligible machine の条件:

1. machine registry に登録されている。
2. `Machine:<MachineTag>` と `CloudSync:<MachineTag>` が required health を満たす。
3. `ExpectedAvailability -> "AlwaysOn"`、または `SpecificMachine` で明示指定されている。
4. `ExecutionCapabilities` が `RequiredCapabilities` を満たす。
5. 実測 license process / subprocess 枠、worker slot、local model slot に空きがある。
6. privacy / credential / filesystem / network scope がその machine で満たせる。

配置 mode ごとの扱い:

| Mode | 配置規則 |
|---|---|
| `EnvironmentIndependent` | eligible な always-on worker から選ぶ。標準2台構成では通常 primary worker 1台に固定される |
| `WorkerPool` | `WorkerPool` 名に属する eligible worker から `LoadBalance` に従って選ぶ |
| `SpecificMachine` | `RequiredMachineTags` の machine だけを使う。stale / sync failing の場合は dispatch しない |

3ライセンス以上で常時稼働 worker が複数ある場合、`WorkerPool` は次を許可する。

- local LLM / GPU heavy workflow を空き slot のあるPCへ分散する
- primary worker が落ちたとき、standby worker が同じ queue を縮退処理する
- `Critical` / `High` workflow 用に `ReservedCriticalSlots` を確保する

ただし、特定PCにだけ存在する資源を使う workflow は負荷分散対象にしない。例:

- そのPCにだけある LM Studio model / GPU / large local cache
- そのPCにだけ設定された private credential
- そのPCの notebook / selection / FE session
- そのPCの filesystem path / device / external application

この場合は `SpecificMachine` とし、UI でも「実行PC固定」と表示する。

### 7.3 SafetyPolicy

```wl
<|
  "EffectClasses" -> {},
  "RequiresApproval" -> False,
  "ApprovalMode" -> "PreApproved" | "AskBeforeEachRun" | "ManualOnly",
  "DangerousActionPolicy" -> <|
    "GitCommit" -> "QueueForBatchApproval",
    "MailSend" -> "QueueForBatchApproval",
    "CloudDeploy" -> "RequireManual",
    "FilesystemDelete" -> "Deny"
  |>,
  "FinalActionPolicy" -> "Queue",
  "AuditLevel" -> "Summary" | "FullPrivate" | "HashOnly"
|>
```

GitHub commit / mail 送信などは workflow 内 final action として queue に積み、Scheduler は直接送出しない。

### 7.4 RecoveryPolicy

```wl
<|
  "OnFailure" -> "StopAndWait" | "RetryLimited" | "MarkSkipped",
  "Retry" -> <|"MaxAttempts" -> 2, "Backoff" -> "Exponential"|>,
  "ResumeMode" -> "FromCheckpoint" | "Restart" | "Manual",
  "AfterFixCondition" -> <|"Atom" -> "ManualResumeApproved"|>
|>
```

既定は `OnFailure -> "StopAndWait"`。  
自動 retry は、workflow が checkpoint / idempotency を宣言した場合だけ許可する。

`RecoveryPolicy` は SourceVault scheduler が保持する実行意図の宣言であり、retry transition / checkpoint / resume / approval waiting の執行主体は Orchestrator workflow と NBAccess である。Scheduler は失敗を観測して `runs.jsonl` に記録し、`AfterFixCondition` が成立した場合に再 enqueue するだけで、workflow 内部状態を直接進めない。

---

## 8. 自動実行可否の分類

PromptRoute / WorkflowRoute / WorkflowTemplate には一覧表示用に `AutoRunCapability` を導出する。

| 値 | 意味 | 自動起動 |
|---|---|---|
| `HeadlessAsync` | WolframScript / subkernel でFE不要。主カーネルを占有しない | 可 |
| `HeadlessWithApproval` | FE不要だが事前承認が必要 | 承認後可 |
| `BlockingSyncUserInitiated` | FE不要だが主カーネル同期で走らせる方が安全。実行中はFEがブロックされる | 自動不可。手動ボタンのみ |
| `FrontendRequired` | Notebook / Dialog / FrontEnd 操作が必要 | 既定不可 |
| `MainKernelOnly` | main kernel でしか動かないがFE不要 | 自動不可。原則 `BlockingSyncUserInitiated` へ分類 |
| `ContextBound` | 現在の notebook / selection / cell に依存 | 不可 |
| `Unknown` | 判定不能 | 不可 |

PromptRoute では既存の `ReplaySafety` と `iSVPRRouteAutoExecutableQ` を使う。  
Workflow では `WorkflowCatalogRecord` / template metadata に以下を追加する。

```wl
"AutoRunCapability" -> "HeadlessAsync" | ...
"HeadlessSafe" -> True | False | Unknown
"RequiresFrontEnd" -> True | False | Unknown
"RequiresNotebookContext" -> True | False | Unknown
"Idempotency" -> "Idempotent" | "AtMostOnce" | "Unknown"
"CheckpointSupport" -> True | False | Unknown
"EstimatedBlockingSeconds" -> integer | Unknown
"FinalActionClasses" -> {"GitCommit", "MailSend"}
"ExecutionPlacementClass" -> "EnvironmentIndependent" | "WorkerPool" | "SpecificMachine" | "Unknown"
"RequiredMachineTags" -> {}
"RequiredCapabilities" -> {"HeadlessAsync"}
"WorkerPool" -> "default-headless" | Missing["None"]
"PlacementReason" -> "..."
```

metadata 未付与の既存 workflow は `AutoRunCapability -> "Unknown"` として扱い、自動起動不可にする。遡及分類は自動スキャンせず、ユーザー操作または管理 workflow により §16.2 の auto-run lint をオンデマンドで実行して付与する。

`ExecutionPlacementClass` が `Unknown` の target は、`AutoRunCapability` が headless に見えても自動負荷分散しない。まず lint / 仕様生成 / 仕様実装で、環境非依存か、worker pool 対象か、特定PC固定かを明示する。

---

## 9. UI 仕様

### 9.0 Diagnostics status band

ワークフロー一覧・保存プロンプト一覧の上部に diagnostics status band を表示する。

表示項目:

- `SystemDoctor: OK | Degraded | Failing`
- component health summary（例: `NBAccessKeys: OK`, `KernelSeat: Degraded`, `GitHubToken: Failing`）
- machine health summary（例: `ProArtPX13: OK`, `Laptop: OfflineOrSleeping`）
- cloud sync health（例: `Dropbox: ProArtPX13 OK / StrixHalo Degraded`）
- Wolfram Cloud comms health（例: `Channel: OK`, `Receiver: Degraded`, `Fallback: SourceVaultPolling`）
- active aggregator と standby 候補
- 最終 doctor 実行時刻
- lightweight diagnostics 最終 tick
- comprehensive diagnostics 最終 run
- 未確認 fatal error 件数
- owner machine / last seen の異常
- license process / subkernel subprocess / backend availability の要約
- reclaimable process capacity（例: `ReclaimableMCPKernels: 1`, `推奨: wlmcp-gateway 集約`）

関連 component が `Failing` の場合、その component を必要とする user workflow の自動 toggle は `不可` または `診断待ち` とする。無関係 component の `Failing` だけでは全 workflow を止めない。`Degraded` の場合は、条件確認 dialog で degraded reason と component-level accept 済みかを表示する。

### 9.1 ワークフロー一覧

`SourceVaultWorkflowPanel[]` の Grid に列を追加する。

現状:

```text
stage | 名前/サマリー | 起動 | 切替/保管 | 要約 | フォルダ
```

追加後:

```text
stage | 名前/サマリー | 実行モード | 実行PC | 自動可否 | 起動条件 | 自動 | 優先度 | 起動 | 切替/保管 | 要約 | フォルダ
```

#### 実行モード列

表示例:

- `別プロセス非ブロック`
- `主カーネルブロック（約N分・手動起動）`
- `承認後手動`
- `文脈依存`

`主カーネルブロック` は自動 tick から dispatch せず、ユーザーが起動ボタンを押した時だけ実行する。Tooltip に `TimeConstraint` と想定ブロック時間を出す。

#### 実行PC列

表示例:

- `環境非依存`
- `pool: default-headless`
- `pool: local-llm-heavy`
- `固定: ProArtPX13`
- `未判定`

Tooltip に eligible machine、required capability、現在の seat / worker slot 状態を出す。標準2台構成では、`環境非依存` でも通常は常時稼働PCに配置されることを表示する。`固定` の場合は、そのPCの heartbeat / cloud sync / local component health が stale なら自動列を `不可` または `診断待ち` にする。

#### 自動可否列

表示例:

- `非同期OK`
- `承認後OK`
- `FE必要`
- `文脈依存`
- `不明`

Tooltip に判定根拠を出す。

#### 起動条件列

ボタン:

- 条件未設定: `条件設定`
- 条件あり: `条件確認`

押すと dialog を開く。

dialog 内容:

1. 自然言語 prompt 入力欄
2. `TriggerSpec に変換` ボタン
3. 構造化 preview
4. 次回起動予定 preview
5. SourceVault / Orchestrator 条件 preview
6. `保存` / `保存せず閉じる`

#### 自動列

Toggle button:

- `OFF`
- `ON`
- `承認待ち`
- `不可`

`不可` の場合は押せない。理由を Tooltip 表示する。OwnerMachine 方式では Tooltip に `Owner: <MachineTag>` と `Last seen: <time>` を出す。長期未 tick の owner は警告色にする。

未確認の致命エラーがある場合、自動列に警告アイコンを表示する。アイコン hover で reason code / 発生時刻を表示し、クリックで diagnostics の保存済み summary を表示する。

#### 優先度列

`Critical` は赤、`High` は橙、`Normal` は無印または黒、`Low` は灰色の badge とする。条件確認 dialog でも「High: 取りこぼし時は追走し、不能ならエラー通知」「Low: 混雑時は一回スキップ可」を明示する。

### 9.2 保存プロンプト一覧

`SourceVaultFormatPromptRouteList` の Grid に列を追加する。

現状:

```text
Prompt | Memo | Target | 作成/更新 | Privacy | State | Actions
```

追加後:

```text
Prompt | Memo | Target | 作成/更新 | Privacy | 実行モード | 実行PC | 自動可否 | 起動条件 | 自動 | 優先度 | State | Actions
```

`State` の `AUTO` は「primary prompt route の prompt 再実行候補」と混同しやすい。  
新しい `自動` 列は Scheduler の `Enabled` を表し、既存の `AutoExecute` とは別名で扱う。

推奨 metadata 名:

```wl
"AutoExecute"        (* 既存: primary saved prompt の自動提案実行 *)
"AutoTriggerEnabled" (* 新規: Scheduler による自動起動 *)
```

### 9.3 条件確認ビュー

条件確認 dialog は、LLM prompt を再表示するだけでなく、必ず構造化表示する。

```text
対象:
  workflow: daily-blog-summary

日時:
  毎週金曜日 03:00 Asia/Tokyo

追加条件:
  sv://source/blog/foo が前回成功以後に Updated

実行:
  SubkernelAsync preferred
  FE不要
  同時実行禁止

安全:
  mail送信は queue に蓄積し、手動承認まで送らない

優先度:
  High（指定時刻に最大限実行。不能時はエラー通知）

Owner:
  ProArtPX13（last seen: 2026-06-26T03:01:00+09:00）
```

---

## 10. Prompt から TriggerSpec を作る

### 10.1 API

```wl
SourceVaultParseAutoTriggerPrompt[
  prompt_String,
  target_Association,
  opts:OptionsPattern[]
] -> <|
  "Status" -> "OK" | "NeedsClarification" | "Failed",
  "TriggerSpec" -> spec,
  "Explanation" -> "...",
  "Questions" -> {...},
  "Warnings" -> {...}
|>
```

`target` は UI の行から渡す。

```wl
<|"TargetType" -> "WorkflowTemplate", "TargetId" -> slug|>
<|"TargetType" -> "PromptRoute", "TargetId" -> routeId|>
```

### 10.2 LLM 出力契約

LLM は自由文ではなく、次の JSON 相当だけを返す。TriggerSpec 解析 prompt 自体も privacy-sensitive とする。URI、メール宛先、本文プレビュー、private source 名などが含まれる場合は cloud LLM に送らず、SourceVault / NBAccess privacy gate を通してローカル private model を使う。

```json
{
  "schedule": {},
  "condition": {},
  "runPolicy": {},
  "executionPolicy": {},
  "safetyPolicy": {},
  "recoveryPolicy": {},
  "explanation": "",
  "warnings": [],
  "questions": []
}
```

`ToExpression` で直接評価しない。  
`ImportString[..., "RawJSON"]` 相当で読み、schema validation を通す。既存の LLM JSON extraction pipeline が使える場合は、JSON parse fallback と sanitizer を流用する。

### 10.3 Clarification が必要な例

- 「隔週金曜」だが anchor date がない。
- 「更新されたら」がどの URI を指すか不明。
- 「メールで送って」が送信先・承認 policy 不明。
- `ContextBound` prompt を自動実行しようとしている。
- FE 必須 workflow を headless 実行しようとしている。

---

## 11. Scheduler Tick

### 11.1 Tick の起動方法

`SourceVaultAutoTriggerTick[]` は claudecode の共有 polling 基盤 `ClaudeRegisterPollingTick` から呼ばれる短い手続きとして実装する。パッケージ側で独自に `CreateScheduledTask` / `RunScheduledTask` を作ってはならない。手動診断用に `SourceVaultAutoTriggerTick[]` を直接呼べるようにはするが、本線は共有 tick への相乗りである。

tick は FE をブロックしないため短く終わる。`WaitAll` しない。`SystemOpen` / `NotebookWrite` / desktop 操作など FE 必須 action を tick の評価コンテキストから直接実行しない。

Tick が行うこと:

0. AsyncActive なら何も dispatch せず `DeferredAsyncActive` として必要最小限の観測だけ記録して戻る。
1. 自PCの machine heartbeat / lightweight diagnostics を更新する。
2. Wolfram Cloud comms が有効なら lightweight cloud heartbeat / round-trip probe を更新し、受信済み channel message を安全に取り込む。
3. 最新 diagnostics rollup を deterministic rule で採用する。自PCが active aggregator 条件を満たす場合は rollup 生成を試みる。rollup が stale / split-brain / failover 中でも、自PCの required component は machine-local report で fallback 判定できるようにする。
4. enabled trigger を読む。
5. diagnostics gate を確認する。system doctor workflow 以外は、workflow が必要とする component の直近 health が `OK` または accept 済み `Degraded` でなければ dispatch しない。実行予定 machine 自身の required component は machine-local report を優先し、global health / rollup stale だけで止めない。
6. `OwnerMachineTag` / best-effort lease を確認する。
7. TriggerSpec の `TimeZone` を使って now と state を作る。
8. `(LastCheckAt, now]` の区間で schedule match を確認する。
9. condition match を確認する。
10. dispatch 直前 privacy gate を再評価する。
11. concurrency / run limit / `DispatchSlotKey` dedup を確認する。
12. `ExecutionPlacement` から eligible machine set を計算する。
13. ready set を `(Priority desc, scheduled-time asc, PriorityRank asc)` で sort する。
14. machine / worker pool ごとの実測 license process / subprocess 枠、worker slot、local model slot を確認し、dispatch 先 machine を選ぶ。
15. job intent を SourceVault append-only log に書く。
16. dispatch 先 machine が自PCでない場合、Wolfram Cloud `JobIntent` message を送る。Cloud ack が返らなくても SourceVault polling fallback を残す。
17. 実行 worker は実行前に job claim を append-only に書き、同一 `DispatchSlotKey` の live claim / started / completed があれば `DuplicateSlotSkipped` とする。
18. 自PCが dispatch 先 machine の場合、上位から `SubkernelAsync` / `WolframScriptProcess` へ dispatch する。既定は `SubkernelAsync` 優先で、`WolframScriptProcess` は process 枠に余裕がある時だけ使う。
19. `Critical` / `High` が seat を取れない場合は、未起動の低優先 pending を preempt できる。ただし実行中 job は kill しない。
20. `Low` が seat を取れない場合は skip + 情報系ログに留め、追走しない。
21. long-running 実行を待たずに戻る。

tick は `ReleaseHold` などで target 本体を主カーネル評価しない。dispatch は process / subkernel 起動までに留める。主カーネル同期 workflow は tick ではなく、UI の手動起動ボタンから実行する。

diagnostics gate は priority に優先する。gate で止められた `Critical` / `High` workflow は黙って skip せず `DiagnosticsNotReady` として致命エスカレーションするが、実行はしない。

### 11.2 Watcher と polling

SourceVault event / Orchestrator event は初期実装では polling でよい。SourceVault source event は既存 `events/source-events.jsonl` を読む。Orchestrator event は workflow run record / state transition log を読み、scheduler 専用イベントに複製しない。

将来的には:

- SourceVault ingest/update/delete API が既存 source event log へ event を emit
- Orchestrator workflow run state transition が event を emit
- Scheduler は event log の watermark を読む

### 11.3 Watermark

trigger ごとに state を持つ。

```wl
<|
  "TriggerId" -> "...",
  "LastCheckAt" -> "...",
  "LastFireAt" -> "...",
  "LastSuccessfulFireAt" -> "...",
  "OwnerMachineTag" -> "...",
  "Lease" -> <|"MachineTag" -> "...", "AcquiredAt" -> "...", "ExpiresAt" -> "..."|>,
  "DispatchSlotKeys" -> {"triggerId:2026-06-26T03:00:00+09:00"},
  "Watermarks" -> <|
    "sv://source/blog/foo" -> <|"LastEventId" -> "...", "LastHash" -> "..."|>
  |>
|>
```

job 状態は文字列だけを信用しない。別プロセス job は heartbeat / pid alive / output marker から状態を導出する。一定時間 heartbeat が無い `Running` は `BackendDiedSilently` として terminal failure に落とす。

---

## 12. Executor 連携

### 12.1 PromptRoute

PromptRoute は次を満たす場合のみ Scheduler から実行できる。

- `ReplaySafety -> "EnvironmentIndependent"`
- `iSVPRRouteAutoExecutableQ[route] === True`
- `ClaudeEval` / `ContinueEval` に戻る `HeavyLLM` route ではない
- dispatch 直前の privacy gate を通る

実行は `SourceVaultReplayRoute` で式を復元し、`ClaudeRuntime` の proposal validation を経由する。登録時に安全だった route でも、参照 source の privacy / credential / network scope が変わりうるため、発火ごとに再評価する。

### 12.2 WorkflowRoute / WorkflowTemplate

Workflow は Orchestrator に渡す。

既存の実体 API は次である。

```wl
ClaudeOrchestrator`Workflow`ClaudeRunWorkflow[wid_String, "Async" -> True]
```

AutoTrigger では、`SourceVault_autotrigger.wl` 側に adapter を本線として置く。

```wl
SourceVaultStartWorkflowForAutoTrigger[
  workflowId_String,
  <|
    "RunMode" -> "AutoTrigger",
    "TriggerId" -> triggerId,
    "JobId" -> jobId,
    "ExecutionPolicy" -> executionPolicy,
    "SafetyPolicy" -> safetyPolicy
  |>
]
```

adapter は Orchestrator の availability を弱参照で確認し、実行可能なら `ClaudeRunWorkflow[wid, "Async" -> True]` を呼ぶ。`TriggerId` / `JobId` / policy は、workflow の input token / context packet / run metadata に保存する。`ClaudeRunWorkflow` に存在しない option を直接渡さない。

adapter は薄い1呼び出しではない。対象種別ごとに責務が分かれる。

| TargetType | adapter の責務 |
|---|---|
| `WorkflowRoute` | 既存 workflow net / wid への参照を解決し、AutoTrigger metadata を run metadata / context packet に束縛して `ClaudeRunWorkflow[wid, "Async" -> True]` を呼ぶ |
| `WorkflowTemplate` | template から workflow spec を復元し、`ClaudeCreateWorkflowNet[spec]` で net を実体化し、`InitialMarking` / 初期 token / context packet に `TriggerId` / `JobId` / policy / `DispatchSlotKey` を入れてから `ClaudeRunWorkflow` を呼ぶ |

すなわち WorkflowTemplate の自動起動は:

```text
template id
  -> template spec restore
  -> AutoTrigger input/context injection
  -> ClaudeCreateWorkflowNet[spec]
  -> ClaudeRunWorkflow[wid, "Async" -> True]
```

の順で行う。template 実体化時に idempotency / checkpoint / dangerous final action policy を再検証する。

### 12.3 FE 必須 workflow

FE 必須 workflow は自動起動 registry に条件を保存できるが、tick から FE 部分を自動実行できない。`SystemOpen` 等の desktop 操作は共有 polling tick / ScheduledTask / SessionSubmit 系評価コンテキストでは silent no-op になりうるためである。

したがって:

- `Enabled -> True` にしても、FE 必須 node は実行せず final action として分離・保留する。
- 実行はユーザーが承認 UI のボタンを `Method -> "Queued"` で押し、メインカーネルのトップレベル評価として走った場合だけ行う。
- `AllowFrontendRequired -> True` は「FE final action の queue 化を許す」という意味であり、「tick からFE操作を実行してよい」という意味ではない。
- UI に `FE必要` と常時表示し、自動列は `承認待ち/手動実行` として扱う。
- 「完了したら自動でフォルダを開く」「自動でNotebookへ書き込む」などは保証しない。必要なら workflow は final action queue item を作り、人間の承認評価を待つ。

---

## 13. 危険副作用の扱い

### 13.1 GitHub commit

自動 workflow は commit を即実行しない。  
workflow は commit candidate を作り、`GitCommitQueue` に積む。

queue item:

```wl
<|
  "ActionClass" -> "GitCommit",
  "Repository" -> "...",
  "Branch" -> "...",
  "DiffSummary" -> "...",
  "ProposedMessage" -> "...",
  "ApprovalState" -> "Pending",
  "CreatedByRunId" -> "..."
|>
```

送出は手動承認または batch approval workflow で行う。

### 13.2 Mail 送信

mail も同様に `OutboundMailQueue` に積む。

```wl
<|
  "ActionClass" -> "MailSend",
  "ToHash" -> "...",
  "Subject" -> "...",
  "BodyPreview" -> "...",
  "BodyStorage" -> "PrivateEncrypted",
  "ApprovalState" -> "Pending"
|>
```

Scheduler は content mail を送信しない。自動実行エラーの operator 通報メールは `OutboundMailQueue` ではなく diagnostics escalation channel の責務であり、固定 operator 宛・metadata only・rate limited の範囲でのみ事前承認済み送信を許す。

### 13.3 FinalActionQueue との統合

既存 NBAccess の `NBEnqueueFinalAction` / `NBFinalActionTick` を尊重する。  
Scheduler は final action の直接同期実行を禁止する。

desktop action / FrontEnd action は queue に積むだけでは実行完了を保証しない。共有 tick から効かない action は、承認 UI のボタン本体でメインカーネル評価として実行する。Scheduler は「queue に積んだ」「承認待ち」「実行済み」を観測するだけである。

---

## 14. 障害記録とエラー summary

### 14.1 reason code

自動実行の障害は安定 reason code で記録する。API / ライセンス / provider の生エラー文字列は保存しない。diagnostics sink が存在する場合、auto-trigger は同じ record を `SourceVaultDiagnosticsLog` に emit する。sink が存在しない場合も auto-trigger local log には残すが、High / Critical user workflow の自動 dispatch は diagnostics ready になるまで既定で許可しない。

| ReasonCode | 意味 | 既定分類 |
|---|---|---|
| `DeferredAsyncActive` | 既存 async 実行中なので dispatch しなかった | 情報 |
| `DeferredFEBusy` | FE / final action 都合で見送った | 情報 |
| `DiagnosticsNotReady` | system doctor が未実行 / `Failing` / 未accept `Degraded` のため user workflow を止めた | Priority 依存 |
| `OwnerOffline` | owner machine が tick していないため評価機会を失った | Priority 依存 |
| `DeferredNoSeat` | 実測 process / subprocess / worker slot / local model slot 不足で見送った | Priority 依存 |
| `LicenseSeatUnavailable` | independent process 枠を確保できない | Priority 依存 |
| `SubkernelUnavailable` | subprocess 枠または local subkernel policy により `SubkernelAsync` を確保できない | Priority 依存 |
| `ReclaimableMCPKernels` | 重複 native stdio MCP kernel により process 枠が埋まっており、単一 gateway 集約で回収可能 | 情報または `Degraded` |
| `CloudAckTimeout` | Wolfram Cloud channel message の ack が時間内に返らない | Priority 依存 |
| `CloudCommsUnavailable` | Wolfram Cloud auth / channel / receiver が利用不可。SourceVault polling へ fallback | 情報または Priority 依存 |
| `ChannelListenerDown` | Wolfram Cloud は利用可能だが local `ChannelListen` listener が死んでいる | 情報または Priority 依存 |
| `CloudCoordinationConflict` | CloudExpression / channel state と SourceVault rollup / log が矛盾 | 致命 |
| `BackendUnavailable` | Orchestrator / Runtime / backend が利用不可 | 致命 |
| `BackendDiedSilently` | 起動後 heartbeat / pid alive が確認できず死亡扱い | 致命 |
| `TimeConstraintExceeded` | TTL / TimeConstraint 超過で停止 | 致命 |
| `ValidationFailedAtDispatch` | dispatch 直前 validation / privacy gate で拒否 | 致命 |
| `WorkflowFailed` | workflow が terminal Failed で終了 | 致命 |
| `DuplicateSlotSkipped` | 同一 DispatchSlotKey の run が既にあり skip | 情報 |
| `DuplicateCompletionObserved` | 同一 DispatchSlotKey の completion が複数観測された | 致命 |
| `InFlightWorkerDiedNeedsManualDecision` | 非 idempotent in-flight job の worker が死亡し、自動 failover 再実行できない | 致命 |

Priority が `High` / `Critical` の場合、`DiagnosticsNotReady` / `OwnerOffline` / `DeferredFEBusy` / `DeferredNoSeat` / `LicenseSeatUnavailable` / `SubkernelUnavailable` / `CloudAckTimeout` は致命系として扱い、summary と警告アイコンを出す。`Normal` / `Low` では情報系を既定とする。

### 14.2 Error summary DerivedArtifact

致命系 reason code が発生したら、scheduler は diagnostics sink に error event を emit する。summary の不変 snapshot / DerivedArtifact 保存は `SourceVault_diagnostics` が担当し、auto-trigger は返された URI を `LastError` に保持する。

```wl
SourceVaultDiagnosticsLog[
  <|"Component" -> "AutoTrigger",
    "ReasonCode" -> "...",
    "TriggerId" -> "...",
    "JobId" -> "...",
    "Priority" -> "...",
    "DiagnosticsClass" -> "Fatal" | "Info",
    "SummaryRequested" -> True|>
]
```

compatibility wrapper として次を用意してよいが、内部では diagnostics API に委譲する。

```wl
SourceVaultWriteAutoTriggerErrorSummary[
  triggerId_String,
  jobId_String,
  errorRecord_Association
] -> <|"Status" -> "OK", "SummaryURI" -> "sv://summary/autotrigger/<triggerId>/<jobId>"|>
```

summary に含めるもの:

- trigger 名 / TargetType / TargetId / DisplayName
- Priority と致命扱いの理由
- 発火対象時刻 slot と dispatch 時刻
- backend 種別、OwnerMachineTag、JobId、DispatchSlotKey
- reason code と構造化診断（pid / elapsed seconds / seat state / attempt count）
- `runs.jsonl` の run id / event id pointer

summary に含めないもの:

- source 本文、mail body、private prompt、credential
- API / ライセンス / provider の生エラー文字列
- privacy level 0.5 以上のデータそのもの

一覧描画用に trigger 定義または軽量 state に次を保存する。

```wl
"LastError" -> <|
  "ReasonCode" -> "BackendDiedSilently",
  "At" -> "2026-06-26T03:01:12+09:00",
  "JobId" -> "job-ProArtPX13-...",
  "SummaryURI" -> "sv://summary/autotrigger/...",
  "Acknowledged" -> False
|>
```

`Acknowledged -> False` の間、一覧の自動列に警告アイコンを表示する。後続 run が成功した場合も audit を残して acknowledged 相当にできるが、黙って履歴を消さない。表示元は diagnostics の error record を正とし、`LastError` は一覧描画用 cache とする。

### 14.3 Error UI API

```wl
SourceVaultShowAutoTriggerError[triggerId_String]
SourceVaultOpenAutoTriggerError[triggerId_String]
SourceVaultAcknowledgeAutoTriggerError[triggerId_String]
```

- `Show` は summary を読み、セルまたは dialog に整形表示する。
- `Open` は `SummaryURI` を解決して開く。`SystemOpen` を使う可能性があるため、必ず `Method -> "Queued"` のメイン評価ボタンから呼ぶ。
- `Acknowledge` は diagnostics record に誰が・いつ確認したかを残し、一覧アイコンを消す。

同一 trigger で致命エラーが連続した場合、最新 summary を表示しつつ件数 badge を出し、過去 N 件へのリンクを summary 内に並べる。

---

## 15. 自動実行向け workflow 作成支援

ユーザー要望の重要点として、「cronで自動実行することを想定したワークフロー作成を支援する機構」を `仕様生成` / `仕様実装` に追加する。

### 15.1 仕様生成 workflow への追加質問

`spec-review` / `spec-impl` 系の workflow 生成時、以下を質問または自動抽出する。

```text
この workflow は自動実行対象ですか。
自動実行対象なら:
  - 想定 trigger は日時か、SourceVault event か、Orchestrator event か
  - headless 実行できるか
  - PC環境非依存か、worker pool で動かせるか、特定PC固定か
  - 特定PCだけの local model / GPU / credential / notebook / file path / device に依存するか
  - 標準2台構成で常時稼働PCに寄せるか、ノートPCを使う必要があるか
  - 3ライセンス以上の構成で負荷分散・冗長化したいか
  - notebook / selection / FE / dialog に依存するか
  - 外部 network / credential を使うか
  - GitHub commit / mail / cloud deploy / delete などの危険副作用があるか
  - 再実行しても安全か
  - worker pool / failover 対象にするなら、DispatchSlotKey に基づく idempotency または checkpoint/resume があるか
  - checkpoint / resume を持つか
  - 更新が遅れている場合の業務判断は何か
```

### 15.2 仕様書に追加する章

生成される workflow 仕様には、必ず次の章を入れる。

```text
自動実行適性
  AutoRunCapability:
  HeadlessSafe:
  RequiresFrontEnd:
  RequiresNotebookContext:
  ExternalDependencies:
  ExecutionPlacement:
  RequiredMachineTags:
  RequiredCapabilities:
  WorkerPool:
  LoadBalance:
  CredentialRefs:
  EffectClasses:
  DangerousActions:
  Idempotency:
  CheckpointSupport:
  FailoverEligibility:
  IdempotencyKey:
  FailurePolicy:
  SuggestedTriggerSpec:
  HumanApprovalPoints:
```

### 15.3 実装生成への要求

`仕様実装` は、自動実行対象 workflow について以下を実装条件にする。

- 入口引数は明示的 association にする。
- `EvaluationNotebook[]`, `InputNotebook[]`, selection, current cell に依存しない。
- PC環境非依存 / worker pool 対象 / 特定PC固定を metadata として保存する。
- local-only resource を使う場合は `RequiredMachineTags` / `RequiredCapabilities` を明示する。
- FE が必要な処理は final action node に分離する。
- 外部 source の「更新待ち」「本日更新なし」判断は workflow 内 node として実装する。
- 危険副作用は queue に積み、実送出 node を分離する。
- checkpoint を保存する。
- 同じ input / same source version で二重実行しても壊れない。
- worker pool / failover 対象の場合は、`DispatchSlotKey` / input digest / source version のいずれかを idempotency key として実装する。
- 実行 summary と evidence bundle を SourceVault に保存する。

### 15.4 自動実行 scaffold

仕様実装が成功したら、workflow catalog record に次を保存する。

```wl
"SuggestedAutoTrigger" -> <|TriggerSpec draft|>
"AutoRunCapability" -> ...
"ExecutionPlacementClass" -> "EnvironmentIndependent" | "WorkerPool" | "SpecificMachine"
"RequiredMachineTags" -> {...}
"RequiredCapabilities" -> {...}
"WorkerPool" -> ...
"AutoRunLint" -> <|
  "Passed" -> True | False,
  "Warnings" -> {...},
  "BlockingIssues" -> {...}
|>
```

UI の `条件設定` dialog は、この `SuggestedAutoTrigger` を初期値として使える。

---

## 16. Lint / Validation

### 16.1 TriggerSpec validation

保存前に検査する。

- `TriggerId` 一意
- target が存在する
- schedule が解釈可能
- interval に anchor が必要な場合は存在する
- condition が schema に合う
- URI が SourceVault URI として解決可能
- Orchestrator event 参照先が存在する
- `Owner.Mode` が `OwnerMachine` または `Lease` で、必要な `OwnerMachineTag` / `LeaseTTLSeconds` がある
- `Lease` を Dropbox マルチマシン排他の保証として扱っていない
- `SourceVaultEvent` 条件が既存 `events/source-events.jsonl` の event vocabulary / URI に対応する
- `Enabled -> True` にする場合、AutoRunCapability が許可範囲
- user workflow を `Enabled -> True` にする場合、diagnostics sink が存在し、必要 component の直近 health が `OK` または明示 accept 済み `Degraded` である
- workflow の `ExecutionPolicy` / `NetworkScope` / `CredentialRefs` / `FinalActionClasses` から required components を導出できる
- workflow を特定PCで実行する場合、`Machine:<MachineTag>` と `CloudSync:<MachineTag>` が required component に含まれる
- target の `ExecutionPlacement` が `EnvironmentIndependent` / `WorkerPool` / `SpecificMachine` のいずれかに分類され、`Unknown` のまま `Enabled -> True` になっていない
- `SpecificMachine` の場合、`RequiredMachineTags` が machine registry に存在し、その machine の required capabilities / component health を参照できる
- `EnvironmentIndependent` / `WorkerPool` の場合、eligible always-on worker が少なくとも1台存在する
- 標準2台構成では、常時稼働PC 1台に heavy workflow が集中しすぎないか、実測 process / subprocess 枠、worker slot、local model slot の恒常的な過予約を警告する
- 3ライセンス以上の拡張構成では、worker pool の `ResourceCapacity` と `$LicenseProcesses` / `$MaxLicenseProcesses` / `$MaxLicenseSubprocesses` 実測値が矛盾していない
- license capacity を registry 宣言値だけで許可していない。dispatch 前 check は diagnostics の実測値だけを見る
- `SubkernelAsync` と `WolframScriptProcess` の budget が分離され、通常 headless dispatch が `SubkernelAsync` 優先になっている
- `ReservedCriticalSlots` が物理席の保証として扱われていない。実測 pool 上で予約不能なら diagnostics に `DeferredNoSeat` / `LicenseSeatUnavailable` / `SubkernelUnavailable` を出す
- diagnostics が process 枠の内訳を分類し、重複 `AgentTools StartMCPServer` kernel を `ReclaimableMCPKernels` として検出・回収推奨できる
- comprehensive doctor が「headless 自動実行用に常時1 process 枠以上を回収または確保できること」を baseline policy として判定する
- 特定PC資源に依存する workflow を `EnvironmentIndependent` として負荷分散対象にしていない
- global health だけで無関係 workflow を止める設計になっていない
- global rollup stale / aggregator failover 中でも、自PC required component は machine-local report で fallback 判定できる
- system doctor workflow 自身は diagnostics bootstrap 例外として `Failing` 状態でも起動を試みられる
- machine registry に参加PCが登録され、少なくとも1台の `AggregatorCandidate` がある
- aggregator failover rule が deterministic で、split brain rollup を destructive action に使っていない
- cloud sync health が local write 成功だけでなく aggregator ack / rollup round-trip を含めて判定される
- stale / fresh 判定が各PCの自己申告 UTC の直接比較ではなく、観測側 `ObservedAtUTC` と per-machine `Sequence` に基づく
- Wolfram Cloud comms を使う場合、channel namespace / CloudObject / receiver permission が vault 単位に分離されている
- cloud message が private prompt / source 本文 / credential / 生エラー文字列を含まず、SourceVault URI pointer / digest / id に限定されている
- high privacy trigger の cloud message が human-readable `sv://...` ではなく opaque pointer を使う
- `ChannelSend` 成功を処理完了とみなさず、application-level ack と SourceVault polling fallback を持つ
- CloudExpression / CloudObject の coordination state が SourceVault 正本より優先されない
- Wolfram Cloud auth / channel / receiver / listener の health が `WolframCloudComms:<MachineTag>` / `WolframCloudAuth:<MachineTag>` / `ChannelListener:<MachineTag>` component として診断される
- `WorkerPool` または `Failover -> True` の target が idempotency または checkpoint/resume を宣言している
- in-flight worker death の自動 failover が idempotent / checkpointable job に限定され、非 idempotent job は manual decision へ escalation される
- `FrontendRequired` / `ContextBound` target を tick 自動実行対象にしていない
- `Critical` / `High` target が `FrontendRequired` / `ContextBound` の場合、優先度と自動実行可否の矛盾を警告する
- `High` / `Critical` に `MisfirePolicy -> "Skip"` を明示指定していないか警告する
- idempotency / checkpoint 未宣言の workflow を `CatchUpLimited` 付き High 以上にしていないか警告する
- 同一 owner machine 上の `Critical` 数が実測 subprocess / process budget と `ReservedCriticalSlots` policy を恒常的に超えないか警告する
- 登録時と dispatch 直前の privacy / credential / network scope が満たされる
- registry の書き込み粒度が trigger 単位で、単一 registry 全体の read-modify-write になっていない
- watermark / lease state の保存が atomic write で実装される
- 致命系 reason code に必ず `SummaryURI` が紐づく
- 致命系 reason code が diagnostics sink に emit される
- error summary に privacy 0.5 以上のデータや生エラー文字列が混入しない
- health 語彙が `OK` / `Degraded` / `Failing` に正規化される
- lightweight diagnostics が kernel spawn / LLM call / blocking IO を含まない
- comprehensive diagnostics の既定頻度が license process / subprocess 枠を圧迫しない
- machine heartbeat は machine-local path に書き、複数PCが同じ heartbeat file を更新しない
- global rollup の `current.wl` が cache であり、immutable rollup files が真実源になっている
- `SourceVaultOpenAutoTriggerError` が `Method -> "Queued"` のメイン評価ボタンから呼ばれる

### 16.2 Workflow auto-run lint

Workflow 側の lint:

- FE / Dialog / NotebookWrite / SelectionMove を通常 node で使っていないか
- FE 必須処理を final action として分離し、tick から直接実行しようとしていないか
- RunProcess / StartProcess / ExternalEvaluate を NBAccess scope なしで使っていないか
- SendMail / Git commit / CloudDeploy が final queue 化されているか
- checkpoint なしで retry policy を指定していないか
- ContextBound な prompt を自動実行しようとしていないか
- `Today`, `Now` の使用が timezone 明示されているか
- retry / resume / approval waiting を SourceVault scheduler ではなく Orchestrator workflow 側に置いているか
- 自動 tick から `MainKernelAsync` / 主カーネル同期 fallback へ流れないか
- `TimeConstraint` が必ず実効化され、無制限既定になっていないか
- heartbeat / pid alive / terminal marker のいずれかで backend death を検出できるか
- `WorkerPool` または `Failover -> True` の場合、`Idempotency -> "Idempotent"` または `CheckpointSupport -> True` を宣言しているか
- PC環境非依存か、worker pool 対象か、特定PC固定かを `ExecutionPlacementClass` として明示しているか
- local model / GPU / private credential / notebook / filesystem path / device 依存を `RequiredCapabilities` / `RequiredMachineTags` に落とせているか
- 標準2台構成で常時稼働PCに寄せるべき workflow と、ノートPC固定にせざるを得ない workflow を混同していないか
- 3ライセンス以上の worker pool で実行する場合、idempotency / checkpoint / final action queue が多重実行・failover に耐えるか

### 16.3 Prompt auto-run lint

PromptRoute 側:

- `ReplaySafety -> EnvironmentIndependent`
- `ReplayClass -> Replayable` または安全な `LightLLM`
- `TargetExprString` が parse 可能
- head allowlist を通る
- cloud LLM fallback が privacy policy に反しない
- prompt が参照する source / credential / local file / local model から `ExecutionPlacement` を導出できる
- `ReplaySafety -> EnvironmentIndependent` でも、local-only resource を参照する場合は `SpecificMachine` に降格する

---

## 17. 実装フェーズ

### Phase 0: diagnostics 最小核

- `SourceVault_diagnostics.wl` 追加
- `SourceVaultSystemDoctor[]`
- `SourceVaultDiagnosticsLog`
- diagnostics sink availability の弱判定
- `OK` / `Degraded` / `Failing` health 語彙の正準化
- 既存 `SourceVaultServiceHealth` / `SourceVaultServiceDoctor` / `SourceVaultMCPRunningQ` の集約
- lightweight diagnostics: 共有 tick inline、kernel spawn なし、heartbeat / pid alive / stale state / doctor freshness のみ
- component health cache と required component gate
- machine registry / machine-local heartbeat
- 標準2台構成 profile（AlwaysOn primary + Intermittent laptop）
- license process / subprocess 実測 probe: `$LicenseProcesses` / `$MaxLicenseProcesses` / `$MaxLicenseSubprocesses`
- process topology probe: FE / evaluation kernel / SourceVault service kernel / MCP gateway / native stdio MCP kernel の分類
- `ReclaimableMCPKernels` 検出と、単一 `wlmcp-gateway` 集約による回収推奨
- baseline policy: headless 自動実行用に常時1 process 枠以上を回収または確保できること
- process budget と subprocess budget の分離
- machine-local report 優先の diagnostics gate fallback
- cloud sync probe / aggregator ack / rollup round-trip 判定
- WolframScript / subkernel availability probe。ただし dispatch 既定は `SubkernelAsync` 優先
- comprehensive diagnostics: `sourcevault-system-doctor-autotrigger` workflow の登録、既定24時間ごと
- global rollup schema / immutable rollup files / current cache
- doctor 自身の停止検出 (`DoctorStale` / `DoctorNotRunning`)
- diagnostics panel / status view の最小版

この Phase が完了するまで、user workflow の `Enabled -> True` は dry-run または保存のみとする。自動実行の最初の実運用対象は system doctor workflow である。

Wolfram Cloud comms、ChannelReceiverFunction、CloudExpression coordination、aggregator election、split-brain rollup 処理は Phase 0 必須にしない。標準2台構成では SourceVault polling だけで成立させ、cloud comms は `WolframCloudComms.Enabled -> False` を既定にする。

### Phase 1: registry と UI draft

- `SourceVault_autotrigger.wl` 追加
- TriggerSpec schema / validation
- per-trigger registry file / append-only operation log
- `SourceVaultListAutoTriggers`
- workflow / prompt 一覧への列追加
- 実行モード列 / 実行PC列 / priority badge / owner last-seen / error icon
- `ExecutionPlacement` 設定・確認 UI
- diagnostics status / unacknowledged error count の表示
- 条件設定 / 確認 dialog
- `Enabled` toggle は保存だけで実行しない dry-run

### Phase 2: schedule tick と job queue

- `SourceVaultAutoTriggerTick[]`
- `ClaudeRegisterPollingTick` への相乗り
- schedule matching
- 既存 `events/source-events.jsonl` の簡易 polling
- `OwnerMachineTag` による二重発火抑止
- best-effort lease の限定実装
- `DispatchSlotKey` による dedup
- priority sort / process-subprocess budget / owner offline 記録
- eligible machine set 計算
- job claim / `DispatchSlotKey` dedup / duplicate completion detection
- remote job intent と dispatch 先 machine の worker pickup
- job append-only log
- duplicate / concurrency suppression
- preview next fire

### Phase 3: PromptRoute 実行

- EnvironmentIndependent PromptRoute の自動実行
- 自動 dispatch backend を Subkernel / WolframScript に限定
- AsyncActive gate / license process-subprocess preflight / heartbeat 監視
- `TimeConstraint` 実効化
- Runtime proposal validation
- 実行履歴保存
- diagnostics emit / 致命エラー summary URI / warning icon / acknowledge flow
- 失敗時 `StopAndWait`

### Phase 4: Workflow 実行

- Orchestrator adapter
- WorkflowTemplate の spec 復元・`ClaudeCreateWorkflowNet` 実体化・context injection
- WorkflowTemplate / WorkflowRoute dispatch
- checkpoint / run id / event 連携
- FinalActionQueue との接続

### Phase 4.5: 拡張マルチPC / Wolfram Cloud comms

- 3ライセンス以上または常時稼働PC 2台以上の worker pool
- worker pool load balance / failover
- failover 再実行の idempotency / checkpoint gate
- Wolfram Cloud channel namespace / heartbeat / ack / round-trip probe
- Wolfram Cloud `JobIntent` wakeup と SourceVault polling fallback
- `ChannelListener:<MachineTag>` watchdog
- CloudExpression / CloudObject coordination state
- ChannelReceiverFunction broker の任意 deploy
- aggregator candidate priority / failover / split-brain rollup detection

### Phase policy: r9 freeze と分割

v0.1-r9 を実装着手用 freeze candidate とする。以後は机上で機能を足し続けず、Phase 0-2 の最小スライスを実装して実測 feedback を得る。

実装用には本仕様を次の小仕様へ分割する。

- diagnostics 最小核 / seat probe / MCP reclaimability
- scheduler registry / TriggerSpec / UI draft
- tick / job queue / SubkernelAsync dispatch
- 拡張マルチPC / Wolfram Cloud comms

Phase 0-2 では cloud comms / aggregator election / split-brain 処理を有効化しない。2台構成で先に価値が出る、diagnostics、実測 license probe、MCP 重複検出、machine heartbeat、SourceVault polling tick、SubkernelAsync 優先 dispatch を完成させる。

### Phase 5: 自動実行向け workflow 生成支援

- 仕様生成テンプレート拡張
- 仕様実装 lint
- SuggestedAutoTrigger 生成
- catalog record 反映

### Phase 6: event-driven 化

- SourceVault ingest/update/delete API から既存 source event log へ event emit
- Orchestrator state transition から event emit
- watermark による効率化

---

## 18. 最小 API 使用例

### 18.1 prompt から条件を設定

```wl
draft = SourceVaultParseAutoTriggerPrompt[
  "毎週金曜日03:00に、sv://source/blog/foo が更新されていたら起動",
  <|"TargetType" -> "WorkflowTemplate", "TargetId" -> "daily-blog-summary"|>
];

SourceVaultRegisterAutoTrigger[
  draft["TriggerSpec"],
  "DryRun" -> False
]
```

### 18.2 自動起動を有効化

```wl
SourceVaultSetAutoTriggerEnabled["autotrg-...", True]
```

### 18.3 tick

```wl
SourceVaultAutoTriggerTick[]
```

### 18.4 状態確認

```wl
SourceVaultAutoTriggerJobQueue["Status" -> "Pending"]
SourceVaultAutoTriggerJobStatus["job-..."]
```

---

## 19. 未決事項

1. OS 常駐 daemon を将来追加する場合の machine ownership / credential scope。lease は単一マシン内補助であり、Dropbox 分散ロックに使わない。
2. SourceVault event log をどの既存 ingest/update API に最初に接続するか。
3. AutoTrigger adapter が workflow input token / context packet に metadata を載せる正確な形式。
4. `AutoExecute` 既存語との混同を避ける UI 文言。
5. FE 必須 workflow を `承認待ち/手動実行` としてどう表示するか。
6. GitHub / mail queue を NBAccess final action queue の汎用 action に寄せるか、SourceVault 側に専用 queue を置くか。
7. `$LicenseProcesses` / `$MaxLicenseProcesses` / `$MaxLicenseSubprocesses` の probe をどの kernel context で安定実行し、SourceVault service / MCP gateway / FE / evaluation kernel / 重複 native stdio MCP kernel の積み上がりをどう分類し、回収推奨へ落とすか。
8. ProArt 側など全参加PCで license process / subprocess 枠を実測し、per-machine pool か global shared pool かをどう判定するか。
9. Critical 予約 slot を実測 process / subprocess pool 上の policy としてどう調整するか。物理席保証と誤解させない UI 文言。
10. 標準2台構成の machine registry 初期値、primary always-on PC、standby laptop の priority。
11. 3ライセンス以上の拡張構成で使う worker pool 名、常時稼働 worker の capacity、local model pool の分け方。
12. Dropbox / OneDrive の provider-specific sync status API をどこまで使い、どこから heartbeat round-trip に一本化するか。
13. Wolfram Cloud channel / CloudObject の permission model を個人 Wolfram ID で運用するか、専用 service identity を使うか。
14. ChannelReceiverFunction を常時 deploy するか、Phase 0 では Wolfram Cloud comms 既定 off + SourceVault polling に留めるか。

---

## 20. 実装上の注意

- 自動起動 registry の文字列を `ToExpression` で直接実行しない。
- LLM が生成した TriggerSpec は必ず schema validation する。
- TriggerSpec 解析と dispatch 前 validation は privacy gate を通す。
- tick は FE を待たない。
- user workflow の自動 dispatch は diagnostics ready を前提にする。最初の自動実行 workflow は system doctor workflow とする。
- diagnostics gate は component-scoped とし、global `Failing` だけで無関係 workflow を止めない。
- global rollup が stale / split-brain の場合でも、自PC required component は machine-local report を優先して判定し、aggregator を gate の SPOF にしない。
- diagnostics gate は Priority に優先する。Critical でも gate 不通過なら実行せず、致命通知だけ行う。
- lightweight diagnostics は shared tick inline で動き、kernel seat を消費しない。
- license capacity は宣言値を信じず、`$LicenseProcesses` / `$MaxLicenseProcesses` / `$MaxLicenseSubprocesses` の実測値で判断する。
- `SubkernelAsync` と `WolframScriptProcess` の budget を分離し、通常の headless 自動実行は `SubkernelAsync` を優先する。
- diagnostics は process 枠の内訳を分類し、重複 native stdio MCP kernel を `ReclaimableMCPKernels` として検出し、単一 gateway 集約による回収を推奨する。
- Phase 0-2 を実装するまでは新機能を足し続けず、v0.1-r9 を freeze candidate として扱う。
- 各PCは自分の管轄 component だけを診断し、machine-local path に heartbeat / report を書く。
- aggregator は各PCの report を集約するだけで、各PC固有 probe を重複実行しない。
- primary aggregator が stale / sync failing の場合は standby aggregator が rollup を代行する。ただし Dropbox 分散ロックとはみなさず、split brain rollup は検出して診断 event にする。
- cloud storage sync health は heartbeat の local write だけで判断しない。aggregator ack / rollup round-trip を含めて判定する。
- Wolfram Cloud channel は既定 off の optional fast path とし、SourceVault log / immutable rollup を正本にする。Cloud state だけを根拠に destructive action を実行しない。
- cloud message は private data を含めず、SourceVault URI pointer / digest / id に限定する。高 privacy では opaque pointer を使う。
- `ChannelSend` 成功を受信・処理完了とみなさず、ack timeout と SourceVault polling fallback を必ず持つ。
- `ChannelListen` listener の死活は `ChannelListener:<MachineTag>` として診断し、常時稼働PCでは watchdog 再起動対象にする。
- 標準構成は2台運用を前提にし、常時稼働PCを通常 worker、ノートPCを intermittent / standby として扱う。license 枠は実測で判断する。
- 3ライセンス以上で常時稼働 worker を増やす場合だけ、`WorkerPool` による本格的な負荷分散・冗長化を有効にする。
- workflow / prompt は `ExecutionPlacement` を持ち、PC環境非依存か、worker pool 対象か、特定PC固定かを曖昧にしない。
- local model / GPU / private credential / notebook / file path / device に依存する target は、環境非依存として分散しない。
- tick は target 本体を主カーネル評価しない。自動 dispatch は Subkernel / WolframScript に限定する。
- マシン間 exactly-once は best-effort である。job claim、`DispatchSlotKey` dedup、completion dedup、workflow idempotency を併用する。
- failover 再実行は idempotent または checkpoint/resume 可能な job だけ許可する。
- long-running job を tick 内で `WaitAll` しない。
- 自動実行時の output は notebook へ直接 streaming しない。summary / log / SourceVault run record に保存する。
- `Enabled -> True` への変更は audit event を残す。
- `Enabled` 化した user / machine / timestamp / previous state を audit に残す。
- `Delete` ではなく、原則 `Disabled` / archived とし、履歴を残す。
- privacy-sensitive prompt の original text は `HashOnly` または private encrypted storage にする。
- `LastSuccessfulFire` と `LastFire` を分ける。失敗 run で watermark を進めない設定を既定にする。
- registry は trigger 単位で保存する。単一 registry 全体を複数マシンが read-modify-write しない。
- watermark / lease / compacted state の書き込みは atomic write とする。`tmp` へ書き、読み戻し検証し、`RenameFile` で置換する。ただし atomic write は Dropbox マルチマシン排他を保証しない。
- lease は best-effort とし、確実な単一実行が必要なら OwnerMachine + DispatchSlotKey dedup を使う。
- job / run / event の JSONL は append-only とし、compact する場合も atomic rewrite する。
- job 状態は heartbeat / pid alive / terminal marker で導出し、`Running` 文字列だけを信用しない。
- 致命エラーは reason code + cloud-safe summary URI を保存し、UI で acknowledge されるまで見える状態にする。
- 致命エラーは diagnostics sink に emit する。auto-trigger はメールを直接送らない。
- content mail (`OutboundMailQueue`) と diagnostics notification mail を混同しない。
- FE 在席時は diagnostics panel / message window を優先し、未 acknowledge の場合だけメール fallback する。
- Priority は dispatch 順序、misfire 既定、miss 重大度分類を同時に変える。Low は一回飛ばし可、High/Critical は不能時に通知する。
- 独自 `CreateScheduledTask` を作らず、共有 polling tick を使う。
