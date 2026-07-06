# SourceVault_servicemanager API リファレンス

## 概要
SourceVault_servicemanager.wl は SourceVault 検索拡張のうち control/channel plane を担当する。load order (§2.4): SourceVault.wl → SourceVault_core.wl → SourceVault_searchindex.wl → SourceVault_servicemanager.wl。依存: SourceVault_core.wl, SourceVault_searchindex.wl。仕様書: sourcevault_websearch_extension_spec_v0_10.md。

段階実装: 今回の増分 (Phase1) は control 側 — private local init 読み込み、service/endpoint/credential profile registry、personal config doctor。後続増分 (Phase2+): detached WolframScript service 起動・停止・監視、manifest、heartbeat、command queue、WebServer route、channel adapter、ActionGate、ServiceVersionSnapshot active pointer、version switch/rollback。

非衝突方針: private helper は `SourceVault\`ServiceManagerPrivate\`` 文脈に置く。

## ローカル設定 (§5.2, §5.3)

### SourceVaultLocalConfigRoot[] → String | Failure
PrivateVault 直下の config/local ディレクトリパスを返す。未解決なら Failure["PrivateVaultUnresolved", ...]。

### SourceVaultLoadLocalInit[opts]
`<PrivateVault>/config/local/SourceVaultLocalInit.wl` を読み込む。存在しなければ fail-closed せず NotFound を返す (推測 fallback はしない)。
→ Association <|"Status"->"Loaded"|"NotFound"|"LoadError", "Path"->...|>
Options: "Path" -> Automatic (明示パス指定)

### SourceVaultLocalConfigStatus[] → Association
local init の有無と登録済み search/service profile の summary を返す。<|"LocalConfigRoot", "LocalInitPath", "LocalInitExists", "SearchProfiles", "ServiceProfiles"|>。

### SourceVaultLocalConfigDoctor[opts] → Association
必須 registry (ReleaseContext / SearchBackend / WebServiceEndpoint) が登録済みかを点検し不足を報告する。<|"Status"->"OK"|"Incomplete", "Missing"->{...}, "ReleaseContexts", "SearchBackends", "WebServiceEndpoints"|>。

## service/endpoint/channel registry (§5.3, §9.x, §16.8)
各 `SourceVaultRegisterXxx` は name(String), spec(Association) を登録する。`SourceVaultResolveServiceProfile[kind,name]` で解決し、未登録は Failure["UnregisteredProfile", ...] で fail-closed する。

### SourceVaultRegisterWebServiceEndpoint[name, spec] → Association
WebService endpoint を登録する。spec 必須キー: "BindAddress", "Port"。不足時 Failure["InvalidSpec", ...]。

### SourceVaultResolveWebServiceEndpoint[name] → Association | Failure
endpoint を解決する。未登録なら fail-closed。

### SourceVaultRegisterChannelEndpoint[name, spec] → Association
mail/Discord 等の channel endpoint を登録する。

### SourceVaultRegisterVoiceBackend[name, spec] → Association
STT/TTS/realtime voice backend を登録する。

### SourceVaultRegisterVRSNSAdapter[name, spec] → Association
VRSNS adapter を登録する。

### SourceVaultRegisterCapabilityProfile[name, spec] → Association
avatar/world capability profile を登録する。

### SourceVaultRegisterLLMBackend[name, spec] → Association
headless LLM backend を登録する (§16.9.1)。既定は API 直叩き/trusted local server、CLI は HeadlessSafe test 合格時のみ。

### SourceVaultRegisterCaptureSource[name, spec] → Association
audio/camera/screen capture source を登録する (§17.3)。DeviceRef/WindowRef は symbolic ref とし、実デバイス名は private local init で解決する。

### SourceVaultRegisterOutputAdapter[name, spec] → Association
Discord 等の output adapter を登録する (§17.9)。

### SourceVaultResolveServiceProfile[kind, name] → Association | Failure
ServiceManager registry の profile を解決する。kind: "WebServiceEndpoint"/"ChannelEndpoint"/"VoiceBackend"/"VRSNSAdapter"/"CapabilityProfile"/"LLMBackend"/"CaptureSource"/"OutputAdapter"。未登録は fail-closed。

### SourceVaultListServiceProfiles[] → Association
全 kind ごとの登録済み名前リストを返す。

### SourceVaultListServiceProfiles[kind] → {String...}
指定 kind の登録済み名前リストを返す。

### SourceVaultClearServiceRegistry[] → Association
ServiceManager registry を消去する (test / 再 init 用)。

