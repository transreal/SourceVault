(* ::Package:: *)

(* ============================================================
   SourceVault_mcp.wl -- MCP tool schema / dispatch / provenance helper

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_mcp.wl"]]

   仕様書: sourcevault_searxng_mcp_spec_v6.md §13, §14

   位置づけ (spec v6 §14.6):
     SourceVault_mcp.wl は MCP protocol endpoint ではない。WL 側補助ライブラリであり、
     - MCP tool schema 定義
     - tools/list / tools/call / initialize の dispatch
     - argument validation / provenance 付与
     を担う。実際の HTTP / JSON-RPC transport は Python proxy 側 (Increment 6b) に置く。
     proxy は HTTP POST /mcp で受けた JSON-RPC を file command queue 経由で
     service kernel に渡し、service が SourceVaultMCPDispatch を呼ぶ。

   service-loadable 制約: FrontEnd / Notebook / NBAccess 非依存。
   結果は JSON 安全 (string / assoc-of-string / list / bool) に保つ。
   ============================================================ *)

BeginPackage["SourceVault`"]

SourceVaultMCPDispatch::usage =
  "SourceVaultMCPDispatch[method, params] は MCP JSON-RPC の method (initialize/tools/list/\n" <>
  "tools/call/ping) を処理し、JSON-RPC result に相当する Association を返す。\n" <>
  "未知 method は Failure[\"MCPMethodNotFound\", ...] (proxy が JSON-RPC error に変換)。";

SourceVaultMCPTools::usage =
  "SourceVaultMCPTools[] は MCP tool 定義 (name/description/inputSchema) のリストを返す。";

SourceVaultMCPCallTool::usage =
  "SourceVaultMCPCallTool[name, args] は tool を実行し MCP result <|\"content\",\"isError\"|> を返す。";

SourceVaultMCPServerInfo::usage =
  "SourceVaultMCPServerInfo[] は MCP serverInfo (<|\"name\",\"version\"|>) を返す。";

$SourceVaultMCPProtocolVersion::usage =
  "$SourceVaultMCPProtocolVersion は initialize で返す MCP protocol version。";

(* ---- Universal MCP Access: URI 層 (universal spec §3.1 / §3.1.1, Phase A) ---- *)

$SourceVaultURINamespaces::usage =
  "$SourceVaultURINamespaces は sv:// URI の予約 identity namespace のリスト。\n" <>
  "object / chunk / artifact / hash / group / relation / snapshot / record / citation。\n" <>
  "mail / web / pdf などの data class は URI namespace ではなく Class / MediaType / Kind sidecar に持つ。";

SourceVaultParseURI::usage =
  "SourceVaultParseURI[uri] は sv:// URI または legacy ref (blob:sha256:.. / snapshot:class:hex) を\n" <>
  "解析し <|Valid, Form, Scheme, Namespace, Segments, Id, CanonicalURI, ...|> を返す。\n" <>
  "未知 namespace / arity 不一致は Valid->False で fail-closed。純関数 (NBAccess 非依存)。";

SourceVaultBuildURI::usage =
  "SourceVaultBuildURI[namespace, id] / [namespace, {seg..}] は予約 namespace と arity を検証し、\n" <>
  "各 segment を percent-encoding した正準 sv:// URI 文字列を返す。namespace/arity 不正は Failure。";

SourceVaultValidURIQ::usage =
  "SourceVaultValidURIQ[uri] は uri が well-formed な sv:// URI または解決可能な legacy ref なら True。";

SourceVaultResolveURI::usage =
  "SourceVaultResolveURI[uri, opts] は URI を正規化し <|CanonicalURI, AlternateURIs, Namespace,\n" <>
  "Class, Kind, Adapter, InternalStableId, ObjectSnapshotRef, ContentHash, ResolutionConfidence|> を返す。\n" <>
  "ResolutionConfidence: Exact (正準) / Alias (legacy ref) / Ambiguous / NotFound。\n" <>
  "opts \"Return\"->\"CanonicalURI\" で canonical 文字列のみ、\"AccessRequest\"->req で将来 gate に渡す。\n" <>
  "Phase A skeleton: 構文正規化のみ (adapter による実 object 解決・access gate は後続 increment)。";

SourceVaultCanonicalURI::usage =
  "SourceVaultCanonicalURI[uri, accessRequest:Automatic] は uri の canonical sv:// URI 文字列を返す\n" <>
  "(SourceVaultResolveURI[..., \"Return\"->\"CanonicalURI\"] の薄い wrapper)。URI を key / edge /\n" <>
  "group member / SourceRef として保存する前に必ずこれで正規化する。";

SourceVaultURIForObject::usage =
  "SourceVaultURIForObject[objectOrRef, opts] は object / 内部 ref から canonical sv:// URI を返す\n" <>
  "adapter hook。Phase A skeleton では legacy ref 文字列や CanonicalURI/Ref/BlobRef を持つ assoc を\n" <>
  "正規化する。adapter registry 経由の実 object 解決は後続 increment。";

(* ---- Universal MCP Access: adapter registry / access model (universal spec §4.1 / §2, Phase A) ---- *)

SourceVaultRegisterMCPDataAdapter::usage =
  "SourceVaultRegisterMCPDataAdapter[name, spec] は data adapter を登録する。spec 必須: \"Kinds\" ({_String..})。\n" <>
  "任意: \"Capabilities\" (Search/ReadMetadata/ReadSummary/ReadContext/ReadBody/DepositArtifact/\n" <>
  "ResolveObjectURI/SemanticSearch/MetadataFilter -> bool)、\"Search\"/\"Resolve\"/\"Read\"/\"SummaryRow\"/\n" <>
  "\"Metadata\"/\"Authorize\"/\"URIForObject\" 関数。Capabilities は未指定 key を False で補完する。";

SourceVaultListMCPDataAdapters::usage =
  "SourceVaultListMCPDataAdapters[] は登録済み adapter 名のリストを返す。";

SourceVaultResolveMCPDataAdapter::usage =
  "SourceVaultResolveMCPDataAdapter[name] は登録済み adapter spec を返す。未登録は Missing[\"AdapterNotRegistered\"]。";

SourceVaultNormalizePrincipal::usage =
  "SourceVaultNormalizePrincipal[input, opts] は MCP request 主体を Principal 連想に正規化する。\n" <>
  "ClientName / ProviderClass が tool 引数由来なら自己申告 (provenance) 扱いで、authoritative\n" <>
  "ProviderClass は opts \"Trusted\" (transport/grant/main-kernel で確立) からのみ採用し、無ければ \"Unknown\"。";

SourceVaultNormalizeAccessRequest::usage =
  "SourceVaultNormalizeAccessRequest[spec, opts] は MCP tool call を AccessRequest 連想 (spec §2.2) に\n" <>
  "正規化する。\"AccessLevel\" を正準とし \"MaxPrivacyLevel\" は入力互換 alias。ScopePolicy は既定\n" <>
  "(RequireAccessTags {}, AllowAccessTags All, DenyAccessTags {}, Untagged \"MetadataOnly\") を補完。";

SourceVaultEffectiveAccessLevel::usage =
  "SourceVaultEffectiveAccessLevel[{ceiling..}] は指定された access ceiling 群の最も厳しい値 (Min) を返す\n" <>
  "(spec §2.4)。numeric でない要素 (Automatic/Missing/None) は無視する。alias を重複して渡してよい (Min は冪等)。\n" <>
  "numeric が皆無なら opts \"Default\" (既定 0.5 = cloud 安全境界) を返す。";

SourceVaultMCPCatalog::usage =
  "SourceVaultMCPCatalog[opts] は登録済み adapter の catalog を JSON 安全な連想で返す。\n" <>
  "各 adapter は name/kinds/available/capabilities/requiresGrantFor を持ち、unavailable なら\n" <>
  "unavailableReason を付ける。トップに defaultReturnFormats。opts \"IncludeUnavailable\"->False で\n" <>
  "unavailable adapter を除外。MCP tool sourcevault_catalog の実体 (spec §9.2 / §16)。";

(* ---- Universal MCP Access: model AccessProfile (universal spec §2.5, AccessProfileRef 方式) ---- *)

SourceVaultSetModelAccessProfile::usage =
  "SourceVaultSetModelAccessProfile[provider, intent, modelId, profile] は model 別 AccessProfile (§2.5) を\n" <>
  "PrivateVault/config/mcp-access-profiles.json に永続化する (AccessProfileRef 方式・GitHub 非公開)。profile:\n" <>
  "MaxAccessLevel / AllowedSinks / AllowedProjections / DeniedProjections / ScopePolicy / RequireGrantFor 等。\n" <>
  "modelId に \"*\" を渡すと provider/intent の wildcard profile。戻り値は正規化済み profile。";

SourceVaultGetModelAccessProfile::usage =
  "SourceVaultGetModelAccessProfile[provider, intent, modelId] は保存済み AccessProfile を返す。\n" <>
  "未登録は Missing[\"AccessProfileNotFound\"]。";

SourceVaultResolveAccessProfile::usage =
  "SourceVaultResolveAccessProfile[request] は request (Provider/ModelId/ModelIntent/TrustDomain) に対する\n" <>
  "実効 AccessProfile を解決する。exact (provider:intent:modelId) -> wildcard (provider:intent:* / provider:*:*)\n" <>
  "-> default の順。default は trust-domain cap (cloud 0.49 / local 1.0) と安全側 ScopePolicy で、profile 未登録\n" <>
  "時に既存 ceiling を変えない。戻り値 <|AccessProfileRef, Source(Exact/Wildcard/Default), Profile|>。";

SourceVaultListModelAccessProfiles::usage =
  "SourceVaultListModelAccessProfiles[] は保存済み AccessProfile の ProfileId リストを返す。";

(* ---- Universal MCP Access: prompt delivery / runtime capability (universal spec §2.5a, Phase A) ---- *)

SourceVaultResolvePromptDeliveryProfile::usage =
  "SourceVaultResolvePromptDeliveryProfile[request, opts] は model / 実行環境 / MCP 可否から\n" <>
  "PromptDeliveryProfile (spec §2.5a) を返す。request key: provider / modelId / clientKind /\n" <>
  "mcpToolsVisible / sourcevaultMcpEnabled / canCallMcpDuringInference / localFolderReadableByTool /\n" <>
  "localPackageDirectoryReadable (いずれも client 申告は advisory)。TrustDomain / TrustCeiling は\n" <>
  "opts \"Trusted\" と provider 級 cap (NBGetProviderMaxAccessLevel, guarded) から server 側で決め、\n" <>
  "自己申告では緩めない。返値は PromptStrategy (MCPDeferred/InlineContext/Hybrid/LocalToolRefs/\n" <>
  "NoSourceVault)、UnknownInputFloor (常に数値)、RequireReviewOnUnmediatedInput、Warnings を含む。\n" <>
  "route / model 解決は prompt router に委譲する薄い planning layer (re-implement しない)。";

SourceVaultMCPRuntimeCapabilities::usage =
  "SourceVaultMCPRuntimeCapabilities[args] は MCP tool sourcevault_runtime_capabilities の実体。\n" <>
  "SourceVaultResolvePromptDeliveryProfile を JSON 安全な camelCase 出力 (deliveryProfileId / trustDomain /\n" <>
  "promptStrategy / outputTrustCeiling / canCallMcpDuringInference / warnings ...) に整形する (spec §16)。";

(* ---- Universal MCP Access: LLM job / MCPCall trace + output privacy (universal spec §13.3 / §13.4) ---- *)

SourceVaultMintTraceId::usage =
  "SourceVaultMintTraceId[kind] は trace 用の opaque correlation id を生成する\n" <>
  "(kind: batch/job/trace/session/work/call -> svbatch-/svjob-/svtrace-/svsession-/svwork-/svmcp-)。\n" <>
  "capability ではなく、漏れても権限を与えない (spec §13.3)。trusted host が mint する想定。";

SourceVaultNormalizeMCPCallRecord::usage =
  "SourceVaultNormalizeMCPCallRecord[spec] は MCP call 監査 record (spec §13.3) を既定補完して正規化する。\n" <>
  "MaxReleasedPrivacy は released projection 自身の privacy (§4.1)。ProjectionPrivacyBasis は\n" <>
  "Recomputed | SourcePrivacyFallback (§6 / r4 C2)。LinkConfidence は Explicit/Metadata/Heuristic/Unlinked。";

SourceVaultObservedReadMax::usage =
  "SourceVaultObservedReadMax[records, opts] は privacy 会計の安全側 observed-read 上限 (max) を返す。\n" <>
  "opts \"BatchId\" / \"SessionId\" で trusted grouping に filter (無指定なら全件)。heuristic link も\n" <>
  "過小評価回避のため Max の上側に含める (spec §13.4 / P3 / P4)。numeric 皆無なら opts \"Default\" (既定 0.0)。";

SourceVaultEstimateOutputPrivacy::usage =
  "SourceVaultEstimateOutputPrivacy[jobSpec, opts] は LLM 出力の OutputPrivacyEstimate (spec §13.4) を\n" <>
  "純関数で返す。jobSpec: DeliveryProfile / PromptPrivacyMax / Batch(Session)ObservedReadMax /\n" <>
  "LocalToolReadPrivacyMax 等。opts \"Records\"->{MCPCall..}。PrivacyLevel は intrinsic = 観測入力の Max\n" <>
  "(監視外 channel 時は UnknownInputFloor へ引き上げ)。TrustCeiling では削らない (T1: sink/env は egress 時の\n" <>
  "NBAuthorize で加える)。NBAccess EffectiveRiskScore の ObservedInputRisk 項に相当。Confidence (High/\n" <>
  "Medium/Low) と RequireReview を §13.4 判定表どおり付与。declassification ではない (egress で再 gate)。";

SourceVaultStartBatch::usage =
  "SourceVaultStartBatch[spec] は prospective な BatchId を mint する (spec §13.3 / N2)。trusted host\n" <>
  "(main kernel / orchestrator) が呼ぶ前提で、client tool 引数からは mint させない。spec: SessionId /\n" <>
  "Title / DeliveryProfileId / ExpectedJobCount。LocalState/hotlog/mcp_batches へ marker を記録し、\n" <>
  "<|BatchId, SessionId, Status->\"Running\", StartedAtUTC, MintAuthority->\"TrustedHost\"|> を返す。";

SourceVaultRecordMCPCall::usage =
  "SourceVaultRecordMCPCall[spec] は MCP call 監査 record を正規化し LocalState/hotlog/mcp_calls/\n" <>
  "YYYY-MM.jsonl へ append-only 記録する (spec §13.3)。best-effort instrumentation で、LocalState 未解決や\n" <>
  "書込失敗でも応答を壊さない。戻り値 <|CallId, Recorded(bool), MaxReleasedPrivacy|>。単一書き手は service kernel。";

SourceVaultMCPCallsRecent::usage =
  "SourceVaultMCPCallsRecent[opts] は記録済み MCPCall を時刻順に返す (main/service helper)。\n" <>
  "opts \"BatchId\" / \"SessionId\" で trusted grouping に filter、\"Limit\"。SourceVaultObservedReadMax の入力。";

(* ---- Universal MCP Access: search 契約層 (universal spec §5 / §6 / §8, Phase B) ---- *)

SourceVaultNormalizeSearchSpec::usage =
  "SourceVaultNormalizeSearchSpec[spec] は MCP の SearchSpec (spec §5.1) を既定補完して正規化する。\n" <>
  "kinds に \"all\" があれば個別指定を無視。filters の accessLevelMax を正準、privacyMax を alias とする。\n" <>
  "return.format 既定 compactText、scope.untagged 既定 MetadataOnly。";

SourceVaultNormalizeSearchResult::usage =
  "SourceVaultNormalizeSearchResult[row, opts] は adapter の生 result row を SearchResult (spec §6) に\n" <>
  "正規化する。URI を canonical 化し、Summary/Snippet を MaxChars で truncation、未開示は\n" <>
  "Missing[\"NotReleased\"] 等で示す。opts: \"Adapter\"/\"Kind\"/\"ReleasedProjection\"/\n" <>
  "\"IncludeSnippets\"/\"IncludeMetadata\"/\"MaxChars\"。release gate 判定は呼び出し側で行う。";

SourceVaultRenderSearchResults::usage =
  "SourceVaultRenderSearchResults[results, format] は正規化済み SearchResult のリストを返却形式に整える。\n" <>
  "\"compactText\" (LLM 可読 text)、\"referencesOnly\" (URI+citation のみ text)、\"structuredJson\"\n" <>
  "(structured list をそのまま返し tool 層で JSON 化) (spec §8)。";

SourceVaultMCPSearch::usage =
  "SourceVaultMCPSearch[searchSpec, opts] は SearchSpec を正規化し、kinds に適合する available な\n" <>
  "search adapter を選び、各 adapter search → SearchResult 正規化 → limit/offset → render する横断検索の\n" <>
  "orchestration (spec §11.1)。戻り値 <|Results, Count, TotalBeforeLimit, Adapters, Format, Rendered,\n" <>
  "AccessRequest|>。opts \"Principal\" / \"Trusted\"。sourcevault_search tool の実体。\n" <>
  "結果は per-result release gate (SourceVaultMCPReleaseGate) を通し、戻り値に ReleaseGated 件数を含む。";

SourceVaultMCPGet::usage =
  "SourceVaultMCPGet[uri, opts] は単一の sv:// URI を解決し、所有 adapter の Resolve で低漏洩\n" <>
  "メタ/サマリー projection を取り、SourceVaultMCPReleaseGate (B3) で出口 gate して返す (spec §11.2)。\n" <>
  "戻り値 <|URI, Found, Released, Adapter, Result(Permit時のみ), Access, RequiresGrantFor, Why,\n" <>
  "AccessRequest|>。body/raw/attachment は含めず requiresGrant を示す (実 grant は Phase D)。\n" <>
  "opts \"Principal\" / \"Trusted\"。sourcevault_get tool の実体。";

SourceVaultMCPReleaseGate::usage =
  "SourceVaultMCPReleaseGate[result, accessRequest] は正規化済み SearchResult を返却してよいか判定し\n" <>
  "<|\"Decision\"->\"Permit\"|\"Deny\", \"Why\"->{...}, ...|> を返す (spec §11, §2.4)。判定: DenyTag 交差、\n" <>
  "Privacy.Level > EffectiveAccessLevel、cloud sink (ProviderClass CloudLLM/Unknown + Sink MCPResponse) で\n" <>
  "Level>=0.5 は Deny。Privacy.Level が数値でない (web/Public, search 自己 gate 済) は Permit。\n" <>
  "release context の MaxPrivacyLevel と request AccessLevel の最小を実効上限にする。";

(* ---- Phase D / Increment D1: AccessGrant + 申請/承認 (spec §2.3, §11.3) ---- *)
SourceVaultMCPEnsureGrantKey::usage =
  "SourceVaultMCPEnsureGrantKey[] は LocalState/secrets/sourcevault-grant-signing-key.json に grant 署名用の\n" <>
  "shared secret (HMAC 鍵) が無ければ生成する (main↔service 共有・MCP transport token とは別物)。\n" <>
  "戻り値 <|KeyId, Created(bool), Path|>。LocalState 未解決なら Failure。";

SourceVaultMCPMintAccessGrant::usage =
  "SourceVaultMCPMintAccessGrant[spec] は §2.3 の AccessGrant を発行し HMAC 署名して返す (main kernel)。\n" <>
  "spec: Principal/AllowedActions/AllowedKinds/AllowedObjectRefs/MaxAccessLevel/AllowedFields/Purpose/Sink/\n" <>
  "TTLSeconds。Digest=正準JSON の SHA256、Signature=同 HMAC。署名鍵が無ければ Failure。";

SourceVaultMCPVerifyAccessGrant::usage =
  "SourceVaultMCPVerifyAccessGrant[grant] は grant の Digest/Signature/期限/RevocationEpoch を検証し\n" <>
  "<|Valid->True|False, Why->{...}, ...|> を返す (service-loadable; 純 crypto, NBAccess 非依存)。";

SourceVaultMCPRevokeAllGrants::usage =
  "SourceVaultMCPRevokeAllGrants[] は revocation epoch を +1 し、これ以前に mint した全 grant を無効化する。";

SourceVaultMCPRequestAccess::usage =
  "SourceVaultMCPRequestAccess[spec] は access grant 申請を LocalState の承認 queue に append-only 保存し\n" <>
  "<|RequestId, Status->\"Pending\"|> を返す (service)。spec: Principal/Action/ObjectRefs/Kinds/Fields/Purpose/\n" <>
  "Sink/RequestedAccessLevel/TTLSeconds。MCP client は status を poll する (sourcevault_request_access tool)。";

SourceVaultMCPAccessStatus::usage =
  "SourceVaultMCPAccessStatus[requestId] は申請の状態 <|Status->Pending|Granted|Denied|Expired, Grant(Granted時)|>\n" <>
  "を返す (service; sourcevault_access_status tool)。grant 期限切れは Expired 扱い。";

SourceVaultMCPPendingAccessRequests::usage =
  "SourceVaultMCPPendingAccessRequests[opts] は未決 (Pending・未期限) の申請一覧を返す (main kernel helper)。";

SourceVaultMCPApproveAccessRequest::usage =
  "SourceVaultMCPApproveAccessRequest[requestId, opts] は申請を承認して AccessGrant を mint し status sidecar に\n" <>
  "記録する (main kernel helper)。opts で発行 scope (MaxAccessLevel/AllowedActions/AllowedKinds/Sink/TTLSeconds 等) を\n" <>
  "申請値より厳しく上書きできる (緩めることはしない想定)。戻り値は発行 grant。";

SourceVaultMCPDenyAccessRequest::usage =
  "SourceVaultMCPDenyAccessRequest[requestId, reason_:\"\"] は申請を却下し status sidecar に記録する (main kernel helper)。";

(* ---- Phase F / §12: ClaudeOrchestrator feedback bridge (MVP=記録のみ) ---- *)
SourceVaultMCPSubmitFeedback::usage =
  "SourceVaultMCPSubmitFeedback[spec] は §12.3 FeedbackEnvelope を LocalState/hotlog/mcp_feedback へ\n" <>
  "append-only 記録し <|EventId, Status->\"Queued\", Kind|> を返す (service)。spec: Kind (HelpRequest|\n" <>
  "SubtaskProposal|AccessRequest|Critique|Correction|SessionNote) / Principal / Payload(Text/Goal/\n" <>
  "SuggestedRole/SuggestedCapabilities/RequestedData/EvidenceRefs) / SessionId / BatchId / PrivacyLevel / RequireApproval。\n" <>
  "PrivacyLevel は自己申告だけでなく同一 Session/Batch の observed-read max (Inc6 hotlog) を継承し Max 合成 (§12.3)。\n" <>
  "effective PrivacyLevel >= 0.5 は cloud participant 再送前 review が要るため RequireReview=True とし、戻り値と\n" <>
  "PrivacyBasis に記録する。MVP は記録のみ。Orchestrator 側の queue/accept/subtask 昇格は将来。";
SourceVaultMCPFeedbackQueue::usage =
  "SourceVaultMCPFeedbackQueue[opts] は記録済み feedback event を時刻順に返す (main kernel helper)。\n" <>
  "opts \"Kind\" / \"Status\" / \"Limit\"。";

SourceVaultMCPDeposit::usage =
  "SourceVaultMCPDeposit[spec] は LLM 生成 artifact の append-only deposit (spec §10.7 / §11.5)。\n" <>
  "spec: mode (\"plan\"|\"commit\") / kind / mediaType / content / policy(privacyLevel/accessTags/denyTags) /\n" <>
  "provenance(authoredBy/inputRefs/citationRefs/promptRefs) / SessionId / BatchId / idempotencyKey。\n" <>
  "mode \"plan\" は書き込まず、§10.7.2 継承後の予定 policy を返す: PrivacyLevel = Max[要求, Session/Batch の\n" <>
  "observed-read max]。自己申告 SourceRefs が observed read で裏付けられない場合は fail-closed で 0.75 floor。\n" <>
  "戻り値に EffectivePolicy / NormalizedSourceRefs / SourceRefRoles / PrivacyBasis / RequiresApproval。\n" <>
  "mode \"commit\" は append-only 保存: text は DerivedArtifact、binary(base64) は CommitBlob + DerivedArtifact。\n" <>
  "commit は request-gate (§11.5/§15.3): DepositArtifact 権限 (有効 grant の AllowedActions、または endpoint\n" <>
  "AccessProfile の AllowedOperations に DepositArtifact) が無ければ RequireGrant を返し書込まない。spec\n" <>
  "\"Grant\" に AccessGrant を渡す。既定 profile の AllowedOperations は DepositArtifact を含まない (fail-closed)。\n" <>
  "contentSHA256 + idempotencyKey で idempotent、per-session/batch quota、低 weight \"Deposited\" 参照イベント。\n" <>
  "RequiresApproval (high-privacy / 未裏付け ref) は spec \"Approved\"->True か grant/profile の MaxAccessLevel >=\n" <>
  "effPL 無しで RequireApproval を返し書込まない。\n" <>
  "戻り値 <|Status, ArtifactUri(sv://artifact/..), DerivedArtifactRef, ContentUri, Existed, EffectivePolicy|>。";

(* ---- Universal MCP Access: WorkSession layer (universal spec §13.5) ---- *)

SourceVaultListWorkSessions::usage =
  "SourceVaultListWorkSessions[opts] は hotlog (mcp_calls / mcp_batches / mcp_deposits) を\n" <>
  "SessionId (無ければ BatchId, 無ければ heuristic) 単位の WorkSession に集約して返す (spec §13.5;\n" <>
  "既存 trace の view であり新 source of truth ではない)。各 record: WorkId / SessionId / BatchIds /\n" <>
  "Title / StartedAtUTC / EndedAtUTC / MCPCallCount / DepositCount / RelatedURIs / OutputURIs /\n" <>
  "MaxObservedPrivacy (観測下限・監視外含まず §13.4) / UnlinkedCallCount / LinkConfidence(Explicit/Heuristic)。\n" <>
  "opts: \"SessionId\" / \"DateFrom\" / \"DateTo\" (YYYY-MM-DD) / \"MaxRows\"。新しい順。";

SourceVaultWorkSessionRecord::usage =
  "SourceVaultWorkSessionRecord[workId] は単一 WorkSession を返す。未存在は Missing[\"WorkSessionNotFound\"]。";

SourceVaultWorkSessionDataset::usage =
  "SourceVaultWorkSessionDataset[opts] は WorkSession 一覧を notebook 俯瞰用 Dataset で返す。\n" <>
  "MaxObservedPrivacy は観測ベースの下限推定で監視外読み取りを含まない (§13.4); release 判断に使わない。";

SourceVaultWorkSessionGraph::usage =
  "SourceVaultWorkSessionGraph[workId] は WorkSession -> MCPCall / RelatedURI / OutputArtifact の\n" <>
  "nodes / edges を返す (履歴ブラウズ用; raw 本文や引数は含めない)。";

Begin["`MCPPrivate`"]

