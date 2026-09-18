(* ::Package:: *)

(* ============================================================
   SourceVault_papernb.wl -- 取り込み済み論文の和訳ノートブック登録簿

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_papernb.wl"]]

   位置づけ:
     SourceVault に ingest 済みの論文 (src-... / sv://snapshot/...) と、documentation.wl の
     DocImportPaper で作った和訳ノートブックを対応づける登録簿。生成ノートブックは
     元ソースの PrivacyLevel を継承し (CloudPublishable 宣言 = PL < 0.5)、翻訳の LLM 経路も
     その PL で決める (PL >= 0.5 は $ClaudePrivateModel のみ。無ければ fail-closed)。
     一覧 (SourceVaultSourcesView / ArXivView) の「和訳NB」列と、SlideWorkflow の文献解決
     (sv:// / src- を指定したら登録済みの和訳ノートを自動で使う) がこれを引く。

   service-loadable 制約:
     FrontEnd / NBAccess / documentation への依存はすべて DownValues guard 付きの弱結合。
     単体 Get でも動く ($SourceVaultPaperNBRoot を与えればテスト可能)。

   保存:
     <SourceVaultCoreRoot>/papernb/registry.json  (Version 1, Entries)
     <SourceVaultCoreRoot>/papernb/<安全化した題名>_<SourceId>.nb  (既定の生成先)
     File は root 内なら相対パスで持つ (Dropbox の root は PC ごとに違う)。
   ============================================================ *)

BeginPackage["SourceVault`"]

$SourceVaultPaperNBRoot::usage = "$SourceVaultPaperNBRoot は和訳ノートブック登録簿の保存先 (Automatic = SourceVaultCoreRoot[]/papernb、無ければ LOCALAPPDATA/SourceVault/papernb)。テストでは隔離ディレクトリを与える。";
SourceVaultPaperNotebookRoot::usage = "SourceVaultPaperNotebookRoot[] は登録簿と生成ノートブックの保存ディレクトリ (無ければ作る)。";
SourceVaultPaperNotebook::usage = "SourceVaultPaperNotebook[ref] は取り込み済み論文 (src-ID / sv://URI / arxiv:ID / URL) に登録された和訳ノートブックの絶対パスを返す。未登録・ファイル無しは Missing。";
SourceVaultPaperNotebookEntry::usage = "SourceVaultPaperNotebookEntry[ref] は登録簿のエントリ (<|SourceId, URI, File, Title, PrivacyLevel, CloudPublishable, TargetLanguage, Status, ..|>)。未登録は Missing。";
SourceVaultRegisterPaperNotebook::usage = "SourceVaultRegisterPaperNotebook[ref, nbPath, opts] は和訳ノートブックを登録する。PrivacyLevel は元ソースから継承 (\"PrivacyLevel\"->値 で明示可)。\"Declare\"->True (既定) なら NBSetCloudPublishable でノートブックに宣言を書く (PL < 0.5 で Public)。同じ SourceId は上書き (差分マージ)。";
SourceVaultUnregisterPaperNotebook::usage = "SourceVaultUnregisterPaperNotebook[ref] は登録を外す (ファイルは消さない)。";
SourceVaultPaperNotebooks::usage = "SourceVaultPaperNotebooks[] は登録一覧 (連想のリスト。core)。";
SourceVaultPaperNotebooksView::usage = "SourceVaultPaperNotebooksView[] は登録一覧の Dataset (View)。";
SourceVaultPaperNotebookPath::usage = "SourceVaultPaperNotebookPath[ref] は新しく生成するときの既定の保存パス (<root>/<題名>_<SourceId>.nb)。";
SourceVaultSourcePrivacy::usage = "SourceVaultSourcePrivacy[ref] は取り込み済みソースの PrivacyLevel (解決できなければ 1.0 = fail-closed)。";
SourceVaultMakePaperNotebook::usage = "SourceVaultMakePaperNotebook[ref, opts] は取り込み済み論文の和訳ノートブックを DocImportPaper で生成して登録する (登録済みでファイルがあれば生成せず開く。\"Force\"->True で作り直し)。PL を継承: 出力の CloudPublishable = (PL < 0.5)、翻訳の LLM は PL >= 0.5 なら $ClaudePrivateModel のみ。opts: \"Force\" / \"Open\" (Automatic = FE なら開く) / \"Interactive\" (True = 現在のノートブックに評価セルを書いて実行) と DocImportPaper のオプション (\"Pages\" / \"Reconstruct\" / \"TargetLanguage\" / Model / Fallback ...)。";
SourceVaultOpenPaperNotebook::usage = "SourceVaultOpenPaperNotebook[ref] は登録済みの和訳ノートブックを開く (FE)。未登録なら SourceVaultMakePaperNotebook を呼ぶ。";

Begin["`PaperNBPrivate`"]

If[! ValueQ[SourceVault`$SourceVaultPaperNBRoot], SourceVault`$SourceVaultPaperNBRoot = Automatic];

(* ---------------- 保存場所 ---------------- *)

iPNLocalFallbackRoot[] := Module[{base},
  base = Quiet @ Check[Environment["LOCALAPPDATA"], $Failed];
  If[! StringQ[base] || StringLength[base] === 0,
    base = Quiet @ Check[$TemporaryDirectory, "."]];
  FileNameJoin[{base, "SourceVault", "papernb"}]];

iPNResolveRoot[] := Module[{override, core},
  override = SourceVault`$SourceVaultPaperNBRoot;
  If[StringQ[override] && StringLength[override] > 0, Return[override]];
  core = If[Length[DownValues[SourceVault`SourceVaultCoreRoot]] > 0,
    Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed], $Failed];
  If[StringQ[core] && StringLength[core] > 0,
    FileNameJoin[{core, "papernb"}],
    iPNLocalFallbackRoot[]]];

