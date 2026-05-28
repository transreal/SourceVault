# SourceVault API リファレンス

外部 source 管理パッケージ。物理ストレージは PrivateVault (authoritative) / CloudMirror / Tmp / AttachmentMirror の 4 tier。依存: [NBAccess](https://github.com/transreal/NBAccess)。

## Bootstrap / 設定

### $SourceVaultVersion
型: String
パッケージバージョン文字列。

### $SourceVaultRoots
型: Association
物理 root ディレクトリマッピング。Keys: "PrivateVault" | "CloudMirror" | "Tmp" | "AttachmentMirror" | "ExternalOwned"。PrivateVault が authoritative storage で cloud LLM には直接読ませない。

### $SourceVaultSeedModelRegistry
型: Association
bootstrap 時の fallback model registry。compiled registry がない場合の災害復旧用 fallback。

### SourceVaultInitialize[opts]
物理 root を生成して初期化。作成済みなら noop。
→ Association
Options: "Roots" -> $SourceVaultRoots (override), "Force" -> False (True で再初期化)

### SourceVaultStatus[sourceRef] / SourceVaultStatus[] → Association
指定 source / snapshot / ファイルの概要。引数なしで vault 全体概要。

### SourceVaultList[] → {String...}
vault 内の全 source ID リスト。

### SourceVaultSnapshots[sourceRef] → {String...}
指定 source の snapshot ID リスト。

## Stage 1: Lookup / Resolve

### SourceVaultResolve[kind, query, opts]
compiled registry から query に match する entry を返す。Availability != "Unavailable" を filter し Class/Freshness で sort して先頭返却。
→ Association | Missing["NotFound"]
Options: "Channel" -> "public" ("public"|"private"), "AllowSeed" -> True, "Topic" -> Automatic
例: SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]

### SourceVaultLookup[topic, key, opts]
compiled registry の単純キー引き。
→ Association | Missing["NotFound"]
Options: "Channel" -> "public", "AllowSeed" -> True

### ClaudeResolveModel[provider, intent] → Association
SourceVaultResolve["Model", ...] の互換 wrapper。旧 WikiDBResolveModel 置換用。

## Stage 1.5 / 2: Ingest

### SourceVaultIngest[source, opts]
外部 source を登録し raw snapshot を PrivateVault に保存。Local file path / HTTPS URL / arXiv:NNNN.NNNNN[vN] に対応。
→ Association
Options:
- Topic -> Automatic | _String
- TrustLevel -> Automatic | "OfficialAPI" | "OfficialDocs" | "PublicWeb" | "LocalFile"
- PrivacyLabel -> Automatic | _Real
- PinVersion -> Automatic | True | False
- Asynchronous -> False (True で LLMGraphDAGCreate 経由非同期投入し JobId 即時 return)
- EnsureUUID -> Automatic | True | False (.nb 取り込み時の UUID 自動付与)

### SourceVaultIngestWait[ingestResult, timeoutSec]
非同期 ingest の完了を待つ。Status: Queued なら snapshot 増加を polling。
→ Association ("Status": Ingested/AlreadyCurrent/RebuiltMetadata/Timeout)

## Stage 4 Phase 4B: PDF page extraction

### SourceVaultExtractPages[snapshot, pages, opts]
snapshot の指定 page を抽出し cache に保存。SHA-256 page hash を page-hashes.json に保存。空 or 5 文字未満時に $SourceVaultOCRHook を呼ぶ。
→ <|"Status", "SnapshotId", "Pages" -> <|n -> text, ...|>, "Hashes", "CachedFrom" -> "Disk"|"Fresh"|"Mixed", "OCRCalled" -> _Bool|>
Options:
- Force -> False (cache 無視して再抽出)
- "ForceOCR" -> False (この呼出だけ OCR 強制、cache バイパス。Force も自動 True)

### $SourceVaultOCRHook
型: None | Function, 初期値: None
スキャン PDF の fallback。Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String 形。SourceVaultOCREnable 経由設定推奨。