If[! StringQ[SourceVault`$SourceVaultMCPProtocolVersion],
  SourceVault`$SourceVaultMCPProtocolVersion = "2024-11-05"];

SourceVaultMCPServerInfo[] := <|"name" -> "sourcevault", "version" -> "0.1.0"|>;

(* ============================================================
   Universal MCP Access -- URI 層 (universal spec §3.1 / §3.1.1)
   Phase A / Increment 1。純関数・service-loadable (NBAccess/FrontEnd 非依存)。

   設計 (review r7/r8 U1-U3):
   - 第 1 segment は identity namespace に固定 dispatch。data class は URI でなく sidecar。
   - 正規化の唯一の入口は SourceVaultResolveURI / SourceVaultCanonicalURI /
     SourceVaultURIForObject。adapter が独自に URI 文字列を組み立て永続化しない。
   - legacy 内部 ref (blob:sha256:.. / snapshot:class:hex) は alternate とし canonical へ正規化。
   - 本 increment は構文正規化のみ。adapter による実 object 解決・access gate は後続。
   ============================================================ *)

(* 予約 namespace と arity (namespace の後に来る path segment 数) *)
SourceVault`$SourceVaultURINamespaces = {
  "object", "chunk", "artifact", "hash", "group",
  "relation", "snapshot", "record", "citation", "file"};

iSVURIArity = <|
  "object" -> 1, "chunk" -> 1, "artifact" -> 1, "relation" -> 1,
  "record" -> 1, "citation" -> 1, "file" -> 1,
  "hash" -> 2, "snapshot" -> 2, "group" -> 2|>;

(* percent-encoding。opaque id 内の "/" ":" "#" "?" 空白等を 1 segment に収める *)
iSVURIEnc[s_String] := URLEncode[s];
iSVURIEnc[x_] := URLEncode[ToString[x]];
iSVURIDec[s_String] := URLDecode[s];
iSVURIDec[x_] := x;

(* ---- parse ---- *)
iSVParseSv[uri_String] := Module[{rest, parts, ns, arity, segs, dec},
  rest = StringDrop[uri, StringLength["sv://"]];
  parts = StringSplit[rest, "/"];
  If[parts === {},
    Return[<|"Valid" -> False, "Form" -> "Invalid", "Input" -> uri, "Reason" -> "EmptyURI"|>]];
  ns = First[parts];
  arity = Lookup[iSVURIArity, ns, $Failed];
  If[arity === $Failed,
    Return[<|"Valid" -> False, "Form" -> "Invalid", "Input" -> uri,
      "Namespace" -> ns, "Reason" -> "UnknownNamespace"|>]];
  segs = Rest[parts];
  If[Length[segs] =!= arity || ! AllTrue[segs, StringQ[#] && # =!= "" &],
    Return[<|"Valid" -> False, "Form" -> "Invalid", "Input" -> uri,
      "Namespace" -> ns, "Reason" -> "ArityMismatch",
      "Expected" -> arity, "Got" -> Length[segs]|>]];
  dec = iSVURIDec /@ segs;
  <|"Valid" -> True, "Form" -> "Canonical", "Scheme" -> "sv", "Namespace" -> ns,
    "Segments" -> dec, "Id" -> Last[dec],
    "CanonicalURI" -> ("sv://" <> ns <> "/" <> StringRiffle[iSVURIEnc /@ dec, "/"]),
    "Input" -> uri|>
];

iSVParseLegacyBlob[ref_String] := Module[{hex},
  hex = StringDrop[ref, StringLength["blob:sha256:"]];
  If[hex === "",
    Return[<|"Valid" -> False, "Form" -> "Invalid", "Input" -> ref, "Reason" -> "EmptyHash"|>]];
  <|"Valid" -> True, "Form" -> "LegacyInternal", "Scheme" -> "blob", "Namespace" -> "hash",
    "Segments" -> {"sha256", hex}, "Id" -> hex,
    "CanonicalURI" -> ("sv://hash/sha256/" <> iSVURIEnc[hex]), "Input" -> ref|>
];

(* core の "snapshot:<class>:<hex>" を最後の ":" で class/hex に分ける (core iResolveRef と同型) *)
iSVParseLegacySnapshot[ref_String] := Module[{rest, pos, class, hex},
  rest = StringDrop[ref, StringLength["snapshot:"]];
  pos = StringPosition[rest, ":"];
  If[pos === {},
    Return[<|"Valid" -> False, "Form" -> "Invalid", "Input" -> ref, "Reason" -> "MalformedSnapshotRef"|>]];
  pos = pos[[-1, 1]];
  class = StringTake[rest, pos - 1];
  hex = StringDrop[rest, pos];
  If[class === "" || hex === "",
    Return[<|"Valid" -> False, "Form" -> "Invalid", "Input" -> ref, "Reason" -> "MalformedSnapshotRef"|>]];
  <|"Valid" -> True, "Form" -> "LegacyInternal", "Scheme" -> "snapshot", "Namespace" -> "snapshot",
    "Segments" -> {class, hex}, "Id" -> hex,
    "CanonicalURI" -> ("sv://snapshot/" <> iSVURIEnc[class] <> "/" <> iSVURIEnc[hex]), "Input" -> ref|>
];

SourceVaultParseURI[uri_String] := Which[
  StringStartsQ[uri, "sv://"], iSVParseSv[uri],
  StringStartsQ[uri, "blob:sha256:"], iSVParseLegacyBlob[uri],
  StringStartsQ[uri, "snapshot:"], iSVParseLegacySnapshot[uri],
  True, <|"Valid" -> False, "Form" -> "Invalid", "Input" -> uri, "Reason" -> "UnknownScheme"|>
];
SourceVaultParseURI[x_] := <|"Valid" -> False, "Form" -> "Invalid", "Input" -> x, "Reason" -> "NotAString"|>;

(* ---- build ---- *)
SourceVaultBuildURI[ns_String, seg_String] := SourceVaultBuildURI[ns, {seg}];
SourceVaultBuildURI[ns_String, segs_List] := Module[{arity},
  arity = Lookup[iSVURIArity, ns, $Failed];
  Which[
    arity === $Failed,
      Failure["UnknownURINamespace", <|"Namespace" -> ns|>],
    Length[segs] =!= arity,
      Failure["URIArityMismatch", <|"Namespace" -> ns, "Expected" -> arity, "Got" -> Length[segs]|>],
    ! AllTrue[segs, StringQ[#] && # =!= "" &],
      Failure["URIEmptySegment", <|"Namespace" -> ns, "Segments" -> segs|>],
    True,
      "sv://" <> ns <> "/" <> StringRiffle[iSVURIEnc /@ segs, "/"]
  ]];

(* ---- predicate ---- *)
SourceVaultValidURIQ[uri_String] := TrueQ[Lookup[SourceVaultParseURI[uri], "Valid", False]];
SourceVaultValidURIQ[_] := False;

(* ---- resolve / canonical ---- *)
Options[SourceVaultResolveURI] = {"Return" -> "Association", "AccessRequest" -> Automatic};
SourceVaultResolveURI[uri_String, OptionsPattern[]] := Module[{p, conf, res, ns, intSnap},
  p = SourceVaultParseURI[uri];
  If[! TrueQ[Lookup[p, "Valid", False]],
    res = <|"CanonicalURI" -> Missing["NotResolved"], "AlternateURIs" -> {},
      "Namespace" -> Lookup[p, "Namespace", Missing[]], "Class" -> Missing["Unknown"],
      "Kind" -> Missing["Unknown"], "Adapter" -> Missing[],
      "InternalStableId" -> Missing[], "ObjectSnapshotRef" -> Missing[],
      "ContentHash" -> Missing[], "ResolutionConfidence" -> "NotFound",
      "Reason" -> Lookup[p, "Reason", "Invalid"], "Input" -> uri|>,
    (* --- valid --- *)
    ns = Lookup[p, "Namespace"];
    conf = If[Lookup[p, "Form"] === "Canonical", "Exact", "Alias"];
    intSnap = If[ns === "snapshot",
      "snapshot:" <> StringRiffle[Lookup[p, "Segments"], ":"], Missing[]];
    res = <|"CanonicalURI" -> Lookup[p, "CanonicalURI"],
      "AlternateURIs" -> If[conf === "Alias", {uri}, {}],
      "Namespace" -> ns, "Class" -> Missing["Unknown"], "Kind" -> Missing["Unknown"],
      "Adapter" -> Missing[], "InternalStableId" -> Missing[],
      "ObjectSnapshotRef" -> intSnap,
      "ContentHash" -> If[ns === "hash", Lookup[p, "Id"], Missing[]],
      "ResolutionConfidence" -> conf, "Input" -> uri|>
  ];
  Switch[OptionValue["Return"],
    "CanonicalURI", Lookup[res, "CanonicalURI"],
    _, res]
];

SourceVaultCanonicalURI[uri_String, accessRequest_: Automatic] :=
  SourceVaultResolveURI[uri, "Return" -> "CanonicalURI", "AccessRequest" -> accessRequest];

(* ---- object -> canonical URI hook (skeleton) ---- *)
SourceVaultURIForObject[ref_String, opts___] :=
  With[{c = SourceVaultCanonicalURI[ref]}, If[MissingQ[c], Missing["NoCanonicalURI"], c]];
SourceVaultURIForObject[obj_Association, opts___] := Which[
  StringQ[Lookup[obj, "CanonicalURI", Null]], SourceVaultCanonicalURI[obj["CanonicalURI"]],
  StringQ[Lookup[obj, "URI", Null]], SourceVaultCanonicalURI[obj["URI"]],
  StringQ[Lookup[obj, "Ref", Null]], SourceVaultCanonicalURI[obj["Ref"]],
  StringQ[Lookup[obj, "BlobRef", Null]], SourceVaultCanonicalURI[obj["BlobRef"]],
  True, Missing["NoAdapterURIHook"]  (* adapter registry hook は後続 increment *)
];
SourceVaultURIForObject[_, opts___] := Missing["UnsupportedObject"];

(* ============================================================
   Universal MCP Access -- adapter registry (universal spec §4.1)
   Phase A / Increment 2。純関数 + module-level registry。
   ============================================================ *)

If[! AssociationQ[$svMCPAdapters], $svMCPAdapters = <||>];

iSVAdapterCapabilityKeys = {
  "Search", "ReadMetadata", "ReadSummary", "ReadContext", "ReadBody",
  "DepositArtifact", "ResolveObjectURI", "SemanticSearch", "MetadataFilter"};

iSVNormalizeCapabilities[capsIn_] := Module[{caps = If[AssociationQ[capsIn], capsIn, <||>]},
  Association[(# -> TrueQ[Lookup[caps, #, False]]) & /@ iSVAdapterCapabilityKeys]];

SourceVaultRegisterMCPDataAdapter[name_String, spec_Association] := Module[{kinds, caps, norm},
  kinds = Lookup[spec, "Kinds", $Failed];
  If[! MatchQ[kinds, {___String}],
    Return[Failure["AdapterMissingKinds",
      <|"MessageTemplate" -> "adapter `1` の \"Kinds\" は {_String..} 必須です。", "Name" -> name|>]]];
  caps = iSVNormalizeCapabilities[Lookup[spec, "Capabilities", <||>]];
  norm = Join[<|"Authorize" -> Automatic|>, spec, <|"Name" -> name, "Capabilities" -> caps|>];
  $svMCPAdapters[name] = norm;
  <|"Status" -> "OK", "Name" -> name, "Kinds" -> kinds, "Capabilities" -> caps|>
];
SourceVaultRegisterMCPDataAdapter[name_String, _] :=
  Failure["AdapterSpecNotAssociation", <|"Name" -> name|>];

SourceVaultListMCPDataAdapters[] := Sort @ Keys[$svMCPAdapters];

SourceVaultResolveMCPDataAdapter[name_String] :=
  Lookup[$svMCPAdapters, name, Missing["AdapterNotRegistered"]];

(* ============================================================
   Universal MCP Access -- access model 正規化 (universal spec §2.1 / §2.2 / §2.4)
   Phase A / Increment 2。純関数。
   ============================================================ *)

(* 自己申告でない authoritative ProviderClass のみ採用 (spec §2.1: release 判定に
   client 自己申告を使わない)。trusted が無ければ Unknown に落とす。 *)
Options[SourceVaultNormalizePrincipal] = {"Trusted" -> <||>};
SourceVaultNormalizePrincipal[input_Association, OptionsPattern[]] := Module[
  {trusted, pcTrusted, validClasses = {"CloudLLM", "LocalLLM", "PrivateLLM"}},
  trusted = OptionValue["Trusted"]; If[! AssociationQ[trusted], trusted = <||>];
  pcTrusted = Lookup[trusted, "ProviderClass", Missing[]];
  <|
    "Kind" -> Lookup[trusted, "Kind", Lookup[input, "Kind", "MCPClient"]],
    (* ClientName は provenance (自己申告可)。release 判定に使わない。 *)
    "ClientName" -> Lookup[trusted, "ClientName",
      Lookup[input, "ClientName", Lookup[input, "_mcpClient", Missing["Unknown"]]]],
    "ProviderClass" -> If[MemberQ[validClasses, pcTrusted], pcTrusted, "Unknown"],
    "ProviderClassTrusted" -> MemberQ[validClasses, pcTrusted],
    "AssertedProviderClass" -> Lookup[input, "ProviderClass", Missing[]],
    "SessionId" -> Lookup[trusted, "SessionId", Lookup[input, "SessionId", Missing["Unknown"]]],
    "UserPresent" -> Lookup[trusted, "UserPresent", Lookup[input, "UserPresent", Missing["Unknown"]]]
  |>
];
SourceVaultNormalizePrincipal[input_, opts___] :=
  SourceVaultNormalizePrincipal[<||>, opts] /; ! AssociationQ[input];

(* 最初の numeric (Automatic/Missing/None でない) を返す *)
iSVCoalesceLevel[vals__] := Module[{nums = Cases[{vals}, _?NumericQ]},
  If[nums === {}, Automatic, First[nums]]];

Options[SourceVaultNormalizeAccessRequest] = {"Principal" -> Automatic};
SourceVaultNormalizeAccessRequest[spec_Association, OptionsPattern[]] := Module[
  {principal, accessLevel, scopeIn, scope},
  principal = OptionValue["Principal"];
  principal = Which[
    AssociationQ[principal], principal,
    AssociationQ[Lookup[spec, "Principal", Null]], Lookup[spec, "Principal"],
    True, SourceVaultNormalizePrincipal[<||>]];
  accessLevel = iSVCoalesceLevel[
    Lookup[spec, "AccessLevel", Automatic], Lookup[spec, "MaxPrivacyLevel", Automatic]];
  scopeIn = Lookup[spec, "ScopePolicy", <||>]; If[! AssociationQ[scopeIn], scopeIn = <||>];
  scope = <|
    "RequireAccessTags" -> Lookup[scopeIn, "RequireAccessTags", {}],
    "AllowAccessTags" -> Lookup[scopeIn, "AllowAccessTags", All],
    "DenyAccessTags" -> Lookup[scopeIn, "DenyAccessTags", {}],
    "Untagged" -> Lookup[scopeIn, "Untagged", "MetadataOnly"]|>;
  <|
    "Action" -> Lookup[spec, "Action", Missing["Required"]],
    "Principal" -> principal,
    "Purpose" -> Lookup[spec, "Purpose", Missing[]],
    "Sink" -> Lookup[spec, "Sink", "MCPResponse"],
    "ReleaseContext" -> Lookup[spec, "ReleaseContext", None],
    "Provider" -> Lookup[spec, "Provider", Automatic],
    "ModelId" -> Lookup[spec, "ModelId", Automatic],
    "ModelIntent" -> Lookup[spec, "ModelIntent", Automatic],
    "AccessLevel" -> accessLevel,
    "MaxPrivacyLevel" -> Lookup[spec, "MaxPrivacyLevel", Missing["LegacyAlias"]],
    "ScopePolicy" -> scope,
    "RequestedProjection" -> Lookup[spec, "RequestedProjection", Missing[]],
    "RequestedKinds" -> Lookup[spec, "RequestedKinds", {}],
    "SessionGrant" -> Lookup[spec, "SessionGrant", None],
    "CreatedAtUTC" -> Lookup[spec, "CreatedAtUTC", Missing[]]
  |>
];

(* 実効上限 = 指定 ceiling の Min。alias 重複可 (Min は冪等)。numeric 皆無なら安全側既定 (0.5)。 *)
Options[SourceVaultEffectiveAccessLevel] = {"Default" -> 0.5};
SourceVaultEffectiveAccessLevel[vals_List, OptionsPattern[]] := Module[{nums},
  nums = Cases[vals, _?NumericQ];
  If[nums === {}, OptionValue["Default"], Min[N /@ nums]]];

(* ============================================================
   Universal MCP Access -- sourcevault_catalog (universal spec §9.2 / §16)
   Phase A / Increment 3。registry (Inc2) を反映する catalog builder。
   adapter の実 Search/Read 関数の wiring は Phase B 以降。
   ============================================================ *)

(* 内部 Capability key -> catalog 公開名 (spec §16 の短い名前) *)
iSVCatalogCapMap = <|
  "Search" -> "search", "ReadMetadata" -> "metadata", "ReadSummary" -> "summary",
  "ReadContext" -> "context", "ReadBody" -> "body", "DepositArtifact" -> "deposit",
  "ResolveObjectURI" -> "resolve_uri", "SemanticSearch" -> "semantic",
  "MetadataFilter" -> "metadataFilter"|>;

(* 可用性: spec の "AvailableProbe" (Function[]) があれば動的評価、無ければ静的 "Available"。
   eagle/mail のような main-kernel でのみ使える adapter は probe で headless 時に unavailable になる。 *)
iSVAdapterAvailableQ[aspec_Association] := With[{p = Lookup[aspec, "AvailableProbe", None]},
  If[p === None, TrueQ[Lookup[aspec, "Available", True]], TrueQ[Quiet[p[]]]]];

iSVCatalogRow[name_String] := Module[{spec, caps, capList, avail, row},
  spec = SourceVaultResolveMCPDataAdapter[name];
  If[! AssociationQ[spec],
    Return[<|"name" -> name, "kinds" -> {}, "available" -> False,
      "capabilities" -> {}, "requiresGrantFor" -> {}|>]];
  caps = Lookup[spec, "Capabilities", <||>];
  capList = (iSVCatalogCapMap[#] &) /@
    Select[iSVAdapterCapabilityKeys, TrueQ[Lookup[caps, #, False]] &];
  avail = iSVAdapterAvailableQ[spec];
  row = <|"name" -> name, "kinds" -> Lookup[spec, "Kinds", {}], "available" -> avail,
    "capabilities" -> capList, "requiresGrantFor" -> Lookup[spec, "RequireGrantFor", {}]|>;
  If[! avail, row["unavailableReason"] = ToString @ Lookup[spec, "UnavailableReason", "Unavailable"]];
  row
];

Options[SourceVaultMCPCatalog] = {"IncludeUnavailable" -> True};
SourceVaultMCPCatalog[OptionsPattern[]] := Module[{rows},
  rows = iSVCatalogRow /@ SourceVaultListMCPDataAdapters[];
  If[! TrueQ[OptionValue["IncludeUnavailable"]],
    rows = Select[rows, TrueQ[Lookup[#, "available", True]] &]];
  <|"adapters" -> rows,
    "defaultReturnFormats" -> {"compactText", "structuredJson", "referencesOnly"}|>
];

(* ============================================================
   Universal MCP Access -- prompt delivery / runtime capability (universal spec §2.5a)
   Phase A / Increment 4。純関数。MCP 可否に応じた PromptStrategy と、自己申告で緩めない
   server 側 TrustCeiling を決める薄い planning layer。route/model 解決は prompt router に委譲。
   ============================================================ *)

(* provider -> trust domain の server 側分類。client 申告 clientKind では緩めない (spec §2.5a / F3)。
   cloud model (anthropic/openai/claude-code/codex 等) は Cloud、ローカル推論は Local、不明は Unknown。 *)
iSVClassifyTrustDomain[provider_String] := Module[{p = ToLowerCase[provider]},
  Which[
    StringContainsQ[p, "anthropic" | "claude" | "openai" | "gpt" | "codex" | "chatgpt" |
      "gemini" | "google" | "azure" | "bedrock" | "cohere" | "mistral"], "Cloud",
    StringContainsQ[p, "lmstudio" | "ollama" | "llamacpp" | "llama.cpp" | "vllm" |
      "koboldcpp" | "localai" | "local"], "Local",
    True, "Unknown"]];
iSVClassifyTrustDomain[_] := "Unknown";

(* provider 級 access ceiling。NBAccess 非依存で guarded: 未ロード/未登録時は trust domain の安全側既定。
   (NBAccess` シンボル未定義時は未評価が返り NumericQ False -> 既定に落ちる。) *)
iSVProviderAccessCeiling[provider_String, trustDomain_String] := Module[{v},
  v = Quiet @ Check[NBAccess`NBGetProviderMaxAccessLevel[ToLowerCase[provider]], Missing[]];
  Which[
    NumericQ[v], N[v],
    MemberQ[{"Cloud", "Unknown"}, trustDomain], 0.49,
    True, 1.0]];
iSVProviderAccessCeiling[_, trustDomain_String] :=
  If[MemberQ[{"Cloud", "Unknown"}, trustDomain], 0.49, 1.0];

(* PromptStrategy 決定 (spec §2.5a の boolean tuple 優先順位)。
   1) MCP を推論中に使える: 基本 MCPDeferred、local tool も併用でき cloud sink なら Hybrid。
   2) 使えない: local folder を tool で読めれば LocalToolRefs、それ以外は host が
      release gate 済み projection を inline する InlineContext を既定 fallback とする。
   NoSourceVault は SourceVault が全く関与しない場合の enum 値であり、本 resolver の既定にはしない。 *)
iSVPromptStrategy[canCallDuring_, svMcpEnabled_, localFolder_, cloudish_] :=
  Module[{mcpUsable = TrueQ[canCallDuring] && TrueQ[svMcpEnabled]},
    Which[
      mcpUsable && TrueQ[localFolder] && TrueQ[cloudish], "Hybrid",
      mcpUsable, "MCPDeferred",
      TrueQ[localFolder], "LocalToolRefs",
      True, "InlineContext"]];

Options[SourceVaultResolvePromptDeliveryProfile] = {"Trusted" -> <||>, "ResolveAccessProfile" -> True};
SourceVaultResolvePromptDeliveryProfile[request_Association, OptionsPattern[]] := Module[
  {trusted, provider, modelId, intent, clientKind, mcpToolsVisible, svMcpEnabled, mcpAvailable,
   canCallDuring, localFolder, localPkg, trustDomain, cloudish, providerCap, ap, apMax, apRef,
   trustCeiling, fullyMediated, unknownFloor, requireReviewUnmediated, canUseUri, strategy,
   warnings, profileId},
  trusted = OptionValue["Trusted"]; If[! AssociationQ[trusted], trusted = <||>];

  (* provenance (自己申告許可) *)
  provider = ToString @ Lookup[request, "provider", Lookup[request, "Provider", "unknown"]];
  modelId = ToString @ Lookup[request, "modelId", Lookup[request, "ModelId", "unknown"]];
  intent = ToString @ Lookup[request, "modelIntent", Lookup[request, "ModelIntent", "default"]];
  clientKind = Lookup[request, "clientKind", Lookup[request, "ClientKind", Missing["Unknown"]]];

  (* MCP 可否 (self-report だが advisory; hard cap は緩めない) *)
  mcpToolsVisible = With[{t = Lookup[request, "mcpToolsVisible", {}]}, If[ListQ[t], t, {}]];
  svMcpEnabled = TrueQ[Lookup[request, "sourcevaultMcpEnabled", mcpToolsVisible =!= {}]];
  mcpAvailable = TrueQ[Lookup[request, "mcpAvailable", mcpToolsVisible =!= {}]];
  canCallDuring = TrueQ[Lookup[request, "canCallMcpDuringInference", mcpAvailable && svMcpEnabled]];
  localFolder = TrueQ[Lookup[request, "localFolderReadableByTool", False]];
  localPkg = TrueQ[Lookup[request, "localPackageDirectoryReadable", False]];

  (* trust domain: trusted host が与えた authoritative 値を優先、無ければ server 側分類。 *)
  trustDomain = With[{td = Lookup[trusted, "TrustDomain", Missing[]]},
    If[StringQ[td], td, iSVClassifyTrustDomain[provider]]];
  cloudish = MemberQ[{"Cloud", "Unknown"}, trustDomain];

  (* AccessProfile を解決 (§2.5) し MaxAccessLevel を ceiling に Min 合成、AccessProfileRef を付与。
     profile 未登録時の default は trust-domain cap (cloud0.49/local1.0) なので既存 ceiling を変えない。 *)
  providerCap = iSVProviderAccessCeiling[provider, trustDomain];
  ap = If[TrueQ[OptionValue["ResolveAccessProfile"]],
    Quiet @ SourceVaultResolveAccessProfile[<|"Provider" -> provider, "ModelId" -> modelId,
      "ModelIntent" -> intent, "TrustDomain" -> trustDomain|>], <||>];
  apMax = With[{m = Lookup[Lookup[ap, "Profile", <||>], "MaxAccessLevel", Missing[]]},
    If[NumericQ[m], N[m], If[cloudish, 0.49, 1.0]]];
  apRef = Lookup[ap, "AccessProfileRef",
    Lookup[trusted, "AccessProfileRef", Lookup[request, "accessProfileRef", Missing[]]]];
  (* TrustCeiling: cloud/unknown は <=0.49、local/private は provider cap (<=1.0)。Min 合成 (§2.4)。 *)
  trustCeiling = If[cloudish,
    SourceVaultEffectiveAccessLevel[{providerCap, apMax, 0.49}],
    SourceVaultEffectiveAccessLevel[{providerCap, apMax, 1.0}]];

  (* InputsFullyMediated: 監視外 read channel (local tool / local pkg) が無いとき True (§13.4)。 *)
  fullyMediated = ! (localFolder || localPkg);
  (* UnknownInputFloor は常に数値 (§13.4)。local/private は 1.0、cloud/unknown は 0.0 (review flag が担う)。 *)
  unknownFloor = If[cloudish, 0.0, 1.0];
  (* cloud profile + 監視外 channel → RequireReview 必須 (§13.4: 数値だけで表さない)。 *)
  requireReviewUnmediated = cloudish && ! fullyMediated;
  canUseUri = canCallDuring;  (* 推論中に sourcevault_get で sv:// を解決できるなら prompt 内で有用 *)

  strategy = iSVPromptStrategy[canCallDuring, svMcpEnabled, localFolder, cloudish];

  warnings = {};
  If[cloudish && localFolder, AppendTo[warnings,
    "Cloud/remote model sink: local tool reads are NOT a grant to send >=0.49 raw/private " <>
    "content to the model context (local execution != model release)."]];
  If[mcpAvailable && ! svMcpEnabled, AppendTo[warnings,
    "MCP tools visible but SourceVault MCP not enabled; falling back to " <> strategy <> "."]];
  If[trustDomain === "Unknown", AppendTo[warnings,
    "Unknown trust domain; treated as cloud-equivalent (TrustCeiling capped at 0.49)."]];
  If[strategy === "InlineContext" && cloudish, AppendTo[warnings,
    "InlineContext fallback is a safe-side capability reduction, not an equivalent of MCPDeferred: " <>
    "only EffectiveAccessLevel<0.5 materials can be inlined for a cloud sink."]];

  profileId = StringRiffle[{ToLowerCase[provider], modelId,
    If[canCallDuring && svMcpEnabled, "mcp", "nomcp"], "v1"}, ":"];

  <|
    "DeliveryProfileId" -> profileId,
    "Provider" -> provider, "ModelId" -> modelId, "ClientKind" -> clientKind,
    "TrustDomain" -> trustDomain,
    "LocalPackageDirectoryReadable" -> localPkg,
    "LocalFolderReadableByTool" -> localFolder,
    "MCPAvailable" -> mcpAvailable,
    "SourceVaultMCPEnabled" -> svMcpEnabled,
    "SourceVaultMCPTools" -> mcpToolsVisible,
    "CanCallMCPDuringInference" -> canCallDuring,
    "CanUseSVURIInPrompt" -> canUseUri,
    "InputsFullyMediatedBySourceVault" -> fullyMediated,
    "PromptStrategy" -> strategy,
    "TrustCeiling" -> trustCeiling,
    "UnknownInputFloor" -> unknownFloor,
    "RequireReviewOnUnmediatedInput" -> requireReviewUnmediated,
    "AccessProfileRef" -> apRef,
    "AccessProfileSource" -> Lookup[ap, "Source", Missing[]],
    "Warnings" -> warnings
  |>
];
SourceVaultResolvePromptDeliveryProfile[req_, opts___] :=
  SourceVaultResolvePromptDeliveryProfile[<||>, opts] /; ! AssociationQ[req];

(* sourcevault_runtime_capabilities tool 整形 (spec §16) *)
SourceVaultMCPRuntimeCapabilities[args_Association] := Module[{p = SourceVaultResolvePromptDeliveryProfile[args]},
  <|
    "deliveryProfileId" -> Lookup[p, "DeliveryProfileId"],
    "provider" -> Lookup[p, "Provider"], "modelId" -> Lookup[p, "ModelId"],
    "trustDomain" -> Lookup[p, "TrustDomain"],
    "mcpAvailable" -> Lookup[p, "MCPAvailable"],
    "sourcevaultMcpEnabled" -> Lookup[p, "SourceVaultMCPEnabled"],
    "canCallMcpDuringInference" -> Lookup[p, "CanCallMCPDuringInference"],
    "canUseSvUriInPrompt" -> Lookup[p, "CanUseSVURIInPrompt"],
    "promptStrategy" -> Lookup[p, "PromptStrategy"],
    "inputsFullyMediatedBySourceVault" -> Lookup[p, "InputsFullyMediatedBySourceVault"],
    "outputTrustCeiling" -> Lookup[p, "TrustCeiling"],
    "unknownInputFloor" -> Lookup[p, "UnknownInputFloor"],
    "requireReviewOnUnmediatedInput" -> Lookup[p, "RequireReviewOnUnmediatedInput"],
    "accessProfileRef" -> Lookup[p, "AccessProfileRef"],
    "warnings" -> Lookup[p, "Warnings", {}]
  |>];

(* ============================================================
   Universal MCP Access -- LLM job / MCPCall trace + output privacy (universal spec §13.3 / §13.4)
   Phase A/B / Increment 5。純関数 (id mint / MCPCall record 正規化 / observed-read 集計 / 出力 privacy 推定)。
   永続化 (LocalState hotlog) と search/get への配線・BatchId plumbing は後続 increment。
   trace 系は host-facing instrumentation であり model tool には露出しない (spec §9.2 / N3)。
   ============================================================ *)

$SourceVaultTraceIdPrefix = <|
  "batch" -> "svbatch", "job" -> "svjob", "trace" -> "svtrace",
  "session" -> "svsession", "work" -> "svwork", "call" -> "svmcp"|>;
SourceVaultMintTraceId[kind_String] := Module[
  {pfx = Lookup[$SourceVaultTraceIdPrefix, ToLowerCase[kind], "svid"]},
  pfx <> "-" <> StringReplace[CreateUUID[], "-" -> ""]];
SourceVaultMintTraceId[] := SourceVaultMintTraceId["trace"];

(* §13.3 MCP call 監査 record 正規化。MaxReleasedPrivacy は released projection 自身の privacy (§4.1)。 *)
SourceVaultNormalizeMCPCallRecord[spec_Association] := <|
  "CallId" -> Lookup[spec, "CallId", SourceVaultMintTraceId["call"]],
  "BatchId" -> Lookup[spec, "BatchId", Missing[]],
  "JobId" -> Lookup[spec, "JobId", Missing[]],
  "TraceToken" -> Lookup[spec, "TraceToken", Missing[]],
  "SessionId" -> Lookup[spec, "SessionId", Missing[]],
  "Tool" -> Lookup[spec, "Tool", Missing[]],
  "ArgumentURIs" -> Lookup[spec, "ArgumentURIs", {}],
  "ReleasedURIs" -> Lookup[spec, "ReleasedURIs", {}],
  "ReleasedProjection" -> Lookup[spec, "ReleasedProjection", "metadata"],
  "MaxReleasedPrivacy" -> Lookup[spec, "MaxReleasedPrivacy", 0.0],
  "ProjectionPrivacyBasis" -> Lookup[spec, "ProjectionPrivacyBasis", "Recomputed"],
  "AccessGrantId" -> Lookup[spec, "AccessGrantId", Missing[]],
  "Decision" -> Lookup[spec, "Decision", "Permit"],
  "LinkConfidence" -> Lookup[spec, "LinkConfidence", "Explicit"],
  "StartedAtUTC" -> Lookup[spec, "StartedAtUTC", Missing[]],
  "FinishedAtUTC" -> Lookup[spec, "FinishedAtUTC", Missing[]]|>;

(* §13.4 / P3 / N2: privacy 会計の安全側 observed-read max。trusted grouping (Batch/Session) で filter。
   heuristic link も過小評価回避のため Max の上側に含める。 *)
Options[SourceVaultObservedReadMax] = {"BatchId" -> Missing[], "SessionId" -> Missing[], "Default" -> 0.0};
SourceVaultObservedReadMax[records_List, OptionsPattern[]] := Module[{bid, sid, sel, nums},
  bid = OptionValue["BatchId"]; sid = OptionValue["SessionId"];
  sel = Select[records, AssociationQ];
  sel = Select[sel, Function[r, Which[
    StringQ[bid], Lookup[r, "BatchId", Missing[]] === bid,
    StringQ[sid], Lookup[r, "SessionId", Missing[]] === sid,
    True, True]]];
  nums = Cases[Lookup[#, "MaxReleasedPrivacy", Missing[]] & /@ sel, _?NumericQ];
  If[nums === {}, OptionValue["Default"], Max[N /@ nums]]];

(* §13.4 Confidence 判定表。prompt 未申告 or Heuristic/Unlinked link -> Low、監視外 channel -> Medium。 *)
iSVEstimateConfidence[fullyMediated_, promptKnown_, linkConfidences_List] := Which[
  ! TrueQ[promptKnown], "Low",
  MemberQ[linkConfidences, "Heuristic"] || MemberQ[linkConfidences, "Unlinked"], "Low",
  ! TrueQ[fullyMediated], "Medium",
  True, "High"];

(* §13.4 OutputPrivacyEstimate (純関数)。PrivacyLevel は intrinsic = 観測入力の Max
   (監視外 channel 時は UnknownInputFloor へ引き上げ)。TrustCeiling では削らない (T1)。
   sink/environment は焼き込まず egress 時の NBAuthorize で加える。declassification ではない。 *)
Options[SourceVaultEstimateOutputPrivacy] = {"Records" -> {}};
SourceVaultEstimateOutputPrivacy[jobSpec_Association, OptionsPattern[]] := Module[
  {deliv, promptMax, promptKnown, batchMax, sessionMax, localMax, uploadMax, userPromptMax,
   records, recNums, candidateNums, observedMax, fullyMediated, unknownFloor, trustCeiling,
   cloudish, floorApplied, requireReview, linkConfs, confidence, fallbackQ, basis},
  deliv = Lookup[jobSpec, "DeliveryProfile", <||>]; If[! AssociationQ[deliv], deliv = <||>];
  records = OptionValue["Records"]; If[! ListQ[records], records = {}];
  promptMax = Lookup[jobSpec, "PromptPrivacyMax", Missing[]]; promptKnown = NumericQ[promptMax];
  batchMax = Lookup[jobSpec, "BatchObservedReadMax", Missing[]];
  sessionMax = Lookup[jobSpec, "SessionObservedReadMax", Missing[]];
  localMax = Lookup[jobSpec, "LocalToolReadPrivacyMax", Missing[]];
  uploadMax = Lookup[jobSpec, "UserUploadPrivacyMax", Missing[]];
  userPromptMax = Lookup[jobSpec, "ExplicitUserPromptPrivacyMax", Missing[]];
  recNums = Cases[
    Lookup[#, "MaxReleasedPrivacy", Missing[]] & /@ Select[records, AssociationQ], _?NumericQ];
  candidateNums = Join[
    Cases[{promptMax, batchMax, sessionMax, localMax, uploadMax, userPromptMax}, _?NumericQ],
    recNums, {0.0}];
  observedMax = Max[candidateNums];
  fullyMediated = TrueQ[Lookup[deliv, "InputsFullyMediatedBySourceVault",
    Lookup[jobSpec, "InputsFullyMediatedBySourceVault", True]]];
  unknownFloor = Lookup[deliv, "UnknownInputFloor", Lookup[jobSpec, "UnknownInputFloor", 0.0]];
  If[! NumericQ[unknownFloor], unknownFloor = 0.0];
  trustCeiling = Lookup[deliv, "TrustCeiling", Lookup[jobSpec, "TrustCeiling", Missing[]]];
  cloudish = MemberQ[{"Cloud", "Unknown"},
    Lookup[deliv, "TrustDomain", Lookup[jobSpec, "TrustDomain", "Unknown"]]];
  (* T1: TrustCeiling では削らない。監視外 channel があれば floor で安全側に引き上げのみ。 *)
  floorApplied = If[! fullyMediated, Max[observedMax, unknownFloor], observedMax];
  (* §13.4 / P1: cloud + 監視外 channel は数値では cloud<0.5 を超えられないため RequireReview 必須。 *)
  requireReview = TrueQ[Lookup[deliv, "RequireReviewOnUnmediatedInput", False]] ||
    (cloudish && ! fullyMediated);
  linkConfs = Lookup[#, "LinkConfidence", "Explicit"] & /@ Select[records, AssociationQ];
  confidence = iSVEstimateConfidence[fullyMediated, promptKnown, linkConfs];
  fallbackQ = MemberQ[
    Lookup[#, "ProjectionPrivacyBasis", "Recomputed"] & /@ Select[records, AssociationQ],
    "SourcePrivacyFallback"];
  basis = DeleteCases[{
    If[promptKnown, "PromptPrivacyMax", Nothing],
    If[NumericQ[batchMax], "BatchObservedReadMax", Nothing],
    If[NumericQ[sessionMax], "SessionObservedReadMax", Nothing],
    If[recNums =!= {}, "MCPCall.MaxReleasedPrivacy", Nothing],
    If[! fullyMediated, "UnknownInputFloor", Nothing],
    If[fallbackQ, "SourcePrivacyFallback(may over-classify)", Nothing],
    "EffectiveRiskScore(ObservedInputRisk)"}, Nothing];
  <|
    "PrivacyLevel" -> N[floorApplied],
    "TrustCeiling" -> trustCeiling,
    "UnknownInputFloor" -> unknownFloor,
    "InputsFullyMediatedBySourceVault" -> fullyMediated,
    "RequireReview" -> requireReview,
    "Confidence" -> confidence,
    "ObservedInputMax" -> N[observedMax],
    "Basis" -> basis,
    "PrivacyInheritancePolicy" -> "MaxObservedInput"
  |>];

(* ============================================================
   Universal MCP Access -- MCPCall 永続化 + batch mint (universal spec §13.3 / §13.5)
   Phase A/B / Increment 6。MCPCall を LocalState hotlog へ append-only 記録し、per-batch /
   per-session の observed-read 集計を可能にする。BatchId は trusted host が mint (N2)。
   永続化 helper (iSVLocalStateDir / iSVAppendJSONL / iSVReadJSONLFile / iSVUTCNowString) は
   Phase D 節で定義済み (runtime 解決)。trace 系は host-facing で model tool には出さない (§9.2 / N3)。
   ============================================================ *)

iSVMCPCallsDir[] := With[{ls = iSVLocalStateDir[]},
  If[StringQ[ls], FileNameJoin[{ls, "hotlog", "mcp_calls"}], $Failed]];
iSVMCPCallsMonthFile[] := With[{d = iSVMCPCallsDir[]},
  If[StringQ[d],
    FileNameJoin[{d, DateString[TimeZoneConvert[Now, 0], {"Year", "-", "Month"}] <> ".jsonl"}], $Failed]];
iSVMCPCallsFiles[] := With[{dir = iSVMCPCallsDir[]},
  If[! StringQ[dir] || ! DirectoryQ[dir], {}, FileNames["*.jsonl", dir, 1]]];

iSVBatchesDir[] := With[{ls = iSVLocalStateDir[]},
  If[StringQ[ls], FileNameJoin[{ls, "hotlog", "mcp_batches"}], $Failed]];
iSVBatchesMonthFile[] := With[{d = iSVBatchesDir[]},
  If[StringQ[d],
    FileNameJoin[{d, DateString[TimeZoneConvert[Now, 0], {"Year", "-", "Month"}] <> ".jsonl"}], $Failed]];

(* trusted host が呼ぶ batch mint。client tool 引数からは mint させない (§13.3 / N2)。 *)
SourceVaultStartBatch[spec_Association] := Module[{bid, sid, marker, path},
  bid = SourceVaultMintTraceId["batch"];
  sid = With[{s = Lookup[spec, "SessionId", Missing[]]},
    If[StringQ[s], s, SourceVaultMintTraceId["session"]]];
  marker = <|
    "BatchId" -> bid, "SessionId" -> sid,
    "Title" -> Lookup[spec, "Title", Missing[]],
    "DeliveryProfileId" -> Lookup[spec, "DeliveryProfileId", Missing[]],
    "ExpectedJobCount" -> Lookup[spec, "ExpectedJobCount", Missing[]],
    "Status" -> "Running", "StartedAtUTC" -> iSVUTCNowString[],
    "MintAuthority" -> "TrustedHost"|>;
  path = iSVBatchesMonthFile[];
  If[StringQ[path], Quiet @ iSVAppendJSONL[path, marker]];
  marker];
SourceVaultStartBatch[] := SourceVaultStartBatch[<||>];

(* MCPCall を正規化し hotlog へ append。best-effort (失敗は応答を壊さない)。 *)
SourceVaultRecordMCPCall[spec_Association] := Module[{rec, path},
  rec = SourceVaultNormalizeMCPCallRecord[spec];
  If[! StringQ[Lookup[rec, "StartedAtUTC", Missing[]]], rec["StartedAtUTC"] = iSVUTCNowString[]];
  If[! StringQ[Lookup[rec, "FinishedAtUTC", Missing[]]], rec["FinishedAtUTC"] = rec["StartedAtUTC"]];
  path = iSVMCPCallsMonthFile[];
  If[StringQ[path], Quiet @ iSVAppendJSONL[path, rec]];
  <|"CallId" -> Lookup[rec, "CallId"], "Recorded" -> StringQ[path],
    "MaxReleasedPrivacy" -> Lookup[rec, "MaxReleasedPrivacy"]|>];

(* 記録済み MCPCall を読み出し (observed-read 集計の入力)。 *)
Options[SourceVaultMCPCallsRecent] = {"BatchId" -> All, "SessionId" -> All, "Limit" -> Automatic};
SourceVaultMCPCallsRecent[OptionsPattern[]] := Module[{all, bid, sid, lim},
  all = Join @@ (iSVReadJSONLFile /@ iSVMCPCallsFiles[]);
  bid = OptionValue["BatchId"]; sid = OptionValue["SessionId"]; lim = OptionValue["Limit"];
  If[StringQ[bid], all = Select[all, Lookup[#, "BatchId", Missing[]] === bid &]];
  If[StringQ[sid], all = Select[all, Lookup[#, "SessionId", Missing[]] === sid &]];
  all = SortBy[all, Lookup[#, "StartedAtUTC", ""] &];
  If[IntegerQ[lim] && lim >= 0, all = Take[all, -Min[Length[all], lim]]];
  all];

(* release 済み結果集合から MaxReleasedPrivacy (released projection 自身の privacy) を取り出す。 *)
iSVMaxReleasedPrivacy[results_List] := Module[{nums},
  nums = Cases[Lookup[Lookup[#, "Privacy", <||>], "Level", Missing[]] & /@ Select[results, AssociationQ],
    _?NumericQ];
  If[nums === {}, 0.0, Max[N /@ nums]]];

(* tool dispatch から呼ぶ recording 配線。search/get の出力から MCPCall を作り記録 (best-effort)。 *)
iSVRecordToolCall[tool_String, args_Association, out_Association] := Quiet @ Module[
  {results, projection, idGiven},
  results = Which[
    ListQ[Lookup[out, "Results", Null]], Lookup[out, "Results"],
    AssociationQ[Lookup[out, "Result", Null]], {Lookup[out, "Result"]},
    True, {}];
  projection = With[{v = Lookup[args, "view", Missing[]]}, If[StringQ[v], v, "metadata"]];
  idGiven = StringQ[Lookup[args, "batchId", Null]] || StringQ[Lookup[args, "jobId", Null]] ||
    StringQ[Lookup[args, "traceToken", Null]];
  SourceVaultRecordMCPCall[<|
    "Tool" -> tool,
    "BatchId" -> Lookup[args, "batchId", Missing[]],
    "JobId" -> Lookup[args, "jobId", Missing[]],
    "TraceToken" -> Lookup[args, "traceToken", Missing[]],
    "SessionId" -> Lookup[args, "sessionId", Missing[]],
    "ReleasedURIs" -> Cases[Lookup[#, "URI", Missing[]] & /@ Select[results, AssociationQ], _String],
    "ReleasedProjection" -> projection,
    "MaxReleasedPrivacy" -> iSVMaxReleasedPrivacy[results],
    "Decision" -> If[TrueQ[Lookup[out, "Released", Null]] ||
      (IntegerQ[Lookup[out, "Count", Null]] && Lookup[out, "Count"] > 0), "Permit", "Redacted"],
    "LinkConfidence" -> If[idGiven, "Explicit", "Heuristic"]|>]];

(* ============================================================
   Universal MCP Access -- model AccessProfile (universal spec §2.5 / §17.7)
   Phase A/C / Increment 7。AccessProfileRef 方式: profile 本体は PrivateVault/config に保存し
   (machine 間共有・GitHub 非公開)、registry には ref のみ。SourceVaultResolvePromptDeliveryProfile (Inc4)
   と access request の ceiling 解決に使う。scope の search/get への enforcement 配線は後続 increment。
   ============================================================ *)

iSVPrivateVaultDir[] := With[{r = Quiet @ SourceVault`SourceVaultRoot["PrivateVault"]},
  If[StringQ[r], r, $Failed]];
