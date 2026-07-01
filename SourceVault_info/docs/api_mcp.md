# SourceVault_mcp API リファレンス

パッケージ: `SourceVault`` (コンテキスト `SourceVault`MCPPrivate`` は内部)
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_mcp.wl"]]`
役割: MCP tool schema 定義・dispatch・argument validation・provenance 付与。HTTP/JSON-RPC transport は Python proxy 側。service kernel から `SourceVaultMCPDispatch` を呼ぶ。FrontEnd/Notebook/NBAccess 非依存。結果は JSON 安全 (string/assoc/list/bool)。

## MCP dispatch / protocol

### $SourceVaultMCPProtocolVersion
型: String, 初期値: "2024-11-05"
`initialize` レスポンスで返す MCP protocol バージョン。

### SourceVaultMCPServerInfo[] → Association
`<|"name" -> "sourcevault", "version" -> "0.1.0"|>` を返す。

### SourceVaultMCPTools[] → List
MCP tool 定義 (name/description/inputSchema) のリストを返す。

### SourceVaultMCPCallTool[name, args] → Association
tool を実行し MCP result `<|"content", "isError"|>` を返す。

### SourceVaultMCPDispatch[method, params] → Association
MCP JSON-RPC の method (initialize/tools/list/tools/call/ping) を処理し JSON-RPC result 相当の Association を返す。未知 method は `Failure["MCPMethodNotFound", ...]` (proxy が JSON-RPC error に変換)。

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

