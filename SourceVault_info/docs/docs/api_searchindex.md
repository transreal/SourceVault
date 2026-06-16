# SourceVault_searchindex API リファレンス

パッケージ: `SourceVault`searchindex`
リポジトリ: https://github.com/transreal/SourceVault_searchindex
依存: [SourceVault_core](https://github.com/transreal/SourceVault_core) (digest / event log / snapshot store)
ロード順: SourceVault.wl → SourceVault_core.wl → SourceVault_searchindex.wl → [SourceVault_servicemanager](https://github.com/transreal/SourceVault_servicemanager)
ロード方法: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_searchindex.wl"]]`

担当範囲: 検索系 local profile registry (§5.3, §7.3) / release context policy 評価 (§6.1-6.3) / 個別 object revocation・tombstone (§6.3.1) / versioned snapshot (§8.3-8.5, §8.10) / PDFIndex legacy adapter (§7.4, §7.4.1) / native projection index (§6.3, §7.6) / TPO 制約・目的別 index・低遅延 interaction (§16) / マルチモーダル event 正規化・media index (§17.4, §17.10, §17.14) / SurveyCorpus・SurveyIngestPlan (§16.3, §16.7)

## プロファイル registry (§5.3, §7.3)

### SourceVaultRegisterReleaseContext[name, spec] → Association|Failure
release context を登録する。spec 必須: `"MaxPrivacyLevel"` (_Real)。省略した boolean フィールドは安全側 False で補完する。登録時に自動補完されるデフォルト: `"RequiredTags"->{}`, `"DenyTags"->{}`, `"RequireCitation"->True`, `"AllowAnswerGeneration"->False`, `"AllowRawPageImage"->False`, `"AllowDownloadOriginal"->False`。任意 spec キー: `"ReleaseContextTag"`, `"Sink"`, `"DisplayName"`, `"DefaultLatencyProfile"`。
→ `<|"Status"->"OK", "Kind"->"ReleaseContext", "Name"->name|>`

### SourceVaultReleaseContextSpec[name] → Association|Failure
登録済み release context spec を返す。未登録なら `Failure["UnregisteredProfile", ...]`。

### SourceVaultListReleaseContexts[] → {String...}
登録済み release context 名のリストを返す。

### SourceVaultRegisterSearchIndexProfile[name, spec] → Association
search index profile を登録する。spec の内容は任意。

### SourceVaultRegisterPDFIndexProfile[name, spec] → Association
PDFIndex profile を登録する。`"CollectionRoot"` を持たせると `SourceVaultSearch` が collection を自動解決する。

### SourceVaultRegisterSearchBackend[name, spec] → Association|Failure
embedding / keyword backend を登録する。spec 必須: `"Kind"` (String)。

### SourceVaultRegisterOCRBackend[name, spec] → Association
OCR backend を登録する。spec の内容は任意。

### SourceVaultResolveSearchIndexProfile[name] → Association|Failure
search index profile を解決する。未登録なら fail-closed (Failure)。

### SourceVaultResolvePDFIndexProfile[name] → Association|Failure
PDFIndex profile を解決する。未登録なら fail-closed。

### SourceVaultResolveSearchBackend[name] → Association|Failure
search backend を解決する。未登録なら fail-closed。

### SourceVaultResolveOCRBackend[name] → Association|Failure
OCR backend を解決する。未登録なら fail-closed。

### SourceVaultListProfiles[kind] → {String...}
指定 kind の登録名を返す。kind: `"ReleaseContext"` / `"SearchIndexProfile"` / `"PDFIndexProfile"` / `"SearchBackend"` / `"OCRBackend"`。

### SourceVaultListProfiles[] → Association
全 kind の登録名 summary `<|kind -> {names...}, ...|>` を返す。

### SourceVaultClearRegistry[kind] → Association
指定 kind の registry を消去する (test / 再 init 用)。→ `<|"Status"->"OK", "Kind"->kind|>`

