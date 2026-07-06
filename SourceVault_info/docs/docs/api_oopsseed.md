# SourceVault_oopsseed API Reference

## 概要

OOPS(草の根 ML アーカイブ)の legacy seed ontology を読み込み、検索基盤(§7.2 chunk 形式)に接続するための一群のプリミティブ。ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_oopsseed.wl"]]`。

設計原則(レビュー由来 r1-r5):
- namespace は enum で決め打ちしない。実データに ki/aga/e/mi/caitsith/tom/ara/anonymous および typo(catisith,lki)の10種が存在し、汎用的に `(SYMBOL INT)` として読む。
- index ファイルは「S式風」ではなく本物の Common Lisp S式。regex や単純行分割では読まない。
- 文字エンコーディングは実機で確定済み: item-name.index は CR 区切りの ShiftJIS(CP932)。ESC(27)=0 なので ISO-2022-JP ではない。0x85 は CP932 二重バイトの一部であり NEL 行終端ではない。quoted-table.index 等の mixed file には `iSVDecodeLegacyJapanese` の cascade を用いる。
- owner-scoped: ki=owner(imai) namespace、mi/aga 等は別 owner namespace。未解決 owner は drop せず `Missing["UnknownOwner"]` とする。
- mail-info.index の ByteStart/ByteEnd は2005年原ファイル基準で現 UTF-8 ファイルでは無効。本文抽出は mbox 直接 parse(`SourceVaultParseOOPSMailFile`)を使う。

対応する仕様書: `ドキュメント/sourcevault_search_foundation_implementation_spec_v1.md` §4.1.1(seed entity dictionary), §6.5.1(owner-scoped topic item), §6.5.2(seed import parser), §6.5.3(privacy defense-in-depth), §6.3(KG 局所探索), §7.2(検索 chunk)。

## S式 reader / legacy decode

### SourceVaultReadSExprString[s] → List
Common Lisp S式の文字列 s を読み、top-level S式のリストを返す。`(...)`→List、`"..."`→String、整数→Integer、bareword(nil 含む)→`SourceVault\`SVSym[name]`。

## Seed entity dictionary(item-name.index)

### SourceVaultImportOOPSItemNames[path, opts]
OOPS の item-name.index を読み、topic name records のリストを返す。
→ `{<|"Namespace","LocalId","CanonicalLabel","SurfaceForms","LanguageHints"|>, ...}`
Options: "Encoding" -> "ShiftJIS"

### SourceVaultBuildSeedEntityDictionary[items, opts]
item-name records から owner-scoped な SourceVaultSeedEntityDictionary(仕様 §4.1.1)を作る。
→ Association
Options: "OwnerMap" -> Automatic, "PersonNamespaces" -> Automatic, "DictionaryId" -> Automatic, "SharedNamespaces" -> Automatic

### SourceVaultSeedDictionaryStats[dict] → Association
seed entity dictionary の検証用統計(namespace 分布、owner 解決率、bilingual 数、surface form 総数など)を返す純関数。

### SourceVaultImportOOPSSeedDictionary[itemNameIndexPath, opts] → Association
import + dictionary build を一括で行う便宜関数(`SourceVaultImportOOPSItemNames` → `SourceVaultBuildSeedEntityDictionary`)。

## Mail import / parse

### SourceVaultImportOOPSMailToItem[path] → Association
mail-to-item.index を読み `<|mailNumber -> {<|"Namespace","LocalId","Role"(title/body)|>, ...}|>` を返す。人手が付与した topic の gold データ(held-out 実験用)。

### SourceVaultImportOOPSMailInfo[path] → Association
mail-info.index を読み `<|mailNumber -> <|"List","Hash","Author","SourceFile","ByteStart","ByteEnd"|>|>` を返す。List 名(oops/oops-ura)は privacy 入力。ByteStart/ByteEnd は現 UTF-8 ファイルでは無効なので使わない。

### SourceVaultParseOOPSMailFile[path] → List
UTF-8 の oops*.txt を mbox として parse する。CR 行終端対応。
→ `{<|"Counter","MlName","Subject","From","To","Cc","Date","Body"|>, ...}`
Counter(X-Ml-Counter)で gold(mail-to-item)と join する。

### SourceVaultStripOOPSMarkers[text] → String
OOPS の topic ID ref(`[ns n]`)、brace wrapper、◎○・ structural marker を除去し query 用 plain text を返す。label 本文は残す(held-out で cheat 防止)。

## Privacy

### SourceVaultMailRecipientPrivacy[mail] → Association
To/Cc の addr-spec から privacy シグナルを導く(§6.5.3 defense-in-depth、一般メール向け=X-Ml-Name に依らない)。
→ `<|"PrivacyLevel","Tags","Signal","Recipients"|>`
私的リストアドレス(oops-ura 等)宛は PrivateML/NoCloudLLM/NoPublicExport、個人宛のみは DirectRecipients、それ以外は neutral(0.0)。list 由来 privacy と max/union で結合する。

