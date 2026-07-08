(* ::Package:: *)

(* ============================================================
   SourceVault_autotrigger.wl

   SourceVault auto-trigger scheduler.
   Phase 1 increment 1: registry FOUNDATION only (side-effect free
   by default). NO tick, NO dispatch, NO execution here.

   Implemented in this increment:
     - TriggerSpec structural schema + validation
     - per-trigger registry storage (compiled/auto-triggers/<id>.wxf)
     - register (DryRun default = validate only, no write)
     - list / get / new-id
     - status

   Storage format note: the spec (3.1) suggests <triggerId>.wl, but
   this implementation stores <triggerId>.wxf instead. Rationale:
     - reading a .wl via Get[] would EXECUTE the file; a tampered
       registry file would then run arbitrary code, contradicting the
       spec's own rule (19: never ToExpression the registry). WXF is
       DESERIALIZED, not evaluated -> safe.
     - WXF round-trips WL values the spec uses (Missing[...], Automatic,
       All, Quantity[...]) losslessly, which JSON cannot.

   Later increments added: schedule / condition matching, diagnostics
   gate, tick, dispatch (sync / async subkernel / workflow), scheduler
   registration, UI layer, SpecificMachine placement enforcement
   (validation + job RequiredMachineTags + per-machine dispatch gate),
   and prompt-to-spec parsing (SourceVaultParseAutoTriggerPrompt:
   deterministic patterns first, optional LLM hook fill).

   Still deferred: WorkerPool load balance / failover, machine-health-
   aware eligible-set (liveness of the required machine), cloud comms,
   update / delete / enable flows.

   Design constraints (rule 11 / rule 30 / spec 2.3):
     - Extension of the SourceVault` context, Get[]-loadable, loads
       standalone. No Needs["ClaudeRuntime`"] / ["ClaudeOrchestrator`"].
     - Idempotent reload. All-ASCII source (defer Japanese usage).
   ============================================================ *)

BeginPackage["SourceVault`"];

Quiet[ClearAll[
  "SourceVault`$SourceVaultAutoTriggerVersion",
  "SourceVault`SourceVaultAutoTriggerStatus",
  "SourceVault`SourceVaultNewAutoTriggerId",
  "SourceVault`SourceVaultValidateAutoTrigger",
  "SourceVault`SourceVaultRegisterAutoTrigger",
  "SourceVault`SourceVaultListAutoTriggers",
  "SourceVault`SourceVaultGetAutoTrigger",
  "SourceVault`SourceVaultAutoTriggerScheduleMatch",
  "SourceVault`SourceVaultAutoTriggerNextFire",
  "SourceVault`SourceVaultAutoTriggerConditionMatch",
  "SourceVault`SourceVaultAutoTriggerDiagnosticsGate",
  "SourceVault`SourceVaultAutoTriggerEvaluateTrigger",
  "SourceVault`SourceVaultAutoTriggerTick",
  "SourceVault`SourceVaultAutoTriggerJobQueue",
  "SourceVault`SourceVaultAutoTriggerDispatchJobs",
  "SourceVault`SourceVaultAutoTriggerRunHistory",
  "SourceVault`SourceVaultAutoTriggerDispatchAsync",
  "SourceVault`SourceVaultAutoTriggerPoll",
  "SourceVault`SourceVaultAutoTriggerRunningJobs",
  "SourceVault`SourceVaultAutoTriggerStartScheduler",
  "SourceVault`SourceVaultAutoTriggerStopScheduler",
  "SourceVault`SourceVaultAutoTriggerSchedulerStatus",
  "SourceVault`SourceVaultStartWorkflowForAutoTrigger",
  "SourceVault`SourceVaultAutoTriggerDispatchWorkflows",
  "SourceVault`SourceVaultAutoTriggerRunningWorkflows",
  "SourceVault`SourceVaultAutoTriggerCapability",
  "SourceVault`SourceVaultAutoTriggerListData",
  "SourceVault`SourceVaultAutoTriggerPanel",
  "SourceVault`SourceVaultAutoTriggerSourceIdResolver",
  "SourceVault`SourceVaultAutoTriggerForTarget",
  "SourceVault`SourceVaultAutoTriggerStatusCell",
  "SourceVault`SourceVaultAutoTriggerSourcesURIResolver",
  "SourceVault`SourceVaultAutoTriggerKnownMachineTags",
  "SourceVault`SourceVaultParseAutoTriggerPrompt",
  "SourceVault`SourceVaultEnqueueWorkflowRun",
  "SourceVault`SourceVaultAutoTriggerDispatchCatalogRuns",
  "SourceVault`SourceVaultRemoteWorkflowResult",
  "SourceVault`SourceVaultAutoTriggerWatchRemoteRun"
]];

$SourceVaultAutoTriggerVersion = "0.1-phase1.4";

SourceVaultAutoTriggerStatus::usage =
  "SourceVaultAutoTriggerStatus[] returns the auto-trigger subsystem status \
(version, registry directory, registered-trigger count). Phase 1 registry \
foundation only: no tick / dispatch / execution.";

SourceVaultNewAutoTriggerId::usage =
  "SourceVaultNewAutoTriggerId[] returns a fresh trigger id of the form \
\"autotrg-XXXXXXXXXXXX\".";

SourceVaultValidateAutoTrigger::usage =
  "SourceVaultValidateAutoTrigger[spec_Association] structurally validates a \
TriggerSpec (required keys, Type, TargetType / Owner.Mode / Schedule.Kind / \
ExecutionPlacement.Mode enums, Enabled boolean). ExecutionPlacement Mode \
\"SpecificMachine\" additionally REQUIRES a non-empty RequiredMachineTags list \
(spec 3.1); tags not found among the known machines (this machine + the \
diagnostics machine registry) are a warning only. Returns <|\"Valid\" -> Bool, \
\"Issues\" -> {...}, \"Warnings\" -> {...}, \"TriggerId\" -> _|>. Does NOT check \
live target existence / URI resolution (deferred to dispatch-time layers).";

SourceVaultRegisterAutoTrigger::usage =
  "SourceVaultRegisterAutoTrigger[spec_Association, opts] validates a TriggerSpec \
and, only when \"DryRun\" -> False, atomically writes it to \
compiled/auto-triggers/<TriggerId>.wxf. Default \"DryRun\" -> True (validate + \
report the target path, write nothing). Returns a status Association.";

SourceVaultListAutoTriggers::usage =
  "SourceVaultListAutoTriggers[opts] returns a list of registered-trigger \
summaries (TriggerId / Name / Enabled / TargetType / UpdatedAt) read from the \
per-trigger registry files.";

SourceVaultGetAutoTrigger::usage =
  "SourceVaultGetAutoTrigger[triggerId_String] returns the full stored TriggerSpec \
Association, or Missing[\"NotFound\"].";

SourceVaultAutoTriggerScheduleMatch::usage =
  "SourceVaultAutoTriggerScheduleMatch[schedule_Association, lastCheck, now] \
implements the spec 4.7 interval-overlap semantics: it returns whether a fire \
time exists in the half-open interval (lastCheck, now]. lastCheck / now may be \
ISO date strings, DateObjects, or AbsoluteTimes. Pure / side-effect-free. \
Supports Schedule Kind \"Alarm\", \"CalendarPattern\" (Fields + N-week Interval), \
and \"Timer\" (needs an anchor). Returns <|\"Matched\" -> Bool, \"FireTimes\" -> \
{ISO...}, \"Capped\" -> Bool, \"Notes\" -> {...}|>.";

SourceVaultAutoTriggerNextFire::usage =
  "SourceVaultAutoTriggerNextFire[schedule_Association, from, opts] returns the \
next fire time strictly after `from` (ISO string), searching forward up to a \
horizon (option \"HorizonDays\", default 366), or Missing[\"NoFireWithinHorizon\"]. \
Pure / side-effect-free; for preview.";

SourceVaultAutoTriggerConditionMatch::usage =
  "SourceVaultAutoTriggerConditionMatch[condition_Association, context_Association] \
evaluates a Condition DSL node (spec 5): Boolean nodes AllOf / AnyOf / Not (empty \
AllOf = True, empty AnyOf = False) and atoms. READ-ONLY. The SourceVaultEvent atom \
is evaluated against context[\"Events\"] (a synthetic event list, for testing) or, \
when absent, the live SourceVaultSourceEvents[] log (weakly). It maps the spec's \
EventType vocabulary (Updated/Deleted/...) onto the actual log vocabulary \
(VersionedUpdate/Retraction/...), filters by SourceId, and windows by \
context[\"WatermarkEventId\"] (events appended AFTER that EventId). Other atom \
types (SourceVaultPredicate / OrchestratorEvent / ApprovalState / QueueState) and \
URI->SourceId resolution are deferred and reported in \"Notes\". Returns \
<|\"Matched\" -> Bool, \"Notes\" -> {...}|>.";

SourceVaultAutoTriggerDiagnosticsGate::usage =
  "SourceVaultAutoTriggerDiagnosticsGate[spec_Association, context_Association] \
decides whether a trigger MAY dispatch, given diagnostics health (spec 3.3). \
Component-scoped: only the components the workflow needs are checked \
(spec DiagnosticsPolicy.RequiredComponents; Automatic -> {\"LicensePool\"}). \
RequiredHealth \"OK\" requires every required component OK; \"DegradedAccepted\" \
also allows Degraded but never Failing. The doctor result is taken from \
context[\"Doctor\"] (for testing) or the live SourceVaultDiagnosticsLightweightDoctor \
(weakly; machine-local, the safe fallback while multi-PC rollup is not wired). \
RequireDiagnosticsReady -> False, or an exempt system-doctor workflow \
(CreatedBy \"System\" / context[\"Exempt\"] -> True), bypass the gate. Judgment \
only; performs no dispatch. Returns <|\"Allowed\" -> Bool, \"Reason\" -> _, \
\"RequiredComponents\" -> {...}, \"BlockingComponents\" -> {...}, ...|>.";

SourceVaultAutoTriggerEvaluateTrigger::usage =
  "SourceVaultAutoTriggerEvaluateTrigger[spec_Association, context_Association] \
composes the full per-trigger decision in order: Enabled -> Owner -> Schedule \
(spec 4.7) -> Condition (spec 5) -> DiagnosticsGate (spec 3.3) -> Placement. \
PURE / no IO / NO DISPATCH: when every check passes it returns a built (not \
executed) job record with a DispatchSlotKey for later dedup. context supplies \
\"Now\" / \"LastCheck\" (ISO), \"MachineTag\", \"Events\", \"Doctor\" (all \
optional with safe defaults). Returns <|\"WouldFire\" -> Bool, \"Stage\" -> _, \
\"Reason\" -> _, \"Job\" -> _ (when WouldFire), ...|>. The first failing stage \
short-circuits.";

SourceVaultAutoTriggerTick::usage =
  "SourceVaultAutoTriggerTick[opts] reads the enabled triggers from the registry, \
evaluates each via SourceVaultAutoTriggerEvaluateTrigger against the live context \
(now / per-trigger LastCheck state / live source events / machine-local doctor), \
and for triggers that pass every check APPENDS a built job to the append-only job \
log (autotrigger/jobs.jsonl) and advances the per-trigger LastCheck state. It does \
NOT dispatch / execute anything (Dispatched -> False). Same DispatchSlotKey is \
de-duplicated against the existing log. Defers (no-op) when the runtime is \
AsyncActive. Options: \"DryRun\" -> False (when True, evaluate only; write nothing), \
\"LastCheckOverride\" -> Automatic (an ISO string forces the evaluation-window \
lower bound for all triggers; for testing / manual catch-up). Returns a tick \
summary. On the very first tick for a trigger the window is empty (state seeded to \
now) so it does not fire; use LastCheckOverride to evaluate a back-window.";

SourceVaultAutoTriggerJobQueue::usage =
  "SourceVaultAutoTriggerJobQueue[opts] returns the built jobs from the append-only \
job log (autotrigger/jobs.jsonl). Option \"Status\" -> All filters by job Status \
(e.g. \"Built\").";

SourceVaultAutoTriggerDispatchJobs::usage =
  "SourceVaultAutoTriggerDispatchJobs[opts] dispatches built jobs that have not yet \
completed (de-duplicated by DispatchSlotKey against the run log). For each it \
re-checks the diagnostics gate and the subprocess-seat budget, claims the slot, \
and runs the target in a SUBKERNEL (subprocess pool; never the main kernel) under \
a time constraint, then records the run to autotrigger/runs.jsonl. This increment \
only really executes the harmless self-test target TargetType \"PureComputation\" \
(a bounded pure computation in a subkernel, returning its subprocess id to prove \
out-of-process execution); real PromptRoute / Workflow executors are NOT wired \
yet and are recorded as \"ExecutorNotWired\". No LLM / Front End / network / \
dangerous side effects. Placement gate: a job whose ExecutionPlacement is \
\"SpecificMachine\" is executed only on a machine whose tag is in the job's \
RequiredMachineTags (case-insensitive); other machines skip it \
(NotEligibleMachine), leaving it Built for the required machine's dispatcher \
(jobs.jsonl is shared via the vault root). Options: \"DryRun\" -> False, \
\"MaxJobs\" -> 1 (cap per call), \"TimeConstraintSeconds\" -> 30. Returns a \
dispatch summary.";

SourceVaultAutoTriggerRunHistory::usage =
  "SourceVaultAutoTriggerRunHistory[opts] returns the run records from \
autotrigger/runs.jsonl. Option \"Status\" -> All filters (e.g. \"Completed\").";

SourceVaultAutoTriggerDispatchAsync::usage =
  "SourceVaultAutoTriggerDispatchAsync[opts] dispatches async-eligible built jobs \
WITHOUT blocking the main kernel: each is submitted to a persistent clean subkernel \
(ParallelSubmit; subprocess pool, NOT the process pool, and NOT a wolframscript \
process whose heavy init hangs headless) which runs it in the background and writes \
a result file. The call returns immediately. Only TargetType \"PureComputation\" is \
async-eligible here; PromptRoute is main-kernel-gated (manual only). \
SpecificMachine jobs whose RequiredMachineTags exclude this machine are not \
picked up. Use SourceVaultAutoTriggerPoll to finalize. Options: \
\"MaxConcurrent\" -> 1, \"TimeConstraintSeconds\" -> 120.";

SourceVaultAutoTriggerPoll::usage =
  "SourceVaultAutoTriggerPoll[] advances the subkernel queue and finalizes async \
jobs whose result file has appeared (records Completed/Failed to runs.jsonl and \
harvests the subkernel). Jobs past their TimeConstraint are recorded TimedOut. \
Non-blocking; intended to be called from the shared polling tick (next increment).";

SourceVaultAutoTriggerRunningJobs::usage =
  "SourceVaultAutoTriggerRunningJobs[] returns the currently in-flight async jobs \
(slot / trigger / elapsed seconds / time constraint).";

SourceVaultAutoTriggerStartScheduler::usage =
  "SourceVaultAutoTriggerStartScheduler[opts] registers the auto-trigger scheduler \
on claudecode's shared polling base (ClaudeRegisterPollingTick), weakly and OPT-IN \
(not started on load). Each fire (throttled to \"IntervalSeconds\", default 60) \
runs, non-blocking: Poll (finalize finished async jobs) -> Tick (evaluate enabled \
triggers, build jobs) -> DispatchAsync (submit async-eligible jobs to subkernels). \
Main-kernel-gated targets (PromptRoute) are NOT auto-dispatched here (they would \
block); they remain manual. Defers while the runtime is AsyncActive. The subkernel \
pool is pre-launched here so the tick never blocks on kernel startup. It does NOT \
create its own ScheduledTask (rule 95).";

SourceVaultAutoTriggerStopScheduler::usage =
  "SourceVaultAutoTriggerStopScheduler[] unregisters the auto-trigger scheduler \
from the shared polling base.";

SourceVaultAutoTriggerSchedulerStatus::usage =
  "SourceVaultAutoTriggerSchedulerStatus[] reports whether the scheduler is \
registered on the shared tick, the interval, the last scheduler-tick summary, and \
the in-flight async jobs.";

SourceVaultStartWorkflowForAutoTrigger::usage =
  "SourceVaultStartWorkflowForAutoTrigger[wid_String, metadata_Association] is the \
auto-trigger adapter onto ClaudeOrchestrator. It weakly checks orchestrator \
availability and, if present, kicks off ClaudeRunWorkflow[wid, \"Async\"->True] \
(non-blocking: returns immediately while the workflow advances on the shared \
polling tick). SourceVaultStartWorkflowForAutoTrigger[spec_Association, metadata] \
first instantiates the net via ClaudeCreateWorkflowNet[spec] and kicks that off. \
Returns <|\"Status\", \"WorkflowId\", ...|>. Does NOT block on completion; poll \
via SourceVaultAutoTriggerPoll / ClaudeAsyncJobInfo.";

SourceVaultAutoTriggerDispatchWorkflows::usage =
  "SourceVaultAutoTriggerDispatchWorkflows[opts] kicks off Built WorkflowRoute / \
WorkflowTemplate jobs non-blocking via ClaudeRunWorkflow Async (main kernel, gated \
on LicensePool). FE-required targets are deferred (not auto-run from the tick). \
SpecificMachine jobs whose RequiredMachineTags exclude this machine are not \
picked up. Options: \"MaxConcurrent\"->1, \"TimeConstraintSeconds\"->600.";

SourceVaultAutoTriggerRunningWorkflows::usage =
  "SourceVaultAutoTriggerRunningWorkflows[] returns the workflow runs kicked off by \
the auto-trigger and still being polled (wid / trigger / elapsed).";

SourceVaultAutoTriggerCapability::usage =
  "SourceVaultAutoTriggerCapability[spec] derives the list-display classification of \
a trigger (spec section 8): <|\"AutoRunCapability\", \"ExecutionMode\" (label), \
\"AutoEligible\"|>. HeadlessAsync for subkernel / workflow-async targets; \
BlockingSyncUserInitiated for main-kernel PromptRoute; FrontendRequired for \
FE-bound workflows; Unknown otherwise.";

SourceVaultAutoTriggerListData::usage =
  "SourceVaultAutoTriggerListData[] returns one row Association per registered \
trigger for the UI: TriggerId / Name / Enabled / ExecutionMode / Placement \
(\:5b9f\:884cPC label: \:74b0\:5883\:975e\:4f9d\:5b58 | pool: <name> | \:56fa\:5b9a: <tags>) / AutoRunCapability \
/ AutoToggle (ON|OFF|\:4e0d\:53ef) / Priority / NextFire / LastRunStatus / HasError / \
ErrorSummary (cloud-safe metadata only). Pure read; no dispatch.";

SourceVaultAutoTriggerPanel::usage =
  "SourceVaultAutoTriggerPanel[] renders a Grid of the registered triggers with \
execution mode, auto-run capability, auto toggle state, a colored priority badge, \
next fire and last run, plus a warning icon for triggers whose last run failed - \
clicking the icon opens the saved (metadata-only) error summary. A diagnostics \
status band is shown on top when SourceVault_diagnostics is loaded.";

SourceVaultAutoTriggerSourceIdResolver::usage =
  "SourceVaultAutoTriggerSourceIdResolver is a settable hook: a function uri -> \
SourceId (String) used by SourceVaultEvent conditions to reconcile a canonical \
sv:// URI to the internal SourceId the event log keys by. Defaults to Automatic \
(no built-in resolver); until wired, a URI atom matches only events that carry \
that URI directly.";

SourceVaultAutoTriggerForTarget::usage =
  "SourceVaultAutoTriggerForTarget[targetType, targetId] returns the \
SourceVaultAutoTriggerListData row for the registered trigger whose Target matches \
(e.g. a WorkflowTemplate trigger for a catalog slug), or Missing[\"NoTrigger\"]. \
Lets the existing workflow / saved-prompt lists show auto-run status per row.";

SourceVaultAutoTriggerStatusCell::usage =
  "SourceVaultAutoTriggerStatusCell[targetType, targetId] renders a compact cell \
(auto toggle badge + priority + warning icon) for the trigger on that target, or a \
gray dash when none is registered. Designed to drop into an existing list Grid.";

SourceVaultAutoTriggerSourcesURIResolver::usage =
  "SourceVaultAutoTriggerSourcesURIResolver[uri] resolves a canonical sv:// URI to \
a SourceId via SourceVaultSources (opt-in; assign it to \
SourceVaultAutoTriggerSourceIdResolver to let SourceVaultEvent conditions match by \
URI). Returns Missing when the URI is not found or the sources listing is \
unavailable.";

SourceVaultAutoTriggerKnownMachineTags::usage =
  "SourceVaultAutoTriggerKnownMachineTags[] returns the machine tags known to \
this vault: this machine's tag, the AUTHORITATIVE runtime machine list \
(SourceVaultListRuntimeMachines, the PCs actually sharing the vault per the \
on-disk runtime/ tree), and every MachineTag in the diagnostics machine \
registry (weakly; the registry is unioned in but is not the source of truth, \
since it can lag or carry stale test entries). All refs are weak (no service \
manager / diagnostics -> just this machine). Used by the SpecificMachine \
placement validation (unknown-tag warning) and by \
SourceVaultParseAutoTriggerPrompt (machine-name detection in prompts).";

SourceVaultParseAutoTriggerPrompt::usage =
  "SourceVaultParseAutoTriggerPrompt[prompt_String, target_Association, opts] \
converts a natural-language trigger request (Japanese / English) into a \
TriggerSpec (spec 10). Deterministic-first, NO LLM needed for the common \
forms: schedule (\:6bce\:9031/\:9694\:9031/\:6bce\:65e5/\:6bce\:6708/N\:6642\:9593\:3054\:3068/ISO alarm/N\:6642\:9593\:5f8c timer, \
weekly/daily/every N hours), sv:// URIs + \:66f4\:65b0 -> SourceVaultEvent Updated \
condition, machine placement (\"<tag>\:3067\:5b9f\:884c\" / \"run on <tag>\" / any known \
machine tag in the prompt -> ExecutionPlacement SpecificMachine + \
RequiredMachineTags), priority words, and \"1\:56de\:3060\:3051\" -> MaxRunsPerWindow \
1/day. When the SCHEDULE cannot be parsed and an LLM hook is available \
(option \"LLMFunction\" -> fn, or the settable hook \
SourceVaultAutoTriggerPromptLLM), the LLM fills only the missing slots: it \
receives one instruction+prompt String, must return a JSON object (spec \
10.2), which is RawJSON-parsed (NEVER ToExpression) and key-whitelisted. The \
original prompt is stored HashOnly (privacy default). Returns \
<|\"Status\" -> \"OK\"|\"NeedsClarification\"|\"Failed\", \"TriggerSpec\" -> spec \
(always Enabled -> False; review then SourceVaultRegisterAutoTrigger), \
\"Explanation\", \"Questions\", \"Warnings\", \"Validation\", \
\"NextFirePreview\"|>. Options: \"TimeZone\" -> \"Asia/Tokyo\", \
\"KnownMachineTags\" -> Automatic, \"LLMFunction\" -> Automatic, \"Now\" -> \
Automatic (ISO string for reproducible tests).";

SourceVaultEnqueueWorkflowRun::usage =
  "SourceVaultEnqueueWorkflowRun[slug_String, machineTag_String, opts] enqueues a \
one-shot \"run this catalog workflow (slug) on <machineTag>\" job into the shared \
auto-trigger job log (autotrigger/jobs.jsonl). The job is self-contained \
(SpecificMachine placement, no registered trigger); the TARGET PC's scheduler \
picks it up via the same placement gate as auto-triggers and runs it locally via \
SourceVaultRunWorkflowAsync. Used by the workflow-list panel's per-row run button \
when a NON-local machine is chosen (a local run executes immediately instead). \
Option \"Form\" -> \"run\". Returns <|\"Status\" -> \"Enqueued\" | \"EnqueueFailed\", \
\"Slug\", \"MachineTag\", \"DispatchSlotKey\", \"EligibleHere\", \"Note\"|>. NOTE: \
the target PC must have SourceVaultAutoTriggerStartScheduler[] running to pick the \
job up.";

SourceVaultAutoTriggerDispatchCatalogRuns::usage =
  "SourceVaultAutoTriggerDispatchCatalogRuns[opts] runs the CatalogWorkflow jobs \
(enqueued by SourceVaultEnqueueWorkflowRun) that THIS machine is allowed to \
execute (placement gate: RequiredMachineTags includes this machine). Each is \
launched non-blocking via SourceVaultRunWorkflowAsync (external process) and \
recorded to autotrigger/runs.jsonl as CatalogRunSubmitted (a spoken-for terminal \
status, so it is not re-dispatched). No orchestrator dependency. Wired into the \
scheduler tick, so a machine with the scheduler running auto-picks up runs \
addressed to it. Option \"MaxRuns\" -> 4 per call. Returns a dispatch summary.";

SourceVaultRemoteWorkflowResult::usage =
  "SourceVaultRemoteWorkflowResult[dispatchSlotKey_String] retrieves the result \
of a REMOTE catalog-workflow run (enqueued with SourceVaultEnqueueWorkflowRun \
and executed on another PC). The executing PC publishes the external job's \
output.wxf into the shared vault (autotrigger/results/) when it finishes; this \
imports it from any PC. Returns the workflow result (e.g. a View), \
Failure[\"CatalogRunFailed\", ...] when the run failed (Reason/MachineTag/\
FinishedAtUTC), Missing[\"StillRunning\"|\"ResultSyncing\"|\"NotFinished\"|\
\"NotFound\", slot] otherwise. The requester's notebook receives an evaluatable \
cell with this call automatically when the run completes (see \
SourceVaultAutoTriggerWatchRemoteRun).";

SourceVaultAutoTriggerWatchRemoteRun::usage =
  "SourceVaultAutoTriggerWatchRemoteRun[dispatchSlotKey, meta] registers a watch \
for a remote catalog run on THIS (requesting) machine. The scheduler tick polls \
the merged run logs and, when the executing PC publishes a terminal record, \
writes into the originating notebook (meta \"Notebook\" -> NotebookObject) via \
the NBAccess final-action queue (WriteNotebookCell; single committer, CellPrint \
fallback): on completion an evaluatable SourceVaultRemoteWorkflowResult[slot] \
cell, on failure / watch timeout ($iSVATRemoteWatchTTLSeconds, default 7200s) a \
red report cell. meta keys: \"Notebook\", \"Slug\", \"MachineTag\". The \
workflow-list panel registers this automatically on remote \"\:5b9f\:884c\". \
Watches are session-local (an FE restart drops them; the result itself is still \
retrievable via SourceVaultRemoteWorkflowResult).";

(* settable hook, deliberately NOT ClearAll'd (idempotent reload keeps it) *)
SourceVaultAutoTriggerPromptLLM::usage =
  "SourceVaultAutoTriggerPromptLLM is a settable hook: a function \
fullPrompt_String -> jsonString used by SourceVaultParseAutoTriggerPrompt when \
the deterministic layer cannot parse the schedule. Default Automatic (no LLM; \
deterministic parsing only). Privacy: prompts may contain private sv:// URIs, \
so route this to a LOCAL model unless the prompt is known cloud-safe (spec \
10.2).";

(* pluggable resolver: slug (String) -> a workflow net wid (String) or a
   ClaudeCreateWorkflowNet spec (Association), or $Failed/Missing when the
   template cannot be resolved without the FE. Default: try the SourceVault
   workflow catalog for an inline executable spec; otherwise unresolved. *)
SourceVaultAutoTriggerWorkflowResolver::usage =
  "SourceVaultAutoTriggerWorkflowResolver is a settable hook: a function slug -> \
(wid_String | spec_Association | $Failed) used to resolve a WorkflowTemplate \
TargetId to something ClaudeRunWorkflow can run. Defaults to a catalog lookup.";

Begin["`Private`"];

(* ---- local helpers ---- *)

iSVATUTCNow[] :=
  Quiet @ Check[
    DateString[{"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute",
       ":", "Second", "Z"}, TimeZone -> 0],
    "unknown"];

iSVATMachineTag[] :=
  StringReplace[ToString[$MachineName],
    Except[LetterCharacter | DigitCharacter | "-" | "_"] .. -> "-"];

(* known machine tags = self + the AUTHORITATIVE runtime machine list
   (SourceVaultListRuntimeMachines, derived from the on-disk runtime/ tree =
   the PCs actually sharing this vault) + the diagnostics machine registry
   (weak / optional; may lag or carry stale test entries, so it is unioned in
   but NOT the source of truth). All refs are weak so autotrigger still loads
   standalone. Comparisons elsewhere are case-insensitive: $MachineName is
   lowercase on Windows while specs / prompts carry display casing. *)
iSVATKnownMachineTags[] :=
  Module[{runtime = {}, reg = {}, regTags},
    If[Length[Names["SourceVault`SourceVaultListRuntimeMachines"]] > 0,
      runtime = Quiet @ Check[
        ToExpression["SourceVault`SourceVaultListRuntimeMachines"][], {}]];
    If[!ListQ[runtime], runtime = {}];
    If[Length[Names["SourceVault`SourceVaultDiagnosticsMachineRegistry"]] > 0,
      reg = Quiet @ Check[
        ToExpression["SourceVault`SourceVaultDiagnosticsMachineRegistry"][], {}]];
    If[!ListQ[reg], reg = {}];
    regTags = Select[
      (Lookup[#, "MachineTag", Missing[]] &) /@ Select[reg, AssociationQ],
      StringQ];
    DeleteDuplicates @ Join[{iSVATMachineTag[]},
      Select[runtime, StringQ], regTags]];

SourceVaultAutoTriggerKnownMachineTags[] := iSVATKnownMachineTags[];

iSVATRoot[] :=
  Module[{r = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed]},
    If[StringQ[r] && r =!= "", r, $Failed]];

iSVATRegistryDir[] :=
  Module[{root = iSVATRoot[]},
    If[root === $Failed, $Failed,
      FileNameJoin[{root, "compiled", "auto-triggers"}]]];

iSVATEnsureDir[dir_String] :=
  Quiet @ Check[
    If[!DirectoryQ[dir], CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    dir, $Failed];

iSVATTriggerPath[id_String] :=
  Module[{dir = iSVATRegistryDir[]},
    If[dir === $Failed, $Failed, FileNameJoin[{dir, id <> ".wxf"}]]];

iSVATAtomicExportWXF[path_String, expr_] :=
  Module[{tmp = path <> ".tmp"},
    If[iSVATEnsureDir[DirectoryName[path]] === $Failed, Return[$Failed]];
    Quiet @ Check[
      Export[tmp, expr, "WXF"];
      If[FileExistsQ[path], DeleteFile[path]];
      RenameFile[tmp, path];
      path, $Failed]];

(* ---- enums ---- *)

$iSVATTargetTypes = {"PromptRoute", "WorkflowRoute", "WorkflowTemplate",
   "PureComputation", "CatalogWorkflow"};
$iSVATOwnerModes = {"OwnerMachine", "Lease"};
$iSVATScheduleKinds = {"Alarm", "Timer", "CalendarPattern", "Cron"};
$iSVATPlacementModes = {"EnvironmentIndependent", "WorkerPool", "SpecificMachine"};
$iSVATRequiredTopKeys = {"Type", "SchemaVersion", "TriggerId", "Target",
   "Enabled", "Schedule"};

(* ---- id ---- *)

SourceVaultNewAutoTriggerId[] :=
  "autotrg-" <> StringTake[StringReplace[CreateUUID[], "-" -> ""], 12];

(* ---- validation ---- *)

SourceVaultValidateAutoTrigger[spec_Association] :=
  Module[{issues = {}, warns = {}, target, owner, sched, place, tid, en},
    Scan[
      Function[k,
        If[!KeyExistsQ[spec, k], AppendTo[issues, "MissingKey:" <> k]]],
      $iSVATRequiredTopKeys];
    If[Lookup[spec, "Type", Null] =!= "AutoTrigger",
      AppendTo[issues, "TypeMustBeAutoTrigger"]];
    tid = Lookup[spec, "TriggerId", Null];
    If[!StringQ[tid], AppendTo[issues, "TriggerIdNotString"],
      If[!StringStartsQ[tid, "autotrg-"],
        AppendTo[warns, "TriggerIdPrefixNotAutotrg"]]];
    en = Lookup[spec, "Enabled", Null];
    If[!BooleanQ[en], AppendTo[issues, "EnabledNotBoolean"]];
    (* Target *)
    target = Lookup[spec, "Target", Null];
    If[!AssociationQ[target], AppendTo[issues, "TargetNotAssociation"],
      If[!MemberQ[$iSVATTargetTypes, Lookup[target, "TargetType", Null]],
        AppendTo[issues, "TargetTypeInvalid"]];
      If[!StringQ[Lookup[target, "TargetId", Null]],
        AppendTo[issues, "TargetIdNotString"]]];
    (* Owner (optional) *)
    owner = Lookup[spec, "Owner", Missing[]];
    If[AssociationQ[owner],
      If[!MemberQ[$iSVATOwnerModes, Lookup[owner, "Mode", Null]],
        AppendTo[issues, "OwnerModeInvalid"]];
      If[Lookup[owner, "Mode", Null] === "Lease" &&
         !IntegerQ[Lookup[owner, "LeaseTTLSeconds", Null]],
        AppendTo[warns, "LeaseTTLSecondsMissing"]]];
    (* Schedule *)
    sched = Lookup[spec, "Schedule", Null];
    If[!AssociationQ[sched], AppendTo[issues, "ScheduleNotAssociation"],
      If[!MemberQ[$iSVATScheduleKinds, Lookup[sched, "Kind", Null]],
        AppendTo[issues, "ScheduleKindInvalid"]]];
    (* ExecutionPlacement (optional). "SpecificMachine" REQUIRES a non-empty
       RequiredMachineTags list (spec 3.1). Tags not among the known machines
       are a warning only: the machine registry is optional and the target PC
       may register later. *)
    place = Lookup[spec, "ExecutionPlacement", Missing[]];
    If[AssociationQ[place],
      Module[{pm = Lookup[place, "Mode", Null], rt, known},
        If[!MemberQ[$iSVATPlacementModes, pm],
          AppendTo[issues, "ExecutionPlacementModeInvalid"]];
        If[pm === "SpecificMachine",
          rt = Lookup[place, "RequiredMachineTags", {}];
          If[!ListQ[rt], rt = {}];
          rt = Select[rt, StringQ];
          If[rt === {},
            AppendTo[issues, "SpecificMachineRequiresMachineTags"],
            known = ToLowerCase /@ iSVATKnownMachineTags[];
            Scan[
              If[!MemberQ[known, ToLowerCase[#]],
                AppendTo[warns, "RequiredMachineTagUnknown:" <> #]] &,
              rt]]]]];
    (* enabling guidance *)
    If[TrueQ[en],
      AppendTo[warns,
        "EnabledTrue:AutoRunCapability+diagnostics gate are enforced at later layers"]];
    <|"Valid" -> (issues === {}),
      "Issues" -> issues,
      "Warnings" -> warns,
      "TriggerId" -> tid|>];

SourceVaultValidateAutoTrigger[_] :=
  <|"Valid" -> False, "Issues" -> {"SpecNotAssociation"}, "Warnings" -> {},
    "TriggerId" -> Missing["NotProvided"]|>;

(* ---- register ---- *)

Options[SourceVaultRegisterAutoTrigger] = {"DryRun" -> True};

SourceVaultRegisterAutoTrigger[spec_Association, opts : OptionsPattern[]] :=
  Module[{v, dryRun, tid, path, toWrite, w},
    v = SourceVaultValidateAutoTrigger[spec];
    dryRun = TrueQ[OptionValue["DryRun"]];
    If[!TrueQ[v["Valid"]],
      Return[<|"Status" -> "Invalid", "Validation" -> v|>]];
    tid = v["TriggerId"];
    path = iSVATTriggerPath[tid];
    If[dryRun,
      Return[<|"Status" -> "DryRun", "Validation" -> v,
        "WouldWriteTo" -> If[path === $Failed, Missing["VaultRootUnresolved"], path],
        "Exists" -> If[path === $Failed, False, FileExistsQ[path]]|>]];
    If[path === $Failed,
      Return[<|"Status" -> "VaultRootUnresolved", "Validation" -> v|>]];
    toWrite = Append[spec, "UpdatedAt" -> iSVATUTCNow[]];
    If[!KeyExistsQ[toWrite, "CreatedAt"] || !StringQ[toWrite["CreatedAt"]],
      toWrite = Append[toWrite, "CreatedAt" -> iSVATUTCNow[]]];
    w = iSVATAtomicExportWXF[path, toWrite];
    If[w === $Failed,
      Return[<|"Status" -> "WriteFailed", "Validation" -> v, "Path" -> path|>]];
    <|"Status" -> "Registered", "TriggerId" -> tid, "Path" -> path,
      "Validation" -> v|>];

(* ---- get / list ---- *)

SourceVaultGetAutoTrigger[triggerId_String] :=
  Module[{path = iSVATTriggerPath[triggerId], r},
    If[path === $Failed || !FileExistsQ[path], Return[Missing["NotFound"]]];
    r = Quiet @ Check[Import[path, "WXF"], $Failed];
    If[AssociationQ[r], r, Missing["Unreadable"]]];

Options[SourceVaultListAutoTriggers] = {};

SourceVaultListAutoTriggers[opts : OptionsPattern[]] :=
  Module[{dir = iSVATRegistryDir[], files},
    If[dir === $Failed || !DirectoryQ[dir], Return[{}]];
    files = FileNames["*.wxf", dir];
    Map[
      Function[f,
        Module[{spec = Quiet @ Check[Import[f, "WXF"], $Failed]},
          If[AssociationQ[spec],
            <|"TriggerId" -> Lookup[spec, "TriggerId", FileBaseName[f]],
              "Name" -> Lookup[spec, "Name", Missing[]],
              "Enabled" -> Lookup[spec, "Enabled", Missing[]],
              "TargetType" -> Lookup[Lookup[spec, "Target", <||>], "TargetType", Missing[]],
              "UpdatedAt" -> Lookup[spec, "UpdatedAt", Missing[]]|>,
            <|"TriggerId" -> FileBaseName[f], "Unreadable" -> True|>]]],
      files]];

(* ---- status ---- *)

SourceVaultAutoTriggerStatus[] :=
  Module[{dir = iSVATRegistryDir[]},
    <|"Version" -> $SourceVaultAutoTriggerVersion,
      "Available" -> True,
      "Phase" -> "registry-foundation (no tick / dispatch / execution)",
      "RegistryDir" -> If[dir === $Failed, Missing["VaultRootUnresolved"], dir],
      "RegisteredCount" ->
        If[dir =!= $Failed && DirectoryQ[dir], Length[FileNames["*.wxf", dir]], 0]|>];

(* ============================================================
   Schedule matching (spec 4 / 4.7). Pure, side-effect-free.
   Interval-overlap: a fire time exists in (lastCheck, now].
   All component extraction uses an explicit TimeZone (headless
   timezone trap; cf. wolfram-license-limits / source-summaries).
   ============================================================ *)

iSVATToDate[x_] :=
  Which[
    Head[x] === DateObject, x,
    StringQ[x], Quiet @ Check[DateObject[x], $Failed],
    NumberQ[x], Quiet @ Check[DateObject[x], $Failed],
    True, $Failed];

iSVATIso[d_] :=
  Quiet @ Check[
    DateString[d, {"Year", "-", "Month", "-", "Day", "T", "Hour", ":",
       "Minute", ":", "Second", "Z"}, TimeZone -> 0],
    DateString[d]];

iSVATFieldMatch[spec_, val_] :=
  Which[
    spec === All, True,
    IntegerQ[spec], val === spec,
    StringQ[spec], val === spec,
    ListQ[spec], MemberQ[spec, val],
    AssociationQ[spec] && KeyExistsQ[spec, "Range"],
      With[{r = spec["Range"]},
        ListQ[r] && Length[r] === 2 && IntegerQ[val] && r[[1]] <= val <= r[[2]]],
    AssociationQ[spec] && KeyExistsQ[spec, "Every"],
      With[{e = spec["Every"], o = Lookup[spec, "Offset", 0]},
        IntegerQ[e] && e > 0 && IntegerQ[val] && Mod[val - o, e] === 0],
    True, False];

iSVATResolveFields[fields_Association] :=
  <|"Year" -> Lookup[fields, "Year", All],
    "Month" -> Lookup[fields, "Month", All],
    "Day" -> Lookup[fields, "Day", All],
    "Weekday" -> Lookup[fields, "Weekday", All],
    "Hour" -> Lookup[fields, "Hour", 0],
    "Minute" -> Lookup[fields, "Minute", 0],
    "Second" -> Lookup[fields, "Second", 0]|>;

(* minute granularity only when Second is exactly 0; else second granularity *)
iSVATNeedsSecondGran[fr_] := fr["Second"] =!= 0;

iSVATInstantMatchQ[fr_Association, d_, tz_] :=
  Module[{dd = DateObject[d, TimeZone -> tz], c, yr, mo, day, hr, mi, se, wd},
    (* request Y/M/D/H/Min (always extractable for minute+ granularity);
       Second separately -> Missing on a minute-granularity DateObject, in
       which case it is treated as 0 (such instants are at :00). *)
    c = Quiet @ Check[
      DateValue[dd, {"Year", "Month", "Day", "Hour", "Minute"}], $Failed];
    If[!ListQ[c] || Length[c] =!= 5, Return[False]];
    {yr, mo, day, hr, mi} = c;
    se = Quiet @ Check[DateValue[dd, "Second"], 0];
    se = If[NumberQ[se], Round[se], 0];
    wd = Quiet @ Check[DateString[dd, "DayName"], ""];
    iSVATFieldMatch[fr["Year"], yr] && iSVATFieldMatch[fr["Month"], mo] &&
    iSVATFieldMatch[fr["Day"], day] && iSVATFieldMatch[fr["Weekday"], wd] &&
    iSVATFieldMatch[fr["Hour"], hr] && iSVATFieldMatch[fr["Minute"], mi] &&
    iSVATFieldMatch[fr["Second"], se]];

iSVATIntervalOkQ[interval_, d_, tz_] :=
  Module[{unit, every, anchorD, weeks},
    If[!AssociationQ[interval], Return[True]];
    unit = Lookup[interval, "Unit", "Weeks"];
    every = Lookup[interval, "Every", 1];
    If[unit =!= "Weeks" || !IntegerQ[every] || every <= 1, Return[True]];
    anchorD = iSVATToDate[Lookup[interval, "AnchorDate", Null]];
    If[anchorD === $Failed, Return[True]];
    weeks = Round[(AbsoluteTime[DateObject[d, TimeZone -> tz]] -
        AbsoluteTime[anchorD]) / (7.*86400)];
    Mod[weeks, every] === 0];

iSVATCalendarFires[schedule_, fromA_, toA_, maxFires_] :=
  Module[{tz, fr, granU, fires = {}, cap = 100000, n = 0, cur, curA, interval},
    tz = Lookup[schedule, "TimeZone", "Asia/Tokyo"];
    fr = iSVATResolveFields[Lookup[schedule, "Fields", <||>]];
    interval = Lookup[schedule, "Interval", Missing[]];
    granU = If[iSVATNeedsSecondGran[fr], "Second", "Minute"];
    cur = Quiet @ Check[DateObject[fromA, granU, TimeZone -> tz], $Failed];
    If[cur === $Failed, Return[<|"FireTimes" -> {}, "Capped" -> False|>]];
    While[True,
      curA = AbsoluteTime[cur];
      If[curA > toA || n >= cap || Length[fires] >= maxFires, Break[]];
      If[curA > fromA && iSVATInstantMatchQ[fr, cur, tz] &&
         iSVATIntervalOkQ[interval, cur, tz],
        AppendTo[fires, iSVATIso[cur]]];
      cur = DatePlus[cur, {1, granU}];
      n++];
    <|"FireTimes" -> fires, "Capped" -> (n >= cap)|>];

iSVATAfterSeconds[a_] :=
  If[!AssociationQ[a], $Failed,
    Module[{q = Lookup[a, "Quantity", Null], u = Lookup[a, "Unit", "Seconds"], mult},
      mult = Lookup[<|"Seconds" -> 1, "Minutes" -> 60, "Hours" -> 3600,
        "Days" -> 86400, "Weeks" -> 604800|>, u, $Failed];
      If[NumberQ[q] && NumberQ[mult], q*mult, $Failed]]];

iSVATScheduleMatchImpl[schedule_Association, fromA_, toA_, maxFires_] :=
  Module[{kind = Lookup[schedule, "Kind", Null], dt, a, anchor, secs, f},
    Switch[kind,
      "Alarm",
        dt = iSVATToDate[Lookup[schedule, "DateTime", Null]];
        If[dt === $Failed,
          Return[<|"Matched" -> False, "FireTimes" -> {}, "Capped" -> False,
            "Notes" -> {"AlarmDateTimeInvalid"}|>]];
        a = AbsoluteTime[dt];
        f = If[a > fromA && a <= toA, {iSVATIso[dt]}, {}];
        <|"Matched" -> (f =!= {}), "FireTimes" -> f, "Capped" -> False, "Notes" -> {}|>,
      "CalendarPattern",
        f = iSVATCalendarFires[schedule, fromA, toA, maxFires];
        <|"Matched" -> (f["FireTimes"] =!= {}), "FireTimes" -> f["FireTimes"],
          "Capped" -> f["Capped"], "Notes" -> {}|>,
      "Timer",
        anchor = iSVATToDate[Lookup[schedule, "Anchor",
          Lookup[schedule, "AnchorAt", Null]]];
        If[anchor === $Failed,
          Return[<|"Matched" -> False, "FireTimes" -> {}, "Capped" -> False,
            "Notes" -> {"TimerNeedsAnchor"}|>]];
        secs = iSVATAfterSeconds[Lookup[schedule, "After", Null]];
        If[secs === $Failed,
          Return[<|"Matched" -> False, "FireTimes" -> {}, "Capped" -> False,
            "Notes" -> {"TimerAfterInvalid"}|>]];
        a = AbsoluteTime[anchor] + secs;
        f = If[a > fromA && a <= toA, {iSVATIso[DateObject[a]]}, {}];
        <|"Matched" -> (f =!= {}), "FireTimes" -> f, "Capped" -> False, "Notes" -> {}|>,
      "Cron",
        If[AssociationQ[Lookup[schedule, "NormalizedTo", Null]],
          iSVATScheduleMatchImpl[schedule["NormalizedTo"], fromA, toA, maxFires],
          <|"Matched" -> False, "FireTimes" -> {}, "Capped" -> False,
            "Notes" -> {"CronNotNormalized"}|>],
      _,
        <|"Matched" -> False, "FireTimes" -> {}, "Capped" -> False,
          "Notes" -> {"UnknownScheduleKind"}|>]];

SourceVaultAutoTriggerScheduleMatch[schedule_Association, lastCheck_, now_] :=
  Module[{fromD = iSVATToDate[lastCheck], toD = iSVATToDate[now]},
    If[fromD === $Failed || toD === $Failed,
      Return[<|"Matched" -> False, "FireTimes" -> {}, "Capped" -> False,
        "Notes" -> {"BadDateInput"}|>]];
    iSVATScheduleMatchImpl[schedule, AbsoluteTime[fromD], AbsoluteTime[toD], Infinity]];

Options[SourceVaultAutoTriggerNextFire] = {"HorizonDays" -> 366};

SourceVaultAutoTriggerNextFire[schedule_Association, from_, opts : OptionsPattern[]] :=
  Module[{fromD = iSVATToDate[from], horizon = OptionValue["HorizonDays"], fromA, m},
    If[fromD === $Failed, Return[Missing["BadDateInput"]]];
    fromA = AbsoluteTime[fromD];
    m = iSVATScheduleMatchImpl[schedule, fromA, fromA + horizon*86400., 1];
    If[TrueQ[m["Matched"]] && m["FireTimes"] =!= {},
      First[m["FireTimes"]], Missing["NoFireWithinHorizon"]]];

(* ============================================================
   Condition matching (spec 5). READ-ONLY. Boolean combinators +
   SourceVaultEvent atom. Bridges the spec's URI / {Updated,...}
   vocabulary onto the actual log's SourceId / {VersionedUpdate,...}.
   ============================================================ *)

(* spec EventType -> actual source-events.jsonl EventType(s). The log today
   emits VersionedUpdate / Retraction (SourceVault.wl); the rest are forward-
   compatible names that simply never match until a producer emits them. An
   unmapped type falls through to itself, so a literal actual type also works. *)
iSVATMapEventType[t_] :=
  Lookup[<|
    "Updated" -> {"VersionedUpdate"},
    "Ingested" -> {"VersionedUpdate"},
    "Deleted" -> {"SourceDeletion", "Retraction"},
    "Retracted" -> {"Retraction"},
    "MetadataChanged" -> {"SchemaChange"},
    "ClaimChanged" -> {"ClaimChanged"},
    "RegistryChanged" -> {"RegistryChanged"}|>, t, {t}];

If[!ValueQ[SourceVaultAutoTriggerSourceIdResolver],
  SourceVaultAutoTriggerSourceIdResolver = Automatic];

(* No built-in sv:// URI -> SourceId map exists yet (URI is the canonical
   cross-environment key, SourceId is the internal/per-machine key the event
   log uses). A producer can wire SourceVaultAutoTriggerSourceIdResolver; until
   then a URI atom matches an event only if the event itself carries that URI. *)
iSVATDefaultURIToSourceId[uri_] := Missing["NoDefaultResolver"];

(* opt-in producer-side resolver: map a canonical sv:// URI -> SourceId via the
   SourceVault sources listing (rows carry both URI and Id/SourceId). Not the
   default (a full sources scan per resolution is not free, and a row Id is not
   guaranteed to equal the event-log SourceId for every Kind); enable it with
     SourceVaultAutoTriggerSourceIdResolver = SourceVaultAutoTriggerSourcesURIResolver
   after confirming the mapping holds for your vault. *)
SourceVaultAutoTriggerSourcesURIResolver[uri_String] :=
  Module[{rows, match, sid},
    If[Length[Names["SourceVault`SourceVaultSources"]] == 0,
      Return[Missing["NoSourcesFn"]]];
    rows = Quiet @ Check[SourceVault`SourceVaultSources["", "Format" -> "Rows"], $Failed];
    If[!ListQ[rows], Return[Missing["SourcesUnavailable"]]];
    match = SelectFirst[rows, Lookup[#, "URI", ""] === uri &, Missing[]];
    If[!AssociationQ[match], Return[Missing["URINotFound"]]];
    sid = Lookup[match, "SourceId", Lookup[match, "Id", Missing[]]];
    If[StringQ[sid], sid, Missing["NoSourceId"]]];

iSVATResolveURIToSourceId[uri_] :=
  Module[{resolver = SourceVaultAutoTriggerSourceIdResolver, r},
    If[!StringQ[uri], Return[Missing["NoURI"]]];
    r = If[resolver === Automatic, iSVATDefaultURIToSourceId[uri],
      Quiet @ Check[resolver[uri], Missing["ResolverFailed"]]];
    If[StringQ[r], r, Missing["URIUnresolved"]]];

(* events appended AFTER the watermark EventId (append-only order) *)
iSVATEventsSince[events_List, wm_] :=
  If[!StringQ[wm], events,
    Module[{ids = (Lookup[#, "EventId", ""] &) /@ events, pos},
      pos = FirstPosition[ids, wm, Missing[], {1}];
      If[MissingQ[pos], events, Drop[events, pos[[1]]]]]];

iSVATResolveEvents[ctx_Association] :=
  Module[{ev = Lookup[ctx, "Events", Automatic]},
    If[ListQ[ev], Return[ev]];
    If[Length[Names["SourceVault`SourceVaultSourceEvents"]] > 0,
      ev = Quiet @ Check[ToExpression["SourceVault`SourceVaultSourceEvents"][], {}],
      ev = {}];
    If[ListQ[ev], ev, {}]];

iSVATEventAtomMatch[atom_Association, ctx_Association] :=
  Module[{events, sid, uri, resolvedSid, wm, windowed, condType, actualTypes,
          matched, notes = {}},
    events = iSVATResolveEvents[ctx];
    sid = Lookup[atom, "SourceId", Missing[]];
    uri = Lookup[atom, "URI", Missing[]];
    (* reconcile canonical URI -> internal SourceId (the log keys by SourceId) *)
    resolvedSid = If[!StringQ[sid] && StringQ[uri],
      iSVATResolveURIToSourceId[uri], Missing[]];
    If[!StringQ[sid] && StringQ[uri] && !StringQ[resolvedSid],
      AppendTo[notes, "URIUnresolved:matchByEventURIFieldOnly"]];
    wm = Lookup[ctx, "WatermarkEventId", Lookup[atom, "SinceEventId", Missing[]]];
    windowed = iSVATEventsSince[events, wm];
    condType = Lookup[atom, "EventType", "Updated"];
    actualTypes = iSVATMapEventType[condType];
    matched = AnyTrue[windowed,
      Function[e,
        Module[{esid = Lookup[e, "SourceId", ""], euri = Lookup[e, "URI", ""],
                srcOk, typeOk},
          srcOk = Which[
            StringQ[sid], esid === sid,                 (* explicit SourceId *)
            StringQ[resolvedSid], esid === resolvedSid,  (* URI resolved to SourceId *)
            StringQ[uri], euri === uri,                  (* event carries URI (fwd-compat) *)
            True, True];                                 (* no source filter -> any *)
          typeOk = condType === All ||
            MemberQ[actualTypes, Lookup[e, "EventType", ""]] ||
            Lookup[e, "EventType", ""] === condType;
          srcOk && typeOk]]];
    <|"Matched" -> matched, "Notes" -> notes|>];

iSVATAtomMatch[atom_Association, ctx_Association] :=
  Switch[Lookup[atom, "Atom", ""],
    "SourceVaultEvent", iSVATEventAtomMatch[atom, ctx],
    "SourceVaultPredicate",
      <|"Matched" -> False, "Notes" -> {"AtomDeferred:SourceVaultPredicate"}|>,
    "OrchestratorEvent",
      <|"Matched" -> False, "Notes" -> {"AtomDeferred:OrchestratorEvent"}|>,
    "ApprovalState",
      <|"Matched" -> False, "Notes" -> {"AtomDeferred:ApprovalState"}|>,
    "QueueState",
      <|"Matched" -> False, "Notes" -> {"AtomDeferred:QueueState"}|>,
    _, <|"Matched" -> False, "Notes" -> {"UnknownAtom"}|>];

iSVATCombineNotes[rs_List] := Flatten[(#["Notes"] &) /@ rs];

iSVATCondImpl[cond_, ctx_Association] :=
  Which[
    !AssociationQ[cond],
      <|"Matched" -> False, "Notes" -> {"ConditionNotAssociation"}|>,
    KeyExistsQ[cond, "AllOf"],
      With[{rs = (iSVATCondImpl[#, ctx] &) /@ Lookup[cond, "AllOf", {}]},
        <|"Matched" -> AllTrue[rs, TrueQ[#["Matched"]] &],
          "Notes" -> iSVATCombineNotes[rs]|>],
    KeyExistsQ[cond, "AnyOf"],
      With[{rs = (iSVATCondImpl[#, ctx] &) /@ Lookup[cond, "AnyOf", {}]},
        <|"Matched" -> AnyTrue[rs, TrueQ[#["Matched"]] &],
          "Notes" -> iSVATCombineNotes[rs]|>],
    KeyExistsQ[cond, "Not"],
      With[{r = iSVATCondImpl[Lookup[cond, "Not", <||>], ctx]},
        <|"Matched" -> !TrueQ[r["Matched"]], "Notes" -> r["Notes"]|>],
    KeyExistsQ[cond, "Atom"], iSVATAtomMatch[cond, ctx],
    True, <|"Matched" -> False, "Notes" -> {"UnknownConditionNode"}|>];

SourceVaultAutoTriggerConditionMatch[condition_Association, context_Association : <||>] :=
  iSVATCondImpl[condition, context];

(* ============================================================
   Diagnostics gate (spec 3.3). Judgment only; no dispatch.
   Component-scoped + machine-local doctor (safe fallback while
   the multi-PC rollup / aggregator is not yet wired).
   ============================================================ *)

(* backend-aware default: SubkernelAsync-dispatched targets consume the
   SUBPROCESS pool, main-kernel / WolframScriptProcess targets the PROCESS
   pool. So the gate checks the resource the target actually needs, instead
   of always requiring the (scarce) process pool. *)
iSVATDefaultRequiredComponents[spec_Association] :=
  Switch[Lookup[Lookup[spec, "Target", <||>], "TargetType", ""],
    "PureComputation", {"SubprocessPool"},
    "PromptRoute", {"LicensePool"},
    (* workflows run in the MAIN kernel via ClaudeRunWorkflow Async (ride the
       shared tick, non-blocking between steps); they do NOT consume a new
       process / subprocess slot, so no scarce-pool requirement by default.
       FE-freeze is handled by FE-required gating + async-LLM handlers, not
       by the resource gate. A workflow that spawns kernels / processes should
       declare RequiredComponents explicitly in its DiagnosticsPolicy. *)
    "WorkflowTemplate" | "WorkflowRoute", {},
    _, {"LicensePool"}];

iSVATGateRequiredComponents[spec_Association] :=
  Module[{dp = Lookup[spec, "DiagnosticsPolicy", <||>], rc},
    rc = Lookup[dp, "RequiredComponents", Automatic];
    If[ListQ[rc], rc, iSVATDefaultRequiredComponents[spec]]];

iSVATResolveDoctor[context_Association] :=
  Module[{d = Lookup[context, "Doctor", Automatic]},
    If[AssociationQ[d], Return[d]];
    If[Length[Names["SourceVault`SourceVaultDiagnosticsLightweightDoctor"]] > 0,
      d = Quiet @ Check[
        ToExpression["SourceVault`SourceVaultDiagnosticsLightweightDoctor"][], $Failed],
      d = $Failed];
    If[AssociationQ[d], d, $Failed]];

SourceVaultAutoTriggerDiagnosticsGate[spec_Association, context_Association : <||>] :=
  Module[{dp, requireReady, requiredHealth, reqComps, doctor, comp, blocking,
          exempt, allowed, reason},
    dp = Lookup[spec, "DiagnosticsPolicy", <||>];
    requireReady = TrueQ[Lookup[dp, "RequireDiagnosticsReady", True]];
    requiredHealth = Lookup[dp, "RequiredHealth", "OK"];
    exempt = TrueQ[Lookup[context, "Exempt", False]] ||
      Lookup[spec, "CreatedBy", ""] === "System";
    If[exempt,
      Return[<|"Allowed" -> True, "Reason" -> "Exempt(SystemDoctorWorkflow)",
        "RequiredComponents" -> {}, "BlockingComponents" -> {}|>]];
    If[!requireReady,
      Return[<|"Allowed" -> True, "Reason" -> "DiagnosticsGateDisabled",
        "RequiredComponents" -> {}, "BlockingComponents" -> {}|>]];
    doctor = iSVATResolveDoctor[context];
    If[doctor === $Failed,
      Return[<|"Allowed" -> False, "Reason" -> "DiagnosticsNotReady:DoctorUnavailable",
        "RequiredComponents" -> iSVATGateRequiredComponents[spec],
        "BlockingComponents" -> {"Doctor"}|>]];
    reqComps = iSVATGateRequiredComponents[spec];
    comp = Lookup[doctor, "ComponentHealth", <||>];
    blocking = Select[reqComps,
      Function[c,
        Module[{h = Lookup[Lookup[comp, c, <||>], "Health", "Missing"]},
          Which[
            h === "Missing", True,                       (* unverifiable -> block *)
            requiredHealth === "DegradedAccepted", h === "Failing",
            True, h =!= "OK"]]]];
    allowed = (blocking === {});
    reason = If[allowed, "Allowed",
      "DiagnosticsNotReady:" <> StringRiffle[blocking, ","]];
    <|"Allowed" -> allowed, "Reason" -> reason,
      "RequiredComponents" -> reqComps, "BlockingComponents" -> blocking,
      "RequiredHealth" -> requiredHealth,
      "DoctorGlobalHealth" -> Lookup[doctor, "GlobalHealth", Missing[]]|>];

(* ============================================================
   Per-trigger evaluation (spec 11.1 decision pipeline, WITHOUT
   dispatch). Pure composition of the prior checks. Builds a job
   record on full pass; never executes it.
   ============================================================ *)

iSVATOwnerOkQ[owner_, machineTag_] :=
  Module[{mode, tag},
    If[!AssociationQ[owner], Return[True]];
    mode = Lookup[owner, "Mode", "OwnerMachine"];
    Which[
      mode === "OwnerMachine",
        tag = Lookup[owner, "OwnerMachineTag", Automatic];
        (tag === Automatic) || (!StringQ[tag]) || (tag === machineTag),
      mode === "Lease", True,   (* lease evaluated at dispatch (best-effort) *)
      True, True]];

iSVATDispatchSlotKey[spec_, fireTimes_] :=
  Module[{tid = Lookup[spec, "TriggerId", "?"],
          slot = If[ListQ[fireTimes] && fireTimes =!= {}, First[fireTimes], "now"]},
    ToString[tid] <> "@" <> ToString[slot]];

SourceVaultAutoTriggerEvaluateTrigger[spec_Association, context_Association : <||>] :=
  Module[{machineTag, owner, now, lastCheck, sched, schedM, cond, condM,
          gate, placement, placeMode, reqTags, fireTimes, job},
    (* 1. Enabled *)
    If[!TrueQ[Lookup[spec, "Enabled", False]],
      Return[<|"WouldFire" -> False, "Stage" -> "Enabled", "Reason" -> "NotEnabled"|>]];
    (* 2. Owner *)
    machineTag = Lookup[context, "MachineTag", iSVATMachineTag[]];
    owner = Lookup[spec, "Owner", <||>];
    If[!iSVATOwnerOkQ[owner, machineTag],
      Return[<|"WouldFire" -> False, "Stage" -> "Owner",
        "Reason" -> "NotOwnerMachine", "MachineTag" -> machineTag|>]];
    (* 3. Schedule *)
    now = Lookup[context, "Now", iSVATUTCNow[]];
    lastCheck = Lookup[context, "LastCheck", now];
    sched = Lookup[spec, "Schedule", <||>];
    schedM = SourceVaultAutoTriggerScheduleMatch[sched, lastCheck, now];
    If[!TrueQ[schedM["Matched"]],
      Return[<|"WouldFire" -> False, "Stage" -> "Schedule",
        "Reason" -> "NoScheduleMatch", "ScheduleNotes" -> schedM["Notes"]|>]];
    (* 4. Condition (absent / empty -> pass) *)
    cond = Lookup[spec, "Condition", Missing[]];
    condM = If[AssociationQ[cond] && cond =!= <||>,
      SourceVaultAutoTriggerConditionMatch[cond, context],
      <|"Matched" -> True, "Notes" -> {}|>];
    If[!TrueQ[condM["Matched"]],
      Return[<|"WouldFire" -> False, "Stage" -> "Condition",
        "Reason" -> "ConditionNotMet", "ConditionNotes" -> condM["Notes"]|>]];
    (* 5. Diagnostics gate *)
    gate = SourceVaultAutoTriggerDiagnosticsGate[spec, context];
    If[!TrueQ[gate["Allowed"]],
      Return[<|"WouldFire" -> False, "Stage" -> "DiagnosticsGate",
        "Reason" -> gate["Reason"], "Gate" -> gate|>]];
    (* 6. Placement (spec 7.2.1, dispatch-side subset): SpecificMachine must
       carry RequiredMachineTags; the tags are RECORDED ON THE JOB so any
       machine's dispatcher (jobs.jsonl is shared via the vault root) can
       decide locally whether it may execute. Building is deliberately NOT
       restricted to the executing machine: the owner machine builds the job
       even when the executor is another PC. *)
    placement = Lookup[spec, "ExecutionPlacement",
      <|"Mode" -> "EnvironmentIndependent"|>];
    If[!AssociationQ[placement],
      placement = <|"Mode" -> "EnvironmentIndependent"|>];
    placeMode = Lookup[placement, "Mode", "EnvironmentIndependent"];
    reqTags = Lookup[placement, "RequiredMachineTags", {}];
    If[!ListQ[reqTags], reqTags = {}];
    reqTags = Select[reqTags, StringQ];
    If[placeMode === "SpecificMachine" && reqTags === {},
      Return[<|"WouldFire" -> False, "Stage" -> "Placement",
        "Reason" -> "SpecificMachineRequiresMachineTags"|>]];
    (* 7. Build job (NOT dispatched) *)
    fireTimes = schedM["FireTimes"];
    job = <|
      "Type" -> "AutoTriggerJob",
      "TriggerId" -> Lookup[spec, "TriggerId", Missing[]],
      "Target" -> Lookup[spec, "Target", <||>],
      "FireTimes" -> fireTimes,
      "DispatchSlotKey" -> iSVATDispatchSlotKey[spec, fireTimes],
      "MachineTag" -> machineTag,
      "PlacementMode" -> placeMode,
      "RequiredMachineTags" -> reqTags,
      "EligibleHere" -> (placeMode =!= "SpecificMachine" ||
        MemberQ[ToLowerCase /@ reqTags, ToLowerCase[machineTag]]),
      "Priority" -> Lookup[Lookup[spec, "RunPolicy", <||>], "Priority", "Normal"],
      "Status" -> "Built",
      "BuiltAtUTC" -> iSVATUTCNow[],
      "Dispatched" -> False|>;
    <|"WouldFire" -> True, "Stage" -> "Built", "Reason" -> "AllChecksPassed",
      "Job" -> job, "ConditionNotes" -> condM["Notes"]|>];

(* ============================================================
   Tick IO wrapper (spec 11.1). Reads registry, evaluates, records
   built jobs to an append-only log, advances LastCheck state.
   NO DISPATCH / NO EXECUTION in this layer.
   ============================================================ *)

iSVATAsyncActiveQ[] :=
  If[Length[Names["ClaudeRuntime`ClaudeRuntimeAsyncActiveQ"]] > 0,
    TrueQ[Quiet @ Check[
      ToExpression["ClaudeRuntime`ClaudeRuntimeAsyncActiveQ"][], False]],
    False];

iSVATLiveEvents[] :=
  If[Length[Names["SourceVault`SourceVaultSourceEvents"]] > 0,
    Module[{e = Quiet @ Check[
        ToExpression["SourceVault`SourceVaultSourceEvents"][], {}]},
      If[ListQ[e], e, {}]],
    {}];

iSVATLoadEnabledSpecs[] :=
  Module[{dir = iSVATRegistryDir[], files},
    If[dir === $Failed || !DirectoryQ[dir], Return[{}]];
    files = FileNames["*.wxf", dir];
    Select[(Quiet @ Check[Import[#, "WXF"], $Failed] &) /@ files,
      AssociationQ[#] && TrueQ[Lookup[#, "Enabled", False]] &]];

(* per-trigger state under a subdir (excluded from the *.wxf registry glob) *)
iSVATStatePath[id_String] :=
  Module[{dir = iSVATRegistryDir[]},
    If[dir === $Failed, $Failed,
      FileNameJoin[{dir, "state", id <> ".wxf"}]]];

iSVATLoadState[id_String] :=
  Module[{p = iSVATStatePath[id], s},
    If[p === $Failed || !FileExistsQ[p], Return[<||>]];
    s = Quiet @ Check[Import[p, "WXF"], <||>];
    If[AssociationQ[s], s, <||>]];

iSVATSaveState[id_String, state_Association] :=
  Module[{p = iSVATStatePath[id]},
    If[p === $Failed, $Failed, iSVATAtomicExportWXF[p, state]]];

(* ---- multi-machine-safe job/run logs (spec 3.1.1) ----
   jobs.jsonl / runs.jsonl were single SHARED append files; with several
   machines appending (cross-machine dispatch + a per-minute trigger) Dropbox
   produced CONFLICT COPIES and remote machines' appends were lost (observed
   2026-07-07). Fix = single-writer principle, same as machine heartbeats:
   each machine APPENDS ONLY to its own autotrigger/jobs/<machineTag>.jsonl
   (runs/<machineTag>.jsonl) and READS the union of every machine's file plus
   the legacy shared file (pre-phase1.3 history, now read-only). Cross-file
   ordering does not matter: dedup keys on DispatchSlotKey. *)

iSVATJobsLegacyPath[] :=
  Module[{root = iSVATRoot[]},
    If[root === $Failed, $Failed,
      FileNameJoin[{root, "autotrigger", "jobs.jsonl"}]]];

iSVATJobsDir[] :=
  Module[{root = iSVATRoot[]},
    If[root === $Failed, $Failed,
      FileNameJoin[{root, "autotrigger", "jobs"}]]];

iSVATJobsWritePath[] :=
  Module[{d = iSVATJobsDir[]},
    If[d === $Failed, $Failed,
      FileNameJoin[{d, iSVATMachineTag[] <> ".jsonl"}]]];

(* parse one JSONL file -> list of Associations (bad lines skipped) *)
iSVATReadJSONLFile[p_] :=
  Module[{lines},
    If[!StringQ[p] || !FileExistsQ[p], Return[{}]];
    lines = Quiet @ Check[Import[p, {"Text", "Lines"}], {}];
    If[!ListQ[lines], lines = {}];
    Select[(Quiet @ Check[Developer`ReadRawJSONString[#], $Failed] &) /@ lines,
      AssociationQ]];

iSVATReadJobs[] :=
  Module[{legacy = iSVATJobsLegacyPath[], d = iSVATJobsDir[], files},
    files = If[d =!= $Failed && DirectoryQ[d], FileNames["*.jsonl", d], {}];
    If[legacy =!= $Failed, files = Prepend[files, legacy]];
    Join @@ (iSVATReadJSONLFile /@ files)];

iSVATAppendJob[job_Association] :=
  Module[{p = iSVATJobsWritePath[], strm},
    If[p === $Failed, Return[$Failed]];
    If[iSVATEnsureDir[DirectoryName[p]] === $Failed, Return[$Failed]];
    strm = Quiet @ Check[OpenAppend[p, CharacterEncoding -> "UTF-8"], $Failed];
    If[strm === $Failed, Return[$Failed]];
    Quiet @ Check[
      WriteString[strm,
        Developer`WriteRawJSONString[job, "Compact" -> True] <> "\n"];
      Close[strm],
      Close[strm]];
    p];

Options[SourceVaultAutoTriggerTick] = {"DryRun" -> False,
  "LastCheckOverride" -> Automatic};

SourceVaultAutoTriggerTick[opts : OptionsPattern[]] :=
  Module[{dryRun, override, specs, now, mt, events, existingSlots, results = {},
          fired = {}},
    If[iSVATAsyncActiveQ[],
      Return[<|"Status" -> "DeferredAsyncActive"|>]];
    dryRun = TrueQ[OptionValue["DryRun"]];
    override = OptionValue["LastCheckOverride"];
    specs = iSVATLoadEnabledSpecs[];
    now = iSVATUTCNow[];
    mt = iSVATMachineTag[];
    events = iSVATLiveEvents[];
    existingSlots = (Lookup[#, "DispatchSlotKey", Null] &) /@ iSVATReadJobs[];
    Scan[
      Function[spec,
        Module[{tid, state, lastCheck, wm, ctx, eval, slot, dup, appended},
          tid = Lookup[spec, "TriggerId", "?"];
          state = iSVATLoadState[tid];
          lastCheck = If[StringQ[override], override,
            Lookup[state, "LastCheckAt", now]];
          wm = Lookup[state, "WatermarkEventId", Missing[]];
          ctx = <|"Now" -> now, "LastCheck" -> lastCheck, "MachineTag" -> mt,
            "Events" -> events, "WatermarkEventId" -> wm|>;
          eval = SourceVaultAutoTriggerEvaluateTrigger[spec, ctx];
          If[TrueQ[eval["WouldFire"]],
            slot = eval["Job"]["DispatchSlotKey"];
            dup = MemberQ[existingSlots, slot];
            appended = If[dryRun || dup, False,
              iSVATAppendJob[eval["Job"]] =!= $Failed];
            If[appended, AppendTo[existingSlots, slot]; AppendTo[fired, tid]];
            AppendTo[results, <|"TriggerId" -> tid, "WouldFire" -> True,
              "DispatchSlotKey" -> slot, "Appended" -> appended,
              "Duplicate" -> dup|>],
            AppendTo[results, <|"TriggerId" -> tid, "WouldFire" -> False,
              "Stage" -> eval["Stage"], "Reason" -> Lookup[eval, "Reason", ""]|>]];
          If[!dryRun,
            iSVATSaveState[tid, Append[state, "LastCheckAt" -> now]]]]],
      specs];
    <|"Status" -> "Ticked", "AtUTC" -> now, "MachineTag" -> mt,
      "Evaluated" -> Length[specs], "Fired" -> fired,
      "Results" -> results, "DryRun" -> dryRun|>];

Options[SourceVaultAutoTriggerJobQueue] = {"Status" -> All};

SourceVaultAutoTriggerJobQueue[opts : OptionsPattern[]] :=
  Module[{jobs = iSVATReadJobs[], st = OptionValue["Status"]},
    If[st === All || !StringQ[st], jobs,
      Select[jobs, Lookup[#, "Status", ""] === st &]]];

(* ============================================================
   Dispatch (spec 7.2 / 11.1). Plumbing increment: only the harmless
   self-test target "PureComputation" actually executes (in a SUBKERNEL,
   never the main kernel). Real executors are NOT wired yet. No LLM /
   FrontEnd / network / dangerous side effects.
   ============================================================ *)

$iSVATTimeoutSentinel = "iSVATTimedOut";

(* runs: same single-writer scheme as jobs (see iSVATReadJobs comment) *)
iSVATRunsLegacyPath[] :=
  Module[{root = iSVATRoot[]},
    If[root === $Failed, $Failed,
      FileNameJoin[{root, "autotrigger", "runs.jsonl"}]]];

iSVATRunsDir[] :=
  Module[{root = iSVATRoot[]},
    If[root === $Failed, $Failed,
      FileNameJoin[{root, "autotrigger", "runs"}]]];

iSVATRunsWritePath[] :=
  Module[{d = iSVATRunsDir[]},
    If[d === $Failed, $Failed,
      FileNameJoin[{d, iSVATMachineTag[] <> ".jsonl"}]]];

iSVATReadRuns[] :=
  Module[{legacy = iSVATRunsLegacyPath[], d = iSVATRunsDir[], files},
    files = If[d =!= $Failed && DirectoryQ[d], FileNames["*.jsonl", d], {}];
    If[legacy =!= $Failed, files = Prepend[files, legacy]];
    Join @@ (iSVATReadJSONLFile /@ files)];

iSVATAppendRun[run_Association] :=
  Module[{p = iSVATRunsWritePath[], strm},
    If[p === $Failed, Return[$Failed]];
    If[iSVATEnsureDir[DirectoryName[p]] === $Failed, Return[$Failed]];
    strm = Quiet @ Check[OpenAppend[p, CharacterEncoding -> "UTF-8"], $Failed];
    If[strm === $Failed, Return[$Failed]];
    Quiet @ Check[
      WriteString[strm,
        Developer`WriteRawJSONString[run, "Compact" -> True] <> "\n"];
      Close[strm],
      Close[strm]];
    p];

(* slots whose DispatchSlotKey already reached a terminal run status *)
iSVATCompletedSlots[] :=
  Module[{runs = iSVATReadRuns[]},
    DeleteDuplicates @ DeleteCases[
      (If[MemberQ[{"Completed", "Failed", "TimedOut",
            (* a workflow slot is "spoken for" once kicked off (WorkflowStarted),
               so it is not re-dispatched even before it reaches a terminal run;
               this also survives a kernel restart (run is persisted). *)
            "WorkflowStarted", "WorkflowCompleted", "WorkflowFailed",
            "WorkflowTimedOut",
            (* a catalog run is spoken for once its external process is submitted
               (it runs independently; the slot must not be re-dispatched) *)
            "CatalogRunSubmitted"},
           Lookup[#, "Status", ""]],
         Lookup[#, "DispatchSlotKey", Null], Null] &) /@ runs, Null]];

(* placement gate (spec 7.2.1): may THIS machine execute the job? jobs.jsonl
   lives in the shared vault root, so every machine's dispatcher sees every
   built job; a SpecificMachine job is executed only by a machine whose tag is
   in RequiredMachineTags (case-insensitive). SpecificMachine with NO tags is
   eligible NOWHERE (fail-safe; validation rejects such specs). Job records
   from older versions lack the tags field -> fall back to the trigger spec. *)
iSVATJobEligibleHereQ[job_Association] :=
  Module[{mode, tags, tid, spec, place},
    mode = Lookup[job, "PlacementMode", Missing[]];
    tags = Lookup[job, "RequiredMachineTags", Missing[]];
    If[mode === "SpecificMachine" && !ListQ[tags],
      tid = Lookup[job, "TriggerId", Missing[]];
      spec = If[StringQ[tid], SourceVaultGetAutoTrigger[tid], Missing[]];
      place = If[AssociationQ[spec],
        Lookup[spec, "ExecutionPlacement", <||>], <||>];
      If[!AssociationQ[place], place = <||>];
      tags = Lookup[place, "RequiredMachineTags", {}]];
    If[mode =!= "SpecificMachine", Return[True]];
    If[!ListQ[tags], tags = {}];
    MemberQ[ToLowerCase /@ Select[tags, StringQ],
      ToLowerCase[iSVATMachineTag[]]]];

(* best-effort free subprocess slots = max subprocesses - current subkernels *)
iSVATSubprocessSlotsFree[] :=
  Module[{p, max},
    If[Length[Names["SourceVault`SourceVaultDiagnosticsLicenseProbe"]] == 0,
      Return[Missing["Unknown"]]];
    p = Quiet @ Check[
      ToExpression["SourceVault`SourceVaultDiagnosticsLicenseProbe"][], $Failed];
    If[!AssociationQ[p], Return[Missing["Unknown"]]];
    max = Lookup[p, "MaxLicenseSubprocesses", Missing[]];
    If[IntegerQ[max], max - Length[Quiet @ Check[Kernels[], {}]],
      Missing["Unknown"]]];

(* best-effort free PROCESS slots (independent wolframscript / MCP / service /
   FE kernels consume this pool). The external executor used by CatalogWorkflow
   spawns an independent wolframscript process, so it needs a free PROCESS seat
   (NOT a subprocess seat). When 0, that spawn dies during startup without
   writing status/output -> a silent NotReady. Missing["Unknown"] when the
   diagnostics probe is unavailable (never block on an unknown reading). *)
iSVATProcessSeatsFree[] :=
  If[Length[Names["SourceVault`SourceVaultDiagnosticsLicenseProbe"]] == 0,
    Missing["Unknown"],
    Module[{p = Quiet @ Check[
        ToExpression["SourceVault`SourceVaultDiagnosticsLicenseProbe"][], $Failed]},
      If[AssociationQ[p], Lookup[p, "ProcessSlotsFree", Missing["Unknown"]],
        Missing["Unknown"]]]];

(* run a bounded pure computation in a subkernel; prove out-of-process by
   returning the subkernel $ProcessID. Optional Target SleepSeconds (number,
   baked in via outer With) lets a test force a timeout. *)
iSVATExecutePureComputation[job_Association, tcSeconds_] :=
  Module[{sleep, k, res, started, finished, status},
    sleep = Lookup[Lookup[job, "Target", <||>], "SleepSeconds", 0];
    If[!NumberQ[sleep], sleep = 0];
    started = iSVATUTCNow[];
    k = Quiet @ Check[LaunchKernels[1], $Failed];
    If[k === $Failed || k === {},
      Return[<|"Status" -> "Failed", "Reason" -> "SubkernelLaunchFailed",
        "Backend" -> "SubkernelAsync",
        "StartedAtUTC" -> started, "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    res = With[{s = N[sleep]},
      TimeConstrained[
        Quiet @ Check[
          ParallelEvaluate[
            (If[s > 0, Pause[s]];
             <|"Sum" -> Total[Range[1000]], "SubProcessId" -> $ProcessID|>),
            First[k]],
          $Failed],
        tcSeconds, $iSVATTimeoutSentinel]];
    Quiet @ Check[CloseKernels[k], Null];
    finished = iSVATUTCNow[];
    status = Which[
      res === $iSVATTimeoutSentinel, "TimedOut",
      res === $Failed || !AssociationQ[res], "Failed",
      True, "Completed"];
    <|"Status" -> status,
      "Result" -> If[AssociationQ[res], res, Missing["NoResult"]],
      "Backend" -> "SubkernelAsync",
      "StartedAtUTC" -> started, "FinishedAtUTC" -> finished|>];

(* cloud-safe result summary: head / length / byte count only, never the
   content (results may be private; the run log must stay metadata-only). *)
iSVATSummarizeResult[res_] :=
  <|"Head" -> ToString[Head[res]],
    "Length" -> Quiet @ Check[
      If[ListQ[res] || AssociationQ[res], Length[res], Missing["NotList"]],
      Missing[]],
    "ByteCount" -> Quiet @ Check[ByteCount[res], Missing[]]|>;

(* promptrouter is loaded AFTER this file by SourceVault.wl; check at run time *)
iSVATPromptRouterReadyQ[] :=
  Length[Names["SourceVault`SourceVaultGetPromptRoute"]] > 0 &&
  Length[DownValues[iSVPRRouteAutoExecutableQ]] > 0 &&
  Length[DownValues[iSVPRAutoExecutableQ]] > 0;

(* PromptRoute executor: reuse the EXISTING gated-execution safety
   (iSVPRRouteAutoExecutableQ + head allowlist + ReplaySafety), then
   ReleaseHold in the MAIN kernel under a time constraint. The auto-exec
   gate admits only EnvironmentIndependent + ReadOnly/SafeCreate SourceVault
   callables, so this is light and FE-safe; heavier routes are rejected by
   the gate. Record only a metadata result summary (no content). *)
iSVATExecutePromptRoute[job_Association, spec_Association, tcSeconds_] :=
  Module[{routeId, route, exprStr, held, safety, res, started, finished,
          status, dec},
    started = iSVATUTCNow[];
    If[!iSVATPromptRouterReadyQ[],
      Return[<|"Status" -> "Skipped", "Reason" -> "PromptRouterUnavailable",
        "Backend" -> "None", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    routeId = Lookup[Lookup[job, "Target", <||>], "TargetId", Missing[]];
    If[!StringQ[routeId],
      Return[<|"Status" -> "Failed", "Reason" -> "TargetIdMissing",
        "Backend" -> "None", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    (* Fully-qualify promptrouter PUBLIC symbols: this file loads BEFORE
       SourceVault_promptrouter, so an unqualified reference would intern in
       SourceVault`Private` (the wrong symbol) at read time. Quiet (not Check)
       so a benign message is not misread as failure. *)
    route = Quiet[SourceVault`SourceVaultGetPromptRoute[routeId]];
    If[!AssociationQ[route] || Lookup[route, "Status", ""] === "NotFound",
      Return[<|"Status" -> "Failed", "Reason" -> "RouteNotFound",
        "RouteIdUsed" -> routeId,
        "Backend" -> "None", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    (* GATE: EnvironmentIndependent + head allowlist (promptrouter-owned) *)
    If[!TrueQ[iSVPRRouteAutoExecutableQ[route]],
      Return[<|"Status" -> "Blocked", "Reason" -> "NotAutoExecutable",
        "Backend" -> "MainKernelGated", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    (* recover expression (decrypt if encrypted) *)
    exprStr = Lookup[route, "TargetExprString", Missing[]];
    If[!StringQ[exprStr] &&
       AssociationQ[Lookup[route, "EncryptedPayload", Null]] &&
       Length[Names["SourceVault`SourceVaultDecryptPromptRoute"]] > 0,
      dec = Quiet[SourceVault`SourceVaultDecryptPromptRoute[route]];
      If[AssociationQ[dec] && Lookup[dec, "Status", ""] === "Ok",
        exprStr = Lookup[Lookup[dec, "Plaintext", <||>],
          "TargetExprString", Missing[]]]];
    If[!StringQ[exprStr],
      Return[<|"Status" -> "Failed", "Reason" -> "NoExpression",
        "Backend" -> "MainKernelGated", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    safety = Lookup[route, "ReplaySafety", "Unknown"];
    held = Quiet @ Check[ToExpression[exprStr, InputForm, HoldComplete], $Failed];
    If[!MatchQ[held, _HoldComplete],
      Return[<|"Status" -> "Failed", "Reason" -> "ParseFailed",
        "Backend" -> "MainKernelGated", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    (* re-validate heads + safety immediately before eval (cf. RunPrimaryRoute) *)
    If[!(TrueQ[iSVPRAutoExecutableQ[held]] && safety === "EnvironmentIndependent"),
      Return[<|"Status" -> "Blocked", "Reason" -> "HeadOrSafetyRejected",
        "Backend" -> "MainKernelGated", "ReplaySafety" -> safety,
        "StartedAtUTC" -> started, "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    (* privacy: the head allowlist permits only ReadOnly/SafeCreate SourceVault
       callables (no cloud-send heads) and execution is LOCAL (no cloud LLM),
       so local ReleaseHold does not expose data to the cloud. *)
    (* Quiet (not Check): a benign message must not be misread as failure;
       detect genuine failure by the result shape instead. *)
    res = TimeConstrained[Quiet[ReleaseHold[held]],
      tcSeconds, $iSVATTimeoutSentinel];
    finished = iSVATUTCNow[];
    status = Which[res === $iSVATTimeoutSentinel, "TimedOut",
      MatchQ[res, $Failed | $Aborted | _Failure], "Failed",
      True, "Completed"];
    <|"Status" -> status,
      "ResultSummary" -> If[res === $iSVATTimeoutSentinel,
        Missing["TimedOut"], iSVATSummarizeResult[res]],
      "Backend" -> "MainKernelGated", "ReplaySafety" -> safety,
      "PrivacyNote" -> "LocalReadOnlyExecution:NoCloudExposure",
      "StartedAtUTC" -> started, "FinishedAtUTC" -> finished|>];

iSVATExecuteJob[job_Association, spec_Association, tcSeconds_] :=
  Module[{tt = Lookup[Lookup[job, "Target", <||>], "TargetType", ""]},
    Switch[tt,
      "PureComputation", iSVATExecutePureComputation[job, tcSeconds],
      "PromptRoute", iSVATExecutePromptRoute[job, spec, tcSeconds],
      "WorkflowRoute" | "WorkflowTemplate",
        iSVATExecuteWorkflow[job, spec, tcSeconds],
      _, <|"Status" -> "Skipped",
        "Reason" -> "ExecutorNotWired:" <> ToString[tt],
        "Backend" -> "None"|>]];

Options[SourceVaultAutoTriggerDispatchJobs] = {"DryRun" -> False,
  "MaxJobs" -> 1, "TimeConstraintSeconds" -> 30};

SourceVaultAutoTriggerDispatchJobs[opts : OptionsPattern[]] :=
  Module[{dryRun, maxJobs, tc, builtJobs, completed, pending, results = {},
          count = 0, mt},
    If[iSVATAsyncActiveQ[], Return[<|"Status" -> "DeferredAsyncActive"|>]];
    dryRun = TrueQ[OptionValue["DryRun"]];
    maxJobs = OptionValue["MaxJobs"];
    tc = OptionValue["TimeConstraintSeconds"];
    mt = iSVATMachineTag[];
    builtJobs = Select[iSVATReadJobs[], Lookup[#, "Status", ""] === "Built" &];
    completed = iSVATCompletedSlots[];
    pending = Select[builtJobs,
      !MemberQ[completed, Lookup[#, "DispatchSlotKey", Null]] &];
    Scan[
      Function[job,
        Module[{slot, tid, spec, gate, slotsFree, exec, runRec},
          If[count >= maxJobs, Return[Null]];
          slot = Lookup[job, "DispatchSlotKey", Null];
          tid = Lookup[job, "TriggerId", Null];
          spec = If[StringQ[tid], SourceVaultGetAutoTrigger[tid], Missing[]];
          If[!AssociationQ[spec],
            AppendTo[results, <|"Slot" -> slot, "Status" -> "Skipped",
              "Reason" -> "TriggerMissing"|>]; Return[Null]];
          If[!iSVATJobEligibleHereQ[job],
            AppendTo[results, <|"Slot" -> slot, "Status" -> "Skipped",
              "Reason" -> "NotEligibleMachine:SpecificMachine"|>]; Return[Null]];
          gate = SourceVaultAutoTriggerDiagnosticsGate[spec, <||>];
          If[!TrueQ[gate["Allowed"]],
            AppendTo[results, <|"Slot" -> slot, "Status" -> "Skipped",
              "Reason" -> gate["Reason"]|>]; Return[Null]];
          slotsFree = iSVATSubprocessSlotsFree[];
          If[IntegerQ[slotsFree] && slotsFree <= 0,
            AppendTo[results, <|"Slot" -> slot, "Status" -> "Deferred",
              "Reason" -> "LicenseSeatUnavailable"|>]; Return[Null]];
          count++;
          If[dryRun,
            AppendTo[results, <|"Slot" -> slot, "Status" -> "DryRun"|>];
            Return[Null]];
          (* claim (best-effort exactly-once marker) *)
          iSVATAppendRun[<|"Type" -> "AutoTriggerRun", "RunId" -> CreateUUID[],
            "DispatchSlotKey" -> slot, "TriggerId" -> tid, "MachineTag" -> mt,
            "Status" -> "Claimed", "ClaimedAtUTC" -> iSVATUTCNow[]|>];
          exec = iSVATExecuteJob[job, spec, tc];
          runRec = Join[
            <|"Type" -> "AutoTriggerRun", "RunId" -> CreateUUID[],
              "DispatchSlotKey" -> slot, "TriggerId" -> tid, "MachineTag" -> mt|>,
            exec];
          iSVATAppendRun[runRec];
          AppendTo[results, <|"Slot" -> slot, "Status" -> exec["Status"],
            "Run" -> runRec|>]]],
      pending];
    <|"Status" -> "Dispatched", "AtUTC" -> iSVATUTCNow[], "MachineTag" -> mt,
      "Pending" -> Length[pending], "Dispatched" -> count, "Results" -> results,
      "DryRun" -> dryRun|>];

Options[SourceVaultAutoTriggerRunHistory] = {"Status" -> All};

SourceVaultAutoTriggerRunHistory[opts : OptionsPattern[]] :=
  Module[{runs = iSVATReadRuns[], st = OptionValue["Status"]},
    If[st === All || !StringQ[st], runs,
      Select[runs, Lookup[#, "Status", ""] === st &]]];

(* ============================================================
   Non-blocking async dispatch via persistent CLEAN subkernels
   (LaunchKernels). StartProcess of wolframscript/wolfram hangs in
   this environment (fresh kernel loads FE-dependent init); subkernels
   start clean and use the subprocess pool (16), not the process pool.
   Pattern: outer With bakes (resultFile, sleep) into the ParallelSubmit
   expr -> subkernel computes in background and writes the result file
   -> the poll detects the file (FileExistsQ) without blocking and
   harvests the EvaluationObject (instant once done).
   ============================================================ *)

If[!ValueQ[$iSVATRunningJobs], $iSVATRunningJobs = <||>];
If[!ValueQ[$iSVATKernelPoolSize], $iSVATKernelPoolSize = 1];
If[!ValueQ[$iSVATOurKernels], $iSVATOurKernels = {}];

iSVATResultFilePath[slot_] :=
  Module[{root = iSVATRoot[], safe},
    If[root === $Failed, Return[$Failed]];
    safe = StringReplace[ToString[slot],
      Except[LetterCharacter | DigitCharacter] .. -> "-"];
    FileNameJoin[{root, "autotrigger", "results", safe <> ".json"}]];

iSVATEnsureKernelPool[] :=
  Quiet @ Check[
    Module[{need = $iSVATKernelPoolSize - Length[$iSVATOurKernels]},
      If[need > 0,
        $iSVATOurKernels = Join[$iSVATOurKernels, LaunchKernels[need]]];
      $iSVATOurKernels],
    $Failed];

iSVATAsyncEligibleQ[job_] :=
  MemberQ[{"PureComputation"},
    Lookup[Lookup[job, "Target", <||>], "TargetType", ""]];

iSVATSubmitJobAsync[job_Association, tc_] :=
  Module[{slot, sleep, rf, eo},
    slot = Lookup[job, "DispatchSlotKey", "?"];
    sleep = Lookup[Lookup[job, "Target", <||>], "SleepSeconds", 0];
    If[!NumberQ[sleep], sleep = 0];
    rf = iSVATResultFilePath[slot];
    If[rf === $Failed,
      Return[<|"Status" -> "Failed", "Slot" -> slot, "Reason" -> "NoResultPath"|>]];
    iSVATEnsureDir[DirectoryName[rf]];
    If[FileExistsQ[rf], Quiet @ DeleteFile[rf]];
    If[iSVATEnsureKernelPool[] === $Failed,
      Return[<|"Status" -> "Failed", "Slot" -> slot, "Reason" -> "KernelPoolFailed"|>]];
    (* outer With bakes the result path + sleep into the held submission *)
    eo = With[{f = rf, s = N[sleep]},
      ParallelSubmit[
        Module[{res},
          If[s > 0, Pause[s]];
          res = <|"Sum" -> Total[Range[1000]], "SubProcessId" -> $ProcessID|>;
          Export[f,
            Developer`WriteRawJSONString[
              <|"Status" -> "Completed",
                "ResultSummary" -> <|"Head" -> ToString[Head[res]],
                  "Sum" -> res["Sum"]|>,
                "SubProcessId" -> res["SubProcessId"]|>,
              "Compact" -> True],
            "Text"]]]];
    Quiet @ Check[Parallel`Developer`QueueRun[], Null];
    $iSVATRunningJobs[slot] = <|"EO" -> eo, "ResultFile" -> rf,
      "StartedAbs" -> AbsoluteTime[], "TimeConstraint" -> tc,
      "TriggerId" -> Lookup[job, "TriggerId", Missing[]]|>;
    <|"Status" -> "Submitted", "Slot" -> slot|>];

iSVATPollAsyncJobs[] :=
  Module[{finalized = {}},
    Quiet @ Check[Parallel`Developer`QueueRun[], Null];
    KeyValueMap[
      Function[{slot, info},
        Module[{rf = info["ResultFile"], elapsed, r},
          elapsed = AbsoluteTime[] - info["StartedAbs"];
          Which[
            FileExistsQ[rf],
              r = Quiet @ Check[
                Developer`ReadRawJSONString[Import[rf, "Text"]], $Failed];
              iSVATAppendRun[<|"Type" -> "AutoTriggerRun",
                "RunId" -> CreateUUID[], "DispatchSlotKey" -> slot,
                "TriggerId" -> info["TriggerId"], "MachineTag" -> iSVATMachineTag[],
                "Status" -> If[AssociationQ[r], Lookup[r, "Status", "Completed"], "Failed"],
                "ResultSummary" -> If[AssociationQ[r], Lookup[r, "ResultSummary", Missing[]], Missing[]],
                "SubProcessId" -> If[AssociationQ[r], Lookup[r, "SubProcessId", Missing[]], Missing[]],
                "Backend" -> "SubkernelAsync", "FinishedAtUTC" -> iSVATUTCNow[]|>];
              Quiet @ Check[WaitNext[{info["EO"]}], Null];
              Quiet @ Check[DeleteFile[rf], Null];
              AppendTo[finalized, slot],
            IntegerQ[info["TimeConstraint"]] && elapsed > info["TimeConstraint"],
              iSVATAppendRun[<|"Type" -> "AutoTriggerRun", "RunId" -> CreateUUID[],
                "DispatchSlotKey" -> slot, "TriggerId" -> info["TriggerId"],
                "MachineTag" -> iSVATMachineTag[], "Status" -> "TimedOut",
                "Backend" -> "SubkernelAsync", "FinishedAtUTC" -> iSVATUTCNow[],
                "Note" -> "exceeded TimeConstraint; untracked (v1 no forced abort)"|>];
              AppendTo[finalized, slot],
            True, Null]]],
      $iSVATRunningJobs];
    Scan[($iSVATRunningJobs = KeyDrop[$iSVATRunningJobs, #]) &, finalized];
    <|"Finalized" -> finalized, "StillRunning" -> Keys[$iSVATRunningJobs]|>];

Options[SourceVaultAutoTriggerDispatchAsync] = {"MaxConcurrent" -> 1,
  "TimeConstraintSeconds" -> 120};

SourceVaultAutoTriggerDispatchAsync[opts : OptionsPattern[]] :=
  Module[{maxC, tc, completed, builtJobs, eligible, results = {}},
    If[iSVATAsyncActiveQ[], Return[<|"Status" -> "DeferredAsyncActive"|>]];
    maxC = OptionValue["MaxConcurrent"];
    tc = OptionValue["TimeConstraintSeconds"];
    iSVATPollAsyncJobs[];
    completed = iSVATCompletedSlots[];
    builtJobs = Select[iSVATReadJobs[], Lookup[#, "Status", ""] === "Built" &];
    eligible = Select[builtJobs,
      iSVATAsyncEligibleQ[#] && iSVATJobEligibleHereQ[#] &&
        !MemberQ[completed, Lookup[#, "DispatchSlotKey", Null]] &&
        !KeyExistsQ[$iSVATRunningJobs, Lookup[#, "DispatchSlotKey", Null]] &];
    Scan[
      Function[job,
        If[Length[$iSVATRunningJobs] < maxC,
          AppendTo[results, iSVATSubmitJobAsync[job, tc]]]],
      eligible];
    <|"Status" -> "Dispatched", "Submitted" -> Length[results],
      "Results" -> results, "Running" -> Keys[$iSVATRunningJobs]|>];

SourceVaultAutoTriggerPoll[opts : OptionsPattern[]] :=
  Module[{sub = iSVATPollAsyncJobs[], wf = iSVATPollWorkflows[]},
    Quiet @ Check[iSVATPollCatalogRuns[], Null];
    Quiet @ Check[iSVATPollRemoteWatches[], Null];
    <|"Finalized" -> Join[Lookup[sub, "Finalized", {}], Lookup[wf, "Finalized", {}]],
      "StillRunning" -> Join[Lookup[sub, "StillRunning", {}], Lookup[wf, "StillRunning", {}]],
      "Subkernel" -> sub, "Workflow" -> wf,
      "CatalogPending" -> Keys[$iSVATCatalogRunsPending],
      "RemoteWatches" -> Keys[$iSVATRemoteWatches]|>];

SourceVaultAutoTriggerRunningJobs[] :=
  KeyValueMap[
    Function[{slot, info},
      <|"Slot" -> slot, "TriggerId" -> info["TriggerId"],
        "ElapsedSeconds" -> (AbsoluteTime[] - info["StartedAbs"]),
        "TimeConstraint" -> info["TimeConstraint"]|>],
    $iSVATRunningJobs];

(* ============================================================
   Workflow executor: kick off WorkflowRoute / WorkflowTemplate
   targets on ClaudeOrchestrator NON-BLOCKING. ClaudeRunWorkflow
   ["Async"->True] rides the shared polling tick and returns
   immediately with a WorkflowId; completion is detected later by
   polling ClaudeAsyncJobInfo. Workflows run in the MAIN kernel
   (LLM / network / approval are not subkernel-safe), gated on
   LicensePool. FE-required workflows are DEFERRED (no FE ops from
   a tick - trap #30). Orchestrator symbols are referenced by their
   FULL context path (this file loads before the orchestrator).
   ============================================================ *)

If[!ValueQ[$iSVATRunningWorkflows], $iSVATRunningWorkflows = <||>];
If[!ValueQ[SourceVaultAutoTriggerWorkflowResolver],
  SourceVaultAutoTriggerWorkflowResolver = Automatic];

(* resolve an orchestrator workflow symbol by full path, requiring it to be
   actually DEFINED (DownValues) so an interned-but-undefined symbol -> $Failed *)
iSVATOrchestratorSym[base_String] :=
  Module[{full = "ClaudeOrchestrator`Workflow`" <> base},
    If[Length[Names[full]] > 0,
      With[{s = Symbol[full]},   (* DownValues is HoldAll: evaluate Symbol first *)
        If[Length[DownValues[s]] > 0, s, $Failed]],
      $Failed]];

(* orchestrator entry points Throw[$Failed, tag] on bad input (e.g. unknown
   wid); Check catches messages, NOT Throw, so wrap calls to swallow both. *)
SetAttributes[iSVATCatchOrch, HoldFirst];
iSVATCatchOrch[expr_] := Quiet @ Catch[Check[expr, $Failed], _, ($Failed &)];

iSVATOrchestratorReadyQ[] := iSVATOrchestratorSym["ClaudeRunWorkflow"] =!= $Failed;

iSVATWorkflowTargetQ[job_] :=
  MemberQ[{"WorkflowRoute", "WorkflowTemplate"},
    Lookup[Lookup[job, "Target", <||>], "TargetType", ""]];

iSVATWorkflowFERequiredQ[spec_Association] :=
  TrueQ[Lookup[Lookup[spec, "ExecutionPolicy", <||>], "FrontendRequired", False]] ||
  TrueQ[Lookup[Lookup[spec, "Target", <||>], "FrontendRequired", False]];

(* default template resolver: a catalog record may carry an inline executable
   "WorkflowSpec" (Association) or a pre-created "WorkflowId" (String); otherwise
   the template lives in a notebook and cannot be run from a tick without the FE. *)
iSVATDefaultWorkflowResolve[slug_String] :=
  Module[{rec},
    If[Length[Names["SourceVault`SourceVaultWorkflowCatalogRecord"]] == 0,
      Return[$Failed]];
    rec = Quiet @ Check[SourceVault`SourceVaultWorkflowCatalogRecord[slug], $Failed];
    If[!AssociationQ[rec], Return[$Failed]];
    Which[
      StringQ[Lookup[rec, "WorkflowId", Null]], rec["WorkflowId"],
      AssociationQ[Lookup[rec, "WorkflowSpec", Null]], rec["WorkflowSpec"],
      True, $Failed]];

(* spec -> <|"Status"->"Resolved","WorkflowId"->..|>
        | <|"Status"->"Spec","Spec"->..|>
        | <|"Status"->"Unresolved","Reason"->..|>  *)
iSVATResolveWorkflow[spec_Association] :=
  Module[{target = Lookup[spec, "Target", <||>], tt, tid, r, resolver},
    tt = Lookup[target, "TargetType", ""];
    Which[
      StringQ[Lookup[target, "WorkflowId", Null]],
        Return[<|"Status" -> "Resolved", "WorkflowId" -> target["WorkflowId"]|>],
      AssociationQ[Lookup[target, "WorkflowSpec", Null]],
        Return[<|"Status" -> "Spec", "Spec" -> target["WorkflowSpec"]|>]];
    tid = Lookup[target, "TargetId", Missing[]];
    If[!StringQ[tid],
      Return[<|"Status" -> "Unresolved", "Reason" -> "TargetIdMissing"|>]];
    Switch[tt,
      "WorkflowRoute",
        <|"Status" -> "Resolved", "WorkflowId" -> tid|>,  (* TargetId is an existing wid *)
      "WorkflowTemplate",
        resolver = SourceVaultAutoTriggerWorkflowResolver;
        r = If[resolver === Automatic, iSVATDefaultWorkflowResolve[tid],
              Quiet @ Check[resolver[tid], $Failed]];
        Which[
          StringQ[r], <|"Status" -> "Resolved", "WorkflowId" -> r|>,
          AssociationQ[r], <|"Status" -> "Spec", "Spec" -> r|>,
          True, <|"Status" -> "Unresolved",
            "Reason" -> "WorkflowTemplateUnresolved:NoExecutableSpec"|>],
      _, <|"Status" -> "Unresolved", "Reason" -> "NotAWorkflowTarget"|>]];

(* adapter (spec 12.2): kick off an existing wid non-blocking *)
SourceVaultStartWorkflowForAutoTrigger[wid_String, metadata_Association : <||>] :=
  Module[{runFn, res},
    runFn = iSVATOrchestratorSym["ClaudeRunWorkflow"];
    If[runFn === $Failed,
      Return[<|"Status" -> "Skipped", "Reason" -> "OrchestratorUnavailable",
        "Backend" -> "None"|>]];
    res = iSVATCatchOrch[runFn[wid, "Async" -> True]];
    If[!AssociationQ[res],
      Return[<|"Status" -> "Failed", "Reason" -> "RunWorkflowFailed",
        "WorkflowId" -> wid, "Backend" -> "Orchestrator"|>]];
    <|"Status" -> "WorkflowStarted",
      "WorkflowId" -> Lookup[res, "WorkflowId", wid],
      "PollKey" -> Lookup[res, "PollKey", Missing[]],
      "OrchestratorStatus" -> Lookup[res, "Status", Missing[]],
      "Backend" -> "Orchestrator"|>];

(* adapter: instantiate a net from a spec, then kick off *)
SourceVaultStartWorkflowForAutoTrigger[spec_Association, metadata_Association : <||>] :=
  Module[{createFn, wid},
    createFn = iSVATOrchestratorSym["ClaudeCreateWorkflowNet"];
    If[createFn === $Failed,
      Return[<|"Status" -> "Skipped", "Reason" -> "OrchestratorUnavailable",
        "Backend" -> "None"|>]];
    wid = iSVATCatchOrch[createFn[spec]];
    If[!StringQ[wid],
      Return[<|"Status" -> "Failed", "Reason" -> "CreateWorkflowNetFailed",
        "Backend" -> "Orchestrator"|>]];
    SourceVaultStartWorkflowForAutoTrigger[wid, metadata]];

(* executor entry: resolve target, FE-gate, kick off, track. Returns
   immediately (WorkflowStarted); completion is recorded by the poll.
   NOTE: AutoTrigger provenance metadata is recorded on the run record and
   passed to the adapter; binding it into the net's input token/context
   packet (spec 12.2) is best-effort and deferred to a follow-up. *)
iSVATExecuteWorkflow[job_Association, spec_Association, tcSeconds_] :=
  Module[{started = iSVATUTCNow[], resolved, metadata, kick, wid},
    If[!iSVATOrchestratorReadyQ[],
      Return[<|"Status" -> "Skipped", "Reason" -> "OrchestratorUnavailable",
        "Backend" -> "None", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    If[iSVATWorkflowFERequiredQ[spec],
      Return[<|"Status" -> "Deferred", "Reason" -> "FrontendRequired",
        "Backend" -> "None", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    resolved = iSVATResolveWorkflow[spec];
    If[Lookup[resolved, "Status", ""] === "Unresolved",
      Return[<|"Status" -> "Skipped",
        "Reason" -> Lookup[resolved, "Reason", "Unresolved"],
        "Backend" -> "None", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    metadata = <|"RunMode" -> "AutoTrigger",
      "TriggerId" -> Lookup[job, "TriggerId", Missing[]],
      "JobId" -> Lookup[job, "DispatchSlotKey", Missing[]],
      "DispatchSlotKey" -> Lookup[job, "DispatchSlotKey", Missing[]],
      "ExecutionPolicy" -> Lookup[spec, "ExecutionPolicy", <||>],
      "SafetyPolicy" -> Lookup[spec, "SafetyPolicy", <||>]|>;
    kick = Switch[Lookup[resolved, "Status", ""],
      "Resolved",
        SourceVaultStartWorkflowForAutoTrigger[resolved["WorkflowId"], metadata],
      "Spec",
        SourceVaultStartWorkflowForAutoTrigger[resolved["Spec"], metadata],
      _, <|"Status" -> "Skipped", "Reason" -> "Unresolved"|>];
    wid = Lookup[kick, "WorkflowId", Missing[]];
    If[Lookup[kick, "Status", ""] === "WorkflowStarted" && StringQ[wid],
      $iSVATRunningWorkflows[wid] = <|"WorkflowId" -> wid,
        "TriggerId" -> Lookup[job, "TriggerId", Missing[]],
        "DispatchSlotKey" -> Lookup[job, "DispatchSlotKey", Missing[]],
        "StartedAbs" -> AbsoluteTime[], "TimeConstraint" -> tcSeconds|>];
    Join[kick, <|"StartedAtUTC" -> started, "FinishedAtUTC" -> iSVATUTCNow[]|>]];

(* map ClaudeAsyncJobInfo -> our terminal run status (Missing if not terminal) *)
iSVATWorkflowTerminalStatus[info_Association] :=
  Module[{st = Lookup[info, "Status", ""], tr = ToString[Lookup[info, "TerminationReason", ""]]},
    Which[
      st =!= "Completed", Missing["NotTerminal"],
      StringContainsQ[ToLowerCase[tr], "fail" | "error" | "abort"], "WorkflowFailed",
      True, "WorkflowCompleted"]];

If[!ValueQ[$iSVATWorkflowNotFoundGraceSeconds], $iSVATWorkflowNotFoundGraceSeconds = 15];

iSVATPollWorkflows[] :=
  Module[{finalized = {}, infoFn = iSVATOrchestratorSym["ClaudeAsyncJobInfo"], mt = iSVATMachineTag[]},
    If[infoFn === $Failed,
      Return[<|"Finalized" -> {}, "StillRunning" -> Keys[$iSVATRunningWorkflows]|>]];
    KeyValueMap[
      Function[{wid, rec},
        Module[{info, term, elapsed, base},
          elapsed = AbsoluteTime[] - rec["StartedAbs"];
          info = iSVATCatchOrch[infoFn[wid]];
          If[!AssociationQ[info], info = <|"Status" -> "NotFound"|>];
          term = iSVATWorkflowTerminalStatus[info];
          base = <|"Type" -> "AutoTriggerRun", "RunId" -> CreateUUID[],
            "DispatchSlotKey" -> rec["DispatchSlotKey"], "TriggerId" -> rec["TriggerId"],
            "MachineTag" -> mt, "WorkflowId" -> wid, "Backend" -> "Orchestrator",
            "FinishedAtUTC" -> iSVATUTCNow[]|>;
          Which[
            StringQ[term],
              iSVATAppendRun[Join[base, <|"Status" -> term,
                "TerminationReason" -> Lookup[info, "TerminationReason", Missing[]],
                "Steps" -> Lookup[info, "Steps", Missing[]]|>]];
              AppendTo[finalized, wid],
            Lookup[info, "Status", ""] === "NotFound" &&
              elapsed > $iSVATWorkflowNotFoundGraceSeconds,
              (* job entry gone after a grace period: assume done/cleaned *)
              iSVATAppendRun[Join[base, <|"Status" -> "WorkflowCompleted",
                "Note" -> "AsyncJobInfo NotFound after grace (assumed completed/cleaned)"|>]];
              AppendTo[finalized, wid],
            IntegerQ[rec["TimeConstraint"]] && elapsed > rec["TimeConstraint"],
              iSVATAppendRun[Join[base, <|"Status" -> "WorkflowTimedOut",
                "Note" -> "exceeded TimeConstraint; left running in orchestrator (v1 no forced cancel)"|>]];
              AppendTo[finalized, wid],
            True, Null]]],
      $iSVATRunningWorkflows];
    Scan[($iSVATRunningWorkflows = KeyDrop[$iSVATRunningWorkflows, #]) &, finalized];
    <|"Finalized" -> finalized, "StillRunning" -> Keys[$iSVATRunningWorkflows]|>];

Options[SourceVaultAutoTriggerDispatchWorkflows] = {"MaxConcurrent" -> 1,
  "TimeConstraintSeconds" -> 600};

SourceVaultAutoTriggerDispatchWorkflows[opts : OptionsPattern[]] :=
  Module[{maxC, tc, completed, builtJobs, eligible, results = {}, mt = iSVATMachineTag[]},
    If[iSVATAsyncActiveQ[], Return[<|"Status" -> "DeferredAsyncActive"|>]];
    If[!iSVATOrchestratorReadyQ[], Return[<|"Status" -> "OrchestratorUnavailable"|>]];
    maxC = OptionValue["MaxConcurrent"];
    tc = OptionValue["TimeConstraintSeconds"];
    iSVATPollWorkflows[];
    completed = iSVATCompletedSlots[];
    builtJobs = Select[iSVATReadJobs[], Lookup[#, "Status", ""] === "Built" &];
    eligible = Select[builtJobs,
      iSVATWorkflowTargetQ[#] && iSVATJobEligibleHereQ[#] &&
        !MemberQ[completed, Lookup[#, "DispatchSlotKey", Null]] &];
    Scan[
      Function[job,
        Module[{slot, tid, spec, gate, exec},
          If[Length[$iSVATRunningWorkflows] >= maxC, Return[Null]];
          slot = Lookup[job, "DispatchSlotKey", Null];
          tid = Lookup[job, "TriggerId", Null];
          spec = If[StringQ[tid], SourceVaultGetAutoTrigger[tid], Missing[]];
          If[!AssociationQ[spec],
            AppendTo[results, <|"Slot" -> slot, "Status" -> "Skipped",
              "Reason" -> "TriggerMissing"|>]; Return[Null]];
          gate = SourceVaultAutoTriggerDiagnosticsGate[spec, <||>];
          If[!TrueQ[gate["Allowed"]],
            AppendTo[results, <|"Slot" -> slot, "Status" -> "Skipped",
              "Reason" -> gate["Reason"]|>]; Return[Null]];
          (* claim (best-effort exactly-once marker) *)
          iSVATAppendRun[<|"Type" -> "AutoTriggerRun", "RunId" -> CreateUUID[],
            "DispatchSlotKey" -> slot, "TriggerId" -> tid, "MachineTag" -> mt,
            "Status" -> "Claimed", "ClaimedAtUTC" -> iSVATUTCNow[]|>];
          exec = iSVATExecuteWorkflow[job, spec, tc];
          iSVATAppendRun[Join[
            <|"Type" -> "AutoTriggerRun", "RunId" -> CreateUUID[],
              "DispatchSlotKey" -> slot, "TriggerId" -> tid, "MachineTag" -> mt|>,
            exec]];
          AppendTo[results, <|"Slot" -> slot, "Status" -> exec["Status"],
            "WorkflowId" -> Lookup[exec, "WorkflowId", Missing[]],
            "Reason" -> Lookup[exec, "Reason", Missing[]]|>]]],
      eligible];
    <|"Status" -> "Dispatched", "AtUTC" -> iSVATUTCNow[], "MachineTag" -> mt,
      "Submitted" -> Length[results], "Results" -> results,
      "RunningWorkflows" -> Keys[$iSVATRunningWorkflows]|>];

SourceVaultAutoTriggerRunningWorkflows[] :=
  KeyValueMap[
    Function[{wid, rec},
      <|"WorkflowId" -> wid, "TriggerId" -> rec["TriggerId"],
        "DispatchSlotKey" -> rec["DispatchSlotKey"],
        "ElapsedSeconds" -> (AbsoluteTime[] - rec["StartedAbs"]),
        "TimeConstraint" -> rec["TimeConstraint"]|>],
    $iSVATRunningWorkflows];

(* ============================================================
   CatalogWorkflow: run a generated *catalog* workflow (a slug from the
   SourceVault workflow list) on a CHOSEN machine. The panel's own local
   run uses SourceVaultRunWorkflowAsync (external process on THIS PC); to
   run on ANOTHER PC we enqueue a SpecificMachine job here, and the target
   PC's scheduler picks it up via the same placement gate that governs
   auto-triggers and executes SourceVaultRunWorkflowAsync locally there.
   This is a DIFFERENT executor from WorkflowRoute/WorkflowTemplate (which
   go through ClaudeRunWorkflow): catalog slugs run via their generated
   Launch entry, so they must use SourceVaultRunWorkflowAsync, not the
   orchestrator. No orchestrator dependency here. jobs.jsonl is shared, so
   the other dispatchers ignore CatalogWorkflow (they filter by their own
   target types) and only SourceVaultAutoTriggerDispatchCatalogRuns runs it. *)

iSVATCatalogTargetQ[job_] :=
  Lookup[Lookup[job, "Target", <||>], "TargetType", ""] === "CatalogWorkflow";

(* run the slug on THIS machine, non-blocking, via the existing external
   executor. Weak ref: SourceVaultRunWorkflowAsync lives in workflowregistry
   (loaded as part of SourceVault); reference it by full name at run time. *)
iSVATExecuteCatalogWorkflow[job_Association] :=
  Module[{target, slug, form, started, runFn, res, free},
    started = iSVATUTCNow[];
    target = Lookup[job, "Target", <||>];
    slug = Lookup[target, "TargetId", Missing[]];
    form = Lookup[target, "Form", "run"];
    If[!StringQ[slug],
      Return[<|"Status" -> "Failed", "Reason" -> "NoSlug",
        "Backend" -> "None", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    (* seat guard: the external executor needs a free PROCESS seat. If the pool
       is saturated the spawn dies during startup without writing status/output
       (a silent NotReady). Refuse up front with an explicit, actionable status
       instead. Deferred (NOT Failed) so the job stays Built and retries when a
       seat frees; subprocess seats are irrelevant here (wrong pool). *)
    free = iSVATProcessSeatsFree[];
    If[IntegerQ[free] && free <= 0,
      Return[<|"Status" -> "DeferredLicenseSeatUnavailable",
        "Reason" -> "ProcessSeatPoolSaturated",
        "ProcessSlotsFree" -> free, "Slug" -> slug,
        "Detail" -> "External executor needs a free PROCESS seat; pool is 0. " <>
          "Free one (e.g. consolidate duplicate Wolfram MCP kernels via " <>
          "wlmcp-gateway, or close a stale kernel) and it retries automatically.",
        "Backend" -> "None", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    If[Length[Names["SourceVault`SourceVaultRunWorkflowAsync"]] == 0,
      Return[<|"Status" -> "Skipped", "Reason" -> "RunWorkflowAsyncUnavailable",
        "Backend" -> "None", "StartedAtUTC" -> started,
        "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    runFn = Symbol["SourceVault`SourceVaultRunWorkflowAsync"];
    res = Quiet @ Check[runFn[slug, form], $Failed];
    If[!AssociationQ[res] || Lookup[res, "Status", ""] =!= "Submitted",
      Return[<|"Status" -> "Failed", "Reason" -> "SubmitFailed",
        "Detail" -> If[AssociationQ[res], Lookup[res, "Status", ""], ToString[res]],
        "Slug" -> slug, "Backend" -> "ExternalExecutor",
        "StartedAtUTC" -> started, "FinishedAtUTC" -> iSVATUTCNow[]|>]];
    (* track the external job until it finishes, so completion/failure can be
       PUBLISHED to the shared vault (the requester may be another PC that
       cannot read this machine's local ClaudeRuntime job dir) *)
    With[{slot = Lookup[job, "DispatchSlotKey", Missing[]]},
      If[StringQ[slot],
        $iSVATCatalogRunsPending[slot] = <|
          "JobID" -> Lookup[res, "JobID", Missing[]],
          "JobDir" -> Lookup[res, "JobDir", Missing[]],
          "Slug" -> slug, "StartedAbs" -> AbsoluteTime[]|>]];
    <|"Status" -> "CatalogRunSubmitted", "Slug" -> slug, "Form" -> form,
      "JobID" -> Lookup[res, "JobID", Missing[]],
      "JobDir" -> Lookup[res, "JobDir", Missing[]],
      "Backend" -> "ExternalExecutor",
      "StartedAtUTC" -> started, "FinishedAtUTC" -> iSVATUTCNow[]|>];

Options[SourceVaultAutoTriggerDispatchCatalogRuns] = {"MaxRuns" -> 4};

SourceVaultAutoTriggerDispatchCatalogRuns[opts : OptionsPattern[]] :=
  Module[{maxRuns, completed, builtJobs, eligible, results = {}, count = 0,
          mt = iSVATMachineTag[]},
    If[iSVATAsyncActiveQ[], Return[<|"Status" -> "DeferredAsyncActive"|>]];
    maxRuns = OptionValue["MaxRuns"];
    completed = iSVATCompletedSlots[];
    builtJobs = Select[iSVATReadJobs[], Lookup[#, "Status", ""] === "Built" &];
    (* only CatalogWorkflow jobs this machine is allowed to execute *)
    eligible = Select[builtJobs,
      iSVATCatalogTargetQ[#] && iSVATJobEligibleHereQ[#] &&
        !MemberQ[completed, Lookup[#, "DispatchSlotKey", Null]] &];
    Scan[
      Function[job,
        Module[{slot, tid, exec, free},
          If[count >= maxRuns, Return[Null]];
          slot = Lookup[job, "DispatchSlotKey", Null];
          tid = Lookup[job, "TriggerId", Null];
          (* seat guard BEFORE claiming: if the PROCESS pool is saturated the
             external executor would spawn a wolframscript that dies at startup
             (silent NotReady). Defer WITHOUT claiming / recording a run, so the
             job stays Built and retries next tick when a seat frees -- and the
             append-only log is not spammed with a Claimed/Deferred pair every
             tick. Surfaced in the returned Results only. *)
          free = iSVATProcessSeatsFree[];
          If[IntegerQ[free] && free <= 0,
            AppendTo[results, <|"Slot" -> slot,
              "Status" -> "DeferredLicenseSeatUnavailable",
              "ProcessSlotsFree" -> free,
              "Reason" -> "ProcessSeatPoolSaturated(retriesWhenFree)"|>];
            Return[Null]];
          (* claim (best-effort exactly-once marker) *)
          iSVATAppendRun[<|"Type" -> "AutoTriggerRun", "RunId" -> CreateUUID[],
            "DispatchSlotKey" -> slot, "TriggerId" -> tid, "MachineTag" -> mt,
            "Status" -> "Claimed", "ClaimedAtUTC" -> iSVATUTCNow[]|>];
          exec = iSVATExecuteCatalogWorkflow[job];
          count++;
          iSVATAppendRun[Join[
            <|"Type" -> "AutoTriggerRun", "RunId" -> CreateUUID[],
              "DispatchSlotKey" -> slot, "TriggerId" -> tid, "MachineTag" -> mt|>,
            exec]];
          AppendTo[results, <|"Slot" -> slot, "Status" -> exec["Status"],
            "Slug" -> Lookup[exec, "Slug", Missing[]],
            "Reason" -> Lookup[exec, "Reason", Missing[]]|>]]],
      eligible];
    <|"Status" -> "Dispatched", "AtUTC" -> iSVATUTCNow[], "MachineTag" -> mt,
      "Submitted" -> count, "Results" -> results|>];

(* PUBLIC: enqueue a one-shot "run this catalog slug on <machineTag>" job.
   Self-contained (no registered trigger): carries its own placement so any
   machine's DispatchCatalogRuns decides locally whether it may execute.
   When machineTag is THIS machine, EligibleHere is True and this machine's
   scheduler runs it; otherwise the target PC's scheduler picks it up. The
   panel calls this only for the REMOTE case (local runs immediately via
   SourceVaultRunWorkflowAsync). Returns an Enqueued status. *)
Options[SourceVaultEnqueueWorkflowRun] = {"Form" -> "run"};

SourceVaultEnqueueWorkflowRun[slug_String, machineTag_String,
    opts : OptionsPattern[]] :=
  Module[{self = iSVATMachineTag[], form, uid, slot, job},
    form = OptionValue["Form"];
    uid = StringTake[StringReplace[CreateUUID[], "-" -> ""], 8];
    slot = "manual-catalog-" <> slug <> "@" <> iSVATUTCNow[] <> "-" <> uid;
    job = <|
      "Type" -> "AutoTriggerJob",
      "TriggerId" -> "manual-" <> uid,
      "Target" -> <|"TargetType" -> "CatalogWorkflow", "TargetId" -> slug,
        "Form" -> form|>,
      "FireTimes" -> {iSVATUTCNow[]},
      "DispatchSlotKey" -> slot,
      "MachineTag" -> self,
      "PlacementMode" -> "SpecificMachine",
      "RequiredMachineTags" -> {machineTag},
      "EligibleHere" -> (ToLowerCase[machineTag] === ToLowerCase[self]),
      "Priority" -> "Normal",
      "Manual" -> True,
      "Status" -> "Built",
      "BuiltAtUTC" -> iSVATUTCNow[],
      "Dispatched" -> False|>;
    If[iSVATAppendJob[job] === $Failed,
      Return[<|"Status" -> "EnqueueFailed", "Slug" -> slug,
        "MachineTag" -> machineTag|>]];
    <|"Status" -> "Enqueued", "Slug" -> slug, "MachineTag" -> machineTag,
      "DispatchSlotKey" -> slot,
      "EligibleHere" -> job["EligibleHere"],
      "Note" -> "Queued for " <> machineTag <>
        "; that PC's scheduler will run it (start it there with " <>
        "SourceVaultAutoTriggerStartScheduler[] if not already running)."|>];

(* ============================================================
   Remote-run result round trip. The external job's output.wxf lives
   in the EXECUTING machine's local ClaudeRuntime job dir, which the
   requesting PC cannot read. So:
     executor side  iSVATPollCatalogRuns[] tracks the submitted external
                    job; on completion it PUBLISHES the output to the
                    shared vault (autotrigger/results/) and appends a
                    terminal run record (CatalogRunCompleted/Failed) to
                    its per-machine runs log.
     any machine    SourceVaultRemoteWorkflowResult[slot] imports the
                    published result (or reports failure/still-running).
     requester side SourceVaultAutoTriggerWatchRemoteRun registers a
                    watch; the scheduler tick polls the merged runs and,
                    on a terminal record, writes to the ORIGINATING
                    notebook via the NBAccess final-action queue
                    (WriteNotebookCell - the same safe single-committer
                    path the external executor uses; never a raw
                    NotebookWrite from the tick). Completion writes an
                    evaluatable retriever cell; failure writes a report.
   ============================================================ *)

If[!AssociationQ[$iSVATCatalogRunsPending], $iSVATCatalogRunsPending = <||>];
If[!AssociationQ[$iSVATRemoteWatches], $iSVATRemoteWatches = <||>];
$iSVATCatalogRunTTLSeconds = 7200;
$iSVATRemoteWatchTTLSeconds = 7200;

iSVATSharedCatalogResultPath[slot_] :=
  Module[{root = iSVATRoot[], safe},
    If[root === $Failed, Return[$Failed]];
    safe = StringReplace[ToString[slot],
      Except[LetterCharacter | DigitCharacter] .. -> "-"];
    FileNameJoin[{root, "autotrigger", "results", safe <> "-result.wxf"}]];

(* EXECUTOR side: finalize tracked external catalog jobs. Publishes the
   result to the shared vault so the requesting PC can retrieve it. *)
iSVATPollCatalogRuns[] :=
  Module[{finalized = {}, mt = iSVATMachineTag[]},
    If[$iSVATCatalogRunsPending === <||>, Return[Null]];
    KeyValueMap[
      Function[{slot, info},
        Module[{jd = Lookup[info, "JobDir", Missing[]], age, st, statusStr,
                outFile, shared, rec},
          age = AbsoluteTime[] - Lookup[info, "StartedAbs", AbsoluteTime[]];
          outFile = If[StringQ[jd], FileNameJoin[{jd, "output.wxf"}], ""];
          st = If[StringQ[jd],
            Quiet @ Check[
              Import[FileNameJoin[{jd, "status.json"}], "RawJSON"], <||>], <||>];
          statusStr = If[AssociationQ[st], Lookup[st, "Status", ""], ""];
          rec = <|"Type" -> "AutoTriggerRun", "RunId" -> CreateUUID[],
            "DispatchSlotKey" -> slot, "MachineTag" -> mt,
            "Slug" -> Lookup[info, "Slug", Missing[]],
            "JobID" -> Lookup[info, "JobID", Missing[]],
            "Backend" -> "ExternalExecutor",
            "FinishedAtUTC" -> iSVATUTCNow[]|>;
          Which[
            StringQ[jd] && FileExistsQ[outFile],
              shared = iSVATSharedCatalogResultPath[slot];
              If[shared =!= $Failed,
                iSVATEnsureDir[DirectoryName[shared]];
                Quiet @ Check[CopyFile[outFile, shared,
                  OverwriteTarget -> True], Null]];
              iSVATAppendRun[Join[rec, <|"Status" -> "CatalogRunCompleted",
                "ResultPublished" -> (shared =!= $Failed && FileExistsQ[shared]),
                "ResultFile" -> If[shared =!= $Failed,
                  FileNameTake[shared], Missing[]]|>]];
              AppendTo[finalized, slot],
            MemberQ[{"Failed", "Expired"}, statusStr],
              iSVATAppendRun[Join[rec, <|"Status" -> "CatalogRunFailed",
                "Reason" -> statusStr,
                "ErrorRef" -> Lookup[st, "ErrorRef", Missing[]]|>]];
              AppendTo[finalized, slot],
            (* no status.json well past startup -> child died before writing *)
            statusStr === "" && age > 180,
              iSVATAppendRun[Join[rec, <|"Status" -> "CatalogRunFailed",
                "Reason" -> "ChildDiedAtStartup(NoStatusWritten)"|>]];
              AppendTo[finalized, slot],
            age > $iSVATCatalogRunTTLSeconds,
              iSVATAppendRun[Join[rec, <|"Status" -> "CatalogRunFailed",
                "Reason" -> "Timeout(" <>
                  ToString[$iSVATCatalogRunTTLSeconds] <> "s)"|>]];
              AppendTo[finalized, slot],
            True, Null]]],
      $iSVATCatalogRunsPending];
    Scan[($iSVATCatalogRunsPending = KeyDrop[$iSVATCatalogRunsPending, #]) &,
      finalized];
    Null];

(* ANY machine: retrieve a published remote-run result by DispatchSlotKey *)
SourceVaultRemoteWorkflowResult[slot_String] :=
  Module[{shared = iSVATSharedCatalogResultPath[slot], runs, recs, term},
    If[shared =!= $Failed && FileExistsQ[shared],
      Return[Quiet @ Check[Import[shared, "WXF"],
        Failure["ResultUnreadable", <|"Path" -> shared|>]]]];
    runs = iSVATReadRuns[];
    recs = Select[runs, Lookup[#, "DispatchSlotKey", ""] === slot &];
    term = SelectFirst[recs,
      MemberQ[{"CatalogRunCompleted", "CatalogRunFailed"},
        Lookup[#, "Status", ""]] &, Missing[]];
    Which[
      AssociationQ[term] && term["Status"] === "CatalogRunFailed",
        Failure["CatalogRunFailed", <|
          "Reason" -> Lookup[term, "Reason", "?"],
          "MachineTag" -> Lookup[term, "MachineTag", "?"],
          "Slug" -> Lookup[term, "Slug", "?"],
          "FinishedAtUTC" -> Lookup[term, "FinishedAtUTC", "?"]|>],
      AssociationQ[term],   (* completed but result file not synced yet *)
        Missing["ResultSyncing", slot],
      AnyTrue[recs, Lookup[#, "Status", ""] === "CatalogRunSubmitted" &],
        Missing["StillRunning", slot],
      recs =!= {}, Missing["NotFinished", slot],
      True, Missing["NotFound", slot]]];

(* REQUESTER side: watch a remote run and report back into the originating
   notebook when it finishes (or fails / times out). *)
SourceVaultAutoTriggerWatchRemoteRun[slot_String, meta_Association : <||>] := (
  $iSVATRemoteWatches[slot] = <|
    "Notebook" -> Lookup[meta, "Notebook", None],
    "Slug" -> Lookup[meta, "Slug", Missing[]],
    "MachineTag" -> Lookup[meta, "MachineTag", Missing[]],
    "StartedAbs" -> AbsoluteTime[]|>;
  <|"Status" -> "Watching", "DispatchSlotKey" -> slot,
    "Watches" -> Length[$iSVATRemoteWatches]|>);

(* write into the originating notebook via the NBAccess final-action queue
   (single committer; TargetNotebook resolved there, CellPrint fallback).
   Weak: without claudecode, log-only. *)
iSVATNotifyRequester[cellExpr_Cell, nb_, summary_String] :=
  Module[{enq = iSVATClaudeSym["ClaudeEnqueueFinalAction"], fa},
    fa = <|"Action" -> "WriteNotebookCell", "Cell" -> cellExpr,
      "Source" -> "AutoTriggerRemoteRun", "RequiresFinalNode" -> True,
      "Summary" -> summary|>;
    If[MatchQ[nb, _NotebookObject], fa["TargetNotebook"] = nb];
    If[enq === $Failed, Return[<|"Status" -> "NoFinalActionQueue"|>]];
    Quiet @ Check[enq[fa], <|"Status" -> "EnqueueFailed"|>]];

iSVATPollRemoteWatches[] :=
  Module[{finalized = {}, runs},
    If[$iSVATRemoteWatches === <||>, Return[Null]];
    runs = iSVATReadRuns[];
    KeyValueMap[
      Function[{slot, w},
        Module[{recs, term, age, slug, mtag, cell, summary},
          recs = Select[runs, Lookup[#, "DispatchSlotKey", ""] === slot &];
          term = SelectFirst[recs,
            MemberQ[{"CatalogRunCompleted", "CatalogRunFailed"},
              Lookup[#, "Status", ""]] &, Missing[]];
          age = AbsoluteTime[] - Lookup[w, "StartedAbs", AbsoluteTime[]];
          slug = ToString[Lookup[w, "Slug", "?"]];
          mtag = ToString[Lookup[w, "MachineTag", "?"]];
          Which[
            AssociationQ[term] && term["Status"] === "CatalogRunCompleted",
              summary = "remote workflow completed: " <> slug <> " @ " <> mtag;
              cell = Cell[
                "(* " <> slug <> " : " <> mtag <>
                  " \:3067\:306e\:5b9f\:884c\:304c\:5b8c\:4e86\:3057\:307e\:3057\:305f - \:8a55\:4fa1\:3059\:308b\:3068\:7d50\:679c\:3092\:53d6\:308a\:51fa\:305b\:307e\:3059 *)\n" <>
                  "SourceVaultRemoteWorkflowResult[\"" <> slot <> "\"]",
                "Input"];
              iSVATNotifyRequester[cell, w["Notebook"], summary];
              AppendTo[finalized, slot],
            AssociationQ[term],   (* CatalogRunFailed *)
              summary = "remote workflow FAILED: " <> slug <> " @ " <> mtag <>
                " (" <> ToString[Lookup[term, "Reason", "?"]] <> ")";
              cell = Cell[
                "\:26a0 \:30ea\:30e2\:30fc\:30c8\:5b9f\:884c\:5931\:6557: " <> slug <>
                  " @ " <> mtag <>
                  "\n\:7406\:7531: " <> ToString[Lookup[term, "Reason", "?"]] <>
                  "\n\:6642\:523b: " <> ToString[Lookup[term, "FinishedAtUTC", "?"]] <>
                  "\n\:8a73\:7d30: SourceVaultRemoteWorkflowResult[\"" <> slot <> "\"]",
                "Text", FontColor -> RGBColor[0.7, 0.1, 0.1]];
              iSVATNotifyRequester[cell, w["Notebook"], summary];
              AppendTo[finalized, slot],
            age > $iSVATRemoteWatchTTLSeconds,
              summary = "remote workflow timeout (no terminal record): " <> slug;
              cell = Cell[
                "\:26a0 \:30ea\:30e2\:30fc\:30c8\:5b9f\:884c\:306e\:7d42\:4e86\:5831\:544a\:304c " <>
                  ToString[$iSVATRemoteWatchTTLSeconds] <>
                  "s \:4ee5\:5185\:306b\:5c4a\:304d\:307e\:305b\:3093\:3067\:3057\:305f: " <> slug <>
                  " @ " <> mtag <>
                  "\n\:5b9f\:884cPC\:306e\:30b9\:30b1\:30b8\:30e5\:30fc\:30e9\:7a3c\:50cd/\:540c\:671f\:3092\:78ba\:8a8d\:3057\:3066\:304f\:3060\:3055\:3044\:3002" <>
                  "\n\:78ba\:8a8d: SourceVaultRemoteWorkflowResult[\"" <> slot <> "\"]",
                "Text", FontColor -> RGBColor[0.7, 0.1, 0.1]];
              iSVATNotifyRequester[cell, w["Notebook"], summary];
              AppendTo[finalized, slot],
            True, Null]]],
      $iSVATRemoteWatches];
    Scan[($iSVATRemoteWatches = KeyDrop[$iSVATRemoteWatches, #]) &, finalized];
    Null];

(* ============================================================
   Scheduler: rides claudecode's shared polling tick (opt-in,
   default off). Each (throttled) fire is non-blocking:
   Poll finished async jobs -> Tick (build jobs) -> DispatchAsync
   (submit async-eligible to subkernels) -> DispatchWorkflows
   (kick off workflow targets non-blocking). Main-kernel PromptRoute
   jobs are not auto-dispatched here. No own ScheduledTask (rule 95).
   ============================================================ *)

(* resolve a claudecode polling-base symbol by name, weakly; require it to
   be actually DEFINED (DownValues), so an interned-but-undefined symbol
   yields $Failed (and StartScheduler honestly reports ClaudeCodeAbsent). *)
iSVATClaudeSym[base_String] :=
  Module[{nm = Join[Names["ClaudeCode`" <> base], Names[base]]},
    If[nm === {}, $Failed,
      With[{s = Symbol[First[nm]]},
        If[Length[DownValues[s]] > 0, s, $Failed]]]];

$iSVATSchedulerTickKey = "sourcevault-autotrigger-scheduler";
If[!ValueQ[$iSVATLastSchedulerTickAt], $iSVATLastSchedulerTickAt = Missing["Never"]];
If[!ValueQ[$iSVATLastSchedulerResult], $iSVATLastSchedulerResult = <||>];

iSVATSchedulerTickBody[interval_] :=
  Module[{now = AbsoluteTime[], last},
    If[iSVATAsyncActiveQ[], Return[Null]];
    last = $iSVATLastSchedulerTickAt;
    If[NumberQ[last] && (now - last) < interval, Return[Null]];
    $iSVATLastSchedulerTickAt = now;
    Quiet @ Check[SourceVaultAutoTriggerPoll[], Null];
    Quiet @ Check[SourceVaultAutoTriggerTick[], Null];
    Quiet @ Check[SourceVaultAutoTriggerDispatchAsync[], Null];
    (* workflow targets: non-blocking kick-off (only if orchestrator present) *)
    If[iSVATOrchestratorReadyQ[],
      Quiet @ Check[SourceVaultAutoTriggerDispatchWorkflows[], Null]];
    (* catalog-workflow runs enqueued for THIS machine (e.g. a "run on <PC>"
       request from another PC's panel); no orchestrator needed *)
    Quiet @ Check[SourceVaultAutoTriggerDispatchCatalogRuns[], Null];
    (* executor: publish finished catalog runs to the shared vault *)
    Quiet @ Check[iSVATPollCatalogRuns[], Null];
    (* requester: report remote-run completion/failure into the origin notebook *)
    Quiet @ Check[iSVATPollRemoteWatches[], Null];
    $iSVATLastSchedulerResult = <|"AtUTC" -> iSVATUTCNow[],
      "Running" -> Keys[$iSVATRunningJobs],
      "RunningWorkflows" -> Keys[$iSVATRunningWorkflows]|>;
    Null];

Options[SourceVaultAutoTriggerStartScheduler] = {"IntervalSeconds" -> 60};

SourceVaultAutoTriggerStartScheduler[opts : OptionsPattern[]] :=
  Module[{reg = iSVATClaudeSym["ClaudeRegisterPollingTick"],
          interval = OptionValue["IntervalSeconds"]},
    If[reg === $Failed,
      Return[<|"Status" -> "ClaudeCodeAbsent",
        "Note" -> "Shared polling base unavailable; scheduler not registered."|>]];
    (* pre-launch the subkernel pool so the tick never blocks on kernel startup *)
    iSVATEnsureKernelPool[];
    Quiet @ Check[
      reg[$iSVATSchedulerTickKey,
        Function[Null, iSVATSchedulerTickBody[interval]],
        "Phase" -> "SourceVaultAutoTrigger",
        "Caller" -> "SourceVaultAutoTrigger",
        "Priority" -> 2,
        "Suppressible" -> True,
        "RunInline" -> True],
      $Failed];
    <|"Status" -> "Registered", "Key" -> $iSVATSchedulerTickKey,
      "IntervalSeconds" -> interval|>];

SourceVaultAutoTriggerStopScheduler[] :=
  Module[{unreg = iSVATClaudeSym["ClaudeUnregisterPollingTick"]},
    If[unreg === $Failed, Return[<|"Status" -> "ClaudeCodeAbsent"|>]];
    Quiet @ Check[unreg[$iSVATSchedulerTickKey], $Failed];
    (* best-effort: finalize any async jobs / workflows already finished at stop
       time (still-in-flight ones remain tracked for the next Poll / StartScheduler) *)
    Quiet @ Check[SourceVaultAutoTriggerPoll[], Null];
    <|"Status" -> "Unregistered", "Key" -> $iSVATSchedulerTickKey,
      "StillRunning" -> Keys[$iSVATRunningJobs],
      "StillRunningWorkflows" -> Keys[$iSVATRunningWorkflows]|>];

SourceVaultAutoTriggerSchedulerStatus[] :=
  Module[{keysFn = iSVATClaudeSym["ClaudePollingTickKeys"], registered},
    registered = If[keysFn === $Failed, Missing["ClaudeCodeAbsent"],
      MemberQ[Quiet @ Check[keysFn[], {}], $iSVATSchedulerTickKey]];
    <|"Registered" -> registered,
      "Key" -> $iSVATSchedulerTickKey,
      "LastSchedulerTick" -> $iSVATLastSchedulerResult,
      "RunningJobs" -> SourceVaultAutoTriggerRunningJobs[]|>];

(* ============================================================
   Prompt -> TriggerSpec (spec 10). Deterministic-first: a small
   pattern layer covers the common Japanese / English forms with
   NO LLM (auditable, testable headless, privacy-neutral):
     schedule   \:6bce\:9031<\:66dc\:65e5>HH:MM / \:9694\:9031 / \:6bce\:65e5 / \:6bce\:671d / \:6bce\:6708D\:65e5 /
                N\:6642\:9593\:3054\:3068 / N\:5206\:3054\:3068 / ISO datetime / YYYY\:5e74M\:6708D\:65e5 /
                N\:6642\:9593\:5f8c (timer) / weekly / daily / every N hours
     condition  sv:// URIs (+ \:66f4\:65b0 / updated) -> SourceVaultEvent
     placement  "<tag>\:3067\:5b9f\:884c" / "run on <tag>" / any known machine
                tag mentioned -> SpecificMachine + RequiredMachineTags
     runPolicy  priority words, "1\:56de\:3060\:3051" -> MaxRunsPerWindow 1/day
   An optional LLM hook (SourceVaultAutoTriggerPromptLLM or option
   "LLMFunction") fills ONLY the slots the deterministic layer left
   open (currently invoked when the schedule is unparsed). Its
   output is JSON: RawJSON-parsed, key-whitelisted, and validated
   through SourceVaultValidateAutoTrigger - never ToExpression
   (spec 10.2 / this file's WXF rationale). The original prompt is
   stored HashOnly (privacy default). The returned spec always has
   Enabled -> False: parse -> user review -> register -> enable.
   ============================================================ *)

$iSVATAsciiWordChar = Alternatives @@ Join[
  CharacterRange["a", "z"], CharacterRange["A", "Z"],
  CharacterRange["0", "9"], {"-", "_"}];

$iSVATWeekdayJP = <|"\:6708" -> "Monday", "\:706b" -> "Tuesday",
  "\:6c34" -> "Wednesday", "\:6728" -> "Thursday", "\:91d1" -> "Friday",
  "\:571f" -> "Saturday", "\:65e5" -> "Sunday"|>;

$iSVATWeekdayEN = {"Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
  "Saturday", "Sunday"};

(* first explicit time of day: HH:MM / H\:6642M\:5206 / H\:6642\:534a / H\:6642.
   "N\:6642\:9593" (duration) is stripped first so "3\:6642\:9593\:3054\:3068" is not 3:00. *)
iSVATPromptTime[s_String] :=
  Module[{s2, t},
    s2 = StringReplace[s, DigitCharacter .. ~~ "\:6642\:9593" -> ""];
    t = StringCases[s2, h : Repeated[DigitCharacter, {1, 2}] ~~ ":" ~~
        m : Repeated[DigitCharacter, {2}] :> {FromDigits[h], FromDigits[m]}, 1];
    If[t === {},
      t = StringCases[s2, h : Repeated[DigitCharacter, {1, 2}] ~~ "\:6642" ~~
          m : Repeated[DigitCharacter, {1, 2}] ~~ "\:5206" :>
          {FromDigits[h], FromDigits[m]}, 1]];
    If[t === {},
      t = StringCases[s2, h : Repeated[DigitCharacter, {1, 2}] ~~
          "\:6642\:534a" :> {FromDigits[h], 30}, 1]];
    If[t === {},
      t = StringCases[s2, h : Repeated[DigitCharacter, {1, 2}] ~~ "\:6642" :>
          {FromDigits[h], 0}, 1]];
    If[t === {}, Missing["NoTime"], First[t]]];

iSVATPromptWeekday[s_String] :=
  Module[{jp, en},
    jp = StringCases[s,
      (d : (Alternatives @@ Keys[$iSVATWeekdayJP])) ~~ "\:66dc" :> d, 1];
    If[jp =!= {}, Return[$iSVATWeekdayJP[First[jp]]]];
    en = StringCases[s, Alternatives @@ $iSVATWeekdayEN, 1, IgnoreCase -> True];
    If[en =!= {}, Capitalize[ToLowerCase[First[en]]], Missing["NoWeekday"]]];

iSVATPromptISODateTime[s_String] :=
  StringCases[s,
    y : Repeated[DigitCharacter, {4}] ~~ "-" ~~
      mo : Repeated[DigitCharacter, {2}] ~~ "-" ~~
      d : Repeated[DigitCharacter, {2}] ~~ "T" ~~
      h : Repeated[DigitCharacter, {2}] ~~ ":" ~~
      mi : Repeated[DigitCharacter, {2}] :>
      {FromDigits[y], FromDigits[mo], FromDigits[d], FromDigits[h],
       FromDigits[mi]}, 1];

iSVATPromptISODate[s_String] :=
  StringCases[s,
    y : Repeated[DigitCharacter, {4}] ~~ "-" ~~
      mo : Repeated[DigitCharacter, {2}] ~~ "-" ~~
      d : Repeated[DigitCharacter, {2}] :>
      {FromDigits[y], FromDigits[mo], FromDigits[d]}, 1];

iSVATPromptJPDate[s_String] :=
  StringCases[s,
    y : Repeated[DigitCharacter, {4}] ~~ "\:5e74" ~~
      mo : Repeated[DigitCharacter, {1, 2}] ~~ "\:6708" ~~
      d : Repeated[DigitCharacter, {1, 2}] ~~ "\:65e5" :>
      {FromDigits[y], FromDigits[mo], FromDigits[d]}, 1];

(* -> <|"Schedule" -> assoc | Missing, "Questions" -> {...}, "Notes" -> {...}|> *)
iSVATPromptSchedule[s_String, tz_String, nowD_] :=
  Module[{time = iSVATPromptTime[s], questions = {}, notes = {}, everyN, wd,
          fields, interval, isoDT, isoD, jpD, rel, monthly, hour, minute, sched},
    hour = If[ListQ[time], time[[1]], 0];
    minute = If[ListQ[time], time[[2]], 0];
    (* every N hours / minutes *)
    everyN = StringCases[s, n : DigitCharacter .. ~~ "\:6642\:9593" ~~
        ("\:3054\:3068" | "\:304a\:304d") :> FromDigits[n], 1];
    If[everyN =!= {},
      Return[<|"Schedule" -> <|"Kind" -> "CalendarPattern", "TimeZone" -> tz,
          "Fields" -> <|"Hour" -> <|"Every" -> First[everyN]|>, "Minute" -> 0|>|>,
        "Questions" -> {}, "Notes" -> {"EveryNHours"}|>]];
    everyN = StringCases[s, n : DigitCharacter .. ~~ "\:5206" ~~
        ("\:3054\:3068" | "\:304a\:304d") :> FromDigits[n], 1];
    If[everyN =!= {},
      (* Hour -> All is REQUIRED: iSVATResolveFields defaults an absent Hour to
         0, which would restrict "every N minutes" to the midnight hour only.
         "N minutes" means every hour. *)
      Return[<|"Schedule" -> <|"Kind" -> "CalendarPattern", "TimeZone" -> tz,
          "Fields" -> <|"Hour" -> All, "Minute" -> <|"Every" -> First[everyN]|>|>|>,
        "Questions" -> {}, "Notes" -> {"EveryNMinutes"}|>]];
    (* weekly / biweekly *)
    If[StringContainsQ[s, "\:6bce\:9031"] || StringContainsQ[s, "\:9694\:9031"] ||
       StringContainsQ[s, ("2" | "\:4e8c") ~~ "\:9031\:9593\:304a\:304d"] ||
       StringContainsQ[s, "every week", IgnoreCase -> True] ||
       StringContainsQ[s, "weekly", IgnoreCase -> True],
      wd = iSVATPromptWeekday[s];
      If[!StringQ[wd],
        AppendTo[questions,
          "WeekdayMissing: which weekday should the weekly schedule fire on?"]];
      If[!ListQ[time],
        AppendTo[questions,
          "TimeMissing: what time of day should it fire? (assumed 00:00)"]];
      fields = <|"Hour" -> hour, "Minute" -> minute|>;
      If[StringQ[wd], fields = Prepend[fields, "Weekday" -> wd]];
      interval = Missing[];
      If[StringContainsQ[s, "\:9694\:9031"] ||
         StringContainsQ[s, ("2" | "\:4e8c") ~~ "\:9031\:9593\:304a\:304d"],
        isoD = iSVATPromptISODate[s];
        If[isoD === {},
          AppendTo[questions,
            "BiweeklyAnchorMissing: an every-2-weeks schedule needs an anchor date (e.g. 2026-07-04); which week is the first?"];
          interval = <|"Unit" -> "Weeks", "Every" -> 2|>,
          interval = <|"Unit" -> "Weeks", "Every" -> 2,
            "AnchorDate" -> DateObject[First[isoD], TimeZone -> tz]|>]];
      sched = <|"Kind" -> "CalendarPattern", "TimeZone" -> tz,
        "Fields" -> fields|>;
      If[AssociationQ[interval], sched = Append[sched, "Interval" -> interval]];
      Return[<|"Schedule" -> sched, "Questions" -> questions,
        "Notes" -> notes|>]];
    (* monthly: \:6bce\:6708D\:65e5 *)
    monthly = StringCases[s, "\:6bce\:6708" ~~ d : DigitCharacter .. ~~
        "\:65e5" :> FromDigits[d], 1];
    If[monthly =!= {},
      If[!ListQ[time],
        AppendTo[questions,
          "TimeMissing: what time of day should it fire? (assumed 00:00)"]];
      Return[<|"Schedule" -> <|"Kind" -> "CalendarPattern", "TimeZone" -> tz,
          "Fields" -> <|"Day" -> First[monthly], "Hour" -> hour,
            "Minute" -> minute|>|>,
        "Questions" -> questions, "Notes" -> notes|>]];
    (* daily *)
    If[StringContainsQ[s, "\:6bce\:65e5"] || StringContainsQ[s, "\:6bce\:671d"] ||
       StringContainsQ[s, "every day", IgnoreCase -> True] ||
       StringContainsQ[s, "daily", IgnoreCase -> True],
      If[!ListQ[time],
        If[StringContainsQ[s, "\:6bce\:671d"],
          hour = 7; minute = 0;
          AppendTo[questions,
            "TimeAssumed: 'every morning' interpreted as 07:00; confirm the time"],
          AppendTo[questions,
            "TimeMissing: what time of day should it fire? (assumed 00:00)"]]];
      Return[<|"Schedule" -> <|"Kind" -> "CalendarPattern", "TimeZone" -> tz,
          "Fields" -> <|"Hour" -> hour, "Minute" -> minute|>|>,
        "Questions" -> questions, "Notes" -> notes|>]];
    (* absolute alarm: ISO datetime / ISO date / YYYY\:5e74M\:6708D\:65e5 *)
    isoDT = iSVATPromptISODateTime[s];
    If[isoDT =!= {},
      Return[<|"Schedule" -> <|"Kind" -> "Alarm",
          "DateTime" -> DateObject[Join[First[isoDT], {0}], TimeZone -> tz],
          "TimeZone" -> tz|>,
        "Questions" -> {}, "Notes" -> {}|>]];
    jpD = iSVATPromptJPDate[s];
    If[jpD === {}, jpD = iSVATPromptISODate[s]];
    If[jpD =!= {},
      If[!ListQ[time],
        AppendTo[questions,
          "TimeMissing: what time of day should it fire? (assumed 00:00)"]];
      Return[<|"Schedule" -> <|"Kind" -> "Alarm",
          "DateTime" -> DateObject[Join[First[jpD], {hour, minute, 0}],
            TimeZone -> tz],
          "TimeZone" -> tz|>,
        "Questions" -> questions, "Notes" -> {}|>]];
    (* relative timer: N\:6642\:9593\:5f8c / N\:5206\:5f8c / N\:65e5\:5f8c. Timer needs a concrete
       anchor (iSVATScheduleMatchImpl); "when enabled" is not knowable at
       parse time, so anchor = parse time, flagged in Notes. *)
    rel = StringCases[s, n : DigitCharacter .. ~~
        (u : ("\:6642\:9593" | "\:5206" | "\:65e5")) ~~ "\:5f8c" :>
        {FromDigits[n], u}, 1];
    If[rel =!= {},
      Return[<|"Schedule" -> <|"Kind" -> "Timer",
          "After" -> <|"Quantity" -> rel[[1, 1]],
            "Unit" -> Switch[rel[[1, 2]],
              "\:6642\:9593", "Hours", "\:5206", "Minutes", _, "Days"]|>,
          "Anchor" -> nowD|>,
        "Questions" -> {}, "Notes" -> {"TimerAnchorSetToParseTime"}|>]];
    <|"Schedule" -> Missing["Unparsed"],
      "Questions" -> {
        "ScheduleMissing: when should this trigger fire? (e.g. '\:6bce\:9031\:91d1\:66dc 03:00', an ISO datetime, or '3\:6642\:9593\:3054\:3068')"},
      "Notes" -> {}|>];

(* machine placement: known tags mentioned anywhere, or an ASCII word right
   before a placement cue ("\:3067\:5b9f\:884c" | "\:3067\:8d70\:3089" | "\:4e0a\:3067" | "\:306b\:56fa\:5b9a") /
   after "run on". Tokens that are part of an sv:// URI are excluded. *)
iSVATPromptPlacement[s_String, knownTags_List] :=
  Module[{known = Select[knownTags, StringQ], uris, byName, cueJP, cueEN,
          cueTags, found, unknown},
    uris = StringCases[s, "sv://" ~~ ($iSVATAsciiWordChar | "/" | ".") ..];
    byName = Select[known, StringContainsQ[s, #, IgnoreCase -> True] &];
    cueJP = StringCases[s,
      (w : ($iSVATAsciiWordChar ..)) ~~ Repeated[WhitespaceCharacter, {0, 2}] ~~
        ("\:3067\:5b9f\:884c" | "\:3067\:8d70\:3089" | "\:4e0a\:3067" |
         "\:306b\:56fa\:5b9a") :> w];
    cueEN = StringCases[s,
      ("run on " | "execute on " | "only on " | "runs on ") ~~
        (w : ($iSVATAsciiWordChar ..)) :> w, IgnoreCase -> True];
    cueTags = Select[Join[cueJP, cueEN],
      StringLength[#] >= 3 &&
        StringMatchQ[#, ___ ~~ LetterCharacter ~~ ___] &];
    (* a token that is merely the tail of an sv:// URI is not a machine tag *)
    cueTags = Select[cueTags,
      Function[w, !AnyTrue[uris, StringContainsQ[#, w] &]]];
    found = DeleteDuplicatesBy[Join[byName, cueTags], ToLowerCase];
    If[found === {},
      Return[<|"Placement" -> Missing["None"], "Warnings" -> {}|>]];
    unknown = Select[found,
      !MemberQ[ToLowerCase /@ known, ToLowerCase[#]] &];
    <|"Placement" -> <|"Mode" -> "SpecificMachine",
        "RequiredMachineTags" -> found, "Failover" -> False|>,
      "Warnings" -> ("MachineTagNotRegistered:" <> # & /@ unknown)|>];

iSVATPromptCondition[s_String] :=
  Module[{uris, upd, atoms},
    uris = DeleteDuplicates @ StringCases[s,
      u : ("sv://" ~~ ($iSVATAsciiWordChar | "/" | ".") ..) :> u];
    If[uris === {},
      Return[<|"Condition" -> Missing["None"], "Warnings" -> {}|>]];
    upd = StringContainsQ[s, "\:66f4\:65b0"] ||
      StringContainsQ[s, "updat", IgnoreCase -> True];
    atoms = (<|"Atom" -> "SourceVaultEvent", "URI" -> #,
        "EventType" -> "Updated", "Since" -> "LastSuccessfulFire"|> &) /@ uris;
    <|"Condition" -> If[Length[atoms] === 1, First[atoms],
        <|"AnyOf" -> atoms|>],
      "Warnings" -> If[upd, {},
        {"URIFoundWithoutUpdateKeyword:AssumedUpdated"}]|>];

iSVATPromptRunPolicy[s_String] :=
  Module[{p = <||>, prio},
    prio = Which[
      StringContainsQ[s, "critical", IgnoreCase -> True] ||
        StringContainsQ[s, "\:6700\:512a\:5148"], "Critical",
      StringContainsQ[s, "\:9ad8\:512a\:5148"] ||
        StringContainsQ[s, "\:512a\:5148\:5ea6\:9ad8"] ||
        StringContainsQ[s, "\:91cd\:8981"], "High",
      StringContainsQ[s, "\:4f4e\:512a\:5148"], "Low",
      True, Missing[]];
    If[StringQ[prio], p = Append[p, "Priority" -> prio]];
    If[StringContainsQ[s, ("1" | "\:4e00") ~~ "\:56de\:3060\:3051"] ||
       StringContainsQ[s, "only once", IgnoreCase -> True] ||
       StringContainsQ[s, "once per day", IgnoreCase -> True],
      p = Append[p, "MaxRunsPerWindow" -> <|"Count" -> 1, "Window" -> "Day"|>]];
    p];

(* ---- optional LLM fill (spec 10.2 contract) ---- *)

If[!ValueQ[SourceVaultAutoTriggerPromptLLM],
  SourceVaultAutoTriggerPromptLLM = Automatic];

$iSVATPromptLLMInstruction =
  "Convert the user's natural-language auto-trigger request into ONE JSON \
object and return ONLY that JSON (no prose, no code fences). Keys (use null \
when the prompt does not specify): \"schedule\", \"condition\", \"runPolicy\", \
\"executionPlacement\", \"explanation\", \"warnings\", \"questions\". \
\"schedule\" examples: {\"Kind\":\"CalendarPattern\",\"TimeZone\":\"Asia/Tokyo\",\
\"Fields\":{\"Weekday\":\"Friday\",\"Hour\":3,\"Minute\":0}} or \
{\"Kind\":\"Alarm\",\"DateTime\":\"2026-07-01T03:00:00\"}. \"condition\": \
{\"Atom\":\"SourceVaultEvent\",\"URI\":\"sv://...\",\"EventType\":\"Updated\",\
\"Since\":\"LastSuccessfulFire\"} or {\"AnyOf\":[...]} / {\"AllOf\":[...]}. \
\"executionPlacement\": {\"Mode\":\"SpecificMachine\",\
\"RequiredMachineTags\":[\"...\"]} ONLY when a specific machine/PC is named. \
\"runPolicy\": {\"Priority\":\"Normal\",\"MaxRunsPerWindow\":{\"Count\":1,\
\"Window\":\"Day\"}}. \"questions\": clarification questions when ambiguous.";

(* take the outermost {...} span (tolerates prose / code fences around it) *)
iSVATExtractJSONObject[t_String] :=
  Module[{i = StringPosition[t, "{", 1], j = StringPosition[t, "}"]},
    If[i === {} || j === {} || j[[-1, 2]] < i[[1, 1]], t,
      StringTake[t, {i[[1, 1]], j[[-1, 2]]}]]];

(* trap #28 (promptrouter): prefer Developer`ReadRawJSONString, fall back to
   ImportString RawJSON. Data only - never ToExpression. *)
iSVATParseJSONish[t_String] :=
  Module[{txt = iSVATExtractJSONObject[t], p},
    p = Quiet @ Check[Developer`ReadRawJSONString[txt], $Failed];
    If[!AssociationQ[p],
      p = Quiet @ Check[ImportString[txt, "RawJSON"], $Failed]];
    If[AssociationQ[p], p, $Failed]];

iSVATPromptLLMFill[llmFn_, prompt_String, tz_String] :=
  Module[{raw, parsed, out = <||>},
    raw = Quiet @ Check[
      llmFn[$iSVATPromptLLMInstruction <> "\nDefault TimeZone: " <> tz <>
        "\nUser request:\n" <> prompt], $Failed];
    If[!StringQ[raw], Return[<|"Status" -> "LLMFailed"|>]];
    parsed = iSVATParseJSONish[raw];
    If[parsed === $Failed, Return[<|"Status" -> "LLMJSONParseFailed"|>]];
    Scan[
      Function[kv,
        With[{v = Lookup[parsed, First[kv], Null]},
          If[AssociationQ[v] && v =!= <||>, out[Last[kv]] = v]]],
      {"schedule" -> "Schedule", "condition" -> "Condition",
       "runPolicy" -> "RunPolicy",
       "executionPlacement" -> "ExecutionPlacement"}];
    If[StringQ[Lookup[parsed, "explanation", Null]],
      out["Explanation"] = parsed["explanation"]];
    Scan[
      Function[k,
        With[{v = Lookup[parsed, k, Null]},
          If[ListQ[v], out[Capitalize[k]] = Select[v, StringQ]]]],
      {"warnings", "questions"}];
    Append[out, "Status" -> "OK"]];

(* ---- human-readable summaries (ASCII; the UI can localize) ---- *)

iSVATDescribeSchedule[s_Association] :=
  Module[{k = Lookup[s, "Kind", "?"], f, iv},
    Switch[k,
      "CalendarPattern",
        f = Lookup[s, "Fields", <||>];
        iv = Lookup[s, "Interval", Missing[]];
        StringRiffle[{
          "CalendarPattern",
          If[KeyExistsQ[f, "Weekday"],
            "Weekday=" <> ToString[f["Weekday"]], Nothing],
          If[KeyExistsQ[f, "Day"],
            "Day=" <> ToString[f["Day"], InputForm], Nothing],
          "Time=" <> ToString[Lookup[f, "Hour", 0], InputForm] <> ":" <>
            ToString[Lookup[f, "Minute", 0], InputForm],
          If[AssociationQ[iv],
            "Every" <> ToString[Lookup[iv, "Every", 1]] <> "Weeks(anchor=" <>
              ToString[Lookup[iv, "AnchorDate", "?"]] <> ")", Nothing],
          "TZ=" <> ToString[Lookup[s, "TimeZone", "?"]]}, " "],
      "Alarm", "Alarm " <> ToString[Lookup[s, "DateTime", "?"]],
      "Timer", "Timer after " <> ToString[Lookup[s, "After", <||>], InputForm] <>
        " (anchor=" <> ToString[Lookup[s, "Anchor", "?"]] <> ")",
      _, ToString[k]]];

iSVATDescribeCondition[c_Association] :=
  Which[
    KeyExistsQ[c, "Atom"],
      ToString[Lookup[c, "Atom", "?"]] <> " " <>
        ToString[Lookup[c, "URI", Lookup[c, "SourceId", ""]]] <> " " <>
        ToString[Lookup[c, "EventType", ""]],
    KeyExistsQ[c, "AnyOf"],
      "AnyOf[" <> StringRiffle[
        iSVATDescribeCondition /@ Select[Lookup[c, "AnyOf", {}], AssociationQ],
        "; "] <> "]",
    KeyExistsQ[c, "AllOf"],
      "AllOf[" <> StringRiffle[
        iSVATDescribeCondition /@ Select[Lookup[c, "AllOf", {}], AssociationQ],
        "; "] <> "]",
    True, ToString[c, InputForm]];

(* ---- public entry ---- *)

Options[SourceVaultParseAutoTriggerPrompt] = {
  "TimeZone" -> "Asia/Tokyo",
  "KnownMachineTags" -> Automatic,
  "LLMFunction" -> Automatic,
  "Now" -> Automatic};

SourceVaultParseAutoTriggerPrompt[prompt_String,
    target_Association : <||>, opts : OptionsPattern[]] :=
  Module[{tz, known, llmFn, nowD, schedR, sched, questions, warns, notes,
          placeR, place, condR, cond, runPol, llmFill, parsedBy, tid, spec,
          v, status, expl, tt, targId, nextFire},
    tz = OptionValue["TimeZone"];
    If[!StringQ[tz], tz = "Asia/Tokyo"];
    known = OptionValue["KnownMachineTags"];
    If[!ListQ[known], known = iSVATKnownMachineTags[]];
    llmFn = OptionValue["LLMFunction"];
    If[llmFn === Automatic, llmFn = SourceVaultAutoTriggerPromptLLM];
    nowD = With[{n = OptionValue["Now"]},
      If[n === Automatic, TimeZoneConvert[Now, tz],
        With[{d = iSVATToDate[n]},
          If[d === $Failed, TimeZoneConvert[Now, tz], d]]]];
    (* deterministic layer *)
    schedR = iSVATPromptSchedule[prompt, tz, nowD];
    sched = schedR["Schedule"];
    questions = schedR["Questions"];
    notes = schedR["Notes"];
    placeR = iSVATPromptPlacement[prompt, known];
    condR = iSVATPromptCondition[prompt];
    runPol = iSVATPromptRunPolicy[prompt];
    warns = Join[Lookup[placeR, "Warnings", {}], Lookup[condR, "Warnings", {}]];
    place = Lookup[placeR, "Placement", Missing[]];
    cond = Lookup[condR, "Condition", Missing[]];
    parsedBy = <|"Provider" -> "Deterministic", "Model" -> Missing["None"]|>;
    (* optional LLM fill for the slots the deterministic layer left open *)
    If[!AssociationQ[sched] && llmFn =!= Automatic && llmFn =!= None,
      llmFill = iSVATPromptLLMFill[llmFn, prompt, tz];
      If[Lookup[llmFill, "Status", ""] === "OK",
        parsedBy = <|"Provider" -> "LLMHook", "Model" -> Missing["Unknown"]|>;
        If[!AssociationQ[sched] &&
           AssociationQ[Lookup[llmFill, "Schedule", Null]],
          sched = llmFill["Schedule"];
          questions = Select[questions,
            !StringStartsQ[#, "ScheduleMissing"] &]];
        If[!AssociationQ[cond] &&
           AssociationQ[Lookup[llmFill, "Condition", Null]],
          cond = llmFill["Condition"]];
        If[!AssociationQ[place] &&
           AssociationQ[Lookup[llmFill, "ExecutionPlacement", Null]],
          place = llmFill["ExecutionPlacement"]];
        If[runPol === <||> &&
           AssociationQ[Lookup[llmFill, "RunPolicy", Null]],
          runPol = llmFill["RunPolicy"]];
        questions = Join[questions, Lookup[llmFill, "Questions", {}]];
        warns = Join[warns, Lookup[llmFill, "Warnings", {}]],
        AppendTo[warns,
          "LLMFillFailed:" <> ToString[Lookup[llmFill, "Status", "?"]]]]];
    tt = Lookup[target, "TargetType", Missing[]];
    targId = Lookup[target, "TargetId", Missing[]];
    If[!StringQ[tt] || !StringQ[targId],
      AppendTo[questions,
        "TargetMissing: TargetType/TargetId must be supplied by the caller (UI row)"]];
    tid = SourceVaultNewAutoTriggerId[];
    spec = <|
      "Type" -> "AutoTrigger",
      "SchemaVersion" -> "0.1",
      "TriggerId" -> tid,
      "Name" -> Lookup[target, "DisplayName",
        If[StringQ[targId], targId, "auto-trigger"]],
      "Target" -> target,
      "Enabled" -> False,
      "Owner" -> <|"Mode" -> "OwnerMachine", "OwnerMachineTag" -> Automatic|>,
      "Schedule" -> If[AssociationQ[sched], sched, <||>],
      "PromptSource" -> <|
        "OriginalPromptStorage" -> "HashOnly",
        "OriginalPromptHash" -> Quiet @ Check[
          Hash[prompt, "SHA256", "HexString"], Missing["HashFailed"]],
        "ParsedBy" -> parsedBy|>,
      "CreatedBy" -> "User"|>;
    If[AssociationQ[cond], spec = Append[spec, "Condition" -> cond]];
    If[AssociationQ[place], spec = Append[spec, "ExecutionPlacement" -> place]];
    If[AssociationQ[runPol] && runPol =!= <||>,
      spec = Append[spec, "RunPolicy" -> runPol]];
    v = SourceVaultValidateAutoTrigger[spec];
    warns = Join[warns, Lookup[v, "Warnings", {}]];
    nextFire = If[AssociationQ[sched] && sched =!= <||>,
      Quiet @ Check[
        SourceVaultAutoTriggerNextFire[sched, nowD, "HorizonDays" -> 62],
        Missing["PreviewFailed"]],
      Missing["NoSchedule"]];
    expl = StringRiffle[{
      "Target: " <> ToString[tt] <> ":" <> ToString[targId],
      "Schedule: " <> If[AssociationQ[sched] && sched =!= <||>,
        iSVATDescribeSchedule[sched], "UNPARSED"],
      "Condition: " <> If[AssociationQ[cond], iSVATDescribeCondition[cond],
        "none (fires on schedule alone)"],
      "Placement: " <> If[AssociationQ[place],
        ToString[Lookup[place, "Mode", "?"]] <> " " <>
          ToString[Lookup[place, "RequiredMachineTags", {}]],
        "EnvironmentIndependent (default)"],
      If[AssociationQ[runPol] && runPol =!= <||>,
        "RunPolicy: " <> ToString[Normal[runPol], InputForm], Nothing],
      "NextFire: " <> ToString[nextFire],
      "Enabled: False (review, register, then enable)"}, "\n"];
    <|"Status" -> Which[
        !TrueQ[v["Valid"]] || !AssociationQ[sched],
          If[questions =!= {}, "NeedsClarification", "Failed"],
        questions =!= {}, "NeedsClarification",
        True, "OK"],
      "TriggerSpec" -> spec,
      "Explanation" -> expl,
      "Questions" -> questions,
      "Warnings" -> DeleteDuplicates[warns],
      "Notes" -> notes,
      "Validation" -> v,
      "NextFirePreview" -> nextFire|>];

(* ============================================================
   UI layer (spec section 8 / 9): list-display classification,
   per-trigger row data, and a standalone panel with execution
   mode / auto-run capability / auto toggle / priority badge and
   a clickable warning icon that opens the saved (metadata-only,
   rule 90) error summary. Pure reads; no dispatch.
   ============================================================ *)

$iSVATErrorStatuses = {"Failed", "TimedOut", "WorkflowFailed", "WorkflowTimedOut"};

(* spec 9.1 \:5b9f\:884cPC column label *)
iSVATPlacementLabel[spec_Association] :=
  Module[{place = Lookup[spec, "ExecutionPlacement", Missing[]], mode, tags},
    If[!AssociationQ[place],
      Return["\:74b0\:5883\:975e\:4f9d\:5b58"]];
    mode = Lookup[place, "Mode", "EnvironmentIndependent"];
    Switch[mode,
      "SpecificMachine",
        tags = Lookup[place, "RequiredMachineTags", {}];
        If[!ListQ[tags], tags = {}];
        "\:56fa\:5b9a: " <> StringRiffle[Select[tags, StringQ], ","],
      "WorkerPool",
        "pool: " <> ToString[Lookup[place, "WorkerPool", "?"]],
      "EnvironmentIndependent", "\:74b0\:5883\:975e\:4f9d\:5b58",
      _, "\:672a\:5224\:5b9a"]];

SourceVaultAutoTriggerCapability[spec_Association] :=
  Module[{tt = Lookup[Lookup[spec, "Target", <||>], "TargetType", ""],
          feReq = iSVATWorkflowFERequiredQ[spec], cap, mode, autoable},
    {cap, mode, autoable} = Switch[tt,
      "PureComputation",
        {"HeadlessAsync", "\:5225\:30d7\:30ed\:30bb\:30b9\:975e\:30d6\:30ed\:30c3\:30af", True},
      "WorkflowRoute" | "WorkflowTemplate",
        If[feReq, {"FrontendRequired", "FE\:5fc5\:8981", False},
          {"HeadlessAsync",
           "\:5225\:30ab\:30fc\:30cd\:30eb\:975e\:30d6\:30ed\:30c3\:30af(workflow)", True}],
      "CatalogWorkflow",
        {"HeadlessAsync",
         "\:5225\:30d7\:30ed\:30bb\:30b9(\:30ab\:30bf\:30ed\:30b0)", True},
      "PromptRoute",
        {"BlockingSyncUserInitiated",
         "\:4e3b\:30ab\:30fc\:30cd\:30eb(\:624b\:52d5\:8d77\:52d5)", False},
      _, {"Unknown", "\:4e0d\:660e", False}];
    <|"AutoRunCapability" -> cap, "ExecutionMode" -> mode, "AutoEligible" -> autoable|>];

(* last non-claim run record for a trigger (Missing if none) *)
iSVATLastRunForTrigger[tid_] :=
  Module[{runs = Select[iSVATReadRuns[],
    Lookup[#, "TriggerId", ""] === tid && Lookup[#, "Status", ""] =!= "Claimed" &]},
    If[runs === {}, Missing["NoRun"], Last[runs]]];

(* cloud-safe error summary (no raw error text - rule 90) *)
iSVATTriggerErrorInfo[lastRun_] :=
  If[!AssociationQ[lastRun],
    <|"HasError" -> False, "Summary" -> Missing[]|>,
    With[{st = Lookup[lastRun, "Status", ""]},
      If[MemberQ[$iSVATErrorStatuses, st],
        <|"HasError" -> True,
          "Summary" -> <|"Status" -> st,
            "Reason" -> Lookup[lastRun, "Reason",
              Lookup[lastRun, "TerminationReason", Missing[]]],
            "FinishedAtUTC" -> Lookup[lastRun, "FinishedAtUTC", Missing[]],
            "TriggerId" -> Lookup[lastRun, "TriggerId", Missing[]],
            "WorkflowId" -> Lookup[lastRun, "WorkflowId", Missing[]],
            "SummaryURI" -> Lookup[lastRun, "SummaryURI", Missing[]]|>|>,
        <|"HasError" -> False, "Summary" -> Missing[]|>]]];

SourceVaultAutoTriggerListData[] :=
  Map[
    Function[s,
      Module[{tid = Lookup[s, "TriggerId", Missing[]], spec, cap, lastRun, err, nf},
        spec = If[StringQ[tid], SourceVaultGetAutoTrigger[tid], Missing[]];
        If[!AssociationQ[spec], spec = <||>];
        cap = SourceVaultAutoTriggerCapability[spec];
        lastRun = iSVATLastRunForTrigger[tid];
        err = iSVATTriggerErrorInfo[lastRun];
        nf = Quiet @ Check[
          SourceVaultAutoTriggerNextFire[Lookup[spec, "Schedule", <||>], iSVATUTCNow[]],
          Missing[]];
        <|"TriggerId" -> tid, "Name" -> Lookup[spec, "Name", tid],
          "TargetType" -> Lookup[Lookup[spec, "Target", <||>], "TargetType", Missing[]],
          "TargetId" -> Lookup[Lookup[spec, "Target", <||>], "TargetId", Missing[]],
          "Enabled" -> TrueQ[Lookup[spec, "Enabled", False]],
          "ExecutionMode" -> cap["ExecutionMode"],
          "Placement" -> iSVATPlacementLabel[spec],
          "AutoRunCapability" -> cap["AutoRunCapability"],
          "AutoToggle" -> Which[!cap["AutoEligible"], "\:4e0d\:53ef",
            TrueQ[Lookup[spec, "Enabled", False]], "ON", True, "OFF"],
          "Priority" -> Lookup[Lookup[spec, "RunPolicy", <||>], "Priority", "Normal"],
          "NextFire" -> nf,
          "LastRunStatus" -> If[AssociationQ[lastRun],
            Lookup[lastRun, "Status", Missing["NoRun"]], Missing["NoRun"]],
          "HasError" -> err["HasError"], "ErrorSummary" -> err["Summary"]|>]],
    SourceVaultListAutoTriggers[]];

iSVATPriorityBadge[p_] :=
  Style[p, Switch[p, "Critical", Red, "High", Darker[Orange, 0.3],
    "Low", Gray, _, Black], Bold];

iSVATAutoToggleBadge[t_] :=
  Style[t, Switch[t, "ON", Darker[Green], "\:4e0d\:53ef", Gray, _, Black], Bold];

iSVATFmtNextFire[nf_] := Which[StringQ[nf], nf, MissingQ[nf], "-", True, ToString[nf]];

iSVATShowErrorSummary[summary_Association] :=
  Module[{uri = Lookup[summary, "SummaryURI", Missing[]], rows},
    rows = KeyValueMap[{Style[#1, Bold], ToString[#2]} &, KeyDrop[summary, "SummaryURI"]];
    CreateDialog[{
      Style["AutoTrigger \:30a8\:30e9\:30fc\:30b5\:30de\:30ea", Bold, 14],
      Grid[rows, Alignment -> Left, Frame -> All, FrameStyle -> LightGray],
      If[StringQ[uri], Button["\:30b5\:30de\:30ea URI \:3092\:958b\:304f", SystemOpen[uri]], Nothing],
      DefaultButton[]}, WindowTitle -> "AutoTrigger Error Summary"]];

iSVATErrorIcon[row_] :=
  If[TrueQ[row["HasError"]],
    With[{summary = row["ErrorSummary"]},
      Button[
        Tooltip[Style["\:26a0", Red, 14],
          Row[{"error: ", Lookup[summary, "Status", "?"], " @ ",
            Lookup[summary, "FinishedAtUTC", "?"]}]],
        iSVATShowErrorSummary[summary], Appearance -> "Frameless"]],
    ""];

SourceVaultAutoTriggerPanel[] :=
  Module[{data = SourceVaultAutoTriggerListData[], header, rows, band},
    header = Style[#, Bold] & /@
      {"\:540d\:524d", "\:5b9f\:884c\:30e2\:30fc\:30c9", "\:5b9f\:884cPC",
       "\:81ea\:52d5\:53ef\:5426",
       "\:81ea\:52d5", "\:512a\:5148\:5ea6", "\:6b21\:56de", "\:524d\:56de", ""};
    rows = Map[
      Function[r,
        {Lookup[r, "Name", ""], Lookup[r, "ExecutionMode", ""],
         Lookup[r, "Placement", ""],
         Lookup[r, "AutoRunCapability", ""],
         iSVATAutoToggleBadge[Lookup[r, "AutoToggle", ""]],
         iSVATPriorityBadge[Lookup[r, "Priority", "Normal"]],
         iSVATFmtNextFire[Lookup[r, "NextFire", Missing[]]],
         Lookup[r, "LastRunStatus", ""], iSVATErrorIcon[r]}],
      data];
    band = If[Length[Names["SourceVault`SourceVaultDiagnosticsStatusBand"]] > 0,
      Quiet @ Check[SourceVault`SourceVaultDiagnosticsStatusBand[], ""], ""];
    Column[{band,
      Grid[Prepend[rows, header], Alignment -> Left, Frame -> All,
        FrameStyle -> LightGray,
        Background -> {None, {LightBlue, {White}}}]}, Spacings -> 1]];

(* join: the ListData row for the trigger on (targetType, targetId), if any.
   Lets existing lists (workflow catalog / saved prompts) show auto-run status
   per row without re-implementing the classification. *)
(* per-target lookup for list-row badges (workflow / saved-prompt panels).
   IMPORTANT: do NOT go through SourceVaultAutoTriggerListData[], which computes
   SourceVaultAutoTriggerNextFire (a schedule-horizon scan ~3.5s/trigger) for
   EVERY trigger. The list panels call this per row inside a Dynamic, so the
   full ListData cost gets multiplied by row*2 and the Dynamic render exceeds
   the FE evaluation budget -> the panel shows $Aborted. The status badge only
   needs AutoToggle / Priority / error fields, so build the row directly from
   the matching spec and skip NextFire (NextFire -> Missing["NotComputed"]). *)
SourceVaultAutoTriggerForTarget[targetType_String, targetId_String] :=
  Module[{specs, hit, tid, spec, cap, lastRun, err},
    specs = Quiet @ Check[SourceVaultListAutoTriggers[], {}];
    If[! ListQ[specs], specs = {}];
    hit = SelectFirst[specs,
      With[{s = Quiet @ Check[
          SourceVaultGetAutoTrigger[Lookup[#, "TriggerId", ""]], Missing[]]},
        AssociationQ[s] &&
          Lookup[Lookup[s, "Target", <||>], "TargetType", Missing[]] === targetType &&
          Lookup[Lookup[s, "Target", <||>], "TargetId", Missing[]] === targetId] &,
      Missing["NoTrigger"]];
    If[! AssociationQ[hit], Return[Missing["NoTrigger"]]];
    tid = Lookup[hit, "TriggerId", Missing[]];
    spec = If[StringQ[tid], SourceVaultGetAutoTrigger[tid], <||>];
    If[! AssociationQ[spec], spec = <||>];
    cap = SourceVaultAutoTriggerCapability[spec];
    lastRun = iSVATLastRunForTrigger[tid];
    err = iSVATTriggerErrorInfo[lastRun];
    <|"TriggerId" -> tid, "Name" -> Lookup[spec, "Name", tid],
      "TargetType" -> Lookup[Lookup[spec, "Target", <||>], "TargetType", Missing[]],
      "TargetId" -> Lookup[Lookup[spec, "Target", <||>], "TargetId", Missing[]],
      "Enabled" -> TrueQ[Lookup[spec, "Enabled", False]],
      "ExecutionMode" -> cap["ExecutionMode"],
      "Placement" -> iSVATPlacementLabel[spec],
      "AutoRunCapability" -> cap["AutoRunCapability"],
      "AutoToggle" -> Which[! cap["AutoEligible"], "\:4e0d\:53ef",
        TrueQ[Lookup[spec, "Enabled", False]], "ON", True, "OFF"],
      "Priority" -> Lookup[Lookup[spec, "RunPolicy", <||>], "Priority", "Normal"],
      "NextFire" -> Missing["NotComputed"],
      "LastRunStatus" -> If[AssociationQ[lastRun],
        Lookup[lastRun, "Status", Missing["NoRun"]], Missing["NoRun"]],
      "HasError" -> err["HasError"], "ErrorSummary" -> err["Summary"]|>];

(* compact cell to drop into an existing list Grid: auto toggle + priority +
   warning icon, or a gray dash when no trigger is registered for the target. *)
SourceVaultAutoTriggerStatusCell[targetType_String, targetId_String] :=
  Module[{row},
    row = If[targetType === "Workflow",
      (* meta-type: a catalog slug may be a WorkflowTemplate or WorkflowRoute *)
      SelectFirst[
        {SourceVaultAutoTriggerForTarget["WorkflowTemplate", targetId],
         SourceVaultAutoTriggerForTarget["WorkflowRoute", targetId]},
        AssociationQ, Missing["NoTrigger"]],
      SourceVaultAutoTriggerForTarget[targetType, targetId]];
    If[!AssociationQ[row],
      Style["\:2014", Gray],   (* em dash: no auto-trigger *)
      Row[{iSVATAutoToggleBadge[Lookup[row, "AutoToggle", ""]], " ",
        iSVATPriorityBadge[Lookup[row, "Priority", "Normal"]], " ",
        iSVATErrorIcon[row]}]]];

End[];

EndPackage[];