### SourceVaultClearRegistry[] → Association
全 registry を消去する。→ `<|"Status"->"OK", "Cleared"->"All"|>`

## release policy 評価 (§6.1-6.3)

### SourceVaultEvaluateReleasePolicy[source, contextName] → Association|Failure
source (object/chunk の Association) が release context で公開可能か評価する。判定条件: PrivacyLevel <= MaxPrivacyLevel かつ RequiredTags ⊆ Tags かつ Tags ∩ DenyTags = {} かつ State ∈ {Approved, Published, Released} かつ NotExpired (ValidFrom/ValidUntil を Now と比較)。contextName 未登録なら fail-closed (Failure)。
→ `<|"Decision"->"Permit"|"Deny"|"NeedsReview", "Why"->{String...}, "PolicyDigest"->..., "Context"->contextName|>`
例: `SourceVaultEvaluateReleasePolicy[<|"PrivacyLevel"->0.3, "Tags"->{"public"}, "State"->"Published"|>, "MyRC"]`

## 個別 object revocation / tombstone (§6.3.1)

### SourceVaultRevokeObject[objectId, opts]
ObjectRevoked event を append-only event log に記録する。
→ event log append 結果
Options: `"Reason"->""`, `"ObjectSnapshotRef"->All` (All で全 snapshot 対象), `"EffectiveAtUTC"->Automatic` (Automatic なら CreatedAtUTC に委ねる), `"State"->"Revoked"` ("Revoked"|"Archived"|"Deleted")

### SourceVaultObjectRevocationStatus[objectId] → Association
object の revocation 状態を返す。内部で `SourceVaultBuildRevocationSet` を呼ぶ。
→ revoked 時: `<|"Revoked"->True, "State"->..., "Reason"->..., "EffectiveAtUTC"->..., "Epoch"->_Integer|>`
→ 非 revoked 時: `<|"Revoked"->False, "State"->Missing["NotRevoked"], "Epoch"->_Integer|>`

### SourceVaultBuildRevocationSet[] → Association
revocation 系 event (ObjectRevoked / ObjectStateChanged / RevocationTombstoneCompacted) を CreatedAtUTC 昇順で replay して HotRevocationSet を構築する。Epoch は revocation 系 event 数 (high-water mark, 単調増加, §6.3.1-4)。
→ `<|"HotRevocationSet"-><|objectId-><|"State"->..., "Reason"->..., "EffectiveAtUTC"->..., "ObjectSnapshotRef"->...|>...|>, "Epoch"->_Integer, "BuiltAtUTC"->...|>`

### SourceVaultRevocationEpoch[] → Integer
現在の revocation epoch (high-water mark) を返す。

### SourceVaultCompactRevocationTombstone[objectId, opts]
tombstone を圧縮する (§6.3.1-9)。RevocationTombstoneCompacted event を記録する。呼び出し側は全 active projection からの除外を事前に保証すること。
→ event log append 結果
Options: `"Reason"->"compacted"`

## versioned snapshot (§8.3-8.5)

### SourceVaultRegisterRetrievalWorkflowKind[kind, spec] → Association
retrieval workflow kind を登録する。組み込み kind: `DirectIndexAnswer`, `KeywordFTS`, `VectorRAG`, `HybridRAG`, `AgenticKeywordSearch`, `DirectCorpusInteraction`, `Cascade`, `ManualReviewDraft`。
→ `<|"Status"->"OK", "Kind"->kind|>`

### SourceVaultListRetrievalWorkflowKinds[] → {String...}
登録済み (組み込み + カスタム) workflow kind の Union を返す。

### SourceVaultSaveRetrievalWorkflowSnapshot[name, spec, opts]
WorkflowSnapshot を immutable 保存する (§8.3)。spec 必須: `"WorkflowKind"` (String、登録済み kind でなければ Failure)。credential / 実 path / IP は含めず profile ref のみ。
→ `<|"Status"->..., "Ref"->..., "Digest"->..., ...|>` または Failure
Options: `"Alias"->None`

