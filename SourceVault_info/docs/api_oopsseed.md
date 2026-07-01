# SourceVault_oopsseed API リファレンス

パッケージ: `SourceVault`
依存: `SourceVault_lexical`（`SourceVaultNormalizeSearchText` / surface index を使う）
ロード順: … → SourceVault_lexical.wl → SourceVault_searchindex.wl → **SourceVault_oopsseed.wl** → …
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_oopsseed.wl"]]`
担当: OOPS メーリングリスト（1992–2005 の個人 ML、約 6500 通・約 4100 topic item）の seed オントロジ取り込みと、一般メールへの topic 自動付与（auto-tag）。「seed を取り込み、一般メールを同形式に変換して検索精度を上げる」方針の基盤。

## 設計（レビューで確立）

- index は「S式風」でなく **Common Lisp S式**。正規表現/単純行分割では読まない（深い入れ子・長大行・引用文字列のため）。
- 名前空間は enum で決め打ちしない。実データに `ki/aga/e/mi/caitsith/tom/ara/anonymous` 等 10 種以上＋typo が存在する。`(SYMBOL INT)` を総称的に読み、未解決 owner は drop せず `Missing["UnknownOwner"]`。
- encoding は実測で確定: `item-name.index` は CR 区切りの **ShiftJIS(CP932)**（ESC=0 ゆえ ISO-2022-JP ではない）。mail 本文（`oops*.txt`）は再エンコード済みで **UTF-8**。2005 年の `mail-info.index` byte offset は現 UTF-8 ファイルでは無効ゆえ、本文は mbox 直接 parse で取る。
- owner-scoped: `ki`=owner(自分) namespace、`mi`/`aga` 等は別 owner。

## S式リーダ・legacy decode

### SourceVaultReadSExprString[s] → List
Common Lisp S式の文字列を読み top-level S式のリストを返す。`(...)`→List, `"..."`→String, 整数→Integer, bareword（`nil` 含む）→`SourceVault\`Private\`SVSym[name]`。

## seed オントロジ取り込み

### SourceVaultImportOOPSItemNames[path, opts] → Association
`item-name.index` を読み topic name records を返す。Options: `"Encoding" -> "ShiftJIS"`。
戻り値: `<|"Items" -> {<|"Namespace", "LocalId", "CanonicalLabel", "SurfaceForms"（"日本語 English"・"日本語(English)" 併記を別名分割）, "LanguageHints"|>...}, "Count", "Warnings", "SourcePath", "Encoding"|>`

### SourceVaultBuildSeedEntityDictionary[itemsOrImport, opts] → Association
item-name records から owner-scoped な seed entity dictionary（§4.1.1）を作る。
Options: `"OwnerMap" -> <|"ki" -> "sventity:owner:imai"|>`, `"SharedNamespaces" -> {"e"}`, `"DictionaryId" -> Automatic`
戻り値: `<|"ObjectClass" -> "SourceVaultSeedEntityDictionary", "DictionaryId", "Entries" -> {<|"TopicItemRef" -> "svtopic:oops:<ns>:<id>", "Namespace", "LocalId", "OwnerRef", "OwnerConfidence", "NamespaceKind" -> "Person"|"Shared"|"Unknown", "CanonicalLabel", "SurfaceForms", "LanguageHints", "PrivacyLevel", "SourceRefs"|>...}, "EntryCount"|>`
この `Entries` を `SourceVault_lexical` の `SourceVaultBuildSurfaceIndex` / `SourceVaultBuildLexicalStats["EntityDictionary"->…]` に渡すと entity OR-match が効く。

### SourceVaultImportOOPSSeedDictionary[itemNameIndexPath, opts] → Association
import + dictionary build を一括で行う便宜関数。戻り値: `<|"Dictionary", "Import"|>`。

### SourceVaultSeedDictionaryStats[dict] → Association
検証用統計（namespace 分布、owner 解決率、bilingual 数、surface form 総数、sample）。

### SourceVaultImportOOPSMailToItem[path] → Association
`mail-to-item.index` を読み `<|mailNumber -> {<|"Namespace", "LocalId", "Role"(title/body)|>...}|>` を返す。人手が付与した topic の **gold** データ（評価用）。

