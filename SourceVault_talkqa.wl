(* ::Package:: *)

(* ============================================================
   SourceVault_talkqa.wl -- 発表用 QA パック (質問 -> 即答) 層

   This file is encoded in UTF-8.
   Load order: SourceVault.wl -> ... -> SourceVault_kb.wl -> SourceVault_talkqa.wl
   Load via:   Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_talkqa.wl"]]

   == 何をするか ==
     発表中に声で聞かれた質問へ、数十 ms で、プライバシーを守って答えるための
     「作り置き」層。既存の層の上に足すだけで、どれも置き換えない。

       SourceVault_kb.wl        Graph-RAG 本体 (slide/figure/topic ノード、BM25 + 伝播、
                                release context によるゲート)。索引と近傍探索はここ。
       SourceVault_webingest.wl 足りないときの web 検索と取り込み。
       SourceVault_crosslink.wl 他の資料からも発表資料へ辿れるようにする provider 登録先。
       SourceVault_realtime.wl  gpt-realtime からの問い合わせ口 (ask tool)。
       SlideWorkflow.wl         デッキと原稿 (<deck>_talk.md)。

     この層がやることは 3 つだけ:
       1) スライドごとに「想定質問 -> 回答候補 -> 出典 sv:// URI」を作り置きする
          (build 時に LLM と KB を使い、実行時には一切使わない)。
       2) 質問が来たら、まず作り置きを引き、外れたら KB を引き、それでも
          足りなければ「web で調べますか」と返す。
       3) いま開いているページを種にした k-hop 近傍を即座に返す (補足説明用)。

   == プライバシー (最重要) ==
     回答候補には必ず PrivacyLevel と Route が焼き込まれる。実行時に判定し直さない
     (速いのと、あとから監査できるため)。

       PL <= $SourceVaultTalkQAPublicMax   -> Route "Public"  クラウド音声で読んでよい
       それ以外                            -> モードで分岐:
           $SourceVaultTalkQAMode = "Private"      -> Route "Local"  (tsukuyomi が読む)
           $SourceVaultTalkQAMode = "Presentation" -> Route "Deny"   (答えない)

     発表モードでは「tsukuyomi が要る質問には答えない」。答えられないことを答えるより、
     答えられないと言う方が事故が小さい。この判断は Ask の戻り値 Status "Blocked" で
     呼び出し側 (音声ブリッジ) に伝える。
   ============================================================ *)

BeginPackage["SourceVault`"];

(* ---- 設定 ---- *)

$SourceVaultTalkQAMode::usage =
  "$SourceVaultTalkQAMode は QA の動作モード。\"Presentation\" (既定) は非公開資料が要る質問に答えない。\n" <>
  "\"Private\" は非公開分を Route \"Local\" (ローカル音声 tsukuyomi) として返す。";

$SourceVaultTalkQAPublicMax::usage =
  "$SourceVaultTalkQAPublicMax はクラウド音声で読んでよい PrivacyLevel の上限 (既定 0.35)。\n" <>
  "これを超える資料は Presentation モードでは使わない。";

$SourceVaultTalkQADefaultPack::usage =
  "$SourceVaultTalkQADefaultPack は packId 省略時に使う QA パック名。";

$SourceVaultTalkQAMinScore::usage =
  "$SourceVaultTalkQAMinScore は KB の答えを採用する BM25 の下限 (既定 2.0)。\n" <>
  "これを下回るヒットは「資料に無い」とみなし、ウェブ検索の可否を尋ねる。\n" <>
  "低くしすぎると、関係のない質問にもそれらしい答えを返してしまう。";

$SourceVaultTalkQAPackSimilarity::usage =
  "$SourceVaultTalkQAPackSimilarity は作り置きの質問を採用する内容語の近さ (既定 0.3)。
" <>
  "同じ固有名詞を含む別の質問に当たるのを防ぐ。下回ると KB を引き直す。";

$SourceVaultTalkQASlide::usage =
  "$SourceVaultTalkQASlide はいま開いているスライド番号 (SourceVaultTalkQASetSlide で設定)。\n" <>
  "近傍検索と、質問の当たり判定の重み付けに使う。";

(* ---- パックの作成と管理 ---- *)

SourceVaultTalkQABuild::usage =
  "SourceVaultTalkQABuild[deck, opts] はスライドデッキから QA パックを作る。\n" <>
  "deck: .nb のパス (原稿 <deck>_talk.md があれば併せて読む)。\n" <>
  "各スライドについて想定質問を作り、KB から回答候補と出典 (sv:// URI) を引いて焼き込む。\n" <>
  "opts: \"PackId\", \"KBId\", \"PrivacyLevel\" (デッキの既定 PL, 既定 0.3),\n" <>
  "\"QuestionsPerSlide\" (既定 3), \"Ingest\" (既定 True = KB へ取り込んでから作る),\n" <>
  "\"Rebuild\" (既定 Automatic), \"QuestionFn\" (Automatic = 資料の PL で経路を選ぶ |\n" <>
  "\"Cloud\" | \"Local\" | \"None\" | 自前の関数 fn[slideText, talkText, k]),\n" <>
  "\"Slides\" -> All | {n...}, \"Verbose\" (既定 True)。";

SourceVaultTalkQAImport::usage =
  "SourceVaultTalkQAImport[deck, slides] は「人が書いた」想定質問と回答をそのまま QA パックへ焼き込む。\n" <>
  "SlideWorkflow の質疑応答セル (SlideQA) が正で、LLM も KB も推測で上書きしない。\n" <>
  "slides: {<|\"Slide\"->n, \"Title\"->.., \"Text\"->スライド本文, \"Talk\"->原稿,\n" <>
  "  \"Entries\"->{<|\"Question\"->q, \"Answer\"->a, \"Citations\"->{..}, \"PrivacyLevel\"->pl|>..}|>..}。\n" <>
  "opts: \"PackId\", \"KBId\", \"SourceId\", \"PrivacyLevel\" (デッキ既定 PL, 既定 0.3),\n" <>
  "\"Ingest\" (既定 True = KB へ取り込んで取りこぼしの受け皿を作る), \"Rebuild\" (既定 Automatic),\n" <>
  "\"Enrich\" (既定 True = 回答が空の想定質問だけ KB から補う), \"Verbose\" (既定 False)。";

SourceVaultTalkQAPacks::usage = "SourceVaultTalkQAPacks[] は作成済み QA パック id の一覧。";
SourceVaultTalkQALoad::usage = "SourceVaultTalkQALoad[packId] は QA パックをメモリに読み込む。";
SourceVaultTalkQAWhere::usage =
  "SourceVaultTalkQAWhere[] は QA パックの置き場の解決結果を返す
" <>
  "(見に行く場所・見つかったファイル・各ルートの由来)。
" <>
  "「パックがありません」と言われたときの切り分けに使う。
" <>
  "この関数が未定義のまま返るなら、そのカーネルは古い版を読んでいる。";

SourceVaultTalkQASelectForDeck::usage =
  "SourceVaultTalkQASelectForDeck[deck] は そのデッキ (.nb またはノートブック) の
" <>
  "QA パックを選んで読み込む。発表ごとに資料が変わるので、一覧の先頭を使わずに
" <>
  "開いているデッキで決める。";

SourceVaultTalkQAUnload::usage = "SourceVaultTalkQAUnload[packId] はメモリ上の QA パックを解放する。";
SourceVaultTalkQAStatus::usage =
  "SourceVaultTalkQAStatus[packId] はパックの状態 (スライド数 / 質問数 / 公開・非公開の内訳 / 作成時刻) を返す。";

(* ---- 実行時 ---- *)

SourceVaultTalkQAAsk::usage =
  "SourceVaultTalkQAAsk[question, opts] は質問に即答する。\n" <>
  "順に (1) 作り置きの想定質問 (2) KB の Graph-RAG (3) 足りなければ \"NeedWeb\" を返す。\n" <>
  "戻り値 <|\"Status\" (\"OK\"|\"Blocked\"|\"NeedWeb\"|\"NotFound\"), \"Route\" (\"Public\"|\"Local\"|\"Deny\"),\n" <>
  "\"AnswerText\", \"SpeakText\", \"Citations\", \"Slide\", \"Source\" (\"Pack\"|\"KB\"|\"Web\"), \"PrivacyLevel\",\n" <>
  "\"ElapsedMs\"|>。opts: \"PackId\", \"Slide\" (既定 $SourceVaultTalkQASlide), \"Mode\", \"AllowWeb\" (既定 False)。";

SourceVaultTalkQANeighbors::usage =
  "SourceVaultTalkQANeighbors[slide, opts] はそのスライドから k ホップで届く資料を返す (補足説明用)。\n" <>
  "opts: \"PackId\", \"Hops\" (既定 2), \"Limit\" (既定 5), \"Mode\"。";

SourceVaultTalkQAWebAnswer::usage =
  "SourceVaultTalkQAWebAnswer[question, opts] は承諾を得たあとの web 検索で回答を作り、\n" <>
  "結果を KB へ取り込んで次回から即答できるようにする。\n" <>
  "opts: \"PackId\", \"KBId\", \"Limit\" (既定 5), \"Ingest\" (既定 True), \"Rebuild\" (既定 True)。";

SourceVaultTalkQAQuestions::usage =
  "SourceVaultTalkQAQuestions[slide] はそのスライドの想定質問と回答候補を返す。";

SourceVaultTalkQASlideInfo::usage =
  "SourceVaultTalkQASlideInfo[n] は n 枚目の記録 (見出し・固有名詞・sv:// リンク・想定質問数) を返す。";

SourceVaultTalkQALinks::usage =
  "SourceVaultTalkQALinks[slide] はそのスライドに結び付いた sv:// URI の一覧を返す。";

SourceVaultTalkQAExport::usage =
  "SourceVaultTalkQAExport[packId] は パックの中身を SourceVaultTalkQAImport と同じ形
" <>
  "({<|\"Slide\", \"Question\", \"Answer\", \"Citations\", \"PrivacyLevel\"|>..}) で返す。
" <>
  "LLM で作った既存パックをスライドの質疑応答セルへ書き戻す (人が直せる形にする) のに使う。";

SourceVaultTalkQAView::usage =
  "SourceVaultTalkQAView[] は QA パックの中身を Dataset で表示する (View 関数)。";

SourceVaultTalkQASetSlide::usage =
  "SourceVaultTalkQASetSlide[n] はいま開いているスライド番号を伝える (SlideWorkflow から呼ばれる)。";

SourceVaultTalkQAHandler::usage =
  "SourceVaultTalkQAHandler[req] は音声ブリッジからの問い合わせ (<|\"query\", \"allowWeb\", \"slide\"|>) に答える。\n" <>
  "SourceVault_realtime の $SourceVaultRealtimeAskHandler へロード時に登録される。";

Begin["`TalkQAPrivate`"];

$tqVersion = "0.2.0";

(* 索引は「全部入り」で作る。build 時に非公開を捨てると Private モードでも
   読めなくなる。公開してよいかは回答時に PL で決める (iTQRoute) *)
$tqReleaseContext = "kb-local";

