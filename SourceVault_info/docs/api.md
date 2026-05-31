# SourceVault API リファレンス

外部 source（PDF/URL/arXiv/notebook）管理パッケージ。`BeginPackage["SourceVault`", {"NBAccess`"}]`。NBAccess の NBAuthorize に依存。物理ストレージは PrivateVault（authoritative）/ CloudMirror / Tmp / AttachmentMirror の tier 構造。LLM 連携は claudecode.wl（ClaudeCode`）を遅延ロード。

## Bootstrap / 設定

### $SourceVaultVersion
型: String
SourceVault パッケージのバージョン文字列。

### $SourceVaultRoots
型: Association
物理 root ディレクトリマッピング。Keys: "PrivateVault" | "CloudMirror" | "Tmp" | "AttachmentMirror" | "ExternalOwned"。PrivateVault は authoritative storage で cloud LLM / Claude Code CLI に直接読ませない。CloudMirror / AttachmentMirror は materialize 済み projection のみ。

### $SourceVaultSeedModelRegistry
型: Association
bootstrap 時の fallback model registry。production truth ではなく、compiled registry が無い場合の災害復旧用 fallback。LLM 自動更新しない。

### $SourceVaultCloudRoots
型: List
クラウド共有フォルダのシンボル名リスト。例: {"$packageDirectory", "$dropbox", "$onWork", "$offWork", "$mathematicaWork"}。絶対パスをこれら配下なら {"$onWork", "folder", "file.nb"} 形式のシンボリックパスに正規化し PC/OS をまたいで同一 ID になる。PC 固有フォルダ（$ClaudeWorkingDirectory 等）は含めない。

### $SourceVaultCloudRootAliases
型: Association, 初期値: <||>
クラウドルートのシンボル名（"$onWork" 等）から旧 PC 等別環境での絶対パスリストへの対応。形式: <|"$onWork" -> {"C:/Users/imai_/Dropbox/On Work"}, ...|>。別 PC で index されたレコードの旧パスを正規化し二重登録を防ぐ。エイリアスパスは現 PC に実在不要（前方一致、大小無視）。

### $SourceVaultMaxFileSizeMB
型: Integer, 初期値: 50
index 時に .nb を Import するファイルサイズの上限(MB)。超えるファイルは Import せずファイル情報だけの軽量 snapshot を作る(Skipped マーク)。

### SourceVaultInitialize[opts]
SourceVault の物理 root を生成して初期化。PrivateVault, Tmp は必須。作成済みなら noop。
→ Association
Options: "Roots" -> $SourceVaultRoots (override), "Force" -> False (True で再初期化)

### SourceVaultStatus[sourceRef] → Association
指定 source / snapshot / ファイルの概要。引数なし SourceVaultStatus[] は vault 全体の概要。

### SourceVaultList[] → List
vault 内の全 source ID リスト。

### SourceVaultSnapshots[sourceRef] → List
指定 source に限定した snapshot ID リスト。

### SourceVaultResetStore[opts]
notebooks ストア(sources/snapshots/summaries/todos/review/lint/sync/relink)を全削除して初期化。破壊的。
→ <|"Status" -> "OK"|"DryRun"|"Failed", "Deleted" -> _List, "NotebooksDir" -> _|>
Options: "Confirm" -> False (無いと DryRun 扱い、実削除しない)

## Lookup / Resolve（Stage 6b: Compiled Registry）

### SourceVaultResolve[kind, query, opts]
compiled registry から query に match する entry を返す。複数 match 時は Availability != "Unavailable" をフィルタ、Class/Freshness で sort し先頭を返す。
→ entry Association または Missing["NotFound"]
Options: "Channel" -> "public" ("private"), "AllowSeed" -> True, "Topic" -> Automatic ("<kind>-registry" 小文字化)
例: SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]

### SourceVaultLookup[topic, key, opts]
compiled registry から key に対応する entry を返す単純キー引き。compiled に無ければ seed に fallback。
→ entry Association または Missing["NotFound"]
Options: "Channel" -> "public", "AllowSeed" -> True
topic 例: "model-registry" | "mathematica-graph-options"。key は String または Association。

### ClaudeResolveModel[provider, intent] → entry Association
SourceVaultResolve["Model", ...] の互換 wrapper。旧 WikiDBResolveModel の置き換え。
例: ClaudeResolveModel["anthropic", "heavy"]

### SourceVaultListModels[provider] → List
指定 provider に登録された選択可能な全モデル ID リスト（catalog 列挙）。compiled 優先、無ければ seed。Availability Unavailable は除外。

### SourceVaultModelContextLength[provider, modelId] → Integer | None
モデルに紐づく ContextLength（SourceVaultSetModel で永続化された値）。未設定なら None。

### SourceVaultListRegistries[opts] → Association
登録済み registry topic と channel。
Options: "Channel" -> All ("public" | "private")

### SourceVaultRegistryStatus[topic, opts]
指定 topic の registry 状態。
→ <|"Topic", "Channel", "CompiledPath", "CompiledExists", "CompiledCount", "SeedPath", "SeedExists", "SeedCount", "LastModified"|>
Options: "Channel" -> "public"

### SourceVaultCompileRegistry[topic, entries, opts]
entries(List of Association)を compiled registry に保存。
→ <|"Status", "Topic", "Channel", "Path", "Count"|>
Options: "Channel" -> "public", "Sources" -> {} (関連 claim/snapshot id), "PolicySource" -> _String

### SourceVaultRegisterSeed[topic, entries] → Association
seed entries を seeds/<topic>-seed.json に保存(bootstrap 用)。production truth ではなく fallback 用。

## Ingest（Stage 1.5/2/4）

### SourceVaultIngest[source, opts]
外部 source を登録し raw snapshot を PrivateVault に保存。Local file path / HTTPS・HTTP URL(URLDownload) / arXiv:NNNN.NNNNN[vN] に対応。
→ Association (Status: Ingested/AlreadyCurrent/RebuiltMetadata/Queued)
Options:
Topic -> Automatic | _String
TrustLevel -> Automatic | "OfficialAPI" | "OfficialDocs" | "PublicWeb" | "LocalFile"
PrivacyLabel -> Automatic | _Real
PinVersion -> True | False | Automatic
Asynchronous -> False (True で LLMGraphDAGCreate 経由ジョブ投入、JobId 即時 return。claudecode.wl 必須)
EnsureUUID -> Automatic | True | False (.nb 取り込み時、hash 計算前に SourceVaultEnsureNotebookUUID で UUID 埋め込み。.nb 以外と巨大ファイルはスキップ)

### SourceVaultIngestWait[ingestResult, timeoutSec] → Association
非同期 ingest の完了を待つ。sync 完了済みなら即 return。Status: Queued なら SourceId の snapshot 増加を polling。timeoutSec(既定 60)超過で Status: Timeout。第一引数は Ingest 結果 Association または SourceId String。

## PDF page 抽出（Stage 4B）

### SourceVaultExtractPages[snapshot, pages, opts]
snapshot の指定 page を抽出し cache に保存。snapshot は SnapshotId または SourceId(latest 使用)。pages は Integer / List of Integer / All。各 page を parsed/by-snap/<id>/pages/NNNN.txt に cache、page-hashes.json に SHA-256 保存。cache hit 時は Import しない。抽出結果が空 or 5文字未満なら $SourceVaultOCRHook を呼ぶ。
→ <|"Status", "SnapshotId", "Pages" -> {n: text, ...}, "Hashes" -> <|...|>, "CachedFrom" -> "Disk"|"Fresh"|"Mixed", "OCRCalled" -> True|False|>
Options: Force -> False (cache 無視再抽出), "ForceOCR" -> False (この呼出だけ OCR 強制、スキャン判定スキップ。hook 必須。True 時 Force も自動適用)

### $SourceVaultOCRHook
型: None | Function, 初期値: None
スキャン PDF の fallback 値。シグネチャ: Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String。ページテキスト抽出失敗時に呼ばれ返値が text として cache される。Phase 4C の SourceVaultOCREnable 経由設定を推奨。

### $SourceVaultOCRMode
型: String, 初期値: "Auto"
OCR 発火モード。"Auto": Plaintext 抽出結果が 5文字未満時のみ OCR。"Force": 長さに関わらず常に OCR(低品質テキスト層対策)。SourceVaultOCREnable[..., "Mode" -> "Force"] で永続化、SourceVaultOCRDisable[] で "Auto" にリセット。

### $SourceVaultOCRVerbose
型: Bool, 初期値: False
OCR 実行時の進捗 Print 制御。True で rasterization/API 呼出/レスポンス長等を Print。

## OCR backends（Stage 4C）

### SourceVaultOCREnable[backend, opts]
OCR hook を有効化。backend 既定 "ClaudeVision"。
→ <|"Status" -> "Enabled", "Backend", "Mode", "Options"|>
backend 別 Options:
"ClaudeVision"(ClaudeCode`ClaudeQueryBg 経由で page 画像送信、大 page は上下分割30px overlap): "DPI" -> 300, "SplitHalves" -> True, "Timeout" -> 180, "Prompt" -> Automatic
"TextRecognize"(組込 TextRecognize、Python 不要): "DPI" -> 150, "Language" -> "Japanese"
"Custom"(ユーザ Function をそのまま $SourceVaultOCRHook に設定): "Hook" -> Function[req, text]
共通 Options: "Mode" -> "Auto" | "Force"

