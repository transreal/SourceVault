# SourceVault_comfyui / ClaudeOrchestrator 画像・動画生成 provider 仕様案 v0.1

作成日: 2026-06-29  
レビュー反映: 2026-06-29  
対象: `SourceVault_comfyui.wl` / SourceVault adapter 群 / ClaudeOrchestrator notebook generation workflow  
目的: ClaudeOrchestrator から ComfyUI をローカル画像・動画生成 provider として呼び出し、スライド用 notebook 生成などのワークフローで生成物を安全に参照・保存・再利用できるようにする。

## 0. 結論

`ClaudeOrchestrator` / `SourceVault` 本体は ComfyUI に依存させず、汎用の「media generation provider」抽象を持つべきである。ただし `SourceVault_comfyui.wl` は単なる最小共通 API の皮ではなく、ComfyUI の workflow / node / model / queue / history / custom node を十分に使える「厚い adapter」にする。

したがって採用方針は次の二層構造とする。

1. 上位層: `SourceVaultGenerateMedia` 相当の汎用要求
   - `Task` は `"Image"` / `"Video"` / `"ImageVariation"` / `"Storyboard"` / `"SlideAsset"` など。
   - provider は `"comfyui"` / 将来の cloud provider / ローカル別実装から選択できる。
   - MVP では ClaudeOrchestrator の workflow transition から WL 関数としてこの層を呼ぶ。LLM に tool として露出する仕組みは現行 ClaudeOrchestrator には無いため、ClaudeRuntime tool 化は将来拡張とする。

2. ComfyUI adapter 層: `SourceVaultComfyUI*` 関数群
   - workflow API JSON を直接登録・変数置換・検証・実行できる。
   - ComfyUI の `/prompt`, `/history`, `/view`, `/upload/image`, `/object_info`, `/queue`, `/interrupt` などを扱う。MVP の進捗監視は polling 既定とし、WebSocket は将来オプションにする。
   - AnimateDiff / WAN / HunyuanVideo / ControlNet / LoRA / IPAdapter / upscaler など、ComfyUI 固有機能を template と capability として露出する。

この形にすると、通常利用では provider 差し替え可能性を保ち、必要なときだけ ComfyUI の強みを全力で使える。

## 1. 背景分析

### 1.1 汎用 provider 化を優先すべき理由

ClaudeOrchestrator がスライド notebook を生成するとき、必要なのは多くの場合「このスライドに入れる図を作る」「短い動画を作る」「生成結果を notebook にリンクする」という抽象的な仕事である。ここで orchestrator 本体が ComfyUI の node ID や checkpoint 名を知ると、将来別の provider を追加するたびに notebook 生成側が壊れやすくなる。

また SourceVault にはすでに provider registry、summary provider、MCP projection、release policy、append-only artifact deposit という方向性がある。ComfyUI も同じ思想で、外部生成 provider の一つとして入れるほうが自然である。

### 1.2 ComfyUI 特化機能を弱めるべきでない理由

一方で ComfyUI は、単純な text-to-image API ではなく workflow graph 実行系である。強みは、node graph の再現性、checkpoint / LoRA / ControlNet / image-to-image / video node / upscaler / postprocess の組み合わせにある。

この能力を汎用 schema の最小公倍数に押し込めると、ComfyUI を使う意味が薄くなる。特に教材スライドでは次が重要になる。

- 同一スライド群で style / character / seed / aspect ratio を固定する。
- 既存の図や数式レンダリングを ControlNet / img2img の入力にする。
- 生成結果に workflow provenance を残して、後で seed や prompt を変えて再生成する。
- 画像だけでなく短い mp4 / gif / webm を生成して notebook からリンクする。
- ComfyUI の custom node が増えても、SourceVault 本体を変更せずに template を増やせる。

### 1.3 推奨判断

結論として、`SourceVault_comfyui.wl` は「汎用 media provider interface を満たす ComfyUI provider」であり、同時に「ComfyUI workflow control toolkit」でもあるべきである。

本体側の依存方向:

```text
ClaudeOrchestrator
  -> generic media generation request
  -> SourceVault media provider registry
  -> SourceVault_comfyui.wl, only when provider == "comfyui"
  -> ComfyUI local server
```

`ClaudeOrchestrator` は ComfyUI 固有 workflow JSON を直接組み立てない。MVP では、媒体生成ステップを External(ComfyUI) transition として表現し、その transition の backend が `SourceVaultGenerateMedia` / `SourceVaultComfyUIGenerate` を jobSpec 構築 helper として使う。advanced mode では `ProviderOptions -> <|"Workflow" -> ..., "ComfyUI" -> ...|>` を渡せる。

## 2. 既存コードとの接続方針

### 2.1 ファイル構成

新規ファイル:

```text
$packageDirectory/SourceVault_comfyui.wl
```

保存先:

```text
PrivateVault/comfyui/
  config/
  workflows/
  jobs/
  cache/
  logs/
```

`PrivateVault/comfyui` は workflow registry、job 状態、低漏洩 projection、ログの置き場であり、生成バイナリの正本ストアではない。生成された画像・動画は `SourceVaultMCPDeposit` / immutable snapshot 系に deposit し、既存の `sv://artifact/...` URI を正準参照にする。ComfyUI 由来であることは URI の独自サブ namespace ではなく、artifact record の `"Provider" -> "comfyui"` で表す。

### 2.2 ロード方針

MVP では `SourceVault.wl` の常時 auto-load には入れない。理由は、ComfyUI は GPU / ローカル HTTP server / 大きな model store と結びつくため、SourceVault の通常利用に副作用を持ち込まないほうがよいからである。

推奨ロード:

```wolfram
Block[{$CharacterEncoding = "UTF-8"},
  Get[FileNameJoin[{$packageDirectory, "SourceVault_comfyui.wl"}]]
]
```

将来、`SourceVault.wl` に optional auto-load を追加する場合も、次の条件を満たす。

- ComfyUI server へ自動接続しない。
- GPU job を自動投入しない。
- API 到達確認は TTL cache 付きで軽く行う。
- 失敗しても SourceVault load を失敗させない。

MCP / `SourceVaultSummaries` へ生成済み素材を出す場合は、GPU/HTTP/FrontEnd に触る本体とは別に、FE/NBAccess 非依存かつ JSON-safe な軽量 projection モジュールを用意する。候補名は `SourceVault_comfyui_projection.wl` とする。この projection モジュールだけを service kernel に load し、`SourceVault_comfyui.wl` 本体は main kernel / workflow executor 側でのみ load する。

### 2.3 Context

`SourceVault_eagle.wl` と同様に、`BeginPackage["SourceVault`"]` を使う。公開シンボルは `SourceVaultComfyUI*` とし、内部 helper は `SourceVault`Private`` に置く。

## 3. ComfyUI API 前提

公式ドキュメント上、ComfyUI server は workflow を `/prompt` に POST して queue に投入し、完了後に `/history/{prompt_id}` と `/view` で出力を取得する流れを提供する。`/ws` による進捗受信も存在するが、Wolfram Language / FrontEnd 上の安定性と既存 External executor の poll tick に合わせ、MVP は `/history/{prompt_id}` と `/queue` の polling を既定にする。API 用 workflow は browser の通常保存形式ではなく `File -> Export Workflow (API)` で得られる JSON 形式を使う。

参照:

- ComfyUI Server API Routes: https://docs.comfy.org/development/comfyui-server/comms_routes
- ComfyUI API Examples: https://docs.comfy.org/development/comfyui-server/api-examples
- Workflow API Format: https://docs.comfy.org/development/api-development/workflow-api-format