### SourceVaultImportOOPSMailInfo[path] → Association
`mail-info.index` を読み `<|mailNumber -> <|"List", "Hash", "Author", "SourceFile", "ByteStart", "ByteEnd"|>|>` を返す。`List`（`oops`/`oops-ura`）は privacy 入力。**注意**: ByteStart/ByteEnd は 2005 年原ファイル基準で現 UTF-8 ファイルでは無効。本文抽出は `SourceVaultParseOOPSMailFile` を使う。

## mail parse・auto-tag

### SourceVaultParseOOPSMailFile[path] → Association
UTF-8 の `oops*.txt` を mbox として parse（CR 行終端）。`X-Ml-Counter` で gold と join する。`Subject` / `From` は **RFC 2047 MIME encoded-word（`=?charset?B/Q?text?=`）を復号**する（`iSVDecodeMimeWords`）。ISO-2022-JP は WL 非対応のため JIS X 0208 バイトを +0x80 して EUC-JP 経由で復号（例 `=?ISO-2022-JP?B?GyRCRT42UBsoSg==?=` → 「転勤」）。Shift_JIS / UTF-8 / EUC-JP も対応。
戻り値: `<|"Mails" -> {<|"Counter", "MlName", "Subject", "From", "Date", "Body"|>...}, "MailCount", "SourcePath"|>`

### SourceVaultStripOOPSMarkers[text] → String
OOPS の topic ID ref（`[ns n]`）・brace wrapper・`◎○・` structural marker を除去して plain text を返す。label 本文は残す（held-out 評価で cheat 防止／一般メール化）。

### SourceVaultParseMailParagraphs[body] → {Association...}
**RAW body**（明示マーカー保持）を段落に分割する（空行区切り、引用/署名/footer を分離。§6.5）。各段落は `RawText`（生・`◎○・{}[ns id]` マーカー保持）と `Text`（`SourceVaultStripOOPSMarkers` 済）を持つ。
戻り値: `{<|"Index", "Kind" -> "Prose"|"Quote"|"Signature"|"Footer", "RawText", "Text"|>...}`
（従来どおり strip 済 body を渡しても動くが、その場合 RawText にマーカーが無く明示 topic は拾えない。）

### SourceVaultExtractExplicitTopics[text] → {Association...}
OOPS の**明示 topic マーカー**を抽出する（§6.5 点 1「明示 topic があれば採用」）。`◎` = Primary / `○` = Secondary / `・` = Mentioned の `<label>[ns id]` と、本文の `{label[ns id]}`。`[ns id]` が topic ref を直接与える**人手付与の最高品質シグナル**（surface form 照合より上）。
戻り値: `{<|"TopicItemRef", "CanonicalLabel", "TopicRole" -> "Primary"|"Secondary"|"Mentioned", "AssignmentKind" -> "ExplicitOOPS", "Confidence" -> 1.0|>...}`

### SourceVaultAssignParagraphTopics[paragraphs, surfaceIndex, opts] → {Association...}
各 prose 段落に topic item を自動付与する（auto-tag）。`surfaceIndex` は `SourceVaultBuildSurfaceIndex[dict]`。
`"ExplicitTopics" -> True`（既定）で、段落の `RawText` から `SourceVaultExtractExplicitTopics` を走らせ `AssignmentKind = "ExplicitOOPS"`（`TopicRole` 付き, conf 1.0）を**最優先**で付与する（seed からは重複除外）。relation 拡張は 明示 ∪ seed から行う。
`"RelationGraph"`（`SourceVaultBuildOOPSRelationGraph` の結果）を渡すと、SeedMatched の named topic から 1-hop の関連 topic を低 confidence の `AssignmentKind = "RelationExpanded"`（`ViaSeed` / `RelationWeight` 付き）として追加する。SeedMatched（conf ≤ 1.0）が常に RelationExpanded（conf = `Min[0.45, 0.2 + 0.03·Weight]`）より上位。`RelationGraph` 無しなら SeedMatched のみ（後方互換）。
`"ExtractCandidates" -> True` で seed 非該当の新トピック候補（`SourceVaultExtractCandidateTopics`）を `AssignmentKind = "AutoExtracted"`（`TopicItemRef -> Missing["Unconfirmed"]`, `ProposedLabel`, `Status -> "Candidate"`, conf 0.2）として追加する（auto-confirm off、owner 確認で正規 topic 化）。
`"RefLabel"`（ref→canonical label の Association）を渡すと、**同一 canonical label の SeedMatched 重複**（別 owner namespace / 重複 entry。例 ki195/e203 とも「映画」）を最高 confidence の 1 件に collapse し、他の ref を `AltRefs` に provenance として残す（軽量 owner disambiguation。曖昧は実データで 2.2% と稀）。
Options: `"MinSurfaceLength" -> 2`, `"TopicLimit" -> 10`, `"ProseOnly" -> True`, `"RelationGraph" -> None`, `"MaxRelationTopics" -> 8`, `"MinRelationWeight" -> 2`, `"ExtractCandidates" -> False`, `"CandidateLimit" -> 8`, `"RefLabel" -> None`
戻り値: `{<|"ParagraphIndex", "Kind", "Assignments" -> {<|"TopicItemRef", "MatchedSurfaceForms", "AssignmentKind" -> "SeedMatched"|"RelationExpanded"|"AutoExtracted", "Confidence", ("ViaSeed", "RelationWeight", "ProposedLabel", "ExtractionKind", "Status")|>...}|>...}`
ノイズ対策（解消済み）: 短い Latin surface form の語中誤一致（例「tar」が「s**tar**ship」）は `iSVSurfaceFormPresentQ` の単語境界一致で解消（api_lexical 参照）。catch-all/退化 topic（ラベル「・」で数百 form を持つ `anonymous:0` 等）も `SourceVaultBuildSurfaceIndex` 構築時に除外済み。残: 同名 topic（例 ki195/e203 とも「映画」）は両方とも正当な topic ゆえ両マッチを許容（owner による後段 disambiguate は将来課題）。

