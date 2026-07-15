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

(* === R3: ActionGate -- capability-class router for UI clicks (spec 7 / P0-7) === *)

SourceVaultRoutineActionClass::usage =
  "SourceVaultRoutineActionClass[kind] maps a UI action kind to its capability class \
(spec 7): \"Select\" (ShowDetail/Select/JumpTo -- effect-free), \"LocalNavigation\" \
(OpenNotebook/OpenDirectory), \"LocalMutation\" (Pin/Waive/Ack/Snooze/CreatePrepNote/\
CandidateToOpen/FalseAlarm), \"WorkflowDispatch\" (RunNow/StartReplyDraft), \
\"ExternalNavigation\" (OpenURL). Unknown kinds -> \"Unknown\".";

SourceVaultRoutineActionGate::usage =
  "SourceVaultRoutineActionGate[action, context] decides whether a UI click may \
proceed and under what conditions (spec 7 / P0-7). It performs NO side effects: it \
classifies, validates, and returns a decision the caller then acts on. action = \
<|\"Kind\", (\"Target\" path), (\"OccurrenceKey\"), (\"ExpectedSemanticDigest\"), \
(\"URL\"), (\"MutationFact\" for LocalMutation), (\"Reason\")|>. context = \
<|(\"AllowedRoots\"->{dirs}), (\"URLSchemes\"->{\"https\"}), (\"URLDomains\"->All|\
{domains}), (\"Occurrences\"-><|key->occurrence|> current snapshot), \
(\"OwnerPermit\"->Bool)|>. Rules: Select always allowed (effect-free). \
LocalNavigation requires the Target path be contained in an AllowedRoot (no \"..\", \
rejects escapes) and, when an OccurrenceKey is given, that the occurrence still \
exists in the current snapshot. WorkflowDispatch RE-VALIDATES the current \
SemanticDigest against action[\"ExpectedSemanticDigest\"] and Blocks a stale view \
(AC-028), otherwise returns Effect \"DelegateToAutoTrigger\". ExternalNavigation \
enforces a scheme allowlist (default https only) and optional domain allowlist, \
rejecting file:/custom-scheme/disallowed-domain URLs (AC-029) and always \
RequiresConfirm. LocalMutation requires OwnerPermit->True, sets RequiresPreview, and \
returns the durable \"AuditFact\" for the caller to append via the ledger. Returns \
<|\"Allowed\"->Bool, \"Class\", \"Reason\", \"RequiresConfirm\"->Bool, \
\"RequiresPreview\"->Bool, \"Effect\"->_, \"AuditFact\"->_|Missing|>.";

SourceVaultRoutineBoardData::usage =
  "SourceVaultRoutineBoardData[occurrences, now, opts] builds the Board's row data \
(spec 5.1) from a list of ObligationOccurrences (already durable-overlaid). Each row: \
<|\"Key\", \"Kind\", \"Importance\", \"Temporal\", \"FulfillmentState\", \
\"AttentionState\", \"DueAtUTC\", \"Resolution\", \"ExpectedSemanticDigest\", \
\"Actions\"->{kinds}, \"FreshnessState\"|>. Rows are filtered to what needs attention \
(Overdue/DueSoon and not Satisfied/Waived/expired-window, excluding unexpired-Snoozed) \
and sorted Mandatory/overdue first, then by DueAtUTC. Options \"IncludeResolved\"-> \
False, \"IncludeSnoozed\"->False, \"SoonWindow\"->86400. Pure; the applicable action \
kinds are gated per click by SourceVaultRoutineActionGate.";

SourceVaultRoutineBoardView::usage =
  "SourceVaultRoutineBoardView[occurrences, opts] renders the Board (FE): a Dataset of \
SourceVaultRoutineBoardData rows with an action menu per row whose buttons route \
through SourceVaultRoutineActionGate before doing anything (spec 5.1/7). Requires a \
Front End; the row data and gating are headless-tested via SourceVaultRoutineBoardData \
and SourceVaultRoutineActionGate. Options forwarded to BoardData plus \"ActionHandler\" \
(a function decision -> _ the buttons call after the gate approves; default a no-op \
that returns the decision).";

(* === R4a: AttentionContext gate + envelope + ladder + coverage (spec 5 / P0-1) === *)

SourceVaultRoutineDefaultAttentionPolicy::usage =
  "SourceVaultRoutineDefaultAttentionPolicy[] returns the default AttentionPolicy \
(spec 4.2): MeetingGate (Enabled/DeferDuringBusy/FlushAfterMeetingMinutes/\
MandatoryLeadMinutes {1440,120,15}), QuietHours (Missing), Channels defaults.";
SourceVaultRoutineSetAttentionPolicy::usage =
  "SourceVaultRoutineSetAttentionPolicy[policy, \"OwnerAuthorization\"->True] persists \
the owner-signed AttentionPolicy to the ledger root config (spec 4.2). \
OwnerAuthorization is required (LLM/external content cannot reach it). Returns status.";
SourceVaultRoutineAttentionPolicy::usage =
  "SourceVaultRoutineAttentionPolicy[] returns the persisted AttentionPolicy, or the \
default when unset/unreadable.";

SourceVaultRoutineNotificationEnvelope::usage =
  "SourceVaultRoutineNotificationEnvelope[kind, opts] builds a normalized notification \
envelope (spec 5.1 / P0-1): <|\"Kind\",\"Stage\",\"Urgency\"->\"Normal\"|\"Critical\", \
\"MeetingBypass\"->Bool, \"QuietHoursBypass\"->Bool, \"Channel\", \"OccurrenceKey\", \
\"EpisodeId\"|>. MeetingBypass and QuietHoursBypass are INDEPENDENT (a 15-minute \
mandatory reminder pierces a meeting but NOT quiet hours). Options set each field.";

SourceVaultRoutineInQuietHours::usage =
  "SourceVaultRoutineInQuietHours[policy, now] returns whether `now` falls in the \
policy's QuietHours window (StartHour..EndHour in the local time zone, wrapping past \
midnight). False when QuietHours is unset.";

SourceVaultRoutineAttentionGate::usage =
  "SourceVaultRoutineAttentionGate[envelope, context] decides \"Deliver\"/\"Defer\" for \
a notification (spec 5 / 7.2 / P0-1). context = <|\"BusyQ\"->Bool, \"InQuietHours\"-> \
Bool|>. The meeting gate and the quiet-hours gate are evaluated INDEPENDENTLY: it \
defers if (BusyQ and not MeetingBypass) OR (InQuietHours and not QuietHoursBypass). \
Returns <|\"Decision\", \"Reason\"|>. So MeetingBypass alone pierces a meeting but \
still defers in quiet hours (AC-003/AC-004).";

SourceVaultRoutineMandatoryLadderStage::usage =
  "SourceVaultRoutineMandatoryLadderStage[eventStart, now, policy] returns the current \
mandatory-reminder ladder stage for an attendance-required event (spec 5.3): the \
TIGHTEST lead-minutes window (from policy MandatoryLeadMinutes) that `now` has entered \
before the event start. Only the tightest configured stage sets MeetingBypass->True \
(and Urgency Critical); wider stages are Board/badge only. Returns <|\"Stage\"->_| \
Missing, \"LeadMinutes\", \"MeetingBypass\", \"Urgency\", \"MinutesUntil\"|>; Stage is \
Missing before any window or once the event has started.";

SourceVaultRoutineCoverageDegradedQ::usage =
  "SourceVaultRoutineCoverageDegradedQ[freshnessState] is True when a source's \
FreshnessState is Stale/Unavailable/Partial, i.e. Mandatory-reminder coverage may be \
degraded and the owner should be told once per episode (spec 3.4/5.5 / AC-008).";

(* === R4b: durable notification queue (spec 5.2/5.3 / P0-5) === *)

SourceVaultRoutineEnqueueNotification::usage =
  "SourceVaultRoutineEnqueueNotification[envelope, opts] appends a notification to the \
durable queue (machine-local, regenerable; NOT the shared ledger) in state Pending \
(spec 5.2). A stable EnvelopeId is derived from (OccurrenceKey, Kind, Stage, Channel, \
EpisodeId) so re-enqueuing the same logical notification is idempotent (hysteresis / \
AC-014): the existing record is returned. Option \"EnvelopeId\" overrides the derived \
id. Returns the queue record.";

SourceVaultRoutineQueueRecords::usage =
  "SourceVaultRoutineQueueRecords[opts] returns the durable queue records. Option \
\"State\"->All filters by state (Pending/Deferred/Claimed/Delivered/Superseded/Expired).";

