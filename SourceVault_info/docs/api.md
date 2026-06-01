# SourceVault API リファレンス

外部 source 管理パッケージ。PDF/URL/arXiv/notebook の ingest、page 抽出、OCR、claim 抽出、evidence bundle、compiled registry、notebook 管理を提供する。依存: [NBAccess](https://github.com/transreal/NBAccess)（NBAuthorize を毎回呼ぶ）、claudecode（ClaudeQuerySync / ClaudeQueryBg / LLMGraphDAGCreate）。

物理ストレージ tier: PrivateVault（authoritative 正本、Dropbox 配下）/ CloudMirror / Tmp / AttachmentMirror。PrivateVault は cloud LLM に直接読ませない。

## Bootstrap / Configuration

### $SourceVaultVersion
型: String
パッケージのバージョン文字列。

### $SourceVaultRoots
型: Association, Keys: "PrivateVault" | "CloudMirror" | "Tmp" | "AttachmentMirror" | "ExternalOwned"
物理 root ディレクトリのマッピング。PrivateVault が authoritative storage。CloudMirror/AttachmentMirror は materialize 済み projection のみ。

### $SourceVaultSeedModelRegistry
型: Association
bootstrap 時の fallback model registry。production truth ではなく、compiled registry が無い場合の災害復旧用。LLM 自動更新しない。

### SourceVaultInitialize[opts]
物理 root を生成して初期化する。PrivateVault, Tmp は必須。作成済みなら noop。
→ Association
Options: "Roots" -> $SourceVaultRoots (override), "Force" -> False (True で再初期化)

### SourceVaultStatus[sourceRef] → Association
指定 source/snapshot/ファイルの概要を返す。引数なし SourceVaultStatus[] は vault 全体の概要。

### SourceVaultList[] → {sourceId, ...}
vault 内の全 source ID リスト。

### SourceVaultSnapshots[sourceRef] → {snapshotId, ...}
指定 source の snapshot ID リスト。

## Ingest (Stage 1.5 / 2 / 4A)

### SourceVaultIngest[source, opts]
外部 source を登録し raw snapshot を PrivateVault に保存。source はローカルファイルパス / HTTP(S) URL / arXiv:NNNN.NNNNN[vN]。
→ Association（Status: Ingested/AlreadyCurrent/RebuiltMetadata/Queued など、SourceId/SnapshotId を含む）
Options:
- Topic -> Automatic | _String
- TrustLevel -> Automatic | "OfficialAPI" | "OfficialDocs" | "PublicWeb" | "LocalFile"
- PrivacyLabel -> Automatic | _Real
- PinVersion -> Automatic | True | False
- Asynchronous -> False (True で LLMGraphDAGCreate 経由でジョブ投入し JobId 即時 return。LLMGraphDAGCreate 必須)
- EnsureUUID -> Automatic | True | False (.nb は hash 計算前に SourceVaultEnsureNotebookUUID で UUID 埋込。.nb 以外と巨大ファイル >$SourceVaultMaxFileSizeMB はスキップ)

例: SourceVaultIngest["arXiv:2401.00001", Topic -> "ml", Asynchronous -> True]

### SourceVaultIngestWait[ingestResult, timeoutSec] → Association
非同期 ingest の完了を待つ。第一引数は SourceVaultIngest の結果 Association または SourceId String。sync 完了済みなら即 return。Status: Queued なら snapshot 増加を polling。timeoutSec（既定 60）超過で Status: Timeout。

## PDF Page Extraction (Stage 4B)

### SourceVaultExtractPages[snapshot, pages, opts]
snapshot の指定 page を抽出し cache に保存。snapshot は SnapshotId または SourceId（latest snapshot 使用）。pages は Integer / {Integer...} / All。各 page を parsed/by-snap/<id>/pages/NNNN.txt に cache、page-hashes.json に SHA-256 保存。cache hit 時は Import しない。抽出結果が空 or 5 文字未満なら $SourceVaultOCRHook を呼ぶ。
→ <|"Status", "SnapshotId", "Pages" -> <|n -> text, ...|>, "Hashes" -> <|...|>, "CachedFrom" -> "Disk"|"Fresh"|"Mixed", "OCRCalled" -> _Bool|>
Options:
- Force -> False (cache 無視して再抽出)
- "ForceOCR" -> False (この呼出だけ OCR を強制、スキャン判定をスキップ。hook 設定要。True 時は Force -> True も自動適用)

### $SourceVaultOCRHook
型: None | Function, 初期値: None
スキャン PDF の fallback。シグネチャ Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String。ExtractPages がページテキスト抽出失敗時に呼ばれ、返値文字列が text として cache される。SourceVaultOCREnable 経由設定推奨。

### $SourceVaultOCRMode
型: String, 初期値: "Auto"
OCR 発火モード。"Auto": Plaintext 抽出が 5 文字未満の時のみ OCR。"Force": 常に OCR(低品質テキスト層対策)。

### $SourceVaultOCRVerbose
型: Bool, 初期値: False
True で rasterization / API 呼出 / レスポンス長の進捗を Print。OCR 無音失敗のデバッグ用。

## OCR Backends (Stage 4C)

### SourceVaultOCREnable[backend, opts]
OCR hook を有効化。backend（既定 "ClaudeVision"）: "ClaudeVision" | "TextRecognize" | "Custom"。
→ <|"Status" -> "Enabled", "Backend" -> _String, "Mode" -> _String, "Options" -> _Association|>
共通 Options: "Mode" -> "Auto" | "Force"
- "ClaudeVision": ClaudeCode`ClaudeQueryBg 経由で page 画像を Claude API に送る。大きい page は上下分割(30px overlap)で 2 回 OCR。Options: "DPI" -> 300, "SplitHalves" -> True, "Timeout" -> 180, "Prompt" -> Automatic
- "TextRecognize": Mathematica 組込 TextRecognize。Options: "DPI" -> 150, "Language" -> "Japanese"
- "Custom": ユーザ Function を $SourceVaultOCRHook に設定。Options: "Hook" -> Function[req, text]

例: SourceVaultOCREnable["ClaudeVision", "Mode" -> "Force", "DPI" -> 300]

### SourceVaultOCRDisable[] → Association
OCR hook を無効化($SourceVaultOCRHook = None)。

### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定。Backend: Disabled/ClaudeVision/TextRecognize/Custom、HookSet: _Bool。

## Claim Extraction (Stage 5 / 6a)

### SourceVaultExtract[sourceSpan, schema, opts]
sourceSpan の page text を LLM に渡して claim 抽出。sourceSpan は SourceVaultSpan[...] の結果 / SnapshotId / SourceId。schema は登録済み schema 名 String または インライン定義 Association。
→ <|"Claims" -> {...}, "Count" -> _Integer (実納数), "ExtractedCount" -> _Integer, "DedupSkipped" -> _Integer, "AccessDecisions" -> <|"Send", "Persist"|>, "ValidationStatus", "SchemaName", "ExtractedAt" -> DateObject, "Errors" -> {...}|>
Deny 時: <|"Status" -> "DeniedByNBAccess", "Reason", "AccessDecisions"|>
RequireApproval 時: <|"Status" -> "RequiresApproval", "Reason", "AccessDecisions"|>
Options:
- "Topic" -> _String (既定 schema 名)
- "ModelIntent" -> "summary" | "extraction" | "math-extraction-heavy"
- "StoreClaims" -> True
- "Dedup" -> True (by-source ファイル単位で ContentHash 照合)
- "AuthorizationCheck" -> True (2 段階 NBAuthorize: sendDecision → 抽出 → persistDecision)
- "Validation" -> "None" | "Required"
- MaxCharacters -> 8000
- Timeout -> 180

### SourceVaultRegisterSchema[name, definition] → Association
抽出 schema をグローバル登録。definition は Association:
- "Description" -> _String (LLM 向け説明)
- "Fields" -> {<|"Name", "Type" -> "Number"|..., "Required" -> _Bool, "Description"|>, ...}
- "OutputShape" -> "List" | "Single"
- "PromptTemplate" -> Automatic | _String
ビルトイン: "FreeText", "NumericFacts", "DefinitionList"。

### SourceVaultClaim[claimId] → Association | Missing["NotFound"]
指定 claim の Association。

### SourceVaultClaimsForSource[sourceIdOrSnapshotId] → {claim, ...}
指定 source に紐づく claim リスト。

### SourceVaultClaimsForTopic[topic] → {claim, ...}
指定 topic に紐づく claim リスト。

### SourceVaultListSchemas[] → {name, ...}
登録済み schema 名リスト。

### SourceVaultGetSchema[name] → Association
登録済み schema 定義。

### SourceVaultClaimStoreStatus[] → Association
ClaimStore の状態(debug)。ClaimsDir/MasterPath/MasterExists/MasterClaims/TopicFiles/SourceFiles。

### SourceVaultClaimStoreCompact[opts]
master + by-topic + by-source を全読みし ContentHash で dedup、全インデックス rebuild。atomic rewrite。dedup 記録は最古を残す。
→ <|"Status" -> "OK"|"Failed", "BeforeCount", "AfterCount", "Removed", "BackupPaths" -> {...}, "DryRun"|>
Options: "Backup" -> True (.bak.<timestamp>), "DryRun" -> False (True で統計のみ)

## Evidence Bundle (Stage 6c)

### SourceVaultBundleCreate[name, deps, opts]
generated artifact の依存を evidence bundle として保存。BundleId は自動生成。deps は Association:
- "GeneratedFiles" -> {path, ...}
- "Sources" -> {<|"SourceId", "SnapshotId"|>, ...}
- "SourceSpans" -> {...} (optional)
- "Claims" -> {claimId, ...}
- "Generator" -> <|"Tool", "WorkflowId", "ModelIntent", "ResolvedModel"|>
→ <|"Status" -> "OK"|"Failed", "BundleId", "Path"|>
Options: "Kind" -> "SimulationExample" | "LaTeXExport" | "DocumentGeneration" | "CodeGeneration" | "Notebook" | _String

### SourceVaultBundleGet[bundleId] → Association | Missing["NotFound"]
指定 bundle を読込。

### SourceVaultBundleList[] → {bundleId, ...}
全 bundle id リスト。

### SourceVaultBundleStatus[bundleId] → Association
bundle の現在 Status を計算。参照 snapshot の LifecycleStatus を集約。手動 Invalidate 済みなら強制 "Invalidated"。
→ <|"Status" -> "Current"|"Stale"|"NeedsReview"|"Invalidated", "Reason", "AffectedSnapshots" -> {...}, "AffectedClaims" -> {...}|>

### SourceVaultBundleInvalidate[bundleId, reason] → Association
bundle を手動 invalidate。reason は記録され後で BundleStatus で返る。

### SourceVaultBundleDelete[bundleId] → Association
bundle ファイル削除(debug)。

## vN Diff + Snapshot Lifecycle (Stage 8)

### SourceVaultDiffVersions[v1Snap, v2Snap] → Association
2 snapshot の page hash 集合を比較。各 page-hashes.json を読みページ番号ごとに hash 比較。
→ <|"Status", "V1Snap", "V2Snap", "AddedPages" -> {Integer...}, "RemovedPages", "ChangedPages", "UnchangedPages"|>

### SourceVaultMarkSnapshotStale[snapshotId, reason] → Association
snapshot meta の LifecycleStatus を "Stale" に更新し source-events.jsonl に VersionedUpdate event を記録。参照する Bundle は自動的に "Stale"。

### SourceVaultMarkSnapshotInvalidated[snapshotId, reason] → Association
LifecycleStatus を "Invalidated" に更新。Retraction など参照を不可にしたい時に使う。

### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason]
高レベル refresh: diff 計算 → oldSnap を "Stale" + SupersededBy=newSnap → event 記録(VersionedUpdate)。
→ <|"Status", "Diff" -> _Association, "Event" -> _Association|>

### SourceVaultBundlesForSnapshot[snapshotId] → {bundleId, ...}
指定 snapshot を参照する全 bundle id。全 bundle の Sources[].SnapshotId が一致するものを収集。

### SourceVaultSourceEvents[opts] → {event, ...}
events/source-events.jsonl の全 event リスト。
Options: "SourceId" -> _String, "SnapshotId" -> _String, "EventType" -> "VersionedUpdate" | "Retraction" | "SourceDeletion" | "SchemaChange"

### SourceVaultSourceEventAppend[event] → Association
event Association を source-events.jsonl に append。EventType/SourceId/Reason は必須。OldSnapshotId/NewSnapshotId/Metadata は任意。EventId, Timestamp は自動生成。

## Compiled Registry (Stage 1 / 6b)

### SourceVaultResolve[kind, query, opts]
compiled registry から query に match する entry を返す。network/LLM なし。複数 match 時は Availability != "Unavailable" でフィルタ、Class/Freshness で sort し先頭を返す。
→ entry Association | Missing["NotFound"]
Options: "Channel" -> "public"|"private", "AllowSeed" -> True, "Topic" -> _String (既定 "<kind>-registry" 小文字化)

例: SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]

### SourceVaultLookup[topic, key, opts]
compiled registry から key に対応する entry を返す。topic 例: "model-registry" | "mathematica-graph-options"。key は String または structured query Association。compiled に無ければ seed に fallback。
→ entry Association | Missing["NotFound"]
Options: "Channel" -> "public" (|"private"), "AllowSeed" -> True

### ClaudeResolveModel[provider, intent] → entry Association | Missing
SourceVaultResolve["Model", ...] の互換 wrapper(旧 WikiDBResolveModel 置換)。
例: ClaudeResolveModel["anthropic", "heavy"]

### SourceVaultListModels[provider] → {modelId, ...}
指定 provider の選択可能な全モデル ID リスト(catalog 列挙)。compiled registry 優先、無ければ seed。Availability Unavailable は除外。

### SourceVaultModelContextLength[provider, modelId] → _Integer | None
モデルに紐づく ContextLength。SourceVaultSetModel[..., "ContextLength" -> n] で永続化された値。未設定なら None。

### SourceVaultModelIntegrations[provider, modelId] → {integration, ...} | None
モデルに紐づく LM Studio MCP integrations リスト。未設定なら None。
例: SourceVaultSetModel["lmstudio", "local-heavy", "qwen/qwen3-coder-30b", "Integrations" -> {"mcp/exa"}, "ContextLength" -> 32000]

### SourceVaultListRegistries[opts] → Association
登録済み registry topic と channel。
Options: "Channel" -> "public" | "private" | All (既定 All)

### SourceVaultRegistryStatus[topic, opts] → Association
指定 topic の registry 状態。
→ <|"Topic", "Channel", "CompiledPath", "CompiledExists" -> _Bool, "CompiledCount", "SeedPath", "SeedExists" -> _Bool, "SeedCount", "LastModified"|>
Options: "Channel" -> "public" | "private"

### SourceVaultCompileRegistry[topic, entries, opts]
entries(List of Association) を compiled registry に保存。
→ <|"Status", "Topic", "Channel", "Path", "Count"|>
Options: "Channel" -> "public", "Sources" -> {_String, ...}, "PolicySource" -> _String

### SourceVaultRegisterSeed[topic, entries] → Association
seed entries を seeds/<topic>-seed.json に保存(bootstrap)。compiled registry が無い時の fallback。

## Notebook Management (Stage 9 P0)

### SourceVaultRegisterNotebook[path] → Association
指定 path の notebook を登録。NotebookRef は path-based hash で安定生成。
→ <|"Status", "NotebookRef", "Path", "RegisteredAt"|>

### SourceVaultIndexNotebook[path, opts]
notebook の Header/Todo/Cell を抽出して index 更新。snapshot に SemanticHash 自動追加。
→ <|"Status", "NotebookRef", "SnapshotId", "Header", "TodoCount", "OpenTodoCount", "ReviewState", "DeadlineState", "Lint" -> {...}|>
Options: "ExtractHeader" -> True, "ExtractTodos" -> True, "ForceReindex" -> False (mtime 同じなら skip)

### SourceVaultIndexNotebookFolder[dir, opts]
folder 配下の .nb を全 index。
→ <|"Status", "Processed" -> _Integer, "Failed" -> _Integer, "Results" -> {...}|>
Options: "Recursive" -> False, "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}

### SourceVaultExtractNotebookHeader[path] → Association
先頭 Input セルから Header を safe parse(HoldComplete + whitelist で RunProcess/Get/Import 等を拒否)。
→ <|"ParseStatus" -> "OK"|"MissingHeader"|"UnsafeExpression", "Keywords", "Deadline", "NextReview", "Status"|>

### SourceVaultExtractNotebookTodos[path] → {todo, ...}
TodoItem スタイルセルを列挙。Status 3 値(Open/Done/Pass)、優先順位 TaggingRules > StrikeThrough+FontColor > Default。StrikeThrough なし→Open、+緑→Done、+灰→Pass、+その他→Done。
→ {<|"Text", "Status", "StatusSource", "StrikeThrough" -> _Bool|>, ...}

### SourceVaultFindNotebooks[opts] → {record, ...}
index 済み notebook を deterministic 検索(LLM 不要)。
各 record: <|"Path"/"OriginalPath", "Title", "NotebookRef", "Header", "Todos" -> {<|"Text","Status"|>...}, "TodoCount"/"OpenTodoCount"/"DoneTodoCount"/"PassTodoCount", "ReviewState", "DeadlineState", "Lint"|>
Options:
- "OpenTodos" -> _Bool
- "NextReview" -> "Today" | "Overdue" | "ThisWeek" | "DueSoon" | <|"From", "To"|> ("Today" は厳密に今日のみ、"ThisWeek"/"DueSoon" は今日±7日、"Overdue" は期限切れ全部)
- "Deadline" -> 同上
- "Keywords" -> {_String, ...} | _String (部分一致 OR。対象: Header.Keywords + Title + FileBaseName + 親フォルダ名)
- "Title" -> _String | {...} ("Keywords" のエイリアス)
- "Status" -> "Todo" | "Done" | _String
- "Scope" -> "Today" (NextReview==今日 OR Deadline==今日 OR Path に今日の YYYYMMDD)
- "ForceReindex" -> False (cache 無視して再 index)
- "Format" -> False (True で SourceVaultFormatNotebookList の Grid に整形)

### SourceVaultNotebookLint[record] → {lintName, ...}
notebook record(または path)に lint チェック。検出: MissingHeader / UnsafeHeaderExpression / HeaderDeadlineMalformed / HeaderNextReviewMalformed / HeaderStatusTodoButNoOpenTodos / HeaderStatusDoneButOpenTodosExist / DeadlinePast / NextReviewPast / TodoCellStatusHeuristicOnly。

## Notebook P1: TaggingRules / SemanticHash / Summary / Todo

### SourceVaultExtractNotebookTaggingRules[path] → Association
notebook 全体および各 TodoItem cell の TaggingRules を取得(rule 102 準拠、Import[path,"Notebook"] + NotebookImport)。
→ <|"Status" -> "OK"|"Failed", "Path", "NotebookTaggingRules" -> _Association, "CellTaggingRules" -> {<|"Index" -> _Integer, "CellStyle", "TaggingRules" -> _Association|>, ...}|>

### SourceVaultNotebookSemanticHash[path] → Association
意味的内容のみ(content/style/TaggingRules/FontVariations/FontColor/Background)を対象に SHA256 ハッシュ。表示メタデータ(ExpressionUUID/CellChangeTimes/FontFamily 等)・ウィンドウ設定は除外。formatting のみの変更で Stale 誤判定を防ぐ。
→ <|"Status" -> "OK"|"Failed", "Path", "SemanticHash" -> _String|>

### SourceVaultRegisterNotebookSummary[path, summary, opts] → Association
notebook の summary artifact を登録。現在の snapshot(SnapshotId + SemanticHash)に紐づけて保存。
→ <|"Status" -> "OK"|"Failed", "SummaryId", "NotebookRef", ...|>
Options: "SummaryFormat" -> "text" | "markdown" (既定 "text"), "GeneratedBy" -> "manual"

### SourceVaultGetNotebookSummary[path] → Association
notebook に紐づく summary record。未登録なら "Status" -> "Missing"。
→ <|"Status" -> "OK"|"Missing"|"Failed", "Summary", "SummaryFormat", "BasedOnSnapshot", "BasedOnSemanticHash", "GeneratedBy", "CreatedAt"|>

### SourceVaultNotebookSummaryStatus[path] → Association
summary artifact の現在 lifecycle ステータス。Missing / Current / StaleFormattingOnly(SemanticHash 一致) / Stale(SemanticHash 変化)。
→ <|"Status", "Reason", "CurrentSnapshot", "SummaryBasedOnSnapshot" -> _String|_Missing|>

### SourceVaultNotebookSummary[path, opts]
notebook 内容を LLM で要約し Summary artifact 保存。内部で RegisterNotebookSummary を呼ぶため lifecycle 管理自動。既定 PrivacyLevel 1.0(ローカル LM 経由)。
→ Current で ForceRefresh 無しなら既存 record、生成成功なら Register 同形、Inconsistent なら <|"Status" -> "Inconsistent", "Reason"|>、失敗なら <|"Status" -> "Failed", "Reason"|>
Options:
- "ForceRefresh" -> False
- "MaxLength" -> 500
- "Language" -> Automatic | "Japanese" | "English"
- "Model" -> Automatic | {"provider", "model"}
- "PrivacyLevel" -> 1.0 (0.0 API 許可 〜 1.0 ローカルのみ)
- "FallbackToCloud" -> "Ask" | "Allow" | "Deny"

### SourceVaultMarkTodo[path, target, newStatus, opts]
notebook 内 Todo cell の Status を変更(NBAccess の NBWriteTodoStatus への薄ラッパー)。target: Integer(1-based Todo Index) / String(TodoId) / Association(<|"Index" -> n, "Text" -> "..."|>)。newStatus: "Open" / "Done" / "Pass"。変更内容は Cell options(FontVariations StrikeThrough + FontColor 緑/灰) と Cell TaggingRules(<|"SourceVault" -> <|"TodoStatus" -> newStatus|>|>)。
→ DryRun: <|"Status" -> "DryRunOK", "Target", "MatchedTodo", "OldStatus", "NewStatus", "CellPath" -> {_Integer...}, "Before" -> HoldComplete[...], "After" -> HoldComplete[...]|>
→ 実行: <|"Status" -> "OK"|"Failed", "Target", "MatchedTodo", "OldStatus", "NewStatus", "ReindexResult" -> _Association|Missing["NotRequested"]|>
Options: "DryRun" -> True (既定、安全側 preview のみ), "AutoReindex" -> True (実行時のみ), "AccessSpec" -> <|"AccessLevel" -> 0.7, ...|>

### SourceVaultUpcomingSchedule[opts] → Dataset
「今日から N 日以内」に Deadline / NextReview がある notebook 一覧を Dataset で返す。概要はキャッシュから取り込む(必要時自動再生成)。日付 yyyy/mm/dd、期限切れは赤、今日/明日は青。
Options:
- "Scope" -> dir | _String (既定 $onWork または $packageDirectory)
- "Period" -> Quantity[7, "Days"]
- "IncludeOverdue" -> True
- "Recursive" -> True
- "Refresh" -> "Never" | "IfStale" | "Force" (既定 Never は保存済 Summary 表示、無ければ Keywords を tooltip に fallback)

## 関連ヘルパー（usage 内で参照される公開シンボル）

以下は他関数の説明中で参照される補助シンボル。
- SourceVaultSpan[...] — SourceVaultExtract の sourceSpan を構築する。
- SourceVaultEnsureNotebookUUID[path] — .nb に ExpressionUUID を埋め込む(Ingest の EnsureUUID で内部使用)。
- SourceVaultFormatNotebookList[records] — notebook record リストを Grid 表に整形(FindNotebooks "Format" -> True が利用)。
- SourceVaultSetModel[provider, intent, modelId, opts] — モデル登録/永続化。Options: "ContextLength" -> n, "Integrations" -> {...}。
- SourceVaultContext[...] — PDF context retrieval。Stage 6d で RequireApproval も block、NBAuthorize 統合。