# SourceVault API リファレンス

LLM \:5411\:3051 API \:30ea\:30d5\:30a1\:30ec\:30f3\:30b9\:3002\:5916\:90e8 source \:7ba1\:7406\:30d1\:30c3\:30b1\:30fc\:30b8\:3002

## Bootstrap / Configuration

### $SourceVaultVersion
\:578b: String
SourceVault \:30d1\:30c3\:30b1\:30fc\:30b8\:306e\:30d0\:30fc\:30b8\:30e7\:30f3\:6587\:5b57\:5217\:3002

### $SourceVaultRoots
\:578b: Association
\:7269\:7406 root \:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:30de\:30c3\:30d4\:30f3\:30b0\:3002Keys: "PrivateVault" | "CloudMirror" | "Tmp" | "AttachmentMirror" | "ExternalOwned"\:3002PrivateVault \:304c authoritative storage \:3067\:3001cloud LLM / Claude Code CLI \:306b\:306f\:76f4\:63a5\:8aad\:307e\:305b\:306a\:3044\:3002

### $SourceVaultSeedModelRegistry
\:578b: Association
Bootstrap \:6642\:306e fallback model registry\:3002Compiled registry \:304c\:7121\:3044\:5834\:5408\:306e\:707d\:5bb3\:5fa9\:65e7\:7528\:3002

### $SourceVaultCloudRoots
\:578b: List of String
\:30af\:30e9\:30a6\:30c9\:5171\:6709\:30d5\:30a9\:30eb\:30c0\:306e\:30b7\:30f3\:30dc\:30eb\:540d\:30ea\:30b9\:30c8\:3002\:4f8b: {"$packageDirectory", "$dropbox", "$onWork", "$offWork", "$mathematicaWork"}\:3002

### $SourceVaultCloudRootAliases
\:578b: Association, \:521d\:671f\:5024: <||>
\:30af\:30e9\:30a6\:30c9\:30eb\:30fc\:30c8\:30b7\:30f3\:30dc\:30eb\:540d\:304b\:3089\:65e7 PC \:306e\:7d76\:5bfe\:30d1\:30b9\:30ea\:30b9\:30c8\:3078\:306e\:30a8\:30a4\:30ea\:30a2\:30b9\:3002\:4f8b: <|"$onWork" -> {"C:/Users/imai_/Dropbox/On Work"}, ...|>\:3002

### SourceVaultInitialize[opts]
SourceVault \:306e\:7269\:7406 root \:3092\:751f\:6210\:3057\:521d\:671f\:5316\:3059\:308b\:3002
\:2192 Association
Options: "Roots" -> $SourceVaultRoots (override), "Force" -> False (\:518d\:521d\:671f\:5316)

### SourceVaultStatus[sourceRef]
\:6307\:5b9a source / snapshot / \:30d5\:30a1\:30a4\:30eb\:306e\:6982\:8981\:3002\:5f15\:6570\:7121\:3057\:3067 vault \:5168\:4f53\:306e\:6982\:8981\:3002
\:2192 Association

### SourceVaultStatus[]
Vault \:5168\:4f53\:306e\:6982\:8981\:3092\:8fd4\:3059\:3002
\:2192 Association

### SourceVaultList[] \:2192 List of String
Vault \:5185\:306e\:5168 source ID \:30ea\:30b9\:30c8\:3002

### SourceVaultSnapshots[sourceRef] \:2192 List of String
\:6307\:5b9a source \:306e snapshot ID \:30ea\:30b9\:30c8\:3002

## Lookup / Resolve

### SourceVaultResolve[kind, query, opts]
Compiled registry \:304b\:3089 query \:306b match \:3059\:308b entry \:3092\:8fd4\:3059\:3002\:8907\:6570 match \:6642\:306f Availability \:30d5\:30a3\:30eb\:30bf + Class/Freshness \:3067 sort\:3057\:305f\:5148\:982d\:3002
\:2192 Association | Missing["NotFound"]
Options: "Channel" -> "public" ("public" | "private"), "AllowSeed" -> True, "Topic" -> Automatic ("<kind>-registry" \:5c0f\:6587\:5b57\:5316)
\:4f8b: SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]