### SourceVaultLoadRetrievalWorkflowSnapshot[ref] → Association|Failure
WorkflowSnapshot を読む。

### SourceVaultFreezeCorpusSnapshot[corpusId, opts]
検索対象集合を immutable CorpusSnapshot に固定する (§8.4)。
→ `<|"Status"->..., "Ref"->..., "Digest"->..., ...|>` または Failure
Options: `"Items"->None` (必須、`{<|"SourceVaultObjectId"->..., "ContentHash"->..., ...|>...}`), `"ReleaseContextRef"->None`, `"Version"->Automatic` (Automatic→"auto"), `"Alias"->None`

### SourceVaultCorpusSnapshotInfo[ref] → Association|Failure
CorpusSnapshot の概要を返す。
→ `<|"CorpusId"->..., "ItemCount"->_Integer, "ReleaseContextRef"->..., "Digest"->...|>`

### SourceVaultDiffCorpusSnapshots[aRef, bRef] → Association|Failure
二つの CorpusSnapshot の item 差分を返す。item の同一性は `"SourceVaultObjectId"` → `"ContentHash"` の順で判定。
→ `<|"Added"->{...}, "Removed"->{...}, "Common"->_Integer|>`

### SourceVaultBuildIndexSnapshot[indexId, corpusRef, workflowRef, opts]
IndexSnapshot を作る (§8.5)。corpusRef / workflowRef が実在しなければ fail-closed。
→ `<|"Status"->..., "Ref"->..., "Digest"->..., ...|>` または Failure
Options: `"Artifacts"-><||>`, `"IndexKinds"->{"KeywordFTS"}`, `"Version"->Automatic`, `"Alias"->None`

### SourceVaultIndexSnapshotInfo[ref] → Association|Failure
IndexSnapshot の概要を返す。
→ `<|"IndexId"->..., "IndexKinds"->..., "CorpusSnapshotRef"->..., "WorkflowSnapshotRef"->..., "Digest"->...|>`

### SourceVaultValidateIndexSnapshot[ref] → Association|Failure
IndexSnapshot の digest と corpus/workflow ref の解決可能性を検証する。
→ `<|"Status"->"Valid"|"Invalid", "DigestValid"->_, "CorpusResolvable"->_, "WorkflowResolvable"->_, "Ref"->ref|>`

## PDFIndex legacy adapter (§7.4, §7.4.1)

### $SourceVaultPDFLegacySearchFunction
型: Function|Symbol, 初期値: Automatic
legacy 検索関数の override。Automatic で `PDFIndex`pdfSearch` を使う。差し替える場合 fn[query, n, collection] が pdfSearch 互換の Dataset または Association リストを返すこと。test 差し替え・PDFIndex 非依存環境用。

### SourceVaultPDFIndexLegacySearch[query, opts]
legacy PDFIndex を呼び正規化前の生結果リスト (Association のリスト) を返す。pdfAskLLM は呼ばず Notebook も書かない。`$SourceVaultPDFLegacySearchFunction` が Automatic かつ `PDFIndex`pdfSearch` が未定義なら Failure["PDFIndexUnavailable", ...]。
→ {Association...} または Failure
Options: `"Collection"->Automatic`, `"Limit"->20`

### SourceVaultPDFIndexLegacyResultToSearchResult[row, opts] → Association
legacy 1 行 (Association) を SearchResult schema に正規化する。raw local path は含まない。
→ `<|"ResultId"->"res:"<>uuid, "ChunkId"->..., "Score"->_Real, "ScoreBreakdown"-><|"Embedding"->Missing[...], "Keyword"->Missing[...]|>, "Snippet"->..., "EvidenceRef"->"evid:"<>..., "Citation"-><|"Title"->..., "Page"->..., "DocId"->...|>, "LegacyTags"->{...}|>`

