# SourceVault API リファレンス

外部 source 管理パッケージ。PDF/URL/arXiv/notebook の ingest、snapshot、claim 抽出、evidence bundle、compiled model registry、notebook 管理を提供する。

依存: [NBAccess](https://github.com/transreal/NBAccess)。各 ingest/context 操作は NBAccess の NBAuthorize を経由する。一部機能は [claudecode](https://github.com/transreal/claudecode) (ClaudeQuerySync / LLMGraphDAGCreate / ClaudeAttach / ClaudeQueryBg)、[ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) (A5/A6 hook)、PDF OCR は [PDFIndex](https://github.com/transreal/PDFIndex) 実証パターンに準拠する。

ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault.wl"]]` または claudecode.wl 経由。

物理ストレージ tier: PrivateVault (authoritative 正本、Dropbox 配下、cloud LLM に直接読ませない) / CloudMirror ($ClaudeWorkingDirectory 配下 mirror) / Tmp / AttachmentMirror ($packageDirectory/claude_attachments)。

## Bootstrap / 設定

### $SourceVaultVersion
型: String
パッケージのバージョン文字列。

### $SourceVaultRoots
型: Association
物理 root ディレクトリマッピング。Keys: "PrivateVault" | "CloudMirror" | "Tmp" | "AttachmentMirror" | "ExternalOwned"。PrivateVault が authoritative storage。

### $SourceVaultSeedModelRegistry
型: Association
bootstrap 時の fallback model registry。production truth ではなく、compiled registry が無い場合の災害復旧用 fallback。LLM 自動更新しない。

### $SourceVaultMaxFileSizeMB
型: Integer, 初期値: 50
index 時に .nb を Import するファイルサイズ上限 (MB)。超過分は Import せず軽量 snapshot のみ作る (Skipped マーク)。

### $SourceVaultCloudRoots
型: List
クラウド共有フォルダのシンボル名リスト。例: {"$packageDirectory", "$dropbox", "$onWork", "$offWork", "$mathematicaWork"}。絶対パスはこれらの配下にあれば {"$onWork", "folder", "file.nb"} のようなシンボリックパスに正規化され、PC/OS をまたいで同一 ID になる。

### $SourceVaultCloudRootAliases
型: Association, 初期値: <||>
クラウドルートのシンボル名から別環境での絶対パスリストへの対応。形式: `<|"$onWork" -> {"C:/Users/imai_/Dropbox/On Work"}, ...|>`。別 PC で index されたレコードの旧パスを正規化し、二重登録を防ぐ。

### SourceVaultInitialize[opts]
物理 root を生成して初期化する。PrivateVault, Tmp は必須。作成済みなら noop。
→ Association
Options: "Roots" -> $SourceVaultRoots (override), "Force" -> False (True で再初期化)

### SourceVaultStatus[sourceRef] → Association
指定 source / snapshot / ファイルの概要を返す。引数なし `SourceVaultStatus[]` は vault 全体の概要。

### SourceVaultList[] → List
vault 内の全 source ID リストを返す。

### SourceVaultSnapshots[sourceRef] → List
指定 source に限定した snapshot ID リスト。

### SourceVaultResetStore[opts]
notebooks ストア (sources/snapshots/summaries/todos/review/lint/sync/relink) を全削除して初期化する。破壊的操作。
→ Association: <|"Status" -> "OK"|"DryRun"|"Failed", "Deleted" -> _List, "NotebooksDir" -> _|>
Options: "Confirm" -> False (無いと DryRun 扱い、実際には削除しない)

## Stage 1: Lookup / Resolve

### SourceVaultResolve[kind, query, opts]
compiled registry から query に match する entry を返す。deterministic、network/LLM なし。複数 match 時は Availability != "Unavailable" をフィルタ、Class/Freshness で sort して先頭を返す。
→ entry Association または Missing["NotFound"]
Options: "Channel" -> "public" | "private", "AllowSeed" -> True, "Topic" -> "<kind>-registry" 小文字化
例: SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]

### SourceVaultLookup[topic, key, opts]
compiled registry から key に対応する entry を返す単純キー引き。compiled に無ければ seed に fallback。
→ entry Association または Missing["NotFound"]
Options: "Channel" -> "public" | "private", "AllowSeed" -> True
topic 例: "model-registry" | "mathematica-graph-options"。key は String または Association。

### ClaudeResolveModel[provider, intent] → entry Association
SourceVaultResolve["Model", ...] の互換 wrapper。旧 WikiDBResolveModel の置き換え。
例: ClaudeResolveModel["anthropic", "heavy"]

### SourceVaultListModels[provider] → List
指定 provider に登録された選択可能な全モデル ID リスト (catalog 列挙)。compiled registry 優先、無ければ seed fallback。Unavailable は除外。

### SourceVaultModelContextLength[provider, modelId] → Integer | None
モデルに紐づく ContextLength。SourceVaultSetModel で永続化された値。LM Studio 等ローカル LLM の context_length に使う。未設定なら None。

### SourceVaultModelIntegrations[provider, modelId] → List | None
モデルに紐づく LM Studio MCP の integrations リスト。未設定なら None。MCP ID ("mcp/exa" 等) をコードにハードコードせず SourceVault ストアに永続化する機構。

## Stage 6b: Compiled Registry 管理

### SourceVaultListRegistries[opts] → Association
登録済み registry topic と channel を返す。
Options: "Channel" -> "public" | "private" | All (default All)

### SourceVaultRegistryStatus[topic, opts]
指定 topic の registry 状態を返す。
→ <|"Topic", "Channel", "CompiledPath", "CompiledExists" -> _Bool, "CompiledCount" -> _Integer, "SeedPath", "SeedExists" -> _Bool, "SeedCount" -> _Integer, "LastModified"|>
Options: "Channel" -> "public" | "private"