### $SourceVaultOCRMode
型: String, 初期値: "Auto"
"Auto" (5 文字未満時のみ OCR) | "Force" (常時 OCR)。

### $SourceVaultOCRVerbose
型: Boolean, 初期値: False
OCR 実行時の進捗 Print 制御。

## Stage 4 Phase 4C: OCR backends

### SourceVaultOCREnable[backend, opts]
OCR hook を有効化。
→ <|"Status" -> "Enabled", "Backend", "Mode", "Options"|>
backend: "ClaudeVision" (default) | "TextRecognize" | "Custom"
Options:
- "DPI" -> 300 (ClaudeVision) / 150 (TextRecognize)
- "SplitHalves" -> True (ClaudeVision で 30px overlap 上下分割)
- "Timeout" -> 180
- "Prompt" -> Automatic
- "Language" -> "Japanese" (TextRecognize)
- "Hook" -> Function (Custom 時に $SourceVaultOCRHook 設定)
- "Mode" -> "Auto" | "Force"

### SourceVaultOCRDisable[]
$SourceVaultOCRHook = None。

### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定。Backend: Disabled/ClaudeVision/TextRecognize/Custom + HookSet。

## Stage 5: Claim extraction

### SourceVaultExtract[sourceSpan, schema, opts]
sourceSpan の page text を LLM に渡して claim 抽出。AuthorizationCheck -> True 時に sendDecision → context 取得 → LLM 抽出 → persistDecision の 3 段。
→ <|"Claims", "Count", "ExtractedCount", "DedupSkipped", "AccessDecisions", "ValidationStatus", "SchemaName", "ExtractedAt", "Errors"|> / <|"Status" -> "DeniedByNBAccess"|"RequiresApproval", "Reason", "AccessDecisions"|>
Options:
- "Topic" -> _String
- "ModelIntent" -> "summary" | "extraction" | "math-extraction-heavy"
- "StoreClaims" -> True
- "Dedup" -> True (by-source ContentHash 照合)
- "AuthorizationCheck" -> True (Stage 6d: 2 段階 NBAuthorize)
- "Validation" -> "None" | "Required"
- MaxCharacters -> 8000
- Timeout -> 180

### SourceVaultRegisterSchema[name, definition] → Association
抽出 schema をグローバル登録。definition は <|"Description", "Fields" -> {<|"Name", "Type", "Required", "Description"|>...}, "OutputShape" -> "List"|"Single", "PromptTemplate" -> Automatic|_String|>。
ビルトイン: "FreeText", "NumericFacts", "DefinitionList"。

### SourceVaultClaim[claimId] → Association | Missing["NotFound"]
指定 claim を取得。

### SourceVaultClaimsForSource[sourceIdOrSnapshotId] → {Association...}
指定 source に紐づく claim リスト。

### SourceVaultClaimsForTopic[topic] → {Association...}
指定 topic に紐づく claim リスト。

### SourceVaultListSchemas[] → {String...}
登録済み schema 名リスト。

### SourceVaultGetSchema[name] → Association
登録済み schema 定義。

### SourceVaultClaimStoreStatus[] → Association
ClaimStore の状態 (debug 用)。Keys: ClaimsDir/MasterPath/MasterExists/MasterClaims/TopicFiles/SourceFiles。

### SourceVaultClaimStoreCompact[opts]
master + by-topic + by-source を ContentHash で dedup して rebuild。atomic rewrite (tmp → rename)。
→ <|"Status", "BeforeCount", "AfterCount", "Removed", "BackupPaths", "DryRun"|>
Options: "Backup" -> True (.bak.<timestamp>), "DryRun" -> False

## Stage 6c: Evidence Bundle

### SourceVaultBundleCreate[name, deps, opts]
generated artifact の依存を evidence bundle として保存。
→ <|"Status", "BundleId", "Path"|>
deps: <|"GeneratedFiles" -> {...}, "Sources" -> {<|"SourceId", "SnapshotId"|>...}, "SourceSpans", "Claims", "Generator" -> <|"Tool", "WorkflowId", "ModelIntent", "ResolvedModel"|>|>
Options: "Kind" -> "SimulationExample" | "LaTeXExport" | "DocumentGeneration" | "CodeGeneration" | "Notebook" | _String

