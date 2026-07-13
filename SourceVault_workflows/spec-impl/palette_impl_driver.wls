#!/usr/bin/env wolframscript
(* ============================================================
   palette_impl_driver.wls  (SourceVault_workflows/spec-impl)

   Background driver for the palette "spec implementation" flow.
   Runs the full implement<->verify loop
   (SourceVaultWorkflow`SpecImpl`RunSpecImpl) from an approved spec, generating
   a codified SVWorkflow_<Name> package under SourceVault_workflows/<name>/,
   then writes a result file the FE kernel polls. Heavy work (claude/codex,
   minutes) runs HERE, off the FE.

   The workflow is loaded ON DEMAND through the SourceVault registry
   (SourceVault`SourceVaultLoadWorkflow["spec-impl"]); no hard-coded path.

   While running, the driver updates a PROGRESS file at every transition so the
   FE poller can show the running model + phase in the WindowStatusArea.

   Usage: wolframscript -file palette_impl_driver.wls <configFile>
   configFile is a WL Association (Put/Get) with keys:
     "Name", "SpecRef" (sv:// / snapshot ref) OR "SpecText", "NotesFile",
     "ClaudeModel", "AdvisaryModel", "MaxRounds", "MaxAuxRounds",
     "ProgressFile", "ResultFile", "PackageRoot", "WorkflowSlug",
     "VaultRoot"(optional), "MockMode"(optional True),
     "Language", "LanguageInstruction"
   ============================================================ *)

Block[{$CharacterEncoding = "UTF-8"},
  Module[{cfgFile, cfg, name, notesText, specText, specRef, err = "",
          mockPlan, mockReview, mockRevise, mockImpl, mockVerify,
          planFn, reviewFn, reviseFn, implFn, verifyFn,
          pkgRoot, slug, loadRes, runFn, langInstr, targetDir, summary, progressFile,
          wfSummary, specForSum, netStruct, wfNetStruct, iNetFromWid},

    cfgFile = If[Length[$ScriptCommandLine] >= 2, $ScriptCommandLine[[2]], ""];
    cfg = Quiet @ Check[Get[cfgFile], $Failed];
    If[! AssociationQ[cfg],
      Print["BAD CONFIG: ", cfgFile]; Exit[1]];

    (* ---- inherit the FE kernel's $Language ---- *)
    With[{lg = Lookup[cfg, "Language", None]},
      If[StringQ[lg] || (ListQ[lg] && AllTrue[lg, StringQ]), $Language = lg]];
    langInstr = With[{li = Lookup[cfg, "LanguageInstruction", ""]},
      If[StringQ[li], li, ""]];

    iRead[p_] := Quiet @ Check[ByteArrayToString[ReadByteArray[p], "UTF-8"], ""];
    iWrite[p_, s_] := Module[{st = OpenWrite[p, BinaryFormat -> True]},
      BinaryWrite[st, StringToByteArray[If[StringQ[s], s, ""], "UTF-8"]]; Close[st]];

    name = Lookup[cfg, "Name", "workflow"];
    notesText = With[{nf = Lookup[cfg, "NotesFile", ""]},
      If[StringQ[nf] && nf =!= "" && FileExistsQ[nf], iRead[nf], ""]];
    specText = With[{s = Lookup[cfg, "SpecText", ""]}, If[StringQ[s], s, ""]];
    specRef  = With[{r = Lookup[cfg, "SpecRef", ""]}, If[StringQ[r], r, ""]];
    progressFile = Lookup[cfg, "ProgressFile", None];

    (* ---- resolve package root ---- *)
    pkgRoot = With[{r = Lookup[cfg, "PackageRoot", Automatic]},
      Which[
        StringQ[r] && r =!= "", r,
        StringQ[$InputFileName] && $InputFileName =!= "",
          DirectoryName[$InputFileName, 3],
        True, "F:/Dropbox/Mathematica-oneDrive/MyPackages"]];
    slug = Lookup[cfg, "WorkflowSlug", "spec-impl"];
    (* generated workflows go under the "testing" stage (テスト中); the FE passes
       an explicit TargetDir, but fall back to the testing stage folder. *)
    targetDir = With[{td = Lookup[cfg, "TargetDir", ""]},
      If[StringQ[td] && td =!= "", td,
        FileNameJoin[{pkgRoot, "SourceVault_workflows", "testing", name}]]];

    (* ---- early progress: starting ---- *)
    Quiet @ Check[
      If[StringQ[progressFile],
        Put[<|"Phase" -> "Starting", "Role" -> "", "Model" -> "",
          "Stage" -> "(single)", "StageIndex" -> 1, "NumStages" -> 1, "Round" -> 1,
          "Verdict" -> "", "Message" -> "loading workflow",
          "UpdatedAtUTC" -> ""|>, progressFile]], Null];

    (* ---- load SourceVault (registry + snapshot ops) ---- *)
    Block[{$CharacterEncoding = "UTF-8"},
      Get[FileNameJoin[{pkgRoot, "SourceVault.wl"}]]];
    With[{vr = Lookup[cfg, "VaultRoot", None]},
      If[StringQ[vr], SourceVault`$SourceVaultCoreRoot = vr]];

    (* ---- on-demand load of the workflow (self-bootstraps ClaudeOrchestrator) ---- *)
    loadRes = Quiet @ Check[SourceVault`SourceVaultLoadWorkflow[slug], $Failed];
    If[! (AssociationQ[loadRes] &&
          MemberQ[{"Loaded", "AlreadyLoaded"}, Lookup[loadRes, "Status", ""]]),
      Print["WORKFLOW LOAD FAILED: ", slug, "  ", loadRes];
      Put[<|"Status" -> "Error", "Error" -> "WorkflowLoadFailed",
        "FinalStatus" -> "Unknown", "Name" -> name|>, Lookup[cfg, "ResultFile", "result.wl"]];
      Exit[1]];

    runFn = Symbol[Lookup[loadRes, "Context", "SourceVaultWorkflow`SpecImpl`"] <> "RunSpecImpl"];

    (* optional: tune the per-LLM-call wall-clock cap (a stuck external CLI call
       is killed after this many seconds instead of blocking the driver). *)
    With[{ctl = Lookup[cfg, "CallTimeLimitSeconds", None]},
      If[IntegerQ[ctl] && ctl > 0,
        Quiet @ Check[
          SourceVaultWorkflow`SpecImpl`Private`$iOrchCallTimeLimit = ctl, Null]]];

    (* ---- mock executors (for headless tests) ---- *)
    mockPlan = Function[{model, pl},
      With[{multi = TrueQ[Lookup[pl, "MockMulti", False]]},
        <|"Multi" -> multi,
          "Stages" -> If[multi, {"stage A", "stage B"}, {"(single)"}],
          "AuxSpec" -> If[multi, "# MOCK PLAN\n- stage A\n- stage B", ""]|>]];
    mockReview = Function[{model, pl, aux},
      <|"Verdict" -> "Approved", "Findings" -> "[]", "ReviewText" -> "mock plan ok"|>];
    mockRevise = Function[{model, pl, aux, fb},
      <|"AuxSpec" -> aux, "Stages" -> Lookup[pl, "Stages", {"(single)"}]|>];
    (* launch 名は System`Run と衝突させない (Run[]:=42 は System`Run に
       DownValue が付き、Symbol[ctx<>"Run"] が未定義→動的ゲート blocker)。
       session_impl_worker.wls の mock と同一に保つ *)
    mockImpl = Function[{model, pl},
      With[{canon = Lookup[pl, "Canon", "Mock"], idx = Lookup[pl, "StageIndex", 1]},
        <|"Files" -> <|
            "SVWorkflow_" <> canon <> ".wl" ->
              "(* mock *)\nBeginPackage[\"SourceVaultWorkflow`" <> canon <> "`\"]\n" <>
              "WorkflowInfo::usage=\"x\";\nLaunchMock::usage=\"x\";\nBegin[\"`Private`\"]\n" <>
              "WorkflowInfo[]:=<|\"Slug\"->\"mock\",\"Launch\"->\"LaunchMock\",\"Stage\"->" <> ToString[idx] <> "|>;\n" <>
              "LaunchMock[]:=42;\nEnd[]\nEndPackage[]\n",
            "SVWorkflow_" <> canon <> "_info/docs/examples/example.md" ->
              "# mock example stage " <> ToString[idx] <> "\n"|>|>]];
    mockVerify = Function[{model, pl, filesText},
      <|"Verdict" -> "Approved", "Findings" -> "[]", "ReviewText" -> "mock verify ok"|>];

    If[TrueQ[Lookup[cfg, "MockMode", False]],
      planFn = mockPlan; reviewFn = mockReview; reviseFn = mockRevise;
      implFn = mockImpl; verifyFn = mockVerify,
      planFn = Automatic; reviewFn = Automatic; reviseFn = Automatic;
      implFn = Automatic; verifyFn = Automatic];

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
        "InitialState" -> If[TrueQ[Lookup[cfg, "MockMulti", False]], <|"MockMulti" -> True|>, <||>],
        "MaxWait" -> Quantity[Lookup[cfg, "MaxWaitSeconds", 2400], "Seconds"]],
      err = "RunSpecImpl failed"; <||>];

    (* ---- background workflow-catalog summary (両モデルがローカルならローカル LLM、
       そうでなければクラウド) -- 重い LLM 呼び出しはこの背景カーネルで行い FE を凍らせない ---- *)
    wfSummary = <|"Summary" -> "", "Keywords" -> {}, "Method" -> ""|>;
    If[AssociationQ[summary] && summary =!= <||> &&
       Length[Names["SourceVault`SourceVaultWorkflowSummarizeText"]] > 0,
      specForSum = specText;
      If[StringTrim[specForSum] === "" && specRef =!= "",
        specForSum = Quiet @ Check[
          Lookup[SourceVault`SourceVaultLoadImmutableSnapshot[specRef], "Text", ""], ""]];
      If[StringQ[specForSum] && StringTrim[specForSum] =!= "",
        wfSummary = Quiet @ Check[
          SourceVault`SourceVaultWorkflowSummarizeText[specForSum,
            Lookup[cfg, "ClaudeModel", ""], Lookup[cfg, "AdvisaryModel", ""],
            "Language" -> Lookup[cfg, "Language", "Japanese"]],
          <|"Summary" -> "", "Keywords" -> {}, "Method" -> ""|>]]];

    (* net 構造の抽出 (session_impl_worker.wls の iNetStructureFromWid と
       同一ロジック。token 本文は載せず件数のみ)。 *)
    iNetFromWid[wid_String] := Module[{net, marking},
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
    iNetFromWid[___] := None;

    (* 実行した implement<->verify net (データのみ。FE は表示しない) *)
    netStruct = Quiet @ Check[
      If[AssociationQ[summary],
        iNetFromWid[Lookup[summary, "WorkflowId", ""]], None], None];

    (* 生成ワークフロー自身の net (net 型 layer-2 = 公開 BuildNet を持つ
       場合のみ。普通の関数パッケージは None → FE は図を出さない)。 *)
    wfNetStruct = Quiet @ Check[
      Module[{lr, wctx, bn, wwid},
        lr = Quiet @ Check[SourceVault`SourceVaultLoadWorkflow[name],
          $Failed];
        If[! (AssociationQ[lr] &&
              MemberQ[{"Loaded", "AlreadyLoaded"},
                Lookup[lr, "Status", ""]]), None,
          wctx = Lookup[lr, "Context", ""];
          If[! StringQ[wctx] || wctx === "" ||
             Names[wctx <> "BuildNet"] === {}, None,
            bn = Symbol[wctx <> "BuildNet"];
            If[! (MatchQ[bn, _Symbol] &&
                  With[{s = bn}, DownValues[s]] =!= {}), None,
              wwid = Quiet @ Check[
                TimeConstrained[bn[name], 30, $Failed], $Failed];
              If[! StringQ[wwid], None, iNetFromWid[wwid]]]]]],
      None];

    (* FinalStatus "Unknown" = ループが最終 place に到達しないまま
       ClaudeRunWorkflow が戻った (典型は MaxWait 時間切れ)。抜け殻 summary
       を Done と報告しない (fail-closed。session_impl_worker.wls と同一)。 *)
    If[AssociationQ[summary] && summary =!= <||> &&
       Lookup[summary, "FinalStatus", "Unknown"] === "Unknown" && err === "",
      err = "implement<->verify loop did not reach a final state" <>
        " (RunStatus: " <> ToString @ Lookup[summary, "RunStatus", "?"] <>
        ", Termination: " <> ToString @ Lookup[summary, "Termination", "?"] <>
        "). Likely MaxWait (" <>
        ToString @ Lookup[cfg, "MaxWaitSeconds", 2400] <>
        "s) exhausted; raise MaxWaitSeconds or reduce rounds."];

    (* result file written LAST = completion signal for the FE poller *)
    Put[<|
      "Status" -> If[AssociationQ[summary] && summary =!= <||> && err === "",
        "Done", "Error"],
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
      "NetStructure" -> netStruct,
      "WorkflowNetStructure" -> If[err === "", wfNetStruct, None]
    |>, Lookup[cfg, "ResultFile", "result.wl"]];

    Print["IMPL DRIVER DONE: ", Lookup[summary, "FinalStatus", "?"]];
  ]
];
