(* ::Package:: *)

(* SourceVault_taskdates.wl -- the three dates of a work note: Deadline, Eventdate, NextReview (2026-11-20).
   GENERATED from test codes/_taskdates_drafts/SourceVault_taskdates_draft.wl by
   test codes/_llmdefense_handoff_20261114/to_ascii_wl.py (edit the draft, then convert; the ASCII file is overwritten).

   Owner, 2026-11-20: the header of a work notebook made from a mail held only NextReview
     <|"Keywords" -> {"mail"}, "NextReview" -> Quantity[1, "Weeks"], "Status" -> "Todo", "Title" -> ..., "MailRecordId" -> ...|>
   The owner's own notes carry
     "Deadline"  -- when the work has an actual deadline,
     "Eventdate" -- when the note is about an event (a meeting, a conference),
     "NextReview"-- when to look at the note again,
   e.g. "Deadline" -> DateObject[{2023, 12, 2}], "Eventdate" -> DateObject[{2023, 12, 2}], "NextReview" -> DateObject[{2023, 12, 1}].
   These three dates are what the agenda ("\:4eca\:65e5\:306e\:4e88\:5b9a") and the reminders work from, so every place that makes a work note
   or a todo should extract Deadline and Eventdate as well as it can and write all three.

   This module is the one place that does it (pure functions; no FE, no LLM, no network):
     SourceVaultTaskDateCandidates[text, ref] -- the dates written in a text, each with its role (Deadline / Event / Unknown)
                                                 read from the words next to it ("\:307e\:3067\:306b" / "\:958b\:50ac")
     SourceVaultTaskDates[spec]               -- the three dates of a work note from its title, summary, body and the
                                                 deadline the mail classification found
     SourceVaultTaskHeaderString[assoc]       -- the status header as editable input text, in the owner's key order
     SourceVaultTaskDatesBackfill[opts]       -- the open notes of $onWork that lack the dates: plan (DryRun) or write
     SourceVaultTaskDatesProbe[]              -- the SystemDoctor probe (counts only): notes whose dates are missing
                                                 although their titles state them, and open notes past their dates
   The key is written "Eventdate" (the owner's spelling: 10 notes of $onWork / $offWork, against 1 "EventDate");
   readers accept both. *)

BeginPackage["SourceVault`"];

SourceVaultTaskDateCandidates::usage =
  "SourceVaultTaskDateCandidates[text, ref] \:306f\:3001text \:306b\:66f8\:304b\:308c\:305f\:65e5\:4ed8\:3092\:3001\:66f8\:304b\:308c\:305f\:9806\:306b\:8fd4\:3059\:3002\:5404\:884c\:306f <|\"Date\" -> DateObject[{y, m, d}], \"Role\", \"HasTime\", \"Weekday\", \"Position\"|>\:3002\
\"Role\" \:306f\:524d\:5f8c\:306e\:8a9e\:3067\:6c7a\:3081\:308b: \"Deadline\" (\:300c\:307e\:3067\:300d\:300c\:7de0\:5207\:300d\:300c\:3006\:5207\:300d\:300c\:671f\:9650\:300d\:300c\:5fc5\:7740\:300d\:300c\:63d0\:51fa\:300d\:300c\:56de\:7b54\:300d\:300c\:7533\:8fbc\:300d)\:3001\"Event\" (\:300c\:958b\:50ac\:300d\:300c\:5b9f\:65bd\:300d\:300c\:4f1a\:8b70\:300d\:300c\:8aac\:660e\:4f1a\:300d\:300c\:7814\:4fee\:300d\:300c\:7814\:7a76\:4f1a\:300d\:300c\:65e5\:6642\:300d\:306a\:3069\:3001\
\:307e\:305f\:306f\:6642\:523b\:304c\:7d9a\:304f)\:3001\:3069\:3061\:3089\:3067\:3082\:306a\:3051\:308c\:3070 \"Unknown\"\:3002\:524d\:5f8c\:306e\:8a9e\:306f\:3001\:96a3\:306e\:65e5\:4ed8\:3068\:6587\:306e\:5207\:308c\:76ee (\:3002\:30fb\:6539\:884c) \:3067\:533a\:5207\:308b\:3002\
\:8aad\:3080\:66f8\:304d\:65b9: 2026\:5e7411\:670820\:65e5\:30fb2026/11/20\:30fb\:4ee4\:548c8\:5e7411\:670820\:65e5\:30fb20261120\:30fb11\:670820\:65e5\:30fb11/20(\:91d1)\:3002\:5e74\:306e\:7121\:3044\:65e5\:4ed8\:306f ref (\:30e1\:30fc\:30eb\:306e\:65e5\:4ed8\:306a\:3069\:3002\:65e2\:5b9a\:306f\:4eca\:65e5) \:306b\:6700\:3082\:8fd1\:3044\:5e74\:306b\:3059\:308b\:3002";
SourceVaultTaskDates::usage =
  "SourceVaultTaskDates[spec, opts] \:306f\:3001\:4f5c\:696d\:30ce\:30fc\:30c8 (\:3084 todo) \:306e 3 \:3064\:306e\:65e5\:4ed8\:3092\:8fd4\:3059: <|\"Deadline\", \"Eventdate\", \"NextReview\", \"Basis\"|>\:3002\
spec \:306e\:30ad\:30fc: \"Title\" (\:4ef6\:540d)\:3001\"Summary\"\:3001\"Body\"\:3001\"Deadline\" (\:30e1\:30fc\:30eb\:306e\:5206\:985e\:304c\:6c42\:3081\:305f\:3006\:5207\:306a\:3069\:3001\:660e\:793a\:306e\:5024\:3002DateObject \:304b \"yyyy-mm-dd\")\:3001\
\"Eventdate\" (\:660e\:793a\:306e\:958b\:50ac\:65e5\:3002\:5b9a\:578b\:696d\:52d9\:306e\:30a4\:30d9\:30f3\:30c8\:306a\:3069)\:3001\"ReferenceDate\" (\:30e1\:30fc\:30eb\:306e\:65e5\:4ed8\:3002\:65e2\:5b9a\:306f\:4eca\:65e5)\:3002\
Deadline \:306f \:660e\:793a\:306e\:5024 \:2192 \:4ef6\:540d\:306e\:3006\:5207 \:2192 \:6982\:8981\:30fb\:672c\:6587\:306e\:3006\:5207 \:306e\:9806\:3002Eventdate \:306f \:660e\:793a\:306e\:5024 \:2192 \:4ef6\:540d\:306e\:958b\:50ac\:65e5 \:2192 \:6982\:8981\:30fb\:672c\:6587\:306e\:958b\:50ac\:65e5 \:306e\:9806\:3002\:57fa\:6e96\:306e\:65e5\:3088\:308a\:524d\:306e\:65e5\:4ed8\:306f\:63a1\:3089\:306a\:3044\:3002\
\:3006\:5207\:304c\:7121\:304f\:958b\:50ac\:65e5\:304c\:3042\:308b\:3068\:304d\:306f\:3001Deadline \:3082\:958b\:50ac\:65e5\:306b\:3059\:308b (\:6240\:6709\:8005\:306e\:30ce\:30fc\:30c8\:306e\:66f8\:304d\:65b9\:3002$SourceVaultTaskDeadlineFromEvent)\:3002\
NextReview \:306f\:3001\:4eca\:65e5\:4ee5\:964d\:306e Deadline \:3068 Eventdate \:306e\:3046\:3061\:65e9\:3044\:65b9\:306e $SourceVaultTaskReviewLeadDays \:65e5\:524d (\:4eca\:65e5\:3088\:308a\:524d\:306a\:3089\:4eca\:65e5)\:3002\:3069\:3061\:3089\:3082\:7121\:3051\:308c\:3070 Quantity[1, \"Weeks\"]\:3002\
\:5024\:306f DateObject[{y, m, d}]\:3002\:898b\:3064\:304b\:3089\:306a\:3044\:65e5\:4ed8\:306f Missing\:3002\"Basis\" \:306f\:305d\:308c\:305e\:308c\:306e\:51fa\:3069\:3053\:308d\:3002";
SourceVaultTaskHeaderString::usage =
  "SourceVaultTaskHeaderString[assoc] \:306f\:3001\:4f5c\:696d\:30ce\:30fc\:30c8\:306e\:72b6\:614b\:306e\:30d8\:30c3\:30c0\:30fc (NotebookStatus \:306e\:30bb\:30eb) \:3092\:3001\:7de8\:96c6\:3067\:304d\:308b\:5165\:529b\:306e\:6587\:5b57\:5217\:306b\:3059\:308b\:3002\
\:30ad\:30fc\:306e\:9806\:306f Keywords, Deadline, Eventdate, NextReview, Status, Title, \:305d\:306e\:4ed6 (\:6e21\:3057\:305f\:9806)\:3002DateObject \:306f DateObject[{y, m, d}] \:306e\:5f62\:3001Missing \:3068 None \:306e\:30ad\:30fc\:306f\:66f8\:304b\:306a\:3044\:3002";
SourceVaultTaskDatesBackfill::usage =
  "SourceVaultTaskDatesBackfill[opts] \:306f\:3001$onWork \:306e\:672a\:51e6\:7406\:306e\:30ce\:30fc\:30c8\:306e\:3046\:3061 Deadline\:30fbEventdate \:304c\:7121\:3044\:3082\:306e (\:3084 NextReview \:304c\:65e2\:5b9a\:306e\:76f8\:5bfe\:5024\:306e\:3082\:306e) \:306b\:3001\
\:984c\:540d\:3068\:5143\:306e\:30e1\:30fc\:30eb (\:72b6\:614b\:306e\:30bb\:30eb\:306e MailRecordId \:304c\:3042\:308c\:3070\:3001\:7d22\:5f15\:306e\:4ef6\:540d\:30fb\:6982\:8981\:30fb\:3006\:5207) \:304b\:3089\:65e5\:4ed8\:3092\:6c42\:3081\:3066\:66f8\:304d\:8db3\:3059\:3002\:65e2\:5b9a\:306f \"DryRun\" -> True (\:66f8\:304b\:305a\:306b\:6848\:3092\:8fd4\:3059)\:3002\
\"DryRun\" -> False \:3067 NBAccess`NBFileSetStatusFields \:306b\:3088\:308a\:66f8\:304f (FE \:3067\:958b\:3044\:3066\:3044\:308b\:30ce\:30fc\:30c8\:306f\:66f8\:304b\:305a \"NotebookIsOpen\" \:3068\:8fd4\:3059)\:3002\
\:65e2\:306b\:3042\:308b Deadline\:30fbEventdate \:306f\:66f8\:304d\:63db\:3048\:306a\:3044\:3002\:6240\:6709\:8005\:306e\:64cd\:4f5c\:3002";
SourceVaultTaskDatesProbe::usage =
  "SourceVaultTaskDatesProbe[] \:306f SystemDoctor \:306e\:691c\:67fb (\"TaskDates\")\:3002$onWork \:306e\:672a\:51e6\:7406\:306e\:30ce\:30fc\:30c8\:306b\:3064\:3044\:3066\:3001\:984c\:540d\:306b\:65e5\:4ed8\:304c\:66f8\:304b\:308c\:3066\:3044\:308b\:306e\:306b Deadline \:3082 Eventdate \:3082\:7121\:3044\:3082\:306e (\"DatesMissing\") \:3068\:3001\
Deadline \:304b Eventdate \:3092\:904e\:304e\:3066\:3082\:672a\:51e6\:7406\:306e\:3082\:306e (\"PastOpen\") \:3092\:6570\:3048\:308b\:3002\:984c\:540d\:3084\:30d1\:30b9\:306f\:8fd4\:3055\:306a\:3044 (\:4ef6\:6570\:3068\:30d5\:30a1\:30a4\:30eb\:306e\:8981\:7d04\:5024\:3060\:3051)\:3002DatesMissing \:304c\:3042\:308c\:3070 Degraded\:3002";
$SourceVaultTaskReviewLeadDays::usage =
  "$SourceVaultTaskReviewLeadDays: NextReview \:3092 Deadline\:30fbEventdate \:306e\:4f55\:65e5\:524d\:306b\:3059\:308b\:304b (\:65e2\:5b9a 1)\:3002";
$SourceVaultTaskDeadlineFromEvent::usage =
  "$SourceVaultTaskDeadlineFromEvent: \:3006\:5207\:304c\:898b\:3064\:304b\:3089\:305a\:958b\:50ac\:65e5\:304c\:3042\:308b\:3068\:304d\:3001Deadline \:3092\:958b\:50ac\:65e5\:306b\:3059\:308b\:304b (\:65e2\:5b9a True\:3002\:6240\:6709\:8005\:306e\:30ce\:30fc\:30c8\:306e\:66f8\:304d\:65b9)\:3002";

Begin["`TaskDatesPrivate`"];

If[! IntegerQ[$SourceVaultTaskReviewLeadDays], $SourceVaultTaskReviewLeadDays = 1];
If[! BooleanQ[$SourceVaultTaskDeadlineFromEvent], $SourceVaultTaskDeadlineFromEvent = True];

iSVTKNFKC[s_String] := With[{r = Quiet @ Check[CharacterNormalize[s, "NFKC"], s]}, If[StringQ[r], r, s]];
iSVTKNFKC[_] := "";

(* ---------------- dates ---------------- *)
iSVTKDaysIn[y_Integer, m_Integer] := Switch[m, 2, If[Mod[y, 4] == 0 && (Mod[y, 100] != 0 || Mod[y, 400] == 0), 29, 28],
  4 | 6 | 9 | 11, 30, _, 31];
iSVTKYMDQ[{y_Integer, m_Integer, d_Integer}] := 1990 <= y <= 2100 && 1 <= m <= 12 && 1 <= d <= iSVTKDaysIn[y, m];
iSVTKYMDQ[_] := False;
(* a day as an absolute time (midnight) *)
iSVTKDayAbs[{y_, m_, d_}] := N[AbsoluteTime[{y, m, d}]];
iSVTKToday[] := N[AbsoluteTime[Take[DateList[], 3]]];
(* anything that names a day -> {y, m, d}, or Missing *)
iSVTKYMD[x_] := Module[{m},
  Which[
    DateObjectQ[x], Take[DateList[x], 3],
    NumberQ[x], Take[DateList[x], 3],
    ListQ[x] && Length[x] >= 3 && AllTrue[Take[x, 3], NumberQ], Round /@ Take[x, 3],
    StringQ[x],
      m = StringCases[iSVTKNFKC[x], RegularExpression["(\\d{4})\\s*[-/.\:5e74]\\s*(\\d{1,2})\\s*[-/.\:6708]\\s*(\\d{1,2})"] :> {"$1", "$2", "$3"}, 1];
      If[m === {}, Missing["NoDate"], With[{v = FromDigits /@ First[m]}, If[iSVTKYMDQ[v], v, Missing["NoDate"]]]],
    True, Missing["NoDate"]]];
iSVTKDateObject[ymd : {_Integer, _Integer, _Integer}] := DateObject[ymd];
(* a month and a day without a year: the year that puts the date nearest to the reference *)
iSVTKNearest[m_Integer, d_Integer, ref_?NumberQ] := Module[{y0 = First[DateList[ref]], cands},
  cands = Select[{{y0, m, d}, {y0 + 1, m, d}, {y0 - 1, m, d}}, iSVTKYMDQ];
  If[cands === {}, Missing["NoDate"], First[SortBy[cands, Abs[iSVTKDayAbs[#] - ref] &]]]];

(* The forms, the full ones first. Each match is masked (replaced by spaces of the same length) before the next form is
   tried, so that "2026\:5e7411\:670820\:65e5" is not read again as "11\:670820\:65e5". *)
$iSVTKForms = {
  {RegularExpression["\:4ee4\:548c\\s*(\\d{1,2}|\:5143)\\s*\:5e74\\s*(\\d{1,2})\\s*\:6708\\s*(\\d{1,2})\\s*\:65e5"],
    Function[{g, ref}, {2018 + If[g[[1]] === "\:5143", 1, FromDigits[g[[1]]]], FromDigits[g[[2]]], FromDigits[g[[3]]]}]},
  {RegularExpression["(?<!\\d)(\\d{4})\\s*\:5e74\\s*(\\d{1,2})\\s*\:6708\\s*(\\d{1,2})\\s*\:65e5"], Function[{g, ref}, FromDigits /@ g]},
  {RegularExpression["(?<!\\d)(\\d{4})[/.\\-](\\d{1,2})[/.\\-](\\d{1,2})(?!\\d)"], Function[{g, ref}, FromDigits /@ g]},
  {RegularExpression["(?<!\\d)(20\\d{2})(\\d{2})(\\d{2})(?!\\d)"], Function[{g, ref}, FromDigits /@ g]},
  {RegularExpression["(?<!\\d)(\\d{1,2})\\s*\:6708\\s*(\\d{1,2})\\s*\:65e5"], Function[{g, ref}, iSVTKNearest[FromDigits[g[[1]]], FromDigits[g[[2]]], ref]]},
  {RegularExpression["(?<![\\d/])(\\d{1,2})/(\\d{1,2})(?=\\s*\\(?[\:6708\:706b\:6c34\:6728\:91d1\:571f\:65e5][)\:66dc]|\\s*\\d{1,2}[:\:6642])"],
    Function[{g, ref}, iSVTKNearest[FromDigits[g[[1]]], FromDigits[g[[2]]], ref]]}};

(* the words next to a date that tell what it is *)
$iSVTKDeadlineAfter = {"\:307e\:3067", "\:8fc4", "\:7de0\:5207", "\:7de0\:3081\:5207", "\:3006\:5207", "\:3006", "\:5fc5\:7740", "\:671f\:9650", "\:63d0\:51fa", "\:56de\:7b54", "\:7533\:8fbc", "\:7533\:3057\:8fbc", "\:53d7\:4ed8\:7d42\:4e86", "\:53b3\:5b88"};
$iSVTKDeadlineBefore = {"\:7de0\:5207", "\:7de0\:3081\:5207\:308a", "\:3006\:5207", "\:3006", "\:671f\:9650", "\:63d0\:51fa\:65e5", "\:56de\:7b54\:65e5", "\:5fc5\:7740", "deadline", "due"};
$iSVTKEventWords = {"\:958b\:50ac", "\:5b9f\:65bd", "\:4f1a\:8b70", "\:6559\:6388\:4f1a", "\:59d4\:54e1\:4f1a", "\:8aac\:660e\:4f1a", "\:7814\:4fee", "\:8b1b\:6f14", "\:8b1b\:7fd2", "\:30bb\:30df\:30ca\:30fc", "\:30b7\:30f3\:30dd\:30b8\:30a6\:30e0", "\:7814\:7a76\:4f1a",
  "\:5927\:4f1a", "\:5b66\:4f1a", "\:5e74\:6b21", "\:5f0f\:5178", "\:5165\:5b66\:5f0f", "\:5352\:696d\:5f0f", "\:6388\:4e0e\:5f0f", "\:8a66\:9a13", "\:9762\:63a5", "\:65e5\:6642", "\:884c\:4e8b", "\:61c7\:89aa\:4f1a", "\:65b0\:5e74\:4f1a", "\:5fd8\:5e74\:4f1a", "\:6b53\:8fce\:4f1a",
  "\:9001\:5225\:4f1a", "\:795d\:8cc0\:4f1a", "\:7dcf\:4f1a", "\:4f8b\:4f1a", "\:30aa\:30ea\:30a8\:30f3\:30c6\:30fc\:30b7\:30e7\:30f3", "\:30ac\:30a4\:30c0\:30f3\:30b9", "\:96c6\:4f1a", "\:30df\:30fc\:30c6\:30a3\:30f3\:30b0",
  "\:6253\:3061\:5408\:308f\:305b", "\:6253\:5408\:305b", "\:898b\:5b66", "\:8a2a\:554f", "\:51fa\:5f35", "\:767a\:8868", "\:958b\:8b1b", "\:516c\:6f14", "conference", "meeting", "workshop", "seminar", "symposium"};
$iSVTKTimeRx = RegularExpression["^\\s*(?:\\(?[\:6708\:706b\:6c34\:6728\:91d1\:571f\:65e5]\\)?)?\\s*(?:\:5348\:524d|\:5348\:5f8c)?\\s*\\d{1,2}\\s*[:\:6642]"];
$iSVTKWeekdayRx = RegularExpression["^\\s*\\(?[\:6708\:706b\:6c34\:6728\:91d1\:571f\:65e5](?:\:66dc\:65e5?)?\\)?"];

(* the text of a window, cut at a sentence end (All keeps the empty piece when the window begins / ends with one) *)
iSVTKCutAfter[s_String] := First[StringSplit[s, {"\:3002", "\n", "\:ff0e"}, All], ""];
iSVTKCutBefore[s_String] := Last[StringSplit[s, {"\:3002", "\n", "\:ff0e"}, All], ""];
iSVTKRole[before_String, after_String, hasTime_] := Module[{a = ToLowerCase[StringTake[after, UpTo[16]]], b = ToLowerCase[StringTake[before, -Min[12, StringLength[before]]]]},
  Which[
    StringContainsQ[a, $iSVTKDeadlineAfter] || StringContainsQ[b, $iSVTKDeadlineBefore], "Deadline",
    StringContainsQ[a, $iSVTKEventWords] || StringContainsQ[b, $iSVTKEventWords], "Event",
    TrueQ[hasTime], "Event",
    True, "Unknown"]];

SourceVault`SourceVaultTaskDateCandidates[text_String, ref0_ : Automatic] := Module[
  {t = iSVTKNFKC[text], ref, masked, found = {}, spans, ordered, n},
  ref = Which[ref0 === Automatic, iSVTKToday[], NumberQ[ref0], N[ref0], DateObjectQ[ref0], N[AbsoluteTime[ref0]],
    True, With[{y = iSVTKYMD[ref0]}, If[ListQ[y], iSVTKDayAbs[y], iSVTKToday[]]]];
  masked = t;
  (* the groups (StringCases) and the spans (StringPosition, without overlaps) of the matches come in the same order;
     the groups are not read again from the matched span, where a look-ahead ("11/20" followed by "(\:91d1)") fails *)
  Scan[Function[form, Module[{pos, gs},
      pos = StringPosition[masked, form[[1]], Overlaps -> False];
      gs = StringCases[masked, form[[1]] :> {"$1", "$2", "$3"}];
      If[Length[pos] === Length[gs] && pos =!= {},
        MapThread[Function[{p, g}, With[{ymd = Quiet @ Check[form[[2]][DeleteCases[g, ""], ref], Missing[]]},
            If[iSVTKYMDQ[ymd], AppendTo[found, {p[[1]], p[[2]], ymd}]]]], {pos, gs}];
        masked = StringReplacePart[masked, StringRepeat[" ", #[[2]] - #[[1]] + 1] & /@ pos, pos]]]], $iSVTKForms];
  ordered = SortBy[found, First];
  n = StringLength[t];
  MapIndexed[Function[{f, k}, Module[{s = f[[1]], e = f[[2]], prevEnd, nextStart, before, after, hasTime, wd},
      prevEnd = If[k[[1]] > 1, ordered[[k[[1]] - 1, 2]], 0];
      nextStart = If[k[[1]] < Length[ordered], ordered[[k[[1]] + 1, 1]], n + 1];
      before = iSVTKCutBefore[StringTake[t, {Max[prevEnd + 1, s - 14], s - 1}]];
      after = iSVTKCutAfter[StringTake[t, {e + 1, Min[nextStart - 1, e + 24]}]];
      hasTime = StringMatchQ[after, $iSVTKTimeRx ~~ ___];
      wd = StringMatchQ[after, $iSVTKWeekdayRx ~~ ___];
      <|"Date" -> iSVTKDateObject[f[[3]]], "YMD" -> f[[3]], "Role" -> iSVTKRole[before, after, hasTime], "HasTime" -> hasTime,
        "Weekday" -> wd, "Position" -> {s, e}|>]], ordered]];
SourceVault`SourceVaultTaskDateCandidates[_, ___] := {};

(* the first date of a role in a text, not before the reference day. In a title a date followed by a weekday and no
   other word is an event ("11\:670820\:65e5(\:91d1)\:306e\:4ef6" names the day of something) *)
iSVTKPick[cands_List, role_String, refDay_?NumberQ, title_ : False] := SelectFirst[cands,
  iSVTKDayAbs[#["YMD"]] >= refDay && (#["Role"] === role ||
    (role === "Event" && TrueQ[title] && #["Role"] === "Unknown" && TrueQ[#["Weekday"]])) &, Missing[]];

Options[SourceVault`SourceVaultTaskDates] = {"Now" -> Automatic, "ReviewLeadDays" -> Automatic, "DeadlineFromEvent" -> Automatic};
SourceVault`SourceVaultTaskDates[spec_Association, opts : OptionsPattern[]] := Module[
  {ref, refDay, today, texts, cands, dl = Missing["None"], ev = Missing["None"], basis = <||>, x, lead, fromEvent, upcoming, nr},
  ref = With[{r = Lookup[spec, "ReferenceDate", Automatic]},
    Which[NumberQ[r], N[r], DateObjectQ[r], N[AbsoluteTime[r]], ListQ[iSVTKYMD[r]], iSVTKDayAbs[iSVTKYMD[r]], True, iSVTKToday[]]];
  refDay = iSVTKDayAbs[Take[DateList[ref], 3]];
  today = With[{n = OptionValue["Now"]}, Which[NumberQ[n], iSVTKDayAbs[Take[DateList[n], 3]],
    DateObjectQ[n], iSVTKDayAbs[Take[DateList[n], 3]], True, iSVTKToday[]]];
  lead = With[{l = OptionValue["ReviewLeadDays"]}, If[IntegerQ[l] && l >= 0, l, $SourceVaultTaskReviewLeadDays]];
  fromEvent = With[{f = OptionValue["DeadlineFromEvent"]}, If[BooleanQ[f], f, TrueQ[$SourceVaultTaskDeadlineFromEvent]]];
  texts = Select[{{"Title", Lookup[spec, "Title", Lookup[spec, "Subject", Missing[]]]},
    {"Summary", Lookup[spec, "Summary", Missing[]]}, {"Body", Lookup[spec, "Body", Missing[]]}}, StringQ[#[[2]]] && #[[2]] =!= "" &];
  cands = (#[[1]] -> SourceVault`SourceVaultTaskDateCandidates[#[[2]], ref]) & /@ texts;
  (* Deadline: the explicit value (the mail classification), then the title, then the summary and the body *)
  x = iSVTKYMD[Lookup[spec, "Deadline", Missing[]]];
  If[ListQ[x], dl = iSVTKDateObject[x]; basis["Deadline"] = "Explicit",
    Scan[Function[c, If[MissingQ[dl], With[{p = iSVTKPick[Last[c], "Deadline", refDay]},
      If[AssociationQ[p], dl = p["Date"]; basis["Deadline"] = First[c]]]]], cands]];
  (* Eventdate: the explicit value (the event of a routine business), then the title, then the summary and the body *)
  x = iSVTKYMD[Lookup[spec, "Eventdate", Lookup[spec, "EventDate", Missing[]]]];
  If[ListQ[x], ev = iSVTKDateObject[x]; basis["Eventdate"] = "Explicit",
    Scan[Function[c, If[MissingQ[ev], With[{p = iSVTKPick[Last[c], "Event", refDay, First[c] === "Title"]},
      If[AssociationQ[p], ev = p["Date"]; basis["Eventdate"] = First[c]]]]], cands]];
  (* an event without a deadline of its own: the work is due by the event (the owner's notes) *)
  If[MissingQ[dl] && DateObjectQ[ev] && fromEvent, dl = ev; basis["Deadline"] = "Eventdate"];
  (* the next review: before the nearer of the two, not before today *)
  upcoming = Select[{dl, ev}, DateObjectQ[#] && iSVTKDayAbs[Take[DateList[#], 3]] >= today &];
  nr = If[upcoming === {}, Quantity[1, "Weeks"],
    With[{d = Max[today, Min[iSVTKDayAbs[Take[DateList[#], 3]] & /@ upcoming] - lead*86400.]}, iSVTKDateObject[Take[DateList[d], 3]]]];
  basis["NextReview"] = If[DateObjectQ[nr], "BeforeDate", "Default"];
  <|"Deadline" -> dl, "Eventdate" -> ev, "NextReview" -> nr, "Basis" -> basis|>];
SourceVault`SourceVaultTaskDates[___] := <|"Deadline" -> Missing["None"], "Eventdate" -> Missing["None"],
  "NextReview" -> Quantity[1, "Weeks"], "Basis" -> <||>|>;

(* ---------------- the header as editable input text ---------------- *)
$iSVTKHeaderOrder = {"Keywords", "Deadline", "Eventdate", "NextReview", "Status", "Title"};
iSVTKValueString[d_?DateObjectQ] := "DateObject[{" <> StringRiffle[ToString /@ Round[Take[DateList[d], 3]], ", "] <> "}]";
iSVTKValueString[v_] := ToString[v, InputForm];
SourceVault`SourceVaultTaskHeaderString[assoc_Association] := Module[{a, keys},
  a = Select[assoc, ! (MissingQ[#] || # === None) &];
  (* the owner's order first, the other keys in the order they were given *)
  keys = Join[Select[$iSVTKHeaderOrder, KeyExistsQ[a, #] &], Select[Keys[a], ! MemberQ[$iSVTKHeaderOrder, #] &]];
  "<|" <> StringRiffle[(ToString[#, InputForm] <> " -> " <> iSVTKValueString[a[#]]) & /@ keys, ", "] <> "|>"];
SourceVault`SourceVaultTaskHeaderString[___] := "<||>";

(* ---------------- $onWork: the notes that lack the dates ---------------- *)
iSVTKRecords[opt_, dir_] := Module[{r},
  If[ListQ[opt], Return[Select[opt, AssociationQ]]];
  If[Length[DownValues[NBAccess`NBOnWorkTasks]] === 0, Return[{}]];
  r = Quiet @ NBAccess`NBOnWorkTasks[NBAccess`PrivacySpec -> <|"AccessLevel" -> 1.0|>,
    Sequence @@ If[StringQ[dir], {"Directory" -> dir}, {}]];
  If[ListQ[r], Select[r, AssociationQ], {}]];
iSVTKOpenQ[rec_] := ! MemberQ[{"Done", "Pass", "Keep"}, Lookup[rec, "State", "Open"]];
(* the title of a note: the header's Title, else the file name without its date *)
iSVTKTitleOf[rec_] := With[{t = Lookup[rec, "Title", Missing[]], p = Lookup[rec, "Path", Missing[]]},
  Which[StringQ[t] && StringTrim[t] =!= "", t,
    StringQ[p], StringReplace[FileBaseName[p], RegularExpression["^\\d{8}[-_ ]?"] -> ""],
    True, ""]];
(* the day a note was made: the yyyymmdd its file name begins with, else its modification date *)
iSVTKNoteDay[rec_] := Module[{p = Lookup[rec, "Path", Missing[]], m},
  m = If[StringQ[p], StringCases[FileNameTake[p], RegularExpression["^(\\d{4})(\\d{2})(\\d{2})"] :> FromDigits /@ {"$1", "$2", "$3"}, 1], {}];
  Which[m =!= {} && iSVTKYMDQ[First[m]], iSVTKDayAbs[First[m]],
    DateObjectQ[Lookup[rec, "ModificationDate", Missing[]]], iSVTKDayAbs[Take[DateList[rec["ModificationDate"]], 3]],
    True, iSVTKToday[]]];
iSVTKMailRow[rid_String, fn_] := Which[
  fn =!= Automatic, Quiet @ Check[fn[rid], <||>],
  Length[DownValues[SourceVault`SourceVaultMailIndexGet]] > 0, Quiet @ Check[SourceVault`SourceVaultMailIndexGet[rid], <||>],
  True, <||>];
iSVTKMailRow[___] := <||>;

(* what a note should get: only what it lacks. Deadline and Eventdate are never overwritten; NextReview is set when it is
   missing or the relative default (an offset from the last change of the file) and a concrete date was found. *)
iSVTKPlanFor[rec_Association, o_Association] := Module[{rid = Lookup[rec, "MailRecordId", Missing[]], row = <||>, spec, td, set = <||>,
    hasDl = DateObjectQ[Lookup[rec, "DeadlineDue", Missing[]]], hasEv = DateObjectQ[Lookup[rec, "EventDue", Missing[]]], ref},
  If[StringQ[rid], row = iSVTKMailRow[rid, Lookup[o, "MailRow", Automatic]]];
  If[! AssociationQ[row], row = <||>];
  ref = With[{d = iSVTKYMD[Lookup[row, "Date", Missing[]]]}, If[ListQ[d], iSVTKDayAbs[d], iSVTKNoteDay[rec]]];
  spec = <|"Title" -> With[{s = Lookup[row, "Subject", Missing[]]}, If[StringQ[s], s, iSVTKTitleOf[rec]]],
    "Summary" -> Lookup[row, "Summary", Missing[]], "Deadline" -> Lookup[row, "Deadline", Missing[]], "ReferenceDate" -> ref|>;
  td = SourceVault`SourceVaultTaskDates[spec, "Now" -> Lookup[o, "Now", Automatic]];
  If[! hasDl && DateObjectQ[td["Deadline"]], set["Deadline"] = td["Deadline"]];
  If[! hasEv && DateObjectQ[td["Eventdate"]], set["Eventdate"] = td["Eventdate"]];
  (* NBOnWorkTasks tells whether the header's NextReview is a date of the owner ("Date") or the relative default *)
  If[set =!= <||> && DateObjectQ[td["NextReview"]] && Lookup[rec, "ReviewKind", Missing[]] =!= "Date", set["NextReview"] = td["NextReview"]];
  <|"Path" -> Lookup[rec, "Path", Missing[]], "MailRecordId" -> rid, "Set" -> set, "Basis" -> KeyTake[td["Basis"], Keys[set]]|>];

Options[SourceVault`SourceVaultTaskDatesBackfill] = {"DryRun" -> True, "Directory" -> Automatic, "Records" -> Automatic,
  "MailRow" -> Automatic, "Now" -> Automatic, "Paths" -> All};
SourceVault`SourceVaultTaskDatesBackfill[opts : OptionsPattern[]] := Module[{o, recs, plans, results},
  o = Association[Options[SourceVault`SourceVaultTaskDatesBackfill], Reverse[{opts}]];
  recs = Select[iSVTKRecords[o["Records"], o["Directory"]], iSVTKOpenQ[#] && StringQ[Lookup[#, "Path", Missing[]]] &];
  If[ListQ[o["Paths"]], recs = Select[recs, MemberQ[o["Paths"], #["Path"]] &]];
  (* a note that has both dates needs nothing *)
  recs = Select[recs, ! (DateObjectQ[Lookup[#, "DeadlineDue", Missing[]]] && DateObjectQ[Lookup[#, "EventDue", Missing[]]]) &];
  plans = Select[iSVTKPlanFor[#, o] & /@ recs, #["Set"] =!= <||> &];
  results = If[TrueQ[o["DryRun"]], plans,
    Function[pl, Append[pl, "Result" -> If[Length[DownValues[NBAccess`NBFileSetStatusFields]] > 0,
      Quiet @ Check[NBAccess`NBFileSetStatusFields[pl["Path"], pl["Set"], "AccessSpec" -> <|"AccessLevel" -> 0.7|>, "DryRun" -> False],
        <|"Status" -> "Failed", "Reason" -> "WriteError"|>],
      <|"Status" -> "Failed", "Reason" -> "NBAccessUnavailable"|>]]] /@ plans];
  (* the paths are made from the titles of the notes (mail subjects): the result leaves through the privacy exit *)
  With[{r = <|"Status" -> "OK", "DryRun" -> TrueQ[o["DryRun"]], "Checked" -> Length[recs], "Count" -> Length[plans],
      "Written" -> Count[results, p_ /; Lookup[Lookup[p, "Result", <||>], "Status", ""] === "OK"], "Plans" -> results|>},
    If[Length[DownValues[SourceVault`SourceVaultPrivateResult]] > 0, Quiet @ Check[SourceVault`SourceVaultPrivateResult[r, 1.0], r], r]]];
SourceVault`SourceVaultTaskDatesBackfill[___] := <|"Status" -> "Failed", "Reason" -> "expects [opts]"|>;

(* ---------------- SystemDoctor: forgetting ----------------
   Counts only (no title, no path): the doctor's result can leave the machine in a notification. *)
iSVTKDigest[p_String] := StringTake[IntegerString[Hash[p, "SHA256"], 36], UpTo[10]];
SourceVault`SourceVaultTaskDatesProbe[opts___] := Module[{o = Association[{opts}], recs, open, today, missing, past},
  recs = iSVTKRecords[Lookup[o, "Records", Automatic], Lookup[o, "Directory", Automatic]];
  If[recs === {} && Length[DownValues[NBAccess`NBOnWorkTasks]] === 0,
    Return[<|"Health" -> "OK", "ReasonCode" -> "NotApplicable", "Component" -> "TaskDates"|>]];
  today = With[{n = Lookup[o, "Now", Automatic]}, If[NumberQ[n], iSVTKDayAbs[Take[DateList[n], 3]], iSVTKToday[]]];
  open = Select[recs, iSVTKOpenQ];
  (* the title states a date (a deadline, or an event) and the note has neither *)
  missing = Select[open, ! DateObjectQ[Lookup[#, "DeadlineDue", Missing[]]] && ! DateObjectQ[Lookup[#, "EventDue", Missing[]]] &&
      AnyTrue[SourceVault`SourceVaultTaskDateCandidates[iSVTKTitleOf[#], iSVTKNoteDay[#]], MemberQ[{"Deadline", "Event"}, #["Role"]] || TrueQ[#["Weekday"]] &] &];
  (* the date is past and the note is still open (a reminder that was missed) *)
  past = Select[open, With[{ds = Select[{Lookup[#, "DeadlineDue", Missing[]], Lookup[#, "EventDue", Missing[]]}, DateObjectQ]},
      ds =!= {} && Max[iSVTKDayAbs[Take[DateList[#], 3]] & /@ ds] < today] &];
  <|"Component" -> "TaskDates", "Health" -> If[missing === {}, "OK", "Degraded"],
    "ReasonCode" -> If[missing === {}, "TaskDatesOK", "TaskDatesMissing"],
    "OpenNotes" -> Length[open], "DatesMissing" -> Length[missing], "PastOpen" -> Length[past],
    "MissingDigests" -> Take[iSVTKDigest[ToString[Lookup[#, "Path", ""]]] & /@ missing, UpTo[5]],
    "Remediation" -> If[missing === {}, "",
      "SourceVaultTaskDatesBackfill[] \:3067\:6848\:3092\:78ba\:304b\:3081\:3001\"DryRun\" -> False \:3067\:66f8\:304d\:8db3\:3059 (\:958b\:3044\:3066\:3044\:308b\:30ce\:30fc\:30c8\:306f\:9589\:3058\:3066\:304b\:3089)"]|>];

(* ---------------- registration ---------------- *)
Quiet @ Check[If[Length[DownValues[NBAccess`NBRegisterApprovalHeads]] > 0,
  NBAccess`NBRegisterApprovalHeads[{"SourceVaultTaskDatesBackfill"}]], Null];
Quiet @ Check[If[Length[DownValues[SourceVault`SourceVaultDiagnosticsRegisterProbe]] > 0,
  SourceVault`SourceVaultDiagnosticsRegisterProbe["TaskDates", Function[SourceVault`SourceVaultTaskDatesProbe[]]]], Null];
Quiet @ Check[If[Length[DownValues[SourceVault`SourceVaultRegisterPrivacyContract]] > 0,
  SourceVault`SourceVaultRegisterPrivacyContract["SourceVaultTaskDatesBackfill",
    <|"Class" -> "Private", "Exit" -> "Result", "Sources" -> {}, "Module" -> "SourceVault_taskdates.wl",
      "Note" -> "the paths of the work notes (made from their titles) and the dates written into them"|>];
  Scan[SourceVault`SourceVaultRegisterPrivacyContract[#,
      <|"Class" -> "Internal", "Exit" -> "None", "Sources" -> {}, "Module" -> "SourceVault_taskdates.wl",
        "Note" -> "dates read from the text the caller gives (no store is read)",
        "NoDataFlow" -> "pure date extraction / header text from caller-provided text; no private store access"|>] &,
    {"SourceVaultTaskDates", "SourceVaultTaskDateCandidates", "SourceVaultTaskHeaderString"}];
  SourceVault`SourceVaultRegisterPrivacyContract["SourceVaultTaskDatesProbe",
    <|"Class" -> "Internal", "Exit" -> "None", "Sources" -> {}, "Module" -> "SourceVault_taskdates.wl",
      "Note" -> "counts and short digests of paths only",
      "NoDataFlow" -> "reads the status headers of $onWork notes but returns counts and 10-character digests of paths only (no title, path or date)"|>]], Null];

End[];
EndPackage[];
