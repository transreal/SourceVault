# SourceVault API リファレンス

外部 source 管理パッケージ。PDF/URL/arXiv/Notebook の取り込み・スナップショット・claim 抽出・evidence bundle・compiled registry・notebook 管理を提供する。`BeginPackage["SourceVault`", {"NBAccess`"}]` で [NBAccess](https://github.com/transreal/NBAccess) に依存。物理ストレージは PrivateVault(authoritative)/CloudMirror/Tmp/AttachmentMirror の tier 構成。読み込みは `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault.wl"]]`。NBAuthorize を毎回呼ぶ前提。

## Bootstrap / 設定

### $SourceVaultVersion
型: String
パッケージのバージョン文字列。

### $SourceVaultRoots
型: Association
物理 root ディレクトリ。Keys: "PrivateVault" | "CloudMirror" | "Tmp" | "AttachmentMirror" | "ExternalOwned"。PrivateVault は authoritative storage で cloud LLM / Claude Code CLI に直接読ませない。CloudMirror / AttachmentMirror は materialize 済み projection のみ置く。

### $SourceVaultSeedModelRegistry
型: Association
bootstrap 時の fallback model registry。production truth ではなく compiled registry が無い場合の災害復旧用 fallback。LLM は自動更新しない。

### $SourceVaultCloudRoots
型: List
クラウド共有フォルダのシンボル名リスト。例: {"$packageDirectory", "$dropbox", "$onWork", "$offWork", "$mathematicaWork"}。絶対パスはこれらの配下にあれば {"$onWork", "folder", "file.nb"} のようなシンボリックパスに正規化され、PC/OS をまたいで同一 ID になる。PC 固有フォルダ($ClaudeWorkingDirectory 等)は含めない。

### $SourceVaultCloudRootAliases
型: Association, 初期値: <||>
クラウドルートのシンボル名("$onWork" 等)から旧 PC など別環境での絶対パスのリストへの対応。形式: <|"$onWork" -> {"C:/Users/imai_/Dropbox/On Work"}, ...|>。エイリアスパスの配下も同じシンボル名にマッチさせ、複数 PC をまたいだ二重登録を防ぐ。

### $SourceVaultMaxFileSizeMB
型: Integer, 初期値: 50
index 時に .nb を Import するファイルサイズの上限(MB)。これを超える .nb は Import せずファイル情報だけの軽量 snapshot を作る(Skipped マーク)。

### SourceVaultInitialize[opts]
物理 root を生成して初期化する。PrivateVault, Tmp は必須。作成済みなら noop。
→ Association
Options: "Roots" -> $SourceVaultRoots ($SourceVaultRoots を override), "Force" -> False (True で再初期化)

### SourceVaultStatus[sourceRef] / SourceVaultStatus[] → Association
指定 source/snapshot/ファイルの概要。引数なしで vault 全体の概要。

### SourceVaultList[] → List
vault 内の全 source ID リスト。

### SourceVaultSnapshots[sourceRef] → List
指定 source の snapshot ID リスト。

### SourceVaultResetStore[opts]
notebooks ストア(sources/snapshots/summaries/todos/review/lint/sync/relink)を全削除して初期化。破壊的操作。
→ <|"Status" -> "OK"|"DryRun"|"Failed", "Deleted" -> _List, "NotebooksDir" -> _|>
Options: "Confirm" -> False (無いと DryRun 扱いで削除しない)

## Stage 1/6b: Lookup / Resolve / Registry

### SourceVaultLookup[topic, key, opts]
compiled registry から key に対応する entry を返す。topic は "model-registry" | "mathematica-graph-options" | _String。key は文字列または Association。コンパイルド registry に無ければ seed に fallback。
→ entry Association または Missing["NotFound"]
Options: "Channel" -> "public" ("public" | "private"), "AllowSeed" -> True (compiled 無し時 seed を使う)

### SourceVaultResolve[kind, query, opts]
compiled registry から query に match する entry を返す。kind は "Model" | _String。query は <|"Provider" -> ..., "Intent" -> ...|> 等の structured 条件。複数 match 時は Availability != "Unavailable" をフィルタ、Class/Freshness で sort して先頭を返す。
→ entry Association または Missing["NotFound"]
Options: "Channel" -> "public" ("public" | "private"), "AllowSeed" -> True, "Topic" -> Automatic (既定 "<kind>-registry" を小文字化)
例: SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]

### ClaudeResolveModel[provider, intent] → Association
SourceVaultResolve["Model", ...] の互換 wrapper。旧 WikiDBResolveModel の置き換え。
例: ClaudeResolveModel["anthropic", "heavy"]

### SourceVaultListModels[provider] → List
指定 provider に登録された選択可能な全モデル ID リスト(catalog 列挙)。compiled registry 優先、無ければ seed。Availability が Unavailable のエントリは除外。

### SourceVaultModelContextLength[provider, modelId] → Integer | None
モデルに紐づく ContextLength。SourceVaultSetModel[..., "ContextLength" -> n] で永続化された値。未設定なら None。

### SourceVaultListRegistries[opts] → Association
登録済み registry topic と channel を返す。
Options: "Channel" -> All ("public" | "private" | All)

