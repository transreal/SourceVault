# SourceVault_mailstructure API リファレンス

パッケージ: `SourceVault`
依存: `SourceVault_oopsseed`（段落分割/候補抽出/session/graph の primitive）, `SourceVault_lexical`（`SourceVaultNormalizeSearchText` / `SourceVaultBuildSurfaceIndex`）, `SourceVault_searchindex`（release policy）, `SourceVault_maildb`（adapter, Inc2+）
ロード順: … → SourceVault_lexical.wl → SourceVault_searchindex.wl → SourceVault_oopsseed.wl → **SourceVault_mailstructure.wl** → …
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_mailstructure.wl"]]`
担当: OOPS 以外の**一般メール（`SourceVault_maildb` の univ 等）**を、返信 session / 段落 topic item / topic item graph に構造化する（§6.5 の seed-optional 拡張）。中核は `TopicVocabulary` 抽象で OOPS seed の有無を吸収する。
仕様: `SourceVault_info/design/sourcevault_general_mail_structuring_spec_v0_1.md`（r3）

## 設計（レビュー r1–r3 で確立）

- **seed-optional**: OOPS トピックアイテムが無くても構築でき、あれば既存 topic item を再利用・無ければ新規作成して拡張する。
- **privacy 継承**: auto topic label は本文由来の派生データ。`PrivacyScope`（release context）ごとに語彙を構築し、public/cloud scope の語彙に private support の label を入れない。表示/検索も request-time gate を通す。
- **冪等**: auto topic ref も relation edge も deterministic id（label hash / EvidenceKey から）。再構築で重複しない。
- **引用検出は corpus 全体の mail relation graph mining**: session は線形リストでなく typed directed multi-edge graph（`SourceVaultMailRelationGraph`）の projection。`RelationRole` で「議論の継続」と「過去メールの参照」を分け、historical reference を現 session に過剰 merge しない。

## Inc 1: TopicVocabulary（seed-optional 語彙）

vocab = `<|"ObjectClass", "VocabularyBuildId", "ProfileDigest", "PrivacyScope", "Dictionary"(Entries), "SurfaceIndex", "SeedRelationGraph", "ObservedRelationGraph", "RefLabel", "Provenance", "GrowReport"|>`。`Dictionary` は OOPS dict と同型ゆえ既存 `SurfaceIndex`/`AssignParagraphTopics` がそのまま食える。

### SourceVaultNewTopicVocabulary[opts] → vocab
空の TopicVocabulary（seed 無しブートストラップ用）。Options: `"OwnerRef"`, `"PrivacyScope"`。

### SourceVaultTopicVocabularyFromSeed[dict, opts] → vocab
OOPS seed dict（or 任意の owner-scoped 辞書）から語彙を作る（既存 topic item を再利用）。Options: `"SeedRelationGraph"`, `"SeedSource"`, `"PrivacyScope"`。

### SourceVaultGrowTopicVocabulary[vocab, mails, opts] → vocab'（純関数）
メールコーパスから語彙を成長させる（seed-optional の核、**r3 pass A = mail-level**）。各メールを prose 段落に絞り（block filter で Quote/Signature/Footer 除外）候補トピックを抽出、複合 support の salience gate（既定 `DistinctMails >= DistinctMailMin`）を満たす繰り返し語だけを deterministic ref（`svtopic:auto:<owner>:<normLabelHash>`）の AutoExtracted topic item 化して追加する。現 `PrivacyScope` の MaxPrivacyLevel/DenyTags を越える候補は除外。各 entry は `SupportRefs`/`SupportPrivacyMax`/`SupportTags`/`SupportGroupingKind`/`VisibilityPolicy` を持つ。`vocab["GrowReport"]` に採用/却下候補・grouping 分布。
Options: `"PrivacyScope"`, `"GroupingKind"`(`Mail`|`PreliminaryThread`|`Session`, 既定 Mail), `"Sessions"`(mailRef→sessionId。pass B で DistinctSessions salience), `"DistinctMailMin"`(2)/`"DistinctThreadMin"`(2)/`"DistinctSessionMin"`(2), `"MinSupport"`(閾値一括上書き), `"MaxNewTopics"`(200), `"OwnerRef"`, `"Rounds"`(1), `"PerMailLimit"`(40), `"CandidateBlockFilters"`(既定 {Quote,Signature,Footer})。