### SourceVaultOCRDisable[] → Association
OCR hook を無効化($SourceVaultOCRHook = None)。

### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定。Backend: Disabled/ClaudeVision/TextRecognize/Custom、HookSet: Bool。

## Claim 抽出（Stage 5/6a）

### SourceVaultExtract[sourceSpan, schema, opts]
sourceSpan の page text を LLM に渡し claim を抽出。sourceSpan は SourceVaultSpan 結果または SnapshotId/SourceId String。schema は登録済み schema 名 String または Association(インライン定義)。
→ <|"Claims" -> {claim1, ...}, "Count"(実納数), "ExtractedCount"(LLM 生抽出数), "DedupSkipped", "AccessDecisions" -> <|"Send", "Persist"|>, "ValidationStatus", "SchemaName", "ExtractedAt" -> DateObject, "Errors"|>
Deny: <|"Status" -> "DeniedByNBAccess", "Reason", "AccessDecisions"|>
RequireApproval: <|"Status" -> "RequiresApproval", "Reason", "AccessDecisions"|>
Options:
"Topic" -> _String (既定 schema 名)
"ModelIntent" -> "summary" | "extraction" | "math-extraction-heavy"
"StoreClaims" -> True
"Dedup" -> True (by-source ファイル単位で ContentHash 照合)
"AuthorizationCheck" -> True (Stage 6d: 2段階 NBAuthorize。sendDecision→抽出→persistDecision)
"Validation" -> "None" | "Required"
MaxCharacters -> 8000
Timeout -> 180

