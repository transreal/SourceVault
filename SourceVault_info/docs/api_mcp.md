# SourceVault_mcp API リファレンス

パッケージ: `SourceVault` (コンテキスト `SourceVault`MCPPrivate` / `SourceVault`ObjectViewPrivate` は内部)
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_mcp.wl"]]`
役割: MCP tool schema 定義・dispatch・argument validation・provenance 付与。HTTP/JSON-RPC transport は Python proxy 側。service kernel から `SourceVaultMCPDispatch` を呼ぶ。FrontEnd/Notebook/NBAccess 非依存。結果は JSON 安全 (string/assoc/list/bool) に保つ。ただし `SourceVaultObjectData`/`SourceVaultObjectProperties` は例外 (Image/Dataset を返しうる内部 helper で、MCP tool には登録されない)。

## MCP dispatch / protocol

### $SourceVaultMCPProtocolVersion
型: String, 初期値: "2024-11-05"
`initialize` レスポンスで返す MCP protocol バージョン。

### SourceVaultMCPServerInfo[] → Association
`<|"name" -> "sourcevault", "version" -> "0.1.0"|>` を返す。

### SourceVaultMCPTools[] → List
MCP tool 定義 (name/description/inputSchema) のリストを返す (現在 26 tool)。一覧は次節「MCP tool 一覧」参照。

### SourceVaultMCPCallTool[name, args] → Association
tool を実行し MCP result `<|"content", "isError"|>` を返す。内部は `Switch[name, ...]` dispatch で各 tool を対応する内部関数に委譲、未知 tool は Failure ではなく `isError:true` の text ("Unknown tool: ...")。`args["_mcpClient"]` から `iMCPProvenance` (Actor/RequestChannel/InitiationType) を組み立て検索・deposit 系呼び出しの provenance に付与する。読み取り系 tool は `iSVRecordToolCall` で observed-read-max 用の監査ログを書く (§13.3/§13.4 の入力になる)。`sourcevault_deposit`/`sourcevault_workflow_write` は自前の append-only 監査ログを持つため対象外。mail/OOPS 系 tool は "CloudSafe"->True を下位関数に渡し私的コンテンツを除外する。

### SourceVaultMCPDispatch[method, params] → Association
MCP JSON-RPC の method (initialize/tools/list/tools/call/ping/notifications/initialized) を処理し JSON-RPC result 相当の Association を返す。`initialize` は `<|protocolVersion, capabilities-><|tools-><||>|>, serverInfo|>`、`ping`/`notifications/initialized` は `<||>`。未知 method は `Failure["MCPMethodNotFound", ...]` (proxy が JSON-RPC error に変換)。`params` 省略形 `SourceVaultMCPDispatch[method]` は `params -> <||>` 扱い。

## MCP tool 一覧 (SourceVaultMCPTools[] / SourceVaultMCPCallTool)

以下のうち主要 tool (`sourcevault_commit_log` / `sourcevault_catalog` / `sourcevault_search` / `sourcevault_get` / `sourcevault_request_access` / `sourcevault_access_status` / `sourcevault_feedback_submit` / `sourcevault_deposit` / `sourcevault_runtime_capabilities` / OOPS・mail thread tool) は本ドキュメントの各節で個別に詳述する。それ以外の残り tool をここにまとめる。

### filesystem / directive tool (実体はこのファイル内 local helper)
- `sourcevault_fs_list` {path} — allow-list root (`$packageDirectory` / `$ClaudeWorkingDirectory` / `$ClaudeAccessibleDirs`) 配下のディレクトリ一覧 (name/type/bytes/secret flag) を返す。実体 `iSVFSListDir`。read-only、root 外は不可。
- `sourcevault_fs_read` {path, maxBytes?} — allow-list root 配下の UTF-8 text file を読む。実体 `iSVFSReadFile`。`.env`/`*secret*`/`*credential*`/鍵・証明書ファイル/`.ssh` 等は拒否、size は server 上限で clamp。
- `sourcevault_directives` {kind:"rules"|"skills"|"root"|"all" = "all"} — Claude Directives (rules/skills/CLAUDE.md) を name/description/`sv://file` URI で一覧。実体 `iSVFSDirectivesList`。CLI/API クライアントが同一 directive set を共有できるようにする。全文取得は `sourcevault_fs_read`/`sourcevault_get` を別途叩く。
- `sourcevault_workflow_write` {path, content} — allow-list root の `SourceVault_workflows/` サブツリーへ UTF-8 text を書き込む (上書き・親ディレクトリ自動作成・1MiB 上限)。実体 `iSVFSWriteFile`。file 編集不可な API/LM Studio クライアント向け (Claude Code/Codex には不要)。write のため `iSVRecordToolCall` の観測ログ対象外。

### Orchestrator feedback 便利 tool (SourceVaultMCPSubmitFeedback の薄い wrapper)
- `sourcevault_orchestrator_help` {text, goal?, evidenceRefs?, sessionId?} — `Kind->"HelpRequest"` で記録するだけ。orchestrator を直接動かさない。
- `sourcevault_orchestrator_subtask` {text, goal?, suggestedRole?, suggestedCapabilities?, evidenceRefs?, sessionId?} — `Kind->"SubtaskProposal"` で記録するだけ。subtask を実際に spawn しない。

### Web 検索 / 非同期 job tool (実体は他パッケージ SourceVault_webingest 等、ここは thin wrapper)
- `sourcevault_web_search` {query, maxResults=10} — SearXNG 同期検索、title/url/snippet のみ (本文取得なし)。実体 `SourceVaultWebSearch`。
- `sourcevault_submit_web_search` {query, maxResults=10, fetchPages=False, maxFetch=3} — 非同期 web search job を投入 (fetchPages=True で上位ページの本文取得・clean-text 化)。実体 `SourceVaultWebSearchSubmit`。JobId を返し `sourcevault_job_status`/`sourcevault_job_result` で回収する。
- `sourcevault_job_status` {jobId} — job 状態 (Queued/Running/Succeeded/Failed) を返す。実体 `SourceVaultWebJobStatus`。
- `sourcevault_job_result` {jobId} — 完了 job の結果 (Results + fetched Document ごとの title/url/ExtractionStatus/CleanTextLength) を返す。未完了・失敗時はその旨を返す。実体 `SourceVaultWebJobResult`。
- `sourcevault_get_document` {snapshotRef} — 保存済み WebDocument のメタ (Url/Title/ContentHash/CleanTextLength/ExtractionStatus) を返す (本文は含まない)。実体 `SourceVaultLoadImmutableSnapshot`。

## パッケージコミット履歴ツール

