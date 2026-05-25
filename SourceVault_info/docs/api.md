# SourceVault API リファレンス

外部 source 管理パッケージ。Stage 0-9 (P1 Step 6 まで) 実装済み。依存: [NBAccess](https://github.com/transreal/NBAccess)。任意連携: [claudecode](https://github.com/transreal/claudecode), [PDFIndex](https://github.com/transreal/PDFIndex)。

## Bootstrap / Configuration

### $SourceVaultVersion
型: String
SourceVault パッケージのバージョン文字列。

### $SourceVaultRoots
型: Association
物理 root ディレクトリマッピング。Keys: `"PrivateVault"` | `"CloudMirror"` | `"Tmp"` | `"AttachmentMirror"` | `"ExternalOwned"`。PrivateVault は authoritative storage で cloud LLM / Claude Code CLI に直接読ませない。CloudMirror / AttachmentMirror は materialize 済み projection のみ。

### $SourceVaultSeedModelRegistry
型: Association
bootstrap 時の fallback model registry。compiled registry が無い場合の災害復旧用 fallback。LLM が自動更新しない。

### $SourceVaultMaxFileSizeMB
型: Integer, 初期値: 50
index 時に .nb を Import するファイルサイズの上限 (MB)。これを超える .nb は Import せずファイル情報のみ記録。

### $SourceVaultCloudRoots
型: List of String
クラウド共有フォルダのシンボル名リスト。例: `{"$packageDirectory", "$dropbox", "$onWork", "$offWork", "$mathematicaWork"}`。これらの配下にあれば `{"$onWork", "folder", "file.nb"}` のようなシンボリックパスに正規化される。

### $SourceVaultCloudRootAliases
型: Association, 初期値: `<||>`
クラウドルートのシンボル名から旧 PC など別環境での絶対パスリストへの対応。例: `<|"$onWork" -> {"C:/Users/imai_/Dropbox/On Work"}|>`。別 PC で index されたレコードの旧パスを正規化するためのエイリアス。

### SourceVaultInitialize[opts] → Association
SourceVault の物理 root を生成して初期化する。作成済みなら noop。
Options: "Roots" -> $SourceVaultRoots (override), "Force" -> False (True で再初期化)

### SourceVaultStatus[sourceRef] → Association
指定 source / snapshot / ファイルの概要を返す。引数なしで vault 全体の概要。

### SourceVaultList[] → List
vault 内の全 source ID リスト。

### SourceVaultSnapshots[sourceRef] → List
指定 source の snapshot ID リスト。

### SourceVaultResetStore[opts] → Association
notebooks ストア (sources/snapshots/summaries/todos/review/lint/sync/relink) を全削除して初期化する。破壊的操作。
Options: "Confirm" -> False (True 必須、無いと DryRun)

## Stage 1: Lookup / Resolve

### SourceVaultLookup[topic, key, opts] → Association | Missing
compiled registry から key に対応する entry を返す。コンパイルド無し時は seed に fallback。
Options: "Channel" -> "public" ("public" | "private"), "AllowSeed" -> True

### SourceVaultResolve[kind, query, opts] → Association | Missing
compiled registry から query に match する entry を返す。複数 match 時は Availability フィルタ後 Class/Freshness で sort し先頭。
Options: "Channel" -> "public", "AllowSeed" -> True, "Topic" -> Automatic
例: `SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]`

### ClaudeResolveModel[provider, intent] → Association | Missing
`SourceVaultResolve["Model", ...]` の互換 wrapper。旧 WikiDBResolveModel の置換。
例: `ClaudeResolveModel["anthropic", "heavy"]`

## Stage 1.5 / 2 / 4A: Ingest

### SourceVaultIngest[source, opts] → Association
外部 source (ローカルファイル / HTTPS URL / arXiv) を登録し raw snapshot を PrivateVault に保存。
→ `<|"Status" -> "Ingested"|"AlreadyCurrent"|"RebuiltMetadata"|"Queued", "SourceId" -> _, "SnapshotId" -> _, ...|>`
Options:
- Topic -> Automatic | _String
- TrustLevel -> Automatic | "OfficialAPI" | "OfficialDocs" | "PublicWeb" | "LocalFile"
- PrivacyLabel -> Automatic | _Real
- PinVersion -> True | False | Automatic
- Asynchronous -> False (True 時 LLMGraphDAGCreate 経由で JobId 即時 return、claudecode 必須)
- EnsureUUID -> Automatic (.nb なら hash 前に UUID 埋込み、巨大ファイルはスキップ)

### SourceVaultIngestWait[ingestResult, timeoutSec] → Association
非同期 ingest 完了待ち (timeoutSec デフォルト 60)。sync 完了済みなら即 return。Queued なら snapshot 増加を polling。Timeout で `Status: "Timeout"`。第一引数は Ingest 結果 Association または SourceId String。

## Stage 4 Phase 4B: PDF Page Extraction

### SourceVaultExtractPages[snapshot, pages, opts] → Association
snapshot の指定 page を抽出し cache 保存。
→ `<|"Status", "SnapshotId", "Pages" -> <|n -> text, ...|>, "Hashes", "CachedFrom" -> "Disk"|"Fresh"|"Mixed", "OCRCalled"|>`
snapshot: SnapshotId String または SourceId (latest 使用)。pages: Integer | List of Integer | All。
Options:
- Force -> False (cache 無視)
- "ForceOCR" -> False (この呼出しだけ OCR 強制、Force 自動適用)

### $SourceVaultOCRHook
型: None | Function, 初期値: None
スキャン PDF の fallback。シグネチャ: `Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String`。

### $SourceVaultOCRMode
型: String, 初期値: "Auto"
OCR 発火モード。"Auto" は Plaintext 抽出が 5 文字未満時のみ OCR。"Force" は常時 OCR。

### $SourceVaultOCRVerbose
型: Boolean, 初期値: False
OCR 実行時の進捗 Print 制御。

## Stage 4 Phase 4C: OCR Backends

### SourceVaultOCREnable[backend, opts] → Association
OCR hook を有効化。backend: `"ClaudeVision"` (デフォルト) | `"TextRecognize"` | `"Custom"`。
→ `<|"Status" -> "Enabled", "Backend", "Mode", "Options"|>`
Options:
- "DPI" -> 300 (ClaudeVision) / 150 (TextRecognize)
- "SplitHalves" -> True (ClaudeVision、大 page を上下 30px overlap で分割)
- "Timeout" -> 180 (ClaudeVision)
- "Prompt" -> Automatic (ClaudeVision)
- "Language" -> "Japanese" (TextRecognize)
- "Hook" -> Function[req, text] (Custom)
- "Mode" -> "Auto" | "Force"
- "Verbose" -> False

### SourceVaultOCRDisable[] → Null
OCR hook を無効化 (`$SourceVaultOCRHook = None`)。

### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定を返す。`<|"Backend" -> "Disabled"|"ClaudeVision"|"TextRecognize"|"Custom", "HookSet" -> _Bool, ...|>`

## Stage 5: Claim Extraction

### SourceVaultExtract[sourceSpan, schema, opts] → Association
sourceSpan の page text を LLM に渡し claim を抽出。
→ `<|"Claims" -> {...}, "Count", "ExtractedCount", "DedupSkipped", "AccessDecisions" -> <|"Send", "Persist"|>, "ValidationStatus", "SchemaName", "ExtractedAt", "Errors"|>`
sourceSpan: `SourceVaultSpan[...]` 結果または SnapshotId/SourceId。schema: 登録済み schema 名または inline Association。
Options:
- "Topic" -> _String
- "ModelIntent" -> "summary" | "extraction" | "math-extraction-heavy"
- "StoreClaims" -> True
- "Dedup" -> True (by-source ContentHash 照合)
- "AuthorizationCheck" -> True (2 段階 NBAuthorize: sendDecision, persistDecision)
- "Validation" -> "None" | "Required"
- MaxCharacters -> 8000
- Timeout -> 180

Decision Deny 時: `<|"Status" -> "DeniedByNBAccess", "Reason", "AccessDecisions"|>`
Decision RequireApproval 時: `<|"Status" -> "RequiresApproval", ...|>`

### SourceVaultRegisterSchema[name, definition] → Association
抽出 schema をグローバルに登録。
definition: `<|"Description" -> _, "Fields" -> {<|"Name", "Type", "Required", "Description"|>, ...}, "OutputShape" -> "List"|"Single", "PromptTemplate" -> Automatic|_String|>`
ビルトイン: `"FreeText"`, `"NumericFacts"`, `"DefinitionList"`。

### SourceVaultClaim[claimId] → Association | Missing
指定 claim を返す。

### SourceVaultClaimsForSource[sourceIdOrSnapshotId] → List
指定 source に紐づく claim リスト。

### SourceVaultClaimsForTopic[topic] → List
指定 topic に紐づく claim リスト。

### SourceVaultListSchemas[] → List
登録済み schema 名リスト。

### SourceVaultGetSchema[name] → Association
登録済み schema 定義を返す。

### SourceVaultClaimStoreStatus[] → Association
ClaimStore の状態を返す (debug)。Keys: ClaimsDir, MasterPath, MasterExists, MasterClaims, TopicFiles, SourceFiles。

### SourceVaultClaimStoreCompact[opts] → Association
master + by-topic + by-source を ContentHash で dedup し全インデックスを atomic rebuild。
→ `<|"Status", "BeforeCount", "AfterCount", "Removed", "BackupPaths", "DryRun"|>`
Options: "Backup" -> True (.bak.<timestamp>), "DryRun" -> False

## Stage 6c: Evidence Bundle

### SourceVaultBundleCreate[name, deps, opts] → Association
generated artifact の依存を evidence bundle として保存。
→ `<|"Status", "BundleId", "Path"|>`
deps: `<|"GeneratedFiles" -> {...}, "Sources" -> {<|"SourceId", "SnapshotId"|>, ...}, "SourceSpans" -> {...}, "Claims" -> {...}, "Generator" -> <|"Tool", "WorkflowId", "ModelIntent", "ResolvedModel"|>|>`
Options: "Kind" -> "SimulationExample" | "LaTeXExport" | "DocumentGeneration" | "CodeGeneration" | "Notebook" | _String

### SourceVaultBundleGet[bundleId] → Association | Missing
指定 bundle を読み込み返す。

### SourceVaultBundleList[] → List
全 bundle id リスト。

### SourceVaultBundleStatus[bundleId] → Association
bundle の現在の Status を計算。参照 snapshot の LifecycleStatus を集約。
→ `<|"Status" -> "Current"|"Stale"|"NeedsReview"|"Invalidated", "Reason", "AffectedSnapshots", "AffectedClaims"|>`

### SourceVaultBundleInvalidate[bundleId, reason] → Association
bundle を手動 invalidate。

### SourceVaultBundleDelete[bundleId] → Association
bundle ファイルを削除 (debug)。

## Stage 8: vN Diff + Snapshot Lifecycle

### SourceVaultDiffVersions[v1Snap, v2Snap] → Association
2 snapshot の page hash 集合差分を返す。
→ `<|"Status", "V1Snap", "V2Snap", "AddedPages" -> {_Integer...}, "RemovedPages", "ChangedPages", "UnchangedPages"|>`

### SourceVaultMarkSnapshotStale[snapshotId, reason] → Association
snapshot meta の LifecycleStatus を `"Stale"` に更新、events/source-events.jsonl に VersionedUpdate 記録。

### SourceVaultMarkSnapshotInvalidated[snapshotId, reason] → Association
LifecycleStatus を `"Invalidated"` に更新 (Retraction など)。

### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason] → Association
高レベル refresh API。diff 計算 → old を Stale 化 + SupersededBy 設定 → event 記録。
→ `<|"Status", "Diff", "Event"|>`

### SourceVaultBundlesForSnapshot[snapshotId] → List
指定 snapshot を参照する全 bundle id リスト。

### SourceVaultSourceEvents[opts] → List
events/source-events.jsonl の全 event リスト。
Options: "SourceId" -> _String, "SnapshotId" -> _String, "EventType" -> "VersionedUpdate" | "Retraction" | "SourceDeletion" | "SchemaChange"

### SourceVaultSourceEventAppend[event] → Association
event Association を events/source-events.jsonl に append。EventType / SourceId / Reason 必須。EventId, Timestamp は自動生成。

## Stage 6b: Compiled Registry

### SourceVaultListRegistries[opts] → List
登録済み registry topic と channel を返す。
Options: "Channel" -> "public" | "private" | All (All)

### SourceVaultRegistryStatus[topic, opts] → Association
指定 topic の registry 状態。
→ `<|"Topic", "Channel", "CompiledPath", "CompiledExists", "CompiledCount", "SeedPath", "SeedExists", "SeedCount", "LastModified"|>`
Options: "Channel" -> "public" | "private"

### SourceVaultCompileRegistry[topic, entries, opts] → Association
entries (List of Association) を compiled registry に保存。
→ `<|"Status", "Topic", "Channel", "Path", "Count"|>`
Options: "Channel" -> "public", "Sources" -> {_String...}, "PolicySource" -> _String

### SourceVaultRegisterSeed[topic, entries] → Association
seed entries を `seeds/<topic>-seed.json` に保存 (bootstrap 用)。

## Stage 9 P0: Notebook Management

### SourceVaultRegisterNotebook[path] → Association
指定 path の notebook を SourceVault に登録。NotebookRef は path-based hash で安定生成。
→ `<|"Status", "NotebookRef", "Path", "RegisteredAt"|>`

### SourceVaultIndexNotebook[path, opts] → Association
notebook の Header / Todo / Cell を抽出して index 更新。
→ `<|"Status", "NotebookRef", "SnapshotId", "Header", "TodoCount", "OpenTodoCount", "ReviewState", "DeadlineState", "Lint" -> {...}|>`
Options: "ExtractHeader" -> True, "ExtractTodos" -> True, "ForceReindex" -> False (mtime 同じなら skip)

### SourceVaultIndexNotebookFolder[dir, opts] → Association
指定 folder 配下の .nb を全て index。
→ `<|"Status", "Processed", "Failed", "Results"|>`
Options: "Recursive" -> False, "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}

### SourceVaultExtractNotebookHeader[path] → Association
notebook 先頭 Input セルから Header を safe parse (HoldComplete + whitelist)。
→ `<|"ParseStatus" -> "OK"|"MissingHeader"|"UnsafeExpression", "Keywords", "Deadline", "NextReview", "Status"|>`

### SourceVaultExtractNotebookTodos[path] → List
notebook 内の TodoItem スタイルセルを列挙。Status は Open / Done / Pass。判定優先順位: TaggingRules > FontVariations StrikeThrough + FontColor > Default。
→ `{<|"Text", "Status", "StatusSource", "StrikeThrough" -> _Bool|>, ...}`

### SourceVaultFindNotebooks[opts] → List
index 済み notebook を検索 (deterministic、LLM 不要)。
→ `{<|"NotebookRef", "OriginalPath", "Title", "Header", "ReviewState", ...|>, ...}`
Options:
- "OpenTodos" -> True | False
- "NextReview" -> "Overdue" | "ThisWeek" | "DueSoon" | `<|"From", "To"|>`
- "Deadline" -> "Overdue" | "ThisWeek" | "DueSoon" | `<|"From", "To"|>`
- "Keywords" -> {_String, ...} (いずれかに match)
- "Status" -> "Todo" | "Done" | _String

### SourceVaultNotebookLint[record] → List
notebook record (または path) に lint チェック。検出名: MissingHeader, UnsafeHeaderExpression, HeaderDeadlineMalformed, HeaderNextReviewMalformed, HeaderStatusTodoButNoOpenTodos, HeaderStatusDoneButOpenTodosExist, DeadlinePast, NextReviewPast, TodoCellStatusHeuristicOnly。

## Stage 9 P1 Step 1: TaggingRules

### SourceVaultExtractNotebookTaggingRules[path] → Association
Notebook 全体および各 TodoItem cell の TaggingRules を取得。Wolfram 標準関数優先 (rule 102) に準拠。
→ `<|"Status" -> "OK"|"Failed", "Path", "NotebookTaggingRules" -> _Association, "CellTaggingRules" -> {<|"Index", "CellStyle", "TaggingRules"|>, ...}|>`

## Stage 9 P1 Step 2: Semantic Hash

### SourceVaultNotebookSemanticHash[path] → Association
notebook の意味的内容のみを対象にしたハッシュを計算。表示メタデータ (ExpressionUUID / CellChangeTimes / CellLabel / FontFamily / WindowSize 等) を除外し、content / style / TaggingRules / FontVariations / FontColor / Background のみ対象。
→ `<|"Status" -> "OK"|"Failed", "Path", "SemanticHash" -> _String|>`

## Stage 9 P1 Step 3: Upcoming Schedule

### SourceVaultUpcomingSchedule[opts] → Dataset
「今日から N 日以内」に Deadline / NextReview がある notebook 一覧を Dataset で返す。期限切れは赤、今日/明日は青。
→ `Dataset[行={Deadline, NextReview, Title (Open button), Dir (Open button), OpenTodos, Status, Privacy}]`
Options:
- "Scope" -> dir | _String (default $onWork または $packageDirectory)
- "Period" -> Quantity[7, "Days"]
- "IncludeOverdue" -> True
- "Recursive" -> True
- "Refresh" -> "Never" | "IfStale" | "Force"
- "FallbackToCloud" -> "Ask" | "Allow" | "Deny"
- "StatusFilter" -> {"Todo"} | {"Todo", "Done", "Pass"} | All
- "UseCache" -> True

### SourceVaultRefreshAllSummaries[opts] → Association
Scope 配下全 notebook の概要を一括再生成。
→ `<|"Status", "Scope", "TotalFiles", "Refreshed", "Cached", "Inconsistent", "Failed", "Details"|>`
Options: "Scope" -> $onWork, "Recursive" -> True, "ForceRefresh" -> False, "FallbackToCloud" -> "Deny"

## Stage 9 P1 Step 4: Summary Artifact Lifecycle

### SourceVaultRegisterNotebookSummary[path, summary, opts] → Association
notebook の summary artifact を登録。現在の snapshot (SnapshotId + SemanticHash) と紐付け保存。
→ `<|"Status" -> "OK"|"Failed", "SummaryId", "NotebookRef", ...|>`
Options: "SummaryFormat" -> "text" | "markdown" (default "text"), "GeneratedBy" -> "manual"

### SourceVaultGetNotebookSummary[path] → Association
notebook に紐づく summary record 取得。
→ `<|"Status" -> "OK"|"Missing"|"Failed", "Summary", "SummaryFormat", "BasedOnSnapshot", "BasedOnSemanticHash", "GeneratedBy", "CreatedAt"|>`

### SourceVaultNotebookSummaryStatus[path] → Association
summary artifact の lifecycle ステータス判定。
→ `<|"Status" -> "Missing"|"Current"|"StaleFormattingOnly"|"Stale", "Reason", "CurrentSnapshot", "SummaryBasedOnSnapshot"|>`
- Missing: summary 未登録
- Current: BasedOnSnapshot が現在 snapshot と一致
- StaleFormattingOnly: SemanticHash 一致 (formatting のみ変更)
- Stale: SemanticHash 変化 (再生成推奨)

## Stage 9 P1 Step 5: LLM Notebook Summary

### SourceVaultNotebookSummary[path, opts] → Association
notebook 内容を LLM で要約し Summary artifact として保存。Step 4 の Register を内部呼出し、snapshot / SemanticHash 紐付け・lifecycle 管理自動。デフォルト PrivacyLevel=1.0 (ローカル LM のみ)。
→ Current 時: 既存 record / 生成成功時: Register と同形 / Inconsistent: `<|"Status" -> "Inconsistent", "Reason", ...|>` / 失敗: `<|"Status" -> "Failed", "Reason"|>`
Options:
- "ForceRefresh" -> False
- "MaxLength" -> 500
- "Language" -> Automatic | "Japanese" | "English"
- "Model" -> Automatic | {"provider", "model"}
- "PrivacyLevel" -> 1.0 (0.0 = API 許可, 1.0 = ローカルのみ)
- "FallbackToCloud" -> "Ask" | "Allow" | "Deny"

## Stage 9 P1 Step 6: Todo 書込み

### SourceVaultMarkTodo[path, target, newStatus, opts] → Association
notebook 内 Todo cell の Status を変更。NBAccess の NBWriteTodoStatus への薄いラッパー。Cell options (FontVariations StrikeThrough + FontColor) と TaggingRules `<|"SourceVault" -> <|"TodoStatus" -> newStatus|>|>` を更新。
target: Integer (1-based Index) | String (TodoId) | Association (`<|"Index" -> n, "Text" -> "..."|>`)
newStatus: `"Open"` | `"Done"` | `"Pass"`
Options:
- "DryRun" -> True (default、安全側、preview のみ)
- "AutoReindex" -> True (実行時のみ SourceVaultIndexNotebook 自動呼出)
- "AccessSpec" -> `<|"AccessLevel" -> 0.7, ...|>`

DryRun 時: `<|"Status" -> "DryRunOK", "Target", "MatchedTodo", "OldStatus", "NewStatus", "CellPath" -> {_Integer...}, "Before" -> HoldComplete[...], "After" -> HoldComplete[...]|>`
実行時: `<|"Status" -> "OK"|"Failed", "Target", "MatchedTodo", "OldStatus", "NewStatus", "ReindexResult"|>`