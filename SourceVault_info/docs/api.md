# SourceVault API リファレンス

パッケージ: `SourceVault` (依存: [NBAccess](https://github.com/transreal/NBAccess))
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault.wl"]]`

## ブートストラップ / 設定

### $SourceVaultVersion
型: String
パッケージバージョン文字列。

### $SourceVaultRoots
型: Association
物理 root ディレクトリマッピング。Keys: `"PrivateVault"` | `"CloudMirror"` | `"Tmp"` | `"AttachmentMirror"` | `"ExternalOwned"`。PrivateVault が authoritative storage。CloudMirror / AttachmentMirror は materialized projection のみ。

### $SourceVaultSeedModelRegistry
型: Association
bootstrap 時の fallback model registry。compiled registry が無い場合の災害復旧用。LLM が自動更新しない。

### SourceVaultInitialize[opts]
物理 root を生成して初期化する。PrivateVault と Tmp は必須。作成済みなら noop。
→ Association
Options: `"Roots"` -> `$SourceVaultRoots` (override), `"Force"` -> False (True で再初期化)

### SourceVaultStatus[sourceRef]
指定 source / snapshot / ファイルの概要を返す。引数なし (`SourceVaultStatus[]`) で vault 全体の概要。
→ Association

### SourceVaultList[] → List
vault 内の全 source ID リスト。

### SourceVaultSnapshots[sourceRef] → List
指定 source に限定した snapshot ID リスト。

## ソース一覧 / 横断検索

### SourceVaultSources[query, opts]
ingest 済み全ソースをメタデータ付き表で表示する。arXiv は論文タイトル・著者・出版日を arXiv API から自動取得して meta にキャッシュ。Web ページは HTML `<title>`、ローカルファイルはファイル名を Title に出す。各行に URL リンク (▶ URL) と ingest 済みファイルを開くリンク (▶ 開く) が付く。query は Title/Authors/Summary/URL/Id 等の部分一致 (`""` または省略で全件)。
→ Grid | Dataset | List
Options: `"Limit"` -> Automatic|n, `"Kind"` -> All|`"arxiv"`|`"web"`|`"local"`, `"FetchMetadata"` -> Automatic (未取得のみ取得)|False (network なし)|True (再取得), `"Since"`/`"Until"`/`"On"` -> ingest 日での絞り込み (日付文字列 `"yyyy-mm-dd"` / Today / DateObject。`"On"` は単日、`"Since"`/`"Until"` は範囲、両端含む), `"Author"` -> 著者名の部分一致, `"Format"` -> `"Grid"` (既定)|`"Dataset"`|`"Rows"`
例: `SourceVaultSources["", "Kind" -> "arxiv", "On" -> Today]`

### SourceVaultArXiv[query, opts]
arXiv ソースだけを共通スキーマ表で表示する (`SourceVaultSources[query, "Kind" -> "arxiv", ...]` の薄ラッパ)。
→ Grid | Dataset | List
Options: `"On"`/`"Since"`/`"Until"`/`"Author"`/`"Limit"`/`"Format"` 等 (SourceVaultSources と同じ)
例: `SourceVaultArXiv["reversible", "Author" -> "Bennett"]`

### SourceVaultBackfillArXivSummaries[opts]
既存の arXiv ソースのうち Summary が未設定のものに arXiv アブストラクトを取得し `$Language` へ翻訳して付与する。cloud LLM 使用 (arXiv は公開データなので PrivacyLevel 0.0)。`$Language` が Japanese のセッションで実行すること。
→ `<|"Candidates", "Updated", "AlreadyPresent", "NoAbstract", "Failed", "Results"|>`
Options: `"Force"` -> False (True で既存 Summary も再生成), `"Model"` -> Automatic, `"Limit"` -> Automatic|n

### SourceVaultShowSourceSummary[sourceId, opts]
ingest 済みソース (arXiv / web / local) のサマリーを編集可能なノートブックで開く。保存済みのユーザー追記版があればそれを開き、無ければ Title/著者/出版/URL/要約からノートを生成する。ノート内の「このノートを保存する」ボタンを押すと `<PrivateVault>/sources/summary-notes/` に保存される。
→ なし (NotebookOpen 副作用)
Options: `"Fresh"` -> False (True で保存版を無視し record から新規生成)

### $SourceVaultSummaryNotebookStyle
型: String, 初期値: `"SourceVault default.nb"`
`SourceVaultShowSourceSummary` が開くノートの StyleDefinitions。

### SourceVaultOpenSourceFile[sourceId]
ingest 済みソースの raw ファイルを ContentHash から現 PC の vault パスを live 再算出して SystemOpen で開く。別 PC (Dropbox 同期) でも開ける。
→ なし (SystemOpen 副作用)

### SourceVaultSourceRow[sourceId] → Association
1 ソースの共通スキーマ行を返す。キー: `"Kind"`, `"Id"`, `"URI"` (sv://snapshot/sha256/<hex>), `"Title"`, `"Authors"`, `"Published"`, `"Summary"`, `"URL"`, `"File"`, `"Date"`, `"PrivacyLevel"`。

### SourceVaultSummaries[query, opts]
SourceVault が抱えるデータ全体 (ingest 済みソース + Eagle 保存済みサマリー等、登録 provider 横断) を検索し統合表で表示する。
→ Grid | Dataset | List
Options: `"Providers"` -> All|`{"sources", "eagle", ...}`, `"Limit"`, `"Kind"`, `"Since"`/`"Until"`/`"On"` -> 登録/生成日での絞り込み, `"Author"` -> 著者部分一致, `"FetchMetadata"`, `"Format"` -> `"Grid"` (既定)|`"Dataset"`|`"Rows"`

### SourceVaultRegisterSummaryProvider[name, fn]
`SourceVaultSummaries` の横断検索 provider を登録する。fn のシグネチャ: `fn[query_String, opts_Association]` → 共通スキーマ行のリスト。
→ なし

### $SourceVaultSummaryProviders
型: Association
`SourceVaultSummaries` が横断する provider の Association (name -> fn)。

## Stage 1: Lookup / Resolve

### SourceVaultLookup[topic, key, opts]
compiled registry からキーに対応する entry を返す。compiled registry に見つからなければ seed に fallback。
→ Association | Missing["NotFound"]
Options: `"Channel"` -> `"public"` (既定)|`"private"`, `"AllowSeed"` -> True (compiled 無し時 seed を使う)
topic 例: `"model-registry"`, `"mathematica-graph-options"`

### SourceVaultResolve[kind, query, opts]
compiled registry から query に match する entry を返す。複数 match 時は Availability != "Unavailable" をフィルタし Class/Freshness で sort して先頭を返す。network なし、LLM なし。
→ Association | Missing["NotFound"]
Options: `"Channel"` -> `"public"`|`"private"`, `"AllowSeed"` -> True, `"Topic"` -> String (既定 `"<kind>-registry"` を小文字化)
例: `SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]`

### ClaudeResolveModel[provider, intent] → Association | Missing["NotFound"]
`SourceVaultResolve["Model", ...]` の互換 wrapper。旧 WikiDBResolveModel の置き換えとして利用できる。
例: `ClaudeResolveModel["anthropic", "heavy"]`

## Stage 1.5 / 2: Ingest

### $SourceVaultMaxFileSizeMB
型: Real
ingest 時の最大ファイルサイズ (MB)。これを超えるファイルは EnsureUUID スキップ対象となる。

### SourceVaultIngest[source, opts]
外部 source を登録し raw snapshot を PrivateVault に保存する。source は ローカルファイルパス / HTTPS URL / arXiv ID (`arXiv:NNNN.NNNNN[vN]`) を受け付ける。arXiv ID は `arxiv.org/pdf/...` に canonicalize して URL ingest する。戻り値に content-addressed 正準 URI `"URI" -> sv://snapshot/sha256/<hex>` を含む (SourceVaultSources の行・mcp との join/参照キー)。
→ Association (`"Status"`, `"SourceId"`, `"SnapshotId"`, `"URI"`, ...)
Options:
- `Topic` -> Automatic | String
- `TrustLevel` -> Automatic | `"OfficialAPI"` | `"OfficialDocs"` | `"PublicWeb"` | `"LocalFile"`
- `PrivacyLabel` -> Automatic | Real
- `PinVersion` -> True | False | Automatic
- `Asynchronous` -> False (True 時は LLMGraphDAGCreate 経由でジョブキューに投入し JobId を即時 return。LLMGraphDAGCreate (claudecode.wl) が必要)
- `EnsureUUID` -> Automatic | True | False (`.nb` 取り込み時の UUID 自動付与。Automatic/True なら hash 計算前に SourceVaultEnsureNotebookUUID を呼び元ファイルに UUID を埋め込む。`.nb` 以外と巨大ファイル (`>$SourceVaultMaxFileSizeMB`) はスキップ。付与に失敗しても ingest は続行)

### SourceVaultIngestWait[ingestResult, timeoutSec]
非同期 ingest の完了を待つ。ingestResult が sync 完了済み (Status: Ingested/AlreadyCurrent/RebuiltMetadata) なら即座に return。Status: Queued の場合は SourceId の snapshot 増加を polling して新規 snapshot 出現で完了。第一引数は SourceVaultIngest の結果 Association または SourceId String。
→ Association
Options: timeoutSec 既定 60 秒。超過で Status: Timeout を返す。

### SourceVaultReclassifyPublicPrivacy[]
ingest 済みの公開 origin ソース (arXiv / 公開 URL) で PrivacyLevel が機密閾値 0.5 以上に誤設定されているものを本来の公開既定値 (OfficialDocs/OfficialAPI=0.0, PublicWeb=0.4) に是正する保守関数。source/snapshot 両メタを書き換える。旧版が arXiv 等の OfficialDocs を 0.6 とタグした件の一度きりの修復用。
→ `<|"Status", "Count", "Changed" -> {<|SourceId, From, To|>...}|>`

## Stage 4 Phase 4B: PDF ページ抽出

### SourceVaultExtractPages[snapshot, pages, opts]
snapshot の指定ページを抽出して cache に保存する。snapshot は SnapshotId String または SourceId String (latest snapshot を使用)。pages は Integer (単ページ) / List of Integer / All。各ページを `parsed/by-snap/<id>/pages/NNNN.txt` に cache し `page-hashes.json` に SHA-256 hash を保存する。cache hit 時は Import しない。抽出結果が空または 5 文字未満の時は `$SourceVaultOCRHook` (定義されていれば) を呼ぶ。
→ `<|"Status", "SnapshotId", "Pages" -> {n: text, ...}, "Hashes" -> <|...|>, "CachedFrom" -> "Disk"|"Fresh"|"Mixed", "OCRCalled" -> True|False|>`
Options: `Force` -> False | True (cache 無視して再抽出), `"ForceOCR"` -> False | True (この呼び出しだけ OCR を強制実行、スキャン判定をスキップ。hook が設定されている必要あり。True 時は Force -> True も自動適用される)

### $SourceVaultOCRHook
型: Function | None, 初期値: None
スキャン PDF の fallback 値。シグネチャ: `Function[<|"RawPath" -> _, "Page" -> _Integer, "SnapshotId" -> _|>] :> _String`。SourceVaultExtractPages がページテキスト抽出失敗時 (空または 5 文字未満) に呼ばれ、返値文字列が text として cache される。`SourceVaultOCREnable[...]` 経由での設定を推奨。

### $SourceVaultOCRMode
型: String, 初期値: `"Auto"`
OCR 発火モードを制御する変数。`"Auto"`: Plaintext 抽出結果が 5 文字未満の時のみ OCR を呼ぶ。`"Force"`: Plaintext の長さに関わらず常に OCR を呼ぶ (低品質テキスト層対策)。`SourceVaultOCREnable[..., "Mode" -> "Force"]` で永続化可能。`SourceVaultOCRDisable[]` で `"Auto"` にリセット。単発の強制 OCR には `SourceVaultExtractPages` の `"ForceOCR"` -> True を使う。

### $SourceVaultOCRVerbose
型: Boolean, 初期値: False
OCR 実行時の進捗 Print を制御する変数。True で rasterization / API 呼び出し / レスポンス長等の進捗を Print する。`SourceVaultOCREnable[..., "Verbose" -> True]` で有効化可能。

## Stage 4 Phase 4C: OCR バックエンド

### SourceVaultOCREnable[backend, opts]
OCR hook を有効化する。backend 既定 `"ClaudeVision"`。
→ `<|"Status" -> "Enabled", "Backend" -> _String, "Mode" -> _String, "Options" -> _Association|>`
backend:
- `"ClaudeVision"`: `ClaudeCode\`ClaudeQueryBg` 経由で Claude API にページ画像を送り OCR (PDFIndex 実証済みパターン)。大きいページは自動で上下分割 (30px overlap) して 2 回 OCR しマージ。Options: `"DPI"` -> 300, `"SplitHalves"` -> True, `"Timeout"` -> 180, `"Prompt"` -> Automatic
- `"TextRecognize"`: Mathematica 組み込み TextRecognize (Python 不要、精度準等)。Options: `"DPI"` -> 150, `"Language"` -> `"Japanese"`
- `"Custom"`: ユーザー提供 Function をそのまま `$SourceVaultOCRHook` に設定。Options: `"Hook"` -> `Function[req, text]`

共通 Options: `"Mode"` -> `"Auto"` (既定) | `"Force"`, `"Verbose"` -> False | True

### SourceVaultOCRDisable[]
OCR hook を無効化する (`$SourceVaultOCRHook = None`)。
→ Association

### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定を返す。キー: `Backend` (Disabled / ClaudeVision / TextRecognize / Custom), `HookSet` (True なら `$SourceVaultOCRHook` に Function が設定済み), `Mode`, `Verbose`。

## Stage 5: Claim 抽出

### SourceVaultExtract[sourceSpan, schema, opts]
sourceSpan のページテキストを LLM に渡して claim を抽出する。sourceSpan は `SourceVaultSpan[...]` の結果または SnapshotId/SourceId String。schema は文字列 (登録済み schema 名) または Association (インライン定義)。AuthorizationCheck -> True 時は sendDecision → context 取得 + LLM 抽出 → persistDecision の 3 フェーズで実行される。
→ `<|"Claims" -> {claim1, ...}, "Count" -> _Integer (実納数), "ExtractedCount" -> _Integer (LLM 生抽出数), "DedupSkipped" -> _Integer, "AccessDecisions" -> <|"Send" -> _, "Persist" -> _|>, "ValidationStatus" -> _, "SchemaName" -> _, "ExtractedAt" -> DateObject, "Errors" -> {...}|>`
Deny 時: `<|"Status" -> "DeniedByNBAccess", "Reason" -> _, "AccessDecisions" -> _|>`
RequireApproval 時: `<|"Status" -> "RequiresApproval", "Reason" -> _, "AccessDecisions" -> _|>`
Options:
- `"Topic"` -> String (claim の topic、既定 schema 名)
- `"ModelIntent"` -> `"summary"` | `"extraction"` | `"math-extraction-heavy"`
- `"StoreClaims"` -> True | False (既定 True)
- `"Dedup"` -> True | False (既定 True。by-source ファイル単位で ContentHash 照合)
- `"AuthorizationCheck"` -> True | False (既定 True。Stage 6d: 2 段階 NBAuthorize)
- `"Validation"` -> `"None"` | `"Required"`
- `MaxCharacters` -> 8000 (LLM に渡す context の最大文字数)
- `Timeout` -> 180

### SourceVaultRegisterSchema[name, definition]
抽出 schema をグローバルに登録する。definition は Association:
- `"Description"` -> String (LLM 向けの説明)
- `"Fields"` -> `{<|"Name" -> _, "Type" -> "Number"|"String"|"Boolean", "Required" -> True|False, "Description" -> _|>, ...}`
- `"OutputShape"` -> `"List"` | `"Single"` (複数 claim か 1 claim か)
- `"PromptTemplate"` -> Automatic | String (既定は Fields から自動生成)

ビルトイン schema: `"FreeText"` (自由抽出)、`"NumericFacts"` (数値・単位・定義・文脈)、`"DefinitionList"` (用語・定義)。
→ なし

### SourceVaultClaim[claimId] → Association | Missing["NotFound"]
指定した claim の Association を返す。

### SourceVaultClaimsForSource[sourceIdOrSnapshotId] → List
指定 source に紐づく claim リストを返す。

### SourceVaultClaimsForTopic[topic] → List
指定 topic に紐づく claim リストを返す。

### SourceVaultListSchemas[] → List
現在登録済みの schema 名リスト。

### SourceVaultGetSchema[name] → Association
登録済み schema 定義 (Association) を返す。

### SourceVaultClaimStoreStatus[] → Association
ClaimStore の状態を返す (debug 用)。キー: `ClaimsDir`, `MasterPath`, `MasterExists`, `MasterClaims` (行数), `TopicFiles`, `SourceFiles`。

### SourceVaultClaimStoreCompact[opts]
master + by-topic + by-source を全読みし ContentHash キーで dedup して全インデックスを rebuild する。atomic rewrite (tmp ファイル → rename)。dedup 記録は master の先頭行を残す (最古の結果を保存)。
→ `<|"Status" -> "OK"|"Failed", "BeforeCount" -> _Integer, "AfterCount" -> _Integer, "Removed" -> _Integer, "BackupPaths" -> {...}, "DryRun" -> _|>`
Options: `"Backup"` -> True (`.bak.<timestamp>` サフィックス), `"DryRun"` -> False (True 時は統計のみ返す)

## Stage 6c: Evidence Bundle

### SourceVaultBundleCreate[name, deps, opts]
生成 artifact の依存を evidence bundle として保存する。name は表示名 (BundleId は自動生成)。
deps は Association:
- `"GeneratedFiles"` -> `{"path/to/output1.wl", ...}`
- `"Sources"` -> `{<|"SourceId" -> _, "SnapshotId" -> _|>, ...}`
- `"SourceSpans"` -> `{...}` (optional)
- `"Claims"` -> `{"claim-...", ...}`
- `"Generator"` -> `<|"Tool" -> _, "WorkflowId" -> _, "ModelIntent" -> _, "ResolvedModel" -> _|>`
→ `<|"Status" -> "OK"|"Failed", "BundleId" -> _String, "Path" -> _String|>`
Options: `"Kind"` -> `"SimulationExample"` | `"LaTeXExport"` | `"DocumentGeneration"` | `"CodeGeneration"` | `"Notebook"` | String

### SourceVaultBundleGet[bundleId] → Association | Missing["NotFound"]
指定 bundle を読み込み返す。

### SourceVaultBundleList[] → List
全 bundle id リスト。

### SourceVaultBundleStatus[bundleId]
bundle の現在の Status を計算して返す。参照する snapshot の LifecycleStatus を集約する。手動 Invalidate 済みなら強制的に `"Invalidated"` を返す。
→ `<|"Status" -> "Current"|"Stale"|"NeedsReview"|"Invalidated", "Reason" -> _, "AffectedSnapshots" -> {...}, "AffectedClaims" -> {...}|>`

### SourceVaultBundleInvalidate[bundleId, reason]
bundle を手動で invalidate する。reason は文字列。記録され、後に SourceVaultBundleStatus で返される。
→ Association

### SourceVaultBundleDelete[bundleId]
bundle ファイルを削除する (debug 用)。
→ Association

## Stage 8: vN diff + snapshot ライフサイクル

### SourceVaultDiffVersions[v1Snap, v2Snap]
二つの snapshot の page hash 集合を比較し差分を返す。各 snapshot の page-hashes.json (Stage 4B) を読み込み、ページ番号ごとに hash を比較する。
→ `<|"Status" -> _, "V1Snap" -> _, "V2Snap" -> _, "AddedPages" -> {_Integer, ...}, "RemovedPages" -> {_Integer, ...}, "ChangedPages" -> {_Integer, ...}, "UnchangedPages" -> {_Integer, ...}|>`

### SourceVaultMarkSnapshotStale[snapshotId, reason]
snapshot meta の LifecycleStatus を `"Stale"` に更新し `events/source-events.jsonl` に VersionedUpdate event を記録する。これによりその snapshot を参照する Bundle は SourceVaultBundleStatus で自動的に `"Stale"` を返すようになる。
→ Association

### SourceVaultMarkSnapshotInvalidated[snapshotId, reason]
snapshot meta の LifecycleStatus を `"Invalidated"` に更新する。Retraction など、参照を不可にしたい場合に使う。Bundle は `"Invalidated"` を返すようになる。
→ Association

### SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason]
高レベル refresh API。(1) oldSnap と newSnap の diff を計算、(2) oldSnap の LifecycleStatus を `"Stale"` に更新 + SupersededBy を newSnap に設定、(3) event を source-events.jsonl に記録 (EventType: VersionedUpdate)。
→ `<|"Status" -> _, "Diff" -> _Association, "Event" -> _Association|>`

### SourceVaultBundlesForSnapshot[snapshotId] → List
指定 snapshot を参照する全 bundle id リスト。全 bundle ファイルを読み、Sources[].SnapshotId が一致するものを収集する。

### SourceVaultSourceEvents[opts] → List
`events/source-events.jsonl` の全 event リスト。
Options: `"SourceId"` -> String (指定 source に関連する event のみ), `"SnapshotId"` -> String (指定 snapshot に関連する event のみ), `"EventType"` -> String (`VersionedUpdate` / `Retraction` / `SourceDeletion` / `SchemaChange`)

### SourceVaultSourceEventAppend[event]
event Association を `events/source-events.jsonl` に append する。event には `EventType` / `SourceId` / `Reason` が必須。`OldSnapshotId` / `NewSnapshotId` / `Metadata` は任意。EventId と Timestamp は自動生成される。
→ Association

## Stage 6b: Compiled Registry

### SourceVaultListModels[provider] → List
指定 provider に登録された選択可能な全モデル ID リスト。SourceVaultResolve が intent 単位の最適 1 件を返すのに対し、これは catalog を列挙する (例: パレットのモデル選択)。compiled registry を優先し、無ければ seed に fallback。Availability が Unavailable のエントリは除外。

### SourceVaultModelContextLength[provider, modelId] → Integer | None
モデルに紐づく ContextLength を返す。`SourceVaultSetModel[..., "ContextLength" -> n]` で永続化された値。LM Studio 等ローカル LLM の context_length に使う。未設定なら None。

### SourceVaultModelIntegrations[provider, modelId] → List | None
モデルに紐づく LM Studio MCP の integrations リストを返す。`SourceVaultSetModel[..., "Integrations" -> {...}]` で永続化された値。LM Studio `/api/v1/chat` の integrations パラメータに使う。未設定なら None。
例: `SourceVaultSetModel["lmstudio", "local-heavy", "qwen/qwen3-coder-30b", "Integrations" -> {"mcp/exa"}, "ContextLength" -> 32000]`

### SourceVaultSetModel[provider, intent, modelId, opts]
compiled registry にモデルエントリを登録・更新する。provider / intent で既存エントリを特定し、modelId および追加メタデータを書き込む。
→ Association
Options: `"ContextLength"` -> Integer (モデルの最大コンテキスト長), `"Integrations"` -> List (LM Studio MCP integrations リスト、例: `{"mcp/exa"}`), `"Channel"` -> `"public"` (既定)|`"private"`
例: `SourceVaultSetModel["lmstudio", "local-heavy", "qwen/qwen3-coder-30b", "Integrations" -> {"mcp/exa"}, "ContextLength" -> 32000]`

### SourceVaultListRegistries[opts] → Association
登録済み registry topic と channel を返す。
Options: `"Channel"` -> `"public"` | `"private"` | All (既定 All)

### SourceVaultRegistryStatus[topic, opts]
指定 topic の registry 状態を返す。
→ `<|"Topic" -> _, "Channel" -> _, "CompiledPath" -> _, "CompiledExists" -> _Bool, "CompiledCount" -> _Integer, "SeedPath" -> _, "SeedExists" -> _Bool, "SeedCount" -> _Integer, "LastModified" -> _String|>`
Options: `"Channel"` -> `"public"` | `"private"`

### SourceVaultCompileRegistry[topic, entries, opts]
entries (List of Association) を compiled registry に保存する。topic 例: `"model-registry"`。entries 例: `{<|"Provider" -> _, "Intent" -> _, "ModelId" -> _|>, ...}`
→ `<|"Status" -> _, "Topic" -> _, "Channel" -> _, "Path" -> _, "Count" -> _Integer|>`
Options: `"Channel"` -> `"public"` (既定)|`"private"`, `"Sources"` -> `{_String, ...}` (関連 claim/snapshot id), `"PolicySource"` -> String

### SourceVaultRegisterSeed[topic, entries]
seed entries を `seeds/<topic>-seed.json` に保存する (bootstrap 用)。seed は production truth ではなく、compiled registry が無い場合の fallback のみに使われる。
→ Association

## Stage 9: Notebook 管理 (P0)

### SourceVaultRegisterNotebook[path] → Association
指定 path の notebook を SourceVault に登録する。NotebookRef は path-based hash で安定生成される。
返却キー: `"Status"`, `"NotebookRef"`, `"Path"`, `"RegisteredAt"`

### SourceVaultIndexNotebook[path, opts]
notebook の Header / Todo / Cell を抽出して index を更新する。
→ `<|"Status" -> _, "NotebookRef" -> _, "SnapshotId" -> _, "Header" -> _, "TodoCount" -> _, "OpenTodoCount" -> _, "ReviewState" -> _, "DeadlineState" -> _, "Lint" -> {...}|>`
Options: `"ExtractHeader"` -> True, `"ExtractTodos"` -> True, `"ForceReindex"` -> False (file mtime が同じなら skip)

### SourceVaultIndexNotebookFolder[dir, opts]
指定 folder 配下の `.nb` を全て index する。
→ `<|"Status" -> _, "Processed" -> _Integer, "Failed" -> _Integer, "Results" -> {...}|>`
Options: `"Recursive"` -> False, `"ExcludePatterns"` -> `{"*.bak.nb", "Untitled*.nb"}` (既定)

### SourceVaultExtractNotebookHeader[path]
notebook の先頭 Input セルから Header Association を safe parse する。HoldComplete + whitelist で RunProcess / Get / Import 等の危険式を拒否する。
→ `<|"ParseStatus" -> "OK"|"MissingHeader"|"UnsafeExpression", "Keywords" -> _, "Deadline" -> _, "NextReview" -> _, "Status" -> _|>`

### SourceVaultExtractNotebookTodos[path] → List
notebook 内の TodoItem スタイルセルを列挙する。Status 判定は TaggingRules > FontVariations StrikeThrough + FontColor > Default の優先順位。
- StrikeThrough なし → Open
- StrikeThrough あり + FontColor 緑 (RGB g > r, g > b) → Done
- StrikeThrough あり + FontColor 灰 (GrayLevel / RGB r≈g≈b) → Pass
- StrikeThrough あり + その他 → Done (後方互換)

返却要素: `<|"Text" -> _, "Status" -> "Open"|"Done"|"Pass", "StatusSource" -> _, "StrikeThrough" -> _Bool|>`

### SourceVaultFindNotebooks[opts]
index 済み notebook を検索する。LLM 不要の deterministic query。
→ `{record, ...}` (各 record は Association)
record キー: `"Path"` / `"OriginalPath"` (同値エイリアス), `"Title"`, `"NotebookRef"`, `"Header"` (Keywords/Deadline/NextReview/Status/Title), `"Todos"` (`{<|"Text", "Status"(Open|Done|Pass), ...|>, ...}`), `"TodoCount"` / `"OpenTodoCount"` / `"DoneTodoCount"` / `"PassTodoCount"`, `"ReviewState"` / `"DeadlineState"`, `"Lint"`
Options:
- `"OpenTodos"` -> True | False (未完了 Todo を含む / 含まない notebook)
- `"NextReview"` -> `"Today"` | `"Overdue"` | `"ThisWeek"` | `"DueSoon"` | `<|"From" -> _, "To" -> _|>`  (`"Today"` は厳密に今日のみ、`"ThisWeek"`/`"DueSoon"` は今日±7 日以内で遠い過去は除外、`"Overdue"` は期限切れ全部)
- `"Deadline"` -> `"Today"` | `"Overdue"` | `"ThisWeek"` | `"DueSoon"` | `<|"From" -> _, "To" -> _|>`
- `"Keywords"` -> `{_String, ...}` | String (部分一致 OR。検索対象: Header.Keywords + Header.Title + FileBaseName[Path] + 親フォルダ名)
- `"Title"` -> String | `{_String, ...}` (`"Keywords"` と同じ検索プールを見るエイリアス)
- `"Status"` -> `"Todo"` | `"Done"` | String
- `"Scope"` -> `"Today"` 複合フィルタ: (NextReview==今日) | (Deadline==今日) | (Path に YYYYMMDD 形式で今日を含む) の OR。NoReviewDate / NoDeadline はレビュー不要扱いで含まれない
- `"ForceReindex"` -> False (True なら mtime/hash cache を無視し全 notebook を再 index。notebook を編集したのに結果が古い場合に使う)
- `"Format"` -> False (True なら結果を SourceVaultFormatNotebookList でスケジュール表と同形式の Grid にして返す)

Todo 項目自体を列挙したい場合は `record["Todos"]` を使う (SourceVaultExtractNotebookTodos[record["Path"]] でも取れるが再抽出になるため非推奨)。

### SourceVaultNotebookLint[record] → List
notebook record (または path) に対して lint チェックを行う。
検出される lint: `MissingHeader` / `UnsafeHeaderExpression` / `HeaderDeadlineMalformed` / `HeaderNextReviewMalformed` / `HeaderStatusTodoButNoOpenTodos` / `HeaderStatusDoneButOpenTodosExist` / `DeadlinePast` / `NextReviewPast` / `TodoCellStatusHeuristicOnly`

## Stage 9 P1 Step 1: TaggingRules 標準化

### SourceVaultExtractNotebookTaggingRules[path]
notebook 全体および各 TodoItem cell の TaggingRules を取得する。Wolfram 標準関数優先原則 (rule 102) に基づき `Import[path, "Notebook"]` の Notebook 式から TaggingRules を抽出 + `NotebookImport[path, style -> "Cell"]` で各 TodoItem cell の options から TaggingRules を抽出する。
→ `<|"Status" -> "OK"|"Failed", "Path" -> _String, "NotebookTaggingRules" -> _Association (無ければ <||>), "CellTaggingRules" -> {<|"Index" -> _Integer, "CellStyle" -> _String, "TaggingRules" -> _Association|>, ...}|>`

## Stage 9 P1 Step 2: NotebookSemanticHash

### SourceVaultNotebookSemanticHash[path]
notebook の意味的内容のみを対象としたハッシュを計算する。表示メタデータ (ExpressionUUID / CellChangeTimes / CellLabel / FontFamily 等) やウィンドウ設定 (WindowSize / WindowMargins / FrontEndVersion 等) は除外し、意味的に重要な要素 (content / style / TaggingRules / FontVariations / FontColor / Background) だけをハッシュ対象とする。Stage 8 (vN diff / snapshot lifecycle) と連携し、formatting のみの変更で Stale 化誤判定を防ぐ。Wolfram 標準関数優先原則 (rule 102): `Import[path, "Notebook"]` + `Hash[normalizedExpr, "SHA256", "HexString"]`。SourceVaultIndexNotebook の snapshot に SemanticHash が自動追加される。
→ `<|"Status" -> "OK"|"Failed", "Path" -> _String, "SemanticHash" -> _String|>`

## Stage 9 P1 Step 4: Summary artifact stale 判定

### SourceVaultRegisterNotebookSummary[path, summary, opts]
notebook の summary artifact を登録する。現在の snapshot (SnapshotId + SemanticHash) に紐づけて保存されるため、後日 stale 判定が可能。summary 文字列を外部から受け取って保存する形式 (Step 5 LLM 要約が未実装の現時点)。
→ `<|"Status" -> "OK"|"Failed", "SummaryId" -> _String, "NotebookRef" -> _String, ...|>`
Options: `"SummaryFormat"` -> `"text"` | `"markdown"` (既定 `"text"`), `"GeneratedBy"` -> String (既定 `"manual"`)

### SourceVaultGetNotebookSummary[path]
notebook に紐づく summary record を取得する。Summary が未登録の場合は `"Status" -> "Missing"` を返す。
→ `<|"Status" -> "OK"|"Missing"|"Failed", "Summary" -> _String, "SummaryFormat" -> _String, "BasedOnSnapshot" -> _String, "BasedOnSemanticHash" -> _String, "GeneratedBy" -> _String, "CreatedAt" -> _String|>`

### SourceVaultNotebookSummaryStatus[path]
notebook の summary artifact の現在の lifecycle ステータスを判定する。Step 5 以降で自動リフレッシュ決定に活用される。
→ `<|"Status" -> _String, "Reason" -> _String, "CurrentSnapshot" -> _String, "SummaryBasedOnSnapshot" -> _String|_Missing|>`
Status 値:
- `Missing` — summary がまだ存在しない (Step 5 初回実行必要)
- `Current` — summary の BasedOnSnapshot が現在の snapshot と一致
- `StaleFormattingOnly` — SemanticHash が一致 (formatting のみの変更、再生成任意)
- `Stale` — SemanticHash が変わった (再生成推奨)

## Stage 9 P1 Step 5: LLM 要約

### SourceVaultNotebookSummary[path, opts]
notebook の LLM 要約を生成し Step 4 の SourceVaultRegisterNotebookSummary で自動登録する。prompt は Header / Todo / Lint / 先頭複数セルのテキストから構築する。ClaudeCode\`ClaudeQuerySync 経由 (claudecode.wl 依存)。PrivacyLevel 既定 1.0 (ローカル LM)。lifecycle 管理 (SemanticHash 紐づけ) は内部で自動実行する。
→ `<|"Status" -> "OK"|"Failed", "Summary" -> _String, "SummaryId" -> _String, "NotebookRef" -> _String, "LifecycleStatus" -> _String|>`
Options: `"Model"` -> Automatic, `"PrivacyLevel"` -> 1.0, `"Force"` -> False (True で Current 状態でも再生成), `"SummaryFormat"` -> `"text"` | `"markdown"` (既定 `"text"`)

## Stage 9 P1 Step 6: MarkTodo

### SourceVaultMarkTodo[path, target, newStatus, opts]
notebook 内の Todo cell の Status を変更する。NBAccess の高レベル API `NBWriteTodoStatus` への薄いラッパ。target は Integer (1-based Todo インデックス) またはマッチ文字列。newStatus は `"Done"` | `"Pass"` | `"Open"`。
→ Association