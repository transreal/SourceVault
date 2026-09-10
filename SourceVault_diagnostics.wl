(* ::Package:: *)

(* ============================================================
   SourceVault_diagnostics.wl

   SourceVault cross-package diagnostics / SIEM layer.
   Phase 0 minimal core (spec: sourcevault_auto_trigger_scheduler_spec
   v0.1, section 2.2 / 3.x / "Phase 0: diagnostics minimal core").

   This file is the SIEM *collector / store / doctor* layer. It does
   NOT own domain diagnostics; producer packages (NBAccess, claudecode,
   Orchestrator, service manager, auto-trigger) own their probes and
   emit into this sink ONLY when it is present (rule 11: producers keep
   no hard dependency on SourceVault).

   Phase 0 scope implemented here:
     - sink availability weak detection
     - structured append-only diagnostics log
     - Wolfram license capacity probe (measured, not declared):
         $LicenseProcesses / $MaxLicenseProcesses / $MaxLicenseSubprocesses
     - kernel process topology classification (Windows CIM, best-effort)
     - reclaimable-capacity detection (duplicate MCP-server kernels)
     - SourceVaultSystemDoctor: aggregate license + reclaimable +
       existing service-manager health into OK/Degraded/Failing
     - machine-local heartbeat (per-machine path, atomic write)
     - minimal status / panel

   Deferred to later increments: probe registry fan-out to all
   producers, escalation / mail channel, aggregator rollup / failover,
   Wolfram Cloud comms, comprehensive-doctor auto-trigger workflow.

   Design constraints honoured (spec 2.2 / 2.3 / rule 11 / rule 30):
     - NOT an independent package. Extension of the SourceVault` context,
       Get[]-loadable. Loads standalone for verification.
     - No Needs["ClaudeRuntime`"] / Needs["ClaudeOrchestrator`"].
       Producer probes are reached by public-symbol name only, weakly.
     - Loads even when producers / vault root are absent.
     - Idempotent: a repeated Get[] re-defines cleanly.
     - All-ASCII source (avoids the \:XXXX literal trap, rule 30 / #11).
       Japanese usage text deferred to a later bulk conversion.
   ============================================================ *)

BeginPackage["SourceVault`"];

(* ------------------------------------------------------------
   Idempotent guard.
   ------------------------------------------------------------ *)

Quiet[ClearAll[
  "SourceVault`$SourceVaultDiagnosticsVersion",
  "SourceVault`SourceVaultDiagnosticsSinkAvailableQ",
  "SourceVault`SourceVaultDiagnosticsRegisterProbe",
  "SourceVault`SourceVaultDiagnosticsListProbes",
  "SourceVault`SourceVaultShadowedSystemSymbols",
  "SourceVault`SourceVaultRepairShadowedSystemSymbols",
  "SourceVault`SourceVaultShadowWatchStart",
  "SourceVault`SourceVaultShadowWatchStop",
  "SourceVault`SourceVaultShadowWatchLog",
  "SourceVault`SourceVaultShadowScanFiles",
  "SourceVault`SourceVaultShadowSanitizeFile",
  "SourceVault`SourceVaultShadowSanitizeNotebook",
  "SourceVault`SourceVaultDiagnosticsLightweightDoctor",
  "SourceVault`SourceVaultDiagnosticsTick",
  "SourceVault`SourceVaultDiagnosticsStartTick",
  "SourceVault`SourceVaultDiagnosticsStopTick",
  "SourceVault`SourceVaultDiagnosticsEscalate",
  "SourceVault`SourceVaultDiagnosticsConfigureMail",
  "SourceVault`SourceVaultDiagnosticsMailConfig",
  "SourceVault`SourceVaultDiagnosticsLog",
  "SourceVault`SourceVaultDiagnosticsLicenseProbe",
  "SourceVault`SourceVaultDiagnosticsKernelProcessTopology",
  "SourceVault`SourceVaultDiagnosticsReclaimableCapacity",
  "SourceVault`SourceVaultSystemDoctor",
  "SourceVault`SourceVaultDiagnosticsMachineHeartbeat",
  "SourceVault`SourceVaultDiagnosticsStatus",
  "SourceVault`SourceVaultDiagnosticsPanel",
  "SourceVault`SourceVaultDiagnosticsStatusBand",
  "SourceVault`SourceVaultDiagnosticsRegisterMachine",
  "SourceVault`SourceVaultDiagnosticsMachineRegistry",
  "SourceVault`SourceVaultDiagnosticsReadHeartbeats",
  "SourceVault`SourceVaultDiagnosticsActiveAggregator",
  "SourceVault`SourceVaultDiagnosticsAggregatorRollup",
  "SourceVault`SourceVaultDiagnosticsCloudHeartbeat",
  "SourceVault`SourceVaultDiagnosticsCloudChannel",
  "SourceVault`SourceVaultDiagnosticsCloudSend",
  "SourceVault`SourceVaultDiagnosticsCloudListen",
  "SourceVault`SourceVaultDiagnosticsCloudStopListen",
  "SourceVault`SourceVaultDiagnosticsCloudInbox",
  "SourceVault`SourceVaultDiagnosticsCloudCommsStatus",
  "SourceVault`SourceVaultDiagnosticsCloudPeerLiveness",
  "SourceVault`SourceVaultDiagnosticsCloudConsume",
  "SourceVault`SourceVaultDiagnosticsIngestSpool",
  "SourceVault`$SourceVaultDiagIngestIntervalSeconds"
]];

$SourceVaultDiagnosticsVersion = "0.1-phase0";

(* ------------------------------------------------------------
   Usage (ASCII; full Japanese text deferred).
   ------------------------------------------------------------ *)

SourceVaultDiagnosticsSinkAvailableQ::usage =
  "SourceVaultDiagnosticsSinkAvailableQ[] returns True when the SourceVault \
diagnostics sink (this layer) is loaded. Producers test this (weakly) before \
emitting; if absent they no-op.";

SourceVaultDiagnosticsIngestSpool::usage =
  "SourceVaultDiagnosticsIngestSpool[] は producer per-process spool \
($UserBaseDirectory/ApplicationData/ClaudeRuntime/diag-spool/*.jsonl) の \
DiagnosticsEvent を正準 diagnostics-log へ転記する (hardening 05 Inc2)。\
呼び出しは service kernel の低頻度 hook からのみ (単一書き手原則)。\
offset sidecar (<file>.ingest.json) で差分読み・EventId dedup で冪等。\
消化済みの過去日 shard は削除。戻り値は件数集計。";

$SourceVaultDiagIngestIntervalSeconds::usage =
  "$SourceVaultDiagIngestIntervalSeconds は service ループの spool ingest 周期 (秒, 既定 60)。";

$SourceVaultDiagSpoolRoot::usage =
  "$SourceVaultDiagSpoolRoot は producer spool directory の上書き (既定 Automatic = \
$UserBaseDirectory/ApplicationData/ClaudeRuntime/diag-spool)。テストシーム。";

SourceVaultDiagnosticsPublish::usage =
  "SourceVaultDiagnosticsPublish[event] は診断 event の bus 入口 (issues spec v0.4 §4.2): \
canonical diagnostics-log へ記録し、issue DB へ弱結合 fan-out (machine-local outbox への \
enqueue のみ・登録/分析は writer 側 reconciler) する。mail/FE escalation は行わない \
(それは SourceVaultDiagnosticsEscalate = Publish + mail policy)。返り値に \
\"IssueSignalQueued\" を含む。issues 層自身の障害 event は再投入しない (reentrancy guard)。";

SourceVaultDiagnosticsLog::usage =
  "SourceVaultDiagnosticsLog[record_Association] appends a structured \
diagnostics record (reason code / component / severity / health / machine tag) \
to the machine-local append-only diagnostics log. Returns the stored record \
or a Failure when the vault root is unresolved.";

SourceVaultDiagnosticsLicenseProbe::usage =
  "SourceVaultDiagnosticsLicenseProbe[] measures the live Wolfram license \
capacity ($LicenseProcesses / $MaxLicenseProcesses / $MaxLicenseSubprocesses, \
$LicenseType) rather than trusting declared values. Returns an Association with \
ProcessSlotsFree and SubprocessSlotsFree.";

SourceVaultDiagnosticsKernelProcessTopology::usage =
  "SourceVaultDiagnosticsKernelProcessTopology[] enumerates running Wolfram \
kernel processes and classifies each (Service / MCPServer / FEKernel / Subkernel \
/ PlayerSandbox / FrontEndUI / Other). Windows best-effort via CIM; degrades to \
a name-only count elsewhere.";

SourceVaultDiagnosticsReclaimableCapacity::usage =
  "SourceVaultDiagnosticsReclaimableCapacity[] inspects the kernel topology for \
reclaimable process slots, primarily duplicate AgentTools MCP-server kernels \
that should collapse to a single shared gateway. Returns ReclaimableMCPKernels \
and a recommendation.";

SourceVaultSystemDoctor::usage =
  "SourceVaultSystemDoctor[opts] runs the Phase 0 cross-package health \
aggregation: license pool, reclaimable MCP capacity, and (weakly) existing \
service-manager health. Returns component-scoped health plus a GlobalHealth of \
\"OK\" | \"Degraded\" | \"Failing\". Read-only.";

SourceVaultDiagnosticsMachineHeartbeat::usage =
  "SourceVaultDiagnosticsMachineHeartbeat[opts] writes this machine's heartbeat \
(liveness + a light component snapshot) to a per-machine path so multi-PC \
aggregation avoids Dropbox write conflicts. Atomic write. Returns the record.";

SourceVaultDiagnosticsStatus::usage =
  "SourceVaultDiagnosticsStatus[opts] returns a compact status Association \
(version, sink, license summary, reclaimable summary, last doctor global health).";

SourceVaultDiagnosticsPanel::usage =
  "SourceVaultDiagnosticsPanel[] returns a minimal human-readable panel (Grid) \
of the current Phase 0 diagnostics: license pool, kernel topology, reclaimable \
capacity, doctor health.";

SourceVaultDiagnosticsStatusBand::usage =
  "SourceVaultDiagnosticsStatusBand[] returns a compact framed status band (spec \
section 9.0) for the top of the workflow / saved-prompt lists: global SystemDoctor \
health, per-component health badges, a license process / subprocess pool summary, \
and (when machines are registered) a multi-machine rollup + active aggregator row.";

SourceVaultDiagnosticsRegisterMachine::usage =
  "SourceVaultDiagnosticsRegisterMachine[assoc] writes a machine-registry record \
(spec 3.4.1) to this/that machine's own per-machine path (conflict-free). Defaults: \
Roles {Worker}, AggregatorPriority 0, ExpectedAvailability AlwaysOn, Stale 300s / \
Failover 600s. Returns the record.";

SourceVaultDiagnosticsMachineRegistry::usage =
  "SourceVaultDiagnosticsMachineRegistry[] reads every registered machine's \
registry.json from the shared diagnostics/machines tree.";

SourceVaultDiagnosticsReadHeartbeats::usage =
  "SourceVaultDiagnosticsReadHeartbeats[] reads each machine's registry + heartbeat \
and returns per-machine liveness (OK | Stale | OfflineOrSleeping | Failing | \
NoHeartbeat), honoring ExpectedAvailability so an Intermittent laptop going stale \
is OfflineOrSleeping, not Failing. Cross-machine age uses heartbeat monotonic \
seconds (subject to clock skew).";

SourceVaultDiagnosticsActiveAggregator::usage =
  "SourceVaultDiagnosticsActiveAggregator[] selects the active aggregator: the \
fresh AggregatorCandidate with the highest AggregatorPriority, plus standby \
candidates.";

SourceVaultDiagnosticsAggregatorRollup::usage =
  "SourceVaultDiagnosticsAggregatorRollup[] reads all machine heartbeats and \
returns a global rollup (worst-of health, per-machine liveness, problem machines, \
active aggregator). Read-only; the shared rollup file is written only by the owner \
maintenance task.";

SourceVaultDiagnosticsCloudHeartbeat::usage =
  "SourceVaultDiagnosticsCloudHeartbeat[opts] reports Wolfram Cloud comms health \
and (opt \"Send\"->True) sends a Heartbeat message over the coordination channel. \
If not $CloudConnected it returns Channel->Unavailable with \
Fallback->SourceVaultPolling, so coordination never hard-depends on the cloud.";

SourceVaultDiagnosticsCloudChannel::usage =
  "SourceVaultDiagnosticsCloudChannel[] ensures and returns the shared Wolfram \
Cloud coordination ChannelObject (all machines on the same Wolfram account share \
it). Returns Available->False with the polling fallback when not cloud-connected.";

SourceVaultDiagnosticsCloudSend::usage =
  "SourceVaultDiagnosticsCloudSend[message_Association] ChannelSends message \
(enriched with this MachineTag / AtUTC / Type) over the coordination channel for \
inter-machine heartbeat / wakeup / negotiation. No-op fallback when offline.";

SourceVaultDiagnosticsCloudListen::usage =
  "SourceVaultDiagnosticsCloudListen[] starts (idempotently) a ChannelListen on \
the coordination channel; incoming packets are recorded to a bounded inbox as \
DATA ONLY (message content is never evaluated) and deduped by MessageID.";

SourceVaultDiagnosticsCloudStopListen::usage =
  "SourceVaultDiagnosticsCloudStopListen[] removes this session's channel listener.";

SourceVaultDiagnosticsCloudInbox::usage =
  "SourceVaultDiagnosticsCloudInbox[opts] returns received channel messages \
(MessageID / FromWolframID / FromMachineTag / Type / Message / ReceivedAtUTC). \
Options: \"Type\"->All, \"MaxItems\"->All.";

SourceVaultDiagnosticsCloudCommsStatus::usage =
  "SourceVaultDiagnosticsCloudCommsStatus[] reports cloud-connected state, channel \
name, whether our listener is still alive (watchdog), and inbox count.";

SourceVaultDiagnosticsCloudPeerLiveness::usage =
  "SourceVaultDiagnosticsCloudPeerLiveness[] derives per-peer liveness from the \
latest cloud Heartbeat message received from each machine tag (OK if within \
$iSVDiagCloudPeerStaleSeconds, else Stale). SourceVaultDiagnosticsAggregatorRollup \
folds this in so a peer seen over the cloud channel is counted live even when its \
Dropbox-synced file heartbeat lags.";

SourceVaultDiagnosticsCloudConsume::usage =
  "SourceVaultDiagnosticsCloudConsume[] is the SAFE inbox consumer: returns peer \
heartbeats (data) and, if any Wakeup messages were received, sets a wakeup flag - \
it never evaluates cloud message content. A caller may, on WakeupRequested, run \
its own local tick and reset the flag.";

SourceVaultDiagnosticsRegisterProbe::usage =
  "SourceVaultDiagnosticsRegisterProbe[id_String, probeFn_] registers a producer \
health probe under id. probeFn is called (0-arg) by SourceVaultSystemDoctor and \
must return either a health string, an Association with a \"Health\" key, or an \
Association of component-name -> <|\"Health\"->...|>. Re-registering an id \
replaces it. The registry survives a repeated Get[] of this file (producers \
register at their own load time, weakly). Returns the id.";

SourceVaultDiagnosticsListProbes::usage =
  "SourceVaultDiagnosticsListProbes[] returns the list of registered diagnostics \
probe ids.";

SourceVaultShadowedSystemSymbols::usage =
  "SourceVaultShadowedSystemSymbols[] lists symbols that shadow a System` symbol \
in this kernel: a symbol Ctx`Name (Ctx != System`) with the same short name as a \
built-in, where Ctx precedes System` on $ContextPath ($ContextPath is searched in \
order; $Context / Global` (last) never shadows built-ins), so that a notebook's \
`Name` resolves to Ctx`Name (shown red in the Front End) and the built-in option / \
function silently stops working. Typical cause: a qualified \
reference such as GitHubREST`MaxItems written in another package, which CREATES \
that symbol on parse (broke Dataset[..., MaxItems -> ...]). Returns a list of \
<|\"Name\", \"Context\", \"Active\", \"Defined\"|> (empty when healthy; \"Defined\" \
False means an empty accidental symbol). Options: \"Contexts\" -> Automatic | {ctx..}; \
\"IncludeInactive\" -> True also lists same-name symbols in contexts after System`. \
Registered as diagnostics probe \"system-symbol-shadow\" (Degraded when non-empty). \
Fix = remove the qualified reference in source, then either restart the kernel or \
run SourceVaultRepairShadowedSystemSymbols[] (no restart needed).";

SourceVaultRepairShadowedSystemSymbols::usage =
  "SourceVaultRepairShadowedSystemSymbols[] removes (Remove[]) the accidental \
EMPTY symbols currently shadowing System` built-ins (as listed by \
SourceVaultShadowedSystemSymbols[]), so the built-ins work again WITHOUT a kernel \
restart (e.g. Dataset[..., MaxItems -> ...] and the red Front End coloring recover \
on the next evaluation). Symbols that carry definitions are kept and reported \
under \"KeptDefined\" unless \"IncludeDefined\" -> True. \"IncludeInactive\" -> True \
also removes the EMPTY same-name symbols in contexts after System` on the path \
(Global` etc.: harmless for the built-in, but still colored red by the Front End). \
Returns <|\"Removed\", \"KeptDefined\", \"Failed\"|>. Repair alone does not fix the \
ORIGIN: check SourceVaultShadowWatchLog[] (\"File\" / \"Stack\") for the creating \
file or code path and remove the qualified Ctx`Name reference there -- or \
rewrite the persisted cache (WXF / Put file) that carries the symbol: a cache \
written while a shadow was active re-creates it on every load.";

SourceVaultShadowWatchStart::usage =
  "SourceVaultShadowWatchStart[] installs a $NewSymbol hook that catches the \
CREATION of a symbol that IMMEDIATELY shadows a System` built-in: same short \
name as a built-in, created in a context that precedes System` on the current \
$ContextPath (the system-symbol-shadow accident, e.g. a qualified \
GitHubREST`MaxItems reference in LLM-generated code evaluated at runtime). \
Each hit is recorded in SourceVaultShadowWatchLog[] with the creating file \
($InputFileName; empty = interactive/runtime evaluation) plus the evaluation-stack \
heads at that moment (\"Stack\": Import/BinaryDeserialize/Get of a persisted cache, \
ToExpression of generated code, the package function that ran it) and raises the \
SourceVaultShadowWatchStart::sysshadow warning immediately, so the origin is \
attributed at the moment it happens instead of being discovered later by the \
probe. Creations in Private` / Global` / off-path contexts stay silent (WL's \
own paclets create System-named symbols in internal off-path contexts during \
load; those never shadow). Auto-installed at load when $NewSymbol is free; \
returns \"Installed\" | \"AlreadyInstalled\" | \"SkippedForeignNewSymbolHook\" \
(an unrelated existing $NewSymbol hook is never clobbered).";

SourceVaultShadowScanFiles::usage =
  "SourceVaultShadowScanFiles[path | {paths..}] scans notebooks / package files / \
Put and WXF caches (directories recurse over *.nb, *.m, *.wl, *.wls, *.wxf, *.mx) \
for PERSISTED shadow symbols: fully qualified tokens Ctx`Name whose short name is a \
System` built-in (e.g. 'GitHubREST`MaxItems' inside a Dataset output cell that was \
evaluated while that shadow was active). Byte-level token search: nothing is evaluated \
and no symbol is created. Returns a list of <|\"File\", \"Symbol\", \"Context\", \"Name\", \
\"Count\", \"Active\"|>; \"Active\" -> True means the context precedes System` on the \
CURRENT $ContextPath, i.e. loading / rendering that file re-creates a live shadow \
(the root cause of the recurring MaxItems shadow, 2026-09-09: the Front End sends the \
embedded expression to the kernel each time it renders the stored output). Inactive hits \
(OutputSizeLimit`Skeleton, ...) are WL internals and harmless. Option \"Names\" -> \
{short names} restricts the search.";

SourceVaultShadowSanitizeFile::usage =
  "SourceVaultShadowSanitizeFile[file] rewrites the persisted shadow tokens found by \
SourceVaultShadowScanFiles in file: Ctx`Name -> Name in text files (.nb / .m / .wl / \
.wls, byte-exact except for the tokens), or a length-aware token rewrite of the WXF \
byte stream for a .wxf cache (verified by re-import; compressed WXF is not supported). A backup <file>.shadowbak-<timestamp> is \
written first (\"Backup\" -> False to skip). Only ACTIVE tokens are rewritten by \
default (\"Contexts\" -> Automatic); pass \"Contexts\" -> {ctx..} to name the \
contexts explicitly (e.g. in a headless kernel where github.wl is not loaded) or All. \
A notebook that is open in the Front End is refused (Failure \"NotebookOpen\"): the \
Front End would overwrite the file on save -- use SourceVaultShadowSanitizeNotebook for \
those. .mx (DumpSave) files cannot be rewritten (Failure \"Unsupported\"). Returns \
<|\"File\", \"Replaced\" -> <|token -> count|>, \"Backup\"|>.";

SourceVaultShadowSanitizeNotebook::usage =
  "SourceVaultShadowSanitizeNotebook[nbObject] (or [] for EvaluationNotebook[]) \
sanitizes an OPEN notebook in place through the Front End: every cell whose stored \
expression contains an active persisted shadow symbol (typically a Dataset output \
cell holding \"Meta\" -> <|GitHubREST`MaxItems -> ...|>) is rewritten with the \
System` symbol (NotebookRead / NotebookWrite), then the kernel is repaired \
(SourceVaultRepairShadowedSystemSymbols). Save the notebook afterwards. The scan works \
on the in-memory notebook, so unsaved poisoned outputs are covered too. Returns \
<|\"Notebook\", \"Cells\" -> rewritten count, \"Symbols\"|>. Options: \"Contexts\", \"Names\" \
as in SourceVaultShadowSanitizeFile.";

SourceVaultShadowWatchStop::usage =
  "SourceVaultShadowWatchStop[] disables the shadow watch and releases the \
$NewSymbol hook (only when it is ours).";

SourceVaultShadowWatchLog::usage =
  "SourceVaultShadowWatchLog[] returns the shadow-watch hits recorded in this \
kernel: a list of <|\"Symbol\", \"File\", \"Date\"|> (newest last, capped). \
\"File\" -> \"\" means the symbol was created by interactive / runtime evaluation \
(e.g. LLM-generated code), not by loading a package file.";

SourceVaultDiagnosticsLightweightDoctor::usage =
  "SourceVaultDiagnosticsLightweightDoctor[] runs a cheap doctor: license probe + \
service health + registered probes, but SKIPS the kernel-topology CIM probe \
(no shell-out). Suitable for the shared polling tick. = \
SourceVaultSystemDoctor[\"IncludeTopology\" -> False].";

SourceVaultDiagnosticsTick::usage =
  "SourceVaultDiagnosticsTick[] is the lightweight body called by the shared \
polling tick. Throttled (default 60s); each run writes a lightweight machine \
heartbeat (no topology), releases stray vault file streams left open by \
aborted writes (SourceVaultReleaseFileStreams; open handles block Dropbox sync \
and cause conflicted copies), and emits DoctorStale when the comprehensive \
doctor has not run within its freshness window. Never spawns a kernel or \
touches the Front End. Returns a short status. Safe to call manually.";

SourceVaultDiagnosticsStartTick::usage =
  "SourceVaultDiagnosticsStartTick[opts] registers SourceVaultDiagnosticsTick on \
claudecode's shared polling base (ClaudeRegisterPollingTick), weakly: a no-op when \
claudecode is absent. Opt-in (not started on load). Option \"IntervalSeconds\" \
(default 60) throttles the body. It does NOT create its own ScheduledTask \
(rule 95).";

SourceVaultDiagnosticsStopTick::usage =
  "SourceVaultDiagnosticsStopTick[] unregisters the lightweight diagnostics tick \
from the shared polling base.";

SourceVaultDiagnosticsEscalate::usage =
  "SourceVaultDiagnosticsEscalate[event_Association] applies the escalation \
policy to a diagnostics event: it always records the event, and for High / \
Critical / Failing events (subject to a dedup window) it routes a notification. \
When the Front End is present the event is recorded for the status-band / \
message-window reader and mail is treated as a deferred fallback; otherwise mail \
is the primary channel. Mail is DRY-RUN by default (records intent only, no SMTP) \
until SourceVaultDiagnosticsConfigureMail enables real sending. The mail body is \
cloud-safe metadata only (reason code / component / machine / time / SummaryURI); \
no raw error text or private data. Returns a routing summary.";

SourceVaultDiagnosticsConfigureMail::usage =
  "SourceVaultDiagnosticsConfigureMail[config_Association] sets and persists the \
diagnostics notification-mail config to vault config (config/diagnostics-mail.json) \
so the recipient is NOT hardcoded in source (rule 03). Keys: \"Recipient\" \
(operator's own fixed address), \"Enabled\" (default False; gates real SMTP send), \
\"DedupWindowSeconds\". Returns the effective config.";

SourceVaultDiagnosticsMailConfig::usage =
  "SourceVaultDiagnosticsMailConfig[] returns the effective notification-mail \
config (Recipient / Enabled / DedupWindowSeconds / Source).";

Begin["`Private`"];

(* ------------------------------------------------------------
   Local helpers.
   ------------------------------------------------------------ *)

iSVDiagUTCNow[] :=
  Quiet @ Check[
    DateString[{"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute",
       ":", "Second", "Z"}, TimeZone -> 0],
    "unknown"];

iSVDiagMachineTag[] :=
  StringReplace[ToString[$MachineName],
    Except[LetterCharacter | DigitCharacter | "-" | "_"] .. -> "-"];

(* vault root via the SourceVault core accessor, guarded so this file
   still loads / probes when run standalone. *)
iSVDiagRoot[] :=
  Module[{r},
    r = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed];
    If[StringQ[r] && r =!= "", r, $Failed]];