### SourceVaultLookup[topic, key, opts]
Compiled registry \:304b\:3089 key \:306b\:5bfe\:5fdc\:3059\:308b entry \:3092\:8fd4\:3059\:3002
\:2192 Association | Missing["NotFound"]
Options: "Channel" -> "public", "AllowSeed" -> True

### ClaudeResolveModel[provider, intent]
SourceVaultResolve["Model", ...] \:306e\:4e92\:63db wrapper\:3002\:65e7 WikiDBResolveModel \:306e\:7f6e\:304d\:63db\:3048\:3002
\:2192 Association | Missing["NotFound"]
\:4f8b: ClaudeResolveModel["anthropic", "heavy"]

### SourceVaultListModels[provider] \:2192 List of String
\:6307\:5b9a provider \:306e\:9078\:629e\:53ef\:80fd\:5168\:30e2\:30c7\:30eb ID \:30ea\:30b9\:30c8\:3002Availability \:304c Unavailable \:306e\:30a8\:30f3\:30c8\:30ea\:306f\:9664\:5916\:3002

### SourceVaultListRegistries[opts]
\:767b\:9332\:6e08\:307f registry topic \:3068 channel \:3092\:8fd4\:3059\:3002
\:2192 List
Options: "Channel" -> All ("public" | "private" | All)

### SourceVaultRegistryStatus[topic, opts]
\:6307\:5b9a topic \:306e registry \:72b6\:614b\:3092\:8fd4\:3059\:3002
\:2192 Association (Topic, Channel, CompiledPath, CompiledExists, CompiledCount, SeedPath, SeedExists, SeedCount, LastModified)
Options: "Channel" -> "public"

### SourceVaultCompileRegistry[topic, entries, opts]
Entries (List of Association) \:3092 compiled registry \:306b\:4fdd\:5b58\:3059\:308b\:3002
\:2192 Association (Status, Topic, Channel, Path, Count)
Options: "Channel" -> "public", "Sources" -> {} (\:95a2\:9023 claim/snapshot id), "PolicySource" -> None

### SourceVaultRegisterSeed[topic, entries] \:2192 Association
Seed entries \:3092 seeds/<topic>-seed.json \:306b\:4fdd\:5b58 (bootstrap \:7528)\:3002

## Ingest

### SourceVaultIngest[source, opts]
\:5916\:90e8 source \:3092\:767b\:9332\:3057 raw snapshot \:3092 PrivateVault \:306b\:4fdd\:5b58\:3002Local file / HTTPS URL / arXiv:NNNN.NNNNN[vN] \:3092\:53d7\:7406\:3002
\:2192 Association (Status, SourceId, SnapshotId, ...)
Options:
  Topic -> Automatic | _String
  TrustLevel -> Automatic | "OfficialAPI" | "OfficialDocs" | "PublicWeb" | "LocalFile"
  PrivacyLabel -> Automatic | _Real
  PinVersion -> Automatic | True | False
  Asynchronous -> False (True \:6642\:306f LLMGraphDAGCreate \:7d4c\:7531\:3067 JobId \:3092\:5373\:6642 return)
  EnsureUUID -> Automatic | True | False (.nb \:306b UUID \:81ea\:52d5\:4ed8\:4e0e)

### SourceVaultIngestWait[ingestResult, timeoutSec]
\:975e\:540c\:671f ingest \:306e\:5b8c\:4e86\:3092\:5f85\:3064\:3002\:7b2c\:4e00\:5f15\:6570\:306f Ingest \:7d50\:679c Association \:307e\:305f\:306f SourceId String\:3002
\:2192 Association (Status: Ingested | AlreadyCurrent | RebuiltMetadata | Queued | Timeout, ...)
\:4f8b: timeoutSec \:30c7\:30d5\:30a9\:30eb\:30c8 60\:3002Status: Queued \:6642\:306f snapshot \:5897\:52a0\:3092 polling\:3002

## PDF Page Extraction (Stage 4 Phase 4B)

