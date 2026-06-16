# SourceVault_servicemanager API リファレンス

パッケージ文脈: `SourceVault``
依存: [SourceVault_core](https://github.com/transreal/SourceVault_core), [SourceVault_searchindex](https://github.com/transreal/SourceVault_searchindex)
ロード順: SourceVault.wl → SourceVault_core.wl → SourceVault_searchindex.wl → SourceVault_servicemanager.wl
UTF-8 エンコード。`Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_servicemanager.wl"]]` でロードする。

## ローカル設定 / init

### SourceVaultLocalConfigRoot[] → String | Failure
PrivateVault 下の `config/local` ディレクトリパスを返す。PrivateVault root 未解決なら `Failure["PrivateVaultUnresolved", ...]`。

### SourceVaultLoadLocalInit[opts]
`<PrivateVault>/config/local/SourceVaultLocalInit.wl` を読み込む。ファイルが存在しなければ fail-closed せず `"NotFound"` を返す (推測 fallback なし)。
→ `<|"Status"->{"Loaded"|"NotFound"|"LoadError"}, "Path"->...|>`
Options: "Path" -> Automatic (Automatic で LocalConfigRoot を使う。明示パスで override 可)

### SourceVaultLocalConfigStatus[] → Association
local init の有無・登録済み SearchProfile・ServiceProfile の summary を返す。キー: `"Status"`, `"LocalConfigRoot"`, `"LocalInitPath"`, `"LocalInitExists"`, `"SearchProfiles"`, `"ServiceProfiles"`。

### SourceVaultLocalConfigDoctor[opts] → Association
必須 registry (ReleaseContext / SearchBackend / WebServiceEndpoint) の登録有無を点検し、不足を報告する。
→ `<|"Status"->{"OK"|"Incomplete"}, "Missing"->{...}, "ReleaseContexts"->{...}, "SearchBackends"->{...}, "WebServiceEndpoints"->{...}|>`

## サービス / エンドポイント / チャネル レジストリ

内部状態 `$smRegistries` に Association として保持する。有効な kind: `"WebServiceEndpoint"`, `"ChannelEndpoint"`, `"VoiceBackend"`, `"VRSNSAdapter"`, `"CapabilityProfile"`, `"LLMBackend"`, `"CaptureSource"`, `"OutputAdapter"`。

### SourceVaultRegisterWebServiceEndpoint[name, spec] → Association | Failure
WebService endpoint を登録する。spec 必須フィールド: `"BindAddress"`, `"Port"`。不足なら `Failure["InvalidSpec", ...]`。
→ `<|"Status"->"OK", "Kind"->"WebServiceEndpoint", "Name"->name|>`

### SourceVaultResolveWebServiceEndpoint[name] → Association | Failure
WebService endpoint spec を解決する。未登録なら `Failure["UnregisteredProfile", ...]` (fail-closed)。

### SourceVaultRegisterChannelEndpoint[name, spec] → Association
mail / Discord 等のチャネル endpoint を登録する。spec は自由形式 Association。

### SourceVaultRegisterVoiceBackend[name, spec] → Association
STT / TTS / realtime voice backend を登録する。

### SourceVaultRegisterVRSNSAdapter[name, spec] → Association
VRSNS adapter を登録する。

### SourceVaultRegisterCapabilityProfile[name, spec] → Association
avatar / world capability profile を登録する。

### SourceVaultRegisterLLMBackend[name, spec] → Association
headless LLM backend を登録する。既定は API 直叩き / trusted local server。CLI は HeadlessSafe test 合格時のみ許可する。

### SourceVaultRegisterCaptureSource[name, spec] → Association
audio / camera / screen capture source を登録する。DeviceRef / WindowRef は symbolic ref とし、実デバイス名は private local init で解決する。

### SourceVaultRegisterOutputAdapter[name, spec] → Association
Discord 等の output adapter を登録する。

### SourceVaultResolveServiceProfile[kind, name] → Association | Failure
ServiceManager registry の profile を解決する。未登録なら `Failure["UnregisteredProfile", ...]` (fail-closed)。
kind は上記 8 種のいずれか。