### SourceVaultCompileRegistry[topic, entries, opts]
entries (List of Association) を compiled registry に保存する。
→ <|"Status", "Topic", "Channel", "Path", "Count" -> _Integer|>
Options: "Channel" -> "public" (default) | "private", "Sources" -> {_String...}, "PolicySource" -> _String
例: entries = {<|"Provider" -> "anthropic", "Intent" -> "heavy", "ModelId" -> "claude-opus-4-8"|>, ...}

### SourceVaultRegisterSeed[topic, entries] → Association
seed entries を seeds/<topic>-seed.json に保存 (bootstrap 用)。seed は production truth ではなく compiled が無い時の fallback。

## Stage 1.5 / 2 / 4: Ingest

### SourceVaultIngest[source, opts]
外部 source を登録し raw snapshot を PrivateVault に保存。local file path / HTTPS・HTTP URL (URLDownload) / arXiv:NNNN.NNNNN[vN] (arxiv.org/pdf に canonicalize) を受ける。
→ Association (Status: Ingested/AlreadyCurrent/RebuiltMetadata、または Asynchronous時 Queued+JobId)
Options:
Topic -> Automatic | _String
TrustLevel -> Automatic | "OfficialAPI" | "OfficialDocs" | "PublicWeb" | "LocalFile"
PrivacyLabel -> Automatic | _Real
PinVersion -> True | False | Automatic
Asynchronous -> False (default。True で LLMGraphDAGCreate 経由ジョブ投入、JobId 即時 return。claudecode.wl 必須)
EnsureUUID -> Automatic | True | False (.nb 取り込み時 hash 計算前に SourceVaultEnsureNotebookUUID を呼び UUID 埋込。.nb 以外と巨大ファイルはスキップ、失敗しても ingest 継続)

### SourceVaultIngestWait[ingestResult, timeoutSec] → Association
非同期 ingest の完了を待つ。第一引数は SourceVaultIngest の結果 Association または SourceId String。sync 完了済みなら即座 return。Status: Queued の場合 SourceId の snapshot 増加を polling。timeoutSec (default 60) 超過で Status: Timeout。

## Stage 4 Phase 4B: PDF page extraction

### SourceVaultExtractPages[snapshot, pages, opts]
snapshot の指定 page を抽出し cache に保存。各 page を parsed/by-snap/<id>/pages/NNNN.txt に cache、page-hashes.json に SHA-256 を保存。cache hit 時は Import しない。抽出結果が空 or 5文字未満なら $SourceVaultOCRHook を呼ぶ。
→ <|"Status", "SnapshotId", "Pages" -> {n: text, ...}, "Hashes" -> <|...|>, "CachedFrom" -> "Disk"|"Fresh"|"Mixed", "OCRCalled" -> True|False|>
snapshot: SnapshotId String または SourceId String (latest snapshot 使用)。pages: Integer | List of Integer | All。
Options: Force -> False (cache 無視再抽出), "ForceOCR" -> False (この呼出だけ OCR 強制、スキャン判定スキップ。hook 設定必須、True 時 Force も自動適用)

### $SourceVaultOCRHook
型: None | Function, 初期値: None
スキャン PDF の fallback 値。シグネチャ: `Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String`。SourceVaultExtractPages がページテキスト抽出失敗時に呼び、返値文字列が text として cache される。SourceVaultOCREnable 経由設定推奨。

### $SourceVaultOCRMode
型: String, 初期値: "Auto"
OCR 発火モード。"Auto": Plaintext 抽出結果が5文字未満の時のみ OCR。"Force": 長さに関わらず常に OCR (低品質テキスト層対策)。SourceVaultOCREnable[..., "Mode" -> "Force"] で永続化、SourceVaultOCRDisable[] で "Auto" にリセット。

### $SourceVaultOCRVerbose
型: Boolean, 初期値: False
OCR 実行時の進捗 Print 制御。True で rasterization / API 呼出 / レスポンス長を Print。

## Stage 4 Phase 4C: OCR backends