### SourceVaultRegisterSchema[name, definition] → Association
抽出 schema をグローバルに登録。definition Association:
"Description" -> String (LLM 向け説明)
"Fields" -> {<|"Name", "Type" -> "Number"等, "Required" -> Bool, "Description"|>, ...}
"OutputShape" -> "List" | "Single"
"PromptTemplate" -> Automatic | _String
ビルトイン schema: "FreeText", "NumericFacts", "DefinitionList"。

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
ClaimStore の状態(debug)。ClaimsDir / MasterPath / MasterExists / MasterClaims(行数) / TopicFiles / SourceFiles。

### SourceVaultClaimStoreCompact[opts]
master + by-topic + by-source を全読みし ContentHash で dedup して全インデックス rebuild。atomic rewrite。dedup は master 先頭行を残す。
→ <|"Status" -> "OK"|"Failed", "BeforeCount", "AfterCount", "Removed", "BackupPaths", "DryRun"|>
Options: "Backup" -> True (.bak.<timestamp>), "DryRun" -> False (True で統計のみ)

## Evidence Bundle（Stage 6c）

### SourceVaultBundleCreate[name, deps, opts]
generated artifact の依存を evidence bundle として保存。BundleId は自動生成。deps Association:
"GeneratedFiles" -> {"path/to/output1.wl", ...}
"Sources" -> {<|"SourceId", "SnapshotId"|>, ...}
"SourceSpans" -> {...} (optional)
"Claims" -> {"claim-...", ...}
"Generator" -> <|"Tool", "WorkflowId", "ModelIntent", "ResolvedModel"|>
→ <|"Status" -> "OK"|"Failed", "BundleId", "Path"|>
Options: "Kind" -> "SimulationExample" | "LaTeXExport" | "DocumentGeneration" | "CodeGeneration" | "Notebook" | _String

### SourceVaultBundleGet[bundleId] → Association | Missing["NotFound"]
指定 bundle を読み込み返す。

### SourceVaultBundleList[] → List
全 bundle id リスト。

### SourceVaultBundleStatus[bundleId] → Association
bundle の現在 Status を計算。参照 snapshot の LifecycleStatus を集約("Current"|"Stale"|"NeedsReview"|"Invalidated")。手動 Invalidate 済みなら強制 "Invalidated"。
→ <|"Status", "Reason", "AffectedSnapshots", "AffectedClaims"|>

### SourceVaultBundleInvalidate[bundleId, reason] → Association
bundle を手動 invalidate。reason は記録され後で BundleStatus が返す。

### SourceVaultBundleDelete[bundleId] → Association
bundle ファイルを削除(debug)。

## vN diff + snapshot lifecycle（Stage 8）

### SourceVaultDiffVersions[v1Snap, v2Snap]
二つの snapshot の page hash 集合(page-hashes.json)を比較。
→ <|"Status", "V1Snap", "V2Snap", "AddedPages"(v2のみ), "RemovedPages"(v1のみ), "ChangedPages"(両方ありhash違う), "UnchangedPages"(両方ありhash一致)|>

### SourceVaultMarkSnapshotStale[snapshotId, reason] → Association
snapshot meta の LifecycleStatus を "Stale" に更新し source-events.jsonl に VersionedUpdate event 記録。参照 Bundle が自動的に "Stale" を返すようになる。

### SourceVaultMarkSnapshotInvalidated[snapshotId, reason] → Association
LifecycleStatus を "Invalidated" に更新(Retraction 等)。Bundle は "Invalidated" を返す。

### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason]
高レベル refresh。diff 計算→oldSnap を "Stale" + SupersededBy=newSnap→event 記録(VersionedUpdate)。
→ <|"Status", "Diff" -> _Association, "Event" -> _Association|>

### SourceVaultBundlesForSnapshot[snapshotId] → List
指定 snapshot を参照する全 bundle id リスト。

### SourceVaultSourceEvents[opts] → List
events/source-events.jsonl の全 event リスト。
Options: "SourceId" -> _String, "SnapshotId" -> _String, "EventType" -> "VersionedUpdate"|"Retraction"|"SourceDeletion"|"SchemaChange"

### SourceVaultSourceEventAppend[event] → Association
event Association を source-events.jsonl に append。EventType/SourceId/Reason 必須。OldSnapshotId/NewSnapshotId/Metadata 任意。EventId/Timestamp 自動生成。

