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
  "発表を登録簿へ upsert する。entry は Title (必須)・SlideURL か PosterURL (どちらか必須)・\n" <>
  "Aliases (呼び名: 話しかけて始めるときの短い名。照合で題名より優先)・\n" <>
  "Id・DeckFile・SecondsPerSlide・StartSlide・EndSlide・NarrationInstructions・\n" <>
  "Event・Author・Date・PrivacyLevel (既定 0.0)・TalkMarkdown・PosterTalk を持つ Association。\n" <>
  "talk はコンパイル済みシナリオ (<|Opening, Closing, Slides|>) で、与えると\n" <>
  "talks/<id>.json へ、TalkMarkdown があれば talks/<id>.md へ保存する。\n" <>
  "PosterTalk (同じ形のポスター原稿) は talks/<id>_poster.json へ保存し、ポスター発表で読む。\n" <>
  "再登録 (同じデッキで押し直し) は前回のエントリを土台にし、今回与えた\n" <>
  "(空でない) 値だけを上書きする。前回エントリの特定は Id > DeckFile > SlideURL なので\n" <>
  "タイトルを直しても別エントリにならない。\"Merge\" -> False で完全差し替え。\n" <>
  "戻り値には RegistryStatus (Created|Updated) と ChangedKeys が付く。";

SourceVaultSlideDeckUnregister::usage =
  "SourceVaultSlideDeckUnregister[idOrTitle] は登録を削除する。";

SourceVaultSlideDeckRegistry::usage =
  "SourceVaultSlideDeckRegistry[] は登録済み発表エントリのリストを返す。";

SourceVaultSlideDeckLookup::usage =
  "SourceVaultSlideDeckLookup[query] は発表タイトル (別名・表記ゆれ可) から\n" <>
  "エントリ 1 件を返す。見つからなければ Missing[\"NotFound\", query]。\n" <>
  "まず呼び名 (Aliases) だけで探し、呼び名で見つからないときに限って題名\n" <>
  "(Title / Id / Event) で近いものを探す (戻り値の MatchedBy が \"Alias\" | \"Title\")。\n" <>
  "末尾の番号が食い違う候補 (31 と 30) は決して一致しない。";

SourceVaultSlideDeckPosterTalk::usage =
  "SourceVaultSlideDeckPosterTalk[idOrTitle] はポスター原稿 (SlideWorkflow の SlidePosterTalk\n" <>
  "セルから登録されたもの) を SourceVaultSlideDeckTalk と同じ形で返す。無ければ Missing[\"NoPosterTalk\", id]。";

SourceVaultSlideDeckMatchScore::usage =
  "SourceVaultSlideDeckMatchScore[query, candidate] は 0.0-1.0 の照合スコア。";

SourceVaultSlideDeckTalk::usage =
  "SourceVaultSlideDeckTalk[idOrTitle] はコンパイル済み発表シナリオ\n" <>
  "<|\"Opening\"->, \"Closing\"->, \"Slides\"->{<|\"Slide\",\"Seconds\",\"Text\"|>..}|> を返す。";

SourceVaultSlideDeckPresentationSpec::usage =
  "SourceVaultSlideDeckPresentationSpec[query] は発表実行に必要な payload\n" <>
  "(found/id/title/url/posterUrl/format/matchedBy/secondsPerSlide/startSlide/endSlide/\n" <>
  "slideCount/narrationInstructions/privacyLevel/talkWithheld/talk/posterTalk) を小文字キーの\n" <>
  "JSON-safe な Association で返す。format は SlideURL があれば \"slides\"、ポスター PDF だけなら\n" <>
  "\"poster\"。posterTalk はポスター原稿 (無ければ Null)。オプション \"IncludeTalk\" -> True|False。";

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

(* 末尾の漢数字の番号を数字にする: 「計算と自然三十三」 -> 「計算と自然33」。
   照合は末尾の数字で発表を区別するので、漢数字のままだと 31/32/33 が同点になり、
   先頭の 31 が始まった (VRChat の音声、2026-09-19)。一文字の「一」は変えない
   (「一つ」「一度」のほうがずっと多い)。末尾の「回」は番号の飾りとして落とす。 *)
$iSDKanjiDigit = <|"〇" -> 0, "零" -> 0, "一" -> 1, "二" -> 2, "三" -> 3,
  "四" -> 4, "五" -> 5, "六" -> 6, "七" -> 7, "八" -> 8, "九" -> 9|>;

