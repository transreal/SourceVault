# SourceVault Universal MCP Access / Orchestrator Feedback 仕様 v1

作成日: 2026-06-16  
レビュー反映: 2026-06-17  
対象: `SourceVault_mcp.wl` / `SourceVault_servicemanager.wl` / SourceVault adapter 群 / ClaudeOrchestrator bridge  
前提仕様: `ドキュメント/sourcevault_searxng_mcp_spec_v6.md`

## 0. 目的

現行の MCP 実装は、SearXNG 経由の Web 検索と WebDocument 取得を SourceVault 経由で LLM に公開する。  
本仕様ではこれを拡張し、LLM が MCP 経由で SourceVault が管理する多種類のデータを安全に検索・参照できるようにする。さらに、LLM が生成した markdown / Wolfram Language file / PDF / image などを、SourceVault の管理下へ能動的に保存する append-only deposit API も定義する。

対象データは少なくとも次を含む。

- Web ingest 済みデータ
- SourceVault snapshot / claim / bundle / search index
- Mathematica notebook と cell 内容
- SourceVault mail snapshot
- Eagle item / PDF / Exif / summary
- PDFIndex legacy / native projection index
- PromptRoute / LLM 実行ログ / 将来の multimodal event
- LLM が MCP 経由で deposit した artifact / attachment / generated source

同時に、LLM から ClaudeOrchestrator 側へ feedback / help request / subtask proposal を送れる仕組みを定義する。  
ただし MCP client は外部または semi-trusted LLM であり、SourceVault data store や ClaudeOrchestrator workflow を直接操作する権限は持たない。

## 1. 基本原則

### 1.1 MCP は authority ではなく projection layer

MCP は次だけを担う。

- tool schema
- argument validation
- request provenance 付与
- adapter dispatch
- JSON 安全な応答整形
- authorization gate への問い合わせ

MVP での最終的な read / write / cloud-send 判定は、SourceVault release policy と NBAccess が担う。ClaudeOrchestrator は当面 feedback / approval proposal の受け口であり、grant/session 発行主体にはしない。将来、ClaudeOrchestrator 側に session broker / grant issuer が実装された段階で、この役割を拡張する。  
MCP endpoint は「読めたから返す」のではなく、「返してよい projection だけを返す」。

### 1.1a 能動的書き込みは append-only deposit から始める

MCP 由来の書き込みは、既存データの上書き・削除・再分類を直接許す mutation ではなく、まず append-only / create-only の deposit として定義する。

- LLM が生成した markdown / `.wl` / PDF / image / JSON などを content-addressed blob に保存する。
- その blob を参照する artifact record を immutable snapshot または append-only event として保存する。
- 作成者、投入者、モデル、セッション、入力 `ObjectRef` / `sv://` URI を provenance として記録する。
- 既存 object の privacy を下げる、AccessTags を緩める、既存 bundle を invalidate する、削除する、pointer を切り替える、といった mutation は deposit とは別扱いにし、approval / DryRun / main kernel workflow を要求する。

既存 Web 検索時の保存は passive log / ingest である。`sourcevault_deposit` は LLM が明示的に「この成果物をSourceVaultに保存したい」と要求する active write として扱う。

### 1.2 PathRef は identity であり権限ではない

`{"$onWork", ...}` などの SymbolicPath / PathRef は、検索・同一性・再リンク・表示に使ってよい。  
しかし read 権限、raw path 返却、クラウド送信可否の根拠にしてはならない。

MCP 応答には原則として raw local path を含めない。必要な場合も `ObjectRef` / `EvidenceRef` / `AccessHandle` を返し、実体 path は現 PC の authorization gate 後に内部解決する。

### 1.2a SourceVault 内外の参照は URI を正準にする

今後の SourceVault / MCP / Web / Orchestrator 間の参照は、`sv://...` URI を正準にする。既存実装の `recordId`、`snapshot:...`、`blob:...`、mail id、PDFIndex row id、Eagle item id、notebook ref、DerivedArtifact ref は残してよいが、外部 API、検索結果、関係記述、grouping、citation、prompt 内参照では URI に正規化して扱う。

基本方針:

- 検索結果は、本文や大きな構造を返す前に、まず URI の集合として返せる。
- URI は capability ではなく identity である。URI を知っていることは read 権限を意味しない。
- URI だけで object を一意特定できる。data class / file type / media type / title / search score / rank などは URI の同一性に関与しない sidecar metadata とする。
- dataset 表示や `Select` のため、`Class` / `MediaType` / `Kind` は URI と一緒に返すことを強く推奨する。ただしこれらは後付け可能な補助情報であり、canonical URI の一部ではない。
- データ間の関係、派生関係、citation、group membership、検索結果 snapshot は、local path や adapter 内部 ID ではなく URI の集合・URI 間 edge として記録する。
- 既存 API は段階的に URI を返すよう更新し、古い `ObjectRef` / `SnapshotRef` / `RecordId` は互換 field として残す。

### 1.3 入口 gate と出口 gate を分ける

MCP request は次の 2 点で判定する。

1. Request gate: その client / session / purpose / sink が、その tool と検索範囲を要求してよいか。
2. Release gate: 個々の結果 item / span / projection を応答として返してよいか。

検索結果集合を作る時点の build-time gate だけには依存しない。返却直前に request-time gate を再評価する。

### 1.4 既定は低漏洩 projection

初期実装では、MCP に返す既定 projection の上限を以下に限定する。ここに列挙した項目であっても、各 item は §2.4 の privacy 目安、実効 privacy 上限、`SourceVaultEvaluateReleasePolicy` による release gate、NBAccess decision によりさらに削減される。

- title
- kind
- source type
- date / ingest date
- summary
- short snippet
- citation / evidence ref
- privacy class の粗い表示
- access handle

本文、メール body、notebook cell text、PDF page text、Exif GPS、添付ファイル名などは明示 request と追加 gate を必要とする。

### 1.5 実装は adapter registry 方式

すべてを巨大な `SourceVaultMCPCallTool` に直書きしない。  
データ種別ごとに adapter を登録し、MCP tool は共通 SearchSpec / ReadSpec を adapter に渡す。

これにより、メール、Eagle、notebook、Web、PDFIndex、将来のデータ種別を後から追加しやすくする。

## 2. Access Model

### 2.1 Principal

MCP request の主体を `Principal` として正規化する。

```wolfram
<|
  "Kind" -> "MCPClient",
  "ClientName" -> "LM Studio" | "Claude Desktop" | "Codex" | _String,
  "ProviderClass" -> "CloudLLM" | "LocalLLM" | "PrivateLLM" | "Unknown",
  "SessionId" -> _String,
  "UserPresent" -> True | False | Missing["Unknown"]
|>
```

`ProviderClass` は privacy 判定の補助であり、単独で権限にはしない。

`ClientName` / `_mcpClient` / `ProviderClass` が tool 引数から来た場合、それは provenance 用の自己申告値に過ぎない。release 判定の入力にしてはならない。MVP では transport 層で per-client identity が確立していない限り、全 MCP client を semi-trusted、かつ最悪ケースでは cloud 相当として扱う。

Claude Code / ChatGPT Codex はローカルの file command queue や shell tool を起動できても、モデル本体への送信先は cloud/remote LLM として扱う。したがって、Claude Code / Codex を `LocalLLM` とみなして `AccessLevel -> 1.0` 相当の notebook cell 本文、mail body、Eagle 原本テキストを MCP response として返してはならない。ローカル実行権限とモデルへのデータ release 権限は別物である。

信頼できる principal は次のいずれかから導出する。

- per-client token または endpoint 分離で transport 層が確立した identity
- NBAccess が発行した AccessGrant に束縛された principal
- main kernel / Orchestrator bridge が明示的に付与した local-only session context

これらが無い場合、`ProviderClass -> "Unknown"` とし、低漏洩 projection のみ許可する。

v6 時点の transport 認証は単一 shared-secret token であり、per-client identity を持たない。そのため MVP では、transport token 保持者は同一 principal として扱う。principal の細かな区別は AccessGrant に束縛された情報でのみ表現する。per-client token や endpoint 分離は将来の transport 拡張である。

### 2.2 AccessRequest

すべての MCP tool call は内部で次の request spec に変換する。

```wolfram
<|
  "Action" -> "Search" | "ReadMetadata" | "ReadSummary" | "ReadContext" |
              "ReadBody" | "DownloadOriginal" | "SubmitFeedback" |
              "RequestHelp" | "RequestSubtask" |
              "DepositArtifact" | "ResolveObjectURI" | "CreateCitation",
  "Principal" -> principal,
  "Purpose" -> _String,
  "Sink" -> "MCPResponse" | "ClaudeOrchestrator" | "LocalOnly",
  "ReleaseContext" -> _String | None,
  "Provider" -> _String | Automatic,
  "ModelId" -> _String | Automatic,
  "ModelIntent" -> _String | Automatic,
  "AccessLevel" -> _Real | Automatic,
  "MaxPrivacyLevel" -> _Real | Automatic,
  "ScopePolicy" -> <|
    "RequireAccessTags" -> {_String ...},
    "AllowAccessTags" -> {_String ...} | All,
    "DenyAccessTags" -> {_String ...},
    "Untagged" -> "Deny" | "MetadataOnly" | "Allow"
  |>,
  "RequestedProjection" -> _String,
  "RequestedKinds" -> {_String ...},
  "SessionGrant" -> _String | None,
  "CreatedAtUTC" -> _String
|>
```

`SessionGrant` は MVP では NBAccess が発行する短命・範囲限定 token とする。ClaudeOrchestrator による grant 発行は将来拡張であり、本仕様 v1 の実装前提に含めない。  
MCP token は transport 認証であり、データ access grant ではない。

NBAccess Phase 4 の設計に合わせ、`AccessLevel` は object 側 `PrivacyLevel` ではなく、request / sink / route / model が許容する最大 risk score として扱う。object 側には `PrivacyLevel` / `BasePrivacyScore` / `AccessTags` / `PolicyLabel` があり、request 側には `AccessLevel` / `ScopePolicy` / `Sink` / `Environment` がある。`PrivacyLevel` を request の `AccessLevel` にコピーして自己参照的な許可判定にしてはならない。

`MaxPrivacyLevel` は legacy / compatibility 用の表記であり、MCP 仕様上は `AccessLevel` と同じ「request 側の上限」として正規化する。新規実装では `AccessLevel` を正準名とし、`MaxPrivacyLevel` は入力互換 alias とする。

`DepositArtifact` は append-only / create-only の保存要求であり、`ReadBody` や `DownloadOriginal` の許可を含意しない。deposit 時に入力参照として `ObjectRef` / `sv://` URI を渡す場合、それらの参照元を読み出せるかどうかは別途 `ResolveObjectURI` / `Read*` action で gate する。LLM が「参照した」と主張した URI は provenance として保存できるが、その URI の本文を再取得してよいことの証明にはならない。

### 2.3 AccessGrant

高 privacy データ、raw body、notebook cell、mail body、添付、Eagle 原本へのアクセスには AccessGrant を必要とする。

```wolfram
<|
  "GrantId" -> _String,
  "IssuedBy" -> "NBAccess",
  "Principal" -> principal,
  "AllowedActions" -> {...},
  "AllowedKinds" -> {...},
  "AllowedObjectRefs" -> All | {...},
  "MaxAccessLevel" -> _Real,
  "MaxPrivacyLevel" -> _Real | Missing["LegacyAlias"],
  "AllowedFields" -> {...},
  "Purpose" -> _String,
  "Sink" -> _String,
  "ExpiresAtUTC" -> _String,
  "RevocationEpoch" -> _Integer,
  "Digest" -> _String,
  "Signature" -> _String,
  "KeyId" -> _String
|>
```

MCP service は grant を検証するだけで、任意に grant を発行しない。  
grant が無い場合の既定は low-leak metadata / summary のみ、または Deny。

grant 検証は `SourceVault_mcp.wl` の service-loadable 制約と両立するよう、NBAccess 非依存の純 crypto で完結させる。MVP では `LocalState/secrets/sourcevault-grant-signing-key.json` に置く shared secret による HMAC を正準方式とし、NBAccess policy snapshot を service kernel にロードしない。この grant signing key は MCP transport token とは別物である。main kernel 側の grant mint と service kernel 側の grant verify は同一 key file を参照する。NBAccess は grant 発行時に必要な policy 判定を済ませ、service は署名・期限・scope・revocation epoch だけを検証する。

HMAC の実装は SourceVault 側 crypto 層を使う。grant の `Digest` / `Signature` は、署名対象 Association から `Signature` 自身を除き、`SourceVaultCanonicalJSONBytes` で決定論的バイト列に正規化してから `iSVHMACSHA256` 相当で計算する。キー順序や空白差で署名が変わらないことを要件にする。

このため Phase D で grant 検証を実装する際は、`SourceVault_crypto.wl` を service-loadable dependency として扱う。`SourceVault_servicemanager.wl` の `iGenRunWls` が生成する service package list に `SourceVault_crypto.wl` を追加する。ロード順は `SourceVault_core.wl` の後、`SourceVault_mcp.wl` より前を基本とし、既存 service loader と同じ `FileExistsQ` ガード付きパターンに合わせる。`SourceVault_info/upload_manifest.json` には `SourceVault_crypto.wl` が含まれている前提だが、`GitHubValidateManifest["SourceVault"]` で確認する。GitHub への反映は通常の `git` 操作ではなく、`github.wl` のマニフェスト駆動運用、すなわち `GitHubValidateManifest` / `GitHubRefreshAndCommit` 等で検証・反映する。

