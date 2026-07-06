# SourceVault_searchindex API リファレンス

## 概要
SourceVault の検索拡張 (data plane)。SourceVault_core の digest / event log / snapshot store に依存する。担当範囲は fail-closed (§5.4) を原則とする検索系ローカルプロファイルの登録・検証・解決、release context policy 評価 (§6.1-6.3)、個別 object revocation / tombstone (§6.3.1)、versioned snapshot (§8)、PDFIndex legacy adapter (§7.4)、native projection index (§6.3, §7.6)、mining primer index (§6.1/6.2)、TPO 制約と目的別 index (§16)、マルチモーダル event / media index (§17)、dense / hybrid retrieval と検索評価ハーネス。context は `SourceVault``。private helper は `SourceVault`SearchIndexPrivate`` 文脈に置き公開シンボルと非衝突。

ロード順 (§2.4): `SourceVault.wl` → `SourceVault_core.wl` → `SourceVault_searchindex.wl` → `SourceVault_servicemanager.wl`。UTF-8 エンコード。読み込みは `Block[{$CharacterEncoding = "UTF-8"}, Get[...]]`。

設計要点:
- fail-closed: 未登録 profile の解決は `Failure["UnregisteredProfile", ...]` を返す。migration rule 未登録なら projection は空。gate 判定不能は Deny 側に倒す。
- release gate は build 時 (収録判定) と request 時 (再評価) の二段。検索結果は Permit のみ返し raw local path は含めない。
- boolean 系 spec の既定は安全側 (False)。ReleaseContext は RequireCitation のみ既定 True。
- 依存パッケージ: [SourceVault_core](https://github.com/transreal/SourceVault_core)、[SourceVault_lexical](https://github.com/transreal/SourceVault_lexical) (BM25 LexicalStats)、[PDFIndex](https://github.com/transreal/PDFIndex) (legacy adapter、任意)。

## プロファイル永続化
DB プロファイル (ReleaseContext / PDFIndexProfile / SearchIndexProfile + PDFIndex migration rule) のみ `PrivateVault/config/searchindex-profiles.wxf` へ自動永続化・自動復元する。SearchBackend / OCRBackend / web service endpoint は永続化せず明示登録のまま。

### $SourceVaultPersistSearchProfiles
型: Boolean, 初期値: True
True のとき DB プロファイル登録を自動永続化し、パッケージロード時に復元する。

### SourceVaultSaveSearchProfiles[] → path | $Failed
DB プロファイルを searchindex-profiles.wxf に保存する。

### SourceVaultLoadSearchProfiles[] → Association
永続化された DB プロファイルを読み込み registry へ復元する。session で登録済みの同名は上書きしない。戻り値は読み込み件数の Association (Status / ReleaseContexts / PDFIndexProfiles / SearchIndexProfiles / MigrationRules)。

## プロファイル registry (§5.3, §7.3)
kind は "ReleaseContext" / "SearchIndexProfile" / "PDFIndexProfile" / "SearchBackend" / "OCRBackend"。

### SourceVaultRegisterReleaseContext[name, spec] → Association
release context を登録する。spec 必須 "MaxPrivacyLevel" (_Real)。安全側 default を補う (RequiredTags->{}, DenyTags->{}, RequireCitation->True, AllowAnswerGeneration->False, AllowRawPageImage->False, AllowDownloadOriginal->False)。任意: ReleaseContextTag / Sink / DisplayName / DefaultLatencyProfile。戻り値 <|"Status"->"OK","Kind","Name"|>。必須欠落時 Failure["InvalidSpec",...]。
例: SourceVaultRegisterReleaseContext["public", <|"MaxPrivacyLevel"->0.3, "RequiredTags"->{"published"}, "DenyTags"->{"secret"}|>]

### SourceVaultReleaseContextSpec[name] → Association | Failure
登録済み release context spec を返す。未登録なら fail-closed Failure。

### SourceVaultListReleaseContexts[] → {name..}
登録済み release context 名のリスト。

### SourceVaultRegisterSearchIndexProfile[name, spec] → Association
search index profile を登録する。

### SourceVaultResolveSearchIndexProfile[name] → Association | Failure
search index profile を解決する。未登録なら fail-closed。

### SourceVaultRegisterPDFIndexProfile[name, spec] → Association
PDFIndex profile を登録する。CollectionRoot を持たせると SourceVaultSearch が collection を解決する。

### SourceVaultResolvePDFIndexProfile[name] → Association | Failure
PDFIndex profile を解決する。未登録なら fail-closed。

### SourceVaultRegisterSearchBackend[name, spec] → Association
embedding / keyword backend を登録する。spec 必須 "Kind" (_String)。永続化されない。

### SourceVaultResolveSearchBackend[name] → Association | Failure
search backend を解決する。未登録なら fail-closed。

### SourceVaultRegisterOCRBackend[name, spec] → Association
OCR backend を登録する。永続化されない。

### SourceVaultResolveOCRBackend[name] → Association | Failure
OCR backend を解決する。未登録なら fail-closed。

### SourceVaultListProfiles[kind] → {name..}
指定 kind の登録名を返す。

### SourceVaultListProfiles[] → Association
全 kind の登録名 summary (kind -> {name..})。

### SourceVaultClearRegistry[kind] → Association
指定 kind の registry を消去する (test / 再 init 用)。

### SourceVaultClearRegistry[] → Association
全 registry を消去する。

## release policy 評価 (§6.1-6.3)

### SourceVaultEvaluateReleasePolicy[source, context] → Association
source (object/chunk 連想) が release context で公開可能か評価する。判定条件: PrivacyLevel <= MaxPrivacyLevel かつ RequiredTags ⊆ Tags かつ Tags ∩ DenyTags = {} かつ State ∈ {Approved,Published,Released} かつ NotExpired (ValidFrom/ValidUntil)。すべて満たせば Permit、いずれか違反で Deny。
→ <|"Decision"->"Permit"|"Deny", "Why"->{理由文字列..}, "PolicyDigest", "Context"|>。context 未登録なら Failure。
source が参照するキー: Tags / PrivacyLevel / State / ValidFrom / ValidUntil。

## 個別 object revocation / tombstone (§6.3.1)
revocation 系 event class は ObjectRevoked / ObjectStateChanged / RevocationTombstoneCompacted。append-only event log に記録し replay で HotRevocationSet を構築する。

### SourceVaultRevokeObject[objectId, opts]
ObjectRevoked event を append-only event log に記録する。
→ AppendEvent の戻り値
Options: "Reason" -> "" (理由文字列), "ObjectSnapshotRef" -> All (All は "AllSnapshots" として記録), "EffectiveAtUTC" -> Automatic (Automatic は CreatedAtUTC に委譲), "State" -> "Revoked" ("Revoked"|"Archived"|"Deleted")

### SourceVaultObjectRevocationStatus[objectId] → Association
object の revocation 状態を返す。
→ Revoked なら <|"Revoked"->True,"State","Reason","EffectiveAtUTC","Epoch"|>、非 revoked なら <|"Revoked"->False,"State"->Missing["NotRevoked"],"Epoch"|>

### SourceVaultBuildRevocationSet[opts] → Association
revocation 系 event を CreatedAtUTC 順に replay し HotRevocationSet と Epoch を作る。event 数 (freshness token) をキーにキャッシュし、追加が無ければ再構築しない。
→ <|"HotRevocationSet"-><|objectId->info..|>, "Epoch"->_Integer, "BuiltAtUTC"|>。Epoch は revocation 系 event の high-water mark (単調増加)。
Options: "NoCache" -> False (True で強制再構築)

### SourceVaultRevocationEpoch[] → Integer
現在の revocation epoch (revocation 系 event 数) を返す。

### SourceVaultCompactRevocationTombstone[objectId, opts]
object の tombstone を圧縮し RevocationTombstoneCompacted event を記録する (§6.3.1-9)。HotRevocationSet から当該 objectId を除外する。呼び出し側は全 active projection からの除外を保証すること。
→ AppendEvent の戻り値
Options: "Reason" -> "compacted"

## versioned snapshot (§8.3-8.5, §8.10, Phase 4)
core の immutable snapshot store (SourceVaultSaveImmutableSnapshot) 上に構築する。

### SourceVaultRegisterRetrievalWorkflowKind[kind, spec] → Association
retrieval workflow kind を登録する。builtin: DirectIndexAnswer / KeywordFTS / VectorRAG / HybridRAG / AgenticKeywordSearch / DirectCorpusInteraction / Cascade / ManualReviewDraft。

### SourceVaultListRetrievalWorkflowKinds[] → {kind..}
builtin と登録済み workflow kind の和を返す。

### SourceVaultSaveRetrievalWorkflowSnapshot[name, spec, opts] → Association
WorkflowSnapshot を immutable 保存する (§8.3)。spec に "WorkflowKind" が必須で既知 kind でなければ Failure。credential / 実 path / IP を含めてはならない (profile ref のみ)。
→ <|"Status","Ref","Digest",...|>
Options: "Alias" -> None

### SourceVaultLoadRetrievalWorkflowSnapshot[ref] → Association | Failure
WorkflowSnapshot を読む。

### SourceVaultSavePromptSnapshot[name, prompt, metadata:<||>] → Association
prompt を code に埋め込まず PromptSnapshot として immutable 保存する (§8.10)。metadata の "Alias" キーで alias を指定できる。

### SourceVaultLoadPromptSnapshot[ref] → Association | Failure
PromptSnapshot を読む。

### SourceVaultFreezeCorpusSnapshot[corpusId, opts] → Association | Failure
検索対象集合を immutable CorpusSnapshot に固定する (§8.4)。
→ SaveImmutableSnapshot の戻り値
Options: "Items" -> None ({<|"SourceVaultObjectId","ContentHash",...|>..} 必須。非リストで Failure), "ReleaseContextRef" -> None, "Version" -> Automatic (Automatic は "auto"), "Alias" -> None

### SourceVaultCorpusSnapshotInfo[ref] → Association | Failure
CorpusSnapshot の概要を返す。→ <|"CorpusId","ItemCount","ReleaseContextRef","Digest"|>

### SourceVaultDiffCorpusSnapshots[a, b] → Association | Failure
二つの CorpusSnapshot の item 差分を返す。item key は SourceVaultObjectId (無ければ ContentHash)。→ <|"Added"->{key..},"Removed"->{key..},"Common"->_Integer|>

### SourceVaultBuildIndexSnapshot[indexId, corpusRef, workflowRef, opts] → Association | Failure
IndexSnapshot を作る (§8.5)。corpusRef / workflowRef が実在しなければ fail-closed (Failure["CorpusRefUnresolved"|"WorkflowRefUnresolved"])。
Options: "Artifacts" -> <||>, "IndexKinds" -> {"KeywordFTS"}, "Version" -> Automatic, "Alias" -> None

### SourceVaultIndexSnapshotInfo[ref] → Association | Failure
IndexSnapshot の概要を返す。→ <|"IndexId","IndexKinds","CorpusSnapshotRef","WorkflowSnapshotRef","Digest"|>

### SourceVaultValidateIndexSnapshot[ref] → Association | Failure
IndexSnapshot の digest と corpus/workflow ref の解決可能性を検証する。→ <|"Status"->"Valid"|"Invalid","DigestValid","CorpusResolvable","WorkflowResolvable","Ref"|>

## PDFIndex legacy adapter (§7.4, §7.4.1, Phase 3)
legacy PDFIndex を release context gate 越しに使う。検索結果は必ず gate を通し raw local path を返さない。

### $SourceVaultPDFLegacySearchFunction
型: Function | Automatic, 初期値: Automatic
legacy 検索関数の override。Automatic で `PDFIndex`pdfSearch` を使う。fn[query, n, collection] が pdfSearch 互換の Dataset / 連想リストを返すこと。test 差し替え用。