iSVAccessProfilesFile[] := With[{r = iSVPrivateVaultDir[]},
  If[StringQ[r], FileNameJoin[{r, "config", "mcp-access-profiles.json"}], $Failed]];

iSVNormalizeScopePolicy[s_] := Module[{sc = If[AssociationQ[s], s, <||>]},
  <|"RequireAccessTags" -> Lookup[sc, "RequireAccessTags", {}],
    "AllowAccessTags" -> Lookup[sc, "AllowAccessTags", All],
    "DenyAccessTags" -> Lookup[sc, "DenyAccessTags", {}],
    "Untagged" -> Lookup[sc, "Untagged", "MetadataOnly"]|>];

iSVAPId[provider_, intent_, modelId_] :=
  ToLowerCase[ToString[provider]] <> ":" <> ToString[intent] <> ":" <> ToString[modelId];

iSVNormalizeAccessProfile[provider_String, intent_String, modelId_String, p_Association] := <|
  "ProfileId" -> iSVAPId[provider, intent, modelId],
  "Provider" -> provider, "ModelIntent" -> intent, "ModelId" -> modelId,
  "EndpointRef" -> Lookup[p, "EndpointRef", Missing[]],
  "TrustDomain" -> Lookup[p, "TrustDomain", iSVClassifyTrustDomain[provider]],
  "MaxAccessLevel" -> With[{m = Lookup[p, "MaxAccessLevel", Missing[]]},
    If[NumericQ[m], N[m],
      If[MemberQ[{"Cloud", "Unknown"}, iSVClassifyTrustDomain[provider]], 0.49, 1.0]]],
  "AllowedSinks" -> Lookup[p, "AllowedSinks", {"LocalOnly", "MCPResponse"}],
  "AllowedOperations" -> Lookup[p, "AllowedOperations", {"Search", "ReadSummary", "ReadContext"}],
  "AllowedProjections" -> Lookup[p, "AllowedProjections", {"metadata", "summary", "snippet"}],
  "DeniedProjections" -> Lookup[p, "DeniedProjections", {"raw", "downloadOriginal"}],
  "ScopePolicy" -> iSVNormalizeScopePolicy[Lookup[p, "ScopePolicy", <||>]],
  "PurposeAllowed" -> Lookup[p, "PurposeAllowed", All],
  "RequireGrantFor" -> Lookup[p, "RequireGrantFor", {"body", "raw", "notebookCell", "mailBody"}],
  "Audit" -> Lookup[p, "Audit", <|"LogLevel" -> "DecisionOnly"|>],
  "CreatedAtUTC" -> iSVUTCNowString[]|>;

(* profile 未登録時の default。MaxAccessLevel = trust-domain cap なので既存 ceiling を変えない。 *)
iSVDefaultAccessProfile[provider_, intent_, modelId_, trustDomain_] := <|
  "ProfileId" -> iSVAPId[provider, intent, modelId],
  "Provider" -> provider, "ModelIntent" -> intent, "ModelId" -> modelId,
  "TrustDomain" -> trustDomain,
  "MaxAccessLevel" -> If[MemberQ[{"Cloud", "Unknown"}, trustDomain], 0.49, 1.0],
  "AllowedProjections" -> {"metadata", "summary", "snippet"},
  "DeniedProjections" -> {"raw", "downloadOriginal"},
  "ScopePolicy" -> <|"RequireAccessTags" -> {}, "AllowAccessTags" -> All,
    "DenyAccessTags" -> {"NoExternal", "StudentPrivate", "Personal"}, "Untagged" -> "MetadataOnly"|>,
  "RequireGrantFor" -> {"body", "raw", "notebookCell", "mailBody"}|>;

iSVLoadAccessProfiles[] := With[{path = iSVAccessProfilesFile[]},
  If[StringQ[path], With[{a = iSVReadJSONFile[path]}, If[AssociationQ[a], a, <||>]], <||>]];

SourceVaultSetModelAccessProfile[provider_String, intent_String, modelId_String, profile_Association] :=
  Module[{norm, all, path},
    norm = iSVNormalizeAccessProfile[provider, intent, modelId, profile];
    path = iSVAccessProfilesFile[];
    If[! StringQ[path], Return[Failure["PrivateVaultUnresolved", <|"Key" -> "PrivateVault"|>]]];
    all = iSVReadJSONFile[path]; If[! AssociationQ[all], all = <||>];
    all[norm["ProfileId"]] = norm;
    If[iSVWriteJSONFile[path, all] === $Failed, Return[Failure["AccessProfileWriteFailed", <||>]]];
    norm];

SourceVaultGetModelAccessProfile[provider_String, intent_String, modelId_String] :=
  Lookup[iSVLoadAccessProfiles[], iSVAPId[provider, intent, modelId],
    Missing["AccessProfileNotFound"]];

SourceVaultListModelAccessProfiles[] := Keys[iSVLoadAccessProfiles[]];

SourceVaultResolveAccessProfile[request_Association] := Module[
  {provider, intent, modelId, td, all, exact, wild, prof, src},
  provider = ToString @ Lookup[request, "Provider", Lookup[request, "provider", "unknown"]];
  intent = ToString @ Lookup[request, "ModelIntent", Lookup[request, "modelIntent", "default"]];
  modelId = ToString @ Lookup[request, "ModelId", Lookup[request, "modelId", "unknown"]];
  td = With[{t = Lookup[request, "TrustDomain", Missing[]]},
    If[StringQ[t], t, iSVClassifyTrustDomain[provider]]];
  all = iSVLoadAccessProfiles[]; If[! AssociationQ[all], all = <||>];
  exact = Lookup[all, iSVAPId[provider, intent, modelId], Missing[]];
  wild = Lookup[all, iSVAPId[provider, intent, "*"],
    Lookup[all, iSVAPId[provider, "*", "*"], Missing[]]];
  {prof, src} = Which[
    AssociationQ[exact], {exact, "Exact"},
    AssociationQ[wild], {wild, "Wildcard"},
    True, {iSVDefaultAccessProfile[provider, intent, modelId, td], "Default"}];
  <|"AccessProfileRef" -> Lookup[prof, "ProfileId", iSVAPId[provider, intent, modelId]],
    "Source" -> src, "Profile" -> prof|>];

(* ============================================================
   Universal MCP Access -- search 契約層 (universal spec §5 / §6 / §8)
   Phase B / Increment 1。純関数 (SearchSpec/SearchResult 正規化 + 返却 render)。
   実 adapter 接続・release gate 適用は Phase B Inc2 以降。
   ============================================================ *)

(* ---- SearchSpec 正規化 (§5.1) ---- *)
SourceVaultNormalizeSearchSpec[spec_Association] := Module[
  {kinds, scope, filters, ret, accessLevelMax},
  kinds = Lookup[spec, "kinds", {"all"}];
  If[! ListQ[kinds] || kinds === {}, kinds = {"all"}];
  If[MemberQ[kinds, "all"], kinds = {"all"}];  (* all は個別指定を上書き *)
  scope = Lookup[spec, "scope", <||>]; If[! AssociationQ[scope], scope = <||>];
  (* 既定を補完しつつ、index 指定 (pdfIndexProfile / index / collection) 等の追加 key は保持する *)
  scope = Join[<|
    "releaseContext" -> None, "topicTags" -> {}, "objectRefs" -> {},
    "requireAccessTags" -> {}, "denyAccessTags" -> {}, "untagged" -> "MetadataOnly"|>,
    scope];
  filters = Lookup[spec, "filters", <||>]; If[! AssociationQ[filters], filters = <||>];
  accessLevelMax = iSVCoalesceLevel[
    Lookup[filters, "accessLevelMax", Automatic], Lookup[filters, "privacyMax", Automatic]];
  filters = Join[filters, <|"accessLevelMax" -> accessLevelMax|>];
  ret = Lookup[spec, "return", <||>]; If[! AssociationQ[ret], ret = <||>];
  ret = <|
    "format" -> Lookup[ret, "format", "compactText"],
    "includeSnippets" -> TrueQ[Lookup[ret, "includeSnippets", True]],
    "includeMetadata" -> TrueQ[Lookup[ret, "includeMetadata", True]],
    "maxCharsPerResult" -> Lookup[ret, "maxCharsPerResult", 800]|>;
  <|
    "query" -> ToString @ Lookup[spec, "query", ""],
    "kinds" -> kinds, "scope" -> scope,
    "targetFields" -> Lookup[spec, "targetFields", {"title", "metadata", "summary"}],
    "methods" -> Lookup[spec, "methods", {"keyword", "metadata"}],
    "filters" -> filters,
    "limit" -> Lookup[spec, "limit", 20], "offset" -> Lookup[spec, "offset", 0],
    "sortBy" -> Lookup[spec, "sortBy", "score"], "return" -> ret,
    "purpose" -> Lookup[spec, "purpose", Missing[]],
    "sessionGrant" -> Lookup[spec, "sessionGrant", None]
  |>
];

(* ---- SearchResult 正規化 (§6) ---- *)
iSVTrunc[Missing[r___], _] := Missing[r];
iSVTrunc[s_String, n_Integer] := If[StringLength[s] > n, StringTake[s, n] <> "\[Ellipsis]", s];
iSVTrunc[x_, _] := x;

iSVResultId[uri_String] := "res-" <> StringTake[IntegerString[Hash[uri, "SHA256"], 16, 64], -12];
iSVResultId[_] := "res-unknown";

Options[SourceVaultNormalizeSearchResult] = {
  "Adapter" -> Missing[], "Kind" -> Missing[], "ReleasedProjection" -> "metadata",
  "IncludeSnippets" -> True, "IncludeMetadata" -> True, "MaxChars" -> 800};
SourceVaultNormalizeSearchResult[row_Association, OptionsPattern[]] := Module[
  {uri, maxc, inclSnip, inclMeta},
  maxc = OptionValue["MaxChars"];
  inclSnip = TrueQ[OptionValue["IncludeSnippets"]];
  inclMeta = TrueQ[OptionValue["IncludeMetadata"]];
  uri = Which[
    StringQ[Lookup[row, "URI", Null]], SourceVaultCanonicalURI[row["URI"]],
    StringQ[Lookup[row, "ObjectRef", Null]], SourceVaultCanonicalURI[row["ObjectRef"]],
    True, SourceVaultURIForObject[row]];
  If[MissingQ[uri], uri = Missing["NoURI"]];
  <|
    "ResultId" -> ToString @ Lookup[row, "ResultId", iSVResultId[uri]],
    "ObjectRef" -> uri, "URI" -> uri,
    "Adapter" -> OptionValue["Adapter"],
    "Kind" -> Lookup[row, "Kind", OptionValue["Kind"]],
    "Title" -> Lookup[row, "Title", Missing["NotReleased"]],
    "Summary" -> iSVTrunc[Lookup[row, "Summary", Missing["NotReleased"]], maxc],
    "Snippet" -> If[inclSnip, iSVTrunc[Lookup[row, "Snippet", Missing["NotReleased"]], maxc],
      Missing["NotRequested"]],
    "Citation" -> Lookup[row, "Citation", <||>],
    "Score" -> Lookup[row, "Score", Missing["NotScored"]],
    "MatchedFields" -> Lookup[row, "MatchedFields", {}],
    (* metadata 非要求でも AccessTags は scope gate (§2.6) のため必ず保持する。 *)
    "Metadata" -> With[{md = With[{m = Lookup[row, "Metadata", <||>]}, If[AssociationQ[m], m, <||>]]},
      If[inclMeta, md,
        With[{at = Lookup[md, "AccessTags", Missing[]]},
          If[MissingQ[at], Missing["NotRequested"], <|"AccessTags" -> at|>]]]],
    "Privacy" -> <|
      "Level" -> Lookup[row, "PrivacyLevel", Missing["Hidden"]],
      "Class" -> Lookup[row, "PrivacyClass", "Private"],
      "ReleasedProjection" -> OptionValue["ReleasedProjection"]|>,
    "Access" -> <|
      "Decision" -> Lookup[row, "Decision", "Permit"],
      "Why" -> Lookup[row, "Why", {}],
      "AccessHandle" -> Lookup[row, "AccessHandle", None]|>,
    "Provenance" -> <|
      "RequestTimeGateReevaluated" -> TrueQ[Lookup[row, "RequestTimeGateReevaluated", False]],
      "PolicyDigestAtRequest" -> Lookup[row, "PolicyDigestAtRequest", Missing[]]|>
  |>
];

(* ---- 返却 render (§8) ---- *)
iSVDispStr[Missing[___]] := "";
iSVDispStr[None] := "";
iSVDispStr[s_String] := s;
iSVDispStr[x_] := ToString[x];

(* 参照表示: canonical URI を優先、無ければ Citation.url (web 候補など外部 URL) *)
iSVResultRef[r_Association] := Module[{ref},
  ref = iSVDispStr[Lookup[r, "ObjectRef", Lookup[r, "URI", ""]]];
  If[ref === "", ref = iSVDispStr[Lookup[Lookup[r, "Citation", <||>], "url", ""]]];
  ref];

iSVRenderCompact[results_List] := StringRiffle[
  MapIndexed[Function[{r, i},
    Module[{title, snip, ref, dec},
      title = iSVDispStr[Lookup[r, "Title", ""]];
      snip = iSVDispStr[Lookup[r, "Snippet", ""]];
      ref = iSVResultRef[r];
      dec = iSVDispStr[Lookup[Lookup[r, "Access", <||>], "Decision", ""]];
      ToString[First[i]] <> ". " <> title <>
        If[ref =!= "", "\n   " <> ref, ""] <>
        If[snip =!= "", "\n   " <> snip, ""] <>
        If[dec =!= "" && dec =!= "Permit", "\n   [access: " <> dec <> "]", ""]]],
    results], "\n\n"];

iSVRenderRefs[results_List] := StringRiffle[
  MapIndexed[Function[{r, i},
    ToString[First[i]] <> ". " <> iSVResultRef[r] <>
      With[{lbl = iSVDispStr[Lookup[Lookup[r, "Citation", <||>], "label", ""]]},
        If[lbl =!= "", "  " <> lbl, ""]]],
    results], "\n"];

SourceVaultRenderSearchResults[results_List, format_String] := Switch[format,
  "structuredJson", results,
  "referencesOnly", iSVRenderRefs[results],
  _, iSVRenderCompact[results]];

(* JSON-safe 化 (Missing/None/Automatic -> Null, DateObject -> ISO)。structuredJson の前段。 *)
iSVJSONSafe[a_Association] := Map[iSVJSONSafe, a];
iSVJSONSafe[l_List] := iSVJSONSafe /@ l;
iSVJSONSafe[Missing[___]] := Null;
iSVJSONSafe[None] := Null;
iSVJSONSafe[Automatic] := Null;
iSVJSONSafe[d_DateObject] := DateString[d, "ISODateTime"];
iSVJSONSafe[s_String] := s;
iSVJSONSafe[b : (True | False | Null)] := b;
iSVJSONSafe[x_?NumericQ] := x;
iSVJSONSafe[x_] := ToString[x];

(* ============================================================
   Universal MCP Access -- search orchestration + search adapter
   (universal spec §11.1 / §10.2)。Phase B / Increment 2。
   ============================================================ *)