iPNEnsureDirectory[dir_String] := (
  If[! DirectoryQ[dir],
    Quiet @ Check[CreateDirectory[dir, CreateIntermediateDirectories -> True], Null]];
  dir);

SourceVaultPaperNotebookRoot[] := iPNEnsureDirectory[iPNResolveRoot[]];
iPNRegistryFile[] := FileNameJoin[{SourceVaultPaperNotebookRoot[], "registry.json"}];
iPNUTCNow[] := DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z";

(* ---------------- JSON I/O (slidedeck.wl と同じ単一エンコード + Dropbox リトライ) ---------------- *)

iPNJSONSafe[expr_] := expr /. {m_Missing :> Null, None -> Null,
  dt_DateObject :> DateString[dt, "ISODateTime"]};
$iPNRetryCount = 5;
$iPNRetryPause = 0.05;

iPNWriteJSON[path_String, data_] := Module[{ba, dir = DirectoryName[path], tmp, done},
  iPNEnsureDirectory[dir];
  ba = Quiet @ Check[ExportByteArray[iPNJSONSafe[data], "RawJSON"], $Failed];
  If[! ByteArrayQ[ba], Return[$Failed]];
  tmp = path <> ".tmp";
  done = False;
  Do[
    done = TrueQ @ Quiet @ Check[
      Module[{strm = OpenWrite[tmp, BinaryFormat -> True]},
        If[Head[strm] =!= OutputStream, Return[False, Module]];
        WithCleanup[BinaryWrite[strm, ba], Quiet @ Close[strm]];
        RenameFile[tmp, path, OverwriteTarget -> True];
        True],
      False];
    If[done, Break[]];
    Pause[$iPNRetryPause],
    {$iPNRetryCount}];
  If[done, path, $Failed]];

iPNReadJSON[path_String] := Module[{bytes, parsed},
  If[! FileExistsQ[path], Return[Missing["NoFile"]]];
  Do[
    bytes = Quiet @ Check[ReadByteArray[path], $Failed];
    If[ByteArrayQ[bytes],
      parsed = Quiet @ Check[ImportByteArray[bytes, "RawJSON"], $Failed];
      If[parsed =!= $Failed, Return[parsed, Module]]];
    Pause[$iPNRetryPause],
    {$iPNRetryCount}];
  If[ByteArrayQ[bytes], Missing["BadJSON"], Missing["Unreadable"]]];