### SourceVaultExtractPages[snapshot, pages, opts]
Snapshot \:306e\:6307\:5b9a page \:3092\:62bd\:51fa\:3057 cache \:306b\:4fdd\:5b58\:3002snapshot \:306f SnapshotId or SourceId String\:3002pages \:306f Integer | List of Integer | All\:3002
\:2192 Association (Status, SnapshotId, Pages -> {n: text, ...}, Hashes, CachedFrom -> "Disk"|"Fresh"|"Mixed", OCRCalled)
Options:
  Force -> False (cache \:7121\:8996\:3057\:518d\:62bd\:51fa)
  "ForceOCR" -> False (\:5358\:767a\:5f37\:5236 OCR\:3001True \:6642\:306f Force \:3082\:81ea\:52d5\:9069\:7528)

### $SourceVaultOCRHook
\:578b: None | Function, \:521d\:671f\:5024: None
\:30b9\:30ad\:30e3\:30f3 PDF \:306e fallback \:5024\:3002\:30b7\:30b0\:30cd\:30c1\:30e3: Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String\:3002SourceVaultOCREnable \:7d4c\:7531\:3067\:306e\:8a2d\:5b9a\:304c\:63a8\:5968\:3002

### $SourceVaultOCRMode
\:578b: String, \:521d\:671f\:5024: "Auto"
OCR \:767a\:706b\:30e2\:30fc\:30c9\:3002"Auto" (Plaintext < 5\:6587\:5b57\:6642\:306e\:307f OCR) | "Force" (\:5e38\:306b OCR)\:3002

### $SourceVaultOCRVerbose
\:578b: Boolean, \:521d\:671f\:5024: False
OCR \:5b9f\:884c\:6642\:306e\:9032\:6357 Print \:3092\:5236\:5fa1\:3002

## OCR Backends (Stage 4 Phase 4C)

### SourceVaultOCREnable[backend, opts]
OCR hook \:3092\:6709\:52b9\:5316\:3059\:308b\:3002backend \:30c7\:30d5\:30a9\:30eb\:30c8 "ClaudeVision"\:3002
\:2192 Association (Status -> "Enabled", Backend, Mode, Options)
Options:
  "Mode" -> "Auto" | "Force"
  "DPI" -> 300 (ClaudeVision) | 150 (TextRecognize)
  "SplitHalves" -> True (ClaudeVision \:5927\:30da\:30fc\:30b8\:306e\:4e0a\:4e0b\:5206\:5272 + 30px overlap)
  "Timeout" -> 180 (ClaudeVision)
  "Prompt" -> Automatic (ClaudeVision)
  "Language" -> "Japanese" (TextRecognize)
  "Hook" -> _Function (Custom \:306e\:307f)
\:4f8b: SourceVaultOCREnable["ClaudeVision", "Mode" -> "Force", "DPI" -> 300]

### SourceVaultOCRDisable[] \:2192 Association
OCR hook \:3092\:7121\:52b9\:5316 ($SourceVaultOCRHook = None)\:3002

### SourceVaultOCRStatus[]
\:73fe\:5728\:306e OCR hook \:8a2d\:5b9a\:3002
\:2192 Association (Backend: Disabled | ClaudeVision | TextRecognize | Custom, HookSet)

## Claim Extraction (Stage 5)

### SourceVaultExtract[sourceSpan, schema, opts]
sourceSpan \:306e page text \:3092 LLM \:306b\:6e21\:3057 claim \:3092\:62bd\:51fa\:3002sourceSpan \:306f SourceVaultSpan[...] / SnapshotId / SourceId\:3002schema \:306f\:6587\:5b57\:5217 (\:767b\:9332\:540d) \:307e\:305f\:306f Association\:3002
\:2192 Association (Claims, Count, ExtractedCount, DedupSkipped, AccessDecisions, ValidationStatus, SchemaName, ExtractedAt, Errors) | Denied/RequiresApproval Association
Options:
  "Topic" -> Automatic (\:30c7\:30d5\:30a9\:30eb\:30c8 schema \:540d)
  "ModelIntent" -> "summary" | "extraction" | "math-extraction-heavy"
  "StoreClaims" -> True
  "Dedup" -> True (by-source ContentHash \:7167\:5408)
  "AuthorizationCheck" -> True (2 \:6bb5\:968e NBAuthorize: sendDecision + persistDecision)
  "Validation" -> "None" | "Required"
  MaxCharacters -> 8000
  Timeout -> 180