### SourceVaultOCREnable[backend, opts]
OCR hook を有効化する。
→ <|"Status" -> "Enabled", "Backend" -> _String, "Mode" -> _String, "Options" -> _Association|>
backend (default "ClaudeVision"): "ClaudeVision" | "TextRecognize" | "Custom"
- "ClaudeVision": ClaudeCode`ClaudeQueryBg 経由で Claude API に page 画像送り OCR。大きい page は自動で上下分割 (30px overlap) して2回 OCR。Options: "DPI" -> 300, "SplitHalves" -> True, "Timeout" -> 180, "Prompt" -> Automatic
- "TextRecognize": Mathematica 組込 TextRecognize。Options: "DPI" -> 150, "Language" -> "Japanese"
- "Custom": ユーザ提供 Function を $SourceVaultOCRHook に設定。Options: "Hook" -> Function[req, text]
共通 Option: "Mode" -> "Auto" (default) | "Force"

### SourceVaultOCRDisable[] → Null
OCR hook を無効化する ($SourceVaultOCRHook = None)。

### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定を返す。Backend: Disabled / ClaudeVision / TextRecognize / Custom。HookSet: True なら Function 設定済み。

## Stage 5/6a: Claim 抽出

### SourceVaultExtract[sourceSpan, schema, opts]
sourceSpan の page text を LLM に渡して claim を抽出する。sourceSpan は SourceVaultSpan[...] の結果、または SnapshotId/SourceId String。schema は登録済み schema 名 String、またはインライン定義 Association。
→ <|"Claims" -> {...}, "Count" -> _Integer (実納数), "ExtractedCount" -> _Integer (LLM 生抽出数), "DedupSkipped" -> _Integer, "AccessDecisions" -> <|"Send", "Persist"|>, "ValidationStatus", "SchemaName", "ExtractedAt" -> DateObject, "Errors" -> {...}|>
Deny時: <|"Status" -> "DeniedByNBAccess", "Reason", "AccessDecisions"|>
RequireApproval時: <|"Status" -> "RequiresApproval", "Reason", "AccessDecisions"|>
Options:
"Topic" -> _String (default schema 名)
"ModelIntent" -> "summary" | "extraction" | "math-extraction-heavy"
"StoreClaims" -> True
"Dedup" -> True (by-source ファイル単位 ContentHash 照合)
"AuthorizationCheck" -> True (2段階 NBAuthorize: sendDecision → context+LLM → persistDecision)
"Validation" -> "None" | "Required"
MaxCharacters -> 8000
Timeout -> 180

### SourceVaultRegisterSchema[name, definition] → Association
抽出 schema をグローバルに登録。definition は Association: "Description" -> String, "Fields" -> {<|"Name", "Type", "Required", "Description"|>, ...}, "OutputShape" -> "List" | "Single", "PromptTemplate" -> Automatic | _String。ビルトイン: "FreeText" / "NumericFacts" / "DefinitionList"。

### SourceVaultClaim[claimId] → Association | Missing["NotFound"]
指定 claim の Association を返す。

### SourceVaultClaimsForSource[sourceIdOrSnapshotId] → List
指定 source に紐づく claim リストを返す。

### SourceVaultClaimsForTopic[topic] → List
指定 topic に紐づく claim リストを返す。

### SourceVaultListSchemas[] → List
登録済み schema 名リストを返す。

### SourceVaultGetSchema[name] → Association
登録済み schema 定義を返す。

### SourceVaultClaimStoreStatus[] → Association
ClaimStore の状態 (debug 用)。ClaimsDir / MasterPath / MasterExists / MasterClaims (行数) / TopicFiles / SourceFiles。

### SourceVaultClaimStoreCompact[opts]
master + by-topic + by-source を全読みし ContentHash キーで dedup して全インデックスを rebuild。atomic rewrite。dedup 記録は master の先頭行を残す (最古の結果を保存)。
→ <|"Status" -> "OK"|"Failed", "BeforeCount", "AfterCount", "Removed", "BackupPaths" -> {...}, "DryRun"|>
Options: "Backup" -> True (.bak.<timestamp>), "DryRun" -> False (True で統計のみ)

## Stage 6c: Evidence Bundle

### SourceVaultBundleCreate[name, deps, opts]
generated artifact の依存を evidence bundle として保存。BundleId は自動生成。
→ <|"Status" -> "OK"|"Failed", "BundleId" -> _String, "Path" -> _String|>
deps Association: "GeneratedFiles" -> {...}, "Sources" -> {<|"SourceId", "SnapshotId"|>, ...}, "SourceSpans" -> {...} (optional), "Claims" -> {"claim-..."}, "Generator" -> <|"Tool", "WorkflowId", "ModelIntent", "ResolvedModel"|>
Options: "Kind" -> "SimulationExample" | "LaTeXExport" | "DocumentGeneration" | "CodeGeneration" | "Notebook" | _String

### SourceVaultBundleGet[bundleId] → Association | Missing["NotFound"]
指定 bundle を読み込み返す。

### SourceVaultBundleList[] → List
全 bundle id リストを返す。

### SourceVaultBundleStatus[bundleId] → Association
bundle の現在の Status を計算。参照する snapshot の LifecycleStatus を集約。手動 Invalidate 済みなら強制的に "Invalidated"。
→ <|"Status" -> "Current"|"Stale"|"NeedsReview"|"Invalidated", "Reason", "AffectedSnapshots" -> {...}, "AffectedClaims" -> {...}|>

### SourceVaultBundleInvalidate[bundleId, reason] → Association
bundle を手動 invalidate する。reason は記録され後で BundleStatus で返る。

### SourceVaultBundleDelete[bundleId] → Association
bundle ファイルを削除 (debug 用)。

## Stage 8: vN diff + snapshot lifecycle

### SourceVaultDiffVersions[v1Snap, v2Snap] → Association
二つの snapshot の page hash 集合を比較し差分を返す。各 snapshot の page-hashes.json を読み page 番号ごとに hash 比較。
→ <|"Status", "V1Snap", "V2Snap", "AddedPages" -> {_Integer...} (v2 のみ), "RemovedPages" (v1 のみ), "ChangedPages" (両方ありhash不一致), "UnchangedPages" (両方ありhash一致)|>

### SourceVaultMarkSnapshotStale[snapshotId, reason] → Association
snapshot meta の LifecycleStatus を "Stale" に更新し events/source-events.jsonl に VersionedUpdate event を記録。その snapshot を参照する Bundle は自動的に "Stale" を返すようになる。

### SourceVaultMarkSnapshotInvalidated[snapshotId, reason] → Association
LifecycleStatus を "Invalidated" に更新。Retraction など参照を不可にしたい場合に使う。

### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason] → Association
高レベル refresh API。diff 計算 → oldSnap を "Stale" + SupersededBy を newSnap に設定 → event 記録。
→ <|"Status", "Diff" -> _Association, "Event" -> _Association|>

### SourceVaultBundlesForSnapshot[snapshotId] → List
指定 snapshot を参照する全 bundle id リストを返す。全 bundle ファイルを読み Sources[].SnapshotId 一致を収集。

### SourceVaultSourceEvents[opts] → List
events/source-events.jsonl の全 event リストを返す。
Options: "SourceId" -> _String, "SnapshotId" -> _String, "EventType" -> "VersionedUpdate" | "Retraction" | "SourceDeletion" | "SchemaChange"

### SourceVaultSourceEventAppend[event] → Association
event Association を source-events.jsonl に append。EventType / SourceId / Reason は必須、OldSnapshotId / NewSnapshotId / Metadata は任意。EventId と Timestamp は自動生成。

## Model Registry 設定

### $SourceVaultModelEndpoints
型: Association
provider 名からモデル一覧エンドポイント設定への Association。各値は <|"ModelsURL", "Kind" -> "Cloud"|"Local", "AuthProvider"|>。ユーザ上書き可。

### SourceVaultModelEndpointStatus[] → Association
各 provider エンドポイントの到達性 (オフライン検知) を返す。401/403 でもサーバ到達 = Online とみなす。
→ <|"Status", "Endpoints" -> <|provider -> <|"Status" -> "Online"|"Offline", ...|>|>|>

### SourceVaultDetectLocalModels[opts] → Association
ローカル LLM サーバ (LM Studio 等、OpenAI 互換 /v1/models) からモデル一覧を推測。API キー不要。キー保護有効ならば NBAccess`NBGetLocalLLMAPIKey 経由で自動解決。
→ <|"Status" -> "OK"|"Offline", "Provider", "Endpoint", "Models" -> {_String..}|>
Options: Provider -> "lmstudio", Endpoint (default ClaudeCode`$ClaudePrivateModel の url 優先)

### SourceVaultSetModel[provider, intent, modelId, opts] → Association
compiled model registry に手動で 1 エントリを書き込む (API キー不要)。Source -> "manual" で保存、同 (provider, intent) の既存を置換。
Options: Channel -> "public", Class -> Automatic (推論), Capabilities -> Automatic, "ContextLength" -> _Integer, "Integrations" -> {_String...}
例: SourceVaultSetModel["lmstudio", "local-heavy", "qwen/qwen3-coder-30b", "Integrations" -> {"mcp/exa"}, "ContextLength" -> 32000]

### SourceVaultClearModelRegistry[opts] → Association
compiled model registry を削除し、次回アクセス時に seed (コード内 iModelSeedEntries) から再構築させる。古い seed コピー残存で ClaudeResolveModel が古い ID を返す時の復旧用。seed 自体は消さない。
Options: Channel -> "public"

### SourceVaultSetModelIntent[variable, spec] → Association
SourceVault が選択するモデルの intent 割当てを変更。variable: "$ClaudeModel" | "$ClaudeDocModel" | "$ClaudePrivateModel" | "$ClaudeFallbackModels"。spec: {provider, intent}、FallbackModels は {{provider,intent}, ...}。設定後 SourceVaultAssignClaudeModels[] で実変数に反映。$NBApprovalHeads 登録済 (ClaudeEval 経由は Hold -> Approve 必要)。
例: SourceVaultSetModelIntent["$ClaudeModel", {"anthropic", "heavy"}]

### SourceVaultModelIntentMap[] → Association
変数名 -> intent spec のマッピングを返す読み取り公開関数。NBAccess`NBSyncClaudeModelVars が読んでモデル変数を解決・代入する。

### SourceVaultAssignClaudeModels[opts] → Null
intent マッピング (SourceVault) と信頼ローカルサーバ (NBAccess`NBResolveLocalServer) から $ClaudeModel / $ClaudeDocModel / $ClaudePrivateModel / $ClaudeFallbackModels を設定。SourceVault ロード時に自動実行。
Options: Verbose -> False

### SourceVaultRefreshModelRegistry[opts] → Association
クラウド (anthropic/openai) とローカル (LM Studio) のエンドポイントからモデル一覧を取得し compiled model registry を更新。クラウド API キーは NBAccess`NBGetAPIKey 経由、キー無し provider はスキップ。取得分は Source -> "auto-fetch" マーク、既存 seed/manual は温存マージ。
→ <|"Status", "FetchedCount", "RegistryTotal", "PerProvider", "RegistryPath"|>
Options: Providers -> All, IncludeCloud -> Automatic, DryRun -> False

## Stage 9: Notebook Management

### SourceVaultRegisterNotebook[path] → Association
指定 path の notebook を登録。NotebookRef は path-based hash で安定生成。
→ <|"Status", "NotebookRef", "Path", "RegisteredAt"|>

### SourceVaultIndexNotebook[path, opts]
notebook の Header / Todo / Cell を抽出して index を更新。
→ <|"Status", "NotebookRef", "SnapshotId", "Header", "TodoCount", "OpenTodoCount", "ReviewState", "DeadlineState", "Lint" -> {...}|>
Options: "ExtractHeader" -> True, "ExtractTodos" -> True, "ForceReindex" -> False (file mtime 同じなら skip)

### SourceVaultIndexNotebookFolder[dir, opts]
指定 folder 配下の .nb を全て index。
→ <|"Status", "Processed" -> _Integer, "Failed" -> _Integer, "Results" -> {...}|>
Options: "Recursive" -> False, "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}

### SourceVaultExtractNotebookHeader[path] → Association
notebook 先頭 Input セルから Header を safe parse (HoldComplete + whitelist で RunProcess/Get/Import 等拒否)。
→ <|"ParseStatus" -> "OK"|"MissingHeader"|"UnsafeExpression", "Keywords", "Deadline", "NextReview", "Status"|>

### SourceVaultExtractNotebookTodos[path] → List
notebook 内の TodoItem スタイルセルを列挙。Status は 3 値 (Open/Done/Pass)。判定優先順位: TaggingRules > FontVariations StrikeThrough + FontColor > Default。StrikeThrough なし→Open、StrikeThrough+緑→Done、StrikeThrough+灰→Pass、StrikeThrough+その他→Done。
→ {<|"Text", "Status", "StatusSource", "StrikeThrough" -> _Bool|>, ...}

### SourceVaultFindNotebooks[opts] → List
index 済み notebook を検索する deterministic query (LLM 不要)。
→ {record, ...}。各 record: <|"Path"/"OriginalPath", "Title", "NotebookRef", "Header", "Todos" -> {<|"Text", "Status"|>...}, "TodoCount", "OpenTodoCount", "DoneTodoCount", "PassTodoCount", "ReviewState", "DeadlineState", "Lint"|>
Options:
"OpenTodos" -> True | False
"NextReview" -> "Today" | "Overdue" | "ThisWeek" | "DueSoon" | <|"From", "To"|> ("Today" は厳密に今日のみ、"ThisWeek"/"DueSoon" は今日±7日以内、"Overdue" は期限切れ全部)
"Deadline" -> "Today" | "Overdue" | "ThisWeek" | "DueSoon" | <|"From", "To"|>
"Keywords" -> {_String...} | _String (Header.Keywords + Title + FileBaseName + 親フォルダ名を部分一致 OR 検索)
"Title" -> _String | {_String...} (Keywords と同じ検索プール)
"Status" -> "Todo" | "Done" | _String
"Scope" -> "Today" (NextReview==今日 | Deadline==今日 | Path に YYYYMMDD で今日 の OR)
"ForceReindex" -> False (True で mtime/hash cache 無視し全再 index)
"Format" -> False (True で SourceVaultFormatNotebookList の Grid を返す)
todo 項目自体を列挙する場合は record["Todos"] を使う (再抽出回避)。

### SourceVaultFindTodos[opts] → List
条件に合う notebook の todo 項目をフラットな List で返す。マッチした各 notebook の todo セルを 1 行 1 項目に展開する。「今週期限の todo をリスト」のような todo 単位の要求向け。
→ {<|"Title", "Path", "NotebookRef", "Deadline", "NextReview", "ReviewState", "DeadlineState", "TodoText", "TodoStatus", "TodoStrikeThrough"|>, ...} (Format->True で Grid)
Options: "TodoStatus" -> "Open" (default) | "Done" | "Pass" | All, "Format" -> False。その他は SourceVaultFindNotebooks と共通 (OpenTodos/NextReview/Deadline/Keywords/Title/Status/Scope)

### SourceVaultNotebookLint[record] → List
notebook record (または path) に対し lint チェック。
→ {"LintName1", ...}
検出: MissingHeader / UnsafeHeaderExpression / HeaderDeadlineMalformed / HeaderNextReviewMalformed / HeaderStatusTodoButNoOpenTodos / HeaderStatusDoneButOpenTodosExist / DeadlinePast / NextReviewPast / TodoCellStatusHeuristicOnly

### SourceVaultFormatNotebookList[records, opts] → Grid
notebook record の List をスケジュール表と同形式 (Deadline / NextReview / Title / Dir / OpenTodos / Status / Summary / Publishable) の Grid 表示。SourceVaultFindNotebooks の返値、IndexNotebook の OK record、Path/Header を持つ任意 Association List を受け付ける。
Options: "Refresh" -> "Never" | "IfStale" | "Force", "FallbackToCloud" -> "Deny" | "Ask" | "Allow", "UseCache" -> True

### SourceVaultUpcomingSchedule[opts] → Dataset
「今日から N 日以内」に Deadline / NextReview がある notebook 一覧を Dataset で返す。概要もキャッシュから取込 (必要時自動再生成)。日付は yyyy/mm/dd、期限切れは赤、今日/明日は青。
Options:
"Scope" -> dir (default $onWork または $packageDirectory)
"Period" -> Quantity[7, "Days"]
"IncludeOverdue" -> True
"Recursive" -> True
"Refresh" -> "Never" | "IfStale" | "Force" (Never は保存済 Summary だけ表示、無ければ Keywords をツールチップに fallback)
"FallbackToCloud" -> "Ask" | "Allow" | "Deny"
"StatusFilter" -> {"Todo"} (default) | {"Todo", "Done", "Pass"} | All
"UseCache" -> True

### SourceVaultNewNotebook[opts] → Association
テンプレートから新規ノートブックを CreateNotebook で開く (未保存)。テンプレートを複製し NotebookStatus セルの Deadline/NextReview を生成日に置換。
→ <|"Status" -> "OK", "Notebook" -> _NotebookObject, "Date", "StatusCellReplaced" -> _Bool, "Saved" -> False, ...|>
Options: "TemplatePath" -> Automatic | path, "Title" -> Automatic | _String, "Date" -> Automatic | _DateObject

### SourceVaultRefreshAllSummaries[opts] → Association
Scope 配下全 notebook の概要を一括再生成する。
→ <|"Status" -> "OK", "Scope", "TotalFiles", "Refreshed", "Cached", "Inconsistent", "Failed", "Details"|>
Options: "Scope" -> dir (default $onWork), "Recursive" -> True, "ForceRefresh" -> False, "FallbackToCloud" -> "Deny", "OpenTodosOnly" -> False, "Model" -> Automatic, "Progress" -> False, "Limit" -> Infinity

## Stage 9 P1: TaggingRules / SemanticHash / Summary

### SourceVaultExtractNotebookTaggingRules[path] → Association
notebook 全体および各 TodoItem cell の TaggingRules を取得。`Import[path, "Notebook"]` の Notebook 式から + `NotebookImport[path, style -> "Cell"]` で各 cell options から抽出。
→ <|"Status" -> "OK"|"Failed", "Path", "NotebookTaggingRules" -> _Association (無ければ <||>), "CellTaggingRules" -> {<|"Index" -> _Integer, "CellStyle" -> _String, "TaggingRules" -> _Association|>, ...}|>

### SourceVaultNotebookSemanticHash[path] → Association
notebook の意味的内容のみを対象にしたハッシュを計算。表示メタデータ (ExpressionUUID/CellChangeTimes/CellLabel/FontFamily) やウィンドウ設定 (WindowSize/WindowMargins/FrontEndVersion) は除外し、意味的に重要な要素 (content/style/TaggingRules/FontVariations/FontColor/Background) のみハッシュ。formatting のみの変更で Stale 化誤判定を防ぐ。
→ <|"Status" -> "OK"|"Failed", "Path", "SemanticHash" -> _String|>

### SourceVaultRegisterNotebookSummary[path, summary, opts] → Association
notebook の summary artifact を登録。現在の snapshot (SnapshotId + SemanticHash) と紐づけて保存し、後日 stale 判定可能。
→ <|"Status" -> "OK"|"Failed", "SummaryId", "NotebookRef", ...|>
Options: "SummaryFormat" -> "text" (default) | "markdown", "GeneratedBy" -> "manual"

### SourceVaultGetNotebookSummary[path] → Association
notebook に紐づく summary record を取得。未登録なら "Status" -> "Missing"。
→ <|"Status" -> "OK"|"Missing"|"Failed", "Summary", "SummaryFormat", "BasedOnSnapshot", "BasedOnSemanticHash", "GeneratedBy", "CreatedAt"|>

### SourceVaultNotebookSummaryStatus[path] → Association
summary artifact の現在 lifecycle ステータスを判定。
→ <|"Status" -> "Missing"|"Current"|"StaleFormattingOnly"|"Stale", "Reason", "CurrentSnapshot", "SummaryBasedOnSnapshot" -> _String|_Missing|>
Missing: summary 不在。Current: BasedOnSnapshot が現在と一致。StaleFormattingOnly: SemanticHash 一致 (formatting のみ変更、再生成任意)。Stale: SemanticHash 変化 (再生成推奨)。

### SourceVaultNotebookSummary[path, opts] → Association
notebook 内容を LLM で要約し Summary artifact として保存。内部で SourceVaultRegisterNotebookSummary を呼ぶため lifecycle 管理自動。default PrivacyLevel = 1.0 (ローカル LM 経由で API に送らない)。
→ Current で ForceRefresh 無し: 既存 record。生成成功: Register 同形 Association。Inconsistent: <|"Status" -> "Inconsistent", "Reason", ...|>。失敗: <|"Status" -> "Failed", "Reason", ...|>
Options: "ForceRefresh" -> False, "MaxLength" -> 500, "Language" -> Automatic | "Japanese" | "English", "Model" -> Automatic | {"provider", "model"}, "PrivacyLevel" -> 1.0 (0.0=API許可〜1.0=ローカルのみ), "FallbackToCloud" -> "Ask" | "Allow" | "Deny"

### SourceVaultMarkTodo[path, target, newStatus, opts] → Association
notebook 内の Todo cell の Status を変更する書き込み系 API。NBAccess の NBWriteTodoStatus への薄いラッパー。Cell options (StrikeThrough + FontColor 緑/灰) と Cell TaggingRules (<|"SourceVault" -> <|"TodoStatus" -> newStatus|>|>) を変更。
target: Integer (1-based Todo Index) | String (TodoId) | Association (<|"Index", "Text"|>)。newStatus: "Open" | "Done" | "Pass"。
→ DryRun: <|"Status" -> "DryRunOK", "Target", "MatchedTodo", "OldStatus", "NewStatus", "CellPath" -> {_Integer...}, "Before" -> HoldComplete[...], "After" -> HoldComplete[...]|>
→ 実行: <|"Status" -> "OK"|"Failed", "Target", "MatchedTodo", "OldStatus", "NewStatus", "ReindexResult" -> _Association | Missing["NotRequested"]|>
Options: "DryRun" -> True (default、安全側), "AutoReindex" -> True (実行時のみ), "AccessSpec" -> <|"AccessLevel" -> 0.7, ...|>

## Notebook UUID

### SourceVaultNotebookUUID[path] → String | Missing[]
notebook に埋め込まれた UUID (TaggingRules > SourceVault > NotebookUUID) を返す。読み取りのみ。

### SourceVaultEnsureNotebookUUID[path, opts] → Association
notebook に UUID が無ければ生成して埋め込む。UUID は notebook 自身の TaggingRules に保存され、ファイル名変更・内容編集をまたいで安定 (Relink の最も信頼できる照合キー)。
→ <|"Status", "Path", "UUID", "Created" -> True|False|>
Options: Force -> False (True で既存も再生成)

### SourceVaultEnsureNotebookUUIDFolder[dir, opts] → Association
folder 配下の .nb 全てに UUID 付与。
→ <|"Status", "TotalFiles", "Created", "AlreadyPresent", "Skipped" (巨大ファイル等), "Failed"|>
Options: Recursive -> True, ExcludePatterns, MaxFileSizeMB (default $SourceVaultMaxFileSizeMB)

## Stage 3: Context retrieval / Span / Attach

### SourceVaultSpan[snapshotOrRef, opts] → Association
SourceSpan association を作る。snapshotOrRef は SnapshotId / SourceRef / file path。
Options: "Pages" -> {1, 3, 5} | All | _Integer, "Role" -> "ReferenceContext" | "Evidence" | "ExtractionInput", "Purpose" -> "LaTeXMathFormatting" | _String

### SourceVaultContext[sourceSpan, opts] → String
sourceSpan の plaintext を取り出し、NBAuthorize の判定付きで LLM 文脈として返す。
Options: MaxCharacters, "Sink", "Purpose"

### SourceVaultContextAssemble[sourceSpans, opts] → String
複数 span を 1 つの prompt context に組み立てる。
Options: "Purpose" -> _String, MaxCharacters -> _Integer, "Ordering" -> "PageOrder" | "Citation" | "GivenOrder", "Separators" -> "ByPage" | "BySource" | None, "IncludeCitations" -> True | False, "Sink" -> _Association

### SourceVaultAttach[nb, source, opts] → Association
notebook に source を attach し TaggingRules に sourceVaultRefs を記録。旧 ClaudeAttach のバックエンド代わり。

### SourceVaultAttachToCell[nb, cellIdx, sourceSpan, opts] → Association
cell に SourceSpan を attach する。

### SourceVaultGetAttachments[nb] → List
notebook に attach された source 一覧を返す。

### SourceVaultGetCellSources[nb, cellIdx] → List
cell に紐づく SourceSpan リストを返す。旧形式 (refSources) を read-only normalization して返す。

### SourceVaultEnsureRegistered[ref] → Association
旧 refSources 形式 (または file path) を SourceSpan 形式に normalize。必要に応じ ingest する。

## Materialization / Path 解決

### SourceVaultMaterializeForSink[sourceRef, sinkSpec, opts] → Association
source を cloud-accessible mirror へ materialize。内部で必ず NBAuthorize を呼ぶ。

### SourceVaultResolvePath[ref, opts] → String
source/snapshot の物理 path を返す。"Tier" -> "PrivateVault" は local kernel / maintenance 専用。cloud LLM 向けには SourceVaultMaterializeForSink を使う。

### SourceVaultObjectSpec[ref, opts] → Association
source/snapshot を NBAuthorize が受け取れる object spec association に変換する。

## Ingest オプションシンボル
Topic / PinVersion / TrustLevel / PrivacyLabel — SourceVaultIngest のオプション。MaxCharacters — SourceVaultContext / SourceVaultContextAssemble のオプション。

## Sync / Relink

### SourceVaultSetSnapshotPrivacyLevel[snapshotId, level] → Association
snapshot record の PrivacyLevel を明示的に上書き。NBAccess`NBSetSnapshotPrivacyLevel の委譲先。承認ゲートは NBAccess 側の $NBApprovalHeads 登録で発火。Notebook snapshot と PDF/URL snapshot の両系統をファイル存在で判別。level は 0.0-1.0 に clip。既存値より低い値指定時は "Lowered" -> True を返す (手動操作なので許可)。
→ <|"Status", "SnapshotId", "OldPrivacyLevel", "NewPrivacyLevel", "Lowered", "SnapshotKind"|>

### SourceVaultSelectSources[opts] → Association
同期対象となる source を選定して返す。Scope 配下の .nb をスキャンし source descriptor 化。
→ <|"Status", "Scope", "Count", "Sources" -> {_Association..}|>
Options: Scope / Recursive / Kind / ExcludePatterns

### SourceVaultSyncPlan[opts] → Association
各 source の鮮度を判定し同期計画を返す (dry-run、副作用なし)。鮮度トークン (ローカルは mtime) を現 snapshot と比較し Fresh/Stale/Missing/NeverIndexed に分類。
→ <|"Status", "Total", "StaleCount", "Plan" -> _Dataset, ...|>
Options: Scope / Recursive / Kind / ExcludePatterns

### SourceVaultSync[opts] → Association
SyncPlan に従い Stale な source を再 index (クローラー骨格)。PrivacyLevel は単調 (自動で下げない)。再 index で下がった場合は SetSnapshotPrivacyLevel で旧値に引き上げ警告記録。sync/sync-history.jsonl に記録、sync/last-sync.json 更新。
→ <|"Status", "SyncId", "Refreshed", "Skipped", "Failed", "PrivacyWarnings"|>
Options: Scope / Recursive / Kind / DryRun / ForceAll / RefreshSummary / FallbackToCloud (default "Deny")

### SourceVaultSyncStatus[] → Association
直近の sync 実行状態 (sync/last-sync.json) を返す。未実行なら <|"Status" -> "NoSyncYet"|>。

### SourceVaultRelinkSources[opts] → Association
OriginalPath が存在しなくなった (移動された) notebook source を検出し Scope 配下から移動先を再リンク。照合は (1) 埋込 UUID、(2) 内容ハッシュ (RawContentHash 完全一致)、(3) ファイル名一意一致 の順。移動判定はシンボリックパス解決ベース (PC・ルートパス差を移動と誤検出しない)。マッチ先が別の現役 record の実ファイルなら StaleDuplicate (旧 PC index の残骸) として分類。
→ <|"Status", "Linked", "Relinked" -> {..}, "RelinkedCount", "ByMethod" -> <|"UUID"/"ContentHash"/"NameOnly"|>, "Unresolved" -> {..}, "DryRun"|>
Options: Scope / Recursive / DryRun (default True) / ApplyNameOnly (default False) / DeleteStale (default False) / ExcludePatterns

## Integration hooks

### SourceVaultClaudeAttachIntegrationEnable[] → Association
ClaudeAttach 呼出時に SourceVault へ side-channel ingest する hook を有効化。既に有効なら noop。元の DownValue は保持され Disable で復元可。前提: claudecode.wl (ClaudeCode`ClaudeAttach) ロード済み。

### SourceVaultClaudeAttachIntegrationDisable[] → Association
hook を外し ClaudeAttach を元の DownValue に復元する。

### SourceVaultClaudeAttachIntegrationStatus[] → Association
現在の hook 状態。Keys: Enabled, OriginalSaved, OriginalDVCount, HookTarget。

### SourceVaultGetClaudeAttachRefs[nb] → List
notebook nb に紐づいた ClaudeAttach side-channel ingest 記録の flat list。各 entry: OriginalPathOrURL / ExpandedPath / SnapshotId / SourceId / ContentHash / IngestStatus / AttachedAt。引数なしで EvaluationNotebook[] を使う。

### SourceVaultClaudeAttachmentsIntegrationEnable[] → Association
ClaudeAttachments[] 呼出時に返値を List of paths から Association list に拡張する hook を有効化。各 Association に cached path / source / metadata + SnapshotId / SourceId / ContentHash / IngestStatus が join される。前提: claudecode.wl (ClaudeCode`ClaudeAttachments) ロード済み。

### SourceVaultClaudeAttachmentsIntegrationDisable[] → Association
hook を外し ClaudeAttachments を元の DownValue に復元する。

### SourceVaultClaudeAttachmentsIntegrationStatus[] → Association
現在の hook 状態を返す。

### SourceVaultWorkerPromptIntegrationEnable[] → Association
ClaudeOrchestrator の A5 hook に SourceVault context 注入関数を登録し、worker prompt 構築時に吹出されるようにする。トリガー: task["SourceSpans"] (明示) + ClaudeAttach 履歴 (自動検出)。前提: ClaudeOrchestrator.wl に A5 hook 追加済み。

### SourceVaultWorkerPromptIntegrationDisable[] → Association
A5 hook の定義をクリアし ClaudeOrchestrator は A5 hook をスキップする。

### SourceVaultWorkerPromptIntegrationStatus[] → Association
現在の A5 hook 状態を返す。

### $SourceVaultWorkerPromptAutoDetect
型: Boolean, 初期値: True
A5 hook 有効時の自動検出 ON/OFF。True: ClaudeAttach 履歴から SnapshotId を自動検出して注入。False: task["SourceSpans"] 明示指定のみ。

### SourceVaultParseProposalIntegrationEnable[] → Association
ClaudeOrchestrator の A6 hook に parseProposal post-processing 関数を登録。LLM 応答内の `<source>snap-...</source>` / `<source>src-...</source>` XML タグを抽出し parseProposal の返値 Association に "SourceVaultRefs" キーを追加。前提: ClaudeOrchestrator.wl に iApplyA6Hook + A6 hook 呈入済み。

### SourceVaultParseProposalIntegrationDisable[] → Association
A6 hook の定義をクリアし iApplyA6Hook を no-op に戻す。

### SourceVaultParseProposalIntegrationStatus[] → Association
現在の A6 hook 状態を返す。

## Phase 2a: DirectiveRepository (ClaudeDirectives 連携、lazy Needs)

### SourceVaultRegisterDirectiveRepository[root] → Association
Claude Directives リポジトリ (ディレクトリ) を DirectiveRepository source として登録。RepoId はリポジトリ root path から決定的に導出。
→ <|"Status", "RepoId", "Root", "Path", "Registration"|>

### SourceVaultIndexDirectiveRepository[root] → Association
Claude Directives リポジトリを index: ClaudeDirectives` でファイル inventory と manifest hash を計算し DirectiveRepository snapshot record を書く。必要なら自動登録。
→ <|"Status", "RepoId", "SnapshotId", "ManifestHash", "FileCount", "Path", "Snapshot"|>

### SourceVaultDirectiveRepositoryStatus[root] → Association
リポジトリの登録有無、snapshot 数、最新 snapshot の manifest hash がディスク上のリポジトリと一致するかを報告。Status: "NotRegistered" | "RegisteredNotIndexed" | "UpToDate" | "Stale"。

### SourceVaultCurrentDirectiveSnapshot[root] → Association
最新の DirectiveRepository snapshot record を返す。無ければ Status -> "NoSnapshot"。

### SourceVaultDiffDirectiveSnapshots[old, new] → Association
二つの DirectiveRepository snapshot record (または snapshot file path) を RelativePath/ContentHash で比較。
→ <|"Status", "Added", "Removed", "Changed", "UnchangedCount", "ManifestHashChanged"|>

## Phase 2b: HarnessMaterialization bundle

### SourceVaultRegisterHarnessMaterialization[target, files, meta] → Association
materialized harness を HarnessMaterialization bundle として登録。target は "Codex" または "ClaudeCLI"、files は生成ファイルパスリスト、meta は HarnessMode / DirectiveRoot / DirectiveRepositorySnapshotId / DirectiveRepositoryManifestHash / RuntimeEnvironmentHash / PermissionProfileHash / Generator を供給。bundle は SourceVault bundles ディレクトリに保存され SourceVaultBundleGet で読める。
→ <|"Status", "BundleId", "Path", "Bundle"|>

### SourceVaultDirectiveSnapshotStaleQ[bundle] → Association
HarnessMaterialization bundle が build された canonical Claude Directives snapshot が stale かを、bundle の DirectiveRepositoryManifestHash と現在のリポジトリ hash 比較で報告。stale なら harness 再生成すべき。
→ <|"Stale", "Reason", "RecordedManifestHash", "CurrentManifestHash"|>

### SourceVaultHarnessRuntimeEnvironmentChangedQ[bundle, currentEnv] → Association
HarnessMaterialization bundle の runtime environment (permission profile / temp project path / attachments) が変わったかを報告。currentEnv は precomputed PermissionProfileHash / RuntimeEnvironmentHash、または raw PermissionProfile / RuntimeEnvironment association を持てる。runtime 変化は config.toml 再生成を要するが canonical snapshot は stale にしない。