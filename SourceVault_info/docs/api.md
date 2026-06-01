# SourceVault API リファレンス

外部 source（PDF/URL/arXiv/Notebook）を content-addressed に管理し、ingest・snapshot・claim 抽出・evidence bundle・notebook 管理・compiled model registry を提供するパッケージ。依存: [NBAccess](https://github.com/transreal/NBAccess)（NBAuthorize を毎回呼ぶ）。LLM/Claude 連携は [claudecode](https://github.com/transreal/claudecode) 経由。
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault.wl"]]`（または claudecode.wl 経由で自動）。
物理ストレージ tier: PrivateVault（authoritative 正本、Dropbox 配下、cloud LLM に直接読ませない）/ CloudMirror（$ClaudeWorkingDirectory mirror）/ Tmp / AttachmentMirror（$packageDirectory/claude_attachments）。

## Bootstrap / 設定

### $SourceVaultVersion
型: String
SourceVault パッケージのバージョン文字列。

### $SourceVaultRoots
型: Association
SourceVault の物理 root ディレクトリマッピング。Keys: "PrivateVault" | "CloudMirror" | "Tmp" | "AttachmentMirror" | "ExternalOwned"。PrivateVault が authoritative storage。CloudMirror/AttachmentMirror は materialize 済み projection のみ。

### $SourceVaultSeedModelRegistry
型: Association
bootstrap 時の fallback model registry。production truth ではなく compiled registry 不在時の災害復旧用。LLM 自動更新しない、更新は review 必須。

### $SourceVaultMaxFileSizeMB
型: Integer, 初期値: 50
index 時に .nb を Import するファイルサイズ上限 (MB)。超過 .nb は Import せず軽量 snapshot を作る (Skipped マーク)。

### $SourceVaultCloudRoots
型: List
クラウド共有フォルダのシンボル名リスト。例: {"$packageDirectory", "$dropbox", "$onWork", "$offWork", "$mathematicaWork"}。絶対パスはこれら配下なら {"$onWork", "folder", "file.nb"} 形式のシンボリックパスに正規化され、PC/OS をまたいで同一 ID になる。

### $SourceVaultCloudRootAliases
型: Association, 初期値: <||>
クラウドルートのシンボル名から旧 PC 等別環境での絶対パスリストへの対応。形式: <|"$onWork" -> {"C:/Users/imai_/Dropbox/On Work"}, ...|>。別 PC で index された旧パスを正規化し二重登録を防ぐ。

### SourceVaultInitialize[opts]
SourceVault の物理 root を生成し初期化。PrivateVault, Tmp は必須。作成済みなら noop。
→ Association
Options: "Roots" -> $SourceVaultRoots (override), "Force" -> False (True で再初期化)

### SourceVaultStatus[sourceRef] → Association
指定 source/snapshot/ファイルの概要。引数なし SourceVaultStatus[] は vault 全体の概要。

### SourceVaultList[] → List
vault 内の全 source ID リスト。

### SourceVaultSnapshots[sourceRef] → List
指定 source に限定した snapshot ID リスト。

### SourceVaultResetStore[opts]
notebooks ストア (sources/snapshots/summaries/todos/review/lint/sync/relink) を全削除して初期化。破壊的操作。
→ <|"Status" -> "OK"|"DryRun"|"Failed", "Deleted" -> _List, "NotebooksDir" -> _|>
Options: "Confirm" -> False (無いと DryRun 扱いで実削除しない)

## Lookup / Resolve（Compiled Registry）

### SourceVaultLookup[topic, key, opts]
compiled registry から key に対応する entry を返す。network/LLM なし。
→ entry Association または Missing["NotFound"]
topic: "model-registry" | "mathematica-graph-options" | _String。key: String または Association。compiled に無ければ seed に fallback。
Options: "Channel" -> "public" (| "private"), "AllowSeed" -> True (compiled 無し時 seed 使用)

### SourceVaultResolve[kind, query, opts]
compiled registry から query に match する entry を返す。deterministic、network/LLM なし。
→ entry Association または Missing["NotFound"]
kind: "Model" | _String。query: <|"Provider" -> ..., "Intent" -> ...|>。複数 match 時は Availability != "Unavailable" をフィルタ、Class/Freshness で sort し先頭を返す。
Options: "Channel" -> "public" (| "private"), "AllowSeed" -> True, "Topic" -> "<kind>-registry" を小文字化
例: SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]

### ClaudeResolveModel[provider, intent] → Association
SourceVaultResolve["Model", ...] の互換 wrapper（旧 WikiDBResolveModel 置換）。
例: ClaudeResolveModel["anthropic", "heavy"]

### SourceVaultListModels[provider] → List
指定 provider に登録された選択可能な全モデル ID リスト（catalog 列挙、Resolve は最適 1 件）。compiled 優先、無ければ seed fallback。Unavailable は除外。

### SourceVaultModelContextLength[provider, modelId] → Integer | None
モデルに紐づく ContextLength（SourceVaultSetModel で永続化された値）。LM Studio 等ローカル LLM の context_length 用。未設定なら None。

### SourceVaultModelIntegrations[provider, modelId] → List | None
モデルに紐づく LM Studio MCP integrations リスト。LM Studio /api/v1/chat の integrations パラメータ用。未設定なら None。
例: SourceVaultSetModel["lmstudio", "local-heavy", "qwen/qwen3-coder-30b", "Integrations" -> {"mcp/exa"}, "ContextLength" -> 32000]

