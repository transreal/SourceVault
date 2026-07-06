# SourceVault_packageapi API リファレンス

パッケージ: `SourceVault`` (コンテキスト: `SourceVault`PackageApiPrivate`` に実装)
ロード: `SourceVault.wl` が自動ロード (aux、wiring の後)。
仕様書: `sourcevault_directive_api_retrieval_spec_v0_3.md` (Inc1/Inc3) + `sourcevault_function_contract_wiring_spec_v0_3.md` (F6)
役割: 各パッケージの `api.md`/`api_*.md` を関数粒度 chunk に索引化し、決定的 ranking 検索・契約 view・関連候補・モデル粒度別描画を提供する。MCP には data adapter "packageapi" として露出 (sourcevault_search kinds ["packageapi"] / sourcevault_get view=contract 等)。chunk 本文は PublicDoc (PrivacyLevel 0、body も grant 不要)。

## 索引

### $SourceVaultPackageApiPackages
型: List, 既定 {"SourceVault", "claudecode", "ClaudeRuntime", "ClaudeOrchestrator", "NBAccess", "github"}
索引対象パッケージ。docs は `<base>/<pkg>_info/docs/api.md` + `api_*.md` (base = 本ファイルのディレクトリ)。

### SourceVaultPackageApiIndexBuild[pkg | All, opts]
chunk 索引を構築する。SourceMTimeToken が一致すれば skip (増分)。再構築は pkg 単位 atomic replace、消えた symbol は tombstone。chunk grammar: `## section` / `### symbol`、終端 = 次の ###/##/EOF、同名 symbol の連続 ### は 1 chunk に併合、aux と main の重複は aux 優先 + duplicateOf 記録。All 指定時は全 pkg を回して集約。
→ Association。pkg 指定: `<|"Status"->"Built"|"Skipped"|"Failed", "Pkg", "Chunks", "Tombstoned", "DocsBuildId"|>`。All 指定: `<|"Status"->"OK"|"Partial", "Built", "Skipped", "Failed"|>`
Options: `"Force"` -> False (True で token 一致でも強制再構築)

### SourceVaultPackageApiIndexStatus[]
pkg 別の chunk 数 / DocsBuildId / StaleDocs / BuiltAt。
→ Association

### SourceVaultPackageApiChunks[pkg]
pkg の全 chunk (未構築なら自動構築)。
→ List

## 解決・検索

URI: `sv://packageapi/<opaqueId>`、opaqueId = stableHash(pkg, symbol, auxName) を 16 桁 hex に切詰め — 世代非依存 (再索引しても不変、実パス・layout は URI から推測不能)。

### SourceVaultPackageApiResolve[symbol]
symbol 名から chunk を返す (全 pkg 横断)。deprecated alias (契約 Supersedes) は正準 symbol に解決し `"ResolvedFromAlias"` を付す。契約があれば `"HasContract"`/`"AuditStatus"` を遅延装飾 (audit 失敗は Freshness "StaleContract")。
→ Association | Missing["NotFound", symbol]

### SourceVaultPackageApiSearch[query, opts]
決定的 ranking (R-spec §8.2) で chunk を検索する。
→ List of `<|"Symbol", "Uri", "Pkg", "AuxName", "Section", "Kind", "Score", "Rank", "Reasons", "Freshness", "Signature"|>`
Options: `"MaxResults"` -> 10, `"MinScore"` -> 3. (これ未満の score は捨て、0 件を許す = 無関係注入をしない), `"Packages"` -> All (canonical 名を大小無視で解決、不明は無視。指定した pkg のみ ensure して探索), `"ExpandRelated"` -> False (True で各 hit に "Related" を Related 上位 5 件で付す)

採点 (加算):
- 強加点 1 SymbolExactInQuery +12 (symbol 名が query に完全包含) / QueryInSymbol +8 (query 長≥5 かつ symbol に包含)
- 強加点 2 AliasCanonical +9 (legacy alias 一致 → 正準 symbol を上位)
- 強加点 3 AuxKeywordMatch +3 (aux keyword 一致、claudecode `$ClaudePackageAuxKeywordMap` 弱結合。aux task-match を main より上位に)
- トークン加点: query を acronym-aware に語分割 (camelCase/連続大文字/数字境界。連続大文字は 1 語に保つ: "NBAccess"→{nb,access})、stopword と短語 (3 文字未満、ただし wl/nb/id/ui/ai は許可) を落とし、symbol トークンと OR 一致 — TokenExact +5 (package 名トークンは非弁別的なので +1) > TokenPrefix +2 > TokenSub +1 (4 文字以上のみ) > SectionMatch +0.5
- 弱加点 BigramOverlap ≤+4: whole-query bigram は ASCII 語を全く含まない query (Japanese/全 stopword 等) のフォールバックのみ。ASCII 概念 query は token 採点に委ねる (source/vault 部分一致の一律ノイズを避ける)

並びは決定論 tie-break で安定: exact/alias tier > Score 降順 > exact 数 > function > variable > 明示 Packages の list 順 (固定 bias なし) > Fresh > symbol 長 > 名前。

### SourceVaultPackageApiRelated[symbolOrUri, opts]
関連・類似 API の ranked 候補 (W-spec §8.2)。symbol/URI どちらでも受ける。Relation と固定重み: Composable (5、契約の出力ポートが相手の入力に DomainKind/MediaKind で適合=決定的) > AliasCanonical (4.5、自分の deprecated alias) > UseInsteadOf (4) > SameCapability (3、CapabilityTags 共有) > SameSection (2、同 section+同 SourceFile) > RequiresNeighbor (1.5、Requires 共有) > SimilarUsage (1、本文 bigram 近傍・同 pkg 上位)。
→ List of `<|"Symbol", "Uri", "Relation", "Score", "Reason"|>`
Options: `"MaxResults"` -> 8

## 取得・描画

### SourceVaultPackageApiGet[uriOrSymbol, opts]
chunk の projection。
→ Association | Missing | Failure["ContractsUnavailable"|"InvalidView"]
Options: `"View"` -> "summary" (既定、tier 描画の要約 "Text") | "metadata" (本文なし、Body/SectionPreface/Signatures を除いた meta) | "body" (chunk 全文) | "contract" (契約 registry の投影 + AuditStatus。評価可能式は含めない = W10、InitializedQRef は名前のみ)、`"Tier"` -> Automatic (=Expert) | "Expert" | "Guided" | "Scaffolded"

tier (W-spec §8.3、索引は 1 本・描画のみ変更):
- Expert: signature + 要約 + Returns 行 + Options 行
- Guided: + Requires (契約由来) + 本文抜粋 (既出の要約/Returns/Options を除いた ≤600 字)
- Scaffolded: + ExplainCallContract (allowed options のみ明示) + `SourceVaultEnsureInitialized` 前置きテンプレート + 「option を発明するな」ガード (小型ローカルモデル向け)

freshness: Fresh | StaleDocs (pkg ソース .wl が docs より新しい) | StaleContract (契約 audit 失敗)。

## MCP 露出 (SourceVault_mcp.wl 側)

data adapter "packageapi" (Kinds {"packageapi", "api"}):
- `sourcevault_search` kinds ["packageapi"] → 上記 Search の結果 (snippet = Expert 要約)
- `sourcevault_get uri` → summary projection / `view=body` は **grant 不要** (BodyGrantRequired->False、PublicDoc) / `view=contract` / `view=scaffolded` / `view=guided`
- `sourcevault_catalog` に自動掲載。索引未ロード時は available=false ("SourceVault_packageapi.wl required")