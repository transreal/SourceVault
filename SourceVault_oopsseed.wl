(* ::Package:: *)

(* ============================================================
   SourceVault_oopsseed.wl -- OOPS seed ontology import primitives
   (検索基盤 Phase 0.5 / Phase 6 foundation)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_oopsseed.wl"]]

   仕様: ドキュメント/sourcevault_search_foundation_implementation_spec_v1.md
         §4.1.1 Seed ontology entity dictionary
         §6.5.2 Seed import parser (Common Lisp S式 reader / legacy decode)
         §6.5.1 Owner-scoped topic item

   レビュー由来の実装原則 (r1-r5):
     - 名前空間は enum で決め打ちしない。実データに ki/aga/e/mi/caitsith/tom/ara/anonymous
       および typo (catisith,lki) の 10 種が存在する。総称的に (SYMBOL INT) を読む。
     - index は「S式風」ではなく Common Lisp S式。regex/単純行分割で読まない。
     - 文字エンコーディングは実機で確定する: item-name.index は CR 区切りの ShiftJIS(CP932)。
       ESC(27)=0 ゆえ ISO-2022-JP ではない。0x85 は CP932 二重バイトの一部 (NEL 行終端ではない)。
       quoted-table.index 等の mixed file 用には iSVDecodeLegacyJapanese の cascade を用意。
     - owner-scoped: ki=owner(imai) namespace、mi/aga 等は別 owner namespace。
       未解決 owner は drop せず Missing["UnknownOwner"]。

   Increment 1 (本ファイル) のスコープ:
     - Common Lisp S式 reader                       SourceVaultReadSExprString / iSVReadAllSExpr
     - legacy Japanese decoder (file -> string)     iSVDecodeLegacyJapaneseFile
     - item-name.index parser -> topic name records SourceVaultImportOOPSItemNames
     - owner-scoped seed entity dictionary builder  SourceVaultBuildSeedEntityDictionary
     - 検証用 stats                                  SourceVaultSeedDictionaryStats

   次 Increment 予定: relation/quote/mail-info parser、mail archive 突き合わせ、
                      held-out 仮説実測 (辞書あり/なし BM25 counterfactual)。
   ============================================================ *)

BeginPackage["SourceVault`"];

SourceVaultReadSExprString::usage =
  "SourceVaultReadSExprString[s] は Common Lisp S式の文字列 s を読み、top-level S式のリストを返す。" <>
  "(...)->List, \"...\"->String, 整数->Integer, bareword(nil 含む)->SourceVault`SVSym[name]。";

SourceVaultImportOOPSItemNames::usage =
  "SourceVaultImportOOPSItemNames[path] は OOPS の item-name.index を読み、" <>
  "{<|\"Namespace\",\"LocalId\",\"CanonicalLabel\",\"SurfaceForms\",\"LanguageHints\"|>, ...} を返す。" <>
  "オプション \"Encoding\" (既定 \"ShiftJIS\")。";

SourceVaultBuildSeedEntityDictionary::usage =
  "SourceVaultBuildSeedEntityDictionary[items] は item-name records から owner-scoped な " <>
  "SourceVaultSeedEntityDictionary (仕様 §4.1.1) を作る。オプション \"OwnerMap\", \"PersonNamespaces\", " <>
  "\"DictionaryId\", \"SharedNamespaces\"。";

SourceVaultSeedDictionaryStats::usage =
  "SourceVaultSeedDictionaryStats[dict] は seed entity dictionary の検証用統計 (namespace 分布、" <>
  "owner 解決率、bilingual 数、surface form 総数など) を返す純関数。";

SourceVaultImportOOPSSeedDictionary::usage =
  "SourceVaultImportOOPSSeedDictionary[itemNameIndexPath, opts] は import + dictionary build を一括で行う便宜関数。";

SourceVaultImportOOPSMailToItem::usage =
  "SourceVaultImportOOPSMailToItem[path] は mail-to-item.index を読み、" <>
  "<|mailNumber -> {<|\"Namespace\",\"LocalId\",\"Role\"(title/body)|>, ...}|> を返す。" <>
  "これは人手が付与した topic の gold データ (held-out 実験用)。";

SourceVaultImportOOPSMailInfo::usage =
  "SourceVaultImportOOPSMailInfo[path] は mail-info.index を読み、" <>
  "<|mailNumber -> <|\"List\",\"Hash\",\"Author\",\"SourceFile\",\"ByteStart\",\"ByteEnd\"|>|> を返す。" <>
  "List 名 (oops/oops-ura) は privacy 入力。注意: ByteStart/ByteEnd は 2005 年原ファイル基準で、" <>
  "現 UTF-8 ファイルでは byte offset が無効。本文抽出は mbox 直接 parse (SourceVaultParseOOPSMailFile) を使う。";

SourceVaultParseOOPSMailFile::usage =
  "SourceVaultParseOOPSMailFile[path] は UTF-8 の oops*.txt を mbox として parse し、" <>
  "{<|\"Counter\",\"MlName\",\"Subject\",\"From\",\"Date\",\"Body\"|>, ...} を返す。" <>
  "Counter (X-Ml-Counter) で gold (mail-to-item) と join する。CR 行終端対応。";

SourceVaultStripOOPSMarkers::usage =
  "SourceVaultStripOOPSMarkers[text] は OOPS の topic ID ref ([ns n])、brace wrapper、" <>
  "◎○・ structural marker を除去して query 用 plain text を返す。label 本文は残す (held-out で cheat 防止)。";

SourceVaultParseMailParagraphs::usage =
  "SourceVaultParseMailParagraphs[body] は mail 本文を段落に分割し、" <>
  "{<|\"Index\",\"Kind\"(Prose/Quote/Signature/Footer),\"Text\"|>, ...} を返す。空行区切り、引用/署名/footer を分離 (§6.5)。";

SourceVaultAssignParagraphTopics::usage =
  "SourceVaultAssignParagraphTopics[paragraphs, surfaceIndex] は各 prose 段落に対し、seed 辞書の " <>
  "surface form OR-match で topic item を自動割当する (auto-tag)。各割当は TopicItemRef / MatchedSurfaceForms / " <>
  "Confidence / AssignmentKind=\"SeedMatched\"。surfaceIndex は SourceVaultBuildSurfaceIndex[dict]。" <>
  "\"RelationGraph\" を渡すと named topic から 1-hop の関連 topic を低 confidence の AssignmentKind=\"RelationExpanded\"" <>
  "(ViaSeed/RelationWeight 付き) として追加する。" <>
  "オプション \"MinSurfaceLength\"(既定2), \"TopicLimit\"(既定10), \"ProseOnly\"(既定 True), " <>
  "\"RelationGraph\"(既定 None), \"MaxRelationTopics\"(既定8), \"MinRelationWeight\"(既定2)。";

SourceVaultImportOOPSItemRelations::usage =
  "SourceVaultImportOOPSItemRelations[path, opts] は item-relation.index / item-relation-up.index を読み、" <>
  "<|TopicItemRef -> {<|\"To\", \"Weight\", \"Direction\"|>...}|> の重み付き有向 relation を返す。" <>
  "オプション \"Direction\"(既定 \"Down\")。";

SourceVaultBuildOOPSRelationGraph::usage =
  "SourceVaultBuildOOPSRelationGraph[tableDir] は item-relation.index(Down)＋item-relation-up.index(Up) を" <>
  "結合した relation graph <|TopicItemRef -> {neighbor...}|> を返す。";

SourceVaultExpandTopicsByRelation::usage =
  "SourceVaultExpandTopicsByRelation[refs, relationGraph] は seed topic 集合を重み付き 1-hop 近傍へ拡張する。" <>
  "seed 自身は除外し To 単位で最大重みに dedup、重み降順。KG 局所探索(§6.3)・auto-tag 拡張に使う。" <>
  "オプション \"MaxNeighborsPerSeed\"(既定5), \"MinWeight\"(既定1), \"MaxTotal\"(既定20)。";

SourceVaultExtractCandidateTopics::usage =
  "SourceVaultExtractCandidateTopics[text] は seed に無い新トピック候補を本文から抽出する(語彙外対応)。" <>
  "katakana 連続/漢字熟語/Latin トークン/「」『』 引用語を salient な候補として返す。" <>
  "seed 既知語(KnownSurfaceIndex)・stopword・退化語は除外、出現数→長さで順位。" <>
  "オプション \"KnownSurfaceIndex\"(既定 None), \"Limit\"(既定15), \"MinKatakana\"(3), \"MinKanji\"(2), \"MaxKanji\"(6), \"MinLatin\"(2)。" <>
  "戻り値 {<|\"Surface\", \"ExtractionKind\", \"Count\"|>...}。auto-tag では AssignmentKind=\"AutoExtracted\"(要確認候補)。";

SourceVaultTopicEnrichment::usage =
  "SourceVaultTopicEnrichment[text, surfaceIndex] は本文に auto-tag を走らせ、検索 index に注入する " <>
  "topic 情報(SeedMatched の正準ラベル＋RelationExpanded の関連ラベル)を返す。chunk の SearchFields[\"topics\"] に " <>
  "TopicsFieldText を載せると「本文に出ない正準/関連ラベル」で検索ヒットするようになる(seed→検索の接続)。" <>
  "オプション \"RefLabel\"(ref->canonical label の Association), \"RelationGraph\"(既定 None), \"IncludeRelated\"(既定 True), " <>
  "\"MaxRelationTopics\"(6), \"MinRelationWeight\"(2)。" <>
  "戻り値 <|\"TopicRefs\", \"TopicLabels\", \"RelatedRefs\", \"RelatedLabels\", \"TopicsFieldText\"|>。";

