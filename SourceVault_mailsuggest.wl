(* ::Package:: *)

(* SourceVault_mailsuggest.wl
   状況テキストからのメールセッション提案 (検索基盤総動員のメールマイニング関数)。
   仕様の合流点:
     - sourcevault_search_foundation_implementation_spec_v1.md (session chunk + KeywordBM25V1)
     - sourcevault_general_mail_structuring_spec_v0_1.md (一般メール構造化 / MailStruct 経路)
     - sourcevault_self_organizing_mining_identity_tag_spec_v0_1.md (TagAssertion / Authorship / Identity 二層)
   mbox = "oops" は OOPS-ml 過去ログ ($svOOPSState / oopsseed 経路)、
   それ以外 ("univ" 等) は IMAP maildb -> SourceVaultStructureMail -> BM25 index (mailstructure 経路)。
   core/View 分離: SourceVaultMailSessionSuggest が連想を返す core、
   SourceVaultMailSessionSuggestView が Dataset + 表示件数制限の View。
   依存: SourceVault_oopsseed / SourceVault_mailstructure / SourceVault_lexical /
         SourceVault_searchindex / SourceVault_mining / SourceVault_identity / SourceVault_core。
   いずれも弱結合 (未ロード成分は該当機能だけ degrade)。 *)

BeginPackage["SourceVault`"]

SourceVaultMailSessionSuggest::usage =
  "SourceVaultMailSessionSuggest[mbox, prompt, opts] は状況テキスト prompt に近いメールセッション(スレッド)候補を返す core 関数。" <>
  "mbox は IMAP maildb の mbox 名 (\"univ\" 等)、\"oops\" は OOPS-ml 過去ログ。prompt は " <>
  "\"検索エンジンについて議論が盛り上がったスレッド\" のような自然文 (BM25 session index で検索)。" <>
  "opts: \"Period\"(All | \"YYYYMM\" | {from,to} | n=直近n月), \"Keywords\"(topic item 準拠キーワード列; 一致率でスコア), " <>
  "\"From\"/\"To\"(差出人/宛先のリスト; アドレス/表示名/ent-/idf- 参照可。満たすメールを含む session だけ残す), " <>
  "\"IdentityTags\"(sv://... オブジェクト / ent- / idf- / メールアドレス / タグ文字列のリスト; " <>
  "TagAssertion・Authorship・identity 層経由で関連 session を上位に boost), " <>
  "\"Limit\"(10), \"MaxCandidates\"(50 検索プール), \"CloudSafe\"(False; True で cloud release context gate), " <>
  "\"Weights\"(Automatic = Prompt 0.6/Keywords 0.2/Identity 0.2 を有効成分で正規化), " <>
  "\"EventLimit\"(5000), \"Rebuild\"(False), \"LoadLimit\"(400 mailstruct 構造化上限)。" <>
  "戻り値 <|MBox, Prompt, Query, CandidatePool, FilteredCount, Candidates -> {<|Session, Subject, Kind, Mails, LastDate, " <>
  "Score, PromptScore, KeywordScore, IdentityScore, MatchedKeywords, MatchedIdentityTags, Snippet, MailRefs|>...}, Corpus|>。";

SourceVaultMailSessionSuggestView::usage =
  "SourceVaultMailSessionSuggestView[mbox, prompt, opts] は SourceVaultMailSessionSuggest の View 版。" <>
  "候補行を Dataset (表示件数は $SourceVaultMailSuggestViewMaxRows で制限) で返す。opts は core と同じ。";

$SourceVaultMailSuggestViewMaxRows::usage =
  "SourceVaultMailSessionSuggestView が一度に表示する最大行数 (既定 25)。";

SourceVaultMailThreadWindow::usage =
  "SourceVaultMailThreadWindow[mbox, sessionId, opts] は 1 スレッド(session)の閲覧ウィンドウを新規ノートブックで開く (front end)。" <>
  "上段にそのスレッドのメール一覧 (クリックで下段の該当メールへジャンプ)、下段に TabView で各メールを表示する。" <>
  "各メールには引用/返信 edge を辿るハイパーリンク (スレッド内は tab 切替、別スレッド参照は新規ウィンドウ) を備える。" <>
  "mbox が \"oops\" 以外 (maildb) の場合は各メール・スレッド末尾に返信ボタン (SourceVaultMailOpenReplyNotebook) を出す。" <>
  "corpus は SourceVaultMailSessionSuggest と同じキャッシュを共有 (同 opts なら即時)。" <>
  "opts: \"Period\"/\"CloudSafe\"/\"Rebuild\"/\"LoadLimit\" (corpus 解決用、suggest と同義)、\"MaxBodyChars\"(20000)、\"WindowTitle\"。";
SourceVaultMailThreadPanel::usage =
  "SourceVaultMailThreadPanel[corpus, sessionId, opts] は SourceVaultMailThreadWindow が表示する panel 式 (DynamicModule) を返す (FE 非依存に構築可)。" <>
  "corpus は iSVSug*Corpus / SourceVaultMailSessionSuggest 内部で作る corpus 連想。opts: \"MaxBodyChars\"(20000), \"OnOpenSession\"(別 session を開く関数 sid|->_, 既定は同 corpus で新規ウィンドウ), \"CanReply\"(Automatic=corpus 由来)。";
SourceVaultMailThreadStructure::usage =
  "SourceVaultMailThreadStructure[corpus, sessionId] は 1 スレッドの純構造 <|Subject, MBox, CanReply, Mails(日付順), OrderedRefs, " <>
  "Links(mailRef->{Parents(引用元/親), Children(被引用/返信)}), CrossRefs(別スレッド参照)|> を返す (FE 非依存)。panel の描画元。";
SourceVaultMailReplyDraft::usage =
  "SourceVaultMailReplyDraft[mbox, sessionId, opts] は maildb スレッド末尾メールへの返信ドラフト <|To,Cc,Subject,InReplyToToken,Quoted,Body,...|> を返す (SourceVaultMailComposeReply 委譲、FE 非依存)。" <>
  "\"ReplyToRef\" でスレッド内の特定メール(MailRef)へ返信。\"ReplyAll\"->True で Cc 含む。mbox=\"oops\" は返信非対応 (Failure)。";

Begin["`MailSuggestPrivate`"]