## Notebook 管理（Stage 9 P0）

### SourceVaultRegisterNotebook[path]
指定 path の notebook を登録。NotebookRef は path-based hash で安定生成。
→ <|"Status", "NotebookRef", "Path", "RegisteredAt"|>

### SourceVaultIndexNotebook[path, opts]
notebook の Header/Todo/Cell を抽出し index 更新。
→ <|"Status", "NotebookRef", "SnapshotId", "Header", "TodoCount", "OpenTodoCount", "ReviewState", "DeadlineState", "Lint"|>
Options: "ExtractHeader" -> True, "ExtractTodos" -> True, "ForceReindex" -> False (file mtime 同じなら skip)

### SourceVaultIndexNotebookFolder[dir, opts]
folder 配下の .nb を全て index。
→ <|"Status", "Processed", "Failed", "Results"|>
Options: "Recursive" -> False, "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}

### SourceVaultExtractNotebookHeader[path]
notebook 先頭 Input セルから Header を safe parse(HoldComplete + whitelist で RunProcess/Get/Import 等拒否)。
→ <|"ParseStatus" -> "OK"|"MissingHeader"|"UnsafeExpression", "Keywords", "Deadline", "NextReview", "Status"|>

### SourceVaultExtractNotebookTodos[path]
notebook 内 TodoItem スタイルセルを列挙。Status 3値(Open/Done/Pass)、判定優先順位: TaggingRules > FontVariations StrikeThrough + FontColor > Default。StrikeThrough なし→Open、+緑→Done、+灰→Pass、+その他→Done。
→ {<|"Text", "Status", "StatusSource", "StrikeThrough" -> _Bool|>, ...}

### SourceVaultFindNotebooks[opts] → List
index 済み notebook を検索(deterministic、LLM 不要)。
Options:
"OpenTodos" -> True | False
"NextReview" -> "Today" | "Overdue" | "ThisWeek" | "DueSoon" | <|"From", "To"|> ("Today" は厳密に今日のみ、"ThisWeek"/"DueSoon" は今日+週内+期限切れ含む)
"Deadline" -> "Today" | "Overdue" | "ThisWeek" | "DueSoon" | <|"From", "To"|>
"Keywords" -> {_String, ...} | _String (部分一致、対象: Header.Keywords+Header.Title+FileBaseName+親フォルダ名、複数 OR)
"Title" -> _String | {_String, ...} ("Keywords" と同検索プールのエイリアス)
"Status" -> "Todo" | "Done" | _String
"Scope" -> "Today" 複合フィルタ: (NextReview==今日)|(Deadline==今日)|(Path に YYYYMMDD で今日) の OR
"Format" -> False (True で SourceVaultFormatNotebookList の Grid を返す)
→ {<|NotebookRef, OriginalPath, Title, Header, ReviewState, ...|>, ...}

### SourceVaultNotebookLint[record] → List
notebook record(または path)に lint チェック。検出: MissingHeader / UnsafeHeaderExpression / HeaderDeadlineMalformed / HeaderNextReviewMalformed / HeaderStatusTodoButNoOpenTodos / HeaderStatusDoneButOpenTodosExist / DeadlinePast / NextReviewPast / TodoCellStatusHeuristicOnly。
→ {"LintName1", ...}

### SourceVaultExtractNotebookTaggingRules[path]
notebook 全体および各 TodoItem cell の TaggingRules 取得。Import[path,"Notebook"] + NotebookImport[path, style->"Cell"] 経由。
→ <|"Status" -> "OK"|"Failed", "Path", "NotebookTaggingRules" -> _Association, "CellTaggingRules" -> {<|"Index", "CellStyle", "TaggingRules"|>, ...}|>

### SourceVaultNotebookSemanticHash[path]
notebook の意味的内容のみ(content/style/TaggingRules/FontVariations/FontColor/Background)を対象にハッシュ計算。表示メタデータ(ExpressionUUID/CellChangeTimes/CellLabel/FontFamily 等)とウィンドウ設定は除外。formatting のみの変更で Stale 化誤判定を防ぐ。Import[path,"Notebook"] + Hash[normalizedExpr,"SHA256","HexString"]。
→ <|"Status" -> "OK"|"Failed", "Path", "SemanticHash"|>

## Notebook Summary lifecycle（Stage 9 P1 Step 4/5）

### SourceVaultRegisterNotebookSummary[path, summary, opts]
notebook の summary artifact を登録。現在の snapshot(SnapshotId + SemanticHash)と紐づけて保存し後日 stale 判定可能。
→ <|"Status" -> "OK"|"Failed", "SummaryId", "NotebookRef", ...|>
Options: "SummaryFormat" -> "text" | "markdown", "GeneratedBy" -> "manual"

### SourceVaultGetNotebookSummary[path]
notebook に紐づく summary record。未登録なら "Status" -> "Missing"。
→ <|"Status" -> "OK"|"Missing"|"Failed", "Summary", "SummaryFormat", "BasedOnSnapshot", "BasedOnSemanticHash", "GeneratedBy", "CreatedAt"|>