### SourceVaultBundleGet[bundleId] → Association | Missing["NotFound"]
指定 bundle を読み込み返却。

### SourceVaultBundleList[] → {String...}
全 bundle id リスト。

### SourceVaultBundleStatus[bundleId] → Association
参照 snapshot の LifecycleStatus を集約。
→ <|"Status" -> "Current"|"Stale"|"NeedsReview"|"Invalidated", "Reason", "AffectedSnapshots", "AffectedClaims"|>

### SourceVaultBundleInvalidate[bundleId, reason]
bundle を手動で invalidate。

### SourceVaultBundleDelete[bundleId]
bundle ファイル削除 (debug 用)。

## Stage 8: vN diff + snapshot lifecycle

### SourceVaultDiffVersions[v1Snap, v2Snap]
2 つの snapshot の page hash 集合を比較。
→ <|"Status", "V1Snap", "V2Snap", "AddedPages" -> {_Integer...}, "RemovedPages", "ChangedPages", "UnchangedPages"|>

### SourceVaultMarkSnapshotStale[snapshotId, reason]
snapshot meta の LifecycleStatus を "Stale" に更新し source-events.jsonl に VersionedUpdate event 記録。

### SourceVaultMarkSnapshotInvalidated[snapshotId, reason]
LifecycleStatus を "Invalidated" に更新。Bundle 側は "Invalidated" を返すようになる。

### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason]
高レベル refresh API: diff 計算 → old を Stale + SupersededBy 設定 → event 記録。
→ <|"Status", "Diff", "Event"|>

### SourceVaultBundlesForSnapshot[snapshotId] → {String...}
指定 snapshot を参照する全 bundle id リスト。

### SourceVaultSourceEvents[opts] → {Association...}
events/source-events.jsonl の全 event。
Options: "SourceId" -> _String, "SnapshotId" -> _String, "EventType" -> "VersionedUpdate"|"Retraction"|"SourceDeletion"|"SchemaChange"

### SourceVaultSourceEventAppend[event] → Association
event Association を append。EventType / SourceId / Reason 必須。EventId / Timestamp は自動。

## Stage 6b: Compiled Registry

### SourceVaultListModels[provider] → {String...}
指定 provider の選択可能な全モデル ID リスト。compiled registry を優先、なければ seed fallback。Unavailable は除外。

### SourceVaultListRegistries[opts] → Association
登録済み registry topic と channel。
Options: "Channel" -> "public" | "private" | All

### SourceVaultRegistryStatus[topic, opts] → Association
指定 topic の registry 状態。
→ <|"Topic", "Channel", "CompiledPath", "CompiledExists", "CompiledCount", "SeedPath", "SeedExists", "SeedCount", "LastModified"|>
Options: "Channel" -> "public" | "private"

### SourceVaultCompileRegistry[topic, entries, opts]
entries を compiled registry に保存。
→ <|"Status", "Topic", "Channel", "Path", "Count"|>
Options: "Channel" -> "public", "Sources" -> {_String...}, "PolicySource" -> _String

### SourceVaultRegisterSeed[topic, entries] → Association
seed entries を seeds/<topic>-seed.json に保存 (bootstrap 用)。

## Stage 9: Notebook Management (P0)

### SourceVaultRegisterNotebook[path] → Association
notebook を SourceVault に登録。NotebookRef は path-based hash で安定生成。
→ <|"Status", "NotebookRef", "Path", "RegisteredAt"|>

### SourceVaultIndexNotebook[path, opts]
Header / Todo / Cell を抽出して index 更新。
→ <|"Status", "NotebookRef", "SnapshotId", "Header", "TodoCount", "OpenTodoCount", "ReviewState", "DeadlineState", "Lint"|>
Options:
- "ExtractHeader" -> True
- "ExtractTodos" -> True
- "ForceReindex" -> False (file mtime 同じなら skip)