### SourceVaultPackageCommitLog[packageName, opts]
本システムのパッケージのコミット履歴を `GitHubREST`GitHubCommitLog` 経由で取得し、JSON-safe なコンパクト形式で返す SourceVault ラッパー。`GithubRepositories/` は `.git` を持たないミラーのため履歴の正本は GitHub API。コミットメタデータのみ (コード本文なし) で cloud-safe (PrivacyLevel 0.0)。`sourcevault_commit_log` tool の実体。packageName が空・`/`\`..` を含む場合は `<|"Status"->"Denied","Reason"->"BadPackageName"|>`、`GitHubREST` 未ロードなら `<|"Status"->"Unavailable","Reason"->"GitHubRESTNotLoadable"|>`、非 String 引数は `<|"Status"->"Denied","Reason"->"BadArguments"|>`。
→ Association `<|"Status", "Package", "Count", "Commits" -> {<|sha, date, author, message|>..}, "PrivacyLevel"|>` (失敗時は `"Status"->"Failed"`, "Reason", "Message")
Options: "Since" -> None, "Until" -> None (ともに "YYYY-MM-DD" 等の日付), "MaxItems" -> 50 (300 に clamp)
例: `SourceVaultPackageCommitLog["SourceVault", "Since" -> "2026-06-20"]`

## OOPS メールスレッド検索ツール (SourceVault_oopsseed 露出)

ClaudeEval / LM Studio / Codex の自然文プロンプト (「○○のスレッドを探して」等) から OOPS メールコーパスのスレッド検索・閲覧を行う 3 tool。実体は [api_oopsseed.md](api_oopsseed.md) の `SourceVaultOOPS...` 関数群 (thin wrapper)。

- **`sourcevault_oops_status`** — OOPS コーパスを冪等ロードし状態 (`Loaded / MailCount / SessionCount / TopicCount / Files / SessionIndexBuilt / Scope`) を返す。検索前に一度呼んで初期化する。実体 `SourceVaultOOPSEnsureLoaded` + `SourceVaultOOPSStatus`。
- **`sourcevault_oops_search_threads`** {query, limit=10} — スレッド (mail session) を BM25 で検索し `{Session, Subject, Score, Snippet}` を返す。日本語・英語クエリ可。実体 `SourceVaultOOPSSearchThreads`。
- **`sourcevault_oops_thread`** {session} — 1 スレッド詳細 `{Session, Subject, SessionKind, MailCounters, MailCount, Digest, TopicLabels}` を返す (Digest = LLM 非依存の決定的要約, per-mail timeline 付き)。QuoteEdges は返却から除外 (compact)。未知 id は `isError:true`「Thread not found: …」。実体 `SourceVaultOOPSThread`。

**scope (負荷制御)**: 全コーパス (161 ファイル / 数千 session) を service カーネルで on-demand build すると重すぎる (session index = per-session TopicEnrichment)。既定 `SourceVault`$svOOPSMCPScope = {"oops 200506.txt"}` の bounded scope に絞る。初回 tool 呼び出しで ~10s (quote-table parse 込み) → 以降 cache。広げるには service カーネルで `$svOOPSMCPScope` を設定 (再起動 or `SourceVaultOOPSEnsureLoaded["Force"->True]` で反映)。

**privacy gate (§6.5.3)**: OOPS アーカイブは公開リスト (`OOPS Mailing List`) と私的リスト (`... Under Ground` = oops-ura) のメールが同一ファイルに混在する。MCP tool は cloud 到達し得るので、3 tool すべて **cloud-safe gate を常に適用**する:
- `search_threads` は厳格な release context `oops-corpus-cloud` (`DenyTags -> {NoCloudLLM, NoPublicExport, PrivateML}`) で検索し、私的リストスレッドを結果から除外する (`SourceVaultOOPSSearchThreads["CloudSafe" -> True]`)。
- `thread` は session が私的リストメールを含む場合 digest を出さず `{Released: false, Why: [...]}` を返す (`SourceVaultOOPSThread["CloudSafe" -> True]`。Thread は検索 gate を通らず直接 session を返すため個別に gate)。

notebook / local から直接 `SourceVaultOOPS...` を呼ぶ場合は既定 `CloudSafe -> False` でフルアクセス (私的スレッドも見える)。

## 一般メール構造化ツール (SourceVault_mailstructure 露出)

OOPS 以外の一般メール (univ 等 maildb) を返信/引用 session ＋ topic に構造化して検索する 3 tool。実体は [api_mailstructure.md](api_mailstructure.md) の `SourceVaultMailStruct...` 関数群 (thin wrapper)。

- **`sourcevault_mail_status`** — scope (`SourceVault`$svMailStructMCPScope = {mbox, period}`、既定 `{"univ", "202606"}`) のメールをロード → StructureMail → BM25 index を cloud PrivacyScope で lazy build し状態 (`Loaded / Scope / MailCount / SessionCount / VocabSize / IndexId`) を返す。検索前に一度呼ぶ。実体 `SourceVaultMailStructEnsureIndex`。
- **`sourcevault_mail_search_threads`** {query, limit=10} — session を BM25 で検索し `{Session, Subject, Score, Snippet}` を返す。実体 `SourceVaultMailStructSearchThreads`。
- **`sourcevault_mail_thread`** {session} — 1 session 詳細 `{SessionId, Subject, MailCount, Topics, CurrentDigest, HistoricalReferences, Released}` を返す。**digest は current session の結論と historical reference (過去メールの引用/前例/テンプレート) を分離** (§9)。実体 `SourceVaultMailStructThread`。

**privacy gate**: 3 tool すべて cloud-safe。(1) `search_threads` は私的/第三者メール (`ThirdPartyContent / NoCloudLLM / NoPublicExport / PrivateML` tag ∨ PrivacyLevel≒1.0) の session chunk を build-time release gate (`mailstruct-cloud`) で除外し検索でヒットさせない。(2) `thread` は session が私的メールを含む場合 digest を出さず `{Released: false, Why: ["PrivateMail"]}` を返す (二重防御)。notebook から直接呼ぶ場合は `CloudSafe -> False` でフルアクセス。

## URI 層 (spec §3.1)

### $SourceVaultURINamespaces
型: List, 初期値: {"object","chunk","artifact","hash","group","relation","snapshot","record","citation","file","packageapi","directive"}
sv:// URI の予約 identity namespace。data class (mail/web/pdf 等) は URI namespace でなく Class/MediaType/Kind sidecar に持つ。namespace arity: object/chunk/artifact/relation/record/citation/file/packageapi/directive → 1 segment、hash/snapshot → 2 segments、group → 2 segments。packageapi/directive は retrieval spec v0.3 §7.2 の stable opaque id (`sv://packageapi/<stableHash(pkg,symbol,auxName)>`、世代非依存)。

