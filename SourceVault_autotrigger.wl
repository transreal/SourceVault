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

   Deferred to later increments: scheduler tick, condition / schedule
   matching, dispatch, job claim, diagnostics gate, executor adapters,
   UI, prompt-to-spec parsing, update / delete / enable flows.

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
  "SourceVault`SourceVaultAutoTriggerSourcesURIResolver"
]];

$SourceVaultAutoTriggerVersion = "0.1-phase1.1";

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
ExecutionPlacement.Mode enums, Enabled boolean). Returns <|\"Valid\" -> Bool, \
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
dangerous side effects. Options: \"DryRun\" -> False, \"MaxJobs\" -> 1 (cap per \
call), \"TimeConstraintSeconds\" -> 30. Returns a dispatch summary.";

SourceVaultAutoTriggerRunHistory::usage =
  "SourceVaultAutoTriggerRunHistory[opts] returns the run records from \
autotrigger/runs.jsonl. Option \"Status\" -> All filters (e.g. \"Completed\").";

SourceVaultAutoTriggerDispatchAsync::usage =
  "SourceVaultAutoTriggerDispatchAsync[opts] dispatches async-eligible built jobs \
WITHOUT blocking the main kernel: each is submitted to a persistent clean subkernel \
(ParallelSubmit; subprocess pool, NOT the process pool, and NOT a wolframscript \
process whose heavy init hangs headless) which runs it in the background and writes \
a result file. The call returns immediately. Only TargetType \"PureComputation\" is \
async-eligible here; PromptRoute is main-kernel-gated (manual only). Use \
SourceVaultAutoTriggerPoll to finalize. Options: \"MaxConcurrent\" -> 1, \
\"TimeConstraintSeconds\" -> 120.";

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
Options: \"MaxConcurrent\"->1, \"TimeConstraintSeconds\"->600.";

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
trigger for the UI: TriggerId / Name / Enabled / ExecutionMode / AutoRunCapability \
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
   "PureComputation"};
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
    (* ExecutionPlacement (optional) *)
    place = Lookup[spec, "ExecutionPlacement", Missing[]];
    If[AssociationQ[place] &&
       !MemberQ[$iSVATPlacementModes, Lookup[place, "Mode", Null]],
      AppendTo[issues, "ExecutionPlacementModeInvalid"]];
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
          gate, placement, fireTimes, job},
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
    (* 6. Placement (mode recorded; full eligible-machine-set deferred) *)
    placement = Lookup[spec, "ExecutionPlacement",
      <|"Mode" -> "EnvironmentIndependent"|>];
    (* 7. Build job (NOT dispatched) *)
    fireTimes = schedM["FireTimes"];
    job = <|
      "Type" -> "AutoTriggerJob",
      "TriggerId" -> Lookup[spec, "TriggerId", Missing[]],
      "Target" -> Lookup[spec, "Target", <||>],
      "FireTimes" -> fireTimes,
      "DispatchSlotKey" -> iSVATDispatchSlotKey[spec, fireTimes],
      "MachineTag" -> machineTag,
      "PlacementMode" -> Lookup[placement, "Mode", "EnvironmentIndependent"],
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

iSVATJobsLogPath[] :=
  Module[{root = iSVATRoot[]},
    If[root === $Failed, $Failed,
      FileNameJoin[{root, "autotrigger", "jobs.jsonl"}]]];

iSVATReadJobs[] :=
  Module[{p = iSVATJobsLogPath[], lines},
    If[p === $Failed || !FileExistsQ[p], Return[{}]];
    lines = Quiet @ Check[Import[p, {"Text", "Lines"}], {}];
    If[!ListQ[lines], lines = {}];
    Select[(Quiet @ Check[Developer`ReadRawJSONString[#], $Failed] &) /@ lines,
      AssociationQ]];

iSVATAppendJob[job_Association] :=
  Module[{p = iSVATJobsLogPath[], strm},
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

iSVATRunsLogPath[] :=
  Module[{root = iSVATRoot[]},
    If[root === $Failed, $Failed,
      FileNameJoin[{root, "autotrigger", "runs.jsonl"}]]];

iSVATReadRuns[] :=
  Module[{p = iSVATRunsLogPath[], lines},
    If[p === $Failed || !FileExistsQ[p], Return[{}]];
    lines = Quiet @ Check[Import[p, {"Text", "Lines"}], {}];
    If[!ListQ[lines], lines = {}];
    Select[(Quiet @ Check[Developer`ReadRawJSONString[#], $Failed] &) /@ lines,
      AssociationQ]];

iSVATAppendRun[run_Association] :=
  Module[{p = iSVATRunsLogPath[], strm},
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
            "WorkflowTimedOut"},
           Lookup[#, "Status", ""]],
         Lookup[#, "DispatchSlotKey", Null], Null] &) /@ runs, Null]];

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
      iSVATAsyncEligibleQ[#] &&
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
    <|"Finalized" -> Join[Lookup[sub, "Finalized", {}], Lookup[wf, "Finalized", {}]],
      "StillRunning" -> Join[Lookup[sub, "StillRunning", {}], Lookup[wf, "StillRunning", {}]],
      "Subkernel" -> sub, "Workflow" -> wf|>];

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
      iSVATWorkflowTargetQ[#] &&
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
   UI layer (spec section 8 / 9): list-display classification,
   per-trigger row data, and a standalone panel with execution
   mode / auto-run capability / auto toggle / priority badge and
   a clickable warning icon that opens the saved (metadata-only,
   rule 90) error summary. Pure reads; no dispatch.
   ============================================================ *)

$iSVATErrorStatuses = {"Failed", "TimedOut", "WorkflowFailed", "WorkflowTimedOut"};

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
      {"\:540d\:524d", "\:5b9f\:884c\:30e2\:30fc\:30c9", "\:81ea\:52d5\:53ef\:5426",
       "\:81ea\:52d5", "\:512a\:5148\:5ea6", "\:6b21\:56de", "\:524d\:56de", ""};
    rows = Map[
      Function[r,
        {Lookup[r, "Name", ""], Lookup[r, "ExecutionMode", ""],
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