## PDFGroupSearchProfile (§19, configuration-as-data)
PDF グループの検索 service 設定 (QueryScopeResolver/EvidencePolicy/AnswerPolicy 等) を一つの data object に束ねる。ドメイン固有をコードに焼かず、profile を差し替えるだけで別 PDF グループの app を立ち上げられる。MVP では sub-profile を inline field として持つ (将来は別 object 参照 + version snapshot 化)。

### SourceVault`SourceVaultCreatePDFGroupSearchProfile[groupAlias, spec] → Association
groupAlias で識別する PDFGroupSearchProfile を登録する。

### SourceVault`SourceVaultResolvePDFGroupSearchProfile[groupAlias] → Association | Failure
登録済み PDFGroupSearchProfile を解決する。未登録は fail-closed。

### SourceVault`SourceVaultListPDFGroupSearchProfiles[] → {String...}
登録済み groupAlias 一覧を返す。

### SourceVault`SourceVaultClonePDFGroupSearchProfile[srcAlias, newAlias, overrides:<||>] → Association | Failure
srcAlias の profile を newAlias として複製し、overrides で差分上書きする。srcAlias 未登録なら fail-closed。

## personal config doctor (§5.5)

### SourceVaultNoPersonalConfigDoctor[filesOrDirs, opts]
repository/配布対象に個人情報・環境依存値が混入していないか検査する。検出対象: IPv4 literal (各 octet<=255 検証、0.0.0.0/255.255.255.255 は除外)、localhost:port、Windows/macOS user path、credential らしき token (sk-..., Bearer ..., api_key/secret/token/password=...)、実 mail address、private vault root。ファイル先頭付近 (4000文字以内) に `doctor:private-design-doc` マーカーがある file は検査対象外。
→ Association <|"Status"->"OK"|"FindingsFound", "Findings"->{<|"File","Line","Kind","Match"|>...}, "FilesScanned", "Skipped", "FindingCount"|>
Options: "MailAllowlist" -> {} (許可 mail アドレスのリスト), "Extensions" -> Automatic (既定 {".wl",".wls",".m",".md",".json",".toml",".yaml",".yml"}), "Mask" -> True (True で match 文字列を先頭2文字+*** にマスク)

## detached service lifecycle (§9.3-9.6, §17.8。Phase2)
runtime directory はマシン単位に namespacing される (`runtime/<MachineName>/services/<serviceId>`) ため、Dropbox 等の共有 vault でも他マシンと衝突しない。

### SourceVaultStartService[serviceId, opts]
detached WolframScript service を起動する。メイン Mathematica を終了しても service process は heartbeat を更新し続ける。
→ Association <|"Status", "ServiceId", "PID", "RuntimeDir"|>
Options: "Kind" -> "heartbeat", "HeartbeatIntervalSeconds" -> 1, "PackageRoot" -> Automatic

### SourceVaultStopService[serviceId, opts] → Association
Stop command を queue に入れ、必要なら pid 検証後に kill する。

### SourceVaultRestartService[serviceId, opts] → Association
stop してから同 profile で start する。

### SourceVaultServiceStatus[serviceId] → Association
pid.json / status.json / heartbeat.json から状態 association を返す。

### SourceVaultServiceHealth[serviceId] → "OK" | "Degraded" | "Failing"
heartbeat の鮮度から健全性を返す。

### SourceVaultInstallWatchdog[serviceId, opts]
軽量 PowerShell ウォッチドッグを常駐起動する。wscript の hidden launcher 経由で一度だけ起動し、以後は PowerShell 内の while ループで自前 sleep して常駐する (周期タスクではないためコンソール窓のフリッカは発生しない)。WL カーネルは spawn しない (ライセンス/電力配慮)。heartbeat 失効 or crash を検知すると stdout.wedge-*.log へログを退避し pid を kill して既存サービスタスクを再実行する (run.wls 再利用=root 再注入なし)。意図停止 (status.State=Stopped) は復活させない。多重常駐は named mutex で1本に抑止する。
→ Association
Options: "StaleSeconds" -> 90 (heartbeat 失効秒), "IntervalMinutes" -> 2 (ループ巡回間隔)

### SourceVaultUninstallWatchdog[serviceId] → Association
watchdog scheduled task を削除し、常駐 PowerShell プロセスも kill する。

### SourceVaultWatchdogStatus[serviceId] → Association
watchdog task 登録の有無・常駐プロセスの生存 (ProcessAlive)・watchdog.log.jsonl の再起動履歴を返す。

