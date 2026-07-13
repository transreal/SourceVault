(* ::Package:: *)

(* ============================================================
   SVWorkflow_SpecReview.wl  (context: SourceVaultWorkflow`SpecReview`)

   SourceVault workflow: Codex<->Claude spec review-and-revise loop,
   built as a ClaudeOrchestrator WorkflowNet (layer-2 codified workflow).

   Lives under SourceVault_workflows/spec-review/ and is loaded ON DEMAND via
   SourceVault`SourceVaultLoadWorkflow["spec-review"] (NOT auto-loaded).
   Public entry points: RunSpecReview, BuildNet, WorkflowInfo, $DefaultMaxRounds.

   Roles map to models generically:
     - Claude Code (review / codegen) role  -> ClaudeCode`$ClaudeModel
     - Codex (advisory / draft) role        -> ClaudeCode`$ClaudeAdvisaryModel

   The loop:
     NeedDraft --Draft(codex)--> Drafted --Review(claude)--> Reviewed
       Reviewed --[verdict=Approved]--> Approved   (codegen)
       Reviewed --[NeedsRevision & round<max]--> NeedDraft (round+1)
       Reviewed --[NeedsRevision & round>=max]--> Failed

   Artifacts/version chain live in SourceVault (snapshot + pointer),
   identical contract to test codes/orch_vault.wls.

   Encoded in UTF-8 (no BOM).
   ============================================================ *)

(* ---- ensure dependencies are loaded before BeginPackage ----
   package root = three levels up from
   .../SourceVault_workflows/spec-review/SVWorkflow_SpecReview.wl *)
SourceVaultWorkflow`SpecReview`Private`$pkgRoot =
  Which[
    StringQ[$InputFileName] && $InputFileName =!= "",
      DirectoryName[$InputFileName, 3],
    StringQ[Quiet @ Check[Symbol["Global`$packageDirectory"], $Failed]],
      Symbol["Global`$packageDirectory"],
    True, "F:/Dropbox/Mathematica-oneDrive/MyPackages"];

(* base orchestrator (also pulls in ClaudeCode`) *)
If[Length[DownValues[ClaudeOrchestrator`ClaudePlanTasks]] === 0,
  Block[{$CharacterEncoding = "UTF-8"},
    Get[FileNameJoin[{SourceVaultWorkflow`SpecReview`Private`$pkgRoot, "ClaudeOrchestrator.wl"}]]]];

(* workflow engine (ClaudeOrchestrator`Workflow`): not auto-loaded by the base file *)
If[Length[DownValues[ClaudeOrchestrator`Workflow`ClaudeCreateWorkflowNet]] === 0,
  Block[{$CharacterEncoding = "UTF-8"},
    Get[FileNameJoin[{SourceVaultWorkflow`SpecReview`Private`$pkgRoot, "ClaudeOrchestrator_workflow.wl"}]]]];

If[Length[DownValues[SourceVault`SourceVaultSaveImmutableSnapshot]] === 0,
  Block[{$CharacterEncoding = "UTF-8"},
    Get[FileNameJoin[{SourceVaultWorkflow`SpecReview`Private`$pkgRoot, "SourceVault.wl"}]]]];

BeginPackage["SourceVaultWorkflow`SpecReview`", {"ClaudeOrchestrator`Workflow`", "SourceVault`"}]

BuildNet::usage =
  "BuildNet[project, opts] builds and registers a ClaudeOrchestrator WorkflowNet for the Codex<->Claude spec review-and-revise loop and returns its workflow id. Options: \"MaxRounds\", \"AdvisaryModel\" (Codex role; default ClaudeCode`$ClaudeAdvisaryModel), \"ClaudeModel\" (Claude role; default ClaudeCode`$ClaudeModel), \"DraftFunction\", \"ReviewFunction\", \"CodegenFunction\".";

RunSpecReview::usage =
  "RunSpecReview[project, opts] builds the net, submits the initial token, runs the workflow synchronously, and returns a summary association (FinalStatus, Rounds, FinalPayload, SpecChain, ReviewChain). Same options as BuildNet plus \"PromptFile\" and \"InitialState\".";

$DefaultMaxRounds::usage =
  "$DefaultMaxRounds is the default maximum number of review rounds before the workflow gives up.";

WorkflowInfo::usage =
  "WorkflowInfo[] returns metadata for this SourceVault workflow (Slug, Name, Version, Context, Launch entry, Description, and the prompt-route specs to register).";

Begin["`Private`"]

If[!ValueQ[$DefaultMaxRounds], $DefaultMaxRounds = 6];

(* ---- workflow contract: metadata for the SourceVault workflow registry ----
   SourceVaultLoadWorkflow / promptrouter read this to register routes and to
   discover the launch entry point. *)
