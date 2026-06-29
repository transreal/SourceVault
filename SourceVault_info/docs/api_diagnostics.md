# SourceVault_diagnostics API リファレンス

## 概要
SourceVault のクロスパッケージ診断 / SIEM レイヤ。Phase 0 minimal core 実装。本ファイルは SIEM の *collector / store / doctor* 層であり、ドメイン診断を所有しない。プロデューサ各パッケージ（NBAccess, claudecode, [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator), service manager, auto-trigger）が自身のプローブを所有し、このシンクが存在するときのみ emit する（rule 11: プロデューサは SourceVault への hard dependency を持たない）。

設計上の制約:
- 独立パッケージではない。[SourceVault](https://github.com/transreal/SourceVault)` コンテキストの拡張であり Get[] でロード可能。単体ロードでも検証可能。
- `Needs["ClaudeRuntime`"]` / `Needs["ClaudeOrchestrator`"]` を行わない。プロデューサのプローブには public-symbol 名で弱く到達する。
- プロデューサ / vault root が不在でもロードできる。
- 冪等。Get[] の再実行はクリーンに再定義する。
- 全 ASCII ソース（rule 30 / #11、`\:XXXX` リテラル回避）。日本語 usage テキストは後続バルク変換へ延期。

Phase 0 スコープ: シンク可用性の弱検出 / 構造化 append-only 診断ログ / Wolfram ライセンス容量プローブ（宣言値でなく実測）/ kernel プロセストポロジ分類（Windows CIM, best-effort）/ 再利用可能容量検出（重複 MCP-server kernel）/ SourceVaultSystemDoctor による集約ヘルス（OK/Degraded/Failing）/ machine-local heartbeat（per-machine path, atomic write）/ minimal status / panel。

延期: プローブレジストリの全プロデューサへの fan-out, escalation / mail チャネル, aggregator rollup / failover, Wolfram Cloud comms, comprehensive-doctor 自動トリガ。

慣習: 全関数は Read-only を基本とする（Doctor 系は副作用なし）。マルチ PC 集約では Dropbox 書き込み衝突を避けるため per-machine path + atomic write を使う。

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
全マシン heartbeat を読み global rollup（worst-of health, per-machine liveness, problem machines, active aggregator）を返す。Read-only。共有 rollup ファイルは owner maintenance task のみが書く。

### SourceVaultDiagnosticsCloudHeartbeat[opts] → Association
Wolfram Cloud comms ヘルスを弱く報告。$CloudConnected でなければ Channel->Unavailable, Fallback->SourceVaultPolling を返し、協調がクラウドに hard-depend しないようにする。実チャネル send/receive（ChannelListen / CloudExpression）はマルチマシンの follow-up。

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
共有 polling tick から呼ばれる軽量 body。throttle あり（default 60s）。各実行で軽量 machine heartbeat（topology なし）を書き、comprehensive doctor が freshness window 内に走っていなければ DoctorStale を emit する。kernel を spawn せず Front End にも触れない。短い status を返す。手動呼び出しも安全。

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