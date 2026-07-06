# SourceVault_mcp API リファレンス (LLM 最適化)

## 概要
SourceVault_mcp.wl は MCP (Model Context Protocol) の WL 側補助ライブラリである。MCP protocol endpoint 本体ではなく、(1) MCP tool schema 定義、(2) initialize / tools/list / tools/call / ping の dispatch、(3) argument validation と provenance 付与を担う。実際の HTTP / JSON-RPC transport は Python proxy 側に置き、proxy は HTTP POST /mcp で受けた JSON-RPC を file command queue 経由で service kernel に渡し、service が `SourceVaultMCPDispatch` を呼ぶ。context は `SourceVault``。UTF-8 エンコード。読込は `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_mcp.wl"]]`。

設計原則: 本ファイルは service-loadable 制約下にあり FrontEnd / Notebook / NBAccess に非依存。戻り値は JSON 安全 (string / assoc-of-string / list / bool) に保つ。純関数層 (URI 解析・access model 正規化・privacy 会計) と、LocalState hotlog へ副作用を持つ永続化層 (MCPCall 記録・grant queue・feedback・deposit) からなる。関連: [SourceVault_core](https://github.com/transreal/SourceVault_core)、[SourceVault_promptrouter](https://github.com/transreal/SourceVault_promptrouter)、[SourceVault_packageapi](https://github.com/transreal/SourceVault_packageapi)、[NBAccess](https://github.com/transreal/NBAccess)、[github](https://github.com/transreal/github) (GitHubREST)。

access 設計の要点: client の自己申告 (ClientName / ProviderClass) は provenance であり release 判定に使わない。authoritative な値は transport/grant/main-kernel で確立した `"Trusted"` opts からのみ採用し、無ければ Unknown / cloud 相当に fail-closed する。cloud/unknown の TrustCeiling は 0.49、local/private は provider cap (≤1.0)。実効 access level は指定 ceiling 群の Min。privacy は observed-read の Max を継承する (declassification せず、egress で再 gate)。

## MCP dispatch / server info

### SourceVaultMCPDispatch[method, params] → Association
MCP JSON-RPC の method (initialize / tools/list / tools/call / ping) を処理し JSON-RPC result 相当の Association を返す。未知 method は `Failure["MCPMethodNotFound", ...]` (proxy が JSON-RPC error に変換)。

### SourceVaultMCPTools[] → List
MCP tool 定義 (name / description / inputSchema) のリストを返す。

### SourceVaultMCPCallTool[name, args] → Association
tool を実行し MCP result `<|"content", "isError"|>` を返す。

### SourceVaultMCPServerInfo[] → Association
MCP serverInfo を返す。実値 `<|"name" -> "sourcevault", "version" -> "0.1.0"|>`。

### $SourceVaultMCPProtocolVersion
型: String, 初期値: "2024-11-05"
initialize で返す MCP protocol version。

### SourceVaultPackageCommitLog[packageName, opts]
本システムのパッケージのコミット履歴を GitHubREST`GitHubCommitLog 経由で取得し JSON-safe なコンパクト形式で返すラッパー。コミットメタデータのみ (コード本文なし) で cloud-safe (PL 0.0)。MCP tool sourcevault_commit_log の実体。GithubRepositories/ は .git を持たないミラーのため履歴の正本は GitHub API。
→ `<|"Status", "Package", "Count", "Commits" -> {<|sha, date, author, message|>..}, "PrivacyLevel"|>`
Options: "Since" -> None, "Until" -> None (日付範囲), "MaxItems" -> 50 (最大件数)
例: `SourceVaultPackageCommitLog["SourceVault", "Since" -> "2026-06-20"]`

## URI 層 (sv:// identity)

### $SourceVaultURINamespaces
型: List, 初期値: {"object", "chunk", "artifact", "hash", "group", "relation", "snapshot", "record", "citation", "file", "packageapi", "directive"}
sv:// URI の予約 identity namespace。第 1 segment はこれに固定 dispatch。mail / web / pdf などの data class は URI namespace ではなく Class / MediaType / Kind sidecar に持つ。arity: object/chunk/artifact/relation/record/citation/file/packageapi/directive は 1、hash/snapshot/group は 2。

### SourceVaultParseURI[uri] → Association
sv:// URI または legacy ref (blob:sha256:.. / snapshot:class:hex) を解析し `<|Valid, Form, Scheme, Namespace, Segments, Id, CanonicalURI, ...|>` を返す。Form は Canonical / LegacyInternal / Invalid。未知 namespace / arity 不一致 / 非文字列は Valid->False で fail-closed。純関数。

### SourceVaultBuildURI[namespace, id] / SourceVaultBuildURI[namespace, {seg..}] → String | Failure
予約 namespace と arity を検証し、各 segment を percent-encoding した正準 sv:// URI 文字列を返す。namespace 不正は `Failure["UnknownURINamespace"]`、arity 不一致は `Failure["URIArityMismatch"]`、空 segment は `Failure["URIEmptySegment"]`。

### SourceVaultValidURIQ[uri] → Bool
uri が well-formed な sv:// URI または解決可能な legacy ref なら True。それ以外/非文字列は False。

### SourceVaultResolveURI[uri, opts]
URI を正規化する。ResolutionConfidence: Exact (正準) / Alias (legacy ref) / Ambiguous / NotFound。Phase A skeleton で構文正規化のみ (adapter による実 object 解決・access gate は後続 increment)。
→ `<|CanonicalURI, AlternateURIs, Namespace, Class, Kind, Adapter, InternalStableId, ObjectSnapshotRef, ContentHash, ResolutionConfidence|>`
Options: "Return" -> "Association" ("CanonicalURI" で canonical 文字列のみ返す), "AccessRequest" -> Automatic (将来 gate に渡す)

### SourceVaultCanonicalURI[uri, accessRequest:Automatic] → String
uri の canonical sv:// URI 文字列を返す (`SourceVaultResolveURI[..., "Return"->"CanonicalURI"]` の薄い wrapper)。URI を key / edge / group member / SourceRef として保存する前に必ずこれで正規化する。

### SourceVaultURIForObject[objectOrRef, opts] → String | Missing
object / 内部 ref から canonical sv:// URI を返す adapter hook。Phase A skeleton では legacy ref 文字列や CanonicalURI/URI/Ref/BlobRef を持つ assoc を正規化する。解決不能は Missing。adapter registry 経由の実 object 解決は後続 increment。

## adapter registry

### SourceVaultRegisterMCPDataAdapter[name, spec] → Association | Failure
data adapter を登録する。spec 必須: "Kinds" ({_String..})。任意: "Capabilities" (Search / ReadMetadata / ReadSummary / ReadContext / ReadBody / DepositArtifact / ResolveObjectURI / SemanticSearch / MetadataFilter -> bool)、"Search" / "Resolve" / "Read" / "SummaryRow" / "Metadata" / "Authorize" / "URIForObject" 関数、"Available" / "AvailableProbe" / "UnavailableReason" / "RequireGrantFor" / "FilterKeys" / "FilterExamples"。Capabilities は未指定 key を False で補完。Kinds 不正は `Failure["AdapterMissingKinds"]`、spec 非 Association は `Failure["AdapterSpecNotAssociation"]`。

### SourceVaultListMCPDataAdapters[] → List
登録済み adapter 名のソート済みリスト。

### SourceVaultResolveMCPDataAdapter[name] → Association | Missing
登録済み adapter spec を返す。未登録は `Missing["AdapterNotRegistered"]`。

### SourceVaultMCPCatalog[opts]
登録済み adapter の catalog を JSON 安全な連想で返す。各 adapter は name / kinds / available / capabilities / requiresGrantFor を持ち、adapter 固有の filterKeys / filterExamples があれば付与、unavailable なら unavailableReason を付ける。トップに defaultReturnFormats ({"compactText", "structuredJson", "referencesOnly"})。MCP tool sourcevault_catalog の実体。
→ `<|"adapters" -> {...}, "defaultReturnFormats" -> {...}|>`
Options: "IncludeUnavailable" -> True (False で unavailable adapter を除外)

## access model 正規化

### SourceVaultNormalizePrincipal[input, opts]
MCP request 主体を Principal 連想に正規化する。ClientName は provenance (自己申告可、release 判定に使わない)。authoritative な ProviderClass (CloudLLM/LocalLLM/PrivateLLM) は opts "Trusted" からのみ採用し、無ければ "Unknown"。
→ `<|Kind, ClientName, ProviderClass, ProviderClassTrusted, AssertedProviderClass, SessionId, UserPresent|>`
Options: "Trusted" -> <||> (transport/grant/main-kernel で確立した authoritative 値)

### SourceVaultNormalizeAccessRequest[spec, opts]
MCP tool call を AccessRequest 連想 (spec §2.2) に正規化する。"AccessLevel" を正準とし "MaxPrivacyLevel" は入力互換 alias。ScopePolicy は既定 (RequireAccessTags {}, AllowAccessTags All, DenyAccessTags {}, Untagged "MetadataOnly") を補完。
→ `<|Action, Principal, Purpose, Sink, ReleaseContext, Provider, ModelId, ModelIntent, AccessLevel, MaxPrivacyLevel, ScopePolicy, RequestedProjection, RequestedKinds, SessionGrant, CreatedAtUTC|>`
Options: "Principal" -> Automatic (Automatic なら spec の Principal か既定を使う)

### SourceVaultEffectiveAccessLevel[{ceiling..}, opts] → Real
指定された access ceiling 群の最も厳しい値 (Min) を返す。numeric でない要素 (Automatic/Missing/None) は無視。alias 重複可 (Min は冪等)。numeric が皆無なら opts の既定を返す。
Options: "Default" -> 0.5 (cloud 安全境界)

## model AccessProfile (AccessProfileRef 方式)

### SourceVaultSetModelAccessProfile[provider, intent, modelId, profile] → Association | Failure
model 別 AccessProfile を PrivateVault/config/mcp-access-profiles.json に永続化 (GitHub 非公開)。profile: MaxAccessLevel / AllowedSinks / AllowedOperations / AllowedProjections / DeniedProjections / ScopePolicy / RequireGrantFor / EndpointRef / PurposeAllowed / Audit 等。modelId に "*" で provider/intent の wildcard profile。戻り値は正規化済み profile。PrivateVault 未解決は Failure。

### SourceVaultGetModelAccessProfile[provider, intent, modelId] → Association | Missing
保存済み AccessProfile を返す。未登録は `Missing["AccessProfileNotFound"]`。

### SourceVaultResolveAccessProfile[request] → Association
request (Provider/ModelId/ModelIntent/TrustDomain) に対する実効 AccessProfile を解決する。exact (provider:intent:modelId) → wildcard (provider:intent:* / provider:*:*) → default の順。default は trust-domain cap (cloud 0.49 / local 1.0) と安全側 ScopePolicy で、profile 未登録時に既存 ceiling を変えない。
→ `<|AccessProfileRef, Source (Exact/Wildcard/Default), Profile|>`

### SourceVaultListModelAccessProfiles[] → List
保存済み AccessProfile の ProfileId リスト。

## prompt delivery / runtime capability

### SourceVaultResolvePromptDeliveryProfile[request, opts]
model / 実行環境 / MCP 可否から PromptDeliveryProfile を返す。request key (いずれも client 申告は advisory): provider / modelId / modelIntent / clientKind / mcpToolsVisible / sourcevaultMcpEnabled / mcpAvailable / canCallMcpDuringInference / localFolderReadableByTool / localPackageDirectoryReadable。TrustDomain / TrustCeiling は opts "Trusted" と provider 級 cap (NBAccess`NBGetProviderMaxAccessLevel, guarded) から server 側で決め、自己申告では緩めない。route / model 解決は prompt router に委譲する薄い planning layer。
→ `<|DeliveryProfileId, Provider, ModelId, ClientKind, TrustDomain, LocalPackageDirectoryReadable, LocalFolderReadableByTool, MCPAvailable, SourceVaultMCPEnabled, SourceVaultMCPTools, CanCallMCPDuringInference, CanUseSVURIInPrompt, InputsFullyMediatedBySourceVault, PromptStrategy, TrustCeiling, UnknownInputFloor, RequireReviewOnUnmediatedInput, AccessProfileRef, AccessProfileSource, Warnings|>`
PromptStrategy: MCPDeferred / InlineContext / Hybrid / LocalToolRefs / NoSourceVault。UnknownInputFloor は常に数値 (cloud/unknown 0.0, local/private 1.0)。
Options: "Trusted" -> <||>, "ResolveAccessProfile" -> True