## Paragraph / topic assignment(auto-tag)

### SourceVaultParseMailParagraphs[body] → List
mail 本文を段落に分割する。空行区切りで引用/署名/footer を分離(§6.5)。
→ `{<|"Index","Kind"(Prose/Quote/Signature/Footer),"Text"|>, ...}`

### SourceVaultAssignParagraphTopics[paragraphs, surfaceIndex, opts]
各 prose 段落に対し seed 辞書の surface form OR-match で topic item を自動割当する(auto-tag)。各割当は TopicItemRef/MatchedSurfaceForms/Confidence/AssignmentKind="SeedMatched"。`"RelationGraph"` を渡すと named topic から1-hopの関連 topic を低 confidence の AssignmentKind="RelationExpanded"(ViaSeed/RelationWeight 付き)として追加する。surfaceIndex は `SourceVaultBuildSurfaceIndex[dict]`(他パッケージ由来)で作る。
→ List
Options: "MinSurfaceLength" -> 2, "TopicLimit" -> 10, "ProseOnly" -> True, "RelationGraph" -> None, "MaxRelationTopics" -> 8, "MinRelationWeight" -> 2

## Relation graph

### SourceVaultImportOOPSItemRelations[path, opts]
item-relation.index / item-relation-up.index を読み、重み付き有向 relation を返す。
→ `<|TopicItemRef -> {<|"To","Weight","Direction"|>...}|>`
Options: "Direction" -> "Down"

### SourceVaultBuildOOPSRelationGraph[tableDir] → Association
item-relation.index(Down)＋item-relation-up.index(Up)を結合した relation graph `<|TopicItemRef -> {neighbor...}|>` を返す。

### SourceVaultExpandTopicsByRelation[refs, relationGraph, opts]
seed topic 集合を重み付き1-hop近傍へ拡張する。seed 自身は除外し To 単位で最大重みに dedup、重み降順。KG 局所探索(§6.3)・auto-tag 拡張に使う。
→ List
Options: "MaxNeighborsPerSeed" -> 5, "MinWeight" -> 1, "MaxTotal" -> 20

### SourceVaultExpandSearchGraph[seeds, opts]
§6.3 KG 局所探索。seed topic refs から重み付き topic relation を multi-hop で BFS 展開する(node 上限/weight 閾値/cycle 安全)。`SourceVaultExpandTopicsByRelation` は auto-tag 用1-hop、本関数は検索用 multi-hop(edges/trace 付き)。
→ `<|"Seeds","Expanded","Edges","Trace"|>`
Options: "RelationGraph" -> (実質必須), "MaxHops" -> 2, "MaxNodes" -> 50, "MinEdgeWeight" -> 1, "RefLabel" -> None, "EdgeKinds" -> {"TopicRelation"}(SharedTag/SharedAuthor/Interaction は将来), "ReleaseContext" -> None

## Candidate topic extraction / confirmation

### SourceVaultExtractCandidateTopics[text, opts]
seed に無い新トピック候補を本文から抽出する(語彙外対応)。katakana 連続/漢字熟語/Latin トークン/「」『』引用語を salient な候補として返す。seed 既知語(KnownSurfaceIndex)・stopword・退化語は除外、出現数→長さで順位。
→ `{<|"Surface","ExtractionKind","Count"|>...}`
Options: "KnownSurfaceIndex" -> None, "Limit" -> 15, "MinKatakana" -> 3, "MinKanji" -> 2, "MaxKanji" -> 6, "MinLatin" -> 2
auto-tag では AssignmentKind="AutoExtracted"(要確認候補)として扱う。

### SourceVaultExtractExplicitTopics[text] → List
OOPS の明示 topic マーカー ◎(Primary)/○(Secondary)/・(Mentioned) `<label>[ns id]` と本文 `{label[ns id]}` を抽出する。`[ns id]` が topic ref を直接与える人手付与の最高品質シグナル(§6.5 点1)。
→ `{<|"TopicItemRef","CanonicalLabel","TopicRole","AssignmentKind"->"ExplicitOOPS","Confidence"->1.0|>...}`

### SourceVaultTopicEnrichment[text, surfaceIndex, opts]
本文に auto-tag を走らせ、検索 index に注入する topic 情報(SeedMatched の正準ラベル＋RelationExpanded の関連ラベル)を返す。chunk の SearchFields["topics"] に TopicsFieldText を載せると「本文に出ない正準/関連ラベル」で検索ヒットするようになる(seed→検索の接続)。
→ `<|"TopicRefs","TopicLabels","RelatedRefs","RelatedLabels","TopicsFieldText"|>`
Options: "RefLabel" -> (ref->canonical label の Association), "RelationGraph" -> None, "IncludeRelated" -> True, "MaxRelationTopics" -> 6, "MinRelationWeight" -> 2