### SourceVaultServiceRootHealth[serviceId] → Association
service の root/ユーザが main kernel と整合しているかを返す (spec v6 §3.6/§3.10)。<|"RootHashMatch", "MainRootHash", "ServiceRootHash", "UserMatch", "MainUser", "ServiceUser", "LocalStatePath", "LocalStateWritable", "CoreRootPath", "Warnings", "Healthy"|>。RootHashMismatch は root 変更後の未再起動、UserMismatch は %LOCALAPPDATA% 分裂の恐れを示す。

### SourceVaultServicePing[serviceId, opts] → Association
Ping command を送り、command queue 経由で Pong を待つ。

### SourceVaultListServices[] → Association
runtime/services 配下の service とその状態を返す。

### SourceVaultServiceLogs[serviceId, opts] → {Association...}
service.log.jsonl の event を返す。
Options: "Limit"

### SourceVaultTailServiceLog[serviceId, n:20] → {Association...}
service.log.jsonl の末尾 n 件を返す。

### SourceVaultSendServiceCommand[serviceId, command] → Association
command (Association, "Command" key 必須) を queue に書く。
→ <|"Status", "CommandId"|>

### SourceVaultServiceCommandResult[serviceId, commandId] → Association
処理済み command の結果を返す (未処理なら Pending)。

### SourceVaultRecoverServices[opts] → Association
status Running だが pid が死んでいる孤児 service を Crashed に更新する。
Options: "Kill" -> False (True で pid 同一性確認後に kill)

### SourceVaultServiceDoctor[serviceId] → Association
runtime dir / pid / heartbeat / status の整合を点検する。

### SourceVaultServiceMain[kind, serviceId, opts]
detached service process 側の runner entrypoint。generated run.wls から呼ばれる。pid/status/heartbeat を書き、command queue を処理し、Stop で終了する。メインカーネルからは直接呼ばない (StartService 経由で使う)。

### SourceVaultServiceRuntimeDir[serviceId] → String | Failure
service の runtime directory を返す (`runtime/<MachineName>/services/<serviceId>`)。

## Python HTTP リバースプロキシ
SocketListen が headless で不可なための edge。proxy code は SourceVault data として保存し、起動時に working へ materialize + digest 検証して実行する。

### $SourceVaultPython
型: String | Automatic, 初期値: Automatic
python 実行ファイルの override。Automatic で PATH 上の python3/python を解決する。

### SourceVaultPublishProxyCodeSnapshot[opts] → Association
組込みの proxy Python ソースを immutable snapshot (SourceVaultProxyCode) として vault に保存する。alias "sv-http-proxy"。
→ <|"Status", "Ref", "Digest", "CodeSHA256"|>

### SourceVaultMaterializeProxyCode[targetDir, opts] → Association
proxy code を targetDir/proxy.py へ出力する。出力後に SHA256 を検証し不一致なら fail-closed。
Options: "CodeRef" -> Automatic (snapshot ref。Automatic は組込みソース)

### SourceVaultStartHTTPProxy[serviceId, opts]
serviceId の WL service を front する Python HTTP proxy を detached 起動する。proxy.py を vault data から materialize+digest検証し、stdlib のみで /sv/health /sv/search /sv/admin/status を提供する。gate は WL service 側にあり、proxy は status/heartbeat の直読みと command queue 中継のみで raw vault を公開しない。
→ Association
Options: "Port" (必須。または "EndpointProfile"), "RoutePrefix" -> "/sv", "ReleaseContext", "PDFIndexProfile", "Bind" -> "127.0.0.1", "CodeRef"

### SourceVaultStopHTTPProxy[serviceId] → Association
Python proxy を停止し scheduled task を削除する。

### SourceVaultHTTPProxyStatus[serviceId] → Association
proxy の pid / 生存 / port を返す。

### SourceVaultProxyRuntimeDir[serviceId] → String
proxy の runtime directory を返す。

## MCP サーバ (WL service + HTTP/MCP proxy の一括制御)

### SourceVaultStartMCP[opts]
MCP サーバ (WL service + HTTP/MCP proxy) を一括起動する。WL service を確保し、/sv/mcp を公開する Python proxy を起動する。Port/MCPToken が Automatic なら既存サービスの proxy.config.json から自動解決する (env 依存値を直書きしない)。
→ <|"Status", "ServiceId", "Port", "Url", "Service", "Proxy"|>
Options: "ServiceId" -> $SourceVaultMCPServiceId, "Port" -> Automatic, "MCPToken" -> Automatic, "RestartService" -> False

