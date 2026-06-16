# SourceVault_searchindex API リファレンス

パッケージ: `SourceVault`
依存: [SourceVault_core](https://github.com/transreal/SourceVault_core) (digest / event log / snapshot store)
ロード順: SourceVault.wl → SourceVault_core.wl → **SourceVault_searchindex.wl** → SourceVault_servicemanager.wl
エンコード: UTF-8。`Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_searchindex.wl"]]` でロードする。

## プロファイル Registry (§5.3, §7.3)

### SourceVaultRegisterReleaseContext[name, spec]
release context を登録する。spec は Association。`"MaxPrivacyLevel"` (_Real) が必須。不足 key は安全側 default で補う。
→ `<|"Status"->"OK", "Kind"->"ReleaseContext", "Name"->name|>` | Failure
spec 必須: `"MaxPrivacyLevel"` (_Real)
spec 任意: `"RequiredTags"`->`{}`, `"DenyTags"`->`{}`, `"RequireCitation"`->True, `"AllowAnswerGeneration"`->False, `"AllowRawPageImage"`->False, `"AllowDownloadOriginal"`->False, `"ReleaseContextTag"`, `"Sink"`, `"DisplayName"`, `"DefaultLatencyProfile"`
例: `SourceVaultRegisterReleaseContext["pub", <|"MaxPrivacyLevel"->0.5, "RequiredTags"->{"approved"}|>]`

### SourceVaultReleaseContextSpec[name] → Association | Failure
登録済み release context の spec を返す。未登録なら Failure["UnregisteredProfile", ...]。

### SourceVaultListReleaseContexts[] → {_String...}
登録済み release context 名のリストを返す。

### SourceVaultRegisterSearchIndexProfile[name, spec] → Association
search index profile を登録する。spec の schema は任意 Association。

### SourceVaultRegisterPDFIndexProfile[name, spec] → Association
PDFIndex profile を登録する。

### SourceVaultRegisterSearchBackend[name, spec] → Association | Failure
embedding / keyword backend を登録する。spec に `"Kind"` (_String) が必須。

### SourceVaultRegisterOCRBackend[name, spec] → Association
OCR backend を登録する。

### SourceVaultResolveSearchIndexProfile[name] → Association | Failure
search index profile を fail-closed で解決する。未登録なら Failure。

### SourceVaultResolvePDFIndexProfile[name] → Association | Failure
PDFIndex profile を fail-closed で解決する。

### SourceVaultResolveSearchBackend[name] → Association | Failure
search backend を fail-closed で解決する。

### SourceVaultResolveOCRBackend[name] → Association | Failure
OCR backend を fail-closed で解決する。

### SourceVaultListProfiles[kind] → {_String...}
指定 kind の登録名リストを返す。kind は `"ReleaseContext"` | `"SearchIndexProfile"` | `"PDFIndexProfile"` | `"SearchBackend"` | `"OCRBackend"`。

### SourceVaultListProfiles[] → Association
全 kind の登録名 summary を返す。`<|kind -> {names...}, ...|>`。

### SourceVaultClearRegistry[kind] → Association
指定 kind の registry を消去する (test / 再 init 用)。

### SourceVaultClearRegistry[] → Association
全 kind の registry を消去する。

## Release Policy 評価 (§6.1-6.3)

### SourceVaultEvaluateReleasePolicy[source, contextName] → Association | Failure
source (chunk / object の Association) が contextName の release context で公開可能か評価する。
判定条件: `PrivacyLevel <= MaxPrivacyLevel` かつ `RequiredTags ⊆ Tags` かつ `Tags ∩ DenyTags = {}` かつ `State ∈ {Approved, Published, Released}` かつ NotExpired。
→ `<|"Decision"->"Permit"|"Deny"|"NeedsReview", "Why"->{...}, "PolicyDigest"->_, "Context"->contextName|>`
未登録 context なら Failure を返す (fail-closed)。

## Object Revocation / Tombstone (§6.3.1)

### SourceVaultRevokeObject[objectId, opts]
ObjectRevoked event を append-only event log に記録する。
→ event log append の戻り値
Options: `"Reason"`->`""` (理由文字列), `"ObjectSnapshotRef"`->All (All で全 snapshot 対象), `"EffectiveAtUTC"`->Automatic (Automatic は CreatedAtUTC に委ねる), `"State"`->`"Revoked"` (`"Revoked"` | `"Archived"` | `"Deleted"`)

### SourceVaultObjectRevocationStatus[objectId] → Association
objectId の revocation 状態を返す。
revoked 時: `<|"Revoked"->True, "State"->_, "Reason"->_, "EffectiveAtUTC"->_, "Epoch"->_Integer|>`
非 revoked 時: `<|"Revoked"->False, "State"->Missing["NotRevoked"], "Epoch"->_Integer|>`

### SourceVaultBuildRevocationSet[] → Association
revocation 系 event (ObjectRevoked / ObjectStateChanged / RevocationTombstoneCompacted) を replay して HotRevocationSet を構築する。
→ `<|"HotRevocationSet"-><|objectId -> info...|>, "Epoch"->_Integer, "BuiltAtUTC"->_String|>`
Epoch は revocation 系 event 数 (high-water mark, §6.3.1-4, 単調増加)。

### SourceVaultRevocationEpoch[] → Integer
現在の revocation epoch (HotRevocationSet の high-water mark) を返す。

### SourceVaultCompactRevocationTombstone[objectId, opts]
RevocationTombstoneCompacted event を記録し tombstone を圧縮する (§6.3.1-9)。呼び出し側は全 active projection からの除外を保証すること。
→ event log append の戻り値
Options: `"Reason"`->`"compacted"`

## Versioned Snapshot (§8.3-8.5, Phase 4)

### SourceVaultRegisterRetrievalWorkflowKind[kind, spec] → Association
retrieval workflow kind を登録する。
kind 例: `"DirectIndexAnswer"` | `"KeywordFTS"` | `"VectorRAG"` | `"HybridRAG"` | `"AgenticKeywordSearch"` | `"DirectCorpusInteraction"` | `"Cascade"` | `"ManualReviewDraft"`

### SourceVaultListRetrievalWorkflowKinds[] → {_String...}
組み込み + 登録済み workflow kind の Union を返す。

### SourceVaultSaveRetrievalWorkflowSnapshot[name, spec, opts]
WorkflowSnapshot を immutable 保存する (§8.3)。spec に `"WorkflowKind"` (_String) が必須。credential / 実 path / IP を spec に含めてはならない (profile ref のみ)。
→ `<|"Status"->_, "Ref"->_, "Digest"->_, ...|>` | Failure
Options: `"Alias"`->None

### SourceVaultLoadRetrievalWorkflowSnapshot[ref] → Association | Failure
WorkflowSnapshot を ref で読み込む。

### SourceVaultFreezeCorpusSnapshot[corpusId, opts]
検索対象集合を immutable CorpusSnapshot に固定する (§8.4)。
→ `<|"Status"->_, "Ref"->_, "Digest"->_, ...|>` | Failure
Options: `"Items"`->None (必須; `{<|"SourceVaultObjectId"->_, "ContentHash"->_, ...|>...}`), `"ReleaseContextRef"`->None, `"Version"`->Automatic, `"Alias"`->None

### SourceVaultCorpusSnapshotInfo[ref] → Association | Failure
CorpusSnapshot の概要を返す。
→ `<|"CorpusId"->_, "ItemCount"->_Integer, "ReleaseContextRef"->_, "Digest"->_|>`

### SourceVaultDiffCorpusSnapshots[aRef, bRef] → Association | Failure
2 つの CorpusSnapshot の item 差分を返す。
→ `<|"Added"->{keys...}, "Removed"->{keys...}, "Common"->_Integer|>`
item key は `"SourceVaultObjectId"` または `"ContentHash"` で識別する。

### SourceVaultBuildIndexSnapshot[indexId, corpusRef, workflowRef, opts]
IndexSnapshot を作る (§8.5)。corpusRef / workflowRef が実在しない場合は fail-closed。
→ `<|"Status"->_, "Ref"->_, "Digest"->_, ...|>` | Failure
Options: `"Artifacts"`->`<||>`, `"IndexKinds"`->`{"KeywordFTS"}`, `"Version"`->Automatic, `"Alias"`->None

### SourceVaultIndexSnapshotInfo[ref] → Association | Failure
IndexSnapshot の概要を返す。
→ `<|"IndexId"->_, "IndexKinds"->_, "CorpusSnapshotRef"->_, "WorkflowSnapshotRef"->_, "Digest"->_|>`

### SourceVaultValidateIndexSnapshot[ref] → Association | Failure
IndexSnapshot の digest 整合性と corpus / workflow ref の解決可能性を検証する。
→ `<|"Status"->"Valid"|"Invalid", "DigestValid"->_, "CorpusResolvable"->_, "WorkflowResolvable"->_, "Ref"->_|>`

## Prompt Snapshot (§8.10)

### SourceVault`SourceVaultSavePromptSnapshot[name, prompt, metadata] → Association
prompt を immutable snapshot として保存する。metadata に `"Alias"` を含められる。

### SourceVault`SourceVaultLoadPromptSnapshot[ref] → Association | Failure
PromptSnapshot を ref で読み込む。

## PDFIndex Legacy Adapter (§7.4, Phase 3)

### $SourceVaultPDFLegacySearchFunction
型: Function | Automatic, 初期値: Automatic
legacy 検索関数の override。Automatic の場合 `PDFIndex`pdfSearch` を使う。差し替える場合は `fn[query, n, collection]` が pdfSearch 互換の Dataset / 連想リストを返す関数を設定する (test 用)。

### SourceVaultSearch[query, opts]
release context gate 付きで検索し SearchResult のリストを返す (§7.4)。各結果に request-time release gate を再評価し Permit のみ返す。raw local path は返さない。
→ `{<|"ResultId"->_, "ChunkId"->_, "Score"->_, "Snippet"->_, "EvidenceRef"->_, "Citation"->_, "ReleaseDecision"->"Permit", "RequestTimeGateReevaluated"->True, "PolicyDigestAtRequest"->_, "Why"->_|>...}` | Failure
Options: `"ReleaseContext"`->None (必須; 未指定で Failure), `"PDFIndexProfile"`->None, `"Collection"`->Automatic, `"Limit"`->20, `"Index"`->None (native projection index id を指定するとそちらを使う)
例: `SourceVaultSearch["量子計算", "ReleaseContext"->"pub", "Limit"->10]`
例 (native index 使用): `SourceVaultSearch["量子計算", "ReleaseContext"->"pub", "Index"->"pub-proj"]`

### SourceVaultPDFIndexLegacySearch[query, opts]
legacy PDFIndex を呼び、正規化前の生結果リスト (`{Association...}`) を返す。pdfAskLLM は呼ばず Notebook も書かない。
→ `{Association...}` | Failure
Options: `"Collection"`->Automatic, `"Limit"`->20

### SourceVaultPDFIndexLegacyResultToSearchResult[row, opts] → Association
legacy 生行 1 件を SearchResult schema に正規化する。raw path を含まない。

### SourceVaultRegisterPDFIndexMigrationRule[profile, rule] → Association
legacy privacy flag から release context への移行 rule を登録する (§7.4.1)。rule 未登録なら projection は空 (fail-closed)。
rule 例: `<|"AssignReleaseContexts"->{...}, "AssignTags"->{...}, "AssignPrivacyLevel"->0.3, "AssignState"->"Published", "RequireHumanReviewed"->True|>`

### SourceVaultPreviewPDFIndexMigration[profile, opts]
sample 行に migration rule を適用し付与 release メタと gate 判定を返す (副作用なし)。
→ `{<|"Title"->_, "AssignedSource"->_, "Decision"->_, "Why"->_|>...}`
Options: `"SampleResults"`->`{}` (legacy 生行リスト), `"ReleaseContext"`->None

### SourceVaultPDFIndexMigrationReport[profile] → Association
登録済み migration rule と human-review 要否を返す。rule 未登録時は `<|"Status"->"NoRule", ...|>`。

## Native Projection Index (§6.3, §7.6, Phase 5)

### SourceVaultBuildProjectionIndex[contextName, opts]
chunk 群に build-time release gate を適用し Permit のみの projection index を作る (§6.3)。keyword + 日本語 bigram スコア方式 (embedding 非依存)。
→ `<|"Status"->"OK", "IndexId"->_, "Ref"->_, "ChunkCount"->_Integer, "ExcludedCount"->_Integer|>` | Failure
Options: `"Chunks"`->None (必須; §7.2 chunk Association のリスト), `"IndexId"`->Automatic (Automatic で contextName + "-proj")
例: `SourceVaultBuildProjectionIndex["pub", "Chunks"->chunks, "IndexId"->"pub-proj"]`

### SourceVaultLoadSearchIndex[indexIdOrRef, opts] → Association | Failure
projection index を memory に読み込む。ref は `"snapshot:..."` 形式または indexId を受け付ける。
→ `<|"Status"->"Loaded", "IndexId"->_, "ChunkCount"->_, "ReleaseContextRef"->_|>`

### SourceVaultUnloadSearchIndex[indexId] → Association
読み込んだ index を解放する。
→ `<|"Status"->"Unloaded", "IndexId"->_|>`

### SourceVaultReloadSearchIndex[indexId, opts] → Association | Failure
index を Unload → Load し直す。

### SourceVaultSearchIndexStatus[indexId] → Association
index の読込状態 / chunk 数 / context を返す。
ロード済み: `<|"IndexId"->_, "Loaded"->True, "ChunkCount"->_, "ReleaseContextRef"->_, "IndexKind"->_|>`
未ロード: `<|"IndexId"->_, "Loaded"->False|>`

### SourceVaultListSearchIndexes[] → {_String...}
memory に読み込み済みの index id リストを返す。

## TPO 制約 / 目的別 Index / 低遅延 Interaction (§16, Phase 7)

### SourceVaultValidateTPOProfile[spec] → Association
TPOProfile spec の必須項目 (`"AllowedScope"` / `"AllowedScope.TopicTags"`) を検査する。
→ `<|"Status"->"OK"|"Invalid", "Issues"->{...}|>`

### SourceVaultRegisterTPOProfile[tpoId, spec, opts] → Association | Failure
TPOProfile (場所 / イベント / 役割 / 許可話題 / 回答長 / 遅延) を登録する (§16.2)。spec に `"AllowedScope"` (TopicTags を含む Association) が必須。
→ `<|"Status"->"OK", "TPOId"->tpoId|>`
spec 必須: `"AllowedScope"`->`<|"TopicTags"->{...}, ...|>`
spec 任意: `"TopicKeywords"`->`<||>`, `"OutOfScopeKeywords"`->`{}`, `"ChannelProfile"`->`<|"MaxAnswerCharacters"->120, "MaxAnswerSentences"->2|>`, `"OutOfScopePolicy"`->`<||>`, `"ReleaseContextRefs"`

### SourceVaultTPOProfile[tpoId] → Association | Failure
登録済み TPOProfile を返す。未登録なら Failure["UnregisteredTPOProfile", ...]。

### SourceVaultListTPOProfiles[] → {_String...}
登録済み TPO id リストを返す。

### SourceVaultClassifyQuestionTPO[question, tpoId] → Association | Failure
質問が TPO に即すか rule + keyword で分類する (LLM 非依存, §16.5)。
→ `<|"ObjectClass"->"SourceVaultQueryScopeDecision", "Decision"->"InScope"|"OutOfScope"|"NeedsClarification"|"Blocked", "TPOProfileRef"->_, "MatchedTopicTags"->{...}, "ReleaseContextRefs"->{...}, "Reason"->_, "Confidence"->_Real|>`

### SourceVaultEvaluateTPOGate[question, tpoId] → Association | Failure
`SourceVaultClassifyQuestionTPO` の別名。

### SourceVaultBuildPurposeIndex[indexId, tpoId, opts]
TPO 制約 (許可 TopicTags + release context) で chunk を絞り projection index を作る (§16.4)。内部で `SourceVaultBuildProjectionIndex` を呼ぶ。
→ `<|"Status"->"OK", "IndexId"->_, "Ref"->_, "ChunkCount"->_, "ExcludedCount"->_|>` | Failure
Options: `"Chunks"`->None (必須), `"ReleaseContext"`->Automatic (Automatic で TPOProfile の ReleaseContextRefs 先頭を使う)

### SourceVaultAnswerForInteraction[question, tpoId, opts]
低遅延 cascade で対話応答を作る (§16.10)。TPOGate → PurposeIndex 検索 → 短答 / fallback の順。回答長は TPO の ChannelProfile.MaxAnswerCharacters に従う。
→ `<|"Decision"->"Speak"|"Clarify"|"Refuse"|"NoAnswer"|"RouteToHuman", "AnswerText"->_, "EvidenceRefs"->{...}, "WorkflowUsed"->_, "ElapsedMs"->_Integer, "DeadlineMet"->_?(BooleanQ), "TPOGateDecision"->_|>`
Options: `"Index"`->None (必須; native projection index id), `"ReleaseContext"`->Automatic, `"DeadlineMs"`->3000

## マルチモーダル Event 正規化 / Media Index (§17.4, §17.10, §17.14, Phase 7b)

### SourceVaultMediaPrivacyDefault[kind] → Real
media kind ごとの既定 PrivacyLevel を返す (§17.13)。
`"AudioSegment"` | `"CameraFrame"` | `"ScreenSnapshot"` → 1.0 (raw media は必ず 1.0)
`"ASRTranscript"` → 0.8, `"UserQuestion"` → 0.7
`"SystemSummary"` | `"ResponseDraft"` | `"VisualCaption"` | `"OCR"` | `"FAQCandidate"` | `"RedactedTranscript"` → 0.5
その他 → 1.0 (フォールバック)

### SourceVaultAppendMultimodalEvent[event] → Association | Failure
MultimodalEvent を正規化し append-only event log に記録する (§17.4)。
event に `"SessionID"` (_String) と `"Kind"` (_String) が必須。`"PrivacyLevel"` 未指定なら kind 既定値を補う。

### SourceVaultSessionEvents[sessionId, opts]
session の MultimodalEvent を CreatedAtUTC 昇順で返す。
→ `{Association...}`
Options: `"Kind"`->All (All で全 kind。文字列指定で絞り込み)

### SourceVaultBuildRealtimeContext[sessionId, opts]
直近 transcript + visual を ObservationEnvelope にまとめる (§17.10)。
→ `<|"ObjectClass"->"SourceVaultObservationEnvelope", "EnvelopeID"->_, "SessionID"->_, "TranscriptText"->_, "TranscriptEvents"->{...}, "VisualEvents"->{...}, "UserQuestion"->_, "CreatedAtUTC"->_|>`
Options: `"TranscriptWindowSeconds"`->20, `"VisualWindowSeconds"`->5, `"MaxFrames"`->3

### SourceVaultBuildMediaIndex[sessionId, opts]
media 由来 (transcript / caption / OCR / summary) を release gate して projection index 化する (§17.14)。raw audio / frame は入れない (§17.13)。
→ `<|"Status"->"OK", "IndexId"->_, "Ref"->_, "ChunkCount"->_, "ExcludedCount"->_|>` | Failure
Options: `"ReleaseContext"`->None (必須), `"IndexId"`->Automatic (Automatic で sessionId + "-media"), `"Modalities"`->`{"ASRTranscript", "VisualCaption", "OCR", "SystemSummary"}` (raw media kind は自動除外)

## Survey Corpus (§16.3, §16.7)

これらの関数は `SourceVault`` 文脈で定義される。

### SourceVault`SourceVaultCreateSurveyIngestPlan[surveyId, spec, opts]
SurveyIngestPlan を immutable snapshot として保存する。
spec 必須: `"SourceQueries"` (List), `"IngestPolicy"` (Association)
→ `<|"Status"->"OK", "ObjectRef"->_, "SnapshotRef"->_, "Digest"->_, "SurveyId"->_, "SurveyVersion"->_, "Warnings"->{}|>` | Failure
Options: `"SurveyVersion"`->Automatic

### SourceVault`SourceVaultIngestSurveyResult[planRef, source, opts] → Association | Failure
1 件のサーベイ結果を IngestPolicy 経由で取り込む (fail-closed)。
source 任意: `"ProvenanceRef"`, `"ReleaseContextRefs"`, `"PrivacyLevel"`, `"Content"`, `"BlobRef"`, `"TopicTags"`, `"ReviewState"`, `"StalenessClass"`, `"ValidFrom"`, `"ValidUntil"`, `"Title"`
IngestPolicy に `"RequireProvenance"->True` がある場合 `"ProvenanceRef"` が必須。`"RequireReleaseContext"->True` の場合 `"ReleaseContextRefs"` が必須。PrivacyLevel が MaxPrivacyLevel を超えると Failure (fail-closed)。
→ `<|"Status"->"OK", "ItemRef"->_, "BlobRef"->_, "ReviewState"->_, "Warnings"->{}|>`

### SourceVault`SourceVaultReviewSurveyItem[itemRef, decision, opts] → Association
SurveyItemReviewed event を記録する。decision 例: `"HumanReviewed"` | `"Rejected"`。

### SourceVault`SourceVaultMarkSurveyItemStale[itemRef, reason, opts] → Association
SurveyItemStale event を記録する。

### SourceVault`SourceVaultBuildSurveyCorpus[surveyId, opts] → Association
event replay から現在の survey item 状態 (最新 review fold + stale フラグ) を構築する (非 immutable)。
→ `<|"ObjectClass"->"SourceVaultSurveyCorpus", "SurveyId"->_, "Items"->{...}, "ItemCount"->_Integer, "Reviewed"->_Integer, "Stale"->_Integer|>`

### SourceVault`SourceVaultFreezeSurveyCorpus[corpusId, opts]
SurveyCorpus を immutable snapshot に固定する。
→ `<|"Status"->"OK", "ObjectRef"->_, "SnapshotRef"->_, "Digest"->_, "ItemCount"->_Integer, "Warnings"->{}|>` | Failure
Options: `"SurveyId"`->Automatic (Items 未指定時にこの surveyId から event replay), `"Items"`->Automatic, `"Version"`->Automatic, `"PlanRef"`->None

### SourceVault`SourceVaultSurveyCorpusStatus[corpusId, opts] → Association | Failure
CorpusSnapshot (immutable) の概要を返す。ref または corpusId を受け付ける。

## 内部変数 (private; 参照のみ)

### $registries
型: Association, 初期値: `<||>`
全 kind のプロファイルを格納する in-memory registry。`SourceVault`SearchIndexPrivate`` 文脈。直接操作せず `Register*` / `ClearRegistry` を使う。

### $workflowKinds
型: Association, 初期値: `<||>`
登録済み workflow kind spec の in-memory store。`SourceVaultListRetrievalWorkflowKinds` は組み込み kind との Union を返す。

### $loadedProjections
型: Association, 初期値: `<||>`
`SourceVaultLoadSearchIndex` でロードした projection index の in-memory cache。key は indexId。

### $tpoProfiles
型: Association, 初期値: `<||>`
登録済み TPOProfile の in-memory store。

### $pdfMigrationRules
型: Association, 初期値: `<||>`
profile 名 → migration rule の in-memory store。

## Chunk Schema (§7.2) — SourceVaultBuildProjectionIndex の入力形式

chunk は以下のキーを持つ Association。`"NormalizedText"` または `"Text"` が keyword スコアに使われる。

`"ChunkId"` (_String), `"SourceVaultObjectId"` (_String, revocation 照合に使用), `"Text"` (_String), `"NormalizedText"` (_String, 省略時 Text にフォールバック), `"Tags"` (`{_String...}`), `"PrivacyLevel"` (_Real), `"State"` (_String), `"Page"` (任意), `"ValidFrom"` / `"ValidUntil"` (DateObject | ISO 文字列 | Missing, 省略で有効期間なし), `"SourceRef"` (`<|"Title"->_|>` 等)

## SearchResult Schema — SourceVaultSearch の戻り値形式

`"ResultId"` (_String, `"res:"` prefix), `"ChunkId"` (_String), `"Score"` (_Real), `"Snippet"` (_String, KWIC), `"EvidenceRef"` (_String, `"evid:"` prefix), `"Citation"` (`<|"Title"->_, "Page"->_|>`), `"SourceVaultObjectId"` (_String | Missing), `"ReleaseDecision"` (`"Permit"` のみ返る), `"Revoked"` (_?(BooleanQ)), `"RequestTimeGateReevaluated"` (True), `"PolicyDigestAtRequest"` (_String | Missing), `"Why"` (`{_String...}`)

## 設計上の注意

fail-closed 原則: 未登録 profile / context の解決は必ず Failure を返す。`Missing` や `Null` を返してサイレントに続行しない。
raw path 非漏洩: `SourceVaultSearch` / `SourceVaultPDFIndexLegacyResultToSearchResult` は raw local ファイルパスを戻り値に含めない。
request-time gate 再評価: `SourceVaultSearch` (legacy / native 両経路) は返却直前に `SourceVaultEvaluateReleasePolicy` を再実行し Permit のみ返す。build-time gate (projection index 構築時) だけに依存しない。
revocation 照合: native 検索 (`iNativeSearch`) は `SourceVaultBuildRevocationSet` で HotRevocationSet を取得し、`SourceVaultObjectId` が含まれる chunk を Deny に強制する。