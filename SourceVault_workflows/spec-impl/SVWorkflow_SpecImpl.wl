(* ::Package:: *)

(* ============================================================
   SVWorkflow_SpecImpl.wl  (context: SourceVaultWorkflow`SpecImpl`)

   SourceVault workflow: implement an APPROVED design spec AS a codified
   SourceVault workflow package (an SVWorkflow_<Name> mini-package), driven
   as a ClaudeOrchestrator WorkflowNet (layer-2 codified workflow).

   Lives under SourceVault_workflows/spec-impl/ and is loaded ON DEMAND via
   SourceVault`SourceVaultLoadWorkflow["spec-impl"] (NOT auto-loaded).
   Public entry points: RunSpecImpl, BuildNet, WorkflowInfo, $DefaultMaxRounds.

   Roles map to models generically (NOTE: inverse of spec-review):
     - Implementer role (plan / implement)  -> ClaudeCode`$ClaudeModel
     - Verifier role (review / verify)       -> ClaudeCode`$ClaudeAdvisaryModel

   The loop (payload-driven staging):
     NeedPlan --Plan(impl)--> Planned
       Planned --AuxReview(verifier, while Multi && !AuxApproved)--> Planned
       Planned --ToImpl[!Multi || AuxApproved || auxRound>=max]--> NeedImpl
     NeedImpl --Implement(impl, current stage)--> Implemented
     Implemented --Verify(verifier)--> Verified
       Verified --[Approved & last stage]--> Approved
       Verified --[Approved & more stages]--> NeedImpl (stage+1, round=1)
       Verified --[NeedsRevision & round<max]--> NeedImpl (round+1, feedback)
       Verified --[NeedsRevision & round>=max]--> Failed

   The implementer's output is a JSON file-manifest {relpath: content}; the
   handler writes the files under TargetDir (= SourceVault_workflows/<slug>/).
   At minimum the generated package must contain
     SVWorkflow_<CanonicalName>.wl
     SVWorkflow_<CanonicalName>_info/docs/examples/example.md

   Artifacts/version chains live in SourceVault (snapshot + pointer):
     impl/<name>/plan        (ImplPlan: split-implementation aux spec)
     impl/<name>/planreview  (ImplPlanReview)
     impl/<name>/artifact    (ImplArtifact: generated file manifest)
     impl/<name>/verify      (ImplVerify)

   Encoded in UTF-8 (no BOM).
   ============================================================ *)

(* ---- ensure dependencies are loaded before BeginPackage ----
   package root = three levels up from
   .../SourceVault_workflows/spec-impl/SVWorkflow_SpecImpl.wl *)
SourceVaultWorkflow`SpecImpl`Private`$pkgRoot =
  Which[
    StringQ[$InputFileName] && $InputFileName =!= "",
      DirectoryName[$InputFileName, 3],
    StringQ[Quiet @ Check[Symbol["Global`$packageDirectory"], $Failed]],
      Symbol["Global`$packageDirectory"],
    True, "F:/Dropbox/Mathematica-oneDrive/MyPackages"];

(* base orchestrator (also pulls in ClaudeCode`) *)
If[Length[DownValues[ClaudeOrchestrator`ClaudePlanTasks]] === 0,
  Block[{$CharacterEncoding = "UTF-8"},
    Get[FileNameJoin[{SourceVaultWorkflow`SpecImpl`Private`$pkgRoot, "ClaudeOrchestrator.wl"}]]]];

(* workflow engine (ClaudeOrchestrator`Workflow`): not auto-loaded by the base file *)
If[Length[DownValues[ClaudeOrchestrator`Workflow`ClaudeCreateWorkflowNet]] === 0,
  Block[{$CharacterEncoding = "UTF-8"},
    Get[FileNameJoin[{SourceVaultWorkflow`SpecImpl`Private`$pkgRoot, "ClaudeOrchestrator_workflow.wl"}]]]];

If[Length[DownValues[SourceVault`SourceVaultSaveImmutableSnapshot]] === 0,
  Block[{$CharacterEncoding = "UTF-8"},
    Get[FileNameJoin[{SourceVaultWorkflow`SpecImpl`Private`$pkgRoot, "SourceVault.wl"}]]]];

BeginPackage["SourceVaultWorkflow`SpecImpl`", {"ClaudeOrchestrator`Workflow`", "SourceVault`"}]

BuildNet::usage =
  "BuildNet[name, opts] builds and registers a ClaudeOrchestrator WorkflowNet that implements an approved spec as a codified SVWorkflow_<Name> package and returns its workflow id. Options: \"MaxRounds\", \"MaxAuxRounds\", \"ClaudeModel\" (implementer role; default ClaudeCode`$ClaudeModel), \"AdvisaryModel\" (verifier role; default ClaudeCode`$ClaudeAdvisaryModel), \"PlanFunction\", \"ImplementFunction\", \"VerifyFunction\", \"ProgressFile\", \"TargetDir\".";

RunSpecImpl::usage =
  "RunSpecImpl[name, opts] builds the net, submits the initial token, runs the workflow synchronously, and returns a summary association (FinalStatus, Stages, GeneratedFiles, TargetDir, PlanURI, ArtifactURI, VerifyURI, chains). Required option \"Spec\" (sv:// URI / snapshot ref / spec text). Other options: \"Notes\", \"PackageRoot\", plus all BuildNet options and \"MaxSteps\", \"MaxWait\".";

$DefaultMaxRounds::usage =
  "$DefaultMaxRounds is the default maximum number of implement/verify revise rounds before giving up.";

WorkflowInfo::usage =
  "WorkflowInfo[] returns metadata for this SourceVault workflow (Slug, Name, Version, Context, Launch entry, Description, Routes).";

Begin["`Private`"]

If[!ValueQ[$DefaultMaxRounds], $DefaultMaxRounds = 3];
If[!ValueQ[$DefaultMaxAuxRounds], $DefaultMaxAuxRounds = 3];

(* per-LLM-call wall-clock cap (seconds). Bounds a single external CLI call so a
   slow/hung provider (e.g. a stuck "codex exec") can never block the driver
   indefinitely; the call is killed and a traceable marker is returned instead.
   The driver may override this from its config ("CallTimeLimitSeconds"). *)
If[!ValueQ[$iOrchCallTimeLimit], $iOrchCallTimeLimit = 900];

(* dynamic verification gate: after the static smoke test, actually LOAD the
   generated package in a fresh wolframscript kernel, call its no-arg launch, and
   run the generated test -- catching runtime errors (invalid context, undefined
   symbols, a launch that returns Missing/$Failed) that a static check cannot.
   $iWolframScript: the executable (the driver overrides via config if needed).
   $iDynTest: master switch. $iDynTestTimeLimit: per-spawn wall-clock cap (s). *)
If[!ValueQ[$iWolframScript], $iWolframScript = "wolframscript"];
If[!ValueQ[$iDynTest], $iDynTest = True];
If[!ValueQ[$iDynTestTimeLimit], $iDynTestTimeLimit = 240];

(* ---- workflow contract: metadata for the SourceVault workflow registry ---- *)
WorkflowInfo[] := <|
  "Slug" -> "spec-impl",
  "Name" -> "Spec -> Workflow Implementation",
  "Version" -> "1.0",
  "Context" -> "SourceVaultWorkflow`SpecImpl`",
  "Launch" -> "RunSpecImpl",
  "Description" ->
    "Implement an approved design spec as a codified SVWorkflow_<Name> package. " <>
    "The implementer ($ClaudeModel) writes the package; the verifier " <>
    "($ClaudeAdvisaryModel) checks it against the spec and feeds back. " <>
    "Complex work is split into stages via an auxiliary spec reviewed to consensus first.",
  "Routes" -> {}
|>;

