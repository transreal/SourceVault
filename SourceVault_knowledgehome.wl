(* ::Package:: *)

(* ============================================================
   SourceVault_knowledgehome.wl -- Cane / Knowledge Home 認知支援マイニングレイヤー
   Phase 1A: 読み取り専用 Knowledge Home ブラウザ (core / View / Window の 3 層)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault.wl"]]
   (SourceVault.wl の umbrella loader が本ファイルを自動ロードする)

   仕様: SourceVault_info/design/sourcevault_cane_knowledge_home_mining_spec_v0_7.md
         (v0.1〜v0.7 の統合。本ファイルは Phase 1A に対応)
     §3    アーキテクチャ L0(oopsseed 既存)/ L1(本層: Knowledge Home 閲覧)
     §5.1  Knowledge Home NB ブラウザ (SourceVaultBuildSearchView の KH 特化バインディング)
     §2 I-3 ベース不変(oops 原本 read-only)/ I-4 既存 gate 全経由(ReleaseContext 明示)

   Phase 1A のスコープ(r5 で条件付き承認済み):
     - topic prev/next、mail prev/index/next
     - quote 双方向(citing→cited と cited←citing の逆引き)
     - 時系列(Counter=投稿順の単調キー)
     - interaction 記録は opt-in で既定 off(Phase 1A では推定に接続しない)
     - 全 read/search API は ReleaseContext を明示引数に持ち gate を経由する。
       未登録/None context は fail-closed(deny all)。

   設計:
     - 状態は $svKHState にキャッシュ。$svOOPSState(oopsseed)の上に KH インデックスを構築。
     - core 関数は "State" オプションで合成状態を注入でき、archive 非依存で headless test 可能。
     - privacy gate は既存 SourceVaultEvaluateReleasePolicy + release context(oops-corpus /
       oops-corpus-cloud)を再利用。KH は gate を緩めない(I-2 単調安全性)。

   次 Increment 予定: 1B 追記(ULID 採番・supersede)、1C 位置づけ・近傍。
   ============================================================ *)

BeginPackage["SourceVault`"];

SourceVaultKnowledgeHomeEnsureLoaded::usage =
  "SourceVaultKnowledgeHomeEnsureLoaded[opts] は Knowledge Home 閲覧層の単一初期化。SourceVaultOOPSEnsureLoaded を" <>
  "呼び、mail/topic/quote の閲覧インデックス(TopicTimeline / MailTopics / QuoteOut / QuoteIn)を $svKHState に構築する(冪等)。" <>
  "KH 拡張(kh-item-extension)を合流する(Phase 1A では空)。閲覧用 release context(oops-corpus / oops-corpus-cloud)を登録する。" <>
  "オプション \"Force\"(既定 False)、SourceVaultOOPSEnsureLoaded に渡す \"MailFiles\"/\"TableDir\"/\"MailDir\"。戻り値 SourceVaultKnowledgeHomeStatus[]。";

SourceVaultKnowledgeHomeStatus::usage =
  "SourceVaultKnowledgeHomeStatus[] は $svKHState の要約 <|Loaded, MailCount, TopicCount, QuoteEdgeCount|> を返す。";

SourceVaultKnowledgeHomeBuildState::usage =
  "SourceVaultKnowledgeHomeBuildState[mails, opts] は mail 連想リストから KH 閲覧状態(TopicTimeline / MailTopics / " <>
  "QuoteOut / QuoteIn 等)を構築して返す純関数(archive 非依存)。EnsureLoaded の内部・合成状態注入・test に使う。" <>
  "オプション \"SurfaceIndex\"(既定 None)、\"RefLabel\"(既定 <||>)、\"QuoteEdges\"(既定 Automatic=SourceVaultBuildMailQuoteEdges[mails])、" <>
  "\"ExtensionEntries\"(既定 {})。";

SourceVaultKnowledgeHomeTopicField::usage =
  "SourceVaultKnowledgeHomeTopicField[opts] は topic item field(資料 p11 の topic item 空間)を返す。" <>
  "各 topic: <|TopicItemRef, CanonicalLabel, MailCount, FirstCounter, LastCounter|>。ReleaseContext を経由し、" <>
  "gate で deny された mail のみに現れる topic は除外する(private topic label 漏洩防止, §2 I-4)。" <>
  "オプション \"ReleaseContext\"(既定 \"oops-corpus\")、\"Limit\"(既定 200)、\"MinMails\"(既定 1)、\"State\"(Automatic)。" <>
  "\"AsDataset\"(既定 False)で Dataset 版。";

SourceVaultKnowledgeHomeParagraphs::usage =
  "SourceVaultKnowledgeHomeParagraphs[topicRef, opts] は topic を担う mail の時系列(Counter 昇順)を返す。prev/next の基盤。" <>
  "各要素: <|MailCounter, MailRef, Subject, From, Date, Released, (Paragraphs|Why)|>。Paragraphs は gate 許可時のみ、" <>
  "各 <|Index, Kind, Text|>(Text は SourceVaultStripOOPSMarkers 済)。deny 時は Released->False + Why、本文/話題を出さない。" <>
  "オプション \"ReleaseContext\"(既定 \"oops-corpus\")、\"State\"(Automatic)、\"IncludeParagraphs\"(既定 True)。";

SourceVaultKnowledgeHomeMail::usage =
  "SourceVaultKnowledgeHomeMail[counter, opts] は 1 mail の閲覧 core を返す(資料 p3 の [prev]/[index]/[next] と引用双方向)。" <>
  "<|MailCounter, Subject, From, To, Date, MlName, Released, (Paragraphs, TopicRefs, TopicLabels, " <>
  "QuotesOut(この mail が引用する元), QuotedBy(この mail を引用する後続), PrevCounter, NextCounter | Why)|>。" <>
  "QuotesOut/QuotedBy は双方向リンク(citing→cited)。deny 時は本文/話題/引用先ラベルを出さない。" <>
  "オプション \"ReleaseContext\"(既定 \"oops-corpus\")、\"State\"(Automatic)。";

SourceVaultKnowledgeHomeFollowLink::usage =
  "SourceVaultKnowledgeHomeFollowLink[ref, opts] は KH 内リンク(svtopic:.../ sv://mail/N / svmailpara:...)を解決して" <>
  "遷移先 core を返す(topic→時系列 / mail→mail core)。View の click ハンドラの基盤。ReleaseContext 経由。";

SourceVaultKnowledgeHomeView::usage =
  "SourceVaultKnowledgeHomeView[entry, opts] は entry(topic ref | mail Counter | \"sv://mail/N\" | svmailpara:)を" <>
  "NB ハイパーテキストとして描画する(core/View/Window の View 層)。topic item はボタン化、click で時系列へ。" <>
  "引用は双方向リンク。gate 未許可 node は low-leak placeholder。オプション \"ReleaseContext\"(既定 \"oops-corpus\")、" <>
  "\"Window\"(既定 False。True で CreateDocument)、\"RecordInteraction\"(既定 False。opt-in。§6.8 行動ログ)、\"State\"(Automatic)。";