SourceVaultRoutineSupersedeNotifications::usage =
  "SourceVaultRoutineSupersedeNotifications[occurrenceKey, opts] marks all not-yet-\
delivered notifications for an occurrence Superseded (spec 5.2: an occurrence moved / \
cancelled / SemanticDigest changed supersedes its pending reminders, AC-002/AC-033). \
Option \"Reason\" (default \"Superseded\"). Returns a summary.";

SourceVaultRoutineQueueTick::usage =
  "SourceVaultRoutineQueueTick[context, opts] advances the durable queue once (spec \
5.2/5.3). For each Pending/Deferred record it RE-EVALUATES SourceVaultRoutineAttentionGate \
against the CURRENT context (context = <|\"BusyQ\", \"InQuietHours\", \"Now\"|>; so a \
notification deferred during a meeting is re-checked and re-deferred while a NEXT \
meeting is still on) and either delivers it (via the injected \"ChannelFn\", recording \
a fresh DeliveryAttemptId and moving to Delivered) or leaves it Deferred. A record \
deferred past \"MaxDeferSeconds\" (default 86400) is delivered to the Board channel as \
a fallback (never lost, spec 5.2). Delivery guarantees are per channel (spec 5.3 / \
P0-5): Board/internal are effectively-once (EnvelopeId upsert), external mail/OS are \
at-least-once (a fresh DeliveryAttemptId per attempt; a crash between channel success \
and the Delivered write yields a bounded duplicate, NOT exactly-once). \"ChannelFn\" \
(envelope, attemptId) -> receipt|$Failed is the injection seam (default: Board-only \
in-record delivery). Options \"MaxDeferSeconds\", \"MaxRecords\". Returns a tick summary.";

SourceVaultRoutineQueueReset::usage =
  "SourceVaultRoutineQueueReset[] clears this machine's durable notification queue \
(regenerable derived state). Returns a status.";

(* === R7: statistical streams -> anomaly (spec 4.3) === *)

SourceVaultRoutineExecutionStreams::usage =
  "SourceVaultRoutineExecutionStreams[occurrences, opts] builds daily rate streams from \
resolved ObligationOccurrences for the anomaly workflow (spec 4.3): this is how \
\"routine not run for a while\" becomes a first-class STATE ANOMALY. Returns an \
Association of streams, each <|\"Points\"->{<|\"WindowStart\",\"WindowEnd\", \
\"EventCount\",\"ExposureCount\"|>...}|>, ready to pass as the \"Streams\" of \
SourceVaultRunCaneAnomalyWorkflow. Streams: \"RoutineExecutionRate\" (per day \
ExposureCount = occurrences due that day, EventCount = those Satisfied) and \
\"RoutineOverdueRate\" (EventCount = those overdue/missed). A stream with no data is \
OMITTED (never fabricate an empty stream, I-15). Each occurrence contributes via its \
Schedule.DueAtUTC (binned in option \"TimeZone\", default \"Asia/Tokyo\") and its \
Fulfillment State/WasOverdue. Options \"TimeZone\", \"Kinds\"->All (restrict to some \
Kind list, e.g. {\"Routine\"}). Pure; the anomaly detection/baselines/correlation are \
the existing 1H-A workflow.";

SourceVaultRoutineOverdueSecondsByDay::usage =
  "SourceVaultRoutineOverdueSecondsByDay[occurrences, opts] returns per-day total \
OverdueContractSeconds (spec 4.3 / P1-11): for each day, the sum over occurrences of \
the within-day overdue dwell (SourceVaultRoutineOverdueSeconds), using each \
occurrence's GraceUntilUTC and resolved time (EvidenceAtUTC when Satisfied, else \
unresolved). SourceUnavailable dwell is not counted here. Returns <|dayKey-> \
seconds...|>. Options \"TimeZone\", \"Now\" (upper bound for unresolved, default now).";

(* === R8a: automation decision core (spec 8.1 / 9 / P1-4) === *)

SourceVaultRoutineFormulaicScore::usage =
  "SourceVaultRoutineFormulaicScore[traces, opts] measures how FORMULAIC a routine's \
executions are (spec 8.1), DETERMINISTICALLY (no LLM): high when the procedure \
signature is consistent, with no owner interventions and no failures. traces is a \
list of <|\"Signature\"->_ (a hashable step-sequence), \"OwnerInterventions\"->_Integer \
(default 0), \"Failed\"->_ (default False)|>. Returns <|\"Score\"->0..1, \
\"SampleSize\", \"Candidate\"->Bool, \"SignatureConsistency\", \"CleanRate\", \
\"FailureRate\"|>. Candidate requires Score >= \"Threshold\" (0.85) AND SampleSize >= \
\"MinSample\" (10): a small sample is NEVER a candidate (P1-4). Score = \
SignatureConsistency * (1-FailureRate) * CleanRate.";

SourceVaultRoutineAutomationEligibility::usage =
  "SourceVaultRoutineAutomationEligibility[spec, opts] is the eligibility GATE that runs \
BEFORE the formulaic score (spec 8.1 / P1-4): a high similarity score does NOT make an \
action safe to automate. spec is an Association describing the action: \
\"ActionRef\" (Missing blocks), \"AutoRunCapability\" (\"HeadlessAsync\"/\"FrontendRequired\"/\
...; FrontendRequired blocks), \"Idempotent\"->Bool, \"Reversible\"->Bool, \
\"RollbackPlan\"->Bool, \"HasPostcondition\"->Bool, \"CredentialScope\" (\"All\" blocks), \
\"TestedRuns\"->Integer. Returns <|\"Eligible\"->Bool, \"MaxState\"->\"None\"|\
\"Supervised\"|\"Unattended\", \"Blockers\"->{...}|>. Unattended is only reachable when \
option \"IP5Wired\"->True (the no-duplicate-execution condition is configured); \
otherwise MaxState caps at Supervised (AC-011).";

SourceVaultRoutineRecertificationClass::usage =
  "SourceVaultRoutineRecertificationClass[spec] classifies an automation for TTL / \
receipt cadence (spec 9): Class A (external send/delete/irreversible: 30-day TTL, \
weekly receipt, sampled outcome audit), B (reversible local mutation: 90-day, \
biweekly), C (read-only fetch: 180-day, monthly/exception). spec keys \"ActionRisk\" \
(\"High\"/\"Medium\"/\"Low\"), \"Reversible\"->Bool, \"Importance\", \"CredentialScope\". \
Importance High escalates one step stricter (C->B, B->A). Returns <|\"Class\", \
\"TTLDays\", \"ReceiptEvery\", \"OutcomeAudit\"->Bool|>.";

(* === R8b: automation proposal / approval flow (spec 8.2) === *)

SourceVaultRoutineProposeAutomation::usage =
  "SourceVaultRoutineProposeAutomation[routineId, automationSpec, traces, opts] proposes \
automating a routine (spec 8.2). It runs the eligibility GATE and the formulaic score; \
only when the spec is Eligible AND the traces make it a Candidate does it append an \
AutomationProposal fact to the durable ledger as state \"PendingReview\" (never \
auto-applied, I-16) and return the proposal. Otherwise it returns a rejection \
Association with the reason (no ledger write). The fact is content-minimized (routineId/\
score/MaxState/RecertClass only; the automationSpec stays owner-local). Options are \
forwarded to the score/eligibility (\"Threshold\",\"MinSample\",\"IP5Wired\").";

SourceVaultRoutineAutomationProposals::usage =
  "SourceVaultRoutineAutomationProposals[opts] replays the ledger and returns the \
current state of each automation proposal (PendingReview / Approved / Rejected). \
Option \"State\"->All filters.";

SourceVaultRoutineApproveAutomation::usage =
  "SourceVaultRoutineApproveAutomation[proposalId, automationSpec, \
\"OwnerAuthorization\"->True] approves a PendingReview proposal (spec 8.2). It builds a \
TriggerSpec DRAFT (Enabled->False, provenance CreatedBy->\"RoutineAutomationProposal\" \
+ ProposalId/ApprovedBy/AuthorizationId, ExpiresAt = now + the RecertificationClass \
TTL), MINTS a one-shot AT-1 Register permit bound to that draft (via \
SourceVaultAutoTriggerMintPermit when autotrigger is loaded; option \"PermitMintFn\" is \
the injection seam), and records an AutomationReviewed(Approved) fact. Returns \
<|\"Draft\", \"Permit\", \"ProposalId\", \"AuthorizationId\"|>; the owner then calls \
SourceVaultRegisterAutoTrigger[Draft, \"DryRun\"->False, \"Permit\"->Permit]. \
OwnerAuthorization is required; the draft starts Enabled->False so a separate owner \
Enable (with its own permit + EnabledAudit) is still needed to arm it (AC-011: no path \
reaches Unattended without owner action).";

