(* :Title: SourceVault_seriesview.wl *)
(* :Context: SourceVault` *)
(* :Summary: Views of SourceVault_series.wl (front end only; document 04 section 11.9 core / view separation, document 15).
     SourceVaultMailTaskProposalsView -- the proposed-task list: every mail matter with its work state, the series it belongs
       to, the earlier occurrences and how they were handled, a suggested handling, and the owner's buttons.
     SourceVaultSeriesCandidatesView  -- the series candidates found in the mail index (04 section 4.3).
     SourceVaultBusinessView          -- the larger businesses (business -> academic year -> steps): the confirmed ones and
       the candidates; for one business its tree, last year's steps against this year's.
   The views only draw what the core functions return. The buttons call the owner functions of the core (work ledger) and
   the existing mailagenda functions; nothing is sent, submitted or published from here.
   What is shown: titles, senders, dates, states. A mail body opens only on a click, in the existing mail window.
   The source is ASCII only. It is GENERATED: edit the UTF-8 draft test codes/_series_drafts/SourceVault_seriesview_draft.wl
   and convert it (python -I "test codes/_llmdefense_handoff_20261114/to_ascii_wl.py" <draft> SourceVault_seriesview.wl);
   a direct edit of this file is lost at the next conversion. *)

BeginPackage["SourceVault`"];

SourceVaultMailTaskProposalsView::usage =
  "SourceVaultMailTaskProposalsView[opts] \:306f\:3001\:30e1\:30fc\:30eb\:3092\:8d77\:70b9\:306b\:3057\:305f\:63d0\:6848\:30bf\:30b9\:30af\:306e\:4e00\:89a7\:3092\:8868\:793a\:3059\:308b\:3002\:884c\:306f 1 \:4ef6\:306e\:7528\:4ef6 (\:4f5c\:696d\:9805\:76ee) \:3067\:3001\:696d\:52d9\:306e\:72b6\:614b \
(\:63d0\:6848\:4e2d\:30fb\:518d\:63d0\:6848\:30fb\:51e6\:7406\:4e2d (\:672c\:4eba / LLM)\:30fb\:4fdd\:7559\:30fb\:51e6\:7406\:6e08\:307f\:30fb\:5374\:4e0b\:30fb\:5bfe\:5fdc\:4e0d\:8981\:30fb\:672a\:5224\:5b9a)\:3001\:3006\:5207\:3001\:5b9a\:578b\:696d\:52d9\:306e\:7cfb\:5217\:3068\:904e\:53bb\:306e\:56de (\:524d\:56de\:306e\:5bfe\:5fdc\:3064\:304d)\:3001\:5bfe\:5fdc\:306e\:6848\:3001\
\:64cd\:4f5c\:306e\:30dc\:30bf\:30f3 (\:8fd4\:4fe1 / \:30ce\:30fc\:30c8 / Todo / \:4fdd\:7559 / \:5374\:4e0b / \:6e08 / \:623b\:3059) \:3092\:6301\:3064\:3002\:4e0a\:306e\:5207\:308a\:66ff\:3048\:3067\:300c\:672a\:51e6\:7406\:300d\:300c\:672a\:53cd\:6620\:300d\:300c\:51e6\:7406\:6e08\:307f\:300d\:306a\:3069\:306b\:7d5e\:308b\:3002\
\:5148\:982d\:306e\:4ef6\:6570\:306f\:5168\:72b6\:614b\:306e\:5408\:8a08\:3067\:3001\:3069\:306e\:30e1\:30fc\:30eb\:3082\:6570\:304b\:3089\:6f0f\:308c\:306a\:3044\:3002Options: \"Filter\" (\:65e2\:5b9a \"Open\")\:3001\"Window\" (\:65e5\:6570)\:3001\"MBox\"\:3001\"MaxPrivacyLevel\"\:3002";

SourceVaultSeriesCandidatesView::usage =
  "SourceVaultSeriesCandidatesView[opts] \:306f\:3001\:30e1\:30fc\:30eb\:306e\:7d22\:5f15\:304b\:3089\:898b\:3064\:3051\:305f\:5b9a\:578b\:696d\:52d9\:306e\:7cfb\:5217\:306e\:5019\:88dc\:3092\:8868\:793a\:3059\:308b (\:540d\:524d\:30fb\:5468\:671f\:30fb\:56de\:6570\:30fb\:5404\:56de\:306e\:65e5\:4ed8\:30fb\:6b21\:56de\:306e\:4e88\:6e2c)\:3002\
\:4ef6\:540d\:306f\:9055\:3063\:3066\:3082\:4ef6\:540d\:3068\:6982\:8981\:306e\:5185\:5bb9\:304c\:8fd1\:3044\:3082\:306e\:306f 1 \:3064\:306e\:7cfb\:5217\:306b\:307e\:3068\:3081\:3066\:51fa\:3059\:3002\:884c\:3092\:958b\:304f\:3068\:3001\:4ef6\:540d\:306e\:578b (\:81ea\:52d5\:3067\:52a0\:308f\:3063\:305f\:672a\:78ba\:8a8d\:306e\:3082\:306e\:306f [\:3053\:306e\:578b\:3092\:5916\:3059])\:3001\:5404\:56de ([\:5916\:3059] \:3067\:305d\:306e\:30e1\:30fc\:30eb\:3060\:3051\:5916\:3059)\:3001\
\:5185\:5bb9\:306e\:8fd1\:3044\:5225\:306e\:7cfb\:5217 ([\:7d71\:5408\:3059\:308b]) \:304c\:51fa\:308b\:3002[\:7cfb\:5217\:306b\:3059\:308b] \:3067\:78ba\:5b9a\:3001[\:5374\:4e0b] \:3067\:4ee5\:5f8c\:306e\:63d0\:6848\:304b\:3089\:5916\:3059\:3002Options: \"IncludeNotifications\" (\:65e2\:5b9a False)\:3001\"MaxPrivacyLevel\"\:3002";

SourceVaultSeriesRelatedFilesRefresh::usage =
  "SourceVaultSeriesRelatedFilesRefresh[nb] / [nb, recordId] \:306f\:3001\:30bf\:30b9\:30af\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:300c\:95a2\:9023\:30d5\:30a1\:30a4\:30eb\:300d\:306e\:90e8\:5206\:3092\:4f5c\:308a\:76f4\:3059\:3002nb \:306f NotebookObject \:304b\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:30d1\:30b9\:3002\
SourceVaultSeriesRelatedFiles \:3067 $onWork \:3068 Eagle (ScanSnap) \:3092\:63a2\:3057\:76f4\:3057\:3001\:524d\:306e\:300c\:95a2\:9023\:30d5\:30a1\:30a4\:30eb\:300d\:306e\:30bb\:30eb (CellTags SVSeriesRelatedFiles) \:3092\:5916\:3057\:3066\:65b0\:3057\:3044\:3082\:306e\:3092\:672b\:5c3e\:306b\:66f8\:304f\:3002\
\:958b\:3044\:3066\:3044\:308b\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306f FE \:3092\:901a\:3057\:3066\:66f8\:304d\:63db\:3048\:3001\:958b\:3044\:3066\:3044\:306a\:3044\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306f\:30d5\:30a1\:30a4\:30eb\:3092\:66f8\:304d\:63db\:3048\:308b\:3002recordId \:3092\:7701\:304f\:3068\:3001\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:72b6\:614b\:30bb\:30eb\:306e MailRecordId \:3092\:4f7f\:3046\:3002\
\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:4e2d\:306e [\:95a2\:9023\:30d5\:30a1\:30a4\:30eb\:3092\:66f4\:65b0] \:304c\:3053\:308c\:3092\:547c\:3076\:3002\:6240\:6709\:8005\:306e\:64cd\:4f5c\:3002\:8fd4\:308a\:5024\:306f <|\"Status\", \"RecordId\", \"Count\", \"Groups\", \"Notes\", \"Where\"|>\:3002";

SourceVaultBusinessView::usage =
  "SourceVaultBusinessView[] \:306f\:3001\:4e0a\:4f4d\:306e\:696d\:52d9 (\:4ef6\:540d\:306e\:9055\:3046\:591a\:304f\:306e\:30e1\:30fc\:30eb\:304c 1 \:5e74\:3092\:901a\:3057\:3066\:5c5e\:3059\:308b\:5b9a\:578b\:696d\:52d9) \:306e\:4e00\:89a7\:3092\:8868\:793a\:3059\:308b: \:6240\:6709\:8005\:304c\:78ba\:5b9a\:3057\:305f\:696d\:52d9\:3068\:3001\:6700\:8fd1\:306e\:30e1\:30fc\:30eb\:306e\:4ef6\:540d\:304b\:3089\:8aad\:3093\:3060\:5019\:88dc\:3002\
[\:696d\:52d9\:3068\:3057\:3066\:78ba\:5b9a] \:3067\:78ba\:5b9a\:3001[\:696d\:52d9\:3067\:306f\:306a\:3044] \:3067\:4ee5\:5f8c\:306e\:5019\:88dc\:304b\:3089\:5916\:3059\:3002[\:6728\:3092\:958b\:304f] \:306f 1 \:3064\:306e\:696d\:52d9\:306e\:6728\:3092\:5225\:306e\:7a93\:306b\:958b\:304f\:3002\n\
SourceVaultBusinessView[nameOrId, opts] \:306f 1 \:3064\:306e\:696d\:52d9\:306e\:6728\:3092\:8868\:793a\:3059\:308b: \:6628\:5e74\:5ea6\:306e\:6bb5\:968e (\:30e1\:30fc\:30eb\:306e 1 \:56de\:5206) \:3092\:65e5\:4ed8\:9806\:306b\:4e26\:3079\:3001\:305d\:306e\:53f3\:306b\:4eca\:5e74\:5ea6\:306e\:5bfe\:5fdc\:3059\:308b\:30e1\:30fc\:30eb (\:72b6\:614b\:3064\:304d)\:3001\
\:307e\:3060\:306a\:3089\:300c\:3053\:308c\:304b\:3089 (\:6628\:5e74\:306f MM/DD)\:300d\:304b\:300c\:4eca\:5e74\:5ea6\:306f\:307e\:3060\:5c4a\:3044\:3066\:3044\:307e\:305b\:3093\:300d\:3092\:51fa\:3059\:3002\:7d9a\:3044\:3066\:4eca\:5e74\:5ea6\:3060\:3051\:306e\:6bb5\:968e\:3001\:904e\:53bb\:306e\:5e74\:5ea6\:3002\:30e1\:30fc\:30eb\:306f [\:5916\:3059] \:3067\:696d\:52d9\:304b\:3089\:5916\:305b\:3001\:9664\:304f\:8a9e\:3092\:8db3\:305b\:308b\:3002\
\:78ba\:5b9a\:3057\:3066\:3044\:306a\:3044\:540d\:524d\:3067\:3082\:3001\:305d\:306e\:8a9e\:3092\:4ef6\:540d\:306b\:542b\:3080\:30e1\:30fc\:30eb\:3067\:540c\:3058\:6728\:3092\:898b\:3089\:308c\:308b (\"Match\" \:3067\:691c\:7d22\:306e\:8a9e\:3092\:6307\:5b9a)\:3002";

ShowRoutineWorkPalette::usage =
  "ShowRoutineWorkPalette[] \:306f\:3001\:30e1\:30fc\:30eb\:3092\:8d77\:70b9\:306b\:3057\:305f\:5b9a\:578b\:696d\:52d9\:306e\:6a5f\:80fd (\:6587\:66f8 15) \:3092\:4e26\:3079\:305f\:6d6e\:52d5\:30d1\:30ec\:30c3\:30c8\:3092\:958b\:304f (ShowClaudePalette / ShowSystemDoctorPalette \:3068\:540c\:3058\:5f62)\:3002\
\:4e00\:89a7 (\:63d0\:6848\:30bf\:30b9\:30af\:30fb\:4e88\:5b9a\:30fb\:7cfb\:5217\:306e\:5019\:88dc\:30fb\:4e0a\:4f4d\:306e\:696d\:52d9)\:3001\:30e1\:30fc\:30eb\:306e\:4e00\:89a7 (\:696d\:52d9\:306b\:672a\:53cd\:6620\:30fb\:672a\:51e6\:7406)\:3001\:696d\:52d9\:306e\:6728\:3092\:958b\:304f\:30fb\:696d\:52d9\:3092\:78ba\:5b9a\:3059\:308b\:3001\:3044\:307e\:4f7f\:3063\:3066\:3044\:308b\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:95a2\:9023 (\:4e0a\:4f4d\:306e\:696d\:52d9\:30fb\:95a2\:9023\:30d5\:30a1\:30a4\:30eb) \:306e\:66f8\:304d\:76f4\:3057\:3001\
\:30ed\:30fc\:30ab\:30eb\:306e\:30e2\:30c7\:30eb\:306b\:3088\:308b\:6bd4\:8f03\:3068\:30e9\:30d9\:30eb\:306e\:66f4\:65b0\:3001\:72b6\:614b\:30fb\:53f0\:5e33\:30fb\:4f7f\:3044\:65b9\:306e\:7a93\:3002\:30d1\:30ec\:30c3\:30c8\:81ea\:8eab\:306f\:8a08\:7b97\:3092\:305b\:305a\:3001\:30dc\:30bf\:30f3\:3092\:62bc\:3057\:305f\:3068\:304d\:3060\:3051\:8a08\:7b97\:3059\:308b\:3002\:4e00\:89a7\:306f\:5225\:306e\:7a93\:306b\:958b\:304d\:3001\:540c\:3058\:30dc\:30bf\:30f3\:3092\:3082\:3046\:4e00\:5ea6\:62bc\:3059\:3068\:4f5c\:308a\:76f4\:3059\:3002\
\:30e1\:30cb\:30e5\:30fc\:306e \:30d1\:30ec\:30c3\:30c8 > Routine Work \:304b\:3089\:3082\:958b\:3051\:308b\:3002";

Begin["`SeriesViewPrivate`"];

(* ---------------- the data of a view is computed OUTSIDE Dynamic ----------------
   The front end cuts a Dynamic off after a few seconds (DynamicEvaluationTimeout) and shows $Aborted. On a real mail store
   the lists take longer than that (owner, 2026-11-16: the candidates view showed $Aborted). So:
     - the data is computed by the main evaluation (the view function) and by the buttons, which are queued and are not cut off;
     - it is kept in $iSVSVStore under the id of the view (its kind and its options);
     - the Dynamic of a view only draws what the store holds. When the store holds nothing for it (a restarted kernel) or
       something older than the last owner action, the view says so and offers a button; it never computes.
   $iSVSVTick is the version of the data: every owner action raises it. $iSVSVDraw only asks for a redraw. *)
If[! IntegerQ[$iSVSVTick], $iSVSVTick = 0];
If[! IntegerQ[$iSVSVDraw], $iSVSVDraw = 0];
If[! AssociationQ[$iSVSVStore], $iSVSVStore = <||>];
$iSVSVStoreMax = 6;     (* views kept (the newest) *)
$iSVSVMaxRows = 200;    (* rows drawn in one list; the rest is counted in a note *)
$iSVSVMaxOccLines = 12; (* occurrences drawn inside one series (the latest) *)
$iSVSVViewNow = None;   (* the id of the view being drawn (the buttons made meanwhile remember it) *)
$iSVSVFrom = None;      (* the id of the view whose button is running *)

iSVSVViewId[kind_String, o_List] := kind <> "-" <> IntegerString[Hash[{kind, o}], 36];

iSVSVCompute["Series", o_List] := Block[{SourceVault`SeriesPrivate`$iSVSRNoExit = True},
  SourceVault`SourceVaultSeriesDiscover[Sequence @@ o]];
(* the proposed-task list: the open matters with their related data, and every matter (counts, closed lists). The two
   calls share one evaluation of the states; every filter of the view is a selection from these. *)
iSVSVCompute["Items", o_List] := Block[{SourceVault`SeriesPrivate`$iSVSRNoExit = True},
  <|"Open" -> SourceVault`SourceVaultMailTaskProposals["States" -> "Open", Sequence @@ o],
    "All" -> SourceVault`SourceVaultMailWorkItems["States" -> All, Sequence @@ o]|>];

(* the larger businesses: the confirmed ones and the candidates; and the tree of one business (its name is "Ref") *)
iSVSVCompute["Businesses", o_List] := Block[{SourceVault`SeriesPrivate`$iSVSRNoExit = True},
  SourceVault`SourceVaultBusinessDiscover[Sequence @@ DeleteCases[o, ("Ref" | "Match") -> _]]];
iSVSVCompute["Business", o_List] := Block[{SourceVault`SeriesPrivate`$iSVSRNoExit = True},
  With[{ref = First[Cases[o, ("Ref" -> r_String) :> r, {1}, 1], ""]},
    SourceVault`SourceVaultBusinessInfo[ref, Sequence @@ DeleteCases[o, "Ref" -> _]]]];

iSVSVPut[kind_String, o_List, data_, tick_Integer, secs_] := Module[{id = iSVSVViewId[kind, o]},
  $iSVSVStore[id] = <|"Kind" -> kind, "Opts" -> o, "Data" -> data, "Tick" -> tick, "At" -> AbsoluteTime[], "Seconds" -> secs|>;
  If[Length[$iSVSVStore] > $iSVSVStoreMax,
    $iSVSVStore = KeyTake[$iSVSVStore, Keys[TakeLargestBy[$iSVSVStore, #["At"] &, $iSVSVStoreMax]]]];
  id];
iSVSVLoad[kind_String, o_List] := Module[{t0 = AbsoluteTime[], data},
  data = iSVSVCompute[kind, o];
  iSVSVPut[kind, o, data, $iSVSVTick, AbsoluteTime[] - t0]];
(* bring one view up to date (its own button); the data did not change, so the other views stay as they are *)
iSVSVReload[kind_String, o_List] := (iSVSVLoad[kind, o]; $iSVSVDraw++;);

(* after an owner action the data has changed. The view the action came from is computed again right here (inside the
   queued button); the other views are then older than the tick and say so. *)
iSVSVRefresh[] := Module[{from = $iSVSVFrom, e, t0, data},
  e = If[StringQ[from], Lookup[$iSVSVStore, from, Missing[]], Missing[]];
  If[AssociationQ[e],
    t0 = AbsoluteTime[];
    (* the action changed the ledger, not the mails: the structure built from the mail index may be reused for longer here
       (a new evaluation of the view, or its update button, reads the index afresh after the usual time) *)
    data = Block[{SourceVault`SeriesPrivate`$iSVSRStructTTL = 900.}, iSVSVCompute[e["Kind"], e["Opts"]]];
    $iSVSVStore[from] = Join[e, <|"Data" -> data, "Tick" -> $iSVSVTick + 1, "At" -> AbsoluteTime[], "Seconds" -> AbsoluteTime[] - t0|>]];
  $iSVSVTick++;];

(* ---------------- labels ---------------- *)

$iSVSVFilters = {"Open" -> "\:672a\:51e6\:7406", "Untracked" -> "\:672a\:53cd\:6620 (\:63d0\:6848\:30fb\:672a\:5224\:5b9a)", "InProgress" -> "\:51e6\:7406\:4e2d", "Pending" -> "\:4fdd\:7559",
  "Done" -> "\:51e6\:7406\:6e08\:307f", "Rejected" -> "\:5374\:4e0b", "NoAction" -> "\:5bfe\:5fdc\:4e0d\:8981", All -> "\:3059\:3079\:3066"};

$iSVSVUnit = <|"Month" -> "\:6708\:6b21", "Quarter" -> "\:56db\:534a\:671f", "Term" -> "\:5b66\:671f", "Year" -> "\:5e74\:6b21", "Frequent" -> "\:983b\:7e41", "Irregular" -> "\:4e0d\:5b9a\:671f", "Single" -> "\:5358\:767a"|>;

$iSVSVReason = <|"Category:TaskRequest" -> "\:5206\:985e: \:4f5c\:696d\:306e\:4f9d\:983c", "Category:AttendanceRequest" -> "\:5206\:985e: \:51fa\:5e2d\:306e\:4f9d\:983c",
  "Category:Confirmation" -> "\:5206\:985e: \:78ba\:8a8d\:306e\:4f9d\:983c", "Deadline" -> "\:3006\:5207\:304c\:3042\:308b", "SubjectCue" -> "\:4ef6\:540d\:306b\:4f9d\:983c\:306e\:8a9e\:304c\:3042\:308b",
  "DirectTo" -> "\:5b9b\:5148\:304c\:672c\:4eba", "OrgTo" -> "\:5b9b\:5148\:304c\:6240\:5c5e\:306e\:5b9b\:5148", "SeriesHandledBefore" -> "\:540c\:3058\:696d\:52d9\:306e\:524d\:56de\:306b\:5bfe\:5fdc\:3057\:3066\:3044\:308b",
  "SeriesConfirmed" -> "\:78ba\:5b9a\:3057\:305f\:7cfb\:5217 (\:5b9a\:578b\:696d\:52d9) \:306e\:65b0\:7740", "BusinessConfirmed" -> "\:78ba\:5b9a\:3057\:305f\:696d\:52d9\:306e\:65b0\:7740", "LowPriority" -> "\:91cd\:8981\:5ea6\:304c\:4f4e\:3044", "Auto" -> "\:81ea\:52d5\:306e\:5224\:5b9a", "Unclassified" -> "\:5206\:985e\:304c\:307e\:3060\:7121\:3044", "OwnerMarked" -> "\:6240\:6709\:8005\:306e\:6307\:5b9a",
  "NewMailAfterReject" -> "\:5374\:4e0b\:306e\:5f8c\:306b\:65b0\:3057\:3044\:30e1\:30fc\:30eb\:304c\:5c4a\:3044\:305f", "DeadlineNear" -> "\:3006\:5207\:304c\:8fd1\:3044", "DeferExpired" -> "\:4fdd\:7559\:306e\:671f\:9650\:304c\:6765\:305f",
  "NewMailAfterDefer" -> "\:4fdd\:7559\:306e\:5f8c\:306b\:65b0\:3057\:3044\:30e1\:30fc\:30eb\:304c\:5c4a\:3044\:305f", "Replied" -> "\:8fd4\:4fe1\:6e08\:307f", "Dismissed" -> "\:78ba\:8a8d\:306e\:307f\:30fb\:5bfe\:5fdc\:6e08\:307f",
  "MarkedDone" -> "\:51e6\:7406\:6e08\:307f\:306b\:3057\:305f", "NotebookDone" -> "\:4f5c\:696d\:30ce\:30fc\:30c8\:304c\:5b8c\:4e86", "TodoDone" -> "Todo \:304c\:5b8c\:4e86", "Notebook" -> "\:4f5c\:696d\:30ce\:30fc\:30c8\:3067\:9032\:884c\:4e2d",
  "Todo" -> "Todo \:3067\:9032\:884c\:4e2d", "TodoPass" -> "Todo \:3092\:898b\:9001\:308a\:4e2d", "LLM" -> "LLM \:304c\:51e6\:7406\:4e2d", "Accepted:Reply" -> "\:8fd4\:4fe1\:3092\:6e96\:5099\:4e2d",
  "Accepted:Manual" -> "\:7740\:624b\:6e08\:307f", "Accepted:Notebook" -> "\:4f5c\:696d\:30ce\:30fc\:30c8\:3067\:9032\:884c\:4e2d", "Accepted:Todo" -> "Todo \:3067\:9032\:884c\:4e2d",
  "Deferred" -> "\:4fdd\:7559\:4e2d", "OutboundOnly" -> "\:81ea\:5206\:304c\:51fa\:3057\:305f\:30e1\:30fc\:30eb\:3060\:3051", "OwnerRejected" -> "\:6240\:6709\:8005\:304c\:5374\:4e0b"|>;

$iSVSVAction = <|"Reply" -> "\:8fd4\:4fe1", "Notebook" -> "\:30ce\:30fc\:30c8", "Todo" -> "Todo", "Confirm" -> "\:78ba\:8a8d\:306e\:307f"|>;
$iSVSVBasis = <|"SameAsLast" -> "\:524d\:56de\:3068\:540c\:3058", "BusinessLastYear" -> "\:6628\:5e74\:5ea6\:306e\:540c\:3058\:6bb5\:968e\:3068\:540c\:3058", "Category" -> "\:5206\:985e\:304b\:3089"|>;
$iSVSVHandling = <|"Replied" -> "\:8fd4\:4fe1", "Notebook" -> "\:30ce\:30fc\:30c8\:30d6\:30c3\:30af", "Todo" -> "Todo", "MarkedDone" -> "\:51e6\:7406\:6e08\:307f\:306b\:3057\:305f",
  "Dismissed" -> "\:78ba\:8a8d\:306e\:307f", "Rejected" -> "\:5374\:4e0b", "None" -> "\:8a18\:9332\:306a\:3057"|>;

(* ---------------- small pieces ---------------- *)

$iSVSVWeek = {"\:6708", "\:706b", "\:6c34", "\:6728", "\:91d1", "\:571f", "\:65e5"};
iSVSVWeekday[a_?NumberQ] := $iSVSVWeek[[Mod[Floor[a/86400.], 7] + 1]];
iSVSVDateTime[a_?NumberQ] := DateString[a, {"Month", "/", "Day"}] <> "(" <> iSVSVWeekday[a] <> ") " <> DateString[a, {"Hour24", ":", "Minute"}];
iSVSVDateTime[_] := "-";
iSVSVDay[a_?NumberQ] := DateString[a, {"Year", "/", "Month", "/", "Day"}];
iSVSVDay[_] := "-";
iSVSVShortDay[a_?NumberQ] := DateString[a, {"Month", "/", "Day"}] <> "(" <> iSVSVWeekday[a] <> ")";

iSVSVClip[s_String, n_Integer] := If[StringLength[s] > n, StringTake[s, n - 1] <> "\:2026", s];
iSVSVClip[s_, n_] := iSVSVClip[ToString[s], n];
iSVSVSender[from_] := iSVSVClip[StringTrim[StringReplace[ToString[from], RegularExpression["\\s*<[^>]*>"] -> ""], ("\"" | " ") ...], 14];

iSVSVDueAbs[d_] := Quiet @ Check[SourceVault`SeriesPrivate`iSVSRDueAbs[d], Missing[]];
iSVSVNow[] := Quiet @ Check[SourceVault`SeriesPrivate`iSVSRNow[], AbsoluteTime[]];

(* deadline colour: past red, today / tomorrow blue, later black (the rule of the agenda view) *)
iSVSVDeadlineCell[d_] := Module[{a = iSVSVDueAbs[d], now = iSVSVNow[]},
  If[! NumberQ[a], Return[""]];
  Style[iSVSVShortDay[a], Which[a < now, Red, a - now <= 2*86400., Blue, True, Black], Bold]];

iSVSVStateColor[st_] := Lookup[SourceVault`SeriesPrivate`$iSVSRStateColors, st, GrayLevel[0.6]];
iSVSVStateBadge[it_Association] := Tooltip[
  Framed[Style[SourceVault`SeriesPrivate`iSVSRFullLabel[it], White, Bold, 11], Background -> iSVSVStateColor[it["State"]],
    FrameStyle -> None, RoundingRadius -> 4, FrameMargins -> {{5, 5}, {1, 1}}],
  StringRiffle[Lookup[$iSVSVReason, #, #] & /@ Select[Lookup[it, "Reasons", {}], StringQ], " / "] <>
    If[NumberQ[Lookup[it, "Until", Missing[]]], "  (" <> iSVSVDay[it["Until"]] <> " \:307e\:3067)", ""]];

(* every button is queued (not cut off by the front end) and runs with the id of the view it was drawn in *)
iSVSVBtn[label_, action_, emphasize_ : False] := With[{from = $iSVSVViewNow},
  Button[Style[label, 11, If[TrueQ[emphasize], Bold, Plain]],
    Block[{SourceVault`SeriesViewPrivate`$iSVSVFrom = from}, action],
    Method -> "Queued", ImageSize -> Automatic, FrameMargins -> 3,
    Background -> If[TrueQ[emphasize], RGBColor[0.82, 0.9, 1.], Automatic]]];
SetAttributes[iSVSVBtn, HoldRest];
iSVSVVia[from_, action_] := Block[{SourceVault`SeriesViewPrivate`$iSVSVFrom = from}, action];
SetAttributes[iSVSVVia, HoldRest];

(* ---------------- actions (the buttons carry literal strings only) ---------------- *)

iSVSVReport[res_] := If[AssociationQ[res] && Lookup[res, "Status", ""] =!= "OK" && TrueQ[$Notebooks],
  Quiet @ MessageDialog[Column[{Style["\:64cd\:4f5c\:3092\:8a18\:9332\:3067\:304d\:307e\:305b\:3093\:3067\:3057\:305f", Bold],
    ToString[Lookup[res, "Reason", ""]], ToString[Lookup[res, "Hint", ""]]}]]];

iSVSVDo[rid_String, via : ("Reply" | "Notebook" | "Todo" | "Manual"), o_List] := (
  iSVSVReport[SourceVault`SourceVaultMailWorkAccept[rid, via, Sequence @@ o]]; iSVSVRefresh[]);
iSVSVDo[rid_String, {"Defer", days_?NumberQ}, o_List] := (
  iSVSVReport[SourceVault`SourceVaultMailWorkAct[rid, "Defer", "Until" -> days, Sequence @@ o]]; iSVSVRefresh[]);
iSVSVDo[rid_String, a : ("Reject" | "Done" | "Reopen" | "Propose" | "NoAction" | "Seen"), o_List] := (
  iSVSVReport[SourceVault`SourceVaultMailWorkAct[rid, a, Sequence @@ o]]; iSVSVRefresh[]);
iSVSVDo[sid_String, a : ("SeriesConfirm" | "SeriesReject"), _] := (
  iSVSVReport[If[a === "SeriesConfirm", SourceVault`SourceVaultSeriesConfirm[sid], SourceVault`SourceVaultSeriesReject[sid]]];
  iSVSVRefresh[]);
(* a series with several title patterns: confirm (and keep together) / reject all of them, or join two series *)
iSVSVDo[sids : {__String}, a : ("SeriesConfirm" | "SeriesReject" | "SeriesMerge"), _] := (
  iSVSVReport[Switch[a, "SeriesConfirm", SourceVault`SourceVaultSeriesConfirm[sids],
    "SeriesReject", SourceVault`SourceVaultSeriesReject[sids], _, SourceVault`SourceVaultSeriesMerge[sids]]];
  iSVSVRefresh[]);
iSVSVDo[sid_String, "SeriesDetach", _] := (iSVSVReport[SourceVault`SourceVaultSeriesDetach[sid]]; iSVSVRefresh[]);
iSVSVDo[rid_String, {"SeriesAddMail", sid_String}, o_List] := (
  iSVSVReport[SourceVault`SourceVaultSeriesAddMail[sid, rid, Sequence @@ o]]; iSVSVRefresh[]);
iSVSVDo[rid_String, "SeriesRemoveMail", o_List] := (
  iSVSVReport[SourceVault`SourceVaultSeriesRemoveMail[rid, Sequence @@ o]]; iSVSVRefresh[]);

(* the larger business: confirm / reject a name, take a mail out, add a word that excludes titles *)
iSVSVDo[name_String, {"BusinessConfirm", match_}, _] := (
  iSVSVReport[SourceVault`SourceVaultBusinessConfirm[name, "Match" -> match]]; iSVSVRefresh[]);
iSVSVDo[name_String, {"BusinessReject", match_}, _] := (
  iSVSVReport[SourceVault`SourceVaultBusinessReject[name, "Match" -> match]]; iSVSVRefresh[]);
iSVSVDo[rid_String, {"BusinessRemoveMail", biz_String}, o_List] := (
  iSVSVReport[SourceVault`SourceVaultBusinessRemoveMail[biz, rid, Sequence @@ o]]; iSVSVRefresh[]);
iSVSVDo[biz_String, {"BusinessExclude", words_List}, _] := (
  iSVSVReport[SourceVault`SourceVaultBusinessConfirm[biz, "Exclude" -> DeleteDuplicates[Select[StringTrim /@ Select[words, StringQ], # =!= "" &]]]];
  iSVSVRefresh[]);
iSVSVOpenBusiness[name_String, match_] := iSVSPTreeFrom[<|"Name" -> name, "Match" -> If[StringQ[match], match, ""]|>];

iSVSVOpenMail[rid_String] := Which[
  Length[DownValues[SourceVault`SourceVaultMailAgendaOpen]] > 0, SourceVault`SourceVaultMailAgendaOpen[rid],
  Length[DownValues[SourceVault`SourceVaultMailShowBody]] > 0, SourceVault`SourceVaultMailShowBody[rid],
  True, Null];
iSVSVOpenPath[path_String] := If[FileExistsQ[path], SystemOpen[path],
  If[TrueQ[$Notebooks], Quiet @ MessageDialog["\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:304c\:898b\:3064\:304b\:308a\:307e\:305b\:3093: " <> path]]];
iSVSVOpenTodo[id_String] := If[Names["SourceVault`SourceVaultTodoShowSummary"] =!= {},
  Symbol[Identity["SourceVault`SourceVaultTodoShowSummary"]][id]];

(* ---------------- cells of one row ---------------- *)

iSVSVSubjectCell[it_Association] := Row[{
  Tooltip[Button[Style[iSVSVClip[it["Subject"], 34], 12, RGBColor[0.05, 0.25, 0.6]], iSVSVOpenMail[it["RecordId"]],
      Appearance -> "Frameless", Method -> "Queued", BaseStyle -> {}],
    With[{sm = Lookup[it, "Summary", ""]}, If[StringQ[sm] && sm =!= "", sm, ToString[it["Subject"]]]]],
  If[Lookup[it, "MailCount", 1] > 1, Style["  (" <> ToString[it["MailCount"]] <> " \:901a)", 10, Gray], ""]}];

iSVSVHandlingText[h_] := If[! AssociationQ[h], "\:8a18\:9332\:306a\:3057",
  Lookup[$iSVSVHandling, h["Kind"], "\:8a18\:9332\:306a\:3057"] <>
    If[NumberQ[Lookup[h, "LagDays", Missing[]]], " (" <> ToString[NumberForm[N[h["LagDays"]], {4, 1}]] <> " \:65e5\:5f8c)", ""]];

iSVSVPrevLine[p_Association] := Row[{
  Style[ToString[p["Key"]], Bold, 11], "  ", Style[iSVSVDay[p["Date"]], 11], "  ",
  Style[iSVSVClip[p["Subject"], 30], 11], "  ", Style["\:5bfe\:5fdc: " <> iSVSVHandlingText[p["Handling"]], 11, Darker[Green]], "  ",
  With[{rid = p["RecordId"]}, iSVSVBtn["\:2709", iSVSVOpenMail[rid]]],
  If[StringQ[Lookup[p["Handling"], "NotebookPath", Missing[]]],
    With[{path = p["Handling"]["NotebookPath"]}, iSVSVBtn["\|01f4d3", iSVSVOpenPath[path]]], ""]}];

iSVSVSeriesCell[it_Association, o_List] := Module[{series = Lookup[it, "Series", Missing[]], prev = Lookup[it, "Previous", {}],
    nbs = Lookup[it, "Notebooks", {}], sim = Lookup[it, "Similar", {}], rid = it["RecordId"], head, body = {}, proposed,
    biz = Lookup[it, "Business", Missing[]], cpart = Lookup[it, "Counterpart", Missing[]]},
  If[! KeyExistsQ[it, "Plan"],   (* a closed list: no related data was computed *)
    Return[Style[If[Lookup[it, "WorkKind", "OneOff"] === "Recurring",
      "\:540c\:7a2e\:306e\:30e1\:30fc\:30eb " <> ToString[Lookup[it, "SeriesCount", 1]] <> " \:56de", "\:5358\:767a"], 11, Gray]]];
  proposed = Lookup[it, "MatchStatus", ""] === "Proposed";
  head = Which[
    AssociationQ[series] && TrueQ[series["Periodic"]],
      Row[{Style["\:5b9a\:578b", Bold, 11, RGBColor[0.5, 0.2, 0.6]],
        Style[" (" <> Lookup[$iSVSVUnit, series["Unit"], "?"] <> ") " <> ToString[Lookup[it, "OccurrenceKey", ""]] <>
          " \:30fb\:904e\:53bb " <> ToString[Lookup[it, "PreviousCount", 0]] <> " \:56de", 11],
        If[proposed, Style["  \:672a\:78ba\:8a8d", 10, Orange], ""]}],
    AssociationQ[series],
      Row[{Style["\:540c\:7a2e\:306e\:30e1\:30fc\:30eb \:30fb\:904e\:53bb " <> ToString[Lookup[it, "PreviousCount", 0]] <> " \:56de (\:5468\:671f\:306a\:3057)", 11],
        If[proposed, Style["  \:672a\:78ba\:8a8d", 10, Orange], ""]}],
    (* a title that names no matter: said, so that the owner sees why nothing of the title's history is shown *)
    TrueQ[Lookup[it, "GenericTitle", False]], Style["\:5358\:767a (\:540c\:5831\:306e\:4ef6\:540d: \:4ef6\:540d\:3067\:306f\:7cfb\:5217\:306b\:3057\:307e\:305b\:3093)", 11, Gray],
    True, Style["\:5358\:767a", 11, Gray]];
  body = iSVSVPrevLine /@ prev;
  (* the larger business the owner confirmed, and the step of last year's run that this mail corresponds to *)
  If[AssociationQ[biz],
    head = Column[{Style["\:25a3 " <> iSVSVClip[biz["Name"], 24], Bold, 11, RGBColor[0.1, 0.35, 0.6]], head}, Spacings -> 0.1];
    If[AssociationQ[cpart], PrependTo[body, Row[{Style["\:6628\:5e74\:5ea6\:306e\:5bfe\:5fdc\:3059\:308b\:6bb5\:968e  ", 10, Gray], iSVSVPrevLine[cpart]}]]]];
  (* the series can be corrected from here: confirm it, or take this mail out of it *)
  If[AssociationQ[series],
    With[{mids = Lookup[series, "MemberIds", {series["SeriesId"]}], r = rid, oo = o},
      AppendTo[body, Row[{
        Style[If[proposed, "\:3053\:306e\:4ef6\:540d\:306e\:578b\:306f\:672a\:78ba\:8a8d\:3067\:3059 (\:81ea\:52d5\:3067\:7cfb\:5217\:306b\:5165\:308a\:307e\:3057\:305f)\:3002 ", "\:7cfb\:5217\:306e\:64cd\:4f5c: "], 10, Gray],
        If[proposed, iSVSVBtn["\:7cfb\:5217\:3068\:3057\:3066\:78ba\:5b9a", iSVSVDo[mids, "SeriesConfirm", {}]], Nothing], " ",
        iSVSVBtn["\:3053\:306e\:30e1\:30fc\:30eb\:3092\:7cfb\:5217\:304b\:3089\:5916\:3059", iSVSVDo[r, "SeriesRemoveMail", oo]]}]]]];
  (* ... or put this mail into a series whose content is near *)
  If[sim =!= {},
    AppendTo[body, Row[Flatten[{Style["\:5185\:5bb9\:306e\:8fd1\:3044\:7cfb\:5217\:306b\:5165\:308c\:308b: ", 10, Gray],
      Riffle[With[{sid = #["SeriesId"], r = rid, oo = o, lbl = "\:ff0b " <> iSVSVClip[#["Name"], 22]},
          iSVSVBtn[lbl, iSVSVDo[r, {"SeriesAddMail", sid}, oo]]] & /@ sim, " "]}]]]];
  If[nbs =!= {},
    AppendTo[body, Row[Flatten[{Style["\:984c\:540d\:306e\:8fd1\:3044\:4f5c\:696d\:30ce\:30fc\:30c8 (\:672a\:78ba\:8a8d): ", 10, Gray],
      Riffle[With[{path = #["Path"], lbl = "\|01f4d3 " <> iSVSVClip[FileBaseName[#["Path"]], 22]}, iSVSVBtn[lbl, iSVSVOpenPath[path]]] & /@ nbs, " "]}]]]];
  If[body === {}, head, OpenerView[{head, Column[body, Spacings -> 0.3]}, False]]];

iSVSVPlanCell[it_Association] := Module[{plan = Lookup[it, "Plan", Missing[]], due},
  If[! AssociationQ[plan], Return[""]];
  due = Lookup[plan, "PredictedDue", Missing[]];
  Column[{
    Style["\:6848: " <> Lookup[$iSVSVAction, plan["SuggestedAction"], "-"] <> " (" <> Lookup[$iSVSVBasis, plan["Basis"], "-"] <> ")", 11],
    If[AssociationQ[due] && due["Basis"] === "LastLag",
      Style["\:76ee\:5b89 " <> iSVSVShortDay[due["At"]] <> " (\:524d\:56de\:306e\:9593\:9694)", 10, Gray], Nothing]}, Spacings -> 0.1]];

iSVSVActionsCell[it_Association, o_List] := Module[{rid = it["RecordId"], st = it["State"], sug, track = Lookup[it, "Track", <||>]},
  sug = Lookup[Lookup[it, "Plan", <||>], "SuggestedAction", ""];
  With[{r = rid, oo = o},
    Row[Riffle[Switch[st,
      "Proposed" | "Reproposed" | "Unclassified", {
        iSVSVBtn["\:8fd4\:4fe1", iSVSVDo[r, "Reply", oo], sug === "Reply"],
        iSVSVBtn["\:30ce\:30fc\:30c8", iSVSVDo[r, "Notebook", oo], sug === "Notebook"],
        iSVSVBtn["Todo", iSVSVDo[r, "Todo", oo], sug === "Todo"],
        With[{f = $iSVSVViewNow},
          ActionMenu[Style["\:4fdd\:7559", 11], {"\:660e\:65e5\:307e\:3067" :> iSVSVVia[f, iSVSVDo[r, {"Defer", 1}, oo]], "3 \:65e5" :> iSVSVVia[f, iSVSVDo[r, {"Defer", 3}, oo]],
            "1 \:9031\:9593" :> iSVSVVia[f, iSVSVDo[r, {"Defer", 7}, oo]], "2 \:9031\:9593" :> iSVSVVia[f, iSVSVDo[r, {"Defer", 14}, oo]],
            "1 \:304b\:6708" :> iSVSVVia[f, iSVSVDo[r, {"Defer", 30}, oo]]}, Method -> "Queued"]],
        iSVSVBtn["\:5374\:4e0b", iSVSVDo[r, "Reject", oo]],
        iSVSVBtn["\:6e08", iSVSVDo[r, "Done", oo], sug === "Confirm"]},
      "InProgress", {
        Which[
          Lookup[track, "Kind", None] === "Notebook" && StringQ[Lookup[track, "NotebookPath", Missing[]]],
            With[{path = track["NotebookPath"]}, iSVSVBtn["\|01f4d3 \:958b\:304f", iSVSVOpenPath[path], True]],
          Lookup[track, "Kind", None] === "Todo" && StringQ[Lookup[track, "TodoId", Missing[]]],
            With[{id = track["TodoId"]}, iSVSVBtn["\:2611 \:958b\:304f", iSVSVOpenTodo[id], True]],
          True, iSVSVBtn["\:8fd4\:4fe1", iSVSVDo[r, "Reply", oo], True]],
        (* a new mail arrived after the work started: the owner says that it has been looked at *)
        If[MemberQ[Lookup[it, "Flags", {}], "NewMailSinceTracked"], iSVSVBtn["\:65b0\:7740\:3092\:78ba\:8a8d\:6e08\:307f", iSVSVDo[r, "Seen", oo]], Nothing],
        iSVSVBtn["\:6e08", iSVSVDo[r, "Done", oo]],
        iSVSVBtn["\:623b\:3059", iSVSVDo[r, "Reopen", oo]]},
      "Pending", {iSVSVBtn["\:518d\:958b", iSVSVDo[r, "Reopen", oo], True], iSVSVBtn["\:6e08", iSVSVDo[r, "Done", oo]]},
      "NoAction", {iSVSVBtn["\:30bf\:30b9\:30af\:306b\:3059\:308b", iSVSVDo[r, "Propose", oo]]},
      _, {iSVSVBtn["\:623b\:3059", iSVSVDo[r, "Reopen", oo]]}], " "]]]];

iSVSVHeaderRow[] := Style[#, Bold, 11, GrayLevel[0.3]] & /@
  {"\:72b6\:614b", "\:53d7\:4fe1", "\:3006\:5207", "\:5dee\:51fa\:4eba", "\:4ef6\:540d", "\:696d\:52d9\:30fb\:904e\:53bb\:306e\:56de", "\:5bfe\:5fdc\:306e\:6848", "\:64cd\:4f5c"};

iSVSVItemRow[it_Association, o_List] := {
  iSVSVStateBadge[it], Style[iSVSVDateTime[it["Date"]], 11], iSVSVDeadlineCell[Lookup[it, "Deadline", Missing[]]],
  Style[iSVSVSender[it["From"]], 11], iSVSVSubjectCell[it], iSVSVSeriesCell[it, o], iSVSVPlanCell[it], iSVSVActionsCell[it, o]};

iSVSVCountsLine[data_Association] := Module[{c = Lookup[data, "Counts", <||>], lab, part},
  lab = Function[st, SourceVault`SeriesPrivate`iSVSRLabel[st] <> " " <> ToString[Lookup[c, st, 0]]];
  part = Function[sts, Row[Riffle[Style[lab[#], iSVSVStateColor[#], Bold] & /@ sts, " \:30fb "]]];
  Row[{Style["\:5168 " <> ToString[Lookup[data, "Total", 0]] <> " \:4ef6   ", Bold],
    Style["\:672a\:51e6\:7406: ", Gray], part[{"Reproposed", "Proposed", "Unclassified", "InProgress", "Pending"}],
    Style["     \:6e08\:307f: ", Gray], part[{"Done", "Rejected", "NoAction"}],
    If[Lookup[data, "HiddenByPrivacy", 0] > 0,
      Style["     (\:6a5f\:5bc6\:5ea6\:306e\:4e0a\:9650\:3067\:975e\:8868\:793a " <> ToString[data["HiddenByPrivacy"]] <> " \:4ef6)", Gray], ""]}]];

(* the body of the proposed-task list, drawn from the stored data (see the top of the file). The filter is a selection:
   the open states come from the proposals (they carry the related data), the others from the list of every matter. *)
iSVSVBody[filter_, data_Association, o_List] := Module[{states, src, items, shown, lo = iSVSVLightOpts[o]},
  states = SourceVault`SourceVaultMailWorkStatesFor[filter];
  src = If[SubsetQ[SourceVault`SeriesPrivate`$iSVSROpenStates, states], Lookup[data, "Open", Missing[]], Lookup[data, "All", Missing[]]];
  If[! AssociationQ[src], Return[Style["\:4e00\:89a7\:3092\:4f5c\:308c\:307e\:305b\:3093\:3067\:3057\:305f\:3002", Red]]];
  items = Select[Lookup[src, "Items", {}], MemberQ[states, #["State"]] &];
  shown = Take[items, UpTo[$iSVSVMaxRows]];
  Column[{
    iSVSVCountsLine[src],
    If[items === {}, Style["\:3053\:306e\:7d5e\:308a\:8fbc\:307f\:306b\:5f53\:305f\:308b\:9805\:76ee\:306f\:3042\:308a\:307e\:305b\:3093\:3002", Gray],
      Pane[Grid[Prepend[iSVSVItemRow[#, lo] & /@ shown, iSVSVHeaderRow[]],
          Alignment -> {Left, Center}, Spacings -> {1.2, 0.7}, BaseStyle -> {LineBreakWithin -> False},
          Dividers -> {None, {False, GrayLevel[0.6], {GrayLevel[0.88]}, False}},
          Background -> {None, {GrayLevel[0.95], None}}],
        ImageSize -> {Full, UpTo[640]}, Scrollbars -> Automatic]],
    If[Length[items] > Length[shown],
      Style["\:5148\:982d\:306e " <> ToString[Length[shown]] <> " \:4ef6\:3092\:8868\:793a\:3057\:3066\:3044\:307e\:3059 (\:5168 " <> ToString[Length[items]] <>
        " \:4ef6)\:3002\:7d5e\:308a\:8fbc\:307f\:3092\:5909\:3048\:308b\:304b\:3001\"Window\" \:3092\:77ed\:304f\:3057\:3066\:304f\:3060\:3055\:3044\:3002", 11, Gray], Nothing]}, Spacings -> 0.8]];
(* computing form (not used by the views): the same body from a fresh computation *)
iSVSVBody[filter_, o_List] := iSVSVBody[filter, iSVSVCompute["Items", o], o];

(* what the Dynamic of a view evaluates: draw the stored data, never compute *)
iSVSVStaleLine[kind_String, o_List] := With[{k = kind, oo = o},
  Row[{Style["\:5225\:306e\:64cd\:4f5c\:3067\:5185\:5bb9\:304c\:5909\:308f\:308a\:307e\:3057\:305f\:3002\:3053\:306e\:4e00\:89a7\:306f\:305d\:306e\:524d\:306e\:3082\:306e\:3067\:3059\:3002 ", 11, RGBColor[0.75, 0.4, 0.]],
    iSVSVBtn["\:4e00\:89a7\:3092\:66f4\:65b0", iSVSVReload[k, oo], True]}]];
(* the highest privacy level in the stored data of a view (1.0 when it cannot be told) *)
iSVSVDataPL["Series", list_] := Which[! ListQ[list], 1.0, list === {}, 0., True, Max[Lookup[#, "PrivacyLevel", 1.0] & /@ list]];
iSVSVDataPL["Businesses" | "Business", data_] := If[! AssociationQ[data], 1.0,
  With[{m = Lookup[data, "MaxPrivacyLevel", If[Lookup[data, "Status", ""] === "NotFound", 0., 1.0]]}, If[NumberQ[m], m, 1.0]]];
iSVSVDataPL[_, data_] := With[{a = If[AssociationQ[data], Lookup[data, "All", Missing[]], Missing[]]},
  If[AssociationQ[a], With[{m = Lookup[a, "MaxPrivacyLevel", 1.0]}, If[NumberQ[m], m, 1.0]], 1.0]];
(* the frame of a view was made for the level the data had then (pl0). A later redraw can hold more confidential mails
   (new mail): say so inside the view. *)
iSVSVRaisedLine[plNow_, pl0_] := If[NumberQ[plNow] && NumberQ[pl0] && plNow >= 0.5 && plNow > pl0 + 0.001,
  Style["\:26a0 \:6a5f\:5bc6 / Confidential  PrivacyLevel " <> ToString[NumberForm[plNow, {3, 2}]] <>
    " (\:3053\:306e\:4e00\:89a7\:3092\:4f5c\:3063\:305f\:5f8c\:306b\:3001\:3088\:308a\:6a5f\:5bc6\:5ea6\:306e\:9ad8\:3044\:30e1\:30fc\:30eb\:304c\:52a0\:308f\:308a\:307e\:3057\:305f\:3002\:8a55\:4fa1\:3057\:76f4\:3059\:3068\:67a0\:304c\:4ed8\:304d\:307e\:3059)", RGBColor[0.75, 0.1, 0.1], Bold, 11],
  Nothing];

iSVSVShow[kind_String, o_List, filter_ : None, pl0_ : 1.0] := Module[{id = iSVSVViewId[kind, o], e},
  e = Lookup[$iSVSVStore, id, Missing[]];
  If[! AssociationQ[e],
    Return[Column[{Style["\:3053\:306e\:4e00\:89a7\:306f\:307e\:3060\:8a08\:7b97\:3057\:3066\:3044\:307e\:305b\:3093 (\:30ab\:30fc\:30cd\:30eb\:3092\:8d77\:52d5\:3057\:76f4\:3057\:305f\:5f8c\:306a\:3069)\:3002", 11, Gray],
      With[{k = kind, oo = o}, iSVSVBtn["\:4e00\:89a7\:3092\:4f5c\:308b", iSVSVReload[k, oo], True]]}, Spacings -> 0.5]]];
  Block[{$iSVSVViewNow = id},
    Column[{
      iSVSVRaisedLine[iSVSVDataPL[kind, e["Data"]], pl0],
      If[e["Tick"] =!= $iSVSVTick, iSVSVStaleLine[kind, o], Nothing],
      Switch[kind, "Series", iSVSVSeriesBody[e["Data"], o], "Businesses", iSVSVBusinessListBody[e["Data"], o],
        "Business", iSVSVBusinessTreeBody[e["Data"], o], _, iSVSVBody[filter, e["Data"], o]]}, Spacings -> 0.6]]];

iSVSVWrap[view_, pl_] := Which[
  ! NumberQ[pl] || pl <= 0., view,
  Length[DownValues[SourceVault`SourceVaultPrivateView]] > 0,
    Quiet @ Check[SourceVault`SourceVaultPrivateView[view, pl], view],
  pl >= 0.5,
    Framed[Column[{Style["\:26a0 \:6a5f\:5bc6 / Confidential  PrivacyLevel " <> ToString[NumberForm[pl, {3, 2}]], RGBColor[0.75, 0.1, 0.1], Bold],
      view}], FrameStyle -> RGBColor[0.8, 0.1, 0.1], Background -> RGBColor[1., 0.95, 0.95]],
  True, view];

(* the options handed to the buttons: only the small ones (never an injected list of mails) *)
iSVSVLightOpts[o_List] := FilterRules[o, {"MBox", "Window", "MaxPrivacyLevel"}];

Options[SourceVault`SourceVaultMailTaskProposalsView] = Join[{"Filter" -> "Open"},
  DeleteCases[Options[SourceVault`SourceVaultMailTaskProposals], "States" -> _]];
SourceVault`SourceVaultMailTaskProposalsView[opts : OptionsPattern[]] := Module[{o = Flatten[{opts}], init, wopts, first, pl},
  init = First[Cases[o, ("Filter" -> f_) :> f, {1}, 1], "Open"];
  wopts = DeleteCases[o, ("Filter" | "States") -> _];
  (* the data is computed here, in the main evaluation, and stored; the Dynamic below only draws it *)
  first = With[{id = iSVSVLoad["Items", wopts]}, Lookup[Lookup[Lookup[$iSVSVStore, id, <||>], "Data", <||>], "All", Missing[]]];
  pl = If[AssociationQ[first], Lookup[first, "MaxPrivacyLevel", 1.0], 1.0];
  iSVSVWrap[
    With[{w = wopts, i = init, p0 = pl},
      DynamicModule[{filter = i},
        Column[{
          Style["\:63d0\:6848\:30bf\:30b9\:30af (\:30e1\:30fc\:30eb\:8d77\:70b9)", Bold, 14],
          SetterBar[Dynamic[filter], $iSVSVFilters, Appearance -> "Palette"],
          Style[Dynamic[
            If[Length[DownValues[SourceVault`SeriesViewPrivate`iSVSVShow]] > 0,
              SourceVault`SeriesViewPrivate`iSVSVShow["Items", w, filter, p0],
              Style["SourceVault \:304c\:8aad\:307f\:8fbc\:307e\:308c\:3066\:3044\:307e\:305b\:3093\:3002", Gray]],
            TrackedSymbols :> {filter, SourceVault`SeriesViewPrivate`$iSVSVTick, SourceVault`SeriesViewPrivate`$iSVSVDraw}],
            DynamicEvaluationTimeout -> 60]}, Spacings -> 0.9]]],
    pl]];

(* ---------------- series candidates (04 section 4.3) ---------------- *)

iSVSVMemberLine[m_Association, multi_] := Row[{Style["\:4ef6\:540d\:306e\:578b: ", 10, Gray], Style[iSVSVClip[m["Name"], 32], 11],
  With[{lab = Lookup[m, "Label", Missing[]]}, If[StringQ[lab], Style["  \:3014" <> lab <> "\:3015", 10, RGBColor[0.1, 0.35, 0.6]], ""]],
  Style["  " <> ToString[m["Count"]] <> " \:56de  ", 10, Gray],
  Style[If[m["Status"] === "Confirmed", "\:78ba\:5b9a", "\:672a\:78ba\:8a8d (\:81ea\:52d5\:3067\:8ffd\:52a0)"], 10, If[m["Status"] === "Confirmed", Darker[Green], Orange]],
  (* why a pattern joined by itself: the owner can judge the ground at a glance *)
  With[{j = Lookup[m, "JoinedBy", Missing[]]}, If[AssociationQ[j],
    Style["  " <> Lookup[<|"Words" -> "\:4ef6\:540d\:3068\:6982\:8981\:306e\:8a9e", "Meaning" -> "\:610f\:5473\:306e\:8fd1\:3055", "Label" -> "\:540c\:3058\:30e9\:30d9\:30eb"|>, j["Basis"], "\:985e\:4f3c"] <>
      If[NumberQ[j["Score"]] && j["Basis"] =!= "Label", " " <> ToString[NumberForm[N[j["Score"]], {3, 2}]], ""] <>
      " \:3067\:300c" <> iSVSVClip[ToString[j["To"]], 14] <> "\:300d\:306b", 9, GrayLevel[0.45]], ""]], "  ",
  If[TrueQ[multi], With[{id = m["SeriesId"]}, iSVSVBtn["\:3053\:306e\:578b\:3092\:5916\:3059", iSVSVDo[id, "SeriesDetach", {}]]], ""]}];
iSVSVOccLine[p_Association] := Row[{Style[ToString[p["Key"]], Bold, 11], "  ", Style[iSVSVDay[p["Date"]], 11], "  ",
  Style[iSVSVClip[p["Subject"], 30], 11], "  ", Style["\:5bfe\:5fdc: " <> iSVSVHandlingText[p["Handling"]], 11, Darker[Green]], "  ",
  With[{rid = p["RecordId"]}, iSVSVBtn["\:2709", iSVSVOpenMail[rid]]], " ",
  With[{rid = p["RecordId"]}, iSVSVBtn["\:5916\:3059", iSVSVDo[rid, "SeriesRemoveMail", {}]]]}];
iSVSVSimilarLine[sid_String, x_Association] := Row[{Style["\:5185\:5bb9\:306e\:8fd1\:3044\:7cfb\:5217: ", 10, Gray], Style[iSVSVClip[x["Name"], 30], 11],
  Style["  " <> ToString[x["Count"]] <> " \:56de  \:8fd1\:3055 " <> ToString[NumberForm[N[x["Score"]], {3, 2}]] <> "  ", 10, Gray],
  With[{a = sid, b = x["SeriesId"]}, iSVSVBtn["\:7d71\:5408\:3059\:308b", iSVSVDo[{a, b}, "SeriesMerge", {}]]]}];

iSVSVSeriesRow[s_Association] := Module[{occ = Lookup[s, "Occurrences", {}], sid = s["SeriesId"], st = s["Status"],
    mem = Lookup[s, "Members", {}], mids, pending},
  mids = If[mem === {}, {sid}, Lookup[mem, "SeriesId"]];
  pending = Count[mem, _?(#["Status"] =!= "Confirmed" &)];
  {Style[If[st === "Confirmed", "\:78ba\:5b9a", "\:5019\:88dc"], Bold, 11, If[st === "Confirmed", Darker[Green], RGBColor[0.1, 0.35, 0.8]]],
   OpenerView[{
     Column[{Style[iSVSVClip[s["Name"], 34], 12],
       With[{lab = Lookup[s, "Label", Missing[]]}, If[StringQ[lab], Style["\:696d\:52d9: " <> lab, 10, RGBColor[0.1, 0.35, 0.6]], Nothing]],
       If[Length[mem] > 1, Style["\:4ef6\:540d\:306e\:578b " <> ToString[Length[mem]] <> " \:7a2e" <>
         If[pending > 0 && st === "Confirmed", " (\:672a\:78ba\:8a8d " <> ToString[pending] <> ")", ""], 10, Orange], Nothing]}, Spacings -> 0.1],
     Column[Join[iSVSVMemberLine[#, Length[mem] > 1] & /@ mem, iSVSVOccLine /@ Take[Reverse[occ], UpTo[$iSVSVMaxOccLines]],
       If[Length[occ] > $iSVSVMaxOccLines,
         {Style["\:307b\:304b " <> ToString[Length[occ] - $iSVSVMaxOccLines] <> " \:56de (\:53e4\:3044\:56de)\:3002\:5168\:90e8\:306f SourceVaultSeriesInfo[\"" <> ToString[sid] <> "\"]", 10, Gray]}, {}],
       iSVSVSimilarLine[sid, #] & /@ Lookup[s, "Similar", {}]], Spacings -> 0.3]}, False],
   Style[Lookup[$iSVSVUnit, s["Period"]["Unit"], "?"], 11],
   Style[ToString[s["Count"]] <> " \:56de (\:5bfe\:5fdc " <> ToString[Lookup[s, "HandledCount", 0]] <> ")", 11],
   Style[StringRiffle[ToString[#["Key"]] & /@ Take[occ, -Min[4, Length[occ]]], ", "], 11],
   Style[If[NumberQ[s["NextPredicted"]], iSVSVDay[s["NextPredicted"]] <> " \:9803", "-"], 11],
   With[{ids = mids}, Row[{
     If[st =!= "Confirmed" || pending > 0, iSVSVBtn["\:7cfb\:5217\:306b\:3059\:308b", iSVSVDo[ids, "SeriesConfirm", {}], True], ""], " ",
     iSVSVBtn["\:5374\:4e0b", iSVSVDo[ids, "SeriesReject", {}]]}]]}];

(* how the series are being compared: by meaning (local embeddings) or by words (the fallback), and what to do when the
   local model cannot be used *)
iSVSVDo["EmbedRefresh", o_List] := (
  With[{r = SourceVault`SourceVaultSeriesEmbedRefresh[Sequence @@ o]},
    If[AssociationQ[r] && Lookup[r, "Status", ""] === "Refused", iSVSVReport[r]]];
  iSVSVRefresh[]);

iSVSVEmbedLine[o_List] := Module[{st = Quiet @ Check[SourceVault`SourceVaultSeriesEmbedStatus[], <||>], mode, docs, with, lo},
  If[! AssociationQ[st] || st === <||>, Return[Nothing]];
  mode = Lookup[st, "Mode", "Lexical"]; docs = Lookup[st, "Documents", Missing[]]; with = Lookup[st, "DocumentsWithVectors", Missing[]];
  lo = FilterRules[o, {"MBox"}];
  Row[{Style["\:5185\:5bb9\:306e\:6bd4\:8f03: ", 11, Gray],
    Which[
      ! TrueQ[st["Enabled"]], Style["\:8a9e\:306e\:4e00\:81f4 (\:57cb\:3081\:8fbc\:307f\:306f\:4f7f\:3063\:3066\:3044\:307e\:305b\:3093)", 11],
      mode === "Semantic", Style["\:610f\:5473 (\:30ed\:30fc\:30ab\:30eb\:306e\:57cb\:3081\:8fbc\:307f " <> ToString[st["Model"]] <> ") \:3068\:8a9e\:306e\:4e00\:81f4", 11, Darker[Green]],
      mode === "Partial", Style["\:610f\:5473 (\:30ed\:30fc\:30ab\:30eb\:306e\:57cb\:3081\:8fbc\:307f) \:306f\:4e00\:90e8\:3060\:3051\:3002\:6b8b\:308a\:306f\:8a9e\:306e\:4e00\:81f4" <>
        If[IntegerQ[docs] && IntegerQ[with], " (" <> ToString[with] <> " / " <> ToString[docs] <> " \:4ef6)", ""], 11, Orange],
      True, Style["\:8a9e\:306e\:4e00\:81f4 (\:57cb\:3081\:8fbc\:307f\:306f\:672a\:8a08\:7b97)", 11, Orange]],
    "  ",
    If[TrueQ[st["Enabled"]],
      With[{oo = lo}, Tooltip[iSVSVBtn["\:5185\:5bb9\:306e\:6bd4\:8f03\:3092\:66f4\:65b0", iSVSVDo["EmbedRefresh", oo]],
        "\:4ef6\:540d\:3068\:6982\:8981\:3092\:30ed\:30fc\:30ab\:30eb\:306e\:57cb\:3081\:8fbc\:307f\:30e2\:30c7\:30eb\:3067\:30d9\:30af\:30c8\:30eb\:306b\:3057\:307e\:3059\:3002\:521d\:56de\:306f\:6570\:5206\:304b\:304b\:308b\:3053\:3068\:304c\:3042\:308a\:307e\:3059\:3002\:30af\:30e9\:30a6\:30c9\:306b\:306f\:9001\:308a\:307e\:305b\:3093\:3002"]], ""],
    If[TrueQ[st["Available"] === False],
      Row[{"  ", Style["\:30ed\:30fc\:30ab\:30eb\:306e\:30e2\:30c7\:30eb\:3092\:4f7f\:3048\:307e\:305b\:3093 (" <> ToString[st["Reason"]] <> ")\:3002\:8a9e\:306e\:4e00\:81f4\:3067\:6bd4\:3079\:3066\:3044\:307e\:3059\:3002 ", 11, RGBColor[0.75, 0.1, 0.1]],
        Style[ToString[Lookup[st, "Hint", ""]], 10, Gray]}], ""]}]];

(* the business labels (written by the local model): how many title patterns have one, and what to do when the local
   model cannot be used. The button asks the model; building the list never does. *)
iSVSVDo["LabelRefresh", o_List] := (
  With[{r = SourceVault`SourceVaultSeriesLabelRefresh["TimeLimit" -> 240, Sequence @@ o]},
    If[AssociationQ[r] && Lookup[r, "Status", ""] === "Refused", iSVSVReport[r]]];
  iSVSVRefresh[]);

iSVSVLabelLine[o_List] := Module[{st = Quiet @ Check[SourceVault`SourceVaultSeriesLabelStatus[], <||>], docs, with, lo},
  If[! AssociationQ[st] || st === <||>, Return[Nothing]];
  docs = Lookup[st, "Documents", Missing[]]; with = Lookup[st, "DocumentsWithLabels", Missing[]];
  lo = FilterRules[o, {"MBox"}];
  Row[{Style["\:696d\:52d9\:306e\:30e9\:30d9\:30eb: ", 11, Gray],
    Which[
      ! TrueQ[st["Enabled"]], Style["\:4f7f\:3063\:3066\:3044\:307e\:305b\:3093", 11],
      IntegerQ[docs] && IntegerQ[with] && docs > 0 && with >= docs,
        Style["\:30ed\:30fc\:30ab\:30eb\:306e LLM \:304c\:4ed8\:3051\:305f\:30e9\:30d9\:30eb\:304c\:540c\:3058\:4ef6\:540d\:306e\:578b\:3092\:307e\:3068\:3081\:3066\:3044\:307e\:3059 (" <> ToString[with] <> " \:4ef6)", 11, Darker[Green]],
      IntegerQ[docs] && IntegerQ[with] && with > 0,
        Style["\:4e00\:90e8\:3060\:3051 (" <> ToString[with] <> " / " <> ToString[docs] <> " \:4ef6)\:3002\:6b8b\:308a\:306f\:57cb\:3081\:8fbc\:307f\:3068\:8a9e\:306e\:4e00\:81f4", 11, Orange],
      True, Style["\:307e\:3060\:4ed8\:3051\:3066\:3044\:307e\:305b\:3093 (\:57cb\:3081\:8fbc\:307f\:3068\:8a9e\:306e\:4e00\:81f4\:3067\:6bd4\:3079\:3066\:3044\:307e\:3059)", 11, Orange]],
    "  ",
    If[TrueQ[st["Enabled"]],
      With[{oo = lo}, Tooltip[iSVSVBtn["\:696d\:52d9\:306e\:30e9\:30d9\:30eb\:3092\:66f4\:65b0", iSVSVDo["LabelRefresh", oo]],
        "\:4ef6\:540d\:3068\:6982\:8981\:304b\:3089\:3001\:30ed\:30fc\:30ab\:30eb\:306e LLM \:306b\:696d\:52d9\:306e\:77ed\:3044\:540d\:524d\:3092\:4ed8\:3051\:3055\:305b\:307e\:3059\:3002\:8a00\:3044\:65b9\:304c\:9055\:3063\:3066\:3082\:540c\:3058\:696d\:52d9\:306a\:3089\:540c\:3058\:540d\:524d\:306b\:306a\:308a\:3001\:540c\:3058\:540d\:524d\:306e\:4ef6\:540d\:306e\:578b\:3092 1 \:3064\:306e\:7cfb\:5217\:306b\:307e\:3068\:3081\:307e\:3059\:3002" <>
        "1 \:56de\:3067 4 \:5206\:307e\:3067\:3002\:6b8b\:308a\:306f\:3082\:3046\:4e00\:5ea6\:62bc\:3059\:3068\:7d9a\:304d\:304b\:3089\:4ed8\:3051\:307e\:3059\:3002\:30af\:30e9\:30a6\:30c9\:306b\:306f\:9001\:308a\:307e\:305b\:3093\:3002"]], ""],
    If[TrueQ[st["Available"] === False],
      Row[{"  ", Style["\:30ed\:30fc\:30ab\:30eb\:306e LLM \:3092\:4f7f\:3048\:307e\:305b\:3093 (" <> ToString[st["Reason"]] <> ")\:3002\:57cb\:3081\:8fbc\:307f\:3068\:8a9e\:306e\:4e00\:81f4\:3067\:6bd4\:3079\:3066\:3044\:307e\:3059\:3002 ", 11, RGBColor[0.75, 0.1, 0.1]],
        Style[ToString[Lookup[st, "Hint", ""]], 10, Gray]}], ""]}]];

(* the body of the candidates view, drawn from the stored list (see the top of the file) *)
iSVSVSeriesBody[list_, o_List] := Module[{shown},
  If[! ListQ[list] || list === {}, Return[Column[{iSVSVEmbedLine[o], iSVSVLabelLine[o], Style["\:7cfb\:5217\:306e\:5019\:88dc\:306f\:3042\:308a\:307e\:305b\:3093\:3002", Gray]}]]];
  shown = Take[list, UpTo[$iSVSVMaxRows]];
  Column[{iSVSVEmbedLine[o], iSVSVLabelLine[o],
  Pane[Grid[Prepend[iSVSVSeriesRow /@ shown,
      Style[#, Bold, 11, GrayLevel[0.3]] & /@ {"\:72b6\:614b", "\:696d\:52d9 (\:76f4\:8fd1\:306e\:4ef6\:540d)", "\:5468\:671f", "\:56de\:6570", "\:76f4\:8fd1\:306e\:56de", "\:6b21\:56de\:306e\:4e88\:6e2c", "\:64cd\:4f5c"}],
      Alignment -> {Left, Center}, Spacings -> {1.2, 0.7}, BaseStyle -> {LineBreakWithin -> False},
      Dividers -> {None, {False, GrayLevel[0.6], {GrayLevel[0.88]}, False}}, Background -> {None, {GrayLevel[0.95], None}}],
    ImageSize -> {Full, UpTo[560]}, Scrollbars -> Automatic],
  If[Length[list] > Length[shown],
    Style["\:5148\:982d\:306e " <> ToString[Length[shown]] <> " \:4ef6\:3092\:8868\:793a\:3057\:3066\:3044\:307e\:3059 (\:5168 " <> ToString[Length[list]] <>
      " \:4ef6\:3002\:5bfe\:5fdc\:3057\:305f\:56de\:306e\:591a\:3044\:9806)\:3002\:5168\:90e8\:306f SourceVaultSeriesDiscover[]\:3002", 11, Gray], Nothing]}, Spacings -> 0.6]];
(* computing form (not used by the views) *)
iSVSVSeriesBody[o_List] := iSVSVSeriesBody[iSVSVCompute["Series", o], o];

Options[SourceVault`SourceVaultSeriesCandidatesView] = Options[SourceVault`SourceVaultSeriesDiscover];
SourceVault`SourceVaultSeriesCandidatesView[opts : OptionsPattern[]] := Module[{o = Flatten[{opts}], list, pl},
  (* the list is computed here, in the main evaluation, and stored; the Dynamic below only draws it *)
  list = With[{id = iSVSVLoad["Series", o]}, Lookup[Lookup[$iSVSVStore, id, <||>], "Data", Missing[]]];
  pl = Which[! ListQ[list], 1.0, list === {}, 0., True, Max[Lookup[#, "PrivacyLevel", 1.0] & /@ list]];
  iSVSVWrap[
    With[{w = o, p0 = pl},
      Column[{
        Style["\:5b9a\:578b\:696d\:52d9\:306e\:7cfb\:5217\:306e\:5019\:88dc (\:30e1\:30fc\:30eb\:304b\:3089)", Bold, 14],
        Style[Dynamic[
          If[Length[DownValues[SourceVault`SeriesViewPrivate`iSVSVShow]] > 0,
            SourceVault`SeriesViewPrivate`iSVSVShow["Series", w, None, p0],
            Style["SourceVault \:304c\:8aad\:307f\:8fbc\:307e\:308c\:3066\:3044\:307e\:305b\:3093\:3002", Gray]],
          TrackedSymbols :> {SourceVault`SeriesViewPrivate`$iSVSVTick, SourceVault`SeriesViewPrivate`$iSVSVDraw}],
          DynamicEvaluationTimeout -> 60]}, Spacings -> 0.9]],
    pl]];

(* ---------------- the larger businesses: business -> academic year -> steps ---------------- *)

iSVSVYearsText[by_, y0_] := If[! AssociationQ[by] || Length[by] === 0, "-",
  StringRiffle[KeyValueMap[ToString[#1] <> "\:5e74\:5ea6 " <> ToString[#2] <> " \:901a" &, KeyTake[by, Range[y0, y0 - 2, -1]]], " \:30fb "] <>
    With[{older = Total[Values[KeySelect[by, # < y0 - 2 &]]]}, If[older > 0, " \:30fb \:305d\:308c\:4ee5\:524d " <> ToString[older] <> " \:901a", ""]]];

iSVSVBusinessRow[b_Association, y0_] := Module[{name = ToString[b["Name"]], match = ToString[b["Match"]], conf = b["Status"] === "Confirmed"},
  {Style[If[conf, "\:78ba\:5b9a", "\:5019\:88dc"], Bold, 11, If[conf, Darker[Green], RGBColor[0.1, 0.35, 0.8]]],
   Column[{Style[iSVSVClip[name, 30], 12],
     Style["\:4ef6\:540d\:306b\:300c" <> match <> "\:300d" <> With[{x = Lookup[b, "Exclude", {}]}, If[ListQ[x] && x =!= {}, "  (\:9664\:304f: " <> StringRiffle[x, "\:3001"] <> ")", ""]], 10, Gray],
     With[{smp = Lookup[b, "Sample", {}]}, If[ListQ[smp] && smp =!= {}, Style["\:4f8b: " <> iSVSVClip[First[smp], 40], 10, GrayLevel[0.45]], Nothing]]},
     Spacings -> 0.1],
   Style[iSVSVYearsText[Lookup[b, "ByYear", <||>], y0], 11],
   Style[ToString[Lookup[b, "Count", 0]] <> " \:901a" <>
     With[{np = Lookup[b, "Patterns", Missing[]]}, If[IntegerQ[np], " \:30fb \:4ef6\:540d " <> ToString[np] <> " \:7a2e", ""]], 11],
   Style[If[NumberQ[Lookup[b, "LastDate", Missing[]]], iSVSVDay[b["LastDate"]], "-"], 11],
   With[{n = name, m = match},
     Row[{iSVSVBtn["\:6728\:3092\:958b\:304f", iSVSVOpenBusiness[n, m], conf], " ",
       If[conf, Nothing, iSVSVBtn["\:696d\:52d9\:3068\:3057\:3066\:78ba\:5b9a", iSVSVDo[n, {"BusinessConfirm", m}, {}], True]], " ",
       iSVSVBtn[If[conf, "\:78ba\:5b9a\:3092\:53d6\:308a\:6d88\:3059", "\:696d\:52d9\:3067\:306f\:306a\:3044"], iSVSVDo[n, {"BusinessReject", m}, {}]]}]]}];

iSVSVBusinessListBody[data_, o_List] := Module[{conf, cands, y0, rows},
  If[! AssociationQ[data], Return[Style["\:4e00\:89a7\:3092\:4f5c\:308c\:307e\:305b\:3093\:3067\:3057\:305f\:3002", Red]]];
  conf = Lookup[data, "Confirmed", {}]; cands = Lookup[data, "Candidates", {}]; y0 = Lookup[data, "ThisYear", 0];
  rows = Take[Join[conf, cands], UpTo[$iSVSVMaxRows]];
  Column[{
    Style["\:78ba\:5b9a\:3057\:305f\:696d\:52d9 " <> ToString[Length[conf]] <> " \:30fb \:5019\:88dc " <> ToString[Length[cands]] <>
      "   (\:5019\:88dc\:306f\:3001\:6700\:8fd1\:306e\:30e1\:30fc\:30eb\:306e 3 \:7a2e\:985e\:4ee5\:4e0a\:306e\:9055\:3046\:4ef6\:540d\:306b\:73fe\:308c\:30012 \:3064\:4ee5\:4e0a\:306e\:5e74\:5ea6\:306b\:307e\:305f\:304c\:308b\:540d\:524d\:3067\:3059\:3002\:4ef6\:540d\:306e\:8a9e\:3060\:3051\:3067\:6c7a\:3081\:3066\:3044\:307e\:3059)", 11, Gray],
    If[rows === {}, Style["\:696d\:52d9\:3082\:5019\:88dc\:3082\:3042\:308a\:307e\:305b\:3093\:3002\:30e1\:30fc\:30eb\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:300c\:4e0a\:4f4d\:306e\:696d\:52d9\:300d\:306e\:7bc0\:3001\:307e\:305f\:306f SourceVaultBusinessConfirm[\"\:540d\:524d\"] \:3067\:78ba\:5b9a\:3067\:304d\:307e\:3059\:3002", Gray],
      Pane[Grid[Prepend[iSVSVBusinessRow[#, y0] & /@ rows,
          Style[#, Bold, 11, GrayLevel[0.3]] & /@ {"\:72b6\:614b", "\:696d\:52d9 (\:4ef6\:540d\:306e\:8a9e)", "\:5e74\:5ea6\:3054\:3068\:306e\:901a\:6570", "\:5168\:4f53", "\:76f4\:8fd1", "\:64cd\:4f5c"}],
          Alignment -> {Left, Center}, Spacings -> {1.2, 0.7}, BaseStyle -> {LineBreakWithin -> False},
          Dividers -> {None, {False, GrayLevel[0.6], {GrayLevel[0.88]}, False}}, Background -> {None, {GrayLevel[0.95], None}}],
        ImageSize -> {Full, UpTo[560]}, Scrollbars -> Automatic]]}, Spacings -> 0.6]];

(* one step (a mail matter): date, [state], subject (opens the mail), attachments, handling, notebook, [take out] *)
(* (a step of this year shows its state instead of the handling text, and a shorter title: two steps stand side by side) *)
iSVSVStepLine[s_Association, bizId_, o_List, showState_ : False] := Row[{
  Style[iSVSVDay[s["Date"]], 11], "  ",
  If[TrueQ[showState], Row[{iSVSVStateBadge[s], " "}], ""],
  With[{rid = s["RecordId"]},
    Tooltip[Button[Style[iSVSVClip[s["Subject"], If[TrueQ[showState], 30, 36]], 11, RGBColor[0.05, 0.25, 0.6]], iSVSVOpenMail[rid],
      Appearance -> "Frameless", Method -> "Queued", BaseStyle -> {}], ToString[s["Subject"]]]],
  If[Lookup[s, "Attachments", 0] > 0, Style["  \:6dfb\:4ed8 " <> ToString[s["Attachments"]], 10, Gray], ""],
  If[TrueQ[showState], "", Style["  \:5bfe\:5fdc: " <> iSVSVHandlingText[Lookup[s, "Handling", Missing[]]], 10, Darker[Green]]],
  If[StringQ[Lookup[Lookup[s, "Handling", <||>], "NotebookPath", Missing[]]],
    With[{path = s["Handling"]["NotebookPath"]}, Row[{" ", iSVSVBtn["\|01f4d3", iSVSVOpenPath[path]]}]], ""],
  If[StringQ[bizId], With[{rid = s["RecordId"], b = bizId, oo = o},
    Row[{" ", Tooltip[iSVSVBtn["\:5916\:3059", iSVSVDo[rid, {"BusinessRemoveMail", b}, oo]], "\:3053\:306e\:30e1\:30fc\:30eb\:3092\:696d\:52d9\:304b\:3089\:5916\:3059 (\:4ef6\:540d\:306b\:8a9e\:3092\:542b\:3080\:304c\:5225\:306e\:7528\:4ef6)"]}]], ""]}];

(* what the owner can do with a step of this year that is not handled yet *)
(* lastKind: how the corresponding step of last year was handled -- that is the suggestion for this year (its button is
   the emphasized one) *)
iSVSVStepActions[s_Association, o_List, lastKind_ : "None"] := With[{r = s["RecordId"], oo = o, st = Lookup[s, "State", ""],
    track = Lookup[s, "Track", <||>],
    emph = Switch[lastKind, "Notebook", "Notebook", "Todo", "Todo", "Replied", "Reply", "MarkedDone" | "Dismissed", "Done", _, "Notebook"]},
  Which[
    MemberQ[{"Proposed", "Reproposed", "Unclassified"}, st],
      Row[{If[emph === "Reply", Row[{iSVSVBtn["\:8fd4\:4fe1", iSVSVDo[r, "Reply", oo], True], " "}], ""],
        iSVSVBtn["\:30ce\:30fc\:30c8", iSVSVDo[r, "Notebook", oo], emph === "Notebook"], " ", iSVSVBtn["Todo", iSVSVDo[r, "Todo", oo], emph === "Todo"], " ",
        iSVSVBtn["\:6e08", iSVSVDo[r, "Done", oo], emph === "Done"],
        If[MemberQ[{"Notebook", "Todo", "Replied", "MarkedDone", "Dismissed"}, lastKind],
          Style["   \:6628\:5e74\:5ea6\:306f: " <> Lookup[$iSVSVHandling, lastKind, "-"], 10, Gray], ""]}],
    st === "InProgress" && Lookup[track, "Kind", None] === "Notebook" && StringQ[Lookup[track, "NotebookPath", Missing[]]],
      With[{path = track["NotebookPath"]}, Row[{iSVSVBtn["\|01f4d3 \:958b\:304f", iSVSVOpenPath[path], True], " ", iSVSVBtn["\:6e08", iSVSVDo[r, "Done", oo]]}]],
    st === "InProgress", iSVSVBtn["\:6e08", iSVSVDo[r, "Done", oo]],
    st === "NoAction", iSVSVBtn["\:30bf\:30b9\:30af\:306b\:3059\:308b", iSVSVDo[r, "Propose", oo]],
    True, ""]];

iSVSVMonthDay[a_] := If[NumberQ[a], DateString[a, {"Month", "/", "Day"}], "-"];
iSVSVProgressRow[p_Association, bizId_, o_List, now_] := Module[{exp = Lookup[p, "ExpectedAt", Missing[]], this = Lookup[p, "This", Missing[]]},
  {iSVSVStepLine[p["Last"], bizId, o],
   Switch[p["Status"],
     "Arrived", If[AssociationQ[this], Column[{iSVSVStepLine[this, bizId, o, True],
       iSVSVStepActions[this, o, Lookup[Lookup[p["Last"], "Handling", <||>], "Kind", "None"]]}, Spacings -> 0.2], ""],
     "Upcoming", Style[If[NumberQ[exp] && exp < now, "\:305d\:308d\:305d\:308d (\:6628\:5e74\:306f ", "\:3053\:308c\:304b\:3089 (\:6628\:5e74\:306f "] <> iSVSVMonthDay[exp] <> ")", 11,
       If[NumberQ[exp] && exp < now, RGBColor[0.85, 0.5, 0.1], RGBColor[0.1, 0.35, 0.8]]],
     _, Style["\:4eca\:5e74\:5ea6\:306f\:307e\:3060\:5c4a\:3044\:3066\:3044\:307e\:305b\:3093 (\:6628\:5e74\:306f " <> iSVSVMonthDay[exp] <> ")", 11, GrayLevel[0.5]]]}];

iSVSVBusinessTreeBody[data_, o_List] := Module[
  {lo = iSVSVLightOpts[o], name, match, excl, conf, id, y0, years, prog, new, now = iSVSVNow[], thisY, lastY, older, arrived, up, na},
  If[! AssociationQ[data], Return[Style["\:6728\:3092\:4f5c\:308c\:307e\:305b\:3093\:3067\:3057\:305f\:3002", Red]]];
  If[Lookup[data, "Status", ""] =!= "OK",
    Return[Column[{Style["\:3053\:306e\:540d\:524d\:306e\:696d\:52d9\:306e\:30e1\:30fc\:30eb\:304c\:898b\:3064\:304b\:308a\:307e\:305b\:3093\:3002", 11, Gray], Style[ToString[Lookup[data, "Hint", ""]], 10, Gray]}]]];
  name = ToString[data["Name"]]; match = ToString[data["Match"]]; excl = Lookup[data, "Exclude", {}]; conf = TrueQ[data["Confirmed"]];
  id = If[conf, data["BusinessId"], None]; y0 = data["ThisYear"]; years = Lookup[data, "Years", {}];
  prog = Lookup[data, "Progress", {}]; new = Lookup[data, "New", {}];
  thisY = SelectFirst[years, #["Year"] === y0 &, <|"Count" -> 0|>]; lastY = SelectFirst[years, #["Year"] === y0 - 1 &, <|"Count" -> 0|>];
  older = Select[years, #["Year"] < y0 - 1 &];
  arrived = Count[prog, _?(#["Status"] === "Arrived" &)]; up = Count[prog, _?(#["Status"] === "Upcoming" &)];
  na = Count[prog, _?(#["Status"] === "NotArrived" &)];
  Column[{
    Row[{Style["\:696d\:52d9: " <> name, Bold, 13], "   ",
      Style[If[conf, "\:78ba\:5b9a\:6e08\:307f", "\:672a\:78ba\:5b9a (\:4ef6\:540d\:306e\:8a9e\:3067\:96c6\:3081\:305f\:898b\:3048\:65b9)"], 11, Bold, If[conf, Darker[Green], RGBColor[0.85, 0.5, 0.1]]], "   ",
      With[{n = name, m = match}, If[conf, iSVSVBtn["\:78ba\:5b9a\:3092\:53d6\:308a\:6d88\:3059", iSVSVDo[n, {"BusinessReject", m}, {}]],
        Row[{iSVSVBtn["\:3053\:306e\:696d\:52d9\:3092\:78ba\:5b9a\:3059\:308b", iSVSVDo[n, {"BusinessConfirm", m}, {}], True], " ",
          iSVSVBtn["\:696d\:52d9\:3067\:306f\:306a\:3044", iSVSVDo[n, {"BusinessReject", m}, {}]]}]]]}],
    Style["\:4ef6\:540d\:306b\:300c" <> match <> "\:300d\:3092\:542b\:3080\:30e1\:30fc\:30eb" <> If[ListQ[excl] && excl =!= {}, " (\:300c" <> StringRiffle[excl, "\:300d\:300c"] <> "\:300d\:3092\:542b\:3080\:4ef6\:540d\:306f\:9664\:304f)", ""] <>
      " \:30fb \:5168 " <> ToString[Lookup[data, "Count", 0]] <> " \:901a\:3002\:5e74\:5ea6\:306f 4 \:6708\:59cb\:307e\:308a\:3002", 11, Gray],
    (* the body of a DynamicModule is typeset after this function has returned: the id of the view is taken here *)
    If[conf, With[{b = data["BusinessId"], old = If[ListQ[excl], excl, {}], from = $iSVSVViewNow},
      Row[{Style["\:5225\:306e\:7528\:4ef6\:304c\:6df7\:3058\:308b\:3068\:304d: ", 10, Gray],
        DynamicModule[{w = ""}, Row[{InputField[Dynamic[w], String, FieldSize -> 14], " ",
          Button[Style["\:3053\:306e\:8a9e\:3092\:542b\:3080\:4ef6\:540d\:3092\:9664\:304f", 11],
            SourceVault`SeriesViewPrivate`iSVSVVia[from, SourceVault`SeriesViewPrivate`iSVSVDo[b, {"BusinessExclude", Append[old, w]}, {}]],
            Method -> "Queued", ImageSize -> Automatic, FrameMargins -> 3]}]],
        If[old =!= {}, Row[{" ", iSVSVBtn["\:9664\:304f\:8a9e\:3092\:6d88\:3059", iSVSVDo[b, {"BusinessExclude", {}}, {}]]}], ""]}]], Nothing],
    Style[ToString[y0] <> "\:5e74\:5ea6 (\:4eca\:5e74\:5ea6) " <> ToString[Lookup[thisY, "Count", 0]] <> " \:901a \:30fb \:672a\:51e6\:7406 " <> ToString[Lookup[data, "OpenCount", 0]] <>
      "     " <> ToString[y0 - 1] <> "\:5e74\:5ea6 (\:6628\:5e74\:5ea6) " <> ToString[Lookup[lastY, "Count", 0]] <> " \:901a", Bold, 12],
    (* last year's steps in the order of their dates, and what corresponds to each this year *)
    If[prog === {}, Style["\:6628\:5e74\:5ea6\:306e\:30e1\:30fc\:30eb\:304c\:3042\:308a\:307e\:305b\:3093 (\:4eca\:5e74\:5ea6\:304c\:6700\:521d\:306e\:5e74\:3067\:3059)\:3002", 11, Gray],
      Column[{
        Style["\:6628\:5e74\:5ea6\:306e\:6bb5\:968e\:3068\:3001\:4eca\:5e74\:5ea6\:306e\:9032\:307f  (\:5c4a\:3044\:305f " <> ToString[arrived] <> " \:30fb \:3053\:308c\:304b\:3089 " <> ToString[up] <> " \:30fb \:307e\:3060\:5c4a\:3044\:3066\:3044\:306a\:3044 " <> ToString[na] <> ")", 11, GrayLevel[0.3]],
        Pane[Grid[Prepend[iSVSVProgressRow[#, id, lo, now] & /@ Take[prog, UpTo[$iSVSVMaxRows]],
            Style[#, Bold, 11, GrayLevel[0.3]] & /@ {ToString[y0 - 1] <> "\:5e74\:5ea6\:306e\:6bb5\:968e", ToString[y0] <> "\:5e74\:5ea6"}],
            Alignment -> {Left, Center}, Spacings -> {1.6, 0.7}, BaseStyle -> {LineBreakWithin -> False},
            Dividers -> {{False, GrayLevel[0.8], False}, {False, GrayLevel[0.6], {GrayLevel[0.88]}, False}}, Background -> {None, {GrayLevel[0.95], None}}],
          ImageSize -> {Full, UpTo[520]}, Scrollbars -> Automatic]}, Spacings -> 0.4]],
    If[new === {}, Nothing,
      Column[Join[{Style["\:4eca\:5e74\:5ea6\:3060\:3051\:306e\:6bb5\:968e (\:6628\:5e74\:5ea6\:306b\:5bfe\:5fdc\:3059\:308b\:30e1\:30fc\:30eb\:304c\:7121\:3044\:3082\:306e) " <> ToString[Length[new]], 11, GrayLevel[0.3]]},
        (Row[{iSVSVStepLine[#, id, lo, True], "  ", iSVSVStepActions[#, lo]}] &) /@ Take[new, UpTo[$iSVSVMaxRows]]], Spacings -> 0.3]],
    If[older === {}, Nothing,
      Column[Join[{Style["\:904e\:53bb\:306e\:5e74\:5ea6", 11, GrayLevel[0.3]]},
        (OpenerView[{Style[#["Key"] <> "  " <> ToString[#["Count"]] <> " \:901a", 11],
            Column[iSVSVStepLine[#, id, lo] & /@ Take[#["Steps"], UpTo[$iSVSVMaxRows]], Spacings -> 0.3]}, False] &) /@ older], Spacings -> 0.3]]},
    Spacings -> 0.8]];

Options[SourceVault`SourceVaultBusinessView] = Join[{"Match" -> Automatic}, Options[SourceVault`SourceVaultBusinessDiscover]];
SourceVault`SourceVaultBusinessView[opts : OptionsPattern[]] := Module[{o = Flatten[{opts}], data, pl},
  (* the list is computed here, in the main evaluation, and stored; the Dynamic below only draws it *)
  data = With[{id = iSVSVLoad["Businesses", o]}, Lookup[Lookup[$iSVSVStore, id, <||>], "Data", Missing[]]];
  pl = iSVSVDataPL["Businesses", data];
  iSVSVWrap[
    With[{w = o, p0 = pl},
      Column[{
        Style["\:4e0a\:4f4d\:306e\:696d\:52d9 (\:30e1\:30fc\:30eb\:304b\:3089)", Bold, 14],
        Style[Dynamic[
          If[Length[DownValues[SourceVault`SeriesViewPrivate`iSVSVShow]] > 0,
            SourceVault`SeriesViewPrivate`iSVSVShow["Businesses", w, None, p0],
            Style["SourceVault \:304c\:8aad\:307f\:8fbc\:307e\:308c\:3066\:3044\:307e\:305b\:3093\:3002", Gray]],
          TrackedSymbols :> {SourceVault`SeriesViewPrivate`$iSVSVTick, SourceVault`SeriesViewPrivate`$iSVSVDraw}],
          DynamicEvaluationTimeout -> 60]}, Spacings -> 0.9]],
    pl]];
SourceVault`SourceVaultBusinessView[ref_String, opts : OptionsPattern[]] := Module[{o = Join[{"Ref" -> ref}, Flatten[{opts}]], data, pl},
  data = With[{id = iSVSVLoad["Business", o]}, Lookup[Lookup[$iSVSVStore, id, <||>], "Data", Missing[]]];
  pl = iSVSVDataPL["Business", data];
  iSVSVWrap[
    With[{w = o, p0 = pl},
      Column[{
        Style["\:696d\:52d9\:306e\:6728 (\:696d\:52d9 \:2192 \:5e74\:5ea6 \:2192 \:6bb5\:968e)", Bold, 14],
        Style[Dynamic[
          If[Length[DownValues[SourceVault`SeriesViewPrivate`iSVSVShow]] > 0,
            SourceVault`SeriesViewPrivate`iSVSVShow["Business", w, None, p0],
            Style["SourceVault \:304c\:8aad\:307f\:8fbc\:307e\:308c\:3066\:3044\:307e\:305b\:3093\:3002", Gray]],
          TrackedSymbols :> {SourceVault`SeriesViewPrivate`$iSVSVTick, SourceVault`SeriesViewPrivate`$iSVSVDraw}],
          DynamicEvaluationTimeout -> 60]}, Spacings -> 0.9]],
    pl]];

(* ---------------- the palette: the functions of this layer as buttons ----------------
   Owner, 2026-11-16: "I want to find problems and improvements while using it" -> a floating palette like ShowClaudePalette /
   ShowSystemDoctorPalette. The palette itself computes nothing (no Dynamic, no timer): a button computes when it is pressed
   (queued, not cut off by the front end), opens a view in a window of its own (pressing it again makes the window afresh),
   or runs an owner operation and says what came of it. While a button runs, claudecode's shared polling tick is held off
   the front end (ClaudeHoldFrontEnd, when claudecode is loaded). *)
$iSVSVLoadedAt = AbsoluteTime[];
$iSVSVPackageDir = With[{f = $InputFileName}, If[StringQ[f] && f =!= "", DirectoryName[f], None]];
If[! ValueQ[$iSVSPPalette], $iSVSPPalette = None];
If[! AssociationQ[$iSVSPWindows], $iSVSPWindows = <||>];
$iSVSPCreateWindow = Automatic;     (* test seam: Function[{title, content}] in place of CreateDocument *)
iSVSPL[ja_String, en_String] := If[$Language === "Japanese", ja, en];
iSVSPDefinedQ[name_String] := Names[name] =!= {} && With[{sym = Symbol[Identity[name]]}, Length[DownValues[sym]] > 0];
SetAttributes[iSVSPHold, HoldAll];
iSVSPHold[expr_] := If[iSVSPDefinedQ["ClaudeCode`ClaudeHoldFrontEnd"], Symbol[Identity["ClaudeCode`ClaudeHoldFrontEnd"]][expr], expr];

(* a view in a window of its own (one window per key; the old one is closed). The view is computed HERE, inside the queued
   button; what the window holds only draws the stored data. The windows cannot be saved: they are views of the mail store. *)
SetAttributes[iSVSPOpenWindow, HoldRest];
iSVSPOpenWindow[key_String, title0_, content_] := Module[{old = Lookup[$iSVSPWindows, key, None], nb, title = ToString[title0], c},
  If[MatchQ[old, _NotebookObject], Quiet @ NotebookClose[old]];
  c = content;
  nb = If[$iSVSPCreateWindow =!= Automatic, $iSVSPCreateWindow[title, c],
    Quiet @ CreateDocument[ExpressionCell[c, "Output"], WindowTitle -> title, WindowSize -> {1280, 780}, Saveable -> False]];
  If[MatchQ[nb, _NotebookObject], $iSVSPWindows[key] = nb,
    If[$iSVSPCreateWindow === Automatic, Quiet @ MessageDialog[iSVSPL["\:30a6\:30a4\:30f3\:30c9\:30a6\:3092\:958b\:3051\:307e\:305b\:3093\:3067\:3057\:305f: ", "Could not open: "] <> title]]];
  nb];

(* what an operation returned, said in a small dialog (short values only) *)
iSVSPShort[v_] := iSVSVClip[StringReplace[ToString[v /. _Missing -> "-"], "\n" -> " "], 110];
iSVSPResultColumn[title_String, r_] := Column[{Style[title, Bold, 12],
  If[AssociationQ[r],
    Grid[KeyValueMap[{Style[ToString[#1], GrayLevel[0.4]], iSVSPShort[#2]} &,
        Select[r, StringQ[#] || NumberQ[#] || BooleanQ[#] || MissingQ[#] || MatchQ[#, {(_String | _?NumberQ | _Rule) ...}] &]],
      Alignment -> Left, Spacings -> {1.2, 0.5}],
    Style[iSVSPShort[r], 11]]}, Spacings -> 0.8];
iSVSPSay[title_String, r_] := If[TrueQ[$Notebooks], Quiet @ MessageDialog[iSVSPResultColumn[title, r]], iSVSPResultColumn[title, r]];

(* ---- the views the buttons open ---- *)
$iSVSPViews = <|
  "proposals" -> {"\:63d0\:6848\:30bf\:30b9\:30af (\:30e1\:30fc\:30eb\:8d77\:70b9)", "Proposed tasks (from mail)"},
  "agenda" -> {"\:4e88\:5b9a", "Agenda"},
  "series" -> {"\:5b9a\:578b\:696d\:52d9\:306e\:7cfb\:5217\:306e\:5019\:88dc", "Series candidates"},
  "business" -> {"\:4e0a\:4f4d\:306e\:696d\:52d9", "Businesses"},
  "mail-untracked" -> {"\:30e1\:30fc\:30eb: \:696d\:52d9\:306b\:672a\:53cd\:6620 (\:63d0\:6848\:4e2d\:30fb\:518d\:63d0\:6848\:30fb\:672a\:5224\:5b9a)", "Mail: not yet in the workflow"},
  "mail-open" -> {"\:30e1\:30fc\:30eb: \:672a\:51e6\:7406 (\:672a\:53cd\:6620\:30fb\:51e6\:7406\:4e2d\:30fb\:4fdd\:7559)", "Mail: open"},
  "status" -> {"\:5b9a\:578b\:696d\:52d9: \:72b6\:614b", "Routine work: status"},
  "ledger" -> {"\:5b9a\:578b\:696d\:52d9: \:5224\:65ad\:306e\:8a18\:9332 (\:53f0\:5e33)", "Routine work: the ledger"},
  "help" -> {"\:5b9a\:578b\:696d\:52d9: \:4f7f\:3044\:65b9", "Routine work: how to use"}|>;
iSVSPWeakView[fname_String, args___] := If[iSVSPDefinedQ["SourceVault`" <> fname], Symbol[Identity["SourceVault`" <> fname]][args],
  Style[fname <> iSVSPL[" \:304c\:8aad\:307f\:8fbc\:307e\:308c\:3066\:3044\:307e\:305b\:3093\:3002", " is not loaded."], Gray]];
iSVSPMailFrom[] := DateObject[DateList[iSVSVNow[] - 86400.*SourceVault`$SourceVaultMailWorkWindow][[;; 3]]];
iSVSPView["proposals"] := SourceVault`SourceVaultMailTaskProposalsView[];
iSVSPView["agenda"] := iSVSPWeakView["SourceVaultRoutineAgendaView"];
iSVSPView["series"] := SourceVault`SourceVaultSeriesCandidatesView[];
iSVSPView["business"] := SourceVault`SourceVaultBusinessView[];
iSVSPView["mail-untracked"] := iSVSPWeakView["SourceVaultMailSearchIndexView", "", "Work" -> "Untracked", "DateFrom" -> iSVSPMailFrom[]];
iSVSPView["mail-open"] := iSVSPWeakView["SourceVaultMailSearchIndexView", "", "Work" -> "Open", "DateFrom" -> iSVSPMailFrom[]];
iSVSPView["status"] := iSVSPStatusView[];
iSVSPView["ledger"] := iSVSPLedgerView[];
iSVSPView["help"] := iSVSPHelpView[];
iSVSPOpen[key_String] := With[{t = Lookup[$iSVSPViews, key, {key, key}]}, iSVSPOpenWindow[key, iSVSPL @@ t, iSVSPView[key]]];

(* ---- the tree of one business / confirming a business: the name is asked in a dialog ---- *)
iSVSPConfirmedNames[] := Module[{d = Quiet @ Check[SourceVault`SeriesPrivate`iSVSRBusinessDefsNow[], <||>]},
  If[! AssociationQ[d], {}, (#["Name"] &) /@ Select[Values[Lookup[d, "Defs", <||>]], #["Status"] === "Confirmed" &]]];
iSVSPWords[s_] := If[! StringQ[s], {}, Select[StringTrim /@ StringSplit[s, "\:3001" | "," | "\:ff0c" | ";"], # =!= "" &]];
(* the body of the dialog (the mode and the names are written into it: it is typeset after this function has returned) *)
iSVSPAskBody[mode : ("Open" | "Confirm"), names_List] :=
    DynamicModule[{name = If[mode === "Open" && names =!= {}, First[names], ""], match = "", excl = ""},
      Column[{
        Style[If[mode === "Open", iSVSPL["\:696d\:52d9\:306e\:6728\:3092\:958b\:304f", "Open the tree of a business"], iSVSPL["\:696d\:52d9\:3092\:78ba\:5b9a\:3059\:308b", "Confirm a business"]], Bold, 13],
        Grid[{
          {iSVSPL["\:696d\:52d9\:306e\:540d\:524d", "Name"], InputField[Dynamic[name], String, FieldSize -> 28]},
          {iSVSPL["\:4ef6\:540d\:306e\:8a9e (\:7a7a\:306a\:3089\:540d\:524d)", "Word in the titles (empty: the name)"], InputField[Dynamic[match], String, FieldSize -> 28]},
          If[mode === "Confirm",
            {iSVSPL["\:9664\:304f\:8a9e (\:3001\:3067\:533a\:5207\:308b)", "Words that exclude titles (comma)"], InputField[Dynamic[excl], String, FieldSize -> 28]}, Nothing]},
          Alignment -> Left],
        If[names === {}, Nothing,
          Row[{Style[iSVSPL["\:78ba\:5b9a\:6e08\:307f\:306e\:696d\:52d9: ", "Confirmed: "], 10, Gray],
            ActionMenu[iSVSPL["\:9078\:3076", "Choose"], (# :> (name = #; match = "")) & /@ names]}]],
        Style[If[mode === "Open",
          iSVSPL["\:78ba\:5b9a\:3057\:3066\:3044\:306a\:3044\:540d\:524d\:3067\:3082\:3001\:305d\:306e\:8a9e\:3092\:4ef6\:540d\:306b\:542b\:3080\:30e1\:30fc\:30eb\:3067\:6728\:3092\:898b\:3089\:308c\:307e\:3059 (\:4f8b: \:540d\:524d\:300c\:5927\:5b66\:5165\:5b66\:5171\:901a\:30c6\:30b9\:30c8\:300d\:3001\:8a9e\:300c\:5171\:901a\:30c6\:30b9\:30c8\:300d)\:3002",
            "A name that is not confirmed shows the same tree from the word alone."],
          iSVSPL["\:4ef6\:540d\:306b\:3053\:306e\:8a9e\:3092\:542b\:3080\:30e1\:30fc\:30eb\:304c\:696d\:52d9\:306b\:5165\:308a\:307e\:3059\:3002\:78ba\:5b9a\:3059\:308b\:3068\:3001\:305d\:306e\:696d\:52d9\:306e\:65b0\:7740\:306f\:63d0\:6848\:306b\:4e0a\:304c\:308a\:3001\:300c\:4e88\:5b9a\:300d\:306e\:5e2f\:306b\:51fa\:307e\:3059\:3002",
            "Mails whose title carries the word belong to the business; its new mails are then proposed."]], 10, Gray],
        Row[{DefaultButton[If[mode === "Open", iSVSPL["\:958b\:304f", "Open"], iSVSPL["\:78ba\:5b9a\:3059\:308b", "Confirm"]],
            DialogReturn[<|"Name" -> name, "Match" -> match, "Exclude" -> excl|>]], "  ",
          CancelButton[iSVSPL["\:3084\:3081\:308b", "Cancel"], DialogReturn[$Canceled]]}]}, Spacings -> 0.9]];
iSVSPAskBusiness[mode : ("Open" | "Confirm")] :=
  DialogInput[iSVSPAskBody[mode, iSVSPConfirmedNames[]], WindowTitle -> iSVSPL["\:4e0a\:4f4d\:306e\:696d\:52d9", "Business"]];
(* the pure parts (what the dialog's answer leads to) *)
iSVSPTreeFrom[a_Association] := With[{n = StringTrim[ToString[Lookup[a, "Name", ""]]], m = StringTrim[ToString[Lookup[a, "Match", ""]]]},
  If[n === "", Missing["NoName"],
    iSVSPOpenWindow["business:" <> n, iSVSPL["\:696d\:52d9\:306e\:6728: ", "Business: "] <> n,
      If[m === "", SourceVault`SourceVaultBusinessView[n], SourceVault`SourceVaultBusinessView[n, "Match" -> m]]]]];
iSVSPConfirmFrom[a_Association] := Module[{n = StringTrim[ToString[Lookup[a, "Name", ""]]], m = StringTrim[ToString[Lookup[a, "Match", ""]]],
    x = iSVSPWords[Lookup[a, "Exclude", ""]], r},
  If[n === "", Return[Missing["NoName"]]];
  r = SourceVault`SourceVaultBusinessConfirm[n, Sequence @@ Join[If[m === "", {}, {"Match" -> m}], If[x === {}, {}, {"Exclude" -> x}]]];
  If[AssociationQ[r] && Lookup[r, "Status", ""] === "OK",
    iSVSVRefresh[];      (* the lists that are open are older now and say so *)
    iSVSPTreeFrom[<|"Name" -> r["Name"]|>],
    iSVSPSay[iSVSPL["\:696d\:52d9\:3092\:78ba\:5b9a\:3067\:304d\:307e\:305b\:3093\:3067\:3057\:305f", "The business could not be confirmed"], r]];
  r];
iSVSPBusinessOpen[] := With[{a = iSVSPAskBusiness["Open"]}, If[AssociationQ[a], iSVSPTreeFrom[a]]];
iSVSPBusinessConfirm[] := With[{a = iSVSPAskBusiness["Confirm"]}, If[AssociationQ[a], iSVSPConfirmFrom[a]]];

(* ---- the notebook the owner is working in: its business part and its related files, written again ---- *)
iSVSPRefreshNotebook[] := Module[{nb = Quiet @ InputNotebook[], r},
  If[Head[nb] =!= NotebookObject || nb === $iSVSPPalette,
    Return[iSVSPSay[iSVSPL["\:95a2\:9023\:3092\:66f4\:65b0\:3067\:304d\:307e\:305b\:3093\:3067\:3057\:305f", "Nothing was refreshed"],
      iSVSPL["\:30bf\:30b9\:30af\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:30af\:30ea\:30c3\:30af\:3057\:3066\:9078\:3093\:3067\:304b\:3089\:62bc\:3057\:3066\:304f\:3060\:3055\:3044\:3002", "Click the task notebook first."]]]];
  r = SourceVault`SourceVaultSeriesRelatedFilesRefresh[nb];
  iSVSPSay[If[AssociationQ[r] && Lookup[r, "Status", ""] === "OK", iSVSPL["\:3053\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:95a2\:9023 (\:4e0a\:4f4d\:306e\:696d\:52d9\:30fb\:95a2\:9023\:30d5\:30a1\:30a4\:30eb) \:3092\:66f8\:304d\:76f4\:3057\:307e\:3057\:305f",
      "The related part of this notebook was written again"], iSVSPL["\:95a2\:9023\:3092\:66f4\:65b0\:3067\:304d\:307e\:305b\:3093\:3067\:3057\:305f", "Nothing was refreshed"]], r]];

(* ---- the local models: the semantic comparison and the business labels ---- *)
iSVSPRunRefresh["Embed"] := With[{r = SourceVault`SourceVaultSeriesEmbedRefresh[]},
  iSVSVRefresh[]; iSVSPSay[iSVSPL["\:5185\:5bb9\:306e\:6bd4\:8f03 (\:30ed\:30fc\:30ab\:30eb\:306e\:57cb\:3081\:8fbc\:307f)", "Semantic comparison (local embeddings)"], r]];
iSVSPRunRefresh["Label"] := With[{r = SourceVault`SourceVaultSeriesLabelRefresh["TimeLimit" -> 240]},
  iSVSVRefresh[]; iSVSPSay[iSVSPL["\:696d\:52d9\:306e\:30e9\:30d9\:30eb (\:30ed\:30fc\:30ab\:30eb\:306e LLM)", "Business labels (local LLM)"], r]];

(* ---- status: counts, decisions, the local models, the ledger, and whether the loaded code is the code on disk ---- *)
iSVSPTime[a_] := If[NumberQ[a] && a > 0, DateString[a, {"Year", "/", "Month", "/", "Day", " ", "Hour24", ":", "Minute"}], "-"];
iSVSPFileLine[dir_, file_String, loadedAt_] := Module[{p, mod},
  If[! StringQ[dir], Return[Style[file <> iSVSPL[": \:8aad\:307f\:8fbc\:307f\:5143\:304c\:5206\:304b\:308a\:307e\:305b\:3093", ": the source is unknown"], Gray]]];
  p = FileNameJoin[{dir, file}];
  If[! FileExistsQ[p], Return[Style[file <> iSVSPL[": \:30d5\:30a1\:30a4\:30eb\:304c\:3042\:308a\:307e\:305b\:3093", ": no such file"], Gray]]];
  mod = Quiet @ Check[N[AbsoluteTime[FileDate[p, "Modification"]]], 0.];
  Row[{Style[file, Bold, 11], Style["   " <> iSVSPL["\:8aad\:307f\:8fbc\:307f ", "loaded "] <> iSVSPTime[loadedAt] <> iSVSPL[" \:30fb \:30d5\:30a1\:30a4\:30eb\:306e\:66f4\:65b0 ", " / file changed "] <>
      iSVSPTime[mod] <> "   ", 11],
    If[NumberQ[loadedAt] && mod > loadedAt + 2.,
      Style[iSVSPL["\:26a0 \:8aad\:307f\:8fbc\:307f\:306e\:5f8c\:3067\:30d5\:30a1\:30a4\:30eb\:304c\:66f4\:65b0\:3055\:308c\:3066\:3044\:307e\:3059 (\:8aad\:307f\:8fbc\:307f\:76f4\:3057\:3066\:304f\:3060\:3055\:3044)", "the file changed after it was loaded: load it again"],
        RGBColor[0.8, 0.3, 0.], Bold, 11],
      Style[iSVSPL["\:8aad\:307f\:8fbc\:3093\:3060\:3082\:306e\:304c\:6700\:65b0\:3067\:3059", "up to date"], Darker[Green], 11]]}]];
iSVSPStatusData[] := Module[{items, dec, biz, evs, gen},
  gen = Block[{SourceVault`SeriesPrivate`$iSVSRNoExit = True}, Quiet @ Check[SourceVault`SourceVaultSeriesGenericTitles[], {}]];
  If[! ListQ[gen], gen = {}];
  items = Block[{SourceVault`SeriesPrivate`$iSVSRNoExit = True}, Quiet @ Check[SourceVault`SourceVaultMailWorkItems[], <||>]];
  dec = Quiet @ Check[SourceVault`SourceVaultSeriesDecisions[], <||>];
  biz = Quiet @ Check[Lookup[SourceVault`SeriesPrivate`iSVSRBusinessDefsNow[], "Defs", <||>], <||>];
  evs = Quiet @ Check[SourceVault`SourceVaultMailWorkEvents[], {}];
  <|"Total" -> Lookup[items, "Total", 0], "Counts" -> Lookup[items, "Counts", <||>], "Window" -> SourceVault`$SourceVaultMailWorkWindow,
    "SeriesConfirmed" -> Count[dec, "Confirmed"], "SeriesRejected" -> Count[dec, "Rejected"],
    "Businesses" -> ((#["Name"] <> " (" <> #["Match"] <> ")") & /@ Select[Values[biz], #["Status"] === "Confirmed" &]),
    "BusinessesRejected" -> Count[Values[biz], _?(#["Status"] === "Rejected" &)],
    "GenericTitles" -> Length[gen], "GenericMails" -> Total[Lookup[gen, "Mails", 0]],
    "Embed" -> Quiet @ Check[SourceVault`SourceVaultSeriesEmbedStatus[], <||>],
    "Label" -> Quiet @ Check[SourceVault`SourceVaultSeriesLabelStatus[], <||>],
    "LedgerRoot" -> Quiet @ Check[SourceVault`SeriesPrivate`iSVSRWorkRoot[], $Failed], "Events" -> Length[evs],
    "LastEventAt" -> If[evs === {}, Missing["None"], Lookup[Last[evs], "AtAbs", Missing["None"]]]|>];
iSVSPStatusView[] := Module[{d = iSVSPStatusData[], lab, row, emb, lb},
  lab = Function[st, SourceVault`SeriesPrivate`iSVSRLabel[st] <> " " <> ToString[Lookup[d["Counts"], st, 0]]];
  row = Function[{k, v}, {Style[k, Bold, 11, GrayLevel[0.3]], v}];
  emb = d["Embed"]; lb = d["Label"];
  Column[{
    Style[iSVSPL["\:5b9a\:578b\:696d\:52d9 (\:30e1\:30fc\:30eb\:8d77\:70b9): \:72b6\:614b", "Routine work (from mail): status"], Bold, 14],
    Grid[{
      row[iSVSPL["\:4f5c\:696d\:9805\:76ee", "Work items"], Style[iSVSPL["\:76f4\:8fd1 ", "last "] <> ToString[d["Window"]] <> iSVSPL[" \:65e5: \:5168 ", " days: "] <> ToString[d["Total"]] <>
        iSVSPL[" \:4ef6   ", "   "] <> StringRiffle[lab /@ SourceVault`SeriesPrivate`$iSVSRStateOrder, " \:30fb "], 11]],
      row[iSVSPL["\:7cfb\:5217", "Series"], Style[iSVSPL["\:78ba\:5b9a ", "confirmed "] <> ToString[d["SeriesConfirmed"]] <> iSVSPL[" \:30fb \:5374\:4e0b ", " / rejected "] <>
        ToString[d["SeriesRejected"]] <> iSVSPL["   (\:4ef6\:540d\:306e\:578b\:306e\:6570)", "   (title patterns)"], 11]],
      row[iSVSPL["\:4e0a\:4f4d\:306e\:696d\:52d9", "Businesses"], Style[If[d["Businesses"] === {}, iSVSPL["\:78ba\:5b9a\:3057\:305f\:696d\:52d9\:306f\:3042\:308a\:307e\:305b\:3093", "none confirmed"],
        StringRiffle[d["Businesses"], iSVSPL["\:3001", ", "]]] <> If[d["BusinessesRejected"] > 0,
          iSVSPL["   \:30fb \:5374\:4e0b ", "   / rejected "] <> ToString[d["BusinessesRejected"]], ""], 11]],
      row[iSVSPL["\:540c\:5831\:306e\:4ef6\:540d", "Broadcast titles"], Style[ToString[Lookup[d, "GenericTitles", 0]] <> iSVSPL[" \:7a2e\:30fb", " titles, "] <>
        ToString[Lookup[d, "GenericMails", 0]] <> iSVSPL[" \:901a   (\:4ef6\:540d\:304c\:7528\:4ef6\:3092\:8868\:3055\:306a\:3044\:306e\:3067\:3001\:4ef6\:540d\:3067\:306f\:7cfb\:5217\:306b\:3057\:307e\:305b\:3093\:3002\:4e00\:89a7\:306f SourceVaultSeriesGenericTitles[])",
          " mails   (the title names no matter: not a series by its title; SourceVaultSeriesGenericTitles[] lists them)"], 11]],
      row[iSVSPL["\:5185\:5bb9\:306e\:6bd4\:8f03", "Comparison"], Style[If[! AssociationQ[emb] || emb === <||>, "-",
        Lookup[<|"Semantic" -> iSVSPL["\:610f\:5473 (\:30ed\:30fc\:30ab\:30eb\:306e\:57cb\:3081\:8fbc\:307f) \:3068\:8a9e\:306e\:4e00\:81f4", "by meaning (local embeddings) and words"],
            "Partial" -> iSVSPL["\:610f\:5473\:306f\:4e00\:90e8\:3060\:3051\:3001\:6b8b\:308a\:306f\:8a9e\:306e\:4e00\:81f4", "by meaning in part, the rest by words"],
            "Lexical" -> iSVSPL["\:8a9e\:306e\:4e00\:81f4 (\:57cb\:3081\:8fbc\:307f\:306f\:672a\:8a08\:7b97\:304b\:3001\:4f7f\:3063\:3066\:3044\:306a\:3044)", "by words (no embeddings)"]|>, Lookup[emb, "Mode", ""], "-"] <>
          With[{m = Lookup[emb, "Model", None]}, If[StringQ[m], iSVSPL["   \:30e2\:30c7\:30eb ", "   model "] <> m, ""]] <>
          iSVSPL["   \:4fdd\:5b58\:6e08\:307f\:306e\:30d9\:30af\:30c8\:30eb ", "   stored vectors "] <> ToString[Lookup[emb, "StoredVectors", 0]] <>
          If[TrueQ[Lookup[emb, "Available", True] === False], iSVSPL["   \:26a0 \:4f7f\:3048\:307e\:305b\:3093: ", "   unavailable: "] <> ToString[Lookup[emb, "Reason", ""]] <>
            "  " <> ToString[Lookup[emb, "Hint", ""]], ""]], 11]],
      row[iSVSPL["\:696d\:52d9\:306e\:30e9\:30d9\:30eb", "Labels"], Style[If[! AssociationQ[lb] || lb === <||>, "-",
        iSVSPL["\:4fdd\:5b58\:6e08\:307f\:306e\:30e9\:30d9\:30eb ", "stored labels "] <> ToString[Lookup[lb, "StoredLabels", 0]] <>
          If[TrueQ[Lookup[lb, "Available", True] === False], iSVSPL["   \:26a0 \:4f7f\:3048\:307e\:305b\:3093: ", "   unavailable: "] <> ToString[Lookup[lb, "Reason", ""]] <>
            "  " <> ToString[Lookup[lb, "Hint", ""]], ""]], 11]],
      row[iSVSPL["\:53f0\:5e33", "Ledger"], Style[ToString[d["Events"]] <> iSVSPL[" \:4ef6   \:6700\:5f8c\:306e\:8a18\:9332 ", " events   last "] <> iSVSPTime[d["LastEventAt"]] <>
        "   " <> If[StringQ[d["LedgerRoot"]], d["LedgerRoot"], iSVSPL["(\:7f6e\:304d\:5834\:304c\:6c7a\:307e\:3063\:3066\:3044\:307e\:305b\:3093)", "(no root)"]], 11]],
      row[iSVSPL["\:8aad\:307f\:8fbc\:3093\:3060\:30b3\:30fc\:30c9", "Loaded code"], Column[{
        iSVSPFileLine[SourceVault`SeriesPrivate`$iSVSRPackageDir, "SourceVault_series.wl", SourceVault`SeriesPrivate`$iSVSRLoadedAt],
        iSVSPFileLine[$iSVSVPackageDir, "SourceVault_seriesview.wl", $iSVSVLoadedAt]}, Spacings -> 0.3]]},
      Alignment -> {Left, Top}, Spacings -> {1.5, 0.9}, Dividers -> {None, {False, {GrayLevel[0.88]}, False}}],
    Style[iSVSPL["\:6570\:3068\:72b6\:614b\:3060\:3051\:3067\:3059 (\:4ef6\:540d\:30fb\:5dee\:51fa\:4eba\:30fb\:672c\:6587\:306f\:51fa\:3057\:307e\:305b\:3093)\:3002\:30d1\:30ec\:30c3\:30c8\:306e [\:72b6\:614b] \:3092\:3082\:3046\:4e00\:5ea6\:62bc\:3059\:3068\:4f5c\:308a\:76f4\:3057\:307e\:3059\:3002",
      "Counts and states only. Press the button again to make this afresh."], 10, Gray]}, Spacings -> 1]];

(* ---- the ledger: the owner's decisions, the newest first (ids, states, and the owner's names of businesses) ---- *)
$iSVSPLedgerMax = 200;
iSVSPLedgerTarget[e_Association] := iSVSVClip[StringRiffle[DeleteCases[{
    With[{b = Lookup[e, "BusinessId", Missing[]]}, If[StringQ[b], b <> With[{n = Lookup[e, "Name", Missing[]]}, If[StringQ[n], " " <> n, ""]] <>
      With[{m = Lookup[e, "Match", Missing[]]}, If[StringQ[m], " (" <> m <> ")", ""]], Nothing]],
    With[{s = Lookup[e, "SeriesId", Missing[]]}, If[StringQ[s], s, Nothing]],
    With[{s = Lookup[e, "SeriesIds", Missing[]]}, If[ListQ[s], StringRiffle[Select[s, StringQ], " + "], Nothing]],
    With[{r = Lookup[e, "RecordId", Missing[]]}, If[StringQ[r], r, Nothing]]}, ""], "   "], 70];
iSVSPLedgerView[] := Module[{evs = Quiet @ Check[SourceVault`SourceVaultMailWorkEvents[], {}], shown},
  If[! ListQ[evs], evs = {}];
  shown = Take[Reverse[evs], UpTo[$iSVSPLedgerMax]];
  Column[{
    Style[iSVSPL["\:5224\:65ad\:306e\:8a18\:9332 (\:53f0\:5e33) \:2015 \:65b0\:3057\:3044\:9806", "The ledger, newest first"], Bold, 14],
    Style[ToString[Length[evs]] <> iSVSPL[" \:4ef6", " events"] <> If[Length[evs] > Length[shown],
      iSVSPL[" (\:65b0\:3057\:3044 ", " (the newest "] <> ToString[Length[shown]] <> iSVSPL[" \:4ef6\:3092\:8868\:793a)", " shown)"], ""] <>
      iSVSPL["\:3002ID \:3068\:72b6\:614b\:3001\:6240\:6709\:8005\:304c\:4ed8\:3051\:305f\:696d\:52d9\:306e\:540d\:524d\:3060\:3051\:3092\:6301\:3061\:307e\:3059\:3002", ". Ids, states and the owner's names of businesses only."], 11, Gray],
    If[shown === {}, Style[iSVSPL["\:307e\:3060\:8a18\:9332\:306f\:3042\:308a\:307e\:305b\:3093\:3002", "Nothing recorded yet."], Gray],
      Pane[Grid[Prepend[
          {Style[iSVSPTime[Lookup[#, "AtAbs", 0.]], 11], Style[ToString[Lookup[#, "Type", "?"]], Bold, 11],
            Style[ToString[Lookup[#, "Actor", ""]], 11], Style[iSVSPLedgerTarget[#], 11],
            Style[StringRiffle[DeleteCases[ToString /@ {Lookup[#, "Via", Nothing], Lookup[#, "Reason", Nothing]}, ""], " "], 11, Gray],
            Style[ToString[Lookup[#, "Machine", ""]], 10, Gray]} & /@ shown,
          Style[#, Bold, 11, GrayLevel[0.3]] & /@ {iSVSPL["\:6642\:523b", "Time"], iSVSPL["\:7a2e\:985e", "Type"], iSVSPL["\:4e3b\:4f53", "Actor"],
            iSVSPL["\:5bfe\:8c61", "Target"], iSVSPL["\:624b\:6bb5\:30fb\:7406\:7531", "Via / reason"], iSVSPL["\:6a5f\:68b0", "Machine"]}],
          Alignment -> {Left, Center}, Spacings -> {1.3, 0.6}, BaseStyle -> {LineBreakWithin -> False},
          Dividers -> {None, {False, GrayLevel[0.6], {GrayLevel[0.9]}, False}}, Background -> {None, {GrayLevel[0.95], None}}],
        ImageSize -> {Full, UpTo[640]}, Scrollbars -> Automatic]]}, Spacings -> 0.8]];

(* ---- how to use: the usage messages of the functions behind the buttons ---- *)
$iSVSPHelpNames = {"ShowRoutineWorkPalette", "SourceVaultMailTaskProposalsView", "SourceVaultRoutineAgendaView", "SourceVaultSeriesCandidatesView",
  "SourceVaultBusinessView", "SourceVaultBusinessConfirm", "SourceVaultBusinessReject", "SourceVaultBusinessAddMail",
  "SourceVaultBusinessRemoveMail", "SourceVaultBusinessInfo", "SourceVaultBusinessDiscover", "SourceVaultSeriesRelatedFilesRefresh",
  "SourceVaultSeriesRelated", "SourceVaultSeriesRelatedFiles", "SourceVaultMailWorkItems", "SourceVaultMailWorkAct", "SourceVaultMailWorkAccept",
  "SourceVaultSeriesConfirm", "SourceVaultSeriesReject", "SourceVaultSeriesMerge", "SourceVaultSeriesDetach", "SourceVaultSeriesAddMail",
  "SourceVaultSeriesRemoveMail", "SourceVaultSeriesInfo", "SourceVaultSeriesAgendaItems", "SourceVaultSeriesEmbedRefresh",
  "SourceVaultSeriesEmbedStatus", "SourceVaultSeriesLabelRefresh", "SourceVaultSeriesLabelStatus", "SourceVaultMailWorkEvents"};
iSVSPUsage[name_String] := If[Names["SourceVault`" <> name] === {}, Missing["NoSymbol"],
  With[{sym = Symbol[Identity["SourceVault`" <> name]]}, With[{u = MessageName[sym, "usage"]}, If[StringQ[u], u, Missing["NoUsage"]]]]];
iSVSPHelpView[] := Column[{
  Style[iSVSPL["\:5b9a\:578b\:696d\:52d9 (\:30e1\:30fc\:30eb\:8d77\:70b9): \:4f7f\:3044\:65b9", "Routine work (from mail): how to use"], Bold, 14],
  Style[iSVSPL["\:30d1\:30ec\:30c3\:30c8\:306e\:30dc\:30bf\:30f3\:306f\:3001\:4e0b\:306e\:95a2\:6570\:3092\:547c\:3073\:307e\:3059\:3002\:3069\:308c\:3082\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3067\:305d\:306e\:307e\:307e\:8a55\:4fa1\:3067\:304d\:307e\:3059 (\:4e00\:89a7\:306e\:95a2\:6570\:306f View \:3067\:7d42\:308f\:308a\:307e\:3059)\:3002",
    "The buttons of the palette call the functions below; each can be evaluated in a notebook."], 11, Gray],
  Pane[Grid[({Style[#, Bold, 11, RGBColor[0.1, 0.3, 0.6]], Style[With[{u = iSVSPUsage[#]}, If[StringQ[u], u, iSVSPL["(\:8aad\:307f\:8fbc\:307e\:308c\:3066\:3044\:307e\:305b\:3093)", "(not loaded)"]]], 11]} &) /@
        $iSVSPHelpNames, Alignment -> {Left, Top}, Spacings -> {1.2, 0.9}, ItemSize -> {{21, 74}},
      Dividers -> {None, {False, {GrayLevel[0.9]}, False}}],
    ImageSize -> {Full, UpTo[660]}, Scrollbars -> Automatic]}, Spacings -> 0.8];

(* ---- the palette ---- *)
(* the colour and the tooltip are evaluated here (Button holds its options) *)
SetAttributes[{iSVSPButton, iSVSPButton2}, HoldRest];
iSVSPButton[label_, color_, action_, tip_ : ""] := With[{c = color, t = tip},
  With[{b = Button[Style[label, Bold, 10, White], iSVSPHold[action], Appearance -> "Frameless", Background -> c, ImageSize -> {110, 18},
      FrameMargins -> {{4, 4}, {1, 1}}, Method -> "Queued"]}, If[StringQ[t] && t =!= "", Tooltip[b, t], b]]];
iSVSPButton2[label_, color_, action_, tip_ : ""] := With[{c = color, t = tip},
  With[{b = Button[Style[label, Bold, 8, White], iSVSPHold[action], Appearance -> "Frameless", Background -> c, ImageSize -> {54, 18},
      FrameMargins -> {{1, 1}, {1, 1}}, Method -> "Queued"]}, If[StringQ[t] && t =!= "", Tooltip[b, t], b]]];
iSVSPButtonRow[b1_, b2_] := Grid[{{b1, b2}}, Spacings -> 0.1];
iSVSPSection[ja_, en_] := Style[iSVSPL[ja, en], Bold, 8, GrayLevel[0.3]];

iSVSPPaletteContent[] := Column[{
  Style[iSVSPL["\:5b9a\:578b\:696d\:52d9", "Routine Work"], Bold, 11, RGBColor[0.42, 0.2, 0.55]],

  iSVSPSection[" \:4e00\:89a7", " Lists"],
  iSVSPButton[iSVSPL["\:63d0\:6848\:30bf\:30b9\:30af", "Proposed tasks"], RGBColor[0.2, 0.4, 0.75], iSVSPOpen["proposals"],
    iSVSPL["\:30e1\:30fc\:30eb\:3092\:8d77\:70b9\:306b\:3057\:305f\:7528\:4ef6\:306e\:4e00\:89a7\:3002\:72b6\:614b (\:63d0\:6848\:4e2d\:30fb\:51e6\:7406\:4e2d\:30fb\:4fdd\:7559\:30fb\:6e08\:307f\:2026) \:3054\:3068\:306b\:7d5e\:308a\:3001\:8fd4\:4fe1\:30fb\:30ce\:30fc\:30c8\:30fbTodo\:30fb\:4fdd\:7559\:30fb\:5374\:4e0b\:30fb\:6e08\:3092\:8a18\:9332\:3059\:308b",
      "Every mail matter with its work state, and the owner's buttons"]],
  iSVSPButton[iSVSPL["\:4e88\:5b9a", "Agenda"], RGBColor[0.25, 0.5, 0.45], iSVSPOpen["agenda"],
    iSVSPL["\:4eca\:5f8c 7 \:65e5\:306e\:4e88\:5b9a\:3002\:78ba\:5b9a\:3057\:305f\:7cfb\:5217\:30fb\:696d\:52d9\:306e\:65b0\:7740\:30e1\:30fc\:30eb\:304c\:300c\:5b9a\:578b\:696d\:52d9\:306e\:65b0\:7740\:300d\:306e\:5e2f\:306b\:51fa\:308b", "The next 7 days, with the new mails of the confirmed series and businesses"]],
  iSVSPButtonRow[
    iSVSPButton2[iSVSPL["\:7cfb\:5217\:306e\:5019\:88dc", "Series"], RGBColor[0.45, 0.3, 0.6], iSVSPOpen["series"],
      iSVSPL["\:540c\:3058\:4ef6\:540d (\:3068\:5185\:5bb9\:306e\:8fd1\:3044\:4ef6\:540d) \:304c\:7e70\:308a\:8fd4\:3057\:5c4a\:304f\:3082\:306e\:306e\:5019\:88dc\:3002[\:7cfb\:5217\:306b\:3059\:308b] \:3067\:78ba\:5b9a", "Recurring title patterns; confirm or reject"]],
    iSVSPButton2[iSVSPL["\:4e0a\:4f4d\:306e\:696d\:52d9", "Businesses"], RGBColor[0.5, 0.25, 0.5], iSVSPOpen["business"],
      iSVSPL["\:4ef6\:540d\:306e\:9055\:3046\:591a\:304f\:306e\:30e1\:30fc\:30eb\:304c 1 \:5e74\:3092\:901a\:3057\:3066\:5c5e\:3059\:308b\:696d\:52d9 (\:78ba\:5b9a\:3057\:305f\:3082\:306e\:3068\:5019\:88dc)\:3002[\:6728\:3092\:958b\:304f] \:3067\:5e74\:5ea6\:3054\:3068\:306e\:6bb5\:968e", "Businesses (confirmed and candidates); their trees"]]],

  iSVSPSection[" \:30e1\:30fc\:30eb", " Mail"],
  iSVSPButtonRow[
    iSVSPButton2[iSVSPL["\:672a\:53cd\:6620", "Untracked"], RGBColor[0.3, 0.45, 0.65], iSVSPOpen["mail-untracked"],
      iSVSPL["\:30e1\:30fc\:30eb\:306e\:4e00\:89a7\:306e\:3046\:3061\:3001\:696d\:52d9\:306b\:307e\:3060\:53cd\:6620\:3057\:3066\:3044\:306a\:3044\:3082\:306e (\:63d0\:6848\:4e2d\:30fb\:518d\:63d0\:6848\:30fb\:672a\:5224\:5b9a)", "The mail list: not yet in the workflow"]],
    iSVSPButton2[iSVSPL["\:672a\:51e6\:7406", "Open"], RGBColor[0.3, 0.4, 0.6], iSVSPOpen["mail-open"],
      iSVSPL["\:30e1\:30fc\:30eb\:306e\:4e00\:89a7\:306e\:3046\:3061\:3001\:672a\:51e6\:7406\:306e\:3082\:306e (\:672a\:53cd\:6620\:306b\:3001\:51e6\:7406\:4e2d\:3068\:4fdd\:7559\:3092\:52a0\:3048\:305f\:3082\:306e)", "The mail list: open matters"]]],

  iSVSPSection[" \:696d\:52d9", " Business"],
  iSVSPButtonRow[
    iSVSPButton2[iSVSPL["\:6728\:3092\:958b\:304f\:2026", "Tree\:2026"], RGBColor[0.5, 0.3, 0.45], iSVSPBusinessOpen[],
      iSVSPL["\:696d\:52d9\:306e\:540d\:524d\:3092\:5165\:308c\:3066\:3001\:5e74\:5ea6 \:2192 \:6bb5\:968e\:306e\:6728\:3092\:958b\:304f (\:6628\:5e74\:5ea6\:306e\:6bb5\:968e\:3068\:4eca\:5e74\:5ea6\:306e\:9032\:307f)\:3002\:78ba\:5b9a\:3057\:3066\:3044\:306a\:3044\:540d\:524d\:3067\:3082\:898b\:3089\:308c\:308b",
        "Open the tree of a business by its name (also a name that is not confirmed)"]],
    iSVSPButton2[iSVSPL["\:78ba\:5b9a\:2026", "Confirm\:2026"], RGBColor[0.6, 0.3, 0.35], iSVSPBusinessConfirm[],
      iSVSPL["\:696d\:52d9\:3092\:540d\:524d\:3068\:4ef6\:540d\:306e\:8a9e\:3067\:78ba\:5b9a\:3059\:308b\:3002\:9664\:304f\:8a9e\:3082\:6307\:5b9a\:3067\:304d\:308b", "Confirm a business by its name and the word in its titles"]]],

  iSVSPSection[" \:30ce\:30fc\:30c8", " Notebook"],
  iSVSPButton[iSVSPL["\:95a2\:9023\:3092\:66f4\:65b0", "Refresh related"], RGBColor[0.3, 0.5, 0.42], iSVSPRefreshNotebook[],
    iSVSPL["\:3044\:307e\:4f7f\:3063\:3066\:3044\:308b\:30bf\:30b9\:30af\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:300c\:4e0a\:4f4d\:306e\:696d\:52d9\:300d\:3068\:300c\:95a2\:9023\:30d5\:30a1\:30a4\:30eb\:300d\:306e\:90e8\:5206\:3092\:66f8\:304d\:76f4\:3059", "Write the related part of the notebook in use again"]],

  iSVSPSection[" \:6bd4\:8f03 (\:30ed\:30fc\:30ab\:30eb)", " Compare (local)"],
  iSVSPButtonRow[
    iSVSPButton2[iSVSPL["\:6bd4\:8f03\:66f4\:65b0", "Embed"], RGBColor[0.4, 0.42, 0.55], iSVSPRunRefresh["Embed"],
      iSVSPL["\:4ef6\:540d\:3068\:6982\:8981\:3092\:30ed\:30fc\:30ab\:30eb\:306e\:57cb\:3081\:8fbc\:307f\:30e2\:30c7\:30eb\:3067\:30d9\:30af\:30c8\:30eb\:306b\:3059\:308b (\:7cfb\:5217\:306e\:7d50\:3073\:4ed8\:3051\:306b\:4f7f\:3046)\:3002\:521d\:56de\:306f\:6570\:5206\:3002\:30af\:30e9\:30a6\:30c9\:306b\:306f\:9001\:3089\:306a\:3044",
        "Embed the title patterns with the local model (minutes the first time)"]],
    iSVSPButton2[iSVSPL["\:30e9\:30d9\:30eb\:66f4\:65b0", "Labels"], RGBColor[0.42, 0.4, 0.5], iSVSPRunRefresh["Label"],
      iSVSPL["\:4ef6\:540d\:3068\:6982\:8981\:306b\:3001\:30ed\:30fc\:30ab\:30eb\:306e LLM \:3067\:696d\:52d9\:306e\:77ed\:3044\:540d\:524d\:3092\:4ed8\:3051\:308b\:30021 \:56de 4 \:5206\:307e\:3067\:3001\:7d9a\:304d\:306f\:3082\:3046\:4e00\:5ea6\:62bc\:3059\:3002\:30af\:30e9\:30a6\:30c9\:306b\:306f\:9001\:3089\:306a\:3044",
        "Label the title patterns with the local LLM (up to 4 minutes a run)"]]],

  iSVSPSection[" \:8a18\:9332", " Records"],
  iSVSPButtonRow[
    iSVSPButton2[iSVSPL["\:72b6\:614b", "Status"], RGBColor[0.4, 0.45, 0.4], iSVSPOpen["status"],
      iSVSPL["\:4ef6\:6570\:3001\:78ba\:5b9a\:3057\:305f\:7cfb\:5217\:3068\:696d\:52d9\:3001\:30ed\:30fc\:30ab\:30eb\:306e\:30e2\:30c7\:30eb\:306e\:72b6\:614b\:3001\:53f0\:5e33\:3001\:8aad\:307f\:8fbc\:3093\:3060\:30b3\:30fc\:30c9\:304c\:6700\:65b0\:304b\:3069\:3046\:304b", "Counts, decisions, local models, the ledger, loaded code"]],
    iSVSPButton2[iSVSPL["\:53f0\:5e33", "Ledger"], RGBColor[0.45, 0.42, 0.38], iSVSPOpen["ledger"],
      iSVSPL["\:6240\:6709\:8005\:306e\:5224\:65ad\:306e\:8a18\:9332\:3092\:65b0\:3057\:3044\:9806\:306b", "The owner's decisions, newest first"]]],
  iSVSPButton[iSVSPL["\:4f7f\:3044\:65b9", "How to use"], GrayLevel[0.45], iSVSPOpen["help"],
    iSVSPL["\:30dc\:30bf\:30f3\:304c\:547c\:3076\:95a2\:6570\:3068\:3001\:305d\:306e\:8aac\:660e", "The functions behind the buttons"]],
  Spacer[1]}, Alignment -> Center, Spacings -> 0];

SourceVault`ShowRoutineWorkPalette[] := (
  If[MatchQ[$iSVSPPalette, _NotebookObject], Quiet @ NotebookClose[$iSVSPPalette]];
  $iSVSPPalette = Quiet @ CreatePalette[iSVSPPaletteContent[],
    WindowTitle -> "Routine Work",
    WindowSize -> {105, All},   (* the same as the Claude Code / Documentation / System Doctor palettes, next to them *)
    WindowFloating -> True,
    WindowClickSelect -> False,
    WindowMargins -> {{Automatic, 331}, {Automatic, 4}},
    Saveable -> False];
  $iSVSPPalette);

(* ---------------- the related files part of a task notebook ---------------- *)

(* the mail a task notebook belongs to: the MailRecordId of its status cell (read by the mail agenda layer, non-evaluating) *)
iSVSVNotebookRid[path_String] := If[Length[DownValues[SourceVault`MailAgendaPrivate`iSVMARecordIdFromNotebook]] > 0,
  Quiet @ Check[SourceVault`MailAgendaPrivate`iSVMARecordIdFromNotebook[path], Missing["Unreadable"]], Missing["MailAgendaUnavailable"]];
iSVSVSamePathQ[a_, b_] := StringQ[a] && StringQ[b] &&
  SourceVault`SeriesPrivate`iSVSRNormPath[a] === SourceVault`SeriesPrivate`iSVSRNormPath[b];
iSVSVOpenNotebook[path_String] := If[TrueQ[$Notebooks],
  SelectFirst[Quiet @ Check[Notebooks[], {}], iSVSVSamePathQ[Quiet @ Check[NotebookFileName[#], $Failed], path] &, Missing["NotOpen"]],
  Missing["NoFrontEnd"]];

Options[SourceVault`SourceVaultSeriesRelatedFilesRefresh] = Options[SourceVault`SourceVaultSeriesRelatedFiles];
SourceVault`SourceVaultSeriesRelatedFilesRefresh[target_, rid0 : (_String | Automatic) : Automatic, opts : OptionsPattern[]] := Module[
  {actor = SourceVault`SeriesPrivate`iSVSRActor[], nb = Missing[], path, rid = rid0, rf, rel, cells, ok,
   tag = SourceVault`SeriesPrivate`$iSVSRRelTag, mtag = SourceVault`SeriesPrivate`$iSVSRRelMailTag},
  If[! SourceVault`SeriesPrivate`iSVSROwnerActorQ[actor], Return[<|"Status" -> "Refused", "Reason" -> "OwnerOnly", "Actor" -> actor|>]];
  Which[
    Head[target] === NotebookObject, nb = target; path = Quiet @ Check[NotebookFileName[nb], $Failed],
    StringQ[target], path = target; nb = iSVSVOpenNotebook[path],
    True, Return[<|"Status" -> "Failed", "Reason" -> "expects a notebook (NotebookObject or path)"|>]];
  If[! StringQ[path], Return[<|"Status" -> "Failed", "Reason" -> "NotebookNotSaved",
    "Hint" -> "\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:4fdd\:5b58\:3057\:3066\:304b\:3089\:5b9f\:884c\:3057\:3066\:304f\:3060\:3055\:3044 (\:4fdd\:5b58\:5148\:306e\:30d5\:30a9\:30eb\:30c0\:304c\:3001\:3053\:306e\:696d\:52d9\:306e\:30d5\:30a9\:30eb\:30c0\:3068\:3057\:3066\:8aad\:307e\:308c\:307e\:3059)\:3002"|>]];
  If[! StringQ[rid], rid = iSVSVNotebookRid[path]];
  If[! StringQ[rid], Return[<|"Status" -> "Failed", "Reason" -> "NoMailLink",
    "Hint" -> "\:3053\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306b\:306f\:30e1\:30fc\:30eb\:3078\:306e\:30ea\:30f3\:30af (\:72b6\:614b\:30bb\:30eb\:306e MailRecordId) \:304c\:3042\:308a\:307e\:305b\:3093\:3002\:30e1\:30fc\:30eb\:306e RecordId \:3092 2 \:756a\:76ee\:306e\:5f15\:6570\:306b\:6e21\:3057\:3066\:304f\:3060\:3055\:3044\:3002"|>]];
  rf = Block[{SourceVault`SeriesPrivate`$iSVSRNoExit = True},
    Quiet @ Check[SourceVault`SourceVaultSeriesRelatedFiles[rid, "NotebookPath" -> path,
      Sequence @@ DeleteCases[Flatten[{opts}], "NotebookPath" -> _]], $Failed]];
  If[! (AssociationQ[rf] && Lookup[rf, "Status", ""] === "OK"),
    Return[<|"Status" -> "Failed", "Reason" -> "RelatedFilesFailed", "Result" -> rf|>]];
  (* the related mails too (the larger business, the earlier occurrences): written again with the files *)
  rel = Block[{SourceVault`SeriesPrivate`$iSVSRNoExit = True},
    Quiet @ Check[SourceVault`SourceVaultSeriesRelated[rid,
      Sequence @@ FilterRules[Flatten[{opts}], Options[SourceVault`SourceVaultSeriesRelated]]], <||>]];
  cells = Join[
    If[AssociationQ[rel] && Lookup[rel, "Status", ""] === "OK",
      SourceVault`SeriesPrivate`iSVSRTagCells[SourceVault`SeriesPrivate`iSVSRRelatedCells[rel], mtag], {}],
    SourceVault`SeriesPrivate`iSVSRRelatedFileCells[rf, rid]];
  ok = If[Head[nb] === NotebookObject,
    (* the notebook is open: change it through the front end (the file is the front end's to save). The cells are taken
       out and written through NBAccess (2026-11-18: no direct access to cells outside NBAccess; the cells that are
       written get the marks of the notebook from NBAccess). Success = the part is in the notebook afterwards *)
    If[Length[DownValues[NBAccess`NBWriteCell]] > 0,
      Quiet @ Check[
        NBAccess`NBDeleteCellsByTag[nb, mtag]; NBAccess`NBDeleteCellsByTag[nb, tag];
        NBAccess`NBInvalidateCellsCache[nb];
        NBAccess`NBMoveToEnd[nb];
        Scan[NBAccess`NBWriteCell[nb, #, After] &, cells];
        NBAccess`NBInvalidateCellsCache[nb];
        cells === {} || Length[Replace[NBAccess`NBCellIndicesByTag[nb, tag], Except[_List] -> {}]] > 0, False],
      False],
    SourceVault`SeriesPrivate`iSVSRReplaceTaggedCells[path, {mtag, tag}, cells]];
  <|"Status" -> If[TrueQ[ok], "OK", "Failed"], "RecordId" -> rid, "Count" -> Lookup[rf, "Count", 0],
    "Groups" -> ((#["Group"] -> Length[#["Files"]]) & /@ Lookup[rf, "Groups", {}]), "Notes" -> Lookup[rf, "Notes", {}],
    "Where" -> If[Head[nb] === NotebookObject, "FrontEnd", "File"]|>];
SourceVault`SourceVaultSeriesRelatedFilesRefresh[___] :=
  <|"Status" -> "Failed", "Reason" -> "expects [notebook] or [notebook, recordId_String]"|>;

(* ---------------- privacy contracts ---------------- *)

Quiet @ Check[
  If[Length[DownValues[SourceVault`SourceVaultRegisterPrivacyContract]] > 0,
    Scan[SourceVault`SourceVaultRegisterPrivacyContract[#,
        <|"Class" -> "Private", "Exit" -> "View", "Sources" -> {"mail"}, "Module" -> "SourceVault_seriesview.wl"|>] &,
      {"SourceVaultMailTaskProposalsView", "SourceVaultSeriesCandidatesView", "SourceVaultBusinessView"}];
    (* returns counts and a status only; what it writes goes into the owner's own task notebook *)
    (* opens a button palette; the views it opens carry their own contracts *)
    SourceVault`SourceVaultRegisterPrivacyContract["ShowRoutineWorkPalette",
      <|"Class" -> "Internal", "Exit" -> "None", "Sources" -> {"mail"}, "Module" -> "SourceVault_seriesview.wl",
        "Note" -> "a button palette; its status / ledger windows show counts, ids and the owner's names of businesses only"|>];
    SourceVault`SourceVaultRegisterPrivacyContract["SourceVaultSeriesRelatedFilesRefresh",
      <|"Class" -> "Internal", "Exit" -> "None", "Sources" -> {"mail"}, "Module" -> "SourceVault_seriesview.wl",
        "Note" -> "status and counts only"|>]], Null];

End[];
EndPackage[];