### SourceVaultSearch[query, opts] → {SearchResult..} | Failure
release context gate 付きで検索し SearchResult のリストを返す (§7.4)。各結果に request-time release gate を再評価し Permit のみ返す。"Index" 指定時は native projection index (iNativeSearch) を使う (PDFIndex 非依存)。それ以外は legacy → 正規化 → migration rule → gate。
Options: "ReleaseContext" -> None (必須。非文字列で Failure["ReleaseContextRequired"]), "PDFIndexProfile" -> None (指定時 CollectionRoot を解決), "Collection" -> Automatic, "Limit" -> 20, "Index" -> None (native projection index id)
例: SourceVaultSearch["query", "ReleaseContext"->"public", "Index"->"public-proj", "Limit"->10]

### SourceVaultPDFIndexLegacySearch[query, opts] → {row..} | Failure
legacy PDFIndex を呼び正規化前の生結果リスト (連想リスト) を返す。pdfAskLLM は呼ばず Notebook も書かない。pdfSearch も override も無ければ Failure["PDFIndexUnavailable"]。
Options: "Collection" -> Automatic, "Limit" -> 20

### SourceVaultPDFIndexLegacyResultToSearchResult[row] → Association
legacy 1 行を SearchResult schema に正規化する (raw path 非含)。→ <|"ResultId","ChunkId","Score","ScoreBreakdown","Snippet","EvidenceRef","Citation","LegacyTags"|>