### SourceVaultListServiceProfiles[] → Association
全 kind の登録済み名前リストを `<|kind -> {name, ...}, ...|>` 形式で返す。

### SourceVaultListServiceProfiles[kind] → List
指定 kind の登録済み名前リストを返す。

### SourceVaultClearServiceRegistry[] → Association
ServiceManager registry を全消去する (テスト / 再 init 用)。→ `<|"Status"->"OK"|>`

## PDFGroupSearchProfile レジストリ

PDF グループの検索 service 設定を一つの data object に束ねる。profile 差し替えで別 PDF グループの app を立ち上げられる。QueryScopeResolver / EvidencePolicy / AnswerPolicy 等を inline field として持つ (MVP)。

### SourceVaultCreatePDFGroupSearchProfile[groupAlias, spec, opts] → Association
PDF グループ検索 profile を登録する。spec に `"GroupAlias"` が自動付与される。
→ `<|"Status"->"OK", "Kind"->"PDFGroupSearchProfile", "Name"->groupAlias|>`

### SourceVaultResolvePDFGroupSearchProfile[groupAlias, opts] → Association | Failure
PDF グループ検索 profile を解決する。未登録なら `Failure["UnregisteredProfile", ...]` (fail-closed)。

### SourceVaultListPDFGroupSearchProfiles[opts] → List
登録済み PDF グループ検索 profile の alias リストを返す。

### SourceVaultClonePDFGroupSearchProfile[srcAlias, newAlias, overrides, opts] → Association
既存 profile を複製し `overrides` で差分指定して新 profile として登録する。overrides 省略時は `<||>`。
例: `SourceVaultClonePDFGroupSearchProfile["r6", "r7", <|"Years"->{2025}|>]`

## パーソナル config ドクター

### SourceVaultNoPersonalConfigDoctor[filesOrDirs, opts]
repository / 配布対象ファイルに個人情報・環境依存値が混入していないか検査する。
検出対象: IPv4 literal (octet 値検証), localhost:port, Windows / macOS ユーザパス, credential らしき token (sk-... / Bearer ... / api_key=... 等), 実メールアドレス。先頭付近に `doctor:private-design-doc` マーカーがあるファイルは検査対象外。
→ `<|"Status"->{"OK"|"FindingsFound"}, "Findings"->{<|"File", "Line", "Kind", "Match"|>, ...}, "FilesScanned"->n, "Skipped"->{...}, "FindingCount"->n|>`
Options: "MailAllowlist" -> {} (許可するメールアドレスリスト), "Extensions" -> Automatic (既定: `{".wl",".wls",".m",".md",".json",".toml",".yaml",".yml"}`), "Mask" -> True (マッチ文字列を先頭2字+`***`に置換)
例: `SourceVaultNoPersonalConfigDoctor[{"src", "config"}, "MailAllowlist"->{"admin@example.com"}, "Mask"->False]`

## デタッチドサービス ライフサイクル (Phase 2)

### SourceVaultStartService[serviceId, opts]
detached WolframScript service を起動する。メイン Mathematica カーネルを終了しても service process は heartbeat を更新し続ける。
→ `<|"Status"->..., "ServiceId"->..., "PID"->..., "RuntimeDir"->...|>`
Options: "Kind" -> "heartbeat", "HeartbeatIntervalSeconds" -> 1, "PackageRoot" -> Automatic

### SourceVaultStopService[serviceId, opts] → Association
Stop command を queue に入れ、必要なら pid 検証後に kill する。

### SourceVaultRestartService[serviceId, opts] → Association
stop してから同 profile で start する。

### SourceVaultServiceStatus[serviceId] → Association
pid.json / status.json / heartbeat.json から状態 association を返す。

### SourceVaultServiceHealth[serviceId] → String
heartbeat の鮮度から `"OK"` / `"Degraded"` / `"Failing"` を返す。

### SourceVaultServicePing[serviceId, opts] → Association
Ping command を送り、command queue 経由で Pong を待つ。