本仕様では legacy server API を第一対象にする。

主要 endpoint:

```text
GET  /system_stats
GET  /object_info
GET  /models
GET  /models/{folder}
POST /prompt
WS   /ws?clientId=<uuid>        (future optional)
GET  /history/{prompt_id}
GET  /view?filename=...&subfolder=...&type=...
POST /upload/image
GET  /queue
POST /queue
POST /interrupt
POST /free                      (version-dependent)
```

新しい ComfyUI / Comfy Cloud 系 API は将来 adapter backend として追加可能にするが、MVP はローカル server `http://127.0.0.1:8188` と legacy server API を対象とする。`/models`、`/free` などは版差があるため、実装時は対象 ComfyUI バージョンを記録し、`/object_info` と実機 `/prompt` で検証する。

## 4. 公開 API 仕様

### 4.1 設定

```wolfram
$SourceVaultComfyUIBaseURL
$SourceVaultComfyUIStoreRoot
$SourceVaultComfyUIHTTPTimeout
$SourceVaultComfyUIJobTimeout
$SourceVaultComfyUIDefaultWorkflow
$SourceVaultComfyUIDefaultProviderName
```

既定値:

```wolfram
$SourceVaultComfyUIBaseURL = "http://127.0.0.1:8188";
$SourceVaultComfyUIDefaultProviderName = "comfyui";
```

`$SourceVaultComfyUIHTTPTimeout` は `/queue` / `/history` / `/view` など単一 HTTP 呼び出しの短い timeout (15-30 秒級) とする。`$SourceVaultComfyUIJobTimeout` は ComfyUI job 全体の timeout (分単位、External executor jobSpec の Timeout に渡す値) とする。この 2 つを混同しない。

`$SourceVaultComfyUIStoreRoot` は `SourceVaultInitialize[]` 済みなら `PrivateVault/comfyui`、未初期化なら `$TemporaryDirectory/sourcevault-comfyui` または既存の SourceVault temporary root を fallback とする。生成バイナリや private provenance を `$packageDirectory` 配下に置かない。

### 4.2 接続・診断

```wolfram
SourceVaultComfyUIStatus[opts]
SourceVaultComfyUIAPIAvailable[opts]
SourceVaultComfyUISystemStats[opts]
SourceVaultComfyUIObjectInfo[opts]
SourceVaultComfyUIModels[folder_:All, opts]
SourceVaultComfyUIQueue[opts]
SourceVaultComfyUIInterrupt[opts]
```

返り値は Association 統一:

```wolfram
<|
  "Status" -> "OK" | "Offline" | "Error",
  "Provider" -> "comfyui",
  "BaseURL" -> "...",
  "Version" -> _String | Missing[],
  "Models" -> _Association | Missing[],
  "Capabilities" -> {...},
  "Reason" -> _String | Missing[]
|>
```

到達不能は message を出さず `<|"Status" -> "Offline"|>` を返す。連続 notebook generation 中に接続失敗で固まらないよう、Eagle adapter と同様に TTL cache を持つ。
階層は次のように統一する。接続診断系 (`SourceVaultComfyUIStatus` / `SourceVaultComfyUIAPIAvailable`) は `"Status" -> "Offline"` を返してよい。一方、実際の API 呼び出しや generation request の失敗は `<|"Status" -> "Error", "Reason" -> "Offline"|>` を返す。

### 4.3 低レベル HTTP API

```wolfram
SourceVaultComfyUIAPICall[endpoint_String, params_:None, opts]
SourceVaultComfyUIUploadImage[path_String, opts]
SourceVaultComfyUIView[file_Association, opts]
```

`SourceVaultComfyUIAPICall` は JSON GET/POST を扱う。binary download は `SourceVaultComfyUIView` で扱う。
`SourceVaultComfyUIUploadImage` は `/upload/image` の multipart/form-data 専用コードパスとし、RawJSON byte helper を流用しない。

`SourceVaultComfyUIView` の入力例:

```wolfram
<|
  "filename" -> "ComfyUI_00001_.png",
  "subfolder" -> "",
  "type" -> "output"
|>
```

返り値:

```wolfram
<|
  "Status" -> "OK",
  "Bytes" -> ByteArray[...],
  "ContentType" -> "image/png",
  "File" -> "...local saved path..."
|>
```

### 4.4 Workflow 登録

```wolfram
SourceVaultComfyUIRegisterWorkflow[name_String, workflow_, opts]
SourceVaultComfyUIWorkflows[opts]
SourceVaultComfyUIWorkflow[name_String, opts]
SourceVaultComfyUIValidateWorkflow[workflow_, opts]
SourceVaultComfyUIRenderWorkflow[workflowOrName_, vars_Association, opts]
```

登録する workflow は API format JSON の Association を正とする。通常保存形式 JSON を渡された場合は、MVP では自動変換しない。`"Reason" -> "NotAPIFormat"` を返し、ComfyUI frontend から API format export を促す。

workflow registry record:

```wolfram
<|
  "Name" -> "slide-illustration-sdxl",
  "Kind" -> "Image" | "Video" | "ImageToImage" | "Upscale",
  "TrustedForPrivateInput" -> False,
  "AllowedNodeTypes" -> Automatic,
  "Workflow" -> <|... API format ...|>,
  "Variables" -> <|
    "Prompt" -> <|"Node" -> "6", "Input" -> "text"|>,
    "NegativePrompt" -> <|"Node" -> "7", "Input" -> "text"|>,
    "Seed" -> <|"Node" -> "3", "Input" -> "seed"|>,
    "Width" -> <|"Node" -> "5", "Input" -> "width"|>,
    "Height" -> <|"Node" -> "5", "Input" -> "height"|>
  |>,
  "Outputs" -> <|
    "Images" -> {"9"},
    "Videos" -> {}
  |>,
  "RequiredModels" -> {...},
  "Tags" -> {"slides", "sdxl"},
  "CreatedAt" -> "...",
  "UpdatedAt" -> "..."
|>
```

`SourceVaultComfyUIValidateWorkflow` は、API JSON の整形式だけでなく次を検査する。

- node graph が API format として整形式である。
- `Variables` が実在 node/input を指す。
- `Outputs` 宣言が history から取得可能な出力 node と整合する。
- `RequiredModels` が実機の `/object_info` または model list で確認可能である。
- private input を受け取る workflow では、node type が信頼済み allowlist に入っている。

custom node の外部送信有無は workflow JSON だけから保証できない。そのため MVP では egress 検出を試みず、機密入力を渡せるのはユーザーが事前登録した信頼済み workflow かつ allowlist node のみで構成されるものに限る。LLM が生成または改変した workflow JSON は機密入力不可とする。

### 4.5 Job 実行

```wolfram
SourceVaultComfyUIQueuePrompt[workflow_, opts]
SourceVaultComfyUIPoll[jobOrPromptId_, opts]
SourceVaultComfyUIJobStatus[jobOrPromptId_, opts]
SourceVaultComfyUIFetchOutputs[jobOrPromptId_, opts]
SourceVaultComfyUISubmitExternal[workflowOrName_, vars_Association:<||>, opts]
SourceVaultComfyUIDepositOutputs[jobOrHistory_, opts]
SourceVaultComfyUIRunWorkflow[workflowOrName_, vars_Association:<||>, opts]
```

