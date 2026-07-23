### $SourceVaultVersion
型: String
パッケージバージョン文字列。現行値 `"2026-05-29-stage-9-p1.5-model-registry-autoupdate"`。

### $SourceVaultRoots
型: Association
物理 root ディレクトリマッピング。Keys: `"PrivateVault"` | `"CloudMirror"` | `"Tmp"` | `"AttachmentMirror"` | `"ExternalOwned"`。PrivateVault が authoritative storage で cloud LLM / Claude Code CLI には直接読ませない。CloudMirror / AttachmentMirror は materialized projection のみ。

### $SourceVaultSeedModelRegistry
型: Association
bootstrap 時の fallback model registry。compiled registry が無い場合の災害復旧用。production truth ではない。LLM が自動更新しない (更新は review 必須)。

### $SourceVaultCloudRoots
型: List
クラウド共有フォルダのシンボル名リスト。例: `{"$packageDirectory", "$dropbox", "$onWork", "$offWork", "$mathematicaWork"}`。絶対パスがこれらの配下にあれば `{"$onWork", "folder", "file.nb"}` のようなシンボリックパスに正規化され、PC / OS をまたいで同一 ID になる。PC 固有フォルダ ($ClaudeWorkingDirectory 等) は含めない。

### $SourceVaultCloudRootAliases
型: Association, 初期値: `<||>`
クラウドルートのシンボル名 (`"$onWork"` 等) から、旧 PC など別環境での絶対パスリストへの対応。形式: `<|"$onWork" -> {"C:/Users/imai_/Dropbox/On Work"}, ...|>` (区切りは `/` でも `\` でも可)。別 PC で index された旧パスを `{"$onWork", ...}` に正規化し、複数 PC またぎの二重登録を防ぐ。エイリアスパスは現 PC に実在しなくてよい (前方一致・大小無視)。

### $SourceVaultDefaultNotebookFolder
型: String | Automatic, 初期値: Automatic
SourceVault notebook の既定フォルダ。Automatic では `Global`$onWork`、無ければ `$packageDirectory` に解決。絶対パスを設定するとその folder が既定 Scope になり、PresentationListener の保存先にも使われる。

### SourceVaultInitialize[opts]
物理 root を生成して初期化する。PrivateVault と Tmp は必須。作成済みなら noop。
→ Association (`"Status"` -> "Initialized" | "AlreadyInitialized" | "Failed")
Options: `"Roots"` -> Automatic (`$SourceVaultRoots` を override), `"Force"` -> False (True で再初期化), `"InitMode"` -> "Force" (既定、本来の初期化) | "Ensure" (既定初期化済みなら副作用ゼロで AlreadyInitialized。依存 DAG 経由の冪等実行は `SourceVaultEnsureInitialized` — api_contracts.md 参照)

### SourceVaultResetStore[opts]
SourceVault の notebooks ストア (sources / snapshots / summaries / todos / review / lint / sync / relink) を全削除して初期化する。NotebookRef 方式変更などで旧データを破棄したいときに使う。破壊的操作のため明示承認が必要。
→ `<|"Status" -> "OK"|"DryRun"|"Failed", "Deleted" -> _List, "NotebooksDir" -> _|>`
Options: `"Confirm"` -> False (無いと DryRun 扱いで実際には削除しない)

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
例: `SourceVaultSources["", "Kind" -> "arxiv", "On" -> Today]` (今日 ingest した arXiv)
注意: 対象は SourceVault ingest 済みソース (src-* record) のみ。PDF 検索索引 (PDFIndex collection。学生便覧等) は含まれない — それらの横断は SourceVaultSummaries (pdfindex provider)、本文検索は SourceVaultSearch[query, "Group" -> name] を使うこと。

### SourceVaultArXiv[query, opts]
arXiv ソースだけを共通スキーマ表で表示する (`SourceVaultSources[query, "Kind" -> "arxiv", ...]` の薄ラッパ)。リンク開き・絞り込み検索を持ち、横断検索 SourceVaultSummaries にも相乗りする。
→ Grid | Dataset | List
Options: `"On"`/`"Since"`/`"Until"`/`"Author"`/`"Limit"`/`"Format"` 等 (SourceVaultSources と同じ)
例: `SourceVaultArXiv["reversible", "Author" -> "Bennett"]`

### SourceVaultBackfillArXivSummaries[opts]
既存の arXiv ソースのうち Summary が未設定 (または過去の LLM エラー本文) のものに arXiv アブストラクトを取得し `$Language` へ翻訳して付与する。cloud LLM 使用 (arXiv は公開データなので PrivacyLevel 0.0)。`$Language` が Japanese のセッションで実行すること (headless では英語原文のまま格納)。
→ `<|"Candidates", "Updated", "AlreadyPresent", "NoAbstract", "Failed", "Results"|>`
Options: `"Force"` -> False (True で既存 Summary も再生成), `"Model"` -> Automatic, `"Limit"` -> Automatic|n

### SourceVaultShowSourceSummary[sourceId, opts]
ingest 済みソース (arXiv / web / local) のサマリーを編集可能なノートブックで開く。保存済みのユーザー追記版があればそれを開き (正本)、無ければ Title/著者/出版/URL/要約からノートを生成する。ノート内の「このノートを保存する」ボタンを押すと `<PrivateVault>/sources/summary-notes/` に保存され、以後はその保存版が開く。SourceVaultSources / SourceVaultArXiv / SourceVaultSummaries の表でタイトルまたはサマリーをクリックすると呼ばれる (arxiv/web/local の既定アクション)。
→ なし (NotebookOpen 副作用)
Options: `"Fresh"` -> False (True で保存版を無視し record から新規生成)

### $SourceVaultSummaryNotebookStyle
型: String, 初期値: `"SourceVault default.nb"`
`SourceVaultShowSourceSummary` が開くノートの StyleDefinitions。

### SourceVaultOpenSourceFile[sourceId]
ingest 済みソースの raw ファイルを ContentHash から現 PC の vault パスを live 再算出して SystemOpen で開く。別 PC (Dropbox 同期) でも開ける。SourceVaultSources / SourceVaultArXiv の「▶ 開く」ボタンの実体。
→ なし (SystemOpen 副作用)

### SourceVaultSourceRow[sourceId] → Association
1 ソースの共通スキーマ行を返す。キー: `"Kind"`, `"Id"`, `"URI"` (sv://snapshot/sha256/<hex>), `"Title"`, `"Authors"`, `"Published"`, `"Summary"`, `"URL"`, `"File"`, `"Date"`, `"PrivacyLevel"`。混在データセットの join/参照キーとして URI を使う。
Options: `"FetchMetadata"` -> Automatic

### SourceVaultSummaries[query, opts]
SourceVault が抱えるデータ全体 (ingest 済みソース + Eagle 保存済みサマリー + PDF 検索索引ドキュメント (pdfindex provider。学生便覧等) 等、登録 provider 横断) を検索し統合表で表示する。
→ Grid | Dataset | List
Options: `"Providers"` -> All|`{"sources", "eagle", "pdfindex", ...}`, `"Limit"`, `"Kind"`, `"Since"`/`"Until"`/`"On"` -> 登録/生成日での絞り込み, `"Author"` -> 著者部分一致, `"FetchMetadata"`, `"Format"` -> `"Grid"` (既定)|`"Dataset"`|`"Rows"`
例: `SourceVaultSummaries["可逆計算"]`、`SourceVaultSummaries["便覧", "Providers" -> {"pdfindex"}]`
pdfindex 行の本文検索 (チャンク単位・gate 付き) は SourceVaultSearch[query, "Group" -> name] を使うこと。

### SourceVaultRegisterSummaryProvider[name, fn]
`SourceVaultSummaries` の横断検索 provider を登録する。fn のシグネチャ: `fn[query_String, opts_Association]` → 共通スキーマ行 (SourceVaultSourceRow 参照) のリスト。
→ なし

### $SourceVaultSummaryProviders
型: Association
`SourceVaultSummaries` が横断する provider の Association (name -> fn)。

## Stage 1: Lookup / Resolve

### SourceVaultLookup[topic, key, opts]
compiled registry からキーに対応する entry を返す。key は文字列または Association (Resolve 同様の structured query)。compiled registry に見つからなければ seed に fallback。
→ Association | Missing["NotFound"]
Options: `"Channel"` -> `"public"` (既定)|`"private"`, `"AllowSeed"` -> True (compiled 無し時 seed を使う)
topic 例: `"model-registry"`, `"mathematica-graph-options"`

### SourceVaultResolve[kind, query, opts]
compiled registry から query に match する entry を返す。複数 match 時は Availability != "Unavailable" をフィルタし Class/Freshness で sort して先頭を返す。network なし、LLM なし。
→ Association | Missing["NotFound"]
Options: `"Channel"` -> `"public"`|`"private"`, `"AllowSeed"` -> True, `"Topic"` -> Automatic (既定 `"<kind>-registry"` を小文字化)
例: `SourceVaultResolve["Model", <|"Provider" -> "anthropic", "Intent" -> "heavy"|>]`

### ClaudeResolveModel[provider, intent] → Association | Missing["NotFound"]
`SourceVaultResolve["Model", ...]` の互換 wrapper。旧 WikiDBResolveModel の置き換えとして利用できる。
例: `ClaudeResolveModel["anthropic", "heavy"]`

## Stage 1.5 / 2: Ingest

### $SourceVaultMaxFileSizeMB
型: Real, 初期値: 50
index 時に `.nb` を Import するファイルサイズの上限 (MB)。これを超える `.nb` (シミュレーション結果等の巨大ファイル) は Import せずファイル情報だけの軽量 snapshot を作る (Skipped マーク)。ingest 時の EnsureUUID でもこの閾値を超えるファイルは UUID 付与スキップ対象となる。

### SourceVaultIngest[source, opts]
外部 source を登録し raw snapshot を PrivateVault に保存する。source は ローカルファイルパス / HTTPS URL / arXiv ID (`arXiv:NNNN.NNNNN[vN]`) を受け付ける。arXiv ID は `arxiv.org/pdf/...` に canonicalize して URL ingest する。戻り値に content-addressed 正準 URI `"URI" -> sv://snapshot/sha256/<hex>` を含む (SourceVaultSources の行・SourceVaultParseURI/mcp との join/参照キー)。
→ Association (`"Status"`, `"SourceId"`, `"SnapshotId"`, `"URI"`, ...)
Options:
- `Topic` -> Automatic | String
- `TrustLevel` -> Automatic | `"OfficialAPI"` | `"OfficialDocs"` | `"PublicWeb"` | `"LocalFile"`
- `PrivacyLabel` -> Automatic | Real
- `PinVersion` -> Automatic | True | False
- `"Asynchronous"` -> False (True 時は LLMGraphDAGCreate 経由でジョブキューに投入し JobId を即時 return。LLMGraphDAGCreate (claudecode.wl) が必要)
- `"EnsureUUID"` -> Automatic | True | False (`.nb` 取り込み時の UUID 自動付与。Automatic/True なら hash 計算前に SourceVaultEnsureNotebookUUID を呼び元ファイルに UUID を埋め込む。`.nb` 以外と巨大ファイル (`>$SourceVaultMaxFileSizeMB`) はスキップ。付与に失敗しても ingest は続行)

### SourceVaultResolveReference[ref]
ingest 済みソースを参照文字列から解決する。ref は正準 snapshot URI (`sv://snapshot/sha256/<hex>`) / SourceId (`src-...`) / ingest 済み URL のいずれか。ClaudeAttach の sv URI アタッチ / documentation.wl の cite 解決が利用する。
→ `<|"Status" -> "OK"|"NotFound", "SourceId" -> _, "URI" -> _, "File" -> _ (現 PC で実在する raw snapshot パス、無ければ ""), "URL" -> _, "Title" -> _, "Authors" -> _, "Published" -> _, "Kind" -> _, "PrivacyLevel" -> _|>`

### SourceVaultIngestWait[ingestResult, timeoutSec]
非同期 ingest の完了を待つ。ingestResult が sync 完了済み (Status: Ingested/AlreadyCurrent/RebuiltMetadata) なら即座に return。Status: Queued の場合は SourceId の snapshot 増加を polling して新規 snapshot 出現で完了。第一引数は SourceVaultIngest の結果 Association または SourceId String。timeoutSec 既定 60 秒、超過で Status: Timeout。
→ Association

### SourceVaultReclassifyPublicPrivacy[]
ingest 済みの公開 origin ソース (arXiv / 公開 URL) で PrivacyLevel が機密閾値 0.5 以上に誤設定されているものを本来の公開既定値 (OfficialDocs/OfficialAPI=0.0, PublicWeb=0.4) に是正する保守関数。source/snapshot 両メタを書き換える。旧版が arXiv 等の OfficialDocs を 0.6 とタグした件の一度きりの修復用 (冪等)。
→ `<|"Status", "Count", "Changed" -> {<|SourceId, From, To|>...}|>`

### Ingest オプションシンボル
`Topic` / `PinVersion` / `TrustLevel` / `PrivacyLabel` は `SourceVaultIngest` のオプションシンボル。`MaxCharacters` は `SourceVaultContext` / `SourceVaultContextAssemble` のオプションシンボル。

## Stage 3: Context 取得 / Attach / Materialization

### SourceVaultSpan[snapshotOrRef, opts] → Association
SourceSpan association を作る。snapshotOrRef は SnapshotId / SourceRef / file path のいずれか。
Options: `"Pages"` -> All | Integer | `{1,3,5}`, `"Role"` -> `"ReferenceContext"` | `"Evidence"` | `"ExtractionInput"`, `"Purpose"` -> `"Generic"` (既定) | `"LaTeXMathFormatting"` | String, `"EquationLabels"` -> Missing["NotSpecified"] (数式ラベルの明示指定、Locator に格納)

### SourceVaultContext[sourceSpan, opts]
sourceSpan の plaintext を取り出し、NBAuthorize の判定付きで LLM 文脈として返す。RequireApproval も block する。
→ Association | plaintext (判定結果に依存)
Options: `MaxCharacters` -> 8000, `"Sink"` -> None, `"Purpose"` -> `"Generic"`

### SourceVaultContextAssemble[sourceSpans, opts]
複数 span を 1 つの prompt context に組み立てる。
→ Association
Options: `"Purpose"` -> `"Generic"`, `MaxCharacters` -> 8000, `"Ordering"` -> `"GivenOrder"` (既定) | `"PageOrder"` | `"Citation"`, `"Separators"` -> `"ByPage"` (既定) | `"BySource"` | None, `"IncludeCitations"` -> True | False, `"Sink"` -> None

### SourceVaultAttach[nb, source, opts]
notebook に source を attach し TaggingRules に sourceVaultRefs を記録する。旧 ClaudeAttach のバックエンド代わり。source は SourceVaultSpan 済み Association、または SourceVaultSpan に渡すのと同じ ref (SnapshotId/SourceId/file path)。
→ Association
Options: `"Pages"` -> All, `"Role"` -> `"ReferenceContext"`, `"Purpose"` -> `"Generic"`, `"CellIndex"` -> Automatic

### SourceVaultAttachToCell[nb, cellIdx, sourceSpan, opts]
cell に SourceSpan を attach する。
→ Association

### SourceVaultGetAttachments[nb] → List
notebook に attach された source 一覧を返す。

### SourceVaultGetCellSources[nb, cellIdx] → List
cell に紐づく SourceSpan リストを返す。旧形式 (refSources) を read-only normalization して新形式で返す。

### SourceVaultEnsureRegistered[ref] → Association
旧 refSources 形式 (あるいは file path) を SourceSpan 形式に normalize する。必要に応じて ingest する。

### SourceVaultMaterializeForSink[sourceRef, sinkSpec, opts]
source を cloud-accessible mirror へ materialize する。内部で必ず NBAuthorize を呼ぶ。
→ Association
Options: `"Force"` -> False

### SourceVaultResolvePath[ref, opts]
source/snapshot の物理 path を返す。`"Tier"` -> `"PrivateVault"` は local kernel / maintenance 専用。cloud LLM 向けには SourceVaultMaterializeForSink を使うこと。
→ String
Options: `"Tier"` -> `"PrivateVault"` 等

### SourceVaultObjectSpec[ref, opts] → Association
source/snapshot を NBAuthorize が受け取れる object spec association に変換する。

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
OCR hook を有効化する。backend 既定 `"ClaudeVision"`。全 backend は単一の共有 Options プール (`Options[SourceVaultOCREnable]`: `"DPI"` -> 300, `"SplitHalves"` -> True, `"Timeout"` -> 180, `"Language"` -> `"Japanese"`, `"Prompt"` -> Automatic, `"Hook"` -> None, `"Mode"` -> `"Auto"`, `"Verbose"` -> False) で opts を検証するが、未指定キーの実効既定値は backend の内部実装依存 (下記)。
→ `<|"Status" -> "Enabled", "Backend" -> _String, "Mode" -> _String, "Options" -> _Association|>`
backend:
- `"ClaudeVision"`: `ClaudeCode`ClaudeQueryBg` 経由で Claude API にページ画像を送り OCR (PDFIndex 実証済みパターン)。大きいページは自動で上下分割 (30px overlap) して 2 回 OCR しマージ。実効既定: `"DPI"` -> 300, `"SplitHalves"` -> True, `"Timeout"` -> 180, `"Prompt"` -> Automatic (未指定時は内蔵プロンプト)
- `"TextRecognize"`: Mathematica 組み込み TextRecognize (Python 不要、精度準等)。実効既定: `"DPI"` -> 150, `"Language"` -> `"Japanese"`
- `"Custom"`: ユーザー提供 Function をそのまま `$SourceVaultOCRHook` に設定。Options: `"Hook"` -> `Function[req, text]` (必須、Head が Function でないと Failed)

共通 Options: `"Mode"` -> `"Auto"` (既定) | `"Force"`, `"Verbose"` -> False | True

### SourceVaultOCRDisable[]
OCR hook を無効化する (`$SourceVaultOCRHook = None`)。
→ Association

### SourceVaultOCRStatus[] → Association
現在の OCR hook 設定を返す。キー: `Backend` (Disabled / ClaudeVision / TextRecognize / Custom), `HookSet` (True なら `$SourceVaultOCRHook` に Function が設定済み), `Mode`, `Verbose`。

## Stage 5: Claim 抽出

### SourceVaultExtract[sourceSpan, schema, opts]
sourceSpan のページテキストを LLM に渡して claim を抽出する。sourceSpan は `SourceVaultSpan[...]` の結果または SnapshotId/SourceId String。schema は文字列 (登録済み schema 名) または Association (インライン定義)。schema の説明・JSON 出力形式・項目名を prompt に差し込み、文字列・数値・配列を抽出。AuthorizationCheck -> True 時は sendDecision (LLM 送信前) → context 取得 + LLM 抽出 → persistDecision (claim 保存前) の 3 フェーズで実行される。
→ `<|"Claims" -> {claim1, ...}, "Count" -> _Integer (実納数), "ExtractedCount" -> _Integer (LLM 生抽出数), "DedupSkipped" -> _Integer, "AccessDecisions" -> <|"Send" -> _, "Persist" -> _|>, "ValidationStatus" -> _, "SchemaName" -> _, "ExtractedAt" -> DateObject, "Errors" -> {...}|>`
Deny 時: `<|"Status" -> "DeniedByNBAccess", "Reason" -> _, "AccessDecisions" -> _|>`
RequireApproval 時: `<|"Status" -> "RequiresApproval", "Reason" -> _, "AccessDecisions" -> _|>`
Options:
- `"Topic"` -> Automatic (claim の topic、既定 schema 名)
- `"ModelIntent"` -> `"extraction"` (既定) | `"summary"` | `"math-extraction-heavy"`
- `"StoreClaims"` -> True | False (既定 True)
- `"Dedup"` -> True | False (既定 True。by-source ファイル単位で ContentHash 照合)
- `"AuthorizationCheck"` -> True | False (既定 True。Stage 6d: 2 段階 NBAuthorize)
- `"Validation"` -> `"None"` (既定) | `"Required"`
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
Options: `"Kind"` -> `"Generic"` (既定) | `"SimulationExample"` | `"LaTeXExport"` | `"DocumentGeneration"` | `"CodeGeneration"` | `"Notebook"` | String

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
→ `<|"Status" -> _, "V1Snap" -> _, "V2Snap" -> _, "AddedPages" -> {_Integer, ...} (v2 にしかない), "RemovedPages" -> {_Integer, ...} (v1 にしかない), "ChangedPages" -> {_Integer, ...} (両方にあるが hash 相違), "UnchangedPages" -> {_Integer, ...} (両方にあり hash 一致)|>`

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
Options: `"SourceId"` -> All (既定)|String (指定 source に関連する event のみ), `"SnapshotId"` -> All (既定)|String (指定 snapshot に関連する event のみ), `"EventType"` -> All (既定)|String (`VersionedUpdate` / `Retraction` / `SourceDeletion` / `SchemaChange`)

### SourceVaultSourceEventAppend[event]
event Association を `events/source-events.jsonl` に append する。event には `EventType` / `SourceId` / `Reason` が必須。`OldSnapshotId` / `NewSnapshotId` / `Metadata` は任意。EventId と Timestamp は自動生成される。
→ Association

## Stage 6b: Compiled Registry

### SourceVaultListModels[provider, opts] → List
指定 provider に登録された選択可能な全モデル ID リスト。SourceVaultResolve が intent 単位の最適 1 件を返すのに対し、これは catalog を列挙する (例: パレットのモデル選択)。compiled registry を優先し、無ければ seed に fallback。Availability が Unavailable のエントリは除外。
Options: `"Channel"` -> `"public"` (既定)|`"private"`, `"AllowSeed"` -> True

### SourceVaultModelContextLength[provider, modelId] → Integer | None
モデルに紐づく ContextLength を返す。`SourceVaultSetModel[..., "ContextLength" -> n]` で永続化された値。LM Studio 等ローカル LLM の context_length に使う。未設定なら None。

### SourceVaultModelIntegrations[provider, modelId] → List | None
モデルに紐づく LM Studio MCP の integrations リストを返す。`SourceVaultSetModel[..., "Integrations" -> {...}]` で永続化された値。LM Studio `/api/v1/chat` の integrations パラメータに使う。MCP ID (`"mcp/exa"` 等) をコードにハードコードせず SourceVault ストアに永続化するための機構。未設定なら None。

### SourceVaultListRegistries[opts] → Association
登録済み registry topic と channel を返す。
Options: `"Channel"` -> `"public"` | `"private"` | All (既定 All)

### SourceVaultRegistryStatus[topic, opts]
指定 topic の registry 状態を返す。
→ `<|"Topic" -> _, "Channel" -> _, "CompiledPath" -> _, "CompiledExists" -> _Bool, "CompiledCount" -> _Integer, "SeedPath" -> _, "SeedExists" -> _Bool, "SeedCount" -> _Integer, "LastModified" -> _String|>`
Options: `"Channel"` -> `"public"` (既定) | `"private"`

### SourceVaultCompileRegistry[topic, entries, opts]
entries (List of Association) を compiled registry に保存する。topic 例: `"model-registry"`。entries 例: `{<|"Provider" -> _, "Intent" -> _, "ModelId" -> _|>, ...}`
→ `<|"Status" -> _, "Topic" -> _, "Channel" -> _, "Path" -> _, "Count" -> _Integer|>`
Options: `"Channel"` -> `"public"` (既定)|`"private"`, `"Sources"` -> `{}` (既定、関連 claim/snapshot id), `"PolicySource"` -> `"config/policies.wl"` (既定)

### SourceVaultRegisterSeed[topic, entries]
seed entries を `seeds/<topic>-seed.json` に保存する (bootstrap 用)。seed は production truth ではなく、compiled registry が無い場合の fallback のみに使われる。
→ なし

## モデルレジストリ管理 / エンドポイント

### $SourceVaultModelEndpoints
型: Association
provider 名からモデル一覧エンドポイント設定への Association。ユーザーが上書き可能 (LM Studio のポート等は環境依存)。各値は `<|"ModelsURL" -> _, "Kind" -> "Cloud"|"Local", "AuthProvider" -> _|>`。

### SourceVaultModelEndpointStatus[] → Association
各 provider エンドポイントの到達性 (オフライン検知) を返す。短いタイムアウトで probe し、401/403 が返ってもサーバー到達 = Online とみなす。
→ `<|"Status" -> _, "Endpoints" -> <|provider -> <|"Status" -> "Online"|"Offline", ...|>|>|>`

### SourceVaultDetectLocalModels[opts]
ローカル LLM サーバー (LM Studio 等、OpenAI 互換 /v1/models) からモデル一覧を推測する。API キー不要。サーバーがキー保護有効な場合、API キーは `NBAccess`NBGetLocalLLMAPIKey` 経由で自動解決される (事前に NBStoreLocalLLMAPIKey で登録)。
→ `<|"Status" -> "OK"|"Offline", "Provider" -> _, "Endpoint" -> _, "Models" -> {_String..}|>`
Options: `"Provider"` -> `"lmstudio"` (既定), `"Endpoint"` -> Automatic (既定は `ClaudeCode`$ClaudePrivateModel` の url を優先、無ければ `$SourceVaultModelEndpoints` の設定)

### SourceVaultSetModel[provider, intent, modelId, opts]
compiled model registry に手動で 1 エントリを書き込む (API キー不要)。Source -> "manual" で保存し、同 (provider, intent) の既存エントリを置き換える。オフライン環境や自動取得できないモデルを固定したいときに使う。
→ Association
Options: `"Channel"` -> `"public"` (既定)|`"private"`, `"Class"` -> Automatic (推論), `"Capabilities"` -> Automatic, `"ContextLength"` -> Automatic|Integer (モデルの最大コンテキスト長), `"Integrations"` -> Automatic|List (LM Studio MCP integrations リスト)
例: `SourceVaultSetModel["lmstudio", "local-heavy", "qwen/qwen3-coder-30b", "Integrations" -> {"mcp/exa"}, "ContextLength" -> 32000]`

### SourceVaultClearModelRegistry[opts]
compiled model registry を削除し、次回アクセス時に seed (コード内の最新 iModelSeedEntries) から再構築させる。compiled に古い seed コピー (例: claude-opus-4-7) が残って ClaudeResolveModel が古い ID を返し続けるときの復旧用。seed 自体は消さない。
→ Association
Options: `"Channel"` -> `"public"` (既定)

### SourceVaultSetModelIntent[variable, spec]
SourceVault が選択するモデルの intent 割り当てを変更する。variable: `"$ClaudeModel"` | `"$ClaudeDocModel"` | `"$ClaudePrivateModel"` | `"$ClaudeFallbackModels"`。spec: `{provider, intent}` (例 `{"anthropic", "heavy"}`)、FallbackModels は `{{provider,intent}, ...}`。設定後 `SourceVaultAssignClaudeModels[]` を呼んで実変数に反映する。$NBApprovalHeads に登録され ClaudeEval 経由では Hold -> Approve が必要。
→ Association
例: `SourceVaultSetModelIntent["$ClaudeModel", {"anthropic", "heavy"}]`

### SourceVaultModelIntentMap[] → Association
変数名 -> intent spec のマッピングを返す読み取り公開関数。`NBAccess`NBSyncClaudeModelVars` がこれを読んでモデル変数を解決・代入する。
例: `<|"$ClaudeModel" -> {"claudecode","code-heavy"}, ...|>`

### SourceVaultAssignClaudeModels[opts]
intent マッピング (SourceVault) と信頼ローカルサーバ (`NBAccess`NBResolveLocalServer`) から $ClaudeModel / $ClaudeDocModel / $ClaudePrivateModel / $ClaudeFallbackModels を設定する。SourceVault ロード時に自動実行される。
→ Association
Options: `Verbose` -> False (既定)

### SourceVaultRefreshModelRegistry[opts]
クラウド (anthropic/openai) とローカル (LM Studio) のエンドポイントからモデル一覧を取得し compiled model registry を更新する。クラウド API キーは `NBAccess`NBGetAPIKey` 経由で取得し、キーが無い provider はスキップ。取得エントリは Source -> "auto-fetch" でマークし、既存の seed/manual エントリは温存してマージする。
→ `<|"Status" -> _, "FetchedCount" -> _, "RegistryTotal" -> _, "PerProvider" -> _, "RegistryPath" -> _|>`
Options: `"Providers"` -> All (既定), `"IncludeCloud"` -> Automatic, `"DryRun"` -> False

## Notebook UUID

### SourceVaultNotebookUUID[path] → String | Missing[]
notebook に埋め込まれた UUID (TaggingRules > SourceVault > NotebookUUID) を返す。未設定なら Missing[]。読み取りのみ (ファイルは書き換えない)。

### SourceVaultEnsureNotebookUUID[path, opts]
notebook に UUID が無ければ生成して埋め込む。UUID は notebook 自身の TaggingRules に保存され、ファイル名変更・内容編集をまたいで安定する (SourceVaultRelinkSources の最も信頼できる照合キー)。
→ `<|"Status" -> _, "Path" -> _, "UUID" -> _, "Created" -> True|False|>`
Options: `Force` -> False (True で既存 UUID も再生成)

### SourceVaultEnsureNotebookUUIDFolder[dir, opts]
folder 配下の `.nb` 全てに UUID を付与する。
→ `<|"Status" -> _, "TotalFiles" -> _, "Created" -> _, "AlreadyPresent" -> _, "Skipped" -> _ (巨大ファイル等), "Failed" -> _|>`
Options: `"Recursive"` -> True, `"ExcludePatterns"` -> {...}, `"MaxFileSizeMB"` -> Automatic (既定 `$SourceVaultMaxFileSizeMB` を使用)

## 同期 / Relink / Privacy

> **関数の出力に PrivacyLevel を伝えるしくみは `api_privacy.md` を参照。**
> `SourceVault_privacy.wl` (`SourceVault.wl` の補助ロード列の先頭。maildb より前にロードされる) が
> 評価スコープの透かし (`SourceVaultNotePrivacy` / `SourceVaultNotePrivacyOf`)、正準 exit
> (View 系 `SourceVaultPrivateView` / Core 系 `SourceVaultPrivateResult`)、宣言レジストリ、
> 呼び出しグラフ監査 (`SourceVaultPrivacyAudit`)、動的適合テスト
> (`SourceVaultPrivacyConformanceTest`) を提供する。
> 本節の `SourceVaultSetSnapshotPrivacyLevel` は「保存済み snapshot record の PL を書き換える」
> 別レイヤ (ストレージ側) で、上記の「評価から出力への伝達」とは責務が異なる。

### SourceVaultSetSnapshotPrivacyLevel[snapshotId, level]
snapshot record の PrivacyLevel フィールドを明示的に上書きする。`NBAccess`NBSetSnapshotPrivacyLevel` の委譲先で、承認ゲートは NBAccess 側の $NBApprovalHeads 登録で発火する。Notebook snapshot (notebooks/snapshots/) と PDF/URL snapshot (raw/meta/) の両系統をファイル存在で判別して処理する。level は 0.0-1.0 に clip される。既存値より低い値を指定した場合は `"Lowered" -> True` を返す (手動操作なので許可、Sync 経路の単調性制約とは別)。
→ `<|"Status" -> _, "SnapshotId" -> _, "OldPrivacyLevel" -> _, "NewPrivacyLevel" -> _, "Lowered" -> _, "SnapshotKind" -> _|>`

### SourceVaultSelectSources[opts]
同期対象となる source を選定して返す。Scope 配下の `.nb` をスキャンし、各ファイルを source descriptor 化する。
→ `<|"Status" -> _, "Scope" -> _, "Count" -> _, "Sources" -> {_Association..}|>`
Options: `"Scope"` -> Automatic, `"Recursive"` -> True, `"Kind"` -> `"Notebook"` (既定、`"All"` も可), `"ExcludePatterns"` -> `{"*.bak.nb", "Untitled*.nb"}`

### SourceVaultSyncPlan[opts]
各 source の鮮度を判定し同期計画を返す (dry-run、副作用なし)。鮮度トークン (ローカルは mtime) を現 snapshot の記録と比較し Fresh/Stale/Missing/NeverIndexed に分類する。
→ `<|"Status" -> _, "Total" -> _, "StaleCount" -> _, "Plan" -> _Dataset, ...|>`
Options: `"Scope"` -> Automatic, `"Recursive"` -> True, `"Kind"` -> `"Notebook"`, `"ExcludePatterns"` -> `{"*.bak.nb", "Untitled*.nb"}`

### SourceVaultSync[opts]
SyncPlan に従い Stale な source を再 index する (クローラー骨格)。ローカル notebook は SourceVaultIndexNotebook で再 index。PrivacyLevel は単調 (自動で下げない): 再 index で下がった場合は SourceVaultSetSnapshotPrivacyLevel で旧値に引き上げ、警告を記録する。sync/sync-history.jsonl に記録し sync/last-sync.json を更新する。
→ `<|"Status" -> _, "SyncId" -> _, "Refreshed" -> _, "Skipped" -> _, "Failed" -> _, "PrivacyWarnings" -> _|>`
Options: `"Scope"` -> Automatic, `"Recursive"` -> True, `"Kind"` -> `"Notebook"`, `"ExcludePatterns"` -> `{"*.bak.nb", "Untitled*.nb"}`, `"DryRun"` -> False, `"ForceAll"` -> False, `"RefreshSummary"` -> False, `"FallbackToCloud"` -> `"Deny"` (一括同期の既定)

### SourceVaultSyncStatus[] → Association
直近の sync 実行の状態 (sync/last-sync.json) を返す。一度も sync していなければ `<|"Status" -> "NoSyncYet"|>`。

### SourceVaultRelinkSources[opts]
OriginalPath が存在しなくなった (移動された) notebook source を検出し、Scope 配下から移動先を探して再リンクする。照合は (1) 埋め込み UUID (TaggingRules の SourceVault > NotebookUUID)、(2) 内容ハッシュ (RawContentHash 完全一致)、(3) ファイル名一意一致 の順。移動判定はシンボリックパス解決ベース (単なる PC・ルートパス差を移動と誤検出しない)。UUID/ContentHash 一致は自動適用、NameOnly (弱い証拠) は ApplyNameOnly -> True のときのみ。マッチ先が既に別の現役 record の指す実ファイルなら StaleDuplicate (旧 PC index の残骸) として分類。DryRun -> False のとき移動先を再 index し旧 record に Superseded マークを付ける (旧 record は削除しない、可逆)。relink/relink-log.jsonl に記録。
→ `<|"Status" -> _, "Linked" -> _, "Relinked" -> {..}, "RelinkedCount" -> _, "ByMethod" -> <|"UUID"/"ContentHash"/"NameOnly" -> _|>, "Unresolved" -> {..}, "DryRun" -> _|>`
Options: `"Scope"` -> Automatic, `"Recursive"` -> True, `"DryRun"` -> True (既定、安全側), `"ApplyNameOnly"` -> False, `"DeleteStale"` -> False (True で StaleDuplicate の残骸 record を sources/ から削除), `"ExcludePatterns"` -> `{"*.bak.nb", "Untitled*.nb"}`

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

### SourceVaultFindTodos[opts]
条件に合う notebook の todo 項目をフラットな List で返す。SourceVaultFindNotebooks と同じ notebook 検索オプション (OpenTodos / NextReview / Deadline / Keywords / Title / Status / Scope) を受け、マッチした各 notebook の todo セルを 1 行 1 項目に展開する。「今週期限の todo をリスト」のような todo 単位の要求には FindNotebooks でなくこちらを使う。
→ `{<|"Title", "Path", "NotebookRef", "Deadline", "NextReview", "ReviewState", "DeadlineState", "TodoText", "TodoStatus", "TodoStrikeThrough"|>, ...}` (Format->True で Grid)
Options: `"TodoStatus"` -> `"Open"` (既定) | `"Done"` | `"Pass"` | All (展開後の todo を status で絞る), FindNotebooks 共通オプション (`"OpenTodos"` の既定はこちらでは True), `"Format"` -> False

### SourceVaultNotebookLint[record] → List
notebook record (または path) に対して lint チェックを行う。
検出される lint: `MissingHeader` / `UnsafeHeaderExpression` / `HeaderDeadlineMalformed` / `HeaderNextReviewMalformed` / `HeaderStatusTodoButNoOpenTodos` / `HeaderStatusDoneButOpenTodosExist` / `DeadlinePast` / `NextReviewPast` / `TodoCellStatusHeuristicOnly`

### SourceVaultUpcomingSchedule[opts]
「今日から N 日以内」に Deadline / NextReview がある notebook の一覧を返す。概要もキャッシュから取り込む (必要時は自動再生成)。日付は yyyy/mm/dd 形式、期限切れは赤、今日または明日は青。
→ Dataset (行={Deadline, NextReview, Title (Open button), Dir (Open button), OpenTodos, Status, Privacy}) | 他 (`"OutputFormat"` 参照)
Options: `"Scope"` -> Automatic (既定 $onWork または $packageDirectory), `"Period"` -> `Quantity[7,"Days"]`, `"IncludeOverdue"` -> True, `"Recursive"` -> True, `"Refresh"` -> `"Never"` (既定) | `"IfStale"` | `"Force"` (Never は保存済み Summary のみ表示、無ければ Keywords をツールチップに fallback。生成は SourceVaultRefreshAllSummaries で行う), `"FallbackToCloud"` -> `"Ask"`, `"StatusFilter"` -> `{"Todo"}` (既定) | `{"Todo","Done","Pass"}` | All, `"UseCache"` -> True, `"OpenTodos"` -> Missing[] (既定、絞り込まない) | True | False (open-todo セルの有無でフィルタ。StatusFilter とは独立), `"DateField"` -> `"Both"` (既定) | `"Deadline"` | `"NextReview"` (指定フィールドを持つ record だけ残す), `"FilterSpec"` -> Missing[] (既定) | Association (下記 FilterSpec DSL による構造化絞り込み), `"OutputFormat"` -> `"Dataset"` (既定、装飾済み Grid) | `"Rows"` (正規化 record の Dataset) | `"Records"` (生の正規化 record List、Select 可能)

`"FilterSpec"` は閉じた述語 DSL (spec v11 5.4.2/5.4.3、PromptRouter TabularQuery のカウンターパート)。ノード形式: `<|"Kind"->"And"|"Or", "Clauses"->{node,...}|>` | `<|"Kind"->"Not", "Clause"->node|>` | `<|"Kind"->"Field", "Field"->name, "Op"->op, "Value"->v|>`。Field は正規化 record のキー (`"Deadline"`, `"NextReview"`, `"OpenTodos"`, `"DoneTodos"`, `"PassTodos"`, `"Title"`, `"Status"`, `"Path"`, `"Keywords"`)、Op は `"Equal"|"NotEqual"|"Greater"|"GreaterEqual"|"Less"|"LessEqual"|"Contains"|"DateWithin"|"NonEmpty"` のみ許可 (ホワイトリスト外は InvalidFilterSpec で Failed)。
例: `SourceVaultUpcomingSchedule["OutputFormat" -> "Records", "FilterSpec" -> <|"Kind" -> "Field", "Field" -> "OpenTodos", "Op" -> "Greater", "Value" -> 0|>]`

### SourceVaultFormatNotebookList[records, opts]
notebook record の List をスケジュール表と同じ表形式で Grid 表示する。SourceVaultFindNotebooks の戻り値、SourceVaultIndexNotebook の OK record リスト、Path/Header を持つ任意の Association List を受け付ける。ClaudeEval などで notebook list を表示する際の既定フォーマット関数。
→ Grid (行={Deadline, NextReview, Title, Dir, OpenTodos, Status, Summary, Publishable})
Options: `"Refresh"` -> `"Never"` (既定) | `"IfStale"` | `"Force"`, `"FallbackToCloud"` -> `"Deny"`, `"UseCache"` -> True

### SourceVaultNewNotebook[opts]
テンプレート (`$packageDirectory/Templates/SourceVault notebook template.nb`) を複製し、NotebookStatus セルの Deadline と NextReview を生成日 (既定: 今日) に置換して未保存の新規ウィンドウとして開く (ファイルには保存しない)。Deadline/NextReview は `DateObject[{y,m,d}]` の編集可能入力式で挿入される。
→ `<|"Status" -> "OK", "Notebook" -> _NotebookObject, "Date" -> _, "StatusCellReplaced" -> _Bool, "Saved" -> False, ...|>`
Options: `"TemplatePath"` -> Automatic | path, `"Title"` -> Automatic (既定 "新規ノート") | String, `"Date"` -> Automatic (今日) | DateObject, `"Keywords"` -> Automatic (テンプレ値維持) | `{_String..}` | String, `"SessionID"` -> Automatic (追加しない) | String

### SourceVaultRefreshAllSummaries[opts]
Scope 配下全 notebook の概要を一括再生成する。
→ `<|"Status" -> "OK", "Scope", "TotalFiles", "Refreshed", "Cached", "Inconsistent", "Failed", "Details"|>`
Options: `"Scope"` -> Automatic (既定 $onWork), `"Recursive"` -> True, `"ForceRefresh"` -> False, `"FallbackToCloud"` -> `"Deny"` (一括時推奨), `"OpenTodosOnly"` -> False (True で OpenTodoCount>0 のノートだけ生成対象), `"Model"` -> Automatic, `"Progress"` -> False (True で 10 件毎に進捗 Print), `"Limit"` -> Infinity

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
notebook の summary artifact を登録する。現在の snapshot (SnapshotId + SemanticHash) に紐づけて保存されるため、後日 stale 判定が可能。summary 文字列を外部から受け取って保存する形式。
→ `<|"Status" -> "OK"|"Failed", "SummaryId" -> _String, "NotebookRef" -> _String, ...|>`
Options: `"SummaryFormat"` -> `"text"` (既定) | `"markdown"`, `"GeneratedBy"` -> `"manual"` (既定)

### SourceVaultGetNotebookSummary[path]
notebook に紐づく summary record を取得する。Summary が未登録の場合は `"Status" -> "Missing"` を返す。
→ `<|"Status" -> "OK"|"Missing"|"Failed", "Summary" -> _String, "SummaryFormat" -> _String, "BasedOnSnapshot" -> _String, "BasedOnSemanticHash" -> _String, "GeneratedBy" -> _String, "CreatedAt" -> _String|>`

### SourceVaultNotebookSummaryStatus[path]
notebook の summary artifact の現在の lifecycle ステータスを判定する。自動リフレッシュ決定に活用される。
→ `<|"Status" -> _String, "Reason" -> _String, "CurrentSnapshot" -> _String, "SummaryBasedOnSnapshot" -> _String|_Missing|>`
Status 値:
- `Missing` — summary がまだ存在しない (初回実行必要)
- `Current` — summary の BasedOnSnapshot が現在の snapshot と一致
- `StaleFormattingOnly` — SemanticHash が一致 (formatting のみの変更、再生成任意)
- `Stale` — SemanticHash が変わった (再生成推奨)

## Stage 9 P1 Step 5: LLM 要約

### SourceVaultNotebookSummary[path, opts]
notebook の内容を LLM で要約し Summary artifact として保存する (内部で SourceVaultRegisterNotebookSummary を SummaryFormat -> "text" 固定で呼ぶため、生成される SummaryFormat は常に text)。snapshot・SemanticHash 紐づけ・lifecycle 管理は自動。prompt は Header / Todo / Lint / 先頭複数セルのテキストから構築する。`ClaudeCode`ClaudeQuerySync` 経由 (claudecode.wl 依存)。既定で PrivacyLevel 1.0 (ローカル LM 経由で notebook 内容を API に送らない)。
→ `<|"Status" -> "OK"|"Failed"|"Inconsistent", "Summary" -> _String, "SummaryId" -> _String, "NotebookRef" -> _String, "LifecycleStatus" -> _String, ...|>` (Current で ForceRefresh 無しなら既存 record を返す)
Options: `"ForceRefresh"` -> False (True で Current でも強制再生成), `"MaxLength"` -> 500 (要約の最大文字数), `"Language"` -> Automatic | `"Japanese"` | `"English"`, `"Model"` -> Automatic (`{"provider","model"}` 明示可), `"PrivacyLevel"` -> 1.0 (0.0=API 許可 〜 1.0=ローカルのみ), `"FallbackToCloud"` -> `"Ask"` | `"Allow"` | `"Deny"`

## Stage 9 P1 Step 6: MarkTodo

### SourceVaultMarkTodo[path, target, newStatus, opts]
notebook 内の Todo cell の Status を変更する。NBAccess の高レベル API `NBWriteTodoStatus` への薄いラッパ。target は Integer (1-based Todo インデックス) / String (TodoId) / Association (`<|"Index" -> n, "Text" -> "..."|>`)。newStatus は `"Open"` | `"Done"` | `"Pass"`。変更内容 (NBWriteTodoStatus に委任): Cell options の FontVariations StrikeThrough + FontColor (緑/灰) と Cell TaggingRules の `<|"SourceVault" -> <|"TodoStatus" -> newStatus|>|>`。
→ DryRun 時: `<|"Status" -> "DryRunOK", "Target", "MatchedTodo", "OldStatus", "NewStatus", "CellPath", "Before" -> HoldComplete[...], "After" -> HoldComplete[...]|>`。実行時: `<|"Status" -> "OK"|"Failed", "Target", "MatchedTodo", "OldStatus", "NewStatus", "ReindexResult" -> _Association|Missing["NotRequested"]|>`
Options: `"DryRun"` -> True (既定、安全側。True は preview のみ), `"AutoReindex"` -> True (編集成功後に SourceVaultIndexNotebook を自動呼び出し、実行時のみ), `"AccessSpec"` -> Automatic (既定で write-eligible な `<|"AccessLevel" -> 0.7, "Environment" -> "Notebook", "AllowedSinks" -> {"LocalOnly", "Notebook"}|>` を渡す。NBAccess に渡される)

## 統合 hook (ClaudeAttach / Attachments / WorkerPrompt / ParseProposal)

### SourceVaultClaudeAttachIntegrationEnable[] → Association
ClaudeAttach 呼出時に SourceVault への side-channel ingest を行う hook を有効化する。既に有効なら noop。元の DownValue は保持され Disable で復元可。前提: claudecode.wl (`ClaudeCode`ClaudeAttach`) がロード済み。

### SourceVaultClaudeAttachIntegrationDisable[] → Association
hook を外し ClaudeAttach を元の DownValue に復元する。

### SourceVaultClaudeAttachIntegrationStatus[] → Association
現在の hook 状態を返す。Keys: Enabled, OriginalSaved, OriginalDVCount, HookTarget。

### SourceVaultGetClaudeAttachRefs[nb] → List
notebook nb に紐づいた ClaudeAttach side-channel ingest 記録の flat list を返す。各 entry: OriginalPathOrURL / ExpandedPath / SnapshotId / SourceId / ContentHash / IngestStatus / AttachedAt。引数なし (`SourceVaultGetClaudeAttachRefs[]`) で EvaluationNotebook[] を使う。

### SourceVaultClaudeAttachmentsIntegrationEnable[] → Association
`ClaudeAttachments[]` 呼出時に戻り値を List of paths から Association list に拡張する hook を有効化する。各 Association に cached path / source / metadata + SourceVault の SnapshotId / SourceId / ContentHash / IngestStatus が join される。前提: `ClaudeCode`ClaudeAttachments` がロード済み。

### SourceVaultClaudeAttachmentsIntegrationDisable[] → Association
hook を外し ClaudeAttachments を元の DownValue に復元する。

### SourceVaultClaudeAttachmentsIntegrationStatus[] → Association
現在の hook 状態を返す。

### SourceVaultWorkerPromptIntegrationEnable[] → Association
ClaudeOrchestrator の A5 hook に SourceVault context 注入関数を登録し、worker prompt 構築時に吹き出されるようにする。前提: ClaudeOrchestrator.wl に A5 hook が追加済み。トリガー: task["SourceSpans"] (明示指定) + ClaudeAttach 履歴 (自動検出)。

### SourceVaultWorkerPromptIntegrationDisable[] → Association
A5 hook の定義をクリアし、ClaudeOrchestrator は A5 hook をスキップする。

### SourceVaultWorkerPromptIntegrationStatus[] → Association
現在の A5 hook 状態を返す。

### $SourceVaultWorkerPromptAutoDetect
型: Boolean, 初期値: True
A5 hook 有効時の自動検出 ON/OFF。True: ClaudeAttach 履歴から SnapshotId を自動検出して注入。False: task["SourceSpans"] 明示指定のみ使用。

### SourceVaultParseProposalIntegrationEnable[] → Association
ClaudeOrchestrator の A6 hook に parseProposal post-processing 関数を登録し、LLM 応答内の `<source>snap-...</source>` / `<source>src-...</source>` XML タグを抽出して parseProposal の戻り値 Association に `"SourceVaultRefs"` キーを追加する。前提: ClaudeOrchestrator.wl に iApplyA6Hook + A6 hook 呈入し済み。

### SourceVaultParseProposalIntegrationDisable[] → Association
A6 hook の定義をクリアし iApplyA6Hook を no-op に戻す。

### SourceVaultParseProposalIntegrationStatus[] → Association
現在の A6 hook 状態を返す。

## ComfyUI アダプタ (on-demand load)

依存: [SourceVault_comfyui](https://github.com/transreal/SourceVault_comfyui) (`SourceVault_comfyui.wl`、$packageDirectory 配下)。BeginPackage には追加せず ForbiddenHead-safe な auto-load stub 経由でロードする。

### SourceVaultComfyUIEnsureLoaded[] → Association
`SourceVault_comfyui.wl` をオンデマンドでロードする (冪等)。ClaudeEval 生成コードは `Get` が forbidden head のため、直接 Get せずこの関数 (または任意の auto-load 対応 SourceVaultComfyUI* エントリポイント) を呼ぶこと。`SourceVaultComfyUIGenerateToNotebook` / `SourceVaultComfyUIServerWorkflowsView` / `SourceVaultComfyUIImportServerWorkflow` 等の呼び出し時は、アダプタ未ロードなら自動でこの関数を呼んでから再ディスパッチする auto-load stub が効くため、通常は明示呼び出し不要。
→ `<|"Status" -> "AlreadyLoaded"|"Loaded"|"Error", "Reason" -> _, "Path" -> _|>`

## DirectiveRepository / HarnessMaterialization

依存: `ClaudeDirectives`` (BeginPackage には追加せず各関数が遅延 Needs でロード)。

### SourceVaultRegisterDirectiveRepository[root] → Association
Claude Directives リポジトリ (ディレクトリ) を DirectiveRepository source として登録する。RepoId はリポジトリ root パスから決定的に導出される。
返却キー: `"Status"`, `"RepoId"`, `"Root"`, `"Path"`, `"Registration"`

### SourceVaultIndexDirectiveRepository[root] → Association
Claude Directives リポジトリを index する。`ClaudeDirectives`` でファイルインベントリと manifest hash を計算し DirectiveRepository snapshot record を書く。未登録なら自動登録。
返却キー: `"Status"`, `"RepoId"`, `"SnapshotId"`, `"ManifestHash"`, `"FileCount"`, `"Path"`, `"Snapshot"`

### SourceVaultDirectiveRepositoryStatus[root] → Association
リポジトリの登録有無、snapshot 数、最新 snapshot の manifest hash がディスク上のリポジトリと一致するかを報告する。Status: `"NotRegistered"` | `"RegisteredNotIndexed"` | `"UpToDate"` | `"Stale"`。

### SourceVaultCurrentDirectiveSnapshot[root] → Association
リポジトリの最新 DirectiveRepository snapshot record を返す。無ければ `Status -> "NoSnapshot"`。

### SourceVaultDiffDirectiveSnapshots[old, new] → Association
二つの DirectiveRepository snapshot record (または snapshot ファイルパス) を RelativePath/ContentHash で比較する。
→ `<|"Status", "Added", "Removed", "Changed", "UnchangedCount", "ManifestHashChanged"|>`

### SourceVaultRegisterHarnessMaterialization[target, files, meta] → Association
materialize 済み harness を HarnessMaterialization bundle として登録する。target は `"Codex"` | `"ClaudeCLI"`。files は生成ファイルパスのリスト。meta は HarnessMode / DirectiveRoot / DirectiveRepositorySnapshotId / DirectiveRepositoryManifestHash / RuntimeEnvironmentHash / PermissionProfileHash / Generator を供給。bundle は SourceVault bundles ディレクトリに保存され SourceVaultBundleGet で読める。
→ `<|"Status", "BundleId", "Path", "Bundle"|>`

### SourceVaultDirectiveSnapshotStaleQ[bundle] → Association
HarnessMaterialization bundle の元になった Claude Directives snapshot が stale かを、bundle の DirectiveRepositoryManifestHash と現リポジトリ hash を比較して報告する。stale なら harness を再生成すべき。
→ `<|"Stale", "Reason", "RecordedManifestHash", "CurrentManifestHash"|>`

### SourceVaultHarnessRuntimeEnvironmentChangedQ[bundle, currentEnv] → Association
HarnessMaterialization bundle の runtime environment (permission profile / temp project path / attachments) が変化したかを報告する。currentEnv は事前計算済み PermissionProfileHash / RuntimeEnvironmentHash か、ハッシュ対象の生 PermissionProfile / RuntimeEnvironment association を持てる。runtime environment 変化は config.toml 再生成を要するが canonical snapshot を stale にはしない。