### SourceVaultListRegistries[opts] → Association
登録済み registry topic と channel。
Options: "Channel" -> All (| "public" | "private")

### SourceVaultRegistryStatus[topic, opts]
指定 topic の registry 状態。
→ <|"Topic", "Channel", "CompiledPath", "CompiledExists" -> _Bool, "CompiledCount" -> _Integer, "SeedPath", "SeedExists" -> _Bool, "SeedCount" -> _Integer, "LastModified"|>
Options: "Channel" -> "public" | "private"

### SourceVaultCompileRegistry[topic, entries, opts]
entries (List of Association) を compiled registry に保存。
→ <|"Status", "Topic", "Channel", "Path", "Count" -> _Integer|>
topic: "model-registry" 等。entries: {<|"Provider" -> ..., "Intent" -> ..., "ModelId" -> ...|>, ...}
Options: "Channel" -> "public" (| "private"), "Sources" -> {_String, ...} (関連 claim/snapshot id), "PolicySource" -> _String

### SourceVaultRegisterSeed[topic, entries] → Association
seed entries を seeds/<topic>-seed.json に保存（bootstrap 用）。seed は compiled 不在時の fallback のみ。

## Ingest

### SourceVaultIngest[source, opts]
外部 source を登録し raw snapshot を PrivateVault に保存。
→ Association（同期時 Status: Ingested/AlreadyCurrent/RebuiltMetadata、Asynchronous 時は JobId 即時 return で Status: Queued）
source: ローカルファイルパス（content-addressed raw に transactional copy）/ HTTPS・HTTP URL（URLDownload で fetch）/ arXiv:NNNN.NNNNN[vN]（arxiv.org/pdf/... に canonicalize）。
Options:
Topic -> Automatic | _String
TrustLevel -> Automatic | "OfficialAPI" | "OfficialDocs" | "PublicWeb" | "LocalFile"
PrivacyLabel -> Automatic | _Real
PinVersion -> True | False | Automatic
Asynchronous -> False (True 時 LLMGraphDAGCreate 経由でジョブ投入し JobId 即時 return、LLMGraphDAGCreate 必須)
EnsureUUID -> Automatic | True | False (.nb 取込時の UUID 自動付与。Automatic/True は hash 計算前に SourceVaultEnsureNotebookUUID を呼ぶ。.nb 以外と巨大ファイルはスキップ、付与失敗でも ingest 継続)

### SourceVaultIngestWait[ingestResult, timeoutSec] → Association
非同期 ingest の完了を待つ。sync 完了済み (Ingested/AlreadyCurrent/RebuiltMetadata) なら即 return。Status: Queued なら SourceId の snapshot 増加を polling し新規 snapshot 出現で完了。timeoutSec (既定 60) 超過で Status: Timeout。第一引数は SourceVaultIngest 結果 Association または SourceId String。

## PDF page extraction

### SourceVaultExtractPages[snapshot, pages, opts]
snapshot の指定 page を抽出し cache に保存。
→ <|"Status", "SnapshotId", "Pages" -> {n: text, ...}, "Hashes" -> <|...|>, "CachedFrom" -> "Disk"|"Fresh"|"Mixed", "OCRCalled" -> True|False|>
snapshot: SnapshotId String または SourceId String (latest snapshot)。pages: Integer | List of Integer | All。各 page を parsed/by-snap/<id>/pages/NNNN.txt に cache、page-hashes.json に SHA-256 保存、cache hit 時は Import しない。抽出結果が空 or 5 文字未満なら $SourceVaultOCRHook を呼ぶ。
Options:
Force -> False (cache 無視して再抽出)
"ForceOCR" -> False (この呼出だけ OCR 強制、スキャン判定スキップ、hook 必須。True 時は Force -> True も自動適用)

### $SourceVaultOCRHook
型: None | Function, 初期値: None
スキャン PDF の fallback 値。シグネチャ: Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String。SourceVaultExtractPages がページテキスト抽出失敗時に呼び、返値が text として cache される。SourceVaultOCREnable 経由設定推奨。

### $SourceVaultOCRMode
型: String, 初期値: "Auto"
OCR 発火モード。"Auto": Plaintext 抽出が 5 文字未満の時のみ OCR。"Force": 長さに関わらず常に OCR（低品質テキスト層を持つ PDF 群の全ページ再 OCR 用）。SourceVaultOCREnable[..., "Mode" -> "Force"] で永続化、SourceVaultOCRDisable[] で "Auto" にリセット。

### $SourceVaultOCRVerbose
型: Boolean, 初期値: False
OCR 実行時の進捗 Print を制御。True で rasterization/API 呼出/レスポンス長等を Print（デバッグ用）。