### SourceVaultRegisterSchema[name, definition] \:2192 Association
\:62bd\:51fa schema \:3092\:30b0\:30ed\:30fc\:30d0\:30eb\:306b\:767b\:9332\:3002definition \:306f Association: "Description", "Fields" -> {<|"Name", "Type", "Required", "Description"|>, ...}, "OutputShape" -> "List" | "Single", "PromptTemplate" -> Automatic\:3002\:30d3\:30eb\:30c8\:30a4\:30f3: "FreeText" / "NumericFacts" / "DefinitionList"\:3002

### SourceVaultClaim[claimId] \:2192 Association | Missing["NotFound"]
\:6307\:5b9a claim \:306e Association\:3002

### SourceVaultClaimsForSource[sourceIdOrSnapshotId] \:2192 List of Association
\:6307\:5b9a source \:306b\:7d10\:3065\:304f claim \:30ea\:30b9\:30c8\:3002

### SourceVaultClaimsForTopic[topic] \:2192 List of Association
\:6307\:5b9a topic \:306b\:7d10\:3065\:304f claim \:30ea\:30b9\:30c8\:3002

### SourceVaultListSchemas[] \:2192 List of String
\:767b\:9332\:6e08\:307f schema \:540d\:30ea\:30b9\:30c8\:3002

### SourceVaultGetSchema[name] \:2192 Association
\:767b\:9332\:6e08\:307f schema \:5b9a\:7fa9\:3002

### SourceVaultClaimStoreStatus[]
ClaimStore \:306e\:72b6\:614b (debug \:7528)\:3002
\:2192 Association (ClaimsDir, MasterPath, MasterExists, MasterClaims, TopicFiles, SourceFiles)

### SourceVaultClaimStoreCompact[opts]
Master + by-topic + by-source \:3092\:5168\:8aad\:307f\:3057 ContentHash \:3067 dedup\:3001\:5168\:30a4\:30f3\:30c7\:30c3\:30af\:30b9\:3092 rebuild\:3002atomic rewrite\:3002
\:2192 Association (Status, BeforeCount, AfterCount, Removed, BackupPaths, DryRun)
Options: "Backup" -> True (.bak.<timestamp>), "DryRun" -> False

## Evidence Bundle (Stage 6c)

### SourceVaultBundleCreate[name, deps, opts]
Generated artifact \:306e\:4f9d\:5b58\:3092 evidence bundle \:3068\:3057\:3066\:4fdd\:5b58\:3002deps: Association {"GeneratedFiles", "Sources", "SourceSpans", "Claims", "Generator"}\:3002
\:2192 Association (Status, BundleId, Path)
Options: "Kind" -> "SimulationExample" | "LaTeXExport" | "DocumentGeneration" | "CodeGeneration" | "Notebook" | _String

### SourceVaultBundleGet[bundleId] \:2192 Association | Missing["NotFound"]
\:6307\:5b9a bundle \:3092\:8aad\:307f\:8fbc\:307f\:8fd4\:3059\:3002

### SourceVaultBundleList[] \:2192 List of String
\:5168 bundle id \:30ea\:30b9\:30c8\:3002

### SourceVaultBundleStatus[bundleId]
Bundle \:306e\:73fe\:5728 Status\:3002\:53c2\:7167\:3059\:308b snapshot \:306e LifecycleStatus \:3092\:96c6\:7d04\:3002
\:2192 Association (Status: Current | Stale | NeedsReview | Invalidated, Reason, AffectedSnapshots, AffectedClaims)

### SourceVaultBundleInvalidate[bundleId, reason] \:2192 Association
Bundle \:3092\:624b\:52d5\:3067 invalidate\:3002

### SourceVaultBundleDelete[bundleId] \:2192 Association
Bundle \:30d5\:30a1\:30a4\:30eb\:3092\:524a\:9664 (debug \:7528)\:3002

## vN Diff + Snapshot Lifecycle (Stage 8)

