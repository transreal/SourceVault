(* ::Package:: *)

(* ============================================================
   SourceVault_slidedeck.wl -- 発表 (スライドデッキ + 発表シナリオ) 登録簿

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_slidedeck.wl"]]

   仕様書: SlideWorkflow_info/design/slide_presentation_scenario_spec_v0_1.md

   位置づけ:
     「計算と自然集会31 のプレゼンを開始」のような発表タイトルから、
     Sliden 用 mp4 の URL と発表シナリオ (原稿) を引くための登録簿。
     中身 (スライド / 原稿) を作るのは SlideWorkflow.wl の管轄で、
     本層はその所在と公開可否だけを持つ。原稿本文はここでは生成も編集もしない。

   service-loadable 制約 (spec v6 3.4):
     FrontEnd / Notebook / NBAccess / UI 依存を持たない。他の SourceVault
     モジュールにも依存しない (root 解決だけ core を DownValues guard 付きで見る)。
     単体 Get だけでも動く ($SourceVaultSlideDeckRoot を与えればテスト可能)。

   privacy:
     エントリは登録時に PrivacyLevel を明示する (既定 0.0 = 公開発表資料)。
     読み出し側は欠落を 1.0 とみなす fail-closed。PrivacyLevel >= 0.5 の
     エントリは原稿本文を返さない (TalkWithheld -> True)。DeckFile は
     ローカル絶対パスなので発表 payload には載せない。
   ============================================================ *)

BeginPackage["SourceVault`"]

$SourceVaultSlideDeckRoot::usage =
  "$SourceVaultSlideDeckRoot は発表登録簿の保存 root の override。\n" <>
  "String を設定するとそのディレクトリを使う (テスト用)。既定 Automatic では\n" <>
  "SourceVaultCoreRoot[]/slidedecks、解決できなければ LOCALAPPDATA 配下。";

$SourceVaultSlideDeckReleaseCeiling::usage =
  "$SourceVaultSlideDeckReleaseCeiling は発表原稿を外部 (MCP / 音声ブリッジ) へ\n" <>
  "渡してよい privacy level の上限 (既定 0.5、これ以上は withheld)。";

SourceVaultSlideDeckRoot::usage =
  "SourceVaultSlideDeckRoot[] は発表登録簿ディレクトリの絶対パスを返す (無ければ作る)。";

SourceVaultSlideDeckRegister::usage =
  "SourceVaultSlideDeckRegister[entry] / SourceVaultSlideDeckRegister[entry, talk] は\n" <>
  "発表を登録簿へ upsert する。entry は Title (必須)・SlideURL (必須)・Aliases・\n" <>
  "Id・DeckFile・SecondsPerSlide・StartSlide・EndSlide・NarrationInstructions・\n" <>
  "Event・Author・Date・PrivacyLevel (既定 0.0)・TalkMarkdown を持つ Association。\n" <>
  "talk はコンパイル済みシナリオ (<|Opening, Closing, Slides|>) で、与えると\n" <>
  "talks/<id>.json へ、TalkMarkdown があれば talks/<id>.md へ保存する。";

SourceVaultSlideDeckUnregister::usage =
  "SourceVaultSlideDeckUnregister[idOrTitle] は登録を削除する。";

SourceVaultSlideDeckRegistry::usage =
  "SourceVaultSlideDeckRegistry[] は登録済み発表エントリのリストを返す。";

SourceVaultSlideDeckLookup::usage =
  "SourceVaultSlideDeckLookup[query] は発表タイトル (別名・表記ゆれ可) から\n" <>
  "エントリ 1 件を返す。見つからなければ Missing[\"NotFound\", query]。\n" <>
  "末尾の番号が食い違う候補 (31 と 30) は決して一致しない。";

SourceVaultSlideDeckMatchScore::usage =
  "SourceVaultSlideDeckMatchScore[query, candidate] は 0.0-1.0 の照合スコア。";