### SourceVaultMCPRuntimeCapabilities[args] → Association
MCP tool sourcevault_runtime_capabilities の実体。`SourceVaultResolvePromptDeliveryProfile` を JSON 安全な camelCase 出力 (deliveryProfileId / provider / modelId / trustDomain / mcpAvailable / sourcevaultMcpEnabled / canCallMcpDuringInference / canUseSvUriInPrompt / promptStrategy / inputsFullyMediatedBySourceVault / outputTrustCeiling / unknownInputFloor / requireReviewOnUnmediatedInput / accessProfileRef / warnings) に整形する。

## trace / privacy 会計

### SourceVaultMintTraceId[kind] → String
trace 用の opaque correlation id を生成する。kind: batch/job/trace/session/work/call -> svbatch-/svjob-/svtrace-/svsession-/svwork-/svmcp-。未知 kind は svid-。引数なし `SourceVaultMintTraceId[]` は "trace"。capability ではなく漏れても権限を与えない。trusted host が mint する想定。

### SourceVaultNormalizeMCPCallRecord[spec] → Association
MCP call 監査 record を既定補完して正規化する。MaxReleasedPrivacy は released projection 自身の privacy。ProjectionPrivacyBasis: Recomputed | SourcePrivacyFallback。LinkConfidence: Explicit/Metadata/Heuristic/Unlinked。
→ `<|CallId, BatchId, JobId, TraceToken, SessionId, Tool, ArgumentURIs, ReleasedURIs, ReleasedProjection, MaxReleasedPrivacy, ProjectionPrivacyBasis, AccessGrantId, Decision, LinkConfidence, StartedAtUTC, FinishedAtUTC|>`