### SourceVaultIndexNotebookFolder[dir, opts]
指定 folder 配下の .nb を一括 index。
→ <|"Status", "Processed", "Failed", "Results"|>
Options: "Recursive" -> False, "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}

### SourceVaultExtractNotebookHeader[path] → Association
先頭 Input セルから Header を safe parse (HoldComplete + whitelist で RunProcess/Get/Import 拒否)。
→ <|"ParseStatus" -> "OK"|"MissingHeader"|"UnsafeExpression", "Keywords", "Deadline", "NextReview", "Status"|>

### SourceVaultExtractNotebookTodos[path] → {Association...}
TodoItem スタイルセルを列挙。Status: Open / Done / Pass。判定優先順: TaggingRules > FontVariations StrikeThrough + FontColor > Default。
→ {<|"Text", "Status", "StatusSource", "StrikeThrough"|>...}

### SourceVaultFindNotebooks[opts] → {Association...}
index 済 notebook を deterministic 検索。
Options:
- "OpenTodos" -> True | False
- "NextReview" -> "Today" | "Overdue" | "ThisWeek" | "DueSoon" | <|"From", "To"|>
- "Deadline" -> "Today" | "Overdue" | "ThisWeek" | "DueSoon" | <|"From", "To"|>
- "Keywords" -> {_String...} | _String (Header.Keywords + Title + FileBaseName + 親フォルダ名、OR 部分一致)
- "Title" -> _String | {_String...} (エイリアス)
- "Status" -> "Todo" | "Done" | _String
- "Scope" -> "Today" (NextReview/Deadline/Path内 YYYYMMDD の OR)
- "Format" -> False (True で SourceVaultFormatNotebookList Grid)

### SourceVaultNotebookLint[record] → {String...}
notebook record (または path) に lint チェック。
検出 lint: MissingHeader / UnsafeHeaderExpression / HeaderDeadlineMalformed / HeaderNextReviewMalformed / HeaderStatusTodoButNoOpenTodos / HeaderStatusDoneButOpenTodosExist / DeadlinePast / NextReviewPast / TodoCellStatusHeuristicOnly

## Stage 9 P1 Step 1: TaggingRules 標準化

### SourceVaultExtractNotebookTaggingRules[path] → Association
notebook 全体および各 TodoItem cell の TaggingRules を取得 (Import["Notebook"] + NotebookImport["Cell"])。
→ <|"Status" -> "OK"|"Failed", "Path", "NotebookTaggingRules" -> _Association, "CellTaggingRules" -> {<|"Index", "CellStyle", "TaggingRules"|>...}|>

## Stage 9 P1 Step 2: NotebookSemanticHash

### SourceVaultNotebookSemanticHash[path] → Association
表示メタデータ (ExpressionUUID/CellChangeTimes/CellLabel/FontFamily 等) およびウィンドウ設定を除外し、意味要素 (content/style/TaggingRules/FontVariations/FontColor/Background) のみ Hash。
→ <|"Status" -> "OK"|"Failed", "Path", "SemanticHash" -> _String|>

## Stage 9 P1 Step 4: Summary artifact stale 判定

### SourceVaultRegisterNotebookSummary[path, summary, opts]
notebook の summary artifact を登録。現 snapshot (SnapshotId + SemanticHash) と紐付け。
→ <|"Status" -> "OK"|"Failed", "SummaryId", "NotebookRef", ...|>
Options: "SummaryFormat" -> "text" ("text"|"markdown"), "GeneratedBy" -> "manual"

### SourceVaultGetNotebookSummary[path] → Association
notebook に紐付く summary record 取得。
→ <|"Status" -> "OK"|"Missing"|"Failed", "Summary", "SummaryFormat", "BasedOnSnapshot", "BasedOnSemanticHash", "GeneratedBy", "CreatedAt"|>

### SourceVaultNotebookSummaryStatus[path] → Association
summary artifact の lifecycle status。
→ <|"Status" -> "Missing"|"Current"|"StaleFormattingOnly"|"Stale", "Reason", "CurrentSnapshot", "SummaryBasedOnSnapshot"|>

## Stage 9 P1 Step 5: LLM 要約