### SourceVaultRegistryStatus[topic, opts]
指定 topic の registry 状態。
→ <|"Topic", "Channel", "CompiledPath", "CompiledExists" -> _Bool, "CompiledCount" -> _Integer, "SeedPath", "SeedExists" -> _Bool, "SeedCount" -> _Integer, "LastModified"|>
Options: "Channel" -> "public" ("public" | "private")

### SourceVaultCompileRegistry[topic, entries, opts]
entries (List of Association) を compiled registry に保存。entries は {<|"Provider" -> ..., "Intent" -> ..., "ModelId" -> ...|>, ...}。
→ <|"Status", "Topic", "Channel", "Path", "Count" -> _Integer|>
Options: "Channel" -> "public" ("public" | "private"), "Sources" -> {} (関連 claim/snapshot id), "PolicySource" -> _String

### SourceVaultRegisterSeed[topic, entries] → Association
seed entries を seeds/<topic>-seed.json に保存(bootstrap 用)。seed は compiled が無い時の fallback。

## Stage 1.5/2/4: Ingest

### SourceVaultIngest[source, opts]
外部 source を登録し raw snapshot を PrivateVault に保存。Local file path はコンテンツアドレス raw ストアへ transactional copy、HTTPS/HTTP URL は URLDownload で fetch + hash + metadata 保存、arXiv:NNNN.NNNNN[vN] は arxiv.org/pdf/... に canonicalize して URL ingest。
→ Association(Status: Ingested/AlreadyCurrent/RebuiltMetadata/Queued 等)
Options:
Topic -> Automatic (Automatic | _String)
TrustLevel -> Automatic (Automatic | "OfficialAPI" | "OfficialDocs" | "PublicWeb" | "LocalFile")
PrivacyLabel -> Automatic (Automatic | _Real)
PinVersion -> Automatic (True | False | Automatic)
Asynchronous -> False (True で LLMGraphDAGCreate 経由でジョブ投入し JobId 即時 return。LLMGraphDAGCreate (claudecode.wl) 必須)
EnsureUUID -> Automatic (Automatic/True で .nb なら hash 計算前に SourceVaultEnsureNotebookUUID を呼び UUID 埋込。.nb 以外と巨大ファイル(>$SourceVaultMaxFileSizeMB)はスキップ)

### SourceVaultIngestWait[ingestResult, timeoutSec] → Association
非同期 ingest の完了を待つ。sync 完了済みなら即座 return。Status: Queued なら SourceId の snapshot 増加を polling。timeoutSec(既定 60)秒超過で Status: Timeout。第一引数は SourceVaultIngest の結果 Association または SourceId String。

## Stage 4B: PDF page 抽出

### SourceVaultExtractPages[snapshot, pages, opts]
snapshot の指定 page を抽出し cache に保存。snapshot は SnapshotId または SourceId(latest snapshot 使用)。pages は Integer / List of Integer / All。各 page を parsed/by-snap/<id>/pages/NNNN.txt に cache し page-hashes.json に SHA-256 を保存。cache hit 時は Import しない。抽出結果が空 or 5文字未満なら $SourceVaultOCRHook を呼ぶ。
→ <|"Status", "SnapshotId", "Pages" -> {n: text, ...}, "Hashes" -> <|...|>, "CachedFrom" -> "Disk"|"Fresh"|"Mixed", "OCRCalled" -> True|False|>
Options: Force -> False (cache 無視して再抽出), "ForceOCR" -> False (この呼出しだけ OCR 強制、スキャン判定スキップ。hook 設定必須。True 時は Force も自動適用)

### $SourceVaultOCRHook
型: None | Function, 初期値: None
スキャン PDF の fallback。シグネチャ: Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String。ページテキスト抽出失敗時(空 or 5文字未満)に呼ばれ、返値文字列が text として cache される。SourceVaultOCREnable 経由設定が推奨。

### $SourceVaultOCRMode
型: String, 初期値: "Auto"
OCR 発火モード。"Auto": Plaintext 抽出結果が 5文字未満の時のみ OCR。"Force": 長さに関わらず常に OCR(低品質テキスト層 PDF 対策)。SourceVaultOCREnable[..., "Mode" -> "Force"] で永続化、SourceVaultOCRDisable[] で "Auto" にリセット。

### $SourceVaultOCRVerbose
型: True|False, 初期値: False
OCR 実行時の進捗 Print 制御。True で rasterization/API 呼出/レスポンス長等を Print。

## Stage 4C: OCR バックエンド