## relation（重み付き有向）取り込み・1-hop 拡張

`item-relation.index` は topic 間の **重み付き有向リンク**（`(ns localId)` → `(((ns localId) weight)...)`）。これを取り込むと「named topic に関連するが本文に名前が出ていない topic」を回収できる（KG 局所探索 §6.3、auto-tag の RelationExpanded）。

### SourceVaultImportOOPSItemRelations[path, opts] → Association
`item-relation.index` / `item-relation-up.index` を S式 parse する。Options: `"Direction" -> "Down"`（`item-relation-up.index` には `"Up"` を渡す）。
戻り値: `<|"Relations" -> <|"<TopicItemRef>" -> {<|"To" -> "<TopicItemRef>", "Weight", "Direction"|>...}|>, "Count", "SourcePath", "Direction"|>`

### SourceVaultBuildOOPSRelationGraph[tableDir] → Association
`tableDir` の `item-relation.index`（Down）＋`item-relation-up.index`（Up）を結合した relation graph を作る。
戻り値: `<|"RelationGraph" -> <|"<TopicItemRef>" -> {neighbor...}|>, "Count", "TableDir"|>`（OOPS 実データで約 2875 ノード）。

### SourceVaultExpandTopicsByRelation[refs, relationGraph, opts] → {Association...}
seed topic 集合（`refs`）を重み付き 1-hop 近傍へ拡張する。seed 自身は除外、`To` 単位で最大重みに dedup、重み降順。auto-tag の RelationExpanded に使う 1-hop 版。
Options: `"MaxNeighborsPerSeed" -> 5`, `"MinWeight" -> 1`, `"MaxTotal" -> 20`
戻り値: `{<|"To", "Weight", "Direction", "ViaSeed"|>...}`

### SourceVaultExpandSearchGraph[seeds, opts] → Association（§6.3 KG local expansion）
seed topic refs を weighted topic relation で **multi-hop BFS 展開**する検索用の KG 局所探索（spec §6.3 public API）。`SourceVaultExpandTopicsByRelation` が auto-tag 用 1-hop なのに対し、本関数は multi-hop で edges / trace を返す。cycle 安全（visited set）。
Options: `"RelationGraph" -> None`（必須相当）, `"MaxHops" -> 2`, `"MaxNodes" -> 50`（総数）, `"MaxNeighborsPerNode" -> 10`（per-node top-k by weight、hub 爆発抑制 §6.5.4）, `"MinEdgeWeight" -> 1`, `"RefLabel" -> None`, `"EdgeKinds" -> {"TopicRelation"}`（SharedTag/SharedAuthor/Interaction は object infra 整備後）, `"ReleaseContext" -> None`（trace 記録。topic node は metadata で、release gate/revocation は対応 content chunk の検索時に適用）
戻り値: `<|"Seeds", "Expanded" -> {<|"Ref", "Label", "Hop", "Weight", "ViaSeed"|>...}, "Edges" -> {<|"From", "To", "Weight", "Kind", "Direction"|>...}, "Trace", "NodeCount", "EdgeCount", "Capped"|>`