### SourceVaultRegisterPDFIndexMigrationRule[profile, rule] → Association
legacy privacy flag から release context への移行 rule を登録する (§7.4.1)。rule 未登録なら projection は空になる (fail-closed §7.4.1-4)。
rule キー: `"AssignReleaseContexts"->{...}`, `"AssignTags"->{...}`, `"AssignPrivacyLevel"->_Real`, `"AssignState"->"Published"`, `"RequireHumanReviewed"->True`, `"AssignValidFrom"->...`, `"AssignValidUntil"->...`
→ `<|"Status"->"OK", "Profile"->profile|>`

### SourceVaultPreviewPDFIndexMigration[profile, opts]
sample 行に rule を適用し付与 release メタと gate 判定を返す (副作用なし)。
→ `{<|"Title"->..., "AssignedSource"->..., "Decision"->..., "Why"->{...}|>...}`
Options: `"SampleResults"->{}`、`"ReleaseContext"->None` (None なら rule の `"DefaultReleaseContextRef"` を使う)

### SourceVaultPDFIndexMigrationReport[profile] → Association
登録済み migration rule と human-review 要否を返す。rule 未登録時: `<|"Status"->"NoRule", "Profile"->profile, "Note"->...|>`。登録時: `<|"Status"->"OK", "Profile"->profile, "Rule"->..., "RequireHumanReviewed"->_|>`

### SourceVaultSearch[query, opts]
release context gate 付きで検索し SearchResult のリストを返す (§7.4)。`"ReleaseContext"` 未指定は fail-closed。各結果に request-time release gate を再評価し Permit のみ返す。raw local path は返さない。`"Index"` 指定時は native projection index を使い PDFIndex を呼ばない。
→ {Association...} または Failure
Options: `"ReleaseContext"->None` (必須), `"PDFIndexProfile"->None` (指定時に CollectionRoot を自動解決), `"Collection"->Automatic`, `"Limit"->20`, `"Index"->None` (indexId 指定で native 検索)
例: `SourceVaultSearch["機械学習", "ReleaseContext"->"PublicRC", "Index"->"corpus-proj"]`

## native projection index (§6.3, §7.6)

### SourceVaultBuildProjectionIndex[contextName, opts]
chunk 群に build-time release gate を適用し Permit のみの KeywordBigram projection index を作る (§6.3)。embedding backend 非依存。除外 chunk は Permit でない chunk の数。
→ `<|"Status"->"OK", "IndexId"->..., "Ref"->..., "ChunkCount"->_Integer, "ExcludedCount"->_Integer|>` または Failure
Options: `"Chunks"->None` (必須、§7.2 chunk Association のリスト), `"IndexId"->Automatic` (既定: contextName<>"-proj")

chunk Association の必須/推奨 key: `"ChunkId"` (String), `"Text"` または `"NormalizedText"` (String), `"PrivacyLevel"` (_Real), `"Tags"` ({String...}), `"State"` (String), `"SourceVaultObjectId"` (revocation 照合用), `"SourceRef"-><|"Title"->...|>`, `"Page"->...`, `"ValidFrom"` / `"ValidUntil"` (DateObject|String、省略時は期限なし扱い)

### SourceVaultLoadSearchIndex[indexIdOrRef, opts] → Association|Failure
projection index を memory に読み込む。`"snapshot:..."` 形式の ref または indexId を受け付ける。
→ `<|"Status"->"Loaded", "IndexId"->..., "ChunkCount"->_Integer, "ReleaseContextRef"->...|>`

### SourceVaultUnloadSearchIndex[indexId] → Association
読み込んだ index を memory から解放する。→ `<|"Status"->"Unloaded", "IndexId"->indexId|>`

### SourceVaultReloadSearchIndex[indexId, opts] → Association|Failure
index を読み直す (Unload → Load)。

### SourceVaultSearchIndexStatus[indexId] → Association
index の読込状態を返す。
→ loaded: `<|"IndexId"->..., "Loaded"->True, "ChunkCount"->_Integer, "ReleaseContextRef"->..., "IndexKind"->...|>`
→ not loaded: `<|"IndexId"->..., "Loaded"->False|>`