### SourceVaultObservedReadMax[records, opts] → Real
privacy 会計の安全側 observed-read 上限 (Max) を返す。heuristic link も過小評価回避のため Max の上側に含める。numeric 皆無なら opts の既定。
Options: "BatchId" -> Missing[], "SessionId" -> Missing[] (trusted grouping に filter、無指定なら全件), "Default" -> 0.0

### SourceVaultEstimateOutputPrivacy[jobSpec, opts]
LLM 出力の OutputPrivacyEstimate を純関数で返す。jobSpec: DeliveryProfile / PromptPrivacyMax / BatchObservedReadMax / SessionObservedReadMax / LocalToolReadPrivacyMax / UserUploadPrivacyMax / ExplicitUserPromptPrivacyMax 等。PrivacyLevel は intrinsic = 観測入力の Max (監視外 channel 時は UnknownInputFloor へ引き上げ)。TrustCeiling では削らない (sink/env は egress 時の NBAuthorize で加える)。Confidence (High/Medium/Low) と RequireReview を判定表どおり付与。declassification ではない (egress で再 gate)。
→ `<|PrivacyLevel, TrustCeiling, UnknownInputFloor, InputsFullyMediatedBySourceVault, RequireReview, Confidence, ObservedInputMax, Basis, PrivacyInheritancePolicy|>`
Options: "Records" -> {} (MCPCall record のリスト)

