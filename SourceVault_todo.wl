(* ::Package:: *)

(* :Title: SourceVault_todo.wl *)
(* :Context: SourceVault` *)
(* :Summary: Unified todo cache database.
   Sources:
     (1) notebook-derived todos -- read INDEX-FIRST from the existing
         notebooks/sources/*.json + snapshots (TodosCompressed), never
         re-importing .nb files on the query path. Done/Keep notebooks keep
         their open todo items visible (the whole point of this layer).
     (2) standalone todos -- items not belonging to any notebook
         (<PrivateVault>/todo/items/<id>.json). Created by SourceVaultNewTodo,
         the palette template, the mail agenda inherit-todo button, the
         Wolfram Cloud RegisterTodoForm inbox, or SourceVaultTodoForSummary
         (a reminder attached to an existing eagle/source/mail summary).
   Overlays (<PrivateVault>/todo/overlays/<id>.json) carry user-side state for
   notebook todos WITHOUT writing into the .nb: Done marking, deadline fixes,
   LLM summaries, and the RECURRENCE marker ("done this year -> resurface next
   year"), which also works for standalone items.
   Notes: like the Eagle summary notes, SourceVaultTodoShowSummary opens a
   summary notebook with a save button; the saved note (todo/notes/*.nb) is
   the canonical user-annotated version and its text joins the search index.
   Search: SourceVaultTodos (core, List[Association]) / SourceVaultTodosView
   (view) pair, plus a "todo" provider in $SourceVaultSummaryProviders so
   todos surface in SourceVaultSummaries / CrossLinks like every summary.
   Pure ASCII (Japanese as \:XXXX escapes). Weak coupling everywhere:
   loads and degrades gracefully when siblings are absent. *)

BeginPackage["SourceVault`"];

SourceVaultTodos::usage =
  "SourceVaultTodos[query, opts] returns the unified todo list as \
List[Association] (core function; chain with Select/SortBy or render with \
SourceVaultTodosView). Merges notebook-derived todos (index-first from the \
notebook snapshot store; notebooks whose Status is Done/Keep still contribute \
their open items) with standalone todos (manual / cloud form / mail-inherited \
/ summary-linked). Effective Status applies the per-todo overlay (Done marks, \
recurrence resurfacing) on top of the notebook cell state. Options: \
\"Status\" (\"Open\" default | \"All\" | list | string), \"Origin\" (All | \
\"notebook\" | \"standalone\"), \"Source\" (All | \"manual\"|\"cloud\"|\
\"mail\"|\"summary\"), \"HasDeadline\" (All|True|False), \"DueWithinDays\" \
(None | days: only items due within n days, overdue included), \"Limit\". \
Record keys include TodoId, Text, Title, Status, Deadline, DeadlineSource, \
Recur, Summary, HasNote, NotebookPath, NotebookTitle, NotebookStatus, \
PrivacyLevel, AddedAt, URI.";

SourceVaultTodosView::usage =
  "SourceVaultTodosView[query, opts] renders SourceVaultTodos as a Grid with \
row actions (done mark, recurrence marker, open note / notebook). Display is \
capped at $SourceVaultTodoViewMaxRows (\"MaxRows\" option). All core options \
pass through.";

SourceVaultTodoGet::usage =
  "SourceVaultTodoGet[todoId] returns the effective merged record for one \
todo id (notebook or standalone), or Missing[\"NotFound\"].";

SourceVaultNewTodo::usage =
  "SourceVaultNewTodo[spec] creates a standalone todo (not belonging to any \
notebook). spec keys: \"Title\" (required), \"Description\", \"Deadline\" \
(DateObject | \"yyyy-mm-dd\" | None), \"PrivacyLevel\" (default 1.0 fail-\
safe), \"Source\" (default \"manual\"), \"MailRecordId\", \"LinkKind\"/\
\"LinkId\" (attach to an existing summary), \"Recur\". \
SourceVaultNewTodo[title] is shorthand. Returns <|\"Status\",\"TodoId\",...|>.";

SourceVaultNewTodoTemplate::usage =
  "SourceVaultNewTodoTemplate[] inserts an editable SourceVaultNewTodo[<|...|>] \
input template cell into the current notebook (expression-centric input UI; \
used by the claudecode palette button).";

SourceVaultTodoSetStatus::usage =
  "SourceVaultTodoSetStatus[todoId, status] sets the effective status \
(\"Open\"|\"Done\"|\"Pass\"|\"Keep\"). For notebook todos this writes the \
OVERLAY only (the .nb cell is untouched; use SourceVaultMarkTodo to edit the \
cell itself). SourceVaultTodoSetStatus[todoId, Automatic] clears the overlay \
override. Done marks record DoneAt, Pass marks record PassAt; both are \
recurrence anchors (a Passed item with a review cycle resurfaces at the \
next cycle just like a Done one).";

SourceVaultTodoDone::usage =
  "SourceVaultTodoDone[todoId] marks a todo Done (records DoneAt; keeps any \
recurrence marker so the item resurfaces next cycle).";

SourceVaultTodoRemindNext::usage =
  "SourceVaultTodoRemindNext[todoId, cycle] adds a recurrence marker: after \
the todo is Done, it resurfaces as Open when the next cycle comes due \
(lead window $SourceVaultTodoRecurLeadDays days before). cycle: \"Yearly\" | \
\"HalfYearly\" | \"Quarterly\" | \"Monthly\" | \"Weekly\" | None (remove). \
Typical use: mark an annual carry-over item Done, then RemindNext \
\"Yearly\". SourceVaultTodoRemindNext[todoId, cycle, leadDays] also \
sets the lead window explicitly (Automatic = the cycle-scaled default).";

SourceVaultTodoPass::usage =
  "SourceVaultTodoPass[todoId] marks a todo Pass (\"skipped this time\"; \
records PassAt). With a review cycle set, the item resurfaces at the next \
cycle exactly as a Done one does.";

SourceVaultTodoUpdate::usage =
  "SourceVaultTodoUpdate[todoId, spec] applies several settings in one \
write (what the settings panel apply button calls). spec keys: \
\"Status\" (\"Open\"|\"Done\"|\"Pass\"|\"Keep\"|Automatic), \
\"Deadline\" (DateObject | \"yyyy-mm-dd\" | \"yyyy/mm/dd\" | None to \
clear, which also suppresses the text-parsed deadline), \"Priority\" \
(0..1), \"PrivacyLevel\" (0..1 | Automatic to drop an override), \
\"Recur\" (cycle string | None) and \"RecurLeadDays\". Notebook todos \
get an overlay, standalone todos are updated in place. Returns \
<|\"Status\", \"TodoId\", \"Applied\"|>.";

SourceVaultTodoSetDeadline::usage =
  "SourceVaultTodoSetDeadline[todoId, date] sets the deadline (DateObject or \
\"yyyy-mm-dd\"/\"yyyy/mm/dd\"). SourceVaultTodoSetDeadline[todoId, None] \
clears it AND suppresses the deadline the text parser would otherwise infer \
from the todo text, so a cleared deadline stays cleared.";

SourceVaultTodoSetPriority::usage =
  "SourceVaultTodoSetPriority[todoId, p] sets the importance 0..1 (0.5 is \
the neutral value used when nothing was set). Sort and filter with the \
\"SortBy\"->\"Priority\" and \"MinPriority\" options of SourceVaultTodos.";

SourceVaultTodoSetPrivacyLevel::usage =
  "SourceVaultTodoSetPrivacyLevel[todoId, pl] sets the privacy level of one \
todo, 0..1. For a notebook todo this OVERRIDES, for that item only, the \
level inherited from its notebook (an owner decision: it can raise or lower \
it); for a standalone todo it replaces the stored level. Automatic drops the \
override and returns to the inherited value.";

SourceVaultTodoEditPanel::usage =
  "SourceVaultTodoEditPanel[todoId] is the todo settings control (deadline, \
review cycle, importance, privacy level, Open/Done/Pass/Keep). It is shown \
inside the todo note window and from the list view settings button. Edits \
are collected in the panel and written by one SourceVaultTodoUpdate call.";

SourceVaultTodoEditWindow::usage =
  "SourceVaultTodoEditWindow[todoId] opens SourceVaultTodoEditPanel in its \
own window.";

SourceVaultTodoShowSummary::usage =
  "SourceVaultTodoShowSummary[todoId] opens the todo summary notebook \
(metadata + LLM summary + description). Like the Eagle summary window it has \
a save button; once saved under todo/notes/ the saved note (with your \
annotations) is opened instead and its text becomes searchable. \
Option \"Fresh\"->True regenerates ignoring the saved note.";

SourceVaultTodoBackfillSummaries::usage =
  "SourceVaultTodoBackfillSummaries[opts] generates LLM summaries for todos \
lacking one, and refines deadlines (a \"\:3006\:5207 yyyy/mm/dd\" pattern in the text is \
parsed deterministically first; the LLM confirms/extracts otherwise). \
Notebook-derived todos add notebook context (title/keywords + plaintext up to \
\"MaxChars\"). Text is wrapped as UNTRUSTED. Model routing (fail-closed): \
PL >= 0.5 rows (confidential convention; undeclared notebooks default to \
exactly 0.5) are sent ONLY to $ClaudePrivateModel (local LLM), passed \
explicitly so the hub's strict >0.5 test cannot route them to the cloud; \
when no valid private model is configured those rows are SKIPPED \
(PrivateModelUnavailable). Only PL < 0.5 rows use the cloud CLI. An explicit \
\"Model\" -> {provider, model, ...} is the owner's override and bypasses the \
guard. There is NO silent local->cloud fallback (the layer calls \
iCallSummaryLLM, never iCallSummaryLLMWithFallback). Options: \"Limit\" \
(10), \"Force\", \"Model\", \"MaxChars\" (6000), \"TimeoutSeconds\" (120), \
\"Status\" (\"Open\").";

SourceVaultTodoRebuildIndex::usage =
  "SourceVaultTodoRebuildIndex[opts] refreshes the notebook-todo cache. \
\"Scan\"->\"OnWork\" (default) incrementally re-indexes $onWork via the \
existing snapshot machinery; \"All\" also scans $offWork (slow the first \
time; needed once so archived Done notebooks contribute their open todos); \
\"None\" only re-reads existing index files. Returns counts.";

SourceVaultTodoAgendaItems::usage =
  "SourceVaultTodoAgendaItems[opts] returns OPEN standalone (non-notebook) \
todos shaped for the routine agenda (Kind \"Todo\", DueT, Label, TodoId, \
PrivacyLevel). PrivacySpec caps disclosure by PrivacyLevel (fail-safe 1.0). \
SourceVaultRoutineAgendaData folds these into the day list / overdue band and \
a dedicated todo band.";

SourceVaultTodoForSummary::usage =
  "SourceVaultTodoForSummary[kind, id, spec] attaches a todo/reminder to an \
existing summary row (kind = \"eagle\"|\"arxiv\"|\"web\"|\"local\"|\"mail\"|...; \
id = the row's Id). Creates a standalone todo with LinkKind/LinkId so the \
row action of that kind opens the original. spec like SourceVaultNewTodo \
(e.g. <|\"Recur\"->\"Yearly\", \"Title\"->\"...\"|> for a check-yearly \
document reminder).";

SourceVaultTodoDeployCloudForm::usage =
  "SourceVaultTodoDeployCloudForm[] deploys the Wolfram Cloud todo entry form \
to <cloudbase>/obj/<user>/RegisterTodoForm ($SourceVaultTodoCloudFormPath). \
Fields: item, description (optional), deadline (optional), PrivacyLevel; \
AddedAt is stamped automatically. Submissions land in the private cloud inbox \
$SourceVaultTodoCloudInboxPath (one object per submission). Requires \
$SourceVaultTodoAllowCloudDeploy = True (deploy guard).";

SourceVaultTodoCloudFetch::usage =
  "SourceVaultTodoCloudFetch[] fetches pending submissions from the cloud \
todo inbox, registers each as a standalone todo (Source \"cloud\"), and \
DELETES the cloud object after successful local persist (\"Delete\"->False \
to keep). Skips gracefully when not cloud-connected.";

SourceVaultTodoCloudSyncStart::usage =
  "SourceVaultTodoCloudSyncStart[] registers the periodic cloud-inbox fetch \
on the shared claudecode polling tick (opt-in; no own ScheduledTask). The \
fetch runs at most every $SourceVaultTodoCloudSyncIntervalHours hours (12 = \
about twice a day) and only when $CloudConnected. Set \
$SourceVaultTodoCloudSyncAutoStart = True in localInit to start on load. \
SourceVaultTodoCloudSyncStop[] unregisters; SourceVaultTodoCloudSyncStatus[] \
reports.";

SourceVaultTodoCloudSyncStop::usage =
  "SourceVaultTodoCloudSyncStop[] unregisters the periodic cloud todo fetch.";

SourceVaultTodoCloudSyncStatus::usage =
  "SourceVaultTodoCloudSyncStatus[] reports the periodic cloud todo fetch \
state (registered / last fetch / last result).";

$SourceVaultTodoStoreRoot::usage =
  "$SourceVaultTodoStoreRoot overrides the todo store root (default \
<PrivateVault>/todo).";
$SourceVaultTodoRecurLeadDays::usage =
  "$SourceVaultTodoRecurLeadDays: days before the next recurrence due date \
at which a Done recurring todo resurfaces as Open (default 30).";
$SourceVaultTodoViewMaxRows::usage =
  "$SourceVaultTodoViewMaxRows: max rows SourceVaultTodosView renders (200).";
$SourceVaultTodoCloudFormPath::usage =
  "$SourceVaultTodoCloudFormPath: cloud object name of the entry form \
(default \"RegisterTodoForm\").";
$SourceVaultTodoCloudInboxPath::usage =
  "$SourceVaultTodoCloudInboxPath: cloud directory holding pending form \
submissions (default \"todo-inbox\").";
$SourceVaultTodoAllowCloudDeploy::usage =
  "$SourceVaultTodoAllowCloudDeploy: deploy guard; SourceVaultTodoDeployCloudForm \
refuses unless True.";
$SourceVaultTodoCloudSyncIntervalHours::usage =
  "$SourceVaultTodoCloudSyncIntervalHours: minimum hours between automatic \
cloud inbox fetches (default 12).";
$SourceVaultTodoCloudSyncAutoStart::usage =
  "$SourceVaultTodoCloudSyncAutoStart: True -> SourceVaultTodoCloudSyncStart[] \
runs when SourceVault_todo loads (default False, rule 95 opt-in).";

Begin["`Private`"];

(* ============================================================
   Config defaults (idempotent re-Get)
   ============================================================ *)

If[! ValueQ[$SourceVaultTodoRecurLeadDays], $SourceVaultTodoRecurLeadDays = 30];
If[! IntegerQ[$SourceVaultTodoViewMaxRows] || $SourceVaultTodoViewMaxRows < 1,
  $SourceVaultTodoViewMaxRows = 200];
If[! StringQ[$SourceVaultTodoCloudFormPath],
  $SourceVaultTodoCloudFormPath = "RegisterTodoForm"];
If[! StringQ[$SourceVaultTodoCloudInboxPath],
  $SourceVaultTodoCloudInboxPath = "todo-inbox"];
If[! ValueQ[$SourceVaultTodoAllowCloudDeploy],
  $SourceVaultTodoAllowCloudDeploy = False];
If[! NumberQ[$SourceVaultTodoCloudSyncIntervalHours],
  $SourceVaultTodoCloudSyncIntervalHours = 12];
If[! ValueQ[$SourceVaultTodoCloudSyncAutoStart],
  $SourceVaultTodoCloudSyncAutoStart = False];

(* test seam: absolute-time "now" override *)
If[! ValueQ[$iSVTDNowOverride], $iSVTDNowOverride = None];
iSVTDNow[] := If[NumberQ[$iSVTDNowOverride], N[$iSVTDNowOverride],
  N[AbsoluteTime[]]];

SourceVaultTodos::cloudskip =
  "Cloud fetch skipped: `1`.";

(* ============================================================
   Store roots / JSON IO (Eagle-style atomic writes)
   ============================================================ *)

iSVTDStoreRoot[] :=
  If[StringQ[$SourceVaultTodoStoreRoot], $SourceVaultTodoStoreRoot,
    With[{r = Quiet@Check[SourceVault`$SourceVaultRoots["PrivateVault"], $Failed]},
      FileNameJoin[{If[StringQ[r], r, $TemporaryDirectory], "todo"}]]];

iSVTDLocalStateDir[] :=
  With[{r = Quiet@Check[SourceVault`$SourceVaultRoots["LocalState"], $Failed]},
    If[StringQ[r], r,
      With[{la = Environment["LOCALAPPDATA"]},
        FileNameJoin[{If[StringQ[la], la, $TemporaryDirectory], "SourceVault"}]]]];

iSVTDItemsDir[]   := FileNameJoin[{iSVTDStoreRoot[], "items"}];
iSVTDOverlayDir[] := FileNameJoin[{iSVTDStoreRoot[], "overlays"}];
iSVTDNotesDir[]   := FileNameJoin[{iSVTDStoreRoot[], "notes"}];

iSVTDEnsureDir[dir_String] :=
  If[! DirectoryQ[dir],
    Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];

iSVTDImportJSON[path_String] :=
  Module[{r},
    If[! FileExistsQ[path], Return[$Failed]];
    r = Quiet@Check[Developer`ReadRawJSONFile[path], $Failed];
    If[AssociationQ[r] || ListQ[r], r,
      Quiet@Check[Import[path, "RawJSON"], $Failed]]];

iSVTDAtomicExportJSON[path_String, expr_] :=
  Module[{tmp = path <> ".svtmp", r},
    r = Quiet@Check[Export[tmp, expr, "RawJSON", "Compact" -> True], $Failed];
    If[r === $Failed, Quiet@DeleteFile[tmp]; Return[$Failed]];
    Quiet@Check[
      RenameFile[tmp, path, OverwriteTarget -> True],
      Quiet@Check[DeleteFile[path]; RenameFile[tmp, path], $Failed]];
    If[FileExistsQ[path] && ! FileExistsQ[tmp], path, $Failed]];

iSVTDIsoNow[] :=
  DateString[DateObject[TimeZone -> 0], "ISODateTime"] <> "Z";

(* ============================================================
   Small shared helpers
   ============================================================ *)

iSVTDPLOf[a_Association] :=
  With[{p = Lookup[a, "PrivacyLevel", Missing[]]},
    If[NumericQ[p], N[p], 1.0]];
iSVTDPLOf[___] := 1.0;

(* an explicitly stored per-todo privacy level overrides the one inherited
   from the notebook; anything else keeps the inherited value *)
iSVTDPLPick[ov_Association, base_] :=
  With[{p = Lookup[ov, "PrivacyLevel", Missing[]]},
    If[NumericQ[p], N[Clip[p, {0., 1.}]], base]];
iSVTDPLPick[_, base_] := base;

(* importance 0..1; nothing stored means the neutral middle *)
$iSVTDDefaultPriority = 0.5;
iSVTDPriorityPick[a_Association] :=
  With[{p = Lookup[a, "Priority", Missing[]]},
    If[NumericQ[p], {N[Clip[p, {0., 1.}]], "Explicit"},
      {$iSVTDDefaultPriority, "Default"}]];
iSVTDPriorityPick[___] := {$iSVTDDefaultPriority, "Default"};

iSVTDPriorityOf[rec_] :=
  With[{p = Lookup[If[AssociationQ[rec], rec, <||>], "Priority", Missing[]]},
    If[NumericQ[p], N[p], $iSVTDDefaultPriority]];

(* Round[x, 0.01] leaves 0.7000000000000001 behind; go through hundredths as
   an integer so the stored JSON keeps clean two-decimal values *)
iSVTDClip01[x_] :=
  If[NumericQ[x], N[Round[100 N[Clip[x, {0., 1.}]]]/100], $Failed];

(* Deadline value -> DateObject (day) | Missing *)
iSVTDToDate[d_] := Which[
  DateObjectQ[d], DateObject[d, "Day"],
  StringQ[d] && StringTrim[d] =!= "",
    With[{o = Quiet@Check[DateObject[StringTake[StringTrim[d], UpTo[10]], "Day"],
        $Failed]},
      If[DateObjectQ[o], o, Missing["Unparsed"]]],
  True, Missing["None"]];

iSVTDDateAbs[d_] := With[{o = iSVTDToDate[d]},
  If[DateObjectQ[o], Quiet@Check[N[AbsoluteTime[o]], Missing[]], Missing[]]];

iSVTDIso[d_] := With[{o = iSVTDToDate[d]},
  If[DateObjectQ[o], DateString[o, "ISODate"], None]];

iSVTDShortDate[d_] := With[{o = iSVTDToDate[d]},
  If[DateObjectQ[o], DateString[o, {"Year", "/", "Month", "/", "Day"}], ""]];

(* stable content hash of a todo text (whitespace-insensitive) *)
iSVTDTextHash[text_String] :=
  StringTake[
    Hash[StringReplace[text, {WhitespaceCharacter -> "", "\:3000" -> ""}],
      "SHA256", "HexString"], 12];

iSVTDSafeFileName[s_String] :=
  StringTake[
    StringReplace[s,
      "\\" | "/" | ":" | "*" | "?" | "\"" | "<" | ">" | "|" | "\n" | "\r" -> "_"],
    UpTo[40]];

(* ============================================================
   Deterministic deadline extraction from todo text.
   "\:3006\:5207 yyyy/mm/dd" and friends parse with high confidence; a bare
   yyyy/mm/dd elsewhere in the text is low confidence. Month/day without a
   year resolves to the next occurrence relative to refAbs.
   ============================================================ *)

iSVTDDeadlineFromText[text_String] :=
  iSVTDDeadlineFromText[text, iSVTDNow[]];
iSVTDDeadlineFromText[text_String, refAbs_?NumberQ] :=
  Module[{kw, m, full, md, y, mo, dy, d},
    kw = "(?:\:3006\:5207|\:7de0\:5207|\:7de0\:3081\:5207\:308a|\:671f\:9650|deadline|due)";
    (* keyword + full date *)
    m = StringCases[text,
      RegularExpression[
        "(?i)" <> kw <> "[ \:3000:\:ff1a]*([0-9]{4})[/\\-\:5e74]([0-9]{1,2})[/\\-\:6708]([0-9]{1,2})"] ->
        {"$1", "$2", "$3"}, 1];
    If[m =!= {},
      {y, mo, dy} = ToExpression /@ First[m];
      d = Quiet@Check[DateObject[{y, mo, dy}], $Failed];
      If[DateObjectQ[d],
        Return[<|"Date" -> d, "Confidence" -> 0.9, "Source" -> "TextParse"|>]]];
    (* keyword + month/day without year: next occurrence *)
    md = StringCases[text,
      RegularExpression[
        "(?i)" <> kw <> "[ \:3000:\:ff1a]*([0-9]{1,2})[/\:6708]([0-9]{1,2})\:65e5?"] ->
        {"$1", "$2"}, 1];
    If[md =!= {},
      {mo, dy} = ToExpression /@ First[md];
      y = DateValue[FromAbsoluteTime[refAbs], "Year"];
      d = Quiet@Check[DateObject[{y, mo, dy}], $Failed];
      If[DateObjectQ[d] && N[AbsoluteTime[d]] < refAbs - 86400.,
        d = Quiet@Check[DateObject[{y + 1, mo, dy}], $Failed]];
      If[DateObjectQ[d],
        Return[<|"Date" -> d, "Confidence" -> 0.7, "Source" -> "TextParse"|>]]];
    (* bare full date anywhere (low confidence) *)
    full = StringCases[text,
      RegularExpression[
        "([0-9]{4})[/\\-\:5e74]([0-9]{1,2})[/\\-\:6708]([0-9]{1,2})"] ->
        {"$1", "$2", "$3"}, 1];
    If[full =!= {},
      {y, mo, dy} = ToExpression /@ First[full];
      d = Quiet@Check[DateObject[{y, mo, dy}], $Failed];
      If[DateObjectQ[d],
        Return[<|"Date" -> d, "Confidence" -> 0.4, "Source" -> "TextParse"|>]]];
    Missing["NoDeadline"]];
iSVTDDeadlineFromText[___] := Missing["NoDeadline"];

(* ============================================================
   Recurrence
   ============================================================ *)

$iSVTDRecurCycles = {"Yearly", "HalfYearly", "Quarterly", "Monthly", "Weekly"};

iSVTDCycleStep[cycle_String] := Switch[cycle,
  "Yearly", {1, "Year"}, "HalfYearly", {6, "Month"},
  "Quarterly", {3, "Month"}, "Monthly", {1, "Month"},
  "Weekly", {1, "Week"}, _, {1, "Year"}];

(* cycle-scaled default lead: a flat 30 days would cover a whole Monthly /
   Weekly cycle and the item would never rest. $SourceVaultTodoRecurLeadDays
   remains the Yearly figure and an upper bound for the shorter cycles. *)
iSVTDDefaultLeadDays[cycle_String] :=
  With[{base = If[NumberQ[$SourceVaultTodoRecurLeadDays],
      N[$SourceVaultTodoRecurLeadDays], 30.]},
    Switch[cycle,
      "Yearly", base,
      "HalfYearly", Min[21., base],
      "Quarterly", Min[14., base],
      "Monthly", Min[7., base],
      "Weekly", Min[2., base],
      _, base]];

(* next due strictly after afterAbs, stepping from anchor date *)
iSVTDNextRecurDue[anchor_?DateObjectQ, cycle_String, afterAbs_?NumberQ] :=
  Module[{step = iSVTDCycleStep[cycle], d = DateObject[anchor, "Day"], k = 0},
    While[k < 200 && N[AbsoluteTime[d]] <= afterAbs,
      d = Quiet@Check[DatePlus[d, step], $Failed];
      If[! DateObjectQ[d], Return[Missing["RecurFailed"]]];
      k++];
    If[k >= 200, Missing["RecurFailed"], d]];
iSVTDNextRecurDue[___] := Missing["RecurFailed"];

(* apply recurrence to an effective record: a CLOSED item (Done, or Pass =
   skipped this time) with a review cycle resurfaces as Open with the advanced
   deadline once inside the lead window. Pass is what makes the cycle a review
   cycle rather than a done-only one: "not this round, ask me again next time". *)
iSVTDClosedStamp[rec_Association] :=
  With[{st = Lookup[rec, "Status", ""]},
    Which[
      st === "Done", Lookup[rec, "DoneAt", Missing["None"]],
      st === "Pass", With[{p = Lookup[rec, "PassAt", Missing[]]},
        If[StringQ[p], p, Lookup[rec, "DoneAt", Missing["None"]]]],
      True, Missing["None"]]];

iSVTDApplyRecur[rec_Association, nowAbs_?NumberQ] :=
  Module[{recur = Lookup[rec, "Recur", Missing[]], cycle, anchor, doneAbs,
      next, lead, nextAbs, stamp},
    If[! MemberQ[{"Done", "Pass"}, Lookup[rec, "Status", ""]] ||
        ! AssociationQ[recur],
      Return[rec]];
    cycle = Lookup[recur, "Cycle", Missing[]];
    If[! StringQ[cycle], Return[rec]];
    stamp = iSVTDClosedStamp[rec];
    doneAbs = With[{a = iSVTDDateAbs[stamp]}, If[NumberQ[a], a, nowAbs]];
    anchor = With[{d = Lookup[rec, "Deadline", Missing[]]},
      If[DateObjectQ[d], d,
        With[{dd = iSVTDToDate[stamp]},
          If[DateObjectQ[dd], dd,
            iSVTDToDate[Lookup[rec, "AddedAt", Missing[]]]]]]];
    If[! DateObjectQ[anchor], Return[rec]];
    next = iSVTDNextRecurDue[anchor, cycle, doneAbs];
    If[! DateObjectQ[next], Return[rec]];
    lead = With[{l = Lookup[recur, "LeadDays", Missing[]]},
      If[NumberQ[l], N[l], iSVTDDefaultLeadDays[cycle]]];
    nextAbs = N[AbsoluteTime[next]];
    If[nowAbs >= nextAbs - lead*86400.,
      Join[rec, <|"Status" -> "Open", "Deadline" -> next,
        "DeadlineSource" -> "Recurrence", "Recurred" -> True|>],
      Append[rec, "NextRecurDue" -> next]]];
iSVTDApplyRecur[rec_, _] := rec;

(* ============================================================
   Standalone items store (+ cache)
   ============================================================ *)

If[! ValueQ[$iSVTDItemCache], $iSVTDItemCache = None]; (* {count, <|id->rec|>} *)

iSVTDItemPath[id_String] := FileNameJoin[{iSVTDItemsDir[], id <> ".json"}];

iSVTDItemCacheEnsure[] :=
  Module[{dir = iSVTDItemsDir[], files},
    files = If[Quiet@Check[DirectoryQ[dir], False], FileNames["*.json", dir], {}];
    If[ListQ[$iSVTDItemCache] && $iSVTDItemCache[[1]] === Length[files],
      Return[$iSVTDItemCache[[2]]]];
    $iSVTDItemCache = {Length[files], Association[
      Function[f, With[{r = iSVTDImportJSON[f]},
        If[AssociationQ[r], FileBaseName[f] -> r, Nothing]]] /@ files]};
    $iSVTDItemCache[[2]]];

iSVTDItemCachePut[id_String, rec_Association] :=
  If[ListQ[$iSVTDItemCache],
    $iSVTDItemCache = {
      $iSVTDItemCache[[1]] +
        If[KeyExistsQ[$iSVTDItemCache[[2]], id], 0, 1],
      Append[$iSVTDItemCache[[2]], id -> rec]}];

iSVTDItemSave[id_String, rec_Association] :=
  Module[{},
    iSVTDEnsureDir[iSVTDItemsDir[]];
    If[iSVTDAtomicExportJSON[iSVTDItemPath[id], rec] === $Failed,
      $Failed,
      iSVTDItemCachePut[id, rec]; id]];

(* ============================================================
   Overlays for notebook todos (+ cache)
   ============================================================ *)

If[! ValueQ[$iSVTDOverlayCache], $iSVTDOverlayCache = None];

iSVTDOverlayPath[id_String] := FileNameJoin[{iSVTDOverlayDir[], id <> ".json"}];

iSVTDOverlayCacheEnsure[] :=
  Module[{dir = iSVTDOverlayDir[], files},
    files = If[Quiet@Check[DirectoryQ[dir], False], FileNames["*.json", dir], {}];
    If[ListQ[$iSVTDOverlayCache] && $iSVTDOverlayCache[[1]] === Length[files],
      Return[$iSVTDOverlayCache[[2]]]];
    $iSVTDOverlayCache = {Length[files], Association[
      Function[f, With[{r = iSVTDImportJSON[f]},
        If[AssociationQ[r], FileBaseName[f] -> r, Nothing]]] /@ files]};
    $iSVTDOverlayCache[[2]]];

iSVTDOverlayCachePut[id_String, rec_Association] :=
  If[ListQ[$iSVTDOverlayCache],
    $iSVTDOverlayCache = {
      $iSVTDOverlayCache[[1]] +
        If[KeyExistsQ[$iSVTDOverlayCache[[2]], id], 0, 1],
      Append[$iSVTDOverlayCache[[2]], id -> rec]}];

iSVTDOverlaySave[id_String, rec_Association] :=
  Module[{},
    iSVTDEnsureDir[iSVTDOverlayDir[]];
    If[iSVTDAtomicExportJSON[iSVTDOverlayPath[id], rec] === $Failed,
      $Failed,
      iSVTDOverlayCachePut[id, rec]; id]];

iSVTDOverlayOf[id_String] :=
  Lookup[iSVTDOverlayCacheEnsure[], id, Missing["NoOverlay"]];

(* merge a mutation into overlay (notebook todo) or item (standalone) *)
iSVTDMutate[id_String, delta_Association] :=
  Module[{isNb = StringStartsQ[id, "svtodo-nb-"], base, merged},
    If[isNb,
      base = With[{o = iSVTDOverlayOf[id]}, If[AssociationQ[o], o, <||>]];
      merged = Join[base, delta, <|"TodoId" -> id,
        "UpdatedAt" -> iSVTDIsoNow[]|>];
      merged = Association[Select[Normal[merged], #[[2]] =!= None &]];
      If[iSVTDOverlaySave[id, merged] === $Failed,
        <|"Status" -> "Failed", "Reason" -> "OverlayWriteFailed"|>,
        <|"Status" -> "OK", "TodoId" -> id, "Overlay" -> merged|>],
      (* standalone *)
      base = Lookup[iSVTDItemCacheEnsure[], id, Missing[]];
      If[! AssociationQ[base],
        Return[<|"Status" -> "Failed", "Reason" -> "NotFound", "TodoId" -> id|>]];
      merged = Join[base, delta, <|"UpdatedAt" -> iSVTDIsoNow[]|>];
      merged = Association[Select[Normal[merged], #[[2]] =!= None &]];
      If[iSVTDItemSave[id, merged] === $Failed,
        <|"Status" -> "Failed", "Reason" -> "ItemWriteFailed"|>,
        <|"Status" -> "OK", "TodoId" -> id, "Record" -> merged|>]]];

(* ============================================================
   Notes (Eagle-style user-annotated summary notebooks)
   ============================================================ *)

If[! AssociationQ[$iSVTDNoteCache], $iSVTDNoteCache = <||>]; (* id->{stamp,text} *)

iSVTDNoteIdOf[file_String] :=
  With[{parts = StringSplit[FileBaseName[file], "_"]},
    If[parts === {}, FileBaseName[file], Last[parts]]];

iSVTDNoteFile[id_String] :=
  Module[{dir = iSVTDNotesDir[], hits},
    If[! TrueQ[Quiet@Check[DirectoryQ[dir], False]], Return[Missing["NoNote"]]];
    hits = FileNames["*" <> id <> ".nb", dir];
    If[hits === {}, Missing["NoNote"], First[hits]]];

iSVTDNoteStamp[file_String] :=
  {Quiet@Check[FileDate[file, "Modification"], $Failed],
   Quiet@Check[FileByteCount[file], $Failed]};

iSVTDNotePlaintext[file_String] :=
  Module[{t, nb},
    t = Quiet@Check[Import[file, "Plaintext"], $Failed];
    If[StringQ[t] && StringTrim[t] =!= "", Return[t]];
    nb = Quiet@Check[Get[file], $Failed];
    If[Head[nb] =!= Notebook, Return[""]];
    StringRiffle[Cases[nb, s_String :> s, {0, Infinity}], " "]];

iSVTDNotesEnsure[] :=
  Module[{dir = iSVTDNotesDir[], files},
    files = If[TrueQ[Quiet@Check[DirectoryQ[dir], False]],
      FileNames["*.nb", dir], {}];
    $iSVTDNoteCache = KeyTake[$iSVTDNoteCache, iSVTDNoteIdOf /@ files];
    Scan[
      Function[f,
        Module[{id = iSVTDNoteIdOf[f], st, e},
          st = iSVTDNoteStamp[f];
          e = Lookup[$iSVTDNoteCache, id, Missing[]];
          If[! (ListQ[e] && e[[1]] === st),
            $iSVTDNoteCache[id] = {st, iSVTDNotePlaintext[f]}]]],
      files];
    $iSVTDNoteCache];

iSVTDNoteTextOf[id_String] :=
  With[{e = Lookup[$iSVTDNoteCache, id, Missing[]]},
    If[ListQ[e] && StringQ[e[[2]]] && StringTrim[e[[2]]] =!= "",
      e[[2]], Missing["NoNote"]]];

(* ============================================================
   Notebook-derived todo rows (INDEX-FIRST, WXF-cached in LOCALAPPDATA)
   ============================================================ *)

If[! AssociationQ[$iSVTDNbCache], $iSVTDNbCache = <||>];
If[! ValueQ[$iSVTDNbCacheLoaded], $iSVTDNbCacheLoaded = False];
If[! ValueQ[$iSVTDNbCacheDirty], $iSVTDNbCacheDirty = False];
If[! ValueQ[$iSVTDNbEnsureStamp], $iSVTDNbEnsureStamp = 0];
(* test seam: inject notebook rows, bypassing the disk index entirely *)
If[! ValueQ[$iSVTDInjectNbRows], $iSVTDInjectNbRows = None];

iSVTDNbCacheFile[] :=
  FileNameJoin[{iSVTDLocalStateDir[], "todo_nb_cache.wxf"}];

iSVTDNbCacheLoad[] :=
  If[! TrueQ[$iSVTDNbCacheLoaded],
    Module[{f = iSVTDNbCacheFile[], d},
      If[FileExistsQ[f],
        d = Quiet@Check[Import[f, "WXF"], $Failed];
        If[AssociationQ[d], $iSVTDNbCache = d]];
      $iSVTDNbCacheLoaded = True]];

iSVTDNbCachePersist[] :=
  If[TrueQ[$iSVTDNbCacheDirty],
    Module[{f = iSVTDNbCacheFile[], tmp},
      iSVTDEnsureDir[DirectoryName[f]];
      tmp = f <> ".tmp" <> ToString[$ProcessID];
      Quiet@Check[
        Export[tmp, $iSVTDNbCache, "WXF"];
        RenameFile[tmp, f, OverwriteTarget -> True];
        $iSVTDNbCacheDirty = False,
        Quiet@DeleteFile[tmp]]]];

iSVTDSourcesDir[] :=
  Quiet@Check[FileNameJoin[{iNotebooksDir[], "sources"}], $Failed];

(* one source json -> base todo rows (no .nb read; snapshot only) *)
iSVTDRowsFromSource[srcPath_String] :=
  Module[{src, snapId, snap, tc, hc, todos, header, sym, path, nbRef, refHex,
      nbTitle, nbPL, nbStatus, extractedAt, seen = <||>, rows = {}},
    src = iSVTDImportJSON[srcPath];
    If[! AssociationQ[src] ||
        Lookup[src, "Type", ""] =!= "NotebookSource", Return[{}]];
    snapId = Lookup[src, "CurrentSnapshotId", Missing[]];
    If[! StringQ[snapId] || StringStartsQ[snapId, "snap-toolarge-"],
      Return[{}]];
    snap = iSVTDImportJSON[
      Quiet@Check[iNotebookSnapshotPath[snapId], $Failed]];
    If[! AssociationQ[snap], Return[{}]];
    tc = Lookup[snap, "TodosCompressed", Missing[]];
    If[! StringQ[tc], Return[{}]];
    todos = Quiet@Check[Uncompress[tc], $Failed];
    If[! ListQ[todos] || todos === {}, Return[{}]];
    hc = Lookup[snap, "HeaderCompressed", Missing[]];
    header = If[StringQ[hc],
      With[{h = Quiet@Check[Uncompress[hc], $Failed]},
        If[AssociationQ[h], h, <||>]], <||>];
    (* resolve path on THIS machine; a vanished file (archived/deleted under
       this path) contributes nothing -- the archived copy gets its own
       source record once $offWork is scanned *)
    sym = Lookup[src, "SymbolicPath", Missing[]];
    path = If[ListQ[sym],
      With[{p = Quiet@Check[iSVResolvePath[sym], Missing[]]},
        If[StringQ[p], p, Lookup[src, "OriginalPath", Missing[]]]],
      Lookup[src, "OriginalPath", Missing[]]];
    If[! StringQ[path] || ! FileExistsQ[path], Return[{}]];
    nbRef = Lookup[src, "NotebookRef", ""];
    refHex = If[StringQ[nbRef] && StringStartsQ[nbRef, "nb-src-"],
      StringDrop[nbRef, 7], ToString[nbRef]];
    nbTitle = With[{t = Lookup[src, "Title", Missing[]]},
      If[StringQ[t] && t =!= "", t, FileBaseName[path]]];
    nbPL = With[{p = Lookup[snap, "PrivacyLevel", Missing[]]},
      If[NumericQ[p], N[p], 1.0]];
    nbStatus = With[{s = Lookup[header, "Status", Missing[]]},
      If[StringQ[s], s, ""]];
    extractedAt = ToString@Lookup[snap, "CreatedAt", ""];
    Scan[
      Function[t,
        If[AssociationQ[t],
          Module[{text = ToString@Lookup[t, "Text", ""], h, n, id},
            If[StringTrim[text] =!= "",
              h = iSVTDTextHash[text];
              n = Lookup[seen, h, 0] + 1; seen[h] = n;
              id = "svtodo-nb-" <> refHex <> "-" <> h <>
                If[n > 1, "-" <> ToString[n], ""];
              AppendTo[rows, <|
                "TodoId" -> id,
                "Origin" -> "notebook",
                "Source" -> "notebook",
                "Text" -> text,
                "CellStatus" -> ToString@Lookup[t, "Status", "Open"],
                "StatusSource" -> ToString@Lookup[t, "StatusSource", ""],
                "StrikeThrough" -> TrueQ[Lookup[t, "StrikeThrough", False]],
                "CellStyle" -> ToString@Lookup[t, "CellStyle", ""],
                "LastChanged" -> Lookup[t, "LastChanged", Missing["None"]],
                "NotebookPath" -> path,
                "NotebookRef" -> nbRef,
                "NotebookTitle" -> nbTitle,
                "NotebookStatus" -> nbStatus,
                "PrivacyLevel" -> nbPL,
                "AddedAt" -> extractedAt|>]]]]],
      todos];
    rows];
iSVTDRowsFromSource[___] := {};

(* cheap ensure: diff source-json mtimes (no notebook scan). TTL-throttled. *)
iSVTDNbRowsEnsure[] :=
  Module[{dir, files, now = N[AbsoluteTime[]], keep},
    If[ListQ[$iSVTDInjectNbRows], Return[$iSVTDInjectNbRows]];
    iSVTDNbCacheLoad[];
    If[now - $iSVTDNbEnsureStamp < 30.,
      Return[Flatten[Values[Lookup[#, "Rows", {}] & /@ $iSVTDNbCache], 1]]];
    $iSVTDNbEnsureStamp = now;
    dir = iSVTDSourcesDir[];
    If[! StringQ[dir] || ! DirectoryQ[dir],
      Return[Flatten[Values[Lookup[#, "Rows", {}] & /@ $iSVTDNbCache], 1]]];
    files = FileNames["*.json", dir];
    keep = <||>;
    Scan[
      Function[f,
        Module[{m = Quiet@Check[N[AbsoluteTime[FileDate[f]]], 0.], e},
          e = Lookup[$iSVTDNbCache, f, Missing[]];
          If[AssociationQ[e] && Lookup[e, "M", -1] === m,
            keep[f] = e,
            keep[f] = <|"M" -> m, "Rows" -> iSVTDRowsFromSource[f]|>;
            $iSVTDNbCacheDirty = True]]],
      files];
    If[Length[keep] =!= Length[$iSVTDNbCache], $iSVTDNbCacheDirty = True];
    $iSVTDNbCache = keep;
    iSVTDNbCachePersist[];
    Flatten[Values[Lookup[#, "Rows", {}] & /@ $iSVTDNbCache], 1]];

Options[SourceVaultTodoRebuildIndex] = {"Scan" -> "OnWork"};
SourceVaultTodoRebuildIndex[OptionsPattern[]] :=
  Module[{scan = OptionValue["Scan"], roots = {}, onw, offw, rows},
    onw = Quiet@Check[Symbol["Global`$onWork"], $Failed];
    offw = Quiet@Check[Symbol["Global`$offWork"], $Failed];
    Which[
      scan === "All",
        If[StringQ[onw] && DirectoryQ[onw], AppendTo[roots, onw]];
        If[StringQ[offw] && DirectoryQ[offw], AppendTo[roots, offw]],
      scan === "OffWork",
        If[StringQ[offw] && DirectoryQ[offw], AppendTo[roots, offw]],
      scan === "None", roots = {},
      True,
        If[StringQ[onw] && DirectoryQ[onw], AppendTo[roots, onw]]];
    (* incremental notebook re-index through the existing snapshot machinery
       (mtime-diffed; unchanged files are not re-imported) *)
    Scan[
      Function[r, Quiet@Check[iSVGetCachedRecords[r, True, True], $Failed]],
      roots];
    (* force a fresh source-dir diff *)
    $iSVTDNbEnsureStamp = 0;
    rows = iSVTDNbRowsEnsure[];
    <|"Status" -> "OK", "ScannedRoots" -> roots,
      "Sources" -> Length[$iSVTDNbCache], "NotebookTodoRows" -> Length[rows]|>];

(* ============================================================
   Effective record assembly
   ============================================================ *)

(* base notebook row + overlay -> effective record *)
iSVTDEffectiveNb[row_Association, nowAbs_] :=
  Module[{id = Lookup[row, "TodoId", ""], ov, status, statusSrc, deadline,
      dlSrc, rec, parsed, doneAt, passAt, noDl, prio},
    ov = With[{o = iSVTDOverlayOf[id]}, If[AssociationQ[o], o, <||>]];
    status = With[{s = Lookup[ov, "Status", Missing[]]},
      If[StringQ[s], s,
        With[{cs = Lookup[row, "CellStatus", "Open"]},
          If[MemberQ[{"Done", "Pass"}, cs], cs, "Open"]]]];
    statusSrc = If[StringQ[Lookup[ov, "Status", Missing[]]], "Overlay",
      Lookup[row, "StatusSource", "Cell"]];
    doneAt = With[{d = Lookup[ov, "DoneAt", Missing[]]},
      Which[
        StringQ[d], d,
        status === "Done" && NumberQ[Lookup[row, "LastChanged", Missing[]]],
          Quiet@Check[
            DateString[FromAbsoluteTime[row["LastChanged"]], "ISODate"],
            Missing["None"]],
        True, Missing["None"]]];
    passAt = With[{d = Lookup[ov, "PassAt", Missing[]]},
      If[StringQ[d], d, Missing["None"]]];
    (* an explicitly CLEARED deadline must stay cleared: without this marker
       the text parser would hand the same date straight back *)
    noDl = TrueQ[Lookup[ov, "NoDeadline", False]];
    deadline = If[noDl, Missing["None"],
      iSVTDToDate[Lookup[ov, "Deadline", Missing[]]]];
    dlSrc = Which[
      noDl, "Cleared",
      DateObjectQ[deadline],
        ToString@Lookup[ov, "DeadlineSource", "Overlay"],
      True, ""];
    If[! noDl && ! DateObjectQ[deadline],
      parsed = iSVTDDeadlineFromText[Lookup[row, "Text", ""], nowAbs];
      If[AssociationQ[parsed] && parsed["Confidence"] >= 0.6,
        deadline = parsed["Date"]; dlSrc = "TextParse"]];
    prio = iSVTDPriorityPick[ov];
    rec = <|
      "TodoId" -> id, "Origin" -> "notebook", "Source" -> "notebook",
      "Text" -> Lookup[row, "Text", ""],
      "Title" -> StringTake[StringTrim[
          StringReplace[Lookup[row, "Text", ""], "\n" -> " "]], UpTo[80]],
      "Status" -> status, "StatusSource" -> statusSrc,
      "Deadline" -> If[DateObjectQ[deadline], deadline, Missing["None"]],
      "DeadlineSource" -> dlSrc,
      "Recur" -> With[{r = Lookup[ov, "Recur", Missing[]]},
        If[AssociationQ[r], r, Missing["None"]]],
      "DoneAt" -> doneAt,
      "PassAt" -> passAt,
      "Priority" -> prio[[1]], "PrioritySource" -> prio[[2]],
      "Summary" -> ToString@Lookup[ov, "Summary", ""],
      "SummaryAt" -> ToString@Lookup[ov, "SummaryAt", ""],
      "NotebookPath" -> Lookup[row, "NotebookPath", Missing[]],
      "NotebookRef" -> Lookup[row, "NotebookRef", Missing[]],
      "NotebookTitle" -> Lookup[row, "NotebookTitle", ""],
      "NotebookStatus" -> Lookup[row, "NotebookStatus", ""],
      "CellStatus" -> Lookup[row, "CellStatus", "Open"],
      "LastChanged" -> Lookup[row, "LastChanged", Missing["None"]],
      "PrivacyLevel" -> iSVTDPLPick[ov, iSVTDPLOf[row]],
      "PrivacyLevelSource" ->
        If[NumericQ[Lookup[ov, "PrivacyLevel", Missing[]]], "Overlay",
          "Notebook"],
      "AddedAt" -> Lookup[row, "AddedAt", ""],
      "URI" -> "sv://record/" <> id|>;
    iSVTDApplyRecur[rec, nowAbs]];

(* standalone item -> effective record *)
iSVTDEffectiveItem[item_Association, nowAbs_] :=
  Module[{id = Lookup[item, "TodoId", ""], deadline, dlSrc, rec, parsed,
      noDl, prio, title = ToString@Lookup[item, "Title", ""]},
    noDl = TrueQ[Lookup[item, "NoDeadline", False]];
    deadline = If[noDl, Missing["None"],
      iSVTDToDate[Lookup[item, "Deadline", Missing[]]]];
    dlSrc = Which[
      noDl, "Cleared",
      DateObjectQ[deadline],
        ToString@Lookup[item, "DeadlineSource", "Explicit"],
      True, ""];
    If[! noDl && ! DateObjectQ[deadline],
      parsed = iSVTDDeadlineFromText[
        title <> " " <> ToString@Lookup[item, "Description", ""], nowAbs];
      If[AssociationQ[parsed] && parsed["Confidence"] >= 0.6,
        deadline = parsed["Date"]; dlSrc = "TextParse"]];
    prio = iSVTDPriorityPick[item];
    rec = <|
      "TodoId" -> id, "Origin" -> "standalone",
      "Source" -> ToString@Lookup[item, "Source", "manual"],
      "Text" -> title, "Title" -> StringTake[title, UpTo[80]],
      "Description" -> ToString@Lookup[item, "Description", ""],
      "Status" -> With[{s = Lookup[item, "Status", "Open"]},
        If[StringQ[s], s, "Open"]],
      "StatusSource" -> "Item",
      "Deadline" -> If[DateObjectQ[deadline], deadline, Missing["None"]],
      "DeadlineSource" -> dlSrc,
      "Recur" -> With[{r = Lookup[item, "Recur", Missing[]]},
        If[AssociationQ[r], r, Missing["None"]]],
      "DoneAt" -> Lookup[item, "DoneAt", Missing["None"]],
      "PassAt" -> Lookup[item, "PassAt", Missing["None"]],
      "Priority" -> prio[[1]], "PrioritySource" -> prio[[2]],
      "Summary" -> ToString@Lookup[item, "Summary", ""],
      "SummaryAt" -> ToString@Lookup[item, "SummaryAt", ""],
      "NotebookPath" -> Missing["None"],
      "NotebookTitle" -> "", "NotebookStatus" -> "",
      "MailRecordId" -> Lookup[item, "MailRecordId", Missing["None"]],
      "LinkKind" -> Lookup[item, "LinkKind", Missing["None"]],
      "LinkId" -> Lookup[item, "LinkId", Missing["None"]],
      "PrivacyLevel" -> iSVTDPLOf[item],
      "PrivacyLevelSource" -> "Item",
      "AddedAt" -> ToString@Lookup[item, "AddedAt", ""],
      "URI" -> "sv://record/" <> id|>;
    iSVTDApplyRecur[rec, nowAbs]];

iSVTDAllEffective[] :=
  Module[{nowAbs = iSVTDNow[], nbRows, items},
    iSVTDOverlayCacheEnsure[];
    nbRows = iSVTDNbRowsEnsure[];
    items = Values[iSVTDItemCacheEnsure[]];
    Join[
      Map[iSVTDEffectiveNb[#, nowAbs] &, Select[nbRows, AssociationQ]],
      Map[iSVTDEffectiveItem[#, nowAbs] &, Select[items, AssociationQ]]]];

(* ============================================================
   Core query: SourceVaultTodos
   ============================================================ *)

iSVTDStatusMatch[st_String, sel_] := Which[
  sel === All || sel === "All", True,
  ListQ[sel], MemberQ[sel, st],
  StringQ[sel], st === sel,
  True, st === "Open"];

iSVTDQueryMatch[rec_Association, q_String] :=
  Module[{note},
    If[StringTrim[q] === "", Return[True]];
    note = With[{n = iSVTDNoteTextOf[Lookup[rec, "TodoId", ""]]},
      If[StringQ[n], n, ""]];
    AnyTrue[
      {Lookup[rec, "Text", ""], Lookup[rec, "Title", ""],
       Lookup[rec, "Summary", ""], Lookup[rec, "Description", ""],
       Lookup[rec, "NotebookTitle", ""], note},
      StringQ[#] && StringContainsQ[#, q, IgnoreCase -> True] &]];

Options[SourceVaultTodos] = {
  "Status" -> "Open", "Origin" -> All, "Source" -> All,
  "HasDeadline" -> All, "DueWithinDays" -> None, "MinPriority" -> None,
  "SortBy" -> "Deadline", "Limit" -> Automatic};

SourceVaultTodos[opts : OptionsPattern[]] := SourceVaultTodos["", opts];
SourceVaultTodos[query_String, OptionsPattern[]] :=
  Module[{rows, nowAbs = iSVTDNow[], lim = OptionValue["Limit"], dwd},
    iSVTDNotesEnsure[];
    rows = iSVTDAllEffective[];
    rows = Select[rows,
      iSVTDStatusMatch[Lookup[#, "Status", "Open"], OptionValue["Status"]] &];
    With[{o = OptionValue["Origin"]},
      If[StringQ[o], rows = Select[rows, Lookup[#, "Origin", ""] === o &]]];
    With[{s = OptionValue["Source"]},
      If[StringQ[s], rows = Select[rows, Lookup[#, "Source", ""] === s &]]];
    With[{hd = OptionValue["HasDeadline"]},
      Which[
        hd === True,
          rows = Select[rows, DateObjectQ[Lookup[#, "Deadline", Missing[]]] &],
        hd === False,
          rows = Select[rows,
            ! DateObjectQ[Lookup[#, "Deadline", Missing[]]] &]]];
    dwd = OptionValue["DueWithinDays"];
    If[NumberQ[dwd],
      rows = Select[rows,
        With[{a = iSVTDDateAbs[Lookup[#, "Deadline", Missing[]]]},
          NumberQ[a] && a <= nowAbs + dwd*86400.] &]];
    With[{mp = OptionValue["MinPriority"]},
      If[NumberQ[mp],
        rows = Select[rows, iSVTDPriorityOf[#] >= mp - 0.0001 &]]];
    rows = Select[rows, iSVTDQueryMatch[#, query] &];
    If[OptionValue["SortBy"] === "Priority",
      (* importance first, deadline as the tie-break (undated last) *)
      rows = SortBy[rows, {-iSVTDPriorityOf[#] &,
        With[{a = iSVTDDateAbs[Lookup[#, "Deadline", Missing[]]]},
          If[NumberQ[a], a, 1.*^13]] &}],
      (* order: dated items by deadline ascending first, then undated newest *)
      rows = Join[
        SortBy[Select[rows, DateObjectQ[Lookup[#, "Deadline", Missing[]]] &],
          iSVTDDateAbs[Lookup[#, "Deadline", Missing[]]] &],
        Reverse@SortBy[
          Select[rows, ! DateObjectQ[Lookup[#, "Deadline", Missing[]]] &],
          ToString@Lookup[#, "AddedAt", ""] &]]];
    If[IntegerQ[lim] && lim >= 0, rows = Take[rows, UpTo[lim]]];
    iSVTDPrivateResult[rows]];
SourceVaultTodos[___] := {};

(* canonical privacy exits (weak binding to the catalog machinery) *)
iSVTDPrivateResult[rows_] :=
  If[Length[DownValues[iSVCatalogPrivateResult]] > 0,
    Quiet@Check[iSVCatalogPrivateResult[rows], rows], rows];
iSVTDPrivateView[expr_, rows_] :=
  If[Length[DownValues[iSVCatalogPrivateView]] > 0,
    Quiet@Check[iSVCatalogPrivateView[expr, rows], expr], expr];

SourceVaultTodoGet[id_String] :=
  With[{hit = SelectFirst[iSVTDAllEffective[],
      Lookup[#, "TodoId", ""] === id &]},
    If[AssociationQ[hit], hit, Missing["NotFound", id]]];
SourceVaultTodoGet[___] := Missing["BadArgs"];

(* ============================================================
   Mutations
   ============================================================ *)

SourceVaultNewTodo[title_String, opts : OptionsPattern[]] :=
  SourceVaultNewTodo[<|"Title" -> title|>];
SourceVaultNewTodo[spec_Association] :=
  Module[{title, id, rec, passKeys, dl},
    title = With[{t = Lookup[spec, "Title", Lookup[spec, "Item", ""]]},
      If[StringQ[t], StringTrim[t], ""]];
    If[title === "",
      Return[<|"Status" -> "Failed", "Reason" -> "EmptyTitle"|>]];
    id = "svtodo-" <> StringTake[
      Hash[CreateUUID[], "SHA256", "HexString"], 12];
    dl = iSVTDIso[Lookup[spec, "Deadline", Missing[]]];
    rec = <|
      "TodoId" -> id,
      "Title" -> title,
      "Description" -> With[{d = Lookup[spec, "Description", ""]},
        If[StringQ[d], d, ""]],
      "Status" -> "Open",
      "PrivacyLevel" -> With[{p = Lookup[spec, "PrivacyLevel", Missing[]]},
        If[NumericQ[p], N[Clip[p, {0., 1.}]], 1.0]],
      "Source" -> With[{s = Lookup[spec, "Source", "manual"]},
        If[StringQ[s], s, "manual"]],
      "AddedAt" -> With[{a = Lookup[spec, "AddedAt", Missing[]]},
        If[StringQ[a] && a =!= "", a, iSVTDIsoNow[]]]|>;
    If[StringQ[dl], rec["Deadline"] = dl;
      rec["DeadlineSource"] = "Explicit"];
    With[{pv = Lookup[spec, "Priority", Missing[]]},
      If[NumericQ[pv], rec["Priority"] = iSVTDClip01[pv]]];
    passKeys = {"MailRecordId", "LinkKind", "LinkId", "Recur"};
    Scan[
      Function[k, With[{v = Lookup[spec, k, Missing[]]},
        If[! MissingQ[v] && v =!= None, rec[k] = v]]],
      passKeys];
    If[iSVTDItemSave[id, rec] === $Failed,
      <|"Status" -> "Failed", "Reason" -> "WriteFailed", "TodoId" -> id|>,
      <|"Status" -> "OK", "TodoId" -> id, "Record" -> rec|>]];
SourceVaultNewTodo[___] :=
  <|"Status" -> "Failed",
    "Reason" -> "expects [title_String] or [spec_Association]"|>;

SourceVaultTodoSetStatus[id_String, Automatic] :=
  iSVTDMutate[id, <|"Status" -> None, "DoneAt" -> None, "PassAt" -> None|>];
SourceVaultTodoSetStatus[id_String,
    status : ("Open" | "Done" | "Pass" | "Keep")] :=
  iSVTDMutate[id, <|"Status" -> status,
    "DoneAt" -> If[status === "Done", iSVTDIsoNow[], None],
    "PassAt" -> If[status === "Pass", iSVTDIsoNow[], None]|>];
SourceVaultTodoSetStatus[___] :=
  <|"Status" -> "Failed",
    "Reason" -> "expects [todoId, \"Open\"|\"Done\"|\"Pass\"|\"Keep\"|Automatic]"|>;

SourceVaultTodoDone[id_String] := SourceVaultTodoSetStatus[id, "Done"];
SourceVaultTodoDone[___] := <|"Status" -> "Failed", "Reason" -> "BadArgs"|>;

SourceVaultTodoPass[id_String] := SourceVaultTodoSetStatus[id, "Pass"];
SourceVaultTodoPass[___] := <|"Status" -> "Failed", "Reason" -> "BadArgs"|>;

SourceVaultTodoRemindNext[id_String, None] :=
  iSVTDMutate[id, <|"Recur" -> None|>];
SourceVaultTodoRemindNext[id_String, cycle_String] :=
  SourceVaultTodoRemindNext[id, cycle, Automatic];
SourceVaultTodoRemindNext[id_String, None, _] :=
  iSVTDMutate[id, <|"Recur" -> None|>];
SourceVaultTodoRemindNext[id_String, cycle_String, lead_] :=
  If[MemberQ[$iSVTDRecurCycles, cycle],
    (* lead Automatic -> the cycle-scaled default is applied at read time *)
    iSVTDMutate[id, <|"Recur" -> If[NumberQ[lead] && lead >= 0,
      <|"Cycle" -> cycle, "LeadDays" -> N[lead]|>,
      <|"Cycle" -> cycle|>]|>],
    <|"Status" -> "Failed", "Reason" -> "UnknownCycle",
      "Allowed" -> $iSVTDRecurCycles|>];
SourceVaultTodoRemindNext[___] :=
  <|"Status" -> "Failed",
    "Reason" -> "expects [todoId, \"Yearly\"|\"HalfYearly\"|\"Quarterly\"|\"Monthly\"|\"Weekly\"|None, leadDays]"|>;

(* ---- individual settings (deadline / importance / privacy level) ----
   Every one of these goes through iSVTDMutate, so a notebook todo gets an
   OVERLAY and its .nb cell is never touched. A None value in the delta means
   "drop the key", which is how a setting returns to its inherited default. *)

SourceVaultTodoSetDeadline[id_String, None] :=
  iSVTDMutate[id, <|"Deadline" -> None, "DeadlineSource" -> None,
    "NoDeadline" -> True|>];
SourceVaultTodoSetDeadline[id_String, Automatic] :=
  iSVTDMutate[id, <|"Deadline" -> None, "DeadlineSource" -> None,
    "NoDeadline" -> None|>];
SourceVaultTodoSetDeadline[id_String, d_] :=
  With[{iso = iSVTDIso[d]},
    If[StringQ[iso],
      iSVTDMutate[id, <|"Deadline" -> iso, "DeadlineSource" -> "Explicit",
        "NoDeadline" -> None|>],
      <|"Status" -> "Failed", "Reason" -> "BadDate", "TodoId" -> id|>]];
SourceVaultTodoSetDeadline[___] :=
  <|"Status" -> "Failed",
    "Reason" -> "expects [todoId, date | None (clear) | Automatic (re-parse)]"|>;

SourceVaultTodoSetPriority[id_String, Automatic] :=
  iSVTDMutate[id, <|"Priority" -> None|>];
SourceVaultTodoSetPriority[id_String, p_?NumericQ] :=
  iSVTDMutate[id, <|"Priority" -> iSVTDClip01[p]|>];
SourceVaultTodoSetPriority[___] :=
  <|"Status" -> "Failed", "Reason" -> "expects [todoId, 0..1 | Automatic]"|>;

SourceVaultTodoSetPrivacyLevel[id_String, Automatic] :=
  iSVTDMutate[id, <|"PrivacyLevel" -> None|>];
SourceVaultTodoSetPrivacyLevel[id_String, p_?NumericQ] :=
  iSVTDMutate[id, <|"PrivacyLevel" -> iSVTDClip01[p]|>];
SourceVaultTodoSetPrivacyLevel[___] :=
  <|"Status" -> "Failed", "Reason" -> "expects [todoId, 0..1 | Automatic]"|>;

(* ---- one-write batch update (what the settings panel calls) ----
   Catch/Throw rather than Return: Return inside the nested With/Which of a
   Module is the trap this codebase has been bitten by before. *)
SourceVaultTodoUpdate[id_String, spec_Association] :=
  Catch[
    Module[{delta = <||>, applied = {}, base, cyc, lead, curRecur, curCyc,
        curLead, res},
      base = With[{b = SourceVaultTodoGet[id]}, If[AssociationQ[b], b, <||>]];
      If[base === <||>,
        Throw[<|"Status" -> "Failed", "Reason" -> "NotFound",
          "TodoId" -> id|>, "iSVTDUpd"]];
      (* status *)
      If[KeyExistsQ[spec, "Status"],
        With[{st = spec["Status"], cur = ToString@Lookup[base, "Status", "Open"]},
          Which[
            st === Automatic,
              delta["Status"] = None; delta["DoneAt"] = None;
              delta["PassAt"] = None; AppendTo[applied, "Status"],
            MemberQ[{"Open", "Done", "Pass", "Keep"}, st],
              delta["Status"] = st;
              (* re-applying the same status must not move the recurrence
                 anchor, so only a real transition stamps the time *)
              If[st =!= cur,
                delta["DoneAt"] = If[st === "Done", iSVTDIsoNow[], None];
                delta["PassAt"] = If[st === "Pass", iSVTDIsoNow[], None]];
              AppendTo[applied, "Status"],
            True,
              Throw[<|"Status" -> "Failed", "Reason" -> "BadStatus",
                "TodoId" -> id|>, "iSVTDUpd"]]]];
      (* deadline *)
      If[KeyExistsQ[spec, "Deadline"],
        With[{d = spec["Deadline"]},
          Which[
            d === None,
              delta["Deadline"] = None; delta["DeadlineSource"] = None;
              delta["NoDeadline"] = True; AppendTo[applied, "Deadline"],
            d === Automatic,
              delta["Deadline"] = None; delta["DeadlineSource"] = None;
              delta["NoDeadline"] = None; AppendTo[applied, "Deadline"],
            True,
              With[{iso = iSVTDIso[d]},
                If[StringQ[iso],
                  delta["Deadline"] = iso;
                  delta["DeadlineSource"] = "Explicit";
                  delta["NoDeadline"] = None; AppendTo[applied, "Deadline"],
                  Throw[<|"Status" -> "Failed", "Reason" -> "BadDate",
                    "TodoId" -> id|>, "iSVTDUpd"]]]]]];
      (* review cycle (+ lead window) *)
      curRecur = With[{r = Lookup[base, "Recur", Missing[]]},
        If[AssociationQ[r], r, <||>]];
      curCyc = With[{c = Lookup[curRecur, "Cycle", Missing[]]},
        If[StringQ[c], c, "None"]];
      curLead = Lookup[curRecur, "LeadDays", Missing[]];
      If[KeyExistsQ[spec, "Recur"] || KeyExistsQ[spec, "RecurLeadDays"],
        cyc = Lookup[spec, "Recur", curCyc];
        lead = Lookup[spec, "RecurLeadDays",
          If[NumberQ[curLead], curLead, Automatic]];
        Which[
          cyc === None || cyc === Automatic || cyc === "None",
            delta["Recur"] = None; AppendTo[applied, "Recur"],
          StringQ[cyc] && MemberQ[$iSVTDRecurCycles, cyc],
            delta["Recur"] = If[NumberQ[lead] && lead >= 0,
              <|"Cycle" -> cyc, "LeadDays" -> N[lead]|>,
              <|"Cycle" -> cyc|>];
            AppendTo[applied, "Recur"],
          True,
            Throw[<|"Status" -> "Failed", "Reason" -> "UnknownCycle",
              "Allowed" -> $iSVTDRecurCycles, "TodoId" -> id|>, "iSVTDUpd"]]];
      (* importance *)
      If[KeyExistsQ[spec, "Priority"],
        With[{p = spec["Priority"]},
          Which[
            p === Automatic, delta["Priority"] = None;
              AppendTo[applied, "Priority"],
            NumericQ[p], delta["Priority"] = iSVTDClip01[p];
              AppendTo[applied, "Priority"],
            True, Throw[<|"Status" -> "Failed", "Reason" -> "BadPriority",
              "TodoId" -> id|>, "iSVTDUpd"]]]];
      (* privacy level *)
      If[KeyExistsQ[spec, "PrivacyLevel"],
        With[{p = spec["PrivacyLevel"]},
          Which[
            p === Automatic, delta["PrivacyLevel"] = None;
              AppendTo[applied, "PrivacyLevel"],
            NumericQ[p], delta["PrivacyLevel"] = iSVTDClip01[p];
              AppendTo[applied, "PrivacyLevel"],
            True, Throw[<|"Status" -> "Failed", "Reason" -> "BadPrivacyLevel",
              "TodoId" -> id|>, "iSVTDUpd"]]]];
      If[delta === <||>,
        <|"Status" -> "NoChange", "TodoId" -> id, "Applied" -> {}|>,
        res = iSVTDMutate[id, delta];
        If[AssociationQ[res] && Lookup[res, "Status", ""] === "OK",
          Append[res, "Applied" -> applied], res]]],
    "iSVTDUpd"];
SourceVaultTodoUpdate[___] :=
  <|"Status" -> "Failed",
    "Reason" -> "expects [todoId_String, spec_Association]"|>;

SourceVaultTodoForSummary[kind_String, linkId_String,
    spec_Association : <||>] :=
  Module[{title},
    title = With[{t = Lookup[spec, "Title", ""]},
      If[StringQ[t] && StringTrim[t] =!= "", t,
        "\:78ba\:8a8d: " <> kind <> ":" <> linkId]];
    SourceVaultNewTodo[Join[spec,
      <|"Title" -> title, "Source" -> "summary",
        "LinkKind" -> kind, "LinkId" -> linkId|>]]];
SourceVaultTodoForSummary[___] :=
  <|"Status" -> "Failed",
    "Reason" -> "expects [kind_String, id_String, spec_Association]"|>;

(* ============================================================
   Palette template (expression-centric input UI)
   ============================================================ *)

SourceVaultNewTodoTemplate[] :=
  Module[{nb = InputNotebook[], tmpl},
    If[Head[nb] =!= NotebookObject,
      Return[<|"Status" -> "Failed", "Reason" -> "NoInputNotebook"|>]];
    tmpl = "SourceVaultNewTodo[<|\"Title\" -> \"\", \"Deadline\" -> None, " <>
      "\"Description\" -> \"\", \"Priority\" -> 0.5, " <>
      "\"PrivacyLevel\" -> 1.0, \"Recur\" -> None|>]";
    If[Length[DownValues[NBAccess`NBInsertInputTemplate]] > 0,
      NBAccess`NBInsertInputTemplate[nb, tmpl],
      NotebookWrite[nb, Cell[BoxData[tmpl], "Input"], All]];
    <|"Status" -> "OK"|>];

(* ============================================================
   Summary notebook window (Eagle-style; save button = System` only)
   ============================================================ *)

Options[SourceVaultTodoShowSummary] = {"Fresh" -> False};
SourceVaultTodoShowSummary[id_String, OptionsPattern[]] :=
  Module[{rec, noteFile, notesDir, savePath, title, metaLine, cells},
    rec = SourceVaultTodoGet[id];
    noteFile = iSVTDNoteFile[id];
    If[! TrueQ[OptionValue["Fresh"]] && StringQ[noteFile],
      Quiet@Check[NotebookOpen[noteFile], $Failed];
      Return[rec]];
    If[! AssociationQ[rec], Return[rec]];
    title = With[{t = Lookup[rec, "Title", id]},
      If[StringQ[t] && t =!= "", t, id]];
    notesDir = iSVTDNotesDir[];
    savePath = FileNameJoin[{notesDir,
      iSVTDSafeFileName[title] <> "_" <> id <> ".nb"}];
    metaLine = StringRiffle[DeleteCases[{
      "\:72b6\:614b: " <> ToString@Lookup[rec, "Status", ""],
      With[{d = iSVTDShortDate[Lookup[rec, "Deadline", Missing[]]]},
        If[d =!= "", "\:3006\:5207: " <> d, Nothing]],
      With[{r = Lookup[rec, "Recur", Missing[]]},
        If[AssociationQ[r],
          "\:6b21\:56de\:30ec\:30d3\:30e5\:30fc: " <>
            iSVTDCycleLabel[ToString@Lookup[r, "Cycle", ""]],
          Nothing]],
      "\:91cd\:8981\:5ea6: " <> iSVTDFmt01[iSVTDPriorityOf[rec]],
      "\:79d8\:533f: " <> iSVTDFmt01[iSVTDPLOf[rec]],
      "Source: " <> ToString@Lookup[rec, "Source", ""],
      With[{a = ToString@Lookup[rec, "AddedAt", ""]},
        If[a =!= "", "\:767b\:9332: " <> StringTake[a, UpTo[10]], Nothing]]},
      Nothing], " / "];
    cells = Join[
      {Cell[title, "Subtitle"],
       Cell[metaLine, "Text"],
       (* live settings control. Held inside Dynamic so the SAVED note never
          carries a stale snapshot of the panel: it is rebuilt from the store
          every time the note is opened. The guard uses System` symbols only,
          so reopening the note without SourceVault loaded degrades to a note
          instead of an error (same rule as the save button below). *)
       With[{theId = id},
         ExpressionCell[
           Dynamic[
             If[Length[DownValues[SourceVault`SourceVaultTodoEditPanel]] > 0,
               SourceVault`SourceVaultTodoEditPanel[theId,
                 "ShowNoteButton" -> False],
               Style["\:8a2d\:5b9a UI \:306f SourceVault \:30ed\:30fc\:30c9\:5f8c\:306b\:6709\:52b9\:306b\:306a\:308a\:307e\:3059",
                 GrayLevel[0.5]]]],
           "Output", CellMargins -> {{20, 20}, {6, 10}}]]},
      With[{p = Lookup[rec, "NotebookPath", Missing[]]},
        If[StringQ[p],
          {Cell["\:30ce\:30fc\:30c8\:30d6\:30c3\:30af: " <> p <>
             With[{ns = ToString@Lookup[rec, "NotebookStatus", ""]},
               If[ns =!= "", "  (Status: " <> ns <> ")", ""]], "Text"]},
          {}]],
      With[{lk = Lookup[rec, "LinkKind", Missing[]],
            li = Lookup[rec, "LinkId", Missing[]]},
        If[StringQ[lk] && StringQ[li],
          {Cell["\:30ea\:30f3\:30af: " <> lk <> ":" <> li, "Text"]}, {}]],
      With[{s = ToString@Lookup[rec, "Summary", ""]},
        If[StringTrim[s] =!= "",
          {Cell[s, "Text"]},
          {Cell["\:30b5\:30de\:30ea\:30fc\:672a\:751f\:6210 \[Dash] " <>
             "SourceVaultTodoBackfillSummaries[] \:3067\:751f\:6210\:3067\:304d\:307e\:3059\:3002",
             "Text"]}]],
      With[{d = ToString@Lookup[rec, "Description", ""]},
        If[StringTrim[d] =!= "", {Cell[d, "Text"]}, {}]],
      (* save button: notes/ path baked as a literal; System` symbols only so
         the button still works after the saved note is reopened later *)
      {With[{p = savePath, ndir = notesDir},
         Cell[BoxData[ToBoxes[
           Button[
             Style[Row[{
               "\:3053\:306e\:30ce\:30fc\:30c8\:3092\:4fdd\:5b58\:3059\:308b (\:88dc\:8db3\:3092\:8ffd\:8a18\:3057\:305f\:3089\:62bc\:3059\:3002\:4ee5\:5f8c\:3053\:306e\:4fdd\:5b58\:7248\:304c\:958b\:304d\:307e\:3059)"}],
               "Hyperlink"],
             (If[! DirectoryQ[ndir],
                CreateDirectory[ndir, CreateIntermediateDirectories -> True]];
              NotebookSave[ButtonNotebook[], p]),
             Method -> "Queued", Appearance -> "Frameless",
             BaseStyle -> "Hyperlink"]]], "Text"]]}];
    Quiet@Check[
      CreateDocument[cells,
        WindowTitle -> "Todo: " <> StringTake[title, UpTo[40]],
        StyleDefinitions -> "SourceVault default.nb"],
      $Failed];
    rec];
SourceVaultTodoShowSummary[___] := Missing["BadArgs"];

(* ============================================================
   LLM summary backfill (+ deadline refinement)
   ============================================================ *)

iSVTDLLMReady[] :=
  Length[DownValues[SourceVault`iCallSummaryLLM]] > 0;

(* FAIL-CLOSED cloud-egress guard (2026-09-01).
   Two hub-side hazards motivated this layer guard, both measured live:
   (1) iCallSummaryLLM's local-routing test WAS strict pl > 0.5, yet the
       system-wide confidential convention is pl >= 0.5 (the wrap badge
       reads "PL 0.5 \:4ee5\:4e0a = \:30af\:30e9\:30a6\:30c9\:9001\:4fe1\:4e0d\:53ef"), and NBFileSpec-inherited
       snapshots stamp ORDINARY undeclared notebooks exactly 0.5 -- on the
       real vault 1961/2003 todo rows sit at 0.5.
   (2) When $ClaudePrivateModel was unset or {}, the hub fell through to
       Model -> Automatic (cloud CLI) even for pl 1.0.
   HUB FIXED (2026-09-01, owner-approved): iCallSummaryLLM now routes
   pl >= 0.5 (and non-numeric pl, treated as 1.0) to $ClaudePrivateModel and
   fail-closes with "PrivateModelUnavailable" when no usable private model
   exists (see test codes/SourceVault_summaryhub_routing_test.wls).
   This layer's guard is KEPT as defense-in-depth: it treats pl >= 0.5 as
   LOCAL-ONLY and passes the private-model tuple EXPLICITLY (hub branch 1),
   and refuses rows without a usable private model up front with a per-row
   "Skipped" status (clearer than a hub Failed). An explicit "Model" option
   is the owner's override and bypasses the guard. Only pl < 0.5 rows may
   use the cloud CLI (public/low-privacy content). *)
iSVTDPrivateModelTuple[] :=
  If[Length[Names["ClaudeCode`$ClaudePrivateModel"]] > 0,
    With[{m = Quiet@Check[Symbol["ClaudeCode`$ClaudePrivateModel"], $Failed]},
      If[ListQ[m] && Length[m] >= 2, m, $Failed]],
    $Failed];
iSVTDPrivateModelReady[] := ListQ[iSVTDPrivateModelTuple[]];

iSVTDWrapUntrusted[text_String] :=
  If[Length[DownValues[iSVWrapUntrustedForSummary]] > 0,
    Quiet@Check[iSVWrapUntrustedForSummary[text],
      <|"Preamble" -> "", "Text" -> text, "Quarantined" -> False|>],
    <|"Preamble" -> "", "Text" -> text, "Quarantined" -> False|>];

iSVTDNotebookContext[rec_Association, maxChars_Integer] :=
  Module[{p = Lookup[rec, "NotebookPath", Missing[]], t},
    If[! StringQ[p] || ! FileExistsQ[p], Return[""]];
    t = Quiet@Check[Import[p, "Plaintext"], $Failed];
    If[! StringQ[t], Return[""]];
    StringTake[t, UpTo[maxChars]]];

iSVTDBuildSummaryPrompt[rec_Association, wrap_Association, ctx_String] :=
  Module[{lang = If[$Language === "Japanese", "Japanese", "English"]},
    ToString@Lookup[wrap, "Preamble", ""] <> "\n\n" <>
    "You are summarizing ONE todo item for a personal task database.\n" <>
    "Write in " <> lang <> ".\n" <>
    "Output EXACTLY two lines:\n" <>
    "Line 1: a one-sentence summary of what has to be done " <>
    "(use the notebook context to make it concrete).\n" <>
    "Line 2: 'DEADLINE: yyyy-mm-dd' if a deadline is stated or clearly " <>
    "implied by the todo text, else 'DEADLINE: NONE'.\n\n" <>
    "=== Todo item ===\n" <> ToString@Lookup[wrap, "Text", ""] <> "\n" <>
    With[{nt = ToString@Lookup[rec, "NotebookTitle", ""]},
      If[nt =!= "", "\n=== Notebook title ===\n" <> nt <> "\n", ""]] <>
    If[StringTrim[ctx] =!= "",
      "\n=== Notebook context (excerpt) ===\n" <> ctx <> "\n", ""]];

iSVTDParseLLMSummary[resp_String] :=
  Module[{lines, cand, sum, dl},
    lines = Select[StringSplit[resp, "\n"], StringTrim[#] =!= "" &];
    If[lines === {}, Return[<|"Summary" -> "", "Deadline" -> Missing[]|>]];
    cand = Select[lines,
      ! StringStartsQ[ToUpperCase[StringTrim[#]], "DEADLINE"] &];
    sum = StringTrim[If[cand === {}, First[lines], First[cand]]];
    dl = With[{m = StringCases[resp,
        RegularExpression["(?i)DEADLINE:\\s*([0-9]{4}-[0-9]{2}-[0-9]{2})"] ->
          "$1", 1]},
      If[m =!= {},
        With[{d = Quiet@Check[DateObject[First[m], "Day"], $Failed]},
          If[DateObjectQ[d], d, Missing[]]],
        Missing[]]];
    <|"Summary" -> sum, "Deadline" -> dl|>];

Options[SourceVaultTodoBackfillSummaries] = {
  "Limit" -> 10, "Force" -> False, "Model" -> Automatic,
  "MaxChars" -> 6000, "TimeoutSeconds" -> 120, "Status" -> "Open"};

SourceVaultTodoBackfillSummaries[opts : OptionsPattern[]] :=
  SourceVaultTodoBackfillSummaries["", opts];
SourceVaultTodoBackfillSummaries[query_String, OptionsPattern[]] :=
  Module[{rows, cands, out = {}, model = OptionValue["Model"],
      maxChars = OptionValue["MaxChars"], tmo = OptionValue["TimeoutSeconds"],
      explicitModel},
    If[! iSVTDLLMReady[],
      Return[<|"Status" -> "Failed", "Reason" -> "SummaryLLMUnavailable"|>]];
    explicitModel = ListQ[model] && Length[model] >= 2;
    rows = SourceVaultTodos[query, "Status" -> OptionValue["Status"]];
    cands = Select[rows,
      TrueQ[OptionValue["Force"]] ||
        StringTrim[ToString@Lookup[#, "Summary", ""]] === "" &];
    cands = Take[cands, UpTo[Max[0, OptionValue["Limit"]]]];
    Scan[
      Function[rec,
        Module[{id = Lookup[rec, "TodoId", ""], pl = iSVTDPLOf[rec], wrap,
            ctx, prompt, res, parsed, delta, effModel},
          Which[
            (* fail-closed: confidential rows (pl >= 0.5, incl. the 0.5
               default of undeclared notebooks) never reach the hub without
               a valid local model *)
            pl >= 0.5 && ! explicitModel && ! iSVTDPrivateModelReady[],
              AppendTo[out, <|"TodoId" -> id, "Status" -> "Skipped",
                "Reason" -> "PrivateModelUnavailable",
                "PrivacyLevel" -> pl,
                "Hint" -> "$ClaudePrivateModel = {provider, model, url} " <>
                  "(local LLM) is required for PL >= 0.5 rows."|>],
            True,
            (* confidential rows pass the LOCAL tuple explicitly (hub
               branch 1) -- pl exactly 0.5 would otherwise slip through the
               hub's strict > 0.5 test onto the cloud CLI *)
            (effModel = Which[
               explicitModel, model,
               pl >= 0.5, iSVTDPrivateModelTuple[],
               True, model];
             wrap = iSVTDWrapUntrusted[
               ToString@Lookup[rec, "Text", ""] <>
               With[{d = ToString@Lookup[rec, "Description", ""]},
                 If[StringTrim[d] =!= "", "\n" <> d, ""]]];
             If[TrueQ[Lookup[wrap, "Quarantined", False]],
               AppendTo[out, <|"TodoId" -> id, "Status" -> "Quarantined"|>],
               ctx = If[Lookup[rec, "Origin", ""] === "notebook" &&
                   IntegerQ[maxChars] && maxChars > 0,
                 iSVTDNotebookContext[rec, maxChars], ""];
               prompt = iSVTDBuildSummaryPrompt[rec, wrap, ctx];
               res = TimeConstrained[
                 Quiet@Check[
                   SourceVault`iCallSummaryLLM[prompt, effModel, pl], $Failed],
                 If[NumberQ[tmo], tmo, 120], $Failed];
               If[AssociationQ[res] && res["Status"] === "OK" &&
                   StringQ[res["Response"]],
                 parsed = iSVTDParseLLMSummary[res["Response"]];
                 delta = <|"Summary" -> parsed["Summary"],
                   "SummaryAt" -> iSVTDIsoNow[],
                   "SummaryModel" -> ToString@Lookup[res, "ResolvedModel", ""]|>;
                 If[DateObjectQ[parsed["Deadline"]] &&
                     ! DateObjectQ[Lookup[rec, "Deadline", Missing[]]],
                   delta["Deadline"] = DateString[parsed["Deadline"], "ISODate"];
                   delta["DeadlineSource"] = "LLM"];
                 iSVTDMutate[id, delta];
                 AppendTo[out, <|"TodoId" -> id, "Status" -> "OK",
                   "Summary" -> parsed["Summary"],
                   "Deadline" -> parsed["Deadline"]|>],
                 AppendTo[out, <|"TodoId" -> id, "Status" -> "Failed",
                   "Reason" -> If[AssociationQ[res],
                     ToString@Lookup[res, "Reason", "LLMFailed"],
                     "LLMFailed"]|>]]])]]],
      cands];
    <|"Status" -> "OK", "Processed" -> Length[out],
      "PrivateModelReady" -> iSVTDPrivateModelReady[], "Results" -> out|>];

(* ============================================================
   Agenda items (standalone open todos for the routine agenda)
   ============================================================ *)

Options[SourceVaultTodoAgendaItems] = {
  PrivacySpec -> <|"AccessLevel" -> 1.0|>, "MaxItems" -> 50};
SourceVaultTodoAgendaItems[OptionsPattern[]] :=
  Module[{ps = OptionValue[PrivacySpec], level, rows},
    level = Which[
      AssociationQ[ps] && NumericQ[Lookup[ps, "AccessLevel", Missing[]]],
        N[ps["AccessLevel"]],
      NumericQ[ps], N[ps], True, 1.0];
    rows = Quiet@Check[
      SourceVaultTodos["", "Status" -> "Open", "Origin" -> "standalone"], {}];
    If[! ListQ[rows], rows = {}];
    rows = Select[rows, iSVTDPLOf[#] <= level &];
    rows = Take[rows, UpTo[OptionValue["MaxItems"]]];
    Map[
      Function[r,
        <|"Kind" -> "Todo",
          "TodoId" -> Lookup[r, "TodoId", ""],
          "Label" -> Lookup[r, "Title", "(todo)"],
          "DueT" -> With[{a = iSVTDDateAbs[Lookup[r, "Deadline", Missing[]]]},
            If[NumberQ[a], a, Missing["None"]]],
          "HasDeadline" ->
            DateObjectQ[Lookup[r, "Deadline", Missing[]]],
          "State" -> "Open",
          "Summary" -> Lookup[r, "Summary", ""],
          "Recurred" -> TrueQ[Lookup[r, "Recurred", False]],
          "Priority" -> iSVTDPriorityOf[r],
          "PrivacyLevel" -> iSVTDPLOf[r]|>],
      rows]];
SourceVaultTodoAgendaItems[___] := {};

(* ============================================================
   Settings panel: deadline / review cycle / importance / privacy level /
   Open-Done-Pass-Keep, in the shape of the mail classification panel --
   edits are collected in the panel and written by ONE apply button
   (SourceVaultTodoUpdate), so a half-finished edit never reaches the store.
   For a notebook todo everything lands in the overlay; the .nb is untouched.
   ============================================================ *)

iSVTDPanelFont[] :=
  If[Length[DownValues[iSVUIFont]] > 0,
    Quiet@Check[iSVUIFont[], "Yu Gothic UI"], "Yu Gothic UI"];

iSVTDFmt01[x_] := If[NumericQ[x], ToString[NumberForm[N[x], {3, 2}]], "-"];

iSVTDStep01[v_, dv_] :=
  iSVTDClip01[If[NumericQ[v], N[v], 0.5] + dv];

iSVTDPriorityColor[p_] := Which[
  ! NumericQ[p], GrayLevel[0.5],
  p >= 0.8, RGBColor[0.8, 0.2, 0.2],
  p >= 0.6, RGBColor[0.85, 0.5, 0.1],
  p <= 0.3, GrayLevel[0.55],
  True, GrayLevel[0.25]];

iSVTDPriorityWord[p_] := Which[
  ! NumericQ[p], "",
  p >= 0.8, "\:9ad8",
  p >= 0.6, "\:3084\:3084\:9ad8",
  p <= 0.3, "\:4f4e",
  True, "\:4e2d"];

iSVTDCycleLabel[c_] := Switch[c,
  "Yearly", "\:5e74\:6b21", "HalfYearly", "\:534a\:5e74", "Quarterly", "\:56db\:534a\:671f",
  "Monthly", "\:6708\:6b21", "Weekly", "\:9031\:6b21", _, "\:306a\:3057"];

$iSVTDCycleMenu = {"None" -> "\:306a\:3057", "Weekly" -> "\:9031\:6b21",
  "Monthly" -> "\:6708\:6b21", "Quarterly" -> "\:56db\:534a\:671f",
  "HalfYearly" -> "\:534a\:5e74", "Yearly" -> "\:5e74\:6b21"};

iSVTDDayStr[d_] :=
  If[DateObjectQ[d], DateString[d, {"Year", "/", "Month", "/", "Day"}], ""];

(* "yyyy/mm/dd" typed in the field -> DateObject (Missing when blank/bad) *)
iSVTDFieldToDate[s_] :=
  If[StringQ[s] && StringTrim[s] =!= "", iSVTDToDate[StringTrim[s]],
    Missing["None"]];

iSVTDShiftField[s_, step_, nowAbs_] :=
  Module[{base, d2},
    base = With[{d = iSVTDFieldToDate[s]},
      If[DateObjectQ[d], d,
        DateObject[FromAbsoluteTime[nowAbs], "Day"]]];
    d2 = Quiet@Check[DatePlus[base, step], $Failed];
    If[DateObjectQ[d2], iSVTDDayStr[d2], If[StringQ[s], s, ""]]];

(* what the item will resurface on, computed from the values currently in the
   panel (no store read, so it is cheap enough to sit inside a Dynamic) *)
iSVTDPreviewNext[dlField_, cyc_, closedAbs_, nowAbs_] :=
  Module[{anchor, next, ref},
    If[! StringQ[cyc] || ! MemberQ[$iSVTDRecurCycles, cyc], Return[""]];
    ref = If[NumberQ[closedAbs], closedAbs, nowAbs];
    anchor = With[{d = iSVTDFieldToDate[dlField]},
      If[DateObjectQ[d], d, DateObject[FromAbsoluteTime[ref], "Day"]]];
    next = iSVTDNextRecurDue[anchor, cyc, ref];
    If[DateObjectQ[next], iSVTDDayStr[next], ""]];

iSVTDPanelMsg[r_] :=
  If[AssociationQ[r] && MemberQ[{"OK", "NoChange"}, Lookup[r, "Status", ""]],
    Style["\[Checkmark] " <>
      If[Lookup[r, "Status", ""] === "NoChange",
        "\:5909\:66f4\:304c\:3042\:308a\:307e\:305b\:3093", "\:53cd\:6620\:3057\:307e\:3057\:305f"],
      Darker@Green],
    Style["\[Times] " <>
      ToString@Lookup[If[AssociationQ[r], r, <||>], "Reason", "Error"], Red]];

Options[SourceVaultTodoEditPanel] = {"ShowNoteButton" -> True};
SourceVaultTodoEditPanel[id_String, OptionsPattern[]] :=
  Module[{rec, ff = iSVTDPanelFont[], st0, dl0, cyc0, lead0, prio0, pl0,
      leadOpts, nbQ, closedAbs, nowAbs = iSVTDNow[]},
    rec = SourceVaultTodoGet[id];
    If[! AssociationQ[rec],
      Return[Style["todo \:304c\:898b\:3064\:304b\:308a\:307e\:305b\:3093: " <> id, Red,
        FontFamily -> ff]]];
    nbQ = StringStartsQ[id, "svtodo-nb-"];
    st0 = ToString@Lookup[rec, "Status", "Open"];
    dl0 = iSVTDShortDate[Lookup[rec, "Deadline", Missing[]]];
    cyc0 = With[{r = Lookup[rec, "Recur", Missing[]]},
      If[AssociationQ[r] && StringQ[Lookup[r, "Cycle", Missing[]]],
        r["Cycle"], "None"]];
    lead0 = With[{r = Lookup[rec, "Recur", Missing[]]},
      If[AssociationQ[r] && NumberQ[Lookup[r, "LeadDays", Missing[]]],
        Round[N[r["LeadDays"]]], Automatic]];
    leadOpts = Join[{Automatic -> "\:65e2\:5b9a"},
      (# -> ToString[#] <> "\:65e5" &) /@
        Union[{2, 7, 14, 30, 60, 90}, If[IntegerQ[lead0], {lead0}, {}]]];
    prio0 = iSVTDPriorityOf[rec];
    pl0 = iSVTDPLOf[rec];
    closedAbs = With[{a = iSVTDDateAbs[iSVTDClosedStamp[rec]]},
      If[NumberQ[a], a, nowAbs]];
    With[{theId = id, ff2 = ff, now2 = nowAbs, closed2 = closedAbs,
        nb2 = nbQ, lopts = leadOpts,
        note2 = TrueQ[OptionValue["ShowNoteButton"]],
        dlSrc2 = ToString@Lookup[rec, "DeadlineSource", ""],
        plSrc2 = ToString@Lookup[rec, "PrivacyLevelSource", ""],
        st1 = st0, dl1 = dl0, cyc1 = cyc0, lead1 = lead0,
        prio1 = prio0, pl1 = pl0},
      DynamicModule[{st = st1, dl = dl1, cyc = cyc1, lead = lead1,
          prio = prio1, pl = pl1, busy = False, msg = ""},
        Panel[
          Column[{
            (* ---- status: Open / Done / Pass / Keep ---- *)
            Row[{
              Style["\:72b6\:614b ", "Text", FontFamily -> ff2],
              SetterBar[Dynamic[st],
                {"Open" -> "Open", "Done" -> "Done", "Pass" -> "Pass",
                 "Keep" -> "Keep"}, BaseStyle -> {FontFamily -> ff2}],
              Spacer[10],
              If[nb2,
                Button[Style["\:81ea\:52d5 (\:30bb\:30eb\:6e96\:62e0\:306b\:623b\:3059)", FontFamily -> ff2],
                  (busy = True;
                   msg = iSVTDPanelMsg[
                     SourceVaultTodoSetStatus[theId, Automatic]];
                   With[{rr = SourceVaultTodoGet[theId]},
                     If[AssociationQ[rr],
                       st = ToString@Lookup[rr, "Status", "Open"]]];
                   busy = False), Method -> "Queued"],
                ""],
              Spacer[10],
              Style["Pass = \:4eca\:56de\:306f\:898b\:9001\:308a (\:5468\:671f\:304c\:3042\:308c\:3070\:6b21\:56de\:518d\:6d6e\:4e0a)",
                GrayLevel[0.45], 10, FontFamily -> ff2]},
              BaselinePosition -> Center],
            (* ---- deadline ---- *)
            Row[{
              Style["\:3006\:5207 ", "Text", FontFamily -> ff2],
              InputField[Dynamic[dl], String, FieldSize -> {9, 1},
                BaseStyle -> {FontFamily -> ff2}],
              Spacer[4],
              Button[Style["\:4eca\:65e5", FontFamily -> ff2],
                dl = iSVTDDayStr[DateObject[FromAbsoluteTime[now2], "Day"]],
                Appearance -> "Palette", ImageSize -> {46, 20}],
              Button[Style["+1\:9031", FontFamily -> ff2],
                dl = iSVTDShiftField[dl, {7, "Day"}, now2],
                Appearance -> "Palette", ImageSize -> {46, 20}],
              Button[Style["+1\:30f6\:6708", FontFamily -> ff2],
                dl = iSVTDShiftField[dl, {1, "Month"}, now2],
                Appearance -> "Palette", ImageSize -> {56, 20}],
              Button[Style["\:306a\:3057", FontFamily -> ff2], dl = "",
                Appearance -> "Palette", ImageSize -> {46, 20}],
              Spacer[10],
              Style["yyyy/mm/dd", GrayLevel[0.5], 10],
              If[MemberQ[{"TextParse", "Recurrence", "Cleared"}, dlSrc2],
                Style["  (\:7531\:6765: " <> dlSrc2 <> ")", GrayLevel[0.5], 10,
                  FontFamily -> ff2], ""]},
              BaselinePosition -> Center],
            (* ---- review cycle ---- *)
            Row[{
              Style["\:6b21\:56de\:30ec\:30d3\:30e5\:30fc ", "Text", FontFamily -> ff2],
              PopupMenu[Dynamic[cyc], $iSVTDCycleMenu,
                MenuStyle -> {FontFamily -> ff2}],
              Spacer[8],
              Style["\:30ea\:30fc\:30c9 ", "Text", FontFamily -> ff2],
              PopupMenu[Dynamic[lead], lopts,
                MenuStyle -> {FontFamily -> ff2}],
              Spacer[10],
              Dynamic[
                With[{n = iSVTDPreviewNext[dl, cyc, closed2, now2]},
                  If[n === "", Style["", 10],
                    Style["\:6b21\:56de: " <> n, RGBColor[0.35, 0.3, 0.7], 10,
                      FontFamily -> ff2]]]]},
              BaselinePosition -> Center],
            (* ---- importance / privacy level ---- *)
            Row[{
              Style["\:91cd\:8981\:5ea6 ", "Text", FontFamily -> ff2],
              Button["\[EmptyDownTriangle]", prio = iSVTDStep01[prio, -0.1],
                Appearance -> "Palette", ImageSize -> {24, 20}],
              Pane[Dynamic@Style[iSVTDFmt01[prio], "Text", Bold,
                  iSVTDPriorityColor[prio], FontFamily -> ff2],
                {42, Automatic}, Alignment -> Center],
              Button["\[EmptyUpTriangle]", prio = iSVTDStep01[prio, +0.1],
                Appearance -> "Palette", ImageSize -> {24, 20}],
              Spacer[4],
              Dynamic@Style[iSVTDPriorityWord[prio],
                iSVTDPriorityColor[prio], 10, FontFamily -> ff2],
              Spacer[16],
              Style["\:79d8\:533f ", "Text", FontFamily -> ff2],
              Button["\[EmptyDownTriangle]", pl = iSVTDStep01[pl, -0.1],
                Appearance -> "Palette", ImageSize -> {24, 20}],
              Pane[Dynamic@Style[iSVTDFmt01[pl], "Text", Bold,
                  FontFamily -> ff2], {42, Automatic}, Alignment -> Center],
              Button["\[EmptyUpTriangle]", pl = iSVTDStep01[pl, +0.1],
                Appearance -> "Palette", ImageSize -> {24, 20}],
              Spacer[6],
              Dynamic[If[NumericQ[pl] && pl >= 0.5,
                Style["\:6a5f\:5bc6 (\:8981\:7d04\:306f\:30ed\:30fc\:30ab\:30ebLLM\:306e\:307f)",
                  RGBColor[0.75, 0.2, 0.2], 10, FontFamily -> ff2],
                Style["", 10]]],
              If[plSrc2 === "Overlay",
                Style["  (\:30ce\:30fc\:30c8\:65e2\:5b9a\:3092\:4e0a\:66f8\:304d)", GrayLevel[0.5], 10,
                  FontFamily -> ff2], ""]},
              BaselinePosition -> Center],
            (* ---- apply ---- *)
            Row[{
              Button[Style["\:53cd\:6620", Bold, FontFamily -> ff2],
                (busy = True;
                 Module[{spec = <||>, base, curDl, curCyc, curLead, r},
                   base = With[{b = SourceVaultTodoGet[theId]},
                     If[AssociationQ[b], b, <||>]];
                   If[st =!= ToString@Lookup[base, "Status", "Open"],
                     spec["Status"] = st];
                   curDl = iSVTDShortDate[Lookup[base, "Deadline", Missing[]]];
                   With[{v = StringTrim[If[StringQ[dl], dl, ""]]},
                     Which[
                       v === "" && curDl =!= "", spec["Deadline"] = None,
                       v =!= "" && v =!= curDl,
                         spec["Deadline"] =
                           If[DateObjectQ[iSVTDFieldToDate[v]], v, $Failed]]];
                   curCyc = With[{rr = Lookup[base, "Recur", Missing[]]},
                     If[AssociationQ[rr] &&
                         StringQ[Lookup[rr, "Cycle", Missing[]]],
                       rr["Cycle"], "None"]];
                   curLead = With[{rr = Lookup[base, "Recur", Missing[]]},
                     If[AssociationQ[rr] &&
                         NumberQ[Lookup[rr, "LeadDays", Missing[]]],
                       Round[N[rr["LeadDays"]]], Automatic]];
                   If[cyc =!= curCyc,
                     spec["Recur"] = If[cyc === "None", None, cyc]];
                   If[lead =!= curLead && cyc =!= "None",
                     spec["RecurLeadDays"] =
                       If[NumberQ[lead], N[lead], Automatic]];
                   If[Abs[prio - iSVTDPriorityOf[base]] > 0.004,
                     spec["Priority"] = prio];
                   If[Abs[pl - iSVTDPLOf[base]] > 0.004,
                     spec["PrivacyLevel"] = pl];
                   Which[
                     Lookup[spec, "Deadline", Missing[]] === $Failed,
                       msg = Style[
                         "\[Times] \:65e5\:4ed8\:306f yyyy/mm/dd \:3067\:5165\:529b\:3057\:3066\:304f\:3060\:3055\:3044", Red],
                     spec === <||>,
                       msg = Style["\:5909\:66f4\:304c\:3042\:308a\:307e\:305b\:3093", Gray],
                     True,
                       r = SourceVaultTodoUpdate[theId, spec];
                       msg = iSVTDPanelMsg[r];
                       With[{rr = SourceVaultTodoGet[theId]},
                         If[AssociationQ[rr],
                           st = ToString@Lookup[rr, "Status", "Open"];
                           dl = iSVTDShortDate[
                             Lookup[rr, "Deadline", Missing[]]];
                           prio = iSVTDPriorityOf[rr];
                           pl = iSVTDPLOf[rr]]]]];
                 busy = False), Method -> "Queued"],
              Spacer[6],
              If[note2,
                Button[Style["\:30ce\:30fc\:30c8\:3092\:958b\:304f", FontFamily -> ff2],
                  SourceVaultTodoShowSummary[theId], Method -> "Queued"], ""],
              Spacer[8],
              Dynamic[If[busy, ProgressIndicator[Appearance -> "Necklace"],
                ""]],
              Spacer[6], Dynamic[msg],
              Spacer[10],
              Style["\:4e00\:89a7\:306f\:518d\:8a55\:4fa1\:3067\:66f4\:65b0\:3055\:308c\:307e\:3059", GrayLevel[0.5], 10,
                FontFamily -> ff2]},
              BaselinePosition -> Center]},
            Spacings -> 0.6],
          Style["\:3053\:306etodo \:306e\:8a2d\:5b9a", "Text", FontFamily -> ff2]]]]];
SourceVaultTodoEditPanel[rec_Association, opts : OptionsPattern[]] :=
  SourceVaultTodoEditPanel[ToString@Lookup[rec, "TodoId", ""], opts];
SourceVaultTodoEditPanel[___] := "";

SourceVaultTodoEditWindow[id_String] :=
  Quiet@Check[
    CreateDocument[
      ExpressionCell[SourceVaultTodoEditPanel[id], "Output",
        CellMargins -> {{15, 15}, {12, 12}}],
      WindowTitle -> "Todo \:8a2d\:5b9a: " <> StringTake[id, UpTo[28]],
      WindowSize -> {920, 260}], $Failed];
SourceVaultTodoEditWindow[rec_Association] :=
  SourceVaultTodoEditWindow[ToString@Lookup[rec, "TodoId", ""]];
SourceVaultTodoEditWindow[___] := $Failed;

(* ============================================================
   View
   ============================================================ *)

iSVTDDueColor[dueAbs_, nowAbs_] := Which[
  ! NumberQ[dueAbs], GrayLevel[0.1],
  dueAbs < nowAbs - 86400., RGBColor[0.85, 0.2, 0.2],
  dueAbs <= nowAbs + 2*86400., RGBColor[0.2, 0.45, 0.8],
  True, GrayLevel[0.1]];

iSVTDStatusLabel[rec_Association] :=
  With[{st = ToString@Lookup[rec, "Status", ""],
        rc = TrueQ[Lookup[rec, "Recurred", False]],
        hasRecur = AssociationQ[Lookup[rec, "Recur", Missing[]]]},
    Row[{Style[st, Switch[st,
        "Open", RGBColor[0.75, 0.35, 0.1],
        "Done", RGBColor[0.2, 0.55, 0.35],
        "Pass", RGBColor[0.45, 0.45, 0.65],
        _, GrayLevel[0.4]], Bold, 10],
      If[hasRecur,
        Style[" \:21bb" <> If[rc, "!", ""], RGBColor[0.35, 0.3, 0.7], 10],
        ""]}]];

Options[SourceVaultTodosView] = Join[Options[SourceVaultTodos],
  {"MaxRows" -> Automatic}];
SourceVaultTodosView[opts : OptionsPattern[]] := SourceVaultTodosView["", opts];
SourceVaultTodosView[query_String, opts : OptionsPattern[]] :=
  Module[{rows, total, cap, shown, ff, header, body, grid, nowAbs = iSVTDNow[]},
    rows = SourceVaultTodos[query,
      Sequence @@ FilterRules[Flatten[{opts}], Options[SourceVaultTodos]]];
    If[! ListQ[rows], rows = {}];
    total = Length[rows];
    cap = With[{m = OptionValue["MaxRows"]},
      Which[IntegerQ[m] && m >= 0, m, m === All, total,
        True, $SourceVaultTodoViewMaxRows]];
    shown = Take[rows, UpTo[cap]];
    If[shown === {},
      Return[Style["\:8a72\:5f53\:3059\:308b todo \:306f\:3042\:308a\:307e\:305b\:3093\:3002", "Text"]]];
    ff = If[Length[DownValues[iSVUIFont]] > 0,
      Quiet@Check[iSVUIFont[], "Yu Gothic UI"], "Yu Gothic UI"];
    header = (Style[#, Bold, FontFamily -> ff] &) /@
      {"Act", "\:72b6\:614b", "\:3006\:5207", "\:5185\:5bb9",
       "\:30b5\:30de\:30ea\:30fc", "\:30ce\:30fc\:30c8", "\:91cd\:8981", "PL",
       "\:767b\:9332"};
    body = Function[rec,
      Module[{id = ToString@Lookup[rec, "TodoId", ""],
          text = ToString@Lookup[rec, "Title", ""],
          sum = ToString@Lookup[rec, "Summary", ""],
          nbPath = Lookup[rec, "NotebookPath", Missing[]],
          nbTitle = ToString@Lookup[rec, "NotebookTitle", ""],
          lk = Lookup[rec, "LinkKind", Missing[]],
          li = Lookup[rec, "LinkId", Missing[]],
          dlAbs = iSVTDDateAbs[Lookup[rec, "Deadline", Missing[]]],
          dlStr, actRow, nbCell},
        dlStr = iSVTDShortDate[Lookup[rec, "Deadline", Missing[]]];
        (* row actions live in COLUMN 1 only (button hit-area rule) *)
        actRow = Row[{
          With[{theId = id},
            Tooltip[Button["\:2713",
              (SourceVaultTodoDone[theId];
               Quiet@Check[iSVTDRefreshNote[], Null]),
              Appearance -> "Frameless", Method -> "Queued",
              BaseStyle -> {RGBColor[0.2, 0.55, 0.35], Bold}],
              "Done \:306b\:3059\:308b (\:518d\:8a55\:4fa1\:3067\:53cd\:6620)"]],
          "  ",
          With[{theId = id},
            Tooltip[Button["\:00bb",
              (SourceVaultTodoPass[theId];
               Quiet@Check[iSVTDRefreshNote[], Null]),
              Appearance -> "Frameless", Method -> "Queued",
              BaseStyle -> {RGBColor[0.45, 0.45, 0.65], Bold}],
              "Pass \:306b\:3059\:308b (\:4eca\:56de\:306f\:898b\:9001\:308a\:3002\:5468\:671f\:304c\:3042\:308c\:3070\:6b21\:56de\:518d\:6d6e\:4e0a)"]],
          "  ",
          With[{theId = id},
            Tooltip[Button["\:21bb",
              iSVTDRecurDialog[theId],
              Appearance -> "Frameless", Method -> "Queued",
              BaseStyle -> {RGBColor[0.35, 0.3, 0.7], Bold}],
              "\:30ea\:30de\:30a4\:30f3\:30c9 (\:5e74\:6b21/\:6708\:6b21...) \:3092\:8a2d\:5b9a"]],
          "  ",
          With[{theId = id},
            Tooltip[Button[Style["\:8a2d\:5b9a", 10],
              SourceVaultTodoEditWindow[theId],
              Appearance -> "Frameless", Method -> "Queued",
              BaseStyle -> {RGBColor[0.25, 0.4, 0.7], Bold}],
              "\:8a2d\:5b9a\:3092\:7de8\:96c6 (\:3006\:5207/\:30ec\:30d3\:30e5\:30fc\:5468\:671f/\:91cd\:8981\:5ea6/\:79d8\:533f)"]]}];
        nbCell = Which[
          StringQ[nbPath],
            With[{p = nbPath, t = nbTitle},
              Tooltip[Button[
                Style[iSVTDTrunc[t, 24], "Hyperlink", FontFamily -> ff],
                SystemOpen[p], Appearance -> "Frameless", Method -> "Queued",
                BaseStyle -> "Hyperlink"], "\:958b\:304f: " <> p]],
          StringQ[lk] && StringQ[li],
            With[{k = lk, i = li},
              Tooltip[Button[
                Style[k <> ":" <> iSVTDTrunc[i, 14], "Hyperlink",
                  FontFamily -> ff],
                iSVTDOpenLink[k, i], Appearance -> "Frameless",
                Method -> "Queued", BaseStyle -> "Hyperlink"],
                "\:30ea\:30f3\:30af\:5148\:3092\:958b\:304f"]],
          True, ""];
        {actRow,
         iSVTDStatusLabel[rec],
         If[dlStr === "", "",
           Style[dlStr, iSVTDDueColor[dlAbs, nowAbs], Bold, 10,
             FontFamily -> ff]],
         With[{theId = id, t = text},
           Tooltip[Button[
             Style[iSVTDTrunc[t, 56], "Hyperlink", FontFamily -> ff],
             SourceVaultTodoShowSummary[theId], Appearance -> "Frameless",
             Method -> "Queued", BaseStyle -> "Hyperlink"],
             t <> "\n(\:30af\:30ea\:30c3\:30af\:3067 todo \:30ce\:30fc\:30c8\:3092\:958b\:304f)  Id: " <> theId]],
         If[sum === "", "",
           Tooltip[Style[iSVTDTrunc[sum, 40], FontFamily -> ff], sum]],
         nbCell,
         With[{p = iSVTDPriorityOf[rec]},
           Tooltip[
             Style[iSVTDFmt01[p], iSVTDPriorityColor[p], Bold, 10,
               FontFamily -> ff],
             "\:91cd\:8981\:5ea6 " <> iSVTDFmt01[p] <> " " <>
               iSVTDPriorityWord[p]]],
         With[{p = iSVTDPLOf[rec]}, ToString[p]],
         With[{a = ToString@Lookup[rec, "AddedAt", ""]},
           If[a === "", "", StringTake[a, UpTo[10]]]]}]] /@ shown;
    grid = Grid[Prepend[body, header],
      Frame -> All, FrameStyle -> Directive[GrayLevel[0.85]],
      Background -> {None, {GrayLevel[0.92], {White}}},
      Alignment -> {Left, Center}, Spacings -> {1.2, 0.6},
      BaseStyle -> {FontFamily -> ff}];
    iSVTDPrivateView[
      Column[{
        Style["SourceVault Todo (" <> ToString[total] <> " \:4ef6)",
          Bold, 14, FontFamily -> ff],
        If[Length[shown] < total,
          Style["\:5148\:982d " <> ToString[Length[shown]] <>
            " \:4ef6\:3092\:8868\:793a (\"MaxRows\" -> All \:3067\:5168\:4ef6)",
            GrayLevel[0.45], FontFamily -> ff], Nothing],
        grid}],
      shown]];
SourceVaultTodosView[___] := Style["SourceVaultTodosView: bad args.", Red];

iSVTDTrunc[s_String, n_Integer] :=
  If[StringLength[s] > n, StringTake[s, n - 1] <> "\[Ellipsis]", s];
iSVTDTrunc[s_, n_] := ToString[s];

iSVTDRefreshNote[] := Null;   (* placeholder; grid refresh = re-evaluate *)

iSVTDRecurDialog[id_String] :=
  CreateDialog[
    Column[{
      Style["\:30ea\:30de\:30a4\:30f3\:30c9\:5468\:671f\:3092\:9078\:629e: " <> id, Bold],
      Row[Riffle[
        Map[
          Function[cyc,
            With[{c = cyc, theId = id},
              Button[Switch[c,
                  "Yearly", "\:5e74\:6b21", "HalfYearly", "\:534a\:5e74",
                  "Quarterly", "\:56db\:534a\:671f", "Monthly", "\:6708\:6b21",
                  "Weekly", "\:9031\:6b21", _, c],
                (SourceVaultTodoRemindNext[theId, c];
                 DialogReturn[]), Method -> "Queued"]]],
          $iSVTDRecurCycles],
        Spacer[4]]],
      With[{theId = id},
        Button["\:89e3\:9664 (\:30de\:30fc\:30ab\:30fc\:524a\:9664)",
          (SourceVaultTodoRemindNext[theId, None]; DialogReturn[]),
          Method -> "Queued"]],
      Button["\:9589\:3058\:308b", DialogReturn[], Method -> "Queued"]},
      Spacings -> 1],
    WindowTitle -> "Todo \:30ea\:30de\:30a4\:30f3\:30c9"];

(* open a linked summary through the registered row action of that kind *)
iSVTDOpenLink[kind_String, id_String] :=
  With[{act = Lookup[
      If[AssociationQ[$iSVRowTitleActions], $iSVRowTitleActions, <||>],
      kind, Automatic]},
    Which[
      act =!= Automatic, Quiet@Check[act[id], $Failed],
      Length[DownValues[SourceVaultShowSourceSummary]] > 0,
        Quiet@Check[SourceVaultShowSourceSummary[id], $Failed],
      True, $Failed]];

(* ============================================================
   Wolfram Cloud form: deploy / fetch / periodic sync
   ============================================================ *)

SourceVaultTodoDeployCloudForm::deploy =
  "Cloud deploy requires $SourceVaultTodoAllowCloudDeploy = True.";

Options[SourceVaultTodoDeployCloudForm] = {"Permissions" -> "Public"};
SourceVaultTodoDeployCloudForm[OptionsPattern[]] :=
  Module[{form, obj},
    If[! TrueQ[$SourceVaultTodoAllowCloudDeploy],
      Message[SourceVaultTodoDeployCloudForm::deploy];
      Return[Failure["DeployBlocked",
        <|"MessageTemplate" ->
          "Set $SourceVaultTodoAllowCloudDeploy = True first."|>]]];
    (* the handler runs in the cloud WITHOUT SourceVault: System` only, the
       inbox path baked in as a literal *)
    form = With[{inbox = $SourceVaultTodoCloudInboxPath},
      FormFunction[
        {"item" -> <|"Interpreter" -> "String",
           "Label" -> "\:9805\:76ee",
           "Help" -> "todo \:306e\:5185\:5bb9 (\:5fc5\:9808)"|>,
         "description" -> <|"Interpreter" -> "String", "Required" -> False,
           "Label" -> "\:8aac\:660e (\:4efb\:610f)"|>,
         "deadline" -> <|"Interpreter" -> "Date", "Required" -> False,
           "Label" -> "\:3006\:5207 (\:4efb\:610f)"|>,
         "privacy" -> <|"Interpreter" -> Restricted["Number", {0, 1}],
           "Default" -> 1.0,
           "Label" -> "PrivacyLevel (0=\:516c\:958b\:53ef \[Dash] 1=\:6a5f\:5bc6)"|>},
        Function[params, Module[{rec, uuid},
          uuid = CreateUUID[];
          rec = <|
            "Item" -> ToString[Lookup[params, "item", ""]],
            "Description" -> With[{d = Lookup[params, "description", ""]},
              If[StringQ[d], d, ""]],
            "Deadline" -> With[{d = Lookup[params, "deadline", None]},
              If[DateObjectQ[d], DateString[d, "ISODate"], None]],
            "PrivacyLevel" -> With[{p = Lookup[params, "privacy", 1.0]},
              If[NumericQ[p], N[p], 1.0]],
            "AddedAt" -> DateString[DateObject[TimeZone -> 0],
                "ISODateTime"] <> "Z"|>;
          CloudPut[rec, CloudObject[inbox <> "/" <> uuid]];
          "\:767b\:9332\:3057\:307e\:3057\:305f\:3002 (id: " <> uuid <> ")"]],
        AppearanceRules -> <|
          "Title" -> "Todo \:767b\:9332",
          "Description" ->
            "SourceVault \:306e todo \:3092\:8ffd\:52a0\:3057\:307e\:3059\:3002" <>
            " \:767b\:9332\:6642\:523b\:306f\:81ea\:52d5\:8a18\:9332\:3055\:308c\:307e\:3059\:3002"|>]];
    obj = Quiet@Check[
      CloudDeploy[form, $SourceVaultTodoCloudFormPath,
        Permissions -> OptionValue["Permissions"]], $Failed];
    If[Head[obj] === CloudObject,
      <|"Status" -> "OK", "CloudObject" -> obj,
        "URL" -> First[obj], "Inbox" -> $SourceVaultTodoCloudInboxPath|>,
      <|"Status" -> "Failed", "Reason" -> "CloudDeployFailed",
        "Result" -> obj|>]];

(* injectable cloud IO seams (tests run without a cloud connection) *)
If[! ValueQ[$iSVTDCloudConnectedQFn], $iSVTDCloudConnectedQFn = Automatic];
If[! ValueQ[$iSVTDCloudObjectsFn], $iSVTDCloudObjectsFn = Automatic];
If[! ValueQ[$iSVTDCloudGetFn], $iSVTDCloudGetFn = Automatic];
If[! ValueQ[$iSVTDCloudDeleteFn], $iSVTDCloudDeleteFn = Automatic];

iSVTDCloudConnectedQ[] :=
  If[$iSVTDCloudConnectedQFn === Automatic,
    TrueQ[Quiet@Check[$CloudConnected, False]],
    TrueQ[Quiet@Check[$iSVTDCloudConnectedQFn[], False]]];

Options[SourceVaultTodoCloudFetch] = {"Delete" -> True, "MaxItems" -> 100};
SourceVaultTodoCloudFetch[OptionsPattern[]] :=
  Module[{objs, fetched = 0, deleted = 0, errors = 0, results = {}},
    If[! iSVTDCloudConnectedQ[],
      Return[<|"Status" -> "Skipped", "Reason" -> "NotCloudConnected"|>]];
    objs = If[$iSVTDCloudObjectsFn === Automatic,
      Quiet@Check[CloudObjects[$SourceVaultTodoCloudInboxPath], $Failed],
      Quiet@Check[$iSVTDCloudObjectsFn[], $Failed]];
    If[! ListQ[objs],
      Return[<|"Status" -> "OK", "Fetched" -> 0, "Deleted" -> 0,
        "Errors" -> 0, "Note" -> "InboxEmptyOrUnreadable"|>]];
    objs = Take[objs, UpTo[OptionValue["MaxItems"]]];
    Scan[
      Function[o,
        Module[{data, res},
          data = If[$iSVTDCloudGetFn === Automatic,
            Quiet@Check[CloudGet[o], $Failed],
            Quiet@Check[$iSVTDCloudGetFn[o], $Failed]];
          If[AssociationQ[data] &&
              StringTrim[ToString@Lookup[data, "Item", ""]] =!= "",
            res = SourceVaultNewTodo[<|
              "Title" -> ToString@Lookup[data, "Item", ""],
              "Description" -> ToString@Lookup[data, "Description", ""],
              "Deadline" -> Lookup[data, "Deadline", None],
              "PrivacyLevel" -> Lookup[data, "PrivacyLevel", 1.0],
              "Source" -> "cloud",
              "AddedAt" -> ToString@Lookup[data, "AddedAt", ""]|>];
            If[AssociationQ[res] && res["Status"] === "OK",
              fetched++;
              AppendTo[results, res["TodoId"]];
              If[TrueQ[OptionValue["Delete"]],
                If[$iSVTDCloudDeleteFn === Automatic,
                  If[Quiet@Check[DeleteObject[o]; True, False], deleted++],
                  If[Quiet@Check[$iSVTDCloudDeleteFn[o]; True, False],
                    deleted++]]],
              errors++],
            errors++]]],
      objs];
    <|"Status" -> "OK", "Fetched" -> fetched, "Deleted" -> deleted,
      "Errors" -> errors, "TodoIds" -> results|>];

(* --- periodic sync on the shared claudecode polling tick (rule 95) --- *)

If[! ValueQ[$iSVTDCloudSyncLastFetch], $iSVTDCloudSyncLastFetch = 0];
If[! ValueQ[$iSVTDCloudSyncLastAttempt], $iSVTDCloudSyncLastAttempt = 0];
If[! ValueQ[$iSVTDCloudSyncLastResult], $iSVTDCloudSyncLastResult = None];
If[! ValueQ[$iSVTDCloudSyncRegistered], $iSVTDCloudSyncRegistered = False];

iSVTDCloudSyncStateFile[] :=
  FileNameJoin[{iSVTDLocalStateDir[], "todo_cloudsync_state.wxf"}];

iSVTDCloudSyncLoadState[] :=
  With[{f = iSVTDCloudSyncStateFile[]},
    If[FileExistsQ[f],
      With[{d = Quiet@Check[Import[f, "WXF"], $Failed]},
        If[AssociationQ[d],
          $iSVTDCloudSyncLastFetch = Lookup[d, "LastFetch", 0]]]]];

iSVTDCloudSyncSaveState[] :=
  Module[{f = iSVTDCloudSyncStateFile[], tmp},
    iSVTDEnsureDir[DirectoryName[f]];
    tmp = f <> ".tmp" <> ToString[$ProcessID];
    Quiet@Check[
      Export[tmp, <|"LastFetch" -> $iSVTDCloudSyncLastFetch|>, "WXF"];
      RenameFile[tmp, f, OverwriteTarget -> True],
      Quiet@DeleteFile[tmp]]];

iSVTDCloudSyncTickBody[] :=
  Quiet@Check[
    Module[{now = N[AbsoluteTime[]], interval},
      interval = If[NumberQ[$SourceVaultTodoCloudSyncIntervalHours],
        $SourceVaultTodoCloudSyncIntervalHours*3600., 12.*3600.];
      (* due yet? attempts are additionally spaced 15 min apart so an
         offline machine does not probe the cloud every tick *)
      If[now - $iSVTDCloudSyncLastFetch < interval, Return[Null]];
      If[now - $iSVTDCloudSyncLastAttempt < 900., Return[Null]];
      $iSVTDCloudSyncLastAttempt = now;
      If[! iSVTDCloudConnectedQ[], Return[Null]];
      $iSVTDCloudSyncLastResult = TimeConstrained[
        SourceVaultTodoCloudFetch[], 60,
        <|"Status" -> "Failed", "Reason" -> "Timeout"|>];
      If[AssociationQ[$iSVTDCloudSyncLastResult] &&
          $iSVTDCloudSyncLastResult["Status"] === "OK",
        $iSVTDCloudSyncLastFetch = now;
        iSVTDCloudSyncSaveState[]];
      Null],
    Null];

iSVTDClaudeSym[name_String] :=
  If[Names[name] === {}, $Failed,
    With[{s = Symbol[name]},
      If[Length[DownValues[s]] > 0, s, $Failed]]];

SourceVaultTodoCloudSyncStart[] :=
  Module[{reg = iSVTDClaudeSym["ClaudeCode`ClaudeRegisterPollingTick"]},
    If[reg === $Failed,
      Return[<|"Status" -> "Failed", "Reason" -> "ClaudeCodeAbsent"|>]];
    iSVTDCloudSyncLoadState[];
    Quiet@Check[
      reg["sourcevault-todo-cloudsync", iSVTDCloudSyncTickBody[] &,
        "Phase" -> "todo-cloudsync", "Caller" -> "SourceVaultTodo"],
      Null];
    $iSVTDCloudSyncRegistered = True;
    <|"Status" -> "Registered", "IntervalHours" ->
      $SourceVaultTodoCloudSyncIntervalHours|>];

SourceVaultTodoCloudSyncStop[] :=
  Module[{unreg = iSVTDClaudeSym["ClaudeCode`ClaudeUnregisterPollingTick"]},
    $iSVTDCloudSyncRegistered = False;
    If[unreg === $Failed,
      Return[<|"Status" -> "Failed", "Reason" -> "ClaudeCodeAbsent"|>]];
    Quiet@Check[unreg["sourcevault-todo-cloudsync"], Null];
    <|"Status" -> "Unregistered"|>];

SourceVaultTodoCloudSyncStatus[] :=
  <|"Registered" -> TrueQ[$iSVTDCloudSyncRegistered],
    "LastFetch" -> If[$iSVTDCloudSyncLastFetch > 0,
      Quiet@Check[DateString[FromAbsoluteTime[$iSVTDCloudSyncLastFetch]],
        $iSVTDCloudSyncLastFetch], None],
    "LastResult" -> $iSVTDCloudSyncLastResult,
    "IntervalHours" -> $SourceVaultTodoCloudSyncIntervalHours|>;

If[TrueQ[$SourceVaultTodoCloudSyncAutoStart],
  Quiet@Check[SourceVaultTodoCloudSyncStart[], Null]];

(* ============================================================
   Cross-search provider ("todo" rows in SourceVaultSummaries / CrossLinks)
   ============================================================ *)

iSVTDCommonRows[query_String, opts_Association] :=
  Module[{rows},
    rows = Quiet@Check[SourceVaultTodos[query, "Status" -> "All"], {}];
    If[! ListQ[rows], Return[{}]];
    Map[
      Function[r,
        <|"Kind" -> "todo",
          "Id" -> ToString@Lookup[r, "TodoId", ""],
          "URI" -> ToString@Lookup[r, "URI", ""],
          "Title" -> ToString@Lookup[r, "Title", ""],
          "Authors" -> "",
          "Published" -> With[{d = iSVTDIso[Lookup[r, "Deadline", Missing[]]]},
            If[StringQ[d], d, ""]],
          "Summary" -> With[{s = ToString@Lookup[r, "Summary", ""]},
            If[s =!= "", s, ToString@Lookup[r, "Description", ""]]],
          "URL" -> "",
          "File" -> With[{p = Lookup[r, "NotebookPath", Missing[]]},
            If[StringQ[p], p, ""]],
          "Date" -> ToString@Lookup[r, "AddedAt", ""],
          "PrivacyLevel" -> iSVTDPLOf[r],
          (* kind-specific columns *)
          "Status" -> ToString@Lookup[r, "Status", ""],
          "Origin" -> ToString@Lookup[r, "Origin", ""]|>],
      rows]];
iSVTDCommonRows[query_String] := iSVTDCommonRows[query, <||>];

(* fully qualified: the registry is a SourceVault` PUBLIC symbol declared by
   SourceVault.wl. An unqualified reference here would work under the umbrella
   but mint an orphan SourceVault`Private symbol in a standalone Get. *)
If[! AssociationQ[SourceVault`$SourceVaultSummaryProviders],
  SourceVault`$SourceVaultSummaryProviders = <||>];
SourceVault`$SourceVaultSummaryProviders["todo"] = iSVTDCommonRows;

If[! AssociationQ[$iSVRowTitleActions], $iSVRowTitleActions = <||>];
$iSVRowTitleActions["todo"] = Function[id, SourceVaultTodoShowSummary[id]];
If[! AssociationQ[$iSVRowOpenActions], $iSVRowOpenActions = <||>];
$iSVRowOpenActions["todo"] = Function[id,
  With[{rec = SourceVaultTodoGet[id]},
    Which[
      AssociationQ[rec] && StringQ[Lookup[rec, "NotebookPath", Missing[]]],
        SystemOpen[rec["NotebookPath"]],
      AssociationQ[rec] && StringQ[Lookup[rec, "LinkKind", Missing[]]] &&
        StringQ[Lookup[rec, "LinkId", Missing[]]],
        iSVTDOpenLink[rec["LinkKind"], rec["LinkId"]],
      True, SourceVaultTodoShowSummary[id]]]];

(* ============================================================
   Privacy contracts (weak; registry may be absent in slim loads)
   ============================================================ *)

Quiet@Check[
  If[Length[DownValues[SourceVault`SourceVaultRegisterPrivacyContract]] > 0,
    Scan[SourceVault`SourceVaultRegisterPrivacyContract[First[#],
        <|"Class" -> "Private", "Exit" -> Last[#], "Sources" -> {"todo"},
          "Module" -> "SourceVault_todo.wl"|>] &,
      {{"SourceVaultTodos", "Result"},
       {"SourceVaultTodosView", "View"},
       {"SourceVaultTodoUpdate", "Result"},
       {"SourceVaultTodoGet", "Result"},
       {"SourceVaultTodoShowSummary", "View"},
       {"SourceVaultTodoAgendaItems", "Result"},
       {"SourceVaultTodoBackfillSummaries", "Result"},
       {"SourceVaultNewTodo", "Result"},
       {"SourceVaultTodoCloudFetch", "Result"}}];
    Scan[SourceVault`SourceVaultRegisterPrivacyContract[#,
        <|"Class" -> "Public", "Module" -> "SourceVault_todo.wl",
          "NoDataFlow" ->
            "Deploys an EMPTY entry form / registers scheduling state only; no stored todo content flows out."|>] &,
      {"SourceVaultTodoDeployCloudForm", "SourceVaultTodoCloudSyncStart",
       "SourceVaultTodoCloudSyncStop", "SourceVaultTodoCloudSyncStatus",
       "SourceVaultTodoRebuildIndex", "SourceVaultNewTodoTemplate",
       (* settings controls: they render only a todo own SETTINGS (status,
          deadline, cycle, importance, privacy level) and no stored todo text,
          summary or notebook content, so nothing classified flows through *)
       "SourceVaultTodoEditPanel", "SourceVaultTodoEditWindow",
       "SourceVaultTodoPass", "SourceVaultTodoSetDeadline",
       "SourceVaultTodoSetPriority", "SourceVaultTodoSetPrivacyLevel"}]],
  Null];

End[];

EndPackage[];
