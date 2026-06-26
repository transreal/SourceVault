# SourceVault_servicemanager API リファレンス

パッケージ: `SourceVault` (ファイル: `SourceVault_servicemanager.wl`)
依存: [SourceVault_core](https://github.com/transreal/SourceVault_core), [SourceVault_searchindex](https://github.com/transreal/SourceVault_searchindex)
ロード順: `SourceVault.wl` → `SourceVault_core.wl` → `SourceVault_searchindex.wl` → 本ファイル
`Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_servicemanager.wl"]]` で読み込む。
private helper は `SourceVault`ServiceManagerPrivate`` 文脈に置き、公開シンボルと非衝突。

## ローカル init / config (§5.2, §5.3)

### SourceVaultLocalConfigRoot[] → String | Failure
`<PrivateVault>/config/local` を返す。`$SourceVaultCoreRoot` または `$SourceVaultRoots["PrivateVault"]` で解決。未解決なら `Failure["PrivateVaultUnresolved", ...]`。

### SourceVaultLoadLocalInit[opts]
`<PrivateVault>/config/local/SourceVaultLocalInit.wl` を UTF-8 で読み込む。存在しなければ fail-closed せず `<|"Status"->"NotFound"|>` を返す。
→ `<|"Status" -> "Loaded"|"NotFound"|"LoadError", "Path" -> ...|>`
Options: "Path" -> Automatic (Automatic で標準パス使用、明示パスも可)

### SourceVaultLocalConfigStatus[] → Association
local init の有無と登録済みプロファイル summary を返す。キー: `LocalConfigRoot`, `LocalInitPath`, `LocalInitExists`, `SearchProfiles`, `ServiceProfiles`。

### SourceVaultLocalConfigDoctor[opts] → Association
必須 registry (ReleaseContext / SearchBackend / WebServiceEndpoint) の登録状況を点検し不足を報告する。
→ `<|"Status" -> "OK"|"Incomplete", "Missing" -> {...}, "ReleaseContexts", "SearchBackends", "WebServiceEndpoints"|>`

## サービス / エンドポイント / チャネル registry (§5.3, §9.x, §16.8)

### SourceVaultRegisterWebServiceEndpoint[name, spec] → Association
WebService endpoint を登録する。spec 必須キー: `"BindAddress"`, `"Port"`。
→ `<|"Status"->"OK", "Kind", "Name"|>` または `Failure["InvalidSpec", ...]`

### SourceVaultResolveWebServiceEndpoint[name] → Association | Failure
登録済み WebService endpoint を解決する。未登録なら `Failure["UnregisteredProfile", ...]`(fail-closed)。

### SourceVaultRegisterChannelEndpoint[name, spec] → Association
mail / Discord 等のチャネル endpoint を登録する。

### SourceVaultRegisterVoiceBackend[name, spec] → Association
STT/TTS/realtime voice backend を登録する。

### SourceVaultRegisterVRSNSAdapter[name, spec] → Association
VRSNS adapter を登録する。

### SourceVaultRegisterCapabilityProfile[name, spec] → Association
avatar/world capability profile を登録する。

### SourceVaultRegisterLLMBackend[name, spec] → Association
headless LLM backend を登録する (§16.9.1)。既定は API 直叩き / trusted local server。CLI は HeadlessSafe test 合格時のみ登録可。

### SourceVaultRegisterCaptureSource[name, spec] → Association
audio/camera/screen capture source を登録する (§17.3)。DeviceRef / WindowRef は symbolic ref とし、実デバイス名は private local init で解決する。

### SourceVaultRegisterOutputAdapter[name, spec] → Association
Discord 等の output adapter を登録する (§17.9)。

### SourceVaultResolveServiceProfile[kind, name] → Association | Failure
ServiceManager registry のプロファイルを解決する。
kind: `"WebServiceEndpoint"` / `"ChannelEndpoint"` / `"VoiceBackend"` / `"VRSNSAdapter"` / `"CapabilityProfile"` / `"LLMBackend"` / `"CaptureSource"` / `"OutputAdapter"`。
未登録なら `Failure["UnregisteredProfile", ...]`(fail-closed)。

### SourceVaultListServiceProfiles[] → Association
全 kind の登録名リストを `<|"WebServiceEndpoint"->{...}, ...|>` で返す。

### SourceVaultListServiceProfiles[kind] → List
指定 kind の登録名リストのみ返す。

### SourceVaultClearServiceRegistry[] → Association
ServiceManager registry を全消去する (テスト / 再 init 用)。→ `<|"Status"->"OK"|>`

## PDFGroupSearchProfile (§19)

### SourceVaultCreatePDFGroupSearchProfile[groupAlias, spec] → Association
PDF グループの検索 service 設定を一つの data object として registry に登録する。spec に QueryScopeResolver / EvidencePolicy / AnswerPolicy 等を inline field として持つ。

### SourceVaultResolvePDFGroupSearchProfile[groupAlias] → Association | Failure
登録済み PDFGroupSearchProfile を解決する。未登録なら Failure(fail-closed)。

### SourceVaultListPDFGroupSearchProfiles[] → List
登録済み PDFGroupSearchProfile の alias リストを返す。

### SourceVaultClonePDFGroupSearchProfile[srcAlias, newAlias, overrides] → Association
`srcAlias` のプロファイルを `newAlias` としてコピーし、`overrides`(Association、省略可)でフィールドを上書きして登録する。

## パーソナル config doctor (§5.5)

### SourceVaultNoPersonalConfigDoctor[filesOrDirs, opts]
repository / 配布対象ファイルに個人情報・環境依存値が混入していないか検査する。
検出対象: IPv4 literal (octet 検証), localhost:port, Windows/macOS ユーザパス, credential らしき token, 実メールアドレス, private vault root。
ファイル先頭付近に `doctor:private-design-doc` マーカーがあるファイルは検査対象外。
→ `<|"Status" -> "OK"|"FindingsFound", "Findings" -> {...}, "FilesScanned" -> n, "Skipped" -> {...}, "FindingCount" -> n|>`
Options: "MailAllowlist" -> {} (許可するメールアドレスリスト), "Extensions" -> Automatic (既定: {".wl",".wls",".m",".md",".json",".toml",".yaml",".yml"}), "Mask" -> True (マッチ文字列を先頭2文字+***に隠す)
例: `SourceVaultNoPersonalConfigDoctor[{"src/", "config.wl"}, "MailAllowlist" -> {"admin@example.com"}, "Mask" -> False]`

## detached service ライフサイクル (§9.3-9.6, §17.8, Phase 2)

### SourceVaultStartService[serviceId, opts]
detached WolframScript service を起動する。メイン Mathematica 終了後も service process は heartbeat を更新し続ける。
→ `<|"Status", "ServiceId", "PID", "RuntimeDir"|>`
Options: "Kind" -> "heartbeat" (サービス種別), "HeartbeatIntervalSeconds" -> 1, "PackageRoot" -> Automatic

### SourceVaultStopService[serviceId, opts]
Stop command を queue に入れ、必要なら pid 検証後に kill する。

### SourceVaultRestartService[serviceId, opts]
stop してから同プロファイルで start する。

### SourceVaultServiceStatus[serviceId] → Association
`pid.json` / `status.json` / `heartbeat.json` から状態 association を返す。

### SourceVaultServiceHealth[serviceId] → String
heartbeat の鮮度から `"OK"` / `"Degraded"` / `"Failing"` を返す。

### SourceVaultInstallWatchdog[serviceId, opts]
軽量 PowerShell ウォッチドッグを常駐起動する。wscript hidden launcher 経由で一度だけ起動し、while ループで自前 sleep しながら常駐する(フリッカなし)。WL カーネルを spawn しない(ライセンス/電力配慮)。heartbeat 失効または crash 検知時に wedge ログを退避し pid kill して既存サービスタスクを再実行する。意図停止(State=Stopped)は復活させない。多重常駐は named mutex で 1 本に抑止する。
Options: "StaleSeconds" -> 90 (heartbeat 失効秒), "IntervalMinutes" -> 2 (ループ巡回間隔)

### SourceVaultUninstallWatchdog[serviceId]
watchdog scheduled task を削除し、常駐 PowerShell プロセスを kill する。

### SourceVaultWatchdogStatus[serviceId] → Association
watchdog task 登録の有無・常駐プロセスの生存(ProcessAlive)・`watchdog.log.jsonl` の再起動履歴を返す。

### SourceVaultServiceRootHealth[serviceId] → Association
service の root/ユーザが main kernel と整合しているかを返す(spec v6 §3.6/§3.10)。
キー: `RootHashMatch`, `MainRootHash`, `ServiceRootHash`, `UserMatch`, `MainUser`, `ServiceUser`, `LocalStatePath`, `LocalStateWritable`, `CoreRootPath`, `Warnings`, `Healthy`。
`RootHashMismatch` = root 変更後の未再起動、`UserMismatch` = `%LOCALAPPDATA%` 分裂の恐れを示す。

### SourceVaultServicePing[serviceId, opts]
Ping command を送り、command queue 経由で Pong を待つ。

### SourceVaultListServices[] → List
`runtime/services` 配下の service とその状態を返す。

### SourceVaultServiceLogs[serviceId, opts] → List
`service.log.jsonl` の event を返す。
Options: "Limit" -> n

### SourceVaultTailServiceLog[serviceId, n:20] → List
`service.log.jsonl` の末尾 n 件を返す。

### SourceVaultSendServiceCommand[serviceId, command] → Association
command(Association、`"Command"` キー必須)を queue に書く。
→ `<|"Status", "CommandId"|>`

### SourceVaultServiceCommandResult[serviceId, commandId] → Association
処理済み command の結果を返す。未処理なら `"Pending"`。

### SourceVaultRecoverServices[opts]
status が Running だが pid が死んでいる孤児 service を Crashed に更新する。
Options: "Kill" -> True (pid 同一性確認後に kill する)

### SourceVaultServiceDoctor[serviceId] → Association
runtime dir / pid / heartbeat / status の整合を点検する。

### SourceVaultServiceMain[kind, serviceId, opts]
detached service process 側の runner entrypoint。生成された `run.wls` から呼ばれる。pid/status/heartbeat を書き、command queue を処理し、Stop で終了する。メインカーネルから直接呼ばない(`SourceVaultStartService` 経由)。

### SourceVaultServiceRuntimeDir[serviceId] → String | Failure
service の runtime directory を返す。パス構成: `<CoreRoot>/runtime/<MachineName>/services/<serviceId>`。

## Python HTTP リバースプロキシ

### $SourceVaultPython
型: String | Automatic, 初期値: Automatic
python 実行ファイルのオーバーライド。Automatic で PATH 上の `python3`/`python` を解決する。

### SourceVaultPublishProxyCodeSnapshot[opts] → Association
組込みの proxy Python ソースを immutable snapshot(`SourceVaultProxyCode`)として vault に保存する。alias: `"sv-http-proxy"`。
→ `<|"Status", "Ref", "Digest", "CodeSHA256"|>`

### SourceVaultMaterializeProxyCode[targetDir, opts] → Association
proxy code を `targetDir/proxy.py` へ出力し、SHA256 を検証する。不一致なら fail-closed。
Options: "CodeRef" -> Automatic (Automatic で組込みソース使用、snapshot ref 指定も可)

### SourceVaultStartHTTPProxy[serviceId, opts]
serviceId の WL service を front する Python HTTP proxy を detached 起動する。`proxy.py` を vault data から materialize + digest 検証し、stdlib のみで `/sv/health` `/sv/search` `/sv/admin/status` を提供する。gate は WL service 側。proxy は status/heartbeat の直読みと command queue 中継のみで raw vault を公開しない。
Options: "Port" (または "EndpointProfile", 必須), "RoutePrefix" -> "/sv", "ReleaseContext", "PDFIndexProfile", "Bind" -> "127.0.0.1", "CodeRef"

### SourceVaultStopHTTPProxy[serviceId]
Python proxy を停止し scheduled task を削除する。

### SourceVaultHTTPProxyStatus[serviceId] → Association
proxy の pid / 生存 / port を返す。

### SourceVaultProxyRuntimeDir[serviceId] → String
proxy の runtime directory を返す。

## MCP サーバ起動/停止 ラッパー

### $SourceVaultMCPServiceId
型: String, 初期値: `"sourcevault"`
MCP サーバの既定 serviceId。

### $SourceVaultMCPPort
型: Integer | Automatic, 初期値: Automatic
MCP proxy の既定ポート。Automatic で既存 `proxy.config.json` から解決、無ければ 8731。SearXNG(8888)/LM Studio(1234) と衝突しない値を設定する。

### $SourceVaultMCPToken
型: String | None | Automatic, 初期値: Automatic
`/sv/mcp` の既定トークン。Automatic で既存設定から解決、無ければ None(localhost 無認証)。文字列なら `X-SourceVault-Token` ヘッダで要求する。

### SourceVaultStartMCP[opts] → Association
MCP サーバ(WL service + HTTP/MCP proxy)を一括起動する。Port/MCPToken は Automatic なら既存 `proxy.config.json` から自動解決(env 依存値を直書きしない)。
→ `<|"Status", "ServiceId", "Port", "Url", "Service", "Proxy"|>`
Options: "ServiceId" -> $SourceVaultMCPServiceId, "Port" -> $SourceVaultMCPPort, "MCPToken" -> $SourceVaultMCPToken, "RestartService" -> False

### SourceVaultStopMCP[opts]
MCP の proxy と WL service を停止する。
Options: "ServiceId" -> $SourceVaultMCPServiceId

### SourceVaultMCPRunningQ[opts] → True | False
MCP proxy が実際に到達可能か(`/health` への HTTP 接続成功)を返す。pid 生存だけに頼らないため stale/再利用 pid での誤検知がない。
Options: "ServiceId" -> $SourceVaultMCPServiceId

### SourceVaultMCPStatus[opts] → Association
MCP の状態と公開 URL を返す。`"Running"` は実到達性(/health 接続成功)。`"ProxyState"` / `"ProxyPidAlive"` は pid ベース。両者が食い違う場合(PidAlive だが Running 偽)は stale/再利用 pid を示す。
Options: "ServiceId" -> $SourceVaultMCPServiceId

## チャネルパイプライン / mail / Discord / OutputGate (§9.8, §13, §17.9)

### SourceVaultMakeQuestionEnvelope[channel, inputText, opts] → Association
統一入力 QuestionEnvelope を作る(§9.8)。
channel: `"Web"` / `"Mail"` / `"Discord"` / `"Voice"` / `"VRSNS"`
Options: "ReleaseContext" (必須), "Audience", "LatencyProfile", "AllowedIndexes" -> {...}, "PDFIndexProfile", "Requester"

### SourceVaultAnswerChannelQuery[envelope, opts] → Association
envelope を検索 → evidence draft 化する。gate 済み `SourceVaultSearch` を使用。Mail は `NeedsHumanReview`(draft のみ)、Discord は低 risk のみ `Answered`。LLM を呼ばない(evidence ベース)。
→ `<|"Decision", "AnswerDraft", "Evidence", "Citations", ...|>`

### SourceVaultMakeMailReplyDraft[envelope, opts] → Association
mail 返信 draft を作る。自動送信は一切しない(§13 Phase 6)。

### SourceVaultEvaluateOutputGate[draft, outputAdapter, opts] → Association
出力可否を判定する(§17.9)。adapter の PrivacyMax / ReleaseContextRequired / AllowedEventKinds / RequireApproval / raw media を評価する。
→ `<|"Decision" -> "Permit"|"NeedsApproval"|"Deny"|"RedactRequired", ...|>`

### SourceVaultDispatchOutput[draft, outputAdapter, opts] → Association
OutputGate を通してから出力する。mail は送信せず draft を返す。Discord は gate Permit かつ `"Approved"->True` かつ `"ReallySend"->True` の時のみ webhook 送信。既定は送信せず `Prepared` / `NeedsApproval` を返す(fail-safe)。
Options: "Approved" -> False, "ReallySend" -> False

## ActionDraft / ActionGate (§9.9, §16.2)

### SourceVaultMakeActionDraft[kind, payload, opts] → Association
ActionDraft を作る(§9.9)。
kind: `"Speak"` / `"Gesture"` / `"Expression"` / `"Move"` / `"ShowPanel"` / `"CallTool"`
Options: "CapabilityProfile", "Audience", "ReleaseContext", "Target", "EvidenceRefs"

### SourceVaultEvaluateActionGate[actionDraft, opts] → Association
capability profile に基づき action 可否を判定する(§9.9)。world 変更(Move/CallTool)は `AllowWorldControl` が無ければ Deny。
→ `<|"Decision" -> "Permit"|"RequiresApproval"|"Deny", ...|>`

### SourceVaultListCaptureSources[] → List
登録済み capture source を返す。

### SourceVaultTestCaptureSource[name] → Association
capture source プロファイルの解決可否を fail-closed で点検する(実 capture はしない)。

## マルチモーダル ingest / live session (§17, Phase 7b)

### SourceVaultIngestCapturedMedia[sessionId, kind, data, opts]
capture 由来データを vault に取り込む(§17.4, §17.11)。data が `ByteArray` なら content-addressed blob に commit、`String` なら Text として記録。MultimodalEvent を append する。
Options: "PersistRaw" -> True, "SourceRef", "Tags", "State", "PrivacyLevel"

### SourceVaultUpdateLiveSummary[sessionId, summary]
live summary pointer を更新し `SystemSummary` event を残す(§17.6)。

### SourceVaultGetLiveSummary[sessionId] → String
現在の live summary を返す。

### SourceVaultGetLiveEvents[sessionId, opts] → List
session の MultimodalEvent を返す(§17.7)。

### SourceVaultGetLiveTranscript[sessionId] → String
session の ASR transcript を連結して返す。

### SourceVaultAskLiveSession[sessionId, question, opts]
UserQuestion を記録し command を enqueue する(§17.7)。メインカーネルは LLM を直接呼ばず、service 側が処理する。

### SourceVaultRegisterMultimodalWorkflow[name, spec] → Association
multimodal workflow(PresentationListenerCompat 等)を登録する(§17.6)。

### SourceVaultListMultimodalWorkflows[] → List
登録済み multimodal workflow を返す。

### SourceVaultSchedulePostprocess[sessionId, spec]
後処理(ASRImprove / Summary / PurposeIndexBuild 等)を予約 event として記録する(§17.11)。

## ServiceVersionSnapshot / version switching (§8.6-8.7, §8.14, Phase 4)

### SourceVaultCreateServiceVersionSnapshot[serviceId, spec] → Association
ServiceVersionSnapshot を immutable 保存する(§8.6)。spec に `WorkflowSnapshotRef` / `CorpusSnapshotRef` / `IndexSnapshotRefs` / `ReleaseContextRef` 等を持つ。credential / 実パス / IP を含めてはならない(profile ref のみ)。

### SourceVaultListServiceVersions[serviceId] → List
作成済み service version の `{Version, Ref, CreatedAtUTC}` を返す。

### SourceVaultServiceVersionInfo[serviceId, version] → Association
指定 version の snapshot を返す。version 省略で active を返す。

### SourceVaultActivateServiceVersion[serviceId, versionOrRef, opts]
active service version を切り替える(§8.7)。digest 検証 + IndexSnapshotRefs の解決可能性を確認し fail-closed。active pointer を pointer event で更新する。

### SourceVaultActiveServiceVersion[serviceId] → String
現在 active な service version ref を返す(pointer replay)。

### SourceVaultRollbackServiceVersion[serviceId, opts]
一つ前の active version へ戻し、rollback log を残す。
Options: "Reason" -> ""

### SourceVaultCompareServiceVersions[serviceId, v1, v2] → Association
二つの service version snapshot の主要 ref 差分を返す。

## Web UI / LLM バックエンド設定

### $SourceVaultWebLLMBase
型: String, 初期値: `"http://localhost:1234"`
LM Studio (ローカル LLM) のエンドポイント base URL。

### $SourceVaultWebChatModel
型: String | Automatic, 初期値: Automatic
Web UI チャット用のデフォルトモデル名。Automatic で LM Studio `/api/v0/models` から loaded かつ非 thinking モデルを自動選択する。

### $SourceVaultOwnerIPs
型: List, 初期値: `{"127.0.0.1", "::1", "localhost"}`
オーナー PC の IP アドレスリスト。ClaudeCode/Codex(サブスク CLI)の使用可否判定に使う。

### $SourceVaultBillingAllowed
型: True | False, 初期値: False
課金 API(Anthropic Messages API 従量課金)の使用許可フラグ。

### $SourceVaultWebBilledModel
型: String, 初期値: `"claude-sonnet-4-6"`
課金 API 使用時のデフォルトモデル ID。

### SourceVaultRegisterOwnerIP[ip] → List
`$SourceVaultOwnerIPs` に IP を追加する(重複は無視)。更新後のリストを返す。

### SourceVaultSetBillingAllowed[b] → True | False
`$SourceVaultBillingAllowed` を設定する。引数は `True` または `False`。