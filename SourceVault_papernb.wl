(* ::Package:: *)

(* ============================================================
   SourceVault_papernb.wl -- \:53d6\:308a\:8fbc\:307f\:6e08\:307f\:30bd\:30fc\:30b9 (\:8ad6\:6587 PDF\:30fbWeb \:30da\:30fc\:30b8) \:306e\:7ffb\:8a33\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:767b\:9332\:7c3f

   \:7ffb\:8a33\:30ce\:30fc\:30c8\:30d6\:30c3\:30af (2026-10-12\:3001\:65e7\:79f0\:300c\:548c\:8a33\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:300d):
     \:8a33\:5148\:306f $Language (\:591a\:8a00\:8a9e\:306e\:5229\:7528\:8005\:304c\:305d\:308c\:305e\:308c\:306e\:8a00\:8a9e\:3067\:4f5c\:308b)\:3002\:539f\:6587\:304c\:540c\:3058\:8a00\:8a9e\:306a\:3089\:7ffb\:8a33\:305b\:305a\:69cb\:9020\:5316\:3060\:3051\:884c\:3046
     (\:5224\:5b9a\:306f documentation \:306e DocPaperDetectLanguage)\:3002\:767b\:9332\:7c3f\:306f (\:30bd\:30fc\:30b9, TargetLanguage) \:3054\:3068\:306b 1 \:4ef6\:3002
     PDF \:306f DocImportPaper\:3001Web \:30da\:30fc\:30b8 (HTML / \:30c6\:30ad\:30b9\:30c8 / Markdown) \:306f DocImportWebPage \:3067\:4f5c\:308b\:3002

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_papernb.wl"]]

   \:4f4d\:7f6e\:3065\:3051:
     SourceVault \:306b ingest \:6e08\:307f\:306e\:8ad6\:6587 (src-... / sv://snapshot/...) \:3068\:3001documentation.wl \:306e
     DocImportPaper \:3067\:4f5c\:3063\:305f\:7ffb\:8a33\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:5bfe\:5fdc\:3065\:3051\:308b\:767b\:9332\:7c3f\:3002\:751f\:6210\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306f
     \:5143\:30bd\:30fc\:30b9\:306e PrivacyLevel \:3092\:7d99\:627f\:3057 (CloudPublishable \:5ba3\:8a00 = PL < 0.5)\:3001\:7ffb\:8a33\:306e LLM \:7d4c\:8def\:3082
     \:305d\:306e PL \:3067\:6c7a\:3081\:308b (PL >= 0.5 \:306f $ClaudePrivateModel \:306e\:307f\:3002\:7121\:3051\:308c\:3070 fail-closed)\:3002
     \:4e00\:89a7 (SourceVaultSourcesView / ArXivView) \:306e\:300c\:7ffb\:8a33NB\:300d\:5217\:3068\:3001SlideWorkflow \:306e\:6587\:732e\:89e3\:6c7a
     (sv:// / src- \:3092\:6307\:5b9a\:3057\:305f\:3089\:767b\:9332\:6e08\:307f\:306e\:7ffb\:8a33\:30ce\:30fc\:30c8\:3092\:81ea\:52d5\:3067\:4f7f\:3046) \:304c\:3053\:308c\:3092\:5f15\:304f\:3002

   service-loadable \:5236\:7d04:
     FrontEnd / NBAccess / documentation \:3078\:306e\:4f9d\:5b58\:306f\:3059\:3079\:3066 DownValues guard \:4ed8\:304d\:306e\:5f31\:7d50\:5408\:3002
     \:5358\:4f53 Get \:3067\:3082\:52d5\:304f ($SourceVaultPaperNBRoot \:3092\:4e0e\:3048\:308c\:3070\:30c6\:30b9\:30c8\:53ef\:80fd)\:3002

   \:4fdd\:5b58:
     <SourceVaultCoreRoot>/papernb/registry.json  (Version 1, Entries)
     <SourceVaultCoreRoot>/papernb/<\:5b89\:5168\:5316\:3057\:305f\:984c\:540d>_<SourceId>.nb  (\:65e2\:5b9a\:306e\:751f\:6210\:5148)
     File \:306f root \:5185\:306a\:3089\:76f8\:5bfe\:30d1\:30b9\:3067\:6301\:3064 (Dropbox \:306e root \:306f PC \:3054\:3068\:306b\:9055\:3046)\:3002
   ============================================================ *)

BeginPackage["SourceVault`"]

$SourceVaultPaperNBRoot::usage = "$SourceVaultPaperNBRoot \:306f\:7ffb\:8a33\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:767b\:9332\:7c3f\:306e\:4fdd\:5b58\:5148 (Automatic = SourceVaultCoreRoot[]/papernb\:3001\:7121\:3051\:308c\:3070 LOCALAPPDATA/SourceVault/papernb)\:3002\:30c6\:30b9\:30c8\:3067\:306f\:9694\:96e2\:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:3092\:4e0e\:3048\:308b\:3002";
SourceVaultPaperNotebookRoot::usage = "SourceVaultPaperNotebookRoot[] \:306f\:767b\:9332\:7c3f\:3068\:751f\:6210\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:4fdd\:5b58\:30c7\:30a3\:30ec\:30af\:30c8\:30ea (\:7121\:3051\:308c\:3070\:4f5c\:308b)\:3002";
SourceVaultPaperNotebook::usage = "SourceVaultPaperNotebook[ref, opts] \:306f\:53d6\:308a\:8fbc\:307f\:6e08\:307f\:30bd\:30fc\:30b9 (src-ID / sv://URI / arxiv:ID / URL / Eagle) \:306b\:767b\:9332\:3055\:308c\:305f\:7ffb\:8a33\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:7d76\:5bfe\:30d1\:30b9\:3092\:8fd4\:3059\:3002\:672a\:767b\:9332\:30fb\:30d5\:30a1\:30a4\:30eb\:7121\:3057\:306f Missing\:3002\"Language\" -> Automatic (\:65e2\:5b9a: $Language \:306e\:8a33\:3092\:512a\:5148\:3057\:3001\:7121\:3051\:308c\:3070\:4ed6\:306e\:8a00\:8a9e\:306e\:767b\:9332) | \"English\" \:7b49 (\:305d\:306e\:8a00\:8a9e\:306e\:767b\:9332\:3060\:3051)\:3002";
SourceVaultPaperNotebookEntry::usage = "SourceVaultPaperNotebookEntry[ref, opts] \:306f\:767b\:9332\:7c3f\:306e\:30a8\:30f3\:30c8\:30ea (<|SourceId, URI, File, Title, PrivacyLevel, CloudPublishable, TargetLanguage, SourceLanguage, Translated, Format, Status, ..|>)\:3002\:672a\:767b\:9332\:306f Missing\:3002\"Language\" \:306f SourceVaultPaperNotebook \:3068\:540c\:3058\:3002";
SourceVaultRegisterPaperNotebook::usage = "SourceVaultRegisterPaperNotebook[ref, nbPath, opts] \:306f\:7ffb\:8a33\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:767b\:9332\:3059\:308b\:3002PL \:306f\:5143\:30bd\:30fc\:30b9\:304b\:3089\:7d99\:627f (\"PrivacyLevel\"->\:5024 \:3067\:660e\:793a\:53ef)\:3002\"Declare\"->True (\:65e2\:5b9a) \:306a\:3089 NBSetCloudPublishable \:3067\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306b\:5ba3\:8a00\:3092\:66f8\:304f (PL < 0.5 \:3067 Public)\:3002\:767b\:9332\:306f (\:30bd\:30fc\:30b9, \"TargetLanguage\") \:3054\:3068: \:540c\:3058\:7d44\:306f\:4e0a\:66f8\:304d (\:5dee\:5206\:30de\:30fc\:30b8)\:3001TargetLanguage \:304c Automatic \:306a\:3089\:65e2\:5b58\:306e\:767b\:9332 ($Language \:512a\:5148) \:3092\:66f4\:65b0\:3059\:308b\:3002\"SourceLanguage\" / \"Translated\" / \"Format\" (pdf / html / markdown / text) \:3082\:8a18\:9332\:3059\:308b\:3002";
SourceVaultUnregisterPaperNotebook::usage = "SourceVaultUnregisterPaperNotebook[ref, opts] \:306f\:767b\:9332\:3092\:5916\:3059 (\:30d5\:30a1\:30a4\:30eb\:306f\:6d88\:3055\:306a\:3044)\:3002\"Language\" -> Automatic (SourceVaultPaperNotebookEntry \:304c\:8fd4\:3059 1 \:4ef6) | \:8a00\:8a9e\:540d | All (\:305d\:306e\:30bd\:30fc\:30b9\:306e\:5168\:8a00\:8a9e)\:3002";
SourceVaultPaperNotebooks::usage = "SourceVaultPaperNotebooks[] \:306f\:767b\:9332\:4e00\:89a7 (\:9023\:60f3\:306e\:30ea\:30b9\:30c8\:3002core)\:3002";
SourceVaultPaperNotebooksView::usage = "SourceVaultPaperNotebooksView[] \:306f\:767b\:9332\:4e00\:89a7\:306e Dataset (View)\:3002";
SourceVaultPaperNotebookPath::usage = "SourceVaultPaperNotebookPath[ref] \:306f\:65b0\:3057\:304f\:751f\:6210\:3059\:308b\:3068\:304d\:306e\:65e2\:5b9a\:306e\:4fdd\:5b58\:30d1\:30b9 (<root>/<\:984c\:540d>_<SourceId>.nb)\:3002SourceVaultPaperNotebookPath[ref, lang] \:306f\:8a00\:8a9e\:540d\:3092\:4ed8\:3051\:305f\:30d1\:30b9 (<root>/<\:984c\:540d>_<SourceId>_<lang>.nb\:3002\:65e2\:5b9a\:306e\:30d1\:30b9\:3092\:5225\:306e\:8a00\:8a9e\:306e\:767b\:9332\:304c\:4f7f\:3063\:3066\:3044\:308b\:3068\:304d\:306b\:4f7f\:3046)\:3002";
SourceVaultSourcePrivacy::usage = "SourceVaultSourcePrivacy[ref] \:306f\:53d6\:308a\:8fbc\:307f\:6e08\:307f\:30bd\:30fc\:30b9\:306e PrivacyLevel (\:89e3\:6c7a\:3067\:304d\:306a\:3051\:308c\:3070 1.0 = fail-closed)\:3002";
SourceVaultMakePaperNotebook::usage = "SourceVaultMakePaperNotebook[ref, opts] \:306f\:53d6\:308a\:8fbc\:307f\:6e08\:307f\:30bd\:30fc\:30b9\:306e\:7ffb\:8a33\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:751f\:6210\:3057\:3066\:767b\:9332\:3059\:308b\:3002PDF \:306f DocImportPaper\:3001Web \:30da\:30fc\:30b8 (HTML / \:30c6\:30ad\:30b9\:30c8 / Markdown\:3002\:7a2e\:5225 web \:306e\:30bd\:30fc\:30b9) \:306f DocImportWebPage \:3067\:4f5c\:308b\:3002\:8a33\:5148\:306f \"TargetLanguage\" (\:65e2\:5b9a $Language) \:3067\:3001\:539f\:6587\:304c\:540c\:3058\:8a00\:8a9e\:306a\:3089\:7ffb\:8a33\:305b\:305a\:69cb\:9020\:5316\:3060\:3051\:884c\:3046\:3002\:305d\:306e\:8a00\:8a9e\:3067\:767b\:9332\:6e08\:307f\:3067\:30d5\:30a1\:30a4\:30eb\:304c\:3042\:308c\:3070\:751f\:6210\:305b\:305a\:958b\:304f (\"Force\"->True \:3067\:4f5c\:308a\:76f4\:3057)\:3002PL \:3092\:7d99\:627f: \:51fa\:529b\:306e CloudPublishable = (PL < 0.5)\:3001\:7ffb\:8a33\:306e LLM \:306f PL >= 0.5 \:306a\:3089 $ClaudePrivateModel \:306e\:307f\:3002opts: \"Force\" / \"Open\" (Automatic = FE \:306a\:3089\:958b\:304f) / \"Interactive\" (True = \:73fe\:5728\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306b\:8a55\:4fa1\:30bb\:30eb\:3092\:66f8\:3044\:3066\:5b9f\:884c) \:3068 DocImportPaper / DocImportWebPage \:306e\:30aa\:30d7\:30b7\:30e7\:30f3 (\"Pages\" / \"Reconstruct\" / \"Translate\" / \"Images\" / Model / Fallback ...)\:3002\"PreferPDF\" -> Automatic: web \:306e\:8ad6\:6587\:30da\:30fc\:30b8\:306b\:30aa\:30fc\:30d7\:30f3\:30a2\:30af\:30bb\:30b9 PDF \:304c\:7d50\:3070\:308c\:3066\:3044\:308c\:3070 (SourceVault_oapdf.wl\:3001\:672a\:78ba\:8a8d\:306a\:3089\:3053\:3053\:3067\:63a2\:3057\:3066\:53d6\:308a\:8fbc\:3080) PDF \:304b\:3089 DocImportPaper \:3067\:4f5c\:308b (False \:3067 HTML \:304b\:3089)\:3002";
SourceVaultOpenPaperNotebook::usage = "SourceVaultOpenPaperNotebook[ref] \:306f $Language \:306e\:7ffb\:8a33\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:958b\:304f (FE)\:3002\:672a\:767b\:9332\:306a\:3089 SourceVaultMakePaperNotebook \:3092\:547c\:3076\:3002";
$SourceVaultComputeNBRoot::usage = "$SourceVaultComputeNBRoot \:306f\:8a08\:7b97\:30ce\:30fc\:30c8\:767b\:9332\:7c3f\:306e\:4fdd\:5b58\:5148 (Automatic = SourceVaultCoreRoot[]/computenb)\:3002";
SourceVaultComputeNotebookRoot::usage = "SourceVaultComputeNotebookRoot[] \:306f\:8a08\:7b97\:30ce\:30fc\:30c8\:306e\:767b\:9332\:7c3f\:3068\:65e2\:5b9a\:306e\:4fdd\:5b58\:5148\:306e\:30c7\:30a3\:30ec\:30af\:30c8\:30ea (\:7121\:3051\:308c\:3070\:4f5c\:308b)\:3002";
SourceVaultComputeNotebookPath::usage = "SourceVaultComputeNotebookPath[title, id] \:306f\:65b0\:3057\:304f\:4f5c\:308b\:8a08\:7b97\:30ce\:30fc\:30c8\:306e\:65e2\:5b9a\:306e\:4fdd\:5b58\:30d1\:30b9 (<root>/<\:984c\:540d>_<Id>.nb)\:3002";
SourceVaultRegisterComputeNotebook::usage = "SourceVaultRegisterComputeNotebook[nbPath, opts] \:306f\:8a08\:7b97\:30ce\:30fc\:30c8 (\:7d20\:6750\:304b\:3089\:4f5c\:3063\:305f Mathematica \:306e\:8a08\:7b97\:3068\:7d50\:679c\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af) \:3092 SourceVault \:306b\:767b\:9332\:3059\:308b\:3002Id = cnb-<8 \:6841>\:3001URI = sv://computenb/<Id>\:3002opts: \"Id\" (\:65e2\:5b9a Automatic = \:540c\:3058\:30d5\:30a1\:30a4\:30eb\:306e\:767b\:9332\:3092\:5f15\:304d\:7d99\:3050\:304b\:65b0\:898f)\:3001\"Title\"\:3001\"Sources\" ({<|\"Key\", \"Ref\"|>..} \:7d20\:6750\:306e locator)\:3001\"PrivacyLevel\" (Automatic = \:7d20\:6750\:306e\:6700\:5927\:3002sv:// / src- / Eagle \:306f\:89e3\:6c7a\:3057\:305f PL \:3067\:3001\:89e3\:3051\:306a\:3051\:308c\:3070 1.0\:3001\:8a08\:7b97\:30ce\:30fc\:30c8\:306f\:305d\:306e\:767b\:9332\:306e PL\:3001URL\:30fbarXiv\:30fb\:30d5\:30a1\:30a4\:30eb\:30fbKG \:30ce\:30fc\:30c9\:306f 0)\:3001\"Language\"\:3001\"Units\"\:3001\"Graph\" (\:30ce\:30fc\:30c8\:306e KG\:3001\:65e2\:5b9a Id)\:3001\"Status\"\:3001\"Copy\" (True \:3067\:767b\:9332\:7c3f\:306e\:5834\:6240\:3078\:5199\:3059)\:3001\"Declare\" (CloudPublishable \:306e\:5ba3\:8a00)\:3002";
SourceVaultComputeNotebookEntry::usage = "SourceVaultComputeNotebookEntry[ref] \:306f\:8a08\:7b97\:30ce\:30fc\:30c8\:306e\:767b\:9332 (ref = Id / sv://computenb/<Id> / \:767b\:9332\:3057\:305f\:30d5\:30a1\:30a4\:30eb\:306e\:30d1\:30b9)\:3002\:672a\:767b\:9332\:306f Missing\:3002";
SourceVaultComputeNotebook::usage = "SourceVaultComputeNotebook[ref] \:306f\:767b\:9332\:3055\:308c\:305f\:8a08\:7b97\:30ce\:30fc\:30c8\:306e\:7d76\:5bfe\:30d1\:30b9 (\:7121\:3051\:308c\:3070 Missing)\:3002SlideWorkflow \:306e\:6587\:732e\:89e3\:6c7a\:304c sv://computenb/<Id> \:3092\:3053\:308c\:3067\:5f15\:304f\:3002";
SourceVaultComputeNotebooks::usage = "SourceVaultComputeNotebooks[] \:306f\:8a08\:7b97\:30ce\:30fc\:30c8\:306e\:767b\:9332\:4e00\:89a7 (\:9023\:60f3\:306e\:30ea\:30b9\:30c8)\:3002";
SourceVaultComputeNotebooksView::usage = "SourceVaultComputeNotebooksView[] \:306f\:8a08\:7b97\:30ce\:30fc\:30c8\:306e\:767b\:9332\:4e00\:89a7\:306e Dataset\:3002";
SourceVaultUnregisterComputeNotebook::usage = "SourceVaultUnregisterComputeNotebook[ref] \:306f\:8a08\:7b97\:30ce\:30fc\:30c8\:306e\:767b\:9332\:3092\:5916\:3059 (\:30d5\:30a1\:30a4\:30eb\:306f\:6d88\:3055\:306a\:3044)\:3002";

Begin["`PaperNBPrivate`"]

If[! ValueQ[SourceVault`$SourceVaultPaperNBRoot], SourceVault`$SourceVaultPaperNBRoot = Automatic];

(* ---------------- \:4fdd\:5b58\:5834\:6240 ---------------- *)

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

(* ---------------- JSON I/O (slidedeck.wl \:3068\:540c\:3058\:5358\:4e00\:30a8\:30f3\:30b3\:30fc\:30c9 + Dropbox \:30ea\:30c8\:30e9\:30a4) ---------------- *)

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

(* \:4e00\:89a7\:306e\:63cf\:753b\:3067 1 \:884c\:3054\:3068\:306b\:8aad\:3080\:306e\:3067\:3001\:30d5\:30a1\:30a4\:30eb\:65e5\:4ed8\:3067\:30ad\:30e3\:30c3\:30b7\:30e5\:3059\:308b *)
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

(* ---------------- \:53c2\:7167\:306e\:89e3\:6c7a ---------------- *)

iPNStr[v_] := Which[StringQ[v], v, v === Null || MissingQ[v] || v === None, "", True, ToString[v]];
iPNSourceRefQ[s_String] := StringStartsQ[s, "src-"] || StringStartsQ[s, "sv://"] ||
  StringStartsQ[s, "arxiv:", IgnoreCase -> True] || StringStartsQ[s, "http://"] || StringStartsQ[s, "https://"];

(* SourceVault \:672c\:4f53\:304c\:8aad\:3081\:3066\:3044\:308c\:3070 SourceVaultResolveReference\:3001\:7121\:3051\:308c\:3070 ref \:3060\:3051\:304b\:3089\:6700\:5c0f\:9650\:3002
   SourceVaultResolveReference \:306f "Notebook" \:30ad\:30fc\:306e\:305f\:3081\:306b\:3053\:306e\:767b\:9332\:7c3f\:3092\:5f15\:304d\:8fd4\:3059\:306e\:3067\:3001\:305d\:306e\:9593\:306f
   $iPNNoResolve \:3067\:518d\:5165\:3092\:6b62\:3081\:308b (\:5b9f\:6a5f\:3067 RecursionLimit \:306b\:9054\:3057\:305f\:76f8\:4e92\:518d\:5e30\:306e\:906e\:65ad) *)
$iPNNoResolve = False;
iPNEagleRefQ[ref_String] := StringStartsQ[ref, "sv://object/eagle-"] || StringStartsQ[ref, "eagle:", IgnoreCase -> True];
iPNResolveSource[ref_String] := Module[{r},
  (* Eagle \:306e PDF (sv://object/eagle-<id> / eagle:<id>) \:306f Eagle \:5074\:306e\:8aad\:307f\:53e3\:3067\:89e3\:6c7a\:3059\:308b (SourceVault_eagle.wl)\:3002
     SourceId \:306f\:7121\:3044\:306e\:3067\:767b\:9332\:7c3f\:306f\:6b63\:6e96 URI \:3067\:5f15\:304f *)
  r = Which[
    iPNEagleRefQ[ref] && Length[DownValues[SourceVault`SourceVaultEagleObjectInfo]] > 0,
      Quiet @ Check[SourceVault`SourceVaultEagleObjectInfo[ref], $Failed],
    ! TrueQ[$iPNNoResolve] && Length[DownValues[SourceVault`SourceVaultResolveReference]] > 0,
      Block[{$iPNNoResolve = True}, Quiet @ Check[SourceVault`SourceVaultResolveReference[ref], $Failed]],
    True, $Failed];
  If[AssociationQ[r] && Lookup[r, "Status", ""] === "OK",
    <|"Status" -> "OK", "SourceId" -> iPNStr[Lookup[r, "SourceId", ""]], "URI" -> iPNStr[Lookup[r, "URI", ""]],
      "File" -> iPNStr[Lookup[r, "File", ""]], "Title" -> iPNStr[Lookup[r, "Title", ""]],
      "URL" -> iPNStr[Lookup[r, "URL", ""]], "Kind" -> iPNStr[Lookup[r, "Kind", ""]],
      "PrivacyLevel" -> With[{p = Lookup[r, "PrivacyLevel", 1.0]}, If[NumericQ[p], N[p], 1.0]]|>,
    <|"Status" -> "Unresolved",
      "SourceId" -> If[StringStartsQ[ref, "src-"], ref, ""],
      "URI" -> If[StringStartsQ[ref, "sv://"], ref, ""],
      "File" -> "", "Title" -> "", "URL" -> "", "Kind" -> "", "PrivacyLevel" -> 1.0|>]];

SourceVaultSourcePrivacy[ref_String] := iPNResolveSource[ref]["PrivacyLevel"];

(* \:5143\:30bd\:30fc\:30b9\:306e\:5f62\:5f0f: PDF \:306f DocImportPaper\:3001\:305d\:308c\:4ee5\:5916\:306f DocImportWebPage *)
iPNSourceFormat[file_String] := Switch[ToLowerCase[FileExtension[file]],
  "pdf", "pdf",
  "html" | "htm" | "xhtml" | "shtml", "html",
  "md" | "markdown", "markdown",
  "txt" | "text", "text",
  _, None];

(* ---- \:767b\:9332\:306f (\:30bd\:30fc\:30b9, TargetLanguage) \:3054\:3068 ----
   \:8a00\:8a9e\:540d\:306e\:6bd4\:8f03\:306f\:5927\:6587\:5b57\:5c0f\:6587\:5b57\:30fb\:4e2d\:56fd\:8a9e\:306e\:7c21\:4f53/\:7e41\:4f53\:3092\:533a\:5225\:3057\:306a\:3044\:3002TargetLanguage \:304c\:7a7a\:306e\:53e4\:3044\:767b\:9332\:306f\:3069\:306e\:8a00\:8a9e\:306b\:3082\:5408\:3046 *)
iPNLangKey[s_String] := With[{l = ToLowerCase[StringDelete[s, WhitespaceCharacter | "-" | "_"]]},
  If[StringContainsQ[l, "chinese" | "mandarin"], "chinese", l]];
iPNEntryLang[e_Association] := iPNStr[Lookup[e, "TargetLanguage", ""]];

(* PDFSourceId: \:8ad6\:6587\:30da\:30fc\:30b8\:306e\:767b\:9332\:3092\:3001\:305d\:306e\:30da\:30fc\:30b8\:306b\:7d50\:3070\:308c\:305f OA PDF \:306e\:30bd\:30fc\:30b9\:304b\:3089\:3082\:5f15\:3051\:308b\:3088\:3046\:306b\:3059\:308b *)
iPNSourceMatchQ[e_Association, ref_String, src_Association] :=
  With[{sid = iPNStr[Lookup[e, "SourceId", ""]], uri = iPNStr[Lookup[e, "URI", ""]], psid = iPNStr[Lookup[e, "PDFSourceId", ""]]},
    (sid =!= "" && (sid === ref || sid === src["SourceId"])) ||
    (uri =!= "" && (uri === ref || uri === src["URI"])) ||
    (psid =!= "" && (psid === ref || psid === src["SourceId"]))];

(* lang \:304c\:6587\:5b57\:5217\:306a\:3089\:305d\:306e\:8a00\:8a9e\:306e\:767b\:9332 (\:7121\:3051\:308c\:3070\:8a00\:8a9e\:306e\:7a7a\:306a\:53e4\:3044\:767b\:9332)\:3001Automatic \:306a\:3089 $Language \:3092\:512a\:5148\:3057\:3066\:7121\:3051\:308c\:3070\:5148\:982d *)
iPNPick[cands_List, lang_] := Module[{exact, wild},
  If[cands === {}, Return[Missing["NotRegistered"]]];
  If[StringQ[lang],
    exact = Select[cands, iPNEntryLang[#] =!= "" && iPNLangKey[iPNEntryLang[#]] === iPNLangKey[lang] &];
    wild = Select[cands, iPNEntryLang[#] === "" &];
    Return[Which[exact =!= {}, First[exact], wild =!= {}, First[wild], True, Missing["NotRegistered"]]]];
  With[{p = iPNPick[cands, $Language]}, If[AssociationQ[p], p, First[cands]]]];

iPNMatchEntry[entries_List, ref_String, src_Association] := iPNMatchEntry[entries, ref, src, Automatic];
iPNMatchEntry[entries_List, ref_String, src_Association, lang_] :=
  iPNPick[Select[entries, iPNSourceMatchQ[#, ref, src] &], lang];

iPNAbsolutePath[e_Association] := Module[{f = iPNStr[Lookup[e, "File", ""]]},
  Which[f === "", "",
    StringMatchQ[f, LetterCharacter ~~ ":" ~~ ___] || StringStartsQ[f, "/"] || StringStartsQ[f, "\\\\"], f,
    True, FileNameJoin[{SourceVaultPaperNotebookRoot[], f}]]];

iPNRelativeFile[path_String] := Module[{root = SourceVaultPaperNotebookRoot[], abs = AbsoluteFileName[path]},
  If[! StringQ[abs], abs = path];
  If[StringStartsQ[abs, root], StringTrim[StringDrop[abs, StringLength[root]], "\\" | "/"], abs]];

(* \:307e\:305a\:767b\:9332\:7c3f\:3092 ref \:305d\:306e\:3082\:306e (SourceId / URI) \:3067\:5f15\:304f\:3002\:305d\:308c\:3067\:898b\:3064\:304b\:3089\:306a\:3044\:3068\:304d\:3060\:3051\:53c2\:7167\:89e3\:6c7a\:3092\:901a\:3059
   (\:4e00\:89a7\:306e 1 \:884c\:3054\:3068\:306e\:547c\:3073\:51fa\:3057\:3092 O(\:5168\:30bd\:30fc\:30b9\:8d70\:67fb) \:306b\:3057\:306a\:3044\:30fb\:518d\:5e30\:3057\:306a\:3044) *)
Options[SourceVaultPaperNotebookEntry] = {"Language" -> Automatic};
SourceVaultPaperNotebookEntry[ref_String, OptionsPattern[]] := Module[
  {entries = iPNReadRegistry[], lang = OptionValue["Language"], cands, e, src},
  lang = If[StringQ[lang] && StringTrim[lang] =!= "", lang, Automatic];
  cands = Select[entries, Function[x,
    With[{sid = iPNStr[Lookup[x, "SourceId", ""]], uri = iPNStr[Lookup[x, "URI", ""]], psid = iPNStr[Lookup[x, "PDFSourceId", ""]]},
      (sid =!= "" && sid === ref) || (uri =!= "" && uri === ref) || (psid =!= "" && psid === ref)]]];
  e = iPNPick[cands, lang];
  If[! AssociationQ[e] && ! TrueQ[$iPNNoResolve],
    src = iPNResolveSource[ref];
    e = iPNMatchEntry[entries, ref, src, lang]];
  If[AssociationQ[e], Append[e, "Notebook" -> iPNAbsolutePath[e]], e]];

Options[SourceVaultPaperNotebook] = {"Language" -> Automatic};
SourceVaultPaperNotebook[ref_String, OptionsPattern[]] := Module[
  {e = SourceVaultPaperNotebookEntry[ref, "Language" -> OptionValue["Language"]]},
  If[! AssociationQ[e], Return[e]];
  If[StringQ[e["Notebook"]] && e["Notebook"] =!= "" && FileExistsQ[e["Notebook"]], e["Notebook"], Missing["NoFile", e["Notebook"]]]];

(* ---------------- \:4fdd\:5b58\:30d1\:30b9 ---------------- *)

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

SourceVaultPaperNotebookPath[ref_String, lang_String] :=
  With[{p = SourceVaultPaperNotebookPath[ref]},
    If[StringTrim[lang] === "", p, StringDrop[p, -3] <> "_" <> iPNSafeName[lang] <> ".nb"]];

iPNSameFileQ[a_String, b_String] := ToLowerCase[StringReplace[a, "\\" -> "/"]] === ToLowerCase[StringReplace[b, "\\" -> "/"]];

(* \:751f\:6210\:5148: \:4f5c\:308a\:76f4\:3057 (\:540c\:3058\:8a00\:8a9e\:306e\:767b\:9332\:304c\:3042\:308b) \:306a\:3089\:305d\:306e\:767b\:9332\:306e\:30d5\:30a1\:30a4\:30eb\:3002\:65b0\:898f\:306a\:3089\:65e2\:5b9a\:306e\:30d1\:30b9\:3001\:305f\:3060\:3057\:65e2\:5b9a\:306e\:30d1\:30b9\:3092
   \:5225\:306e\:8a00\:8a9e\:306e\:767b\:9332\:304c\:4f7f\:3063\:3066\:3044\:308c\:3070\:8a00\:8a9e\:540d\:4ed8\:304d\:306e\:30d1\:30b9 *)
iPNOutputPathFor[ref_String, lang_String, existing_] := Module[{plain = SourceVaultPaperNotebookPath[ref], owner},
  If[AssociationQ[existing] && StringQ[existing["Notebook"]] && existing["Notebook"] =!= "", Return[existing["Notebook"]]];
  owner = SelectFirst[iPNReadRegistry[], iPNSameFileQ[iPNAbsolutePath[#], plain] &, None];
  If[owner === None || iPNEntryLang[owner] === "" || iPNLangKey[iPNEntryLang[owner]] === iPNLangKey[lang],
    plain, SourceVaultPaperNotebookPath[ref, lang]]];

(* ---------------- \:767b\:9332 ---------------- *)

Options[SourceVaultRegisterPaperNotebook] = {"PrivacyLevel" -> Automatic, "Title" -> Automatic,
  "TargetLanguage" -> Automatic, "SourceLanguage" -> Automatic, "Translated" -> Automatic, "Format" -> Automatic,
  "PDFSourceId" -> Automatic, "Declare" -> True, "Status" -> "OK", "FailedPages" -> {}, "Pages" -> Automatic};
SourceVaultRegisterPaperNotebook[ref_String, nbPath_String, OptionsPattern[]] := Module[
  {src = iPNResolveSource[ref], entries, prior, pa, pl, e, declared = "Skipped", abs,
   lang = OptionValue["TargetLanguage"]},
  lang = If[StringQ[lang] && StringTrim[lang] =!= "", lang, Automatic];
  abs = With[{a = AbsoluteFileName[nbPath]}, If[StringQ[a], a, nbPath]];
  If[! FileExistsQ[abs],
    Return[Failure["NoFile", <|"MessageTemplate" -> "notebook `1` does not exist", "MessageParameters" -> {nbPath}|>]]];
  pl = OptionValue["PrivacyLevel"];
  If[! NumericQ[pl], pl = src["PrivacyLevel"]];
  pl = Clip[N[pl], {0., 1.}];
  entries = iPNReadRegistry[];
  (* \:8a33\:5148\:306e\:8a00\:8a9e\:3092\:6307\:5b9a\:3057\:305f\:3089\:305d\:306e\:8a00\:8a9e\:306e\:767b\:9332\:3060\:3051\:3092\:4e0a\:66f8\:304d\:3059\:308b (\:5225\:306e\:8a00\:8a9e\:306e\:8a33\:306f\:6b8b\:3059) *)
  prior = iPNMatchEntry[entries, ref, src, lang];
  (* \:672a\:767b\:9332\:306a\:3089 prior \:306f Missing: Lookup \:3092\:901a\:3059\:3068\:672a\:8a55\:4fa1\:5f0f\:304c\:6b8b\:308a JSON \:306b\:66f8\:3051\:306a\:304f\:306a\:308b *)
  pa = If[AssociationQ[prior], prior, <||>];
  e = <|"SourceId" -> If[src["SourceId"] =!= "", src["SourceId"], iPNStr[Lookup[pa, "SourceId", ref]]],
    "URI" -> If[src["URI"] =!= "", src["URI"], iPNStr[Lookup[pa, "URI", ""]]],
    "File" -> iPNRelativeFile[abs],
    "Title" -> With[{t = OptionValue["Title"]}, If[StringQ[t] && t =!= "", t,
      If[src["Title"] =!= "", src["Title"], iPNStr[Lookup[pa, "Title", FileBaseName[abs]]]]]],
    "PrivacyLevel" -> pl, "CloudPublishable" -> (pl < 0.5),
    "TargetLanguage" -> If[StringQ[lang], lang, With[{l = iPNStr[Lookup[pa, "TargetLanguage", ""]]}, If[l === "", $Language, l]]],
    "SourceLanguage" -> With[{s = OptionValue["SourceLanguage"]}, If[StringQ[s], s, iPNStr[Lookup[pa, "SourceLanguage", ""]]]],
    "Translated" -> With[{t = OptionValue["Translated"]}, If[BooleanQ[t], t, Lookup[pa, "Translated", Null]]],
    "Format" -> With[{f = OptionValue["Format"]}, Which[StringQ[f], f,
      src["File"] =!= "", Replace[iPNSourceFormat[src["File"]], None -> ""], True, iPNStr[Lookup[pa, "Format", ""]]]],
    (* \:8ad6\:6587\:30da\:30fc\:30b8\:3092 OA PDF \:304b\:3089\:4f5c\:3063\:305f\:3068\:304d\:306e PDF \:306e\:30bd\:30fc\:30b9 (\:7121\:3051\:308c\:3070\:7a7a) *)
    "PDFSourceId" -> With[{p = OptionValue["PDFSourceId"]}, If[StringQ[p], p, iPNStr[Lookup[pa, "PDFSourceId", ""]]]],
    "Status" -> iPNStr[OptionValue["Status"]], "FailedPages" -> OptionValue["FailedPages"],
    "Pages" -> Replace[OptionValue["Pages"], Automatic -> Lookup[pa, "Pages", Null]],
    "CreatedAtUTC" -> iPNStr[Lookup[pa, "CreatedAtUTC", iPNUTCNow[]]], "UpdatedAtUTC" -> iPNUTCNow[]|>;
  If[e["CreatedAtUTC"] === "", e["CreatedAtUTC"] = iPNUTCNow[]];
  (* PL \:306e\:7d99\:627f\:3092\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:81ea\:8eab\:306b\:3082\:5ba3\:8a00\:3059\:308b (NBAccess \:304c\:3042\:308b\:3068\:304d\:3060\:3051) *)
  If[TrueQ[OptionValue["Declare"]] && Length[DownValues[NBAccess`NBSetCloudPublishable]] > 0,
    declared = With[{r = Quiet @ Check[NBAccess`NBSetCloudPublishable[abs, pl < 0.5], $Failed]},
      If[AssociationQ[r], iPNStr[Lookup[r, "Status", "?"]], "Failed"]]];
  entries = If[AssociationQ[prior], Replace[entries, x_ /; x === prior :> e, {1}], Append[entries, e]];
  If[! StringQ[iPNWriteRegistry[entries]],
    Return[Failure["SaveFailed", <|"MessageTemplate" -> "could not write the notebook registry"|>]]];
  Join[e, <|"Notebook" -> abs, "Declared" -> declared|>]];

Options[SourceVaultUnregisterPaperNotebook] = {"Language" -> Automatic};
SourceVaultUnregisterPaperNotebook[ref_String, OptionsPattern[]] := Module[
  {src = iPNResolveSource[ref], entries, drop, lang = OptionValue["Language"]},
  entries = iPNReadRegistry[];
  drop = If[lang === All, Select[entries, iPNSourceMatchQ[#, ref, src] &],
    With[{p = iPNMatchEntry[entries, ref, src, If[StringQ[lang], lang, Automatic]]}, If[AssociationQ[p], {p}, {}]]];
  If[drop === {}, Return[False]];
  StringQ[iPNWriteRegistry[Select[entries, ! MemberQ[drop, #] &]]]];

SourceVaultPaperNotebooks[] := Map[Append[#, "Notebook" -> iPNAbsolutePath[#]] &, iPNReadRegistry[]];

SourceVaultPaperNotebooksView[] := Dataset[Map[
  <|"SourceId" -> iPNStr[#["SourceId"]], "Title" -> iPNStr[Lookup[#, "Title", ""]],
    "PL" -> Lookup[#, "PrivacyLevel", 1.0], "Public" -> TrueQ[Lookup[#, "CloudPublishable", False]],
    "Language" -> iPNStr[Lookup[#, "TargetLanguage", ""]], "From" -> iPNStr[Lookup[#, "SourceLanguage", ""]],
    "Translated" -> Lookup[#, "Translated", Null], "Format" -> iPNStr[Lookup[#, "Format", ""]],
    "Status" -> iPNStr[Lookup[#, "Status", ""]],
    "Exists" -> FileExistsQ[iPNStr[#["Notebook"]]], "Updated" -> iPNStr[Lookup[#, "UpdatedAtUTC", ""]],
    "Notebook" -> iPNStr[#["Notebook"]]|> &, SourceVaultPaperNotebooks[]]];

(* ---------------- \:751f\:6210 (DocImportPaper \:7d4c\:7531\:3001PL \:7d99\:627f) ---------------- *)

iPNDocImportQ["pdf"] := Length[DownValues[Documentation`DocImportPaper]] > 0;
iPNDocImportQ[_] := Length[DownValues[Documentation`DocImportWebPage]] > 0;

(* PL \:3067 LLM \:7d4c\:8def\:3092\:6c7a\:3081\:308b: PL >= 0.5 \:306f $ClaudePrivateModel \:3060\:3051 (\:7121\:3051\:308c\:3070 fail-closed)\:3002
   PL < 0.5 \:306f\:65e2\:5b9a (Claude Code CLI / \:30d1\:30ec\:30c3\:30c8\:306e\:30e2\:30c7\:30eb)\:3002DocImportPaper \:81ea\:8eab\:306f PL \:3092\:898b\:306a\:3044 *)
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

(* \:30da\:30fc\:30b8\:306e\:30bd\:30fc\:30b9\:306b\:7d50\:3070\:308c\:305f\:30aa\:30fc\:30d7\:30f3\:30a2\:30af\:30bb\:30b9 PDF (SourceVault_oapdf.wl)\:3002\:7d50\:3070\:308c\:3066\:3044\:306a\:3051\:308c\:3070\:63a2\:3057\:3066\:53d6\:308a\:8fbc\:3080
   (\:78ba\:8a8d\:6e08\:307f\:3067\:898b\:3064\:304b\:3089\:306a\:304b\:3063\:305f\:3082\:306e\:306f $SourceVaultOARecheckDays \:65e5\:306f\:7e70\:308a\:8fd4\:3055\:306a\:3044)\:3002PDF \:304c\:7121\:3051\:308c\:3070 None *)
iPNOpenAccessPDF[src_Association] := Module[{sid = src["SourceId"], r},
  If[sid === "" || Length[DownValues[SourceVault`SourceVaultOpenAccessPDFSource]] === 0, Return[None]];
  r = Quiet @ Check[SourceVault`SourceVaultOpenAccessPDFSource[sid], $Failed];
  If[! AssociationQ[r] && Length[DownValues[SourceVault`SourceVaultIngestOpenAccessPDF]] > 0,
    Quiet @ Check[SourceVault`SourceVaultIngestOpenAccessPDF[sid], Null];
    r = Quiet @ Check[SourceVault`SourceVaultOpenAccessPDFSource[sid], $Failed]];
  If[AssociationQ[r] && StringQ[r["File"]] && r["File"] =!= "" && FileExistsQ[r["File"]] && iPNSourceFormat[r["File"]] === "pdf",
    r, None]];

$iPNOwnOptions = {"Force" -> False, "Open" -> Automatic, "Interactive" -> False, "Verbose" -> True, "PreferPDF" -> Automatic};
SourceVaultMakePaperNotebook[ref_String, opts___Rule] := Module[
  {own = Association[$iPNOwnOptions], all = Association[{opts}], src, lang, existingE, existing, fmt, path,
   pl, model, fallback, docOpts, common, res, la, entry, fe, pdfSrc = None, srcFile},
  own = Join[own, KeyTake[all, Keys[own]]];
  fe = $FrontEnd =!= Null && TrueQ[$Notebooks];
  (* \:30d1\:30ec\:30c3\:30c8 / \:4e00\:89a7\:30dc\:30bf\:30f3\:304b\:3089: \:73fe\:5728\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306b\:8a55\:4fa1\:30bb\:30eb\:3092\:66f8\:3044\:3066\:5b9f\:884c (\:9032\:6357\:304c\:898b\:3048\:308b\:30fb\:3084\:308a\:76f4\:305b\:308b) *)
  If[TrueQ[own["Interactive"]] && fe,
    Return[iPNInsertAndEvaluate["SourceVaultMakePaperNotebook[\"" <> ref <> "\"]"]]];
  src = iPNResolveSource[ref];
  (* \:8a33\:5148\:306f $Language (\:591a\:8a00\:8a9e: \:5229\:7528\:8005\:3054\:3068\:306e\:8a00\:8a9e\:3067\:4f5c\:308b)\:3002\:305d\:306e\:8a00\:8a9e\:306e\:767b\:9332\:3060\:3051\:3092\:300c\:4f5c\:6210\:6e08\:307f\:300d\:3068\:307f\:306a\:3059 *)
  lang = With[{l = Lookup[all, "TargetLanguage", Automatic]}, If[StringQ[l] && StringTrim[l] =!= "", l, $Language]];
  existingE = SourceVaultPaperNotebookEntry[ref, "Language" -> lang];
  existing = If[AssociationQ[existingE] && StringQ[existingE["Notebook"]] && existingE["Notebook"] =!= "" &&
    FileExistsQ[existingE["Notebook"]], existingE["Notebook"], Missing["NotRegistered"]];
  If[StringQ[existing] && ! TrueQ[own["Force"]],
    If[fe && own["Open"] =!= False, iPNOpenNotebookFront[existing]];
    Return[Append[existingE, "Status" -> "Existing"]]];
  If[src["Status"] =!= "OK" || src["File"] === "" || ! FileExistsQ[src["File"]],
    Return[Failure["SourceNotFound", <|"MessageTemplate" ->
      "`1` is not an ingested source with a local file (SourceVaultResolveReference)", "MessageParameters" -> {ref}|>]]];
  fmt = iPNSourceFormat[src["File"]];
  If[fmt === None,
    Return[Failure["UnsupportedFormat", <|"MessageTemplate" ->
      "`1` is not a PDF, HTML, text or Markdown file", "MessageParameters" -> {src["File"]}|>]]];
  srcFile = src["File"];
  pl = src["PrivacyLevel"];
  (* \:8ad6\:6587\:30da\:30fc\:30b8 (web \:306e HTML) \:306b\:30aa\:30fc\:30d7\:30f3\:30a2\:30af\:30bb\:30b9\:306e PDF \:304c\:3042\:308c\:3070 PDF \:304b\:3089\:4f5c\:308b: \:6570\:5f0f\:30fb\:56f3\:8868\:30fb\:6bb5\:7d44\:307f\:304c\:5d29\:308c\:306a\:3044 *)
  If[fmt === "html" && own["PreferPDF"] =!= False, pdfSrc = iPNOpenAccessPDF[src]];
  If[AssociationQ[pdfSrc],
    (* PDF \:306e\:30bd\:30fc\:30b9\:304b\:3089\:4f5c\:3063\:305f\:540c\:3058\:8a00\:8a9e\:306e\:7ffb\:8a33\:30ce\:30fc\:30c8\:304c\:3042\:308c\:3070\:305d\:308c\:3092\:4f7f\:3046 *)
    With[{pe = SourceVaultPaperNotebookEntry[pdfSrc["SourceId"], "Language" -> lang]},
      If[! TrueQ[own["Force"]] && AssociationQ[pe] && StringQ[pe["Notebook"]] && FileExistsQ[pe["Notebook"]],
        If[fe && own["Open"] =!= False, iPNOpenNotebookFront[pe["Notebook"]]];
        Return[Append[pe, "Status" -> "Existing"]]]];
    fmt = "pdf"; srcFile = pdfSrc["File"]; pl = Max[pl, pdfSrc["PrivacyLevel"]]];
  If[! iPNDocImportQ[fmt],
    Return[Failure["DocumentationNotLoaded", <|"MessageTemplate" ->
      "documentation.wl (`1`) is not loaded", "MessageParameters" -> {If[fmt === "pdf", "DocImportPaper", "DocImportWebPage"]}|>]]];
  model = iPNRouteModel[pl, Lookup[all, ClaudeCode`Model, Automatic]];
  If[model === $Failed,
    Return[Failure["PrivateModelUnavailable", <|"MessageTemplate" ->
      "PrivacyLevel `1` requires $ClaudePrivateModel (local model); none is configured", "MessageParameters" -> {pl}|>]]];
  fallback = If[pl < 0.5,
    Lookup[all, ClaudeCode`Fallback,
      If[Length[DownValues[ClaudeCode`GetPaletteFallback]] > 0, TrueQ[Quiet @ Check[ClaudeCode`GetPaletteFallback[], False]], False]],
    False];
  path = iPNOutputPathFor[ref, lang, existingE];
  docOpts = Normal[KeyDrop[all, Join[Keys[own], {ClaudeCode`Model, ClaudeCode`Fallback,
    "OutputPath", "Open", "Save", "CloudPublishable", "TargetLanguage"}]]];
  If[TrueQ[own["Verbose"]],
    Print["SourceVault: ", src["Title"], " (PL ", pl, ", ", If[pl < 0.5, "cloud", "local"], ", ", fmt,
      If[AssociationQ[pdfSrc], " = OA PDF " <> pdfSrc["SourceId"] <> " via " <> pdfSrc["Via"], ""], " -> ", lang, ") -> ", path]];
  common = {"OutputPath" -> path, "Open" -> False, "Save" -> True, "CloudPublishable" -> (pl < 0.5),
    "TargetLanguage" -> lang, ClaudeCode`Model -> model, ClaudeCode`Fallback -> fallback, "Verbose" -> own["Verbose"]};
  (* \:76f4\:524d\:306e\:5225\:306e\:5909\:63db\:306e\:89e3\:6790\:7d50\:679c\:3092\:767b\:9332\:306b\:6df7\:305c\:306a\:3044 *)
  If[ValueQ[Documentation`$DocPaperLastAnalysis], Documentation`$DocPaperLastAnalysis = <||>];
  res = If[fmt === "pdf",
    Documentation`DocImportPaper[srcFile, Sequence @@ docOpts, Sequence @@ common],
    Documentation`DocImportWebPage[srcFile, Sequence @@ docOpts, "BaseURL" -> src["URL"], "Title" -> src["Title"],
      Sequence @@ common]];
  If[res === $Failed || ! FileExistsQ[path],
    Return[Failure["ImportFailed", <|"MessageTemplate" -> "`1` did not produce `2`",
      "MessageParameters" -> {If[fmt === "pdf", "DocImportPaper", "DocImportWebPage"], path}|>]]];
  la = Replace[$DocPaperLastAnalysisSafe[], Except[_Association] -> <||>];
  entry = SourceVaultRegisterPaperNotebook[ref, path, "PrivacyLevel" -> pl,
    "Title" -> src["Title"], "TargetLanguage" -> lang, "Format" -> fmt,
    "PDFSourceId" -> If[AssociationQ[pdfSrc], pdfSrc["SourceId"], Automatic],
    "SourceLanguage" -> iPNStr[Lookup[la, "SourceLanguage", ""]],
    "Translated" -> Lookup[la, "Translated", Automatic],
    "FailedPages" -> Lookup[la, "FailedPages", {}]];
  If[fe && own["Open"] =!= False, iPNOpenNotebookFront[path]];
  entry];

$DocPaperLastAnalysisSafe[] := If[ValueQ[Documentation`$DocPaperLastAnalysis] && AssociationQ[Documentation`$DocPaperLastAnalysis],
  Documentation`$DocPaperLastAnalysis, <||>];

(* \:65e2\:306b\:958b\:3044\:3066\:3044\:308b\:30ce\:30fc\:30c8\:306f NotebookOpen \:3057\:3066\:3082\:524d\:9762\:306b\:6765\:306a\:3044\:3053\:3068\:304c\:3042\:308b (\:4e00\:89a7\:306e\:30dc\:30bf\:30f3\:304b\:3089\:62bc\:3059\:3068
   \:300c\:53cd\:5fdc\:306f\:3059\:308b\:304c\:958b\:304b\:306a\:3044\:300d\:306b\:898b\:3048\:308b)\:3002\:958b\:3044\:3066\:3044\:308b\:7a93\:3092\:63a2\:3057\:3066\:524d\:9762\:3078\:3001\:7121\:3051\:308c\:3070\:958b\:3044\:3066\:524d\:9762\:3078 *)
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

SourceVaultOpenPaperNotebook[ref_String] := Module[{p = SourceVaultPaperNotebook[ref, "Language" -> $Language]},
  If[StringQ[p],
    If[$FrontEnd =!= Null && TrueQ[$Notebooks], iPNOpenNotebookFront[p], p],
    SourceVaultMakePaperNotebook[ref, "Interactive" -> True]]];

(* ---------------- \:8a08\:7b97\:30ce\:30fc\:30c8 (v1.47): \:7d20\:6750\:304b\:3089\:4f5c\:3063\:305f Mathematica \:306e\:8a08\:7b97\:3068\:7d50\:679c\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af ----------------
   1 \:672c\:306e\:8ad6\:6587\:306b\:4ed8\:968f\:3059\:308b\:306e\:3067\:306f\:306a\:304f\:3001\:8907\:6570\:306e\:7d20\:6750 (\:8ad6\:6587\:30fbSourceVault \:306e\:6587\:66f8\:30fbKG \:306e\:30ce\:30fc\:30c9\:30fb\:904e\:53bb\:306e\:30b9\:30e9\:30a4\:30c9) \:304b\:3089\:4f5c\:3063\:3066 SourceVault \:304c
   \:7ba1\:7406\:3059\:308b\:3002Id = cnb-<8 \:6841>\:3001URI = sv://computenb/<Id>\:3002\:30bb\:30eb\:306e\:5358\:4f4d (CellTags "CNU:<unit>") \:306f KG \:306e\:30ce\:30fc\:30c9\:306b\:306a\:308a\:3001\:30bb\:30eb\:306e\:4e26\:3073\:306f
   1 \:3064\:306e\:30b9\:30c8\:30fc\:30ea\:30fc\:3068\:3057\:3066 KG (GraphId = Id\:3001Kind Notebook) \:306b\:5165\:308b (SlideWorkflow \:306e SlideComputeGraph)\:3002
   \:4fdd\:5b58: <SourceVaultCoreRoot>/computenb/registry.json \:3068 <\:984c\:540d>_<Id>.nb (File \:306f root \:5185\:306a\:3089\:76f8\:5bfe\:30d1\:30b9) *)
If[! ValueQ[SourceVault`$SourceVaultComputeNBRoot], SourceVault`$SourceVaultComputeNBRoot = Automatic];

iCNResolveRoot[] := Module[{override = SourceVault`$SourceVaultComputeNBRoot, core},
  If[StringQ[override] && StringLength[override] > 0, Return[override]];
  core = If[Length[DownValues[SourceVault`SourceVaultCoreRoot]] > 0,
    Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed], $Failed];
  If[StringQ[core] && StringLength[core] > 0, FileNameJoin[{core, "computenb"}],
    FileNameJoin[{DirectoryName[iPNLocalFallbackRoot[]], "computenb"}]]];
SourceVaultComputeNotebookRoot[] := iPNEnsureDirectory[iCNResolveRoot[]];
iCNRegistryFile[] := FileNameJoin[{SourceVaultComputeNotebookRoot[], "registry.json"}];

$iCNRegistryCache = None;
iCNReadRegistry[] := Module[{f = iCNRegistryFile[], stamp, raw},
  stamp = {f, If[FileExistsQ[f], Quiet @ Check[FileDate[f, "Modification"], None], None]};
  If[ListQ[$iCNRegistryCache] && $iCNRegistryCache[[1]] === stamp, Return[$iCNRegistryCache[[2]]]];
  raw = iPNReadJSON[f];
  raw = If[AssociationQ[raw], Select[Lookup[raw, "Entries", {}], AssociationQ], {}];
  $iCNRegistryCache = {stamp, raw};
  raw];
iCNWriteRegistry[entries_List] := ($iCNRegistryCache = None;
  iPNWriteJSON[iCNRegistryFile[], <|"Version" -> 1, "UpdatedAtUTC" -> iPNUTCNow[], "Entries" -> entries|>]);

$iCNURIPrefix = "sv://computenb/";
iCNIdOf[ref_String] := If[StringStartsQ[ref, $iCNURIPrefix], StringDrop[ref, StringLength[$iCNURIPrefix]], ref];
iCNAbsolutePath[e_Association] := Module[{f = iPNStr[Lookup[e, "File", ""]]},
  Which[f === "", "",
    StringMatchQ[f, LetterCharacter ~~ ":" ~~ ___] || StringStartsQ[f, "/"] || StringStartsQ[f, "\\\\"], f,
    True, FileNameJoin[{SourceVaultComputeNotebookRoot[], f}]]];
iCNRelativeFile[path_String] := Module[{root = SourceVaultComputeNotebookRoot[], abs = AbsoluteFileName[path]},
  If[! StringQ[abs], abs = path];
  If[StringStartsQ[abs, root], StringTrim[StringDrop[abs, StringLength[root]], "\\" | "/"], abs]];
iCNAbs[p_String] := With[{a = Quiet @ AbsoluteFileName[p]}, If[StringQ[a], a, p]];
iCNMatch[entries_List, ref_String] := Module[{id = iCNIdOf[ref], abs = None},
  If[StringEndsQ[ref, ".nb", IgnoreCase -> True], abs = iCNAbs[ref]];
  SelectFirst[entries, iPNStr[Lookup[#, "Id", ""]] === id || (StringQ[abs] && iCNAbs[iCNAbsolutePath[#]] === abs) &,
    Missing["NotRegistered"]]];

SourceVaultComputeNotebookEntry[ref_String] := With[{e = iCNMatch[iCNReadRegistry[], ref]},
  If[AssociationQ[e], Append[e, "Notebook" -> iCNAbsolutePath[e]], e]];
SourceVaultComputeNotebook[ref_String] := Module[{e = SourceVaultComputeNotebookEntry[ref]},
  If[! AssociationQ[e], Return[e]];
  If[StringQ[e["Notebook"]] && e["Notebook"] =!= "" && FileExistsQ[e["Notebook"]], e["Notebook"], Missing["NoFile", e["Notebook"]]]];
SourceVaultComputeNotebookPath[title_String, id_String] := FileNameJoin[{SourceVaultComputeNotebookRoot[],
  If[StringTrim[title] === "", id, iPNSafeName[title] <> "_" <> id] <> ".nb"}];

iCNNewId[seed_String] := Module[{entries = iCNReadRegistry[], id, k = 0},
  id = "cnb-" <> StringTake[IntegerString[Hash[seed <> iPNUTCNow[], "SHA256"], 16, 64], 8];
  While[AnyTrue[entries, iPNStr[Lookup[#, "Id", ""]] === id &] && k < 20,
    k++; id = "cnb-" <> StringTake[IntegerString[Hash[seed <> iPNUTCNow[] <> ToString[k], "SHA256"], 16, 64], 8]];
  id];

(* \:7d20\:6750\:306e PL: sv:// / src- / Eagle \:306f\:89e3\:6c7a\:3057\:305f PL (\:89e3\:3051\:306a\:3051\:308c\:3070 1.0 = fail-closed)\:3001\:8a08\:7b97\:30ce\:30fc\:30c8\:306f\:305d\:306e\:767b\:9332\:306e PL\:3001
   \:305d\:308c\:4ee5\:5916 (URL\:30fbarXiv\:30fb\:30ed\:30fc\:30ab\:30eb\:30d5\:30a1\:30a4\:30eb\:30fbKG \:30ce\:30fc\:30c9) \:306f 0 *)
iCNSourcePL[ref_String] := Which[
  StringStartsQ[ref, $iCNURIPrefix] || StringMatchQ[ref, "cnb-" ~~ WordCharacter ..],
    With[{e = SourceVaultComputeNotebookEntry[ref]}, If[AssociationQ[e] && NumericQ[Lookup[e, "PrivacyLevel", None]], N[e["PrivacyLevel"]], 1.]],
  StringStartsQ[ref, "sv://"] || StringStartsQ[ref, "src-"] || iPNEagleRefQ[ref], iPNResolveSource[ref]["PrivacyLevel"],
  True, 0.];
iCNSourceRows[s_] := Select[Map[Which[
    StringQ[#], <|"Key" -> "", "Ref" -> #|>,
    AssociationQ[#], <|"Key" -> iPNStr[Lookup[#, "Key", ""]], "Ref" -> iPNStr[Lookup[#, "Ref", Lookup[#, "Locator", ""]]]|>,
    True, Nothing] &, Replace[s, Except[_List] -> {}]], #["Ref"] =!= "" &];

Options[SourceVaultRegisterComputeNotebook] = {"Id" -> Automatic, "Title" -> Automatic, "Sources" -> Automatic, "PrivacyLevel" -> Automatic,
  "Language" -> Automatic, "Units" -> Automatic, "Graph" -> Automatic, "Status" -> "OK", "Declare" -> True, "Copy" -> False};
SourceVaultRegisterComputeNotebook[nbPath_String, OptionsPattern[]] := Module[
  {abs = iCNAbs[nbPath], entries, prior, pa, id, title, srcs, pl, e, declared = "Skipped", dest},
  If[! FileExistsQ[abs],
    Return[Failure["NoFile", <|"MessageTemplate" -> "notebook `1` does not exist", "MessageParameters" -> {nbPath}|>]]];
  entries = iCNReadRegistry[];
  prior = With[{i = OptionValue["Id"]}, If[StringQ[i], iCNMatch[entries, i], iCNMatch[entries, abs]]];
  pa = If[AssociationQ[prior], prior, <||>];
  id = Which[StringQ[OptionValue["Id"]], iCNIdOf[OptionValue["Id"]], StringQ[Lookup[pa, "Id", None]], pa["Id"], True, iCNNewId[abs]];
  title = With[{tt = OptionValue["Title"]}, If[StringQ[tt] && StringTrim[tt] =!= "", tt, iPNStr[Lookup[pa, "Title", FileBaseName[abs]]]]];
  If[TrueQ[OptionValue["Copy"]] && ! StringStartsQ[abs, SourceVaultComputeNotebookRoot[]],
    dest = SourceVaultComputeNotebookPath[title, id];
    If[StringQ[Quiet @ Check[CopyFile[abs, dest, OverwriteTarget -> True], $Failed]], abs = dest]];
  srcs = iCNSourceRows[Replace[OptionValue["Sources"], Automatic :> Lookup[pa, "Sources", {}]]];
  pl = OptionValue["PrivacyLevel"];
  If[! NumericQ[pl], pl = Max[Prepend[iCNSourcePL /@ Lookup[srcs, "Ref", {}], 0.]]];
  pl = Clip[N[pl], {0., 1.}];
  e = <|"Id" -> id, "URI" -> $iCNURIPrefix <> id, "File" -> iCNRelativeFile[abs], "Title" -> title,
    "Sources" -> srcs, "PrivacyLevel" -> pl, "CloudPublishable" -> (pl < 0.5),
    "Language" -> With[{l = OptionValue["Language"]}, If[StringQ[l], l, iPNStr[Lookup[pa, "Language", $Language]]]],
    "Units" -> Replace[OptionValue["Units"], Automatic :> Lookup[pa, "Units", Null]],
    "Graph" -> Replace[OptionValue["Graph"], Automatic :> iPNStr[Lookup[pa, "Graph", id]]],
    "Status" -> iPNStr[OptionValue["Status"]],
    "CreatedAtUTC" -> With[{c = iPNStr[Lookup[pa, "CreatedAtUTC", ""]]}, If[c === "", iPNUTCNow[], c]], "UpdatedAtUTC" -> iPNUTCNow[]|>;
  If[TrueQ[OptionValue["Declare"]] && Length[DownValues[NBAccess`NBSetCloudPublishable]] > 0,
    declared = With[{r = Quiet @ Check[NBAccess`NBSetCloudPublishable[abs, pl < 0.5], $Failed]},
      If[AssociationQ[r], iPNStr[Lookup[r, "Status", "?"]], "Failed"]]];
  entries = If[AssociationQ[prior], Replace[entries, x_ /; x === prior :> e, {1}], Append[entries, e]];
  If[! StringQ[iCNWriteRegistry[entries]],
    Return[Failure["SaveFailed", <|"MessageTemplate" -> "could not write the compute notebook registry"|>]]];
  Join[e, <|"Notebook" -> abs, "Declared" -> declared|>]];

SourceVaultUnregisterComputeNotebook[ref_String] := Module[{entries = iCNReadRegistry[], prior},
  prior = iCNMatch[entries, ref];
  If[! AssociationQ[prior], Return[False]];
  StringQ[iCNWriteRegistry[DeleteCases[entries, prior]]]];

SourceVaultComputeNotebooks[] := Map[Append[#, "Notebook" -> iCNAbsolutePath[#]] &, iCNReadRegistry[]];
SourceVaultComputeNotebooksView[] := Dataset[Map[
  <|"Id" -> iPNStr[#["Id"]], "Title" -> iPNStr[Lookup[#, "Title", ""]], "Units" -> Lookup[#, "Units", Null],
    "Sources" -> StringRiffle[Lookup[Replace[Lookup[#, "Sources", {}], Except[_List] -> {}], "Ref", {}], ", "],
    "PL" -> Lookup[#, "PrivacyLevel", 1.0], "Public" -> TrueQ[Lookup[#, "CloudPublishable", False]],
    "Status" -> iPNStr[Lookup[#, "Status", ""]], "Exists" -> FileExistsQ[iPNStr[#["Notebook"]]],
    "Updated" -> iPNStr[Lookup[#, "UpdatedAtUTC", ""]], "Notebook" -> iPNStr[#["Notebook"]]|> &, SourceVaultComputeNotebooks[]]];

End[]

EndPackage[]

(*Print[Style["SourceVault_papernb.wl \:304c\:30ed\:30fc\:30c9\:3055\:308c\:307e\:3057\:305f\:3002", Bold]];
Print["
  SourceVaultMakePaperNotebook[\"src-...\"]      \[RightArrow] \:53d6\:308a\:8fbc\:307f\:6e08\:307f\:8ad6\:6587\:306e\:7ffb\:8a33\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:751f\:6210\:30fb\:767b\:9332 (PL \:7d99\:627f)
  SourceVaultPaperNotebook[ref]                  \[RightArrow] \:767b\:9332\:6e08\:307f\:7ffb\:8a33\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:30d1\:30b9 (SlideWorkflow \:306e\:6587\:732e\:89e3\:6c7a\:304c\:4f7f\:3046)
  SourceVaultRegisterPaperNotebook[ref, nb]     \[RightArrow] \:65e2\:5b58\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:767b\:9332 (CloudPublishable \:5ba3\:8a00\:3064\:304d)
  SourceVaultPaperNotebooks[] / ...View[]        \[RightArrow] \:4e00\:89a7
"];*)