### SourceVaultParseURI[uri] → Association
sv:// URI または legacy ref (`blob:sha256:hex` / `snapshot:class:hex`) を解析する。純関数。
返値 key: Valid / Form("Canonical"|"LegacyInternal"|"Invalid") / Scheme / Namespace / Segments / Id / CanonicalURI / Input / Reason(Invalid 時)。未知 namespace/arity 不一致は `Valid->False`。

### SourceVaultBuildURI[namespace, id] → String|Failure
### SourceVaultBuildURI[namespace, {seg..}] → String|Failure
予約 namespace と arity を検証し percent-encoding 済みの正準 sv:// URI 文字列を返す。namespace/arity 不正は `Failure["UnknownURINamespace"|"URIArityMismatch"|"URIEmptySegment", ...]`。

### SourceVaultValidURIQ[uri] → True|False
uri が well-formed な sv:// URI または解決可能な legacy ref なら True。非 String は False。

### SourceVaultResolveURI[uri, opts]
URI を正規化し解決情報を返す。Phase A は構文正規化のみ (adapter による実 object 解決は後続 increment)。
→ Association または String ("Return"->"CanonicalURI" 時)
Options: "Return" -> "Association" ("CanonicalURI" 指定で canonical 文字列のみ返す), "AccessRequest" -> Automatic (将来 gate に渡す)
返値 key: CanonicalURI / AlternateURIs / Namespace / Class / Kind / Adapter / InternalStableId / ObjectSnapshotRef / ContentHash / ResolutionConfidence("Exact"|"Alias"|"Ambiguous"|"NotFound") / Input

### SourceVaultCanonicalURI[uri, accessRequest:Automatic] → String|Missing
`SourceVaultResolveURI[uri, "Return"->"CanonicalURI"]` の薄い wrapper。URI を key/edge/group member/SourceRef として保存する前に必ずこれで正規化する。

### SourceVaultURIForObject[objectOrRef, opts] → String|Missing
object/内部 ref から canonical sv:// URI を返す adapter hook。String 引数は `SourceVaultCanonicalURI` に委譲。Association 引数は "CanonicalURI" / "URI" / "Ref" / "BlobRef" key を順に参照する。adapter registry 経由の実 object 解決は後続 increment。

## sv:// object 解決 (SourceVault_objectview.wl 統合、FrontEnd 非依存)

MCP tool には登録されない (Image/Dataset を返しうるため JSON safety 契約の対象外) が、notebook/service 側から sv:// object の実体を引く共通 API。eagle enrichment は DownValues guarded (eagle 未ロードなら既定値にフォールバック)。

### SourceVaultObjectPrivacyLevel[uri] → Real
sv:// object の privacy level (0.0-1.0) を返す。snapshot は `SourceVaultSnapshotPrivacyLevel` 経由、eagle は item の PrivacyLevel (`SourceVaultEagleSummaryRow` 経由)、file は 0.0 (allow-list bridge)、それ以外/未ロード/無効 URI は既定 `$SourceVaultDefaultObjectPrivacyLevel` (既定 0.85)。

### SourceVaultObjectData[uri] → Association|Image|String|Failure
sv:// が指す実オブジェクトデータを返す。snapshot → 検証済み assoc、eagle 画像 → Image、eagle 他 → `<|FilePath, FilePathPortable, Item|>`、file → 内容 (画像なら Image、それ以外 text)。解決できなければ Failure ("InvalidURI"/"BadSnapshotURI"/"SnapshotNotFound"/"EagleUnavailable"/"EagleItemNotFound"/"NoPath"/"UnsupportedKind")。

### SourceVaultObjectProperties[uri] → Association
sv:// オブジェクトの全プロパティを返す。共通 key: URI/Namespace/Kind/PrivacyLevel/PrivacySource。eagle: Id/Name/Ext/Tags/Folders/Annotation/URL/Size/ModificationTime/FilePath(このマシンの絶対パス)/FilePathPortable({"$dropbox",...} のシンボリックパス。別 PC でも解決可。ルート外は {"<ABS>",path})/EagleRaw、画像なら追加で ImageDimensions/FileFormat/FileByteCount/Exif。snapshot: `Snapshot`+元フィールド名の key 群 + PrivacyRecord。file: FileByteCount/FileFormat/FileDate (画像なら ImageDimensions/Exif も)。無効 URI は `<|Valid->False, Reason|>`。

## Adapter registry (spec §4.1)

### SourceVaultRegisterMCPDataAdapter[name, spec] → Association|Failure
data adapter を登録する。spec 必須: "Kinds" ({_String..})。
任意 spec key: "Capabilities" (<|cap->bool|>)、"Search"/"Resolve"/"Read"/"SummaryRow"/"Metadata"/"Authorize"/"URIForObject"/"OwnsURIQ" 関数 (OwnsURIQ は `Function[parsedURI]->True|False` で `sourcevault_get` の URI 所有 adapter 選定に使う)、"Available" (bool)、"AvailableProbe" (Function[])、"RequireGrantFor" ({_String..})、"UnavailableReason"、"BodyGrantRequired" (bool、既定 True。False で view=body を grant なしで解放 — PublicDoc adapter 用、release gate は通す。R-spec §5.6)、"ExtraViews" (<|viewName -> Function[parsed, accessRequest]|>、adapter 固有 view。packageapi: contract/scaffolded/guided)、"FilterKeys"/"FilterExamples" ({_String..}、catalog に露出する adapter 固有 filter discovery。packageapi の packages 等)。
Capabilities key: Search / ReadMetadata / ReadSummary / ReadContext / ReadBody / DepositArtifact / ResolveObjectURI / SemanticSearch / MetadataFilter。未指定 key は False で補完する。
返値: `<|"Status"->"OK", "Name", "Kinds", "Capabilities"|>`。Kinds 不正は `Failure["AdapterMissingKinds"]`、spec 非 Association は `Failure["AdapterSpecNotAssociation"]`。

### SourceVaultListMCPDataAdapters[] → {String..}
登録済み adapter 名のリスト (ソート済み) を返す。

### SourceVaultResolveMCPDataAdapter[name] → Association|Missing
登録済み adapter spec を返す。未登録は `Missing["AdapterNotRegistered"]`。

## Access model 正規化 (spec §2.1 / §2.2 / §2.4)

