(* ::Package:: *)

(* SourceVault_routineplan.wl
   Routine EXTENSION -- planning core (preparation estimation, capacity-aware
   front-load placement, LatestSafeStart/Slack for procrastination prevention).
   Extension spec: sourcevault_routine_planview_ext_spec_v0_1.md (RX-2 planning).
   Depends on the core (SourceVault_routine.wl) for identity; pure math otherwise.
   IO-free. Pure ASCII. Day granularity is UTC (TimeZone option, default 0). *)

BeginPackage["SourceVault`"];

SourceVaultRoutinePreparationTasks::usage =
  "SourceVaultRoutinePreparationTasks[event, prepSpec] derives the preparation tasks \
for a meeting/talk (ext spec 2 / P1-9): one PrepTask per PreparationSpec Step, with a \
STABLE identity (prep: HMAC(parent StableId + immutable StepId), so changing Effort/\
ChunkMax never re-identifies it), Due = event Start - MinLeadDays, EarliestStart = \
event Start - WindowDays, Effort, DependsOn (mapped from Step DependsOnStepId), \
Movable->True and ParentRef = the event. event carries EventId/OriginalStart/Start; \
prepSpec has MinLeadDays/WindowDays and Steps {<|\"StepId\",\"Effort\",\
(\"DependsOnStepId\")|>...}. Returns a list of task Associations ready for \
SourceVaultRoutinePlacePlan.";

SourceVaultRoutineLatestSafeStart::usage =
  "SourceVaultRoutineLatestSafeStart[due, effortHours, capacityFn, opts] returns the \
LATEST day one can start and still finish `effortHours` of work by `due`, by \
accumulating daily capacity backwards from the due day until it covers the effort \
(ext spec 3.6). capacityFn[dayStartAbs] -> available hours that day. Returns the day-\
start absolute time, or Missing[\"Infeasible\"] if the horizon (option \"HorizonDays\", \
365) cannot supply the effort. This is the anti-procrastination clock.";

SourceVaultRoutineSlack::usage =
  "SourceVaultRoutineSlack[due, effortHours, capacityFn, now, opts] returns \
LatestSafeStart - now in seconds (negative = already too late; Missing when \
Infeasible). Small/negative slack is the SlackLow / Infeasible nudge trigger \
(ext spec 3.6).";

SourceVaultRoutinePlacePlan::usage =
  "SourceVaultRoutinePlacePlan[tasks, capacityFn, opts] places tasks into daily chunks \
respecting hard constraints and a front-loaded objective (ext spec 3.2, deterministic \
= same input -> same plan). tasks: {<|\"TaskId\", \"DueAtUTC\", \"Effort\" (hours or \
Quantity), (\"DependsOn\"->{ids}), (\"EarliestStart\")|>...}. capacityFn[dayStartAbs] -> \
hours. Algorithm: (1) DAG validation -- a DependsOn cycle is INFEASIBLE (AC-044); \
(2) Kahn topological order picking the earliest-Due ready task (stable tie-break by \
TaskId); (3) each task fills capacity forward from max(EarliestStart, deps' finish+1d, \
plan start) up to its due day, front-loaded; a task whose remaining effort cannot fit \
before its due is reported Infeasible (never silently dropped, AC-023). Option \
\"Pins\"->{<|\"TaskId\",\"DayAbs\",\"Hours\"|>...} pre-places fixed chunks (owner pins / \
FocusReservation / immovable tasks): their capacity is consumed first and those tasks \
are not re-placed. Other options \"TimeZone\" (0), \"PlanStart\" (Automatic=now), \
\"DefaultEffortHours\" (1). Returns <|\"Chunks\"->{<|\"TaskId\",\"DayAbs\",\"Hours\"|>...}, \
\"Infeasible\"->{<|\"TaskId\",\"ShortfallHours\"|>...}, \"Order\"->{ids}, \
\"CycleDetected\"->Bool|>.";

SourceVaultRoutineDefaultCapacityModel::usage =
  "SourceVaultRoutineDefaultCapacityModel[] returns the default CapacityModel (ext spec \
3.1): WeekdayHours (Mon-Fri 4h, weekend 0), FrontLoad 0.7, AllowedWindows All.";

SourceVaultRoutineDayCapacityFn::usage =
  "SourceVaultRoutineDayCapacityFn[capacityModel, opts] builds a capacityFn[dayStartAbs] \
-> effective hours for that day (ext spec 3.1/3.4): WeekdayHours for the day-of-week \
MINUS calendar busy MINUS UNBOUND FocusReservation holds; an Away day is 0. Options \
\"BusyHoursByDay\"/\"ReservationHoursByDay\" (Associations dayKey->hours; dayKey = \
\"YYYY-MM-DD\"), \"AwayDays\" ({dayKeys}), \"TimeZone\" (0). Bound reservation chunks \
are placed as Pins so their hours are NOT double-deducted (AC-045).";

SourceVaultRoutineReplan::usage =
  "SourceVaultRoutineReplan[tasks, capacityFn, opts] regenerates a plan (ext spec 3.5, \
auto-heal). It subtracts recorded progress from each task's effort (undone work rolls \
forward), keeps owner pins fixed, and re-places the rest. If \"InputFresh\"->False (a \
calendar/source is Stale/Partial), it does NOT silently re-plan: it returns the prior \
plan with \"Degraded\"->True and a PlanInputDegraded report (AC-046). Options \
\"PriorPlan\", \"Pins\", \"Progress\" (<|taskId->completedHours|>), \"InputFresh\" \
(True), plus PlacePlan options. Returns <|\"Plan\", \"Report\"-><|\"Moved\",\"Added\", \
\"Dropped\",\"NewInfeasible\"|>, \"Degraded\"->Bool|>.";

SourceVaultRoutineFocusRequest::usage =
  "SourceVaultRoutineFocusRequest[request, tasks, capacityFn, opts] reserves a focus \
slot and pushes MOVABLE work aside to protect it (ext spec 3.7). request = \
<|\"WindowStart\",\"WindowEnd\" (abs), \"Hours\"|>. Immovable tasks (Movable->False) are \
pinned to their prior-plan days; the focus window's capacity is reserved; movable tasks \
are re-placed around it. Movable tasks that no longer fit before their due become \
Conflicts -- the request never silently violates a deadline (AC-023). Options \
\"PriorPlan\", plus PlacePlan options. Returns <|\"Plan\", \"Conflicts\"->{taskIds}, \
\"Feasible\"->Bool, \"Options\"->{\"Defer\"|\"Waive\"|\"Automate\"|\"NegotiateDeadline\"}|>; \
Options is the escalation menu shown when there are Conflicts (never a silent give-up).";

(* === RX-1: visualization suite (ext spec 4). data (headless) + view (FE). === *)

SourceVaultRoutineGanttData::usage =
  "SourceVaultRoutineGanttData[plan, tasks, opts] returns per-task Gantt rows (ext spec \
4.2): {<|\"TaskId\",\"Days\"->{dayAbs...},\"HoursByDay\",\"TotalHours\",\"DueAtUTC\", \
\"FirstDay\",\"LastDay\"|>...} sorted by first scheduled day. Pure/headless (the \
SourceVaultRoutineGanttView renderer needs a Front End).";

SourceVaultRoutineGanttView::usage =
  "SourceVaultRoutineGanttView[plan, tasks, opts] renders a Gantt/timeline Graphics of \
the plan (ext spec 4.2): one row per task with a bar spanning its scheduled days and a \
Due marker. Requires a Front End for display (the Graphics expression itself builds \
headless). Bars carry a Tooltip with the TaskId; click-routing follows the BoardView / \
ActionGate pattern.";

SourceVaultRoutineLoadData::usage =
  "SourceVaultRoutineLoadData[plan, capacityFn, from, to, opts] returns per-day load \
(ext spec 4.4): {<|\"DayAbs\",\"DayKey\",\"Planned\"(hours),\"Capacity\",\"Ratio\", \
\"Over\"->Bool|>...} across [from, to]. This is the calendar that shows whether todos \
pile up on particular days -- the main procrastination gauge. Pure/headless. Options \
\"TimeZone\"(0).";

SourceVaultRoutineLoadView::usage =
  "SourceVaultRoutineLoadView[plan, capacityFn, from, to, opts] renders a load heatmap \
(ext spec 4.4): a calendar grid coloured by planned/capacity ratio (over-loaded days \
stand out), so concentration of work is visible at a glance. Requires a Front End.";

SourceVaultRoutineProcessGraph::usage =
  "SourceVaultRoutineProcessGraph[tasks, opts] builds a dependency Graph of the tasks \
(ext spec 4.3): vertices = TaskIds, directed edges = DependsOn (a general dependency \
DAG is drawn as a Graph, NOT mislabelled a Petri net; a formal Petri view is reserved \
for workflow-semantics scopes via the ClaudeOrchestrator observability adapter). \
Returns a Graph object (usable headless). Option \"VertexLabels\"->\"TaskId\".";

(* --- ScheduleFabric integration: real calendar + $onWork -> plan tasks/capacity --- *)

