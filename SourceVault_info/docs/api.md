# SourceVault API リファレンス

`BeginPackage["SourceVault`", {"NBAccess`"}]` で定義。
依存: [NBAccess](https://github.com/transreal/NBAccess)、[claudecode](https://github.com/transreal/claudecode) (非同期 ingest・OCR・LLM 要約時に必要)

## Bootstrap / 設定

### $SourceVaultVersion
型: String
パッケージのバージョン文字列。
### $SourceVaultRoots
型: Association
物理 root ディレクトリマッピング。Keys: "PrivateVault" | "CloudMirror" | "Tmp" | "AttachmentMirror" | "ExternalOwned"。PrivateVault が authoritative storage (Dropbox 配下)。CloudMirror / AttachmentMirror は materialize 済み projection のみ置く。cloud LLM / Claude Code CLI に直接読ませない。
### $SourceVaultSeedModelRegistry
型: Association
bootstrap 時の fallback model registry。production truth ではなく compiled registry がない場合の災害復旧用 fallback のみで使われる。LLM が自動更新しない。更新は review 必須。
### $SourceVaultMaxFileSizeMB
型: Real
EnsureUUID スキップの閾値 (MB)。SourceVaultIngest がこのサイズを超えるファイルの UUID 付与をスキップする。
### SourceVaultInitialize[opts]
SourceVault の物理 root を生成して初期化する。作成済みなら noop。PrivateVault と Tmp は必須。
→ Association
Options: "Roots" -> $SourceVaultRoots (override), "Force" -> False (再初期化)
### SourceVaultStatus[sourceRef] → Association
指定 source / snapshot / ファイルの概要を返す。引数なしで vault 全体の概要。
### SourceVaultList[] → List
vault 内の全 source ID リスト。
### SourceVaultSnapshots[sourceRef] → List
指定 source に限定した snapshot ID リスト。

## ソース一覧 / 横断検索

### SourceVaultSources[query, opts]
ingest 済み全ソースをメタデータ付きの表で表示する。arXiv は論文タイトル・著者・出版日 (arXiv API から自動取得しメタキャッシュ)、Web ページは HTML `<title>`、ローカルファイルはファイル名を Title に出す。各行に URL リンクと ingest 済みファイルを開くリンクが付く。query は Title/Authors/URL/Id の部分一致 ("" または省略で全件)。
→ Grid | Dataset | List
Options: "Limit" -> Automatic, "Kind" -> All | "arxiv" | "web" | "local", "FetchMetadata" -> Automatic (未取得のみ取得) | False | True (再取得), "Format" -> "Grid" | "Dataset" | "Rows"
### SourceVaultSourceRow[sourceId] → Association
1 ソースの共通スキーマ行。キー: "Kind", "Id", "Title", "Authors", "Published", "Summary", "URL", "File", "Date", "PrivacyLevel"。SourceVaultSummaries 登録 provider の fn が返す行と同じキー構造。
### SourceVaultSummaries[query, opts]
ingest 済みソース + Eagle 保存済みサマリー等、登録 provider 横断で検索し統合表で表示する。
→ Grid | Dataset | List
Options: "Providers" -> All | {"sources", "eagle", ...}, "Limit" -> Automatic, "Kind" -> All | "arxiv" | "web" | "local", "FetchMetadata" -> Automatic | False | True, "Format" -> "Grid" | "Dataset" | "Rows"
例: `SourceVaultSummaries["可逆計算"]`
### SourceVaultRegisterSummaryProvider[name, fn] → Null
SourceVaultSummaries の横断検索 provider を登録する。fn のシグネチャ: `fn[query_String, opts_Association]` → SourceVaultSourceRow と同じキーの Association リスト。
### $SourceVaultSummaryProviders
型: Association
SourceVaultSummaries が横断する provider の Association (name -> fn)。

## Stage 1 / Stage 6b: Lookup / Resolve / Compiled Registry

### SourceVaultLookup[topic, key, opts]
compiled registry から key に対応する entry を返す。compiled registry に見つからなければ seed に fallback。network なし、LLM なし。
→ Association | Missing["NotFound"]
Options: "Channel" -> "public" | "private" (既定 "public"), "AllowSeed" -> True (compiled なし時 seed を使う)
### SourceVaultResolve[kind, query, opts]
compiled registry から query に match する entry を返す。複数 match 時は Availability != "Unavailable" をフィルタし Class/Freshness で sort して先頭を返す。network なし、LLM なし。
→ Association | Missing["NotFound"]
Options: "Channel" -> "public" | "private", "AllowSeed" -> True, "Topic" -> "<kind>-registry" を小文字化 (既定)
例: `SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]`
### ClaudeResolveModel[provider, intent] → Association | Missing["NotFound"]
SourceVaultResolve["Model", ...] の互換 wrapper。旧 WikiDBResolveModel の置き換えとして利用できる。
例: `ClaudeResolveModel["anthropic", "heavy"]`
### SourceVaultListModels[provider] → List
指定 provider に登録された選択可能な全モデル ID リストを返す。SourceVaultResolve が intent 単位の最適 1 件を返すのに対し catalog を列挙する (例: パレットのモデル選択)。compiled registry を優先し、なければ seed に fallback。Availability が Unavailable のエントリは除外。
### SourceVaultModelContextLength[provider, modelId] → Integer | None
モデルに紐づく ContextLength を返す。SourceVaultSetModel[..., "ContextLength" -> n] で永続化された値。LM Studio 等ローカル LLM の context_length に使う。未設定なら None。
### SourceVaultModelIntegrations[provider, modelId] → List | None
モデルに紐づく LM Studio MCP の integrations リストを返す。SourceVaultSetModel[..., "Integrations" -> {...}] で永続化された値。LM Studio /api/v1/chat の integrations パラメータに使う。MCP ID ("mcp/exa" 等) をコードにハードコードせず SourceVault ストアに永続化するための機構。未設定なら None。
例: `SourceVaultSetModel["lmstudio", "local-heavy", "qwen/qwen3-coder-30b", "Integrations" -> {"mcp/exa"}, "ContextLength" -> 32000]`
### SourceVaultSetModel[provider, intent, modelId, opts]
指定 provider + intent のモデルを compiled registry に設定する。SourceVaultModelContextLength や SourceVaultModelIntegrations で取得できる値を永続化する。
→ Association
### SourceVaultListRegistries[opts] → Association
登録済み registry topic と channel を返す。
Options: "Channel" -> "public" | "private" | All (既定 All)
### SourceVaultRegistryStatus[topic, opts]
指定 topic の registry 状態を返す。
→ Association: <|"Topic" -> _, "Channel" -> _, "CompiledPath" -> _, "CompiledExists" -> Bool, "CompiledCount" -> Integer, "SeedPath" -> _, "SeedExists" -> Bool, "SeedCount" -> Integer, "LastModified" -> String|>
Options: "Channel" -> "public" | "private"
### SourceVaultCompileRegistry[topic, entries, opts]
entries (List of Association) を compiled registry に保存する。entries 形式例: {<|"Provider" -> _, "Intent" -> _, "ModelId" -> _|>, ...}。
→ Association: <|"Status" -> _, "Topic" -> _, "Channel" -> _, "Path" -> _, "Count" -> Integer|>
Options: "Channel" -> "public" | "private" (既定 "public"), "Sources" -> {String, ...} (関連 claim/snapshot id), "PolicySource" -> String
### SourceVaultRegisterSeed[topic, entries] → Association
seed entries を seeds/<topic>-seed.json に保存する (bootstrap 用)。seed は production truth ではなく compiled registry がない場合の fallback のみで使われる。

## Stage 1.5 / 2: Ingest

### SourceVaultIngest[source, opts]
外部 source を登録し raw snapshot を PrivateVault に保存する。ローカルファイルパス、HTTPS/HTTP URL、arXiv:NNNN.NNNNN[vN] 形式に対応 (arXiv は arxiv.org/pdf/... に canonicalize して URL ingest)。
→ Association
Options: Topic -> Automatic | String, TrustLevel -> Automatic | "OfficialAPI" | "OfficialDocs" | "PublicWeb" | "LocalFile", PrivacyLabel -> Automatic | Real, PinVersion -> True | False | Automatic, Asynchronous -> False | True (True 時は LLMGraphDAGCreate 経由でジョブキューに投入し JobId を即時 return、claudecode.wl 必須), EnsureUUID -> Automatic | True | False (.nb 取り込み時の UUID 自動付与。Automatic/True: .nb なら hash 計算前に SourceVaultEnsureNotebookUUID を呼びファイルに UUID を埋め込む。.nb 以外と巨大ファイル (>$SourceVaultMaxFileSizeMB) はスキップ。付与失敗でも ingest は続行)
### SourceVaultIngestWait[ingestResult, timeoutSec]
非同期 ingest の完了を待つ。ingestResult が sync 完了済み (Status: Ingested/AlreadyCurrent/RebuiltMetadata) なら即座に return。Status: Queued の場合は SourceId の snapshot 増加を polling し新規 snapshot 出現で完了。timeoutSec 秒 (既定 60) 超過で Status: Timeout を返す。第一引数は SourceVaultIngest の結果 Association または SourceId String。
→ Association
### SourceVaultEnsureNotebookUUID[path] → Association
.nb ファイルに UUID が未設定の場合に UUID を埋め込む。SourceVaultIngest が EnsureUUID -> True 時に内部で呼ぶ。

## Stage 4 Phase 4B: PDF ページ抽出

### SourceVaultExtractPages[snapshot, pages, opts]
snapshot の指定 page を抽出して cache に保存する。snapshot は SnapshotId または SourceId (latest snapshot を使用)。pages は Integer / List of Integer / All。各 page を parsed/by-snap/<id>/pages/NNNN.txt に cache し page-hashes.json に SHA-256 hash を保存する。cache hit 時は Import しない。抽出結果が空または 5 文字未満の時は $SourceVaultOCRHook (設定されていれば) を呼ぶ。
→ Association: <|"Status", "SnapshotId", "Pages" -> {n -> text, ...}, "Hashes" -> <|...|>, "CachedFrom" -> "Disk" | "Fresh" | "Mixed", "OCRCalled" -> True | False|>
Options: Force -> False | True (cache 無視して再抽出), "ForceOCR" -> False | True (この呼び出しだけ OCR を強制実行しスキャン判定をスキップ。ForceOCR -> True 時は Force -> True も自動適用。永続的に強制モードにしたい場合は SourceVaultOCREnable[..., "Mode" -> "Force"] を使う。hook が設定されている必要あり)
### $SourceVaultOCRHook
型: None | Function, 初期値: None
スキャン PDF の fallback OCR 関数。シグネチャ: `Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String`。SourceVaultExtractPages がページテキスト抽出失敗時 (空または 5 文字未満) に呼ばれ、返値文字列が text として cache される。SourceVaultOCREnable[...] 経由で設定するのが推奨。
### $SourceVaultOCRMode
型: String, 初期値: "Auto"
OCR 発火モードを制御する変数。"Auto": Plaintext 抽出結果が 5 文字未満の時のみ OCR を呼ぶ。"Force": Plaintext の長さに関わらず常に OCR を呼ぶ (低品質テキスト層を持つ PDF 群に対してスキャン判定をスキップして全ページを再 OCR したい時に使う)。SourceVaultOCREnable[..., "Mode" -> "Force"] で永続化、SourceVaultOCRDisable[] で "Auto" にリセット。単発の強制 OCR には SourceVaultExtractPages の "ForceOCR" -> True を使う。
### $SourceVaultOCRVerbose
型: Boolean, 初期値: False
OCR 実行時の進捗 Print を制御する変数。True: rasterization / API 呼出 / レスポンス長等の進捗を Print する。OCR が無音で失敗している時のデバッグ用。SourceVaultOCREnable[..., "Verbose" -> True] で有効化可能。

## Stage 4 Phase 4C: OCR バックエンド

### SourceVaultOCREnable[backend, opts]
OCR hook を有効化する。backend 既定は "ClaudeVision"。
→ Association: <|"Status" -> "Enabled", "Backend" -> String, "Mode" -> String, "Options" -> Association|>
Options (backend 共通): "Mode" -> "Auto" | "Force"
"ClaudeVision" Options: "DPI" -> 300, "SplitHalves" -> True (大きい page を上下分割して 2 回 OCR マージ、30px overlap), "Timeout" -> 180, "Prompt" -> Automatic (ClaudeCode`ClaudeQueryBg 経由で Claude API に page 画像を送る)
"TextRecognize" Options: "DPI" -> 150, "Language" -> "Japanese" (Mathematica 組み込み TextRecognize、Python 不要)
"Custom" Options: "Hook" -> Function[req, text] (ユーザ提供 Function をそのまま $SourceVaultOCRHook に設定)
例: `SourceVaultOCREnable["ClaudeVision", "Mode" -> "Force"]`
### SourceVaultOCRDisable[] → Null
OCR hook を無効化する ($SourceVaultOCRHook = None、$SourceVaultOCRMode = "Auto")。
### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定を返す。Backend: "Disabled" | "ClaudeVision" | "TextRecognize" | "Custom"、HookSet: True なら $SourceVaultOCRHook に Function が設定済み。

## Stage 5: Claim 抽出

### SourceVaultSpan[...] → Association
SourceVaultExtract に渡す sourceSpan を生成する。(usage 宣言は提供ソース内に未確認)
### SourceVaultExtract[sourceSpan, schema, opts]
sourceSpan の page text を LLM に渡して claim を抽出する。sourceSpan は SourceVaultSpan[...] の結果または SnapshotId/SourceId String。schema は文字列 (登録済み schema 名) または Association (インライン定義)。AuthorizationCheck -> True 時は sendDecision → context 取得 + LLM 抽出 → persistDecision の 3 ステップで実行 (Stage 6d: 2 段階 NBAuthorize)。
→ Association: <|"Claims" -> {claim, ...}, "Count" -> Integer (実納数), "ExtractedCount" -> Integer (LLM 生抽出数), "DedupSkipped" -> Integer, "AccessDecisions" -> <|"Send" -> _, "Persist" -> _|>, "ValidationStatus" -> _, "SchemaName" -> _, "ExtractedAt" -> DateObject, "Errors" -> {...}|>
Decision が Deny: <|"Status" -> "DeniedByNBAccess", "Reason" -> _, "AccessDecisions" -> _|>
Decision が RequireApproval: <|"Status" -> "RequiresApproval", "Reason" -> _, "AccessDecisions" -> _|>
Options: "Topic" -> String (claim の topic、既定は schema 名), "ModelIntent" -> "summary" | "extraction" | "math-extraction-heavy", "StoreClaims" -> True (ClaimStore に保存), "Dedup" -> True (by-source ファイル単位で ContentHash 照合), "AuthorizationCheck" -> True (2 段階 NBAuthorize), "Validation" -> "None" | "Required", MaxCharacters -> 8000 (LLM に渡す context の最大文字数), Timeout -> 180
### SourceVaultRegisterSchema[name, definition] → Null
抽出 schema をグローバルに登録する。definition は Association: "Description" -> String (LLM 向け説明), "Fields" -> {<|"Name" -> _, "Type" -> _, "Required" -> _, "Description" -> _|>, ...}, "OutputShape" -> "List" | "Single", "PromptTemplate" -> Automatic | String。ビルトイン schema: "FreeText" (自由抽出)、"NumericFacts" (数値・単位・定義・文脈)、"DefinitionList" (用語・定義)。
### SourceVaultClaim[claimId] → Association | Missing["NotFound"]
指定した claim の Association を返す。
### SourceVaultClaimsForSource[sourceIdOrSnapshotId] → List
指定 source に紐づく claim リストを返す。
### SourceVaultClaimsForTopic[topic] → List
指定 topic に紐づく claim リストを返す。
### SourceVaultListSchemas[] → List
現在登録済みの schema 名リストを返す。
### SourceVaultGetSchema[name] → Association
登録済み schema 定義 (Association) を返す。
### SourceVaultClaimStoreStatus[] → Association
ClaimStore の状態を返す (debug 用)。キー: ClaimsDir / MasterPath / MasterExists / MasterClaims (行数) / TopicFiles / SourceFiles。
### SourceVaultClaimStoreCompact[opts]
master + by-topic + by-source を全読みし ContentHash キーで dedup して全インデックスを rebuild する。atomic rewrite (tmp ファイル → rename)。dedup 記録は master の先頭行を残す (最古の結果を保存)。
→ Association: <|"Status" -> "OK" | "Failed", "BeforeCount" -> Integer, "AfterCount" -> Integer, "Removed" -> Integer, "BackupPaths" -> {...}, "DryRun" -> _|>
Options: "Backup" -> True (.bak.<timestamp> サフィックスでバックアップ), "DryRun" -> False (True 時は統計のみ返し書き込まない)

## Stage 6c: Evidence Bundle

### SourceVaultBundleCreate[name, deps, opts]
generated artifact の依存を evidence bundle として保存する。name は文字列 (BundleId は自動生成)。deps は Association: "GeneratedFiles" -> {path, ...}, "Sources" -> {<|"SourceId" -> _, "SnapshotId" -> _|>, ...}, "SourceSpans" -> {...} (任意), "Claims" -> {claimId, ...}, "Generator" -> <|"Tool" -> _, "WorkflowId" -> _, "ModelIntent" -> _, "ResolvedModel" -> _|>。
→ Association: <|"Status" -> "OK" | "Failed", "BundleId" -> String, "Path" -> String|>
Options: "Kind" -> "SimulationExample" | "LaTeXExport" | "DocumentGeneration" | "CodeGeneration" | "Notebook" | String
### SourceVaultBundleGet[bundleId] → Association | Missing["NotFound"]
指定 bundle を読み込み返す。
### SourceVaultBundleList[] → List
全 bundle id リストを返す。
### SourceVaultBundleStatus[bundleId]
bundle の現在の Status を計算して返す。参照する snapshot の LifecycleStatus を集約する。手動 Invalidate 済みなら強制的に "Invalidated" を返す。
→ Association: <|"Status" -> "Current" | "Stale" | "NeedsReview" | "Invalidated", "Reason" -> _, "AffectedSnapshots" -> {...}, "AffectedClaims" -> {...}|>
### SourceVaultBundleInvalidate[bundleId, reason] → Association
bundle を手動で invalidate する。reason は文字列で記録され後に SourceVaultBundleStatus で返される。
### SourceVaultBundleDelete[bundleId] → Null
bundle ファイルを削除する (debug 用)。

## Stage 8: vN diff + snapshot lifecycle

### SourceVaultDiffVersions[v1Snap, v2Snap]
二つの snapshot の page hash 集合を比較し差分を返す。各 snapshot の page-hashes.json (Stage 4B) を読み込みページ番号ごとに hash を比較する。
→ Association: <|"Status" -> _, "V1Snap" -> _, "V2Snap" -> _, "AddedPages" -> {Integer, ...}, "RemovedPages" -> {Integer, ...}, "ChangedPages" -> {Integer, ...}, "UnchangedPages" -> {Integer, ...}|>
### SourceVaultMarkSnapshotStale[snapshotId, reason] → Association
snapshot meta の LifecycleStatus を "Stale" に更新し events/source-events.jsonl に VersionedUpdate event を記録する。この snapshot を参照する Bundle は SourceVaultBundleStatus で自動的に "Stale" を返すようになる。
### SourceVaultMarkSnapshotInvalidated[snapshotId, reason] → Association
snapshot meta の LifecycleStatus を "Invalidated" に更新する。Retraction 等、参照を不可にしたい場合に使う。Bundle は "Invalidated" を返すようになる。
### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason]
高レベル refresh API。1. oldSnap と newSnap の diff を計算、2. oldSnap の LifecycleStatus を "Stale" に更新 + SupersededBy を newSnap に設定、3. event を source-events.jsonl に記録 (EventType: VersionedUpdate)。
→ Association: <|"Status" -> _, "Diff" -> Association, "Event" -> Association|>
### SourceVaultBundlesForSnapshot[snapshotId] → List
指定の snapshot を参照する全 bundle id リストを返す。全 bundle ファイルを読み Sources[].SnapshotId が一致するものを収集する。
### SourceVaultSourceEvents[opts] → List
events/source-events.jsonl の全 event リストを返す。
Options: "SourceId" -> String (指定 source に関連する event のみ), "SnapshotId" -> String (指定 snapshot に関連する event のみ), "EventType" -> String (VersionedUpdate | Retraction | SourceDeletion | SchemaChange)
### SourceVaultSourceEventAppend[event] → Association
event Association を events/source-events.jsonl に append する。event には EventType / SourceId / Reason が必須。OldSnapshotId / NewSnapshotId / Metadata は任意。EventId と Timestamp は自動生成される。

## Stage 9: Notebook 管理 (P0)

### SourceVaultRegisterNotebook[path]
指定 path の notebook を SourceVault に登録する。NotebookRef は path-based hash で安定生成される。
→ Association: <|"Status" -> _, "NotebookRef" -> _, "Path" -> _, "RegisteredAt" -> _|>
### SourceVaultIndexNotebook[path, opts]
notebook の Header / Todo / Cell を抽出して index を更新する。
→ Association: <|"Status" -> _, "NotebookRef" -> _, "SnapshotId" -> _, "Header" -> _, "TodoCount" -> _, "OpenTodoCount" -> _, "ReviewState" -> _, "DeadlineState" -> _, "Lint" -> {...}|>
Options: "ExtractHeader" -> True, "ExtractTodos" -> True, "ForceReindex" -> False (file mtime が同じなら skip)
### SourceVaultIndexNotebookFolder[dir, opts]
指定 folder 配下の .nb を全て index する。
→ Association: <|"Status" -> _, "Processed" -> Integer, "Failed" -> Integer, "Results" -> {...}|>
Options: "Recursive" -> False, "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}
### SourceVaultExtractNotebookHeader[path]
notebook の先頭 Input セルから Header Association を safe parse する。HoldComplete + whitelist で RunProcess / Get / Import 等の危険式を拒否する。
→ Association: <|"ParseStatus" -> "OK" | "MissingHeader" | "UnsafeExpression", "Keywords" -> _, "Deadline" -> _, "NextReview" -> _, "Status" -> _|>
### SourceVaultExtractNotebookTodos[path] → List
notebook 内の TodoItem スタイルセルを列挙する。Status は Open / Done / Pass の 3 値。判定優先順位: TaggingRules > FontVariations StrikeThrough + FontColor > Default。StrikeThrough なし → Open、StrikeThrough あり + FontColor 緑 (RGB g > r, g > b) → Done、StrikeThrough あり + FontColor 灰 (GrayLevel / RGB r≈g≈b) → Pass、StrikeThrough あり + その他 → Done (後方互換)。返値: `{<|"Text" -> _, "Status" -> _, "StatusSource" -> _, "StrikeThrough" -> Bool|>, ...}`
### SourceVaultFindNotebooks[opts]
index 済み notebook を検索する。LLM 不要の deterministic query。返値の各 record は "Path" / "OriginalPath" (同値エイリアス), "Title" (Header.Title または FileBaseName), "NotebookRef", "Header" (Keywords/Deadline/NextReview/Status/Title), "Todos" ({<|"Text", "Status" (Open|Done|Pass), ...|>, ...}), "TodoCount" / "OpenTodoCount" / "DoneTodoCount" / "PassTodoCount", "ReviewState" / "DeadlineState", "Lint" を持つ Association。todo 項目自体を列挙したい場合は record["Todos"] を使う (SourceVaultExtractNotebookTodos[record["Path"]] でも取れるが再抽出となるため record["Todos"] 推奨)。
→ {Association, ...}
Options: "OpenTodos" -> True | False, "NextReview" -> "Today" | "Overdue" | "ThisWeek" | "DueSoon" | <|"From" -> _, "To" -> _|> ("Today" は厳密に今日のみ、"ThisWeek"/"DueSoon" は今日±7日以内 (今週内に過ぎた期限切れも含むが遠い過去は除外)、"Overdue" は期限切れ全部), "Deadline" -> "Today" | "Overdue" | "ThisWeek" | "DueSoon" | <|"From" -> _, "To" -> _|>, "Keywords" -> {String, ...} | String (Header.Keywords + Header.Title + FileBaseName + 親フォルダ名に部分一致、複数指定時は OR), "Title" -> String | {String, ...} ("Keywords" と同じ検索プールを見るエイリアス), "Status" -> "Todo" | "Done" | String, "Scope" -> "Today" (複合フィルタ: NextReview==今日 | Deadline==今日 | Path に YYYYMMDD 形式で今日を含む の OR。NoReviewDate / NoDeadline はレビュー不要扱いで含まれない), "ForceReindex" -> False (True なら mtime/ハッシュ cache を無視して全 notebook を再 index。notebook を編集したのに結果が古い場合に使う), "Format" -> False (True なら結果を SourceVaultFormatNotebookList でスケジュール表と同形式の Grid にして返す)
### SourceVaultFormatNotebookList[records] → Grid
notebook record リストをスケジュール表と同形式の Grid にフォーマットする。SourceVaultFindNotebooks の "Format" -> True オプションが内部で呼ぶ。
### SourceVaultNotebookLint[record] → List
notebook record (または path) に対して lint チェックを行う。検出される lint: MissingHeader / UnsafeHeaderExpression / HeaderDeadlineMalformed / HeaderNextReviewMalformed / HeaderStatusTodoButNoOpenTodos / HeaderStatusDoneButOpenTodosExist / DeadlinePast / NextReviewPast / TodoCellStatusHeuristicOnly。

## Stage 9 P1 Step 1: TaggingRules 標準化

### SourceVaultExtractNotebookTaggingRules[path]
notebook 全体および各 TodoItem cell の TaggingRules を取得する。Wolfram 標準関数優先原則 (rule 102) に基づき `Import[path, "Notebook"]` の Notebook 式から TaggingRules を抽出し、`NotebookImport[path, style -> "Cell"]` で各 TodoItem cell の options から TaggingRules を抽出する。
→ Association: <|"Status" -> "OK" | "Failed", "Path" -> String, "NotebookTaggingRules" -> Association (Notebook[..., TaggingRules -> _] の値、なければ <||>), "CellTaggingRules" -> {<|"Index" -> Integer, "CellStyle" -> String, "TaggingRules" -> Association|>, ...}|>

## Stage 9 P1 Step 2: NotebookSemanticHash

### SourceVaultNotebookSemanticHash[path]
notebook の意味的内容のみを対象にしたハッシュを計算する。表示メタデータ (ExpressionUUID / CellChangeTimes / CellLabel / FontFamily 等) やウィンドウ設定 (WindowSize / WindowMargins / FrontEndVersion 等) は除外し、意味的に重要な要素 (content / style / TaggingRules / FontVariations / FontColor / Background) のみをハッシュ対象とする。Stage 8 と連携し formatting のみの変更で Stale 化誤判定を防ぐ。実装: `Import[path, "Notebook"]` + `Hash[normalizedExpr, "SHA256", "HexString"]`。
→ Association: <|"Status" -> "OK" | "Failed", "Path" -> String, "SemanticHash" -> String|>

## Stage 9 P1 Step 4: Summary artifact stale 判定

### SourceVaultRegisterNotebookSummary[path, summary, opts]
notebook の summary artifact を登録する。現在の snapshot (SnapshotId + SemanticHash) と紐づけて保存されるため後日 stale 判定可能。
→ Association: <|"Status" -> "OK" | "Failed", "SummaryId" -> String, "NotebookRef" -> String, ...|>
Options: "SummaryFormat" -> "text" | "markdown" (既定 "text"), "GeneratedBy" -> String (既定 "manual")
### SourceVaultGetNotebookSummary[path]
notebook に紐づく summary record を取得する。未登録の場合は "Status" -> "Missing" を返す。
→ Association: <|"Status" -> "OK" | "Missing" | "Failed", "Summary" -> String, "SummaryFormat" -> String, "BasedOnSnapshot" -> String, "BasedOnSemanticHash" -> String, "GeneratedBy" -> String, "CreatedAt" -> String|>
### SourceVaultNotebookSummaryStatus[path]
notebook の summary artifact の現在 lifecycle ステータスを判定する。Step 5 以降で自動リフレッシュ決定に活用する。判定: Missing (summary が存在しない) → Current (BasedOnSnapshot が現在の snapshot と一致) → StaleFormattingOnly (SemanticHash が一致、formatting のみの変更、再生成任意) → Stale (SemanticHash が変わった、再生成推奨)。
→ Association: <|"Status" -> "Missing" | "Current" | "StaleFormattingOnly" | "Stale", "Reason" -> String, "CurrentSnapshot" -> String, "SummaryBasedOnSnapshot" -> String | Missing|>

## Stage 9 P1 Step 5: LLM 要約

### SourceVaultNotebookSummary[path, opts]
notebook の内容を LLM で要約し Summary artifact として保存する。Step 4 の SourceVaultRegisterNotebookSummary を内部で呼ぶため snapshot・SemanticHash 紐づけ・lifecycle 管理は自動。Current で ForceRefresh なしの場合は既存 record を返す。プライバシー既定: PrivacyLevel -> 1.0 (ローカル LM 経由で notebook 内容を API に送らない)。ClaudeCode`ClaudeQuerySync 経由で LLM を呼ぶ。
→ Current で ForceRefresh なし: SourceVaultGetNotebookSummary と同形の Association
→ 生成成功: SourceVaultRegisterNotebookSummary と同形の Association
→ Inconsistent (FallbackToCloud キャンセル): <|"Status" -> "Inconsistent", "Reason" -> String, ...|>
→ 失敗: <|"Status" -> "Failed", "Reason" -> String, ...|>
Options: "ForceRefresh" -> False (既存 summary が Current でも強制再生成), "MaxLength" -> 500 (要約の最大文字数、LLM prompt 経由で指定), "Language" -> Automatic | "Japanese" | "English", "Model" -> Automatic | {"provider", "model"}, "PrivacyLevel" -> 1.0 (0.0 (API 許可) 〜 1.0 (ローカルのみ)), "FallbackToCloud" -> "Ask" | "Allow" | "Deny"

## Stage 9 P1 Step 6: MarkTodo

### SourceVaultMarkTodo[path, target, newStatus, opts]
notebook 内の Todo cell の Status を変更する。NBAccess の高レベル API NBWriteTodoStatus への薄いラッパー。target は Integer (1-based Todo Index) / String (TodoId) / Association (<|"Index" -> n, "Text" -> "..."|>)。newStatus は "Open" / "Done" / "Pass"。変更内容は NBWriteTodoStatus に委だ: Cell options の FontVariations StrikeThrough + FontColor (緑/灰)、Cell TaggingRules <|"SourceVault" -> <|"TodoStatus" -> newStatus|>|>。
→ DryRun 時: <|"Status" -> "DryRunOK", "Target" -> _, "MatchedTodo" -> <|...|>, "OldStatus" -> _, "NewStatus" -> _, "CellPath" -> {Integer, ...}, "Before" -> HoldComplete[...], "After" -> HoldComplete[...]|>
→ 実行時: <|"Status" -> "OK" | "Failed", "Target" -> _, "MatchedTodo" -> <|...|>, "OldStatus" -> _, "NewStatus" -> _, "ReindexResult" -> Association | Missing["NotRequested"]|>
Options: "DryRun" -> True (既定 True、安全側。False にして実行), "AutoReindex" -> True (編集成功後に SourceVaultIndexNotebook を自動呼び出し、実行時のみ), "AccessSpec" -> <|"AccessLevel" -> 0.7, ...|> (NBAccess に渡す)

## Stage 9 P1 Step 3: UpcomingSchedule

### SourceVaultUpcomingSchedule[opts]
今後のスケジュール一覧を返す。(提供ソースの末尾で切断のため完全な usage 宣言は未確認。SourceVaultFindNotebooks の NextReview/Deadline フィルタと連携するとみられる)
→ (詳細不明)