### SourceVaultOCREnable[backend, opts]
OCR hook を有効化。
→ <|"Status" -> "Enabled", "Backend" -> _String, "Mode" -> _String, "Options" -> _Association|>
backend (既定 "ClaudeVision"): "ClaudeVision" | "TextRecognize" | "Custom"
"ClaudeVision": ClaudeCode`ClaudeQueryBg 経由で Claude API に page 画像送り OCR。大きい page は自動で上下分割 (30px overlap) し 2 回 OCR マージ。Options: "DPI" -> 300, "SplitHalves" -> True, "Timeout" -> 180, "Prompt" -> Automatic
"TextRecognize": 組込 TextRecognize (Python 不要)。Options: "DPI" -> 150, "Language" -> "Japanese"
"Custom": ユーザ Function をそのまま $SourceVaultOCRHook に設定。Options: "Hook" -> Function[req, text]
共通 Option: "Mode" -> "Auto" (| "Force")

### SourceVaultOCRDisable[] → Association
OCR hook を無効化 ($SourceVaultOCRHook = None)。

### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定。Backend: Disabled/ClaudeVision/TextRecognize/Custom、HookSet: _Bool。

## Claim 抽出

### SourceVaultExtract[sourceSpan, schema, opts]
sourceSpan の page text を LLM に渡し claim を抽出。
→ <|"Claims" -> {...}, "Count" -> _Integer (実納数), "ExtractedCount" -> _Integer, "DedupSkipped" -> _Integer, "AccessDecisions" -> <|"Send" -> _, "Persist" -> _|>, "ValidationStatus", "SchemaName", "ExtractedAt" -> DateObject, "Errors" -> {...}|>
Deny 時: <|"Status" -> "DeniedByNBAccess", "Reason", "AccessDecisions"|>。RequireApproval 時: <|"Status" -> "RequiresApproval", ...|>
sourceSpan: SourceVaultSpan[...] 結果 / SnapshotId / SourceId String。schema: 登録済 schema 名 String または インライン Association。
Options:
"Topic" -> _String (既定 schema 名)
"ModelIntent" -> "summary" | "extraction" | "math-extraction-heavy"
"StoreClaims" -> True
"Dedup" -> True (by-source ファイル単位で ContentHash 照合)
"AuthorizationCheck" -> True (Stage 6d: 2 段階 NBAuthorize: sendDecision → 抽出 → persistDecision)
"Validation" -> "None" | "Required"
MaxCharacters -> 8000
Timeout -> 180

### SourceVaultRegisterSchema[name, definition] → Association
抽出 schema をグローバル登録。definition: <|"Description" -> _String, "Fields" -> {<|"Name" -> _, "Type" -> "Number", "Required" -> _Bool, "Description" -> _|>, ...}, "OutputShape" -> "List" | "Single", "PromptTemplate" -> Automatic | _String|>。ビルトイン: "FreeText"/"NumericFacts"/"DefinitionList"。

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
ClaimStore 状態 (debug)。ClaimsDir/MasterPath/MasterExists/MasterClaims (行数)/TopicFiles/SourceFiles。

### SourceVaultClaimStoreCompact[opts]
master+by-topic+by-source を全読みし ContentHash で dedup して全インデックス rebuild。atomic rewrite。dedup 記録は master 先頭行を残す。
→ <|"Status" -> "OK"|"Failed", "BeforeCount" -> _Integer, "AfterCount" -> _Integer, "Removed" -> _Integer, "BackupPaths" -> {...}, "DryRun" -> _|>
Options: "Backup" -> True (.bak.<timestamp>), "DryRun" -> False (True で統計のみ)

## Evidence Bundle

### SourceVaultBundleCreate[name, deps, opts]
generated artifact の依存を evidence bundle として保存。
→ <|"Status" -> "OK"|"Failed", "BundleId" -> _String, "Path" -> _String|>
name: 表示名 (BundleId は自動生成)。deps: <|"GeneratedFiles" -> {...}, "Sources" -> {<|"SourceId" -> _, "SnapshotId" -> _|>, ...}, "SourceSpans" -> {...} (optional), "Claims" -> {...}, "Generator" -> <|"Tool" -> _, "WorkflowId" -> _, "ModelIntent" -> _, "ResolvedModel" -> _|>|>
Options: "Kind" -> "SimulationExample" | "LaTeXExport" | "DocumentGeneration" | "CodeGeneration" | "Notebook" | _String

### SourceVaultBundleGet[bundleId] → Association | Missing["NotFound"]
指定 bundle を読み込む。

### SourceVaultBundleList[] → List
全 bundle id リスト。

### SourceVaultBundleStatus[bundleId] → Association
bundle の現在 Status を計算。参照 snapshot の LifecycleStatus を集約。手動 Invalidate 済みなら強制的に "Invalidated"。
→ <|"Status" -> "Current"|"Stale"|"NeedsReview"|"Invalidated", "Reason", "AffectedSnapshots" -> {...}, "AffectedClaims" -> {...}|>

### SourceVaultBundleInvalidate[bundleId, reason] → Association
bundle を手動 invalidate。reason は記録され後で BundleStatus が返す。

### SourceVaultBundleDelete[bundleId] → Association
bundle ファイルを削除 (debug)。

## vN diff + snapshot lifecycle

### SourceVaultDiffVersions[v1Snap, v2Snap] → Association
二つの snapshot の page hash 集合を比較。各 page-hashes.json を読み page 番号ごとに hash 比較。
→ <|"Status", "V1Snap", "V2Snap", "AddedPages" -> {_Integer...}, "RemovedPages" -> {...}, "ChangedPages" -> {...}, "UnchangedPages" -> {...}|>

### SourceVaultMarkSnapshotStale[snapshotId, reason] → Association
snapshot meta の LifecycleStatus を "Stale" に更新し、events/source-events.jsonl に VersionedUpdate event 記録。参照する Bundle は自動的に "Stale" を返すようになる。

### SourceVaultMarkSnapshotInvalidated[snapshotId, reason] → Association
LifecycleStatus を "Invalidated" に更新。Retraction 等参照を不可にしたい時。

### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason]
高レベル refresh API。(1) diff 計算 (2) oldSnap を "Stale" + SupersededBy を newSnap に (3) event 記録。
→ <|"Status", "Diff" -> _Association, "Event" -> _Association|>

### SourceVaultBundlesForSnapshot[snapshotId] → List
指定 snapshot を参照する全 bundle id リスト。

### SourceVaultSourceEvents[opts] → List
events/source-events.jsonl の全 event リスト。
Options: "SourceId" -> _String, "SnapshotId" -> _String, "EventType" -> "VersionedUpdate" | "Retraction" | "SourceDeletion" | "SchemaChange"

### SourceVaultSourceEventAppend[event] → Association
event Association を source-events.jsonl に append。event に EventType/SourceId/Reason 必須、OldSnapshotId/NewSnapshotId/Metadata 任意。EventId と Timestamp は自動生成。

## Notebook 管理

### SourceVaultRegisterNotebook[path] → Association
指定 path の notebook を登録。NotebookRef は path-based hash で安定生成。
→ <|"Status", "NotebookRef", "Path", "RegisteredAt"|>

### SourceVaultIndexNotebook[path, opts]
notebook の Header/Todo/Cell を抽出して index 更新。
→ <|"Status", "NotebookRef", "SnapshotId", "Header", "TodoCount", "OpenTodoCount", "ReviewState", "DeadlineState", "Lint" -> {...}|>
Options: "ExtractHeader" -> True, "ExtractTodos" -> True, "ForceReindex" -> False (file mtime 同じなら skip)

### SourceVaultIndexNotebookFolder[dir, opts]
folder 配下の .nb を全て index。
→ <|"Status", "Processed" -> _Integer, "Failed" -> _Integer, "Results" -> {...}|>
Options: "Recursive" -> False, "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}

### SourceVaultExtractNotebookHeader[path] → Association
先頭 Input セルから Header を safe parse (HoldComplete + whitelist で RunProcess/Get/Import 等拒否)。
→ <|"ParseStatus" -> "OK"|"MissingHeader"|"UnsafeExpression", "Keywords", "Deadline", "NextReview", "Status"|>

### SourceVaultExtractNotebookTodos[path] → List
TodoItem スタイルセルを列挙。Status 3 値判定（優先順: TaggingRules > StrikeThrough+FontColor > Default）。StrikeThrough なし→Open、あり+緑→Done、あり+灰→Pass、あり+他→Done。
→ {<|"Text", "Status", "StatusSource", "StrikeThrough" -> _Bool|>, ...}

### SourceVaultFindNotebooks[opts] → List
index 済 notebook を検索。LLM 不要 deterministic query。
→ {<|NotebookRef, OriginalPath, Title, Header, ReviewState, ...|>, ...}
Options:
"OpenTodos" -> True | False
"NextReview" -> "Today" | "Overdue" | "ThisWeek" | "DueSoon" | <|"From" -> _, "To" -> _|>
"Deadline" -> "Today" | "Overdue" | "ThisWeek" | "DueSoon" | <|"From" -> _, "To" -> _|>
"Keywords" -> {_String, ...} | _String (部分一致 OR、対象: Header.Keywords + Title + FileBaseName + 親フォルダ名)
"Title" -> _String | {_String, ...} ("Keywords" エイリアス)
"Status" -> "Todo" | "Done" | _String
"Scope" -> "Today" 複合フィルタ ((NextReview==今日)|(Deadline==今日)|(Path に YYYYMMDD で今日))
"Format" -> False (True なら SourceVaultFormatNotebookList で Grid 化)

### SourceVaultNotebookLint[record] → List
notebook record (または path) に lint チェック。検出: MissingHeader/UnsafeHeaderExpression/HeaderDeadlineMalformed/HeaderNextReviewMalformed/HeaderStatusTodoButNoOpenTodos/HeaderStatusDoneButOpenTodosExist/DeadlinePast/NextReviewPast/TodoCellStatusHeuristicOnly。
→ {"LintName1", ...}

### SourceVaultExtractNotebookTaggingRules[path] → Association
notebook 全体および各 TodoItem cell の TaggingRules を取得。Import[path, "Notebook"] + NotebookImport[path, style->"Cell"] 経由。
→ <|"Status" -> "OK"|"Failed", "Path", "NotebookTaggingRules" -> _Association, "CellTaggingRules" -> {<|"Index" -> _Integer, "CellStyle" -> _String, "TaggingRules" -> _Association|>, ...}|>

### SourceVaultNotebookSemanticHash[path] → Association
notebook の意味的内容のみを対象にハッシュ計算。表示メタデータ (ExpressionUUID/CellChangeTimes/CellLabel/FontFamily 等) とウィンドウ設定を除外、意味的要素 (content/style/TaggingRules/FontVariations/FontColor/Background) だけ。formatting のみ変更で Stale 誤判定を防ぐ。
→ <|"Status" -> "OK"|"Failed", "Path", "SemanticHash" -> _String|>

### SourceVaultRegisterNotebookSummary[path, summary, opts] → Association
notebook の summary artifact を登録。現在の snapshot (SnapshotId + SemanticHash) と紐づけ保存し後日 stale 判定可能。
→ <|"Status" -> "OK"|"Failed", "SummaryId", "NotebookRef", ...|>
Options: "SummaryFormat" -> "text" (| "markdown"), "GeneratedBy" -> "manual"

### SourceVaultGetNotebookSummary[path] → Association
notebook に紐づく summary record。未登録なら "Status" -> "Missing"。
→ <|"Status" -> "OK"|"Missing"|"Failed", "Summary", "SummaryFormat", "BasedOnSnapshot", "BasedOnSemanticHash", "GeneratedBy", "CreatedAt"|>

### SourceVaultNotebookSummaryStatus[path] → Association
summary artifact の lifecycle ステータス判定。Missing (未存在) / Current (BasedOnSnapshot が現 snapshot と一致) / StaleFormattingOnly (SemanticHash 一致、formatting のみ変更) / Stale (SemanticHash 変化)。
→ <|"Status" -> _String, "Reason", "CurrentSnapshot", "SummaryBasedOnSnapshot" -> _String|_Missing|>

### SourceVaultMarkTodo[path, target, newStatus, opts]
notebook 内 Todo cell の Status を変更。NBAccess`NBWriteTodoStatus への薄いラッパー（Cell options: FontVariations StrikeThrough + FontColor、Cell TaggingRules: <|"SourceVault" -> <|"TodoStatus" -> newStatus|>|>）。
target: Integer (1-based Todo Index) / String (TodoId) / Association (<|"Index" -> n, "Text" -> "..."|>)。newStatus: "Open" | "Done" | "Pass"。
→ DryRun: <|"Status" -> "DryRunOK", "Target", "MatchedTodo", "OldStatus", "NewStatus", "CellPath" -> {_Integer...}, "Before" -> HoldComplete[...], "After" -> HoldComplete[...]|>
→ 実行: <|"Status" -> "OK"|"Failed", "Target", "MatchedTodo", "OldStatus", "NewStatus", "ReindexResult" -> _Association | Missing["NotRequested"]|>
Options: "DryRun" -> True (安全側、True は preview のみ), "AutoReindex" -> True (実行成功後 SourceVaultIndexNotebook 自動、実行時のみ), "AccessSpec" -> <|"AccessLevel" -> 0.7, ...|>