### SourceVaultListServices[] → List
runtime/services 配下の全 service とその状態を返す。

### SourceVaultServiceLogs[serviceId, opts] → List
service.log.jsonl の event リストを返す。
Options: "Limit" -> Infinity

### SourceVaultTailServiceLog[serviceId, n:20] → List
service.log.jsonl の末尾 n 件を返す。

### SourceVaultSendServiceCommand[serviceId, command] → Association
command (Association, `"Command"` key 必須) を queue に書く。
→ `<|"Status"->..., "CommandId"->...|>`

### SourceVaultServiceCommandResult[serviceId, commandId] → Association | "Pending"
処理済み command の結果を返す。未処理なら `"Pending"`。

### SourceVaultRecoverServices[opts] → Association
status が Running だが pid が死んでいる孤児 service を Crashed に更新する。
Options: "Kill" -> True (pid 同一性確認後に kill する)

### SourceVaultServiceDoctor[serviceId] → Association
runtime dir / pid / heartbeat / status の整合を点検する。

### SourceVaultServiceMain[kind, serviceId, opts]
detached service process 側の runner entrypoint。生成された run.wls から呼ばれる。pid / status / heartbeat を書き、command queue を処理し、Stop で終了する。メインカーネルから直接呼ばない (StartService 経由)。

### SourceVaultServiceRuntimeDir[serviceId] → String | Failure
service の runtime directory パスを返す。

## Python HTTP リバースプロキシ

### $SourceVaultPython
型: String | Automatic, 初期値: Automatic
python 実行ファイルの override。Automatic で PATH 上の python3 / python を解決する。

### SourceVaultPublishProxyCodeSnapshot[opts] → Association
組込みの proxy Python ソースを immutable snapshot (SourceVaultProxyCode) として vault に保存する。alias `"sv-http-proxy"`。
→ `<|"Status"->..., "Ref"->..., "Digest"->..., "CodeSHA256"->...|>`

### SourceVaultMaterializeProxyCode[targetDir, opts] → Association
proxy code を `targetDir/proxy.py` へ出力し SHA256 を検証する。不一致なら fail-closed。
Options: "CodeRef" -> Automatic (snapshot ref | Automatic で組込みソースを使う)

### SourceVaultStartHTTPProxy[serviceId, opts]
serviceId の WL service を front する Python HTTP proxy を detached 起動する。proxy.py を vault data から materialize + digest 検証し、stdlib のみで `/sv/health`, `/sv/search`, `/sv/admin/status` を提供する。gate は WL service 側。proxy は status / heartbeat の直読みと command queue 中継のみで raw vault を公開しない。
→ `<|"Status"->..., ...|>`
Options: "Port" -> (必須、または "EndpointProfile" を指定), "EndpointProfile" -> Automatic, "RoutePrefix" -> "/sv", "ReleaseContext" -> None, "PDFIndexProfile" -> None, "Bind" -> "127.0.0.1", "CodeRef" -> Automatic

### SourceVaultStopHTTPProxy[serviceId] → Association
Python proxy を停止し scheduled task を削除する。

### SourceVaultHTTPProxyStatus[serviceId] → Association
proxy の pid / 生存状態 / port を返す。

### SourceVaultProxyRuntimeDir[serviceId] → String
proxy の runtime directory パスを返す。

## チャネルパイプライン / メール / Discord / OutputGate

### SourceVaultMakeQuestionEnvelope[channel, inputText, opts] → Association
統一入力 QuestionEnvelope を作る。channel: `"Web"` | `"Mail"` | `"Discord"` | `"Voice"` | `"VRSNS"`。
Options: "ReleaseContext" -> (必須), "Audience" -> Automatic, "LatencyProfile" -> Automatic, "AllowedIndexes" -> {}, "PDFIndexProfile" -> Automatic, "Requester" -> None

### SourceVaultAnswerChannelQuery[envelope, opts] → Association
envelope を検索 → evidence draft 化する。gate 済み SourceVaultSearch を使う。Mail は NeedsHumanReview (draft のみ)、Discord は低リスクのみ Answered。LLM は呼ばない (evidence ベース)。
→ `<|"Decision"->..., "AnswerDraft"->..., "Evidence"->..., "Citations"->..., ...|>`