### SourceVaultConfirmCandidateTopics[candidates, opts]
AutoExtracted 候補(owner が確認したもの)を seed と同形の新 topic entry(TopicItemRef/CanonicalLabel/SurfaceForms/NamespaceKind="Extracted"/Provenance)にする。candidates は `{<|"Surface","ExtractionKind"|>...}` か `{label string...}`。
→ `<|"ConfirmedEntries","Count",("MergedDictionary")|>`
Options: "ExistingDictionary" -> None(渡すと Entries を merge した MergedDictionary を返す→BuildSurfaceIndex で検索可能に), "RefPrefix" -> "svtopic:extracted", "StartId" -> 1, "OwnerRef" -> None, "PrivacyLevel" -> 0.3
永続化は `SourceVaultSaveExtractedTopics` を使う。

### SourceVaultSaveExtractedTopics[entries, path]
確認済 extracted topic entry を WXF で永続化する。

### SourceVaultLoadExtractedTopics[path] → List
`SourceVaultSaveExtractedTopics` で保存した entry リストを返す。読み戻した後は `dict["Entries"]` に Join すれば seed に編入できる。

## 検索 chunk 構築

### SourceVaultBuildMailChunks[mail, surfaceIndex, opts]
parse 済 mail を §7.2 検索 chunk のリストにする。各 chunk は SearchFields(title/body/author/topics)＋Text/NormalizedText＋PrivacyLevel/State/Tags＋TopicRefs/RelatedRefs。topics は `SourceVaultTopicEnrichment` で auto-tag 注入する。
→ List
Options: "Granularity" -> "Paragraph"("Mail" も可), "RelationGraph" -> None, "RefLabel" -> None, "PrivacyLevel" -> 0.5, "ReleaseState" -> "Published", "IncludeRelated" -> True, "ObjectIdPrefix" -> "svobj:oops"
Paragraph 粒度なら topic は段落単位で付くので whole-mail より precision が高い。

## Quote tracking

### SourceVaultImportOOPSQuoteTable[path] → Association
quote-table.index を読み `<|mailNumber -> {<|"Index","FromMail","StandardQuoteId"|>...}|>` を返す。各メールが引用している元メール(FromMail)と seed の standard-quote id。OOPS seed の authoritative な引用グラフ。

### SourceVaultExtractMailQuoteMarkers[mail] → List
本文の `` -*- Quote (from N) -*- `` マーカーを抽出する。N が整数なら ExplicitMarker(FromMail)、URL なら ExternalURL(FromRef)。
→ `{<|"QuoteKind",("FromMail"|"FromRef"),"SourceMarker"|>...}`

### SourceVaultBuildMailQuoteEdges[mails, opts]
SourceVaultMailQuoteEdge のリストを作る(§6.5 quote tracking)。seed quote-table(authoritative)を `"QuoteTable"` で渡すと SeedStandardQuote edge を、本文マーカーからは ExplicitMarker/ExternalURL edge を作る。
→ `{<|"ObjectClass","QuoteEdgeId","SeedQuoteId","FromMailRef","ToMailRef","QuoteKind","Confidence","SourceMarker"|>...}`
Options: "QuoteTable" -> None

## Session(thread)構築

### SourceVaultBuildMailSessions[mails, quoteEdges, opts]
quote edge の連結成分＋Subject の Re:/Fwd: 正規化でメールをセッション(スレッド)にまとめる(§6.5 session/cluster)。quote 連結が有れば SessionKind="QuoteCluster"、Subject のみなら "ReplyThread"。
→ `{SourceVaultMailSession...}`: `<|MailSessionId,MailCounters,MailRefs,MailCount,SessionKind(ReplyThread|QuoteCluster|Singleton),Subject,StartMailCounter,EndMailCounter|>`
Options: "SubjectThreading" -> True

### SourceVaultBuildSessionChunks[mails, sessions, opts]
session(スレッド)単位の §7.2 検索 chunk を作る。各 chunk は session の全メール本文を連結し、Subject/著者/topic(TopicEnrichment 注入)を持つ。query がスレッド全体を引ける(§6.5「結論」query 向け)。PrivacyLevel/Tags は §6.5.3 の list(oops/oops-ura)由来を session 内 max/union で採る。
→ List
Options: "SurfaceIndex" -> (必須相当), "RelationGraph" -> None, "RefLabel" -> None, "PrivacyLevel" -> Automatic(list由来), "ReleaseState" -> "Published", "MaxBodyChars" -> 4000