### SourceVaultNotebookSummary[path, opts]
notebook 内容を LLM で要約し Summary artifact 保存。内部で SourceVaultRegisterNotebookSummary を呼ぶため lifecycle 管理自動。既定 PrivacyLevel -> 1.0 (ローカル LM 経由、内容を API に送らない)。
→ Current で ForceRefresh 無し: 既存 record。生成成功: Register 同形 Association。Inconsistent: <|"Status" -> "Inconsistent", "Reason", ...|>。失敗: <|"Status" -> "Failed", "Reason", ...|>
Options:
"ForceRefresh" -> False
"MaxLength" -> 500
"Language" -> Automatic (| "Japanese" | "English")
"Model" -> Automatic ({"provider", "model"} 明示可)
"PrivacyLevel" -> 1.0 (0.0 API 許可 〜 1.0 ローカルのみ)
"FallbackToCloud" -> "Ask" (| "Allow" | "Deny")

### SourceVaultUpcomingSchedule[opts] → Dataset
「今日から N 日以内」に Deadline/NextReview がある notebook 一覧。日付 yyyy/mm/dd、期限切れ赤、今日/明日青。
→ Dataset[行={Deadline, NextReview, Title (Open button), Dir (Open button), OpenTodos, Status, Privacy}]
Options:
"Scope" -> dir (default $onWork or $packageDirectory)
"Period" -> Quantity[7, "Days"]
"IncludeOverdue" -> True
"Recursive" -> True
"Refresh" -> "Never" (| "IfStale" | "Force"。Never は保存済 Summary だけ表示、無ければ Keywords を tooltip fallback)
"FallbackToCloud" -> "Ask" (| "Allow" | "Deny")
"StatusFilter" -> {"Todo"} (| {"Todo","Done","Pass"} | All)
"UseCache" -> True