SourceVaultExpandSearchGraph::usage =
  "SourceVaultExpandSearchGraph[seeds, opts] は §6.3 KG 局所探索。seed topic refs から重み付き topic relation を " <>
  "multi-hop で BFS 展開し <|\"Seeds\", \"Expanded\", \"Edges\", \"Trace\"|> を返す(node 上限/weight 閾値/cycle 安全)。" <>
  "ExpandTopicsByRelation は auto-tag 用 1-hop、本関数は検索用 multi-hop(edges/trace 付き)。" <>
  "オプション \"RelationGraph\"(必須相当), \"MaxHops\"(2), \"MaxNodes\"(50), \"MinEdgeWeight\"(1), \"RefLabel\"(None), " <>
  "\"EdgeKinds\"(既定 {\"TopicRelation\"}; SharedTag/SharedAuthor/Interaction は将来), \"ReleaseContext\"(None)。";

SourceVaultConfirmCandidateTopics::usage =
  "SourceVaultConfirmCandidateTopics[candidates, opts] は AutoExtracted 候補(owner が確認したもの)を " <>
  "seed と同形の新 topic entry(TopicItemRef/CanonicalLabel/SurfaceForms/NamespaceKind=\"Extracted\"/Provenance) にする。" <>
  "candidates は {<|\"Surface\",\"ExtractionKind\"|>...} か {label string...}。" <>
  "オプション \"ExistingDictionary\"(渡すと Entries を merge した MergedDictionary を返す→BuildSurfaceIndex で検索可能に), " <>
  "\"RefPrefix\"(\"svtopic:extracted\"), \"StartId\"(1), \"OwnerRef\"(None), \"PrivacyLevel\"(0.3)。" <>
  "戻り値 <|\"ConfirmedEntries\", \"Count\", (\"MergedDictionary\")|>。永続は SourceVaultSaveExtractedTopics。";

SourceVaultBuildMailChunks::usage =
  "SourceVaultBuildMailChunks[mail, surfaceIndex, opts] は parse 済 mail を §7.2 検索 chunk のリストにする。" <>
  "各 chunk は SearchFields(title/body/author/topics)＋Text/NormalizedText＋PrivacyLevel/State/Tags＋TopicRefs/RelatedRefs。" <>
  "topics は SourceVaultTopicEnrichment で auto-tag 注入。" <>
  "オプション \"Granularity\"(\"Paragraph\"既定/\"Mail\"), \"RelationGraph\", \"RefLabel\", \"PrivacyLevel\"(0.5), " <>
  "\"ReleaseState\"(\"Published\"), \"IncludeRelated\"(True), \"ObjectIdPrefix\"(\"svobj:oops\")。" <>
  "Paragraph 粒度なら topic は段落単位で付くので whole-mail より precision が高い。";

SourceVaultSaveExtractedTopics::usage =
  "SourceVaultSaveExtractedTopics[entries, path] は確認済 extracted topic entry を WXF で永続化する。" <>
  "SourceVaultLoadExtractedTopics[path] で読み戻し、dict[\"Entries\"] に Join すれば seed に編入できる。";
SourceVaultLoadExtractedTopics::usage =
  "SourceVaultLoadExtractedTopics[path] は SourceVaultSaveExtractedTopics で保存した entry リストを返す。";

SourceVaultImportOOPSQuoteTable::usage =
  "SourceVaultImportOOPSQuoteTable[path] は quote-table.index を読み <|mailNumber -> {<|\"Index\",\"FromMail\",\"StandardQuoteId\"|>...}|> を返す。" <>
  "各メールが引用している元メール(FromMail)と seed の standard-quote id。OOPS seed の authoritative な引用グラフ。";

SourceVaultExtractMailQuoteMarkers::usage =
  "SourceVaultExtractMailQuoteMarkers[mail] は本文の `-*- Quote (from N) -*-` マーカーを抽出する。" <>
  "N が整数なら ExplicitMarker(FromMail)、URL なら ExternalURL(FromRef)。戻り値 {<|\"QuoteKind\",(\"FromMail\"|\"FromRef\"),\"SourceMarker\"|>...}。";

SourceVaultBuildMailQuoteEdges::usage =
  "SourceVaultBuildMailQuoteEdges[mails, opts] は SourceVaultMailQuoteEdge のリストを作る(§6.5 quote tracking)。" <>
  "seed quote-table(authoritative)を \"QuoteTable\" で渡すと SeedStandardQuote edge を、本文マーカーからは ExplicitMarker/ExternalURL edge を作る。" <>
  "各 edge: <|\"ObjectClass\",\"QuoteEdgeId\",\"SeedQuoteId\",\"FromMailRef\",\"ToMailRef\",\"QuoteKind\",\"Confidence\",\"SourceMarker\"|>。オプション \"QuoteTable\"(None)。";

SourceVaultBuildMailSessions::usage =
  "SourceVaultBuildMailSessions[mails, quoteEdges, opts] は quote edge の連結成分＋Subject の Re:/Fwd: 正規化で" <>
  "メールをセッション(スレッド)にまとめる(§6.5 session/cluster)。戻り値 {SourceVaultMailSession...}: " <>
  "<|MailSessionId,MailCounters,MailRefs,MailCount,SessionKind(ReplyThread|QuoteCluster|Singleton),Subject,StartMailCounter,EndMailCounter|>。" <>
  "オプション \"SubjectThreading\"(既定 True)。quote 連結が有れば QuoteCluster、Subject のみなら ReplyThread。";

SourceVaultBuildTopicItemGraph::usage =
  "SourceVaultBuildTopicItemGraph[mails, opts] は段落 auto-tag の topic をノード、同一段落共起=CoParagraph、" <>
  "quote edge 越し=QuoteTransition、seed relation=SeedRelation の辺を張った SourceVaultTopicItemGraph を作る(§6.5)。" <>
  "戻り値 <|Nodes(TopicItemRef/Label/SupportParagraphs), Edges(From/To/EdgeKind/Weight/EvidenceRefs), NodeCount, EdgeCount|>。" <>
  "必須オプション \"SurfaceIndex\"。任意 \"RelationGraph\"/\"RefLabel\"/\"QuoteEdges\"/\"SessionRefs\"。";

Begin["`Private`"];

(* ------------------------------------------------------------
   §6.5.2  Common Lisp S式 reader (proper, paren-balanced)
   表現: list->List, string->String, integer->Integer, bareword->SVSym[name]
   ------------------------------------------------------------ *)

$svNel = FromCharacterCode[133];

iSVWhiteQ[c_String] := (c === " " || c === "\t" || c === "\n" || c === "\r" || c === $svNel || c === "\f");
iSVDelimQ[c_String] := (c === "(" || c === ")" || c === "\"");

iSVSkipWS[cs_, n_Integer, p0_Integer] := Module[{p = p0},
  While[p <= n && iSVWhiteQ[cs[[p]]], p++]; p];

(* read one S-expr starting at position p (assumes non-WS). returns {expr, nextPos} *)
iSVReadOne[s_String, cs_, n_Integer, p0_Integer] := Module[{c = cs[[p0]]},
  Which[
    c === "(", iSVReadList[s, cs, n, p0 + 1],
    c === "\"", iSVReadString[s, cs, n, p0 + 1],
    True, iSVReadAtom[s, cs, n, p0]]];

iSVReadList[s_String, cs_, n_Integer, p0_Integer] := Module[{p, items},
  items = Reap[
      p = iSVSkipWS[cs, n, p0];
      While[p <= n && cs[[p]] =!= ")",
        With[{r = iSVReadOne[s, cs, n, p]}, Sow[r[[1]]]; p = iSVSkipWS[cs, n, r[[2]]]]];
    ][[2]];
  {If[items === {}, {}, First[items]], p + 1}  (* +1 skips the ')' *)];

iSVReadString[s_String, cs_, n_Integer, p0_Integer] := Module[{p = p0, raw},
  While[p <= n && cs[[p]] =!= "\"",
    If[cs[[p]] === "\\" && p < n, p += 2, p++]];
  (* cs から切り出す。StringTake[s,{p0,p-1}] は位置 p まで走査する O(位置) で、
     大きな index では O(n^2) になり wedge していた。 *)
  raw = If[p > p0, StringJoin[cs[[p0 ;; p - 1]]], ""];
  raw = StringReplace[raw, {"\\\"" -> "\"", "\\\\" -> "\\", "\\n" -> "\n", "\\t" -> "\t"}];
  {raw, p + 1}  (* +1 skips closing quote *)];

iSVReadAtom[s_String, cs_, n_Integer, p0_Integer] := Module[{p = p0, tok},
  While[p <= n && ! iSVWhiteQ[cs[[p]]] && ! iSVDelimQ[cs[[p]]], p++];
  tok = StringJoin[cs[[p0 ;; p - 1]]];  (* cs から切り出す (O(トークン長)) *)
  {iSVClassifyAtom[tok], p}];

(* 整数は FromDigits で解釈する。ToExpression はフルパーサ起動で 1 整数あたり ms 級ゆえ、
   quote-table(整数 ~20万)等の大きな index で wedge していた。FromDigits は桁違いに速い。 *)
iSVClassifyAtom[tok_String] :=
  Which[
    StringMatchQ[tok, DigitCharacter ..], FromDigits[tok],
    StringMatchQ[tok, "-" ~~ DigitCharacter ..], -FromDigits[StringDrop[tok, 1]],
    True, SVSym[tok]];