WorkflowInfo[] := <|
  "Slug" -> "spec-review",
  "Name" -> "Codex<->Claude Spec Review",
  "Version" -> "1.0",
  "Context" -> "SourceVaultWorkflow`SpecReview`",
  "Launch" -> "RunSpecReview",
  "Description" ->
    "Codex drafts a spec, Claude reviews; revise/approve loop with SourceVault " <>
    "snapshot+pointer versioning. An approved spec can be codegen'd to a .wl package.",
  "Routes" -> {}
|>;

(* ---- model resolution: role -> generic constant ---- *)
iResolveAdvisary[m_] := Which[
  m =!= Automatic, m,
  ValueQ[ClaudeCode`$ClaudeAdvisaryModel], ClaudeCode`$ClaudeAdvisaryModel,
  True, "chatgptcodex"];

iResolveClaude[m_] := Which[
  m =!= Automatic, m,
  ValueQ[ClaudeCode`$ClaudeModel], ClaudeCode`$ClaudeModel,
  True, ""];

(* output language for generated prose: the kernel's $Language (the driver
   inherits the FE kernel's $Language via the config). Used so the review text
   matches the spec language instead of being forced to English. *)
iLangName[] := If[StringQ[$Language] && $Language =!= "", $Language, "English"];

(* ---- binding / payload helpers ---- *)
iPayload[b_Association] := Lookup[First[Values[b]], "Payload", <||>];
iVerdict[b_Association] := Lookup[iPayload[b], "Verdict", ""];
iRound[b_Association]   := Lookup[iPayload[b], "Round", 1];
iMaxRounds[b_Association] := Lookup[iPayload[b], "MaxRounds", $DefaultMaxRounds];
(* G6: an empty drafter response (usage/rate limit, HTTP 529) routes straight to
   GiveUp -- it must NOT loop, and must NOT let an empty spec be Approved. *)
iDraftEmpty[b_Association] := TrueQ[Lookup[iPayload[b], "DraftEmpty", False]];

(* ---- vault contract (mirror of orch_vault.wls) ----
   作成者 LLM の記録: CreatedBy は role 名 (codex/claude)、GeneratedBy は
   実モデルラベル (iModelLabel。メール/NB 要約 sidecar・llmlog・spec-impl と
   同じ規約)。snapshot と OrchHandoff event の両方に載せる。 *)
iSaveSpec[project_, round_, text_, parentRef_, genBy_:""] := Module[{snap, ref},
  snap = SourceVaultSaveImmutableSnapshot["OrchSpec", <|
    "Project" -> project, "Round" -> round, "Role" -> "spec",
    "Text" -> text, "ParentReviewRef" -> parentRef,
    "CreatedBy" -> "codex", "GeneratedBy" -> genBy|>];
  ref = Lookup[snap, "Ref"];
  SourceVaultAtomicUpdatePointer["orch/" <> project <> "/spec", ref];
  SourceVaultAppendEvent[<|"EventClass" -> "OrchHandoff", "Project" -> project,
    "Round" -> round, "Role" -> "spec", "From" -> "codex", "To" -> "claude",
    "GeneratedBy" -> genBy, "Value" -> ref, "ParentReviewRef" -> parentRef|>];
  ref];

iSaveReview[project_, round_, verdict_, findings_, targetSpecRef_, text_, genBy_:""] := Module[{snap, ref},
  snap = SourceVaultSaveImmutableSnapshot["OrchReview", <|
    "Project" -> project, "Round" -> round, "Role" -> "review",
    "Verdict" -> verdict, "Findings" -> findings, "TargetSpecRef" -> targetSpecRef,
    "Text" -> text, "CreatedBy" -> "claude", "GeneratedBy" -> genBy|>];
  ref = Lookup[snap, "Ref"];
  SourceVaultAtomicUpdatePointer["orch/" <> project <> "/review", ref];
  SourceVaultAppendEvent[<|"EventClass" -> "OrchHandoff", "Project" -> project,
    "Round" -> round, "Role" -> "review", "From" -> "claude", "To" -> "codex",
    "Verdict" -> verdict, "GeneratedBy" -> genBy, "Value" -> ref,
    "TargetSpecRef" -> targetSpecRef|>];
  ref];

iRefToURI[ref_String] := Module[{p = StringSplit[ref, ":"]},
  If[Length[p] >= 3 && p[[1]] === "snapshot", "sv://snapshot/" <> p[[2]] <> "/" <> p[[3]], ref]];
iRefToURI[_] := "<no-ref>";

(* ---- progress emission (the FE poller reads this file and shows the running
   model + phase in the WindowStatusArea). Written atomically (temp + rename)
   so a concurrent FE Get does not see a torn file. ---- *)
iNowUTC[] := Quiet @ Check[
  DateString[Now, {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"},
    TimeZone -> 0], ""];
iModelLabel[model_] := Which[
  StringQ[model] && model =!= "", model,
  ListQ[model] && Length[model] >= 1 && StringQ[model[[1]]],
    model[[1]] <> If[Length[model] >= 2 && StringQ[model[[2]]] && model[[2]] =!= "" &&
      model[[2]] =!= "Automatic", ":" <> model[[2]], ""],
  True, "model"];
iEmitProgress[None, _] := Null;
iEmitProgress[file_String, assoc_Association] := Quiet @ Check[
  Module[{tmp = file <> ".tmp"},
    Put[Join[<|"UpdatedAtUTC" -> iNowUTC[]|>, assoc], tmp];
    Quiet @ If[FileExistsQ[file], DeleteFile[file]];
    RenameFile[tmp, file]], Null];
iEmitProgress[_, _] := Null;
iProg[progressFile_, payload_, phase_, role_, model_, msg_] := iEmitProgress[progressFile, <|
  "Phase" -> phase, "Role" -> role, "Model" -> iModelLabel[model],
  "Round" -> Lookup[payload, "Round", 1], "Verdict" -> Lookup[payload, "Verdict", ""],
  "Message" -> msg|>];

(* ============================================================
   Real executors (LIVE path: shells out to codex / claude).
   Each takes the resolved model for its role.
   ============================================================ *)

iCmdPrefix[] := If[$OperatingSystem === "Windows", {"cmd", "/c"}, {}];

(* extract a concrete model-name string from a string or {provider, model, ...} tuple *)
iModelName[model_] := Which[
  StringQ[model] && model =!= "", model,
  ListQ[model] && Length[model] >= 2 && StringQ[model[[2]]] && model[[2]] =!= "Automatic", model[[2]],
  True, ""];

iCodexModelArgs[model_] := Which[
  ListQ[model] && Length[model] >= 2 && StringQ[model[[2]]] && model[[2]] =!= "Automatic",
    {"-m", model[[2]]},
  True, {}];

(* ============================================================
   Provider-agnostic synchronous text query (role -> model).
   chatgptcodex -> codex CLI (codex has no ClaudeQuerySync branch);
   claudecode / anthropic / openai / lmstudio -> ClaudeCode`ClaudeQuerySync.
   ============================================================ *)

(* canonical provider token, or None if `s` is not a provider name *)
iCanonProvider[s_] := Module[{l = ToLowerCase[ToString[s]]},
  Which[
    MemberQ[{"chatgptcodex", "chatgpt-codex", "codex", "gptcodex"}, l], "chatgptcodex",
    MemberQ[{"claudecode", "claude"}, l], "claudecode",
    l === "anthropic", "anthropic",
    l === "openai", "openai",
    l === "lmstudio", "lmstudio",
    True, None]];

(* normalize a model value to a {provider, modelName, [url]} tuple *)
iModelTuple[m_] := Which[
  ListQ[m] && Length[m] >= 2 && StringQ[m[[1]]], m,
  StringQ[m] && m =!= "" && iCanonProvider[m] =!= None, {iCanonProvider[m], ""},
  StringQ[m] && m =!= "", {"claudecode", m},
  True, {"claudecode", ""}];

(* per-LLM-call wall-clock cap (s): a stuck "codex exec" can never block the
   driver indefinitely (mirror of spec-impl). *)
If[! ValueQ[$iOrchCallTimeLimit], $iOrchCallTimeLimit = 900];

(* codex text query: codex exec, final message captured via -o (UTF-8 file) *)
iOrchCodex[tup_, prompt_] := Module[{ws, answerFile, model, modelArgs, res, ans},
  ws = FileNameJoin[{$TemporaryDirectory, "orchq_codex_" <> StringReplace[CreateUUID[], "-" -> ""]}];
  Quiet @ CreateDirectory[ws, CreateIntermediateDirectories -> True];
  answerFile = FileNameJoin[{ws, "answer.txt"}];
  model = If[Length[tup] >= 2 && StringQ[tup[[2]]] && tup[[2]] =!= "" && tup[[2]] =!= "Automatic",
    tup[[2]], ""];
  modelArgs = If[model =!= "", {"-m", model}, {}];
  (* TimeConstrained bounds a stuck call; RunProcess has no usable timeout option
     here (ProcessTimeLimit is rejected). On timeout returns the marker "TimedOut". *)
  res = TimeConstrained[
    Quiet @ Check[
      RunProcess[Join[iCmdPrefix[],
          {"codex", "exec", "-C", ws, "-s", "workspace-write", "--skip-git-repo-check",
           "-c", "approval_policy=never"}, modelArgs, {"-o", answerFile, "-"}],
        All, StringToByteArray[prompt, "UTF-8"]],
      <|"ExitCode" -> "Error", "StandardOutput" -> ""|>],
    $iOrchCallTimeLimit, "TimedOut"];
  ans = Which[
    FileExistsQ[answerFile], iReadUTF8[answerFile],
    AssociationQ[res], Lookup[res, "StandardOutput", ""],
    True, ""];
  Quiet @ If[DirectoryQ[ws], DeleteDirectory[ws, DeleteContents -> True]];
  If[StringQ[ans] && StringTrim[ans] =!= "",
    ans,
    "[codex produced no output: timed out after " <> ToString[$iOrchCallTimeLimit] <>
      "s or the call failed]"]];

iOrchQuery[m_, prompt_] := Module[{tup = iModelTuple[m], prov, r},
  prov = ToLowerCase[tup[[1]]];
  If[prov === "chatgptcodex",
    iOrchCodex[tup, prompt],
    r = Quiet @ Check[
      Block[{ClaudeCode`$ClaudeModel = tup}, ClaudeCode`ClaudeQuerySync[prompt]], $Failed];
    If[StringQ[r], r, ""]]];

(* ---- compute-aware spec drafting: execution profile rules + machine table ----
   The known-machine table comes from SourceVault_simrun.wl's shared store
   (each PC runs SourceVaultMachineProfileRefresh[] once); fail-soft when absent. *)
iMachineSpecsText[] := Module[{r},
  r = Quiet @ Check[
    If[Length[Names["SourceVault`SourceVaultMachineSpecsText"]] > 0,
      SourceVault`SourceVaultMachineSpecsText[], $Failed], $Failed];
  If[StringQ[r] && r =!= "", r, "(machine spec table unavailable)"]];

iComputeProfileBlock[] :=
  "\n=== EXECUTION PROFILE RULES (compute-aware specs) ===\n" <>
  "Classify the workflow you are specifying into one of two execution classes:\n" <>
  "- \"simulation\": numerical simulation / Monte Carlo / parameter sweeps run repeatedly while " <>
  "tuning parameters, GPU (CUDA) jobs, media generation (video/image batches), or ANY run whose " <>
  "output artifacts can be large (more than a few MB, or many files).\n" <>
  "- \"standard\": specs, reviews, reports, notebooks, small datasets/plots -- everything else.\n" <>
  "IF the requirements mention ANY of: execution-speed priority, parallel execution / subkernels, " <>
  "CUDA / GPU, a specific machine name, numerical simulation, or large outputs, THEN the spec MUST " <>
  "contain a section titled exactly \"## Execution Profile\" with EXACTLY these fields:\n" <>
  "  - ExecutionClass: \"simulation\" | \"standard\"\n" <>
  "  - Parallelization: \"subkernels\" | \"none\"  (subkernels = launch ALL available subkernels " <>
  "for the run and CLOSE them when the run finishes, so the license seats return to standby; the " <>
  "implementation uses SourceVault`SourceVaultWithSubkernels)\n" <>
  "  - CUDA: \"required\" | \"none\"  (required = the run only works on machines with an Nvidia GPU; " <>
  "non-GPU machines must fail gracefully with a clear message, never crash)\n" <>
  "  - TargetMachine: a machine tag from the known-machine table below, or \"any\" (when CUDA is " <>
  "required, pick a machine that actually has an Nvidia GPU; honor an explicit machine name in the " <>
  "requirements, e.g. rapterlake4t)\n" <>
  "  - OutputMode: \"reference\" | \"inline\"  (reference = bulk outputs -- data files, images, " <>
  "videos, frames -- are written to a per-run folder under udb/simruns named " <>
  "<yyyymmddHHmm>-<machine>-<slug>, and SourceVault stores ONLY a metadata snapshot; the run " <>
  "returns the sv://snapshot/SimulationRun/... URI plus a SMALL summary. simulation-class " <>
  "workflows MUST use reference; standard workflows keep the existing inline behavior)\n" <>
  "  - Outputs: the list of artifact files the run writes into the run folder\n" <>
  "When ExecutionClass is \"simulation\", the spec must also name the tunable parameters (what the " <>
  "user will vary between trial runs) and their defaults, so every run is reproducible from its " <>
  "recorded Params. Requirements that only produce a small report need NO Execution Profile section.\n" <>
  "Known machines (shared, measured; memory/cores/GPU per PC):\n" <> iMachineSpecsText[] <> "\n";

iRealDraft[model_, payload_] := Module[{prompt, lastReview, text},
  lastReview = Lookup[payload, "LastReviewText", ""];
  prompt = Lookup[payload, "DraftPrompt", "Write a Wolfram Language design spec."] <>
    If[StringQ[lastReview] && lastReview =!= "",
      "\n\n=== Previous review (address every point; rewrite the FULL spec) ===\n" <> lastReview, ""] <>
    iComputeProfileBlock[] <>
    "\n\nOutput ONLY the design spec in Markdown as your reply. No preamble and no file writing.";
  text = iOrchQuery[model, prompt];
  <|"SpecText" -> If[StringQ[text], text, ""]|>];

iRealReview[model_, payload_, specText_] := Module[
  {prompt, out, json, verdict, findings, reviewText},
  prompt =
    "Review the following Wolfram Language design spec strictly and decide whether it is implementable.\n" <>
    "EXECUTION PROFILE CHECK: if the spec's requirements involve execution-speed priority, parallel " <>
    "execution / subkernels, CUDA / GPU, a specific machine, numerical simulation, or large outputs " <>
    "(big data files / images / video), the spec MUST contain an \"## Execution Profile\" section " <>
    "with fields ExecutionClass / Parallelization / CUDA / TargetMachine / OutputMode / Outputs, and " <>
    "it must be CONSISTENT: ExecutionClass \"simulation\" requires OutputMode \"reference\" (bulk " <>
    "artifacts go to a per-run udb/simruns folder; SourceVault keeps only a metadata snapshot and " <>
    "the run returns its sv:// URI with a small summary); CUDA \"required\" needs a TargetMachine " <>
    "that has an Nvidia GPU (see the machine table) and a graceful non-GPU failure path; " <>
    "Parallelization \"subkernels\" means all available subkernels are launched for the run and " <>
    "closed afterwards. A missing or inconsistent Execution Profile in such a spec is a blocker. " <>
    "Specs for ordinary small reports need no such section -- do not demand one.\n" <>
    "Known machines:\n" <> iMachineSpecsText[] <> "\n" <>
    "Respond with EXACTLY one JSON object inside a ```json block and nothing else.\n" <>
    "Write the \"reviewText\" value and every finding \"title\" in " <> iLangName[] <> ".\n" <>
    "Keep the JSON keys and the \"verdict\" / \"severity\" enum values in ASCII exactly as in the schema.\n" <>
    "Schema: {\"verdict\":\"Approved\"|\"NeedsRevision\",\"findings\":[{\"id\":\"..\",\"severity\":\"blocker\"|\"minor\",\"title\":\"..\"}],\"reviewText\":\"..\"}\n" <>
    "If there are zero blocker findings, verdict is Approved.\n\n=== SPEC ===\n" <> specText;
  (* reviewText/titles follow $Language; keys+enums stay ASCII so parsing and the
     verdict/severity checks below are unaffected. The JSON reader and writer both
     handle non-ASCII values, and SourceVault stores them as UTF-8. *)
  out = iOrchQuery[model, prompt];
  json = iExtractJSON[out];
  verdict = Lookup[json, "verdict", iScanVerdict[out]];
  findings = Quiet @ Check[Developer`WriteRawJSONString[Lookup[json, "findings", {}]], "[]"];
  reviewText = Lookup[json, "reviewText", out];
  <|"Verdict" -> If[verdict === "Approved", "Approved", "NeedsRevision"],
    "Findings" -> If[StringQ[findings], findings, "[]"], "ReviewText" -> reviewText|>];

(* derive a package name: explicit option > BeginPackage in spec > first H1 > project *)
iDerivePackageName[payload_, spec_] := Module[{explicit, bp, h1, w},
  explicit = Lookup[payload, "PackageName", Automatic];
  If[StringQ[explicit] && explicit =!= "", Return[explicit]];
  bp = StringCases[spec, "BeginPackage[\"" ~~ n : (Except["`"] ..) ~~ "`" :> n, 1];
  If[bp =!= {}, Return[First[bp]]];
  h1 = StringCases[spec, StartOfLine ~~ "# " ~~ t : (Except["\n"] ..) :> t, 1];
  If[h1 =!= {},
    w = StringCases[First[h1], LetterCharacter ~~ (WordCharacter ...), 1];
    If[w =!= {}, Return[First[w]]]];
  With[{j = StringJoin[StringCases[Lookup[payload, "Project", "Generated"], WordCharacter ..]]},
    If[j === "", "Generated", j]]];

iExtractCode[out_String] := Module[{m, body},
  m = StringCases[out, "```" ~~ Shortest[b__] ~~ "```" :> b, 1];
  body = If[m =!= {}, First[m], out];
  body = StringReplace[body, StartOfString ~~ ("wl" | "mathematica" | "wolfram") ~~ "\n" -> ""];
  StringTrim[body]];
iExtractCode[_] := "";

(* LIVE codegen: headless claude implements the approved spec as a loadable
   ASCII .wl package written into $packageDirectory (the package root). *)
iRealCodegen[model_, payload_] := Module[
  {spec, pkgName, targetFile, prompt, out, code},
  spec = Lookup[payload, "SpecText", ""];
  If[! (StringQ[spec] && StringLength[spec] > 0),
    Return[<|"Path" -> Missing["NoSpec"]|>]];
  pkgName = iDerivePackageName[payload, spec];
  targetFile = FileNameJoin[{$pkgRoot, pkgName <> ".wl"}];
  If[FileExistsQ[targetFile],
    targetFile = FileNameJoin[{$pkgRoot, pkgName <> "_generated.wl"}]];
  prompt =
    "Implement the following approved Wolfram Language design spec as a complete, loadable .wl package.\n" <>
    "Output ONLY the .wl file content inside a single ```wl code block, with nothing before or after it.\n" <>
    "Use ASCII characters only (English comments and usage strings; if a non-ASCII glyph is unavoidable, write it as \\:XXXX).\n" <>
    "Structure: BeginPackage[\"" <> pkgName <> "`\"]; public ::usage messages; Begin[\"`Private`\"]; implementation; End[]; EndPackage[].\n" <>
    "Do not Clear or Remove the Global` context. Implement the spec exactly, including edge cases.\n\n=== SPEC ===\n" <> spec;
  out = iOrchQuery[model, prompt];
  code = iExtractCode[out];
  If[StringQ[code] && StringLength[code] > 20,
    iWriteUTF8[targetFile, code];
    <|"Path" -> targetFile, "PackageName" -> pkgName, "Bytes" -> StringLength[code]|>,
    <|"Path" -> Missing["CodegenEmpty"], "PackageName" -> pkgName|>]];

(* ---- small IO / JSON helpers (message-quiet) ---- *)
iWriteUTF8[p_, s_] := Module[{strm = OpenWrite[p, BinaryFormat -> True]},
  BinaryWrite[strm, StringToByteArray[s, "UTF-8"]]; Close[strm]];
iReadUTF8[p_] := Quiet @ Check[ByteArrayToString[ReadByteArray[p], "UTF-8"], ""];

(* parse a JSON string via the UTF-8 byte-array path (rules/30: non-ASCII values
   break Developer`ReadRawJSONString / ImportString["RawJSON"]); fall back to
   ReadRawJSONString. Returns the value or $Failed. *)
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
  With[{bo = iBalancedObject[body]},
    If[StringQ[bo], r = iReadJSON[bo]; If[AssociationQ[r] || ListQ[r], Return[r]]]];
  With[{bo = iBalancedObject[out]},
    If[StringQ[bo], r = iReadJSON[bo]; If[AssociationQ[r] || ListQ[r], Return[r]]]];
  <||>];
iExtractJSON[_] := <||>;

(* verdict-of-last-resort if JSON parsing fails entirely (so a single malformed
   character cannot silently force NeedsRevision and block convergence). *)
iScanVerdict[text_String] := Which[
  StringContainsQ[text, RegularExpression["\"verdict\"\\s*:\\s*\"Approved\""]], "Approved",
  StringContainsQ[text, "NeedsRevision"], "NeedsRevision",
  StringContainsQ[text, "Approved"], "Approved",
  True, "NeedsRevision"];
iScanVerdict[_] := "NeedsRevision";

(* ============================================================
   Handler factories (close over the role's resolved model + fn)
   Each returns <|"Payload" -> newState|> and is message-quiet.
   ============================================================ *)

iDraftHandler[model_, draftFn_, progressFile_:None] := Function[binding,
  Quiet @ Module[{pl, res, text, ref, emptyDraft},
    pl = iPayload[binding];
    iProg[progressFile, pl, "Draft", "codex", model,
      "drafting spec (round " <> ToString[Lookup[pl, "Round", 1]] <> ")"];
    res = draftFn[model, pl];
    text = Lookup[res, "SpecText", ""];
    (* G6 empty-response guard: a blank / "produced no output" draft is almost
       always a transient provider failure (usage/rate limit, HTTP 529), not a
       fixable content issue -> flag it so the net routes to GiveUp (see guards). *)
    emptyDraft = ! StringQ[text] || StringTrim[text] === "" ||
      StringStartsQ[StringTrim[text], "[codex produced no output"];
    If[emptyDraft,
      iProg[progressFile, pl, "Draft", "codex", model,
        "EMPTY draft response (likely usage limit / overload) -- giving up"]];
    ref = iSaveSpec[Lookup[pl, "Project", "proj"], Lookup[pl, "Round", 1], text,
      Lookup[pl, "LastReviewRef", "none"], iModelLabel[model]];
    <|"Payload" -> Join[pl, <|"SpecRef" -> ref, "SpecURI" -> iRefToURI[ref],
        "SpecText" -> text, "DraftModel" -> model, "DraftEmpty" -> emptyDraft,
        "GiveUpReason" -> If[emptyDraft,
          "drafter returned an empty response (likely a usage/rate limit or HTTP 529 overload) -- re-run later", ""]|>]|>]];

iReviewHandler[model_, reviewFn_, progressFile_:None] := Function[binding,
  Quiet @ Module[{pl, res, verdict, findings, rtext, ref},
    pl = iPayload[binding];
    If[iDraftEmpty[binding],
      (* G6: empty draft -> do not spend a review call; force NeedsRevision so the
         net's GiveUp guard (which includes DraftEmpty) fires. *)
      iProg[progressFile, pl, "Review", "claude", model, "skipped (empty draft)"];
      verdict = "NeedsRevision"; findings = "[]";
      rtext = "skipped: empty draft (likely usage limit / overload)",
      (* normal review *)
      iProg[progressFile, pl, "Review", "claude", model,
        "reviewing spec (round " <> ToString[Lookup[pl, "Round", 1]] <> ")"];
      res = reviewFn[model, pl, Lookup[pl, "SpecText", ""]];
      verdict = Lookup[res, "Verdict", "NeedsRevision"];
      findings = Lookup[res, "Findings", "[]"];
      rtext = Lookup[res, "ReviewText", ""]];
    ref = iSaveReview[Lookup[pl, "Project", "proj"], Lookup[pl, "Round", 1],
      verdict, findings, Lookup[pl, "SpecRef", "none"], rtext,
      iModelLabel[model]];
    <|"Payload" -> Join[pl, <|"Verdict" -> verdict, "ReviewRef" -> ref,
        "ReviewURI" -> iRefToURI[ref], "LastReviewRef" -> ref,
        "LastReviewText" -> rtext, "ReviewModel" -> model|>]|>]];

iApproveHandler[model_, codegenFn_, progressFile_:None] := Function[binding,
  Quiet @ Module[{pl, res},
    pl = iPayload[binding];
    iProg[progressFile, pl, "Approved", "claude", model, "spec approved"];
    res = If[codegenFn === None, <|"Path" -> Missing["NoCodegen"]|>, codegenFn[model, pl]];
    <|"Payload" -> Join[pl, <|"Status" -> "Approved",
        "GeneratedPath" -> Lookup[res, "Path", Missing[]], "CodegenModel" -> model|>]|>]];

iReviseHandler[progressFile_:None] := Function[binding,
  Module[{pl}, pl = iPayload[binding];
    iProg[progressFile, pl, "Revise", "codex", "", "revising after review"];
    <|"Payload" -> Join[pl, <|"Round" -> Lookup[pl, "Round", 1] + 1, "Verdict" -> "Pending"|>]|>]];

iGiveUpHandler[progressFile_:None] := Function[binding,
  Module[{pl, reason}, pl = iPayload[binding];
    reason = Lookup[pl, "GiveUpReason", ""];
    iProg[progressFile, pl, "Failed", "", "",
      If[StringQ[reason] && reason =!= "", reason, "gave up after max rounds"]];
    <|"Payload" -> Join[pl, <|"Status" -> "GaveUp",
        "FinalStatus" -> "GaveUp", "GiveUpReason" -> reason|>]|>]];

(* ============================================================
   Net builder
   ============================================================ *)

Options[BuildNet] = {
  "MaxRounds" -> Automatic,
  "AdvisaryModel" -> Automatic,
  "ClaudeModel" -> Automatic,
  "DraftFunction" -> Automatic,
  "ReviewFunction" -> Automatic,
  "CodegenFunction" -> None,
  "ProgressFile" -> None};

BuildNet[project_String, opts:OptionsPattern[]] := Module[
  {advisary, claude, draftFn, reviewFn, codegenFn, progressFile, spec, wid},
  advisary = iResolveAdvisary[OptionValue["AdvisaryModel"]];
  claude   = iResolveClaude[OptionValue["ClaudeModel"]];
  draftFn  = OptionValue["DraftFunction"] /. Automatic -> iRealDraft;
  reviewFn = OptionValue["ReviewFunction"] /. Automatic -> iRealReview;
  codegenFn = OptionValue["CodegenFunction"] /. Automatic -> iRealCodegen;
  progressFile = OptionValue["ProgressFile"];

  spec = <|
    "SourcePlace" -> "NeedDraft",
    "FinalPlaces" -> {"Approved", "Failed"},
    "Description" -> "Codex<->Claude spec review loop for " <> project,
    "Places" -> <|
      "NeedDraft" -> WorkflowPlace["NeedDraft"],
      "Drafted"   -> WorkflowPlace["Drafted"],
      "Reviewed"  -> WorkflowPlace["Reviewed"],
      "Approved"  -> WorkflowPlace["Approved"],
      "Failed"    -> WorkflowPlace["Failed"]|>,
    "Transitions" -> <|
      "Draft" -> WorkflowTransition["Draft",
        "InputArcs" -> {<|"Place" -> "NeedDraft"|>},
        "OutputArcs" -> {<|"Place" -> "Drafted", "TokenKind" -> "Artifact"|>},
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iDraftHandler[advisary, draftFn, progressFile]|>],
      "Review" -> WorkflowTransition["Review",
        "InputArcs" -> {<|"Place" -> "Drafted"|>},
        "OutputArcs" -> {<|"Place" -> "Reviewed", "TokenKind" -> "Artifact"|>},
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iReviewHandler[claude, reviewFn, progressFile]|>],
      "Approve" -> WorkflowTransition["Approve",
        "InputArcs" -> {<|"Place" -> "Reviewed"|>},
        "OutputArcs" -> {<|"Place" -> "Approved", "TokenKind" -> "Artifact"|>},
        "Guard" -> Function[b, iVerdict[b] === "Approved" && ! iDraftEmpty[b]],
        "Priority" -> 10,
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iApproveHandler[claude, codegenFn, progressFile]|>],
      "Revise" -> WorkflowTransition["Revise",
        "InputArcs" -> {<|"Place" -> "Reviewed"|>},
        "OutputArcs" -> {<|"Place" -> "NeedDraft", "TokenKind" -> "Artifact"|>},
        "Guard" -> Function[b, iVerdict[b] === "NeedsRevision" && iRound[b] < iMaxRounds[b] && ! iDraftEmpty[b]],
        "Priority" -> 5,
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iReviseHandler[progressFile]|>],
      "GiveUp" -> WorkflowTransition["GiveUp",
        "InputArcs" -> {<|"Place" -> "Reviewed"|>},
        "OutputArcs" -> {<|"Place" -> "Failed", "TokenKind" -> "Artifact"|>},
        "Guard" -> Function[b, iDraftEmpty[b] || (iVerdict[b] === "NeedsRevision" && iRound[b] >= iMaxRounds[b])],
        "Priority" -> 1,
        "Executor" -> "PureFunction",
        "RuntimeSpec" -> <|"Handler" -> iGiveUpHandler[progressFile]|>]|>|>;

  wid = ClaudeCreateWorkflowNet[spec];
  wid];

(* ============================================================
   Runner
   ============================================================ *)

Options[RunSpecReview] = Join[Options[BuildNet],
  {"PromptFile" -> None, "DraftPrompt" -> Automatic, "InitialState" -> <||>,
   "PackageName" -> Automatic,
   "MaxSteps" -> 200, "MaxWait" -> Quantity[1800, "Seconds"]}];

RunSpecReview[project_String, opts:OptionsPattern[]] := Module[
  {maxRounds, draftPrompt, wid, initPayload, tok, run, st, finalTok, finalPayload,
   specChain, reviewChain},
  maxRounds = OptionValue["MaxRounds"] /. Automatic -> $DefaultMaxRounds;
  draftPrompt = OptionValue["DraftPrompt"] /. Automatic -> (
    With[{pf = OptionValue["PromptFile"]},
      If[StringQ[pf] && FileExistsQ[pf], iReadUTF8[pf],
        "Write a small self-contained Wolfram Language design spec."]]);

  wid = BuildNet[project,
    FilterRules[{opts}, Options[BuildNet]]];

  initPayload = Join[<|
    "Project" -> project, "Round" -> 1, "MaxRounds" -> maxRounds,
    "Verdict" -> "Pending", "LastReviewText" -> "", "LastReviewRef" -> "none",
    "PackageName" -> OptionValue["PackageName"],
    "DraftPrompt" -> draftPrompt|>, OptionValue["InitialState"]];

  tok = WorkflowToken["Kind" -> "Artifact", "Payload" -> initPayload];
  ClaudeSubmitToken[wid, tok];

  run = ClaudeRunWorkflow[wid, "MaxSteps" -> OptionValue["MaxSteps"],
    "MaxWait" -> OptionValue["MaxWait"]];

  st = ClaudeWorkflowState[wid];
  finalTok = iFinalToken[st];
  finalPayload = If[AssociationQ[finalTok], Lookup[finalTok, "Payload", <||>], <||>];
  specChain = SourceVaultPointerHistory["orch/" <> project <> "/spec"];
  reviewChain = SourceVaultPointerHistory["orch/" <> project <> "/review"];

  <|"WorkflowId" -> wid,
    "RunStatus" -> Lookup[run, "Status", run],
    "Termination" -> Lookup[run, "TerminationReason", "-"],
    "FinalStatus" -> Lookup[finalPayload, "Status",
      If[KeyExistsQ[markingPlaces[st], "Approved"] &&
         Length[markingPlaces[st]["Approved"]] > 0, "Approved", "Unknown"]],
    "Rounds" -> Lookup[finalPayload, "Round", Missing[]],
    "FinalVerdict" -> Lookup[finalPayload, "Verdict", Missing[]],
    "DraftModel" -> Lookup[finalPayload, "DraftModel", Missing[]],
    "ReviewModel" -> Lookup[finalPayload, "ReviewModel", Missing[]],
    "ApprovedSpecURI" -> Lookup[finalPayload, "SpecURI", Missing[]],
    "ApprovedReviewURI" -> Lookup[finalPayload, "ReviewURI", Missing[]],
    "GeneratedPath" -> Lookup[finalPayload, "GeneratedPath", Missing[]],
    "SpecChain" -> (iRefToURI[Lookup[#, "Value", ""]] & /@ specChain),
    "ReviewChain" -> (iRefToURI[Lookup[#, "Value", ""]] & /@ reviewChain),
    "FinalPayload" -> finalPayload|>];

markingPlaces[st_] := Lookup[st, "Marking", <||>];

iFinalToken[st_] := Module[{mk, tokens, ids},
  mk = Lookup[st, "Marking", <||>];
  tokens = Lookup[st, "Tokens", <||>];
  ids = Join[Lookup[mk, "Approved", {}], Lookup[mk, "Failed", {}]];
  If[ids === {}, Missing["NoFinalToken"], Lookup[tokens, First[ids], Missing[]]]];

End[]
EndPackage[]
