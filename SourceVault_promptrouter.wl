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
  "SourceVault`SourceVaultProposePromptRoute",
  "SourceVault`SourceVaultClassifyProviderTrustDomain",
  "SourceVault`SaveLastPrompt",
  "SourceVault`AddPromptMemo",
  "SourceVault`SourceVaultDecryptPromptRoute",
  "SourceVault`SourceVaultSearchPromptRoutes",
  "SourceVault`SourceVaultFormatPromptRouteList",
  "SourceVault`SourceVaultReplayRoute",
  "SourceVault`SourceVaultAutoSaveLastPrompt",
  "SourceVault`SourceVaultMatchSavedPromptVersions",
  "SourceVault`SourceVaultPrimaryPromptRoute",
  "SourceVault`SourceVaultSetPrimaryPromptRoute",
  "SourceVault`SourceVaultDeletePromptRoute",
  "SourceVault`SourceVaultRunPrimaryRoute",
  "SourceVault`SourceVaultPromptVersionsUI",
  "SourceVault`SourceVaultProposeSavedPromptRoute",
  "SourceVault`SourceVaultClassifyPromptReplaySafety",
  "SourceVault`SourceVaultClassifyPromptContextDependency",
  "SourceVault`SourceVaultUpdatePromptRouteMemo"
]];

(* ------------------------------------------------------------
   Saved-prompt feature flags (Order 9: prompt capture / versioning
   / primary auto-execute). These are NOT cleared on reload so a
   user's setting survives a repeated Get[]; they default once.
     $SourceVaultPromptAutoSave            -- auto-save every
       notebook ClaudeEval prompt as a new version (default True).
     $SourceVaultPromptSavedProposalActive -- let ClaudeEval consult
       saved prompts before the LLM call (default True).
     $SourceVaultPromptBypassOnce          -- one-shot normalized key
       that the saved-prompt proposer consumes and then ignores, so
       the "ask the LLM again" button can force the legacy path.
   ------------------------------------------------------------ *)