If[! StringQ[SourceVault`$SourceVaultTalkQAMode],
  SourceVault`$SourceVaultTalkQAMode = "Presentation"];
If[! NumericQ[SourceVault`$SourceVaultTalkQAPublicMax],
  SourceVault`$SourceVaultTalkQAPublicMax = 0.35];
If[! StringQ[SourceVault`$SourceVaultTalkQADefaultPack],
  SourceVault`$SourceVaultTalkQADefaultPack = ""];
If[! IntegerQ[SourceVault`$SourceVaultTalkQASlide],
  SourceVault`$SourceVaultTalkQASlide = 0];
If[! NumericQ[SourceVault`$SourceVaultTalkQAMinScore],
  SourceVault`$SourceVaultTalkQAMinScore = 2.0];
If[! NumericQ[SourceVault`$SourceVaultTalkQAPackSimilarity],
  SourceVault`$SourceVaultTalkQAPackSimilarity = 0.3];

If[! AssociationQ[$tqLoaded], $tqLoaded = <||>];
If[! AssociationQ[$tqPeeked], $tqPeeked = <||>];

iFail[tag_String, msg_String, extra_: <||>] :=
  Failure[tag, Join[<|"MessageTemplate" -> msg|>, extra]];

iStr[x_] := If[StringQ[x], x, ToString[x]];
iNum[x_, d_] := If[NumericQ[x], N[x], d];
iUTC[] := DateString[Now, "ISODateTime"];

(* ---- 置き場: KB と同じ LocalState 配下 (Dropbox 非同期) ---- *)

$tqFile = Quiet @ Check[
  If[StringQ[System`Private`$InputFileName], System`Private`$InputFileName, $InputFileName],
  ""];

(* 共有ボールト (PrivateVault)。他の SourceVault の資産と同じ場所で、
   FE からも headless からも同じに見える *)
iTQVaultRoot[] := Module[{v},
  v = Quiet @ Check[SourceVault`$SourceVaultRoots["PrivateVault"], $Failed];
  If[! StringQ[v], v = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]];
  If[StringQ[v], FileNameJoin[{v, "talkqa"}], Null]];

iTQRoot[] := Module[{v, ls, kbRoot},
  v = iTQVaultRoot[];
  If[StringQ[v], Return[v]];
  (* LocalState は中核にあるので、KB の読み込み状況に左右されない *)
  ls = Quiet @ Check[SourceVault`SourceVaultRoot["LocalState"], $Failed];
  If[StringQ[ls], Return[FileNameJoin[{ls, "kb", "talkqa"}]]];
  kbRoot = Quiet @ Check[SourceVault`SourceVaultKBRoot["_"], $Failed];
  If[StringQ[kbRoot], Return[FileNameJoin[{DirectoryName[kbRoot], "talkqa"}]]];
  FileNameJoin[{$TemporaryDirectory, "SourceVault", "talkqa"}]];

(* 探すときは、過去に使われた置き場も見る。書いた場所と探す場所が
   セッションによって食い違うと「パックがありません」になる *)
(* OS 既定の LocalState。SourceVault の中核も KB も読まれていない状態でも
   同じ場所に辿り着けるようにするため *)
iTQDefaultLocalState[] := Module[{d},
  d = Which[
    $OperatingSystem === "Windows", Quiet @ Environment["LOCALAPPDATA"],
    $OperatingSystem === "MacOSX",
      FileNameJoin[{$HomeDirectory, "Library", "Application Support"}],
    True, FileNameJoin[{$HomeDirectory, ".local", "share"}]];
  If[StringQ[d], FileNameJoin[{d, "SourceVault"}], Null]];

iTQRoots[] := DeleteDuplicates[Select[
  {iTQRoot[], iTQVaultRoot[],
   With[{ls = Quiet @ Check[SourceVault`SourceVaultRoot["LocalState"], $Failed]},
     If[StringQ[ls], FileNameJoin[{ls, "kb", "talkqa"}], Null]],
   With[{ls = iTQDefaultLocalState[]},
     If[StringQ[ls], FileNameJoin[{ls, "kb", "talkqa"}], Null]],
   FileNameJoin[{$TemporaryDirectory, "SourceVault", "talkqa"}]},
  StringQ[#] && DirectoryQ[#] &]];

iTQFind[packId_String] := SelectFirst[
  FileNameJoin[{#, packId <> ".wxf"}] & /@ iTQRoots[], FileExistsQ, ""];

iTQEnsureRoot[] := With[{d = iTQRoot[]},
  If[! DirectoryQ[d], Quiet @ Check[CreateDirectory[d, CreateIntermediateDirectories -> True], Null]];
  d];

iTQPath[packId_String] := FileNameJoin[{iTQEnsureRoot[], packId <> ".wxf"}];

SourceVaultTalkQAWhere[] := <|
  "Version" -> $tqVersion,
  "Root" -> iTQRoot[],
  "SearchedIn" -> iTQRoots[],
  "Files" -> Flatten[FileNames["*.wxf", #] & /@ iTQRoots[]],
  "Packs" -> SourceVaultTalkQAPacks[],
  "DefaultPack" -> SourceVault`$SourceVaultTalkQADefaultPack,
  "Loaded" -> Keys[$tqLoaded],
  "LocalStateRoot" -> Quiet @ Check[SourceVault`SourceVaultRoot["LocalState"], $Failed],
  "OSLocalState" -> iTQDefaultLocalState[],
  "KBRoot" -> Quiet @ Check[SourceVault`SourceVaultKBRoot["_"], $Failed],
  "PackageFile" -> $tqFile|>;

SourceVaultTalkQAPacks[] := Module[{files},
  files = Quiet @ Check[Flatten[FileNames["*.wxf", #] & /@ iTQRoots[]], {}];
  Sort[DeleteDuplicates[FileBaseName /@ files]]];

iTQSave[pack_Association] := Quiet @ Check[
  Export[iTQPath[pack["PackId"]], pack, "WXF"], $Failed];

SourceVaultTalkQALoad[packId_String] := Module[{path, pack},
  path = iTQFind[packId];
  If[path === "",
    Return[iFail["PackNotFound", "その QA パックはありません。",
      <|"PackId" -> packId, "SearchedIn" -> iTQRoots[]|>]]];
  pack = Quiet @ Check[Import[path, "WXF"], $Failed];
  If[! AssociationQ[pack],
    Return[iFail["PackUnreadable", "QA パックを読めませんでした。", <|"PackId" -> packId|>]]];
  $tqLoaded[packId] = pack;
  SourceVault`$SourceVaultTalkQADefaultPack = packId;
  <|"Status" -> "OK", "PackId" -> packId, "Slides" -> Length[Lookup[pack, "Slides", <||>]],
    "Questions" -> Length[Lookup[pack, "Entries", {}]]|>];

(* デッキ (.nb) に対応するパックを選ぶ。発表が変われば資料も変わるので、
   一覧の先頭を黙って使うより、開いているデッキで決めるほうが安全 *)
(* 日本語のファイル名は合成済み (NFC) と分解 (NFD) が混ざる。
   見た目が同じでも文字列としては一致しないので、正規化してから比べる *)
iTQNameKey[s_] := ToLowerCase[StringDelete[
  Quiet @ Check[CharacterNormalize[iStr[s], "NFC"], iStr[s]],
  WhitespaceCharacter]];

(* 最後の砦: 同じファイルを指しているか *)
iTQSameFileQ[a_, b_] := StringQ[a] && StringQ[b] &&
  With[{fa = Quiet @ Check[AbsoluteFileName[a], $Failed],
        fb = Quiet @ Check[AbsoluteFileName[b], $Failed]},
    StringQ[fa] && fa === fb];

iTQDeckMatchQ[p_, base_String, deck_String] := Module[{dp},
  If[! AssociationQ[p], Return[False]];
  dp = iStr[Lookup[p, "DeckPath", ""]];
  iTQNameKey[Lookup[p, "SourceId", ""]] === base ||
    iTQNameKey[FileBaseName[dp]] === base ||
    iTQSameFileQ[dp, deck]];

(* 同じデッキに複数のパックが残ることがある (パック id を変えて作り直したとき)。
   新しいほうを使う。古い発表の作り置きで答えるのが一番わかりにくい事故なので、
   一覧の先頭 (アルファベット順) に任せない。
   BuiltAtUTC は秒単位で、同じ秒に 2 つ書くと並びが決まらない。書き込み時刻を
   主鍵にする (どちらが後に書かれたかが、まさに知りたいこと) *)
iTQPackWrittenAt[packId_String] := Module[{p, path},
  p = iTQPeek[packId];
  If[AssociationQ[p] && NumericQ[Lookup[p, "SavedAt", None]],
    Return[N[Lookup[p, "SavedAt"]]]];
  (* SavedAt を持たない古いパック。ファイルの日付で近似する (秒単位) *)
  path = iTQFind[packId];
  If[path === "", Return[0.]];
  With[{d = Quiet @ Check[AbsoluteTime[FileDate[path]], 0.]},
    If[NumericQ[d], N[d], 0.]]];

iTQPacksForDeck[deck_String] := Module[{base, hits},
  base = iTQNameKey[FileBaseName[deck]];
  hits = Select[SourceVaultTalkQAPacks[], iTQDeckMatchQ[iTQPeek[#], base, deck] &];
  Reverse[SortBy[hits,
    {iTQPackWrittenAt[#], iStr[Lookup[iTQPeek[#], "BuiltAtUTC", ""]]} &]]];

SourceVaultTalkQASelectForDeck[deck_String] := Module[{hits, hit},
  hits = iTQPacksForDeck[deck];
  hit = If[hits === {}, None, First[hits]];
  If[hit === None,
    Return[iFail["NoPackForDeck", "このデッキの QA パックはまだありません。",
      <|"Deck" -> deck, "Packs" -> SourceVaultTalkQAPacks[],
        "SearchedIn" -> iTQRoots[],
        "Decks" -> (iStr[Lookup[iTQPeek[#], "DeckPath", ""]] & /@
           SourceVaultTalkQAPacks[])|>]]];
  SourceVaultTalkQALoad[hit]];

SourceVaultTalkQASelectForDeck[nb_NotebookObject] :=
  With[{f = Quiet[NotebookFileName[nb]]},
    If[StringQ[f], SourceVaultTalkQASelectForDeck[f],
      iFail["NoDeckPath", "ノートブックが保存されていません。"]]];

(* パックの見出しだけ見る (中身は必要になってから) *)
iTQPeek[packId_String] := Module[{path},
  If[KeyExistsQ[$tqLoaded, packId], Return[$tqLoaded[packId]]];
  If[KeyExistsQ[$tqPeeked, packId], Return[$tqPeeked[packId]]];
  path = iTQFind[packId];
  If[path === "", Return[Missing["NoPack"]]];
  $tqPeeked[packId] = Quiet @ Check[
    KeyTake[Import[path, "WXF"],
      {"PackId", "SourceId", "DeckPath", "BuiltAtUTC", "KBId", "Origin", "SavedAt"}],
    Missing["Unreadable"]]];

SourceVaultTalkQAUnload[packId_String] := ($tqLoaded = KeyDrop[$tqLoaded, packId];
  <|"Status" -> "OK", "PackId" -> packId|>);

iTQPackId[Automatic] := SourceVault`$SourceVaultTalkQADefaultPack;
iTQPackId[s_String] := s;
iTQPackId[_] := SourceVault`$SourceVaultTalkQADefaultPack;

iTQEnsure[packIdIn_] := Module[{packId = iTQPackId[packIdIn], r},
  If[! StringQ[packId] || packId === "",
    With[{all = SourceVaultTalkQAPacks[]},
      If[all === {}, Return[iFail["NoPack", "QA パックがまだありません (SourceVaultTalkQABuild で作ります)。"]]];
      packId = First[all]]];
  If[KeyExistsQ[$tqLoaded, packId], Return[$tqLoaded[packId]]];
  r = SourceVaultTalkQALoad[packId];
  If[FailureQ[r], Return[r]];
  $tqLoaded[packId]];

(* ---- 正規化と鍵 ---- *)

(* SourceVault の中核が読まれていないカーネルだと、この関数は未定義のまま
   返る (メッセージが出ないので Check も拾わない)。そのまま進むと
   鍵 (Keys/QNorm) に式が焼き込まれ、パックは作れるのに一問も当たらない。
   文字列が戻らなければ落とす *)
iTQNorm[s_String] := With[{r = Quiet @ Check[
    SourceVault`SourceVaultNormalizeSearchText[s], $Failed]},
  If[StringQ[r], r, ToLowerCase[StringTrim[s]]]];
iTQNorm[x_] := iTQNorm[iStr[x]];

(* 質問の当たり判定に使う鍵。日本語は空白で切れないので 2-gram も使うが、
   ひらがなだけの 2-gram (「とは」「につ」「して」…) は助詞で、何にでも当たる。
   これを鍵に含めると「東京の明日の天気は」が「可逆計算とは」に当たってしまう
   (実測 2026-08-22)。内容語だけを鍵にする *)
iTQContentKeyQ[k_String] :=
  StringLength[k] >= 3 ||
    ! StringMatchQ[k, RegularExpression["[\\x{3040}-\\x{309F}]+"]];

iTQKeys[s_String] := Module[{n, toks},
  n = iTQNorm[s];
  toks = Select[StringSplit[n, Except[WordCharacter] ..], StringLength[#] >= 2 &];
  toks = Join[toks,
    Select[StringPartition[StringDelete[n, WhitespaceCharacter], 2, 1],
      StringLength[#] === 2 &]];
  DeleteDuplicates[Select[toks, iTQContentKeyQ]]];

(* ---- プライバシー ---- *)

(* 覚えている番号より、いま出ているページを優先する。
   発表者が手で送ったときに、前のページの文脈で答えないため *)
iTQLiveSlide[] := Module[{n},
  If[Length[DownValues[SlideWorkflow`SlideCurrentNumber]] === 0,
    Return[SourceVault`$SourceVaultTalkQASlide]];
  n = Quiet @ Check[SlideWorkflow`SlideCurrentNumber[], Missing[]];
  If[IntegerQ[n] && n > 0,
    SourceVault`$SourceVaultTalkQASlide = n; n,
    SourceVault`$SourceVaultTalkQASlide]];

iTQMode[Automatic] := SourceVault`$SourceVaultTalkQAMode;
iTQMode[s_String] := s;
iTQMode[_] := SourceVault`$SourceVaultTalkQAMode;

iTQPublicMax[] := iNum[SourceVault`$SourceVaultTalkQAPublicMax, 0.35];

(* PL とモードから経路を決める。ここだけが判断の場所 *)
iTQRoute[pl_, mode_String] := Which[
  iNum[pl, 1.] <= iTQPublicMax[], "Public",
  mode === "Private", "Local",
  True, "Deny"];

$tqWebDownText =
  "\:30a6\:30a7\:30d6\:691c\:7d22\:306e\:30b5\:30fc\:30d3\:30b9 (SourceVault \:306e MCP) \:304c\:6b62\:307e\:3063\:3066\:3044\:308b\:306e\:3067\:3001\:3044\:307e\:306f\:8abf\:3079\:3089\:308c\:307e\:305b\:3093\:3002";
$tqNoMaterialWebDownText =
  "\:624b\:5143\:306e\:8cc7\:6599\:306b\:306f\:3042\:308a\:307e\:305b\:3093\:3002\:30a6\:30a7\:30d6\:691c\:7d22\:306e\:30b5\:30fc\:30d3\:30b9 (SourceVault \:306e MCP) \:304c\:6b62\:307e\:3063\:3066\:3044\:308b\:306e\:3067\:3001\:8abf\:3079\:308b\:3053\:3068\:3082\:3067\:304d\:307e\:305b\:3093\:3002";

$tqBlockedText = "その質問は非公開の資料が必要なので、この場ではお答えできません。";
$tqNotFoundText = "手元の資料には見当たりませんでした。";
$tqNeedWebText = "手元の資料では足りません。ウェブで調べてよければ、そう言ってください。";

(* ---- 想定質問の生成 ---- *)

$tqQuestionPrompt =
  "次はある発表スライド 1 枚の内容と、そのスライドで話す原稿です。\n" <>
  "聴衆から出そうな質問を `n` 個、日本語で作ってください。\n" <>
  "規則:\n" <>
  "- 1 行に 1 問。番号や記号を付けない。\n" <>
  "- スライドの内容に即した、具体的で短い質問にする。\n" <>
  "- 「このスライドについて教えて」のような漠然とした質問は作らない。\n" <>
  "- 質問文以外は何も出力しない。\n\n";

(* LLM の応答がエラー本文のことがある (CLI の認証切れなど)。素通しすると
   「Failed to authenticate: ...」が想定質問として焼き込まれる (実測 2026-08-22)。
   新しい LLM 経路を足すたびにこのゲートを通すこと *)
$tqErrorMarks = {"failed to authenticate", "oauth", "session expired",
  "[error]", "error:", "エラー:", "rate limit", "unauthorized", "forbidden",
  "not found", "timed out", "timeout", "usage limit", "insufficient",
  "invalid api key", "credit balance", "$failed", "missing["};

iTQLLMErrorQ[resp_] := ! StringQ[resp] ||
  StringLength[StringTrim[resp]] < 4 ||
  With[{low = ToLowerCase[StringTake[resp, UpTo[400]]]},
    AnyTrue[$tqErrorMarks, StringContainsQ[low, #] &]];

iTQParseQuestions[resp_, k_Integer] := Module[{lines},
  If[iTQLLMErrorQ[resp], Return[{}]];
  lines = StringTrim /@ StringSplit[StringReplace[resp, "\r\n" -> "\n"], "\n"];
  lines = StringTrim[StringReplace[#,
    StartOfString ~~ (DigitCharacter | "." | ")" | "-" | "*" | "・" | " ") .. -> ""]] & /@ lines;
  lines = Select[lines, StringLength[#] >= 6 && StringLength[#] <= 120 &];
  Take[DeleteDuplicates[lines], UpTo[k]]];

iTQPrompt[slideText_String, talkText_String, k_Integer] :=
  StringReplace[$tqQuestionPrompt, "`n`" -> ToString[k]] <>
    "=== スライド ===\n" <> StringTake[slideText, UpTo[1200]] <> "\n" <>
    If[StringTrim[talkText] === "", "",
      "=== 原稿 ===\n" <> StringTake[talkText, UpTo[1200]] <> "\n"];

(* 資料の PL に応じて経路を選ぶ。ClaudeQuerySync は PrivacyLevel < 0.5 なら
   クラウド (Claude Code CLI)、それ以上ならローカルモデルへ自動で振る。
   公開スライドをローカルの小さいモデルで作ると遅いし質も落ちるので、
   公開なら素直にクラウドを使う *)
iTQCloudQuestions[slideText_String, talkText_String, k_Integer, pl_] := Module[{resp},
  If[Length[DownValues[ClaudeCode`ClaudeQuerySync]] === 0, Return[{}]];
  resp = Quiet @ Check[
    ClaudeCode`ClaudeQuerySync[iTQPrompt[slideText, talkText, k],
      ClaudeCode`PrivacyLevel -> iNum[pl, 0.3], ClaudeCode`Timeout -> 150],
    Missing[]];
  iTQParseQuestions[resp, k]];

(* ローカル LLM (LM Studio) 直行。クラウドが無いときの受け皿 *)
iTQLocalQuestions[slideText_String, talkText_String, k_Integer] := Module[{resp},
  If[Length[DownValues[SourceVault`SourceVaultQueryLocalLLM]] === 0, Return[{}]];
  resp = Quiet @ Check[
    SourceVault`SourceVaultQueryLocalLLM[iTQPrompt[slideText, talkText, k], 90],
    Missing[]];
  iTQParseQuestions[resp, k]];

(* LLM が無いときの保険。見出しと頻出語から素直に作る *)
iTQFallbackQuestions[title_String, slideText_String, k_Integer] := Module[{terms, qs},
  terms = Select[
    DeleteDuplicates[StringCases[slideText,
      RegularExpression["[\\x{4E00}-\\x{9FFF}\\x{30A0}-\\x{30FF}A-Za-z0-9]{3,12}"]]],
    StringLength[#] >= 3 &];
  terms = Take[terms, UpTo[Max[0, k - 1]]];
  qs = Join[
    If[StringTrim[title] === "", {}, {title <> "について詳しく教えてください。"}],
    (# <> "とは何ですか。") & /@ terms];
  Take[DeleteDuplicates[qs], UpTo[k]]];

(* ノートブック自身の公開宣言。Public 宣言のあるものだけクラウドへ出す。
   宣言なし (Unspecified) と Private はローカル固定 (rules/61) *)
iTQDeckCloudOK[deck_String] := TrueQ[Quiet @ Check[
  NBAccess`NBGetCloudPublishable[deck] === True, False]];

iTQQuestionModel[Automatic, deck_String] :=
  If[iTQDeckCloudOK[deck], "Cloud", "Local"];
iTQQuestionModel[m_, _] := m;

iTQQuestionsFor[title_, slideText_, talkText_, k_, fn_, pl_ : 0.3] := Module[{qs},
  qs = Which[
    fn === "Local", iTQLocalQuestions[slideText, talkText, k],
    fn === "Cloud", iTQCloudQuestions[slideText, talkText, k, iNum[pl, 0.3]],
    fn === "None", {},
    fn === Automatic, With[{c = iTQCloudQuestions[slideText, talkText, k, iNum[pl, 0.3]]},
      If[c =!= {}, c, iTQLocalQuestions[slideText, talkText, k]]],
    True, Quiet @ Check[fn[slideText, talkText, k], {}]];
  If[! ListQ[qs] || qs === {}, qs = iTQFallbackQuestions[iStr[title], iStr[slideText], k]];
  Select[Flatten[{qs}], StringQ[#] && StringTrim[#] =!= "" &]];

(* ---- build ---- *)

(* デッキの PrivacyLevel: 数値が明示されればそれ、Automatic はノートブックの公開宣言
   (Public -> 0.0、それ以外 0.3)。KB 側 (iKBDeckPrivacy) と同じ規則 *)
iTQDeckPL[pl_?NumericQ, _] := N[Clip[pl, {0., 1.}]];
iTQDeckPL[_, deck_String] := If[iTQDeckCloudOK[deck], 0., 0.3];

Options[SourceVaultTalkQABuild] = {"PackId" -> Automatic, "KBId" -> Automatic,
  "PrivacyLevel" -> Automatic, "QuestionsPerSlide" -> 3, "Ingest" -> True,
  "Rebuild" -> Automatic, "QuestionFn" -> Automatic, "Slides" -> All,
  "QuestionModel" -> Automatic, "Verbose" -> True, "AnswerLimit" -> 3};

SourceVaultTalkQABuild[deck_String, OptionsPattern[]] := Module[
  {kbId, packId, verbose, ing, talkTexts, sourceId, slides, chosen,
   entries = {}, slideRecs = <||>, k, qfn, pack, t0, kbStatus, nQ = 0},
  t0 = AbsoluteTime[];
  verbose = TrueQ[OptionValue["Verbose"]];
  If[! FileExistsQ[deck],
    Return[iFail["DeckNotFound", "デッキが見つかりません。", <|"Deck" -> deck|>]]];
  kbId = Replace[OptionValue["KBId"], Automatic :> SourceVault`$SourceVaultKBDefaultId];
  sourceId = FileBaseName[deck];
  packId = Replace[OptionValue["PackId"], Automatic :> sourceId];
  k = OptionValue["QuestionsPerSlide"]; If[! IntegerQ[k] || k < 1, k = 3];
  qfn = OptionValue["QuestionFn"];
  (* どの LLM に本文を見せてよいかは、取り込みの PrivacyLevel ではなく
     ノートブックの公開宣言で決める (rules/61) *)
  If[qfn === Automatic,
    qfn = iTQQuestionModel[OptionValue["QuestionModel"], deck];
    If[verbose,
      Print["[talkqa] 想定質問の生成: " <> qfn <>
        If[qfn === "Local", " (\:516c\:958b\:5ba3\:8a00\:304c\:306a\:3044\:306e\:3067\:30ed\:30fc\:30ab\:30eb\:56fa\:5b9a)", ""]]]];

  (* 1) 原稿 (あれば)。取り込みより先に読む: 画像だけのスライドは本文が無く、
     中身は原稿にしかないので、原稿を chunk に入れないと見出ししか答えられない *)
  talkTexts = iTQTalkTexts[deck];
  If[verbose,
    Print["[talkqa] 原稿 " <> ToString[Length[talkTexts]] <> " 枚分" <>
      If[talkTexts === <||>, " (見つからない)", ""]]];

  (* 2) KB へ取り込む (未変更なら KB 側が飛ばす) *)
  If[TrueQ[OptionValue["Ingest"]],
    If[verbose, Print["[talkqa] KB へ取り込み: " <> sourceId]];
    ing = Quiet @ Check[SourceVault`SourceVaultKBIngestSlideDeck[kbId, deck,
      "SourceId" -> sourceId, "PrivacyLevel" -> OptionValue["PrivacyLevel"],
      "SlideNotes" -> talkTexts, "MaxSlideCharacters" -> 2500], $Failed];
    If[FailureQ[ing] || ing === $Failed,
      Return[iFail["IngestFailed", "KB への取り込みに失敗しました。", <|"Result" -> ing|>]]];
    If[OptionValue["Rebuild"] =!= False &&
        (OptionValue["Rebuild"] === True || Lookup[ing, "Status", ""] =!= "Unchanged"),
      If[verbose, Print["[talkqa] KB を再構築 (" <> $tqReleaseContext <> ")"]];
      Quiet @ Check[SourceVault`SourceVaultKBBuild[kbId,
        "ReleaseContext" -> $tqReleaseContext], $Failed]]];
  kbStatus = Quiet @ Check[SourceVault`SourceVaultKBStatus[kbId], <||>];

  (* 3) KB のスライド chunk を取り出す (本文と URI はここから) *)
  slides = iTQSlideChunks[kbId, sourceId];
  If[slides === {} || FailureQ[slides],
    Return[iFail["NoSlides", "KB にこのデッキのスライドがありません (取り込みを確認)。",
      <|"SourceId" -> sourceId, "KBId" -> kbId|>]]];
  chosen = OptionValue["Slides"];
  If[ListQ[chosen], slides = Select[slides, MemberQ[chosen, #["SlideIndex"]] &]];

  (* 4) スライドごとに 想定質問 -> 回答候補 *)
  Do[
    Module[{n, title, body, talkText, qs, links, recs = {}},
      n = sl["SlideIndex"]; title = iStr[sl["Title"]]; body = iStr[sl["Text"]];
      talkText = iStr[Lookup[talkTexts, n, ""]];
      If[verbose, Print["[talkqa] スライド " <> ToString[n] <> " " <> title]];
      qs = iTQQuestionsFor[title, body <> "\n" <> talkText, talkText, k, qfn,
        iNum[sl["PrivacyLevel"], iTQDeckPL[OptionValue["PrivacyLevel"], deck]]];
      Do[
        Module[{ans},
          ans = iTQAnswerFor[kbId, q, OptionValue["AnswerLimit"], sourceId];
          If[AssociationQ[ans],
            nQ++;
            AppendTo[recs, Join[<|"Slide" -> n, "Question" -> q,
              "Keys" -> iTQKeys[q], "QNorm" -> iTQNorm[q]|>, ans]]]],
        {q, qs}];
      links = DeleteDuplicates[Join[
        {iStr[sl["ObjectURI"]]},
        Flatten[Lookup[#, "CitationURIs", {}] & /@ recs]]];
      links = Select[links, StringQ[#] && StringStartsQ[#, "sv://"] &];
      slideRecs[n] = <|"Slide" -> n, "Title" -> title,
        "Terms" -> iTQProperTerms[title <> " " <> body <> " " <> talkText, 4],
        "SlideNodeId" -> iStr[sl["SlideNodeId"]],
        "ObjectURI" -> iStr[sl["ObjectURI"]],
        "PrivacyLevel" -> iNum[sl["PrivacyLevel"], 0.],
        "Links" -> links, "QuestionCount" -> Length[recs]|>;
      entries = Join[entries, recs]],
    {sl, slides}];

  pack = <|"ObjectClass" -> "SourceVaultTalkQAPack", "SchemaVersion" -> 1,
    "PackId" -> packId, "KBId" -> kbId, "DeckPath" -> deck, "SourceId" -> sourceId,
    "BuiltAtUTC" -> iUTC[], "SavedAt" -> AbsoluteTime[], "Version" -> $tqVersion,
    "Slides" -> slideRecs, "Entries" -> entries,
    "Index" -> iTQBuildIndex[entries],
    "PublicMax" -> iTQPublicMax[],
    "KBStatus" -> If[AssociationQ[kbStatus], KeyTake[kbStatus,
      {"Chunks", "Nodes", "Edges", "Sources", "BuiltAtUTC"}], <||>]|>;
  If[iTQSave[pack] === $Failed,
    Return[iFail["PackSaveFailed", "QA パックを保存できませんでした。", <|"PackId" -> packId|>]]];
  $tqLoaded[packId] = pack;
  SourceVault`$SourceVaultTalkQADefaultPack = packId;
  If[verbose,
    Print["[talkqa] 完了: " <> ToString[Length[slideRecs]] <> " 枚 / " <>
      ToString[nQ] <> " 問  (" <> ToString[Round[AbsoluteTime[] - t0]] <> " 秒)"]];
  <|"Status" -> "OK", "PackId" -> packId, "KBId" -> kbId,
    "Slides" -> Length[slideRecs], "Questions" -> nQ,
    "Public" -> Count[entries, e_ /; e["Route"] === "Public"],
    "NonPublic" -> Count[entries, e_ /; e["Route"] =!= "Public"],
    "ElapsedSeconds" -> Round[AbsoluteTime[] - t0, 0.1]|>];

(* 原稿 <deck>_talk.md を スライド番号 -> 読み上げ文 で返す。
   SlideWorkflow が読まれていない headless でも動くよう、自前の読み取りを用意する
   (実測 2026-08-22: wolframscript で黙って原稿なしのパックができていた) *)
iTQTalkPath[deck_String] := Module[{p},
  If[Length[DownValues[SlideWorkflow`SlideTalkFile]] === 0,
    Quiet @ Check[Needs["SlideWorkflow`"], Null]];
  p = If[Length[DownValues[SlideWorkflow`SlideTalkFile]] > 0,
    Quiet[SlideWorkflow`SlideTalkFile[deck]], ""];
  If[StringQ[p] && FileExistsQ[p], Return[p]];
  p = FileNameJoin[{DirectoryName[deck], FileBaseName[deck] <> "_talk.md"}];
  If[FileExistsQ[p], p, ""]];

(* "## 7 UCNC 2026 {seconds=25}" の次の本文を拾う *)
iTQTalkParse[md_String] := Module[{lines, cur = 0, acc = <||>, m},
  lines = StringSplit[md, {"\r\n", "\n", "\r"}];
  Do[
    m = StringCases[l, RegularExpression["^##\\s+(\\d+)\\s"] :> "$1"];
    If[m =!= {},
      cur = ToExpression[First[m]];
      If[! IntegerQ[cur], cur = 0],
      If[cur > 0 && ! StringStartsQ[StringTrim[l], "#"],
        acc[cur] = StringTrim[Lookup[acc, cur, ""] <> " " <> l]]],
    {l, lines}];
  Select[acc, StringLength[#] > 0 &]];

iTQTalkTexts[deck_String] := Module[{path, talk},
  path = iTQTalkPath[deck];
  If[path === "", Return[<||>]];
  If[Length[DownValues[SlideWorkflow`SlideTalkFromMarkdown]] > 0,
    talk = Quiet[SlideWorkflow`SlideTalkFromMarkdown[File[path]]];
    If[AssociationQ[talk] && Lookup[talk, "Slides", {}] =!= {},
      Return[Select[Association[Table[
        Lookup[sl, "Slide", 0] -> iStr[Lookup[sl, "Text", ""]],
        {sl, Select[Lookup[talk, "Slides", {}], AssociationQ]}]],
        StringLength[#] > 0 &]]]];
  Quiet @ Check[
    iTQTalkParse[Import[path, "Text", CharacterEncoding -> "UTF-8"]], <||>]];

(* KB から 1 デッキ分のスライド chunk を取り出す。KB の検索経路を通さず、
   その source に限定した空クエリ相当の引き方をする *)
iTQSlideChunks[kbId_String, sourceId_String] := Module[{res},
  res = Quiet @ Check[
    SourceVault`SourceVaultKBSearch[kbId, sourceId,
      "SourceId" -> sourceId, "Limit" -> 500, "RetrievalDepth" -> 500,
      "UseGraph" -> False, "MaxCharactersPerResult" -> 1500,
      "ReleaseContext" -> $tqReleaseContext], {}];
  If[! ListQ[res] || res === {}, Return[{}]];
  SortBy[Select[res, IntegerQ[Lookup[#, "SlideIndex", 0]] &], Lookup[#, "SlideIndex", 0] &]];

(* ============================================================
   セル由来の作り置き (SourceVaultTalkQAImport)

   SourceVaultTalkQABuild は「LLM に想定質問を作らせ、KB に答えを引かせる」。
   こちらは逆で、発表者がスライドに書いた質疑応答セルをそのまま焼き込む。
   人が書いた答えを LLM の言い換えで上書きしない (本番で読み上げるので、
   言い回しまで発表者のものであるべき)。

   KB への取り込みは残す。作り置きに無い質問が来たときの受け皿 (Ask の 2 段目)
   と、近傍表示 (Neighbors) が、デッキを KB が知らないと動かないため。
   ============================================================ *)

iTQImportCite[c_] := Which[
  AssociationQ[c], c,
  StringQ[c] && StringStartsQ[StringTrim[c], "sv://"],
    <|"Label" -> StringTrim[c], "SourceId" -> "", "SlideIndex" -> 0,
      "ObjectURI" -> StringTrim[c]|>,
  StringQ[c] && StringTrim[c] =!= "",
    <|"Label" -> StringTrim[c], "SourceId" -> "", "SlideIndex" -> 0,
      "ObjectURI" -> ""|>,
  True, Nothing];

(* 1 問を焼く。答えが空のものは焼かない = Ask が KB へ落ちる。
   空のまま入れると iTQLookup が当たってしまい、「資料に見当たりません」で
   打ち切られる (KB に答えがあっても届かない) *)
iTQImportEntry[kbId_String, sourceId_String, n_Integer, e_Association,
    slidePL_, enrich_] := Module[{q, a, pl, cites, uris, pub, ans},
  q = StringTrim[iStr[Lookup[e, "Question", ""]]];
  If[q === "", Return[Missing["NoQuestion"]]];
  a = StringTrim[iStr[Lookup[e, "Answer", ""]]];
  pl = iNum[Lookup[e, "PrivacyLevel", slidePL], iNum[slidePL, 0.3]];
  cites = DeleteCases[iTQImportCite /@ Flatten[{Lookup[e, "Citations", {}]}], Nothing];
  If[a === "" && TrueQ[enrich],
    ans = iTQAnswerFor[kbId, q, 3, sourceId];
    If[AssociationQ[ans],
      a = StringTrim[iStr[Lookup[ans, "FullAnswer", Lookup[ans, "AnswerText", ""]]]];
      If[cites === {}, cites = Select[Lookup[ans, "FullCitations", {}], AssociationQ]];
      pl = Max[pl, iNum[Lookup[ans, "PrivacyLevel", 0.], 0.]]]];
  If[a === "", Return[Missing["NoAnswer"]]];
  pub = pl <= iTQPublicMax[];
  uris = Select[iStr[Lookup[#, "ObjectURI", ""]] & /@ cites,
    StringQ[#] && StringStartsQ[#, "sv://"] &];
  <|"Slide" -> n, "Question" -> q, "Keys" -> iTQKeys[q], "QNorm" -> iTQNorm[q],
    "AnswerText" -> a,
    "PublicAnswer" -> If[pub, a, ""],
    "PublicCitations" -> If[pub, cites, {}],
    "PublicPrivacyLevel" -> If[pub, pl, 0.],
    "FullAnswer" -> a, "FullCitations" -> cites,
    "ContextText" -> "",
    "PrivacyLevel" -> pl,
    "Route" -> If[pub, "Public", "Deny"],
    "RoutePrivate" -> iTQRoute[pl, "Private"],
    "Citations" -> cites, "CitationURIs" -> uris,
    "Count" -> 1, "Origin" -> "Cells"|>];

Options[SourceVaultTalkQAImport] = {"PackId" -> Automatic, "KBId" -> Automatic,
  "SourceId" -> Automatic, "PrivacyLevel" -> Automatic, "Ingest" -> True,
  "Rebuild" -> Automatic, "Enrich" -> True, "Verbose" -> False};

SourceVaultTalkQAImport[deck_String, slidesIn_List, OptionsPattern[]] := Module[
  {kbId, packId, sourceId, deckPL, verbose, enrich, talkTexts, ing, chunks,
   chunkOf = <||>, entries = {}, slideRecs = <||>, pack, t0, dropped = 0,
   kbStatus = <||>, slides, prior},
  t0 = AbsoluteTime[];
  verbose = TrueQ[OptionValue["Verbose"]];
  enrich = TrueQ[OptionValue["Enrich"]];
  slides = Select[slidesIn, AssociationQ];
  If[slides === {},
    Return[iFail["NoSlides", "質疑応答セルがありません。", <|"Deck" -> deck|>]]];
  (* すでにこのデッキのパックがあるなら、その id と KB を引き継ぐ。
     別 id で作ると同じデッキに 2 つ残り、SelectForDeck が古いほうを掴む。
     KB も変わると、作り置きに無い質問の受け皿が別の索引を見にいく *)
  prior = If[StringQ[deck] && deck =!= "",
    With[{h = iTQPacksForDeck[deck]},
      If[h === {}, <||>, With[{p = iTQPeek[First[h]]}, If[AssociationQ[p], p, <||>]]]],
    <||>];
  sourceId = Replace[OptionValue["SourceId"], Automatic :>
    With[{sid = iStr[Lookup[prior, "SourceId", ""]]},
      If[sid =!= "", sid, FileBaseName[deck]]]];
  packId = Replace[OptionValue["PackId"], Automatic :>
    With[{pid = iStr[Lookup[prior, "PackId", ""]]},
      If[pid =!= "", pid, sourceId]]];
  kbId = Replace[OptionValue["KBId"], Automatic :>
    With[{k = iStr[Lookup[prior, "KBId", ""]]},
      If[k =!= "", k, SourceVault`$SourceVaultKBDefaultId]]];
  If[! StringQ[kbId] || kbId === "", kbId = "cn"];
  deckPL = iTQDeckPL[OptionValue["PrivacyLevel"], deck];

  talkTexts = Select[Association[Table[
    Lookup[s, "Slide", 0] -> iStr[Lookup[s, "Talk", ""]], {s, slides}]],
    StringQ[#] && StringTrim[#] =!= "" &];

  (* KB へ取り込む。失敗しても作り置きは作る (発表本番で「パックが無い」より、
     取りこぼしの受け皿が弱いほうが軽い) *)
  If[TrueQ[OptionValue["Ingest"]] && FileExistsQ[deck],
    If[verbose, Print["[talkqa] KB へ取り込み: " <> sourceId]];
    ing = Quiet @ Check[SourceVault`SourceVaultKBIngestSlideDeck[kbId, deck,
      "SourceId" -> sourceId, "PrivacyLevel" -> OptionValue["PrivacyLevel"],
      "SlideNotes" -> talkTexts, "MaxSlideCharacters" -> 2500], $Failed];
    If[AssociationQ[ing] && OptionValue["Rebuild"] =!= False &&
        (OptionValue["Rebuild"] === True || Lookup[ing, "Status", ""] =!= "Unchanged"),
      If[verbose, Print["[talkqa] KB を再構築 (" <> $tqReleaseContext <> ")"]];
      Quiet @ Check[SourceVault`SourceVaultKBBuild[kbId,
        "ReleaseContext" -> $tqReleaseContext], $Failed]];
    kbStatus = Quiet @ Check[SourceVault`SourceVaultKBStatus[kbId], <||>]];

  chunks = Quiet @ Check[iTQSlideChunks[kbId, sourceId], {}];
  If[ListQ[chunks],
    chunkOf = Association[Table[Lookup[c, "SlideIndex", 0] -> c, {c, chunks}]]];

  Do[
    Module[{n, ch, title, body, talk, slPL, recs, links},
      n = Lookup[s, "Slide", 0];
      If[IntegerQ[n] && n >= 1,
        ch = Lookup[chunkOf, n, <||>];
        If[! AssociationQ[ch], ch = <||>];
        title = iStr[Lookup[s, "Title", ""]];
        If[title === "", title = iStr[Lookup[ch, "Title", ""]]];
        body = iStr[Lookup[s, "Text", ""]];
        If[body === "", body = iStr[Lookup[ch, "Text", ""]]];
        talk = iStr[Lookup[s, "Talk", ""]];
        slPL = iNum[Lookup[s, "PrivacyLevel",
          iNum[Lookup[ch, "PrivacyLevel", deckPL], deckPL]], deckPL];
        recs = Table[iTQImportEntry[kbId, sourceId, n, e, slPL, enrich],
          {e, Select[Lookup[s, "Entries", {}], AssociationQ]}];
        dropped += Count[recs, _Missing];
        recs = Select[recs, AssociationQ];
        links = DeleteDuplicates[Select[Join[
          {iStr[Lookup[ch, "ObjectURI", ""]]},
          Flatten[Lookup[#, "CitationURIs", {}] & /@ recs]],
          StringQ[#] && StringStartsQ[#, "sv://"] &]];
        slideRecs[n] = <|"Slide" -> n, "Title" -> title,
          "Terms" -> iTQProperTerms[title <> " " <> body <> " " <> talk, 4],
          "SlideNodeId" -> iStr[Lookup[ch, "SlideNodeId", ""]],
          "ObjectURI" -> iStr[Lookup[ch, "ObjectURI", ""]],
          "PrivacyLevel" -> slPL,
          "Links" -> links, "QuestionCount" -> Length[recs]|>;
        entries = Join[entries, recs]]],
    {s, slides}];

  If[entries === {},
    Return[iFail["NoAnswers",
      "回答の書かれた想定質問がありません (Q: に対する A: を書いてください)。",
      <|"Deck" -> deck, "Dropped" -> dropped|>]]];

  pack = <|"ObjectClass" -> "SourceVaultTalkQAPack", "SchemaVersion" -> 1,
    "PackId" -> packId, "KBId" -> kbId, "DeckPath" -> deck, "SourceId" -> sourceId,
    "BuiltAtUTC" -> iUTC[], "SavedAt" -> AbsoluteTime[],
    "Version" -> $tqVersion, "Origin" -> "Cells",
    "Slides" -> slideRecs, "Entries" -> entries,
    "Index" -> iTQBuildIndex[entries],
    "PublicMax" -> iTQPublicMax[],
    "KBStatus" -> If[AssociationQ[kbStatus], KeyTake[kbStatus,
      {"Chunks", "Nodes", "Edges", "Sources", "BuiltAtUTC"}], <||>]|>;
  If[iTQSave[pack] === $Failed,
    Return[iFail["PackSaveFailed", "QA パックを保存できませんでした。",
      <|"PackId" -> packId|>]]];
  $tqLoaded[packId] = pack;
  $tqPeeked = KeyDrop[$tqPeeked, packId];
  SourceVault`$SourceVaultTalkQADefaultPack = packId;
  If[verbose,
    Print["[talkqa] セルから作成: " <> ToString[Length[slideRecs]] <> " 枚 / " <>
      ToString[Length[entries]] <> " 問"]];
  <|"Status" -> "OK", "PackId" -> packId, "KBId" -> kbId, "Origin" -> "Cells",
    "Slides" -> Length[slideRecs], "Questions" -> Length[entries],
    "Dropped" -> dropped,
    "Public" -> Count[entries, e_ /; Lookup[e, "Route", ""] === "Public"],
    "NonPublic" -> Count[entries, e_ /; Lookup[e, "Route", ""] =!= "Public"],
    "ElapsedSeconds" -> Round[AbsoluteTime[] - t0, 0.1]|>];

iTQCiteOf[results_List] := Map[Function[r,
  <|"Label" -> iStr[Lookup[r, "SourceTitle", ""]] <> " / スライド " <>
      ToString[Lookup[r, "SlideIndex", 0]] <>
      With[{t = iStr[Lookup[r, "Title", ""]]}, If[t === "", "", "「" <> t <> "」"]],
    "SourceId" -> iStr[Lookup[r, "SourceId", ""]],
    "SlideIndex" -> Lookup[r, "SlideIndex", 0],
    "ObjectURI" -> iStr[Lookup[r, "ObjectURI", ""]]|>], results];

iTQURIsOf[results_List] := Select[
  iStr[Lookup[#, "ObjectURI", ""]] & /@ results,
  StringQ[#] && StringStartsQ[#, "sv://"] &];

iTQMaxPL[results_List] :=
  If[results === {}, 0., Max[iNum[Lookup[#, "PrivacyLevel", 1.], 1.] & /@ results]];

(* 1 問への回答候補を KB から作る (LLM を使わない = 速い・確定的)。
   公開分だけの答えと、全部を使った答えを両方作って焼き込む。
   実行時にどちらを出すかはモードが決める *)
(* 発表の質問は、まずそのデッキで答える。ウェブから取り込んだ本文が KB に
   増えると、デッキの内容がそれに負けることがある (実測 2026-08-23) *)
iTQAnswerFor[kbId_String, question_String, limitIn_, srcIn_ : All] := Module[{r},
  If[StringQ[srcIn] && srcIn =!= "",
    r = iTQAnswerWith[kbId, question, limitIn, srcIn];
    If[AssociationQ[r], Return[r]]];
  iTQAnswerWith[kbId, question, limitIn, All]];

iTQAnswerWith[kbId_String, question_String, limitIn_, src_] := Module[
  {lim, ans, all, pub, pubText, fullText},
  lim = If[IntegerQ[limitIn] && limitIn > 0, limitIn, 3];
  ans = Quiet @ Check[SourceVault`SourceVaultKBAnswer[kbId, question, "Limit" -> lim,
    "SourceId" -> src, "ReleaseContext" -> $tqReleaseContext], $Failed];
  If[! AssociationQ[ans] || Lookup[ans, "Count", 0] === 0, Return[Missing["NoAnswer"]]];
  (* 弱いヒットを採ると、関係のない質問にもそれらしい嘘を返す。
     MCP の音声経路と同じ考え方で下限を置く *)
  If[iNum[Lookup[ans, "TopBM25", 0.], 0.] <
      iNum[SourceVault`$SourceVaultTalkQAMinScore, 2.0],
    Return[Missing["WeakMatch"]]];
  all = Select[Lookup[ans, "Results", {}], AssociationQ];
  If[all === {}, Return[Missing["NoAnswer"]]];
  (* BM25 は一般的な語 (「大学」など) で下限を超えることがある。
     組み立てた答えが質問の語をひとつも含まず、重なりも薄いなら、別の話 *)
  (* 判定は chunk 全体 (見出しを含む) で行う。事実は本文に、名前は見出しにある
     ことが多く、文だけを見ると正しい答えまで捨ててしまう (実測 2026-08-23) *)
  (* URL は中身ではない。出典行の "ivas-project" のような文字列で
     「この資料は IVAS を扱っている」と誤認した (実測 2026-08-23) *)
  With[{scope = StringDelete[StringRiffle[
      (iStr[Lookup[#, "Title", ""]] <> " " <> iStr[Lookup[#, "Text", ""]]) & /@ all, " "],
      RegularExpression["https?://\\S+"]],
     draft = iTQComposeAnswer[question, all, iStr[Lookup[ans, "AnswerText", ""]]]},
    If[! iTQMentionsQ[scope, question] && iTQCover[question, draft] < 0.15,
      Return[Missing["Unrelated"]]]];
  (* 公開でありさえすればよいのではなく、実際に関連していること。
     上位の得点から離れた公開 chunk で答えると、非公開が要る質問に
     無関係な公開文で答えてしまう (実測 2026-08-22) *)
  pub = With[{top = Max[iNum[Lookup[#, "Score", 0.], 0.] & /@ all]},
    Select[all,
      iNum[Lookup[#, "PrivacyLevel", 1.], 1.] <= iTQPublicMax[] &&
        iNum[Lookup[#, "Score", 0.], 0.] >= 0.5 top &]];
  pubText = If[pub === {}, "",
    iTQComposeAnswer[question, pub, iStr[Lookup[ans, "AnswerText", ""]]]];
  fullText = iTQComposeAnswer[question, all, iStr[Lookup[ans, "AnswerText", ""]]];
  <|"AnswerText" -> If[pubText =!= "", pubText, fullText],  (* 参照系の既定 *)
    "PublicAnswer" -> pubText,
    "PublicCitations" -> iTQCiteOf[pub],
    "PublicPrivacyLevel" -> iTQMaxPL[pub],
    "FullAnswer" -> fullText,
    "FullCitations" -> iTQCiteOf[all],
    "ContextText" -> StringTake[iStr[Lookup[ans, "ContextText", ""]], UpTo[1200]],
    "PrivacyLevel" -> iTQMaxPL[all],
    (* 発表モードでの経路: 公開分だけで答えられるか *)
    "Route" -> If[pubText =!= "", "Public", "Deny"],
    "RoutePrivate" -> iTQRoute[iTQMaxPL[all], "Private"],
    "Citations" -> iTQCiteOf[If[pub =!= {}, pub, all]],
    "CitationURIs" -> iTQURIsOf[all],
    "Count" -> Length[all]|>];

(* KB の AnswerText は「質問と最も重なる 1 文」で、見出し行が勝ちやすい
   (「フレドキンゲートとは」-> 見出し「フレドキンゲート」)。本文から 1〜2 文を
   選び直し、短すぎるときだけ KB の答えに戻す *)
iTQSentences[text_String] := Module[{lines, parts},
  lines = Select[StringTrim /@ StringSplit[text, "\n"], # =!= "" &];
  (* 区切りは文の側に残したいので後読みで割る *)
  parts = Flatten[StringSplit[#, RegularExpression["(?<=[。！？!?])"]] & /@ lines];
  Select[StringTrim /@ parts, StringLength[#] >= 8 &]];

iTQOverlap[a_String, b_String] := Module[{ga, gb},
  ga = DeleteDuplicates[StringPartition[StringDelete[iTQNorm[a], WhitespaceCharacter], 2, 1]];
  gb = DeleteDuplicates[StringPartition[StringDelete[iTQNorm[b], WhitespaceCharacter], 2, 1]];
  If[ga === {} || gb === {}, 0., N[Length[Intersection[ga, gb]]]/Length[ga]]];

(* 質問側だけの、ごく小さな言い換え表。辞書を持ち込むのではなく、
   発表の質疑で繰り返し出るものだけ (実測で足りなかった語) *)
$tqSynonyms = {
  "由来" -> "出どころ 語源 起源 始まり",
  "語源" -> "由来 出どころ",
  "会期" -> "日程 期間 開催",
  "開催地" -> "場所 会場",
  "値段" -> "価格 円 いくら",
  "学費" -> "授業料 円",
  "作った" -> "開発 考案 発表",
  "言い出した" -> "提唱 名付け 広めた 呼んだ"};

iTQExpand[q_String] := StringJoin[q,
  StringJoin[Table[
    If[StringContainsQ[q, First[r]], " " <> Last[r], ""], {r, $tqSynonyms}]]];

(* 内容語の 2-gram。ひらがなだけの並びは助詞・語尾なので落とす
   (「開かれますか」の「かれ」で一致してしまうため) *)
iTQContentGrams[s_String] := Select[
  DeleteDuplicates[StringPartition[StringDelete[iTQNorm[s], WhitespaceCharacter], 2, 1]],
  iTQContentKeyQ];

(* 質問に出てくる語 (英数字語・カタカナ語・漢字語)。2-gram と違って、
   短い頭字語が別の語の一部と偶然重なることがない *)
iTQKeyTokens[q_String] := Select[
  Flatten[StringCases[q, {
    RegularExpression["[A-Za-z][A-Za-z0-9]{2,}"],
    RegularExpression["[\\x{30A1}-\\x{30FA}\\x{30FC}]{3,}"],
    RegularExpression["[\\x{4E00}-\\x{9FFF}]{2,}"]}]],
  StringLength[#] >= 2 &];

(* 答えが質問の語をひとつも含まないなら、それは別の話をしている *)
iTQMentionsQ[text_String, question_String] := Module[{toks},
  toks = iTQKeyTokens[question];
  If[toks === {}, Return[True]];
  AnyTrue[toks, StringContainsQ[text, #, IgnoreCase -> True] &]];

(* 質問の内容語との重なり。両側を見る (片側だと、全部入りの一覧行が
   どの質問にも勝ってしまう)。助詞・語尾は落としてあるので、
   「開かれますか」のような文法的一致では当たらない *)
iTQCover[question_String, cand_String] := Module[{gq, gc, c, p, r},
  gq = iTQContentGrams[iTQExpand[question]];
  If[gq === {}, Return[iTQDice[question, cand]]];
  gc = iTQContentGrams[cand];
  If[gc === {}, Return[0.]];
  c = Length[Intersection[gq, gc]];
  If[c === 0, Return[0.]];
  r = N[c]/Length[gq];          (* 質問語をどれだけ含むか *)
  p = N[c]/Length[gc];          (* 余計なことが混ざっていないか *)
  5 p r/(4 p + r)];             (* F2: 再現率を重めに *)

(* 両側の長さを見る。内容語が無い質問のときだけ使う *)
iTQDice[a_String, b_String] := Module[{ga, gb, c},
  ga = DeleteDuplicates[StringPartition[StringDelete[iTQNorm[a], WhitespaceCharacter], 2, 1]];
  gb = DeleteDuplicates[StringPartition[StringDelete[iTQNorm[b], WhitespaceCharacter], 2, 1]];
  If[ga === {} || gb === {}, Return[0.]];
  c = Length[Intersection[ga, gb]];
  N[2 c]/(Length[ga] + Length[gb])];

iTQComposeAnswer[question_String, results_List, fallback_String] := Module[
  {text, sents, scored, idx, out, titles},
  If[results === {}, Return[fallback]];
  (* 上位 2 件から候補文を集める。1 件目が見出しだけのスライド (画像ページ) でも
     関連する説明に届くように。見出し行は質問語と最もよく重なるが事実を含まないので、
     候補から外す (実測: ASCAT の開催地を訊いて見出しが返った) *)
  titles = iTQNorm /@ Select[iStr[Lookup[#, "Title", ""]] & /@ results, # =!= "" &];
  sents = Flatten[iTQSentences[iStr[Lookup[#, "Text", ""]]] & /@ Take[results, UpTo[2]]];
  sents = With[{cand = Select[sents,
      ! MemberQ[titles, iTQNorm[#]] &&
        ! iTQUrlOnlyQ[#] &]},
    If[cand === {}, sents, cand]];
  text = iStr[Lookup[First[results], "Text", ""]];
  If[sents === {},
    Return[If[StringLength[fallback] >= 8, fallback, StringTake[text, UpTo[160]]]]];
  (* 見出し行は質問語との重なりが高く出るが、事実を含まない。短い候補は減点する *)
  scored = Table[
    iTQCover[question, sents[[i]]] *
        If[StringLength[sents[[i]]] < 16, 0.55, 1.] *
        iTQFillerPenalty[sents[[i]]] +
      (* 質問の語そのものを含む文を優先する。カタカナ表記と英字表記が
         混ざるデッキでは、2-gram だけだと言い換えた文が勝ってしまう *)
      If[iTQMentionsQ[sents[[i]], question], 0.25, 0.] +
      iTQAspectBonus[question, sents[[i]]] +
      (* 内容語が 1 つも重ならないとき (固有名詞が ASCII で、説明文が日本語など) の
         並び替え。全部 0 点で先頭の文が選ばれるのを避ける *)
      0.05 iTQDice[question, sents[[i]]],
    {i, Length[sents]}];
  idx = First[Ordering[scored, -1]];
  out = sents[[idx]];
  (* 1 文が短いときは次の文も足す (「〜です。」だけで終わらせない) *)
  If[StringLength[out] < 60 && idx < Length[sents],
    out = out <> sents[[idx + 1]]];
  If[StringLength[out] < 8, out = fallback];
  StringTake[StringTrim[out], UpTo[220]]];

iTQBuildIndex[entries_List] := Module[{idx = <||>},
  Do[
    Module[{e = entries[[i]]},
      Do[idx[key] = Append[Lookup[idx, key, {}], i], {key, Lookup[e, "Keys", {}]}]],
    {i, Length[entries]}];
  idx];

(* ---- 問い合わせ ---- *)

Options[SourceVaultTalkQAAsk] = {"PackId" -> Automatic, "Slide" -> Automatic,
  "Mode" -> Automatic, "AllowWeb" -> False, "MinScore" -> 0.5, "KBId" -> Automatic};

SourceVaultTalkQAAsk[question_String, OptionsPattern[]] := Module[
  {pack, mode, slide, t0, hit, ans, kbId, route, pl, elapsed},
  t0 = AbsoluteTime[];
  mode = iTQMode[OptionValue["Mode"]];
  pack = iTQEnsure[OptionValue["PackId"]];
  slide = Replace[OptionValue["Slide"], Automatic :> iTQLiveSlide[]];
  If[! IntegerQ[slide], slide = 0];

  (* 1) 作り置きを引く *)
  If[AssociationQ[pack],
    hit = iTQLookup[pack, question, slide, iNum[OptionValue["MinScore"], 0.5]];
    If[AssociationQ[hit],
      elapsed = Round[(AbsoluteTime[] - t0) * 1000.];
      Return[iTQResult[hit, mode, "Pack", slide, elapsed]]]];

  (* 2) KB を引く *)
  kbId = Replace[OptionValue["KBId"], Automatic :>
    If[AssociationQ[pack], Lookup[pack, "KBId", SourceVault`$SourceVaultKBDefaultId],
      SourceVault`$SourceVaultKBDefaultId]];
  ans = iTQAnswerFor[kbId, question, 3,
    If[AssociationQ[pack], iStr[Lookup[pack, "SourceId", ""]], ""]];
  If[AssociationQ[ans],
    elapsed = Round[(AbsoluteTime[] - t0) * 1000.];
    Return[iTQResult[ans, mode, "KB", slide, elapsed]]];

  (* 3) 足りない *)
  elapsed = Round[(AbsoluteTime[] - t0) * 1000.];
  If[TrueQ[OptionValue["AllowWeb"]],
    Return[SourceVaultTalkQAWebAnswer[question, "PackId" -> OptionValue["PackId"],
      "Slide" -> slide]]];
  If[! iTQWebHealthyQ[],
    (* 調べられないのに承諾を求めない。「資料に無い」で終わらせるのも誤解を招く *)
    Return[<|"Status" -> "Unavailable", "Route" -> "Public", "AnswerText" -> "",
      "SpeakText" -> $tqNoMaterialWebDownText, "Citations" -> {}, "Slide" -> slide,
      "Source" -> "None", "WebAvailable" -> False, "PrivacyLevel" -> 0.,
      "ElapsedMs" -> Round[(AbsoluteTime[] - t0) * 1000.]|>]];
  <|"Status" -> "NeedWeb", "Route" -> "Public", "AnswerText" -> "",
    "SpeakText" -> $tqNeedWebText, "Citations" -> {}, "Slide" -> slide,
    "Source" -> "None", "WebAvailable" -> True,
    "PrivacyLevel" -> 0., "ElapsedMs" -> elapsed|>];

(* モードで「公開分だけの答え」と「全部の答え」を選ぶ。
   発表モードで公開分が無い = tsukuyomi が要る質問 -> 答えない *)
iTQResult[hit_Association, mode_String, source_String, slide_, elapsed_] := Module[
  {text, route, cites, pl},
  If[mode === "Private",
    text = iStr[Lookup[hit, "FullAnswer", Lookup[hit, "AnswerText", ""]]];
    pl = iNum[Lookup[hit, "PrivacyLevel", 0.], 0.];
    route = iTQRoute[pl, "Private"];
    cites = Lookup[hit, "FullCitations", Lookup[hit, "Citations", {}]],
    text = iStr[Lookup[hit, "PublicAnswer", ""]];
    pl = iNum[Lookup[hit, "PublicPrivacyLevel", 0.], 0.];
    route = If[StringTrim[text] === "", "Deny", "Public"];
    cites = Lookup[hit, "PublicCitations", {}]];
  Which[
    route === "Deny",
      <|"Status" -> "Blocked", "Route" -> "Deny", "AnswerText" -> "",
        "SpeakText" -> $tqBlockedText, "Citations" -> {},
        "Slide" -> slide, "Source" -> source,
        "PrivacyLevel" -> iNum[Lookup[hit, "PrivacyLevel", 1.], 1.],
        "ElapsedMs" -> elapsed|>,
    StringTrim[text] === "",
      <|"Status" -> "NotFound", "Route" -> route, "AnswerText" -> "",
        "SpeakText" -> $tqNotFoundText, "Citations" -> {},
        "Slide" -> slide, "Source" -> source, "PrivacyLevel" -> 0.,
        "ElapsedMs" -> elapsed|>,
    True,
      <|"Status" -> "OK", "Route" -> route, "AnswerText" -> text,
        "SpeakText" -> text,
        "ContextText" -> iStr[Lookup[hit, "ContextText", ""]],
        "Citations" -> cites,
        "Slide" -> slide, "Source" -> source,
        "PrivacyLevel" -> pl,
        "Question" -> Lookup[hit, "Question", ""],
        "ElapsedMs" -> elapsed|>]];

(* 何を訊いているか (場所・日時・数・理由・方法・定義)。
   固有名詞が同じでも観点が違えば、作り置きの答えは使えない *)
$tqAspects = {
  "Where" -> {"どこ", "何処", "場所", "会場", "開催地", "どちら"},
  "When" -> {"いつ", "日程", "会期", "何日", "何月", "締切", "〆切", "期限", "日時"},
  "HowMany" -> {"いくつ", "何件", "何人", "何回", "何本", "どれくらい", "どれぐらい"},
  "Why" -> {"なぜ", "why", "理由", "どうして"},
  "How" -> {"どうやって", "どのように", "方法", "手順"},
  "Who" -> {"誰", "だれ", "どなた", "who"},
  "What" -> {"とは", "何ですか", "なんですか", "どういう", "どのような", "内容"}};

iTQAspect[q_String] := Module[{n = iTQNorm[q]},
  Select[Keys[$tqAspects],
    AnyTrue[Lookup[$tqAspects, #, {}], StringContainsQ[n, #] &] &]];

iTQAspectCompatibleQ[a_String, b_String] := Module[{x, y},
  x = iTQAspect[a]; y = iTQAspect[b];
  (* どちらかが判らないときは邪魔をしない *)
  If[x === {} || y === {}, Return[True]];
  Intersection[x, y] =!= {}];

(* 観点ごとの「答えらしさ」。場所を訊かれたら場所を含む文を選ぶ *)
$tqAspectCues = {
  "Where" -> {"場所", "会場", "大学", "研究所", "キャンパス", "センター", "市", "県",
    "italy", "india", "@", "開催地", "にて", "で開"},
  "When" -> {"日程", "会期", "年", "月", "日", "締切", "〆切", "期限", "から", "まで"},
  "HowMany" -> {"つ", "件", "回", "名", "人", "本", "全部で"},
  "Why" -> {"ため", "理由", "から", "ので", "という"},
  "How" -> {"によって", "方法", "手順", "する"},
  "Who" -> {"さん", "氏", "博士", "教授", "が作", "が提唱", "創業", "開発した", "考案"},
  "What" -> {"です", "である", "とは", "モデル", "こと"}};

(* 原稿には「〜を説明します」「見ていきましょう」のようなつなぎの文がある。
   事実を含まないので答えには使わない (実測 2026-08-22) *)
$tqFillerMarks = {"説明します", "紹介します", "見ていきま", "見ていく", "お話しします",
  "述べます", "触れておきます", "ご覧ください", "始めます", "続けます"};

iTQFillerPenalty[cand_String] :=
  If[AnyTrue[$tqFillerMarks, StringContainsQ[cand, #] &], 0.45, 1.];

iTQAspectBonus[question_String, cand_String] := Module[{as, cues, n},
  as = iTQAspect[question];
  If[as === {}, Return[0.]];
  cues = Flatten[Lookup[$tqAspectCues, as, {}]];
  n = ToLowerCase[cand];
  If[AnyTrue[cues, StringContainsQ[n, #] &], 0.15, 0.]];

(* 作り置きの中から一番近い質問を選ぶ。鍵の重なり + 同じスライドなら加点 *)
iTQLookup[pack_Association, question_String, slide_Integer, minScore_] := Module[
  {keys, idx, entries, counts, best, bestScore, bestMatched},
  entries = Lookup[pack, "Entries", {}];
  If[entries === {}, Return[Missing["NoEntries"]]];
  idx = Lookup[pack, "Index", <||>];
  keys = iTQKeys[question];
  If[keys === {}, Return[Missing["NoKeys"]]];
  counts = <||>;
  Do[
    Do[counts[i] = Lookup[counts, i, 0] + 1, {i, Lookup[idx, key, {}]}],
    {key, keys}];
  If[Length[counts] === 0, Return[Missing["NoHit"]]];
  best = Missing[]; bestScore = 0.; bestMatched = 0;
  KeyValueMap[Function[{i, c},
    Module[{e = entries[[i]], score},
      score = N[c] / Max[1, Length[keys]];
      (* 質問語の側から見た被覆も見る (短い質問が有利になりすぎないように) *)
      score = 0.5 score + 0.5 N[c] / Max[1, Length[Lookup[e, "Keys", {}]]];
      If[IntegerQ[slide] && slide > 0 && Lookup[e, "Slide", 0] === slide,
        score = score + 0.08];
      If[score > bestScore, bestScore = score; best = e; bestMatched = c]]],
    counts];
  If[! (AssociationQ[best] && bestScore >= minScore && bestMatched >= 2),
    Return[Missing["BelowThreshold"]]];
  (* 同じ固有名詞を含む別の質問に当たることがある。質問文そのものの
     内容語と、訊いている観点でも確かめ、離れていれば KB を引き直す
     (数十 ms で済む) *)
  If[iTQCover[question, iStr[Lookup[best, "Question", ""]]] <
      iNum[SourceVault`$SourceVaultTalkQAPackSimilarity, 0.3],
    Return[Missing["DifferentQuestion"]]];
  If[! iTQAspectCompatibleQ[question, iStr[Lookup[best, "Question", ""]]],
    Return[Missing["DifferentAspect"]]];
  best];

(* ---- 近傍 (開いているページの周り) ---- *)

Options[SourceVaultTalkQANeighbors] = {"PackId" -> Automatic, "Hops" -> 2,
  "Limit" -> 5, "Mode" -> Automatic};

SourceVaultTalkQANeighbors[slideIn : (_Integer | Automatic) : Automatic,
    OptionsPattern[]] := Module[{pack, slide, rec, res, mode},
  pack = iTQEnsure[OptionValue["PackId"]];
  If[! AssociationQ[pack], Return[pack]];
  mode = iTQMode[OptionValue["Mode"]];
  slide = Replace[slideIn, Automatic :> SourceVault`$SourceVaultTalkQASlide];
  rec = Lookup[Lookup[pack, "Slides", <||>], slide, Missing[]];
  If[! AssociationQ[rec],
    Return[iFail["SlideNotInPack", "そのスライドはパックにありません。", <|"Slide" -> slide|>]]];
  res = Quiet @ Check[SourceVault`SourceVaultKBNeighbors[Lookup[pack, "KBId", "cn"],
    rec["SlideNodeId"], "Hops" -> OptionValue["Hops"], "Limit" -> OptionValue["Limit"],
    "ReleaseContext" -> $tqReleaseContext], {}];
  If[! ListQ[res], Return[{}]];
  Map[Function[r,
    Module[{pl = iNum[Lookup[r, "PrivacyLevel", 1.], 1.], route},
      route = iTQRoute[pl, mode];
      <|"Slide" -> Lookup[r, "SlideIndex", 0],
        "Title" -> Lookup[r, "Title", ""],
        "SourceTitle" -> Lookup[r, "SourceTitle", ""],
        "Score" -> Round[iNum[Lookup[r, "Score", 0.], 0.], 0.001],
        "PrivacyLevel" -> pl, "Route" -> route,
        "Text" -> If[route === "Deny", "", iStr[Lookup[r, "Text", ""]]],
        "URI" -> iStr[Lookup[r, "ObjectURI", ""]]|>]],
    res]];

(* ---- web への逃がし ---- *)

Options[SourceVaultTalkQAWebAnswer] = {"PackId" -> Automatic, "KBId" -> Automatic,
  "Limit" -> 5, "Ingest" -> True, "Rebuild" -> True, "Slide" -> Automatic,
  "Verbose" -> False};

SourceVaultTalkQAWebAnswer[question_String, OptionsPattern[]] := Module[
  {pack, kbId, run, results, items, text, sourceId, ing, t0, slide, terms, query},
  t0 = AbsoluteTime[];
  If[Length[DownValues[SourceVault`SourceVaultWebSearch]] === 0,
    Return[<|"Status" -> "NotFound", "Route" -> "Public", "AnswerText" -> "",
      "SpeakText" -> "ウェブ検索の層が読み込まれていません。", "Citations" -> {},
      "Source" -> "Web", "PrivacyLevel" -> 0., "ElapsedMs" -> 0|>]];
  pack = iTQEnsure[OptionValue["PackId"]];
  kbId = Replace[OptionValue["KBId"], Automatic :>
    If[AssociationQ[pack], Lookup[pack, "KBId", SourceVault`$SourceVaultKBDefaultId],
      SourceVault`$SourceVaultKBDefaultId]];
  (* 頭字語は文脈がないと決まらない。いま開いているページの固有名詞を足して引く
     (実測 2026-08-23: Anduril のページで「IVAS とは」と訊いて別分野の IVAS が返った) *)
  slide = Replace[OptionValue["Slide"], Automatic :> iTQLiveSlide[]];
  terms = Select[iTQContextTerms[pack, slide],
    ! StringContainsQ[question, #, IgnoreCase -> True] &];
  query = StringTrim[question <> If[terms === {}, "", " " <> StringRiffle[terms, " "]]];
  run = Quiet @ Check[SourceVault`SourceVaultWebSearch[query], $Failed];
  (* 落ちているのか、見つからないのか。混ぜると「資料に記載がありません」と
     誤報してしまう *)
  If[run === $Failed || iTQWebServiceFailureQ[run],
    iTQNoteWebHealth[False];
    Return[<|"Status" -> "Unavailable", "Route" -> "Public", "AnswerText" -> "",
      "SpeakText" -> $tqWebDownText, "Citations" -> {}, "Source" -> "Web",
      "Reason" -> If[FailureQ[run], ToString[Quiet[run[[1]]]], "RequestFailed"],
      "PrivacyLevel" -> 0., "ElapsedMs" -> Round[(AbsoluteTime[] - t0) 1000.]|>]];
  iTQNoteWebHealth[True];
  results = If[AssociationQ[run], Lookup[run, "Results", Lookup[run, "results", {}]], {}];
  (* 絞りすぎたときは、元の質問だけでもう一度 *)
  If[terms =!= {} && (! ListQ[results] || Length[results] < 2),
    run = Quiet @ Check[SourceVault`SourceVaultWebSearch[question], $Failed];
    results = If[AssociationQ[run], Lookup[run, "Results", Lookup[run, "results", {}]], {}];
    query = question];
  If[! ListQ[results] || results === {},
    Return[<|"Status" -> "NotFound", "Route" -> "Public", "AnswerText" -> "",
      "SpeakText" -> "ウェブでも見つかりませんでした。", "Citations" -> {},
      "Source" -> "Web", "PrivacyLevel" -> 0.,
      "ElapsedMs" -> Round[(AbsoluteTime[] - t0) 1000.]|>]];
  results = Take[Select[results, AssociationQ], UpTo[
    If[IntegerQ[OptionValue["Limit"]], OptionValue["Limit"], 5]]];
  (* 提供元によって鍵の綴りが違う (SearXNG 経路は Url / Snippet)。
     取りこぼすと出典 URL が消える *)
  items = Map[Function[r,
    <|"Title" -> iTQFirstString[r, {"Title", "title"}],
      "URL" -> iTQFirstString[r, {"URL", "Url", "url", "Link", "link"}],
      "Text" -> iTQFirstString[r,
        {"Content", "content", "Text", "Snippet", "snippet", "Description"}]|>],
    results];
  items = Select[items, StringLength[StringTrim[#["Text"]]] > 20 &];
  If[items === {},
    Return[<|"Status" -> "NotFound", "Route" -> "Public", "AnswerText" -> "",
      "SpeakText" -> "ウェブの結果に本文がありませんでした。", "Citations" -> {},
      "Source" -> "Web", "PrivacyLevel" -> 0.,
      "ElapsedMs" -> Round[(AbsoluteTime[] - t0) 1000.]|>]];
  text = iTQWebSummary[question, items, terms];
  (* 次回から即答できるように KB へ入れる *)
  sourceId = "web-" <> StringTake[Hash[question, "SHA256", "HexString"], 10];
  If[TrueQ[OptionValue["Ingest"]] &&
      Length[DownValues[SourceVault`SourceVaultKBIngestTexts]] > 0,
    ing = Quiet @ Check[SourceVault`SourceVaultKBIngestTexts[kbId, sourceId, items,
      "Title" -> ("web: " <> StringTake[question, UpTo[40]]),
      "PrivacyLevel" -> 0.0, "Kind" -> "Web",
      "Tags" -> {"web", "talkqa"}], $Failed];
    If[TrueQ[OptionValue["Rebuild"]] && ! FailureQ[ing],
      Quiet @ Check[SourceVault`SourceVaultKBBuild[kbId,
        "ReleaseContext" -> $tqReleaseContext], $Failed]]];
  <|"Status" -> "OK", "Route" -> "Public", "AnswerText" -> text, "SpeakText" -> text,
    "Query" -> query,
    "Citations" -> (<|"Title" -> #["Title"], "URI" -> #["URL"]|> & /@ items),
    "Slide" -> SourceVault`$SourceVaultTalkQASlide, "Source" -> "Web",
    "PrivacyLevel" -> 0., "SourceId" -> sourceId,
    "ElapsedMs" -> Round[(AbsoluteTime[] - t0) 1000.]|>];

(* web の結果をまとめる。ローカル LLM があれば 2-3 文に、無ければ抜粋を並べる *)
(* スライドの固有名詞。頭字語の曖昧さを解くために使う。
   ASCII の大文字始まりの語と、長めのカタカナ語を拾う *)
iTQProperTerms[text_String, n_Integer : 4] := Module[{ascii, kana, all},
  ascii = StringCases[text,
    RegularExpression["[A-Z][A-Za-z0-9]{2,}(?: [A-Z][A-Za-z0-9]{2,})?"]];
  kana = StringCases[text,
    RegularExpression["[\\x{30A1}-\\x{30FA}\\x{30FC}]{4,}"]];
  all = DeleteDuplicates[StringTrim /@ Join[ascii, kana]];
  all = Select[all, StringLength[#] >= 3 &];
  (* よく出るものを優先 (見出しの語は本文にも出る) *)
  all = SortBy[all, -{StringCount[text, #], StringLength[#]} &];
  Take[all, UpTo[n]]];

(* 検索が使えるか。落ちているときに承諾を求めても叶わないので、先に確かめる。
   毎回 HTTP を叩かないよう、結果は少しの間覚えておく *)
If[! AssociationQ[$tqWebHealth], $tqWebHealth = <|"At" -> 0., "OK" -> True|>];

iTQWebServiceFailureQ[f_] := FailureQ[f] &&
  MemberQ[{"SearXNGTimeout", "SearXNGRequestFailed", "SearXNGHTTPError",
    "SearXNGJSONParseFailed"}, Quiet[f[[1]]]];

iTQNoteWebHealth[ok_] := ($tqWebHealth = <|"At" -> AbsoluteTime[], "OK" -> TrueQ[ok]|>; ok);

iTQWebHealthyQ[] := Module[{age, run},
  If[Length[DownValues[SourceVault`SourceVaultSearXNGSearch]] === 0, Return[False]];
  age = AbsoluteTime[] - iNum[Lookup[$tqWebHealth, "At", 0.], 0.];
  If[age < 60., Return[TrueQ[Lookup[$tqWebHealth, "OK", True]]]];
  run = TimeConstrained[
    Quiet @ Check[SourceVault`SourceVaultSearXNGSearch["ping",
      "MaxResults" -> 1, "TimeoutSeconds" -> 3], $Failed], 5, $TimedOut];
  iTQNoteWebHealth[AssociationQ[run]]];

iTQFirstString[r_Association, keys_List] := Module[{v},
  v = SelectFirst[Lookup[r, #, Missing[]] & /@ keys,
    StringQ[#] && StringTrim[#] =!= "" &, ""];
  iStr[v]];
iTQFirstString[_, _] := "";

(* URL の並びだけの行は答えにならない。1 本とは限らない *)
iTQUrlOnlyQ[t_String] := StringLength[StringTrim[
  StringDelete[t, RegularExpression["https?://\\S+"]]]] < 10;

(* LLM は頼まなくても JSON やコードフェンスで返すことがある。
   そのまま読み上げると「波括弧 answer コロン」と発話してしまう (実測 2026-08-23) *)
iTQPlainAnswer[respIn_] := Module[{r, j, a},
  If[! StringQ[respIn], Return[""]];
  r = StringTrim[respIn];
  r = StringReplace[r, {
    StartOfString ~~ "```" ~~ (WordCharacter ...) ~~ ("\r\n" | "\n") -> "",
    "```" ~~ EndOfString -> ""}];
  r = StringTrim[r];
  If[StringStartsQ[r, "{"] || StringStartsQ[r, "["],
    j = Quiet @ Check[
      ImportByteArray[StringToByteArray[r, "UTF-8"], "RawJSON"], $Failed];
    If[AssociationQ[j],
      a = SelectFirst[
        Lookup[j, #, Missing[]] & /@ {"answer", "Answer", "text", "content"},
        StringQ, ""];
      If[StringQ[a] && StringLength[StringTrim[a]] > 0, r = StringTrim[a]]]];
  StringTrim[StringReplace[r, {"\r\n" -> " ", "\n" -> " ", "  " -> " "}]]];

(* いま開いているページの語。すでに質問に入っているものは足さない *)
iTQContextTerms[pack_, slide_] := Module[{rec, terms},
  If[! AssociationQ[pack] || ! IntegerQ[slide] || slide <= 0, Return[{}]];
  rec = Lookup[Lookup[pack, "Slides", <||>], slide, <||>];
  If[! AssociationQ[rec], Return[{}]];
  terms = Flatten[{Lookup[rec, "Terms", {}], iTQCleanTitle[Lookup[rec, "Title", ""]]}];
  terms = DeleteDuplicates[Select[terms, StringQ[#] && StringLength[StringTrim[#]] >= 3 &]];
  Take[terms, UpTo[2]]];

(* 見出しの飾り (→ など) を落とす *)
iTQCleanTitle[t_] := StringTrim[StringReplace[iStr[t],
  {"\:2192" -> "", "->" -> "", "\:ff08" ~~ Except[")" | "\:ff09"] .. ~~ ("\:ff09" | ")") -> ""}]];

(* ウェブの結果は公開情報なので、クラウドで要約してよい。ローカルは 40 秒以上かかり、
   発表中の質疑には間に合わない (worker の ask タイムアウトは十数秒) *)
iTQWebSummary[question_String, items_List, terms_List : {}] := Module[{prompt, resp, out},
  prompt = "次のウェブ検索の結果だけを根拠に、質問へ日本語で 2〜3 文で答えてください。" <>
    "結果に無いことは書かないでください。前置きや見出しを付けず、答えの文だけを" <>
    "そのまま書いてください (JSON やコードブロックにしないこと)。\n\n" <>
    If[terms === {}, "",
      "この質問は「" <> StringRiffle[terms, "、"] <>
        "」を扱っているスライドを表示している場面で出たものです。" <>
        "略語はこの文脈で解釈してください。\n\n"] <>
    "質問: " <> question <> "\n\n" <>
    StringRiffle[Table[
      "- " <> it["Title"] <> ": " <> StringTake[it["Text"], UpTo[400]],
      {it, items}], "\n"];
  If[Length[DownValues[ClaudeCode`ClaudeQuerySync]] > 0,
    resp = Quiet @ Check[ClaudeCode`ClaudeQuerySync[prompt,
      ClaudeCode`PrivacyLevel -> 0.0, ClaudeCode`Timeout -> 25], Missing[]];
    out = iTQPlainAnswer[resp];
    If[StringLength[out] > 10 && ! iTQLLMErrorQ[out],
      Return[StringTake[out, UpTo[400]]]]];
  If[Length[DownValues[SourceVault`SourceVaultQueryLocalLLM]] > 0,
    resp = Quiet @ Check[SourceVault`SourceVaultQueryLocalLLM[prompt, 60], Missing[]];
    out = iTQPlainAnswer[resp];
    If[StringLength[out] > 10 && ! iTQLLMErrorQ[out],
      Return[StringTake[out, UpTo[400]]]]];
  (* LLM が駄目でも黙らない: 見つかった本文の頭を読む *)
  StringTake[StringRiffle[
    (#["Title"] <> ": " <> StringTake[#["Text"], UpTo[160]]) & /@ Take[items, UpTo[2]],
    " / "], UpTo[400]]];

(* ---- 参照系 ---- *)

SourceVaultTalkQAQuestions[slideIn : (_Integer | Automatic) : Automatic,
    packIdIn_ : Automatic] := Module[{pack, slide},
  pack = iTQEnsure[packIdIn];
  If[! AssociationQ[pack], Return[pack]];
  slide = Replace[slideIn, Automatic :> SourceVault`$SourceVaultTalkQASlide];
  Select[Lookup[pack, "Entries", {}], Lookup[#, "Slide", 0] === slide &]];

(* 1 枚分の記録 (見出し・固有名詞・リンク・想定質問数)。パレットの情報表示や
   検索語の組み立ての確認に使う *)
SourceVaultTalkQASlideInfo[slideIn : (_Integer | Automatic) : Automatic,
    packIdIn_ : Automatic] := Module[{pack, slide},
  pack = iTQEnsure[packIdIn];
  If[! AssociationQ[pack], Return[pack]];
  slide = Replace[slideIn, Automatic :> SourceVault`$SourceVaultTalkQASlide];
  Lookup[Lookup[pack, "Slides", <||>], slide, <||>]];

SourceVaultTalkQALinks[slideIn : (_Integer | Automatic) : Automatic,
    packIdIn_ : Automatic] := Module[{pack, slide, rec},
  pack = iTQEnsure[packIdIn];
  If[! AssociationQ[pack], Return[pack]];
  slide = Replace[slideIn, Automatic :> SourceVault`$SourceVaultTalkQASlide];
  rec = Lookup[Lookup[pack, "Slides", <||>], slide, <||>];
  Lookup[rec, "Links", {}]];

SourceVaultTalkQAStatus[packIdIn_ : Automatic] := Module[{pack, entries},
  pack = iTQEnsure[packIdIn];
  If[! AssociationQ[pack], Return[pack]];
  entries = Lookup[pack, "Entries", {}];
  <|"PackId" -> pack["PackId"], "KBId" -> Lookup[pack, "KBId", ""],
    "Deck" -> Lookup[pack, "DeckPath", ""],
    "BuiltAtUTC" -> Lookup[pack, "BuiltAtUTC", ""],
    "Slides" -> Length[Lookup[pack, "Slides", <||>]],
    "Questions" -> Length[entries],
    "Public" -> Count[entries, e_ /; Lookup[e, "Route", ""] === "Public"],
    "NonPublic" -> Count[entries, e_ /; Lookup[e, "Route", ""] =!= "Public"],
    "Links" -> Total[Length[Lookup[#, "Links", {}]] & /@ Values[Lookup[pack, "Slides", <||>]]],
    "Mode" -> SourceVault`$SourceVaultTalkQAMode,
    "PublicMax" -> iTQPublicMax[]|>];

SourceVaultTalkQAView[packIdIn_ : Automatic] := Module[{pack, entries},
  pack = iTQEnsure[packIdIn];
  If[! AssociationQ[pack], Return[pack]];
  entries = Lookup[pack, "Entries", {}];
  Dataset[Map[Function[e,
    <|"Slide" -> Lookup[e, "Slide", 0],
      "Question" -> Lookup[e, "Question", ""],
      "Answer" -> StringTake[iStr[Lookup[e, "AnswerText", ""]], UpTo[80]],
      "PL" -> Round[iNum[Lookup[e, "PrivacyLevel", 0.], 0.], 0.01],
      "Route" -> Lookup[e, "Route", ""],
      "Cites" -> Length[Lookup[e, "Citations", {}]]|>], entries]]];

(* パック -> 人が直せる形。Import の逆で、往復できることが大事 (LLM で作った
   作り置きをスライドのセルへ戻し、そこで直してから焼き直す) *)
SourceVaultTalkQAExport[packIdIn_ : Automatic] := Module[{pack},
  pack = iTQEnsure[packIdIn];
  If[! AssociationQ[pack], Return[pack]];
  Map[Function[e,
    <|"Slide" -> Lookup[e, "Slide", 0],
      "Question" -> iStr[Lookup[e, "Question", ""]],
      "Answer" -> iStr[Lookup[e, "FullAnswer", Lookup[e, "AnswerText", ""]]],
      "Citations" -> Select[
        Map[Function[c, With[{u = iStr[Lookup[c, "ObjectURI", ""]]},
            If[u =!= "", u, iStr[Lookup[c, "Label", ""]]]]],
          Select[Lookup[e, "FullCitations", Lookup[e, "Citations", {}]], AssociationQ]],
        StringQ[#] && StringTrim[#] =!= "" &],
      "PrivacyLevel" -> iNum[Lookup[e, "PrivacyLevel", 0.], 0.]|>],
    Select[Lookup[pack, "Entries", {}], AssociationQ]]];

SourceVaultTalkQASetSlide[n_Integer] := (SourceVault`$SourceVaultTalkQASlide = n);
SourceVaultTalkQASetSlide[_] := SourceVault`$SourceVaultTalkQASlide;

(* ---- 音声ブリッジからの入口 ---- *)

SourceVaultTalkQAHandler[req_Association] := Module[{q, allowWeb, slide, res},
  q = iStr[Lookup[req, "query", Lookup[req, "Query", ""]]];
  If[StringTrim[q] === "",
    Return[<|"status" -> "error", "message" -> "質問が空です。"|>]];
  allowWeb = TrueQ[Lookup[req, "allowWeb", Lookup[req, "AllowWeb", False]]];
  slide = Lookup[req, "slide", Lookup[req, "Slide", Automatic]];
  If[IntegerQ[slide] && slide > 0, SourceVaultTalkQASetSlide[slide]];
  res = SourceVaultTalkQAAsk[q, "AllowWeb" -> allowWeb];
  If[! AssociationQ[res],
    Return[<|"status" -> "error", "message" -> "回答を作れませんでした。"|>]];
  <|"status" -> ToLowerCase[iStr[res["Status"]]],
    "answer" -> iStr[res["SpeakText"]],
    "route" -> iStr[res["Route"]],
    "source" -> iStr[Lookup[res, "Source", ""]],
    (* 作り置きのどの問いに当たったか。音声側 (GPT-Live) が、答えが質問に
       合っているかを判断するのに使う (合っていなければ資料に頼らず答える) *)
    "matchedQuestion" -> iStr[Lookup[res, "Question", ""]],
    "slide" -> Lookup[res, "Slide", 0],
    "needWeb" -> (res["Status"] === "NeedWeb"),
    "serviceDown" -> (res["Status"] === "Unavailable"),
    "citations" -> Take[
      iStr[Lookup[#, "Label", Lookup[#, "Title", Lookup[#, "ObjectURI", ""]]]] & /@
        Select[Lookup[res, "Citations", {}], AssociationQ], UpTo[3]],
    "elapsedMs" -> Lookup[res, "ElapsedMs", 0]|>];

(* ---- 他の層への結線 ---- *)

(* 横断リンク: 他の資料からも「発表で使った資料」を辿れるようにする *)
iTQCrossLinkSearch[query_String, opts___] := Module[{pack, hits},
  pack = iTQEnsure[Automatic];
  If[! AssociationQ[pack], Return[{}]];
  hits = Select[Lookup[pack, "Entries", {}],
    Lookup[#, "Route", ""] === "Public" &&
      StringContainsQ[iTQNorm[Lookup[#, "Question", ""] <> " " <>
        iStr[Lookup[#, "AnswerText", ""]]], iTQNorm[query]] &];
  Map[Function[e,
    <|"Kind" -> "TalkQA", "Id" -> ToString[Lookup[e, "Slide", 0]],
      "URI" -> First[Lookup[e, "CitationURIs", {""}], ""],
      "Title" -> ("スライド " <> ToString[Lookup[e, "Slide", 0]] <> ": " <>
        iStr[Lookup[e, "Question", ""]]),
      "Snippet" -> StringTake[iStr[Lookup[e, "AnswerText", ""]], UpTo[160]],
      "Score" -> 0.6, "Provider" -> "talkqa"|>],
    Take[hits, UpTo[10]]]];

If[Length[DownValues[SourceVault`SourceVaultRegisterCrossLinkProvider]] > 0,
  Quiet @ Check[
    SourceVault`SourceVaultRegisterCrossLinkProvider["talkqa",
      <|"SearchFn" -> (iTQCrossLinkSearch[#1, ##2] &),
        "Description" -> "発表 QA パック (想定質問と回答候補)",
        "Kinds" -> {"TalkQA"}|>],
    Null]];

(* 音声ブリッジ: 問い合わせ tool の受け口を登録する *)
If[ValueQ[SourceVault`$SourceVaultRealtimeAskHandler] ||
    Length[Names["SourceVault`$SourceVaultRealtimeAskHandler"]] > 0,
  SourceVault`$SourceVaultRealtimeAskHandler = SourceVaultTalkQAHandler];

End[];

EndPackage[];