## Inc 2: maildb アダプタ（canonical gate source + fail-safe）

### SourceVaultMailStructEnsureReleaseContexts[]
一般メール構造化用 release context を冪等登録。`mailstruct-local`（MaxPL 1.0・DenyTags {}）/ `mailstruct-cloud`（MaxPL 1.0・DenyTags {NoCloudLLM, NoPublicExport, PrivateML, ThirdPartyContent}）。

### SourceVaultMailSnapshotReleaseSource[snap] → source
maildb snapshot を `SourceVaultEvaluateReleasePolicy` 用の canonical source `<|"PrivacyLevel", "Tags", "State"|>` に射影。`PrivacyLevel` は `Derived.PrivacyLevel` が numeric ならそれ、**欠落/未生成は 1.0（fail-safe）**。`Tags` は `Derived.AccessTags`/`DenyTags` ∪ `SourceVaultMailRecipientPrivacy`（To/Cc）の tag。`State` は "Published"。

### SourceVaultMailToGenericRecord[snap, opts] → §3.1 record | Missing["Gated"]
release gate（Options `"ReleaseContext"`, 既定 `"mailstruct-local"`）で **Permit のみ**。Deny は `Missing["Gated"]`。**Permit 後にのみ復号**し、失敗は `"Body" -> Missing["BodyDecryptFailed"]`（低漏洩 metadata は残す）。
戻り値 record: `<|"MailRef"(sv://mail/<RecordId>, 冪等主キー), "RecordId", "Subject", "From", "To", "Cc", "Date", "Body", "BodyWasHTML", "ThreadHeaders"(<|MessageIDToken, InReplyToToken, ReferencesTokens|>), "ReplyToAddr"(participant signal 専用), "PrivacyLevel", "Tags", "LegacyCounterAlias"(内部専用), "SourceRef"|>`。
**注意**: 現行 maildb snapshot は `MailSource.MessageIDToken` のみ保持し `InReplyToToken`/`ReferencesTokens` は非保持 → header pass は degraded（下記）。

### SourceVaultMailRecordsForStructuring[opts] → {record...}
ロード済み snapshot（既定 `SourceVaultMailSnapshotList[]`）を generic record 列に変換（Gated は除外、復号失敗は低漏洩 metadata で残す）。Options: `"Snapshots"`(明示指定), `"MBox"`, `"DateFrom"`/`"DateTo"`(ISO), `"ReleaseContext"`, `"Limit"`。

### SourceVaultMailStructHeaderAvailability[snaps, opts] → Association
ThreadHeaders token（MessageID/InReplyTo/References）の保持率を報告し、InReplyTo 保持率が閾値未満なら `"HeaderPassMode" -> "Degraded"`（§6b）。token は String または ByteArray を present と判定。Options: `"Threshold"`(0.5)。

## Inc 3: Mail relation graph mining（引用/参照検出, §6）

### SourceVaultBuildQuoteFingerprintIndex[records, opts] → index
各メールを span（`SourceProse`/`QuoteQuery`/`ForwardedBlock`）に分け、**PrivacyScope ごとの scope-salted keyed hash**（line hash + shingle: word bigram ∪ char 4-gram で CJK 対応）を作る（§6e）。raw quote text は保存しない。**common line/shingle の DF フィルタ**（多数メールに出る hash＝挨拶/定型句を候補生成から除外）。
戻り値: `<|"Scope", "ProfileDigest", "BuildId", "CommonHashCount", "CommonDocFreqThreshold", "Spans", "SpanByRef", "LineHashIndex", "ShingleIndex"|>`。Options: `"PrivacyScope"`, `"MinLineChars"`(6), `"MinQuoteChars"`(12), `"CommonDocFreqFraction"`(0.3), `"CommonDocFreqMinCount"`(8)。

