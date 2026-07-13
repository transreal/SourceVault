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
(* ---- Phase 1C: 位置づけ(KnowledgeHomeTopicPosition)/ 近傍検索 / 3リング提案 ---- *)
SourceVaultKnowledgeHomeTopicPosition::usage =
  "SourceVaultKnowledgeHomeTopicPosition[entry, opts] は object(mail Counter | \"sv://mail/N\" | svkhpara: | 生テキスト)の" <>
  "topic 空間座標を返す(§4.1。決定的・再生成可能な projection)。TopicEvidence は重みごとの根拠" <>
  "(TopicRef/Weight/Method=OwnerConfirmed|SeedMatched|RelationExpanded/SourceSegmentRef/Confidence)。" <>
  "UnknownMass はどの topic にも帰属しない質量(無理に押し込まない)。Space=OOPSSeed|KHExtension|Mixed。" <>
  "mail が gate で deny なら Released->False のみ(low-leak)。" <>
  "オプション \"ReleaseContext\"(既定 \"oops-corpus\")、\"State\"(Automatic)、\"RelationGraph\"(Automatic=state)、" <>
  "\"IncludeRelation\"(既定 True)、\"MaxRelationTopics\"(6)。";
SourceVaultKnowledgeHomeNeighborhoodSearch::usage =
  "SourceVaultKnowledgeHomeNeighborhoodSearch[entry, opts] は位置(または entry から即時計算)の近傍 object " <>
  "(mail + KH パラグラフ)を topic 重なりで返す(Neighbor Hopping の基盤)。gate で deny された object は返さない。" <>
  "戻り値 {<|Ref, Kind, Subject, Score, SharedTopicLabels, Date|>...}(Score 降順)。" <>
  "オプション \"ReleaseContext\"、\"State\"、\"Limit\"(10)、\"ExcludeRefs\"({})、\"IncludeKH\"(True)。";
SourceVaultKnowledgeHomeSuggestNextNodes::usage =
  "SourceVaultKnowledgeHomeSuggestNextNodes[entry, opts] は資料 p11 の 3 リング提案: " <>
  "Ring1=similar topics and newer(前進バイアス。newer は bounded な一特徴)、Ring2=direct neighborhood(引用/被引用)、" <>
  "Ring3=neighborhood(relation graph 経由の周辺)。各提案は Ring と Reasons(理由表示)を持つ。" <>
  "dismiss は \"ExcludeRefs\" と SourceVaultKnowledgeHomeDismissSuggestion[ref](セッション内)。" <>
  "オプション \"ReleaseContext\"、\"State\"、\"RelationGraph\"(Automatic)、\"LimitPerRing\"(5)、\"ExcludeRefs\"({})。";
SourceVaultKnowledgeHomeDismissSuggestion::usage =
  "SourceVaultKnowledgeHomeDismissSuggestion[ref] は提案 dismiss をセッション内リスト($SourceVaultKnowledgeHomeDismissed)に" <>
  "追加する(以後の SuggestNextNodes から除外。永続化は後続 Phase)。";
SourceVaultKnowledgeHomeSuggestView::usage =
  "SourceVaultKnowledgeHomeSuggestView[entry, opts] は SuggestNextNodes の Dataset 版(Ring/Score/理由付き)。";

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

(* mail の topic refs。mode:
   "Auto"     = 明示 ◎○・ ＋ seed-matched(4548 surface × 段落照合。単一 mail 向け。全コーパスでは重い)
   "Explicit" = 明示マーカーのみ(regex。高速)
   "Gold"     = 明示 ∪ 人手付与 gold(mail-to-item.index。全コーパス構築の既定=速く・高品質) *)
