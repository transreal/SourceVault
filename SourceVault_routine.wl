(* ::Package:: *)

(* SourceVault_routine.wl
   Routine / obligation core -- R1: canonical identity rules + pure functions.
   NO IO, NO LLM, NO dependency on other SourceVault packages (loadable standalone).
   Spec: sourcevault_routine_attention_spec_v0_4.md (core).

   R1 covers the deterministic, side-effect-free heart of the routine layer:
     - identity rules (spec 2.2): StableId + OccurrenceToken, immutable across
       fulfillment / deadline / metadata changes.
     - 3-valued (Kleene) evidence logic (spec 2.6): Not[Unknown]=Unknown, source
       unavailable never becomes True/OutcomeSatisfied.
     - Resolution state machine (spec 2.4): SatisfiedOnTime/Late/SupersededByCatchUp/
       Missed/Waived, with monotonic WasOverdue / FirstOverdueAtUTC.
     - long-period due generation (spec 4.1 / AC-032): direct arithmetic, never
       silenced by a scan cap.
     - OverdueContractSeconds (spec 4.3 / AC via P1-11): daily overdue integral.

   All times are handled as absolute seconds internally; DateObject or
   absolute-time inputs are accepted and normalized. Pure ASCII source. *)

BeginPackage["SourceVault`"];

SourceVaultRoutineIdentity::usage =
  "SourceVaultRoutineIdentity[kind, data] returns <|\"Namespace\",\"StableId\",\
\"OccurrenceToken\"|> for an obligation source record (spec 2.2). kind is one of \
\"CalendarEvent\"/\"Routine\"/\"Commitment\"/\"OnWorkTask\"/\"PrepTask\". The \
StableId and OccurrenceToken are IMMUTABLE across fulfillment, deadline and \
metadata changes; behaviour changes belong to Revision, not identity. \
CalendarEvent uses data[\"EventId\"] (NBAccess R0b) + data[\"OriginalStart\"]; \
Routine uses RoutineId + WindowStartUTC; Commitment uses CommitmentId + \
CommitmentOccurrenceId; OnWorkTask uses TaskId + ReviewCycleOrdinal; PrepTask \
uses a digest of ParentStableId+StepId + the parent OccurrenceToken.";

SourceVaultRoutineKeyString::usage =
  "SourceVaultRoutineKeyString[identity] returns the canonical dedup/ledger key \
string \"StableId|OccurrenceToken\" for an identity Association (or an occurrence \
that carries \"Identity\").";

SourceVaultRoutineTriple::usage =
  "SourceVaultRoutineTriple[truth, quality, freshness] builds a normalized evidence \
triple <|\"Truth\"->True|False|\"Unknown\", \"Quality\"->_|Missing, \
\"Freshness\"->\"Fresh\"|\"Stale\"|\"Partial\"|\"Unavailable\"|>. quality is one of \
\"AttemptObserved\"/\"ExecutionSucceeded\"/\"OutcomeSatisfied\" or Missing.";

SourceVaultRoutineKleeneNot::usage =
  "SourceVaultRoutineKleeneNot[triple] applies 3-valued negation: True<->False, \
Unknown->Unknown (spec 2.6). Quality is dropped (Not is a guard, not a positive \
postcondition). Freshness is preserved.";
SourceVaultRoutineKleeneAllOf::usage =
  "SourceVaultRoutineKleeneAllOf[triples] is Kleene conjunction: any False -> False; \
else any Unknown -> Unknown; else True with Quality = min over constituents. Empty \
list -> True. Freshness = worst over constituents.";
SourceVaultRoutineKleeneAnyOf::usage =
  "SourceVaultRoutineKleeneAnyOf[triples] is Kleene disjunction: any True -> True \
with Quality = max over the True branches; else any Unknown -> Unknown; else False. \
Empty list -> False.";

SourceVaultRoutineEvaluateEvidence::usage =
  "SourceVaultRoutineEvaluateEvidence[spec, atomFn] recursively evaluates an \
EvidenceSpec boolean tree (keys \"AllOf\"/\"AnyOf\"/\"Not\"/\"Atom\") to a triple. \
atomFn is the injection seam: atomFn[atomSpec] must return a triple (Truth/Quality/\
Freshness). This keeps R1 IO-free; the real atom resolvers (event store, watermark, \
AutoTrigger runs) are supplied in R2. A leaf with no recognized key -> Unknown.";

SourceVaultRoutineFulfillmentReached::usage =
  "SourceVaultRoutineFulfillmentReached[triple, minQuality] is True only when \
triple[\"Truth\"] === True AND its quality rank >= minQuality's rank. Unknown and \
False never reach fulfillment (spec 2.6 / AC-034).";

SourceVaultRoutineQualityRank::usage =
  "SourceVaultRoutineQualityRank[quality] maps AttemptObserved/ExecutionSucceeded/\
OutcomeSatisfied to 1/2/3 (Missing/other -> 0). Exposed for tests and R2.";

SourceVaultRoutineTemporalState::usage =
  "SourceVaultRoutineTemporalState[schedule, now, opts] returns \"Upcoming\"/\
\"DueSoon\"/\"Overdue\" from schedule[\"DueAtUTC\"]/[\"GraceUntilUTC\"] and now \
(DateObject or absolute seconds). now < Due-SoonWindow: Upcoming; up to GraceUntil: \
DueSoon; at/after GraceUntil: Overdue. Option \"SoonWindow\" (seconds, default 86400).";

SourceVaultRoutineResolveSeries::usage =
  "SourceVaultRoutineResolveSeries[occurrences, evidence, now, mode] resolves a \
whole obligation series purely (spec 2.4). occurrences is a list of \
<|\"OccurrenceToken\", \"DueAtUTC\", \"GraceUntilUTC\", (\"WindowStartUTC\")|> \
sorted by Due; evidence is a list of <|\"AtUTC\", (\"Quality\")|> execution \
timestamps; mode is \"EachOccurrence\"/\"LatestState\"/\"AnyWithinWindow\". Returns \
one Fulfillment Association per occurrence with State/Resolution/WasOverdue/\
FirstOverdueAtUTC/EvidenceAtUTC/EvidenceQuality. LatestState restores current \
coverage but keeps past unfulfilled occurrences as SupersededByCatchUp with \
WasOverdue retained; EachOccurrence keeps each independent (AC-010). WasOverdue \
and FirstOverdueAtUTC, once True/set, are never cleared by later catch-up (AC-025).";

SourceVaultRoutineNextDue::usage =
  "SourceVaultRoutineNextDue[cadence, from, opts] returns the next due strictly \
after `from` as <|\"DueAtUTC\", \"GraceUntilUTC\", \"Capped\"->False|>, computed by \
DIRECT arithmetic so long/sparse cadences are never silenced by a scan cap \
(spec 4.1 / AC-032). cadence Kind: \"Interval\" (IntervalSeconds+Anchor), \
\"Daily\"/\"Weekly\"/\"Monthly\"/\"Yearly\" (Interval count + Anchor). Grace comes \
from cadence[\"GraceSeconds\"] or option \"GraceSeconds\" (default 0). For other \
Kinds an injected option \"NextFireFn\" (cadence, fromAbs) -> absOrMissing is used; \
if absent, returns Failure[\"NBRoutineNoNextDue\"]. Month/Year stepping clamps \
short months (a due target, unlike NBCalendarEvents strict-skip expansion).";

