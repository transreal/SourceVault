#!/usr/bin/env wolframscript
(* ::Package:: *)
(* acceptance test (.wls) for the workflow whose slug CamelCases to the canonical
   context leaf 20260622\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2, which is
   digit-leading and therefore W-prefixed by the registry to
   W20260622\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2.
   Loads via SourceVault`SourceVaultLoadWorkflow and asserts behavior with
   NETWORK-FREE unit tests of the core logic (normalize / summary), INCLUDING
   data-shape handling: a sample TimeSeries (what FinancialData actually returns)
   must NOT be dropped by ListQ, Quantity-valued (currency) series are stripped,
   and sample {date,value} pairs work too.
   Also asserts the spec DISPLAY requirements (section 1 Text cell + graph title)
   and that the GENERATED notebook cells coerce the FinancialData shape robustly.
   Prints PASS/FAIL per check and a final RESULT count. Exit code 1 on any FAIL.
   All Japanese (slug, context, launch symbol, display names, the index token) is
   written with \:XXXX escapes so this script has no raw full-width bytes. *)

$pkgRoot = Module[{d = If[StringQ[$InputFileName] && $InputFileName =!= "",
      DirectoryName[$InputFileName], Directory[]]},
   While[d =!= DirectoryName[d] && ! FileExistsQ[FileNameJoin[{d, "SourceVault.wl"}]],
     d = DirectoryName[d]];
   d];
If[! FileExistsQ[FileNameJoin[{$pkgRoot, "SourceVault.wl"}]],
  $pkgRoot = "F:/Dropbox/Mathematica-oneDrive/MyPackages"];

If[! MemberQ[$Packages, "SourceVault`"],
  Block[{$CharacterEncoding = "UTF-8"}, Get[FileNameJoin[{$pkgRoot, "SourceVault.wl"}]]]];

$pass = 0; $fail = 0;
check[label_, cond_] := If[TrueQ[cond],
  $pass++; Print["PASS: ", label],
  $fail++; Print["FAIL: ", label]];

approxQ[a_, b_] := NumberQ[a] && NumberQ[b] && Abs[a - b] < 0.001;

slug = "20260622-\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2";
ctx  = "SourceVaultWorkflow`W20260622\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2`";
launchName = "\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2Launch";

(* spec DISPLAY literals (must match the package exactly) *)
specTitleCell = "Maginiticent 7\:3068Nvidia, TSMC, Samsung, \:30de\:30a4\:30af\:30ed\:30f3\:3001\:30ad\:30aa\:30af\:30b7\:30a2\:3068S&P500\:30a4\:30f3\:30c7\:30c3\:30af\:30b9\:306e2016/1/1\:3092100\:3068\:3057\:3066\:73fe\:5728\:307e\:3067\:306e\:63a8\:79fb\:306e\:53ef\:8996\:5316";
specPlotTitle = "2016\:5e741\:67081\:65e5\:3092100\:3068\:3057\:305f\:4e3b\:8981\:30c6\:30c3\:30af\:30fb\:534a\:5c0e\:4f53\:95a2\:9023\:9298\:67c4\:3068S&P 500\:306e\:63a8\:79fb";

(* 0. the BeginPackage context MUST equal the registry's slug-derived context
   (digit-leading canonical leaf -> W-prefixed) *)