### SourceVaultStopMCP[opts] → Association
MCP の proxy と WL service を停止する。
Options: "ServiceId" -> $SourceVaultMCPServiceId

### SourceVaultMCPRunningQ[opts] → True | False
MCP proxy が実際に到達可能か (proxy の /health へ HTTP 接続成功) を返す。pid 生存だけに頼らないので stale/再利用 pid でも誤検知しない。
Options: "ServiceId" -> $SourceVaultMCPServiceId

### SourceVaultMCPStatus[opts] → Association
MCP の状態と公開 URL を返す。"Running" は実到達性 (/health 接続成功)、"ProxyState"/"ProxyPidAlive" は pid ベース。両者が食い違う場合は stale/再利用 pid。
Options: "ServiceId" -> $SourceVaultMCPServiceId

### $SourceVaultMCPServiceId
型: String, 初期値: "sourcevault"
MCP サーバの既定 serviceId。

### $SourceVaultMCPPort
型: Integer | Automatic, 初期値: Automatic
MCP proxy の既定ポート (Automatic は既存 proxy.config.json から解決、無ければ 8731)。SearXNG(8888)/LM Studio(1234) と衝突しない値にする。

### $SourceVaultMCPToken
型: String | None | Automatic, 初期値: Automatic
/sv/mcp の既定トークン (Automatic は既存設定から解決、無ければ None=localhost 無認証)。文字列なら X-SourceVault-Token で要求する。

## channel pipeline / mail / Discord / OutputGate (§9.8, §13 Phase6, §17.9)

### SourceVaultMakeQuestionEnvelope[channel, inputText, opts] → Association
統一入力 QuestionEnvelope を作る。channel: "Web"|"Mail"|"Discord"|"Voice"|"VRSNS"。
Options 必須: "ReleaseContext"。任意: "Audience", "LatencyProfile", "AllowedIndexes" -> {...}, "PDFIndexProfile", "Requester"

### SourceVaultAnswerChannelQuery[envelope, opts] → Association
envelope を検索→evidence draft 化する。gate 済み SourceVaultSearch を使い、Mail は NeedsHumanReview (draft のみ)、Discord は低 risk のみ Answered。LLM は呼ばない (evidence ベース)。
→ <|"Decision", "AnswerDraft", "Evidence", "Citations", ...|>

### SourceVaultMakeMailReplyDraft[envelope, opts] → Association
mail 返信 draft を作る。自動送信は一切しない (§13 Phase6)。

### SourceVaultEvaluateOutputGate[draft, outputAdapter, opts] → Association
出力可否を判定する (§17.9)。判定基準: adapter の PrivacyMax / ReleaseContextRequired / AllowedEventKinds / RequireApproval / raw media。
→ Decision: "Permit"|"NeedsApproval"|"Deny"|"RedactRequired"

### SourceVaultDispatchOutput[draft, outputAdapter, opts] → Association
OutputGate を通してから出力する。mail は送信せず draft を返す。Discord は gate Permit かつ opts "Approved"->True かつ "ReallySend"->True の時のみ webhook 送信。既定は送信せず Prepared / NeedsApproval を返す (fail-safe)。

## ActionDraft / ActionGate (VRSNS avatar・world action 安全制御, §9.9, §16.2)

### SourceVaultMakeActionDraft[kind, payload, opts] → Association
ActionDraft を作る。kind: "Speak"|"Gesture"|"Expression"|"Move"|"ShowPanel"|"CallTool"。
Options: "CapabilityProfile", "Audience", "ReleaseContext", "Target", "EvidenceRefs"

### SourceVaultEvaluateActionGate[actionDraft, opts] → Association
capability profile に基づき action 可否を判定する (§9.9)。world 変更 (Move/CallTool) は AllowWorldControl が無ければ Deny。
→ Decision: "Permit"|"RequiresApproval"|"Deny"

### SourceVaultListCaptureSources[] → Association
登録済み capture source を返す。

### SourceVaultTestCaptureSource[name] → Association
capture source profile の解決可否を fail-closed で点検する (実 capture はしない)。

## マルチモーダル ingest / live session (§17。Phase7b)