将来 ClaudeOrchestrator が grant issuer になる場合も、同じ署名形式に従い、issuer 追加は enum 拡張として扱う。

### 2.4 PrivacyLevel / AccessLevel の目安

実装上は既存 `PrivacyLevel` / `AccessLabel` / `PolicyLabel` / release context を正とする。MCP 仕様では次の目安を使う。

| Level | 意味 | MCP 既定 |
|---|---|---|
| 0.0-0.3 | public / published | summary / snippet 可 |
| >0.3-<0.5 | cloud-send 候補になり得る低機密 | summary / snippet 可、body は制限 |
| >=0.5-0.8 | private / local LLM 想定 | metadata のみ、grant で summary/context |
| >0.8-1.0 | confidential | 原則 Deny、grant と local-only sink 必須 |

この表は UI と既定値の目安であり、最終判定は release policy / NBAccess が行う。NBAccess design の原則どおり、`PrivacyLevel` は legacy / routing hint として凍結し、authorization の正本にはしない。

NBAccess 実装では `ScoreGate` / `NBRouteDecision` は routing advisory であり、permit / deny の主体ではない。MCP / Web の hard gate は、`NBAuthorize` が内部で合成する `PolicyGate` と `EnvironmentGate` を正本にする。特に cloud / local sink 境界は score 比較だけで表さず、`AccessRequest["Sink"]` / `Environment["Route"]` / `Environment["Networked"]` / principal を含む EnvironmentGate に渡す。

複数の access / privacy 上限が指定された場合、routing ceiling / request ceiling は常に最も厳しい値を使う。ただしこれは `NBAuthorize` に渡す request shaping と routing advice のための値であり、単独の hard permit 判定ではない。

```text
EffectiveAccessLevel =
  Min[NormalizeAccessLevelAliases[
      AccessRequest.AccessLevel,
      AccessRequest.MaxPrivacyLevel,
      SearchSpec.filters.accessLevelMax,
      SearchSpec.filters.privacyMax,
      ReleaseContext.MaxPrivacyLevel,
      ModelAccessProfile.MaxAccessLevel,
      EndpointAccessProfile.MaxAccessLevel,
      AccessGrant.MaxAccessLevel,
      AccessGrant.MaxPrivacyLevel]]
```

`MaxPrivacyLevel` / `privacyMax` は legacy alias として受け付けるが、正準化後は `AccessLevel` / `MaxAccessLevel` / `accessLevelMax` として 1 回だけ合成する。client 指定値で ReleaseContext や AccessGrant の上限を緩めることはできない。未指定値は `Infinity` ではなく、その層の安全側既定値として解決する。

Cloud/remote LLM sink には hard cap を置く。`Principal.ProviderClass -> "CloudLLM" | "Unknown"`、または client が Claude Code / ChatGPT Codex / Claude Desktop など cloud model へ送る経路である場合、`Sink -> "MCPResponse"` の request は `Sink -> "CloudLLM"` / `Environment["Route"] -> "CloudLLM"` / `Environment["Networked"] -> True` 相当として NBAccess EnvironmentGate に渡す。既存 NBAccess の routing threshold は `$NBRoutingThresholds["Cloud"] -> 0.5` だが、MCP / Web の外部 sink では安全側に `EffectiveRiskScore < 0.5` を cloud routing 候補の目安とし、0.5 ちょうどは cloud 自動送信候補にしない。0.5 を含めて許す必要がある legacy release context は明示 profile と監査理由を要求する。

`AccessGrant` は cloud/remote LLM sink の hard cap を緩めない。高 privacy データに対する grant は、次のどちらかに限定する。

- `Sink -> "LocalOnly"` として main kernel / local service が内部処理し、MCP response には redacted summary / metadata / referencesOnly だけを返す。
- 信頼済み local/private LLM principal に束縛し、transport と endpoint が local-only であることを NBAccess が確認した場合だけ、より高い `MaxAccessLevel` を許す。

したがって「Claude Code / Codex がローカルツールを呼べるから高 privacy grant を得やすい」という解釈は誤りである。得られるのは、ローカル側で処理したうえで cloud-safe projection だけを返すための workflow/grant であり、raw private content を Claude Code / Codex のモデル context に送る grant ではない。

### 2.5 Model / Endpoint AccessProfile

SourceVault は既に `SourceVaultSetModel[provider, intent, modelId, "ContextLength" -> n, ...]` により provider / intent / modelId と context length / integrations を compiled model registry に保存する。NBAccess 側では `NBRegisterTrustedLocalServer[<|"MachineName", "Subnet", "Provider", "URL"|>]` が trusted local endpoint を管理し、モデル名そのものは SourceVault の model registry が扱う。この分離は維持する。

MCP / Web 検索で使う release 制御は、model registry の補助情報として次の `AccessProfile` を持てるようにする。

```wolfram
<|
  "ProfileId" -> "lmstudio:extraction:qwen/qwen3.6-27b",
  "Provider" -> "lmstudio",
  "ModelIntent" -> "extraction",
  "ModelId" -> "qwen/qwen3.6-27b",
  "EndpointRef" -> "nbaccess:trusted-local-server:...",
  "TrustDomain" -> "Local" | "Private" | "Cloud" | "Unknown",
  "MaxAccessLevel" -> 1.0,
  "AllowedSinks" -> {"LocalOnly", "MCPResponse", "WebResponse"},
  "AllowedOperations" -> {"Search", "ReadSummary", "ReadContext"},
  "AllowedProjections" -> {"metadata", "summary", "snippet", "context"},
  "DeniedProjections" -> {"raw", "downloadOriginal"},
  "ScopePolicy" -> <|
    "RequireAccessTags" -> {},
    "AllowAccessTags" -> All,
    "DenyAccessTags" -> {"NoExternal", "StudentPrivate", "Personal"},
    "Untagged" -> "MetadataOnly"
  |>,
  "PurposeAllowed" -> {"Search", "RAG", "Extraction"},
  "RequireGrantFor" -> {"body", "raw", "notebookCell", "mailBody"},
  "Audit" -> <|"LogLevel" -> "DecisionOnly"|>
|>
```

公開 API 案:

```wolfram
SourceVaultSetModelAccessProfile[provider_String, intent_String, modelId_String, profile_Association]
SourceVaultGetModelAccessProfile[provider_String, intent_String, modelId_String]
SourceVaultResolveAccessProfile[request_Association]
```

または、後方互換を重視する場合は `SourceVaultSetModel` に以下の options を追加してもよい。

```wolfram
SourceVaultSetModel[
  "lmstudio", "extraction", "qwen/qwen3.6-27b",
  "ContextLength" -> 70000,
  "MCPAccessProfile" -> <|"MaxAccessLevel" -> 1.0, ...|>,
  "WebAccessProfile" -> <|"MaxAccessLevel" -> 0.49, ...|>
]
```

ただし、実装上は registry entry に巨大な policy を直書きするより、`AccessProfileRef` を保存し、profile 本体は LocalState / PrivateVault 側の policy registry に置く方が安全である。特定組織・研究テーマ・内部タグの存在自体が private metadata になり得るため、GitHub 公開対象の seed / manifest には個人環境の profile を含めない。

### 2.6 Tag / Scope Policy

タグベース制御は `AccessLevel` の代替ではない。`AccessLevel` は request / route 側の ceiling、`AccessTags` / `DenyTags` / `PolicyLabel` は PolicyGate / release policy の入力である。MCP release gate は独自の gate 代数を作らず、既存の `NBAuthorize` と SourceVault release policy を正準呼び出しにする。

```text
Permit =
  NBPermitQ[NBAuthorize(objectSpec, accessRequest)]
  AND SourceVaultEvaluateReleasePolicy(material, releaseContext)
  AND AccessTagPolicyWrapper(material.AccessTags, request.ScopePolicy)
  AND ProjectionGate(requestedProjection)
```

`NBAuthorize` 内では PolicyGate / ScoreGate / EnvironmentGate が合成されるが、hard permit / deny の正本は PolicyGate + EnvironmentGate であり、ScoreGate は NBAccess の設計どおり routing advisory として扱う。`objectSpec` の構築では、既存 `NBAuthorizeFile` / `iNBFileSpecForAuthorize` と同様に、projection key を除去し、legacy `PrivacyLevel` 由来の score field を補完する。

`AccessTagPolicyWrapper` は §17.9 の未決 API 案 `SourceVaultEvaluateAccessTagPolicy[material, profile, request]` に相当する。現行 `SourceVaultTagPolicyEvaluate[material, recipient, purpose]` は recipient / purpose 指向の message release API であり、MCP / Web request にそのまま流用しない。

`AccessTags` の例:

```text
Department:InformationEngineering
Org:FukuyamaU
Project:yyyy
Course:DataStructures
RequiresNDA
NoExternal
StudentPrivate
Personal
```

タグの意味:

- `RequireAccessTags`: material がこのタグを持つ場合だけ対象にする。検索 scope を狭める用途に使う。
- `AllowAccessTags`: request principal / profile が読めるタグ集合。`All` は trusted local/private の明示 profile でのみ許す。
- `DenyAccessTags`: 交差したら Deny。Deny wins。
- `Untagged`: scoped profile でタグ未設定 object をどう扱うか。MVP 既定は `"MetadataOnly"`、厳密な研究会/学科限定検索では `"Deny"`。

「情報工学科関連のデータに限って提供したい」場合の profile 例:

```wolfram
<|
  "MaxAccessLevel" -> 0.8,
  "ScopePolicy" -> <|
    "RequireAccessTags" -> {"Department:InformationEngineering"},
    "AllowAccessTags" -> {
      "Department:InformationEngineering",
      "Org:FukuyamaU"
    },
    "DenyAccessTags" -> {"NoExternal", "StudentPrivate", "Personal"},
    "Untagged" -> "Deny"
  |>,
  "AllowedProjections" -> {"metadata", "summary", "snippet"},
  "RequireGrantFor" -> {"body", "raw"}
|>
```

現状で実装可能な範囲:

- 暗号 record には `AccessTags` が AAD として認証されており、改ざん検出できる。
- mail / identity 系には `SourceVaultTagPolicyEvaluate` と `ContactAccessProfile` があり、Deny-wins / fail-closed の tag policy が既に存在する。
- notebook は TaggingRules / SourceVault header / snapshot metadata に tags を保存できるが、既存 notebook すべてが一貫した AccessTags を持つとは限らない。
- web ingest / Eagle / PDF / SearchIndex は、metadata tags が存在するものは scope filter できるが、AccessTags として認証済みかどうかは adapter ごとに確認が必要である。

したがって MVP では、タグが認証済みまたは SourceVault 管理 metadata として信頼できる object だけを scoped release 対象にする。タグ未設定・由来不明の object は、scope 指定時には `Untagged -> "Deny"` または `"MetadataOnly"` に落とす。これにより「タグ体系が完全に整うまで何もできない」状態を避けつつ、タグ未整備データを高 privacy で誤公開しない。

### 2.7 MCP と Web 検索での共通化

MCP と web server の検索システムは別々の access logic を持たない。両者は同じ `AccessProfile` / `ReleaseContext` / `ScopePolicy` を参照し、入口ごとの差分は `Sink` と endpoint profile で表す。

```text
MCP call:
  Principal + ModelAccessProfile + MCPEndpointProfile + ReleaseContext + Grant

Web search:
  Requester + WebServiceEndpointProfile + CapabilityProfile + ReleaseContext

Common:
  SourceVaultResolveAccessProfile
  SourceVaultEvaluateReleasePolicy
  NBAccess/NBAuthorize-compatible AccessRequest
```

Web endpoint 側では `SourceVaultRegisterWebServiceEndpoint` / `SourceVaultRegisterCapabilityProfile` の spec に次を追加する。

```wolfram
"AccessProfileRef" -> "profile:web:jouhou-public",
"MaxAccessLevel" -> 0.45,
"ScopePolicy" -> <|"RequireAccessTags" -> {"Department:InformationEngineering"}, ...|>,
"AllowedProjections" -> {"metadata", "summary", "citations"},
"DeniedProjections" -> {"raw", "mailBody", "notebookCell"}
```

Web UI からの `tags` / `unit` / `years` / `ReleaseContexts` 指定は検索 filter であり、authorization ではない。返却直前に共通 release gate を再評価する。

### 2.8 SourceVault_searchindex / RAG backend との連携

`SourceVault_searchindex.wl` は、SourceVault の検索・RAG 系 resource を管理する正準サブシステムとして扱う。MCP 側に独立した検索 DB registry を作らない。少なくとも次の既存概念を再利用する。

- `ReleaseContext`: `MaxPrivacyLevel` / `RequiredTags` / `DenyTags` / citation policy を持つ release 単位。
- `SearchBackend`: keyword / embedding / vector / OCR などの backend 登録。
- `RetrievalWorkflowSnapshot`: `"KeywordFTS"` / `"VectorRAG"` / `"HybridRAG"` / `"Cascade"` などの retrieval workflow 定義。
- `CorpusSnapshot`: 検索対象集合を immutable に固定したもの。
- `IndexSnapshot`: corpus + workflow + index artifact の immutable snapshot。
- `SourceVaultProjectionIndex`: build-time release gate 済みの projection index。
- `TPOProfile` / `PurposeIndexSpec` / `PurposeIndexSnapshot`: 目的・場所・対象話題ごとの低遅延 purpose index。