### SourceVaultNotebookSummaryStatus[path]
summary artifact の lifecycle 判定。Missing(未存在) / Current(BasedOnSnapshot が現 snapshot と一致) / StaleFormattingOnly(SemanticHash 一致、再生成任意) / Stale(SemanticHash 変化、再生成推奨)。
→ <|"Status", "Reason", "CurrentSnapshot", "SummaryBasedOnSnapshot" -> _String|_Missing|>

### SourceVaultNotebookSummary[path, opts]
notebook 内容を LLM で要約し Summary artifact 保存。内部で RegisterNotebookSummary を呼ぶため lifecycle 管理は自動。既定 PrivacyLevel -> 1.0(ローカル LM のみ、内容を API に送らない)。Current で ForceRefresh 無しなら既存 record を返す。
→ 生成成功: Register 同形 Association / Inconsistent: <|"Status" -> "Inconsistent", "Reason", ...|> / Failed: <|"Status" -> "Failed", "Reason", ...|>
Options:
"ForceRefresh" -> False
"MaxLength" -> 500
"Language" -> Automatic | "Japanese" | "English"
"Model" -> Automatic | {"provider", "model"}
"PrivacyLevel" -> 1.0 (0.0=API許可 〜 1.0=ローカルのみ)
"FallbackToCloud" -> "Ask" | "Allow" | "Deny"

### SourceVaultMarkTodo[path, target, newStatus, opts]
notebook 内 Todo cell の Status を変更(書き込み系)。NBAccess`NBWriteTodoStatus への薄いラッパー。target: Integer(1-based Index) / String(TodoId) / Association(<|"Index", "Text"|>)。newStatus: "Open"/"Done"/"Pass"。変更内容: Cell options(FontVariations StrikeThrough + FontColor 緑/灰) + Cell TaggingRules <|"SourceVault" -> <|"TodoStatus" -> newStatus|>|>。
→ DryRun: <|"Status" -> "DryRunOK", "Target", "MatchedTodo", "OldStatus", "NewStatus", "CellPath", "Before" -> HoldComplete[...], "After" -> HoldComplete[...]|>
→ 実行: <|"Status" -> "OK"|"Failed", "Target", "MatchedTodo", "OldStatus", "NewStatus", "ReindexResult" -> _Association|Missing["NotRequested"]|>
Options: "DryRun" -> True (preview のみ、安全側), "AutoReindex" -> True (実行時のみ), "AccessSpec" -> <|"AccessLevel" -> 0.7, ...|>

## スケジュール表示（Stage 9 P1）

### SourceVaultUpcomingSchedule[opts] → Dataset
「今日から N 日以内」に Deadline/NextReview がある notebook 一覧を Dataset で返す。概要もキャッシュから取込(必要時自動再生成)。日付 yyyy/mm/dd、期限切れ赤、今日明日青。
Options:
"Scope" -> dir (default $onWork または $packageDirectory)
"Period" -> Quantity[7, "Days"]
"IncludeOverdue" -> True
"Recursive" -> True
"Refresh" -> "Never" | "IfStale" | "Force"
"FallbackToCloud" -> "Ask" | "Allow" | "Deny"
"StatusFilter" -> {"Todo"} | {"Todo","Done","Pass"} | All
"UseCache" -> True
→ Dataset(行={Deadline, NextReview, Title(Open button), Dir(Open button), OpenTodos, Status, Privacy})

### SourceVaultFormatNotebookList[records_List, opts] → Grid
notebook record の List をスケジュール表と同表形式で Grid 表示。FindNotebooks 結果や IndexNotebook の OK record、Path/Header を持つ任意 Association List を受付。
Options: "Refresh" -> "Never" | "IfStale" | "Force", "FallbackToCloud" -> "Deny" | "Ask" | "Allow", "UseCache" -> True
→ Grid(行={Deadline, NextReview, Title, Dir, OpenTodos, Status, Summary, Publishable})

### SourceVaultRefreshAllSummaries[opts] → Association
Scope 配下全 notebook の概要を一括再生成。
→ <|"Status" -> "OK", "Scope", "TotalFiles", "Refreshed", "Cached", "Inconsistent", "Failed", "Details"|>
Options:
"Scope" -> dir (default $onWork)
"Recursive" -> True
"ForceRefresh" -> False
"FallbackToCloud" -> "Deny" | "Ask" | "Allow"
"OpenTodosOnly" -> False (True で OpenTodoCount>0 のみ)
"Model" -> Automatic
"Progress" -> False (True で 10 件毎進捗 Print)
"Limit" -> Infinity

## Context retrieval / Attach（Stage 3）

### SourceVaultSpan[snapshotOrRef, opts] → Association
SourceSpan association を作る。snapshotOrRef は SnapshotId/SourceRef/file path。
Options: "Pages" -> {1,3,5} | All | _Integer, "Role" -> "ReferenceContext" | "Evidence" | "ExtractionInput", "Purpose" -> "LaTeXMathFormatting" | _String

### SourceVaultContext[sourceSpan, opts]
sourceSpan の plaintext を取り出し NBAuthorize 判定付きで LLM 文脈として返す。RequireApproval も block。
Options: MaxCharacters, "Sink", "Purpose"

### SourceVaultContextAssemble[sourceSpans, opts]
複数 span を 1 つの prompt context に組み立てる。
Options: "Purpose" -> _String, MaxCharacters -> _Integer, "Ordering" -> "PageOrder" | "Citation" | "GivenOrder", "Separators" -> "ByPage" | "BySource" | None, "IncludeCitations" -> True | False, "Sink" -> _Association

### SourceVaultAttach[nb, source, opts]
notebook に source を attach し TaggingRules に sourceVaultRefs を記録。旧 ClaudeAttach のバックエンド代わり。

### SourceVaultAttachToCell[nb, cellIdx, sourceSpan, opts]
cell に SourceSpan を attach。

### SourceVaultGetAttachments[nb] → List
notebook に attach された source 一覧。

### SourceVaultGetCellSources[nb, cellIdx] → List
cell に紐づく SourceSpan リスト(旧 refSources を read-only normalization)。

### SourceVaultEnsureRegistered[ref] → Association
旧 refSources 形式(or file path)を SourceSpan 形式に normalize。必要に応じ ingest。

## Materialization

### SourceVaultMaterializeForSink[sourceRef, sinkSpec, opts]
source を cloud-accessible mirror へ materialize。内部で必ず NBAuthorize を呼ぶ。

### SourceVaultResolvePath[ref, opts] → String
source/snapshot の物理 path。"Tier" -> "PrivateVault" は local kernel/maintenance 専用。cloud LLM 向けには SourceVaultMaterializeForSink を使う。

### SourceVaultObjectSpec[ref, opts] → Association
source/snapshot を NBAuthorize が受け取れる object spec association に変換。

## Ingest オプションシンボル
Topic / PinVersion / TrustLevel / PrivacyLabel — SourceVaultIngest オプション。
MaxCharacters — SourceVaultContext / SourceVaultContextAssemble オプション。

## ClaudeAttach Integration

### SourceVaultClaudeAttachIntegrationEnable[]
ClaudeAttach 呼出時に SourceVault への side-channel ingest を行う hook を有効化。既に有効なら noop。元の DownValue は保持、Disable で復元可。前提: claudecode.wl(ClaudeCode`ClaudeAttach)ロード済み。