### SourceVaultDiffVersions[v1Snap, v2Snap]
\:4e8c\:3064\:306e snapshot \:306e page hash \:96c6\:5408\:3092\:6bd4\:8f03\:3057\:5dee\:5206\:3092\:8fd4\:3059\:3002
\:2192 Association (Status, V1Snap, V2Snap, AddedPages, RemovedPages, ChangedPages, UnchangedPages)

### SourceVaultMarkSnapshotStale[snapshotId, reason] \:2192 Association
Snapshot meta \:306e LifecycleStatus \:3092 "Stale" \:306b\:66f4\:65b0 + VersionedUpdate event \:8a18\:9332\:3002

### SourceVaultMarkSnapshotInvalidated[snapshotId, reason] \:2192 Association
Snapshot meta \:306e LifecycleStatus \:3092 "Invalidated" \:306b\:66f4\:65b0\:3002Retraction \:7528\:3002

### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason]
\:9ad8\:30ec\:30d9\:30eb refresh API\:3002Diff \:8a08\:7b97 + oldSnap \:3092 Stale \:5316 + SupersededBy \:8a2d\:5b9a + event \:8a18\:9332\:3002
\:2192 Association (Status, Diff, Event)

### SourceVaultBundlesForSnapshot[snapshotId] \:2192 List of String
\:6307\:5b9a snapshot \:3092\:53c2\:7167\:3059\:308b\:5168 bundle id\:3002

### SourceVaultSourceEvents[opts]
events/source-events.jsonl \:306e\:5168 event \:30ea\:30b9\:30c8\:3002
\:2192 List of Association
Options: "SourceId" -> _String, "SnapshotId" -> _String, "EventType" -> "VersionedUpdate" | "Retraction" | "SourceDeletion" | "SchemaChange"

### SourceVaultSourceEventAppend[event] \:2192 Association
Event Association \:3092 events/source-events.jsonl \:306b append\:3002\:5fc5\:9808: EventType, SourceId, Reason\:3002\:4efb\:610f: OldSnapshotId, NewSnapshotId, Metadata\:3002EventId / Timestamp \:306f\:81ea\:52d5\:3002

## Notebook Management (Stage 9)

### SourceVaultRegisterNotebook[path]
\:6307\:5b9a path \:306e notebook \:3092 SourceVault \:306b\:767b\:9332\:3002NotebookRef \:306f path-based hash\:3002
\:2192 Association (Status, NotebookRef, Path, RegisteredAt)

### SourceVaultIndexNotebook[path, opts]
Notebook \:306e Header / Todo / Cell \:3092\:62bd\:51fa\:3057 index \:3092\:66f4\:65b0\:3002
\:2192 Association (Status, NotebookRef, SnapshotId, Header, TodoCount, OpenTodoCount, ReviewState, DeadlineState, Lint)
Options: "ExtractHeader" -> True, "ExtractTodos" -> True, "ForceReindex" -> False (mtime \:540c\:3058\:306a\:3089 skip)

### SourceVaultIndexNotebookFolder[dir, opts]
\:6307\:5b9a folder \:914d\:4e0b\:306e .nb \:3092\:5168\:3066 index\:3002
\:2192 Association (Status, Processed, Failed, Results)
Options: "Recursive" -> False, "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}

### SourceVaultExtractNotebookHeader[path]
\:5148\:982d Input \:30bb\:30eb\:304b\:3089 Header Association \:3092 safe parse (HoldComplete + whitelist)\:3002
\:2192 Association (ParseStatus: OK | MissingHeader | UnsafeExpression, Keywords, Deadline, NextReview, Status)

### SourceVaultExtractNotebookTodos[path]
Notebook \:5185\:306e TodoItem \:30b9\:30bf\:30a4\:30eb\:30bb\:30eb\:3092\:5217\:6319\:3002Status \:5224\:5b9a: TaggingRules > StrikeThrough + FontColor > Default \:512a\:5148\:9806\:4f4d\:3002
\:2192 List of Association ({Text, Status: Open|Done|Pass, StatusSource, StrikeThrough})

### SourceVaultExtractNotebookTaggingRules[path]
Notebook \:5168\:4f53 + \:5404 TodoItem cell \:306e TaggingRules \:3092\:53d6\:5f97\:3002
\:2192 Association (Status, Path, NotebookTaggingRules, CellTaggingRules -> {<|Index, CellStyle, TaggingRules|>, ...})