### SourceVaultRegisterPDFIndexMigrationRule[profile, rule] → Association
legacy privacy flag から release context への移行 rule を登録する (§7.4.1)。永続化対象。rule 未登録なら projection は空 (fail-closed の期待挙動)。
rule 例: <|"AssignReleaseContexts"->{..}, "AssignTags"->{..}, "AssignPrivacyLevel"->0.3, "AssignState"->"Published", "AssignValidFrom"->_, "AssignValidUntil"->_, "RequireHumanReviewed"->True, "DefaultReleaseContextRef"->_|>

### SourceVaultPreviewPDFIndexMigration[profile, opts] → {Association..}
sample 行に rule を適用し、付与 release メタと gate 判定を返す (副作用なし)。ReleaseContext 未指定時は rule の DefaultReleaseContextRef を使う。
→ 各行 <|"Title","AssignedSource","Decision","Why"|>
Options: "SampleResults" -> {} ({row..}), "ReleaseContext" -> None

### SourceVaultPDFIndexMigrationReport[profile] → Association
登録済み migration rule と human-review 要否を返す。rule 未登録なら <|"Status"->"NoRule",...|>、登録済みなら <|"Status"->"OK","Rule","RequireHumanReviewed"|>。

## native projection index (PDFIndex 非依存。§6.3, §7.6, Phase 5)
build 時に release gate を適用し Permit のみ収録。検索時は request-time gate 再評価 + revocation 照合。IndexKind は "KeywordBigram" (既定, keyword+日本語 bigram)、"KeywordBM25V1" (BM25 LexicalStats)、"DenseV1" (embedding, mean-centering)。