### SourceVaultStartBatch[spec] → Association
prospective な BatchId を mint する。trusted host (main kernel / orchestrator) が呼ぶ前提で、client tool 引数からは mint させない。spec: SessionId / Title / DeliveryProfileId / ExpectedJobCount。LocalState/hotlog/mcp_batches へ marker を記録。引数なし可。
→ `<|BatchId, SessionId, Title, DeliveryProfileId, ExpectedJobCount, Status->"Running", StartedAtUTC, MintAuthority->"TrustedHost"|>`

### SourceVaultRecordMCPCall[spec] → Association
MCP call 監査 record を正規化し LocalState/hotlog/mcp_calls/YYYY-MM.jsonl へ append-only 記録する。best-effort instrumentation で LocalState 未解決や書込失敗でも応答を壊さない。単一書き手は service kernel。
→ `<|CallId, Recorded (bool), MaxReleasedPrivacy|>`

### SourceVaultMCPCallsRecent[opts] → List
記録済み MCPCall を時刻順に返す (main/service helper)。`SourceVaultObservedReadMax` の入力。
Options: "BatchId" -> All, "SessionId" -> All (trusted grouping に filter), "Limit" -> Automatic

## search 契約層

### SourceVaultNormalizeSearchSpec[spec] → Association
MCP の SearchSpec を既定補完して正規化する。kinds に "all" があれば個別指定を無視。filters の accessLevelMax を正準、privacyMax を alias とする。return.format 既定 compactText、scope.untagged 既定 MetadataOnly。

### SourceVaultNormalizeSearchResult[row, opts] → Association
adapter の生 result row を SearchResult (spec §6) に正規化する。URI を canonical 化し、Summary/Snippet を MaxChars で truncation、未開示は `Missing["NotReleased"]` 等で示す。release gate 判定は呼び出し側で行う。
Options: "Adapter", "Kind", "ReleasedProjection", "IncludeSnippets", "IncludeMetadata", "MaxChars"

