#!/usr/bin/env wolframscript
(* ============================================================
   palette_driver.wls  (SourceVault_workflows/spec-review)

   Background driver for the palette "spec generation" consensus flow.
   Runs the full Codex<->Claude review-and-revise loop
   (SourceVaultWorkflow`SpecReview`RunSpecReview) from notebook-derived
   requirements, then writes a result file the FE kernel polls. Heavy work
   (codex/claude, minutes) runs HERE, off the FE.

   The workflow is loaded ON DEMAND through the SourceVault registry
   (SourceVault`SourceVaultLoadWorkflow["spec-review"]); no hard-coded
   workflow path. The package root is taken from the config (PackageRoot)
   written by the FE kernel, with robust fallbacks.

   Usage: wolframscript -file palette_driver.wls <configFile>
   configFile is a WL Association (Put/Get) with keys:
     "Project", "Version", "RequirementsFile", "PrevSpecRef",
     "AdvisaryModel", "ClaudeModel", "MaxRounds", "PackageName",
     "ResultFile", "SpecOutFile", "PackageRoot", "WorkflowSlug",
     "VaultRoot"(optional), "MockMode"(optional True)
   ============================================================ *)

Block[{$CharacterEncoding = "UTF-8"},
  Module[{cfgFile, cfg, reqText, prevText, draftPrompt, summary, err = "",
          mockDraft, mockReview, draftFn, reviewFn, specOut,
          pkgRoot, slug, loadRes, runFn, langInstr},

    cfgFile = If[Length[$ScriptCommandLine] >= 2, $ScriptCommandLine[[2]], ""];
    cfg = Quiet @ Check[Get[cfgFile], $Failed];
    If[! AssociationQ[cfg],
      Print["BAD CONFIG: ", cfgFile]; Exit[1]];

    (* ---- inherit the FE kernel's $Language ----
       a fresh wolframscript kernel can come up with $Language -> "English",
       so adopt whatever the FE kernel passed. This localizes messages and any
       $Language-aware prompt building inside the loaded packages. *)
    With[{lg = Lookup[cfg, "Language", None]},
      If[StringQ[lg] || (ListQ[lg] && AllTrue[lg, StringQ]), $Language = lg]];
    langInstr = With[{li = Lookup[cfg, "LanguageInstruction", ""]},
      If[StringQ[li], li, ""]];

    iRead[p_] := Quiet @ Check[ByteArrayToString[ReadByteArray[p], "UTF-8"], ""];
    iWrite[p_, s_] := Module[{st = OpenWrite[p, BinaryFormat -> True]},
      BinaryWrite[st, StringToByteArray[If[StringQ[s], s, ""], "UTF-8"]]; Close[st]];

    reqText = iRead[Lookup[cfg, "RequirementsFile", ""]];
    If[! StringQ[reqText], reqText = ""];

    (* ---- resolve package root (config first, then $InputFileName, then default) ---- *)
    pkgRoot = With[{r = Lookup[cfg, "PackageRoot", Automatic]},
      Which[
        StringQ[r] && r =!= "", r,
        StringQ[$InputFileName] && $InputFileName =!= "",
          DirectoryName[$InputFileName, 3],
        True, "F:/Dropbox/Mathematica-oneDrive/MyPackages"]];
    slug = Lookup[cfg, "WorkflowSlug", "spec-review"];

    (* ---- load SourceVault (provides the registry + snapshot ops) ---- *)
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
        "FinalStatus" -> "Unknown"|>, Lookup[cfg, "ResultFile", "result.wl"]];
      Exit[1]];

    runFn = Symbol[Lookup[loadRes, "Context", "SourceVaultWorkflow`SpecReview`"] <> "RunSpecReview"];

    (* early progress so the FE poller shows something before the first transition *)
    With[{pf = Lookup[cfg, "ProgressFile", None]},
      If[StringQ[pf],
        Quiet @ Check[Put[<|"Phase" -> "Starting", "Role" -> "", "Model" -> "",
          "Round" -> 1, "Verdict" -> "", "Message" -> "running consensus loop",
          "UpdatedAtUTC" -> ""|>, pf], Null]]];

    (* previous approved spec for version-up context (read from vault) *)
    prevText = With[{ref = Lookup[cfg, "PrevSpecRef", "none"]},
      If[StringQ[ref] && ref =!= "none",
        With[{rec = Quiet @ SourceVault`SourceVaultLoadImmutableSnapshot[ref]},
          If[AssociationQ[rec], Lookup[rec, "Text", ""], ""]], ""]];

    draftPrompt =
      langInstr <>
      If[StringQ[prevText] && prevText =!= "",
        "This is a VERSION-UP. The notebook requirements were edited; produce an updated FULL spec.\n\n" <>
        "=== Previous spec ===\n" <> prevText <> "\n\n", ""] <>
      "=== Notebook requirements ===\n" <> reqText;

    mockDraft = Function[{model, pl},
      <|"SpecText" -> "# MOCK SPEC v" <> ToString[Lookup[pl, "Round", 1]] <>
         " (" <> Lookup[pl, "Project", ""] <> ")"|>];
    mockReview = Function[{model, pl, st},
      <|"Verdict" -> If[Lookup[pl, "Round", 1] >= 2, "Approved", "NeedsRevision"],
        "Findings" -> "[]", "ReviewText" -> "mock review round " <> ToString[Lookup[pl, "Round", 1]]|>];
    draftFn = If[TrueQ[Lookup[cfg, "MockMode", False]], mockDraft, Automatic];
    reviewFn = If[TrueQ[Lookup[cfg, "MockMode", False]], mockReview, Automatic];

    summary = Quiet @ Check[
      runFn[Lookup[cfg, "Project", "palette"],
        "DraftPrompt" -> draftPrompt,
        "PackageName" -> Lookup[cfg, "PackageName", Automatic],
        "AdvisaryModel" -> Lookup[cfg, "AdvisaryModel", Automatic],
        "ClaudeModel" -> Lookup[cfg, "ClaudeModel", Automatic],
        "DraftFunction" -> draftFn, "ReviewFunction" -> reviewFn,
        "CodegenFunction" -> None,
        "ProgressFile" -> Lookup[cfg, "ProgressFile", None],
        "MaxRounds" -> Lookup[cfg, "MaxRounds", 3],
        "MaxWait" -> Quantity[1500, "Seconds"]],
      err = "RunSpecReview failed"; <||>];

    specOut = Lookup[cfg, "SpecOutFile", ""];
    iWrite[specOut, ToString @ Lookup[summary, "ApprovedSpecURI", ""]];  (* placeholder; overwritten below if text available *)
    With[{fp = Lookup[summary, "FinalPayload", <||>]},
      iWrite[specOut, If[AssociationQ[fp], ToString @ Lookup[fp, "SpecText", ""], ""]]];

    (* result file written LAST = completion signal for the FE poller *)
    Put[<|
      "Status" -> If[AssociationQ[summary] && summary =!= <||>, "Done", "Error"],
      "Error" -> err,
      "FinalStatus" -> Lookup[summary, "FinalStatus", "Unknown"],
      "Rounds" -> Lookup[summary, "Rounds", Missing[]],
      "DraftModel" -> ToString @ Lookup[summary, "DraftModel", ""],
      "ReviewModel" -> ToString @ Lookup[summary, "ReviewModel", ""],
      "ApprovedSpecURI" -> ToString @ Lookup[summary, "ApprovedSpecURI", ""],
      "ApprovedReviewURI" -> ToString @ Lookup[summary, "ApprovedReviewURI", ""],
      "SpecChain" -> Lookup[summary, "SpecChain", {}],
      "ReviewChain" -> Lookup[summary, "ReviewChain", {}],
      "SpecOutFile" -> specOut
    |>, Lookup[cfg, "ResultFile", "result.wl"]];

    Print["DRIVER DONE: ", Lookup[summary, "FinalStatus", "?"]];
  ]
];