### SourceVaultMakeMailReplyDraft[envelope, opts] → Association
メール返信 draft を作る。自動送信は一切しない。

### SourceVaultEvaluateOutputGate[draft, outputAdapter, opts] → Association
出力可否を判定する。adapter の PrivacyMax / ReleaseContextRequired / AllowedEventKinds / RequireApproval / raw media を判定基準とする。
→ `<|"Decision"->{"Permit"|"NeedsApproval"|"Deny"|"RedactRequired"}, ...|>`

### SourceVaultDispatchOutput[draft, outputAdapter, opts] → Association
OutputGate を通してから出力する。mail は送信せず draft を返す。Discord は gate が Permit かつ opts `"Approved"->True` かつ `"ReallySend"->True` の時のみ webhook 送信する。既定は送信せず Prepared / NeedsApproval を返す (fail-safe)。

## ActionDraft / ActionGate (VRSNS アクション安全制御)

### SourceVaultMakeActionDraft[kind, payload, opts] → Association
ActionDraft を作る。kind: `"Speak"` | `"Gesture"` | `"Expression"` | `"Move"` | `"ShowPanel"` | `"CallTool"`。
Options: "CapabilityProfile" -> None, "Audience" -> Automatic, "ReleaseContext" -> None, "Target" -> None, "EvidenceRefs" -> {}

### SourceVaultEvaluateActionGate[actionDraft, opts] → Association
capability profile に基づき action 可否を判定する。world 変更 (Move / CallTool) は AllowWorldControl が無ければ Deny。
→ `<|"Decision"->{"Permit"|"RequiresApproval"|"Deny"}, ...|>`

### SourceVaultListCaptureSources[] → List
登録済み capture source の名前リストを返す。

### SourceVaultTestCaptureSource[name] → Association
capture source profile の解決可否を fail-closed で点検する (実 capture はしない)。

## マルチモーダル ingest / ライブセッション (Phase 7b)

### SourceVaultIngestCapturedMedia[sessionId, kind, data, opts] → Association
capture 由来データを vault に取り込む。data が ByteArray なら content-addressed blob に commit (PersistRaw->True 時)、String なら Text として記録する。MultimodalEvent を append する。実 ffmpeg / ASR driver はこの関数を呼ぶ (device 非依存の取込点)。
Options: "PersistRaw" -> True, "SourceRef" -> None, "Tags" -> {}, "State" -> Automatic, "PrivacyLevel" -> Automatic

### SourceVaultUpdateLiveSummary[sessionId, summary] → Association
live summary pointer を更新し SystemSummary event を残す。

### SourceVaultGetLiveSummary[sessionId] → String | Missing
現在の live summary を返す。

### SourceVaultGetLiveEvents[sessionId, opts] → List
session の MultimodalEvent リストを返す。

### SourceVaultGetLiveTranscript[sessionId] → String
session の ASR transcript を連結して返す。

### SourceVaultAskLiveSession[sessionId, question, opts] → Association
UserQuestion を記録し command を enqueue する。メインカーネルは LLM を直接呼ばず service 側が処理する。

### SourceVaultRegisterMultimodalWorkflow[name, spec] → Association
multimodal workflow (PresentationListenerCompat 等) を登録する。

### SourceVaultListMultimodalWorkflows[] → List
登録済み multimodal workflow の名前リストを返す。

### SourceVaultSchedulePostprocess[sessionId, spec] → Association
後処理 (ASRImprove / Summary / PurposeIndexBuild 等) を予約 event として記録する。

## ServiceVersionSnapshot / バージョン切替 (Phase 4)

### SourceVaultCreateServiceVersionSnapshot[serviceId, spec] → Association
ServiceVersionSnapshot を immutable 保存する。spec は WorkflowSnapshotRef / CorpusSnapshotRef / IndexSnapshotRefs / ReleaseContextRef 等を持つ。credential / 実 path / IP を含めてはならない (profile ref のみ)。

