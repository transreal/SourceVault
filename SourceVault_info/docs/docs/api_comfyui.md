# SourceVault_comfyui API リファレンス

## 概要
`SourceVault_comfyui.wl` は ComfyUI (ローカル画像/動画生成サーバー) への薄い HTTP クライアント兼 workflow registry 兼非ブロックジョブ adapter。Eagle adapter に準拠した UTF-8 byte 安全 HTTP helper を持ち、接続診断・低レベル HTTP API・workflow 登録/検証/rendering・非ブロックジョブ投入・生成物の SourceVault artifact deposit までを提供する。

ロード順: `SourceVault.wl -> SourceVault_core.wl ... -> SourceVault_comfyui.wl`。UTF-8 で `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_comfyui.wl"]]` としてロードする。全公開シンボルは context `SourceVault\`` に属する。

## 設計上の不変条件
- 公開関数は `$Failed` を返さず必ず Association を返し、必ず `"Status"` キーを持つ。`"Status"` は主に `"OK"`/`"Offline"`/`"Error"`/`"Registered"`/`"Submitted"`/`"Queued"`/`"Timeout"` 等。
- 生成バイナリの正本は `SourceVaultMCPDeposit` の immutable snapshot (`sv://artifact/...`)。`PrivateVault/comfyui` は registry / job 状態 / log の置き場であり正本ストアではない。生成バイナリや private provenance を `$packageDirectory` 配下に置かない。
- HTTP 層は `$SourceVaultComfyUIHTTPHook` で差し替え可能 (テスト時 mock、本番 URLRead)。
- workflow template は code ではなく data として保存する: `PrivateVault/comfyui/workflows/<name>/{workflow-api.json, meta.json}`。
- status reader 状態機械 (Running/Completed/Failed/Lost) は純関数として分離。transient HTTP 失敗は terminal failure にせず Poll 側が Running 扱いにする。
- workflow hash は recursive key sort による canonical JSON の SHA256 (`"sha256:..."`) で決定論化。

## workflow 形式
- API format: 各値が `"class_type"` を持つ Association (トップに `nodes`/`links` キーを持たない)。`/prompt` に投入できる唯一の形式。ComfyUI frontend の File → Export (API) で得られる。
- browser format: `nodes`/`links` を持つ frontend 通常保存形式。server の userdata に保存されるのは通常こちら。`SourceVaultComfyUIConvertWorkflow` で API format へ best-effort 変換する。

## 設定変数

### $SourceVaultComfyUIBaseURL
型: String, 初期値: `"http://127.0.0.1:8188"`
ComfyUI server のベース URL。

### $SourceVaultComfyUIHTTPTimeout
型: Integer(秒), 初期値: 30
`/queue` `/history` `/view` など単一 HTTP 呼び出しの短い timeout。job 全体 timeout とは別。

### $SourceVaultComfyUIJobTimeout
型: Integer(秒), 初期値: 600
ComfyUI job 全体の timeout。External executor jobSpec の Timeout に渡す値。

### $SourceVaultComfyUIStoreRoot
型: String, 初期値: 未設定 (未初期化なら `PrivateVault/comfyui`、無ければ `$TemporaryDirectory/sourcevault-comfyui`)
workflow registry / job cache / log の保存先。生成バイナリの正本ストアではない。

### $SourceVaultComfyUIDefaultWorkflow
型: String|None, 初期値: None
workflow 未指定時に使う登録済み workflow 名。

### $SourceVaultComfyUIDefaultProviderName
型: String, 初期値: `"comfyui"`
provider 識別名。

### $SourceVaultComfyUIOfflineRecheckSeconds
型: Integer(秒), 初期値: 30
online/offline 判定の TTL cache 秒。到達不能 server への繰り返し接続待ちを避ける。

