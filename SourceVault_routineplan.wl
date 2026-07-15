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
before its due is reported Infeasible (never silently dropped, AC-023). Options \
\"TimeZone\" (0), \"PlanStart\" (Automatic=now), \"DefaultEffortHours\" (1). Returns \
<|\"Chunks\"->{<|\"TaskId\",\"DayAbs\",\"Hours\"|>...}, \"Infeasible\"->{<|\"TaskId\", \
\"ShortfallHours\"|>...}, \"Order\"->{ids}, \"CycleDetected\"->Bool|>.";

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
  Map[Function[st, Module[{sid = Lookup[st, "StepId", Missing[]], dep},
    dep = Lookup[st, "DependsOnStepId", Missing["None"]];
    <|"Kind" -> "PrepTask", "TaskId" -> prepIdOf[sid],
      "StepId" -> sid,
      "Identity" -> <|"StableId" -> prepIdOf[sid], "OccurrenceToken" -> parentTok|>,
      "DueAtUTC" -> due, "EarliestStart" -> earliest,
      "Effort" -> Lookup[st, "Effort", Missing["None"]],
      "DependsOn" -> If[MemberQ[stepIdSet, dep], {prepIdOf[dep]}, {}],
      "Movable" -> True,
      "ParentRef" -> <|"StableId" -> parentId, "OccurrenceToken" -> parentTok|>|>]],
    steps]];
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
  "TimeZone" -> 0, "PlanStart" -> Automatic, "DefaultEffortHours" -> 1};
SourceVaultRoutinePlacePlan[tasks_List, capacityFn_, OptionsPattern[]] := Module[
  {tz = OptionValue["TimeZone"], planStart, byId, indeg, dependents, ready, used = <||>,
   finishDay = <||>, chunks = {}, infeasible = {}, order = {}, defEff, ids},
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
  ready = Select[ids, indeg[#] == 0 &];
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
          Select[Lookup[task, "DependsOn", {}], MemberQ[ids, #] &]]]]];
      dueDay = With[{d = iSVRPDueOf[byId, tid]},
        If[NumberQ[d], iSVRPDayStart[d, tz], earliest]];
      remaining = eff; day = earliest; last = earliest;
      While[remaining > 10^-9 && day <= dueDay + 0.5,
        Module[{avail = Max[0., Quiet@Check[capacityFn[day], 0.] - Lookup[used, day, 0.]], put},
          If[avail > 0,
            put = Min[remaining, avail];
            AppendTo[chunks, <|"TaskId" -> tid, "DayAbs" -> day, "Hours" -> put|>];
            used[day] = Lookup[used, day, 0.] + put; remaining -= put; last = day]];
        day += $svRPDay];
      finishDay[tid] = last;
      If[remaining > 10^-6,
        AppendTo[infeasible, <|"TaskId" -> tid, "ShortfallHours" -> remaining|>]];
      Do[indeg[d] = indeg[d] - 1; If[indeg[d] == 0, AppendTo[ready, d]],
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

End[];

EndPackage[];