SourceVaultRoutineRejectAutomation::usage =
  "SourceVaultRoutineRejectAutomation[proposalId, opts] records an \
AutomationReviewed(Rejected) fact for a proposal. Option \"Reason\".";

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
iSVRtnAppendLine[file_, assoc_] := Module[{json, clean},
  clean = assoc /. m_Missing :> Null;   (* JSON has no Missing; store as null *)
  json = StringReplace[
    Quiet@Check[Developer`WriteRawJSONString[clean, "Compact" -> True],
      Developer`WriteRawJSONString[clean]], {"\n" -> " ", "\r" -> " "}];
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

(* ============================================================
   R3: ActionGate -- capability-class router for UI clicks (spec 7 / P0-7).
   Pure decision logic; performs no side effects. Board/View calls this before
   acting, and executes only what the gate returns.
   ============================================================ *)

$svRtnActionClassMap = <|
  "ShowDetail" -> "Select", "Select" -> "Select", "JumpTo" -> "Select",
  "Inspect" -> "Select",
  "OpenNotebook" -> "LocalNavigation", "OpenDirectory" -> "LocalNavigation",
  "Pin" -> "LocalMutation", "Waive" -> "LocalMutation", "Ack" -> "LocalMutation",
  "Snooze" -> "LocalMutation", "CreatePrepNote" -> "LocalMutation",
  "CandidateToOpen" -> "LocalMutation", "FalseAlarm" -> "LocalMutation",
  "Unpin" -> "LocalMutation",
  "RunNow" -> "WorkflowDispatch", "StartReplyDraft" -> "WorkflowDispatch",
  "OpenURL" -> "ExternalNavigation"|>;
SourceVault`SourceVaultRoutineActionClass[kind_String] :=
  Lookup[$svRtnActionClassMap, kind, "Unknown"];
SourceVault`SourceVaultRoutineActionClass[___] := "Unknown";

(* case-insensitive path containment: target must be under root, no ".." escape *)
iSVRtnPathContained[path_String, root_String] := Module[
  {pp = FileNameSplit[path], rp = FileNameSplit[root], lc},
  lc = ToLowerCase;
  If[MemberQ[pp, ".."] || rp === {} || Length[pp] < Length[rp], False,
    (lc /@ Take[pp, Length[rp]]) === (lc /@ rp)]];
iSVRtnPathContained[___] := False;

iSVRtnAnyRootContains[path_, roots_List] :=
  AnyTrue[roots, StringQ[#] && iSVRtnPathContained[path, #] &];

(* the durable fact a LocalMutation should append (built, not appended, by the gate) *)
iSVRtnMutationFact[action_] := Module[
  {kind = Lookup[action, "Kind", ""], sid, tok, base},
  {sid, tok} = With[{k = Lookup[action, "OccurrenceKey", Missing["None"]]},
    If[StringQ[k] && StringContainsQ[k, "|"],
      With[{sp = StringSplit[k, "|", 2]}, {sp[[1]], sp[[2]]}], {Missing["None"], Missing["None"]}]];
  base = <|"StableId" -> sid, "OccurrenceToken" -> tok|>;
  Switch[kind,
    "Waive", Join[base, <|"FactKind" -> "Waive",
      "WaiveReason" -> Lookup[action, "Reason", "OwnerDecision"]|>],
    "Ack", Join[base, <|"FactKind" -> "Ack"|>],
    "Snooze", Join[base, <|"FactKind" -> "Snooze",
      "UntilAbs" -> N[iSVRtnAbs[Lookup[action, "UntilAbs", Missing["None"]]] /.
        Except[_?NumberQ] -> 0]|>],
    "Pin", Join[base, <|"FactKind" -> "ManualMark", "MarkState" -> "Pinned"|>],
    _, Join[base, <|"FactKind" -> "AuditAction", "ActionKind" -> kind|>]]];

iSVRtnDecision[allowed_, class_, reason_, opts_ : <||>] :=
  Join[<|"Allowed" -> allowed, "Class" -> class, "Reason" -> reason,
    "RequiresConfirm" -> False, "RequiresPreview" -> False,
    "Effect" -> Missing["None"], "AuditFact" -> Missing["None"]|>, opts];

SourceVault`SourceVaultRoutineActionGate[action_Association, context_ : <||>] := Module[
  {kind = Lookup[action, "Kind", ""], class, ctx = If[AssociationQ[context], context, <||>],
   target, url, roots, schemes, domains, occs, key, occ, curDigest, expDigest, parsed,
   scheme, domain},
  class = SourceVault`SourceVaultRoutineActionClass[kind];
  Switch[class,
    "Select",
      iSVRtnDecision[True, class, "EffectFree", <|"Effect" -> "ShowInline"|>],
    "LocalNavigation",
      target = Lookup[action, "Target", Missing["None"]];
      roots = Lookup[ctx, "AllowedRoots", {}];
      occs = Lookup[ctx, "Occurrences", <||>];
      key = Lookup[action, "OccurrenceKey", Missing["None"]];
      Which[
        !StringQ[target],
          iSVRtnDecision[False, class, "NoTarget"],
        !iSVRtnAnyRootContains[target, roots],
          iSVRtnDecision[False, class, "PathNotContained"],
        StringQ[key] && AssociationQ[occs] && !KeyExistsQ[occs, key],
          iSVRtnDecision[False, class, "OccurrenceGone"],
        True,
          iSVRtnDecision[True, class, "Contained",
            <|"Effect" -> "OpenLocal"|>]],
    "WorkflowDispatch",
      occs = Lookup[ctx, "Occurrences", <||>];
      key = Lookup[action, "OccurrenceKey", Missing["None"]];
      occ = If[StringQ[key] && AssociationQ[occs], Lookup[occs, key, Missing["None"]],
        Missing["None"]];
      expDigest = Lookup[action, "ExpectedSemanticDigest", Missing["None"]];
      curDigest = If[AssociationQ[occ],
        Lookup[Lookup[occ, "Revision", <||>], "SemanticDigest", Missing["None"]],
        Missing["None"]];
      Which[
        !AssociationQ[occ],
          iSVRtnDecision[False, class, "OccurrenceGone"],
        expDigest =!= Missing["None"] && curDigest =!= Missing["None"] &&
          expDigest =!= curDigest,
          iSVRtnDecision[False, class, "StaleRevision"],   (* AC-028 *)
        True,
          iSVRtnDecision[True, class, "RevisionOK",
            <|"Effect" -> "DelegateToAutoTrigger"|>]],
    "ExternalNavigation",
      url = Lookup[action, "URL", Missing["None"]];
      schemes = ToLowerCase /@ Lookup[ctx, "URLSchemes", {"https"}];
      domains = Lookup[ctx, "URLDomains", All];
      If[!StringQ[url], Return[iSVRtnDecision[False, class, "NoURL"]]];
      parsed = Quiet@Check[URLParse[url], $Failed];
      scheme = If[AssociationQ[parsed], ToLowerCase[ToString[Lookup[parsed, "Scheme", ""]]], ""];
      domain = If[AssociationQ[parsed], ToString[Lookup[parsed, "Domain", ""]], ""];
      Which[
        !MemberQ[schemes, scheme],
          iSVRtnDecision[False, class, "SchemeNotAllowed"],   (* AC-029 *)
        ListQ[domains] && !MemberQ[domains, domain],
          iSVRtnDecision[False, class, "DomainNotAllowed"],   (* AC-029 *)
        True,
          iSVRtnDecision[True, class, "URLAllowed",
            <|"RequiresConfirm" -> True, "Effect" -> "OpenExternal"|>]],
    "LocalMutation",
      If[!TrueQ[Lookup[ctx, "OwnerPermit", False]],
        iSVRtnDecision[False, class, "OwnerPermitRequired"],
        iSVRtnDecision[True, class, "OwnerAuthorized",
          <|"RequiresPreview" -> True, "Effect" -> "AppendLedgerFact",
            "AuditFact" -> iSVRtnMutationFact[action]|>]],
    _,
      iSVRtnDecision[False, "Unknown", "UnknownActionKind"]]];
SourceVault`SourceVaultRoutineActionGate[___] :=
  iSVRtnDecision[False, "Unknown", "BadArguments"];

(* ============================================================
   R3: Board -- attention list (spec 5.1). BoardData is the pure, headless-tested
   row builder; BoardView is the FE renderer (needs a Front End) wired to ActionGate.
   ============================================================ *)

iSVRtnBoardActions[occ_] := Module[
  {kind = Lookup[occ, "Kind", ""], ful = Lookup[occ, "Fulfillment", <||>],
   imp = Lookup[occ, "Importance", "Normal"], acts},
  acts = Switch[kind,
    "OnWorkTask", {"ShowDetail", "OpenNotebook", "Ack", "Snooze"},
    "Commitment", {"ShowDetail", "StartReplyDraft", "Waive", "Ack", "Snooze"},
    "Routine", {"ShowDetail", "RunNow", "Ack", "Snooze", "Waive"},
    "CalendarEvent", {"ShowDetail", "Ack"},
    "PrepTask", {"ShowDetail", "OpenNotebook", "Ack", "Snooze"},
    _, {"ShowDetail", "Ack"}];
  (* Low-importance items are waivable everywhere *)
  If[imp === "Low" && !MemberQ[acts, "Waive"], acts = Append[acts, "Waive"]];
  acts];

$svRtnTemporalRank = <|"Overdue" -> 0, "DueSoon" -> 1, "Upcoming" -> 2, "Unknown" -> 3|>;
$svRtnImpRank = <|"Mandatory" -> 0, "High" -> 1, "Normal" -> 2, "Low" -> 3|>;

Options[SourceVault`SourceVaultRoutineBoardData] = {
  "IncludeResolved" -> False, "IncludeSnoozed" -> False, "SoonWindow" -> 86400};
SourceVault`SourceVaultRoutineBoardData[occs_List, now_, OptionsPattern[]] := Module[
  {sw = OptionValue["SoonWindow"], nowAbs = iSVRtnAbs[now], rows},
  rows = Map[Function[occ, Module[
    {sched = Lookup[occ, "Schedule", <||>], ful = Lookup[occ, "Fulfillment", <||>],
     att = Lookup[occ, "Attention", <||>], temporal, key},
    key = Quiet@Check[SourceVault`SourceVaultRoutineKeyString[Lookup[occ, "Identity", <||>]],
      "?"];
    temporal = SourceVault`SourceVaultRoutineTemporalState[sched, now, "SoonWindow" -> sw];
    <|"Key" -> key, "Kind" -> Lookup[occ, "Kind", ""],
      "Importance" -> Lookup[occ, "Importance", "Normal"],
      "Temporal" -> temporal,
      "FulfillmentState" -> Lookup[ful, "State", "Unknown"],
      "Resolution" -> Lookup[ful, "Resolution", Missing["None"]],
      "AttentionState" -> Lookup[att, "State", "Eligible"],
      "NextEligibleAtUTC" -> Lookup[att, "NextEligibleAtUTC", Missing["None"]],
      "DueAtUTC" -> Lookup[sched, "DueAtUTC", Missing["None"]],
      "ExpectedSemanticDigest" ->
        Lookup[Lookup[occ, "Revision", <||>], "SemanticDigest", Missing["None"]],
      "FreshnessState" -> Lookup[Lookup[occ, "Source", <||>], "FreshnessState", "Fresh"],
      "Actions" -> iSVRtnBoardActions[occ]|>]], occs];
  (* filter to what needs attention *)
  rows = Select[rows, Function[r,
    Module[{resolved = MemberQ[{"Satisfied", "Waived", "Cancelled"}, r["FulfillmentState"]],
       snoozed = r["AttentionState"] === "Snoozed" &&
         NumberQ[iSVRtnAbs[r["NextEligibleAtUTC"]]] &&
         iSVRtnAbs[r["NextEligibleAtUTC"]] > nowAbs},
      And[
        Or[TrueQ[OptionValue["IncludeResolved"]], !resolved],
        Or[TrueQ[OptionValue["IncludeSnoozed"]], !snoozed],
        MemberQ[{"Overdue", "DueSoon"}, r["Temporal"]] ||
          TrueQ[OptionValue["IncludeResolved"]]]]]];
  (* sort: importance (Mandatory first) then temporal (overdue first) then due asc *)
  SortBy[rows, {
    Lookup[$svRtnImpRank, #["Importance"], 2] &,
    Lookup[$svRtnTemporalRank, #["Temporal"], 3] &,
    With[{d = iSVRtnAbs[#["DueAtUTC"]]}, If[NumberQ[d], d, Infinity]] &}]];
SourceVault`SourceVaultRoutineBoardData[___] := {};