### SourceVaultClaudeAttachIntegrationDisable[]
hook を外し ClaudeAttach を元の DownValue に復元。

### SourceVaultClaudeAttachIntegrationStatus[] → Association
hook 状態。Keys: Enabled, OriginalSaved, OriginalDVCount, HookTarget。

### SourceVaultGetClaudeAttachRefs[nb] → List
notebook に紐づいた ClaudeAttach side-channel ingest 記録の flat list。各 entry: OriginalPathOrURL / ExpandedPath / SnapshotId / SourceId / ContentHash / IngestStatus / AttachedAt。引数なしで EvaluationNotebook[] を使う。

## ClaudeAttachments Integration

### SourceVaultClaudeAttachmentsIntegrationEnable[]
ClaudeAttachments[] 呼出時に返値を List of paths から Association list に拡張する hook を有効化。各 Association に cached path/source/metadata + SnapshotId/SourceId/ContentHash/IngestStatus を join。前提: ClaudeCode`ClaudeAttachments ロード済み。

### SourceVaultClaudeAttachmentsIntegrationDisable[]
hook を外し復元。

### SourceVaultClaudeAttachmentsIntegrationStatus[] → Association
現在の hook 状態。

## WorkerPrompt Integration（A5 hook）

### SourceVaultWorkerPromptIntegrationEnable[]
ClaudeOrchestrator の A5 hook に SourceVault context 注入関数を登録。worker prompt 構築時に吹出。前提: ClaudeOrchestrator.wl に A5 hook 5行追加済み。トリガー: task["SourceSpans"](明示)+ ClaudeAttach 履歴(自動検出)。

### SourceVaultWorkerPromptIntegrationDisable[]
A5 hook の定義をクリア。

### SourceVaultWorkerPromptIntegrationStatus[] → Association
現在の A5 hook 状態。

### $SourceVaultWorkerPromptAutoDetect
型: Bool, 初期値: True
A5 hook 有効時の自動検出 ON/OFF。True: ClaudeAttach 履歴から SnapshotId を自動検出して注入。False: task["SourceSpans"] 明示のみ。

## ParseProposal Integration（A6 hook）

### SourceVaultParseProposalIntegrationEnable[]
ClaudeOrchestrator の A6 hook に parseProposal post-processing 登録。LLM 応答内の <source>snap-...</source> / <source>src-...</source> XML タグを抽出し parseProposal 返値 Association に "SourceVaultRefs" キー追加。前提: ClaudeOrchestrator.wl に iApplyA6Hook + A6 hook 呼入済み。

### SourceVaultParseProposalIntegrationDisable[]
A6 hook 定義をクリア(iApplyA6Hook は no-op に戻る)。

### SourceVaultParseProposalIntegrationStatus[] → Association
現在の A6 hook 状態。

## Privacy / Sync / Relink

### SourceVaultSetSnapshotPrivacyLevel[snapshotId, level]
snapshot record の PrivacyLevel を明示上書き。NBAccess`NBSetSnapshotPrivacyLevel への委譲先。承認ゲートは NBAccess の $NBApprovalHeads で発火。Notebook snapshot と PDF/URL snapshot の両系統をファイル存在で判別。level は 0.0-1.0 に clip。既存より低い値指定で "Lowered" -> True(手動操作なので許可)。
→ <|"Status", "SnapshotId", "OldPrivacyLevel", "NewPrivacyLevel", "Lowered", "SnapshotKind"|>