MVP の本筋は非ブロック実行である。`SourceVaultComfyUISubmitExternal` は ComfyUI job を ClaudeOrchestrator の External executor backend (`Backend -> "ComfyUI"`) として投入し、`/prompt` POST 直後に `PromptId` / `JobId` を持つ `AwaitingLLM` 相当の状態を返す。完了判定は `ClaudeExternalJobPollTick` 系の poll tick から `/history/{prompt_id}` と `/queue` を確認して行い、artifact deposit と notebook 反映は `$ClaudeExternalCompletionHook` 相当の完了 hook で行う。

ただし現行 External executor は WolframScript 子プロセス job 向けの singleton hook (`$ClaudeExternalJobLauncher` / `$ClaudeExternalJobStatusReader` / `$ClaudeExternalJobKiller`) を前提としており、backend 別 dispatch をまだ持たない。したがって `Backend -> "ComfyUI"` は `SourceVault_comfyui.wl` だけでは成立しない。Phase 0 で `ClaudeRuntime_externalrunner.wl` ないし `ClaudeOrchestrator_workflow.wl` に backend dispatch 層を追加し、WolframScript job と ComfyUI job が共存できることを前提条件にする。

backend dispatch 層の最小契約:

- launcher registry は `jobSpec["Backend"]` を見て WolframScript launcher / ComfyUI launcher を分岐する。
- status reader registry は `awaitMeta["Backend"]` または `jobSpec["Backend"]` を見て `JobDir/status.json` reader / ComfyUI HTTP polling reader を分岐する。
- killer registry は WolframScript PID killer / ComfyUI `/interrupt` + queue deletion killer を分岐する。
- AwaitKind は Phase 0 で明示的に扱う。MVP では既存 poll tick と互換にするため `AwaitKind -> "ExternalWolframScriptJob"` を流用してもよいが、その場合も backend field で ComfyUI を分岐する。将来は poll filter を external backend 横断に一般化し、名前と実体のずれを解消する。
- ComfyUI backend 未登録時、既存 WolframScript external dispatch は完全に同一挙動を保つ。backend registry 化は純加法であり、`ClaudeWireExternalRunner` の既存 WolframScript 結線を default として温存する。
- ComfyUI launcher は子プロセスを起動せず、`/prompt` POST の `prompt_id` を `PromptId` として保存し、`PID -> None` を許容する。
- ComfyUI retry は WolframScript の checkpoint resume ではなく、新 prompt submit として扱う。自動 retry は既定 off とし、明示 retry では `ParentJobId` / `ParentPromptId` を記録する。
- ComfyUI status reader は完了時に `/view` 取得と `SourceVaultComfyUIDepositOutputs` を行い、`SourceVaultRef` / `ArtifactUri` を completion payload に返す。大きな動画の取得・deposit は shared polling tick を長時間塞がないよう bounded にし、必要なら別 worker へ offload する。
- ComfyUI killer は timeout / cancel 時に対象 prompt の状態を確認してから動く。対象 prompt が pending なら `/queue` delete のみ、対象 prompt が現在 running であることを `/queue` で確認できた場合だけ `/interrupt` を呼ぶ。既に history 入り、または対象同一性が確認できない場合は他ジョブ巻き込みを避けて `/interrupt` しない。killer 未結線のまま timeout/cancel してはならない。killer 未結線を検知した場合は diagnostics に loud に記録し、可能なら best-effort queue delete だけを試みる。

ComfyUI status reader の状態機械:

- `/queue` に `PromptId` が pending または running として存在する場合は `Running`。
- `/queue` から消え、`/history/{prompt_id}` に outputs が存在する場合は `Completed`。
- `/history/{prompt_id}` に error status または `node_errors` が存在する場合は `Failed`。
- 一度 queue/history で観測した `PromptId` が、その後 `/queue` にも `/history` にも存在しない場合は `Lost` / terminal failure。
- `/queue` や `/history` の HTTP timeout、接続失敗、ComfyUI 一時停止など transient な poll 失敗は `Running` として扱う。ComfyUI が明示した node error、または観測済み prompt の queue/history 双方からの消失だけを terminal failure にする。

ComfyUI polling はジョブごとに毎回 HTTP しない。backend は tick ごとに `/queue` を原則 1 回だけ取得し、全 in-flight prompt の pending/running を判定する。queue から消えた prompt だけ `/history/{prompt_id}` を確認し、その結果を tick 内 cache として各 awaiting entry に配る。`SourceVaultComfyUIQueue` / status reader はこの prefetch cache を優先し、main kernel 上で N ジョブぶんの `/queue` + `/history` を直列連打しない。

backpressure:

- ComfyUI backend は in-flight submit 上限を持つ。上限を超える media request は SourceVault 側の pending queue に置くか、slide workflow 側でまだ External transition を発火しない。
- 既定上限は小さく始める。単一 GPU では running 1 + pending 少数で十分であり、無制限 submit は避ける。
- 複数媒体を生成する slide workflow では、可能なら 1 つの slide workflow 内に複数 External(ComfyUI) transition を持たせ、standalone 1-job-1-net を大量生成する運用は避ける。

非ブロック経路:

1. workflow load
2. vars 置換
3. validation
4. `/prompt` POST
5. `PromptId` / `JobId` を保存して即 return
6. poll tick が `/history/{prompt_id}` / `/queue` で完了確認
7. `/view` で画像・動画 bytes を取得
8. `SourceVaultMCPDeposit` / immutable snapshot 系へ deposit
9. completion hook が notebook cell / placeholder を反映

`SourceVaultComfyUIRunWorkflow` は高水準 convenience 関数として残すが、FrontEnd を持たない wolframscript / subkernel での単独デバッグ用に限定する。main kernel / notebook / ClaudeOrchestrator 経路の既定にしてはならない。

submit 時返り値:

```wolfram
<|
  "Status" -> "Queued" | "Awaiting" | "Error",
  "Provider" -> "comfyui",
  "JobId" -> "sv-comfy-...",
  "PromptId" -> "...",
  "WorkflowName" -> "...",
  "Awaiting" -> True,
  "Diagnostics" -> <|...|>
|>
```

完了時返り値 (completion hook / job result read API が受け取る payload):

```wolfram
<|
  "Status" -> "OK" | "Error" | "Timeout",
  "Provider" -> "comfyui",
  "JobId" -> "sv-comfy-...",
  "PromptId" -> "...",
  "WorkflowName" -> "...",
  "Artifacts" -> {
    <|
      "URI" -> "sv://artifact/...",
      "Kind" -> "Image",
      "File" -> "...",
      "MediaType" -> "image/png",
      "Width" -> 1024,
      "Height" -> 768,
      "Prompt" -> "...",
      "Seed" -> 123,
      "WorkflowHash" -> "...",
      "Provider" -> "comfyui"
    |>
  },
  "History" -> <|...|>,
  "Diagnostics" -> <|...|>
|>
```

`SourceVaultComfyUIDepositOutputs[jobOrHistory, opts]` は ComfyUI history から出力ファイルを列挙し、`/view` で bytes を取得し、`SourceVaultMCPDeposit` へ渡して artifact URI を返す。deposit gate / quota で失敗した場合は生成 job 自体を成功扱いにしたうえで、`"Status" -> "Error", "Reason" -> "DepositDenied" | "DepositQuotaExceeded"` を completion diagnostics に残し、notebook には再 deposit 可能な placeholder を入れる。

### 4.6 汎用 media generation API

