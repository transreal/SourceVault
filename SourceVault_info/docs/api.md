# SourceVault API リファレンス

LLM 向け API リファレンス。`BeginPackage["SourceVault`", {"NBAccess`"}]`。依存: [NBAccess](https://github.com/transreal/NBAccess), [claudecode](https://github.com/transreal/claudecode), [PDFIndex](https://github.com/transreal/PDFIndex)。

## Bootstrap / Configuration

### $SourceVaultVersion
型: String
SourceVault パッケージのバージョン文字列。

### $SourceVaultRoots
型: Association
物理 root ディレクトリマッピング。Keys: `"PrivateVault"` (authoritative storage, Dropbox 配下) | `"CloudMirror"` ($ClaudeWorkingDirectory 配下) | `"Tmp"` | `"AttachmentMirror"` ($packageDirectory/claude_attachments) | `"ExternalOwned"`。PrivateVault は cloud LLM / Claude CLI に直接読ませない。

### $SourceVaultSeedModelRegistry
型: Association
Bootstrap 時の fallback model registry。production truth ではなく、compiled registry が無い場合の災害復旧用 fallback。LLM が自動更新しない。

### $SourceVaultCloudRoots
型: List of String
クラウド共有フォルダのシンボル名リスト (例: `{"$packageDirectory", "$dropbox", "$onWork", "$offWork", "$mathematicaWork"}`)。絶対パスはこれら配下にあれば `{"$onWork", "folder", "file.nb"}` 形式のシンボリックパスに正規化される。

### $SourceVaultCloudRootAliases
型: Association, 初期値: `<||>`
クラウドルートのシンボル名から旧 PC など別環境での絶対パスへの対応。形式: `<|"$onWork" -> {"C:/Users/imai_/Dropbox/On Work"}, ...|>`。複数 PC をまたいだ二重登録を防止。

### SourceVaultInitialize[opts]
物理 root を生成して初期化する。作成済みなら noop。
→ Association
Options: "Roots" -> $SourceVaultRoots (override), "Force" -> False (True で再初期化)

### SourceVaultStatus[sourceRef] → Association
指定 source / snapshot / ファイルの概要を返す。引数なしで vault 全体の概要。

### SourceVaultList[] → List
vault 内の全 source ID リスト。

### SourceVaultSnapshots[sourceRef] → List
指定 source の snapshot ID リスト。

## Stage 1 / 6b: Compiled Registry

### SourceVaultResolve[kind, query, opts]
compiled registry から query に match する entry を返す。複数 match 時は Availability != "Unavailable" をフィルタし Class/Freshness で sort して先頭を返す。
→ Association | Missing["NotFound"]
Options: "Channel" -> "public" ("public" | "private"), "AllowSeed" -> True (compiled 無し時 seed 使用), "Topic" -> Automatic (デフォルト "<kind>-registry" 小文字)
例: `SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]`

### SourceVaultLookup[topic, key, opts]
compiled registry から key に対応する entry を返す。
→ Association | Missing["NotFound"]
Options: "Channel" -> "public", "AllowSeed" -> True

### ClaudeResolveModel[provider, intent] → Association
SourceVaultResolve["Model", ...] の互換 wrapper。例: `ClaudeResolveModel["anthropic", "heavy"]`

### SourceVaultListModels[provider] → List
指定 provider の選択可能な全モデル ID リスト。Availability が Unavailable のエントリは除外。

### SourceVaultListRegistries[opts] → List
登録済み registry topic と channel を返す。
Options: "Channel" -> All ("public" | "private" | All)

### SourceVaultRegistryStatus[topic, opts] → Association
指定 topic の registry 状態 (CompiledPath, CompiledExists, CompiledCount, SeedPath, SeedExists, SeedCount, LastModified)。
Options: "Channel" -> "public"

### SourceVaultCompileRegistry[topic, entries, opts]
entries (List of Association) を compiled registry に保存。
→ Association
Options: "Channel" -> "public", "Sources" -> {} (関連 claim/snapshot id), "PolicySource" -> _String

### SourceVaultRegisterSeed[topic, entries] → Association
seed entries を seeds/<topic>-seed.json に保存 (bootstrap 用)。

## Stage 1.5 / 2 / 4A: Ingest

### SourceVaultIngest[source, opts]
外部 source を登録し raw snapshot を PrivateVault に保存。Local file path / HTTPS URL / `arXiv:NNNN.NNNNN[vN]` をサポート。
→ Association (Status: Ingested/AlreadyCurrent/RebuiltMetadata/Queued)
Options: Topic -> Automatic, TrustLevel -> Automatic ("OfficialAPI" | "OfficialDocs" | "PublicWeb" | "LocalFile"), PrivacyLabel -> Automatic, PinVersion -> Automatic, Asynchronous -> False (True で LLMGraphDAGCreate 経由・JobId 即時 return), EnsureUUID -> Automatic (.nb 取り込み時の UUID 自動付与)

### SourceVaultIngestWait[ingestResult, timeoutSec] → Association
非同期 ingest 完了を待つ。timeoutSec デフォルト 60。Status: Queued なら polling し、新規 snapshot 出現で完了。Timeout 時は Status: Timeout。第一引数は SourceVaultIngest 結果 Association または SourceId String。

## Stage 4B: PDF Page Extraction

### SourceVaultExtractPages[snapshot, pages, opts]
snapshot の指定 page を抽出し cache に保存。snapshot は SnapshotId / SourceId String、pages は Integer / List / All。
→ `<|"Status", "SnapshotId", "Pages" -> {n -> text, ...}, "Hashes", "CachedFrom" -> "Disk"|"Fresh"|"Mixed", "OCRCalled"|>`
Options: Force -> False (cache 無視して再抽出), "ForceOCR" -> False (この呼出だけ OCR 強制実行、Force も自動適用)

### $SourceVaultOCRHook
型: None | Function
初期値: None
スキャン PDF の fallback。シグネチャ `Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String`。

### $SourceVaultOCRMode
型: String
初期値: "Auto"
OCR 発火モード。"Auto" は Plaintext 抽出結果が 5 文字未満時のみ OCR、"Force" は常に OCR。

### $SourceVaultOCRVerbose
型: Boolean
初期値: False
OCR 実行時の進捗 Print を制御。

## Stage 4C: OCR Backends

### SourceVaultOCREnable[backend, opts]
OCR hook を有効化。backend デフォルト "ClaudeVision"。
→ `<|"Status" -> "Enabled", "Backend", "Mode", "Options"|>`
Options ("ClaudeVision"): "DPI" -> 300, "SplitHalves" -> True, "Timeout" -> 180, "Prompt" -> Automatic
Options ("TextRecognize"): "DPI" -> 150, "Language" -> "Japanese"
Options ("Custom"): "Hook" -> Function[req, text]
共通: "Mode" -> "Auto" ("Auto" | "Force"), "Verbose" -> False

### SourceVaultOCRDisable[]
OCR hook を無効化 ($SourceVaultOCRHook = None)。

### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定 (Backend: Disabled/ClaudeVision/TextRecognize/Custom, HookSet, Mode, Options)。

## Stage 5: Claim Extraction

### SourceVaultExtract[sourceSpan, schema, opts]
sourceSpan の page text を LLM に渡して claim を抽出。sourceSpan は SourceVaultSpan 結果 / SnapshotId / SourceId String。schema は登録名 String または Association。
→ `<|"Claims", "Count", "ExtractedCount", "DedupSkipped", "AccessDecisions" -> <|"Send", "Persist"|>, "ValidationStatus", "SchemaName", "ExtractedAt", "Errors"|>`
Deny 時: `<|"Status" -> "DeniedByNBAccess", "Reason", "AccessDecisions"|>`
RequireApproval 時: `<|"Status" -> "RequiresApproval", ...|>`
Options: "Topic" -> Automatic (デフォルト schema 名), "ModelIntent" -> "extraction" ("summary" | "extraction" | "math-extraction-heavy"), "StoreClaims" -> True, "Dedup" -> True (by-source 単位 ContentHash 照合), "AuthorizationCheck" -> True (2 段階 NBAuthorize), "Validation" -> "None" ("None" | "Required"), MaxCharacters -> 8000, Timeout -> 180

### SourceVaultRegisterSchema[name, definition] → Association
抽出 schema をグローバルに登録。definition は `<|"Description", "Fields" -> {<|"Name", "Type", "Required", "Description"|>, ...}, "OutputShape" -> "List"|"Single", "PromptTemplate" -> Automatic|_String|>`。ビルトイン: "FreeText" / "NumericFacts" / "DefinitionList"。

### SourceVaultClaim[claimId] → Association | Missing["NotFound"]
指定 claim の Association。

### SourceVaultClaimsForSource[sourceIdOrSnapshotId] → List
指定 source に紐づく claim リスト。

### SourceVaultClaimsForTopic[topic] → List
指定 topic に紐づく claim リスト。

### SourceVaultListSchemas[] → List
登録済み schema 名リスト。

### SourceVaultGetSchema[name] → Association
登録済み schema 定義。

### SourceVaultClaimStoreStatus[] → Association
ClaimStore の状態 (ClaimsDir, MasterPath, MasterExists, MasterClaims, TopicFiles, SourceFiles)。

### SourceVaultClaimStoreCompact[opts]
master + by-topic + by-source を全読みし ContentHash で dedup して rebuild。atomic rewrite。
→ `<|"Status", "BeforeCount", "AfterCount", "Removed", "BackupPaths", "DryRun"|>`
Options: "Backup" -> True (.bak.<timestamp>), "DryRun" -> False

## Stage 6c: Evidence Bundle

### SourceVaultBundleCreate[name, deps, opts]
generated artifact の依存を evidence bundle として保存。deps は `<|"GeneratedFiles", "Sources" -> {<|"SourceId", "SnapshotId"|>, ...}, "SourceSpans", "Claims", "Generator" -> <|"Tool", "WorkflowId", "ModelIntent", "ResolvedModel"|>|>`。
→ `<|"Status", "BundleId", "Path"|>`
Options: "Kind" -> _String ("SimulationExample" | "LaTeXExport" | "DocumentGeneration" | "CodeGeneration" | "Notebook" | _String)

### SourceVaultBundleGet[bundleId] → Association | Missing["NotFound"]
指定 bundle を読み込み。

### SourceVaultBundleList[] → List
全 bundle id リスト。

### SourceVaultBundleStatus[bundleId] → Association
bundle の現在 Status (参照する snapshot の LifecycleStatus を集約)。`<|"Status" -> "Current"|"Stale"|"NeedsReview"|"Invalidated", "Reason", "AffectedSnapshots", "AffectedClaims"|>`

### SourceVaultBundleInvalidate[bundleId, reason]
bundle を手動で invalidate する。

### SourceVaultBundleDelete[bundleId]
bundle ファイルを削除 (debug 用)。

## Stage 8: Snapshot Lifecycle / vN Diff

### SourceVaultDiffVersions[v1Snap, v2Snap] → Association
2 snapshot の page hash 集合を比較。`<|"Status", "V1Snap", "V2Snap", "AddedPages", "RemovedPages", "ChangedPages", "UnchangedPages"|>`

### SourceVaultMarkSnapshotStale[snapshotId, reason]
snapshot の LifecycleStatus を "Stale" に更新し events/source-events.jsonl に VersionedUpdate event を記録。

### SourceVaultMarkSnapshotInvalidated[snapshotId, reason]
snapshot の LifecycleStatus を "Invalidated" に更新。Retraction 用途。

### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason] → Association
高レベル refresh API。diff 計算 + old を Stale 化 + SupersededBy 設定 + event 記録。`<|"Status", "Diff", "Event"|>`

### SourceVaultBundlesForSnapshot[snapshotId] → List
指定 snapshot を参照する全 bundle id。

### SourceVaultSourceEvents[opts] → List
events/source-events.jsonl の全 event リスト。
Options: "SourceId" -> _String, "SnapshotId" -> _String, "EventType" -> _String ("VersionedUpdate" | "Retraction" | "SourceDeletion" | "SchemaChange")

### SourceVaultSourceEventAppend[event]
event Association を append。EventType / SourceId / Reason 必須。EventId と Timestamp は自動生成。

## Stage 9 P0: Notebook Management

### SourceVaultRegisterNotebook[path] → Association
notebook を SourceVault に登録。NotebookRef は path-based hash で安定生成。`<|"Status", "NotebookRef", "Path", "RegisteredAt"|>`

### SourceVaultIndexNotebook[path, opts]
notebook の Header / Todo / Cell を抽出し index 更新。
→ `<|"Status", "NotebookRef", "SnapshotId", "Header", "TodoCount", "OpenTodoCount", "ReviewState", "DeadlineState", "Lint"|>`
Options: "ExtractHeader" -> True, "ExtractTodos" -> True, "ForceReindex" -> False (file mtime 同じなら skip)

### SourceVaultIndexNotebookFolder[dir, opts]
folder 配下の全 .nb を index。
→ `<|"Status", "Processed", "Failed", "Results"|>`
Options: "Recursive" -> False, "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}

### SourceVaultExtractNotebookHeader[path] → Association
先頭 Input セルから Header Association を safe parse (HoldComplete + whitelist)。`<|"ParseStatus" -> "OK"|"MissingHeader"|"UnsafeExpression", "Keywords", "Deadline", "NextReview", "Status"|>`

### SourceVaultExtractNotebookTodos[path] → List
TodoItem スタイルセルを列挙。Status 判定: TaggingRules > StrikeThrough+FontColor > Default。`{<|"Text", "Status" -> "Open"|"Done"|"Pass", "StatusSource", "StrikeThrough"|>, ...}`

### SourceVaultFindNotebooks[opts] → List
index 済み notebook を deterministic 検索。`{<|NotebookRef, OriginalPath, Title, Header, ReviewState, ...|>, ...}`
Options: "OpenTodos" -> _Bool, "NextReview" -> "Overdue"|"ThisWeek"|"DueSoon"|<|"From", "To"|>, "Deadline" -> 同上, "Keywords" -> {_String, ...} (いずれかに match), "Status" -> _String

### SourceVaultNotebookLint[record] → List
notebook record (または path) に対して lint。検出: MissingHeader / UnsafeHeaderExpression / HeaderDeadlineMalformed / HeaderNextReviewMalformed / HeaderStatusTodoButNoOpenTodos / HeaderStatusDoneButOpenTodosExist / DeadlinePast / NextReviewPast / TodoCellStatusHeuristicOnly。

## Stage 9 P1: Extended Notebook Management

### SourceVaultExtractNotebookTaggingRules[path] → Association
notebook 全体および各 TodoItem cell の TaggingRules を取得。`Import[path, "Notebook"]` + `NotebookImport[path, style -> "Cell"]` 経由。
`<|"Status", "Path", "NotebookTaggingRules", "CellTaggingRules" -> {<|"Index", "CellStyle", "TaggingRules"|>, ...}|>`

### SourceVaultNotebookSemanticHash[path] → Association
意味的内容のみを対象にしたハッシュ。表示メタデータ (ExpressionUUID / CellChangeTimes / CellLabel / FontFamily / WindowSize 等) を除外し、content / style / TaggingRules / FontVariations / FontColor / Background をハッシュ対象とする。`<|"Status", "Path", "SemanticHash"|>`

### SourceVaultRegisterNotebookSummary[path, summary, opts]
summary artifact を登録。現在の snapshot (SnapshotId + SemanticHash) と紐づけて保存。
→ `<|"Status", "SummaryId", "NotebookRef", ...|>`
Options: "SummaryFormat" -> "text" ("text" | "markdown"), "GeneratedBy" -> "manual"

### SourceVaultGetNotebookSummary[path] → Association
notebook に紐づく summary record。`<|"Status" -> "OK"|"Missing"|"Failed", "Summary", "SummaryFormat", "BasedOnSnapshot", "BasedOnSemanticHash", "GeneratedBy", "CreatedAt"|>`

### SourceVaultNotebookSummaryStatus[path] → Association
summary artifact の lifecycle 判定。`<|"Status" -> "Missing"|"Current"|"StaleFormattingOnly"|"Stale", "Reason", "CurrentSnapshot", "SummaryBasedOnSnapshot"|>`

### SourceVaultNotebookSummary[path, opts]
notebook 内容を LLM で要約し Summary artifact として保存。Step 4 の Register を内部で呼ぶため lifecycle 管理は自動。デフォルト PrivacyLevel -> 1.0 (ローカル LM 経由、cloud API に送らない)。
→ Association (Register と同形)。Current で ForceRefresh 無しなら既存 record。Inconsistent 時: `<|"Status" -> "Inconsistent", "Reason", ...|>`。失敗時: `<|"Status" -> "Failed", "Reason", ...|>`。
Options: "ForceRefresh" -> False, "MaxLength" -> 500, "Language" -> Automatic (Automatic | "Japanese" | "English"), "Model" -> Automatic ({provider, model} 明示指定可), "PrivacyLevel" -> 1.0 (0.0 API 許可 〜 1.0 ローカルのみ), "FallbackToCloud" -> "Ask" ("Ask" | "Allow" | "Deny")

### SourceVaultMarkTodo[path, target, newStatus, opts]
notebook 内の Todo cell の Status を変更 (NBWriteTodoStatus への薄ラッパー)。target は Integer (1-based Index) / String (TodoId) / Association (`<|"Index", "Text"|>`)。newStatus は "Open" / "Done" / "Pass"。
→ DryRun: `<|"Status" -> "DryRunOK", "Target", "MatchedTodo", "OldStatus", "NewStatus", "CellPath", "Before", "After"|>`
→ 実行: `<|"Status" -> "OK"|"Failed", "Target", "MatchedTodo", "OldStatus", "NewStatus", "ReindexResult"|>`
Options: "DryRun" -> True (安全側), "AutoReindex" -> True (実行時のみ), "AccessSpec" -> `<|"AccessLevel" -> 0.7, ...|>`

### SourceVaultUpcomingSchedule[opts] → Dataset
「今日から N 日以内」に Deadline / NextReview がある notebook 一覧。列: Deadline, NextReview, Title (Open button), Dir (Open button), OpenTodos, Status, Privacy。期限切れは赤、今日/明日は青。
Options: "Scope" -> $onWork (default), "Period" -> Quantity[7, "Days"], "IncludeOverdue" -> True, "Recursive" -> True, "Refresh" -> "IfStale" ("Never" | "IfStale" | "Force"), "FallbackToCloud" -> "Ask", "StatusFilter" -> {"Todo"} (All も可), "UseCache" -> True

### SourceVaultRefreshAllSummaries[opts]
Scope 配下全 notebook の概要を一括再生成。
→ `<|"Status", "Scope", "TotalFiles", "Refreshed", "Cached", "Inconsistent", "Failed", "Details"|>`
Options: "Scope" -> $onWork, "Recursive" -> True, "ForceRefresh" -> False, "FallbackToCloud" -> "Deny" (一括時推奨)

### SourceVaultResetStore[opts]
notebooks ストア (sources / snapshots / summaries / todos / review / lint / sync / relink) を全削除して初期化。破壊的操作のため明示承認必要。
Options: "Confirm" -> True (必須)