### SourceVaultListSearchIndexes[] → {String...}
memory に読み込み済みの index id を返す。

## TPO 制約 / 目的別 index / 低遅延 interaction (§16)

### SourceVaultRegisterTPOProfile[tpoId, spec] → Association|Failure
TPOProfile (場所/イベント/役割/許可話題/回答長/遅延) を登録する (§16.2)。spec 必須: `"AllowedScope"` (Association、`"TopicTags"` キー必須)。
省略時の既定: `"TopicKeywords"-><||>` (topic名→キーワードリストの Association), `"OutOfScopeKeywords"->{}`, `"ChannelProfile"-><|"MaxAnswerCharacters"->120, "MaxAnswerSentences"->2|>`, `"OutOfScopePolicy"-><||>`
任意 spec キー: `"AllowedScope"-><|"TopicTags"->{...}, "ReleaseContextRefs"->{...}|>`, `"ReleaseContextRefs"` (AllowedScope 外にも置ける), `"TopicKeywords"`, `"OutOfScopeKeywords"`, `"ChannelProfile"`, `"OutOfScopePolicy"`

### SourceVaultTPOProfile[tpoId] → Association|Failure
登録済み TPOProfile を返す。未登録なら `Failure["UnregisteredTPOProfile", <|"TPOId"->tpoId|>]`。

### SourceVaultListTPOProfiles[] → {String...}
登録済み TPO id を返す。

### SourceVaultValidateTPOProfile[spec] → Association
TPOProfile spec の必須項目 (`"AllowedScope"` と `"AllowedScope"."TopicTags"`) を検査する。
→ `<|"Status"->"OK"|"Invalid", "Issues"->{String...}|>`

### SourceVaultClassifyQuestionTPO[question, tpoId] → Association|Failure
質問が TPO に即すか分類し QueryScopeDecision を返す (§16.5)。rule + keyword ベース (LLM 非依存)。OutOfScopeKeywords に一致→OutOfScope、TopicKeywords に一致→InScope、いずれも不一致→NeedsClarification。
→ `<|"ObjectClass"->"SourceVaultQueryScopeDecision", "Decision"->"InScope"|"OutOfScope"|"NeedsClarification"|"Blocked", "TPOProfileRef"->tpoId, "MatchedTopicTags"->{...}, "ReleaseContextRefs"->{...}, "Reason"->..., "Confidence"->_Real|>`

### SourceVaultEvaluateTPOGate[question, tpoId] → Association|Failure
`SourceVaultClassifyQuestionTPO` の別名。

### SourceVaultBuildPurposeIndex[indexId, tpoId, opts]
TPO 制約 (AllowedScope.TopicTags と Tags の交差) で chunk を絞り `SourceVaultBuildProjectionIndex` を呼ぶ (§16.4)。release context は TPO の `AllowedScope.ReleaseContextRefs` (または `ReleaseContextRefs`) の先頭要素を自動解決。
→ `SourceVaultBuildProjectionIndex` と同形の結果 または Failure
Options: `"Chunks"->None` (必須), `"ReleaseContext"->Automatic` (Automatic で TPO から解決)

### SourceVaultAnswerForInteraction[question, tpoId, opts]
低遅延 cascade で対話応答を作る (§16.10)。TPOGate → PurposeIndex 検索 → 短答 / fallback。回答長は TPO の `ChannelProfile.MaxAnswerCharacters` で切り詰める。Decision: `Speak` (結果あり) / `Clarify` (NeedsClarification) / `Refuse` (OutOfScope|Blocked) / `NoAnswer` (結果なし or 超過)。
→ `<|"Decision"->"Speak"|"Clarify"|"Refuse"|"NoAnswer"|"RouteToHuman", "AnswerText"->..., "EvidenceRefs"->{...}, "WorkflowUsed"->..., "ElapsedMs"->_Integer, "DeadlineMet"->True|False, "TPOGateDecision"->...|>`
Options: `"Index"->None` (必須、事前 build した indexId), `"ReleaseContext"->Automatic`, `"DeadlineMs"->3000`
例: `SourceVaultAnswerForInteraction["量子コンピュータとは", "venue-TPO", "Index"->"venue-proj", "DeadlineMs"->2000]`