`SourceVault_comfyui.wl` は、将来 SourceVault 本体に入る media provider registry と同型の関数を持つ。Phase 3 で core 公開 API として追加する場合は、既存の `SourceVaultRegisterSummaryProvider` と同じ registry pattern (`$SourceVaultMediaProviders[name] = fn`) に揃える。

```wolfram
SourceVaultRegisterMediaProvider[name_String, fn_]
SourceVaultMediaProviders[]
SourceVaultGenerateMedia[spec_Association, opts]
SourceVaultComfyUIBuildJobSpec[spec_Association, opts]
SourceVaultComfyUIGenerate[spec_Association, opts]
```

ただし MVP では本体に registry が無いため、`SourceVault_comfyui.wl` 内で局所 registry を提供し、既存の `SourceVault` に同名関数が存在する場合だけそれに登録する。これは暫定互換であり、Phase 3 は adapter 実装ではなく core API 追加を含む。

`SourceVaultComfyUIBuildJobSpec[spec, opts]` は純関数的 helper で、workflow 選択、変数解決、seed 確定、privacy 計算、ComfyUI API workflow rendering、External executor jobSpec 構築までを行う。HTTP submit / await / deposit は行わない。

`SourceVaultComfyUIGenerate[spec, opts]` は provider 専用 entry point で、明示 mode により返り値を固定する。

- `"Mode" -> "BuildJobSpec"`: `SourceVaultComfyUIBuildJobSpec` と同じ返り値。in-workflow の External(ComfyUI) transition backend はこの mode だけを使う。
- `"Mode" -> "Async"`: workflow 文脈の外でだけ、内部で 1 遷移 WorkflowNet を生成して lifecycle を workflow engine に所有させる。これは `ClaudeSubmitExternalHeldExprJob` と同じ発想である。
- `"Mode" -> "DebugSync"`: wolframscript / subkernel 用の同期 convenience。FrontEnd workflow では使わない。

in-workflow では `SourceVaultComfyUIBuildJobSpec` / `SourceVaultComfyUIGenerate[..., "Mode" -> "BuildJobSpec"]` を jobSpec 構築 helper として使い、submit と await は、その slide workflow 内の External(ComfyUI) transition executor が担う。PureFunction transition 本体から async submit を行わない。

async 実行の前提として `ClaudeActivateExternalExecutor` 相当が live で、shared polling tick が登録済みであることを要求する。

汎用 request spec:

```wolfram
<|
  "Task" -> "Image",
  "Prompt" -> "diagrammatic illustration of reversible cellular automata",
  "NegativePrompt" -> "text, watermark",
  "Style" -> "clean educational slide illustration",
  "AspectRatio" -> "16:9",
  "Width" -> 1344,
  "Height" -> 768,
  "Count" -> 1,
  "Seed" -> Automatic,
  "Inputs" -> {
    <|"Kind" -> "Image", "File" -> "...", "Role" -> "ControlNet"|>
  },
  "Output" -> <|
    "Purpose" -> "SlideAsset",
    "Notebook" -> "...",
    "SlideId" -> "slide-03"
  |>,
  "Provider" -> "comfyui",
  "ProviderOptions" -> <|
    "Workflow" -> "slide-illustration-sdxl",
    "LoRA" -> {...},
    "Sampler" -> "dpmpp_2m_sde"
  |>
|>
```

ComfyUI provider はこの spec を workflow vars に落とす。変換できない場合は `"Reason" -> "NoWorkflowForSpec"` を返す。
`"Count" -> n` は MVP では batch node ではなく n 回 submit と定義する。`"Seed" -> Automatic` は ComfyUI 内部に任せず、SourceVault 側で整数 seed を確定して workflow に inject し、その確定値を artifact provenance に保存する。

## 5. ClaudeOrchestrator 連携

### 5.1 Orchestrator から見る入口

MVP では ClaudeOrchestrator に `GenerateMedia` という LLM-visible tool を追加しない。現行 ClaudeOrchestrator には LLM へ tool spec を登録・露出する registry が無いためである。

in-workflow の本筋では、媒体生成を PureFunction transition の中の関数呼び出しとして実行しない。媒体生成ステップ自体を External(ComfyUI) transition として workflow に置く。

slide planner / workflow builder が作る transition 例:

```wolfram
<|
  "Executor" -> "External",
  "ExecutorOptions" -> <|
    "Backend" -> "ComfyUI",
    "MediaSpec" -> <|
      "Task" -> "Image",
      "Prompt" -> "...",
      "Purpose" -> "SlideAsset",
      "Provider" -> "comfyui",
      "ProviderOptions" -> <|...|>
    |>
  |>
|>
```

in-workflow dispatch:

```text
slide workflow External transition
  -> ExecutorOptions["Backend"] == "ComfyUI"
  -> SourceVaultGenerateMedia / SourceVaultComfyUIGenerate
       (workflow selection + vars + seed + jobSpec build only)
  -> External executor Backend -> "ComfyUI"
```

standalone では `SourceVaultGenerateMedia[..., "Execution" -> "Async"]` が内部で 1 遷移 WorkflowNet を作る。in-workflow から standalone async を呼んで子 WorkflowNet を作る運用は避ける。

LLM には「ComfyUI workflow JSON を直接書かせる」より、「登録済み workflow template 名と変数を指定させる」ほうを既定にする。workflow JSON 直接投入は power user / trusted local mode のみ。将来 LLM-visible tool が必要になった場合は、ClaudeRuntime の tool 定義口を確認した上で、`GenerateMedia` を ClaudeRuntime tool として登録する。新しい `ClaudeOrchestrator` tool registry の新設は v0.1 のスコープ外とする。

### 5.2 スライド notebook 生成での使い方

スライド生成中の流れ:

1. slide planner が、画像や動画が必要な箇所を `MediaRequest` として列挙する。
2. `MediaRequest` は本文・図の意図・アスペクト比・希望スタイル・privacy を持つ。
3. workflow builder が各 `MediaRequest` を External(ComfyUI) transition に変換する。
4. External executor backend が `SourceVaultGenerateMedia` / `SourceVaultComfyUIGenerate` を使って jobSpec を構築し、ComfyUI job を非ブロック投入する。
5. poll tick が完了を検出したら、成果物を `SourceVaultMCPDeposit` 経由で SourceVault artifact として保存する。
6. completion hook が notebook cell を更新する。画像なら main kernel が URI を local file path に解決して `Import[file]` 相当を挿入し、動画なら local path link / `Hyperlink` / option で `Video[file]` を入れる。
7. cell `TaggingRules` に `sv://artifact/...`、prompt、seed、workflow hash を残す。

Notebook cell metadata 例:

```wolfram
TaggingRules -> <|
  "SourceVault" -> <|
    "GeneratedMedia" -> <|
      "URI" -> "sv://artifact/...",
      "Provider" -> "comfyui",
      "Prompt" -> "...",
      "WorkflowName" -> "slide-illustration-sdxl",
      "WorkflowHash" -> "...",
      "Seed" -> 12345,
      "GeneratedAt" -> "2026-06-29T..."
    |>
  |>
|>
```

### 5.3 失敗時の挙動

生成失敗は notebook generation 全体を必ずしも失敗させない。

既定:

- 画像生成失敗: placeholder cell を入れ、`MediaRequest` と error を metadata に残す。
- 動画生成失敗: 画像 fallback を試す。不可なら link placeholder を入れる。
- ComfyUI offline: provider fallback があれば切替、なければ `"NeedsMediaGeneration"` marker を残す。
- private input があり、信頼済み workflow / approval 条件を満たさない場合: job を queue せず `"Reason" -> "ApprovalRequired"` または `"Reason" -> "UntrustedWorkflowForPrivateInput"` を返し、placeholder に request を残す。