### SourceVaultNormalizePrincipal[input, opts]
MCP request 主体を Principal 連想に正規化する。ClientName は自己申告可 (provenance 扱い)。authoritative ProviderClass は opts "Trusted" からのみ採用し、無ければ "Unknown" (release 判定に client 自己申告は使わない)。有効 ProviderClass は {CloudLLM, LocalLLM, PrivateLLM}。
→ Association
Options: "Trusted" -> <||> (transport/grant/main-kernel で確立した authoritative 情報)
返値 key: Kind / ClientName / ProviderClass / ProviderClassTrusted / AssertedProviderClass / SessionId / UserPresent

### SourceVaultNormalizeAccessRequest[spec, opts]
MCP tool call を AccessRequest 連想 (spec §2.2) に正規化する。"AccessLevel" を正準とし "MaxPrivacyLevel" を入力互換 alias とする。ScopePolicy は既定 (RequireAccessTags {}, AllowAccessTags All, DenyAccessTags {}, Untagged "MetadataOnly") を補完する。
→ Association
Options: "Principal" -> Automatic
返値 key: Action / Principal / Purpose / Sink / ReleaseContext / Provider / ModelId / ModelIntent / AccessLevel / MaxPrivacyLevel / ScopePolicy / RequestedProjection / RequestedKinds / SessionGrant / CreatedAtUTC

### SourceVaultEffectiveAccessLevel[{ceiling..}]
指定 access ceiling 群の最も厳しい値 (Min) を返す (spec §2.4)。Automatic/Missing/None 等の非 numeric は無視。alias を重複して渡してよい (Min は冪等)。numeric が皆無なら opts "Default" を返す。
→ Real
Options: "Default" -> 0.5 (cloud 安全境界)

## Catalog (spec §9.2 / §16)

### SourceVaultMCPCatalog[opts]
登録済み adapter の catalog を JSON 安全な連想で返す。各 adapter record: name/kinds/available/capabilities/requiresGrantFor、adapter 固有の filterKeys/filterExamples があれば付加、unavailable なら unavailableReason を付加。トップに defaultReturnFormats ({"compactText","structuredJson","referencesOnly"})。可用性は spec "AvailableProbe" (Function[]) があれば動的評価、無ければ静的 "Available"。`sourcevault_catalog` tool の実体。
→ Association
Options: "IncludeUnavailable" -> True

## AccessProfile / model 別アクセス設定 (spec §2.5)

### SourceVaultSetModelAccessProfile[provider, intent, modelId, profile] → Association|Failure
model 別 AccessProfile を PrivateVault/config/mcp-access-profiles.json に永続化する (AccessProfileRef 方式・GitHub 非公開)。modelId に "*" を渡すと provider/intent の wildcard profile。
profile key: MaxAccessLevel / AllowedSinks / AllowedOperations / AllowedProjections / DeniedProjections / ScopePolicy / PurposeAllowed / RequireGrantFor / Audit / EndpointRef / TrustDomain。返値は正規化済み profile。PrivateVault 未解決/書込失敗は Failure。

### SourceVaultGetModelAccessProfile[provider, intent, modelId] → Association|Missing
保存済み AccessProfile を返す。未登録は `Missing["AccessProfileNotFound"]`。

### SourceVaultListModelAccessProfiles[] → {String..}
保存済み AccessProfile の ProfileId (provider:intent:modelId 形式) リストを返す。

### SourceVaultResolveAccessProfile[request] → Association
request に対する実効 AccessProfile を解決する。解決順: exact (provider:intent:modelId) → wildcard (provider:intent:* / provider:*:*) → default。default は trust-domain cap (cloud 0.49 / local 1.0) と安全側 ScopePolicy で、profile 未登録時に既存 ceiling を変えない。
request key: Provider / ModelId / ModelIntent / TrustDomain
返値: `<|AccessProfileRef, Source("Exact"|"Wildcard"|"Default"), Profile|>`

`SourceVaultMCPSearch`/`SourceVaultMCPGet` はこの解決結果 (Source が "Exact"/"Wildcard" の時のみ) を `iSVResolveScopeForRequest` (§2.6) 経由で request の ScopePolicy に合成する。deny-tags は union (より厳しい方が勝つ)、require-tags は union、allow-tags は intersection、untagged 厳しさは max。Source が "Default" (未登録モデル) の場合は非破壊のため合成しない。

## Prompt delivery profile (spec §2.5a)

### SourceVaultResolvePromptDeliveryProfile[request, opts]
model/実行環境/MCP 可否から PromptDeliveryProfile (spec §2.5a) を返す。TrustDomain/TrustCeiling は opts "Trusted" と provider 級 cap (NBGetProviderMaxAccessLevel, guarded) から server 側で決め、自己申告では緩めない。
→ Association
Options: "Trusted" -> <||>, "ResolveAccessProfile" -> True
request key (すべて advisory): provider / modelId / clientKind / mcpToolsVisible / sourcevaultMcpEnabled / canCallMcpDuringInference / localFolderReadableByTool / localPackageDirectoryReadable
返値 key: DeliveryProfileId / Provider / ModelId / ClientKind / TrustDomain / LocalPackageDirectoryReadable / LocalFolderReadableByTool / MCPAvailable / SourceVaultMCPEnabled / SourceVaultMCPTools / CanCallMCPDuringInference / CanUseSVURIInPrompt / InputsFullyMediatedBySourceVault / PromptStrategy / TrustCeiling / UnknownInputFloor / RequireReviewOnUnmediatedInput / AccessProfileRef / AccessProfileSource / Warnings
PromptStrategy: "MCPDeferred" | "InlineContext" | "Hybrid" | "LocalToolRefs" | "NoSourceVault"
例: `SourceVaultResolvePromptDeliveryProfile[<|"provider"->"anthropic","modelId"->"claude-sonnet-4-6","canCallMcpDuringInference"->True,"sourcevaultMcpEnabled"->True|>]`

### SourceVaultMCPRuntimeCapabilities[args] → Association
`sourcevault_runtime_capabilities` tool の実体。`SourceVaultResolvePromptDeliveryProfile` を JSON 安全な camelCase 出力に整形する (spec §16)。
返値 key: deliveryProfileId / provider / modelId / trustDomain / mcpAvailable / sourcevaultMcpEnabled / canCallMcpDuringInference / canUseSvUriInPrompt / promptStrategy / inputsFullyMediatedBySourceVault / outputTrustCeiling / unknownInputFloor / requireReviewOnUnmediatedInput / accessProfileRef / warnings

## LLM job trace / output privacy (spec §13.3 / §13.4)

### SourceVaultMintTraceId[kind] → String
### SourceVaultMintTraceId[] → String
trace 用 opaque correlation id を生成する。引数なしは "trace"。kind → prefix: "batch"→svbatch- / "job"→svjob- / "trace"→svtrace- / "session"→svsession- / "work"→svwork- / "call"→svmcp-。未知 kind は svid-。capability ではなく漏れても権限を与えない。trusted host が mint する想定 (client tool 引数からは mint させない)。