SourceVaultRoutineOverdueSeconds::usage =
  "SourceVaultRoutineOverdueSeconds[graceUntil, resolvedAt, dayStart, dayEnd] \
returns the length of [max(graceUntil, dayStart), min(resolvedAtOrDayEnd, dayEnd)] \
in seconds (>=0): the within-day overdue dwell integral for one occurrence on one \
day (spec 4.3 / P1-11). resolvedAt Missing means still unresolved -> dayEnd is used \
as the upper bound. SourceUnavailable dwell is the caller's concern (kept separate).";

(* === R2: durable-facts shared ledger (spec 2.8 / P0-4) === *)

$SourceVaultRoutineLedgerRoot::usage =
  "$SourceVaultRoutineLedgerRoot is the directory of the append-only durable-facts \
ledger (spec 2.8: Dropbox-shared, single-writer=OwnerMachine, EventId dedup). Holds \
ManualMark/Waive/Ack/Snooze/Resolution/IdentityMapping/AutomationProvenance facts \
(content-minimized: opaque ids/enums/times only, no labels or body = I-13). Derived \
state (queue/plan/fulfillment cache/snapshot) is machine-local and regenerable, NOT \
here. Set it before use (tests point it at a temp dir).";

$SourceVaultRoutineCacheRoot::usage =
  "$SourceVaultRoutineCacheRoot is the MACHINE-LOCAL directory holding the fulfillment \
cache watermark used by the OwnerMachine handoff guard (spec 2.8). Separate per \
machine; never shared.";

$SourceVaultRoutineThisMachineTag::usage =
  "$SourceVaultRoutineThisMachineTag identifies the current machine for the ledger \
single-writer guard. Default $MachineName; overridable (tests simulate an \
OwnerMachine move by changing it).";

SourceVaultRoutineSetOwnerMachine::usage =
  "SourceVaultRoutineSetOwnerMachine[tag] records the OwnerMachine (the sole ledger \
writer) in the ledger root. Only the OwnerMachine may append durable facts.";
SourceVaultRoutineOwnerMachine::usage =
  "SourceVaultRoutineOwnerMachine[] returns the recorded OwnerMachine tag, or \
Missing[\"None\"] if unset (first writer is allowed while unset).";

SourceVaultRoutineLedgerAppend::usage =
  "SourceVaultRoutineLedgerAppend[fact, opts] appends a durable fact to the ledger \
(one JSON line). fact needs \"FactKind\" and, for occurrence-scoped facts, \
\"StableId\"/\"OccurrenceToken\". An EventId (ULID), \"At\"/\"AtAbs\" and \"By\" (this \
machine) are added. REJECTS content-bearing keys (Label/Body/Summary/Title/\
Description/Prompt/Text/Content/Note/Subject/From/To = I-13) with \
Failure[\"NBRoutineContentLeak\"]. Enforces the single-writer guard (Failure\
[\"NBRoutineNotOwnerMachine\"] when a different OwnerMachine is set). Option \
\"IdempotencyKey\" -> _ : if a prior fact carried the same key, the existing event is \
returned and nothing is appended (idempotent = AC-014). Returns the stored event.";

SourceVaultRoutineLedgerEvents::usage =
  "SourceVaultRoutineLedgerEvents[opts] returns the raw ledger events in append order. \
Option \"SinceEventId\" -> _ returns only events strictly after that EventId (for \
handoff ingest). Corrupt lines are skipped.";

SourceVaultRoutineLedgerWatermark::usage =
  "SourceVaultRoutineLedgerWatermark[] returns the last (tail) EventId in the ledger, \
or Missing[\"None\"] when empty. Monotone (ULIDs are lexically time-ordered).";

SourceVaultRoutineLedgerReplay::usage =
  "SourceVaultRoutineLedgerReplay[opts] folds the ledger into current durable state: \
per-occurrence latest fact of each kind (keyed by \"StableId|OccurrenceToken\"), plus \
identity mappings. Returns <|\"Occurrences\"-><|key-><|Mark,Waive,Ack,Snooze,\
Resolution|>...|>, \"IdentityMappings\"-><|nsKey->mapping...|>, \"Watermark\"->_|>. \
Append-only + latest-wins, so replay after an OwnerMachine move preserves all prior \
ManualMark/Waive/overdue history (AC-026).";

SourceVaultRoutineFulfillmentCacheRebuild::usage =
  "SourceVaultRoutineFulfillmentCacheRebuild[] replays the shared ledger and writes \
this machine's local cache watermark (= ledger tail). A new OwnerMachine must run \
this to ingest history before ticking. Returns a summary.";

SourceVaultRoutineTickGuard::usage =
  "SourceVaultRoutineTickGuard[] returns <|\"Ready\"->Bool, \"Reason\"->_, \
\"CacheWatermark\"->_, \"LedgerWatermark\"->_|>. Ready only when this machine's cache \
watermark equals the ledger tail: a machine that has not ingested up to the tail \
(e.g. just after an OwnerMachine handoff) is NotReady and must Rebuild first, so the \
attention tick never runs on stale/incomplete durable state (spec 2.8 / AC-026).";

(* === R2-3: source adapters -> ObligationOccurrence + freshness (spec 2.1/3.1/3.4) === *)

SourceVaultRoutineFreshness::usage =
  "SourceVaultRoutineFreshness[observedAt, now, opts] classifies a source read as \
\"Fresh\"/\"Stale\"/\"Unavailable\" by age (spec 3.4). observedAt Missing -> \
Unavailable. Options \"FreshSeconds\" (default 3600: age<=this is Fresh) and \
\"StaleSeconds\" (default 86400: age<=this is Stale, else Unavailable). \"Partial\" is \
set by the adapter (truncation/Completeness<1), not here.";

SourceVaultRoutineStaleUsePolicy::usage =
  "SourceVaultRoutineStaleUsePolicy[freshness, use] returns the per-use action for a \
given FreshnessState (spec 3.4 table). use is \"Board\"/\"ActiveReminder\"/\
\"BusyGating\"/\"Plan\". e.g. Stale+Board->\"ShowStaleLabel\", Stale+ActiveReminder->\
\"SendLowered\", Unavailable+BusyGating->\"FailOpen\", Stale/Partial+Plan->\"Freeze\".";