iKHMailTopics[mail_Association, sidx_] := iKHMailTopics[mail, sidx, "Auto", None];
iKHMailTopics[mail_Association, sidx_, mode_String, goldEntries_] := Module[
  {body, expl, assignRows, seedm, goldRefs, explRefs, seedRefs, refs, labels},
  body = ToString@Lookup[mail, "Body", ""];
  expl = Quiet@Check[SourceVaultExtractExplicitTopics[body], {}];
  seedm = If[mode === "Auto" && AssociationQ[sidx],
    assignRows = Quiet@Check[SourceVaultAssignParagraphTopics[SourceVaultParseMailParagraphs[body], sidx], {}];
    Flatten[Lookup[#, "Assignments", {}] & /@ assignRows],
    {}];
  goldRefs = If[mode === "Gold" && ListQ[goldEntries],
    ("svtopic:oops:" <> #["Namespace"] <> ":" <> ToString[#["LocalId"]]) & /@ goldEntries,
    {}];
  explRefs = #["TopicItemRef"] & /@ expl;
  seedRefs = Lookup[#, "TopicItemRef", Nothing] & /@ seedm;
  refs = DeleteDuplicates@DeleteMissing@DeleteCases[Join[explRefs, goldRefs, seedRefs], Nothing];
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

$svKHAutoTagMailLimit = 300;  (* これ以上の corpus は Auto(全 surface 照合)を既定にしない=初回構築の重量化防止 *)

Options[SourceVaultKnowledgeHomeBuildState] = {"SurfaceIndex" -> None, "RefLabel" -> <||>,
  "QuoteEdges" -> Automatic, "ExtensionEntries" -> {}, "Extension" -> None, "RelationGraph" -> None,
  "MailToItem" -> None, "TopicAssign" -> Automatic};
SourceVaultKnowledgeHomeBuildState[mails_List, OptionsPattern[]] := Module[
  {sidx, refLabel, edges, byCounter, counters, mailTopics, topicTimeline, topicLabel, quoteOut, quoteIn,
   ext, khTimeline, gold, mode},
  sidx = OptionValue["SurfaceIndex"];
  refLabel = OptionValue["RefLabel"];
  gold = OptionValue["MailToItem"];
  (* TopicAssign 解決: gold があれば Gold(速く・人手品質)、大 corpus は Explicit、小 corpus は Auto *)
  mode = OptionValue["TopicAssign"] /. Automatic :> Which[
    AssociationQ[gold] && Length[gold] > 0, "Gold",
    Length[mails] > $svKHAutoTagMailLimit, "Explicit",
    True, "Auto"];
  edges = OptionValue["QuoteEdges"] /. Automatic :> Quiet@Check[SourceVaultBuildMailQuoteEdges[mails], {}];
  byCounter = Association[(Lookup[#, "Counter", Missing[]] -> #) & /@ mails];
  KeyDropFrom[byCounter, {Missing[]}];
  counters = Sort[Keys[byCounter]];
  mailTopics = Association[(# -> iKHMailTopics[byCounter[#], sidx, mode,
    If[AssociationQ[gold], Lookup[gold, #, {}], None]]) & /@ counters];
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
    "SurfaceIndex" -> sidx, "RefLabel" -> refLabel, "RelationGraph" -> OptionValue["RelationGraph"],
    "MailTopics" -> mailTopics, "TopicTimeline" -> topicTimeline, "TopicLabel" -> topicLabel,
    "QuoteOut" -> quoteOut, "QuoteIn" -> quoteIn, "ExtensionEntries" -> OptionValue["ExtensionEntries"],
    "Extension" -> ext, "TopicKHTimeline" -> khTimeline,
    "MailToItem" -> gold, "TopicAssignMode" -> mode|>];

Options[SourceVaultKnowledgeHomeEnsureLoaded] = {"Force" -> False, "MailFiles" -> All,
  "TableDir" -> Automatic, "MailDir" -> Automatic};
SourceVaultKnowledgeHomeEnsureLoaded[OptionsPattern[]] := Module[
  {oopsStatus, st, gold},
  If[TrueQ[SourceVault`$svKHState["Loaded"]] && ! TrueQ[OptionValue["Force"]],
    Return[SourceVaultKnowledgeHomeStatus[]]];
  Print["[KnowledgeHome] OOPS archive 読み込み中 (初回のみ。全 corpus は数分かかることがあります)..."];
  oopsStatus = SourceVaultOOPSEnsureLoaded["Force" -> OptionValue["Force"],
    "MailFiles" -> OptionValue["MailFiles"], "TableDir" -> OptionValue["TableDir"],
    "MailDir" -> OptionValue["MailDir"]];
  If[FailureQ[oopsStatus], Return[oopsStatus]];
  iKHEnsureReleaseContexts[];
  st = SourceVault`$svOOPSState;
  (* gold(人手付与 mail-to-item)を読み込み: 全 corpus timeline を高速・高品質に構築する土台 *)
  gold = Quiet@Check[
    Lookup[SourceVaultImportOOPSMailToItem[
      FileNameJoin[{Lookup[st, "TableDir", ""], "mail-to-item.index"}]], "MailToItem", None], None];
  Print["[KnowledgeHome] 閲覧インデックス構築中 (mails=", Length[Lookup[st, "Mails", {}]],
    ", gold=", If[AssociationQ[gold], Length[gold], 0], ")..."];
  SourceVault`$svKHState = SourceVaultKnowledgeHomeBuildState[Lookup[st, "Mails", {}],
    "SurfaceIndex" -> Lookup[st, "SurfaceIndex", None], "RefLabel" -> Lookup[st, "RefLabel", <||>],
    "QuoteEdges" -> Lookup[st, "QuoteEdges", Automatic],
    "RelationGraph" -> Lookup[st, "RelationGraph", None],
    "MailToItem" -> gold,
    "Extension" -> Quiet@Check[SourceVaultKnowledgeHomeExtension[], None]];  (* 追記分を合流 *)
  Print["[KnowledgeHome] 構築完了 (TopicAssign=", SourceVault`$svKHState["TopicAssignMode"], ")"];
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

(* ============================================================
   Phase 1C: 位置づけ(TopicPosition)/ 近傍検索 / 3リング提案
   決定的・LLM 不使用・再生成可能。gate は candidate 側に適用(I-4)。
   ============================================================ *)

$svKHPositionPipelineVersion = "kh-pos-v1";

(* entry の本文と meta を解決: mail counter / sv://mail/N / svkhpara: / 生テキスト *)
iKHResolveEntry[st_Association, entry_, ctx_] := Module[{c, para, ext},
  Which[
    IntegerQ[entry] || (StringQ[entry] && StringMatchQ[entry, "sv://mail/" ~~ ___]),
      c = If[IntegerQ[entry], entry, iKHCounterOfRef[entry]];
      If[MissingQ[c] || ! KeyExistsQ[st["MailByCounter"], c],
        Missing["MailNotFound"],
        Module[{mail = st["MailByCounter"][c], gate},
          gate = iKHGate[mail, ctx];
          <|"Kind" -> "Mail", "URI" -> iKHMailRef[c], "Counter" -> c,
            "Body" -> Lookup[mail, "Body", ""], "Released" -> gate["Permit"], "Why" -> gate["Why"],
            "PrivacyLevel" -> iKHMailSource[mail]["PrivacyLevel"]|>]],
    StringQ[entry] && StringMatchQ[entry, "svkhpara:" ~~ ___],
      ext = Lookup[st, "Extension", None];
      para = If[AssociationQ[ext],
        SelectFirst[ext["Paragraphs"], #["ParagraphRef"] === entry &, Missing["ParagraphNotFound"]],
        Missing["NoExtension"]];
      If[MissingQ[para], para,
        Module[{gate = iKHGateSource[iKHParaSource[para], ctx]},
          <|"Kind" -> "KHPara", "URI" -> entry, "Counter" -> Missing[],
            "Body" -> Lookup[para, "Body", ""], "Released" -> gate["Permit"], "Why" -> gate["Why"],
            "PrivacyLevel" -> Lookup[para, "PrivacyLevel", 0.6]|>]],
    StringQ[entry],
      (* 生テキスト(owner の query/思考文脈)。gate 対象外(candidate 側で gate) *)
      <|"Kind" -> "Text", "URI" -> "svtext:" <> IntegerString[Hash[entry], 36],
        "Counter" -> Missing[], "Body" -> entry, "Released" -> True, "Why" -> {},
        "PrivacyLevel" -> 0.0|>,
    True, Missing["UnresolvableEntry"]]];

iKHSpaceOf[refs_List] := Which[
  refs === {}, Missing["NoTopics"],
  AllTrue[refs, StringMatchQ[#, "svtopic:oops:" ~~ ___] &], "OOPSSeed",
  AllTrue[refs, StringMatchQ[#, "svtopic:kh:" ~~ ___] || StringMatchQ[#, "svtopic:extracted:" ~~ ___] &], "KHExtension",
  True, "Mixed"];

Options[SourceVaultKnowledgeHomeTopicPosition] = {"ReleaseContext" -> "oops-corpus", "State" -> Automatic,
  "RelationGraph" -> Automatic, "IncludeRelation" -> True, "MaxRelationTopics" -> 6};
SourceVaultKnowledgeHomeTopicPosition[entry_, OptionsPattern[]] := Module[
  {st, ctx, res, relGraph, paras, assignRows, evid, prose, unknownMass, weights, anchors, refs},
  st = iKHState[OptionValue["State"]];
  ctx = OptionValue["ReleaseContext"];
  iKHEnsureReleaseContexts[];
  res = iKHResolveEntry[st, entry, ctx];
  If[MissingQ[res], Return[res]];
  If[! TrueQ[res["Released"]],
    Return[<|"ObjectClass" -> "SourceVaultKnowledgeHomeTopicPosition", "ObjectURI" -> res["URI"],
      "Released" -> False, "Why" -> res["Why"]|>]];  (* low-leak: evidence/weights を出さない *)
  relGraph = OptionValue["RelationGraph"] /. Automatic :> Lookup[st, "RelationGraph", None];
  If[! TrueQ[OptionValue["IncludeRelation"]], relGraph = None];
  paras = Quiet@Check[SourceVaultParseMailParagraphs[ToString@res["Body"]], {}];
  assignRows = If[AssociationQ[st["SurfaceIndex"]],
    Quiet@Check[SourceVaultAssignParagraphTopics[paras, st["SurfaceIndex"],
      "RelationGraph" -> relGraph, "MaxRelationTopics" -> OptionValue["MaxRelationTopics"]], {}],
    (* surface index 無し: 明示マーカーのみ *)
    Module[{expl = Quiet@Check[SourceVaultExtractExplicitTopics[ToString@res["Body"]], {}]},
      {<|"ParagraphIndex" -> 1, "Kind" -> "Prose",
         "Assignments" -> (Append[#, "AssignmentKind" -> "ExplicitOOPS"] & /@ expl)|>}]];
  (* TopicEvidence: 段落×assignment を根拠として保持(P1-02 provenance) *)
  evid = Flatten@Map[Function[row,
    Map[Function[a,
      <|"TopicRef" -> a["TopicItemRef"],
        "Weight" -> Lookup[a, "Confidence", 0.5],
        "Method" -> Switch[Lookup[a, "AssignmentKind", ""],
          "ExplicitOOPS", "OwnerConfirmed", "SeedMatched", "SeedMatched",
          "RelationExpanded", "RelationExpanded", _, "SeedMatched"],
        "SourceSegmentRef" -> res["URI"] <> "#p" <> ToString[Lookup[row, "ParagraphIndex", 0]],
        "Confidence" -> Lookup[a, "Confidence", 0.5],
        "PrivacyLevel" -> res["PrivacyLevel"]|>],
      Lookup[row, "Assignments", {}]]],
    assignRows];
  (* gold(mail-to-item の人手付与)も OwnerConfirmed evidence として合流(mail entry のみ) *)
  If[! MissingQ[res["Counter"]] && AssociationQ[Lookup[st, "MailToItem", None]],
    evid = Join[evid, Map[Function[g,
      <|"TopicRef" -> "svtopic:oops:" <> g["Namespace"] <> ":" <> ToString[g["LocalId"]],
        "Weight" -> 1.0, "Method" -> "OwnerConfirmed",
        "SourceSegmentRef" -> res["URI"] <> "#gold:" <> ToString@Lookup[g, "Role", ""],
        "Confidence" -> 1.0, "PrivacyLevel" -> res["PrivacyLevel"]|>],
      Lookup[st["MailToItem"], res["Counter"], {}]]]];
  (* UnknownMass: topic の付かない prose 段落の割合(無理に押し込まない。P1-01) *)
  prose = Select[assignRows, Lookup[#, "Kind", "Prose"] === "Prose" &];
  unknownMass = If[prose === {}, 1.0,
    N[Count[prose, row_ /; Lookup[row, "Assignments", {}] === {}] / Length[prose]]];
  weights = Merge[(#["TopicRef"] -> #["Weight"]) & /@ evid, Total];
  If[Length[weights] > 0,
    weights = weights / Sqrt[Total[Values[weights]^2]]];  (* L2 正規化 *)
  anchors = DeleteDuplicates[#["TopicRef"] & /@ Select[evid, #["Method"] === "OwnerConfirmed" &]];
  refs = Keys[weights];
  <|"ObjectClass" -> "SourceVaultKnowledgeHomeTopicPosition", "ObjectURI" -> res["URI"],
    "Released" -> True,
    "TopicWeights" -> weights, "TopicEvidence" -> evid,
    "AnchorTopicRefs" -> anchors, "UnknownMass" -> unknownMass,
    "Space" -> iKHSpaceOf[refs], "MaxInputPrivacyLevel" -> res["PrivacyLevel"],
    "VocabularyVersion" -> "sidx:" <> ToString[Length[Lookup[st, "SurfaceIndex", <||>] /. None -> <||>]] <>
      ":lbl:" <> ToString[Length[Lookup[st, "RefLabel", <||>]]],
    "PipelineVersion" -> $svKHPositionPipelineVersion,
    "InputDigest" -> IntegerString[Hash[ToString@res["Body"]], 36],
    "DerivedAtUTC" -> iKHNowUTC[]|>];

(* candidate(mail/KH para)の重なりスコア: query 位置の重みを共有 topic 上で合算(決定的・軽量) *)
iKHOverlapScore[weights_Association, candRefs_List] :=
  Total[Lookup[weights, #, 0.] & /@ candRefs];

Options[SourceVaultKnowledgeHomeNeighborhoodSearch] = {"ReleaseContext" -> "oops-corpus",
  "State" -> Automatic, "Limit" -> 10, "ExcludeRefs" -> {}, "IncludeKH" -> True};
SourceVaultKnowledgeHomeNeighborhoodSearch[entry_, OptionsPattern[]] := Module[
  {st, ctx, pos, weights, selfURI, rows, khRows, excl},
  st = iKHState[OptionValue["State"]];
  ctx = OptionValue["ReleaseContext"];
  pos = If[AssociationQ[entry] && KeyExistsQ[entry, "TopicWeights"], entry,
    SourceVaultKnowledgeHomeTopicPosition[entry, "ReleaseContext" -> ctx, "State" -> st]];
  If[MissingQ[pos] || ! TrueQ[Lookup[pos, "Released", False]], Return[{}]];
  weights = pos["TopicWeights"];
  selfURI = Lookup[pos, "ObjectURI", ""];
  excl = OptionValue["ExcludeRefs"];
  (* mail candidates(gate 経由: deny は除外) *)
  rows = Map[Function[c,
    Module[{mt = st["MailTopics"][c], score, mail},
      score = iKHOverlapScore[weights, mt["Refs"]];
      If[score <= 0. || MemberQ[excl, iKHMailRef[c]] || iKHMailRef[c] === selfURI, Nothing,
        mail = st["MailByCounter"][c];
        If[! iKHGate[mail, ctx]["Permit"], Nothing,
          <|"Ref" -> iKHMailRef[c], "Kind" -> "Mail", "Counter" -> c,
            "Subject" -> Lookup[mail, "Subject", ""], "Date" -> Lookup[mail, "Date", ""],
            "Score" -> Round[score, 0.001],
            "SharedTopicLabels" -> (Lookup[st["TopicLabel"], #, #] & /@
              Select[mt["Refs"], Lookup[weights, #, 0.] > 0. &])|>]]]],
    st["Counters"]];
  (* KH paragraph candidates *)
  khRows = If[! TrueQ[OptionValue["IncludeKH"]] || ! AssociationQ[Lookup[st, "Extension", None]], {},
    Map[Function[p,
      Module[{score = iKHOverlapScore[weights, Lookup[p, "TopicRefs", {}]], ref = p["ParagraphRef"]},
        If[score <= 0. || MemberQ[excl, ref] || ref === selfURI ||
            ! iKHGateSource[iKHParaSource[p], ctx]["Permit"], Nothing,
          <|"Ref" -> ref, "Kind" -> "KHPara", "Counter" -> Missing[],
            "Subject" -> StringTake[StringReplace[Lookup[p, "Body", ""], "\n" -> " "], UpTo[60]],
            "Date" -> Lookup[p, "CreatedAtUTC", ""], "Score" -> Round[score, 0.001],
            "SharedTopicLabels" -> (Lookup[st["TopicLabel"], #, #] & /@
              Select[Lookup[p, "TopicRefs", {}], Lookup[weights, #, 0.] > 0. &])|>]]],
      st["Extension"]["Paragraphs"]]];
  Take[ReverseSortBy[Join[rows, khRows], #["Score"] &], UpTo[OptionValue["Limit"]]]];

(* ---- 3 リング提案(資料 p11)。newer は bounded な一特徴(I-5 / P1-04) ---- *)
If[! ListQ[SourceVault`$SourceVaultKnowledgeHomeDismissed],
  SourceVault`$SourceVaultKnowledgeHomeDismissed = {}];
SourceVaultKnowledgeHomeDismissSuggestion[ref_String] :=
  (AppendTo[SourceVault`$SourceVaultKnowledgeHomeDismissed, ref];
   SourceVault`$SourceVaultKnowledgeHomeDismissed);

$svKHNewerBoost = 0.2;  (* bounded: 類似度が主、newer は加点上限 0.2 *)

Options[SourceVaultKnowledgeHomeSuggestNextNodes] = {"ReleaseContext" -> "oops-corpus",
  "State" -> Automatic, "RelationGraph" -> Automatic, "LimitPerRing" -> 5, "ExcludeRefs" -> {}};
SourceVaultKnowledgeHomeSuggestNextNodes[entry_, OptionsPattern[]] := Module[
  {st, ctx, pos, refC, excl, nbrs, ring1, ring2, ring3, relGraph, expanded, expRefs, viaOf},
  st = iKHState[OptionValue["State"]];
  ctx = OptionValue["ReleaseContext"];
  (* リング意味論: ring1/近傍 = core(OwnerConfirmed+SeedMatched)の類似。
     relation 展開は ring3 の役割なので、query 位置は core のみで作る。 *)
  pos = SourceVaultKnowledgeHomeTopicPosition[entry, "ReleaseContext" -> ctx, "State" -> st,
    "IncludeRelation" -> False];
  If[MissingQ[pos] || ! TrueQ[Lookup[pos, "Released", False]], Return[{}]];
  refC = If[IntegerQ[entry], entry, iKHCounterOfRef[ToString[entry]]];  (* 参照時点(mail のみ) *)
  excl = Join[OptionValue["ExcludeRefs"], SourceVault`$SourceVaultKnowledgeHomeDismissed];
  nbrs = SourceVaultKnowledgeHomeNeighborhoodSearch[pos, "ReleaseContext" -> ctx, "State" -> st,
    "Limit" -> 4*OptionValue["LimitPerRing"], "ExcludeRefs" -> excl];
  (* Ring1: similar topics and newer(前進バイアス。newer 加点は bounded) *)
  ring1 = Map[Function[row,
    Module[{newer = ! MissingQ[refC] && IntegerQ[row["Counter"]] && row["Counter"] > refC},
      Join[row, <|"Ring" -> 1,
        "RankScore" -> row["Score"] + If[newer, $svKHNewerBoost, 0.],
        "Reasons" -> DeleteCases[{"SimilarTopics: " <> StringRiffle[Take[row["SharedTopicLabels"], UpTo[3]], ", "],
          If[newer, "Newer", Nothing]}, Nothing]|>]]],
    nbrs];
  ring1 = Take[ReverseSortBy[ring1, #["RankScore"] &], UpTo[OptionValue["LimitPerRing"]]];
  (* Ring2: direct neighborhood(引用/被引用。mail entry のみ) *)
  ring2 = If[MissingQ[refC], {},
    Module[{links = Join[
        Lookup[Lookup[st, "QuoteOut", <||>], refC, {}][[All, "ToCounter"]],
        Lookup[Lookup[st, "QuoteIn", <||>], refC, {}][[All, "FromCounter"]]]},
      Map[Function[c2,
        If[MissingQ[c2] || ! KeyExistsQ[st["MailByCounter"], c2] ||
            MemberQ[excl, iKHMailRef[c2]] || ! iKHGate[st["MailByCounter"][c2], ctx]["Permit"], Nothing,
          <|"Ref" -> iKHMailRef[c2], "Kind" -> "Mail", "Counter" -> c2,
            "Subject" -> st["MailByCounter"][c2]["Subject"], "Date" -> st["MailByCounter"][c2]["Date"],
            "Score" -> 1., "Ring" -> 2, "RankScore" -> 1.,
            "SharedTopicLabels" -> {}, "Reasons" -> {"QuoteEdge"}|>]],
        Take[DeleteDuplicates[DeleteMissing[links]], UpTo[OptionValue["LimitPerRing"]]]]]];
  (* Ring3: relation graph 経由の周辺(query topic の 1-hop 先を担う object) *)
  relGraph = OptionValue["RelationGraph"] /. Automatic :> Lookup[st, "RelationGraph", None];
  ring3 = If[! AssociationQ[relGraph], {},
    Module[{seedRefs = Keys[pos["TopicWeights"]]},
      expanded = Quiet@Check[SourceVaultExpandTopicsByRelation[seedRefs, relGraph,
        "MaxTotal" -> 3*OptionValue["LimitPerRing"]], {}];
      expRefs = Lookup[#, "To", Missing[]] & /@ expanded;
      viaOf = Association[(Lookup[#, "To", ""] -> Lookup[#, "ViaSeed", ""]) & /@ expanded];
      Map[Function[c3,
        Module[{mt = st["MailTopics"][c3], hits},
          hits = Intersection[mt["Refs"], DeleteMissing[expRefs]];
          If[hits === {} || MemberQ[excl, iKHMailRef[c3]] ||
              iKHOverlapScore[pos["TopicWeights"], mt["Refs"]] > 0. ||  (* ring1 と重複する直接共有は除外 *)
              ! iKHGate[st["MailByCounter"][c3], ctx]["Permit"], Nothing,
            <|"Ref" -> iKHMailRef[c3], "Kind" -> "Mail", "Counter" -> c3,
              "Subject" -> st["MailByCounter"][c3]["Subject"], "Date" -> st["MailByCounter"][c3]["Date"],
              "Score" -> 0.5, "Ring" -> 3, "RankScore" -> 0.5,
              "SharedTopicLabels" -> (Lookup[st["TopicLabel"], #, #] & /@ hits),
              "Reasons" -> {"RelatedTopic via " <>
                StringRiffle[DeleteDuplicates[Lookup[st["TopicLabel"], Lookup[viaOf, #, ""], ""] & /@ hits], ", "]}|>]]],
        st["Counters"]]]];
  ring3 = Take[ring3, UpTo[OptionValue["LimitPerRing"]]];
  Join[ring1, ring2, ring3]];

Options[SourceVaultKnowledgeHomeSuggestView] = Options[SourceVaultKnowledgeHomeSuggestNextNodes];
SourceVaultKnowledgeHomeSuggestView[entry_, opts : OptionsPattern[]] := Module[
  {rows = SourceVaultKnowledgeHomeSuggestNextNodes[entry, opts]},
  If[rows =!= {},
    Dataset[<|"Ring" -> #["Ring"], "Ref" -> #["Ref"], "Subject" -> #["Subject"],
        "Score" -> #["RankScore"], "Reasons" -> StringRiffle[#["Reasons"], " / "]|> & /@ rows],
    (* 提案なし: 黙って空にせず理由を明示(P1-01: Unknown を明示・無理に押し込まない) *)
    iKHSuggestEmptyExplain[entry,
      FilterRules[{opts}, Options[SourceVaultKnowledgeHomeTopicPosition]]]]];

(* 位置推定不能/gate deny の説明パネル。語彙外候補(ExtractCandidateTopics)と mint 手順を提示 *)
iKHSuggestEmptyExplain[entry_, posOpts_List] := Module[
  {st, pos, cands, candLabels},
  st = iKHState[Automatic];
  pos = Quiet@Check[SourceVaultKnowledgeHomeTopicPosition[entry, Sequence @@ posOpts], Missing["PositionError"]];
  Which[
    MissingQ[pos],
      Column[{Style["提案なし: entry を解決できません。", Bold], Style[ToString[pos], GrayLevel[0.5], 10]}],
    ! TrueQ[Lookup[pos, "Released", False]],
      Column[{Style["提案なし: この object は現在の release context では非公開です。", Bold],
        Style[StringRiffle[Lookup[pos, "Why", {}], ", "], GrayLevel[0.5], 10]}],
    Length[Lookup[pos, "TopicWeights", <||>]] === 0,
      cands = If[StringQ[entry],
        Quiet@Check[SourceVaultExtractCandidateTopics[entry,
          "KnownSurfaceIndex" -> Lookup[st, "SurfaceIndex", None], "Limit" -> 5], {}], {}];
      candLabels = Lookup[#, "Surface", ""] & /@ cands;
      Column[Flatten@{
        Style["提案なし: topic 空間で位置を推定できません(UnknownMass = 1)。", Bold],
        Style["この表現は Knowledge Home の語彙(seed 辞書+KH 拡張)に無い未マップ領域です。誤った topic へは押し込みません。", 11],
        If[candLabels =!= {},
          {Style["新トピック候補(語彙外抽出):", Bold, 11],
           Style["  " <> StringRiffle[candLabels, " / "], 11, RGBColor[0.1, 0.3, 0.7]],
           Style["  → SourceVaultKnowledgeHomeMintItem[\"" <> First[candLabels] <>
             "\"] で正規 topic 化し、Append で追記すると次回から位置が付きます。", 10, GrayLevel[0.35]]},
          {}],
        Style["全文検索: SourceVaultOOPSSearchThreads[query] / KH 追記検索: SourceVaultKnowledgeHomeSearch[query]", 10, GrayLevel[0.5]]},
        Spacings -> 0.6],
    True,
      Column[{Style["提案なし: 位置は推定できましたが、共有 topic を持つ object が見つかりません。", Bold],
        Style["topics: " <> StringRiffle[Take[Keys[pos["TopicWeights"]], UpTo[5]], ", "], GrayLevel[0.5], 10]}]]];

End[];

EndPackage[];