(* ---- Phase 1B: 非破壊追記(ULID 採番 / ki alias / CAS / supersede / undo / offline merge) ---- *)
SourceVaultKnowledgeHomeMintItem::usage =
  "SourceVaultKnowledgeHomeMintItem[label, opts] は Knowledge Home 拡張の topic item を採番する(§4.2)。" <>
  "正準 ID は衝突しない ULID(\"svtopic:kh:<ULID>\")、表示 alias は \"ki <n>\"(KH ローカル counter を .lockdir + " <>
  "compare-and-swap で発番)。alias 履歴を保持し、原本 index は不変。KnowledgeHomeTopicItemMinted を kh-events.jsonl に追記。" <>
  "オプション \"Root\"(Automatic=<PrivateVault>/knowledgehome)、\"OwnerRef\"、\"PrivacyLevel\"(既定 0.6)、\"AliasBase\"(既定 10000)、" <>
  "\"NoAlias\"(既定 False)、\"DeviceID\"、\"CreatedAtUTC\"、\"Persist\"(既定 True)。戻り値は minted entry。";
SourceVaultKnowledgeHomeAppend::usage =
  "SourceVaultKnowledgeHomeAppend[body, opts] は oops 文法の追記パラグラフを非破壊に追加する(§5.2)。" <>
  "ParagraphRef=\"svkhpara:<ULID>\"、明示マーカー(◎○・[ns id])と引用マーカー(-*- Quote (from N) -*-)を検証・抽出し、" <>
  "KnowledgeHomeParagraphAdded を kh-events.jsonl に追記。oops 原本は read-only。" <>
  "オプション \"Topics\"(追加 topic refs)、\"Quotes\"(引用先 refs)、\"PrivacyLevel\"(既定 0.6)、\"Tags\"、\"Author\"、" <>
  "\"CognitiveContextRef\"(§4.3 の local-only 参照 ID。既定 Missing)、\"Root\"、\"DeviceID\"、\"CreatedAtUTC\"、\"SupersedesRef\"、\"Persist\"(True)。";
SourceVaultKnowledgeHomeAppendTemplate::usage =
  "SourceVaultKnowledgeHomeAppendTemplate[] は追記用の「引数入り式テンプレート 1 セル」(Defer 式)を返す。" <>
  "フォーム的セル編集でなく評価可能式テンプレートを正とする方針(式中心 UI)。";
SourceVaultKnowledgeHomeSupersede::usage =
  "SourceVaultKnowledgeHomeSupersede[paragraphRef, newBody, opts] は既存 KH パラグラフを訂正する(非破壊)。" <>
  "新パラグラフを追記し、旧を Superseded にする(旧は log に残る)。戻り値 <|OldRef, NewRef, Event|>。opts は Append と同じ。";
SourceVaultKnowledgeHomeUndoLast::usage =
  "SourceVaultKnowledgeHomeUndoLast[opts] は直近の(自分の)追記を supersede で取り消す(Retracted。非破壊)。" <>
  "オプション \"Author\"(既定 owner)、\"Root\"、\"DeviceID\"、\"Persist\"(True)。戻り値 <|RetractedRef, Event|>。";
SourceVaultKnowledgeHomeExtension::usage =
  "SourceVaultKnowledgeHomeExtension[opts] は kh-events.jsonl を replay して拡張 projection を返す(再生成可能)。" <>
  "<|Paragraphs(active), Topics(minted map), AliasMap(alias->ref), TopicKHTimeline(topicRef->{para...}), EventCount|>。" <>
  "オプション \"Root\"(Automatic)、\"Events\"(明示注入=archive/disk 非依存。test 用)。";
SourceVaultKnowledgeHomeMergeExtensions::usage =
  "SourceVaultKnowledgeHomeMergeExtensions[eventLists, opts] は複数デバイスの event 列を合流して replay する(offline merge)。" <>
  "正準 ULID は衝突しないので paragraph は無傷。alias(ki n)衝突は正準 ID を保ったまま alias を振り直し AliasHistory に記録。" <>
  "戻り値 <|Projection, AliasReassignments|>。";
SourceVaultKnowledgeHomeSearch::usage =
  "SourceVaultKnowledgeHomeSearch[query, opts] は追記済 KH パラグラフを BM25(SourceVaultBuildLexicalStats/LexicalRank)で検索する。" <>
  "ReleaseContext gate を経由し、deny パラグラフは返さない。オプション \"ReleaseContext\"(既定 \"oops-corpus\")、\"Extension\"(Automatic)、" <>
  "\"Root\"、\"Limit\"(既定 10)。戻り値 {<|ParagraphRef, Score, Snippet, TopicRefs|>...}。「追記→検索」の往復。";

Begin["`Private`"];

(* ------------------------------------------------------------
   状態: $svKHState を $svOOPSState の上に構築(冪等・注入可能)
   ------------------------------------------------------------ *)

