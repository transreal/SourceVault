(* :Title: SourceVault_mailagenda.wl *)
(* :Context: SourceVault` *)
(* :Summary: R9 mail agenda -- owner-directed actionable mails (reply needed /
   task or attendance requests) surfaced into the routine agenda, with a
   resolution state machine (Replied / NotebookCreated / Dismissed) and
   mail<->notebook inheritance links.
   Spec: SourceVault_info/design/sourcevault_routine_mail_agenda_spec_v0_1.md
   Design: deterministic-first (no LLM on the agenda path; reads the derived
   Category/Priority/Summary that SourceVaultInferMailDerivedBatch precomputed),
   index-only scan (no shard/body load except the lazy owner-direction probe),
   weak binding to maildb/identity (empty results when absent). *)

BeginPackage["SourceVault`"];

SourceVaultMailAgendaItems::usage =
  "SourceVaultMailAgendaItems[opts] returns the actionable-mail agenda items: mails \
within the window whose derived Category is a request (TaskRequest/AttendanceRequest/\
Confirmation, or with an inferred Deadline), that pass the SPAM/relevance gate \
(Priority >= $SourceVaultMailAgendaMinPriority), that are OWNER-directed (To contains \
an identity owner address; org address or body-addressee pattern raises the score, \
threshold $SourceVaultMailAgendaDirectionThreshold), and that are UNRESOLVED (no \
reply recorded in maildb interaction.json, not Dismissed, no inheriting notebook). \
Options: \"Mails\" (Automatic -> SourceVaultMailSearchIndex; inject index-row list \
for tests), \"Interactions\"/\"Resolutions\" (Automatic -> live; injectable), \
\"Window\" (days, Automatic -> $SourceVaultMailAgendaWindow), \"Now\" (test seam), \
\"SnapshotProbe\" (Automatic -> lazy decrypt probe for Cc/body addressee; None -> \
skip; injectable fn rid -> <|\"CcOwner\",\"OrgTo\",\"BodyAddressee\"|>), \
\"MaxPrivacyLevel\" (1.0; mails whose derived PrivacyLevel exceeds it are excluded, \
missing PL counts as 1.0 fail-safe). Same-thread mails (normalized subject + MBox, \
or an injected \"ThreadKeyFunction\") collapse into ONE item represented by the \
newest owner-directed member (ThreadCount/ThreadRecordIds carried); a thread is \
resolved when its latest resolution is after its latest inbound mail, and a newer \
Re: re-surfaces it. Returns items <|RecordId, Subject, From, Date, Category, \
Priority, Deadline, Summary, DirectionScore, DirectionEvidence, MBox, PrivacyLevel, \
ThreadCount, ThreadRecordIds|> newest first, plus PendingCount on the assoc.";

SourceVaultMailAgendaResolve::usage =
  "SourceVaultMailAgendaResolve[recordId, kind] records a resolution for a mail \
agenda item: kind \"Dismissed\" (confirmed, nothing to do) or \"NotebookCreated\" \
(with option \"NotebookPath\"). Stored content-minimized (RecordId only) in \
<mailStoreRoot>/agenda.json. The item disappears from SourceVaultMailAgendaItems.";

SourceVaultMailAgendaReopen::usage =
  "SourceVaultMailAgendaReopen[recordId] removes a stored resolution so the item \
is listed again.";

SourceVaultMailAgendaResolutions::usage =
  "SourceVaultMailAgendaResolutions[] returns the stored resolutions association \
(RecordId -> <|State, At, NotebookPath?|>).";

SourceVaultMailAgendaOpen::usage =
  "SourceVaultMailAgendaOpen[recordId] opens the mail-action window for an agenda \
item (front end): summary + explicit actions [返信する] (SourceVaultMailOpenReplyNotebook; \
sending records RepliedAt -> auto-Done), [ノートブックを作成して継承] \
(SourceVaultMailAgendaInherit), [確認のみ・対応済み] (Resolve Dismissed), plus \
thread view (SourceVaultMailThreadNotebook) and body display.";

SourceVaultMailAgendaInherit::usage =
  "SourceVaultMailAgendaInherit[recordId, opts] creates an inheriting work notebook \
in $onWork for the mail: newNote-style metadata cell <|Title (subject), Keywords, \
Status->Todo, Deadline (inferred, if any), MailRecordId|> plus an open-original-mail \
button cell. Records NotebookCreated in agenda.json (item leaves the agenda), emits \
an inheritance event to $SourceVaultMailAgendaEventSink (mining layer seam). \
Options: \"Directory\" (Automatic -> Global`$onWork), \"Open\" (True -> SystemOpen), \
\"Deadline\", \"Title\". Returns <|Status, NotebookPath, RecordId|>.";

SourceVaultMailForNotebook::usage =
  "SourceVaultMailForNotebook[nbPathOrNotebookObject] reads the MailRecordId metadata \
of an inheriting notebook (non-evaluating parse) and opens the mail thread \
(SourceVaultMailThreadNotebook), so the original mail AND its later replies are one \
step away from the work notebook. Returns the RecordId, or Missing if the notebook \
has no mail link.";

$SourceVaultMailAgendaWindow::usage =
  "$SourceVaultMailAgendaWindow: candidate scan window in days (default 45).";
$SourceVaultMailAgendaMinPriority::usage =
  "$SourceVaultMailAgendaMinPriority: derived-Priority threshold below which mails \
are excluded as spam/irrelevant (default 0.5).";
$SourceVaultMailAgendaDirectionThreshold::usage =
  "$SourceVaultMailAgendaDirectionThreshold: minimum owner-direction score to list \
an item (default 0.7).";
$SourceVaultMailAgendaOrgAddresses::usage =
  "$SourceVaultMailAgendaOrgAddresses: organisation mail addresses that count as \
owner-directed with score 0.6 (default {}; set per environment, e.g. via \
PrivateVault/config/mailagenda.json).";
$SourceVaultMailAgendaOwnerAddresses::usage =
  "$SourceVaultMailAgendaOwnerAddresses: fallback owner addresses when the identity \
layer (SourceVaultOwnerEmails) is unavailable (default {}).";
$SourceVaultMailAgendaAddresseePatterns::usage =
  "$SourceVaultMailAgendaAddresseePatterns: body addressee patterns (default \
{\"今井\"}) checked in the first part of the body to raise the direction score.";
$SourceVaultMailAgendaCategories::usage =
  "$SourceVaultMailAgendaCategories: derived categories treated as actionable \
(default {TaskRequest, AttendanceRequest, Confirmation}).";
$SourceVaultMailAgendaEventSink::usage =
  "$SourceVaultMailAgendaEventSink: None or a Function receiving canonical events \
(<|Type,RecordId,NotebookPath,At|>) for the mining/identity layer (rule-11 weak \
coupling; Inc3 wires the real sink).";

Begin["`MailAgendaPrivate`"];

(* ---------------- configuration ---------------- *)

If[!NumberQ[$SourceVaultMailAgendaWindow], $SourceVaultMailAgendaWindow = 45];
If[!NumberQ[$SourceVaultMailAgendaMinPriority], $SourceVaultMailAgendaMinPriority = 0.5];
If[!NumberQ[$SourceVaultMailAgendaDirectionThreshold],
  $SourceVaultMailAgendaDirectionThreshold = 0.7];
If[!ListQ[$SourceVaultMailAgendaOrgAddresses], $SourceVaultMailAgendaOrgAddresses = {}];
If[!ListQ[$SourceVaultMailAgendaOwnerAddresses], $SourceVaultMailAgendaOwnerAddresses = {}];
If[!ListQ[$SourceVaultMailAgendaAddresseePatterns],
  $SourceVaultMailAgendaAddresseePatterns = {"\:4eca\:4e95"}];
If[!ListQ[$SourceVaultMailAgendaCategories],
  $SourceVaultMailAgendaCategories = {"TaskRequest", "AttendanceRequest", "Confirmation"}];
If[!MatchQ[$SourceVaultMailAgendaEventSink, None | _Function],
  $SourceVaultMailAgendaEventSink = None];

(* environment config (keeps personal addresses out of the source): *)
iSVMAConfigPath[] := Quiet@Check[FileNameJoin[{
    SourceVault`$SourceVaultRoots["PrivateVault"], "config", "mailagenda.json"}], $Failed];
iSVMAConfigLoad[] := Module[{p = iSVMAConfigPath[], j},
  If[!StringQ[p] || !FileExistsQ[p], Return[Null]];
  j = Quiet@Check[Developer`ReadRawJSONString[
    ByteArrayToString[ReadByteArray[p], "UTF-8"]], $Failed];
  If[!AssociationQ[j], Return[Null]];
  If[ListQ[j["OrgAddresses"]], $SourceVaultMailAgendaOrgAddresses = j["OrgAddresses"]];
  If[ListQ[j["OwnerAddresses"]], $SourceVaultMailAgendaOwnerAddresses = j["OwnerAddresses"]];
  If[ListQ[j["AddresseePatterns"]],
    $SourceVaultMailAgendaAddresseePatterns = j["AddresseePatterns"]];
  If[NumberQ[j["MinPriority"]], $SourceVaultMailAgendaMinPriority = N[j["MinPriority"]]];
  If[NumberQ[j["Window"]], $SourceVaultMailAgendaWindow = N[j["Window"]]];
  Null];
Quiet[iSVMAConfigLoad[]];

(* ---------------- small helpers ---------------- *)

iSVMAAbs[t_?NumberQ] := N[t];
iSVMAAbs[t_DateObject] := Quiet@Check[AbsoluteTime[t], $Failed];
iSVMAAbs[t_String] := Quiet@Check[AbsoluteTime[DateObject[t]], $Failed];
iSVMAAbs[_] := $Failed;

(* extract lowercase addresses from a raw header value; use maildb's parser when live *)
iSVMAParseEmails[s_String] := Module[{r},
  r = If[Length[DownValues[SourceVault`SourceVaultMailParseEmails]] > 0,
    Quiet@Check[SourceVault`SourceVaultMailParseEmails[s], $Failed], $Failed];
  If[!ListQ[r],
    r = StringCases[s, RegularExpression["[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+"]]];
  ToLowerCase /@ Select[r, StringQ]];
iSVMAParseEmails[_] := {};

iSVMAOwnerEmails[] := Module[{ids},
  ids = If[Length[DownValues[SourceVault`SourceVaultOwnerEmails]] > 0,
    Quiet@Check[SourceVault`SourceVaultOwnerEmails[], {}], {}];
  If[!ListQ[ids], ids = {}];
  DeleteDuplicates[ToLowerCase /@ Select[
    Join[ids, $SourceVaultMailAgendaOwnerAddresses], StringQ]]];

(* the identity owner entity (user DB #1 / OwnerKind Self) is the AUTHORITY for
   the org addresses, the addressee-name patterns and the primary mbox; the
   $SourceVaultMailAgenda* globals / config file are fallbacks only. Register:
   SourceVaultUpdateEntity[1, <|"OrgEmails"->{...}, "PrimaryMBox"->"univ",
     "AddresseePatterns"->{...}|>] *)
iSVMAOwnerEntity[] :=
  If[Length[DownValues[SourceVault`SourceVaultOwnerEntity]] > 0,
    Quiet@Check[SourceVault`SourceVaultOwnerEntity[], Missing["NoOwner"]],
    Missing["NoIdentity"]];

iSVMAOrgEmails[] := Module[{e = iSVMAOwnerEntity[], fromId = {}},
  If[AssociationQ[e],
    With[{o = Lookup[e, "OrgEmails", Missing[]]},
      If[ListQ[o], fromId = Select[o, StringQ]]]];
  DeleteDuplicates[ToLowerCase /@ Select[
    Join[fromId, $SourceVaultMailAgendaOrgAddresses], StringQ]]];

(* addressee patterns: explicit entity field first; else derived from the
   owner's registered Names (Kanji surname = first token, plus each Romaji
   token so English mail greetings like "Dear Prof. Imai" match); the
   $SourceVaultMailAgendaAddresseePatterns fallback is always unioned in.
   Matching is case-insensitive (IMAI / imai). *)
iSVMAAddresseePatterns[] := Module[{e = iSVMAOwnerEntity[], pats = {}},
  If[AssociationQ[e],
    With[{p = Lookup[e, "AddresseePatterns", Missing[]]},
      If[ListQ[p], pats = Select[p, StringQ]]];
    If[pats === {},
      Module[{names = Lookup[e, "Names", <||>], kj, rj},
        If[!AssociationQ[names], names = <||>];
        kj = Lookup[names, "Kanji", Missing[]];
        rj = Lookup[names, "Romaji", Missing[]];
        If[StringQ[kj] && StringTrim[kj] =!= "",
          AppendTo[pats, First[StringSplit[kj, " " | "\:3000"], kj]]];
        If[StringQ[rj],
          pats = Join[pats,
            Select[StringSplit[rj, " " | "."], StringLength[#] >= 3 &]]]]]];
  DeleteDuplicates[Select[Join[pats, $SourceVaultMailAgendaAddresseePatterns],
    StringQ[#] && StringTrim[#] =!= "" &]]];

iSVMAPrimaryMBox[] := Module[{e = iSVMAOwnerEntity[]},
  If[AssociationQ[e],
    With[{m = Lookup[e, "PrimaryMBox", Missing[]]},
      If[StringQ[m] && StringTrim[m] =!= "", m, All]], All]];

(* ---------------- resolution sidecar (<mailStoreRoot>/agenda.json) ---------------- *)

If[!AssociationQ[$iSVMAStore], $iSVMAStore = <||>];
If[!BooleanQ[$iSVMAStoreLoaded], $iSVMAStoreLoaded = False];

iSVMAStorePath[] := Module[{root},
  root = If[Length[DownValues[SourceVault`SourceVaultMailStoreRoot]] > 0,
    Quiet@Check[SourceVault`SourceVaultMailStoreRoot[], $Failed], $Failed];
  If[StringQ[root], FileNameJoin[{root, "agenda.json"}], $Failed]];

iSVMALoad[] := Module[{p = iSVMAStorePath[], j},
  If[!StringQ[p] || !FileExistsQ[p], $iSVMAStoreLoaded = True; Return[$iSVMAStore]];
  j = Quiet@Check[Developer`ReadRawJSONString[
    ByteArrayToString[ReadByteArray[p], "UTF-8"]], $Failed];
  If[AssociationQ[j], $iSVMAStore = j];
  $iSVMAStoreLoaded = True; $iSVMAStore];

(* save with UTF-8 single encoding + atomic rename (JSONL lesson).
   merge -> True (default) folds in on-disk entries from other sessions;
   merge -> False overwrites (needed by Reopen: a load-merge-save would
   resurrect the entry just deleted). *)
iSVMASave[merge_ : True] := Module[{p = iSVMAStorePath[], tmp, bytes},
  If[!StringQ[p], Return[$Failed]];
  If[TrueQ[merge] && FileExistsQ[p],
    Module[{onDisk = Quiet@Check[Developer`ReadRawJSONString[
        ByteArrayToString[ReadByteArray[p], "UTF-8"]], <||>]},
      If[AssociationQ[onDisk], $iSVMAStore = Join[onDisk, $iSVMAStore]]]];
  bytes = Quiet@Check[StringToByteArray[
    Developer`WriteRawJSONString[$iSVMAStore], "UTF-8"], $Failed];
  If[Head[bytes] =!= ByteArray, Return[$Failed]];
  tmp = p <> ".tmp" <> ToString[$ProcessID];
  (* 過去の Abort/打ち切りで p / tmp に残った stray stream を先に解放 (Windows では
     開きっぱなしハンドルが RenameFile 置換や Dropbox 同期を阻害する) *)
  If[Length[DownValues[SourceVault`SourceVaultReleaseFileStreams]] > 0,
    Quiet[SourceVault`SourceVaultReleaseFileStreams[p];
      SourceVault`SourceVaultReleaseFileStreams[tmp]]];
  Quiet@Check[
    Module[{strm = OpenWrite[tmp, BinaryFormat -> True]},
      WithCleanup[BinaryWrite[strm, bytes], Quiet @ Close[strm]]];
    RenameFile[tmp, p, OverwriteTarget -> True]; p, $Failed]];

SourceVault`SourceVaultMailAgendaResolutions[] := (iSVMALoad[]; $iSVMAStore);

Options[SourceVault`SourceVaultMailAgendaResolve] = {"NotebookPath" -> None};
SourceVault`SourceVaultMailAgendaResolve[rid_String,
    kind : ("Dismissed" | "NotebookCreated"), OptionsPattern[]] := Module[{entry},
  iSVMALoad[];
  entry = <|"State" -> kind, "At" -> DateString["ISODateTime"]|>;
  If[StringQ[OptionValue["NotebookPath"]],
    entry["NotebookPath"] = OptionValue["NotebookPath"]];
  $iSVMAStore[rid] = entry;
  iSVMASave[];
  <|"Status" -> "OK", "RecordId" -> rid, "State" -> kind|>];
SourceVault`SourceVaultMailAgendaResolve[___] :=
  <|"Status" -> "Failed",
    "Reason" -> "expects [recordId_String, \"Dismissed\"|\"NotebookCreated\"]"|>;

SourceVault`SourceVaultMailAgendaReopen[rid_String] := (
  iSVMALoad[]; KeyDropFrom[$iSVMAStore, rid]; iSVMASave[False];
  <|"Status" -> "OK", "RecordId" -> rid|>);
SourceVault`SourceVaultMailAgendaReopen[___] := <|"Status" -> "Failed"|>;

(* ---------------- shard ensure (body access) ----------------
   The agenda pipeline runs on the lightweight index only; snapshot BODIES
   live in monthly shards that are NOT in memory. SourceVaultMailSnapshotGet
   reads the in-memory store only, so body actions (\:8fd4\:4fe1/\:672c\:6587\:8868\:793a) and the
   decrypt probe would fail with Reason NotFound (misleadingly hinting at
   credentials) unless the record's shard is lazily loaded first. The index
   row carries the ShardKey ("mbox/yyyymm"); SourceVaultMailEnsureLoaded is
   idempotent, so this loads each needed shard exactly once. *)
iSVMAEnsureShard[rid_String] := Module[{row, sk, parts},
  If[Length[DownValues[SourceVault`SourceVaultMailIndexGet]] === 0 ||
     Length[DownValues[SourceVault`SourceVaultMailEnsureLoaded]] === 0,
    Return[False]];
  row = Quiet@Check[SourceVault`SourceVaultMailIndexGet[rid], Missing[]];
  If[!AssociationQ[row], Return[False]];
  sk = Lookup[row, "ShardKey", Missing[]];
  If[!StringQ[sk], Return[False]];
  parts = StringSplit[sk, "/"];
  If[Length[parts] =!= 2, Return[False]];
  Quiet@Check[
    SourceVault`SourceVaultMailEnsureLoaded[parts[[1]], parts[[2]]]; True,
    False]];
iSVMAEnsureShard[___] := False;

(* ---------------- lazy snapshot probe (Cc / body addressee) ---------------- *)

(* returns <|"CcOwner"->bool,"OrgTo"->bool,"BodyAddressee"->bool|> reading the
   snapshot ONCE; cached under the sidecar so re-runs never decrypt again. *)
iSVMASnapshotProbe[rid_String] := Module[{cached, snap, md, cc, toAll, body, res,
    owner = iSVMAOwnerEmails[], org = iSVMAOrgEmails[]},
  iSVMALoad[];
  cached = Lookup[Lookup[$iSVMAStore, rid, <||>], "Probe", Missing[]];
  If[AssociationQ[cached], Return[cached]];
  If[Length[DownValues[SourceVault`SourceVaultMailSnapshotGet]] === 0,
    Return[<|"CcOwner" -> False, "OrgTo" -> False, "BodyAddressee" -> False|>]];
  iSVMAEnsureShard[rid];   (* snapshot bodies live in lazily-loaded shards *)
  snap = Quiet@Check[SourceVault`SourceVaultMailSnapshotGet[rid], $Failed];
  If[!AssociationQ[snap],
    Return[<|"CcOwner" -> False, "OrgTo" -> False, "BodyAddressee" -> False|>]];
  md = Lookup[snap, "MailMetadataPublic", <||>];
  cc = iSVMAParseEmails[Lookup[md, "Cc", ""]];
  toAll = Join[iSVMAParseEmails[Lookup[md, "To", ""]], cc];
  body = Quiet@Check[Module[{d = SourceVault`SourceVaultMailSnapshotDecryptBody[snap]},
    Which[AssociationQ[d] && StringQ[d["Body"]], d["Body"],
      StringQ[d], d, True, ""]], ""];
  If[!StringQ[body], body = ""];
  res = <|
    "CcOwner" -> (Intersection[cc, owner] =!= {}),
    "OrgTo" -> (Intersection[toAll, org] =!= {}),
    "BodyAddressee" -> AnyTrue[iSVMAAddresseePatterns[],
      StringContainsQ[StringTake[body, UpTo[400]], #,
        IgnoreCase -> True] &]|>;
  $iSVMAStore[rid] = Append[Lookup[$iSVMAStore, rid, <||>], "Probe" -> res];
  iSVMASave[];
  res];

(* ---------------- direction score ---------------- *)

(* index-only stage: returns <|"Score","Evidence","NeedProbe"|> *)
iSVMADirectionBase[toRaw_, owner_List, org_List] := Module[{emails},
  emails = iSVMAParseEmails[If[StringQ[toRaw], toRaw, ""]];
  Which[
    Intersection[emails, owner] =!= {},
      <|"Score" -> 1.0, "Evidence" -> {"DirectTo"}, "NeedProbe" -> False|>,
    Intersection[emails, org] =!= {},
      <|"Score" -> 0.6, "Evidence" -> {"OrgTo"}, "NeedProbe" -> True|>,
    True,
      <|"Score" -> 0., "Evidence" -> {}, "NeedProbe" -> True|>]];

iSVMADirectionFinal[base_Association, probe_] := Module[
  {score = base["Score"], ev = base["Evidence"]},
  If[AssociationQ[probe],
    If[TrueQ[probe["CcOwner"]] && score < 0.7,
      score = 0.7; AppendTo[ev, "CcOwner"]];
    If[TrueQ[probe["OrgTo"]] && score < 0.6,
      score = 0.6; AppendTo[ev, "OrgTo"]];
    If[TrueQ[probe["BodyAddressee"]] && score > 0.,
      score = Min[score + 0.3, 0.95]; AppendTo[ev, "BodyAddressee"]]];
  <|"Score" -> score, "Evidence" -> ev|>];

(* ---------------- thread key (session grouping) ---------------- *)

(* normalized subject = thread key, same rule as maildb's ThreadNotebook
   (strip Re:/Fwd:/FW: prefixes repeatedly, lowercase, collapse whitespace);
   computable from the index row alone. *)
iSVMANormSubject[s_] := If[!StringQ[s], "",
  Module[{t = ToLowerCase@StringTrim[s]},
    t = FixedPoint[StringTrim@StringReplace[#,
      StartOfString ~~ RegularExpression["(re|fwd|fw)\\s*[:\:ff1a]\\s*"] -> ""] &, t];
    StringReplace[t, RegularExpression["\\s+"] -> " "]]];

iSVMAThreadKey[row_Association] :=
  ToString[Lookup[row, "MBox", ""]] <> "|" <>
    iSVMANormSubject[Lookup[row, "Subject", ""]];

(* latest resolution instant (abs) across a thread's record ids:
   interaction RepliedAt and agenda-sidecar At; a resolution without a parseable
   At counts as Infinity (always resolved -- legacy entries). *)
iSVMAResolvedAbs[rids_List, interactions_, resolutions_] := Module[{ts = {}},
  Do[Module[{rep, res},
    rep = Lookup[Lookup[interactions, rid, <||>], "RepliedAt", Missing[]];
    If[StringQ[rep],
      With[{a = iSVMAAbs[rep]}, AppendTo[ts, If[NumberQ[a], a, Infinity]]]];
    res = Lookup[resolutions, rid, <||>];
    If[MemberQ[{"Dismissed", "NotebookCreated"},
        Lookup[res, "State", Missing[]]],
      With[{a = iSVMAAbs[Lookup[res, "At", Missing[]]]},
        AppendTo[ts, If[NumberQ[a], a, Infinity]]]]],
    {rid, rids}];
  If[ts === {}, -Infinity, Max[ts]]];

(* ---------------- the pipeline ---------------- *)

(* fail-safe privacy read: a missing/non-numeric derived PrivacyLevel counts
   as 1.0 (same convention as maildb's iSVMDConfidentialQ) *)
iSVMAPrivacyOf[rowOrItem_] := With[
  {p = Lookup[rowOrItem, "PrivacyLevel", Missing[]]},
  If[NumberQ[p], N[p], 1.0]];

Options[SourceVault`SourceVaultMailAgendaItems] = {
  "Mails" -> Automatic, "Interactions" -> Automatic, "Resolutions" -> Automatic,
  "Window" -> Automatic, "Now" -> Automatic, "SnapshotProbe" -> Automatic,
  "ThreadKeyFunction" -> Automatic, "MaxItems" -> 60, "MaxPrivacyLevel" -> 1.0,
  "MBox" -> Automatic};

SourceVault`SourceVaultMailAgendaItems[OptionsPattern[]] := Module[
  {nowAbs, windowDays, fromAbs, rows, interactions, resolutions, owner, org,
   probeFn, keyFn, cands = {}, groups, items = {}, pending = 0,
   minPr = $SourceVaultMailAgendaMinPriority,
   thr = $SourceVaultMailAgendaDirectionThreshold, maxPL},
  maxPL = With[{m = OptionValue["MaxPrivacyLevel"]},
    If[NumberQ[m], N[m], 1.0]];
  nowAbs = With[{n = OptionValue["Now"]},
    If[n === Automatic, N[AbsoluteTime[]], iSVMAAbs[n]]];
  windowDays = With[{w = OptionValue["Window"]},
    If[NumberQ[w], N[w], N[$SourceVaultMailAgendaWindow]]];
  fromAbs = nowAbs - windowDays*86400.;

  (* stage 0: rows from the lightweight index (never loads shard bodies),
     restricted to the owner's primary mbox from the identity entity unless
     overridden ("MBox" -> All scans every mbox) *)
  rows = With[{m = OptionValue["Mails"]},
    If[m === Automatic,
      If[Length[DownValues[SourceVault`SourceVaultMailSearchIndex]] > 0,
        Module[{mbox = OptionValue["MBox"]},
          If[mbox === Automatic, mbox = iSVMAPrimaryMBox[]];
          Quiet@Check[SourceVault`SourceVaultMailSearchIndex["",
            "DateFrom" -> DateObject[FromAbsoluteTime[fromAbs]],
            "MBox" -> If[mbox === All, Automatic, mbox],
            "Limit" -> 1000], {}]], {}],
      m]];
  If[!ListQ[rows], rows = {}];

  interactions = With[{i = OptionValue["Interactions"]},
    If[i === Automatic,
      If[Length[DownValues[SourceVault`SourceVaultMailInteractionStats]] > 0,
        Quiet@Check[SourceVault`SourceVaultMailInteractionStats[], <||>], <||>],
      i]];
  If[!AssociationQ[interactions], interactions = <||>];
  resolutions = With[{r = OptionValue["Resolutions"]},
    If[r === Automatic, SourceVault`SourceVaultMailAgendaResolutions[], r]];
  If[!AssociationQ[resolutions], resolutions = <||>];
  owner = iSVMAOwnerEmails[]; org = iSVMAOrgEmails[];
  probeFn = With[{p = OptionValue["SnapshotProbe"]},
    Which[p === Automatic, iSVMASnapshotProbe, p === None, None, True, p]];
  keyFn = With[{k = OptionValue["ThreadKeyFunction"]},
    If[k === Automatic, iSVMAThreadKey, k]];

  (* pass 1: window / category / priority gates -> candidates *)
  Do[Module[{rid, dateAbs, cat, prio, deadline},
    rid = Lookup[row, "RecordId", Missing[]];
    dateAbs = iSVMAAbs[Lookup[row, "Date", Missing[]]];
    If[!StringQ[rid] || !NumberQ[dateAbs] || dateAbs < fromAbs, Continue[]];
    cat = Lookup[row, "Category", Missing["NotGenerated"]];
    deadline = Lookup[row, "Deadline", Missing[]];
    prio = Lookup[row, "Priority", Missing["NotGenerated"]];
    If[MatchQ[cat, Missing["NotGenerated"]] && !NumberQ[prio],
      pending++; Continue[]];
    If[!(MemberQ[$SourceVaultMailAgendaCategories, cat] || StringQ[deadline]),
      Continue[]];
    If[NumberQ[prio] && prio < minPr, Continue[]];
    (* privacy gate: mails above MaxPrivacyLevel never enter the agenda
       (missing PL counts as 1.0, fail-safe) *)
    If[iSVMAPrivacyOf[row] > maxPL, Continue[]];
    AppendTo[cands, Append[row, "DateAbs" -> dateAbs]]],
    {row, rows}];

  (* pass 2: group by thread (mail session). A thread is resolved when its
     latest resolution instant is AFTER its latest inbound mail (so a new Re:
     arriving after a reply/dismiss re-surfaces the thread as a fresh request).
     The representative is the NEWEST member that passes the owner-direction
     gate; the whole thread is one agenda item. *)
  groups = GroupBy[cands, Quiet@Check[keyFn[#], "?"] &];
  Do[Module[{g = Reverse[SortBy[grp, #["DateAbs"] &]], rids, latestAbs,
      resolvedAbs, rep = Missing[], repDir = Missing[]},
    rids = Lookup[#, "RecordId"] & /@ g;
    latestAbs = First[g]["DateAbs"];
    resolvedAbs = iSVMAResolvedAbs[rids, interactions, resolutions];
    If[resolvedAbs >= latestAbs, Continue[]];
    (* newest-first: first member that is owner-directed represents the thread *)
    Do[Module[{base, probe, dir},
      base = iSVMADirectionBase[Lookup[cand, "ToRaw", Missing[]], owner, org];
      dir = If[base["Score"] >= thr || probeFn === None ||
          !TrueQ[base["NeedProbe"]],
        KeyTake[base, {"Score", "Evidence"}],
        probe = Quiet@Check[probeFn[Lookup[cand, "RecordId", ""]], $Failed];
        iSVMADirectionFinal[base, If[AssociationQ[probe], probe, <||>]]];
      If[dir["Score"] >= thr, rep = cand; repDir = dir; Break[]]],
      {cand, g}];
    If[!AssociationQ[rep], Continue[]];
    AppendTo[items, <|
      "RecordId" -> Lookup[rep, "RecordId", ""],
      "Subject" -> Lookup[rep, "Subject", ""],
      "From" -> Lookup[rep, "From", ""],
      "Date" -> rep["DateAbs"],
      "Category" -> Lookup[rep, "Category", Missing[]],
      "Priority" -> Lookup[rep, "Priority", Missing[]],
      "Deadline" -> Lookup[rep, "Deadline", Missing[]],
      "Summary" -> Lookup[rep, "Summary", Missing[]],
      "DirectionScore" -> repDir["Score"],
      "DirectionEvidence" -> repDir["Evidence"],
      "MBox" -> Lookup[rep, "MBox", Missing[]],
      "PrivacyLevel" -> iSVMAPrivacyOf[rep],
      "ThreadCount" -> Length[g],
      "ThreadRecordIds" -> rids|>]],
    {grp, Values[groups]}];

  items = Take[Reverse[SortBy[items, #["Date"] &]],
    UpTo[OptionValue["MaxItems"]]];
  <|"Items" -> items, "PendingCount" -> pending|>];
SourceVault`SourceVaultMailAgendaItems[___] := <|"Items" -> {}, "PendingCount" -> 0|>;

(* ---------------- inheritance notebook (R9-6) ---------------- *)

iSVMASafeFileName[s_String] := Module[{t},
  t = StringReplace[s, {"/" -> "-", "\\" -> "-", ":" -> "-", "*" -> "-", "?" -> "-",
    "\"" -> "'", "<" -> "(", ">" -> ")", "|" -> "-", "\n" -> " ", "\r" -> ""}];
  StringTrim[StringTake[t, UpTo[24]]]];

iSVMAEmitEvent[ev_Association] :=
  If[MatchQ[$SourceVaultMailAgendaEventSink, _Function],
    Quiet@Check[$SourceVaultMailAgendaEventSink[ev], Null], Null];

Options[SourceVault`SourceVaultMailAgendaInherit] = {
  "Directory" -> Automatic, "Open" -> True, "Deadline" -> Automatic,
  "Title" -> Automatic};

SourceVault`SourceVaultMailAgendaInherit[rid_String, OptionsPattern[]] := Module[
  {dir, row, subject, deadline, meta, nbPath, cells, buttonCell, res},
  dir = With[{d = OptionValue["Directory"]},
    If[d === Automatic, Quiet@Check[Symbol["Global`$onWork"], $Failed], d]];
  If[!StringQ[dir] || !DirectoryQ[dir],
    Return[<|"Status" -> "Failed", "Reason" -> "NoDirectory", "Directory" -> dir|>]];
  row = If[Length[DownValues[SourceVault`SourceVaultMailIndexGet]] > 0,
    Quiet@Check[SourceVault`SourceVaultMailIndexGet[rid], <||>], <||>];
  If[!AssociationQ[row], row = <||>];
  subject = With[{t = OptionValue["Title"]},
    If[StringQ[t], t, Lookup[row, "Subject", "mail task"]]];
  If[!StringQ[subject], subject = "mail task"];
  deadline = With[{d = OptionValue["Deadline"]},
    If[d === Automatic, Lookup[row, "Deadline", Missing[]], d]];
  meta = <|"Title" -> subject, "Keywords" -> {"mail"}, "Status" -> "Todo"|>;
  If[StringQ[deadline],
    With[{dl = Quiet@Check[DateObject[StringTake[deadline, UpTo[10]]], $Failed]},
      If[DateObjectQ[dl], meta["Deadline"] = dl]]];
  If[DateObjectQ[deadline], meta["Deadline"] = deadline];
  meta["MailRecordId"] = rid;
  nbPath = FileNameJoin[{dir,
    DateString[{"Year", "Month", "Day"}] <> "-" <> iSVMASafeFileName[subject] <> ".nb"}];
  If[FileExistsQ[nbPath],
    nbPath = StringReplace[nbPath, ".nb" ~~ EndOfString ->
      "-" <> ToString[UnixTime[]] <> ".nb"]];
  buttonCell = Cell[BoxData[ToBoxes[
    Button["\:2709 \:5143\:30e1\:30fc\:30eb\:30fb\:8fd4\:4fe1\:3092\:958b\:304f",
      SourceVault`SourceVaultMailForNotebook[nbPath], Method -> "Queued"]]], "Input"];
  (* the metadata cell is written as InputForm TEXT: it round-trips exactly via
     ToExpression[str, InputForm, HoldComplete] (non-evaluating), so the NBAccess
     safe extractor sees DateObject[{y,m,d}] literally (whitelist form). A
     StandardForm TemplateBox would re-parse into the long DateObject form. *)
  cells = {
    Cell[subject, "Title"],
    Cell[ToString[Defer[Evaluate[meta]], InputForm], "Input",
      InitializationCell -> True],
    buttonCell};
  (* privacy inheritance: the note embeds mail content (subject + a body
     link), so it explicitly declares itself non-publishable. Absent tagging
     already means PL 1.0 fail-safe; writing it makes the inheritance
     explicit and survives any future default change. *)
  res = Quiet@Check[Export[nbPath,
    Notebook[cells,
      TaggingRules -> {"SourceVault" -> {"CloudPublishable" -> False}}],
    "NB"], $Failed];
  If[res === $Failed,
    Return[<|"Status" -> "Failed", "Reason" -> "ExportFailed", "Path" -> nbPath|>]];
  SourceVault`SourceVaultMailAgendaResolve[rid, "NotebookCreated",
    "NotebookPath" -> nbPath];
  iSVMAEmitEvent[<|"Type" -> "MailInheritedByNotebook", "RecordId" -> rid,
    "NotebookPath" -> nbPath, "At" -> DateString["ISODateTime"]|>];
  If[TrueQ[OptionValue["Open"]], Quiet[SystemOpen[nbPath]]];
  <|"Status" -> "OK", "NotebookPath" -> nbPath, "RecordId" -> rid|>];
SourceVault`SourceVaultMailAgendaInherit[___] :=
  <|"Status" -> "Failed", "Reason" -> "expects [recordId_String, opts]"|>;

(* ---------------- notebook -> mail back-navigation ---------------- *)

(* non-evaluating metadata read: Import Notebook -> first init/input cell ->
   MakeExpression -> NBAccess safe extractor (whitelist incl. MailRecordId). *)
iSVMARecordIdFromNotebook[path_String] := Module[{nb, inits, first, held, meta},
  nb = Quiet@Check[Import[path, "Notebook"], $Failed];
  If[Head[nb] =!= Notebook, Return[Missing["Unreadable"]]];
  inits = Cases[nb, Cell[bx_, ___, InitializationCell -> True, ___] :> bx, Infinity];
  If[inits === {}, inits = Cases[nb, Cell[b_BoxData, "Input", ___] :> b, Infinity]];
  If[inits === {}, Return[Missing["NoMetadata"]]];
  first = First[inits];
  (* text cells (our own Inherit output) parse via ToExpression+HoldComplete
     (non-evaluating); box cells via MakeExpression *)
  held = Which[
    StringQ[first],
      Quiet@Check[ToExpression[first, InputForm, HoldComplete], $Failed],
    True,
      Quiet@Check[MakeExpression[first, StandardForm], $Failed]];
  If[!MatchQ[held, _HoldComplete], Return[Missing["ParseFailed"]]];
  meta = If[Length[DownValues[NBAccess`NBOnWorkTaskSafeExtract]] > 0,
    Quiet@Check[NBAccess`NBOnWorkTaskSafeExtract[held], <||>], <||>];
  If[!AssociationQ[meta], meta = <||>];
  Lookup[meta, "MailRecordId", Missing["NoMailLink"]]];

SourceVault`SourceVaultMailForNotebook[path_String] := Module[{rid},
  rid = iSVMARecordIdFromNotebook[path];
  If[!StringQ[rid], Return[rid]];
  If[Length[DownValues[SourceVault`SourceVaultMailThreadNotebook]] > 0,
    Quiet@Check[SourceVault`SourceVaultMailThreadNotebook[rid], Null]];
  rid];
SourceVault`SourceVaultMailForNotebook[nb_NotebookObject] :=
  With[{p = Quiet@Check[NotebookFileName[nb], $Failed]},
    If[StringQ[p], SourceVault`SourceVaultMailForNotebook[p],
      Missing["NotebookNotSaved"]]];
SourceVault`SourceVaultMailForNotebook[___] := Missing["BadArgs"];

(* ---------------- action window (front end) ---------------- *)

iSVMAKindLabel[cat_, deadline_] := Which[
  cat === "TaskRequest", "\:4f9d\:983c",
  cat === "AttendanceRequest", "\:51fa\:5e2d",
  cat === "Confirmation", "\:78ba\:8a8d",
  StringQ[deadline], "\:3006\:5207",
  True, "\:8981\:5bfe\:5fdc"];

SourceVault`SourceVaultMailAgendaOpen[rid_String] := Module[
  {row, subject, summary, nb},
  row = If[Length[DownValues[SourceVault`SourceVaultMailIndexGet]] > 0,
    Quiet@Check[SourceVault`SourceVaultMailIndexGet[rid], <||>], <||>];
  If[!AssociationQ[row], row = <||>];
  subject = Lookup[row, "Subject", rid];
  summary = Lookup[row, "Summary", Missing[]];
  nb = CreateDocument[{
    Cell[If[StringQ[subject], subject, rid], "Section"],
    Cell[TextData[{
      "From: " <> ToString[Lookup[row, "From", "?"]] <> "\:3000\:3000" <>
      ToString[Lookup[row, "Date", ""]]}], "Text"],
    If[StringQ[summary], Cell[summary, "Text", FontColor -> GrayLevel[0.3]],
      Nothing],
    Cell[BoxData[ToBoxes[Row[{
      Button[Style["\:21a9 \:8fd4\:4fe1\:3059\:308b", Bold],
        (iSVMAEnsureShard[rid];
         SourceVault`SourceVaultMailOpenReplyNotebook[rid]), Method -> "Queued",
        ImageSize -> Automatic],
      "  ",
      Button[Style["\:1f4d3 \:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:4f5c\:6210\:3057\:3066\:7d99\:627f", Bold],
        SourceVault`SourceVaultMailAgendaInherit[rid], Method -> "Queued",
        ImageSize -> Automatic],
      "  ",
      Button["\:2713 \:78ba\:8a8d\:306e\:307f\:30fb\:5bfe\:5fdc\:6e08\:307f",
        (SourceVault`SourceVaultMailAgendaResolve[rid, "Dismissed"];
         NotebookClose[EvaluationNotebook[]]), Method -> "Queued",
        ImageSize -> Automatic]}]]], "Output"],
    Cell[BoxData[ToBoxes[Row[{
      Button["\:2630 \:30b9\:30ec\:30c3\:30c9\:5168\:4f53\:3092\:8868\:793a",
        SourceVault`SourceVaultMailThreadNotebook[rid], Method -> "Queued"],
      "  ",
      Button["\:2709 \:672c\:6587\:3092\:8868\:793a",
        (iSVMAEnsureShard[rid];
         SourceVault`SourceVaultMailShowBody[rid]), Method -> "Queued"]}]]],
      "Output"]},
    WindowTitle -> "\:8981\:5bfe\:5fdc: " <> If[StringQ[subject],
      StringTake[subject, UpTo[40]], rid],
    WindowSize -> {560, 320}];
  nb];
SourceVault`SourceVaultMailAgendaOpen[item_Association] :=
  SourceVault`SourceVaultMailAgendaOpen[Lookup[item, "RecordId", ""]];
SourceVault`SourceVaultMailAgendaOpen[___] := $Failed;

End[];

EndPackage[];
