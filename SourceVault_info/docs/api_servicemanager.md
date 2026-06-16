# SourceVault_servicemanager API リファレンス

パッケージ: `SourceVault`
GitHub: https://github.com/transreal/SourceVault_servicemanager
依存: [SourceVault_core](https://github.com/transreal/SourceVault_core), [SourceVault_searchindex](https://github.com/transreal/SourceVault_searchindex)
ロード順: SourceVault.wl → SourceVault_core.wl → SourceVault_searchindex.wl → SourceVault_servicemanager.wl
ロード方法: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_servicemanager.wl"]]`

## ローカル init / config (§5.2, §5.3)

### SourceVaultLocalConfigRoot[] → String | Failure
`<PrivateVault>/config/local` のパスを返す。`$SourceVaultCoreRoot` または `$SourceVaultRoots["PrivateVault"]` から解決。未解決なら Failure["PrivateVaultUnresolved"]。

### SourceVaultLoadLocalInit[opts]
`<PrivateVault>/config/local/SourceVaultLocalInit.wl` を読み込む。不在なら fail-closed せず `<|"Status"->"NotFound"|>` を返す。
→ `<|"Status" -> "Loaded"|"NotFound"|"LoadError", "Path" -> ...|>`
Options: "Path" -> Automatic (Automatic で LocalConfigRoot から自動構築、明示パスも可)

### SourceVaultLocalConfigStatus[] → Association
local init の有無・登録済みプロファイルの summary を返す。キー: Status, LocalConfigRoot, LocalInitPath, LocalInitExists, SearchProfiles, ServiceProfiles。

### SourceVaultLocalConfigDoctor[opts] → Association
必須 registry (ReleaseContext / SearchBackend / WebServiceEndpoint) の登録状況を点検し不足を報告する。
→ `<|"Status" -> "OK"|"Incomplete", "Missing" -> {...}, "ReleaseContexts", "SearchBackends", "WebServiceEndpoints"|>`

## サービス / エンドポイント / チャンネル registry (§5.3, §9.x, §16.8)

### SourceVaultRegisterWebServiceEndpoint[name, spec] → Association | Failure
WebService エンドポイントを登録する。spec 必須フィールド: `"BindAddress"`, `"Port"`。不足なら Failure["InvalidSpec"]。

### SourceVaultResolveWebServiceEndpoint[name] → Association | Failure
登録済み WebServiceEndpoint を解決する。未登録なら Failure["UnregisteredProfile"] (fail-closed)。

### SourceVaultRegisterChannelEndpoint[name, spec] → Association
mail / Discord 等のチャンネルエンドポイントを登録する。spec は自由 Association。

### SourceVaultRegisterVoiceBackend[name, spec] → Association
STT / TTS / realtime voice backend を登録する。

### SourceVaultRegisterVRSNSAdapter[name, spec] → Association
VRSNS adapter を登録する。

### SourceVaultRegisterCapabilityProfile[name, spec] → Association
avatar / world capability profile を登録する。

### SourceVaultRegisterLLMBackend[name, spec] → Association
headless LLM backend を登録する (§16.9.1)。既定は API 直叩き / trusted local server。CLI は HeadlessSafe test 合格時のみ。

### SourceVaultRegisterCaptureSource[name, spec] → Association
audio / camera / screen capture source を登録する (§17.3)。DeviceRef / WindowRef は symbolic ref とし、実デバイス名は private local init で解決する。

### SourceVaultRegisterOutputAdapter[name, spec] → Association
Discord 等の output adapter を登録する (§17.9)。

### SourceVaultResolveServiceProfile[kind, name] → Association | Failure
ServiceManager registry から指定 kind / name のプロファイルを解決する。未登録なら Failure["UnregisteredProfile"] (fail-closed)。
kind の有効値: `"WebServiceEndpoint"` / `"ChannelEndpoint"` / `"VoiceBackend"` / `"VRSNSAdapter"` / `"CapabilityProfile"` / `"LLMBackend"` / `"CaptureSource"` / `"OutputAdapter"`

### SourceVaultListServiceProfiles[] → Association
全 kind の登録名リストを `<|"WebServiceEndpoint" -> {...}, ...|>` で返す。

### SourceVaultListServiceProfiles[kind] → List
指定 kind の登録名リストを返す。

### SourceVaultClearServiceRegistry[] → Association
ServiceManager registry を全消去する (テスト / 再 init 用)。→ `<|"Status" -> "OK"|>`

## PDFGroupSearchProfile (§19)

### SourceVaultCreatePDFGroupSearchProfile[groupAlias, spec] → Association
PDF グループの検索サービス設定を configuration-as-data オブジェクトとして registry に登録する。spec は QueryScopeResolver / EvidencePolicy / AnswerPolicy 等を inline フィールドとして持つ。

### SourceVaultResolvePDFGroupSearchProfile[groupAlias] → Association | Failure
登録済み PDFGroupSearchProfile を解決する。未登録なら Failure["UnregisteredProfile"]。

### SourceVaultListPDFGroupSearchProfiles[] → List
登録済み PDFGroupSearchProfile の alias 名リストを返す。

### SourceVaultClonePDFGroupSearchProfile[srcAlias, newAlias, overrides] → Association | Failure
srcAlias のプロファイルを複製して newAlias で登録する。overrides で差分フィールドを上書きする。overrides 省略時は `<||>`。srcAlias 未登録なら Failure を返す。

例: `SourceVaultClonePDFGroupSearchProfile["base", "2025", <|"Year" -> 2025|>]`

## personal config doctor (§5.5)

### SourceVaultNoPersonalConfigDoctor[filesOrDirs, opts]
リポジトリ / 配布対象に個人情報・環境依存値が混入していないか検査する。
検出対象: IPv4 literal (octet 検証付き、0.0.0.0 / 255.255.255.255 は除外), localhost:port, Windows/macOS ユーザパス, credential らしき token (sk-..., Bearer ..., api_key= 等), 実メールアドレス。ファイル先頭付近に `doctor:private-design-doc` マーカーがあるファイルは検査対象外。
→ `<|"Status" -> "OK"|"FindingsFound", "Findings" -> {<|"File", "Line", "Kind", "Match"|>,...}, "FilesScanned", "Skipped", "FindingCount"|>`
Options: "MailAllowlist" -> {} (除外するメールアドレスリスト), "Extensions" -> Automatic (Automatic = {".wl",".wls",".m",".md",".json",".toml",".yaml",".yml"}), "Mask" -> True (True で検出値を先頭2文字+***にマスク)

例: `SourceVaultNoPersonalConfigDoctor[{"src/", "config/"}, "MailAllowlist" -> {"public@example.com"}, "Mask" -> False]`

## detached service ライフサイクル (§9.3-9.6, §17.8。Phase 2)

### SourceVaultStartService[serviceId, opts]
detached WolframScript service を起動する。メイン Mathematica を終了しても service process は heartbeat を更新し続ける。
→ `<|"Status", "ServiceId", "PID", "RuntimeDir"|>`
Options: "Kind" -> "heartbeat" (サービス種別), "HeartbeatIntervalSeconds" -> 1, "PackageRoot" -> Automatic

### SourceVaultStopService[serviceId, opts]
Stop command を queue に書き込み、必要なら pid 検証後に kill する。

### SourceVaultRestartService[serviceId, opts]
stop してから同プロファイルで start する。

### SourceVaultServiceStatus[serviceId] → Association
pid.json / status.json / heartbeat.json から状態 association を返す。

### SourceVaultServiceHealth[serviceId] → String
heartbeat の鮮度から `"OK"` / `"Degraded"` / `"Failing"` を返す。

### SourceVaultServiceRootHealth[serviceId] → Association
service の root / ユーザがメインカーネルと整合しているか検証する (spec v6 §3.6/§3.10)。
→ `<|"RootHashMatch", "MainRootHash", "ServiceRootHash", "UserMatch", "MainUser", "ServiceUser", "LocalStatePath", "LocalStateWritable", "CoreRootPath", "Warnings", "Healthy"|>`
RootHashMismatch は root 変更後の未再起動、UserMismatch は %LOCALAPPDATA% 分裂の恐れを示す。

### SourceVaultServicePing[serviceId, opts]
Ping command を送り command queue 経由で Pong を待つ。

### SourceVaultListServices[] → List
runtime/services 配下の全サービスとその状態を返す。

### SourceVaultServiceLogs[serviceId, opts] → List
service.log.jsonl の event リストを返す。
Options: "Limit" -> All

### SourceVaultTailServiceLog[serviceId, n:20] → List
service.log.jsonl の末尾 n 件を返す。

### SourceVaultSendServiceCommand[serviceId, command] → Association
command (Association、"Command" キー必須) を command queue に書き込む。
→ `<|"Status", "CommandId"|>`

### SourceVaultServiceCommandResult[serviceId, commandId] → Association
処理済み command の結果を返す。未処理なら `"Pending"` を含む association を返す。

### SourceVaultRecoverServices[opts] → Association
status Running だが pid が死んでいる孤児 service を Crashed に更新する。
Options: "Kill" -> True (True で pid 同一性確認後に kill)

### SourceVaultServiceDoctor[serviceId] → Association
runtime dir / pid / heartbeat / status の整合を点検する。

### SourceVaultServiceMain[kind, serviceId, opts]
detached service process 側の runner entrypoint。generated run.wls から呼ばれる。pid / status / heartbeat を書き、command queue を処理し、Stop で終了する。メインカーネルから直接呼ばない (StartService 経由)。

### SourceVaultServiceRuntimeDir[serviceId] → String | Failure
service の runtime directory パスを返す。

## Python HTTP リバースプロキシ

### $SourceVaultPython
型: String | Symbol, 初期値: Automatic
python 実行ファイルの override。Automatic で PATH 上の python3 / python を解決する。

### SourceVaultPublishProxyCodeSnapshot[opts] → Association
組込みの proxy Python ソースを immutable snapshot (SourceVaultProxyCode) として vault に保存する。alias "sv-http-proxy"。
→ `<|"Status", "Ref", "Digest", "CodeSHA256"|>`

### SourceVaultMaterializeProxyCode[targetDir, opts]
proxy code を `targetDir/proxy.py` へ出力する。出力後に SHA256 を検証し不一致なら fail-closed。
Options: "CodeRef" -> Automatic (Automatic = 組込みソース使用、snapshot ref も指定可)

### SourceVaultStartHTTPProxy[serviceId, opts]
serviceId の WL service を front する Python HTTP proxy を detached 起動する。proxy.py を vault data から materialize + digest 検証し、stdlib のみで `/sv/health` `/sv/search` `/sv/admin/status` を提供する。gate は WL service 側。proxy は status/heartbeat の直読みと command queue 中継のみで raw vault を公開しない。
必須 opts: "Port" (または "EndpointProfile")
Options: "RoutePrefix" -> "/sv", "ReleaseContext" -> None, "PDFIndexProfile" -> None, "Bind" -> "127.0.0.1", "CodeRef" -> Automatic

### SourceVaultStopHTTPProxy[serviceId]
Python proxy を停止し scheduled task を削除する。

### SourceVaultHTTPProxyStatus[serviceId] → Association
proxy の pid / 生存状態 / port を返す。

### SourceVaultProxyRuntimeDir[serviceId] → String
proxy の runtime directory を返す。

## MCP サーバ便利ラッパー

### $SourceVaultMCPServiceId
型: String, 初期値: "sourcevault"
MCP サーバの既定 serviceId。

### $SourceVaultMCPPort
型: Integer | Symbol, 初期値: Automatic
MCP proxy の既定ポート。Automatic で既存 proxy.config.json から解決、無ければ 8731。SearXNG(8888) / LM Studio(1234) と衝突しない値を設定する。

### $SourceVaultMCPToken
型: String | Symbol | None, 初期値: Automatic
/sv/mcp の既定トークン。Automatic で既存設定から解決、無ければ None (localhost 無認証)。文字列なら `X-SourceVault-Token` ヘッダで要求する。

### SourceVaultStartMCP[opts]
MCP サーバ (WL service + HTTP/MCP proxy) を一括起動する。`/sv/mcp` を公開する Python proxy を起動する。Port / MCPToken が Automatic なら既存 proxy.config.json から自動解決 (env 依存値を直書きしない)。
→ `<|"Status", "ServiceId", "Port", "Url", "Service", "Proxy"|>`
Options: "ServiceId" -> $SourceVaultMCPServiceId, "Port" -> Automatic, "MCPToken" -> Automatic, "RestartService" -> False

### SourceVaultStopMCP[opts]
MCP の proxy と WL service を停止する。
Options: "ServiceId" -> $SourceVaultMCPServiceId

### SourceVaultMCPRunningQ[opts] → True | False
MCP proxy が稼働中 (到達可能) かを返す。
Options: "ServiceId" -> $SourceVaultMCPServiceId

### SourceVaultMCPStatus[opts] → Association
MCP の service / proxy 状態と公開 URL をまとめて返す。
Options: "ServiceId" -> $SourceVaultMCPServiceId

## チャンネルパイプライン / mail / Discord / OutputGate (§9.8, §13, §17.9)

### SourceVaultMakeQuestionEnvelope[channel, inputText, opts] → Association
統一入力 QuestionEnvelope を作る (§9.8)。
channel: `"Web"` | `"Mail"` | `"Discord"` | `"Voice"` | `"VRSNS"`
必須 opts: "ReleaseContext"
Options: "Audience" -> None, "LatencyProfile" -> None, "AllowedIndexes" -> {}, "PDFIndexProfile" -> None, "Requester" -> None

### SourceVaultAnswerChannelQuery[envelope, opts] → Association
envelope を検索 → evidence draft 化する。gate 済み SourceVaultSearch を使い、Mail は NeedsHumanReview (draft のみ)、Discord は低 risk のみ Answered。LLM は呼ばない (evidence ベース)。
→ `<|"Decision", "AnswerDraft", "Evidence", "Citations", ...|>`

### SourceVaultMakeMailReplyDraft[envelope, opts] → Association
mail 返信 draft を作る。自動送信は一切しない (§13 Phase 6)。

### SourceVaultEvaluateOutputGate[draft, outputAdapter, opts] → Association
出力可否を判定する (§17.9)。adapter の PrivacyMax / ReleaseContextRequired / AllowedEventKinds / RequireApproval / raw media を検査する。
→ `<|"Decision" -> "Permit"|"NeedsApproval"|"Deny"|"RedactRequired", ...|>`

### SourceVaultDispatchOutput[draft, outputAdapter, opts] → Association
OutputGate を通してから出力する。mail は送信せず draft を返す。Discord は gate Permit かつ opts `"Approved"->True` かつ `"ReallySend"->True` のときのみ webhook 送信。既定は送信せず Prepared / NeedsApproval を返す (fail-safe)。
Options: "Approved" -> False, "ReallySend" -> False

## ActionDraft / ActionGate (§9.9, §16.2)

### SourceVaultMakeActionDraft[kind, payload, opts] → Association
ActionDraft を作る (§9.9)。
kind: `"Speak"` | `"Gesture"` | `"Expression"` | `"Move"` | `"ShowPanel"` | `"CallTool"`
Options: "CapabilityProfile" -> None, "Audience" -> None, "ReleaseContext" -> None, "Target" -> None, "EvidenceRefs" -> {}

### SourceVaultEvaluateActionGate[actionDraft, opts] → Association
capability profile に基づき action 可否を判定する (§9.9)。Move / CallTool は AllowWorldControl が無ければ Deny。
→ `<|"Decision" -> "Permit"|"RequiresApproval"|"Deny", ...|>`

### SourceVaultListCaptureSources[] → List
登録済み capture source 名リストを返す。

### SourceVaultTestCaptureSource[name] → Association
capture source profile の解決可否を fail-closed で点検する (実 capture はしない)。

## マルチモーダル ingest / live session (§17。Phase 7b)

### SourceVaultIngestCapturedMedia[sessionId, kind, data, opts]
capture 由来データを vault に取り込む (§17.4, §17.11)。data が ByteArray なら content-addressed blob に commit (PersistRaw->True 時)、String なら Text として記録。MultimodalEvent を append。実 ffmpeg / ASR driver がこの関数を呼ぶ (device 非依存の取込点)。
Options: "PersistRaw" -> True, "SourceRef" -> None, "Tags" -> {}, "State" -> None, "PrivacyLevel" -> None

### SourceVaultUpdateLiveSummary[sessionId, summary]
live summary pointer を更新し SystemSummary event を残す (§17.6)。

### SourceVaultGetLiveSummary[sessionId] → String | Missing
現在の live summary を返す。

### SourceVaultGetLiveEvents[sessionId, opts] → List
session の MultimodalEvent リストを返す (§17.7)。

### SourceVaultGetLiveTranscript[sessionId] → String
session の ASR transcript を連結して返す。

### SourceVaultAskLiveSession[sessionId, question, opts] → Association
UserQuestion を記録し command を enqueue する (§17.7)。メインカーネルは LLM を直接呼ばず、service 側が処理する。

### SourceVaultRegisterMultimodalWorkflow[name, spec] → Association
multimodal workflow (PresentationListenerCompat 等) を登録する (§17.6)。

### SourceVaultListMultimodalWorkflows[] → List
登録済み multimodal workflow 名リストを返す。

### SourceVaultSchedulePostprocess[sessionId, spec]
後処理 (ASRImprove / Summary / PurposeIndexBuild 等) を予約 event として記録する (§17.11)。

## ServiceVersionSnapshot / version 切り替え (§8.6-8.7, §8.14。Phase 4)

### SourceVaultCreateServiceVersionSnapshot[serviceId, spec] → Association
ServiceVersionSnapshot を immutable 保存する (§8.6)。spec は WorkflowSnapshotRef / CorpusSnapshotRef / IndexSnapshotRefs / ReleaseContextRef 等を持つ。credential / 実 path / IP を含めてはならない (profile ref のみ)。

### SourceVaultListServiceVersions[serviceId] → List
作成済み service version の `{<|"Version", "Ref", "CreatedAtUTC"|>,...}` を返す。

### SourceVaultServiceVersionInfo[serviceId, version] → Association
指定 version の snapshot を返す。version 省略で active version を返す。

### SourceVaultActivateServiceVersion[serviceId, versionOrRef, opts]
active service version を切り替える (§8.7)。digest 検証 + IndexSnapshotRefs の解決可能性を確認し fail-closed。active pointer を pointer event で更新する。

### SourceVaultActiveServiceVersion[serviceId] → String | Missing
現在 active な service version ref を返す (pointer replay)。

### SourceVaultRollbackServiceVersion[serviceId, opts] → Association
一つ前の active version へ戻し、rollback log を残す。
Options: "Reason" -> None

### SourceVaultCompareServiceVersions[serviceId, v1, v2] → Association
二つの service version snapshot の主要 ref 差分を返す。

## LLM ポリシー / 課金制御 変数

### $SourceVaultOwnerIPs
型: List, 初期値: {"127.0.0.1", "::1", "localhost"}
オーナー PC の IP リスト。proxy が付与する実 TCP peer IP と照合する (X-Forwarded-For は詐称可能なため不使用)。`SourceVaultRegisterOwnerIP` で追加する。

### $SourceVaultBillingAllowed
型: Boolean, 初期値: False
課金 API (Anthropic Messages API) の利用可否。True にすると非オーナーからも課金 API が呼ばれる。`SourceVaultSetBillingAllowed` で設定する。

### $SourceVaultWebBilledModel
型: String, 初期値: "claude-sonnet-4-6"
課金 API 使用時の既定モデル ID。

### $SourceVaultWebLLMBase
型: String, 初期値: "http://localhost:1234"
LM Studio (OpenAI 互換) のベース URL。

### $SourceVaultWebChatModel
型: String | Symbol, 初期値: Automatic
/pdfask 等で使う LLM モデル指定。Automatic で LM Studio `/api/v0/models` から loaded・非 thinking モデルを自動選択。`"cloud"` / `"cloud:<model>"` でサブスク CLI (オーナーのみ)、`"api"` / `"api:<model>"` で課金 API、それ以外はローカルモデル名として解釈する。

### SourceVaultRegisterOwnerIP[ip] → List
$SourceVaultOwnerIPs に ip を追加し、更新後のリストを返す。

### SourceVaultSetBillingAllowed[b] → True | False
$SourceVaultBillingAllowed を設定する。b は True または False。

## 注意事項

load order 違反 (SourceVault_core / SourceVault_searchindex より先にロード) はシンボル未解決で Failure になる。private helper は `SourceVault`ServiceManagerPrivate`` 文脈に置かれており、直接呼び出しは非推奨。全登録関数 (Register*) は private local init (`SourceVaultLoadLocalInit` が読み込む wl ファイル) から呼ぶのが標準パターン。credential / 実パス / IP は registry の spec に含めてはならず、symbolic ref のみを登録する。