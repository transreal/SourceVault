(* ::Package:: *)

(* ============================================================
   session_impl_worker.wls  (SourceVault_workflows/spec-impl)

   RuntimeSession episode worker for the palette "spec implementation"
   flow (IncE worker seam of ClaudeRuntime_sessionrunner.wl).

   拡張子が .wls なのは workflow レジストリ対策: iSVWFMainFile は slug
   フォルダ内の Sort 順最初の *.wl を workflow 本体として Get するため、
   補助 .wl を置くと SourceVaultLoadWorkflow["spec-impl"] が壊れる
   (palette_impl_driver.wls と同じ理由)。Get は .wls でも問題なく働く。
   palette_impl_driver.wls と同じ実装ループ (RunSpecImpl) を、外部
   wolframscript 子プロセスの ClaudeRunSessionFromSpool worker mode で
   実行し、進捗は従来どおり ProgressFile (routine telemetry)、完了は
   ArtifactProposed control event + result.wl (legacy 互換) で返す。

   設計: ClaudeOrchestrator_info/design/
         claude_orchestrator_specimpl_session_migration_v0_1.md §3

   呼び出し契約 (ctx は sessionrunner の iRunnerWorkerContext):
     SpecImplEpisodeWorker[ctx]
       ctx["Manifest"]["GoalRef"] = config.wl のパス
         (palette_impl_driver.wls と同一フォーマット。追加キー不要)
       ctx["Emit"][type, payloadRefs] で control event を emit
   terminal 契約:
     - 成功 (result Status=="Done"): result を staging に WXF 化し
       ArtifactProposed を emit (episode の terminal 化は orchestrator の
       ValidateArtifact→CommitArtifact→FinalizeCommittedArtifact が行う)
     - 失敗: result.wl を書いた上で Failed を emit (ResultRef 付き)
     - 開始前に Cancel command を検出したら ack + Cancelled を emit
   ============================================================ *)

BeginPackage["SourceVaultWorkflow`SpecImplSession`"];

SpecImplEpisodeWorker::usage =
  "SpecImplEpisodeWorker[ctx] は spec-impl の implement<->verify ループを\n" <>
  "RuntimeSession episode worker として実行する。ctx は\n" <>
  "ClaudeRunSessionFromSpool (worker mode) が渡す protocol context。\n" <>
  "config は ctx[\"Manifest\"][\"GoalRef\"] の config.wl\n" <>
  "(palette_impl_driver.wls と同一フォーマット) から読む。";

Begin["`Private`"];

iRead[p_] := Quiet @ Check[
  ByteArrayToString[ReadByteArray[p], "UTF-8"], ""];

(* 失敗 event の payload に載せる要約 (本文は ref のみ = I4) *)
iFailPayload[reason_, resultFile_] :=
  <|"Reason" -> ToString[reason],
    "ResultRef" -> If[StringQ[resultFile], resultFile, None]|>;

(* 実行済み/構築済み net の構造+marking (token 件数のみ) を可搬な連想に
   落とす。FE がモジュール追加なしで Petri net 図を描くためのデータ
   (token 本文は巨大 payload になりうるので載せない)。
   net が取れない環境では None (表示は単にスキップされる)。 *)
(* 注意: main 定義は必ず型付きパターンにする。無型 f[summary_] の後に
   f[_]:=None を定義すると、WL はパターン名だけ違う定義を同一視して
   main 定義を置換してしまう (常に None になる罠。T5 で実測)。 *)