MCP の `sourcevault_search` は、`ScopePolicy` / `ReleaseContext` / `AccessProfile` から検索対象 index を解決する薄い resolver を通す。

```wolfram
SourceVaultResolveSearchIndexesForScope[searchSpec_, accessRequest_] :=
  <|
    "Decision" -> "UseIndexes" | "NoCompatibleIndex" | "RequireApproval",
    "Candidates" -> {indexCapability ...},
    "Rejected" -> {<|"IndexId" -> _, "Why" -> {...}|> ...},
    "Fallback" -> "SourceVaultSearch" | "AdapterSearch" | "MetadataOnly" | "Deny"
  |>
```

`indexCapability` は少なくとも次を持つ。

```wolfram
<|
  "IndexId" -> _String,
  "IndexRef" -> "snapshot:..." | _String,
  "IndexKind" -> "ProjectionIndex" | "PurposeIndex" | "VectorRAG" |
                 "HybridRAG" | "ExternalRegistered",
  "ReleaseContextRefs" -> {_String ...},
  "CorpusSnapshotRef" -> _String | Missing[],
  "WorkflowSnapshotRef" -> _String | Missing[],
  "TPOProfileRef" -> _String | Missing[],
  "PurposeIndexId" -> _String | Missing[],
  "AllowedMethods" -> {"keyword" | "semantic" | "hybrid" ...},
  "ScopePolicy" -> _Association,
  "RequiredAccessTags" -> {_String ...},
  "DenyAccessTags" -> {_String ...},
  "MaxAccessLevel" -> _Real,
  "SupportsCertifiedPostFilter" -> True | False,
  "State" -> "Active" | "Staged" | "Deprecated",
  "HumanReviewed" -> True | False,
  "ValidatedAtUTC" -> _String | Missing[]
|>
```

resolver の選択規則:

1. 明示 `SearchSpec.indexRefs` / AccessProfile の `SearchIndexPolicy.AllowedIndexRefs` / `ReleaseContext` / `TPOProfileRef` から候補 index を集める。
2. `SourceVaultValidateIndexSnapshot`、`SourceVaultPurposeIndexStatus`、`SourceVaultSearchIndexStatus` 相当で snapshot / active pointer / corpus / workflow の整合性を確認する。
3. index の `ReleaseContextRefs` は request の `ReleaseContext` と一致またはより厳しいものだけを許可する。より緩い release context で構築された index を、狭い request scope に流用してはならない。
4. index scope は request `ScopePolicy` より広くてはならない。広い index を使えるのは、各 chunk が認証済み `AccessTags` / `PrivacyLevel` / `SourceVaultObjectId` を保持し、backend が certified post-filter を保証する場合だけである。vector DB / embedding backend が post-filter を保証できない場合は `NoCompatibleIndex` とする。
5. `DenyAccessTags` は deny-wins。index の corpus または workflow が request の deny tag と交差する場合は候補から外す。
6. 検索結果は index build-time gate を通っていても、返却直前に `NBAuthorize` + `SourceVaultEvaluateReleasePolicy` + `AccessTagPolicyWrapper` を request-time に再評価する。

「情報工学科関連のデータに限って提供したい」profile は、ScopePolicy だけでなく、検索 index の選択 policy も持つ。

```wolfram
<|
  "ProfileId" -> "profile:mcp:ie-department",
  "MaxAccessLevel" -> 0.49,
  "ScopePolicy" -> <|
    "RequireAccessTags" -> {"Department:InformationEngineering"},
    "AllowAccessTags" -> {"Department:InformationEngineering", "Org:FukuyamaU"},
    "DenyAccessTags" -> {"NoExternal", "StudentPrivate", "Personal"},
    "Untagged" -> "Deny"
  |>,
  "SearchIndexPolicy" -> <|
    "AllowedIndexRefs" -> {
      "svpurposeindex:ie-department:*",
      "ie-department-public-proj",
      "snapshot:SourceVaultPurposeIndexSnapshot:..."
    },
    "RequireIndexScopeTags" -> {"Department:InformationEngineering"},
    "AllowedMethods" -> {"keyword", "semantic", "hybrid"},
    "AllowBroaderIndexWithPostFilter" -> False,
    "RequireHumanReviewedCorpus" -> True,
    "Fallback" -> "MetadataOnly"
  |>
|>
```

多数の data group 専用 RAG / vector DB / purpose index を追加する場合も、それぞれを `SearchBackend` + `RetrievalWorkflowSnapshot` + `CorpusSnapshot` + `IndexSnapshot` または `PurposeIndexSnapshot` として登録する。MCP / Web はそれらを直接信用せず、`SourceVaultResolveSearchIndexesForScope` で scope-compatible な index だけを選び、結果ごとに release gate を再評価する。これにより「検索DBを増やすほど漏洩経路が増える」状態を避け、profile が指定した提供範囲を検索 backend 選択にも反映できる。

index 名、corpus 名、workflow 名も私的 metadata になり得る。`sourcevault_catalog` が返す index 一覧は、その principal / AccessProfile に見せてよい indexCapability のみとし、拒否された index の詳細名は既定では返さない。必要な場合は `RejectedIndexes` に粗い理由だけを返す。

## 3. ObjectRef / SpanRef

### 3.1 SourceVault URI / ObjectRef

MCP から指定可能な対象は raw path ではなく SourceVault URI とする。`ObjectRef` は既存実装との互換名として残すが、外部 API では `URI` / `ObjectURI` を正準名にする。

文字列表現:

```text
sv://object/<opaqueObjectId>
sv://chunk/<opaqueChunkId>
sv://artifact/<artifactId>
sv://hash/sha256/<hex64>
sv://group/<groupKind>/<groupId>
sv://relation/<relationId>
sv://snapshot/<class>/<hex64>
sv://record/<recordId>
sv://citation/<citationId>
```

第 1 segment は identity namespace として固定 dispatch する。`object` / `chunk` / `artifact` / `hash` / `group` / `relation` / `snapshot` / `record` / `citation` を予約する。`mail` / `web` / `image` / `pdf` / `text` / `notebook` などの data class や file type は URI grammar の正本にしない。必要な場合は解決後 metadata の `Class` / `MediaType` / `Kind` / `Adapter` field として持つ。これにより同一 object が `sv://pdf/...` と `sv://web/...` のような複数 canonical URI に分裂することを避ける。

既存 core の `blob:sha256:<hex64>` / `snapshot:<class>:<hex64>` は内部 ref として維持する。MCP や prompt に出す URI は `sv://...` 形式を正準にし、内部 ref は `sourcevault_resolve_uri` で解決する。`sv://hash/sha256/<hex64>` は content-addressed identity として便利だが、高 privacy object では hash の露出自体が同一性リークになり得る。その場合は `sv://object/<opaqueObjectId>` または `sv://artifact/<artifactId>` を外部表示の正準 URI とし、hash は access gate 後の metadata projection に限って返す。

`<id>` 部分は URI path として percent-encoding する。adapter 内部 ID が `/`, `#`, `?`, `:`, whitespace などを含み得る場合、MCP へ出す ObjectRef では opaque id に変換する。高 privacy adapter では raw `recordId` をそのまま露出せず、必要に応じて session-bound handle 経由でのみ解決できる opaque id を使う。

#### 3.1.1 Canonical URI

URI を key / edge / group member / SourceRef として保存する前に、必ず canonical URI に正規化する。正規化の唯一の入口は `sourcevault_resolve_uri` / `SourceVaultResolveURI` / adapter hook `SourceVaultURIForObject` とする。各 adapter が独自に URI 文字列を組み立てて永続化してはならない。

```wolfram
SourceVaultCanonicalURI[uri_String, accessRequest_: Automatic] :=
  SourceVaultResolveURI[uri, "Return" -> "CanonicalURI", "AccessRequest" -> accessRequest]

SourceVaultURIForObject[objectOrInternalId_, opts___] :=
  (* adapter registry 経由で canonical URI を返す *)
```

解決結果は少なくとも次を持つ。

```wolfram
<|
  "CanonicalURI" -> "sv://...",
  "AlternateURIs" -> {"sv://...", "snapshot:...", "blob:sha256:..." ...},
  "Class" -> _String,
  "Kind" -> _String,
  "Adapter" -> _String | Missing[],
  "InternalStableId" -> _String | Missing[],
  "ObjectSnapshotRef" -> _String | Missing[],
  "ContentHash" -> _String | Missing[],
  "ResolutionConfidence" -> "Exact" | "Alias" | "Ambiguous" | "NotFound"
|>
```

canonical URI は object ごとに 1 つを目標にする。document と chunk のように粒度が異なる場合は、同一 object ではなく `sv://object/...` と `sv://chunk/...` の関係として扱い、`SourceVaultRelation` (`contains` / `partOf`) で結ぶ。`sv://snapshot/...` / `sv://record/...` / `blob:sha256:...` / data-class 由来の legacy URI は内部 ref または alternate URI であり、外部 relation / group の正本 key にする前に canonical URI へ正規化する。

ObjectRef は identifier であり capability ではない。bare ObjectRef で許可できるのは原則 `metadata` または公開済み `summary` の範囲に限る。`mail` / `notebook` / Eagle 原本 / body / context など高 privacy kind の読み出しには、同一 session 由来の `AccessHandle` または NBAccess 発行 `AccessGrant` を必須とする。

`sv://` URI も同じく identifier であり capability ではない。LLM prompt 内に `sv://object/...` / `sv://artifact/...` / legacy alternate URI が含まれる場合、LLM は内容を推測してはならず、MCP の `sourcevault_resolve_uri` / `sourcevault_get` で明示的に解決する。アクセス不可の場合は、metadata-only の範囲で応答するか、`sourcevault_request_access` を案内する。

既存実装の更新方針:

- `SourceVaultSearch` / `sourcevault_search` は各 result に `URI` を必ず付ける。`ObjectRef` は同値の互換 alias とする。
- `SourceVaultDerivedArtifact` / `SourceVaultSaveDerivedArtifact` は `CanonicalURI` と `SourceRefs` の URI 正規化を持つ。
- `SourceVaultFreezeCorpusSnapshot` / `SourceVaultBuildIndexSnapshot` / purpose index 系の item は、既存互換のため `SourceVaultObjectId` / `ContentHash` を内部安定 key として維持する。`SourceVaultObjectURI` は canonical URI の併存 field として追加し、relation / group / MCP response ではこちらを使う。
- mail / web / Eagle / notebook / PDFIndex legacy adapter は内部 ID を URI に変換する `SourceVaultURIForObject` 相当の adapter hook を持つ。

`SourceVaultObjectId` から `SourceVaultObjectURI` への単純置換は、既存 `CorpusSnapshot` / `IndexSnapshot` の digest と差分計算を変えるため行わない。URI を corpus key に昇格する場合は、明示 migration version を切り、既存 snapshot を再 freeze / 再 index する。

内部表現:

```wolfram
<|
  "Scheme" -> "sv",
  "Namespace" -> "object" | "chunk" | "artifact" | "hash" |
                 "group" | "relation" | "snapshot" | "record" | "citation",
  "Class" -> "mail" | "web" | "image" | "pdf" | "text" |
             "notebook" | "artifact" | "search" | "group" | "relation" |
             Missing["Unknown"],
  "MediaType" -> _String | Missing[],
  "Adapter" -> "web" | "mail" | "eagle" | "notebook" | "search" | _String,
  "Kind" -> _String,
  "Id" -> _String,
  "Version" -> Automatic | _String,
  "PathRef" -> Missing["NotExposed"] | _Association
|>
```

### 3.2 SpanRef

特定範囲の読み出しは `SpanRef` とする。

```wolfram
<|
  "ObjectRef" -> objectRef,
  "Selector" -> <|
    "Pages" -> {1, 2},
    "Cells" -> {3, 4},
    "CharRange" -> {1, 2000},
    "Fields" -> {"Summary", "Title"}
  |>
|>
```

adapter は自分が理解できる selector だけを受け付け、未知 selector は fail-closed にする。

### 3.3 URISet / Relation / Group

検索結果、RAG corpus、手動 selection、bundle、derived artifact の入力集合は、URI の集合として記録する。
`Items[*].URI` は保存前に `SourceVaultCanonicalURI` で正規化済みでなければならない。未解決 / ambiguous な URI は group に入れず、`RejectedItems` に理由を残す。

```wolfram
<|
  "ObjectClass" -> "SourceVaultURISet",
  "URISetId" -> _String,
  "CanonicalURI" -> "sv://group/uriset/...",
  "Items" -> {
    <|"URI" -> "sv://object/...", "Class" -> "pdf" | "mail" | _String,
      "MediaType" -> _String | Missing[],
      "Role" -> "Result" | "Source" | "Citation",
      "Rank" -> _Integer | Missing[], "Score" -> _Real | Missing[]|>
  },
  "CreatedAtUTC" -> _String,
  "Policy" -> <|"ReleaseContext" -> _String | None, "ScopePolicy" -> _Association|>,
  "Provenance" -> <|"Query" -> _String | Missing[], "Tool" -> _String, "SessionId" -> _String|>
|>
```