返り値は Orchestrator が扱いやすいよう、必ず `Status` と `Reason` を持つ。

## 6. Artifact / provenance

### 6.1 保存方針

生成バイナリは独自の `PrivateVault/comfyui/artifacts/<id>.json` ストアに保存しない。既存の `SourceVaultMCPDeposit` を commit mode で呼び、binary は CommitBlob + DerivedArtifact として保存する。ComfyUI 固有メタデータは deposit spec の provenance / sidecar metadata に載せる。

正準 URI は既存の `sv://artifact/...` 体系に従う。`sv://artifact/comfyui/<id>` のような ComfyUI 独自サブ namespace は作らない。ComfyUI 由来であることは `"Provider" -> "comfyui"`、`"MediaKind"`、`"WorkflowHash"` などの field で表す。

自動生成 media の deposit は、ClaudeOrchestrator 由来の principal / purpose を明示した access spec で行う。MVP の既定は次のいずれかを Phase 0 で確定する。

1. ClaudeOrchestrator generated-media 用の事前 grant を発行し、completion hook はその grant で `SourceVaultMCPDeposit[..., "Mode" -> "commit"]` を行う。
2. completion hook では `Mode -> "plan"` までに留め、ユーザー操作または main kernel の明示 commit で保存を確定する。

commit gate / quota / approval で deny された場合、ComfyUI generation 自体は成功として扱い、deposit 失敗を別 error として記録する。notebook には「生成済みだが SourceVault deposit 未完了」の placeholder と再 deposit 用 marker を残す。shared polling tick 上で承認待ちや長時間 retry に入ってはならない。

### 6.2 Deposit metadata

```wolfram
<|
  "ArtifactUri" -> "sv://artifact/...",
  "ContentUri" -> "sv://hash/sha256/...",
  "Kind" -> "GeneratedMedia",
  "MediaKind" -> "Image" | "Video",
  "Provider" -> "comfyui",
  "ProviderVersion" -> "...",
  "BaseURL" -> "http://127.0.0.1:8188",
  "PromptId" -> "...",
  "JobId" -> "...",
  "WorkflowName" -> "...",
  "WorkflowHash" -> "...",
  "WorkflowSnapshotURI" -> "sv://snapshot/sha256/...",
  "Request" -> <|... generic request ...|>,
  "Outputs" -> {
    <|
      "ArtifactUri" -> "sv://artifact/...",
      "ContentUri" -> "sv://hash/sha256/...",
      "MediaType" -> "image/png",
      "ContentHash" -> "...",
      "Width" -> 1344,
      "Height" -> 768,
      "DurationSeconds" -> Missing[]
    |>
  },
  "Prompt" -> "...",
  "NegativePrompt" -> "...",
  "Seed" -> 12345,
  "PrivacyLevel" -> <derived by Max[input privacy, prompt privacy, default]>,
  "GeneratedBy" -> "ClaudeOrchestrator" | "manual",
  "CreatedAt" -> "...",
  "SourceRefs" -> {...},
  "ParentArtifactURI" -> "sv://artifact/..." | Missing[],
  "LicenseNotes" -> "...",
  "Diagnostics" -> <|...|>
|>
```

workflow API JSON、request、history は生成バイナリと同じ artifact に巨大 JSON として埋め込まず、必要に応じて `SourceVaultSaveImmutableSnapshot` で content-addressed snapshot として保存する。artifact metadata にはその `WorkflowSnapshotURI` / `HistorySnapshotURI` / `RequestSnapshotURI` を持たせる。
workflow snapshot は model 名、LoadImage node、環境依存 path を含みうるため、low-trust MCP projection へは出さない。必要な場合も release gate 後に redacted projection だけを返す。

### 6.3 job cache

`PrivateVault/comfyui/jobs` には実行中 job の状態、poll 用 prompt id、短い diagnostics、deposit 後の ArtifactUri を保存する。これは再開・診断用 cache であり、生成物の正本ではない。

動画生成で ComfyUI の出力が output directory にしかない場合も、history から参照できるファイルだけを `/view` で取得して deposit する。output directory scan は opt-in の診断 fallback とし、既定では使わない。

un-deposited bytes の不変条件:

- `SourceVaultMCPDeposit` を通れない生成 bytes を、正本 store にも gate 外 cache にも無期限保存しない。
- deposit deny / quota exceeded の場合、既定では `/view` 取得済み bytes は破棄し、placeholder には再 deposit ではなく再生成用の request / seed / workflow snapshot refs を残す。
- どうしても再 deposit 用 bytes を残す option を設ける場合は、短命 quarantine 領域に PrivacyLevel 1.0 として置き、TTL 削除を必須にする。この quarantine は MCP projection / summary provider へ出さない。
- shared polling tick 上で、deny された bytes を保存するための承認待ちや長時間 retry に入らない。

ComfyUI history は有限で、server 再起動、履歴上限、`/free` などで消える。`Lost` になった job は terminal failure とするが、output directory にファイルが残っている可能性はある。output directory scan は opt-in の救済であり、実行時は privacy gate と path redaction を再評価する。

### 6.4 再生成

同じ artifact record から再生成する関数:

```wolfram
SourceVaultComfyUIRegenerate[artifactOrURI_, opts]
```

既定では新 artifact record を作る。既存 artifact の上書きは禁止する。ただし同一 prompt / seed / workflow から同一 bytes が生成された場合、content blob は content-addressed store により dedup されうる。もっとも画像・動画生成は GPU / driver / library / custom node version により同一 seed でも byte 一致しないことが多い。`WorkflowHash` + seed は再生成レシピであり、byte-level deterministic identity ではない。したがって bytes 決定性を前提にしたロジックを組まない。比較用に `ParentArtifactURI` を record 関係として記録する。

## 7. Template 設計

### 7.1 template は code ではなく data

ComfyUI workflow template は `.json` と sidecar metadata で管理する。Mathematica code に巨大 workflow JSON を埋め込まない。

推奨:

```text
PrivateVault/comfyui/workflows/
  slide-illustration-sdxl/
    workflow-api.json
    meta.json
  slide-short-video/
    workflow-api.json
    meta.json
```

`SourceVault_comfyui.wl` 側には標準最小 template を数個だけ同梱してもよいが、実運用ではユーザーが ComfyUI frontend で調整した workflow を登録して使う。

### 7.2 変数置換

変数は JSONPath 風ではなく、ComfyUI API format の node id / input key で指定する。

```wolfram
"Prompt" -> <|"Node" -> "6", "Input" -> "text"|>
"Seed" -> <|"Node" -> "3", "Input" -> "seed", "Default" -> Automatic|>
```

複数 node へ同じ prompt を入れる場合:

```wolfram
"Prompt" -> {
  <|"Node" -> "6", "Input" -> "text"|>,
  <|"Node" -> "23", "Input" -> "text"|>
}
```

### 7.3 capability matching

`SourceVaultGenerateMedia` は request を満たす workflow を選ぶ。

matching keys:

- `Task`
- `MediaKind`
- `AspectRatio`
- `RequiresInputImage`
- `SupportsControlNet`
- `SupportsVideo`
- `MaxWidth` / `MaxHeight`
- `StyleTags`
- `RequiredModelsAvailable`

