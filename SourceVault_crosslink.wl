(* ::Package:: *)

(* SourceVault_crosslink.wl
   SourceVault ヘテロ DB 横断ハイパーテキスト層。

   univ 等の一般メール (mailbrowse) / OOPS メールアーカイブ (oopsseed) /
   Eagle・ingest 済みソース・PDF 索引 ($SourceVaultSummaryProviders) を横断して
   「内容的に近いもの」をリンクとして解決し (core)、クリックで各 DB の
   ネイティブビューへ遷移できるセルを出力する (View)。

   mining 層 (SourceVault_mining) の活用:
   - ランキング: 候補を RRF (provider 横断 rank 融合) で束ねた後、
     SourceVaultMiningRerank で TagAssertion / Authorship / ObjectSignals
     (importance) による boost を適用する (SourceVaultMinedSearch と同型)。
   - クリック学習: リンクを開くたびに SourceVaultMakeObjectInteraction
     (Owner/SearchClick) を event log へ記録し、ObjectSignals importance に
     還流する (次回以降のランキングに効く)。
   - anchor の topic ラベルは QueryTags として TagAssertion 照合に使う。
   - SourceVaultCrossLinkAssertTopics で anchor の topic を TopicTag
     (SourceKind=Mining) として明示的に vault へ委託できる (opt-in)。
   - topic anchor は topic graph (ObservedRelationGraph) の隣接 topic で
     クエリを拡張する。
   mining 未ロードでも全機能は劣化動作する (boost/記録なし・fail-soft)。

   設計原則 (core/View 分離):
   - SourceVaultCrossLinks (core) は連想リストを返す。
   - SourceVaultCrossLinksView がリンク付き Grid セルを出力し、表示件数も
     View 層で制限する。ボタンには小さな文字列 (kind/id/mbox/uri) のみ焼き込む。

   provider は registry ($SourceVaultCrossLinkProviders) で拡張できる
   (notebook DB 等を今後追加する場合は SourceVaultRegisterCrossLinkProvider)。

   コンテキスト注意: このファイルより後にロードされ得るパッケージのシンボル
   (eagle / mcp / mining / SourceVault.wl 本体の registry) は必ず SourceVault`
   完全修飾で参照する (裸参照は parse 時に private 孤児シンボルを作る罠)。

   依存 (すべて任意・呼び出し時に存在確認): SourceVault_mailbrowse,
   SourceVault_oopsseed, SourceVault.wl ($SourceVaultSummaryProviders),
   SourceVault_mining, SourceVault_core (event log), SourceVault_eagle。
   このファイルは UTF-8。Block[{$CharacterEncoding = "UTF-8"}, Get[...]] で読むこと。 *)

BeginPackage["SourceVault`"]

SourceVaultRegisterCrossLinkProvider::usage =
  "SourceVaultRegisterCrossLinkProvider[name, spec] は横断リンク provider を登録する。\n" <>
  "spec: <|\"SearchFn\" -> fn[query, opts], \"Description\", \"Kinds\"|>。fn は link row\n" <>
  "(<|Kind, Id, MBox, URI, Title, Snippet, Score, Provider|>) のリストを返すこと。";

$SourceVaultCrossLinkProviders::usage =
  "$SourceVaultCrossLinkProviders は横断リンク provider の registry (name -> spec)。";

SourceVaultCrossLinkAnchor::usage =
  "SourceVaultCrossLinkAnchor[anchor] は anchor 指定を検索プロファイル\n" <>
  "<|AnchorURI, Title, Topics, QueryText, Tokens, Author, ExcludeKeys|> に解決する (core)。\n" <>
  "anchor: 文字列 (自由クエリ) | <|\"Kind\" -> \"mail\"|\"mail-thread\"|\"topic\"|\"oops-mail\"|\n" <>
  "\"oops-thread\"|\"eagle\", \"Id\" -> ..., \"MBox\" -> ...|> | <|\"Text\" -> ...|>。";

SourceVaultCrossLinks::usage =
  "SourceVaultCrossLinks[anchor, opts] は anchor に内容的に近いオブジェクトを全 provider 横断で\n" <>
  "検索し、RRF 融合 + mining boost (TagAssertion/Authorship/ObjectSignals) 済みの link row\n" <>
  "リストを返す (core)。\n" <>
  "Options: \"Providers\" -> All, \"Limit\" -> 12, \"PerProviderLimit\" -> 8,\n" <>
  "  \"MiningBoost\" -> True, \"QueryTags\" -> Automatic (anchor の Topics), \"QueryAuthor\" -> None,\n" <>
  "  \"EventLimit\" -> 3000, \"ExcludeSelf\" -> True,\n" <>
  "  \"MinScore\" -> Automatic (BM25 provider の弱一致ノイズ除外。Automatic = Max[2.0, 0.4*最高スコア]。\n" <>
  "   数値で絶対下限、None で無効)。";

SourceVaultCrossLinksView::usage =
  "SourceVaultCrossLinksView[anchor, opts] は SourceVaultCrossLinks の結果をクリックで各 DB の\n" <>
  "ビューへ遷移できる Grid で表示する (View)。オプションは SourceVaultCrossLinks と同じ。";

SourceVaultCrossLinkOpen::usage =
  "SourceVaultCrossLinkOpen[kind, id, mbox, uri] は link row の対象をネイティブビューで開く (I/O)。\n" <>
  "oops-thread/oops-mail -> OOPS ビュー, mail-thread/mail/topic -> mailbrowse ビュー,\n" <>
  "eagle -> Eagle サマリー, その他 -> sv:// プロパティ / URL / ファイル。開くたびに\n" <>
  "mining ObjectInteraction (SearchClick) を記録する (mining 未ロード時は skip)。";

SourceVaultCrossLinkRecordInteraction::usage =
  "SourceVaultCrossLinkRecordInteraction[targetURI, interactionKind, queryRef] は mining の\n" <>
  "ObjectInteraction event を記録する (mining/core 未ロード時は Missing を返す fail-soft)。\n" <>
  "$SourceVaultCrossLinkAppendEventFn でテスト用に append 先を差し替え可。";

SourceVaultCrossLinkAssertTopics::usage =
  "SourceVaultCrossLinkAssertTopics[anchor, opts] は anchor の topic ラベルを TopicTag\n" <>
  "(SourceKind=Mining) として anchor URI に assert する (opt-in, I/O)。以後の mining boost /\n" <>
  "SourceVaultMinedSearch のタグ照合に効く。Options: \"Confidence\" -> 0.6, \"MaxTags\" -> 8,\n" <>
  "  \"CommitFn\" -> Automatic (テスト注入用)。";

$SourceVaultCrossLinkViewMaxRows::usage =
  "$SourceVaultCrossLinkViewMaxRows は CrossLinksView の表示上限行数 (既定 20)。";

$SourceVaultCrossLinkAppendEventFn::usage =
  "$SourceVaultCrossLinkAppendEventFn は interaction event の append 関数 override (既定 Automatic =\n" <>
  "SourceVaultAppendEvent)。テストで実 event dir への書込を避けるために差し替える。";

$SourceVaultCrossLinkKindNames::usage =
  "$SourceVaultCrossLinkKindNames は link row の Kind -> 表示名 (View 用) の Association。";

(* ---- registry / 設定は SourceVault` 直下 ---- *)
If[! AssociationQ[$SourceVaultCrossLinkProviders], $SourceVaultCrossLinkProviders = <||>];
If[! IntegerQ[$SourceVaultCrossLinkViewMaxRows], $SourceVaultCrossLinkViewMaxRows = 20];
If[! ValueQ[$SourceVaultCrossLinkAppendEventFn], $SourceVaultCrossLinkAppendEventFn = Automatic];
If[! AssociationQ[$SourceVaultCrossLinkKindNames],
  $SourceVaultCrossLinkKindNames = <|
    "oops-thread" -> "OOPSスレ", "oops-mail" -> "OOPSメール",
    "mail-thread" -> "メールスレ", "mail" -> "メール", "topic" -> "topic",
    "eagle" -> "Eagle", "source" -> "ソース", "pdfindex" -> "PDF索引",
    "arxiv" -> "arXiv", "web" -> "Web"|>];

SourceVaultRegisterCrossLinkProvider[name_String, spec_Association] := (
  $SourceVaultCrossLinkProviders[name] = spec; name);

Begin["`CrossLinkPrivate`"]

(* ================= 内部 helper ================= *)

iSVCLShort[s_, n_Integer] := StringTake[
  StringReplace[ToString[s], {"\n" -> " ", "\r" -> ""}], UpTo[n]];

iSVCLOpenDoc[expr_] := CreateDocument[ExpressionCell[expr, "Output"]];

(* 正規化キー (lexical 公開関数。未ロード時は小文字化 fallback) *)
iSVCLNormKey[s_String] := With[
  {n = Quiet @ Check[SourceVault`SourceVaultNormalizeSearchText[s], $Failed]},
  If[StringQ[n] && n =!= "", n, ToLowerCase[StringTrim[s]]]];