iNetStructureFromWid[wid_String] := Module[{net, marking},
  net = Quiet[ClaudeOrchestrator`Workflow`Private`$iWorkflowNets[wid]];
  If[! (AssociationQ[net] && KeyExistsQ[net, "Places"]), Return[None]];
  marking = Quiet @ Check[
    Lookup[ClaudeOrchestrator`Workflow`ClaudeWorkflowState[wid],
      "Marking", <||>], <||>];
  If[! AssociationQ[marking], marking = <||>];
  <|"Places" -> Keys @ Lookup[net, "Places", <||>],
    "SourcePlace" -> Lookup[net, "SourcePlace", ""],
    "FinalPlaces" -> Cases[Lookup[net, "FinalPlaces", {}], _String],
    "Transitions" -> Map[
      Function[tdef, <|
        "In" -> Cases[
          Map[Lookup[#, "Place"] &, Lookup[tdef, "InputArcs", {}]],
          _String],
        "Out" -> Cases[
          Map[Lookup[#, "Place"] &, Lookup[tdef, "OutputArcs", {}]],
          _String]|>],
      Lookup[net, "Transitions", <||>]],
    "Marking" -> Select[
      Map[If[ListQ[#], Length[#], 0] &, marking], # > 0 &]|>];
iNetStructureFromWid[_] := None;

iNetStructureOf[summary_Association] :=
  iNetStructureFromWid[Lookup[summary, "WorkflowId", ""]];
iNetStructureOf[_] := None;

(* 生成されたワークフロー自身が Petri net 型 (公開 BuildNet を持つ layer-2
   codified workflow) の場合に限り、その net 構造を返す。普通の関数
   パッケージ (WorkflowInfo + launch 関数のみ) は None = FE は図を出さない
   (ユーザー指定)。BuildNet 呼び出しは best-effort (Quiet+TimeConstrained)。 *)
iGeneratedNetStructure[slug_String, name_String] := Module[
  {loadRes, ctx, bn, wid},
  loadRes = Quiet @ Check[
    SourceVault`SourceVaultLoadWorkflow[slug], $Failed];
  If[! (AssociationQ[loadRes] &&
        MemberQ[{"Loaded", "AlreadyLoaded"},
          Lookup[loadRes, "Status", ""]]), Return[None]];
  ctx = Lookup[loadRes, "Context", ""];
  If[! StringQ[ctx] || ctx === "" ||
     Names[ctx <> "BuildNet"] === {}, Return[None]];
  bn = Symbol[ctx <> "BuildNet"];
  If[! (MatchQ[bn, _Symbol] && With[{s = bn}, DownValues[s]] =!= {}),
    Return[None]];
  wid = Quiet @ Check[TimeConstrained[bn[name], 30, $Failed], $Failed];
  If[! StringQ[wid], Return[None]];
  iNetStructureFromWid[wid]];
iGeneratedNetStructure[___] := None;