データ間の関係は URI 間 edge として記録する。adapter 内部 ID、local path、raw hash を relation の正本にしない。
`SubjectURI` / `ObjectURI` は canonical URI に正規化してから保存する。alternate URI は必要なら provenance に残すが、edge key には使わない。

```wolfram
<|
  "ObjectClass" -> "SourceVaultRelation",
  "RelationId" -> _String,
  "CanonicalURI" -> "sv://relation/...",
  "SubjectURI" -> "sv://...",
  "Predicate" -> "derivedFrom" | "cites" | "summarizes" | "contains" |
                 "memberOf" | "duplicates" | "supersedes" | _String,
  "ObjectURI" -> "sv://...",
  "Confidence" -> _Real | Missing[],
  "Provenance" -> _Association,
  "Policy" -> _Association
|>
```

グルーピングは `sv://group/<groupKind>/<groupId>` として表す。例:

- `sv://group/search-resultset/<id>`: ある検索実行の結果集合 snapshot
- `sv://group/corpus/<corpusId>`: RAG corpus / CorpusSnapshot
- `sv://group/bundle/<bundleId>`: evidence bundle
- `sv://group/collection/<id>`: 手動または workflow による任意 collection

group の member はすべて URI で表す。group 自体も URI なので、別 group の member や citation にできる。

### 3.4 SearchResultSet Snapshot

`sourcevault_search` は通常の `SearchResult` list だけでなく、URI 集合だけの軽量応答、または検索結果集合の immutable snapshot を返せる。

```wolfram
<|
  "ObjectClass" -> "SourceVaultSearchResultSet",
  "ResultSetId" -> _String,
  "CanonicalURI" -> "sv://group/search-resultset/...",
  "Query" -> _String,
  "SearchSpecDigest" -> "sha256:...",
  "AccessProfileRef" -> _String | Missing[],
  "ReleaseContext" -> _String | None,
  "IndexRefs" -> {_String ...},
  "ResultURIs" -> {"sv://..." ...},
  "Results" -> {SearchResultSummary ...},
  "CreatedAtUTC" -> _String,
  "PolicyDigestAtSearch" -> _String | Missing[],
  "RevocationEpoch" -> _Integer | Missing[]
|>
```

`ResultURIs` は canonical URI の順序付き配列であり、result ordering を保持する。検索 adapter が返した URI は snapshot 保存前に `SourceVaultCanonicalURI` で正規化する。再利用時は snapshot に含まれる `Results` をそのまま信じず、URI ごとに request-time gate を再評価する。検索結果 snapshot は「その時点で何が候補だったか」を再現する provenance であり、将来の read 許可を保証しない。

## 4. Adapter Registry

### 4.1 登録 API 案

将来実装する共通 API。

```wolfram
SourceVaultRegisterMCPDataAdapter[name_String, spec_Association]
SourceVaultListMCPDataAdapters[]
SourceVaultResolveMCPDataAdapter[name_String]
```

`spec` は以下を持つ。

```wolfram
<|
  "Name" -> _String,
  "Kinds" -> {_String ...},
  "Capabilities" -> <|
    "Search" -> True | False,
    "ReadMetadata" -> True | False,
    "ReadSummary" -> True | False,
    "ReadContext" -> True | False,
    "ReadBody" -> True | False,
    "DepositArtifact" -> True | False,
    "ResolveObjectURI" -> True | False,
    "SemanticSearch" -> True | False,
    "MetadataFilter" -> True | False,
    "IndexAwareSearch" -> True | False,
    "PurposeIndexSearch" -> True | False
  |>,
  "Search" -> Function[{searchSpec, accessRequest}, ...],
  "URIForObject" -> Function[{objectOrInternalId}, "sv://..."],
  "ResolveURI" -> Function[{uri, accessRequest}, <|"CanonicalURI" -> "sv://...", ...|>],
  "Resolve" -> Function[{objectRefOrURI, accessRequest}, ...],
  "Read" -> Function[{readSpec, accessRequest}, ...],
  "SummaryRow" -> Function[{object, accessRequest}, ...],
  "Metadata" -> Function[{object, accessRequest}, ...],
  "Authorize" -> Automatic | Function[{objectSpec, accessRequest}, ...]
|>
```

### 4.2 初期 adapter

| Adapter | 初期実装 | 備考 |
|---|---|---|
| `web` | 既存 `SourceVaultWebSearch` / WebDocument snapshot | v6 実装を維持 |
| `search` | `SourceVaultSearch` | release context 必須、raw path 非漏洩 |
| `eagle` | `SourceVaultEagleSummaryRow` / `SourceVaultEagleSearch` | 初期は summary/metadata 中心 |
| `mail` | `SourceVaultMailSearchSummary` / `SourceVaultMailSummaryRow` | body は grant 必須 |
| `notebook` | `SourceVaultIndexNotebook` / NBAccess semantic API | cell text は NBAccess gate 必須 |
| `artifact` | `SourceVaultSaveDerivedArtifact` / `SourceVaultCommitBlob` / DerivedArtifact snapshot | Phase G で deposit / resolve URI |

`mail` と `notebook` は NBAccess 依存が強いため、headless service で常時有効にしない。  
初期実装では adapter status を `UnavailableWithoutGrant` または `MainKernelOnly` として返し、grant / policy snapshot がない環境では検索対象から除外する。

## 5. SearchSpec

### 5.1 共通 schema

MCP tool `sourcevault_search` は次を受け取る。

```json
{
  "query": "string",
  "kinds": ["web", "mail", "eagle", "notebook", "pdf", "artifact", "all"],
  "scope": {
    "releaseContext": "pub",
    "topicTags": ["..."],
    "objectRefs": ["sv://..."],
    "requireAccessTags": ["Department:InformationEngineering"],
    "denyAccessTags": ["NoExternal", "StudentPrivate"],
    "untagged": "Deny"
  },
  "targetFields": ["title", "metadata", "summary", "body"],
  "methods": ["keyword", "metadata", "semantic", "hybrid"],
  "indexRefs": ["ie-department-public-proj", "snapshot:SourceVaultPurposeIndexSnapshot:..."],
  "indexPolicy": {
    "preferPurposeIndex": true,
    "allowBroaderIndexWithPostFilter": false,
    "requireHumanReviewedCorpus": true
  },
  "filters": {
    "dateFrom": "YYYY-MM-DD",
    "dateTo": "YYYY-MM-DD",
    "ingestedFrom": "YYYY-MM-DD",
    "ingestedTo": "YYYY-MM-DD",
    "ext": "pdf",
    "tags": ["..."],
    "hasAttachment": true,
    "accessLevelMax": 0.49,
    "privacyMax": 0.5
  },
  "limit": 20,
  "offset": 0,
  "sortBy": "score",
  "return": {
    "format": "compactText",
    "uriMode": "include",
    "persistResultSet": false,
    "includeSnippets": true,
    "includeMetadata": true,
    "maxCharsPerResult": 800
  },
  "purpose": "answer-user-question",
  "sessionGrant": null
}
```

`kinds` に `"all"` が含まれる場合、個別 kind 指定は無視し、`sourcevault_catalog` が `available -> true` かつ request gate を通した adapter 全体を対象にする。`"all"` と明示除外を同時に表したい場合は将来 `excludeKinds` を追加する。MVP では `excludeKinds` は定義しない。

`scope.requireAccessTags` / `scope.denyAccessTags` は検索集合を狭める希望条件であり、それだけでは authorization にならない。request gate では `AccessProfile.ScopePolicy` と合成し、release gate では result ごとの `AccessTags` / `DenyTags` / `PolicyLabel` を再評価する。

`filters.accessLevelMax` は client 側の希望上限であり、release context / grant / model profile / endpoint profile の上限を緩めない。`filters.privacyMax` は入力互換 alias として受け付けるが、正規化後は `accessLevelMax` として扱う。§2.4 の `EffectiveAccessLevel` により最小値として合成する。

`return.uriMode`:

| Mode | 意味 |
|---|---|
| `include` | 通常の SearchResult に `URI` を必ず含める |
| `only` | URI と低漏洩 class / title だけ返す |
| `resultSet` | `SourceVaultSearchResultSet` snapshot を作り、その URI を返す |

`return.persistResultSet -> true` の場合、検索結果集合を `sv://group/search-resultset/...` として SourceVault に保存する。保存されるのは URI と低漏洩 metadata / search provenance であり、後続 read では URI ごとに access gate を再評価する。

### 5.2 methods

| Method | 意味 | 初期対応 |
|---|---|---|
| `keyword` | 部分一致 / FTS / bigram | 必須 |
| `metadata` | 日付・拡張子・タグ・サイズ・Exif 等 | 必須 |
| `semantic` | vector DB / embedding 類似検索 | optional |
| `hybrid` | keyword + semantic + metadata rank | 将来 |

初期実装は `keyword` + `metadata` でよい。  
`semantic` 指定時に backend 未登録なら、`Capabilities.SemanticSearch -> False` を結果 metadata に出し、keyword fallback したか fail したかを明示する。

`indexRefs` は使用したい index の希望であり、authorization ではない。service は §2.8 の `SourceVaultResolveSearchIndexesForScope` で `ReleaseContext` / `ScopePolicy` / AccessProfile / `SearchIndexPolicy` と照合し、互換性のある `SourceVault_searchindex.wl` 管理下の index だけを使う。指定 index が request scope より広い、未検証、human review 不足、または certified post-filter を持たない場合は、`RejectedIndexes` に理由を入れ、`indexPolicy` / AccessProfile の fallback に従う。

### 5.3 targetFields

| Field | 対象 | 備考 |
|---|---|---|
| `title` | title / subject / notebook title / Eagle name | 低漏洩 |
| `metadata` | ingest date, size, ext, tags, Exif summary | フィールド別 gate |
| `summary` | LLM summary / derived summary | summary 自体の PrivacyLevel を持つ |
| `body` | 本文 / cell text / mail body / PDF page text | grant 必須 |

`targetFields` は検索対象であり、返却対象ではない。返却は `return` と release gate で決まる。

## 6. SearchResult

MCP の構造化結果は次の schema に正規化する。

```wolfram
<|
  "ResultId" -> _String,
  "URI" -> "sv://...",
  "ObjectRef" -> "sv://...",  (* compatibility alias of URI *)
  "Class" -> "mail" | "web" | "image" | "pdf" | "text" |
             "notebook" | "artifact" | "search" | "group" | _String,
  "MediaType" -> _String | Missing[],
  "Adapter" -> _String,
  "Kind" -> _String,
  "Title" -> _String,
  "Summary" -> _String | Missing["NotReleased"],
  "Snippet" -> _String | Missing["NotReleased"],
  "Citation" -> _Association,
  "Score" -> _Real | Missing["NotScored"],
  "MatchedFields" -> {_String ...},
  "Metadata" -> _Association,
  "Index" -> <|
    "IndexId" -> _String | Missing["AdapterSearch"],
    "IndexRef" -> _String | Missing[],
    "IndexKind" -> _String | Missing[],
    "CorpusSnapshotRef" -> _String | Missing[],
    "WorkflowSnapshotRef" -> _String | Missing[],
    "ScopeCompatible" -> True | False | Missing[]
  |>,
  "Privacy" -> <|
    "Level" -> _Real | Missing["Hidden"],
    "Class" -> "Public" | "Private" | "Confidential" | "Mixed",
    "ReleasedProjection" -> _String
  |>,
  "Access" -> <|
    "Decision" -> "Permit" | "Screen" | "RequireApproval" | "Deny",
    "Why" -> {...},
    "AccessHandle" -> _String | None
  |>,
  "Provenance" -> <|
    "RequestTimeGateReevaluated" -> True,
    "PolicyDigestAtRequest" -> _String | Missing[],
    "SearchIndexResolverDecision" -> _Association | Missing[]
  |>
|>
```

`URI` だけが identity の正本であり、`Class` / `MediaType` / `Kind` / `Title` / `Score` / `MatchedFields` / `Snippet` は sidecar metadata である。Dataset 表示や `Select[results, #Class == "pdf" &]` のため `Class` / `MediaType` / `Kind` の付与を推奨するが、これらを変えても canonical URI は変わらない。

`AccessHandle` は同一 session 内で `sourcevault_get` / `sourcevault_context` に渡す短命 handle。  
handle は objectRef と projection scope に束縛され、別 object や raw body へ昇格できない。

JSON 応答では `Missing["NotReleased"]` などの理由を単純な `null` に潰さず、可能な限り `OmittedFields` / `RedactionReasons` / `ReleasedProjection` に明示する。値自体は `null` でもよいが、「存在しない」と「privacy により非開示」を区別できる metadata を必ず添える。

## 7. ReadSpec

### 7.1 MCP tool `sourcevault_get`

特定 data を指定して読み出す。

```json
{
  "uri": "sv://object/...",
  "objectRef": "sv://object/...",
  "view": "metadata",
  "fields": ["title", "summary", "date", "tags"],
  "maxChars": 4000,
  "accessHandle": "optional-for-metadata-only",
  "sessionGrant": "optional-for-metadata-only",
  "purpose": "inspect-search-result"
}
```

`uri` を正準入力名にする。`objectRef` は互換 alias として受け付け、内部で `SourceVaultCanonicalURI` に正規化する。

`view`:

| View | 内容 | 初期許可 |
|---|---|---|
| `metadata` | title/date/size/tags 等 | 低漏洩 |
| `summary` | 保存済み summary | privacy gate |
| `snippet` | 検索一致周辺 | privacy gate |
| `context` | LLM context 用抜粋 | grant または release context |
| `body` | 本文 | grant 必須 |
| `raw` | 原本 / 添付 / raw fetch handle | MCP 既定 Deny |

`accessHandle` / `sessionGrant` が無い bare ObjectRef 直接読み出しは、`metadata` と公開可能な `summary` に限る。`context` / `body` / `raw`、および high privacy kind は handle/grant なしでは Deny する。`raw` view は grant があっても raw local path を返さず、main kernel でしか解決できない fetch handle または approval request を返す。

### 7.2 MCP tool `sourcevault_context`

RAG / 引用用に span を組み立てる。`SourceVaultContext` / `SourceVaultContextAssemble` に近いが、MCP 用に release gate と truncation を標準化する。

```json
{
  "spans": [
    {"uri": "sv://chunk/...", "selector": {"pages": [3, 4]}},
    {"uri": "sv://object/...", "selector": {"cells": [10, 11]}}
  ],
  "maxChars": 8000,
  "format": "evidenceText",
  "sessionGrant": "optional",
  "purpose": "answer-with-citations"
}
```

戻り値は source ごとに citation と released projection を持つ。
`objectRef` は `uri` の互換 alias として受け付ける。

## 8. Return Format

### 8.1 compactText

LLM がそのまま読みやすい既定形式。  
各結果は 1 件あたり title / snippet / citation / URI / access hint を含む。`objectRef` は互換 alias として含めてもよい。

### 8.2 structuredJson

tool chaining 用。`SearchResult` / `ReadResult` Association を JSON 安全化して返す。

### 8.3 evidenceText

引用付き context。本文や snippet を含む場合は、各 block に `ObjectRef` / `Citation` / `ReleasedProjection` を付ける。

### 8.4 referencesOnly

データ本文を返さず、URI と citation だけ返す。  
privacy が高い環境や、まず人間に候補だけ見せる場合の既定 fallback。

### 8.5 uriList

検索結果を順序付き URI 配列として返す。

```json
{
  "uris": ["sv://object/...", "sv://object/..."],
  "classes": ["pdf", "mail"],
  "mediaTypes": ["application/pdf", "message/rfc822"],
  "resultSetUri": null
}
```

LLM がまず候補集合だけを持ち、必要な URI だけ `sourcevault_get` / `sourcevault_context` で解決する用途に使う。

### 8.6 uriSet

検索結果集合を `SourceVaultSearchResultSet` として保存し、`sv://group/search-resultset/...` を返す。大量検索、複数LLM間の handoff、後続の human review / rerank / bundle 作成に使う。

## 9. MCP Tool Set

### 9.1 既存 tool

既存 tool はそのまま維持する。

- `sourcevault_web_search`
- `sourcevault_submit_web_search`
- `sourcevault_job_status`
- `sourcevault_job_result`
- `sourcevault_get_document`

ただし `sourcevault_get_document` は将来 `sourcevault_get` の `view -> "metadata"` 互換 wrapper とする。
後方互換のため、現行 `sourcevault_get_document` が返す `Url` / `Title` / `ContentHash` / `CleanTextLength` / `ExtractionStatus` は `sourcevault_get view -> "metadata"` の返却フィールドに含める。

### 9.2 新規 tool surface

| Tool | Phase | 役割 |
|---|---|---|
| `sourcevault_catalog` | A | 利用可能 adapter / kind / capability / policy status を返す |
| `sourcevault_search` | B | 横断検索 |
| `sourcevault_get` | C | objectRef 指定読み出し |
| `sourcevault_context` | C | span 指定 context assembly |
| `sourcevault_explain_access` | D | なぜ Permit/Deny/RequireApproval かを説明 |
| `sourcevault_request_access` | D | NBAccess/main kernel に access grant を申請 |
| `sourcevault_access_status` | D | access request の Pending/Granted/Denied/Expired を poll |
| `sourcevault_resolve_uri` | G | `sv://...` URI を metadata / access decision / internal ref に解決 |
| `sourcevault_deposit` | G | LLM 生成 artifact を append-only / create-only で保存 |

`sourcevault_catalog` は LLM に「今どのデータに何ができるか」を教えるための重要 tool。  
実装初期は `mail` / `notebook` が unavailable でも、その理由を返す。

tool surface が肥大すると小型ローカル LLM の tool 選択精度が落ちるため、Phase A/B の実装対象は `sourcevault_catalog` / `sourcevault_search` / `sourcevault_get` の 3 本を優先する。`sourcevault_context` と `sourcevault_explain_access` は Phase C/D で追加し、active write は Phase G の `sourcevault_resolve_uri` / `sourcevault_deposit` まで遅らせる。さらに tool 数が問題になる場合は、`sourcevault` 単一 tool + `action -> "search"|"get"|"context"|"resolve_uri"|"deposit"` に束ねる代替設計を許容する。

### 9.3 将来 tool

| Tool | 役割 |
|---|---|
| `sourcevault_create_bundle` | 検索結果から evidence bundle 案を作る |
| `sourcevault_summarize_selection` | grant 済み範囲の local summary |
| `sourcevault_vector_search` | 明示的な semantic search |
| `sourcevault_create_citation` | `sv://` URI から citation card / bibliography entry を作る |

破壊的 mutation / 既存 object 更新系は MVP では入れない。append-only deposit は Phase G で導入できるが、既存 object の上書き、削除、privacy 緩和、bundle invalidate、pointer 更新は DryRun 既定、approval 必須、`Claude Directives/rules/103-sourcevault-datastore-safety.md` のデータストア書き込み安全規約に準拠する。

## 10. データ種別別のアクセス方式

### 10.1 WebDocument

既存 v6 の実装を基礎にする。

- search: `SourceVaultWebSearch`
- async search/fetch: `SourceVaultWebSearchSubmit`
- read metadata: immutable snapshot
- read body/context: clean-text blob ref 経由、非 2xx fetch は失敗扱い
- privacy: Web 由来でも private annotation / derived summary が混ざる場合は summary 側の privacy を優先

### 10.2 SearchIndex / PDFIndex

`SourceVault_searchindex.wl` の `SourceVaultSearch` / `SourceVaultBuildProjectionIndex` / `SourceVaultBuildPurposeIndex` / `SourceVaultSelectPurposeIndex` を正準にする。

- release context 必須
- raw path 非返却
- request-time gate 再評価
- citation / evidence ref を返す
- `CorpusSnapshot` / `IndexSnapshot` / `PurposeIndexSnapshot` は immutable ref として扱う
- index 選択は §2.8 の `SourceVaultResolveSearchIndexesForScope` を通す
- profile scope より広い index は、certified post-filter が無い限り使わない

MCP では `kind -> "pdf"` または `adapter -> "search"` として見せる。
v6 で構想されていた `sourcevault_search_evidence` は未実装のため、新設 `sourcevault_search` に集約する。

### 10.3 Eagle

初期は `SourceVaultEagleSummaryRow` 互換の低漏洩 row を返す。

検索対象:

- name/title
- annotation
- tags/folders
- URL
- summary/note
- Exif index の公開可能フィールド

本文抽出 `SourceVaultEagleExtractText` は `view -> "context"` または `"body"` 扱いで、grant 必須。  
GPS / camera / thumbnail / original path は field ごとに gate する。

### 10.4 Mail

初期は `SourceVaultMailSearchSummary` / `SourceVaultMailSummaryRow` の範囲に限定する。

検索対象:

- subject
- public metadata
- derived summary
- category / deadline / priority
- date / mbox / attachment count

本文復号 `SourceVaultMailGetBody`、添付、返信 draft は grant 必須。  
MCP へメール本文を返す場合は `Sink -> "MCPResponse"` と信頼済み principal を必ず判定する。transport 層または grant で principal を信頼できない場合、ProviderClass の自己申告に関わらず Deny または redacted summary のみにする。

### 10.5 Notebook / Cell

Notebook は SourceVault notebook source と NBAccess semantic API を組み合わせる。

検索対象:

- notebook header
- todo metadata
- indexed summary
- cell style / tags
- low privacy cell text

cell text は `NBFileReadCells` 相当の PrivacySpec filtering を通す。  
`NBFileReadAllCells` 相当の全セル読みは local-only grant 必須。  
MCP service が NBAccess をロードできない場合、notebook adapter は `RequiresMainKernelGrant` を返す。

### 10.6 Derived Artifacts / Claims / Bundles

claim / bundle は SourceVault 内部の evidence として扱う。

- claim search: topic / schema / source / content hash / validation status
- bundle search: bundle id / status / dependency source / stale state
- read: summary と dependency graph は可、claim payload は source privacy を継承

`SourceVaultBundleCreate` / `SourceVaultBundleInvalidate` などの mutation は main kernel approval 経由に限定する。ClaudeOrchestrator 経由の mutation は将来、feedback proposal を user approval 付き workflow に昇格する実装が入った後に扱う。

### 10.7 LLM Deposited Artifacts

LLM が MCP 経由で保存する markdown / `.wl` / PDF / image / JSON / text は、`artifact` kind として扱う。これは notebook や mail の本文を直接更新するものではなく、SourceVault 内に新しい成果物を追加する操作である。

初期実装は既存 `DerivedArtifact` サブシステムを正準にする。`sv://artifact/...` は MCP / prompt 向けの外部 URI であり、SourceVault 内部の保存 class は原則 `ObjectClass -> "DerivedArtifact"` / snapshot class `"DerivedArtifact"` とする。これにより、既存の `SourceRefs`、参照イベント、importance 連携、`SourceVaultDerivedArtifactsForSource` による逆引きを再利用する。新しい snapshot class `"Artifact"` を並行新設しない。

- text / markdown / JSON / 小さい `.wl` は、Phase G で拡張した `SourceVaultSaveDerivedArtifact` 互換 API に渡し、`DerivedArtifact` 不変 snapshot として保存する。
- binary / 大きい payload は `SourceVaultCommitBlob[data, "Meta" -> ...]` で content-addressed blob として保存し、その `BlobRef` を `DerivedArtifact` record から参照する。
- MCP 入力の `inputRefs` / `citationRefs` / `promptRefs` は境界 schema の alias とし、保存時は URI 正規化済みの `SourceRefs` と `SourceRefRoles` に正規化する。`SourceRefs` を派生関係の正本にし、adapter 内部 ID や local path を入れない。
- `ArtifactType -> "MCPDeposit"` または media type 別の artifact type を導入し、SourceRefs には `"Deposited"` 参照イベントを emit する。既存 `"Summary"` は従来どおり `"Summarized"` に対応する。
- `"Deposited"` および既存 fallback `"Derived"` の参照イベント weight は低く明示登録する。自己申告 `SourceRefs` を `UsedInAnswer` 相当の importance boost にしてはならない。deposit 由来イベントには `"channel" -> "MCPDeposit"` を付け、importance 集計側で discount / ignore できるようにする。
- 同一 content の再保存は idempotent とし、`DerivedArtifact` ref / artifact URI を返す。
- Phase G の deposit API は、現行 `SourceVaultSaveDerivedArtifact` を無変更で直接呼ばない。現行実装は `ArtifactId -> CreateUUID[]` と `CreatedAt` を record に含めるため、同一 content でも別 snapshot になり得る。deposit では `ContentSHA256` / `BlobRef` と `idempotencyKey` から dedup identity を作る、または volatile field を digest 対象から除外する、または idempotency-key index を先に引く。
- 現行 `SourceVaultSaveDerivedArtifact` は `Text` / `Summary` が空だと `EmptyText` で失敗する。deposit 拡張では `Text` または `Content.BlobRef` のいずれかを必須にし、binary-only artifact を許可する。
- `.wl` は実行可能コードではなく inert artifact として保存する。deposit された `.wl` は blob storage / DerivedArtifact に留め、package loader の glob scan、`Get`、`Needs`、自動 import の対象にしない。評価、tool 実行への接続は別の approval gate を要求する。
- PDF / image は base64 payload または将来の chunked upload / local file handle で受ける。EXIF や embedded metadata は leakage source として扱い、metadata projection も release gate を通す。

DerivedArtifact deposit record の正準 schema 案:

```wolfram
<|
  "ObjectClass" -> "DerivedArtifact",
  "SchemaVersion" -> 1,
  "ArtifactType" -> "MCPDeposit" | "Summary" | "Markdown" | "WLSource" |
                    "PDF" | "Image" | _String,
  "ArtifactId" -> _String,
  "CanonicalURI" -> "sv://artifact/...",
  "AlternateURIs" -> {"sv://hash/sha256/...", "snapshot:DerivedArtifact:..."},
  "Ref" -> "snapshot:DerivedArtifact:...",
  "Text" -> _String | Missing[],
  "Content" -> <|
    "BlobRef" -> "blob:sha256:..." | Missing[],
    "MediaType" -> "text/markdown" | "application/vnd.wolfram.wl" |
                   "application/pdf" | "image/png" | _String,
    "Filename" -> _String | Missing[],
    "Bytes" -> _Integer,
    "ContentSHA256" -> "sha256:..."
  |>,
  "Metadata" -> <|
    "Title" -> _String | Missing[],
    "Language" -> _String | Missing[],
    "CreatedAtUTC" -> _String,
    "IngestedAtUTC" -> _String
  |>,
  "Policy" -> <|
    "PrivacyLevel" -> _Real,
    "AccessTags" -> {_String ...},
    "DenyTags" -> {_String ...},
    "ReleaseContext" -> _String | None,
    "CloudSendAllowed" -> True | False
  |>,
  "SourceRefs" -> {"sv://..." ...},
  "SourceUrls" -> {_String ...} | Missing[],
  "SourceRefRoles" -> <|
    "Input" -> {"sv://..." ...},
    "Citation" -> {"sv://..." ...},
    "Prompt" -> {"sv://..." ...}
  |>,
  "IngestProvenance" -> <|
    "DepositedBy" -> principal,
    "AuthoredBy" -> _Association,
    "ActingFor" -> _Association | Missing[],
    "Provider" -> _String | Automatic,
    "ModelId" -> _String | Automatic,
    "SessionId" -> _String,
    "Tool" -> "sourcevault_deposit",
    "UserApproved" -> True | False | Missing[]
  |>,
  "Integrity" -> <|
    "RecordDigest" -> "sha256:...",
    "CreatedEventId" -> _String | Missing[]
  |>
|>
```