### SourceVaultBuildProjectionIndex[context, opts] → Association | Failure
chunk 群に build-time release gate を適用し Permit のみの endpoint-specific projection index を immutable 保存する (§6.3)。
→ <|"Status","IndexId","Ref","ChunkCount","ExcludedCount","IndexKind"|>
Options: "Chunks" -> None (§7.2 chunk のリスト必須。非リストで Failure["ChunksRequired"]), "IndexId" -> Automatic (既定 context<>"-proj"), "IndexKind" -> "KeywordBigram" ("KeywordBM25V1"/"DenseV1" も可), "EntityDictionary" -> None (BM25 時の entity dict, §4.1.1), "Overwrite" -> False
chunk が参照するキー: ChunkId / NormalizedText | Text / SearchFields / SourceVaultObjectId / SourceRef / Page + gate 用の Tags/PrivacyLevel/State。

### SourceVaultLoadSearchIndex[indexIdOrRef, opts] → Association | Failure
projection index を memory に読み込む。ref が "snapshot:" 始まりならそのまま、それ以外は "SourceVaultProjectionIndex/"<>id で解決。→ <|"Status"->"Loaded","IndexId","ChunkCount","ReleaseContextRef"|>

### SourceVaultUnloadSearchIndex[indexId] → Association
読み込んだ index を memory から解放する。

### SourceVaultReloadSearchIndex[indexId, opts] → Association
index を unload → load し直す。

### SourceVaultListSearchIndexes[] → {indexId..}
memory に読み込み済みの index id を返す。

### SourceVaultSearchIndexStatus[indexId] → Association
index の読込状態を返す。未読込なら <|"IndexId","Loaded"->False|>、読込済なら <|"IndexId","Loaded"->True,"ChunkCount","ReleaseContextRef","IndexKind"|>。

## Mining primer index (§6.1/6.2)
mining サマリー由来の低コスト探索。item は summary レベル。結果は EvidenceKind="SummaryPrimer" で回答根拠にしない。

### SourceVaultBuildPrimerIndex[context, opts] → Association | Failure
mining サマリー由来の primer item に build-time release gate を適用し Permit のみの SourceVaultPrimerIndex を immutable 保存する (§6.1)。summary fields を lexical chunk (title/summary/tags/author) に写像し BM25 LexicalStats を build。
→ <|"Status","PrimerId","Ref","ItemCount","ExcludedCount"|>
Options: "Items" -> None (必須。非リストで Failure["ItemsRequired"]), "PrimerId" -> Automatic (既定 context<>"-primer"), "Overwrite" -> False
item のキー: "ObjectURI","SourceVaultObjectId","Title","Summary","Tags","Authors","Signals"(<|"EffectiveImportance"->_|>),"Freshness"("Fresh"|"StalePrimer"),"PrivacyLevel","State"。