SourceVaultRoutineBuildOccurrence::usage =
  "SourceVaultRoutineBuildOccurrence[kind, sourceData, sourceMeta] normalizes one \
source record into an ObligationOccurrence (spec 2.1): Identity (via \
SourceVaultRoutineIdentity), Revision, Kind, Source (ObservedAtUTC/FreshnessState/\
Completeness from sourceMeta), Schedule (abs-second Due/Grace/Start/End per kind), a \
default Fulfillment (State \"Unknown\") and Attention (\"Eligible\"), plus Effort/\
Movable/DependsOn/Importance/ParentRef. kind is one of the SourceVaultRoutineIdentity \
kinds. Times accept DateObject or absolute seconds. Pure; merge ledger facts with \
SourceVaultRoutineApplyDurable.";

SourceVaultRoutineApplyDurable::usage =
  "SourceVaultRoutineApplyDurable[occurrence, replayState] overlays the durable ledger \
facts (from SourceVaultRoutineLedgerReplay) for this occurrence's key onto its \
Fulfillment and Attention (spec 2.8). Precedence for Fulfillment: Waive > Resolution \
> ManualMark; Attention: an unexpired Snooze sets Snoozed(+NextEligibleAtUTC), else \
Ack sets Acknowledged. WasOverdue is OR-preserved (never cleared, AC-025). Pure.";

Begin["`Private`"];

(* ---- time helpers (absolute seconds, TZ-independent) ---- *)
iSVRtnAbs[t_?NumberQ] := t;
iSVRtnAbs[t_DateObject] := Quiet@Check[AbsoluteTime[t], $Failed];
iSVRtnAbs[t_] := Quiet@Check[AbsoluteTime[t], $Failed];
iSVRtnNumQ[t_] := NumberQ[t] || DateObjectQ[t];

iSVRtnTimeToken[d_] := Module[{a = iSVRtnAbs[d]},
  If[NumberQ[a], "@" <> IntegerString[Round[a]], "none"]];

iSVRtnDigest[s_String] := StringTake[
  IntegerString[Hash[s, "SHA256"], 36] <> "0000000000000000", 16];
iSVRtnDigest[s_] := iSVRtnDigest[ToString[s]];

(* ---- identity (spec 2.2) ---- *)
SourceVaultRoutineIdentity[kind_String, data_Association] := Module[{ns, sid, tok},
  Switch[kind,
    "CalendarEvent",
      ns = "Calendar";
      sid = "cal:" <> ToString[Lookup[data, "EventId", "unknown"]];
      tok = iSVRtnTimeToken[Lookup[data, "OriginalStart", Missing["None"]]],
    "Routine",
      ns = "Routine";
      sid = "rtn:" <> ToString[Lookup[data, "RoutineId", "unknown"]];
      tok = iSVRtnTimeToken[Lookup[data, "WindowStartUTC", Missing["None"]]],
    "Commitment",
      ns = "Commitment";
      sid = "cmt:" <> ToString[Lookup[data, "CommitmentId", "unknown"]];
      tok = ToString[Lookup[data, "CommitmentOccurrenceId", "0"]],
    "OnWorkTask",
      ns = "OnWork";
      sid = "nb:" <> ToString[Lookup[data, "TaskId", "unknown"]];
      tok = "cyc:" <> ToString[Lookup[data, "ReviewCycleOrdinal", 0]],
    "PrepTask",
      ns = "Prep";
      sid = "prep:" <> iSVRtnDigest[
        ToString[Lookup[data, "ParentStableId", ""]] <> ":" <>
        ToString[Lookup[data, "StepId", ""]]];
      tok = ToString[Lookup[data, "ParentOccurrenceToken", "0"]],
    _, Return[Failure["NBRoutineUnknownKind",
      <|"MessageTemplate" -> "Unknown obligation kind.", "Kind" -> kind|>]]];
  <|"Namespace" -> ns, "StableId" -> sid, "OccurrenceToken" -> tok|>];
SourceVaultRoutineIdentity[___] :=
  Failure["NBRoutineBadIdentity", <|"MessageTemplate" -> "Bad identity arguments."|>];

SourceVaultRoutineKeyString[id_Association] := Which[
  KeyExistsQ[id, "StableId"] && KeyExistsQ[id, "OccurrenceToken"],
    ToString[id["StableId"]] <> "|" <> ToString[id["OccurrenceToken"]],
  KeyExistsQ[id, "Identity"] && AssociationQ[id["Identity"]],
    SourceVaultRoutineKeyString[id["Identity"]],
  True, Failure["NBRoutineBadIdentity",
    <|"MessageTemplate" -> "Association lacks StableId/OccurrenceToken."|>]];

(* ---- 3-valued (Kleene) evidence logic (spec 2.6) ---- *)
$svRtnQualityRank = <|"AttemptObserved" -> 1, "ExecutionSucceeded" -> 2,
  "OutcomeSatisfied" -> 3|>;
$svRtnRankQuality = <|1 -> "AttemptObserved", 2 -> "ExecutionSucceeded",
  3 -> "OutcomeSatisfied"|>;
SourceVaultRoutineQualityRank[q_] := Lookup[$svRtnQualityRank, q, 0];

$svRtnFreshRank = <|"Fresh" -> 4, "Stale" -> 3, "Partial" -> 2, "Unavailable" -> 1|>;
iSVRtnFreshRank[f_] := Lookup[$svRtnFreshRank, f, 4];
iSVRtnWorstFresh[fs_List] := If[fs === {}, "Fresh",
  Lookup[<|4 -> "Fresh", 3 -> "Stale", 2 -> "Partial", 1 -> "Unavailable"|>,
    Min[iSVRtnFreshRank /@ fs], "Fresh"]];

iSVRtnTruthQ[t_] := MatchQ[t, True | False] || t === "Unknown";
SourceVaultRoutineTriple[truth_, quality_ : Missing["None"], freshness_ : "Fresh"] :=
  <|"Truth" -> If[iSVRtnTruthQ[truth], truth, "Unknown"],
    "Quality" -> If[KeyExistsQ[$svRtnQualityRank, quality], quality, Missing["None"]],
    "Freshness" -> If[KeyExistsQ[$svRtnFreshRank, freshness], freshness, "Fresh"]|>;

iSVRtnNormTriple[t_Association] := SourceVaultRoutineTriple[
  Lookup[t, "Truth", "Unknown"], Lookup[t, "Quality", Missing["None"]],
  Lookup[t, "Freshness", "Fresh"]];
iSVRtnNormTriple[_] := SourceVaultRoutineTriple["Unknown"];

SourceVaultRoutineKleeneNot[t_Association] := Module[{tt = iSVRtnNormTriple[t]},
  <|"Truth" -> Switch[tt["Truth"], True, False, False, True, _, "Unknown"],
    "Quality" -> Missing["None"], "Freshness" -> tt["Freshness"]|>];