iSVReadAllSExpr[s_String] := Module[{cs = Characters[s], n = StringLength[s], p},
  p = iSVSkipWS[cs, n, 1];
  Reap[
      While[p <= n,
        With[{r = iSVReadOne[s, cs, n, p]}, Sow[r[[1]]]; p = iSVSkipWS[cs, n, r[[2]]]]];
    ][[2]] /. {{} -> {}, {x_List} :> x}];

SourceVaultReadSExprString[s_String] := iSVReadAllSExpr[s];

(* ------------------------------------------------------------
   §6.5.2  legacy Japanese decode
   item-name.index は ShiftJIS。mixed file 用に cascade も用意 (本 increment では未使用 path)。
   ------------------------------------------------------------ *)

iSVDecodeLegacyJapaneseFile[path_String, enc_String: "ShiftJIS"] :=
  Module[{b = BinaryReadList[path, "Byte"], s},
    s = Quiet@Check[FromCharacterCode[b, enc], $Failed];
    If[s === $Failed || StringContainsQ[s, FromCharacterCode[65533]],
      (* fallback cascade: ISO-2022-JP -> UTF-8 -> Latin1 *)
      s = SelectFirst[
        {Quiet@Check[FromCharacterCode[b, "ISO2022-JP"], $Failed],
         Quiet@Check[FromCharacterCode[b, "UTF-8"], $Failed],
         FromCharacterCode[b, "ISOLatin1"]},
        # =!= $Failed && ! StringContainsQ[#, FromCharacterCode[65533]] &,
        FromCharacterCode[b, "ISOLatin1"]]];
    s];

(* ------------------------------------------------------------
   bilingual / language helpers (OOV 辞書資産: "日本語 English" 併記を分割)
   ------------------------------------------------------------ *)

iSVHasCJKQ[s_String] := StringContainsQ[s, RegularExpression["[^\\x00-\\x7F]"]];
iSVHasLatinQ[s_String] := StringContainsQ[s, RegularExpression["[A-Za-z]"]];

iSVLanguageHints[s_String] :=
  DeleteCases[{If[iSVHasCJKQ[s], "ja", Nothing], If[iSVHasLatinQ[s], "en", Nothing]}, Nothing];

(* 併記語を分割: "日本語 English" / "日本語(English)" の両形を別名化。
   例: "ブルース・スターリング Bruce Sterling" -> {full,"ブルース・スターリング","Bruce Sterling"}
       "時刻表(time table)" -> {full,"時刻表","time table"}  (英語が括弧内の頻出形) *)
iSVBilingualForms[label_String] := Module[{forms = {label}, paren, spaced},
  paren = StringCases[label,
    RegularExpression["^(.+?)\\(([^()]*[A-Za-z][^()]*)\\)\\s*$"] :> {"$1", "$2"}];
  If[paren =!= {},
    forms = Join[forms, StringTrim /@ First[paren]],
    (* 括弧形でなければ末尾 latin run の空白区切りを試す *)
    spaced = StringCases[label,
      RegularExpression["^(.*[^\\x00-\\x7F])\\s+([A-Za-z][\\x20-\\x7E]*?)\\s*$"] :> {"$1", "$2"}];
    If[spaced =!= {}, forms = Join[forms, StringTrim /@ First[spaced]]]];
  DeleteDuplicates@DeleteCases[StringTrim /@ forms, ""]];

(* ------------------------------------------------------------
   §6.5  item-name.index parser
   record = key (SYM INT) then value (STRING ...). top-level S式が key,value,key,value... と並ぶ。
   ------------------------------------------------------------ *)

Options[SourceVaultImportOOPSItemNames] = {"Encoding" -> "ShiftJIS"};
SourceVaultImportOOPSItemNames[path_String, OptionsPattern[]] :=
  Module[{s, exprs, recs, warnings = {}},
    If[! FileExistsQ[path],
      Return[Failure["FileNotFound", <|"MessageTemplate" -> "item-name.index がない: `1`", "MessageParameters" -> {path}|>]]];
    s = iSVDecodeLegacyJapaneseFile[path, OptionValue["Encoding"]];
    exprs = iSVReadAllSExpr[s];
    (* 2 つずつ key/value を取り出す *)
    recs = Reap[
      Module[{i = 1, len = Length[exprs], key, val},
        While[i <= len,
          key = exprs[[i]];
          val = If[i + 1 <= len, exprs[[i + 1]], Missing["NoValue"]];
          Which[
            MatchQ[key, {SVSym[_String], _Integer}] && MatchQ[val, {___String}] && val =!= {},
              Sow[<|
                "Namespace" -> key[[1, 1]],
                "LocalId" -> key[[2]],
                "CanonicalLabel" -> First[val],
                "SurfaceForms" -> DeleteDuplicates@Flatten[iSVBilingualForms /@ val],
                "LanguageHints" -> iSVLanguageHints[First[val]]|>];
              i += 2,
            MatchQ[key, {SVSym[_String], _Integer}],
              (* value 不在/想定外: key だけ進めて警告 *)
              AppendTo[warnings, <|"Kind" -> "BadValue", "Key" -> key, "Value" -> val|>]; i += 2,
            True,
              AppendTo[warnings, <|"Kind" -> "BadKey", "Expr" -> key|>]; i += 1]]];
    ][[2]];
    recs = If[recs === {}, {}, First[recs]];
    <|"Items" -> recs, "Count" -> Length[recs], "Warnings" -> warnings,
      "SourcePath" -> path, "Encoding" -> OptionValue["Encoding"]|>];

(* ------------------------------------------------------------
   §4.1.1  owner-scoped seed entity dictionary
   ------------------------------------------------------------ *)

Options[SourceVaultBuildSeedEntityDictionary] = {
  "OwnerMap" -> <|"ki" -> "sventity:owner:imai"|>,
  "SharedNamespaces" -> {"e"},
  "DictionaryId" -> Automatic};

SourceVaultBuildSeedEntityDictionary[importResult_Association, opts : OptionsPattern[]] :=
  SourceVaultBuildSeedEntityDictionary[Lookup[importResult, "Items", {}], opts];

SourceVaultBuildSeedEntityDictionary[items_List, OptionsPattern[]] :=
  Module[{ownerMap, shared, dictId, entries},
    ownerMap = OptionValue["OwnerMap"];
    shared = OptionValue["SharedNamespaces"];
    dictId = OptionValue["DictionaryId"] /. Automatic -> "svdict:oops-topic:item-name";
    entries = Map[
      Function[it,
        Module[{ns = it["Namespace"], owner, nsKind},
          owner = Lookup[ownerMap, ns, Missing["UnknownOwner"]];
          nsKind = Which[
            MemberQ[shared, ns], "Shared",
            ! MissingQ[owner], "Person",
            True, "Unknown"];
          <|
            "TopicItemRef" -> "svtopic:oops:" <> ns <> ":" <> ToString[it["LocalId"]],
            "Namespace" -> ns,
            "LocalId" -> it["LocalId"],
            "OwnerRef" -> owner,
            "OwnerConfidence" -> If[MissingQ[owner], 0.0, 1.0],
            "NamespaceKind" -> nsKind,
            "CanonicalLabel" -> it["CanonicalLabel"],
            "SurfaceForms" -> it["SurfaceForms"],
            "LanguageHints" -> it["LanguageHints"],
            "PrivacyLevel" -> Missing["FromSupportingMail"],
            "SourceRefs" -> {"table/item-name.index"}|>]],
      items];
    <|
      "ObjectClass" -> "SourceVaultSeedEntityDictionary",
      "DictionaryId" -> dictId,
      "Entries" -> entries,
      "EntryCount" -> Length[entries]|>];

SourceVaultImportOOPSSeedDictionary[path_String, opts : OptionsPattern[]] :=
  Module[{imp = SourceVaultImportOOPSItemNames[path, FilterRules[{opts}, Options[SourceVaultImportOOPSItemNames]]]},
    If[FailureQ[imp], imp,
      <|"Dictionary" -> SourceVaultBuildSeedEntityDictionary[imp,
           FilterRules[{opts}, Options[SourceVaultBuildSeedEntityDictionary]]],
        "Import" -> KeyDrop[imp, "Items"]|>]];

(* ------------------------------------------------------------
   検証用 stats
   ------------------------------------------------------------ *)