### SourceVaultLoadPrimerIndex[primerIdOrRef] → Association | Failure
primer index を memory に読み込む。→ <|"Status"->"Loaded","PrimerId","ItemCount"|>

### SourceVaultPrimerSearch[query, opts] → {Association..} | Failure
primer を BM25(summary/title/tags/authors) + bounded MiningBoost + EffectiveImportance*ImportanceWeight - StalePrimerPenalty で採点し、request-time gate/revocation 後 Permit のみ Score 降順で返す (§6.2)。未ロードなら自動ロード。
→ 各結果 <|"ResultId","SourceVaultObjectId","ObjectURI","Title","Summary","Score","BM25","MiningBoost","ImportanceTerm","FreshnessPenalty","Freshness","EvidenceKind"->"SummaryPrimer","ReleaseDecision","Revoked","RequestTimeGateReevaluated","Why"|>
Options: "ReleaseContext" -> None (必須。非文字列で Failure), "PrimerIndex" -> Automatic (既定 <rc>-primer), "Limit" -> 20, "UseSummaries" -> True (False で Summary を Missing["Hidden"]), "UseMining" -> True, "MaxBoost" -> 0.2 (MiningBoost 上限), "ImportanceWeight" -> 0.1, "StalePrimerPenalty" -> 0.15

## TPO 制約 / 目的別 index / 低遅延 interaction (§16, Phase 7)
TPO = Time/Place/Occasion。場所・イベント・役割・許可話題・回答長・遅延を束ねた制約。

### SourceVaultRegisterTPOProfile[tpoId, spec] → Association
TPOProfile を登録する (§16.2)。spec 必須 "AllowedScope" (TopicTags を含む)。任意 "TopicKeywords","OutOfScopeKeywords","ChannelProfile"(MaxAnswerCharacters 等),"OutOfScopePolicy","ReleaseContextRefs"。

### SourceVaultTPOProfile[tpoId] → Association | Failure
登録済み TPOProfile を返す (未登録 fail-closed)。

### SourceVaultListTPOProfiles[] → {tpoId..}
登録済み TPO id を返す。

### SourceVaultValidateTPOProfile[spec] → Association
TPOProfile spec の必須項目を検査する。

### SourceVaultClassifyQuestionTPO[question, tpoId] → Association
質問が TPO に即すか rule + keyword (LLM 非依存) で分類し QueryScopeDecision を返す (§16.5)。→ Decision: InScope | OutOfScope | NeedsClarification | Blocked。

### SourceVaultEvaluateTPOGate[question, tpoId] → Association
SourceVaultClassifyQuestionTPO の別名。

### SourceVaultBuildPurposeIndex[indexId, tpoId, opts] → Association | Failure
TPO 制約 (許可 topic tags + release context) で chunk を絞り projection index を作る (§16.4)。
Options: "Chunks" (必須) ほか BuildProjectionIndex 系。

### SourceVaultAnswerForInteraction[question, tpoId, opts] → Association
低遅延 cascade で対話応答を作る (§16.10)。TPOGate → PurposeIndex 検索 → 短答 / fallback。回答長は TPO の ChannelProfile に従う。
→ <|"Decision"->Speak|Clarify|Refuse|NoAnswer|RouteToHuman, "AnswerText","EvidenceRefs","WorkflowUsed","ElapsedMs","DeadlineMet","TPOGateDecision"|>
Options: "Index" (必須), "ReleaseContext", "DeadlineMs"

## マルチモーダル event 正規化 / media index (§17.4, §17.10, §17.14, Phase 7b)

### SourceVaultMediaPrivacyDefault[kind] → Real
media kind ごとの既定 PrivacyLevel を返す (§17.13)。raw media は >=1.0。

### SourceVaultAppendMultimodalEvent[event] → Association
MultimodalEvent を正規化し append-only event log に記録する (§17.4)。必須 "SessionID","Kind"。PrivacyLevel 未指定なら kind 既定 (raw media は 1.0)。

### SourceVaultSessionEvents[sessionId, opts] → {event..}
session の MultimodalEvent を時刻順に返す。
Options: "Kind" (kind で絞り込み)