`IngestProvenance` は既存 `SourceVaultSaveDerivedArtifact` record との互換名である。MCP 応答では `Provenance` alias として返してよいが、保存 record では `IngestProvenance` を正準にする。`Content` / `Policy` / `Metadata` / `SourceRefRoles` / `Integrity` は Phase G の `DerivedArtifact` record builder で追加する拡張 field であり、既存関数の現行 field set に存在しないことを前提に実装する。

#### 10.7.1 LLM identity の二層記録

既存 `SourceVault_identity.wl` は、`Identifier` と `Entity` の二層で作成者・送信者を管理している。LLM deposit でも同じ構造を使う。

- Identifier 層: `llm-provider:lmstudio`, `llm-model:qwen/qwen3.6-27b`, `mcp-client:claude-code`, `mcp-session:<id>`, `codex-thread:<id>` など、観測された transport / model / session identity を記録する。
- Entity 層: 既存実装で確実に使われている `Kind -> "Person"` を維持しつつ、LLM 用には `Kind -> "LLM" | "LLMService" | "Agent" | "Workflow"` などを拡張候補にする。実装時は `SourceVault_identity.wl` / `api_identity.md` の実際の Kind 語彙を確認し、未知 Kind は fail-closed profile で登録する。
- 自動作成される LLM / Agent entity は fail-closed の `ContactAccessProfile` を持つ。identity resolution は security boundary ではない。

artifact provenance では少なくとも二つの作成者レイヤーを分ける。

- `AuthoredBy`: LLM が自己申告する著者、モデル名、生成主体。これは provenance であり authority ではない。
- `DepositedBy`: AccessGrant / transport / endpoint / main kernel が確認した投入主体。監査と責任追跡ではこちらを正本にする。

必要に応じて `ActingFor` にユーザまたは ClaudeOrchestrator workflow を記録する。ただし `ActingFor` があるだけで、そのユーザの private data を読めるわけではない。

#### 10.7.2 deposit 時の privacy / tag 継承

LLM が生成した artifact は、入力 source より低い privacy に自動 declassify してはならない。

```text
ArtifactPrivacyLevel =
  Max[
    RequestedPrivacyLevel,
    PrivacyLevel inferred from SourceRefs,
    PrivacyLevel inferred from prompt/session context,
    EndpointAccessProfile.DepositPrivacyFloor]

ArtifactAccessTags =
  Union[RequestedAccessTags, AccessTags inherited from SourceRefs, RequiredTagsFromProfile]

ArtifactDenyTags =
  Union[RequestedDenyTags, DenyTags inherited from SourceRefs, RequiredDenyTagsFromProfile]
```

MCP 境界では `inputRefs` / `citationRefs` / `promptRefs` を受け付けてよいが、保存前に `SourceRefs` / `SourceRefRoles` へ正規化する。入力参照の privacy / tags を service kernel で評価できない場合、初期実装は fail-closed とし、`PrivacyLevel -> 0.75` 相当、`CloudSendAllowed -> False`、または `RequireApproval` に落とす。notebook / mail など MainKernelOnly な参照を含み、正確な継承が必要な deposit は、§11.3 の approval queue を経由して main kernel / NBAccess 側で評価し、その結果に基づく AccessGrant または deposit plan を mint する。

LLM が要求した `PrivacyLevel` / `AccessTags` は下限・候補であり、SourceVault / NBAccess がより厳しい値へ引き上げられる。

`AccessTags` の緩和、`DenyTags` の削除、`CloudSendAllowed -> True`、public citation への昇格は deposit ではなく declassification / release planning として扱い、別 approval を要求する。

## 11. Authorization Flow

### 11.1 Search

```text
MCP tool call
  -> parse SearchSpec
  -> build AccessRequest(Action="Search")
  -> resolve AccessProfile / ReleaseContext / ScopePolicy
  -> request gate
     (NBAuthorize query/object spec with Sink/Environment/Principal;
      PolicyGate + EnvironmentGate are hard, ScoreGate is advisory)
  -> resolve scope-compatible indexes
     (SourceVaultResolveSearchIndexesForScope;
      SourceVault_searchindex ReleaseContext/Corpus/Index/PurposeIndex validation)
  -> select adapters
  -> adapter search or SourceVaultSearch[Index -> compatibleIndex]
  -> normalize SearchResult
  -> per-result release gate
     (NBAuthorize + SourceVaultEvaluateReleasePolicy + AccessTagPolicyWrapper)
  -> normalize each result to canonical URI
  -> optionally persist SourceVaultSearchResultSet
  -> projection / redaction / truncation
  -> JSON-safe MCP response
```

### 11.2 Read

```text
MCP tool call
  -> parse ObjectRef / ReadSpec
  -> resolve adapter
  -> build object spec
  -> request gate
     (NBAuthorize object spec with Sink/Environment/Principal;
      PolicyGate + EnvironmentGate are hard, ScoreGate is advisory)
  -> adapter read
  -> release gate for requested projection
     (NBAuthorize + SourceVaultEvaluateReleasePolicy + AccessTagPolicyWrapper)
  -> redaction / truncation
  -> response
```

adapter は独自の release 判定を増やさず、既存 `SourceVaultEvaluateReleasePolicy[source, contextName]` と `NBAuthorize` / `NBPermitQ` に必要な object spec / access request を構築する。adapter 固有の追加制約は、共通 gate に渡す source metadata / tags / privacy / state / PolicyLabel / Environment として表現する。

### 11.3 RequireApproval

`RequireApproval` は MCP では成功扱いではなく、次を返す。

```wolfram
<|
  "Status" -> "RequireApproval",
  "RequestId" -> _String,
  "Action" -> _String,
  "ObjectRef" -> _String | Missing[],
  "Reason" -> _String,
  "HowToProceed" -> "Call sourcevault_request_access and poll sourcevault_access_status, or ask the user to approve in Mathematica."
|>
```

MCP client が勝手に再試行して権限昇格できないよう、approval request は NBAccess/main kernel 側の session に束縛する。ClaudeOrchestrator 側の workflow session へ束縛する設計は将来拡張とする。

承認は v6 の job と同じ poll 型にする。

```text
sourcevault_request_access
  -> <|"RequestId" -> "...", "Status" -> "Pending"|>

sourcevault_access_status
  -> Pending | Granted | Denied | Expired

Granted
  -> short-lived AccessGrant または AccessHandle
```

SSE や long polling は要求しない。`sourcevault_access_status` は `sourcevault_job_status` と同じ transport 前提で実装する。

`sourcevault_request_access` が作る pending request は、service kernel が LocalState の承認 queue に append-only で保存する。

```text
<LocalState>/hotlog/mcp_access_requests/YYYY-MM.jsonl
```

main kernel / notebook 側には、少なくとも次の helper を用意する。

```wolfram
SourceVaultMCPPendingAccessRequests[opts]
SourceVaultMCPApproveAccessRequest[requestId, opts]
SourceVaultMCPDenyAccessRequest[requestId, reason]
```

承認 helper は NBAccess の authorization を呼び、許可された場合だけ §2.3 の AccessGrant または AccessHandle を mint する。発行結果は同じ requestId に紐づく status sidecar / event として LocalState に記録し、service kernel の `sourcevault_access_status` が `Pending | Granted | Denied | Expired` として返す。

この queue は feedback queue とは別物である。access request queue は権限昇格に関わるため、UI / helper / audit log を Phase D の成果物に含める。

### 11.4 Resolve URI

```text
MCP tool call
  -> parse sv:// URI
  -> normalize ObjectRef / internal ref candidate
  -> build AccessRequest(Action="ResolveObjectURI")
  -> request gate
  -> resolve adapter / artifact record / snapshot metadata
  -> release gate for requested view
  -> return metadata, citation, available views, and optional accessHandle
```

`sourcevault_resolve_uri` は URI を capability に変換しない。返せるのは、許可された projection の metadata、citation、利用可能 view、必要な grant の説明、同一 session に束縛された短命 `AccessHandle` までである。`blob:sha256:...` や local path は既定では返さない。

### 11.5 Deposit Artifact

```text
MCP tool call
  -> parse DepositSpec
  -> build AccessRequest(Action="DepositArtifact")
  -> request gate
  -> validate media type / size / encoding
  -> check per-session / per-principal quota and rate limit
  -> normalize inputRefs / citationRefs / promptRefs to SourceRefs / SourceRefRoles
  -> resolve SourceRefs only to the extent required for policy inheritance
  -> compute inherited PrivacyLevel / AccessTags / DenyTags
  -> plan response if mode="plan"
  -> SourceVaultCommitBlob[data]
  -> resolve idempotency by ContentSHA256 / BlobRef + idempotencyKey
  -> SourceVaultSaveDerivedArtifact-compatible deposit builder
     (snapshot class "DerivedArtifact"; event type "Deposited")
  -> return canonical sv://artifact/... URI and citation metadata
```

`mode -> "plan"` は書き込みを行わず、予定される `PrivacyLevel` / `AccessTags` / `DenyTags` / `CanonicalURI` 形式 / 必要 approval を返す。`mode -> "commit"` は `AllowedActions` に `DepositArtifact` を含む AccessGrant、または endpoint profile の明示許可を要求する。

deposit は create-only / idempotent でなければならない。同じ content + 同じ idempotency key の再実行は同じ DerivedArtifact record または `Existed -> True` を返す。異なる content が同じ user-supplied id / alias を要求した場合は collision として fail-closed する。deposit alias は create-only とし、既存 alias の re-point は破壊的 mutation / pointer 更新扱いで別 approval を要求する。

deposit は per-session / per-principal の件数・総バイト quota と rate limit を必ず通す。超過時は `QuotaExceeded` または `RateLimited` として fail-closed し、payload を保存しない。quota 判定は `DepositedBy` / `SessionId` / `ModelId` を含む audit event と対応させ、異常な大量 deposit を後から検出できるようにする。

deposit 由来の `SourceRefs` は自己申告 provenance であり、検証済み evidence ではない。`"Deposited"` / `"Derived"` 参照イベントは低 weight に固定し、`channel -> "MCPDeposit"` を付ける。高い importance boost は、本文・引用関係が main kernel / NBAccess / human review で検証された後の `"Cited"` / `"UsedInAnswer"` など別 event に限る。

MCP から受けた payload をそのまま cloud へ再送しない。service kernel は payload を SourceVault core storage に保存し、応答では `sv://` URI と許可済み metadata のみ返す。

## 12. ClaudeOrchestrator Feedback Bridge

### 12.1 目的

MCP client から ClaudeOrchestrator へ、次のような情報を返せるようにする。

- help request: 「この検索範囲では答えられないので、追加探索を頼みたい」
- subtask proposal: 「この論文集合を local worker で要約してほしい」
- access request: 「メール本文ではなく summary だけで足りるか確認してほしい」
- critique / correction: 「検索結果 A と B が矛盾している」
- session note: 「この LLM はこの objectRef を根拠として使った」

### 12.2 MCP tool

MVP:

| Tool | 役割 |
|---|---|
| `sourcevault_feedback_submit` | Orchestrator 宛 feedback event を記録 |
| `sourcevault_orchestrator_help` | help request を作成 |
| `sourcevault_orchestrator_subtask` | subtask proposal を作成 |

これらは workflow を直接実行しない。  
MVP では SourceVault service が feedback event を記録するだけに留める。ClaudeOrchestrator が event を読み、必要なら user approval / worker spawn へ昇格する処理は将来拡張とする。grant 発行は MVP では NBAccess が担い、feedback bridge は grant issuer ではない。

### 12.3 FeedbackEnvelope

```wolfram
<|
  "EventId" -> _String,
  "Kind" -> "HelpRequest" | "SubtaskProposal" | "AccessRequest" |
            "Critique" | "Correction" | "SessionNote",
  "From" -> principal,
  "Target" -> <|"System" -> "ClaudeOrchestrator", "SessionId" -> _String|>,
  "Payload" -> <|
    "Text" -> _String,
    "Goal" -> _String | Missing[],
    "SuggestedRole" -> _String | Missing[],
    "SuggestedCapabilities" -> {_String ...},
    "RequestedData" -> {_String ...},
    "EvidenceRefs" -> {_String ...}
  |>,
  "PrivacyLevel" -> _Real,
  "CreatedAtUTC" -> _String,
  "RequireApproval" -> True | False,
  "Status" -> "Queued"
|>
```

