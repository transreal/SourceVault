(* ::Package:: *)

(* ============================================================
   SourceVault_promptrouter.wl

   SourceVault PromptRouter extension - Phase A skeleton.

   Implements the unified spec
     "SourceVault Prompt Router / Prompt Capture / Workflow Promotion"
     Version v9.
   This file covers Phase A only (spec section 18, Order 0/1 boundary):

     - file added, loadable as a SourceVault` context extension
     - status API
     - ClaudeRuntime / ClaudeOrchestrator availability detection
     - no-op / dry-run SourceVaultResolvePromptRoute
     - SourceVaultExecutePromptRoute returns NotDispatched so that
       the ClaudeEval weak-call path (wired later in Phase A1)
       falls back to the legacy route.

   Design constraints honoured here (see spec sections 3, 4, 5, 19):

     - This is NOT an independent package. It is an extension of the
       SourceVault` context. It is loaded via Get[] by the SourceVault.wl
       bootstrap (spec 3.2).
     - It does NOT call Needs["ClaudeRuntime`"] or
       Needs["ClaudeOrchestrator`"]. Availability is detected at
       runtime from public symbol names only (rule 11).
     - It loads successfully even when ClaudeRuntime / ClaudeOrchestrator
       are absent.
     - Loading is idempotent: a repeated Get[] re-defines cleanly.

   Source is intentionally all-ASCII to avoid the \:XXXX literal trap
   (rule 30 / trap #11). Japanese usage text is deferred to later
   phases and will be added via the bulk \u -> \: conversion.
   ============================================================ *)

BeginPackage["SourceVault`"];

(* ------------------------------------------------------------
   Idempotent guard: clear the public symbols this extension owns
   so that a repeated Get[] does not accumulate stale definitions.
   ------------------------------------------------------------ *)

Quiet[ClearAll[
  "SourceVault`$SourceVaultPromptRouterVersion",
  "SourceVault`SourceVaultPromptRouterStatus",
  "SourceVault`SourceVaultPromptRouterAvailableQ",
  "SourceVault`SourceVaultPromptRouterActiveQ",
  "SourceVault`SourceVaultResolvePromptRoute",
  "SourceVault`SourceVaultExecutePromptRoute",
  "SourceVault`SourceVaultRouteExplain",
  "SourceVault`SourceVaultPromptRunRecord",
  "SourceVault`SourceVaultPromptRunHistory",
  "SourceVault`SourceVaultCallableAllowlistRegistry",
  "SourceVault`SourceVaultCallableAllowlistView",
  "SourceVault`SourceVaultRegisterPromptRoute",
  "SourceVault`SourceVaultListPromptRoutes",
  "SourceVault`SourceVaultGetPromptRoute",
  "SourceVault`SourceVaultCaptureLastPromptRun",
  "SourceVault`SourceVaultPromotePromptRun",
  "SourceVault`SourceVaultResolvePromptPrivacy",
  "SourceVault`SourceVaultPromptPrivacyAllowsCloudRouter",
  "SourceVault`SourceVaultResolveModelForPromptRouter",
  "SourceVault`SourceVaultPromptReprocessPlan",
  "SourceVault`SourceVaultProposePromptRoute"
]];

(* ------------------------------------------------------------
   Public usage messages (Phase A scope).
   ------------------------------------------------------------ *)

$SourceVaultPromptRouterVersion::usage =
  "$SourceVaultPromptRouterVersion is the version string of the " <>
  "SourceVault PromptRouter extension.";

SourceVaultPromptRouterStatus::usage =
  "SourceVaultPromptRouterStatus[] returns an Association describing " <>
  "the PromptRouter extension: its version, implementation phase, " <>
  "the availability of claudecode / SourceVault / ClaudeRuntime / " <>
  "ClaudeOrchestrator, and whether automatic ClaudeEval dispatch is " <>
  "currently active.";

SourceVaultPromptRouterAvailableQ::usage =
  "SourceVaultPromptRouterAvailableQ[] returns True when the " <>
  "PromptRouter extension itself has loaded into the SourceVault` " <>
  "context. It does not imply that ClaudeRuntime or ClaudeOrchestrator " <>
  "are present.";

SourceVaultPromptRouterActiveQ::usage =
  "SourceVaultPromptRouterActiveQ[caller] returns True when the " <>
  "PromptRouter should handle a request from the given caller.\n" <>
  "caller: \"Manual\" | \"ClaudeEval\" | Automatic (default Automatic, " <>
  "treated as \"ClaudeEval\" so the claudecode weak call is safe).\n" <>
  "Manual API is active whenever the extension is loaded. Automatic " <>
  "ClaudeEval dispatch is active only when ClaudeOrchestrator is also " <>
  "loaded (spec section 4).";

SourceVaultResolvePromptRoute::usage =
  "SourceVaultResolvePromptRoute[prompt, opts] resolves a prompt to a " <>
  "route decision Association without executing it.\n" <>
  "Phase A: this is a no-op / dry-run skeleton. It always returns a " <>
  "decision with Status -> \"NotFound\" and Decision -> \"NotImplemented\". " <>
  "Deterministic and LLM-backed resolution are implemented in Phase B " <>
  "and later.\n" <>
  "Options: \"DryRun\" -> False, \"AllowLLMRouter\" -> Automatic, " <>
  "\"AllowWorkflow\" -> Automatic, \"PrivacyLevel\" -> Automatic, " <>
  "\"StorePrompt\" -> \"HashOnly\", \"FallbackToClaudeEval\" -> True, " <>
  "\"Caller\" -> Automatic.";

SourceVaultExecutePromptRoute::usage =
  "SourceVaultExecutePromptRoute[prompt, opts] resolves and executes a " <>
  "prompt route.\n" <>
  "Phase A: this is a skeleton. It always returns " <>
  "<|\"Status\" -> \"NotDispatched\", ...|> so that the ClaudeEval " <>
  "weak-call path falls back to the existing ClaudeEval route.\n" <>
  "Options: same as SourceVaultResolvePromptRoute.";

SourceVaultRouteExplain::usage =
  "SourceVaultRouteExplain[prompt, opts] returns a human-readable " <>
  "explanation of how a prompt would be routed.\n" <>
  "Phase A: skeleton. It reports that route resolution is not yet " <>
  "implemented and echoes the current router status.";

SourceVaultPromptRunRecord::usage =
  "SourceVaultPromptRunRecord[prompt, routeDecision, result, opts] " <>
  "appends a PromptRun record to the append-only JSONL store at " <>
  "<PrivateVault>/promptrouter/runs/prompt-runs.jsonl.\n" <>
  "A PromptRun is execution history, not a registry entry: it is " <>
  "stored like claims.jsonl / source-events.jsonl and is never " <>
  "written to the compiled registry (spec sections 9.0, 24.1).\n" <>
  "Raw prompt text is not stored by default; only a hash is kept.\n" <>
  "Options: \"StorePrompt\" -> \"HashOnly\" (also \"PrivateRaw\" | " <>
  "\"Off\"), \"PrivacyLevel\" -> 0.0, \"PrivacyOrigin\" -> {}, " <>
  "\"AllowedTrustDomains\" -> Automatic, \"CloudFallback\" -> \"Ask\", " <>
  "\"Dependencies\" -> <||>, \"ModelResolution\" -> <||>, " <>
  "\"DryRun\" -> False.\n" <>
  "Returns <|\"Status\" -> \"OK\" | \"DryRun\" | \"Skipped\" | " <>
  "\"Failed\", \"RunId\" -> ..., \"Record\" -> ...|>.";

SourceVaultPromptRunHistory::usage =
  "SourceVaultPromptRunHistory[opts] returns a list of PromptRun " <>
  "records from the append-only store, newest first.\n" <>
  "Options: \"MaxResults\" -> Automatic, \"RouteId\" -> Automatic, " <>
  "\"Decision\" -> Automatic, \"Since\" -> Automatic (an ISO date-time " <>
  "string; records with Timestamp >= Since are kept).";

SourceVaultCallableAllowlistRegistry::usage =
  "SourceVaultCallableAllowlistRegistry[] returns the SourceVault-owned callable allowlist: an Association keyed by FunctionId, holding the raw Symbol, UseAsFunctionRoute / UseAsHandlerRef flags, and SideEffectClass. Only callables that exist in SourceVault.wl are registered (spec 7.3 / 25); SourceVaultReviewQueue / SourceVaultOpenTodoList are handled as semantic IntentIds instead.";

SourceVaultCallableAllowlistView::usage =
  "SourceVaultCallableAllowlistView[] returns the merged logical view of the SourceVault-owned allowlist and, when ClaudeOrchestrator is loaded, the Orchestrator-owned handler allowlist (queried by weak call). FunctionRoute dispatch and HandlerRef resolution consult this view. SourceVault-owned entries take precedence on key conflict.";

SourceVaultRegisterPromptRoute::usage =
  "SourceVaultRegisterPromptRoute[route_Association, opts] adds or replaces a PromptRoute in the compiled prompt-route-registry. DryRun -> True (the default, rule 103) reports the planned topic, RouteId and action without writing; DryRun -> False performs an atomic write (encode, verify, tmp, rename). Returns WrittenCount / SkippedCount / ByAction / Topic / Channel / Path aggregates.";

SourceVaultListPromptRoutes::usage =
  "SourceVaultListPromptRoutes[opts] returns the PromptRoutes for a channel. With IncludeSeed -> True (default) the built-in seed routes are appended for any RouteId not already in the registry.";

SourceVaultGetPromptRoute::usage =
  "SourceVaultGetPromptRoute[routeId_String, opts] returns the PromptRoute with the given RouteId, or an Association with Status NotFound.";

SourceVaultCaptureLastPromptRun::usage =
  "SourceVaultCaptureLastPromptRun[opts] returns the most recent PromptRun from the append-only history as <|Status -> \"OK\", PromptRun -> ...|>, or Status NoPromptRun when the history is empty.";

SourceVaultPromotePromptRun::usage =
  "SourceVaultPromotePromptRun[runId_String, opts] classifies a recorded PromptRun (spec 10.3) and, for a deterministic route hit, strengthens that route's Matcher with the run's fingerprint and raw example. DryRun -> True (default, rule 103) reports the plan; workflow traces and LLM-only runs are classified but not auto-promoted.";

SourceVaultResolvePromptPrivacy::usage =
  "SourceVaultResolvePromptPrivacy[components_Association, opts] combines the privacy contributions of a prompt into a single PrivacyLevel (the Max of every component, spec 11.2) plus AllowedTrustDomains / CloudFallback / CloudRouterAllowed metadata. A SecretCell or PrivateModelExecution component raises the level to at least 0.75 (spec 11.3 / 11.4).";

SourceVaultPromptPrivacyAllowsCloudRouter::usage =
  "SourceVaultPromptPrivacyAllowsCloudRouter[level] (or a privacy-resolution Association) returns True only when the PrivacyLevel is below the 0.5 cloud-send boundary (spec 11.5). Non-numeric input is treated as unsafe and returns False.";

SourceVaultResolveModelForPromptRouter::usage =
  "SourceVaultResolveModelForPromptRouter[query_Association, opts] is the model-resolver contract layer (spec 12). It normalises the query to the full ModelIntent / WeightClass / PrivacyLevel / AllowedTrustDomains / CloudFallback / RequiredCapabilities / DegradationPolicy contract and weak-calls the host resolver. When no resolver exists or its result is unclassifiable it returns NeedsModelClassification; at PrivacyLevel >= 0.5 an unconfirmed (non Local/Private) model yields NeedsPrivateModel rather than a cloud fallback.";

SourceVaultPromptReprocessPlan::usage =
  "SourceVaultPromptReprocessPlan[opts] scans the PromptRoute registry for stale routes (schema / registry version mismatch, or RouteIds named in the StaleRouteIds option) and returns a read-only reprocessing plan (spec 14.2 / 14.3). Each stale route is classified by policy: a ReadOnly FunctionRoute is AutoRecomputable, an Intent route is OnDemandRefresh, and a WorkflowRoute is NeedsApproval. It builds the plan only -- it never reprocesses anything.";

SourceVaultProposePromptRoute::usage =
  "SourceVaultProposePromptRoute[prompt_String, opts] is the ClaudeEval-facing PromptRouter API (spec v11 5.3). It resolves a schedule prompt to an UNEVALUATED proposal expression -- HoldComplete[SourceVaultUpcomingSchedule[..., \"FilterSpec\" -> <|...|>]] -- and returns a PromptRouteProposal Association carrying it under \"ProposedExpression\". It never evaluates the expression; the ClaudeEval bridge passes only that field to the Runtime for head-based validation. A non-schedule prompt yields Status NotDispatched.";


Begin["`Private`"];

(* ------------------------------------------------------------
   Version / phase constants.
   ------------------------------------------------------------ *)

$SourceVaultPromptRouterVersion = "2.0.0-proposeContract (2026-05-25)";

iSVPRImplementationPhase[] := "ProposeContract-spec-v11";

(* ------------------------------------------------------------
   Availability detection.

   Detection uses public symbol names only. Names[...] returns an
   empty list when the context does not exist, so these checks are
   safe even when the package is absent. No Private symbols and no
   Needs[...] are used here (rule 11).
   ------------------------------------------------------------ *)

iSVPRSymbolPresentQ[fullName_String] :=
  TrueQ[Quiet @ Check[Length[Names[fullName]] > 0, False]];

iSVPRClaudeCodeAvailableQ[] :=
  iSVPRSymbolPresentQ["ClaudeCode`ClaudeEval"];

iSVPRSourceVaultAvailableQ[] :=
  iSVPRSymbolPresentQ["SourceVault`SourceVaultStatus"];

iSVPRRuntimeAvailableQ[] :=
  iSVPRSymbolPresentQ["ClaudeRuntime`ClaudeRunTurn"] ||
  iSVPRSymbolPresentQ["ClaudeRuntime`ClaudeRuntimeExecuteTransition"];

iSVPROrchestratorAvailableQ[] :=
  iSVPRSymbolPresentQ[
    "ClaudeOrchestrator`Workflow`ClaudeCreateWorkflowNet"];

(* Snapshot of the four availability flags as one Association. *)
iSVPRAvailabilitySnapshot[] :=
  <|
    "ClaudeCode"        -> iSVPRClaudeCodeAvailableQ[],
    "SourceVault"       -> iSVPRSourceVaultAvailableQ[],
    "ClaudeRuntime"     -> iSVPRRuntimeAvailableQ[],
    "ClaudeOrchestrator"-> iSVPROrchestratorAvailableQ[]
  |>;

(* ------------------------------------------------------------
   SourceVaultPromptRouterAvailableQ

   True once this extension has loaded. We assert it by the presence
   of our own version symbol with a String value.
   ------------------------------------------------------------ *)

SourceVaultPromptRouterAvailableQ[] :=
  StringQ[$SourceVaultPromptRouterVersion];

(* ------------------------------------------------------------
   SourceVaultPromptRouterActiveQ[caller]

   Phase A semantics (no flags yet; flags are introduced in
   Phase A1 together with the claudecode changes):

     caller = "Manual"
       -> active whenever the extension is loaded. Manual API such as
          SourceVaultResolvePromptRoute[..., "DryRun" -> True] works
          without ClaudeOrchestrator (spec section 4).

     caller = "ClaudeEval" or Automatic
       -> active only when ClaudeOrchestrator is also loaded. This is
          the spec section 4 default: automatic ClaudeEval dispatch
          becomes effective only at the full-stack load state.

   Automatic is treated as "ClaudeEval" because the claudecode weak
   call (spec 5.2) passes through here, and the conservative choice
   keeps single-package claudecode usage unchanged.
   ------------------------------------------------------------ *)

SourceVaultPromptRouterActiveQ[caller_:Automatic] :=
  Module[{c},
    If[!SourceVaultPromptRouterAvailableQ[], Return[False]];
    c = Which[
      caller === Automatic,            "ClaudeEval",
      StringQ[caller],                 caller,
      True,                            "ClaudeEval"];
    Switch[c,
      "Manual",
        True,
      "ClaudeEval",
        TrueQ[iSVPROrchestratorAvailableQ[]],
      _,
        TrueQ[iSVPROrchestratorAvailableQ[]]
    ]
  ];

SourceVaultPromptRouterActiveQ[___] := False;

(* ------------------------------------------------------------
   SourceVaultPromptRouterStatus[]
   ------------------------------------------------------------ *)

SourceVaultPromptRouterStatus[] :=
  Module[{avail},
    avail = iSVPRAvailabilitySnapshot[];
    <|
      "Type"             -> "SourceVaultPromptRouterStatus",
      "Version"          -> $SourceVaultPromptRouterVersion,
      "Phase"            -> iSVPRImplementationPhase[],
      "Available"        -> SourceVaultPromptRouterAvailableQ[],
      "Availability"     -> avail,
      "ActiveForManual"  -> SourceVaultPromptRouterActiveQ["Manual"],
      "ActiveForClaudeEval"
                         -> SourceVaultPromptRouterActiveQ["ClaudeEval"],
      "Notes"            ->
        "Order 1: PromptRun append-only JSONL store is implemented " <>
        "(SourceVaultPromptRunRecord / SourceVaultPromptRunHistory). " <>
        "Route resolution and execution are still skeletons: " <>
        "SourceVaultResolvePromptRoute always returns NotFound; " <>
        "SourceVaultExecutePromptRoute always returns NotDispatched."
    |>
  ];

SourceVaultPromptRouterStatus[___] :=
  <|"Type" -> "SourceVaultPromptRouterStatus",
    "Status" -> "Failed",
    "Reason" -> "SourceVaultPromptRouterStatus takes no arguments."|>;

(* ------------------------------------------------------------
   Option definitions for the resolve / execute / explain API.

   These option names are fixed by spec section 16.2. Phase A accepts
   them for forward compatibility but only reads "DryRun" and
   "Caller"; the rest are recorded verbatim in the decision so that
   later phases and tests can observe what was requested.
   ------------------------------------------------------------ *)

Options[SourceVaultResolvePromptRoute] = {
  "DryRun"              -> False,
  "AllowLLMRouter"      -> Automatic,
  "AllowWorkflow"       -> Automatic,
  "PrivacyLevel"        -> Automatic,
  "StorePrompt"         -> "HashOnly",
  "FallbackToClaudeEval"-> True,
  "Caller"              -> Automatic
};

Options[SourceVaultExecutePromptRoute] =
  Options[SourceVaultResolvePromptRoute];

Options[SourceVaultRouteExplain] =
  Options[SourceVaultResolvePromptRoute];

(* Collect the recognised options into an Association for echoing.
   Each OptionValue call passes the option name as a string literal
   so that the HoldRest attribute of OptionValue cannot interfere. *)
iSVPRCollectOptions[head_, optsList_List] :=
  <|
    "DryRun" ->
      OptionValue[head, optsList, "DryRun"],
    "AllowLLMRouter" ->
      OptionValue[head, optsList, "AllowLLMRouter"],
    "AllowWorkflow" ->
      OptionValue[head, optsList, "AllowWorkflow"],
    "PrivacyLevel" ->
      OptionValue[head, optsList, "PrivacyLevel"],
    "StorePrompt" ->
      OptionValue[head, optsList, "StorePrompt"],
    "FallbackToClaudeEval" ->
      OptionValue[head, optsList, "FallbackToClaudeEval"],
    "Caller" ->
      OptionValue[head, optsList, "Caller"]
  |>;

(* ------------------------------------------------------------
   SourceVaultResolvePromptRoute[prompt, opts]

   Phase A: no-op / dry-run skeleton. Always returns a well-formed
   decision Association with Status -> "NotFound" and
   Decision -> "NotImplemented". The shape is intentionally close to
   the final schema so that Phase B can fill it in without changing
   callers or tests.
   ------------------------------------------------------------ *)

SourceVaultResolvePromptRoute[prompt_String,
                              opts:OptionsPattern[]] :=
  Module[{recognised, routes, params, matched, route, target,
          lex, top, base},
    recognised = iSVPRCollectOptions[
      SourceVaultResolvePromptRoute, {opts}];
    routes = iSVPRLoadPromptRoutes[];
    If[!ListQ[routes], routes = {}];
    params = iSVPRExtractParameters[prompt];
    If[!AssociationQ[params], params = <||>];

    base = <|
      "Type"            -> "PromptRouteDecision",
      "Prompt"          -> prompt,
      "Parameters"      -> params,
      "RequestedOptions"-> recognised,
      "RouterPhase"     -> iSVPRImplementationPhase[],
      "RouterVersion"   -> $SourceVaultPromptRouterVersion
    |>;

    matched = iSVPRMatchRoute[prompt, routes];

    Which[
      (* deterministic: multiple keyword matches -> NeedsChoice *)
      ListQ[matched],
        Join[base, <|
          "Status"   -> "NeedsChoice",
          "Decision" -> "MultipleRoutesMatched",
          "Choices"  -> Map[Lookup[#, "RouteId", "?"] &, matched]|>],

      (* deterministic: single keyword match *)
      !MissingQ[matched],
        route  = matched;
        target = Lookup[route, "Target", <||>];
        Join[base, <|
          "Status"       -> "Matched",
          "Decision"     -> "DeterministicMatch",
          "RouteId"      -> Lookup[route, "RouteId", Missing[]],
          "RouteVersion" -> Lookup[route, "RouteVersion", Missing[]],
          "Target"       -> target|>],

      (* no deterministic match -> Order 4 lexical search *)
      True,
        lex = iSVPRLexicalSearch[prompt, routes];
        Which[
          Length[lex] === 0,
            Join[base, <|
              "Status"   -> "NotFound",
              "Decision" -> "NoMatch",
              "Target"   -> Missing["NoMatch"]|>],

          (* single, confident candidate -> auto-accept *)
          Length[lex] === 1 && lex[[1]]["Score"] >= 0.5,
            route  = lex[[1]]["Route"];
            target = Lookup[route, "Target", <||>];
            Join[base, <|
              "Status"       -> "Matched",
              "Decision"     -> "LexicalMatch",
              "RouteId"      -> Lookup[route, "RouteId", Missing[]],
              "RouteVersion" -> Lookup[route, "RouteVersion", Missing[]],
              "Target"       -> target,
              "Score"        -> lex[[1]]["Score"],
              "Reasons"      -> lex[[1]]["Reasons"]|>],

          (* otherwise: ranked candidate list, caller chooses *)
          True,
            Join[base, <|
              "Status"     -> "Candidates",
              "Decision"   -> "LexicalCandidates",
              "Candidates" ->
                Map[KeyDrop[#, "Route"] &, lex]|>]
        ]
    ]
  ];

SourceVaultResolvePromptRoute[arg_, OptionsPattern[]] :=
  <|"Type" -> "PromptRouteDecision",
    "Status" -> "Failed",
    "Reason" -> "PromptMustBeAString",
    "GivenHead" -> ToString[Head[arg]]|>;

(* ------------------------------------------------------------
   SourceVaultExecutePromptRoute[prompt, opts]

   Phase A: always returns NotDispatched. The claudecode weak call
   (spec 5.2), once wired in Phase A1, treats this as "fall back to
   the existing ClaudeEval route". Returning a structured Association
   here keeps that contract explicit.
   ------------------------------------------------------------ *)

SourceVaultExecutePromptRoute[prompt_String,
                              opts:OptionsPattern[]] :=
  Module[{recognised, dryRun, decision, target, adapter, fid,
          callable, plan, result, runRec, base},
    recognised = iSVPRCollectOptions[
      SourceVaultExecutePromptRoute, {opts}];
    dryRun = TrueQ[OptionValue[
      SourceVaultExecutePromptRoute, {opts}, "DryRun"]];

    decision = SourceVaultResolvePromptRoute[prompt, opts];

    base = <|
      "Type"            -> "PromptRouteExecution",
      "Prompt"          -> prompt,
      "Decision"        -> decision,
      "RequestedOptions"-> recognised,
      "RouterPhase"     -> iSVPRImplementationPhase[],
      "RouterVersion"   -> $SourceVaultPromptRouterVersion
    |>;

    (* not a deterministic match -> fall back to ClaudeEval *)
    If[!AssociationQ[decision] ||
       Lookup[decision, "Status", ""] =!= "Matched",
      Return[Join[base, <|
        "Status" -> "NotDispatched",
        "Reason" -> Lookup[decision, "Status", "ResolveFailed"]|>]]];

    target  = Lookup[decision, "Target", <||>];

    (* TabularQuery target (spec v11 5.3 / 5.4): a route whose
       Target Kind is "TabularQuery" is resolved by building a
       proposal expression with SourceVaultProposePromptRoute.
       SourceVaultExecutePromptRoute is the manual / test /
       diagnostics API (spec 5.3), so it MAY evaluate the held
       expression and report the evaluated result here. The
       ClaudeEval bridge does NOT come through this path -- it
       calls SourceVaultProposePromptRoute directly and submits
       the unevaluated ProposedExpression to the Runtime. *)
    If[Lookup[target, "Kind", ""] === "TabularQuery",
      Module[{proposal, heldExpr},
        proposal = SourceVaultProposePromptRoute[prompt];
        If[dryRun,
          Return[Join[base, <|
            "Status" -> "DryRun",
            "Plan" -> <|"Dispatch" -> "TabularQuery",
              "Proposal" -> proposal|>|>]]];
        If[!AssociationQ[proposal] ||
           Lookup[proposal, "Status", ""] =!= "Proposed",
          Return[Join[base, <|
            "Status" -> "DispatchFailed",
            "Dispatch" -> "TabularQuery",
            "Proposal" -> proposal|>]]];
        heldExpr = Lookup[proposal, "ProposedExpression",
          $Failed];
        (* manual API: evaluate the held proposal and return the
           evaluated schedule result for diagnostics *)
        Return[Join[base, <|
          "Status" -> "Dispatched",
          "Dispatch" -> "TabularQuery",
          "Proposal" -> proposal,
          "Result" -> If[
            MatchQ[heldExpr, _HoldComplete],
            ReleaseHold[heldExpr],
            $Failed]|>]]]];

    adapter = iSVPRApplyAdapter[target,
      Lookup[decision, "Parameters", <||>]];
    fid = Lookup[adapter, "FunctionId", Missing["NoFunctionId"]];

    If[!StringQ[fid],
      Return[Join[base, <|
        "Status" -> "NotDispatched",
        "Reason" -> "AdapterProducedNoFunctionId",
        "Adapter" -> adapter|>]]];

    callable = iSVPRResolveCallable[fid];
    If[!AssociationQ[callable],
      Return[Join[base, <|
        "Status" -> "NotDispatched",
        "Reason" -> "NotInAllowlist",
        "Adapter" -> adapter|>]]];
    If[!TrueQ[callable["UseAsFunctionRoute"]],
      Return[Join[base, <|
        "Status" -> "NotDispatched",
        "Reason" -> "NotUsableAsFunctionRoute",
        "Adapter" -> adapter|>]]];

    (* only ReadOnly callables auto-dispatch; others need approval *)
    If[Lookup[callable, "SideEffectClass", "Unknown"] =!= "ReadOnly",
      Return[Join[base, <|
        "Status" -> "NeedsApproval",
        "Reason" -> "NonReadOnlySideEffect",
        "Adapter" -> adapter|>]]];

    plan = <|
      "FunctionId"      -> fid,
      "Options"         -> Lookup[adapter, "Options", <||>],
      "AdapterKind"     -> Lookup[adapter, "AdapterKind", "Direct"],
      "ApproximateRoute"-> TrueQ[Lookup[adapter, "ApproximateRoute", False]]
    |>;

    (* DryRun: report the plan, do not invoke the callable *)
    If[dryRun,
      Return[Join[base, <|
        "Status" -> "DryRun",
        "Plan"   -> plan|>]]];

    (* dispatch: invoke the real callable with the adapted Options *)
    result = Quiet @ Check[
      callable["Symbol"][
        Sequence @@ Normal[Lookup[adapter, "Options", <||>]]],
      $Failed];

    (* record the run in the append-only PromptRun store (Order 1) *)
    runRec = Quiet @ Check[
      SourceVaultPromptRunRecord[prompt, decision,
        <|"Kind" -> "FunctionResult"|>],
      <|"Status" -> "Failed"|>];

    Join[base, <|
      "Status" -> If[result === $Failed, "DispatchFailed", "Dispatched"],
      "Plan"   -> plan,
      "Result" -> result,
      "RunId"  -> Lookup[runRec, "RunId", Missing["NotRecorded"]]
    |>]
  ];

SourceVaultExecutePromptRoute[arg_, OptionsPattern[]] :=
  <|"Type" -> "PromptRouteExecution",
    "Status" -> "NotDispatched",
    "Reason" -> "PromptMustBeAString",
    "GivenHead" -> ToString[Head[arg]]|>;

(* ------------------------------------------------------------
   SourceVaultRouteExplain[prompt, opts]

   Phase A: reports that resolution is not yet implemented and
   returns the current router status alongside the (skeleton)
   decision so that the explanation is still informative.
   ------------------------------------------------------------ *)

SourceVaultRouteExplain[prompt_String,
                        opts:OptionsPattern[]] :=
  Module[{decision},
    decision = SourceVaultResolvePromptRoute[prompt, opts];
    <|
      "Type"        -> "PromptRouteExplanation",
      "Prompt"      -> prompt,
      "Summary"     ->
        "PromptRouter is in the Phase A skeleton state. Route " <>
        "resolution is not implemented yet, so every prompt resolves " <>
        "to NotFound and execution returns NotDispatched (the " <>
        "ClaudeEval fallback path).",
      "Decision"    -> decision,
      "RouterStatus"-> SourceVaultPromptRouterStatus[]
    |>
  ];

SourceVaultRouteExplain[arg_, OptionsPattern[]] :=
  <|"Type" -> "PromptRouteExplanation",
    "Status" -> "Failed",
    "Reason" -> "PromptMustBeAString",
    "GivenHead" -> ToString[Head[arg]]|>;

(* ============================================================
   Order 1: PromptRun append-only JSONL store.

   A PromptRun is execution history. It is stored like SourceVault's
   claims.jsonl / source-events.jsonl: an append-only JSONL file
   under <PrivateVault>/promptrouter/runs/, NOT in the compiled
   registry (spec sections 9.0, 24.1).

   JSONL append / read follow SourceVault's existing pattern:
   iSanitizeForJSON for encoding, ReadByteArray + ByteArrayToString
   for decoding (rule 101 / 103). iSanitizeForJSON and iEnsureDir
   are SourceVault-owned private helpers; this extension runs in the
   same SourceVault`Private` context and may use them directly.
   ============================================================ *)

(* Minimal prompt normalizer for Order 1. The full normalizer
   (Unicode / full-width / kanji-digit / synonym map) arrives in
   Order 3/4; PromptHash will be recomputed from it then. *)
iSVPRNormalizePrompt[s_String] :=
  ToLowerCase[
    StringReplace[StringTrim[s], RegularExpression["\\s+"] -> " "]];
iSVPRNormalizePrompt[_] := "";

(* store paths *)
iSVPRRunsDir[] :=
  FileNameJoin[{
    SourceVault`$SourceVaultRoots["PrivateVault"],
    "promptrouter", "runs"}];

iSVPRRunsJSONLPath[] :=
  FileNameJoin[{iSVPRRunsDir[], "prompt-runs.jsonl"}];

(* run id / timestamp *)
iSVPRMakeRunId[] := "prun-" <> CreateUUID[];

iSVPRTimestamp[] :=
  Quiet @ Check[DateString[Now, "ISODateTime"], DateString[]];

(* Append one PromptRun record as a single JSONL line, following
   SourceVault's claims-append pattern. *)
iSVPRAppendRunJSONL[record_Association] :=
  Module[{path, sanitized, line, strm},
    path = iSVPRRunsJSONLPath[];
    sanitized = iSanitizeForJSON[record];
    line = Quiet @ Check[
      ExportString[sanitized, "RawJSON", "Compact" -> True],
      $Failed];
    If[!StringQ[line],
      Return[<|"Status" -> "Failed",
        "Reason" -> "JSONEncodeFailed", "Path" -> path|>]];
    iEnsureDir[DirectoryName[path]];
    strm = Quiet[OpenAppend[path, BinaryFormat -> True]];
    If[Head[strm] =!= OutputStream,
      Return[<|"Status" -> "Failed",
        "Reason" -> "OpenAppendFailed", "Path" -> path|>]];
    BinaryWrite[strm, StringToByteArray[line <> "\n", "UTF-8"]];
    Close[strm];
    <|"Status" -> "OK", "Path" -> path|>
  ];

(* Load all PromptRun records, following SourceVault's
   iClaimsLoadJSONL pattern. Returns oldest-first. *)
iSVPRLoadRunsJSONL[] :=
  Module[{path, rawBytes, content, lines, parsed},
    path = iSVPRRunsJSONLPath[];
    If[!FileExistsQ[path], Return[{}]];
    rawBytes = Quiet[ReadByteArray[path]];
    If[!ByteArrayQ[rawBytes], Return[{}]];
    content = Quiet[ByteArrayToString[rawBytes, "UTF-8"]];
    If[!StringQ[content], Return[{}]];
    lines = StringSplit[content, RegularExpression["\\r?\\n"]];
    lines = Select[lines, StringTrim[#] =!= "" &];
    parsed = Map[
      Function[ln,
        Module[{r = Quiet[ImportString[ln, "RawJSON"]]},
          If[ListQ[r] && !AssociationQ[r], r = Association[r]];
          If[AssociationQ[r], r, Missing["ParseFailed"]]]],
      lines];
    Select[parsed, AssociationQ]
  ];

(* Summarise an arbitrary result value into the Result sub-schema. *)
iSVPRResultSummary[result_] :=
  Which[
    AssociationQ[result],
      {Lookup[result, "Kind", "Unknown"],
       Lookup[result, "BundleId", Missing["None"]],
       Lookup[result, "CacheKey", Missing["None"]]},
    result === Null,
      {"None", Missing["None"], Missing["None"]},
    True,
      {"Opaque", Missing["None"], Missing["None"]}
  ];

Options[SourceVaultPromptRunRecord] = {
  "StorePrompt"         -> "HashOnly",
  "PrivacyLevel"        -> 0.0,
  "PrivacyOrigin"       -> {},
  "AllowedTrustDomains" -> Automatic,
  "CloudFallback"       -> "Ask",
  "Dependencies"        -> <||>,
  "ModelResolution"     -> <||>,
  "DryRun"              -> False
};

SourceVaultPromptRunRecord[prompt_String, routeDecision_Association,
                           result_, opts:OptionsPattern[]] :=
  Module[{storeClass, normalized, promptHash, runId, ts, record,
          rawStored, deps, modelRes, privLevel, appendResult,
          routeId, routeVer, decision, params,
          resultKind, resultBundle, resultCache, summary},

    storeClass = OptionValue[
      SourceVaultPromptRunRecord, {opts}, "StorePrompt"];
    If[storeClass === "Off",
      Return[<|"Status" -> "Skipped",
        "Reason" -> "StorePromptOff"|>]];
    If[storeClass =!= "HashOnly" && storeClass =!= "PrivateRaw",
      storeClass = "HashOnly"];

    normalized = iSVPRNormalizePrompt[prompt];
    promptHash = "sha256:" <> Hash[normalized, "SHA256", "HexString"];
    runId = iSVPRMakeRunId[];
    ts = iSVPRTimestamp[];
    rawStored = (storeClass === "PrivateRaw");

    deps = OptionValue[
      SourceVaultPromptRunRecord, {opts}, "Dependencies"];
    If[!AssociationQ[deps], deps = <||>];
    modelRes = OptionValue[
      SourceVaultPromptRunRecord, {opts}, "ModelResolution"];
    If[!AssociationQ[modelRes], modelRes = <||>];
    privLevel = OptionValue[
      SourceVaultPromptRunRecord, {opts}, "PrivacyLevel"];

    routeId  = Lookup[routeDecision, "RouteId",
                 Missing["NotApplicable"]];
    routeVer = Lookup[routeDecision, "RouteVersion",
                 Missing["NotApplicable"]];
    decision = Lookup[routeDecision, "Decision",
                 Lookup[routeDecision, "Status", "Unknown"]];
    params   = Lookup[routeDecision, "Parameters", <||>];
    If[!AssociationQ[params], params = <||>];

    summary = iSVPRResultSummary[result];
    {resultKind, resultBundle, resultCache} = summary;

    record = <|
      "Type"               -> "PromptRun",
      "RunId"              -> runId,
      "Timestamp"          -> ts,
      "PromptHash"         -> promptHash,
      "PromptFingerprint"  -> promptHash,
      "RawPromptStored"    -> rawStored,
      "PromptStorageClass" -> storeClass,
      "RawPrompt"          ->
        If[rawStored, prompt, Missing["NotStored"]],
      "Route" -> <|
        "RouteId"      -> routeId,
        "RouteVersion" -> routeVer,
        "Decision"     -> decision
      |>,
      "Parameters" -> params,
      "Dependencies" -> <|
        "SourceSnapshots"  ->
          Lookup[deps, "SourceSnapshots", {}],
        "RegistryVersions" ->
          Lookup[deps, "RegistryVersions", {}],
        "WorkflowTemplate" ->
          Lookup[deps, "WorkflowTemplate", Missing["None"]]
      |>,
      "ModelResolution" -> <|
        "Requested"         ->
          Lookup[modelRes, "Requested", <||>],
        "Resolved"          ->
          Lookup[modelRes, "Resolved", <||>],
        "FallbackKind"      ->
          Lookup[modelRes, "FallbackKind", Missing["None"]],
        "CloudFallbackUsed" ->
          TrueQ[Lookup[modelRes, "CloudFallbackUsed", False]]
      |>,
      "Privacy" -> <|
        "PrivacyLevel"        -> privLevel,
        "PrivacyOrigin"       -> OptionValue[
          SourceVaultPromptRunRecord, {opts}, "PrivacyOrigin"],
        "AllowedTrustDomains" -> OptionValue[
          SourceVaultPromptRunRecord, {opts}, "AllowedTrustDomains"],
        "CloudFallback"       -> OptionValue[
          SourceVaultPromptRunRecord, {opts}, "CloudFallback"]
      |>,
      "Result" -> <|
        "Kind"     -> resultKind,
        "BundleId" -> resultBundle,
        "CacheKey" -> resultCache
      |>,
      "RouterVersion" -> $SourceVaultPromptRouterVersion
    |>;

    If[TrueQ[OptionValue[
        SourceVaultPromptRunRecord, {opts}, "DryRun"]],
      Return[<|"Status" -> "DryRun",
        "RunId" -> runId, "Record" -> record|>]];

    appendResult = iSVPRAppendRunJSONL[record];
    If[Lookup[appendResult, "Status", "Failed"] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[appendResult, "Reason", "AppendFailed"],
        "RunId" -> runId, "Record" -> record|>]];

    <|"Status" -> "OK", "RunId" -> runId,
      "Path" -> Lookup[appendResult, "Path", Missing["None"]],
      "Record" -> record|>
  ];

SourceVaultPromptRunRecord[___] :=
  <|"Type" -> "PromptRun",
    "Status" -> "Failed",
    "Reason" -> "InvalidArguments",
    "Hint" ->
      "Expected SourceVaultPromptRunRecord[prompt_String, " <>
      "routeDecision_Association, result_, opts]."|>;

Options[SourceVaultPromptRunHistory] = {
  "MaxResults" -> Automatic,
  "RouteId"    -> Automatic,
  "Decision"   -> Automatic,
  "Since"      -> Automatic
};

SourceVaultPromptRunHistory[opts:OptionsPattern[]] :=
  Module[{runs, maxR, routeId, decision, since, filtered},
    runs = iSVPRLoadRunsJSONL[];
    If[!ListQ[runs], runs = {}];

    routeId  = OptionValue[
      SourceVaultPromptRunHistory, {opts}, "RouteId"];
    decision = OptionValue[
      SourceVaultPromptRunHistory, {opts}, "Decision"];
    since    = OptionValue[
      SourceVaultPromptRunHistory, {opts}, "Since"];
    maxR     = OptionValue[
      SourceVaultPromptRunHistory, {opts}, "MaxResults"];

    filtered = runs;
    If[StringQ[routeId],
      filtered = Select[filtered,
        Lookup[Lookup[#, "Route", <||>], "RouteId", Null]
          === routeId &]];
    If[StringQ[decision],
      filtered = Select[filtered,
        Lookup[Lookup[#, "Route", <||>], "Decision", Null]
          === decision &]];
    If[StringQ[since],
      (* ISO date-time strings sort lexicographically by time.
         Wolfram does not evaluate >= on strings, so use Order:
         Order[since, ts] >= 0 means since precedes-or-equals ts. *)
      filtered = Select[filtered,
        Module[{ts = Lookup[#, "Timestamp", ""]},
          StringQ[ts] && Order[since, ts] >= 0] &]];

    (* newest first: the JSONL file is append-order = oldest first *)
    filtered = Reverse[filtered];

    If[IntegerQ[maxR] && maxR >= 0,
      filtered = Take[filtered, UpTo[maxR]]];
    filtered
  ];

SourceVaultPromptRunHistory[___] :=
  <|"Status" -> "Failed",
    "Reason" -> "InvalidArguments",
    "Hint" -> "Expected SourceVaultPromptRunHistory[opts]."|>;


(* ============================================================
   Order 3a: callable allowlist + deterministic parameter
   extraction.

   These are pure parts of the deterministic FunctionRoute:
   - the SourceVault-owned callable allowlist (spec 7.3 / 25),
   - the canonical parameter extraction engine (spec 8.2).
   They do NOT touch the PromptRoute compiled registry; that
   binding is Order 3b.

   Per spec 6.2 / 25, only callables that REALLY exist in
   SourceVault.wl are registered: SourceVaultUpcomingSchedule and
   SourceVaultFindNotebooks. SourceVaultReviewQueue /
   SourceVaultOpenTodoList are deliberately NOT registered; they
   are handled as semantic IntentIds whose adapter targets
   SourceVaultFindNotebooks (Order 3b).

   Japanese keywords below are written as \:XXXX literals so the
   source stays all-ASCII (rule 30 / trap #11).
   ============================================================ *)

(* ----- callable allowlist (SourceVault-owned) ----- *)

(* SourceVaultCallableAllowlistRegistry[] is a code-resident
   constant table. It holds raw Wolfram symbols, so it must never
   be written to a compiled JSON registry (spec 7.3). Only
   callables that exist in SourceVault.wl appear here. *)
SourceVaultCallableAllowlistRegistry[] :=
  <|
    "SourceVaultUpcomingSchedule" -> <|
      "FunctionId"         -> "SourceVaultUpcomingSchedule",
      "Symbol"             -> SourceVaultUpcomingSchedule,
      "UseAsFunctionRoute" -> True,
      "UseAsHandlerRef"    -> True,
      "SideEffectClass"    -> "ReadOnly",
      "OwnerPackage"       -> "SourceVault"
    |>,
    "SourceVaultFindNotebooks" -> <|
      "FunctionId"         -> "SourceVaultFindNotebooks",
      "Symbol"             -> SourceVaultFindNotebooks,
      "UseAsFunctionRoute" -> True,
      "UseAsHandlerRef"    -> True,
      "SideEffectClass"    -> "ReadOnly",
      "OwnerPackage"       -> "SourceVault"
    |>
  |>;

SourceVaultCallableAllowlistRegistry[___] :=
  <|"Status" -> "Failed",
    "Reason" -> "SourceVaultCallableAllowlistRegistry takes no arguments."|>;

(* Weak call into the ClaudeOrchestrator-owned handler allowlist.
   SourceVault does NOT hard-depend on ClaudeOrchestrator (rule 11):
   the call goes through Names / Symbol only, and an absent or
   failing Orchestrator simply yields an empty handler set. Both
   plausible context locations are probed. *)
iSVPROrchestratorHandlerAllowlist[] :=
  Module[{candidates, hit, res},
    candidates = {
      "ClaudeOrchestrator`Workflow`ClaudeWorkflowHandlerAllowlist",
      "ClaudeOrchestrator`ClaudeWorkflowHandlerAllowlist"};
    hit = SelectFirst[candidates,
      Length[Names[#]] > 0 &, Missing["NoOrchestrator"]];
    If[MissingQ[hit], Return[<||>]];
    res = Quiet @ Check[Symbol[hit][], <||>];
    If[AssociationQ[res], res, <||>]
  ];

(* SourceVaultCallableAllowlistView[] is the merged logical view
   that FunctionRoute dispatch and HandlerRef resolution consult.
   SourceVault-owned entries take precedence on key conflict. *)
SourceVaultCallableAllowlistView[] :=
  Module[{base, orch},
    base = SourceVaultCallableAllowlistRegistry[];
    If[!AssociationQ[base], base = <||>];
    orch = iSVPROrchestratorHandlerAllowlist[];
    If[!AssociationQ[orch], orch = <||>];
    Join[orch, base]
  ];

SourceVaultCallableAllowlistView[___] :=
  <|"Status" -> "Failed",
    "Reason" -> "SourceVaultCallableAllowlistView takes no arguments."|>;

(* Resolve a FunctionId against the merged view. Returns the entry
   Association, or Missing["NotInAllowlist"]. *)
iSVPRResolveCallable[functionId_String] :=
  Lookup[SourceVaultCallableAllowlistView[], functionId,
    Missing["NotInAllowlist"]];
iSVPRResolveCallable[_] := Missing["NotInAllowlist"];

(* ----- deterministic parameter extraction (spec 8.2) ----- *)

(* kanji digit 1..10 -> Integer *)
iSVPRKanjiDigitMap[] := <|"\:4e00" -> 1, "\:4e8c" -> 2, "\:4e09" -> 3, "\:56db" -> 4, "\:4e94" -> 5, "\:516d" -> 6, "\:4e03" -> 7, "\:516b" -> 8, "\:4e5d" -> 9, "\:5341" -> 10|>;

iSVPRKanjiToInt[s_String] :=
  Lookup[iSVPRKanjiDigitMap[], s, Missing["NotKanjiDigit"]];
iSVPRKanjiToInt[_] := Missing["NotKanjiDigit"];

(* Extract a period in days from a prompt. Recognises:
     <digits> + NICHIKAN          e.g. 3 + (day-span)
     <kanji>  + NICHIKAN          e.g. (three) + (day-span)
     ISSHUUKAN (one week)         -> 7
     <digits> days / day          (ASCII, case-insensitive)
   Returns an Integer, or Missing["NoPeriod"]. *)
iSVPRExtractPeriodDays[prompt_String] :=
  Module[{digitHits, kanjiHits, weekHit, asciiHits, n},
    (* <digits> + day-span *)
    digitHits = Quiet @ StringCases[prompt,
      RegularExpression["([0-9]+)\:65e5\:9593"] -> "$1"];
    If[ListQ[digitHits] && Length[digitHits] > 0,
      n = Quiet @ Check[ToExpression[First[digitHits]], $Failed];
      If[IntegerQ[n] && n > 0, Return[n]]];
    (* <kanji> + day-span *)
    kanjiHits = Quiet @ StringCases[prompt,
      (k:("\:4e00" | "\:4e8c" | "\:4e09" | "\:56db" | "\:4e94" | "\:516d" | "\:4e03" | "\:516b" | "\:4e5d" | "\:5341")) ~~ "\:65e5\:9593" -> k];
    If[ListQ[kanjiHits] && Length[kanjiHits] > 0,
      n = iSVPRKanjiToInt[First[kanjiHits]];
      If[IntegerQ[n] && n > 0, Return[n]]];
    (* one week *)
    weekHit = StringContainsQ[prompt, "\:4e00\:9031\:9593"];
    If[TrueQ[weekHit], Return[7]];
    (* ASCII: <digits> day(s) *)
    asciiHits = Quiet @ StringCases[ToLowerCase[prompt],
      RegularExpression["([0-9]+)\\s*days?"] -> "$1"];
    If[ListQ[asciiHits] && Length[asciiHits] > 0,
      n = Quiet @ Check[ToExpression[First[asciiHits]], $Failed];
      If[IntegerQ[n] && n > 0, Return[n]]];
    Missing["NoPeriod"]
  ];
iSVPRExtractPeriodDays[_] := Missing["NoPeriod"];

(* Master extraction. Returns an Association of canonical
   parameters (spec 8.2.1 normal form). Keys are present only when
   a value was detected. The "Ambiguous" key, when present, lists
   parameter names whose detection was ambiguous (e.g. KONSHUU). *)
iSVPRExtractParameters[prompt_String] :=
  Module[{p, lower, params, ambiguous, pd,
          todoKeys, reviewKeys, deadlineKeys,
          hasTodo, hasReview, hasDeadline, hasWeek},
    p = prompt;
    lower = ToLowerCase[p];
    params = <||>;
    ambiguous = {};

    todoKeys     = {"Todo\:304c\:6b8b\:3063\:3066\:3044\:308b", "\:672a\:5b8c\:4e86", "\:6b8b\:3063\:3066\:3044\:308bTodo", "open todo"};
    reviewKeys   = {"\:30ec\:30d3\:30e5\:30fc"};
    deadlineKeys = {"\:7de0\:5207", "\:671f\:9650"};

    (* PeriodDays (canonical: PeriodDays -> n_Integer; Quantity is
       produced only by the adapter, spec 8.2.1) *)
    pd = iSVPRExtractPeriodDays[p];
    If[IntegerQ[pd], params["PeriodDays"] = pd];

    (* this-week: ambiguous between CalendarWeek and PeriodDays 7 *)
    hasWeek = StringContainsQ[p, "\:4eca\:9031"];
    If[TrueQ[hasWeek],
      params["DateRangeKind"] = "CalendarWeek";
      ambiguous = Append[ambiguous, "DateRangeKind"]];

    (* OpenTodos: any todo keyword (English compared lower-case) *)
    hasTodo = AnyTrue[todoKeys,
      StringContainsQ[p, #] || StringContainsQ[lower, ToLowerCase[#]] &];
    If[TrueQ[hasTodo], params["OpenTodos"] = True];

    (* review intent *)
    hasReview = AnyTrue[reviewKeys, StringContainsQ[p, #] &] ||
      StringContainsQ[lower, "nextreview"];
    If[TrueQ[hasReview],
      params["IntentId"]  = "ReviewQueue";
      params["DateField"] = "NextReview"];

    (* deadline keyword (English "deadline" compared lower-case) *)
    hasDeadline = AnyTrue[deadlineKeys, StringContainsQ[p, #] &] ||
      StringContainsQ[lower, "deadline"];
    If[TrueQ[hasDeadline] && !KeyExistsQ[params, "DateField"],
      params["DateField"] = "Deadline"];

    (* $onWork scope reference (identity, not authority - spec 8.2.1) *)
    If[StringContainsQ[p, "$onWork"],
      params["ScopeRef"] =
        <|"Kind" -> "RootSymbol", "Name" -> "$onWork"|>];

    If[Length[ambiguous] > 0,
      params["Ambiguous"] = ambiguous];
    params
  ];
iSVPRExtractParameters[_] := <||>;



(* ============================================================
   Order 3b-1: seed PromptRoutes, registry load, deterministic
   route matching.

   SourceVaultResolvePromptRoute is upgraded from the Phase A
   skeleton to a real resolver: it loads PromptRoutes (compiled
   registry + built-in seed fallback) and matches the prompt by
   the Matcher KeywordsAny set, attaching the canonical parameters
   extracted in Order 3a.

   Built-in seed routes follow SourceVault's seed philosophy: a
   seed is not production truth, only a fallback when the compiled
   registry has no entry (cf. SourceVaultRegisterSeed). Registry
   routes take precedence by RouteId.

   The FunctionRoute dispatch / adapter (turning a decision into a
   real callable invocation) is Order 3b-2; SourceVaultExecutePromptRoute
   stays a skeleton until then.

   Japanese keywords are \:XXXX literals (rule 30 / trap #11).
   ============================================================ *)

(* ----- built-in seed PromptRoutes (spec 7.1 schema, abridged) -----
   Only routes whose Target resolves to a real callable or to a
   well-defined IntentId are seeded. *)
iSVPRSeedPromptRoutes[] :=
  {
    <|
      "Type"         -> "PromptRoute",
      "RouteId"      -> "seed-sourcevault-upcoming-schedule-v1",
      "RouteVersion" -> 1,
      "SchemaVersion"-> 1,
      "Matcher" -> <|
        "Kind"        -> "DeterministicPattern",
        "KeywordsAny" -> {"\:30b9\:30b1\:30b8\:30e5\:30fc\:30eb", "\:4e88\:5b9a", "schedule"}
      |>,
      "Target" -> <|
        "Kind"       -> "TabularQuery",
        "DataSource" -> "schedule"
      |>,
      "Privacy" -> <|"PrivacyLevel" -> 0.0|>,
      "Source"  -> "SeedBuiltIn"
    |>,
    <|
      "Type"         -> "PromptRoute",
      "RouteId"      -> "seed-intent-reviewqueue-v1",
      "RouteVersion" -> 1,
      "SchemaVersion"-> 1,
      "Matcher" -> <|
        "Kind"        -> "DeterministicPattern",
        "KeywordsAny" -> {"\:30ec\:30d3\:30e5\:30fc"}
      |>,
      "Target" -> <|
        "Kind"             -> "Intent",
        "IntentId"         -> "ReviewQueue",
        "AdapterFunctionId"-> "SourceVaultFindNotebooks"
      |>,
      "Privacy" -> <|"PrivacyLevel" -> 0.0|>,
      "Source"  -> "SeedBuiltIn"
    |>,
    <|
      "Type"         -> "PromptRoute",
      "RouteId"      -> "seed-intent-opentodolist-v1",
      "RouteVersion" -> 1,
      "SchemaVersion"-> 1,
      "Matcher" -> <|
        "Kind"        -> "DeterministicPattern",
        "KeywordsAny" -> {"\:672a\:5b8c\:4e86", "Todo\:304c\:6b8b\:3063\:3066\:3044\:308b", "open todo"}
      |>,
      "Target" -> <|
        "Kind"             -> "Intent",
        "IntentId"         -> "OpenTodoList",
        "AdapterFunctionId"-> "SourceVaultFindNotebooks"
      |>,
      "Privacy" -> <|"PrivacyLevel" -> 0.0|>,
      "Source"  -> "SeedBuiltIn"
    |>
  };

(* ----- load PromptRoutes: compiled registry first, seed fills gaps -----
   iCompiledPath / iLoadRegistryEntries are SourceVault-owned private
   helpers; this extension runs in the same SourceVault`Private context
   and may use them directly. *)
iSVPRLoadPromptRoutes[] :=
  Module[{path, registryRoutes, seed, regIds},
    seed = iSVPRSeedPromptRoutes[];
    path = Quiet @ Check[
      iCompiledPath["prompt-route-registry", "public"], $Failed];
    registryRoutes = If[StringQ[path] && FileExistsQ[path],
      Quiet @ Check[iLoadRegistryEntries[path], {}],
      {}];
    If[!ListQ[registryRoutes], registryRoutes = {}];
    registryRoutes = Select[registryRoutes, AssociationQ];
    (* registryRoutes is a LIST of Associations: map Lookup
       over it. Lookup[list, key] would mis-read the list as
       a rule-list and raise Lookup::invrl. *)
    regIds = Map[Lookup[#, "RouteId", Null] &, registryRoutes];
    (* registry routes win; seed routes fill RouteIds not in registry *)
    Join[
      registryRoutes,
      Select[seed,
        Function[sr, !MemberQ[regIds, Lookup[sr, "RouteId", Null]]]]
    ]
  ];

(* ----- deterministic keyword match -----
   Returns the single matching route, a List of routes (ambiguous),
   or Missing["NoMatch"]. *)
iSVPRMatchRoute[prompt_String, routes_List] :=
  Module[{hits},
    hits = Select[routes,
      Function[route,
        Module[{kws},
          kws = Lookup[Lookup[route, "Matcher", <||>], "KeywordsAny", {}];
          ListQ[kws] && AnyTrue[kws,
            StringQ[#] && StringContainsQ[prompt, #] &]]]];
    Which[
      Length[hits] === 0, Missing["NoMatch"],
      Length[hits] === 1, First[hits],
      True,               hits
    ]
  ];
iSVPRMatchRoute[_, _] := Missing["NoMatch"];



(* ============================================================
   Order 3b-2: canonical-parameter adapter and FunctionRoute
   dispatch.

   SourceVaultExecutePromptRoute is upgraded from the Phase A
   skeleton to a real dispatcher: resolve -> adapter -> allowlist
   check -> dispatch (ReadOnly callables only) -> PromptRun record.

   The adapter turns a route decision into a concrete callable
   invocation:
   - Function target: canonical parameters become the callable's
     real Options. PeriodDays -> "Period" -> Quantity[n,"Days"]
     (spec 8.2.1: Quantity is produced only here, never stored).
   - Intent target: spec 25.3 / 25.4 InitialAdapter. ReviewQueue /
     OpenTodoList map onto SourceVaultFindNotebooks options. A
     PeriodDays-bearing ReviewQueue is flagged ApproximateRoute so
     the day-range is never silently approximated (spec 25.3).
   ============================================================ *)

(* ----- canonical parameters -> real Options for a Function id ----- *)
iSVPRParamsToOptions[functionId_String, params_Association] :=
  Module[{opts, pd, scope},
    opts = <||>;
    Which[
      functionId === "SourceVaultUpcomingSchedule",
        pd = Lookup[params, "PeriodDays", Missing[]];
        If[IntegerQ[pd] && pd > 0,
          opts["Period"] = Quantity[pd, "Days"]];
        scope = Lookup[params, "ScopeRef", Missing[]];
        If[AssociationQ[scope] && StringQ[Lookup[scope, "Name", Null]],
          (* ScopeRef is identity, not authority: the real Scope is
             still subject to NBAccess authorization downstream. *)
          opts["Scope"] = scope["Name"]],
      functionId === "SourceVaultFindNotebooks",
        If[Lookup[params, "OpenTodos", Missing[]] === True,
          opts["OpenTodos"] = True];
        If[Lookup[params, "DateField", ""] === "Deadline",
          opts["Deadline"] = "DueSoon"];
        If[Lookup[params, "DateField", ""] === "NextReview",
          opts["NextReview"] = "DueSoon"],
      True,
        Null
    ];
    opts
  ];
iSVPRParamsToOptions[_, _] := <||>;

(* ----- Intent target -> concrete adapter (spec 25.3 / 25.4) ----- *)
iSVPRIntentAdapter[intentId_String, params_Association] :=
  Module[{opts, pd, approx},
    approx = False;
    Which[
      intentId === "ReviewQueue",
        opts = <|"NextReview" -> "DueSoon", "OpenTodos" -> Missing[]|>;
        If[Lookup[params, "OpenTodos", Missing[]] === True,
          opts["OpenTodos"] = True];
        pd = Lookup[params, "PeriodDays", Missing[]];
        (* spec 25.3: an exact day-range cannot be expressed by the
           current SourceVaultFindNotebooks NextReview option, so a
           PeriodDays-bearing ReviewQueue is an approximate route. *)
        If[IntegerQ[pd], approx = True];
        <|"FunctionId"      -> "SourceVaultFindNotebooks",
          "Options"         -> opts,
          "AdapterKind"     -> "Intent",
          "IntentId"        -> "ReviewQueue",
          "ApproximateRoute"-> approx|>,
      intentId === "OpenTodoList",
        <|"FunctionId"      -> "SourceVaultFindNotebooks",
          "Options"         -> <|"OpenTodos" -> True|>,
          "AdapterKind"     -> "Intent",
          "IntentId"        -> "OpenTodoList",
          "ApproximateRoute"-> False|>,
      True,
        <|"FunctionId"      -> Missing["UnknownIntent"],
          "Options"         -> <||>,
          "AdapterKind"     -> "Intent",
          "IntentId"        -> intentId,
          "ApproximateRoute"-> False|>
    ]
  ];
iSVPRIntentAdapter[_, _] :=
  <|"FunctionId" -> Missing["UnknownIntent"], "Options" -> <||>,
    "AdapterKind" -> "Intent", "ApproximateRoute" -> False|>;

(* ----- route Target -> concrete adapter ----- *)
iSVPRApplyAdapter[target_Association, params_Association] :=
  Module[{kind, fid},
    kind = Lookup[target, "Kind", "Function"];
    Which[
      kind === "Function",
        fid = Lookup[target, "FunctionId", Missing["NoFunctionId"]];
        <|"FunctionId"      -> fid,
          "Options"         ->
            If[StringQ[fid], iSVPRParamsToOptions[fid, params], <||>],
          "AdapterKind"     -> "Direct",
          "ApproximateRoute"-> False|>,
      kind === "Intent",
        iSVPRIntentAdapter[
          Lookup[target, "IntentId", ""], params],
      True,
        <|"FunctionId" -> Missing["UnknownTargetKind"],
          "Options" -> <||>, "AdapterKind" -> "Unknown",
          "ApproximateRoute" -> False|>
    ]
  ];
iSVPRApplyAdapter[_, _] :=
  <|"FunctionId" -> Missing["BadTarget"], "Options" -> <||>,
    "AdapterKind" -> "Unknown", "ApproximateRoute" -> False|>;



(* ============================================================
   Order 4: lexical / keyword inverted-index search.

   When deterministic FunctionRoute matching (Order 3) finds no
   route, the resolver falls back to a lexical search over a
   token inverted index built from the route Matcher KeywordsAny
   sets (spec 21.3 step 3). A synonym map normalises surface
   forms onto canonical tokens so that, e.g., the synonym for
   "review" also reaches the ReviewQueue route.

   Results are a ranked candidate list (spec 21.4): each
   candidate carries a Score and the Reasons that produced it. A
   single high-score candidate is auto-accepted (Decision
   LexicalMatch); otherwise the decision is LexicalCandidates and
   the caller chooses.

   The index is a derived view of the loaded routes, not a new
   database (spec 21.1). Japanese synonym keys are \:XXXX
   literals (rule 30 / trap #11).
   ============================================================ *)

(* surface form -> canonical token (spec 21.3 step 3 synonym map) *)
iSVPRSynonymMap[] := <|"\:30b9\:30b1\:30b8\:30e5\:30fc\:30eb" -> "schedule", "\:4e88\:5b9a" -> "schedule", "schedule" -> "schedule", "\:30ec\:30d3\:30e5\:30fc" -> "review", "\:898b\:76f4\:3057" -> "review", "review" -> "review", "\:672a\:5b8c\:4e86" -> "opentodo", "Todo\:304c\:6b8b\:3063\:3066\:3044\:308b" -> "opentodo", "done\:3067\:306a\:3044" -> "opentodo", "open todo" -> "opentodo", "\:7de0\:5207" -> "deadline", "\:671f\:9650" -> "deadline", "deadline" -> "deadline"|>;

(* tokenise text into canonical tokens by detecting synonym-map
   surface forms. Japanese is not morphologically parsed (spec
   21.3): detection is by substring containment, ASCII case-folded. *)
iSVPRTokenize[text_String] :=
  Module[{lower, tokens},
    lower = ToLowerCase[text];
    tokens = {};
    KeyValueMap[
      Function[{surface, canon},
        If[StringContainsQ[lower, ToLowerCase[surface]],
          tokens = Append[tokens, canon]]],
      iSVPRSynonymMap[]];
    DeleteDuplicates[tokens]
  ];
iSVPRTokenize[_] := {};

(* canonical tokens of a route's KeywordsAny set *)
iSVPRRouteTokens[route_Association] :=
  DeleteDuplicates[Flatten[
    Map[iSVPRTokenize,
      Select[
        Lookup[Lookup[route, "Matcher", <||>], "KeywordsAny", {}],
        StringQ]]]];
iSVPRRouteTokens[_] := {};

(* token -> {RouteId,...} inverted index over the loaded routes *)
iSVPRBuildSearchIndex[routes_List] :=
  Module[{idx},
    idx = <||>;
    Scan[
      Function[route,
        Module[{rid, toks},
          rid  = Lookup[route, "RouteId", Null];
          toks = iSVPRRouteTokens[route];
          Scan[
            Function[tok,
              idx[tok] = Append[Lookup[idx, tok, {}], rid]],
            toks]]],
      Select[routes, AssociationQ]];
    Map[DeleteDuplicates, idx]
  ];
iSVPRBuildSearchIndex[_] := <||>;

(* lexical search: returns a Score-sorted candidate list. Each
   candidate is <|RouteId, Kind, Score, Reasons, Route|>. Score is
   the fraction of prompt tokens that the route covers. *)
iSVPRLexicalSearch[prompt_String, routes_List] :=
  Module[{idx, ptoks, routeById, hitCount, candidates},
    idx   = iSVPRBuildSearchIndex[routes];
    ptoks = iSVPRTokenize[prompt];
    If[Length[ptoks] === 0, Return[{}]];
    routeById = Association[
      Map[(Lookup[#, "RouteId", Null] -> #) &,
        Select[routes, AssociationQ]]];
    hitCount = <||>;
    Scan[
      Function[tok,
        Scan[
          Function[rid,
            hitCount[rid] = Lookup[hitCount, rid, 0] + 1],
          Lookup[idx, tok, {}]]],
      ptoks];
    candidates = KeyValueMap[
      Function[{rid, cnt},
        Module[{route, rtoks},
          route = Lookup[routeById, rid, <||>];
          rtoks = iSVPRRouteTokens[route];
          <|
            "RouteId" -> rid,
            "Kind"    -> "FunctionRoute",
            "Score"   -> N[cnt / Length[ptoks]],
            "Reasons" ->
              Map[("token:" <> #) &, Intersection[ptoks, rtoks]],
            "Route"   -> route
          |>]],
      hitCount];
    Reverse[SortBy[candidates, #["Score"] &]]
  ];
iSVPRLexicalSearch[_, _] := {};



(* ============================================================
   Order 5a: PromptRoute registry write API.

   SourceVaultRegisterPromptRoute / SourceVaultListPromptRoutes /
   SourceVaultGetPromptRoute let the deterministic FunctionRoute
   registry grow beyond the built-in seed routes.

   Writes follow ClaudeDirective rule 103 / spec 10.4:
   - DryRun -> True is the DEFAULT for the write API; a dry run
     reports the planned topic, RouteId and action and writes
     nothing.
   - the compiled registry is rewritten atomically: encode, verify
     the JSON round-trips, write to path.tmp, then rename over the
     target (the existing file is removed first for Windows).
   - iSanitizeForJSON is used for encoding; iLoadRegistryEntries
     (ReadByteArray path) for reading.
   - return values carry WrittenCount / SkippedCount / ByAction /
     Topic / Channel / Path aggregates.
   - retirement uses a non-destructive LifecycleStatus mark rather
     than physical deletion (handled by callers; this layer never
     deletes route entries).

   This section is all-ASCII (rule 30 / trap #11).
   ============================================================ *)

iSVPRPromptRouteRegistryPath[channel_String] :=
  iCompiledPath["prompt-route-registry", channel];

(* default privacy metadata for a route lacking one (spec 11.1) *)
iSVPRDefaultRoutePrivacy[] :=
  <|
    "PrivacyLevel"        -> 0.0,
    "PrivacyOrigin"       -> {},
    "AllowedTrustDomains" -> Automatic,
    "CloudFallback"       -> "NeedsApproval",
    "RawPromptStored"     -> False,
    "PromptStorageClass"  -> "HashOnly"
  |>;

(* atomic registry write (spec 10.4): encode -> verify -> tmp ->
   Windows-safe rename. A single flat Module so that any early
   Return exits this helper, never a nested scope. *)
iSVPRAtomicWriteRegistry[path_String, entries_List] :=
  Module[{sanitized, json, verify, tmp, strm, renamed},
    sanitized = Map[iSanitizeForJSON, entries];
    json = Quiet @ Check[
      ExportString[sanitized, "RawJSON", "Compact" -> False],
      $Failed];
    If[!StringQ[json],
      Return[<|"Status" -> "Failed",
        "Reason" -> "JSONEncodeFailed", "Path" -> path|>]];
    verify = Quiet @ Check[ImportString[json, "RawJSON"], $Failed];
    If[!ListQ[verify],
      Return[<|"Status" -> "Failed",
        "Reason" -> "JSONVerifyFailed", "Path" -> path|>]];
    tmp = path <> ".tmp";
    iEnsureDir[DirectoryName[path]];
    strm = Quiet[OpenWrite[tmp, BinaryFormat -> True]];
    If[Head[strm] =!= OutputStream,
      Return[<|"Status" -> "Failed",
        "Reason" -> "OpenTmpFailed", "Path" -> path|>]];
    BinaryWrite[strm, StringToByteArray[json, "UTF-8"]];
    (* UTF-8 to stay consistent with the iLoadRegistryEntries
       read path; ISO8859-1 corrupts non-ASCII route keywords. *)
    Close[strm];
    (* Windows-safe rename: remove the existing target first *)
    If[FileExistsQ[path], Quiet[DeleteFile[path]]];
    renamed = Quiet @ Check[RenameFile[tmp, path], $Failed];
    If[renamed === $Failed,
      Quiet[DeleteFile[tmp]];
      Return[<|"Status" -> "Failed",
        "Reason" -> "RenameFailed", "Path" -> path|>]];
    <|"Status" -> "OK", "Path" -> path,
      "Count" -> Length[entries]|>
  ];

Options[SourceVaultRegisterPromptRoute] = {
  "DryRun"  -> True,
  "Confirm" -> False,
  "Channel" -> "public"
};

SourceVaultRegisterPromptRoute[route_Association,
                               opts:OptionsPattern[]] :=
  Module[{dryRun, channel, rid, routeWithPrivacy, path, existing,
          pos, action, newEntries, writeResult},
    dryRun  = TrueQ[OptionValue[
      SourceVaultRegisterPromptRoute, {opts}, "DryRun"]];
    channel = OptionValue[
      SourceVaultRegisterPromptRoute, {opts}, "Channel"];
    If[!StringQ[channel], channel = "public"];

    (* validate the route *)
    If[!StringQ[Lookup[route, "RouteId", Null]] ||
       Lookup[route, "Type", ""] =!= "PromptRoute" ||
       !AssociationQ[Lookup[route, "Matcher", Null]] ||
       !AssociationQ[Lookup[route, "Target", Null]],
      Return[<|"Status" -> "Failed",
        "Reason" -> "InvalidRoute",
        "Hint" ->
          "route needs Type PromptRoute, a String RouteId, and " <>
          "Association Matcher and Target."|>]];
    rid = route["RouteId"];

    (* ensure privacy metadata (spec 11.1) *)
    routeWithPrivacy = If[
      AssociationQ[Lookup[route, "Privacy", Null]],
      route,
      Append[route, "Privacy" -> iSVPRDefaultRoutePrivacy[]]];

    (* load the current channel registry *)
    path = iSVPRPromptRouteRegistryPath[channel];
    existing = If[FileExistsQ[path],
      Quiet @ Check[iLoadRegistryEntries[path], {}], {}];
    If[!ListQ[existing], existing = {}];
    existing = Select[existing, AssociationQ];

    (* added vs replaced *)
    pos = FirstPosition[existing,
      _?(Lookup[#, "RouteId", Null] === rid &), Missing[]];
    action = If[MissingQ[pos], "Added", "Replaced"];
    newEntries = If[action === "Replaced",
      ReplacePart[existing, First[pos] -> routeWithPrivacy],
      Append[existing, routeWithPrivacy]];

    (* DryRun (default): report the plan, write nothing *)
    If[dryRun,
      Return[<|
        "Status"        -> "DryRun",
        "Topic"         -> "prompt-route-registry",
        "Channel"       -> channel,
        "Path"          -> path,
        "ByAction"      -> <|action -> 1|>,
        "WrittenCount"  -> 0,
        "SkippedCount"  -> 0,
        "PlannedRouteId"-> rid,
        "PlannedAction" -> action,
        "ResultingCount"-> Length[newEntries]|>]];

    (* real write *)
    writeResult = iSVPRAtomicWriteRegistry[path, newEntries];
    If[Lookup[writeResult, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[writeResult, "Reason", "WriteFailed"],
        "Topic" -> "prompt-route-registry",
        "Channel" -> channel, "Path" -> path|>]];

    <|
      "Status"        -> "OK",
      "Topic"         -> "prompt-route-registry",
      "Channel"       -> channel,
      "Path"          -> path,
      "ByAction"      -> <|action -> 1|>,
      "WrittenCount"  -> 1,
      "SkippedCount"  -> 0,
      "RouteId"       -> rid,
      "Action"        -> action,
      "ResultingCount"-> Length[newEntries]
    |>
  ];

SourceVaultRegisterPromptRoute[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" ->
      "Expected SourceVaultRegisterPromptRoute[route_Association, opts]."|>;

Options[SourceVaultListPromptRoutes] = {
  "Channel"     -> "public",
  "IncludeSeed" -> True
};

SourceVaultListPromptRoutes[opts:OptionsPattern[]] :=
  Module[{channel, includeSeed, path, registryRoutes,
          seed, regIds},
    channel = OptionValue[
      SourceVaultListPromptRoutes, {opts}, "Channel"];
    includeSeed = TrueQ[OptionValue[
      SourceVaultListPromptRoutes, {opts}, "IncludeSeed"]];
    If[!StringQ[channel], channel = "public"];

    path = iSVPRPromptRouteRegistryPath[channel];
    registryRoutes = If[FileExistsQ[path],
      Quiet @ Check[iLoadRegistryEntries[path], {}], {}];
    If[!ListQ[registryRoutes], registryRoutes = {}];
    registryRoutes = Select[registryRoutes, AssociationQ];

    If[includeSeed,
      seed   = iSVPRSeedPromptRoutes[];
      (* registryRoutes is a LIST of Associations: map Lookup
       over it. Lookup[list, key] would mis-read the list as
       a rule-list and raise Lookup::invrl. *)
    regIds = Map[Lookup[#, "RouteId", Null] &, registryRoutes];
      Join[registryRoutes,
        Select[seed,
          Function[sr,
            !MemberQ[regIds, Lookup[sr, "RouteId", Null]]]]],
      registryRoutes]
  ];

SourceVaultListPromptRoutes[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" -> "Expected SourceVaultListPromptRoutes[opts]."|>;

Options[SourceVaultGetPromptRoute] =
  Options[SourceVaultListPromptRoutes];

SourceVaultGetPromptRoute[routeId_String,
                          opts:OptionsPattern[]] :=
  Module[{routes, hit},
    routes = SourceVaultListPromptRoutes[opts];
    If[!ListQ[routes],
      Return[<|"Status" -> "Failed",
        "Reason" -> "ListFailed", "RouteId" -> routeId|>]];
    hit = SelectFirst[routes,
      Lookup[#, "RouteId", Null] === routeId &,
      Missing["NotFound"]];
    If[MissingQ[hit],
      <|"Status" -> "NotFound", "RouteId" -> routeId|>,
      hit]
  ];

SourceVaultGetPromptRoute[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" ->
      "Expected SourceVaultGetPromptRoute[routeId_String, opts]."|>;


(* ============================================================
   Order 5b: prompt capture and PromptRun promotion.

   SourceVaultCaptureLastPromptRun returns the most recent
   PromptRun from the append-only JSONL history (Order 1).

   SourceVaultPromotePromptRun classifies a recorded run per
   spec 10.3 and, conservatively, promotes only ReadOnly
   deterministic routes:

     deterministic route hit   -> PromptExample: the run's
                                  PromptHash (and raw prompt, if
                                  stored) strengthen the existing
                                  route's Matcher.
     ClaudeOrchestrator trace   -> WorkflowRouteDraft: classified
                                  only, NOT auto-promoted here.
     LLM one-shot / no route    -> NeedsReview: not promoted.

   Promotion writes go through the Order 5a registry API, so
   DryRun -> True is the default and the atomic-write / rule 103
   guarantees are inherited. This section is all-ASCII.
   ============================================================ *)

Options[SourceVaultCaptureLastPromptRun] = {};

SourceVaultCaptureLastPromptRun[opts:OptionsPattern[]] :=
  Module[{hist},
    hist = Quiet @ Check[SourceVaultPromptRunHistory[], {}];
    If[!ListQ[hist] || Length[hist] === 0,
      Return[<|"Status" -> "NoPromptRun",
        "Reason" -> "PromptRunHistoryEmpty"|>]];
    (* history is newest-first (Order 1), so First is the last run *)
    <|"Status" -> "OK", "PromptRun" -> First[hist]|>
  ];

SourceVaultCaptureLastPromptRun[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" -> "Expected SourceVaultCaptureLastPromptRun[opts]."|>;

Options[SourceVaultPromotePromptRun] = {
  "DryRun"  -> True,
  "Confirm" -> False,
  "Channel" -> "public"
};

SourceVaultPromotePromptRun[runId_String,
                            opts:OptionsPattern[]] :=
  Module[{dryRun, channel, hist, run, route, routeId, decision,
          wfTemplate, classification, existingRoute, matcher,
          promptHash, rawPrompt, fps, examples, updatedRoute,
          regResult},
    dryRun  = TrueQ[OptionValue[
      SourceVaultPromotePromptRun, {opts}, "DryRun"]];
    channel = OptionValue[
      SourceVaultPromotePromptRun, {opts}, "Channel"];
    If[!StringQ[channel], channel = "public"];

    (* locate the PromptRun in the history *)
    hist = Quiet @ Check[SourceVaultPromptRunHistory[], {}];
    If[!ListQ[hist], hist = {}];
    run = SelectFirst[hist,
      Lookup[#, "RunId", Null] === runId &, Missing["NotFound"]];
    If[MissingQ[run],
      Return[<|"Status" -> "Failed",
        "Reason" -> "RunNotFound", "RunId" -> runId|>]];

    (* classify per spec 10.3 *)
    route      = Lookup[run, "Route", <||>];
    routeId    = Lookup[route, "RouteId", Null];
    decision   = Lookup[route, "Decision", ""];
    wfTemplate = Lookup[
      Lookup[run, "Dependencies", <||>],
      "WorkflowTemplate", Missing["None"]];

    classification = Which[
      StringQ[routeId] &&
        MemberQ[{"DeterministicMatch", "LexicalMatch"}, decision],
        "PromptExample",
      StringQ[wfTemplate],
        "WorkflowRouteDraft",
      True,
        "NeedsReview"
    ];

    (* conservative: only deterministic ReadOnly routes promote *)
    If[classification =!= "PromptExample",
      Return[<|
        "Status"         -> "NotPromoted",
        "Classification" -> classification,
        "Reason"         -> If[
          classification === "WorkflowRouteDraft",
          "WorkflowTraceNeedsDraftReview",
          "NoDeterministicRouteToPromote"],
        "RunId"          -> runId|>]];

    (* fetch the route this run used *)
    existingRoute = SourceVaultGetPromptRoute[
      routeId, "Channel" -> channel];
    If[!AssociationQ[existingRoute] ||
       Lookup[existingRoute, "Status", ""] === "NotFound",
      Return[<|"Status" -> "Failed",
        "Reason" -> "RouteNotFound",
        "RouteId" -> routeId, "RunId" -> runId|>]];

    (* strengthen the Matcher: add the fingerprint, and the raw
       prompt as an Example when it was actually stored *)
    matcher    = Lookup[existingRoute, "Matcher", <||>];
    promptHash = Lookup[run, "PromptHash", Missing[]];
    rawPrompt  = Lookup[run, "RawPrompt", Missing[]];

    fps = Lookup[matcher, "PromptFingerprints", {}];
    If[!ListQ[fps], fps = {}];
    If[StringQ[promptHash],
      fps = DeleteDuplicates[Append[fps, promptHash]]];

    examples = Lookup[matcher, "Examples", {}];
    If[!ListQ[examples], examples = {}];
    If[StringQ[rawPrompt],
      examples = DeleteDuplicates[Append[examples, rawPrompt]]];

    updatedRoute = Append[existingRoute,
      "Matcher" -> Append[matcher,
        <|"PromptFingerprints" -> fps,
          "Examples"           -> examples|>]];

    (* DryRun (default): report the promotion plan *)
    If[dryRun,
      Return[<|
        "Status"             -> "DryRun",
        "Classification"     -> "PromptExample",
        "RunId"              -> runId,
        "RouteId"            -> routeId,
        "Channel"            -> channel,
        "PlannedAction"      -> "AddPromptExampleToRoute",
        "FingerprintCount"   -> Length[fps],
        "ExampleCount"       -> Length[examples],
        "RawExampleAvailable"-> StringQ[rawPrompt]|>]];

    (* real promotion: register the strengthened route (Order 5a) *)
    regResult = SourceVaultRegisterPromptRoute[
      updatedRoute, "DryRun" -> False, "Channel" -> channel];
    If[Lookup[regResult, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[regResult, "Reason", "RegisterFailed"],
        "RouteId" -> routeId, "RunId" -> runId|>]];

    <|
      "Status"          -> "OK",
      "Classification"  -> "PromptExample",
      "RunId"           -> runId,
      "RouteId"         -> routeId,
      "Channel"         -> channel,
      "Action"          -> "PromptExampleAdded",
      "FingerprintCount"-> Length[fps],
      "ExampleCount"    -> Length[examples],
      "RegisterAction"  -> Lookup[regResult, "Action", "?"]
    |>
  ];

SourceVaultPromotePromptRun[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" ->
      "Expected SourceVaultPromotePromptRun[runId_String, opts]."|>;


(* ============================================================
   Order 6a: prompt privacy propagation.

   SourceVaultResolvePromptPrivacy combines the privacy
   contributions of a prompt (cell, prompt text, notebook
   dependencies, model execution floor, result, user override)
   into a single PrivacyLevel and the associated trust-domain /
   cloud-fallback metadata (spec 11.2 - 11.5).

   Decision rule (spec 11.2): the level is the Max of every
   contributing component. A secret cell (spec 11.3) or a
   private/local model execution (spec 11.4) raises the level to
   at least 0.75, restricts AllowedTrustDomains to Local/Private,
   and sets CloudFallback to Deny.

   The 0.5 boundary (spec 11.5) is the cloud-send threshold, not
   a stored privacy value: at PrivacyLevel >= 0.5 only exact /
   deterministic matching and a private/local router are allowed,
   and the cloud lightweight router must not be used.

   This section is all-ASCII. Raw prompts are never stored by
   this layer; raw storage stays an explicit, separate user opt.
   ============================================================ *)

(* spec 11.2: numeric contributions, missing treated as 0.0 *)
iSVPRPrivacyComponentKeys[] := {
  "PromptCellPrivacyLevel",
  "PromptTextPrivacyLevel",
  "NotebookDependencyPrivacyLevel",
  "ModelExecutionPrivacyFloor",
  "ResultPrivacyLevel",
  "UserSpecifiedPrivacyLevel"
};

iSVPRResolvePrivacyLevel[components_Association] :=
  Module[{vals},
    vals = Map[
      Function[key,
        With[{v = Lookup[components, key, 0.0]},
          If[NumericQ[v], N[v], 0.0]]],
      iSVPRPrivacyComponentKeys[]];
    Max[Append[vals, 0.0]]
  ];
iSVPRResolvePrivacyLevel[_] := 0.0;

Options[SourceVaultResolvePromptPrivacy] = {};

SourceVaultResolvePromptPrivacy[components_Association,
                                opts:OptionsPattern[]] :=
  Module[{level, secretCell, privateModel, origins,
          allowedDomains, cloudFallback, cloudRouterOK},
    level        = iSVPRResolvePrivacyLevel[components];
    secretCell   = TrueQ[Lookup[components, "SecretCell", False]];
    privateModel = TrueQ[
      Lookup[components, "PrivateModelExecution", False]];

    (* spec 11.3 / 11.4: secret cell or private model -> >= 0.75 *)
    If[secretCell || privateModel, level = Max[level, 0.75]];

    origins = {};
    If[secretCell,
      origins = Append[origins, "SecretCell"]];
    If[privateModel,
      origins = Append[origins, "PrivateModelExecution"]];

    (* spec 11.5: 0.5 is the cloud-send boundary *)
    cloudRouterOK  = (level < 0.5);
    allowedDomains = If[level >= 0.5,
      {"Local", "Private"}, Automatic];
    cloudFallback  = If[level >= 0.5, "Deny", "Ask"];

    <|
      "Type"                -> "PromptPrivacyResolution",
      "PrivacyLevel"        -> level,
      "PrivacyOrigin"       -> origins,
      "AllowedTrustDomains" -> allowedDomains,
      "CloudFallback"       -> cloudFallback,
      "RawPromptStored"     -> False,
      "PromptStorageClass"  -> "HashOnly",
      "CloudRouterAllowed"  -> cloudRouterOK,
      "RouterVersion"       -> $SourceVaultPromptRouterVersion
    |>
  ];

SourceVaultResolvePromptPrivacy[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" ->
      "Expected SourceVaultResolvePromptPrivacy[components_Association, opts]."|>;

(* spec 11.5: cloud lightweight router is allowed only below the
   0.5 boundary. Anything non-numeric is treated as unsafe -> no. *)
SourceVaultPromptPrivacyAllowsCloudRouter[level_?NumericQ] :=
  (N[level] < 0.5);

SourceVaultPromptPrivacyAllowsCloudRouter[
  res_Association] :=
  With[{lv = Lookup[res, "PrivacyLevel", Missing[]]},
    If[NumericQ[lv], N[lv] < 0.5, False]];

SourceVaultPromptPrivacyAllowsCloudRouter[_] := False;


(* ============================================================
   Order 6b: model resolver contract wrapper.

   PromptRoutes carry a model INTENT, never a concrete model
   name (spec 12.1). SourceVaultResolveModelForPromptRouter is
   the thin contract layer between the router and whatever model
   resolver the host environment provides.

   Per spec 12.1.1 the wrapper:
   - normalises the query to the full contract (ModelIntent,
     WeightClass, PrivacyLevel, AllowedTrustDomains,
     CloudFallback, RequiredCapabilities, DegradationPolicy);
   - weak-calls SourceVault`SourceVaultResolve["Model", query]
     only when that symbol actually exists, so the router still
     loads in environments without a resolver;
   - when no resolver is available, or the resolver result is
     empty / unclassifiable, returns NeedsModelClassification
     rather than guessing;
   - per spec 12.4 / 12.1.1-4, at PrivacyLevel >= 0.5 a model
     that cannot be confirmed Local or Private is NOT used as a
     cloud fallback: the wrapper returns NeedsPrivateModel.

   The result mirrors the PromptRun ModelResolution shape
   (Requested / Resolved / FallbackKind / CloudFallbackUsed) so
   it can be recorded directly. This section is all-ASCII.
   ============================================================ *)

(* fill the spec 12.1 contract with defaults *)
iSVPRNormalizeModelQuery[query_Association] :=
  Module[{priv},
    priv = Lookup[query, "PrivacyLevel", 0.0];
    If[!NumericQ[priv], priv = 0.0];
    <|
      "ModelIntent"          ->
        Lookup[query, "ModelIntent", "router"],
      "WeightClass"          ->
        Lookup[query, "WeightClass", Automatic],
      "PrivacyLevel"         -> N[priv],
      "AllowedTrustDomains"  ->
        Lookup[query, "AllowedTrustDomains", Automatic],
      "CloudFallback"        ->
        Lookup[query, "CloudFallback", "Ask"],
      "RequiredCapabilities" ->
        Lookup[query, "RequiredCapabilities",
          {"TextIn", "TextOut"}],
      "DegradationPolicy"    ->
        Lookup[query, "DegradationPolicy", "Flexible"]
    |>
  ];
iSVPRNormalizeModelQuery[_] := iSVPRNormalizeModelQuery[<||>];

Options[SourceVaultResolveModelForPromptRouter] = {};

SourceVaultResolveModelForPromptRouter[query_Association,
                                       opts:OptionsPattern[]] :=
  Module[{nq, privLevel, resolverAvailable, raw,
          resolvedDomain, cloudUsed},
    (* spec 12.1: a String ModelIntent is required *)
    If[!StringQ[Lookup[query, "ModelIntent", Null]],
      Return[<|"Status" -> "Failed",
        "Reason" -> "MissingModelIntent",
        "Hint" ->
          "query needs a String ModelIntent (spec 12.1)."|>]];

    nq        = iSVPRNormalizeModelQuery[query];
    privLevel = nq["PrivacyLevel"];

    (* weak resolver availability check *)
    resolverAvailable =
      (Names["SourceVault`SourceVaultResolve"] =!= {});
    If[!resolverAvailable,
      Return[<|
        "Status"    -> "NeedsModelClassification",
        "Reason"    -> "NoModelResolverAvailable",
        "Requested" -> nq,
        "RouterVersion" -> $SourceVaultPromptRouterVersion|>]];

    (* delegate the actual model choice to the host resolver *)
    raw = Quiet @ Check[
      Symbol["SourceVault`SourceVaultResolve"]["Model", nq],
      $Failed];

    If[raw === $Failed || raw === Null || MissingQ[raw],
      Return[<|
        "Status"    -> "NeedsModelClassification",
        "Reason"    -> "ResolverEmptyOrFailed",
        "Requested" -> nq,
        "RouterVersion" -> $SourceVaultPromptRouterVersion|>]];

    (* spec 12.4 / 12.1.1-4: at PrivacyLevel >= 0.5 a model that
       cannot be confirmed Local/Private must not be used *)
    resolvedDomain = If[AssociationQ[raw],
      Lookup[raw, "TrustDomain", Missing["Unknown"]],
      Missing["Unknown"]];

    If[privLevel >= 0.5 &&
       !MemberQ[{"Local", "Private"}, resolvedDomain],
      Return[<|
        "Status"         -> "NeedsPrivateModel",
        "Reason"         -> "PrivacyFloorBlocksUnconfirmedModel",
        "Requested"      -> nq,
        "ResolvedDomain" -> resolvedDomain,
        "RouterVersion"  -> $SourceVaultPromptRouterVersion|>]];

    cloudUsed = (resolvedDomain === "Cloud");

    <|
      "Status"            -> "Resolved",
      "Requested"         -> nq,
      "Resolved"          -> raw,
      "FallbackKind"      -> If[AssociationQ[raw],
        Lookup[raw, "FallbackKind", Missing["DelegatedToResolver"]],
        Missing["DelegatedToResolver"]],
      "CloudFallbackUsed" -> cloudUsed,
      "RouterVersion"     -> $SourceVaultPromptRouterVersion
    |>
  ];

SourceVaultResolveModelForPromptRouter[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" ->
      "Expected SourceVaultResolveModelForPromptRouter[query_Association, opts]."|>;


(* ============================================================
   Order 11: PromptRouter reprocessing plan.

   SourceVaultPromptReprocessPlan scans the PromptRoute registry
   for routes that have gone stale and produces a reprocessing
   plan (spec 14.2 / 14.3). It does NOT itself reprocess anything
   -- it builds the plan a reprocess driver would consume, and is
   read-only.

   A route is stale (spec 14.1 version metadata) when any of:
   - its SchemaVersion differs from the current schema version;
   - its CompiledRegistryVersion differs from the registry
     version the router currently produces;
   - the caller passes a StaleRouteIds list naming it directly
     (e.g. routes whose SourceSnapshotIds were invalidated by
     SourceVaultRefreshSnapshot upstream).

   Each stale route is classified by spec 14.3 policy:
   - a FunctionRoute targeting a ReadOnly callable ->
     "AutoRecomputable" (safe to recompute on next ClaudeEval);
   - an Intent route -> "OnDemandRefresh";
   - a WorkflowRoute / WorkflowTemplate target ->
     "NeedsApproval" (side effects, multiple candidates).

   Per spec 14.3 immediate auto-reprocessing is never the
   default: the plan is just a queue. This section is all-ASCII.
   ============================================================ *)

(* the schema / registry versions the current router produces *)
iSVPRCurrentSchemaVersion[]   := 1;
iSVPRCurrentRegistryVersion[] := 1;

(* classify one stale route by spec 14.3 policy *)
iSVPRReprocessPolicy[route_Association] :=
  Module[{target, kind, callable},
    target = Lookup[route, "Target", <||>];
    kind   = Lookup[target, "Kind", "Function"];
    Which[
      kind === "WorkflowTemplate" || kind === "Workflow",
        <|"Policy" -> "NeedsApproval",
          "Reason" -> "WorkflowSideEffectsNeedApproval"|>,
      kind === "Intent",
        <|"Policy" -> "OnDemandRefresh",
          "Reason" -> "IntentRouteRefreshedOnDemand"|>,
      kind === "TabularQuery",
        <|"Policy" -> "OnDemandRefresh",
          "Reason" -> "TabularQueryRouteRefreshedOnDemand"|>,
      kind === "Function",
        callable = If[
          Names["SourceVault`SourceVaultCallableAllowlistRegistry"] =!= {},
          iSVPRResolveCallable[
            Lookup[target, "FunctionId", ""]],
          Missing["NoAllowlist"]];
        If[AssociationQ[callable] &&
           Lookup[callable, "SideEffectClass", "Unknown"] ===
             "ReadOnly",
          <|"Policy" -> "AutoRecomputable",
            "Reason" -> "ReadOnlyDeterministicRoute"|>,
          <|"Policy" -> "NeedsApproval",
            "Reason" -> "NonReadOnlyOrUnknownCallable"|>],
      True,
        <|"Policy" -> "NeedsApproval",
          "Reason" -> "UnknownTargetKind"|>
    ]
  ];
iSVPRReprocessPolicy[_] :=
  <|"Policy" -> "NeedsApproval", "Reason" -> "BadRoute"|>;

(* is a route stale? returns {staleQ, reasons} *)
iSVPRRouteStaleQ[route_Association, staleIds_List] :=
  Module[{reasons, rid, schemaV, regV},
    reasons = {};
    rid     = Lookup[route, "RouteId", Null];
    schemaV = Lookup[route, "SchemaVersion", Missing[]];
    regV    = Lookup[route, "CompiledRegistryVersion", Missing[]];

    If[StringQ[rid] && MemberQ[staleIds, rid],
      AppendTo[reasons, "ExplicitlyMarkedStale"]];
    If[IntegerQ[schemaV] &&
       schemaV =!= iSVPRCurrentSchemaVersion[],
      AppendTo[reasons, "SchemaVersionMismatch"]];
    If[IntegerQ[regV] &&
       regV =!= iSVPRCurrentRegistryVersion[],
      AppendTo[reasons, "RegistryVersionMismatch"]];

    {reasons =!= {}, reasons}
  ];
iSVPRRouteStaleQ[_, _] := {False, {}};

Options[SourceVaultPromptReprocessPlan] = {
  "Channel"      -> "public",
  "StaleRouteIds"-> {}
};

SourceVaultPromptReprocessPlan[opts:OptionsPattern[]] :=
  Module[{channel, staleIds, routes, items, byPolicy},
    channel = OptionValue[
      SourceVaultPromptReprocessPlan, {opts}, "Channel"];
    If[!StringQ[channel], channel = "public"];
    staleIds = OptionValue[
      SourceVaultPromptReprocessPlan, {opts}, "StaleRouteIds"];
    If[!ListQ[staleIds], staleIds = {}];

    routes = SourceVaultListPromptRoutes[
      "Channel" -> channel, "IncludeSeed" -> True];
    If[!ListQ[routes], routes = {}];

    (* one plan item per stale route *)
    items = Map[
      Function[route,
        Module[{stale, policy},
          stale = iSVPRRouteStaleQ[route, staleIds];
          If[!First[stale], Nothing,
            policy = iSVPRReprocessPolicy[route];
            <|
              "RouteId"      -> Lookup[route, "RouteId", "?"],
              "StaleReasons" -> Last[stale],
              "Policy"       -> policy["Policy"],
              "PolicyReason" -> policy["Reason"]
            |>]]],
      Select[routes, AssociationQ]];
    items = DeleteCases[items, Nothing];

    byPolicy = Counts[
      Map[Lookup[#, "Policy", "?"] &, items]];

    <|
      "Type"             -> "PromptReprocessPlan",
      "Channel"          -> channel,
      "StaleRouteCount"  -> Length[items],
      "Items"            -> items,
      "ByPolicy"         -> byPolicy,
      "AutoRecomputable" ->
        Count[items, _?(#["Policy"] === "AutoRecomputable" &)],
      "NeedsApproval"    ->
        Count[items, _?(#["Policy"] === "NeedsApproval" &)],
      "RouterVersion"    -> $SourceVaultPromptRouterVersion
    |>
  ];

SourceVaultPromptReprocessPlan[___] :=
  <|"Type" -> "PromptReprocessPlan",
    "Status" -> "Failed",
    "Reason" -> "InvalidArguments",
    "Hint" ->
      "Expected SourceVaultPromptReprocessPlan[opts]."|>;



(* ============================================================
   TabularQuery / schedule proposal (spec v11 5.3 / 5.4 / 6.1).

   This section replaces the earlier Order T1-T6 implementation,
   which violated spec 5.2: it executed routes and returned
   evaluated Grids / Associations to ClaudeEval. Per spec 5.2
   ClaudeEval must receive an UNEVALUATED Mathematica
   expression, so the PromptRouter here only BUILDS a proposal
   expression -- it never runs it.

   For a schedule prompt the proposal is

     HoldComplete[
       SourceVaultUpcomingSchedule[
         "Scope" -> $onWork,
         "Period" -> Quantity[n, "Days"],
         "Refresh" -> "Never",
         "FallbackToCloud" -> "Deny",
         "FilterSpec" -> <|... closed-DSL predicate ...|>  (* optional *)
       ]
     ]

   The date span of the prompt ("today + 3 days", "this month")
   becomes the Period option (spec 5.4.1); any other narrowing
   ("open todos remain", "deadline this week") becomes a
   FilterSpec literal Association (spec 5.4.2). The FilterSpec
   DSL is the closed grammar of spec 5.4.3 -- Kind And/Or/Not/
   Field, a whitelisted Op set, schema field names only, no
   Function / Slot / arbitrary code. SourceVaultUpcomingSchedule
   itself owns the predicate engine and the decorated Grid
   formatting (Title links, tooltips, date styling); the
   PromptRouter never re-implements display.

   SourceVaultProposePromptRoute is the ClaudeEval-facing API:
   it returns a PromptRouteProposal diagnostic Association whose
   "ProposedExpression" field holds the HoldComplete expression.
   The ClaudeEval bridge passes ONLY that field to the Runtime.
   SourceVaultExecutePromptRoute stays as the manual / test /
   diagnostics API and may evaluate.

   This section is all-ASCII; Japanese cue words are \:XXXX
   literals (rule 30 / trap #11).
   ============================================================ *)

(* ----- schedule field schema (spec 5.4.3 field allowlist) -----
   The schema is the closed set of field names a FilterSpec may
   reference, with their value types and an English/Japanese
   alias dictionary. SourceVaultUpcomingSchedule's predicate
   engine accepts these field names (and the *Count aliases). *)
iSVPRScheduleFieldSchema[] := <|
  "DataSource" -> "schedule",
  "Fields" -> {
    <|"Name" -> "Deadline", "Type" -> "Date",
      "Aliases" -> {"deadline", "\:7de0\:5207", "\:671f\:9650"}|>,
    <|"Name" -> "NextReview", "Type" -> "Date",
      "Aliases" -> {"nextreview", "next review",
        "\:30ec\:30d3\:30e5\:30fc", "\:898b\:76f4\:3057"}|>,
    <|"Name" -> "OpenTodoCount", "Type" -> "Integer",
      "Aliases" -> {"opentodos", "opentodocount",
        "\:672a\:5b8c\:4e86", "\:672a\:5b8c\:4e86todo"}|>,
    <|"Name" -> "DoneTodoCount", "Type" -> "Integer",
      "Aliases" -> {"donetodos", "donetodocount",
        "\:5b8c\:4e86", "\:5b8c\:4e86todo"}|>,
    <|"Name" -> "PassTodoCount", "Type" -> "Integer",
      "Aliases" -> {"passtodos", "passtodocount",
        "\:30d1\:30b9"}|>,
    <|"Name" -> "Status", "Type" -> "String",
      "Aliases" -> {"status", "\:72b6\:614b"}|>,
    <|"Name" -> "Title", "Type" -> "String",
      "Aliases" -> {"title", "\:30bf\:30a4\:30c8\:30eb",
        "\:984c\:540d"}|>,
    <|"Name" -> "Keywords", "Type" -> "StringList",
      "Aliases" -> {"keywords", "keyword",
        "\:30ad\:30fc\:30ef\:30fc\:30c9"}|>
  }
|>;

(* canonical field name for any alias (English/Japanese, any
   case), or Missing["UnknownField"] *)
iSVPRResolveScheduleField[word_String] :=
  Module[{target, hit},
    target = ToLowerCase[StringTrim[word]];
    hit = SelectFirst[iSVPRScheduleFieldSchema[]["Fields"],
      Function[f,
        MemberQ[
          Map[ToLowerCase,
            Prepend[Lookup[f, "Aliases", {}],
              Lookup[f, "Name", ""]]],
          target]],
      Missing["UnknownField"]];
    If[AssociationQ[hit], hit["Name"], hit]
  ];
iSVPRResolveScheduleField[_] := Missing["UnknownField"];

(* ----- prompt -> date span (Period option, spec 5.4.1) -----
   Returns an Association
     <|"PeriodDays" -> n|>            for a forward window, or
     <|"PeriodDays" -> n,
       "AnchorNote" -> "..."|>        with a note, or
     Missing["NoDateSpan"]            when the prompt names no
                                      date span at all.
   "today + N days", "N day(s)", "this week", "this month",
   "M/D" (today .. that day), "M month" are recognised. *)
iSVPRParsePeriodDays[prompt_String] :=
  Module[{today, mNdays, mDays, slash, mo, dy, monthN,
          dayCount},
    today = DateObject[Now, "Day"];

    (* "today + N days" : \:4eca\:65e5\:304b\:3089 N \:65e5\:9593 *)
    mNdays = StringCases[prompt,
      "\:4eca\:65e5\:304b\:3089" ~~ Whitespace ... ~~
        d : DigitCharacter .. ~~ Whitespace ... ~~
        "\:65e5\:9593" :> ToExpression[d], 1];
    If[mNdays =!= {} && IntegerQ[First[mNdays]],
      Return[<|"PeriodDays" -> First[mNdays]|>]];

    (* bare "N day(s)" : N \:65e5\:9593 / N \:65e5\:5206 *)
    mDays = StringCases[prompt,
      d : DigitCharacter .. ~~ Whitespace ... ~~
        ("\:65e5\:9593" | "\:65e5\:5206") :>
        ToExpression[d], 1];
    If[mDays =!= {} && IntegerQ[First[mDays]],
      Return[<|"PeriodDays" -> First[mDays]|>]];

    (* "this week" : \:4eca\:9031 *)
    If[StringContainsQ[prompt, "\:4eca\:9031"],
      Return[<|"PeriodDays" -> 7,
        "AnchorNote" -> "ThisWeek"|>]];

    (* "this month" : \:4eca\:6708 *)
    If[StringContainsQ[prompt, "\:4eca\:6708"],
      Return[<|"PeriodDays" -> 31,
        "AnchorNote" -> "ThisMonth"|>]];

    (* "M/D" : today .. that day inclusive *)
    slash = StringCases[prompt,
      d1 : DigitCharacter .. ~~ ("/" | "-") ~~
        d2 : DigitCharacter .. :>
        {ToExpression[d1], ToExpression[d2]}, 1];
    If[slash =!= {},
      {mo, dy} = First[slash];
      If[IntegerQ[mo] && IntegerQ[dy] &&
         1 <= mo <= 12 && 1 <= dy <= 31,
        Module[{namedDay, span},
          namedDay = Quiet @ Check[
            DateObject[{DateValue[today, "Year"], mo, dy},
              "Day"], $Failed];
          If[Head[namedDay] === DateObject,
            span = Round[
              (AbsoluteTime[namedDay] -
               AbsoluteTime[today]) / 86400] + 1;
            Return[<|"PeriodDays" -> Max[span, 1],
              "AnchorNote" -> "UpToNamedDay"|>]]]]];

    (* "M month" : \:6708 *)
    monthN = StringCases[prompt,
      d : DigitCharacter .. ~~ "\:6708" :>
        ToExpression[d], 1];
    If[monthN =!= {} && IntegerQ[First[monthN]] &&
       1 <= First[monthN] <= 12,
      Module[{first, daysToEnd},
        first = DateObject[{DateValue[today, "Year"],
          First[monthN], 1}, "Day"];
        daysToEnd = Round[
          (AbsoluteTime[DatePlus[first, {1, "Month"}]] -
           AbsoluteTime[today]) / 86400];
        Return[<|"PeriodDays" -> Max[daysToEnd, 1],
          "AnchorNote" -> "NamedMonth"|>]]];

    Missing["NoDateSpan"]
  ];
iSVPRParsePeriodDays[_] := Missing["NoDateSpan"];

(* ----- prompt -> FilterSpec (closed-DSL, spec 5.4.2/5.4.3) ---
   Non-date narrowing. Returns a FilterSpec Association, or
   Missing["NoFilter"] when the prompt asks for no narrowing.
   Recognised: "open todos remain", "N or more open todos",
   "done", "not done". *)
iSVPRParseFilterSpec[prompt_String] :=
  Module[{clauses, nOpen},
    clauses = {};

    (* "N or more" open todos : N \:4ef6\:4ee5\:4e0a / N \:4ee5\:4e0a *)
    nOpen = StringCases[prompt,
      d : DigitCharacter .. ~~ ("\:4ef6" | "") ~~
        "\:4ee5\:4e0a" :> ToExpression[d], 1];
    If[nOpen =!= {} && IntegerQ[First[nOpen]],
      AppendTo[clauses,
        <|"Kind" -> "Field", "Field" -> "OpenTodoCount",
          "Op" -> "GreaterEqual", "Value" -> First[nOpen]|>]];

    (* "open todos remain" -> OpenTodoCount > 0
       (only when no explicit count clause was added above).
       The open-todo concept may be named by "Todo" / "todo"
       or by the Japanese word for "incomplete" (\:672a\:5b8c\:4e86);
       paired with the Japanese for "remain" (\:6b8b) or
       "exists" (\:3042\:308b). *)
    If[nOpen === {} &&
       (StringContainsQ[prompt, "Todo"] ||
        StringContainsQ[prompt, "todo"] ||
        StringContainsQ[prompt, "TODO"] ||
        StringContainsQ[prompt, "\:672a\:5b8c\:4e86"]) &&
       (StringContainsQ[prompt, "\:6b8b"] ||
        StringContainsQ[prompt, "\:3042\:308b"]),
      AppendTo[clauses,
        <|"Kind" -> "Field", "Field" -> "OpenTodoCount",
          "Op" -> "Greater", "Value" -> 0|>]];

    (* "done" : \:5b8c\:4e86\:3057\:305f / \:5b8c\:4e86\:6e08 *)
    If[StringContainsQ[prompt, "\:5b8c\:4e86\:3057\:305f"] ||
       StringContainsQ[prompt, "\:5b8c\:4e86\:6e08"],
      AppendTo[clauses,
        <|"Kind" -> "Field", "Field" -> "Status",
          "Op" -> "Equal", "Value" -> "Done"|>]];

    Which[
      clauses === {}, Missing["NoFilter"],
      Length[clauses] === 1, First[clauses],
      True, <|"Kind" -> "And", "Clauses" -> clauses|>]
  ];
iSVPRParseFilterSpec[_] := Missing["NoFilter"];

(* ----- scope cue (spec example uses $onWork) -----
   Detects an $onWork hint; defaults to Automatic so
   SourceVaultUpcomingSchedule resolves the scope itself. *)
iSVPRParseScopeSymbol[prompt_String] :=
  If[StringContainsQ[prompt, "$onWork"] ||
     StringContainsQ[prompt, "\:4ed5\:4e8b"],
    "$onWork", Automatic];

(* ----- build the proposal expression (spec 5.4) -----
   Returns HoldComplete[ SourceVaultUpcomingSchedule[...] ].
   periodDays drives the Period option; filterSpec, when
   present, is embedded as a literal FilterSpec Association.
   The expression is built held so nothing evaluates here. *)
(* Build the held proposal expression. The function takes its
   arguments by VALUE (no Hold attribute): the period count and
   the FilterSpec Association are concrete data computed by the
   caller. With[] injects those values into the body so that
   HoldComplete then freezes a fully-formed, literal expression
   -- HoldComplete[SourceVaultUpcomingSchedule["Period" ->
   Quantity[3,"Days"], ...]] -- with no unbound local symbols.
   $onWork is intentionally left as a SYMBOL inside the held
   expression: it is resolved later, when the Runtime evaluates
   the proposal, not here. *)
iSVPRBuildScheduleProposal[periodDays_Integer,
                           filterSpec_, scopeSym_] :=
  With[{pd = periodDays, fs = filterSpec},
    If[fs === None || MissingQ[fs],
      If[scopeSym === "$onWork",
        HoldComplete[
          SourceVaultUpcomingSchedule[
            "Scope" -> $onWork,
            "Period" -> Quantity[pd, "Days"],
            "Refresh" -> "Never",
            "FallbackToCloud" -> "Deny"]],
        HoldComplete[
          SourceVaultUpcomingSchedule[
            "Scope" -> Automatic,
            "Period" -> Quantity[pd, "Days"],
            "Refresh" -> "Never",
            "FallbackToCloud" -> "Deny"]]],
      If[scopeSym === "$onWork",
        HoldComplete[
          SourceVaultUpcomingSchedule[
            "Scope" -> $onWork,
            "Period" -> Quantity[pd, "Days"],
            "Refresh" -> "Never",
            "FallbackToCloud" -> "Deny",
            "FilterSpec" -> fs]],
        HoldComplete[
          SourceVaultUpcomingSchedule[
            "Scope" -> Automatic,
            "Period" -> Quantity[pd, "Days"],
            "Refresh" -> "Never",
            "FallbackToCloud" -> "Deny",
            "FilterSpec" -> fs]]]]
  ];

(* validate that a FilterSpec only uses the closed DSL
   (spec 5.4.3). Returns True / False. *)
iSVPRValidateFilterSpec[spec_] :=
  Module[{okOps, walk},
    okOps = {"Equal", "NotEqual", "Greater", "GreaterEqual",
      "Less", "LessEqual", "Contains", "DateWithin",
      "NonEmpty"};
    walk[node_] := Which[
      !AssociationQ[node], False,
      Lookup[node, "Kind", Null] === "Field",
        StringQ[Lookup[node, "Field", Null]] &&
        StringQ[iSVPRResolveScheduleField[node["Field"]]] &&
        MemberQ[okOps, Lookup[node, "Op", Null]],
      MemberQ[{"And", "Or"}, Lookup[node, "Kind", Null]],
        ListQ[Lookup[node, "Clauses", Null]] &&
        node["Clauses"] =!= {} &&
        AllTrue[node["Clauses"], walk],
      Lookup[node, "Kind", Null] === "Not",
        AssociationQ[Lookup[node, "Clause", Null]] &&
        walk[node["Clause"]],
      True, False];
    walk[spec]
  ];

(* ----- public: SourceVaultProposePromptRoute (spec 5.3) -----
   The ClaudeEval-facing API. Resolves the prompt to a schedule
   proposal and returns a PromptRouteProposal diagnostic
   Association carrying the unevaluated ProposedExpression.
   It NEVER evaluates the expression. When the prompt is not a
   schedule request it returns Status NotDispatched so the
   ClaudeEval bridge falls back. *)
Options[SourceVaultProposePromptRoute] = {
  "Caller" -> "ClaudeEval"
};

SourceVaultProposePromptRoute[prompt_String,
                              opts:OptionsPattern[]] :=
  Module[{isSchedule, periodInfo, periodDays, filterSpec,
          scopeSym, proposal, anchorNote},
    (* only schedule prompts are handled by this builder *)
    isSchedule = StringContainsQ[prompt,
      "\:30b9\:30b1\:30b8\:30e5\:30fc\:30eb"] ||
      StringContainsQ[prompt, "\:4e88\:5b9a"] ||
      StringContainsQ[prompt, "schedule"];
    If[!isSchedule,
      Return[<|"Type" -> "PromptRouteProposal",
        "Status" -> "NotDispatched",
        "Reason" -> "NotASchedulePrompt",
        "Prompt" -> prompt|>]];

    (* date span -> Period (default 7 days when none stated) *)
    periodInfo = iSVPRParsePeriodDays[prompt];
    periodDays = If[AssociationQ[periodInfo],
      Lookup[periodInfo, "PeriodDays", 7], 7];
    anchorNote = If[AssociationQ[periodInfo],
      Lookup[periodInfo, "AnchorNote", None], None];
    If[!IntegerQ[periodDays] || periodDays < 1,
      periodDays = 7];

    (* non-date narrowing -> FilterSpec *)
    filterSpec = iSVPRParseFilterSpec[prompt];
    If[MissingQ[filterSpec], filterSpec = None];
    If[filterSpec =!= None &&
       !iSVPRValidateFilterSpec[filterSpec],
      (* a malformed internally-built FilterSpec is a bug;
         fail safe by dropping it rather than proposing it *)
      filterSpec = None];

    scopeSym = iSVPRParseScopeSymbol[prompt];

    proposal = iSVPRBuildScheduleProposal[
      periodDays, filterSpec, scopeSym];

    <|
      "Type"     -> "PromptRouteProposal",
      "Status"   -> "Proposed",
      "Prompt"   -> prompt,
      "Decision" -> <|
        "RouteId" -> "seed-sourcevault-upcoming-schedule-v1",
        "Method"  -> "DeterministicSchedule",
        "PeriodDays" -> periodDays,
        "AnchorNote" -> anchorNote,
        "HasFilterSpec" -> (filterSpec =!= None)|>,
      "ProposedExpression" -> proposal,
      "ValidationHints" -> <|
        "ExpectedHeads" -> {SourceVaultUpcomingSchedule},
        "SideEffectClass" -> "ReadOnly"|>,
      "RouterPhase"   -> iSVPRImplementationPhase[],
      "RouterVersion" -> $SourceVaultPromptRouterVersion
    |>
  ];
SourceVaultProposePromptRoute[___] :=
  <|"Type" -> "PromptRouteProposal",
    "Status" -> "Failed", "Reason" -> "InvalidArguments"|>;


End[];

EndPackage[];