### SourceVaultBuildMailRelationGraph[records, opts] → SourceVaultMailRelationGraph
header/quote/subject/participant edge を **typed directed multi-edge** に統合。**edge 方向は citing(From)→cited(To)**。`EdgeId = Hash[ProfileDigest, From, To, EdgeKind, EvidenceKey]`（冪等）。`RelationRole`（ThreadContinuation/EvidenceCitation/TemplateReuse/AnnualEventReuse/ForwardedContext/UnknownReference）は §6c の v0.1 決定論ルール（+`RoleConfidence`/`RoleSource`）。候補生成は line/shingle 索引を共有 hash 数で prefilter（budget）。同一 (From,To,EdgeKind) の並行 edge は最良 confidence を代表に集約（`SpanPairCount` 記録）。
Options: `"QuotePass"`(`LocalOnly`|`IndexBuildOnly`|`Full`, 既定 LocalOnly。LocalOnly は GlobalQuoteIndex pass の edge を落とす), `"QuoteIndex"`(既存 index 再利用), `"MaxContinuationGapDays"`(30), `"MaxGlobalCandidatesPerQuote"`(20), `"MaxQuoteBlocksPerMail"`(40), `"MaxAmbiguityForMerge"`(2), `"MinLineJaccardExact"`(0.6), `"MinShingleJaccardFuzzy"`(0.3), `"LocalWindowDays"`(14), `"PrivacyScope"`, `"ProfileDigest"`。
edge = `<|"EdgeId", "FromMailRef", "ToMailRef", "EdgeKind", "EvidenceKey", "RelationRole", "RoleConfidence", "RoleSource", "Confidence", "TemporalDistanceDays", "CandidateGenerationPass"(Local|GlobalQuoteIndex|Header), "AmbiguityCount", "SourceSpanRole", "QuoteLineage"(Direct|ReQuote), "FeatureScores", "MatchedSpanRefs", "SpanPairCount", "PrivacyLevel", "Tags"|>`。

### SourceVaultMineMailSessions[graph, opts] → {session...}
relation graph を session に projection（§6d）。**ThreadContinuation の強 edge（ReplyHeader/ReferenceHeader/direct QuoteExact/strict SubjectFallback, 低 ambiguity・高 confidence）だけで merge**（`ConnectedComponents`）し、`EvidenceCitation`/`AnnualEventReuse`/`TemplateReuse`/`ForwardedContext` は merge せず `CrossSessionReferences` に残す。
戻り値: `{<|"MailSessionId", "MailRefs", "MailCount", "SessionGraphRef", "CrossSessionReferences"(<|EdgeId, From, To, Role, ToSession|>...)|>...}`。Options: `"MaxAmbiguityForMerge"`(2), `"MergeConfidenceMin"`(0.5)。

## Inc 4: 段落 topic 付与 + topic graph + 統合 (§7-§9)

### SourceVaultStructureMail[mails, opts] → 統合結果
一般メール構造化の統合パイプライン (§2): **pass A 語彙(mail-level) → relation graph + sessions → pass B(session-aware 語彙 refine) → 段落 topic 付与 → topic graph**。pass A は session 不要・pass B は Inc3 の session を使う 2-pass で、語彙↔session の循環依存を断つ (§4.3)。
戻り値: `<|"Vocabulary"(ObservedRelationGraph 込み), "RelationGraph", "Sessions", "TopicGraph", "ParagraphTopics", "Records", "Report"|>`。Options: `"Seed"`(dict|None), `"Grow"`(True), `"PassB"`(True), `"QuotePass"`(Full), `"PrivacyScope"`, `"OwnerRef"`, `"MaxTopicsPerMail"`(8)。

### SourceVaultBuildMailTopicGraph[relationGraph, topicsByMail, vocab, opts] → ObservedRelationGraph
relation graph 駆動で auto topic 間の topic transition を作る (§8)。RelationRole を写像: **ThreadContinuation→QuoteTransition / EvidenceCitation・AnnualEventReuse→HistoricalReferenceTransition / TemplateReuse→TemplateReuseTransition**、同一メール共起→CoParagraph。低 confidence 引用は **bounded boost**(`Min[confidence, cap]`)。各 transition に Weight/EvidenceRefs/PrivacyMax。
戻り値: `<|fromRef -> {<|"From", "To", "Kind", "Weight", "EvidenceRefs", "PrivacyMax"|>...}|>`。Options: `"MaxTopicsPerMail"`(8), `"BoundedBoostCap"`(0.3)。