If[!ValueQ[SourceVault`$SourceVaultPromptAutoSave],
  SourceVault`$SourceVaultPromptAutoSave = True];
If[!ValueQ[SourceVault`$SourceVaultPromptSavedProposalActive],
  SourceVault`$SourceVaultPromptSavedProposalActive = True];
If[!ValueQ[SourceVault`$SourceVaultPromptBypassOnce],
  SourceVault`$SourceVaultPromptBypassOnce = Missing["None"]];

(* X1: when True (default), SourceVault registers a context planner into
   ClaudeCode`$ClaudeEvalContextPlanner that uses
   SourceVaultClassifyPromptContextDependency to refine the ClaudeEval
   ContextPlan per prompt. Set False to make the planner a no-op (the base
   package then falls back to its default plan) without reloading. *)
If[!ValueQ[SourceVault`$SourceVaultContextPlannerEnabled],
  SourceVault`$SourceVaultContextPlannerEnabled = True];

(* X0b-2 opt-in. When True the planner trims SELF-CONTAINED (no-marker) prompts
   to NO notebook context (Notebook "None"), not just the default bounded Tail.
   Helps light models stop imitating prior cells on trivial prompts, at the cost
   of possibly starving an unmarked notebook-dependent prompt. Default False
   (conservative). History is never trimmed by this flag. *)
If[!ValueQ[SourceVault`$SourceVaultContextPlannerTrimSelfContained],
  SourceVault`$SourceVaultContextPlannerTrimSelfContained = False];

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



(* ===================================================================
   Phase 2.2: provider trust-domain classification (spec 12)
   Classifies ChatGPT Codex as a cloud-backed CLI (TrustDomain Cloud)
   so that the existing PrivacyLevel >= 0.5 floor (spec 12.3) blocks
   automatic Codex selection for private prompts.
   =================================================================== *)

SourceVaultClassifyProviderTrustDomain::usage =
  "SourceVaultClassifyProviderTrustDomain[label] maps a provider or route label to a TrustDomain (spec 12.2). \"chatgptcodex\" / \"ChatGPTCodexCLI\" / \"ClaudeCodeCLI\" / \"CloudLLM\" classify as \"Cloud\"; \"LocalOnly\" as \"Local\"; \"PrivateLLM\" as \"Private\". Ambiguous or unknown labels (e.g. LocalOpenAICompatible, ExternalAPI) return Missing[\"UnclassifiedTrustDomain\"] so the host resolver must declare TrustDomain explicitly. ChatGPT Codex is a cloud-backed CLI: its filesystem sandbox is local but its LLM inference is in the cloud.";

SaveLastPrompt::usage =
  "SaveLastPrompt[memo_String] saves the most recent successful ClaudeEval / ContinueEval prompt run as a named PromptRoute so it can be searched and re-run later. memo is a free-text note (e.g. \"this function only works where an LLM is available\") stored in the route's Memo field and shown in the prompt table. Options: \"Channel\" -> \"public\"|\"private\"|\"local\" (default Automatic, resolved from privacy), \"Encrypt\" -> False; when True the raw prompt and TargetExprString are encrypted at rest via SourceVaultEncryptedPut (encrypt-then-MAC, keys via NBAccess) and embedded as an EncryptedPayload in the route, with Examples emptied and PromptStorageClass set to \"Encrypted\" (Memo is kept in plaintext as the display label). Requires the SourceVault encryption modules to be loaded and SourceVaultInitializeEncryption[] to have run. \"DryRun\" -> False, \"RouteId\" -> Automatic. Privacy is tracked via SourceVaultResolvePromptPrivacy; with Encrypt -> False the raw prompt/function are stored in plaintext, but PrivacyLevel and CloudFallback are recorded on the route. Use SourceVaultDecryptPromptRoute[route] to recover the plaintext from an encrypted route.";

AddPromptMemo::usage =
  "AddPromptMemo[memo_String] attaches a free-text memo to the most recent ClaudeEval / ContinueEval prompt. Because every run is already auto-captured as a versioned PromptRoute (SourceVaultAutoSaveLastPrompt), AddPromptMemo updates the Memo of that newest saved version IN PLACE via SourceVaultUpdatePromptRouteMemo - it does not create a redundant new version the way SaveLastPrompt does. The target prompt is resolved from the last run (override with \"PromptText\") and its newest version in the prompt group (override with \"RouteId\"). When no saved version exists yet - e.g. a HeavyLLM one-shot answer that auto-save intentionally skips - it falls back to SaveLastPrompt so the memo still gets a home. Returns <|\"Status\"->...,\"RouteId\"->...,\"Memo\"->...,\"Action\"->\"MemoUpdated\"|\"MemoSavedNewVersion\"|>. Options: \"PromptText\" -> Automatic, \"RouteId\" -> Automatic.";

SourceVaultDecryptPromptRoute::usage =
  "SourceVaultDecryptPromptRoute[route_Association] decrypts the EncryptedPayload of an encrypted PromptRoute (created via SaveLastPrompt with Encrypt -> True), returning <|\"Status\"->\"Ok\",\"Plaintext\"->...|> or an error association. MAC is verified before decryption; on failure no plaintext is returned.";

SourceVaultSearchPromptRoutes::usage =
  "SourceVaultSearchPromptRoutes[query_String, opts] returns saved PromptRoutes whose prompt examples or memo contain query as a substring (partial match, like SourceVaultFindNotebooks Keywords). query \"\" matches all. Options: \"CreatedAt\" -> <|\"From\"->_,\"To\"->_|> and \"UpdatedAt\" -> <|\"From\"->_,\"To\"->_|> filter by definition / last-updated date (same date-range form as the notebook query API); \"Channel\" -> All|\"public\"|\"private\"|\"local\"; \"IncludeSeed\" -> True. Returns a List of route Associations (does not execute anything).";

SourceVaultFormatPromptRouteList::usage =
  "SourceVaultFormatPromptRouteList[routes_List, opts] renders saved PromptRoutes as a Grid (columns: Prompt, Memo, Target, CreatedAt, UpdatedAt, Privacy) with three action buttons per row: Preview (dry-run, shows what would execute without running it), Run (executes the route now), and ToInput (writes the saved function-call expression into a new Input cell). Mirrors SourceVaultFormatNotebookList. The default display format for prompt-route lists requested in a prompt.";

SourceVaultReplayRoute::usage =
  "SourceVaultReplayRoute[route_Association, opts] \:306f\:4fdd\:5b58\:6e08\:307f PromptRoute \:3092\:518d\:5b9f\:884c\:30af\:30e9\:30b9\:306b\:5fdc\:3058\:3066\:518d\:69cb\:6210\:3057\:3001\:8a55\:4fa1\:7528\:306e\:5f0f\:6587\:5b57\:5217\:3092\:8fd4\:3059\:3002Replayable \:306f TargetExprString \:3092\:305d\:306e\:307e\:307e\:8fd4\:3059\:3002LightLLM \:306f \\\"NewPrompt\\\" \:7121\:3057\:306a\:3089\:5143\:306e TargetExprString \:3092\:5fa9\:5143\:3057\:3001\:65b0\:30d7\:30ed\:30f3\:30d7\:30c8\:6587\:3092\:4e0e\:3048\:308b\:3068\:8efd\:91cf LLM (\\\"ExtractModel\\\" -> Automatic \:306f SourceVault \:65e2\:5b9a\:30e2\:30c7\:30eb) \:3067\:5404\:30d1\:30e9\:30e1\:30fc\:30bf\:30b9\:30ed\:30c3\:30c8\:306e\:65b0 InputForm \:5024\:3092\:62bd\:51fa\:3057\:3001ParameterTemplate \:3092\:57cb\:3081\:305f\:5f0f\:6587\:5b57\:5217\:3092\:8fd4\:3059\:3002HeavyLLM \:307e\:305f\:306f\:5f0f\:304c\:8a18\:9332\:3055\:308c\:3066\:3044\:306a\:3044\:30eb\:30fc\:30c8\:306f ClaudeEval[...] \:5f62\:5f0f\:306e\:5f0f\:3092\:8fd4\:3059\:3002\:623b\:308a\:5024: <|\\\"Status\\\", \\\"ReplayClass\\\", \\\"ExprString\\\", \\\"SlotValues\\\"|>\:3002\:30aa\:30d7\:30b7\:30e7\:30f3: \\\"NewPrompt\\\" -> Automatic, \\\"ExtractModel\\\" -> Automatic\:3002";

$SourceVaultPromptAutoSave::usage =
  "$SourceVaultPromptAutoSave (default True) controls whether ClaudeEval " <>
  "auto-saves every notebook prompt it runs as a new saved PromptRoute " <>
  "version via SourceVaultAutoSaveLastPrompt. Set to False to disable " <>
  "automatic capture.";

$SourceVaultPromptSavedProposalActive::usage =
  "$SourceVaultPromptSavedProposalActive (default True) controls whether " <>
  "ClaudeEval, before calling the LLM, consults the saved prompts for an " <>
  "exact (normalized) match and proposes them. Set to False to disable " <>
  "the saved-prompt proposal at the ClaudeEval entry.";

$SourceVaultPromptBypassOnce::usage =
  "$SourceVaultPromptBypassOnce is a one-shot normalized-prompt key. When " <>
  "SourceVaultProposeSavedPromptRoute sees a prompt whose normalized form " <>
  "matches it, it consumes the key (resets to Missing) and declines, so " <>
  "ClaudeEval falls through to the legacy LLM path. The \"ask the LLM " <>
  "again\" button in the saved-prompt list sets this.";

SourceVaultAutoSaveLastPrompt::usage =
  "SourceVaultAutoSaveLastPrompt[prompt_String, opts] saves the most recent " <>
  "successful ClaudeEval/ContinueEval run for prompt as a NEW saved " <>
  "PromptRoute version (it never overwrites an existing version). It is the " <>
  "default-on capture path called automatically by ClaudeEval; the manual, " <>
  "memo-bearing counterpart is SaveLastPrompt. Versions for the same " <>
  "(normalized) prompt share a PromptGroupId. A new version is skipped when " <>
  "its TargetExprString duplicates the group's newest version. Gated by " <>
  "$SourceVaultPromptAutoSave. Options: \"Memo\" -> \"\", plus the SaveLastPrompt " <>
  "options. Returns the SaveLastPrompt result, or <|\"Status\"->\"Skipped\"|>.";

SourceVaultMatchSavedPromptVersions::usage =
  "SourceVaultMatchSavedPromptVersions[prompt_String, opts] returns the saved " <>
  "PromptRoutes whose normalized prompt exactly matches prompt (the same " <>
  "normalization used for PromptHash), across all channels, sorted primary " <>
  "first then newest. Returns {} when none match. Options: \"Channel\" -> All, " <>
  "\"IncludeSeed\" -> False.";

SourceVaultPrimaryPromptRoute::usage =
  "SourceVaultPrimaryPromptRoute[prompt_String] returns the primary saved " <>
  "PromptRoute for prompt's group, or Missing[\"NoPrimary\"]. A route is " <>
  "primary when its \"Primary\" field is True (set via " <>
  "SourceVaultSetPrimaryPromptRoute).";

SourceVaultSetPrimaryPromptRoute::usage =
  "SourceVaultSetPrimaryPromptRoute[routeId_String, opts] marks the route as " <>
  "the primary version within its PromptGroupId and clears Primary on its " <>
  "siblings (across channels). Option \"AutoExecute\" -> True|False sets " <>
  "whether ClaudeEval may release-and-evaluate the route's frozen expression " <>
  "without a confirmation dialog; AutoExecute is only honoured for routes " <>
  "with ReplaySafety \"EnvironmentIndependent\". This is a reversible metadata " <>
  "toggle so \"DryRun\" defaults to False. Returns Status/RouteId/Channel/" <>
  "ClearedSiblings.";

SourceVaultDeletePromptRoute::usage =
  "SourceVaultDeletePromptRoute[routeId_String, opts] removes a saved " <>
  "PromptRoute from its channel registry (atomic rewrite). Per the datastore " <>
  "safety rule it is non-destructive by default: \"DryRun\" -> True (the " <>
  "default) reports the plan, and a real delete requires \"Confirm\" -> True " <>
  "(and DryRun -> False). Returns Status/RouteId/Channel/Removed/WasPrimary.";

SourceVaultRunPrimaryRoute::usage =
  "SourceVaultRunPrimaryRoute[groupId_String, opts] is the gated executor for " <>
  "a primary route's frozen expression. It parses the route's TargetExprString " <>
  "WITHOUT evaluating it, and evaluates it only when (a) the head is a " <>
  "ReadOnly/SafeCreate SourceVault callable (it rejects Set/SetDelayed/" <>
  "AppendTo/ClaudeAttach/SystemCredential and any unclassified head, honouring " <>
  "the AutoEvaluate-prohibited rule) and (b) the route's ReplaySafety is " <>
  "\"EnvironmentIndependent\". Otherwise it returns a notice and does not " <>
  "evaluate. ClaudeEval reaches this only via a HoldComplete[SourceVaultRunPrimaryRoute[..]] " <>
  "proposal, so ClaudeEval never releases the saved expression directly.";

SourceVaultPromptVersionsUI::usage =
  "SourceVaultPromptVersionsUI[normKey_String, prompt_String, opts] renders the " <>
  "saved versions for a prompt group (via SourceVaultFormatPromptRouteList) " <>
  "with a header and an \"ask the LLM again\" button that bypasses the saved " <>
  "proposal once and re-runs ClaudeEval through the LLM. ClaudeEval shows this " <>
  "instead of calling the LLM when saved versions exist but no auto-execute " <>
  "primary is set.";

SourceVaultProposeSavedPromptRoute::usage =
  "SourceVaultProposeSavedPromptRoute[prompt_String, opts] is the ClaudeEval-entry " <>
  "saved-prompt proposer (weak-called from claudecode before the LLM call). It " <>
  "returns a PromptRouteProposal whose \"ProposedExpression\" is either " <>
  "HoldComplete[SourceVaultRunPrimaryRoute[groupId]] (when an EnvironmentIndependent " <>
  "primary with AutoExecute exists) or HoldComplete[SourceVaultPromptVersionsUI[..]] " <>
  "(when saved versions exist). It returns Status NotDispatched when the feature " <>
  "is off, the one-shot bypass key matches, or no saved version matches.";

SourceVaultUpdatePromptRouteMemo::usage =
  "SourceVaultUpdatePromptRouteMemo[routeId_String, memo_String] sets the " <>
  "Memo field of a saved PromptRoute (atomic channel rewrite) and bumps " <>
  "UpdatedAt. Used by the editable Memo cell in SourceVaultFormatPromptRouteList " <>
  "so a memo can be added or revised after a prompt was auto-saved. Memo is " <>
  "stored in plaintext even for encrypted routes (it is the display label). " <>
  "Returns Status/RouteId/Channel/Memo.";

SourceVaultClassifyPromptReplaySafety::usage =
  "SourceVaultClassifyPromptReplaySafety[prompt_String, exprString_, contextBinding_] " <>
  "classifies whether a generated expression is safe to replay as a frozen " <>
  "constant. Returns <|\"ReplaySafety\" -> \"EnvironmentIndependent\" | " <>
  "\"ContextBound\" | \"Unknown\", \"ContextBinding\" -> <|...|>|>. A prompt is " <>
  "ContextBound when its expression literally embeds captured notebook context, " <>
  "references session-transient symbols (%/Out/In/SelectedCells/NotebookRead/...), " <>
  "or the prompt uses deictic words (\"the cell above\", etc.). Only " <>
  "EnvironmentIndependent routes may be auto-executed; ContextBound routes are " <>
  "forced to ReplayClass HeavyLLM (re-resolved by the LLM with fresh context).";

SourceVaultClassifyPromptContextDependency::usage =
  "SourceVaultClassifyPromptContextDependency[prompt_String] is an LLM-free, " <>
  "prompt-only prefilter that infers what context a NEW prompt requires, BEFORE " <>
  "any expression is generated (unlike SourceVaultClassifyPromptReplaySafety, " <>
  "which classifies an already-generated expression). It shares the deictic " <>
  "pattern table with iSVPRDeicticQ and never conflates notebook references with " <>
  "conversation-history references. Returns <|\"DependencyKinds\" -> {...}, " <>
  "\"RequiredContext\" -> <|\"Notebook\" -> <|\"Mode\" -> \"None\" | " <>
  "\"PreviousCellGroup\" | \"Tail\" | \"Full\"|>, \"SelectedCells\" -> True|False, " <>
  "\"History\" -> <|\"Mode\" -> \"None\" | \"Recent\"|>|>, \"Confidence\" -> " <>
  "\"High\"|\"Low\", \"Reasons\" -> {...}|>. RequiredContext is the required " <>
  "MINIMUM (a floor); a context planner combines it with the requested/default " <>
  "plan. When nothing is detected the floor is empty (DependencyKinds " <>
  "{\"SelfContained\"}, Confidence \"Low\") so trivial prompts get minimal context.";

SourceVaultPromptRoutePanel::usage =
  "SourceVaultPromptRoutePanel[] returns a UI panel that lists the saved " <>
  "PromptRoutes and lets you search them by keyword/memo, filter by channel, " <>
  "and manage each one (Preview / Run / ToInput / Primary / Memo / delete) " <>
  "via SourceVaultFormatPromptRouteList. It is the saved-prompt counterpart of " <>
  "SourceVaultWorkflowPanel (manual refresh, FE-freeze safe). Options: " <>
  "\"Channel\" -> All|\"public\"|\"private\"|\"local\" (initial channel filter).";

Begin["`Private`"];

(* ------------------------------------------------------------
   Version / phase constants.
   ------------------------------------------------------------ *)

$SourceVaultPromptRouterVersion = "2.1.0-savedPromptVersions (2026-06-09)";

iSVPRImplementationPhase[] := "SavedPromptVersions-spec-v11";

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

    (* ReadOnly \:307e\:305f\:306f SafeCreate (\:65b0\:898f\:30d5\:30a1\:30a4\:30eb\:751f\:6210\:306e\:307f\:30fb\:65e2\:5b58\:975e\:7834\:58ca) \:306f\:81ea\:52d5\:8d77\:52d5\:3002
       \:305d\:306e\:4ed6\:306e\:526f\:4f5c\:7528 (\:524a\:9664\:30fb\:4e0a\:66f8\:304d\:7b49) \:306f\:5f93\:6765\:901a\:308a\:627f\:8a8d\:5f85\:3061\:3002
       SafeCreate \:306f\:30e6\:30fc\:30b6\:304c\:660e\:793a\:7684\:306b\:6307\:793a\:3057\:305f\:5834\:5408\:306e\:307f\:30de\:30c3\:30c1\:3059\:308b\:30ad\:30fc\:30ef\:30fc\:30c9 route \:306b\:9650\:308a\:3001
       \:65e2\:5b58\:30d5\:30a1\:30a4\:30eb\:3092\:4e0a\:66f8\:304d\:305b\:305a\:9023\:756a\:56de\:907f\:3059\:308b\:5b9f\:88c5\:3092\:524d\:63d0\:3068\:3059\:308b\:3002 *)
    If[!MemberQ[{"ReadOnly", "SafeCreate"},
        Lookup[callable, "SideEffectClass", "Unknown"]],
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
    BinaryWrite[strm, StringToByteArray[line <> "\n", "ISO8859-1"]];
    (* Stage 9 P1.5 utf8fix: ExportString["RawJSON"] \:306e\:623b\:308a\:5024\:306f
       UTF-8 byte \:306e Latin-1 \:8868\:73fe\:306a\:306e\:3067 ISO8859-1 \:3067 byte \:5316\:3002
       \:65e7 UTF-8 \:306f\:4e8c\:91cd encode (SourceVault.wl JSONL \:5074\:3068\:540c\:3058 ISO8859-1 \:306b\:7d71\:4e00)\:3002 *)
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
    |>,
    "SourceVaultNewNotebook" -> <|
      "FunctionId"         -> "SourceVaultNewNotebook",
      "Symbol"             -> SourceVaultNewNotebook,
      "UseAsFunctionRoute" -> True,
      "UseAsHandlerRef"    -> True,
      (* \:65b0\:898f\:30d5\:30a1\:30a4\:30eb\:751f\:6210\:306e\:307f\:30fb\:65e2\:5b58\:975e\:7834\:58ca (\:9023\:756a\:56de\:907f) \:306a\:306e\:3067 SafeCreate\:3002
         \:30e6\:30fc\:30b6\:304c\:660e\:793a\:7684\:306b\:300c\:65b0\:898f\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:300d\:3068\:6307\:793a\:3057\:305f\:6642\:306b\:81ea\:52d5\:8d77\:52d5\:3055\:308c\:308b\:3002 *)
      "SideEffectClass"    -> "SafeCreate",
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
(* \:518d\:5b9f\:884c\:30af\:30e9\:30b9\:5224\:5b9a (\:30d5\:30a7\:30fc\:30ba2): \:63d0\:6848\:5f0f\:6587\:5b57\:5217\:304b\:3089 ReplayClass \:3092\:81ea\:52d5\:5224\:5b9a\:3059\:308b\:3002
   - \"Replayable\": LLM \:4e0d\:8981\:3067\:305d\:306e\:307e\:307e\:8a55\:4fa1\:3067\:304d\:308b\:3002\:5f0f\:306b ClaudeEval/ContinueEval \:3092\:542b\:307e\:305a\:3001
     \:5168\:30b7\:30f3\:30dc\:30eb head \:304c\:8a31\:53ef (SourceVault \:7cfb + \:5b89\:5168\:306a\:30b7\:30b9\:30c6\:30e0\:95a2\:6570) \:306b\:53ce\:307e\:308b\:3002
   - \"HeavyLLM\": \:30d1\:30fc\:30b9\:4e0d\:80fd / ClaudeEval \:3092\:542b\:3080 / \:8a31\:53ef\:5916 head \:3092\:542b\:3080 (\:6bce\:56de LLM \:518d\:751f\:6210\:304c\:5fc5\:8981)\:3002
   \:30d5\:30a7\:30fc\:30ba3 \:3067 LightLLM (\:30d1\:30e9\:30e1\:30fc\:30bf\:62bd\:51fa) \:3092\:8ffd\:52a0\:4e88\:5b9a\:3002 *)
iSVPRClassifyReplay[exprStr_String] :=
  Module[{held, heads, allow, llmHeads, badHeads, trimmed},
    trimmed = StringTrim[exprStr];
    If[trimmed === "" ||
       StringStartsQ[trimmed, "(" <> "*"],
      Return["HeavyLLM"]];
    held = Quiet @ Check[
      ToExpression[exprStr, InputForm, HoldComplete], $Failed];
    If[held === $Failed || !MatchQ[held, _HoldComplete],
      Return["HeavyLLM"]];
    (* \:5f0f\:4e2d\:306e\:5168\:30b7\:30f3\:30dc\:30eb head \:3092\:62bd\:51fa (\:672a\:8a55\:4fa1)\:3002
       held = HoldComplete[expr] \:306e\:30e9\:30c3\:30d1\:30fc\:81ea\:4f53\:306f\:9664\:304d\:3001\:4e2d\:8eab expr \:306e head \:3092\:898b\:308b\:3002 *)
    heads = Quiet @ Check[
      Extract[held, {1},
        Function[Null,
          DeleteDuplicates @ Cases[Unevaluated[#],
            s_Symbol[___] :> SymbolName[Unevaluated[s]],
            {0, Infinity}, Heads -> True],
          HoldAllComplete]], {}];
    If[!ListQ[heads], heads = {}];
    (* LLM \:518d\:751f\:6210\:304c\:5fc5\:8981\:306a head: ClaudeEval / ContinueEval *)
    llmHeads = Select[heads,
      StringMatchQ[#, "ClaudeEval" | "ContinueEval"] &];
    If[Length[llmHeads] > 0, Return["HeavyLLM"]];
    (* \:8a31\:53ef head: SourceVault \:7cfb (Symbol \:540d\:304c SourceVault \:3067\:59cb\:307e\:308b\:304b
       \:8a31\:53ef\:30ea\:30b9\:30c8\:767b\:9332\:6e08\:307f) + \:5b89\:5168\:306a\:30b7\:30b9\:30c6\:30e0\:95a2\:6570 (\:6700\:5c0f\:9650) *)
    allow = Quiet @ Check[
      Keys[SourceVaultCallableAllowlistRegistry[]], {}];
    If[!ListQ[allow], allow = {}];
    badHeads = Select[heads,
      !(StringStartsQ[#, "SourceVault"] ||
        StringStartsQ[#, "NB"] ||
        MemberQ[allow, #] ||
        MemberQ[$iSVPRReplaySafeSystemHeads, #]) &];
    If[Length[badHeads] > 0, Return["HeavyLLM"]];
    "Replayable"];
iSVPRClassifyReplay[_] := "HeavyLLM";

(* \:30d5\:30a7\:30fc\:30ba3a: \:63d0\:6848\:5f0f\:6587\:5b57\:5217\:3092\:69cb\:6587\:7684\:306b\:30d1\:30e9\:30e1\:30fc\:30bf\:5316\:3059\:308b\:3002
   \:5f0f\:4e2d\:306e DateObject[{y, m, d}] \:30ea\:30c6\:30e9\:30eb\:3092\:691c\:51fa\:3057\:3001\:30d7\:30ec\:30fc\:30b9\:30db\:30eb\:30c0 @@SLOT_n@@ \:306b\:7f6e\:63db\:3057\:305f
   ParameterTemplate \:6587\:5b57\:5217\:3068\:3001\:5404\:30b9\:30ed\:30c3\:30c8\:306e\:5143\:5024\:30fb\:578b\:3092\:8a18\:9332\:3057\:305f ParameterSlots \:3092\:8fd4\:3059\:3002
   \:8fd4\:308a\:5024: <|\"Template\" -> _String, \"Slots\" -> {<|\"Name\",\"Type\",\"OriginalString\"|>...}|>\:3002
   \:30b9\:30ed\:30c3\:30c8\:304c 0 \:500b\:306a\:3089 Template \:306f\:5143\:5f0f\:307e\:307e\:30fbSlots \:7a7a (LightLLM \:306b\:306f\:306a\:3089\:306a\:3044)\:3002
   LLM \:4e0d\:8981\:306e\:7d14\:69cb\:6587\:51e6\:7406\:3002 *)
iSVPRParameterize[exprStr_String] :=
  Module[{held, dateNodes, slots, template, idx},
    held = Quiet @ Check[
      ToExpression[exprStr, InputForm, HoldComplete], $Failed];
    If[held === $Failed || !MatchQ[held, _HoldComplete],
      Return[<|"Template" -> exprStr, "Slots" -> {}|>]];
    (* \:5f0f\:4e2d\:306e DateObject[...] \:30ce\:30fc\:30c9\:3092 InputForm \:6587\:5b57\:5217\:3068\:3057\:3066\:5217\:6319 (\:672a\:8a55\:4fa1) *)
    dateNodes = Quiet @ Check[
      Extract[held, {1},
        Function[Null,
          Cases[Unevaluated[#],
            d : (_DateObject) :> ToString[Unevaluated[d], InputForm],
            {0, Infinity}],
          HoldAllComplete]], {}];
    If[!ListQ[dateNodes], dateNodes = {}];
    dateNodes = DeleteDuplicates[Select[dateNodes, StringQ]];
    (* \:5404 DateObject \:6587\:5b57\:5217\:3092\:30d7\:30ec\:30fc\:30b9\:30db\:30eb\:30c0\:306b\:7f6e\:63db\:3057\:3066\:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:5316 *)
    template = exprStr;
    slots = {};
    idx = 0;
    Scan[
      Function[ds,
        idx = idx + 1;
        With[{slotName = "@@SLOT_" <> ToString[idx] <> "@@"},
          template = StringReplace[template, ds -> slotName];
          AppendTo[slots, <|
            "Name" -> slotName,
            "Type" -> "Date",
            "Source" -> "Syntactic",
            "OriginalString" -> ds,
            "Hint" -> "\:65e5\:4ed8"|>]]],
      dateNodes];
    <|"Template" -> template, "Slots" -> slots|>];
iSVPRParameterize[_] := <|"Template" -> "", "Slots" -> {}|>;

(* ============================================================
   \:30d5\:30a7\:30fc\:30ba3b: LightLLM \:518d\:5b9f\:884c\:ff08\:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:5145\:586b\:30fb\:30b9\:30ed\:30c3\:30c8\:62bd\:51fa\:30fb\:516c\:958b\:518d\:5b9f\:884c API\:ff09\:3002
      3a \:306e iSVPRParameterize \:304c\:4f5c\:308b ParameterTemplate / ParameterSlots \:3092
      \:4f7f\:3044\:3001\:65b0\:30d7\:30ed\:30f3\:30d7\:30c8\:304b\:3089\:65b0\:30d1\:30e9\:30e1\:30fc\:30bf\:5024\:3092\:8efd\:91cf LLM \:3067\:62bd\:51fa\:3057\:3066\:5f0f\:3092\:518d\:69cb\:6210\:3059\:308b\:3002
   ============================================================ *)

(* (1) iSVPRFillTemplate: \:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:306e\:30b9\:30ed\:30c3\:30c8\:3092\:65b0\:5024\:3067\:57cb\:3081\:3066\:5f0f\:6587\:5b57\:5217\:3092\:8fd4\:3059\:3002
   LLM \:4e0d\:8981\:30fb\:7d14\:7c8b\:95a2\:6570\:3002slotValues \:306f <|"@@SLOT_n@@" -> "<\:65b0 InputForm \:6587\:5b57\:5217>"|>\:3002 *)
iSVPRFillTemplate[template_String, slotValues_Association] :=
  Module[{result},
    result = template;
    KeyValueMap[
      Function[{slot, val},
        If[StringQ[slot] && StringQ[val],
          result = StringReplace[result, slot -> val]]],
      slotValues];
    result];
iSVPRFillTemplate[template_String, _] := template;
iSVPRFillTemplate[_, _] := Missing["BadTemplate"];

(* LLM \:5fdc\:7b54\:304b\:3089 ```json \:30d5\:30a7\:30f3\:30b9\:3092\:9664\:53bb\:3057\:30013 \:6bb5\:968e\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3067 Association \:5316\:3059\:308b\:3002
   \:7f60 #28: ImportString["RawJSON"] \:306f\:74b0\:5883\:306b\:3088\:308a\:5931\:6557\:3059\:308b\:305f\:3081
   Developer`ReadRawJSONString \:3092\:512a\:5148\:3002\:5931\:6557\:6642\:306f <||>\:3002
   \:5024\:304c\:6587\:5b57\:5217\:306e\:30b9\:30ed\:30c3\:30c8\:3060\:3051\:3092\:6b8b\:3059\:3002 *)
iSVPRParseSlotJSON[raw_String] :=
  Module[{txt, parsed, assoc},
    txt = raw;
    (* \:30b3\:30fc\:30c9\:30d5\:30a7\:30f3\:30b9\:9664\:53bb: ```json ... ``` \:307e\:305f\:306f ``` ... ``` *)
    txt = StringReplace[txt,
      {StartOfString ~~ Whitespace... ~~ "```" ~~ ("json" | "JSON" | "") ~~ "\n" -> "",
       "```" ~~ Whitespace... ~~ EndOfString -> ""}];
    txt = StringReplace[txt, "```" -> ""];
    txt = StringTrim[txt];
    (* \:5148\:982d\:306e { \:304b\:3089\:672b\:5c3e\:306e } \:307e\:3067\:3092\:629c\:304d\:51fa\:3059\:ff08\:524d\:5f8c\:306e\:5730\:306e\:6587\:3092\:9664\:53bb\:ff09 *)
    Module[{p1, p2},
      p1 = StringPosition[txt, "{", 1];
      p2 = Last /@ StringPosition[txt, "}"];
      If[p1 =!= {} && p2 =!= {},
        txt = StringTake[txt, {p1[[1, 1]], Last[p2]}]]];
    (* 3 \:6bb5\:968e JSON \:30d1\:30fc\:30b9 *)
    parsed = Quiet @ Check[Developer`ReadRawJSONString[txt], $Failed];
    If[parsed === $Failed || Head[parsed] === Developer`ReadRawJSONString,
      parsed = Quiet @ Check[ImportString[txt, "RawJSON"], $Failed]];
    If[parsed === $Failed,
      parsed = Quiet @ Check[
        ImportString[txt, "JSON"] /. r : {__Rule} :> Association[r], $Failed]];
    If[parsed === $Failed, Return[<||>]];
    assoc = If[AssociationQ[parsed], parsed,
      If[ListQ[parsed] && parsed =!= {} && AllTrue[parsed, MatchQ[#, _Rule | _RuleDelayed] &],
        Association[parsed], <||>]];
    If[!AssociationQ[assoc], Return[<||>]];
    (* \:5024\:304c\:6587\:5b57\:5217\:306e\:30ad\:30fc\:3060\:3051\:6b8b\:3059 *)
    Select[assoc, StringQ]];
iSVPRParseSlotJSON[_] := <||>;

(* (2) iSVPRExtractSlotValues: \:8efd\:91cf LLM \:306b ParameterTemplate \:3068\:5404\:30b9\:30ed\:30c3\:30c8\:306e
   Type/Hint/OriginalString\:3001\:65b0\:30d7\:30ed\:30f3\:30d7\:30c8\:6587\:3092\:6e21\:3057\:3001\:5404\:30b9\:30ed\:30c3\:30c8\:306e\:65b0 InputForm \:5024\:3092
   JSON \:3067\:5f97\:308b\:3002"ExtractModel" -> Automatic \:306a\:3089\:65e2\:5b9a\:30e2\:30c7\:30eb\:3002
   ClaudeQueryBg[userPrompt, "System" \:306f\:7121\:3044\:306e\:3067 system \:306f\:30d7\:30ed\:30f3\:30d7\:30c8\:5148\:982d\:306b\:9023\:7d50\:3002
   \:5931\:6557\:6642\:306f <||>\:3002 *)
Options[iSVPRExtractSlotValues] = {"ExtractModel" -> Automatic};
iSVPRExtractSlotValues[route_Association, newPrompt_String, opts : OptionsPattern[]] :=
  Lookup[iSVPRExtractSlotValuesDiag[route, newPrompt, opts], "Values", <||>];

(* \:8a3a\:65ad\:7248: \:5931\:6557\:6bb5\:968e\:3092 "Reason" \:306b\:8fd4\:3059\:3002
   \:623b\:308a\:5024 <|"Values" -> _Association, "Reason" -> _String,
   "RawResponse" -> _String (\:53d6\:5f97\:3067\:304d\:305f\:5834\:5408)|>\:3002 *)
Options[iSVPRExtractSlotValuesDiag] = {"ExtractModel" -> Automatic};
iSVPRExtractSlotValuesDiag[route_Association, newPrompt_String, opts : OptionsPattern[]] :=
  Module[{template, slots, model, queryBg, sysPrompt, slotLines, userPrompt,
          fullPrompt, resp, parsed, slotNames, kept},
    template = Lookup[route, "ParameterTemplate", Missing[]];
    slots    = Lookup[route, "ParameterSlots", {}];
    If[!StringQ[template] || !ListQ[slots] || slots === {},
      Return[<|"Values" -> <||>, "Reason" -> "NoTemplateOrSlots"|>]];
    slotNames = Lookup[#, "Name", Missing[]] & /@ slots;
    slotNames = Select[slotNames, StringQ];
    If[slotNames === {},
      Return[<|"Values" -> <||>, "Reason" -> "NoSlotNames"|>]];
    model = OptionValue["ExtractModel"];
    (* ClaudeQueryBg \:3092\:5f31\:547c\:3073\:51fa\:3057\:3067\:89e3\:6c7a\:ff08claudecode` \:304c\:30ed\:30fc\:30c9\:6e08\:307f\:524d\:63d0\:3060\:304c\:5b89\:5168\:306b\:ff09\:3002
       \:5224\:5b9a\:306f 2 \:6bb5\:69cb\:3048: (a) ClaudeQueryBg \:540d\:304c\:898b\:3048\:308b\:304b\:3001\:307e\:305f\:306f
       (b) \:540c\:30d1\:30c3\:30b1\:30fc\:30b8\:306e ClaudeEval \:304c\:898b\:3048\:308c\:3070 ClaudeCode` \:306f\:30ed\:30fc\:30c9\:6e08\:307f\:3068\:307f\:306a\:3059\:3002
       Names \:304c $ContextPath \:4f9d\:5b58\:3067\:62fe\:3048\:306a\:3044\:30b1\:30fc\:30b9\:3092\:9632\:3050\:3002 *)
    If[!(iSVPRSymbolPresentQ["ClaudeCode`ClaudeQueryBg"] ||
         iSVPRSymbolPresentQ["ClaudeCode`ClaudeEval"]),
      Return[<|"Values" -> <||>, "Reason" -> "NoClaudeQueryBg"|>]];
    (* ClaudeCode` \:306f\:30ed\:30fc\:30c9\:6e08\:307f\:3002\:30d5\:30eb\:30cd\:30fc\:30e0\:3067\:65e2\:5b58\:30b7\:30f3\:30dc\:30eb\:3092\:53d6\:5f97\:3002 *)
    queryBg = Symbol["ClaudeCode`ClaudeQueryBg"];
    (* system \:76f8\:5f53\:306e\:6307\:793a\:6587\:ff08\:65e5\:672c\:8a9e\:ff09 *)
    sysPrompt = StringJoin[
      "\:3042\:306a\:305f\:306f\:4fdd\:5b58\:6e08\:307f\:306e Wolfram \:5f0f\:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:306e\:30d1\:30e9\:30e1\:30fc\:30bf\:30b9\:30ed\:30c3\:30c8\:3092\:3001",
      "\:65b0\:3057\:3044\:30d7\:30ed\:30f3\:30d7\:30c8\:6587\:306b\:5408\:308f\:305b\:3066\:518d\:8a08\:7b97\:3059\:308b\:30a2\:30b7\:30b9\:30bf\:30f3\:30c8\:3067\:3059\:3002\n",
      "\:5404\:30b9\:30ed\:30c3\:30c8\:306e\:65b0\:3057\:3044\:5024\:3092 Wolfram InputForm \:6587\:5b57\:5217\:3068\:3057\:3066\:6c42\:3081\:3066\:304f\:3060\:3055\:3044\:3002\n",
      "\:65e5\:4ed8\:30b9\:30ed\:30c3\:30c8\:306f DateObject[{y,m,d}] \:5f62\:5f0f\:306e\:6587\:5b57\:5217\:3067\:8fd4\:3057\:307e\:3059\:3002\n",
      "\:5909\:66f4\:304c\:4e0d\:8981\:306a\:30b9\:30ed\:30c3\:30c8\:306f\:5143\:306e\:5024\:3092\:305d\:306e\:307e\:307e\:8fd4\:3057\:307e\:3059\:3002\n",
      "\:5fdc\:7b54\:306f JSON \:30aa\:30d6\:30b8\:30a7\:30af\:30c8\:306e\:307f\:3092\:8fd4\:3057\:3001\:524d\:5f8c\:306b\:5730\:306e\:6587\:3084 Markdown \:30b3\:30fc\:30c9\:30d5\:30a7\:30f3\:30b9\:3092\:4ed8\:3051\:306a\:3044\:3067\:304f\:3060\:3055\:3044\:3002\n",
      "JSON \:306e\:30ad\:30fc\:306f\:30b9\:30ed\:30c3\:30c8\:540d (@@SLOT_n@@)\:3001\:5024\:306f InputForm \:6587\:5b57\:5217\:3067\:3059\:3002"];
    (* \:5404\:30b9\:30ed\:30c3\:30c8\:306e\:8aac\:660e\:884c *)
    slotLines = StringRiffle[
      Function[s,
        StringJoin[
          Lookup[s, "Name", "?"], ": Type=", ToString[Lookup[s, "Type", "Unknown"]],
          ", Hint=", ToString[Lookup[s, "Hint", ""]],
          ", \:5143\:5024=", ToString[Lookup[s, "OriginalString", ""]]]] /@ slots,
      "\n"];
    userPrompt = StringJoin[
      "\:5f0f\:30c6\:30f3\:30d7\:30ec\:30fc\:30c8:\n", template, "\n\n",
      "\:30b9\:30ed\:30c3\:30c8\:4e00\:89a7:\n", slotLines, "\n\n",
      "\:65b0\:3057\:3044\:30d7\:30ed\:30f3\:30d7\:30c8\:6587:\n", newPrompt, "\n\n",
      "\:4e0a\:8a18\:306e\:5404\:30b9\:30ed\:30c3\:30c8\:540d\:3092\:30ad\:30fc\:3001\:65b0\:3057\:3044 InputForm \:6587\:5b57\:5217\:3092\:5024\:3068\:3059\:308b JSON \:3092\:8fd4\:3057\:3066\:304f\:3060\:3055\:3044\:3002"];
    fullPrompt = sysPrompt <> "\n\n" <> userPrompt;
    (* LLM \:547c\:3073\:51fa\:3057\:3002Model \:6307\:5b9a\:304c Automatic \:4ee5\:5916\:306a\:3089\:6e21\:3059\:3002
       NOTE: the Model option symbol lives in ClaudeCode`Private`, so a bare
       Model symbol parsed here becomes SourceVault`Private`Model and is
       silently ignored by ClaudeQueryBg. Pass the option by its string
       name instead (OptionValue resolves string names by symbol name). *)
    resp = Quiet @ Check[
      If[model === Automatic,
        queryBg[fullPrompt],
        queryBg[fullPrompt, "Model" -> model]],
      $Failed];
    If[!StringQ[resp],
      Return[<|"Values" -> <||>, "Reason" -> "LLMCallFailed",
        "RawResponse" -> If[StringQ[resp], resp, ToString[resp]]|>]];
    parsed = iSVPRParseSlotJSON[resp];
    If[!AssociationQ[parsed] || parsed === <||>,
      Return[<|"Values" -> <||>, "Reason" -> "JSONParseFailed",
        "RawResponse" -> resp|>]];
    (* \:65e2\:77e5\:30b9\:30ed\:30c3\:30c8\:540d\:306b\:9650\:5b9a\:3057\:3066\:63a1\:7528 *)
    kept = KeySelect[parsed, MemberQ[slotNames, #] &];
    If[kept === <||>,
      Return[<|"Values" -> <||>, "Reason" -> "NoMatchingSlots",
        "RawResponse" -> resp|>]];
    <|"Values" -> kept, "Reason" -> "OK", "RawResponse" -> resp|>];
iSVPRExtractSlotValuesDiag[_, _, OptionsPattern[]] :=
  <|"Values" -> <||>, "Reason" -> "BadArguments"|>;

(* (3) SourceVaultReplayRoute (\:516c\:958b API): \:518d\:5b9f\:884c\:30af\:30e9\:30b9\:306b\:5fdc\:3058\:3066\:5f0f\:6587\:5b57\:5217\:3092\:8fd4\:3059\:3002
   Replayable: TargetExprString \:3092\:305d\:306e\:307e\:307e\:3002
   LightLLM: NewPrompt \:7121\:2192\:5143\:5024\:5fa9\:5143 / \:6709\:2192 iSVPRExtractSlotValues + iSVPRFillTemplate\:3002
   HeavyLLM / \:5f0f\:7121: iSVPRRouteInputExpr (ClaudeEval[...] \:5f62\:5f0f)\:3002
   \:623b\:308a\:5024: <|"Status","ReplayClass","ExprString","SlotValues"|>\:3002 *)
Options[SourceVaultReplayRoute] = {"NewPrompt" -> Automatic, "ExtractModel" -> Automatic};
SourceVaultReplayRoute[route_Association, opts : OptionsPattern[]] :=
  Module[{cls, targetExpr, template, slots, newPrompt, model},
    cls        = Lookup[route, "ReplayClass", "HeavyLLM"];
    targetExpr = Lookup[route, "TargetExprString", Missing[]];
    template   = Lookup[route, "ParameterTemplate", Missing[]];
    slots      = Lookup[route, "ParameterSlots", {}];
    newPrompt  = OptionValue["NewPrompt"];
    model      = OptionValue["ExtractModel"];
    Which[
      (* === Replayable: \:305d\:306e\:307e\:307e === *)
      cls === "Replayable" && StringQ[targetExpr],
        <|"Status" -> "OK", "ReplayClass" -> "Replayable",
          "ExprString" -> targetExpr, "SlotValues" -> <||>|>,
      (* === LightLLM === *)
      cls === "LightLLM" && StringQ[template] && ListQ[slots] && slots =!= {},
        If[!StringQ[newPrompt] || newPrompt === "",
          (* NewPrompt \:7121\:3057: \:5143\:5024 (TargetExprString) \:3092\:5fa9\:5143 *)
          <|"Status" -> "OK", "ReplayClass" -> "LightLLM",
            "ExprString" -> If[StringQ[targetExpr], targetExpr, template],
            "SlotValues" -> <||>|>,
          (* NewPrompt \:6709\:308a: \:65b0\:5024\:62bd\:51fa \:2192 \:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:5145\:586b *)
          Module[{diag, sv, ex},
            diag = iSVPRExtractSlotValuesDiag[route, newPrompt,
              "ExtractModel" -> model];
            sv = Lookup[diag, "Values", <||>];
            If[!AssociationQ[sv] || sv === <||>,
              Return[<|"Status" -> "ExtractFailed", "ReplayClass" -> "LightLLM",
                "ExprString" -> If[StringQ[targetExpr], targetExpr, template],
                "SlotValues" -> <||>,
                "Reason" -> Lookup[diag, "Reason", "Unknown"],
                "RawResponse" -> Lookup[diag, "RawResponse", Missing[]]|>]];
            ex = iSVPRFillTemplate[template, sv];
            If[!StringQ[ex],
              Return[<|"Status" -> "FillFailed", "ReplayClass" -> "LightLLM",
                "ExprString" -> If[StringQ[targetExpr], targetExpr, template],
                "SlotValues" -> sv|>]];
            <|"Status" -> "OK", "ReplayClass" -> "LightLLM",
              "ExprString" -> ex, "SlotValues" -> sv|>]],
      (* === HeavyLLM \:307e\:305f\:306f\:5f0f\:7121\:3057: ClaudeEval[...] \:5f62\:5f0f === *)
      True,
        <|"Status" -> "OK", "ReplayClass" -> "HeavyLLM",
          "ExprString" -> iSVPRRouteInputExpr[route, iSVPRRouteDisplayPrompt[route]],
          "SlotValues" -> <||>|>]];
SourceVaultReplayRoute[___] :=
  <|"Status" -> "Failed", "Reason" -> "BadArguments",
    "Hint" -> "Expected SourceVaultReplayRoute[route_Association, opts]."|>;
(* LightLLM \:518d\:5b9f\:884c\:30c0\:30a4\:30a2\:30ed\:30b0\:3002\:5143\:30d7\:30ed\:30f3\:30d7\:30c8\:30fb\:4fdd\:5b58\:5f0f\:30fb\:5dee\:3057\:66ff\:308f\:308b\:30d1\:30e9\:30e1\:30fc\:30bf\:4e00\:89a7\:3092
   \:898b\:305b\:305f\:4e0a\:3067\:65b0\:30d7\:30ed\:30f3\:30d7\:30c8\:6587\:3092\:5165\:529b\:3055\:305b\:3001SourceVaultReplayRoute \:3092\:547c\:3076\:3002
   \:623b\:308a\:5024: \:6210\:529f\:6642\:306f SourceVaultReplayRoute \:306e\:7d50\:679c Association\:3001
   \:30ad\:30e3\:30f3\:30bb\:30eb\:6642\:306f $Canceled\:3002Run/ToInput \:30dc\:30bf\:30f3\:304b\:3089\:5171\:7528\:3059\:308b\:3002 *)
iSVPRLightLLMReplayDialog[route_Association] :=
  Module[{origPrompt, origExpr, slots, slotRows, np},
    origPrompt = iSVPRRouteDisplayPrompt[route];
    (* RouteId \:3078\:306e\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:306f\:65b0\:30d7\:30ed\:30f3\:30d7\:30c8\:5165\:529b\:306e\:521d\:671f\:5024\:3068\:3057\:3066\:7121\:610f\:5473\:306a\:306e\:3067\:3001
       Matcher.Examples \:7531\:6765\:3067\:306a\:3051\:308c\:3070\:7a7a\:6587\:5b57\:306b\:3059\:308b\:3002 *)
    If[!StringQ[origPrompt] ||
        origPrompt === Lookup[route, "RouteId", ""],
      origPrompt = ""];
    origExpr = Lookup[route, "TargetExprString",
      Lookup[route, "ParameterTemplate", ""]];
    If[!StringQ[origExpr], origExpr = ""];
    slots = Lookup[route, "ParameterSlots", {}];
    If[!ListQ[slots], slots = {}];
    (* \:30b9\:30ed\:30c3\:30c8\:4e00\:89a7\:3092\:300c\:5143\:5024 (\:578b)\:300d\:306e\:884c\:3067\:898b\:305b\:308b *)
    slotRows = Map[
      Function[s,
        {Style[Lookup[s, "Name", "?"], "Courier", FontSize -> 11,
           RGBColor[0.2, 0.38, 0.65]],
         Style[ToString[Lookup[s, "OriginalString", ""]], "Courier",
           FontSize -> 11],
         Style["(" <> ToString[Lookup[s, "Type", "?"]] <> ")",
           FontSize -> 10, GrayLevel[0.5]]}],
      slots];
    np = DialogInput[
      DynamicModule[{val = origPrompt},
        Column[{
          Style["LightLLM \:518d\:5b9f\:884c: \:30d1\:30e9\:30e1\:30fc\:30bf\:306e\:5dee\:3057\:66ff\:3048",
            Bold, FontSize -> 13, FontFamily -> "Yu Gothic UI"],
          Spacer[{0, 6}],
          (* \:4fdd\:5b58\:3055\:308c\:305f\:5f0f *)
          Style["\:4fdd\:5b58\:3055\:308c\:305f\:5f0f:", FontFamily -> "Yu Gothic UI",
            FontSize -> 11, GrayLevel[0.4]],
          Framed[
            Style[origExpr, "Courier", FontSize -> 11],
            Background -> GrayLevel[0.97],
            FrameStyle -> GrayLevel[0.85],
            RoundingRadius -> 4, ImageSize -> {520, Automatic}],
          Spacer[{0, 6}],
          (* \:5dee\:3057\:66ff\:308f\:308b\:30d1\:30e9\:30e1\:30fc\:30bf *)
          Style["\:5dee\:3057\:66ff\:308f\:308b\:30d1\:30e9\:30e1\:30fc\:30bf:",
            FontFamily -> "Yu Gothic UI", FontSize -> 11, GrayLevel[0.4]],
          If[slotRows === {},
            Style["(\:30d1\:30e9\:30e1\:30fc\:30bf\:306a\:3057)", FontFamily -> "Yu Gothic UI",
              FontSize -> 10, GrayLevel[0.5]],
            Grid[slotRows, Alignment -> Left, Spacings -> {1.5, 0.4},
              ItemSize -> {Automatic, Automatic}]],
          Style[
            "\:4e0a\:306e\:5f0f\:306e\:4e2d\:3067\:3001\:3053\:308c\:3089\:306e\:30d1\:30e9\:30e1\:30fc\:30bf\:304c\:65b0\:3057\:3044\:30d7\:30ed\:30f3\:30d7\:30c8\:306b\:5408\:308f\:305b\:3066\:81ea\:52d5\:3067\:5dee\:3057\:66ff\:308f\:308a\:307e\:3059\:3002",
            FontFamily -> "Yu Gothic UI", FontSize -> 10, GrayLevel[0.5]],
          Spacer[{0, 8}],
          (* \:65b0\:30d7\:30ed\:30f3\:30d7\:30c8\:5165\:529b *)
          Style["\:65b0\:3057\:3044\:30d7\:30ed\:30f3\:30d7\:30c8\:6587\:3092\:5165\:529b\:3057\:3066\:304f\:3060\:3055\:3044:",
            FontFamily -> "Yu Gothic UI", FontSize -> 11, Bold],
          InputField[Dynamic[val], String,
            ImageSize -> {520, 60},
            FieldHint -> origPrompt,
            BaseStyle -> {FontFamily -> "Yu Gothic UI", FontSize -> 12}],
          Spacer[{0, 8}],
          Row[{
            DefaultButton["OK (\:518d\:5b9f\:884c)", DialogReturn[val],
              ImageSize -> Automatic,
              BaseStyle -> {FontFamily -> "Yu Gothic UI"}],
            Spacer[{8, 0}],
            CancelButton["\:30ad\:30e3\:30f3\:30bb\:30eb", DialogReturn[$Canceled],
              BaseStyle -> {FontFamily -> "Yu Gothic UI"}]
          }]
        }, Spacings -> 0.3]],
      WindowTitle -> "LightLLM Replay"];
    If[np === $Canceled || !StringQ[np] || np === "",
      Return[$Canceled]];
    SourceVaultReplayRoute[route, "NewPrompt" -> np]];
iSVPRLightLLMReplayDialog[_] := $Canceled;




(* \:518d\:5b9f\:884c\:3067\:8a31\:53ef\:3059\:308b\:5b89\:5168\:306a\:30b7\:30b9\:30c6\:30e0 head (\:6700\:5c0f\:9650\:30fb\:526f\:4f5c\:7528\:306a\:3057)\:3002
   \:5f0f\:306e\:69cb\:9020\:30fb\:30ea\:30b9\:30c8\:30fb\:30aa\:30d7\:30b7\:30e7\:30f3\:30fb\:65e5\:4ed8\:7b49\:3002\:30d5\:30a1\:30a4\:30eb\:524a\:9664\:30fb\:66f8\:304d\:8fbc\:307f\:7cfb\:306f\:542b\:3081\:306a\:3044\:3002 *)
$iSVPRReplaySafeSystemHeads = {
  "List", "Association", "Rule", "RuleDelayed", "All", "None",
  "True", "False", "String", "Integer", "Real",
  "DateObject", "Quantity", "CompoundExpression",
  "Hold", "HoldForm", "HoldComplete", "HoldPattern"};

(* JSON \:30e9\:30a6\:30f3\:30c9\:30c8\:30ea\:30c3\:30d7\:5f8c\:306e PromptRoute \:3092\:6b63\:898f\:5316\:3059\:308b\:3002
   \:7a7a Association <||> \:306f JSON \:3067 {} (\:7a7a\:30ea\:30b9\:30c8) \:306b\:306a\:308a\:3001\:8aad\:307f\:8fbc\:307f\:5f8c\:3082 {} \:306e\:307e\:307e\:3002
   Matcher / Target / Privacy \:306f Association \:3067\:3042\:308b\:3079\:304d\:306a\:306e\:3067\:3001{} \:306a\:3089 <||> \:306b\:623b\:3059\:3002
   \:3053\:308c\:3092\:6020\:308b\:3068 Lookup[target, \"Kind\"] \:7b49\:304c Lookup::invrl \:3092\:8d77\:3053\:3057\:3001
   route \:304c\:8868\:793a\:51e6\:7406\:304b\:3089\:843d\:3061\:308b (SaveLastPrompt \:3057\:305f\:30eb\:30fc\:30c8\:304c\:4e00\:89a7\:306b\:51fa\:306a\:3044)\:3002
   Matcher.KeywordsAny / Examples \:306f\:30ea\:30b9\:30c8\:306e\:307e\:307e\:3067\:826f\:3044 (Association \:5316\:3057\:306a\:3044)\:3002 *)
iSVPRNormalizeRoute[route_] :=
  Module[{r},
    If[!AssociationQ[route], Return[route]];
    r = route;
    (* Association \:3092\:671f\:5f85\:3059\:308b\:30c8\:30c3\:30d7\:30ec\:30d9\:30eb\:30ad\:30fc: {} \:2192 <||> *)
    Scan[
      Function[k,
        If[KeyExistsQ[r, k] && r[k] === {}, r[k] = <||>]],
      {"Matcher", "Target", "Privacy"}];
    (* Matcher \:304c Association \:306a\:3089\:3001\:305d\:306e\:4e2d\:306e Association \:671f\:5f85\:30ad\:30fc\:3082\:5fdc\:6025\:6b63\:898f\:5316 *)
    If[AssociationQ[Lookup[r, "Matcher", Null]],
      Module[{m = r["Matcher"]},
        (* KeywordsAny / Examples / PromptFingerprints \:306f\:30ea\:30b9\:30c8\:306e\:307e\:307e\:3067\:826f\:3044\:306e\:3067\:89e6\:3089\:306a\:3044 *)
        r["Matcher"] = m]];
    r];
iSVPRNormalizeRoute[x_] := x;

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
    |>,
    <|
      "Type"         -> "PromptRoute",
      "RouteId"      -> "seed-function-newnotebook-v1",
      "RouteVersion" -> 1,
      "SchemaVersion"-> 1,
      "Matcher" -> <|
        "Kind"        -> "DeterministicPattern",
        (* \"\:65b0\:898f\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\" / \"\:65b0\:3057\:3044\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\" \:7b49\:3002
           \:90e8\:5206\:4e00\:81f4 (KeywordsAny) \:306a\:306e\:3067\"\:3092\"\:6709\:7121\:30fb\:524d\:5f8c\:6587\:8a00\:3092\:554f\:308f\:305a\:62fe\:3046\:3002 *)
        "KeywordsAny" -> {"\:65b0\:898f\:30ce\:30fc\:30c8\:30d6\:30c3\:30af", "\:65b0\:3057\:3044\:30ce\:30fc\:30c8\:30d6\:30c3\:30af",
          "\:65b0\:898f notebook", "new notebook"}
      |>,
      "Target" -> <|
        "Kind"       -> "Function",
        "FunctionId" -> "SourceVaultNewNotebook"
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
    BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
    (* Stage 9 P1.5 utf8fix: ExportString["RawJSON"] \:306e\:623b\:308a\:5024 String \:306f\:3001
       \:5404 codepoint \:304c\:65e2\:306b UTF-8 byte sequence \:306e Latin-1 \:8868\:73fe\:306b\:306a\:3063\:3066\:3044\:308b\:3002
       \:3088\:3063\:3066 ISO8859-1 (1 codepoint = 1 byte) \:3067 byte \:5316\:3059\:308c\:3070
       String \:5185\:90e8\:306e UTF-8 byte \:304c\:305d\:306e\:307e\:307e\:30d5\:30a1\:30a4\:30eb\:306b\:843d\:3061\:3001
       \:8aad\:307f\:53d6\:308a\:306e ByteArrayToString[..., "UTF-8"] \:3068\:6574\:5408\:3059\:308b\:3002
       \:65e7: StringToByteArray[json, "UTF-8"] \:306f\:4e8c\:91cd encode \:306b\:306a\:308a\:3001
       \:65e5\:672c\:8a9e\:306e Memo / Examples \:7b49\:304c\:6587\:5b57\:5316\:3051\:3057\:3066\:3044\:305f
       (model-registry \:5074\:306e iSaveRegistryEntries \:3068\:540c\:3058 ISO8859-1 \:306b\:7d71\:4e00)\:3002 *)
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
    existing = Map[iSVPRNormalizeRoute, existing];
    existing = Select[existing, AssociationQ];

    (* added vs replaced\:3002
       FirstPosition \:306f\:30c7\:30d5\:30a9\:30eb\:30c8\:3067\:5168\:30ec\:30d9\:30eb\:3092\:63a2\:7d22\:3059\:308b\:305f\:3081\:3001
       \:30c6\:30b9\:30c8\:95a2\:6570 Lookup[#, \"RouteId\"] \:304c route \:5185\:90e8\:306e\:30cd\:30b9\:30c8\:5024
       (\"PromptRoute\" \:6587\:5b57\:5217\:3084 ParameterSlots \:5185\:306e Association \:7b49) \:306b\:3082
       \:9069\:7528\:3055\:308c Lookup::invrl \:3092\:8d77\:3053\:3059\:3002\:30c8\:30c3\:30d7\:30ec\:30d9\:30eb {1} \:306b\:9650\:5b9a\:3059\:308b\:3002 *)
    pos = FirstPosition[existing,
      _?(AssociationQ[#] && Lookup[#, "RouteId", Null] === rid &),
      Missing[], {1}];
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
    registryRoutes = Map[iSVPRNormalizeRoute, registryRoutes];
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
          resolvedDomain, cloudUsed, routingClass, registryClass = None},
    (* spec 12.1: a String ModelIntent is required *)
    If[!StringQ[Lookup[query, "ModelIntent", Null]],
      Return[<|"Status" -> "Failed",
        "Reason" -> "MissingModelIntent",
        "Hint" ->
          "query needs a String ModelIntent (spec 12.1)."|>]];

    nq        = iSVPRNormalizeModelQuery[query];
    privLevel = nq["PrivacyLevel"];

    (* Routing power policy (X0b/B-side: power-aware light-model routing).
       claudecode owns $ClaudeRoutingModelPolicy + ClaudeRoutingModelClass[];
       SourceVault weak-calls it (dependency direction SourceVault -> claudecode,
       rule 11) and only for LIGHT routing. "Off" stops light-tier dispatch (the
       caller falls back to $ClaudeModel); "Cloud" forces a cloud light model
       (rule 02: resolved by trust domain, never a hardcoded name); "Local"/None
       leave the query unchanged (backward compatible). The PrivacyLevel >= 0.5
       floor below still wins over a "Cloud" policy. *)
    routingClass = Which[
      Lookup[nq, "WeightClass", Automatic] =!= "Light", None,
      Names["ClaudeCode`ClaudeRoutingModelClass"] === {}, None,
      True, Quiet @ Check[Symbol["ClaudeCode`ClaudeRoutingModelClass"][], None]];
    If[routingClass === "Off",
      Return[<|
        "Status"        -> "RoutingDisabled",
        "Reason"        -> "RoutingPolicyOff",
        "RoutingClass"  -> "Off",
        "Requested"     -> nq,
        "RouterVersion" -> $SourceVaultPromptRouterVersion|>]];
    If[routingClass === "Cloud",
      nq = Append[nq, "AllowedTrustDomains" -> {"Cloud"}]];

    (* weak resolver availability check *)
    resolverAvailable =
      (Names["SourceVault`SourceVaultResolve"] =!= {});
    If[!resolverAvailable,
      Return[<|
        "Status"    -> "NeedsModelClassification",
        "Reason"    -> "NoModelResolverAvailable",
        "Requested" -> nq,
        "RouterVersion" -> $SourceVaultPromptRouterVersion|>]];

    (* X2/X3 (model classification): the host resolver matches registry entries
       by Class ("Light-Local" / "Light-Cloud" / "Heavy-Cloud" / "Heavy-Local"),
       not by the spec-12.1 contract keys. Translate WeightClass + trust
       preference into a Class query so an explicit Light/Heavy intent resolves a
       concrete model. Automatic weight keeps the old NeedsModelClassification
       behaviour (we do not guess a tier). *)
    With[{wc = Lookup[nq, "WeightClass", Automatic],
          atd = Lookup[nq, "AllowedTrustDomains", Automatic]},
      Module[{trustKind},
        trustKind = Which[
          privLevel >= 0.5, "Local",                       (* privacy floor wins *)
          ListQ[atd] && MemberQ[atd, "Cloud"] &&
            FreeQ[atd, "Local"] && FreeQ[atd, "Private"], "Cloud",
          ListQ[atd] && (MemberQ[atd, "Local"] || MemberQ[atd, "Private"]), "Local",
          wc === "Heavy", "Cloud",                         (* heavy default -> cloud *)
          True, "Local"];                                  (* light default -> local *)
        registryClass = Which[
          wc === "Light", "Light-" <> trustKind,
          wc === "Heavy", "Heavy-" <> trustKind,
          True, None]]];

    (* delegate the actual model choice to the host resolver *)
    raw = Quiet @ Check[
      Symbol["SourceVault`SourceVaultResolve"]["Model",
        If[StringQ[registryClass], <|"Class" -> registryClass|>, nq]],
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
      iResolveRawTrustDomain[raw],
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
      "RoutingClass"      -> routingClass,
      "ResolvedClass"     -> registryClass,
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

(* schedule \:4ee5\:5916\:306e\:30d7\:30ed\:30f3\:30d7\:30c8\:3092 seed route \:30c6\:30fc\:30d6\:30eb\:3067\:89e3\:6c7a\:3057\:3001Function route \:304c
   \:78ba\:5b9a\:3057\:305f\:5834\:5408\:306b held \:63d0\:6848\:5f0f\:3092\:8fd4\:3059\:3002\:78ba\:5b9a\:3057\:306a\:3044\:30fb\:5bfe\:8c61\:5916\:306a\:3089
   Missing[] \:3092\:8fd4\:3057\:3001\:547c\:3073\:51fa\:3057\:5074\:304c NotDispatched \:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3059\:308b\:3002
   - SourceVaultResolvePromptRoute \:3067 Status==Matched \:304b\:3064 Target.Kind==Function \:3092\:8981\:6c42
   - FunctionId \:304c allowlist (View) \:306b\:5b58\:5728\:3057\:3001UseAsFunctionRoute==True \:304b\:3064
     SideEffectClass \:304c ReadOnly / SafeCreate \:3067\:3042\:308b\:3053\:3068\:3092\:8981\:6c42 (\:5371\:967a\:306a\:526f\:4f5c\:7528\:306f\:81ea\:52d5\:8d77\:52d5\:3057\:306a\:3044)
   - \:5f15\:6570\:306f\:7121\:3057 (FunctionId[]) \:3067 held \:5316\:3002\:73fe\:72b6 SourceVaultNewNotebook \:306f\:30aa\:30d7\:30b7\:30e7\:30f3\:7121\:3057\:3067\:52d5\:304f\:3002 *)
(* Build HoldComplete[sym[args...]] from a symbol and route-declared literal
   Target.Args. With-substitution injects the locals even into the held body,
   so e.g. PackageCommitPlan["github"] is held unevaluated. *)
iSVPRFunctionRouteHeld[sym_, args_List] :=
  Switch[Length[args],
    0, With[{s = sym}, HoldComplete[s[]]],
    1, With[{s = sym, a1 = args[[1]]}, HoldComplete[s[a1]]],
    2, With[{s = sym, a1 = args[[1]], a2 = args[[2]]}, HoldComplete[s[a1, a2]]],
    3, With[{s = sym, a1 = args[[1]], a2 = args[[2]], a3 = args[[3]]},
         HoldComplete[s[a1, a2, a3]]],
    _, With[{s = sym, a = args}, HoldComplete[s[a]]]];
iSVPRFunctionRouteHeld[sym_, _] := With[{s = sym}, HoldComplete[s[]]];

iSVPRProposeFunctionRoute[prompt_String] :=
  Module[{decision, target, fid, callable, sym, sideEffect, held, args},
    decision = Quiet @ Check[
      SourceVaultResolvePromptRoute[prompt], $Failed];
    If[!AssociationQ[decision] ||
        Lookup[decision, "Status", ""] =!= "Matched",
      Return[Missing["NoFunctionRoute"]]];
    target = Lookup[decision, "Target", <||>];
    If[!AssociationQ[target] ||
        Lookup[target, "Kind", ""] =!= "Function",
      Return[Missing["NotFunctionTarget"]]];
    fid = Lookup[target, "FunctionId", Missing[]];
    If[!StringQ[fid], Return[Missing["NoFunctionId"]]];
    callable = iSVPRResolveCallable[fid];
    If[!AssociationQ[callable], Return[Missing["NotInAllowlist"]]];
    If[!TrueQ[callable["UseAsFunctionRoute"]],
      Return[Missing["NotUsableAsFunctionRoute"]]];
    sideEffect = Lookup[callable, "SideEffectClass", "Unknown"];
    If[!MemberQ[{"ReadOnly", "SafeCreate"}, sideEffect],
      (* \:5371\:967a\:306a\:526f\:4f5c\:7528: \:81ea\:52d5\:63d0\:6848\:305b\:305a NotDispatched \:306b\:843d\:3068\:3059 *)
      Return[Missing["NonAutoDispatchSideEffect"]]];
    sym = Lookup[callable, "Symbol", Missing[]];
    If[MissingQ[sym], Return[Missing["NoSymbol"]]];
    (* route-declared Target.Args -> HoldComplete[sym[args...]] (deterministic).
       No Args -> sym[] (backward compatible; sym stays a held symbol). *)
    args = Lookup[target, "Args", {}];
    If[!ListQ[args], args = {}];
    held = iSVPRFunctionRouteHeld[sym, args];
    <|
      "Type"     -> "PromptRouteProposal",
      "Status"   -> "Proposed",
      "Prompt"   -> prompt,
      "Decision" -> <|
        "RouteId" -> Lookup[decision, "RouteId", Missing[]],
        "Method"  -> "DeterministicFunctionRoute",
        "FunctionId" -> fid, "Args" -> args|>,
      "ProposedExpression" -> held,
      "ValidationHints" -> <|
        "ExpectedHeads" -> {sym},
        "SideEffectClass" -> sideEffect|>,
      "RouterPhase"   -> iSVPRImplementationPhase[],
      "RouterVersion" -> $SourceVaultPromptRouterVersion
    |>
  ];
iSVPRProposeFunctionRoute[_] := Missing["BadPrompt"];

SourceVaultProposePromptRoute[prompt_String,
                              opts:OptionsPattern[]] :=
  Module[{isSchedule, periodInfo, periodDays, filterSpec,
          scopeSym, proposal, anchorNote, fnProposal},
    (* schedule prompts: \:5f93\:6765\:901a\:308a SourceVaultUpcomingSchedule \:63d0\:6848 *)
    isSchedule = StringContainsQ[prompt,
      "\:30b9\:30b1\:30b8\:30e5\:30fc\:30eb"] ||
      StringContainsQ[prompt, "\:4e88\:5b9a"] ||
      StringContainsQ[prompt, "schedule"];
    If[!isSchedule,
      (* \:30b9\:30b1\:30b8\:30e5\:30fc\:30eb\:4ee5\:5916\:306f seed route \:30c6\:30fc\:30d6\:30eb (SourceVaultResolvePromptRoute) \:3067
         \:89e3\:6c7a\:3092\:8a66\:307f\:308b\:3002Function route \:304c\:78ba\:5b9a\:3057\:3001\:305d\:306e FunctionId \:304c allowlist \:3067
         ReadOnly / SafeCreate \:306a\:3089\:3001\:305d\:306e\:95a2\:6570\:547c\:3073\:51fa\:3057\:3092 held \:63d0\:6848\:3068\:3057\:3066\:8fd4\:3059\:3002
         \:3053\:308c\:306b\:3088\:308a\:300c\:65b0\:898f\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:300d\:7b49\:306e\:975e\:30b9\:30b1\:30b8\:30e5\:30fc\:30eb\:30d7\:30ed\:30f3\:30d7\:30c8\:3082
         PromptRouter \:7d4c\:7531\:3067\:6240\:5b9a\:306e\:95a2\:6570\:306b\:30eb\:30fc\:30c6\:30a3\:30f3\:30b0\:3055\:308c\:308b\:3002
         \:89e3\:6c7a\:3067\:304d\:306a\:3051\:308c\:3070\:5f93\:6765\:901a\:308a NotDispatched \:3092\:8fd4\:3057 LLM \:751f\:6210\:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3002 *)
      fnProposal = iSVPRProposeFunctionRoute[prompt];
      If[AssociationQ[fnProposal],
        Return[fnProposal]];
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



(* ===================================================================
   Phase 2.2: provider trust-domain classification (spec 12.2)
   Fallback classification used only when the host resolver does not
   declare TrustDomain itself; an explicit TrustDomain always wins.
   =================================================================== *)

(* spec 12.2 mapping: provider/route label -> TrustDomain.
   Only confidently-classifiable labels are mapped; ambiguous ones
   (LocalOpenAICompatible, ExternalAPI) stay Missing so they are
   treated conservatively by the PrivacyLevel >= 0.5 floor. *)
iClassifyProviderTrustDomain[label_String] :=
  Module[{lc},
    lc = ToLowerCase[StringTrim[label]];
    Which[
      MemberQ[{"chatgptcodex", "codex", "chatgptcodexcli",
               "chatgpt codex cli", "chatgpt-codex",
               "chatgpt codex"}, lc],
        "Cloud",
      MemberQ[{"cloudllm", "cloud llm", "claudecodecli",
               "claude code cli", "claudecode", "anthropic",
               "openai"}, lc],
        "Cloud",
      MemberQ[{"privatellm", "private llm", "private"}, lc],
        "Private",
      MemberQ[{"localonly", "local only", "local",
               "localonlyllm"}, lc],
        "Local",
      True,
        Missing["UnclassifiedTrustDomain"]]];

iClassifyProviderTrustDomain[_] :=
  Missing["UnclassifiedTrustDomain"];

(* resolve a TrustDomain from a host-resolver result: an explicit
   TrustDomain wins; otherwise fall back to label classification *)
iResolveRawTrustDomain[raw_Association] :=
  Module[{td, cls, label},
    td = Lookup[raw, "TrustDomain", Missing["NotProvided"]];
    If[StringQ[td], Return[td]];
    (* the registry Class encodes the trust domain asserted at registration
       time: a "*-Local" entry is a confirmed-local model even when the provider
       label (e.g. lmstudio, which can also point at a remote endpoint) is not
       generically classifiable. Per-model Class is more authoritative than the
       generic provider classification, so it wins over the label fallback. *)
    cls = Lookup[raw, "Class", Missing["NoClass"]];
    If[StringQ[cls],
      Which[
        StringContainsQ[cls, "Local"], Return["Local"],
        StringContainsQ[cls, "Cloud"], Return["Cloud"]]];
    label = SelectFirst[
      {Lookup[raw, "Provider", Null],
       Lookup[raw, "ProviderLabel", Null],
       Lookup[raw, "Route", Null],
       Lookup[raw, "Model", Null]},
      StringQ, Null];
    If[StringQ[label],
      iClassifyProviderTrustDomain[label],
      Missing["Unknown"]]];

iResolveRawTrustDomain[_] := Missing["Unknown"];

(* ---- SourceVaultClassifyProviderTrustDomain (spec 12.2) ---- *)

SourceVaultClassifyProviderTrustDomain[label_String] :=
  iClassifyProviderTrustDomain[label];

SourceVaultClassifyProviderTrustDomain[___] :=
  Missing["UnclassifiedTrustDomain"];

(* ===================================================================
   Phase D (UI scope): SaveLastPrompt / SearchPromptRoutes /
   FormatPromptRouteList

   spec 10.1 / 10.2 / 21.7. These build on the existing capture,
   privacy, registry, and execute APIs:
   - SourceVaultCaptureLastPromptRun   (last successful run)
   - SourceVaultResolvePromptPrivacy   (privacy tracking)
   - SourceVaultRegisterPromptRoute    (atomic registry write)
   - SourceVaultListPromptRoutes       (read registry)
   - SourceVaultExecutePromptRoute     (run a route)

   NOTE (handoff): "Encrypt" -> True is a placeholder. Encryption of
   prompt / memo / target at rest (spec physical-storage-extension
   section 1.2, KeyRef "SourceVault:master:v1") is NOT implemented.
   No master-key infrastructure exists yet in NBAccess or SourceVault.
   Until that lands, SaveLastPrompt with "Encrypt" -> True returns
   Status NotImplemented rather than silently storing plaintext.
   =================================================================== *)

iSVPRSaveDir[] :=
  FileNameJoin[{
    SourceVault`$SourceVaultRoots["PrivateVault"],
    "promptrouter", "saved"}];

(* derive a stable-ish route id from the prompt + timestamp *)
iSVPRMakeSavedRouteId[prompt_String] :=
  "promptroute-saved-" <>
    StringTake[Hash[iSVPRNormalizePrompt[prompt], "SHA256", "HexString"], 12];
iSVPRMakeSavedRouteId[_] :=
  "promptroute-saved-" <> StringTake[CreateUUID[], 8];

(* extract the expression/function the run produced, as a string
   suitable for writing into an Input cell. Falls back gracefully. *)
iSVPRRunTargetExpr[run_Association] :=
  Module[{route, target, expr},
    route  = Lookup[run, "Route", <||>];
    If[!AssociationQ[route], route = <||>];
    target = Lookup[run, "Target", Lookup[route, "Target", <||>]];
    If[!AssociationQ[target], target = <||>];
    expr = Which[
      StringQ[Lookup[run, "ProposedExpressionString", Missing[]]],
        Lookup[run, "ProposedExpressionString"],
      StringQ[Lookup[run, "TargetExprString", Missing[]]],
        Lookup[run, "TargetExprString"],
      AssociationQ[target] &&
        StringQ[Lookup[target, "FunctionSymbol", Missing[]]],
        Lookup[target, "FunctionSymbol"] <> "[]",
      True, Missing["NoTargetExpr"]];
    expr];
iSVPRRunTargetExpr[_] := Missing["NoTargetExpr"];

(* ------------------------------------------------------------
   encryption-at-rest helpers (Phase SV-E3 / spec v18 §9)
   ------------------------------------------------------------ *)

(* 暗号モジュールがロード済みかつ at-rest 鍵が初期化済みか *)
iSVPREncryptionAvailableQ[] :=
  TrueQ@Quiet@Check[
    Length[DownValues[SourceVault`SourceVaultEncryptedPut]] > 0 &&
     ValueQ[SourceVault`$SourceVaultDefaultAtRestKeyRef] &&
     AssociationQ[NBAccess`NBKeyStatus[SourceVault`$SourceVaultDefaultAtRestKeyRef]],
    False];

(* route の機密 (raw prompt / TargetExprString / Target) を暗号化し inline payload に置換。
   平文 fallback は行わず、失敗時は Ok->False を返す。Memo は表示ラベルとして平文維持。 *)
iSVPRApplyEncryption[route_Association, rawPrompt_, targetExpr_, privLevel_] :=
  Module[{payload, put, rec, newRoute, leak},
    payload = <|
      "Prompt"           -> If[StringQ[rawPrompt], rawPrompt, Missing["NotStored"]],
      "TargetExprString" -> If[StringQ[targetExpr], targetExpr, Missing["NoTargetExpr"]],
      "Target"           -> Lookup[route, "Target", <||>]|>;
    put = SourceVault`SourceVaultEncryptedPut[payload,
       "PrivacyLevel" -> privLevel, "ContentType" -> "PromptRoute",
       "Persist" -> False, "SensitiveFields" -> {"Prompt", "TargetExprString"}];
    If[! AssociationQ[put] || Lookup[put, "Status", ""] =!= "Stored",
      Return[<|"Ok" -> False, "Reason" -> Lookup[put, "Reason", "EncryptedPutFailed"]|>]];
    rec = put["Record"];
    newRoute = route;
    newRoute["Matcher", "Examples"]      = {};
    newRoute["TargetExprString"]         = Missing["Encrypted"];
    newRoute["Target"]                   = <||>;
    newRoute["ParameterTemplate"]        = Missing["Encrypted"];
    newRoute["ParameterSlots"]           = {};
    newRoute["EncryptedPayload"]         = rec;
    newRoute["Privacy", "PromptStorageClass"] = "Encrypted";
    newRoute["Privacy", "RawPromptStored"]    = False;
    leak = SourceVault`SourceVaultAssertNoPlaintextLeak[
       newRoute, payload, {"Prompt", "TargetExprString"}];
    If[! TrueQ[Lookup[leak, "NoLeak", False]],
      Return[<|"Ok" -> False, "Reason" -> "PlaintextLeakInRoute",
        "Leaked" -> Lookup[leak, "Leaked", {}]|>]];
    <|"Ok" -> True, "Route" -> newRoute|>];

(* 暗号 route の inline EncryptedPayload を復号する。MAC 検証を経て plaintext を返す。 *)
SourceVaultDecryptPromptRoute[route_Association] :=
  Module[{rec},
    rec = Lookup[route, "EncryptedPayload", Missing["NotEncrypted"]];
    If[! AssociationQ[rec],
      Return[<|"Status" -> "Error", "Reason" -> "NotEncryptedRoute",
        "PlaintextReturned" -> False|>]];
    SourceVault`SourceVaultDecryptRecord[rec]];
SourceVaultDecryptPromptRoute[___] :=
  <|"Status" -> "Error", "Reason" -> "InvalidArguments", "PlaintextReturned" -> False|>;

Options[SaveLastPrompt] = {
  "Channel" -> Automatic,
  "Encrypt" -> False,
  "DryRun"  -> False,
  "RouteId" -> Automatic,
  "ReplayClass" -> Automatic,
  "PromptText" -> Automatic,
  "TargetExprString" -> Automatic,
  "ForceNewVersion" -> False,
  "Auto" -> False
};

SaveLastPrompt[memo_String, opts:OptionsPattern[]] :=
  Module[{encrypt, channel, dryRun, routeId, capture, run, rawPrompt,
          privComponents, privRes, privLevel, cloudFallback, allowedDomains,
          ts, targetExpr, route, regResult, promptFingerprint,
          promptTextOpt, targetExprOpt, forceNew, autoMode,
          gid, versionNum, deterministicId, existingGroup,
          ctxBinding, safetyRes, replaySafety, contextBinding},

    encrypt = TrueQ[OptionValue[SaveLastPrompt, {opts}, "Encrypt"]];
    promptTextOpt = OptionValue[SaveLastPrompt, {opts}, "PromptText"];
    targetExprOpt = OptionValue[SaveLastPrompt, {opts}, "TargetExprString"];
    forceNew = TrueQ[OptionValue[SaveLastPrompt, {opts}, "ForceNewVersion"]];
    autoMode = TrueQ[OptionValue[SaveLastPrompt, {opts}, "Auto"]];
    (* encryption-at-rest: 機密 (raw prompt / TargetExprString) を SourceVaultEncryptedPut で
       encrypt-then-MAC し、route に inline EncryptedPayload として埋める (後段で適用)。
       モジュール未ロード時は平文 fallback せず明示エラー。 *)
    If[encrypt && ! iSVPREncryptionAvailableQ[],
      Return[<|"Status" -> "Failed",
        "Reason" -> "EncryptionModuleNotAvailable",
        "Hint" ->
          "SourceVault encryption modules (SourceVault_encryptedstore.wl) が未ロード、" <>
          "または SourceVaultInitializeEncryption[] が未実行です。"|>]];

    dryRun  = TrueQ[OptionValue[SaveLastPrompt, {opts}, "DryRun"]];
    routeId = OptionValue[SaveLastPrompt, {opts}, "RouteId"];

    (* fetch the last successful prompt run. The auto-save path supplies
       an explicit "PromptText"; if no PromptRun has been recorded yet
       (the plain LLM ClaudeEval path does not record one) we tolerate
       an empty run and rely on the override + shared expr string. *)
    capture = SourceVaultCaptureLastPromptRun[];
    If[!AssociationQ[capture] ||
       Lookup[capture, "Status", ""] =!= "OK",
      If[StringQ[promptTextOpt],
        run = <||>,
        Return[<|"Status" -> "Failed",
          "Reason" -> "NoLastPromptRun",
          "Hint" ->
            "No recent successful ClaudeEval / ContinueEval run found to save."|>]],
      run = Lookup[capture, "PromptRun", <||>]];
    If[!AssociationQ[run], run = <||>];

    (* raw prompt: explicit override wins, else stored raw, else note *)
    rawPrompt = Which[
      StringQ[promptTextOpt],                          promptTextOpt,
      StringQ[Lookup[run, "RawPrompt", Missing[]]],    run["RawPrompt"],
      StringQ[Lookup[run, "PromptText", Missing[]]],   run["PromptText"],
      True,                                            Missing["NotStored"]];

    (* fingerprint of the prompt actually being saved. The captured
       run can be unrelated to an explicit "PromptText": the plain
       LLM ClaudeEval path records no PromptRun, so the capture may
       return a run that is days old. Reusing that run's PromptHash
       (or its Privacy / Target) would bind this route to a prompt
       it never saw. Recompute from the raw prompt with the same
       normalization + hash as SourceVaultPromptRunRecord, and drop
       the run entirely when its hash does not match. *)
    promptFingerprint = If[StringQ[rawPrompt],
      "sha256:" <> Hash[iSVPRNormalizePrompt[rawPrompt],
        "SHA256", "HexString"],
      Lookup[run, "PromptHash", Missing["NoHash"]]];
    If[StringQ[promptTextOpt] &&
       StringQ[Lookup[run, "PromptHash", Missing[]]] &&
       run["PromptHash"] =!= promptFingerprint,
      run = <||>];

    (* privacy tracking (spec 11): resolve from whatever the run
       recorded; default components are empty -> level 0.0 *)
    privComponents = Lookup[run, "Privacy", <||>];
    If[!AssociationQ[privComponents], privComponents = <||>];
    privRes = SourceVaultResolvePromptPrivacy[privComponents];
    privLevel      = Lookup[privRes, "PrivacyLevel", 0.0];
    cloudFallback  = Lookup[privRes, "CloudFallback", "Ask"];
    allowedDomains = Lookup[privRes, "AllowedTrustDomains", Automatic];

    (* channel: explicit option wins; else privacy-derived. A
       prompt that cannot go to the cloud is saved to the private
       channel so the search index keeps it out of cloud routing. *)
    channel = OptionValue[SaveLastPrompt, {opts}, "Channel"];
    If[channel === Automatic || !StringQ[channel],
      channel = If[NumericQ[privLevel] && privLevel >= 0.5,
        "private", "public"]];

    ts = iSVPRTimestamp[];

    (* target expression: explicit override wins; else the run's
       proposed/target string; else the shared expr ClaudeEval recorded
       for the most recent PromptRouter / runtime release. This is the
       root of Replayable (no-LLM replay). *)
    targetExpr = Which[
      StringQ[targetExprOpt], targetExprOpt,
      True,                   iSVPRRunTargetExpr[run]];
    If[!StringQ[targetExpr],
      Module[{shared},
        shared = Quiet @ Check[
          Symbol["ClaudeCode`$ClaudeEvalLastProposedExprString"],
          Missing["NotCaptured"]];
        If[StringQ[shared] && shared =!= "", targetExpr = shared]]];

    (* ReplaySafety: is the expression a pure function of the live world,
       or did it bake a transient notebook input as a literal? The context
       binding ClaudeEval recorded for this run is the authoritative cue. *)
    (* ClaudeEval records the surrounding notebook context it captured
       for this run in ClaudeCode`$ClaudeEvalNotebookContext. We read it
       directly (weak, no dependency) as the authoritative cue for
       whether the generated expression baked a transient cell as a
       literal. No new claudecode global is required. *)
    ctxBinding = Module[{ctx},
      ctx = Quiet @ Check[
        Symbol["ClaudeCode`$ClaudeEvalNotebookContext"], ""];
      If[!StringQ[ctx], ctx = ""];
      <|"ContextText" -> ctx, "UsedNotebookContext" -> (ctx =!= "")|>];
    safetyRes = SourceVaultClassifyPromptReplaySafety[
      If[StringQ[rawPrompt], rawPrompt, ""],
      If[StringQ[targetExpr], targetExpr, ""], ctxBinding];
    replaySafety  = Lookup[safetyRes, "ReplaySafety", "Unknown"];
    contextBinding = Lookup[safetyRes, "ContextBinding", <||>];

    (* version grouping: every save is a new version sharing a
       PromptGroupId, never overwriting. The first save of a never-seen
       prompt keeps the deterministic id (back-compat / tests); later
       saves and all auto-saves create a versioned sibling. *)
    gid = iSVPRPromptGroupId[If[StringQ[rawPrompt], rawPrompt, memo]];
    existingGroup = If[StringQ[gid], iSVPRGroupRoutes[gid], {}];
    deterministicId = iSVPRMakeSavedRouteId[
      If[StringQ[rawPrompt], rawPrompt, memo]];
    versionNum = If[StringQ[gid], iSVPRNextVersion[gid], 1];
    If[!StringQ[routeId] || routeId === "",
      routeId = Which[
        forceNew,             iSVPRMakeVersionedRouteId[
                                If[StringQ[rawPrompt], rawPrompt, memo]],
        existingGroup === {}, deterministicId,
        True,                 iSVPRMakeVersionedRouteId[
                                If[StringQ[rawPrompt], rawPrompt, memo]]]];

    (* build the PromptRoute. We store the raw prompt as an Example
       and the memo as a first-class field for searching/display.
       Plaintext is acceptable here per design: functions/memos
       rarely need secrecy. PrivacyLevel/CloudFallback are recorded
       so the router still respects privacy at match time. *)
    route = <|
      "Type"         -> "PromptRoute",
      "RouteId"      -> routeId,
      "RouteVersion" -> 1,
      "SchemaVersion"-> 1,
      "Memo"         -> memo,
      "CreatedAt"    -> ts,
      "UpdatedAt"    -> ts,
      "PromptGroupId"-> gid,
      "Version"      -> versionNum,
      "Primary"      -> False,
      "AutoExecute"  -> False,
      "ReplaySafety" -> replaySafety,
      "ContextBinding"-> contextBinding,
      "Source"       -> If[autoMode, "AutoCapture", "ManualSaveLastPrompt"],
      "Matcher" -> <|
        "Kind" -> "SavedPrompt",
        "PromptFingerprints" -> {promptFingerprint},
        "Examples" ->
          If[StringQ[rawPrompt], {rawPrompt}, {}]
      |>,
      "Target" ->
        Module[{tgt = Lookup[run, "Target", Null],
                rt = Lookup[run, "Route", Null]},
          Which[
            AssociationQ[tgt], tgt,
            AssociationQ[rt] && AssociationQ[Lookup[rt, "Target", Null]],
              rt["Target"],
            True, <||>]],
      "TargetExprString" ->
        If[StringQ[targetExpr], targetExpr, Missing["NoTargetExpr"]],
      "ReplayClass" ->
        Module[{userClass, autoClass, paramInfo},
          userClass = OptionValue[SaveLastPrompt, {opts}, "ReplayClass"];
          autoClass = If[StringQ[targetExpr],
            iSVPRClassifyReplay[targetExpr], "HeavyLLM"];
          (* Replayable \:3068\:5224\:5b9a\:3055\:308c\:305f\:5f0f\:306b\:65e5\:4ed8\:30b9\:30ed\:30c3\:30c8\:304c\:3042\:308c\:3070 LightLLM \:306b\:683c\:4e0a\:3052\:3002
             (\:9aa8\:683c\:306f\:56fa\:5b9a\:3060\:304c\:65e5\:4ed8\:30d1\:30e9\:30e1\:30fc\:30bf\:3092\:5dee\:3057\:66ff\:3048\:3066\:518d\:5b9f\:884c\:3067\:304d\:308b) *)
          If[autoClass === "Replayable" && StringQ[targetExpr],
            paramInfo = iSVPRParameterize[targetExpr];
            If[Length[Lookup[paramInfo, "Slots", {}]] > 0,
              autoClass = "LightLLM"]];
          (* ContextBound: \:51cd\:7d50\:5f0f\:306f\:53e4\:3044\:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:3092\:518d\:751f\:3057\:3066\:3057\:307e\:3046\:306e\:3067
             \:5fc5\:305a HeavyLLM (\:6bce\:56de\:73fe\:5728\:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:3067 LLM \:518d\:89e3\:6c7a) \:306b\:843d\:3068\:3059 *)
          If[replaySafety === "ContextBound", autoClass = "HeavyLLM"];
          (* \:81ea\:52d5\:5224\:5b9a\:3092\:512a\:5148\:3001\:30e6\:30fc\:30b6\:30fc\:6307\:5b9a (Automatic \:4ee5\:5916) \:304c\:3042\:308c\:3070\:4e0a\:66f8\:304d *)
          If[MemberQ[{"Replayable", "LightLLM", "HeavyLLM"}, userClass],
            userClass, autoClass]],
      "ParameterTemplate" ->
        If[StringQ[targetExpr],
          Lookup[iSVPRParameterize[targetExpr], "Template", targetExpr],
          Missing["NoTemplate"]],
      "ParameterSlots" ->
        If[StringQ[targetExpr],
          Lookup[iSVPRParameterize[targetExpr], "Slots", {}],
          {}],
      "Privacy" -> <|
        "PrivacyLevel"        -> privLevel,
        "PrivacyOrigin"       -> Lookup[privRes, "PrivacyOrigin", {}],
        "AllowedTrustDomains" -> allowedDomains,
        "CloudFallback"       -> cloudFallback,
        "RawPromptStored"     -> StringQ[rawPrompt],
        "PromptStorageClass"  -> "Plaintext"
      |>
    |>;

    (* encryption-at-rest: route の機密 field を暗号化し inline EncryptedPayload に置換 *)
    If[encrypt,
      Module[{encRes},
        encRes = iSVPRApplyEncryption[route, rawPrompt, targetExpr, privLevel];
        If[!TrueQ[Lookup[encRes, "Ok", False]],
          Return[<|"Status" -> "Failed",
            "Reason" -> Lookup[encRes, "Reason", "EncryptionFailed"],
            "RouteId" -> routeId|>]];
        route = encRes["Route"]]];

    If[dryRun,
      Return[<|"Status" -> "DryRun", "RouteId" -> routeId,
        "Channel" -> channel, "Memo" -> memo,
        "PrivacyLevel" -> privLevel,
        "PromptGroupId" -> gid, "Version" -> versionNum,
        "ReplaySafety" -> replaySafety,
        "PromptStorageClass" -> Lookup[route["Privacy"], "PromptStorageClass", "Plaintext"],
        "Route" -> route|>]];

    regResult = SourceVaultRegisterPromptRoute[
      route, "DryRun" -> False, "Channel" -> channel];
    If[Lookup[regResult, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[regResult, "Reason", "RegisterFailed"],
        "RouteId" -> routeId, "Channel" -> channel|>]];

    <|"Status" -> "OK", "RouteId" -> routeId, "Channel" -> channel,
      "Memo" -> memo, "PrivacyLevel" -> privLevel,
      "PromptGroupId" -> gid, "Version" -> versionNum,
      "ReplaySafety" -> replaySafety,
      "ReplayClass" -> Lookup[route, "ReplayClass", "HeavyLLM"],
      "ParameterSlots" -> Lookup[route, "ParameterSlots", {}],
      "TargetExprString" -> Lookup[route, "TargetExprString", Missing["NoTargetExpr"]],
      "PromptStorageClass" -> Lookup[route["Privacy"], "PromptStorageClass", "Plaintext"],
      "PlaintextPersisted" -> (Lookup[route["Privacy"], "PromptStorageClass", "Plaintext"] =!= "Encrypted"),
      "Action" -> Lookup[regResult, "Action", "Added"]|>
  ];

SaveLastPrompt[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" -> "Expected SaveLastPrompt[memo_String, opts]."|>;

(* ---------- search ---------- *)

(* parse a date-range Association <|"From"->_, "To"->_|> into a pair
   of DateObjects. Accepts date strings or DateObjects. Missing parts
   become -inf / +inf. Returns {fromDO|None, toDO|None}. *)
iSVPRParseDateRange[spec_] :=
  Module[{from, to, toDO},
    If[!AssociationQ[spec], Return[{None, None}]];
    toDO = Function[v,
      Which[
        MatchQ[v, _DateObject], v,
        StringQ[v], Quiet @ Check[DateObject[v], None],
        True, None]];
    from = toDO[Lookup[spec, "From", Missing[]]];
    to   = toDO[Lookup[spec, "To", Missing[]]];
    {from, to}];

(* test a route's CreatedAt/UpdatedAt against a parsed range *)
iSVPRRouteDateInRange[route_Association, field_String, spec_] :=
  Module[{from, to, raw, d},
    If[!AssociationQ[spec], Return[True]];
    {from, to} = iSVPRParseDateRange[spec];
    If[from === None && to === None, Return[True]];
    raw = Lookup[route, field, Missing[]];
    d = Which[
      MatchQ[raw, _DateObject], raw,
      StringQ[raw], Quiet @ Check[DateObject[raw], Missing[]],
      True, Missing[]];
    If[!MatchQ[d, _DateObject], Return[False]];
    And[
      from === None || DateObjectQ[from] && (from <= d),
      to   === None || DateObjectQ[to]   && (d <= to)]];
iSVPRRouteDateInRange[_, _, _] := True;

(* substring match over prompt examples + memo *)
iSVPRRouteTextMatch[route_Association, query_String] :=
  Module[{matcher, examples, memo, pool},
    If[query === "", Return[True]];
    matcher  = Lookup[route, "Matcher", <||>];
    examples = If[AssociationQ[matcher],
      Lookup[matcher, "Examples", {}], {}];
    If[!ListQ[examples], examples = {}];
    memo = Lookup[route, "Memo", ""];
    pool = DeleteCases[
      Join[Select[examples, StringQ],
           {If[StringQ[memo], memo, ""],
            Lookup[route, "RouteId", ""]}],
      ""];
    AnyTrue[pool, StringContainsQ[#, query] &]];
iSVPRRouteTextMatch[_, _] := False;

Options[SourceVaultSearchPromptRoutes] = {
  "Channel"     -> All,
  "IncludeSeed" -> True,
  "CreatedAt"   -> Missing[],
  "UpdatedAt"   -> Missing[]
};

SourceVaultSearchPromptRoutes[query_String, opts:OptionsPattern[]] :=
  Module[{channel, includeSeed, createdSpec, updatedSpec, channels,
          routes},
    channel     = OptionValue[SourceVaultSearchPromptRoutes, {opts}, "Channel"];
    includeSeed = TrueQ[OptionValue[
      SourceVaultSearchPromptRoutes, {opts}, "IncludeSeed"]];
    createdSpec = OptionValue[SourceVaultSearchPromptRoutes, {opts}, "CreatedAt"];
    updatedSpec = OptionValue[SourceVaultSearchPromptRoutes, {opts}, "UpdatedAt"];

    channels = Which[
      channel === All, {"public", "private", "local"},
      StringQ[channel], {channel},
      ListQ[channel], Select[channel, StringQ],
      True, {"public"}];

    routes = Join @@ Map[
      Function[ch,
        With[{r = Quiet @ Check[
            SourceVaultListPromptRoutes[
              "Channel" -> ch, "IncludeSeed" -> includeSeed], {}]},
          If[ListQ[r], Select[r, AssociationQ], {}]]],
      channels];

    (* dedupe by RouteId *)
    routes = DeleteDuplicatesBy[routes,
      Lookup[#, "RouteId", CreateUUID[]] &];

    Select[routes,
      Function[rt,
        iSVPRRouteTextMatch[rt, query] &&
        iSVPRRouteDateInRange[rt, "CreatedAt", createdSpec] &&
        iSVPRRouteDateInRange[rt, "UpdatedAt", updatedSpec]]]
  ];

SourceVaultSearchPromptRoutes[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" ->
      "Expected SourceVaultSearchPromptRoutes[query_String, opts]."|>;

(* ---------- format / display ---------- *)

(* one example prompt string for display (first example or memo) *)
iSVPRRouteDisplayPrompt[route_Association] :=
  Module[{matcher, examples, kws},
    matcher  = Lookup[route, "Matcher", <||>];
    examples = If[AssociationQ[matcher],
      Lookup[matcher, "Examples", {}], {}];
    (* 1. \:4fdd\:5b58\:6e08\:307f\:30d7\:30ed\:30f3\:30d7\:30c8\:4f8b (SaveLastPrompt \:7531\:6765) \:304c\:3042\:308c\:3070\:305d\:308c\:3092\:8868\:793a *)
    If[ListQ[examples] && Length[examples] > 0 && StringQ[First[examples]],
      Return[First[examples]]];
    (* 2. seed route \:7b49\:3067\:4f8b\:304c\:7121\:3044\:5834\:5408\:306f Matcher.KeywordsAny \:306e\:5148\:982d\:3092\:4ee3\:8868\:8868\:793a
       (RouteId \:3088\:308a\:30e6\:30fc\:30b6\:306b\:5206\:304b\:308a\:3084\:3059\:3044\:30ad\:30fc\:30ef\:30fc\:30c9) *)
    kws = If[AssociationQ[matcher],
      Lookup[matcher, "KeywordsAny", {}], {}];
    If[ListQ[kws] && Length[kws] > 0 && StringQ[First[kws]],
      Return[First[kws]]];
    (* 3. \:6700\:7d42 fallback: RouteId *)
    Lookup[route, "RouteId", ""]];
iSVPRRouteDisplayPrompt[_] := "";

(* route \:306e Target \:304b\:3089\:5b9f\:884c\:5bfe\:8c61\:306e\:95a2\:6570 ID \:3092\:89e3\:6c7a\:3059\:308b (\:8868\:793a\:30fb\:5b9f\:884c\:5f0f\:7528)\:3002
   Kind \:306b\:5fdc\:3058\:3066 FunctionId / AdapterFunctionId / TabularQuery \:5bfe\:5fdc\:95a2\:6570\:3092\:8fd4\:3059\:3002 *)
iSVPRRouteTargetFunctionId[route_Association] :=
  Module[{target, kind},
    target = Lookup[route, "Target", <||>];
    If[!AssociationQ[target], Return[Missing["NoTarget"]]];
    kind = Lookup[target, "Kind", "Function"];
    Which[
      kind === "Function",
        Lookup[target, "FunctionId",
          Lookup[target, "FunctionSymbol", Missing["NoFunctionId"]]],
      kind === "Intent",
        Lookup[target, "AdapterFunctionId", Missing["NoAdapter"]],
      kind === "TabularQuery",
        (* schedule \:306a\:3069\:306e\:8868\:5f62\:30af\:30a8\:30ea\:306f SourceVaultUpcomingSchedule \:3092\:4ee3\:8868\:3068\:3059\:308b *)
        "SourceVaultUpcomingSchedule",
      True, Missing["UnknownKind"]]];
iSVPRRouteTargetFunctionId[_] := Missing["BadRoute"];

(* the function-call expression string for the ToInput button *)
iSVPRRouteInputExpr[route_Association, displayPrompt_String] :=
  Module[{te, target, sym, fid, matcher, examples, promptText, rid},
    rid = Lookup[route, "RouteId", ""];
    (* 1. \:4fdd\:5b58\:6e08\:307f\:306e\:5b8c\:5168\:5f0f\:6587\:5b57\:5217\:304c\:3042\:308c\:3070\:305d\:308c\:3092\:512a\:5148 *)
    te = Lookup[route, "TargetExprString", Missing[]];
    If[StringQ[te], Return[te]];
    target = Lookup[route, "Target", <||>];
    (* 2. \:65e7\:5f62\:5f0f: Target.FunctionSymbol \:304c\:3042\:308c\:3070 sym[] *)
    sym = If[AssociationQ[target],
      Lookup[target, "FunctionSymbol", Missing[]], Missing[]];
    If[StringQ[sym], Return[sym <> "[]"]];
    (* 3. Function route: Target.Kind / FunctionId \:304b\:3089\:5b9f\:884c\:5f0f\:3092\:7d44\:307f\:7acb\:3066\:308b *)
    fid = iSVPRRouteTargetFunctionId[route];
    If[StringQ[fid] && AssociationQ[target] &&
        Lookup[target, "Kind", "Function"] === "Function",
      Return[fid <> "[]"]];
    (* 4. \:4fdd\:5b58\:30d7\:30ed\:30f3\:30d7\:30c8\:30fbIntent\:30fbTabularQuery: \:30d7\:30ed\:30f3\:30d7\:30c8\:6587\:3092 ClaudeEval \:3067\:5b9f\:884c\:3002
       \:30d7\:30ed\:30f3\:30d7\:30c8\:6587\:306e\:51b3\:5b9a\:9806: (a) \:6e21\:3055\:308c\:305f displayPrompt (RouteId \:3068\:7570\:306a\:308b\:5834\:5408)
       (b) Matcher.Examples \:306e\:5148\:982d (c) Matcher.KeywordsAny \:306e\:5148\:982d\:3002
       \:3044\:305a\:308c\:3082 RouteId \:306b\:843d\:3061\:306a\:3044\:3088\:3046\:751f\:53d6\:5f97\:3059\:308b\:3002 *)
    matcher = Lookup[route, "Matcher", <||>];
    examples = If[AssociationQ[matcher],
      Lookup[matcher, "Examples", {}], {}];
    promptText = Which[
      StringQ[displayPrompt] && displayPrompt =!= "" && displayPrompt =!= rid,
        displayPrompt,
      ListQ[examples] && Length[examples] > 0 && StringQ[First[examples]],
        First[examples],
      AssociationQ[matcher] &&
        MatchQ[Lookup[matcher, "KeywordsAny", {}], {_String, ___}],
        First[Lookup[matcher, "KeywordsAny"]],
      True, Missing["NoPrompt"]];
    If[StringQ[promptText] && promptText =!= "",
      Return["ClaudeEval[\"" <>
        StringReplace[promptText, "\"" -> "\\\""] <> "\"]"]];
    "(* no target expression *)"];

(* \:5f15\:6570 1 \:7248: \:5f8c\:65b9\:4e92\:63db\:3002\:8868\:793a\:30d7\:30ed\:30f3\:30d7\:30c8\:3092\:5185\:90e8\:3067\:89e3\:6c7a\:3057\:3066\:79fb\:8b72 *)
iSVPRRouteInputExpr[route_Association] :=
  iSVPRRouteInputExpr[route, iSVPRRouteDisplayPrompt[route]];
iSVPRRouteInputExpr[_] := "(* no target expression *)";

(* ToInput \:30dc\:30bf\:30f3\:7528: \:4fdd\:5b58\:6642\:306b\:5b9f\:969b\:306b\:5b9f\:884c\:3055\:308c\:305f\:63d0\:6848\:5f0f\:3092\:8fd4\:3059\:3002
   \:512a\:5148\:9806: route.TargetExprString (\:4fdd\:5b58\:3055\:308c\:305f\:63d0\:6848\:5f0f) > Target.FunctionSymbol[]
   > Function route \:306e FunctionId[] \:3002\:3044\:305a\:308c\:3082\:7121\:3051\:308c\:3070\:3001\:63d0\:6848\:5f0f\:304c\:8a18\:9332\:3055\:308c\:3066\:3044\:306a\:3044
   \:65e7\:30eb\:30fc\:30c8\:306a\:306e\:3067\:30d7\:30ed\:30f3\:30d7\:30c8\:5b9f\:884c\:5f0f (ClaudeEval[...]) \:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3059\:308b\:3002 *)
iSVPRRouteProposedExpr[route_Association] :=
  Module[{te, target, sym, fid},
    te = Lookup[route, "TargetExprString", Missing[]];
    If[StringQ[te] && te =!= "", Return[te]];
    target = Lookup[route, "Target", <||>];
    sym = If[AssociationQ[target],
      Lookup[target, "FunctionSymbol", Missing[]], Missing[]];
    If[StringQ[sym], Return[sym <> "[]"]];
    fid = iSVPRRouteTargetFunctionId[route];
    If[StringQ[fid] && AssociationQ[target] &&
        Lookup[target, "Kind", "Function"] === "Function",
      Return[fid <> "[]"]];
    (* \:63d0\:6848\:5f0f\:672a\:8a18\:9332: \:30d7\:30ed\:30f3\:30d7\:30c8\:5b9f\:884c\:5f0f\:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af *)
    iSVPRRouteInputExpr[route, iSVPRRouteDisplayPrompt[route]]];
iSVPRRouteProposedExpr[_] := "(* no proposed expression *)";

(* privacy label, env-independent English word *)
iSVPRPrivacyLabel[route_Association] :=
  Module[{lv},
    lv = Lookup[Lookup[route, "Privacy", <||>], "PrivacyLevel", 0.0];
    Which[
      !NumericQ[lv], "Unknown",
      lv >= 0.75, "Secret",
      lv >= 0.5,  "Private",
      lv > 0.0,   "Restricted",
      True,       "Public"]];
iSVPRPrivacyLabel[_] := "Unknown";

Options[SourceVaultFormatPromptRouteList] = {};

SourceVaultFormatPromptRouteList[routes_List, opts:OptionsPattern[]] :=
  Module[{filtered, cols, header, body},
    filtered = Select[Map[iSVPRNormalizeRoute, routes], AssociationQ];
    If[filtered === {},
      Return[Style[
        "\:8a72\:5f53\:3059\:308b\:4fdd\:5b58\:6e08\:307f\:30d7\:30ed\:30f3\:30d7\:30c8\:306f\:3042\:308a\:307e\:305b\:3093\:3002",
        FontFamily -> "Yu Gothic UI"]]];
    cols = {"Prompt", "Memo", "Target", "\:4f5c\:6210/\:66f4\:65b0",
            "Privacy", "State", "Actions"};
    header = Map[
      Style[#, Bold, FontFamily -> "Yu Gothic UI"] &, cols];
    body = Map[
      Function[rt,
        Module[{prompt, memo, targetSym, created, updated, privLabel,
                routeId, channel, inputExpr, promptEval, proposedExpr,
                replayClass},
          prompt   = iSVPRRouteDisplayPrompt[rt];
          memo     = Lookup[rt, "Memo", ""];
          (* Target \:8868\:793a: FunctionSymbol \:304c\:7121\:3044 seed route \:3067\:3082
             Kind/FunctionId \:304b\:3089\:5b9f\:884c\:5bfe\:8c61\:95a2\:6570\:3092\:8868\:793a\:3059\:308b *)
          targetSym = Module[{fs, fid},
            fs = Lookup[Lookup[rt, "Target", <||>], "FunctionSymbol", Missing[]];
            If[StringQ[fs], fs,
              fid = iSVPRRouteTargetFunctionId[rt];
              If[StringQ[fid], fid, ""]]];
          created  = Lookup[rt, "CreatedAt", ""];
          updated  = Lookup[rt, "UpdatedAt", ""];
          privLabel = iSVPRPrivacyLabel[rt];
          routeId  = Lookup[rt, "RouteId", ""];
          channel  = Lookup[rt, "_Channel", "public"];
          inputExpr = iSVPRRouteInputExpr[rt, prompt];
          (* Prompt \:30af\:30ea\:30c3\:30af\:7528: \:30d7\:30ed\:30f3\:30d7\:30c8\:6587\:3092 ClaudeEval \:3067\:5b9f\:884c\:3059\:308b\:5f0f *)
          promptEval = If[StringQ[prompt] && prompt =!= "",
            "ClaudeEval[\"" <> StringReplace[prompt, "\"" -> "\\\""] <> "\"]",
            Missing["NoPrompt"]];
          (* ToInput \:7528: \:4fdd\:5b58\:6642\:306b\:5b9f\:884c\:3055\:308c\:305f\:63d0\:6848\:5f0f (ProposedExpressionString /
             TargetExprString)\:3002\:7121\:3051\:308c\:3070 iSVPRRouteInputExpr \:306e\:7d50\:679c\:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af *)
          proposedExpr = iSVPRRouteProposedExpr[rt];
          replayClass = Lookup[rt, "ReplayClass", "HeavyLLM"];
          {
            (* Prompt \:5217: \:30af\:30ea\:30c3\:30af\:3067 ClaudeEval[\"<\:30d7\:30ed\:30f3\:30d7\:30c8>\"] \:3092\:5165\:529b\:30bb\:30eb\:306b\:66f8\:304f *)
            If[StringQ[promptEval],
              With[{pe = promptEval},
                Tooltip[
                  Button[
                    Style[iSVPRTruncateDisplay[prompt, 42],
                      FontFamily -> "Yu Gothic UI"],
                    Module[{target = InputNotebook[]},
                      If[Head[target] === NotebookObject,
                        NBAccess`NBWriteInputCellAndMaybeEvaluate[
                          target, pe, False]]],
                    Appearance -> "Frameless",
                    BaseStyle -> {},
                    Method -> "Queued"],
                  prompt]],
              Tooltip[
                Style[iSVPRTruncateDisplay[prompt, 42], FontFamily -> "Yu Gothic UI"],
                prompt]],
            (* Memo: editable in place (auto-saved prompts have no memo;
               add/revise here and 保存 writes it back to the registry) *)
            With[{rid = routeId, m0 = If[StringQ[memo], memo, ""]},
              DynamicModule[{m = m0, saved = False},
                Column[{
                  InputField[Dynamic[m], String,
                    FieldSize -> {14, {1, 5}},
                    BaseStyle -> {FontFamily -> "Yu Gothic UI", FontSize -> 10}],
                  Row[{
                    Button[
                      Style["\:4fdd\:5b58", FontFamily -> "Yu Gothic UI",
                        FontSize -> 9, RGBColor[0.2, 0.38, 0.65]],
                      (SourceVaultUpdatePromptRouteMemo[rid,
                         If[StringQ[m], m, ""]]; saved = True),
                      Appearance -> "Frameless", BaseStyle -> {"Hyperlink"},
                      Method -> "Queued"],
                    Dynamic[If[TrueQ[saved],
                      Style[" \:2713", RGBColor[0.15, 0.45, 0.30], FontSize -> 9],
                      ""]]}]
                }, Spacings -> 0.1]]],
            Column[{
              Tooltip[
                Style[iSVPRTruncateDisplay[targetSym, 16],
                  FontFamily -> "Courier", FontSize -> 9],
                targetSym],
              Style[replayClass, FontFamily -> "Yu Gothic UI", FontSize -> 9,
                Which[
                  replayClass === "Replayable", RGBColor[0.15, 0.45, 0.30],
                  replayClass === "LightLLM", RGBColor[0.6, 0.5, 0.2],
                  True, GrayLevel[0.5]]]
            }, Spacings -> 0.2],
            Column[{
              Style[iSVPRDateOnly[created], FontFamily -> "Yu Gothic UI",
                FontSize -> 10],
              Style[iSVPRDateOnly[updated], FontFamily -> "Yu Gothic UI",
                FontSize -> 9, GrayLevel[0.5]]
            }, Spacings -> 0.15],
            Style[privLabel, FontFamily -> "Yu Gothic UI",
              Which[
                privLabel === "Public", GrayLevel[0.5],
                privLabel === "Restricted", RGBColor[0.6, 0.5, 0.2],
                True, RGBColor[0.7, 0.15, 0.15]]],
            (* State: PRIMARY / AUTO flags + ReplaySafety (Nothing
               collapses out of the Column when a flag is unset) *)
            Column[{
              If[TrueQ[Lookup[rt, "Primary", False]],
                Style["PRIMARY", Bold, FontSize -> 9, RGBColor[0.5, 0.3, 0.55]],
                Nothing],
              If[TrueQ[Lookup[rt, "AutoExecute", False]],
                Style["AUTO", Bold, FontSize -> 9, RGBColor[0.15, 0.45, 0.30]],
                Nothing],
              Style[Lookup[rt, "ReplaySafety", "?"], FontSize -> 8,
                Which[
                  Lookup[rt, "ReplaySafety", ""] === "EnvironmentIndependent",
                    RGBColor[0.15, 0.45, 0.30],
                  Lookup[rt, "ReplaySafety", ""] === "ContextBound",
                    RGBColor[0.6, 0.5, 0.2],
                  True, GrayLevel[0.5]]]
            }, Spacings -> 0.15],
            With[{rid = routeId, ie = proposedExpr, rc = replayClass,
                  theRoute = rt, safe = Lookup[rt, "ReplaySafety", "Unknown"]},
              Column[{
                (* ToInput: \:4fdd\:5b58\:6642\:306e\:63d0\:6848\:5f0f\:3092\:65b0\:898f\:5165\:529b\:30bb\:30eb\:306b\:66f8\:304f (\:8a55\:4fa1\:306f\:3057\:306a\:3044)\:3002
                   \:5024\:306f build \:6642\:306b\:5916\:5074 With \:3067\:30ea\:30c6\:30e9\:30eb\:5316\:3055\:308c\:308b (Module \:5c40\:6240\:5909\:6570\:6f0f\:308c\:9632\:6b62) *)
                Button[
                  Style["ToInput", FontFamily -> "Yu Gothic UI", FontSize -> 10,
                    RGBColor[0.2, 0.38, 0.65]],
                  Module[{target = InputNotebook[], replay, exprStr},
                    If[rc === "LightLLM",
                      replay = Quiet @ Check[
                        iSVPRLightLLMReplayDialog[theRoute], $Failed];
                      If[replay === $Canceled, Return[Null, Module]];
                      exprStr = If[AssociationQ[replay],
                        Lookup[replay, "ExprString", Missing[]], Missing[]];
                      If[!StringQ[exprStr], exprStr = ie];
                      If[Head[target] === NotebookObject && StringQ[exprStr],
                        NBAccess`NBWriteInputCellAndMaybeEvaluate[
                          target, exprStr, False]],
                      If[Head[target] === NotebookObject && StringQ[ie],
                        NBAccess`NBWriteInputCellAndMaybeEvaluate[
                          target, ie, False]]]],
                  Appearance -> "Frameless",
                  BaseStyle -> {"Hyperlink"},
                  Method -> "Queued"],
                (* Primary\:8a2d\:5b9a *)
                Button[
                  Style["Primary\:8a2d\:5b9a", FontFamily -> "Yu Gothic UI",
                    FontSize -> 10, RGBColor[0.5, 0.3, 0.55]],
                  Module[{choice},
                    choice = ChoiceDialog[
                      Column[{
                        Style["\:30d7\:30e9\:30a4\:30de\:30ea\:8a2d\:5b9a: " <> rid, Bold],
                        If[safe === "EnvironmentIndependent",
                          Style["\:81ea\:52d5\:5b9f\:884c\:3082\:8a31\:53ef\:3067\:304d\:307e\:3059\:3002",
                            FontSize -> 10],
                          Style["\:3053\:306e\:5f0f\:306f\:74b0\:5883\:4f9d\:5b58\:ff08" <> ToString[safe] <>
                            "\:ff09\:306e\:305f\:3081\:81ea\:52d5\:5b9f\:884c\:306f\:3067\:304d\:307e\:305b\:3093\:3002",
                            FontSize -> 10, RGBColor[0.6, 0.5, 0.2]]]}],
                      Flatten[{
                        "Primary\:306e\:307f" -> "PrimaryOnly",
                        If[safe === "EnvironmentIndependent",
                          {"Primary+\:81ea\:52d5\:5b9f\:884c" -> "PrimaryAuto"}, {}],
                        "\:30ad\:30e3\:30f3\:30bb\:30eb" -> $Canceled}]];
                    If[choice =!= $Canceled,
                      MessageDialog[Column[{
                        Style["Primary\:8a2d\:5b9a\:5b8c\:4e86", Bold],
                        SourceVaultSetPrimaryPromptRoute[rid,
                          "AutoExecute" -> (choice === "PrimaryAuto")],
                        Style["\:6700\:65b0\:72b6\:614b\:306f\:518d\:8868\:793a\:3057\:3066\:304f\:3060\:3055\:3044\:3002",
                          FontSize -> 10, GrayLevel[0.4]]}]]]],
                  Appearance -> "Frameless",
                  BaseStyle -> {"Hyperlink"},
                  Method -> "Queued"],
                (* \:524a\:9664: \:78ba\:8a8d\:30c0\:30a4\:30a2\:30ed\:30b0\:5f8c\:306b DryRun->False, Confirm->True \:3067\:5b9f\:524a\:9664 *)
                Button[
                  Style["\:524a\:9664", FontFamily -> "Yu Gothic UI",
                    FontSize -> 10, RGBColor[0.7, 0.15, 0.15]],
                  Module[{ok},
                    ok = ChoiceDialog[
                      Style["\:524a\:9664\:3057\:307e\:3059\:304b: " <> rid,
                        RGBColor[0.7, 0.15, 0.15]]];
                    If[TrueQ[ok],
                      MessageDialog[Column[{
                        Style["\:524a\:9664\:5b8c\:4e86", Bold],
                        SourceVaultDeletePromptRoute[rid,
                          "DryRun" -> False, "Confirm" -> True],
                        Style["\:6700\:65b0\:72b6\:614b\:306f\:518d\:8868\:793a\:3057\:3066\:304f\:3060\:3055\:3044\:3002",
                          FontSize -> 10, GrayLevel[0.4]]}]]]],
                  Appearance -> "Frameless",
                  BaseStyle -> {"Hyperlink"},
                  Method -> "Queued"]
              }, Spacings -> 0.35]]
          }]],
      filtered];
    Grid[
      Prepend[body, header],
      Frame -> All,
      FrameStyle -> Directive[GrayLevel[0.85]],
      Background -> {None, {GrayLevel[0.92], {White}}},
      Alignment -> {Left, Center},
      Spacings -> {1.2, 0.7},
      BaseStyle -> {FontFamily -> "Yu Gothic UI"}
    ]
  ];

SourceVaultFormatPromptRouteList[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" ->
      "Expected SourceVaultFormatPromptRouteList[routes_List, opts]."|>;

(* ---------- panel: search box + managed listing (mirrors SourceVaultWorkflowPanel) ---------- *)

Options[SourceVaultPromptRoutePanel] = {"Channel" -> All};

SourceVaultPromptRoutePanel[opts:OptionsPattern[]] :=
  DynamicModule[{query = "", channel, routes},
    channel = OptionValue[SourceVaultPromptRoutePanel, {opts}, "Channel"];
    routes = Quiet @ Check[
      SourceVaultSearchPromptRoutes["", "Channel" -> channel], {}];
    Panel[Column[{
      Style["SourceVault \:4fdd\:5b58\:30d7\:30ed\:30f3\:30d7\:30c8\:4e00\:89a7", Bold, 15,
        FontFamily -> "Yu Gothic UI"],
      Row[{
        InputField[Dynamic[query], String,
          FieldHint -> "\:30ad\:30fc\:30ef\:30fc\:30c9 / \:30e1\:30e2\:691c\:7d22", ImageSize -> 300,
          BaseStyle -> {FontFamily -> "Yu Gothic UI"}],
        Spacer[6],
        PopupMenu[Dynamic[channel],
          {All -> "\:5168\:30c1\:30e3\:30cd\:30eb", "public" -> "public",
           "private" -> "private", "local" -> "local"},
          BaseStyle -> {FontFamily -> "Yu Gothic UI"}],
        Spacer[6],
        Button[Style["\:691c\:7d22", FontFamily -> "Yu Gothic UI"],
          routes = Quiet @ Check[
            SourceVaultSearchPromptRoutes[query, "Channel" -> channel], {}],
          Method -> "Queued"],
        Spacer[4],
        Button[Style["\:5168\:4ef6", FontFamily -> "Yu Gothic UI"],
          query = "";
          routes = Quiet @ Check[
            SourceVaultSearchPromptRoutes["", "Channel" -> channel], {}],
          Method -> "Queued"],
        Spacer[4],
        Tooltip[
          Button[Style["\:518d\:8aad\:8fbc", FontFamily -> "Yu Gothic UI"],
            routes = Quiet @ Check[
              SourceVaultSearchPromptRoutes[query, "Channel" -> channel], {}],
            Method -> "Queued"],
          "\:5b9f\:884c\:30fbPrimary\:8a2d\:5b9a\:30fb\:524a\:9664\:306e\:5f8c\:306f\:518d\:8aad\:8fbc\:3067\:6700\:65b0\:72b6\:614b\:306b\:3057\:3066\:304f\:3060\:3055\:3044\:3002"]}],
      Dynamic[
        Row[{
          Style[ToString[Length[If[ListQ[routes], routes, {}]]] <> " \:4ef6",
            FontFamily -> "Yu Gothic UI", FontSize -> 10, GrayLevel[0.45]]}],
        TrackedSymbols :> {routes}],
      Dynamic[
        SourceVaultFormatPromptRouteList[If[ListQ[routes], routes, {}]],
        TrackedSymbols :> {routes}]},
      Spacings -> 0.6],
      ImageMargins -> 4]];

SourceVaultPromptRoutePanel[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" -> "Expected SourceVaultPromptRoutePanel[opts]."|>;


(* ============================================================
   Order 9: prompt capture (default-on) / version grouping /
   primary auto-execute / ReplaySafety.

   A "saved prompt" is now versioned: every save of the same
   (normalized) prompt becomes a new PromptRoute that shares a
   PromptGroupId. One version per group may be Primary; a Primary
   version may additionally be AutoExecute, in which case ClaudeEval
   releases-and-evaluates its frozen expression -- but only when the
   expression is ReadOnly/SafeCreate AND environment-independent.

   ReplaySafety distinguishes an expression that is a pure function
   of the live world (EnvironmentIndependent, e.g. uses Today /
   DatePlus / a named file) from one that baked a transient
   environment input -- a captured notebook cell, % / Out, a
   selection -- as a literal (ContextBound). Only the former may be
   auto-executed; the latter is forced to ReplayClass HeavyLLM and is
   re-resolved by the LLM with fresh context.

   All-ASCII source; Japanese UI text uses \:XXXX (rule 30).
   ============================================================ *)

(* ---------- prompt group + version identity ---------- *)

iSVPRPromptGroupId[prompt_String] :=
  "promptgroup-" <> StringTake[
    Hash[iSVPRNormalizePrompt[prompt], "SHA256", "HexString"], 16];
iSVPRPromptGroupId[_] := Missing["BadPrompt"];

(* a fresh, unique versioned route id for a prompt's group *)
iSVPRMakeVersionedRouteId[prompt_String] :=
  iSVPRPromptGroupId[prompt] <> "-v" <> StringTake[CreateUUID[], 8];
iSVPRMakeVersionedRouteId[_] :=
  "promptgroup-x-v" <> StringTake[CreateUUID[], 8];

(* group id of an existing route: explicit field, else derived from
   the first stored example (back-compat for pre-versioning routes) *)
iSVPRRouteGroupId[route_Association] :=
  Module[{gid, ex},
    gid = Lookup[route, "PromptGroupId", Missing[]];
    If[StringQ[gid] && gid =!= "", Return[gid]];
    ex = iSVPRRouteDisplayPrompt[route];
    If[StringQ[ex] && ex =!= "",
      iSVPRPromptGroupId[ex], Missing["NoGroup"]]];
iSVPRRouteGroupId[_] := Missing["NoGroup"];

iSVPRSavedChannels[] := {"public", "private", "local"};

(* every saved route across channels (no seed), each tagged _Channel *)
iSVPRAllSavedRoutes[] :=
  Join @@ Map[
    Function[ch,
      With[{r = Quiet @ Check[
          SourceVaultListPromptRoutes[
            "Channel" -> ch, "IncludeSeed" -> False], {}]},
        If[ListQ[r],
          Map[Function[rt,
              If[AssociationQ[rt], Append[rt, "_Channel" -> ch], rt]],
            Select[r, AssociationQ]],
          {}]]],
    iSVPRSavedChannels[]];

(* routes in a group, newest first (Version, then UpdatedAt) *)
iSVPRGroupRoutes[groupId_String] :=
  Module[{all},
    all = Select[iSVPRAllSavedRoutes[],
      iSVPRRouteGroupId[#] === groupId &];
    ReverseSortBy[all,
      Function[rt, {
        If[IntegerQ[Lookup[rt, "Version", 0]], Lookup[rt, "Version", 0], 0],
        ToString[Lookup[rt, "UpdatedAt", ""]]}]]];
iSVPRGroupRoutes[_] := {};

iSVPRNextVersion[groupId_String] :=
  Module[{vs},
    vs = Cases[Map[Lookup[#, "Version", 0] &, iSVPRGroupRoutes[groupId]],
      _Integer];
    If[vs === {}, 1, Max[vs] + 1]];
iSVPRNextVersion[_] := 1;

(* the channel a route lives in, or Missing["NotFound"] *)
iSVPRFindRouteChannel[routeId_String] :=
  SelectFirst[iSVPRSavedChannels[],
    Function[ch,
      With[{r = Quiet @ Check[
          SourceVaultListPromptRoutes[
            "Channel" -> ch, "IncludeSeed" -> False], {}]},
        ListQ[r] && AnyTrue[r,
          AssociationQ[#] && Lookup[#, "RouteId", Null] === routeId &]]],
    Missing["NotFound"]];
iSVPRFindRouteChannel[_] := Missing["NotFound"];

(* rewrite one channel registry by mapping fn over its entry list.
   Writes only when the list actually changed (no empty-file churn). *)
iSVPRRewriteChannel[channel_String, fn_] :=
  Module[{path, existing, updated},
    path = iSVPRPromptRouteRegistryPath[channel];
    existing = If[FileExistsQ[path],
      Quiet @ Check[iLoadRegistryEntries[path], {}], {}];
    If[!ListQ[existing], existing = {}];
    existing = Select[Map[iSVPRNormalizeRoute, existing], AssociationQ];
    updated = fn[existing];
    If[!ListQ[updated],
      Return[<|"Status" -> "Failed", "Reason" -> "BadRewrite",
        "Channel" -> channel|>]];
    If[updated === existing,
      Return[<|"Status" -> "OKNoChange", "Channel" -> channel|>]];
    iSVPRAtomicWriteRegistry[path, updated]];
iSVPRRewriteChannel[_, _] :=
  <|"Status" -> "Failed", "Reason" -> "BadArguments"|>;

(* ---------- ReplaySafety classification ---------- *)

(* session-transient symbols: their presence in an expression means the
   result depends on the live notebook / session state at call time *)
$iSVPRTransientHeads = {
  "Out", "In", "$Line", "MessageList",
  "SelectedCells", "SelectionMove", "NotebookRead", "NotebookGet",
  "EvaluationNotebook", "InputNotebook", "SelectedNotebook",
  "ClipboardData", "PreviousCell", "NextCell"};

(* deictic phrases that point at the live notebook context *)
$iSVPRDeicticPatterns = {
  "\:4e0a\:306e\:30bb\:30eb", "\:524d\:306e\:30bb\:30eb", "\:76f4\:524d\:306e\:30bb\:30eb",
  "\:3055\:3063\:304d", "\:76f4\:524d", "\:9078\:629e", "\:524d\:306e\:7d50\:679c",
  "the cell above", "previous cell", "above cell", "selected text",
  "last result", "the result above"};

(* head names applied somewhere in a held expression (un-evaluated) *)
iSVPRHeldHeadNames[held_] :=
  Module[{heads},
    If[!MatchQ[held, _HoldComplete], Return[{}]];
    (* Cases traverses the held structure without evaluating it
       (HoldComplete keeps the contents inert); works for any arity. *)
    heads = Quiet @ Check[
      DeleteDuplicates @ Cases[held,
        s_Symbol[___] :> SymbolName[Unevaluated[s]],
        {0, Infinity}, Heads -> True], {}];
    If[!ListQ[heads], heads = {}];
    DeleteCases[heads, "HoldComplete"]];
iSVPRHeldHeadNames[___] := {};

iSVPRExprHeadNamesFromString[exprStr_String] :=
  Module[{held},
    held = Quiet @ Check[
      ToExpression[exprStr, InputForm, HoldComplete], $Failed];
    If[MatchQ[held, _HoldComplete], iSVPRHeldHeadNames[held], {}]];
iSVPRExprHeadNamesFromString[_] := {};

(* a non-trivial line of captured context appears verbatim in the expr *)
iSVPRContextOverlapQ[exprStr_String, ctxText_String] :=
  Module[{lines},
    If[StringTrim[ctxText] === "" || StringTrim[exprStr] === "",
      Return[False]];
    lines = StringSplit[ctxText, RegularExpression["\\r?\\n"]];
    lines = Select[Map[StringTrim, lines], StringLength[#] >= 12 &];
    AnyTrue[lines, StringContainsQ[exprStr, #] &]];
iSVPRContextOverlapQ[_, _] := False;

iSVPRDeicticQ[prompt_String] :=
  Module[{p = ToLowerCase[prompt]},
    AnyTrue[$iSVPRDeicticPatterns,
      StringContainsQ[prompt, #] || StringContainsQ[p, ToLowerCase[#]] &]];
iSVPRDeicticQ[_] := False;

SourceVaultClassifyPromptReplaySafety[prompt_String, exprString_,
                                      contextBinding_] :=
  Module[{exprStr, binding, ctxText, usedCtx, overlap, heads,
          transient, deictic, safety},
    exprStr = If[StringQ[exprString], exprString, ""];
    binding = If[AssociationQ[contextBinding], contextBinding, <||>];
    ctxText = Lookup[binding, "ContextText", ""];
    If[!StringQ[ctxText], ctxText = ""];
    usedCtx = TrueQ[Lookup[binding, "UsedNotebookContext", False]];
    (* 1. literal context overlap (authoritative) *)
    overlap  = iSVPRContextOverlapQ[exprStr, ctxText];
    (* 2. transient session symbols in the expr *)
    heads     = iSVPRExprHeadNamesFromString[exprStr];
    transient = Intersection[heads, $iSVPRTransientHeads];
    (* 3. deictic words in the prompt (weak backup) *)
    deictic = iSVPRDeicticQ[prompt];
    safety = Which[
      overlap || Length[transient] > 0, "ContextBound",
      TrueQ[deictic],                    "ContextBound",
      exprStr === "",                    "Unknown",
      True,                              "EnvironmentIndependent"];
    <|"ReplaySafety" -> safety,
      "ContextBinding" -> <|
        "UsedNotebookContext" -> usedCtx,
        "ContextOverlap"      -> TrueQ[overlap],
        "TransientSymbols"    -> transient,
        "Deictic"             -> TrueQ[deictic]|>|>];
SourceVaultClassifyPromptReplaySafety[___] :=
  <|"ReplaySafety" -> "Unknown", "ContextBinding" -> <||>|>;

(* ---------- prompt-only context-dependency classification (X1) ---------- *)

(* conversation-history references. Kept separate from the notebook deictic
   table on purpose: "the conversation above" is NOT a notebook reference.
   These phrases are stripped before the deictic check so a pure-history
   prompt never lights up a notebook scope (spec 7.1: do not conflate). *)
$iSVPRHistoryPatterns = {
  "\:3055\:3063\:304d\:306e\:4f1a\:8a71", "\:5148\:307b\:3069\:306e\:4f1a\:8a71",
  "\:76f4\:524d\:306e\:4f1a\:8a71", "\:524d\:56de\:306e\:4f1a\:8a71",
  "\:3053\:306e\:4f1a\:8a71", "\:3053\:308c\:307e\:3067\:306e\:4f1a\:8a71",
  "\:524d\:306e\:8cea\:554f", "\:3055\:3063\:304d\:8a00\:3063\:305f",
  "\:524d\:306e\:3084\:308a\:53d6\:308a",
  "earlier you said", "you said earlier", "you mentioned", "as you said",
  "as mentioned earlier", "previous conversation",
  "earlier in this conversation", "in our conversation", "you told me"};

(* explicit whole-notebook requests *)
$iSVPRWholeNotebookPatterns = {
  "\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:5168\:4f53", "\:30ce\:30fc\:30c8\:5168\:4f53",
  "\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:5168\:90e8", "\:5168\:30bb\:30eb",
  "\:3059\:3079\:3066\:306e\:30bb\:30eb", "\:5168\:3066\:306e\:30bb\:30eb",
  "whole notebook", "entire notebook", "this notebook",
  "the whole notebook", "all cells", "all the cells", "across the notebook"};

(* explicit cell/text-selection references. More specific than the bare
   "\:9078\:629e" deictic token, which also matches "\:9078\:629e\:80a2" (= options). *)
$iSVPRSelectionPatterns = {
  "\:9078\:629e\:3057\:305f\:30bb\:30eb", "\:9078\:629e\:30bb\:30eb",
  "\:9078\:629e\:4e2d", "\:9078\:629e\:7bc4\:56f2",
  "\:9078\:629e\:3057\:305f\:30c6\:30ad\:30b9\:30c8", "\:9078\:629e\:90e8\:5206",
  "selected cell", "selected cells", "selected text", "selected region",
  "the selection", "highlighted cell"};

(* case-insensitive substring hit against a phrase table *)
iSVPRAnyPhraseQ[prompt_String, phrases_List] :=
  Module[{p = ToLowerCase[prompt]},
    AnyTrue[phrases,
      StringContainsQ[prompt, #] || StringContainsQ[p, ToLowerCase[#]] &]];
iSVPRAnyPhraseQ[_, _] := False;

(* %, Out, In and other session-transient references in the prompt itself.
   Two paths: (a) if the prompt parses as code, look for transient heads;
   (b) textual backup for natural-language prompts embedding Out[/In[/%. *)
iSVPRPromptTransientQ[prompt_String] :=
  Module[{heads, hit},
    heads = iSVPRExprHeadNamesFromString[prompt];
    hit = Length[Intersection[heads, $iSVPRTransientHeads]] > 0;
    hit = hit || StringContainsQ[prompt, "Out[" | "In["];
    hit = hit || StringContainsQ[prompt,
      RegularExpression["(?<![0-9A-Za-z])%(?![0-9A-Za-z])"]];
    TrueQ[hit]];
iSVPRPromptTransientQ[_] := False;

(* demonstrative + notebook-artifact noun (e.g. "\:3053\:306e\:30b0\:30e9\:30d5" = this graph). These
   read as notebook-recent references even though the bare demonstrative is not
   in the shared deictic table. Used only by the dependency classifier, so the
   replay-safety classifier's table is untouched. Strengthens detection so the
   opt-in self-contained trim does not starve "\:3053\:306e\:30b0\:30e9\:30d5\:3092\:6539\:5584\:3057\:3066"-style prompts. *)
$iSVPRNotebookNounRegex = RegularExpression[
  "(\:3053\:306e|\:305d\:306e|\:3042\:306e|\:4e0a\:306e|\:5148\:307b\:3069\:306e)" <>
  "(\:7d50\:679c|\:30b0\:30e9\:30d5|\:30c7\:30fc\:30bf|\:51fa\:529b|\:30b3\:30fc\:30c9|\:95a2\:6570|" <>
  "\:30d7\:30ed\:30c3\:30c8|\:5024|\:8a08\:7b97|\:5f0f|\:30a8\:30e9\:30fc|\:56f3|" <>
  "\:30d7\:30ed\:30b0\:30e9\:30e0|\:8868|\:30ea\:30b9\:30c8|\:30bb\:30eb)"];

iSVPRNotebookNounQ[s_String] :=
  StringContainsQ[s, $iSVPRNotebookNounRegex] ||
  StringContainsQ[s, "\:4e0a\:8a18"] ||                       (* \:4e0a\:8a18 = the above *)
  StringContainsQ[ToLowerCase[s], "the above"] ||
  StringContainsQ[ToLowerCase[s], "above output"] ||
  StringContainsQ[ToLowerCase[s], "above result"];
iSVPRNotebookNounQ[_] := False;

(* notebook scope rank: None 0 < PreviousCellGroup 1 < Tail 2 < Full 3 *)
$iSVPRNotebookModeByRank = {"None", "PreviousCellGroup", "Tail", "Full"};

SourceVaultClassifyPromptContextDependency[prompt_String] :=
  Module[{historyHit, stripped, deictic, transient, wholeNB, selection,
          rank, nbMode, histMode, kinds, reasons, confidence},
    historyHit = iSVPRAnyPhraseQ[prompt, $iSVPRHistoryPatterns];
    (* strip matched history phrases before the deictic check so a pure-
       history prompt does not trigger a notebook scope via the shared
       "\:3055\:3063\:304d" / "\:76f4\:524d" tokens (spec 7.1: do not conflate) *)
    stripped = If[historyHit,
      StringReplace[prompt, (# -> " " &) /@ $iSVPRHistoryPatterns], prompt];
    deictic   = iSVPRDeicticQ[stripped] || iSVPRNotebookNounQ[stripped];
    transient = iSVPRPromptTransientQ[prompt];
    wholeNB   = iSVPRAnyPhraseQ[prompt, $iSVPRWholeNotebookPatterns];
    selection = iSVPRAnyPhraseQ[prompt, $iSVPRSelectionPatterns];
    (* notebook scope = max of the contributing signals *)
    rank = 0;
    If[transient, rank = Max[rank, 1]];   (* %/Out/In -> PreviousCellGroup+ *)
    If[deictic,   rank = Max[rank, 2]];   (* "the cell above" -> Tail+ *)
    If[wholeNB,   rank = 3];              (* explicit whole notebook -> Full *)
    nbMode   = $iSVPRNotebookModeByRank[[rank + 1]];
    histMode = If[historyHit, "Recent", "None"];
    (* dependency kinds + human-readable reasons *)
    kinds = {}; reasons = {};
    If[rank == 3,
      AppendTo[kinds, "NotebookFull"];
      AppendTo[reasons, "explicit whole-notebook request"]];
    If[1 <= rank <= 2,
      AppendTo[kinds, "NotebookRecent"];
      AppendTo[reasons,
        If[deictic, "deictic notebook reference",
                    "transient-symbol notebook reference"]]];
    If[transient,
      AppendTo[kinds, "TransientSymbols"];
      AppendTo[reasons, "prompt references %/Out/In"]];
    If[selection,
      AppendTo[kinds, "SelectedCells"];
      AppendTo[reasons, "explicit cell/text selection"]];
    If[historyHit,
      AppendTo[kinds, "ConversationHistory"];
      AppendTo[reasons, "explicit conversation-history reference"]];
    If[kinds === {},
      kinds = {"SelfContained"};
      AppendTo[reasons, "no notebook/history/selection markers detected"]];
    confidence = If[rank > 0 || selection || historyHit, "High", "Low"];
    <|"DependencyKinds" -> DeleteDuplicates[kinds],
      "RequiredContext" -> <|
        "Notebook"      -> <|"Mode" -> nbMode|>,
        "SelectedCells" -> TrueQ[selection],
        "History"       -> <|"Mode" -> histMode|>|>,
      "Confidence" -> confidence,
      "Reasons"    -> reasons|>];
(* non-string / unclassifiable: choose broader REQUESTED context, but still
   never conflate notebook with history (spec 7.1) *)
SourceVaultClassifyPromptContextDependency[___] :=
  <|"DependencyKinds" -> {"Unknown"},
    "RequiredContext" -> <|
      "Notebook"      -> <|"Mode" -> "Tail"|>,
      "SelectedCells" -> False,
      "History"       -> <|"Mode" -> "Recent"|>|>,
    "Confidence" -> "Low",
    "Reasons"    -> {"non-string prompt; defaulting to broad requested context"}|>;

(* ---------- context planner (X1): register into the base-package hook ----------
   ClaudeCode`$ClaudeEvalContextPlanner is a package-neutral hook owned by
   claudecode (default None). SourceVault sets it to this planner so the
   ClaudeEval send path can refine its ContextPlan per prompt. claudecode never
   references SourceVault (rule 11): the dependency direction stays
   SourceVault -> claudecode, and claudecode only calls the function value held
   in its own hook variable. The base hook already wraps this call in
   Quiet/Check/Catch and fail-safes to the default plan, so any error here is
   non-fatal. *)
iSVPRContextPlanner[payload_Association] :=
  Module[{enabled, defaultPlan, prompt, cls, conf, clsNbMode, nbMode, nbBudget},
    defaultPlan = Lookup[payload, "DefaultPlan", <||>];
    If[!AssociationQ[defaultPlan], defaultPlan = <||>];
    enabled = TrueQ[SourceVault`$SourceVaultContextPlannerEnabled];
    prompt  = Lookup[payload, "Prompt", ""];
    If[!enabled || !StringQ[prompt] || StringTrim[prompt] === "",
      Return[defaultPlan, Module]];
    cls = Quiet @ Check[
      SourceVaultClassifyPromptContextDependency[prompt], $Failed];
    If[!AssociationQ[cls], Return[defaultPlan, Module]];
    conf      = Lookup[cls, "Confidence", "Low"];
    clsNbMode = Lookup[Lookup[Lookup[cls, "RequiredContext", <||>],
                  "Notebook", <||>], "Mode", "Tail"];
    nbBudget  = Lookup[Lookup[defaultPlan, "Notebook", <||>], "CharBudget",
                  ClaudeCode`$ClaudeEvalContextNotebookCharBudget];
    (* Conservative policy (X1-2): only act on HIGH-confidence classifications.
       - High + Notebook "None" (a pure conversation-history question) -> drop
         notebook context; there is a positive reason it is irrelevant.
       - High + any notebook need -> bounded "Tail" (the X0a-safe mode; the
         assembler does not yet bound "Full"/"PreviousCellGroup" -- that is X0b).
       - Low / SelfContained -> keep the DEFAULT notebook scope. With no positive
         evidence the notebook is irrelevant we never starve an unmarked prompt.
       History and ToolDefinitions are left at the default plan (history is never
       trimmed here, so unmarked multi-turn follow-ups keep their context).
       The $SourceVaultContextPlannerTrimSelfContained opt-in (default False)
       additionally drops notebook context for Low/SelfContained prompts. *)
    nbMode = Which[
      conf === "High",
        If[clsNbMode === "None", "None", "Tail"],
      TrueQ[SourceVault`$SourceVaultContextPlannerTrimSelfContained],
        "None",
      True,
        Lookup[Lookup[defaultPlan, "Notebook", <||>], "Mode", "Tail"]];
    Append[defaultPlan,
      "Notebook" -> <|"Mode" -> nbMode, "CharBudget" -> nbBudget|>]
  ];
iSVPRContextPlanner[_] := <||>;

(* register the planner into the claudecode hook (load-order independent:
   claudecode initialises the variable with If[!ValueQ[...], ...=None], so this
   assignment survives whether SourceVault loads before or after claudecode) *)
ClaudeCode`$ClaudeEvalContextPlanner = iSVPRContextPlanner;

(* ---------- auto-execute gate (rule 00 + ReadOnly/SafeCreate) ---------- *)

(* heads that are safe to release-and-evaluate without confirmation.
   Pure / structural / scoping / list / math / string / date heads.
   Mutating, file, process, network heads are intentionally absent. *)
$iSVPRAutoExecSafeHeads = {
  "Module", "Block", "With", "Function", "Slot", "SlotSequence",
  "CompoundExpression", "Set", "SetDelayed",
  "If", "Which", "Switch", "Do", "Table", "Map", "MapThread", "Apply",
  "Scan", "Fold", "FoldList", "Nest", "NestList", "Through", "MapIndexed",
  "List", "Association", "Rule", "RuleDelayed", "Part", "Span",
  "First", "Last", "Most", "Rest", "Take", "Drop", "Length", "Range",
  "Join", "Flatten", "Partition", "Append", "Prepend", "Insert", "Delete",
  "ReplacePart", "Reverse", "Sort", "SortBy", "ReverseSort", "ReverseSortBy",
  "Select", "Cases", "DeleteCases", "Pick", "DeleteDuplicates",
  "DeleteDuplicatesBy", "Count", "Total", "Union", "Intersection",
  "Complement", "Lookup", "Keys", "Values", "KeyTake", "KeyDrop",
  "KeySelect", "KeyValueMap", "Normal", "Merge", "GroupBy",
  "AssociationThread", "Thread", "Replace", "ReplaceAll", "ReplaceRepeated",
  "Position", "FirstCase", "SelectFirst", "MemberQ", "FreeQ", "AllTrue",
  "AnyTrue", "NoneTrue", "KeyExistsQ",
  "Plus", "Times", "Subtract", "Divide", "Power", "Minus", "Mod",
  "Quotient", "Floor", "Ceiling", "Round", "Max", "Min", "Abs",
  "And", "Or", "Not", "Xor", "Equal", "Unequal", "Greater", "Less",
  "GreaterEqual", "LessEqual", "SameQ", "UnsameQ", "Boole", "TrueQ",
  "StringJoin", "StringRiffle", "StringSplit", "StringTrim", "StringTake",
  "StringDrop", "StringLength", "StringContainsQ", "StringStartsQ",
  "StringEndsQ", "StringReplace", "StringCases", "ToString",
  "ToUpperCase", "ToLowerCase", "StringForm", "StringTemplate",
  "Characters", "StringQ", "IntegerQ", "NumericQ", "AssociationQ", "ListQ",
  "Today", "Now", "DateObject", "DateList", "DatePlus", "DateDifference",
  "DateString", "DateValue", "AbsoluteTime", "FromDateString", "DateRange",
  "DayName", "DayRange", "Quantity", "UnitConvert",
  "N", "Identity", "Echo", "Print", "Style", "Column", "Row", "Grid",
  "Item", "Missing", "Nothing"};

(* heads that must never be auto-executed (rule 00 + side effects) *)
$iSVPRAutoExecForbiddenHeads = {
  "ClaudeAttach", "SystemCredential",
  "Set", "SetDelayed",  (* only forbidden as protected-target; see guard *)
  "Put", "PutAppend", "Save", "DumpSave", "Export",
  "DeleteFile", "RenameFile", "CopyFile", "CreateFile", "CreateDirectory",
  "DeleteDirectory", "WriteString", "Write", "BinaryWrite", "OpenWrite",
  "OpenAppend", "Run", "RunProcess", "StartProcess", "ExternalEvaluate",
  "CreateScheduledTask", "RemoveScheduledTask", "URLSubmit", "URLExecute",
  "SendMail", "DeleteObject", "SetEnvironment", "Install",
  "AppendTo", "PrependTo", "AssociateTo", "AddTo", "SubtractFrom",
  "TimesBy", "DivideBy", "Increment", "Decrement", "PreIncrement",
  "PreDecrement", "ClearAll", "Clear", "Remove", "Unset"};

(* the genuinely-forbidden heads (Set/SetDelayed are handled by the
   protected-target guard, not a blanket ban, so locals stay legal) *)
$iSVPRAutoExecHardForbidden = Complement[
  $iSVPRAutoExecForbiddenHeads, {"Set", "SetDelayed"}];

(* True when a held expr assigns (Set/AddTo/...) to a $-prefixed global
   symbol -- the rule 00 protected-constant family ($Claude*, $NB*,
   $SourceVault*, etc.). Module-local vars are not $-prefixed. *)
iSVPRHasGlobalAssignment[held_] :=
  Module[{targets},
    If[!MatchQ[held, _HoldComplete], Return[False]];
    targets = Quiet @ Check[
      Cases[held,
        (Set | SetDelayed | AddTo | SubtractFrom | TimesBy | DivideBy |
         AppendTo | PrependTo | AssociateTo | Increment | Decrement |
         PreIncrement | PreDecrement | Unset)[lhs_, ___] :>
          Cases[Unevaluated[lhs],
            s_Symbol :> SymbolName[Unevaluated[s]],
            {0, Infinity}, Heads -> True],
        {0, Infinity}, Heads -> True], {}];
    targets = Flatten[If[ListQ[targets], targets, {}]];
    AnyTrue[targets, StringQ[#] && StringStartsQ[#, "$"] &]];
iSVPRHasGlobalAssignment[___] := False;

(* a held expr is auto-executable iff: it is not an LLM call, has no
   hard-forbidden head, assigns no protected global, and every applied
   head is a SourceVault*/NB*/allowlisted/safe-system head. *)
iSVPRAutoExecutableQ[held_] :=
  Module[{heads, allow, bad},
    If[!MatchQ[held, _HoldComplete], Return[False]];
    heads = iSVPRHeldHeadNames[held];
    If[!ListQ[heads] || heads === {}, Return[False]];
    If[Length[Intersection[heads, {"ClaudeEval", "ContinueEval"}]] > 0,
      Return[False]];
    If[Length[Intersection[heads, $iSVPRAutoExecHardForbidden]] > 0,
      Return[False]];
    If[iSVPRHasGlobalAssignment[held], Return[False]];
    allow = Quiet @ Check[Keys[SourceVaultCallableAllowlistView[]], {}];
    If[!ListQ[allow], allow = {}];
    bad = Select[heads,
      !(StringStartsQ[#, "SourceVault"] || StringStartsQ[#, "NB"] ||
        MemberQ[allow, #] || MemberQ[$iSVPRAutoExecSafeHeads, #]) &];
    Length[bad] === 0];
iSVPRAutoExecutableQ[___] := False;

(* True when a saved route's stored expression may be auto-executed:
   parseable, auto-executable head set, and EnvironmentIndependent. *)
iSVPRRouteAutoExecutableQ[route_Association] :=
  Module[{exprStr, held, safety},
    exprStr = Lookup[route, "TargetExprString", Missing[]];
    If[!StringQ[exprStr] || StringTrim[exprStr] === "", Return[False]];
    safety = Lookup[route, "ReplaySafety", "Unknown"];
    If[safety =!= "EnvironmentIndependent", Return[False]];
    held = Quiet @ Check[
      ToExpression[exprStr, InputForm, HoldComplete], $Failed];
    iSVPRAutoExecutableQ[held]];
iSVPRRouteAutoExecutableQ[_] := False;

(* ---------- exact-match lookup / primary resolution ---------- *)

Options[SourceVaultMatchSavedPromptVersions] = {
  "Channel" -> All, "IncludeSeed" -> False};

SourceVaultMatchSavedPromptVersions[prompt_String,
                                    opts:OptionsPattern[]] :=
  Module[{gid, all, hits},
    gid = iSVPRPromptGroupId[prompt];
    If[!StringQ[gid], Return[{}]];
    all = iSVPRAllSavedRoutes[];
    hits = Select[all, iSVPRRouteGroupId[#] === gid &];
    ReverseSortBy[hits,
      Function[rt, {
        If[TrueQ[Lookup[rt, "Primary", False]], 1, 0],
        If[IntegerQ[Lookup[rt, "Version", 0]], Lookup[rt, "Version", 0], 0],
        ToString[Lookup[rt, "UpdatedAt", ""]]}]]];
SourceVaultMatchSavedPromptVersions[___] := {};

SourceVaultPrimaryPromptRoute[prompt_String] :=
  Module[{vs},
    vs = SourceVaultMatchSavedPromptVersions[prompt];
    If[!ListQ[vs], vs = {}];
    SelectFirst[vs, TrueQ[Lookup[#, "Primary", False]] &,
      Missing["NoPrimary"]]];
SourceVaultPrimaryPromptRoute[_] := Missing["BadPrompt"];

(* ---------- set primary / delete ---------- *)

Options[SourceVaultSetPrimaryPromptRoute] = {
  "AutoExecute" -> Automatic, "DryRun" -> False};

SourceVaultSetPrimaryPromptRoute[routeId_String,
                                 opts:OptionsPattern[]] :=
  Module[{dryRun, autoOpt, ch, route, gid, safety, autoExec, cleared},
    dryRun  = TrueQ[OptionValue[
      SourceVaultSetPrimaryPromptRoute, {opts}, "DryRun"]];
    autoOpt = OptionValue[
      SourceVaultSetPrimaryPromptRoute, {opts}, "AutoExecute"];
    ch = iSVPRFindRouteChannel[routeId];
    If[!StringQ[ch],
      Return[<|"Status" -> "NotFound", "RouteId" -> routeId|>]];
    route = SourceVaultGetPromptRoute[routeId,
      "Channel" -> ch, "IncludeSeed" -> False];
    If[!AssociationQ[route] ||
       Lookup[route, "Status", ""] === "NotFound",
      Return[<|"Status" -> "NotFound", "RouteId" -> routeId|>]];
    gid    = iSVPRRouteGroupId[route];
    safety = Lookup[route, "ReplaySafety", "Unknown"];
    autoExec = Which[
      autoOpt === Automatic, TrueQ[Lookup[route, "AutoExecute", False]],
      TrueQ[autoOpt],        safety === "EnvironmentIndependent",
      True,                  False];
    If[dryRun,
      Return[<|"Status" -> "DryRun", "RouteId" -> routeId, "Channel" -> ch,
        "PromptGroupId" -> gid, "AutoExecute" -> autoExec,
        "AutoExecuteRequested" -> autoOpt, "ReplaySafety" -> safety|>]];
    cleared = {};
    Scan[
      Function[c,
        iSVPRRewriteChannel[c,
          Function[entries,
            Map[
              Function[e,
                Which[
                  Lookup[e, "RouteId", Null] === routeId,
                    Join[e, <|"Primary" -> True, "AutoExecute" -> autoExec,
                      "UpdatedAt" -> iSVPRTimestamp[]|>],
                  iSVPRRouteGroupId[e] === gid &&
                    TrueQ[Lookup[e, "Primary", False]],
                    (AppendTo[cleared, Lookup[e, "RouteId", "?"]];
                     Join[e, <|"Primary" -> False, "AutoExecute" -> False|>]),
                  True, e]],
              entries]]]],
      iSVPRSavedChannels[]];
    <|"Status" -> "OK", "RouteId" -> routeId, "Channel" -> ch,
      "PromptGroupId" -> gid, "Primary" -> True, "AutoExecute" -> autoExec,
      "ReplaySafety" -> safety,
      "ClearedSiblings" -> DeleteCases[cleared, routeId]|>];
SourceVaultSetPrimaryPromptRoute[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" -> "Expected SourceVaultSetPrimaryPromptRoute[routeId_String, opts]."|>;

Options[SourceVaultDeletePromptRoute] = {
  "DryRun" -> True, "Confirm" -> False};

SourceVaultDeletePromptRoute[routeId_String, opts:OptionsPattern[]] :=
  Module[{dryRun, confirm, ch, route, wasPrimary, writeRes},
    dryRun  = TrueQ[OptionValue[
      SourceVaultDeletePromptRoute, {opts}, "DryRun"]];
    confirm = TrueQ[OptionValue[
      SourceVaultDeletePromptRoute, {opts}, "Confirm"]];
    ch = iSVPRFindRouteChannel[routeId];
    If[!StringQ[ch],
      Return[<|"Status" -> "NotFound", "RouteId" -> routeId|>]];
    route = SourceVaultGetPromptRoute[routeId,
      "Channel" -> ch, "IncludeSeed" -> False];
    wasPrimary = AssociationQ[route] &&
      TrueQ[Lookup[route, "Primary", False]];
    (* rule 103: non-destructive by default; real delete needs both *)
    If[dryRun || !confirm,
      Return[<|"Status" -> "DryRun", "RouteId" -> routeId, "Channel" -> ch,
        "WasPrimary" -> wasPrimary,
        "Hint" ->
          "Pass DryRun -> False and Confirm -> True to delete."|>]];
    writeRes = iSVPRRewriteChannel[ch,
      Function[entries,
        Select[entries, Lookup[#, "RouteId", Null] =!= routeId &]]];
    If[Lookup[writeRes, "Status", ""] === "Failed",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[writeRes, "Reason", "WriteFailed"],
        "RouteId" -> routeId, "Channel" -> ch|>]];
    <|"Status" -> "OK", "RouteId" -> routeId, "Channel" -> ch,
      "Removed" -> 1, "WasPrimary" -> wasPrimary|>];
SourceVaultDeletePromptRoute[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" -> "Expected SourceVaultDeletePromptRoute[routeId_String, opts]."|>;

(* ---------- editable memo ---------- *)

SourceVaultUpdatePromptRouteMemo[routeId_String, memo_String] :=
  Module[{ch, found = False, writeRes},
    ch = iSVPRFindRouteChannel[routeId];
    If[!StringQ[ch],
      Return[<|"Status" -> "NotFound", "RouteId" -> routeId|>]];
    writeRes = iSVPRRewriteChannel[ch,
      Function[entries,
        Map[Function[e,
          If[Lookup[e, "RouteId", Null] === routeId,
            (found = True;
             Join[e, <|"Memo" -> memo, "UpdatedAt" -> iSVPRTimestamp[]|>]),
            e]], entries]]];
    If[Lookup[writeRes, "Status", ""] === "Failed",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[writeRes, "Reason", "WriteFailed"],
        "RouteId" -> routeId, "Channel" -> ch|>]];
    If[TrueQ[found],
      <|"Status" -> "OK", "RouteId" -> routeId,
        "Channel" -> ch, "Memo" -> memo|>,
      <|"Status" -> "NotFound", "RouteId" -> routeId|>]];
SourceVaultUpdatePromptRouteMemo[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments"|>;

(* ---------- add / revise the memo on the last run's saved version ----------
   The prompt is already auto-captured on every ClaudeEval / ContinueEval run
   (SourceVaultAutoSaveLastPrompt), so the natural manual gesture after a run
   is to ATTACH A MEMO to that already-saved newest version - not to save the
   prompt again. AddPromptMemo updates the Memo of the last run's newest saved
   version in place (no redundant new version). When no saved version exists
   yet - e.g. a HeavyLLM one-shot answer that auto-save intentionally skips -
   it falls back to SaveLastPrompt so the memo still gets a home. *)

(* the prompt string of the most recent ClaudeEval / ContinueEval run.
   ClaudeEval records it in ClaudeCode`$iClaudeEvalAutoSaveTask at turn start
   (and never clears it) - the same handle the auto-saver keys on - so we read
   it weakly. Falls back to the last successful PromptRun capture. *)
iSVPRLastEvalPrompt[] :=
  Module[{p, cap, run},
    p = Quiet @ Check[
      Symbol["ClaudeCode`$iClaudeEvalAutoSaveTask"], Missing["NoGlobal"]];
    If[StringQ[p] && StringTrim[p] =!= "", Return[p]];
    cap = Quiet @ Check[SourceVaultCaptureLastPromptRun[], <||>];
    If[AssociationQ[cap] && Lookup[cap, "Status", ""] === "OK",
      run = Lookup[cap, "PromptRun", <||>];
      If[AssociationQ[run],
        p = Which[
          StringQ[Lookup[run, "RawPrompt", Missing[]]],  run["RawPrompt"],
          StringQ[Lookup[run, "PromptText", Missing[]]], run["PromptText"],
          True, Missing["NoPrompt"]];
        If[StringQ[p], Return[p]]]];
    Missing["NoLastPrompt"]];

Options[AddPromptMemo] = {"PromptText" -> Automatic, "RouteId" -> Automatic};

AddPromptMemo[memo_String, opts:OptionsPattern[]] :=
  Module[{routeIdOpt, promptOpt, prompt, gid, latest,
          routeId = Missing["None"], upd, saveRes},
    routeIdOpt = OptionValue[AddPromptMemo, {opts}, "RouteId"];
    promptOpt  = OptionValue[AddPromptMemo, {opts}, "PromptText"];

    (* prompt of the run whose memo we are setting *)
    prompt = If[StringQ[promptOpt] && StringTrim[promptOpt] =!= "",
      promptOpt, iSVPRLastEvalPrompt[]];

    (* target route: explicit RouteId wins; else the newest saved version in
       the last run's prompt group (the version auto-save just created) *)
    Which[
      StringQ[routeIdOpt] && routeIdOpt =!= "",
        routeId = routeIdOpt,
      StringQ[prompt],
        gid = iSVPRPromptGroupId[prompt];
        latest = If[StringQ[gid],
          First[iSVPRGroupRoutes[gid], Missing[]], Missing[]];
        If[AssociationQ[latest],
          routeId = Lookup[latest, "RouteId", Missing["None"]]]];

    (* in-place memo update on the existing newest version *)
    If[StringQ[routeId] && routeId =!= "",
      upd = SourceVaultUpdatePromptRouteMemo[routeId, memo];
      If[AssociationQ[upd] && Lookup[upd, "Status", ""] === "OK",
        Return[Join[upd, <|"Action" -> "MemoUpdated"|>]]]];

    (* fallback: nothing saved for this run yet -> save a version with the memo *)
    saveRes = If[StringQ[prompt],
      SaveLastPrompt[memo, "PromptText" -> prompt],
      SaveLastPrompt[memo]];
    If[!AssociationQ[saveRes],
      saveRes = <|"Status" -> "Failed", "Reason" -> "SaveFailed"|>];
    Join[saveRes,
      <|"Action" -> If[Lookup[saveRes, "Status", ""] === "OK",
          "MemoSavedNewVersion", "MemoNotSaved"]|>]
  ];

AddPromptMemo[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" -> "Expected AddPromptMemo[memo_String, opts]."|>;

(* truncate a display string so a long prompt does not break the Grid
   layout; the full text is kept for matching and shown via Tooltip. *)
(* ISO 日時文字列 ("2026-06-02T16:44:32") -> 日付のみ ("2026-06-02")。
   "T" / 空白で切って先頭 (日付) を返す。非文字列・空はそのまま文字列化。 *)
iSVPRDateOnly[s_] := Module[{t},
  t = ToString[s];
  If[StringTrim[t] === "", Return[t]];
  First[StringSplit[t, "T" | " "], t]];

iSVPRTruncateDisplay[s_String, n_Integer:64] :=
  Module[{flat},
    flat = StringReplace[s, RegularExpression["\\s+"] -> " "];
    flat = StringTrim[flat];
    If[StringLength[flat] > n,
      StringTake[flat, n] <> "\:2026", flat]];
iSVPRTruncateDisplay[s_, n_:64] := iSVPRTruncateDisplay[ToString[s], n];

(* ---------- primary auto-execute executor (gated) ---------- *)

(* styled notice returned when an auto-execute cannot proceed *)
iSVPRAutoExecNotice[reason_String, groupId_, route_] :=
  Column[{
    Style["\:81ea\:52d5\:5b9f\:884c\:3067\:304d\:307e\:305b\:3093: " <> reason,
      Bold, RGBColor[0.6, 0.5, 0.2], FontFamily -> "Yu Gothic UI"],
    Style["groupId: " <> ToString[groupId],
      FontSize -> 9, GrayLevel[0.5]]},
    Spacings -> 0.3];

(* notice + manual-run button for a blocked expression *)
iSVPRAutoExecBlocked[exprStr_String, safety_, groupId_, route_] :=
  Column[{
    Style[
      "\:81ea\:52d5\:5b9f\:884c\:3067\:304d\:307e\:305b\:3093\:ff08\:526f\:4f5c\:7528\:307e\:305f\:306f\:74b0\:5883\:4f9d\:5b58\:304c\:672a\:78ba\:8a8d\:3067\:3059\:ff09\:3002" <>
      "\:624b\:52d5\:3067\:5b9f\:884c\:3057\:3066\:304f\:3060\:3055\:3044\:3002",
      Bold, RGBColor[0.6, 0.5, 0.2], FontFamily -> "Yu Gothic UI"],
    Style["ReplaySafety: " <> ToString[safety],
      FontSize -> 9, GrayLevel[0.5]],
    With[{e = exprStr},
      Button[
        Style["\:624b\:52d5\:3067\:5b9f\:884c", FontFamily -> "Yu Gothic UI",
          FontSize -> 10, RGBColor[0.2, 0.38, 0.65]],
        Module[{target = InputNotebook[]},
          If[Head[target] === NotebookObject,
            NBAccess`NBWriteInputCellAndMaybeEvaluate[target, e, False]]],
        Appearance -> "Frameless", BaseStyle -> {"Hyperlink"},
        Method -> "Queued"]]},
    Spacings -> 0.3];

Options[SourceVaultRunPrimaryRoute] = {};

SourceVaultRunPrimaryRoute[groupId_String, opts:OptionsPattern[]] :=
  Module[{routes, primary, exprStr, held, safety, dispPrompt},
    routes = iSVPRGroupRoutes[groupId];
    primary = SelectFirst[routes,
      TrueQ[Lookup[#, "Primary", False]] &, Missing[]];
    If[!AssociationQ[primary],
      Return[iSVPRAutoExecNotice[
        "\:30d7\:30e9\:30a4\:30de\:30ea\:672a\:8a2d\:5b9a", groupId, Missing[]]]];
    dispPrompt = iSVPRRouteDisplayPrompt[primary];
    exprStr = Lookup[primary, "TargetExprString", Missing[]];
    (* encrypted primary: decrypt to recover the expression *)
    If[!StringQ[exprStr] &&
       AssociationQ[Lookup[primary, "EncryptedPayload", Null]],
      Module[{dec},
        dec = SourceVaultDecryptPromptRoute[primary];
        If[AssociationQ[dec] && Lookup[dec, "Status", ""] === "Ok",
          exprStr = Lookup[Lookup[dec, "Plaintext", <||>],
            "TargetExprString", Missing[]]]]];
    If[!StringQ[exprStr] || StringTrim[exprStr] === "",
      Return[iSVPRAutoExecNotice["\:5f0f\:306a\:3057", groupId, primary]]];
    safety = Lookup[primary, "ReplaySafety", "Unknown"];
    held = Quiet @ Check[
      ToExpression[exprStr, InputForm, HoldComplete], $Failed];
    If[!MatchQ[held, _HoldComplete],
      Return[iSVPRAutoExecNotice["\:30d1\:30fc\:30b9\:4e0d\:80fd", groupId, primary]]];
    If[!(iSVPRAutoExecutableQ[held] && safety === "EnvironmentIndependent"),
      Return[iSVPRAutoExecBlocked[exprStr, safety, groupId, primary]]];
    (* record the run, then release-and-evaluate the frozen expression *)
    Quiet @ Check[
      SourceVaultPromptRunRecord[
        If[StringQ[dispPrompt], dispPrompt, ""],
        <|"RouteId" -> Lookup[primary, "RouteId", Missing[]],
          "RouteVersion" -> Lookup[primary, "Version", Missing[]],
          "Decision" -> "PrimaryAutoExecute"|>,
        <|"Kind" -> "FunctionResult"|>],
      Null];
    Quiet @ Check[ReleaseHold[held], $Failed]];
SourceVaultRunPrimaryRoute[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments"|>;

(* ---------- saved-versions UI (no LLM) ---------- *)

Options[SourceVaultPromptVersionsUI] = {};

SourceVaultPromptVersionsUI[normKey_String, prompt_String,
                            opts:OptionsPattern[]] :=
  Module[{versions, grid, askBtn},
    versions = SourceVaultMatchSavedPromptVersions[prompt];
    If[!ListQ[versions], versions = {}];
    grid = SourceVaultFormatPromptRouteList[versions];
    askBtn = With[{k = normKey, p = prompt},
      Button[
        Style["LLM\:306b\:65b0\:898f\:554f\:3044\:5408\:308f\:305b",
          FontFamily -> "Yu Gothic UI", FontSize -> 11,
          RGBColor[0.2, 0.38, 0.65]],
        Module[{target = InputNotebook[]},
          SourceVault`$SourceVaultPromptBypassOnce = k;
          If[Head[target] === NotebookObject,
            NBAccess`NBWriteInputCellAndMaybeEvaluate[target,
              "ClaudeEval[\"" <>
                StringReplace[p, "\"" -> "\\\""] <> "\"]", True]]],
        Appearance -> "Frameless", BaseStyle -> {"Hyperlink"},
        Method -> "Queued"]];
    Column[{
      Style["\:300c" <> prompt <> "\:300d\:306e\:4fdd\:5b58\:6e08\:307f\:5019\:88dc " <>
        ToString[Length[versions]] <> " \:4ef6",
        Bold, FontFamily -> "Yu Gothic UI"],
      grid,
      Row[{
        Style["\:9069\:5408\:3059\:308b\:5019\:88dc\:304c\:7121\:3051\:308c\:3070: ",
          FontFamily -> "Yu Gothic UI", FontSize -> 10, GrayLevel[0.4]],
        askBtn}]},
      Spacings -> 0.6]];
SourceVaultPromptVersionsUI[___] :=
  Style["(invalid SourceVaultPromptVersionsUI call)",
    RGBColor[0.7, 0.15, 0.15]];

(* ---------- ClaudeEval-entry saved-prompt proposer ---------- *)

(* --- (i)(ii) saved-prompt loop fix helpers ---
   Meta/display expressions (the promptrouter's own proposal UI) must never be
   captured as a route's TargetExprString, and bare auto-captured HeavyLLM
   one-shots must not be re-proposed (spec section 10.3). *)
iSVPRMetaDisplayHeads = {
  "SourceVaultPromptVersionsUI", "SourceVaultRunPrimaryRoute",
  "SourceVaultProposeSavedPromptRoute", "SourceVaultProposePromptRoute"};
iSVPRIsMetaDisplayExpr[s_String] :=
  Module[{t = StringTrim[s, RegularExpression["[\\s();]+"]]},
    AnyTrue[iSVPRMetaDisplayHeads, StringStartsQ[t, # <> "["] &]];
iSVPRIsMetaDisplayExpr[_] := False;

(* spec 10.3: a saved version is worth offering via the versions UI only if it
   is a user-set primary, or a reusable route (deterministic / light), NOT a
   bare auto-captured HeavyLLM one-shot. *)
iSVPRVersionProposableQ[v_Association] :=
  TrueQ[Lookup[v, "Primary", False]] ||
  Lookup[v, "ReplayClass", "HeavyLLM"] =!= "HeavyLLM" ||
  Lookup[v, "Source", ""] =!= "AutoCapture";
iSVPRVersionProposableQ[_] := False;

Options[SourceVaultProposeSavedPromptRoute] = {"Caller" -> Automatic};

SourceVaultProposeSavedPromptRoute[prompt_String,
                                   opts:OptionsPattern[]] :=
  Module[{normKey, gid, bypass, versions, primary, autoPrimary},
    If[!TrueQ[SourceVault`$SourceVaultPromptSavedProposalActive],
      Return[<|"Status" -> "NotDispatched",
        "Reason" -> "SavedProposalInactive"|>]];
    normKey = iSVPRNormalizePrompt[prompt];
    If[normKey === "",
      Return[<|"Status" -> "NotDispatched", "Reason" -> "EmptyPrompt"|>]];
    (* one-shot bypass set by the "ask the LLM again" button *)
    bypass = SourceVault`$SourceVaultPromptBypassOnce;
    If[StringQ[bypass] && bypass === normKey,
      SourceVault`$SourceVaultPromptBypassOnce = Missing["None"];
      Return[<|"Status" -> "NotDispatched", "Reason" -> "BypassedOnce"|>]];
    gid = iSVPRPromptGroupId[prompt];
    versions = SourceVaultMatchSavedPromptVersions[prompt];
    If[!ListQ[versions] || versions === {},
      Return[<|"Status" -> "NotDispatched", "Reason" -> "NoSavedVersion"|>]];
    primary = SelectFirst[versions,
      TrueQ[Lookup[#, "Primary", False]] &, Missing[]];
    autoPrimary = AssociationQ[primary] &&
      TrueQ[Lookup[primary, "AutoExecute", False]] &&
      Lookup[primary, "ReplaySafety", "Unknown"] === "EnvironmentIndependent" &&
      iSVPRRouteAutoExecutableQ[primary];
    If[autoPrimary,
      Return[With[{g = gid},
        <|"Status" -> "Proposed",
          "ProposedExpression" -> HoldComplete[SourceVaultRunPrimaryRoute[g]],
          "Dispatch" -> "PrimaryAutoExecute", "PromptGroupId" -> gid|>]]];
    (* (ii) spec 10.3 + loop fix: do NOT propose the versions UI when every
       saved version is a bare auto-captured HeavyLLM one-shot (not a reusable
       route). Proposing those caused a re-proposal loop; fall through so the
       normal LLM path answers the prompt. *)
    If[!AnyTrue[versions, iSVPRVersionProposableQ],
      Return[<|"Status" -> "NotDispatched",
        "Reason" -> "OnlyAutoCaptureHeavyLLM", "PromptGroupId" -> gid|>]];
    With[{k = normKey, p = prompt},
      <|"Status" -> "Proposed",
        "ProposedExpression" -> HoldComplete[SourceVaultPromptVersionsUI[k, p]],
        "Dispatch" -> "VersionsUI", "PromptGroupId" -> gid|>]];
SourceVaultProposeSavedPromptRoute[___] :=
  <|"Status" -> "NotDispatched", "Reason" -> "BadArguments"|>;

(* ---------- default-on auto-save ---------- *)

(* A ClaudeEval turn can execute several proposal expressions (e.g.
   FetchNew, then EnsureLoaded; MailView after approval). To replay the
   prompt faithfully we save the WHOLE workflow as one route, keyed by a
   per-turn id, upserted as each expression executes. The async approval
   case is handled because the post-approval execution simply appends. *)
If[!ValueQ[$iSVPRTurnAccum], $iSVPRTurnAccum = <||>];

(* combine executed expression strings into one evaluable workflow that
   returns the last expression's value (the display) *)
iSVPRCombineWorkflowExprs[exprs_List] :=
  Module[{cleaned},
    cleaned = Select[exprs, StringQ[#] && StringTrim[#] =!= "" &];
    cleaned = Map[StringTrim[#, RegularExpression["[\\s;]+"]] &, cleaned];
    cleaned = Select[cleaned, # =!= "" &];
    (* (i) never let the proposal/display UI leak into a saved route *)
    cleaned = Select[cleaned, ! iSVPRIsMetaDisplayExpr[#] &];
    Which[
      cleaned === {},        "",
      Length[cleaned] === 1, First[cleaned],
      (* wrap in parens so the whole workflow is ONE CompoundExpression
         (otherwise ToExpression splits it into a multi-arg HoldComplete
         which neither parses as a single value nor ReleaseHolds right) *)
      True,                  "(\n" <> StringRiffle[cleaned, ";\n"] <> "\n)"]];
iSVPRCombineWorkflowExprs[_] := "";

Options[SourceVaultAutoSaveLastPrompt] = {
  "Memo" -> "", "TurnId" -> Automatic, "ExprString" -> Automatic};

SourceVaultAutoSaveLastPrompt[prompt_String, opts:OptionsPattern[]] :=
  Module[{memo, turnId, exprOpt, exprStr, gid, st, combined, latest},
    If[!TrueQ[SourceVault`$SourceVaultPromptAutoSave],
      Return[<|"Status" -> "Skipped", "Reason" -> "AutoSaveDisabled"|>]];
    If[StringTrim[prompt] === "",
      Return[<|"Status" -> "Skipped", "Reason" -> "EmptyPrompt"|>]];
    memo = OptionValue[SourceVaultAutoSaveLastPrompt, {opts}, "Memo"];
    If[!StringQ[memo], memo = ""];
    turnId  = OptionValue[SourceVaultAutoSaveLastPrompt, {opts}, "TurnId"];
    exprOpt = OptionValue[SourceVaultAutoSaveLastPrompt, {opts}, "ExprString"];
    exprStr = Which[
      StringQ[exprOpt] && StringTrim[exprOpt] =!= "", exprOpt,
      True, Module[{s = Quiet @ Check[
          Symbol["ClaudeCode`$ClaudeEvalLastProposedExprString"], Missing[]]},
        If[StringQ[s] && StringTrim[s] =!= "", s, Missing[]]]];
    (* nothing executable to capture -> skip (we only save replayable runs) *)
    If[!StringQ[exprStr],
      Return[<|"Status" -> "Skipped", "Reason" -> "NoExecutedExpression"|>]];
    (* (i) never capture the promptrouter's own proposal/display expression as a
       route (it would re-show the versions UI on replay -> infinite loop) *)
    If[iSVPRIsMetaDisplayExpr[exprStr],
      Return[<|"Status" -> "Skipped", "Reason" -> "MetaDisplayExpr"|>]];
    (* (iii) spec 10.3: do not route-ify a raw HeavyLLM one-shot (an LLM answer
       with no reusable callable, e.g. ClaudeEval[...] / Print[...]). PromptRun
       history records the run separately; only Replayable / Light routes are
       worth saving and replaying. Keeps the registry free of un-replayable,
       never-proposed HeavyLLM versions. *)
    If[iSVPRClassifyReplay[exprStr] === "HeavyLLM",
      Return[<|"Status" -> "Skipped", "Reason" -> "HeavyLLMOneShot"|>]];
    gid = iSVPRPromptGroupId[prompt];

    (* ---- turn accumulation: one upserted route per turn ---- *)
    If[StringQ[turnId] && turnId =!= "",
      st = Lookup[$iSVPRTurnAccum, turnId, Missing[]];
      If[AssociationQ[st] && st["GroupId"] === gid,
        (* same turn: append this expression and re-save the SAME route *)
        Module[{exprs = st["Exprs"]},
          If[!MemberQ[exprs, exprStr], exprs = Append[exprs, exprStr]];
          combined = iSVPRCombineWorkflowExprs[exprs];
          $iSVPRTurnAccum[turnId] = Join[st, <|"Exprs" -> exprs|>];
          Return[SaveLastPrompt[memo, "PromptText" -> prompt,
            "TargetExprString" -> combined, "RouteId" -> st["RouteId"],
            "Channel" -> st["Channel"], "Auto" -> True]]],
        (* new turn: dedup vs the group's newest version, else new version *)
        combined = iSVPRCombineWorkflowExprs[{exprStr}];
        latest = If[StringQ[gid],
          First[iSVPRGroupRoutes[gid], Missing[]], Missing[]];
        If[AssociationQ[latest] &&
           Lookup[latest, "TargetExprString", Missing[]] === combined,
          Return[<|"Status" -> "Skipped",
            "Reason" -> "DuplicateOfLatestVersion", "PromptGroupId" -> gid|>]];
        Module[{res},
          res = SaveLastPrompt[memo, "PromptText" -> prompt,
            "TargetExprString" -> combined, "ForceNewVersion" -> True,
            "Auto" -> True];
          $iSVPRTurnAccum[turnId] = <|"RouteId" -> Lookup[res, "RouteId", ""],
            "GroupId" -> gid, "Channel" -> Lookup[res, "Channel", "public"],
            "Exprs" -> {exprStr}|>;
          Return[res]]],

      (* ---- no TurnId: single-version save (legacy path) ---- *)
      latest = If[StringQ[gid],
        First[iSVPRGroupRoutes[gid], Missing[]], Missing[]];
      If[AssociationQ[latest] &&
         Lookup[latest, "TargetExprString", Missing[]] === exprStr,
        Return[<|"Status" -> "Skipped",
          "Reason" -> "DuplicateOfLatestVersion", "PromptGroupId" -> gid|>]];
      SaveLastPrompt[memo, "PromptText" -> prompt,
        "TargetExprString" -> exprStr, "ForceNewVersion" -> True,
        "Auto" -> True]]];
SourceVaultAutoSaveLastPrompt[___] :=
  <|"Status" -> "Failed", "Reason" -> "BadArguments"|>;


End[];

EndPackage[];