(* ---- search adapter: 既存 SourceVaultSearch (release gate 内蔵) に接続 ---- *)
(* SourceVaultSearch row -> universal SearchResult の共通 key へ写像。raw path は持ち込まない。 *)
(* #3: pdfGetChunk 用 collection 名を scope から解決 (servicemanager iWebProfileCollection と同型)。 *)
iSVPdfCollectionForScope[scope_Association] := Module[{coll, prof, p, cr},
  coll = Lookup[scope, "collection", Automatic];
  If[StringQ[coll] && coll =!= "", Return[coll]];
  prof = Lookup[scope, "pdfIndexProfile", Automatic];
  If[! StringQ[prof], Return["default"]];
  p = Quiet @ Check[SourceVault`SearchIndexPrivate`iResolve["PDFIndexProfile", prof], $Failed];
  If[! AssociationQ[p], Return["default"]];
  cr = Lookup[p, "CollectionRoot", Automatic];
  If[StringQ[cr] && cr =!= "", cr, "default"]];

(* native row は durable な SourceVaultObjectId を object URI に。legacy PDF chunk は整数 index を
   collection 込みで chunk URI に (sv://chunk/<collection>:<index>) → sourcevault_get で解決/本文取得可。 *)
iSVSearchRowURI[r_Association, coll_String : "default"] := Module[{cid, oid, ci},
  cid = ToString @ Lookup[r, "ChunkId", "?"];
  oid = Lookup[r, "SourceVaultObjectId", Missing[]];
  ci = Quiet @ Check[ToExpression[cid], $Failed];
  Which[
    StringQ[oid] && oid =!= "", SourceVaultBuildURI["object", oid],
    IntegerQ[ci], SourceVaultBuildURI["chunk", coll <> ":" <> ToString[ci]],
    cid =!= "?" && cid =!= "", SourceVaultBuildURI["chunk", cid],
    True, Missing["NoURI"]]];

iSVSearchAdapterSearch[spec_Association, accessRequest_Association] := Module[
  {scope, rc, q, lim, prof, idx, coll, chunkColl, opts, rows},
  scope = Lookup[spec, "scope", <||>]; If[! AssociationQ[scope], scope = <||>];
  rc = Lookup[scope, "releaseContext", None];
  If[! StringQ[rc], Return[{}]];  (* §10.2: release context 必須。無ければ fail-closed で空。 *)
  chunkColl = iSVPdfCollectionForScope[scope];  (* chunk URI / 後続 pdfGetChunk 用 collection 名 *)
  q = ToString @ Lookup[spec, "query", ""];
  lim = Lookup[spec, "limit", 20];
  (* どの index を引くか: PDFIndexProfile (例 "student-handbook") / native Index / Collection *)
  prof = Lookup[scope, "pdfIndexProfile", Automatic];
  idx = Lookup[scope, "index", Automatic];
  coll = Lookup[scope, "collection", Automatic];
  opts = {"ReleaseContext" -> rc, "Limit" -> lim,
    If[StringQ[prof], "PDFIndexProfile" -> prof, Nothing],
    If[StringQ[idx], "Index" -> idx, Nothing],
    If[StringQ[coll], "Collection" -> coll, Nothing]};
  (* 注意: Check[expr, $Failed] は expr が message を出しただけで $Failed を返す
     (戻り値が正常でも)。SourceVaultSearch は一部 deny 等で warning message を出すため、
     Check を使うと valid な結果を取りこぼす。message 表示は Quiet で抑え、成否は型で判定する。 *)
  rows = Quiet @ SourceVault`SourceVaultSearch[q, Sequence @@ opts];
  If[! ListQ[rows], Return[{}]];
  Function[r, <|
    "URI" -> iSVSearchRowURI[r, chunkColl], "Kind" -> "search",
    "Title" -> Lookup[Lookup[r, "Citation", <||>], "Title", Missing["NotReleased"]],
    "Snippet" -> Lookup[r, "Snippet", Missing["NotReleased"]],
    "Citation" -> Lookup[r, "Citation", <||>],
    "Score" -> Lookup[r, "Score", Missing["NotScored"]],
    "MatchedFields" -> {"snippet"},
    "Metadata" -> <|"EvidenceRef" -> Lookup[r, "EvidenceRef", Missing[]],
      "SourceVaultObjectId" -> Lookup[r, "SourceVaultObjectId", Missing[]]|>,
    "PrivacyClass" -> "Mixed",
    "Decision" -> Lookup[r, "ReleaseDecision", "Permit"],
    "RequestTimeGateReevaluated" -> TrueQ[Lookup[r, "RequestTimeGateReevaluated", False]],
    "PolicyDigestAtRequest" -> Lookup[r, "PolicyDigestAtRequest", Missing[]],
    "Why" -> Lookup[r, "Why", {}]|>] /@ rows
];

(* #3: search/PDF chunk の単一 URI 解決 + 本文 (chunk 全文) 解放。
   chunk URI = sv://chunk/<collection>:<index> (index は安定整数; pdfGetChunk で全文取得)。
   resolve は identity(metadata)のみ、本文は ReadBody (grant 必須・非cloud)。
   chunk が grant scope (AllowedObjectRefs) に在ることが arbitrary chunk 取得を防ぐ。
   PDFIndex は service-loadable なので、本文も local sink へなら service kernel で供給可。 *)
iSVPdfChunkParse[parsed_Association] := Module[{id, parts, idx, coll},
  If[Lookup[parsed, "Namespace", ""] =!= "chunk", Return[$Failed]];
  id = ToString @ Lookup[parsed, "Id", ""];
  parts = StringSplit[id, ":"];
  If[Length[parts] < 2, Return[$Failed]];
  idx = Quiet @ Check[ToExpression[Last[parts]], $Failed];
  If[! IntegerQ[idx], Return[$Failed]];
  coll = StringRiffle[Most[parts], ":"];
  <|"Collection" -> If[coll === "", "default", coll], "ChunkIndex" -> idx|>];

iSVPdfOwnsURIQ[parsed_Association] := AssociationQ[iSVPdfChunkParse[parsed]];

iSVPdfChunkResolve[parsed_Association, accessRequest_Association] := Module[{p},
  p = iSVPdfChunkParse[parsed];
  If[! AssociationQ[p], Return[Missing["NotChunkURI"]]];
  (* identity のみ。citation/Title は元の検索結果側にある (chunkIndex からは引けない)。
     PrivacyLevel は載せない → B3 は identity metadata を permit。本文は ReadBody で grant gate。 *)
  <|"Kind" -> "search", "Title" -> Missing["UseSearchResultCitation"],
    "Citation" -> <|"label" -> "PDF chunk " <> ToString[p["ChunkIndex"]] <> " @" <> p["Collection"]|>,
    "MatchedFields" -> {},
    "Metadata" -> <|"Collection" -> p["Collection"], "ChunkIndex" -> p["ChunkIndex"]|>,
    "PrivacyClass" -> "Mixed"|>];

iSVPdfReadBodyReadyQ[] := Length[DownValues[PDFIndex`pdfGetChunk]] > 0;
iSVPdfChunkReadBody[parsed_Association, grant_Association, accessRequest_Association, view_ : "body"] :=
  Module[{p, full},
    If[! iSVPdfReadBodyReadyQ[], Return[Missing["PDFIndexUnavailable"]]];
    p = iSVPdfChunkParse[parsed];
    If[! AssociationQ[p], Return[Missing["NotChunkURI"]]];
    full = Quiet @ Check[PDFIndex`pdfGetChunk[p["ChunkIndex"], p["Collection"]], $Failed];
    If[StringQ[full] && StringTrim[full] =!= "",
      <|"Body" -> full, "Kind" -> "pdfchunk"|>,
      Missing["ChunkNotFound"]]];

(* ---- web adapter: 既存 SourceVaultWebSearch (SearXNG 候補) に接続 ---- *)
(* web 検索結果は外部 URL 候補 (未 ingest)。canonical sv:// object は持たず、URL は Citation に載せる。
   SourceVaultWebSearch は List でなく <|"Results"->{...}|> を返す点が search adapter と異なる。 *)
iSVUrlId[u_String] := StringTake[IntegerString[Hash[u, "SHA256"], 16, 64], -12];
iSVUrlId[_] := "unknown";

iSVWebAdapterSearch[spec_Association, accessRequest_Association] := Module[{q, lim, run, results},
  q = ToString @ Lookup[spec, "query", ""];
  lim = Lookup[spec, "limit", 20];
  run = Quiet @ SourceVault`SourceVaultWebSearch[q, "MaxResults" -> lim,
    "RequestChannel" -> "MCP", "InitiationType" -> "MCPIngest"];
  If[! AssociationQ[run], Return[{}]];   (* Failure (SearXNG 不可) → fail-closed で空 *)
  results = Lookup[run, "Results", {}];
  If[! ListQ[results], Return[{}]];
  Function[r, <|
    "URI" -> Missing["NotStored"],   (* 外部 URL 候補。ingest 後に sv://object/snapshot 化 *)
    "Kind" -> "web",
    "Title" -> Lookup[r, "Title", Missing["NotReleased"]],
    "Snippet" -> Lookup[r, "Snippet", Missing["NotReleased"]],
    "Citation" -> <|"label" -> Lookup[r, "Title", ""], "url" -> Lookup[r, "Url", ""]|>,
    "Score" -> Lookup[r, "Score", Missing["NotScored"]],
    "MatchedFields" -> {"title", "snippet"},
    "Metadata" -> <|"Url" -> Lookup[r, "Url", Missing[]], "Engine" -> Lookup[r, "Engine", Missing[]],
      "Rank" -> Lookup[r, "Rank", Missing[]], "PublishedDate" -> Lookup[r, "PublishedDate", Missing[]]|>,
    "PrivacyClass" -> "Public",
    "ResultId" -> "web-" <> iSVUrlId[Lookup[r, "Url", ""]]|>] /@ results
];

(* ---- eagle adapter: 既存 SourceVaultEagleSummaryRow (低漏洩 row) に接続 ---- *)
(* SummaryRow は "File" (ローカルパス) を含むが、結果には絶対に含めない (raw path 非返却 §1.2)。
   PrivacyLevel を載せるので B3 gate が cloud 宛の private item を自動で落とす。
   eagle は NBAccess/eagle ライブラリ依存 → headless では AvailableProbe で unavailable。 *)
(* SummaryRow → MCP SearchResult row。search/get 共用。"File" (ローカルパス) は除外。 *)
(* Eagle の user 管理 Tags + Folders を scope 用 AccessTags にする (§2.6: ローカル user 管理 metadata)。
   暗号認証ではないが local 自己管理データなので scope filtering の信頼ソースにできる。
   SummaryRow の Tags はカンマ結合 string (SourceVault_eagle.wl: StringRiffle[..,", "]) なので
   string/list の両方を吸収する。 *)
iSVEGTagsToList[x_] := Which[
  ListQ[x], Cases[x, _String],
  StringQ[x], Select[StringTrim /@ StringSplit[x, ","], # =!= "" &],
  True, {}];
iSVEagleAccessTags[r_Association] := DeleteDuplicates @ Join[
  iSVEGTagsToList[Lookup[r, "Tags", {}]],
  iSVEGTagsToList[Lookup[r, "Folders", {}]]];

iSVEagleRowToResult[r_Association] := Module[{id = ToString @ Lookup[r, "Id", ""]},
  <|
  "URI" -> If[id =!= "", SourceVaultBuildURI["object", "eagle-" <> id], Missing["NoURI"]],
  "Kind" -> "eagle",
  "Title" -> Lookup[r, "Title", Missing["NotReleased"]],
  "Summary" -> Lookup[r, "Summary", Missing["NotReleased"]],
  "Citation" -> <|"label" -> Lookup[r, "Title", ""], "url" -> Lookup[r, "URL", ""]|>,
  "Score" -> Missing["NotScored"],
  "MatchedFields" -> {"title", "annotation", "tags"},
  (* 低漏洩 metadata のみ。"File" (ローカルパス) は意図的に除外。AccessTags を scope gate 用に surface。 *)
  "Metadata" -> <|"Ext" -> Lookup[r, "Ext", Missing[]], "Size" -> Lookup[r, "Size", Missing[]],
    "Tags" -> Lookup[r, "Tags", Missing[]], "Folders" -> Lookup[r, "Folders", Missing[]],
    "AccessTags" -> iSVEagleAccessTags[r], "AccessTagsTrust" -> "Managed",
    "Date" -> Lookup[r, "Date", Missing[]], "Annotation" -> Lookup[r, "Annotation", Missing[]],
    "Authors" -> Lookup[r, "Authors", Missing[]], "Published" -> Lookup[r, "Published", Missing[]]|>,
  "PrivacyLevel" -> Lookup[r, "PrivacyLevel", Missing["Hidden"]],
  "PrivacyClass" -> "Private",
  "ResultId" -> "eagle-" <> If[id =!= "", id, iSVUrlId[ToString[r]]]|>];

iSVEagleAdapterSearch[spec_Association, accessRequest_Association] := Module[{q, lim, items, rows},
  q = ToString @ Lookup[spec, "query", ""];
  lim = Lookup[spec, "limit", 20];
  items = Quiet @ SourceVault`SourceVaultEagleSearch[q, "Limit" -> lim];
  If[! ListQ[items], Return[{}]];
  rows = Select[(Quiet @ SourceVault`SourceVaultEagleSummaryRow[#] &) /@ items, AssociationQ];
  iSVEagleRowToResult /@ rows
];

(* Phase C2: sv://object/eagle-<id> を Eagle item metadata から解決 (原本ファイルは開かない)。 *)
iSVEagleAdapterResolve[parsed_Association, accessRequest_Association] := Module[{seg, eid, item, row},
  seg = ToString @ Lookup[parsed, "Id", ""];
  If[! StringStartsQ[seg, "eagle-"], Return[Missing["NotEagleURI"]]];
  eid = StringDrop[seg, StringLength["eagle-"]];
  If[eid === "", Return[Missing["NoId"]]];
  item = Quiet @ SourceVault`SourceVaultEagleItem[eid];
  If[! AssociationQ[item], Return[Missing["NotFound"]]];
  row = Quiet @ SourceVault`SourceVaultEagleSummaryRow[item];
  If[! AssociationQ[row], Return[Missing["NotFound"]]];
  iSVEagleRowToResult[row]
];

iSVEagleOwnsURIQ[parsed_Association] :=
  Lookup[parsed, "Namespace", ""] === "object" &&
    StringQ[Lookup[parsed, "Id", Null]] && StringStartsQ[parsed["Id"], "eagle-"];

(* D3(eagle 拡張): body/context は原本から抽出テキストを返す (grant 必須・非cloud sink)。
   raw(原本ファイル)は LLM へ返さない (§906 raw path 非返却) → RawNotReleased。
   eagle ライブラリ依存 → headless/service では MainKernelOnly。grant 検証は呼び出し側で実施済。 *)
iSVEagleReadBodyReadyQ[] :=
  Length[DownValues[SourceVault`SourceVaultEagleExtractText]] > 0 &&
   Length[DownValues[SourceVault`SourceVaultEagleItem]] > 0;
iSVEagleAdapterReadBody[parsed_Association, grant_Association, accessRequest_Association, view_:"body"] :=
  Module[{seg, eid, ext},
    If[! iSVEagleReadBodyReadyQ[], Return[Missing["MainKernelOnly"]]];
    seg = ToString @ Lookup[parsed, "Id", ""];
    If[! StringStartsQ[seg, "eagle-"], Return[Missing["NotEagleURI"]]];
    eid = StringDrop[seg, StringLength["eagle-"]];
    If[eid === "", Return[Missing["NoId"]]];
    If[view === "raw", Return[Missing["RawNotReleased"]]];  (* 原本パスは返さない *)
    ext = Quiet @ SourceVault`SourceVaultEagleExtractText[eid, "MaxChars" -> 8000];
    If[AssociationQ[ext] && Lookup[ext, "Status", ""] === "OK" && StringQ[Lookup[ext, "Text", Null]],
      <|"Body" -> ext["Text"], "Kind" -> Lookup[ext, "Kind", Missing[]], "Chars" -> Lookup[ext, "Chars", Missing[]]|>,
      Missing["ExtractFailed"]]];

(* ---- mail adapter: ディスク上の軽量メタデータ索引 (.svmailidx) に接続 ---- *)
(* SourceVaultMailSearchIndex は snapshot 本体 (本文暗号文) をメモリへロードせず、
   shard sidecar の低漏洩メタ/サマリー行 (SummaryRow 形 + Summary) だけを走査する。
   → 年単位のメールを EnsureLoaded で常駐させなくても検索できる。
   本文 (body 復号)・添付は含めない (grant 必須, Phase D/E)。
   **mail は PL 欠落を 1.0 扱い (fail-closed)** にして B3 で確実に gate する。
   maildb 依存 (索引関数は main kernel のみ) → headless では AvailableProbe で unavailable。
   privacy gate は B3 (SourceVaultMCPReleaseGate) に一本化する (source 段の MaxPrivacy 前段
   フィルタは B3 の cloud-cap と同一閾値の二重チェックで冗長 + ReleaseGated 件数を曖昧にするため
   行わない)。索引はメタのみで安価なので、gate 後に公開結果が枯れないよう source は多めに取得し、
   最終的な limit は orchestration の post-gate Take が担う。
   索引が未生成だと 0 件 → SourceVaultMailRebuildMetadataIndex で一括生成 (保存時は自動更新)。 *)
(* 索引行 (SummaryRow 形 + Summary) → MCP SearchResult row。search/get 共用。 *)
iSVMailRowToResult[r_Association] := Module[{rid = Lookup[r, "RecordId", Missing[]], pl = Lookup[r, "PrivacyLevel", Missing[]]},
  <|
  "URI" -> If[StringQ[rid] && rid =!= "", SourceVaultBuildURI["record", rid], Missing["NoURI"]],
  "Kind" -> "mail",
  "Title" -> Lookup[r, "Subject", Missing["NotReleased"]],
  (* 低 PL (B3 が permit) の mail のみ要約を開示。eagle と挙動を揃える。
     PL>=0.5 は B3 が結果ごと gate するので要約も漏れない (§2.4: PL<0.5 は summary 可)。 *)
  "Summary" -> Lookup[r, "Summary", Missing["NotGenerated"]],
  "Citation" -> <|"label" -> iSVDispStr[Lookup[r, "Subject", ""]],
    "from" -> iSVDispStr[Lookup[r, "From", ""]], "date" -> iSVDispStr[Lookup[r, "Date", ""]]|>,
  "Score" -> Missing["NotScored"],
  "MatchedFields" -> {"subject"},
  (* 低漏洩 metadata のみ。body / 添付 / 復号は含めない。AccessTags は index が認証済みタグを
     surface していれば scope gate に使う (暗号 record の AAD 認証タグ; 無ければ {} = untagged)。 *)
  "Metadata" -> <|"From" -> Lookup[r, "From", Missing[]], "Date" -> Lookup[r, "Date", Missing[]],
    "Category" -> Lookup[r, "Category", Missing[]], "Deadline" -> Lookup[r, "Deadline", Missing[]],
    "Priority" -> Lookup[r, "Priority", Missing[]], "Attach" -> Lookup[r, "Attach", 0],
    "MBox" -> Lookup[r, "MBox", Missing[]], "BodyEncrypted" -> Lookup[r, "BodyEncrypted", Missing[]],
    "AccessTags" -> iSVEGTagsToList[Lookup[r, "AccessTags", Lookup[r, "Tags", {}]]],
    "AccessTagsTrust" -> "Authenticated"|>,
  (* fail-closed: PL 欠落は 1.0 (B3 で cloud 宛に必ず gate) *)
  "PrivacyLevel" -> If[NumericQ[pl], pl, 1.0],
  "PrivacyClass" -> "Private",
  "ResultId" -> "mail-" <> If[StringQ[rid], rid, iSVUrlId[ToString[r]]]|>];

iSVMailAdapterSearch[spec_Association, accessRequest_Association] := Module[{q, lim, srcLim, rows},
  q = ToString @ Lookup[spec, "query", ""];
  lim = Lookup[spec, "limit", 20];
  srcLim = If[IntegerQ[lim] && lim > 0, Max[5*lim, 100], 200];
  rows = Quiet @ SourceVault`SourceVaultMailSearchIndex[q, "Limit" -> srcLim];
  If[! ListQ[rows], Return[{}]];
  iSVMailRowToResult /@ Select[rows, AssociationQ]
];

(* Phase C: 単一 URI 解決。sv://record/<recordId> を索引から引く (本文はロードしない)。 *)
iSVMailAdapterResolve[parsed_Association, accessRequest_Association] := Module[{rid, row},
  rid = ToString @ Lookup[parsed, "Id", ""];
  If[rid === "", Return[Missing["NoId"]]];
  row = Quiet @ SourceVault`SourceVaultMailIndexGet[rid];
  If[! AssociationQ[row], Return[Missing["NotFound"]]];
  iSVMailRowToResult[row]
];

(* mail URI を所有するか: sv://record/svmail-... *)
iSVMailOwnsURIQ[parsed_Association] :=
  Lookup[parsed, "Namespace", ""] === "record" &&
    StringQ[Lookup[parsed, "Id", Null]] && StringStartsQ[parsed["Id"], "svmail-"];

(* D3: 本文解放 (grant 検証は呼び出し側 iSVMCPGetBody が実施済み)。
   maildb (LoadShard/SnapshotGet/DecryptBody) は main kernel のみ → service では MainKernelOnly。
   索引行の ShardKey で該当 shard を on-demand ロードし、snapshot の暗号化 body を復号して返す。 *)
iSVMailReadBodyReadyQ[] :=
  Length[DownValues[SourceVault`SourceVaultMailLoadShard]] > 0 &&
   Length[DownValues[SourceVault`SourceVaultMailSnapshotGet]] > 0 &&
   Length[DownValues[SourceVault`SourceVaultMailSnapshotDecryptBody]] > 0;
iSVMailAdapterReadBody[parsed_Association, grant_Association, accessRequest_Association, view_:"body"] :=
  Module[{rid, row, sk, snap, dec},
    If[! iSVMailReadBodyReadyQ[], Return[Missing["MainKernelOnly"]]];
    rid = ToString @ Lookup[parsed, "Id", ""];
    If[rid === "", Return[Missing["NoId"]]];
    row = Quiet @ SourceVault`SourceVaultMailIndexGet[rid];
    If[! AssociationQ[row], Return[Missing["NotFound"]]];
    sk = Lookup[row, "ShardKey", Missing[]];
    If[StringQ[sk], Quiet @ SourceVault`SourceVaultMailLoadShard[sk]];
    snap = Quiet @ SourceVault`SourceVaultMailSnapshotGet[rid];
    If[! AssociationQ[snap], Return[Missing["NotFound"]]];
    dec = Quiet @ SourceVault`SourceVaultMailSnapshotDecryptBody[snap];
    If[AssociationQ[dec] && Lookup[dec, "Status", ""] === "Ok",
      <|"Body" -> Lookup[dec, "Body", Missing[]], "RecordId" -> rid, "View" -> "body"|>,
      Missing["DecryptFailed"]]];

(* ---- adapter 選択 ---- *)
iSVAdapterMatchesKinds[name_String, kinds_List] := If[MemberQ[kinds, "all"], True,
  Module[{aspec = SourceVaultResolveMCPDataAdapter[name]},
    AssociationQ[aspec] &&
      (IntersectingQ[Lookup[aspec, "Kinds", {}], kinds] || MemberQ[kinds, name])]];

iSVAdapterAvailableSearchable[name_String] := Module[{aspec = SourceVaultResolveMCPDataAdapter[name]},
  AssociationQ[aspec] && iSVAdapterAvailableQ[aspec] &&
    TrueQ[Lookup[Lookup[aspec, "Capabilities", <||>], "Search", False]]];

iSVRunAdapterSearch[name_String, spec_Association, accessRequest_Association] := Module[
  {aspec, fn, rows, ret},
  aspec = SourceVaultResolveMCPDataAdapter[name];
  If[! AssociationQ[aspec], Return[{}]];
  fn = Lookup[aspec, "Search", None];
  If[fn === None, Return[{}]];
  rows = Quiet @ fn[spec, accessRequest];  (* Check は使わない (message=失敗の誤判定を避ける) *)
  If[! ListQ[rows], Return[{}]];
  ret = Lookup[spec, "return", <||>];
  Function[row, SourceVaultNormalizeSearchResult[row,
    "Adapter" -> name, "ReleasedProjection" -> "summary",
    "IncludeSnippets" -> TrueQ[Lookup[ret, "includeSnippets", True]],
    "IncludeMetadata" -> TrueQ[Lookup[ret, "includeMetadata", True]],
    "MaxChars" -> Lookup[ret, "maxCharsPerResult", 800]]] /@ rows
];

(* ============================================================
   Universal MCP Access -- per-result release gate (universal spec §11 / §2.4)
   Phase B / Increment B3。service-loadable (NBAccess 非依存の baseline gate)。
   - cloud sink hard cap: ProviderClass CloudLLM/Unknown + Sink MCPResponse は Level>=0.5 を Deny
   - EffectiveAccessLevel 上限: Privacy.Level > min(AccessLevel, releaseContext.MaxPrivacyLevel, 既定0.5) は Deny
   - DenyTag: result の AccessTags が request.ScopePolicy.DenyAccessTags と交差したら Deny
   web(Public, Level 非数値)/ search(SourceVaultSearch が release context で自己 gate 済) は通過。
   NBAuthorize/SourceVaultEvaluateReleasePolicy のフル統合 (object spec/label) は将来 (grant/Phase D 以降)。
   ============================================================ *)

iSVResolveReleaseContextMax[ctxName_] := If[! StringQ[ctxName], Missing[],
  Module[{spec = Quiet @ SourceVault`SourceVaultReleaseContextSpec[ctxName]},
    If[AssociationQ[spec], Lookup[spec, "MaxPrivacyLevel", Missing[]], Missing[]]]];

iSVCloudSinkQ[accessRequest_Association] := Module[{sink, pc},
  sink = Lookup[accessRequest, "Sink", "MCPResponse"];
  pc = Lookup[Lookup[accessRequest, "Principal", <||>], "ProviderClass", "Unknown"];
  sink === "MCPResponse" && MemberQ[{"CloudLLM", "Unknown"}, pc]];

iSVEffectiveLevel[accessRequest_Association] :=
  SourceVaultEffectiveAccessLevel[{
    Lookup[accessRequest, "AccessLevel", Automatic],
    iSVResolveReleaseContextMax[Lookup[accessRequest, "ReleaseContext", None]]},
    "Default" -> 0.5];

(* ---- AccessTag scope policy (§2.6 AccessTagPolicyWrapper) ---- *)
(* Untagged の厳しさ順 (Deny > MetadataOnly > Allow) で厳しい方を採る *)
iSVScopeStricterUntagged[a_, b_] := Module[{rank = <|"Deny" -> 3, "MetadataOnly" -> 2, "Allow" -> 1|>},
  If[Lookup[rank, a, 2] >= Lookup[rank, b, 2], a, b]];
(* AllowAccessTags 合成 = 最も制限的 (intersection)。All は無制限。 *)
iSVScopeAllowCompose[a_, b_] := Which[
  a === All && b === All, All, a === All, b, b === All, a,
  ListQ[a] && ListQ[b], Intersection[a, b], ListQ[a], a, ListQ[b], b, True, All];
(* client scope と profile scope を合成 (profile が制約を追加; deny-wins, require-narrows)。 *)
iSVComposeScopePolicy[client_Association, profile_Association] := <|
  "RequireAccessTags" -> Union[Lookup[client, "RequireAccessTags", {}], Lookup[profile, "RequireAccessTags", {}]],
  "DenyAccessTags" -> Union[Lookup[client, "DenyAccessTags", {}], Lookup[profile, "DenyAccessTags", {}]],
  "AllowAccessTags" -> iSVScopeAllowCompose[Lookup[client, "AllowAccessTags", All], Lookup[profile, "AllowAccessTags", All]],
  "Untagged" -> iSVScopeStricterUntagged[Lookup[client, "Untagged", "MetadataOnly"], Lookup[profile, "Untagged", "MetadataOnly"]]|>;

(* material の AccessTags を scope policy で判定 -> {Permit|Deny, reason}。 *)
iSVScopeDecision[tags0_, scope_Association] := Module[
  {tags = If[ListQ[tags0], tags0, {}], require, deny, allow, untagged},
  require = Lookup[scope, "RequireAccessTags", {}]; If[! ListQ[require], require = {}];
  deny = Lookup[scope, "DenyAccessTags", {}]; If[! ListQ[deny], deny = {}];
  allow = Lookup[scope, "AllowAccessTags", All];
  untagged = Lookup[scope, "Untagged", "MetadataOnly"];
  Which[
    deny =!= {} && IntersectingQ[deny, tags], {"Deny", "DenyTagIntersect"},
    require =!= {} && ! SubsetQ[tags, require], {"Deny", "MissingRequiredTags"},
    tags === {} && untagged === "Deny", {"Deny", "UntaggedDenied"},
    ListQ[allow] && tags =!= {} && ! SubsetQ[allow, tags], {"Deny", "TagNotInAllow"},
    tags === {} && untagged === "MetadataOnly", {"Screen", "UntaggedMetadataOnly"},
    True, {"Permit"}]];

(* §2.6 MetadataOnly: untagged 結果を summary/snippet 抜きの metadata-only 投影に降格する。
   Title / metadata / Privacy.Level は保持し、ReleasedProjection を metadata にする。 *)
iSVDowngradeResult[r_Association] := Module[{priv = Lookup[r, "Privacy", <||>]},
  Join[r, <|
    "Summary" -> Missing["ScreenedMetadataOnly"],
    "Snippet" -> Missing["ScreenedMetadataOnly"],
    "Privacy" -> Join[If[AssociationQ[priv], priv, <||>], <|"ReleasedProjection" -> "metadata"|>]|>]];

(* search/get の request scope を解決: client scope に、登録済み (Exact/Wildcard) AccessProfile の
   ScopePolicy を合成する。Default profile は合成しない (= 既存挙動を変えない / 非破壊)。
   apOption に明示 profile (ScopePolicy or Profile を持つ assoc) を渡せば resolution を省く。 *)
iSVResolveScopeForRequest[specIn_, scopeAssoc_Association, apOption_] := Module[{client, ap, profScope},
  client = <|
    "RequireAccessTags" -> Lookup[scopeAssoc, "requireAccessTags", Lookup[scopeAssoc, "RequireAccessTags", {}]],
    "DenyAccessTags" -> Lookup[scopeAssoc, "denyAccessTags", Lookup[scopeAssoc, "DenyAccessTags", {}]],
    "AllowAccessTags" -> Lookup[scopeAssoc, "allowAccessTags", Lookup[scopeAssoc, "AllowAccessTags", All]],
    (* unscoped の既定は Allow (非破壊: profile が MetadataOnly/Deny を明示した時のみ降格/拒否)。 *)
    "Untagged" -> Lookup[scopeAssoc, "untagged", Lookup[scopeAssoc, "Untagged", "Allow"]]|>;
  profScope = Which[
    AssociationQ[apOption] && AssociationQ[Lookup[apOption, "ScopePolicy", Null]],
      Lookup[apOption, "ScopePolicy"],
    AssociationQ[apOption] && AssociationQ[Lookup[apOption, "Profile", Null]],
      Lookup[Lookup[apOption, "Profile", <||>], "ScopePolicy", <||>],
    True,
      (ap = SourceVaultResolveAccessProfile[<|
        "provider" -> Lookup[specIn, "provider", Missing[]],
        "modelId" -> Lookup[specIn, "modelId", Missing[]],
        "modelIntent" -> Lookup[specIn, "modelIntent", "default"]|>];
       If[MemberQ[{"Exact", "Wildcard"}, Lookup[ap, "Source", "Default"]],
         Lookup[Lookup[ap, "Profile", <||>], "ScopePolicy", <||>], <||>])];
  If[! AssociationQ[profScope] || profScope === <||>, client, iSVComposeScopePolicy[client, profScope]]];

SourceVaultMCPReleaseGate[result_Association, accessRequest_Association] := Module[
  {plevel, effLevel, cloudSink, scope, rTags, scopeDec},
  effLevel = iSVEffectiveLevel[accessRequest];
  cloudSink = iSVCloudSinkQ[accessRequest];
  plevel = Lookup[Lookup[result, "Privacy", <||>], "Level", Missing[]];
  scope = Lookup[accessRequest, "ScopePolicy", <||>]; If[! AssociationQ[scope], scope = <||>];
  rTags = Lookup[Lookup[result, "Metadata", <||>], "AccessTags", {}];
  scopeDec = iSVScopeDecision[rTags, scope];
  Which[
    First[scopeDec] === "Deny",
      <|"Decision" -> "Deny", "Why" -> {Last[scopeDec]}|>,
    NumericQ[plevel] && plevel > effLevel,
      <|"Decision" -> "Deny", "Why" -> {"PrivacyExceedsAccessLevel"},
        "Level" -> plevel, "EffectiveAccessLevel" -> effLevel|>,
    NumericQ[plevel] && cloudSink && plevel >= 0.5,
      <|"Decision" -> "Deny", "Why" -> {"CloudSinkHardCap"}, "Level" -> plevel|>,
    First[scopeDec] === "Screen",
      <|"Decision" -> "Screen", "Why" -> {Last[scopeDec]}, "ReleasedProjection" -> "metadata"|>,
    True,
      <|"Decision" -> "Permit", "Why" -> {}|>]];

(* ---- orchestration ---- *)
Options[SourceVaultMCPSearch] = {"Principal" -> Automatic, "Trusted" -> <||>, "AccessProfile" -> Automatic};
SourceVaultMCPSearch[specIn_Association, OptionsPattern[]] := Module[
  {spec, scope, filt, principal, composedScope, accessRequest, kinds, selected,
   normalized, gated, off, lim, limited, fmt},
  spec = SourceVaultNormalizeSearchSpec[specIn];
  scope = Lookup[spec, "scope", <||>]; filt = Lookup[spec, "filters", <||>];
  principal = OptionValue["Principal"];
  If[! AssociationQ[principal],
    principal = SourceVaultNormalizePrincipal[
      With[{p = Lookup[specIn, "principal", <||>]}, If[AssociationQ[p], p, <||>]],
      "Trusted" -> OptionValue["Trusted"]]];
  (* client scope に登録済み AccessProfile の ScopePolicy を合成 (§2.6; Default は非合成=非破壊)。
     raw scope を渡し未指定 Untagged は Allow 既定 (profile が MetadataOnly を入れた時のみ降格)。 *)
  composedScope = iSVResolveScopeForRequest[specIn, Lookup[specIn, "scope", <||>], OptionValue["AccessProfile"]];
  accessRequest = SourceVaultNormalizeAccessRequest[<|
    "Action" -> "Search", "Principal" -> principal,
    "Purpose" -> Lookup[spec, "purpose", Missing[]],
    "ReleaseContext" -> Lookup[scope, "releaseContext", None],
    "AccessLevel" -> Lookup[filt, "accessLevelMax", Automatic],
    "ScopePolicy" -> composedScope,
    "RequestedKinds" -> Lookup[spec, "kinds", {"all"}]|>];
  kinds = Lookup[spec, "kinds", {"all"}];
  selected = Select[SourceVaultListMCPDataAdapters[],
    iSVAdapterMatchesKinds[#, kinds] && iSVAdapterAvailableSearchable[#] &];
  normalized = Flatten[
    Function[aname, iSVRunAdapterSearch[aname, spec, accessRequest]] /@ selected, 1];
  (* B3: 返却直前に per-result release gate を再評価。Permit はそのまま、Screen は metadata-only へ
     降格 (§2.6 MetadataOnly: summary/snippet 抜き)、Deny は除外。 *)
  gated = DeleteCases[
    Map[Function[r, With[{g = SourceVaultMCPReleaseGate[r, accessRequest]},
      Switch[Lookup[g, "Decision"],
        "Permit", r,
        "Screen", iSVDowngradeResult[r],
        _, Nothing]]], normalized],
    Nothing];
  off = Lookup[spec, "offset", 0]; lim = Lookup[spec, "limit", 20];
  limited = Take[Drop[gated, Min[Length[gated], Max[0, off]]], UpTo[Max[0, lim]]];
  fmt = Lookup[Lookup[spec, "return", <||>], "format", "compactText"];
  <|"Results" -> limited, "Count" -> Length[limited],
    "TotalBeforeLimit" -> Length[normalized],
    "ReleaseGated" -> (Length[normalized] - Length[gated]),
    "Screened" -> Count[limited,
      _?(MatchQ[Lookup[#, "Summary", Null], Missing["ScreenedMetadataOnly"]] &)],
    "EffectiveAccessLevel" -> iSVEffectiveLevel[accessRequest],
    "Adapters" -> selected,
    "Format" -> fmt, "Rendered" -> SourceVaultRenderSearchResults[limited, fmt],
    "AccessRequest" -> accessRequest|>
];

(* ============================================================
   Universal MCP Access -- 単一 URI 解決 (universal spec §11.2 / sourcevault_get)
   Phase C / Increment C1。adapter の OwnsURIQ で所有 adapter を選び、Resolve で
   低漏洩 projection を取り、B3 (SourceVaultMCPReleaseGate) で出口 gate して返す。
   body/raw/attachment は含めず RequiresGrantFor を示す (実 grant は Phase D)。
   ============================================================ *)

iSVAdapterOwnsURIQ[name_String, parsed_Association] := Module[
  {aspec = SourceVaultResolveMCPDataAdapter[name], fn},
  If[! AssociationQ[aspec], Return[False]];
  fn = Lookup[aspec, "OwnsURIQ", None];
  TrueQ[fn =!= None && fn[parsed]]];

iSVResolveOwningAdapter[parsed_Association] :=
  SelectFirst[SourceVaultListMCPDataAdapters[],
    iSVAdapterOwnsURIQ[#, parsed] &&
      iSVAdapterAvailableQ[SourceVaultResolveMCPDataAdapter[#]] &,
    Missing["NoOwningAdapter"]];

Options[SourceVaultMCPGet] = {"Principal" -> Automatic, "Trusted" -> <||>,
  "AccessLevel" -> Automatic, "ReleaseContext" -> None, "Grant" -> None, "View" -> Automatic,
  "AccessProfile" -> Automatic};
SourceVaultMCPGet[uriIn_, OptionsPattern[]] := Module[
  {uri, parsed, canonical, principal, composedScope, accessRequest, aname, aspec, fn, row,
   normalized, gate, reqGrant, vw},
  uri = If[StringQ[uriIn], uriIn, ToString[uriIn]];
  parsed = SourceVaultParseURI[uri];
  If[! TrueQ[Lookup[parsed, "Valid", False]],
    Return[<|"URI" -> uri, "Found" -> False, "Released" -> False,
      "Why" -> {"InvalidURI"}, "Reason" -> Lookup[parsed, "Reason", Missing[]]|>]];
  canonical = With[{c = SourceVaultCanonicalURI[uri]}, If[StringQ[c], c, uri]];
  principal = OptionValue["Principal"];
  If[! AssociationQ[principal],
    principal = SourceVaultNormalizePrincipal[<||>, "Trusted" -> OptionValue["Trusted"]]];
  (* AccessProfile の ScopePolicy を enforcement (明示 profile option 時; 既定は default=非破壊) *)
  composedScope = iSVResolveScopeForRequest[<||>, <||>, OptionValue["AccessProfile"]];
  accessRequest = SourceVaultNormalizeAccessRequest[<|
    "Action" -> "Get", "Principal" -> principal,
    "AccessLevel" -> OptionValue["AccessLevel"],
    "ReleaseContext" -> OptionValue["ReleaseContext"],
    "ScopePolicy" -> composedScope,
    "RequestedKinds" -> {Lookup[parsed, "Namespace", "all"]}|>];
  aname = iSVResolveOwningAdapter[parsed];
  If[! StringQ[aname],
    Return[<|"URI" -> canonical, "Found" -> False, "Released" -> False,
      "Why" -> {"NoResolver"}, "Namespace" -> Lookup[parsed, "Namespace", Missing[]]|>]];
  aspec = SourceVaultResolveMCPDataAdapter[aname];
  fn = Lookup[aspec, "Resolve", None];
  reqGrant = Lookup[aspec, "RequireGrantFor", {}];
  If[fn === None,
    Return[<|"URI" -> canonical, "Found" -> False, "Released" -> False,
      "Adapter" -> aname, "Why" -> {"ResolveNotImplemented"}, "RequiresGrantFor" -> reqGrant|>]];
  row = Quiet @ fn[parsed, accessRequest];
  If[! AssociationQ[row],
    Return[<|"URI" -> canonical, "Found" -> False, "Released" -> False,
      "Adapter" -> aname, "Why" -> {"NotFound"}, "RequiresGrantFor" -> reqGrant|>]];
  normalized = SourceVaultNormalizeSearchResult[row,
    "Adapter" -> aname, "ReleasedProjection" -> "summary",
    "IncludeSnippets" -> True, "IncludeMetadata" -> True, "MaxChars" -> 800];
  (* D3: body/raw/context は grant 必須。grant 検証+scope+非cloud sink+PL上限を通ったら
     adapter の ReadBody で本文を解放 (mail は該当 shard を on-demand 復号; main-kernel のみ)。 *)
  vw = With[{x = OptionValue["View"]}, If[StringQ[x], ToLowerCase[x], "summary"]];
  If[MemberQ[{"body", "raw", "context"}, vw],
    Return[iSVMCPGetBody[normalized, parsed, aspec, aname, vw,
      OptionValue["Grant"], accessRequest, canonical, reqGrant]]];
  gate = SourceVaultMCPReleaseGate[normalized, accessRequest];
  If[! MemberQ[{"Permit", "Screen"}, Lookup[gate, "Decision"]],
    (* gate で落ちたら内容は返さず判定のみ *)
    Return[<|"URI" -> canonical, "Found" -> True, "Released" -> False,
      "Adapter" -> aname, "Access" -> gate, "RequiresGrantFor" -> reqGrant,
      "Why" -> Lookup[gate, "Why", {"Denied"}],
      "EffectiveAccessLevel" -> iSVEffectiveLevel[accessRequest]|>]];
  (* Screen は summary/snippet を抜いた metadata-only へ降格して返す (§2.6 MetadataOnly)。 *)
  With[{outR = If[Lookup[gate, "Decision"] === "Screen", iSVDowngradeResult[normalized], normalized]},
    <|"URI" -> canonical, "Found" -> True, "Released" -> True, "Adapter" -> aname,
      "Result" -> outR, "Access" -> gate, "RequiresGrantFor" -> reqGrant,
      "EffectiveAccessLevel" -> iSVEffectiveLevel[accessRequest], "AccessRequest" -> accessRequest|>]
];

(* ---- D3: 本文系 view (body/raw/context) の grant gate + 解放 ---- *)
(* grant が当該 URI/kind/view を許可し、かつ sink が非 cloud、PL <= grant.MaxAccessLevel なら Permit。
   本文は grant があっても cloud/Codex sink へは出さない (標準制約)。 *)
iSVGrantPermitsView[grant_Association, canonicalURI_String, kind_String, view_String,
    plevel_, accessRequest_Association] := Module[{v, fields, actions, kinds, refs, maxAL},
  v = SourceVaultMCPVerifyAccessGrant[grant];
  If[! TrueQ[Lookup[v, "Valid", False]],
    Return[<|"Permit" -> False, "Why" -> Prepend[Lookup[v, "Why", {}], "GrantInvalid"]|>]];
  fields = Lookup[v, "AllowedFields", {}]; actions = Lookup[v, "AllowedActions", {}];
  If[! (MemberQ[fields, view] || (view === "body" && MemberQ[actions, "ReadBody"])),
    Return[<|"Permit" -> False, "Why" -> {"ViewNotInGrant"}|>]];
  kinds = Lookup[v, "AllowedKinds", {}];
  If[! (MemberQ[kinds, kind] || MemberQ[kinds, "all"]),
    Return[<|"Permit" -> False, "Why" -> {"KindNotInGrant"}|>]];
  refs = Lookup[v, "AllowedObjectRefs", {}];
  If[! (refs === "All" || (ListQ[refs] && MemberQ[refs, canonicalURI])),
    Return[<|"Permit" -> False, "Why" -> {"ObjectRefNotInGrant"}|>]];
  (* 本文は cloud sink へ出さない (grant があっても hard cap) *)
  If[iSVCloudSinkQ[accessRequest],
    Return[<|"Permit" -> False, "Why" -> {"CloudSinkBlockedForBody"}|>]];
  maxAL = Lookup[v, "MaxAccessLevel", 0.5];
  If[NumericQ[plevel] && NumericQ[maxAL] && plevel > maxAL,
    Return[<|"Permit" -> False, "Why" -> {"PrivacyExceedsGrant"},
      "Level" -> plevel, "MaxAccessLevel" -> maxAL|>]];
  <|"Permit" -> True, "Why" -> {}, "GrantId" -> Lookup[v, "GrantId", Missing[]]|>];

iSVMCPGetBody[normalized_Association, parsed_Association, aspec_, aname_String, view_String,
    grant_, accessRequest_Association, canonical_String, reqGrant_] := Module[{plevel, kind, gate, fn, body},
  plevel = Lookup[Lookup[normalized, "Privacy", <||>], "Level", Missing[]];
  kind = ToString @ Lookup[normalized, "Kind", ""];
  If[! AssociationQ[grant],
    Return[<|"URI" -> canonical, "Found" -> True, "Released" -> False, "Adapter" -> aname,
      "View" -> view, "Why" -> {"GrantRequired"}, "RequiresGrantFor" -> reqGrant,
      "HowToProceed" -> "call sourcevault_request_access for this URI/view, then pass the granted AccessGrant."|>]];
  gate = iSVGrantPermitsView[grant, canonical, kind, view, plevel, accessRequest];
  If[! TrueQ[Lookup[gate, "Permit", False]],
    Return[<|"URI" -> canonical, "Found" -> True, "Released" -> False, "Adapter" -> aname,
      "View" -> view, "Access" -> <|"Decision" -> "Deny", "Why" -> Lookup[gate, "Why", {}]|>,
      "RequiresGrantFor" -> reqGrant|>]];
  fn = If[AssociationQ[aspec], Lookup[aspec, "ReadBody", None], None];
  If[fn === None,
    Return[<|"URI" -> canonical, "Found" -> True, "Released" -> False, "Adapter" -> aname,
      "View" -> view, "Why" -> {"BodyNotSupported"}, "RequiresGrantFor" -> reqGrant|>]];
  body = Quiet @ fn[parsed, grant, accessRequest, view];
  If[! AssociationQ[body],
    Return[<|"URI" -> canonical, "Found" -> True, "Released" -> False, "Adapter" -> aname,
      "View" -> view,
      "Why" -> {Which[
        MatchQ[body, Missing["MainKernelOnly"]], "BodyRequiresMainKernel",
        MatchQ[body, Missing["RawNotReleased"]], "RawNotReleased",
        True, "BodyUnavailable"]},
      "RequiresGrantFor" -> reqGrant|>]];
  Join[<|"URI" -> canonical, "Found" -> True, "Released" -> True, "Adapter" -> aname, "View" -> view,
    "Result" -> normalized,
    "Access" -> <|"Decision" -> "Permit", "Why" -> {}, "GrantId" -> Lookup[gate, "GrantId", Missing[]]|>,
    "GrantId" -> Lookup[gate, "GrantId", Missing[]]|>,
    KeyTake[body, {"Body", "Kind", "Chars"}]]];

(* ============================================================
   Phase D / Increment D1 -- AccessGrant (HMAC) + 申請/承認 poll
   (universal spec §2.3 / §11.3)
   配置前提 (2026-06-17 ユーザー決定): **MCP service と grant 承認 (NB) は同一マシン**。
   よって署名鍵・申請 queue とも machine-local の LocalState (%LOCALAPPDATA%, Dropbox 非同期)
   に置き、同一マシン内で mint→verify が完結する。
   - 署名鍵: LocalState/secrets/sourcevault-grant-signing-key.json は **machine-local の
     ローカル秘密** (web サーバのセッション署名鍵に相当)。Dropbox には出さず、既存の
     SourceVaultExportKeyBundle/ImportKeyBundle (共有データ復号用 master 鍵の移送) には
     **意図的に含めない** (grant は短命かつマシン内完結で可搬不要、非可搬の方が安全)。
     各マシンが SourceVaultMCPEnsureGrantKey[] で自分用を生成する。MCP transport token とも別。
     crypto は SourceVault_crypto.wl の公開ラッパー使用。
   - 署名対象は iSVJSONSafe → JSON round-trip → SourceVaultCanonicalJSONBytes に正規化し、
     JSON serialize/deserialize 境界 (status sidecar / tool 応答) で署名が壊れないようにする。
   - 申請 queue: LocalState/hotlog/mcp_access_requests/YYYY-MM.jsonl (append-only)、
     決定 sidecar: .../status/<requestId>.json。
   - D1 は grant の発行・検証・申請/承認フローまで。本文の実解放は D3。
   ============================================================ *)

iSVCryptoReadyQ[] := Length[DownValues[SourceVault`SourceVaultHMACSHA256Hex]] > 0 &&
  Length[DownValues[SourceVault`SourceVaultCanonicalJSONBytes]] > 0;

iSVLocalStateDir[] := With[{r = Quiet @ SourceVault`SourceVaultRoot["LocalState"]},
  If[StringQ[r], r, $Failed]];
iSVSecretsDir[] := With[{ls = iSVLocalStateDir[]}, If[StringQ[ls], FileNameJoin[{ls, "secrets"}], $Failed]];

(* ---- UTC 時刻ヘルパー (AbsoluteTime は TZ 非依存の絶対時刻) ---- *)
iSVUTCNowString[] := DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z";
iSVUTCPlusString[sec_] := DateString[TimeZoneConvert[DatePlus[Now, {sec, "Second"}], 0], "ISODateTime"] <> "Z";
iSVNowAbs[] := AbsoluteTime[TimeZoneConvert[Now, 0]];
iSVParseUTCAbs[s_] := If[! StringQ[s], $Failed,
  Quiet @ Check[AbsoluteTime[DateObject[StringTrim[s, "Z"], TimeZone -> 0]], $Failed]];
iSVUTCExpiredQ[iso_] := With[{a = iSVParseUTCAbs[iso]}, ! NumericQ[a] || a <= iSVNowAbs[]];

(* ---- JSON file I/O ---- *)
iSVReadJSONFile[path_] := If[StringQ[path] && FileExistsQ[path],
  Quiet @ Check[Import[path, "RawJSON"], $Failed], $Failed];
iSVWriteJSONFile[path_String, assoc_] := Module[{dir = DirectoryName[path]},
  If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];
  Quiet @ Check[Export[path, iSVJSONSafe[assoc], "RawJSON"]; path, $Failed]];
iSVReadJSONLFile[path_] := Module[{raw, lines},
  raw = Quiet @ Check[ByteArrayToString[ReadByteArray[path], "UTF-8"], ""];
  If[! StringQ[raw], Return[{}]];
  lines = Select[StringSplit[raw, "\n"], StringTrim[#] =!= "" &];
  Select[Quiet @ Check[ImportString[StringTrim[#], "RawJSON"], Nothing] & /@ lines, AssociationQ]];
iSVAppendJSONL[path_String, assoc_] := Module[{dir = DirectoryName[path], line},
  If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];
  line = Quiet @ Check[ExportString[iSVJSONSafe[assoc], "RawJSON", "Compact" -> True], $Failed];
  If[! StringQ[line], Return[$Failed]];
  (* UTF-8 bytes で binary 追記。WriteString[OpenAppend] は Windows 既定 encoding で
     非 ASCII (日本語) を文字化けさせ ImportString が parse 失敗するため使わない。
     iSVReadJSONLFile は ByteArrayToString[.., "UTF-8"] で読むので往復する。 *)
  Quiet @ Check[With[{strm = OpenAppend[path, BinaryFormat -> True]},
    BinaryWrite[strm, StringToByteArray[line <> "\n", "UTF-8"]]; Close[strm]; path], $Failed]];

(* ---- 署名鍵 ---- *)
iSVGrantKeyFile[] := With[{d = iSVSecretsDir[]},
  If[StringQ[d], FileNameJoin[{d, "sourcevault-grant-signing-key.json"}], $Failed]];
SourceVaultMCPEnsureGrantKey[] := Module[{path, cur},
  path = iSVGrantKeyFile[];
  If[! StringQ[path], Return[Failure["LocalStateUnresolved", <|"Key" -> "LocalState"|>]]];
  cur = iSVReadJSONFile[path];
  If[AssociationQ[cur] && StringQ[Lookup[cur, "Key", Null]],
    Return[<|"KeyId" -> Lookup[cur, "KeyId", "grant-hmac-v1"], "Created" -> False, "Path" -> path|>]];
  iSVWriteJSONFile[path, <|"KeyId" -> "grant-hmac-v1",
    "Key" -> BaseEncode[ByteArray[RandomInteger[{0, 255}, 32]]],
    "Algorithm" -> "HMAC-SHA256", "CreatedAtUTC" -> iSVUTCNowString[]|>];
  <|"KeyId" -> "grant-hmac-v1", "Created" -> True, "Path" -> path|>];
iSVGrantKeyRecord[] := iSVReadJSONFile[iSVGrantKeyFile[]];
iSVGrantKeyBytes[] := Module[{rec = iSVGrantKeyRecord[], b},
  If[! AssociationQ[rec], Return[Missing["NoKey"]]];
  b = Lookup[rec, "Key", Missing[]];
  If[! StringQ[b], Return[Missing["NoKey"]]];
  With[{d = Quiet@Check[BaseDecode[b], $Failed]}, If[Head[d] === ByteArray, d, Missing["BadKey"]]]];
iSVGrantKeyId[] := With[{rec = iSVGrantKeyRecord[]},
  If[AssociationQ[rec], Lookup[rec, "KeyId", "grant-hmac-v1"], "grant-hmac-v1"]];

(* ---- revocation epoch (revoke-all) ---- *)
iSVRevEpochFile[] := With[{d = iSVSecretsDir[]},
  If[StringQ[d], FileNameJoin[{d, "sourcevault-grant-revocation-epoch.json"}], $Failed]];
iSVCurrentRevEpoch[] := With[{rec = iSVReadJSONFile[iSVRevEpochFile[]]},
  If[AssociationQ[rec] && IntegerQ[Lookup[rec, "Epoch", Null]], rec["Epoch"], 0]];
SourceVaultMCPRevokeAllGrants[] := Module[{path = iSVRevEpochFile[], e},
  If[! StringQ[path], Return[Failure["LocalStateUnresolved", <||>]]];
  e = iSVCurrentRevEpoch[] + 1;
  iSVWriteJSONFile[path, <|"Epoch" -> e, "BumpedAtUTC" -> iSVUTCNowString[]|>];
  <|"Status" -> "Revoked", "Epoch" -> e|>];

(* ---- grant 署名: JSON 境界で安定するよう round-trip 後に canonical 化 ---- *)
iSVStableBytes[g_] := Module[{rt},
  rt = Quiet @ Check[ImportString[ExportString[iSVJSONSafe[g], "RawJSON"], "RawJSON"], iSVJSONSafe[g]];
  SourceVault`SourceVaultCanonicalJSONBytes[rt]];
iSVGrantDigest[g_] := Hash[iSVStableBytes[KeyDrop[g, {"Digest", "Signature"}]], "SHA256", "HexString"];
iSVGrantSignature[g_, keyBytes_ByteArray] :=
  SourceVault`SourceVaultHMACSHA256Hex[keyBytes, iSVStableBytes[KeyDrop[g, {"Signature"}]]];
iSVGrantExpiredQ[g_] := iSVUTCExpiredQ[Lookup[g, "ExpiresAtUTC", ""]];

SourceVaultMCPMintAccessGrant[spec_Association] := Module[{keyBytes, g, ttl},
  If[! iSVCryptoReadyQ[], Return[Failure["CryptoUnavailable", <||>]]];
  keyBytes = iSVGrantKeyBytes[];
  If[Head[keyBytes] =!= ByteArray,
    Return[Failure["GrantKeyUnavailable", <|"Hint" -> "SourceVaultMCPEnsureGrantKey[] を先に実行"|>]]];
  (* 既定 900s。負値も許す (即期限切れ grant は DOA で害がなく、期限ロジックの検証に使える) *)
  ttl = With[{t = Lookup[spec, "TTLSeconds", 900]}, If[IntegerQ[t], t, 900]];
  g = <|
    "GrantId" -> "grant-" <> StringReplace[CreateUUID[], "-" -> ""],
    "IssuedBy" -> ToString @ Lookup[spec, "IssuedBy", "NBAccess"],
    "Principal" -> Lookup[spec, "Principal", <||>],
    "AllowedActions" -> Lookup[spec, "AllowedActions", {}],
    "AllowedKinds" -> Lookup[spec, "AllowedKinds", {}],
    "AllowedObjectRefs" -> Lookup[spec, "AllowedObjectRefs", {}],
    "MaxAccessLevel" -> N @ With[{m = Lookup[spec, "MaxAccessLevel", 0.5]}, If[NumericQ[m], m, 0.5]],
    "AllowedFields" -> Lookup[spec, "AllowedFields", {}],
    "Purpose" -> ToString @ Lookup[spec, "Purpose", ""],
    "Sink" -> ToString @ Lookup[spec, "Sink", "LocalOnly"],
    "ExpiresAtUTC" -> iSVUTCPlusString[ttl],
    "RevocationEpoch" -> iSVCurrentRevEpoch[],
    "KeyId" -> iSVGrantKeyId[]|>;
  (* MaxPrivacyLevel は数値指定時のみ含める (Missing を JSON に残さない) *)
  If[NumericQ[Lookup[spec, "MaxPrivacyLevel", Null]],
    g = Append[g, "MaxPrivacyLevel" -> N[spec["MaxPrivacyLevel"]]]];
  (* grant 本体を JSON-native 化 (Principal 等の Missing→Null)。返す grant をそのまま
     serialize でき、署名も保存/復元境界と一致する (iSVStableBytes も round-trip するので冪等)。 *)
  g = iSVJSONSafe[g];
  g = Append[g, "Digest" -> iSVGrantDigest[g]];
  g = Append[g, "Signature" -> iSVGrantSignature[g, keyBytes]];
  g];

SourceVaultMCPVerifyAccessGrant[grant_Association] := Module[{keyBytes, e},
  If[! iSVCryptoReadyQ[], Return[<|"Valid" -> False, "Why" -> {"CryptoUnavailable"}|>]];
  keyBytes = iSVGrantKeyBytes[];
  If[Head[keyBytes] =!= ByteArray, Return[<|"Valid" -> False, "Why" -> {"KeyUnavailable"}|>]];
  If[ToString@Lookup[grant, "KeyId", ""] =!= iSVGrantKeyId[],
    Return[<|"Valid" -> False, "Why" -> {"KeyIdMismatch"}|>]];
  If[! SourceVault`SourceVaultConstantTimeEqualQ[ToString@Lookup[grant, "Digest", ""], iSVGrantDigest[grant]],
    Return[<|"Valid" -> False, "Why" -> {"DigestMismatch"}|>]];
  If[! SourceVault`SourceVaultConstantTimeEqualQ[ToString@Lookup[grant, "Signature", ""],
       iSVGrantSignature[grant, keyBytes]],
    Return[<|"Valid" -> False, "Why" -> {"SignatureMismatch"}|>]];
  If[iSVGrantExpiredQ[grant],
    Return[<|"Valid" -> False, "Why" -> {"Expired"}, "ExpiresAtUTC" -> Lookup[grant, "ExpiresAtUTC", Missing[]]|>]];
  e = Lookup[grant, "RevocationEpoch", 0];
  If[! IntegerQ[e] || e < iSVCurrentRevEpoch[], Return[<|"Valid" -> False, "Why" -> {"Revoked"}|>]];
  <|"Valid" -> True, "Why" -> {}, "GrantId" -> Lookup[grant, "GrantId", Missing[]],
    "Principal" -> Lookup[grant, "Principal", <||>],
    "AllowedActions" -> Lookup[grant, "AllowedActions", {}],
    "AllowedKinds" -> Lookup[grant, "AllowedKinds", {}],
    "AllowedObjectRefs" -> Lookup[grant, "AllowedObjectRefs", {}],
    "AllowedFields" -> Lookup[grant, "AllowedFields", {}],
    "MaxAccessLevel" -> Lookup[grant, "MaxAccessLevel", Missing[]],
    "Sink" -> Lookup[grant, "Sink", Missing[]],
    "ExpiresAtUTC" -> Lookup[grant, "ExpiresAtUTC", Missing[]]|>];
SourceVaultMCPVerifyAccessGrant[_] := <|"Valid" -> False, "Why" -> {"NotAssociation"}|>;

(* ---- 申請 queue / status sidecar ---- *)
iSVAccessReqDir[] := With[{ls = iSVLocalStateDir[]},
  If[StringQ[ls], FileNameJoin[{ls, "hotlog", "mcp_access_requests"}], $Failed]];
iSVAccessReqMonthFile[] := With[{d = iSVAccessReqDir[]},
  If[StringQ[d], FileNameJoin[{d, DateString[TimeZoneConvert[Now, 0], {"Year", "-", "Month"}] <> ".jsonl"}], $Failed]];
iSVAccessStatusFile[reqId_String] := With[{d = iSVAccessReqDir[]},
  If[StringQ[d], FileNameJoin[{d, "status", reqId <> ".json"}], $Failed]];
iSVReadAllRequests[] := Module[{dir = iSVAccessReqDir[]},
  If[! StringQ[dir] || ! DirectoryQ[dir], Return[{}]];
  Join @@ (iSVReadJSONLFile /@ FileNames["*.jsonl", dir, 1])];
iSVFindRequest[reqId_String] :=
  SelectFirst[iSVReadAllRequests[], Lookup[#, "RequestId", ""] === reqId &, Missing["NotFound"]];
iSVReadStatus[reqId_String] := iSVReadJSONFile[iSVAccessStatusFile[reqId]];
iSVReqExpiredQ[req_] := iSVUTCExpiredQ[Lookup[req, "ExpiresAtUTC", ""]];

SourceVaultMCPRequestAccess[spec_Association] := Module[{reqId, ttl, rec, path},
  reqId = "req-" <> StringReplace[CreateUUID[], "-" -> ""];
  ttl = With[{t = Lookup[spec, "TTLSeconds", 3600]}, If[IntegerQ[t] && t > 0, t, 3600]];
  rec = <|
    "RequestId" -> reqId, "Type" -> "MCPAccessRequest",
    "RequestedAtUTC" -> iSVUTCNowString[], "ExpiresAtUTC" -> iSVUTCPlusString[ttl],
    "Principal" -> Lookup[spec, "Principal", <||>],
    "Action" -> ToString @ Lookup[spec, "Action", "ReadBody"],
    "ObjectRefs" -> Lookup[spec, "ObjectRefs", {}],
    "Kinds" -> Lookup[spec, "Kinds", {}],
    "Fields" -> Lookup[spec, "Fields", {}],
    "Purpose" -> ToString @ Lookup[spec, "Purpose", ""],
    "Sink" -> ToString @ Lookup[spec, "Sink", "LocalOnly"],
    "RequestedAccessLevel" -> With[{r = Lookup[spec, "RequestedAccessLevel", Missing[]]},
      If[NumericQ[r], N[r], Missing["NotSpecified"]]],
    "ReleaseContext" -> With[{c = Lookup[spec, "ReleaseContext", None]}, If[StringQ[c], c, Null]],
    "Status" -> "Pending"|>;
  path = iSVAccessReqMonthFile[];
  If[! StringQ[path], Return[Failure["LocalStateUnresolved", <||>]]];
  If[iSVAppendJSONL[path, rec] === $Failed, Return[Failure["QueueWriteFailed", <||>]]];
  <|"RequestId" -> reqId, "Status" -> "Pending", "ExpiresAtUTC" -> rec["ExpiresAtUTC"],
    "HowToProceed" -> "poll sourcevault_access_status with this RequestId; a human approves in Mathematica."|>];

SourceVaultMCPAccessStatus[requestId_String] := Module[{st, req, grant},
  st = iSVReadStatus[requestId];
  If[AssociationQ[st],
    Which[
      Lookup[st, "Status", ""] === "Granted",
        grant = Lookup[st, "Grant", Missing[]];
        If[AssociationQ[grant] && iSVGrantExpiredQ[grant],
          <|"Status" -> "Expired", "RequestId" -> requestId|>,
          <|"Status" -> "Granted", "RequestId" -> requestId, "Grant" -> grant|>],
      Lookup[st, "Status", ""] === "Denied",
        <|"Status" -> "Denied", "RequestId" -> requestId, "Reason" -> Lookup[st, "Reason", ""]|>,
      True, <|"Status" -> ToString@Lookup[st, "Status", "Unknown"], "RequestId" -> requestId|>],
    (* 未決 *)
    req = iSVFindRequest[requestId];
    If[! AssociationQ[req], Return[<|"Status" -> "NotFound", "RequestId" -> requestId|>]];
    If[iSVReqExpiredQ[req],
      <|"Status" -> "Expired", "RequestId" -> requestId|>,
      <|"Status" -> "Pending", "RequestId" -> requestId|>]]];

(* ---- main kernel helpers (承認 UI) ---- *)
Options[SourceVaultMCPPendingAccessRequests] = {"IncludeExpired" -> False};
SourceVaultMCPPendingAccessRequests[OptionsPattern[]] := Module[{all, inclExp},
  inclExp = TrueQ[OptionValue["IncludeExpired"]];
  all = iSVReadAllRequests[];
  Select[all, (! AssociationQ[iSVReadStatus[Lookup[#, "RequestId", ""]]]) &&
    (inclExp || ! iSVReqExpiredQ[#]) &]];

(* #4 承認時ポリシーゲート: 要求 objectRef のうち revoke 済みのものを返す (best-effort)。
   objectId は URI の Id segment (mail=svmail-.., eagle=eagle-..)。revocation API 未ロード or
   "All"/非リストなら検査せず {} (= fail-open; 一致した revoked のみ拒否するので誤拒否しない)。 *)
iSVApprovalRevokedRefs[refs_] :=
  If[refs === "All" || ! ListQ[refs] ||
     Length[DownValues[SourceVault`SourceVaultObjectRevocationStatus]] == 0, {},
   Select[refs, Function[uri,
     Module[{p, oid, st},
       p = SourceVaultParseURI[ToString[uri]];
       oid = If[AssociationQ[p], ToString @ Lookup[p, "Id", ""], ""];
       If[oid === "", False,
         st = Quiet @ SourceVault`SourceVaultObjectRevocationStatus[oid];
         AssociationQ[st] && TrueQ[Lookup[st, "Revoked", False]]]]]]];

Options[SourceVaultMCPApproveAccessRequest] = {"MaxAccessLevel" -> Automatic,
  "AllowedActions" -> Automatic, "AllowedKinds" -> Automatic, "AllowedObjectRefs" -> Automatic,
  "AllowedFields" -> Automatic, "Sink" -> Automatic, "TTLSeconds" -> 900,
  "ReleaseContext" -> Automatic};
SourceVaultMCPApproveAccessRequest[requestId_String, OptionsPattern[]] := Module[
  {req, gspec, grant, sf, refs, revoked, rc, ctxMax, revChecked, requested},
  req = iSVFindRequest[requestId];
  If[! AssociationQ[req], Return[Failure["RequestNotFound", <|"RequestId" -> requestId|>]]];
  (* 申請値を既定に、opts で厳しく上書き (緩める想定はしない)。human 承認 + policy gate の二段。 *)
  requested = With[{o = OptionValue["MaxAccessLevel"]},
    If[NumericQ[o], o, With[{r = Lookup[req, "RequestedAccessLevel", Missing[]]}, If[NumericQ[r], r, 0.5]]]];
  gspec = <|
    "Principal" -> Lookup[req, "Principal", <||>],
    "AllowedActions" -> With[{o = OptionValue["AllowedActions"]},
      If[o === Automatic, {Lookup[req, "Action", "ReadBody"]}, o]],
    "AllowedKinds" -> With[{o = OptionValue["AllowedKinds"]}, If[o === Automatic, Lookup[req, "Kinds", {}], o]],
    "AllowedObjectRefs" -> With[{o = OptionValue["AllowedObjectRefs"]},
      If[o === Automatic, Lookup[req, "ObjectRefs", {}], o]],
    "AllowedFields" -> With[{o = OptionValue["AllowedFields"]}, If[o === Automatic, Lookup[req, "Fields", {}], o]],
    "MaxAccessLevel" -> requested,
    "Sink" -> With[{o = OptionValue["Sink"]}, If[o === Automatic, Lookup[req, "Sink", "LocalOnly"], o]],
    "Purpose" -> Lookup[req, "Purpose", ""], "TTLSeconds" -> OptionValue["TTLSeconds"]|>;
  sf = iSVAccessStatusFile[requestId];
  If[! StringQ[sf], Return[Failure["LocalStateUnresolved", <||>]]];
  refs = Lookup[gspec, "AllowedObjectRefs", {}];
  revChecked = Length[DownValues[SourceVault`SourceVaultObjectRevocationStatus]] > 0;
  (* (a) revoke 済み objectRef は承認拒否 *)
  revoked = iSVApprovalRevokedRefs[refs];
  If[revoked =!= {},
    iSVWriteJSONFile[sf, <|"RequestId" -> requestId, "Status" -> "Denied",
      "DecidedAtUTC" -> iSVUTCNowString[], "Reason" -> "RevokedObjectRefs",
      "PolicyGate" -> <|"RevocationChecked" -> True, "RevokedRefs" -> revoked|>|>];
    Return[Failure["RevokedObjectRefs", <|"RequestId" -> requestId, "RevokedRefs" -> revoked|>]]];
  (* (b) ReleaseContext 指定時は grant の MaxAccessLevel を context の MaxPrivacyLevel で cap *)
  rc = With[{o = OptionValue["ReleaseContext"]},
    If[StringQ[o], o, With[{r = Lookup[req, "ReleaseContext", None]}, If[StringQ[r], r, None]]]];
  ctxMax = iSVResolveReleaseContextMax[rc];
  If[NumericQ[ctxMax],
    gspec = Append[gspec, "MaxAccessLevel" -> Min[requested, ctxMax]]];
  grant = SourceVaultMCPMintAccessGrant[gspec];
  If[! AssociationQ[grant], Return[grant]];
  iSVWriteJSONFile[sf, <|"RequestId" -> requestId, "Status" -> "Granted",
    "DecidedAtUTC" -> iSVUTCNowString[], "Grant" -> grant,
    "PolicyGate" -> <|"RevocationChecked" -> revChecked, "RevokedRefs" -> {},
      "ReleaseContext" -> If[StringQ[rc], rc, Null],
      "AppliedLevelCap" -> If[NumericQ[ctxMax], ctxMax, Null]|>|>];
  grant];

SourceVaultMCPDenyAccessRequest[requestId_String, reason_String : ""] := Module[{sf},
  sf = iSVAccessStatusFile[requestId];
  If[! StringQ[sf], Return[Failure["LocalStateUnresolved", <||>]]];
  iSVWriteJSONFile[sf, <|"RequestId" -> requestId, "Status" -> "Denied",
    "DecidedAtUTC" -> iSVUTCNowString[], "Reason" -> reason|>];
  <|"Status" -> "Denied", "RequestId" -> requestId|>];

(* ============================================================
   Phase F / §12 -- ClaudeOrchestrator feedback bridge (MVP = 記録のみ)
   feedback event を LocalState/hotlog/mcp_feedback/YYYY-MM.jsonl へ append-only。
   service kernel が単一書き手 (tool dispatch は service 内で走る)。
   Orchestrator 側の queue/accept/reject/subtask 昇格は将来 (本実装に含めない)。
   ============================================================ *)

$svFeedbackKinds = {"HelpRequest", "SubtaskProposal", "AccessRequest",
  "Critique", "Correction", "SessionNote"};

iSVFeedbackDir[] := With[{ls = iSVLocalStateDir[]},
  If[StringQ[ls], FileNameJoin[{ls, "hotlog", "mcp_feedback"}], $Failed]];
iSVFeedbackMonthFile[] := With[{d = iSVFeedbackDir[]},
  If[StringQ[d], FileNameJoin[{d, DateString[TimeZoneConvert[Now, 0], {"Year", "-", "Month"}] <> ".jsonl"}], $Failed]];
iSVFeedbackFiles[] := With[{dir = iSVFeedbackDir[]},
  If[! StringQ[dir] || ! DirectoryQ[dir], {}, FileNames["*.jsonl", dir, 1]]];

SourceVaultMCPSubmitFeedback[spec_Association] := Module[
  {kind, eid, self, sid, bid, sessMax, batchMax, effPL, payloadIn, payload, env, path},
  kind = ToString @ Lookup[spec, "Kind", "SessionNote"];
  If[! MemberQ[$svFeedbackKinds, kind],
    Return[Failure["InvalidFeedbackKind", <|"Kind" -> kind, "Allowed" -> $svFeedbackKinds|>]]];
  eid = "fb-" <> StringReplace[CreateUUID[], "-" -> ""];
  self = With[{p = Lookup[spec, "PrivacyLevel", 0.5]}, If[NumericQ[p], N[p], 0.5]];
  sid = ToString @ Lookup[spec, "SessionId",
    Lookup[Lookup[spec, "Target", <||>], "SessionId", "Unknown"]];
  bid = Lookup[spec, "BatchId", Missing[]];
  (* §12.3: Payload.Text は LLM 出力。自己申告だけに依存せず、同一 session / batch の observed-read max
     (Inc6 hotlog) を継承して privacy を引き上げる。best-effort (hotlog 無 -> 0)。 *)
  sessMax = Quiet @ SourceVaultObservedReadMax[
    SourceVaultMCPCallsRecent["SessionId" -> sid], "Default" -> 0.0];
  batchMax = If[StringQ[bid],
    Quiet @ SourceVaultObservedReadMax[
      SourceVaultMCPCallsRecent["BatchId" -> bid], "Default" -> 0.0], 0.0];
  If[! NumericQ[sessMax], sessMax = 0.0]; If[! NumericQ[batchMax], batchMax = 0.0];
  effPL = Max[self, sessMax, batchMax];
  payloadIn = With[{p = Lookup[spec, "Payload", <||>]}, If[AssociationQ[p], p, <||>]];
  payload = <|
    "Text" -> ToString @ Lookup[payloadIn, "Text", Lookup[spec, "Text", ""]],
    "Goal" -> Lookup[payloadIn, "Goal", Lookup[spec, "Goal", Missing["NotSpecified"]]],
    "SuggestedRole" -> Lookup[payloadIn, "SuggestedRole", Lookup[spec, "SuggestedRole", Missing["NotSpecified"]]],
    "SuggestedCapabilities" -> Lookup[payloadIn, "SuggestedCapabilities", Lookup[spec, "SuggestedCapabilities", {}]],
    "RequestedData" -> Lookup[payloadIn, "RequestedData", Lookup[spec, "RequestedData", {}]],
    "EvidenceRefs" -> Lookup[payloadIn, "EvidenceRefs", Lookup[spec, "EvidenceRefs", {}]]|>;
  env = <|
    "EventId" -> eid, "Type" -> "MCPFeedbackEvent", "Kind" -> kind,
    "From" -> Lookup[spec, "Principal", <||>],
    "Target" -> <|"System" -> "ClaudeOrchestrator", "SessionId" -> sid|>,
    "BatchId" -> bid,
    "Payload" -> payload, "PrivacyLevel" -> effPL,
    "PrivacyBasis" -> <|"SelfReported" -> self,
      "SessionObservedReadMax" -> sessMax, "BatchObservedReadMax" -> batchMax,
      "Policy" -> "MaxObservedInput"|>,
    (* feedback は cloud/remote participant へ再送され得るため、>=0.5 は送信前 review を要求 (§12.3)。 *)
    "RequireReview" -> (effPL >= 0.5),
    "CreatedAtUTC" -> iSVUTCNowString[],
    "RequireApproval" -> TrueQ[Lookup[spec, "RequireApproval", False]],
    "Status" -> "Queued"|>;
  path = iSVFeedbackMonthFile[];
  If[! StringQ[path], Return[Failure["LocalStateUnresolved", <||>]]];
  If[iSVAppendJSONL[path, env] === $Failed, Return[Failure["FeedbackWriteFailed", <||>]]];
  <|"EventId" -> eid, "Status" -> "Queued", "Kind" -> kind,
    "PrivacyLevel" -> effPL, "RequireReview" -> (effPL >= 0.5)|>];

Options[SourceVaultMCPFeedbackQueue] = {"Kind" -> All, "Status" -> All, "Limit" -> Automatic};
SourceVaultMCPFeedbackQueue[OptionsPattern[]] := Module[{all, kind, status, lim},
  all = Join @@ (iSVReadJSONLFile /@ iSVFeedbackFiles[]);
  kind = OptionValue["Kind"]; status = OptionValue["Status"]; lim = OptionValue["Limit"];
  If[StringQ[kind], all = Select[all, Lookup[#, "Kind", ""] === kind &]];
  If[StringQ[status], all = Select[all, Lookup[#, "Status", ""] === status &]];
  all = SortBy[all, Lookup[#, "CreatedAtUTC", ""] &];
  If[IntegerQ[lim] && lim >= 0, all = Take[all, -Min[Length[all], lim]]];
  all];

(* ============================================================
   Universal MCP Access -- artifact deposit (universal spec §10.7 / §10.7.2 / §11.5)
   b Part A / deposit。mode "plan" は §10.7.2 の privacy/tag 継承を計算し書き込まない。
   PrivacyLevel = Max[要求, Session/Batch observed-read max]、自己申告 SourceRefs が observed read で
   裏付けられない場合は fail-closed 0.75 floor。mode "commit" (実書込) は後続 increment。
   ============================================================ *)

(* inputRefs/citationRefs/promptRefs を canonical sv:// URI 集合に正規化する。 *)
iSVDepositCanonRefs[refs_] := If[! ListQ[refs], {},
  DeleteCases[
    Map[Function[u,
      If[StringQ[u],
        With[{c = Quiet @ SourceVaultCanonicalURI[u]}, If[StringQ[c], c, u]],
        Nothing]], refs],
    Nothing]];

(* ---- deposit commit のストレージ / quota / content (§11.5) ---- *)
$svDepositMaxBytes = 5*1024*1024;              (* 単一 deposit payload 上限 5MB *)
$svDepositMaxItemsPerSession = 200;            (* per-session / per-batch 件数上限 *)
$svDepositMaxBytesPerSession = 50*1024*1024;   (* per-session / per-batch 総バイト上限 *)

iSVDepositsDir[] := With[{ls = iSVLocalStateDir[]},
  If[StringQ[ls], FileNameJoin[{ls, "hotlog", "mcp_deposits"}], $Failed]];
iSVDepositsMonthFile[] := With[{d = iSVDepositsDir[]},
  If[StringQ[d],
    FileNameJoin[{d, DateString[TimeZoneConvert[Now, 0], {"Year", "-", "Month"}] <> ".jsonl"}], $Failed]];
iSVDepositsFiles[] := With[{dir = iSVDepositsDir[]},
  If[! StringQ[dir] || ! DirectoryQ[dir], {}, FileNames["*.jsonl", dir, 1]]];
iSVDepositIdempotencyFile[] := With[{d = iSVDepositsDir[]},
  If[StringQ[d], FileNameJoin[{d, "idempotency.json"}], $Failed]];

(* per-session / per-batch の deposit 使用量 (件数・バイト)。shared principal 下では session/batch が主キー。 *)
iSVDepositUsage[sid_, bid_] := Module[{recs},
  recs = Select[Join @@ (iSVReadJSONLFile /@ iSVDepositsFiles[]),
    AssociationQ[#] && (Lookup[#, "SessionId", ""] === sid ||
      (StringQ[bid] && Lookup[#, "BatchId", ""] === bid)) &];
  <|"Items" -> Length[recs],
    "Bytes" -> Total[Cases[Lookup[#, "Bytes", 0] & /@ recs, _?NumericQ]]|>];

(* content -> <|Bytes(ByteArray), Text(artifact 用), Binary|>。utf-8 は text 本体、base64 は decode。 *)
iSVDepositContentBytes[content_Association, title_] := Module[{enc, text, bytes},
  enc = ToLowerCase[ToString[Lookup[content, "encoding", "utf-8"]]];
  Which[
    enc === "base64",
      bytes = Quiet @ Check[
        BaseDecode[ToString @ Lookup[content, "data", Lookup[content, "text", ""]]], $Failed];
      If[Head[bytes] =!= ByteArray, Return[$Failed]];
      <|"Bytes" -> bytes,
        "Text" -> If[StringQ[title] && title =!= "", title, "[binary deposit]"], "Binary" -> True|>,
    True,
      text = ToString @ Lookup[content, "text", ""];
      <|"Bytes" -> StringToByteArray[text, "UTF-8"], "Text" -> text, "Binary" -> False|>]];

(* deposit の request-gate (§11.5 / §15.3): commit に DepositArtifact 権限があるか判定する。
   (1) spec["Grant"] が HMAC 有効かつ AllowedActions に DepositArtifact を含む、または
   (2) endpoint AccessProfile の AllowedOperations に DepositArtifact を含む。
   既定 profile の AllowedOperations は {Search, ReadSummary, ReadContext} で DepositArtifact を
   含まない → 既定 fail-closed (RequireGrant)。
   MaxAccessLevel は privacy approval gate の ceiling 判定に流用する。 *)
iSVDepositAuthorized[spec_Association] := Module[
  {grant, gv, prov, ab, modelId, provider, prof, ops, profMax},
  grant = Lookup[spec, "Grant", None];
  If[AssociationQ[grant],
    gv = SourceVaultMCPVerifyAccessGrant[grant];
    If[TrueQ[Lookup[gv, "Valid", False]] &&
       MemberQ[Lookup[gv, "AllowedActions", {}], "DepositArtifact"],
      Return[<|"Authorized" -> True, "Via" -> "Grant",
        "GrantId" -> Lookup[gv, "GrantId", Missing[]],
        "MaxAccessLevel" -> With[{m = Lookup[gv, "MaxAccessLevel", 0.0]}, If[NumericQ[m], N[m], 0.0]]|>,
      Module]]];
  prov = With[{p = Lookup[spec, "provenance", <||>]}, If[AssociationQ[p], p, <||>]];
  ab = With[{a = Lookup[prov, "authoredBy", <||>]}, If[AssociationQ[a], a, <||>]];
  modelId = ToString @ Lookup[ab, "modelId", Lookup[spec, "ModelId", "unknown"]];
  provider = ToString @ Lookup[ab, "provider",
    Lookup[With[{pr = Lookup[spec, "Principal", <||>]}, If[AssociationQ[pr], pr, <||>]],
      "Provider", "unknown"]];
  prof = Quiet @ SourceVaultResolveAccessProfile[
    <|"Provider" -> provider, "ModelId" -> modelId, "ModelIntent" -> "deposit"|>];
  ops = If[AssociationQ[prof],
    With[{o = Lookup[Lookup[prof, "Profile", <||>], "AllowedOperations", {}]},
      If[ListQ[o], o, {}]], {}];
  If[MemberQ[ops, "DepositArtifact"],
    profMax = With[{m = Lookup[Lookup[prof, "Profile", <||>], "MaxAccessLevel", 0.0]},
      If[NumericQ[m], N[m], 0.0]];
    Return[<|"Authorized" -> True, "Via" -> "Profile",
      "ProfileRef" -> Lookup[prof, "AccessProfileRef", Missing[]],
      "MaxAccessLevel" -> profMax|>, Module]];
  <|"Authorized" -> False, "Via" -> None, "MaxAccessLevel" -> 0.0|>];

SourceVaultMCPDeposit[spec_Association] := Module[
  {mode, prov, policyIn, inputRefs, citationRefs, promptRefs, sourceRefs, roles,
   sid, bid, sessMax, batchMax, observedMax, reqPL, base, unevaluated, effPL,
   tags, denyTags, cloudOK, requiresApproval, warnings},
  mode = ToLowerCase[ToString[Lookup[spec, "mode", "plan"]]];
  prov = With[{p = Lookup[spec, "provenance", <||>]}, If[AssociationQ[p], p, <||>]];
  policyIn = With[{p = Lookup[spec, "policy", <||>]}, If[AssociationQ[p], p, <||>]];

  (* MCP 入力 refs を canonical SourceRefs + SourceRefRoles に正規化 (§10.7.2)。 *)
  inputRefs = iSVDepositCanonRefs[Lookup[prov, "inputRefs", {}]];
  citationRefs = iSVDepositCanonRefs[Lookup[prov, "citationRefs", {}]];
  promptRefs = iSVDepositCanonRefs[Lookup[prov, "promptRefs", {}]];
  sourceRefs = DeleteDuplicates[Join[inputRefs, citationRefs, promptRefs]];
  roles = <|"Input" -> inputRefs, "Citation" -> citationRefs, "Prompt" -> promptRefs|>;

  (* 同一 Session / Batch の observed-read max (Inc6 hotlog) *)
  sid = ToString @ Lookup[spec, "SessionId", Lookup[spec, "sessionId", "Unknown"]];
  bid = Lookup[spec, "BatchId", Lookup[spec, "batchId", Missing[]]];
  sessMax = Quiet @ SourceVaultObservedReadMax[
    SourceVaultMCPCallsRecent["SessionId" -> sid], "Default" -> 0.0];
  batchMax = If[StringQ[bid],
    Quiet @ SourceVaultObservedReadMax[
      SourceVaultMCPCallsRecent["BatchId" -> bid], "Default" -> 0.0], 0.0];
  If[! NumericQ[sessMax], sessMax = 0.0]; If[! NumericQ[batchMax], batchMax = 0.0];
  observedMax = Max[sessMax, batchMax];

  (* §10.7.2: 要求 privacy は下限。observed-read max を継承して Max 合成。 *)
  reqPL = With[{p = Lookup[policyIn, "privacyLevel", Lookup[spec, "PrivacyLevel", Missing[]]]},
    If[NumericQ[p], N[p], Missing[]]];
  base = Max[Join[Cases[{reqPL, sessMax, batchMax}, _?NumericQ], {0.0}]];
  (* 自己申告 SourceRefs があるが observed read で裏付けが無い = service で評価不能 → fail-closed 0.75。 *)
  unevaluated = sourceRefs =!= {} && observedMax == 0.0;
  effPL = If[unevaluated, Max[base, 0.75], base];

  tags = With[{t = Lookup[policyIn, "accessTags", {}]}, If[ListQ[t], Cases[t, _String], {}]];
  denyTags = With[{t = Lookup[policyIn, "denyTags", {}]}, If[ListQ[t], Cases[t, _String], {}]];
  cloudOK = effPL < 0.5;
  requiresApproval = unevaluated || effPL >= 0.5;
  warnings = {};
  If[unevaluated, AppendTo[warnings,
    "Declared SourceRefs are not corroborated by observed MCP reads in this session/batch; " <>
    "privacy floored to 0.75 (fail-closed, §10.7.2)."]];

  Which[
    mode === "plan",
      <|"Status" -> "Planned", "WouldWrite" -> False,
        "EffectivePolicy" -> <|"PrivacyLevel" -> effPL, "AccessTags" -> tags,
          "DenyTags" -> denyTags, "CloudSendAllowed" -> cloudOK,
          "ReleaseContext" -> Lookup[policyIn, "releaseContext", None]|>,
        "NormalizedSourceRefs" -> sourceRefs,
        "SourceRefRoles" -> roles,
        "PrivacyBasis" -> <|"Requested" -> reqPL,
          "SessionObservedReadMax" -> sessMax, "BatchObservedReadMax" -> batchMax,
          "FailClosedFloorApplied" -> unevaluated, "Policy" -> "MaxObservedInput"|>,
        "RequiresApproval" -> requiresApproval,
        "ArtifactURIForm" -> "sv://artifact/<artifactId>",
        "Warnings" -> warnings|>,
    mode === "commit",
      Module[{auth, grantCeil, approvedQ, title, content, cb, bytes, artText, binaryQ, usage,
              contentSHA, idempKey, idxFile, idx, cached, blobRes, blobRef, contentUri,
              saveRes, artUri, depRec},
        (* request-gate (§11.5 / §15.3): commit は DepositArtifact 権限を要求 (grant か endpoint profile)。
           既定 profile は権限を持たない → fail-closed RequireGrant。 *)
        auth = iSVDepositAuthorized[spec];
        If[! TrueQ[Lookup[auth, "Authorized", False]],
          Return[<|"Status" -> "RequireGrant",
            "Reason" -> "commit requires DepositArtifact authorization: a grant from sourcevault_request_access " <>
              "(action=DepositArtifact) or an endpoint profile capability.",
            "RequiredAction" -> "DepositArtifact", "AuthDetail" -> auth,
            "HowToProceed" -> "sourcevault_request_access action=DepositArtifact -> poll sourcevault_access_status " <>
              "-> pass the granted grant in the deposit 'grant' field."|>]];
        (* privacy approval gate (§10.7.2): high-privacy / 未裏付け SourceRefs は明示 approval 無しに commit しない。
           ただし明示 Approved、または grant/profile の MaxAccessLevel が effPL 以上なら承認済み扱い。 *)
        grantCeil = With[{m = Lookup[auth, "MaxAccessLevel", 0.0]}, If[NumericQ[m], m, 0.0]];
        approvedQ = TrueQ[Lookup[spec, "Approved", False]] || grantCeil >= effPL;
        If[requiresApproval && ! approvedQ,
          Return[<|"Status" -> "RequireApproval",
            "Reason" -> "High-privacy or uncorroborated-source deposit requires approval (§10.7.2 / §11.5).",
            "EffectivePolicy" -> <|"PrivacyLevel" -> effPL, "CloudSendAllowed" -> cloudOK|>,
            "RequiresApproval" -> True, "AuthVia" -> Lookup[auth, "Via", None], "Warnings" -> warnings|>]];
        title = ToString @ Lookup[spec, "title", Lookup[spec, "filename", ""]];
        content = With[{c = Lookup[spec, "content", <||>]}, If[AssociationQ[c], c, <||>]];
        cb = iSVDepositContentBytes[content, title];
        If[cb === $Failed, Return[<|"Status" -> "InvalidContent", "Reason" -> "base64 decode failed"|>]];
        bytes = cb["Bytes"]; artText = cb["Text"]; binaryQ = cb["Binary"];
        If[Length[bytes] > $svDepositMaxBytes,
          Return[<|"Status" -> "PayloadTooLarge", "Bytes" -> Length[bytes],
            "MaxBytes" -> $svDepositMaxBytes|>]];
        If[! binaryQ && (! StringQ[artText] || StringTrim[artText] === ""),
          Return[<|"Status" -> "EmptyText", "Reason" -> "text deposit requires non-empty content.text"|>]];
        (* quota (§11.5): per-session/batch 件数・バイト超過は fail-closed *)
        usage = iSVDepositUsage[sid, bid];
        If[usage["Items"] >= $svDepositMaxItemsPerSession ||
           usage["Bytes"] + Length[bytes] > $svDepositMaxBytesPerSession,
          Return[<|"Status" -> "QuotaExceeded", "Usage" -> usage,
            "MaxItems" -> $svDepositMaxItemsPerSession, "MaxBytes" -> $svDepositMaxBytesPerSession|>]];
        (* idempotency: contentSHA256 + idempotencyKey。同一 key+同一 content は既存を返す。 *)
        contentSHA = "sha256:" <> ToLowerCase @ IntegerString[Hash[bytes, "SHA256"], 16, 64];
        idempKey = With[{k = Lookup[spec, "idempotencyKey", Missing[]]}, If[StringQ[k], k, contentSHA]];
        idxFile = iSVDepositIdempotencyFile[];
        idx = With[{a = If[StringQ[idxFile], iSVReadJSONFile[idxFile], $Failed]},
          If[AssociationQ[a], a, <||>]];
        cached = Lookup[idx, idempKey, Missing[]];
        If[AssociationQ[cached],
          If[Lookup[cached, "ContentSHA256", ""] === contentSHA,
            Return[Join[cached, <|"Status" -> "OK", "Existed" -> True|>]],
            Return[<|"Status" -> "IdempotencyCollision",
              "Reason" -> "different content for same idempotencyKey"|>]]];
        (* binary は content-addressed blob、text は DerivedArtifact 本文 *)
        blobRef = Missing[]; contentUri = Null;
        If[binaryQ,
          blobRes = SourceVault`SourceVaultCommitBlob[bytes,
            "Meta" -> <|"MediaType" -> Lookup[spec, "mediaType", Missing[]],
              "Filename" -> Lookup[spec, "filename", Missing[]], "Channel" -> "MCPDeposit"|>];
          If[AssociationQ[blobRes] && StringQ[Lookup[blobRes, "BlobRef", Null]],
            blobRef = blobRes["BlobRef"];
            (* hash 露出は cloud-safe な場合のみ (高 privacy は opaque artifactUri が正準, §3.1/§17.10) *)
            If[cloudOK, contentUri = "sv://hash/sha256/" <> ToString @ Lookup[blobRes, "Hash", ""]],
            Return[<|"Status" -> "BlobCommitFailed", "Detail" -> blobRes|>]]];
        (* DerivedArtifact として append-only 保存。ArtifactType "MCPDeposit" で低 weight "Deposited"
           参照イベント (weight 0.1, channel MCPDeposit) を SourceRefs ごと自動発行 + 逆引き用に保存。 *)
        saveRes = SourceVault`SourceVaultSaveDerivedArtifact[<|
          "Text" -> artText, "ArtifactType" -> "MCPDeposit", "SourceRefs" -> sourceRefs,
          "Model" -> ToString @ Lookup[Lookup[prov, "authoredBy", <||>], "modelId",
            Lookup[spec, "ModelId", ""]],
          "Provenance" -> <|"RequestChannel" -> "MCPDeposit",
            "AuthoredBy" -> Lookup[prov, "authoredBy", <||>],
            "DepositedBy" -> Lookup[spec, "Principal", <||>],
            "SessionId" -> sid, "BatchId" -> bid, "SourceRefRoles" -> roles,
            "ContentSHA256" -> contentSHA, "BlobRef" -> blobRef,
            "MediaType" -> Lookup[spec, "mediaType", Missing[]],
            "EffectivePolicy" -> <|"PrivacyLevel" -> effPL, "AccessTags" -> tags,
              "DenyTags" -> denyTags, "CloudSendAllowed" -> cloudOK|>|>|>];
        If[! AssociationQ[saveRes] || Lookup[saveRes, "Status", ""] =!= "OK",
          Return[<|"Status" -> "DepositWriteFailed", "Detail" -> saveRes|>]];
        artUri = "sv://artifact/" <> ToString @ Lookup[saveRes, "ArtifactId", ""];
        depRec = <|"ArtifactUri" -> artUri, "DerivedArtifactRef" -> Lookup[saveRes, "Ref"],
          "ContentSHA256" -> contentSHA, "ContentUri" -> contentUri,
          "SessionId" -> sid, "BatchId" -> bid, "Bytes" -> Length[bytes],
          "PrivacyLevel" -> effPL, "CreatedAtUTC" -> iSVUTCNowString[]|>;
        (* idempotency index 更新 + 監査ログ (quota 集計) append *)
        If[StringQ[idxFile], Quiet @ iSVWriteJSONFile[idxFile, Append[idx, idempKey -> depRec]]];
        With[{dp = iSVDepositsMonthFile[]}, If[StringQ[dp], Quiet @ iSVAppendJSONL[dp, depRec]]];
        <|"Status" -> "OK", "ArtifactUri" -> artUri,
          "DerivedArtifactRef" -> Lookup[saveRes, "Ref"], "ContentUri" -> contentUri,
          "Existed" -> Lookup[saveRes, "Existed", False],
          "EffectivePolicy" -> <|"PrivacyLevel" -> effPL, "AccessTags" -> tags,
            "DenyTags" -> denyTags, "CloudSendAllowed" -> cloudOK|>,
          "ReleasedProjection" -> "metadata", "RequiresApproval" -> requiresApproval|>],
    True,
      Failure["InvalidDepositMode", <|"Mode" -> mode|>]]];

(* ============================================================
   Universal MCP Access -- WorkSession layer (universal spec §13.5)
   c。Inc6/feedback/deposit の hotlog を SessionId/BatchId 単位に集約する view。
   新しい source of truth は作らず、既存 trace を束ねて notebook で俯瞰する (§17.22)。
   MaxObservedPrivacy は観測下限 (監視外含まず) で release 判断には使わない。
   ============================================================ *)

iSVBatchesFiles[] := With[{dir = iSVBatchesDir[]},
  If[! StringQ[dir] || ! DirectoryQ[dir], {}, FileNames["*.jsonl", dir, 1]]];

iSVWorkId[key_] := "svwork-" <> StringTake[IntegerString[Hash[key, "SHA256"], 16, 64], -12];

iSVWSGroupKey[ev_] := With[{sid = Lookup[ev, "SessionId", Missing[]], bid = Lookup[ev, "BatchId", Missing[]]},
  Which[
    StringQ[sid] && sid =!= "" && sid =!= "Unknown", sid,
    StringQ[bid] && bid =!= "", bid,
    True, "unlinked-heuristic"]];

(* mcp_calls + mcp_deposits を共通 event 形に正規化 (各 SessionId/BatchId/At/URIs/Privacy/LinkConfidence)。 *)
iSVCollectWorkEvents[] := Join[
  Map[Function[c, <|
    "Kind" -> "MCPCall", "Id" -> Lookup[c, "CallId", Missing[]],
    "SessionId" -> Lookup[c, "SessionId", Missing[]], "BatchId" -> Lookup[c, "BatchId", Missing[]],
    "At" -> Lookup[c, "StartedAtUTC", Lookup[c, "FinishedAtUTC", ""]],
    "URIs" -> Lookup[c, "ReleasedURIs", {}], "OutputURIs" -> {},
    "Privacy" -> Lookup[c, "MaxReleasedPrivacy", 0.0], "Tool" -> Lookup[c, "Tool", Missing[]],
    "LinkConfidence" -> Lookup[c, "LinkConfidence", "Explicit"]|>],
    Select[Join @@ (iSVReadJSONLFile /@ iSVMCPCallsFiles[]), AssociationQ]],
  Map[Function[d, <|
    "Kind" -> "Deposit", "Id" -> Lookup[d, "ArtifactUri", Missing[]],
    "SessionId" -> Lookup[d, "SessionId", Missing[]], "BatchId" -> Lookup[d, "BatchId", Missing[]],
    "At" -> Lookup[d, "CreatedAtUTC", ""], "URIs" -> {},
    "OutputURIs" -> {Lookup[d, "ArtifactUri", Missing[]]},
    "Privacy" -> Lookup[d, "PrivacyLevel", 0.0], "Tool" -> "sourcevault_deposit",
    "LinkConfidence" -> "Explicit"|>],
    Select[Join @@ (iSVReadJSONLFile /@ iSVDepositsFiles[]), AssociationQ]]];

iSVBatchTitleMap[] := Association @@ Cases[
  Join @@ (iSVReadJSONLFile /@ iSVBatchesFiles[]),
  b_?AssociationQ :> (ToString @ Lookup[b, "BatchId", ""] -> ToString @ Lookup[b, "Title", ""])];

iSVBuildWorkSession[key_, evs_, batchTitles_] := Module[
  {sids, bids, ats, callEvs, depEvs, uris, outUris, maxP, unlinked, heuristic, title},
  sids = DeleteDuplicates @ Cases[Lookup[#, "SessionId", Missing[]] & /@ evs, _String];
  bids = DeleteDuplicates @ Cases[Lookup[#, "BatchId", Missing[]] & /@ evs, _String];
  ats = Sort @ Cases[Lookup[#, "At", ""] & /@ evs, _String?(# =!= "" &)];
  callEvs = Select[evs, Lookup[#, "Kind"] === "MCPCall" &];
  depEvs = Select[evs, Lookup[#, "Kind"] === "Deposit" &];
  uris = DeleteDuplicates @ Cases[Flatten[Lookup[#, "URIs", {}] & /@ evs], _String];
  outUris = DeleteDuplicates @ Cases[Flatten[Lookup[#, "OutputURIs", {}] & /@ evs], _String];
  maxP = Max[Join[Cases[Lookup[#, "Privacy", 0.0] & /@ evs, _?NumericQ], {0.0}]];
  unlinked = Count[evs,
    _?(MemberQ[{"Heuristic", "Unlinked", "Metadata"}, Lookup[#, "LinkConfidence", "Explicit"]] &)];
  heuristic = (key === "unlinked-heuristic") || unlinked > 0;
  title = With[{bt = Lookup[batchTitles, First[bids, ""], ""]},
    Which[StringQ[bt] && bt =!= "", bt, sids =!= {}, First[sids], True, key]];
  <|"WorkId" -> iSVWorkId[key], "GroupKey" -> key,
    "SessionId" -> If[sids === {}, Missing[], First[sids]], "SessionIds" -> sids, "BatchIds" -> bids,
    "Title" -> title,
    "StartedAtUTC" -> If[ats === {}, Missing[], First[ats]],
    "EndedAtUTC" -> If[ats === {}, Missing[], Last[ats]],
    "MCPCallCount" -> Length[callEvs], "DepositCount" -> Length[depEvs],
    "MCPCallIds" -> Cases[Lookup[#, "Id", Missing[]] & /@ callEvs, _String],
    "RelatedURIs" -> uris, "OutputURIs" -> outUris, "RelatedURICount" -> Length[uris],
    "MaxObservedPrivacy" -> maxP,
    "MaxObservedPrivacyNote" -> "観測ベースの下限推定。監視外読み取りは含まない (§13.4)。",
    "UnlinkedCallCount" -> unlinked, "LinkConfidence" -> If[heuristic, "Heuristic", "Explicit"]|>];

iSVWSDateOK[at_, from_, to_] := Module[
  {day = If[StringQ[at] && StringLength[at] >= 10, StringTake[at, 10], ""]},
  And[! StringQ[from] || day === "" || day >= from,
    ! StringQ[to] || day === "" || day <= to]];

Options[SourceVaultListWorkSessions] = {
  "SessionId" -> All, "DateFrom" -> Automatic, "DateTo" -> Automatic, "MaxRows" -> Automatic};
SourceVaultListWorkSessions[OptionsPattern[]] := Module[{evs, titles, ws, sidF, fromF, toF, maxRows},
  evs = iSVCollectWorkEvents[];
  titles = iSVBatchTitleMap[];
  ws = KeyValueMap[iSVBuildWorkSession[#1, #2, titles] &, GroupBy[evs, iSVWSGroupKey]];
  sidF = OptionValue["SessionId"];
  If[StringQ[sidF], ws = Select[ws, MemberQ[Lookup[#, "SessionIds", {}], sidF] &]];
  fromF = With[{f = OptionValue["DateFrom"]}, If[StringQ[f], f, Null]];
  toF = With[{t = OptionValue["DateTo"]}, If[StringQ[t], t, Null]];
  If[StringQ[fromF] || StringQ[toF],
    ws = Select[ws, iSVWSDateOK[Lookup[#, "StartedAtUTC", ""], fromF, toF] &]];
  ws = Reverse @ SortBy[ws, Lookup[#, "StartedAtUTC", ""] &];
  maxRows = OptionValue["MaxRows"];
  If[IntegerQ[maxRows] && maxRows >= 0, ws = Take[ws, UpTo[maxRows]]];
  ws];

SourceVaultWorkSessionRecord[workId_String] :=
  SelectFirst[SourceVaultListWorkSessions[], Lookup[#, "WorkId", ""] === workId &,
    Missing["WorkSessionNotFound"]];

SourceVaultWorkSessionDataset[opts:OptionsPattern[SourceVaultListWorkSessions]] := Dataset @ Map[
  KeyTake[#, {"StartedAtUTC", "Title", "SessionId", "MCPCallCount", "DepositCount",
    "RelatedURICount", "MaxObservedPrivacy", "UnlinkedCallCount", "LinkConfidence", "WorkId"}] &,
  SourceVaultListWorkSessions[opts]];

SourceVaultWorkSessionGraph[workId_String] := Module[{ws = SourceVaultWorkSessionRecord[workId]},
  If[! AssociationQ[ws], Return[ws]];
  <|"WorkId" -> workId,
    "Nodes" -> Join[
      {<|"Id" -> workId, "Type" -> "WorkSession", "Label" -> Lookup[ws, "Title", workId]|>},
      Map[<|"Id" -> #, "Type" -> "MCPCall"|> &, Lookup[ws, "MCPCallIds", {}]],
      Map[<|"Id" -> #, "Type" -> "URI"|> &, Lookup[ws, "RelatedURIs", {}]],
      Map[<|"Id" -> #, "Type" -> "Artifact"|> &, Lookup[ws, "OutputURIs", {}]]],
    "Edges" -> Join[
      Map[<|"From" -> workId, "To" -> #, "Rel" -> "contains"|> &, Lookup[ws, "MCPCallIds", {}]],
      Map[<|"From" -> workId, "To" -> #, "Rel" -> "related"|> &, Lookup[ws, "RelatedURIs", {}]],
      Map[<|"From" -> workId, "To" -> #, "Rel" -> "output"|> &, Lookup[ws, "OutputURIs", {}]]]|>];

(* ============================================================
   Filesystem read access (read-only, allow-listed, cloud privacy)
   $packageDirectory / $ClaudeWorkingDirectory / $ClaudeAccessibleDirs are
   readable at PrivacyLevel 0.0 (cloud-ok). Everything else is denied.
   Secret-looking files are denied even inside allowed roots. Never writes.
   Service-loadable: no FrontEnd / NBAccess dependency.
   ============================================================ *)

$svFSMaxBytes = 524288;        (* per-file read cap (512 KiB) *)
$svFSMaxListEntries = 2000;    (* directory listing cap *)
$svFSMaxWriteBytes = 1048576;  (* per-file write cap (1 MiB) *)

iSVFSCanon[p_String] := With[{e = Quiet @ Check[ExpandFileName[p], p]},
  StringReplace[If[StringQ[e], e, p], "\\" -> "/"]];
iSVFSCanon[_] := "";

(* secret-looking files: denied to any sink even inside allowed roots.
   "token" matches credential-ish names only, not the bare substring
   (so e.g. tokenizer.wl stays readable). Adjustable list. *)
iSVFSSecretQ[canonPath_String] := Module[{low = ToLowerCase[canonPath], base},
  base = ToLowerCase[FileNameTake[canonPath]];
  Or[
    base === ".env", StringEndsQ[base, ".env"], StringStartsQ[base, ".env."],
    StringContainsQ[base, "secret"], StringContainsQ[base, "credential"],
    StringContainsQ[base, "password"], StringContainsQ[base, "apikey"],
    StringContainsQ[base, "api_key"], StringContainsQ[base, "privatekey"],
    StringContainsQ[base, "private_key"], StringContainsQ[base, "access_token"],
    StringContainsQ[base, "auth_token"], StringContainsQ[base, "refresh_token"],
    StringEndsQ[base, ".token"],
    StringEndsQ[base, ".pem"], StringEndsQ[base, ".key"], StringEndsQ[base, ".p12"],
    StringEndsQ[base, ".pfx"], StringEndsQ[base, ".crt"], StringEndsQ[base, ".cer"],
    StringEndsQ[base, ".der"],
    StringMatchQ[base, "id_rsa" ~~ ___], StringMatchQ[base, "id_dsa" ~~ ___],
    StringMatchQ[base, "id_ecdsa" ~~ ___], StringMatchQ[base, "id_ed25519" ~~ ___],
    StringContainsQ[low, "/.ssh/"], StringContainsQ[low, "/.aws/"],
    StringContainsQ[low, "/.gnupg/"], StringContainsQ[low, "/secrets/"],
    StringContainsQ[low, "/.git/"]]];
iSVFSSecretQ[_] := True;

iSVFSAllowedRoots[] := Module[{roots = {}},
  If[ValueQ[Global`$packageDirectory] && StringQ[Global`$packageDirectory],
    AppendTo[roots, Global`$packageDirectory]];
  If[ValueQ[ClaudeCode`$ClaudeWorkingDirectory] && StringQ[ClaudeCode`$ClaudeWorkingDirectory],
    AppendTo[roots, ClaudeCode`$ClaudeWorkingDirectory]];
  If[ValueQ[ClaudeCode`$ClaudeAccessibleDirs] && ListQ[ClaudeCode`$ClaudeAccessibleDirs],
    roots = Join[roots, Select[ClaudeCode`$ClaudeAccessibleDirs, StringQ]]];
  DeleteDuplicates[iSVFSCanon /@ Select[roots, StringQ[#] && # =!= "" &]]];

iSVFSUnderRootQ[canon_String] := AnyTrue[iSVFSAllowedRoots[],
  (canon === # || StringStartsQ[canon <> "/", # <> "/"]) &];

iSVFSAccessQ[pathIn_String] := Module[{canon = iSVFSCanon[pathIn]},
  Which[
    canon === "", <|"Allowed" -> False, "Reason" -> "BadPath"|>,
    ! iSVFSUnderRootQ[canon],
      <|"Allowed" -> False, "Reason" -> "OutsideAllowedRoots", "Path" -> canon|>,
    iSVFSSecretQ[canon],
      <|"Allowed" -> False, "Reason" -> "SecretFileDenied", "Path" -> canon|>,
    True, <|"Allowed" -> True, "Path" -> canon|>]];
iSVFSAccessQ[_] := <|"Allowed" -> False, "Reason" -> "BadPath"|>;

iSVFSListDir[pathIn_String] := Module[{acc, canon, entries},
  acc = iSVFSAccessQ[pathIn];
  If[! TrueQ[Lookup[acc, "Allowed", False]],
    Return[<|"Status" -> "Denied", "Reason" -> Lookup[acc, "Reason", "Denied"], "Path" -> pathIn|>]];
  canon = acc["Path"];
  If[! DirectoryQ[canon], Return[<|"Status" -> "NotADirectory", "Path" -> canon|>]];
  entries = Take[Quiet @ Check[FileNames["*", canon], {}], UpTo[$svFSMaxListEntries]];
  <|"Status" -> "OK", "Path" -> canon, "PrivacyLevel" -> 0.0, "Count" -> Length[entries],
    "Entries" -> Map[Function[f, <|
      "name" -> FileNameTake[f],
      "type" -> If[DirectoryQ[f], "directory", "file"],
      "bytes" -> If[DirectoryQ[f], Missing["Directory"], Quiet @ Check[FileByteCount[f], Missing[]]],
      "secret" -> iSVFSSecretQ[iSVFSCanon[f]]|>], entries]|>];
iSVFSListDir[_] := <|"Status" -> "Denied", "Reason" -> "BadPath"|>;

iSVFSReadFile[pathIn_String, maxBytesIn_:Automatic] := Module[
  {acc, canon, maxB, bytes, trunc, text},
  acc = iSVFSAccessQ[pathIn];
  If[! TrueQ[Lookup[acc, "Allowed", False]],
    Return[<|"Status" -> "Denied", "Reason" -> Lookup[acc, "Reason", "Denied"], "Path" -> pathIn|>]];
  canon = acc["Path"];
  If[DirectoryQ[canon], Return[<|"Status" -> "IsDirectory", "Path" -> canon|>]];
  If[! FileExistsQ[canon], Return[<|"Status" -> "NotFound", "Path" -> canon|>]];
  maxB = If[IntegerQ[maxBytesIn] && maxBytesIn > 0, Min[maxBytesIn, $svFSMaxBytes], $svFSMaxBytes];
  bytes = Quiet @ Check[ReadByteArray[canon], $Failed];
  If[bytes === EndOfFile,
    Return[<|"Status" -> "OK", "Path" -> canon, "Bytes" -> 0, "Truncated" -> False,
      "Text" -> "", "PrivacyLevel" -> 0.0|>]];
  If[Head[bytes] =!= ByteArray, Return[<|"Status" -> "ReadFailed", "Path" -> canon|>]];
  trunc = Length[bytes] > maxB;
  text = Quiet @ Check[ByteArrayToString[If[trunc, Take[bytes, maxB], bytes], "UTF-8"], $Failed];
  If[! StringQ[text],
    Return[<|"Status" -> "NotUTF8Text", "Path" -> canon, "Bytes" -> Length[bytes]|>]];
  <|"Status" -> "OK", "Path" -> canon, "Bytes" -> Length[bytes],
    "Truncated" -> trunc, "Text" -> text, "PrivacyLevel" -> 0.0|>];
iSVFSReadFile[_, ___] := <|"Status" -> "Denied", "Reason" -> "BadPath"|>;

(* ============================================================
   Filesystem WRITE relay (SourceVault_workflows only)
   For API / LM Studio models that cannot edit files directly (Claude Code and
   Codex edit $packageDirectory files directly and do not need this). Enforces the
   same access principle as reads -- only under an allowed root ($packageDirectory
   / $ClaudeWorkingDirectory / $ClaudeAccessibleDirs) -- AND additionally scopes
   writes to paths inside a "SourceVault_workflows/" subtree, and never to
   secret-looking files. UTF-8 text only, size-capped, creates parent dirs.
   ============================================================ *)

iSVFSWorkflowWriteAccessQ[pathIn_String] := Module[{canon = iSVFSCanon[pathIn]},
  Which[
    canon === "", <|"Allowed" -> False, "Reason" -> "BadPath"|>,
    ! iSVFSUnderRootQ[canon],
      <|"Allowed" -> False, "Reason" -> "OutsideAllowedRoots", "Path" -> canon|>,
    ! StringContainsQ[canon, "/SourceVault_workflows/"],
      <|"Allowed" -> False, "Reason" -> "WriteScopeIsSourceVaultWorkflowsOnly", "Path" -> canon|>,
    iSVFSSecretQ[canon],
      <|"Allowed" -> False, "Reason" -> "SecretFileDenied", "Path" -> canon|>,
    True, <|"Allowed" -> True, "Path" -> canon|>]];
iSVFSWorkflowWriteAccessQ[_] := <|"Allowed" -> False, "Reason" -> "BadPath"|>;

iSVFSWriteFile[pathIn_String, contentIn_] := Module[
  {acc, canon, bytes, dir, strm, existed},
  acc = iSVFSWorkflowWriteAccessQ[pathIn];
  If[! TrueQ[Lookup[acc, "Allowed", False]],
    Return[<|"Status" -> "Denied", "Reason" -> Lookup[acc, "Reason", "Denied"], "Path" -> pathIn|>]];
  canon = acc["Path"];
  If[DirectoryQ[canon], Return[<|"Status" -> "IsDirectory", "Path" -> canon|>]];
  If[! StringQ[contentIn],
    Return[<|"Status" -> "BadContent", "Reason" -> "content must be a UTF-8 string", "Path" -> canon|>]];
  bytes = Quiet @ Check[StringToByteArray[contentIn, "UTF-8"], $Failed];
  If[Head[bytes] =!= ByteArray, Return[<|"Status" -> "EncodeFailed", "Path" -> canon|>]];
  If[Length[bytes] > $svFSMaxWriteBytes,
    Return[<|"Status" -> "TooLarge", "Path" -> canon, "Bytes" -> Length[bytes],
      "MaxBytes" -> $svFSMaxWriteBytes|>]];
  dir = DirectoryName[canon];
  If[StringQ[dir] && dir =!= "" && ! DirectoryQ[dir],
    Quiet @ Check[CreateDirectory[dir, CreateIntermediateDirectories -> True], Null]];
  existed = FileExistsQ[canon];
  strm = Quiet @ Check[OpenWrite[canon, BinaryFormat -> True], $Failed];
  If[Head[strm] =!= OutputStream, Return[<|"Status" -> "OpenFailed", "Path" -> canon|>]];
  If[Quiet @ Check[BinaryWrite[strm, bytes]; Close[strm]; True, Quiet @ Close[strm]; False] =!= True,
    Return[<|"Status" -> "WriteFailed", "Path" -> canon|>]];
  <|"Status" -> "OK", "Path" -> canon, "Bytes" -> Length[bytes],
    "Created" -> ! existed, "Overwritten" -> existed, "PrivacyLevel" -> 0.0|>];
iSVFSWriteFile[_, ___] := <|"Status" -> "Denied", "Reason" -> "BadPath"|>;

(* ---- Claude Directives listing (rules / skills / CLAUDE.md), read live ---- *)
iSVFSDirectivesRoot[] := Module[{base},
  base = If[ValueQ[Global`$packageDirectory] && StringQ[Global`$packageDirectory],
    Global`$packageDirectory, Directory[]];
  SelectFirst[{FileNameJoin[{base, "Claude Directives"}], FileNameJoin[{base, ".claude"}]},
    DirectoryQ, Missing["NoDirectivesRoot"]]];

iSVFSFrontmatter[text_String] := Module[{m},
  m = StringCases[text, StartOfString ~~ "---\n" ~~ Shortest[b__] ~~ "\n---" :> b, 1];
  If[m === {}, Return[<||>]];
  Association @ Cases[StringSplit[First[m], "\n"],
    l_ /; StringContainsQ[l, ":"] :> With[{kv = StringSplit[l, ":"]},
      StringTrim[First[kv]] -> StringTrim[StringRiffle[Rest[kv], ":"]]]]];

iSVFSDirectiveEntry[file_String, role_String] := Module[{text, fm, title},
  text = Quiet @ Check[ByteArrayToString[ReadByteArray[file], "UTF-8"], ""];
  If[! StringQ[text], text = ""];
  fm = iSVFSFrontmatter[text];
  title = First[StringCases[text, StartOfLine ~~ "# " ~~ t : Except["\n"] .. :> t, 1], Missing[]];
  <|"role" -> role, "name" -> Lookup[fm, "name", FileBaseName[file]],
    "description" -> Lookup[fm, "description", title],
    "uri" -> ("sv://file/" <> iSVURIEnc[iSVFSCanon[file]]),
    "path" -> file, "bytes" -> Quiet @ Check[FileByteCount[file], Missing[]]|>];

iSVFSDirectivesList[kindIn_:"all"] := Module[{root, kind, items, claudemd},
  root = iSVFSDirectivesRoot[];
  If[! StringQ[root], Return[<|"Status" -> "NoDirectivesRoot"|>]];
  kind = ToLowerCase[ToString[kindIn]]; items = <||>;
  If[MemberQ[{"all", "rules"}, kind],
    items["Rules"] = iSVFSDirectiveEntry[#, "rule"] & /@
      Quiet @ Check[FileNames["*.md", FileNameJoin[{root, "rules"}]], {}]];
  If[MemberQ[{"all", "skills"}, kind],
    items["Skills"] = iSVFSDirectiveEntry[#, "skill"] & /@
      Quiet @ Check[FileNames["SKILL.md", FileNameJoin[{root, "skills"}], Infinity], {}]];
  If[MemberQ[{"all", "root"}, kind],
    claudemd = FileNameJoin[{root, "CLAUDE.md"}];
    If[FileExistsQ[claudemd], items["Root"] = {iSVFSDirectiveEntry[claudemd, "root"]}]];
  Join[<|"Status" -> "OK", "Root" -> root, "PrivacyLevel" -> 0.0,
    "Count" -> Total[Length /@ Values[items]]|>, items]];

(* ---- sv://file/<abs-path> adapter (read-only; content in summary at PL 0.0) ---- *)
iSVFileOwnsURIQ[parsed_Association] := Lookup[parsed, "Namespace", ""] === "file";

iSVFileResolve[parsed_Association, accessRequest_Association] := Module[{path, r, d},
  path = ToString @ Lookup[parsed, "Id", ""];
  If[path === "", Return[Missing["NoPath"]]];
  r = iSVFSReadFile[path];
  If[Lookup[r, "Status", ""] === "OK",
    Return[<|"URI" -> ("sv://file/" <> iSVURIEnc[r["Path"]]), "Kind" -> "file",
      "Title" -> FileNameTake[r["Path"]], "Summary" -> r["Text"], "PrivacyLevel" -> 0.0,
      "Metadata" -> <|"AccessTags" -> {}, "Bytes" -> Lookup[r, "Bytes", Missing[]],
        "Truncated" -> Lookup[r, "Truncated", False], "Type" -> "file"|>|>]];
  d = iSVFSListDir[path];
  If[Lookup[d, "Status", ""] === "OK",
    Return[<|"URI" -> ("sv://file/" <> iSVURIEnc[d["Path"]]), "Kind" -> "file",
      "Title" -> FileNameTake[d["Path"]],
      "Summary" -> ("directory (" <> ToString[d["Count"]] <> " entries): " <>
        StringRiffle[Lookup[#, "name"] & /@ Take[d["Entries"], UpTo[80]], ", "]),
      "PrivacyLevel" -> 0.0, "Metadata" -> <|"AccessTags" -> {}, "Type" -> "directory"|>|>]];
  Missing["NotAccessible"]];

(* ---- snapshot adapter: content-addressed 不変スナップショットを
   sv://snapshot/<class>/<hex> で解決し、privacy サイドレコードの level (既定 0.85) を
   Privacy.Level に載せて release gate を通す。これが無いと snapshot URI は NoResolver で
   ゲートを素通りしていた (privacy invariant phase 1)。 *)
iSVSnapshotOwnsURIQ[parsed_Association] := Lookup[parsed, "Namespace", ""] === "snapshot";

iSVSnapshotResolve[parsed_Association, accessRequest_Association] := Module[
  {segs, class, hex, ref, rec, level, summary},
  segs = Lookup[parsed, "Segments", {}];
  If[! (ListQ[segs] && Length[segs] === 2), Return[Missing["BadSnapshotURI"]]];
  {class, hex} = segs;
  ref = "snapshot:" <> ToString[class] <> ":" <> ToString[hex];
  rec = Quiet @ SourceVaultLoadImmutableSnapshot[ref];
  If[! AssociationQ[rec], Return[Missing["NotFound"]]];
  level = SourceVaultSnapshotPrivacyLevel[ref];
  summary = Which[
    StringQ[Lookup[rec, "Text", Null]], StringTake[rec["Text"], UpTo[800]],
    StringQ[Lookup[rec, "Summary", Null]], rec["Summary"],
    True, Missing["NoSummary"]];
  <|"URI" -> ("sv://snapshot/" <> iSVURIEnc[ToString[class]] <> "/" <> iSVURIEnc[ToString[hex]]),
    "Kind" -> "snapshot",
    "Title" -> Lookup[rec, "Title", ToString[class] <> " snapshot"],
    "Summary" -> summary,
    "PrivacyLevel" -> level,
    "Metadata" -> <|"AccessTags" -> {}, "Class" -> class, "Type" -> "snapshot",
      "Role" -> Lookup[rec, "Role", Missing[]],
      "Project" -> Lookup[rec, "Project", Missing[]],
      "PrivacySource" -> Lookup[SourceVaultSnapshotPrivacyRecord[ref], "Source", "Default"]|>|>
];

(* ---- built-in adapter のデフォルト登録 (load 時) ---- *)
iSVRegisterDefaultAdapters[] := (
  SourceVaultRegisterMCPDataAdapter["search", <|
    "Kinds" -> {"search", "pdf"}, "Available" -> True,
    "Capabilities" -> <|"Search" -> True, "ReadMetadata" -> True,
      "ReadSummary" -> True, "MetadataFilter" -> True,
      "ResolveObjectURI" -> True, "ReadBody" -> True|>,
    "RequireGrantFor" -> {"body", "raw"},
    "Search" -> iSVSearchAdapterSearch,
    (* #3: sv://chunk/<collection>:<index> を解決 (resolve=identity, ReadBody=pdfGetChunk 全文・grant 必須) *)
    "OwnsURIQ" -> iSVPdfOwnsURIQ, "Resolve" -> iSVPdfChunkResolve,
    "ReadBody" -> iSVPdfChunkReadBody|>];
  SourceVaultRegisterMCPDataAdapter["snapshot", <|
    "Kinds" -> {"snapshot"}, "Available" -> True,
    "Capabilities" -> <|"ReadMetadata" -> True, "ReadSummary" -> True,
      "ResolveObjectURI" -> True|>,
    "RequireGrantFor" -> {},
    "OwnsURIQ" -> iSVSnapshotOwnsURIQ, "Resolve" -> iSVSnapshotResolve|>];
  SourceVaultRegisterMCPDataAdapter["web", <|
    "Kinds" -> {"web"}, "Available" -> True,
    "Capabilities" -> <|"Search" -> True, "ReadMetadata" -> True, "ReadSummary" -> True|>,
    "RequireGrantFor" -> {"body", "raw"},
    "Search" -> iSVWebAdapterSearch|>];
  SourceVaultRegisterMCPDataAdapter["eagle", <|
    "Kinds" -> {"eagle", "image", "pdf"},
    (* Names ではなく DownValues で判定: mcp.wl 自身が SourceVaultEagleSearch を参照するため
       headless でも symbol は存在する。実定義 (DownValues) の有無で可用性を見る。 *)
    "AvailableProbe" -> Function[Length[DownValues[SourceVault`SourceVaultEagleSearch]] > 0 &&
      Length[DownValues[SourceVault`SourceVaultEagleSummaryRow]] > 0],
    "UnavailableReason" -> "MainKernelOnly (eagle library required)",
    "Capabilities" -> <|"Search" -> True, "ReadMetadata" -> True, "ReadSummary" -> True,
      "MetadataFilter" -> True, "ResolveObjectURI" -> True, "ReadBody" -> True|>,
    "RequireGrantFor" -> {"body", "raw", "context"},
    "Search" -> iSVEagleAdapterSearch,
    (* Phase C2: sv://object/eagle-... を Eagle item metadata から解決 (原本は開かない) *)
    "OwnsURIQ" -> iSVEagleOwnsURIQ, "Resolve" -> iSVEagleAdapterResolve,
    (* D3 拡張: body/context は抽出テキスト解放 (grant 必須・非cloud・main kernel のみ) *)
    "ReadBody" -> iSVEagleAdapterReadBody|>];
  SourceVaultRegisterMCPDataAdapter["mail", <|
    "Kinds" -> {"mail"},
    (* maildb は main kernel のみ。索引検索関数の実定義 (DownValues) の有無で probe。 *)
    "AvailableProbe" -> Function[Length[DownValues[SourceVault`SourceVaultMailSearchIndex]] > 0],
    "UnavailableReason" -> "MainKernelOnly (maildb metadata index required)",
    "Capabilities" -> <|"Search" -> True, "ReadMetadata" -> True, "ReadSummary" -> True,
      "MetadataFilter" -> True, "ResolveObjectURI" -> True, "ReadBody" -> True|>,
    "RequireGrantFor" -> {"body", "raw", "attachment"},
    "Search" -> iSVMailAdapterSearch,
    (* Phase C: sv://record/svmail-... を索引から解決 (本文はロードしない) *)
    "OwnsURIQ" -> iSVMailOwnsURIQ, "Resolve" -> iSVMailAdapterResolve,
    (* D3: 本文解放 (grant 必須・非cloud sink・main kernel のみ) *)
    "ReadBody" -> iSVMailAdapterReadBody|>];
  (* filesystem: read-only, allow-listed, content released at PL 0.0 (cloud-ok). *)
  SourceVaultRegisterMCPDataAdapter["filesystem", <|
    "Kinds" -> {"file", "filesystem"}, "Available" -> True,
    "Capabilities" -> <|"ReadMetadata" -> True, "ReadSummary" -> True,
      "ResolveObjectURI" -> True|>,
    "RequireGrantFor" -> {},
    "OwnsURIQ" -> iSVFileOwnsURIQ, "Resolve" -> iSVFileResolve|>];
);

iSVRegisterDefaultAdapters[];

(* ---- tool 定義 (JSON Schema inputSchema) ---- *)
SourceVaultMCPTools[] := {
  <|"name" -> "sourcevault_web_search",
    "description" -> "Search the local web via SearXNG and return candidate results " <>
      "(title, url, snippet). Does NOT fetch page bodies. Use for quick lookups.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "query" -> <|"type" -> "string", "description" -> "Search query."|>,
        "maxResults" -> <|"type" -> "integer", "description" -> "Max results (default 10)."|>|>,
      "required" -> {"query"}|>|>,
  <|"name" -> "sourcevault_submit_web_search",
    "description" -> "Submit an asynchronous web search job. Optionally fetch and clean-text " <>
      "the top results (fetchPages). Returns a jobId; poll with sourcevault_job_status / " <>
      "sourcevault_job_result.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "query" -> <|"type" -> "string", "description" -> "Search query."|>,
        "maxResults" -> <|"type" -> "integer", "description" -> "Max search results (default 10)."|>,
        "fetchPages" -> <|"type" -> "boolean", "description" -> "Fetch & clean-text top pages (default false)."|>,
        "maxFetch" -> <|"type" -> "integer", "description" -> "Max pages to fetch when fetchPages (default 3)."|>|>,
      "required" -> {"query"}|>|>,
  <|"name" -> "sourcevault_job_status",
    "description" -> "Get the status of a web search job (Queued/Running/Succeeded/Failed).",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|"jobId" -> <|"type" -> "string", "description" -> "Job id from submit."|>|>,
      "required" -> {"jobId"}|>|>,
  <|"name" -> "sourcevault_job_result",
    "description" -> "Get the result of a completed web search job (results + fetched documents).",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|"jobId" -> <|"type" -> "string", "description" -> "Job id from submit."|>|>,
      "required" -> {"jobId"}|>|>,
  <|"name" -> "sourcevault_get_document",
    "description" -> "Load a stored WebDocument by snapshot ref (returns url, title, clean-text length, hash).",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|"snapshotRef" -> <|"type" -> "string", "description" -> "WebDocument snapshot ref."|>|>,
      "required" -> {"snapshotRef"}|>|>,
  <|"name" -> "sourcevault_catalog",
    "description" -> "List available SourceVault data adapters: their kinds, capabilities, " <>
      "and which views require an access grant. Call this first to discover what data can be searched or read.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|"includeUnavailable" -> <|"type" -> "boolean",
        "description" -> "Include adapters that are currently unavailable (default true)."|>|>|>|>,
  <|"name" -> "sourcevault_runtime_capabilities",
    "description" -> "Report how this client/model connects to SourceVault: trust domain, whether SourceVault " <>
      "MCP can be called during inference, the recommended prompt strategy (MCPDeferred | InlineContext | " <>
      "Hybrid | LocalToolRefs | NoSourceVault), and the output trust ceiling. Client-reported fields are " <>
      "advisory and do NOT raise hard caps.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "provider" -> <|"type" -> "string", "description" -> "Model provider, e.g. lmstudio | anthropic | openai."|>,
        "modelId" -> <|"type" -> "string", "description" -> "Model id."|>,
        "clientKind" -> <|"type" -> "string", "description" -> "Client kind, e.g. desktop-chat | cli | api."|>,
        "mcpToolsVisible" -> <|"type" -> "array", "items" -> <|"type" -> "string"|>,
          "description" -> "SourceVault MCP tool names visible to the client."|>,
        "sourcevaultMcpEnabled" -> <|"type" -> "boolean",
          "description" -> "Whether SourceVault MCP is enabled for this client."|>,
        "canCallMcpDuringInference" -> <|"type" -> "boolean",
          "description" -> "Whether the client can call MCP tools mid-inference."|>,
        "localFolderReadableByTool" -> <|"type" -> "boolean",
          "description" -> "Whether the client can read local files with its own tools."|>,
        "localPackageDirectoryReadable" -> <|"type" -> "boolean",
          "description" -> "Whether the client can read the package directory."|>|>|>|>,
  <|"name" -> "sourcevault_search",
    "description" -> "Search across SourceVault data adapters (web, search index, ...). Returns URIs " <>
      "with title/snippet/citation. Use sourcevault_catalog to see available kinds. High-privacy bodies " <>
      "are NOT returned here; resolve a URI with sourcevault_get (a grant may be required).",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "query" -> <|"type" -> "string", "description" -> "Search query."|>,
        "kinds" -> <|"type" -> "array", "items" -> <|"type" -> "string"|>,
          "description" -> "Data kinds to search, e.g. [\"search\"] or [\"all\"] (default [\"all\"])."|>,
        "scope" -> <|"type" -> "object",
          "description" -> "releaseContext (string), requireAccessTags, denyAccessTags, untagged."|>,
        "filters" -> <|"type" -> "object",
          "description" -> "accessLevelMax (number), dateFrom, dateTo, ext, tags, etc."|>,
        "limit" -> <|"type" -> "integer", "description" -> "Max results (default 20)."|>,
        "offset" -> <|"type" -> "integer", "description" -> "Result offset (default 0)."|>,
        "return" -> <|"type" -> "object",
          "description" -> "format: compactText | structuredJson | referencesOnly; maxCharsPerResult."|>,
        "purpose" -> <|"type" -> "string", "description" -> "Why the data is needed."|>|>,
      "required" -> {"query"}|>|>,
  <|"name" -> "sourcevault_get",
    "description" -> "Resolve a single sv:// URI (e.g. from sourcevault_search results) to its low-privacy " <>
      "metadata/summary projection. Bodies/raw/attachments are NOT returned (they require an access grant); " <>
      "the response lists requiresGrantFor. High-privacy items may be release-gated (released=false).",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "uri" -> <|"type" -> "string", "description" -> "The sv:// URI to resolve."|>,
        "view" -> <|"type" -> "string",
          "description" -> "metadata | summary (default) | body. body/raw/context need a valid grant and a non-cloud sink; mail body is main-kernel only."|>,
        "grant" -> <|"type" -> "object",
          "description" -> "An AccessGrant from sourcevault_access_status (required for body/raw/context)."|>,
        "scope" -> <|"type" -> "object", "description" -> "releaseContext (string)."|>,
        "filters" -> <|"type" -> "object", "description" -> "accessLevelMax (number)."|>,
        "return" -> <|"type" -> "object",
          "description" -> "format: compactText | structuredJson."|>,
        "purpose" -> <|"type" -> "string", "description" -> "Why the data is needed."|>|>,
      "required" -> {"uri"}|>|>,
  <|"name" -> "sourcevault_request_access",
    "description" -> "Request an access grant for high-privacy content (body/raw/attachment/context) that " <>
      "sourcevault_get / sourcevault_search would not release. Returns a RequestId; a human approves it in " <>
      "Mathematica. Poll sourcevault_access_status. Does NOT itself grant access.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "objectRefs" -> <|"type" -> "array", "items" -> <|"type" -> "string"|>,
          "description" -> "sv:// URIs to request access to."|>,
        "kinds" -> <|"type" -> "array", "items" -> <|"type" -> "string"|>,
          "description" -> "Data kinds, e.g. [\"mail\"]."|>,
        "fields" -> <|"type" -> "array", "items" -> <|"type" -> "string"|>,
          "description" -> "Views requested, e.g. [\"body\"]."|>,
        "action" -> <|"type" -> "string", "description" -> "e.g. ReadBody (default)."|>,
        "sink" -> <|"type" -> "string", "description" -> "Where the data goes (e.g. LocalOnly). Cloud sinks cannot get high-privacy bodies."|>,
        "accessLevelMax" -> <|"type" -> "number", "description" -> "Requested ceiling (not binding; approver caps it)."|>,
        "purpose" -> <|"type" -> "string", "description" -> "Why the data is needed."|>|>,
      "required" -> {"purpose"}|>|>,
  <|"name" -> "sourcevault_access_status",
    "description" -> "Poll the status of an access request created by sourcevault_request_access. " <>
      "Returns Pending | Granted | Denied | Expired (and the grant when Granted).",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "requestId" -> <|"type" -> "string", "description" -> "The RequestId from sourcevault_request_access."|>|>,
      "required" -> {"requestId"}|>|>,
  <|"name" -> "sourcevault_feedback_submit",
    "description" -> "Record a feedback event for ClaudeOrchestrator (help request, subtask proposal, " <>
      "critique/correction, session note). Recorded only — does NOT run any workflow or grant access. " <>
      "A human/orchestrator may act on it later.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "kind" -> <|"type" -> "string",
          "description" -> "HelpRequest | SubtaskProposal | AccessRequest | Critique | Correction | SessionNote."|>,
        "text" -> <|"type" -> "string", "description" -> "The feedback message."|>,
        "goal" -> <|"type" -> "string", "description" -> "Optional goal/intent."|>,
        "evidenceRefs" -> <|"type" -> "array", "items" -> <|"type" -> "string"|>,
          "description" -> "Optional sv:// URIs this feedback refers to."|>,
        "sessionId" -> <|"type" -> "string", "description" -> "Optional session id."|>,
        "purpose" -> <|"type" -> "string", "description" -> "Why."|>|>,
      "required" -> {"kind", "text"}|>|>,
  <|"name" -> "sourcevault_orchestrator_help",
    "description" -> "Convenience: record a HelpRequest feedback event (e.g. 'this scope can't answer; " <>
      "please do additional exploration'). Recorded only.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "text" -> <|"type" -> "string", "description" -> "What help is needed."|>,
        "goal" -> <|"type" -> "string", "description" -> "Optional goal."|>,
        "evidenceRefs" -> <|"type" -> "array", "items" -> <|"type" -> "string"|>|>,
        "sessionId" -> <|"type" -> "string"|>|>,
      "required" -> {"text"}|>|>,
  <|"name" -> "sourcevault_orchestrator_subtask",
    "description" -> "Convenience: record a SubtaskProposal feedback event (e.g. 'summarize this paper set " <>
      "with a local worker'). Recorded only — does NOT spawn a worker.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "text" -> <|"type" -> "string", "description" -> "The proposed subtask."|>,
        "goal" -> <|"type" -> "string", "description" -> "Optional goal."|>,
        "suggestedRole" -> <|"type" -> "string", "description" -> "Optional worker role."|>,
        "suggestedCapabilities" -> <|"type" -> "array", "items" -> <|"type" -> "string"|>|>,
        "evidenceRefs" -> <|"type" -> "array", "items" -> <|"type" -> "string"|>|>,
        "sessionId" -> <|"type" -> "string"|>|>,
      "required" -> {"text"}|>|>,
  <|"name" -> "sourcevault_deposit",
    "description" -> "Append-only deposit of an LLM-generated artifact (markdown / .wl / text / JSON / PDF / " <>
      "image) into SourceVault as an immutable DerivedArtifact, addressed by a returned sv://artifact/<id> URI. " <>
      "Create-only: never overwrites, deletes, or declassifies existing data (those need separate approval). " <>
      "mode 'plan' previews the inherited policy / URI form without writing; mode 'commit' writes and REQUIRES " <>
      "DepositArtifact authorization (a grant from sourcevault_request_access action=DepositArtifact, or an " <>
      "endpoint profile capability) -- otherwise it returns RequireGrant. Privacy is inherited from same-session/" <>
      "batch reads (Max composition, no laundering); high-privacy or uncorroborated deposits return RequireApproval. " <>
      "Per-session/batch item and byte quotas apply (QuotaExceeded). Same content + idempotencyKey is idempotent.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "mode" -> <|"type" -> "string", "description" -> "plan (preview, no write) | commit (write). Default plan."|>,
        "title" -> <|"type" -> "string", "description" -> "Artifact title."|>,
        "content" -> <|"type" -> "object",
          "description" -> "{text: string} for text/markdown/wl/json, or {base64: string} for binary."|>,
        "mediaType" -> <|"type" -> "string",
          "description" -> "e.g. text/markdown, application/vnd.wolfram.wl, application/pdf, image/png."|>,
        "filename" -> <|"type" -> "string", "description" -> "Optional filename for binary content."|>,
        "provenance" -> <|"type" -> "object",
          "description" -> "{inputRefs, citationRefs, promptRefs: [sv:// URIs], authoredBy: {modelId, provider}}."|>,
        "policy" -> <|"type" -> "object",
          "description" -> "{privacyLevel (lower bound only), accessTags, denyTags, releaseContext}. Privacy is only raised."|>,
        "grant" -> <|"type" -> "object",
          "description" -> "An AccessGrant (from sourcevault_access_status) whose AllowedActions includes DepositArtifact. Required for commit unless the endpoint profile permits deposit."|>,
        "sessionId" -> <|"type" -> "string", "description" -> "Session id (privacy inheritance + quota)."|>,
        "batchId" -> <|"type" -> "string", "description" -> "Optional batch id."|>,
        "idempotencyKey" -> <|"type" -> "string", "description" -> "Optional; same key + content returns the existing artifact."|>,
        "purpose" -> <|"type" -> "string", "description" -> "Why this artifact is being stored."|>|>,
      "required" -> {"content"}|>|>,
  <|"name" -> "sourcevault_fs_list",
    "description" -> "List a directory under an allow-listed root ($packageDirectory, $ClaudeWorkingDirectory, or a $ClaudeAccessibleDirs entry). Read-only. Returns entries (name, type, bytes, secret-flag). Paths outside the allowed roots are not accessible.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "path" -> <|"type" -> "string", "description" -> "Absolute directory path under an allowed root."|>|>,
      "required" -> {"path"}|>|>,
  <|"name" -> "sourcevault_fs_read",
    "description" -> "Read a UTF-8 text file under an allow-listed root (cloud-accessible privacy). Read-only and size-capped. Secret-looking files (.env, *secret*, *credential*, keys/certs, .ssh, etc.) and paths outside the allowed roots are denied. Write is not supported.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "path" -> <|"type" -> "string", "description" -> "Absolute file path under an allowed root."|>,
        "maxBytes" -> <|"type" -> "integer", "description" -> "Optional read cap in bytes; clamped to the server max."|>|>,
      "required" -> {"path"}|>|>,
  <|"name" -> "sourcevault_directives",
    "description" -> "List Claude Directives (rules/, skills/, CLAUDE.md) with name, description and an sv://file URI for each, so CLI and API agents share the same directive set. Read live from the canonical Claude Directives directory. Use sourcevault_fs_read (or sourcevault_get on the sv://file URI) to fetch a directive's full text.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "kind" -> <|"type" -> "string", "description" -> "rules | skills | root | all (default all)."|>|>,
      "required" -> {}|>|>,
  <|"name" -> "sourcevault_workflow_write",
    "description" -> "Relay a UTF-8 text WRITE to a SourceVault_workflows file under an allow-listed root ($packageDirectory / $ClaudeWorkingDirectory / $ClaudeAccessibleDirs). Intended for API / LM Studio models that cannot edit files directly (Claude Code and Codex edit files directly and do NOT need this). Write is SCOPED to paths inside a 'SourceVault_workflows/' subtree; paths outside the allowed roots, non-SourceVault_workflows paths, and secret-looking files are denied. Creates parent directories, overwrites existing files, size-capped (1 MiB). To READ workflow files use sourcevault_fs_read / sourcevault_fs_list.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "path" -> <|"type" -> "string", "description" -> "Absolute file path under <allowed-root>/SourceVault_workflows/ (parent dirs are created)."|>,
        "content" -> <|"type" -> "string", "description" -> "Full UTF-8 text content to write (replaces the file)."|>|>,
      "required" -> {"path", "content"}|>|>
  };

(* ---- text content helper ---- *)
iMCPText[s_String] := <|"content" -> {<|"type" -> "text", "text" -> s|>}, "isError" -> False|>;
iMCPError[s_String] := <|"content" -> {<|"type" -> "text", "text" -> s|>}, "isError" -> True|>;

(* structured な連想を JSON-safe text block にして返す (structuredJson 用) *)
iMCPJSONText[expr_] := Module[{s},
  s = Quiet @ ExportString[iSVJSONSafe[expr], "RawJSON", "Compact" -> True];
  If[StringQ[s], iMCPText[s], iMCPError["JSON encode failed"]]];

iMCPFormatResults[results_List] := StringRiffle[
  MapIndexed[Function[{r, i},
    ToString[First[i]] <> ". " <> ToString @ Lookup[r, "Title", ""] <> "\n   " <>
      ToString @ Lookup[r, "Url", ""] <> "\n   " <>
      StringTake[ToString @ Lookup[r, "Snippet", ""], UpTo[200]]],
    results], "\n"];

(* MCP 経由の最小 provenance (spec v6 §9.3) *)
iMCPProvenance[args_Association] := <|
  "InitiationType" -> "MCPIngest",
  "RequestChannel" -> "MCP",
  "UrlOrigin" -> "SearchResult",
  "UserSpecifiedUrl" -> "Unknown",
  "Actor" -> <|"Type" -> "MCPClient",
    "ClientName" -> Lookup[args, "_mcpClient", "LM Studio"]|>|>;

(* ---- tool 実行 ---- *)
SourceVaultMCPCallTool[name_String, args_Association] := Module[{prov, r},
  prov = iMCPProvenance[args];
  Switch[name,
    "sourcevault_web_search",
      r = SourceVault`SourceVaultWebSearch[Lookup[args, "query", ""],
        "MaxResults" -> Lookup[args, "maxResults", 10],
        "RequestChannel" -> "MCP", "InitiationType" -> "MCPIngest",
        (* SearchRun の監査記録に MCP クライアント識別を残す (Actor=MCPClient) *)
        "Actor" -> Lookup[prov, "Actor", Automatic]];
      If[FailureQ[r], iMCPError["Search failed: " <> ToString[r]],
        iMCPText["Found " <> ToString @ Lookup[r, "ResultCount", 0] <> " results for \"" <>
          Lookup[args, "query", ""] <> "\":\n\n" <> iMCPFormatResults[Lookup[r, "Results", {}]]]],
    "sourcevault_submit_web_search",
      r = SourceVault`SourceVaultWebSearchSubmit[<|
        "Query" -> Lookup[args, "query", ""],
        "MaxResults" -> Lookup[args, "maxResults", 10],
        "FetchPages" -> TrueQ[Lookup[args, "fetchPages", False]],
        "MaxFetch" -> Lookup[args, "maxFetch", 3],
        "RequestChannel" -> "MCP", "InitiationType" -> "MCPIngest",
        (* SearchRun にも MCP Actor を通す ("Actor" は SourceVaultWebSearch のオプションなので
           iWebRunSearchJob の FilterRules で SearchRun の provenance に乗る)。
           "Provenance" は文書 fetch (WebDocument) 側の provenance。 *)
        "Actor" -> Lookup[prov, "Actor", Automatic],
        "Provenance" -> prov|>];
      If[! AssociationQ[r], iMCPError["Submit failed: " <> ToString[r]],
        iMCPText["Submitted job " <> ToString @ Lookup[r, "JobId", "?"] <>
          " (status: " <> ToString @ Lookup[r, "Status", "?"] <>
          "). Use sourcevault_job_result with this jobId to get results."]],
    "sourcevault_job_status",
      r = SourceVault`SourceVaultWebJobStatus[Lookup[args, "jobId", ""]];
      iMCPText["Job " <> ToString @ Lookup[r, "JobId", "?"] <> ": " <> ToString @ Lookup[r, "Status", "?"]],
    "sourcevault_job_result",
      r = SourceVault`SourceVaultWebJobResult[Lookup[args, "jobId", ""]];
      Which[
        ! TrueQ[Lookup[r, "Ready", False]],
          iMCPText["Job not ready: " <> ToString @ Lookup[r, "Status", "?"]],
        Lookup[r, "Status", ""] === "Failed",
          iMCPError["Job failed: " <> ToString @ Lookup[r, "FailureReason", "?"]],
        True,
          Module[{res = Lookup[r, "Result", <||>], docs},
            docs = Lookup[res, "Documents", {}];
            iMCPText["Results (" <> ToString @ Lookup[res, "ResultCount", 0] <> "):\n\n" <>
              iMCPFormatResults[Lookup[res, "Results", {}]] <>
              If[docs =!= {},
                "\n\nFetched documents (" <> ToString[Length[docs]] <> "):\n" <>
                  StringRiffle[Function[d,
                    "- " <> ToString @ Lookup[d, "Title", Lookup[d, "Url", "?"]] <> " [" <>
                    ToString @ Lookup[d, "ExtractionStatus", "?"] <> ", " <>
                    ToString @ Lookup[d, "CleanTextLength", 0] <> " chars]"] /@ docs, "\n"],
                ""]]]],
    "sourcevault_get_document",
      r = SourceVault`SourceVaultLoadImmutableSnapshot[Lookup[args, "snapshotRef", ""]];
      If[! AssociationQ[r], iMCPError["Document not found: " <> ToString @ Lookup[args, "snapshotRef", ""]],
        iMCPText["WebDocument:\n  Url: " <> ToString @ Lookup[r, "Url", "?"] <>
          "\n  Title: " <> ToString @ Lookup[r, "Title", ""] <>
          "\n  ContentHash: " <> ToString @ Lookup[r, "ContentHash", "?"] <>
          "\n  CleanTextLength: " <> ToString @ Lookup[r, "CleanTextLength", 0] <>
          "\n  ExtractionStatus: " <> ToString @ Lookup[r, "ExtractionStatus", "?"]]],
    "sourcevault_catalog",
      iMCPJSONText[SourceVaultMCPCatalog[
        "IncludeUnavailable" -> TrueQ[Lookup[args, "includeUnavailable", True]]]],
    "sourcevault_runtime_capabilities",
      iMCPJSONText[SourceVaultMCPRuntimeCapabilities[args]],
    "sourcevault_search",
      Module[{out, fmt},
        out = SourceVaultMCPSearch[args, "Principal" -> SourceVaultNormalizePrincipal[args]];
        iSVRecordToolCall["sourcevault_search", args, out];
        fmt = Lookup[out, "Format", "compactText"];
        If[fmt === "structuredJson",
          iMCPJSONText[<|"count" -> Lookup[out, "Count", 0], "results" -> Lookup[out, "Results", {}]|>],
          iMCPText["Found " <> ToString @ Lookup[out, "Count", 0] <> " result(s):\n\n" <>
            Lookup[out, "Rendered", ""]]]],
    "sourcevault_get",
      Module[{out, fmt},
        out = SourceVaultMCPGet[Lookup[args, "uri", ""],
          "Principal" -> SourceVaultNormalizePrincipal[args],
          "AccessLevel" -> Lookup[Lookup[args, "filters", <||>], "accessLevelMax", Automatic],
          "ReleaseContext" -> Lookup[Lookup[args, "scope", <||>], "releaseContext", None],
          "View" -> Lookup[args, "view", Automatic],
          "Grant" -> With[{g = Lookup[args, "grant", None]}, If[AssociationQ[g], g, None]]];
        iSVRecordToolCall["sourcevault_get", args, out];
        fmt = Lookup[Lookup[args, "return", <||>], "format", "structuredJson"];
        If[fmt === "compactText",
          iMCPText[
            "URI: " <> ToString @ Lookup[out, "URI", "?"] <>
            "\nFound: " <> ToString @ Lookup[out, "Found", False] <>
            "  Released: " <> ToString @ Lookup[out, "Released", False] <>
            If[TrueQ[Lookup[out, "Released", False]],
              "\n" <> SourceVaultRenderSearchResults[{Lookup[out, "Result", <||>]}, "compactText"],
              "\nWhy: " <> ToString @ Lookup[out, "Why", {}]] <>
            "\nrequiresGrantFor: " <> ToString @ Lookup[out, "RequiresGrantFor", {}]],
          (* structuredJson: AccessRequest は内部情報なので返却から落とす *)
          iMCPJSONText[KeyDrop[out, "AccessRequest"]]]],
    "sourcevault_request_access",
      iMCPJSONText[SourceVaultMCPRequestAccess[<|
        "Principal" -> SourceVaultNormalizePrincipal[args],
        "Action" -> Lookup[args, "action", "ReadBody"],
        "ObjectRefs" -> Lookup[args, "objectRefs", {}],
        "Kinds" -> Lookup[args, "kinds", {}],
        "Fields" -> Lookup[args, "fields", {}],
        "Sink" -> Lookup[args, "sink", "LocalOnly"],
        "RequestedAccessLevel" -> Lookup[args, "accessLevelMax", Missing[]],
        "ReleaseContext" -> Lookup[Lookup[args, "scope", <||>], "releaseContext", None],
        "Purpose" -> Lookup[args, "purpose", ""]|>]],
    "sourcevault_access_status",
      iMCPJSONText[SourceVaultMCPAccessStatus[ToString @ Lookup[args, "requestId", ""]]],
    "sourcevault_feedback_submit",
      iMCPJSONText[SourceVaultMCPSubmitFeedback[<|
        "Principal" -> SourceVaultNormalizePrincipal[args],
        "Kind" -> Lookup[args, "kind", "SessionNote"],
        "SessionId" -> Lookup[args, "sessionId", "Unknown"],
        "Payload" -> <|"Text" -> Lookup[args, "text", ""], "Goal" -> Lookup[args, "goal", Missing[]],
          "EvidenceRefs" -> Lookup[args, "evidenceRefs", {}]|>|>]],
    "sourcevault_orchestrator_help",
      iMCPJSONText[SourceVaultMCPSubmitFeedback[<|
        "Principal" -> SourceVaultNormalizePrincipal[args], "Kind" -> "HelpRequest",
        "SessionId" -> Lookup[args, "sessionId", "Unknown"],
        "Payload" -> <|"Text" -> Lookup[args, "text", ""], "Goal" -> Lookup[args, "goal", Missing[]],
          "EvidenceRefs" -> Lookup[args, "evidenceRefs", {}]|>|>]],
    "sourcevault_orchestrator_subtask",
      iMCPJSONText[SourceVaultMCPSubmitFeedback[<|
        "Principal" -> SourceVaultNormalizePrincipal[args], "Kind" -> "SubtaskProposal",
        "SessionId" -> Lookup[args, "sessionId", "Unknown"],
        "Payload" -> <|"Text" -> Lookup[args, "text", ""], "Goal" -> Lookup[args, "goal", Missing[]],
          "SuggestedRole" -> Lookup[args, "suggestedRole", Missing[]],
          "SuggestedCapabilities" -> Lookup[args, "suggestedCapabilities", {}],
          "EvidenceRefs" -> Lookup[args, "evidenceRefs", {}]|>|>]],
    "sourcevault_deposit",
      (* deposit は append-only write。自己の監査ログ (mcp_deposits) を持つので iSVRecordToolCall
         (mcp_calls = read 観測) には記録せず、observed-read-max を汚染しない。 *)
      iMCPJSONText[SourceVaultMCPDeposit[<|
        "mode" -> Lookup[args, "mode", "plan"],
        "title" -> Lookup[args, "title", Lookup[args, "filename", ""]],
        "content" -> With[{c = Lookup[args, "content", <||>]}, If[AssociationQ[c], c, <||>]],
        "mediaType" -> Lookup[args, "mediaType", Missing[]],
        "filename" -> Lookup[args, "filename", Missing[]],
        "provenance" -> With[{p = Lookup[args, "provenance", <||>]}, If[AssociationQ[p], p, <||>]],
        "policy" -> With[{p = Lookup[args, "policy", <||>]}, If[AssociationQ[p], p, <||>]],
        "Grant" -> With[{g = Lookup[args, "grant", None]}, If[AssociationQ[g], g, None]],
        "Principal" -> SourceVaultNormalizePrincipal[args],
        "SessionId" -> Lookup[args, "sessionId", "Unknown"],
        "BatchId" -> Lookup[args, "batchId", Missing[]],
        "idempotencyKey" -> Lookup[args, "idempotencyKey", Missing[]]|>]],
    "sourcevault_fs_list",
      Module[{o = iSVFSListDir[ToString @ Lookup[args, "path", ""]]},
        iSVRecordToolCall["sourcevault_fs_list", args, o]; iMCPJSONText[o]],
    "sourcevault_fs_read",
      Module[{o = iSVFSReadFile[ToString @ Lookup[args, "path", ""], Lookup[args, "maxBytes", Automatic]]},
        iSVRecordToolCall["sourcevault_fs_read", args, o]; iMCPJSONText[o]],
    "sourcevault_directives",
      Module[{o = iSVFSDirectivesList[Lookup[args, "kind", "all"]]},
        iSVRecordToolCall["sourcevault_directives", args, o]; iMCPJSONText[o]],
    "sourcevault_workflow_write",
      (* a write (scoped to SourceVault_workflows): not recorded via
         iSVRecordToolCall (that log = read observation / observed-read-max). *)
      Module[{o = iSVFSWriteFile[ToString @ Lookup[args, "path", ""], Lookup[args, "content", ""]]},
        iMCPJSONText[o]],
    _,
      iMCPError["Unknown tool: " <> name]
  ]];

(* ---- JSON-RPC method dispatch ---- *)
SourceVaultMCPDispatch[method_String, params_Association] := Switch[method,
  "initialize",
    <|"protocolVersion" -> SourceVault`$SourceVaultMCPProtocolVersion,
      "capabilities" -> <|"tools" -> <||>|>,
      "serverInfo" -> SourceVaultMCPServerInfo[]|>,
  "tools/list",
    <|"tools" -> SourceVaultMCPTools[]|>,
  "tools/call",
    SourceVaultMCPCallTool[Lookup[params, "name", ""],
      With[{a = Lookup[params, "arguments", <||>]}, If[AssociationQ[a], a, <||>]]],
  "ping",
    <||>,
  "notifications/initialized",
    <||>,
  _,
    Failure["MCPMethodNotFound", <|"Method" -> method|>]
];
SourceVaultMCPDispatch[method_String] := SourceVaultMCPDispatch[method, <||>];

End[]  (* `MCPPrivate` *)


(* ============================================================
   sv:// object resolution -- merged from SourceVault_objectview.wl (2026-06-21).
   NBAccess / FrontEnd independent; eagle enrichment is DownValues-guarded.
   Cell output (SourceVaultObjectToCell) lives in SourceVault_eagle.wl (FE side).
   Note: ObjectData/Properties may return Image/Dataset, but are NOT registered
   as MCP tools, so the MCP JSON-safety contract is unaffected.
   ============================================================ *)

SourceVaultObjectPrivacyLevel::usage =
  "SourceVaultObjectPrivacyLevel[uri] は sv:// オブジェクトの privacy level (0.0-1.0) を返す。\n" <>
  "snapshot は privacy サイドレコード (既定 0.85)、eagle は item の PrivacyLevel、\n" <>
  "file は 0.0 (allow-list bridge)、それ以外は既定 0.85。";

SourceVaultObjectData::usage =
  "SourceVaultObjectData[uri] は sv:// が指す実オブジェクトデータを返す。\n" <>
  "snapshot -> 検証済み assoc / eagle 画像 -> Image / eagle 他 -> <|FilePath, Item|> /\n" <>
  "file -> 内容 (text/bytes/Image)。解決できなければ Failure。";

SourceVaultObjectProperties::usage =
  "SourceVaultObjectProperties[uri] は sv:// オブジェクトの全プロパティを Association で返す。\n" <>
  "共通: URI / Namespace / Kind / PrivacyLevel / PrivacySource。\n" <>
  "eagle: Id/Name/Ext/Tags/Folders/Annotation/URL/Size/FilePath(このマシンの絶対パス)/\n" <>
  "FilePathPortable({\"$dropbox\",...} のシンボリックパス。別 PC でも解決可。FilePath が\n" <>
  "$dropbox/$onWork 等の外ならルート外を示す {\"<ABS>\",..})、画像なら ImageDimensions/\n" <>
  "FileFormat/FileByteCount、写真なら Exif、生データ EagleRaw。\n" <>
  "snapshot: スナップショット record 全フィールド + PrivacyRecord。";

Begin["`ObjectViewPrivate`"]

(* ---- 画像拡張子判定 ---- *)
iSVOVImageExtQ[ext_String] := MemberQ[
  {"jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif"},
  ToLowerCase[StringTrim[ext, "."]]];
iSVOVImageExtQ[_] := False;

(* ---- eagle がロードされているか ---- *)
iSVOVEagleAvailableQ[] :=
  Length[DownValues[SourceVault`SourceVaultEagleItem]] > 0;

(* ---- uri -> parsed (sv:// / legacy snapshot: 両対応) ---- *)
iSVOVParse[uri_String] := SourceVaultParseURI[uri];

(* ---- snapshot uri/ref -> "snapshot:class:hex" ---- *)
iSVOVSnapshotRef[parsed_Association] := Module[{segs},
  segs = Lookup[parsed, "Segments", {}];
  If[ListQ[segs] && Length[segs] === 2,
    "snapshot:" <> ToString[segs[[1]]] <> ":" <> ToString[segs[[2]]],
    $Failed]];

(* ---- eagle uri (sv://object/eagle-<id>) -> id ---- *)
iSVOVEagleId[parsed_Association] := Module[{seg},
  seg = ToString @ Lookup[parsed, "Id", ""];
  If[StringStartsQ[seg, "eagle-"], StringDrop[seg, StringLength["eagle-"]], $Failed]];

(* ============================================================
   privacy level
   ============================================================ *)
SourceVaultObjectPrivacyLevel[uri_String] := Module[{p, ns, ref, eid, item, lv},
  p = iSVOVParse[uri];
  If[! TrueQ[Lookup[p, "Valid", False]], Return[SourceVault`$SourceVaultDefaultObjectPrivacyLevel]];
  ns = Lookup[p, "Namespace", ""];
  Which[
    ns === "snapshot",
      SourceVault`SourceVaultSnapshotPrivacyLevel[uri],
    ns === "object" && StringStartsQ[ToString @ Lookup[p, "Id", ""], "eagle-"],
      eid = iSVOVEagleId[p];
      If[eid === $Failed || ! iSVOVEagleAvailableQ[],
        Return[SourceVault`$SourceVaultDefaultObjectPrivacyLevel]];
      item = Quiet @ SourceVault`SourceVaultEagleItem[eid];
      If[! AssociationQ[item], Return[SourceVault`$SourceVaultDefaultObjectPrivacyLevel]];
      lv = Quiet @ Lookup[
        If[Length[DownValues[SourceVault`SourceVaultEagleSummaryRow]] > 0,
          SourceVault`SourceVaultEagleSummaryRow[item], <||>],
        "PrivacyLevel", SourceVault`$SourceVaultDefaultObjectPrivacyLevel];
      If[NumericQ[lv], N[Clip[lv, {0.0, 1.0}]], SourceVault`$SourceVaultDefaultObjectPrivacyLevel],
    ns === "file",
      0.0,
    True,
      SourceVault`$SourceVaultDefaultObjectPrivacyLevel]];
SourceVaultObjectPrivacyLevel[_] := SourceVault`$SourceVaultDefaultObjectPrivacyLevel;

(* ---- ローカル絶対パス -> 移植可能なシンボリックパス ($dropbox 等基準) ----
   eagle がロード済みなら本家 iSVEGSymbolizePath を使う ($dropbox/$onWork 等の
   ルートに一致すれば {"$dropbox", "Eagle", ...} を返し、別 PC でも
   iSVEGResolvePathSpec で解決できる)。ルート外は {"<ABS>", 絶対パス} を返す
   (=移植不可の明示)。FilePath (絶対) はこのマシン用の live 値であり、出力を
   別環境へ持ち越すときは sv:// URI を再解決するか、この FilePathPortable を使う。 *)
iSVOVPortablePath[path_] :=
  If[StringQ[path] &&
     Length[DownValues[SourceVault`Private`iSVEGSymbolizePath]] > 0,
    Quiet @ Check[SourceVault`Private`iSVEGSymbolizePath[path], Missing["NotPortable"]],
    Missing["NoFile"]];

(* ============================================================
   実データ
   ============================================================ *)
SourceVaultObjectData[uri_String] := Module[{p, ns, ref, rec, eid, item, path, ext, fid},
  p = iSVOVParse[uri];
  If[! TrueQ[Lookup[p, "Valid", False]],
    Return[Failure["InvalidURI", <|"URI" -> uri|>]]];
  ns = Lookup[p, "Namespace", ""];
  Which[
    ns === "snapshot",
      ref = iSVOVSnapshotRef[p];
      If[ref === $Failed, Return[Failure["BadSnapshotURI", <|"URI" -> uri|>]]];
      rec = Quiet @ SourceVault`SourceVaultLoadImmutableSnapshot[ref];
      If[AssociationQ[rec], rec, Failure["SnapshotNotFound", <|"URI" -> uri|>]],
    ns === "object" && StringStartsQ[ToString @ Lookup[p, "Id", ""], "eagle-"],
      eid = iSVOVEagleId[p];
      If[eid === $Failed || ! iSVOVEagleAvailableQ[],
        Return[Failure["EagleUnavailable", <|"URI" -> uri|>]]];
      item = Quiet @ SourceVault`SourceVaultEagleItem[eid];
      If[! AssociationQ[item], Return[Failure["EagleItemNotFound", <|"Id" -> eid|>]]];
      path = Quiet @ SourceVault`SourceVaultEagleItemPath[item];
      ext = ToString @ Lookup[item, "ext", ""];
      If[StringQ[path] && iSVOVImageExtQ[ext],
        With[{img = Quiet @ Check[Import[path], $Failed]},
          If[ImageQ[img], img,
            <|"FilePath" -> path, "FilePathPortable" -> iSVOVPortablePath[path],
              "Item" -> item|>]],
        <|"FilePath" -> If[StringQ[path], path, Missing["NoFile"]],
          "FilePathPortable" -> iSVOVPortablePath[path], "Item" -> item|>],
    ns === "file",
      fid = ToString @ Lookup[p, "Id", ""];
      If[fid === "", Return[Failure["NoPath", <|"URI" -> uri|>]]];
      If[iSVOVImageExtQ[FileExtension[fid]] && FileExistsQ[fid],
        With[{img = Quiet @ Check[Import[fid], $Failed]},
          If[ImageQ[img], img, Quiet @ Check[Import[fid, "Text"], Missing["Unreadable"]]]],
        Quiet @ Check[Import[fid, "Text"], Missing["Unreadable"]]],
    True,
      Failure["UnsupportedKind", <|"URI" -> uri, "Namespace" -> ns|>]]];
SourceVaultObjectData[_] := Failure["NotAString", <||>];

(* ============================================================
   全プロパティ (連想)
   ============================================================ *)
iSVOVFileProps[path_String, level_] := Module[{ex, base},
  base = <|"FilePath" -> path, "PrivacyLevel" -> level, "PrivacySource" -> "Default",
    "FileByteCount" -> Quiet @ Check[FileByteCount[path], Missing[]],
    "FileFormat" -> Quiet @ Check[FileFormat[path], Missing[]],
    "FileDate" -> Quiet @ Check[DateString @ FileDate[path], Missing[]]|>;
  ex = FileExtension[path];
  If[iSVOVImageExtQ[ex] && FileExistsQ[path],
    base = Join[base, <|
      "ImageDimensions" -> Quiet @ Check[Import[path, "ImageSize"], Missing[]],
      "Exif" -> Quiet @ Check[Import[path, "Exif"], Missing[]]|>]];
  base];

SourceVaultObjectProperties[uri_String] := Module[
  {p, ns, ref, rec, pr, level, eid, item, path, ext, base, img},
  p = iSVOVParse[uri];
  If[! TrueQ[Lookup[p, "Valid", False]],
    Return[<|"URI" -> uri, "Valid" -> False, "Reason" -> Lookup[p, "Reason", "InvalidURI"]|>]];
  ns = Lookup[p, "Namespace", ""];
  level = SourceVaultObjectPrivacyLevel[uri];
  Which[
    ns === "snapshot",
      ref = iSVOVSnapshotRef[p];
      rec = If[ref =!= $Failed, Quiet @ SourceVault`SourceVaultLoadImmutableSnapshot[ref], $Failed];
      pr = If[ref =!= $Failed, Quiet @ SourceVault`SourceVaultSnapshotPrivacyRecord[ref], <||>];
      Join[
        <|"URI" -> uri, "Namespace" -> "snapshot", "Kind" -> "snapshot",
          "Ref" -> If[StringQ[ref], ref, Missing[]],
          "PrivacyLevel" -> level,
          "PrivacySource" -> Lookup[If[AssociationQ[pr], pr, <||>], "Source", "Default"],
          "PrivacyRecord" -> pr|>,
        If[AssociationQ[rec], KeyMap["Snapshot" <> # &, rec],
          <|"Snapshot" -> Missing["NotFound"]|>]],
    ns === "object" && StringStartsQ[ToString @ Lookup[p, "Id", ""], "eagle-"],
      eid = iSVOVEagleId[p];
      If[eid === $Failed || ! iSVOVEagleAvailableQ[],
        Return[<|"URI" -> uri, "Namespace" -> "object", "Kind" -> "eagle",
          "PrivacyLevel" -> level, "Reason" -> "EagleUnavailable", "Id" -> eid|>]];
      item = Quiet @ SourceVault`SourceVaultEagleItem[eid];
      If[! AssociationQ[item],
        Return[<|"URI" -> uri, "Namespace" -> "object", "Kind" -> "eagle",
          "PrivacyLevel" -> level, "Reason" -> "ItemNotFound", "Id" -> eid|>]];
      path = Quiet @ SourceVault`SourceVaultEagleItemPath[item];
      ext = ToString @ Lookup[item, "ext", ""];
      base = <|"URI" -> uri, "Namespace" -> "object", "Kind" -> "eagle",
        "Id" -> eid, "Name" -> Lookup[item, "name", Missing[]], "Ext" -> ext,
        "Tags" -> Lookup[item, "tags", {}], "Folders" -> Lookup[item, "folders", {}],
        "Annotation" -> Lookup[item, "annotation", Missing[]],
        "URL" -> Lookup[item, "url", Missing[]], "Size" -> Lookup[item, "size", Missing[]],
        "ModificationTime" -> Lookup[item, "modificationTime", Lookup[item, "mtime", Missing[]]],
        "FilePath" -> If[StringQ[path], path, Missing["NoFile"]],
        (* 移植可能なシンボリックパス: 別環境では FilePath(絶対) ではなくこれ
           (または sv:// URI 再解決) を使う。{"$dropbox",...} は別 PC で解決可。 *)
        "FilePathPortable" -> iSVOVPortablePath[path],
        "PrivacyLevel" -> level, "PrivacySource" -> "Default",
        "EagleRaw" -> item|>;
      If[StringQ[path] && iSVOVImageExtQ[ext],
        base = Join[base, <|
          "ImageDimensions" -> Quiet @ Check[Import[path, "ImageSize"], Missing[]],
          "FileFormat" -> Quiet @ Check[FileFormat[path], Missing[]],
          "FileByteCount" -> Quiet @ Check[FileByteCount[path], Missing[]],
          "Exif" -> If[Length[DownValues[SourceVault`SourceVaultEagleExif]] > 0,
            With[{er = Quiet @ SourceVault`SourceVaultEagleExif[item]},
              If[AssociationQ[er] && TrueQ[Lookup[er, "HasExif", False]],
                Lookup[er, "Exif", Missing[]], Missing["NoExif"]]],
            Quiet @ Check[Import[path, "Exif"], Missing[]]]|>]];
      base,
    ns === "file",
      With[{fp = ToString @ Lookup[p, "Id", ""]},
        Join[<|"URI" -> uri, "Namespace" -> "file", "Kind" -> "file"|>,
          iSVOVFileProps[fp, level]]],
    True,
      <|"URI" -> uri, "Namespace" -> ns, "Kind" -> ns,
        "PrivacyLevel" -> level, "Parsed" -> p,
        "Note" -> "properties not enriched for this namespace"|>]];
SourceVaultObjectProperties[_] := <|"Valid" -> False, "Reason" -> "NotAString"|>;

End[]  (* `ObjectViewPrivate` *)

EndPackage[]  (* SourceVault` *)