SourceVaultSlideDeckTalk::usage =
  "SourceVaultSlideDeckTalk[idOrTitle] はコンパイル済み発表シナリオ\n" <>
  "<|\"Opening\"->, \"Closing\"->, \"Slides\"->{<|\"Slide\",\"Seconds\",\"Text\"|>..}|> を返す。";

SourceVaultSlideDeckPresentationSpec::usage =
  "SourceVaultSlideDeckPresentationSpec[query] は発表実行に必要な payload\n" <>
  "(found/id/title/url/secondsPerSlide/startSlide/endSlide/slideCount/\n" <>
  "narrationInstructions/privacyLevel/talkWithheld/talk) を小文字キーの\n" <>
  "JSON-safe な Association で返す。オプション \"IncludeTalk\" -> True|False。";

SourceVaultSlideDeckList::usage =
  "SourceVaultSlideDeckList[] は発表一覧を JSON-safe な小文字キー Association の\n" <>
  "リストで返す (原稿本文は含まない)。";

Begin["`SlideDeckPrivate`"]

If[! ValueQ[SourceVault`$SourceVaultSlideDeckRoot],
  SourceVault`$SourceVaultSlideDeckRoot = Automatic];
If[! ValueQ[SourceVault`$SourceVaultSlideDeckReleaseCeiling],
  SourceVault`$SourceVaultSlideDeckReleaseCeiling = 0.5];

(* ---------------- 保存場所 ---------------- *)

iSDLocalFallbackRoot[] := Module[{base},
  base = Quiet @ Check[Environment["LOCALAPPDATA"], $Failed];
  If[! StringQ[base] || StringLength[base] === 0,
    base = Quiet @ Check[$TemporaryDirectory, "."]];
  FileNameJoin[{base, "SourceVault", "slidedecks"}]];

iSDResolveRoot[] := Module[{override, core},
  override = SourceVault`$SourceVaultSlideDeckRoot;
  If[StringQ[override] && StringLength[override] > 0, Return[override]];
  core = If[Length[DownValues[SourceVault`SourceVaultCoreRoot]] > 0,
    Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed], $Failed];
  If[StringQ[core] && StringLength[core] > 0,
    FileNameJoin[{core, "slidedecks"}],
    iSDLocalFallbackRoot[]]];

iSDEnsureDirectory[dir_String] := (
  If[! DirectoryQ[dir],
    Quiet @ Check[CreateDirectory[dir, CreateIntermediateDirectories -> True], Null]];
  dir);

SourceVaultSlideDeckRoot[] := iSDEnsureDirectory[iSDResolveRoot[]];

iSDTalkDirectory[] := iSDEnsureDirectory[
  FileNameJoin[{SourceVaultSlideDeckRoot[], "talks"}]];

iSDRegistryFile[] := FileNameJoin[{SourceVaultSlideDeckRoot[], "registry.json"}];

(* ---------------- JSON I/O (単一 UTF-8 エンコード) ----------------
   ExportString["RawJSON"] は日本語 Windows で UTF-8 バイトを codepoint 展開した
   String を返すため、必ず ExportByteArray で書き ReadByteArray で読む。 *)

(* ReplaceAll (1 パス) であること。//. だと Real -> N[Real] のような恒等規則で
   固定点に到達せず、Association 相手に無限ループになる (実測: 20s で戻らない)。 *)
iSDJSONSafe[expr_] := expr /. {
  m_Missing :> Null,
  dt_DateObject :> DateString[dt, "ISODateTime"]};

(* 登録簿は既定で CoreRoot (Dropbox) 配下に置かれる。同期中の一時ロックで読み書きが
   単発で失敗することが実測であるため、両方向とも短いリトライを入れる。ここで諦めると
   「登録済みの発表が未登録と報告される」という最悪の壊れ方をする。 *)
$iSDRetryCount = 5;
$iSDRetryPause = 0.05;

iSDWriteJSON[path_String, data_] := Module[{ba, dir = DirectoryName[path], tmp, done},
  iSDEnsureDirectory[dir];
  ba = Quiet @ Check[ExportByteArray[iSDJSONSafe[data], "RawJSON"], $Failed];
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
    Pause[$iSDRetryPause],
    {$iSDRetryCount}];
  If[done, path, $Failed]];