### SourceVaultFormatNotebookList[records, opts] → Grid
notebook record List をスケジュール表と同じ表形式 (Deadline/NextReview/Title (Open button)/Dir (Open button)/OpenTodos/Status/Summary/Publishable) で Grid 表示。FindNotebooks 戻り値、IndexNotebook OK record の List、Path/Header を持つ Association List を受付。
Options: "Refresh" -> "Never" (| "IfStale" | "Force"), "FallbackToCloud" -> "Deny" (| "Ask" | "Allow"), "UseCache" -> True

### SourceVaultRefreshAllSummaries[opts]
Scope 配下全 notebook の概要を一括再生成。
→ <|"Status" -> "OK", "Scope", "TotalFiles", "Refreshed", "Cached", "Inconsistent", "Failed", "Details"|>
Options:
"Scope" -> dir (default $onWork)
"Recursive" -> True
"ForceRefresh" -> False
"FallbackToCloud" -> "Deny" (一括時は Deny 推奨)
"OpenTodosOnly" -> False (True で OpenTodoCount > 0 のみ)
"Model" -> Automatic
"Progress" -> False (True で 10 件毎 Print)
"Limit" -> Infinity

## Context retrieval / ClaudeAttach 互換

### SourceVaultSpan[snapshotOrRef, opts] → Association
SourceSpan association を作る。snapshotOrRef: SnapshotId / SourceRef / file path。
Options: "Pages" -> {1,3,5} | All | _Integer, "Role" -> "ReferenceContext" | "Evidence" | "ExtractionInput", "Purpose" -> "LaTeXMathFormatting" | _String