iSDSplitAt[t_String, u_String] := With[{p = StringPosition[t, u, 1]},
  If[p === {}, None, {StringTake[t, p[[1, 1]] - 1], StringDrop[t, p[[1, 2]]]}]];

iSDKanjiNumber[s_String] := Module[{t = s, total = 0, parts},
  If[s === "", Return[Missing["NotANumber"]]];
  If[StringFreeQ[t, "十" | "百"],
    Return[If[AllTrue[Characters[t], KeyExistsQ[$iSDKanjiDigit, #] &],
      FromDigits[Lookup[$iSDKanjiDigit, Characters[t]]], Missing["NotANumber"]]]];
  Do[
    parts = iSDSplitAt[t, First[u]];
    If[parts =!= None,
      total += If[First[parts] === "", 1,
        Lookup[$iSDKanjiDigit, First[parts], Missing["NotANumber"]]] * Last[u];
      t = Last[parts]],
    {u, {{"百", 100}, {"十", 10}}}];
  If[t =!= "", total += Lookup[$iSDKanjiDigit, t, Missing["NotANumber"]]];
  If[IntegerQ[total], total, Missing["NotANumber"]]];

iSDTrailingNumberDigits[t_String] := Module[{m, v, s = t},
  s = StringReplace[s, RegularExpression["(\\d+)回$"] -> "$1"];
  m = StringCases[s,
    RegularExpression["^(.*?)([〇零一二三四五六七八九十百]+)回?$"] :> {"$1", "$2"}];
  If[m === {} || m[[1, 2]] === "一", Return[s]];
  v = iSDKanjiNumber[m[[1, 2]]];
  If[IntegerQ[v], m[[1, 1]] <> ToString[v], s]];

iSDNormalize[value_] := Module[{t},
  t = ToString[value];
  t = Quiet @ Check[CharacterNormalize[t, "NFKC"], t];
  If[! StringQ[t], t = ToString[value]];
  t = ToLowerCase[t];
  iSDTrailingNumberDigits @ StringJoin @ Select[Characters[t],
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

(* ---- 呼び名 (Aliases) 優先の 2 段照合 (2026-10-16) ----
   呼び名は「話しかけて始めるときの短い名」(SlideWorkflow の指示セル Aliases: / 呼び名: 行)。
   題名が長い発表 (ポスターなど) では題名そのものを言わないので、まず呼び名だけで探し、
   呼び名で見つからないときに限って題名 (Title / Id / Event) で近いものを探す。
   呼び名の一致は題名の一致より常に優先する (「CIHCD 2026」で題名の似た別の発表が始まらない)。 *)
iSDAliasKeys[entry_Association] := Select[Flatten[{Lookup[entry, "Aliases", {}]}],
  StringQ[#] && StringTrim[#] =!= "" &];

(* 題名段の鍵 = 従来どおり Title / Id / Aliases (あいまい照合) に Event を足したもの *)
iSDTitleKeys[entry_Association] := DeleteDuplicates @ Select[
  Join[{Lookup[entry, "Title", ""], Lookup[entry, "Id", ""], Lookup[entry, "Event", ""]},
    Flatten[{Lookup[entry, "Aliases", {}]}]],
  StringQ[#] && StringTrim[#] =!= "" &];

(* 呼び名段のスコア: 呼び名は丸ごと言われたときだけ効く (依頼文が呼び名を含む:
   完全一致 1.0 / 先頭 0.9 / 途中 0.8)。呼び名の一部しか言われていないとき
   (「計算と自然」に対して呼び名「計算と自然集会31」) は題名段へ降りる — 題名段は同点を
   Ambiguous にするので、番号の読めない依頼で先頭の発表が始まることがない。 *)
iSDAliasContainScore[query_, alias_] := Module[{a, b, da, db},
  a = iSDNormalize[query]; b = iSDNormalize[alias];
  If[a === "" || b === "", Return[0.]];
  da = iSDTrailingDigits[a]; db = iSDTrailingDigits[b];
  If[da =!= "" && db =!= "" && da =!= db, Return[0.]];
  Which[a === b, 1., StringStartsQ[a, b], 0.9, StringContainsQ[a, b], 0.8, True, 0.]];

iSDKeysScore[query_, keys_List, scoreFn_: SourceVaultSlideDeckMatchScore] :=
  Max[Append[scoreFn[query, #] & /@ keys, 0.]];

(* 1 段分の照合: {score, entry}。閾値以上の候補が無ければ None。
   別々の発表が同点で並ぶなら選ばない (Missing["Ambiguous"])。並びの先頭を返していたので、
   番号の読めない依頼で 31 が始まった (2026-09-19) *)
iSDBestMatch[query_, entries_List, keysFn_, scoreFn_: SourceVaultSlideDeckMatchScore] :=
    Module[{scored, best, ties},
  scored = {iSDKeysScore[query, keysFn[#], scoreFn], #} & /@ entries;
  scored = Select[scored, First[#] >= $iSDMatchThreshold &];
  If[scored === {}, Return[None]];
  best = First @ SortBy[scored, -First[#] &];
  ties = DeleteDuplicates[Lookup[Last /@
    Select[scored, Abs[First[#] - First[best]] < 10^-9 &], "Id", Null]];
  If[Length[ties] > 1, Missing["Ambiguous", query], best]];

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
  e["PosterURL"] = StringTrim @ ToString @ Lookup[e, "PosterURL", ""];   (* v1.56: ポスター PDF の URL (SlideWorkflow の PosterURL:) *)
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
  (* PosterTalk (ポスター原稿) は talks/<id>_poster.json へ書くので、エントリ本体には持たない *)
  KeyDrop[e, {"TalkMarkdown", "PosterTalk"}]];

(* ---------------- 再登録 (同じデッキで「登録」を押し直したとき) ----------------
   前回のエントリを土台にし、今回実際に与えられた値だけを上書きする
   (直したところだけが直る)。未記入の項目や、登録簿側でただ一度
   設定した項目 (StartSlide / EndSlide など) を再登録で落とさないため。

   前回エントリの特定は Id > DeckFile > SlideURL。タイトルを直しただけで
   別エントリが増えないよう、Id (タイトル由来) が外れてもデッキファイルと
   配信 URL でも引く。Id を明示したときだけはそれが唯一の鍵。 *)

iSDPathKey[p_] := If[StringQ[p] && StringTrim[p] =!= "",
  ToLowerCase[StringReplace[StringTrim[p], "\\" -> "/"]], ""];

iSDExplicitId[entry_Association] := With[{v = Lookup[entry, "Id", ""]},
  If[StringQ[v] && StringTrim[v] =!= "", StringTrim[v], None]];

iSDFindPrior[entries_List, incoming_Association, id_String] := Module[{f, deck, url},
  f = SelectFirst[entries, ToString[Lookup[#, "Id", ""]] === id &, None];
  If[AssociationQ[f], Return[f]];
  If[iSDExplicitId[incoming] =!= None, Return[None]];
  deck = iSDPathKey[Lookup[incoming, "DeckFile", ""]];
  If[deck =!= "",
    f = SelectFirst[entries, iSDPathKey[Lookup[#, "DeckFile", ""]] === deck &, None];
    If[AssociationQ[f], Return[f]]];
  url = StringTrim[ToString[Lookup[incoming, "SlideURL", ""]]];
  If[url =!= "",
    f = SelectFirst[entries,
      StringTrim[ToString[Lookup[#, "SlideURL", ""]]] === url &, None];
    If[AssociationQ[f], Return[f]]];
  url = StringTrim[ToString[Lookup[incoming, "PosterURL", ""]]];
  If[url =!= "",
    f = SelectFirst[entries,
      StringTrim[ToString[Lookup[#, "PosterURL", ""]]] === url &, None];
    If[AssociationQ[f], Return[f]]];
  None];

(* 空文字列・空リスト・ Null は「今回は指定していない」= 前回の値を残す *)
iSDSuppliedQ[v_] := Which[
  v === Null || v === None || v === Automatic || MissingQ[v], False,
  StringQ[v], StringTrim[v] =!= "",
  ListQ[v], v =!= {},
  True, True];

iSDChangedKeys[entry_Association, prior_] := If[! AssociationQ[prior], {},
  DeleteCases[
    Select[Union[Keys[entry], Keys[prior]],
      Lookup[entry, #, Null] =!= Lookup[prior, #, Null] &],
    "UpdatedAtUTC"]];

Options[SourceVaultSlideDeckRegister] = {"Merge" -> True};

SourceVaultSlideDeckRegister[entry_Association] :=
  SourceVaultSlideDeckRegister[entry, None];

SourceVaultSlideDeckRegister[entry_Association, opts__Rule] :=
  SourceVaultSlideDeckRegister[entry, None, opts];

SourceVaultSlideDeckRegister[entryIn_Association,
    talk : Except[_Rule | _RuleDelayed], OptionsPattern[]] := Module[
  {entry, entries, prior, baseId, changed, id, talkFile, talkJSON, markdown,
   talkChanged = False, posterTalk, posterJSON, newPoster, posterChanged = False},
  entries = iSDReadRegistry[];
  baseId = iSDNormalizeEntry[entryIn]["Id"];
  prior = If[TrueQ[OptionValue["Merge"]],
    iSDFindPrior[entries, entryIn, baseId], None];
  entry = iSDNormalizeEntry[
    If[AssociationQ[prior],
      Join[KeyDrop[prior, {"UpdatedAtUTC"}],
        Select[KeyDrop[entryIn, {"Id"}], iSDSuppliedQ],
        <|"Id" -> ToString[Lookup[prior, "Id", baseId]]|>],
      entryIn]];
  If[entry["Title"] === "",
    Return[Failure["SlideDeckTitleRequired",
      <|"MessageTemplate" -> "発表タイトル (Title) は必須です。"|>]]];
  (* SlideURL (mp4) か PosterURL (ポスター PDF) のどちらかが要る。ポスターだけの発表も同じ登録簿・同じ QA を使う *)
  If[! StringMatchQ[entry["SlideURL"], ("http://" | "https://") ~~ __] &&
      ! StringMatchQ[ToString @ Lookup[entry, "PosterURL", ""], ("http://" | "https://") ~~ __],
    Return[Failure["SlideDeckURLRequired",
      <|"MessageTemplate" -> "SlideURL か PosterURL のどちらかが http(s) の絶対 URL である必要があります。",
        "SlideURL" -> entry["SlideURL"]|>]]];
  id = entry["Id"];
  iSDTalkDirectory[];
  markdown = Lookup[entryIn, "TalkMarkdown", None];
  If[StringQ[markdown] && StringTrim[markdown] =!= "",
    talkFile = FileNameJoin[{iSDTalkDirectory[], id <> ".md"}];
    (* 原稿はエントリの外 (talks/<id>.md) なので、変わったかをここで見る *)
    talkChanged = ! FileExistsQ[talkFile] ||
      With[{old = Quiet[Check[
          Import[talkFile, "Text", CharacterEncoding -> "UTF-8"], None]]},
        (* Import["Text"] は末尾改行を落とすので、改行だけの差で変更扱いにしない *)
        ! StringQ[old] ||
          StringTrim[StringReplace[old, "\r\n" -> "\n"]] =!=
            StringTrim[StringReplace[markdown, "\r\n" -> "\n"]]];
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
  (* ポスター原稿 (SlideWorkflow の SlidePosterTalk セル) はスライド原稿と別の原稿。
     talks/<id>_poster.json へ置き、ポスターだけの発表 (SlideURL 無し) を VRCRealtime が
     読むときに使う。前回の原稿は今回与えられたときだけ差し替える (再登録で落とさない)。 *)
  posterTalk = Lookup[entryIn, "PosterTalk", None];
  If[AssociationQ[posterTalk] && iSDTalkNonEmptyQ[posterTalk],
    posterJSON = FileNameJoin[{iSDTalkDirectory[], id <> "_poster.json"}];
    newPoster = iSDNormalizeTalk[posterTalk, id, entry];
    posterChanged = ! FileExistsQ[posterJSON] ||
      With[{old = iSDReadJSON[posterJSON]},
        ! AssociationQ[old] || iSDNormalizeTalk[old, id, entry] =!= newPoster];
    iSDWriteJSON[posterJSON, newPoster];
    entry["PosterTalkJSON"] = FileNameJoin[{"talks", id <> "_poster.json"}];
    entry["PosterTalkURI"] = "sv://slidetalk/" <> id <> "/poster"];
  changed = iSDChangedKeys[entry, prior];
  If[AssociationQ[prior] && TrueQ[talkChanged], AppendTo[changed, "Talk"]];
  If[AssociationQ[prior] && TrueQ[posterChanged], AppendTo[changed, "PosterTalk"]];
  (* 並びを崩さずに差し替える (新規は末尾へ) *)
  entries = If[AnyTrue[entries, ToString[Lookup[#, "Id", ""]] === id &],
    Replace[entries, e_Association /; ToString[Lookup[e, "Id", ""]] === id :> entry, {1}],
    Append[entries, entry]];
  If[iSDWriteRegistry[entries] === $Failed,
    Failure["SlideDeckRegistryWriteFailed",
      <|"MessageTemplate" -> "登録簿を書き込めませんでした。", "Path" -> iSDRegistryFile[]|>],
    Join[entry, <|"RegistryStatus" -> If[AssociationQ[prior], "Updated", "Created"],
      "ChangedKeys" -> changed|>]]];

SourceVaultSlideDeckUnregister[query_String] := Module[{entry, entries},
  entry = SourceVaultSlideDeckLookup[query];
  If[! AssociationQ[entry], Return[entry]];
  entries = Select[iSDReadRegistry[], Lookup[#, "Id", ""] =!= entry["Id"] &];
  iSDWriteRegistry[entries];
  <|"Status" -> "Unregistered", "Id" -> entry["Id"], "Title" -> entry["Title"]|>];

(* 呼び名 (Aliases) → 題名 (Title / Id / Event) の順。戻り値のエントリには
   どちらで一致したか (MatchedBy: "Alias" | "Title") とスコアが付く。
   呼び名で同点の別発表が並べば、題名へ降りずに Ambiguous (呼び名の衝突は直すべき登録の問題)。 *)
SourceVaultSlideDeckLookup[query_] := Module[{entries, hit},
  If[! StringQ[query] || StringTrim[query] === "",
    Return[Missing["NotFound", query]]];
  entries = iSDReadRegistry[];
  If[entries === {}, Return[Missing["NotFound", query]]];
  hit = iSDBestMatch[query, entries, iSDAliasKeys, iSDAliasContainScore];
  If[MissingQ[hit], Return[hit]];
  If[ListQ[hit],
    Return[Join[Last[hit], <|"MatchedBy" -> "Alias", "MatchScore" -> First[hit]|>]]];
  hit = iSDBestMatch[query, entries, iSDTitleKeys];
  If[MissingQ[hit], Return[hit]];
  If[ListQ[hit],
    Return[Join[Last[hit], <|"MatchedBy" -> "Title", "MatchScore" -> First[hit]|>]]];
  Missing["NotFound", query]];

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

iSDTalkPathOf[entry_Association, key_String] := Module[{rel},
  rel = Lookup[entry, key, None];
  If[! StringQ[rel] || StringTrim[rel] === "", Return[None]];
  If[FileNameDepth[rel] > 0 && FileExistsQ[rel], Return[rel]];
  FileNameJoin[{SourceVaultSlideDeckRoot[], rel}]];

iSDTalkPath[entry_Association] := iSDTalkPathOf[entry, "TalkJSON"];

(* 原稿 (Opening か 1 枚でも本文) があるか。空の原稿は書かない (前回の原稿を消さない) *)
iSDTalkNonEmptyQ[talk_Association] := Module[{slides},
  slides = Lookup[talk, "Slides", Lookup[talk, "slides", {}]];
  StringTrim[ToString @ Lookup[talk, "Opening", Lookup[talk, "opening", ""]]] =!= "" ||
    (ListQ[slides] && AnyTrue[slides,
      AssociationQ[#] && StringTrim[ToString @ Lookup[#, "Text", Lookup[#, "text", ""]]] =!= "" &])];

iSDReadTalkFile[entry_Association, key_String, missingTag_String] := Module[{path, talk},
  path = iSDTalkPathOf[entry, key];
  If[path === None || ! FileExistsQ[path], Return[Missing[missingTag, entry["Id"]]]];
  talk = iSDReadJSON[path];
  If[! AssociationQ[talk], Return[Missing[missingTag, entry["Id"]]]];
  iSDNormalizeTalk[talk, ToString @ Lookup[entry, "Id", ""], entry]];

SourceVaultSlideDeckTalk[query_] := Module[{entry},
  entry = If[AssociationQ[query], query, SourceVaultSlideDeckLookup[query]];
  If[! AssociationQ[entry], Return[entry]];
  iSDReadTalkFile[entry, "TalkJSON", "NoTalk"]];

(* privacy: the poster script is the talk text itself, so it leaves through the canonical Result exit
   with the entry's PL (missing = 1.0, fail-closed; iSDPrivacyOf). PresentationSpec only reaches here for
   released entries (PL < ceiling), so that path stays below the marking threshold. *)
SourceVaultSlideDeckPosterTalk[query_] := Module[{entry, talk},
  entry = If[AssociationQ[query], query, SourceVaultSlideDeckLookup[query]];
  If[! AssociationQ[entry], Return[entry]];
  talk = iSDReadTalkFile[entry, "PosterTalkJSON", "NoPosterTalk"];
  If[AssociationQ[talk] && Length[DownValues[SourceVault`SourceVaultPrivateResult]] > 0,
    Quiet @ Check[SourceVault`SourceVaultPrivateResult[talk, iSDPrivacyOf[entry]], talk], talk]];

(* 発表の形: SlideURL (Sliden 用 mp4) があれば "slides"、ポスター PDF だけなら "poster"。
   両方あるときは "slides" (ポスターとして始めるかは呼ぶ側 (音声の「ポスター発表」) が決める) *)
iSDFormatOf[entry_Association] := If[
  ! StringMatchQ[ToString @ Lookup[entry, "SlideURL", ""], ("http://" | "https://") ~~ __] &&
    StringMatchQ[ToString @ Lookup[entry, "PosterURL", ""], ("http://" | "https://") ~~ __],
  "poster", "slides"];

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
  "posterUrl" -> ToString @ Lookup[entry, "PosterURL", ""],
  "event" -> ToString @ Lookup[entry, "Event", ""],
  "author" -> ToString @ Lookup[entry, "Author", ""],
  "date" -> ToString @ Lookup[entry, "Date", ""],
  "slideCount" -> Lookup[entry, "SlideCount", Null],
  "secondsPerSlide" -> iSDNumberOr[Lookup[entry, "SecondsPerSlide", 25.], 25.],
  "startSlide" -> With[{s = Lookup[entry, "StartSlide", 1]}, If[IntegerQ[s], s, 1]],
  "endSlide" -> With[{s = Lookup[entry, "EndSlide", Null]}, If[IntegerQ[s], s, Null]],
  "narrationInstructions" -> ToString @ Lookup[entry, "NarrationInstructions", ""],
  "talkURI" -> ToString @ Lookup[entry, "TalkURI", ""],
  "posterTalkURI" -> ToString @ Lookup[entry, "PosterTalkURI", ""],
  "format" -> iSDFormatOf[entry],
  "matchedBy" -> ToString @ Lookup[entry, "MatchedBy", ""],
  "privacyLevel" -> iSDPrivacyOf[entry],
  "updatedAtUTC" -> ToString @ Lookup[entry, "UpdatedAtUTC", ""]|>;

SourceVaultSlideDeckList[] := iSDEntryPayload /@ Select[iSDReadRegistry[], iSDReleasableQ];

Options[SourceVaultSlideDeckPresentationSpec] = {"IncludeTalk" -> True};

SourceVaultSlideDeckPresentationSpec[query_, OptionsPattern[]] := Module[
  {entry, payload, includeTalk, talk, released, posterTalk},
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
  posterTalk = If[includeTalk, SourceVaultSlideDeckPosterTalk[entry], Missing["Skipped"]];
  Join[
    <|"found" -> True, "released" -> True|>,
    payload,
    If[AssociationQ[talk],
      <|"talkWithheld" -> False, "talk" -> iSDTalkPayload[talk]|>,
      <|"talkWithheld" -> False, "talk" -> Null|>],
    (* ポスター原稿 (あれば)。ポスター発表 (format "poster"、または音声で「ポスター発表」) で読む *)
    <|"posterTalk" -> If[AssociationQ[posterTalk], iSDTalkPayload[posterTalk], Null]|>]];

(* privacy contract for the function added after the module's initial review (model:
   iSVMDRegisterPrivacyContracts in SourceVault_maildb.wl). No-op without the privacy layer. *)
iSDRegisterPrivacyContracts[] :=
  Quiet @ Check[
    If[Length[DownValues[SourceVault`SourceVaultRegisterPrivacyContract]] > 0,
      SourceVault`SourceVaultRegisterPrivacyContract["SourceVaultSlideDeckPosterTalk",
        <|"Class" -> "Private", "Exit" -> "Result", "Sources" -> {"slidedeck"},
          "Module" -> "SourceVault_slidedeck.wl",
          "Note" -> "Returns the stored poster script; PL = the registry entry's PrivacyLevel (missing = 1.0)."|>]];
    Null, Null];
iSDRegisterPrivacyContracts[];

End[]

EndPackage[]