### $SourceVaultComfyUIHTTPHook
型: Function|None, 初期値: None
HTTP 層の差し替えフック。`Function[<|"Method","Endpoint","Query","Body"|>] -> <|"StatusCode", "Body"(string|ByteArray)|>`。テスト時に mock を注入する。

### $SourceVaultComfyUIDepositMode
型: String, 初期値: `"commit"`
生成物を `SourceVaultMCPDeposit` へ渡す mode。`"commit"` は vault へ書き DepositArtifact 権限 (grant / AccessProfile) を要する。`"plan"` は vault へ書かず予定 policy のみ算定 (生成物はローカル参照に留まる)。

### $SourceVaultComfyUIDepositGrant
型: AccessGrant|None, 初期値: None
commit deposit に使う AccessGrant。`SourceVaultMCPMintAccessGrant` / `sourcevault_request_access` (action=DepositArtifact) で得た grant を設定すると completion hook の deposit がそれで commit する。`SourceVaultComfyUIActivate` が自動発行して設定する。

## 接続・診断

### SourceVaultComfyUIStatus[opts] → Association
ComfyUI server の状態を返す。到達不能なら message を出さず `<|"Status"->"Offline", "Provider", "BaseURL", "Reason"|>`。到達可なら `<|"Status"->"OK","Provider","BaseURL","Version","Capabilities"->{"Image","Video"},"Stats"|>`。結果は TTL cache される。
Options: "Refresh" -> False (True で cache を無効化して再取得)

### SourceVaultComfyUIAPIAvailable[opts] → True|False
ComfyUI server へ到達可能かを返す (TTL cache)。
Options: "Refresh" -> False

### SourceVaultComfyUISystemStats[opts] → Association
`/system_stats` を返す (`<|"Status"->"OK","Data"->...|>`)。

### SourceVaultComfyUIObjectInfo[opts] → Association
`/object_info` (利用可能 node 定義) を返す。

### SourceVaultComfyUIModels[folder:All, opts] → Association
`/models` (folder が All/Automatic) または `/models/{folder}` を返す。

### SourceVaultComfyUIQueue[opts] → Association
`/queue` (running / pending) を返す。

### SourceVaultComfyUIInterrupt[opts] → Association
`/interrupt` を呼ぶ低レベル debug primitive。`/interrupt` は実行中ジョブを止める global 操作で prompt スコープではない。複数ジョブ運用では prompt スコープの killer 経路を使うこと。成功時 `<|"Status"->"OK","Note"->"global interrupt (not prompt-scoped)"|>`。

## 低レベル HTTP API

### SourceVaultComfyUIAPICall[endpoint, params:None, opts] → Association
JSON GET/POST を扱う。params があれば POST(JSON)、無ければ (None または `<||>`) GET。返り `<|"Status","Data"|>`。binary download は `SourceVaultComfyUIView` を使う。

### SourceVaultComfyUIView[file_Association, opts]
`/view` で出力ファイル bytes を取得する。file は `<|"filename","subfolder","type"|>` (大文字始まりのキーも許容、type 既定 `"output"`)。
→ `<|"Status","Bytes"->ByteArray,"ContentType","File"->(保存パス|Missing)|>`
Options: "Save" -> True (True なら `StoreRoot/cache` にローカル materialize しパスを "File" で返す)

### SourceVaultComfyUIUploadImage[path_String, opts]
`/upload/image` に multipart/form-data でアップロードする。元ファイル名や source path は出さず random 名を使う。
→ `<|"Status","Name","Subfolder","Type"|>`
Options: "Overwrite" -> True, "Type" -> "input", "Subfolder" -> ""

## Workflow registry (template = data)