### SourceVaultRenderSearchResults[results, format] → String | List
正規化済み SearchResult のリストを返却形式に整える。format: "compactText" (LLM 可読 text) / "referencesOnly" (URI+citation のみ text) / "structuredJson" (structured list をそのまま返し tool 層で JSON 化)。

### SourceVaultMCPSearch[searchSpec, opts]
SearchSpec を正規化し、kinds に適合する available な search adapter を選び、各 adapter search → SearchResult 正規化 → limit/offset → render する横断検索の orchestration。per-result release gate (`SourceVaultMCPReleaseGate`) を通す。sourcevault_search tool の実体。
→ `<|Results, Count, TotalBeforeLimit, Adapters, Format, Rendered, ReleaseGated (gate 除外件数), AccessRequest|>`
Options: "Principal", "Trusted"

### SourceVaultMCPGet[uri, opts]
単一の sv:// URI を解決し、所有 adapter の Resolve で低漏洩メタ/サマリー projection を取り、`SourceVaultMCPReleaseGate` で出口 gate して返す。body/raw/attachment は含めず requiresGrant を示す (実 grant は Phase D)。例外: adapter が "BodyGrantRequired"->False を宣言する PublicDoc 系 (packageapi 等) は view=body を grant なしで解放する。adapter の "ExtraViews" に登録された view 名 (packageapi: contract/scaffolded/guided) はその projection を返す。sourcevault_get tool の実体。
→ `<|URI, Found, Released, Adapter, Result (Permit時のみ), Access, RequiresGrantFor, Why, AccessRequest|>`
Options: "Principal", "Trusted", "View"

### SourceVaultMCPReleaseGate[result, accessRequest] → Association
正規化済み SearchResult を返却してよいか判定する。判定: DenyTag 交差 / Privacy.Level > EffectiveAccessLevel / cloud sink (ProviderClass CloudLLM/Unknown + Sink MCPResponse) で Level>=0.5 は Deny。Privacy.Level が数値でない (web/Public, search 自己 gate 済) は Permit。release context の MaxPrivacyLevel と request AccessLevel の最小を実効上限にする。
→ `<|"Decision"->"Permit"|"Deny", "Why"->{...}, ...|>`

## AccessGrant + 申請/承認 (Phase D)

### SourceVaultMCPEnsureGrantKey[] → Association | Failure
LocalState/secrets/sourcevault-grant-signing-key.json に grant 署名用 shared secret (HMAC 鍵) が無ければ生成する (main↔service 共有・MCP transport token とは別物)。LocalState 未解決なら Failure。
→ `<|KeyId, Created (bool), Path|>`

### SourceVaultMCPMintAccessGrant[spec] → Association | Failure
§2.3 の AccessGrant を発行し HMAC 署名して返す (main kernel)。spec: Principal / AllowedActions / AllowedKinds / AllowedObjectRefs / MaxAccessLevel / AllowedFields / Purpose / Sink / TTLSeconds。Digest=正準 JSON の SHA256、Signature=同 HMAC。署名鍵が無ければ Failure。

### SourceVaultMCPVerifyAccessGrant[grant] → Association
grant の Digest/Signature/期限/RevocationEpoch を検証する (service-loadable; 純 crypto, NBAccess 非依存)。
→ `<|Valid->True|False, Why->{...}, ...|>`

### SourceVaultMCPRevokeAllGrants[] → Association
revocation epoch を +1 し、これ以前に mint した全 grant を無効化する。

### SourceVaultMCPRequestAccess[spec] → Association
access grant 申請を LocalState の承認 queue に append-only 保存する (service)。spec: Principal / Action / ObjectRefs / Kinds / Fields / Purpose / Sink / RequestedAccessLevel / TTLSeconds。MCP client は status を poll する (sourcevault_request_access tool)。
→ `<|RequestId, Status->"Pending"|>`

### SourceVaultMCPAccessStatus[requestId] → Association
申請の状態を返す (service; sourcevault_access_status tool)。grant 期限切れは Expired 扱い。
→ `<|Status->Pending|Granted|Denied|Expired, Grant (Granted時)|>`

### SourceVaultMCPPendingAccessRequests[opts] → List
未決 (Pending・未期限) の申請一覧を返す (main kernel helper)。