## AutoExtracted（seed 非該当の新トピック候補）

seed（1992–2005 語彙）に無い語（post-2005 や新しい固有名詞）に対し、本文から salient な候補を抽出して新トピックの種にする。auto-confirm は既定 off で、候補は owner 確認を経て正規 topic 化する想定。

### SourceVaultExtractCandidateTopics[text, opts] → {Association...}
本文から新トピック候補を抽出する。katakana 連続（≥3）/漢字熟語（2–6）/Latin トークン（≥2）/「」『』 内の短語（≤8、句読点・空白・改行を含まない）を拾い、seed 既知語（`"KnownSurfaceIndex"` の正規化 surface に一致）・stopword（汎用 En/Ja 語＋OOPS namespace 残骸）・退化語を除外、正規化 surface で group して出現数→長さ順に返す。
Options: `"KnownSurfaceIndex" -> None`, `"Limit" -> 15`, `"MinKatakana" -> 3`, `"MinKanji" -> 2`, `"MaxKanji" -> 6`, `"MinLatin" -> 2`
戻り値: `{<|"Surface", "ExtractionKind" -> "Katakana"|"Kanji"|"Latin"|"Quoted", "Count"|>...}`
既知の限界: 辞書なし抽出ゆえ漢字連続が併合しうる（例「結局億単位」=結局+億単位）。正攻法は形態素分割（hybrid 実測後に保留）。候補は確認ゲート前提のため許容。

### SourceVaultConfirmCandidateTopics[candidates, opts] → Association
owner が確認した AutoExtracted 候補を seed と同形の新 topic entry にする（candidate → 確認済 topic → 検索可能の loop を閉じる）。`candidates` は `{<|"Surface","ExtractionKind"|>...}` か label 文字列のリスト。auto-confirm は行わない。
Options: `"ExistingDictionary" -> None`（渡すと Entries を merge した `MergedDictionary` を返す → `SourceVaultBuildSurfaceIndex` で再 index すると確認 topic が SeedMatched で引けるようになる）, `"RefPrefix" -> "svtopic:extracted"`, `"StartId" -> 1`, `"OwnerRef" -> None`, `"PrivacyLevel" -> 0.3`
戻り値: `<|"ConfirmedEntries" -> {<|"TopicItemRef", "CanonicalLabel", "SurfaceForms", "NamespaceKind" -> "Extracted", "OwnerRef", "PrivacyLevel", "Provenance"|>...}, "Count", ("MergedDictionary")|>`。

### SourceVaultSaveExtractedTopics[entries, path] / SourceVaultLoadExtractedTopics[path]
確認済 extracted topic entry を WXF で永続化・読み戻す（owner store）。読み戻した entry を `dict["Entries"]` に `Join` すれば seed に編入でき、次回以降 SeedMatched で引ける。`Save` は `<|"Status","Path","Count"|>`、`Load` は entry リストを返す。

## mail → 検索 chunk ビルダ