### SourceVaultContext[sourceSpan, opts]
sourceSpan の plaintext を取り出し NBAuthorize 判定付きで LLM 文脈として返す。"RequireApproval" も block。
Options: MaxCharacters, "Sink", "Purpose"

### SourceVaultContextAssemble[sourceSpans, opts]
複数 span を 1 つの prompt context に組み立てる。
Options: "Purpose" -> _String, MaxCharacters -> _Integer, "Ordering" -> "PageOrder" | "Citation" | "GivenOrder", "Separators" -> "ByPage" | "BySource" | None, "IncludeCitations" -> True | False, "Sink" -> _Association

### SourceVaultAttach[nb, source, opts] → Association
notebook に source を attach、TaggingRules に sourceVaultRefs 記録。旧 ClaudeAttach の代わり。

### SourceVaultAttachToCell[nb, cellIdx, sourceSpan, opts] → Association
cell に SourceSpan を attach。

### SourceVaultGetAttachments[nb] → List
notebook に attach された source 一覧。

### SourceVaultGetCellSources[nb, cellIdx] → List
cell に紐づく SourceSpan リスト（旧形式 refSources を read-only normalize）。

### SourceVaultEnsureRegistered[ref] → Association
旧 refSources 形式 (or file path) を SourceSpan 形式に normalize、必要に応じ ingest。

## Materialization

### SourceVaultMaterializeForSink[sourceRef, sinkSpec, opts]
source を cloud-accessible mirror へ materialize。内部で必ず NBAuthorize を呼ぶ。

### SourceVaultResolvePath[ref, opts] → String
source/snapshot の物理 path。"Tier" -> "PrivateVault" は local kernel/maintenance 専用。cloud LLM 向けは SourceVaultMaterializeForSink を使う。

### SourceVaultObjectSpec[ref, opts] → Association
source/snapshot を NBAuthorize が受け取れる object spec association に変換。

## Ingest オプションシンボル

### Topic / PinVersion / TrustLevel / PrivacyLabel
SourceVaultIngest オプションシンボル。

### MaxCharacters
SourceVaultContext / SourceVaultContextAssemble オプションシンボル。

## ClaudeAttach 統合

### SourceVaultClaudeAttachIntegrationEnable[] → Association
ClaudeAttach 呼出時に SourceVault への side-channel ingest を行う hook を有効化。有効済なら noop。元 DownValue 保持、Disable で復元可。前提: claudecode.wl の ClaudeCode`ClaudeAttach ロード済。

### SourceVaultClaudeAttachIntegrationDisable[] → Association
hook を外し ClaudeAttach を元 DownValue に復元。

### SourceVaultClaudeAttachIntegrationStatus[] → Association
現在の hook 状態。Keys: Enabled, OriginalSaved, OriginalDVCount, HookTarget。

### SourceVaultGetClaudeAttachRefs[nb] → List
notebook nb に紐づく ClaudeAttach side-channel ingest 記録の flat list。各 entry: OriginalPathOrURL/ExpandedPath/SnapshotId/SourceId/ContentHash/IngestStatus/AttachedAt。引数なしは EvaluationNotebook[]。

## ClaudeAttachments 統合

### SourceVaultClaudeAttachmentsIntegrationEnable[] → Association
ClaudeAttachments[] 戻り値を List of paths から Association list に拡張する hook を有効化。SnapshotId/SourceId/ContentHash/IngestStatus を join。前提: ClaudeCode`ClaudeAttachments ロード済。

### SourceVaultClaudeAttachmentsIntegrationDisable[] → Association
hook を外し復元。

### SourceVaultClaudeAttachmentsIntegrationStatus[] → Association
現在の hook 状態。

## WorkerPrompt 統合

### SourceVaultWorkerPromptIntegrationEnable[] → Association
ClaudeOrchestrator の A5 hook に SourceVault context 注入関数を登録、worker prompt 構築時に吹出。前提: ClaudeOrchestrator.wl に A5 hook 5 行追加済。トリガー: task["SourceSpans"] (明示) + ClaudeAttach 履歴 (自動検出)。

### SourceVaultWorkerPromptIntegrationDisable[] → Association
A5 hook 定義をクリア。

### SourceVaultWorkerPromptIntegrationStatus[] → Association
現在の A5 hook 状態。

### $SourceVaultWorkerPromptAutoDetect
型: Boolean, 初期値: True
A5 hook 有効時の自動検出 ON/OFF。True: ClaudeAttach 履歴から SnapshotId 自動検出注入。False: task["SourceSpans"] 明示のみ。

## ParseProposal 統合

### SourceVaultParseProposalIntegrationEnable[] → Association
ClaudeOrchestrator の A6 hook に parseProposal post-processing 関数を登録。LLM 応答内 <source>snap-...</source> / <source>src-...</source> XML タグを抽出し parseProposal 戻り値に "SourceVaultRefs" キー追加。前提: ClaudeOrchestrator.wl に iApplyA6Hook + A6 hook 呈入済。

### SourceVaultParseProposalIntegrationDisable[] → Association
A6 hook 定義をクリア、iApplyA6Hook は no-op に。