SourceVaultRoutineFabricTasks::usage =
  "SourceVaultRoutineFabricTasks[from, to, opts] builds the planning task list from REAL \
sources (ScheduleFabric): $onWork notebook deadlines (NBAccess`NBOnWorkTasks -- each \
open task with a Due in [from,to] becomes a task labelled by its Title, Effort from its \
metadata or the default) plus preparation tasks derived for calendar meetings that match \
a PreparationSpec. Weakly bound to NBAccess (returns {} if it is unavailable). Options: \
PrivacySpec (default AccessLevel 1.0 -- a LOCAL FE view needs Title/Summary labels), \
\"OnWorkTasks\"/\"CalendarEvents\" (Automatic -> live NBAccess reads; or inject a list \
for tests), \"PreparationSpecs\" ({<|\"Match\"-><|\"Patterns\",\"MandatoryOnly\"|>, \
\"Prep\"->PreparationSpec|>...}), \"DefaultEffortHours\" (2), \"IncludeDone\" (False). \
Returns a tasks list ready for SourceVaultRoutinePlacePlan / the views.";

SourceVaultRoutineFabricCapacityFn::usage =
  "SourceVaultRoutineFabricCapacityFn[from, to, opts] builds a capacityFn from a \
CapacityModel MINUS the owner's real calendar busy hours per day (NBAccess`\
NBCalendarFreeBusy; free/busy metadata only, works at AccessLevel 0.5). So the plan is \
placed around actual meetings. Weakly bound to NBAccess. Options \"CapacityModel\" \
(default), \"FreeBusy\" (Automatic -> live read; or inject), \"AwayDays\", \"TimeZone\" \
(0). Returns a Function[dayStartAbs -> hours].";

SourceVaultRoutineAgendaData::usage =
  "SourceVaultRoutineAgendaData[from, to, opts] (or [Quantity[n,\"Days\"]]) merges the \
owner's calendar events (NBAccess`NBCalendarEvents) with $onWork notebook deadlines and \
NextReviews (NBAccess`NBOnWorkTasks) into one day-grouped agenda. Returns <|\"From\", \
\"To\", \"Overdue\"->{past-due deadline/review items}, \"Days\"->{<|\"DayAbs\",\"DayKey\", \
\"Weekday\",\"AllDay\"->{deadline/review/all-day-event items},\"Timed\"->{timed events}|>...}|>. \
Each notebook item carries its \"Path\" so a view can open it in one click. Weakly bound to \
NBAccess (empty result if unavailable). Options: PrivacySpec (AccessLevel 1.0), \
\"CalendarEvents\"/\"OnWorkTasks\" (Automatic -> live reads, or inject lists for tests), \
\"ModifiedWithinDays\" (120 -- task scan window), \"IncludeOverdue\" (True), \"TimeZone\" \
(Automatic -> $TimeZone).";

SourceVaultRoutineAgendaView::usage =
  "SourceVaultRoutineAgendaView[from, to, opts] (or [Quantity[n,\"Days\"]]) renders \
SourceVaultRoutineAgendaData as a readable vertical day-by-day timeline: an overdue banner, \
then per day an all-day band (notebook Deadlines in red, NextReviews in blue, all-day \
calendar events in green) followed by timed calendar events. Notebook rows are clickable \
(SystemOpen, so Dropbox online-only files download and open too) to jump straight into the \
work. Needs a Front End. Same options as SourceVaultRoutineAgendaData.";

