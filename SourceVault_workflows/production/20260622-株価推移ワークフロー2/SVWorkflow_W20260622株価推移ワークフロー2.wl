(* ::Package:: *)

(* ============================================================
   SVWorkflow main package file
   (context: SourceVaultWorkflow`W20260622\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2`).

   Codified SourceVault workflow, slug 20260622-\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2.
   FULL implementation in a single stage: package skeleton + WorkflowInfo +
   self-bootstrap + a launch entry that ACTUALLY performs work
   (no-arg safe report, plus "generate" / "normalize" / "summary" / "data" / "plot" forms).

   ---- naming (authoritative) ----
   A Wolfram context/symbol leaf may NOT begin with a digit. The on-demand
   registry (SourceVault_workflowregistry.wl) derives the context from the slug
   and PREFIXES "W" when the canonical leaf starts with a digit:
     SourceVaultWorkflowContext[slug]
       = "SourceVaultWorkflow`" <> iSVWFCanonicalSlug[slug] <> "`"
     iSVWFCanonicalSlug[slug] = StringJoin[Capitalize /@
       Select[StringSplit[slug, Except[WordCharacter]..], # =!= "" &]]
       then "W" <> canon when canon starts with a digit.
   For slug 20260622-\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2 the word runs
   "20260622" and "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2" Capitalize
   and join to 20260622\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2 (digit-leading),
   so the registry prepends "W", giving the canonical leaf
   W20260622\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2 and the expected context
   "SourceVaultWorkflow`W20260622\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2`".
   This BeginPackage MUST match it exactly; SourceVaultLoadWorkflow judges success
   by MemberQ[$Packages, <that ctx>].

   ---- Japanese symbols are intentional ----
   The launch entry is the JAPANESE-named public symbol
   \:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch (the trailing "2" is an
   ASCII digit at the END of the leaf, which is valid; the leaf begins with a
   letter so no W prefix is needed). Every Japanese leaf and string value is
   \:XXXX-escaped so the source stays pure-ASCII on disk while the kernel decodes
   it at parse time. This file is encoded UTF-8 / ASCII bytes only.
   ============================================================ *)

(* ---- self-bootstrap (depth-independent pkgRoot) ----
   Walk up from this file's directory until the directory that contains
   SourceVault.wl is found, then load SourceVault.wl only if not already present.
   The workflow's own logic relies only on built-ins (FinancialData / DateListPlot),
   so this is the single, guarded dependency. *)
With[{pkgRoot =
    Module[{d = If[StringQ[$InputFileName] && $InputFileName =!= "",
          DirectoryName[$InputFileName], Directory[]]},
      While[d =!= DirectoryName[d] &&
          ! FileExistsQ[FileNameJoin[{d, "SourceVault.wl"}]], d = DirectoryName[d]];
      d]},
  If[! MemberQ[$Packages, "SourceVault`"] &&
      FileExistsQ[FileNameJoin[{pkgRoot, "SourceVault.wl"}]],
    Block[{$CharacterEncoding = "UTF-8"},
      Quiet @ Check[Get[FileNameJoin[{pkgRoot, "SourceVault.wl"}]], Null]]]];

BeginPackage["SourceVaultWorkflow`W20260622\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2`"]

WorkflowInfo::usage =
  "WorkflowInfo[] returns this SourceVault workflow's metadata (Slug, Name, Version, Context, Launch, Description, Routes).";

(* \:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch : the launch entry, a Japanese-named symbol. *)
\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch::usage =
  "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[] returns a side-effect-free report (Status->Ready) describing the target tickers, Japanese display names, period, baseline/fallback policy and identifier table. \:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[\"generate\", opts] builds the 6-cell relative-index notebook (Notebook expression; \"Export\"->path writes a .nb). \:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[\"normalize\", pairs] rebases a {date,value} series (or a TimeSeries) to 100. \:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[\"data\"] fetches+normalizes live data; [\"plot\"] returns the line chart (both need network).";

Begin["`Private`"]

(* ---- fixed parameters (spec) ---- *)
$iStartDate = {2016, 1, 1};
$iBaseValue = 100;

(* identifier table: each series tried Primary -> Fallbacks in order under
   Quiet@Check; empty/$Failed/Missing is treated as invalid and skipped. *)
$iSeries = {
  <|"Display" -> "\:30a2\:30c3\:30d7\:30eb",                 "Primary" -> "AAPL",       "Fallbacks" -> {"NASDAQ:AAPL"},  "Group" -> "Magnificent7"|>,
  <|"Display" -> "\:30de\:30a4\:30af\:30ed\:30bd\:30d5\:30c8", "Primary" -> "MSFT",       "Fallbacks" -> {"NASDAQ:MSFT"},  "Group" -> "Magnificent7"|>,
  <|"Display" -> "\:30a2\:30eb\:30d5\:30a1\:30d9\:30c3\:30c8", "Primary" -> "GOOGL",      "Fallbacks" -> {"GOOG", "NASDAQ:GOOGL"}, "Group" -> "Magnificent7"|>,
  <|"Display" -> "\:30a2\:30de\:30be\:30f3",                 "Primary" -> "AMZN",       "Fallbacks" -> {"NASDAQ:AMZN"},  "Group" -> "Magnificent7"|>,
  <|"Display" -> "\:30e1\:30bf",                             "Primary" -> "META",       "Fallbacks" -> {"FB", "NASDAQ:META"}, "Group" -> "Magnificent7"|>,
  <|"Display" -> "\:30c6\:30b9\:30e9",                       "Primary" -> "TSLA",       "Fallbacks" -> {"NASDAQ:TSLA"},  "Group" -> "Magnificent7"|>,
  <|"Display" -> "\:30a8\:30cc\:30d3\:30c7\:30a3\:30a2",     "Primary" -> "NVDA",       "Fallbacks" -> {"NASDAQ:NVDA"},  "Group" -> "Highlight"|>,
  <|"Display" -> "\:ff34\:ff33\:ff2d\:ff23",                 "Primary" -> "TSM",        "Fallbacks" -> {"NYSE:TSM"},     "Group" -> "Semiconductor"|>,
  <|"Display" -> "\:30b5\:30e0\:30b9\:30f3\:96fb\:5b50",     "Primary" -> "KRX:005930", "Fallbacks" -> {"005930.KS", "SSNLF"}, "Group" -> "Semiconductor"|>,
  <|"Display" -> "\:30de\:30a4\:30af\:30ed\:30f3",           "Primary" -> "MU",         "Fallbacks" -> {"NASDAQ:MU"},    "Group" -> "Semiconductor"|>,
  <|"Display" -> "\:30ad\:30aa\:30af\:30b7\:30a2",           "Primary" -> "TSE:285A",   "Fallbacks" -> {"285A.T"},       "Group" -> "Semiconductor"|>,
  <|"Display" -> "\:ff33\:ff06\:ff30\:ff15\:ff10\:ff10",     "Primary" -> "^GSPC",      "Fallbacks" -> {"^SPX", "SP500"}, "Group" -> "Index"|>
};

$iPriceProperty = <|"Primary" -> "AdjustedClose", "Fallback" -> "Close"|>;

(* spec graph title (exact wording, half-width 2016 / 100 / "S&P 500"):
   2016\:5e74\:ff11\:6708\:ff11\:65e5\:3092\:ff11\:ff10\:ff10\:3068\:3057\:305f\:4e3b\:8981\:30c6\:30c3\:30af\:30fb\:534a\:5c0e\:4f53\:95a2\:9023\:9298\:67c4\:3068S&P 500\:306e\:63a8\:79fb *)
$iPlotTitle = "2016\:5e741\:67081\:65e5\:3092100\:3068\:3057\:305f\:4e3b\:8981\:30c6\:30c3\:30af\:30fb\:534a\:5c0e\:4f53\:95a2\:9023\:9298\:67c4\:3068S&P 500\:306e\:63a8\:79fb";

(* spec section 1: the EXACT Text-cell wording placed at the head of the
   generated notebook (note the intentional spelling "Maginiticent" per spec) *)
$iTitleCellText = "Maginiticent 7\:3068Nvidia, TSMC, Samsung, \:30de\:30a4\:30af\:30ed\:30f3\:3001\:30ad\:30aa\:30af\:30b7\:30a2\:3068S&P500\:30a4\:30f3\:30c7\:30c3\:30af\:30b9\:306e2016/1/1\:3092100\:3068\:3057\:3066\:73fe\:5728\:307e\:3067\:306e\:63a8\:79fb\:306e\:53ef\:8996\:5316";

(* generated-notebook Japanese fragments *)
$iFrameX      = "\:65e5\:4ed8";
$iFrameY      = "\:6307\:6570\:5024\:ff08\:ff12\:ff10\:ff11\:ff16\:5e74\:521d\:ff1d\:ff11\:ff10\:ff10\:ff09";
$iBaseLabel   = "2016-01-01 = 100";
$iAsOfLabel   = "\:30c7\:30fc\:30bf\:53d6\:5f97\:65e5: ";
$iBaseNote    = "\:57fa\:6e96: \:5404\:7cfb\:5217\:306e 2016-01-01 \:4ee5\:964d\:6700\:521d\:306e\:6709\:52b9\:5024\:3092 100 \:3068\:3057\:305f\:76f8\:5bfe\:6307\:6570\:3002\:88dc\:9593\:306a\:3057\:3002";
$iKioxiaNote  = "\:30ad\:30aa\:30af\:30b7\:30a2\:306f 2016 \:5e74\:6642\:70b9\:3067\:672a\:4e0a\:5834\:306e\:305f\:3081\:3001\:53d6\:5f97\:53ef\:80fd\:306a\:6700\:521d\:306e\:55b6\:696d\:65e5\:3092 100 \:3068\:3057\:3001\:57fa\:6e96\:65e5\:304c\:4ed6\:9298\:67c4\:3068\:7570\:306a\:308b\:3002";
$iUnavailLbl  = "\:53d6\:5f97\:4e0d\:80fd\:9298\:67c4: ";
$iNone        = "\:306a\:3057";
(* supplementary-table header labels (spec section 6) *)
$iTblName     = "\:9298\:67c4\:540d";
$iTblTicker   = "\:30c6\:30a3\:30c3\:30ab\:30fc";
$iTblBaseDate = "\:57fa\:6e96\:65e5";
$iTblBasePx   = "\:57fa\:6e96\:4fa1\:683c";
$iTblLastDate = "\:6700\:65b0\:65e5";
$iTblLastIdx  = "\:6700\:65b0\:6307\:6570\:5024";
$iTblNote     = "\:5099\:8003";

(* ---- core logic (pure, network-free) ---- *)
iNum[v_] := Which[NumberQ[v], v, QuantityQ[v], QuantityMagnitude[v], True, $Failed];

iAbsT[d_] := Quiet @ Check[AbsoluteTime[d], 0];

iValidPairQ[p_] := MatchQ[p, {_, _}] && NumberQ[iNum[p[[2]]]] && TrueQ[iNum[p[[2]]] > 0];

(* FinancialData[id, prop, {start, end}] returns a TimeSeries, not a list of
   {date, value} pairs. Coerce ROBUSTLY to a flat list of scalar {date, value}
   pairs that downstream MatchQ[#,{_,_}] / #[[2]] code can rely on, regardless of
   the actual path shape:
     - prefer ts["DatePath"]  -> {{DateObject, value}, ...} (documented)
     - fall back to ts["Path"] -> {{absTime, value}, ...}
   then KEEP only length-2 sublists (defensive: a vector / odd path entry is
   dropped here instead of corrupting #[[2]] later). Values may be plain numbers
   OR Quantity (currency); iNum strips those downstream, so they survive here. *)
iCoercePairs[d_] := If[ListQ[d], Select[d, MatchQ[#, {_, _}] &], {}];
iAsPairs[ts_TimeSeries] := Module[{p},
  p = Quiet @ Check[ts["DatePath"], $Failed];
  If[! (ListQ[p] && Length[p] > 0), p = Quiet @ Check[ts["Path"], $Failed]];
  iCoercePairs[p]];
iAsPairs[d_List] := iCoercePairs[d];
iAsPairs[_] := {};

iGoodSeriesQ[ts_TimeSeries] := iGoodSeriesQ[iAsPairs[ts]];
iGoodSeriesQ[d_] := With[{p = iCoercePairs[d]},
  p =!= {} && AnyTrue[p, NumberQ[iNum[#[[2]]]] &]];

(* rebase to 100 on the first valid trading day; no interpolation, no synthetic
   points -- only the valid pairs (sorted by date) survive. *)
iNormalizePairs[input_] := Module[{pairs, valid, base},
  pairs = iAsPairs[input];
  valid = SortBy[Select[pairs, iValidPairQ], iAbsT[First[#]] &];
  If[valid === {}, Return[{}]];
  base = iNum[valid[[1, 2]]];
  ({#[[1]], $iBaseValue iNum[#[[2]]]/base // N}) & /@ valid];

(* one summary row for the supplementary table (spec section 6) from a raw
   {date,value}/TimeSeries series; returns Missing-aware fields. *)
iSummaryRow[display_, ticker_, prop_, input_] := Module[{valid, base, last},
  valid = SortBy[Select[iAsPairs[input], iValidPairQ], iAbsT[First[#]] &];
  If[valid === {},
    Return[<|"Display" -> display, "Ticker" -> ticker, "Property" -> prop,
      "BaseDate" -> Missing["NotAvailable"], "BasePrice" -> Missing["NotAvailable"],
      "LastDate" -> Missing["NotAvailable"], "LastIndex" -> Missing["NotAvailable"]|>]];
  base = iNum[valid[[1, 2]]];
  last = valid[[-1]];
  <|"Display" -> display, "Ticker" -> ticker, "Property" -> prop,
    "BaseDate" -> valid[[1, 1]], "BasePrice" -> base,
    "LastDate" -> last[[1]],
    "LastIndex" -> ($iBaseValue iNum[last[[2]]]/base // N)|>];

(* ---- live fetch (network) ---- *)
iToday[] := Take[DateList[], 3];

iFetchOne[entry_] := Module[{ids, out = Missing["Unavailable"]},
  ids = Prepend[Lookup[entry, "Fallbacks", {}], entry["Primary"]];
  Catch[
    Do[
      Module[{d = Quiet @ Check[
            FinancialData[id, prop, {$iStartDate, iToday[]}], $Failed]},
        If[iGoodSeriesQ[d],
          Throw[<|"Display" -> entry["Display"], "Identifier" -> id,
            "Property" -> prop, "Data" -> iAsPairs[d]|>]]],
      {id, ids}, {prop, {$iPriceProperty["Primary"], $iPriceProperty["Fallback"]}}];
    out]];

iFetchAll[] := Module[{fetched, available, unavailable, normalized, summary},
  fetched = Association[(#["Display"] -> iFetchOne[#]) & /@ $iSeries];
  available = Select[fetched, AssociationQ];
  unavailable = Keys[Select[fetched, MissingQ]];
  normalized = Association[
    (# -> iNormalizePairs[available[#]["Data"]]) & /@ Keys[available]];
  summary = (iSummaryRow[#["Display"], #["Identifier"], #["Property"], #["Data"]] & /@
    Values[available]);
  <|"Status" -> "Fetched", "AsOf" -> iToday[],
    "Available" -> Keys[available], "Unavailable" -> unavailable,
    "Raw" -> available, "Normalized" -> normalized, "Summary" -> summary|>];

iPlotGraphic[normalized_Association, log_: False] := DateListPlot[
  Values[normalized],
  PlotLegends -> Keys[normalized],
  PlotLabel -> $iPlotTitle,
  FrameLabel -> {$iFrameX, $iFrameY},
  Joined -> True,
  PlotRange -> All,
  ScalingFunctions -> If[TrueQ[log], "Log", None],
  GridLines -> Automatic,
  GridLinesStyle -> Directive[GrayLevel[0.85]],
  PlotTheme -> "Detailed",
  ImageSize -> {1100, 620}];

(* ---- generated-notebook construction ---- *)
iSeriesEntryCode[s_] := StringJoin[
  "  <|\"Display\" -> ", ToString[s["Display"], InputForm],
  ", \"Ids\" -> ", ToString[Prepend[s["Fallbacks"], s["Primary"]], InputForm], "|>"];

iSeriesListCode[] := StringJoin["{\n",
  StringRiffle[iSeriesEntryCode /@ $iSeries, ",\n"], "\n}"];

iCell2[] := StringJoin[
  "(* parameters: period, target series, display names, colors, title *)\n",
  "startDate = {2016, 1, 1};\n",
  "endDate = Take[DateList[], 3];\n",
  "baseValue = 100;\n",
  "series = ", iSeriesListCode[], ";\n",
  "displayNames = Lookup[series, \"Display\"];\n",
  "plotColors = Take[ColorData[97, \"ColorList\"], Length[series]];\n",
  "plotTitle = ", ToString[$iPlotTitle, InputForm], ";"];

(* data-fetch cell -- robust shape handling so the normalize / table cells can
   safely assume a flat list of scalar {date, value} pairs. asPairs prefers the
   documented DatePath, falls back to Path, and keeps only length-2 sublists;
   num strips Quantity (currency) values. This mirrors the package's iAsPairs so
   FinancialData's TimeSeries return shape never silently drops a series. *)
iCell3[] := StringJoin[
  "(* data fetch: AdjustedClose preferred, Close fallback, per identifier *)\n",
  "num[v_] := Which[NumberQ[v], v, QuantityQ[v], QuantityMagnitude[v], True, $Failed];\n",
  "(* FinancialData[id, prop, {start, end}] returns a TimeSeries, not a list. *)\n",
  "(* Coerce to scalar {date,value} pairs: DatePath -> Path, keep length-2 only. *)\n",
  "coercePairs[d_] := If[ListQ[d], Select[d, MatchQ[#, {_, _}] &], {}];\n",
  "asPairs[ts_TimeSeries] := Module[{p}, p = Quiet@Check[ts[\"DatePath\"], $Failed];\n",
  "   If[! (ListQ[p] && Length[p] > 0), p = Quiet@Check[ts[\"Path\"], $Failed]];\n",
  "   coercePairs[p]];\n",
  "asPairs[d_List] := coercePairs[d]; asPairs[_] := {};\n",
  "goodSeriesQ[d0_] := With[{p = asPairs[d0]}, p =!= {} && AnyTrue[p, NumberQ[num[#[[2]]]] &]];\n",
  "fetchOne[ids_List] := Module[{out = Missing[\"Unavailable\"]},\n",
  "  Catch[\n",
  "    Do[Module[{d = Quiet@Check[FinancialData[id, prop, {startDate, endDate}], $Failed]},\n",
  "       If[goodSeriesQ[d], Throw[<|\"Identifier\" -> id, \"Property\" -> prop, \"Data\" -> asPairs[d]|>]]],\n",
  "      {id, ids}, {prop, {\"AdjustedClose\", \"Close\"}}];\n",
  "    out]];\n",
  "fetched = Association[(#[\"Display\"] -> fetchOne[#[\"Ids\"]]) & /@ series];\n",
  "available = Select[fetched, AssociationQ];\n",
  "unavailable = Keys[Select[fetched, MissingQ]];"];

(* normalize cell -- input is already a coerced list of scalar {date,value}
   pairs (asPairs ran in the fetch cell), but re-coerce defensively in case the
   cell is run on a raw TimeSeries directly. *)
iCell4[] := StringJoin[
  "(* normalize: first valid price -> 100, no interpolation *)\n",
  "validPairQ[p_] := MatchQ[p, {_, _}] && NumberQ[num[p[[2]]]] && TrueQ[num[p[[2]]] > 0];\n",
  "normalize[pairs0_] := Module[{pairs, valid, base},\n",
  "  pairs = asPairs[pairs0];\n",
  "  valid = SortBy[Select[pairs, validPairQ], AbsoluteTime[First[#]] &];\n",
  "  If[valid === {}, Return[{}]];\n",
  "  base = num[valid[[1, 2]]];\n",
  "  ({#[[1]], baseValue num[#[[2]]]/base // N}) & /@ valid];\n",
  "normalized = Association[(# -> normalize[available[#][\"Data\"]]) & /@ Keys[available]];"];

iCell5[] := StringJoin[
  "(* visualize: all series on one relative-index line chart (logScale toggles Y) *)\n",
  "logScale = False;\n",
  "DateListPlot[\n",
  "  Values[normalized],\n",
  "  PlotLegends -> Keys[normalized],\n",
  "  PlotLabel -> plotTitle,\n",
  "  FrameLabel -> {", ToString[$iFrameX, InputForm], ", ", ToString[$iFrameY, InputForm], "},\n",
  "  Joined -> True,\n",
  "  PlotRange -> All,\n",
  "  ScalingFunctions -> If[logScale, \"Log\", None],\n",
  "  GridLines -> Automatic,\n",
  "  GridLinesStyle -> Directive[GrayLevel[0.85]],\n",
  "  PlotTheme -> \"Detailed\",\n",
  "  ImageSize -> {1100, 620}]"];

(* supplementary-table cell -- re-coerce via asPairs so the row builder never
   assumes a particular FinancialData shape; num strips Quantity. *)
iCell6[] := StringJoin[
  "(* supplementary table + annotation: name / ticker / base date / base price / last date / last index / note *)\n",
  "summaryRow[disp_, tick_, prop_, pairs0_] := Module[{pairs, valid, base, last},\n",
  "  pairs = asPairs[pairs0];\n",
  "  valid = SortBy[Select[pairs, validPairQ], AbsoluteTime[First[#]] &];\n",
  "  If[valid === {}, Return[{disp, tick, \"-\", \"-\", \"-\", \"-\", \"\"}]];\n",
  "  base = num[valid[[1, 2]]]; last = valid[[-1]];\n",
  "  {disp, tick, DateString[valid[[1, 1]], {\"Year\", \"-\", \"Month\", \"-\", \"Day\"}], base,\n",
  "   DateString[last[[1]], {\"Year\", \"-\", \"Month\", \"-\", \"Day\"}], baseValue num[last[[2]]]/base // N, \"\"}];\n",
  "tblRows = (summaryRow[#, available[#][\"Identifier\"], available[#][\"Property\"], available[#][\"Data\"]] & /@ Keys[available]);\n",
  "Column[{\n",
  "  Grid[Prepend[tblRows, {", ToString[$iTblName, InputForm], ", ", ToString[$iTblTicker, InputForm], ", ",
  ToString[$iTblBaseDate, InputForm], ", ", ToString[$iTblBasePx, InputForm], ", ",
  ToString[$iTblLastDate, InputForm], ", ", ToString[$iTblLastIdx, InputForm], ", ", ToString[$iTblNote, InputForm], "}], Frame -> All],\n",
  "  ", ToString[$iAsOfLabel, InputForm], " <> DateString[endDate],\n",
  "  ", ToString[$iBaseNote, InputForm], ",\n",
  "  ", ToString[$iKioxiaNote, InputForm], ",\n",
  "  ", ToString[$iUnavailLbl, InputForm],
  " <> If[unavailable === {}, ", ToString[$iNone, InputForm],
  ", StringRiffle[unavailable, \", \"]]\n",
  "}]"];

(* spec section 1: the head cell is the EXACT specified Text cell (not a Title).
   spec sections 2-6 follow as Input cells. *)
iBuildNotebook[] := Notebook[{
  Cell[$iTitleCellText, "Text"],
  Cell[iCell2[], "Input"],
  Cell[iCell3[], "Input"],
  Cell[iCell4[], "Input"],
  Cell[iCell5[], "Input"],
  Cell[iCell6[], "Input"]
}];

(* ---- workflow contract ---- *)
WorkflowInfo[] := <|
  "Slug" -> "20260622-\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2",
  "Name" -> "20260622-\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2 \:682a\:4fa1\:76f8\:5bfe\:6307\:6570\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:751f\:6210",
  "Version" -> "1.0.0",
  "Context" -> "SourceVaultWorkflow`W20260622\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2`",
  "Launch" -> "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch",
  "Description" ->
    "2016\:5e74 1 \:6708 1 \:65e5\:3092 100 \:3068\:3057\:305f\:4e3b\:8981\:30c6\:30c3\:30af\:30fb\:534a\:5c0e\:4f53\:682a\:30fb S&P500 \:306e\:76f8\:5bfe\:6307\:6570\:63a8\:79fb\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:751f\:6210\:3059\:308b\:5b8c\:5168\:5b9f\:88c5\:7248\:3002\:30b3\:30f3\:30c6\:30af\:30b9\:30c8\:5148\:982d\:306e\:6570\:5b57\:3092\:907f\:3051\:308b\:305f\:3081 W \:30d7\:30ec\:30d5\:30a3\:30c3\:30af\:30b9\:4ed8\:304d context\:3002AdjustedClose \:512a\:5148\:30fbClose fallback\:3001\:88dc\:9593\:306a\:3057\:3002Launch[\"generate\"] \:3067 6 \:30bb\:30eb\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:ff08\:88dc\:52a9\:8868\:30fb\:5bfe\:6570\:30b9\:30b1\:30fc\:30eb\:5207\:66ff\:542b\:3080\:ff09\:3092\:751f\:6210\:3057\:3001Launch[\"data\"]/[\"plot\"] \:3067\:6700\:65b0\:30c7\:30fc\:30bf\:3092\:53d6\:5f97\:30fb\:63cf\:753b\:3059\:308b\:3002",
  "Routes" -> {}
|>;

(* ---- launch entry: no-argument safe report (NO side effects) ---- *)
\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[] := <|
  "Status" -> "Ready",
  "Mode" -> "report",
  "SideEffects" -> False,
  "Slug" -> "20260622-\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2",
  "Version" -> "1.0.0",
  "Stage" -> 1,
  "StartDate" -> $iStartDate,
  "BaseValue" -> $iBaseValue,
  "EndDatePolicy" -> "until the latest available trading day at run time",
  "BaselinePolicy" -> "first valid price on/after 2016-01-01 is set to 100; a later-listed symbol uses its own first valid day and its baseline-date difference is annotated",
  "PriceProperty" -> $iPriceProperty,
  "PricePropertyNote" -> "prefer AdjustedClose (dividend/split adjusted); on unsupported/empty/failure fall back to Close per identifier and record which was used",
  "MissingPolicy" -> "irregular series of valid trading days only; NO synthetic points (no zero-fill, carry-forward or linear interpolation); adjacent valid points are connected, long/unlisted/unavailable spans are not drawn",
  "DataShapePolicy" -> "FinancialData returns a TimeSeries (NOT a {{date,value},...} list); every series is coerced via DatePath->Path to scalar {date,value} pairs (length-2 only) and Quantity values are stripped, so no series is dropped by a ListQ-only gate or by an unexpected path shape -- both the package logic and the generated notebook cells use this coercion",
  "Series" -> $iSeries,
  "SeriesCount" -> Length[$iSeries],
  "FallbackPolicy" -> "try Primary then Fallbacks in order under Quiet@Check; treat empty/$Failed/Missing as invalid and advance; a symbol with all candidates invalid is collected as unavailable (warning/annotation) while other series continue",
  "SP500Policy" -> "S&P500 uses index (\:6307\:6570) identifiers (^GSPC etc.) only; the ETF / total-return proxy is dropped; if every index candidate is invalid it is reported as unavailable and never substituted",
  "NvidiaPolicy" -> "Nvidia is in Magnificent 7 but is tagged Group->Highlight so it can be emphasized as an individual comparison target without being double-listed",
  "SamsungNote" -> "Samsung: prefer the KRX:005930 code; fall back to a Yahoo-style symbol; if the SSNLF ADR is the last resort, currency/liquidity differences are annotated",
  "KioxiaNote" -> "Kioxia: listed 2024-12 (TSE), so there is no series at the start date; treated as an unlisted span (not missing) and normalized from its first available trading day with a baseline-date note",
  "TableColumns" -> {$iTblName, $iTblTicker, $iTblBaseDate, $iTblBasePx, $iTblLastDate, $iTblLastIdx, $iTblNote},
  "LogScaleOption" -> "Launch[\"plot\", \"Log\" -> True] (or notebook logScale=True) switches the Y axis to a log scale",
  "TitleCellText" -> $iTitleCellText,
  "PlotTitle" -> $iPlotTitle,
  "Launch" -> "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch",
  "Forms" -> {
    "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[\"run\"]  (end-to-end: fetch + chart; async-drivable via SourceVaultRunWorkflowAsync)",
    "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[]",
    "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[\"generate\", \"Export\" -> path]",
    "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[\"normalize\", pairs]",
    "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[\"summary\", display, ticker, prop, pairs]",
    "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[\"data\"]",
    "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch[\"plot\", \"Log\" -> True]"
  }
|>;

(* ---- notebook-generating form: builds the real 6-cell notebook ---- *)
\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch["generate", opts___Rule] :=
  Module[{nb, o, file, res, r},
    nb = iBuildNotebook[];
    o = Association[{opts}];
    file = Lookup[o, "Export", None];
    res = <|
      "Status" -> "Generated",
      "Stage" -> 1,
      "Launch" -> "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch",
      "Title" -> $iTitleCellText,
      "PlotTitle" -> $iPlotTitle,
      "CellCount" -> Length[First[nb]],
      "CellStyles" -> Cases[First[nb], Cell[_, st_, ___] :> st],
      "Notebook" -> nb,
      "File" -> None|>;
    If[StringQ[file],
      r = Quiet @ Check[Export[file, nb, "NB"], $Failed];
      If[r === $Failed, r = Quiet @ Check[(Put[nb, file]; file), $Failed]];
      res["File"] = If[StringQ[file] && FileExistsQ[file], file, $Failed]];
    res];

(* ---- pure normalization form (network-free, testable) ---- *)
\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch["normalize", pairs_List] :=
  iNormalizePairs[pairs];
\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch["normalize", ts_ /; Head[ts] === TimeSeries] :=
  iNormalizePairs[ts];

(* ---- pure summary-row form (network-free, testable) ---- *)
\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch["summary", display_, ticker_, prop_, input_] :=
  iSummaryRow[display, ticker, prop, input];

(* ---- live data form (network): fetch + normalize every series ---- *)
\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch["data", opts___Rule] := iFetchAll[];

(* ---- live plot form (network): fetch + normalize + render ---- *)
\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch["plot", opts___Rule] :=
  Module[{o = Association[{opts}], d, normalized},
    d = iFetchAll[];
    normalized = d["Normalized"];
    If[! AssociationQ[normalized] || normalized === <||>,
      Return[Missing["NoData"]]];
    iPlotGraphic[normalized, TrueQ[Lookup[o, "Log", False]]]];

(* ---- async-drivable end-to-end entry (= "plot"): fetch + normalized chart ----
   generic runner SourceVault`SourceVaultRunWorkflowAsync[slug, "run"] が呼ぶ形。
   自己完結 (引数不要) で成果物 (DateListPlot) を返すので非同期実行に載せられる。 *)
\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch["run", opts___Rule] :=
  \:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch["plot", opts];

End[]  (* `Private` *)

EndPackage[]