候補が複数ある場合、MVP では決定論的 matching と明示優先度で順位付けする。同点なら登録順を使う。成功率や最近の失敗率に基づく ranking は、実行統計の永続 schema を別途定義してから将来追加する。
`RequiredModelsAvailable` や node capability は、毎回 live probe せず TTL cache 済みの `/object_info` / model list を使う。main kernel 上で workflow 選択のたびに HTTP probe して小さなブロックを再導入しない。

`AspectRatio` と `Width` / `Height` が同時に指定された場合、明示された `Width` / `Height` を優先し、`AspectRatio` は validation warning の対象にする。`Width` / `Height` が無い場合だけ、workflow template の既定 size と `AspectRatio` から寸法を解決する。

## 8. セキュリティ・プライバシー

### 8.1 ComfyUI は local provider だが無条件安全ではない

ComfyUI server はローカルで動くが、custom node は任意の Python code になりうる。したがって `ProviderClass -> "Local"` であっても、SourceVault の private data を無制限に渡してよいとはしない。

特に次を禁止または deny 対象にする。

- private notebook / mail / PDF 本文をそのまま prompt に入れる。
- raw local path を workflow JSON に埋め込む。
- 信頼済み allowlist に無い custom node を含む workflow に機密入力を渡す。
- LLM が生成した任意 workflow JSON を検証なしに投入する。

custom node が外部 network へ送るかどうかは API format JSON からは保証できない。MVP は egress 判定ではなく、信頼済み登録 workflow と node type allowlist によるホワイトリスト方式を採る。

### 8.2 release policy

`MediaRequest` は `PrivacyLevel` を持つ。

```wolfram
"PrivacyLevel" -> 0.0   (* 公開可 *)
"PrivacyLevel" -> 0.85  (* SourceVault 既定に近い private 寄り *)
"PrivacyLevel" -> 1.0   (* ローカル限定 *)
```

PrivacyLevel は既存 SourceVault と同じ連続値 `[0.0, 1.0]` とする。生成物の PrivacyLevel は `Max[入力群の PrivacyLevel, prompt provenance の PrivacyLevel, 既定 PrivacyLevel]` で導出し、欠落は fail-closed で `1.0` とする。release 判定は既存の `SourceVaultMCPReleaseGate` / effective access level と整合させる。

MVP では ComfyUI を local sink と扱うが、workflow に外部 API node が含まれるかは完全判定できない。そのため private input image / private text を使い、かつ信頼済み workflow / allowlist 条件を満たさない場合は、承認待ちで suspend せず `<|"Status" -> "Error", "Reason" -> "ApprovalRequired"|>` または `"UntrustedWorkflowForPrivateInput"` で即 deny する。orchestrator 側に approve/reject/resume UX が実装された後に suspend/resume 方式へ拡張する。

### 8.3 path handling

MCP / LLM 応答には raw path を出さず、`sv://artifact/...` を正準参照にする。Notebook への挿入時のみ、main kernel が URI を local file path に解決する。

ComfyUI へ入力画像を渡す場合は `/upload/image` を使い、SourceVault 管理下の一時 projection から渡す。元ファイルの絶対パスを workflow に直接埋め込まない。

`/upload/image` は ComfyUI server の `input/` 側にファイルを残しうる。private 入力画像を渡す場合、ComfyUI server filesystem 自体を PrivacyLevel 1.0 の local sink とみなし、次を守る。

- upload filename はランダム化し、元ファイル名や source path を含めない。
- job 完了後、可能な範囲で uploaded input の削除を試みる。ComfyUI API で安全に削除できない環境では、残留することを diagnostics と artifact provenance に記録する。
- private input を許可する workflow は trusted workflow + allowlist node に限る。ComfyUI input dir に痕跡が残ることも deny/allow 判断の材料に含める。
- MCP / low-trust projection には uploaded input filename や workflow 内の input path を出さない。

## 9. Video 対応

ComfyUI の動画生成は custom node と workflow 依存が大きいため、MVP では API を固定しすぎない。

汎用 request:

```wolfram
<|
  "Task" -> "Video",
  "Prompt" -> "...",
  "DurationSeconds" -> 4,
  "FPS" -> 12,
  "Width" -> 1024,
  "Height" -> 576,
  "Provider" -> "comfyui",
  "ProviderOptions" -> <|"Workflow" -> "slide-short-video"|>
|>
```

ComfyUI adapter は workflow の出力 history を見て、`videos` / `gifs` / `images` / custom output field を順に探す。見つからない場合は output directory scan を option で許可するが、既定は history に出たファイルだけを保存する。

Notebook では動画ファイルへの `Hyperlink` を第一選択にする。Wolfram front end の video embed が安定する環境では `Video[file]` cell も option で使う。

## 10. MCP / SourceVault 横断検索との接続

生成 artifact は将来 `SourceVaultSummaries` / MCP search にも出せる。ただし GPU/HTTP/FrontEnd に触る `SourceVault_comfyui.wl` 本体を service kernel に常時 load しない。検索・MCP projection だけを担う `SourceVault_comfyui_projection.wl` を分離し、そこから summary provider を登録する。

provider row:

```wolfram
<|
  "Kind" -> "generated-media",
  "Id" -> "...",
  "URI" -> "sv://artifact/...",
  "Title" -> "...",
  "Summary" -> "Prompt: ...",
  "File" -> Missing["Redacted"],
  "Date" -> DateObject[...],
  "PrivacyLevel" -> ...,
  "Provider" -> "comfyui",
  "MediaKind" -> "Image"
|>
```

登録関数:

```wolfram
SourceVaultRegisterSummaryProvider["comfyui", SourceVaultComfyUISummaryRows]
```

projection 関数は FE/NBAccess 非依存かつ JSON-safe にする。low-trust MCP response へ raw file path、ByteArray、Image、Video、NotebookObject を返してはならない。MCP には URI、短い summary、media kind、低解像度 thumbnail artifact の URI など thumbnail-safe projection だけを返す。thumbnail は生成時に派生 artifact として保存しておく。

## 11. Error model

全公開関数は `$Failed` を返さず、原則 Association を返す。

共通 error:

```wolfram
<|"Status" -> "Error", "Reason" -> "Offline"|>
<|"Status" -> "Error", "Reason" -> "ValidationFailed", "NodeErrors" -> ...|>
<|"Status" -> "Error", "Reason" -> "Timeout"|>
<|"Status" -> "Error", "Reason" -> "NoWorkflowForSpec"|>
<|"Status" -> "Error", "Reason" -> "OutputNotFound"|>
<|"Status" -> "Error", "Reason" -> "ModelMissing", "MissingModels" -> {...}|>
<|"Status" -> "Error", "Reason" -> "ApprovalRequired"|>
<|"Status" -> "Error", "Reason" -> "ExternalExecutorInactive"|>
<|"Status" -> "Error", "Reason" -> "ExternalBackendDispatchUnavailable"|>
<|"Status" -> "Error", "Reason" -> "DepositDenied"|>
<|"Status" -> "Error", "Reason" -> "DepositQuotaExceeded"|>
```

ComfyUI の `/prompt` が `error` / `node_errors` を返した場合は、`Diagnostics` にそのまま保存する。ただし notebook や MCP に返す projection では必要最小限に短縮する。

## 12. 実装フェーズ

### Phase 0: 設計確定