### SourceVaultSelectSources[opts]
同期対象 source を選定。Scope 配下の .nb をスキャンし source descriptor 化。
→ <|"Status", "Scope", "Count", "Sources" -> {_Association..}|>
Options: Scope / Recursive / Kind / ExcludePatterns

### SourceVaultSyncPlan[opts]
各 source の鮮度を判定し同期計画を返す(dry-run)。鮮度トークン(ローカルは mtime)を現 snapshot 記録と比較し Fresh/Stale/Missing/NeverIndexed に分類。
→ <|"Status", "Total", "StaleCount", "Plan" -> _Dataset, ...|>
Options: Scope / Recursive / Kind / ExcludePatterns

### SourceVaultSync[opts]
SyncPlan に従い Stale な source を再 index(クローラー骨格)。ローカル notebook は IndexNotebook で再 index。PrivacyLevel は単調(自動で下げない、下がったら旧値に引き上げ警告記録)。
→ <|"Status", "SyncId", "Refreshed", "Skipped", "Failed", "PrivacyWarnings"|>
Options: Scope / Recursive / Kind / DryRun / ForceAll / RefreshSummary / FallbackToCloud(既定 "Deny")

### SourceVaultSyncStatus[] → Association
直近の sync 実行状態(sync/last-sync.json)。未実行なら <|"Status" -> "NoSyncYet"|>。

### SourceVaultRelinkSources[opts]
OriginalPath が消えた(移動された)notebook source を検出し Scope 配下から移動先を探して再リンク。照合順: (1)埋込 UUID、(2)内容ハッシュ(RawContentHash 完全一致)、(3)ファイル名一意一致。移動判定はシンボリックパス解決ベース。マッチ先が既に別現役 record の実ファイルなら StaleDuplicate(旧 PC index 残骸)分類。
→ <|"Status", "Linked", "Relinked" -> {..}, "RelinkedCount", "ByMethod" -> <|"UUID"/"ContentHash"/"NameOnly" -> _|>, "Unresolved" -> {..}, "DryRun"|>
Options: Scope / Recursive / DryRun(既定 True) / ApplyNameOnly(既定 False) / DeleteStale(既定 False) / ExcludePatterns

## Model registry 管理

### $SourceVaultModelEndpoints
型: Association
provider 名からモデル一覧エンドポイント設定への Association。ユーザ上書き可。各値: <|"ModelsURL", "Kind" -> "Cloud"|"Local", "AuthProvider"|>。

### SourceVaultModelEndpointStatus[] → Association
各 provider エンドポイントの到達性(オフライン検知)。短タイムアウトで probe、401/403 でもサーバ到達=Online。
→ <|"Status", "Endpoints" -> <|provider -> <|"Status" -> "Online"|"Offline", ...|>|>|>

### SourceVaultDetectLocalModels[opts]
ローカル LLM サーバ(LM Studio 等、OpenAI 互換 /v1/models)からモデル一覧を推測。API キー不要。サーバがキー保護有効なら NBAccess`NBGetLocalLLMAPIKey 経由で自動解決(事前に NBStoreLocalLLMAPIKey 登録)。
→ <|"Status" -> "OK"|"Offline", "Provider", "Endpoint", "Models" -> {_String..}|>
Options: Provider(既定 "lmstudio") / Endpoint(既定は ClaudeCode`$ClaudePrivateModel の url 優先)

### SourceVaultSetModel[provider, intent, modelId, opts]
compiled model registry に手動で 1 エントリ書込(API キー不要)。Source -> "manual" で保存し同(provider,intent)の既存を置換。
Options: Channel(既定 public) / Class(既定 Automatic=推論) / Capabilities(既定 Automatic)
例: SourceVaultSetModel["anthropic", "heavy", "claude-opus-4-8"]

### SourceVaultClearModelRegistry[opts]
compiled model registry を削除し次回アクセス時に seed(コード内最新 iModelSeedEntries)から再構築。古い seed コピー残留時の復旧用。seed 自体は消さない。
Options: Channel(既定 public)

### SourceVaultSetModelIntent[variable, spec]
SourceVault が選択するモデルの intent 割当てを変更。variable: "$ClaudeModel" | "$ClaudeDocModel" | "$ClaudePrivateModel" | "$ClaudeFallbackModels"。spec: {provider, intent}(FallbackModels は {{provider,intent},...})。設定後 SourceVaultAssignClaudeModels[] で実変数に反映。$NBApprovalHeads 登録、ClaudeEval 経由では Hold->Approve 必要。
例: SourceVaultSetModelIntent["$ClaudeModel", {"anthropic", "heavy"}]