### SourceVaultNormalizeMCPCallRecord[spec] → Association
MCP call 監査 record (spec §13.3) を既定補完して正規化する。
spec/返値 key: CallId / BatchId / JobId / TraceToken / SessionId / Tool / ArgumentURIs / ReleasedURIs / ReleasedProjection / MaxReleasedPrivacy / ProjectionPrivacyBasis / AccessGrantId / Decision / LinkConfidence / StartedAtUTC / FinishedAtUTC
MaxReleasedPrivacy は released projection 自身の privacy (§4.1)。ProjectionPrivacyBasis: "Recomputed" | "SourcePrivacyFallback"。LinkConfidence: "Explicit" | "Metadata" | "Heuristic" | "Unlinked"。

### SourceVaultObservedReadMax[records, opts]
privacy 会計の安全側 observed-read 上限 (Max) を返す。heuristic link も過小評価回避のため Max の上側に含める (spec §13.4 / P3 / P4)。numeric 皆無なら opts "Default"。
→ Real
Options: "BatchId" -> Missing[] (trusted grouping filter), "SessionId" -> Missing[], "Default" -> 0.0

### SourceVaultEstimateOutputPrivacy[jobSpec, opts]
LLM 出力の OutputPrivacyEstimate (spec §13.4) を純関数で返す。PrivacyLevel は観測入力の Max (監視外 channel 時は UnknownInputFloor へ引き上げ)。TrustCeiling では削らない (T1: sink/env は egress 時の NBAuthorize で加える)。declassification ではない。
→ Association
Options: "Records" -> {} (MCPCall record リスト)
jobSpec key: DeliveryProfile / PromptPrivacyMax / BatchObservedReadMax / SessionObservedReadMax / LocalToolReadPrivacyMax / UserUploadPrivacyMax / ExplicitUserPromptPrivacyMax / InputsFullyMediatedBySourceVault / UnknownInputFloor / TrustCeiling / TrustDomain
返値 key: PrivacyLevel / TrustCeiling / UnknownInputFloor / InputsFullyMediatedBySourceVault / RequireReview / Confidence("High"|"Medium"|"Low") / ObservedInputMax / Basis / PrivacyInheritancePolicy

## MCPCall 永続化 / batch mint (spec §13.3)

### SourceVaultStartBatch[spec] → Association
### SourceVaultStartBatch[] → Association
prospective な BatchId を mint する (spec §13.3 / N2)。trusted host (main kernel/orchestrator) が呼ぶ前提。client tool 引数からは mint させない。LocalState/hotlog/mcp_batches に marker を記録する。SessionId 未指定なら mint する。
spec key: SessionId / Title / DeliveryProfileId / ExpectedJobCount
返値: `<|BatchId, SessionId, Status->"Running", StartedAtUTC, MintAuthority->"TrustedHost"|>`

### SourceVaultRecordMCPCall[spec] → Association
MCP call 監査 record を正規化し LocalState/hotlog/mcp_calls/YYYY-MM.jsonl へ append-only 記録する (spec §13.3)。best-effort (LocalState 未解決や書込失敗でも応答を壊さない)。単一書き手は service kernel。
返値: `<|CallId, Recorded(bool), MaxReleasedPrivacy|>`

### SourceVaultMCPCallsRecent[opts]
記録済み MCPCall を時刻順に返す。`SourceVaultObservedReadMax` の入力として使う。
→ List
Options: "BatchId" -> All, "SessionId" -> All, "Limit" -> Automatic

## 検索契約層 (spec §5 / §6 / §8 / §11)

### SourceVaultNormalizeSearchSpec[spec] → Association
MCP の SearchSpec (spec §5.1) を既定補完して正規化する。kinds に "all" があれば個別指定を無視 (既定 {"all"})。filters の accessLevelMax を正準、privacyMax を alias とする。scope 既定: releaseContext->None, topicTags->{}, objectRefs->{}, requireAccessTags->{}, denyAccessTags->{}, untagged->"MetadataOnly"。return 既定: format->"compactText", includeSnippets->True, includeMetadata->True, maxCharsPerResult->800。top level 既定: limit->20, offset->0, sortBy->"score"。`methods` 既定は `{"keyword", "metadata"}`（後方互換）。`"bm25"` を含めると search adapter が日本語 BM25 + entity OR-match の `KeywordBM25V1` index を選ぶ（§8.2）。principal は正規化しない (呼び出し側 `SourceVaultNormalizePrincipal` が別途担当)。
→ Association `<|query, kinds, scope, targetFields, methods, filters, limit, offset, sortBy, return, purpose, sessionGrant|>`

### SourceVaultNormalizeSearchResult[row, opts] → Association
adapter の生 result row を SearchResult (spec §6) に正規化する。URI を canonical 化し Summary/Snippet を MaxChars で truncation する。未開示は `Missing["NotReleased"]` 等で示す。IncludeMetadata->False でも scope gating (§2.6) に必要な AccessTags は `<|"AccessTags"->at|>` として残し、それ以外の Metadata は `Missing["NotRequested"]`。release gate 判定は呼び出し側で行う。
Options: "Adapter" -> Missing[], "Kind" -> Missing[], "ReleasedProjection" -> "metadata", "IncludeSnippets" -> True, "IncludeMetadata" -> True, "MaxChars" -> 800
返値 key: ResultId / ObjectRef / URI / Adapter / Kind / Title / Summary / Snippet / Citation / Score / MatchedFields / Metadata / Privacy(Level/Class/ReleasedProjection) / Access(Decision/Why/AccessHandle) / Provenance(RequestTimeGateReevaluated/PolicyDigestAtRequest)

### SourceVaultRenderSearchResults[results, format] → String|List
正規化済み SearchResult のリストを返却形式に整える。
format: "compactText" (既定 fallback。番号付きブロックで title/ref/snippet、Access.Decision が Permit 以外なら `[access: <Decision>]` を追記) | "referencesOnly" (URI/Citation.url + Citation.label のみの番号付き text) | "structuredJson" (structured list をそのまま返し tool 層で JSON 化) (spec §8)