### SourceVaultOCREnable[backend, opts]
OCR hook を有効化。backend(既定 "ClaudeVision"): "ClaudeVision" | "TextRecognize" | "Custom"。"ClaudeVision" は ClaudeCode`ClaudeQueryBg 経由で Claude API に page 画像を送り OCR(大きい page は自動で上下分割 30px overlap し 2 回 OCR マージ)。"TextRecognize" は組込 TextRecognize。"Custom" はユーザ Function をそのまま $SourceVaultOCRHook に設定。
→ <|"Status" -> "Enabled", "Backend" -> _String, "Mode" -> _String, "Options" -> _Association|>
Options(backend別): "DPI" -> 300/150, "SplitHalves" -> True, "Timeout" -> 180, "Prompt" -> Automatic, "Language" -> "Japanese", "Hook" -> Function[req, text]
共通 Option: "Mode" -> "Auto" ("Auto" | "Force")

### SourceVaultOCRDisable[] → Association
OCR hook を無効化($SourceVaultOCRHook = None)。

### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定。Backend: Disabled/ClaudeVision/TextRecognize/Custom。HookSet: True なら Function 設定済み。

## Stage 5/6a: Claim 抽出

### SourceVaultExtract[sourceSpan, schema, opts]
sourceSpan の page text を LLM に渡して claim を抽出。sourceSpan は SourceVaultSpan[...] の結果または SnapshotId/SourceId String。schema は登録済み schema 名(文字列)または Association(インライン定義)。
→ <|"Claims" -> {...}, "Count" -> _Integer (実納数), "ExtractedCount" -> _Integer, "DedupSkipped" -> _Integer, "AccessDecisions" -> <|"Send" -> _, "Persist" -> _|>, "ValidationStatus", "SchemaName", "ExtractedAt" -> DateObject, "Errors" -> {...}|>
Deny時: <|"Status" -> "DeniedByNBAccess", "Reason", "AccessDecisions"|>
RequireApproval時: <|"Status" -> "RequiresApproval", "Reason", "AccessDecisions"|>
Options: "Topic" -> _String (既定 schema 名), "ModelIntent" -> "summary"|"extraction"|"math-extraction-heavy", "StoreClaims" -> True, "Dedup" -> True (by-source ファイル単位で ContentHash 照合), "AuthorizationCheck" -> True (2段階 NBAuthorize: sendDecision → 抽出 → persistDecision), "Validation" -> "None"|"Required", MaxCharacters -> 8000, Timeout -> 180

### SourceVaultRegisterSchema[name, definition] → Association
抽出 schema をグローバルに登録。definition は <|"Description" -> _String, "Fields" -> {<|"Name", "Type", "Required", "Description"|>, ...}, "OutputShape" -> "List"|"Single", "PromptTemplate" -> Automatic|_String|>。ビルトイン: "FreeText" / "NumericFacts" / "DefinitionList"。

### SourceVaultClaim[claimId] → Association | Missing["NotFound"]
指定 claim の Association を返す。

### SourceVaultClaimsForSource[sourceIdOrSnapshotId] → List
指定 source に紐づく claim リスト。

### SourceVaultClaimsForTopic[topic] → List
指定 topic に紐づく claim リスト。

### SourceVaultListSchemas[] → List
登録済み schema 名リスト。

### SourceVaultGetSchema[name] → Association
登録済み schema 定義。

### SourceVaultClaimStoreStatus[] → Association
ClaimStore 状態(debug)。ClaimsDir/MasterPath/MasterExists/MasterClaims(行数)/TopicFiles/SourceFiles。

### SourceVaultClaimStoreCompact[opts]
master + by-topic + by-source を全読みし ContentHash で dedup して全インデックスを rebuild。atomic rewrite。dedup は master 先頭行を残す(最古を保存)。
→ <|"Status" -> "OK"|"Failed", "BeforeCount", "AfterCount", "Removed", "BackupPaths" -> {...}, "DryRun"|>
Options: "Backup" -> True (.bak.<timestamp>), "DryRun" -> False (True で統計のみ)

## Stage 6c: Evidence Bundle

### SourceVaultBundleCreate[name, deps, opts]
generated artifact の依存を evidence bundle として保存。name は表示名(BundleId は自動生成)。deps は <|"GeneratedFiles" -> {...}, "Sources" -> {<|"SourceId", "SnapshotId"|>, ...}, "SourceSpans" -> {...}, "Claims" -> {...}, "Generator" -> <|"Tool", "WorkflowId", "ModelIntent", "ResolvedModel"|>|>。
→ <|"Status" -> "OK"|"Failed", "BundleId", "Path"|>
Options: "Kind" -> "SimulationExample"|"LaTeXExport"|"DocumentGeneration"|"CodeGeneration"|"Notebook"|_String

### SourceVaultBundleGet[bundleId] → Association | Missing["NotFound"]
指定 bundle を読み込み。

### SourceVaultBundleList[] → List
全 bundle id リスト。

### SourceVaultBundleStatus[bundleId]
bundle の現在の Status を計算。参照する snapshot の LifecycleStatus を集約。手動 Invalidate 済みなら "Invalidated"。
→ <|"Status" -> "Current"|"Stale"|"NeedsReview"|"Invalidated", "Reason", "AffectedSnapshots" -> {...}, "AffectedClaims" -> {...}|>

### SourceVaultBundleInvalidate[bundleId, reason] → Association
bundle を手動で invalidate。reason は記録され後で BundleStatus に返る。

### SourceVaultBundleDelete[bundleId] → Association
bundle ファイルを削除(debug)。

## Stage 8: vN diff + snapshot lifecycle

### SourceVaultDiffVersions[v1Snap, v2Snap]
二つの snapshot の page hash 集合を比較。各 page-hashes.json を読みページ番号ごとに hash 比較。
→ <|"Status", "V1Snap", "V2Snap", "AddedPages" -> {...}, "RemovedPages" -> {...}, "ChangedPages" -> {...}, "UnchangedPages" -> {...}|>

### SourceVaultMarkSnapshotStale[snapshotId, reason] → Association
snapshot meta の LifecycleStatus を "Stale" に更新し events/source-events.jsonl に VersionedUpdate event を記録。その snapshot を参照する Bundle が自動で "Stale" を返すようになる。

### SourceVaultMarkSnapshotInvalidated[snapshotId, reason] → Association
LifecycleStatus を "Invalidated" に更新。Retraction 等、参照を不可にしたい場合に使う。

### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason]
高レベル refresh。diff 計算 → oldSnap を "Stale" + SupersededBy=newSnap → event 記録。
→ <|"Status", "Diff" -> _Association, "Event" -> _Association|>

### SourceVaultBundlesForSnapshot[snapshotId] → List
指定 snapshot を参照する全 bundle id リスト(Sources[].SnapshotId 一致)。

### SourceVaultSourceEvents[opts] → List
events/source-events.jsonl の全 event リスト。
Options: "SourceId" -> _String, "SnapshotId" -> _String, "EventType" -> _String (VersionedUpdate/Retraction/SourceDeletion/SchemaChange)

### SourceVaultSourceEventAppend[event] → Association
event Association を source-events.jsonl に append。EventType/SourceId/Reason 必須。OldSnapshotId/NewSnapshotId/Metadata 任意。EventId と Timestamp は自動生成。

## モデルレジストリ管理

### $SourceVaultModelEndpoints
型: Association
provider 名からモデル一覧エンドポイント設定への Association。ユーザ上書き可。各値は <|"ModelsURL" -> _, "Kind" -> "Cloud"|"Local", "AuthProvider" -> _|>。

### SourceVaultModelEndpointStatus[] → Association
各 provider エンドポイントの到達性(オフライン検知)。短いタイムアウトで probe、401/403 でもサーバ到達=Online とみなす。
→ <|"Status", "Endpoints" -> <|provider -> <|"Status" -> "Online"|"Offline", ...|>|>|>

### SourceVaultDetectLocalModels[opts] → Association
ローカル LLM サーバ(LM Studio 等 OpenAI 互換 /v1/models)からモデル一覧を推測。API キー不要。キー保護有効時は NBAccess`NBGetLocalLLMAPIKey 経由で自動解決。
→ <|"Status" -> "OK"|"Offline", "Provider", "Endpoint", "Models" -> {_String..}|>
Options: Provider -> "lmstudio", Endpoint -> Automatic (ClaudeCode`$ClaudePrivateModel の url を優先)

### SourceVaultSetModel[provider, intent, modelId, opts]
compiled model registry に手動で 1 エントリを書き込む(API キー不要)。Source -> "manual"。同 (provider, intent) の既存を置換。
→ Association
Options: Channel -> "public", Class -> Automatic (=推論), Capabilities -> Automatic, ("ContextLength" -> n で永続化)
例: SourceVaultSetModel["anthropic", "heavy", "claude-opus-4-8"]

### SourceVaultClearModelRegistry[opts] → Association
compiled model registry を削除し次回アクセス時に seed(コード内最新 iModelSeedEntries)から再構築。古い seed コピーが残り古い ID を返し続ける時の復旧用。seed 自体は消さない。
Options: Channel -> "public"

### SourceVaultSetModelIntent[variable, spec] → Association
SourceVault が選択するモデルの intent 割当てを変更。variable: "$ClaudeModel" | "$ClaudeDocModel" | "$ClaudePrivateModel" | "$ClaudeFallbackModels"。spec: {provider, intent}(FallbackModels は {{provider,intent},...})。設定後 SourceVaultAssignClaudeModels[] で実変数に反映。$NBApprovalHeads 登録、ClaudeEval 経由では Hold -> Approve 必要。
例: SourceVaultSetModelIntent["$ClaudeModel", {"anthropic", "heavy"}]

### SourceVaultModelIntentMap[] → Association
変数名 -> intent spec のマッピングを返す読取り公開関数。NBAccess`NBSyncClaudeModelVars が読む。
例: <|"$ClaudeModel" -> {"claudecode","code-heavy"}, ...|>

### SourceVaultAssignClaudeModels[opts] → Association
intent マッピングと信頼ローカルサーバ(NBAccess`NBResolveLocalServer)から $ClaudeModel / $ClaudeDocModel / $ClaudePrivateModel / $ClaudeFallbackModels を設定。SourceVault ロード時に自動実行。
Options: Verbose -> False

### SourceVaultRefreshModelRegistry[opts] → Association
クラウド(anthropic/openai)とローカル(LM Studio)のエンドポイントからモデル一覧を取得し compiled model registry を更新。API キーは NBAccess`NBGetAPIKey 経由、無い provider はスキップ。取得分は Source -> "auto-fetch"、既存 seed/manual は温存マージ。
→ <|"Status", "FetchedCount", "RegistryTotal", "PerProvider", "RegistryPath"|>
Options: Providers -> All, IncludeCloud -> Automatic, DryRun -> False

## Stage 3: Context / Span / Attach

### SourceVaultSpan[snapshotOrRef, opts] → Association
SourceSpan association を作る。snapshotOrRef は SnapshotId/SourceRef/file path。
Options: "Pages" -> {1,3,5}|All|_Integer, "Role" -> "ReferenceContext"|"Evidence"|"ExtractionInput", "Purpose" -> "LaTeXMathFormatting"|_String

### SourceVaultContext[sourceSpan, opts] → Association
sourceSpan の plaintext を取り出し NBAuthorize 判定付きで LLM 文脈として返す。RequireApproval も block。
Options: MaxCharacters, "Sink", "Purpose"

### SourceVaultContextAssemble[sourceSpans, opts] → Association
複数 span を 1 つの prompt context に組み立てる。
Options: "Purpose" -> _String, MaxCharacters -> _Integer, "Ordering" -> "PageOrder"|"Citation"|"GivenOrder", "Separators" -> "ByPage"|"BySource"|None, "IncludeCitations" -> True|False, "Sink" -> _Association

### SourceVaultAttach[nb, source, opts] → Association
notebook に source を attach し TaggingRules に sourceVaultRefs を記録。旧 ClaudeAttach のバックエンド代わり。

### SourceVaultAttachToCell[nb, cellIdx, sourceSpan, opts] → Association
cell に SourceSpan を attach。

### SourceVaultGetAttachments[nb] → List
notebook に attach された source 一覧。

### SourceVaultGetCellSources[nb, cellIdx] → List
cell に紐づく SourceSpan リスト。旧形式(refSources)を read-only normalization して新形式で返す。

### SourceVaultEnsureRegistered[ref] → Association
旧 refSources 形式(あるいは file path)を SourceSpan 形式に normalize。必要に応じ ingest。

## Materialization / Path

### SourceVaultMaterializeForSink[sourceRef, sinkSpec, opts] → Association
source を cloud-accessible mirror へ materialize。内部で必ず NBAuthorize を呼ぶ。

### SourceVaultResolvePath[ref, opts] → String
source/snapshot の物理 path。"Tier" -> "PrivateVault" は local kernel / maintenance 専用。cloud LLM 向けは SourceVaultMaterializeForSink を使う。

### SourceVaultObjectSpec[ref, opts] → Association
source/snapshot を NBAuthorize が受け取れる object spec association に変換。

### SourceVaultSetSnapshotPrivacyLevel[snapshotId, level] → Association
snapshot record の PrivacyLevel を明示上書き。NBAccess`NBSetSnapshotPrivacyLevel の委譲先。承認ゲートは NBAccess 側 $NBApprovalHeads 登録で発火。Notebook snapshot と PDF/URL snapshot 両系統をファイル存在で判別。level は 0.0-1.0 に clip。既存値より低い値指定時は "Lowered" -> True。
→ <|"Status", "SnapshotId", "OldPrivacyLevel", "NewPrivacyLevel", "Lowered", "SnapshotKind"|>

## Ingest オプションシンボル
### Topic / PinVersion / TrustLevel / PrivacyLabel
SourceVaultIngest のオプションシンボル。
### MaxCharacters
SourceVaultContext / SourceVaultContextAssemble のオプションシンボル。

## ClaudeAttach 統合 (P1)

### SourceVaultClaudeAttachIntegrationEnable[] → Association
ClaudeAttach 呼出時に SourceVault への side-channel ingest を行う hook を有効化。既に有効なら noop。元の DownValue は保持、Disable で復元。前提: claudecode.wl (ClaudeCode`ClaudeAttach) ロード済み。

### SourceVaultClaudeAttachIntegrationDisable[] → Association
hook を外し ClaudeAttach を元の DownValue に復元。

### SourceVaultClaudeAttachIntegrationStatus[] → Association
hook 状態。Keys: Enabled, OriginalSaved, OriginalDVCount, HookTarget。

### SourceVaultGetClaudeAttachRefs[nb] / SourceVaultGetClaudeAttachRefs[] → List
notebook に紐づく ClaudeAttach side-channel ingest 記録の flat list。引数なしで EvaluationNotebook[]。各 entry: OriginalPathOrURL/ExpandedPath/SnapshotId/SourceId/ContentHash/IngestStatus/AttachedAt。

## ClaudeAttachments 統合 (P2)

### SourceVaultClaudeAttachmentsIntegrationEnable[] → Association
ClaudeAttachments[] の返値を List of paths から Association list に拡張する hook を有効化。各 Association に SnapshotId/SourceId/ContentHash/IngestStatus が join。前提: claudecode.wl (ClaudeCode`ClaudeAttachments) ロード済み。

### SourceVaultClaudeAttachmentsIntegrationDisable[] → Association
hook を外し ClaudeAttachments を元の DownValue に復元。

### SourceVaultClaudeAttachmentsIntegrationStatus[] → Association
現在の hook 状態。

## WorkerPrompt 統合 (P3)

### SourceVaultWorkerPromptIntegrationEnable[] → Association
ClaudeOrchestrator の A5 hook に SourceVault context 注入関数を登録。前提: ClaudeOrchestrator.wl に A5 hook 5 行追加済み。トリガー: task["SourceSpans"](明示)+ ClaudeAttach 履歴(自動検出)。

### SourceVaultWorkerPromptIntegrationDisable[] → Association
A5 hook の定義をクリア。

### SourceVaultWorkerPromptIntegrationStatus[] → Association
現在の A5 hook 状態。

### $SourceVaultWorkerPromptAutoDetect
型: True|False, 初期値: True
A5 hook 有効時の自動検出 ON/OFF。True で ClaudeAttach 履歴から SnapshotId を自動検出して注入。False で task["SourceSpans"] 明示のみ。

## ParseProposal 統合 (P4)

### SourceVaultParseProposalIntegrationEnable[] → Association
ClaudeOrchestrator の A6 hook に parseProposal post-processing 関数を登録。LLM 応答内の <source>snap-...</source> / <source>src-...</source> XML タグを抽出し parseProposal 返値に "SourceVaultRefs" キーを追加。前提: ClaudeOrchestrator.wl に iApplyA6Hook + A6 hook 呈入済み。

### SourceVaultParseProposalIntegrationDisable[] → Association
A6 hook 定義をクリア、iApplyA6Hook は no-op に戻る。

### SourceVaultParseProposalIntegrationStatus[] → Association
現在の A6 hook 状態。

## Stage 9: Notebook 管理

### SourceVaultRegisterNotebook[path]
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

### SourceVaultExtractNotebookHeader[path]
notebook 先頭 Input セルから Header Association を safe parse。HoldComplete + whitelist で RunProcess/Get/Import 等の危険式を拒否。
→ <|"ParseStatus" -> "OK"|"MissingHeader"|"UnsafeExpression", "Keywords", "Deadline", "NextReview", "Status"|>

### SourceVaultExtractNotebookTodos[path] → List
notebook 内の TodoItem スタイルセルを列挙。Status は 3 値(Open/Done/Pass)。判定優先順位: TaggingRules > FontVariations StrikeThrough + FontColor > Default。StrikeThrough なし→Open、+緑→Done、+灰→Pass、+その他→Done。
→ {<|"Text", "Status", "StatusSource", "StrikeThrough" -> _Bool|>, ...}

### SourceVaultFindNotebooks[opts] → List
index 済み notebook を deterministic 検索(LLM 不要)。
Options:
"OpenTodos" -> True|False
"NextReview" -> "Today"|"Overdue"|"ThisWeek"|"DueSoon"|<|"From", "To"|> ("Today" は厳密に今日のみ、"ThisWeek"/"DueSoon" は今日+週内+期限切れ含む)
"Deadline" -> "Today"|"Overdue"|"ThisWeek"|"DueSoon"|<|"From", "To"|>
"Keywords" -> {_String,...}|_String (部分一致、対象: Header.Keywords+Header.Title+FileBaseName+親フォルダ名、複数は OR)
"Title" -> _String|{_String,...} ("Keywords" と同検索、エイリアス)
"Status" -> "Todo"|"Done"|_String
"Scope" -> "Today" (NextReview==今日 | Deadline==今日 | Path に YYYYMMDD 形式で今日含む の OR)
"Format" -> False (True で SourceVaultFormatNotebookList の Grid で返す)
→ {<|NotebookRef, OriginalPath, Title, Header, ReviewState, ...|>, ...}

### SourceVaultNotebookLint[record] → List
notebook record(または path)に lint チェック。検出: MissingHeader/UnsafeHeaderExpression/HeaderDeadlineMalformed/HeaderNextReviewMalformed/HeaderStatusTodoButNoOpenTodos/HeaderStatusDoneButOpenTodosExist/DeadlinePast/NextReviewPast/TodoCellStatusHeuristicOnly。
→ {"LintName1", ...}

## Stage 9 P1: TaggingRules / SemanticHash

### SourceVaultExtractNotebookTaggingRules[path]
notebook 全体と各 TodoItem cell の TaggingRules を取得。Import[path, "Notebook"] の Notebook 式から抽出 + NotebookImport[path, style -> "Cell"] で各 TodoItem cell から抽出。
→ <|"Status" -> "OK"|"Failed", "Path", "NotebookTaggingRules" -> _Association (無ければ <||>), "CellTaggingRules" -> {<|"Index" -> _Integer, "CellStyle" -> _String, "TaggingRules" -> _Association|>, ...}|>

### SourceVaultNotebookSemanticHash[path]
notebook の意味的内容のみを対象にしたハッシュ。表示メタデータ(ExpressionUUID/CellChangeTimes/CellLabel/FontFamily 等)とウィンドウ設定(WindowSize/WindowMargins/FrontEndVersion 等)を除外し、content/style/TaggingRules/FontVariations/FontColor/Background だけをハッシュ対象とする。formatting のみの変更で Stale 化誤判定を防ぐ。Import[path, "Notebook"] + Hash[normalizedExpr, "SHA256", "HexString"]。
→ <|"Status" -> "OK"|"Failed", "Path", "SemanticHash" -> _String|>

## Stage 9 P1: Summary lifecycle

### SourceVaultRegisterNotebookSummary[path, summary, opts]
notebook の summary artifact を登録。現在の snapshot (SnapshotId + SemanticHash) と紐づけて保存し後日 stale 判定可能。
→ <|"Status" -> "OK"|"Failed", "SummaryId", "NotebookRef", ...|>
Options: "SummaryFormat" -> "text" ("text" | "markdown"), "GeneratedBy" -> "manual"

### SourceVaultGetNotebookSummary[path]
notebook に紐づく summary record を取得。未登録なら "Status" -> "Missing"。
→ <|"Status" -> "OK"|"Missing"|"Failed", "Summary", "SummaryFormat", "BasedOnSnapshot", "BasedOnSemanticHash", "GeneratedBy", "CreatedAt"|>

### SourceVaultNotebookSummaryStatus[path]
summary artifact の lifecycle ステータス判定。Missing(未存在)/Current(BasedOnSnapshot が現在の snapshot と一致)/StaleFormattingOnly(SemanticHash 一致、formatting のみ変更)/Stale(SemanticHash 変化、再生成推奨)。
→ <|"Status" -> _String, "Reason" -> _String, "CurrentSnapshot", "SummaryBasedOnSnapshot" -> _String|_Missing|>

### SourceVaultNotebookSummary[path, opts]
notebook 内容を LLM で要約し Summary artifact として保存。内部で SourceVaultRegisterNotebookSummary を呼ぶため lifecycle 管理は自動。デフォルト PrivacyLevel -> 1.0(ローカル LM 経由、内容を API に送らない)。
→ Current+ForceRefresh無し時は既存 record、生成成功時は Register と同形、Inconsistent 時 <|"Status" -> "Inconsistent", "Reason", ...|>、失敗時 <|"Status" -> "Failed", "Reason", ...|>
Options: "ForceRefresh" -> False, "MaxLength" -> 500, "Language" -> Automatic (Automatic|"Japanese"|"English"), "Model" -> Automatic ({"provider","model"}), "PrivacyLevel" -> 1.0 (0.0 API許可 〜 1.0 ローカルのみ), "FallbackToCloud" -> "Ask" ("Ask"|"Allow"|"Deny")

## Stage 9 P1: Todo 書き込み

### SourceVaultMarkTodo[path, target, newStatus, opts]
notebook 内の Todo cell の Status を変更。NBAccess の NBWriteTodoStatus への薄いラッパー。target: Integer(1-based Todo Index)/String(TodoId)/Association(<|"Index" -> n, "Text" -> "..."|>)。newStatus: "Open"/"Done"/"Pass"。Cell options(FontVariations StrikeThrough + FontColor 緑/灰)と Cell TaggingRules(<|"SourceVault" -> <|"TodoStatus" -> newStatus|>|>)を変更。
→ DryRun: <|"Status" -> "DryRunOK", "Target", "MatchedTodo", "OldStatus", "NewStatus", "CellPath" -> {_Integer...}, "Before" -> HoldComplete[...], "After" -> HoldComplete[...]|>
→ 実行: <|"Status" -> "OK"|"Failed", "Target", "MatchedTodo", "OldStatus", "NewStatus", "ReindexResult" -> _Association|Missing["NotRequested"]|>
Options: "DryRun" -> True (True は preview のみ、安全側), "AutoReindex" -> True (編集成功後 SourceVaultIndexNotebook 自動呼出、実行時のみ), "AccessSpec" -> <|"AccessLevel" -> 0.7, ...|>

## Stage 9 P1: スケジュール / 一覧表示

### SourceVaultUpcomingSchedule[opts]
「今日から N 日以内」に Deadline/NextReview がある notebook の一覧を Dataset で返す。概要もキャッシュから取込(必要時自動再生成)。日付は yyyy/mm/dd、期限切れは赤、今日/明日は青。
→ Dataset[行={Deadline, NextReview, Title (Open button), Dir (Open button), OpenTodos, Status, Privacy}]
Options: "Scope" -> dir|_String (default $onWork または $packageDirectory), "Period" -> Quantity[7,"Days"], "IncludeOverdue" -> True, "Recursive" -> True, "Refresh" -> "Never" ("Never"|"IfStale"|"Force"), "FallbackToCloud" -> "Ask" ("Ask"|"Allow"|"Deny"), "StatusFilter" -> {"Todo"} ({"Todo"}|{"Todo","Done","Pass"}|All), "UseCache" -> True

### SourceVaultFormatNotebookList[records, opts]
notebook record の List をスケジュール表と同じ表形式で Grid 表示。SourceVaultFindNotebooks の返値、IndexNotebook の OK record の List、Path/Header を持つ任意の Association List を受け付ける。
→ Grid (行={Deadline, NextReview, Title, Dir, OpenTodos, Status, Summary, Publishable})
Options: "Refresh" -> "Never" ("Never"|"IfStale"|"Force"), "FallbackToCloud" -> "Deny" ("Ask"|"Allow"|"Deny"), "UseCache" -> True

### SourceVaultRefreshAllSummaries[opts]
Scope 配下全 notebook の概要を一括再生成。
→ <|"Status" -> "OK", "Scope", "TotalFiles", "Refreshed", "Cached", "Inconsistent", "Failed", "Details"|>
Options: "Scope" -> dir|_String (default $onWork), "Recursive" -> True, "ForceRefresh" -> False, "FallbackToCloud" -> "Deny" ("Ask"|"Allow"|"Deny"), "OpenTodosOnly" -> False (True で OpenTodoCount>0 のみ), "Model" -> Automatic, "Progress" -> False, "Limit" -> Infinity

## Sync / Relink

### SourceVaultSelectSources[opts] → Association
同期対象となる source を選定。Scope 配下の .nb をスキャンし source descriptor 化。
→ <|"Status", "Scope", "Count", "Sources" -> {_Association..}|>
Options: Scope / Recursive / Kind / ExcludePatterns

### SourceVaultSyncPlan[opts] → Association
各 source の鮮度を判定し同期計画を返す(dry-run、副作用なし)。鮮度トークン(ローカルは mtime)を現 snapshot 記録と比較し Fresh/Stale/Missing/NeverIndexed に分類。
→ <|"Status", "Total", "StaleCount", "Plan" -> _Dataset, ...|>
Options: Scope / Recursive / Kind / ExcludePatterns

### SourceVaultSync[opts] → Association
SyncPlan に従い Stale な source を再 index(クローラー骨格)。ローカル notebook は SourceVaultIndexNotebook で再 index。PrivacyLevel は単調(自動で下げない): 再 index で下がった場合は旧値に引上げ警告記録。sync/sync-history.jsonl に記録、sync/last-sync.json 更新。
→ <|"Status", "SyncId", "Refreshed", "Skipped", "Failed", "PrivacyWarnings"|>
Options: Scope / Recursive / Kind / DryRun / ForceAll / RefreshSummary / FallbackToCloud (既定 "Deny")

### SourceVaultSyncStatus[] → Association
直近の sync 実行状態(sync/last-sync.json)。未実行なら <|"Status" -> "NoSyncYet"|>。

### SourceVaultRelinkSources[opts] → Association
OriginalPath が存在しなくなった(移動された)notebook source を検出し、Scope 配下から移動先を探して再リンク。照合順: (1) 埋込 UUID(TaggingRules の SourceVault > NotebookUUID)、(2) 内容ハッシュ(RawContentHash 完全一致)、(3) ファイル名一意一致。移動判定はシンボリックパス解決ベース。UUID/ContentHash 一致は自動適用、NameOnly は ApplyNameOnly -> True 時のみ。
→ <|"Status", "Linked", "Relinked" -> {..}, "RelinkedCount", "ByMethod" -> <|"UUID"/"ContentHash"/"NameOnly" -> _|>, "Unresolved" -> {..}, "DryRun"|>
Options: Scope / Recursive / DryRun (既定 True) / ApplyNameOnly (既定 False) / DeleteStale (既定 False) / ExcludePatterns

## Notebook UUID

### SourceVaultNotebookUUID[path] → String | Missing[]
notebook に埋込まれた UUID(TaggingRules > SourceVault > NotebookUUID)。未設定なら Missing[]。読取りのみ。

### SourceVaultEnsureNotebookUUID[path, opts] → Association
notebook に UUID が無ければ生成して埋込む。UUID は notebook 自身の TaggingRules に保存され、ファイル名変更・内容編集をまたいで安定(SourceVaultRelinkSources の最も信頼できる照合キー)。
→ <|"Status", "Path", "UUID", "Created" -> True|False|>
Options: Force -> False (True で既存 UUID も再生成)

### SourceVaultEnsureNotebookUUIDFolder[dir, opts] → Association
folder 配下の .nb 全てに UUID を付与。
→ <|"Status", "TotalFiles", "Created", "AlreadyPresent", "Skipped", "Failed"|>
Options: Recursive -> True / ExcludePatterns / MaxFileSizeMB (既定 $SourceVaultMaxFileSizeMB)

## Phase 2a: DirectiveRepository

ClaudeDirectives` に lazy Needs で依存(BeginPackage には追加しない)。

### SourceVaultRegisterDirectiveRepository[root] → Association
Claude Directives リポジトリ(ディレクトリ)を DirectiveRepository source として登録。RepoId は root path から決定的に導出。
→ <|"Status", "RepoId", "Root", "Path", "Registration"|>

### SourceVaultIndexDirectiveRepository[root] → Association
ClaudeDirectives` 経由でファイル inventory と manifest hash を計算し DirectiveRepository snapshot record を書く。必要なら自動登録。
→ <|"Status", "RepoId", "SnapshotId", "ManifestHash", "FileCount", "Path", "Snapshot"|>

### SourceVaultDirectiveRepositoryStatus[root] → Association
リポジトリの登録有無、snapshot 数、最新 snapshot の manifest hash がディスク上と一致するかを報告。Status: "NotRegistered"|"RegisteredNotIndexed"|"UpToDate"|"Stale"。

### SourceVaultCurrentDirectiveSnapshot[root] → Association
最新の DirectiveRepository snapshot record。無ければ Status -> "NoSnapshot"。

### SourceVaultDiffDirectiveSnapshots[old, new] → Association
二つの DirectiveRepository snapshot record(または snapshot file paths)を RelativePath/ContentHash で比較。
→ <|"Status", "Added", "Removed", "Changed", "UnchangedCount", "ManifestHashChanged"|>

## Phase 2b: HarnessMaterialization

### SourceVaultRegisterHarnessMaterialization[target, files, meta] → Association
materialize した harness を HarnessMaterialization bundle として登録。target は "Codex" or "ClaudeCLI"、files は生成ファイルパスのリスト、meta は HarnessMode/DirectiveRoot/DirectiveRepositorySnapshotId/DirectiveRepositoryManifestHash/RuntimeEnvironmentHash/PermissionProfileHash/Generator を供給。SourceVaultBundleGet で読める。
→ <|"Status", "BundleId", "Path", "Bundle"|>

### SourceVaultDirectiveSnapshotStaleQ[bundle] → Association
HarnessMaterialization bundle が built された canonical Claude Directives snapshot が stale かを bundle の DirectiveRepositoryManifestHash と現リポジトリ hash の比較で報告。stale なら harness 再生成が必要。
→ <|"Stale", "Reason", "RecordedManifestHash", "CurrentManifestHash"|>

### SourceVaultHarnessRuntimeEnvironmentChangedQ[bundle, currentEnv] → Association
HarnessMaterialization bundle の runtime environment(permission profile/temp project path/attachments)が変化したかを報告。currentEnv は事前計算済み PermissionProfileHash/RuntimeEnvironmentHash、または生 PermissionProfile/RuntimeEnvironment association を渡せる。runtime-environment 変化は config.toml 再生成を要するが canonical snapshot を stale にはしない。