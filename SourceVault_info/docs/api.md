# SourceVault API リファレンス

外部 source 管理パッケージ。PDF/URL/arXiv/Notebook の ingest・snapshot・claim 抽出・evidence bundle・compiled registry・notebook 管理を提供。`BeginPackage["SourceVault`", {"NBAccess`"}]`。NBAccess の NBAuthorize を前提とする。authoritative storage は PrivateVault (Dropbox 配下)、cloud LLM には CloudMirror/AttachmentMirror の materialize 済み projection のみ露出。

## Bootstrap / 設定

### $SourceVaultVersion
型: String
パッケージのバージョン文字列。

### $SourceVaultRoots
型: Association, Keys: "PrivateVault" | "CloudMirror" | "Tmp" | "AttachmentMirror" | "ExternalOwned"
物理 root ディレクトリマッピング。PrivateVault が authoritative。cloud LLM/Claude Code CLI に直接読ませない。

### $SourceVaultSeedModelRegistry
型: Association
bootstrap 時の fallback model registry。production truth ではなく、compiled registry が無い場合の災害復旧用 fallback。LLM 自動更新しない。

### SourceVaultInitialize[opts] → Association
物理 root を生成・初期化。PrivateVault/Tmp は必須。作成済みなら noop。
Options: "Roots" -> $SourceVaultRoots (override), "Force" -> False (True で再初期化)

### SourceVaultStatus[sourceRef] → Association
指定 source/snapshot/ファイルの概要。引数なし SourceVaultStatus[] で vault 全体概要。

### SourceVaultList[] → {sourceId, ...}
vault 内の全 source ID リスト。

### SourceVaultSnapshots[sourceRef] → {snapshotId, ...}
指定 source の snapshot ID リスト。

## Lookup / Resolve / Registry

### SourceVaultResolve[kind, query, opts] → Association | Missing["NotFound"]
compiled registry から query に match する entry を返す。Network/LLM なし。kind: "Model" | _String。query: <|"Provider" -> ..., "Intent" -> ...|>。複数 match 時は Availability != "Unavailable" をフィルタ、Class/Freshness で sort し先頭を返す。
Options: "Channel" -> "public" | "private", "AllowSeed" -> True (compiled 無し時 seed), "Topic" -> "<kind>-registry" 小文字化
例: SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]

### SourceVaultLookup[topic, key, opts] → Association | Missing["NotFound"]
compiled registry から key に対応する entry を返す。topic: "model-registry" | "mathematica-graph-options" | _String。key: String または Association。compiled に無ければ seed に fallback。
Options: "Channel" -> "public" (| "private"), "AllowSeed" -> True

### ClaudeResolveModel[provider, intent] → Association
SourceVaultResolve["Model", ...] の互換 wrapper。旧 WikiDBResolveModel の置き換え。
例: ClaudeResolveModel["anthropic", "heavy"]

### SourceVaultListModels[provider] → {modelId, ...}
provider に登録された選択可能な全モデル ID を列挙 (catalog)。compiled 優先、無ければ seed。Availability=Unavailable は除外。

### SourceVaultModelContextLength[provider, modelId] → _Integer | None
モデルに紐づく ContextLength。SourceVaultSetModel[..., "ContextLength" -> n] で永続化された値。LM Studio 等の context_length 用。未設定なら None。

### SourceVaultModelIntegrations[provider, modelId] → {mcpId, ...} | None
モデルに紐づく LM Studio MCP integrations リスト。LM Studio /api/v1/chat の integrations パラメータ用。未設定なら None。

### SourceVaultListRegistries[opts] → Association
登録済み registry topic と channel を返す。
Options: "Channel" -> "public" | "private" | All (default All)

### SourceVaultRegistryStatus[topic, opts] → Association
指定 topic の registry 状態。返り値キー: "Topic", "Channel", "CompiledPath", "CompiledExists", "CompiledCount", "SeedPath", "SeedExists", "SeedCount", "LastModified"。
Options: "Channel" -> "public" | "private"