### SourceVaultComfyUIRegisterWorkflow[name_String, workflow, opts]
API format workflow JSON を名前付きで登録する (`PrivateVault/comfyui/workflows/<name>` に `workflow-api.json` と `meta.json`)。workflow に `"Workflow"` キーがあればその値を採る。通常保存形式 (browser format) は `"Reason"->"NotAPIFormat"` で拒否。
→ `<|"Status"->"Registered","Name","WorkflowHash"|>` / エラー時 `<|"Status"->"Error","Reason"|>`
Options: "Kind" -> "Image", "Variables" -> <||> (変数名→注入先 node/input マッピング), "Outputs" -> <||>, "RequiredModels" -> {}, "Tags" -> {}, "TrustedForPrivateInput" -> False, "AllowedNodeTypes" -> Automatic

### SourceVaultComfyUIWorkflows[opts] → Association
登録済み workflow 名と meta の一覧を返す。`<|"Status"->"OK","Workflows"->{<|"Name",...|>..}|>`。

### SourceVaultComfyUIWorkflow[name_String, opts] → Association
登録済み workflow record (Workflow JSON + meta) を返す。`<|"Status"->"OK",...|>` / 未登録時 Error。

### SourceVaultComfyUIValidateWorkflow[workflowOrRecord, opts] → Association
API format 整形式・Variables/Outputs の node 実在を検査する。
Options: "Variables" -> <||>, "Outputs" -> <||>, "ObjectInfo" -> ... (RequiredModels 確認用)

### SourceVaultComfyUIRenderWorkflow[workflowOrName, vars_Association, opts]
Variables マッピングに従って vars を API JSON の node/input に inject した workflow を返す。
→ `<|"Status"->"OK","Workflow"->apiJson,"WorkflowHash"|>`

## Server workflow (userdata) 取り込み
ComfyUI frontend の「ワークフロー」ブラウズ = server の userdata API。server 保存は通常 browser 形式で、API format への変換は `/object_info` の入力スキーマに基づく best-effort (警告付き)。userdata API は ComfyUI バージョン依存のため実機確認を要する。

### SourceVaultComfyUIServerWorkflows[opts] → Association
server 側に保存されたユーザー定義 workflow を一覧する (`GET /userdata?dir=workflows&recurse=true&split=false&full_info=true`)。
→ `<|"Status","Workflows"->{<|"Name","Path","Size","Modified","Registered"|>..}|>`。Registered は同名が SourceVault registry に取り込み済みか。
Options: "Directory" -> "workflows"

### SourceVaultComfyUIServerWorkflowsView[opts] → Dataset
`SourceVaultComfyUIServerWorkflows` の Dataset 表示版。
Options: "Limit" -> 50

### SourceVaultComfyUIFetchServerWorkflow[name] → Association
server 保存 workflow の JSON を取得し形式を判定する。
→ `<|"Status","Name","Format"->"API"|"Browser","Workflow"|>`

### SourceVaultComfyUIConvertWorkflow[browserWF, opts] → Association
frontend 通常保存形式 (nodes/links) を API format へ best-effort 変換する。`/object_info` の入力スキーマで widgets_values を input 名へ対応付け、link 解決 (Reroute 追跡・PrimitiveNode 値化・control_after_generate スキップ) を行う。muted/bypassed node や group node は警告。
→ `<|"Status","Workflow","Warnings"|>`
変換後は `SourceVaultComfyUIValidateWorkflow` と実機テスト実行での確認を推奨。

### SourceVaultComfyUIImportServerWorkflow[name, opts] → Association
server 保存 workflow を取得し (browser 形式なら API へ変換)、Variables/Outputs を自動検出して SourceVault registry へ登録する。
→ `<|"Status","Name","Format","Warnings","Variables","Outputs","Registration"|>`
Options: "Name" -> Automatic (拡張子抜きファイル名), "Variables" -> Automatic (Seed/Prompt/NegativePrompt/Width/Height を sampler 近傍から自動検出), "Outputs" -> Automatic (output node 自動検出), "Kind" -> Automatic, "Register" -> True (False で登録せず変換結果のみ返す)

## Job 実行

