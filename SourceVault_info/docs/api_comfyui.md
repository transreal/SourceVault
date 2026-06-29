# SourceVault_comfyui API リファレンス

パッケージ: `SourceVault_comfyui` ([GitHub](https://github.com/transreal/SourceVault_comfyui))

## 概要

ComfyUI ローカル画像/動画生成アダプタ。thin HTTP クライアント・workflow レジストリ・非ブロック job 管理・artifact deposit を提供する。

ロード順: `SourceVault.wl` → `SourceVault_core.wl` → `SourceVault_comfyui.wl`。
UTF-8 ファイルなので `Block[{$CharacterEncoding="UTF-8"}, Get["SourceVault_comfyui.wl"]]` で読む。

**設計上の不変条件**
- 公開関数は `$Failed` を返さず常に `Association` を返し、必ず `"Status"` キーを持つ。
- 生成バイナリの正本は `SourceVaultMCPDeposit` / immutable snapshot (`sv://artifact/...`)。`PrivateVault/comfyui` は registry・job 状態・log の置き場であり正本ストアではない。
- HTTP 層は `$SourceVaultComfyUIHTTPHook` で差し替え可能（テスト時 mock）。
- `SourceVaultComfyUISubmitExternal` は ClaudeOrchestrator External executor backend (Phase 0.5) が前提であり、未整備の場合は `"ExternalBackendDispatchUnavailable"` を返す stub になる。

**主要な利用パターン**

```
(* 1. 同期 debug 実行 (非 FE / wolframscript) *)
SourceVaultComfyUIRunWorkflow["myWF", <|"Prompt" -> "a cat"|>]

(* 2. in-workflow jobSpec 構築 (ClaudeOrchestrator 遷移内) *)
SourceVaultComfyUIGenerate[<|"Prompt"->"a dog","ProviderOptions"-><|"Workflow"->"myWF"|>|>]

(* 3. 非ブロック投入 (External executor 有効時) *)
SourceVaultComfyUIGenerate[spec, "Mode" -> "Async"]
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

## Job 実行

### SourceVaultComfyUIQueuePrompt[workflow, opts]
API format workflow を `/prompt` に POST し prompt_id を返す。
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
ComfyUI job を ClaudeOrchestrator External executor backend（`Backend->"ComfyUI"`）として 1 遷移 WorkflowNet で非ブロック投入する。
→ `<|"Status"->{"Submitted"|"Error"},"WorkflowId","PromptId"|>`
ClaudeOrchestrator`Workflow` engine が未ロード/未 activate なら `"ExternalExecutorInactive"`、backend dispatch 未整備なら `"ExternalBackendDispatchUnavailable"` を返す。完了時の deposit/反映は status reader と completion hook が担う。
Options:
- `"PrivacyLevel" -> Automatic`
- `"NotifyNotebook" -> None`（完了通知先 notebook）

### SourceVaultComfyUIRegisterBackend[] → Association
ComfyUI 用の launcher/status reader/killer を `ClaudeOrchestrator`Workflow`ClaudeRegisterExternalBackend` へ登録する（冪等）。orchestrator backend dispatch が未整備なら `"ExternalBackendDispatchUnavailable"` を返す。

### SourceVaultComfyUIActivate[opts] → Association
ComfyUI を非ブロック生成 provider として live 稼働させる（冪等）。1 カーネルセッションに 1 回呼ぶ。処理順: (1) backend 登録、(2) auto-commit 用 DepositArtifact grant を発行して `$SourceVaultComfyUIDepositGrant` に設定、(3) `ClaudeRuntime`ClaudeActivateExternalExecutor` で poll tick を共有タスクへ登録。
→ `<|"Status","BackendRegistered","GrantIssued","ExecutorActivated"|>`
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

## 同期 debug 実行

### SourceVaultComfyUIRunWorkflow[workflowOrName, vars_Association:<||>, opts]
同期 debug 経路（submit → poll loop → fetch → deposit）。FrontEnd を持たない wolframscript / subkernel 用であり、main kernel / notebook のデフォルトにしてはならない。
→ `<|"Status"->{"OK"|"Error"|"Timeout"},"Provider","PromptId","Artifacts","Outputs","WorkflowHash"|>`
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