iSVDiagMachineDir[] :=
  Module[{root = iSVDiagRoot[]},
    If[root === $Failed, $Failed,
      FileNameJoin[{root, "diagnostics", "machines", iSVDiagMachineTag[]}]]];

iSVDiagEnsureDir[dir_String] :=
  Quiet @ Check[
    If[!DirectoryQ[dir], CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    dir, $Failed];

iSVDiagAtomicWrite[path_String, text_String] :=
  Module[{tmp = path <> ".tmp", dir = DirectoryName[path]},
    If[iSVDiagEnsureDir[dir] === $Failed, Return[$Failed]];
    Quiet @ Check[
      Export[tmp, text, "Text", CharacterEncoding -> "UTF-8"];
      If[FileExistsQ[path], DeleteFile[path]];
      RenameFile[tmp, path];
      path,
      $Failed]];

(* compact (single-line) JSON: required for the append-only JSONL log
   where each record must occupy exactly one line. *)
iSVDiagToJSON[assoc_] :=
  Quiet @ Check[Developer`WriteRawJSONString[assoc, "Compact" -> True],
    Quiet @ Check[ExportString[assoc, "RawJSON", "Compact" -> True], "{}"]];

(* weak existence check for a producer symbol: trap #18 safe (do not
   use ValueQ on a function symbol). *)
iSVDiagSymbolExistsQ[name_String] :=
  Length[Names[name]] > 0;

iSVDiagCall[name_String, args___] :=
  If[iSVDiagSymbolExistsQ[name],
    Quiet @ Check[ToExpression[name][args], $Failed],
    Missing["ProducerAbsent"]];

(* ------------------------------------------------------------
   Sink availability.
   ------------------------------------------------------------ *)

SourceVaultDiagnosticsSinkAvailableQ[] := True;

(* ------------------------------------------------------------
   Probe registry. Producers register their own health probes here
   (pull model, rule 11). Default-once so a repeated Get[] of this
   file does not wipe producer registrations.
   ------------------------------------------------------------ *)

If[!ValueQ[$iSVDiagProbes], $iSVDiagProbes = <||>];

(* default-once tick / freshness state (survives a repeated Get[]) *)
If[!ValueQ[$iSVDiagLastComprehensiveAt], $iSVDiagLastComprehensiveAt = Missing["Never"]];
If[!ValueQ[$iSVDiagLastTickTime], $iSVDiagLastTickTime = Missing["Never"]];
If[!ValueQ[$iSVDiagLastTickResult], $iSVDiagLastTickResult = <||>];
$iSVDiagTickKey = "sourcevault-diagnostics-lightweight";
(* comprehensive doctor freshness window: 24h + 1h grace *)
$iSVDiagComprehensiveStaleSeconds = 90000;

(* escalation / notification-mail state (default-once). Recipient is NEVER
   hardcoded here (rule 03); it is loaded from vault config. *)
If[!ValueQ[$iSVDiagEscalationState], $iSVDiagEscalationState = <||>];
If[!ValueQ[$iSVDiagMailRecipient], $iSVDiagMailRecipient = Missing["Unconfigured"]];
If[!ValueQ[$iSVDiagMailEnabled], $iSVDiagMailEnabled = False];
If[!ValueQ[$iSVDiagMailConfigLoaded], $iSVDiagMailConfigLoaded = False];
If[!ValueQ[$iSVDiagDedupWindowSeconds], $iSVDiagDedupWindowSeconds = 1800];

SourceVaultDiagnosticsRegisterProbe[id_String, probeFn_] :=
  ($iSVDiagProbes[id] = probeFn; id);

SourceVaultDiagnosticsListProbes[] := Keys[$iSVDiagProbes];

(* normalize a probe result into a component-name -> <|"Health"->...|> map *)
iSVDiagNormalizeProbeResult[id_String, res_] :=
  Which[
    StringQ[res],
      <|id -> <|"Health" -> iSVDiagNormalizeHealth[res]|>|>,
    AssociationQ[res] && KeyExistsQ[res, "Health"],
      <|Lookup[res, "Component", id] ->
          <|"Health" -> iSVDiagNormalizeHealth[res],
            "Detail" -> KeyDrop[res, {"Component"}]|>|>,
    AssociationQ[res] && AllTrue[Values[res], AssociationQ],
      Association @ KeyValueMap[
        Function[{k, v}, k -> <|"Health" -> iSVDiagNormalizeHealth[v]|>], res],
    AssociationQ[res],
      <|id -> <|"Health" -> "OK", "Detail" -> res|>|>,
    True,
      <|id -> <|"Health" -> "Degraded", "ReasonCode" -> "ProbeBadResult"|>|>];

(* run every registered probe defensively; a throwing / slow / absent
   probe yields a Degraded "ProbeError" component, never crashes the doctor. *)
iSVDiagRunRegisteredProbes[] :=
  Module[{out = <||>},
    KeyValueMap[
      Function[{id, fn},
        Module[{res},
          (* defensive against message / $Failed / Abort / Throw / timeout:
             Quiet (messages), CheckAbort (Abort), Catch (any Throw tag),
             TimeConstrained (slow). Quiet@Check alone does NOT catch Throw. *)
          res = Quiet @ CheckAbort[
            Catch[TimeConstrained[fn[], 15, $iSVDiagProbeTimeout],
              _, ($iSVDiagProbeError &)],
            $iSVDiagProbeError];
          If[res === $Failed, res = $iSVDiagProbeError];
          out = Join[out,
            Which[
              res === $iSVDiagProbeTimeout,
                <|id -> <|"Health" -> "Degraded", "ReasonCode" -> "ProbeTimeout"|>|>,
              res === $iSVDiagProbeError,
                <|id -> <|"Health" -> "Degraded", "ReasonCode" -> "ProbeError"|>|>,
              True,
                iSVDiagNormalizeProbeResult[id, res]]]]],
      $iSVDiagProbes];
    out];

(* ------------------------------------------------------------
   System-symbol shadow probe (2026-08-18).
   A symbol Ctx`Name (Ctx != System`) whose short name equals a System`
   symbol shadows the built-in when Ctx precedes System` on $ContextPath:
   a notebook's `Name` then resolves to Ctx`Name (red in the FE) and
   built-in options / functions silently stop working.
   Usual cause: a qualified reference Ctx`Name written from ANOTHER
   package (e.g. GitHubREST`MaxItems in SourceVault_mcp.wl), which
   creates the symbol at parse time although Ctx never defines it.
   Read-only; touches only Names / $ContextPath.
   ------------------------------------------------------------ *)

(* short names of the symbols living directly in ctx. Names[] returns a
   short name when the symbol is reachable via $ContextPath and a qualified
   name otherwise (and may include sub-context symbols); normalize both and
   keep only symbols whose context is exactly ctx. Vectorized: this runs on
   the 60 s lightweight tick, so per-name Module/Function calls are avoided. *)
iSVDiagContextShortNames[ctx_String] :=
  Module[{names = Quiet @ Check[Names[ctx <> "*"], {}], short, qual, len},
    If[!ListQ[names] || names === {}, Return[{}]];
    len = StringLength[ctx];
    short = Pick[names, StringFreeQ[names, "`"]];
    qual = Pick[names, StringStartsQ[names, ctx]];
    qual = StringDrop[qual, len];
    qual = Pick[qual, StringFreeQ[qual, "`"]];
    DeleteDuplicates @ Join[short, qual]];

(* does the (fully qualified) symbol carry any definition? False for an
   accidental empty symbol created by a mere qualified reference. *)
iSVDiagSymbolDefinedQ[full_String] :=
  Quiet @ Check[
    ToExpression[full, InputForm,
      Function[s,
        TrueQ[Length[OwnValues[s]] + Length[DownValues[s]] + Length[SubValues[s]] +
          Length[UpValues[s]] + Length[Options[s]] > 0], HoldAll]],
    False];

Options[SourceVaultShadowedSystemSymbols] =
  {"Contexts" -> Automatic, "IncludeInactive" -> False};

(* Lookup rule (measured, WL 15.0): a short name is resolved by walking
   $ContextPath IN ORDER; $Context is consulted only when nothing on the
   path matches (and is where new symbols are created). Hence a same-name
   symbol shadows the built-in iff its context precedes System` on
   $ContextPath; Global` (last) or an unlisted Private` context never does. *)
SourceVaultShadowedSystemSymbols[OptionsPattern[]] :=
  Module[{path = $ContextPath, sysNames, ctxs, sysPos, out},
    sysNames = DeleteDuplicates[Last[StringSplit[#, "`"]] & /@ Names["System`*"]];
    ctxs = Replace[OptionValue["Contexts"],
      Automatic :> DeleteDuplicates[Append[path, $Context]]];
    ctxs = DeleteCases[Select[Flatten[{ctxs}], StringQ], "System`"];
    sysPos = FirstPosition[path, "System`", {Infinity}][[1]];
    out = Flatten @ Map[
      Function[ctx, Module[{hits, pos, active},
        hits = Intersection[iSVDiagContextShortNames[ctx], sysNames];
        pos = FirstPosition[path, ctx, {Infinity}][[1]];
        active = TrueQ[pos < sysPos];
        Map[<|"Name" -> #, "Context" -> ctx, "Active" -> active,
              "Defined" -> iSVDiagSymbolDefinedQ[ctx <> #]|> &, hits]]],
      ctxs];
    If[TrueQ[OptionValue["IncludeInactive"]], out, Select[out, TrueQ[#Active] &]]];

(* core probe: Degraded while any active shadow exists (fix source, restart
   the kernel). Registered here (not by a producer) because the symbol table
   is the kernel's own; re-registration on repeated Get[] just replaces.
   The scan walks the whole symbol table once per context (~0.6 s with the
   full package set), so the probe caches its result for 10 min, keyed on
   $ContextPath (a newly loaded package invalidates it at once); the public
   function itself always computes fresh. *)
If[!ValueQ[$iSVDiagShadowProbeCache], $iSVDiagShadowProbeCache = <||>];
$iSVDiagShadowProbeTTL = 600;

iSVDiagShadowProbeResult[] :=
  Module[{c = $iSVDiagShadowProbeCache, now = AbsoluteTime[], sh},
    If[AssociationQ[c] && Lookup[c, "Path", None] === $ContextPath &&
         NumberQ[Lookup[c, "At", None]] && now - c["At"] < $iSVDiagShadowProbeTTL,
      Return[c["Result"]]];
    sh = Quiet @ Check[SourceVaultShadowedSystemSymbols[], $Failed];
    $iSVDiagShadowProbeCache = <|"Path" -> $ContextPath, "At" -> now, "Result" -> sh|>;
    sh];

SourceVaultDiagnosticsRegisterProbe["system-symbol-shadow",
  Function[Module[{sh = iSVDiagShadowProbeResult[]},
    Which[
      sh === $Failed,
        <|"Health" -> "Degraded", "ReasonCode" -> "ProbeError"|>,
      sh === {},
        <|"Health" -> "OK", "Count" -> 0|>,
      True,
        <|"Health" -> "Degraded", "ReasonCode" -> "SystemSymbolShadowed",
          "Count" -> Length[sh],
          "Symbols" -> Map[#Context <> #Name &, sh]|>]]]];

(* ------------------------------------------------------------
   Shadow repair (2026-08-26): Remove[] the accidental empty
   shadow symbols in-place so built-ins recover without a kernel
   restart. Symbols with definitions are kept unless forced -- an
   accidental symbol created by a mere qualified reference carries
   no values at all, so removing only the empty ones is safe.
   ------------------------------------------------------------ *)

Options[SourceVaultRepairShadowedSystemSymbols] =
  {"IncludeDefined" -> False, "IncludeInactive" -> False};

SourceVaultRepairShadowedSystemSymbols[OptionsPattern[]] :=
  Module[{sh, incl = TrueQ[OptionValue["IncludeDefined"]],
      target, kept, removed = {}, failed = {}},
    (* "IncludeInactive": also the empty same-name symbols in contexts AFTER
       System` on the path (Global` etc.). Those never break the built-in but
       the Front End still colors the name red (duplicate on the path). *)
    sh = SourceVaultShadowedSystemSymbols[
      "IncludeInactive" -> TrueQ[OptionValue["IncludeInactive"]]];
    If[!ListQ[sh], Return[$Failed]];
    target = Select[sh, incl || !TrueQ[#Defined] &];
    kept = Select[sh, !incl && TrueQ[#Defined] &];
    Scan[
      Function[rec, Module[{full = rec["Context"] <> rec["Name"]},
        (* Remove / Unprotect are HoldAll: apply on the evaluated string
           (Remove @@ {full}); Remove[full] would remove the Module
           variable itself, not the named symbol *)
        Quiet @ Check[
          (Unprotect @@ {full}; Remove @@ {full}; AppendTo[removed, full]),
          AppendTo[failed, full]]]],
      target];
    $iSVDiagShadowProbeCache = <||>;  (* force a fresh probe scan *)
    <|"Removed" -> removed,
      "KeptDefined" -> Map[#Context <> #Name &, kept],
      "Failed" -> failed|>];

(* ------------------------------------------------------------
   Shadow watch (2026-08-26): $NewSymbol hook that attributes the
   accident at CREATION time. The 60 s probe above detects a shadow
   but cannot say where it came from; by then $InputFileName is
   long gone. The hook records file + time the moment a System-named
   symbol appears in a public non-System context -- including
   runtime evaluation of LLM-generated code, which a static source
   grep can never catch ($InputFileName == "" identifies that case).
   Private` contexts are skipped: package option keys living in
   Private` are harmless (never on $ContextPath) and number in the
   dozens; Global` (path tail) never shadows either.
   Cost: one hash lookup per new symbol; string tests only on hit.
   ------------------------------------------------------------ *)

SourceVaultShadowWatchStart::sysshadow =
  "New symbol `1` shadows a System` built-in (created in: `2`). The built-in \
(and its Front End coloring) is broken for this kernel until repaired. Run \
SourceVaultRepairShadowedSystemSymbols[] to fix the session, and remove the \
qualified reference at the recorded origin.";

If[!ListQ[$iSVDiagShadowWatchLog], $iSVDiagShadowWatchLog = {}];
$iSVDiagShadowWatchLimit = 200;

(* fires only when the creation is an IMMEDIATE shadow: ctx precedes System`
   on the current $ContextPath (probe semantics). WL's own paclet loads
   routinely create System-named symbols in internal contexts that are never
   on the path (System`Convert`HTMLDump`Monitor, FrontEnd`BoxFrame,
   Image`InteractiveDump`Echo, ... -- 10 such during a full init load);
   those never shadow anything and must stay silent. Load-time parse
   accidents whose context reaches the path only later are still caught by
   the 60 s probe above. *)
(* evaluation-stack heads at the moment of a hit (computed only on a hit):
   attributes runtime creations that carry no $InputFileName -- a WXF / Put
   cache written while a shadow was active re-creates the shadow symbol on
   every Import / BinaryDeserialize / Get (verified 2026-09-09: both
   serializers persist the full context, both fire $NewSymbol), ToExpression
   of LLM-generated code, Dynamic callbacks, ... Structural heads are
   dropped, consecutive duplicates collapsed, innermost frames kept. *)
$iSVDiagShadowStackNoise = {"System`CompoundExpression", "System`Module",
  "System`Block", "System`With", "System`If", "System`Which", "System`Set",
  "System`SetDelayed", "System`Function", "System`Map", "System`Scan",
  "System`Do", "System`Table", "System`List", "System`Rule", "System`AppendTo",
  "System`Quiet", "System`Check", "System`Association", "System`Part",
  "System`Catch", "System`Throw", "System`Apply", "System`Composition",
  "System`RuleDelayed", "System`Hold", "System`HoldComplete", "System`Sequence"};
$iSVDiagShadowStackLimit = 30;

iSVDiagShadowStackHeads[] :=
  Quiet @ Check[
    Module[{heads = Stack[], names},
      names = Map[If[Head[#] === Symbol, Context[#] <> SymbolName[#], ToString[#]] &,
        heads];
      names = DeleteCases[names, Alternatives @@ $iSVDiagShadowStackNoise];
      names = names //. {a___, x_, x_, b___} :> {a, x, b};
      Take[names, -Min[Length[names], $iSVDiagShadowStackLimit]]],
    {}];

iSVDiagShadowWatchHook[name_String, ctx_String] :=
  If[TrueQ[$iSVDiagShadowWatchOn] &&
       ctx =!= "System`" && ctx =!= "Global`" &&
       AssociationQ[$iSVDiagShadowWatchSysNames] &&
       KeyExistsQ[$iSVDiagShadowWatchSysNames, name] &&
       StringFreeQ[ctx, "Private`"],
    Module[{path = $ContextPath, cpos, spos},
      cpos = FirstPosition[path, ctx, {Infinity}][[1]];
      spos = FirstPosition[path, "System`", {Infinity}][[1]];
      If[cpos < spos,
        Block[{$iSVDiagShadowWatchOn = False},  (* reentrancy guard *)
          If[!ListQ[$iSVDiagShadowWatchLog], $iSVDiagShadowWatchLog = {}];
          AppendTo[$iSVDiagShadowWatchLog,
            <|"Symbol" -> ctx <> name,
              "File" -> If[StringQ[$InputFileName], $InputFileName, ""],
              "Stack" -> iSVDiagShadowStackHeads[],
              "Date" -> DateString[]|>];
          If[Length[$iSVDiagShadowWatchLog] > $iSVDiagShadowWatchLimit,
            $iSVDiagShadowWatchLog =
              Take[$iSVDiagShadowWatchLog, -$iSVDiagShadowWatchLimit]];
          $iSVDiagShadowProbeCache = <||>;
          Message[SourceVaultShadowWatchStart::sysshadow, ctx <> name,
            If[StringQ[$InputFileName] && $InputFileName =!= "",
              $InputFileName, "interactive/runtime evaluation"]]]]]];

SourceVaultShadowWatchStart[] := (
  If[!AssociationQ[$iSVDiagShadowWatchSysNames],
    $iSVDiagShadowWatchSysNames = AssociationMap[True &,
      DeleteDuplicates[Last[StringSplit[#, "`"]] & /@ Names["System`*"]]]];
  Which[
    $NewSymbol === iSVDiagShadowWatchHook,
      $iSVDiagShadowWatchOn = True; "AlreadyInstalled",
    ValueQ[$NewSymbol],
      "SkippedForeignNewSymbolHook",   (* never clobber an unrelated hook *)
    True,
      $iSVDiagShadowWatchOn = True;
      $NewSymbol = iSVDiagShadowWatchHook;
      "Installed"]);

SourceVaultShadowWatchStop[] := (
  $iSVDiagShadowWatchOn = False;
  If[$NewSymbol === iSVDiagShadowWatchHook, Unset[$NewSymbol]];
  "Stopped");

SourceVaultShadowWatchLog[] :=
  If[ListQ[$iSVDiagShadowWatchLog], $iSVDiagShadowWatchLog, {}];

(* auto-install (weak): a free $NewSymbol is taken, a foreign hook is left
   alone. Covers every kernel that loads the SourceVault chain, so the next
   runtime-created shadow is attributed instead of rediscovered blind. *)
Quiet @ SourceVaultShadowWatchStart[];

(* ------------------------------------------------------------
   Persisted-shadow scan / sanitize (2026-09-09).
   ROOT CAUSE of the recurring MaxItems shadow (8/18, 8/26, 9/9): a
   Dataset output cell evaluated while GitHubREST`MaxItems was active
   (2026-08-18) stores its display metadata with the FULLY QUALIFIED
   option symbol -- "Meta" -> <|GitHubREST`MaxItems -> {All, All}|> --
   inside the notebook file. Every time the Front End renders that
   output (opening the notebook, paging the table) the embedded
   expression is sent to the kernel, the symbol is re-created, and,
   github.wl being on $ContextPath, System`MaxItems is shadowed again.
   $InputFileName is empty on that path, so the source grep and the
   headless load-chain replay never see it. Put / WXF caches persist
   symbols the same way (verified: both keep the full context, both
   fire $NewSymbol on load).
   Scan = byte-level token search (nothing evaluated, no symbol created);
   sanitize = rewrite Ctx`Name -> Name in text files (closed notebooks,
   packages) or re-serialize WXF, always leaving a backup. Open
   notebooks go through the Front End (NotebookRead / NotebookWrite).
   Only ACTIVE tokens (context before System` on the current path) are
   rewritten by default: OutputSizeLimit`Skeleton and similar WL
   internals are legitimate and must stay.
   ------------------------------------------------------------ *)

$iSVDiagShadowTokenRegex = "(?<![A-Za-z0-9$`])(?:[A-Za-z0-9$]+`)+[A-Za-z0-9$]+";
$iSVDiagShadowScanPatterns = {"*.nb", "*.m", "*.wl", "*.wls", "*.wxf", "*.mx"};

(* System short-name table shared with the watch hook *)
iSVDiagShadowSysNameSet[] := (
  If[!AssociationQ[$iSVDiagShadowWatchSysNames],
    $iSVDiagShadowWatchSysNames = AssociationMap[True &,
      DeleteDuplicates[Last[StringSplit[#, "`"]] & /@ Names["System`*"]]]];
  $iSVDiagShadowWatchSysNames);

iSVDiagShadowNameSet[Automatic] := iSVDiagShadowSysNameSet[];
iSVDiagShadowNameSet[names_List] := AssociationMap[True &, Select[names, StringQ]];
iSVDiagShadowNameSet[_] := iSVDiagShadowSysNameSet[];

(* bytes <-> string by a Latin-1 round trip: every byte maps to exactly one
   character and back, so binary (WXF) and any text encoding scan alike and
   a text rewrite is written back byte-exact outside the replaced tokens. *)
iSVDiagShadowReadText[file_String] :=
  Quiet @ Check[ByteArrayToString[ReadByteArray[file], "ISO8859-1"], $Failed];

iSVDiagShadowWriteText[file_String, text_String] :=
  Module[{str = OpenWrite[file, BinaryFormat -> True]},
    BinaryWrite[str, StringToByteArray[text, "ISO8859-1"]];
    Close[str]];

iSVDiagShadowExpandPaths[paths_List] :=
  DeleteDuplicates @ Flatten @ Map[
    Function[p, Which[
      !StringQ[p], {},
      DirectoryQ[p], FileNames[$iSVDiagShadowScanPatterns, p, Infinity],
      FileExistsQ[p], {p},
      True, {}]],
    paths];

(* qualified-symbol tokens of one text. Text (.nb / .m / .wl): tokens are
   delimited by non-identifier characters. WXF ("8:" header): a symbol is
   "s" + length byte + name and the NEXT token's type byte (a letter) follows
   without any delimiter, so the text regex would read "MaxItemsf"; cut at
   the stored length instead. Compressed WXF ("8C:") is not scanned. *)
iSVDiagShadowTokens[text_String] :=
  If[StringStartsQ[text, "8:"],
    Select[
      Cases[StringCases[text,
          RegularExpression["s([\\x01-\\x7f])([A-Za-z0-9$`]+)"] :> {"$1", "$2"}],
        ({l_, sym_} /; StringLength[sym] >= First[ToCharacterCode[l]]) :>
          StringTake[sym, First[ToCharacterCode[l]]]],
      StringMatchQ[#, RegularExpression["(?:[A-Za-z0-9$]+`)+[A-Za-z0-9$]+"]] &],
    StringCases[text, RegularExpression[$iSVDiagShadowTokenRegex]]];

(* token scan of one text; label = file name (or "<notebook>") *)
iSVDiagShadowScanText[text_String, label_String, names_] :=
  Module[{sysNames = iSVDiagShadowNameSet[names], path = $ContextPath, sysPos, toks},
    sysPos = FirstPosition[path, "System`", {Infinity}][[1]];
    toks = iSVDiagShadowTokens[text];
    toks = Select[toks, Function[t, With[{parts = StringSplit[t, "`"]},
      KeyExistsQ[sysNames, Last[parts]] && First[parts] =!= "System"]]];
    Map[Function[pair, With[{tok = pair[[1]], name = Last[StringSplit[pair[[1]], "`"]]},
      With[{ctx = StringDrop[tok, -StringLength[name]]},
        <|"File" -> label, "Symbol" -> tok, "Context" -> ctx, "Name" -> name,
          "Count" -> pair[[2]],
          "Active" -> TrueQ[FirstPosition[path, ctx, {Infinity}][[1]] < sysPos]|>]]],
      Tally[toks]]];

Options[SourceVaultShadowScanFiles] = {"Names" -> Automatic};

SourceVaultShadowScanFiles[paths : (_String | {___String}), OptionsPattern[]] :=
  Module[{files = iSVDiagShadowExpandPaths[Flatten[{paths}]], names = OptionValue["Names"]},
    Flatten @ Map[
      Function[f, Module[{text = iSVDiagShadowReadText[f]},
        If[StringQ[text], iSVDiagShadowScanText[text, f, names], {}]]],
      files]];

iSVDiagShadowSelectTargets[hits_List, ctxs_] := Switch[ctxs,
  Automatic, Select[hits, TrueQ[#Active] &],
  All, hits,
  _, Select[hits, MemberQ[Flatten[{ctxs}], #Context] &]];

(* is the file open in the Front End? (its save would overwrite our rewrite) *)
iSVDiagShadowNotebookOpenQ[file_String] :=
  $FrontEnd =!= Null && TrueQ @ Quiet @ Check[
    AnyTrue[Notebooks[], Quiet @ Check[
      ExpandFileName[NotebookFileName[#]] === ExpandFileName[file], False] &], False];

iSVDiagShadowBackup[file_String] :=
  Module[{bak = file <> ".shadowbak-" <>
      DateString[{"Year", "Month", "Day", "Hour", "Minute", "Second"}]},
    CopyFile[file, bak, OverwriteTarget -> True]; bak];

(* whole-token replacement: never inside a longer identifier *)
iSVDiagShadowTokenRule[tok_String, name_String] :=
  RegularExpression["(?<![A-Za-z0-9$`])" <> StringReplace[tok, "$" -> "\\$"] <>
    "(?![A-Za-z0-9$`])"] -> name;

(* WXF: a symbol token is "s" + length byte + name, so rewrite the byte
   stream with the corrected length. This is done on the bytes, not via
   Import / ReplaceAll / Export: ReplaceAll never reaches Association KEYS
   (exactly where the poisoned option symbol lives) and Import would
   evaluate held code inside the cache. Names >= 128 bytes (2-byte varint)
   are not handled (never a System name). *)
iSVDiagShadowWXFTokenRules[targets_List] :=
  Map[Function[t,
      "s" <> FromCharacterCode[StringLength[t["Symbol"]]] <> t["Symbol"] ->
      "s" <> FromCharacterCode[StringLength[t["Name"]]] <> t["Name"]],
    Select[targets, StringLength[#Symbol] < 128 &]];

iSVDiagShadowRewriteWXFText[text_String, targets_List] :=
  StringReplace[text, iSVDiagShadowWXFTokenRules[targets]];

(* in-kernel expression rewrite through the same byte path: handles keys and
   held parts alike, evaluates nothing (BinarySerialize / BinaryDeserialize) *)
iSVDiagShadowReplaceSymbols[expr_, targets_List] :=
  Block[{$iSVDiagShadowWatchOn = False},
    BinaryDeserialize[StringToByteArray[
      iSVDiagShadowRewriteWXFText[
        ByteArrayToString[BinarySerialize[expr], "ISO8859-1"], targets],
      "ISO8859-1"]]];

iSVDiagShadowSanitizeWXF[file_String, targets_List] :=
  Module[{text = iSVDiagShadowReadText[file], check},
    If[!StringQ[text] || !StringStartsQ[text, "8:"], Return[$Failed]];
    iSVDiagShadowWriteText[file, iSVDiagShadowRewriteWXFText[text, targets]];
    (* verify: the rewritten cache must still deserialize. Not Check[]: a
       leftover shadow would fire ::sysshadow / ::shdw and Check would
       misread those as failure *)
    check = Block[{$iSVDiagShadowWatchOn = False}, Quiet @ Import[file, "WXF"]];
    If[check === $Failed, Return[$Failed]];
    SourceVaultRepairShadowedSystemSymbols[];
    True];

Options[SourceVaultShadowSanitizeFile] =
  {"Contexts" -> Automatic, "Backup" -> True, "Names" -> Automatic};

SourceVaultShadowSanitizeFile[file_String, OptionsPattern[]] :=
  Module[{hits, targets, ext, text, new, bak = None, counts, r},
    If[!FileExistsQ[file], Return[Failure["NotFound", <|"File" -> file|>]]];
    If[iSVDiagShadowNotebookOpenQ[file],
      Return[Failure["NotebookOpen", <|"MessageTemplate" ->
        "`1` is open in the Front End; use SourceVaultShadowSanitizeNotebook[nbObject] or close it first.",
        "MessageParameters" -> {file}, "File" -> file|>]]];
    hits = SourceVaultShadowScanFiles[file, "Names" -> OptionValue["Names"]];
    targets = iSVDiagShadowSelectTargets[hits, OptionValue["Contexts"]];
    If[targets === {},
      Return[<|"File" -> file, "Replaced" -> <||>, "Backup" -> None|>]];
    ext = ToLowerCase[FileExtension[file]];
    If[ext === "mx",
      Return[Failure["Unsupported", <|"MessageTemplate" ->
        "`1` is a DumpSave (.mx) file; regenerate it after repairing the kernel.",
        "MessageParameters" -> {file}, "File" -> file,
        "Symbols" -> targets[[All, "Symbol"]]|>]]];
    If[TrueQ[OptionValue["Backup"]], bak = iSVDiagShadowBackup[file]];
    counts = Association[(#Symbol -> #Count) & /@ targets];
    If[ext === "wxf",
      r = iSVDiagShadowSanitizeWXF[file, targets];
      If[r === $Failed,
        If[StringQ[bak], Quiet @ CopyFile[bak, file, OverwriteTarget -> True]];
        Return[Failure["WXFRewriteFailed", <|"File" -> file, "Backup" -> bak,
          "MessageTemplate" -> "`1`: rewritten WXF did not verify (compressed WXF is not supported); original restored from the backup.",
          "MessageParameters" -> {file}|>]]],
      text = iSVDiagShadowReadText[file];
      If[!StringQ[text],
        Return[Failure["ReadFailed", <|"File" -> file, "Backup" -> bak|>]]];
      new = StringReplace[text, iSVDiagShadowTokenRule[#Symbol, #Name] & /@ targets];
      iSVDiagShadowWriteText[file, new]];
    <|"File" -> file, "Replaced" -> counts, "Backup" -> bak|>];

Options[SourceVaultShadowSanitizeNotebook] = {"Contexts" -> Automatic, "Names" -> Automatic};

SourceVaultShadowSanitizeNotebook[opts : OptionsPattern[]] :=
  SourceVaultShadowSanitizeNotebook[EvaluationNotebook[], opts];

iSVDiagShadowWXFText[expr_] := ByteArrayToString[BinarySerialize[expr], "ISO8859-1"];

SourceVaultShadowSanitizeNotebook[nb_NotebookObject, OptionsPattern[]] :=
  Module[{hits, targets, needles, done = 0},
    Block[{$iSVDiagShadowWatchOn = False},   (* reading the cells re-creates the symbols; repaired below *)
      (* in-memory scan (covers outputs produced since the last save) through
         the WXF byte form: every non-System symbol is fully qualified there,
         so the same token scan applies and nothing is evaluated *)
      hits = iSVDiagShadowScanText[iSVDiagShadowWXFText[NotebookGet[nb]], "<notebook>",
        OptionValue["Names"]];
      targets = iSVDiagShadowSelectTargets[hits, OptionValue["Contexts"]];
      If[targets === {},
        Return[<|"Notebook" -> nb, "Cells" -> 0, "Symbols" -> {}|>]];
      needles = iSVDiagShadowWXFTokenRules[targets][[All, 1]];
      Scan[Function[c, Module[{expr = Quiet @ NotebookRead[c], text},
          text = Quiet @ Check[iSVDiagShadowWXFText[expr], $Failed];
          If[StringQ[text] && StringContainsQ[text, Alternatives @@ needles],
            NotebookWrite[c, iSVDiagShadowReplaceSymbols[expr, targets]]; done++]]],
        Cells[nb]]];
    SourceVaultRepairShadowedSystemSymbols[];
    <|"Notebook" -> nb, "Cells" -> done, "Symbols" -> targets[[All, "Symbol"]]|>];

(* ------------------------------------------------------------
   License capacity (measured).
   ------------------------------------------------------------ *)

SourceVaultDiagnosticsLicenseProbe[] :=
  Module[{maxP, used, maxS, type, freeP, subUsed, freeS},
    maxP = Quiet @ Check[$MaxLicenseProcesses, Missing["Unavailable"]];
    used = Quiet @ Check[$LicenseProcesses, Missing["Unavailable"]];
    maxS = Quiet @ Check[$MaxLicenseSubprocesses, Missing["Unavailable"]];
    type = Quiet @ Check[ToString[$LicenseType], "unknown"];
    If[!IntegerQ[maxP], maxP = Missing["Unavailable"]];
    If[!IntegerQ[used], used = Missing["Unavailable"]];
    If[!IntegerQ[maxS], maxS = Missing["Unavailable"]];
    freeP = If[IntegerQ[maxP] && IntegerQ[used], maxP - used, Missing["Unavailable"]];
    (* current parallel subkernels of this kernel; subprocess pool usage *)
    subUsed = Quiet @ Check[Length[Kernels[]], Missing["Unavailable"]];
    freeS = If[IntegerQ[maxS] && IntegerQ[subUsed], maxS - subUsed, Missing["Unavailable"]];
    <|
      "LicenseType" -> type,
      "MaxLicenseProcesses" -> maxP,
      "LicenseProcesses" -> used,
      "ProcessSlotsFree" -> freeP,
      "MaxLicenseSubprocesses" -> maxS,
      "Subprocesses" -> subUsed,
      "SubprocessSlotsFree" -> freeS,
      "MeasuredAtUTC" -> iSVDiagUTCNow[],
      "MachineTag" -> iSVDiagMachineTag[]
    |>];

(* ------------------------------------------------------------
   Kernel process topology (Windows best-effort via CIM).
   ------------------------------------------------------------ *)

$iSVDiagKernelNames =
  {"WolframKernel.exe", "Mathematica.exe", "wolfram.exe",
   "WolframScript.exe", "wolframscript.exe", "MathKernel.exe",
   "WolframNB.exe"};

iSVDiagClassifyKernel[name_String, cmd_String] :=
  Which[
    StringContainsQ[cmd, "run.wls"], "Service",
    StringContainsQ[cmd, "StartMCPServer"], "MCPServer",
    StringContainsQ[cmd, "-subkernel"], "Subkernel",
    StringContainsQ[cmd, "playerpass"] || StringContainsQ[cmd, "-sandbox"],
      "PlayerSandbox",
    name === "WolframNB.exe", "FrontEndUI",
    StringContainsQ[name, "WolframKernel"] || StringContainsQ[name, "MathKernel"],
      "FEKernel",
    True, "Other"];

(* process classes that draw an independent license *process* slot *)
$iSVDiagSeatClasses = {"Service", "MCPServer", "FEKernel", "Other"};

iSVDiagWindowsTopology[] :=
  Module[{flt, cmd, out, data},
    flt = StringRiffle[
      ("Name='" <> # <> "'") & /@ $iSVDiagKernelNames, " OR "];
    cmd = "Get-CimInstance Win32_Process -Filter \"" <> flt <>
      "\" | Select-Object ProcessId,Name,CommandLine | ConvertTo-Json -Compress";
    out = Quiet @ Check[
      TimeConstrained[
        RunProcess[{"powershell", "-NoProfile", "-NonInteractive", "-Command", cmd},
          "StandardOutput"], 20, $Failed],
      $Failed];
    If[!StringQ[out] || StringTrim[out] === "", Return[$Failed]];
    data = Quiet @ Check[Developer`ReadRawJSONString[out], $Failed];
    If[data === $Failed,
      data = Quiet @ Check[ImportString[out, "RawJSON"], $Failed]];
    If[data === $Failed, Return[$Failed]];
    If[AssociationQ[data], data = {data}];
    If[!ListQ[data], Return[$Failed]];
    Map[
      Function[p,
        Module[{nm, cm},
          nm = ToString @ Lookup[p, "Name", ""];
          cm = Lookup[p, "CommandLine", ""];
          cm = If[StringQ[cm], cm, ""];
          <|"ProcessId" -> Lookup[p, "ProcessId", Missing[]],
            "Name" -> nm,
            "Class" -> iSVDiagClassifyKernel[nm, cm]|>]],
      data]];

SourceVaultDiagnosticsKernelProcessTopology[] :=
  Module[{procs, counts, seats},
    procs = If[$OperatingSystem === "Windows", iSVDiagWindowsTopology[], $Failed];
    If[procs === $Failed,
      (* fallback: name-only count, no command-line classification *)
      Return[<|
        "ProbeMethod" -> "Fallback",
        "Classified" -> False,
        "Processes" -> {},
        "ClassCounts" -> <||>,
        "SeatConsumingCount" -> Missing["Unclassified"],
        "MeasuredAtUTC" -> iSVDiagUTCNow[],
        "MachineTag" -> iSVDiagMachineTag[]|>]];
    counts = Counts[Lookup[#, "Class", "Other"] & /@ procs];
    seats = Total[Lookup[counts, #, 0] & /@ $iSVDiagSeatClasses];
    <|
      "ProbeMethod" -> "WindowsCIM",
      "Classified" -> True,
      "Processes" -> procs,
      "ClassCounts" -> counts,
      "SeatConsumingCount" -> seats,
      "MeasuredAtUTC" -> iSVDiagUTCNow[],
      "MachineTag" -> iSVDiagMachineTag[]
    |>];

(* ------------------------------------------------------------
   Reclaimable capacity (duplicate MCP-server kernels).
   ------------------------------------------------------------ *)

SourceVaultDiagnosticsReclaimableCapacity[topo_Association] :=
  Module[{mcp, reclaimable},
    mcp = Quiet @ Check[Lookup[topo["ClassCounts"], "MCPServer", 0], 0];
    If[!IntegerQ[mcp], mcp = 0];
    reclaimable = Max[0, mcp - 1];
    <|
      "MCPServerKernels" -> mcp,
      "ReclaimableMCPKernels" -> reclaimable,
      "ReclaimableProcessSlots" -> reclaimable,
      "Recommendation" ->
        If[reclaimable > 0,
          "Route Wolfram MCP clients through the single shared gateway " <>
          "(wlmcp-gateway, http) so " <> ToString[mcp] <>
          " StartMCPServer kernels collapse to 1; frees " <>
          ToString[reclaimable] <> " process slot(s).",
          "No duplicate MCP-server kernels detected."],
      "MeasuredAtUTC" -> iSVDiagUTCNow[]
    |>];
SourceVaultDiagnosticsReclaimableCapacity[] :=
  SourceVaultDiagnosticsReclaimableCapacity[
    SourceVaultDiagnosticsKernelProcessTopology[]];

(* ------------------------------------------------------------
   System doctor (Phase 0 aggregation).
   ------------------------------------------------------------ *)

iSVDiagWorst[healths_List] :=
  Which[
    MemberQ[healths, "Failing"], "Failing",
    MemberQ[healths, "Degraded"], "Degraded",
    True, "OK"];

iSVDiagLicensePoolHealth[lic_Association, reclaim_Association] :=
  Module[{free = lic["ProcessSlotsFree"],
          recl = Lookup[reclaim, "ReclaimableProcessSlots", 0]},
    Which[
      !IntegerQ[free], "Degraded",                  (* could not measure *)
      free >= 1, "OK",                              (* headroom for a headless job *)
      IntegerQ[recl] && recl > 0, "Degraded",       (* full but reclaimable via gateway *)
      True, "Failing"]];                            (* full, nothing to reclaim *)

(* subprocess (subkernel) pool: the resource SubkernelAsync jobs consume *)
iSVDiagSubprocessPoolHealth[lic_Association] :=
  Module[{free = lic["SubprocessSlotsFree"]},
    Which[!IntegerQ[free], "Degraded", free >= 1, "OK", True, "Failing"]];

iSVDiagNormalizeHealth[h_] :=
  Which[
    AssociationQ[h], Lookup[h, "Health", "OK"],
    StringQ[h], h,
    True, "OK"];

(* weakly read service-manager health for known service ids, if present *)
iSVDiagServiceHealthComponents[] :=
  Module[{ids = {"sourcevault"}, out = <||>},
    If[!iSVDiagSymbolExistsQ["SourceVault`SourceVaultServiceHealth"],
      Return[out]];
    Scan[
      Function[id,
        Module[{h = iSVDiagCall["SourceVault`SourceVaultServiceHealth", id]},
          If[StringQ[h] || AssociationQ[h],
            out = Append[out,
              ("Service:" <> id) -> <|"Health" -> iSVDiagNormalizeHealth[h]|>]]]],
      ids];
    out];

Options[SourceVaultSystemDoctor] = {"Emit" -> False, "IncludeTopology" -> True};

SourceVaultSystemDoctor[opts : OptionsPattern[]] :=
  Module[{inclTopo, lic, topo, reclaim, comp, poolHealth, mcpHealth, svc,
          registered, global, result, seatNote, recl},
    inclTopo = TrueQ[OptionValue["IncludeTopology"]];
    lic = SourceVaultDiagnosticsLicenseProbe[];
    If[inclTopo,
      topo = SourceVaultDiagnosticsKernelProcessTopology[];
      reclaim = SourceVaultDiagnosticsReclaimableCapacity[topo];
      $iSVDiagLastComprehensiveAt = AbsoluteTime[],
      (* lightweight: skip the CIM topology shell-out *)
      topo = <|"ProbeMethod" -> "Skipped", "Classified" -> False,
        "ClassCounts" -> <||>, "SeatConsumingCount" -> Missing["Skipped"]|>;
      reclaim = <|"MCPServerKernels" -> Missing["Skipped"],
        "ReclaimableMCPKernels" -> 0, "ReclaimableProcessSlots" -> 0,
        "Recommendation" -> "Topology probe skipped (lightweight)."|>];
    poolHealth = iSVDiagLicensePoolHealth[lic, reclaim];
    recl = Lookup[reclaim, "ReclaimableMCPKernels", 0];
    mcpHealth = If[IntegerQ[recl] && recl > 0, "Degraded", "OK"];
    svc = iSVDiagServiceHealthComponents[];
    registered = iSVDiagRunRegisteredProbes[];
    (* core components first; registered producer probes do not silently
       overwrite the core license/MCP keys. *)
    comp = Join[
      KeyDrop[registered, {"LicensePool", "SubprocessPool", "MCPKernels"}],
      svc,
      <|"LicensePool" -> <|"Health" -> poolHealth|>,
        "SubprocessPool" -> <|"Health" -> iSVDiagSubprocessPoolHealth[lic]|>,
        "MCPKernels" -> <|"Health" -> mcpHealth|>|>];
    global = iSVDiagWorst[Lookup[#, "Health", "OK"] & /@ Values[comp]];
    (* license API is the authoritative process-used count; the topology
       SeatConsumingCount is an approximate breakdown and may differ
       (e.g. mathlink companion / controller kernels). *)
    seatNote = <|
      "AuthoritativeProcessesUsed" -> lic["LicenseProcesses"],
      "MaxLicenseProcesses" -> lic["MaxLicenseProcesses"],
      "TopologyApproxSeatCount" -> Lookup[topo, "SeatConsumingCount", Missing[]],
      "Source" -> "LicenseAPI is authoritative; topology is an approximate breakdown.",
      "Agrees" ->
        With[{a = lic["LicenseProcesses"], b = Lookup[topo, "SeatConsumingCount", Missing[]]},
          If[IntegerQ[a] && IntegerQ[b], a === b, Missing["Unknown"]]]|>;
    result = <|
      "Type" -> "SystemDoctor",
      "SchemaVersion" -> $SourceVaultDiagnosticsVersion,
      "GeneratedAtUTC" -> iSVDiagUTCNow[],
      "MachineTag" -> iSVDiagMachineTag[],
      "GlobalHealth" -> global,
      "ComponentHealth" -> comp,
      "RegisteredProbeIds" -> Keys[$iSVDiagProbes],
      "License" -> lic,
      "SeatAccounting" -> seatNote,
      "Topology" -> KeyDrop[topo, "Processes"],
      "Reclaimable" -> reclaim
    |>;
    If[TrueQ[OptionValue["Emit"]],
      SourceVaultDiagnosticsLog[<|
        "Type" -> "DoctorRun",
        "Component" -> "SystemDoctor",
        "Health" -> global,
        "ReasonCode" -> "DoctorRun",
        "Summary" -> result|>]];
    result];

(* ------------------------------------------------------------
   Structured diagnostics log (machine-local, append-only).
   ------------------------------------------------------------ *)

iSVDiagLogPath[] :=
  Module[{dir = iSVDiagMachineDir[]},
    If[dir === $Failed, $Failed,
      FileNameJoin[{dir, "diagnostics-log.jsonl"}]]];

SourceVaultDiagnosticsLog[record_Association] :=
  Module[{path = iSVDiagLogPath[], enriched, json, strm},
    If[path === $Failed,
      Return[Failure["VaultRootUnresolved",
        <|"MessageTemplate" -> "SourceVault root unresolved; cannot persist diagnostics log."|>]]];
    If[iSVDiagEnsureDir[DirectoryName[path]] === $Failed,
      Return[Failure["LogDirUnwritable", <|"MessageTemplate" -> "Cannot create diagnostics log directory."|>]]];
    enriched = Join[
      <|"AtUTC" -> iSVDiagUTCNow[], "MachineTag" -> iSVDiagMachineTag[]|>,
      record];
    (* hardening 05 Inc2 (2026-07-08): 単一エンコード化。旧実装は
       WriteRawJSONString の返す「UTF-8 バイト文字列」を WriteString が
       UTF-8 で再エンコードし、日本語 payload が二重エンコードで化けた
       (SourceVault_mcp iSVAppendJSONL と同族の罠。実測 31B vs 正 22B)。
       ExportByteArray で一発エンコードし BinaryWrite する。fallback は
       byte-string を ISO8859-1 で素通し (= 元バイトそのまま)。 *)
    json = Quiet @ Check[
      ExportByteArray[enriched, "RawJSON", "Compact" -> True], $Failed];
    If[! ByteArrayQ[json],
      json = Quiet @ Check[
        StringToByteArray[iSVDiagToJSON[enriched], "ISO8859-1"], $Failed]];
    If[! ByteArrayQ[json], json = StringToByteArray["{}", "UTF-8"]];
    strm = Quiet @ Check[OpenAppend[path, BinaryFormat -> True], $Failed];
    If[strm === $Failed,
      Return[Failure["LogOpenFailed", <|"MessageTemplate" -> "Cannot open diagnostics log."|>]]];
    Quiet @ Check[
      BinaryWrite[strm, json];
      BinaryWrite[strm, StringToByteArray["\n", "UTF-8"]];
      Close[strm], Close[strm]];
    enriched];

(* ------------------------------------------------------------
   Machine heartbeat (per-machine path, atomic write).
   ------------------------------------------------------------ *)

$iSVDiagHeartbeatSeq = 0;

iSVDiagHeartbeatPath[] :=
  Module[{dir = iSVDiagMachineDir[]},
    If[dir === $Failed, $Failed,
      FileNameJoin[{dir, "heartbeat.json"}]]];

iSVDiagPriorSequence[path_String] :=
  Module[{prior},
    If[!FileExistsQ[path], Return[0]];
    prior = Quiet @ Check[Developer`ReadRawJSONString[ReadString[path]], $Failed];
    If[AssociationQ[prior] && IntegerQ[Lookup[prior, "Sequence", 0]],
      Lookup[prior, "Sequence", 0], 0]];

Options[SourceVaultDiagnosticsMachineHeartbeat] = {"IncludeTopology" -> True};

SourceVaultDiagnosticsMachineHeartbeat[opts : OptionsPattern[]] :=
  Module[{path = iSVDiagHeartbeatPath[], doctor, record, seq, w},
    If[path === $Failed,
      Return[Failure["VaultRootUnresolved",
        <|"MessageTemplate" -> "SourceVault root unresolved; cannot write heartbeat."|>]]];
    seq = iSVDiagPriorSequence[path] + 1;
    $iSVDiagHeartbeatSeq = seq;
    doctor = SourceVaultSystemDoctor[
      "IncludeTopology" -> TrueQ[OptionValue["IncludeTopology"]]];
    record = <|
      "Type" -> "MachineHeartbeat",
      "MachineTag" -> iSVDiagMachineTag[],
      "Sequence" -> seq,
      "WrittenAtUTC" -> iSVDiagUTCNow[],
      "LocalMonotonicSeconds" -> Quiet @ Check[N[AbsoluteTime[]], Missing[]],
      "GlobalHealth" -> doctor["GlobalHealth"],
      "LicenseProcessSlotsFree" -> doctor["License"]["ProcessSlotsFree"],
      "ReclaimableMCPKernels" -> Lookup[doctor["Reclaimable"], "ReclaimableMCPKernels", 0],
      "ComponentHealth" -> doctor["ComponentHealth"]
    |>;
    w = iSVDiagAtomicWrite[path, iSVDiagToJSON[record]];
    If[w === $Failed,
      Return[Failure["HeartbeatWriteFailed",
        <|"MessageTemplate" -> "Atomic heartbeat write failed.", "Record" -> record|>]]];
    record];

(* ------------------------------------------------------------
   Multi-machine layer (spec 3.4): machine registry, heartbeat
   aggregation, active-aggregator selection, rollup, and a weak
   Wolfram Cloud heartbeat that degrades to SourceVault polling.
   Per-machine paths keep Dropbox writes conflict-free. The pure
   selection / rollup logic is split out so it is testable without
   the vault filesystem.
   ------------------------------------------------------------ *)

iSVDiagMachinesRoot[] :=
  Module[{root = iSVDiagRoot[]},
    If[root === $Failed, $Failed, FileNameJoin[{root, "diagnostics", "machines"}]]];

iSVDiagMachineSubdir[tag_String] :=
  Module[{r = iSVDiagMachinesRoot[]},
    If[r === $Failed, $Failed, FileNameJoin[{r, tag}]]];

iSVDiagReadJSONFile[path_] :=
  If[StringQ[path] && FileExistsQ[path],
    Quiet @ Check[Developer`ReadRawJSONString[ReadString[path]], $Failed], $Failed];

iSVDiagListMachineTags[] :=
  Module[{r = iSVDiagMachinesRoot[]},
    If[r === $Failed || !DirectoryQ[r], {},
      FileNameTake /@ Select[FileNames[All, r], DirectoryQ]]];

SourceVaultDiagnosticsRegisterMachine[assoc_Association] :=
  Module[{tag = Lookup[assoc, "MachineTag", iSVDiagMachineTag[]], dir, path, rec, w},
    dir = iSVDiagMachineSubdir[tag];
    If[dir === $Failed, Return[Failure["VaultRootUnresolved", <||>]]];
    iSVDiagEnsureDir[dir];
    path = FileNameJoin[{dir, "registry.json"}];
    rec = Join[
      <|"Type" -> "MachineRegistry", "MachineTag" -> tag, "Roles" -> {"Worker"},
        "AggregatorPriority" -> 0, "ExpectedAvailability" -> "AlwaysOn",
        "HeartbeatIntervalSeconds" -> 60, "StaleAfterSeconds" -> 300,
        "FailoverAfterSeconds" -> 600|>,
      assoc, <|"MachineTag" -> tag, "RegisteredAtUTC" -> iSVDiagUTCNow[]|>];
    w = iSVDiagAtomicWrite[path, iSVDiagToJSON[rec]];
    If[w === $Failed, Failure["RegistryWriteFailed", <|"Record" -> rec|>], rec]];

SourceVaultDiagnosticsMachineRegistry[] :=
  Cases[
    iSVDiagReadJSONFile[FileNameJoin[{iSVDiagMachineSubdir[#], "registry.json"}]] & /@
      iSVDiagListMachineTags[],
    _Association];

(* age via heartbeat monotonic seconds (AbsoluteTime is a global instant; subject
   to inter-machine clock skew, which the spec flags as a known limitation) *)
iSVDiagHeartbeatAgeSeconds[hb_] :=
  Module[{m = If[AssociationQ[hb], Lookup[hb, "LocalMonotonicSeconds", Missing[]], Missing[]]},
    If[NumberQ[m], Max[0, AbsoluteTime[] - m], Missing["NoTimestamp"]]];

iSVDiagMachineLiveness[reg_, hb_] :=
  Module[{age, stale = Lookup[reg, "StaleAfterSeconds", 300],
          failover = Lookup[reg, "FailoverAfterSeconds", 600],
          avail = Lookup[reg, "ExpectedAvailability", "AlwaysOn"]},
    If[!AssociationQ[hb], Return["NoHeartbeat"]];
    age = iSVDiagHeartbeatAgeSeconds[hb];
    Which[
      !NumberQ[age], "Unknown",
      age < stale, "OK",
      avail === "Intermittent", "OfflineOrSleeping",
      age < failover, "Stale",
      True, "Failing"]];

SourceVaultDiagnosticsReadHeartbeats[] :=
  Map[
    Function[tag,
      Module[{reg = iSVDiagReadJSONFile[FileNameJoin[{iSVDiagMachineSubdir[tag], "registry.json"}]],
              hb = iSVDiagReadJSONFile[FileNameJoin[{iSVDiagMachineSubdir[tag], "heartbeat.json"}]]},
        <|"MachineTag" -> tag,
          "Registry" -> If[AssociationQ[reg], reg, Missing["Unregistered"]],
          "Heartbeat" -> If[AssociationQ[hb], hb, Missing["NoHeartbeat"]],
          "AgeSeconds" -> If[AssociationQ[hb], iSVDiagHeartbeatAgeSeconds[hb], Missing[]],
          "Liveness" -> iSVDiagMachineLiveness[If[AssociationQ[reg], reg, <||>], hb],
          "GlobalHealth" -> If[AssociationQ[hb], Lookup[hb, "GlobalHealth", "Unknown"], "Unknown"]|>]],
    iSVDiagListMachineTags[]];

(* pure: pick active aggregator from a list of read-heartbeat records *)
iSVDiagAggregatorFromHeartbeats[hbs_List] :=
  Module[{cands},
    cands = Select[hbs,
      AssociationQ[Lookup[#, "Registry", Null]] &&
        MemberQ[Lookup[#["Registry"], "Roles", {}], "AggregatorCandidate"] &&
        #["Liveness"] === "OK" &];
    cands = ReverseSortBy[cands, Lookup[#["Registry"], "AggregatorPriority", 0] &];
    <|"ActiveAggregator" ->
        If[cands === {}, Missing["NoActiveAggregator"], First[cands]["MachineTag"]],
      "StandbyCandidates" -> If[Length[cands] > 1, Rest[cands][[All, "MachineTag"]], {}],
      "Considered" -> Length[hbs]|>];

iSVDiagRollupFromHeartbeats[hbs_List] :=
  Module[{healths = Lookup[#, "GlobalHealth", "Unknown"] & /@ hbs, global, agg},
    agg = iSVDiagAggregatorFromHeartbeats[hbs];
    global = Which[
      MemberQ[healths, "Failing"] || AnyTrue[hbs, #["Liveness"] === "Failing" &], "Failing",
      MemberQ[healths, "Degraded"] ||
        AnyTrue[hbs, MemberQ[{"Stale", "NoHeartbeat"}, #["Liveness"]] &], "Degraded",
      True, "OK"];
    <|"Type" -> "AggregatorRollup", "AtUTC" -> iSVDiagUTCNow[],
      "ActiveAggregator" -> agg["ActiveAggregator"],
      "StandbyCandidates" -> agg["StandbyCandidates"],
      "GlobalHealth" -> global,
      "Machines" -> (<|"MachineTag" -> #["MachineTag"], "Liveness" -> #["Liveness"],
          "GlobalHealth" -> #["GlobalHealth"], "AgeSeconds" -> #["AgeSeconds"]|> & /@ hbs),
      "ProblemMachines" -> (#["MachineTag"] & /@ Select[hbs, #["Liveness"] =!= "OK" &])|>];

SourceVaultDiagnosticsActiveAggregator[] :=
  iSVDiagAggregatorFromHeartbeats[SourceVaultDiagnosticsReadHeartbeats[]];

SourceVaultDiagnosticsAggregatorRollup[] :=
  iSVDiagMergeCloudIntoRollup[
    iSVDiagRollupFromHeartbeats[SourceVaultDiagnosticsReadHeartbeats[]],
    iSVDiagCloudPeerHeartbeats[]];

iSVDiagCloudConnectedQ[] := TrueQ[Quiet @ Check[$CloudConnected, False]];

(* shared coordination channel name. All machines on the SAME Wolfram account
   reference the same named channel, so cross-machine send/recv just works.
   Configurable via the mail/comms config; default fixed name. *)
If[!ValueQ[$iSVDiagCloudChannelName], $iSVDiagCloudChannelName = "sourcevault-coordination"];
If[!ValueQ[$iSVDiagCloudInbox], $iSVDiagCloudInbox = {}];
If[!ValueQ[$iSVDiagCloudSeenIds], $iSVDiagCloudSeenIds = {}];
If[!ValueQ[$iSVDiagCloudInboxMax], $iSVDiagCloudInboxMax = 200];
If[!ValueQ[$iSVDiagCloudListener], $iSVDiagCloudListener = Null];

(* ensure the named channel exists (idempotent) and return its ChannelObject *)
iSVDiagCloudChannelObj[] :=
  Module[{name = $iSVDiagCloudChannelName},
    Quiet @ Check[CreateChannel[name, Permissions -> "Private"], Null];
    ChannelObject[name]];

SourceVaultDiagnosticsCloudChannel[] :=
  If[!iSVDiagCloudConnectedQ[],
    <|"Available" -> False, "Reason" -> "NotCloudConnected",
      "Fallback" -> "SourceVaultPolling"|>,
    Module[{ch = Quiet @ Check[iSVDiagCloudChannelObj[], $Failed]},
      <|"Available" -> (ch =!= $Failed), "Channel" -> ToString[ch],
        "Name" -> $iSVDiagCloudChannelName|>]];

(* receiver: DATA ONLY. Records the incoming packet to a bounded inbox; never
   evaluates message content (cloud messages are data, not commands). Dedups by
   MessageID. The payload sits under the "Message" key (see channel API). *)
iSVDiagCloudReceiver[pkt_] :=
  Module[{msg, mid},
    If[!AssociationQ[pkt], Return[Null]];
    msg = Lookup[pkt, "Message", <||>];
    mid = ToString @ Lookup[pkt, "MessageID", ""];
    If[mid =!= "" && MemberQ[$iSVDiagCloudSeenIds, mid], Return[Null]];
    AppendTo[$iSVDiagCloudSeenIds, mid];
    If[Length[$iSVDiagCloudSeenIds] > 2 $iSVDiagCloudInboxMax,
      $iSVDiagCloudSeenIds = Take[$iSVDiagCloudSeenIds, -$iSVDiagCloudInboxMax]];
    AppendTo[$iSVDiagCloudInbox, <|
      "MessageID" -> mid,
      "FromWolframID" -> Lookup[pkt, "RequesterWolframID", Missing[]],
      "FromMachineTag" -> If[AssociationQ[msg], Lookup[msg, "MachineTag", Missing[]], Missing[]],
      "Type" -> If[AssociationQ[msg], Lookup[msg, "Type", Missing[]], Missing[]],
      "Message" -> msg,
      "ReceivedAtUTC" -> iSVDiagUTCNow[],
      "ReceivedAbs" -> AbsoluteTime[]|>];   (* monotonic, for liveness age *)
    If[Length[$iSVDiagCloudInbox] > $iSVDiagCloudInboxMax,
      $iSVDiagCloudInbox = Take[$iSVDiagCloudInbox, -$iSVDiagCloudInboxMax]];
    Null];

(* is OUR listener still registered with the broker? (watchdog, spec r8) *)
iSVDiagCloudListenerAliveQ[] :=
  $iSVDiagCloudListener =!= Null &&
    TrueQ[Quiet @ Check[
      MemberQ[ChannelListeners[], $iSVDiagCloudListener] ||
        MemberQ[ToString /@ ChannelListeners[], ToString[$iSVDiagCloudListener]],
      False]];

SourceVaultDiagnosticsCloudListen[] :=
  Module[{ch, lis},
    If[!iSVDiagCloudConnectedQ[],
      Return[<|"Status" -> "Skipped", "Reason" -> "NotCloudConnected",
        "Fallback" -> "SourceVaultPolling"|>]];
    If[iSVDiagCloudListenerAliveQ[],
      Return[<|"Status" -> "AlreadyListening",
        "Listener" -> ToString[$iSVDiagCloudListener]|>]];
    ch = Quiet @ Check[iSVDiagCloudChannelObj[], $Failed];
    If[ch === $Failed, Return[<|"Status" -> "Failed", "Reason" -> "ChannelUnresolved"|>]];
    lis = Quiet @ Check[ChannelListen[ch, iSVDiagCloudReceiver], $Failed];
    If[lis === $Failed, Return[<|"Status" -> "Failed", "Reason" -> "ChannelListenFailed"|>]];
    $iSVDiagCloudListener = lis;
    <|"Status" -> "Listening", "Channel" -> ToString[ch],
      "Listener" -> ToString[lis]|>];

SourceVaultDiagnosticsCloudStopListen[] :=
  Module[{lis = $iSVDiagCloudListener},
    If[lis === Null, Return[<|"Status" -> "NotListening"|>]];
    Quiet @ Check[RemoveChannelListener[lis], Null];
    $iSVDiagCloudListener = Null;
    <|"Status" -> "Stopped"|>];

SourceVaultDiagnosticsCloudSend[message_Association] :=
  Module[{ch, payload, res},
    If[!iSVDiagCloudConnectedQ[],
      Return[<|"Sent" -> False, "Reason" -> "NotCloudConnected",
        "Fallback" -> "SourceVaultPolling"|>]];
    ch = Quiet @ Check[iSVDiagCloudChannelObj[], $Failed];
    If[ch === $Failed, Return[<|"Sent" -> False, "Reason" -> "ChannelUnresolved"|>]];
    payload = Join[
      <|"Type" -> "Message", "MachineTag" -> iSVDiagMachineTag[],
        "AtUTC" -> iSVDiagUTCNow[]|>, message];
    res = Quiet @ Check[ChannelSend[ch, payload], $Failed];
    If[res === $Failed,
      <|"Sent" -> False, "Reason" -> "ChannelSendFailed"|>,
      <|"Sent" -> True, "Channel" -> ToString[ch], "Type" -> payload["Type"]|>]];

Options[SourceVaultDiagnosticsCloudInbox] = {"Type" -> All, "MaxItems" -> All};
SourceVaultDiagnosticsCloudInbox[opts : OptionsPattern[]] :=
  Module[{items = $iSVDiagCloudInbox, ty = OptionValue["Type"], mx = OptionValue["MaxItems"]},
    If[StringQ[ty], items = Select[items, Lookup[#, "Type", ""] === ty &]];
    If[IntegerQ[mx] && Length[items] > mx, items = Take[items, -mx]];
    items];

SourceVaultDiagnosticsCloudCommsStatus[] :=
  <|"CloudConnected" -> iSVDiagCloudConnectedQ[],
    "ChannelName" -> $iSVDiagCloudChannelName,
    "ListenerAlive" -> iSVDiagCloudListenerAliveQ[],
    "InboxCount" -> Length[$iSVDiagCloudInbox],
    "Fallback" -> "SourceVaultPolling",
    "AtUTC" -> iSVDiagUTCNow[]|>;

(* heartbeat over the channel: send a Heartbeat message if connected, else
   report the polling fallback. Round-trip visibility is via the inbox. *)
Options[SourceVaultDiagnosticsCloudHeartbeat] = {"Send" -> True};
SourceVaultDiagnosticsCloudHeartbeat[opts : OptionsPattern[]] :=
  Module[{connected = iSVDiagCloudConnectedQ[], sent},
    If[!connected,
      Return[<|"Channel" -> "Unavailable", "Fallback" -> "SourceVaultPolling",
        "Reason" -> "NotCloudConnected", "AtUTC" -> iSVDiagUTCNow[]|>]];
    sent = If[TrueQ[OptionValue["Send"]],
      SourceVaultDiagnosticsCloudSend[<|"Type" -> "Heartbeat",
        "GlobalHealth" -> Quiet @ Check[
          SourceVaultDiagnosticsLightweightDoctor[]["GlobalHealth"], Missing[]]|>],
      <|"Sent" -> False, "Reason" -> "SendDisabled"|>];
    <|"Channel" -> "Connected", "Fallback" -> "SourceVaultPolling",
      "CloudBase" -> Quiet @ Check[$CloudBase, Missing[]],
      "ListenerAlive" -> iSVDiagCloudListenerAliveQ[],
      "HeartbeatSent" -> Lookup[sent, "Sent", False],
      "AtUTC" -> iSVDiagUTCNow[]|>];

(* ------------------------------------------------------------
   Cloud-channel consumption: derive peer liveness from received
   Heartbeat messages, and a SAFE consumer that only sets a wakeup
   flag (no eval of cloud content). Used to enrich the multi-PC
   rollup so a peer seen via cloud is live even if its file
   heartbeat (Dropbox-synced) lags.
   ------------------------------------------------------------ *)

If[!ValueQ[$iSVDiagCloudPeerStaleSeconds], $iSVDiagCloudPeerStaleSeconds = 180];
If[!ValueQ[$iSVDiagCloudWakeupRequested], $iSVDiagCloudWakeupRequested = False];

(* latest cloud Heartbeat per peer machine -> liveness (from the inbox) *)
iSVDiagCloudPeerHeartbeats[] :=
  Module[{hbs, byTag},
    hbs = Select[$iSVDiagCloudInbox,
      Lookup[#, "Type", ""] === "Heartbeat" &&
        StringQ[Lookup[#, "FromMachineTag", Missing[]]] &];
    byTag = GroupBy[hbs, Lookup[#, "FromMachineTag", ""] &];
    Association @ KeyValueMap[
      Function[{tag, msgs},
        Module[{latest = Last[SortBy[msgs, Lookup[#, "ReceivedAbs", 0] &]], age},
          age = AbsoluteTime[] - Lookup[latest, "ReceivedAbs", 0];
          tag -> <|
            "GlobalHealth" -> Lookup[Lookup[latest, "Message", <||>], "GlobalHealth", "Unknown"],
            "AgeSeconds" -> age,
            "Liveness" -> If[age < $iSVDiagCloudPeerStaleSeconds, "OK", "Stale"],
            "Source" -> "Cloud"|>]],
      byTag]];

SourceVaultDiagnosticsCloudPeerLiveness[] := iSVDiagCloudPeerHeartbeats[];

(* SAFE consumer: peer heartbeats (data) + a wakeup flag. Never evaluates
   cloud message content. A caller may, on WakeupRequested, run its own tick
   (a safe local action) and then reset the flag. *)
SourceVaultDiagnosticsCloudConsume[] :=
  Module[{wakeups = Select[$iSVDiagCloudInbox, Lookup[#, "Type", ""] === "Wakeup" &]},
    If[wakeups =!= {}, $iSVDiagCloudWakeupRequested = True];
    <|"PeerHeartbeats" -> iSVDiagCloudPeerHeartbeats[],
      "WakeupRequested" -> $iSVDiagCloudWakeupRequested,
      "WakeupCount" -> Length[wakeups],
      "InboxCount" -> Length[$iSVDiagCloudInbox]|>];

(* merge cloud-derived liveness into a file-based rollup: a machine is OK if
   EITHER source is fresh; cloud-only machines are added. *)
iSVDiagBestLiveness[fileL_, cloudL_] :=
  Which[
    fileL === "OK" || cloudL === "OK", "OK",
    StringQ[fileL] && fileL =!= "NoHeartbeat", fileL,
    StringQ[cloudL], cloudL,
    True, fileL];

iSVDiagMergeCloudIntoRollup[rollup_Association, cloudPeers_Association] :=
  Module[{machines = Lookup[rollup, "Machines", {}], seen, merged, cloudOnly,
          all, global, problems},
    seen = Lookup[#, "MachineTag", ""] & /@ machines;
    merged = Map[
      Function[m,
        Module[{tag = Lookup[m, "MachineTag", ""], cp},
          cp = Lookup[cloudPeers, tag, Missing[]];
          If[AssociationQ[cp],
            Append[m, <|"CloudLiveness" -> cp["Liveness"],
              "Liveness" -> iSVDiagBestLiveness[Lookup[m, "Liveness", ""], cp["Liveness"]],
              "LivenessSources" -> {"File", "Cloud"}|>],
            Append[m, "LivenessSources" -> {"File"}]]]],
      machines];
    cloudOnly = KeyValueMap[
      Function[{tag, cp},
        <|"MachineTag" -> tag, "Liveness" -> cp["Liveness"],
          "GlobalHealth" -> cp["GlobalHealth"], "AgeSeconds" -> cp["AgeSeconds"],
          "CloudLiveness" -> cp["Liveness"], "LivenessSources" -> {"Cloud"}|>],
      KeySelect[cloudPeers, !MemberQ[seen, #] &]];
    all = Join[merged, cloudOnly];
    global = Which[
      AnyTrue[all, #["Liveness"] === "Failing" &] ||
        MemberQ[Lookup[#, "GlobalHealth", "Unknown"] & /@ all, "Failing"], "Failing",
      AnyTrue[all, MemberQ[{"Stale", "NoHeartbeat"}, #["Liveness"]] &] ||
        MemberQ[Lookup[#, "GlobalHealth", "Unknown"] & /@ all, "Degraded"], "Degraded",
      True, "OK"];
    problems = #["MachineTag"] & /@ Select[all, #["Liveness"] =!= "OK" &];
    Join[rollup, <|"Machines" -> all, "GlobalHealth" -> global,
      "ProblemMachines" -> problems, "CloudPeersConsidered" -> Length[cloudPeers]|>]];

(* ------------------------------------------------------------
   Status / panel.
   ------------------------------------------------------------ *)

SourceVaultDiagnosticsStatus[opts : OptionsPattern[]] :=
  Module[{doctor = SourceVaultSystemDoctor[]},
    <|
      "Version" -> $SourceVaultDiagnosticsVersion,
      "SinkAvailable" -> SourceVaultDiagnosticsSinkAvailableQ[],
      "MachineTag" -> iSVDiagMachineTag[],
      "GlobalHealth" -> doctor["GlobalHealth"],
      "LicenseProcessesUsed" -> doctor["License"]["LicenseProcesses"],
      "MaxLicenseProcesses" -> doctor["License"]["MaxLicenseProcesses"],
      "ProcessSlotsFree" -> doctor["License"]["ProcessSlotsFree"],
      "MaxLicenseSubprocesses" -> doctor["License"]["MaxLicenseSubprocesses"],
      "ReclaimableMCPKernels" -> Lookup[doctor["Reclaimable"], "ReclaimableMCPKernels", 0]
    |>];

SourceVaultDiagnosticsPanel[] :=
  Module[{doctor = SourceVaultSystemDoctor[], lic, topo, reclaim, rows},
    lic = doctor["License"];
    topo = doctor["Topology"];
    reclaim = doctor["Reclaimable"];
    rows = {
      {"Diagnostics version", $SourceVaultDiagnosticsVersion},
      {"Machine", iSVDiagMachineTag[]},
      {"Global health", doctor["GlobalHealth"]},
      {"License type", lic["LicenseType"]},
      {"Process slots", Row[{lic["LicenseProcesses"], " / ", lic["MaxLicenseProcesses"],
         "  (free: ", lic["ProcessSlotsFree"], ")"}]},
      {"Subprocess (subkernel) max", lic["MaxLicenseSubprocesses"]},
      {"Kernel classes", topo["ClassCounts"]},
      {"Seat-consuming kernels", topo["SeatConsumingCount"]},
      {"Reclaimable MCP kernels", reclaim["ReclaimableMCPKernels"]},
      {"Recommendation", reclaim["Recommendation"]}};
    Grid[rows, Alignment -> Left, Frame -> All,
      Background -> {None, {{None, GrayLevel[0.95]}}},
      Spacings -> {1, 0.6}]];

iSVDiagHealthColor[h_] :=
  Switch[h, "OK", Darker[Green], "Degraded", Darker[Orange, 0.3], "Failing", Red, _, Gray];

iSVDiagHealthBadge[h_] := Style[h, iSVDiagHealthColor[h], Bold];

iSVDiagLivenessColor[l_] :=
  Switch[l, "OK", Darker[Green], "Stale", Darker[Orange, 0.3],
    "OfflineOrSleeping", Gray, "Failing" | "NoHeartbeat", Red, _, Gray];

iSVDiagLivenessBadge[l_] := Style[l, iSVDiagLivenessColor[l], Bold];

(* machine / aggregator / cloud row for the band; placeholder until machines
   are registered so a single-PC setup stays uncluttered *)
iSVDiagBandMultiRow[] :=
  Module[{hbs = Quiet @ Check[SourceVaultDiagnosticsReadHeartbeats[], {}],
          cloud = Quiet @ Check[SourceVaultDiagnosticsCloudHeartbeat[], <||>], rollup, cloudTxt},
    cloudTxt = Row[{"  cloud: ", Lookup[cloud, "Channel", "?"],
      " (fallback ", Lookup[cloud, "Fallback", "?"], ")"}];
    If[!ListQ[hbs] || hbs === {},
      Style[Row[{"machine / aggregator: (no machines registered)", cloudTxt}], Gray, Italic, 10],
      rollup = iSVDiagRollupFromHeartbeats[hbs];
      Column[{
        Row[{"machines: ",
          Row[Riffle[
            Row[{#["MachineTag"], ":", iSVDiagLivenessBadge[#["Liveness"]]}] & /@
              rollup["Machines"], "   "]]}],
        Row[{"aggregator: ",
          Style[ToString[rollup["ActiveAggregator"]], Bold], cloudTxt}]},
        Spacings -> 0.2]]];

SourceVaultDiagnosticsStatusBand[] :=
  Module[{doctor = SourceVaultSystemDoctor["IncludeTopology" -> False],
          gh, comps, lic, compBadges},
    gh = doctor["GlobalHealth"];
    comps = Lookup[doctor, "ComponentHealth", <||>];
    lic = doctor["License"];
    compBadges = KeyValueMap[
      Row[{#1, ": ", iSVDiagHealthBadge[iSVDiagNormalizeHealth[#2]]}] &, comps];
    Framed[
      Column[{
        Row[{Style["SystemDoctor: ", Bold], iSVDiagHealthBadge[gh]}],
        Row[Riffle[compBadges, "   "]],
        Row[{"License: ", lic["LicenseProcesses"], "/", lic["MaxLicenseProcesses"],
          " proc (free ", lic["ProcessSlotsFree"], "),  subproc free ",
          Lookup[lic, "SubprocessSlotsFree", "?"], "/", lic["MaxLicenseSubprocesses"]}],
        iSVDiagBandMultiRow[]},
        Spacings -> 0.4],
      Background -> Switch[gh, "Failing", Lighter[Red, 0.7],
        "Degraded", Lighter[Yellow, 0.6], _, Lighter[Green, 0.8]],
      FrameStyle -> Gray, RoundingRadius -> 5, FrameMargins -> 8]];

(* ------------------------------------------------------------
   Lightweight diagnostics + shared-tick integration (rule 95:
   ride claudecode's shared polling base, no own ScheduledTask,
   no kernel spawn, no Front End from the tick context).
   ------------------------------------------------------------ *)

SourceVaultDiagnosticsLightweightDoctor[] :=
  SourceVaultSystemDoctor["IncludeTopology" -> False];

iSVDiagComprehensiveStaleQ[] :=
  Module[{last = $iSVDiagLastComprehensiveAt},
    If[!NumberQ[last], True,
      (AbsoluteTime[] - last) > $iSVDiagComprehensiveStaleSeconds]];

Options[SourceVaultDiagnosticsTick] = {"IntervalSeconds" -> 60, "Force" -> False};
SourceVaultDiagnosticsTick[opts : OptionsPattern[]] :=
  Module[{now = AbsoluteTime[], interval, last, stale, hb, status},
    interval = OptionValue["IntervalSeconds"];
    last = $iSVDiagLastTickTime;
    (* throttle: the shared tick fires every few seconds; do the body
       at most once per interval. *)
    If[!TrueQ[OptionValue["Force"]] && NumberQ[last] && (now - last) < interval,
      Return[<|"Status" -> "Throttled", "SinceLastSeconds" -> (now - last)|>]];
    $iSVDiagLastTickTime = now;
    hb = Quiet @ Check[
      SourceVaultDiagnosticsMachineHeartbeat["IncludeTopology" -> False], $Failed];
    (* stray stream release (weak coupling: core 不在なら no-op)。Abort/打ち切りで
       Open〜Close の間に取り残された vault 配下 stream はカーネル終了まで残り、
       開いた write ハンドルが Dropbox 同期を止め conflicted copy を作る。
       tick 境界 (この時点で正当な保持者はいない) で強制 Close する。 *)
    If[Length[DownValues[SourceVault`SourceVaultReleaseFileStreams]] > 0,
      Module[{swR = Quiet @ Check[SourceVault`SourceVaultReleaseFileStreams[], <||>]},
        If[AssociationQ[swR] && Lookup[swR, "Released", 0] > 0,
          Quiet @ Check[
            SourceVaultDiagnosticsLog[<|
              "Type" -> "DiagnosticsEvent",
              "Component" -> "VaultFileStreams",
              "Health" -> "OK",
              "ReasonCode" -> "StrayStreamsReleased",
              "Released" -> Lookup[swR, "Released", 0],
              "Files" -> Lookup[swR, "Files", {}]|>],
            Null]]]];
    stale = iSVDiagComprehensiveStaleQ[];
    If[stale,
      Quiet @ Check[
        SourceVaultDiagnosticsLog[<|
          "Type" -> "DiagnosticsEvent",
          "Component" -> "ComprehensiveDoctor",
          "Health" -> "Degraded",
          "ReasonCode" ->
            If[NumberQ[$iSVDiagLastComprehensiveAt], "DoctorStale", "DoctorNotRunning"]|>],
        Null]];
    status = <|
      "Status" -> "Ticked",
      "AtUTC" -> iSVDiagUTCNow[],
      "HeartbeatWritten" -> AssociationQ[hb],
      "ComprehensiveStale" -> stale,
      "GlobalHealth" -> If[AssociationQ[hb], Lookup[hb, "GlobalHealth", Missing[]], Missing[]]|>;
    $iSVDiagLastTickResult = status;
    status];

(* resolve a claudecode polling-base symbol by name, weakly (no intern) *)
iSVDiagClaudeSym[base_String] :=
  Module[{nm = Join[Names["ClaudeCode`" <> base], Names[base]]},
    If[Length[nm] == 0, $Failed, Symbol[First[nm]]]];

Options[SourceVaultDiagnosticsStartTick] = {"IntervalSeconds" -> 60};
SourceVaultDiagnosticsStartTick[opts : OptionsPattern[]] :=
  Module[{reg = iSVDiagClaudeSym["ClaudeRegisterPollingTick"],
          interval = OptionValue["IntervalSeconds"]},
    If[reg === $Failed,
      Return[<|"Status" -> "ClaudeCodeAbsent",
        "Note" -> "Shared polling base unavailable; tick not registered."|>]];
    Quiet @ Check[
      reg[$iSVDiagTickKey,
        Function[Null, SourceVaultDiagnosticsTick["IntervalSeconds" -> interval]],
        "Phase" -> "SourceVaultDiagnostics",
        "Caller" -> "SourceVaultDiagnostics",
        "Priority" -> 1,
        "Suppressible" -> True,
        "RunInline" -> True],
      $Failed];
    <|"Status" -> "Registered", "Key" -> $iSVDiagTickKey, "IntervalSeconds" -> interval|>];

SourceVaultDiagnosticsStopTick[] :=
  Module[{unreg = iSVDiagClaudeSym["ClaudeUnregisterPollingTick"]},
    If[unreg === $Failed, Return[<|"Status" -> "ClaudeCodeAbsent"|>]];
    Quiet @ Check[unreg[$iSVDiagTickKey], $Failed];
    <|"Status" -> "Unregistered", "Key" -> $iSVDiagTickKey|>];

(* ------------------------------------------------------------
   Escalation + notification-mail. DRY-RUN by default; real SMTP
   send (via SendMail through the connected Wolfram account) fires
   only after SourceVaultDiagnosticsConfigureMail enables it AND a
   recipient is configured. Mail is a different trust class from
   content mail: operator's own fixed address (from config, not
   hardcoded), metadata-only body (rule 90), per-event dedup plus a
   global rate limit.
   ------------------------------------------------------------ *)

iSVDiagMailConfigPath[] :=
  Module[{root = iSVDiagRoot[]},
    If[root === $Failed, $Failed,
      FileNameJoin[{root, "config", "diagnostics-mail.json"}]]];

iSVDiagLoadMailConfig[] :=
  Module[{path = iSVDiagMailConfigPath[], cfg},
    $iSVDiagMailConfigLoaded = True;
    If[path === $Failed || !FileExistsQ[path], Return[Null]];
    cfg = Quiet @ Check[Developer`ReadRawJSONString[ReadString[path]], $Failed];
    If[AssociationQ[cfg],
      If[StringQ[Lookup[cfg, "Recipient", Null]],
        $iSVDiagMailRecipient = cfg["Recipient"]];
      If[BooleanQ[Lookup[cfg, "Enabled", Null]],
        $iSVDiagMailEnabled = cfg["Enabled"]];
      If[IntegerQ[Lookup[cfg, "DedupWindowSeconds", Null]],
        $iSVDiagDedupWindowSeconds = cfg["DedupWindowSeconds"]]];
    Null];

iSVDiagEnsureMailConfig[] :=
  If[!TrueQ[$iSVDiagMailConfigLoaded], iSVDiagLoadMailConfig[]];

SourceVaultDiagnosticsMailConfig[] :=
  (iSVDiagEnsureMailConfig[];
   <|"Recipient" -> $iSVDiagMailRecipient,
     "Enabled" -> $iSVDiagMailEnabled,
     "DedupWindowSeconds" -> $iSVDiagDedupWindowSeconds,
     "Source" -> If[StringQ[iSVDiagMailConfigPath[]], iSVDiagMailConfigPath[], "session"]|>);

SourceVaultDiagnosticsConfigureMail[config_Association] :=
  Module[{path = iSVDiagMailConfigPath[], merged, w},
    iSVDiagEnsureMailConfig[];
    If[StringQ[Lookup[config, "Recipient", Null]],
      $iSVDiagMailRecipient = config["Recipient"]];
    If[BooleanQ[Lookup[config, "Enabled", Null]],
      $iSVDiagMailEnabled = config["Enabled"]];
    If[IntegerQ[Lookup[config, "DedupWindowSeconds", Null]],
      $iSVDiagDedupWindowSeconds = config["DedupWindowSeconds"]];
    merged = <|"Recipient" -> $iSVDiagMailRecipient,
      "Enabled" -> $iSVDiagMailEnabled,
      "DedupWindowSeconds" -> $iSVDiagDedupWindowSeconds|>;
    If[path =!= $Failed,
      iSVDiagEnsureDir[DirectoryName[path]];
      w = iSVDiagAtomicWrite[path, iSVDiagToJSON[merged]];
      If[w === $Failed,
        Return[Failure["MailConfigWriteFailed",
          <|"MessageTemplate" -> "Could not persist diagnostics mail config.",
            "Config" -> merged|>]]]];
    Append[merged, "Persisted" -> (path =!= $Failed)]];

(* should this event trigger a notification? *)
iSVDiagShouldMailQ[event_Association] :=
  Module[{sev = Lookup[event, "Severity", Lookup[event, "Priority", ""]],
          health = Lookup[event, "Health", ""]},
    TrueQ[Lookup[event, "Escalate", False]] ||
    MemberQ[{"High", "Critical"}, sev] ||
    health === "Failing"];

iSVDiagFEPresentQ[] :=
  TrueQ[Quiet @ Check[$FrontEnd =!= Null && Length[Notebooks[]] > 0, False]];

(* cloud-safe metadata only; no raw error text / private data (rule 90) *)
iSVDiagMailBody[event_Association] :=
  <|"ReasonCode" -> Lookup[event, "ReasonCode", Missing[]],
    "Component" -> Lookup[event, "Component", Missing[]],
    "Health" -> Lookup[event, "Health", Missing[]],
    "Severity" -> Lookup[event, "Severity", Missing[]],
    "MachineTag" -> iSVDiagMachineTag[],
    "AtUTC" -> iSVDiagUTCNow[],
    "SummaryURI" -> Lookup[event, "SummaryURI", Missing[]]|>;

(* metadata Association -> plain-text body (already cloud-safe: rule 90) *)
iSVDiagMailBodyText[body_] :=
  If[AssociationQ[body],
    StringRiffle[KeyValueMap[ToString[#1] <> ": " <> ToString[#2] &, body], "\n"],
    ToString[body]];

(* global rate limit so even a storm of DISTINCT events cannot flood mail
   (the per-(component,reasonCode) dedup is separate). *)
If[!ValueQ[$iSVDiagMailSendTimes], $iSVDiagMailSendTimes = {}];
If[!ValueQ[$iSVDiagMailMinIntervalSeconds], $iSVDiagMailMinIntervalSeconds = 60];
If[!ValueQ[$iSVDiagMailMaxPerHour], $iSVDiagMailMaxPerHour = 6];

iSVDiagMailRateState[now_] :=
  Module[{recent = Select[$iSVDiagMailSendTimes, (now - #) < 3600 &]},
    $iSVDiagMailSendTimes = recent;   (* prune > 1h *)
    <|"LastAgo" -> If[recent === {}, Infinity, now - Max[recent]],
      "CountLastHour" -> Length[recent]|>];

(* real send: SendMail (routes through the connected Wolfram account / cloud).
   Self-addressed, metadata-only, rate limited. Returns a result Association;
   never throws. Only ever called from the non-dry-run branch (mail enabled
   AND recipient configured). *)
iSVDiagSendMailReal[recipient_, subject_, body_] :=
  Module[{now = AbsoluteTime[], rate, bodyText, res, sent},
    If[!StringQ[recipient], Return[<|"Sent" -> False, "Reason" -> "NoRecipient"|>]];
    rate = iSVDiagMailRateState[now];
    Which[
      rate["LastAgo"] < $iSVDiagMailMinIntervalSeconds,
        Return[<|"Sent" -> False, "Reason" -> "RateLimited:MinInterval",
          "LastAgoSeconds" -> rate["LastAgo"]|>],
      rate["CountLastHour"] >= $iSVDiagMailMaxPerHour,
        Return[<|"Sent" -> False, "Reason" -> "RateLimited:MaxPerHour",
          "CountLastHour" -> rate["CountLastHour"]|>]];
    bodyText = iSVDiagMailBodyText[body];
    res = Quiet @ Catch[
      Check[SendMail["To" -> recipient, "Subject" -> subject, "Body" -> bodyText],
        $Failed], _, ($Failed &)];
    sent = res =!= $Failed && !FailureQ[res] && Head[res] =!= SendMail;
    If[sent,
      AppendTo[$iSVDiagMailSendTimes, now];
      <|"Sent" -> True, "Reason" -> "Sent", "AtUTC" -> iSVDiagUTCNow[]|>,
      <|"Sent" -> False, "Reason" -> "SendMailFailed"|>]];

(* ------------------------------------------------------------
   issue DB への弱結合 fan-out (issues spec v0.4 §4)。
   enqueue は machine-local outbox への短時間 append のみ。閾値判定・
   Unroutable 判定は issues 側 (SourceVaultIssueSignalEnqueue) が行う。
   reentrancy guard: issues 層自身の障害 event は再投入しない (V3-B5)。
   ------------------------------------------------------------ *)

iSVDiagIssueFanOut[event_Association] := Module[{comp, payload, e, r},
  comp = ToString @ Lookup[event, "Component", ""];
  If[ToString @ Lookup[event, "Producer", ""] === "issues" ||
     comp === "IssueDB" || StringStartsQ[comp, "IssueDB:"],
    Return[<|"Queued" -> False, "Reason" -> "Reentrant"|>]];
  If[Names["SourceVault`SourceVaultIssueSignalEnqueue"] === {} ||
     With[{s = Symbol["SourceVault`SourceVaultIssueSignalEnqueue"]},
       Length[DownValues[s]]] === 0,
    Return[<|"Queued" -> False, "Reason" -> "SinkUnavailable"|>]];
  payload = Replace[Lookup[event, "Payload", <||>],
    Except[_Association] -> <||>];
  (* DiagnosticsEvent (EventClass/Payload 形) -> 汎用 event への決定論 adapter *)
  e = <|
    "Producer" -> With[{p = ToString @ Lookup[event, "Producer", ""]},
      If[p === "", "diagnostics", p]],
    "Component" -> If[comp =!= "", comp,
      With[{c2 = ToString @ Lookup[payload, "Component",
          Lookup[payload, "Service", ""]]},
        If[c2 =!= "", c2, ToString @ Lookup[event, "EventClass", ""]]]],
    "ReasonCode" -> With[{rc = ToString @ Lookup[event, "ReasonCode", ""]},
      If[rc =!= "", rc, ToString @ Lookup[event, "EventClass", ""]]],
    "Severity" -> Lookup[event, "Severity",
      Lookup[event, "Priority", Missing["NotProvided"]]],
    "Health" -> Lookup[event, "Health", Missing["NotProvided"]],
    "Summary" -> ToString @ Lookup[event, "Summary",
      Lookup[event, "EventClass", ""]],
    "EventId" -> Lookup[event, "EventId", Missing["NotProvided"]],
    "ObservedAtUTC" -> Lookup[event, "ObservedAtUTC",
      Lookup[event, "AtUTC", Missing["NotProvided"]]],
    "MachineTag" -> Lookup[event, "MachineTag", Missing["NotProvided"]],
    "Escalate" -> Lookup[event, "Escalate", Missing["NotProvided"]],
    "SignalKind" -> Lookup[event, "SignalKind", Missing["NotProvided"]],
    "Correlation" -> Lookup[event, "Correlation", Missing["NotProvided"]]|>;
  e = DeleteCases[e, _Missing];
  r = Quiet @ Check[
    Symbol["SourceVault`SourceVaultIssueSignalEnqueue"][e], $Failed];
  Which[
    AssociationQ[r] && TrueQ[Lookup[r, "Queued", False]],
      <|"Queued" -> True, "Reason" -> ToString @ Lookup[r, "Reason", "Queued"],
        "EventId" -> ToString @ Lookup[r, "EventId", ""]|>,
    AssociationQ[r],
      <|"Queued" -> False, "Reason" -> ToString @ Lookup[r, "Reason", "?"]|>,
    True, <|"Queued" -> False, "Reason" -> "EnqueueFailed"|>]];

(* bus 入口: log + issue fan-out のみ (mail/FE escalation は Escalate 側)。 *)
SourceVaultDiagnosticsPublish[event_Association] :=
  Module[{enriched, logged, issue},
    enriched = Join[<|"AtUTC" -> iSVDiagUTCNow[],
      "MachineTag" -> iSVDiagMachineTag[]|>, event];
    If[! KeyExistsQ[enriched, "Type"],
      enriched = Append[enriched, "Type" -> "DiagnosticsEvent"]];
    logged = Quiet @ Check[SourceVaultDiagnosticsLog[enriched], $Failed];
    issue = iSVDiagIssueFanOut[enriched];
    <|"Logged" -> (logged =!= $Failed && ! FailureQ[logged]),
      "IssueSignalQueued" -> TrueQ[Lookup[issue, "Queued", False]],
      "IssueSignal" -> issue|>];

SourceVaultDiagnosticsEscalate[event_Association] :=
  Module[{enriched, fe, key, prior, now = AbsoluteTime[], coalesced,
          shouldMail, recipient, body, subject, dryRun, mailResult, mailIntent,
          forceMail, issueQ},
    iSVDiagEnsureMailConfig[];
    enriched = Join[
      <|"AtUTC" -> iSVDiagUTCNow[], "MachineTag" -> iSVDiagMachineTag[]|>, event];
    fe = iSVDiagFEPresentQ[];
    (* always record the event for the FE-side reader / audit *)
    Quiet @ Check[
      SourceVaultDiagnosticsLog[Append[enriched,
        "Type" -> "DiagnosticsEscalation"]], Null];
    (* issue DB fan-out (弱結合・enqueue のみ)。durable 化の成否は
       IssueSignalQueued として呼び手/監査へ返す (V3-B1)。 *)
    issueQ = iSVDiagIssueFanOut[enriched];
    (* dedup by (component, reasonCode) within the window *)
    key = {ToString @ Lookup[event, "Component", ""],
           ToString @ Lookup[event, "ReasonCode", ""]};
    prior = Lookup[$iSVDiagEscalationState, Key[key], <||>];
    coalesced = AssociationQ[prior] && NumberQ[Lookup[prior, "LastAtAbs", None]] &&
      (now - prior["LastAtAbs"]) < $iSVDiagDedupWindowSeconds;
    shouldMail = iSVDiagShouldMailQ[enriched] && !coalesced;
    $iSVDiagEscalationState[key] = <|
      "LastAtAbs" -> now,
      "Count" -> (Lookup[prior, "Count", 0] + 1)|>;
    If[!shouldMail,
      Return[<|"Escalated" -> False,
        "Reason" -> If[coalesced, "CoalescedWithinWindow", "BelowThreshold"],
        "FEPresent" -> fe, "Recorded" -> True,
        "IssueSignalQueued" -> TrueQ[Lookup[issueQ, "Queued", False]]|>]];
    recipient = $iSVDiagMailRecipient;
    body = iSVDiagMailBody[enriched];
    subject = "[SourceVault diagnostics] " <>
      ToString @ Lookup[enriched, "Health", "?"] <> " " <>
      ToString @ Lookup[enriched, "Component", "?"] <> " " <>
      ToString @ Lookup[enriched, "ReasonCode", "?"] <> " @ " <> iSVDiagMachineTag[];
    (* the operator's intent: when the FE is in use, surface in the status band,
       do NOT mail (mail is for when they are away from the machine = headless).
       "ForceMail"->True overrides (e.g. to test delivery from the FE). *)
    forceMail = TrueQ[Lookup[event, "ForceMail", False]];
    dryRun = !(TrueQ[$iSVDiagMailEnabled] && StringQ[recipient]) || (fe && !forceMail);
    mailResult = If[dryRun,
      <|"Sent" -> False, "Reason" ->
        Which[!TrueQ[$iSVDiagMailEnabled], "DryRun:MailDisabled",
              !StringQ[recipient], "DryRun:RecipientUnconfigured",
              fe && !forceMail, "DeferredToFEStatusBand",
              True, "DryRun"]|>,
      iSVDiagSendMailReal[recipient, subject, body]];
    mailIntent = <|
      "Type" -> "MailIntent",
      "DryRun" -> dryRun,
      "PrimaryChannel" -> If[fe, "FEStatusBand", "Mail"],
      "MailRole" -> If[fe, "DeferredFallback", "Primary"],
      "RecipientConfigured" -> StringQ[recipient],
      "Subject" -> subject,
      "Body" -> body,
      "MailResult" -> mailResult,
      "Component" -> Lookup[event, "Component", Missing[]],
      "ReasonCode" -> Lookup[event, "ReasonCode", Missing[]]|>;
    Quiet @ Check[SourceVaultDiagnosticsLog[mailIntent], Null];
    <|"Escalated" -> True,
      "FEPresent" -> fe,
      "PrimaryChannel" -> mailIntent["PrimaryChannel"],
      "DryRun" -> dryRun,
      "MailResult" -> mailResult,
      "Subject" -> subject,
      "IssueSignalQueued" -> TrueQ[Lookup[issueQ, "Queued", False]]|>];

(* ------------------------------------------------------------
   Spool ingest (hardening 05 Inc2, 2026-07-08)

   producer (claudecode / ClaudeRuntime / servicemanager) は
   iClaudeDiagEmit で machine-local per-process spool に書く。
   本関数がそれを正準 diagnostics-log へ転記する唯一の経路
   (単一書き手 = service kernel。P0-6 の多重追記を再導入しない)。

   冪等性:
     - offset sidecar (<spool>.ingest.json) による差分読み
     - EventId dedup (ingest-seen.json, 直近 20000 件)
       → sidecar 消失/巻き戻りでも二重転記しない
   部分行:
     - producer が書き込み途中の末尾行 (改行なし) はバイト位置で
       消費せず次回に回す (UTF-8 日本語でも安全なバイト単位処理)
   制限:
     - ローテート済み .jsonl.1 は対象外 (20MB 到達時のみ・稀)
   ------------------------------------------------------------ *)

If[! ValueQ[$SourceVaultDiagIngestIntervalSeconds],
  $SourceVaultDiagIngestIntervalSeconds = 60];
If[! ValueQ[SourceVault`$SourceVaultDiagSpoolRoot],
  SourceVault`$SourceVaultDiagSpoolRoot = Automatic];

iSVDiagSpoolDir[] := If[StringQ[SourceVault`$SourceVaultDiagSpoolRoot],
  SourceVault`$SourceVaultDiagSpoolRoot,
  FileNameJoin[{$UserBaseDirectory, "ApplicationData",
    "ClaudeRuntime", "diag-spool"}]];

iSVDiagAtomicWriteJSON[path_String, assoc_Association] :=
  Module[{ba, tmp, strm},
    ba = Quiet @ ExportByteArray[assoc, "RawJSON", "Compact" -> True];
    If[! ByteArrayQ[ba], Return[$Failed]];
    tmp = path <> ".tmp-" <> ToString[$ProcessID];
    strm = Quiet @ OpenWrite[tmp, BinaryFormat -> True];
    If[Head[strm] =!= OutputStream, Return[$Failed]];
    BinaryWrite[strm, ba]; Close[strm];
    Quiet @ Check[RenameFile[tmp, path, OverwriteTarget -> True]; path,
      Quiet @ DeleteFile[tmp]; $Failed]];

iSVDiagIngestSeenPath[] :=
  Module[{dir = iSVDiagMachineDir[]},
    If[dir === $Failed, $Failed,
      FileNameJoin[{dir, "ingest-seen.json"}]]];

(* hardening 05 Inc4: watchdog.log.jsonl (PS watchdog が書く DiagnosticsEvent
   schema 行) も ingest 対象にする。列挙は servicemanager の machine root へ
   弱結合 (service kernel は常に servicemanager を積んでいる)。単体テストから
   差し替えられるよう独立ヘルパにする。 *)
iSVDiagWatchdogLogFiles[] := Module[{root, mroot},
  (* 2026-07-09 fix: DownValues[Symbol["..."]] は HoldAll で機能しない
     (DownValues::sym)。With でシンボルを束縛してから DownValues を取る。 *)
  If[Names["SourceVault`ServiceManagerPrivate`iRuntimeMachineRoot"] === {} ||
     With[{sym = Symbol["SourceVault`ServiceManagerPrivate`iRuntimeMachineRoot"]},
       Length[DownValues[sym]]] === 0,
    Return[{}]];
  root = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed];
  If[! StringQ[root], Return[{}]];
  mroot = Quiet @ Check[
    Symbol["SourceVault`ServiceManagerPrivate`iRuntimeMachineRoot"][root],
    $Failed];
  If[! StringQ[mroot] || ! DirectoryQ[mroot], Return[{}]];
  Quiet @ Check[
    FileNames["watchdog.log.jsonl", FileNameJoin[{mroot, "services"}], 2],
    {}]];

SourceVaultDiagnosticsIngestSpool[] := Module[
  {dir = iSVDiagSpoolDir[], files, wdFiles, seenPath, seen, nowU,
   ingested = 0, corrupt = 0, pruned = 0, foreign = 0, today, ingestOne},
  seenPath = iSVDiagIngestSeenPath[];
  seen = If[StringQ[seenPath] && FileExistsQ[seenPath],
    Quiet @ Check[Import[seenPath, "RawJSON"], <||>], <||>];
  If[! AssociationQ[seen], seen = <||>];
  nowU = UnixTime[];
  today = DateString[TimeZoneConvert[Now, 0], {"Year", "Month", "Day"}];
  (* per-file 取り込み。pruneQ: 消化済み過去日 shard を削除してよいか
     (producer spool のみ)。requireTypeQ: Type=="DiagnosticsEvent" の行だけ
     取り込む (watchdog log は旧形式行が混在し得るため。旧形式は corrupt
     ではなく foreign として静かにスキップ)。 *)
  (* V3-B1 (issues spec v0.4 §4.4): raw spool の唯一 consumer として
     diagnostics-log と issue-outbox の両 sink へ fan-out する。
     - consumer 別 receipt: seen[eid] = <|"t","log","issue"|> (旧形式の
       整数値は両 sink 済みとみなす = 過去 event を遡って issue 化しない)
     - 行単位バイト消費: 全 sink 完了行だけ offset を進め、未完の行
       (issues 未ロード/一時 IO 失敗) で止めて次回へ。log 済み行の再読は
       receipt が二重転記を防ぐ。
     - prune は全行・全 sink 完了時のみ。 *)
  ingestOne = Function[{f, pruneQ, requireTypeQ}, Module[
      {sc = f <> ".ingest.json", off, size, strm, ba, bytes, lastNL = 0,
       text, rawLines, newOff, dateTag, stopped = False},
      off = Quiet @ Check[
        Lookup[Import[sc, "RawJSON"], "Offset", 0], 0];
      If[! IntegerQ[off] || off < 0, off = 0];
      size = Quiet @ Check[FileByteCount[f], 0];
      If[off > size, off = 0];   (* 巻き戻り (rotate 等) → dedup が守る *)
      newOff = off;
      If[size > off,
        strm = Quiet @ OpenRead[f, BinaryFormat -> True];
        If[Head[strm] === InputStream,
          Quiet @ SetStreamPosition[strm, off];
          ba = Quiet @ Check[ReadByteArray[strm, size - off], $Failed];
          Quiet @ Close[strm];
          If[ByteArrayQ[ba],
            bytes = Normal[ba];
            lastNL = Last[Flatten[Position[bytes, 10]], 0];
            If[lastNL > 0,
              text = Quiet @ Check[
                ByteArrayToString[ByteArray[bytes[[1 ;; lastNL]]], "UTF-8"],
                ""];
              (* All = 空行も保持 (バイト勘定のため)。text は \n 終端なので
                 末尾の空要素を 1 個落とす *)
              rawLines = StringSplit[text, "\n", All];
              If[rawLines =!= {} && Last[rawLines] === "",
                rawLines = Most[rawLines]];
              Catch[
                Scan[Function[raw, Module[
                    {lnBytes, ln, rec, eid, entry, logDone, issueDone,
                     issueRes},
                    lnBytes = Length[StringToByteArray[raw, "UTF-8"]] + 1;
                    ln = StringTrim[raw];
                    If[ln === "", newOff += lnBytes; Return[Null, Module]];
                    rec = Quiet @ Check[ImportByteArray[
                      StringToByteArray[ln, "UTF-8"], "RawJSON"], $Failed];
                    Which[
                      ! AssociationQ[rec],
                        If[requireTypeQ, foreign++, corrupt++];
                        newOff += lnBytes,
                      requireTypeQ &&
                        Lookup[rec, "Type", ""] =!= "DiagnosticsEvent",
                        foreign++; newOff += lnBytes,
                      True,
                        eid = Lookup[rec, "EventId", None];
                        entry = If[StringQ[eid], Lookup[seen, eid, None], None];
                        logDone = Which[IntegerQ[entry], True,
                          AssociationQ[entry],
                            TrueQ[Lookup[entry, "log", False]],
                          True, False];
                        issueDone = Which[IntegerQ[entry], True,
                          AssociationQ[entry],
                            MemberQ[{True, "NotApplicable"},
                              Lookup[entry, "issue", False]],
                          True, False];
                        If[! logDone,
                          logDone = (Quiet @ Check[
                            SourceVaultDiagnosticsLog[Join[rec,
                              <|"IngestedAtUTC" -> iSVDiagUTCNow[]|>]],
                            $Failed]) =!= $Failed;
                          If[logDone, ingested++]];
                        If[! issueDone,
                          issueRes = iSVDiagIssueFanOut[rec];
                          issueDone = Which[
                            TrueQ[Lookup[issueRes, "Queued", False]], True,
                            MemberQ[{"BelowThreshold", "Unroutable",
                                "Reentrant", "EventIdConflict"},
                              ToString @ Lookup[issueRes, "Reason", ""]],
                              "NotApplicable",
                            True, False]];
                        If[StringQ[eid],
                          seen[eid] = <|"t" -> nowU,
                            "log" -> TrueQ[logDone],
                            "issue" -> If[issueDone === "NotApplicable",
                              "NotApplicable", TrueQ[issueDone]]|>];
                        If[TrueQ[logDone] && issueDone =!= False,
                          newOff += lnBytes,
                          stopped = True; Throw[Null, iSVDiagStopTag]]]]],
                  rawLines],
                iSVDiagStopTag];
              iSVDiagAtomicWriteJSON[sc, <|"Offset" -> newOff|>]]]]];
      (* 消化済みの過去日 shard は削除 (producer 名-<pid>-<yyyymmdd>.jsonl)。
         watchdog log は長寿命ファイルなので prune しない (pruneQ=False)。
         未完 sink が残る間 (stopped) は prune しない (V3-B1)。 *)
      If[pruneQ && ! stopped,
        dateTag = Last[StringCases[FileBaseName[f],
          RegularExpression["(\\d{8})$"] -> "$1"], ""];
        If[newOff >= size && size === Quiet @ Check[FileByteCount[f], -1] &&
           dateTag =!= "" && dateTag =!= today,
          Quiet @ DeleteFile[f]; Quiet @ DeleteFile[sc]; pruned++]]]];
  files = If[DirectoryQ[dir],
    Quiet @ Check[FileNames["*.jsonl", dir], {}], {}];
  Scan[ingestOne[#, True, False] &, files];
  wdFiles = iSVDiagWatchdogLogFiles[];
  Scan[ingestOne[#, False, True] &, wdFiles];
  If[Length[seen] > 20000,
    (* receipt 値は旧形式 (整数 timestamp) と新形式 (<|"t",..|>) が混在 *)
    seen = Association @ Take[
      SortBy[Normal[seen],
        Function[kv, With[{v = Last[kv]},
          If[AssociationQ[v], Lookup[v, "t", 0], v]]]], -20000]];
  If[StringQ[seenPath], iSVDiagAtomicWriteJSON[seenPath, seen]];
  If[corrupt > 0,
    Quiet @ Check[SourceVaultDiagnosticsLog[<|
      "Type" -> "DiagnosticsEvent", "EventId" -> CreateUUID[],
      "EventClass" -> "SpoolLineCorrupt", "Producer" -> "servicemanager",
      "ProducerPid" -> $ProcessID, "Severity" -> "warn",
      "Payload" -> <|"Count" -> corrupt|>|>], Null]];
  <|"Ingested" -> ingested, "Corrupt" -> corrupt, "Foreign" -> foreign,
    "PrunedSpools" -> pruned,
    "Files" -> Length[files] + Length[wdFiles]|>];

End[];

EndPackage[];