### SourceVaultMCPSearch[searchSpec, opts]
SearchSpec を正規化し kinds に適合する available な search adapter を選び、各 adapter search → SearchResult 正規化 → per-result release gate (SourceVaultMCPReleaseGate) → limit/offset → render する横断検索 orchestration (spec §11.1)。`sourcevault_search` tool の実体。
**method=bm25 (§8.2)**: `methods` に `"bm25"` があり明示 `scope.index` が無ければ、search adapter は `scope.bm25Index` → 慣習 `"<releaseContext>-bm25"` の順で `KeywordBM25V1` index を選ぶ。実際の BM25/bigram は index の `IndexKind` で `iNativeSearch` が dispatch する（method は advisory）。結果 Metadata に `RetrievalKind`（"KeywordBM25"/"KeywordBigram"）を載せる。query が英語・doc が日本語でも entity term で一致する（表記非一致/OOV 回復）。
→ Association
Options: "Principal" -> Automatic, "Trusted" -> <||>, "AccessProfile" -> Automatic (登録済み AccessProfile の ScopePolicy を §2.6 合成、`iSVResolveScopeForRequest` 経由)
返値 key: Results / Count / TotalBeforeLimit / Warnings(adapter 別の非致命的警告、例: UnknownPackage) / ReleaseGated(Deny で除外された件数) / Screened(Screen 降格で summary/snippet を落とされ最終ページに残った件数) / EffectiveAccessLevel / Adapters / Format / Rendered / AccessRequest

### SourceVaultMCPGet[uri, opts]
単一の sv:// URI を解決し、所有 adapter (`OwnsURIQ` で選定) の Resolve で低漏洩メタ/サマリー projection を取り、SourceVaultMCPReleaseGate で出口 gate して返す (spec §11.2)。既定 View="summary" は body/raw/attachment を含めず requiresGrant を示す。`sourcevault_get` tool の実体。
View="body"|"raw"|"context" は `iSVMCPGetBody` に委譲し AccessGrant による本文解放を試みる (Phase D)。`iSVGrantPermitsView` が Grant の Valid、AllowedFields/AllowedActions("ReadBody")、AllowedKinds、AllowedObjectRefs を確認し、cloud sink への body 送出は有効な Grant があっても常に拒否 (Why->"CloudSinkBlockedForBody")、PrivacyLevel<=Grant.MaxAccessLevel も要る。Grant 未指定/不足時は `Why->"GrantRequired"` 等 + `HowToProceed` ヒントを返す。
例外 (F6): adapter が "BodyGrantRequired"->False を宣言する PublicDoc 系 (packageapi) は view=body を Grant なしで解放 (`Access.Why -> {"GrantFreePublicDoc"}`、release gate は通す)。adapter の "ExtraViews" に登録された view (packageapi: contract=機械可読契約+AuditStatus / scaffolded / guided=粒度 tier 描画) はその projection を返す。
→ Association (View/判定枝で形が可変)
Options: "Principal" -> Automatic, "Trusted" -> <||>, "AccessLevel" -> Automatic (この呼び出し限定の access ceiling)、"ReleaseContext" -> None (`SourceVaultReleaseContextSpec` で MaxPrivacyLevel を解決し実効上限に反映)、"Grant" -> None (body/raw/context view のみ検証される AccessGrant)、"View" -> Automatic ("summary"(既定)|"body"|"raw"|"context"|adapter ExtraViews)、"AccessProfile" -> Automatic (Search と同じ §2.6 scope 合成)
返値 key (共通): URI / Found / Released。summary 系はさらに Adapter / Result(Permit時) / Access / RequiresGrantFor / Why / EffectiveAccessLevel / AccessRequest。body/raw/context/ExtraViews はさらに Adapter / View / Result / Access / GrantId / Why(失敗時) / HowToProceed(Grant不足時)。

### SourceVaultMCPReleaseGate[result, accessRequest] → Association
正規化済み SearchResult を返却してよいか判定する (spec §11, §2.4)。Decision は "Permit" | "Screen" | "Deny" の3種。
判定順: (1) scope 判定 (`AccessTags` vs ScopePolicy) が Deny → Deny (Why: "DenyTagIntersect"/"MissingRequiredTags"/"UntaggedDenied"/"TagNotInAllow" 等)。(2) Privacy.Level(数値) > EffectiveAccessLevel → Deny (Why->"PrivacyExceedsAccessLevel")。(3) cloud sink (ProviderClass CloudLLM/Unknown + Sink MCPResponse) で Level>=0.5 → Deny (Why->"CloudSinkHardCap")。(4) scope 判定が Screen (untagged かつ ScopePolicy Untagged->"MetadataOnly") → Screen (Why->"UntaggedMetadataOnly", ReleasedProjection->"metadata")。呼び出し側 (`SourceVaultMCPSearch`/`SourceVaultMCPGet`) は Screen を `iSVDowngradeResult` で Summary/Snippet を `Missing["ScreenedMetadataOnly"]` に降格して返す。(5) それ以外 (Privacy.Level が数値でない=web/Public 等 search 自己 gate 済) → Permit。release context の MaxPrivacyLevel と request AccessLevel の最小を実効上限にする。
返値: `<|"Decision"->"Permit"|"Screen"|"Deny", "Why"->{...}, "Level"(該当時), "EffectiveAccessLevel"(該当時), "ReleasedProjection"(Screen時)|>`

## AccessGrant / 申請・承認 (spec §2.3 / §11.3, Phase D)

### SourceVaultMCPEnsureGrantKey[] → Association|Failure
LocalState/secrets/sourcevault-grant-signing-key.json に grant 署名用 shared secret (HMAC-SHA256 鍵、32byte) が無ければ生成する (main↔service 共有・machine-local で非同期。MCP transport token とは別物)。既定 KeyId "grant-hmac-v1"。
返値: `<|KeyId, Created(bool), Path|>`。LocalState 未解決なら `Failure["LocalStateUnresolved"]`。

### SourceVaultMCPMintAccessGrant[spec] → Association|Failure
§2.3 の AccessGrant を発行し HMAC 署名して返す (main kernel)。
spec key: Principal(既定<||>) / AllowedActions(既定{}) / AllowedKinds(既定{}) / AllowedObjectRefs(既定{}) / MaxAccessLevel(既定0.5) / AllowedFields(既定{}) / Purpose(既定"") / Sink(既定"LocalOnly") / TTLSeconds(既定900。負数も許容=即時失効テスト用) / IssuedBy(既定"NBAccess") / MaxPrivacyLevel(数値の時のみ出力に含む)。
返値 key: GrantId("grant-"+UUID) / IssuedBy / Principal / AllowedActions / AllowedKinds / AllowedObjectRefs / MaxAccessLevel / AllowedFields / Purpose / Sink / ExpiresAtUTC / RevocationEpoch / KeyId / (MaxPrivacyLevel) / Digest(canonical JSON の SHA256) / Signature(同 HMAC)。署名鍵が無ければ `Failure["GrantKeyUnavailable"]`、crypto 未ロードは `Failure["CryptoUnavailable"]`。