### SourceVaultComfyUIQueuePrompt[workflow, opts] → Association
API format workflow を `/prompt` に POST し prompt_id を返す。全 ComfyUI 投入のチョークポイントで `SourceVaultRateLimit["ComfyUISubmit"]` を通す (core 未ロードなら fail-open)。workflow に `"Workflow"` キーがあればその値を採る。
→ `<|"Status"->"OK","PromptId","ClientId","NodeErrors"|>` / Error 時 `"Reason"` (`"RateLimitExceeded"`/`"NotAPIFormat"`/`"NoPromptId"`/`"QueueFailed"` 等)
Options: "ClientId" -> Automatic (未指定なら `sv-comfy-<rand>` を生成)

### SourceVaultComfyUIPoll[promptId, opts] → Association
`/queue` と `/history` を確認して job 状態を返す。state は `"Running"`/`"Completed"`/`"Failed"`/`"Lost"`。transient HTTP 失敗は Running 扱い (`"Transient"->True`)。
→ `<|"Status","State","Transient",...|>`
Options: "Seen" -> (観測済みフラグ), "Queue" -> (注入用 queue snapshot), "History" -> (注入用 history snapshot)

### SourceVaultComfyUIJobStatus[promptId, opts] → Association
`SourceVaultComfyUIPoll` の薄いラッパ。

### SourceVaultComfyUIFetchOutputs[promptIdOrHistory, opts] → Association
history から出力ファイル一覧を取り出す。
→ `<|"Status","Outputs"->{<|"filename","subfolder","type","kind"|>..}|>`

### SourceVaultComfyUIBuildJobSpec[spec_Association, opts] → Association
純関数 helper。workflow 選択・変数解決・seed 確定・privacy 計算・API workflow rendering・External executor jobSpec 構築までを行い HTTP は叩かない。spec の `"ProviderOptions"` 内 `"Workflow"` (無ければ `$SourceVaultComfyUIDefaultWorkflow`) で workflow を選ぶ。spec は `"Prompt"`/`"NegativePrompt"`/`"Seed"`(既定 Automatic=random)/`"Width"`/`"Height"`/`"Inputs"`/`"PrivacyLevel"` 等を持ちうる。生成物 PrivacyLevel = Max[入力群 PL, prompt provenance PL, 既定] (欠落は fail-closed=既定)。
→ `<|"Status"->"OK",...|>` / `"NoWorkflowForSpec"` 等

## 非ブロックジョブ (External executor)
ClaudeOrchestrator External executor backend として ComfyUI job を非ブロック投入する。launcher は子プロセスを起動せず `/prompt` POST して prompt_id を JobID にする。status reader は `/queue`+`/history` で判定し Completed 時に `/view`+deposit。killer は prompt スコープ (pending なら queue delete、running なら `/interrupt`)。

### SourceVaultComfyUIRegisterBackend[] → Association
ComfyUI 用の launcher/status reader/killer を `ClaudeOrchestrator\`Workflow\`ClaudeRegisterExternalBackend` へ登録する (冪等)。orchestrator backend dispatch が未整備なら `"ExternalBackendDispatchUnavailable"`。

### SourceVaultComfyUIActivate[opts] → Association
ComfyUI を非ブロック生成 provider として live 稼働させる (冪等): (1) backend 登録、(2) auto-commit 用 DepositArtifact grant を発行し `$SourceVaultComfyUIDepositGrant` に設定、(3) `ClaudeRuntime\`ClaudeActivateExternalExecutor` で poll tick を共有タスクへ登録。1 カーネルセッションに 1 回呼ぶ。
Options: "RenewGrant" -> False (True で grant 再発行), "GrantTTLSeconds" -> 86400, "GrantMaxAccessLevel" -> 0.49 (この値以上の effPL deposit は approval gate で保護=auto-commit しない)

### SourceVaultComfyUISubmitExternal[workflowOrName, vars:<||>, opts] → Association
ComfyUI job を External executor backend (Backend->"ComfyUI") として 1 遷移 WorkflowNet で非ブロック投入する。内部で `SourceVaultComfyUIActivate` を冪等に呼ぶため単独でも背景で完了まで進む。
→ `<|"Status"->"Queued"|"Submitted","WorkflowId","PromptId"|>`。engine 未ロード/未 activate なら `"ExternalExecutorInactive"`、backend dispatch 未整備なら `"ExternalBackendDispatchUnavailable"`。
Options: "PrivacyLevel" -> Automatic (欠落は既定 privacy), "NotifyNotebook" -> None

## Deposit

### SourceVaultComfyUIDepositOutputs[promptIdOrHistory, opts] → Association
出力ファイルを `/view` で取得し `SourceVaultMCPDeposit` へ渡して artifact URI を返す。deposit backend 不在なら `"LocalCacheOnly"` に落ちる。deposit gate/quota 失敗時は job を成功扱いにしつつ `"DepositDenied"`/`"DepositQuotaExceeded"` を残す。
→ `<|"Status","Artifacts"->{..},"DepositBackend"|>`
Options: "PrivacyLevel" -> Automatic, "Provenance" -> <||>

## 同期・高水準経路

### SourceVaultComfyUIRunWorkflow[workflowOrName, vars:<||>, opts] → Association
同期 debug 経路 (submit → poll loop → fetch → deposit)。FrontEnd を持たない wolframscript / subkernel 用であり、main kernel / notebook 既定にしてはならない。
→ `<|"Status"->"OK","Provider","PromptId","Artifacts","Outputs","WorkflowHash"|>` / 未完了時 `"Timeout"`/`"Error"`
Options: "PollInterval" -> 1.5, "Deposit" -> Automatic (False で materialize/deposit を完全 skip), "PrivacyLevel" -> Automatic

### SourceVaultComfyUIGenerate[spec_Association, opts] → Association
provider 専用 entry point。spec の `"ProviderOptions"["Workflow"]` で workflow を選ぶ。
Options: "Mode" -> "BuildJobSpec" (既定, in-workflow helper=BuildJobSpec) | "DebugSync" (非 FE=RunWorkflow) | "Async" (External 投入=SubmitExternal), "PrivacyLevel" -> Automatic, "NotifyNotebook" -> None
例: `SourceVaultComfyUIGenerate[<|"Prompt"->"a cat","ProviderOptions"-><|"Workflow"->"sdxl"|>|>, "Mode"->"Async"]`

### SourceVaultComfyUIGenerateToNotebook[workflowName, promptOrVars, opts] → Association
ClaudeEval 向け一括関数: (1) Activate(冪等) (2) workflow 未登録なら server 保存分から自動取り込み (3) SubmitExternal で非ブロック投入 (4) 完了まで poll tick を手動駆動して待機 (5) deposit URI を `NBAccess\`NBInsertArtifactCell` でノートブック表示。promptOrVars は英語プロンプト文字列 (自動的に `<|"Prompt"->...|>` へ) または vars Association。Seed 未指定なら自動確定。ClaudeEval 生成コードは Get/Import が ForbiddenHead のため、この 1 呼び出しにまとめる。
→ `<|"Status","URI","Displayed","PromptId","WorkflowId",...|>` / 未完了時 `"Timeout"` (生成は背景で継続しうる)
Options: "PrivacyLevel" -> 0.0, "TimeoutSeconds" -> 600, "PollInterval" -> 3.0, "Notebook" -> Automatic
例: `SourceVaultComfyUIGenerateToNotebook["sdxl", "a photorealistic red apple on a table"]`

## 関連パッケージ
SourceVault_core, SourceVault_mcp (deposit 正本ストア), SourceVault_eagle (HTTP helper パターンの参照元), ClaudeOrchestrator_workflow (External executor engine), ClaudeRuntime_externalrunner (poll tick 共有タスク), NBAccess (artifact cell 表示)。