## マルチモーダル event 正規化 / media index (§17.4, §17.10, §17.14)

### SourceVaultMediaPrivacyDefault[kind] → Real
media kind ごとの既定 PrivacyLevel を返す (§17.13)。AudioSegment/CameraFrame/ScreenSnapshot→1.0、ASRTranscript→0.8、UserQuestion→0.7、SystemSummary/ResponseDraft/VisualCaption/OCR/FAQCandidate/RedactedTranscript→0.5、その他→1.0。

### SourceVaultAppendMultimodalEvent[event] → Association|Failure
MultimodalEvent を正規化し event log に記録する (§17.4)。event 必須: `"SessionID"` (String), `"Kind"` (String)。PrivacyLevel 未指定なら kind 既定を自動設定。
→ event log append 結果 または `Failure["BadMultimodalEvent", ...]`

### SourceVaultSessionEvents[sessionId, opts]
session の MultimodalEvent を CreatedAtUTC 昇順で返す。
→ {Association...}
Options: `"Kind"->All` (All で全 kind、String 指定で Kind 絞り込み)

### SourceVaultBuildRealtimeContext[sessionId, opts]
直近 transcript + visual を ObservationEnvelope にまとめる (§17.10)。ASRTranscript を最大 8 件、VisualCaption/OCR/CameraFrame/ScreenSnapshot を MaxFrames 件取る。
→ `<|"ObjectClass"->"SourceVaultObservationEnvelope", "EnvelopeID"->"obs:"<>uuid, "SessionID"->..., "TranscriptText"->..., "TranscriptEvents"->{...}, "VisualEvents"->{...}, "UserQuestion"->..., "CreatedAtUTC"->...|>`
Options: `"TranscriptWindowSeconds"->20`, `"VisualWindowSeconds"->5`, `"MaxFrames"->3`

### SourceVaultBuildMediaIndex[sessionId, opts]
media 由来 (transcript/caption/OCR/summary) を release gate して projection index 化する (§17.14)。raw audio/frame は入れない (`$derivedMediaKinds`: ASRTranscript/VisualCaption/OCR/SystemSummary/FAQCandidate/RedactedTranscript)。内部で `SourceVaultBuildProjectionIndex` を呼ぶ。
→ `SourceVaultBuildProjectionIndex` と同形の結果 または Failure
Options: `"ReleaseContext"->None` (必須), `"IndexId"->Automatic` (既定: sessionId<>"-media"), `"Modalities"->{"ASRTranscript","VisualCaption","OCR","SystemSummary"}` (raw kind は `$derivedMediaKinds` との交差で自動除外)

## SurveyCorpus / SurveyIngestPlan (§16.3, §16.7)

これらは `SourceVault`` コンテキストで定義される。フル修飾名は `SourceVault`SourceVaultXxx`。

### SourceVault`SourceVaultCreateSurveyIngestPlan[surveyId, spec, opts]
SurveyIngestPlan を immutable snapshot として保存する。spec 必須: `"SourceQueries"` (List), `"IngestPolicy"` (Association)。
→ `<|"Status"->"OK", "ObjectRef"->..., "SnapshotRef"->..., "Digest"->..., "SurveyId"->..., "SurveyVersion"->..., "Warnings"->{}|>` または Failure
Options: `"SurveyVersion"->Automatic`