### SourceVaultNotebookSemanticHash[path]
\:610f\:5473\:7684\:5185\:5bb9\:306e\:307f\:3092\:5bfe\:8c61\:306b SHA256 hash \:3092\:8a08\:7b97\:3002\:8868\:793a\:30e1\:30bf\:30c7\:30fc\:30bf (ExpressionUUID / CellChangeTimes / WindowSize \:7b49) \:9664\:5916\:3002
\:2192 Association (Status, Path, SemanticHash)

### SourceVaultFindNotebooks[opts]
Index \:6e08\:307f notebook \:3092\:691c\:7d22\:3002LLM \:4e0d\:8981\:306e deterministic query\:3002
\:2192 List of Association
Options:
  "OpenTodos" -> _Bool
  "NextReview" -> "Overdue" | "ThisWeek" | "DueSoon" | <|"From", "To"|>
  "Deadline" -> "Overdue" | "ThisWeek" | "DueSoon" | <|"From", "To"|>
  "Keywords" -> {_String, ...}
  "Status" -> "Todo" | "Done" | _String

### SourceVaultNotebookLint[record] \:2192 List of String
Notebook record (\:307e\:305f\:306f path) \:306b lint \:30c1\:30a7\:30c3\:30af\:3002\:691c\:51fa: MissingHeader / UnsafeHeaderExpression / HeaderDeadlineMalformed / HeaderNextReviewMalformed / HeaderStatusTodoButNoOpenTodos / HeaderStatusDoneButOpenTodosExist / DeadlinePast / NextReviewPast / TodoCellStatusHeuristicOnly\:3002

## Notebook Summary Artifact (Stage 9 P1 Step 4)

### SourceVaultRegisterNotebookSummary[path, summary, opts]
Notebook \:306e summary artifact \:3092\:767b\:9332\:3002\:73fe\:5728\:306e snapshot (SnapshotId + SemanticHash) \:3068\:7d10\:3065\:3051\:3066\:4fdd\:5b58\:3002
\:2192 Association (Status, SummaryId, NotebookRef, ...)
Options: "SummaryFormat" -> "text" ("text" | "markdown"), "GeneratedBy" -> "manual"

### SourceVaultGetNotebookSummary[path]
Notebook \:306b\:7d10\:3065\:304f summary record\:3002\:672a\:767b\:9332\:6642\:306f Status -> "Missing"\:3002
\:2192 Association (Status: OK | Missing | Failed, Summary, SummaryFormat, BasedOnSnapshot, BasedOnSemanticHash, GeneratedBy, CreatedAt)

### SourceVaultNotebookSummaryStatus[path]
Summary artifact \:306e\:73fe\:5728 lifecycle\:3002
\:2192 Association (Status: Missing | Current | StaleFormattingOnly | Stale, Reason, CurrentSnapshot, SummaryBasedOnSnapshot)

### SourceVaultNotebookSummary[path, opts]
Notebook \:5185\:5bb9\:3092 LLM \:3067\:8981\:7d04\:3057 Summary artifact \:3068\:3057\:3066\:4fdd\:5b58\:3002Step 4 Register \:3092\:5185\:90e8\:547c\:3073\:51fa\:3057 lifecycle \:7ba1\:7406\:81ea\:52d5\:3002\:30c7\:30d5\:30a9\:30eb\:30c8 PrivacyLevel = 1.0 (\:30ed\:30fc\:30ab\:30eb LM)\:3002
\:2192 Association (Get \:540c\:5f62 | Register \:540c\:5f62 | Inconsistent | Failed)
Options:
  "ForceRefresh" -> False
  "MaxLength" -> 500
  "Language" -> Automatic (Automatic | "Japanese" | "English")
  "Model" -> Automatic ({"provider", "model"} \:660e\:793a\:6307\:5b9a\:53ef)
  "PrivacyLevel" -> 1.0
  "FallbackToCloud" -> "Ask" ("Ask" | "Allow" | "Deny")