SourceVaultSeedDictionaryStats[dict_Association] := Module[{es = Lookup[dict, "Entries", {}]},
  <|
    "EntryCount" -> Length[es],
    "NamespaceTally" -> ReverseSort@Counts[#["Namespace"] & /@ es],
    "OwnerResolved" -> Count[es, e_ /; ! MissingQ[e["OwnerRef"]]],
    "OwnerUnresolved" -> Count[es, e_ /; MissingQ[e["OwnerRef"]]],
    "NamespaceKindTally" -> ReverseSort@Counts[#["NamespaceKind"] & /@ es],
    "BilingualCount" -> Count[es, e_ /; Length[e["LanguageHints"]] >= 2],
    "TotalSurfaceForms" -> Total[Length[#["SurfaceForms"]] & /@ es],
    "SampleBilingual" -> Take[Select[es, Length[#["LanguageHints"]] >= 2 &], UpTo[5]][[All, {"CanonicalLabel", "SurfaceForms"}]]
  |>];

(* ------------------------------------------------------------
   §6.5  mail-to-item.index / mail-info.index parser
   どちらも top-level が (integer, list) の繰り返し。namespace は総称。
   ------------------------------------------------------------ *)

SourceVaultImportOOPSMailToItem[path_String] := Module[{s, exprs, rules},
  If[! FileExistsQ[path], Return[Failure["FileNotFound", <|"MessageTemplate" -> path|>]]];
  s = iSVDecodeLegacyJapaneseFile[path, "ShiftJIS"];
  exprs = iSVReadAllSExpr[s];
  rules = Reap[Module[{i = 1, len = Length[exprs], num, lst},
      While[i + 1 <= len,
        num = exprs[[i]]; lst = exprs[[i + 1]];
        If[IntegerQ[num] && ListQ[lst],
          Sow[num -> Cases[lst,
            {{SVSym[ns_String], lid_Integer}, SVSym[role_String]} :>
              <|"Namespace" -> ns, "LocalId" -> lid, "Role" -> role|>]]];
        i += 2]]][[2]];
  rules = If[rules === {}, {}, First[rules]];
  <|"MailToItem" -> Association[rules], "MailCount" -> Length[rules], "SourcePath" -> path|>];

SourceVaultImportOOPSMailInfo[path_String] := Module[{s, exprs, rules},
  If[! FileExistsQ[path], Return[Failure["FileNotFound", <|"MessageTemplate" -> path|>]]];
  s = iSVDecodeLegacyJapaneseFile[path, "ShiftJIS"];
  exprs = iSVReadAllSExpr[s];
  rules = Reap[Module[{i = 1, len = Length[exprs], num, info},
      While[i + 1 <= len,
        num = exprs[[i]]; info = exprs[[i + 1]];
        If[IntegerQ[num] &&
           MatchQ[info, {SVSym[_String], _Integer, _String, {_String, _Integer, _Integer}}],
          Sow[num -> <|
            "List" -> info[[1, 1]], "Hash" -> info[[2]], "Author" -> info[[3]],
            "SourceFile" -> info[[4, 1]], "ByteStart" -> info[[4, 2]], "ByteEnd" -> info[[4, 3]]|>]];
        i += 2]]][[2]];
  rules = If[rules === {}, {}, First[rules]];
  <|"MailInfo" -> Association[rules], "MailCount" -> Length[rules], "SourcePath" -> path|>];

(* ------------------------------------------------------------
   §6.5  mbox 直接 parse (UTF-8, CR 行終端)
   2005 年の byte offset は再エンコードで無効ゆえ、X-Ml-Counter で gold と join する。
   ------------------------------------------------------------ *)

iSVDecodeMailFile[path_String] := Module[{b = BinaryReadList[path, "Byte"], s},
  s = Quiet@Check[FromCharacterCode[b, "UTF-8"], $Failed];
  If[s === $Failed || StringContainsQ[s, FromCharacterCode[65533]],
    s = iSVDecodeLegacyJapaneseFile[path, "UTF-8"]];
  s];

iSVHdr[headers_String, key_String] :=
  FirstCase[StringCases[headers, RegularExpression["(?:^|\\r|\\n)" <> key <> ":[ \\t]*([^\\r\\n]*)"] :> "$1"],
    _String, "", {1}];

(* ------------------------------------------------------------
   RFC 2047 MIME encoded-word (=?charset?B/Q?text?=) 復号。Subject/From の日本語見出しを decode。
   ISO-2022-JP は WL 非対応ゆえ JIS X 0208 バイトを +0x80 して EUC-JP 経由で復号する。
   ------------------------------------------------------------ *)

iSVIso2022jpToEuc[bytes_List] := Module[{out = {}, i = 1, n = Length[bytes], mode = "ascii"},
  While[i <= n,
    If[bytes[[i]] == 27 && i + 2 <= n,
      Which[
        bytes[[i + 1]] == 36 && MemberQ[{64, 66}, bytes[[i + 2]]], mode = "jis"; i += 3,  (* ESC $ @/B *)
        bytes[[i + 1]] == 40 && MemberQ[{66, 74, 72}, bytes[[i + 2]]], mode = "ascii"; i += 3,  (* ESC ( B/J/H *)
        True, i += 1],
      If[mode == "jis" && i + 1 <= n && bytes[[i]] < 128 && bytes[[i + 1]] < 128,
        AppendTo[out, BitOr[bytes[[i]], 128]]; AppendTo[out, BitOr[bytes[[i + 1]], 128]]; i += 2,
        AppendTo[out, bytes[[i]]]; i += 1]]];
  out];

iSVDecodeQPBytes[text_String] := Module[{chars = Characters[StringReplace[text, "_" -> " "]], out = {}, i = 1, n},
  n = Length[chars];
  While[i <= n,
    If[chars[[i]] === "=" && i + 2 <= n &&
        StringMatchQ[chars[[i + 1]] <> chars[[i + 2]], RegularExpression["[0-9A-Fa-f]{2}"]],
      AppendTo[out, FromDigits[chars[[i + 1]] <> chars[[i + 2]], 16]]; i += 3,
      AppendTo[out, First@ToCharacterCode[chars[[i]]]]; i += 1]];
  out];

iSVMimeWordBytes[enc_String, text_String] := Switch[ToUpperCase[enc],
  "B", Quiet@Check[Normal@BaseDecode[StringTrim[text]], $Failed],
  "Q", iSVDecodeQPBytes[text],
  _, $Failed];

iSVBytesToStringByCharset[bytes_List, charset_String] := Module[{cs = ToUpperCase[charset]},
  Which[
    StringContainsQ[cs, "2022"],
      Quiet@Check[ByteArrayToString[ByteArray[iSVIso2022jpToEuc[bytes]], "EUC-JP"], $Failed],
    StringContainsQ[cs, "UTF-8"] || cs === "UTF8",
      Quiet@Check[ByteArrayToString[ByteArray[bytes], "UTF-8"], $Failed],
    StringContainsQ[cs, "SHIFT"] || MemberQ[{"SJIS", "X-SJIS", "CP932", "MS_KANJI", "WINDOWS-31J"}, cs],
      Quiet@Check[ByteArrayToString[ByteArray[bytes], "ShiftJIS"], $Failed],
    StringContainsQ[cs, "EUC"],
      Quiet@Check[ByteArrayToString[ByteArray[bytes], "EUC-JP"], $Failed],
    True, Quiet@Check[ByteArrayToString[ByteArray[bytes], "ASCII"], Quiet@Check[FromCharacterCode[bytes], $Failed]]]];

iSVDecodeMimeWords[s0_String] := Module[{s},
  s = StringReplace[s0, RegularExpression["\\?=\\s+=\\?"] -> "?==?"];  (* 隣接 encoded-word 間の空白を除去 (RFC2047) *)
  StringReplace[s,
    Shortest["=?" ~~ cs : (Except["?"] ..) ~~ "?" ~~ en : ("B" | "b" | "Q" | "q") ~~ "?" ~~ tx : (Except["?"] ...) ~~ "?="] :>
      Module[{by = iSVMimeWordBytes[en, tx], str},
        str = If[ListQ[by], iSVBytesToStringByCharset[by, cs], $Failed];
        If[StringQ[str], str, "=?" <> cs <> "?" <> en <> "?" <> tx <> "?="]]]];

SourceVaultParseOOPSMailFile[path_String] := Module[{s, parts, mails},
  If[! FileExistsQ[path], Return[Failure["FileNotFound", <|"MessageTemplate" -> path|>]]];
  s = iSVDecodeMailFile[path];
  parts = StringSplit[s, RegularExpression["[\\r\\n]From oops-adm@\\S+"]];
  mails = Reap[
    Do[Module[{hb, headers, body, counter},
      hb = StringSplit[part, RegularExpression["\\r\\r|\\n\\n|\\r\\n\\r\\n"], 2];
      headers = hb[[1]]; body = If[Length[hb] >= 2, hb[[2]], ""];
      counter = StringCases[headers, RegularExpression["X-Ml-Counter:[ \\t]*(\\d+)"] :> "$1"];
      If[counter =!= {},
        Sow[<|
          "Counter" -> ToExpression[First[counter]],
          "MlName" -> StringTrim@iSVHdr[headers, "X-Ml-Name"],
          "Subject" -> StringTrim@iSVDecodeMimeWords@iSVHdr[headers, "Subject"],
          "From" -> StringTrim@iSVDecodeMimeWords@iSVHdr[headers, "From"],
          "Date" -> StringTrim@iSVHdr[headers, "Date"],
          "Body" -> body|>]]],
      {part, parts}]][[2]];
  mails = If[mails === {}, {}, First[mails]];
  <|"Mails" -> mails, "MailCount" -> Length[mails], "SourcePath" -> path|>];

SourceVaultStripOOPSMarkers[text_String] := Module[{s = text},
  s = StringReplace[s, RegularExpression["\\[[A-Za-z]+[ \\t]+\\d+\\]"] -> ""];  (* [ns n] ID ref *)
  s = StringReplace[s, {"{" -> "", "}" -> ""}];                                  (* brace wrapper *)
  s = StringReplace[s, RegularExpression["[◎○・]"] -> " "];                      (* structural bullet *)
  s = StringReplace[s, {"\r" -> "\n"}];
  StringReplace[s, RegularExpression["[ \\t]+"] -> " "]];

(* ------------------------------------------------------------
   §6.5  paragraph 分割 ＋ topic 自動付与 (auto-tag, Track B MVP)
   ------------------------------------------------------------ *)

iSVParaKind[t_String] := Which[
  StringContainsQ[t, "-*- Quote"] || StringContainsQ[t, "-*- Unquote"] ||
    StringMatchQ[t, RegularExpression["(?s)^[ \\t]*>.*"]], "Quote",
  StringMatchQ[t, RegularExpression["(?s)^[；;]\\s*[A-Za-z]{0,4}\\s*$"]], "Signature",
  StringContainsQ[t, "X-Ml-"] || StringContainsQ[t, "Errors-To:"] ||
    StringContainsQ[t, "Reply-To:"], "Footer",
  True, "Prose"];

SourceVaultParseMailParagraphs[body_String] := Module[{norm, blocks, paras},
  norm = StringReplace[body, "\r" -> "\n"];
  blocks = StringSplit[norm, RegularExpression["\\n[ \\t]*\\n+"]];
  blocks = Select[StringTrim /@ blocks, # =!= "" &];
  paras = MapIndexed[<|"Index" -> #2[[1]], "Kind" -> iSVParaKind[#1], "Text" -> #1|> &, blocks];
  paras];

Options[SourceVaultAssignParagraphTopics] = {"MinSurfaceLength" -> 2, "TopicLimit" -> 10, "ProseOnly" -> True,
  "RelationGraph" -> None, "MaxRelationTopics" -> 8, "MinRelationWeight" -> 2,
  "ExtractCandidates" -> False, "CandidateLimit" -> 8, "RefLabel" -> None};
SourceVaultAssignParagraphTopics[paragraphs_List, surfaceIndex_Association, OptionsPattern[]] :=
  Module[{minLen = OptionValue["MinSurfaceLength"], lim = OptionValue["TopicLimit"],
          proseOnly = OptionValue["ProseOnly"], keys,
          relGraph = OptionValue["RelationGraph"], maxRel = OptionValue["MaxRelationTopics"],
          minRelW = OptionValue["MinRelationWeight"], refLabel = OptionValue["RefLabel"],
          extractCand = OptionValue["ExtractCandidates"], candLim = OptionValue["CandidateLimit"]},
    keys = Select[Keys[surfaceIndex], StringLength[#] >= minLen &];
    Map[Function[para,
      If[proseOnly && para["Kind"] =!= "Prose",
        <|"ParagraphIndex" -> para["Index"], "Kind" -> para["Kind"], "Assignments" -> {}|>,
        Module[{nt = iSVNormalizeSearchText[para["Text"]], matches, byRef, seedAssigns, relAssigns, candAssigns},
          matches = Flatten@Map[Function[sf,
             If[iSVSurfaceFormPresentQ[nt, sf], (sf -> #) & /@ surfaceIndex[sf], {}]], keys];
          byRef = GroupBy[matches, Last -> First];  (* ref -> {surfaceForm...} *)
          seedAssigns = Take[ReverseSortBy[
            KeyValueMap[Function[{ref, sfs},
              <|"TopicItemRef" -> ref, "MatchedSurfaceForms" -> DeleteDuplicates[sfs],
                "AssignmentKind" -> "SeedMatched",
                "Confidence" -> Min[1.0, 0.4 + 0.12*Max[StringLength /@ sfs]]|>], byRef],
            #Confidence &], UpTo[lim]];
          (* owner disambiguation(軽量): 同一 canonical label の重複(別 owner/重複 entry)を 1 件に collapse、
             AltRefs に他 ref を provenance として残す (RefLabel 指定時) *)
          If[AssociationQ[refLabel] && Length[seedAssigns] > 1,
            seedAssigns = ReverseSortBy[
              Values@GroupBy[seedAssigns, Lookup[refLabel, #["TopicItemRef"], #["TopicItemRef"]] &,
                Function[grp, Module[{sorted = ReverseSortBy[grp, #["Confidence"] &]},
                  Append[First[sorted], <|
                    "MatchedSurfaceForms" -> DeleteDuplicates[Flatten[#["MatchedSurfaceForms"] & /@ grp]],
                    "AltRefs" -> Rest[#["TopicItemRef"] & /@ sorted]|>]]]],
              #["Confidence"] &]];
          (* relation 1-hop 拡張: named topic から関連 topic を低 confidence で付与 (RelationGraph 指定時) *)
          relAssigns = If[AssociationQ[relGraph] && seedAssigns =!= {},
            Map[<|"TopicItemRef" -> #["To"], "MatchedSurfaceForms" -> {},
                  "AssignmentKind" -> "RelationExpanded",
                  "Confidence" -> Min[0.45, 0.2 + 0.03*#["Weight"]],
                  "ViaSeed" -> #["ViaSeed"], "RelationWeight" -> #["Weight"]|> &,
              SourceVaultExpandTopicsByRelation[#["TopicItemRef"] & /@ seedAssigns, relGraph,
                "MaxTotal" -> maxRel, "MinWeight" -> minRelW]],
            {}];
          (* AutoExtracted: seed 非該当の新トピック候補 (要確認; ExtractCandidates->True 時) *)
          candAssigns = If[TrueQ[extractCand],
            Map[<|"TopicItemRef" -> Missing["Unconfirmed"], "ProposedLabel" -> #["Surface"],
                  "MatchedSurfaceForms" -> {#["Surface"]}, "ExtractionKind" -> #["ExtractionKind"],
                  "AssignmentKind" -> "AutoExtracted", "Confidence" -> 0.2, "Status" -> "Candidate"|> &,
              SourceVaultExtractCandidateTopics[para["Text"],
                "KnownSurfaceIndex" -> surfaceIndex, "Limit" -> candLim]],
            {}];
          <|"ParagraphIndex" -> para["Index"], "Kind" -> para["Kind"],
            "Assignments" -> Join[seedAssigns, relAssigns, candAssigns]|>]]],
      paragraphs]];

(* ------------------------------------------------------------
   §6.5.4 / §6.3  weighted directed relation 取り込み ＋ 1-hop 拡張
   ------------------------------------------------------------ *)

Options[SourceVaultImportOOPSItemRelations] = {"Direction" -> "Down"};
SourceVaultImportOOPSItemRelations[path_String, OptionsPattern[]] := Module[{s, exprs, rules, dir},
  If[! FileExistsQ[path], Return[Failure["FileNotFound", <|"MessageTemplate" -> path|>]]];
  dir = OptionValue["Direction"];
  s = iSVDecodeLegacyJapaneseFile[path, "ShiftJIS"];
  exprs = iSVReadAllSExpr[s];
  rules = Reap[Module[{i = 1, len = Length[exprs], key, val},
      While[i + 1 <= len,
        key = exprs[[i]]; val = exprs[[i + 1]];
        If[MatchQ[key, {SVSym[_String], _Integer}] && ListQ[val],
          Sow[("svtopic:oops:" <> key[[1, 1]] <> ":" <> ToString[key[[2]]]) ->
            Cases[val, {{SVSym[ns_String], lid_Integer}, w_Integer} :>
              <|"To" -> "svtopic:oops:" <> ns <> ":" <> ToString[lid], "Weight" -> w, "Direction" -> dir|>]]];
        i += 2]]][[2]];
  rules = If[rules === {}, {}, First[rules]];
  <|"Relations" -> Association[rules], "Count" -> Length[rules], "SourcePath" -> path, "Direction" -> dir|>];

SourceVaultBuildOOPSRelationGraph[tableDir_String, opts___] := Module[{down, up, merged},
  down = SourceVaultImportOOPSItemRelations[FileNameJoin[{tableDir, "item-relation.index"}], "Direction" -> "Down"];
  up = SourceVaultImportOOPSItemRelations[FileNameJoin[{tableDir, "item-relation-up.index"}], "Direction" -> "Up"];
  If[FailureQ[down], Return[down]];
  merged = Merge[{Lookup[down, "Relations", <||>],
     If[FailureQ[up], <||>, Lookup[up, "Relations", <||>]]}, Apply[Join]];
  <|"RelationGraph" -> merged, "Count" -> Length[merged], "TableDir" -> tableDir|>];

Options[SourceVaultExpandTopicsByRelation] = {"MaxNeighborsPerSeed" -> 5, "MinWeight" -> 1, "MaxTotal" -> 20};
SourceVaultExpandTopicsByRelation[refs_List, relationGraph_Association, OptionsPattern[]] :=
  Module[{seeds = Union[refs], expanded},
    expanded = Flatten@Map[Function[ref,
      Module[{nbrs = Select[Lookup[relationGraph, ref, {}], #["Weight"] >= OptionValue["MinWeight"] &]},
        Map[Append[#, "ViaSeed" -> ref] &,
          Take[ReverseSortBy[nbrs, #["Weight"] &], UpTo[OptionValue["MaxNeighborsPerSeed"]]]]]], seeds];
    expanded = Select[expanded, ! MemberQ[seeds, #["To"]] &];
    expanded = Map[First@ReverseSortBy[#, #["Weight"] &] &, Values@GroupBy[expanded, #["To"] &]];
    Take[ReverseSortBy[expanded, #["Weight"] &], UpTo[OptionValue["MaxTotal"]]]];

(* ------------------------------------------------------------
   §6.5.5  AutoExtracted: seed 非該当の新トピック候補抽出 (語彙外/post-2005 対応)
   seed surface に無い salient な語 (katakana 連続/漢字熟語/Latin/引用) を候補化する。
   auto-confirm は既定 off (候補のみ; owner 確認で正規 topic 化)。
   ------------------------------------------------------------ *)

$svStopwordsEn = {"the", "and", "for", "you", "this", "that", "with", "are", "was", "but",
  "not", "from", "have", "has", "will", "can", "all", "one", "out", "com", "www",
  "http", "https", "org", "net", "your", "our", "its", "etc", "via", "per",
  "ki", "mi", "aga", "tom", "ara", "lki", "caitsith"};  (* 末尾は OOPS namespace ref 残骸 *)
$svStopwordsJa = {"場合", "問題", "情報", "時間", "今回", "以下", "以上", "内容", "必要",
  "可能", "関係", "状態", "方法", "結果", "現在", "場所", "部分", "全体", "一部",
  "自分", "相手", "世界", "日本", "今日", "明日", "昨日", "意味", "理由", "感じ",
  "記事", "事実", "立場", "コメント", "メール", "予定", "確認", "以前"};

Options[SourceVaultExtractCandidateTopics] = {"KnownSurfaceIndex" -> None, "Limit" -> 15,
  "MinKatakana" -> 3, "MinKanji" -> 2, "MaxKanji" -> 6, "MinLatin" -> 2};
SourceVaultExtractCandidateTopics[text_String, OptionsPattern[]] := Module[
  {minKata = OptionValue["MinKatakana"], minKanji = OptionValue["MinKanji"],
   maxKanji = OptionValue["MaxKanji"], minLatin = OptionValue["MinLatin"],
   known = OptionValue["KnownSurfaceIndex"], lim = OptionValue["Limit"],
   kata, kanji, latin, quoted, raw, knownQ, stop, grouped},
  kata = StringCases[text,
    RegularExpression["[\\x{30A0}-\\x{30FF}\\x{FF66}-\\x{FF9F}]{" <> ToString[minKata] <> ",}"]];
  kanji = StringCases[text,
    RegularExpression["[\\x{4E00}-\\x{9FFF}]{" <> ToString[minKanji] <> "," <> ToString[maxKanji] <> "}"]];
  latin = StringCases[text,
    RegularExpression["[A-Za-z][A-Za-z0-9\\-]{" <> ToString[Max[minLatin - 1, 0]] <> ",}"]];
  (* 引用語は短いコンパクト語のみ (句読点/空白/改行を含む節・全文は topic でない。長さ上限で節を排除) *)
  quoted = StringCases[text, RegularExpression["[「『]([^」』。、，．\\s]{2,8})[」』]"] -> "$1"];
  raw = Join[{#, "Katakana"} & /@ kata, {#, "Kanji"} & /@ kanji,
    {#, "Latin"} & /@ latin, {#, "Quoted"} & /@ quoted];
  knownQ = If[AssociationQ[known],
    Function[s, KeyExistsQ[known, iSVNormalizeSearchText[s]]], Function[s, False]];
  stop = Join[$svStopwordsEn, $svStopwordsJa];
  grouped = GroupBy[
    Select[raw, Function[pair,
      With[{s = pair[[1]], n = iSVNormalizeSearchText[pair[[1]]]},
        StringLength[n] >= 2 && ! iSVDegenerateStrQ[s] && ! knownQ[s] && ! MemberQ[stop, n]]]],
    iSVNormalizeSearchText[#[[1]]] &];
  Take[ReverseSortBy[
    KeyValueMap[Function[{normKey, members},
      <|"Surface" -> First[Commonest[#[[1]] & /@ members]],
        "ExtractionKind" -> First[Commonest[#[[2]] & /@ members]],
        "Count" -> Length[members]|>], grouped],
    {#["Count"], StringLength[#["Surface"]]} &], UpTo[lim]]];

(* ------------------------------------------------------------
   §6.5.6  seed → 検索の接続: auto-tag の topic を検索 index へ注入する enrichment
   chunk["SearchFields"]["topics"] に TopicsFieldText を載せると、本文に出ない
   正準ラベル/関連トピックでの検索が auto-tag 経由でヒットする (プロジェクトの主張)。
   ------------------------------------------------------------ *)

Options[SourceVaultTopicEnrichment] = {"RefLabel" -> None, "RelationGraph" -> None,
  "IncludeRelated" -> True, "MaxRelationTopics" -> 6, "MinRelationWeight" -> 2};
SourceVaultTopicEnrichment[text_String, surfaceIndex_Association, OptionsPattern[]] := Module[
  {refLabel = OptionValue["RefLabel"], relGraph = OptionValue["RelationGraph"],
   inclRel = TrueQ[OptionValue["IncludeRelated"]], assigns, seed, rel, labelOf, seedRefs, relRefs},
  labelOf = If[AssociationQ[refLabel], Function[r, Lookup[refLabel, r, r]], Identity];
  assigns = First[SourceVaultAssignParagraphTopics[
      {<|"Index" -> 1, "Kind" -> "Prose", "Text" -> text|>}, surfaceIndex,
      "ProseOnly" -> False, "RelationGraph" -> If[inclRel, relGraph, None],
      "MaxRelationTopics" -> OptionValue["MaxRelationTopics"],
      "MinRelationWeight" -> OptionValue["MinRelationWeight"]]]["Assignments"];
  seed = Select[assigns, #["AssignmentKind"] === "SeedMatched" &];
  rel = Select[assigns, #["AssignmentKind"] === "RelationExpanded" &];
  seedRefs = #["TopicItemRef"] & /@ seed;
  relRefs = #["TopicItemRef"] & /@ rel;
  <|"TopicRefs" -> seedRefs,
    "TopicLabels" -> DeleteDuplicates[labelOf /@ seedRefs],
    "RelatedRefs" -> relRefs,
    "RelatedLabels" -> DeleteDuplicates[labelOf /@ relRefs],
    "TopicsFieldText" -> StringRiffle[
      DeleteDuplicates[labelOf /@ Join[seedRefs, If[inclRel, relRefs, {}]]], " "]|>];

(* ------------------------------------------------------------
   §6.3  KG local expansion: seed topic refs を weighted topic relation で
   multi-hop BFS 展開する (node 上限/weight 閾値/cycle 安全, edges+trace 付き)。
   ExpandTopicsByRelation(auto-tag 用 1-hop) と役割分担。EdgeKinds は当面 TopicRelation のみ
   (SharedTag/SharedAuthor/Interaction は object infra 整備後に追加)。
   ------------------------------------------------------------ *)

Options[SourceVaultExpandSearchGraph] = {"RelationGraph" -> None, "MaxHops" -> 2, "MaxNodes" -> 50,
  "MinEdgeWeight" -> 1, "MaxNeighborsPerNode" -> 10, "RefLabel" -> None,
  "EdgeKinds" -> {"TopicRelation"}, "ReleaseContext" -> None};
SourceVaultExpandSearchGraph[seeds_List, OptionsPattern[]] := Module[
  {relGraph = OptionValue["RelationGraph"], maxHops = OptionValue["MaxHops"],
   maxNodes = OptionValue["MaxNodes"], minW = OptionValue["MinEdgeWeight"],
   maxNbr = OptionValue["MaxNeighborsPerNode"],
   refLabel = OptionValue["RefLabel"], edgeKinds = OptionValue["EdgeKinds"],
   rc = OptionValue["ReleaseContext"], labelOf, visited, frontier, expanded, edges, trace, capped},
  labelOf = If[AssociationQ[refLabel], Function[r, Lookup[refLabel, r, r]], Identity];
  If[! AssociationQ[relGraph] || ! MemberQ[edgeKinds, "TopicRelation"],
    Return[<|"Seeds" -> seeds, "Expanded" -> {}, "Edges" -> {}, "NodeCount" -> 0, "EdgeCount" -> 0,
      "Capped" -> False, "Trace" -> {<|"Step" -> "init",
        "Note" -> "RelationGraph 無し or TopicRelation edge kind 無効"|>}|>]];
  visited = Association[(# -> True) & /@ seeds];
  frontier = DeleteDuplicates[seeds]; expanded = {}; edges = {}; trace = {}; capped = False;
  Do[
    Module[{next = {}},
      Do[
        Module[{nbrs = Take[ReverseSortBy[
            Select[Lookup[relGraph, node, {}], #["Weight"] >= minW &], #["Weight"] &],
            UpTo[maxNbr]]},
          Do[
            With[{to = nb["To"], w = nb["Weight"]},
              AppendTo[edges, <|"From" -> node, "To" -> to, "Weight" -> w,
                "Kind" -> "TopicRelation", "Direction" -> Lookup[nb, "Direction", Missing[]]|>];
              If[! KeyExistsQ[visited, to],
                If[Length[expanded] >= maxNodes, capped = True,
                  visited[to] = True;
                  AppendTo[expanded, <|"Ref" -> to, "Label" -> labelOf[to], "Hop" -> hop,
                    "Weight" -> w, "ViaSeed" -> node|>];
                  AppendTo[next, to]]]],
            {nb, nbrs}]],
        {node, frontier}];
      AppendTo[trace, <|"Step" -> "hop", "Hop" -> hop, "FrontierIn" -> Length[frontier],
        "NewNodes" -> Length[next], "TotalNodes" -> Length[expanded]|>];
      frontier = next;
      If[frontier === {} || capped, Break[]]],
    {hop, 1, maxHops}];
  If[capped, AppendTo[trace, <|"Step" -> "cap", "Note" -> "MaxNodes に到達", "MaxNodes" -> maxNodes|>]];
  If[StringQ[rc], AppendTo[trace, <|"Step" -> "gate",
    "Note" -> "topic node は metadata。release gate/revocation は対応 content chunk 検索時に適用",
    "ReleaseContext" -> rc|>]];
  <|"Seeds" -> seeds, "Expanded" -> expanded, "Edges" -> edges,
    "NodeCount" -> Length[expanded], "EdgeCount" -> Length[edges], "Capped" -> capped,
    "Trace" -> trace|>];

(* ------------------------------------------------------------
   §6.5.5  AutoExtracted 確認ワークフロー: owner が確認した候補を seed と同形の
   新 topic entry にして dictionary に merge する (candidate→確認済 topic→検索可能)。
   永続(ファイル/DB)は owner 選択で別途。auto-confirm は行わない。
   ------------------------------------------------------------ *)

Options[SourceVaultConfirmCandidateTopics] = {"ExistingDictionary" -> None,
  "RefPrefix" -> "svtopic:extracted", "StartId" -> 1, "OwnerRef" -> None, "PrivacyLevel" -> 0.3};
SourceVaultConfirmCandidateTopics[candidates_List, OptionsPattern[]] := Module[
  {prefix = OptionValue["RefPrefix"], startId = OptionValue["StartId"],
   owner = OptionValue["OwnerRef"], pl = OptionValue["PrivacyLevel"],
   existing = OptionValue["ExistingDictionary"], entries, result},
  entries = MapIndexed[Function[{c, i},
    Module[{surf = If[AssociationQ[c], Lookup[c, "Surface", ToString[c]], ToString[c]],
            kind = If[AssociationQ[c], Lookup[c, "ExtractionKind", Missing[]], Missing[]],
            id = startId + i[[1]] - 1},
      <|"TopicItemRef" -> prefix <> ":" <> ToString[id],
        "Namespace" -> "extracted", "LocalId" -> id,
        "CanonicalLabel" -> surf, "SurfaceForms" -> {surf},
        "NamespaceKind" -> "Extracted", "OwnerRef" -> owner, "PrivacyLevel" -> pl,
        "Provenance" -> <|"Source" -> "AutoExtracted", "ExtractionKind" -> kind|>|>]],
    candidates];
  result = <|"ConfirmedEntries" -> entries, "Count" -> Length[entries]|>;
  If[AssociationQ[existing],
    result = Append[result, "MergedDictionary" -> Append[existing,
      "Entries" -> Join[Lookup[existing, "Entries", {}], entries]]]];
  result];

(* ------------------------------------------------------------
   §7.2  mail → 検索 chunk ビルダ (auto-tag topic enrichment を粒度別に baked-in)
   Paragraph 粒度なら topic は段落単位で付き whole-mail より precision が高い。
   ------------------------------------------------------------ *)

Options[SourceVaultBuildMailChunks] = {"Granularity" -> "Paragraph", "RelationGraph" -> None,
  "RefLabel" -> None, "PrivacyLevel" -> 0.5, "ReleaseState" -> "Published",
  "IncludeRelated" -> True, "ObjectIdPrefix" -> "svobj:oops"};
SourceVaultBuildMailChunks[mail_Association, surfaceIndex_Association, OptionsPattern[]] := Module[
  {gran = OptionValue["Granularity"], relGraph = OptionValue["RelationGraph"],
   refLabel = OptionValue["RefLabel"], pl = OptionValue["PrivacyLevel"],
   state = OptionValue["ReleaseState"], inclRel = OptionValue["IncludeRelated"],
   objPrefix = OptionValue["ObjectIdPrefix"], counter, subject, from, objId, body, mk, paras},
  counter = ToString @ Lookup[mail, "Counter", "?"];
  subject = Lookup[mail, "Subject", ""]; from = Lookup[mail, "From", ""];
  objId = objPrefix <> ":" <> counter;
  body = SourceVaultStripOOPSMarkers[Lookup[mail, "Body", ""]];
  mk = Function[{cid, txt}, Module[{enr = SourceVaultTopicEnrichment[txt, surfaceIndex,
      "RefLabel" -> refLabel, "RelationGraph" -> relGraph, "IncludeRelated" -> inclRel]},
    <|"ChunkId" -> cid, "SourceVaultObjectId" -> objId,
      "SearchFields" -> <|"title" -> subject, "body" -> txt, "author" -> from,
        "topics" -> enr["TopicsFieldText"]|>,
      "Text" -> txt, "NormalizedText" -> SourceVaultNormalizeSearchText[txt],
      "PrivacyLevel" -> pl, "State" -> state, "Tags" -> {},
      "TopicRefs" -> enr["TopicRefs"], "RelatedRefs" -> enr["RelatedRefs"],
      "SourceRef" -> <|"Title" -> subject|>|>]];
  If[gran === "Mail",
    {mk["oops-" <> counter, body]},
    paras = Select[SourceVaultParseMailParagraphs[body], #["Kind"] === "Prose" &];
    MapIndexed[mk["oops-" <> counter <> "-p" <> ToString[#2[[1]]], #1["Text"]] &, paras]]];

(* 確認済 extracted topic の永続 (owner store)。dict["Entries"] に Join で seed 編入。 *)
SourceVaultSaveExtractedTopics[entries_List, path_String] := Module[{dir = DirectoryName[path]},
  If[StringQ[dir] && dir =!= "" && ! DirectoryQ[dir],
    Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];
  Quiet@Check[Export[path, <|"Version" -> 1, "Entries" -> entries|>, "WXF"];
    <|"Status" -> "Saved", "Path" -> path, "Count" -> Length[entries]|>,
    Failure["SaveFailed", <|"MessageTemplate" -> path|>]]];
SourceVaultLoadExtractedTopics[path_String] := If[! FileExistsQ[path],
  Failure["FileNotFound", <|"MessageTemplate" -> path|>],
  Module[{d = Quiet@Check[Import[path, "WXF"], $Failed]},
    If[AssociationQ[d], Lookup[d, "Entries", {}], Failure["BadFile", <|"MessageTemplate" -> path|>]]]];

(* ------------------------------------------------------------
   §6.5  quote tracking: 引用グラフ (メール→引用元メール)
   seed quote-table(authoritative) ＋ 本文 `-*- Quote (from N) -*-` マーカー。
   ------------------------------------------------------------ *)

(* quote-table.index: <mail#> ((idx (from src)(standard-quote qid))...) | nil の交互ペア *)
SourceVaultImportOOPSQuoteTable[path_String, opts___] := Module[{s, exprs, rules},
  If[! FileExistsQ[path], Return[Failure["FileNotFound", <|"MessageTemplate" -> path|>]]];
  s = iSVDecodeLegacyJapaneseFile[path, "ShiftJIS"];
  exprs = iSVReadAllSExpr[s];
  rules = Reap[Module[{i = 1, len = Length[exprs], key, val},
      While[i + 1 <= len,
        key = exprs[[i]]; val = exprs[[i + 1]];
        If[IntegerQ[key],
          Sow[key -> If[ListQ[val],
            Cases[val, {idx_Integer, {SVSym["from"], src_Integer}, {SVSym["standard-quote"], qid_Integer}} :>
              <|"Index" -> idx, "FromMail" -> src, "StandardQuoteId" -> qid|>],
            {}]]];
        i += 2]]][[2]];
  rules = If[rules === {}, {}, First[rules]];
  <|"Quotes" -> Association[rules], "Count" -> Length[rules], "SourcePath" -> path|>];

SourceVaultExtractMailQuoteMarkers[mail_Association] := Module[{body = Lookup[mail, "Body", ""], marks},
  marks = StringCases[body, "-*- Quote (from " ~~ ref : Shortest[__] ~~ ") -*-" :> StringTrim[ref]];
  Map[Function[r,
    If[StringMatchQ[r, DigitCharacter ..],
      <|"QuoteKind" -> "ExplicitMarker", "FromMail" -> FromDigits[r],
        "SourceMarker" -> "-*- Quote (from " <> r <> ") -*-"|>,
      <|"QuoteKind" -> "ExternalURL", "FromRef" -> r,
        "SourceMarker" -> "-*- Quote (from " <> r <> ") -*-"|>]], DeleteDuplicates[marks]]];

Options[SourceVaultBuildMailQuoteEdges] = {"QuoteTable" -> None};
SourceVaultBuildMailQuoteEdges[mails_List, OptionsPattern[]] := Module[
  {qt = OptionValue["QuoteTable"], mailRef, edges},
  mailRef = Function[n, "sv://mail/" <> ToString[n]];
  edges = Flatten@Map[Function[m,
    Module[{counter = Lookup[m, "Counter", Missing[]], seed, markers, seedFroms, seedEdges, markerEdges},
      (* seed quote-table(authoritative) *)
      seed = If[AssociationQ[qt], Lookup[qt, counter, {}], {}];
      seedEdges = Map[Function[q,
        <|"ObjectClass" -> "SourceVaultMailQuoteEdge",
          "QuoteEdgeId" -> "svquote:" <> ToString[counter] <> ":sq" <> ToString[q["StandardQuoteId"]],
          "SeedQuoteId" -> "standard-quote:" <> ToString[q["StandardQuoteId"]],
          "FromMailRef" -> mailRef[counter], "ToMailRef" -> mailRef[q["FromMail"]],
          "QuoteKind" -> "SeedStandardQuote", "Confidence" -> 1.0, "SourceMarker" -> Missing[]|>], seed];
      seedFroms = #["FromMail"] & /@ seed;
      (* 本文マーカー: seed に無い from(URL含む)・非 seed メール向け *)
      markers = SourceVaultExtractMailQuoteMarkers[m];
      markerEdges = Map[Function[mk,
        Which[
          mk["QuoteKind"] === "ExternalURL",
            <|"ObjectClass" -> "SourceVaultMailQuoteEdge",
              "QuoteEdgeId" -> "svquote:" <> ToString[counter] <> ":url" <> IntegerString[Hash[mk["FromRef"]], 16, 8],
              "SeedQuoteId" -> Missing[], "FromMailRef" -> mailRef[counter], "ToMailRef" -> mk["FromRef"],
              "QuoteKind" -> "ExternalURL", "Confidence" -> 0.9, "SourceMarker" -> mk["SourceMarker"]|>,
          ! MemberQ[seedFroms, mk["FromMail"]],  (* seed 未収録の explicit marker のみ(重複回避) *)
            <|"ObjectClass" -> "SourceVaultMailQuoteEdge",
              "QuoteEdgeId" -> "svquote:" <> ToString[counter] <> ":m" <> ToString[mk["FromMail"]],
              "SeedQuoteId" -> Missing[], "FromMailRef" -> mailRef[counter], "ToMailRef" -> mailRef[mk["FromMail"]],
              "QuoteKind" -> "ExplicitMarker", "Confidence" -> 0.9, "SourceMarker" -> mk["SourceMarker"]|>,
          True, Nothing]], markers];
      Join[seedEdges, markerEdges]]], mails];
  edges];

(* ------------------------------------------------------------
   §6.5  mail session / cluster: quote edge 連結成分 ＋ Subject Re:/Fwd: スレッド化
   ------------------------------------------------------------ *)

iSVMailRefNumber[ref_] := With[
  {m = StringCases[ToString[ref], "sv://mail/" ~~ n : DigitCharacter .. :> FromDigits[n]]},
  If[m === {}, Missing[], First[m]]];
iSVNormalizeSubject[subj_] := StringTrim@StringReplace[ToString[subj],
  StartOfString ~~ Longest[(("re" | "fwd" | "fw") ~~ (WhitespaceCharacter ...) ~~ ":" ~~ (WhitespaceCharacter ...)) ..] -> "",
  IgnoreCase -> True];

Options[SourceVaultBuildMailSessions] = {"SubjectThreading" -> True};
SourceVaultBuildMailSessions[mails_List, quoteEdges_List, OptionsPattern[]] := Module[
  {counters, byCounter, qEdges, sEdges, g, comps},
  counters = DeleteMissing[Lookup[#, "Counter", Missing[]] & /@ mails];
  byCounter = Association[(Lookup[#, "Counter", Missing[]] -> #) & /@ mails];
  (* quote edge (present-mail 間の無向辺) *)
  qEdges = DeleteDuplicates@DeleteCases[Map[Function[e,
    Module[{f = iSVMailRefNumber[e["FromMailRef"]], t = iSVMailRefNumber[e["ToMailRef"]]},
      If[IntegerQ[f] && IntegerQ[t] && f =!= t && MemberQ[counters, f] && MemberQ[counters, t],
        UndirectedEdge @@ Sort[{f, t}], Nothing]]], quoteEdges], Nothing];
  (* Subject 正規化スレッド (Re:/Fwd: を剥がし同一 subject を連結) *)
  sEdges = If[TrueQ[OptionValue["SubjectThreading"]],
    DeleteDuplicates@Flatten@Values@GroupBy[mails,
      iSVNormalizeSubject[Lookup[#, "Subject", ""]] &,
      Function[grp, With[{cs = Sort[Lookup[#, "Counter"] & /@ grp]},
        If[Length[cs] > 1, UndirectedEdge @@@ Partition[cs, 2, 1], {}]]]],
    {}];
  g = Graph[counters, DeleteDuplicates[Join[qEdges, sEdges]]];
  comps = ConnectedComponents[g];
  Map[Function[comp, Module[{cms = Sort[comp], sessMails, hasQuote, kind},
    sessMails = DeleteMissing[Lookup[byCounter, cms]];
    hasQuote = AnyTrue[qEdges, MemberQ[cms, #[[1]]] && MemberQ[cms, #[[2]]] &];
    kind = Which[Length[cms] == 1, "Singleton", hasQuote, "QuoteCluster", True, "ReplyThread"];
    <|"ObjectClass" -> "SourceVaultMailSession",
      "MailSessionId" -> "svmailsession:" <> ToString[First[cms]] <> "-" <> ToString[Last[cms]],
      "MailCounters" -> cms, "MailRefs" -> ("sv://mail/" <> ToString[#] & /@ cms),
      "MailCount" -> Length[cms], "SessionKind" -> kind,
      "Subject" -> If[sessMails === {}, "", Lookup[First[sessMails], "Subject", ""]],
      "StartMailCounter" -> First[cms], "EndMailCounter" -> Last[cms]|>]],
    ReverseSortBy[comps, Length]]];

(* ------------------------------------------------------------
   §6.5  topic item graph: 段落 topic ＋ quote/relation を束ねたグラフ
   Nodes = topic item (SupportParagraphs 付き)。Edges =
   CoParagraph(同一段落共起) / QuoteTransition(quote edge 越し) / SeedRelation(seed 関係)。
   ------------------------------------------------------------ *)

Options[SourceVaultBuildTopicItemGraph] = {"SurfaceIndex" -> None, "RelationGraph" -> None,
  "RefLabel" -> None, "QuoteEdges" -> {}, "SessionRefs" -> {}};
SourceVaultBuildTopicItemGraph[mails_List, OptionsPattern[]] := Module[
  {sidx = OptionValue["SurfaceIndex"], relGraph = OptionValue["RelationGraph"],
   refLabel = OptionValue["RefLabel"], quoteEdges = OptionValue["QuoteEdges"],
   label, paraTopics, nodeGroups, nodes, nodeRefs, coEdges, mailTopics, qtEdges, seedEdges},
  If[! AssociationQ[sidx], Return[Failure["SurfaceIndexRequired",
    <|"MessageTemplate" -> "SourceVaultBuildTopicItemGraph には \"SurfaceIndex\" が必須です。"|>]]];
  label = If[AssociationQ[refLabel], Function[r, Lookup[refLabel, r, r]], Identity];
  (* 各メール各 prose 段落の SeedMatched topic *)
  paraTopics = Flatten@Map[Function[m,
    Module[{counter = Lookup[m, "Counter", "?"], paras, assigned},
      paras = SourceVaultParseMailParagraphs[SourceVaultStripOOPSMarkers[Lookup[m, "Body", ""]]];
      assigned = SourceVaultAssignParagraphTopics[paras, sidx, "RefLabel" -> refLabel];
      Map[Function[a,
        With[{trefs = DeleteDuplicates[#["TopicItemRef"] & /@
             Select[a["Assignments"], #["AssignmentKind"] === "SeedMatched" &]]},
          If[trefs === {}, Nothing,
            <|"MailCounter" -> counter,
              "ParaRef" -> "svmailpara:" <> ToString[counter] <> ":" <> ToString[a["ParagraphIndex"]],
              "TopicRefs" -> trefs|>]]], assigned]]], mails];
  (* nodes: topic -> SupportParagraphs *)
  nodeGroups = GroupBy[
    Flatten@Map[Function[pt, (<|"Ref" -> #, "ParaRef" -> pt["ParaRef"]|>) & /@ pt["TopicRefs"]], paraTopics],
    #["Ref"] &];
  nodes = KeyValueMap[Function[{ref, es},
    <|"TopicItemRef" -> ref, "Label" -> label[ref],
      "SupportParagraphs" -> DeleteDuplicates[#["ParaRef"] & /@ es]|>], nodeGroups];
  nodeRefs = Keys[nodeGroups];
  (* CoParagraph: 同一段落に出た topic ペア *)
  coEdges = KeyValueMap[Function[{pair, paraRefs},
    <|"From" -> pair[[1]], "To" -> pair[[2]], "EdgeKind" -> "CoParagraph",
      "Weight" -> Length[DeleteDuplicates[paraRefs]], "EvidenceRefs" -> DeleteDuplicates[paraRefs]|>],
    GroupBy[Flatten[Function[pt, With[{tr = pt["TopicRefs"]},
      If[Length[tr] >= 2, (Sort[#] -> pt["ParaRef"]) & /@ Subsets[tr, {2}], {}]]] /@ paraTopics, 1],
      First -> Last]];
  (* QuoteTransition: quote edge の from-mail topic ↔ to-mail topic *)
  mailTopics = Association @ KeyValueMap[#1 -> DeleteDuplicates@Flatten[#["TopicRefs"] & /@ #2] &,
    GroupBy[paraTopics, #["MailCounter"] &]];
  qtEdges = KeyValueMap[Function[{pair, evs},
    <|"From" -> pair[[1]], "To" -> pair[[2]], "EdgeKind" -> "QuoteTransition",
      "Weight" -> Length[DeleteDuplicates[evs]], "EvidenceRefs" -> DeleteDuplicates[evs]|>],
    GroupBy[Flatten[Map[Function[e,
      Module[{f = iSVMailRefNumber[e["FromMailRef"]], t = iSVMailRefNumber[e["ToMailRef"]], ft, tt},
        ft = Lookup[mailTopics, f, {}]; tt = Lookup[mailTopics, t, {}];
        If[ft =!= {} && tt =!= {},
          DeleteCases[Flatten[Outer[If[#1 =!= #2, Sort[{#1, #2}] -> e["QuoteEdgeId"], Nothing] &, ft, tt], 1], Nothing],
          {}]]], quoteEdges], 1], First -> Last]];
  (* SeedRelation: グラフ内 node 間に seed 関係がある辺 *)
  seedEdges = If[AssociationQ[relGraph],
    DeleteDuplicatesBy[Flatten@Map[Function[a,
      Map[<|"From" -> a, "To" -> #["To"], "EdgeKind" -> "SeedRelation",
          "Weight" -> #["Weight"], "EvidenceRefs" -> {}|> &,
        Select[Lookup[relGraph, a, {}], MemberQ[nodeRefs, #["To"]] &]]], nodeRefs],
      {#["From"], #["To"]} &],
    {}];
  <|"ObjectClass" -> "SourceVaultTopicItemGraph",
    "GraphId" -> "svtopicgraph:" <> ToString[Min[DeleteMissing[Lookup[#, "Counter", Missing[]] & /@ mails]]],
    "Nodes" -> nodes, "Edges" -> Join[coEdges, qtEdges, seedEdges],
    "MailSessionRefs" -> OptionValue["SessionRefs"],
    "NodeCount" -> Length[nodes], "EdgeCount" -> Length[coEdges] + Length[qtEdges] + Length[seedEdges],
    "EdgeKindTally" -> <|"CoParagraph" -> Length[coEdges], "QuoteTransition" -> Length[qtEdges],
      "SeedRelation" -> Length[seedEdges]|>|>];

End[];

EndPackage[];