### SourceVaultMCPApproveAccessRequest[requestId, opts] → Association
申請を承認して AccessGrant を mint し status sidecar に記録する (main kernel helper)。opts で発行 scope を申請値より厳しく上書きできる (緩めない想定)。戻り値は発行 grant。
Options: MaxAccessLevel / AllowedActions / AllowedKinds / Sink / TTLSeconds 等

### SourceVaultMCPDenyAccessRequest[requestId, reason:""] → Association
申請を却下し status sidecar に記録する (main kernel helper)。

## feedback / deposit (Phase F)

### SourceVaultMCPSubmitFeedback[spec] → Association
§12.3 FeedbackEnvelope を LocalState/hotlog/mcp_feedback へ append-only 記録する (service)。spec: Kind (HelpRequest | SubtaskProposal | AccessRequest | Critique | Correction | SessionNote) / Principal / Payload (Text/Goal/SuggestedRole/SuggestedCapabilities/RequestedData/EvidenceRefs) / SessionId / BatchId / PrivacyLevel / RequireApproval。PrivacyLevel は自己申告だけでなく同一 Session/Batch の observed-read max を継承し Max 合成。effective PrivacyLevel >= 0.5 は cloud participant 再送前 review が要るため RequireReview=True。MVP は記録のみ。
→ `<|EventId, Status->"Queued", Kind, RequireReview, PrivacyBasis, ...|>`

### SourceVaultMCPFeedbackQueue[opts] → List
記録済み feedback event を時刻順に返す (main kernel helper)。
Options: "Kind", "Status", "Limit"

### SourceVaultMCPDeposit[spec] → Association
LLM 生成 artifact の append-only deposit。spec: mode ("plan"|"commit") / kind / mediaType / content / policy (privacyLevel/accessTags/denyTags) / provenance (authoredBy/inputRefs/citationRefs/promptRefs) / SessionId / BatchId / idempotencyKey / Grant / Approved。
mode "plan" は書き込まず予定 policy を返す: PrivacyLevel = Max[要求, Session/Batch の observed-read max]。自己申告 SourceRefs が observed read で裏付けられない場合は fail-closed で 0.75 floor。mode "commit" は append-only 保存 (text は DerivedArtifact、binary(base64) は CommitBlob + DerivedArtifact)。commit は request-gate: DepositArtifact 権限 (有効 grant の AllowedActions、または endpoint AccessProfile の AllowedOperations に DepositArtifact) が無ければ RequireGrant を返し書込まない (既定 profile は含まないため fail-closed)。contentSHA256 + idempotencyKey で idempotent。RequiresApproval (high-privacy / 未裏付け ref) は spec "Approved"->True か grant/profile の MaxAccessLevel >= effPL が無いと RequireApproval を返し書込まない。
→ `<|Status, ArtifactUri (sv://artifact/..), DerivedArtifactRef, ContentUri, Existed, EffectivePolicy, NormalizedSourceRefs, SourceRefRoles, PrivacyBasis, RequiresApproval|>`

## WorkSession 層

### SourceVaultListWorkSessions[opts] → List
hotlog (mcp_calls / mcp_batches / mcp_deposits) を SessionId (無ければ BatchId, 無ければ heuristic) 単位の WorkSession に集約して返す (既存 trace の view であり新 source of truth ではない)。新しい順。各 record: WorkId / SessionId / BatchIds / Title / StartedAtUTC / EndedAtUTC / MCPCallCount / DepositCount / RelatedURIs / OutputURIs / MaxObservedPrivacy (観測下限・監視外含まず) / UnlinkedCallCount / LinkConfidence (Explicit/Heuristic)。
Options: "SessionId", "DateFrom", "DateTo" (YYYY-MM-DD), "MaxRows"

### SourceVaultWorkSessionRecord[workId] → Association | Missing
単一 WorkSession を返す。未存在は `Missing["WorkSessionNotFound"]`。

### SourceVaultWorkSessionDataset[opts] → Dataset
WorkSession 一覧を notebook 俯瞰用 Dataset で返す。MaxObservedPrivacy は観測ベースの下限推定で監視外読み取りを含まない (release 判断に使わない)。

### SourceVaultWorkSessionGraph[workId] → Association
WorkSession -> MCPCall / RelatedURI / OutputArtifact の nodes / edges を返す (履歴ブラウズ用; raw 本文や引数は含めない)。