(* ---- model resolution: role -> generic constant ---- *)
iResolveClaude[m_] := Which[
  m =!= Automatic, m,
  ValueQ[ClaudeCode`$ClaudeModel], ClaudeCode`$ClaudeModel,
  True, ""];

iResolveAdvisary[m_] := Which[
  m =!= Automatic, m,
  ValueQ[ClaudeCode`$ClaudeAdvisaryModel], ClaudeCode`$ClaudeAdvisaryModel,
  True, "chatgptcodex"];

(* output language for generated prose: the kernel's $Language (the driver
   inherits the FE kernel's $Language via the config). *)
iLangName[] := If[StringQ[$Language] && $Language =!= "", $Language, "English"];

(* a ready-made language directive may be passed via payload "LanguageInstruction" *)
iLangInstr[payload_] := With[{li = Lookup[payload, "LanguageInstruction", ""]},
  If[StringQ[li], li, ""]];

(* ---- canonical name / slug helpers (mirror the workflow registry) ---- *)
(* slug -> CamelCase symbol-safe leaf. Mirror of the registry's iSVWFCanonicalSlug
   (MUST stay identical so the generated BeginPackage context matches what
   SourceVaultWorkflowContext[slug] expects). A leaf may not begin with a digit,
   so a date-prefixed slug ("20260622-...") gets a "W" prefix. *)
iCanonicalName[slug_String] := Module[{parts, canon},
  parts = Select[StringSplit[slug, Except[WordCharacter] ..], # =!= "" &];
  canon = If[parts === {}, slug, StringJoin[Capitalize /@ parts]];
  If[StringQ[canon] && canon =!= "" && StringStartsQ[canon, DigitCharacter],
    "W" <> canon, canon]];

(* ---- binding / payload helpers ---- *)
iPayload[b_Association] := Lookup[First[Values[b]], "Payload", <||>];
iVerdict[b_Association] := Lookup[iPayload[b], "Verdict", ""];
iRound[b_Association]   := Lookup[iPayload[b], "Round", 1];
iMaxRounds[b_Association] := Lookup[iPayload[b], "MaxRounds", $DefaultMaxRounds];
iMulti[b_Association] := TrueQ[Lookup[iPayload[b], "Multi", False]];
iAuxApproved[b_Association] := TrueQ[Lookup[iPayload[b], "AuxApproved", False]];
iAuxRound[b_Association] := Lookup[iPayload[b], "AuxRound", 0];
iMaxAuxRounds[b_Association] := Lookup[iPayload[b], "MaxAuxRounds", $DefaultMaxAuxRounds];
iStageIndex[b_Association] := Lookup[iPayload[b], "StageIndex", 1];
iNumStages[b_Association] := Max[1, Length[Lookup[iPayload[b], "Stages", {"(single)"}]]];
iImplBlocked[b_Association] := TrueQ[Lookup[iPayload[b], "ImplBlocked", False]];

(* ---- small IO / JSON helpers (message-quiet) ---- *)
iWriteUTF8[p_, s_] := Module[{strm},
  Quiet @ Check[
    If[! DirectoryQ[DirectoryName[p]],
      CreateDirectory[DirectoryName[p], CreateIntermediateDirectories -> True]], Null];
  strm = OpenWrite[p, BinaryFormat -> True];
  BinaryWrite[strm, StringToByteArray[If[StringQ[s], s, ""], "UTF-8"]]; Close[strm]];
iReadUTF8[p_] := Quiet @ Check[ByteArrayToString[ReadByteArray[p], "UTF-8"], ""];

(* parse a JSON string via the UTF-8 byte-array path (rules/30: non-ASCII
   values break Developer`ReadRawJSONString / ImportString["RawJSON"]); fall
   back to ReadRawJSONString. Returns the value or $Failed. *)
iReadJSON[s_String] := Module[{r},
  r = Quiet @ Check[ImportByteArray[StringToByteArray[s, "UTF-8"], "RawJSON"], $Failed];
  If[AssociationQ[r] || ListQ[r], Return[r]];
  r = Quiet @ Check[Developer`ReadRawJSONString[s], $Failed];
  If[AssociationQ[r] || ListQ[r], r, $Failed]];
iReadJSON[_] := $Failed;

(* the first balanced {...} object in s (string-aware), ignoring stray trailing
   braces or prose that LLMs sometimes append (e.g. codex's extra "}"). *)
iBalancedObject[s_String] := Module[{chars, depth = 0, start = 0, inStr = False, esc = False, res = $Failed},
  chars = Characters[s];
  Do[
    With[{c = chars[[i]]},
      Which[
        esc, esc = False,
        c === "\\", If[inStr, esc = True],
        c === "\"", inStr = ! inStr,
        inStr, Null,
        c === "{", If[depth === 0, start = i]; depth++,
        c === "}", depth--;
          If[depth === 0 && start > 0,
            res = StringJoin[Take[chars, {start, i}]]; Break[]]]],
    {i, Length[chars]}];
  res];
iBalancedObject[_] := $Failed;

iExtractJSON[out_String] := Module[{m, body, r},
  m = StringCases[out, "```json" ~~ Shortest[b__] ~~ "```" :> b, 1];
  body = StringTrim @ If[m =!= {}, First[m], out];
  r = iReadJSON[body];
  If[AssociationQ[r] || ListQ[r], Return[r]];
  (* tolerant: extract the first balanced {...} (handles trailing junk) *)
  With[{bo = iBalancedObject[body]},
    If[StringQ[bo], r = iReadJSON[bo]; If[AssociationQ[r] || ListQ[r], Return[r]]]];
  With[{bo = iBalancedObject[out]},
    If[StringQ[bo], r = iReadJSON[bo]; If[AssociationQ[r] || ListQ[r], Return[r]]]];
  <||>];
iExtractJSON[_] := <||>;

(* verdict-of-last-resort: if JSON parsing fails entirely, scan the raw text so
   a single malformed character cannot silently force NeedsRevision (which would
   make the loop unable to ever converge). *)
iScanVerdict[text_String] := Which[
  StringContainsQ[text, RegularExpression["\"verdict\"\\s*:\\s*\"Approved\""]], "Approved",
  StringContainsQ[text, "NeedsRevision"], "NeedsRevision",
  StringContainsQ[text, "Approved"], "Approved",
  True, "NeedsRevision"];
iScanVerdict[_] := "NeedsRevision";

(* ---- progress emission (FE reads this file and shows WindowStatusArea) ----
   written atomically (temp + rename) so a concurrent FE Get does not see a
   torn file. *)
iEmitProgress[None, _] := Null;
iEmitProgress[file_String, assoc_Association] := Quiet @ Check[
  Module[{tmp = file <> ".tmp"},
    Put[Join[<|"UpdatedAtUTC" -> iNowUTC[]|>, assoc], tmp];
    Quiet @ If[FileExistsQ[file], DeleteFile[file]];
    RenameFile[tmp, file]], Null];
iEmitProgress[_, _] := Null;

iNowUTC[] := Quiet @ Check[
  DateString[Now, {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"},
    TimeZone -> 0], ""];

iRefToURI[ref_String] := Module[{p = StringSplit[ref, ":"]},
  If[Length[p] >= 3 && p[[1]] === "snapshot", "sv://snapshot/" <> p[[2]] <> "/" <> p[[3]], ref]];
iRefToURI[_] := "<no-ref>";

(* a short human label for "which model is running" *)
iModelLabel[model_] := Which[
  StringQ[model] && model =!= "", model,
  ListQ[model] && Length[model] >= 1 && StringQ[model[[1]]],
    model[[1]] <> If[Length[model] >= 2 && StringQ[model[[2]]] && model[[2]] =!= "" &&
      model[[2]] =!= "Automatic", ":" <> model[[2]], ""],
  True, "model"];

(* ============================================================
   Vault contract
   ============================================================ *)

iSavePlan[name_, round_, multi_, stages_, text_] := Module[{snap, ref},
  snap = SourceVaultSaveImmutableSnapshot["ImplPlan", <|
    "Project" -> name, "Round" -> round, "Role" -> "plan",
    "Multi" -> multi, "Stages" -> stages, "Text" -> text, "CreatedBy" -> "implementer"|>];
  ref = Lookup[snap, "Ref"];
  SourceVaultAtomicUpdatePointer["impl/" <> name <> "/plan", ref];
  SourceVaultAppendEvent[<|"EventClass" -> "ImplHandoff", "Project" -> name,
    "Round" -> round, "Role" -> "plan", "From" -> "implementer", "To" -> "verifier", "Value" -> ref|>];
  ref];

iSavePlanReview[name_, round_, verdict_, findings_, targetRef_, text_] := Module[{snap, ref},
  snap = SourceVaultSaveImmutableSnapshot["ImplPlanReview", <|
    "Project" -> name, "Round" -> round, "Role" -> "planreview",
    "Verdict" -> verdict, "Findings" -> findings, "TargetPlanRef" -> targetRef,
    "Text" -> text, "CreatedBy" -> "verifier"|>];
  ref = Lookup[snap, "Ref"];
  SourceVaultAtomicUpdatePointer["impl/" <> name <> "/planreview", ref];
  SourceVaultAppendEvent[<|"EventClass" -> "ImplHandoff", "Project" -> name,
    "Round" -> round, "Role" -> "planreview", "From" -> "verifier", "To" -> "implementer",
    "Verdict" -> verdict, "Value" -> ref|>];
  ref];

iSaveArtifact[name_, stage_, round_, files_, testFiles_, steps_, manifestText_] := Module[{snap, ref},
  snap = SourceVaultSaveImmutableSnapshot["ImplArtifact", <|
    "Project" -> name, "Stage" -> stage, "Round" -> round, "Role" -> "artifact",
    "Files" -> files, "TestFiles" -> testFiles, "Steps" -> steps,
    "Text" -> manifestText, "CreatedBy" -> "implementer"|>];
  ref = Lookup[snap, "Ref"];
  SourceVaultAtomicUpdatePointer["impl/" <> name <> "/artifact", ref];
  SourceVaultAppendEvent[<|"EventClass" -> "ImplHandoff", "Project" -> name,
    "Stage" -> stage, "Round" -> round, "Role" -> "artifact",
    "From" -> "implementer", "To" -> "verifier", "Value" -> ref|>];
  ref];

iSaveVerify[name_, stage_, round_, verdict_, findings_, targetRef_, text_] := Module[{snap, ref},
  snap = SourceVaultSaveImmutableSnapshot["ImplVerify", <|
    "Project" -> name, "Stage" -> stage, "Round" -> round, "Role" -> "verify",
    "Verdict" -> verdict, "Findings" -> findings, "TargetArtifactRef" -> targetRef,
    "Text" -> text, "CreatedBy" -> "verifier"|>];
  ref = Lookup[snap, "Ref"];
  SourceVaultAtomicUpdatePointer["impl/" <> name <> "/verify", ref];
  SourceVaultAppendEvent[<|"EventClass" -> "ImplHandoff", "Project" -> name,
    "Stage" -> stage, "Round" -> round, "Role" -> "verify",
    "From" -> "verifier", "To" -> "implementer", "Verdict" -> verdict, "Value" -> ref|>];
  ref];

(* ============================================================
   Provider-agnostic synchronous text query (role -> model).
   chatgptcodex -> codex CLI; claudecode / anthropic / openai / lmstudio ->
   ClaudeCode`ClaudeQuerySync.  (mirror of spec-review)
   ============================================================ *)

iCmdPrefix[] := If[$OperatingSystem === "Windows", {"cmd", "/c"}, {}];

iCanonProvider[s_] := Module[{l = ToLowerCase[ToString[s]]},
  Which[
    MemberQ[{"chatgptcodex", "chatgpt-codex", "codex", "gptcodex"}, l], "chatgptcodex",
    MemberQ[{"claudecode", "claude"}, l], "claudecode",
    l === "anthropic", "anthropic",
    l === "openai", "openai",
    l === "lmstudio", "lmstudio",
    True, None]];

iModelTuple[m_] := Which[
  ListQ[m] && Length[m] >= 2 && StringQ[m[[1]]], m,
  StringQ[m] && m =!= "" && iCanonProvider[m] =!= None, {iCanonProvider[m], ""},
  StringQ[m] && m =!= "", {"claudecode", m},
  True, {"claudecode", ""}];

iOrchCodex[tup_, prompt_] := Module[{ws, answerFile, model, modelArgs, res, ans},
  ws = FileNameJoin[{$TemporaryDirectory, "implq_codex_" <> StringReplace[CreateUUID[], "-" -> ""]}];
  Quiet @ CreateDirectory[ws, CreateIntermediateDirectories -> True];
  answerFile = FileNameJoin[{ws, "answer.txt"}];
  model = If[Length[tup] >= 2 && StringQ[tup[[2]]] && tup[[2]] =!= "" && tup[[2]] =!= "Automatic",
    tup[[2]], ""];
  modelArgs = If[model =!= "", {"-m", model}, {}];
  (* TimeConstrained bounds a stuck "codex exec" to $iOrchCallTimeLimit s so a
     hung/very-slow provider can never block the driver indefinitely. (RunProcess
     has no usable timeout option here -- ProcessTimeLimit is rejected -- so the
     synchronous call is wrapped.) On timeout it returns the marker "TimedOut";
     otherwise res is the All-form result association. *)
  res = TimeConstrained[
    Quiet @ Check[
      RunProcess[Join[iCmdPrefix[],
          {"codex", "exec", "-C", ws, "-s", "workspace-write", "--skip-git-repo-check",
           "-c", "approval_policy=never"}, modelArgs, {"-o", answerFile, "-"}],
        All, StringToByteArray[prompt, "UTF-8"]],
      <|"ExitCode" -> "Error", "StandardOutput" -> ""|>],
    $iOrchCallTimeLimit,
    "TimedOut"];
  ans = Which[
    FileExistsQ[answerFile], iReadUTF8[answerFile],
    AssociationQ[res], Lookup[res, "StandardOutput", ""],
    True, ""];
  Quiet @ If[DirectoryQ[ws], DeleteDirectory[ws, DeleteContents -> True]];
  If[StringQ[ans] && StringTrim[ans] =!= "",
    ans,
    (* no output: timed out (after $iOrchCallTimeLimit s) or the call failed.
       Return a traceable marker rather than "" so the verifier records a
       concrete NeedsRevision (reason visible in the review text). *)
    "[codex produced no output: timed out after " <> ToString[$iOrchCallTimeLimit] <>
      "s or the call failed]"]];

iOrchQuery[m_, prompt_] := Module[{tup = iModelTuple[m], prov, r},
  prov = ToLowerCase[tup[[1]]];
  If[prov === "chatgptcodex",
    iOrchCodex[tup, prompt],
    r = Quiet @ Check[
      Block[{ClaudeCode`$ClaudeModel = tup}, ClaudeCode`ClaudeQuerySync[prompt]], $Failed];
    If[StringQ[r], r, ""]]];

(* ============================================================
   Real executors (LIVE path).  Each takes the resolved model for its role.
   ============================================================ *)

(* shared prompt fragment: the SVWorkflow packaging conventions the
   implementer must follow when producing the generated package. *)
iConventions[name_, canon_] :=
  "Packaging conventions for the generated codified SourceVault workflow:\n" <>
  "- Folder: SourceVault_workflows/" <> name <> "/ (the target dir; use RELATIVE paths in the manifest).\n" <>
  "- Main file: SVWorkflow_" <> canon <> ".wl beginning with BeginPackage[\"SourceVaultWorkflow`" <> canon <> "`\"] (NO second argument when there are no needed contexts). NEVER write BeginPackage[ctx, {}] with an empty list -- it is invalid and the package fails to load. If other contexts are needed, pass a NONEMPTY list, e.g. BeginPackage[\"...`\", {\"SourceVault`\"}].\n" <>
  "- The main file must self-bootstrap its dependencies with Get[FileNameJoin[{<pkgRoot>, ...}]] guarded by DownValues/Names checks. Compute pkgRoot DEPTH-INDEPENDENTLY by walking up from the file's directory until the directory that contains SourceVault.wl is found (do NOT hardcode a DirectoryName depth -- the workflow may live under SourceVault_workflows/testing/<slug>/ or /production/<slug>/): pkgRoot = Module[{d = DirectoryName[$InputFileName]}, While[d =!= DirectoryName[d] && ! FileExistsQ[FileNameJoin[{d, \"SourceVault.wl\"}]], d = DirectoryName[d]]; d].\n" <>
  "- It must expose WorkflowInfo[] returning <|\"Slug\"->\"" <> name <> "\",\"Name\"->...,\"Version\"->...,\"Context\"->\"SourceVaultWorkflow`" <> canon <> "`\",\"Launch\"->\"<entry>\",\"Description\"->...,\"Routes\"->{}|>.\n" <>
  "- It must define the public launch entry named in WorkflowInfo[\"Launch\"]. If the no-argument launch form is a safe report (no side effects), provide an explicit form that actually performs the work and document both in the example. STANDARDIZE the end-to-end work-performing form as <Launch>[\"run\"] (a string first argument \"run\") so it can be launched ASYNCHRONOUSLY off the FRONT END by the generic runner SourceVault`SourceVaultRunWorkflowAsync[slug, \"run\"] -- keep <Launch>[\"run\"] self-contained (it reads its own inputs / does its own fetch) and RETURNING the deliverable (a View / report / result), never requiring interactive args.\n" <>
  "- Docs file: SVWorkflow_" <> canon <> "_info/docs/examples/example.md (a short usage example).\n" <>
  "  In example.md, load the workflow with the on-demand registry loader exactly as:\n" <>
  "    Needs[\"SourceVault`\"]; SourceVault`SourceVaultLoadWorkflow[\"" <> name <> "\"]\n" <>
  "  Do NOT use a manual Get with a hardcoded path or any placeholder symbol. Then call WorkflowInfo[] and the launch entry, showing the real invocation (with arguments if the launch needs them to do its work). For a LONG-RUNNING end-to-end run (network / LLM), show SourceVault`SourceVaultRunWorkflowAsync[\"" <> name <> "\", \"run\"] as the DEFAULT way to run it (it runs off the FRONT END so the notebook does not freeze; the synchronous <Launch>[\"run\"] is only for quick/offline cases). The completion writes a summary to the notebook; the result View is retrieved via SourceVault`SourceVaultRunWorkflowResult.\n" <>
  "- Extra subfiles, if any, are SVWorkflow_" <> canon <> "_<sub>.wl .\n" <>
  "- Encode in UTF-8; use only \\:XXXX style Unicode escapes inside .wl strings; do not Clear/Remove the Global` context.\n" <>
  "SIMULATION / HEAVY-COMPUTE CONVENTIONS -- apply ONLY when the spec has an \"## Execution Profile\" " <>
  "section with ExecutionClass \"simulation\", or otherwise requires subkernel parallelism / CUDA / " <>
  "large (reference-mode) outputs:\n" <>
  "- The no-arg launch stays a SAFE report: it must never run the simulation, launch kernels, or " <>
  "touch the GPU. The real run is <Launch>[\"run\", opts] with the spec's tunable parameters as options.\n" <>
  "- REFERENCE OUTPUTS (OutputMode \"reference\"): at the start of \"run\" call " <>
  "run = SourceVault`SourceVaultSimRunCreate[\"" <> name <> "\", params] (params = an Association of " <>
  "the tunable parameters; it creates the per-run folder <udb>/simruns/<yyyymmddHHmm>-<machine>-<slug>). " <>
  "Write EVERY bulk artifact (data .wxf/.csv, images, videos, frames) under run[\"Folder\"]. At the end " <>
  "call fin = SourceVault`SourceVaultSimRunFinalize[run, <|\"Status\"->\"Done\",\"Summary\"-><SMALL assoc>|>] " <>
  "and RETURN a small association that includes fin[\"URI\"] (the sv://snapshot/SimulationRun/... " <>
  "reference), fin[\"Folder\"], and key summary numbers. NEVER return or store bulk data/graphics " <>
  "inline, never deposit the bulk files as vault blobs, and never put large values into the Finalize " <>
  "extra argument (metadata + small summary only).\n" <>
  "- CPU PARALLEL (Parallelization \"subkernels\"): wrap the heavy compute in " <>
  "SourceVault`SourceVaultWithSubkernels[ ... ] -- it launches ALL available subkernels and ALWAYS " <>
  "closes the ones it launched when the body finishes, returning the license seats to standby. Do NOT " <>
  "call LaunchKernels/CloseKernels yourself. Inside the body, ParallelMap / ParallelTable / " <>
  "DistributeDefinitions / ParallelEvaluate work as usual (remember to DistributeDefinitions or " <>
  "ParallelEvaluate[Get[...]] anything the subkernels need).\n" <>
  "- CUDA (CUDA \"required\"): begin \"run\" with gate = SourceVault`SourceVaultCUDARequire[]; " <>
  "If[FailureQ[gate], Return[gate]] -- on a non-Nvidia machine this returns a graceful Failure naming " <>
  "the known GPU machines (e.g. the spec's TargetMachine). Ship the CUDA C source as a .cu file in the " <>
  "package folder; compile with exe = SourceVault`SourceVaultCUDACompile[cuPath] (nvcc -O3, cached " <>
  "under LocalState; a Failure means nvcc is unavailable -- return it). Exchange data with the " <>
  "executable via BINARY FILES inside the run folder (BinaryWrite / BinaryReadList), never by parsing " <>
  "large data from stdout.\n" <>
  "- Test file: keep it LIGHT -- tiny problem sizes, no subkernel launch, no GPU/nvcc requirement " <>
  "(skip CUDA paths printing SKIP when SourceVault`SourceVaultGPUAvailableQ[] is False), network-free; " <>
  "SimRunCreate/Finalize may be exercised with $SourceVaultSimRunRoot redirected to a temp directory.\n" <>
  "- Exact simrun API (auto-loaded with SourceVault`): " <>
  "SourceVaultSimRunCreate[slug_String, params_Association] -> <|\"RunId\",\"Folder\",\"Slug\",\"Machine\",\"Params\",\"StartedAtUTC\"|>; " <>
  "SourceVaultSimRunFinalize[run_Association, extra_Association] -> <|\"Status\",\"URI\",\"Ref\",\"RunId\",\"Folder\",\"Files\",\"TotalBytes\"|> | Failure; " <>
  "SourceVaultWithSubkernels[body] / SourceVaultWithSubkernels[n, body] (HoldAll; returns body's value); " <>
  "SourceVaultCUDARequire[] -> <|\"OK\"->True,\"GPUs\"->...|> | Failure[\"NoNvidiaGPU\",...]; " <>
  "SourceVaultCUDACompile[cuFile_String] -> exePath_String | Failure; " <>
  "SourceVaultGPUAvailableQ[] -> True|False; " <>
  "SourceVaultMachineProfile[] -> <|\"MachineTag\",\"ProcessorCount\",\"MemoryGB\",\"GPUs\",...|>; " <>
  "SourceVaultSimRunFolder[uri_String] -> local folder path | Missing.\n";

(* PLAN: decide single vs multi-stage; if multi, draft a split-implementation aux spec. *)
iRealPlan[model_, payload_] := Module[{name, canon, spec, notes, prompt, out, json, multi, stages, aux},
  name = Lookup[payload, "Name", "workflow"];
  canon = Lookup[payload, "Canon", iCanonicalName[name]];
  spec = Lookup[payload, "Spec", ""];
  notes = Lookup[payload, "Notes", ""];
  prompt =
    iLangInstr[payload] <> "\n" <>
    "You are the implementer. Plan how to implement the APPROVED design spec below as a codified " <>
    "SourceVault workflow package named \"" <> name <> "\".\n" <>
    iConventions[name, canon] <>
    "Decide whether the implementation should be split into multiple sequential stages.\n" <>
    "STRONGLY PREFER A SINGLE STAGE. Almost every workflow -- in particular any that generates one " <>
    "notebook / report / visualization -- must be a SINGLE stage that fully implements everything in " <>
    "one shot. Each stage is produced by a SEPARATE model call that cannot iteratively run code, so " <>
    "splitting tends to leave later stages unfinished.\n" <>
    "Use multiple stages ONLY when the package is genuinely composed of independent, separately " <>
    "completable components (e.g. several distinct subpackages), AND each stage on its own produces a " <>
    "COMPLETE, working, non-stub deliverable.\n" <>
    "NEVER use a 'skeleton/stub first, real body later' split: a stage whose launch entry returns a " <>
    "NotImplemented/placeholder stub is FORBIDDEN. When in any doubt, choose a SINGLE stage.\n" <>
    "If multi-stage, write a split-implementation auxiliary spec (Markdown) describing each stage and its scope.\n" <>
    "Write the auxSpec and stage titles in " <> iLangName[] <> ".\n" <>
    "Respond with EXACTLY one JSON object inside a ```json block and nothing else.\n" <>
    "Schema: {\"multi\":true|false,\"stages\":[\"stage title\",...],\"auxSpec\":\"markdown (\\\"\\\" if single stage)\"}\n" <>
    If[StringQ[notes] && notes =!= "", "\n=== Implementation notes ===\n" <> notes <> "\n", ""] <>
    "\n=== APPROVED SPEC ===\n" <> spec;
  out = iOrchQuery[model, prompt];
  json = iExtractJSON[out];
  multi = TrueQ[Lookup[json, "multi", False]];
  stages = Lookup[json, "stages", {}];
  stages = Select[If[ListQ[stages], stages, {}], StringQ[#] && # =!= "" &];
  If[stages === {}, stages = {"(single)"}; multi = False];
  If[! multi, stages = {First[stages]}];
  aux = Lookup[json, "auxSpec", ""];
  <|"Multi" -> multi, "Stages" -> stages, "AuxSpec" -> If[StringQ[aux], aux, ""]|>];

(* AUX REVIEW: verifier reviews the auxiliary split-implementation spec. *)
iRealPlanReview[model_, payload_, auxText_] := Module[{prompt, out, json, verdict, findings, rtext},
  prompt =
    "Review the following split-implementation plan (auxiliary spec) for implementing a design spec " <>
    "as a codified workflow. Decide whether the staged plan is sound and complete.\n" <>
    "SCOPE: judge ONLY the staged DECOMPOSITION (are the stages coherent, ordered, complete?). Do " <>
    "NOT reject over package context / file naming / BeginPackage form: those are derived " <>
    "deterministically by the SourceVault registry from the workflow slug (an escaped-Japanese " <>
    "CamelCase context) and are validated by a deterministic load check at implementation time -- in " <>
    "particular, NEVER demand an ASCII context (e.g. a \"SpecV2\"-style leaf); an ASCII context would " <>
    "fail to load and is WRONG.\n" <>
    "Respond with EXACTLY one JSON object inside a ```json block and nothing else.\n" <>
    "Write the \"reviewText\" and every finding \"title\" in " <> iLangName[] <> ".\n" <>
    "Keep JSON keys and the \"verdict\"/\"severity\" enum values in ASCII.\n" <>
    "Schema: {\"verdict\":\"Approved\"|\"NeedsRevision\",\"findings\":[{\"id\":\"..\",\"severity\":\"blocker\"|\"minor\",\"title\":\"..\"}],\"reviewText\":\"..\"}\n" <>
    "If there are zero blocker findings, verdict is Approved.\n\n" <>
    "=== ORIGINAL SPEC ===\n" <> Lookup[payload, "Spec", ""] <> "\n\n" <>
    "=== STAGED PLAN ===\n" <> auxText;
  out = iOrchQuery[model, prompt];
  json = iExtractJSON[out];
  verdict = Lookup[json, "verdict", iScanVerdict[out]];
  findings = Quiet @ Check[Developer`WriteRawJSONString[Lookup[json, "findings", {}]], "[]"];
  rtext = Lookup[json, "reviewText", out];
  <|"Verdict" -> If[verdict === "Approved", "Approved", "NeedsRevision"],
    "Findings" -> If[StringQ[findings], findings, "[]"], "ReviewText" -> rtext|>];

(* revise the aux spec given verifier feedback *)
iRealPlanRevise[model_, payload_, auxText_, feedback_] := Module[{name, canon, prompt, out, json, aux},
  name = Lookup[payload, "Name", "workflow"];
  canon = Lookup[payload, "Canon", iCanonicalName[name]];
  prompt =
    iLangInstr[payload] <> "\n" <>
    "Revise the split-implementation auxiliary spec to address every review point. Keep what still applies.\n" <>
    "Write the auxSpec and stage titles in " <> iLangName[] <> ".\n" <>
    "Respond with EXACTLY one JSON object inside a ```json block and nothing else.\n" <>
    "Schema: {\"stages\":[\"stage title\",...],\"auxSpec\":\"markdown\"}\n\n" <>
    "=== ORIGINAL SPEC ===\n" <> Lookup[payload, "Spec", ""] <> "\n\n" <>
    "=== PREVIOUS PLAN ===\n" <> auxText <> "\n\n" <>
    "=== REVIEW (address every point) ===\n" <> feedback;
  out = iOrchQuery[model, prompt];
  json = iExtractJSON[out];
  aux = Lookup[json, "auxSpec", auxText];
  With[{stages = Select[Lookup[json, "stages", {}], StringQ[#] && # =!= "" &]},
    <|"AuxSpec" -> If[StringQ[aux], aux, auxText],
      "Stages" -> If[stages =!= {}, stages, Lookup[payload, "Stages", {"(single)"}]]|>]];

(* IMPLEMENT: carry out the implementation sub-steps for the current stage
   (write/modify code -> write tests -> run tests -> verify results) and return
   the file manifest (code + test files) plus a structured step log. *)
iRealImplement[model_, payload_] := Module[
  {name, canon, spec, notes, stages, idx, multi, stageTitle, aux, lastVerify,
   existing, prompt, out, files, steps, testFiles},
  name = Lookup[payload, "Name", "workflow"];
  canon = Lookup[payload, "Canon", iCanonicalName[name]];
  spec = Lookup[payload, "Spec", ""];
  notes = Lookup[payload, "Notes", ""];
  stages = Lookup[payload, "Stages", {"(single)"}];
  idx = Lookup[payload, "StageIndex", 1];
  multi = TrueQ[Lookup[payload, "Multi", False]];
  stageTitle = If[1 <= idx <= Length[stages], stages[[idx]], "(single)"];
  aux = Lookup[payload, "AuxSpec", ""];
  lastVerify = Lookup[payload, "LastVerifyText", ""];
  existing = Lookup[payload, "GeneratedFiles", {}];
  prompt =
    iLangInstr[payload] <> "\n" <>
    "You are the implementer. Implement the APPROVED design spec below as a codified SourceVault " <>
    "workflow package named \"" <> name <> "\".\n" <>
    iConventions[name, canon] <>
    If[multi,
      "This is a MULTI-STAGE implementation. Implement ONLY stage " <> ToString[idx] <> " of " <>
        ToString[Length[stages]] <> ": \"" <> stageTitle <> "\". Build on any files already generated; " <>
        "you may add or modify files as the stage requires.\n" <>
        If[StringQ[aux] && aux =!= "", "\n=== STAGED PLAN (auxiliary spec) ===\n" <> aux <> "\n", ""],
      "Implement the whole package in a single stage.\n"] <>
    "FULLY implement everything in scope" <> If[multi, " for THIS stage", ""] <> ": the launch entry " <>
    "and every function must actually perform their work. Do NOT leave placeholder or " <>
    "\"NotImplemented\"/stub return values for in-scope functionality -- a stub is treated as " <>
    "incomplete and will be rejected.\n" <>
    "ALWAYS VERIFY BUILT-INS AGAINST THE WOLFRAM DOCUMENTATION before relying on them: never assume a " <>
    "function's argument forms, options, or RETURN TYPE/shape -- confirm them in the Mathematica docs " <>
    "(ref/<Name>) and write code that matches the documented result, handling the actual Head you get back. " <>
    "Concretely: FinancialData[id, prop, {start, end}] returns a TimeSeries, NOT a list of {date, value} " <>
    "pairs -- accept a TimeSeries (e.g. via ts[\"Path\"]) or both forms, and never gate fetched data with " <>
    "ListQ alone (a TimeSeries fails ListQ, silently dropping every series). Apply the same doc-checked " <>
    "care to any data / import / plot / external built-in whose output shape you are unsure of.\n" <>
    "GROUND EVERY PROJECT / NON-BUILT-IN API AGAINST ITS REAL DEFINITION -- NEVER INVENT ONE. Any symbol " <>
    "you did not define yourself and that is NOT a Wolfram System built-in (in particular ANYTHING in a " <>
    "package context such as SourceVault`, NBAccess`, ClaudeCode`, ClaudeOrchestrator`) MUST have its exact " <>
    "name, positional arguments, OPTION names and RETURN shape confirmed against GROUND TRUTH before you " <>
    "call it. Resolve it in ONE of these ways: (1) PREFERRED -- the SourceVault MCP package-API index: call " <>
    "the sourcevault_search tool with kinds:[\"packageapi\"] for the function, then sourcevault_get with " <>
    "view:\"contract\" for its exact signature / options / return type; (2) read the REAL source with " <>
    "Grep/Read under the package root. Do NOT assume an option exists, a positional-argument order, or that " <>
    "a function returns a List when it actually returns an Association -- e.g. SourceVault`SourceVaultMailFetchNew " <>
    "is SourceVaultMailFetchNew[mbox_String, opts] (a mailbox STRING first, options \"Period\"/\"Process\"/... " <>
    "-- there is NO \"Account\" option) and it RETURNS an Association (status/counts) storing to the vault, " <>
    "NOT a list of mails. If you CANNOT resolve a REQUIRED API by either route, DO NOT fabricate a " <>
    "plausible-looking call: STOP and declare it via the UNRESOLVED-API protocol below, and emit NO file " <>
    "that calls the unverified API.\n" <>
    "BEFORE approval your package is REALLY EXECUTED in a fresh wolframscript kernel: it is loaded via " <>
    "SourceVault`SourceVaultLoadWorkflow, its no-arg launch entry is CALLED, and your test file is RUN. So " <>
    "(a) the package must load with NO error messages; (b) the no-arg launch must be a network-free safe " <>
    "report that returns cleanly (never $Failed / Missing); (c) \"test_" <> canon <> ".wls\" MUST be " <>
    "standalone-runnable via `wolframscript -file` -- self-bootstrap SourceVault (compute pkgRoot by walking " <>
    "up to SourceVault.wl then Get it), use NETWORK-FREE unit tests of the core logic INCLUDING data-shape " <>
    "handling (feed a sample TimeSeries / sample {date,value} pairs instead of calling the network), Print " <>
    "PASS/FAIL counts, and Exit[1] on ANY failure.\n" <>
    If[existing =!= {}, "\nAlready-generated files (relative paths): " <>
      StringRiffle[existing, ", "] <> "\n", ""] <>
    If[StringQ[lastVerify] && lastVerify =!= "",
      "\n=== Previous verification (address every point) ===\n" <> lastVerify <> "\n", ""] <>
    If[StringQ[notes] && notes =!= "", "\n=== Implementation notes ===\n" <> notes <> "\n", ""] <>
    "\nCarry out and REPORT these implementation sub-steps for this stage:\n" <>
    "  1. CODE  - create or modify the package code files.\n" <>
    "  2. TESTS - create a Wolfram test file (name it \"test_" <> canon <> ".wls\") that loads the package via " <>
    "SourceVault`SourceVaultLoadWorkflow and checks behavior with assertions (Print PASS/FAIL counts).\n" <>
    "  3. RUN   - run the tests in your environment if you can.\n" <>
    "  4. VERIFY- confirm the results; if a test fails, fix the code and re-run until passing.\n\n" <>
    "Then output, in THIS ORDER and NOTHING else (no code fences):\n" <>
    "(A) EVERY file (package code AND the test file) as delimited blocks:\n" <>
    "<<<FILE relative/path>>>\n<the full verbatim file content>\n<<<ENDFILE>>>\n" <>
    "(B) a step log:\n" <>
    "<<<STEPS>>>\n" <>
    "CODE: <files created/modified + one-line summary>\n" <>
    "TESTS: <test file created + what it checks>\n" <>
    "RUN: <PASS|FAIL|NOT-RUN> - <how you ran them / key result>\n" <>
    "VERIFY: <your conclusion>\n" <>
    "<<<ENDSTEPS>>>\n" <>
    "(C) FAIL-CLOSED -- emit this block IF AND ONLY IF you could not ground a REQUIRED project/external " <>
    "API against its real definition (neither the SourceVault MCP packageapi index nor the real source " <>
    "resolved it). When present, the run STOPS with a warning and your files are NOT shipped, so include " <>
    "it ONLY when genuinely blocked (never as a routine note):\n" <>
    "<<<UNRESOLVED-API>>>\n" <>
    "<one line per unresolved API: fully-qualified name | what you tried (MCP packageapi / source grep) | why it stayed unresolved>\n" <>
    "<<<ENDUNRESOLVED>>>\n" <>
    "Use RELATIVE paths under the package folder and emit content VERBATIM (no escaping). " <>
    "Always include \"SVWorkflow_" <> canon <> ".wl\", \"SVWorkflow_" <> canon <>
      "_info/docs/examples/example.md\", and the test file.\n" <>
    "\n=== APPROVED SPEC ===\n" <> spec;
  out = iOrchQuery[model, prompt];
  (* delimiter-based manifest is robust for WL code (avoids JSON escaping of
     quotes/backslashes that frequently corrupts the manifest); JSON fallback. *)
  files = iParseFileManifest[out];
  steps = iParseSteps[out];
  testFiles = Select[Keys[files], StringContainsQ[#, "test", IgnoreCase -> True] &];
  <|"Files" -> files, "Steps" -> steps, "TestFiles" -> testFiles,
    "Unresolved" -> iParseUnresolved[out], "Raw" -> out|>];

(* extract the <<<STEPS>>> ... <<<ENDSTEPS>>> sub-step log (free-form lines) *)
iParseSteps[out_String] := Module[{m},
  m = StringCases[out, "<<<STEPS>>>" ~~ Shortest[s___] ~~ "<<<ENDSTEPS>>>" :> s, 1];
  If[m =!= {}, StringTrim[First[m]], ""]];
iParseSteps[_] := "";

(* L2 fail-closed: extract the <<<UNRESOLVED-API>>> ... <<<ENDUNRESOLVED>>> block.
   Its presence means the implementer could not ground a required project/external
   API and is REFUSING to guess -> the run stops with a warning (never ships code
   built on an invented API). Returns the reason text, or "" when not blocked. *)
iParseUnresolved[out_String] := Module[{m},
  m = StringCases[out,
    "<<<UNRESOLVED-API>>>" ~~ Shortest[s___] ~~ "<<<ENDUNRESOLVED>>>" :> s, 1];
  If[m =!= {}, StringTrim[First[m]], ""]];
iParseUnresolved[_] := "";

(* a compact RUN status (PASS/FAIL/NOT-RUN/-) parsed from a step log *)
iStepsRunStatus[steps_String] := Module[{m},
  m = StringCases[steps, RegularExpression["(?im)^\\s*RUN\\s*:\\s*(PASS|FAIL|NOT-RUN)"] :> "$1", 1];
  If[m =!= {}, ToUpperCase[First[m]], "-"]];
iStepsRunStatus[_] := "-";

(* parse a file manifest: first try <<<FILE path>>> ... <<<ENDFILE>>> blocks
   (no escaping needed for code), then fall back to a JSON {files:{...}} object. *)
iParseFileManifest[out_String] := Module[{blocks, files, json, f},
  blocks = StringCases[out,
    "<<<FILE" ~~ Whitespace ~~ path : Shortest[__] ~~ ">>>" ~~ ("\r" ...) ~~ "\n" ~~
      content : Shortest[___] ~~ ("\r" ...) ~~ "\n" ~~ "<<<ENDFILE>>>" :> {StringTrim[path], content}];
  files = Association[
    (#[[1]] -> #[[2]]) & /@ Select[blocks, StringQ[#[[1]]] && iSafeRelPathQ[#[[1]]] &]];
  If[Length[files] > 0, Return[files]];
  json = iExtractJSON[out];
  f = Lookup[json, "files", Lookup[json, "Files", <||>]];
  If[! AssociationQ[f], Return[<||>]];
  Association @ KeyValueMap[
    Function[{k, v}, If[StringQ[k] && StringQ[v] && iSafeRelPathQ[k], k -> v, Nothing]], f]];
iParseFileManifest[_] := <||>;

(* a relative path is safe if it has no drive/leading-slash and no ".." segment *)
iSafeRelPathQ[p_String] := Module[{q = StringReplace[p, "\\" -> "/"]},
  ! StringStartsQ[q, "/"] && ! StringContainsQ[q, ":"] &&
    ! MemberQ[StringSplit[q, "/"], ".." | ""] && StringTrim[q] =!= ""];
iSafeRelPathQ[_] := False;

(* VERIFY: verifier checks the generated files against the spec (+ stage). *)
iRealVerify[model_, payload_, filesText_] := Module[{prompt, out, json, verdict, findings, rtext, multi, idx, stages, stageTitle, canon, ctx},
  multi = TrueQ[Lookup[payload, "Multi", False]];
  stages = Lookup[payload, "Stages", {"(single)"}];
  idx = Lookup[payload, "StageIndex", 1];
  stageTitle = If[1 <= idx <= Length[stages], stages[[idx]], "(single)"];
  (* the registry-derived package context (slug -> CamelCase, kept escaped) is a
     FIXED value already enforced by the deterministic smoke test; surface it so
     the verifier never re-litigates naming (e.g. demands an ASCII context). *)
  canon = Lookup[payload, "Canon", iCanonicalName[Lookup[payload, "Name", "wf"]]];
  ctx = "SourceVaultWorkflow`" <> canon <> "`";
  prompt =
    "You are the verifier. Check whether the generated codified-workflow package below faithfully " <>
    "implements the APPROVED spec" <>
    If[multi, " for stage " <> ToString[idx] <> "/" <> ToString[Length[stages]] <> " (\"" <> stageTitle <> "\")", ""] <>
    ".\n\n" <>
    "ALREADY VALIDATED BY A DETERMINISTIC CHECK -- DO NOT FLAG OR ASK TO CHANGE THESE:\n" <>
    "The package file name, main .wl name and BeginPackage context are NOT free choices: the " <>
    "SourceVault registry derives them deterministically from the workflow slug, and a deterministic " <>
    "load check performed BEFORE you has ALREADY confirmed the source parses, that BeginPackage uses " <>
    "EXACTLY the required context \"" <> ctx <> "\" (with no empty needed-context list), and that " <>
    "WorkflowInfo[] is defined. This required context contains escaped Japanese (\\:XXXX) BY DESIGN; " <>
    "an ASCII context (e.g. a \"SpecV2\"-style ASCII leaf) would FAIL to load and is WRONG. NEVER " <>
    "request ASCII-izing, renaming, or otherwise changing the context / file name / BeginPackage form " <>
    "-- treat naming, syntax and load-ability as settled facts, never a finding.\n\n" <>
    "WHAT TO JUDGE -- SPEC FIDELITY ONLY: does the package implement the APPROVED requirements" <>
    If[multi, " for THIS stage", ""] <> "? When the APPROVED spec has an \"## Execution Profile\" " <>
    "with ExecutionClass \"simulation\", also check the simulation contract: bulk outputs must go to " <>
    "a SourceVaultSimRunCreate run folder and be finalized with SourceVaultSimRunFinalize (the run " <>
    "returns the sv:// URI + a small summary, never bulk data inline); subkernel parallelism must go " <>
    "through SourceVaultWithSubkernels (never bare LaunchKernels without closing); CUDA runs must " <>
    "gate on SourceVaultCUDARequire[] and fail gracefully on non-GPU machines; the no-arg launch " <>
    "must not start the simulation. A violation of this contract is a blocker. " <>
    "You MAY check that WorkflowInfo[] exposes a Launch entry, " <>
    "that a usage/example doc and a test file exist and are adequate, and that the code matches the " <>
    "spec. But a RUN result of NOT-RUN that the implementer attributes to the sandbox/approval gate " <>
    "is NOT, by itself, a blocker.\n" <>
    "If an \"=== EXECUTED TEST RESULT ===\" section appears below, it is the ACTUAL output of running the " <>
    "generated test in a fresh kernel just now. Treat a FAILED assertion about the SPEC or CORE LOGIC " <>
    "(data handling, normalization, the launch result, required behavior) as a blocker -> NeedsRevision. " <>
    "Do NOT block on a failure that is clearly the test's own fragility unrelated to the spec (e.g. a flaky " <>
    "file read inside the test); just note it in reviewText.\n" <>
    "Respond with EXACTLY one JSON object inside a ```json block and nothing else.\n" <>
    "Write the \"reviewText\" and every finding \"title\" in " <> iLangName[] <> ".\n" <>
    "Keep JSON keys and the \"verdict\"/\"severity\" enum values in ASCII.\n" <>
    "Schema: {\"verdict\":\"Approved\"|\"NeedsRevision\",\"findings\":[{\"id\":\"..\",\"severity\":\"blocker\"|\"minor\",\"title\":\"..\"}],\"reviewText\":\"..\"}\n" <>
    "If there are zero blocker findings, verdict is Approved.\n\n" <>
    "=== APPROVED SPEC ===\n" <> Lookup[payload, "Spec", ""] <> "\n\n" <>
    If[multi && StringQ[Lookup[payload, "AuxSpec", ""]] && Lookup[payload, "AuxSpec", ""] =!= "",
      "=== STAGED PLAN ===\n" <> Lookup[payload, "AuxSpec", ""] <> "\n\n", ""] <>
    With[{steps = Lookup[payload, "LastSteps", ""]},
      If[StringQ[steps] && steps =!= "", "=== IMPLEMENTER STEP LOG (code/tests/run/verify) ===\n" <> steps <> "\n\n", ""]] <>
    "=== GENERATED PACKAGE ===\n" <> filesText;
  out = iOrchQuery[model, prompt];
  json = iExtractJSON[out];
  verdict = Lookup[json, "verdict", iScanVerdict[out]];
  findings = Quiet @ Check[Developer`WriteRawJSONString[Lookup[json, "findings", {}]], "[]"];
  rtext = Lookup[json, "reviewText", out];
  <|"Verdict" -> If[verdict === "Approved", "Approved", "NeedsRevision"],
    "Findings" -> If[StringQ[findings], findings, "[]"], "ReviewText" -> rtext|>];

(* write a file manifest under TargetDir; returns the list of written rel paths *)
iWriteFiles[targetDir_, files_Association] := Module[{written = {}},
  KeyValueMap[
    Function[{rel, content},
      Module[{abs = FileNameJoin[Join[{targetDir}, StringSplit[StringReplace[rel, "\\" -> "/"], "/"]]]},
        Quiet @ Check[iWriteUTF8[abs, content]; AppendTo[written, rel], Null]]],
    files];
  written];

(* a concatenation of generated files (for the verifier prompt and artifact text) *)
iManifestText[files_Association] := StringRiffle[
  KeyValueMap[Function[{k, v}, "----- FILE: " <> k <> " -----\n" <> v], files], "\n\n"];

(* read the currently-on-disk generated files back as a manifest text *)
iReadGenerated[targetDir_, rels_List] := iManifestText[
  Association @ Map[
    Function[rel, rel -> iReadUTF8[FileNameJoin[Join[{targetDir},
      StringSplit[StringReplace[rel, "\\" -> "/"], "/"]]]]], rels]];

(* deterministic load check (static, no extra kernel): the generated main .wl
   must (a) parse, (b) open with BeginPackage["<expected ctx>`"] -- never with an
   empty needed-context list {} -- and (c) define WorkflowInfo. This catches the
   load-breaking defects a static LLM review misses (syntax errors,
   BeginPackage[ctx,{}], a wrong/missing BeginPackage context) WITHOUT spawning a
   second wolframscript (a nested kernel cannot acquire a license, and an
   in-kernel Get would leave sticky contexts that falsely pass later rounds).
   ToExpression decodes \\:XXXX so the parsed context matches the Unicode ctx. *)
iSmokeTestPackage[targetDir_, pkgRoot_, ctx_] := Module[
  {mains, mainFile, s, held, beginCtxs, emptyLists, hasWFInfo},
  mains = FileNames["SVWorkflow_*.wl", targetDir];
  If[mains === {}, mains = FileNames["*.wl", targetDir]];
  If[mains === {}, Return[<|"OK" -> False, "Output" -> "no .wl file was generated"|>]];
  mainFile = First[Sort[mains]];
  s = iReadUTF8[mainFile];
  held = Quiet @ Check[ToExpression[s, InputForm, HoldComplete], $Failed];
  If[! MatchQ[held, _HoldComplete],
    Return[<|"OK" -> False, "Output" -> "syntax error: the main .wl does not parse", "MainFile" -> mainFile|>]];
  (* :> forms avoid evaluating the held BeginPackage[...] when extracting *)
  beginCtxs = Quiet @ Cases[held, BeginPackage[c_String, ___] :> c, Infinity];
  emptyLists = Quiet @ Cases[held, BeginPackage[_String, {}] :> "empty", Infinity];
  hasWFInfo = StringContainsQ[s, "WorkflowInfo"];  (* the function name is ASCII regardless of \\:XXXX *)
  Which[
    beginCtxs === {},
      <|"OK" -> False, "Output" -> "no BeginPackage[...] found", "MainFile" -> mainFile|>,
    emptyLists =!= {},
      <|"OK" -> False, "Output" -> "invalid BeginPackage with an empty needed-context list {}", "MainFile" -> mainFile|>,
    ! MemberQ[beginCtxs, ctx],
      <|"OK" -> False, "Output" -> "BeginPackage context " <> First[beginCtxs] <> " does not match the expected " <> ctx, "MainFile" -> mainFile|>,
    ! hasWFInfo,
      <|"OK" -> False, "Output" -> "no WorkflowInfo definition found", "MainFile" -> mainFile|>,
    True,
      <|"OK" -> True, "Output" -> "static load check OK", "MainFile" -> mainFile|>]];

(* ---- dynamic gate: actually load + launch the package in a FRESH wolframscript
   kernel (separate process, so no sticky contexts / license-nesting in this
   kernel). Catches runtime defects the static smoke cannot: invalid/undefined
   context at load, undefined symbols, a no-arg launch that errors or returns
   Missing/$Failed. Returns <|"Ran", "OK", "Output", "Phase"|>. "Ran" -> False
   means wolframscript was unavailable (inconclusive -> do NOT block). ---- *)
$iDynHarnessScript = StringJoin[
  "Block[{$CharacterEncoding=\"UTF-8\"},\n",
  "Module[{cfg,res,lr,ctx,info,launch,sym,out,wfDir,pkgSrc,projTok,apiUndef},\n",
  " cfg=Get[$ScriptCommandLine[[2]]];\n",
  " res=<|\"OK\"->False,\"Phase\"->\"start\",\"Status\"->\"\",\"Output\"->\"\"|>;\n",
  " Quiet@Check[Get[cfg[\"SvPath\"]],$Failed];\n",
  " $Path=Prepend[$Path,cfg[\"PkgRoot\"]];\n",
  " lr=Quiet@Check[SourceVault`SourceVaultLoadWorkflow[cfg[\"Slug\"]],$Failed];\n",
  " res[\"Status\"]=If[AssociationQ[lr],ToString@Lookup[lr,\"Status\",\"?\"],ToString[lr]];\n",
  " If[!(AssociationQ[lr]&&MemberQ[{\"Loaded\",\"AlreadyLoaded\"},Lookup[lr,\"Status\",\"\"]]),\n",
  "   res[\"Phase\"]=\"load\";res[\"Output\"]=\"package did not load via SourceVaultLoadWorkflow (Status \"<>res[\"Status\"]<>\")\";\n",
  "   Put[res,cfg[\"ResultFile\"]];Exit[]];\n",
  (* L3 deterministic API-grounding gate: every project-context symbol the package
     references MUST resolve to a real, loaded symbol. SourceVault.wl auto-loads its
     subsystems (maildb/crypto/identity/...), so a name absent from Names[] here is a
     hallucinated / misspelled API -> HARD block. (Catches invented FUNCTION names;
     wrong options / return-shape on a REAL function are handled by the grounding
     prompt + the LLM verifier, not this static existence check.) *)
  " wfDir=If[AssociationQ[lr]&&StringQ[Lookup[lr,\"Path\",\"\"]],DirectoryName[lr[\"Path\"]],\"\"];\n",
  " pkgSrc=If[wfDir=!=\"\",StringJoin[(Quiet@Check[ByteArrayToString[ReadByteArray[#],\"UTF-8\"],\"\"])&/@FileNames[\"*.wl\",wfDir,Infinity]],\"\"];\n",
  " projTok=DeleteDuplicates@Flatten@Table[StringCases[pkgSrc,pfx~~n:((LetterCharacter|\"$\")~~(WordCharacter|\"$\")...):>pfx<>n],{pfx,{\"SourceVault`\",\"NBAccess`\",\"ClaudeCode`\",\"ClaudeOrchestrator`\"}}];\n",
  " apiUndef=Select[projTok,Names[#]==={}&];\n",
  " If[apiUndef=!={},res[\"Phase\"]=\"api-grounding\";res[\"OK\"]=False;\n",
  "   res[\"Output\"]=\"the package calls project APIs that DO NOT EXIST after loading (invented / misspelled): \"<>StringRiffle[apiUndef,\", \"]<>\". Ground every SourceVault`/NBAccess`/ClaudeCode` call against its real definition (SourceVault MCP packageapi or the real source) before calling it.\";\n",
  "   Put[res,cfg[\"ResultFile\"]];Exit[]];\n",
  " ctx=Quiet@SourceVault`SourceVaultWorkflowContext[cfg[\"Slug\"]];\n",
  " info=Quiet@Check[Symbol[ctx<>\"WorkflowInfo\"][],$Failed];\n",
  " If[!AssociationQ[info],res[\"Phase\"]=\"workflowinfo\";res[\"Output\"]=\"WorkflowInfo[] is not callable / not an Association\";\n",
  "   Put[res,cfg[\"ResultFile\"]];Exit[]];\n",
  " launch=Lookup[info,\"Launch\",\"\"];\n",
  " If[!(StringQ[launch]&&launch=!=\"\"),res[\"Phase\"]=\"launch-entry\";res[\"Output\"]=\"WorkflowInfo has no Launch entry\";\n",
  "   Put[res,cfg[\"ResultFile\"]];Exit[]];\n",
  " sym=Symbol[ctx<>launch];\n",
  " out=Quiet@Check[sym[],$Failed];\n",
  " If[out===$Failed||Head[out]===sym||MissingQ[out],res[\"Phase\"]=\"launch-call\";res[\"Output\"]=\"no-arg launch \"<>launch<>\"[] errored / did not evaluate / returned Missing\";\n",
  "   Put[res,cfg[\"ResultFile\"]];Exit[]];\n",
  " res[\"OK\"]=True;res[\"Phase\"]=\"ok\";res[\"Output\"]=\"load + WorkflowInfo[] + \"<>launch<>\"[] OK (Status \"<>res[\"Status\"]<>\")\";\n",
  " Put[res,cfg[\"ResultFile\"]];\n",
  "]]\n"];

iDynHarnessLoad[targetDir_, slug_, pkgRoot_] := Module[
  {ws, scriptFile, cfgFile, resultFile, runRes, res},
  ws = FileNameJoin[{$TemporaryDirectory, "svimpl_dyn_" <> StringReplace[CreateUUID[], "-" -> ""]}];
  Quiet @ CreateDirectory[ws, CreateIntermediateDirectories -> True];
  scriptFile = FileNameJoin[{ws, "dyntest.wls"}];
  cfgFile    = FileNameJoin[{ws, "dyncfg.wl"}];
  resultFile = FileNameJoin[{ws, "dynresult.wl"}];
  Block[{$CharacterEncoding = "UTF-8"},
    Put[<|"SvPath" -> FileNameJoin[{pkgRoot, "SourceVault.wl"}], "PkgRoot" -> pkgRoot,
      "Slug" -> slug, "ResultFile" -> resultFile|>, cfgFile]];
  iWriteUTF8[scriptFile, $iDynHarnessScript];
  runRes = Quiet @ Check[
    TimeConstrained[
      RunProcess[{$iWolframScript, "-file", scriptFile, cfgFile}, All],
      $iDynTestTimeLimit, "TimedOut"],
    "Error"];
  res = If[FileExistsQ[resultFile], Quiet @ Check[Get[resultFile], $Failed], $Failed];
  Quiet @ If[DirectoryQ[ws], DeleteDirectory[ws, DeleteContents -> True]];
  If[AssociationQ[res],
    <|"Ran" -> True, "OK" -> TrueQ[res["OK"]], "Output" -> Lookup[res, "Output", ""],
      "Phase" -> Lookup[res, "Phase", ""]|>,
    <|"Ran" -> False, "OK" -> False,
      "Output" -> "dynamic load test could not run (wolframscript unavailable or timed out): " <> ToString[runRes]|>]];

(* run the generated test file in a fresh kernel. ADVISORY: its result is
   surfaced to the LLM verifier as context (not a hard gate), because a test can
   fail on its own fragility rather than a real package defect. The hard
   deterministic gate is iDynHarnessLoad (load + no-arg launch). *)
iRunGenTest[targetDir_] := Module[{testFiles, testRes, exitCode, stdout},
  testFiles = FileNames["test_*.wls", targetDir];
  If[testFiles === {}, Return[<|"Ran" -> False, "OK" -> True, "Output" -> "(no test file)"|>]];
  testRes = Quiet @ Check[
    TimeConstrained[RunProcess[{$iWolframScript, "-file", First[testFiles]}, All],
      $iDynTestTimeLimit, "TimedOut"], "Error"];
  If[! AssociationQ[testRes],
    Return[<|"Ran" -> False, "OK" -> True, "Output" -> "(test run inconclusive: " <> ToString[testRes] <> ")"|>]];
  exitCode = Lookup[testRes, "ExitCode", 0];
  stdout = StringTrim[Lookup[testRes, "StandardOutput", ""] <> "\n" <> Lookup[testRes, "StandardError", ""]];
  <|"Ran" -> True, "OK" -> (exitCode === 0), "ExitCode" -> exitCode,
    "Output" -> (If[exitCode === 0, "test PASS (exit 0)\n",
        "test exited " <> ToString[exitCode] <> " (some assertions failed)\n"] <>
      StringTake[stdout, UpTo[1200]])|>];

(* ============================================================
   Handler factories (close over the role's resolved model + fn + progress)
   Each returns <|"Payload" -> newState|> and is message-quiet.
   ============================================================ *)

iProg[progressFile_, payload_, phase_, role_, model_, msg_] := iEmitProgress[progressFile, <|
  "Phase" -> phase, "Role" -> role, "Model" -> iModelLabel[model],
  "Stage" -> (With[{s = Lookup[payload, "Stages", {"(single)"}], i = Lookup[payload, "StageIndex", 1]},
     If[1 <= i <= Length[s], s[[i]], "(single)"]]),
  "StageIndex" -> Lookup[payload, "StageIndex", 1],
  "NumStages" -> Max[1, Length[Lookup[payload, "Stages", {"(single)"}]]],
  "Round" -> Lookup[payload, "Round", 1],
  "Verdict" -> Lookup[payload, "Verdict", ""],
  "Message" -> msg|>];

iPlanHandler[model_, planFn_, progressFile_] := Function[binding,
  Quiet @ Module[{pl, res, multi, stages, aux, ref},
    pl = iPayload[binding];
    iProg[progressFile, pl, "Plan", "implementer", model, "planning implementation"];
    res = planFn[model, pl];
    multi = TrueQ[Lookup[res, "Multi", False]];
    stages = Lookup[res, "Stages", {"(single)"}];
    aux = Lookup[res, "AuxSpec", ""];
    ref = If[multi && StringQ[aux] && aux =!= "",
      iSavePlan[Lookup[pl, "Name", "wf"], 1, multi, stages, aux], "none"];
    <|"Payload" -> Join[pl, <|
      "Multi" -> multi, "Stages" -> stages, "StageIndex" -> 1,
      "AuxSpec" -> aux, "AuxApproved" -> ! multi, "AuxRound" -> 0,
      "PlanRef" -> ref, "PlanURI" -> iRefToURI[ref]|>]|>]];

iAuxReviewHandler[vmodel_, imodel_, reviewFn_, reviseFn_, progressFile_] := Function[binding,
  Quiet @ Module[{pl, aux, rev, verdict, ref, auxRound, rr},
    pl = iPayload[binding];
    aux = Lookup[pl, "AuxSpec", ""];
    auxRound = Lookup[pl, "AuxRound", 0] + 1;
    iProg[progressFile, pl, "AuxReview", "verifier", vmodel,
      "reviewing staged plan (round " <> ToString[auxRound] <> ")"];
    rev = reviewFn[vmodel, pl, aux];
    verdict = Lookup[rev, "Verdict", "NeedsRevision"];
    ref = iSavePlanReview[Lookup[pl, "Name", "wf"], auxRound, verdict,
      Lookup[rev, "Findings", "[]"], Lookup[pl, "PlanRef", "none"], Lookup[rev, "ReviewText", ""]];
    If[verdict === "Approved",
      <|"Payload" -> Join[pl, <|"AuxApproved" -> True, "AuxRound" -> auxRound,
          "PlanReviewRef" -> ref, "PlanReviewURI" -> iRefToURI[ref]|>]|>,
      (* needs revision: implementer revises the aux spec for the next round *)
      iProg[progressFile, pl, "AuxRevise", "implementer", imodel, "revising staged plan"];
      rr = reviseFn[imodel, pl, aux, Lookup[rev, "ReviewText", ""]];
      With[{newAux = Lookup[rr, "AuxSpec", aux], newStages = Lookup[rr, "Stages", Lookup[pl, "Stages", {"(single)"}]]},
        Module[{pref = iSavePlan[Lookup[pl, "Name", "wf"], auxRound + 1, True, newStages, newAux]},
          <|"Payload" -> Join[pl, <|"AuxApproved" -> False, "AuxRound" -> auxRound,
              "AuxSpec" -> newAux, "Stages" -> newStages,
              "PlanRef" -> pref, "PlanURI" -> iRefToURI[pref],
              "PlanReviewRef" -> ref, "PlanReviewURI" -> iRefToURI[ref]|>]|>]]]]];

iToImplHandler[progressFile_] := Function[binding,
  Quiet @ Module[{pl}, pl = iPayload[binding];
    iProg[progressFile, pl, "ToImpl", "implementer", "", "entering implementation phase"];
    <|"Payload" -> Join[pl, <|"StageIndex" -> 1, "Round" -> 1|>]|>]];

iImplementHandler[model_, implFn_, progressFile_, targetDir_] := Function[binding,
  Quiet @ Module[{pl, res, files, steps, testFiles, written, allFiles, manifestText, artifactText, ref, idx, emptyImpl, unresolved, implBlocked},
    pl = iPayload[binding];
    idx = Lookup[pl, "StageIndex", 1];
    iProg[progressFile, pl, "Implement", "implementer", model,
      "implementing stage " <> ToString[idx] <> "/" <> ToString[Max[1, Length[Lookup[pl, "Stages", {"x"}]]]] <>
      " (code/tests/run/verify, round " <> ToString[Lookup[pl, "Round", 1]] <> ")"];
    res = implFn[model, pl];
    files = Lookup[res, "Files", <||>];
    steps = Lookup[res, "Steps", ""];
    testFiles = Lookup[res, "TestFiles", {}];
    written = If[AssociationQ[files] && Length[files] > 0, iWriteFiles[targetDir, files], {}];
    (* L2 fail-closed: the implementer emitted an <<<UNRESOLVED-API>>> block -- it
       could not ground a required project/external API and refused to guess. STOP
       with a warning (route to Blocked in the net) instead of shipping/looping. *)
    unresolved = Lookup[res, "Unresolved", ""];
    implBlocked = StringQ[unresolved] && StringTrim[unresolved] =!= "";
    If[implBlocked,
      steps = "IMPL BLOCKED: the implementer (" <> iModelLabel[model] <> ") could not verify a required " <>
        "project/external API against ground truth (SourceVault MCP packageapi / real source) and refused " <>
        "to invent one, so no runnable implementation was produced. Resolve the API contract (or amend the " <>
        "spec to pin the exact integration API) and re-run.\n--- UNRESOLVED APIs ---\n" <> unresolved <>
        If[StringQ[Lookup[res, "Steps", ""]] && StringTrim[Lookup[res, "Steps", ""]] =!= "",
          "\n--- implementer step log ---\n" <> Lookup[res, "Steps", ""], ""]];
    (* empty-LLM-response guard: when the implementer returns nothing (no files AND
       no raw text) it is almost always a transient provider failure -- a Claude
       usage/rate limit or an HTTP 529 overload -- NOT a fixable code defect. Record
       a clear reason and force give-up after THIS round instead of silently looping
       into repeated "no .wl generated" smoke rejections. *)
    emptyImpl = (written === {} &&
      With[{raw = Lookup[res, "Raw", ""]}, ! StringQ[raw] || StringTrim[raw] === ""]);
    If[emptyImpl,
      steps = "IMPL ERROR: the implementer model (" <> iModelLabel[model] <> ") returned an EMPTY " <>
        "response -- no code was generated. This is almost always a transient provider issue " <>
        "(a Claude usage/rate limit, or an HTTP 529 overload), not a spec/implementation defect. " <>
        "Re-run later, or reduce concurrent load (close extra kernels/jobs)."];
    allFiles = DeleteDuplicates[Join[Lookup[pl, "GeneratedFiles", {}], written]];
    manifestText = iManifestText[If[AssociationQ[files], files, <||>]];
    (* the artifact's stored Text begins with the code/tests/run/verify step log
       so clicking the artifact sv:// URI shows the implementation process *)
    artifactText = If[StringQ[steps] && steps =!= "",
      "=== IMPLEMENTATION STEPS (code / tests / run / verify) ===\n" <> steps <> "\n\n", ""] <> manifestText;
    iProg[progressFile, pl, "Implement", "implementer", model,
      Which[
        implBlocked,
          "stage " <> ToString[idx] <> ": BLOCKED -- a required API could not be verified (see warning); stopping",
        emptyImpl,
          "stage " <> ToString[idx] <> ": EMPTY model response (likely usage limit / overload) -- giving up",
        True,
          "stage " <> ToString[idx] <> " run: " <> iStepsRunStatus[steps] <>
          " (" <> ToString[Length[written]] <> " files, " <> ToString[Length[testFiles]] <> " test)"]];
    ref = iSaveArtifact[Lookup[pl, "Name", "wf"], idx, Lookup[pl, "Round", 1],
      written, testFiles, steps, artifactText];
    <|"Payload" -> Join[pl, <|"GeneratedFiles" -> allFiles, "StageFiles" -> written,
        "TestFiles" -> testFiles, "LastSteps" -> steps, "ImplEmpty" -> emptyImpl,
        (* L2: carry the fail-closed flag + reason so the net routes to Blocked *)
        "ImplBlocked" -> implBlocked,
        "BlockReason" -> If[implBlocked, unresolved, Lookup[pl, "BlockReason", ""]],
        (* on an empty response, jump Round to MaxRounds so the post-verify routing
           gives up immediately instead of retrying into the same empty result *)
        "Round" -> If[emptyImpl, Lookup[pl, "MaxRounds", $DefaultMaxRounds], Lookup[pl, "Round", 1]],
        "ArtifactRef" -> ref, "ArtifactURI" -> iRefToURI[ref], "ImplModel" -> iModelLabel[model]|>]|>]];

iVerifyHandler[model_, verifyFn_, progressFile_, targetDir_, smokeQ_:True] := Function[binding,
  Quiet @ Module[{pl, idx, ctx, smoke, dyn, gentest, filesText, res, verdict, findings, rtext, ref},
    pl = iPayload[binding];
    idx = Lookup[pl, "StageIndex", 1];
    iProg[progressFile, pl, "Verify", "verifier", model,
      "verifying stage " <> ToString[idx] <> " (round " <> ToString[Lookup[pl, "Round", 1]] <> ")"];
    (* deterministic gate first: the generated package MUST load standalone.
       A static LLM review cannot catch load-breaking defects, so a failed smoke
       test forces NeedsRevision with a concrete, actionable finding (and we skip
       the LLM verify to save a round-trip). *)
    ctx = "SourceVaultWorkflow`" <> iCanonicalName[Lookup[pl, "Name", "wf"]] <> "`";
    smoke = If[TrueQ[smokeQ],
      iProg[progressFile, pl, "Verify", "verifier", model, "load smoke-test"];
      iSmokeTestPackage[targetDir, Lookup[pl, "PackageRoot", $pkgRoot], ctx],
      <|"OK" -> True|>];
    If[! TrueQ[Lookup[smoke, "OK", False]],
      verdict = "NeedsRevision";
      findings = "[{\"id\":\"load-smoke\",\"severity\":\"blocker\",\"title\":\"generated package fails to load standalone\"}]";
      rtext = "LOAD SMOKE-TEST FAILED: SourceVault`SourceVaultLoadWorkflow could not load the generated package and WorkflowInfo[] was not callable with a Launch entry. " <>
        "Likely causes: BeginPackage with an empty needed-context list (use BeginPackage[\"<ctx>`\"] with NO second argument, never {}); a syntax error; or a BeginPackage context that is not exactly \"" <> ctx <> "\". " <>
        "Fix so the package loads cleanly. Smoke output: " <> Lookup[smoke, "Output", ""],
      (* static smoke passed -> DYNAMIC HARD GATE: really load the package + call
         its no-arg launch in a fresh wolframscript kernel. This deterministically
         catches runtime defects the static check and a static LLM review miss
         (invalid/undefined context, undefined symbols, a launch returning
         Missing/$Failed). *)
      dyn = If[TrueQ[$iDynTest],
        iProg[progressFile, pl, "Verify", "verifier", model, "dynamic load+launch (fresh kernel)"];
        iDynHarnessLoad[targetDir, Lookup[pl, "Name", "wf"], Lookup[pl, "PackageRoot", $pkgRoot]],
        <|"Ran" -> False, "OK" -> True|>];
      If[TrueQ[dyn["Ran"]] && ! TrueQ[dyn["OK"]],
        verdict = "NeedsRevision";
        If[Lookup[dyn, "Phase", ""] === "api-grounding",
          (* L3: the package calls a project API that does not exist -> a hallucinated
             / misspelled function name, caught deterministically before the LLM. *)
          findings = "[{\"id\":\"api-grounding\",\"severity\":\"blocker\",\"title\":\"calls a project API that does not exist (invented/misspelled)\"}]";
          rtext = "API-GROUNDING CHECK FAILED -- after loading SourceVault (which auto-loads its subsystems) in a fresh kernel, " <>
            "the generated package references project symbols that DO NOT EXIST. " <> Lookup[dyn, "Output", ""] <> " " <>
            "For EACH such call, confirm the real name/signature via the SourceVault MCP packageapi index " <>
            "(sourcevault_search kinds:[\"packageapi\"] then sourcevault_get view:\"contract\") or the real source, " <>
            "and NEVER invent an API. If a required API genuinely cannot be resolved, emit the UNRESOLVED-API block.",
          findings = "[{\"id\":\"dyn-load\",\"severity\":\"blocker\",\"title\":\"package fails to load / run in a fresh kernel\"}]";
          rtext = "DYNAMIC LOAD TEST FAILED -- the package was ACTUALLY loaded in a fresh wolframscript kernel " <>
            "via SourceVault`SourceVaultLoadWorkflow and its no-arg launch entry was called. " <>
            "Result: " <> Lookup[dyn, "Output", ""] <> " " <>
            "Fix so the package loads with no error messages and the no-arg launch returns cleanly (no Missing/$Failed)."],
        (* load gate OK (or inconclusive) -> run the generated test (ADVISORY) and
           feed its real output to the LLM verifier, then verify against the spec *)
        gentest = If[TrueQ[$iDynTest] && TrueQ[dyn["Ran"]],
          iProg[progressFile, pl, "Verify", "verifier", model, "running generated test (fresh kernel)"];
          iRunGenTest[targetDir],
          <|"Ran" -> False, "Output" -> ""|>];
        filesText = iReadGenerated[targetDir, Lookup[pl, "GeneratedFiles", {}]] <>
          If[TrueQ[gentest["Ran"]],
            "\n\n=== EXECUTED TEST RESULT (the generated test was run in a fresh wolframscript kernel) ===\n" <>
              Lookup[gentest, "Output", ""] <> "\n", ""];
        res = verifyFn[model, pl, filesText];
        verdict = Lookup[res, "Verdict", "NeedsRevision"];
        findings = Lookup[res, "Findings", "[]"];
        rtext = Lookup[res, "ReviewText", ""]]];
    ref = iSaveVerify[Lookup[pl, "Name", "wf"], idx, Lookup[pl, "Round", 1],
      verdict, findings, Lookup[pl, "ArtifactRef", "none"], rtext];
    <|"Payload" -> Join[pl, <|"Verdict" -> verdict, "VerifyRef" -> ref,
        "VerifyURI" -> iRefToURI[ref], "LastVerifyText" -> rtext,
        "VerifyModel" -> iModelLabel[model], "SmokeOK" -> TrueQ[Lookup[smoke, "OK", False]]|>]|>]];

iApproveHandler[progressFile_] := Function[binding,
  Quiet @ Module[{pl}, pl = iPayload[binding];
    iProg[progressFile, pl, "Approved", "", "", "implementation approved"];
    <|"Payload" -> Join[pl, <|"Status" -> "Approved"|>]|>]];

iNextStageHandler[progressFile_] := Function[binding,
  Quiet @ Module[{pl}, pl = iPayload[binding];
    iProg[progressFile, pl, "NextStage", "", "", "advancing to next stage"];
    <|"Payload" -> Join[pl, <|"StageIndex" -> Lookup[pl, "StageIndex", 1] + 1,
        "Round" -> 1, "Verdict" -> "Pending", "LastVerifyText" -> ""|>]|>]];

iReviseHandler[progressFile_] := Function[binding,
  Quiet @ Module[{pl}, pl = iPayload[binding];
    iProg[progressFile, pl, "Revise", "implementer", "", "revising after verification"];
    <|"Payload" -> Join[pl, <|"Round" -> Lookup[pl, "Round", 1] + 1, "Verdict" -> "Pending"|>]|>]];

iGiveUpHandler[progressFile_] := Function[binding,
  Quiet @ Module[{pl}, pl = iPayload[binding];
    iProg[progressFile, pl, "Failed", "", "", "gave up after max rounds"];
    <|"Payload" -> Join[pl, <|"Status" -> "GaveUp"|>]|>]];

(* L2 fail-closed terminal: reached when the implementer declared a required API
   unresolved (ImplBlocked). Stops the run with Status "Blocked" and a warning; the
   FE surfaces BlockReason so the user knows exactly which API could not be verified. *)
iBlockHandler[progressFile_] := Function[binding,
  Quiet @ Module[{pl}, pl = iPayload[binding];
    iProg[progressFile, pl, "Blocked", "", "",
      "stopped: a required API could not be verified against ground truth (fail-closed)"];
    <|"Payload" -> Join[pl, <|"Status" -> "Blocked"|>]|>]];

(* ============================================================
   Net builder
   ============================================================ *)

Options[BuildNet] = {
  "MaxRounds" -> Automatic,
  "MaxAuxRounds" -> Automatic,
  "ClaudeModel" -> Automatic,
  "AdvisaryModel" -> Automatic,
  "PlanFunction" -> Automatic,
  "PlanReviewFunction" -> Automatic,
  "PlanReviseFunction" -> Automatic,
  "ImplementFunction" -> Automatic,
  "VerifyFunction" -> Automatic,
  "ProgressFile" -> None,
  "SmokeTest" -> True,
  "TargetDir" -> Automatic};

BuildNet[name_String, opts:OptionsPattern[]] := Module[
  {claude, advisary, planFn, planReviewFn, planReviseFn, implFn, verifyFn,
   progressFile, smokeQ, targetDir, spec, wid},
  claude   = iResolveClaude[OptionValue["ClaudeModel"]];
  advisary = iResolveAdvisary[OptionValue["AdvisaryModel"]];
  planFn       = OptionValue["PlanFunction"] /. Automatic -> iRealPlan;
  planReviewFn = OptionValue["PlanReviewFunction"] /. Automatic -> iRealPlanReview;
  planReviseFn = OptionValue["PlanReviseFunction"] /. Automatic -> iRealPlanRevise;
  implFn   = OptionValue["ImplementFunction"] /. Automatic -> iRealImplement;
  verifyFn = OptionValue["VerifyFunction"] /. Automatic -> iRealVerify;
  progressFile = OptionValue["ProgressFile"];
  smokeQ = TrueQ[OptionValue["SmokeTest"]];
  targetDir = OptionValue["TargetDir"] /. Automatic ->
    FileNameJoin[{$pkgRoot, "SourceVault_workflows", "testing", name}];

  spec = <|
    "SourcePlace" -> "NeedPlan",
    "FinalPlaces" -> {"Approved", "Failed", "Blocked"},
    "Description" -> "Implement spec as codified workflow: " <> name,
    "Places" -> <|
      "NeedPlan"    -> WorkflowPlace["NeedPlan"],
      "Planned"     -> WorkflowPlace["Planned"],
      "NeedImpl"    -> WorkflowPlace["NeedImpl"],
      "Implemented" -> WorkflowPlace["Implemented"],
      "Verified"    -> WorkflowPlace["Verified"],
      "Approved"    -> WorkflowPlace["Approved"],
      "Failed"      -> WorkflowPlace["Failed"],
      "Blocked"     -> WorkflowPlace["Blocked"]|>,
    "Transitions" -> <|
      "Plan" -> WorkflowTransition["Plan",
        "InputArcs" -> {<|"Place" -> "NeedPlan"|>},
        "OutputArcs" -> {<|"Place" -> "Planned", "TokenKind" -> "Artifact"|>},
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iPlanHandler[claude, planFn, progressFile]|>],
      "AuxReview" -> WorkflowTransition["AuxReview",
        "InputArcs" -> {<|"Place" -> "Planned"|>},
        "OutputArcs" -> {<|"Place" -> "Planned", "TokenKind" -> "Artifact"|>},
        "Guard" -> Function[b, iMulti[b] && ! iAuxApproved[b] && iAuxRound[b] < iMaxAuxRounds[b]],
        "Priority" -> 10,
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iAuxReviewHandler[advisary, claude, planReviewFn, planReviseFn, progressFile]|>],
      "ToImpl" -> WorkflowTransition["ToImpl",
        "InputArcs" -> {<|"Place" -> "Planned"|>},
        "OutputArcs" -> {<|"Place" -> "NeedImpl", "TokenKind" -> "Artifact"|>},
        "Guard" -> Function[b, ! iMulti[b] || iAuxApproved[b] || iAuxRound[b] >= iMaxAuxRounds[b]],
        "Priority" -> 5,
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iToImplHandler[progressFile]|>],
      "Implement" -> WorkflowTransition["Implement",
        "InputArcs" -> {<|"Place" -> "NeedImpl"|>},
        "OutputArcs" -> {<|"Place" -> "Implemented", "TokenKind" -> "Artifact"|>},
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iImplementHandler[claude, implFn, progressFile, targetDir]|>],
      (* L2 fail-closed: an implement that declared a required API unresolved goes
         straight to the terminal Blocked place (higher priority than Verify). *)
      "Block" -> WorkflowTransition["Block",
        "InputArcs" -> {<|"Place" -> "Implemented"|>},
        "OutputArcs" -> {<|"Place" -> "Blocked", "TokenKind" -> "Artifact"|>},
        "Guard" -> Function[b, iImplBlocked[b]],
        "Priority" -> 20,
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iBlockHandler[progressFile]|>],
      "Verify" -> WorkflowTransition["Verify",
        "InputArcs" -> {<|"Place" -> "Implemented"|>},
        "OutputArcs" -> {<|"Place" -> "Verified", "TokenKind" -> "Artifact"|>},
        "Guard" -> Function[b, ! iImplBlocked[b]],
        "Priority" -> 1,
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iVerifyHandler[advisary, verifyFn, progressFile, targetDir, smokeQ]|>],
      "Approve" -> WorkflowTransition["Approve",
        "InputArcs" -> {<|"Place" -> "Verified"|>},
        "OutputArcs" -> {<|"Place" -> "Approved", "TokenKind" -> "Artifact"|>},
        "Guard" -> Function[b, iVerdict[b] === "Approved" && iStageIndex[b] >= iNumStages[b]],
        "Priority" -> 10,
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iApproveHandler[progressFile]|>],
      "NextStage" -> WorkflowTransition["NextStage",
        "InputArcs" -> {<|"Place" -> "Verified"|>},
        "OutputArcs" -> {<|"Place" -> "NeedImpl", "TokenKind" -> "Artifact"|>},
        "Guard" -> Function[b, iVerdict[b] === "Approved" && iStageIndex[b] < iNumStages[b]],
        "Priority" -> 7,
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iNextStageHandler[progressFile]|>],
      "Revise" -> WorkflowTransition["Revise",
        "InputArcs" -> {<|"Place" -> "Verified"|>},
        "OutputArcs" -> {<|"Place" -> "NeedImpl", "TokenKind" -> "Artifact"|>},
        "Guard" -> Function[b, iVerdict[b] === "NeedsRevision" && iRound[b] < iMaxRounds[b]],
        "Priority" -> 5,
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iReviseHandler[progressFile]|>],
      "GiveUp" -> WorkflowTransition["GiveUp",
        "InputArcs" -> {<|"Place" -> "Verified"|>},
        "OutputArcs" -> {<|"Place" -> "Failed", "TokenKind" -> "Artifact"|>},
        "Guard" -> Function[b, iVerdict[b] === "NeedsRevision" && iRound[b] >= iMaxRounds[b]],
        "Priority" -> 1,
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iGiveUpHandler[progressFile]|>]|>|>;

  wid = ClaudeCreateWorkflowNet[spec];
  wid];

(* ============================================================
   Runner
   ============================================================ *)

Options[RunSpecImpl] = Join[Options[BuildNet],
  {"Spec" -> "", "SpecRef" -> "", "Notes" -> "", "PackageRoot" -> Automatic,
   "LanguageInstruction" -> "",
   "InitialState" -> <||>, "MaxSteps" -> 400, "MaxWait" -> Quantity[2400, "Seconds"]}];

(* resolve a Spec option that may be sv:// URI / snapshot ref / raw text *)
iResolveSpec[specOpt_, specRefOpt_] := Module[{ref, rec},
  ref = Which[
    StringQ[specRefOpt] && specRefOpt =!= "", specRefOpt,
    StringQ[specOpt] && (StringStartsQ[specOpt, "sv://"] || StringStartsQ[specOpt, "snapshot:"]), specOpt,
    True, ""];
  If[ref =!= "",
    rec = Quiet @ SourceVaultLoadImmutableSnapshot[iSpecURIToRef[ref]];
    If[AssociationQ[rec], Return[Lookup[rec, "Text", ""]]]];
  If[StringQ[specOpt], specOpt, ""]];

iSpecURIToRef[s_String] := Module[{body, parts},
  Which[
    StringStartsQ[s, "snapshot:"], s,
    StringStartsQ[s, "sv://snapshot/"],
      body = StringDrop[s, StringLength["sv://snapshot/"]];
      parts = StringSplit[body, {"/", ":"}];
      If[Length[parts] >= 2, "snapshot:" <> parts[[1]] <> ":" <> Last[parts], s],
    True, s]];
iSpecURIToRef[x_] := x;

RunSpecImpl[name_String, opts:OptionsPattern[]] := Module[
  {maxRounds, maxAux, packageRoot, targetDir, canon, specText, notes, langInstr,
   progressFile, wid, initPayload, tok, run, st, finalTok, finalPayload},
  maxRounds = OptionValue["MaxRounds"] /. Automatic -> $DefaultMaxRounds;
  maxAux = OptionValue["MaxAuxRounds"] /. Automatic -> $DefaultMaxAuxRounds;
  packageRoot = OptionValue["PackageRoot"] /. Automatic -> $pkgRoot;
  canon = iCanonicalName[name];
  targetDir = OptionValue["TargetDir"] /. Automatic ->
    FileNameJoin[{packageRoot, "SourceVault_workflows", "testing", name}];
  specText = iResolveSpec[OptionValue["Spec"], OptionValue["SpecRef"]];
  notes = OptionValue["Notes"] /. (x_ /; ! StringQ[x]) -> "";
  langInstr = OptionValue["LanguageInstruction"] /. (x_ /; ! StringQ[x]) -> "";
  progressFile = OptionValue["ProgressFile"];

  wid = BuildNet[name,
    "MaxRounds" -> maxRounds, "MaxAuxRounds" -> maxAux,
    "ClaudeModel" -> OptionValue["ClaudeModel"], "AdvisaryModel" -> OptionValue["AdvisaryModel"],
    "PlanFunction" -> OptionValue["PlanFunction"],
    "PlanReviewFunction" -> OptionValue["PlanReviewFunction"],
    "PlanReviseFunction" -> OptionValue["PlanReviseFunction"],
    "ImplementFunction" -> OptionValue["ImplementFunction"],
    "VerifyFunction" -> OptionValue["VerifyFunction"],
    "SmokeTest" -> OptionValue["SmokeTest"],
    "ProgressFile" -> progressFile, "TargetDir" -> targetDir];

  initPayload = Join[<|
    "Name" -> name, "Canon" -> canon, "Spec" -> specText, "Notes" -> notes,
    "LanguageInstruction" -> langInstr,
    "TargetDir" -> targetDir, "PackageRoot" -> packageRoot,
    "Round" -> 1, "MaxRounds" -> maxRounds, "MaxAuxRounds" -> maxAux,
    "Verdict" -> "Pending", "StageIndex" -> 1, "Stages" -> {"(single)"},
    "Multi" -> False, "AuxApproved" -> False, "AuxRound" -> 0,
    "GeneratedFiles" -> {}, "LastVerifyText" -> ""|>,
    OptionValue["InitialState"]];

  tok = WorkflowToken["Kind" -> "Artifact", "Payload" -> initPayload];
  ClaudeSubmitToken[wid, tok];

  run = ClaudeRunWorkflow[wid, "MaxSteps" -> OptionValue["MaxSteps"],
    "MaxWait" -> OptionValue["MaxWait"]];

  st = ClaudeWorkflowState[wid];
  finalTok = iFinalToken[st];
  finalPayload = If[AssociationQ[finalTok], Lookup[finalTok, "Payload", <||>], <||>];

  <|"WorkflowId" -> wid,
    "Name" -> name,
    "TargetDir" -> targetDir,
    "RunStatus" -> Lookup[run, "Status", run],
    "Termination" -> Lookup[run, "TerminationReason", "-"],
    "FinalStatus" -> Lookup[finalPayload, "Status",
      If[KeyExistsQ[markingPlaces[st], "Approved"] &&
         Length[markingPlaces[st]["Approved"]] > 0, "Approved", "Unknown"]],
    "Multi" -> TrueQ[Lookup[finalPayload, "Multi", False]],
    "Stages" -> Lookup[finalPayload, "Stages", {"(single)"}],
    "Rounds" -> Lookup[finalPayload, "Round", Missing[]],
    "FinalVerdict" -> Lookup[finalPayload, "Verdict", Missing[]],
    "BlockReason" -> Lookup[finalPayload, "BlockReason", ""],
    "GeneratedFiles" -> Lookup[finalPayload, "GeneratedFiles", {}],
    "ImplModel" -> Lookup[finalPayload, "ImplModel", Missing[]],
    "VerifyModel" -> Lookup[finalPayload, "VerifyModel", Missing[]],
    "PlanURI" -> Lookup[finalPayload, "PlanURI", Missing[]],
    "ArtifactURI" -> Lookup[finalPayload, "ArtifactURI", Missing[]],
    "VerifyURI" -> Lookup[finalPayload, "VerifyURI", Missing[]],
    "PlanChain" -> (iRefToURI[Lookup[#, "Value", ""]] & /@ iChain["impl/" <> name <> "/plan"]),
    "ArtifactChain" -> (iRefToURI[Lookup[#, "Value", ""]] & /@ iChain["impl/" <> name <> "/artifact"]),
    "VerifyChain" -> (iRefToURI[Lookup[#, "Value", ""]] & /@ iChain["impl/" <> name <> "/verify"]),
    "FinalPayload" -> finalPayload|>];

iChain[ptr_] := With[{h = Quiet @ SourceVaultPointerHistory[ptr]}, If[ListQ[h], h, {}]];

markingPlaces[st_] := Lookup[st, "Marking", <||>];

iFinalToken[st_] := Module[{mk, tokens, ids},
  mk = Lookup[st, "Marking", <||>];
  tokens = Lookup[st, "Tokens", <||>];
  ids = Join[Lookup[mk, "Approved", {}], Lookup[mk, "Failed", {}], Lookup[mk, "Blocked", {}]];
  If[ids === {}, Missing["NoFinalToken"], Lookup[tokens, First[ids], Missing[]]]];

End[]
EndPackage[]