### SourceVaultBuildSessionDigest[session, mails, opts] → String
LLM を使わない決定的なスレッド要約(digest)文字列を作る。Subject＋話題(topic ラベル)＋各メールの先頭 prose 段落のタイムライン。
Options: "SurfaceIndex" -> None, "RefLabel" -> None, "MaxMails" -> 8, "ParaChars" -> 120, "PrimaryTopicsOnly" -> True(話題を◎Primary明示 topic に限定=精密。無ければ enrichment 上位に fallback), "FallbackTopics" -> 6

## Topic item graph

### SourceVaultBuildTopicItemGraph[mails, opts]
段落 auto-tag の topic をノード、同一段落共起=CoParagraph、quote edge 越し=QuoteTransition、seed relation=SeedRelation の辺を張った SourceVaultTopicItemGraph を作る(§6.5)。
→ `<|Nodes(TopicItemRef/Label/SupportParagraphs), Edges(From/To/EdgeKind/Weight/EvidenceRefs), NodeCount, EdgeCount|>`
Options: "SurfaceIndex" -> (必須), "RelationGraph" -> None, "RefLabel" -> None, "QuoteEdges" -> None, "SessionRefs" -> None

## 高レベル状態管理(OOPSEnsureLoaded 系)

### SourceVaultOOPSEnsureLoaded[opts]
OOPS メール構造化・検索の単一初期化(冪等)。seed 辞書/surface index/relation graph/quote table を読み、指定メールファイルを parse し、quote edge と session を構築してメモリ状態 `$svOOPSState` に載せる。`SourceVaultMailEnsureLoaded` 相当。
→ SourceVaultOOPSStatus[]
Options: "MailFiles" -> All(`{files}` や `"oops 9805.txt"` も可), "TableDir" -> Automatic($dropbox 由来), "MailDir" -> Automatic($dropbox 由来), "Force" -> False

### SourceVaultOOPSStatus[] → Association
`$svOOPSState` の要約を返す。`<|Loaded, MailCount, SessionCount, TopicCount, Files, SessionIndexBuilt|>`

### SourceVaultOOPSSessions[opts] → Dataset
読み込んだ session を MailCount 降順の Dataset で返す。
Options: "Limit" -> 30, "MinMails" -> 1

### SourceVaultOOPSSearchThreads[query, opts] → Dataset
スレッド(session)を検索し Dataset(Session/Subject/Kind/Mails/Score/Snippet) を返す。初回は session 検索 index を lazy build。ClaudeEval からの「○○のスレッドを探して」等に対応。
Options: "Limit" -> 10, "CloudSafe" -> False(True で §6.5.3 私的リスト(oops-ura/Under Ground)スレッドを DenyTags で gate=cloud 到達 client 向け)

### SourceVaultOOPSThread[sessionId, opts] → Association
1スレッドの情報を返す。`<|Session, Subject, SessionKind, MailCounters, Digest, TopicLabels, AllTopics, Released, QuoteEdges|>`。TopicLabels は◎Primary寄せ(精密。digest 話題行と一貫)、AllTopics は広い enrichment(俯瞰/recall)。
Options: "CloudSafe" -> False(True で私的リストスレッドは digest を出さず Released->False を返す)

## 可視化

### SourceVaultOOPSTopicGraphPlot[topicItemGraph, opts] → Graph
SourceVaultTopicItemGraph を Graph 描画する。edge を種別で色分け(CoParagraph=青/QuoteTransition=赤/SeedRelation=灰)、node サイズは支持段落数。
Options: "MaxNodes" -> 15

### SourceVaultOOPSThreadGraph[sessionId, opts] → Graph
そのスレッドの topic item graph を構築して `SourceVaultOOPSTopicGraphPlot` で描画する。

### SourceVaultOOPSThreadView[sessionId] → Column
1スレッドの Subject/種別/話題/決定的 digest を Column で表示する。

### SourceVaultOOPSThreadList[opts] → Grid
読み込んだスレッド一覧を Grid で表示する。Subject はボタンで、押すと `SourceVaultOOPSThreadView` を新規ノートブックで開く。
Options: "Limit" -> 30, "MinMails" -> 1

## Primer 連携

### SourceVaultBuildSessionPrimerItems[mails, sessions, opts]
session を SourceVaultPrimerIndex の item にする(§6.5「session summary を primer に」)。各 item: Title=Subject / Summary=`SourceVaultBuildSessionDigest` / Tags=topic ラベル∪list tags / Authors / Signals.EffectiveImportance(スレッド規模の決定的 proxy) / PrivacyLevel/Tags(§6.5.3) / Freshness。`SourceVaultBuildPrimerIndex` の `"Items"` に渡す。
→ List
Options: "SurfaceIndex" -> None, "RelationGraph" -> None, "RefLabel" -> None, "Freshness" -> "Fresh"