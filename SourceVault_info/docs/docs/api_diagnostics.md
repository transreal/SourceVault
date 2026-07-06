# SourceVault_diagnostics API リファレンス

## 概要
SourceVault のクロスパッケージ診断 / SIEM レイヤ (Phase 0 minimal core)。producer パッケージ (NBAccess, claudecode, Orchestrator, service manager, auto-trigger) が持つ probe の出力を受ける collector / store / doctor 層。ドメイン診断そのものは所有せず、この sink が存在するときにのみ producer が弱結合で emit する (rule 11: producer は SourceVault への hard dependency を持たない)。

`SourceVault`` コンテキストの拡張であり独立パッケージではない。`Get[]` でロード可能。producer / vault root が不在でもロードでき、`Get[]` を繰り返しても冪等に再定義される。`Needs["ClaudeRuntime`"]` / `Needs["ClaudeOrchestrator`"]` は行わず、producer probe は public シンボル名で弱く到達する。ソースは all-ASCII (rule 30 / #11)。

Phase 0 実装範囲: sink 可用性の弱検出 / 構造化 append-only 診断ログ / Wolfram ライセンス容量の実測 probe / kernel プロセストポロジ分類 (Windows CIM best-effort) / 回収可能容量検出 (重複 MCP-server kernel) / SourceVaultSystemDoctor による集約 (OK/Degraded/Failing) / マシンローカルハートビート (per-machine パス, atomic write) / minimal status / panel。

設計上の分類ラベル: kernel topology は Service / MCPServer / FEKernel / Subkernel / PlayerSandbox / FrontEndUI / Other。GlobalHealth / component health は "OK" | "Degraded" | "Failing"。マシン liveness は OK | Stale | OfflineOrSleeping | Failing | NoHeartbeat。

## バージョン変数
### $SourceVaultDiagnosticsVersion
型: String, 初期値: "0.1-phase0"
この診断レイヤのバージョン。

## Sink / ログ
### SourceVaultDiagnosticsSinkAvailableQ[] → True|False
この診断 sink レイヤがロード済みなら True。producer は emit 前にこれを弱くテストし、不在なら no-op する。

### SourceVaultDiagnosticsLog[record_Association] → Association|Failure
構造化診断レコード (reason code / component / severity / health / machine tag) をマシンローカルの append-only 診断ログへ追記する。保存したレコードを返す。vault root が解決できない場合は Failure を返す。

## ライセンス / トポロジ / 容量
### SourceVaultDiagnosticsLicenseProbe[] → Association
Wolfram ライセンス容量を宣言値でなく実測する ($LicenseProcesses / $MaxLicenseProcesses / $MaxLicenseSubprocesses, $LicenseType)。ProcessSlotsFree, SubprocessSlotsFree を含む Association を返す。

### SourceVaultDiagnosticsKernelProcessTopology[] → Association
稼働中の Wolfram kernel プロセスを列挙し各々を分類 (Service / MCPServer / FEKernel / Subkernel / PlayerSandbox / FrontEndUI / Other)。Windows は CIM で best-effort、それ以外は名前のみのカウントに縮退する。

### SourceVaultDiagnosticsReclaimableCapacity[] → Association
kernel トポロジを調べ回収可能なプロセススロット (主に単一共有ゲートウェイに集約すべき重複 AgentTools MCP-server kernel) を検出する。ReclaimableMCPKernels と推奨を返す。

### SourceVaultSystemDoctor[opts]
Phase 0 のクロスパッケージ健全性集約を実行: ライセンスプール、回収可能 MCP 容量、(弱く) 既存 service-manager health。read-only。
→ Association (component 単位 health + GlobalHealth "OK"|"Degraded"|"Failing")
Options: "IncludeTopology" -> True (kernel トポロジ CIM probe を含めるか。False で shell-out を回避)

### SourceVaultDiagnosticsLightweightDoctor[] → Association
安価な doctor: ライセンス probe + service health + 登録 probe を実行するが kernel-topology CIM probe を SKIP する (shell-out なし)。共有 polling tick 向け。`SourceVaultSystemDoctor["IncludeTopology" -> False]` と等価。

## ハートビート / 状態表示
### SourceVaultDiagnosticsMachineHeartbeat[opts]
このマシンのハートビート (liveness + 軽量 component snapshot) を per-machine パスへ書く。multi-PC 集約時の Dropbox write conflict を避ける。atomic write。
→ Association (レコード)

### SourceVaultDiagnosticsStatus[opts]
コンパクトな状態 Association を返す (version, sink, license summary, reclaimable summary, 最終 doctor の GlobalHealth)。
→ Association

### SourceVaultDiagnosticsPanel[] → Grid
現在の Phase 0 診断の最小人間可読パネル (Grid): ライセンスプール、kernel トポロジ、回収可能容量、doctor health。

### SourceVaultDiagnosticsStatusBand[] → framed band
workflow / saved-prompt リスト上部向けのコンパクトな枠付き状態バンド (spec 9.0): GlobalHealth、component 単位 health バッジ、ライセンス process/subprocess プール要約、(マシン登録済みなら) multi-machine rollup + active aggregator 行。

## マシンレジストリ / 集約
### SourceVaultDiagnosticsRegisterMachine[assoc]
マシンレジストリレコード (spec 3.4.1) をこの/対象マシン自身の per-machine パスへ書く (conflict-free)。
→ Association (レコード)
デフォルト: Roles {Worker}, AggregatorPriority 0, ExpectedAvailability AlwaysOn, Stale 300s, Failover 600s。

### SourceVaultDiagnosticsMachineRegistry[] → List
共有 diagnostics/machines ツリーから登録済み全マシンの registry.json を読む。

### SourceVaultDiagnosticsReadHeartbeats[] → Association
各マシンの registry + heartbeat を読み per-machine liveness を返す (OK | Stale | OfflineOrSleeping | Failing | NoHeartbeat)。ExpectedAvailability を尊重し、Intermittent なラップトップが stale になっても OfflineOrSleeping であって Failing ではない。cross-machine age は heartbeat の monotonic 秒を使う (clock skew の影響を受ける)。

### SourceVaultDiagnosticsActiveAggregator[] → Association
active aggregator を選出: fresh な AggregatorCandidate のうち AggregatorPriority 最大のもの、加えて standby 候補。

### SourceVaultDiagnosticsAggregatorRollup[] → Association
全マシンの heartbeat を読み global rollup を返す (worst-of health, per-machine liveness, problem machines, active aggregator)。read-only。共有 rollup ファイルは owner maintenance task のみが書く。

## Wolfram Cloud コーディネーション
### SourceVaultDiagnosticsCloudHeartbeat[opts]
Wolfram Cloud comms health を報告し、opt で coordination channel に Heartbeat メッセージを送る。$CloudConnected でない場合は Channel->Unavailable, Fallback->SourceVaultPolling を返し、coordination がクラウドに hard-depend しないようにする。
→ Association
Options: "Send" -> False (True で Heartbeat メッセージを送信)

### SourceVaultDiagnosticsCloudChannel[] → ChannelObject|Association
共有 Wolfram Cloud coordination ChannelObject を確保して返す (同一 Wolfram アカウントの全マシンが共有)。cloud-connected でないとき Available->False と polling fallback を返す。

### SourceVaultDiagnosticsCloudSend[message_Association] → 結果
message を coordination channel に ChannelSend する (MachineTag / AtUTC / Type を付加)。マシン間 heartbeat / wakeup / negotiation 用。offline 時は no-op fallback。

### SourceVaultDiagnosticsCloudListen[] → 結果
coordination channel 上で ChannelListen を冪等に開始する。受信パケットは bounded inbox に DATA ONLY として記録され (メッセージ内容は決して評価されない)、MessageID で dedup される。

### SourceVaultDiagnosticsCloudStopListen[] → 結果
このセッションの channel listener を除去する。

### SourceVaultDiagnosticsCloudInbox[opts]
受信した channel メッセージを返す (MessageID / FromWolframID / FromMachineTag / Type / Message / ReceivedAtUTC)。
→ List
Options: "Type" -> All (Type でフィルタ), "MaxItems" -> All (最大件数)

### SourceVaultDiagnosticsCloudCommsStatus[] → Association
cloud-connected 状態、channel 名、自 listener が生存しているか (watchdog)、inbox 件数を報告する。

### SourceVaultDiagnosticsCloudPeerLiveness[] → Association
各 machine tag から受信した最新 cloud Heartbeat メッセージから per-peer liveness を導く ($iSVDiagCloudPeerStaleSeconds 以内なら OK、超過で Stale)。SourceVaultDiagnosticsAggregatorRollup はこれを畳み込み、Dropbox 同期のファイル heartbeat が遅れても cloud channel で見えた peer を live と数える。

### SourceVaultDiagnosticsCloudConsume[] → Association
安全な inbox consumer: peer heartbeat (データ) を返し、Wakeup メッセージを受けていれば wakeup フラグを立てる — cloud メッセージ内容を決して評価しない。呼び手は WakeupRequested 時に自前のローカル tick を走らせフラグを reset してよい。

## Probe レジストリ
### SourceVaultDiagnosticsRegisterProbe[id_String, probeFn_] → id
producer health probe を id で登録する。probeFn は SourceVaultSystemDoctor から 0 引数で呼ばれ、health 文字列 / "Health" キーを持つ Association / component 名 -> <|"Health"->...|> の Association のいずれかを返さねばならない。同一 id の再登録は置換する。レジストリはこのファイルの `Get[]` 繰り返しでも生存する (producer は自身のロード時に弱く登録)。

### SourceVaultDiagnosticsListProbes[] → List
登録済み診断 probe id のリストを返す。

## ポーリング tick
### SourceVaultDiagnosticsTick[] → status
共有 polling tick から呼ばれる軽量本体。throttle 付き (デフォルト 60s)。各実行で軽量マシン heartbeat (topology なし) を書き、comprehensive doctor が freshness window 内に走っていなければ DoctorStale を emit する。kernel を spawn せず Front End も触らない。手動呼び出しも安全。

### SourceVaultDiagnosticsStartTick[opts]
SourceVaultDiagnosticsTick を claudecode の共有 polling base (ClaudeRegisterPollingTick) に弱く登録する。claudecode 不在時は no-op。opt-in (ロード時には開始しない)。自前の ScheduledTask は作らない (rule 95)。
→ 結果
Options: "IntervalSeconds" -> 60 (本体を throttle する秒数)

### SourceVaultDiagnosticsStopTick[] → 結果
軽量診断 tick を共有 polling base から登録解除する。

## エスカレーション / 通知メール
### SourceVaultDiagnosticsEscalate[event_Association] → routing summary
診断イベントにエスカレーションポリシーを適用する。常にイベントを記録し、High / Critical / Failing イベント (dedup window 対象) では通知を routing する。Front End 存在時はイベントを status-band / message-window reader 用に記録しメールを deferred fallback とする。それ以外はメールが primary channel。メールはデフォルト DRY-RUN (意図のみ記録、SMTP 送信なし) で、SourceVaultDiagnosticsConfigureMail が実送信を有効化するまで送らない。メール本文は cloud-safe なメタデータのみ (reason code / component / machine / time / SummaryURI)。raw エラーテキストや private データは含めない。

### SourceVaultDiagnosticsConfigureMail[config_Association] → Association
診断通知メール設定を vault config (config/diagnostics-mail.json) に設定・永続化する。宛先をソースにハードコードしないため (rule 03)。有効設定を返す。
Keys: "Recipient" (operator 自身の固定アドレス), "Enabled" (デフォルト False; 実 SMTP 送信を gate), "DedupWindowSeconds"。

### SourceVaultDiagnosticsMailConfig[] → Association
有効な通知メール設定を返す (Recipient / Enabled / DedupWindowSeconds / Source)。

## 関連パッケージ
- [SourceVault](https://github.com/transreal/SourceVault)
- [SourceVault_servicemanager](https://github.com/transreal/SourceVault_servicemanager)
- [SourceVault_autotrigger](https://github.com/transreal/SourceVault_autotrigger)
- [NBAccess](https://github.com/transreal/NBAccess)
- [claudecode](https://github.com/transreal/claudecode)
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)
- [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime)