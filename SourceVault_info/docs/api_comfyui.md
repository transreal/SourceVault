# SourceVault_comfyui API リファレンス

パッケージ: `SourceVault_comfyui` ([GitHub](https://github.com/transreal/SourceVault_comfyui))

## 概要

ComfyUI ローカル画像/動画生成アダプタ。thin HTTP クライアント・workflow レジストリ・非ブロック job 管理・artifact deposit を提供する。

ロード順: `SourceVault.wl` → `SourceVault_core.wl` → `SourceVault_comfyui.wl`。
人間が手でロードする場合は `Block[{$CharacterEncoding="UTF-8"}, Get["SourceVault_comfyui.wl"]]`。
**ClaudeEval 生成コードでは `Get` は ForbiddenHead**なので使わない — `SourceVaultComfyUIEnsureLoaded[]` を呼ぶか、自動ロード対応 entry point（`SourceVaultComfyUIGenerateToNotebook` / `SourceVaultComfyUIServerWorkflowsView` / `SourceVaultComfyUIImportServerWorkflow`）を直接呼べば内部でロードされる。

**設計上の不変条件**
- 公開関数は `$Failed` を返さず常に `Association` を返し、必ず `"Status"` キーを持つ。
- 生成バイナリの正本は `SourceVaultMCPDeposit` / immutable snapshot (`sv://artifact/...`)。`PrivateVault/comfyui` は registry・job 状態・log の置き場であり正本ストアではない。
- HTTP 層は `$SourceVaultComfyUIHTTPHook` で差し替え可能（テスト時 mock）。
- `SourceVaultComfyUISubmitExternal` は ClaudeOrchestrator External executor backend (Phase 0.5) が前提であり、未整備の場合は `"ExternalBackendDispatchUnavailable"` を返す stub になる。

## ★ 対話ノートブックから画像/動画を生成する（ClaudeEval 推奨レシピ）

「ComfyUI の <workflow名> で〜の画像を生成して」という要求には**この 1 呼び出しをそのまま使う**。

```mathematica
(* プロンプトは必ず英語へ翻訳して渡す (SDXL 等 CLIP 系は日本語が効きにくい) *)
SourceVaultComfyUIGenerateToNotebook["sdxl_simple_example2",
  "a boy sprinting at full speed across a grassland"]
```

これ 1 つで「adapter の自動ロード → Activate（grant/poll tick）→ workflow 未登録なら server 保存分から自動取り込み → 非ブロック投入 → 完了待ち → 生成画像を privacy marking 付きセルとしてノートブックへ挿入」まで行う。SDXL で数十秒かかる。返り値は `<|"Status"->"OK","URI"->"sv://artifact/...","Displayed"->True,...|>`。

**重要な制約**:
- **`Get` / `Import` / `Export` は ForbiddenHead**（安全検証で拒否される）。生成コードに書いてはならない。パッケージのロードは上記関数（または `SourceVaultComfyUIEnsureLoaded[]`）が内部で行う。
- 詳細な vars を渡す場合は第 2 引数を Association に:
  `SourceVaultComfyUIGenerateToNotebook["sdxl_simple_example2", <|"Prompt" -> "...", "NegativePrompt" -> "...", "Seed" -> 999, "Width" -> 1024, "Height" -> 1024|>]`
- Options: `"PrivacyLevel" -> 0.0`, `"TimeoutSeconds" -> 600`。

**手動フロー（セルを分けて非ブロックで進めたい場合）**:

```mathematica
(* セル1: 投入 (即 Queued が返り FE は固まらない) *)
res = SourceVaultComfyUISubmitExternal["sdxl_simple_example2",
  <|"Prompt" -> "a boy sprinting across a grassland", "Seed" -> 999|>,
  "PrivacyLevel" -> 0.0]

(* セル2 (数十秒後): Done を確認し Out トークンの URI を表示 *)
ClaudeOrchestrator`Workflow`ClaudeWorkflowState[res["WorkflowId"]]   (* Status -> "Done" *)
NBAccess`NBInsertArtifactCell[EvaluationNotebook[], "sv://artifact/artifact-..."]
```

- 利用可能な workflow 名は `SourceVaultComfyUIServerWorkflowsView[]`（server 保存分）と `SourceVaultComfyUIWorkflows[]`（取り込み済み）で確認する。これらも自動ロード対応。
- `Variables` が自動検出されなかった workflow（prompt/sampler の無い upscale 系等）では vars に `"Prompt"` を渡しても効かない。`SourceVaultComfyUIWorkflow[name]` の `Meta→Variables` で受け付ける変数名を確認する。

**主要な利用パターン**

```mathematica
(* 1. 対話 1 枚生成 (上の推奨レシピ) *)
SourceVaultComfyUIRunWorkflow["myWF", <|"Prompt" -> "a cat"|>]

(* 2. 非ブロック投入 (動画/バッチ。ClaudeOrchestrator engine ロード済み環境) *)
SourceVaultComfyUISubmitExternal["myWF", <|"Prompt" -> "a dog"|>, "PrivacyLevel" -> 0.0]

(* 3. in-workflow jobSpec 構築 (ClaudeOrchestrator 遷移内。HTTP を叩かない) *)
SourceVaultComfyUIGenerate[<|"Prompt"->"a dog","ProviderOptions"-><|"Workflow"->"myWF"|>|>]
```

## 設定変数

### $SourceVaultComfyUIBaseURL
型: String, 初期値: `"http://127.0.0.1:8188"`
ComfyUI サーバのベース URL。末尾スラッシュは自動 trim される。

### $SourceVaultComfyUIHTTPTimeout
型: Number, 初期値: `30`
単一 HTTP 呼び出し（`/queue`・`/history`・`/view` 等）の timeout 秒。job 全体 timeout とは別。

### $SourceVaultComfyUIJobTimeout
型: Number, 初期値: `600`
ComfyUI job 全体の timeout 秒。External executor jobSpec の `Timeout` に渡す値。

### $SourceVaultComfyUIStoreRoot
型: String, 初期値: `PrivateVault/comfyui`（未初期化時は `$TemporaryDirectory/sourcevault-comfyui`）
workflow registry・job cache・log の保存先。生成バイナリの正本ストアではない。

### $SourceVaultComfyUIDefaultWorkflow
型: String | None, 初期値: `None`
workflow 未指定時に使う登録済み workflow 名。

### $SourceVaultComfyUIDefaultProviderName
型: String, 初期値: `"comfyui"`
provider 識別名。生成物 provenance に埋め込まれる。

### $SourceVaultComfyUIOfflineRecheckSeconds
型: Number, 初期値: `30`
online/offline 判定の TTL cache 秒。到達不能サーバへの繰り返し接続待ちを避ける。

### $SourceVaultComfyUIHTTPHook
型: Function | None, 初期値: `None`
HTTP 層の差し替えフック。テスト時に mock を注入する。契約: `Function[<|"Method","Endpoint","Query","Body"|>] -> <|"StatusCode", "Body"(String|ByteArray)|>]`。

### $SourceVaultComfyUIDepositMode
型: String, 初期値: `"commit"`
生成物を `SourceVaultMCPDeposit` へ渡す mode。`"commit"` は vault へ書き込む（`DepositArtifact` 権限が必要）。`"plan"` は vault へ書かず予定 policy のみ算定してローカル参照に留める。

### $SourceVaultComfyUIDepositGrant
型: AccessGrant | None, 初期値: `None`
commit deposit に使う AccessGrant。`SourceVaultMCPMintAccessGrant` / `sourcevault_request_access`（`action=DepositArtifact`）で得た grant を設定すると completion hook の deposit がそれで commit する。

## 接続・診断

### SourceVaultComfyUIStatus[opts]
ComfyUI サーバの状態を返す。到達不能でも message を出さず `<|"Status"->"Offline"|>` を返す。結果は TTL cache される。
→ `Association` (`"Status"->{"OK"|"Offline"}, "Provider", "BaseURL", "Version", "Capabilities", "Stats", "Reason"`)
Options: `"Refresh" -> False`（True でキャッシュを破棄して再 probe）

### SourceVaultComfyUIAPIAvailable[opts]
ComfyUI サーバへ到達可能かを `True`/`False` で返す（TTL cache）。
→ `True | False`
Options: `"Refresh" -> False`

### SourceVaultComfyUISystemStats[opts] → Association
`/system_stats` を GET して `<|"Status","Data"|>` を返す。

### SourceVaultComfyUIObjectInfo[opts] → Association
`/object_info`（利用可能 node 定義）を GET して返す。

### SourceVaultComfyUIModels[folder:All, opts] → Association
`/models` または `/models/{folder}` を GET して返す。`folder` が `All`/`Automatic` なら全一覧。

### SourceVaultComfyUIQueue[opts] → Association
`/queue`（`queue_running` / `queue_pending`）を GET して返す。

### SourceVaultComfyUIInterrupt[opts] → Association
`/interrupt` を POST する低レベル debug primitive。ComfyUI の `/interrupt` は実行中 job を止める **global 操作**であり prompt スコープではない。複数 job 運用では prompt スコープの killer 経路（`SourceVaultComfyUIRegisterBackend` の killer）を使うこと。

## 低レベル HTTP API

### SourceVaultComfyUIAPICall[endpoint, params:None, opts] → Association
JSON GET/POST の汎用ラッパ。`params` が `None`/`<||>` なら GET、`Association` なら POST(JSON)。binary download は `SourceVaultComfyUIView` を使う。

### SourceVaultComfyUIView[file_Association, opts]
`/view` で出力ファイルの bytes を取得する。
→ `<|"Status","Bytes"->ByteArray,"ContentType","File"|>`
Options: `"Save" -> True`（True で `$SourceVaultComfyUIStoreRoot/cache/` へローカル保存）
`file` は `<|"filename","subfolder","type"|>` 形式。キーは大文字小文字どちらも受け付ける。

### SourceVaultComfyUIUploadImage[pathOrImage, opts]
`/upload/image` に multipart/form-data でアップロードする。元ファイル名・source path は送らず random 名を使う。
→ `<|"Status","Name","Subfolder","Type"|>`
Options: `"Overwrite" -> True`, `"Type" -> "input"`, `"Subfolder" -> ""`

## Workflow レジストリ

workflow template はコードではなくデータとして `PrivateVault/comfyui/workflows/<name>/` に `workflow-api.json` と `meta.json` で永続化される。

### SourceVaultComfyUIRegisterWorkflow[name, workflow, opts]
API format workflow JSON を名前付きで登録する。通常保存形式 JSON（`nodes`/`links` キーを持つ）は `"Reason"->"NotAPIFormat"` で拒否する。ComfyUI frontend の File → Export (API) で得た JSON を渡す。
→ `<|"Status"->{"Registered"|"Error"},"Name","WorkflowHash"|>`
Options:
- `"Kind" -> "Image"` (種別: `"Image"` | `"Video"`)
- `"Variables" -> <||>` (inject ポイントのマッピング `<|"Prompt"-><|"NodeId","Input"|>,...|>`)
- `"Outputs" -> <||>` (出力 node マッピング)
- `"RequiredModels" -> {}` (必要モデル名リスト)
- `"Tags" -> {}` (検索用タグ)
- `"TrustedForPrivateInput" -> False` (private 入力を許可するか)
- `"AllowedNodeTypes" -> Automatic` (許可 node type 制限。`Automatic` → `Null` で保存)

### SourceVaultComfyUIWorkflows[opts] → Association
登録済み workflow 名と meta の一覧を返す。
→ `<|"Status"->"OK","Workflows"->{<|"Name","Kind","Tags","WorkflowHash","UpdatedAt"|>,...}|>`

### SourceVaultComfyUIWorkflow[name, opts] → Association
登録済み workflow record（Workflow JSON + meta）を返す。
→ `<|"Status"->{"OK"|"Error"},"Workflow","Meta","WorkflowHash"|>`

### SourceVaultComfyUIValidateWorkflow[workflowOrRecord, opts] → Association
API format 整形式・Variables/Outputs の node 実在を検査する。
Options: `"Variables"`, `"Outputs"`, `"ObjectInfo"`（RequiredModels 確認用）

### SourceVaultComfyUIRenderWorkflow[workflowOrName, vars_Association, opts] → Association
Variables マッピングに従って `vars` を API JSON の node/input に inject した workflow を返す。
→ `<|"Status","Workflow","WorkflowHash","Name"|>`

例:
```mathematica
SourceVaultComfyUIRenderWorkflow["sdxl_basic",
  <|"Prompt" -> "a cat", "Seed" -> 42, "Width" -> 1024, "Height" -> 1024|>]
```

## Server workflow の一覧・取り込み

ComfyUI frontend の「ワークフロー」ブラウズに見える server 保存 workflow (userdata API) を、Wolfram 側から一覧・取得・registry へ取り込みできる。**手動の API エクスポートは不要**（browser 形式は自動変換される）。

### SourceVaultComfyUIServerWorkflows[opts] → Association
server 保存 workflow を一覧する。
→ `<|"Status","Workflows"->{<|"Name","Path","Size","Modified","Registered"|>,...}|>`（`Registered` は registry 取り込み済みか）
Options: `"Directory" -> "workflows"`

### SourceVaultComfyUIServerWorkflowsView[opts] → Dataset
上の Dataset 表示版。Options: `"Limit" -> 50`。

### SourceVaultComfyUIFetchServerWorkflow[name] → Association
server 保存 workflow の JSON を取得し形式を判定する。
→ `<|"Status","Name","Path","Format"->{"API"|"Browser"},"Workflow"|>`
`name` は `"upscaled_video"` のように拡張子・ディレクトリ無しでよい（自動補完）。

### SourceVaultComfyUIConvertWorkflow[browserWF, opts] → Association
frontend 通常保存形式 (nodes/links) を API format へ **best-effort 変換**する。`/object_info` の入力スキーマで widgets_values を input 名へ対応付け、Reroute 追跡・PrimitiveNode 値化・`control_after_generate` スキップを行う。muted/bypassed/group node は警告してスキップ。
→ `<|"Status","Workflow","Warnings"|>`（`Warnings` を必ず確認し、変換後は検証・テスト実行を推奨）

### SourceVaultComfyUIImportServerWorkflow[name, opts] → Association
**一発取り込み**: 取得 → (browser 形式なら API へ変換) → Variables/Outputs 自動検出 → registry 登録。
→ `<|"Status","Name","Format","Warnings","Variables","Outputs","Kind","Registration","Workflow"|>`
Options:
- `"Name" -> Automatic`（登録名。既定は拡張子抜きファイル名）
- `"Variables" -> Automatic`（sampler の seed/noise_seed、positive/negative リンク先 TextEncode の text、latent 先の width/height を自動検出。明示指定も可）
- `"Outputs" -> Automatic`（object_info の output_node フラグから自動検出。Video 系 class は Videos へ）
- `"Kind" -> Automatic`（Videos 非空なら `"Video"`）
- `"Register" -> True`（False で変換結果のみ返し登録しない）

例:
```mathematica
SourceVaultComfyUIServerWorkflowsView[]                       (* 一覧 *)
SourceVaultComfyUIImportServerWorkflow["sdxl_simple_example2"] (* 取り込み *)
```

## Job 実行

### SourceVaultComfyUIQueuePrompt[workflow, opts]
API format workflow を `/prompt` に POST し prompt_id を返す。過剰実行対策として `SourceVaultRateLimit["ComfyUISubmit"]` をチョークポイントとする。
→ `<|"Status","PromptId","ClientId","NodeErrors"|>`
Options: `"ClientId" -> Automatic`（Automatic で `"sv-comfy-<random>"` を生成）

### SourceVaultComfyUIPoll[promptId, opts]
`/queue` と `/history` を確認して job 状態を返す。transient HTTP 失敗は `"Running"` 扱い（terminal failure にしない）。
→ `<|"Status"->"OK","State"->{"Running"|"Completed"|"Failed"|"Lost"},"Transient"->Bool|>`
Options:
- `"Seen" -> False`（True: 投入後 1 回以上観測済み。False だと queue/history 双方に無い場合 Lost 誤判定を避けるため Running 扱い）
- `"Queue" -> Automatic`（注入用 queue snapshot）
- `"History" -> Automatic`（注入用 history snapshot）

### SourceVaultComfyUIJobStatus[promptId, opts] → Association
`SourceVaultComfyUIPoll` の薄いラッパ。同じ返り値形式。

### SourceVaultComfyUIFetchOutputs[promptIdOrHistory, opts] → Association
history から出力ファイル一覧（`filename`/`subfolder`/`type`/`kind`）を取り出す。
→ `<|"Status","Outputs"->{<|"filename","subfolder","type","kind"|>,...}|>`
`promptIdOrHistory` は prompt_id 文字列または history Association どちらも受け付ける。

### SourceVaultComfyUIBuildJobSpec[spec_Association, opts] → Association
純関数 helper（HTTP を叩かない）。workflow 選択・変数解決・seed 確定・privacy 計算・API workflow rendering・External executor jobSpec 構築を行う。in-workflow 遷移内で使う。
→ `<|"Status","Provider","WorkflowName","Workflow","WorkflowHash","Seed","PrivacyLevel","OutputsDecl","RequiredModels","Request","JobTimeout","ExternalJobSpec"|>`

`spec` のキー:
- `"Prompt"` (String)
- `"NegativePrompt"` (String)
- `"Seed"` (Integer | Automatic)
- `"Width"`, `"Height"` (Integer)
- `"PrivacyLevel"` (Number 0–1)
- `"Inputs"` (List of `<|"PrivacyLevel",...|>`)
- `"ProviderOptions"` (`<|"Workflow" -> name|>`)

例:
```mathematica
SourceVaultComfyUIBuildJobSpec[<|
  "Prompt" -> "a cat",
  "Seed" -> Automatic,
  "Width" -> 1024, "Height" -> 1024,
  "ProviderOptions" -> <|"Workflow" -> "sdxl_basic"|>
|>]
```

### SourceVaultComfyUISubmitExternal[workflowOrName, vars_Association:<||>, opts]
ComfyUI job を ClaudeOrchestrator External executor backend（`Backend->"ComfyUI"`）として 1 遷移 WorkflowNet で**非ブロック投入**する（即返り、FE を固めない）。内部で backend 登録・grant 確保・poll tick 起動を自己治癒する（冪等）。
→ `<|"Status"->"Queued","Provider","WorkflowId","PromptId","JobId","Awaiting"->True|>`
生成は背景の poll tick が進め、完了時に deposit されて workflow が Done になる。進捗は `SourceVaultComfyUIJobStatus[promptId]`、結果 URI は `ClaudeOrchestrator`Workflow`ClaudeWorkflowState[workflowId]` の Out トークン Payload（`"SourceVaultRef"`）で得られる。表示は `NBAccess`NBInsertArtifactCell[uri]`。
ClaudeOrchestrator`Workflow` engine が未ロードなら `"ExternalExecutorInactive"`、backend dispatch 未整備なら `"ExternalBackendDispatchUnavailable"` を返す。
Options:
- `"PrivacyLevel" -> Automatic`
- `"NotifyNotebook" -> None`（完了通知先 notebook）

### SourceVaultComfyUIRegisterBackend[] → Association
ComfyUI 用の launcher/status reader/killer を `ClaudeOrchestrator`Workflow`ClaudeRegisterExternalBackend` へ登録する（冪等）。orchestrator backend dispatch が未整備なら `"ExternalBackendDispatchUnavailable"` を返す。

### SourceVaultComfyUIActivate[opts] → Association
ComfyUI を非ブロック生成 provider として live 稼働させる（冪等）。1 カーネルセッションに 1 回呼ぶ。処理順: (1) backend 登録、(2) auto-commit 用 DepositArtifact grant を発行して `$SourceVaultComfyUIDepositGrant` に設定、(3) poll tick を共有タスクへ登録（`ClaudeRuntime_externalrunner` ロード済みならフル activate、未ロードでも `ClaudeExternalJobPollTick` を直接登録して背景進行させる `Via->"DirectPollTick"`）。
→ `<|"Status"->{"OK"|"Partial"},"Backend","Grant","Executor","DepositMode"|>`（`Grant` の Status が OK なら auto-commit 可）
Options:
- `"RenewGrant" -> False`（True で grant 再発行）
- `"GrantTTLSeconds" -> 86400`
- `"GrantMaxAccessLevel" -> 0.49`（この値以上の実効 PL の deposit は approval gate で保護され auto-commit しない）

### SourceVaultComfyUIDepositOutputs[promptIdOrHistory, opts]
出力ファイルを `/view` で取得し `SourceVaultMCPDeposit` へ渡して artifact URI を返す。deposit gate/quota 失敗時は job を成功扱いにしつつ `"DepositDenied"`/`"DepositQuotaExceeded"` を残す。deposit backend が無い環境ではローカルキャッシュパスのみ返す（`"DepositBackend"->"LocalCacheOnly"`）。
→ `<|"Status","Artifacts"->{...},"DepositBackend"|>`
Options:
- `"PrivacyLevel" -> Automatic`
- `"Provenance" -> <||>`（artifact provenance に merge される追加メタデータ）

## 同期実行

### SourceVaultComfyUIRunWorkflow[workflowOrName, vars_Association:<||>, opts]
同期経路（submit → poll loop → fetch → deposit）。生成が終わるまでカーネルをブロックする。**ユーザーが明示要求した対話的な 1 枚生成では使ってよい**（SDXL で数十秒の通常の長い評価）。動画・複数枚・バッチ・orchestrator/背景経路では使わず `SourceVaultComfyUISubmitExternal`（非ブロック）を使う。
→ `<|"Status"->{"OK"|"Error"|"Timeout"},"Provider","PromptId","Artifacts","Outputs","WorkflowHash"|>`
`Artifacts` の各要素: deposit 成功時は `"URI"->"sv://artifact/..."`（表示は `NBAccess`NBInsertArtifactCell[uri]`）、deposit backend/grant 無し時は `"File"`（ローカルキャッシュパス。`Import[file]` で表示可）。
Options:
- `"PollInterval" -> 1.5`（ポーリング間隔秒）
- `"Deposit" -> Automatic`（False で materialize/deposit を完全 skip）
- `"PrivacyLevel" -> Automatic`

例:
```mathematica
SourceVaultComfyUIRunWorkflow["sdxl_basic",
  <|"Prompt" -> "sunset over mountains", "Seed" -> 12345|>,
  "PollInterval" -> 2.0]
```

## Provider エントリポイント

### SourceVaultComfyUIGenerateToNotebook[workflowName, promptOrVars, opts] → Association
ClaudeEval 向け一括関数（★冒頭レシピ参照）。adapter 自動ロード → Activate → 未登録なら server から取り込み → `SubmitExternal` 非ブロック投入 → 完了待ち（評価中は背景 tick が回らないため poll tick を手動駆動）→ deposit URI を `NBAccess`NBInsertArtifactCell` で表示。
→ `<|"Status"->{"OK"|"Timeout"|"Error"},"URI","Displayed","MediaKind","PrivacyLevel","PromptId","WorkflowId"|>`
Options: `"PrivacyLevel" -> 0.0`, `"TimeoutSeconds" -> 600`, `"PollInterval" -> 3.0`, `"Notebook" -> Automatic`
`promptOrVars`: 英語プロンプト文字列、または `<|"Prompt"->...,"NegativePrompt"->...,"Seed"->...,"Width"->...,"Height"->...|>`。

### SourceVaultComfyUIEnsureLoaded[] → Association
`SourceVault_comfyui.wl` を on-demand ロードする（冪等。auto-load される SourceVault.wl 側が提供）。ClaudeEval 生成コードは `Get` の代わりにこれを使う。
→ `<|"Status"->{"AlreadyLoaded"|"Loaded"|"Error"}|>`

### SourceVaultComfyUIGenerate[spec_Association, opts]
provider 専用エントリポイント。`"Mode"` で動作を切り替える。
→ `Association`（Mode に応じて `BuildJobSpec` / `RunWorkflow` / `SubmitExternal` の返り値）
Options:
- `"Mode" -> "BuildJobSpec"` — `"BuildJobSpec"`: in-workflow helper（HTTP 不使用）、`"DebugSync"`: 非 FE 同期実行、`"Async"`: External 投入（現状 backend dispatch 未整備時 stub）
- `"PrivacyLevel" -> Automatic`
- `"NotifyNotebook" -> None`

`spec` のキー: `"Prompt"`, `"NegativePrompt"`, `"Seed"`, `"Width"`, `"Height"`, `"ProviderOptions" -> <|"Workflow" -> name|>`, `"PrivacyLevel"`, `"Inputs"`

例:
```mathematica
(* in-workflow: jobSpec 構築のみ *)
SourceVaultComfyUIGenerate[<|
  "Prompt" -> "a robot",
  "ProviderOptions" -> <|"Workflow" -> "sdxl_basic"|>
|>, "Mode" -> "BuildJobSpec"]

(* 非 FE 同期実行 *)
SourceVaultComfyUIGenerate[spec, "Mode" -> "DebugSync"]

(* 非ブロック投入 (External executor 有効時) *)
SourceVaultComfyUIGenerate[spec, "Mode" -> "Async", "NotifyNotebook" -> EvaluationNotebook[]]
```

## 状態機械

`SourceVaultComfyUIPoll` / `SourceVaultComfyUIJobStatus` が返す `"State"` の値:

| 状態 | 意味 |
|---|---|
| `"Running"` | queue 内に存在、または transient HTTP 失敗（terminal にしない） |
| `"Completed"` | history にあり outputs が存在し error なし |
| `"Failed"` | history にあり `status_str == "error"` |
| `"Lost"` | queue にも history にも存在せず、かつ `seen=True`（投入確認済み）の場合 |

`seen=False`（未確認投入）かつ queue/history 双方に無い場合は `"Running"` 扱いにして Lost 誤判定を避ける。

## HTTP フック契約（テスト用）

```mathematica
$SourceVaultComfyUIHTTPHook = Function[req,
  (* req: <|"Method","Endpoint","Query","Body"|> *)
  <|"StatusCode" -> 200, "Body" -> jsonString|>];
```

mock は `"Body"` として JSON string または ByteArray を返せる。`SourceVaultComfyUIUploadImage` の mock は `"Body"` に `<|"name","subfolder","type"|>` JSON を返す。

## 依存関係

- [SourceVault](https://github.com/transreal/SourceVault) — `$SourceVaultRoots`, `SourceVaultMCPDeposit`
- [SourceVault_core](https://github.com/transreal/SourceVault_core) — 基盤ユーティリティ
- [SourceVault_mcp](https://github.com/transreal/SourceVault_mcp) — `SourceVaultMCPDeposit`, `SourceVaultMCPMintAccessGrant`
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) — External executor backend dispatch（Phase 0.5、オプション）
- [ClaudeOrchestrator_workflow](https://github.com/transreal/ClaudeOrchestrator_workflow) — `ClaudeCreateWorkflowNet`, `ClaudeStepWorkflow`, `ClaudeRegisterExternalBackend`（オプション）
- [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime) — `ClaudeActivateExternalExecutor`（オプション）