### SourceVaultMCPVerifyAccessGrant[grant] → Association
grant の Digest/Signature/期限/RevocationEpoch を検証する (service-loadable; 純 crypto、NBAccess 非依存)。
成功: `<|Valid->True, Why->{}, GrantId, Principal, AllowedActions, AllowedKinds, AllowedObjectRefs, AllowedFields, MaxAccessLevel, Sink, ExpiresAtUTC|>`。
失敗: `<|Valid->False, Why->{reason}, ...|>`。reason は判定順に "CryptoUnavailable" / "KeyUnavailable" / "KeyIdMismatch" / "DigestMismatch" / "SignatureMismatch" / "Expired" / "Revoked" / (非 Association 入力は "NotAssociation")。

### SourceVaultMCPRevokeAllGrants[] → Association
revocation epoch を +1 し、これ以前に mint した全 grant を無効化する (machine-local カウンタ)。返値: `<|Status->"Revoked", Epoch|>`。LocalState 未解決は `Failure["LocalStateUnresolved"]`。

### SourceVaultMCPRequestAccess[spec] → Association
access grant 申請を LocalState の承認 queue (`hotlog/mcp_access_requests/YYYY-MM.jsonl`) に append-only 保存する (service)。MCP client は status を poll する (`sourcevault_request_access` tool の実体)。
spec key: Principal(既定<||>) / Action(既定"ReadBody") / ObjectRefs(既定{}) / Kinds(既定{}) / Fields(既定{}) / Purpose(既定"") / Sink(既定"LocalOnly") / RequestedAccessLevel / ReleaseContext / TTLSeconds(既定3600)。
返値: `<|RequestId("req-"+UUID), Status->"Pending", ExpiresAtUTC, HowToProceed|>`。LocalState 未解決/書込失敗はそれぞれ `Failure["LocalStateUnresolved"|"QueueWriteFailed"]`。

### SourceVaultMCPAccessStatus[requestId] → Association
申請の状態を返す (service; `sourcevault_access_status` tool の実体)。decision sidecar (`status/<requestId>.json`) を優先参照し、無ければ pending queue にフォールバック。grant 期限切れは "Expired" 扱い。
返値: `<|Status->"Pending"|"Granted"|"Denied"|"Expired"|"NotFound", RequestId, Grant(Granted時), Reason(Denied時)|>`

### SourceVaultMCPPendingAccessRequests[opts] → List
未決 (decision sidecar 未作成) の申請一覧を、生の request record (RequestId/Type/RequestedAtUTC/ExpiresAtUTC/Principal/Action/ObjectRefs/Kinds/Fields/Purpose/Sink/RequestedAccessLevel/ReleaseContext/Status:"Pending") のまま返す (main kernel helper)。
Options: "IncludeExpired" -> False (True で期限切れ申請も含める)

### SourceVaultMCPApproveAccessRequest[requestId, opts] → Association
申請を承認して AccessGrant を mint し status sidecar に記録する (main kernel helper)。未指定 (Automatic) の各 option は申請値をそのまま引き継ぐ (緩める想定はしない: AllowedActions 既定 {申請Action}、AllowedKinds/AllowedObjectRefs/AllowedFields も申請値、MaxAccessLevel 既定は申請 RequestedAccessLevel か 0.5)。
Options: "MaxAccessLevel" -> Automatic, "AllowedActions" -> Automatic, "AllowedKinds" -> Automatic, "AllowedObjectRefs" -> Automatic, "AllowedFields" -> Automatic, "Sink" -> Automatic, "TTLSeconds" -> 900, "ReleaseContext" -> Automatic
承認前 gate: (a) AllowedObjectRefs を revocation status で確認し失効 ref があれば自動 Deny (sidecar Reason->"RevokedObjectRefs"、`Failure["RevokedObjectRefs"]` を返す)。(b) ReleaseContext が解決可能なら MaxAccessLevel をその MaxPrivacyLevel で Min にさらに制限。
返値: 発行した grant Association そのもの (`SourceVaultMCPMintAccessGrant` と同じ key 構成)。RequestId 不明は `Failure["RequestNotFound"]`。

### SourceVaultMCPDenyAccessRequest[requestId, reason_:""] → Association
申請を却下し status sidecar (`Status->"Denied"`, Reason, DecidedAtUTC) に記録する (main kernel helper)。存在確認はしない (未知/期限切れ id も却下できる)。
返値: `<|Status->"Denied", RequestId|>`。LocalState 未解決は `Failure["LocalStateUnresolved"]`。

## Feedback bridge (Phase F / §12)

### SourceVaultMCPSubmitFeedback[spec] → Association
§12.3 FeedbackEnvelope を LocalState/hotlog/mcp_feedback へ append-only 記録する (service)。PrivacyLevel は自己申告だけでなく同一 Session/Batch の observed-read max (`SourceVaultObservedReadMax[SourceVaultMCPCallsRecent[...]]`) を継承し Max 合成する (§12.3)。effective PrivacyLevel >= 0.5 は RequireReview=True。MVP は記録のみ (Orchestrator 側 queue/accept/subtask 昇格は将来)。
spec key: Kind("HelpRequest"|"SubtaskProposal"|"AccessRequest"|"Critique"|"Correction"|"SessionNote"、既定"SessionNote") / Principal / Payload(Text/Goal/SuggestedRole/SuggestedCapabilities/RequestedData/EvidenceRefs) / SessionId(既定"Unknown") / BatchId / PrivacyLevel(自己申告、既定0.5) / RequireApproval(既定False)
未知 Kind は `Failure["InvalidFeedbackKind"]`。LocalState 未解決/書込失敗はそれぞれ `Failure["LocalStateUnresolved"|"FeedbackWriteFailed"]`。
返値: `<|EventId, Status->"Queued", Kind, PrivacyLevel, RequireReview|>`

### SourceVaultMCPFeedbackQueue[opts] → List
記録済み feedback event (append 時の envelope そのまま: EventId/Type/Kind/From/Target/BatchId/Payload/PrivacyLevel/PrivacyBasis/RequireReview/CreatedAtUTC/RequireApproval/Status) を CreatedAtUTC 昇順で返す (main kernel helper)。
Options: "Kind" -> All, "Status" -> All, "Limit" -> Automatic (非負整数指定時は末尾 N 件=直近 N 件)

## Artifact deposit (spec §10.7 / §11.5)