### 12.4 保存先

feedback event は hot data なので LocalState に append-only で置く。

```text
<LocalState>/hotlog/mcp_feedback/YYYY-MM.jsonl
```

低頻度で CoreRoot へ rollup 可能にする。  
package directory や `github.wl` の upload manifest 対象には置かない。

feedback log の単一書き手は service kernel とする。proxy / MCP endpoint は直接 JSONL に追記せず、file command queue 経由で service kernel に `AppendFeedback` command を渡す。書き込みは core の atomic directory lock / append-only パターンを使い、ReferenceEvents hotlog と同じ運用にそろえる。

### 12.5 Orchestrator 側 bridge

将来 API 案:

```wolfram
ClaudeOrchestratorIngestSourceVaultFeedback[event_Association]
ClaudeOrchestratorFeedbackQueue[opts]
ClaudeOrchestratorAcceptFeedback[eventId, opts]
ClaudeOrchestratorRejectFeedback[eventId, reason]
ClaudeOrchestratorCreateSubtaskFromFeedback[eventId, opts]
```

ClaudeOrchestrator の将来責務:

- multi-turn / long-running state 管理
- approval 待ち
- worker spawn
- retry / pause / resume
- single committer
- approval proposal の workflow 化

MCP / SourceVault の責務:

- feedback event の受け取り
- provenance 記録
- data reference の検証
- 危険な直接実行をしない

## 13. Multi-LLM Session Control

本節は将来構想であり、MVP / Phase A-H の実装対象ではない。ClaudeOrchestrator 側に session broker / grant issuer / participant policy が存在しない現状では、この機能を前提にしない。

複数の cloud LLM / private LLM / local LLM が同じ SourceVault を介して通信する場合、ClaudeOrchestrator を session broker とする。

### 13.1 SessionEnvelope

```wolfram
<|
  "SessionId" -> _String,
  "Owner" -> _String,
  "Participants" -> {principal ...},
  "AllowedDataKinds" -> {...},
  "DefaultReleaseContext" -> _String,
  "AccessProfileByParticipant" -> <|clientId -> profileRefOrInlineProfile|>,
  "MaxAccessLevelByParticipant" -> <|clientId -> level|>,
  "AllowedFeedbackKinds" -> {...},
  "CreatedAtUTC" -> _String,
  "ExpiresAtUTC" -> _String,
  "RevocationEpoch" -> _Integer
|>
```

### 13.2 Data lease

LLM 間で本文を渡すのではなく、objectRef / evidenceRef / accessHandle を渡す。

- handle は短命
- projection scope 固定
- revocation epoch を持つ
- 期限切れ後は再 gate

これにより「cloud LLM が private LLM に何かを依頼する」場合でも、ClaudeOrchestrator が data flow を制御できる。

## 14. 段階実装計画

### Phase A: 仕様と catalog

- `sourcevault_catalog`
- adapter registry skeleton
- 既存 Web MCP tool の互換維持
- JSON-safe 共通 formatter
- access request / principal 正規化
- NBAccess design に合わせた `AccessLevel` / `PrivacyLevel` 用語整理
- MCP / Web 共通 `AccessProfile` schema
- `SourceVaultURIForObject` / `SourceVaultResolveURI` / `SourceVaultCanonicalURI` の skeleton
- URI grammar の予約 namespace / parse precedence 実装

### Phase B: 低漏洩横断検索

- `sourcevault_search`
- `web` / `search` / `eagle summary` / `mail summary` の metadata + summary search
- `uriList` / `uriSet` / `referencesOnly` / `compactText` / `structuredJson`
- search result の `URI` 正準化。`ObjectRef` は互換 alias として残す
- `SourceVaultSearchResultSet` snapshot と `sv://group/search-resultset/...`
- URISet / Relation / SearchResultSet 保存前の canonical URI 正規化
- raw path 非返却テスト
- `ScopePolicy` による `RequireAccessTags` / `DenyAccessTags` filter
- タグ未設定 object の `Untagged -> "MetadataOnly" | "Deny"` 挙動
- `SourceVault_searchindex.wl` の `SourceVaultSearch` を search adapter の正準 backend として接続
- `SourceVaultResolveSearchIndexesForScope` の最小実装: ReleaseContext / ScopePolicy / active index / certified post-filter 判定

### Phase C: 指定読み出し

- `sourcevault_get`
- `metadata` / `summary` / `snippet`
- `context` は release context または grant 必須
- `body` / `raw` は MVP では Deny
- `SourceVaultSetModelAccessProfile` または `SourceVaultSetModel[..., "MCPAccessProfile" -> ...]` の実装
- `SourceVaultRegisterWebServiceEndpoint` / `CapabilityProfile` への `AccessProfileRef` 接続

### Phase D: grant / approval

- `sourcevault_explain_access`
- `sourcevault_request_access`
- `sourcevault_access_status`
- AccessGrant mint API: `SourceVaultMCPMintAccessGrant` または NBAccess 側同等 API
- pending access request queue: `SourceVaultMCPPendingAccessRequests` / approve / deny helper
- NBAccess policy 判定 + SourceVault crypto による HMAC 署名
- service kernel 側の HMAC 検証
- `SourceVault_crypto.wl` の service loader (`iGenRunWls`) 追加。ロード順は `SourceVault_core.wl` 後、`SourceVault_mcp.wl` 前。
- `SourceVault_info/upload_manifest.json` に `SourceVault_crypto.wl` が含まれることを `github.wl` の `GitHubValidateManifest` で確認
- `RequireApproval` response

### Phase E: Notebook / Mail body / Eagle PDF context

- notebook adapter を NBAccess semantic API と接続
- mail body は local-only grant 必須
- Eagle PDF page context は selector + grant
- field-level redaction

### Phase F: Orchestrator feedback

- SourceVault feedback hotlog
- `sourcevault_feedback_submit`
- `sourcevault_orchestrator_help`
- `sourcevault_orchestrator_subtask`
- ClaudeOrchestrator 側 queue / accept / reject は将来 API 案として文書化のみ

### Phase G: artifact deposit / URI resolver

- `sourcevault_resolve_uri`
- `sourcevault_deposit`
- `SourceVaultCommitBlob` + `SourceVaultSaveDerivedArtifact` / `"DerivedArtifact"` snapshot による create-only 保存
- `SourceRefs` / 参照イベント / `SourceVaultDerivedArtifactsForSource` の既存逆引き機構を再利用
- `"Deposited"` / `"Derived"` 参照イベント weight の低 weight 明示登録、`channel -> "MCPDeposit"` discount
- content hash + idempotency key による DerivedArtifact record dedup。現行 `CreateUUID[]` / `CreatedAt` 依存の非 idempotent record builder は deposit では使わない
- `Text` または `Content.BlobRef` のいずれか必須にして binary-only deposit を許可
- LLM / Agent identity を `SourceVault_identity.wl` の Identifier / Entity 二層に拡張
- `AuthoredBy` / `DepositedBy` / `ActingFor` / `SourceRefs` / `SourceRefRoles` provenance
- deposit privacy / AccessTags / DenyTags の継承
- per-session / per-principal quota と rate limit
- `.wl` artifact は inert file として保存し、実行は別 approval gate
- prompt 内 `sv://` URI を MCP で解決する運用ルール

### Phase H: semantic / vector backend

- adapter capability `SemanticSearch`
- vector DB backend registry
- hybrid rank
- index snapshot / workflow snapshot への provenance 記録
- `SearchBackend` / `RetrievalWorkflowSnapshot` / `CorpusSnapshot` / `IndexSnapshot` / `PurposeIndexSnapshot` を MCP catalog に露出
- data group 専用 RAG / vector DB / purpose index の scope-compatible selection

### Phase I: Orchestrator session broker (future)

- ClaudeOrchestrator 側 session broker
- multi-LLM participant policy
- ClaudeOrchestrator grant issuer 拡張
- feedback event から workflow subtask への昇格

Phase I は ClaudeOrchestrator 側の新 API 実装が必要な独立プロジェクトとして扱う。

## 15. 実装上の注意

### 15.1 service-loadable 境界

`SourceVault_mcp.wl` は v6 ルール通り FrontEnd / Notebook / NBAccess に直接依存しない。  
NBAccess が必要な処理は以下のどちらかにする。

1. main kernel / NBAccess が grant を発行し、service は HMAC grant 検証だけ行う。
2. service adapter を `UnavailableWithoutMainKernel` として fail-closed にする。

### 15.2 秘密情報の保存先

MCP transport token、session grant cache、feedback hotlog は LocalState。  
package directory / `SourceVault_info/` / `github.wl` の upload manifest 対象に置かない。GitHub への同期対象は `SourceVault_info/upload_manifest.json` と `GitHubValidateManifest` で確認する。

### 15.3 data store mutation

MCP 由来の破壊的 mutation は MVP では禁止。  
ただし Phase G の `sourcevault_deposit` は、append-only / create-only の artifact deposit として例外的に許可できる。deposit は次を満たす。

- raw local path への任意書き込みをしない。
- `SourceVaultCommitBlob` による content-addressed blob と、`DerivedArtifact` immutable snapshot または append-only event の組で保存する。
- `SourceRefs` / 参照イベント / 逆引きは既存 `SourceVaultSaveDerivedArtifact` 系を再利用し、並行する新 `"Artifact"` snapshot class を作らない。
- 既存 object を上書きしない。
- privacy / AccessTags / DenyTags を入力 source より緩めない。
- deposit 由来の自己申告 `SourceRefs` は低 weight の `"Deposited"` event に留め、importance / ranking を強く押し上げない。
- artifact record は content hash / idempotency key で dedup し、揮発 field によって同一内容が別 snapshot へ増殖しないようにする。
- per-session / per-principal の件数・総バイト quota と rate limit を通し、超過時は `QuotaExceeded` / `RateLimited` で fail-closed する。
- `mode -> "plan"` で予定される policy / provenance / URI を事前確認できる。
- `mode -> "commit"` は endpoint profile または AccessGrant の `DepositArtifact` 許可を要求する。
- 監査 event に `DepositedBy` / `AuthoredBy` / `ModelId` / `SessionId` / `SourceRefs` を残す。

既存データの変更、削除、pointer 更新、bundle invalidate、privacy 緩和、tag 緩和を将来追加する場合は必ず次を守る。

- `DryRun -> True` 既定
- 実行前 approval
- 削除と mark を分離
- atomic write
- 変更件数の集計

### 15.4 JSON safety

MCP result は JSON-safe にする。

- `Missing` / `None` -> null。ただし omission reason は `OmittedFields` / `RedactionReasons` / `ReleasedProjection` に保持する。
- `DateObject` -> ISO string
- raw binary は返さない
- 長文は `maxChars` で切る
- token / credential は絶対に返さない

### 15.5 関連 rules / docs

実装時は本仕様だけでなく、以下を併読する。

- `Claude Directives/CLAUDE.md`: Claude Code / ChatGPT Codex はローカル tool を起動できても cloud/remote LLM sink として扱い、privacy 0.5 以上の raw/private content を model context に送らない、という基本原則を常に保持する。本仕様の当該原則を更新した場合、`CLAUDE.md` 側も同時に更新する。
- `Claude Directives/rules/103-sourcevault-datastore-safety.md`: DryRun 既定、削除と mark 分離、atomic write、変更件数集計。
- `Claude Directives/rules/104-path-ref-identity-not-authority.md`: PathRef は identity であり authority ではない。
- `Claude Directives/rules/105-sourcevault-web-mcp.md`: service-loadable 境界、LocalState、MCP proxy、service restart、upload manifest 更新義務。
- `NBAccess_info/design/nbaccess_phase4_privacy_projection_policy_revised3.md`: `PrivacyLevel` は legacy / routing hint として凍結し、`AccessLevel` は request / sink / route が許容する最大 risk score とする。Cloud send は `NBAuthorize` projection として扱う。
- `NBAccess_info/design/NBAccess_claudecode_privacy_spec_v0_1.md`: Principal / ReaderPolicy / PolicyLabel / EffectiveRiskScore / AccessRequest / ReleasePolicy / Declassify の基本設計。タグ・ラベル・score を混同しない。
- `SourceVault_info/docs/api_searchindex.md`: `ReleaseContext` / `SearchBackend` / `RetrievalWorkflowSnapshot` / `CorpusSnapshot` / `IndexSnapshot` / `ProjectionIndex` / `PurposeIndex` / `SourceVaultSearch`。
- `SourceVault_info/docs/api_core.md`: `SourceVaultCommitBlob` / `SourceVaultSaveImmutableSnapshot` / append-only event / content-addressed storage。
- `SourceVault_info/docs/api_webingest.md`: `SourceVaultSaveDerivedArtifact` / `SourceVaultDerivedArtifactList` / `SourceVaultDerivedArtifactsForSource`、`SourceRefs` と参照イベント。
- `SourceVault_info/docs/api_identity.md`: Identifier / Entity の二層 identity、fail-closed ContactAccessProfile、identity resolution は security boundary ではないという原則。
- `github_info/docs/api.md` / `github_info/docs/README.md`: GitHub 反映は `github.wl` の `upload_manifest.json`、`GitHubValidateManifest`、`GitHubRefreshAndCommit` 等を使う。通常の低レベル git 操作を前提にしない。

## 16. MVP tool schema 案

### sourcevault_catalog