(* FE renderer -- needs a Front End; NB-verified. Logic is in BoardData/ActionGate. *)
Options[SourceVault`SourceVaultRoutineBoardView] = Join[
  Options[SourceVault`SourceVaultRoutineBoardData],
  {"ActionHandler" -> Automatic, "Occurrences" -> <||>, "OwnerPermit" -> False,
   "AllowedRoots" -> {}}];
SourceVault`SourceVaultRoutineBoardView[occs_List, opts : OptionsPattern[]] := Module[
  {rows, handler = OptionValue["ActionHandler"], snapKeyed, gateCtx},
  rows = SourceVault`SourceVaultRoutineBoardData[occs, Now,
    "IncludeResolved" -> OptionValue["IncludeResolved"],
    "IncludeSnoozed" -> OptionValue["IncludeSnoozed"],
    "SoonWindow" -> OptionValue["SoonWindow"]];
  snapKeyed = Association[Map[
    (Quiet@Check[SourceVault`SourceVaultRoutineKeyString[Lookup[#, "Identity", <||>]], "?"] -> #) &,
    occs]];
  gateCtx = <|"Occurrences" -> snapKeyed, "OwnerPermit" -> OptionValue["OwnerPermit"],
    "AllowedRoots" -> OptionValue["AllowedRoots"], "URLSchemes" -> {"https"}|>;
  If[handler === Automatic, handler = Function[dec, dec]];
  If[rows === {},
    Style["No routines or commitments need attention.", Italic],
    Dataset[Map[Function[r,
      <|"\:671f\:9650" -> r["DueAtUTC"], "\:7a2e\:5225" -> r["Kind"],
        "\:91cd\:8981\:5ea6" -> r["Importance"], "\:72b6\:614b" -> r["Temporal"],
        "\:5c65\:884c" -> r["FulfillmentState"], "\:6ce8\:610f" -> r["AttentionState"],
        "\:64cd\:4f5c" -> Row[Riffle[Map[Function[k,
          Button[k, handler[SourceVault`SourceVaultRoutineActionGate[
            <|"Kind" -> k, "OccurrenceKey" -> r["Key"],
              "ExpectedSemanticDigest" -> r["ExpectedSemanticDigest"]|>, gateCtx]],
            ImageSize -> Automatic]], r["Actions"]], " "]]|>], rows]]]];
SourceVault`SourceVaultRoutineBoardView[___] :=
  Style["SourceVaultRoutineBoardView: expected a list of occurrences.", Red];

(* ============================================================
   R4a: AttentionContext gate + envelope + mandatory ladder + coverage.
   Pure gate logic (P0-1: meeting gate and quiet gate are independent) plus a small
   owner-signed policy store. The durable notification queue is R4b.
   ============================================================ *)

SourceVault`SourceVaultRoutineDefaultAttentionPolicy[] := <|
  "MeetingGate" -> <|"Enabled" -> True, "DeferDuringBusy" -> True,
    "FlushAfterMeetingMinutes" -> 5, "MandatoryLeadMinutes" -> {1440, 120, 15}|>,
  "QuietHours" -> Missing["None"],
  "Channels" -> <|"Board" -> True, "Badge" -> False, "Digest" -> False, "Mail" -> False|>|>;

iSVRtnAttnPolicyFile[] := If[iSVRtnLedgerRootQ[],
  FileNameJoin[{SourceVault`$SourceVaultRoutineLedgerRoot, "config", "attention_policy.json"}],
  $Failed];

Options[SourceVault`SourceVaultRoutineSetAttentionPolicy] = {"OwnerAuthorization" -> False};
SourceVault`SourceVaultRoutineSetAttentionPolicy[policy_Association, OptionsPattern[]] := Module[
  {f = iSVRtnAttnPolicyFile[]},
  If[!TrueQ[OptionValue["OwnerAuthorization"]],
    Return[Failure["NBRoutineOwnerAuthRequired",
      <|"MessageTemplate" -> "OwnerAuthorization->True is required."|>]]];
  If[f === $Failed,
    Return[Failure["NBRoutineNoLedgerRoot",
      <|"MessageTemplate" -> "$SourceVaultRoutineLedgerRoot is not set."|>]]];
  iSVRtnEnsureDir[DirectoryName[f]];
  Export[f, Developer`WriteRawJSONString[Join[policy,
    <|"UpdatedAt" -> iSVRtnNowIso[]|>]], "Text"];
  <|"Status" -> "OK"|>];