## Notebook Todo Write (Stage 9 P1 Step 6)

### SourceVaultMarkTodo[path, target, newStatus, opts]
Notebook \:5185 Todo cell \:306e Status \:3092\:5909\:66f4\:3002NBAccess \:306e NBWriteTodoStatus \:3078\:306e\:8584\:3044\:30e9\:30c3\:30d1\:30fc\:3002target: Integer (1-based Todo Index) | String (TodoId) | Association (<|"Index", "Text"|>)\:3002newStatus: "Open" | "Done" | "Pass"\:3002
\:2192 Association (DryRun: Status -> "DryRunOK", Target, MatchedTodo, OldStatus, NewStatus, CellPath, Before, After / \:5b9f\:884c: Status -> "OK"|"Failed", ..., ReindexResult)
Options:
  "DryRun" -> True (\:5b89\:5168\:5074 default\:3001True \:306f preview \:306e\:307f)
  "AutoReindex" -> True (\:7de8\:96c6\:6210\:529f\:5f8c\:306b SourceVaultIndexNotebook \:81ea\:52d5\:547c\:3073\:51fa\:3057)
  "AccessSpec" -> <|"AccessLevel" -> 0.7, ...|>
\:4f8b: SourceVaultMarkTodo[path, 3, "Done", "DryRun" -> False]

## Notebook Schedule / Refresh (Stage 9 P1 Step 3)

### SourceVaultUpcomingSchedule[opts]
\:4eca\:65e5\:304b\:3089 N \:65e5\:4ee5\:5185\:306b Deadline / NextReview \:304c\:3042\:308b notebook \:306e\:4e00\:89a7\:3092 Dataset \:3067\:8fd4\:3059\:3002
\:2192 Dataset (\:884c: Deadline, NextReview, Title, Dir, OpenTodos, Status, Privacy)
Options:
  "Scope" -> $onWork | _String (\:30c7\:30a3\:30ec\:30af\:30c8\:30ea)
  "Period" -> Quantity[7, "Days"]
  "IncludeOverdue" -> True
  "Recursive" -> True
  "Refresh" -> "IfStale" ("Never" | "IfStale" | "Force")
  "FallbackToCloud" -> "Ask"
  "StatusFilter" -> {"Todo"} ({"Todo"} | {"Todo", "Done", "Pass"} | All)
  "UseCache" -> True

### SourceVaultRefreshAllSummaries[opts]
Scope \:914d\:4e0b\:5168 notebook \:306e\:6982\:8981\:3092\:4e00\:62ec\:518d\:751f\:6210\:3059\:308b\:3002
\:2192 Association (Status, Scope, TotalFiles, Refreshed, Cached, Inconsistent, Failed, Details)
Options:
  "Scope" -> $onWork (default)
  "Recursive" -> True
  "ForceRefresh" -> False
  "FallbackToCloud" -> "Deny" (\:4e00\:62ec\:6642\:63a8\:5968)

## Maintenance

### SourceVaultResetStore[opts]
Notebooks \:30b9\:30c8\:30a2 (sources / snapshots / summaries / todos / review / lint / sync / relink) \:3092\:5168\:524a\:9664\:3057\:521d\:671f\:5316\:3002NotebookRef \:65b9\:5f0f\:5909\:66f4\:6642\:306b\:65e7\:30c7\:30fc\:30bf\:3092\:7834\:68c4\:3059\:308b\:7528\:9014\:3002
\:2192 Association
Options: "Confirm" -> True (\:5fc5\:9808\:3001\:660e\:793a\:7684\:306a\:627f\:8a8d)

## \:4f9d\:5b58\:30d1\:30c3\:30b1\:30fc\:30b8

- [NBAccess](https://github.com/transreal/NBAccess) — NBAuthorize / NBWriteTodoStatus \:7b49 (\:5fc5\:9808)
- [claudecode](https://github.com/transreal/claudecode) — ClaudeQuerySync / ClaudeQueryBg / LLMGraphDAGCreate (LLM / async ingest \:6642)
- [PDFIndex](https://github.com/transreal/PDFIndex) — OCR ClaudeVision \:30d1\:30bf\:30fc\:30f3\:306e\:539f\:5178