Input:

```json
{
  "includeUnavailable": true
}
```

Output:

```json
{
  "adapters": [
    {
      "name": "eagle",
      "kinds": ["eagle", "pdf", "image"],
      "available": true,
      "capabilities": ["search", "metadata", "summary"],
      "requiresGrantFor": ["context", "body", "raw"]
    },
    {
      "name": "artifact",
      "kinds": ["artifact", "markdown", "wl", "pdf", "image"],
      "available": true,
      "capabilities": ["resolve_uri", "metadata", "summary", "deposit"],
      "requiresGrantFor": ["body", "raw"]
    }
  ],
  "searchIndexes": [
    {
      "indexId": "ie-department-public-proj",
      "indexKind": "ProjectionIndex",
      "releaseContextRefs": ["ie-public"],
      "scopeTags": ["Department:InformationEngineering"],
      "methods": ["keyword"],
      "state": "Active"
    }
  ],
  "defaultReturnFormats": ["compactText", "structuredJson", "referencesOnly"]
}
```

### sourcevault_search

Input: SearchSpec。  
Output: `uriList` / `uriSet` / compactText / structured SearchResult list。structured result では `URI` を正準 field とし、`ObjectRef` は互換 alias とする。

### sourcevault_get

Input: ReadSpec。  
Output:

```json
{
  "status": "OK",
  "objectRef": "sv://...",
  "view": "summary",
  "content": "...",
  "citation": {},
  "releasedProjection": "summary",
  "truncated": false
}
```

### sourcevault_context

Input: span list。  
Output: evidenceText または structured context blocks。

### sourcevault_explain_access

Input:

```json
{
  "objectRef": "sv://...",
  "action": "ReadBody",
  "view": "body"
}
```

Output:

```json
{
  "decision": "RequireApproval",
  "why": ["PrivacyExceedsGrant", "BodyRequested"],
  "possibleLowerLeakViews": ["metadata", "summary", "referencesOnly"]
}
```

### sourcevault_request_access

Input:

```json
{
  "objectRef": "sv://...",
  "action": "ReadContext",
  "view": "context",
  "fields": ["summary", "body"],
  "purpose": "answer-with-citations",
  "requestedAccessLevel": 0.8,
  "requestedMaxPrivacyLevel": 0.8
}
```

`requestedMaxPrivacyLevel` は後方互換 alias であり、新規 client は `requestedAccessLevel` を使う。

Output:

```json
{
  "requestId": "sv-access-...",
  "status": "Pending",
  "pollTool": "sourcevault_access_status",
  "expiresAtUTC": "..."
}
```

### sourcevault_access_status

Input:

```json
{
  "requestId": "sv-access-..."
}
```

Output:

```json
{
  "requestId": "sv-access-...",
  "status": "Granted",
  "accessHandle": "optional",
  "accessGrant": "optional",
  "expiresAtUTC": "..."
}
```

`status` は `"Pending" | "Granted" | "Denied" | "Expired"`。`Granted` 以外では `accessHandle` / `accessGrant` を返さない。

### sourcevault_resolve_uri

Input:

```json
{
  "uri": "sv://artifact/art-...",
  "view": "metadata",
  "returnFormat": "structuredJson",
  "sessionGrant": null
}
```

Output:

```json
{
  "status": "OK",
  "uri": "sv://artifact/art-...",
  "objectRef": "sv://artifact/art-...",
  "kind": "artifact",
  "availableViews": ["metadata", "summary"],
  "metadata": {
    "title": "draft note",
    "mediaType": "text/markdown",
    "privacyClass": "private"
  },
  "citation": {
    "label": "SourceVault artifact: draft note",
    "uri": "sv://artifact/art-..."
  },
  "releasedProjection": "metadata"
}
```

`view -> "body" | "raw"` は `sourcevault_get` と同じ gate を通す。URI 解決だけでは本文アクセスを許可しない。

### sourcevault_deposit

Input:

```json
{
  "mode": "plan",
  "kind": "artifact",
  "mediaType": "text/markdown",
  "filename": "research_meeting_note.md",
  "title": "研究会メモ",
  "content": {
    "encoding": "utf-8",
    "text": "# 研究会メモ\n..."
  },
  "policy": {
    "privacyLevel": "Automatic",
    "accessTags": ["ie-department"],
    "denyTags": [],
    "releaseContext": null
  },
  "provenance": {
    "authoredBy": {
      "provider": "lmstudio",
      "modelId": "qwen/qwen3.6-27b"
    },
    "inputRefs": ["sv://object/..."],
    "citationRefs": ["sv://object/..."]
  },
  "idempotencyKey": "optional-client-generated-key",
  "sessionGrant": null
}
```

Output for `mode -> "plan"`:

```json
{
  "status": "Planned",
  "wouldWrite": false,
  "effectivePolicy": {
    "privacyLevel": 0.75,
    "accessTags": ["ie-department"],
    "denyTags": [],
    "cloudSendAllowed": false
  },
  "normalizedSourceRefs": ["sv://object/...", "sv://object/..."],
  "quota": {
    "status": "OK",
    "remainingBytes": 1048576,
    "remainingItems": 20
  },
  "requiresApproval": false,
  "warnings": []
}
```

Output for `mode -> "commit"`:

```json
{
  "status": "OK",
  "artifactUri": "sv://artifact/art-...",
  "derivedArtifactRef": "snapshot:DerivedArtifact:...",
  "contentUri": null,
  "citation": {
    "label": "SourceVault artifact: 研究会メモ",
    "uri": "sv://artifact/art-..."
  },
  "blobRefExposed": false,
  "releasedProjection": "metadata"
}
```

`contentUri` は `sv://hash/sha256/...` を返せる policy の場合だけ設定する。高 privacy artifact では `null` とし、opaque `artifactUri` を正準参照にする。MVP での `content.encoding` は `"utf-8"` と `"base64"` を許可する。大きい PDF / image は size limit を超えた場合 `PayloadTooLarge` とし、将来の chunked upload または main kernel local file handle に回す。

`inputRefs` / `citationRefs` は MCP 入力互換名であり、保存時には `SourceRefs` / `SourceRefRoles` へ正規化する。quota 超過時は `mode -> "commit"` でも保存せず、`Status -> "QuotaExceeded"` または `"RateLimited"` を返す。

## 17. 未決事項

1. AccessGrant の鍵管理  
   署名方式は `LocalState/secrets/sourcevault-grant-signing-key.json` の shared secret による HMAC を MVP 正準とする。未決なのは key rotation、KeyId 管理、revocation epoch の rollup 方式である。

2. service kernel で mail / notebook adapter をどこまでロードするか  
   現行ルールでは `SourceVault_mcp.wl` 自体は NBAccess 非依存。高 privacy adapter は main kernel bridge に逃がす案が安全。

3. vector DB の正準 backend  
   Mathematica 内 keyword index、外部 vector DB、SQLite FTS、Qdrant 等を adapter 化するか。

4. ClaudeOrchestrator feedback の UI  
   queue を notebook cell に提示するか、palette / dataset / workflow place として見せるか。

5. access request 承認 UI  
   feedback UI とは別に、`mcp_access_requests` queue を main kernel で確認し、NBAccess 判定と HMAC grant mint を実行する UI / helper を決める必要がある。

6. cloud LLM と private LLM の相互通信 policy  
   ClaudeOrchestrator が participant ごとの AccessProfile / MaxAccessLevel / sink を管理する必要がある。

7. AccessProfile の保存先  
   `SourceVaultSetModel` の compiled model registry に policy 本体を保存するか、registry には `AccessProfileRef` だけを保存し LocalState / PrivateVault 側に profile 本体を置くかを決める必要がある。個人環境・所属・研究テーマに関わる tag scope は private metadata になり得るため、MVP では `AccessProfileRef` 方式を推奨する。

8. AccessTags の完全性  
   mail / encrypted record / identity では `AccessTags` の基盤があるが、notebook / web ingest / Eagle / PDF / SearchIndex の既存データすべてに認証済み AccessTags があるとは限らない。scoped profile でタグ未設定 object を `Deny` にするか `MetadataOnly` にするかは profile ごとに明示する。

9. tag policy の共通 API 化  
   現在の `SourceVaultTagPolicyEvaluate` は message release / recipient profile 文脈の API である。MCP / Web search に使うには、recipient ではなく principal / access profile / request scope を入力に取る薄い wrapper、例えば `SourceVaultEvaluateAccessTagPolicy[material, profile, request]` が必要になる。

10. artifact URI の外部表示形式  
    `sv://hash/sha256/<hex>` は便利だが、hash の露出が高 privacy content の同一性リークになり得る。外部 prompt / citation では opaque `sv://artifact/<artifactId>` を正準にし、hash URI をどの privacy level まで返すかを運用で決める必要がある。

11. deposit payload size / chunked upload  
    MCP JSON tool call で base64 PDF / image を受けると payload が大きくなる。MVP は size limit で fail-closed とし、将来 `sourcevault_deposit_chunk`、または main kernel が発行する local file handle 方式を検討する。

12. deposit quota policy  
    per-session / per-principal / per-model の件数、総バイト数、期間別 rate limit、retention / GC とどう接続するかを決める必要がある。MVP は安全側の小さな既定 quota と `QuotaExceeded` fail-closed を正準にする。

13. LLM / Agent entity の命名規約  
    `SourceVault_identity.wl` 本体で確実に使われている既定 `Kind -> "Person"` と、docs / 既存データに存在し得る Kind 語彙を確認し、`"LLM"` / `"Agent"` / `"LLMService"` / `"Workflow"` の対応表を作る必要がある。自動作成 entity は fail-closed の原則を維持する。

14. search index capability metadata  
    既存 `SourceVault_searchindex.wl` は ProjectionIndex / PurposeIndex / CorpusSnapshot / WorkflowSnapshot を持つが、MCP profile から自動選択するには、各 index が `ScopePolicy` / `RequiredAccessTags` / `DenyAccessTags` / `SupportsCertifiedPostFilter` / `HumanReviewed` / `State` を安定して返す必要がある。現行 registry / snapshot から導出する薄い `SourceVaultResolveSearchIndexesForScope` wrapper を追加する。

15. vector DB / external RAG backend の certified post-filter  
    外部 vector DB が chunk ごとの認証済み tags / privacy / object id を保持し、検索後に漏れなく post-filter できるかを backend capability として宣言させる必要がある。保証できない backend は、request scope より広い corpus に対して使わない。

16. URI migration / adapter hook  
    既存 `SourceVaultSearch`、Web ingest、mail snapshot、Eagle、notebook、PDFIndex legacy、DerivedArtifact、CorpusSnapshot、PurposeIndex の各 ID を `sv://object/...` / `sv://chunk/...` / `sv://artifact/...` 等の canonical URI に正規化する `SourceVaultURIForObject` / `SourceVaultResolveURI` / `SourceVaultCanonicalURI` adapter hook が必要である。旧 `ObjectRef` / `RecordId` / `SnapshotRef` は互換 field として残すが、新規 relation / group / search result snapshot は canonical URI を正本にする。`Class` / `MediaType` / `Kind` は sidecar metadata として付ける。`SourceVaultObjectId` は corpus / index の内部安定 key として維持し、`SourceVaultObjectURI` は併存 field とする。

17. URI namespace / sidecar class taxonomy  
    URI namespace は identity 用に `object` / `chunk` / `artifact` / `hash` / `group` / `relation` / `snapshot` / `record` / `citation` を予約する。`mail` / `web` / `image` / `pdf` / `text` / `notebook` / `audio` / `video` / `dataset` / `code` などは URI namespace ではなく `Class` / `MediaType` / `Kind` sidecar metadata として扱う。dataset 表示や `Select` のため、これらの付与を推奨する。

18. CanonicalURI / AlternateURI map  
    各 object は原則 1 つの `CanonicalURI` と複数の `AlternateURIs` を持つ。alternate には `snapshot:...` / `blob:...` / legacy record id 由来 URI が入る。URISet / Relation / SourceRefs / SearchResultSet は保存前に canonical 化する必要がある。ambiguous な URI の扱い、alias map の保存先、revocation 時の alias invalidation を決める必要がある。

## 18. v1 の結論

最初から全データ型・全検索方式・全返却形式を実装しきらない。  
しかし、最初から次の 9 つだけは固定する。

1. adapter registry
2. ObjectRef / SpanRef
3. SearchSpec / ReadSpec
4. request gate + release gate
5. Orchestrator feedback は event proposal であり直接実行ではない
6. LLM からの書き込みは append-only / create-only artifact deposit から始め、破壊的 mutation と分離する
7. `sv://` URI は参照 identity であり capability ではない。prompt 内 URI は MCP で解決し、アクセス不可なら metadata-only または access request に落とす
8. 検索/RAG backend は `SourceVault_searchindex.wl` の ReleaseContext / Corpus / Index / PurposeIndex を正準にし、profile の ScopePolicy に適合する index だけを選択する
9. 検索結果、関係記述、grouping、corpus、search result snapshot は canonical URI 集合を正本にする。ただし corpus / index の内部安定 key として既存 `SourceVaultObjectId` は維持する

この 9 点を固定すれば、当面は keyword + metadata + summary の低漏洩検索だけで開始し、運用しながら notebook cell、mail body、Eagle PDF page、artifact deposit、semantic search、data group 専用 RAG、Orchestrator subtask へ拡張できる。