### SourceVaultListServiceVersions[serviceId] → List
作成済み service version の `<|"Version"->..., "Ref"->..., "CreatedAtUTC"->...|>` リストを返す。

### SourceVaultServiceVersionInfo[serviceId, version] → Association
指定 version の snapshot を返す。version 省略で現在 active version の情報を返す。

### SourceVaultActivateServiceVersion[serviceId, versionOrRef, opts] → Association
active service version を切り替える。digest 検証 + IndexSnapshotRefs の解決可能性を確認し、fail-closed。active pointer を pointer event で更新する。

### SourceVaultActiveServiceVersion[serviceId] → String | Missing
現在 active な service version ref を返す (pointer replay)。

### SourceVaultRollbackServiceVersion[serviceId, opts] → Association
一つ前の active version へ戻し rollback log を残す。
Options: "Reason" -> ""

### SourceVaultCompareServiceVersions[serviceId, v1, v2] → Association
二つの service version snapshot の主要 ref 差分を返す。

## Web UI / LLM バックエンド変数

### $SourceVaultWebLLMBase
型: String, 初期値: `"http://localhost:1234"`
LM Studio (OpenAI 互換) のベース URL。ValueQ で未設定時のみ初期化する。

### $SourceVaultWebChatModel
型: String | Automatic, 初期値: Automatic
LM Studio で使うモデル ID。Automatic で `/api/v0/models` から loaded + non-thinking モデルを自動選択する。

### $SourceVaultOwnerIPs
型: List, 初期値: `{"127.0.0.1", "::1", "localhost"}`
オーナー PC の IP リスト。このリストに含まれる IP からのリクエストのみサブスクリプション LLM (ClaudeCode 等) の使用を許可する。proxy 経由でない直接呼び出し (IP 不明) はオーナー扱いとする。

### $SourceVaultBillingAllowed
型: True | False, 初期値: False
課金 API (Anthropic Messages API 等) の使用許可フラグ。False の非オーナーリクエストは LM Studio にフォールバックする。

### $SourceVaultWebBilledModel
型: String, 初期値: `"claude-sonnet-4-6"`
課金 API 使用時の既定モデル ID。

### SourceVaultRegisterOwnerIP[ip] → List
ip を `$SourceVaultOwnerIPs` に追加し現在のリストを返す。重複は追加しない。

### SourceVaultSetBillingAllowed[b] → True | False
`$SourceVaultBillingAllowed` を設定する。b は `True` | `False`。

## 補足 curated 知識

### SourceVaultRegisterCuratedKnowledge[id, spec] → Association
人手レビュー済みの clean text を curated knowledge として登録し、`<CoreRoot>/curated/curated_knowledge.wl` に永続化する。既存エントリを読んでから追加するため別カーネルの登録を上書き喪失しない。
spec フィールド: `"Text"` (必須), `"Years" -> {}`, `"Unit" -> All`, `"QuestionClasses" -> All`, `"ReleaseContexts" -> {}`, `"ReviewState" -> "HumanReviewed"`, `"AllowedUse" -> "EvidenceOnly"`, `"SourceRefs" -> {}`。
→ `<|"Status"->"OK", "Id"->id, "Persisted"->{True|False}|>`

### SourceVaultListCuratedKnowledge[opts] → List
登録済み curated knowledge を `Normal[$svCuratedKnowledge]` した rule リストで返す。

### SourceVaultDraftCuratedTranscription[query, opts]
OCR で構造が崩れた表チャンクを LLM で clean に転記し、人手レビュー前提のドラフト curated 項目を返す。自動登録しない (ReviewState=NeedsHumanReview)。人手確認後に `SourceVaultRegisterCuratedKnowledge` で登録する。
→ Association | `Failure["NoSourceChunks", ...]`
Options: "Collection" -> "default", "ChunkIds" -> Automatic (Automatic でクエリ検索して自動取得), "Limit" -> 4, "ChatModel" -> "cloud", "Years" -> {}, "Unit" -> All, "ReleaseContexts" -> {}