- `GenerateMedia` は MVP では LLM-visible tool ではなく workflow transition から WL 直呼びとする。
- in-workflow の媒体生成は PureFunction 内の関数呼び出しではなく External(ComfyUI) transition として表現する。`SourceVaultGenerateMedia` / `SourceVaultComfyUIGenerate` は in-workflow では jobSpec 構築 helper に留め、standalone async だけが内部 1 遷移 WorkflowNet を作る。
- ComfyUI job は External executor backend (`Backend -> "ComfyUI"`) に寄せ、main kernel / FE をブロックしない。ただし現行 External executor は backend 別 dispatch を持たないため、ComfyUI と既存 WolframScript job が共存できる launcher / status reader / killer registry の設計を確定する。
- standalone async は内部で 1 遷移 WorkflowNet を生成し、`ClaudeActivateExternalExecutor` 相当が live であることを前提にする。
- ComfyUI status reader の状態機械を Completed / Failed / Lost / Running / Transient に分け、transient HTTP failure を terminal failure にしない。
- ComfyUI polling は tick 単位で `/queue` を集約取得し、queue から消えた prompt だけ `/history` を確認する。in-flight 上限と backpressure を持つ。
- artifact は独自 store ではなく `SourceVaultMCPDeposit` / immutable snapshot に寄せる。
- 自動生成 media の deposit commit に使う grant / principal / quota と、deposit deny 時の placeholder 挙動を確定する。
- private input upload の lifecycle と、deposit deny 時の un-deposited bytes 方針を確定する。
- 検証戦略を確定し、mock HTTP で検証できる層と live ComfyUI / FE が必要な層を分ける。
- MCP / summary provider は projection サブモジュールへ分離する。
- 承認 UX 未実装の間、private input の未承認ケースは suspend ではなく deny とする。

受け入れ条件:

- B-1/B-2/B-3 に相当する設計判断が仕様上閉じている。
- 実装者が「同期 wait」「独自 artifact URI namespace」「LLM tool registry 新設」を Phase 1 で始めないことが明確である。
- `Backend -> "ComfyUI"` が singleton hook を上書きせず、既存 WolframScript external job を壊さないことが明確である。
- AwaitKind を流用するか一般化するかを決め、ComfyUI backend 未登録時は既存 WolframScript external dispatch と完全に同一挙動である。
- timeout / cancel 時に ComfyUI killer (`/interrupt` + queue deletion) が呼ばれる契約がある。
- ComfyUI killer は対象 prompt が running であると確認した場合だけ `/interrupt` し、pending は queue delete のみで処理する。
- completion hook / status reader が大容量 `/view` 取得や deposit で shared polling tick を長時間塞がない方針がある。
- deposit offload は deposit ごとに新規 subkernel を起こさず、bounded な単一 worker または既存 async 機構を使う方針がある。

### Phase 0.5: External backend dispatch 前提実装

この phase は SourceVault_comfyui ではなく ClaudeRuntime / ClaudeOrchestrator 側の cross-package work item である。`ClaudeRuntime_externalrunner.wl` ないし `ClaudeOrchestrator_workflow.wl` に backend dispatch 層を純加法で追加し、ComfyUI backend を登録できる土台を作る。

受け入れ条件:

- ComfyUI backend 未登録時、既存 WolframScript external job は既存挙動と同一である。
- `ClaudeWireExternalRunner` の WolframScript launcher / killer / default status reader は default backend として温存される。
- 既存 WolframScript external dispatch / `ClaudeSubmitExternalHeldExprJob` 系の回帰テストが green である。
- backend registry は launcher / status reader / killer / AwaitKind policy を backend ごとに分岐できる。
- ComfyUI backend が未結線の場合、`SourceVaultComfyUISubmitExternal` は `<|"Status" -> "Error", "Reason" -> "ExternalBackendDispatchUnavailable"|>` を返し、singleton hook を直接上書きしない。

### Phase 1: thin ComfyUI client + non-blocking job

- `SourceVault_comfyui.wl` 作成
- 設定変数
- `SourceVaultComfyUIStatus`
- `SourceVaultComfyUIAPICall`
- `SourceVaultComfyUIQueuePrompt`
- `SourceVaultComfyUIPoll`
- `SourceVaultComfyUIFetchOutputs`
- `SourceVaultComfyUIBuildJobSpec`
- `SourceVaultComfyUISubmitExternal`
- `SourceVaultComfyUIDepositOutputs`
- debug 専用 `SourceVaultComfyUIRunWorkflow`

受け入れ条件:

- 既存の API format workflow JSON を投入し、main kernel / FE をブロックせずに画像を `SourceVaultMCPDeposit` 経由で保存できる。
- ComfyUI offline でも静かに `Status -> "Offline"` を返す。
- 対象 ComfyUI バージョンと `/object_info` の実機検証結果を diagnostics に残せる。
- transient な `/queue` / `/history` 失敗で terminal failure にせず、次 tick へ待機継続できる。
- 複数 in-flight job でも tick あたり `/queue` は集約取得され、in-flight 上限を超えた submit は backpressure される。

### Phase 2: workflow registry / template

- `SourceVaultComfyUIRegisterWorkflow`
- `SourceVaultComfyUIWorkflows`
- `SourceVaultComfyUIRenderWorkflow`
- 変数置換
- model availability check
- allowlist validation
- canonical workflow hash

受け入れ条件:

- `Prompt` / `Seed` / `Width` / `Height` を差し替えて同じ workflow を再利用できる。
- model 欠落時に generation 前に警告できる。
- workflow hash は再帰的キーソートされた canonical JSON から決定論的に計算される。

### Phase 3: generic media provider

- `SourceVaultGenerateMedia`
- `SourceVaultRegisterMediaProvider`
- `SourceVaultComfyUIGenerate`
- notebook insertion helper

受け入れ条件:

- ClaudeOrchestrator workflow transition は ComfyUI 固有 workflow JSON を扱わずに slide asset を生成できる。
- 生成 artifact の URI が notebook cell metadata に残る。
- `SourceVaultRegisterMediaProvider` / `SourceVaultGenerateMedia` は `SourceVaultRegisterSummaryProvider` と同じ registry pattern に揃う。

### Phase 4: video / img2img / approval

- `/upload/image`
- video output detection
- input image projection
- continuous PrivacyLevel 継承
- private input deny / future approval gate
- placeholder fallback
- trusted workflow / node allowlist

受け入れ条件:

- 画像入力付き workflow を raw path 直埋めなしで実行できる。
- short video artifact を notebook から link できる。

### Phase 5: MCP / SourceVaultSummaries

- `SourceVaultComfyUISummaryRows`
- `SourceVault_comfyui_projection.wl`
- MCP projection
- regenerated artifact relation
- search / reuse UI

受け入れ条件:

- 生成済み素材を `SourceVaultSummaries[..., "Providers" -> {"comfyui"}]` 相当で検索できる。
- service kernel では JSON-safe projection だけを返し、raw path / bytes / Image / Video を返さない。

## 13. 最小サンプル API

### 13.1 直接 workflow 実行 (debug / non-FE)

```wolfram
Block[{$CharacterEncoding = "UTF-8"},
  Get[FileNameJoin[{$packageDirectory, "SourceVault_comfyui.wl"}]]
];

SourceVaultComfyUIRunWorkflow[
  "slide-illustration-sdxl",
  <|
    "Prompt" -> "clean educational illustration of a reversible cellular automaton",
    "NegativePrompt" -> "watermark, text, blurry",
    "Width" -> 1344,
    "Height" -> 768,
    "Seed" -> 12345
  |>
]
```

この synchronous convenience は wolframscript / subkernel でのデバッグ用であり、FrontEnd 上の notebook workflow では既定にしない。

