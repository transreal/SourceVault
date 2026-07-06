# SourceVault_packageapi API リファレンス

## 概要
SourceVault_packageapi は各パッケージの `<pkg>_info/docs/api.md` + `api_*.md` を `## section` / `### symbol` 単位で chunk 化し、索引・検索・関連提示・契約ビューを提供する kernel 層モジュール (F6)。仕様は R-spec (sourcevault_directive_api_retrieval_spec_v0_3.md) と W-spec (sourcevault_function_contract_wiring_spec_v0_3.md) に準拠。MCP 露出は SourceVault_mcp.wl 側 (R3) で行い、本ファイルは kernel API のみ。context は `SourceVault`\`、private helper は `SourceVault`PackageApiPrivate`\` 文脈に隔離する。

設計の要点:
- chunker: 終端 = 次の `###`/`##`/EOF。section preface (`##` と最初の `###` の間) は metadata へ。同名 symbol の連続 `###` 見出しは 1 chunk に signature 併合。aux (`api_*.md`) と main (`api.md`) の重複は aux 優先で `DuplicateOf` を記録。
- URI: `sv://packageapi/<opaqueId>`。opaqueId = `stableHash(pkg, symbol, auxName)` の先頭 16 hex。世代非依存で実パス・layout は URI から推測不能 (R-spec §7.2)。
- 索引: pkg 単位 atomic replace。`SourceMTimeToken` 一致で skip する増分再構築。`IndexSchemaVersion`/`ChunkerVersion`/`DocsBuildId` を保持。消えた symbol は tombstone (R-spec §7.1)。
- 検索: R-spec §8.2 の決定的 ranking。関数名完全一致 > legacy alias 一致 > aux keyword 一致 > acronym-aware token OR 一致 > (token 無し query のみ) whole-query bigram。閾値未満は 0 件を許す (無関係注入をしない)。tie-break は決定論。
- view: `metadata` | `summary` | `body` | `contract` (W-spec §8.1)。契約は registry が正で、評価可能式は投影しない (W10)。
- related: `Composable` (契約から決定的) / `AliasCanonical` / `UseInsteadOf` / `SameCapability` / `SameSection` / `RequiresNeighbor` / `SimilarUsage`。
- tier: `Expert` / `Guided` / `Scaffolded` (W-spec §8.3)。索引は 1 本で描画のみ変える。Scaffolded は `SourceVaultEnsureInitialized` 前置きテンプレート + allowed options のみ。
- freshness: `Fresh` / `StaleDocs` (source .wl が docs より新しい) / `StaleContract` (契約 audit 失敗、W-spec §8.4)。
- privacy: chunk 本文は PrivacyLevel 0 (PublicDoc、R-spec P4)。

既定索引対象パッケージ: SourceVault, claudecode, ClaudeRuntime, ClaudeOrchestrator, NBAccess, github。契約連携が有効なのは SourceVault_contracts / SourceVault_wiring がロードされ `SourceVaultFunctionContract` が定義されているときのみ (弱結合、未ロードでも動作する)。

## 変数
### $SourceVaultPackageApiPackages
型: List of String, 初期値: {"SourceVault", "claudecode", "ClaudeRuntime", "ClaudeOrchestrator", "NBAccess", "github"}
索引対象パッケージの既定リスト。各 pkg の docs は `<base>/<pkg>_info/docs/api.md` + `api_*.md` (base = 本ファイルのディレクトリ = MyPackages)。未定義時のみ初期化されるので、ロード前に上書きすれば尊重される。

## 索引の構築・状態
### SourceVaultPackageApiIndexBuild[pkg, opts]
package API chunk 索引を構築する。`pkg` は String または `All`。`All` は既定リスト全体を順に build。`SourceMTimeToken` (docs ファイル群の mtime) が一致し版も同じなら skip (増分)。再構築は pkg 単位 atomic replace で、旧索引にあり新索引に無い symbol は tombstone 化 (R-spec §7.1)。docs が無ければ Failed。
→ Association。単一 pkg: `<|"Status" -> "Built"|"Skipped"|"Failed", "Pkg", "Chunks", "Tombstoned", "DocsBuildId"|>`。`All`: `<|"Status" -> "OK"|"Partial", "Built", "Skipped", "Failed"|>` (pkg 名リスト)
Options: "Force" -> False (True で token 一致でも強制再構築)

### SourceVaultPackageApiIndexStatus[] → Association
pkg 別に `<|"Chunks" (chunk 数), "DocsBuildId", "StaleDocs", "BuiltAt"|>` を返す。索引済み pkg のみ含む。