### SourceVaultCompileRegistry[topic, entries, opts] → Association
entries (List of Association) を compiled registry に保存。entries: {<|"Provider" -> ..., "Intent" -> ..., "ModelId" -> ...|>, ...}。
→ <|"Status", "Topic", "Channel", "Path", "Count"|>
Options: "Channel" -> "public", "Sources" -> {_String, ...}, "PolicySource" -> _String

### SourceVaultRegisterSeed[topic, entries] → Association
seed entries を seeds/<topic>-seed.json に保存 (bootstrap 用)。seed は production truth ではなく compiled 無し時の fallback のみ。

## Ingest

### SourceVaultIngest[source, opts] → Association
外部 source を登録し raw snapshot を PrivateVault に保存。Local file path / HTTPS・HTTP URL (URLDownload) / arXiv:NNNN.NNNNN[vN] (arxiv.org/pdf に canonicalize) に対応。
Options: Topic -> Automatic | _String, TrustLevel -> Automatic | "OfficialAPI" | "OfficialDocs" | "PublicWeb" | "LocalFile", PrivacyLabel -> Automatic | _Real, PinVersion -> True | False | Automatic, Asynchronous -> False (True で LLMGraphDAGCreate 経由ジョブ投入し JobId 即時 return、claudecode.wl 必須), EnsureUUID -> Automatic | True | False (.nb は hash 計算前に UUID 埋め込み、>$SourceVaultMaxFileSizeMB の非.nb はスキップ)

### SourceVaultIngestWait[ingestResult, timeoutSec] → Association
非同期 ingest の完了を待つ。第一引数は SourceVaultIngest 結果 Association または SourceId String。sync 完了済み (Ingested/AlreadyCurrent/RebuiltMetadata) なら即 return。Status: Queued なら SourceId の snapshot 増加を polling。timeoutSec (default 60) 超過で Status: Timeout。

## PDF page 抽出 (Stage 4B)

### SourceVaultExtractPages[snapshot, pages, opts] → Association
snapshot の指定 page を抽出し cache に保存。snapshot: SnapshotId または SourceId (latest 使用)。pages: Integer | List of Integer | All。各 page を parsed/by-snap/<id>/pages/NNNN.txt に cache、page-hashes.json に SHA-256 保存。cache hit 時は Import しない。抽出結果が空 or 5文字未満なら $SourceVaultOCRHook を呼ぶ。
→ <|"Status", "SnapshotId", "Pages" -> {n: text, ...}, "Hashes", "CachedFrom" -> "Disk"|"Fresh"|"Mixed", "OCRCalled" -> True|False|>
Options: Force -> False (cache 無視再抽出), "ForceOCR" -> False (この呼出だけ OCR 強制、スキャン判定スキップ、hook 必須、True 時 Force も自動適用)

### $SourceVaultOCRHook
型: None | Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String, 初期値: None
スキャン PDF の fallback。ページテキスト抽出失敗時 (空 or 5文字未満) に呼ばれ、返値文字列が text として cache される。SourceVaultOCREnable 経由設定推奨。

### $SourceVaultOCRMode
型: String, 初期値: "Auto"
"Auto": Plaintext 抽出が 5文字未満の時のみ OCR。"Force": 長さに関わらず常に OCR (低品質テキスト層対策)。SourceVaultOCREnable[..., "Mode" -> "Force"] で永続化、SourceVaultOCRDisable[] で "Auto" にリセット。

### $SourceVaultOCRVerbose
型: Bool, 初期値: False
True で rasterization/API呼出/レスポンス長等の進捗を Print。OCR デバッグ用。

## OCR backends (Stage 4C)