### SourceVaultMCPDeposit[spec] → Association
LLM 生成 artifact の append-only deposit。`sourcevault_deposit` tool の実体。
spec key:
- mode: "plan" (書き込まず予定 policy を返す) | "commit" (append-only 保存)
- kind / mediaType / content (commit時。text または `<|"encoding"->"base64","data"->...|>`)
- policy: `<|privacyLevel, accessTags, denyTags, releaseContext|>`
- provenance: `<|authoredBy(modelId/provider), inputRefs, citationRefs, promptRefs|>` (各 ref は `SourceVaultCanonicalURI` で正規化・重複除去し `sourceRefs`/`SourceRefRoles` にまとめる)
- title/filename (commit時)
- SessionId / BatchId / idempotencyKey (省略時は contentSHA256 を代用)
- Grant: AccessGrant (commit 時の DepositArtifact 権限検証に使用)
- Approved: True (RequiresApproval 回避用)

権限判定 (commit のみ): (1) `spec.Grant` が Valid かつ AllowedActions に "DepositArtifact" を含めば Via->"Grant"。(2) 無ければ ModelIntent "deposit" で `SourceVaultResolveAccessProfile` を解決し AllowedOperations に "DepositArtifact" があれば Via->"Profile"。既定 profile の AllowedOperations ({Search,ReadSummary,ReadContext}) はこれを含まないため fail-closed。

PrivacyLevel = Max[要求値(policy.privacyLevel), Session/Batch の observed-read max]。sourceRefs が非空なのに observed max が 0.0 (裏付けなし) の場合は fail-closed で少なくとも 0.75 まで引き上げる ("unevaluated" 扱い)。CloudSendAllowed = effPL<0.5。RequiresApproval = unevaluated || effPL>=0.5。

mode "plan" 返値: `<|Status->"Planned", WouldWrite->False, EffectivePolicy(PrivacyLevel/AccessTags/DenyTags/CloudSendAllowed/ReleaseContext), NormalizedSourceRefs, SourceRefRoles(Input/Citation/Prompt), PrivacyBasis(Requested/SessionObservedReadMax/BatchObservedReadMax/FailClosedFloorApplied/Policy->"MaxObservedInput"), RequiresApproval, ArtifactURIForm("sv://artifact/<id>" の形の例示), Warnings|>`

mode "commit": text は DerivedArtifact、binary(base64) は CommitBlob + DerivedArtifact。DepositArtifact 権限が無ければ書込まず `<|Status->"RequireGrant", Reason, RequiredAction->"DepositArtifact", AuthDetail, HowToProceed|>` を返す。RequiresApproval (high-privacy/未裏付け ref) は `Approved->True` か 対応 grant/profile の MaxAccessLevel>=effPL 無しで書込まず `<|Status->"RequireApproval", Reason, EffectivePolicy, RequiresApproval->True, AuthVia, Warnings|>` を返す。
commit 成功時: `<|Status->"OK", ArtifactUri(sv://artifact/..), DerivedArtifactRef, ContentUri(binary かつ CloudSendAllowed の時のみ sv://hash/sha256/.. で非Null。それ以外はNull=高 privacy content は ArtifactUri のみ正準), Existed, EffectivePolicy(PrivacyLevel/AccessTags/DenyTags/CloudSendAllowed), ReleasedProjection->"metadata", RequiresApproval|>`。
contentSHA256+idempotencyKey が既出かつ同一内容なら idempotent replay として過去 deposit record (ArtifactUri/DerivedArtifactRef/ContentSHA256/ContentUri/SessionId/BatchId/Bytes/PrivacyLevel/CreatedAtUTC + Status->"OK", Existed->True。※新規成功時と key 構成が異なるので呼び出し側は両対応が必要) を返す。同一 key で内容が異なれば `Status->"IdempotencyCollision"`。
その他失敗 Status: "InvalidContent"(base64 decode失敗) / "PayloadTooLarge"(Bytes/MaxBytes=5MB 超過) / "EmptyText" / "QuotaExceeded"(session/batch あたり件数 200 or 容量 50MB 超過。Usage/MaxItems/MaxBytes を返す) / "BlobCommitFailed"(Detail) / "DepositWriteFailed"(Detail) / 不正 mode は `Failure["InvalidDepositMode"]`。

## WorkSession 層 (spec §13.5)

### SourceVaultListWorkSessions[opts] → List
hotlog (mcp_calls/mcp_batches/mcp_deposits) を SessionId (無ければ BatchId、無ければ heuristic) 単位の WorkSession に集約して返す。既存 trace の view (新 source of truth ではない)。StartedAtUTC 降順 (新しい順)。
Options: "SessionId" -> All, "DateFrom" -> Automatic (YYYY-MM-DD), "DateTo" -> Automatic, "MaxRows" -> Automatic
各 record key: WorkId / GroupKey / SessionId / SessionIds / BatchIds / Title / StartedAtUTC / EndedAtUTC / MCPCallCount / DepositCount / MCPCallIds / RelatedURIs / OutputURIs / RelatedURICount / MaxObservedPrivacy(観測下限・監視外含まず §13.4) / MaxObservedPrivacyNote / UnlinkedCallCount / LinkConfidence("Explicit"|"Heuristic")

### SourceVaultWorkSessionRecord[workId] → Association|Missing
単一 WorkSession を返す (`SourceVaultListWorkSessions[]` の全件から検索。自身は option を取らない)。未存在は `Missing["WorkSessionNotFound"]`。

### SourceVaultWorkSessionDataset[opts] → Dataset
WorkSession 一覧を notebook 俯瞰用 Dataset で返す。`SourceVaultListWorkSessions` と同じ Options ("SessionId"/"DateFrom"/"DateTo"/"MaxRows") をそのまま受け渡す。列は StartedAtUTC/Title/SessionId/MCPCallCount/DepositCount/RelatedURICount/MaxObservedPrivacy/UnlinkedCallCount/LinkConfidence/WorkId の 10 列に絞り込み (SessionIds/BatchIds/MCPCallIds/RelatedURIs/OutputURIs/EndedAtUTC/GroupKey/MaxObservedPrivacyNote は含まない)。MaxObservedPrivacy は観測ベースの下限推定で監視外読み取りを含まない (§13.4); release 判断に使わない。

### SourceVaultWorkSessionGraph[workId] → Association
WorkSession → MCPCall / RelatedURI / OutputArtifact の nodes/edges を返す (履歴ブラウズ用; raw 本文や引数は含めない)。単純な Association の list であり `Graph[]`/GraphPlot オブジェクトではない (JSON/notebook 両対応)。
返値: `<|WorkId, Nodes->{<|Id,Type("WorkSession"|"MCPCall"|"URI"|"Artifact"),Label|>...}, Edges->{<|From,To,Rel("contains"|"related"|"output")|>...}|>`。workId が未存在なら `Missing["WorkSessionNotFound"]` をそのまま返す。