SourceVaultRoutineKleeneAllOf[ts_List] := Module[
  {tt = iSVRtnNormTriple /@ ts, fresh},
  fresh = iSVRtnWorstFresh[#["Freshness"] & /@ tt];
  Which[
    tt === {}, <|"Truth" -> True, "Quality" -> Missing["None"], "Freshness" -> "Fresh"|>,
    AnyTrue[tt, #["Truth"] === False &],
      <|"Truth" -> False, "Quality" -> Missing["None"], "Freshness" -> fresh|>,
    AnyTrue[tt, #["Truth"] === "Unknown" &],
      <|"Truth" -> "Unknown", "Quality" -> Missing["None"], "Freshness" -> fresh|>,
    True,
      <|"Truth" -> True,
        "Quality" -> Lookup[$svRtnRankQuality,
          Min[SourceVaultRoutineQualityRank[#["Quality"]] & /@ tt], Missing["None"]],
        "Freshness" -> fresh|>]];
SourceVaultRoutineKleeneAllOf[___] := SourceVaultRoutineTriple["Unknown"];

SourceVaultRoutineKleeneAnyOf[ts_List] := Module[
  {tt = iSVRtnNormTriple /@ ts, fresh, trues},
  fresh = iSVRtnWorstFresh[#["Freshness"] & /@ tt];
  Which[
    tt === {}, <|"Truth" -> False, "Quality" -> Missing["None"], "Freshness" -> "Fresh"|>,
    AnyTrue[tt, #["Truth"] === True &],
      (trues = Select[tt, #["Truth"] === True &];
       <|"Truth" -> True,
         "Quality" -> Lookup[$svRtnRankQuality,
           Max[SourceVaultRoutineQualityRank[#["Quality"]] & /@ trues], Missing["None"]],
         "Freshness" -> iSVRtnWorstFresh[#["Freshness"] & /@ trues]|>),
    AnyTrue[tt, #["Truth"] === "Unknown" &],
      <|"Truth" -> "Unknown", "Quality" -> Missing["None"], "Freshness" -> fresh|>,
    True, <|"Truth" -> False, "Quality" -> Missing["None"], "Freshness" -> fresh|>]];
SourceVaultRoutineKleeneAnyOf[___] := SourceVaultRoutineTriple["Unknown"];

SourceVaultRoutineEvaluateEvidence[spec_Association, atomFn_] := Which[
  KeyExistsQ[spec, "AllOf"],
    SourceVaultRoutineKleeneAllOf[
      SourceVaultRoutineEvaluateEvidence[#, atomFn] & /@ spec["AllOf"]],
  KeyExistsQ[spec, "AnyOf"],
    SourceVaultRoutineKleeneAnyOf[
      SourceVaultRoutineEvaluateEvidence[#, atomFn] & /@ spec["AnyOf"]],
  KeyExistsQ[spec, "Not"],
    SourceVaultRoutineKleeneNot[
      SourceVaultRoutineEvaluateEvidence[spec["Not"], atomFn]],
  KeyExistsQ[spec, "Atom"],
    iSVRtnNormTriple[Quiet@Check[atomFn[spec], SourceVaultRoutineTriple["Unknown"]]],
  True, SourceVaultRoutineTriple["Unknown"]];
SourceVaultRoutineEvaluateEvidence[_, _] := SourceVaultRoutineTriple["Unknown"];

SourceVaultRoutineFulfillmentReached[t_Association, minQuality_] :=
  With[{tt = iSVRtnNormTriple[t]},
    tt["Truth"] === True &&
      SourceVaultRoutineQualityRank[tt["Quality"]] >=
        SourceVaultRoutineQualityRank[minQuality]];
SourceVaultRoutineFulfillmentReached[___] := False;

(* ---- temporal state (spec 2.1/5.1) ---- *)
Options[SourceVaultRoutineTemporalState] = {"SoonWindow" -> 86400};
SourceVaultRoutineTemporalState[sched_Association, now_, OptionsPattern[]] := Module[
  {due = iSVRtnAbs[Lookup[sched, "DueAtUTC", Missing["None"]]],
   grace, n = iSVRtnAbs[now], sw = OptionValue["SoonWindow"]},
  grace = iSVRtnAbs[Lookup[sched, "GraceUntilUTC", Lookup[sched, "DueAtUTC", Missing["None"]]]];
  If[!NumberQ[grace], grace = due];
  Which[
    !NumberQ[due] || !NumberQ[n], "Unknown",
    n >= grace, "Overdue",
    n >= due - sw, "DueSoon",
    True, "Upcoming"]];

(* ---- Resolution state machine (spec 2.4) ---- *)
(* window of an occurrence: (WindowStart, GraceUntil]. WindowStart defaults to the
   previous occurrence's Due, else Due itself (a point occurrence). *)
iSVRtnOccWindow[occs_List] := Module[{sorted, n},
  sorted = SortBy[occs, iSVRtnAbs[Lookup[#, "DueAtUTC", 0]] &];
  n = Length[sorted];
  Table[Module[{o = sorted[[i]], due, grace, ws},
    due = iSVRtnAbs[Lookup[o, "DueAtUTC", Missing["None"]]];
    grace = iSVRtnAbs[Lookup[o, "GraceUntilUTC", due]];
    If[!NumberQ[grace], grace = due];
    ws = Which[
      NumberQ[iSVRtnAbs[Lookup[o, "WindowStartUTC", Missing[]]]],
        iSVRtnAbs[o["WindowStartUTC"]],
      i > 1, iSVRtnAbs[sorted[[i - 1]]["DueAtUTC"]],
      True, -Infinity];   (* first occurrence, no explicit start: any evidence up to grace *)
    <|"Occ" -> o, "Due" -> due, "Grace" -> grace, "WinStart" -> ws|>], {i, n}]];

SourceVaultRoutineResolveSeries[occs_List, evidence_List, now_, mode_String] := Module[
  {win, evs, nowAbs = iSVRtnAbs[now], latest, consumed = {}, out = {}},
  win = iSVRtnOccWindow[occs];
  evs = SortBy[
    Select[<|"At" -> iSVRtnAbs[Lookup[#, "AtUTC", Missing[]]],
        "Q" -> Lookup[#, "Quality", "AttemptObserved"]|> & /@ evidence,
      NumberQ[#["At"]] &], #["At"] &];
  latest = If[evs === {}, Missing["None"], Last[evs]["At"]];
  (* process in due order; each evidence is consumed by the EARLIEST occurrence whose
     (WinStart, Grace] window it falls in, so it is never double-counted (bug fix). *)
  Do[Module[
    {w = win[[i]], due, grace, ws, avail, ownIx, r},
    due = w["Due"]; grace = w["Grace"]; ws = w["WinStart"];
    avail = Select[Range[Length[evs]],
      !MemberQ[consumed, #] && ws < evs[[#]]["At"] <= grace &];
    ownIx = If[avail === {}, Missing["None"], First[avail]];
    If[!MissingQ[ownIx], AppendTo[consumed, ownIx]];
    r = Which[
      (* own-window evidence: satisfied *)
      !MissingQ[ownIx],
        With[{e = evs[[ownIx]]},
          <|"State" -> "Satisfied",
            "Resolution" -> If[e["At"] <= due, "SatisfiedOnTime", "SatisfiedLate"],
            "WasOverdue" -> (NumberQ[due] && e["At"] > due),
            "FirstOverdueAtUTC" -> If[NumberQ[due] && e["At"] > due, grace, Missing["None"]],
            "EvidenceAtUTC" -> e["At"], "EvidenceQuality" -> e["Q"]|>],
      (* LatestState catch-up: a later check after this occ's grace restores coverage *)
      mode === "LatestState" && NumberQ[latest] && NumberQ[grace] && latest > grace,
        <|"State" -> "Satisfied", "Resolution" -> "SupersededByCatchUp",
          "WasOverdue" -> True, "FirstOverdueAtUTC" -> grace,
          "EvidenceAtUTC" -> latest, "EvidenceQuality" -> Missing["None"]|>,
      (* grace passed, no evidence -> Missed *)
      NumberQ[grace] && nowAbs > grace,
        <|"State" -> "Unfulfilled", "Resolution" -> "Missed",
          "WasOverdue" -> True, "FirstOverdueAtUTC" -> grace,
          "EvidenceAtUTC" -> Missing["None"], "EvidenceQuality" -> Missing["None"]|>,
      (* still open *)
      True,
        <|"State" -> "Unknown", "Resolution" -> Missing["None"],
          "WasOverdue" -> False, "FirstOverdueAtUTC" -> Missing["None"],
          "EvidenceAtUTC" -> Missing["None"], "EvidenceQuality" -> Missing["None"]|>];
    AppendTo[out,
      Join[<|"OccurrenceToken" -> Lookup[w["Occ"], "OccurrenceToken", Missing["None"]],
        "DueAtUTC" -> due, "GraceUntilUTC" -> grace|>, r]]],
    {i, Length[win]}];
  out];
SourceVaultRoutineResolveSeries[___] := {};

(* ---- long-period due generation (spec 4.1 / AC-032) ---- *)
$svRtnFreqSeconds = <|"Daily" -> 86400., "Weekly" -> 604800.,
  "Monthly" -> 2629746., "Yearly" -> 31556952.|>;
iSVRtnAddPeriods[freq_, anchor_DateObject, n_Integer, k_Integer] := Switch[freq,
  "Daily", DatePlus[anchor, {n*k, "Day"}],
  "Weekly", DatePlus[anchor, {n*k, "Week"}],
  "Monthly", DatePlus[anchor, {n*k, "Month"}],
  "Yearly", DatePlus[anchor, {n*k, "Year"}],
  _, $Failed];

iSVRtnNextCalendar[freq_, anchorAbs_, k_, fromAbs_] := Module[
  {anchor = DateObject[FromAbsoluteTime[anchorAbs], TimeZone -> 0],
   est, n, cand, guard = 0},
  est = Max[0, Floor[(fromAbs - anchorAbs)/($svRtnFreqSeconds[freq]*k)] - 2];
  n = est;
  (* small bounded forward search from a close estimate: never a 1e5-step scan *)
  While[guard++ < 64,
    cand = iSVRtnAddPeriods[freq, anchor, n, k];
    If[cand === $Failed, Return[Missing["None"]]];
    If[AbsoluteTime[cand] > fromAbs + 0.5, Return[AbsoluteTime[cand]]];
    n++];
  Missing["None"]];

Options[SourceVaultRoutineNextDue] = {"GraceSeconds" -> Automatic, "NextFireFn" -> Missing["None"]};
SourceVaultRoutineNextDue[cadence_Association, from_, OptionsPattern[]] := Module[
  {kind = Lookup[cadence, "Kind", ""], fromAbs = iSVRtnAbs[from], due, grace, k, anchorAbs,
   graceSec, nff = OptionValue["NextFireFn"]},
  graceSec = With[{g = OptionValue["GraceSeconds"]},
    Which[NumberQ[g], g, NumberQ[Lookup[cadence, "GraceSeconds", Missing[]]],
      cadence["GraceSeconds"], True, 0]];
  If[!NumberQ[fromAbs],
    Return[Failure["NBRoutineBadFrom", <|"MessageTemplate" -> "Bad `from` time."|>]]];
  due = Which[
    kind === "Interval",
      Module[{iv = Lookup[cadence, "IntervalSeconds", Missing[]],
          an = iSVRtnAbs[Lookup[cadence, "Anchor", Missing[]]]},
        If[!NumberQ[iv] || iv <= 0 || !NumberQ[an], Missing["None"],
          an + Ceiling[(fromAbs - an)/iv + 10^-9]*iv]],
    MemberQ[{"Daily", "Weekly", "Monthly", "Yearly"}, kind],
      (anchorAbs = iSVRtnAbs[Lookup[cadence, "Anchor", Missing[]]];
       k = Max[1, Round[Lookup[cadence, "Interval", 1]]];
       If[!NumberQ[anchorAbs], Missing["None"],
         iSVRtnNextCalendar[kind, anchorAbs, k, fromAbs]]),
    (nff =!= Missing["None"] && (Head[nff] === Function || Head[nff] === Symbol)),
      With[{r = Quiet@Check[nff[cadence, fromAbs], Missing["None"]]},
        If[NumberQ[iSVRtnAbs[r]], iSVRtnAbs[r], Missing["None"]]],
    True, Missing["None"]];
  If[!NumberQ[due],
    Return[Failure["NBRoutineNoNextDue",
      <|"MessageTemplate" -> "Could not compute next due for this cadence.",
        "Kind" -> kind|>]]];
  grace = due + graceSec;
  <|"DueAtUTC" -> due, "GraceUntilUTC" -> grace, "Capped" -> False|>];
SourceVaultRoutineNextDue[___] :=
  Failure["NBRoutineBadCadence", <|"MessageTemplate" -> "Bad cadence arguments."|>];

(* ---- overdue integral (spec 4.3 / P1-11) ---- *)
SourceVaultRoutineOverdueSeconds[graceUntil_, resolvedAt_, dayStart_, dayEnd_] := Module[
  {g = iSVRtnAbs[graceUntil], ds = iSVRtnAbs[dayStart], de = iSVRtnAbs[dayEnd],
   ra = iSVRtnAbs[resolvedAt], hi, lo},
  If[!NumberQ[g] || !NumberQ[ds] || !NumberQ[de], Return[0.]];
  lo = Max[g, ds];
  hi = Min[If[NumberQ[ra], ra, de], de];
  N[Max[0, hi - lo]]];
SourceVaultRoutineOverdueSeconds[___] := 0.;

(* ============================================================
   R2: durable-facts shared ledger (spec 2.8 / P0-4).
   Append-only JSONL, ULID EventId dedup, single-writer OwnerMachine,
   content-minimized facts, machine-local cache watermark for handoff.
   ============================================================ *)

If[!StringQ[SourceVault`$SourceVaultRoutineThisMachineTag],
  SourceVault`$SourceVaultRoutineThisMachineTag =
    Quiet@Check[$MachineName, "unknown-machine"]];

iSVRtnThisMachine[] := With[{t = SourceVault`$SourceVaultRoutineThisMachineTag},
  If[StringQ[t] && t =!= "", t, "unknown-machine"]];

(* --- ULID (lexically time-ordered) --- *)
$svRtnCrock = Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"];
iSVRtnCrock[n_Integer, len_Integer] := StringJoin@Module[{d = {}, x = n},
  Do[PrependTo[d, $svRtnCrock[[Mod[x, 32] + 1]]]; x = Quotient[x, 32], {len}]; d];
iSVRtnULID[] := Module[
  {ms = Round[(AbsoluteTime[] - AbsoluteTime[{1970, 1, 1, 0, 0, 0}, TimeZone -> 0])*1000],
   rnd = FromDigits[StringTake[StringDelete[CreateUUID[], "-"], 20], 16]},
  iSVRtnCrock[ms, 10] <> iSVRtnCrock[Mod[rnd, 32^16], 16]];

iSVRtnNowIso[] := DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z";

(* --- ledger root / paths --- *)
iSVRtnLedgerRootQ[] := StringQ[SourceVault`$SourceVaultRoutineLedgerRoot] &&
  SourceVault`$SourceVaultRoutineLedgerRoot =!= "";
iSVRtnEnsureDir[dir_] := If[!DirectoryQ[dir],
  Quiet@Check[CreateDirectory[dir, CreateIntermediateDirectories -> True], $Failed], dir];
iSVRtnLedgerFile[] := FileNameJoin[{SourceVault`$SourceVaultRoutineLedgerRoot, "facts.jsonl"}];
iSVRtnOwnerFile[] := FileNameJoin[{SourceVault`$SourceVaultRoutineLedgerRoot, "owner.json"}];
iSVRtnCacheRoot[] := If[StringQ[SourceVault`$SourceVaultRoutineCacheRoot] &&
    SourceVault`$SourceVaultRoutineCacheRoot =!= "",
  SourceVault`$SourceVaultRoutineCacheRoot,
  FileNameJoin[{SourceVault`$SourceVaultRoutineLedgerRoot, "_cache_" <> iSVRtnThisMachine[]}]];
iSVRtnCacheFile[] := FileNameJoin[{iSVRtnCacheRoot[], "watermark.json"}];

(* --- JSONL append / read (single UTF-8 encoding; no double-encode) --- *)
iSVRtnAppendLine[file_, assoc_] := Module[{json},
  json = StringReplace[
    Quiet@Check[Developer`WriteRawJSONString[assoc, "Compact" -> True],
      Developer`WriteRawJSONString[assoc]], {"\n" -> " ", "\r" -> " "}];
  iSVRtnEnsureDir[DirectoryName[file]];
  Module[{s = OpenAppend[file, BinaryFormat -> True]},
    BinaryWrite[s, StringToByteArray[json <> "\n", "UTF-8"]]; Close[s]];
  assoc];
iSVRtnReadEvents[file_] := If[!FileExistsQ[file], {},
  Module[{lines},
    lines = Select[StringSplit[
      Quiet@Check[ByteArrayToString[ReadByteArray[file], "UTF-8"], ""], "\n"],
      StringLength[StringTrim[#]] > 0 &];
    Select[Map[Function[ln,
      Quiet@Check[Developer`ReadRawJSONString[ln], $Failed]], lines], AssociationQ]]];

(* --- owner machine (single-writer) --- *)
SourceVault`SourceVaultRoutineSetOwnerMachine[tag_String] := Module[{},
  If[!iSVRtnLedgerRootQ[],
    Return[Failure["NBRoutineNoLedgerRoot",
      <|"MessageTemplate" -> "$SourceVaultRoutineLedgerRoot is not set."|>]]];
  iSVRtnEnsureDir[SourceVault`$SourceVaultRoutineLedgerRoot];
  Export[iSVRtnOwnerFile[],
    Developer`WriteRawJSONString[<|"OwnerMachineTag" -> tag, "At" -> iSVRtnNowIso[]|>],
    "Text"];
  <|"Status" -> "OK", "OwnerMachineTag" -> tag|>];
SourceVault`SourceVaultRoutineSetOwnerMachine[___] :=
  Failure["NBRoutineBadArgs", <|"MessageTemplate" -> "tag must be a string."|>];

SourceVault`SourceVaultRoutineOwnerMachine[] := Module[{f, j},
  If[!iSVRtnLedgerRootQ[], Return[Missing["None"]]];
  f = iSVRtnOwnerFile[];
  If[!FileExistsQ[f], Return[Missing["None"]]];
  j = Quiet@Check[Developer`ReadRawJSONString[Import[f, "Text"]], $Failed];
  If[AssociationQ[j] && StringQ[Lookup[j, "OwnerMachineTag", Missing[]]],
    j["OwnerMachineTag"], Missing["None"]]];

$svRtnContentDenylist = {"Label", "Body", "Summary", "Title", "Description",
  "Prompt", "Text", "Content", "Note", "Subject", "From", "To", "Name"};

(* --- append a durable fact --- *)
Options[SourceVault`SourceVaultRoutineLedgerAppend] = {"IdempotencyKey" -> Missing["None"]};
SourceVault`SourceVaultRoutineLedgerAppend[fact_Association, OptionsPattern[]] := Module[
  {owner, this = iSVRtnThisMachine[], leak, idem = OptionValue["IdempotencyKey"],
   existing, ev},
  If[!iSVRtnLedgerRootQ[],
    Return[Failure["NBRoutineNoLedgerRoot",
      <|"MessageTemplate" -> "$SourceVaultRoutineLedgerRoot is not set."|>]]];
  If[!StringQ[Lookup[fact, "FactKind", Missing[]]],
    Return[Failure["NBRoutineNoFactKind",
      <|"MessageTemplate" -> "fact needs a string FactKind."|>]]];
  (* I-13 content-minimization guard *)
  leak = Intersection[Keys[fact], $svRtnContentDenylist];
  If[leak =!= {},
    Return[Failure["NBRoutineContentLeak",
      <|"MessageTemplate" -> "Fact carries content-bearing keys (I-13).",
        "Keys" -> leak|>]]];
  (* single-writer guard *)
  owner = SourceVault`SourceVaultRoutineOwnerMachine[];
  If[StringQ[owner] && owner =!= this,
    Return[Failure["NBRoutineNotOwnerMachine",
      <|"MessageTemplate" -> "Only the OwnerMachine may append.",
        "OwnerMachineTag" -> owner, "ThisMachine" -> this|>]]];
  (* idempotency *)
  If[StringQ[idem],
    existing = SelectFirst[iSVRtnReadEvents[iSVRtnLedgerFile[]],
      Lookup[#, "IdempotencyKey", Missing[]] === idem &, Missing["None"]];
    If[AssociationQ[existing], Return[existing]]];
  ev = Join[<|"EventId" -> iSVRtnULID[], "At" -> iSVRtnNowIso[],
      "AtAbs" -> N[AbsoluteTime[]], "By" -> this|>,
    fact,
    If[StringQ[idem], <|"IdempotencyKey" -> idem|>, <||>]];
  iSVRtnAppendLine[iSVRtnLedgerFile[], ev];
  ev];
SourceVault`SourceVaultRoutineLedgerAppend[___] :=
  Failure["NBRoutineBadArgs", <|"MessageTemplate" -> "fact must be an Association."|>];

(* --- read / watermark --- *)
Options[SourceVault`SourceVaultRoutineLedgerEvents] = {"SinceEventId" -> Missing["None"]};
SourceVault`SourceVaultRoutineLedgerEvents[OptionsPattern[]] := Module[
  {evs, since = OptionValue["SinceEventId"]},
  If[!iSVRtnLedgerRootQ[], Return[{}]];
  evs = iSVRtnReadEvents[iSVRtnLedgerFile[]];
  If[StringQ[since],
    evs = Select[evs, StringQ[Lookup[#, "EventId", Missing[]]] &&
      OrderedQ[{since, #["EventId"]}] && #["EventId"] =!= since &]];
  evs];

SourceVault`SourceVaultRoutineLedgerWatermark[] := Module[{evs},
  If[!iSVRtnLedgerRootQ[], Return[Missing["None"]]];
  evs = iSVRtnReadEvents[iSVRtnLedgerFile[]];
  If[evs === {}, Missing["None"], Lookup[Last[evs], "EventId", Missing["None"]]]];

(* --- replay to current durable state --- *)
$svRtnOccFactKinds = <|"ManualMark" -> "Mark", "Waive" -> "Waive", "Ack" -> "Ack",
  "Snooze" -> "Snooze", "Resolution" -> "Resolution"|>;
SourceVault`SourceVaultRoutineLedgerReplay[OptionsPattern[]] := Module[
  {evs, occ = <||>, idmap = <||>, key, slot},
  If[!iSVRtnLedgerRootQ[], Return[<|"Occurrences" -> <||>,
    "IdentityMappings" -> <||>, "Watermark" -> Missing["None"]|>]];
  evs = iSVRtnReadEvents[iSVRtnLedgerFile[]];
  Do[Module[{fk = Lookup[e, "FactKind", ""]},
    Which[
      KeyExistsQ[$svRtnOccFactKinds, fk],
        key = ToString[Lookup[e, "StableId", "?"]] <> "|" <>
          ToString[Lookup[e, "OccurrenceToken", "?"]];
        slot = $svRtnOccFactKinds[fk];
        occ = Append[occ, key -> Append[Lookup[occ, key, <||>], slot -> e]],
      fk === "IdentityMapping",
        key = ToString[Lookup[e, "Namespace", "?"]] <> "|" <>
          ToString[Lookup[e, "SourceKey", "?"]];
        idmap = Append[idmap, key -> e]]],
    {e, evs}];
  <|"Occurrences" -> occ, "IdentityMappings" -> idmap,
    "Watermark" -> If[evs === {}, Missing["None"],
      Lookup[Last[evs], "EventId", Missing["None"]]]|>];

(* --- machine-local cache watermark + handoff tick guard --- *)
SourceVault`SourceVaultRoutineFulfillmentCacheRebuild[] := Module[{wm, cf},
  If[!iSVRtnLedgerRootQ[],
    Return[Failure["NBRoutineNoLedgerRoot",
      <|"MessageTemplate" -> "$SourceVaultRoutineLedgerRoot is not set."|>]]];
  wm = SourceVault`SourceVaultRoutineLedgerWatermark[];
  cf = iSVRtnCacheFile[];
  iSVRtnEnsureDir[DirectoryName[cf]];
  Export[cf, Developer`WriteRawJSONString[<|
    "CacheWatermark" -> If[MissingQ[wm], Null, wm],
    "RebuiltAt" -> iSVRtnNowIso[], "Machine" -> iSVRtnThisMachine[]|>], "Text"];
  <|"Status" -> "OK", "CacheWatermark" -> wm|>];

iSVRtnCacheWatermark[] := Module[{cf, j},
  cf = iSVRtnCacheFile[];
  If[!FileExistsQ[cf], Return[Missing["None"]]];
  j = Quiet@Check[Developer`ReadRawJSONString[Import[cf, "Text"]], $Failed];
  If[AssociationQ[j],
    With[{w = Lookup[j, "CacheWatermark", Null]},
      If[StringQ[w], w, Missing["None"]]], Missing["None"]]];

SourceVault`SourceVaultRoutineTickGuard[] := Module[{cw, lw, ready, reason},
  If[!iSVRtnLedgerRootQ[],
    Return[<|"Ready" -> False, "Reason" -> "NoLedgerRoot",
      "CacheWatermark" -> Missing["None"], "LedgerWatermark" -> Missing["None"]|>]];
  cw = iSVRtnCacheWatermark[];
  lw = SourceVault`SourceVaultRoutineLedgerWatermark[];
  ready = Which[
    MissingQ[lw], True,               (* empty ledger: nothing to ingest *)
    MissingQ[cw], False,              (* never rebuilt on this machine *)
    True, cw === lw];                 (* caught up to tail *)
  reason = Which[
    ready && MissingQ[lw], "EmptyLedger",
    ready, "CaughtUp",
    MissingQ[cw], "NeverIngested",
    True, "BehindTail"];
  <|"Ready" -> ready, "Reason" -> reason,
    "CacheWatermark" -> cw, "LedgerWatermark" -> lw|>];

(* ============================================================
   R2-3: source adapters -> ObligationOccurrence + freshness (spec 2.1/3.1/3.4).
   Pure normalization + durable-fact overlay. IO-free.
   ============================================================ *)

Options[SourceVault`SourceVaultRoutineFreshness] = {
  "FreshSeconds" -> 3600, "StaleSeconds" -> 86400};
SourceVault`SourceVaultRoutineFreshness[observedAt_, now_, OptionsPattern[]] := Module[
  {oa = iSVRtnAbs[observedAt], n = iSVRtnAbs[now], age,
   fs = OptionValue["FreshSeconds"], ss = OptionValue["StaleSeconds"]},
  If[!NumberQ[oa] || !NumberQ[n], Return["Unavailable"]];
  age = n - oa;
  Which[age <= fs, "Fresh", age <= ss, "Stale", True, "Unavailable"]];

$svRtnStalePolicy = <|
  "Board" -> <|"Fresh" -> "Show", "Stale" -> "ShowStaleLabel",
    "Partial" -> "ShowStaleLabel", "Unavailable" -> "ShowUnavailable"|>,
  "ActiveReminder" -> <|"Fresh" -> "Send", "Stale" -> "SendLowered",
    "Partial" -> "SendLowered", "Unavailable" -> "Suppress"|>,
  "BusyGating" -> <|"Fresh" -> "Use", "Stale" -> "Use",
    "Partial" -> "Use", "Unavailable" -> "FailOpen"|>,
  "Plan" -> <|"Fresh" -> "Normal", "Stale" -> "Freeze",
    "Partial" -> "Freeze", "Unavailable" -> "Freeze"|>|>;
SourceVault`SourceVaultRoutineStaleUsePolicy[fresh_String, use_String] :=
  Lookup[Lookup[$svRtnStalePolicy, use, <||>], fresh, "Unknown"];
SourceVault`SourceVaultRoutineStaleUsePolicy[___] := "Unknown";

(* per-kind schedule (abs seconds) *)
iSVRtnScheduleFor[kind_, d_] := Module[
  {start = iSVRtnAbs[Lookup[d, "Start", Missing["None"]]],
   end = iSVRtnAbs[Lookup[d, "End", Missing["None"]]],
   due = iSVRtnAbs[Lookup[d, "DueAtUTC", Lookup[d, "Due",
     Lookup[d, "Deadline", Missing["None"]]]]],
   grace = iSVRtnAbs[Lookup[d, "GraceUntilUTC", Missing["None"]]],
   tz = Lookup[d, "TimeZone", "Asia/Tokyo"], allday = TrueQ[Lookup[d, "AllDay", False]]},
  Switch[kind,
    "CalendarEvent",
      <|"StartUTC" -> start, "EndUTC" -> end,
        "DueAtUTC" -> start, "GraceUntilUTC" -> If[NumberQ[end], end, start],
        "TimeZone" -> tz, "AllDay" -> allday|>,
    _,
      <|"StartUTC" -> Missing["None"], "EndUTC" -> Missing["None"],
        "DueAtUTC" -> due, "GraceUntilUTC" -> If[NumberQ[grace], grace, due],
        "TimeZone" -> tz, "AllDay" -> allday|>]];

iSVRtnDefaultMode[kind_] := Switch[kind,
  "CalendarEvent", "AnyWithinWindow", "Routine", "LatestState", _, "EachOccurrence"];

iSVRtnImportance[kind_, d_] := Which[
  kind === "CalendarEvent" && TrueQ[Lookup[d, "Mandatory", False]], "Mandatory",
  StringQ[Lookup[d, "Importance", Missing[]]], d["Importance"],
  True, "Normal"];

SourceVault`SourceVaultRoutineBuildOccurrence[kind_String, d_Association,
    srcMeta_Association : <||>] := Module[
  {identity, mode = iSVRtnDefaultMode[kind]},
  identity = SourceVault`SourceVaultRoutineIdentity[kind, d];
  If[MatchQ[identity, _Failure], Return[identity]];
  <|"Type" -> "ObligationOccurrence", "SchemaVersion" -> "0.4",
    "Identity" -> identity,
    "Revision" -> <|
      "SemanticDigest" -> Lookup[d, "SemanticDigest", Missing["None"]],
      "ObservedRevision" -> Lookup[d, "ObservedRevision", Missing["None"]]|>,
    "Kind" -> kind,
    "Source" -> <|
      "ObservedAtUTC" -> Lookup[srcMeta, "ObservedAtUTC", Missing["None"]],
      "FreshnessState" -> Lookup[srcMeta, "FreshnessState", "Fresh"],
      "Completeness" -> Lookup[srcMeta, "Completeness", 1.0]|>,
    "Schedule" -> iSVRtnScheduleFor[kind, d],
    "Fulfillment" -> <|"Mode" -> mode, "State" -> "Unknown",
      "Resolution" -> Missing["None"], "WasOverdue" -> False,
      "FirstOverdueAtUTC" -> Missing["None"], "EvidenceQuality" -> Missing["None"],
      "EvidenceAtUTC" -> Missing["None"]|>,
    "Attention" -> <|"EpisodeId" -> Missing["None"], "State" -> "Eligible",
      "NextEligibleAtUTC" -> Missing["None"]|>,
    "Effort" -> Lookup[d, "Effort", Missing["None"]],
    "Movable" -> Lookup[d, "Movable", If[kind === "CalendarEvent", False, True]],
    "DependsOn" -> Lookup[d, "DependsOn", {}],
    "ParentRef" -> Lookup[d, "ParentRef", Missing["None"]],
    "Importance" -> iSVRtnImportance[kind, d]|>];
SourceVault`SourceVaultRoutineBuildOccurrence[___] :=
  Failure["NBRoutineBadBuild", <|"MessageTemplate" -> "Bad BuildOccurrence args."|>];

(* overlay durable ledger facts (Waive > Resolution > Mark; Snooze/Ack for attention) *)
SourceVault`SourceVaultRoutineApplyDurable[occ_Association, replay_Association] := Module[
  {key, facts, ful = occ["Fulfillment"], att = occ["Attention"], now = N[AbsoluteTime[]],
   waive, res, mark, ack, snz, wasOverdue},
  key = SourceVault`SourceVaultRoutineKeyString[occ["Identity"]];
  If[MatchQ[key, _Failure], Return[occ]];
  facts = Lookup[Lookup[replay, "Occurrences", <||>], key, <||>];
  waive = Lookup[facts, "Waive", Missing["None"]];
  res = Lookup[facts, "Resolution", Missing["None"]];
  mark = Lookup[facts, "Mark", Missing["None"]];
  ack = Lookup[facts, "Ack", Missing["None"]];
  snz = Lookup[facts, "Snooze", Missing["None"]];
  wasOverdue = TrueQ[ful["WasOverdue"]] ||
    (AssociationQ[res] && TrueQ[Lookup[res, "WasOverdue", False]]);
  ful = Which[
    AssociationQ[waive],
      Join[ful, <|"State" -> "Waived", "Resolution" -> "Waived",
        "WasOverdue" -> wasOverdue|>],
    AssociationQ[res],
      Join[ful, <|"State" -> "Satisfied",
        "Resolution" -> Lookup[res, "Resolution", ful["Resolution"]],
        "WasOverdue" -> wasOverdue,
        "FirstOverdueAtUTC" -> Lookup[res, "FirstOverdueAtUTC", ful["FirstOverdueAtUTC"]],
        "EvidenceAtUTC" -> Lookup[res, "EvidenceAtUTC", ful["EvidenceAtUTC"]],
        "EvidenceQuality" -> Lookup[res, "EvidenceQuality", ful["EvidenceQuality"]]|>],
    AssociationQ[mark],
      Join[ful, <|"State" -> Lookup[mark, "MarkState", ful["State"]],
        "WasOverdue" -> wasOverdue|>],
    True, Join[ful, <|"WasOverdue" -> wasOverdue|>]];
  att = Which[
    AssociationQ[snz] && NumberQ[iSVRtnAbs[Lookup[snz, "UntilAbs", Missing[]]]] &&
      iSVRtnAbs[snz["UntilAbs"]] > now,
      Join[att, <|"State" -> "Snoozed",
        "NextEligibleAtUTC" -> iSVRtnAbs[snz["UntilAbs"]]|>],
    AssociationQ[ack],
      Join[att, <|"State" -> "Acknowledged"|>],
    True, att];
  Join[occ, <|"Fulfillment" -> ful, "Attention" -> att|>]];
SourceVault`SourceVaultRoutineApplyDurable[occ_, _] := occ;

End[];

EndPackage[];