(* 一覧の描画で 1 行ごとに読むので、ファイル日付でキャッシュする *)
$iPNRegistryCache = None;
iPNReadRegistry[] := Module[{f = iPNRegistryFile[], stamp, raw},
  stamp = {f, If[FileExistsQ[f], Quiet @ Check[FileDate[f, "Modification"], None], None]};
  If[ListQ[$iPNRegistryCache] && $iPNRegistryCache[[1]] === stamp, Return[$iPNRegistryCache[[2]]]];
  raw = iPNReadJSON[f];
  raw = If[AssociationQ[raw], Select[Lookup[raw, "Entries", {}], AssociationQ], {}];
  $iPNRegistryCache = {stamp, raw};
  raw];
iPNWriteRegistry[entries_List] := ($iPNRegistryCache = None;
  iPNWriteJSON[iPNRegistryFile[], <|"Version" -> 1, "UpdatedAtUTC" -> iPNUTCNow[], "Entries" -> entries|>]);

(* ---------------- 参照の解決 ---------------- *)

iPNStr[v_] := Which[StringQ[v], v, v === Null || MissingQ[v] || v === None, "", True, ToString[v]];
iPNSourceRefQ[s_String] := StringStartsQ[s, "src-"] || StringStartsQ[s, "sv://"] ||
  StringStartsQ[s, "arxiv:", IgnoreCase -> True] || StringStartsQ[s, "http://"] || StringStartsQ[s, "https://"];

(* SourceVault 本体が読めていれば SourceVaultResolveReference、無ければ ref だけから最小限。
   SourceVaultResolveReference は "Notebook" キーのためにこの登録簿を引き返すので、その間は
   $iPNNoResolve で再入を止める (実機で RecursionLimit に達した相互再帰の遮断) *)