### SourceVaultBuildMailChunks[mail, surfaceIndex, opts] → {Association...}
parse 済 mail（`SourceVaultParseOOPSMailFile` の 1 要素）を §7.2 検索 chunk のリストにする。各 chunk は `SearchFields`（title/body/author/**topics**）＋`Text`/`NormalizedText`＋`PrivacyLevel`/`State`/`Tags`＋`TopicRefs`/`RelatedRefs`＋`SourceRef`。`topics` は `SourceVaultTopicEnrichment` が auto-tag で注入する。これを `SourceVaultBuildProjectionIndex` の `"Chunks"` に渡せば seed→検索の pipeline が完成。
Options: `"Granularity" -> "Paragraph"`（既定。各 prose 段落を 1 chunk＝段落単位 topic で precision 高い）` | "Mail"`（mail 全体で 1 chunk）, `"RelationGraph"`, `"RefLabel"`, `"PrivacyLevel" -> 0.5`, `"ReleaseState" -> "Published"`, `"IncludeRelated" -> True`, `"ObjectIdPrefix" -> "svobj:oops"`

## seed → 検索の接続（topic enrichment）

auto-tag した topic を検索 index に注入し、「本文に literal で出ない正準/関連トピック」でも文書がヒットするようにする。これがプロジェクトの主張（一般メールを seed 形式に変換して検索精度を上げる）の実体。

### SourceVaultTopicEnrichment[text, surfaceIndex, opts] → Association
`text` に auto-tag（`SourceVaultAssignParagraphTopics`、`ProseOnly -> False`）を走らせ、検索 index へ注入する topic 情報を返す。`"RefLabel"`（ref→canonical label の Association）で label を解決、`"RelationGraph"` を渡すと RelationExpanded の関連トピックも含める。
Options: `"RefLabel" -> None`, `"RelationGraph" -> None`, `"IncludeRelated" -> True`, `"MaxRelationTopics" -> 6`, `"MinRelationWeight" -> 2`
戻り値: `<|"TopicRefs", "TopicLabels"（SeedMatched 正準）, "RelatedRefs", "RelatedLabels"（RelationExpanded）, "TopicsFieldText"|>`
使い方: chunk の `SearchFields["topics"]` に `TopicsFieldText` を載せて `SourceVaultBuildProjectionIndex` で build する（`iSVChunkText` が `topics` を検索対象に含む）。実証: mail の本文に無い関連トピック（例「Independence Day」）で、enrichment 有りの index だけがその mail を検索できる。

## メール構造化（quote / session, §6.5）

メールを「段落 topic ＋ 引用関係 ＋ スレッド」に構造化する。OOPS はスレッドヘッダ（In-Reply-To / References）を持たず Message-Id のみなので、seed の `quote-table.index` を authoritative な引用グラフとする。

> **注意（S 式パース速度）**: `quote-table.index`（約 477KB、整数 ~20 万）などの大きな index は、S 式リーダの `iSVClassifyAtom` が整数を `FromDigits` で（旧 `ToExpression` は 1 整数 ms 級で数分かかり共有カーネルが wedge する）、`iSVReadAtom`/`iSVReadString` が `StringJoin[cs[[...]]]` で（旧 `StringTake[s,{...}]` は O(位置) で O(n²)）読むよう修正済み。477KB でも約 6 秒。

### SourceVaultImportOOPSQuoteTable[path] → Association
`quote-table.index` を読み `<|mailNumber -> {<|"Index", "FromMail", "StandardQuoteId"|>...}|>` を返す。各メールが引用している元メール（`FromMail`）と seed の standard-quote id。`<mail#> ((idx (from src) (standard-quote qid))...)` の交互ペア（`nil` は空）。

### SourceVaultExtractMailQuoteMarkers[mail] → {Association...}
本文の `-*- Quote (from N) -*-` マーカーを抽出する。`N` が整数なら `QuoteKind -> "ExplicitMarker"`（`FromMail`）、URL なら `"ExternalURL"`（`FromRef`）。

### SourceVaultBuildMailQuoteEdges[mails, opts] → {Association...}
`SourceVaultMailQuoteEdge` のリストを作る。`"QuoteTable"`（`SourceVaultImportOOPSQuoteTable[...]["Quotes"]`）を渡すと seed から `SeedStandardQuote`（Confidence 1.0, authoritative）edge を、本文マーカーから `ExternalURL`（URL）と seed 未収録の `ExplicitMarker` edge を作る。各 edge: `<|"ObjectClass" -> "SourceVaultMailQuoteEdge", "QuoteEdgeId", "SeedQuoteId", "FromMailRef", "ToMailRef", "QuoteKind", "Confidence", "SourceMarker"|>`。

### SourceVaultBuildMailSessions[mails, quoteEdges, opts] → {SourceVaultMailSession...}
quote edge の連結成分と Subject の `Re:`/`Fwd:` 正規化（`iSVNormalizeSubject`）による同一 subject 連結を `ConnectedComponents` でまとめ、メールをセッション（スレッド）にする。
Options: `"SubjectThreading" -> True`
戻り値: `<|"ObjectClass" -> "SourceVaultMailSession", "MailSessionId", "MailCounters", "MailRefs", "MailCount", "SessionKind" -> "QuoteCluster"|"ReplyThread"|"Singleton", "Subject", "StartMailCounter", "EndMailCounter"|>`。quote 連結が有れば `QuoteCluster`、Subject のみなら `ReplyThread`。

### SourceVaultBuildTopicItemGraph[mails, opts] → Association（§6.5 topic item graph）
段落 topic・引用・seed 関係を 1 つのグラフに束ねる。各メール各 prose 段落を auto-tag（SeedMatched）してノード（topic item）を作り、辺を張る:
- **CoParagraph**: 同じ段落に共起した topic ペア（`Weight` = 共起段落数）。
- **QuoteTransition**: quote edge の引用元メール topic × 引用先メール topic（`QuoteEdges` 経由）。
- **SeedRelation**: グラフ内 node 間に seed relation graph の辺があるもの。
必須 Options: `"SurfaceIndex"`。任意: `"RelationGraph"`（SeedRelation 用）, `"RefLabel"`, `"QuoteEdges"`（`SourceVaultBuildMailQuoteEdges` の結果。QuoteTransition 用）, `"SessionRefs"`, `"MaxTopicsPerMailForQuote" -> 4`（QuoteTransition の all-pairs 爆発を防ぐため、各メールの支持段落数 top-N トピックだけを引用遷移に使う）。
戻り値: `<|"ObjectClass" -> "SourceVaultTopicItemGraph", "GraphId", "Nodes" -> {<|"TopicItemRef", "Label", "SupportParagraphs"|>...}, "Edges" -> {<|"From", "To", "EdgeKind", "Weight", "EvidenceRefs"|>...}, "NodeCount", "EdgeCount", "EdgeKindTally"|>`
> QuoteTransition は引用元×引用先 topic の all-pairs なので、quote が多いスレッドでは辺が増える（将来 top-k / Primary 限定で剪定予定）。

### SourceVaultBuildSessionChunks[mails, sessions, opts] → {Association...}
session（スレッド）単位の §7.2 検索 chunk を作る。各 chunk は session の全メール本文を連結し、`SearchFields`（title=Subject / body=連結本文 / author=著者 union / topics=`SourceVaultTopicEnrichment` 注入）を持つ。`SourceVaultBuildProjectionIndex` に渡すと **query がスレッド全体を引ける**（§6.5「日程・事項の結論」query 向け）。
`PrivacyLevel` / `Tags` は §6.5.3 の list（`iSVOOPSListPrivacy`）由来を session 内で **max / union** で採る（1 通でも私的リストなら session 全体が私的）。
Options: `"SurfaceIndex"`, `"RelationGraph"`, `"RefLabel"`, `"PrivacyLevel" -> Automatic`（list 由来）, `"ReleaseState" -> "Published"`, `"MaxBodyChars" -> 4000`

> **§6.5.3 privacy / trust class**: `X-Ml-Name` の実値は `"OOPS Mailing List"`（公開）と `"OOPS Mailing List Under Ground"`（= oops-ura, 私的）。`iSVOOPSListPrivacy` は "under ground" / "oops-ura" を検出した list を私的とし、`PrivacyLevel 0.6` ＋ `{"PrivateML", "NoCloudLLM", "NoPublicExport"}` を付ける。cloud LLM / public export の release context は `DenyTags` にこれらを持つので、私的リスト由来のスレッドは自動的に除外される。

### SourceVaultBuildSessionDigest[session, mails, opts] → String
LLM を使わない**決定的なスレッド要約**を返す。`[スレッド] <Subject> (<N>通/<SessionKind>)` ＋ `話題: <topic ラベル>` ＋ 各メールの `#<counter> <著者>: <先頭 prose 段落>` のタイムライン。
Options: `"SurfaceIndex"`（話題抽出用）, `"RefLabel"`, `"MaxMails" -> 8`, `"ParaChars" -> 120`

### SourceVaultBuildSessionPrimerItems[mails, sessions, opts] → {Association...}
session を `SourceVaultPrimerIndex` の item にする（§6.5「session summary を primer に」）。各 item は `Title` = Subject、`Summary` = `SourceVaultBuildSessionDigest`、`Tags` = topic ラベル ∪ list tags（§6.5.3）、`Authors`、`Signals -> <|"EffectiveImportance" -> _|>`（`Min[0.9, 0.3 + 0.06·MailCount]` = スレッド規模の決定的 proxy）、`PrivacyLevel` / `Freshness`。これを `SourceVaultBuildPrimerIndex` の `"Items"` に渡すと、`SourceVaultPrimerSearch` が**スレッドを digest 付きで**引ける（大きいスレッドほど importance で上位）。「日程・事項の結論探し」query 向け。
Options: `"SurfaceIndex"`, `"RelationGraph"`, `"RefLabel"`, `"Freshness" -> "Fresh"`

## OOPS メール utility 層（単一 init ＋操作）

`SourceVaultMailEnsureLoaded`（ライブ IMAP mail store）に相当する、OOPS コーパス用のワンショット初期化と操作関数。状態は `SourceVault\`$svOOPSState` にキャッシュされる。ClaudeEval からの各種操作（「○○のスレッドを探して」等）の土台。

### SourceVaultOOPSEnsureLoaded[opts] → Association
OOPS メール構造化・検索を 1 発で初期化する（冪等）。seed 辞書 / surface index / relation graph / quote table を読み、指定メールファイルを parse し、quote edge と session を構築して `$svOOPSState` に載せる。
Options: `"MailFiles" -> All`（`All` / `{"oops 9805.txt", …}` / 単一文字列）, `"TableDir"` / `"MailDir" -> Automatic`（`Global\`$dropbox` の OOPS archive から導出）, `"Force" -> False`。戻り値は `SourceVaultOOPSStatus[]`。

### SourceVaultOOPSStatus[] → Association
`<|"Loaded", "MailCount", "SessionCount", "TopicCount", "Files", "SessionIndexBuilt"|>`。

### SourceVaultOOPSSessions[opts] → Dataset
読み込んだ session を `<|"Session", "Subject", "Kind", "Mails"|>` の Dataset（MailCount 降順）で返す。Options: `"Limit" -> 30`, `"MinMails" -> 1`。

### SourceVaultOOPSSearchThreads[query, opts] → Dataset
スレッド（session）を検索して `<|"Session", "Subject", "Score", "Snippet"|>` の Dataset を返す。初回は session 検索 index を内部 release context `oops-corpus` に lazy build する。Options: `"Limit" -> 10`。

### SourceVaultOOPSThread[sessionId] → Association
1 スレッドの詳細 `<|"Session", "Subject", "SessionKind", "MailCounters", "Digest"（決定的要約）, "TopicLabels", "QuoteEdges"|>`。

```mathematica
SourceVaultOOPSEnsureLoaded["MailFiles" -> "oops 9805.txt"]   (* 単一 init *)
SourceVaultOOPSSearchThreads["FireWire"]                       (* スレッド検索 *)
SourceVaultOOPSThread["svmailsession:4431-4449"]["Digest"]     (* スレッド要約 *)
```

## 可視化（ノートブック表示）

utility 層の上に載る、ノートブック向けの表示関数。

### SourceVaultOOPSTopicGraphPlot[topicItemGraph, opts] → Graph
`SourceVaultBuildTopicItemGraph` の結果を `Graph` として描画する。edge を種別で色分け（**CoParagraph=青 / QuoteTransition=赤 / SeedRelation=灰**）、node サイズは支持段落数、支持数 top-N node（`"MaxNodes" -> 15`）に絞る。

### SourceVaultOOPSThreadGraph[sessionId, opts] → Graph
そのスレッドの topic item graph を構築して `SourceVaultOOPSTopicGraphPlot` で描画する（FireWire 等の中心トピックが大きく出る）。

### SourceVaultOOPSThreadView[sessionId] → Column
1 スレッドの Subject / 種別 / 通数 / 話題 / 決定的 digest を `Column` + `Framed` で表示する。

### SourceVaultOOPSThreadList[opts] → Grid
読み込んだスレッド一覧を `Grid` で表示する。`Subject` はボタンで、押すと `SourceVaultOOPSThreadView` を新規ノートブックで開く。Options: `"Limit" -> 30`, `"MinMails" -> 1`。

## 利用例

```mathematica
(* seed 辞書を build → surface index → BM25 index に entity stream を載せる *)
dict = SourceVaultImportOOPSSeedDictionary["…/db/table/item-name.index"]["Dictionary"];
sidx = SourceVaultBuildSurfaceIndex[dict];

(* relation graph を build *)
graph = SourceVaultBuildOOPSRelationGraph["…/db/table"]["RelationGraph"];

(* 一般メールを段落 topic 付与（named ＋ relation 1-hop の related） *)
mails = SourceVaultParseOOPSMailFile["…/oops-ml-generate/oops 200506.txt"]["Mails"];
paras = SourceVaultParseMailParagraphs[SourceVaultStripOOPSMarkers[First[mails]["Body"]]];
SourceVaultAssignParagraphTopics[paras, sidx, "RelationGraph" -> graph]
```