### SourceVaultModelIntentMap[] → Association
変数名 -> intent spec のマッピング(読取公開関数)。NBAccess`NBSyncClaudeModelVars が利用。
例: <|"$ClaudeModel" -> {"claudecode","code-heavy"}, ...|>

### SourceVaultAssignClaudeModels[opts]
intent マッピングと信頼ローカルサーバ(NBAccess`NBResolveLocalServer)から $ClaudeModel/$ClaudeDocModel/$ClaudePrivateModel/$ClaudeFallbackModels を設定。SourceVault ロード時に自動実行。
Options: Verbose(既定 False)

### SourceVaultRefreshModelRegistry[opts]
クラウド(anthropic/openai)とローカル(LM Studio)のエンドポイントからモデル一覧取得し compiled model registry 更新。クラウド API キーは NBAccess`NBGetAPIKey 経由、無い provider はスキップ。取得分は Source -> "auto-fetch"、既存 seed/manual は温存マージ。
→ <|"Status", "FetchedCount", "RegistryTotal", "PerProvider", "RegistryPath"|>
Options: Providers(既定 All) / IncludeCloud(既定 Automatic) / DryRun(既定 False)

## Notebook UUID

### SourceVaultNotebookUUID[path] → String | Missing[]
notebook に埋込まれた UUID(TaggingRules > SourceVault > NotebookUUID)。未設定なら Missing[]。読取のみ。

### SourceVaultEnsureNotebookUUID[path, opts]
notebook に UUID が無ければ生成して埋込。UUID は TaggingRules に保存され、ファイル名変更・内容編集をまたいで安定(RelinkSources の最も信頼できる照合キー)。
→ <|"Status", "Path", "UUID", "Created" -> True|False|>
Options: Force(既定 False、True で既存 UUID も再生成)

### SourceVaultEnsureNotebookUUIDFolder[dir, opts]
folder 配下の .nb 全てに UUID 付与。
→ <|"Status", "TotalFiles", "Created", "AlreadyPresent", "Skipped"(巨大ファイル等), "Failed"|>
Options: Recursive(既定 True) / ExcludePatterns / MaxFileSizeMB(既定 $SourceVaultMaxFileSizeMB)

## DirectiveRepository（Phase 2a）

### SourceVaultRegisterDirectiveRepository[root]
Claude Directives リポジトリ(ディレクトリ)を DirectiveRepository source として登録。RepoId は root path から決定的に導出。
→ <|"Status", "RepoId", "Root", "Path", "Registration"|>

### SourceVaultIndexDirectiveRepository[root]
Claude Directives リポジトリを index: file inventory と manifest hash を ClaudeDirectives` で計算し DirectiveRepository snapshot record を書く。未登録なら自動登録。
→ <|"Status", "RepoId", "SnapshotId", "ManifestHash", "FileCount", "Path", "Snapshot"|>

### SourceVaultDirectiveRepositoryStatus[root] → Association
登録有無・snapshot 数・最新 snapshot の manifest hash がディスクと一致するかを報告。Status: "NotRegistered" | "RegisteredNotIndexed" | "UpToDate" | "Stale"。

### SourceVaultCurrentDirectiveSnapshot[root] → Association
最新の DirectiveRepository snapshot record。無ければ Status -> "NoSnapshot"。

### SourceVaultDiffDirectiveSnapshots[old, new]
二つの DirectiveRepository snapshot record(または snapshot file paths)を RelativePath/ContentHash で比較。
→ <|"Status", "Added", "Removed", "Changed", "UnchangedCount", "ManifestHashChanged"|>

## HarnessMaterialization（Phase 2b）

### SourceVaultRegisterHarnessMaterialization[target, files, meta]
materialized harness を HarnessMaterialization bundle として登録。target は "Codex" or "ClaudeCLI"。files は生成ファイルパスリスト。meta: HarnessMode, DirectiveRoot, DirectiveRepositorySnapshotId, DirectiveRepositoryManifestHash, RuntimeEnvironmentHash, PermissionProfileHash, Generator。bundle は SourceVault bundles ディレクトリ配下に保存、SourceVaultBundleGet で読める。
→ <|"Status", "BundleId", "Path", "Bundle"|>

### SourceVaultDirectiveSnapshotStaleQ[bundle]
HarnessMaterialization bundle が構築された canonical Claude Directives snapshot が stale かを、bundle の DirectiveRepositoryManifestHash と現リポジトリ hash 比較で報告。stale なら harness 再生成すべき。
→ <|"Stale", "Reason", "RecordedManifestHash", "CurrentManifestHash"|>

### SourceVaultHarnessRuntimeEnvironmentChangedQ[bundle, currentEnv]
HarnessMaterialization bundle の runtime environment(permission profile, temp project path, attachments)が変化したか報告。currentEnv は事前計算 PermissionProfileHash/RuntimeEnvironmentHash か、生 PermissionProfile/RuntimeEnvironment Association を渡せる。runtime 変化は config.toml 再生成を要するが canonical snapshot は stale にしない。