### SourceVaultParseProposalIntegrationStatus[] → Association
現在の A6 hook 状態。

## Snapshot privacy / Sync

### SourceVaultSetSnapshotPrivacyLevel[snapshotId, level] → Association
snapshot record の PrivacyLevel を明示的に上書き。NBAccess`NBSetSnapshotPrivacyLevel の委譲先。Notebook snapshot と PDF/URL snapshot 両系統をファイル存在で判別。level は 0.0-1.0 に clip。既存値より低い値指定時は "Lowered" -> True。
→ <|"Status", "SnapshotId", "OldPrivacyLevel", "NewPrivacyLevel", "Lowered", "SnapshotKind"|>

### SourceVaultSelectSources[opts] → Association
同期対象 source を選定。Scope 配下の .nb をスキャンし source descriptor 化。
→ <|"Status", "Scope", "Count", "Sources" -> {_Association..}|>
Options: Scope / Recursive / Kind / ExcludePatterns

### SourceVaultSyncPlan[opts] → Association
各 source の鮮度を判定し同期計画を返す (dry-run、副作用なし)。鮮度トークン (ローカルは mtime) を現 snapshot 記録と比較し Fresh/Stale/Missing/NeverIndexed に分類。
→ <|"Status", "Total", "StaleCount", "Plan" -> _Dataset, ...|>
Options: Scope / Recursive / Kind / ExcludePatterns

### SourceVaultSync[opts] → Association
SyncPlan に従い Stale な source を再 index (クローラー骨格)。PrivacyLevel は単調 (自動で下げない)。再 index で下がったら SetSnapshotPrivacyLevel で旧値に引き上げ警告記録。sync/sync-history.jsonl 記録、sync/last-sync.json 更新。
→ <|"Status", "SyncId", "Refreshed", "Skipped", "Failed", "PrivacyWarnings"|>
Options: Scope / Recursive / Kind / DryRun / ForceAll / RefreshSummary / FallbackToCloud (既定 "Deny")

### SourceVaultSyncStatus[] → Association
直近 sync 実行の状態 (sync/last-sync.json)。未実行なら <|"Status" -> "NoSyncYet"|>。

### SourceVaultRelinkSources[opts] → Association
OriginalPath が存在しなくなった (移動された) notebook source を検出、Scope 配下から移動先を探し再リンク。照合順: (1) 埋込 UUID (TaggingRules SourceVault>NotebookUUID) (2) 内容ハッシュ (RawContentHash 完全一致) (3) ファイル名一意一致。移動判定はシンボリックパス解決ベース。
→ <|"Status", "Linked", "Relinked" -> {..}, "RelinkedCount", "ByMethod" -> <|"UUID"/"ContentHash"/"NameOnly" -> _|>, "Unresolved" -> {..}, "DryRun"|>
Options: Scope / Recursive / DryRun (既定 True) / ApplyNameOnly (既定 False) / DeleteStale (既定 False) / ExcludePatterns

## Model endpoints / registry 管理

### $SourceVaultModelEndpoints
型: Association
provider 名からモデル一覧エンドポイント設定への Association。ユーザ上書き可。各値: <|"ModelsURL" -> _, "Kind" -> "Cloud"|"Local", "AuthProvider" -> _|>。

### SourceVaultModelEndpointStatus[] → Association
各 provider エンドポイントの到達性 (オフライン検知)。短タイムアウトで probe、401/403 でもサーバ到達 = Online とみなす。
→ <|"Status", "Endpoints" -> <|provider -> <|"Status" -> "Online"|"Offline", ...|>|>|>

### SourceVaultDetectLocalModels[opts] → Association
ローカル LLM サーバ (LM Studio 等、OpenAI 互換 /v1/models) からモデル一覧を推測。API キー不要。
→ <|"Status" -> "OK"|"Offline", "Provider", "Endpoint", "Models" -> {_String..}|>
Options: Provider (既定 "lmstudio") / Endpoint (既定は ClaudeCode`$ClaudePrivateModel の url 優先、無ければ $SourceVaultModelEndpoints の設定)。キー保護有効時は NBAccess`NBGetLocalLLMAPIKey 経由自動解決 (事前 NBStoreLocalLLMAPIKey 登録)。

### SourceVaultSetModel[provider, intent, modelId, opts] → Association
compiled model registry に手動で 1 エントリ書込 (API キー不要)。Source -> "manual" で保存、同 (provider, intent) の既存エントリを置換。
Options: Channel (既定 public) / Class (既定 Automatic=推論) / Capabilities (既定 Automatic) / Integrations / ContextLength
例: SourceVaultSetModel["anthropic", "heavy", "claude-opus-4-8"]

### SourceVaultClearModelRegistry[opts] → Association
compiled model registry を削除、次回アクセス時に seed (コード内最新 iModelSeedEntries) から再構築。古い seed コピーが残り ClaudeResolveModel が古い ID を返す時の復旧用。seed 自体は消さない。
Options: Channel (既定 public)

### SourceVaultSetModelIntent[variable, spec] → Association
SourceVault が選択するモデルの intent 割当を変更。variable: "$ClaudeModel" | "$ClaudeDocModel" | "$ClaudePrivateModel" | "$ClaudeFallbackModels"。spec: {provider, intent} (FallbackModels は {{provider,intent}, ...})。設定後 SourceVaultAssignClaudeModels[] を呼び実変数に反映。$NBApprovalHeads 登録済 (ClaudeEval 経由では Hold->Approve 必要)。
例: SourceVaultSetModelIntent["$ClaudeModel", {"anthropic", "heavy"}]

### SourceVaultModelIntentMap[] → Association
変数名 -> intent spec のマッピングを返す読み取り公開関数。NBAccess`NBSyncClaudeModelVars が読む。
例: <|"$ClaudeModel" -> {"claudecode","code-heavy"}, ...|>