(* Re:/Fwd: 剥がし (ローカル実装。private helper には依存しない) *)
iSVCLNormTitle[t_String] := StringTrim @ StringReplace[t,
  StartOfString ~~ RegularExpression["(?i)((re|fw|fwd)(\\[[0-9]+\\])?[ \\t]*[:：][ \\t]*)+"] -> ""];

(* 汎用語 stoplist (mailstructure private の $svMSTopicStoplist を guarded 流用) *)
iSVCLStopKeys[] := With[{sl = SourceVault`MailStructPrivate`$svMSTopicStoplist},
  If[ListQ[sl], iSVCLNormKey /@ Select[sl, StringQ], {}]];

(* topic ラベル + タイトル語からクエリトークン列を作る *)
iSVCLTokens[topics_List, title_String] := Module[{stop, words, toks},
  stop = iSVCLStopKeys[];
  words = Select[
    StringSplit[title, RegularExpression[
      "[\\s,;:/()\\[\\]{}\"'。、．，・「」『』<>|]+"]],
    StringLength[#] >= 2 &];
  toks = DeleteDuplicates[Join[Select[topics, StringQ], words]];
  toks = Select[toks, ! MemberQ[stop, iSVCLNormKey[#]] &];
  If[toks === {} && StringTrim[title] =!= "", toks = {StringTrim[title]}];
  Take[toks, UpTo[6]]];

iSVCLProfile[uri_, title_, topics_List, tokens_List, author_, excl_List] := <|
  "AnchorURI" -> ToString[uri], "Title" -> ToString[title],
  "Topics" -> DeleteDuplicates[Select[topics, StringQ[#] && # =!= "" &]],
  "QueryText" -> iSVCLShort[StringRiffle[
    DeleteDuplicates[Select[Join[topics, {iSVCLNormTitle[ToString[title]]}],
      StringQ[#] && # =!= "" &]], " "], 300],
  "Tokens" -> tokens, "Author" -> author, "ExcludeKeys" -> excl|>;

(* ================= anchor 解決 ================= *)

SourceVault`SourceVaultCrossLinkAnchor[q_String] :=
  iSVCLProfile["", q, {}, iSVCLTokens[{}, q], None, {}];

SourceVault`SourceVaultCrossLinkAnchor[a_Association] := Module[
  {kind = ToString @ Lookup[a, "Kind", ""], id = ToString @ Lookup[a, "Id", ""],
   mbox = ToString @ Lookup[a, "MBox", ""]},
  Which[
    (* 既に解決済みプロファイル *)
    KeyExistsQ[a, "QueryText"] && KeyExistsQ[a, "Tokens"], a,
    KeyExistsQ[a, "Text"],
      With[{t = ToString @ Lookup[a, "Text", ""]},
        iSVCLProfile["", t, {}, iSVCLTokens[{}, t], None, {}]],
    kind === "mail", iSVCLAnchorMail[id, mbox],
    kind === "mail-thread", iSVCLAnchorMailThread[id, mbox],
    kind === "topic", iSVCLAnchorTopic[id, mbox],
    kind === "oops-mail", iSVCLAnchorOOPSMail[id],
    kind === "oops-thread", iSVCLAnchorOOPSThread[id],
    kind === "eagle", iSVCLAnchorEagle[id],
    True, Missing["UnknownAnchor", kind]]];

iSVCLAnchorMail[id_String, mbox_String] := Module[{m, topics, subj, sess, excl},
  m = Quiet @ Check[SourceVault`SourceVaultMailBrowseMail[id, "MBox" -> mbox],
    Missing["NoMail"]];
  If[! AssociationQ[m], Return[Missing["MailNotFound", id]]];
  topics = Lookup[m, "TopicLabels", {}];
  subj = Lookup[m, "Subject", ""];
  sess = Lookup[m, "Session", ""];
  excl = DeleteCases[{"mail:" <> Lookup[m, "MailRef", id],
    If[StringQ[sess], "mail-thread:" <> sess, Nothing]}, Nothing];
  iSVCLProfile[Lookup[m, "MailRef", id], subj, topics,
    iSVCLTokens[topics, iSVCLNormTitle[subj]], Lookup[m, "From", None], excl]];

iSVCLAnchorMailThread[id_String, mbox_String] := Module[{t, topics},
  t = Quiet @ Check[SourceVault`SourceVaultMailBrowseThread[id, "MBox" -> mbox],
    Missing["NoThread"]];
  If[! AssociationQ[t], Return[Missing["ThreadNotFound", id]]];
  topics = DeleteDuplicates @ Join[Lookup[t, "TopicLabels", {}], Lookup[t, "Topics", {}]];
  iSVCLProfile[id, Lookup[t, "Subject", ""], topics,
    iSVCLTokens[topics, iSVCLNormTitle[Lookup[t, "Subject", ""]]], None,
    {"mail-thread:" <> id}]];

(* topic anchor: topic graph の隣接 topic ラベルでクエリ拡張 (mining/graph 活用) *)
iSVCLAnchorTopic[id_String, mbox_String] := Module[{tm, rel, topics},
  tm = Quiet @ Check[SourceVault`SourceVaultMailBrowseTopicMails[id, "MBox" -> mbox],
    Missing["NoTopic"]];
  If[! AssociationQ[tm], Return[Missing["TopicNotFound", id]]];
  rel = Quiet @ Check[
    SourceVault`SourceVaultMailBrowseTopicRelated[tm["TopicRef"],
      "MBox" -> mbox, "Limit" -> 3], {}];
  topics = DeleteDuplicates @ Prepend[
    If[ListQ[rel], ToString @ Lookup[#, "Label", ""] & /@ rel, {}], tm["Label"]];
  iSVCLProfile[tm["TopicRef"], tm["Label"], topics,
    iSVCLTokens[topics, tm["Label"]], None, {"topic:" <> tm["TopicRef"]}]];

iSVCLAnchorOOPSMail[id_String] := Module[{st, c, mail, subj, topics, sess, excl},
  st = If[AssociationQ[SourceVault`$svOOPSState], SourceVault`$svOOPSState, <||>];
  If[! TrueQ[Lookup[st, "Loaded", False]], Return[Missing["OOPSNotLoaded"]]];
  c = Quiet @ Check[FromDigits[id], $Failed];
  If[! IntegerQ[c], Return[Missing["BadCounter", id]]];
  mail = SelectFirst[Lookup[st, "Mails", {}], Lookup[#, "Counter", -1] === c &, Missing[]];
  If[! AssociationQ[mail], Return[Missing["MailNotFound", id]]];
  subj = Lookup[mail, "Subject", ""];
  topics = Quiet @ Check[
    SourceVault`SourceVaultTopicEnrichment[
      SourceVault`SourceVaultStripOOPSMarkers[Lookup[mail, "Body", ""]],
      st["SurfaceIndex"], "RefLabel" -> st["RefLabel"],
      "IncludeRelated" -> False]["TopicLabels"], {}];
  If[! ListQ[topics], topics = {}];
  sess = SelectFirst[Lookup[st, "Sessions", {}],
    MemberQ[Lookup[#, "MailCounters", {}], c] &, Missing[]];
  excl = DeleteCases[{"oops-mail:" <> id,
    If[AssociationQ[sess], "oops-thread:" <> Lookup[sess, "MailSessionId", ""], Nothing]},
    Nothing];
  iSVCLProfile["sv://mail/" <> id, subj, Take[topics, UpTo[8]],
    iSVCLTokens[Take[topics, UpTo[8]], iSVCLNormTitle[subj]],
    Lookup[mail, "From", None], excl]];

iSVCLAnchorOOPSThread[id_String] := Module[{st, det, topics},
  st = If[AssociationQ[SourceVault`$svOOPSState], SourceVault`$svOOPSState, <||>];
  If[! TrueQ[Lookup[st, "Loaded", False]], Return[Missing["OOPSNotLoaded"]]];
  det = Quiet @ Check[SourceVault`SourceVaultOOPSThread[id], Missing["NoThread"]];
  If[! AssociationQ[det], Return[Missing["ThreadNotFound", id]]];
  topics = Take[Lookup[det, "TopicLabels", {}], UpTo[8]];
  iSVCLProfile[id, Lookup[det, "Subject", ""], topics,
    iSVCLTokens[topics, iSVCLNormTitle[Lookup[det, "Subject", ""]]], None,
    {"oops-thread:" <> id}]];

iSVCLAnchorEagle[id_String] := Module[{row},
  If[Length[DownValues[SourceVault`SourceVaultEagleSummaryRow]] === 0,
    Return[Missing["EagleUnavailable"]]];
  row = Quiet @ Check[SourceVault`SourceVaultEagleSummaryRow[id], Missing["NoRow"]];
  If[! AssociationQ[row], Return[Missing["EagleItemNotFound", id]]];
  Module[{tags = With[{t = Lookup[row, "Tags", {}]}, If[ListQ[t], t, {}]],
    title = ToString @ Lookup[row, "Title", ""]},
    iSVCLProfile[Lookup[row, "URI", "sv://object/eagle-" <> id], title, tags,
      iSVCLTokens[tags, title],
      With[{au = Lookup[row, "Authors", None]}, If[ListQ[au] && au =!= {}, First[au], None]],
      {"eagle:" <> id}]]];

(* ================= 組み込み provider ================= *)

(* 弱一致ノイズ除外 (mailbrowse SearchThreads と同規約):
   Automatic = Max[2.0, 0.4*最高スコア] 未満を落とす / 数値=絶対下限 / None・0=全件 *)
iSVCLMinScoreFilter[rowsIn_List, minScore_] := Module[{rows, top, minS},
  rows = Select[rowsIn, AssociationQ[#] && NumericQ[Lookup[#, "Score", None]] &];
  If[rows === {}, Return[{}]];
  top = Max[N @ Lookup[#, "Score", 0.] & /@ rows];
  minS = Which[
    minScore === None || minScore === 0 || minScore === 0., -Infinity,
    NumericQ[minScore], N[minScore],
    True, Max[2.0, 0.4*top]];
  Select[rows, Lookup[#, "Score", 0.] >= minS &]];

(* OOPS メールアーカイブ (session BM25)。未ロード時は空 (自動フルロードはしない)。 *)
iSVCLOOPSProvider[query_String, o_Association] := Module[{rows},
  If[Length[DownValues[SourceVault`SourceVaultOOPSSearchThreads]] === 0 ||
     ! AssociationQ[SourceVault`$svOOPSState] ||
     ! TrueQ[Lookup[SourceVault`$svOOPSState, "Loaded", False]],
    Return[{}]];
  rows = Quiet @ Check[Normal @ SourceVault`SourceVaultOOPSSearchThreads[query,
    "Limit" -> Lookup[o, "Limit", 8]], {}];
  If[! ListQ[rows], Return[{}]];
  rows = iSVCLMinScoreFilter[rows, Lookup[o, "MinScore", Automatic]];
  Map[Function[r, Module[{sid = ToString @ Lookup[r, "Session", ""]},
    <|"Kind" -> "oops-thread", "Id" -> sid, "MBox" -> "",
      "URI" -> If[StringStartsQ[sid, "svmailsession:"],
        "sv://mailsession/" <> StringDrop[sid, StringLength["svmailsession:"]], sid],
      "Title" -> ToString @ Lookup[r, "Subject", ""],
      "Snippet" -> ToString @ Lookup[r, "Snippet", ""],
      "Score" -> With[{s = Lookup[r, "Score", 0.]}, If[NumericQ[s], N[s], 0.]],
      "Provider" -> "oops"|>]], Select[rows, AssociationQ]]];

(* 汎用 mbox (mailbrowse)。ロード済みの全 mbox を横断。 *)
iSVCLMailBrowseProvider[query_String, o_Association] := Module[{mbs, lim},
  If[Length[DownValues[SourceVault`SourceVaultMailBrowseSearchThreads]] === 0 ||
     ! AssociationQ[SourceVault`$svMailBrowseState], Return[{}]];
  mbs = Select[Keys[SourceVault`$svMailBrowseState],
    TrueQ[Lookup[Lookup[SourceVault`$svMailBrowseState, #, <||>], "Loaded", False]] &];
  lim = Lookup[o, "Limit", 8];
  Join @@ Map[Function[mb, Map[Function[r,
    <|"Kind" -> "mail-thread", "Id" -> ToString @ Lookup[r, "Session", ""], "MBox" -> mb,
      "URI" -> ToString @ Lookup[r, "Session", ""],
      "Title" -> ToString @ Lookup[r, "Subject", ""],
      "Snippet" -> ToString @ Lookup[r, "Snippet", ""],
      "Score" -> With[{s = Lookup[r, "Score", 0.]}, If[NumericQ[s], N[s], 0.]],
      "Provider" -> "mailbrowse:" <> mb|>],
    Select[Quiet @ Check[SourceVault`SourceVaultMailBrowseSearchThreads[query,
        "MBox" -> mb, "Limit" -> lim,
        "MinScore" -> Lookup[o, "MinScore", Automatic]], {}], AssociationQ]]], mbs]];

(* サマリー横断 ($SourceVaultSummaryProviders: sources / eagle / pdfindex ...)。
   これらは部分一致検索なのでトークンごとに引き、複数トークン一致を加点する。 *)
iSVCLSummariesProvider[query_String, o_Association] := Module[
  {provs, toks, lim, all = {}},
  provs = If[AssociationQ[SourceVault`$SourceVaultSummaryProviders],
    SourceVault`$SourceVaultSummaryProviders, <||>];
  If[Length[provs] === 0, Return[{}]];
  toks = With[{t = Lookup[o, "Tokens", {}]}, If[ListQ[t], t, {}]];
  If[toks === {}, toks = Select[StringSplit[query], StringLength[#] >= 2 &]];
  toks = Take[DeleteDuplicates[toks], UpTo[4]];
  If[toks === {}, Return[{}]];
  lim = Lookup[o, "Limit", 8];
  Do[Module[{rows},
    rows = Join @@ Map[Function[fn, With[
      {r = Quiet @ Check[fn[tok, <|"FetchMetadata" -> False, "Kind" -> All|>], {}]},
      If[ListQ[r], Select[r, AssociationQ], {}]]], Values[provs]];
    all = Join[all, Map[Function[row, <|
      "Kind" -> ToString @ Lookup[row, "Kind", "source"],
      "Id" -> ToString @ Lookup[row, "Id", Lookup[row, "URI", ""]],
      "MBox" -> "",
      "URI" -> ToString @ Lookup[row, "URI", ""],
      "URL" -> ToString @ Lookup[row, "URL", ""],
      "File" -> ToString @ Lookup[row, "File", ""],
      "Title" -> ToString @ Lookup[row, "Title", ""],
      "Snippet" -> iSVCLShort[Lookup[row, "Summary", ""], 100],
      "PrivacyLevel" -> Lookup[row, "PrivacyLevel", Missing[]],
      "Score" -> 1., "Provider" -> "summaries", "MatchedToken" -> tok|>],
      Take[rows, UpTo[2 lim]]]]],
    {tok, toks}];
  all = Values @ GroupBy[all, (#["Kind"] <> ":" <> #["Id"]) &,
    Function[grp, Append[First[grp], <|"Score" -> N @ Length[grp],
      "MatchedTokens" -> DeleteDuplicates[
        ToString @ Lookup[#, "MatchedToken", ""] & /@ grp]|>]]];
  Take[ReverseSortBy[all, Lookup[#, "Score", 0.] &], UpTo[lim]]];

SourceVault`SourceVaultRegisterCrossLinkProvider["oops", <|
  "SearchFn" -> iSVCLOOPSProvider, "Kinds" -> {"oops-thread"},
  "Description" -> "OOPS メールアーカイブのスレッド (要 SourceVaultOOPSEnsureLoaded)"|>];
SourceVault`SourceVaultRegisterCrossLinkProvider["mailbrowse", <|
  "SearchFn" -> iSVCLMailBrowseProvider, "Kinds" -> {"mail-thread"},
  "Description" -> "汎用 mbox (univ 等) のメールスレッド (要 SourceVaultMailBrowseEnsureLoaded)"|>];
SourceVault`SourceVaultRegisterCrossLinkProvider["summaries", <|
  "SearchFn" -> iSVCLSummariesProvider, "Kinds" -> {"eagle", "source", "pdfindex"},
  "Description" -> "Eagle サマリー / ingest 済みソース / PDF 索引 ($SourceVaultSummaryProviders 横断)"|>];

(* ================= mining 統合 ================= *)

(* 各 row に MiningProjection (ObjectTags / Authorships / ObjectSignals) を後付けする。
   mining/core 未ロード時は Missing (呼び出し側で fallback)。 *)
iSVCLAttachMiningProjection[rows_List, eventLimit_Integer] := Module[
  {ev, tagsAll, authAll},
  If[Length[DownValues[SourceVault`SourceVaultReplayTagAssertions]] === 0 ||
     Length[DownValues[SourceVault`SourceVaultTransactionLog]] === 0 ||
     Length[DownValues[SourceVault`SourceVaultObjectTags]] === 0,
    Return[Missing["MiningUnavailable"]]];
  ev = Quiet @ Check[SourceVault`SourceVaultTransactionLog["Limit" -> eventLimit], {}];
  If[! ListQ[ev], ev = {}];
  tagsAll = Quiet @ Check[SourceVault`SourceVaultReplayTagAssertions[ev], {}];
  authAll = Lookup[#, "Assertion"] & /@
    Select[ev, Lookup[#, "EventClass"] === "AuthorshipObserved" &];
  Map[Function[r, Module[{ids, uri},
    ids = DeleteDuplicates @ Select[
      {ToString @ Lookup[r, "URI", ""], ToString @ Lookup[r, "Id", ""],
       ToString @ Lookup[r, "Key", ""]}, # =!= "" &];
    uri = SelectFirst[ids,
      (Quiet @ Check[SourceVault`SourceVaultObjectTags[tagsAll, #]["Tags"], {}] =!= {} ||
       Quiet @ Check[SourceVault`SourceVaultObjectAuthorships[authAll, #], {}] =!= {}) &,
      Missing["NoMatch"]];
    Append[r, "MiningProjection" -> If[StringQ[uri],
      <|"Tags" -> SourceVault`SourceVaultObjectTags[tagsAll, uri],
        "Authorships" -> SourceVault`SourceVaultObjectAuthorships[authAll, uri],
        "Signals" -> Quiet @ Check[
          SourceVault`SourceVaultReplayObjectSignals[ev, uri], <||>]|>,
      <|"Tags" -> SourceVault`SourceVaultObjectTags[{}, "sv://nomatch"],
        "Authorships" -> {}, "Signals" -> <||>|>]]]], rows]];

SourceVault`SourceVaultCrossLinkRecordInteraction[targetURI_String,
  interactionKind_String: "SearchClick", queryRef_: Missing["NoQuery"]] := Quiet @ Check[
  Module[{appendFn = SourceVault`$SourceVaultCrossLinkAppendEventFn},
    If[appendFn === Automatic,
      If[Length[DownValues[SourceVault`SourceVaultAppendEvent]] === 0,
        Return[Missing["NoEventStore"]]];
      appendFn = SourceVault`SourceVaultAppendEvent];
    If[Length[DownValues[SourceVault`SourceVaultMakeObjectInteraction]] === 0,
      Return[Missing["MiningUnavailable"]]];
    appendFn[SourceVault`SourceVaultObjectInteractionRecordedEvent[
      SourceVault`SourceVaultMakeObjectInteraction[targetURI, "Owner", interactionKind,
        "QueryRef" -> queryRef, "ContextRef" -> "crosslink"]]]],
  Missing["RecordFailed"]];

Options[SourceVault`SourceVaultCrossLinkAssertTopics] = {"Confidence" -> 0.6, "MaxTags" -> 8,
  "CommitFn" -> Automatic};
SourceVault`SourceVaultCrossLinkAssertTopics[anchor_, OptionsPattern[]] := Module[
  {prof, uri, tags, fn = OptionValue["CommitFn"], conf = OptionValue["Confidence"]},
  prof = SourceVault`SourceVaultCrossLinkAnchor[anchor];
  If[! AssociationQ[prof], Return[Missing["BadAnchor"]]];
  uri = Lookup[prof, "AnchorURI", ""];
  If[! StringQ[uri] || uri === "", Return[Missing["NoAnchorURI"]]];
  If[fn === Automatic,
    If[Length[DownValues[SourceVault`SourceVaultAssertTag]] === 0,
      Return[Missing["MiningUnavailable"]]];
    fn = Function[{u, tg}, SourceVault`SourceVaultAssertTag[u, tg,
      "SourceKind" -> "Mining", "TagClass" -> "TopicTag",
      "Confidence" -> conf, "SourceRef" -> "crosslink:anchor"]]];
  tags = Take[Lookup[prof, "Topics", {}], UpTo[OptionValue["MaxTags"]]];
  fn[uri, #] & /@ tags];

(* ================= core: 横断検索 ================= *)

Options[SourceVault`SourceVaultCrossLinks] = {"Providers" -> All, "Limit" -> 12,
  "PerProviderLimit" -> 8, "MiningBoost" -> True, "QueryTags" -> Automatic,
  "QueryAuthor" -> None, "EventLimit" -> 3000, "ExcludeSelf" -> True,
  "MinScore" -> Automatic};
SourceVault`SourceVaultCrossLinks[anchor_, OptionsPattern[]] := Module[
  {prof, provs, sel, o, byProv, scores = <||>, best = <||>, merged, qtags, withProj},
  prof = SourceVault`SourceVaultCrossLinkAnchor[anchor];
  If[! AssociationQ[prof], Return[{}]];
  If[Lookup[prof, "QueryText", ""] === "" && Lookup[prof, "Tokens", {}] === {},
    Return[{}]];
  provs = SourceVault`$SourceVaultCrossLinkProviders;
  sel = OptionValue["Providers"];
  If[sel =!= All && sel =!= Automatic,
    provs = KeyTake[provs, ToString /@ Flatten[{sel}]]];
  o = <|"Limit" -> OptionValue["PerProviderLimit"],
    "Query" -> prof["QueryText"], "Tokens" -> Lookup[prof, "Tokens", {}],
    "Topics" -> Lookup[prof, "Topics", {}], "MinScore" -> OptionValue["MinScore"]|>;
  byProv = Association @ KeyValueMap[Function[{name, spec},
    name -> Module[{r = Quiet @ Check[
        Lookup[spec, "SearchFn", Function[{q, oo}, {}]][prof["QueryText"], o], {}]},
      If[ListQ[r],
        Select[r, AssociationQ[#] && KeyExistsQ[#, "Kind"] && KeyExistsQ[#, "Id"] &],
        {}]]], provs];
  (* RRF 融合: provider 内の rank から 1/(60+rank) を合算 (native score は微小 tie-break) *)
  KeyValueMap[Function[{prov, rows},
    MapIndexed[Function[{r, i}, Module[
      {key = ToString @ Lookup[r, "Kind", ""] <> ":" <> ToString @ Lookup[r, "Id", ""]},
      scores[key] = Lookup[scores, key, 0.] + 1./(60. + i[[1]]) +
        0.001*Min[With[{s = Lookup[r, "Score", 0.]}, If[NumericQ[s], N[s], 0.]], 20.];
      If[! KeyExistsQ[best, key],
        best[key] = Append[r, "Key" -> key],
        best[key] = Append[best[key], "AlsoFoundBy" -> DeleteDuplicates @ Append[
          Lookup[best[key], "AlsoFoundBy", {Lookup[best[key], "Provider", ""]}],
          ToString @ Lookup[r, "Provider", prov]]]]]], rows]], byProv];
  merged = KeyValueMap[Function[{key, sc},
    Append[best[key], "Score" -> Round[sc, 0.00001]]], scores];
  (* 自分自身 (anchor) の除外 *)
  If[TrueQ[OptionValue["ExcludeSelf"]],
    Module[{excl = Lookup[prof, "ExcludeKeys", {}], auri = Lookup[prof, "AnchorURI", ""]},
      merged = Select[merged, Function[r,
        ! MemberQ[excl, Lookup[r, "Key", ""]] &&
        (auri === "" || Lookup[r, "URI", ""] =!= auri)]]]];
  (* mining boost (TagAssertion / Authorship / ObjectSignals)。未ロード時は RRF のまま *)
  qtags = OptionValue["QueryTags"] /. Automatic -> Lookup[prof, "Topics", {}];
  If[TrueQ[OptionValue["MiningBoost"]] &&
      Length[DownValues[SourceVault`SourceVaultMiningRerank]] > 0,
    withProj = iSVCLAttachMiningProjection[merged, OptionValue["EventLimit"]];
    If[ListQ[withProj],
      merged = SourceVault`SourceVaultMiningRerank[withProj,
        "QueryTags" -> qtags, "QueryAuthor" -> OptionValue["QueryAuthor"],
        "MaxBoost" -> 0.2],
      merged = ReverseSortBy[merged, Lookup[#, "Score", 0.] &]],
    merged = ReverseSortBy[merged, Lookup[#, "Score", 0.] &]];
  Take[merged, UpTo[OptionValue["Limit"]]]];

(* ================= open dispatch (I/O) ================= *)

(* OOPS メールは機密セル対応の oopsseed 内部 opener を優先 (存在すれば) *)
iSVCLOpenOOPSMailDoc[c_Integer] := If[
  Length[DownValues[SourceVault`Private`iSVOOPSOpenMailDoc]] > 0,
  SourceVault`Private`iSVOOPSOpenMailDoc[c],
  iSVCLOpenDoc[SourceVault`SourceVaultOOPSMailView[c]]];

iSVCLOpenEagle[id_String] := If[
  Length[DownValues[SourceVault`SourceVaultEagleShowSummary]] > 0,
  Quiet @ Check[SourceVault`SourceVaultEagleShowSummary[id],
    iSVCLOpenGeneric["eagle", id, "sv://object/eagle-" <> id]],
  iSVCLOpenGeneric["eagle", id, "sv://object/eagle-" <> id]];

iSVCLOpenGeneric[kind_String, id_String, uri_String] := Which[
  StringStartsQ[uri, "http"], SystemOpen[uri],
  StringStartsQ[id, "http"], SystemOpen[id],
  StringStartsQ[uri, "sv://"] &&
      Length[DownValues[SourceVault`SourceVaultObjectProperties]] > 0,
    iSVCLOpenDoc[Dataset[Quiet @ Check[SourceVault`SourceVaultObjectProperties[uri],
      <|"URI" -> uri, "Error" -> "Unresolvable"|>]]],
  uri =!= "" && FileExistsQ[uri], SystemOpen[uri],
  id =!= "" && FileExistsQ[id], SystemOpen[id],
  True, MessageDialog["この対象を開く方法が未登録です: " <> kind <> ":" <> id]];

SourceVault`SourceVaultCrossLinkOpen[kind_String, id_String, mbox_String: "",
  uri_String: ""] := Module[
  {target = If[uri =!= "", uri, kind <> ":" <> id]},
  SourceVault`SourceVaultCrossLinkRecordInteraction[target, "SearchClick"];
  Switch[kind,
    "oops-thread", iSVCLOpenDoc[SourceVault`SourceVaultOOPSThreadView[id]],
    "oops-mail", With[{c = Quiet @ Check[FromDigits[id], $Failed]},
      If[IntegerQ[c], iSVCLOpenOOPSMailDoc[c],
        MessageDialog["OOPS counter が不正です: " <> id]]],
    "mail-thread", iSVCLOpenDoc[
      SourceVault`SourceVaultMailBrowseThreadView[id, "MBox" -> mbox]],
    "mail", SourceVault`SourceVaultMailBrowseOpenMail[id, mbox],
    "topic", iSVCLOpenDoc[
      SourceVault`SourceVaultMailBrowseTopicThreadList[id, "MBox" -> mbox]],
    "eagle", iSVCLOpenEagle[id],
    _, iSVCLOpenGeneric[kind, id, uri]]];

(* ================= View ================= *)

Options[SourceVault`SourceVaultCrossLinksView] = Options[SourceVault`SourceVaultCrossLinks];
SourceVault`SourceVaultCrossLinksView[anchor_, opts : OptionsPattern[]] := Module[
  {prof, links, cap, rows, header},
  prof = SourceVault`SourceVaultCrossLinkAnchor[anchor];
  If[! AssociationQ[prof],
    Return[Style["アンカーを解決できません: " <> ToString[prof, InputForm],
      Italic, GrayLevel[0.4]]]];
  header = Column[{
    Style[Row[{"⇄ 関連リンク: ", iSVCLShort[Lookup[prof, "Title", ""], 60]}], Bold, 13],
    Style[Row[{"query: ", iSVCLShort[Lookup[prof, "QueryText", ""], 90],
      If[Lookup[prof, "Topics", {}] === {}, "",
        "   topics: " <> StringRiffle[Take[prof["Topics"], UpTo[6]], ", "]]}],
      9, GrayLevel[0.5]]}, Spacings -> 0.2];
  links = SourceVault`SourceVaultCrossLinks[prof,
    Sequence @@ FilterRules[{opts}, Options[SourceVault`SourceVaultCrossLinks]]];
  If[links === {},
    Return[Column[{header,
      Style["(関連なし — 対象 DB がロード済みか確認: SourceVaultMailBrowseEnsureLoaded / " <>
        "SourceVaultOOPSEnsureLoaded)", Italic, GrayLevel[0.5]]}, Spacings -> 1]]];
  cap = SourceVault`$SourceVaultCrossLinkViewMaxRows;
  rows = Map[Function[r, Module[{openTarget, kindLabel},
    openTarget = SelectFirst[
      {ToString @ Lookup[r, "URI", ""], ToString @ Lookup[r, "URL", ""],
       ToString @ Lookup[r, "File", ""]}, # =!= "" &, ""];
    kindLabel = Lookup[SourceVault`$SourceVaultCrossLinkKindNames,
      Lookup[r, "Kind", ""], ToString @ Lookup[r, "Kind", ""]];
    If[ToString @ Lookup[r, "MBox", ""] =!= "", kindLabel = kindLabel <> ":" <> r["MBox"]];
    {Style[kindLabel, 9, GrayLevel[0.35]],
     With[{k = ToString @ Lookup[r, "Kind", ""], i = ToString @ Lookup[r, "Id", ""],
        b = ToString @ Lookup[r, "MBox", ""], u = openTarget,
        tl = If[ToString @ Lookup[r, "Title", ""] === "",
          iSVCLShort[Lookup[r, "Id", ""], 40], iSVCLShort[Lookup[r, "Title", ""], 50]]},
       Button[Style[tl, 12, RGBColor[0.1, 0.3, 0.7]],
         SourceVault`SourceVaultCrossLinkOpen[k, i, b, u], Appearance -> "Frameless",
         Alignment -> Left, Method -> "Queued"]],
     Round[With[{s = Lookup[r, "RankScore", Lookup[r, "Score", 0.]]},
       If[NumericQ[s], N[s], 0.]], 0.001],
     Style[iSVCLShort[Lookup[r, "Snippet", ""], 70], 10, GrayLevel[0.35]],
     Style[ToString @ Lookup[r, "Provider", ""] <>
       With[{mbst = Lookup[r, "MiningBoost", 0.]},
         If[NumericQ[mbst] && mbst > 0., " +" <> ToString[Round[mbst, 0.01]], ""]],
       9, GrayLevel[0.5]]}]],
    Take[links, UpTo[cap]]];
  Column[{header,
    Grid[Prepend[rows,
      Style[#, Bold] & /@ {"種別", "Title (クリックで開く)", "Score", "Snippet", "出典"}],
      Frame -> All, Alignment -> {Left, Center},
      Background -> {None, {LightBlue, None}}],
    If[Length[links] > cap,
      Style[Row[{"… 他 ", Length[links] - cap, " 件"}], GrayLevel[0.5], 10], Nothing]},
    Spacings -> 1]];

End[]

EndPackage[]
