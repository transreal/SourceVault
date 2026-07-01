# SourceVault_searchindex API リファレンス

パッケージ: `SourceVault`
依存: [SourceVault_core](https://github.com/transreal/SourceVault_core)
ロード順: SourceVault.wl → SourceVault_core.wl → **SourceVault_searchindex.wl** → SourceVault_servicemanager.wl
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_searchindex.wl"]]`
担当: 検索系 profile registry・release policy 評価・object revocation/tombstone・versioned snapshot・PDFIndex legacy adapter・native projection index・TPO 制約/目的別 index/低遅延 interaction・マルチモーダル event 正規化/media index

## §7.2 chunk スキーマ（各関数の "Chunks" 引数共通）

各 chunk は `Association` で以下のキーを持つ。`"NormalizedText"` または `"Text"` のいずれかが必要。

| キー | 型 | 用途 |
|---|---|---|
| `"ChunkId"` | String | chunk 識別子 |
| `"SourceVaultObjectId"` | String (省略可) | revocation 照合に使う |
| `"Text"` / `"NormalizedText"` | String | 検索対象テキスト |
| `"Tags"` | {String...} | release gate の tag 判定に使う |
| `"PrivacyLevel"` | Real | release gate の PL 判定 |
| `"State"` | String | `"Approved"` / `"Published"` / `"Released"` で gate 通過 |
| `"Page"` | Integer / Missing | ページ番号 |
| `"SourceRef"` | Association | `<|"Title" -> ...|>` |
| `"ValidFrom"` / `"ValidUntil"` | DateObject / ISO String (省略可) | 有効期限 |

## プロファイル永続化

### $SourceVaultPersistSearchProfiles
型: Boolean, 初期値: True
True のとき DB プロファイル（ReleaseContext / PDFIndexProfile / SearchIndexProfile / PDFIndex migration rule）を PrivateVault/config へ自動永続化する。SearchBackend / OCRBackend は永続化しない（明示登録のみ）。

### SourceVaultSaveSearchProfiles[] → path | $Failed
DB プロファイルを `PrivateVault/config/searchindex-profiles.wxf` に保存する。

### SourceVaultLoadSearchProfiles[] → Association
永続化済み DB プロファイルを registry に復元する（session で登録済みの同名は上書きしない）。
戻り値: `<|"Status" -> "Loaded"|"NoFile"|"BadFile", "ReleaseContexts" -> _Integer, "PDFIndexProfiles" -> _Integer, "SearchIndexProfiles" -> _Integer, "MigrationRules" -> _Integer|>`

## Release Context 登録・解決

### SourceVaultRegisterReleaseContext[name, spec] → Association | Failure
release context を登録する。`spec` 必須: `"MaxPrivacyLevel" -> _Real`。
任意 spec キー: `"RequiredTags"`, `"DenyTags"`, `"ReleaseContextTag"`, `"Sink"`, `"DisplayName"`, `"RequireCitation"`, `"AllowAnswerGeneration"`, `"AllowRawPageImage"`, `"AllowDownloadOriginal"`, `"DefaultLatencyProfile"`。
boolean の既定は安全側 (False)。`MaxPrivacyLevel` が欠如または非数値の場合は Failure を返す。
戻り値: `<|"Status" -> "OK", "Kind" -> "ReleaseContext", "Name" -> name|>`

### SourceVaultReleaseContextSpec[name] → Association | Failure
登録済み release context spec を返す。未登録なら Failure。

### SourceVaultListReleaseContexts[] → {String...}
登録済み release context 名のリストを返す。

## SearchIndex / PDFIndex / Backend Profile 登録・解決

### SourceVaultRegisterSearchIndexProfile[name, spec] → Association
search index profile を登録する。spec の内容に制約なし。

### SourceVaultResolveSearchIndexProfile[name] → Association | Failure
search index profile を解決する。未登録なら fail-closed (Failure)。

### SourceVaultRegisterPDFIndexProfile[name, spec] → Association
PDFIndex profile を登録する。spec の内容に制約なし。

### SourceVaultResolvePDFIndexProfile[name] → Association | Failure
PDFIndex profile を解決する。未登録なら fail-closed。

### SourceVaultRegisterSearchBackend[name, spec] → Association | Failure
embedding/keyword backend を登録する。spec 必須: `"Kind" -> _String`。

### SourceVaultResolveSearchBackend[name] → Association | Failure
search backend を解決する。未登録なら fail-closed。

### SourceVaultRegisterOCRBackend[name, spec] → Association
OCR backend を登録する。spec の内容に制約なし。

### SourceVaultResolveOCRBackend[name] → Association | Failure
OCR backend を解決する。未登録なら fail-closed。

## Registry 管理

### SourceVaultListProfiles[kind] → {String...}
指定 kind の登録名を返す。kind: `"ReleaseContext"` / `"SearchIndexProfile"` / `"PDFIndexProfile"` / `"SearchBackend"` / `"OCRBackend"`。

### SourceVaultListProfiles[] → Association
全 kind の登録名 summary を返す: `<|"ReleaseContext" -> {...}, ...|>`

### SourceVaultClearRegistry[kind] → Association
指定 kind の registry を消去する（test/再 init 用）。戻り値: `<|"Status" -> "OK", "Kind" -> kind|>`

### SourceVaultClearRegistry[] → Association
全 registry を消去する。戻り値: `<|"Status" -> "OK", "Cleared" -> "All"|>`

## Release Policy 評価 (§6.1-6.3)

### SourceVaultEvaluateReleasePolicy[source, contextName] → Association | Failure
source（object/chunk Association）が release context で公開可能か評価する。
判定: `PrivacyLevel <= MaxPrivacyLevel` かつ `RequiredTags ⊆ Tags` かつ `Tags ∩ DenyTags = {}` かつ `State ∈ {Approved, Published, Released}` かつ NotExpired（ValidFrom/ValidUntil を Now で評価）。
戻り値: `<|"Decision" -> "Permit"|"Deny", "Why" -> {String...}, "PolicyDigest" -> _, "Context" -> contextName|>`
contextName 未登録の場合は Failure を返す（fail-closed）。

## Object Revocation / Tombstone (§6.3.1)

### SourceVaultRevokeObject[objectId, opts] → Association
ObjectRevoked event を append-only event log に記録する。
Options: `"Reason" -> ""`, `"ObjectSnapshotRef" -> All`（All で全 snapshot 対象、文字列で特定 snapshot 指定）, `"EffectiveAtUTC" -> Automatic`（Automatic で CreatedAtUTC に委ねる）, `"State" -> "Revoked"`（`"Revoked"` / `"Archived"` / `"Deleted"`）

### SourceVaultBuildRevocationSet[opts] → Association
revocation 系 event（ObjectRevoked / ObjectStateChanged / RevocationTombstoneCompacted）を全件 replay して HotRevocationSet と Epoch を作る。
戻り値: `<|"HotRevocationSet" -> <|objectId -> <|"State", "Reason", "EffectiveAtUTC", "ObjectSnapshotRef"|>...|>, "Epoch" -> _Integer, "BuiltAtUTC" -> _String|>`
Epoch = revocation 系 event 数（high-water mark、単調増加）。
**count-keyed cache**: 全 event ファイル数（append-only ゆえ追加/compaction で必ず変化、read/parse せず FileNames のみで安価）を freshness token にして結果を memoize する。event 数が不変なら全 event の再 replay を避ける（毎検索の全 log 読み = 数秒を回避）。append があれば必ず無効化されるので revocation を取りこぼさない（cross-process correct）。Options: `"NoCache" -> False`（True で強制再構築）。

### SourceVaultObjectRevocationStatus[objectId] → Association
object の revocation 状態を返す。
revoked: `<|"Revoked" -> True, "State", "Reason", "EffectiveAtUTC", "Epoch"|>`
未 revoked: `<|"Revoked" -> False, "State" -> Missing["NotRevoked"], "Epoch"|>`

### SourceVaultRevocationEpoch[] → Integer
現在の revocation epoch（high-water mark）を返す。

### SourceVaultCompactRevocationTombstone[objectId, opts] → Association
tombstone を圧縮し RevocationTombstoneCompacted event を記録する (§6.3.1-9)。呼び出し側は全 active projection からの除外を保証すること。
Options: `"Reason" -> "compacted"`

## Versioned Snapshot (§8.3-8.5, Phase 4)

### SourceVaultRegisterRetrievalWorkflowKind[kind, spec] → Association
retrieval workflow kind を登録する。組み込み kind（登録不要）: `"DirectIndexAnswer"` / `"KeywordFTS"` / `"VectorRAG"` / `"HybridRAG"` / `"AgenticKeywordSearch"` / `"DirectCorpusInteraction"` / `"Cascade"` / `"ManualReviewDraft"`。

### SourceVaultListRetrievalWorkflowKinds[] → {String...}
組み込み + 追加登録済みの workflow kind を返す。

### SourceVaultSaveRetrievalWorkflowSnapshot[name, spec, opts] → Association | Failure
WorkflowSnapshot を immutable 保存する (§8.3)。spec 必須: `"WorkflowKind" -> _String`（登録済み kind でなければ Failure）。credential/実 path/IP を spec に含めてはならない（profile ref のみ）。
→ `<|"Status", "Ref", "Digest", ...|>`
Options: `"Alias" -> None`
例: `SourceVaultSaveRetrievalWorkflowSnapshot["wf-kw", <|"WorkflowKind" -> "KeywordFTS", "SearchIndexProfile" -> "myProfile"|>, "Alias" -> "wf-kw-v1"]`

### SourceVaultLoadRetrievalWorkflowSnapshot[ref] → Association | Failure
WorkflowSnapshot を読む。ref はスナップショット参照文字列。

### SourceVaultFreezeCorpusSnapshot[corpusId, opts] → Association | Failure
検索対象集合を immutable CorpusSnapshot に固定する (§8.4)。
→ `<|"Status", "Ref", "Digest", ...|>`
Options: `"Items" -> None`（必須: `{<|"SourceVaultObjectId" -> ..., "ContentHash" -> ..., ...|>...}`）, `"ReleaseContextRef" -> None`, `"Version" -> Automatic`, `"Alias" -> None`

### SourceVaultCorpusSnapshotInfo[ref] → Association | Failure
CorpusSnapshot の概要を返す。戻り値: `<|"CorpusId", "ItemCount", "ReleaseContextRef", "Digest"|>`

### SourceVaultDiffCorpusSnapshots[aRef, bRef] → Association | Failure
二つの CorpusSnapshot の item 差分を返す。item key は `"SourceVaultObjectId"` または `"ContentHash"` で識別。
戻り値: `<|"Added" -> {key...}, "Removed" -> {key...}, "Common" -> _Integer|>`

### SourceVaultBuildIndexSnapshot[indexId, corpusRef, workflowRef, opts] → Association | Failure
IndexSnapshot を作る (§8.5)。corpusRef / workflowRef が実在しなければ fail-closed。
→ `<|"Status", "Ref", "Digest", ...|>`
Options: `"Artifacts" -> <||>`, `"IndexKinds" -> {"KeywordFTS"}`, `"Version" -> Automatic`, `"Alias" -> None`

### SourceVaultIndexSnapshotInfo[ref] → Association | Failure
IndexSnapshot の概要を返す。戻り値: `<|"IndexId", "IndexKinds", "CorpusSnapshotRef", "WorkflowSnapshotRef", "Digest"|>`

### SourceVaultValidateIndexSnapshot[ref] → Association | Failure
IndexSnapshot の digest と corpus/workflow ref の解決可能性を検証する。
戻り値: `<|"Status" -> "Valid"|"Invalid", "DigestValid" -> True|False, "CorpusResolvable" -> True|False, "WorkflowResolvable" -> True|False, "Ref"|>`

## Prompt Snapshot (§8.10)

### SourceVaultSavePromptSnapshot[name, prompt, metadata] → Association
prompt を immutable snapshot として保存する。`metadata` は省略可（既定 `<||>`）。`metadata["Alias"]` で alias 指定可。
例: `SourceVault`SourceVaultSavePromptSnapshot["myPrompt", "あなたはアシスタントです。", <|"Alias" -> "prompt-v1"|>]`

### SourceVaultLoadPromptSnapshot[ref] → Association | Failure
PromptSnapshot を読む。`SourceVault`SourceVaultLoadPromptSnapshot[ref]` として呼ぶ。

## PDFIndex Legacy Adapter (§7.4, Phase 3)

### $SourceVaultPDFLegacySearchFunction
型: Function | Automatic, 初期値: Automatic
legacy 検索関数の override。Automatic で `PDFIndex`pdfSearch` を使う。`fn[query, n, collection]` が pdfSearch 互換の Dataset/連想リストを返すこと。`PDFIndex`pdfSearch` が未ロードかつ Automatic のままなら Failure。test 差し替え用。

### SourceVaultSearch[query, opts] → {Association...} | Failure
release context gate 付きで検索し Permit のみの SearchResult リストを返す (§7.4)。raw local path は返さない。request-time gate を再評価する。`"Index"` 指定時は native projection index を使い PDFIndex 非依存。scorer は index の `IndexKind` で `iNativeSearch` が dispatch する: `KeywordBigram` → bigram スコア、`KeywordBM25V1` → BM25 + entity OR-match、`DenseV1` → query を index の provider で埋め込み格納 vector と cosine（`RetrievalKind="DenseEmbedding"`）。query / chunk のゲート・revocation 適用は全 kind で共有。
Options: `"ReleaseContext" -> None`（必須）, `"PDFIndexProfile" -> None`, `"Collection" -> Automatic`, `"Limit" -> 20`, `"Index" -> None`（native index ID）
SearchResult スキーマ: `<|"ResultId", "ChunkId", "Score", "RetrievalKind" -> "KeywordBigram"|"KeywordBM25", "Snippet", "EvidenceRef", "Citation" -> <|"Title", "Page", ...|>, "SourceVaultObjectId", "ReleaseDecision" -> "Permit", "Revoked", "RequestTimeGateReevaluated" -> True, "PolicyDigestAtRequest", "Why", ("ScoreBreakdown")|>`（`RetrievalKind` / `ScoreBreakdown` は追加キー＝後方互換）
例: `SourceVaultSearch["量子コンピュータ", "ReleaseContext" -> "public", "Index" -> "my-bm25", "Limit" -> 10]`

### SourceVaultPDFIndexLegacySearch[query, opts] → {Association...} | Failure
legacy PDFIndex を呼び生結果リストを返す。pdfAskLLM は呼ばず Notebook も書かない。
Options: `"Collection" -> Automatic`, `"Limit" -> 20`

### SourceVaultPDFIndexLegacyResultToSearchResult[row, opts] → Association
legacy 1 行を SearchResult schema に正規化する（raw path 非含）。
戻り値: `<|"ResultId", "ChunkId", "Score", "ScoreBreakdown" -> <|"Embedding" -> Missing[...], "Keyword" -> Missing[...]|>, "Snippet", "EvidenceRef", "Citation" -> <|"Title", "Page", "DocId"|>, "LegacyTags"|>`

### SourceVaultRegisterPDFIndexMigrationRule[profile, rule] → Association
legacy privacy flag から release context への移行 rule を登録する (§7.4.1)。rule 未登録なら projection は空になる（fail-closed）。永続化対象。
rule キー: `"AssignReleaseContexts" -> {String...}`, `"AssignTags" -> {String...}`, `"AssignPrivacyLevel" -> _Real`, `"AssignState" -> _String`, `"RequireHumanReviewed" -> True|False`, `"AssignValidFrom"`, `"AssignValidUntil"`, `"DefaultReleaseContextRef"`

### SourceVaultPreviewPDFIndexMigration[profile, opts] → {Association...}
sample 行に migration rule を適用し付与 release メタと gate 判定を返す（副作用なし）。
Options: `"SampleResults" -> {}`, `"ReleaseContext" -> None`（None のとき rule の `DefaultReleaseContextRef` を使う）
戻り値: `{<|"Title", "AssignedSource", "Decision" -> "Permit"|"Deny"|"NoContext", "Why"|>...}`

### SourceVaultPDFIndexMigrationReport[profile] → Association
登録済み migration rule と human-review 要否を返す。
rule あり: `<|"Status" -> "OK", "Profile", "Rule", "RequireHumanReviewed"|>`
rule なし: `<|"Status" -> "NoRule", "Profile", "Note"|>`

## Native Projection Index (§6.3, §7.6, Phase 5)

### SourceVaultBuildProjectionIndex[contextName, opts] → Association | Failure
chunk 群に build-time release gate を適用し Permit のみの projection index を作り immutable 保存する (§6.3)。`"IndexKind"` で scorer を選ぶ: `"KeywordBigram"`（既定、従来の bigram スコア）/ `"KeywordBM25V1"`（日本語正規化 + unigram/bigram/exact の BM25。`SourceVault_lexical` の `SourceVaultBuildLexicalStats` で `LexicalStats` を build し record に格納する）/ `"DenseV1"`（各 chunk を既定 embedding provider で埋め込み `DenseVectors`/`DenseDim`/`EmbeddingProvider` を record に格納。表記に依らない意味的 recall の dense arm。BM25 と同じ SearchFields 被覆で埋め込む）。
→ `<|"Status" -> "OK", "IndexId", "Ref", "ChunkCount" -> _Integer, "ExcludedCount" -> _Integer, "IndexKind"|>`
Options: `"Chunks" -> None`（必須: §7.2 chunk のリスト）, `"IndexId" -> Automatic`（既定: contextName <> `"-proj"`）, `"IndexKind" -> "KeywordBigram"`, `"EntityDictionary" -> None`（`KeywordBM25V1` 時に seed entity dictionary を渡すと entity stream を作り、surface form の OR-match で表記非一致/OOV の topic を index/query 両側で結ぶ。§4.1.1。`SourceVault_oopsseed` の `SourceVaultImportOOPSSeedDictionary` 等で作る）
例: `SourceVaultBuildProjectionIndex["public", "Chunks" -> chunks, "IndexId" -> "pub-bm25", "IndexKind" -> "KeywordBM25V1", "EntityDictionary" -> dict]`

### SourceVaultLoadSearchIndex[indexIdOrRef, opts] → Association | Failure
projection index を memory に読み込む。`"snapshot:..."` 形式の ref または indexId 文字列を受け付ける。
戻り値: `<|"Status" -> "Loaded", "IndexId", "ChunkCount", "ReleaseContextRef"|>`

### SourceVaultUnloadSearchIndex[indexId] → Association
読み込んだ index を解放する。戻り値: `<|"Status" -> "Unloaded", "IndexId"|>`

### SourceVaultReloadSearchIndex[indexId, opts] → Association | Failure
index を unload して再ロードする。

### SourceVaultListSearchIndexes[] → {String...}
memory に読み込み済みの index id を返す。

### SourceVaultSearchIndexStatus[indexId] → Association
index の読込状態/chunk 数/context を返す。
ロード済み: `<|"IndexId", "Loaded" -> True, "ChunkCount", "ReleaseContextRef", "IndexKind" -> "KeywordBigram"|"KeywordBM25V1"|"DenseV1"|>`
未ロード: `<|"IndexId", "Loaded" -> False|>`

## Dense / Hybrid Retrieval（embedding arm）

lexical(BM25)を精度の主軸に、表記に依らない意味的 recall を dense arm で足し、**RRF（Reciprocal Rank Fusion）**で融合する。embedder は injectable（既定は決定的 hashing。実測用の意味的 embedder＝Wolfram NetModel / LM Studio 等を register で差し替える）。`DenseV1` build は anisotropy 対策の **mean-centering**（corpus 平均 `DenseMean` を引いて再正規化）を適用し、query 側も同じ平均で center してから cosine する。

> **既定 OFF のオプトイン**: dense/hybrid は既存の BM25/bigram 経路に影響しない追加機能。OOPS seed コーパス（小規模・entity 濃・seed ラベルが既に OOV/言い換えを橋渡し）での go/no-go 実測では、bge-m3 を centering しても BM25+seed を上回らず hybrid も改善しなかった（**NO-GO**）。**大規模コーパスや強い embedder での再評価**用に配線を保持している。seed ラベル層がある系では dense の増分価値は小さい。

### SourceVaultRegisterEmbeddingProvider[name, fn] → Association
embedding provider を登録する。`fn[{text..}]` は数値ベクトルのリストを返す（L2 正規化推奨、次元は全 text で一定）。実 embedder はここで差し込む。
例（LM Studio の OpenAI 互換 `/v1/embeddings` を使う場合）:
```mathematica
SourceVaultRegisterEmbeddingProvider["LMStudio", Function[texts,
  With[{r = URLExecute[HTTPRequest["http://127.0.0.1:1234/v1/embeddings",
       <|"Method" -> "POST", "ContentType" -> "application/json",
         "Body" -> ExportString[<|"model" -> "text-embedding-bge-m3", "input" -> texts|>, "RawJSON"]|>], "RawJSON"]},
    Lookup[#, "embedding"] & /@ Lookup[r, "data", {}]]]];
SourceVaultSetEmbeddingProvider["LMStudio"];
```

### SourceVaultListEmbeddingProviders[] → {String...}
登録済み provider 名。既定は `{"HashingNGramV1"}`。

### SourceVaultSetEmbeddingProvider[name] → Association | Failure
既定 provider を切り替える（未登録なら Failure）。以降の `DenseV1` build と `SourceVaultEmbedTexts` がこれを使う。

### SourceVaultEmbeddingProvider[] → String
現在の既定 provider 名。

### SourceVaultEmbedTexts[{text..}] → {Vector...} | Failure
既定 provider で埋め込みベクトルのリストを返す。

### $SourceVaultEmbeddingDim → Integer
既定(hashing)embedder の次元（既定 256）。実 provider は自身の次元を返してよい。

### SourceVaultHybridSearch[query, opts] → {Association...} | Failure
BM25 index と Dense index を検索し **RRF** で融合、両 arm とも release gate 済み（Permit）の結果を `FusedScore` 降順で返す。各結果は代表 SearchResult に `FusedScore` と `RetrievalKind -> "HybridRRF"` を付す。RRF: 各 arm の rank(1-based) から `score[id] += 1/(k + rank)`。
Options: `"ReleaseContext" -> None`（必須）, `"BM25Index" -> None`, `"DenseIndex" -> None`, `"Limit" -> 20`, `"RetrievalDepth" -> 50`（各 arm の取得深さ）, `"RRFConstant" -> 60`
例: `SourceVaultHybridSearch["サイバーパンク", "ReleaseContext" -> "kb", "BM25Index" -> "kb-bm25", "DenseIndex" -> "kb-dense"]`

## Mining Primer (§6.1/6.2)

mining サマリー由来の低コスト探索層。raw chunk でなく summary item を index し、importance / freshness を加味して採点する。BuildProjectionIndex と同型だが item は summary レベル。

### SourceVaultBuildPrimerIndex[contextName, opts] → Association | Failure
primer item に build-time release gate を適用し Permit のみの `SourceVaultPrimerIndex` を immutable 保存する。各 item の summary/title/tags/authors を lexical chunk に写像し `SourceVaultBuildLexicalStats` で BM25 stats を作る。
Options: `"Items" -> None`（必須: `{<|"ObjectURI", "SourceVaultObjectId", "Title", "Summary", "Tags", "Authors", "Signals" -> <|"EffectiveImportance" -> _|>, "Freshness" -> "Fresh"|"StalePrimer", "PrivacyLevel", "State"|>...}`。mining 層が供給）, `"PrimerId" -> Automatic`（既定 contextName <> `"-primer"`）
→ `<|"Status" -> "OK", "PrimerId", "Ref", "ItemCount", "ExcludedCount"|>`

### SourceVaultLoadPrimerIndex[primerIdOrRef] → Association | Failure
primer index を memory（`$loadedPrimers`）に読み込む。`SourceVaultPrimerSearch` は未ロードなら自動 load。

### SourceVaultPrimerSearch[query, opts] → {Association...}
primer を採点して Permit のみ返す。`PrimerScore = BM25(summary/title/tags/authors) + MiningBoost + EffectiveImportance·ImportanceWeight − StalePrimerPenalty`。`MiningBoost = Min[MaxBoost, MaxBoost·EffectiveImportance]`（bounded）。`Freshness == "StalePrimer"` のとき `StalePrimerPenalty` を引く。request-time gate / revocation を再評価し、結果は `EvidenceKind -> "SummaryPrimer"`（回答根拠にはしない）。
必須 `"ReleaseContext"`（fail-closed）。Options: `"PrimerIndex" -> Automatic`（既定 `<rc>-primer`）, `"Limit" -> 20`, `"MaxBoost" -> 0.2`, `"ImportanceWeight" -> 0.1`, `"StalePrimerPenalty" -> 0.15`, `"UseSummaries" -> True`, `"UseMining" -> True`
戻り値: `{<|"ResultId", "SourceVaultObjectId", "ObjectURI", "Title", "Summary", "Score", "BM25", "MiningBoost", "ImportanceTerm", "FreshnessPenalty", "Freshness", "EvidenceKind" -> "SummaryPrimer", "ReleaseDecision", "Revoked", "RequestTimeGateReevaluated", "Why"|>...}`

## TPO 制約 / 目的別 Index / 低遅延 Interaction (§16, Phase 7)

### SourceVaultRegisterTPOProfile[tpoId, spec] → Association | Failure
TPOProfile（場所/イベント/役割/許可話題/回答長/遅延制約）を登録する (§16.2)。
spec 必須: `"AllowedScope" -> <|"TopicTags" -> {String...}, ...|>`
任意 spec キー: `"ReleaseContextRefs" -> {String...}`, `"AllowedScope"["ReleaseContextRefs"]`, `"TopicKeywords" -> <|topic -> {kw...}|>`, `"OutOfScopeKeywords" -> {String...}`, `"ChannelProfile" -> <|"MaxAnswerCharacters" -> 120, "MaxAnswerSentences" -> 2|>`, `"OutOfScopePolicy" -> <||>`
`AllowedScope.TopicTags` が無い場合は Failure。

### SourceVaultTPOProfile[tpoId] → Association | Failure
登録済み TPOProfile を返す。未登録なら Failure。

### SourceVaultListTPOProfiles[] → {String...}
登録済み TPO id を返す。

### SourceVaultValidateTPOProfile[spec] → Association
TPOProfile spec の必須項目を検査する。戻り値: `<|"Status" -> "OK"|"Invalid", "Issues" -> {String...}|>`

### SourceVaultClassifyQuestionTPO[question, tpoId] → Association | Failure
質問が TPO に即すか分類し QueryScopeDecision を返す (§16.5)。rule + keyword で判定（LLM 非依存）。
Decision: `"InScope"` / `"OutOfScope"` / `"NeedsClarification"` / `"Blocked"`
判定ロジック: OutOfScopeKeywords にヒット → OutOfScope、TopicKeywords にヒットかつ AllowedScope.TopicTags に含まれる → InScope、いずれもヒットなし → NeedsClarification。
戻り値: `<|"ObjectClass" -> "SourceVaultQueryScopeDecision", "Decision", "TPOProfileRef", "MatchedTopicTags", "ReleaseContextRefs", "Reason", "Confidence"|>`

### SourceVaultEvaluateTPOGate[question, tpoId] → Association | Failure
`SourceVaultClassifyQuestionTPO` の別名。

### SourceVaultBuildPurposeIndex[indexId, tpoId, opts] → Association | Failure
TPO 制約（許可 topic tags）で chunk を絞り、release context gate を適用して projection index を作る (§16.4)。build-time gate は内部で `SourceVaultBuildProjectionIndex` が行う。
Options: `"Chunks" -> None`（必須）, `"ReleaseContext" -> Automatic`（Automatic で TPO の `AllowedScope.ReleaseContextRefs` または `ReleaseContextRefs` の先頭文字列を使う。解決できなければ Failure）
例: `SourceVaultBuildPurposeIndex["lobby-idx", "lobbyTPO", "Chunks" -> chunks]`

### SourceVaultAnswerForInteraction[question, tpoId, opts] → Association | Failure
低遅延 cascade で対話応答を作る (§16.10)。TPOGate → PurposeIndex 検索 → 短答/fallback の順で処理。回答長は TPO の `ChannelProfile.MaxAnswerCharacters` で切り詰める。
→ `<|"Decision" -> "Speak"|"Clarify"|"Refuse"|"NoAnswer", "AnswerText" -> _String, "EvidenceRefs" -> {String...}, "WorkflowUsed" -> "PurposeIndex"|"TPOGate"|"Fallback", "ElapsedMs" -> _Integer, "DeadlineMet" -> True|False, "TPOGateDecision" -> _Association|>`
Options: `"Index" -> None`（必須: projection index ID）, `"ReleaseContext" -> Automatic`（Automatic で TPO の ReleaseContextRefs 先頭）, `"DeadlineMs" -> 3000`
例: `SourceVaultAnswerForInteraction["展示内容を教えて", "lobbyTPO", "Index" -> "lobby-idx", "ReleaseContext" -> "public", "DeadlineMs" -> 2000]`

## マルチモーダル Event / Media Index (§17, Phase 7b)

### SourceVaultMediaPrivacyDefault[kind] → Real
media kind ごとの既定 PrivacyLevel を返す (§17.13)。
`"AudioSegment"` / `"CameraFrame"` / `"ScreenSnapshot"` → `1.0`, `"ASRTranscript"` → `0.8`, `"UserQuestion"` → `0.7`, `"SystemSummary"` / `"ResponseDraft"` / `"VisualCaption"` / `"OCR"` / `"FAQCandidate"` / `"RedactedTranscript"` → `0.5`, その他 → `1.0`

### SourceVaultAppendMultimodalEvent[event] → Association | Failure
MultimodalEvent を正規化し append-only event log に記録する (§17.4)。`"PrivacyLevel"` 未指定なら kind 既定値を使う（raw media は 1.0）。
event 必須: `"SessionID" -> _String`, `"Kind" -> _String`

### SourceVaultSessionEvents[sessionId, opts] → {Association...}
session の MultimodalEvent を時刻順 (CreatedAtUTC) に返す。
Options: `"Kind" -> All`（特定 Kind で絞り込む）

### SourceVaultBuildRealtimeContext[sessionId, opts] → Association
直近 transcript + visual を ObservationEnvelope にまとめる (§17.10)。
→ `<|"ObjectClass" -> "SourceVaultObservationEnvelope", "EnvelopeID", "SessionID", "TranscriptText", "TranscriptEvents", "VisualEvents", "UserQuestion" -> _String|Missing["NoQuestion"], "CreatedAtUTC"|>`
Options: `"TranscriptWindowSeconds" -> 20`, `"VisualWindowSeconds" -> 5`, `"MaxFrames" -> 3`

### SourceVaultBuildMediaIndex[sessionId, opts] → Association | Failure
media 由来の derived イベント（transcript/caption/OCR/summary）を release gate して projection index 化する (§17.14)。raw audio/frame は含まない（`$derivedMediaKinds` 内のみ対象）。
Options: `"ReleaseContext" -> None`（必須）, `"IndexId" -> Automatic`（既定: sessionId <> `"-media"`）, `"Modalities" -> {"ASRTranscript", "VisualCaption", "OCR", "SystemSummary"}`（`$rawMediaKinds` は除外される）

## Survey Corpus / Survey Ingest Plan (§16.3, §16.7)

### SourceVaultCreateSurveyIngestPlan[surveyId, spec, opts] → Association | Failure
サーベイ取り込み計画を immutable snapshot として保存する。`SourceVault`SourceVaultCreateSurveyIngestPlan[...]` として呼ぶ。
spec 必須: `"SourceQueries" -> {_...}`, `"IngestPolicy" -> _Association`
→ `<|"Status" -> "OK", "ObjectRef", "SnapshotRef", "Digest", "SurveyId", "SurveyVersion", "Warnings"|>`
Options: `"SurveyVersion" -> Automatic`

### SourceVaultIngestSurveyResult[planRef, source, opts] → Association | Failure
planRef の IngestPolicy を適用してサーベイ結果を取り込む（fail-closed）。`SourceVault`SourceVaultIngestSurveyResult[...]` として呼ぶ。
source 任意キー: `"ProvenanceRef"`, `"ReleaseContextRefs"`, `"PrivacyLevel"`, `"Content"`, `"BlobRef"`, `"ReviewState"`, `"TopicTags"`, `"StalenessClass"`, `"ValidFrom"`, `"ValidUntil"`, `"Title"`
fail-closed 条件: `RequireProvenance` = True かつ `ProvenanceRef` 無し / `RequireReleaseContext` = True かつ `ReleaseContextRefs` 空 / `PrivacyLevel` > `MaxPrivacyLevel`
→ `<|"Status" -> "OK", "ItemRef", "BlobRef", "ReviewState", "Warnings"|>`

### SourceVaultReviewSurveyItem[itemRef, decision, opts] → Association
サーベイ item にレビュー判定を記録する（SurveyItemReviewed event）。`SourceVault`SourceVaultReviewSurveyItem[...]` として呼ぶ。
decision: `"Approved"` / `"Rejected"` / `"NeedsHumanReview"` 等の文字列。
戻り値: `<|"Status" -> "OK", "ItemRef", "ReviewState"|>`

### SourceVaultMarkSurveyItemStale[itemRef, reason, opts] → Association
サーベイ item を stale としてマークする（SurveyItemStale event）。`SourceVault`SourceVaultMarkSurveyItemStale[...]` として呼ぶ。