check["registry derives the W-prefixed canonical context from the slug",
  SourceVault`SourceVaultWorkflowContext[slug] === ctx];
check["the registry-derived context is a valid (non-digit-leading) leaf",
  StringQ[ctx] && StringContainsQ[ctx, "`W20260622"]];

(* 1. load via the on-demand registry *)
load = SourceVault`SourceVaultLoadWorkflow[slug];
check["load status is Loaded/AlreadyLoaded", MatchQ[Lookup[load, "Status"], "Loaded" | "AlreadyLoaded"]];
check["load reports canonical context", Lookup[load, "Context"] === ctx];
check["context is actually registered in $Packages", MemberQ[$Packages, ctx]];

infoFn = Symbol[ctx <> "WorkflowInfo"];
runFn  = Symbol[ctx <> launchName];

(* 2. WorkflowInfo *)
info = infoFn[];
check["WorkflowInfo returns association", AssociationQ[info]];
check["WorkflowInfo has all required keys",
  AssociationQ[info] &&
    And @@ (KeyExistsQ[info, #] & /@ {"Slug", "Name", "Version", "Context", "Launch", "Description", "Routes"})];
check["WorkflowInfo Slug", Lookup[info, "Slug"] === slug];
check["WorkflowInfo Context", Lookup[info, "Context"] === ctx];
check["WorkflowInfo Launch is the Japanese symbol name", Lookup[info, "Launch"] === launchName];
check["WorkflowInfo Version is 1.0.0", Lookup[info, "Version"] === "1.0.0"];
check["WorkflowInfo Routes is {}", Lookup[info, "Routes"] === {}];

(* 3. launch[] safe report -- fully implemented, Status Ready, no side effects *)
rep = runFn[];
check["launch[] returns association", AssociationQ[rep]];
check["report declares no side effects", Lookup[rep, "SideEffects"] === False];
check["report Status is Ready (not a stub)", Lookup[rep, "Status"] === "Ready"];
check["report Series has 12 entries", Length[Lookup[rep, "Series", {}]] === 12];
check["report SeriesCount is 12", Lookup[rep, "SeriesCount"] === 12];
check["report StartDate is {2016,1,1}", Lookup[rep, "StartDate"] === {2016, 1, 1}];
check["report BaseValue is 100", Lookup[rep, "BaseValue"] === 100];
check["report PriceProperty AdjustedClose primary",
  Lookup[Lookup[rep, "PriceProperty", <||>], "Primary"] === "AdjustedClose"];
check["report PriceProperty Close fallback",
  Lookup[Lookup[rep, "PriceProperty", <||>], "Fallback"] === "Close"];
check["report has a FallbackPolicy",
  StringQ[Lookup[rep, "FallbackPolicy"]] && Lookup[rep, "FallbackPolicy"] =!= ""];
check["report has a MissingPolicy",
  StringQ[Lookup[rep, "MissingPolicy"]] && Lookup[rep, "MissingPolicy"] =!= ""];
check["report documents the FinancialData TimeSeries data-shape policy",
  StringQ[Lookup[rep, "DataShapePolicy"]] &&
    StringContainsQ[Lookup[rep, "DataShapePolicy", ""], "TimeSeries"]];
check["report has a NvidiaPolicy (individual highlight, no double-listing)",
  StringQ[Lookup[rep, "NvidiaPolicy"]] && Lookup[rep, "NvidiaPolicy"] =!= ""];
check["report exposes a log-scale option", StringQ[Lookup[rep, "LogScaleOption"]]];
check["report TableColumns has 7 columns (spec section 6)",
  Length[Lookup[rep, "TableColumns", {}]] === 7];
check["SP500 policy mentions the index token",
  StringQ[Lookup[rep, "SP500Policy"]] && StringContainsQ[Lookup[rep, "SP500Policy"], "\:6307\:6570"]];
check["SP500 policy carries no SPY ETF proxy",
  StringQ[Lookup[rep, "SP500Policy"]] && ! StringContainsQ[Lookup[rep, "SP500Policy"], "SPY"]];

(* 3b. spec DISPLAY requirements surfaced in the report *)
check["report TitleCellText is the EXACT spec section-1 Text wording",
  Lookup[rep, "TitleCellText"] === specTitleCell];
check["report PlotTitle is the EXACT spec graph title",
  Lookup[rep, "PlotTitle"] === specPlotTitle];

prims = Lookup[#, "Primary"] & /@ Lookup[rep, "Series", {}];
check["table has ^GSPC as the S&P500 primary (index, not ETF)", MemberQ[prims, "^GSPC"]];
displays = Lookup[#, "Display"] & /@ Lookup[rep, "Series", {}];
check["table includes Samsung display name", MemberQ[displays, "\:30b5\:30e0\:30b9\:30f3\:96fb\:5b50"]];
check["table includes Kioxia display name", MemberQ[displays, "\:30ad\:30aa\:30af\:30b7\:30a2"]];
check["table includes S&P500 display name", MemberQ[displays, "\:ff33\:ff06\:ff30\:ff15\:ff10\:ff10"]];
check["report Launch field is the Japanese symbol name", Lookup[rep, "Launch"] === launchName];

(* 4. normalize form -- real, pure logic on {date,value} pairs *)
norm = runFn["normalize", {{{2016, 1, 1}, 50}, {{2016, 1, 2}, 75}, {{2016, 1, 3}, Missing[]}, {{2016, 1, 4}, 100}}];
check["normalize returns a list", ListQ[norm]];
check["normalize drops the Missing entry (3 valid)", Length[norm] === 3];
check["normalize rebases first valid price to 100", approxQ[norm[[1, 2]], 100.]];
check["normalize scales 75 -> 150", approxQ[norm[[2, 2]], 150.]];
check["normalize scales 100 -> 200", approxQ[norm[[3, 2]], 200.]];

norm2 = runFn["normalize", {{{2016, 1, 1}, Missing[]}, {{2016, 1, 2}, 20}, {{2016, 1, 3}, 30}}];
check["normalize skips a leading invalid value (2 valid)", Length[norm2] === 2];
check["normalize rebases from first VALID value (20 -> 100)", approxQ[norm2[[1, 2]], 100.]];
check["normalize scales 30 -> 150 from that baseline", approxQ[norm2[[2, 2]], 150.]];

norm3 = runFn["normalize", {{{2016, 1, 1}, Missing[]}, {{2016, 1, 2}, $Failed}}];
check["normalize of an all-invalid series returns {}", norm3 === {}];

(* 4b. DATA-SHAPE handling: FinancialData returns a TimeSeries, NOT a list of
   pairs. A TimeSeries fails ListQ, so a ListQ-only gate would silently drop it.
   Feeding a sample TimeSeries here proves the workflow accepts the TimeSeries
   (via DatePath/Path coercion) and rebases it correctly. *)
sampleTs = TimeSeries[{{{2016, 1, 1}, 50.}, {{2016, 1, 2}, 75.}, {{2016, 1, 4}, 100.}}];
check["a sample TimeSeries is recognized (Head is TimeSeries)", Head[sampleTs] === TimeSeries];
check["a sample TimeSeries fails ListQ (the trap we must avoid)", ! ListQ[sampleTs]];
normTs = runFn["normalize", sampleTs];
check["normalize accepts a TimeSeries and returns a list", ListQ[normTs]];
check["normalize does NOT drop the TimeSeries (3 points survive)", Length[normTs] === 3];
check["every normalized TimeSeries entry is a scalar {date,value} pair",
  ListQ[normTs] && AllTrue[normTs, MatchQ[#, {_, _}] && NumberQ[#[[2]]] &]];
check["normalize rebases the TimeSeries first value to 100", approxQ[normTs[[1, 2]], 100.]];
check["normalize scales the TimeSeries 75 -> 150", approxQ[normTs[[2, 2]], 150.]];
check["normalize scales the TimeSeries 100 -> 200", approxQ[normTs[[3, 2]], 200.]];

(* 4c. Quantity-valued series: real FinancialData prices can be Quantity
   (currency). The shape handling must STRIP the currency, not drop the point.
   Test both a Quantity-valued list and a Quantity-valued TimeSeries. *)
qList = {{{2016, 1, 1}, Quantity[50., "USDollars"]}, {{2016, 1, 2}, Quantity[100., "USDollars"]}};
normQ = runFn["normalize", qList];
check["normalize strips Quantity values in a list (2 points)", Length[normQ] === 2];
check["normalize rebases the Quantity list first value to 100", approxQ[normQ[[1, 2]], 100.]];
check["normalize scales the Quantity list 100usd -> 200", approxQ[normQ[[2, 2]], 200.]];

qTs = TimeSeries[{{{2016, 1, 1}, Quantity[40., "KRW"]}, {{2016, 1, 3}, Quantity[120., "KRW"]}}];
normQTs = runFn["normalize", qTs];
check["normalize strips Quantity values in a TimeSeries (2 points survive)", Length[normQTs] === 2];
check["normalize rebases the Quantity TimeSeries first value to 100", approxQ[normQTs[[1, 2]], 100.]];
check["normalize scales the Quantity TimeSeries 40krw -> 300", approxQ[normQTs[[2, 2]], 300.]];

(* 5. summary form -- supplementary table row (spec section 6), pure logic *)
sum = runFn["summary", "\:30a2\:30c3\:30d7\:30eb", "AAPL", "AdjustedClose",
  {{{2016, 1, 1}, 50}, {{2016, 1, 5}, 200}}];
check["summary returns an association", AssociationQ[sum]];
check["summary Display preserved", Lookup[sum, "Display"] === "\:30a2\:30c3\:30d7\:30eb"];
check["summary Ticker preserved", Lookup[sum, "Ticker"] === "AAPL"];
check["summary BaseDate is the first valid day", Lookup[sum, "BaseDate"] === {2016, 1, 1}];
check["summary BasePrice is the first valid price (50)", approxQ[Lookup[sum, "BasePrice"], 50]];
check["summary LastIndex rebases the last value (200 -> 400)", approxQ[Lookup[sum, "LastIndex"], 400.]];

sumTs = runFn["summary", "X", "TST", "Close", sampleTs];
check["summary accepts a TimeSeries (BasePrice 50)", approxQ[Lookup[sumTs, "BasePrice"], 50.]];
check["summary on a TimeSeries rebases last (100 -> 200)", approxQ[Lookup[sumTs, "LastIndex"], 200.]];

sumQTs = runFn["summary", "Y", "QRW", "Close", qTs];
check["summary strips Quantity from a TimeSeries (BasePrice 40)", approxQ[Lookup[sumQTs, "BasePrice"], 40.]];
check["summary on a Quantity TimeSeries rebases last (40 -> 300)", approxQ[Lookup[sumQTs, "LastIndex"], 300.]];

sumEmpty = runFn["summary", "Z", "NA", "Close", {{{2016, 1, 1}, Missing[]}}];
check["summary of an all-invalid series reports Missing BasePrice", MissingQ[Lookup[sumEmpty, "BasePrice"]]];

(* 6. generate form -- builds the real 6-cell notebook *)
gen = runFn["generate"];
check["generate returns association", AssociationQ[gen]];
check["generate Status is Generated (not a stub)", Lookup[gen, "Status"] === "Generated"];
check["generate CellCount is 6", Lookup[gen, "CellCount"] === 6];
nb = Lookup[gen, "Notebook"];
check["generate Notebook head is Notebook", Head[nb] === Notebook];
check["generate Notebook actually holds 6 cells", Length[First[nb]] === 6];
styles = Lookup[gen, "CellStyles", {}];
check["first cell is a Text cell (spec section 1)", First[styles] === "Text"];
check["remaining 5 cells are Input cells", Rest[styles] === {"Input", "Input", "Input", "Input", "Input"}];

(* 6b. spec section 1: the head Text cell carries the EXACT specified wording *)
check["first cell text is the EXACT spec section-1 Text wording",
  First[First[nb]][[1]] === specTitleCell];
check["generate Title equals the spec Text-cell wording",
  Lookup[gen, "Title"] === specTitleCell];
check["generate PlotTitle equals the EXACT spec graph title",
  Lookup[gen, "PlotTitle"] === specPlotTitle];
check["notebook title cell equals the generate Title field",
  First[First[nb]][[1]] === Lookup[gen, "Title"]];

codeCells = Cases[First[nb], Cell[s_String, _, ___] :> s];
allCode = StringRiffle[codeCells, "\n"];
check["notebook code fetches via FinancialData", StringContainsQ[allCode, "FinancialData"]];
check["notebook code prefers AdjustedClose", StringContainsQ[allCode, "AdjustedClose"]];
check["notebook code falls back to Close", StringContainsQ[allCode, "Close"]];
check["notebook code handles the TimeSeries shape (asPairs)",
  StringContainsQ[allCode, "asPairs"]];
check["notebook code coerces via DatePath then Path",
  StringContainsQ[allCode, "DatePath"] && StringContainsQ[allCode, "Path"]];
check["notebook code keeps only scalar {_,_} pairs (coercePairs)",
  StringContainsQ[allCode, "coercePairs"]];
check["notebook normalize re-coerces its input via asPairs (no raw-list assumption)",
  StringContainsQ[allCode, "normalize[pairs0_]"] && StringContainsQ[allCode, "asPairs[pairs0]"]];
check["notebook summary re-coerces its input via asPairs",
  StringContainsQ[allCode, "summaryRow[disp_, tick_, prop_, pairs0_]"]];
check["notebook code normalizes (rebases to baseValue)",
  StringContainsQ[allCode, "normalize"] && StringContainsQ[allCode, "baseValue"]];
check["notebook code visualizes via DateListPlot", StringContainsQ[allCode, "DateListPlot"]];
check["notebook code exposes a log-scale toggle", StringContainsQ[allCode, "logScale"]];
check["notebook code builds the supplementary Grid table", StringContainsQ[allCode, "Grid"]];
check["notebook code carries the EXACT spec graph title", StringContainsQ[allCode, specPlotTitle]];
check["notebook code carries the S&P500 display token (full-width)",
  StringContainsQ[allCode, "\:ff33\:ff06\:ff30\:ff15\:ff10\:ff10"]];

(* 7. generate with Export -> writes a .nb file *)
tmpNb = FileNameJoin[{DirectoryName[$InputFileName], "_gen_test_kabu2.nb"}];
If[FileExistsQ[tmpNb], Quiet @ DeleteFile[tmpNb]];
gen2 = runFn["generate", "Export" -> tmpNb];
check["generate Export writes the .nb file", FileExistsQ[tmpNb]];
check["generate Export reports the written path", Lookup[gen2, "File"] === tmpNb];
If[FileExistsQ[tmpNb], Quiet @ DeleteFile[tmpNb]];

(* 8. manifest.json: present beside this script, relative paths, consistent meta *)
mfPath = FileNameJoin[{DirectoryName[$InputFileName], "manifest.json"}];
check["manifest.json exists beside the package", FileExistsQ[mfPath]];
mf = If[FileExistsQ[mfPath], Quiet @ Import[mfPath, "RawJSON"], $Failed];
check["manifest.json parses to an association", AssociationQ[mf]];
check["manifest Slug matches the workflow slug",
  AssociationQ[mf] && Lookup[mf, "Slug"] === slug];
check["manifest Context matches the canonical context",
  AssociationQ[mf] && Lookup[mf, "Context"] === ctx];
check["manifest Launch matches the launch symbol name",
  AssociationQ[mf] && Lookup[mf, "Launch"] === launchName];
check["manifest Version matches (1.0.0)", AssociationQ[mf] && Lookup[mf, "Version"] === "1.0.0"];
check["manifest Files are all RELATIVE paths (no drive/leading slash)",
  AssociationQ[mf] && With[{fs = Lookup[mf, "Files", {}]},
    ListQ[fs] && fs =!= {} &&
      AllTrue[fs, StringQ[#] && ! StringStartsQ[#, "/"] &&
        ! StringMatchQ[#, RegularExpression["[A-Za-z]:.*"]] &]]];
check["manifest lists the main .wl (relative)",
  AssociationQ[mf] && MemberQ[Lookup[mf, "Files", {}],
    "SVWorkflow_W20260622\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2.wl"]];
check["manifest MainFile is the main .wl",
  AssociationQ[mf] && Lookup[mf, "MainFile"] ===
    "SVWorkflow_W20260622\:682a\:4fa1\:63a8\:79fb\:30ef\:30fc\:30af\:30d5\:30ed\:30fc2.wl"];

Print["RESULT: ", $pass, " passed, ", $fail, " failed"];
If[$fail > 0, Exit[1], Exit[0]];