If[! AssociationQ[SourceVault`$svKHState], SourceVault`$svKHState = <||>];

$svKHPrivateListPattern = RegularExpression["(?i)ura|under\\s*ground"];

(* mail の privacy source assoc を作る(gate 入力)。
   受信者由来(SourceVaultMailRecipientPrivacy, 公開 API)＋ list 名由来を max/union。 *)
iKHMailSource[mail_Association] := Module[{rp, pl, tags, mlName},
  rp = Quiet@Check[SourceVaultMailRecipientPrivacy[mail], <||>];
  pl = Lookup[rp, "PrivacyLevel", 0.0];
  tags = Lookup[rp, "Tags", {}];
  mlName = ToString@Lookup[mail, "MlName", ""];
  If[StringQ[mlName] && StringLength[mlName] > 0 && StringContainsQ[mlName, $svKHPrivateListPattern],
    pl = Max[pl, 0.6];
    tags = Union[tags, {"PrivateML", "NoCloudLLM", "NoPublicExport"}]];
  <|"PrivacyLevel" -> pl, "Tags" -> tags, "State" -> "Published"|>];

(* source assoc(PrivacyLevel/Tags/State)に対する gate 判定。未登録 context は fail-closed。 *)
iKHGateSource[src_Association, ctx_] := Module[{res},
  If[! (StringQ[ctx] && MemberQ[SourceVaultListReleaseContexts[], ctx]),
    Return[<|"Permit" -> False, "Why" -> {"UnknownReleaseContext"}|>]];
  res = Quiet@Check[SourceVaultEvaluateReleasePolicy[src, ctx], $Failed];
  If[! AssociationQ[res], Return[<|"Permit" -> False, "Why" -> {"GateError"}|>]];
  <|"Permit" -> (Lookup[res, "Decision", "Deny"] === "Permit"),
    "Why" -> Lookup[res, "Why", {}]|>];

(* mail の gate: 受信者/list 由来 privacy を源にする *)
iKHGate[mail_Association, ctx_] := iKHGateSource[iKHMailSource[mail], ctx];

(* 閲覧用 release context を冪等登録(oopsseed の private helper と同一だが本層でも保証する) *)
iKHEnsureReleaseContexts[] := (
  If[! MemberQ[SourceVaultListReleaseContexts[], "oops-corpus"],
    SourceVaultRegisterReleaseContext["oops-corpus", <|"MaxPrivacyLevel" -> 1.0|>]];
  If[! MemberQ[SourceVaultListReleaseContexts[], "oops-corpus-cloud"],
    SourceVaultRegisterReleaseContext["oops-corpus-cloud",
      <|"MaxPrivacyLevel" -> 1.0, "DenyTags" -> {"NoCloudLLM", "NoPublicExport", "PrivateML"}|>]];);

(* mail の topic refs(明示 ◎○・ 最高品質 ＋ seed-matched)。ラベルも収集 *)
iKHMailTopics[mail_Association, sidx_] := Module[{body, expl, assignRows, seedm, explRefs, seedRefs, refs, labels},
  body = ToString@Lookup[mail, "Body", ""];
  expl = Quiet@Check[SourceVaultExtractExplicitTopics[body], {}];
  assignRows = If[sidx === None || MissingQ[sidx] || ! AssociationQ[sidx], {},
    Quiet@Check[SourceVaultAssignParagraphTopics[SourceVaultParseMailParagraphs[body], sidx], {}]];
  seedm = Flatten[Lookup[#, "Assignments", {}] & /@ assignRows];  (* 各 <|TopicItemRef, CanonicalLabel, ...|> *)
  explRefs = #["TopicItemRef"] & /@ expl;
  seedRefs = Lookup[#, "TopicItemRef", Nothing] & /@ seedm;
  refs = DeleteDuplicates@DeleteMissing@DeleteCases[Join[explRefs, seedRefs], Nothing];
  (* 空ラベル・Missing は落とす(seed 辞書の正準ラベルを BuildState で shadow しないため)。
     Select は Association に適用して値を見る(rule のリストに適用しない)。 *)
  labels = Association@DeleteCases[
    Join[
      (#["TopicItemRef"] -> Lookup[#, "CanonicalLabel", ""]) & /@ expl,
      (Lookup[#, "TopicItemRef", Missing[]] -> Lookup[#, "CanonicalLabel", ""]) & /@ seedm],
    (_?MissingQ -> _)];
  labels = Select[labels, StringQ[#] && StringTrim[#] =!= "" &];
  <|"Refs" -> refs, "Labels" -> labels|>];

iKHMailRef[counter_] := "sv://mail/" <> ToString[counter];
iKHCounterOfRef[ref_] := Module[{m = StringCases[ToString[ref], "sv://mail/" ~~ n : DigitCharacter .. :> FromDigits[n]]},
  If[m === {}, Missing["NotMailRef"], First[m]]];

Options[SourceVaultKnowledgeHomeBuildState] = {"SurfaceIndex" -> None, "RefLabel" -> <||>,
  "QuoteEdges" -> Automatic, "ExtensionEntries" -> {}, "Extension" -> None};
SourceVaultKnowledgeHomeBuildState[mails_List, OptionsPattern[]] := Module[
  {sidx, refLabel, edges, byCounter, counters, mailTopics, topicTimeline, topicLabel, quoteOut, quoteIn,
   ext, khTimeline},
  sidx = OptionValue["SurfaceIndex"];
  refLabel = OptionValue["RefLabel"];
  edges = OptionValue["QuoteEdges"] /. Automatic :> Quiet@Check[SourceVaultBuildMailQuoteEdges[mails], {}];
  byCounter = Association[(Lookup[#, "Counter", Missing[]] -> #) & /@ mails];
  KeyDropFrom[byCounter, {Missing[]}];
  counters = Sort[Keys[byCounter]];
  mailTopics = Association[(# -> iKHMailTopics[byCounter[#], sidx]) & /@ counters];
  (* topic -> 時系列 counters(昇順)＋ラベル *)
  topicTimeline = <||>; topicLabel = <||>;
  Scan[Function[c,
    Module[{mt = mailTopics[c]},
      Scan[Function[ref,
        topicTimeline[ref] = Append[Lookup[topicTimeline, ref, {}], c];
        (* ラベル: 明示/seed-matched の非空ラベル(iKHMailTopics で空は除去済)を優先、
           無ければ seed 辞書 refLabel、最後に ref 文字列。空文字が正準ラベルを覆わないよう
           まだ有効ラベルが無い場合のみ上書きする。 *)
        Module[{cur = Lookup[topicLabel, ref, ""], cand},
          If[! StringQ[cur] || StringTrim[cur] === "",
            (* 優先: 明示/seed-matched の非空ラベル -> seed 辞書 refLabel -> ref 文字列 *)
            cand = Lookup[mt["Labels"], ref, ""];
            If[! StringQ[cand] || StringTrim[cand] === "", cand = Lookup[refLabel, ref, ""]];
            If[! StringQ[cand] || StringTrim[cand] === "", cand = ToString[ref]];
            topicLabel[ref] = cand]]],
        mt["Refs"]]]], counters];
  topicTimeline = Sort /@ topicTimeline;
  (* quote 双方向: Out = この mail が引用(From==C→To)、In = この mail を引用(To==C←From) *)
  quoteOut = <||>; quoteIn = <||>;
  Scan[Function[e,
    Module[{fc = iKHCounterOfRef[e["FromMailRef"]], tc = iKHCounterOfRef[e["ToMailRef"]]},
      If[! MissingQ[fc],
        quoteOut[fc] = Append[Lookup[quoteOut, fc, {}],
          <|"To" -> e["ToMailRef"], "ToCounter" -> tc, "Kind" -> e["QuoteKind"], "EdgeId" -> e["QuoteEdgeId"]|>]];
      If[! MissingQ[tc],
        quoteIn[tc] = Append[Lookup[quoteIn, tc, {}],
          <|"From" -> e["FromMailRef"], "FromCounter" -> fc, "Kind" -> e["QuoteKind"], "EdgeId" -> e["QuoteEdgeId"]|>]]]],
    edges];
  (* Phase 1B: extension projection を合流。minted topic ラベル + KH パラグラフ時系列 *)
  ext = OptionValue["Extension"];
  khTimeline = <||>;
  If[AssociationQ[ext],
    khTimeline = Lookup[ext, "TopicKHTimeline", <||>];
    (* minted topic の正準ラベルを補完(mail 由来ラベルは上書きしない) *)
    Scan[Function[ref,
      Module[{lbl = Lookup[Lookup[ext["Topics"], ref, <||>], "CanonicalLabel", ""]},
        If[StringQ[lbl] && StringTrim[lbl] =!= "" &&
            (! KeyExistsQ[topicLabel, ref] || StringTrim[ToString@topicLabel[ref]] === ""),
          topicLabel[ref] = lbl]]],
      Keys[Lookup[ext, "Topics", <||>]]];
    (* KH-only topic のラベルも(minted でない外部 ref を KH para が担う場合) *)
    Scan[Function[ref, If[! KeyExistsQ[topicLabel, ref], topicLabel[ref] = ToString[ref]]],
      Keys[khTimeline]]];
  <|"Loaded" -> True, "MailByCounter" -> byCounter, "Counters" -> counters,
    "SurfaceIndex" -> sidx, "RefLabel" -> refLabel,
    "MailTopics" -> mailTopics, "TopicTimeline" -> topicTimeline, "TopicLabel" -> topicLabel,
    "QuoteOut" -> quoteOut, "QuoteIn" -> quoteIn, "ExtensionEntries" -> OptionValue["ExtensionEntries"],
    "Extension" -> ext, "TopicKHTimeline" -> khTimeline|>];

Options[SourceVaultKnowledgeHomeEnsureLoaded] = {"Force" -> False, "MailFiles" -> All,
  "TableDir" -> Automatic, "MailDir" -> Automatic};
SourceVaultKnowledgeHomeEnsureLoaded[OptionsPattern[]] := Module[
  {oopsStatus, st},
  If[TrueQ[SourceVault`$svKHState["Loaded"]] && ! TrueQ[OptionValue["Force"]],
    Return[SourceVaultKnowledgeHomeStatus[]]];
  oopsStatus = SourceVaultOOPSEnsureLoaded["Force" -> OptionValue["Force"],
    "MailFiles" -> OptionValue["MailFiles"], "TableDir" -> OptionValue["TableDir"],
    "MailDir" -> OptionValue["MailDir"]];
  If[FailureQ[oopsStatus], Return[oopsStatus]];
  iKHEnsureReleaseContexts[];
  st = SourceVault`$svOOPSState;
  SourceVault`$svKHState = SourceVaultKnowledgeHomeBuildState[Lookup[st, "Mails", {}],
    "SurfaceIndex" -> Lookup[st, "SurfaceIndex", None], "RefLabel" -> Lookup[st, "RefLabel", <||>],
    "QuoteEdges" -> Lookup[st, "QuoteEdges", Automatic],
    "Extension" -> Quiet@Check[SourceVaultKnowledgeHomeExtension[], None]];  (* 追記分を合流 *)
  SourceVaultKnowledgeHomeStatus[]];

SourceVaultKnowledgeHomeStatus[] := If[! TrueQ[SourceVault`$svKHState["Loaded"]],
  <|"Loaded" -> False|>,
  <|"Loaded" -> True,
    "MailCount" -> Length[SourceVault`$svKHState["Counters"]],
    "TopicCount" -> Length[SourceVault`$svKHState["TopicTimeline"]],
    "QuoteEdgeCount" -> Total[Length /@ Values[SourceVault`$svKHState["QuoteOut"]]]|>];

(* 状態解決: 注入 (Automatic=$svKHState、既定は EnsureLoaded) *)
iKHState[stOpt_] := Which[
  AssociationQ[stOpt] && TrueQ[stOpt["Loaded"]], stOpt,
  TrueQ[SourceVault`$svKHState["Loaded"]], SourceVault`$svKHState,
  True, (SourceVaultKnowledgeHomeEnsureLoaded[]; SourceVault`$svKHState)];

(* context に対する可視 counter 集合(gate 経由) *)
iKHVisibleCounters[st_Association, ctx_] := Select[st["Counters"],
  iKHGate[st["MailByCounter"][#], ctx]["Permit"] &];

(* ------------------------------------------------------------
   §5.1 core: topic field / paragraphs(時系列) / mail(双方向)
   ------------------------------------------------------------ *)

Options[SourceVaultKnowledgeHomeTopicField] = {"ReleaseContext" -> "oops-corpus", "Limit" -> 200,
  "MinMails" -> 1, "State" -> Automatic, "AsDataset" -> False};
SourceVaultKnowledgeHomeTopicField[OptionsPattern[]] := Module[
  {st, ctx, vis, khTL, allRefs, rows},
  st = iKHState[OptionValue["State"]];
  ctx = OptionValue["ReleaseContext"];
  iKHEnsureReleaseContexts[];
  vis = iKHVisibleCounters[st, ctx];  (* private topic label 漏洩防止: deny mail は除外 *)
  khTL = Lookup[st, "TopicKHTimeline", <||>];
  allRefs = DeleteDuplicates@Join[Keys[st["TopicTimeline"]], Keys[khTL]];
  rows = Map[Function[ref,
    Module[{visC = Intersection[Lookup[st["TopicTimeline"], ref, {}], vis],
            khVis = Select[Lookup[khTL, ref, {}], iKHGateSource[iKHParaSource[#], ctx]["Permit"] &],
            total},
      total = Length[visC] + Length[khVis];
      If[total < OptionValue["MinMails"], Nothing,
        <|"TopicItemRef" -> ref, "CanonicalLabel" -> Lookup[st["TopicLabel"], ref, ToString[ref]],
          "MailCount" -> Length[visC], "KHCount" -> Length[khVis], "TotalCount" -> total,
          "FirstCounter" -> If[visC === {}, Missing[], Min[visC]],
          "LastCounter" -> If[visC === {}, Missing[], Max[visC]]|>]]],
    allRefs];
  rows = Take[ReverseSortBy[rows, #["TotalCount"] &], UpTo[OptionValue["Limit"]]];
  If[TrueQ[OptionValue["AsDataset"]], Dataset[rows], rows]];

Options[SourceVaultKnowledgeHomeParagraphs] = {"ReleaseContext" -> "oops-corpus",
  "State" -> Automatic, "IncludeParagraphs" -> True};
SourceVaultKnowledgeHomeParagraphs[topicRef_, OptionsPattern[]] := Module[
  {st, ctx, counters},
  st = iKHState[OptionValue["State"]];
  ctx = OptionValue["ReleaseContext"];
  iKHEnsureReleaseContexts[];
  counters = Lookup[st["TopicTimeline"], topicRef, {}];  (* 昇順=時系列。prev/next 基盤 *)
  (* mail 時系列 + KH 追記パラグラフ(gate 経由) *)
  Join[
    Map[Function[c, iKHMailTimelineRow[st, c, ctx, OptionValue["IncludeParagraphs"]]], counters],
    Map[Function[p, iKHKHParaRow[p, ctx, OptionValue["IncludeParagraphs"]]],
      Lookup[Lookup[st, "TopicKHTimeline", <||>], topicRef, {}]]]];

(* KH 追記パラグラフの時系列行(mail と同形。gate で deny なら本文を出さない) *)
iKHKHParaRow[p_Association, ctx_, includeParas_] := Module[{gate, out},
  gate = iKHGateSource[iKHParaSource[p], ctx];
  out = <|"ParagraphRef" -> Lookup[p, "ParagraphRef", ""], "Kind" -> "KHAppend",
    "Subject" -> "", "From" -> Lookup[p, "Author", ""], "Date" -> Lookup[p, "CreatedAtUTC", ""],
    "Released" -> gate["Permit"]|>;
  If[gate["Permit"],
    If[TrueQ[includeParas], out["Body"] = Lookup[p, "Body", ""]],
    out["Why"] = gate["Why"]];
  out];

iKHMailTimelineRow[st_Association, c_, ctx_, includeParas_] := Module[{mail, gate, out},
  mail = st["MailByCounter"][c];
  gate = iKHGate[mail, ctx];
  out = <|"MailCounter" -> c, "MailRef" -> iKHMailRef[c],
    "Subject" -> Lookup[mail, "Subject", ""], "From" -> Lookup[mail, "From", ""],
    "Date" -> Lookup[mail, "Date", ""], "Released" -> gate["Permit"]|>;
  If[gate["Permit"],
    If[TrueQ[includeParas],
      out["Paragraphs"] = iKHParagraphs[mail]],
    out["Why"] = gate["Why"]];  (* deny: 本文/話題を出さない *)
  out];

iKHParagraphs[mail_Association] := Module[{paras},
  paras = Quiet@Check[SourceVaultParseMailParagraphs[ToString@Lookup[mail, "Body", ""]], {}];
  Map[<|"Index" -> Lookup[#, "Index", 0], "Kind" -> Lookup[#, "Kind", "Prose"],
    "Text" -> SourceVaultStripOOPSMarkers[ToString@Lookup[#, "Text", ""]]|> &, paras]];

Options[SourceVaultKnowledgeHomeMail] = {"ReleaseContext" -> "oops-corpus", "State" -> Automatic};
SourceVaultKnowledgeHomeMail[counter_, OptionsPattern[]] := Module[
  {st, ctx, c, mail, gate, mt, out, idx, prevC, nextC, qOut, qIn},
  st = iKHState[OptionValue["State"]];
  ctx = OptionValue["ReleaseContext"];
  iKHEnsureReleaseContexts[];
  c = If[StringQ[counter], iKHCounterOfRef[counter], counter];
  If[MissingQ[c] || ! KeyExistsQ[st["MailByCounter"], c],
    Return[Missing["MailNotFound"]]];
  mail = st["MailByCounter"][c];
  gate = iKHGate[mail, ctx];
  (* prev/index/next は corpus 全体の counter 順(資料 p3) *)
  idx = FirstPosition[st["Counters"], c, {0}][[1]];
  prevC = If[idx > 1, st["Counters"][[idx - 1]], Missing[]];
  nextC = If[idx < Length[st["Counters"]] && idx > 0, st["Counters"][[idx + 1]], Missing[]];
  out = <|"MailCounter" -> c, "Subject" -> Lookup[mail, "Subject", ""],
    "From" -> Lookup[mail, "From", ""], "To" -> Lookup[mail, "To", ""],
    "Date" -> Lookup[mail, "Date", ""], "MlName" -> Lookup[mail, "MlName", ""],
    "Released" -> gate["Permit"], "PrevCounter" -> prevC, "NextCounter" -> nextC|>;
  If[! gate["Permit"], out["Why"] = gate["Why"]; Return[out]];
  mt = st["MailTopics"][c];
  (* 引用双方向。相手 mail の可視性も gate し、deny 先はラベルを出さず ref のみ(low-leak) *)
  qOut = iKHGateQuoteLinks[st, Lookup[st["QuoteOut"], c, {}], "To", "ToCounter", ctx];
  qIn = iKHGateQuoteLinks[st, Lookup[st["QuoteIn"], c, {}], "From", "FromCounter", ctx];
  out["Paragraphs"] = iKHParagraphs[mail];
  out["TopicRefs"] = mt["Refs"];
  out["TopicLabels"] = mt["Labels"];
  out["QuotesOut"] = qOut;
  out["QuotedBy"] = qIn;
  out];

(* 引用リンクの相手 subject は相手 mail が可視のときだけ付ける(漏洩防止) *)
iKHGateQuoteLinks[st_Association, links_List, refKey_, counterKey_, ctx_] := Map[Function[lk,
  Module[{tc = Lookup[lk, counterKey, Missing[]], subj = Missing[], vis = False, m},
    If[! MissingQ[tc] && KeyExistsQ[st["MailByCounter"], tc],
      m = st["MailByCounter"][tc];
      vis = iKHGate[m, ctx]["Permit"];
      If[vis, subj = Lookup[m, "Subject", ""]]];
    <|"Ref" -> lk[refKey], "Counter" -> tc, "Kind" -> Lookup[lk, "Kind", ""],
      "EdgeId" -> Lookup[lk, "EdgeId", ""], "TargetReleased" -> vis, "Subject" -> subj|>]],
  links];

SourceVaultKnowledgeHomeFollowLink[ref_, opts : OptionsPattern[]] := Module[{r = ToString[ref], c},
  Which[
    StringMatchQ[r, "svtopic:" ~~ ___],
      <|"Kind" -> "TopicTimeline", "TopicItemRef" -> r,
        "Timeline" -> SourceVaultKnowledgeHomeParagraphs[r, opts]|>,
    StringMatchQ[r, "sv://mail/" ~~ ___],
      c = iKHCounterOfRef[r];
      <|"Kind" -> "Mail", "MailCounter" -> c, "Mail" -> SourceVaultKnowledgeHomeMail[c, opts]|>,
    StringMatchQ[r, "svmailpara:" ~~ ___],
      <|"Kind" -> "Paragraph", "ParagraphRef" -> r|>,  (* 1B で解決強化 *)
    True, Missing["UnresolvableRef"]]];
Options[SourceVaultKnowledgeHomeFollowLink] = Options[SourceVaultKnowledgeHomeMail];

(* ------------------------------------------------------------
   §5.1 View / Window 層(NB ハイパーテキスト。FE 依存)
   ------------------------------------------------------------ *)

Options[SourceVaultKnowledgeHomeView] = {"ReleaseContext" -> "oops-corpus", "Window" -> False,
  "RecordInteraction" -> False, "State" -> Automatic};
SourceVaultKnowledgeHomeView[entry_, OptionsPattern[]] := Module[
  {ctx, st, r, panel},
  ctx = OptionValue["ReleaseContext"];
  st = iKHState[OptionValue["State"]];
  r = ToString[entry];
  panel = Which[
    StringMatchQ[r, "svtopic:" ~~ ___],
      iKHRenderTopic[st, r, ctx, OptionValue["RecordInteraction"]],
    IntegerQ[entry] || StringMatchQ[r, "sv://mail/" ~~ ___],
      iKHRenderMail[st, If[IntegerQ[entry], entry, iKHCounterOfRef[r]], ctx, OptionValue["RecordInteraction"]],
    True,  (* 検索クエリ文字列 -> スレッド検索(既存)へ委譲 *)
      iKHRenderQuery[r, ctx]];
  If[TrueQ[OptionValue["Window"]], CreateDocument[panel, WindowTitle -> "Knowledge Home", WindowSize -> {760, 720}], panel]];

iKHMaybeRecord[record_, action_, target_] := If[TrueQ[record],
  Quiet@Check[SourceVaultRecordTopicItemInteraction[
    <|"ActionKind" -> action, "TargetRef" -> target, "Actor" -> "sventity:owner:imai"|>], Null]];

iKHTopicButton[st_, ref_, ctx_, record_] := Button[
  Style[Lookup[st["TopicLabel"], ref, ToString[ref]], RGBColor[0.1, 0.3, 0.7]],
  (iKHMaybeRecord[record, "FollowedLink", ref];
   CreateDocument[iKHRenderTopic[st, ref, ctx, record], WindowTitle -> "Topic: " <> Lookup[st["TopicLabel"], ref, ref],
     WindowSize -> {760, 720}]),
  Appearance -> "Frameless"];

iKHMailButton[st_, c_, ctx_, record_, label_] := Button[Style[label, RGBColor[0.1, 0.3, 0.7]],
  (iKHMaybeRecord[record, "FollowedLink", iKHMailRef[c]];
   CreateDocument[iKHRenderMail[st, c, ctx, record], WindowTitle -> "oops: " <> ToString[c],
     WindowSize -> {760, 720}]),
  Appearance -> "Frameless"];

iKHRenderTopic[st_, ref_, ctx_, record_] := Module[{rows},
  iKHMaybeRecord[record, "Viewed", ref];
  rows = SourceVaultKnowledgeHomeParagraphs[ref, "ReleaseContext" -> ctx, "State" -> st, "IncludeParagraphs" -> False];
  Column[{
    Style["Topic: " <> Lookup[st["TopicLabel"], ref, ToString[ref]], Bold, 16],
    Style[ref <> "  (" <> ToString[Length[rows]] <> " 通)", GrayLevel[0.5]],
    Style["時系列 (prev/next):", Bold],
    Grid[Prepend[
      Map[Function[row, {iKHMailButton[st, row["MailCounter"], ctx, record, ToString[row["MailCounter"]]],
        If[TrueQ[row["Released"]], Style[row["Subject"], 12], Style["(非公開)", GrayLevel[0.6], Italic]],
        Style[ToString@row["Date"], 10, GrayLevel[0.5]]}], rows],
      Style[#, Bold] & /@ {"oops", "Subject", "Date"}],
      Frame -> All, Alignment -> {Left, Center}, Background -> {None, {LightBlue, None}}]},
    Spacings -> 1]];

iKHRenderMail[st_, c_, ctx_, record_] := Module[{d},
  d = SourceVaultKnowledgeHomeMail[c, "ReleaseContext" -> ctx, "State" -> st];
  If[MissingQ[d], Return[Style["mail not found: " <> ToString[c], Red]]];
  iKHMaybeRecord[record, "Viewed", iKHMailRef[c]];
  If[! TrueQ[d["Released"]],
    Return[Column[{Style["oops: " <> ToString[c], Bold, 16],
      Framed[Style["この mail は現在の release context では非公開です。 " <> StringRiffle[d["Why"], ", "],
        GrayLevel[0.5], Italic], Background -> GrayLevel[0.95]]}]]];
  Column[{
    Row[{iKHNav[st, d["PrevCounter"], ctx, record, "[prev]"], " / [index] / ",
      iKHNav[st, d["NextCounter"], ctx, record, "[next]"]}],
    Style["oops: " <> ToString[c] <> "  " <> ToString[d["Subject"]], Bold, 16],
    Style[Row[{"From: ", d["From"], "   ", d["Date"]}], GrayLevel[0.45], 11],
    If[d["TopicRefs"] =!= {},
      Row[Prepend[Riffle[iKHTopicButton[st, #, ctx, record] & /@ d["TopicRefs"], "  "],
        Style["話題: ", Bold]]], Nothing],
    Style["本文:", Bold],
    Column[(Framed[Style[#["Text"], 11],
        FrameStyle -> If[#["Kind"] === "Quote", RGBColor[0.85, 0.4, 0.2], LightGray],
        Background -> If[#["Kind"] === "Quote", RGBColor[0.98, 0.95, 0.92], White]] & /@
      Select[d["Paragraphs"], StringLength[StringTrim[#["Text"]]] > 0 &])],
    If[d["QuotesOut"] =!= {}, iKHQuoteBlock[st, d["QuotesOut"], "引用元 (この mail が引用) →", ctx, record], Nothing],
    If[d["QuotedBy"] =!= {}, iKHQuoteBlock[st, d["QuotedBy"], "← 被引用 (この mail を引用)", ctx, record], Nothing]},
    Spacings -> 1]];

iKHNav[st_, c_, ctx_, record_, label_] := If[MissingQ[c], Style[label, GrayLevel[0.7]],
  iKHMailButton[st, c, ctx, record, label]];

iKHQuoteBlock[st_, links_, title_, ctx_, record_] := Column[{
  Style[title, Bold, GrayLevel[0.3]],
  Column[Map[Function[lk,
    If[MissingQ[lk["Counter"]] || ! KeyExistsQ[st["MailByCounter"], lk["Counter"]],
      Style["→ " <> ToString[lk["Ref"]] <> " (" <> ToString[lk["Kind"]] <> ")", 10, GrayLevel[0.5]],
      If[TrueQ[lk["TargetReleased"]],
        Row[{iKHMailButton[st, lk["Counter"], ctx, record,
          "→ " <> ToString[lk["Counter"]] <> ": " <> ToString[lk["Subject"]]],
          Style[" (" <> ToString[lk["Kind"]] <> ")", 9, GrayLevel[0.6]]}],
        Style["→ " <> ToString[lk["Counter"]] <> " (非公開)", 10, GrayLevel[0.6]]]]],
    links]]}];

iKHRenderQuery[q_String, ctx_] := Module[{cloud},
  cloud = (ctx === "oops-corpus-cloud");
  Column[{Style["検索: " <> q, Bold, 14],
    SourceVaultOOPSSearchThreads[q, "CloudSafe" -> cloud]}]];

(* ============================================================
   Phase 1B: 非破壊追記(ULID / ki alias / CAS / supersede / undo / offline merge)
   ============================================================ *)

(* ---- ULID(48-bit ms timestamp + 80-bit randomness, Crockford base32) ---- *)
$svKHCrockford = Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"];
iKHCrockford[n_Integer, len_Integer] := Module[{d = {}, x = n},
  Do[PrependTo[d, $svKHCrockford[[Mod[x, 32] + 1]]]; x = Quotient[x, 32], {len}];
  StringJoin[d]];
iKHUnixMillis[] := Module[{t = AbsoluteTime[] - AbsoluteTime[{1970, 1, 1, 0, 0, 0}, TimeZone -> 0]},
  Round[t*1000]];
iKHULID[] := Module[{ms = iKHUnixMillis[], rnd},
  rnd = FromDigits[StringTake[StringDelete[CreateUUID[], "-"], 20], 16];
  iKHCrockford[ms, 10] <> iKHCrockford[Mod[rnd, 32^16], 16]];

iKHNowUTC[] := DateString[Now, {"Year", "-", "Month", "-", "Day", "T",
  "Hour", ":", "Minute", ":", "Second", "Z"}, TimeZone -> 0];
iKHDevice[] := StringReplace[ToString[$MachineName], Except[WordCharacter | "-"] -> "_"];

(* ---- KH extension store(正準 = kh-events.jsonl。UTF-8 バイトで JSONL 二重エンコード回避) ---- *)
iKHRoot[rootOpt_] := Module[{r},
  r = rootOpt /. Automatic :> Module[{pv = SourceVaultRoot["PrivateVault"]},
    If[StringQ[pv], FileNameJoin[{pv, "knowledgehome"}], Missing["PrivateVaultUnresolved"]]];
  If[StringQ[r] && ! DirectoryQ[r], Quiet@CreateDirectory[r, CreateIntermediateDirectories -> True]];
  r];
iKHEventsPath[root_] := FileNameJoin[{root, "kh-events.jsonl"}];
iKHCounterPath[root_] := FileNameJoin[{root, "kh-alias.counter"}];

(* Missing を Null に正規化して RawJSON バイト化(UTF-8 単一エンコード) *)
iKHNormalizeForJSON[x_] := x /. m_Missing :> Null;
iKHAppendEventFile[root_, ev_Association] := Module[{path = iKHEventsPath[root], bytes},
  bytes = ExportByteArray[iKHNormalizeForJSON[ev], "RawJSON", "Compact" -> True];
  If[! MatchQ[bytes, _ByteArray],
    Return[Failure["KHJSONEncode", <|"MessageTemplate" -> "KH event を JSON 化できません"|>]]];
  SourceVaultWithLock["khevents-" <> IntegerString[Hash[root], 16, 8],
    Module[{strm = OpenAppend[path, BinaryFormat -> True]},
      BinaryWrite[strm, Normal[bytes]];
      BinaryWrite[strm, {10}];  (* newline *)
      Close[strm]; True]]];
iKHReadEventFile[root_] := Module[{path = iKHEventsPath[root], bytes, lines},
  If[! StringQ[root] || ! FileExistsQ[path], Return[{}]];
  bytes = BinaryReadList[path, "Byte"];
  lines = SequenceSplit[bytes, {10}];  (* split on newline *)
  DeleteCases[
    (Quiet@Check[ImportByteArray[ByteArray[#], "RawJSON"], $Failed] & /@ Select[lines, # =!= {} &]),
    $Failed]];

(* ---- mint: ULID canonical + ki alias(CAS counter)---- *)
Options[SourceVaultKnowledgeHomeMintItem] = {"Root" -> Automatic, "OwnerRef" -> "sventity:owner:imai",
  "PrivacyLevel" -> 0.6, "AliasBase" -> 10000, "NoAlias" -> False, "DeviceID" -> Automatic,
  "CreatedAtUTC" -> Automatic, "Persist" -> True};
SourceVaultKnowledgeHomeMintItem[label_String, OptionsPattern[]] := Module[
  {root, ref, aliasKi, ev, dev, ts},
  root = iKHRoot[OptionValue["Root"]];
  ref = "svtopic:kh:" <> iKHULID[];
  dev = OptionValue["DeviceID"] /. Automatic :> iKHDevice[];
  ts = OptionValue["CreatedAtUTC"] /. Automatic :> iKHNowUTC[];
  aliasKi = Missing["NoAlias"];
  If[! TrueQ[OptionValue["NoAlias"]] && StringQ[root],
    aliasKi = SourceVaultWithLock["khalias-" <> IntegerString[Hash[root], 16, 8],
      Module[{cpath = iKHCounterPath[root], cur, next},
        cur = If[FileExistsQ[cpath], Quiet@Check[ToExpression[StringTrim[ReadString[cpath]]], OptionValue["AliasBase"]], OptionValue["AliasBase"]];
        If[! IntegerQ[cur], cur = OptionValue["AliasBase"]];
        next = cur + 1;
        Export[cpath, ToString[next], "Text"];  (* CAS: lock 下で read-modify-write *)
        next]];
    If[! IntegerQ[aliasKi], aliasKi = Missing["AliasError"]]];
  ev = <|"EventClass" -> "KnowledgeHomeTopicItemMinted", "EventId" -> "khev:" <> iKHULID[],
    "TopicItemRef" -> ref, "CanonicalLabel" -> label, "OwnerRef" -> OptionValue["OwnerRef"],
    "PrivacyLevel" -> OptionValue["PrivacyLevel"],
    "AliasKi" -> aliasKi, "Alias" -> If[IntegerQ[aliasKi], "ki " <> ToString[aliasKi], Missing[]],
    "AliasHistory" -> If[IntegerQ[aliasKi], {<|"Ki" -> aliasKi, "AssignedAtUTC" -> ts, "DeviceID" -> dev|>}, {}],
    "CreatedAtUTC" -> ts, "DeviceID" -> dev|>;
  If[TrueQ[OptionValue["Persist"]] && StringQ[root], iKHAppendEventFile[root, ev]];
  ev];

(* mint 済 alias("ki N")を本文参照形(svtopic:oops:ki:N)から正準 ULID へ解決する map。
   正準 ID は安定・alias は merge で振り直され得るので、追記時に安定な正準へ焼き込む(§4.2)。 *)
iKHAliasRefMap[ext_Association] := Association@DeleteCases[
  KeyValueMap[Function[{alias, canon},
    Module[{ki = StringCases[alias, "ki" ~~ Whitespace ~~ n : DigitCharacter .. :> n]},
      If[ki === {}, Nothing, ("svtopic:oops:ki:" <> First[ki]) -> canon]]],
    Lookup[ext, "AliasMap", <||>]],
  (_ -> _?(!StringQ[#] &))];

(* ---- append paragraph(非破壊) ---- *)
Options[SourceVaultKnowledgeHomeAppend] = {"Topics" -> {}, "Quotes" -> {}, "PrivacyLevel" -> 0.6,
  "Tags" -> {}, "Author" -> "sventity:owner:imai", "CognitiveContextRef" -> Missing[],
  "Root" -> Automatic, "DeviceID" -> Automatic, "CreatedAtUTC" -> Automatic,
  "SupersedesRef" -> Missing[], "Extension" -> Automatic, "Persist" -> True};
SourceVaultKnowledgeHomeAppend[body_String, OptionsPattern[]] := Module[
  {root, ref, explicit, quoteMarks, rawTopicRefs, aliasMap, topicRefs, quoteRefs, ev, dev, ts},
  root = iKHRoot[OptionValue["Root"]];
  ref = "svkhpara:" <> iKHULID[];
  dev = OptionValue["DeviceID"] /. Automatic :> iKHDevice[];
  ts = OptionValue["CreatedAtUTC"] /. Automatic :> iKHNowUTC[];
  (* oops 文法検証・抽出: 明示 topic マーカー + 引用マーカー *)
  explicit = Quiet@Check[SourceVaultExtractExplicitTopics[body], {}];
  quoteMarks = Quiet@Check[SourceVaultExtractMailQuoteMarkers[<|"Body" -> body|>], {}];
  rawTopicRefs = DeleteDuplicates@Join[OptionValue["Topics"], #["TopicItemRef"] & /@ explicit];
  (* alias 参照(ki N)を正準 ULID へ解決 *)
  aliasMap = iKHAliasRefMap[
    OptionValue["Extension"] /. Automatic :> Quiet@Check[SourceVaultKnowledgeHomeExtension["Root" -> root], <||>]];
  topicRefs = DeleteDuplicates[Lookup[aliasMap, #, #] & /@ rawTopicRefs];
  quoteRefs = DeleteDuplicates@Join[OptionValue["Quotes"],
    DeleteMissing[Lookup[#, "FromMail", Missing[]] & /@ quoteMarks] /. n_Integer :> "sv://mail/" <> ToString[n]];
  ev = <|"EventClass" -> "KnowledgeHomeParagraphAdded", "EventId" -> "khev:" <> iKHULID[],
    "ParagraphRef" -> ref, "Body" -> body, "TopicRefs" -> topicRefs, "QuoteRefs" -> quoteRefs,
    "ExplicitTopics" -> explicit, "PrivacyLevel" -> OptionValue["PrivacyLevel"], "Tags" -> OptionValue["Tags"],
    "Author" -> OptionValue["Author"], "CognitiveContextRef" -> OptionValue["CognitiveContextRef"],
    "SupersedesRef" -> OptionValue["SupersedesRef"], "CreatedAtUTC" -> ts, "DeviceID" -> dev|>;
  If[TrueQ[OptionValue["Persist"]] && StringQ[root], iKHAppendEventFile[root, ev]];
  ev];

SourceVaultKnowledgeHomeAppendTemplate[] := Defer[
  SourceVaultKnowledgeHomeAppend[
    "◎ <ラベル>[kh <n>]\n\n<本文をここに。引用は -*- Quote (from N) -*- ... -*- Unquote -*->",
    "PrivacyLevel" -> 0.6, "Tags" -> {}]];

(* ---- supersede(訂正)/ undo(取り消し)---- *)
Options[SourceVaultKnowledgeHomeSupersede] = Options[SourceVaultKnowledgeHomeAppend];
SourceVaultKnowledgeHomeSupersede[paragraphRef_String, newBody_String, opts : OptionsPattern[]] := Module[
  {newEv},
  newEv = SourceVaultKnowledgeHomeAppend[newBody, "SupersedesRef" -> paragraphRef, opts];
  <|"OldRef" -> paragraphRef, "NewRef" -> newEv["ParagraphRef"], "Event" -> newEv|>];

Options[SourceVaultKnowledgeHomeUndoLast] = {"Author" -> "sventity:owner:imai", "Root" -> Automatic,
  "DeviceID" -> Automatic, "Persist" -> True};
SourceVaultKnowledgeHomeUndoLast[OptionsPattern[]] := Module[
  {root, proj, mine, target, ev, dev, ts},
  root = iKHRoot[OptionValue["Root"]];
  proj = SourceVaultKnowledgeHomeExtension["Root" -> root];
  mine = Select[proj["Paragraphs"], Lookup[#, "Author", ""] === OptionValue["Author"] &];
  If[mine === {}, Return[Missing["NothingToUndo"]]];
  target = Last[SortBy[mine, Lookup[#, "CreatedAtUTC", ""] &]];  (* 直近 *)
  dev = OptionValue["DeviceID"] /. Automatic :> iKHDevice[];
  ts = iKHNowUTC[];
  ev = <|"EventClass" -> "KnowledgeHomeParagraphSuperseded", "EventId" -> "khev:" <> iKHULID[],
    "TargetRef" -> target["ParagraphRef"], "NewRef" -> Missing[], "Reason" -> "Retracted",
    "Author" -> OptionValue["Author"], "CreatedAtUTC" -> ts, "DeviceID" -> dev|>;
  If[TrueQ[OptionValue["Persist"]] && StringQ[root], iKHAppendEventFile[root, ev]];
  <|"RetractedRef" -> target["ParagraphRef"], "Event" -> ev|>];

(* ---- replay projection(再生成可能)---- *)
iKHReplayEvents[events_List] := Module[
  {added = <||>, mintedT = <||>, superseded = {}, aliasMap = <||>, active, khTimeline},
  Scan[Function[ev,
    Switch[Lookup[ev, "EventClass", ""],
      "KnowledgeHomeParagraphAdded",
        added[ev["ParagraphRef"]] = ev;
        If[StringQ[Lookup[ev, "SupersedesRef", Null]], AppendTo[superseded, ev["SupersedesRef"]]],
      "KnowledgeHomeParagraphSuperseded",
        If[StringQ[Lookup[ev, "TargetRef", Null]], AppendTo[superseded, ev["TargetRef"]]],
      "KnowledgeHomeTopicItemMinted",
        mintedT[ev["TopicItemRef"]] = ev;
        If[StringQ[Lookup[ev, "Alias", Null]], aliasMap[ev["Alias"]] = ev["TopicItemRef"]]]],
    events];
  active = KeyValueMap[#2 &, KeyDrop[added, DeleteDuplicates[superseded]]];
  active = SortBy[active, Lookup[#, "CreatedAtUTC", ""] &];
  (* topic -> KH paragraphs 時系列 *)
  khTimeline = <||>;
  Scan[Function[p,
    Scan[Function[ref, khTimeline[ref] = Append[Lookup[khTimeline, ref, {}], p]],
      Lookup[p, "TopicRefs", {}]]], active];
  <|"Paragraphs" -> active, "Topics" -> mintedT, "AliasMap" -> aliasMap,
    "TopicKHTimeline" -> khTimeline, "EventCount" -> Length[events]|>];

Options[SourceVaultKnowledgeHomeExtension] = {"Root" -> Automatic, "Events" -> Automatic};
SourceVaultKnowledgeHomeExtension[OptionsPattern[]] := Module[{events},
  events = OptionValue["Events"] /. Automatic :> iKHReadEventFile[iKHRoot[OptionValue["Root"]]];
  iKHReplayEvents[events]];

(* ---- offline merge(alias 衝突は正準 ID を保って alias 振り直し)---- *)
Options[SourceVaultKnowledgeHomeMergeExtensions] = {"AliasBase" -> 10000};
SourceVaultKnowledgeHomeMergeExtensions[eventLists_List, OptionsPattern[]] := Module[
  {all, proj, mintEvents, seenAlias = <||>, reassign = {}, nextAlias, fixedEvents},
  all = Flatten[eventLists, 1];
  (* alias 衝突検出: 同一 Alias を複数の TopicItemRef が主張 → 後発を振り直す *)
  mintEvents = Select[all, Lookup[#, "EventClass", ""] === "KnowledgeHomeTopicItemMinted" &];
  nextAlias = Max[Append[
    DeleteMissing[Lookup[#, "AliasKi", Missing[]] & /@ mintEvents /. Null -> Missing[]],
    OptionValue["AliasBase"]]];
  fixedEvents = Map[Function[ev,
    If[Lookup[ev, "EventClass", ""] === "KnowledgeHomeTopicItemMinted" && StringQ[Lookup[ev, "Alias", Null]],
      Module[{al = ev["Alias"], ref = ev["TopicItemRef"], newKi, newAlias, hist},
        If[KeyExistsQ[seenAlias, al] && seenAlias[al] =!= ref,
          (* 衝突: 正準 ref は不変、alias を振り直す *)
          nextAlias += 1; newKi = nextAlias; newAlias = "ki " <> ToString[newKi];
          hist = Append[Lookup[ev, "AliasHistory", {}],
            <|"Ki" -> newKi, "AssignedAtUTC" -> iKHNowUTC[], "DeviceID" -> iKHDevice[], "Reason" -> "MergeCollision"|>];
          AppendTo[reassign, <|"TopicItemRef" -> ref, "OldAlias" -> al, "NewAlias" -> newAlias|>];
          seenAlias[newAlias] = ref;
          Join[ev, <|"AliasKi" -> newKi, "Alias" -> newAlias, "AliasHistory" -> hist|>],
          seenAlias[al] = ref; ev]],
      ev]],
    all];
  proj = iKHReplayEvents[fixedEvents];
  <|"Projection" -> proj, "AliasReassignments" -> reassign|>];

(* ---- KH パラグラフ検索(BM25。追記→検索の往復)---- *)
iKHParaSource[p_Association] := <|"PrivacyLevel" -> Lookup[p, "PrivacyLevel", 0.6],
  "Tags" -> Lookup[p, "Tags", {}], "State" -> "Published"|>;
Options[SourceVaultKnowledgeHomeSearch] = {"ReleaseContext" -> "oops-corpus", "Extension" -> Automatic,
  "Root" -> Automatic, "Limit" -> 10};
SourceVaultKnowledgeHomeSearch[query_String, OptionsPattern[]] := Module[
  {ext, ctx, visible, chunks, stats, ranked, byId},
  iKHEnsureReleaseContexts[];
  ctx = OptionValue["ReleaseContext"];
  ext = OptionValue["Extension"] /. Automatic :> SourceVaultKnowledgeHomeExtension["Root" -> OptionValue["Root"]];
  visible = Select[ext["Paragraphs"], iKHGateSource[iKHParaSource[#], ctx]["Permit"] &];
  If[visible === {}, Return[{}]];
  byId = Association[(#["ParagraphRef"] -> #) & /@ visible];
  chunks = <|"ChunkId" -> #["ParagraphRef"], "Text" -> Lookup[#, "Body", ""]|> & /@ visible;
  stats = SourceVaultBuildLexicalStats[chunks];
  ranked = SourceVaultLexicalRank[query, stats, "Limit" -> OptionValue["Limit"]];
  Map[Function[r,
    Module[{p = byId[r["ChunkId"]]},
      <|"ParagraphRef" -> r["ChunkId"], "Score" -> Round[r["Score"], 0.01],
        "Snippet" -> StringTake[StringReplace[Lookup[p, "Body", ""], {"\n" -> " ", "\r" -> ""}], UpTo[80]],
        "TopicRefs" -> Lookup[p, "TopicRefs", {}]|>]],
    ranked]];

End[];

EndPackage[];