### SourceVaultIngestCapturedMedia[sessionId, kind, data, opts] → Association
capture 由来データを vault に取り込む (§17.4, §17.11)。data が ByteArray なら content-addressed blob に commit (PersistRaw->True 時)、String なら Text として記録。MultimodalEvent を append。実 ffmpeg/ASR driver はこの関数を呼ぶ (device 非依存の取込点)。
Options: "PersistRaw" -> True, "SourceRef", "Tags", "State", "PrivacyLevel"

### SourceVaultUpdateLiveSummary[sessionId, summary] → Association
live summary pointer を更新し SystemSummary event を残す (§17.6)。

### SourceVaultGetLiveSummary[sessionId] → String | Association
現在の live summary を返す。

### SourceVaultGetLiveEvents[sessionId, opts] → {Association...}
session の MultimodalEvent を返す (§17.7)。

### SourceVaultGetLiveTranscript[sessionId] → String
session の ASR transcript を連結して返す。

### SourceVaultAskLiveSession[sessionId, question, opts] → Association
UserQuestion を記録し command を enqueue する (§17.7)。メインカーネルは LLM を直接呼ばず、service 側が処理する。

### SourceVaultRegisterMultimodalWorkflow[name, spec] → Association
multimodal workflow (PresentationListenerCompat 等) を登録する (§17.6)。

### SourceVaultListMultimodalWorkflows[] → {String...}
登録済み multimodal workflow を返す。

### SourceVaultSchedulePostprocess[sessionId, spec] → Association
後処理 (ASRImprove/Summary/PurposeIndexBuild 等) を予約 event として記録する (§17.11)。

## ServiceVersionSnapshot / version switching (§8.6-8.7, §8.14。Phase4)

### SourceVaultCreateServiceVersionSnapshot[serviceId, spec] → Association
ServiceVersionSnapshot を immutable 保存する (§8.6)。spec は WorkflowSnapshotRef / CorpusSnapshotRef / IndexSnapshotRefs / ReleaseContextRef 等を持つ。credential / 実 path / IP を含めてはならない (profile ref のみ)。

### SourceVaultListServiceVersions[serviceId] → {Association...}
作成済み service version の {Version, Ref, CreatedAtUTC} を返す。

### SourceVaultServiceVersionInfo[serviceId, version] → Association
指定 version の snapshot を返す (version 省略で active)。

### SourceVaultActivateServiceVersion[serviceId, versionOrRef, opts] → Association
active service version を切り替える (§8.7)。digest 検証 + IndexSnapshotRefs の解決可能性を確認し fail-closed。active pointer を pointer event で更新する。

### SourceVaultActiveServiceVersion[serviceId] → Association
現在 active な service version ref を返す (pointer replay)。

### SourceVaultRollbackServiceVersion[serviceId, opts] → Association
一つ前の active version へ戻し、rollback log を残す。
Options: "Reason"

### SourceVaultCompareServiceVersions[serviceId, v1, v2] → Association
二つの service version snapshot の主要 ref 差分を返す。

## Web LLM チャットバックエンド設定 (課金/ライセンスポリシー)
Web UI の /pdfask 回答合成が呼ぶローカル/クラウド LLM の解決先を制御する変数群。ClaudeCode/Codex 等のサブスク CLI は契約者本人 (オーナー PC) のみ利用可とするポリシーで、client IP がオーナー IP と一致する場合のみサブスクバックエンドを許可する (非オーナーは課金 API かローカル LLM に降格)。

### $SourceVaultWebLLMBase
型: String, 初期値: "http://localhost:1234"
LM Studio 等ローカル LLM の base URL。

### $SourceVaultWebChatModel
型: String | Automatic, 初期値: Automatic
/pdfask 回答合成に使うモデル指定。"cloud"/"cloud:<model>" でサブスク CLI、"api"/"api:<model>" で課金 API、それ以外はローカルモデル名として解決する。

### $SourceVaultOwnerIPs
型: {String...}, 初期値: {"127.0.0.1", "::1", "localhost"}
サブスク CLI (ClaudeCode/Codex) 利用を許可するオーナー PC の client IP リスト。

### $SourceVaultBillingAllowed
型: True | False, 初期値: False
課金 API (Anthropic Messages API) の利用を許可するか。

### $SourceVaultWebBilledModel
型: String, 初期値: "claude-sonnet-4-6"
課金 API の既定モデル。

### SourceVault`SourceVaultRegisterOwnerIP[ip] → {String...}
$SourceVaultOwnerIPs に ip を追加登録する (重複しない)。

### SourceVault`SourceVaultSetBillingAllowed[b] → True | False
$SourceVaultBillingAllowed を設定する。