(* forward declarations: these are DEFINED by SourceVault_mailagenda.wl but
   referenced below. Touching them here, in the package context BEFORE
   Begin[`Private`], pins the references to the PUBLIC SourceVault` symbols
   regardless of load order. Without this, loading routineplan before
   mailagenda (the umbrella order) makes the bare references inside `Private`
   resolve to fresh SourceVault`Private` symbols, and the mail band silently
   stays empty (DownValues of the wrong symbol is 0). *)
SourceVaultMailAgendaItems;
SourceVaultMailAgendaOpen;

Begin["`Private`"];

iSVRPHours[e_?NumberQ] := N[e];
iSVRPHours[q_Quantity] := Quiet@Check[QuantityMagnitude[UnitConvert[q, "Hours"]], 0.];
iSVRPHours[_] := 0.;

iSVRPAbs[t_?NumberQ] := N[t];
iSVRPAbs[t_DateObject] := Quiet@Check[AbsoluteTime[t], $Failed];
iSVRPAbs[t_] := Quiet@Check[AbsoluteTime[t], $Failed];

iSVRPDayStart[abs_, tz_] := Module[{d, y, mo, day},
  d = Quiet@Check[DateObject[FromAbsoluteTime[abs], TimeZone -> tz], $Failed];
  If[!DateObjectQ[d], Return[$Failed]];
  {y, mo, day} = Round /@ DateValue[d, {"Year", "Month", "Day"}];
  AbsoluteTime[DateObject[{y, mo, day, 0, 0, 0}, TimeZone -> tz]]];

$svRPDay = 86400.;

iSVRPDueOf[byId_, tid_] :=
  iSVRPAbs[Lookup[Lookup[byId, tid, <||>], "DueAtUTC", Missing[]]];

(* ---- preparation tasks (ext 2) ---- *)
SourceVaultRoutinePreparationTasks[event_Association, prepSpec_Association] := Module[
  {evStart, parentId, parentTok, minLead, windowDays, steps, due, earliest, stepIdSet,
   prepIdOf},
  evStart = iSVRPAbs[Lookup[event, "Start", Lookup[event, "OriginalStart", Missing[]]]];
  If[!NumberQ[evStart], Return[{}]];
  parentId = "cal:" <> ToString[Lookup[event, "EventId", "unknown"]];
  parentTok = With[{os = iSVRPAbs[Lookup[event, "OriginalStart",
      Lookup[event, "Start", Missing[]]]]},
    If[NumberQ[os], "@" <> IntegerString[Round[os]], "none"]];
  minLead = With[{m = Lookup[prepSpec, "MinLeadDays", 1]}, If[NumberQ[m], m, 1]];
  windowDays = With[{w = Lookup[prepSpec, "WindowDays", 7]}, If[NumberQ[w], w, 7]];
  steps = Lookup[prepSpec, "Steps", {}];
  If[!ListQ[steps] || steps === {}, Return[{}]];
  due = evStart - minLead*$svRPDay;
  earliest = evStart - windowDays*$svRPDay;
  stepIdSet = Lookup[#, "StepId", Missing[]] & /@ steps;
  prepIdOf[sid_] := If[Length[Names["SourceVault`SourceVaultRoutineIdentity"]] > 0,
    Lookup[SourceVault`SourceVaultRoutineIdentity["PrepTask",
      <|"ParentStableId" -> parentId, "StepId" -> sid,
        "ParentOccurrenceToken" -> parentTok|>], "StableId", "prep:" <> ToString[sid]],
    "prep:" <> ToString[sid]];
  With[{evLabel = Lookup[event, "Summary", Lookup[event, "Label", Missing["None"]]]},
  Map[Function[st, Module[{sid = Lookup[st, "StepId", Missing[]], dep, stepLabel, label},
    dep = Lookup[st, "DependsOnStepId", Missing["None"]];
    stepLabel = ToString[Lookup[st, "Label", sid]];
    label = If[StringQ[evLabel], evLabel <> ": " <> stepLabel, stepLabel];
    <|"Kind" -> "PrepTask", "TaskId" -> prepIdOf[sid],
      "StepId" -> sid, "Label" -> label,
      "Identity" -> <|"StableId" -> prepIdOf[sid], "OccurrenceToken" -> parentTok|>,
      "DueAtUTC" -> due, "EarliestStart" -> earliest,
      "Effort" -> Lookup[st, "Effort", Missing["None"]],
      "DependsOn" -> If[MemberQ[stepIdSet, dep], {prepIdOf[dep]}, {}],
      "Movable" -> True,
      "ParentRef" -> <|"StableId" -> parentId, "OccurrenceToken" -> parentTok|>|>]],
    steps]]];
SourceVaultRoutinePreparationTasks[___] := {};

(* ---- LatestSafeStart / Slack (ext 3.6) ---- *)
Options[SourceVaultRoutineLatestSafeStart] = {"TimeZone" -> 0, "HorizonDays" -> 365};
SourceVaultRoutineLatestSafeStart[due_, effortHours_, capacityFn_, OptionsPattern[]] := Module[
  {tz = OptionValue["TimeZone"], dueAbs = iSVRPAbs[due], eff = iSVRPHours[effortHours],
   dueDay, day, cum = 0., guard = 0, horizon = OptionValue["HorizonDays"]},
  If[!NumberQ[dueAbs], Return[Missing["BadDue"]]];
  If[eff <= 0, Return[iSVRPDayStart[dueAbs, tz]]];
  dueDay = iSVRPDayStart[dueAbs, tz];
  If[!NumberQ[dueDay], Return[Missing["BadDue"]]];
  day = dueDay;
  While[guard++ <= horizon,
    cum += Max[0., Quiet@Check[capacityFn[day], 0.]];
    If[cum >= eff - 10^-9, Return[day]];
    day -= $svRPDay];
  Missing["Infeasible"]];

Options[SourceVaultRoutineSlack] = {"TimeZone" -> 0, "HorizonDays" -> 365};
SourceVaultRoutineSlack[due_, effortHours_, capacityFn_, now_, OptionsPattern[]] := Module[
  {lss = SourceVaultRoutineLatestSafeStart[due, effortHours, capacityFn,
     "TimeZone" -> OptionValue["TimeZone"], "HorizonDays" -> OptionValue["HorizonDays"]],
   nowAbs = iSVRPAbs[now]},
  If[!NumberQ[lss] || !NumberQ[nowAbs], Return[Missing["Infeasible"]]];
  lss - nowAbs];

(* ---- placement (ext 3.2) ---- *)
Options[SourceVaultRoutinePlacePlan] = {
  "TimeZone" -> 0, "PlanStart" -> Automatic, "DefaultEffortHours" -> 1, "Pins" -> {}};
SourceVaultRoutinePlacePlan[tasks_List, capacityFn_, OptionsPattern[]] := Module[
  {tz = OptionValue["TimeZone"], planStart, byId, indeg, dependents, ready, used = <||>,
   finishDay = <||>, chunks = {}, infeasible = {}, order = {}, defEff, ids,
   pins = OptionValue["Pins"], pinnedIds},
  planStart = With[{ps = OptionValue["PlanStart"]},
    iSVRPDayStart[If[ps === Automatic, N[AbsoluteTime[]], iSVRPAbs[ps]], tz]];
  If[!NumberQ[planStart], planStart = iSVRPDayStart[N[AbsoluteTime[]], tz]];
  defEff = OptionValue["DefaultEffortHours"];
  ids = Lookup[#, "TaskId", Missing[]] & /@ tasks;
  byId = Association[(Lookup[#, "TaskId", Missing[]] -> #) & /@ tasks];
  (* dependency graph restricted to present task ids *)
  indeg = Association[Map[Function[t,
    Lookup[t, "TaskId", Missing[]] ->
      Length[Select[Lookup[t, "DependsOn", {}], MemberQ[ids, #] &]]], tasks]];
  dependents = Association[(# -> {}) & /@ ids];
  Do[Module[{tid = Lookup[t, "TaskId", Missing[]]},
    Do[If[MemberQ[ids, dep], dependents[dep] = Append[dependents[dep], tid]],
      {dep, Lookup[t, "DependsOn", {}]}]], {t, tasks}];
  (* pre-place pins (owner pins / FocusReservation / immovable): fixed chunks whose
     capacity is consumed and whose tasks are not re-placed (ext 3.2/3.4). *)
  If[!ListQ[pins], pins = {}];
  Do[Module[{ptid = Lookup[pin, "TaskId", Missing[]],
      pday = iSVRPDayStart[iSVRPAbs[Lookup[pin, "DayAbs", Missing[]]], tz],
      ph = iSVRPHours[Lookup[pin, "Hours", 0]]},
    If[StringQ[ptid] && NumberQ[pday],
      AppendTo[chunks, <|"TaskId" -> ptid, "DayAbs" -> pday, "Hours" -> ph|>];
      used[Round[pday]] = Lookup[used, Round[pday], 0.] + ph;
      finishDay[ptid] = Max[Lookup[finishDay, ptid, pday], pday]]],
    {pin, pins}];
  pinnedIds = DeleteDuplicates@Select[Lookup[#, "TaskId", Missing[]] & /@ pins, StringQ];
  (* mark pinned tasks placed and release their dependents *)
  Do[If[MemberQ[ids, pid],
    AppendTo[order, pid];
    Do[If[KeyExistsQ[indeg, d], indeg[d] = indeg[d] - 1], {d, dependents[pid]}]],
    {pid, pinnedIds}];
  ready = Select[ids, !MemberQ[pinnedIds, #] && indeg[#] == 0 &];
  While[ready =!= {},
    Module[{t, tid, task, eff, earliest, dueDay, day, remaining, last},
      t = First[SortBy[ready,
        {With[{d = iSVRPDueOf[byId, #]}, If[NumberQ[d], d, Infinity]] &, # &}]];
      tid = t; ready = DeleteCases[ready, tid]; AppendTo[order, tid];
      task = byId[tid];
      eff = With[{e = Lookup[task, "Effort", Missing["None"]]},
        If[MissingQ[e], defEff, iSVRPHours[e]]];
      earliest = Max[Join[
        {planStart},
        With[{es = iSVRPAbs[Lookup[task, "EarliestStart", Missing[]]]},
          If[NumberQ[es], {iSVRPDayStart[es, tz]}, {}]],
        DeleteMissing[Map[
          Function[dep, With[{fd = Lookup[finishDay, dep, Missing[]]},
            If[NumberQ[fd], fd + $svRPDay, Missing[]]]],
          Select[Lookup[task, "DependsOn", {}],
            MemberQ[ids, #] || MemberQ[pinnedIds, #] &]]]]];
      dueDay = With[{d = iSVRPDueOf[byId, tid]},
        If[NumberQ[d], iSVRPDayStart[d, tz], earliest]];
      remaining = eff; day = earliest; last = earliest;
      While[remaining > 10^-9 && day <= dueDay + 0.5,
        Module[{avail = Max[0.,
            Quiet@Check[capacityFn[day], 0.] - Lookup[used, Round[day], 0.]], put},
          If[avail > 0,
            put = Min[remaining, avail];
            AppendTo[chunks, <|"TaskId" -> tid, "DayAbs" -> day, "Hours" -> put|>];
            used[Round[day]] = Lookup[used, Round[day], 0.] + put;
            remaining -= put; last = day]];
        day += $svRPDay];
      finishDay[tid] = last;
      If[remaining > 10^-6,
        AppendTo[infeasible, <|"TaskId" -> tid, "ShortfallHours" -> remaining|>]];
      Do[indeg[d] = indeg[d] - 1;
        If[indeg[d] == 0 && !MemberQ[pinnedIds, d], AppendTo[ready, d]],
        {d, dependents[tid]}]]];
  If[Length[order] < Length[ids],
    Return[<|"Chunks" -> chunks, "Infeasible" ->
        Append[infeasible, <|"Reason" -> "DependencyCycle",
          "TaskIds" -> Complement[ids, order]|>],
      "Order" -> order, "CycleDetected" -> True|>]];
  <|"Chunks" -> chunks, "Infeasible" -> infeasible, "Order" -> order,
    "CycleDetected" -> False|>];
SourceVaultRoutinePlacePlan[___] :=
  <|"Chunks" -> {}, "Infeasible" -> {}, "Order" -> {}, "CycleDetected" -> False|>;

(* ---- CapacityModel (ext 3.1/3.4) ---- *)
SourceVaultRoutineDefaultCapacityModel[] := <|
  "WeekdayHours" -> <|"Monday" -> 4, "Tuesday" -> 4, "Wednesday" -> 4, "Thursday" -> 4,
    "Friday" -> 4, "Saturday" -> 0, "Sunday" -> 0|>,
  "FrontLoad" -> 0.7, "AllowedWindows" -> All|>;

iSVRPDayKey[dayAbs_, tz_] := Module[{d, y, mo, day},
  d = Quiet@Check[DateObject[FromAbsoluteTime[dayAbs], TimeZone -> tz], $Failed];
  If[!DateObjectQ[d], Return[Missing["Bad"]]];
  {y, mo, day} = Round /@ DateValue[d, {"Year", "Month", "Day"}];
  StringJoin[ToString[y], "-", IntegerString[mo, 10, 2], "-", IntegerString[day, 10, 2]]];

Options[SourceVaultRoutineDayCapacityFn] = {
  "BusyHoursByDay" -> <||>, "ReservationHoursByDay" -> <||>, "AwayDays" -> {},
  "TimeZone" -> 0};
SourceVaultRoutineDayCapacityFn[capModel_Association, OptionsPattern[]] := Module[
  {wh = Lookup[capModel, "WeekdayHours", <||>], busy = OptionValue["BusyHoursByDay"],
   res = OptionValue["ReservationHoursByDay"], away = OptionValue["AwayDays"],
   tz = OptionValue["TimeZone"]},
  Function[dayAbs, With[{dk = iSVRPDayKey[dayAbs, tz]},
    Which[
      !StringQ[dk], 0.,
      MemberQ[away, dk], 0.,
      True, With[{dow = ToString[DayName[
          DateObject[FromAbsoluteTime[dayAbs], TimeZone -> tz]]]},
        Max[0., N@Lookup[wh, dow, 0] - N@Lookup[busy, dk, 0] - N@Lookup[res, dk, 0]]]]]]];

(* ---- plan diff (ext 3.5 report) ---- *)
iSVRPTaskDays[plan_] := Module[{chunks = Lookup[plan, "Chunks", {}]},
  GroupBy[chunks, Lookup[#, "TaskId", ""] &,
    Sort[Round[Lookup[#, "DayAbs", 0]] & /@ #] &]];
iSVRPPlanDiff[prior_, new_] := Module[{pd = iSVRPTaskDays[prior], nd = iSVRPTaskDays[new],
   priorInf, newInf},
  priorInf = Lookup[#, "TaskId", Missing[]] & /@ Lookup[prior, "Infeasible", {}];
  newInf = Lookup[#, "TaskId", Missing[]] & /@ Lookup[new, "Infeasible", {}];
  <|"Moved" -> Select[Keys[nd], KeyExistsQ[pd, #] && pd[#] =!= nd[#] &],
    "Added" -> Complement[Keys[nd], Keys[pd]],
    "Dropped" -> Complement[Keys[pd], Keys[nd]],
    "NewInfeasible" -> Complement[Select[newInf, StringQ], Select[priorInf, StringQ]]|>];

(* ---- daily replan / auto-heal (ext 3.5) ---- *)
Options[SourceVaultRoutineReplan] = {
  "TimeZone" -> 0, "PlanStart" -> Automatic, "DefaultEffortHours" -> 1,
  "PriorPlan" -> Missing["None"], "Pins" -> {}, "Progress" -> <||>, "InputFresh" -> True};
SourceVaultRoutineReplan[tasks_List, capacityFn_, OptionsPattern[]] := Module[
  {prior = OptionValue["PriorPlan"], progress = OptionValue["Progress"], adjTasks, newPlan},
  If[!TrueQ[OptionValue["InputFresh"]],
    Return[<|"Plan" -> If[AssociationQ[prior], prior,
        <|"Chunks" -> {}, "Infeasible" -> {}, "Order" -> {}, "CycleDetected" -> False|>],
      "Report" -> <|"Reason" -> "PlanInputDegraded"|>, "Degraded" -> True|>]];
  (* subtract recorded progress from each task's remaining effort *)
  adjTasks = Map[Function[t, Module[{tid = Lookup[t, "TaskId", ""],
      eff = With[{e = Lookup[t, "Effort", Missing["None"]]},
        If[MissingQ[e], OptionValue["DefaultEffortHours"], iSVRPHours[e]]], done},
    done = N@Lookup[progress, tid, 0];
    Append[t, "Effort" -> Max[0., eff - done]]]], tasks];
  newPlan = SourceVaultRoutinePlacePlan[adjTasks, capacityFn,
    "TimeZone" -> OptionValue["TimeZone"], "PlanStart" -> OptionValue["PlanStart"],
    "DefaultEffortHours" -> OptionValue["DefaultEffortHours"], "Pins" -> OptionValue["Pins"]];
  <|"Plan" -> newPlan, "Degraded" -> False,
    "Report" -> If[AssociationQ[prior], iSVRPPlanDiff[prior, newPlan],
      <|"Moved" -> {}, "Added" -> Keys[iSVRPTaskDays[newPlan]], "Dropped" -> {},
        "NewInfeasible" -> (Lookup[#, "TaskId", Missing[]] & /@ newPlan["Infeasible"])|>]|>];
SourceVaultRoutineReplan[___] :=
  <|"Plan" -> <|"Chunks" -> {}|>, "Report" -> <||>, "Degraded" -> False|>;

(* ---- FocusRequest: protect a focus slot by pushing movable work (ext 3.7) ---- *)
Options[SourceVaultRoutineFocusRequest] = {
  "TimeZone" -> 0, "PlanStart" -> Automatic, "DefaultEffortHours" -> 1,
  "PriorPlan" -> Missing["None"]};
SourceVaultRoutineFocusRequest[request_Association, tasks_List, capacityFn_,
    OptionsPattern[]] := Module[
  {tz = OptionValue["TimeZone"], ws = iSVRPAbs[Lookup[request, "WindowStart", Missing[]]],
   we = iSVRPAbs[Lookup[request, "WindowEnd", Missing[]]],
   hrs = iSVRPHours[Lookup[request, "Hours", 0]], prior = OptionValue["PriorPlan"],
   immovable, movable, pins, priorDays, focusCap, plan, conflicts},
  If[!NumberQ[ws] || !NumberQ[we],
    Return[<|"Plan" -> <|"Chunks" -> {}|>, "Conflicts" -> {}, "Feasible" -> False,
      "Options" -> {}, "Reason" -> "BadWindow"|>]];
  (* immovable tasks pinned to their prior-plan days; movable ones re-placed *)
  priorDays = If[AssociationQ[prior], iSVRPTaskDays[prior], <||>];
  immovable = Select[tasks, !TrueQ[Lookup[#, "Movable", True]] &];
  movable = Select[tasks, TrueQ[Lookup[#, "Movable", True]] &];
  pins = Flatten[Map[Function[t, Module[{tid = Lookup[t, "TaskId", ""],
      days = Lookup[priorDays, Lookup[t, "TaskId", ""], {}]},
    If[days === {}, {},
      (* spread prior effort evenly across its prior days as pins *)
      With[{ph = iSVRPHours[Lookup[t, "Effort", 0]]/Max[1, Length[days]]},
        Map[<|"TaskId" -> tid, "DayAbs" -> #, "Hours" -> ph|> &, days]]]]], immovable]];
  (* reserve the focus window: zero the effective capacity inside it for other work *)
  focusCap = Function[dayAbs, If[ws - 0.5 <= dayAbs < we, 0., capacityFn[dayAbs]]];
  plan = SourceVaultRoutinePlacePlan[movable, focusCap,
    "TimeZone" -> tz, "PlanStart" -> OptionValue["PlanStart"],
    "DefaultEffortHours" -> OptionValue["DefaultEffortHours"], "Pins" -> pins];
  conflicts = Select[Lookup[#, "TaskId", Missing[]] & /@ Lookup[plan, "Infeasible", {}],
    StringQ];
  <|"Plan" -> plan, "Conflicts" -> conflicts, "Feasible" -> (conflicts === {}),
    "Options" -> If[conflicts === {}, {},
      {"Defer", "Waive", "Automate", "NegotiateDeadline"}]|>];
SourceVaultRoutineFocusRequest[___] :=
  <|"Plan" -> <|"Chunks" -> {}|>, "Conflicts" -> {}, "Feasible" -> False, "Options" -> {}|>;

(* ============================================================
   RX-1: visualization suite (ext spec 4). Each visual = a pure DATA function
   (headless-tested) + a VIEW renderer (Graphics/Graph; display needs a Front End).
   ============================================================ *)

(* human display label (StepId / Label) while TaskId stays the identity *)
iSVRPLabel[task_] := With[{l = Lookup[task, "Label",
    Lookup[task, "StepId", Lookup[task, "TaskId", "?"]]]},
  If[StringQ[l] || l =!= Missing["KeyAbsent"], ToString[l], "?"]];

SourceVaultRoutineGanttData[plan_Association, tasks_List, opts : OptionsPattern[]] := Module[
  {chunks = Lookup[plan, "Chunks", {}], byTask, byId, rows},
  byId = Association[(Lookup[#, "TaskId", Missing[]] -> #) & /@ tasks];
  byTask = GroupBy[chunks, Lookup[#, "TaskId", ""] &];
  rows = KeyValueMap[Function[{tid, cs}, Module[{days, hbd},
    days = Sort[Round[Lookup[#, "DayAbs", 0]] & /@ cs];
    hbd = Association[(Round[Lookup[#, "DayAbs", 0]] -> Lookup[#, "Hours", 0]) & /@ cs];
    <|"TaskId" -> tid, "Label" -> iSVRPLabel[Lookup[byId, tid, <|"TaskId" -> tid|>]],
      "Days" -> days, "HoursByDay" -> hbd,
      "TotalHours" -> Total[Lookup[#, "Hours", 0] & /@ cs],
      "DueAtUTC" -> iSVRPAbs[Lookup[Lookup[byId, tid, <||>], "DueAtUTC", Missing[]]],
      "FirstDay" -> Min[days], "LastDay" -> Max[days]|>]], byTask];
  SortBy[rows, {#["FirstDay"] &, #["TaskId"] &}]];
SourceVaultRoutineGanttData[___] := {};

Options[SourceVaultRoutineGanttView] = {"TimeZone" -> 0};
SourceVaultRoutineGanttView[plan_Association, tasks_List, OptionsPattern[]] := Module[
  {rows = SourceVaultRoutineGanttData[plan, tasks], tz = OptionValue["TimeZone"],
   allDays, d0, d1, dayIdx, prims, n},
  If[rows === {}, Return[Style["No scheduled work.", Italic]]];
  allDays = Union[Flatten[#["Days"] & /@ rows]];
  d0 = Min[allDays]; d1 = Max[Append[allDays,
    Max[DeleteMissing[#["DueAtUTC"] & /@ rows]]]];
  dayIdx[day_] := Round[(day - d0)/$svRPDay];
  n = Length[rows];
  prims = Flatten@MapIndexed[Function[{row, i}, Module[{y = n - i[[1]], bars, dueX},
    bars = Map[Function[day, {RGBColor[0.27, 0.54, 0.79],
      Tooltip[Rectangle[{dayIdx[day], y + 0.1}, {dayIdx[day] + 0.9, y + 0.9}],
        row["Label"] <> " (" <> ToString[row["HoursByDay"][day]] <> "h, "
          <> DateString[FromAbsoluteTime[day], {"Month", "/", "Day"}] <> ")"]}],
      row["Days"]];
    dueX = If[NumberQ[row["DueAtUTC"]], {RGBColor[0.85, 0.2, 0.2],
      Line[{{dayIdx[row["DueAtUTC"]], y}, {dayIdx[row["DueAtUTC"]], y + 1}}]}, {}];
    {bars, dueX}]], rows];
  Graphics[prims,
    Frame -> True, AspectRatio -> 1/GoldenRatio,
    FrameTicks -> {{Table[{n - i + 0.5, rows[[i]]["Label"]}, {i, n}], None},
      {Table[{dayIdx[d0 + k*$svRPDay] + 0.45,
        DateString[FromAbsoluteTime[d0 + k*$svRPDay], {"Month", "/", "Day"}]},
        {k, 0, dayIdx[d1]}], None}},
    PlotRangePadding -> 0.5, ImageSize -> 520]];
SourceVaultRoutineGanttView[___] := Style["SourceVaultRoutineGanttView: bad args.", Red];

Options[SourceVaultRoutineLoadData] = {"TimeZone" -> 0, "Tasks" -> {}};
SourceVaultRoutineLoadData[plan_Association, capacityFn_, from_, to_, OptionsPattern[]] := Module[
  {tz = OptionValue["TimeZone"], f = iSVRPDayStart[iSVRPAbs[from], OptionValue["TimeZone"]],
   t = iSVRPDayStart[iSVRPAbs[to], OptionValue["TimeZone"]], chunks, plannedByDay,
   chunksByDay, byId, day, out = {}},
  If[!NumberQ[f] || !NumberQ[t], Return[{}]];
  chunks = Lookup[plan, "Chunks", {}];
  byId = Association[(Lookup[#, "TaskId", Missing[]] -> #) & /@ OptionValue["Tasks"]];
  plannedByDay = GroupBy[chunks, Round[Lookup[#, "DayAbs", 0]] &,
    Total[Lookup[#, "Hours", 0] & /@ #] &];
  chunksByDay = GroupBy[chunks, Round[Lookup[#, "DayAbs", 0]] &];
  day = f;
  While[day <= t + 0.5,
    Module[{cap = Max[0., Quiet@Check[capacityFn[day], 0.]],
        planned = N@Lookup[plannedByDay, Round[day], 0.], dtasks},
      dtasks = Map[Function[c, <|"TaskId" -> Lookup[c, "TaskId", "?"],
        "Label" -> iSVRPLabel[Lookup[byId, Lookup[c, "TaskId", ""],
          <|"TaskId" -> Lookup[c, "TaskId", "?"]|>]],
        "Hours" -> Lookup[c, "Hours", 0]|>], Lookup[chunksByDay, Round[day], {}]];
      AppendTo[out, <|"DayAbs" -> day, "DayKey" -> iSVRPDayKey[day, tz],
        "Planned" -> planned, "Capacity" -> cap,
        "Ratio" -> If[cap > 0, planned/cap, If[planned > 0, Infinity, 0.]],
        "Over" -> (planned > cap + 10^-9), "Tasks" -> dtasks|>]];
    day += $svRPDay];
  out];
SourceVaultRoutineLoadData[___] := {};

iSVRPTrunc[s_String, n_Integer] := If[StringLength[s] > n, StringTake[s, n] <> "\[Ellipsis]", s];

Options[SourceVaultRoutineLoadView] = {"TimeZone" -> 0, "Tasks" -> {}};
SourceVaultRoutineLoadView[plan_Association, capacityFn_, from_, to_, OptionsPattern[]] := Module[
  {data = SourceVaultRoutineLoadData[plan, capacityFn, from, to,
     "TimeZone" -> OptionValue["TimeZone"], "Tasks" -> OptionValue["Tasks"]], cells},
  If[data === {}, Return[Style["No load data.", Italic]]];
  cells = Map[Function[d, Module[{r = d["Ratio"], col, dtasks = Lookup[d, "Tasks", {}],
      taskLine, tipText},
    col = Which[
      d["Over"], RGBColor[0.85, 0.2, 0.2],
      r >= 0.75, RGBColor[0.95, 0.6, 0.15],
      r > 0, RGBColor[0.4, 0.7, 0.4],
      True, GrayLevel[0.92]];
    (* compact task hint in the cell: first label(s), rest as +N *)
    taskLine = Which[
      dtasks === {}, "",
      Length[dtasks] == 1, iSVRPTrunc[dtasks[[1]]["Label"], 12],
      True, iSVRPTrunc[dtasks[[1]]["Label"], 9] <> " +" <> ToString[Length[dtasks] - 1]];
    tipText = If[dtasks === {},
      d["DayKey"] <> ": " <> ToString[NumberForm[100*d["Ratio"], {4, 0}]] <> "% (no tasks)",
      d["DayKey"] <> " (" <> ToString[NumberForm[100*d["Ratio"], {4, 0}]] <> "%):\n" <>
        StringRiffle[Map[("- " <> #["Label"] <> " " <> ToString[#["Hours"]] <> "h") &, dtasks],
          "\n"]];
    Tooltip[
      Item[Framed[Column[{
        Style[DateString[FromAbsoluteTime[d["DayAbs"]], {"Month", "/", "Day"}], 9],
        Style[taskLine, 8, Bold],
        Style[ToString[NumberForm[d["Planned"], {3, 1}]] <> "/" <>
          ToString[NumberForm[d["Capacity"], {3, 1}]] <> "h", 8]}, Alignment -> Center,
        Spacings -> 0.15],
        Background -> col, FrameStyle -> GrayLevel[0.7], ImageSize -> {78, 52}]],
      tipText]]], data];
  Grid[Partition[cells, 7, 7, {1, 1}, ""], Spacings -> {0.3, 0.3}]];
SourceVaultRoutineLoadView[___] := Style["SourceVaultRoutineLoadView: bad args.", Red];

Options[SourceVaultRoutineProcessGraph] = {"VertexLabels" -> Automatic};
SourceVaultRoutineProcessGraph[tasks_List, OptionsPattern[]] := Module[
  {ids, edges, byId, labelRules},
  byId = Association[(Lookup[#, "TaskId", Missing[]] -> #) & /@ tasks];
  ids = Select[Lookup[#, "TaskId", Missing[]] & /@ tasks, StringQ];
  edges = Flatten[Map[Function[t, Module[{tid = Lookup[t, "TaskId", ""]},
    Map[(# -> tid) &, Select[Lookup[t, "DependsOn", {}], MemberQ[ids, #] &]]]], tasks]];
  (* vertices keep the TaskId identity; labels are the human StepId/Label *)
  labelRules = Map[(# -> iSVRPLabel[Lookup[byId, #, <|"TaskId" -> #|>]]) &, ids];
  Graph[ids, DirectedEdge @@@ edges,
    VertexLabels -> If[OptionValue["VertexLabels"] === None, None, labelRules],
    GraphLayout -> "LayeredDigraphEmbedding", ImageSize -> 420]];
SourceVaultRoutineProcessGraph[___] := Graph[{}, {}];

(* --- ScheduleFabric integration (real calendar + $onWork) --- *)

iSVRPEventMatchesPrep[event_, match_] := Module[
  {pats = Lookup[match, "Patterns", {}], mandOnly = TrueQ[Lookup[match, "MandatoryOnly", False]],
   hay},
  If[mandOnly && !TrueQ[Lookup[event, "Mandatory", False]], Return[False]];
  hay = StringRiffle[Select[Flatten[{Lookup[event, "Summary", ""],
    Lookup[event, "Categories", {}]}], StringQ], " "];
  If[pats === {}, True,
    AnyTrue[pats, Function[p, TrueQ[Quiet@Check[
      StringContainsQ[hay, p, IgnoreCase -> True], False]]]]]];

Options[SourceVaultRoutineFabricTasks] = {
  PrivacySpec -> <|"AccessLevel" -> 1.0|>, "OnWorkTasks" -> Automatic,
  "CalendarEvents" -> Automatic, "PreparationSpecs" -> {}, "DefaultEffortHours" -> 2,
  "IncludeDone" -> False};
SourceVaultRoutineFabricTasks[from_, to_, OptionsPattern[]] := Module[
  {fromAbs = iSVRPAbs[from], toAbs = iSVRPAbs[to], ow, cal, tasks = {}, prepSpecs,
   def = OptionValue["DefaultEffortHours"], ps = OptionValue[PrivacySpec]},
  If[!NumberQ[fromAbs] || !NumberQ[toAbs], Return[{}]];
  (* --- $onWork deadline tasks --- *)
  ow = With[{o = OptionValue["OnWorkTasks"]},
    If[o === Automatic,
      If[Length[Names["NBAccess`NBOnWorkTasks"]] > 0,
        Quiet@Check[NBAccess`NBOnWorkTasks[PrivacySpec -> ps,
          "IncludeDone" -> OptionValue["IncludeDone"]], {}], {}],
      o]];
  If[!ListQ[ow], ow = {}];
  Do[Module[{due = iSVRPAbs[Lookup[t, "Due", Missing[]]],
      title = Lookup[t, "Title", Lookup[t, "FileDigest", "task"]],
      tid = Lookup[t, "TaskId", Lookup[t, "FileDigest", Missing[]]],
      state = Lookup[t, "State", "Open"]},
    If[NumberQ[due] && fromAbs - $svRPDay <= due <= toAbs && StringQ[tid] &&
        (TrueQ[OptionValue["IncludeDone"]] ||
          !MemberQ[{"Done", "Pass", "Keep"}, state]),
      AppendTo[tasks, <|"Kind" -> "OnWorkTask",
        "TaskId" -> "nb:" <> ToString[tid],
        "Label" -> If[StringQ[title], title, "task"],
        "DueAtUTC" -> due,
        "Effort" -> With[{e = Lookup[t, "Effort", Missing["None"]]},
          If[MissingQ[e], def, e]],
        "Movable" -> If[BooleanQ[Lookup[t, "Movable", Missing[]]], t["Movable"], True],
        "DependsOn" -> {}|>]]],
    {t, ow}];
  (* --- preparation tasks for matching calendar meetings --- *)
  prepSpecs = OptionValue["PreparationSpecs"];
  If[ListQ[prepSpecs] && prepSpecs =!= {},
    cal = With[{c = OptionValue["CalendarEvents"]},
      If[c === Automatic,
        If[Length[Names["NBAccess`NBCalendarEvents"]] > 0,
          Quiet@Check[NBAccess`NBCalendarEvents[
            DateObject[FromAbsoluteTime[fromAbs]],
            DateObject[FromAbsoluteTime[toAbs + 60*$svRPDay]], PrivacySpec -> ps], {}], {}],
        c]];
    If[!ListQ[cal], cal = {}];
    Do[Do[If[iSVRPEventMatchesPrep[ev, Lookup[spec, "Match", <||>]],
        tasks = Join[tasks, SourceVaultRoutinePreparationTasks[ev,
          Lookup[spec, "Prep", <||>]]]],
      {spec, prepSpecs}], {ev, cal}]];
  tasks];
SourceVaultRoutineFabricTasks[___] := {};

iSVRPBusyHoursByDay[freebusy_, tz_] := Module[{acc = <||>},
  Do[Module[{s = iSVRPAbs[Lookup[b, "Start", Missing[]]],
      e = iSVRPAbs[Lookup[b, "End", Missing[]]], day, dur},
    If[NumberQ[s] && NumberQ[e] && e > s,
      (* attribute the block to the day of its start (coarse but adequate) *)
      day = iSVRPDayKey[iSVRPDayStart[s, tz], tz];
      dur = (e - s)/3600.;
      If[StringQ[day], acc[day] = N@Lookup[acc, day, 0.] + dur]]],
    {b, freebusy}];
  acc];

Options[SourceVaultRoutineFabricCapacityFn] = {
  "CapacityModel" -> Automatic, "FreeBusy" -> Automatic, "AwayDays" -> {}, "TimeZone" -> 0};
SourceVaultRoutineFabricCapacityFn[from_, to_, OptionsPattern[]] := Module[
  {tz = OptionValue["TimeZone"], capModel, fb, busyByDay},
  capModel = With[{c = OptionValue["CapacityModel"]},
    If[c === Automatic, SourceVaultRoutineDefaultCapacityModel[], c]];
  fb = With[{f = OptionValue["FreeBusy"]},
    If[f === Automatic,
      If[Length[Names["NBAccess`NBCalendarFreeBusy"]] > 0,
        Quiet@Check[NBAccess`NBCalendarFreeBusy[
          DateObject[FromAbsoluteTime[iSVRPAbs[from]]],
          DateObject[FromAbsoluteTime[iSVRPAbs[to]]]], {}], {}],
      f]];
  If[!ListQ[fb], fb = {}];
  busyByDay = iSVRPBusyHoursByDay[fb, tz];
  SourceVaultRoutineDayCapacityFn[capModel, "TimeZone" -> tz,
    "BusyHoursByDay" -> busyByDay, "AwayDays" -> OptionValue["AwayDays"]]];
SourceVaultRoutineFabricCapacityFn[___] :=
  SourceVaultRoutineDayCapacityFn[SourceVaultRoutineDefaultCapacityModel[]];

(* ============================================================
   Unified daily agenda: calendar events + $onWork deadlines/reviews,
   grouped by day; each notebook item carries its Path for one-click open.
   ============================================================ *)

iSVRPWeekdayJP[dayAbs_] := Switch[
  Quiet@Check[DateValue[FromAbsoluteTime[dayAbs], "DayName"], None],
  Monday, "\:6708", Tuesday, "\:706b", Wednesday, "\:6c34", Thursday, "\:6728",
  Friday, "\:91d1", Saturday, "\:571f", Sunday, "\:65e5", _, ""];

(* all-day if it starts at local midnight and spans whole days *)
iSVRPAllDayQ[s_, e_, tz_] := TrueQ[NumberQ[s] && NumberQ[e] &&
  Abs[s - iSVRPDayStart[s, tz]] < 60 && (e - s) >= 86340 &&
  Abs[Mod[e - s, 86400.]] < 60];

iSVRPHM[abs_, tz_] := Module[{ds = iSVRPDayStart[abs, tz], secs, h, m},
  If[!NumberQ[ds], Return["--:--"]];
  secs = abs - ds; h = Floor[secs/3600]; m = Floor[Mod[secs, 3600]/60];
  StringJoin[IntegerString[h, 10, 2], ":", IntegerString[m, 10, 2]]];

(* display name for a $onWork task: Title, else the file base name minus a date prefix *)
iSVRPTaskName[t_] := Module[
  {title = Lookup[t, "Title", Missing[]], p = Lookup[t, "Path", Missing[]], base},
  Which[
    StringQ[title] && StringLength[StringTrim[title]] > 0, title,
    StringQ[p], base = FileBaseName[p];
      StringReplace[base, RegularExpression["^\\d{6,8}[-_]?"] -> ""],
    True, "(untitled)"]];

iSVRPAllDayRank[item_] := Switch[Lookup[item, "Kind", ""],
  "Deadline", 1, "MailDeadline", 2, "Review", 3, "AllDayEvent", 4, _, 5];

Options[SourceVaultRoutineAgendaData] = {
  PrivacySpec -> <|"AccessLevel" -> 1.0|>, "CalendarEvents" -> Automatic,
  "OnWorkTasks" -> Automatic, "ModifiedWithinDays" -> 120, "IncludeOverdue" -> True,
  "TimeZone" -> Automatic, "IncludeMail" -> Automatic, "MailItems" -> Automatic,
  "MailMaxPrivacyLevel" -> 1.0};

SourceVaultRoutineAgendaData[dur_Quantity, opts : OptionsPattern[]] :=
  SourceVaultRoutineAgendaData[N[AbsoluteTime[]],
    N[AbsoluteTime[]] + iSVRPHours[dur]*3600., opts];

SourceVaultRoutineAgendaData[from_, to_, OptionsPattern[]] := Module[
  {tz = OptionValue["TimeZone"], ps = OptionValue[PrivacySpec],
   fromAbs = iSVRPAbs[from], toAbs = iSVRPAbs[to], cal, ow, items = {}, overdue = {},
   fromDay, toDayEnd, byDay, dayKeys, days},
  If[tz === Automatic, tz = $TimeZone];
  If[!NumberQ[fromAbs] || !NumberQ[toAbs],
    Return[<|"From" -> from, "To" -> to, "TimeZone" -> tz, "Overdue" -> {},
      "Mail" -> {}, "MailPendingCount" -> 0, "Days" -> {}|>]];
  fromDay = iSVRPDayStart[fromAbs, tz];
  toDayEnd = iSVRPDayStart[toAbs, tz] + $svRPDay;

  (* --- calendar events --- *)
  cal = With[{c = OptionValue["CalendarEvents"]},
    If[c === Automatic,
      If[Length[Names["NBAccess`NBCalendarEvents"]] > 0,
        Quiet@Check[NBAccess`NBCalendarEvents[DateObject[FromAbsoluteTime[fromDay]],
          DateObject[FromAbsoluteTime[toDayEnd]], PrivacySpec -> ps], {}], {}],
      c]];
  If[!ListQ[cal], cal = {}];
  Do[Module[{s = iSVRPAbs[Lookup[ev, "Start", Missing[]]],
      e = iSVRPAbs[Lookup[ev, "End", Missing[]]],
      sum = Lookup[ev, "Summary", Lookup[ev, "Title", ""]], allday, d},
    If[NumberQ[s],
      e = If[NumberQ[e], e, s];
      allday = If[BooleanQ[Lookup[ev, "AllDay", Missing[]]], TrueQ[ev["AllDay"]],
        iSVRPAllDayQ[s, e, tz]];
      d = iSVRPDayStart[s, tz];
      If[NumberQ[d] && fromDay <= d < toDayEnd,
        AppendTo[items, <|"Kind" -> If[allday, "AllDayEvent", "Event"],
          "StartT" -> s, "EndT" -> e,
          "Label" -> If[StringQ[sum], sum, ToString[sum]],
          "Mandatory" -> TrueQ[Lookup[ev, "Mandatory", False]],
          "DayAbs" -> d|>]]]],
    {ev, cal}];

  (* --- $onWork deadlines / reviews --- *)
  ow = With[{o = OptionValue["OnWorkTasks"]},
    If[o === Automatic,
      If[Length[Names["NBAccess`NBOnWorkTasks"]] > 0,
        Quiet@Check[NBAccess`NBOnWorkTasks[PrivacySpec -> ps,
          "ModifiedWithinDays" -> OptionValue["ModifiedWithinDays"]], {}], {}],
      o]];
  If[!ListQ[ow], ow = {}];
  Do[Module[{due = iSVRPAbs[Lookup[t, "Due", Missing[]]],
      kind = Lookup[t, "DueKind", Missing[]], state = Lookup[t, "State", "Open"], item, d},
    (* Keep = intentionally parked: no reminders, so neither the day list nor
       the overdue band should nag about it *)
    If[NumberQ[due] && !MemberQ[{"Done", "Pass", "Keep"}, state],
      d = iSVRPDayStart[due, tz];
      item = <|"Kind" -> Switch[kind, "NextReview", "Review", _, "Deadline"],
        "DueT" -> due, "Label" -> iSVRPTaskName[t], "Path" -> Lookup[t, "Path", Missing[]],
        "State" -> state, "DayAbs" -> d|>;
      Which[
        d < fromDay, If[TrueQ[OptionValue["IncludeOverdue"]], AppendTo[overdue, item]],
        d < toDayEnd, AppendTo[items, item]]]],
    {t, ow}];

  overdue = SortBy[overdue, #["DueT"] &];

  (* --- actionable mails (R9, weak binding to SourceVault_mailagenda) --- *)
  Module[{includeMail = OptionValue["IncludeMail"], mailRes, mailItems = {},
      mailPending = 0, level},
    level = Which[
      AssociationQ[ps] && NumberQ[Lookup[ps, "AccessLevel", Missing[]]],
        N[ps["AccessLevel"]],
      NumberQ[ps], N[ps], True, 1.0];
    If[includeMail === Automatic, includeMail = level >= 1.0];
    If[TrueQ[includeMail],
      mailRes = With[{m = OptionValue["MailItems"],
          mpl = OptionValue["MailMaxPrivacyLevel"]},
        If[m === Automatic,
          If[Length[DownValues[SourceVaultMailAgendaItems]] > 0,
            Quiet@Check[SourceVaultMailAgendaItems[
              "MaxPrivacyLevel" -> mpl], <||>], <||>],
          <|"Items" -> m, "PendingCount" -> 0|>]];
      If[AssociationQ[mailRes],
        mailItems = Lookup[mailRes, "Items", {}];
        mailPending = Lookup[mailRes, "PendingCount", 0]];
      If[!ListQ[mailItems], mailItems = {}];
      (* privacy filter also on injected items (missing PL = 1.0, fail-safe) *)
      With[{mpl = With[{m = OptionValue["MailMaxPrivacyLevel"]},
          If[NumberQ[m], N[m], 1.0]]},
        mailItems = Select[mailItems, iSVRPMailPL[#] <= mpl &]]];

    (* mails with a definite deadline join the day calendar: an all-day item on
       the deadline day, clickable through to the mail action window *)
    Do[Module[{dl = iSVRPAbs[Lookup[mi, "Deadline", Missing[]]], d},
      If[NumberQ[dl],
        d = iSVRPDayStart[dl, tz];
        If[NumberQ[d] && fromDay <= d < toDayEnd,
          AppendTo[items, <|"Kind" -> "MailDeadline", "DueT" -> dl,
            "Label" -> Lookup[mi, "Subject", "mail"],
            "MailRecordId" -> Lookup[mi, "RecordId", Missing[]],
            "DayAbs" -> d|>]]]],
      {mi, mailItems}];

    (* --- group by day (after mail deadlines joined) --- *)
    byDay = GroupBy[items, Round[#["DayAbs"]] &];
    dayKeys = Sort[Keys[byDay]];
    days = Map[Function[dk, Module[{grp = byDay[dk]},
      <|"DayAbs" -> N[dk], "DayKey" -> iSVRPDayKey[dk, tz],
        "Weekday" -> iSVRPWeekdayJP[dk],
        "AllDay" -> SortBy[Select[grp, MemberQ[
            {"Deadline", "MailDeadline", "Review", "AllDayEvent"}, #["Kind"]] &],
          {iSVRPAllDayRank[#], Lookup[#, "Label", ""]} &],
        "Timed" -> SortBy[Select[grp, #["Kind"] === "Event" &],
          #["StartT"] &]|>]], dayKeys];
    <|"From" -> fromAbs, "To" -> toAbs, "TimeZone" -> tz, "Overdue" -> overdue,
      "Mail" -> mailItems, "MailPendingCount" -> mailPending, "Days" -> days|>]];
SourceVaultRoutineAgendaData[___] :=
  <|"From" -> Missing[], "To" -> Missing[], "TimeZone" -> 0, "Overdue" -> {},
    "Mail" -> {}, "MailPendingCount" -> 0, "Days" -> {}|>;

(* ---- view ---- *)
iSVRPAgendaColor["Deadline"] = RGBColor[0.85, 0.2, 0.2];
iSVRPAgendaColor["MailDeadline"] = RGBColor[0.8, 0.3, 0.15];
iSVRPAgendaColor["Review"] = RGBColor[0.2, 0.45, 0.8];
iSVRPAgendaColor["AllDayEvent"] = RGBColor[0.2, 0.6, 0.3];
iSVRPAgendaColor["Event"] = RGBColor[0.2, 0.55, 0.35];
iSVRPAgendaColor[_] = GrayLevel[0.3];
iSVRPAgendaKindTag["MailDeadline"] = "\:2709\:3006\:5207";
iSVRPAgendaKindTag["Deadline"] = "\:3006\:5207";
iSVRPAgendaKindTag["Review"] = "\:30ec\:30d3\:30e5\:30fc";
iSVRPAgendaKindTag[_] = "";

iSVRPAgendaItemRow[item_, tz_] := Module[
  {kind = Lookup[item, "Kind", ""], col, path = Lookup[item, "Path", Missing[]],
   label = Lookup[item, "Label", "?"], tag, timepart, mand, nameCell},
  col = iSVRPAgendaColor[kind];
  tag = iSVRPAgendaKindTag[kind];
  mand = TrueQ[Lookup[item, "Mandatory", False]];
  timepart = Switch[kind,
    "Event", iSVRPHM[Lookup[item, "StartT", 0], tz] <> "\:2013" <>
      iSVRPHM[Lookup[item, "EndT", 0], tz],
    "AllDayEvent", "\:7d42\:65e5",
    _, "\:3000\:3000"];
  (* clickable open. Two traps fixed: (1) BaseStyle "Hyperlink" OVERRODE the
     ButtonFunction with hyperlink navigation, so clicks did nothing. (2) NotebookOpen
     cannot open a Dropbox online-only (not-yet-downloaded) placeholder, which is why
     older/long-untouched notebooks failed while recent (local) ones opened; SystemOpen
     goes through the OS so Dropbox downloads the file first (matches the working
     NotebookExtensions dashboard, which also uses SystemOpen). Mouseover = link look. *)
  nameCell = Which[
    StringQ[path],
    With[{p = path, lbl = label, c = col},
      Tooltip[
        Button[Mouseover[Style[lbl, c, 12], Style[lbl, c, 12, Underlined]],
          SystemOpen[p], Appearance -> None],
        "\:958b\:304f: " <> p]],
    (* mail deadline on the calendar: click -> the mail action window *)
    StringQ[Lookup[item, "MailRecordId", Missing[]]] &&
      Length[DownValues[SourceVaultMailAgendaOpen]] > 0,
    With[{r = item["MailRecordId"], lbl = label, c = col},
      Tooltip[
        Button[Mouseover[Style[lbl, c, 12], Style[lbl, c, 12, Underlined]],
          SourceVaultMailAgendaOpen[r], Appearance -> None, Method -> "Queued"],
        "\:958b\:304f: \:5bfe\:5fdc\:30a6\:30a3\:30f3\:30c9\:30a6 (\:8fd4\:4fe1/\:7d99\:627f/\:5bfe\:5fdc\:6e08\:307f)"]],
    True, Style[label, col, 12]];
  Row[{
    Style[Pane[timepart, 74], GrayLevel[0.45], 10],
    If[tag =!= "", Style["\:3010" <> tag <> "\:3011", col, Bold, 10], ""],
    If[mand, Style["\:2605", RGBColor[0.85, 0.2, 0.2], 10], ""],
    " ", nameCell}]];

(* --- mail band helpers (R9) --- *)

(* fail-safe privacy read (missing derived PL counts as 1.0, maildb convention) *)
iSVRPMailPL[item_] := With[{p = Lookup[item, "PrivacyLevel", Missing[]]},
  If[NumberQ[p], N[p], 1.0]];

(* a view containing even one PL >= 0.5 mail is confidential (maildb rule).
   Wrap through ClaudeCode`Confidential when available (cell marking + secret
   variable registration); else schedule SourceVaultMarkConfidentialViewCells
   on the evaluation notebook (FE only) as the fallback. *)
iSVRPAgendaConfidentialQ[mailItems_List] :=
  mailItems =!= {} && AnyTrue[mailItems, iSVRPMailPL[#] >= 0.5 &];

iSVRPWrapConfidential[result_, mailItems_List] := Which[
  !iSVRPAgendaConfidentialQ[mailItems], result,
  Length[DownValues[ClaudeCode`Confidential]] > 0,
    ClaudeCode`Confidential[result],
  True,
    Quiet@Check[
      If[TrueQ[$Notebooks] &&
          Length[DownValues[SourceVaultMarkConfidentialViewCells]] > 0,
        With[{nb = EvaluationNotebook[]},
          If[Head[nb] === NotebookObject,
            SessionSubmit[ScheduledTask[
              Quiet@Check[SourceVaultMarkConfidentialViewCells[nb], Null],
              {1.0}]]]]];
      Null, Null];
    result];

iSVRPMailKind[cat_, deadline_] := Which[
  cat === "TaskRequest", {"\:4f9d\:983c", RGBColor[0.75, 0.35, 0.1]},
  cat === "AttendanceRequest", {"\:51fa\:5e2d", RGBColor[0.45, 0.3, 0.75]},
  cat === "Confirmation", {"\:78ba\:8a8d", RGBColor[0.2, 0.5, 0.6]},
  StringQ[deadline], {"\:3006\:5207", RGBColor[0.85, 0.2, 0.2]},
  True, {"\:8981\:5bfe\:5fdc", GrayLevel[0.3]}];

(* "2026-07-25T00:00:00" | DateObject | abs -> "07/25"; else "" *)
iSVRPShortDate[d_] := Module[{abs = iSVRPAbs[d]},
  If[NumberQ[abs],
    DateString[FromAbsoluteTime[abs], {"Month", "/", "Day"}], ""]];

(* due-date colour rule (matches the notebook dashboards): past -> red,
   today/tomorrow (within 24h) -> blue, further future -> black. A date-only
   deadline (midnight) on TODAY still counts as "due today" -> blue; a TIMED
   deadline already passed today -> red. *)
iSVRPDueColor[dueAbs_, nowAbs_, tz_] := Module[
  {day0 = iSVRPDayStart[nowAbs, tz], dayD = iSVRPDayStart[dueAbs, tz]},
  Which[
    !NumberQ[dueAbs] || !NumberQ[day0] || !NumberQ[dayD], GrayLevel[0.1],
    dayD < day0, RGBColor[0.85, 0.2, 0.2],
    dayD == day0 && dueAbs < nowAbs && dueAbs > dayD, RGBColor[0.85, 0.2, 0.2],
    dayD <= day0 + $svRPDay, RGBColor[0.2, 0.45, 0.8],
    True, GrayLevel[0.1]]];

iSVRPMailRow[item_Association, nowAbs_, tz_ : Automatic] := Module[
  {rid = Lookup[item, "RecordId", ""], subject = Lookup[item, "Subject", "?"],
   from = Lookup[item, "From", ""], summary = Lookup[item, "Summary", Missing[]],
   dateAbs = Lookup[item, "Date", Missing[]],
   deadline = Lookup[item, "Deadline", Missing[]],
   tzv, kind, ageDays, recvStr, dlStr, subjCell},
  tzv = If[tz === Automatic, $TimeZone, tz];
  {kind, ageDays} = {iSVRPMailKind[Lookup[item, "Category", Missing[]], deadline],
    If[NumberQ[dateAbs], Max[0, Round[(nowAbs - dateAbs)/86400.]], Missing[]]};
  (* received date + age, e.g. "07/14 受信・2日前" *)
  recvStr = If[NumberQ[dateAbs],
    iSVRPShortDate[dateAbs] <> " \:53d7\:4fe1" <>
      If[IntegerQ[ageDays],
        "\:30fb" <> If[ageDays === 0, "\:4eca\:65e5",
          ToString[ageDays] <> "\:65e5\:524d"], ""], ""];
  dlStr = If[StringQ[deadline] || DateObjectQ[deadline],
    iSVRPShortDate[deadline], ""];
  If[!StringQ[subject], subject = ToString[subject]];
  subjCell = If[StringQ[rid] && rid =!= "" &&
      Length[DownValues[SourceVaultMailAgendaOpen]] > 0,
    With[{r = rid, lbl = subject},
      Tooltip[Button[
        Mouseover[Style[lbl, GrayLevel[0.1], 12],
          Style[lbl, GrayLevel[0.1], 12, Underlined]],
        SourceVaultMailAgendaOpen[r], Appearance -> None, Method -> "Queued"],
        "\:958b\:304f: \:5bfe\:5fdc\:30a6\:30a3\:30f3\:30c9\:30a6 (\:8fd4\:4fe1/\:7d99\:627f/\:5bfe\:5fdc\:6e08\:307f)"]],
    Style[subject, GrayLevel[0.1], 12]];
  Column[{
    Row[{Style["\:3010" <> kind[[1]] <> "\:3011", kind[[2]], Bold, 10], " ",
      subjCell,
      With[{tc = Lookup[item, "ThreadCount", 1]},
        If[IntegerQ[tc] && tc > 1,
          Style["\:3000(\:30b9\:30ec\:30c3\:30c9 " <> ToString[tc] <> " \:901a)",
            RGBColor[0.15, 0.35, 0.6], 9], Nothing]],
      Style["\:3000\[Dash] " <> ToString[from], GrayLevel[0.45], 10],
      If[recvStr =!= "",
        Style["\:3000(" <> recvStr <> ")", GrayLevel[0.55], 9], Nothing],
      If[dlStr =!= "",
        Style["\:3000\:3006\:5207\[FilledRightTriangle]" <> dlStr,
          iSVRPDueColor[iSVRPAbs[deadline], nowAbs, tzv], Bold, 10], Nothing]}],
    If[StringQ[summary],
      Style["\:3000\:3000" <> summary, GrayLevel[0.4], 10], Nothing]},
    Spacings -> 0.1, Alignment -> Left]];

Options[SourceVaultRoutineAgendaView] = Options[SourceVaultRoutineAgendaData];
SourceVaultRoutineAgendaView[dur_Quantity, opts : OptionsPattern[]] :=
  SourceVaultRoutineAgendaView[N[AbsoluteTime[]],
    N[AbsoluteTime[]] + iSVRPHours[dur]*3600., opts];
SourceVaultRoutineAgendaView[from_, to_, opts : OptionsPattern[]] := Module[
  {data = SourceVaultRoutineAgendaData[from, to,
     Sequence @@ FilterRules[{opts}, Options[SourceVaultRoutineAgendaData]]],
   tz, overdue, days, mail, mailPending, sections = {}},
  tz = Lookup[data, "TimeZone", 0];
  overdue = Lookup[data, "Overdue", {}];
  days = Lookup[data, "Days", {}];
  mail = Lookup[data, "Mail", {}];
  mailPending = Lookup[data, "MailPendingCount", 0];
  If[overdue === {} && days === {} && mail === {},
    Return[Style["\:4e88\:5b9a\:30fb\:3006\:5207\:30fb\:8981\:5bfe\:5fdc\:30e1\:30fc\:30eb\:306f\:3042\:308a\:307e\:305b\:3093\:3002",
      Italic, Gray]]];
  (* order: day-by-day calendar FIRST, then overdue, then actionable mails *)
  Do[Module[{dayAbs = d["DayAbs"], wd = d["Weekday"], allday = d["AllDay"],
      timed = d["Timed"], hdr, rows, weekend},
    weekend = MemberQ[{"\:571f", "\:65e5"}, wd];
    hdr = Style[DateString[FromAbsoluteTime[dayAbs], {"Month", "/", "Day"}] <>
        "\:3000(" <> wd <> ")", Bold, 13,
      If[weekend, RGBColor[0.7, 0.3, 0.3], GrayLevel[0.15]]];
    rows = Join[Map[iSVRPAgendaItemRow[#, tz] &, allday],
      Map[iSVRPAgendaItemRow[#, tz] &, timed]];
    AppendTo[sections, Column[{hdr,
      Column[rows, Spacings -> 0.4, Alignment -> Left]}, Spacings -> 0.3,
      Alignment -> Left]]],
    {d, days}];
  If[overdue =!= {},
    AppendTo[sections, Framed[Column[Prepend[
        Map[iSVRPAgendaItemRow[#, tz] &, overdue],
        Style["\:26a0 \:671f\:9650\:8d85\:904e\:30fb\:672a\:51e6\:7406", RGBColor[0.85, 0.2, 0.2],
          Bold, 12]], Alignment -> Left, Spacings -> 0.35],
      Background -> RGBColor[1, 0.95, 0.95], FrameStyle -> RGBColor[0.85, 0.55, 0.55],
      RoundingRadius -> 5, FrameMargins -> 8]]];
  (* R9: actionable mails needing reply / owner-directed requests *)
  If[mail =!= {} || mailPending > 0,
    Module[{nowAbs = N[AbsoluteTime[]], rows},
      rows = Map[iSVRPMailRow[#, nowAbs, tz] &, mail];
      If[IntegerQ[mailPending] && mailPending > 0,
        AppendTo[rows, Style[
          "(\:672a\:5206\:985e " <> ToString[mailPending] <>
          " \:4ef6 \[Dash] SourceVaultMailAddSummaries[mbox] \:3067\:8981\:7d04\:3092\:8a08\:7b97)",
          Italic, GrayLevel[0.5], 9]]];
      AppendTo[sections, Framed[Column[Prepend[rows,
          Style["\:2709 \:8981\:5bfe\:5fdc\:30e1\:30fc\:30eb (" <>
            ToString[Length[mail]] <> ")", RGBColor[0.15, 0.35, 0.6], Bold, 12]],
          Alignment -> Left, Spacings -> 0.4],
        Background -> RGBColor[0.95, 0.97, 1], FrameStyle -> RGBColor[0.55, 0.65, 0.85],
        RoundingRadius -> 5, FrameMargins -> 8]]]];
  iSVRPWrapConfidential[
    Framed[Column[sections, Spacings -> 1.2, Alignment -> Left],
      FrameStyle -> GrayLevel[0.85], FrameMargins -> 12, RoundingRadius -> 6],
    mail]];
SourceVaultRoutineAgendaView[___] :=
  Style["SourceVaultRoutineAgendaView: bad args.", Red];

End[];

EndPackage[];