### SourceVaultPackageApiChunks[pkg] → List of chunk Association
pkg の全 chunk を返す。索引未構築なら自動構築 (iPAEnsureIndex)。chunk は `"Symbol"/"Signatures"/"Section"/"Kind"/"Pkg"/"AuxName"/"SourceFile"/"Body"/"Uri"/"OpaqueId"/"Signature"/"SectionPreface"/"ReturnsLine"/"OptionsLine"/"Freshness"` 等を持つ。

## 解決・検索
### SourceVaultPackageApiResolve[symbol] → chunk Association | Missing["NotFound", symbol]
symbol 名から chunk を全 pkg 横断で解決する (全 pkg 自動 ensure)。deprecated alias (契約 `Supersedes` 由来の alias index) は正準 symbol の chunk に解決し `"ResolvedFromAlias" -> 元の名` を付す。契約が利用可能なら `iPADecorate` で `HasContract`/`AuditStatus`/`Freshness` (StaleContract 判定) を付す。

### SourceVaultPackageApiSearch[query, opts]
決定的 ranking (R-spec §8.2) で chunk を検索する。加点構造: 強加点=関数名完全一致 (query 内に symbol 名) > QueryInSymbol > legacy alias 一致 (正準を上位) > aux keyword 一致、token 加点=query を acronym-aware に語分割 (camelCase/連続大文字/数字を分割、stopword と短語を除去) し symbol token と OR 一致 (完全一致 > prefix > substring。package 名 token は非弁別的で弱加点)、弱加点=ASCII 語を全く含まない query (Japanese 等) のみ whole-query bigram。`MinScore` 未満は 0 件を許す。並びは決定論 tie-break で安定 (exact/alias tier > Score > exact 数 > function>variable > 明示 Packages の list 順 > Fresh > 名前長 > 名前)。
→ List of `<|"Symbol", "Uri", "Pkg", "AuxName", "Section", "Kind", "Score", "Reasons", "Freshness", "Signature", "Rank"|>` (ExpandRelated 時は "Related" も)
Options: "MaxResults" -> 10, "MinScore" -> 3. (閾値), "Packages" -> All (canonical 名を大小無視で解決、不明は無視。指定時はその pkg のみ ensure & 検索), "ExpandRelated" -> False (True で各結果に "Related" を MaxResults 5 で付与)

## 関連候補
### SourceVaultPackageApiRelated[symbolOrUri, opts]
関連・類似 API の ranked 候補を返す (W-spec §8.2)。`sv://` URI または symbol 名を受ける。契約由来 (決定的): `AliasCanonical` (自分の deprecated alias = `Supersedes`)、`UseInsteadOf` (契約の同名フィールド)、`Composable` (自分の出力ポートが相手の入力ポートに DomainKind/MediaKind で適合)、`SameCapability` (`CapabilityTags` 共通)、`RequiresNeighbor` (`Requires` 共通)。chunk 由来: `SameSection` (同 section かつ同 SourceFile、最大 4)、`SimilarUsage` (同 pkg で本文 bigram overlap ≥ 15、上位 3)。同 symbol・同 relation の重複は排除。
→ List of `<|"Symbol", "Uri", "Relation", "Score", "Reason"|>` (Score 降順)
Options: "MaxResults" -> 8
固定重み: Composable 5. > AliasCanonical 4.5 > UseInsteadOf 4. > SameCapability 3. > SameSection 2. > RequiresNeighbor 1.5 > SimilarUsage 1.

## chunk 取得・tier 描画
### SourceVaultPackageApiGet[symbolOrUri, opts]
chunk を projection して返す (W-spec §8.1)。`sv://` URI または symbol 名を受ける。metadata は Body/SectionPreface/Signatures を除いた chunk。summary は tier に応じた要約テキスト。body は chunk 全文。contract は契約 registry の投影 (評価可能式を含めず `InitializedQRef` は名前のみ = W10、`AuditStatus`/`Freshness`/`Uri` 付き)。
→ Association | Missing["NotFound"|"NoContract", ...] | Failure["ContractsUnavailable"|"InvalidView"]
Options:
  "View" -> "summary" ("metadata" | "summary" | "body" | "contract")
  "Tier" -> Automatic (=Expert) | "Expert" | "Guided" | "Scaffolded" (W-spec §8.3)
tier 描画: Expert は signature + 要約 + Returns + Options 行のみ。Guided/Scaffolded は加えて `Requires` と body 抜粋 (最大 600 字、既出行は重複除去)。Scaffolded はさらに `SourceVaultExplainCallContract` 説明・`SourceVaultEnsureInitialized["sym"]` テンプレート・「列挙された option のみ使え」注記を付す。
例: SourceVaultPackageApiGet["SourceVaultPackageApiSearch", "View" -> "contract"]
例: SourceVaultPackageApiGet["sv://packageapi/ab12cd34ef567890", "View" -> "summary", "Tier" -> "Scaffolded"]