iSDReadJSON[path_String] := Module[{bytes, parsed},
  If[! FileExistsQ[path], Return[Missing["NoFile"]]];
  Do[
    bytes = Quiet @ Check[ReadByteArray[path], $Failed];
    If[ByteArrayQ[bytes],
      parsed = Quiet @ Check[ImportByteArray[bytes, "RawJSON"], $Failed];
      If[parsed =!= $Failed, Return[parsed, Module]]];
    Pause[$iSDRetryPause],
    {$iSDRetryCount}];
  If[ByteArrayQ[bytes], Missing["BadJSON"], Missing["Unreadable"]]];

(* ---------------- 正規化と照合 ---------------- *)

iSDNormalize[value_] := Module[{t},
  t = ToString[value];
  t = Quiet @ Check[CharacterNormalize[t, "NFKC"], t];
  If[! StringQ[t], t = ToString[value]];
  t = ToLowerCase[t];
  StringJoin @ Select[Characters[t],
    StringMatchQ[#, LetterCharacter | DigitCharacter] &]];

iSDTrailingDigits[s_String] := Module[{m},
  m = StringCases[s, d : DigitCharacter .. ~~ EndOfString :> d];
  If[m === {}, "", First[m]]];

iSDBigrams[s_String] := If[StringLength[s] < 2, {s},
  Table[StringTake[s, {i, i + 1}], {i, StringLength[s] - 1}]];

iSDJaccard[a_String, b_String] := Module[{x, y, u},
  x = Union[iSDBigrams[a]]; y = Union[iSDBigrams[b]];
  u = Union[x, y];
  If[x === {} || y === {} || u === {}, 0.,
    N[Length[Intersection[x, y]] / Length[u]]]];

SourceVaultSlideDeckMatchScore[query_, candidate_] := Module[{a, b, da, db},
  a = iSDNormalize[query]; b = iSDNormalize[candidate];
  If[a === "" || b === "", Return[0.]];
  (* 番号違いは別の発表。ここを緩めると 31 の依頼で 30 が始まる *)
  da = iSDTrailingDigits[a]; db = iSDTrailingDigits[b];
  If[da =!= "" && db =!= "" && da =!= db, Return[0.]];
  Which[
    a === b, 1.,
    StringStartsQ[a, b] || StringStartsQ[b, a], 0.9,
    StringContainsQ[a, b] || StringContainsQ[b, a], 0.8,
    True, iSDJaccard[a, b]]];

$iSDMatchThreshold = 0.34;

iSDEntryKeys[entry_Association] := DeleteDuplicates @ Select[
  Join[
    {Lookup[entry, "Title", ""], Lookup[entry, "Id", ""]},
    Flatten[{Lookup[entry, "Aliases", {}]}]],
  StringQ[#] && StringTrim[#] =!= "" &];

iSDEntryScore[query_, entry_Association] :=
  Max[Append[SourceVaultSlideDeckMatchScore[query, #] & /@ iSDEntryKeys[entry], 0.]];

(* ---------------- 登録簿 ---------------- *)

iSDDefaultId[entry_Association] := Module[{norm},
  norm = iSDNormalize[Lookup[entry, "Title", ""]];
  If[norm === "", "deck" <> IntegerString[Hash[entry, "SHA256"], 36, 8],
    StringTake[norm, UpTo[64]]]];

iSDReadRegistry[] := Module[{raw, entries},
  raw = iSDReadJSON[iSDRegistryFile[]];
  entries = If[AssociationQ[raw], Lookup[raw, "Entries", {}], {}];
  If[! ListQ[entries], entries = {}];
  Select[entries, AssociationQ]];

iSDWriteRegistry[entries_List] := iSDWriteJSON[iSDRegistryFile[],
  <|"Version" -> 1, "UpdatedAtUTC" -> iSDUTCNow[], "Entries" -> entries|>];

iSDUTCNow[] := Quiet @ Check[
  DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z", ""];

SourceVaultSlideDeckRegistry[] := iSDReadRegistry[];

iSDNumberOr[value_, default_] := If[NumericQ[value], N[value], default];

iSDNormalizeEntry[entryIn_Association] := Module[{e = entryIn, id},
  e["Title"] = StringTrim @ ToString @ Lookup[e, "Title", ""];
  e["SlideURL"] = StringTrim @ ToString @ Lookup[e, "SlideURL", ""];
  id = Lookup[e, "Id", Automatic];
  e["Id"] = If[StringQ[id] && StringTrim[id] =!= "", StringTrim[id], iSDDefaultId[e]];
  e["Aliases"] = Select[Flatten[{Lookup[e, "Aliases", {}]}],
    StringQ[#] && StringTrim[#] =!= "" &];
  e["SecondsPerSlide"] = iSDNumberOr[Lookup[e, "SecondsPerSlide", 25.], 25.];
  e["StartSlide"] = With[{s = Lookup[e, "StartSlide", 1]},
    If[IntegerQ[s] && s >= 1, s, 1]];
  e["EndSlide"] = With[{s = Lookup[e, "EndSlide", Null]},
    If[IntegerQ[s] && s >= 1, s, Null]];
  e["SlideCount"] = With[{s = Lookup[e, "SlideCount", Null]},
    If[IntegerQ[s] && s >= 0, s, Null]];
  e["NarrationInstructions"] = ToString @ Lookup[e, "NarrationInstructions", ""];
  (* privacy は登録時に明示する。読み側は欠落を 1.0 とみなす *)
  e["PrivacyLevel"] = iSDNumberOr[Lookup[e, "PrivacyLevel", 0.], 0.];
  e["UpdatedAtUTC"] = iSDUTCNow[];
  KeyDrop[e, {"TalkMarkdown"}]];

SourceVaultSlideDeckRegister[entry_Association] :=
  SourceVaultSlideDeckRegister[entry, None];

SourceVaultSlideDeckRegister[entryIn_Association, talk_] := Module[
  {entry, entries, id, talkFile, talkJSON, markdown},
  entry = iSDNormalizeEntry[entryIn];
  If[entry["Title"] === "",
    Return[Failure["SlideDeckTitleRequired",
      <|"MessageTemplate" -> "発表タイトル (Title) は必須です。"|>]]];
  If[! StringMatchQ[entry["SlideURL"], ("http://" | "https://") ~~ __],
    Return[Failure["SlideDeckURLRequired",
      <|"MessageTemplate" -> "SlideURL は http(s) の絶対 URL である必要があります。",
        "SlideURL" -> entry["SlideURL"]|>]]];
  id = entry["Id"];
  iSDTalkDirectory[];
  markdown = Lookup[entryIn, "TalkMarkdown", None];
  If[StringQ[markdown] && StringTrim[markdown] =!= "",
    talkFile = FileNameJoin[{iSDTalkDirectory[], id <> ".md"}];
    Quiet @ Check[
      Export[talkFile, markdown, "Text", CharacterEncoding -> "UTF-8"], Null];
    entry["TalkFile"] = FileNameJoin[{"talks", id <> ".md"}]];
  If[AssociationQ[talk],
    talkJSON = FileNameJoin[{iSDTalkDirectory[], id <> ".json"}];
    iSDWriteJSON[talkJSON, iSDNormalizeTalk[talk, id, entry]];
    entry["TalkJSON"] = FileNameJoin[{"talks", id <> ".json"}];
    entry["TalkURI"] = "sv://slidetalk/" <> id;
    If[entry["SlideCount"] === Null,
      With[{n = Length @ Lookup[talk, "Slides", {}]},
        If[n > 0, entry["SlideCount"] = n]]]];
  entries = iSDReadRegistry[];
  entries = Append[Select[entries, Lookup[#, "Id", ""] =!= id &], entry];
  If[iSDWriteRegistry[entries] === $Failed,
    Failure["SlideDeckRegistryWriteFailed",
      <|"MessageTemplate" -> "登録簿を書き込めませんでした。", "Path" -> iSDRegistryFile[]|>],
    entry]];

SourceVaultSlideDeckUnregister[query_String] := Module[{entry, entries},
  entry = SourceVaultSlideDeckLookup[query];
  If[! AssociationQ[entry], Return[entry]];
  entries = Select[iSDReadRegistry[], Lookup[#, "Id", ""] =!= entry["Id"] &];
  iSDWriteRegistry[entries];
  <|"Status" -> "Unregistered", "Id" -> entry["Id"], "Title" -> entry["Title"]|>];

SourceVaultSlideDeckLookup[query_] := Module[{entries, scored, best},
  If[! StringQ[query] || StringTrim[query] === "",
    Return[Missing["NotFound", query]]];
  entries = iSDReadRegistry[];
  If[entries === {}, Return[Missing["NotFound", query]]];
  scored = {iSDEntryScore[query, #], #} & /@ entries;
  scored = Select[scored, First[#] >= $iSDMatchThreshold &];
  If[scored === {}, Return[Missing["NotFound", query]]];
  best = First @ SortBy[scored, -First[#] &];
  Last[best]];

(* ---------------- 発表シナリオ ---------------- *)

iSDNormalizeSlideEntry[slide_, index_Integer, entry_] := Module[{s, n},
  s = If[AssociationQ[slide], slide, <|"Text" -> ToString[slide]|>];
  n = Lookup[s, "Slide", Lookup[s, "slide", index]];
  <|"Slide" -> If[IntegerQ[n] && n >= 1, n, index],
    "Title" -> ToString @ Lookup[s, "Title", Lookup[s, "title", ""]],
    "Seconds" -> With[{v = Lookup[s, "Seconds", Lookup[s, "seconds", Null]]},
      If[NumericQ[v] && N[v] > 0., N[v], Null]],
    "Text" -> ToString @ Lookup[s, "Text", Lookup[s, "text", ""]]|>];

iSDNormalizeTalk[talkIn_Association, id_String, entry_] := Module[{slides},
  slides = Lookup[talkIn, "Slides", Lookup[talkIn, "slides", {}]];
  If[! ListQ[slides], slides = {}];
  slides = MapIndexed[iSDNormalizeSlideEntry[#1, First[#2], entry] &, slides];
  <|"Version" -> 1, "Id" -> id,
    "Title" -> ToString @ Lookup[talkIn, "Title", Lookup[entry, "Title", ""]],
    "Language" -> ToString @ Lookup[talkIn, "Language", "Japanese"],
    "Opening" -> ToString @ Lookup[talkIn, "Opening", Lookup[talkIn, "opening", ""]],
    "Closing" -> ToString @ Lookup[talkIn, "Closing", Lookup[talkIn, "closing", ""]],
    "Slides" -> slides|>];

iSDTalkPath[entry_Association] := Module[{rel},
  rel = Lookup[entry, "TalkJSON", None];
  If[! StringQ[rel] || StringTrim[rel] === "", Return[None]];
  If[FileNameDepth[rel] > 0 && FileExistsQ[rel], Return[rel]];
  FileNameJoin[{SourceVaultSlideDeckRoot[], rel}]];

SourceVaultSlideDeckTalk[query_] := Module[{entry, path, talk},
  entry = If[AssociationQ[query], query, SourceVaultSlideDeckLookup[query]];
  If[! AssociationQ[entry], Return[entry]];
  path = iSDTalkPath[entry];
  If[path === None || ! FileExistsQ[path], Return[Missing["NoTalk", entry["Id"]]]];
  talk = iSDReadJSON[path];
  If[! AssociationQ[talk], Return[Missing["NoTalk", entry["Id"]]]];
  iSDNormalizeTalk[talk, ToString @ Lookup[entry, "Id", ""], entry]];

(* ---------------- 発表 payload ---------------- *)

(* privacy 欠落は 1.0 (fail-closed)。数値でない値も同様。 *)
iSDPrivacyOf[entry_Association] := With[{v = Lookup[entry, "PrivacyLevel", Missing[]]},
  If[NumericQ[v], N[v], 1.]];

iSDReleasableQ[entry_Association] :=
  iSDPrivacyOf[entry] < iSDCeiling[];

iSDCeiling[] := With[{c = SourceVault`$SourceVaultSlideDeckReleaseCeiling},
  If[NumericQ[c], N[c], 0.5]];

iSDTalkPayload[talk_Association] := <|
  "opening" -> Lookup[talk, "Opening", ""],
  "closing" -> Lookup[talk, "Closing", ""],
  "slides" -> (<|"slide" -> #["Slide"], "title" -> #["Title"],
      "seconds" -> #["Seconds"], "text" -> #["Text"]|> & /@
    Select[Lookup[talk, "Slides", {}],
      AssociationQ[#] && StringTrim[ToString[Lookup[#, "Text", ""]]] =!= "" &])|>;

iSDEntryPayload[entry_Association] := <|
  "id" -> ToString @ Lookup[entry, "Id", ""],
  "title" -> ToString @ Lookup[entry, "Title", ""],
  "aliases" -> Select[Flatten[{Lookup[entry, "Aliases", {}]}], StringQ],
  "url" -> ToString @ Lookup[entry, "SlideURL", ""],
  "event" -> ToString @ Lookup[entry, "Event", ""],
  "author" -> ToString @ Lookup[entry, "Author", ""],
  "date" -> ToString @ Lookup[entry, "Date", ""],
  "slideCount" -> Lookup[entry, "SlideCount", Null],
  "secondsPerSlide" -> iSDNumberOr[Lookup[entry, "SecondsPerSlide", 25.], 25.],
  "startSlide" -> With[{s = Lookup[entry, "StartSlide", 1]}, If[IntegerQ[s], s, 1]],
  "endSlide" -> With[{s = Lookup[entry, "EndSlide", Null]}, If[IntegerQ[s], s, Null]],
  "narrationInstructions" -> ToString @ Lookup[entry, "NarrationInstructions", ""],
  "talkURI" -> ToString @ Lookup[entry, "TalkURI", ""],
  "privacyLevel" -> iSDPrivacyOf[entry],
  "updatedAtUTC" -> ToString @ Lookup[entry, "UpdatedAtUTC", ""]|>;

SourceVaultSlideDeckList[] := iSDEntryPayload /@ Select[iSDReadRegistry[], iSDReleasableQ];

Options[SourceVaultSlideDeckPresentationSpec] = {"IncludeTalk" -> True};

SourceVaultSlideDeckPresentationSpec[query_, OptionsPattern[]] := Module[
  {entry, payload, includeTalk, talk, released},
  entry = If[AssociationQ[query], query, SourceVaultSlideDeckLookup[query]];
  If[! AssociationQ[entry],
    Return[<|"found" -> False, "query" -> ToString[query],
      "reason" -> "NotRegistered",
      "available" -> (Lookup[#, "title", ""] & /@ SourceVaultSlideDeckList[])|>]];
  released = iSDReleasableQ[entry];
  payload = iSDEntryPayload[entry];
  includeTalk = TrueQ[OptionValue["IncludeTalk"]];
  If[! released,
    (* タイトルと privacy だけ返す。URL も原稿も外へ出さない *)
    Return[Join[<|"found" -> True, "released" -> False, "talkWithheld" -> True,
      "talk" -> Null|>,
      KeyTake[payload, {"id", "title", "privacyLevel"}]]]];
  talk = If[includeTalk, SourceVaultSlideDeckTalk[entry], Missing["Skipped"]];
  Join[
    <|"found" -> True, "released" -> True|>,
    payload,
    If[AssociationQ[talk],
      <|"talkWithheld" -> False, "talk" -> iSDTalkPayload[talk]|>,
      <|"talkWithheld" -> False, "talk" -> Null|>]]];

End[]

EndPackage[]