- **`sourcevault_mail_status`** — scope (`SourceVault`$svMailStructMCPScope = {mbox, period}`, 既定 `{"univ", "202606"}`) のメールをロード → StructureMail → BM25 index を cloud PrivacyScope で lazy build し状態 (`Loaded / Scope / MailCount / SessionCount / VocabSize / IndexId`) を返す。検索前に一度呼ぶ。実体 `SourceVaultMailStructEnsureIndex`。
- **`sourcevault_mail_search_threads`** {query, limit=10} — session を BM25 で検索し `{Session, Subject, Score, Snippet}` を返す。実体 `SourceVaultMailStructSearchThreads`。
- **`sourcevault_mail_thread`** {session} — 1 session 詳細 `{SessionId, Subject, MailCount, Topics, CurrentDigest, HistoricalReferences, Released}` を返す。**digest は current session の結論と historical reference (過去メールの引用/前例/テンプレート) を分離** (§9)。実体 `SourceVaultMailStructThread`。

**privacy gate**: 3 tool すべて cloud-safe。(1) `search_threads` は私的/第三者メール (`ThirdPartyContent / NoCloudLLM / NoPublicExport / PrivateML` tag ∨ PrivacyLevel≒1.0) の session chunk を build-time release gate (`mailstruct-cloud`) で除外し検索でヒットさせない。(2) `thread` は session が私的メールを含む場合 digest を出さず `{Released: false, Why: ["PrivateMail"]}` を返す (二重防御)。notebook から直接呼ぶ場合は `CloudSafe -> False` でフルアクセス。

## URI 層 (spec §3.1)

### $SourceVaultURINamespaces
型: List, 初期値: {"object","chunk","artifact","hash","group","relation","snapshot","record","citation","file"}
sv:// URI の予約 identity namespace。data class (mail/web/pdf 等) は URI namespace でなく Class/MediaType/Kind sidecar に持つ。namespace arity: object/chunk/artifact/relation/record/citation/file → 1 segment、hash/snapshot → 2 segments、group → 2 segments。

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

## Adapter registry (spec §4.1)

### SourceVaultRegisterMCPDataAdapter[name, spec] → Association|Failure
data adapter を登録する。spec 必須: "Kinds" ({_String..})。
任意 spec key: "Capabilities" (<|cap->bool|>)、"Search"/"Resolve"/"Read"/"SummaryRow"/"Metadata"/"Authorize"/"URIForObject" 関数、"Available" (bool)、"AvailableProbe" (Function[])、"RequireGrantFor" ({_String..})、"UnavailableReason"。
Capabilities key: Search / ReadMetadata / ReadSummary / ReadContext / ReadBody / DepositArtifact / ResolveObjectURI / SemanticSearch / MetadataFilter。未指定 key は False で補完。
返値: `<|"Status"->"OK", "Name", "Kinds", "Capabilities"|>`

### SourceVaultListMCPDataAdapters[] → {String..}
登録済み adapter 名のリスト (ソート済み) を返す。

### SourceVaultResolveMCPDataAdapter[name] → Association|Missing
登録済み adapter spec を返す。未登録は `Missing["AdapterNotRegistered"]`。

## Access model 正規化 (spec §2.1 / §2.2 / §2.4)

### SourceVaultNormalizePrincipal[input, opts]
MCP request 主体を Principal 連想に正規化する。ClientName は自己申告可 (provenance 扱い)。authoritative ProviderClass は opts "Trusted" からのみ採用し、無ければ "Unknown" (release 判定に client 自己申告は使わない)。
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
登録済み adapter の catalog を JSON 安全な連想で返す。各 adapter record: name/kinds/available/capabilities/requiresGrantFor、unavailable なら unavailableReason を付加。トップに defaultReturnFormats。
→ Association
Options: "IncludeUnavailable" -> True

## AccessProfile / model 別アクセス設定 (spec §2.5)

### SourceVaultSetModelAccessProfile[provider, intent, modelId, profile] → Association|Failure
model 別 AccessProfile を PrivateVault/config/mcp-access-profiles.json に永続化する (AccessProfileRef 方式・GitHub 非公開)。modelId に "*" を渡すと provider/intent の wildcard profile。
profile key: MaxAccessLevel / AllowedSinks / AllowedOperations / AllowedProjections / DeniedProjections / ScopePolicy / PurposeAllowed / RequireGrantFor / Audit / EndpointRef / TrustDomain。返値は正規化済み profile。

### SourceVaultGetModelAccessProfile[provider, intent, modelId] → Association|Missing
保存済み AccessProfile を返す。未登録は `Missing["AccessProfileNotFound"]`。

### SourceVaultListModelAccessProfiles[] → {String..}
保存済み AccessProfile の ProfileId (provider:intent:modelId 形式) リストを返す。

### SourceVaultResolveAccessProfile[request] → Association
request に対する実効 AccessProfile を解決する。解決順: exact (provider:intent:modelId) → wildcard (provider:intent:* / provider:*:*) → default。default は trust-domain cap (cloud 0.49 / local 1.0) と安全側 ScopePolicy で、profile 未登録時に既存 ceiling を変えない。
request key: Provider / ModelId / ModelIntent / TrustDomain
返値: `<|AccessProfileRef, Source("Exact"|"Wildcard"|"Default"), Profile|>`

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
trace 用 opaque correlation id を生成する。kind → prefix: "batch"→svbatch- / "job"→svjob- / "trace"→svtrace- / "session"→svsession- / "work"→svwork- / "call"→svmcp-。capability ではなく漏れても権限を与えない。trusted host が mint する想定 (client tool 引数からは mint させない)。

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
prospective な BatchId を mint する (spec §13.3 / N2)。trusted host (main kernel/orchestrator) が呼ぶ前提。client tool 引数からは mint させない。LocalState/hotlog/mcp_batches に marker を記録する。
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
MCP の SearchSpec (spec §5.1) を既定補完して正規化する。kinds に "all" があれば個別指定を無視。filters の accessLevelMax を正準、privacyMax を alias とする。return.format 既定 "compactText"、scope.untagged 既定 "MetadataOnly"。`methods` 既定は `{"keyword", "metadata"}`（後方互換）。`"bm25"` を含めると search adapter が日本語 BM25 + entity OR-match の `KeywordBM25V1` index を選ぶ（§8.2）。

### SourceVaultNormalizeSearchResult[row, opts] → Association
adapter の生 result row を SearchResult (spec §6) に正規化する。URI を canonical 化し Summary/Snippet を MaxChars で truncation する。未開示は `Missing["NotReleased"]` 等で示す。release gate 判定は呼び出し側で行う。
Options: "Adapter" -> Missing[], "Kind" -> Missing[], "ReleasedProjection" -> Missing[], "IncludeSnippets" -> True, "IncludeMetadata" -> True, "MaxChars" -> Automatic

### SourceVaultRenderSearchResults[results, format] → String|List
正規化済み SearchResult のリストを返却形式に整える。
format: "compactText" (LLM 可読 text) | "referencesOnly" (URI+citation のみ text) | "structuredJson" (structured list をそのまま返し tool 層で JSON 化) (spec §8)

### SourceVaultMCPSearch[searchSpec, opts]
SearchSpec を正規化し kinds に適合する available な search adapter を選び、各 adapter search → SearchResult 正規化 → limit/offset → render する横断検索 orchestration (spec §11.1)。per-result release gate (SourceVaultMCPReleaseGate) を通す。`sourcevault_search` tool の実体。
**method=bm25 (§8.2)**: `methods` に `"bm25"` があり明示 `scope.index` が無ければ、search adapter は `scope.bm25Index` → 慣習 `"<releaseContext>-bm25"` の順で `KeywordBM25V1` index を選ぶ。実際の BM25/bigram は index の `IndexKind` で `iNativeSearch` が dispatch する（method は advisory）。結果 Metadata に `RetrievalKind`（"KeywordBM25"/"KeywordBigram"）を載せる。query が英語・doc が日本語でも entity term で一致する（表記非一致/OOV 回復）。
→ Association
Options: "Principal" -> Automatic, "Trusted" -> <||>
返値 key: Results / Count / TotalBeforeLimit / Adapters / Format / Rendered / AccessRequest / ReleaseGated

### SourceVaultMCPGet[uri, opts]
単一の sv:// URI を解決し、所有 adapter の Resolve で低漏洩メタ/サマリー projection を取り、SourceVaultMCPReleaseGate で出口 gate して返す (spec §11.2)。body/raw/attachment は含めず requiresGrant を示す (実 grant は Phase D)。`sourcevault_get` tool の実体。
→ Association
Options: "Principal" -> Automatic, "Trusted" -> <||>
返値 key: URI / Found / Released / Adapter / Result(Permit 時のみ) / Access / RequiresGrantFor / Why / AccessRequest

### SourceVaultMCPReleaseGate[result, accessRequest] → Association
正規化済み SearchResult を返却してよいか判定する (spec §11, §2.4)。
判定ルール: DenyTag 交差→Deny、Privacy.Level > EffectiveAccessLevel→Deny、cloud sink (ProviderClass CloudLLM/Unknown + Sink MCPResponse) で Level>=0.5→Deny、Privacy.Level が数値でない (web/Public など検索自己 gate 済)→Permit。release context の MaxPrivacyLevel と request AccessLevel の最小を実効上限にする。
返値: `<|"Decision"->"Permit"|"Deny", "Why"->{...}, ...|>`

## AccessGrant / 申請・承認 (spec §2.3 / §11.3, Phase D)

### SourceVaultMCPEnsureGrantKey[] → Association|Failure
LocalState/secrets/sourcevault-grant-signing-key.json に grant 署名用 shared secret (HMAC 鍵) が無ければ生成する。main↔service 共有 (MCP transport token とは別物)。LocalState 未解決なら Failure。
返値: `<|KeyId, Created(bool), Path|>`

### SourceVaultMCPMintAccessGrant[spec] → Association|Failure
§2.3 の AccessGrant を発行し HMAC 署名して返す (main kernel)。署名鍵が無ければ Failure。
spec key: Principal / AllowedActions / AllowedKinds / AllowedObjectRefs / MaxAccessLevel / AllowedFields / Purpose / Sink / TTLSeconds
Digest = 正準 JSON の SHA256、Signature = 同 HMAC。

### SourceVaultMCPVerifyAccessGrant[grant] → Association
grant の Digest/Signature/期限/RevocationEpoch を検証する (service-loadable; 純 crypto、NBAccess 非依存)。
返値: `<|Valid->True|False, Why->{...}, ...|>`

### SourceVaultMCPRevokeAllGrants[] → Association
revocation epoch を +1 し、これ以前に mint した全 grant を無効化する。

### SourceVaultMCPRequestAccess[spec] → Association
access grant 申請を LocalState の承認 queue に append-only 保存する (service)。MCP client は status を poll する (`sourcevault_request_access` tool の実体)。
spec key: Principal / Action / ObjectRefs / Kinds / Fields / Purpose / Sink / RequestedAccessLevel / TTLSeconds
返値: `<|RequestId, Status->"Pending"|>`

### SourceVaultMCPAccessStatus[requestId] → Association
申請の状態を返す (service; `sourcevault_access_status` tool の実体)。grant 期限切れは "Expired" 扱い。
返値: `<|Status->"Pending"|"Granted"|"Denied"|"Expired", Grant(Granted 時)|>`

### SourceVaultMCPPendingAccessRequests[opts] → List
未決 (Pending・未期限) の申請一覧を返す (main kernel helper)。

### SourceVaultMCPApproveAccessRequest[requestId, opts] → Association
申請を承認して AccessGrant を mint し status sidecar に記録する (main kernel helper)。opts で発行 scope (MaxAccessLevel / AllowedActions / AllowedKinds / Sink / TTLSeconds 等) を申請値より厳しく上書きできる (緩めることはしない想定)。返値は発行 grant。

### SourceVaultMCPDenyAccessRequest[requestId, reason_:""] → Association
申請を却下し status sidecar に記録する (main kernel helper)。

## Feedback bridge (Phase F / §12)

### SourceVaultMCPSubmitFeedback[spec] → Association
§12.3 FeedbackEnvelope を LocalState/hotlog/mcp_feedback へ append-only 記録する (service)。PrivacyLevel は自己申告だけでなく同一 Session/Batch の observed-read max を継承し Max 合成する (§12.3)。effective PrivacyLevel >= 0.5 は RequireReview=True。MVP は記録のみ (Orchestrator 側 queue/accept/subtask 昇格は将来)。
spec key: Kind("HelpRequest"|"SubtaskProposal"|"AccessRequest"|"Critique"|"Correction"|"SessionNote") / Principal / Payload(Text/Goal/SuggestedRole/SuggestedCapabilities/RequestedData/EvidenceRefs) / SessionId / BatchId / PrivacyLevel / RequireApproval
返値: `<|EventId, Status->"Queued", Kind|>`

### SourceVaultMCPFeedbackQueue[opts] → List
記録済み feedback event を時刻順に返す (main kernel helper)。
Options: "Kind" -> All, "Status" -> All, "Limit" -> Automatic

## Artifact deposit (spec §10.7 / §11.5)

### SourceVaultMCPDeposit[spec] → Association
LLM 生成 artifact の append-only deposit。`sourcevault_deposit` tool の実体。
spec key:
- mode: "plan" (書き込まず予定 policy を返す) | "commit" (append-only 保存)
- kind: artifact の種別
- mediaType: MIME type
- content: text または base64 binary
- policy: `<|privacyLevel, accessTags, denyTags|>`
- provenance: `<|authoredBy, inputRefs, citationRefs, promptRefs|>`
- SessionId / BatchId / idempotencyKey
- Grant: AccessGrant (commit 時の権限検証に使用)
- Approved: True (RequiresApproval 回避用)

mode "plan" 返値 key: EffectivePolicy / NormalizedSourceRefs / SourceRefRoles / PrivacyBasis / RequiresApproval
mode "commit": DepositArtifact 権限 (有効 grant の AllowedActions または endpoint AccessProfile の AllowedOperations) が無ければ RequireGrant を返し書込まない。既定 profile の AllowedOperations は DepositArtifact を含まない (fail-closed)。contentSHA256+idempotencyKey で idempotent。RequiresApproval (high-privacy/未裏付け ref) は Approved->True か対応 grant 無しで RequireApproval を返し書込まない。
commit 返値 key: Status / ArtifactUri(sv://artifact/..) / DerivedArtifactRef / ContentUri / Existed / EffectivePolicy

PrivacyLevel = Max[要求値, Session/Batch の observed-read max]。自己申告 SourceRefs が observed read で裏付けられない場合は fail-closed で 0.75 floor。

## WorkSession 層 (spec §13.5)

### SourceVaultListWorkSessions[opts] → List
hotlog (mcp_calls/mcp_batches/mcp_deposits) を SessionId (無ければ BatchId、無ければ heuristic) 単位の WorkSession に集約して返す。既存 trace の view (新 source of truth ではない)。新しい順。
Options: "SessionId" -> All, "DateFrom" -> Automatic (YYYY-MM-DD), "DateTo" -> Automatic, "MaxRows" -> Automatic
各 record key: WorkId / SessionId / BatchIds / Title / StartedAtUTC / EndedAtUTC / MCPCallCount / DepositCount / RelatedURIs / OutputURIs / MaxObservedPrivacy(観測下限・監視外含まず §13.4) / UnlinkedCallCount / LinkConfidence("Explicit"|"Heuristic")

### SourceVaultWorkSessionRecord[workId] → Association|Missing
単一 WorkSession を返す。未存在は `Missing["WorkSessionNotFound"]`。

### SourceVaultWorkSessionDataset[opts] → Dataset
WorkSession 一覧を notebook 俯瞰用 Dataset で返す。MaxObservedPrivacy は観測ベースの下限推定で監視外読み取りを含まない (§13.4); release 判断に使わない。

### SourceVaultWorkSessionGraph[workId] → Association
WorkSession → MCPCall / RelatedURI / OutputArtifact の nodes/edges を返す (履歴ブラウズ用; raw 本文や引数は含めない)。