SourceVault`SourceVaultRoutineSetAttentionPolicy[___] :=
  Failure["NBRoutineBadArgs", <|"MessageTemplate" -> "policy must be an Association."|>];

SourceVault`SourceVaultRoutineAttentionPolicy[] := Module[{f = iSVRtnAttnPolicyFile[], j},
  If[f === $Failed || !FileExistsQ[f],
    Return[SourceVault`SourceVaultRoutineDefaultAttentionPolicy[]]];
  j = Quiet@Check[Developer`ReadRawJSONString[Import[f, "Text"]], $Failed];
  If[AssociationQ[j], j, SourceVault`SourceVaultRoutineDefaultAttentionPolicy[]]];

Options[SourceVault`SourceVaultRoutineNotificationEnvelope] = {
  "Stage" -> "Default", "Urgency" -> "Normal", "MeetingBypass" -> False,
  "QuietHoursBypass" -> False, "Channel" -> "Board", "OccurrenceKey" -> Missing["None"],
  "EpisodeId" -> Missing["None"]};
SourceVault`SourceVaultRoutineNotificationEnvelope[kind_String, OptionsPattern[]] := <|
  "Kind" -> kind, "Stage" -> OptionValue["Stage"], "Urgency" -> OptionValue["Urgency"],
  "MeetingBypass" -> TrueQ[OptionValue["MeetingBypass"]],
  "QuietHoursBypass" -> TrueQ[OptionValue["QuietHoursBypass"]],
  "Channel" -> OptionValue["Channel"],
  "OccurrenceKey" -> OptionValue["OccurrenceKey"],
  "EpisodeId" -> OptionValue["EpisodeId"]|>;

SourceVault`SourceVaultRoutineInQuietHours[policy_Association, now_] := Module[
  {qh = Lookup[policy, "QuietHours", Missing["None"]], hr, sh, eh},
  If[!AssociationQ[qh], Return[False]];
  sh = Lookup[qh, "StartHour", Missing["None"]];
  eh = Lookup[qh, "EndHour", Missing["None"]];
  If[!IntegerQ[sh] || !IntegerQ[eh], Return[False]];
  (* a DateObject is read in its OWN time zone; an absolute number in local time *)
  hr = Which[
    DateObjectQ[now], Quiet@Check[DateValue[now, "Hour"], $Failed],
    NumberQ[now], Quiet@Check[DateValue[FromAbsoluteTime[now], "Hour"], $Failed],
    True, $Failed];
  If[!IntegerQ[hr] && !NumberQ[hr], Return[False]];
  hr = Floor[hr];
  If[sh <= eh, sh <= hr < eh, hr >= sh || hr < eh]];  (* wraps past midnight *)
SourceVault`SourceVaultRoutineInQuietHours[___] := False;

SourceVault`SourceVaultRoutineAttentionGate[env_Association, context_ : <||>] := Module[
  {ctx = If[AssociationQ[context], context, <||>], busyQ, quietQ, mb, qb, deferM, deferQ},
  busyQ = TrueQ[Lookup[ctx, "BusyQ", False]];
  quietQ = TrueQ[Lookup[ctx, "InQuietHours", False]];
  mb = TrueQ[Lookup[env, "MeetingBypass", False]];
  qb = TrueQ[Lookup[env, "QuietHoursBypass", False]];
  deferM = busyQ && !mb;
  deferQ = quietQ && !qb;
  If[deferM || deferQ,
    <|"Decision" -> "Defer",
      "Reason" -> Which[deferM && deferQ, "BusyAndQuiet", deferM, "Busy", True, "Quiet"]|>,
    <|"Decision" -> "Deliver", "Reason" -> "Eligible"|>]];
SourceVault`SourceVaultRoutineAttentionGate[___] :=
  <|"Decision" -> "Defer", "Reason" -> "BadArguments"|>;

SourceVault`SourceVaultRoutineMandatoryLadderStage[eventStart_, now_, policy_Association] := Module[
  {es = iSVRtnAbs[eventStart], n = iSVRtnAbs[now], leads, minutesUntil, entered, tightest, minLead},
  leads = Lookup[Lookup[policy, "MeetingGate", <||>], "MandatoryLeadMinutes", {1440, 120, 15}];
  If[!MatchQ[leads, {__?NumberQ}], leads = {1440, 120, 15}];
  If[!NumberQ[es] || !NumberQ[n] || n >= es,
    Return[<|"Stage" -> Missing["None"], "LeadMinutes" -> Missing["None"],
      "MeetingBypass" -> False, "Urgency" -> "Normal", "MinutesUntil" -> Missing["None"]|>]];
  minutesUntil = (es - n)/60.;
  entered = Select[leads, minutesUntil <= # &];   (* windows we have entered *)
  If[entered === {},
    Return[<|"Stage" -> Missing["None"], "LeadMinutes" -> Missing["None"],
      "MeetingBypass" -> False, "Urgency" -> "Normal", "MinutesUntil" -> minutesUntil|>]];
  tightest = Min[entered];   (* tightest window entered = current stage *)
  minLead = Min[leads];      (* tightest configured stage pierces meetings *)
  <|"Stage" -> "Lead" <> ToString[Round[tightest]] <> "Minutes",
    "LeadMinutes" -> tightest,
    "MeetingBypass" -> (tightest == minLead),
    "Urgency" -> If[tightest == minLead, "Critical", "Normal"],
    "MinutesUntil" -> minutesUntil|>];
SourceVault`SourceVaultRoutineMandatoryLadderStage[___] :=
  <|"Stage" -> Missing["None"], "MeetingBypass" -> False, "Urgency" -> "Normal"|>;

SourceVault`SourceVaultRoutineCoverageDegradedQ[fresh_] :=
  MemberQ[{"Stale", "Unavailable", "Partial"}, fresh];
SourceVault`SourceVaultRoutineCoverageDegradedQ[___] := False;

(* ============================================================
   R4b: durable notification queue (spec 5.2/5.3 / P0-5).
   Machine-local (derived, regenerable). Append-only JSONL, replay-latest per
   EnvelopeId. State: Pending -> Deferred -> Delivered | Superseded | Expired.
   ============================================================ *)

$svRtnTerminalStates = {"Delivered", "Superseded", "Expired"};

iSVRtnQueueFile[] := If[iSVRtnLedgerRootQ[] ||
    (StringQ[SourceVault`$SourceVaultRoutineCacheRoot] &&
      SourceVault`$SourceVaultRoutineCacheRoot =!= ""),
  FileNameJoin[{iSVRtnCacheRoot[], "queue", "notifications.jsonl"}], $Failed];

iSVRtnQueueReadLatest[] := Module[{f = iSVRtnQueueFile[], evs, latest = <||>},
  If[f === $Failed || !FileExistsQ[f], Return[{}]];
  evs = iSVRtnReadEvents[f];
  Do[If[StringQ[Lookup[r, "EnvelopeId", Missing[]]],
    latest[r["EnvelopeId"]] = r], {r, evs}];
  Values[latest]];

iSVRtnEnvelopeId[env_] := iSVRtnDigest[StringRiffle[{
  ToString[Lookup[env, "OccurrenceKey", ""]], ToString[Lookup[env, "Kind", ""]],
  ToString[Lookup[env, "Stage", ""]], ToString[Lookup[env, "Channel", ""]],
  ToString[Lookup[env, "EpisodeId", ""]]}, "|"]];

Options[SourceVault`SourceVaultRoutineEnqueueNotification] = {"EnvelopeId" -> Automatic};
SourceVault`SourceVaultRoutineEnqueueNotification[env_Association, OptionsPattern[]] := Module[
  {f = iSVRtnQueueFile[], envId, existing, rec},
  If[f === $Failed,
    Return[Failure["NBRoutineNoQueueRoot",
      <|"MessageTemplate" -> "No ledger/cache root for the notification queue."|>]]];
  envId = With[{o = OptionValue["EnvelopeId"]},
    If[StringQ[o], o, iSVRtnEnvelopeId[env]]];
  existing = SelectFirst[iSVRtnQueueReadLatest[],
    Lookup[#, "EnvelopeId", Missing[]] === envId &, Missing["None"]];
  (* idempotent hysteresis: same logical notification is enqueued once *)
  If[AssociationQ[existing], Return[existing]];
  rec = <|"EnvelopeId" -> envId, "State" -> "Pending",
    "Kind" -> Lookup[env, "Kind", ""], "Stage" -> Lookup[env, "Stage", "Default"],
    "Channel" -> Lookup[env, "Channel", "Board"],
    "OccurrenceKey" -> Lookup[env, "OccurrenceKey", Missing["None"]],
    "EpisodeId" -> Lookup[env, "EpisodeId", Missing["None"]],
    "MeetingBypass" -> TrueQ[Lookup[env, "MeetingBypass", False]],
    "QuietHoursBypass" -> TrueQ[Lookup[env, "QuietHoursBypass", False]],
    "Urgency" -> Lookup[env, "Urgency", "Normal"],
    "EnqueuedAtAbs" -> N[AbsoluteTime[]], "UpdatedAtAbs" -> N[AbsoluteTime[]],
    "DeferCount" -> 0, "DeliveryAttemptId" -> Missing["None"],
    "ChannelReceipt" -> Missing["None"], "Reason" -> "Enqueued"|>;
  iSVRtnAppendLine[f, rec];
  rec];
SourceVault`SourceVaultRoutineEnqueueNotification[___] :=
  Failure["NBRoutineBadArgs", <|"MessageTemplate" -> "envelope must be an Association."|>];

Options[SourceVault`SourceVaultRoutineQueueRecords] = {"State" -> All};
SourceVault`SourceVaultRoutineQueueRecords[OptionsPattern[]] := Module[
  {recs = iSVRtnQueueReadLatest[], st = OptionValue["State"]},
  If[StringQ[st], Select[recs, Lookup[#, "State", ""] === st &], recs]];

iSVRtnQueueUpdate[rec_, changes_] := Module[{f = iSVRtnQueueFile[], nr},
  nr = Join[rec, changes, <|"UpdatedAtAbs" -> N[AbsoluteTime[]]|>];
  If[f =!= $Failed, iSVRtnAppendLine[f, nr]];
  nr];

Options[SourceVault`SourceVaultRoutineSupersedeNotifications] = {"Reason" -> "Superseded"};
SourceVault`SourceVaultRoutineSupersedeNotifications[occKey_String, OptionsPattern[]] := Module[
  {targets, n = 0},
  targets = Select[iSVRtnQueueReadLatest[],
    Lookup[#, "OccurrenceKey", Missing[]] === occKey &&
      !MemberQ[$svRtnTerminalStates, Lookup[#, "State", ""]] &];
  Do[iSVRtnQueueUpdate[r, <|"State" -> "Superseded",
    "Reason" -> OptionValue["Reason"]|>]; n++, {r, targets}];
  <|"Status" -> "OK", "Superseded" -> n|>];
SourceVault`SourceVaultRoutineSupersedeNotifications[___] :=
  Failure["NBRoutineBadArgs", <|"MessageTemplate" -> "occurrenceKey must be a string."|>];

(* default channel: Board / internal -> effectively-once in-record delivery *)
iSVRtnDefaultChannelFn[env_, attemptId_] := <|"Channel" -> Lookup[env, "Channel", "Board"],
  "DeliveredAtAbs" -> N[AbsoluteTime[]], "AttemptId" -> attemptId|>;

Options[SourceVault`SourceVaultRoutineQueueTick] = {
  "ChannelFn" -> Automatic, "MaxDeferSeconds" -> 86400, "MaxRecords" -> 500};
SourceVault`SourceVaultRoutineQueueTick[context_ : <||>, OptionsPattern[]] := Module[
  {ctx = If[AssociationQ[context], context, <||>], chFn = OptionValue["ChannelFn"],
   maxDefer = OptionValue["MaxDeferSeconds"], now, active, delivered = 0, deferred = 0,
   fellBack = 0},
  If[iSVRtnQueueFile[] === $Failed,
    Return[<|"Status" -> "NoQueueRoot", "Delivered" -> 0, "Deferred" -> 0|>]];
  If[chFn === Automatic, chFn = iSVRtnDefaultChannelFn];
  now = With[{c = iSVRtnAbs[Lookup[ctx, "Now", Missing[]]]},
    If[NumberQ[c], c, N[AbsoluteTime[]]]];
  active = Select[iSVRtnQueueReadLatest[],
    MemberQ[{"Pending", "Deferred"}, Lookup[#, "State", ""]] &];
  If[IntegerQ[OptionValue["MaxRecords"]],
    active = Take[active, UpTo[OptionValue["MaxRecords"]]]];
  Do[Module[{rec = r, env, decision, attemptId, receipt, agedOut},
    env = <|"Kind" -> rec["Kind"], "Stage" -> rec["Stage"], "Channel" -> rec["Channel"],
      "MeetingBypass" -> rec["MeetingBypass"],
      "QuietHoursBypass" -> rec["QuietHoursBypass"]|>;
    agedOut = NumberQ[maxDefer] && (now - Lookup[rec, "EnqueuedAtAbs", now]) > maxDefer;
    decision = If[agedOut, "Deliver",
      SourceVault`SourceVaultRoutineAttentionGate[env, ctx]["Decision"]];
    If[decision === "Deliver",
      (* fresh DeliveryAttemptId per attempt (at-least-once for external channels) *)
      attemptId = iSVRtnULID[];
      receipt = Quiet@Check[chFn[
        If[agedOut, Append[env, "Channel" -> "Board"], env], attemptId], $Failed];
      If[receipt === $Failed,
        (iSVRtnQueueUpdate[rec, <|"State" -> "Deferred",
          "DeferCount" -> Lookup[rec, "DeferCount", 0] + 1,
          "Reason" -> "ChannelFailedRetry"|>]; deferred++),
        (iSVRtnQueueUpdate[rec, <|"State" -> "Delivered",
          "Channel" -> If[agedOut, "Board", rec["Channel"]],
          "DeliveryAttemptId" -> attemptId, "ChannelReceipt" -> receipt,
          "Reason" -> If[agedOut, "MaxDeferFallbackToBoard", "Delivered"]|>];
         delivered++; If[agedOut, fellBack++])],
      (* Defer: re-evaluated next tick against current context *)
      (iSVRtnQueueUpdate[rec, <|"State" -> "Deferred",
        "DeferCount" -> Lookup[rec, "DeferCount", 0] + 1,
        "Reason" -> "DeferredByGate"|>]; deferred++)]],
    {r, active}];
  <|"Status" -> "OK", "Delivered" -> delivered, "Deferred" -> deferred,
    "FellBackToBoard" -> fellBack|>];

SourceVault`SourceVaultRoutineQueueReset[] := Module[{f = iSVRtnQueueFile[]},
  If[f =!= $Failed && FileExistsQ[f], Quiet@DeleteFile[f]];
  <|"Status" -> "Reset"|>];

(* ============================================================
   R7: statistical streams (spec 4.3). Pure daily binning of resolved occurrences
   into rate streams for the existing anomaly (1H-A) workflow. This is where
   "routine not run for a while" becomes a state anomaly. IO-free.
   ============================================================ *)

iSVRtnDayBin[abs_, tz_] := Module[{d, y, mo, day, ds, de},
  d = Quiet@Check[DateObject[FromAbsoluteTime[abs], TimeZone -> tz], $Failed];
  If[!DateObjectQ[d], Return[$Failed]];
  {y, mo, day} = Round /@ DateValue[d, {"Year", "Month", "Day"}];
  ds = AbsoluteTime[DateObject[{y, mo, day, 0, 0, 0}, TimeZone -> tz]];
  de = ds + 86400;
  <|"Key" -> StringJoin[ToString[y], "-", IntegerString[mo, 10, 2], "-",
      IntegerString[day, 10, 2]],
    "StartAbs" -> ds, "EndAbs" -> de|>];

iSVRtnStreamPoints[byDay_] := Map[Function[k,
  <|"WindowStart" -> DateString[FromAbsoluteTime[byDay[k]["StartAbs"]],
      "ISODateTime", TimeZone -> 0] <> "Z",
    "WindowEnd" -> DateString[FromAbsoluteTime[byDay[k]["EndAbs"]],
      "ISODateTime", TimeZone -> 0] <> "Z",
    "EventCount" -> byDay[k]["Event"], "ExposureCount" -> byDay[k]["Exposure"]|>],
  Sort[Keys[byDay]]];

Options[SourceVault`SourceVaultRoutineExecutionStreams] = {
  "TimeZone" -> "Asia/Tokyo", "Kinds" -> All};
SourceVault`SourceVaultRoutineExecutionStreams[occs_List, OptionsPattern[]] := Module[
  {tz = OptionValue["TimeZone"], kinds = OptionValue["Kinds"], sel,
   execDay = <||>, ovDay = <||>, streams = <||>},
  sel = If[ListQ[kinds], Select[occs, MemberQ[kinds, Lookup[#, "Kind", ""]] &], occs];
  Do[Module[{due = iSVRtnAbs[Lookup[Lookup[o, "Schedule", <||>], "DueAtUTC", Missing[]]],
      ful = Lookup[o, "Fulfillment", <||>], bin, satisfied, overdue},
    If[NumberQ[due],
      bin = iSVRtnDayBin[due, tz];
      If[bin =!= $Failed,
        satisfied = Lookup[ful, "State", "Unknown"] === "Satisfied";
        overdue = TrueQ[Lookup[ful, "WasOverdue", False]] ||
          Lookup[ful, "Resolution", ""] === "Missed" ||
          Lookup[ful, "State", ""] === "Unfulfilled";
        execDay[bin["Key"]] = <|"StartAbs" -> bin["StartAbs"], "EndAbs" -> bin["EndAbs"],
          "Exposure" -> Lookup[execDay, bin["Key"], <|"Exposure" -> 0|>]["Exposure"] + 1,
          "Event" -> Lookup[execDay, bin["Key"], <|"Event" -> 0|>]["Event"] +
            If[satisfied, 1, 0]|>;
        ovDay[bin["Key"]] = <|"StartAbs" -> bin["StartAbs"], "EndAbs" -> bin["EndAbs"],
          "Exposure" -> Lookup[ovDay, bin["Key"], <|"Exposure" -> 0|>]["Exposure"] + 1,
          "Event" -> Lookup[ovDay, bin["Key"], <|"Event" -> 0|>]["Event"] +
            If[overdue, 1, 0]|>]]],
    {o, sel}];
  (* omit empty streams (I-15) *)
  If[execDay =!= <||>,
    streams["RoutineExecutionRate"] = <|"Points" -> iSVRtnStreamPoints[execDay]|>];
  If[ovDay =!= <||> && AnyTrue[Values[ovDay], #["Event"] > 0 &],
    streams["RoutineOverdueRate"] = <|"Points" -> iSVRtnStreamPoints[ovDay]|>];
  streams];
SourceVault`SourceVaultRoutineExecutionStreams[___] := <||>;

Options[SourceVault`SourceVaultRoutineOverdueSecondsByDay] = {
  "TimeZone" -> "Asia/Tokyo", "Now" -> Automatic};
SourceVault`SourceVaultRoutineOverdueSecondsByDay[occs_List, OptionsPattern[]] := Module[
  {tz = OptionValue["TimeZone"], nowAbs, byDay = <||>},
  nowAbs = With[{n = OptionValue["Now"]},
    If[n === Automatic, N[AbsoluteTime[]], iSVRtnAbs[n]]];
  Do[Module[{sched = Lookup[o, "Schedule", <||>], ful = Lookup[o, "Fulfillment", <||>],
      grace, resolved, bin, secs},
    grace = iSVRtnAbs[Lookup[sched, "GraceUntilUTC", Missing[]]];
    If[NumberQ[grace],
      resolved = If[Lookup[ful, "State", ""] === "Satisfied",
        iSVRtnAbs[Lookup[ful, "EvidenceAtUTC", Missing["None"]]], Missing["None"]];
      bin = iSVRtnDayBin[grace, tz];
      If[bin =!= $Failed,
        secs = SourceVault`SourceVaultRoutineOverdueSeconds[grace,
          If[NumberQ[resolved], resolved, Missing["None"]],
          bin["StartAbs"], Min[bin["EndAbs"], nowAbs]];
        byDay[bin["Key"]] = Lookup[byDay, bin["Key"], 0] + secs]]],
    {o, occs}];
  byDay];
SourceVault`SourceVaultRoutineOverdueSecondsByDay[___] := <||>;

(* ============================================================
   R8a: automation decision core (spec 8.1/9). Pure. The eligibility GATE is
   independent from (and precedes) the formulaic score: high similarity does not
   make an action safe. IO-free.
   ============================================================ *)

Options[SourceVault`SourceVaultRoutineFormulaicScore] = {"Threshold" -> 0.85, "MinSample" -> 10};
SourceVault`SourceVaultRoutineFormulaicScore[traces_List, OptionsPattern[]] := Module[
  {n = Length[traces], sigs, modalCount, sigConsistency, cleanRate, failureRate, score},
  If[n == 0,
    Return[<|"Score" -> 0., "SampleSize" -> 0, "Candidate" -> False,
      "SignatureConsistency" -> 0., "CleanRate" -> 0., "FailureRate" -> 0.|>]];
  sigs = Lookup[#, "Signature", Missing["None"]] & /@ traces;
  modalCount = Max[Values[Counts[sigs]]];
  sigConsistency = N[modalCount/n];
  cleanRate = N[Count[traces, t_ /; Lookup[t, "OwnerInterventions", 0] == 0]/n];
  failureRate = N[Count[traces, t_ /; TrueQ[Lookup[t, "Failed", False]]]/n];
  score = sigConsistency*(1 - failureRate)*cleanRate;
  <|"Score" -> score, "SampleSize" -> n,
    "Candidate" -> (score >= OptionValue["Threshold"] && n >= OptionValue["MinSample"]),
    "SignatureConsistency" -> sigConsistency, "CleanRate" -> cleanRate,
    "FailureRate" -> failureRate|>];
SourceVault`SourceVaultRoutineFormulaicScore[___] :=
  <|"Score" -> 0., "SampleSize" -> 0, "Candidate" -> False|>;

Options[SourceVault`SourceVaultRoutineAutomationEligibility] = {"IP5Wired" -> False};
SourceVault`SourceVaultRoutineAutomationEligibility[spec_Association, OptionsPattern[]] := Module[
  {blockers = {}, softBlocks = {}, maxState, ip5 = TrueQ[OptionValue["IP5Wired"]]},
  If[MissingQ[Lookup[spec, "ActionRef", Missing["None"]]] ||
      Lookup[spec, "ActionRef", Missing["None"]] === Missing["None"],
    AppendTo[blockers, "NoActionRef"]];
  If[Lookup[spec, "AutoRunCapability", ""] === "FrontendRequired",
    AppendTo[blockers, "FrontendRequired"]];
  If[Lookup[spec, "CredentialScope", ""] === "All",
    AppendTo[blockers, "UnboundedCredentialScope"]];
  (* not reversible AND no rollback plan is a hard blocker *)
  If[!TrueQ[Lookup[spec, "Reversible", False]] && !TrueQ[Lookup[spec, "RollbackPlan", False]],
    AppendTo[blockers, "IrreversibleNoRollback"]];
  (* soft: non-idempotent / no postcondition cap the state but do not fully block *)
  If[!TrueQ[Lookup[spec, "Idempotent", False]], AppendTo[softBlocks, "NonIdempotent"]];
  If[!TrueQ[Lookup[spec, "HasPostcondition", False]], AppendTo[softBlocks, "NoPostcondition"]];
  maxState = Which[
    blockers =!= {}, "None",
    (* Unattended needs IP-5 wired AND idempotent AND a checkable postcondition *)
    ip5 && softBlocks === {}, "Unattended",
    True, "Supervised"];
  <|"Eligible" -> (blockers === {}), "MaxState" -> maxState,
    "Blockers" -> blockers, "SoftBlocks" -> softBlocks|>];
SourceVault`SourceVaultRoutineAutomationEligibility[___] :=
  <|"Eligible" -> False, "MaxState" -> "None", "Blockers" -> {"BadSpec"}|>;

SourceVault`SourceVaultRoutineRecertificationClass[spec_Association] := Module[
  {risk = Lookup[spec, "ActionRisk", "Medium"], rev = TrueQ[Lookup[spec, "Reversible", True]],
   imp = Lookup[spec, "Importance", "Normal"], baseRank, rank, class, ttl, receipt, audit},
  (* base class rank: 1=A(strictest) .. 3=C(loosest) *)
  baseRank = Which[
    risk === "High" || !rev, 1,          (* external / irreversible -> A *)
    risk === "Medium", 2,                (* reversible local mutation -> B *)
    True, 3];                            (* read-only -> C *)
  rank = If[imp === "High", Max[1, baseRank - 1], baseRank];   (* escalate one step *)
  class = rank /. {1 -> "A", 2 -> "B", 3 -> "C"};
  {ttl, receipt, audit} = Switch[class,
    "A", {30, "Weekly", True},
    "B", {90, "Biweekly", False},
    _, {180, "Monthly", False}];
  <|"Class" -> class, "TTLDays" -> ttl, "ReceiptEvery" -> receipt, "OutcomeAudit" -> audit|>];
SourceVault`SourceVaultRoutineRecertificationClass[___] :=
  <|"Class" -> "A", "TTLDays" -> 30, "ReceiptEvery" -> "Weekly", "OutcomeAudit" -> True|>;

(* ============================================================
   R8b: automation proposal / approval flow (spec 8.2). Ties R8a (score/eligibility/
   class) + the durable ledger + AT-1 (permit) into propose -> PendingReview ->
   owner-approve -> TriggerSpec draft + one-shot Register permit. Nothing is
   auto-applied (I-16); the draft starts Enabled->False.
   ============================================================ *)

Options[SourceVault`SourceVaultRoutineProposeAutomation] = {
  "Threshold" -> 0.85, "MinSample" -> 10, "IP5Wired" -> False};
SourceVault`SourceVaultRoutineProposeAutomation[routineId_String, spec_Association,
    traces_List, OptionsPattern[]] := Module[
  {elig, score, recert, propId, fact},
  elig = SourceVault`SourceVaultRoutineAutomationEligibility[spec,
    "IP5Wired" -> OptionValue["IP5Wired"]];
  If[!TrueQ[elig["Eligible"]],
    Return[<|"Status" -> "Rejected", "Reason" -> "NotEligible",
      "Blockers" -> elig["Blockers"]|>]];
  score = SourceVault`SourceVaultRoutineFormulaicScore[traces,
    "Threshold" -> OptionValue["Threshold"], "MinSample" -> OptionValue["MinSample"]];
  If[!TrueQ[score["Candidate"]],
    Return[<|"Status" -> "Rejected", "Reason" -> "NotCandidate",
      "Score" -> score["Score"], "SampleSize" -> score["SampleSize"]|>]];
  recert = SourceVault`SourceVaultRoutineRecertificationClass[spec];
  propId = "prop-" <> iSVRtnULID[];
  fact = <|"FactKind" -> "AutomationProposal", "ProposalId" -> propId,
    "RoutineId" -> routineId, "StableId" -> "rtn:" <> routineId,
    "Score" -> N[score["Score"]], "SampleSize" -> score["SampleSize"],
    "MaxState" -> elig["MaxState"], "RecertClass" -> recert["Class"],
    "TTLDays" -> recert["TTLDays"], "State" -> "PendingReview"|>;
  With[{r = SourceVault`SourceVaultRoutineLedgerAppend[fact]},
    If[MatchQ[r, _Failure], Return[r]]];
  <|"Status" -> "PendingReview", "ProposalId" -> propId, "Score" -> N[score["Score"]],
    "MaxState" -> elig["MaxState"], "RecertClass" -> recert["Class"]|>];
SourceVault`SourceVaultRoutineProposeAutomation[___] :=
  Failure["NBRoutineBadArgs", <|"MessageTemplate" -> "Bad ProposeAutomation args."|>];

Options[SourceVault`SourceVaultRoutineAutomationProposals] = {"State" -> All};
SourceVault`SourceVaultRoutineAutomationProposals[OptionsPattern[]] := Module[
  {evs, byId = <||>, st = OptionValue["State"], out},
  evs = SourceVault`SourceVaultRoutineLedgerEvents[];
  Do[Module[{fk = Lookup[e, "FactKind", ""], pid = Lookup[e, "ProposalId", Missing[]]},
    If[StringQ[pid],
      Which[
        fk === "AutomationProposal", byId[pid] = e,
        fk === "AutomationReviewed" && KeyExistsQ[byId, pid],
          byId[pid] = Join[byId[pid], <|"State" -> Lookup[e, "Verdict", "Reviewed"],
            "ReviewedAt" -> Lookup[e, "At", Missing["None"]],
            "AuthorizationId" -> Lookup[e, "AuthorizationId", Missing["None"]]|>]]]],
    {e, evs}];
  out = Values[byId];
  If[StringQ[st], Select[out, Lookup[#, "State", ""] === st &], out]];

(* build a TriggerSpec draft from an owner-local automation spec (pure) *)
iSVRtnTriggerDraft[spec_, propId_, authId_, ttlDays_] := Module[{tid, expIso},
  tid = "autotrg-" <> StringTake[iSVRtnULID[], 12];
  expIso = DateString[DatePlus[Now, {ttlDays, "Day"}],
    "ISODateTime", TimeZone -> 0] <> "Z";
  <|"Type" -> "AutoTrigger", "SchemaVersion" -> "0.1", "TriggerId" -> tid,
    "Target" -> Lookup[spec, "Target",
      <|"TargetType" -> "PureComputation", "TargetId" -> Lookup[spec, "RoutineId", "noop"]|>],
    "Enabled" -> False,   (* owner must separately Enable (own permit + EnabledAudit) *)
    "Schedule" -> Lookup[spec, "Schedule", <|"Kind" -> "Alarm"|>],
    "Condition" -> Lookup[spec, "Condition", <||>],   (* IP-5 predicate wired here later *)
    "Owner" -> <|"Mode" -> "OwnerMachine"|>,
    "ExecutionPlacement" -> Lookup[spec, "ExecutionPlacement",
      <|"Mode" -> "EnvironmentIndependent"|>],
    "ExpiresAt" -> expIso,
    "CreatedBy" -> "RoutineAutomationProposal",
    "PromptSource" -> <|"ProposalId" -> propId, "ApprovedBy" -> "Owner",
      "AuthorizationId" -> authId|>,
    "EnabledAudit" -> {}|>];

Options[SourceVault`SourceVaultRoutineApproveAutomation] = {
  "OwnerAuthorization" -> False, "PermitMintFn" -> Automatic};
SourceVault`SourceVaultRoutineApproveAutomation[proposalId_String, spec_Association,
    OptionsPattern[]] := Module[
  {prop, recert, authId, draft, mintFn, permit, specHash, fact},
  If[!TrueQ[OptionValue["OwnerAuthorization"]],
    Return[Failure["NBRoutineOwnerAuthRequired",
      <|"MessageTemplate" -> "OwnerAuthorization->True is required to approve."|>]]];
  prop = SelectFirst[SourceVault`SourceVaultRoutineAutomationProposals[],
    Lookup[#, "ProposalId", ""] === proposalId &, Missing["None"]];
  If[!AssociationQ[prop],
    Return[Failure["NBRoutineNoProposal",
      <|"MessageTemplate" -> "Proposal not found.", "ProposalId" -> proposalId|>]]];
  If[Lookup[prop, "State", ""] =!= "PendingReview",
    Return[Failure["NBRoutineProposalNotPending",
      <|"MessageTemplate" -> "Proposal is not PendingReview.",
        "State" -> Lookup[prop, "State", ""]|>]]];
  recert = SourceVault`SourceVaultRoutineRecertificationClass[spec];
  authId = "auth-" <> iSVRtnULID[];
  draft = iSVRtnTriggerDraft[spec, proposalId, authId, recert["TTLDays"]];
  (* mint a one-shot AT-1 Register permit bound to the draft (weak autotrigger dep) *)
  mintFn = OptionValue["PermitMintFn"];
  If[mintFn === Automatic,
    mintFn = If[Length[Names["SourceVault`SourceVaultAutoTriggerMintPermit"]] > 0 &&
        Length[Names["SourceVault`SourceVaultAutoTriggerSpecHash"]] > 0,
      Function[dr, Module[{sh = SourceVault`SourceVaultAutoTriggerSpecHash[dr]},
        SourceVault`SourceVaultAutoTriggerMintPermit[
          <|"SpecHash" -> sh, "ProposalId" -> proposalId, "Action" -> "Register"|>,
          "OwnerAuthorization" -> True]]],
      Missing["NoAutoTrigger"]]];
  permit = If[MissingQ[mintFn], Missing["NoAutoTrigger"],
    Quiet@Check[mintFn[draft], Missing["MintFailed"]]];
  fact = <|"FactKind" -> "AutomationReviewed", "ProposalId" -> proposalId,
    "Verdict" -> "Approved", "AuthorizationId" -> authId,
    "TriggerId" -> draft["TriggerId"]|>;
  With[{r = SourceVault`SourceVaultRoutineLedgerAppend[fact]},
    If[MatchQ[r, _Failure], Return[r]]];
  <|"Status" -> "Approved", "ProposalId" -> proposalId, "AuthorizationId" -> authId,
    "Draft" -> draft, "Permit" -> permit|>];
SourceVault`SourceVaultRoutineApproveAutomation[___] :=
  Failure["NBRoutineBadArgs", <|"MessageTemplate" -> "Bad ApproveAutomation args."|>];

Options[SourceVault`SourceVaultRoutineRejectAutomation] = {"Reason" -> "OwnerRejected"};
SourceVault`SourceVaultRoutineRejectAutomation[proposalId_String, OptionsPattern[]] := Module[
  {fact},
  fact = <|"FactKind" -> "AutomationReviewed", "ProposalId" -> proposalId,
    "Verdict" -> "Rejected", "Reason" -> OptionValue["Reason"]|>;
  With[{r = SourceVault`SourceVaultRoutineLedgerAppend[fact]},
    If[MatchQ[r, _Failure], Return[r]]];
  <|"Status" -> "Rejected", "ProposalId" -> proposalId|>];
SourceVault`SourceVaultRoutineRejectAutomation[___] :=
  Failure["NBRoutineBadArgs", <|"MessageTemplate" -> "Bad RejectAutomation args."|>];

End[];

EndPackage[];