### SourceVault`SourceVaultIngestSurveyResult[planRef, source] → Association|Failure
planRef の IngestPolicy に従い source item を検証してイベント記録する (fail-closed)。RequireProvenance / RequireReleaseContext / MaxPrivacyLevel 超過で Failure。Content (String|ByteArray) が BlobRef なしの場合 `SourceVaultCommitBlob` を自動呼び出し。
source キー: `"Content"` (String/ByteArray) または `"BlobRef"`, `"ReleaseContextRefs"`, `"PrivacyLevel"` (_Real), `"ProvenanceRef"`, `"TopicTags"`, `"Title"`, `"StalenessClass"`, `"ValidFrom"`, `"ValidUntil"`, `"ReviewState"` (省略時は `IngestPolicy.DefaultReviewState`、既定 `"NeedsHumanReview"`)
→ `<|"Status"->"OK", "ItemRef"->"svitem:"<>uuid, "BlobRef"->..., "ReviewState"->..., "Warnings"->{}|>`

### SourceVault`SourceVaultReviewSurveyItem[itemRef, decision] → Association
survey item にレビュー判定を記録する (SurveyItemReviewed event)。decision 例: `"HumanReviewed"`, `"Rejected"`。
→ `<|"Status"->"OK", "ItemRef"->..., "ReviewState"->decision|>`

### SourceVault`SourceVaultMarkSurveyItemStale[itemRef, reason] → Association
survey item に stale フラグを立てる (SurveyItemStale event)。
→ `<|"Status"->"OK", "ItemRef"->..., "Stale"->True|>`

### SourceVault`SourceVaultBuildSurveyCorpus[surveyId] → Association
event replay から survey item の現在状態を再構築する (副作用なし、snapshot 化しない)。ReviewState は最新の SurveyItemReviewed event で上書き。Stale フラグは SurveyItemStale event の存在で判定。
→ `<|"Status"->"OK", "ObjectClass"->"SourceVaultSurveyCorpus", "SurveyId"->..., "Items"->{...}, "ItemCount"->_Integer, "Reviewed"->_Integer, "Stale"->_Integer|>`

### SourceVault`SourceVaultFreezeSurveyCorpus[corpusId, opts]
SurveyCorpus を immutable snapshot として固定する。Items 省略時は SurveyId から event replay で自動取得。
→ `<|"Status"->"OK", "ObjectRef"->..., "SnapshotRef"->..., "Digest"->..., "ItemCount"->_Integer, "Warnings"->{}|>` または Failure
Options: `"SurveyId"->Automatic` (Items 省略時に必須), `"Items"->Automatic` (明示指定で replay 省略可), `"Version"->Automatic`, `"PlanRef"->None`

### SourceVault`SourceVaultSurveyCorpusStatus[corpusId] → Association|Failure
SurveyCorpus の概要を snapshot store から読んで返す。

## PromptSnapshot (§8.10)

### SourceVault`SourceVaultSavePromptSnapshot[name, prompt, metadata]
prompt を code に埋め込まず immutable snapshot 化する (§8.10)。ObjectClass: `"PromptSnapshot"`、InterfaceVersion: `"SVPrompt/1"`。
metadata 任意キー: `"Alias"->None` など。
→ `SourceVaultSaveImmutableSnapshot` と同形の結果

### SourceVault`SourceVaultLoadPromptSnapshot[ref] → Association|Failure
PromptSnapshot を読む。

## 依存・関連パッケージ

- [SourceVault_core](https://github.com/transreal/SourceVault_core): `SourceVaultAppendEvent`, `SourceVaultTransactionLog`, `SourceVaultSaveImmutableSnapshot`, `SourceVaultLoadImmutableSnapshot`, `SourceVaultVerifyImmutableSnapshot`, `SourceVaultSnapshotDigest`, `SourceVaultCommitBlob`
- [PDFIndex](https://github.com/transreal/PDFIndex): legacy adapter のバックエンド (optional、`$SourceVaultPDFLegacySearchFunction` で差し替え可)
- 後続ロード: [SourceVault_servicemanager](https://github.com/transreal/SourceVault_servicemanager)