### SourceVaultBuildRealtimeContext[sessionId, opts] → Association
直近 transcript + visual を ObservationEnvelope にまとめる (§17.10)。
Options: "TranscriptWindowSeconds" -> 20, "VisualWindowSeconds" -> 5, "MaxFrames" -> 3

### SourceVaultBuildMediaIndex[sessionId, opts] → Association | Failure
media 由来 (transcript/caption/OCR/summary) を release gate して projection index 化する (§17.14)。raw audio/frame は入れない。
Options: "ReleaseContext" (必須), "IndexId", "Modalities"

## Dense / hybrid retrieval (embedding arm)
lexical(BM25) を精度の主軸、dense を意味的 recall として RRF で融合する。embedder は injectable (既定=決定的 hashing n-gram、実測は NetModel/LM Studio 等を register)。

### $SourceVaultEmbeddingDim
型: Integer, 初期値: 256
既定 (hashing) embedder の次元。実 provider は自身の次元を返してよい。

### SourceVaultRegisterEmbeddingProvider[name, fn] → Association
embedding provider を登録する。fn[{text..}] は数値ベクトルのリストを返す (L2 正規化推奨、次元は全 text で一定)。

### SourceVaultListEmbeddingProviders[] → {name..}
登録済み embedding provider 名のリスト。

### SourceVaultSetEmbeddingProvider[name] → Association | Failure
既定 embedding provider を切り替える。未登録なら Failure["UnknownEmbeddingProvider"]。

### SourceVaultEmbeddingProvider[] → String
現在の既定 embedding provider 名を返す (初期 "HashingNGramV1")。

### SourceVaultEmbedTexts[{text..}] → {vector..}
既定 provider で埋め込みベクトルのリストを返す。

### SourceVaultRegisterHTTPEmbeddingProvider[name, opts] → Association
OpenAI 互換 /v1/embeddings HTTP エンドポイント (LM Studio 等) を叩く embedding provider を登録する。body は ExportByteArray で UTF-8 バイト化し日本語の二重エンコード文字化けを防ぐ・応答は index でソート。手書き provider の encoding/認証 URL ミスを回避する正準ヘルパ。
Options: "URL" -> Automatic (=Global`$embeddingEndpoint), "Model" -> Automatic (=Global`$embeddingModel), "AuthToken" -> Automatic (エンドポイントのベース URL で LM Studio トークンを NBGetLocalLLMAPIKey 自動解決 (FE のみ)｜None｜文字列｜token を返す関数), "Normalize" -> False, "SetActive" -> True, "TimeoutSeconds" -> 60

### SourceVaultHybridSearch[query, opts] → {SearchResult..} | Failure
BM25 index と Dense index を検索し RRF (Reciprocal Rank Fusion) で融合、両 arm とも Permit の結果を FusedScore 降順で返す。dense/hybrid go/no-go の評価入口。
Options: "ReleaseContext" (必須), "BM25Index", "DenseIndex", "Limit" -> 20, "RetrievalDepth" -> 50 (各 arm の取得深さ), "RRFConstant" -> 60

## 検索評価 (held-out eval harness)

### SourceVaultEvaluateSearch[queries, searchFn, opts] → Association
gold query 群で検索品質 (recall@k, MRR) を測る再利用可能ハーネス。queries は {<|"Query","RelevantIds"->{chunkId..}|>..} または {q -> {relIds}..}。searchFn[query] は結果 assoc (ChunkId 付き) または ChunkId 文字列のランク付きリストを返す。
→ <|"NumQueries","RecallAtK"->(k->平均),"MRR","PerQuery"|>
Options: "K" -> {1,3,5,10}, "Limit" -> 10

### SourceVaultIndexSearcher[releaseContext, indexId, opts] → Function
SourceVaultEvaluateSearch 用の searchFn (query を index で引く closure) を返す。
Options: "Limit" -> 20

## SearchResult schema (共通)
native/legacy 検索結果の主なキー: ResultId / ChunkId / Score / RetrievalKind ("KeywordBigram"|"KeywordBM25"|"DenseEmbedding") / ScoreBreakdown / Snippet / EvidenceRef / Citation(<|"Title","Page"|>) / SourceVaultObjectId / ReleaseDecision / Revoked / RequestTimeGateReevaluated / PolicyDigestAtRequest / Why。raw local path は含まない。追加キーは後方互換 (§1.3)。