SpecImplEpisodeWorker[ctx_Association] :=
  Module[{manifest, emit, cfgFile, cfg, name, notesText, specText,
          specRef, progressFile, resultFile, pkgRoot, slug, targetDir,
          langInstr, loadRes, runFn, planFn, reviewFn, reviseFn, implFn,
          verifyFn, mockPlan, mockReview, mockRevise, mockImpl,
          mockVerify, err = "", summary, wfSummary, specForSum, result,
          stagingRoot, artifactPath, cand, wellFormed},
    manifest = Lookup[ctx, "Manifest", <||>];
    emit = Lookup[ctx, "Emit", Function[{t, p}, Null]];

    (* ---- config (legacy config.wl と同一) ---- *)
    cfgFile = Lookup[manifest, "GoalRef", None];
    cfg = If[StringQ[cfgFile] && FileExistsQ[cfgFile],
      Quiet @ Check[Get[cfgFile], $Failed], $Failed];
    If[!AssociationQ[cfg],
      emit["Failed", iFailPayload["BadConfig", None]];
      Return[<|"Status" -> "Failed", "Reason" -> "BadConfig"|>]];
    resultFile = Lookup[cfg, "ResultFile", "result.wl"];

    (* ---- 開始前 cancel チェック ---- *)
    If[TrueQ[Quiet @ Check[ctx["CancelRequestedQ"][], False]],
      Module[{cmds = Quiet @ Check[ctx["PollCommands"][], {}]},
        Scan[
          Function[c,
            If[Lookup[c, "Type", None] === "Cancel",
              Quiet @ Check[
                ctx["AckCommand"][Lookup[c, "CommandId", "?"]], Null]]],
          If[ListQ[cmds], cmds, {}]]];
      emit["Cancelled", <|"Reason" -> "CancelledBeforeStart"|>];
      Return[<|"Status" -> "Cancelled"|>]];

    (* ---- FE kernel の $Language を継承 ---- *)
    With[{lg = Lookup[cfg, "Language", None]},
      If[StringQ[lg] || (ListQ[lg] && AllTrue[lg, StringQ]),
        $Language = lg]];
    langInstr = With[{li = Lookup[cfg, "LanguageInstruction", ""]},
      If[StringQ[li], li, ""]];

    name = Lookup[cfg, "Name", "workflow"];
    notesText = With[{nf = Lookup[cfg, "NotesFile", ""]},
      If[StringQ[nf] && nf =!= "" && FileExistsQ[nf], iRead[nf], ""]];
    specText = With[{s = Lookup[cfg, "SpecText", ""]},
      If[StringQ[s], s, ""]];
    specRef = With[{r = Lookup[cfg, "SpecRef", ""]},
      If[StringQ[r], r, ""]];
    progressFile = Lookup[cfg, "ProgressFile", None];

    pkgRoot = With[{r = Lookup[cfg, "PackageRoot", Automatic]},
      Which[
        StringQ[r] && r =!= "", r,
        StringQ[$InputFileName] && $InputFileName =!= "",
          DirectoryName[$InputFileName, 3],
        True, "F:/Dropbox/Mathematica-oneDrive/MyPackages"]];
    slug = Lookup[cfg, "WorkflowSlug", "spec-impl"];
    targetDir = With[{td = Lookup[cfg, "TargetDir", ""]},
      If[StringQ[td] && td =!= "", td,
        FileNameJoin[{pkgRoot, "SourceVault_workflows", "testing",
          name}]]];

    (* ---- early progress ---- *)
    Quiet @ Check[
      If[StringQ[progressFile],
        Put[<|"Phase" -> "Starting", "Role" -> "", "Model" -> "",
          "Stage" -> "(single)", "StageIndex" -> 1, "NumStages" -> 1,
          "Round" -> 1, "Verdict" -> "",
          "Message" -> "loading workflow (session)",
          "UpdatedAtUTC" -> ""|>, progressFile]], Null];

    (* ---- SourceVault + spec-impl workflow を on-demand ロード ---- *)
    Block[{$CharacterEncoding = "UTF-8"},
      Quiet @ Check[Get[FileNameJoin[{pkgRoot, "SourceVault.wl"}]],
        Null]];
    With[{vr = Lookup[cfg, "VaultRoot", None]},
      If[StringQ[vr], SourceVault`$SourceVaultCoreRoot = vr]];
    loadRes = Quiet @ Check[
      SourceVault`SourceVaultLoadWorkflow[slug], $Failed];
    If[!(AssociationQ[loadRes] &&
         MemberQ[{"Loaded", "AlreadyLoaded"},
           Lookup[loadRes, "Status", ""]]),
      Quiet @ Check[
        Put[<|"Status" -> "Error", "Error" -> "WorkflowLoadFailed",
          "FinalStatus" -> "Unknown", "Name" -> name|>, resultFile],
        Null];
      emit["Failed", iFailPayload["WorkflowLoadFailed", resultFile]];
      Return[<|"Status" -> "Failed",
        "Reason" -> "WorkflowLoadFailed"|>]];
    runFn = Symbol[Lookup[loadRes, "Context",
      "SourceVaultWorkflow`SpecImpl`"] <> "RunSpecImpl"];
    With[{ctl = Lookup[cfg, "CallTimeLimitSeconds", None]},
      If[IntegerQ[ctl] && ctl > 0,
        Quiet @ Check[
          SourceVaultWorkflow`SpecImpl`Private`$iOrchCallTimeLimit = ctl,
          Null]]];

    (* ---- mock executors (headless テスト用。legacy driver と同一) ---- *)
    mockPlan = Function[{model, pl},
      With[{multi = TrueQ[Lookup[pl, "MockMulti", False]]},
        <|"Multi" -> multi,
          "Stages" -> If[multi, {"stage A", "stage B"}, {"(single)"}],
          "AuxSpec" ->
            If[multi, "# MOCK PLAN\n- stage A\n- stage B", ""]|>]];
    mockReview = Function[{model, pl, aux},
      <|"Verdict" -> "Approved", "Findings" -> "[]",
        "ReviewText" -> "mock plan ok"|>];
    mockRevise = Function[{model, pl, aux, fb},
      <|"AuxSpec" -> aux,
        "Stages" -> Lookup[pl, "Stages", {"(single)"}]|>];
    (* launch 名は System`Run と衝突させない (Run[]:=42 は System`Run に
       DownValue が付き、Symbol[ctx<>"Run"] が未定義→動的ゲート blocker
       になる legacy 由来のバグ)。usage 宣言済みの公開 symbol にする *)
    mockImpl = Function[{model, pl},
      With[{canon = Lookup[pl, "Canon", "Mock"],
            idx = Lookup[pl, "StageIndex", 1]},
        <|"Files" -> <|
            "SVWorkflow_" <> canon <> ".wl" ->
              "(* mock *)\nBeginPackage[\"SourceVaultWorkflow`" <>
              canon <> "`\"]\n" <>
              "WorkflowInfo::usage=\"x\";\nLaunchMock::usage=\"x\";\n" <>
              "Begin[\"`Private`\"]\n" <>
              "WorkflowInfo[]:=<|\"Slug\"->\"mock\",\"Launch\"->\"LaunchMock\",\"Stage\"->" <>
              ToString[idx] <> "|>;\n" <>
              "LaunchMock[]:=42;\nEnd[]\nEndPackage[]\n",
            "SVWorkflow_" <> canon <> "_info/docs/examples/example.md" ->
              "# mock example stage " <> ToString[idx] <> "\n"|>|>]];
    mockVerify = Function[{model, pl, filesText},
      <|"Verdict" -> "Approved", "Findings" -> "[]",
        "ReviewText" -> "mock verify ok"|>];
    If[TrueQ[Lookup[cfg, "MockMode", False]],
      planFn = mockPlan; reviewFn = mockReview; reviseFn = mockRevise;
      implFn = mockImpl; verifyFn = mockVerify,
      planFn = Automatic; reviewFn = Automatic; reviseFn = Automatic;
      implFn = Automatic; verifyFn = Automatic];

    (* ---- 本体: implement <-> verify ループ ---- *)
    summary = Quiet @ Check[
      runFn[name,
        "Spec" -> If[specRef =!= "", specRef, specText],
        "SpecRef" -> specRef,
        "Notes" -> notesText,
        "PackageRoot" -> pkgRoot,
        "TargetDir" -> targetDir,
        "LanguageInstruction" -> langInstr,
        "ClaudeModel" -> Lookup[cfg, "ClaudeModel", Automatic],
        "AdvisaryModel" -> Lookup[cfg, "AdvisaryModel", Automatic],
        "MaxRounds" -> Lookup[cfg, "MaxRounds", 3],
        "MaxAuxRounds" -> Lookup[cfg, "MaxAuxRounds", 3],
        "ProgressFile" -> progressFile,
        "PlanFunction" -> planFn, "PlanReviewFunction" -> reviewFn,
        "PlanReviseFunction" -> reviseFn,
        "ImplementFunction" -> implFn, "VerifyFunction" -> verifyFn,
        "InitialState" -> If[TrueQ[Lookup[cfg, "MockMulti", False]],
          <|"MockMulti" -> True|>, <||>],
        "MaxWait" -> Quantity[Lookup[cfg, "MaxWaitSeconds", 2400],
          "Seconds"]],
      err = "RunSpecImpl failed"; <||>];

    (* ---- workflow-catalog 用の背景要約 (legacy と同一) ---- *)
    wfSummary = <|"Summary" -> "", "Keywords" -> {}, "Method" -> ""|>;
    If[AssociationQ[summary] && summary =!= <||> &&
       Length[Names["SourceVault`SourceVaultWorkflowSummarizeText"]] > 0,
      specForSum = specText;
      If[StringTrim[specForSum] === "" && specRef =!= "",
        specForSum = Quiet @ Check[
          Lookup[SourceVault`SourceVaultLoadImmutableSnapshot[specRef],
            "Text", ""], ""]];
      If[StringQ[specForSum] && StringTrim[specForSum] =!= "",
        wfSummary = Quiet @ Check[
          SourceVault`SourceVaultWorkflowSummarizeText[specForSum,
            Lookup[cfg, "ClaudeModel", ""],
            Lookup[cfg, "AdvisaryModel", ""],
            "Language" -> Lookup[cfg, "Language", "Japanese"]],
          <|"Summary" -> "", "Keywords" -> {}, "Method" -> ""|>]]];

    (* ---- result (legacy result.wl と同一キー) ----
       FinalStatus "Unknown" = ループが最終 place に到達しないまま
       ClaudeRunWorkflow が戻った (典型は MaxWait 時間切れ)。抜け殻 summary
       を Done と報告しない (fail-closed)。 *)
    If[AssociationQ[summary] && summary =!= <||> &&
       Lookup[summary, "FinalStatus", "Unknown"] === "Unknown" && err === "",
      err = "implement<->verify loop did not reach a final state" <>
        " (RunStatus: " <> ToString @ Lookup[summary, "RunStatus", "?"] <>
        ", Termination: " <> ToString @ Lookup[summary, "Termination", "?"] <>
        "). Likely MaxWait (" <>
        ToString @ Lookup[cfg, "MaxWaitSeconds", 2400] <>
        "s) exhausted; raise MaxWaitSeconds or reduce rounds."];
    result = <|
      "Status" -> If[AssociationQ[summary] && summary =!= <||> &&
          err === "", "Done", "Error"],
      "Error" -> err,
      "Name" -> name,
      "TargetDir" -> targetDir,
      "Summary" -> Lookup[wfSummary, "Summary", ""],
      "Keywords" -> Lookup[wfSummary, "Keywords", {}],
      "SummaryMethod" -> Lookup[wfSummary, "Method", ""],
      "FinalStatus" -> Lookup[summary, "FinalStatus", "Unknown"],
      "BlockReason" -> ToString @ Lookup[summary, "BlockReason", ""],
      "Multi" -> TrueQ[Lookup[summary, "Multi", False]],
      "Stages" -> Lookup[summary, "Stages", {}],
      "Rounds" -> Lookup[summary, "Rounds", Missing[]],
      "FinalVerdict" -> Lookup[summary, "FinalVerdict", Missing[]],
      "GeneratedFiles" -> Lookup[summary, "GeneratedFiles", {}],
      "ImplModel" -> ToString @ Lookup[summary, "ImplModel", ""],
      "VerifyModel" -> ToString @ Lookup[summary, "VerifyModel", ""],
      "PlanURI" -> ToString @ Lookup[summary, "PlanURI", ""],
      "ArtifactURI" -> ToString @ Lookup[summary, "ArtifactURI", ""],
      "VerifyURI" -> ToString @ Lookup[summary, "VerifyURI", ""],
      "PlanChain" -> Lookup[summary, "PlanChain", {}],
      "ArtifactChain" -> Lookup[summary, "ArtifactChain", {}],
      "VerifyChain" -> Lookup[summary, "VerifyChain", {}],
      (* 実行した implement<->verify net の構造+最終 marking (データのみ。
         FE は表示しない = デバッグ/将来用) *)
      "NetStructure" -> Quiet @ Check[iNetStructureOf[summary], None],
      (* 生成ワークフロー自身の net (net 型 layer-2 の場合のみ。普通の
         関数パッケージは None → FE は図を出さない) *)
      "WorkflowNetStructure" -> Quiet @ Check[
        If[err === "", iGeneratedNetStructure[name, name], None], None]|>;
    (* legacy 互換 + 失敗時の詳細参照先として常に書く *)
    Quiet @ Check[Put[result, resultFile], Null];

    (* ---- 失敗は Failed event で fail-closed ---- *)
    If[result[["Status"]] =!= "Done",
      emit["Failed",
        iFailPayload[
          If[err =!= "", err, Lookup[result, "FinalStatus", "Unknown"]],
          resultFile]];
      Return[<|"Status" -> "Failed", "Reason" -> err|>]];

    (* ---- 成功: staging に WXF 化して ArtifactProposed ---- *)
    stagingRoot = DirectoryName[resultFile];
    artifactPath = FileNameJoin[{stagingRoot, "artifact-result.wxf"}];
    Quiet @ Check[Export[artifactPath, result, "WXF"], Null];
    wellFormed = FileExistsQ[artifactPath] &&
      StringQ[Lookup[result, "Name", None]] &&
      StringQ[Lookup[result, "TargetDir", None]];
    If[!wellFormed,
      emit["Failed", iFailPayload["ArtifactStagingFailed", resultFile]];
      Return[<|"Status" -> "Failed",
        "Reason" -> "ArtifactStagingFailed"|>]];
    cand = <|
      "ArtifactId" -> ctx["NewId"]["art"],
      "SessionId" -> Lookup[manifest, "SessionId", "ses-unknown"],
      "EpisodeId" -> Lookup[manifest, "EpisodeId", "epi-unknown"],
      "ArtifactType" -> "SpecImplResult",
      "ArtifactRef" -> artifactPath,
      "ManifestRef" -> None,
      "ContentHash" -> ctx["CanonicalHash"][result],
      "ByteCount" -> FileByteCount[artifactPath],
      "OutputSchemaVersion" -> 1,
      "PrivacyLabel" -> 1.0,
      "Provenance" -> <|
        "InputRefs" -> Select[{specRef}, # =!= "" &],
        "ToolJournalRef" -> None,
        "Model" -> Lookup[result, "ImplModel", ""],
        "RuntimeTraceRef" -> None|>,
      "SelfChecks" -> <|"ResultWellFormed" -> True|>,
      "BaseRevision" -> None|>;
    emit["ArtifactProposed", <|"ArtifactCandidate" -> cand|>];
    <|"Status" -> "WorkerDone",
      "FinalStatus" -> Lookup[result, "FinalStatus", "Unknown"]|>
  ];

End[];

EndPackage[];