### SourceVaultNotebookSummary[path, opts]
notebook 内容を LLM 要約し Summary artifact として保存。内部で Step 4 Register を呼ぶ。プライバシー: 既定 PrivacyLevel -> 1.0 (ローカル LM)。
→ Current で ForceRefresh なし: 既存 record / 成功: Register 同形 / Inconsistent: <|"Status" -> "Inconsistent", "Reason", ...|> / 失敗: <|"Status" -> "Failed", "Reason"|>
Options:
- "ForceRefresh" -> False
- "MaxLength" -> 500
- "Language" -> Automatic | "Japanese" | "English"
- "Model" -> Automatic | {"provider", "model"}
- "PrivacyLevel" -> 1.0 (0.0 で API 許可)
- "FallbackToCloud" -> "Ask" | "Allow" | "Deny"

## Stage 9 P1 Step 6: SourceVaultMarkTodo

### SourceVaultMarkTodo[path, target, newStatus, opts]
notebook 内 Todo cell の Status 変更。NBAccess の NBWriteTodoStatus への薄いラッパー。Cell options (FontVariations StrikeThrough + FontColor) と TaggingRules (<|"SourceVault" -> <|"TodoStatus" -> newStatus|>|>) を更新。
target: Integer (1-based) | String (TodoId) | Association (<|"Index", "Text"|>)
newStatus: "Open" | "Done" | "Pass"
→ DryRun: <|"Status" -> "DryRunOK", "Target", "MatchedTodo", "OldStatus", "NewStatus", "CellPath", "Before" -> HoldComplete[...], "After" -> HoldComplete[...]|>
→ 実行: <|"Status" -> "OK"|"Failed", "Target", "MatchedTodo", "OldStatus", "NewStatus", "ReindexResult"|>
Options:
- "DryRun" -> True (安全側既定)
- "AutoReindex" -> True (実行時のみ)
- "AccessSpec" -> <|"AccessLevel" -> 0.7, ...|>

## Stage 9 P1 Step 3: Upcoming Schedule / 表示ヘルパー

### SourceVaultUpcomingSchedule[opts]
「今日から N 日以内」に Deadline / NextReview がある notebook 一覧を Dataset で返す。期限切れは赤、今日または明日は青。
→ Dataset (列: Deadline, NextReview, Title (Open button), Dir (Open button), OpenTodos, Status, Privacy)
Options:
- "Scope" -> dir (default $onWork または $packageDirectory)
- "Period" -> Quantity[7, "Days"]
- "IncludeOverdue" -> True
- "Recursive" -> True
- "Refresh" -> "Never" | "IfStale" | "Force"
- "FallbackToCloud" -> "Ask" | "Allow" | "Deny"
- "StatusFilter" -> {"Todo"} | {"Todo","Done","Pass"} | All
- "UseCache" -> True

### SourceVaultFormatNotebookList[records, opts]
notebook record の List をスケジュール表と同形式 (Deadline / NextReview / Title (Open button) / Dir (Open button) / OpenTodos / Status / Summary / Publishable) で Grid 表示。
→ Grid
Options:
- "Refresh" -> "Never" | "IfStale" | "Force"
- "FallbackToCloud" -> "Deny"
- "UseCache" -> True

### SourceVaultRefreshAllSummaries[opts]
Scope 配下全 notebook の概要を一括再生成。
Options:
- "Scope" -> dir (default $onWork)
- "Recursive" -> True
- "ForceRefresh" -> False
（他オプションは出力末尾切り詰めのため正本 source を参照）

## 関連パッケージ

- [NBAccess](https://github.com/transreal/NBAccess) — Notebook アクセス / NBAuthorize 提供 (依存必須)
- [claudecode](https://github.com/transreal/claudecode) — ClaudeQuerySync / LLMGraphDAGCreate / ClaudeQueryBg 提供
- [PDFIndex](https://github.com/transreal/PDFIndex) — ClaudeVision OCR の実証元パターン
- [SourceVault_promptrouter](https://github.com/transreal/SourceVault_promptrouter) — prompt routing 拡張