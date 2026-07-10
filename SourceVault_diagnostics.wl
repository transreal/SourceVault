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

SourceVaultDiagnosticsLightweightDoctor::usage =
  "SourceVaultDiagnosticsLightweightDoctor[] runs a cheap doctor: license probe + \
service health + registered probes, but SKIPS the kernel-topology CIM probe \
(no shell-out). Suitable for the shared polling tick. = \
SourceVaultSystemDoctor[\"IncludeTopology\" -> False].";

SourceVaultDiagnosticsTick::usage =
  "SourceVaultDiagnosticsTick[] is the lightweight body called by the shared \
polling tick. Throttled (default 60s); each run writes a lightweight machine \
heartbeat (no topology) and emits DoctorStale when the comprehensive doctor has \
not run within its freshness window. Never spawns a kernel or touches the Front \
End. Returns a short status. Safe to call manually.";

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

SourceVaultDiagnosticsEscalate[event_Association] :=
  Module[{enriched, fe, key, prior, now = AbsoluteTime[], coalesced,
          shouldMail, recipient, body, subject, dryRun, mailResult, mailIntent,
          forceMail},
    iSVDiagEnsureMailConfig[];
    enriched = Join[
      <|"AtUTC" -> iSVDiagUTCNow[], "MachineTag" -> iSVDiagMachineTag[]|>, event];
    fe = iSVDiagFEPresentQ[];
    (* always record the event for the FE-side reader / audit *)
    Quiet @ Check[
      SourceVaultDiagnosticsLog[Append[enriched,
        "Type" -> "DiagnosticsEscalation"]], Null];
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
        "FEPresent" -> fe, "Recorded" -> True|>]];
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
      "Subject" -> subject|>];

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

iSVDiagSpoolDir[] := FileNameJoin[{$UserBaseDirectory, "ApplicationData",
  "ClaudeRuntime", "diag-spool"}];

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
  ingestOne = Function[{f, pruneQ, requireTypeQ}, Module[
      {sc = f <> ".ingest.json", off, size, strm, ba, bytes, lastNL = 0,
       text, lines, newOff, dateTag},
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
              lines = Select[StringTrim /@ StringSplit[text, "\n"],
                # =!= "" &];
              Scan[Function[ln, Module[{rec, eid},
                  rec = Quiet @ Check[ImportByteArray[
                    StringToByteArray[ln, "UTF-8"], "RawJSON"], $Failed];
                  Which[
                    ! AssociationQ[rec],
                      If[requireTypeQ, foreign++, corrupt++],
                    requireTypeQ &&
                      Lookup[rec, "Type", ""] =!= "DiagnosticsEvent",
                      foreign++,
                    True,
                      eid = Lookup[rec, "EventId", None];
                      If[! (StringQ[eid] && KeyExistsQ[seen, eid]),
                        Quiet @ Check[
                          SourceVaultDiagnosticsLog[Join[rec,
                            <|"IngestedAtUTC" -> iSVDiagUTCNow[]|>]], Null];
                        If[StringQ[eid], seen[eid] = nowU];
                        ingested++]]]],
                lines];
              newOff = off + lastNL;
              iSVDiagAtomicWriteJSON[sc, <|"Offset" -> newOff|>]]]]];
      (* 消化済みの過去日 shard は削除 (producer 名-<pid>-<yyyymmdd>.jsonl)。
         watchdog log は長寿命ファイルなので prune しない (pruneQ=False)。 *)
      If[pruneQ,
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
    seen = Association @ Take[SortBy[Normal[seen], Last], -20000]];
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
