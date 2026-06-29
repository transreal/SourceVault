(* ::Package:: *)

(* ============================================================
   SourceVault_comfyui.wl -- ComfyUI local image/video generation adapter
     (thin HTTP client / workflow registry / non-blocking job / artifact deposit)

   This file is encoded in UTF-8.
   Load order: SourceVault.wl -> (SourceVault_core.wl ...) -> SourceVault_comfyui.wl
   Load via:   Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_comfyui.wl"]]

   仕様: ドキュメント/sourcevault_comfyui_generation_provider_spec_v0_1.md

   == このファイルが実装する範囲 (Phase 1 + a) ==
     - 設定変数と UTF-8 byte 安全 HTTP helper (Eagle adapter 準拠)。
     - 接続診断 (Status / SystemStats / ObjectInfo / Models / Queue / Interrupt) と TTL online cache。
     - 低レベル HTTP API (APICall / View / UploadImage[multipart])。
     - workflow registry (Register / Workflows / Workflow / Validate / Render)。
       template は code ではなく data: PrivateVault/comfyui/workflows/<name>/{workflow-api.json, meta.json}。
     - canonical workflow hash (recursive key sort)。
     - status reader 状態機械 (Running / Completed / Failed / Lost) を純関数として分離 ... iSVCFClassifyState。
       transient HTTP 失敗は呼び出し側 (Poll) が Running 扱いにする (terminal failure にしない)。
     - QueuePrompt / Poll / JobStatus / FetchOutputs / BuildJobSpec / DepositOutputs。
     - SourceVaultComfyUIRunWorkflow: 同期 debug 経路 (非 FE / wolframscript / subkernel 用)。
     - SourceVaultComfyUIGenerate: Mode (BuildJobSpec / DebugSync / Async)。
       in-workflow は BuildJobSpec helper として使い、submit/await は External(ComfyUI) transition が担う。

   == このファイルがまだ実装しない範囲 (依存先が未整備) ==
     - SourceVaultComfyUISubmitExternal の非ブロック投入: ClaudeOrchestrator External executor の
       backend dispatch (Phase 0.5) が前提。未整備のため
       <|"Status"->"Error","Reason"->"ExternalBackendDispatchUnavailable"|> を返すガード stub。
     - SourceVault_comfyui_projection.wl (MCP / summary provider) は別ファイル (Phase 5)。

   == 設計上の不変条件 ==
     - 公開関数は $Failed を返さず必ず Association を返し、必ず "Status" を持つ。
     - 生成バイナリの正本は SourceVaultMCPDeposit / immutable snapshot (sv://artifact/...)。
       PrivateVault/comfyui は registry / job 状態 / log の置き場で正本ストアではない。
     - 生成バイナリや private provenance を $packageDirectory 配下に置かない。
     - HTTP 層は $SourceVaultComfyUIHTTPHook で差し替え可能 (テスト時 mock、本番 URLRead)。

   == HTTP hook 契約 (テスト用) ==
     $SourceVaultComfyUIHTTPHook = Function[req,
       (* req: <|"Method","Endpoint","Query","Body"|> *)
       <|"StatusCode" -> 200, "Body" -> jsonString | ByteArray[...]|>];
   ============================================================ *)

BeginPackage["SourceVault`"];

(* ---- 設定 ---- *)
$SourceVaultComfyUIBaseURL::usage = "$SourceVaultComfyUIBaseURL は ComfyUI server のベース URL (既定 http://127.0.0.1:8188)。";
$SourceVaultComfyUIHTTPTimeout::usage = "$SourceVaultComfyUIHTTPTimeout は /queue / /history / /view など単一 HTTP 呼び出しの短い timeout 秒 (既定 30)。job 全体 timeout とは別。";
$SourceVaultComfyUIJobTimeout::usage = "$SourceVaultComfyUIJobTimeout は ComfyUI job 全体の timeout 秒 (既定 600)。External executor jobSpec の Timeout に渡す値。";
$SourceVaultComfyUIStoreRoot::usage = "$SourceVaultComfyUIStoreRoot は ComfyUI 連携データ (workflow registry / job cache / log) の保存先。既定 PrivateVault/comfyui、未初期化なら $TemporaryDirectory/sourcevault-comfyui。生成バイナリの正本ストアではない。";
$SourceVaultComfyUIDefaultWorkflow::usage = "$SourceVaultComfyUIDefaultWorkflow は workflow 未指定時に使う登録済み workflow 名 (既定 None)。";
$SourceVaultComfyUIDefaultProviderName::usage = "$SourceVaultComfyUIDefaultProviderName は provider 識別名 (既定 \"comfyui\")。";
$SourceVaultComfyUIOfflineRecheckSeconds::usage = "$SourceVaultComfyUIOfflineRecheckSeconds は online/offline 判定の TTL cache 秒 (既定 30)。到達不能 server への繰り返し接続待ちを避ける。";
$SourceVaultComfyUIHTTPHook::usage = "$SourceVaultComfyUIHTTPHook は HTTP 層の差し替えフック (既定 None)。テスト時に mock を注入する。Function[<|\"Method\",\"Endpoint\",\"Query\",\"Body\"|>] -> <|\"StatusCode\",\"Body\"(string|ByteArray)|>。";
$SourceVaultComfyUIDepositMode::usage = "$SourceVaultComfyUIDepositMode は生成物を SourceVaultMCPDeposit へ渡す mode (\"commit\"|\"plan\"、既定 \"commit\")。\"plan\" は vault へ書かず予定 policy のみ算定 (生成物はローカル参照に留まる)。\"commit\" は DepositArtifact 権限 (grant / AccessProfile) を要する。";
$SourceVaultComfyUIDepositGrant::usage = "$SourceVaultComfyUIDepositGrant は commit deposit に使う AccessGrant (既定 None)。SourceVaultMCPMintAccessGrant / sourcevault_request_access (action=DepositArtifact) で得た grant を設定すると completion hook の deposit がそれで commit する。";

(* ---- 接続・診断 ---- *)
SourceVaultComfyUIStatus::usage = "SourceVaultComfyUIStatus[opts] は ComfyUI server の状態を返す。到達不能なら message を出さず <|\"Status\"->\"Offline\"|>。結果は TTL cache される。";
SourceVaultComfyUIAPIAvailable::usage = "SourceVaultComfyUIAPIAvailable[opts] は ComfyUI server へ到達可能かを True/False で返す (TTL cache)。";
SourceVaultComfyUISystemStats::usage = "SourceVaultComfyUISystemStats[opts] は /system_stats を返す。";
SourceVaultComfyUIObjectInfo::usage = "SourceVaultComfyUIObjectInfo[opts] は /object_info (利用可能 node 定義) を返す。";
SourceVaultComfyUIModels::usage = "SourceVaultComfyUIModels[folder:All, opts] は /models または /models/{folder} を返す。";
SourceVaultComfyUIQueue::usage = "SourceVaultComfyUIQueue[opts] は /queue (running / pending) を返す。";
SourceVaultComfyUIInterrupt::usage = "SourceVaultComfyUIInterrupt[opts] は /interrupt を呼ぶ低レベル debug primitive。ComfyUI の /interrupt は実行中ジョブを止める global 操作で prompt スコープではない。複数ジョブ運用では prompt スコープの killer 経路を使うこと。";

(* ---- 低レベル HTTP ---- *)
SourceVaultComfyUIAPICall::usage = "SourceVaultComfyUIAPICall[endpoint, params:None, opts] は JSON GET/POST を扱う。params があれば POST(JSON)、無ければ GET。binary download は SourceVaultComfyUIView を使う。";
SourceVaultComfyUIView::usage = "SourceVaultComfyUIView[file_Association, opts] は /view で出力ファイル bytes を取得する。file は <|\"filename\",\"subfolder\",\"type\"|>。返り <|\"Status\",\"Bytes\"->ByteArray,\"ContentType\",\"File\"|>。";
SourceVaultComfyUIUploadImage::usage = "SourceVaultComfyUIUploadImage[pathOrImage, opts] は /upload/image に multipart/form-data でアップロードする。元ファイル名や source path は出さず random 名を使う。返り <|\"Status\",\"Name\",\"Subfolder\",\"Type\"|>。";

(* ---- Workflow 登録 ---- *)
SourceVaultComfyUIRegisterWorkflow::usage = "SourceVaultComfyUIRegisterWorkflow[name, workflow, opts] は API format workflow JSON を名前付きで登録する (PrivateVault/comfyui/workflows/<name>)。opts: \"Kind\",\"Variables\",\"Outputs\",\"RequiredModels\",\"Tags\",\"TrustedForPrivateInput\",\"AllowedNodeTypes\"。通常保存形式 JSON は \"Reason\"->\"NotAPIFormat\" で拒否。";
SourceVaultComfyUIWorkflows::usage = "SourceVaultComfyUIWorkflows[opts] は登録済み workflow 名と meta の一覧を返す。";
SourceVaultComfyUIWorkflow::usage = "SourceVaultComfyUIWorkflow[name, opts] は登録済み workflow record (Workflow JSON + meta) を返す。";
SourceVaultComfyUIValidateWorkflow::usage = "SourceVaultComfyUIValidateWorkflow[workflowOrRecord, opts] は API format 整形式・Variables/Outputs の node 実在を検査する。opts: \"Variables\",\"Outputs\",\"ObjectInfo\"(RequiredModels 確認用)。";
SourceVaultComfyUIRenderWorkflow::usage = "SourceVaultComfyUIRenderWorkflow[workflowOrName, vars_Association, opts] は Variables マッピングに従って vars を API JSON の node/input に inject した workflow を返す。";

(* ---- Job 実行 ---- *)
SourceVaultComfyUIQueuePrompt::usage = "SourceVaultComfyUIQueuePrompt[workflow, opts] は API format workflow を /prompt に POST し prompt_id を返す。";
SourceVaultComfyUIPoll::usage = "SourceVaultComfyUIPoll[promptId, opts] は /queue と /history を確認して job 状態 (Running/Completed/Failed/Lost) を返す。transient HTTP 失敗は Running 扱い。opts: \"Seen\"(観測済みフラグ),\"Queue\",\"History\"(注入用 snapshot)。";
SourceVaultComfyUIJobStatus::usage = "SourceVaultComfyUIJobStatus[promptId, opts] は SourceVaultComfyUIPoll の薄いラッパ。";
SourceVaultComfyUIFetchOutputs::usage = "SourceVaultComfyUIFetchOutputs[promptIdOrHistory, opts] は history から出力ファイル一覧 (filename/subfolder/type/kind) を取り出す。";
SourceVaultComfyUIBuildJobSpec::usage = "SourceVaultComfyUIBuildJobSpec[spec_Association, opts] は純関数 helper。workflow 選択・変数解決・seed 確定・privacy 計算・API workflow rendering・External executor jobSpec 構築までを行い HTTP は叩かない。";
SourceVaultComfyUISubmitExternal::usage = "SourceVaultComfyUISubmitExternal[workflowOrName, vars, opts] は ComfyUI job を ClaudeOrchestrator External executor backend (Backend->\"ComfyUI\") として 1 遷移 WorkflowNet で非ブロック投入する。返り <|\"Status\"->\"Submitted\",\"WorkflowId\",\"PromptId\"|>。ClaudeOrchestrator`Workflow` engine が未ロード/未 activate なら \"ExternalExecutorInactive\" / backend dispatch 未整備なら \"ExternalBackendDispatchUnavailable\" を返す。完了時の deposit/反映は status reader と completion hook が担う。";
SourceVaultComfyUIRegisterBackend::usage = "SourceVaultComfyUIRegisterBackend[] は ComfyUI 用の launcher/status reader/killer を ClaudeOrchestrator`Workflow`ClaudeRegisterExternalBackend へ登録する (冪等)。orchestrator backend dispatch が未整備なら \"ExternalBackendDispatchUnavailable\"。";
SourceVaultComfyUIActivate::usage = "SourceVaultComfyUIActivate[opts] は ComfyUI を非ブロック生成 provider として live 稼働させる (冪等): (1) backend 登録、(2) auto-commit 用 DepositArtifact grant を発行し $SourceVaultComfyUIDepositGrant に設定、(3) ClaudeRuntime`ClaudeActivateExternalExecutor で poll tick を共有タスクへ登録。opts: \"RenewGrant\"->False (True で grant 再発行)、\"GrantTTLSeconds\"->86400、\"GrantMaxAccessLevel\"->0.49 (この値以上の effPL deposit は approval gate で保護=auto-commit しない)。1 カーネルセッションに 1 回呼ぶ。";
SourceVaultComfyUIDepositOutputs::usage = "SourceVaultComfyUIDepositOutputs[promptIdOrHistory, opts] は出力ファイルを /view で取得し SourceVaultMCPDeposit へ渡して artifact URI を返す。deposit gate/quota 失敗時は job を成功扱いにしつつ \"DepositDenied\"/\"DepositQuotaExceeded\" を残す。";
SourceVaultComfyUIRunWorkflow::usage = "SourceVaultComfyUIRunWorkflow[workflowOrName, vars:<||>, opts] は同期 debug 経路 (submit -> poll loop -> fetch -> deposit)。FrontEnd を持たない wolframscript / subkernel 用であり、main kernel / notebook 既定にしてはならない。";
SourceVaultComfyUIGenerate::usage = "SourceVaultComfyUIGenerate[spec_Association, opts] は provider 専用 entry point。opts \"Mode\"->\"BuildJobSpec\"(既定, in-workflow helper)|\"DebugSync\"(非 FE)|\"Async\"(External 投入, 現状 stub)。";

Begin["`Private`"];

(* ============================================================
   設定・パス
   ============================================================ *)

If[! ValueQ[$SourceVaultComfyUIBaseURL], $SourceVaultComfyUIBaseURL = "http://127.0.0.1:8188"];
If[! ValueQ[$SourceVaultComfyUIHTTPTimeout], $SourceVaultComfyUIHTTPTimeout = 30];
If[! ValueQ[$SourceVaultComfyUIJobTimeout], $SourceVaultComfyUIJobTimeout = 600];
If[! ValueQ[$SourceVaultComfyUIDefaultWorkflow], $SourceVaultComfyUIDefaultWorkflow = None];
If[! ValueQ[$SourceVaultComfyUIDefaultProviderName], $SourceVaultComfyUIDefaultProviderName = "comfyui"];
If[! ValueQ[$SourceVaultComfyUIOfflineRecheckSeconds], $SourceVaultComfyUIOfflineRecheckSeconds = 30];
If[! ValueQ[$SourceVaultComfyUIHTTPHook], $SourceVaultComfyUIHTTPHook = None];
If[! ValueQ[$SourceVaultComfyUIDepositMode], $SourceVaultComfyUIDepositMode = "commit"];
If[! ValueQ[$SourceVaultComfyUIDepositGrant], $SourceVaultComfyUIDepositGrant = None];

iSVCFBaseURL[] := If[StringQ[$SourceVaultComfyUIBaseURL],
  StringTrim[$SourceVaultComfyUIBaseURL, "/"], "http://127.0.0.1:8188"];

iSVCFHTTPTimeout[] := If[NumericQ[$SourceVaultComfyUIHTTPTimeout], $SourceVaultComfyUIHTTPTimeout, 30];
iSVCFJobTimeout[]  := If[NumericQ[$SourceVaultComfyUIJobTimeout], $SourceVaultComfyUIJobTimeout, 600];
iSVCFProvider[]    := If[StringQ[$SourceVaultComfyUIDefaultProviderName], $SourceVaultComfyUIDefaultProviderName, "comfyui"];

iSVCFStoreRoot[] :=
  If[StringQ[$SourceVaultComfyUIStoreRoot], $SourceVaultComfyUIStoreRoot,
    With[{r = Quiet@Check[SourceVault`$SourceVaultRoots["PrivateVault"], $Failed]},
      FileNameJoin[{If[StringQ[r], r, FileNameJoin[{$TemporaryDirectory, "sourcevault-comfyui"}]],
        If[StringQ[r], "comfyui", ""]}]]];

iSVCFEnsureDir[dir_String] :=
  If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];

iSVCFWorkflowsDir[] := FileNameJoin[{iSVCFStoreRoot[], "workflows"}];
iSVCFJobsDir[]      := FileNameJoin[{iSVCFStoreRoot[], "jobs"}];

(* epoch ms *)
iSVCFNowMs[] := Round[1000*(AbsoluteTime[TimeZone -> 0] - 2208988800)];

(* ============================================================
   JSON I/O (UTF-8 byte 安全。Eagle adapter と同じパターン)
   ============================================================ *)

iSVCFTmpJSON[tag_] := FileNameJoin[{$TemporaryDirectory,
  "sv_comfy_" <> tag <> "_" <> IntegerString[$ProcessID] <> "_" <>
  IntegerString[RandomInteger[{0, 999999999}]] <> ".json"}];

iSVCFJSONBytes[expr_] :=
  Module[{f = iSVCFTmpJSON["req"], bytes},
    Quiet@Check[Export[f, expr, "RawJSON", "Compact" -> True], Return[$Failed]];
    bytes = Quiet@Check[ByteArray[BinaryReadList[f]], $Failed];
    Quiet@DeleteFile[f];
    bytes];

iSVCFParseJSONBytes[bytes_] :=
  Module[{f = iSVCFTmpJSON["resp"], strm, json},
    If[Head[bytes] =!= ByteArray, Return[$Failed]];
    Quiet[strm = OpenWrite[f, BinaryFormat -> True];
      BinaryWrite[strm, Normal[bytes]]; Close[strm]];
    json = Quiet@Check[Import[f, "RawJSON"], $Failed];
    Quiet@DeleteFile[f];
    json];

(* ByteArray / String どちらの body でも JSON を取り出す (mock は string を返しうる) *)
iSVCFParseBody[b_ByteArray] := iSVCFParseJSONBytes[b];
iSVCFParseBody[b_String]    := Quiet@Check[ImportString[b, "RawJSON"], $Failed];
iSVCFParseBody[_]           := $Failed;

iSVCFAtomicExportJSON[path_String, expr_] :=
  Module[{tmp = path <> ".svtmp", r},
    r = Quiet@Check[Export[tmp, expr, "RawJSON", "Compact" -> True], $Failed];
    If[r === $Failed, Quiet@DeleteFile[tmp]; Return[$Failed]];
    Quiet@Check[RenameFile[tmp, path, OverwriteTarget -> True],
      Quiet@Check[DeleteFile[path]; RenameFile[tmp, path], $Failed]];
    If[FileExistsQ[path] && ! FileExistsQ[tmp], path, $Failed]];

iSVCFImportJSON[path_String] :=
  If[FileExistsQ[path], Quiet@Check[Import[path, "RawJSON"], $Failed], $Failed];

(* ============================================================
   canonical JSON / workflow hash (recursive key sort で決定論化)
   Association -> RawJSON のキー順に依存しない安定 hash を作る。
   ============================================================ *)

iSVCFCanonicalize[a_Association] := KeySort[iSVCFCanonicalize /@ a];
iSVCFCanonicalize[l_List] := iSVCFCanonicalize /@ l;
iSVCFCanonicalize[x_] := x;

iSVCFCanonicalJSONString[expr_] :=
  Quiet@Check[ExportString[iSVCFCanonicalize[expr], "RawJSON", "Compact" -> True], $Failed];

iSVCFWorkflowHash[wf_] :=
  With[{s = iSVCFCanonicalJSONString[wf]},
    If[StringQ[s], "sha256:" <> Hash[s, "SHA256", "HexString"], Missing["HashFailed"]]];

(* ============================================================
   HTTP 層 (差し替え可能)
   iSVCFHTTPRaw は <|"Status","StatusCode","Body"|> を返す。
   $SourceVaultComfyUIHTTPHook が設定されていればそれを使う (テスト用 mock)。
   ============================================================ *)

iSVCFHTTPRaw[method_String, endpoint_String, query_List : {}, body_ : None] :=
  Module[{hook = $SourceVaultComfyUIHTTPHook, url, req, resp, code, bodyOut},
    If[hook =!= None,
      With[{r = Quiet@Check[
          hook[<|"Method" -> method, "Endpoint" -> endpoint, "Query" -> query, "Body" -> body|>],
          $Failed]},
        If[! AssociationQ[r], Return[<|"Status" -> "Error", "Reason" -> "HookFailed"|>]];
        code = Lookup[r, "StatusCode", 200];
        bodyOut = Lookup[r, "Body", ""];
        Return[<|"Status" -> If[code === 200, "OK", "Error"],
          "StatusCode" -> code, "Body" -> bodyOut|>]]];
    url = URLBuild[iSVCFBaseURL[] <> endpoint, query];
    req = Switch[method,
      "GET", HTTPRequest[url, <|"Method" -> "GET"|>],
      "POST", If[body === None,
        HTTPRequest[url, <|"Method" -> "POST"|>],
        HTTPRequest[url, <|"Method" -> "POST",
          "Headers" -> {"Content-Type" -> "application/json; charset=utf-8"},
          "Body" -> body|>]],
      _, Return[<|"Status" -> "Error", "Reason" -> "BadMethod"|>]];
    resp = Quiet@Check[URLRead[req, TimeConstraint -> iSVCFHTTPTimeout[]], $Failed];
    If[! MatchQ[resp, _HTTPResponse],
      Return[<|"Status" -> "Error", "Reason" -> "Unreachable", "Endpoint" -> endpoint|>]];
    code = resp["StatusCode"];
    bodyOut = Quiet@Check[resp["BodyByteArray"], $Failed];
    <|"Status" -> If[code === 200, "OK", "Error"], "StatusCode" -> code, "Body" -> bodyOut|>];

(* GET JSON。endpoint への GET を JSON parse して <|"Status","Data"|> で返す *)
iSVCFGetJSON[endpoint_String, query_List : {}] :=
  Module[{raw = iSVCFHTTPRaw["GET", endpoint, query], json},
    If[Lookup[raw, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Error",
        "Reason" -> Lookup[raw, "Reason", "HTTP" <> ToString[Lookup[raw, "StatusCode", "?"]]],
        "Endpoint" -> endpoint|>]];
    json = iSVCFParseBody[Lookup[raw, "Body", $Failed]];
    If[json === $Failed,
      Return[<|"Status" -> "Error", "Reason" -> "BadJSON", "Endpoint" -> endpoint|>]];
    <|"Status" -> "OK", "Data" -> json|>];

(* POST JSON body *)
iSVCFPostJSON[endpoint_String, params_Association] :=
  Module[{body = iSVCFJSONBytes[params], raw, json},
    If[body === $Failed && $SourceVaultComfyUIHTTPHook === None,
      Return[<|"Status" -> "Error", "Reason" -> "RequestEncodeFailed"|>]];
    raw = iSVCFHTTPRaw["POST", endpoint, {},
      If[$SourceVaultComfyUIHTTPHook =!= None, params, body]];
    If[Lookup[raw, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Error",
        "Reason" -> Lookup[raw, "Reason", "HTTP" <> ToString[Lookup[raw, "StatusCode", "?"]]],
        "Endpoint" -> endpoint, "Detail" -> iSVCFParseBody[Lookup[raw, "Body", ""]]|>]];
    json = iSVCFParseBody[Lookup[raw, "Body", $Failed]];
    <|"Status" -> "OK", "Data" -> json|>];

(* ============================================================
   online / offline 判定 (TTL cache)
   ============================================================ *)

If[! ListQ[$iSVCFOnlineCache], $iSVCFOnlineCache = {}];  (* {t, <|stat|>} *)

iSVCFProbe[] :=
  Module[{r = iSVCFGetJSON["/system_stats"]},
    If[Lookup[r, "Status", ""] === "OK",
      <|"Online" -> True, "Stats" -> Lookup[r, "Data", Missing[]]|>,
      <|"Online" -> False, "Reason" -> Lookup[r, "Reason", "Unreachable"]|>]];

iSVCFStatusNow[] :=
  Module[{now = AbsoluteTime[], ttl, p},
    ttl = If[NumericQ[$SourceVaultComfyUIOfflineRecheckSeconds],
      $SourceVaultComfyUIOfflineRecheckSeconds, 30];
    If[ListQ[$iSVCFOnlineCache] && Length[$iSVCFOnlineCache] === 2 &&
        now - $iSVCFOnlineCache[[1]] < ttl,
      Return[$iSVCFOnlineCache[[2]]]];
    p = iSVCFProbe[];
    $iSVCFOnlineCache = {now, p};
    p];

(* ============================================================
   接続・診断 (公開)
   ============================================================ *)

Options[SourceVaultComfyUIStatus] = {"Refresh" -> False};
SourceVaultComfyUIStatus[OptionsPattern[]] :=
  Module[{p, ver},
    If[TrueQ[OptionValue["Refresh"]], $iSVCFOnlineCache = {}];
    p = iSVCFStatusNow[];
    If[! TrueQ[Lookup[p, "Online", False]],
      Return[<|"Status" -> "Offline", "Provider" -> iSVCFProvider[],
        "BaseURL" -> iSVCFBaseURL[], "Reason" -> Lookup[p, "Reason", "Unreachable"]|>]];
    ver = Quiet@Check[Lookup[p, "Stats", <||>]["system"]["comfyui_version"], Missing[]];
    <|"Status" -> "OK", "Provider" -> iSVCFProvider[], "BaseURL" -> iSVCFBaseURL[],
      "Version" -> If[StringQ[ver], ver, Missing[]],
      "Capabilities" -> {"Image", "Video"},
      "Stats" -> Lookup[p, "Stats", Missing[]]|>];

SourceVaultComfyUIAPIAvailable[OptionsPattern[]] :=
  TrueQ[Lookup[iSVCFStatusNow[], "Online", False]];
Options[SourceVaultComfyUIAPIAvailable] = {"Refresh" -> False};

SourceVaultComfyUISystemStats[___] := iSVCFGetJSON["/system_stats"];
SourceVaultComfyUIObjectInfo[___]  := iSVCFGetJSON["/object_info"];

SourceVaultComfyUIModels[folder_ : All, ___] :=
  If[folder === All || folder === Automatic,
    iSVCFGetJSON["/models"],
    iSVCFGetJSON["/models/" <> ToString[folder]]];

SourceVaultComfyUIQueue[___] := iSVCFGetJSON["/queue"];

SourceVaultComfyUIInterrupt[___] :=
  Module[{raw = iSVCFHTTPRaw["POST", "/interrupt", {}, None]},
    If[Lookup[raw, "Status", ""] === "OK",
      <|"Status" -> "OK", "Note" -> "global interrupt (not prompt-scoped)"|>,
      <|"Status" -> "Error", "Reason" -> Lookup[raw, "Reason", "InterruptFailed"]|>]];

(* ============================================================
   低レベル HTTP API (公開)
   ============================================================ *)

SourceVaultComfyUIAPICall[endpoint_String, params : (_Association | None) : None, ___] :=
  If[params === None || params === <||>,
    iSVCFGetJSON[endpoint],
    iSVCFPostJSON[endpoint, params]];

Options[SourceVaultComfyUIView] = {"Save" -> True};
SourceVaultComfyUIView[file_Association, OptionsPattern[]] :=
  Module[{q, raw, bytes, ct, saved = Missing[], dir, fname},
    q = {"filename" -> ToString@Lookup[file, "filename", Lookup[file, "Filename", ""]],
         "subfolder" -> ToString@Lookup[file, "subfolder", Lookup[file, "Subfolder", ""]],
         "type" -> ToString@Lookup[file, "type", Lookup[file, "Type", "output"]]};
    raw = iSVCFHTTPRaw["GET", "/view", q];
    If[Lookup[raw, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Error",
        "Reason" -> Lookup[raw, "Reason", "ViewFailed"]|>]];
    bytes = Lookup[raw, "Body", $Failed];
    If[Head[bytes] === String, bytes = StringToByteArray[bytes]];
    If[Head[bytes] =!= ByteArray,
      Return[<|"Status" -> "Error", "Reason" -> "NoBytes"|>]];
    ct = iSVCFGuessContentType[Lookup[file, "filename", ""]];
    If[TrueQ[OptionValue["Save"]],
      dir = FileNameJoin[{iSVCFStoreRoot[], "cache"}];
      iSVCFEnsureDir[dir];
      fname = FileNameJoin[{dir, IntegerString[iSVCFNowMs[]] <> "_" <>
        FileNameTake[ToString@Lookup[file, "filename", "out.bin"]]}];
      Quiet@Check[BinaryWrite[fname, Normal[bytes]] // Close, fname];
      If[FileExistsQ[fname], saved = fname]];
    <|"Status" -> "OK", "Bytes" -> bytes, "ContentType" -> ct, "File" -> saved|>];

iSVCFGuessContentType[name_String] :=
  Switch[ToLowerCase@FileExtension[name],
    "png", "image/png", "jpg" | "jpeg", "image/jpeg", "webp", "image/webp",
    "gif", "image/gif", "mp4", "video/mp4", "webm", "video/webm",
    _, "application/octet-stream"];
iSVCFGuessContentType[_] := "application/octet-stream";

(* /upload/image: multipart/form-data。元ファイル名/source path を出さず random 名で送る *)
Options[SourceVaultComfyUIUploadImage] = {"Overwrite" -> True, "Type" -> "input", "Subfolder" -> ""};
SourceVaultComfyUIUploadImage[path_String, OptionsPattern[]] :=
  Module[{rand, url, req, resp, json},
    If[! FileExistsQ[path], Return[<|"Status" -> "Error", "Reason" -> "FileNotFound"|>]];
    rand = "sv_input_" <> IntegerString[RandomInteger[{0, 999999999}]] <>
      "." <> If[FileExtension[path] === "", "png", FileExtension[path]];
    If[$SourceVaultComfyUIHTTPHook =!= None,
      With[{r = $SourceVaultComfyUIHTTPHook[<|"Method" -> "POST", "Endpoint" -> "/upload/image",
          "Query" -> {}, "Body" -> <|"image" -> rand|>|>]},
        json = iSVCFParseBody[Lookup[r, "Body", ""]];
        Return[If[AssociationQ[json],
          <|"Status" -> "OK", "Name" -> Lookup[json, "name", rand],
            "Subfolder" -> Lookup[json, "subfolder", ""], "Type" -> Lookup[json, "type", "input"]|>,
          <|"Status" -> "OK", "Name" -> rand, "Subfolder" -> "", "Type" -> "input"|>]]]];
    url = iSVCFBaseURL[] <> "/upload/image";
    req = HTTPRequest[url, <|"Method" -> "POST",
      "Body" -> {"image" -> <|"Content" -> File[path], "Name" -> rand|>,
        "overwrite" -> If[TrueQ[OptionValue["Overwrite"]], "true", "false"],
        "type" -> OptionValue["Type"], "subfolder" -> OptionValue["Subfolder"]}|>];
    resp = Quiet@Check[URLRead[req, TimeConstraint -> iSVCFHTTPTimeout[]], $Failed];
    If[! MatchQ[resp, _HTTPResponse] || resp["StatusCode"] =!= 200,
      Return[<|"Status" -> "Error", "Reason" -> "UploadFailed"|>]];
    json = iSVCFParseBody[Quiet@Check[resp["BodyByteArray"], $Failed]];
    If[! AssociationQ[json],
      Return[<|"Status" -> "Error", "Reason" -> "BadJSON"|>]];
    <|"Status" -> "OK", "Name" -> Lookup[json, "name", rand],
      "Subfolder" -> Lookup[json, "subfolder", ""], "Type" -> Lookup[json, "type", "input"]|>];

(* ============================================================
   Workflow registry (template = data)
   ============================================================ *)

(* API format 判定: 各値が "class_type" を持つ assoc。browser 形式 (nodes/links) は弾く *)
iSVCFAPIFormatQ[wf_Association] :=
  Length[wf] > 0 && ! KeyExistsQ[wf, "nodes"] && ! KeyExistsQ[wf, "links"] &&
  AllTrue[Values[wf], AssociationQ[#] && KeyExistsQ[#, "class_type"] &];
iSVCFAPIFormatQ[_] := False;

iSVCFWorkflowDir[name_String] := FileNameJoin[{iSVCFWorkflowsDir[], name}];

Options[SourceVaultComfyUIRegisterWorkflow] = {
  "Kind" -> "Image", "Variables" -> <||>, "Outputs" -> <||>,
  "RequiredModels" -> {}, "Tags" -> {},
  "TrustedForPrivateInput" -> False, "AllowedNodeTypes" -> Automatic};
SourceVaultComfyUIRegisterWorkflow[name_String, workflow_, OptionsPattern[]] :=
  Module[{wf = workflow, dir, meta, now},
    If[AssociationQ[wf] && KeyExistsQ[wf, "Workflow"], wf = wf["Workflow"]];
    If[! iSVCFAPIFormatQ[wf],
      Return[<|"Status" -> "Error", "Reason" -> "NotAPIFormat",
        "Hint" -> "ComfyUI frontend の File -> Export (API) で得た JSON を渡してください。"|>]];
    dir = iSVCFWorkflowDir[name];
    iSVCFEnsureDir[dir];
    now = DateString[Now, "ISODateTime"];
    (* meta は RawJSON で永続化するため symbol (Automatic 等) を JSON 安全値へ寄せる。
       AllowedNodeTypes Automatic は null、未確定 hash は null。 *)
    meta = <|"Name" -> name, "Kind" -> OptionValue["Kind"],
      "TrustedForPrivateInput" -> TrueQ[OptionValue["TrustedForPrivateInput"]],
      "AllowedNodeTypes" -> Replace[OptionValue["AllowedNodeTypes"], Automatic -> Null],
      "Variables" -> OptionValue["Variables"], "Outputs" -> OptionValue["Outputs"],
      "RequiredModels" -> OptionValue["RequiredModels"], "Tags" -> OptionValue["Tags"],
      "WorkflowHash" -> With[{h = iSVCFWorkflowHash[wf]}, If[StringQ[h], h, Null]],
      "CreatedAt" -> now, "UpdatedAt" -> now|>;
    If[iSVCFAtomicExportJSON[FileNameJoin[{dir, "workflow-api.json"}], wf] === $Failed ||
       iSVCFAtomicExportJSON[FileNameJoin[{dir, "meta.json"}], meta] === $Failed,
      Return[<|"Status" -> "Error", "Reason" -> "PersistFailed"|>]];
    <|"Status" -> "Registered", "Name" -> name, "WorkflowHash" -> meta["WorkflowHash"]|>];

SourceVaultComfyUIWorkflows[___] :=
  Module[{dir = iSVCFWorkflowsDir[], names},
    If[! DirectoryQ[dir], Return[<|"Status" -> "OK", "Workflows" -> {}|>]];
    names = Select[FileNames["*", dir], DirectoryQ];
    <|"Status" -> "OK",
      "Workflows" -> (Function[d,
          With[{m = iSVCFImportJSON[FileNameJoin[{d, "meta.json"}]]},
            If[AssociationQ[m], KeyTake[m, {"Name", "Kind", "Tags", "WorkflowHash", "UpdatedAt"}],
              <|"Name" -> FileNameTake[d]|>]]] /@ names)|>];

SourceVaultComfyUIWorkflow[name_String, ___] :=
  Module[{dir = iSVCFWorkflowDir[name], wf, meta},
    If[! DirectoryQ[dir], Return[<|"Status" -> "Error", "Reason" -> "WorkflowNotFound", "Name" -> name|>]];
    wf = iSVCFImportJSON[FileNameJoin[{dir, "workflow-api.json"}]];
    meta = iSVCFImportJSON[FileNameJoin[{dir, "meta.json"}]];
    If[! AssociationQ[wf],
      Return[<|"Status" -> "Error", "Reason" -> "WorkflowUnreadable", "Name" -> name|>]];
    <|"Status" -> "OK", "Name" -> name, "Workflow" -> wf,
      "Meta" -> If[AssociationQ[meta], meta, <||>]|>];

(* workflowOrName -> <|"Workflow","Variables","Outputs","Meta"|> *)
iSVCFResolveRecord[workflowOrName_, opts_Association] :=
  Module[{rec},
    Which[
      StringQ[workflowOrName],
        rec = SourceVaultComfyUIWorkflow[workflowOrName];
        If[Lookup[rec, "Status", ""] =!= "OK", Return[rec]];
        <|"Workflow" -> rec["Workflow"],
          "Variables" -> Lookup[rec["Meta"], "Variables", Lookup[opts, "Variables", <||>]],
          "Outputs" -> Lookup[rec["Meta"], "Outputs", Lookup[opts, "Outputs", <||>]],
          "Meta" -> rec["Meta"], "Name" -> workflowOrName, "Status" -> "OK"|>,
      AssociationQ[workflowOrName] && KeyExistsQ[workflowOrName, "Workflow"],
        <|"Workflow" -> workflowOrName["Workflow"],
          "Variables" -> Lookup[workflowOrName, "Variables", Lookup[opts, "Variables", <||>]],
          "Outputs" -> Lookup[workflowOrName, "Outputs", Lookup[opts, "Outputs", <||>]],
          "Meta" -> Lookup[workflowOrName, "Meta", <||>],
          "Name" -> Lookup[workflowOrName, "Name", Missing[]], "Status" -> "OK"|>,
      iSVCFAPIFormatQ[workflowOrName],
        <|"Workflow" -> workflowOrName,
          "Variables" -> Lookup[opts, "Variables", <||>],
          "Outputs" -> Lookup[opts, "Outputs", <||>],
          "Meta" -> <||>, "Name" -> Missing[], "Status" -> "OK"|>,
      True, <|"Status" -> "Error", "Reason" -> "BadWorkflow"|>]];

(* node/input への代入。mapping は <|"Node","Input"|> または mapping のリスト *)
iSVCFSetNodeInput[wf_Association, node_String, input_String, val_] :=
  If[KeyExistsQ[wf, node] && AssociationQ[wf[node]] && KeyExistsQ[wf[node], "inputs"],
    ReplacePart[wf, {node, "inputs", input} -> val], wf];

iSVCFApplyVar[wf_Association, mapping_Association, val_] :=
  iSVCFSetNodeInput[wf, ToString@Lookup[mapping, "Node", ""],
    ToString@Lookup[mapping, "Input", ""], val];
iSVCFApplyVar[wf_Association, mappings_List, val_] :=
  Fold[iSVCFApplyVar[#1, #2, val] &, wf, mappings];
iSVCFApplyVar[wf_Association, _, _] := wf;

Options[SourceVaultComfyUIRenderWorkflow] = {"Variables" -> <||>, "Outputs" -> <||>};
SourceVaultComfyUIRenderWorkflow[workflowOrName_, vars_Association, OptionsPattern[]] :=
  Module[{rec, wf, varmap},
    rec = iSVCFResolveRecord[workflowOrName, <|"Variables" -> OptionValue["Variables"],
      "Outputs" -> OptionValue["Outputs"]|>];
    If[Lookup[rec, "Status", ""] =!= "OK", Return[rec]];
    wf = rec["Workflow"];
    varmap = rec["Variables"];
    KeyValueMap[
      Function[{k, v},
        If[KeyExistsQ[varmap, k], wf = iSVCFApplyVar[wf, varmap[k], v]]],
      vars];
    <|"Status" -> "OK", "Workflow" -> wf, "Name" -> Lookup[rec, "Name", Missing[]],
      "WorkflowHash" -> iSVCFWorkflowHash[wf]|>];

Options[SourceVaultComfyUIValidateWorkflow] = {"Variables" -> <||>, "Outputs" -> <||>, "ObjectInfo" -> None};
SourceVaultComfyUIValidateWorkflow[workflowOrRecord_, OptionsPattern[]] :=
  Module[{rec, wf, vars, outs, issues = {}, nodes},
    rec = iSVCFResolveRecord[workflowOrRecord, <|"Variables" -> OptionValue["Variables"],
      "Outputs" -> OptionValue["Outputs"]|>];
    If[Lookup[rec, "Status", ""] =!= "OK", Return[rec]];
    wf = rec["Workflow"];
    If[! iSVCFAPIFormatQ[wf],
      Return[<|"Status" -> "Error", "Reason" -> "NotAPIFormat"|>]];
    nodes = Keys[wf];
    vars = rec["Variables"]; outs = rec["Outputs"];
    (* Variables が実在 node/input を指すか *)
    KeyValueMap[Function[{k, m},
      With[{mlist = If[ListQ[m], m, {m}]},
        Scan[Function[mm,
          With[{n = ToString@Lookup[mm, "Node", ""], inp = ToString@Lookup[mm, "Input", ""]},
            If[! MemberQ[nodes, n],
              AppendTo[issues, <|"Kind" -> "VarNodeMissing", "Var" -> k, "Node" -> n|>],
              If[! (AssociationQ[wf[n]] && KeyExistsQ[wf[n], "inputs"] &&
                    KeyExistsQ[wf[n]["inputs"], inp]),
                AppendTo[issues, <|"Kind" -> "VarInputMissing", "Var" -> k, "Node" -> n, "Input" -> inp|>]]]]],
          mlist]]], vars];
    (* Outputs 宣言の node 実在 *)
    Scan[Function[n, If[! MemberQ[nodes, ToString[n]],
        AppendTo[issues, <|"Kind" -> "OutputNodeMissing", "Node" -> n|>]]],
      Flatten[Values[If[AssociationQ[outs], outs, <||>]]]];
    If[issues === {},
      <|"Status" -> "OK", "Valid" -> True, "NodeCount" -> Length[nodes]|>,
      <|"Status" -> "Error", "Reason" -> "ValidationFailed", "Issues" -> issues|>]];

(* ============================================================
   seed / privacy / jobSpec
   ============================================================ *)

iSVCFResolveSeed[Automatic] := RandomInteger[{0, 2^31 - 1}];
iSVCFResolveSeed[s_Integer] := s;
iSVCFResolveSeed[s_?NumericQ] := Round[s];
iSVCFResolveSeed[_] := RandomInteger[{0, 2^31 - 1}];

iSVCFDefaultPrivacy[] :=
  With[{d = Quiet@Check[SourceVault`$SourceVaultDefaultObjectPrivacyLevel, $Failed]},
    If[NumericQ[d], N[d], 0.85]];

(* 生成物 PrivacyLevel = Max[入力群 PL, prompt provenance PL, 既定]。欠落は fail-closed=既定 *)
iSVCFComputePrivacy[spec_Association] :=
  Module[{lv = {}, inputs},
    If[NumericQ[Lookup[spec, "PrivacyLevel", Missing[]]], AppendTo[lv, N@spec["PrivacyLevel"]]];
    inputs = Lookup[spec, "Inputs", {}];
    If[ListQ[inputs],
      Scan[If[AssociationQ[#] && NumericQ[Lookup[#, "PrivacyLevel", Missing[]]],
        AppendTo[lv, N@#["PrivacyLevel"]]] &, inputs]];
    AppendTo[lv, iSVCFDefaultPrivacy[]];
    Max[lv]];

(* 寸法解決: Width/Height 優先。AspectRatio は warning 相当 (ここでは Width/Height があれば採用) *)
iSVCFResolveDims[spec_Association] :=
  Module[{w = Lookup[spec, "Width", Missing[]], h = Lookup[spec, "Height", Missing[]]},
    <|"Width" -> If[IntegerQ[w], w, Missing[]], "Height" -> If[IntegerQ[h], h, Missing[]],
      "AspectRatioIgnored" -> (KeyExistsQ[spec, "AspectRatio"] && IntegerQ[w] && IntegerQ[h])|>];

Options[SourceVaultComfyUIBuildJobSpec] = {};
SourceVaultComfyUIBuildJobSpec[spec_Association, OptionsPattern[]] :=
  Module[{wfName, po, vars, seed, dims, rendered, pl, rec},
    po = Lookup[spec, "ProviderOptions", <||>];
    wfName = Lookup[po, "Workflow",
      If[StringQ[$SourceVaultComfyUIDefaultWorkflow], $SourceVaultComfyUIDefaultWorkflow, Missing[]]];
    If[! StringQ[wfName],
      Return[<|"Status" -> "Error", "Reason" -> "NoWorkflowForSpec"|>]];
    rec = SourceVaultComfyUIWorkflow[wfName];
    If[Lookup[rec, "Status", ""] =!= "OK", Return[rec]];
    seed = iSVCFResolveSeed[Lookup[spec, "Seed", Automatic]];
    dims = iSVCFResolveDims[spec];
    pl = iSVCFComputePrivacy[spec];
    vars = <|"Prompt" -> Lookup[spec, "Prompt", ""],
      "NegativePrompt" -> Lookup[spec, "NegativePrompt", ""], "Seed" -> seed|>;
    If[IntegerQ[dims["Width"]], vars["Width"] = dims["Width"]];
    If[IntegerQ[dims["Height"]], vars["Height"] = dims["Height"]];
    rendered = SourceVaultComfyUIRenderWorkflow[wfName, vars];
    If[Lookup[rendered, "Status", ""] =!= "OK", Return[rendered]];
    <|"Status" -> "OK", "Provider" -> iSVCFProvider[], "WorkflowName" -> wfName,
      "Workflow" -> rendered["Workflow"], "WorkflowHash" -> rendered["WorkflowHash"],
      "Seed" -> seed, "PrivacyLevel" -> pl,
      "OutputsDecl" -> Lookup[rec["Meta"], "Outputs", <||>],
      "RequiredModels" -> Lookup[rec["Meta"], "RequiredModels", {}],
      "Request" -> spec, "JobTimeout" -> iSVCFJobTimeout[],
      "ExternalJobSpec" -> <|"Backend" -> "ComfyUI", "MediaSpec" -> spec,
        "Workflow" -> rendered["Workflow"], "JobTimeout" -> iSVCFJobTimeout[]|>|>];

(* ============================================================
   Job 実行
   ============================================================ *)

(* /prompt POST。workflow(API JSON) を queue へ。返り prompt_id *)
Options[SourceVaultComfyUIQueuePrompt] = {"ClientId" -> Automatic};
SourceVaultComfyUIQueuePrompt[workflow_, OptionsPattern[]] :=
  Module[{wf = workflow, cid, params, r, pid},
    If[AssociationQ[wf] && KeyExistsQ[wf, "Workflow"], wf = wf["Workflow"]];
    If[! iSVCFAPIFormatQ[wf],
      Return[<|"Status" -> "Error", "Reason" -> "NotAPIFormat"|>]];
    cid = OptionValue["ClientId"];
    If[cid === Automatic, cid = "sv-comfy-" <> IntegerString[RandomInteger[{0, 999999999}]]];
    params = <|"prompt" -> wf, "client_id" -> cid|>;
    r = iSVCFPostJSON["/prompt", params];
    If[Lookup[r, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Error", "Reason" -> Lookup[r, "Reason", "QueueFailed"],
        "Detail" -> Lookup[r, "Detail", Missing[]]|>]];
    pid = Quiet@Check[Lookup[r["Data"], "prompt_id", Missing[]], Missing[]];
    If[! StringQ[pid],
      Return[<|"Status" -> "Error", "Reason" -> "NoPromptId", "Data" -> Lookup[r, "Data", Missing[]]|>]];
    <|"Status" -> "OK", "PromptId" -> pid, "ClientId" -> cid,
      "NodeErrors" -> Quiet@Check[Lookup[r["Data"], "node_errors", <||>], <||>]|>];

(* /queue 内の全 prompt_id を集める *)
iSVCFQueueIds[queue_Association] :=
  Module[{collect},
    collect[entries_List] := Cases[entries, e_List /; Length[e] >= 2 :> ToString[e[[2]]]];
    collect[_] := {};
    Join[collect[Lookup[queue, "queue_running", {}]],
         collect[Lookup[queue, "queue_pending", {}]]]];
iSVCFQueueIds[_] := {};

iSVCFHistoryEntry[history_Association, promptId_String] :=
  Lookup[history, promptId, Missing[]];
iSVCFHistoryEntry[_, _] := Missing[];

iSVCFHistoryHasError[entry_Association] :=
  Module[{st = Lookup[entry, "status", <||>]},
    AssociationQ[st] && (ToString@Lookup[st, "status_str", ""] === "error" ||
      MemberQ[Flatten[{Lookup[st, "messages", {}]}], _?(StringContainsQ[ToString[#], "error", IgnoreCase -> True] &)] &&
        ToString@Lookup[st, "status_str", ""] =!= "success")];
iSVCFHistoryHasError[_] := False;

iSVCFHistoryHasOutputs[entry_Association] :=
  With[{o = Lookup[entry, "outputs", <||>]}, AssociationQ[o] && Length[o] > 0];
iSVCFHistoryHasOutputs[_] := False;

(* ── status reader 状態機械 (純関数, テスト対象の核心) ──
   引数: promptId, queue snapshot, history snapshot (history/{id} 形 <|pid -> entry|>), seenBefore
   返り: "Running" | "Completed" | "Failed" | "Lost"
   transient (HTTP 失敗) はここでは扱わない。呼び出し側 (Poll) が Running 扱いにする。 *)
iSVCFClassifyState[promptId_String, queue_, history_, seenBefore_:False] :=
  Module[{inQueue, entry},
    inQueue = MemberQ[iSVCFQueueIds[queue], promptId];
    entry = iSVCFHistoryEntry[history, promptId];
    Which[
      inQueue, "Running",
      AssociationQ[entry] && iSVCFHistoryHasError[entry], "Failed",
      AssociationQ[entry] && iSVCFHistoryHasOutputs[entry], "Completed",
      AssociationQ[entry], "Completed",
      TrueQ[seenBefore] && ! inQueue && MissingQ[entry], "Lost",
      True, "Running"]];

Options[SourceVaultComfyUIPoll] = {"Seen" -> False, "Queue" -> Automatic, "History" -> Automatic};
SourceVaultComfyUIPoll[promptId_String, OptionsPattern[]] :=
  Module[{queue, history, qr, hr, state},
    queue = OptionValue["Queue"];
    history = OptionValue["History"];
    If[queue === Automatic,
      qr = SourceVaultComfyUIQueue[];
      If[Lookup[qr, "Status", ""] =!= "OK",
        Return[<|"Status" -> "OK", "State" -> "Running", "Transient" -> True,
          "Reason" -> Lookup[qr, "Reason", "QueueUnreachable"]|>]];
      queue = qr["Data"]];
    If[history === Automatic,
      hr = iSVCFGetJSON["/history/" <> promptId];
      If[Lookup[hr, "Status", ""] =!= "OK",
        Return[<|"Status" -> "OK", "State" -> "Running", "Transient" -> True,
          "Reason" -> Lookup[hr, "Reason", "HistoryUnreachable"]|>]];
      history = hr["Data"]];
    state = iSVCFClassifyState[promptId, queue, history, TrueQ[OptionValue["Seen"]]];
    <|"Status" -> "OK", "State" -> state, "PromptId" -> promptId,
      "Transient" -> False|>];

SourceVaultComfyUIJobStatus[promptId_String, opts___] := SourceVaultComfyUIPoll[promptId, opts];

(* history から出力ファイルを列挙 *)
SourceVaultComfyUIFetchOutputs[promptId_String, ___] :=
  Module[{hr = iSVCFGetJSON["/history/" <> promptId]},
    If[Lookup[hr, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Error", "Reason" -> Lookup[hr, "Reason", "HistoryUnreachable"]|>]];
    SourceVaultComfyUIFetchOutputs[hr["Data"]]];

SourceVaultComfyUIFetchOutputs[history_Association, ___] :=
  Module[{entry, outputs, files = {}},
    entry = If[Length[history] === 1 && AssociationQ[First[Values[history]]] &&
        KeyExistsQ[First[Values[history]], "outputs"],
      First[Values[history]], history];
    outputs = Lookup[entry, "outputs", <||>];
    If[! AssociationQ[outputs],
      Return[<|"Status" -> "Error", "Reason" -> "NoOutputs"|>]];
    KeyValueMap[Function[{nodeId, nodeOut},
      Scan[Function[kind,
        With[{lst = Lookup[nodeOut, kind, {}]},
          If[ListQ[lst],
            Scan[If[AssociationQ[#],
              AppendTo[files, <|"filename" -> Lookup[#, "filename", ""],
                "subfolder" -> Lookup[#, "subfolder", ""],
                "type" -> Lookup[#, "type", "output"],
                "kind" -> kind, "node" -> nodeId|>]] &, lst]]]],
        {"images", "gifs", "videos"}]],
      If[AssociationQ[outputs], outputs, <||>]];
    <|"Status" -> "OK", "Outputs" -> files|>];

(* ============================================================
   Deposit (SourceVaultMCPDeposit があれば content store へ)
   ============================================================ *)

iSVCFDepositAvailableQ[] :=
  TrueQ[Quiet@Check[Length[DownValues[SourceVault`SourceVaultMCPDeposit]] > 0, False]];

Options[SourceVaultComfyUIDepositOutputs] = {"PrivacyLevel" -> Automatic, "Provenance" -> <||>};
SourceVaultComfyUIDepositOutputs[promptId_String, opts : OptionsPattern[]] :=
  Module[{fo = SourceVaultComfyUIFetchOutputs[promptId]},
    If[Lookup[fo, "Status", ""] =!= "OK", Return[fo]];
    iSVCFDepositFiles[fo["Outputs"], <|opts|>]];
SourceVaultComfyUIDepositOutputs[history_Association, opts : OptionsPattern[]] :=
  Module[{fo = SourceVaultComfyUIFetchOutputs[history]},
    If[Lookup[fo, "Status", ""] =!= "OK", Return[fo]];
    iSVCFDepositFiles[fo["Outputs"], <|opts|>]];

iSVCFDepositFiles[files_List, opts_Association] :=
  Module[{pl, prov, artifacts = {}, depAvail = iSVCFDepositAvailableQ[]},
    pl = Lookup[opts, "PrivacyLevel", Automatic];
    If[! NumericQ[pl], pl = iSVCFDefaultPrivacy[]];
    prov = Lookup[opts, "Provenance", <||>];
    Scan[Function[f,
      With[{v = SourceVaultComfyUIView[f]},
        If[Lookup[v, "Status", ""] === "OK",
          With[{dep = iSVCFDepositOne[v, f, pl, prov, depAvail]},
            AppendTo[artifacts, dep]]]]],
      files];
    <|"Status" -> If[AllTrue[artifacts, Lookup[#, "Status", ""] === "OK" &], "OK", "Error"],
      "Artifacts" -> artifacts,
      "DepositBackend" -> If[depAvail, "SourceVaultMCPDeposit", "LocalCacheOnly"]|>];

(* SourceVaultMCPDeposit 用 spec。binary は base64 Association (mediaType は top-level)。
   commit は DepositArtifact 権限を要する: grant か ClaudeOrchestrator AccessProfile。
   provenance.authoredBy で profile 解決の principal を与える。 *)
iSVCFDepositSpec[bytes_, mt_, pl_, prov_, file_] :=
  Module[{spec},
    spec = <|
      "mode" -> If[StringQ[$SourceVaultComfyUIDepositMode], $SourceVaultComfyUIDepositMode, "commit"],
      "kind" -> "GeneratedMedia", "mediaType" -> mt,
      "content" -> <|"encoding" -> "base64", "data" -> BaseEncode[bytes]|>,
      "title" -> ToString@Lookup[file, "filename", "comfyui-output"],
      "policy" -> <|"privacyLevel" -> pl|>,
      "provenance" -> Join[
        <|"authoredBy" -> <|"provider" -> "ClaudeOrchestrator", "modelId" -> "comfyui",
            "ModelIntent" -> "deposit"|>|>,
        If[AssociationQ[prov], prov, <||>],
        <|"Provider" -> iSVCFProvider[], "Filename" -> ToString@Lookup[file, "filename", ""]|>]|>;
    If[$SourceVaultComfyUIDepositGrant =!= None,
      spec["Grant"] = $SourceVaultComfyUIDepositGrant];
    spec];

iSVCFDepositOne[view_Association, file_Association, pl_, prov_, depAvail_] :=
  Module[{bytes = view["Bytes"], mt = view["ContentType"], dep, uri, st},
    If[! depAvail,
      (* deposit 不能環境: local cache の path のみ返す (正本 store ではない) *)
      Return[<|"Status" -> "OK", "URI" -> Missing["NoDepositBackend"],
        "File" -> Lookup[view, "File", Missing[]], "MediaType" -> mt,
        "PrivacyLevel" -> pl, "Provider" -> iSVCFProvider[]|>]];
    If[Head[bytes] =!= ByteArray,
      Return[<|"Status" -> "Error", "Reason" -> "NoBytes", "File" -> Lookup[view, "File", Missing[]]|>]];
    dep = Quiet@Check[
      SourceVault`SourceVaultMCPDeposit[iSVCFDepositSpec[bytes, mt, pl, prov, file]], $Failed];
    If[! AssociationQ[dep],
      Return[<|"Status" -> "Error", "Reason" -> "DepositFailed",
        "File" -> Lookup[view, "File", Missing[]]|>]];
    uri = Lookup[dep, "ArtifactUri", Lookup[dep, "ContentUri", Missing[]]];
    st = ToString@Lookup[dep, "Status", ""];
    If[StringQ[uri],
      <|"Status" -> "OK", "URI" -> uri, "ContentUri" -> Lookup[dep, "ContentUri", Missing[]],
        "MediaType" -> mt, "PrivacyLevel" -> pl, "Provider" -> iSVCFProvider[],
        "DepositStatus" -> st|>,
      (* 書き込まれなかった (RequireGrant / RequireApproval / QuotaExceeded / Planned 等)。
         生成物自体は成功なので File は残す。 *)
      <|"Status" -> "Error", "Reason" -> "DepositNotWritten", "DepositStatus" -> st,
        "DepositResult" -> KeyTake[dep, {"Status", "Reason", "RequiresApproval", "HowToProceed"}],
        "File" -> Lookup[view, "File", Missing[]], "MediaType" -> mt, "PrivacyLevel" -> pl|>]];

(* ============================================================
   SourceVaultComfyUIRunWorkflow -- 同期 debug 経路 (非 FE 用)
   ============================================================ *)

Options[SourceVaultComfyUIRunWorkflow] = {
  "PollInterval" -> 1.5, "Deposit" -> Automatic, "PrivacyLevel" -> Automatic};
SourceVaultComfyUIRunWorkflow[workflowOrName_, vars_Association : <||>, OptionsPattern[]] :=
  Module[{rendered, qp, pid, t0, interval, deadline, seen = False, poll, state,
          deposit, dep, fo},
    rendered = SourceVaultComfyUIRenderWorkflow[workflowOrName, vars];
    If[Lookup[rendered, "Status", ""] =!= "OK", Return[rendered]];
    qp = SourceVaultComfyUIQueuePrompt[rendered["Workflow"]];
    If[Lookup[qp, "Status", ""] =!= "OK", Return[qp]];
    pid = qp["PromptId"];
    interval = If[NumericQ[OptionValue["PollInterval"]], OptionValue["PollInterval"], 1.5];
    t0 = AbsoluteTime[]; deadline = t0 + iSVCFJobTimeout[];
    state = "Running";
    While[AbsoluteTime[] < deadline,
      poll = SourceVaultComfyUIPoll[pid, "Seen" -> seen];
      state = Lookup[poll, "State", "Running"];
      If[! TrueQ[Lookup[poll, "Transient", False]], seen = True];
      If[MemberQ[{"Completed", "Failed", "Lost"}, state], Break[]];
      Pause[interval]];
    If[state =!= "Completed",
      Return[<|"Status" -> If[state === "Failed", "Error", "Timeout"],
        "Reason" -> If[state === "Failed", "GenerationFailed", "Timeout"],
        "Provider" -> iSVCFProvider[], "PromptId" -> pid, "State" -> state|>]];
    deposit = OptionValue["Deposit"];
    fo = SourceVaultComfyUIFetchOutputs[pid];
    (* 既定 (Automatic/True) は出力をローカル materialize し、deposit backend が
       あれば commit する (DepositOutputs が backend 不在を LocalCacheOnly に落とす)。
       "Deposit"->False のときだけ materialize/deposit を完全に skip する。 *)
    dep = If[deposit === False,
      <|"Status" -> "OK", "Artifacts" -> {}, "DepositBackend" -> "Skipped"|>,
      SourceVaultComfyUIDepositOutputs[pid, "PrivacyLevel" -> OptionValue["PrivacyLevel"]]];
    <|"Status" -> "OK", "Provider" -> iSVCFProvider[], "PromptId" -> pid,
      "Artifacts" -> Lookup[dep, "Artifacts", {}],
      "Outputs" -> Lookup[fo, "Outputs", {}],
      "WorkflowHash" -> rendered["WorkflowHash"]|>];

(* ============================================================
   External(ComfyUI) backend -- ClaudeOrchestrator External executor へ差し込む
     launcher / status reader / killer。backend dispatch (Phase 0.5) と組で動く。
   - launcher は子プロセスを起動せず /prompt POST し prompt_id を JobID にする。
   - status reader は /queue + /history で状態判定し、Completed 時に /view + deposit。
   - killer は prompt スコープ: pending なら queue delete、running なら /interrupt。
   pending 情報 (rendered workflow / PrivacyLevel) は $iSVCFPendingJobs で受け渡す。
   ============================================================ *)

If[! AssociationQ[$iSVCFPendingJobs], $iSVCFPendingJobs = <||>];  (* key(wid|promptId) -> meta *)

iSVCFBackendDispatchAvailableQ[] :=
  TrueQ[Quiet@Check[
    Length[DownValues[ClaudeOrchestrator`Workflow`ClaudeRegisterExternalBackend]] > 0, False]];

iSVCFEngineAvailableQ[] :=
  TrueQ[Quiet@Check[
    Length[DownValues[ClaudeOrchestrator`Workflow`ClaudeCreateWorkflowNet]] > 0 &&
    Length[DownValues[ClaudeOrchestrator`Workflow`ClaudeStepWorkflow]] > 0, False]];

(* launcher: jobSpec["WorkflowID"] から pending(=SubmitExternal が積んだ workflow) を引き、
   /prompt POST。成功したら pending を promptId へ re-key し JobID=promptId を返す。 *)
iSVCFExtLauncher[jobSpec_Association] :=
  Module[{wid = Lookup[jobSpec, "WorkflowID", Missing[]], pend, wf, qp, pid},
    pend = If[StringQ[wid], Lookup[$iSVCFPendingJobs, wid, <||>], <||>];
    wf = Lookup[pend, "Workflow", Missing[]];
    If[! iSVCFAPIFormatQ[wf],
      Return[<|"Status" -> "Failed", "Reason" -> "NoWorkflowForComfyJob"|>]];
    qp = SourceVaultComfyUIQueuePrompt[wf];
    If[Lookup[qp, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Failed", "Reason" -> Lookup[qp, "Reason", "QueueFailed"]|>]];
    pid = qp["PromptId"];
    (* /prompt 成功 = queue 投入済みなので Seen=True で開始 (直後の Lost 誤判定を避ける) *)
    $iSVCFPendingJobs[pid] = <|
      "PrivacyLevel" -> Lookup[pend, "PrivacyLevel", Automatic],
      "WorkflowName" -> Lookup[pend, "WorkflowName", Missing[]],
      "Request" -> Lookup[pend, "Request", <||>], "Seen" -> True|>;
    If[StringQ[wid], $iSVCFPendingJobs = KeyDrop[$iSVCFPendingJobs, wid]];
    <|"Status" -> "Launched", "JobID" -> pid, "JobDir" -> None, "PID" -> None|>];

(* status reader: awaitMeta["JobID"]=promptId。Completed 時に deposit して ref を返す。
   transient HTTP 失敗は Running 扱い (terminal failure にしない)。 *)
iSVCFExtStatusReader[awaitMeta_Association] :=
  Module[{pid = Lookup[awaitMeta, "JobID", Missing[]], pend, seen, poll, state, pl, dep, art, uri},
    If[! StringQ[pid], Return[<|"Status" -> "Running"|>]];
    pend = Lookup[$iSVCFPendingJobs, pid, <||>];
    seen = TrueQ[Lookup[pend, "Seen", True]];
    poll = SourceVaultComfyUIPoll[pid, "Seen" -> seen];
    If[TrueQ[Lookup[poll, "Transient", False]], Return[<|"Status" -> "Running"|>]];
    state = Lookup[poll, "State", "Running"];
    Switch[state,
      "Completed",
        pl = Lookup[pend, "PrivacyLevel", Automatic];
        dep = SourceVaultComfyUIDepositOutputs[pid, "PrivacyLevel" -> pl];
        art = If[Length[Lookup[dep, "Artifacts", {}]] >= 1, First[dep["Artifacts"]], <||>];
        uri = Lookup[art, "URI", Missing[]];
        $iSVCFPendingJobs = KeyDrop[$iSVCFPendingJobs, pid];
        <|"Status" -> "Completed", "SourceVaultRef" -> uri, "OutputRef" -> uri,
          "Artifacts" -> Lookup[dep, "Artifacts", {}],
          "DepositBackend" -> Lookup[dep, "DepositBackend", Missing[]]|>,
      "Failed" | "Lost",
        $iSVCFPendingJobs = KeyDrop[$iSVCFPendingJobs, pid];
        <|"Status" -> "Failed", "ErrorRef" -> state|>,
      _, <|"Status" -> "Running"|>]];

iSVCFQueueIdsIn[queue_Association, key_String] :=
  Cases[Lookup[queue, key, {}], e_List /; Length[e] >= 2 :> ToString[e[[2]]]];
iSVCFQueueIdsIn[_, _] := {};

(* killer: prompt スコープ。pending なら queue delete のみ、running なら /interrupt。
   global /interrupt で他ジョブを巻き込まない。 *)
iSVCFExtKiller[awaitMeta_Association] :=
  Module[{pid = Lookup[awaitMeta, "JobID", Missing[]], qr, queue, running, pending},
    If[StringQ[pid], $iSVCFPendingJobs = KeyDrop[$iSVCFPendingJobs, pid]];
    If[! StringQ[pid], Return[Null]];
    qr = SourceVaultComfyUIQueue[];
    If[Lookup[qr, "Status", ""] =!= "OK", Return[Null]];
    queue = qr["Data"];
    running = MemberQ[iSVCFQueueIdsIn[queue, "queue_running"], pid];
    pending = MemberQ[iSVCFQueueIdsIn[queue, "queue_pending"], pid];
    Which[
      pending, iSVCFPostJSON["/queue", <|"delete" -> {pid}|>],
      running, SourceVaultComfyUIInterrupt[],
      True, Null];
    Null];

SourceVaultComfyUIRegisterBackend[] :=
  If[iSVCFBackendDispatchAvailableQ[],
    ClaudeOrchestrator`Workflow`ClaudeRegisterExternalBackend["ComfyUI",
      <|"Launcher" -> iSVCFExtLauncher, "StatusReader" -> iSVCFExtStatusReader,
        "Killer" -> iSVCFExtKiller|>],
    <|"Status" -> "Error", "Reason" -> "ExternalBackendDispatchUnavailable"|>];

(* auto-commit 用 DepositArtifact grant (§6.1 standing-grant)。
   GrantMaxAccessLevel 未満の effPL だけ auto-approve され、それ以上 (high-privacy) は
   deposit 側 approval gate (RequireApproval) で保護される=auto-commit しない。 *)
iSVCFMintAvailableQ[] :=
  TrueQ[Quiet@Check[Length[DownValues[SourceVault`SourceVaultMCPMintAccessGrant]] > 0, False]];
iSVCFActivateExecutorAvailableQ[] :=
  TrueQ[Quiet@Check[Length[DownValues[ClaudeRuntime`ClaudeActivateExternalExecutor]] > 0, False]];

(* poll tick を起動する。ClaudeRuntime_externalrunner があればフル activate
   (WolframScript launcher 結線 + completion hook + tick 登録)。無くても
   engine の ClaudeExternalJobPollTick を共有 polling tick へ直接登録して
   ComfyUI ジョブが背景で自動完了するようにする (externalrunner 非依存)。 *)
iSVCFEnsurePollTick[] :=
  Which[
    iSVCFActivateExecutorAvailableQ[],
      Quiet@Check[ClaudeRuntime`ClaudeActivateExternalExecutor[],
        <|"Status" -> "Error", "Reason" -> "ActivateException"|>],
    TrueQ[Quiet@Check[
        Length[DownValues[ClaudeCode`ClaudeRegisterPollingTick]] > 0 &&
        Length[DownValues[ClaudeOrchestrator`Workflow`ClaudeExternalJobPollTick]] > 0, False]],
      (Quiet@Check[ClaudeCode`ClaudeRegisterPollingTick["sv-comfyui-external-poll",
         ClaudeOrchestrator`Workflow`ClaudeExternalJobPollTick], Null];
       <|"Status" -> "OK", "Via" -> "DirectPollTick",
         "Note" -> "externalrunner 未ロードのため poll tick を直接登録 (completion hook 無し)"|>),
    True, <|"Status" -> "Error", "Reason" -> "PollTickUnavailable"|>];

Options[iSVCFEnsureDepositGrant] = {"RenewGrant" -> False, "GrantTTLSeconds" -> 86400,
  "GrantMaxAccessLevel" -> 0.49};
iSVCFEnsureDepositGrant[OptionsPattern[]] :=
  Module[{g},
    If[! TrueQ[OptionValue["RenewGrant"]] && $SourceVaultComfyUIDepositGrant =!= None,
      Return[<|"Status" -> "OK", "Existing" -> True|>]];
    If[! iSVCFMintAvailableQ[],
      Return[<|"Status" -> "Error", "Reason" -> "MintUnavailable"|>]];
    Quiet@Check[SourceVault`SourceVaultMCPEnsureGrantKey[], Null];
    g = Quiet@Check[SourceVault`SourceVaultMCPMintAccessGrant[<|
      "Principal" -> <|"Provider" -> "ClaudeOrchestrator", "Component" -> "SourceVault_comfyui"|>,
      "AllowedActions" -> {"DepositArtifact"}, "AllowedKinds" -> {"GeneratedMedia"},
      "MaxAccessLevel" -> OptionValue["GrantMaxAccessLevel"],
      "Purpose" -> "comfyui generated-media auto-commit",
      "TTLSeconds" -> OptionValue["GrantTTLSeconds"]|>], $Failed];
    If[! AssociationQ[g],
      Return[<|"Status" -> "Error", "Reason" -> "MintFailed", "Detail" -> g|>]];
    $SourceVaultComfyUIDepositGrant = g;
    <|"Status" -> "OK", "GrantId" -> Lookup[g, "GrantId", Missing[]],
      "MaxAccessLevel" -> OptionValue["GrantMaxAccessLevel"]|>];

(* SubmitExternal の自己治癒 (全冪等): backend 登録 + grant 確保 + poll tick 起動 *)
iSVCFEnsureActivated[] :=
  (SourceVaultComfyUIRegisterBackend[];
   If[StringQ[$SourceVaultComfyUIDepositMode] && $SourceVaultComfyUIDepositMode === "commit",
     iSVCFEnsureDepositGrant[]];
   iSVCFEnsurePollTick[];);

Options[SourceVaultComfyUIActivate] = {"RenewGrant" -> False, "GrantTTLSeconds" -> 86400,
  "GrantMaxAccessLevel" -> 0.49};
SourceVaultComfyUIActivate[OptionsPattern[]] :=
  Module[{reg, grant, act},
    reg = SourceVaultComfyUIRegisterBackend[];
    grant = iSVCFEnsureDepositGrant["RenewGrant" -> OptionValue["RenewGrant"],
      "GrantTTLSeconds" -> OptionValue["GrantTTLSeconds"],
      "GrantMaxAccessLevel" -> OptionValue["GrantMaxAccessLevel"]];
    act = iSVCFEnsurePollTick[];
    <|"Status" -> If[Lookup[reg, "Status", ""] === "Registered" &&
        MemberQ[{"OK"}, Lookup[grant, "Status", ""]], "OK", "Partial"],
      "Backend" -> reg, "Grant" -> grant, "Executor" -> act,
      "DepositMode" -> $SourceVaultComfyUIDepositMode|>];

(* ============================================================
   SourceVaultComfyUISubmitExternal -- 1 遷移 WorkflowNet で非ブロック投入
     (ClaudeSubmitExternalHeldExprJob と同じ In+Slots->External->Out+Slots パターン)
   ============================================================ *)

Options[SourceVaultComfyUISubmitExternal] = {"PrivacyLevel" -> Automatic, "NotifyNotebook" -> None};
SourceVaultComfyUISubmitExternal[workflowOrName_, vars_Association : <||>, OptionsPattern[]] :=
  Module[{rendered, pl, wid, awaiting, meta, pid,
          WNet, WPlace, WTrans, WTok, createNet, submitTok, stepWf},
    If[! iSVCFBackendDispatchAvailableQ[],
      Return[<|"Status" -> "Error", "Reason" -> "ExternalBackendDispatchUnavailable",
        "Hint" -> "ClaudeOrchestrator backend dispatch 未整備。非 FE では SourceVaultComfyUIRunWorkflow を使用。"|>]];
    If[! iSVCFEngineAvailableQ[],
      Return[<|"Status" -> "Error", "Reason" -> "ExternalExecutorInactive",
        "Hint" -> "ClaudeOrchestrator`Workflow` engine が未ロードです。"|>]];
    (* backend 登録 + auto-commit grant 確保 + poll tick 起動 (冪等)。
       これにより SubmitExternal 単独でも背景で完了まで進む。 *)
    iSVCFEnsureActivated[];
    rendered = SourceVaultComfyUIRenderWorkflow[workflowOrName, vars];
    If[Lookup[rendered, "Status", ""] =!= "OK", Return[rendered]];
    pl = OptionValue["PrivacyLevel"];
    If[! NumericQ[pl], pl = iSVCFDefaultPrivacy[]];
    WNet = ClaudeOrchestrator`Workflow`WorkflowNet;
    WPlace = ClaudeOrchestrator`Workflow`WorkflowPlace;
    WTrans = ClaudeOrchestrator`Workflow`WorkflowTransition;
    WTok = ClaudeOrchestrator`Workflow`WorkflowToken;
    createNet = ClaudeOrchestrator`Workflow`ClaudeCreateWorkflowNet;
    submitTok = ClaudeOrchestrator`Workflow`ClaudeSubmitToken;
    stepWf = ClaudeOrchestrator`Workflow`ClaudeStepWorkflow;
    wid = Quiet@Check[createNet[WNet[
        "SourcePlace" -> "In", "FinalPlaces" -> {"Out"},
        "Places" -> <|"In" -> WPlace["In", "AcceptedKinds" -> All],
          "Slots" -> WPlace["Slots", "AcceptedKinds" -> All],
          "Out" -> WPlace["Out", "AcceptedKinds" -> All]|>,
        "Transitions" -> <|"Run" -> WTrans["Run",
          "InputArcs" -> {<|"Place" -> "In", "Multiplicity" -> 1|>,
            <|"Place" -> "Slots", "Multiplicity" -> 1|>},
          "OutputArcs" -> {<|"Place" -> "Out", "Multiplicity" -> 1|>,
            <|"Place" -> "Slots", "Multiplicity" -> 1|>},
          "Executor" -> "External",
          "RuntimeSpec" -> <|"Timeout" -> iSVCFJobTimeout[],
            "ExecutorOptions" -> <|"Backend" -> "ComfyUI", "Handler" -> "ComfyUIPrompt",
              "NotifyNotebook" -> OptionValue["NotifyNotebook"]|>|>]|>]], $Failed];
    If[! StringQ[wid], Return[<|"Status" -> "Error", "Reason" -> "NetCreateFailed"|>]];
    (* launcher が wid で引けるよう rendered workflow を pending に積む *)
    $iSVCFPendingJobs[wid] = <|"Workflow" -> rendered["Workflow"], "PrivacyLevel" -> pl,
      "WorkflowName" -> Lookup[rendered, "Name", Missing[]], "Request" -> vars|>;
    submitTok[wid, WTok["Kind" -> "Task", "Payload" -> <|"Provider" -> "comfyui",
      "WorkflowName" -> Lookup[rendered, "Name", Missing[]]|>]];
    submitTok[wid, WTok["Kind" -> "Slot"], "Slots"];
    Quiet@Check[stepWf[wid], $Failed];
    (* stepWf 後にライブの $iWorkflowNets を読む (スナップショットにしない)。
       External 分岐が AwaitingLLMTransitions[awaitId] を登録済みのはず。 *)
    awaiting = Quiet@Check[
      Lookup[Lookup[ClaudeOrchestrator`Workflow`Private`$iWorkflowNets, wid, <||>],
        "AwaitingLLMTransitions", <||>], <||>];
    If[! AssociationQ[awaiting] || Length[awaiting] === 0,
      $iSVCFPendingJobs = KeyDrop[$iSVCFPendingJobs, wid];
      Return[<|"Status" -> "Error", "Reason" -> "ExternalLaunchNotAwaiting", "WorkflowId" -> wid|>]];
    meta = Lookup[First[Values[awaiting]], "PartialPayload", <||>];
    pid = Lookup[meta, "JobID", Missing[]];
    <|"Status" -> "Queued", "Provider" -> iSVCFProvider[], "WorkflowId" -> wid,
      "PromptId" -> pid, "JobId" -> pid, "Awaiting" -> True|>];

(* ============================================================
   SourceVaultComfyUIGenerate -- provider 専用 entry point
   ============================================================ *)

iSVCFSpecVars[spec_Association] :=
  Module[{vars = <|"Prompt" -> Lookup[spec, "Prompt", ""],
      "NegativePrompt" -> Lookup[spec, "NegativePrompt", ""],
      "Seed" -> iSVCFResolveSeed[Lookup[spec, "Seed", Automatic]]|>},
    If[IntegerQ[Lookup[spec, "Width", Missing[]]], vars["Width"] = spec["Width"]];
    If[IntegerQ[Lookup[spec, "Height", Missing[]]], vars["Height"] = spec["Height"]];
    vars];

Options[SourceVaultComfyUIGenerate] = {"Mode" -> "BuildJobSpec", "PrivacyLevel" -> Automatic,
  "NotifyNotebook" -> None};
SourceVaultComfyUIGenerate[spec_Association, OptionsPattern[]] :=
  Module[{mode = OptionValue["Mode"], wfName},
    wfName = Lookup[Lookup[spec, "ProviderOptions", <||>], "Workflow", Missing[]];
    Switch[mode,
      "BuildJobSpec", SourceVaultComfyUIBuildJobSpec[spec],
      "Async",
        If[! StringQ[wfName], Return[<|"Status" -> "Error", "Reason" -> "NoWorkflowForSpec"|>]];
        SourceVaultComfyUISubmitExternal[wfName, iSVCFSpecVars[spec],
          "PrivacyLevel" -> Replace[OptionValue["PrivacyLevel"], Automatic :> iSVCFComputePrivacy[spec]],
          "NotifyNotebook" -> OptionValue["NotifyNotebook"]],
      "DebugSync",
        If[! StringQ[wfName], Return[<|"Status" -> "Error", "Reason" -> "NoWorkflowForSpec"|>]];
        SourceVaultComfyUIRunWorkflow[wfName, iSVCFSpecVars[spec]],
      _, <|"Status" -> "Error", "Reason" -> "BadMode", "Mode" -> mode|>]];

End[];  (* `Private` *)

EndPackage[];

(* ============================================================
   $ClaudePackageAuxKeywordMap への登録 (api_comfyui.md 自動注入の足場)
   ============================================================ *)
If[AssociationQ[ClaudeCode`$ClaudePackageAuxKeywordMap],
  Module[{auxMap},
    auxMap = Lookup[ClaudeCode`$ClaudePackageAuxKeywordMap, "SourceVault", <||>];
    If[! AssociationQ[auxMap], auxMap = <||>];
    auxMap["comfyui"] = {
      "ComfyUI", "コンフィ", "SourceVaultComfyUI",
      "画像生成", "動画生成", "image generation", "video generation",
      "workflow", "ControlNet", "img2img", "SDXL"};
    ClaudeCode`$ClaudePackageAuxKeywordMap["SourceVault"] = auxMap]];

(* orchestrator backend dispatch が既にロード済みなら ComfyUI backend を登録 (冪等)。
   未ロードなら何もしない (SubmitExternal が呼ばれた時に登録される)。 *)
Quiet@Check[
  If[TrueQ[Quiet@Check[
        Length[DownValues[ClaudeOrchestrator`Workflow`ClaudeRegisterExternalBackend]] > 0, False]],
    SourceVault`SourceVaultComfyUIRegisterBackend[]], Null];

If[!TrueQ[$SourceVaultComfyUIQuietLoad],
  Print[Style["SourceVault_comfyui パッケージがロードされました。", Bold]];
  Print["
  SourceVaultComfyUIStatus[]                       → ComfyUI server 状態 (Offline 時も静か)
  SourceVaultComfyUIRegisterWorkflow[name, apiJson] → API format workflow 登録
  SourceVaultComfyUIRunWorkflow[name, vars]         → 同期 debug 実行 (非 FE 用)
  SourceVaultComfyUIBuildJobSpec[spec]              → jobSpec 構築 (純関数 / in-workflow helper)
  SourceVaultComfyUIGenerate[spec, \"Mode\"->...]     → provider entry (BuildJobSpec/DebugSync/Async)
  (非ブロック投入 SubmitExternal は Phase 0.5 backend dispatch 後に有効化)
"]];
