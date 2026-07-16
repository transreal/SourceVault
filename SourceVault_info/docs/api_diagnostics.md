# SourceVault_diagnostics API リファレンス

## 概要
SourceVault のクロスパッケージ診断 / SIEM レイヤ。Phase 0 minimal core 実装。本ファイルは SIEM の *collector / store / doctor* 層であり、ドメイン診断を所有しない。プロデューサ各パッケージ（[NBAccess](https://github.com/transreal/NBAccess), [claudecode](https://github.com/transreal/claudecode), [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator), [service manager](https://github.com/transreal/SourceVault_servicemanager), [auto-trigger](https://github.com/transreal/SourceVault_autotrigger)）が自身のプローブを所有し、このシンクが存在するときのみ emit する（rule 11: プロデューサは SourceVault への hard dependency を持たない）。

設計上の制約:
- 独立パッケージではない。[SourceVault](https://github.com/transreal/SourceVault) コンテキストの拡張であり Get[] でロード可能。単体ロードでも検証可能。
- `Needs["ClaudeRuntime`"]` / `Needs["ClaudeOrchestrator`"]` を行わない。プロデューサのプローブには public-symbol 名で弱く到達する。
- プロデューサ / vault root が不在でもロードできる。
- 冪等。Get[] の再実行はクリーンに再定義する。
- 全 ASCII ソース（rule 30 / #11、`\:XXXX` リテラル回避）。日本語 usage テキストは後続バルク変換へ延期。

Phase 0 スコープ: シンク可用性の弱検出 / 構造化 append-only 診断ログ / Wolfram ライセンス容量プローブ（宣言値でなく実測）/ kernel プロセストポロジ分類（Windows CIM, best-effort）/ 再利用可能容量検出（重複 MCP-server kernel）/ SourceVaultSystemDoctor による集約ヘルス（OK/Degraded/Failing）/ machine-local heartbeat（per-machine path, atomic write）/ minimal status / panel。

延期（一部は後続増分で実装済み。下記 Cloud comms 参照）: プローブレジストリの全プロデューサへの fan-out, comprehensive-doctor 自動トリガ。

慣習: 全関数は Read-only を基本とする（Doctor 系は副作用なし）。マルチ PC 集約では Dropbox 書き込み衝突を避けるため per-machine path + atomic write を使う。Cloud comms は best-effort で、非接続時は必ず SourceVault polling へ fallback し、協調がクラウドに hard-depend しない。受信メッセージ内容は決して評価せず DATA としてのみ扱う。

## バージョン変数

### $SourceVaultDiagnosticsVersion
型: String, 初期値: "0.1-phase0"
診断レイヤのバージョン。

## シンク可用性

### SourceVaultDiagnosticsSinkAvailableQ[] → True|False
この診断シンク（本レイヤ）がロード済みなら True。プロデューサが emit 前に弱くテストし、不在なら no-op する。

## 診断ログ

### SourceVaultDiagnosticsLog[record_Association] → Association | Failure
構造化診断レコード（reason code / component / severity / health / machine tag）を machine-local append-only 診断ログに追記する。格納したレコードを返す。vault root が解決できない場合は Failure。

### SourceVaultDiagnosticsIngestSpool[] → Association
producer per-process spool（`$UserBaseDirectory/ApplicationData/ClaudeRuntime/diag-spool/*.jsonl`）の DiagnosticsEvent を正準 diagnostics-log へ転記する（hardening 05 Inc2）。service kernel の低頻度 hook からのみ呼ぶ（単一書き手原則）。offset sidecar（`<file>.ingest.json`）で差分読み・EventId dedup により冪等。消化済みの過去日 shard は削除。件数集計を返す。

### $SourceVaultDiagIngestIntervalSeconds
型: Integer, 初期値: 60
service ループの spool ingest 周期（秒）。

## ライセンス / トポロジ / 容量プローブ

### SourceVaultDiagnosticsLicenseProbe[] → Association
Wolfram ライセンス容量を実測（$LicenseProcesses / $MaxLicenseProcesses / $MaxLicenseSubprocesses / $LicenseType）。宣言値を信頼しない。ProcessSlotsFree と SubprocessSlotsFree を含む Association を返す。

### SourceVaultDiagnosticsKernelProcessTopology[] → Association
稼働中の Wolfram kernel プロセスを列挙し各々を分類（Service / MCPServer / FEKernel / Subkernel / PlayerSandbox / FrontEndUI / Other）。Windows は CIM 経由の best-effort、他環境では name-only count に degrade。

### SourceVaultDiagnosticsReclaimableCapacity[] → Association
kernel トポロジを検査し再利用可能なプロセススロット（主に単一共有ゲートウェイへ collapse すべき重複 AgentTools MCP-server kernel）を検出。ReclaimableMCPKernels と recommendation を返す。

## システムドクター

### SourceVaultSystemDoctor[opts]
Phase 0 のクロスパッケージヘルス集約: ライセンスプール, 再利用可能 MCP 容量, （弱く）既存 service-manager ヘルス。component スコープのヘルスと GlobalHealth（"OK" | "Degraded" | "Failing"）を返す。Read-only。
→ Association
Options: "IncludeTopology" -> True (kernel-topology CIM プローブを含めるか。False で shell-out を回避)

### SourceVaultDiagnosticsLightweightDoctor[] → Association
安価な doctor: ライセンスプローブ + service health + 登録済みプローブを実行し kernel-topology CIM プローブをスキップ（shell-out なし）。共有 polling tick 向け。`SourceVaultSystemDoctor["IncludeTopology" -> False]` と等価。

## Heartbeat / Machine レジストリ / 集約

### SourceVaultDiagnosticsMachineHeartbeat[opts] → Association
本マシンの heartbeat（liveness + 軽量 component snapshot）を per-machine path へ書き込み、マルチ PC 集約での Dropbox 書き込み衝突を回避する。Atomic write。レコードを返す。

### SourceVaultDiagnosticsRegisterMachine[assoc] → Association
machine-registry レコード（spec 3.4.1）を当該マシン自身の per-machine path（衝突なし）へ書き込む。レコードを返す。
デフォルト: Roles {Worker}, AggregatorPriority 0, ExpectedAvailability AlwaysOn, Stale 300s, Failover 600s。

### SourceVaultDiagnosticsMachineRegistry[] → List
共有 diagnostics/machines ツリーから登録済み全マシンの registry.json を読む。

### SourceVaultDiagnosticsReadHeartbeats[] → Association
各マシンの registry + heartbeat を読み per-machine liveness（OK | Stale | OfflineOrSleeping | Failing | NoHeartbeat）を返す。ExpectedAvailability を尊重し、Intermittent な laptop の stale は Failing でなく OfflineOrSleeping。クロスマシン age は heartbeat monotonic seconds を使用（clock skew の影響を受ける）。

### SourceVaultDiagnosticsActiveAggregator[] → Association
active aggregator を選出: 最高 AggregatorPriority を持つ fresh な AggregatorCandidate と standby candidates。

### SourceVaultDiagnosticsAggregatorRollup[] → Association
全マシン heartbeat を読み global rollup（worst-of health, per-machine liveness, problem machines, active aggregator）を返す。cloud peer liveness を fold-in し、cloud channel 経由で見えた peer は Dropbox-synced file heartbeat が遅延していても live として数える。Read-only。共有 rollup ファイルは owner maintenance task のみが書く。

## Cloud comms（Wolfram Cloud 協調チャネル）
非接続時は必ず polling fallback。受信メッセージは DATA としてのみ記録し内容を評価しない。

### SourceVaultDiagnosticsCloudHeartbeat[opts] → Association
Wolfram Cloud comms ヘルスを弱く報告し、opt "Send"->True で協調チャネル経由に Heartbeat メッセージを送る。$CloudConnected でなければ Channel->Unavailable, Fallback->SourceVaultPolling を返し、協調がクラウドに hard-depend しないようにする。
Options: "Send" -> False (True で Heartbeat メッセージを送信)

### SourceVaultDiagnosticsCloudChannel[] → Association
共有 Wolfram Cloud 協調 ChannelObject を ensure して返す（同一 Wolfram アカウントの全マシンが共有）。非接続時は Available->False と polling fallback を返す。

### SourceVaultDiagnosticsCloudSend[message_Association] → Association
message（this MachineTag / AtUTC / Type を付加）を協調チャネルへ ChannelSend する。inter-machine の heartbeat / wakeup / negotiation 用。offline 時は no-op fallback。

### SourceVaultDiagnosticsCloudListen[] → Association
協調チャネルへ冪等に ChannelListen を開始する。受信パケットは DATA ONLY として bounded inbox に記録し（メッセージ内容は決して評価しない）、MessageID で dedup する。

### SourceVaultDiagnosticsCloudStopListen[] → 結果
本セッションのチャネルリスナを解除する。

### SourceVaultDiagnosticsCloudInbox[opts] → List
受信済みチャネルメッセージ（MessageID / FromWolframID / FromMachineTag / Type / Message / ReceivedAtUTC）を返す。
Options: "Type" -> All (Type でフィルタ), "MaxItems" -> All (返却件数上限)

### SourceVaultDiagnosticsCloudCommsStatus[] → Association
cloud-connected 状態, channel 名, 自リスナが生存しているか（watchdog）, inbox 件数を報告する。

### SourceVaultDiagnosticsCloudPeerLiveness[] → Association
各 machine tag から最後に受信した cloud Heartbeat メッセージから per-peer liveness を導出（$iSVDiagCloudPeerStaleSeconds 内なら OK, それ以外は Stale）。SourceVaultDiagnosticsAggregatorRollup がこれを fold-in する。

### SourceVaultDiagnosticsCloudConsume[] → Association
SAFE な inbox consumer。peer heartbeats（data）を返し、Wakeup メッセージを受けていれば wakeup flag を立てる。cloud メッセージ内容は決して評価しない。caller は WakeupRequested を見て自前の local tick を走らせ flag を reset してよい。

## ステータス / パネル

### SourceVaultDiagnosticsStatus[opts] → Association
compact な status Association（version, sink, license summary, reclaimable summary, last doctor global health）を返す。

### SourceVaultDiagnosticsPanel[] → Grid
現状の Phase 0 診断（license pool, kernel topology, reclaimable capacity, doctor health）の最小限の人間可読パネル（Grid）を返す。

### SourceVaultDiagnosticsStatusBand[] → Framed
workflow / saved-prompt リスト先頭用のコンパクトな framed status band（spec 9.0）を返す。global SystemDoctor health, per-component health badges, license process / subprocess pool summary、（マシン登録時は）multi-machine rollup + active aggregator 行を含む。

## プローブレジストリ

### SourceVaultDiagnosticsRegisterProbe[id_String, probeFn_] → id
プロデューサヘルスプローブを id で登録。probeFn は SourceVaultSystemDoctor から 0-arg で呼ばれ、health string / "Health" キーを持つ Association / component-name -> <|"Health"->...|> の Association のいずれかを返さねばならない。同一 id の再登録は置換。レジストリは本ファイルの Get[] 再実行を生き残る（プロデューサは自身のロード時に弱く登録）。id を返す。

### SourceVaultDiagnosticsListProbes[] → List
登録済み診断プローブ id のリストを返す。

## Polling Tick

### SourceVaultDiagnosticsTick[] → String
共有 polling tick から呼ばれる軽量 body。throttle あり（default 60s）。各実行で軽量 machine heartbeat（topology なし）を書き、aborted write により開いたままの stray vault file stream を解放し（SourceVaultReleaseFileStreams; 開いたハンドルは Dropbox sync をブロックし conflicted copy を招くため）、comprehensive doctor が freshness window 内に走っていなければ DoctorStale を emit する。kernel を spawn せず Front End にも触れない。短い status を返す。手動呼び出しも安全。

### SourceVaultDiagnosticsStartTick[opts] → 登録結果
claudecode の共有 polling base（ClaudeRegisterPollingTick）に SourceVaultDiagnosticsTick を弱く登録する。claudecode 不在時は no-op。opt-in（ロード時には start しない）。独自の ScheduledTask は作らない（rule 95）。
Options: "IntervalSeconds" -> 60 (body の throttle 秒数)

### SourceVaultDiagnosticsStopTick[] → 結果
共有 polling base から軽量診断 tick を解除する。

## エスカレーション / メール

### SourceVaultDiagnosticsEscalate[event_Association] → Association
診断イベントにエスカレーションポリシーを適用。常にイベントを記録し、High / Critical / Failing イベントは（dedup window を条件に）通知を route する。Front End 存在時はイベントを status-band / message-window reader 向けに記録しメールは deferred fallback 扱い、なければメールが primary チャネル。メールは SourceVaultDiagnosticsConfigureMail で実送信が有効になるまで DRY-RUN がデフォルト（intent のみ記録、SMTP なし）。メール body は cloud-safe metadata のみ（reason code / component / machine / time / SummaryURI）で raw error text や private data を含まない。routing summary を返す。

### SourceVaultDiagnosticsConfigureMail[config_Association] → Association
診断通知メール設定を vault config（config/diagnostics-mail.json）に set & persist し、recipient をソースにハードコードしない（rule 03）。effective config を返す。
Keys: "Recipient"（operator 自身の固定アドレス）, "Enabled"（default False; 実 SMTP 送信を gate）, "DedupWindowSeconds"

### SourceVaultDiagnosticsMailConfig[] → Association
effective な通知メール設定（Recipient / Enabled / DedupWindowSeconds / Source）を返す。