### 13.2 汎用 request

```wolfram
SourceVaultGenerateMedia[
  <|
    "Task" -> "Image",
    "Prompt" -> "minimal diagram-like image for a lecture slide about reversible computation",
    "Purpose" -> "SlideAsset",
    "AspectRatio" -> "16:9",
    "Execution" -> "Async",
    "Provider" -> "comfyui",
    "ProviderOptions" -> <|"Workflow" -> "slide-illustration-sdxl"|>
  |>
]
```

standalone async の場合、この呼び出しは内部で 1 遷移 WorkflowNet を生成して external awaiting 状態を workflow engine に登録する。返り値は submit 時点では `Artifacts` を含まず、`<|"Status" -> "Queued", "JobId" -> ..., "PromptId" -> ...|>` 形になる。`ClaudeActivateExternalExecutor` 相当が live でない場合は queue せず `<|"Status" -> "Error", "Reason" -> "ExternalExecutorInactive"|>` を返す。

### 13.3 スライド notebook への挿入

```wolfram
res = SourceVaultGenerateMedia[request];

If[MemberQ[{"Queued", "Awaiting"}, Lookup[res, "Status"]],
  SourceVaultInsertMediaPlaceholderCell[
    EvaluationNotebook[],
    request,
    Join[res, <|"PlaceholderKind" -> "GeneratedMediaPending"|>]
  ],
  SourceVaultInsertMediaPlaceholderCell[EvaluationNotebook[], request, res]
]
```

実際の画像・動画 cell への差し替えは completion hook が行う。呼び出し直後に `res["Artifacts"]` を同期的に読む形は、debug 専用 `SourceVaultComfyUIRunWorkflow` の結果に限る。

## 14. 未決事項

1. ComfyUI server 起動も SourceVault が管理するか
   - MVP では管理しない。ユーザーが ComfyUI を起動しておく。
   - 将来 `SourceVault_servicemanager.wl` 経由で launch profile を持てる。

2. bundled workflow template を同梱するか
   - 最小限の SDXL image workflow は便利だが、model 名が環境依存。
   - MVP では template import / registry を先に作り、同梱は任意。

3. video node の標準化
   - custom node 差が大きいため、workflow metadata の `Outputs` 宣言を信頼する方式を優先。

4. cloud Comfy API との統合
   - provider `"comfyui-cloud"` として別 backend にする。
   - privacy policy は cloud LLM と同等に扱う。

5. 生成物のライセンス/出典表示
   - artifact record に `LicenseNotes` と `ModelNotes` を残す。
   - スライド末尾に generated media credits を自動生成する helper を検討。

## 15. 実装上の注意

- HTTP JSON は Eagle adapter と同様に UTF-8 byte 安全な helper を使う。
- `URLRead` の timeout を必ず設定する。単一 HTTP timeout (`$SourceVaultComfyUIHTTPTimeout`) と job 全体 timeout (`$SourceVaultComfyUIJobTimeout`) は別設定にする。
- 進捗監視は polling 既定とする。WebSocket は将来オプションであり、MVP の必須経路にしない。
- External executor の singleton hook を ComfyUI 用に直接上書きしない。backend registry / dispatch 層を通し、WolframScript external job と共存させる。
- timeout / cancellation は ComfyUI backend killer に接続する。対象 prompt が pending なら queue delete、対象 prompt が running であると確認できた場合だけ `/interrupt` を呼ぶ。
- 大きな `/view` 取得や deposit を offload する場合でも、deposit ごとに新規 subkernel を起動しない。bounded な単一 worker、既存 async 機構、または shared queue を使う。
- `/upload/image` は multipart/form-data 専用実装にする。
- ComfyUI の output directory を直接 scan する fallback は opt-in にする。
- workflow hash は recursive key sort された canonical JSON 文字列から計算する。Association -> RawJSON のキー順には依存しない。
- prompt / workflow snapshot URI / seed / model / ComfyUI version を artifact provenance に必ず残す。
- `Seed -> Automatic` は SourceVault 側で整数に確定してから workflow に inject する。
- 既存 artifact record の上書きは禁止し、再生成は新 artifact record として append-only にする。同一 bytes の blob dedup は許可する。
- 生成バイナリや private provenance を `$packageDirectory` 配下に置かない。
- SourceVault / ClaudeOrchestrator 本体は ComfyUI package をロードしていなくても動くこと。

## 16. 推奨される最初の実装単位

最初に作るべき公開関数はこの 9 個でよい。

```wolfram
SourceVaultComfyUIStatus
SourceVaultComfyUIAPICall
SourceVaultComfyUIRegisterWorkflow
SourceVaultComfyUIWorkflows
SourceVaultComfyUIRenderWorkflow
SourceVaultComfyUIBuildJobSpec
SourceVaultComfyUISubmitExternal
SourceVaultComfyUIDepositOutputs
SourceVaultComfyUIGenerate
```

この時点で、ClaudeOrchestrator の External(ComfyUI) backend からは `SourceVaultComfyUIGenerate` を暫定的な jobSpec 構築 helper として使える。Phase 3 で `SourceVaultGenerateMedia` が整ったら、backend 側の helper を generic API に切り替える。

## 17. 検証戦略

### 17.1 wolframscript + mock HTTP で検証する層

以下は FrontEnd / live ComfyUI なしで検証できるよう、HTTP layer を注入可能にする。

- status reader 状態機械: Running / Completed / Failed / Lost / Transient の table-driven test。
- transient HTTP failure が terminal failure にならないこと。
- canonical workflow hash の決定論。
- `SourceVaultComfyUIValidateWorkflow`。
- `SourceVaultComfyUIBuildJobSpec`。
- PrivacyLevel の Max 継承と fail-closed。
- capability matching と TTL cache 利用。
- submit 時返り値 / 完了時 payload 形。
- AspectRatio と Width/Height の解決規則。
- ComfyUI killer の pending / running / history 済み分岐。ただし実 `/interrupt` 呼び出しは mock。

Phase 1 の実装では、status reader と API client を密結合させず、テスト時に mock `SourceVaultComfyUIAPICall` 相当を注入できるようにする。

### 17.2 live ComfyUI + wolframscript で検証する層

FrontEnd なしで、debug sync 経路を最小 1 本通す。

- `SourceVaultComfyUIRunWorkflow` による `/prompt` -> `/queue` / `/history` -> `/view`。
- 対象 ComfyUI バージョンと `/object_info` の実機記録。
- `/upload/image` の multipart 実装。
- generated bytes の `SourceVaultMCPDeposit` または plan mode までの疎通。
- ComfyUI history pruning / Lost 時の diagnostics。

### 17.3 FE + live ComfyUI で検証する層

Notebook / shared polling task / completion hook を含む経路はユーザーの NB 検証を必要とする。

- External(ComfyUI) transition が Awaiting になり、FE をブロックしないこと。
- shared polling tick が completion を拾うこと。
- completion hook が placeholder cell を画像・動画 cell / link に差し替えること。
- 複数 in-flight job で `/queue` 集約 polling と backpressure が効くこと。
- cancel / timeout が ComfyUI killer に届き、他 prompt を巻き込まないこと。

### 17.4 回帰テスト

Phase 0.5 の backend dispatch 実装では、ComfyUI backend を登録しない状態で既存 WolframScript external dispatch が変わらないことを必ず確認する。これは SourceVault_comfyui のテストではなく ClaudeRuntime / ClaudeOrchestrator 側の回帰テストとして扱う。