### SourceVaultOCREnable[backend, opts] → Association
OCR hook を有効化。backend (default "ClaudeVision"): "ClaudeVision" | "TextRecognize" | "Custom"。
→ <|"Status" -> "Enabled", "Backend", "Mode", "Options"|>
"ClaudeVision": ClaudeCode`ClaudeQueryBg 経由で page 画像を Claude API に送り OCR。大 page は上下分割 (30px overlap) で2回マージ。Options: "DPI" -> 300, "SplitHalves" -> True, "Timeout" -> 180, "Prompt" -> Automatic
"TextRecognize": 組込 TextRecognize (Python 不要)。Options: "DPI" -> 150, "Language" -> "Japanese"
"Custom": ユーザ Function をそのまま $SourceVaultOCRHook に設定。Options: "Hook" -> Function[req, text]
共通 Options: "Mode" -> "Auto" (5文字未満時のみ) | "Force" (常時)

### SourceVaultOCRDisable[] → Association
OCR hook を無効化 ($SourceVaultOCRHook = None)。

### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定。Backend: Disabled / ClaudeVision / TextRecognize / Custom。HookSet: True なら Function 設定済み。

## Claim 抽出 (Stage 5/6a)

### SourceVaultExtract[sourceSpan, schema, opts] → Association
sourceSpan の page text を LLM に渡し claim を抽出。sourceSpan: SourceVaultSpan[...] 結果 / SnapshotId / SourceId。schema: 登録済み schema 名 (String) または インライン定義 (Association)。
→ <|"Claims" -> {...}, "Count" (実納数), "ExtractedCount" (LLM生抽出数), "DedupSkipped", "AccessDecisions" -> <|"Send", "Persist"|>, "ValidationStatus", "SchemaName", "ExtractedAt" -> DateObject, "Errors"|>
Deny 時: <|"Status" -> "DeniedByNBAccess", "Reason", "AccessDecisions"|>
RequireApproval 時: <|"Status" -> "RequiresApproval", "Reason", "AccessDecisions"|>
Options: "Topic" -> _String (default schema 名), "ModelIntent" -> "summary" | "extraction" | "math-extraction-heavy", "StoreClaims" -> True, "Dedup" -> True (by-source ContentHash 照合), "AuthorizationCheck" -> True (2段階 NBAuthorize: sendDecision → context取得+抽出 → persistDecision), "Validation" -> "None" | "Required", MaxCharacters -> 8000, Timeout -> 180

### SourceVaultRegisterSchema[name, definition] → Association
抽出 schema をグローバルに登録。definition は Association:
"Description" -> String (LLM向け説明), "Fields" -> {<|"Name", "Type" -> "Number"|..., "Required" -> True, "Description"|>, ...}, "OutputShape" -> "List" | "Single", "PromptTemplate" -> Automatic | _String
ビルトイン schema: "FreeText", "NumericFacts", "DefinitionList"。

### SourceVaultClaim[claimId] → Association | Missing["NotFound"]
指定 claim の Association を返す。

### SourceVaultClaimsForSource[sourceIdOrSnapshotId] → {claim, ...}
指定 source に紐づく claim リスト。

### SourceVaultClaimsForTopic[topic] → {claim, ...}
指定 topic に紐づく claim リスト。

### SourceVaultListSchemas[] → {schemaName, ...}
登録済み schema 名リスト。

### SourceVaultGetSchema[name] → Association
登録済み schema 定義を返す。

### SourceVaultClaimStoreStatus[] → Association
ClaimStore 状態 (debug)。ClaimsDir / MasterPath / MasterExists / MasterClaims (行数) / TopicFiles / SourceFiles。

### SourceVaultClaimStoreCompact[opts] → Association
master + by-topic + by-source を全読みし ContentHash で dedup、全インデックスを atomic rebuild (tmp → rename)。dedup は master 先頭行を残す (最古を保存)。
→ <|"Status" -> "OK"|"Failed", "BeforeCount", "AfterCount", "Removed", "BackupPaths", "DryRun"|>
Options: "Backup" -> True (.bak.<timestamp>), "DryRun" -> False (True で統計のみ)

## Evidence Bundle (Stage 6c)

### SourceVaultBundleCreate[name, deps, opts] → Association
generated artifact の依存を evidence bundle として保存。BundleId は自動生成。deps: Association ("GeneratedFiles" -> {paths}, "Sources" -> {<|"SourceId", "SnapshotId"|>, ...}, "SourceSpans" -> {...} 任意, "Claims" -> {claimId, ...}, "Generator" -> <|"Tool", "WorkflowId", "ModelIntent", "ResolvedModel"|>)。
→ <|"Status" -> "OK"|"Failed", "BundleId", "Path"|>
Options: "Kind" -> "SimulationExample" | "LaTeXExport" | "DocumentGeneration" | "CodeGeneration" | "Notebook" | _String

### SourceVaultBundleGet[bundleId] → Association | Missing["NotFound"]
指定 bundle を読み込み返す。

### SourceVaultBundleList[] → {bundleId, ...}
全 bundle id リスト。

### SourceVaultBundleStatus[bundleId] → Association
bundle の現在 Status を計算。参照 snapshot の LifecycleStatus を集約。手動 Invalidate 済みなら強制的に "Invalidated"。
→ <|"Status" -> "Current"|"Stale"|"NeedsReview"|"Invalidated", "Reason", "AffectedSnapshots", "AffectedClaims"|>

### SourceVaultBundleInvalidate[bundleId, reason] → Association
bundle を手動 invalidate。reason は記録され BundleStatus で返される。

### SourceVaultBundleDelete[bundleId] → Association
bundle ファイルを削除 (debug)。

## vN diff + snapshot lifecycle (Stage 8)

### SourceVaultDiffVersions[v1Snap, v2Snap] → Association
2 snapshot の page hash 集合を比較。各 page-hashes.json を読み page 番号ごとに hash 比較。
→ <|"Status", "V1Snap", "V2Snap", "AddedPages" (v2のみ), "RemovedPages" (v1のみ), "ChangedPages" (両方ありhash相違), "UnchangedPages" (両方ありhash一致)|>

### SourceVaultMarkSnapshotStale[snapshotId, reason] → Association
snapshot meta の LifecycleStatus を "Stale" に更新し events/source-events.jsonl に VersionedUpdate event 記録。参照する Bundle は BundleStatus で自動 "Stale"。

### SourceVaultMarkSnapshotInvalidated[snapshotId, reason] → Association
LifecycleStatus を "Invalidated" に更新。Retraction 等、参照を不可にしたい場合。Bundle は "Invalidated" を返す。

### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason] → Association
高レベル refresh。(1) diff 計算 (2) oldSnap を "Stale" + SupersededBy=newSnap (3) source-events.jsonl に VersionedUpdate event 記録。
→ <|"Status", "Diff" -> _Association, "Event" -> _Association|>

### SourceVaultBundlesForSnapshot[snapshotId] → {bundleId, ...}
指定 snapshot を参照する全 bundle id (Sources[].SnapshotId 一致)。

### SourceVaultSourceEvents[opts] → {event, ...}
events/source-events.jsonl の全 event リスト。
Options: "SourceId" -> _String, "SnapshotId" -> _String, "EventType" -> "VersionedUpdate" | "Retraction" | "SourceDeletion" | "SchemaChange"

### SourceVaultSourceEventAppend[event] → Association
event Association を source-events.jsonl に append。必須キー: EventType / SourceId / Reason。任意: OldSnapshotId / NewSnapshotId / Metadata。EventId と Timestamp は自動生成。

## Notebook 管理 (Stage 9)

### SourceVaultRegisterNotebook[path] → Association
notebook を SourceVault に登録。path: 絶対/ローカルパス。NotebookRef は path-based hash で安定生成。
→ <|"Status", "NotebookRef", "Path", "RegisteredAt"|>

### SourceVaultIndexNotebook[path, opts] → Association
notebook の Header/Todo/Cell を抽出し index 更新。snapshot に SemanticHash 自動追加。
→ <|"Status", "NotebookRef", "SnapshotId", "Header", "TodoCount", "OpenTodoCount", "ReviewState", "DeadlineState", "Lint"|>
Options: "ExtractHeader" -> True, "ExtractTodos" -> True, "ForceReindex" -> False (mtime 同じなら skip)

### SourceVaultIndexNotebookFolder[dir, opts] → Association
folder 配下の .nb を全て index。
→ <|"Status", "Processed" -> _Integer, "Failed" -> _Integer, "Results"|>
Options: "Recursive" -> False, "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}

### SourceVaultExtractNotebookHeader[path] → Association
先頭 Input セルから Header を safe parse (HoldComplete + whitelist で RunProcess/Get/Import 拒否)。
→ <|"ParseStatus" -> "OK"|"MissingHeader"|"UnsafeExpression", "Keywords", "Deadline", "NextReview", "Status"|>

### SourceVaultExtractNotebookTodos[path] → {Association, ...}
TodoItem スタイルセルを列挙。Status 判定優先順位: TaggingRules > FontVariations StrikeThrough + FontColor > Default。StrikeThrough なし→Open、+緑(g>r,g>b)→Done、+灰(GrayLevel/r≈g≈b)→Pass、+その他→Done。
→ {<|"Text", "Status" -> "Open"|"Done"|"Pass", "StatusSource", "StrikeThrough" -> _Bool|>, ...}

### SourceVaultFindNotebooks[opts] → {record, ...}
index 済み notebook を deterministic query。各 record キー: "Path"/"OriginalPath", "Title", "NotebookRef", "Header", "Todos" -> {<|"Text", "Status"|>, ...}, "TodoCount"/"OpenTodoCount"/"DoneTodoCount"/"PassTodoCount", "ReviewState"/"DeadlineState", "Lint"。todo 本体は record["Todos"] を使う。
Options:
"OpenTodos" -> True | False
"NextReview" -> "Today" (厳密今日のみ) | "Overdue" (期限切れ全部) | "ThisWeek" | "DueSoon" (今日±7日内) | <|"From", "To"|>
"Deadline" -> 同上
"Keywords" -> {_String, ...} | _String (部分一致 OR、対象: Header.Keywords+Title+FileBaseName+親フォルダ名)
"Title" -> _String | {...} ("Keywords" のエイリアス)
"Status" -> "Todo" | "Done" | _String
"Scope" -> "Today" (NextReview==今日 | Deadline==今日 | Path に YYYYMMDD で今日含む の OR)
"ForceReindex" -> False (True で mtime/hash cache 無視全再index)
"Format" -> False (True で SourceVaultFormatNotebookList の Grid で返す)

### SourceVaultNotebookLint[record] → {lintName, ...}
notebook record (または path) に lint チェック。検出: MissingHeader / UnsafeHeaderExpression / HeaderDeadlineMalformed / HeaderNextReviewMalformed / HeaderStatusTodoButNoOpenTodos / HeaderStatusDoneButOpenTodosExist / DeadlinePast / NextReviewPast / TodoCellStatusHeuristicOnly。

### SourceVaultExtractNotebookTaggingRules[path] → Association
notebook 全体および各 TodoItem cell の TaggingRules を取得。Import[path, "Notebook"] の Notebook 式 + NotebookImport[path, style -> "Cell"] 経由。
→ <|"Status" -> "OK"|"Failed", "Path", "NotebookTaggingRules" -> _Association (無ければ <||>), "CellTaggingRules" -> {<|"Index" -> _Integer, "CellStyle" -> _String, "TaggingRules" -> _Association|>, ...}|>

### SourceVaultNotebookSemanticHash[path] → Association
意味的内容のみを対象にした hash。表示メタデータ (ExpressionUUID/CellChangeTimes/CellLabel/FontFamily 等) とウィンドウ設定 (WindowSize/WindowMargins/FrontEndVersion 等) を除外し、content/style/TaggingRules/FontVariations/FontColor/Background のみを対象。formatting のみの変更で Stale 誤判定を防ぐ。Hash[normalizedExpr, "SHA256", "HexString"]。
→ <|"Status" -> "OK"|"Failed", "Path", "SemanticHash" -> _String|>

### SourceVaultRegisterNotebookSummary[path, summary, opts] → Association
notebook の summary artifact を登録。現在の snapshot (SnapshotId + SemanticHash) に紐づけ保存し後日 stale 判定可能。
→ <|"Status" -> "OK"|"Failed", "SummaryId", "NotebookRef", ...|>
Options: "SummaryFormat" -> "text" | "markdown" (default "text"), "GeneratedBy" -> _String (default "manual")

### SourceVaultGetNotebookSummary[path] → Association
summary record を取得。未登録なら "Status" -> "Missing"。
→ <|"Status" -> "OK"|"Missing"|"Failed", "Summary", "SummaryFormat", "BasedOnSnapshot", "BasedOnSemanticHash", "GeneratedBy", "CreatedAt"|>

### SourceVaultNotebookSummaryStatus[path] → Association
summary artifact の lifecycle ステータス判定。Missing (未存在) / Current (BasedOnSnapshot が現 snapshot と一致) / StaleFormattingOnly (SemanticHash 一致、formatting のみ変更) / Stale (SemanticHash 変化、再生成推奨)。
→ <|"Status", "Reason", "CurrentSnapshot", "SummaryBasedOnSnapshot" -> _String|_Missing|>

### SourceVaultNotebookSummary[path, opts] → Association
notebook を LLM で要約し Summary artifact として保存。内部で SourceVaultRegisterNotebookSummary を呼ぶため lifecycle 管理は自動。default PrivacyLevel -> 1.0 (ローカル LM 経由で API に送らない)。
Options: "ForceRefresh" -> False (Current でも強制再生成), "MaxLength" -> 500, "Language" -> Automatic | "Japanese" | "English", "Model" -> Automatic | {"provider", "model"}, "PrivacyLevel" -> 1.0 (0.0 API許可〜1.0 ローカルのみ), "FallbackToCloud" -> "Ask" | "Allow" | "Deny"
→ Current かつ ForceRefresh 無し: 既存 record (Get 同形)。生成成功: Register 同形 Association。Inconsistent (キャンセル): <|"Status" -> "Inconsistent", "Reason", ...|>。失敗: <|"Status" -> "Failed", "Reason", ...|>

### SourceVaultMarkTodo[path, target, newStatus, opts] → Association
notebook 内の Todo cell の Status を変更 (書き込み系)。NBAccess の NBWriteTodoStatus への薄いラッパー。target: Integer (1-based Index) / String (TodoId) / Association (<|"Index", "Text"|>)。newStatus: "Open" | "Done" | "Pass"。変更内容: Cell options (FontVariations StrikeThrough + FontColor 緑/灰) と Cell TaggingRules (<|"SourceVault" -> <|"TodoStatus" -> newStatus|>|>)。
Options: "DryRun" -> True (preview のみ、安全側), "AutoReindex" -> True (実行時のみ index 自動), "AccessSpec" -> <|"AccessLevel" -> 0.7, ...|>
→ DryRun: <|"Status" -> "DryRunOK", "Target", "MatchedTodo", "OldStatus", "NewStatus", "CellPath" -> {_Integer...}, "Before" -> HoldComplete[...], "After" -> HoldComplete[...]|>
→ 実行: <|"Status" -> "OK"|"Failed", "Target", "MatchedTodo", "OldStatus", "NewStatus", "ReindexResult" -> _Association | Missing["NotRequested"]|>

### SourceVaultUpcomingSchedule[opts] → Dataset
「今日から N 日以内」に Deadline / NextReview がある notebook 一覧を Dataset で返す。概要もキャッシュから取り込む (必要時自動再生成)。日付は yyyy/mm/dd、期限切れは赤、今日/明日は青。
Options: "Scope" -> dir | _String (default $onWork または $packageDirectory), "Period" -> Quantity[7, "Days"], "IncludeOverdue" -> True, "Recursive" -> True, "Refresh" -> "Never" | "IfStale" | "Force" (default Never: 保存済み Summary だけ表示、無ければ Keywords をツールチップに fallback)

## 関連変数

### $SourceVaultMaxFileSizeMB
型: Number
SourceVaultIngest の EnsureUUID 処理で .nb 以外の巨大ファイル (>この値) は UUID 付与をスキップする閾値。