### SourceVaultAssignClaudeModels[opts] → Association
intent マッピング (SourceVault) と信頼ローカルサーバ (NBAccess`NBResolveLocalServer) から $ClaudeModel/$ClaudeDocModel/$ClaudePrivateModel/$ClaudeFallbackModels を設定。SourceVault ロード時自動実行。
Options: Verbose (既定 False)

### SourceVaultRefreshModelRegistry[opts] → Association
クラウド (anthropic/openai) とローカル (LM Studio) エンドポイントからモデル一覧取得し compiled model registry 更新。クラウド API キーは NBAccess`NBGetAPIKey 経由、キー無 provider はスキップ。取得エントリは Source -> "auto-fetch"、既存 seed/manual は温存マージ。
→ <|"Status", "FetchedCount", "RegistryTotal", "PerProvider", "RegistryPath"|>
Options: Providers (既定 All) / IncludeCloud (既定 Automatic) / DryRun (既定 False)

## Notebook UUID

### SourceVaultNotebookUUID[path] → String | Missing[]
notebook に埋込まれた UUID (TaggingRules > SourceVault > NotebookUUID)。読み取りのみ。

### SourceVaultEnsureNotebookUUID[path, opts] → Association
notebook に UUID が無ければ生成して埋込む。UUID は TaggingRules に保存、ファイル名変更・内容編集をまたいで安定 (Relink の最も信頼できる照合キー)。
→ <|"Status", "Path", "UUID", "Created" -> True|False|>
Options: Force (既定 False、True で既存 UUID も再生成)

### SourceVaultEnsureNotebookUUIDFolder[dir, opts] → Association
folder 配下の .nb 全てに UUID 付与。
→ <|"Status", "TotalFiles", "Created", "AlreadyPresent", "Skipped", "Failed"|>
Options: Recursive (既定 True) / ExcludePatterns / MaxFileSizeMB (既定 $SourceVaultMaxFileSizeMB)

## DirectiveRepository（Claude Directives リポジトリ source）

依存: ClaudeDirectives`（lazy Needs のみ、BeginPackage には追加しない）。

### SourceVaultRegisterDirectiveRepository[root] → Association
Claude Directives リポジトリ (ディレクトリ) を DirectiveRepository source として登録。RepoId は root path から決定的に導出。
→ <|"Status", "RepoId", "Root", "Path", "Registration"|>

### SourceVaultIndexDirectiveRepository[root] → Association
リポジトリを index: ClaudeDirectives` でファイルインベントリと manifest hash を計算し DirectiveRepository snapshot record を書込。未登録なら自動登録。
→ <|"Status", "RepoId", "SnapshotId", "ManifestHash", "FileCount", "Path", "Snapshot"|>

### SourceVaultDirectiveRepositoryStatus[root] → Association
登録有無、snapshot 数、最新 snapshot の manifest hash が disk と一致するかを報告。Status: "NotRegistered" | "RegisteredNotIndexed" | "UpToDate" | "Stale"。

### SourceVaultCurrentDirectiveSnapshot[root] → Association
リポジトリの最新 DirectiveRepository snapshot record。無ければ Status -> "NoSnapshot"。

### SourceVaultDiffDirectiveSnapshots[old, new] → Association
2 つの DirectiveRepository snapshot record (or ファイルパス) を RelativePath/ContentHash で比較。
→ <|"Status", "Added", "Removed", "Changed", "UnchangedCount", "ManifestHashChanged"|>

## HarnessMaterialization（materialized harness bundle）

### SourceVaultRegisterHarnessMaterialization[target, files, meta] → Association
materialized harness を HarnessMaterialization bundle として登録。target: "Codex" | "ClaudeCLI"。files: 生成ファイルパスリスト。meta: HarnessMode, DirectiveRoot, DirectiveRepositorySnapshotId, DirectiveRepositoryManifestHash, RuntimeEnvironmentHash, PermissionProfileHash, Generator。bundle は SourceVault bundles ディレクトリ下に保存、SourceVaultBundleGet で読める。
→ <|"Status", "BundleId", "Path", "Bundle"|>

### SourceVaultDirectiveSnapshotStaleQ[bundle] → Association
HarnessMaterialization bundle のビルド元 canonical Claude Directives snapshot が stale か判定。bundle の DirectiveRepositoryManifestHash と現リポジトリ hash を比較。stale = harness 再生成すべき。
→ <|"Stale", "Reason", "RecordedManifestHash", "CurrentManifestHash"|>

### SourceVaultHarnessRuntimeEnvironmentChangedQ[bundle, currentEnv] → Association
bundle の runtime environment (permission profile, temp project path, attachments) が変化したか判定。currentEnv は precomputed PermissionProfileHash/RuntimeEnvironmentHash、または raw PermissionProfile/RuntimeEnvironment associations。runtime 変化は config.toml 再生成を要するが canonical snapshot を stale にはしない。