## Inc 5: 検索 / primer 接続 (§9)

### SourceVaultMailStructSessionChunks[structResult, opts] → {chunk...}
StructureMail の結果から session 単位の §7.2 検索 chunk を作る。**privacy は record の PrivacyLevel/Tags を継承**(Inc2 adapter 由来。OOPS list privacy は使わない)、topic は vocab で enrichment。Options: `"MaxBodyChars"`(4000), `"ReleaseState"`(Published)。

### SourceVaultMailStructBuildSearchIndex[structResult, opts] → Association
session chunk から `SourceVaultBuildProjectionIndex`(KeywordBM25V1, EntityDictionary=vocab) で projection index を作り load する。戻り値: `<|"IndexId", "Context", "ChunkCount", "ExcludedCount"|>`。Options: `"ReleaseContext"`(mailstruct-local), `"IndexId"`, `"IndexKind"`(KeywordBM25V1)。

### SourceVaultMailStructSearch[query, indexInfo, opts] → 検索結果
BuildSearchIndex の結果(or IndexId 文字列)で release-gate 付き検索(`SourceVaultSearch` ラッパ)。Options: `"ReleaseContext"`, `"Limit"`(10)。

### SourceVaultMailStructSessionDigest[session, structResult, opts] → Association
**§9 current session の結論と historical reference を分離**した digest。本 session の timeline を `CurrentDigest` に、`CrossSessionReferences`(EvidenceCitation/AnnualEventReuse/TemplateReuse/ForwardedContext) を `HistoricalReferences`(Role/Subject/Excerpt/ToSession) に分ける。過去参照を current の結論本文に混ぜない。
戻り値: `<|"SessionId", "Subject", "MailCount", "Topics", "CurrentDigest", "HistoricalReferences"|>`。Options: `"ParaChars"`(120), `"MaxMails"`(8)。

## 使用例（統合パイプライン → 検索 / digest）

```wolfram
SourceVaultMailEnsureLoaded["univ", "202606"];   (* ← 先に snapshot をロード (必須) *)
recs = SourceVaultMailRecordsForStructuring["MBox" -> "univ", "Limit" -> 100];
st   = SourceVaultStructureMail[recs, "OwnerRef" -> "owner:imai", "QuotePass" -> "Full"];
st["Report"]
Counts[#["Kind"] & /@ Flatten[Values[st["TopicGraph"]]]]   (* Quote/Historical/CoParagraph *)

idx = SourceVaultMailStructBuildSearchIndex[st];
res = SourceVaultMailStructSearch["Zoom", idx, "Limit" -> 5];

h = Select[st["Sessions"], #["CrossSessionReferences"] =!= {} &];
SourceVaultMailStructSessionDigest[First[h], st]   (* Current / HistoricalReferences 分離 *)
```

## 注意 / 既知の制約

- **header degraded**: 現行 maildb は MessageIDToken のみ保持のため reply header チェーンは張れない。session は quote / subject fallback で形成される。新規 import で raw header から InReplyTo/References token を生成する hook は今後（§6b）。
- **UnknownReference**: 日本語頻出句が誤マッチした曖昧引用は `UnknownReference` になり session merge に使われない（正しく非マージ）。DF フィルタ・edge 集約でノイズを削減済み。閾値の追い込みは仕様 §13 open issue（実データ較正）。
- **snapshot ロード必須**: search/digest は `SourceVaultMailSnapshotList[]` を使うため、先に `SourceVaultMailEnsureLoaded["<mbox>", "<yyyymm>"]` でロードしないと records が空になる。
- **復号失敗メール**: `Body -> Missing["BodyDecryptFailed"]` の record は段落 topic 抽出/chunk から自動的に除外され、低漏洩 metadata のみ残る。
- 残（任意 P2）: §9b live SearchView / annotation（親 `SourceVaultSearchView` 接続）、topic 品質 tuning（汎用語 stoplist / IDF、§13 open issue）。