$iPNNoResolve = False;
iPNEagleRefQ[ref_String] := StringStartsQ[ref, "sv://object/eagle-"] || StringStartsQ[ref, "eagle:", IgnoreCase -> True];
iPNResolveSource[ref_String] := Module[{r},
  (* Eagle の PDF (sv://object/eagle-<id> / eagle:<id>) は Eagle 側の読み口で解決する (SourceVault_eagle.wl)。
     SourceId は無いので登録簿は正準 URI で引く *)
  r = Which[
    iPNEagleRefQ[ref] && Length[DownValues[SourceVault`SourceVaultEagleObjectInfo]] > 0,
      Quiet @ Check[SourceVault`SourceVaultEagleObjectInfo[ref], $Failed],
    ! TrueQ[$iPNNoResolve] && Length[DownValues[SourceVault`SourceVaultResolveReference]] > 0,
      Block[{$iPNNoResolve = True}, Quiet @ Check[SourceVault`SourceVaultResolveReference[ref], $Failed]],
    True, $Failed];
  If[AssociationQ[r] && Lookup[r, "Status", ""] === "OK",
    <|"Status" -> "OK", "SourceId" -> iPNStr[Lookup[r, "SourceId", ""]], "URI" -> iPNStr[Lookup[r, "URI", ""]],
      "File" -> iPNStr[Lookup[r, "File", ""]], "Title" -> iPNStr[Lookup[r, "Title", ""]],
      "PrivacyLevel" -> With[{p = Lookup[r, "PrivacyLevel", 1.0]}, If[NumericQ[p], N[p], 1.0]]|>,
    <|"Status" -> "Unresolved",
      "SourceId" -> If[StringStartsQ[ref, "src-"], ref, ""],
      "URI" -> If[StringStartsQ[ref, "sv://"], ref, ""],
      "File" -> "", "Title" -> "", "PrivacyLevel" -> 1.0|>]];

SourceVaultSourcePrivacy[ref_String] := iPNResolveSource[ref]["PrivacyLevel"];

iPNMatchEntry[entries_List, ref_String, src_Association] := SelectFirst[entries, Function[e,
  With[{sid = iPNStr[Lookup[e, "SourceId", ""]], uri = iPNStr[Lookup[e, "URI", ""]]},
    (sid =!= "" && (sid === ref || sid === src["SourceId"])) ||
    (uri =!= "" && (uri === ref || uri === src["URI"]))]], Missing["NotRegistered"]];

iPNAbsolutePath[e_Association] := Module[{f = iPNStr[Lookup[e, "File", ""]]},
  Which[f === "", "",
    StringMatchQ[f, LetterCharacter ~~ ":" ~~ ___] || StringStartsQ[f, "/"] || StringStartsQ[f, "\\\\"], f,
    True, FileNameJoin[{SourceVaultPaperNotebookRoot[], f}]]];

iPNRelativeFile[path_String] := Module[{root = SourceVaultPaperNotebookRoot[], abs = AbsoluteFileName[path]},
  If[! StringQ[abs], abs = path];
  If[StringStartsQ[abs, root], StringTrim[StringDrop[abs, StringLength[root]], "\\" | "/"], abs]];

(* まず登録簿を ref そのもの (SourceId / URI) で引く。それで見つからないときだけ参照解決を通す
   (一覧の 1 行ごとの呼び出しを O(全ソース走査) にしない・再帰しない) *)
SourceVaultPaperNotebookEntry[ref_String] := Module[{entries = iPNReadRegistry[], e, src},
  e = SelectFirst[entries, Function[x,
    With[{sid = iPNStr[Lookup[x, "SourceId", ""]], uri = iPNStr[Lookup[x, "URI", ""]]},
      (sid =!= "" && sid === ref) || (uri =!= "" && uri === ref)]], Missing["NotRegistered"]];
  If[! AssociationQ[e] && ! TrueQ[$iPNNoResolve],
    src = iPNResolveSource[ref];
    e = iPNMatchEntry[entries, ref, src]];
  If[AssociationQ[e], Append[e, "Notebook" -> iPNAbsolutePath[e]], e]];

SourceVaultPaperNotebook[ref_String] := Module[{e = SourceVaultPaperNotebookEntry[ref]},
  If[! AssociationQ[e], Return[e]];
  If[StringQ[e["Notebook"]] && e["Notebook"] =!= "" && FileExistsQ[e["Notebook"]], e["Notebook"], Missing["NoFile", e["Notebook"]]]];

(* ---------------- 保存パス ---------------- *)

iPNSafeName[s_String] := Module[{t},
  t = StringReplace[StringTrim[s], {"\\" | "/" | ":" | "*" | "?" | "\"" | "<" | ">" | "|" | "\n" | "\r" -> " "}];
  t = StringReplace[t, Whitespace .. -> " "];
  StringTrim[StringTake[t, UpTo[60]]]];

SourceVaultPaperNotebookPath[ref_String] := Module[{src = iPNResolveSource[ref], sid, base},
  sid = Which[src["SourceId"] =!= "", src["SourceId"],
    StringStartsQ[src["URI"], "sv://object/"], StringDrop[src["URI"], StringLength["sv://object/"]],
    True, iPNSafeName[ref]];
  base = If[src["Title"] =!= "", iPNSafeName[src["Title"]] <> "_" <> sid, sid];
  FileNameJoin[{SourceVaultPaperNotebookRoot[], base <> ".nb"}]];

(* ---------------- 登録 ---------------- *)

Options[SourceVaultRegisterPaperNotebook] = {"PrivacyLevel" -> Automatic, "Title" -> Automatic,
  "TargetLanguage" -> Automatic, "Declare" -> True, "Status" -> "OK", "FailedPages" -> {}, "Pages" -> Automatic};
SourceVaultRegisterPaperNotebook[ref_String, nbPath_String, OptionsPattern[]] := Module[
  {src = iPNResolveSource[ref], entries, prior, pa, pl, e, declared = "Skipped", abs},
  abs = With[{a = AbsoluteFileName[nbPath]}, If[StringQ[a], a, nbPath]];
  If[! FileExistsQ[abs],
    Return[Failure["NoFile", <|"MessageTemplate" -> "notebook `1` does not exist", "MessageParameters" -> {nbPath}|>]]];
  pl = OptionValue["PrivacyLevel"];
  If[! NumericQ[pl], pl = src["PrivacyLevel"]];
  pl = Clip[N[pl], {0., 1.}];
  entries = iPNReadRegistry[];
  prior = iPNMatchEntry[entries, ref, src];
  (* 未登録なら prior は Missing: Lookup を通すと未評価式が残り JSON に書けなくなる *)
  pa = If[AssociationQ[prior], prior, <||>];
  e = <|"SourceId" -> If[src["SourceId"] =!= "", src["SourceId"], iPNStr[Lookup[pa, "SourceId", ref]]],
    "URI" -> If[src["URI"] =!= "", src["URI"], iPNStr[Lookup[pa, "URI", ""]]],
    "File" -> iPNRelativeFile[abs],
    "Title" -> With[{t = OptionValue["Title"]}, If[StringQ[t] && t =!= "", t,
      If[src["Title"] =!= "", src["Title"], iPNStr[Lookup[pa, "Title", FileBaseName[abs]]]]]],
    "PrivacyLevel" -> pl, "CloudPublishable" -> (pl < 0.5),
    "TargetLanguage" -> With[{l = OptionValue["TargetLanguage"]}, If[StringQ[l], l, iPNStr[Lookup[pa, "TargetLanguage", $Language]]]],
    "Status" -> iPNStr[OptionValue["Status"]], "FailedPages" -> OptionValue["FailedPages"],
    "Pages" -> Replace[OptionValue["Pages"], Automatic -> Lookup[pa, "Pages", Null]],
    "CreatedAtUTC" -> iPNStr[Lookup[pa, "CreatedAtUTC", iPNUTCNow[]]], "UpdatedAtUTC" -> iPNUTCNow[]|>;
  If[e["CreatedAtUTC"] === "", e["CreatedAtUTC"] = iPNUTCNow[]];
  (* PL の継承をノートブック自身にも宣言する (NBAccess があるときだけ) *)
  If[TrueQ[OptionValue["Declare"]] && Length[DownValues[NBAccess`NBSetCloudPublishable]] > 0,
    declared = With[{r = Quiet @ Check[NBAccess`NBSetCloudPublishable[abs, pl < 0.5], $Failed]},
      If[AssociationQ[r], iPNStr[Lookup[r, "Status", "?"]], "Failed"]]];
  entries = If[AssociationQ[prior], Replace[entries, x_ /; x === prior :> e, {1}], Append[entries, e]];
  If[! StringQ[iPNWriteRegistry[entries]],
    Return[Failure["SaveFailed", <|"MessageTemplate" -> "could not write the notebook registry"|>]]];
  Join[e, <|"Notebook" -> abs, "Declared" -> declared|>]];

SourceVaultUnregisterPaperNotebook[ref_String] := Module[{src = iPNResolveSource[ref], entries, prior},
  entries = iPNReadRegistry[];
  prior = iPNMatchEntry[entries, ref, src];
  If[! AssociationQ[prior], Return[False]];
  StringQ[iPNWriteRegistry[DeleteCases[entries, prior]]]];

SourceVaultPaperNotebooks[] := Map[Append[#, "Notebook" -> iPNAbsolutePath[#]] &, iPNReadRegistry[]];

SourceVaultPaperNotebooksView[] := Dataset[Map[
  <|"SourceId" -> iPNStr[#["SourceId"]], "Title" -> iPNStr[Lookup[#, "Title", ""]],
    "PL" -> Lookup[#, "PrivacyLevel", 1.0], "Public" -> TrueQ[Lookup[#, "CloudPublishable", False]],
    "Language" -> iPNStr[Lookup[#, "TargetLanguage", ""]], "Status" -> iPNStr[Lookup[#, "Status", ""]],
    "Exists" -> FileExistsQ[iPNStr[#["Notebook"]]], "Updated" -> iPNStr[Lookup[#, "UpdatedAtUTC", ""]],
    "Notebook" -> iPNStr[#["Notebook"]]|> &, SourceVaultPaperNotebooks[]]];

(* ---------------- 生成 (DocImportPaper 経由、PL 継承) ---------------- *)

iPNDocImportQ[] := Length[DownValues[Documentation`DocImportPaper]] > 0;

(* PL で LLM 経路を決める: PL >= 0.5 は $ClaudePrivateModel だけ (無ければ fail-closed)。
   PL < 0.5 は既定 (Claude Code CLI / パレットのモデル)。DocImportPaper 自身は PL を見ない *)
iPNRouteModel[pl_?NumericQ, explicit_] := Module[{priv},
  If[ListQ[explicit] && Length[explicit] >= 2, Return[explicit]];
  If[pl < 0.5, Return[Automatic]];
  priv = If[ValueQ[ClaudeCode`$ClaudePrivateModel], ClaudeCode`$ClaudePrivateModel, None];
  If[ListQ[priv] && Length[priv] >= 2, priv, $Failed]];

iPNInsertAndEvaluate[code_String] := Module[{nb = Quiet[InputNotebook[]]},
  If[Head[nb] =!= NotebookObject, Return[$Failed]];
  SelectionMove[nb, After, Notebook];
  NotebookWrite[nb, Cell[BoxData[code], "Input"], All];
  SelectionEvaluate[nb];
  nb];

$iPNOwnOptions = {"Force" -> False, "Open" -> Automatic, "Interactive" -> False, "Verbose" -> True};
SourceVaultMakePaperNotebook[ref_String, opts___Rule] := Module[
  {own = Association[$iPNOwnOptions], src, path, existing, pl, model, fallback, docOpts, res, out, entry, fe},
  own = Join[own, KeyTake[Association[{opts}], Keys[own]]];
  fe = $FrontEnd =!= Null && TrueQ[$Notebooks];
  (* パレット / 一覧ボタンから: 現在のノートブックに評価セルを書いて実行 (進捗が見える・やり直せる) *)
  If[TrueQ[own["Interactive"]] && fe,
    Return[iPNInsertAndEvaluate["SourceVaultMakePaperNotebook[\"" <> ref <> "\"]"]]];
  src = iPNResolveSource[ref];
  existing = SourceVaultPaperNotebook[ref];
  If[StringQ[existing] && ! TrueQ[own["Force"]],
    If[fe && own["Open"] =!= False, iPNOpenNotebookFront[existing]];
    Return[Append[SourceVaultPaperNotebookEntry[ref], "Status" -> "Existing"]]];
  If[src["Status"] =!= "OK" || src["File"] === "" || ! FileExistsQ[src["File"]],
    Return[Failure["SourceNotFound", <|"MessageTemplate" ->
      "`1` is not an ingested source with a local file (SourceVaultResolveReference)", "MessageParameters" -> {ref}|>]]];
  If[! iPNDocImportQ[],
    Return[Failure["DocumentationNotLoaded", <|"MessageTemplate" ->
      "documentation.wl (DocImportPaper) is not loaded"|>]]];
  pl = src["PrivacyLevel"];
  model = iPNRouteModel[pl, Lookup[Association[{opts}], ClaudeCode`Model, Automatic]];
  If[model === $Failed,
    Return[Failure["PrivateModelUnavailable", <|"MessageTemplate" ->
      "PrivacyLevel `1` requires $ClaudePrivateModel (local model); none is configured", "MessageParameters" -> {pl}|>]]];
  fallback = If[pl < 0.5,
    Lookup[Association[{opts}], ClaudeCode`Fallback,
      If[Length[DownValues[ClaudeCode`GetPaletteFallback]] > 0, TrueQ[Quiet @ Check[ClaudeCode`GetPaletteFallback[], False]], False]],
    False];
  path = SourceVaultPaperNotebookPath[ref];
  docOpts = Normal[KeyDrop[Association[{opts}], Join[Keys[own], {ClaudeCode`Model, ClaudeCode`Fallback,
    "OutputPath", "Open", "Save", "CloudPublishable"}]]];
  If[TrueQ[own["Verbose"]],
    Print["SourceVault: ", src["Title"], " (PL ", pl, ", ", If[pl < 0.5, "cloud", "local"], ") -> ", path]];
  res = Documentation`DocImportPaper[src["File"], "OutputPath" -> path, "Open" -> False, "Save" -> True,
    "CloudPublishable" -> (pl < 0.5), ClaudeCode`Model -> model, ClaudeCode`Fallback -> fallback,
    "Verbose" -> own["Verbose"], Sequence @@ docOpts];
  If[! FileExistsQ[path],
    Return[Failure["ImportFailed", <|"MessageTemplate" -> "DocImportPaper did not produce `1`", "MessageParameters" -> {path}|>]]];
  entry = SourceVaultRegisterPaperNotebook[ref, path, "PrivacyLevel" -> pl,
    "Title" -> src["Title"],
    "TargetLanguage" -> With[{l = Lookup[Association[{opts}], "TargetLanguage", Automatic]}, If[StringQ[l], l, $Language]],
    "FailedPages" -> Lookup[Replace[$DocPaperLastAnalysisSafe[], Except[_Association] -> <||>], "FailedPages", {}]];
  If[fe && own["Open"] =!= False, iPNOpenNotebookFront[path]];
  entry];

$DocPaperLastAnalysisSafe[] := If[ValueQ[Documentation`$DocPaperLastAnalysis] && AssociationQ[Documentation`$DocPaperLastAnalysis],
  Documentation`$DocPaperLastAnalysis, <||>];

(* 既に開いているノートは NotebookOpen しても前面に来ないことがある (一覧のボタンから押すと
   「反応はするが開かない」に見える)。開いている窓を探して前面へ、無ければ開いて前面へ *)
iPNOpenNotebookFront[p_String] := Module[{abs, existing, nb},
  abs = With[{a = AbsoluteFileName[p]}, If[StringQ[a], a, p]];
  existing = SelectFirst[Notebooks[],
    Function[n, With[{f = Quiet @ Check[NotebookFileName[n], $Failed]},
      StringQ[f] && (f === abs || Quiet @ Check[AbsoluteFileName[f] === abs, False])]], None];
  nb = If[existing =!= None, existing, Quiet @ Check[NotebookOpen[abs], $Failed]];
  If[Head[nb] === NotebookObject,
    Quiet @ Check[SetOptions[nb, Visible -> True], Null];
    Quiet @ Check[SetSelectedNotebook[nb], Null]];
  nb];

SourceVaultOpenPaperNotebook[ref_String] := Module[{p = SourceVaultPaperNotebook[ref]},
  If[StringQ[p],
    If[$FrontEnd =!= Null && TrueQ[$Notebooks], iPNOpenNotebookFront[p], p],
    SourceVaultMakePaperNotebook[ref, "Interactive" -> True]]];

End[]

EndPackage[]

Print[Style["SourceVault_papernb.wl がロードされました。", Bold]];
Print["
  SourceVaultMakePaperNotebook[\"src-...\"]      → 取り込み済み論文の和訳ノートブックを生成・登録 (PL 継承)
  SourceVaultPaperNotebook[ref]                  → 登録済み和訳ノートブックのパス (SlideWorkflow の文献解決が使う)
  SourceVaultRegisterPaperNotebook[ref, nb]     → 既存ノートブックの登録 (CloudPublishable 宣言つき)
  SourceVaultPaperNotebooks[] / ...View[]        → 一覧
"];