If[! ValueQ[SourceVault`$SourceVaultMailSuggestViewMaxRows],
  SourceVault`$SourceVaultMailSuggestViewMaxRows = 25];
If[! AssociationQ[$svMailSuggestCorpora], $svMailSuggestCorpora = <||>];   (* corpusKey -> corpus *)
If[! AssociationQ[$svMailSuggestTextCache], $svMailSuggestTextCache = <||>]; (* {corpusTag,sid} -> normText *)

$svSugCloudDenyTags = {"NoCloudLLM", "NoPublicExport", "PrivateML", "ThirdPartyContent"};

(* ---------------- 日付 ---------------- *)

$svSugMonthNum = <|"jan" -> 1, "feb" -> 2, "mar" -> 3, "apr" -> 4, "may" -> 5, "jun" -> 6,
  "jul" -> 7, "aug" -> 8, "sep" -> 9, "oct" -> 10, "nov" -> 11, "dec" -> 12|>;

(* mail Date ヘッダ (ISO / RFC2822 混在) を DateObject に。失敗は Missing。memoize *)
iSVSugDate[s_String] := iSVSugDate[s] = Module[{t = StringTrim[s], d, m},
  If[t === "", Return[Missing["NoDate"]]];
  d = Quiet@Check[DateObject[t], $Failed];
  If[Head[d] === DateObject && TrueQ[DateObjectQ[d]], Return[d]];
  (* RFC2822 fallback: "3 Feb 1999" *)
  m = StringCases[ToLowerCase[t],
    RegularExpression["(\\d{1,2})\\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\s+(\\d{2,4})"] ->
      {"$1", "$2", "$3"}];
  If[m === {}, Missing["BadDate"],
    Module[{dd = ToExpression[m[[1, 1]]], mm = Lookup[$svSugMonthNum, m[[1, 2]], 1],
        yy = ToExpression[m[[1, 3]]]},
      If[yy < 100, yy = If[yy >= 70, 1900 + yy, 2000 + yy]];
      Quiet@Check[DateObject[{yy, mm, dd}], Missing["BadDate"]]]]];
iSVSugDate[_] := Missing["NoDate"];

iSVSugYYYYMMQ[p_] := StringQ[p] && StringMatchQ[p, Repeated[DigitCharacter, {6}]];
iSVSugMonthStart[p_?iSVSugYYYYMMQ] :=
  DateObject[{ToExpression@StringTake[p, 4], ToExpression@StringTake[p, {5, 6}], 1}];
iSVSugMonthEnd[p_?iSVSugYYYYMMQ] := DatePlus[DatePlus[iSVSugMonthStart[p], {1, "Month"}], {-1, "Day"}];

iSVSugRangeEdge[x_, kind_] := Which[
  Head[x] === DateObject, x,
  iSVSugYYYYMMQ[x], If[kind === "Start", iSVSugMonthStart[x], iSVSugMonthEnd[x]],
  StringQ[x], With[{d = iSVSugDate[x]}, If[Head[d] === DateObject, d, Missing["BadEdge"]]],
  True, Missing["BadEdge"]];

(* Period -> {from, to} (DateObject) | Missing (フィルタ無し) *)
iSVSugPeriodRange[p_] := Which[
  MatchQ[p, All | None | Automatic | "Latest" | ""], Missing["NoFilter"],
  IntegerQ[p] && p > 0,
    With[{now = Now},
      {DatePlus[DateObject[{DateValue[now, "Year"], DateValue[now, "Month"], 1}], {-(p - 1), "Month"}], now}],
  iSVSugYYYYMMQ[p], {iSVSugMonthStart[p], iSVSugMonthEnd[p]},
  ListQ[p] && Length[p] === 2,
    With[{a = iSVSugRangeEdge[p[[1]], "Start"], b = iSVSugRangeEdge[p[[2]], "End"]},
      If[Head[a] === DateObject && Head[b] === DateObject, {a, b}, Missing["NoFilter"]]],
  True, Missing["NoFilter"]];

(* Day 粒度に落とす。実メールの Date は時刻付き(Instant)で、境界(Day)と <= 比較すると
   DateObject::nordol (粒度重複で比較不能) を出し比較が symbolic 化して行が壊れる。両辺 Day に揃える。 *)
iSVSugDay[d_] := If[Head[d] === DateObject, Quiet@Check[DateObject[d, "Day"], d], d];
iSVSugInRangeQ[d_, {a_, b_}] := With[{dd = iSVSugDay[d]},
  Head[dd] === DateObject && iSVSugDay[a] <= dd <= iSVSugDay[b]];

(* ---------------- corpus 正規化層 ---------------- *)

iSVSugNorm[s_String] := SourceVault`SourceVaultNormalizeSearchText[s];
iSVSugNorm[_] := "";

iSVSugStrOr[x_] := If[StringQ[x], x, ""];

(* relation/quote edge を window 用に正規化: {<|From, To, Kind, Role|>...} (mailRef ベース) *)
iSVSugNormEdges[edges_List] := DeleteDuplicates@Map[Function[e,
  <|"From" -> iSVSugStrOr@Lookup[e, "FromMailRef", ""],
    "To" -> iSVSugStrOr@Lookup[e, "ToMailRef", ""],
    "Kind" -> Lookup[e, "EdgeKind", Missing["Unknown"]],
    "Role" -> Lookup[e, "RelationRole", "Quote"]|>],
  Select[edges, AssociationQ]];
iSVSugNormEdges[_] := {};

(* OOPS corpus: $svOOPSState を正規化 (index/検索は SourceVaultOOPSSearchThreads を再利用) *)
iSVSugOOPSCorpus[cloudSafe_] := Module[{st, mailBy, rows},
  Quiet@Check[SourceVault`SourceVaultOOPSEnsureLoaded[], Null];
  st = SourceVault`$svOOPSState;
  If[! TrueQ[Lookup[st, "Loaded", False]],
    Return[Failure["OOPSNotLoaded",
      <|"MessageTemplate" -> "OOPS 過去ログをロードできません (SourceVaultOOPSEnsureLoaded 失敗)。"|>]]];
  mailBy = Association[Map[Function[m, With[
      {ref = "sv://mail/" <> ToString[Lookup[m, "Counter", "?"]]},
      ref -> <|"MailRef" -> ref, "RecordId" -> ToString[Lookup[m, "Counter", "?"]],
        "From" -> iSVSugStrOr@Lookup[m, "From", ""], "To" -> iSVSugStrOr@Lookup[m, "To", ""],
        "Cc" -> iSVSugStrOr@Lookup[m, "Cc", ""],
        "Subject" -> iSVSugStrOr@Lookup[m, "Subject", ""],
        "DateRaw" -> iSVSugStrOr@Lookup[m, "Date", ""],
        "Body" -> iSVSugStrOr@Lookup[m, "Body", ""]|>]],
    Lookup[st, "Mails", {}]]];
  rows = Association[Map[Function[sess, Lookup[sess, "MailSessionId", ""] -> <|
      "SessionId" -> Lookup[sess, "MailSessionId", ""],
      "Subject" -> iSVSugStrOr@Lookup[sess, "Subject", ""],
      "Kind" -> Lookup[sess, "SessionKind", Missing["Unknown"]],
      "MailRefs" -> Lookup[sess, "MailRefs",
         ("sv://mail/" <> ToString[#]) & /@ Lookup[sess, "MailCounters", {}]],
      "MailCount" -> Lookup[sess, "MailCount", Length[Lookup[sess, "MailCounters", {}]]]|>],
    Lookup[st, "Sessions", {}]]];
  <|"Kind" -> "OOPS", "CorpusTag" -> "oops", "MBox" -> "oops", "CanReply" -> False,
    "SessionRows" -> rows, "MailByRef" -> mailBy,
    "RelationEdges" -> iSVSugNormEdges[Lookup[st, "QuoteEdges", {}]],
    "SessionAssocById" -> Association[(Lookup[#, "MailSessionId", ""] -> #) & /@ Lookup[st, "Sessions", {}]],
    "Records" -> Lookup[st, "Mails", {}],
    "SearchFn" -> Function[{q, lim}, Module[{res},
       res = Quiet[SourceVault`SourceVaultOOPSSearchThreads[q,
          "Limit" -> lim, "CloudSafe" -> cloudSafe]];
       If[Head[res] === Dataset, res = Normal[res]];
       If[! ListQ[res], {},
         <|"Session" -> Lookup[#, "Session", ""], "Score" -> Lookup[#, "Score", 0.],
           "Snippet" -> Lookup[#, "Snippet", ""]|> & /@ res]]]|>];

(* MailStruct corpus: maildb -> generic record -> StructureMail -> BM25 index。(mbox, period, ctx) 単位で cache *)
iSVSugMailStructCorpus[mbox_String, period_, cloudSafe_, rebuild_, loadLimit_] := Module[
  {ctx, key, range, df, dt, records, scope, st, idxInfo, rows, mailBy, corpus},
  ctx = If[TrueQ[cloudSafe], "mailstruct-cloud", "mailstruct-local"];
  key = {"mailstruct", mbox, period, ctx, loadLimit};
  If[! TrueQ[rebuild] && KeyExistsQ[$svMailSuggestCorpora, key],
    Return[$svMailSuggestCorpora[key]]];
  Quiet@Check[SourceVault`SourceVaultMailEnsureLoaded[mbox,
     period /. {None -> All, Automatic -> All}], Null];
  range = iSVSugPeriodRange[period];
  df = If[ListQ[range], DateString[range[[1]], "ISODate"], None];
  dt = If[ListQ[range], DateString[range[[2]], "ISODate"], None];
  (* Check ではなく Quiet: RecordsForStructuring が付随メッセージを出しても結果は保持する
     (Check だと「メッセージ発生=失敗」と誤認して空にしてしまう)。失敗判定は型ガードで行う。 *)
  records = Quiet[SourceVault`SourceVaultMailRecordsForStructuring[
     "MBox" -> mbox, "DateFrom" -> df, "DateTo" -> dt,
     "ReleaseContext" -> ctx, "Limit" -> loadLimit]];
  If[! ListQ[records] || records === {},
    Return[Failure["NoMailRecords",
      <|"MessageTemplate" -> "mbox `1` に構造化対象メールがありません (SourceVaultMailEnsureLoaded 済みか確認)。",
        "MessageParameters" -> {mbox}|>]]];
  scope = If[TrueQ[cloudSafe],
    <|"ReleaseContext" -> ctx, "MaxPrivacyLevel" -> 1.0, "DenyTags" -> $svSugCloudDenyTags|>,
    <|"ReleaseContext" -> ctx, "MaxPrivacyLevel" -> 1.0, "DenyTags" -> {}|>];
  st = SourceVault`SourceVaultStructureMail[records, "PrivacyScope" -> scope,
     "QuotePass" -> "Full", "OwnerRef" -> "owner:mailsuggest"];
  idxInfo = SourceVault`SourceVaultMailStructBuildSearchIndex[st, "ReleaseContext" -> ctx];
  mailBy = Association[Map[Function[r, Lookup[r, "MailRef", ""] -> <|
      "MailRef" -> Lookup[r, "MailRef", ""],
      "RecordId" -> With[{rid = Lookup[r, "RecordId", Missing[]]},
         If[StringQ[rid], rid, StringDelete[Lookup[r, "MailRef", ""], "sv://mail/"]]],
      "From" -> iSVSugStrOr@Lookup[r, "From", ""], "To" -> iSVSugStrOr@Lookup[r, "To", ""],
      "Cc" -> iSVSugStrOr@Lookup[r, "Cc", ""],
      "Subject" -> iSVSugStrOr@Lookup[r, "Subject", ""],
      "DateRaw" -> iSVSugStrOr@Lookup[r, "Date", ""],
      "Body" -> With[{b = Lookup[r, "Body", ""]}, If[StringQ[b], b, ""]],
      "Tags" -> Lookup[r, "Tags", {}],
      "PrivacyLevel" -> Lookup[r, "PrivacyLevel", 1.0]|>], records]];
  rows = Association[Map[Function[sess, Module[{refs, subj},
      refs = Lookup[sess, "MailRefs", {}];
      subj = With[{subs = Select[
           Lookup[Lookup[mailBy, #, <||>], "Subject", ""] & /@ refs,
           StringQ[#] && StringTrim[#] =!= "" &]},
        If[subs === {}, "(件名なし)", First[Commonest[subs]]]];
      Lookup[sess, "MailSessionId", ""] -> <|
        "SessionId" -> Lookup[sess, "MailSessionId", ""],
        "Subject" -> subj, "Kind" -> Missing["NotClassified"],
        "MailRefs" -> refs, "MailCount" -> Lookup[sess, "MailCount", Length[refs]]|>]],
    Lookup[st, "Sessions", {}]]];
  corpus = <|"Kind" -> "MailStruct", "CorpusTag" -> StringRiffle[ToString /@ key, "|"],
    "MBox" -> mbox, "CanReply" -> True,
    "SessionRows" -> rows, "MailByRef" -> mailBy,
    "RelationEdges" -> iSVSugNormEdges[Lookup[Lookup[st, "RelationGraph", <||>], "Edges", {}]],
    "SessionAssocById" -> Association[(Lookup[#, "MailSessionId", ""] -> #) & /@ Lookup[st, "Sessions", {}]],
    "Records" -> records, "IndexInfo" -> idxInfo, "ReleaseContext" -> ctx,
    "SearchFn" -> Function[{q, lim}, Module[{res},
       res = Quiet[SourceVault`SourceVaultMailStructSearch[q, idxInfo,
          "ReleaseContext" -> ctx, "Limit" -> lim]];
       If[Head[res] === Dataset, res = Normal[res]];
       If[! ListQ[res], {},
         <|"Session" -> Lookup[#, "ChunkId", ""], "Score" -> Lookup[#, "Score", 0.],
           "Snippet" -> Lookup[#, "Snippet", ""]|> & /@ res]]]|>;
  $svMailSuggestCorpora[key] = corpus;
  corpus];

(* mbox から corpus を解決 ("oops" は OOPS 過去ログ、他は maildb) *)
iSVSugResolveCorpus[mbox_String, period_, cloudSafe_, rebuild_, loadLimit_] :=
  If[ToLowerCase[StringTrim[mbox]] === "oops",
    iSVSugOOPSCorpus[cloudSafe],
    iSVSugMailStructCorpus[mbox, period, cloudSafe, rebuild, loadLimit]];

(* session 正規化本文 (subject + 本文連結、cache 付き) *)
iSVSugSessNormText[corpus_, sessRow_] := Module[
  {ck = {Lookup[corpus, "CorpusTag", "?"], sessRow["SessionId"]}, mails, txt},
  If[KeyExistsQ[$svMailSuggestTextCache, ck], Return[$svMailSuggestTextCache[ck]]];
  mails = DeleteMissing[Lookup[corpus["MailByRef"], sessRow["MailRefs"]]];
  txt = iSVSugNorm[StringTake[
     StringRiffle[Join[{sessRow["Subject"]}, Lookup[#, "Body", ""] & /@ mails], "\n"], UpTo[20000]]];
  $svMailSuggestTextCache[ck] = txt;
  txt];

(* ---------------- From/To 照合 ---------------- *)

(* entity の Email identifier 値 + DisplayName を照合パターンにする *)
iSVSugEntityPatterns[eid_String] := Module[{e, idfs, emails, dn},
  e = Quiet@Check[SourceVault`SourceVaultGetEntity[eid], Missing[]];
  If[! AssociationQ[e], Return[{}]];
  idfs = Quiet@Check[SourceVault`SourceVaultGetIdentifier[#], Missing[]] & /@ Lookup[e, "Identifiers", {}];
  emails = Cases[idfs, i_Association /; Lookup[i, "Kind", ""] === "Email" :> ToLowerCase[Lookup[i, "Value", ""]]];
  dn = Lookup[e, "DisplayName", ""];
  DeleteDuplicates@DeleteCases[Append[emails, ToLowerCase[iSVSugStrOr[dn]]], ""]];

(* From/To オプション項目 -> 小文字部分一致パターン列 *)
iSVSugAddressPatterns[spec_] := Module[{items},
  items = Which[spec === {} || spec === None || spec === All, {},
    ListQ[spec], spec, StringQ[spec], {spec}, True, {}];
  If[items =!= {}, Quiet@Check[SourceVault`SourceVaultIdentityEnsureLoaded[], Null]];
  DeleteDuplicates@Flatten[Map[Function[e, Which[
      StringQ[e] && StringStartsQ[e, "ent-"], iSVSugEntityPatterns[e],
      StringQ[e] && StringStartsQ[e, "idf-"],
        With[{idf = Quiet@Check[SourceVault`SourceVaultGetIdentifier[e], Missing[]]},
          If[AssociationQ[idf], {ToLowerCase[Lookup[idf, "Value", ""]]}, {}]],
      StringQ[e] && StringTrim[e] =!= "", {ToLowerCase[StringTrim[e]]},
      True, {}]], items]]];

iSVSugFieldMatch[field_String, pats_List] :=
  pats =!= {} && With[{f = ToLowerCase[field]}, AnyTrue[pats, # =!= "" && StringContainsQ[f, #] &]];

(* session が From/To 条件を満たすメールを含むか *)
iSVSugFromToQ[mails_List, fromPats_List, toPats_List] :=
  (fromPats === {} && toPats === {}) ||
  AnyTrue[mails, Function[m,
    (fromPats === {} || iSVSugFieldMatch[Lookup[m, "From", ""], fromPats]) &&
    (toPats === {} || iSVSugFieldMatch[
       Lookup[m, "To", ""] <> " " <> Lookup[m, "Cc", ""], toPats])]];

(* ---------------- IdentityTags 解決 (mining/identity 弱結合) ---------------- *)

iSVSugMiningAvailableQ[] :=
  Length[DownValues[SourceVault`SourceVaultReplayTagAssertions]] > 0 &&
  Length[DownValues[SourceVault`SourceVaultTransactionLog]] > 0;

(* 1 identity tag -> 照合プロファイル
   <|Tag, MailRefs(直接参照する mail), Addresses(From/To 照合), TagStrings(共有 tag), TextTerms(本文照合)|> *)
iSVSugOneProfile[t_String, actives_List, authAll_List] := Module[
  {prof = <|"Tag" -> t, "MailRefs" -> {}, "Addresses" -> {}, "TagStrings" -> {}, "TextTerms" -> {}|>,
   addrOfAuth, taggedMails},
  (* この tag 文字列を Tag に持つ assertion の対象メール *)
  taggedMails = DeleteDuplicates@Cases[actives,
    a_Association /; Lookup[a, "Tag", ""] === t &&
       StringStartsQ[iSVSugStrOr@Lookup[a, "TargetURI", ""], "sv://mail/"] :> a["TargetURI"]];
  (* authorship assertion の Identifier/Entity をアドレスに解決 *)
  addrOfAuth = Function[a, Module[{out = {}},
     With[{er = Lookup[a, "EntityRef", Missing[]]},
       If[StringQ[er], out = Join[out, iSVSugEntityPatterns[er]]]];
     With[{ir = Lookup[a, "IdentifierRef", Missing[]]},
       If[StringQ[ir],
         With[{idf = Quiet@Check[SourceVault`SourceVaultGetIdentifier[ir], Missing[]]},
           If[AssociationQ[idf] && Lookup[idf, "Kind", ""] === "Email",
             AppendTo[out, ToLowerCase[Lookup[idf, "Value", ""]]]]]]];
     out]];
  Which[
   StringStartsQ[t, "sv://mail/"],
     prof["MailRefs"] = {t},
   StringStartsQ[t, "sv://"],
     Module[{objTags, auths},
       objTags = Quiet@Check[
          Lookup[SourceVault`SourceVaultObjectTags[actives, t], "Tags", {}], {}];
       auths = Select[authAll, Lookup[#, "ObjectURI", ""] === t &];
       prof["TagStrings"] = objTags;
       prof["MailRefs"] = taggedMails;
       prof["Addresses"] = DeleteDuplicates@Flatten[addrOfAuth /@ auths]],
   StringStartsQ[t, "ent-"],
     Module[{e = Quiet@Check[SourceVault`SourceVaultGetEntity[t], Missing[]]},
       prof["Addresses"] = iSVSugEntityPatterns[t];
       prof["TextTerms"] = If[AssociationQ[e], {iSVSugStrOr@Lookup[e, "DisplayName", ""]}, {}];
       prof["MailRefs"] = DeleteDuplicates@Join[taggedMails,
          Cases[authAll, a_Association /; Lookup[a, "EntityRef", Missing[]] === t &&
             StringStartsQ[iSVSugStrOr@Lookup[a, "ObjectURI", ""], "sv://mail/"] :> a["ObjectURI"]]]],
   StringStartsQ[t, "idf-"],
     Module[{idf = Quiet@Check[SourceVault`SourceVaultGetIdentifier[t], Missing[]]},
       If[AssociationQ[idf] && Lookup[idf, "Kind", ""] === "Email",
         prof["Addresses"] = {ToLowerCase[Lookup[idf, "Value", ""]]}];
       prof["MailRefs"] = Cases[authAll,
          a_Association /; Lookup[a, "IdentifierRef", Missing[]] === t &&
            StringStartsQ[iSVSugStrOr@Lookup[a, "ObjectURI", ""], "sv://mail/"] :> a["ObjectURI"]]],
   StringContainsQ[t, "@"],
     prof["Addresses"] = {ToLowerCase[StringTrim[t]]},
   True,
     (* タグ文字列 / 表示名: assertion 直接対象 + DisplayName 一致 entity + 本文語 *)
     Module[{ent},
       ent = SelectFirst[Quiet@Check[SourceVault`SourceVaultListEntities[], {}],
          Lookup[#, "DisplayName", ""] === t &, Missing[]];
       prof["MailRefs"] = taggedMails;
       prof["TagStrings"] = {t};
       prof["TextTerms"] = {t};
       If[AssociationQ[ent],
         prof["Addresses"] = iSVSugEntityPatterns[Lookup[ent, "EntityId", ""]]]]];
  prof];

(* IdentityTags -> {profiles, assertsByTarget} *)
iSVSugIdentityProfiles[tags_List, eventLimit_] := Module[{ev, tagsAll, actives, authAll},
  If[tags === {}, Return[<|"Profiles" -> {}, "AssertsByTarget" -> <||>|>]];
  Quiet@Check[SourceVault`SourceVaultIdentityEnsureLoaded[], Null];
  If[! iSVSugMiningAvailableQ[],
    ev = {}; actives = {}; authAll = {},
    ev = Quiet@Check[SourceVault`SourceVaultTransactionLog["Limit" -> eventLimit], {}];
    If[! ListQ[ev], ev = {}];
    tagsAll = Quiet@Check[SourceVault`SourceVaultReplayTagAssertions[ev], {}];
    actives = Select[If[ListQ[tagsAll], tagsAll, {}], Lookup[#, "Status", ""] === "active" &];
    authAll = Lookup[#, "Assertion", <||>] & /@
      Select[ev, Lookup[#, "EventClass", ""] === "AuthorshipObserved" &]];
  <|"Profiles" -> (iSVSugOneProfile[#, actives, authAll] & /@ Select[tags, StringQ]),
    "AssertsByTarget" -> GroupBy[
       Select[actives, StringStartsQ[iSVSugStrOr@Lookup[#, "TargetURI", ""], "sv://mail/"] &],
       Lookup[#, "TargetURI"] &]|>];

(* 1 profile の session への寄与 (0..1) *)
iSVSugIdentityContribution[prof_, refs_List, mails_List, sessTags_List, normTextFn_] := Which[
  Intersection[prof["MailRefs"], refs] =!= {}, 1.0,
  prof["Addresses"] =!= {} && AnyTrue[mails, Function[m, iSVSugFieldMatch[
     StringRiffle[{Lookup[m, "From", ""], Lookup[m, "To", ""], Lookup[m, "Cc", ""]}, " "],
     prof["Addresses"]]]], 0.8,
  MemberQ[sessTags, prof["Tag"]], 0.7,
  Intersection[prof["TagStrings"], sessTags] =!= {}, 0.5,
  prof["TextTerms"] =!= {} && With[{nt = normTextFn[]},
     AnyTrue[Select[prof["TextTerms"], # =!= "" &],
       StringContainsQ[nt, iSVSugNorm[#]] &]], 0.4,
  True, 0.];

(* ---------------- core ---------------- *)

iSVSugFirstSnippet[mails_List, chars_Integer] := Module[{b},
  b = SelectFirst[Lookup[#, "Body", ""] & /@ mails, StringQ[#] && StringTrim[#] =!= "" &, ""];
  StringTake[StringReplace[b, {"\n" -> " ", "\r" -> ""}], UpTo[chars]]];

Options[SourceVaultMailSessionSuggest] = {
  "Period" -> All, "Keywords" -> {}, "From" -> {}, "To" -> {}, "IdentityTags" -> {},
  "Limit" -> 10, "MaxCandidates" -> 50, "CloudSafe" -> False,
  "Weights" -> Automatic, "EventLimit" -> 5000, "Rebuild" -> False, "LoadLimit" -> 400};

SourceVaultMailSessionSuggest[mbox_String, prompt_String : "", OptionsPattern[]] := Module[
  {period = OptionValue["Period"], cloudSafe = TrueQ[OptionValue["CloudSafe"]],
   lim = OptionValue["Limit"], maxCand = OptionValue["MaxCandidates"],
   keywords, idTags, corpus, range, fromPats, toPats, idProf, profiles, assertsByTarget,
   query, searchRows, poolCount, maxScore, weights, wP, wK, wI, wTotal, rows, filteredCount},
  keywords = With[{k = OptionValue["Keywords"]},
    Which[ListQ[k], Select[k, StringQ[#] && StringTrim[#] =!= "" &],
      StringQ[k] && StringTrim[k] =!= "", {k}, True, {}]];
  idTags = With[{k = OptionValue["IdentityTags"]},
    Which[ListQ[k], Select[k, StringQ[#] && StringTrim[#] =!= "" &],
      StringQ[k] && StringTrim[k] =!= "", {k}, True, {}]];
  corpus = If[ToLowerCase[StringTrim[mbox]] === "oops",
    iSVSugOOPSCorpus[cloudSafe],
    iSVSugMailStructCorpus[mbox, period, cloudSafe,
      TrueQ[OptionValue["Rebuild"]], OptionValue["LoadLimit"]]];
  If[FailureQ[corpus], Return[corpus]];
  range = iSVSugPeriodRange[period];
  fromPats = iSVSugAddressPatterns[OptionValue["From"]];
  toPats = iSVSugAddressPatterns[OptionValue["To"]];
  idProf = iSVSugIdentityProfiles[idTags, OptionValue["EventLimit"]];
  profiles = idProf["Profiles"]; assertsByTarget = idProf["AssertsByTarget"];
  (* 検索プール: prompt+keywords を 1 query に。空なら全 session (通数降順) *)
  query = StringTrim@StringRiffle[
     Join[If[StringTrim[prompt] === "", {}, {prompt}], keywords], " "];
  searchRows = If[query =!= "",
    corpus["SearchFn"][query, maxCand],
    Map[Function[sr, <|"Session" -> sr["SessionId"], "Score" -> 0., "Snippet" -> ""|>],
      Take[ReverseSortBy[Values[corpus["SessionRows"]], #["MailCount"] &], UpTo[maxCand]]]];
  searchRows = DeleteDuplicatesBy[Select[searchRows, StringQ[Lookup[#, "Session", Null]] &],
     Lookup[#, "Session"] &];
  poolCount = Length[searchRows];
  maxScore = Max[Append[Lookup[#, "Score", 0.] & /@ searchRows, 0.]];
  (* weights: 有効成分 (prompt / keywords / identitytags) だけで正規化 *)
  weights = OptionValue["Weights"] /. Automatic ->
    <|"Prompt" -> 0.6, "Keywords" -> 0.2, "Identity" -> 0.2|>;
  wP = If[query =!= "", Lookup[weights, "Prompt", 0.6], 0.];
  wK = If[keywords =!= {}, Lookup[weights, "Keywords", 0.2], 0.];
  wI = If[profiles =!= {}, Lookup[weights, "Identity", 0.2], 0.];
  wTotal = wP + wK + wI;
  rows = DeleteCases[Map[Function[hit, Module[
     {sid = hit["Session"], sessRow, mails, dates, lastDate, normTextFn, sessTags,
      pScore, matchedKw, kScore, contribs, matchedTags, iScore, total, kindVal, snippet},
     sessRow = Lookup[corpus["SessionRows"], sid, Missing[]];
     If[! AssociationQ[sessRow], Nothing,
      mails = DeleteMissing[Lookup[corpus["MailByRef"], sessRow["MailRefs"]]];
      dates = DeleteMissing[iSVSugDate[Lookup[#, "DateRaw", ""]] & /@ mails];
      (* period / From / To フィルタ *)
      If[ListQ[range] && ! AnyTrue[dates, iSVSugInRangeQ[#, range] &], Nothing,
       If[! iSVSugFromToQ[mails, fromPats, toPats], Nothing,
        lastDate = If[dates === {}, "", DateString[Last[Sort[dates]], "ISODate"]];
        normTextFn = Function[{}, iSVSugSessNormText[corpus, sessRow]];
        pScore = If[maxScore > 0, N[Lookup[hit, "Score", 0.]/maxScore], 0.];
        matchedKw = Select[keywords, StringContainsQ[normTextFn[], iSVSugNorm[#]] &];
        kScore = If[keywords === {}, 0., N[Length[matchedKw]/Length[keywords]]];
        sessTags = DeleteDuplicates@Flatten[
           Lookup[#, "Tag", ""] & /@ Flatten[Lookup[assertsByTarget, sessRow["MailRefs"], {}]]];
        contribs = Map[Function[pr, pr["Tag"] ->
            iSVSugIdentityContribution[pr, sessRow["MailRefs"], mails, sessTags, normTextFn]],
          profiles];
        matchedTags = Keys@Select[Association[contribs], # > 0 &];
        iScore = If[profiles === {}, 0., N[Total[Values[Association[contribs]]]/Length[profiles]]];
        total = If[wTotal > 0, (wP*pScore + wK*kScore + wI*iScore)/wTotal, 0.];
        kindVal = With[{k = sessRow["Kind"]},
          If[! MissingQ[k], k,
            Quiet@Check[Lookup[SourceVault`SourceVaultClassifyMailSessionKind[
               Lookup[corpus["SessionAssocById"], sid, <||>], corpus["Records"]],
              "SessionKind", Missing["Unknown"]], Missing["Unknown"]]]];
        snippet = With[{s = Lookup[hit, "Snippet", ""]},
          If[StringQ[s] && StringTrim[s] =!= "", s, iSVSugFirstSnippet[mails, 80]]];
        <|"Session" -> sid, "Subject" -> sessRow["Subject"], "Kind" -> kindVal,
          "Mails" -> sessRow["MailCount"], "LastDate" -> lastDate,
          "Score" -> Round[total, 0.001],
          "PromptScore" -> Round[pScore, 0.001], "KeywordScore" -> Round[kScore, 0.001],
          "IdentityScore" -> Round[iScore, 0.001],
          "MatchedKeywords" -> matchedKw, "MatchedIdentityTags" -> matchedTags,
          "Snippet" -> snippet, "MailRefs" -> sessRow["MailRefs"]|>]]]]],
    searchRows], Nothing];
  filteredCount = Length[rows];
  rows = Take[ReverseSortBy[rows, {#["Score"], #["LastDate"]} &], UpTo[lim]];
  <|"MBox" -> mbox, "Prompt" -> prompt, "Query" -> query,
    "CandidatePool" -> poolCount, "FilteredCount" -> filteredCount,
    "Candidates" -> rows,
    "Corpus" -> <|"Kind" -> corpus["Kind"],
      "SessionCount" -> Length[corpus["SessionRows"]],
      "MailCount" -> Length[corpus["MailByRef"]],
      "CloudSafe" -> cloudSafe|>,
    "Weights" -> <|"Prompt" -> wP, "Keywords" -> wK, "Identity" -> wI|>|>];

(* ---------------- View ---------------- *)

Options[SourceVaultMailSessionSuggestView] = Options[SourceVaultMailSessionSuggest];
SourceVaultMailSessionSuggestView[mbox_String, prompt_String : "", opts : OptionsPattern[]] := Module[
  {res, rows, period, cloudSafe, loadLimit, openBtn},
  res = SourceVaultMailSessionSuggest[mbox, prompt, opts];
  If[FailureQ[res] || ! AssociationQ[res], Return[res]];
  rows = Lookup[res, "Candidates", {}];
  If[rows === {}, Return[Dataset[{}]]];
  (* corpus 再解決用の opts を捕捉 (window を同キャッシュで開く) *)
  period = OptionValue["Period"]; cloudSafe = OptionValue["CloudSafe"];
  loadLimit = OptionValue["LoadLimit"];
  openBtn[sid_] := Button["\:958b\:304f",   (* 開く *)
     SourceVaultMailThreadWindow[mbox, sid, "Period" -> period,
       "CloudSafe" -> cloudSafe, "LoadLimit" -> loadLimit],
     Appearance -> "Palette", Method -> "Queued"];
  Dataset[
    Function[r, Join[
       <|"Open" -> openBtn[Lookup[r, "Session", ""]]|>,
       KeyTake[r, {"Session", "Subject", "Kind", "Mails", "LastDate", "Score",
          "MatchedKeywords", "MatchedIdentityTags", "Snippet"}]]] /@ rows,
    MaxItems -> {SourceVault`$SourceVaultMailSuggestViewMaxRows, All}]];

(* ================= スレッド閲覧ウィンドウ (§9b live view / hypertext) ================= *)

(* 表示名短縮 (<addr> 除去)、日付短縮、日付ソートキー、本文 readable 化 *)
iSVSugFromShort[m_Association] := With[{f = iSVSugStrOr@Lookup[m, "From", ""]},
  With[{s = StringTrim@StringReplace[f, RegularExpression["\\s*<[^>]*>"] -> ""]},
    If[s === "", f, s]]];
iSVSugDateShort[m_Association] := With[{d = iSVSugDate[Lookup[m, "DateRaw", ""]]},
  If[Head[d] === DateObject, DateString[d, "ISODate"], iSVSugStrOr@Lookup[m, "DateRaw", ""]]];
iSVSugSortKey[m_Association] := With[{d = iSVSugDate[Lookup[m, "DateRaw", ""]]},
  If[Head[d] === DateObject, AbsoluteTime[d], Infinity]];
iSVSugReadableBody[b_String] := Module[{s = StringReplace[b, {"\r\n" -> "\n", "\r" -> "\n"}]},
  If[StringContainsQ[s, RegularExpression["(?i)<(html|body|div|p|br|table)[ >/]"]],
    s = StringReplace[s, {RegularExpression["(?i)<br\\s*/?>"] -> "\n",
       RegularExpression["(?i)</(p|div|tr|h[1-6]|li)>"] -> "\n",
       RegularExpression["<[^>]+>"] -> ""}]];
  StringTrim[s]];
iSVSugReadableBody[_] := "";

(* ハイパーリンク色 *)
$svSugLinkColor = RGBColor[0.1, 0.32, 0.72];
$svSugXLinkColor = RGBColor[0.55, 0.2, 0.6];

(* スレッド構造 (純関数・FE 非依存・テスト可能)。
   日付順メール列 + 各メールの引用元(Parents)/被引用(Children) スレッド内リンク +
   別スレッド参照(CrossRefs) を返す。panel はこれを描画するだけ。 *)
SourceVaultMailThreadStructure[corpus_Association, sessionId_String] := Module[
  {sessRow, mailBy, mails, orderedRefs, inSet, edges, links, crossRefs},
  sessRow = Lookup[Lookup[corpus, "SessionRows", <||>], sessionId, Missing[]];
  If[! AssociationQ[sessRow],
    Return[Failure["SessionNotFound",
      <|"MessageTemplate" -> "session `1` が corpus にありません。", "MessageParameters" -> {sessionId}|>]]];
  mailBy = Lookup[corpus, "MailByRef", <||>];
  mails = SortBy[DeleteMissing[Lookup[mailBy, Lookup[sessRow, "MailRefs", {}]]], iSVSugSortKey];
  If[mails === {},
    Return[Failure["EmptyThread", <|"MessageTemplate" -> "スレッドにメールがありません。"|>]]];
  orderedRefs = Lookup[#, "MailRef", ""] & /@ mails;
  inSet = Association[(# -> True) & /@ orderedRefs];
  (* スレッド内 edge のみ (From=citing → To=cited) *)
  edges = Select[Lookup[corpus, "RelationEdges", {}],
     KeyExistsQ[inSet, Lookup[#, "From", ""]] && KeyExistsQ[inSet, Lookup[#, "To", ""]] &];
  links = Association[Map[Function[ref, ref -> <|
     "Parents" -> DeleteDuplicates@Select[
        Lookup[#, "To", ""] & /@ Select[edges, Lookup[#, "From", ""] === ref &], # =!= ref &],
     "Children" -> DeleteDuplicates@Select[
        Lookup[#, "From", ""] & /@ Select[edges, Lookup[#, "To", ""] === ref &], # =!= ref &]|>],
    orderedRefs]];
  crossRefs = DeleteCases[Map[Function[cr,
     With[{toSid = Lookup[cr, "ToSession", Missing[]]},
       If[StringQ[toSid] && toSid =!= sessionId,
         <|"Role" -> ToString@Lookup[cr, "Role", ""], "ToSession" -> toSid,
           "ToSubject" -> iSVSugStrOr@Lookup[Lookup[corpus["SessionRows"], toSid, <||>], "Subject", toSid]|>,
         Nothing]]],
     Lookup[Lookup[Lookup[corpus, "SessionAssocById", <||>], sessionId, <||>],
        "CrossSessionReferences", {}]], Nothing];
  <|"SessionId" -> sessionId,
    "Subject" -> With[{s = iSVSugStrOr@Lookup[sessRow, "Subject", ""]}, If[s === "", "(件名なし)", s]],
    "MBox" -> iSVSugStrOr@Lookup[corpus, "MBox", ""],
    "CanReply" -> TrueQ@Lookup[corpus, "CanReply", False],
    "Mails" -> mails, "OrderedRefs" -> orderedRefs, "Links" -> links, "CrossRefs" -> crossRefs|>];

Options[SourceVaultMailThreadPanel] = {"MaxBodyChars" -> 20000, "OnOpenSession" -> Automatic,
  "CanReply" -> Automatic};
SourceVaultMailThreadPanel[corpus_Association, sessionId_String, OptionsPattern[]] := Module[
  {struct, mails, orderedRefs, refToIdx, links, n, subject, mbox, canReply,
   maxBody = OptionValue["MaxBodyChars"], openSess, crossButtons},
  struct = SourceVaultMailThreadStructure[corpus, sessionId];
  If[FailureQ[struct], Return[struct]];
  mails = struct["Mails"]; orderedRefs = struct["OrderedRefs"]; links = struct["Links"];
  n = Length[mails];
  refToIdx = Association[MapIndexed[#1 -> #2[[1]] &, orderedRefs]];
  subject = struct["Subject"]; mbox = struct["MBox"];
  canReply = With[{c = OptionValue["CanReply"]},
    If[c === Automatic, TrueQ[struct["CanReply"]], TrueQ[c]]];
  With[{mailBy = Lookup[corpus, "MailByRef", <||>]},
   openSess = With[{ofn = OptionValue["OnOpenSession"]},
     If[ofn === Automatic,
       Function[sid, CreateDocument[SourceVaultMailThreadPanel[corpus, sid, "MaxBodyChars" -> maxBody],
          WindowTitle -> "\:30b9\:30ec\:30c3\:30c9", WindowSize -> {720, 680}]],
       ofn]];
   crossButtons = Map[Function[cr,
      With[{toSid = cr["ToSession"], role = cr["Role"], subj = cr["ToSubject"]},
        Button[Style["\[RightArrow] " <> role <> ": " <> subj, $svSugXLinkColor],
           openSess[toSid], Appearance -> "Frameless", Method -> "Queued"]]], struct["CrossRefs"]];
  (* ---- DynamicModule: sel = 選択中メール index。上=一覧、下=TabView ---- *)
  DynamicModule[{sel = 1},
   Column[{
     Style[subject, Bold, 16],
     Style[Row[{mbox, "  \[Bullet]  ", n, " \:901a"}], GrayLevel[0.4]],
     (* 上段: メール一覧 (クリックで下段 TabView へジャンプ) *)
     Pane[Grid[Prepend[
        Table[With[{i = i0, m = mails[[i0]]},
          {Dynamic[If[sel === i, Style["\[FilledRightTriangle]", $svSugLinkColor], ""]],
           "#" <> ToString[i], iSVSugDateShort[m], iSVSugFromShort[m],
           Button[Dynamic[Style[StringTake[iSVSugStrOr@Lookup[m, "Subject", "(件名なし)"], UpTo[46]],
              If[sel === i, Bold, Plain]]], sel = i, Appearance -> "Frameless",
             Alignment -> Left]}], {i0, n}],
        Style[#, Bold, GrayLevel[0.3]] & /@ {"", "#", "\:65e5\:4ed8", "\:5dee\:51fa\:4eba", "\:4ef6\:540d (\:30af\:30ea\:30c3\:30af\:3067\:8868\:793a)"}],
        Frame -> All, FrameStyle -> GrayLevel[0.8], Alignment -> {Left, Center},
        Background -> {None, {GrayLevel[0.95]}}],
       {UpTo[700], UpTo[190]}, Scrollbars -> {False, Automatic}, ImageMargins -> 2],
     If[crossButtons === {}, Nothing,
       Column[Prepend[crossButtons,
          Style["\:4ed6\:30b9\:30ec\:30c3\:30c9\:3078\:306e\:53c2\:7167 (\:904e\:53bb\:30e1\:30fc\:30eb\:5f15\:7528\:306a\:3069):", Bold, GrayLevel[0.4]]]]],
     (* 下段: TabView で各メール本文 + スレッド内リンク *)
     TabView[
      Table[With[{i = i0, m = mails[[i0]], ref = orderedRefs[[i0]]},
        ToString[i] -> Column[{
          Grid[DeleteCases[{
             {Style["From:", Bold], iSVSugStrOr@Lookup[m, "From", ""]},
             {Style["To:", Bold], iSVSugStrOr@Lookup[m, "To", ""]},
             If[iSVSugStrOr@Lookup[m, "Cc", ""] =!= "", {Style["Cc:", Bold], m["Cc"]}, Nothing],
             {Style["Date:", Bold], iSVSugDateShort[m]},
             {Style["Subject:", Bold], iSVSugStrOr@Lookup[m, "Subject", ""]}}, Nothing],
            Alignment -> Left, Spacings -> {0.5, 0.3}],
          (* スレッド内ハイパーリンク (クリックで tab ジャンプ) *)
          With[{ps = Lookup[links[ref], "Parents", {}], cs = Lookup[links[ref], "Children", {}]},
           Column[DeleteCases[{
             If[ps === {}, Nothing,
               Row[Prepend[Riffle[
                  (With[{j = refToIdx[#], mt = Lookup[mailBy, #, <||>]},
                    Button[Style["#" <> ToString[j] <> " " <> iSVSugFromShort[mt] <>
                        " (" <> iSVSugDateShort[mt] <> ")", $svSugLinkColor],
                       sel = j, Appearance -> "Frameless", Method -> "Queued"]] &) /@ ps, "  "],
                 Style["\:5f15\:7528\:5143/\:89aa: ", Bold, GrayLevel[0.4]]]]],
             If[cs === {}, Nothing,
               Row[Prepend[Riffle[
                  (With[{j = refToIdx[#], mt = Lookup[mailBy, #, <||>]},
                    Button[Style["#" <> ToString[j] <> " " <> iSVSugFromShort[mt] <>
                        " (" <> iSVSugDateShort[mt] <> ")", $svSugLinkColor],
                       sel = j, Appearance -> "Frameless", Method -> "Queued"]] &) /@ cs, "  "],
                 Style["\:8fd4\:4fe1/\:88ab\:5f15\:7528: ", Bold, GrayLevel[0.4]]]]]}, Nothing]]],
          Style["\[LongDash]\[LongDash] \:672c\:6587 \[LongDash]\[LongDash]", GrayLevel[0.5]],
          Pane[StringTake[iSVSugReadableBody[Lookup[m, "Body", ""]], UpTo[maxBody]],
             {UpTo[680], UpTo[320]}, Scrollbars -> {False, Automatic}],
          If[canReply && StringQ[Lookup[m, "RecordId", Missing[]]],
            Row[{Button["\:2709 \:3053\:306e\:30e1\:30fc\:30eb\:306b\:8fd4\:4fe1",
                SourceVault`SourceVaultMailOpenReplyNotebook[m["RecordId"]],
                Appearance -> "Palette", Method -> "Queued"], "  ",
               Button["\:2709 \:5168\:54e1\:306b\:8fd4\:4fe1",
                SourceVault`SourceVaultMailOpenReplyNotebook[m["RecordId"], "ReplyAll" -> True],
                Appearance -> "Palette", Method -> "Queued"]}], Nothing]}, Spacings -> 0.8]],
       {i0, n}], Dynamic[sel], ImageSize -> {UpTo[720], UpTo[560]}],
     (* スレッド末尾: 最新メールへの返信 (maildb のみ) *)
     If[canReply && StringQ[Lookup[Last[mails], "RecordId", Missing[]]],
       With[{rid = Last[mails]["RecordId"]},
        Row[{Style["\:30b9\:30ec\:30c3\:30c9\:306b\:8fd4\:4fe1: ", Bold],
          Button["\:2709 \:6700\:65b0\:30e1\:30fc\:30eb\:3078",
            SourceVault`SourceVaultMailOpenReplyNotebook[rid], Appearance -> "Palette", Method -> "Queued"], "  ",
          Button["\:2709 \:5168\:54e1\:306b",
            SourceVault`SourceVaultMailOpenReplyNotebook[rid, "ReplyAll" -> True],
            Appearance -> "Palette", Method -> "Queued"]}]], Nothing]},
    Spacings -> 1]]]];

Options[SourceVaultMailThreadWindow] = {"Period" -> All, "CloudSafe" -> False, "Rebuild" -> False,
  "LoadLimit" -> 400, "MaxBodyChars" -> 20000, "WindowTitle" -> Automatic};
SourceVaultMailThreadWindow[mbox_String, sessionId_String, OptionsPattern[]] := Module[
  {corpus, panel, title, sessRow},
  corpus = iSVSugResolveCorpus[mbox, OptionValue["Period"], TrueQ@OptionValue["CloudSafe"],
     TrueQ@OptionValue["Rebuild"], OptionValue["LoadLimit"]];
  If[FailureQ[corpus], Return[corpus]];
  panel = SourceVaultMailThreadPanel[corpus, sessionId, "MaxBodyChars" -> OptionValue["MaxBodyChars"]];
  If[FailureQ[panel], Return[panel]];
  sessRow = Lookup[Lookup[corpus, "SessionRows", <||>], sessionId, <||>];
  title = With[{t = OptionValue["WindowTitle"]},
    If[t === Automatic, "\:2709 " <> iSVSugStrOr@Lookup[sessRow, "Subject", "\:30b9\:30ec\:30c3\:30c9"], t]];
  CreateDocument[panel, WindowTitle -> title, WindowSize -> {740, 700}]];

Options[SourceVaultMailReplyDraft] = {"Period" -> All, "CloudSafe" -> False, "Rebuild" -> False,
  "LoadLimit" -> 400, "ReplyToRef" -> Automatic, "ReplyAll" -> False};
SourceVaultMailReplyDraft[mbox_String, sessionId_String, OptionsPattern[]] := Module[
  {corpus, sessRow, mails, target, rid},
  If[ToLowerCase[StringTrim[mbox]] === "oops",
    Return[Failure["ReplyNotSupported",
      <|"MessageTemplate" -> "oops 過去ログ (ML アーカイブ) には返信できません。"|>]]];
  corpus = iSVSugResolveCorpus[mbox, OptionValue["Period"], TrueQ@OptionValue["CloudSafe"],
     TrueQ@OptionValue["Rebuild"], OptionValue["LoadLimit"]];
  If[FailureQ[corpus], Return[corpus]];
  sessRow = Lookup[Lookup[corpus, "SessionRows", <||>], sessionId, Missing[]];
  If[! AssociationQ[sessRow],
    Return[Failure["SessionNotFound",
      <|"MessageTemplate" -> "session `1` が corpus にありません。", "MessageParameters" -> {sessionId}|>]]];
  mails = SortBy[DeleteMissing[Lookup[corpus["MailByRef"], Lookup[sessRow, "MailRefs", {}]]], iSVSugSortKey];
  If[mails === {}, Return[Failure["EmptyThread", <|"MessageTemplate" -> "スレッドにメールがありません。"|>]]];
  target = With[{rt = OptionValue["ReplyToRef"]},
    If[StringQ[rt], SelectFirst[mails, Lookup[#, "MailRef", ""] === rt &, Last[mails]], Last[mails]]];
  rid = Lookup[target, "RecordId", Missing[]];
  If[! StringQ[rid], Return[Failure["NoRecordId", <|"MessageTemplate" -> "RecordId 不明で返信できません。"|>]]];
  SourceVault`SourceVaultMailComposeReply[rid, "ReplyAll" -> TrueQ@OptionValue["ReplyAll"]]];

End[]

EndPackage[]
