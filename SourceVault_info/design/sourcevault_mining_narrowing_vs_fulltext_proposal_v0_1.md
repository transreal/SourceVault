# SourceVault マイニングによる対象絞り込みの活用と改善提案 v0.1

作成日: 2026-07-05
対象読者: SourceVault / claudecode ハーネス保守、および Codex / Claude Code へタスクを投げる運用者
関連: `SourceVault_packageapi.wl`、`SourceVault_mcp.wl`、`SourceVault_info/docs/api_packageapi.md`、`SourceVault_info/docs/api_mining.md`、`ドキュメント/sourcevault_llm_execution_log_ingest_mcp_spec_v0_1.md`（比較対象タスクの成果物）

本版 (v0.1r2): レビュー r1・r2 を反映。r1 = §1 に「マイニングの段（first-stage / get / rerank / fallback）の分離」、§4-A に往復コスト予算・鮮度(StaleDocs)・`sourcevault_get` 露出差、§4-B の短語 precision 厳格化・tie-break・受け入れ表、§4-D「MCP adapter に package scope」を追加。r2 = §4-D に B-1(cold start でも scoped ensure)・B-2(filter を tool schema/catalog に広告)・B-3(`Packages` 正規化と UnknownPackage 警告)、§4-B に B-4(packageRank に固定 bias を持たせない)・B-5(exact/alias tier 保護)・B-6(acronym-aware tokenizer)・B-7(具体順位 acceptance + unit/smoke 二層化)、§4-E(Open Questions への決定) を追加。

## 0. 背景と問い

Codex に「各 PC のローカル実行ログを SourceVault に ingest し、全 PC の LLM が MCP 経由で参照できるようにする仕様を作れ」というタスクを投げた。その走り出しのログを見ると、Codex は **作業ディレクトリ全体に対する全文検索（`rg --files` → `rg -n "SourceVault|ClaudeOrchestrator|MCP|mcp|log|ログ|ingest|..."`）** を数回かけて対象を絞り込んでいた。

問い: **SourceVault MCP が提供するマイニングフレームワーク（特に `packageapi` アダプタ）で対象をより確実に絞り込めれば、その使用を指示して作業パフォーマンスを上げられないか。** 本書は全文検索と MCP マイニングを実測比較し、結論と改善案を示す。

## 1. 結論（先に要約）

- **「うまく打てば」MCP マイニング（`sourcevault_search kinds=["packageapi"]`）は全文 rg を精度・往復数で圧倒する。** 単一概念トークンで引くと、関数粒度・シグネチャ付き・ノイズ 0 で、Codex が最終的に §16 で挙げた実 API にそのまま着地する。
- **しかし「素朴に打つと」現ランカーは全文 rg に負ける。** エージェントが既定で打つ「自然文／キーワード束（regex 交替）」クエリは、現ランカーがちょうど苦手とし、`$SourceVault…` 変数の無関係な羅列を返す。根本原因はランキング実装上の仕様である（§3）。
- **したがって推奨は次の段（stage）ごとに分けて実施:**
  1. **運用（ディレクティブ/スキル・P0）**: 「対象を絞り込む」局面ではまず `packageapi` を **単一概念トークンで反復** し、`sourcevault_get view=body`（grant 不要）で本文確認、最後に grep/Read へ **予算付きフォールバック** する手順を明文化する（§4-A）。
  2. **first-stage ランカー改善（P1）**: `SourceVaultPackageApiSearch` を **クエリのトークン分割 + トークン単位 OR スコアリング + 決定論 tie-break** に拡張する（§4-B）。決定論と「閾値未満は 0 件」の fail-closed 性は維持する。
  3. **MCP adapter 引数拡張（P1）**: MCP `packageapi` adapter が現在 `query`/`limit` しか受けず **package scope を渡せない**ため、`filters.packages` 等を通す（§4-D）。これが無いと 4-A で「SourceVault と ClaudeOrchestrator に絞れ」と指示しても MCP 検索は全 package 横断のまま。
- **段の分離（重要な用語整理）**: 本書の「マイニング」は次の 4 段に分解される。今回の初動 narrowing の改善対象は **first-stage の 1〜2 段のみ**であり、`SourceVaultMinedSearch` / `SourceVaultMiningRerank` は改善対象ではない（下記 3 段目の rerank であって、候補発見を広げない）。
  1. first-stage 検索: `SourceVaultPackageApiSearch` / MCP `packageapi` adapter ← **改善対象**
  2. 二次取得: `sourcevault_get view=body|contract|guided|scaffolded`
  3. rerank: `SourceVaultMinedSearch` / `SourceVaultMiningRerank`（候補集合は `SearchFn` の返却範囲に限定。初回検索で漏れた候補は救えない）
  4. fallback: filesystem grep / （将来）code-symbol 索引
- **速度の但し書き**: 本実測で `sourcevault_search` は 1 回あたり数十秒〜約 2 分かかる場合があった（環境・kernel 状態依存、index rebuild 含む）。したがって本提案の主効果は **件数削減・往復（推論ステップ）削減・context 汚染回避** であって「常に wall time が速い」ではない。運用は §4-A の予算とフォールバックで担保する。
- なお、`search` アダプタ（取込済みコンテンツ索引）は今回の「ログ」概念に対して **0 件** を返した。これはマイニングの欠陥ではなく、**ログがまだ ingest されていない**（＝Codex タスクが埋める穴）ことを意味する（§5）。

## 2. 実測比較

タスク上の絞り込み目標: 「PC ごとログ ingest → MCP 共有」に関係する約 6 サブシステム（webingest rollup / mcp adapter registry / observability `$LLMCallLog` / servicemanager machine 別 runtime / claudecode Codex ログ / core append-only）。

### 2.1 全文検索（Codex の実際の方式）

| 指標 | 実測 |
|---|---|
| `rg "SourceVault\|ClaudeOrchestrator\|MCP\|mcp\|log\|ログ\|ingest\|Ingest\|packageDirectory"`（*.wl 全体） | **13,180 ヒット / 200+ ファイル（上限打切）** |
| ノイズ内訳 | `bak\`、`test codes\`、`_info\history\`、`GithubRepositories\`（ミラー重複）、無関係パッケージ（`fujikiCA` / `情報工学科成績` / `CellularAutomata` / `Cerezo` 等）を大量に含む |
| `SourceVault*.wl` に絞り `log\|ログ\|ingest` のみ | 1,418 ヒット / 48 ファイル（それでもミラー重複と test codes を含む） |
| 到達コスト | Codex ログ上、`Get-ChildItem` / `rg` を十数回反復して手動で絞り込み。往復・トークン消費が大きい |

全文検索は **recall は最大（取りこぼさない）が precision が極端に低い**。対象言語（.wl）のソース本文・on-disk パスまで拾える点は本質的な強み。

### 2.2 MCP マイニング（`packageapi`）— 単一概念トークンで駆動した場合

| クエリ | 上位ヒット（抜粋） | 評価 |
|---|---|---|
| `"ingest"` | `SourceVaultIngestSurveyResult`, `SourceVaultIngestWait`, `SourceVaultRegisterWebIngestHook`, `$ClaudeSourceVaultIngestConnector`, `SourceVaultMiningWebIngest*` | 完璧。関数粒度・シグネチャ付き・ノイズ 0 |
| `"runtime machine"` | `SourceVaultServiceRuntimeDir`（`<CoreRoot>/runtime/<MachineName>/services/<id>` = §4.2 で Codex が必要としたパスそのもの）, `SourceVaultStartService`, `SourceVaultDiagnosticsCloudSend`（inter-machine heartbeat/wakeup）, `showLLMCallLog`（`$LLMCallLog` ビューア = §1.4/§6.2） | 上位が核心に直撃。一部ノイズ混入 |
| `"RegisterMCPServer"` | `SourceVaultRegisterMCPDataAdapter`, `SourceVaultResolveMCPDataAdapter`（= §8.1 adapter 登録そのもの） | 完璧 |

**3 回の呼び出しで、Codex が §16 で列挙した実 API に、フィルタリングなしで直接着地した。** 各結果はシグネチャ＋要約を同梱し、`sourcevault_get view=body`（grant 不要の PublicDoc）で全文チャンクへ即展開できる。

### 2.3 MCP マイニング — 素朴に駆動した場合（＝退行）

| クエリ | 結果 |
|---|---|
| `"ingest log runtime source into vault"`（自然文） | `$UseLegacyStategraph`, `$SourceVaultWiringLLM`, `$SourceVaultWebSearch…` … と **概ねアルファベット逆順の `$` 変数の羅列**。3 つの異なる自然文クエリがほぼ同一の無関係集合を返した |
| `"log"`（短い単一語） | **0 件** |

つまり **エージェントが既定で打つクエリ形（Codex が rg に投げたのと同じ「キーワード束」）を、現ランカーはちょうど処理できない**。これが「素朴に MCP を使わせると全文検索に負ける」核心である。

## 3. 退行の根本原因（コード実体で確定）

`SourceVault_packageapi.wl` の `SourceVaultPackageApiSearch`（404-465 行）を精読した結果、退行は実装上の必然:

1. **クエリはトークン分割されず、1 個の不透明文字列として扱われる**（413 行 `qBigrams = iPABigrams[query]` は空白込みの全文 bigram）。term 単位のマッチングが存在しない。
2. **substring 加点に長さゲート**: `StringLength[query] >= 5 && StringContainsQ[symLower, qLower]`（426-428 行）。`"log"`（3 文字）は substring パス自体が無効。
3. **bigram 加点に閾値** `ov >= 3`（447 行）。`"log"` の bigram は {"lo","og"} の 2 個で閾値未満 → スコア 0 → `MinScore 3.` 未満 → 0 件（実測と一致）。
4. **多語クエリの希釈**: 長い自然文は汎用 bigram（"in","er","st","re"…）が本文先頭 200 字（445-446 行）と偶然重なり、多数チャンクが薄く `ov>=3` を超える。スコアが団子状に並び、`Take[Reverse@SortBy[results, Score]]`（464 行）のタイ順＝事実上の逆インデックス順（`$SourceVault…` 群）が表面化する。

強加点（完全一致 +12 / substring +8 / alias +9）は **「関数名を既に知っている」場合に最適化** されており、「概念で探す」ディスカバリ用途には設計上向いていない。

## 4. 提案

### 4-A. 運用: 「絞り込み」局面のクエリ手順を明文化（コード変更なし・即効）

Codex / Claude Code 向けディレクティブ（またはスキル）に、以下の **絞り込みプロトコル（MCP first, grep bounded fallback）** を追加する:

> 本システム（SourceVault / claudecode / ClaudeOrchestrator / NBAccess）の関数・API を探す局面では、いきなり全文検索しない。まず MCP で絞る:
> 1. `sourcevault_catalog` で `packageapi` の可用性を **セッション最初の 1 回だけ** 確認する。
> 2. `sourcevault_search kinds=["packageapi"]` を **1 呼び出し 1 概念トークン**、合計 **3〜6 トークンまで**（各 `limit` は 5〜10）引く（例: `ingest` / `rollup` / `adapter` / `mcp` / `runtime` / `machine` / `snapshot` / `privacy` / `log`）。自然文・`A|B|C` の交替束を 1 クエリに詰めない。同一クエリ結果はセッション内で使い回す（再問い合わせしない）。
> 3. package を絞れる場合は `filters.packages`（例 `["SourceVault","ClaudeOrchestrator"]`）を付ける（要 §4-D の adapter 拡張）。
> 4. 上位候補は URI と Symbol を記録し、`sourcevault_get uri view=body|contract|guided`（`packageapi` は grant 不要）で本文チャンクを取得して確定する。**`sourcevault_get` が tool として見えない**クライアントでは、search 結果の snippet / signature で候補を絞り、その file を Read へ移る。
> 5. 結果の `Freshness` が `StaleDocs` の候補は、api ドキュメントがソースより古い可能性があるので、当該実装ファイルを短く確認してから採用する。`Fresh` は原則そのまま一次候補にしてよい。
> 6. 次のいずれかのときだけ全文検索へフォールバックする: `packageapi` が扱わないもの（ソース本文の実装詳細、on-disk のログ/パス、未文書化シンボル）、候補が 0 件、StaleDocs が上位を占める、または MCP 応答が所定秒数を超える。フォールバックは広く撫でず `rg -g "SourceVault*.wl" -g "ClaudeOrchestrator*.wl"` のように **glob で境界を切る**。

この手順で、§2.2 の「うまく打った」精度を再現でき、Codex の十数回の rg 反復を数回の的確な MCP 呼び出しに置き換えられる。**まずこれを入れるのを最優先**（低リスク・即効・コード改修不要）。ただし前記の速度但し書きのとおり、往復時間の保険としてフォールバック条件（0 件 / StaleDocs 上位 / タイムアウト）を必ず併記すること。

### 4-B. コード改善: `SourceVaultPackageApiSearch` をトークン化する（本命）

現ランカーを、自然文・キーワード束でも機能するトークン単位 OR スコアリングへ拡張する。決定論と「閾値未満 0 件」の fail-closed 性は維持する。

要点（`SourceVault_packageapi.wl` 内の純関数改修、索引スキーマは不変・描画も不変）:

- **クエリとシンボルの両方を acronym-aware にトークン化する**（B-6）:
  - `iPAQueryTokens[query]`: 空白・句読点・`|`・`/`・`_`・`-`・camelCase 境界で分割。ストップワード（into, the, a, で, を… 最小限）を除去。**2 文字以下は原則捨てる**が、`wl`/`nb`/`id`/`ui`/`ai` 等の allowlist は別扱い。
  - `iPASymbolTokens[sym]`: シンボルを同様に分割するが、**連続大文字（acronym run）は 1 トークンとして保持**する（`LLM` / `MCP` / `API` / `PDF` / `NB`）。camelCase 単純 split で `LLM`→`l,l,m` に割れたり `NBAccess`→`nbaccess` のまま残ったりする退行を避ける。
  - 期待トークン（回帰で固定）: `$LLMCallLog` → {llm, call, log}、`NBAccess` → {nb, access}、`SourceVaultServiceRuntimeDir` → {source, vault, service, runtime, dir}。
- **各クエリトークン t をシンボルに対し独立採点し合算**（OR 意味）。**短語（<4 文字）の precision 低下を防ぐため、加点条件を厳格化する**:
  - t がシンボルトークンと **完全一致**（token-exact）／ camel-snake 分割語一致: 強加点。← `"log"` はここで `$LLMCallLog`・`showLLMCallLog` を拾う（`dialog`/`catalog` はトークン `dialog`/`catalog` であって `log` と token-exact しないので誤爆しない）。
  - シンボルが t で **始まる**（prefix）: 中加点。
  - t がシンボルの **substring**: **トークン長 >= 4、または aux keyword / section 一致がある場合のみ**弱加点（短い substring の無差別加点はしない）。
  - bigram は全文でなく **トークン単位**で取り、本文先頭とのオーバーラップは補助（希釈防止のため上限を厳しめに）。
- **短語（`log` 等）は substring より synonym/aux 経由を主とする**: 既存 `iPAAuxKeywordBonus`（`ClaudeCode`$ClaudePackageAuxKeywordMap` 参照、386-398 行）に概念→シンボルの弱マップを足す（例: `log` → `showLLMCallLog` / `$LLMCallLog`、`machine` → `ServiceRuntimeDir` / `MachineTag`、`adapter` → `RegisterMCPDataAdapter`）。**新機構を作らず既存フックを拡張**する。
- **exact / alias / canonical hit は tier で最優先し、トークン加点では追い越せないことを保証する**（B-5）。トークン単位 OR を単純加算にすると、長い自然文で弱一致を多数集めた候補が `SymbolExactInQuery +12` / alias +9 の hit を超え得る。対策は次のどちらかを実装規則として明記する（本提案は前者を推奨）:
  - **推奨: tier 化** — `HasExactOrAlias` を真偽の第 1 tier キーにし、exact/alias 群はトークンスコアに関係なく常にトークンのみ群より上位（下記 tie-break tuple の先頭に置く）。
  - 代替: トークン加点の総量に上限を設け、+9 を超えないよう clip する。
- **`MinScore` の「閾値未満は 0 件」を維持**（汎用語のみ・無関係注入をしない fail-closed）。
- **`Reasons` にトークン別の寄与を残す**（例 `TokenExact(log)` / `TokenPrefix(runtime)` / `SectionMatch(mcp)`）。回帰テストで説明可能にする。

**決定論 tie-break（必須）**: 現状 `Reverse @ SortBy[results, Score]`（464 行）は同点時に insertion order へ引っ張られ、hit 数が増えると `$SourceVault…` 群が浮く。自然文対応で同点が増えるため、次の **明示 tuple** で安定ソートする（実装はこの tuple をそのまま `SortBy` キーにする）:

```
{ HasExactOrAlias(1|0) 降順,   (* B-5: exact/alias tier を最優先 *)
  Score 降順,
  exactCount(exact/alias/token-exact Reason 数) 降順,
  kindWeight(function=2 > variable=1 > section-only=0) 降順,
  packageRank(下記) 昇順,
  freshnessWeight(Fresh=0 > StaleDocs=1) 昇順,
  -StringLength[symbol],        (* 短い名を上位 *)
  symbol(辞書順) }              (* 最終 stable key・決定論保証 *)
```

- **packageRank は固定 bias を持たせない**（B-4）。`SourceVault` / `ClaudeOrchestrator` を常に主要扱いすると `NBAccess` / `github` 調査タスクで不自然に偏る。規則:
  - `Packages` option / `filters.packages` が明示された場合、**その list order** を packageRank とする。
  - クエリトークンに package 名（`nbaccess` 等）が出た場合だけ、その package を soft boost。
  - それ以外は packageRank を一律（priority なし）にし、`$SourceVaultPackageApiPackages` の既定順で安定化する。

受け入れテスト（回帰で固定・「上位」でなく具体順位で判定・B-7）:

| query | 期待（具体判定） |
|---|---|
| `log` | top 5 に `showLLMCallLog` または `$LLMCallLog` を含む。`catalog` / `workflowcatalog` は top 5 に**入らない**。0 件不可 |
| `runtime machine` （`filters.packages=["SourceVault"]`） | top 3 に `SourceVaultServiceRuntimeDir` |
| `ingest` | top 5 に ingest 系 API（`SourceVaultIngestSurveyResult` / `IngestWait` 等） |
| `ingest log runtime source into vault` | ingest/runtime/log 系が `$SourceVaultWeb…` 群より上位 |
| `the and into` | count 0 |
| `SourceVaultPackageApiSearch` | exact hit が **1 位**（B-5 tier の確認） |
| `RegisterMCPServer` | top 3 に `SourceVaultRegisterMCPDataAdapter` |
| 不正 package filter（例 `filters.packages=["Nope"]`） | result 0 **かつ** `Warnings` に UnknownPackage が返る（静かな 0 件にしない・B-3） |
| （MCP メタ） | `sourcevault_search` の tool schema または `sourcevault_catalog` の packageapi entry に `packages` filter が見える（B-2） |

テストの二層化（B-7）:

- **unit test**: 固定 mock index（docs 鮮度に依存しない）に対し、ランキング・tokenizer・tie-break・正規化の決定論を検証する。
- **smoke test**: 実 docs に対し `sourcevault_search` / MCP 経由で上表を確認する（鮮度で揺れうるので上位集合の包含で判定）。

**local 関数と MCP 経由の両方**で確認するのは、local だけ直って **MCP adapter が古い引数しか渡さない**取りこぼし（§4-D）を防ぐため。

これにより **素朴に駆動されたエージェントでも精密ヒットを得る**ようになり、4-A への依存度が下がる（保険の二重化）。

### 4-B'. 設計判断: 汎用ランカーを維持し、タスク特化型は採らない

検討課題: `SourceVaultPackageApiSearch` に「タスクドメイン」オプション（例 `"TaskDomain" -> "ingest"|"mcp-adapter"|"logging"|...`）を足し、**ドメイン別に出力を分ける特化型**にすべきか。

**判断: 採らない。汎用ランカーを 4-B で直し、ドメインは汎用ランカー上の「任意のソフトバイアス」としてのみ持つ。出力（結果リストの契約）は分けない。**

理由（層の分離）: 今回の退行は **クエリ理解の欠陥（非トークン化・長さゲート・bigram 閾値）= 汎用パスの正当性バグ**である。`TaskDomain` は絞り込み（プレフィルタ／バイアス）機構であって **クエリ理解そのものは直さない**。両者は解く問題が別レイヤ。

- **汎用パスを直さずに特化を足すと、列挙外ドメインのクエリはゴミを返し続ける。** 特に spec-impl のグラウンディング（`specimpl-api-grounding-failclosed-fix`）は **生成コード中の任意シンボル** を照合する用途で、ドメイン列挙が原理的に不可能。汎用ランカーの正しさへの依存は外せない。
- **呼び出し側がドメインを知っているなら、それはトークンとしてクエリに渡せる。** `TaskDomain -> "ingest"` と書けるなら query に `"ingest"` と書けば同じ。ドメイン enum の付加価値は「シノニム展開」だけで、それは既存 `iPAAuxKeywordBonus`（`$ClaudePackageAuxKeywordMap`、386-398 行）が担う場所 = 4-B が拡張する場所。**別オプション化は不要。**
- **MCP 表面の頑健性**: `sourcevault_search` は Codex / クラウドモデルなど異種クライアントへ露出する。`taskDomain` enum を足すと、値を誤選択したクライアントは **汎用クエリより悪いフィルタ結果**を得る。自由文クエリ + 良い汎用ランカーの方が多様なクライアントに堅い。
- **決定論・単一ソース原則との齟齬**: タスク分類表は api ドキュメントとは別の第二の真実源で、新関数ごとのタグ付けが必要になり必ずドリフトする。SourceVault の event-sourced / deterministic / fail-closed 思想に逆行。汎用トークン化は **ドキュメント自身からランキングを導出**するのでドリフトしない。
- **「出力を分けたい」動機の多くは実は描画（view）の話**: 「実装タスクは contract、レビューは signature だけ」等の差は既に `sourcevault_get` の `view=contract/scaffolded/guided` と `Tier` で解決済み。ランキングと描画を混同しない。

**ドメインを持たせる正しい形（ソフトファセット・任意）**:

- 既存 `"Packages"` オプション（401 行）でパッケージ scope を渡す（ハードだが既存・安全）。
- チャンクの `"Section"`（`## section`）一致に **加点（ハードフィルタでなく additive boost）** する任意 `"Facet"` を足す。recall を落とさず決定論も保つ。
- ドメイン→シンボルのシノニムは **別パスにせず** 4-B のトークン採点へ畳み込む。

結果として「1 本の決定論的ランク済みリスト」という契約は割らず、scope は任意のソフト指定に留める。

**タスク特化が正当化される条件（現時点で該当なし）**: 「少数・安定・高頻度のタスク型で、トークン化後も汎用ランカーが計測上劣り、かつ異なる出力射影が要る」場合に限る。本コードベースの最有力候補 spec-impl グラウンディングですら、無限トークン照合ゆえ逆に汎用を要求する。

### 4-C. （任意・中規模）ディスカバリの穴を埋める新索引

`packageapi` は各パッケージの `api*.md` **のみ** を索引する。したがって:

- **文書化されていないシンボル / 実装本文の所在** は `packageapi` では引けず、grep/Read が今も必要。当面は 4-B + grep フォールバックで十分と判断する。
- 将来、ソース定義（`f[...] :=` の LHS シンボル）を軽量索引化する **「code-symbol」アダプタ** を足せば、「どのファイルの何行でこのシンボルが定義/使用されるか」を MCP で引けるようになる。ただし優先度は低く、4-A/4-B の後でよい。

一方、今回の Codex タスクが対象とする **実行ログそのもの** の欠落（§5）は、Codex が書いた `llmlog` アダプタ仕様（`sourcevault_llm_execution_log_ingest_mcp_spec_v0_1.md`）が埋める。これは本書のマイニング改善とは独立の作業。

### 4-D. MCP `packageapi` adapter に package scope / filters を通す（P1）

現状 `SourceVault_mcp.wl` の `iSVPackageApiAdapterSearch`（2961-2980 行）は `spec` から `query` と `limit` **しか**取り出さず、`SourceVault`SourceVaultPackageApiSearch[q, "MaxResults" -> lim]` を呼ぶだけである。したがって MCP 経由では `Packages`（4-B' の soft facet）も view も指定できず、**4-A で「SourceVault と ClaudeOrchestrator に絞れ」と指示しても検索は全 package 横断のまま**になる。local 関数だけ 4-B で直しても、MCP クライアント（Codex / クラウドモデル）からは恩恵が届かない。

改修（`spec["filters"]` を読んで local 関数へ委譲する。最小は `packages`）:

```wl
iSVPackageApiAdapterSearch[spec_Association, accessRequest_Association] :=
  Module[{q, lim, pkgs, hits, filt},
    If[!iSVPackageApiAvailableQ[], Return[{}]];
    q = Lookup[spec, "query", ""];
    If[!StringQ[q] || StringTrim[q] === "", Return[{}]];
    lim = Lookup[spec, "limit", 10];
    filt = Lookup[spec, "filters", <||>];
    pkgs = Lookup[filt, "packages", Lookup[filt, "package", All]];
    hits = Quiet @ Check[
      SourceVault`SourceVaultPackageApiSearch[q,
        "MaxResults" -> lim, "Packages" -> pkgs], {}];
    (* 以降は既存の row/snippet 整形をそのまま *)
    ...
  ];
```

段階:

- **最小**: `filters.packages` → `"Packages"`。これだけで package scope 指示が MCP から効く。
- **任意**: `filters.symbolKind`（function / variable 等の post filter）、`filters.freshness`（Fresh / StaleDocs の soft warning または filter）、`return.maxCharsPerResult`（snippet 長調整）。
- **不変条件**: 未知 filter は無視（fail-open な絞り込みでなく、指定が無ければ従来どおり全 package = 後方互換）。PublicDoc の grant 不要性・既存 view 経路は変えない。

**B-1: cold start でも scoped ensure にする（package scope を初動性能へ効かせる）**。現 `SourceVaultPackageApiSearch` は 407 行で無条件に `iPAEnsureAll[]`（= 全 package を `iPAEnsureIndex` で ensure、315-316 行）を呼ぶため、`Packages` を指定しても cold start では全 package の index 構築が走り、**scope が結果絞り込みにしか効かず「初動を速くする」目的に半分しか効かない**。改修:

- `Packages` option を **`iPAEnsureAll[]` より先に正規化**し、対象 package だけ `iPAEnsureIndex /@ pkgs`（311 行の既存 per-package ensure を再利用）。
- `All` のときだけ従来どおり `iPAEnsureAll[]`。
- 役割分担を明記: `SourceVaultPackageApiIndexBuild[All]` / `SourceVaultPackageApiIndexStatus[]` は**全体 warmup / 状態確認**用、通常検索は **package-scoped ensure** 用。

**B-2: filter を tool schema / catalog に広告する（LLM が発見できるようにする）**。現 `sourcevault_search` の `filters` 説明は `"accessLevelMax, dateFrom, dateTo, ext, tags, etc."`（`SourceVault_mcp.wl:3175-3176`）で packageapi 固有 filter が見えない。実装だけ受けても、プロンプトで毎回教えない限り自然には呼ばれない。改修:

- `sourcevault_catalog` の packageapi entry に `filterKeys`（`packages` / `package` / `symbolKind` / `freshness`）と `examples`（`filters.packages=["SourceVault","ClaudeOrchestrator"]`）を出す。
- あわせて `sourcevault_search` の `filters` 説明にも packageapi filter を追記する（catalog を読まないクライアント向けの二重化）。

**B-3: `Packages` 入力の正規化と不正値の応答を定義する**。現実装は `Intersection[Keys[$svPAIndex], Flatten @ {OptionValue["Packages"]}]`（410-411 行）で、名前が完全一致しないと**静かに 0 件**になり、LLM は「packageapi にない」と誤認して広い grep へ戻る。規則:

- 許可値は canonical package 名の list（= `$SourceVaultPackageApiPackages`）。
- scalar 文字列は 1 要素 list に正規化。**comma-separated 文字列は受けない**（誤用防止・明示エラー）。
- 大文字小文字は正規化して照合（`sourcevault` → `SourceVault`）。alias は初期は非対応（将来拡張）。
- 不明 package 指定時は、結果 0 件で終わらせず **MCP response metadata に `Warnings -> {<|"Code"->"UnknownPackage", "Value"->...|>}` 相当を返す**（受け入れテストで固定）。

優先度は 4-B と同じ P1（local ランカーを直しても MCP に通らなければ運用効果が半減するため）。B-1（scoped ensure）は初動性能に直結するので 4-D の中でも先に入れる。

### 4-E. 決定事項（r2 Open Questions への回答）

r2 レビューの Open Questions に、本提案としての既定判断を与える（実装時の指針。異論あれば実装前に上書き可）。

1. **`filters.packages` の受け入れ**: canonical 名（`$SourceVaultPackageApiPackages`）の list。**大文字小文字は正規化して照合**するが、alias と comma-separated 文字列は初期非対応（不明値は Warning）。
2. **filter discovery の置き場所**: **両方**。`sourcevault_catalog` の packageapi entry に `filterKeys`/`examples` を出すのを主とし、`sourcevault_search` schema 説明にも追記して二重化する。
3. **exact/alias の保護方式**: **numeric cap でなく tier**（B-5 推奨）。`HasExactOrAlias` を tie-break tuple の先頭キーにする。cap は代替として残すが既定は tier。
4. **package-scoped ensure と既存 API の関係**: 通常検索は package-scoped ensure、`SourceVaultPackageApiIndexBuild[All]` / `IndexStatus[]` は全体 warmup / 状態確認、と役割を分ける（B-1）。索引スキーマ・世代非依存 URI は不変。

## 5. 補足: `search` アダプタが 0 件だった意味

`sourcevault_search kinds=["search"]` に `"log runtime execution transcript"` を投げると **0 件**。これはランカーの問題ではなく、**LLM 実行ログが現時点でどのアダプタにも取り込まれていない**ことを示す。すなわち:

- 「過去に他 PC でこの問題をどう解いたか」を MCP で引ける状態にするには、まず ingest が要る（＝Codex の `llmlog` 仕様）。
- 本書の 4-A/4-B は「**コードベースの API を絞り込む**」性能の話であり、「**過去ログを引く**」性能とは別レイヤ。両方を混同しないこと。
- **将来の横断ルーティング**: `llmlog` アダプタが入ると、同じ query が `search` / `mail` / `llmlog` / `packageapi` にまたがる。今は「0 件」でよいが、`llmlog` 実装後の acceptance test には **アダプタ横断の routing**（kind 指定なし query がどのアダプタへ配分されるか、release gate が kind ごとに正しく効くか）を含めること。

## 6. 推奨する着手順序

- **P0 — 4-A（プロトコル明文化）**: 即日・低リスク。ディレクティブ/スキルに追記。効果が最も早く、失敗しても grep フォールバックで回復できる。コード変更前に入れてよい。
- **P1 — 4-B（ランカーのトークン化 + tie-break）**: `SourceVault_packageapi.wl` の純関数改修 + §4-B 受け入れテスト。索引再構築は不要（描画・スキーマ不変）。必ず tie-break と `Reasons` の score 寄与を付ける。
- **P1 — 4-D（MCP adapter の filters 対応）**: `iSVPackageApiAdapterSearch` に `filters.packages` を通す。4-B と同格（local だけ直しても MCP へ届かないため）。**先に B-1（cold start でも package-scoped ensure）** を入れて初動性能へ効かせ、**B-2（filter を catalog/schema に広告）** で LLM から発見可能にし、**B-3（正規化 + UnknownPackage 警告）** で静かな 0 件を防ぐ。受け入れは local 関数と MCP 経由の両方で確認。
- **P2 — `sourcevault_get` のクライアント露出確認**: tool schema には存在するが、Codex / Claude Code / Desktop / API client で実露出が異なる。見える tool 名を `sourcevault_runtime_capabilities` に記録し、4-A の「見える/見えない」分岐を確定する。
- **P3 — 4-C（code-symbol 索引）**: 任意・後回し。未文書化シンボルと実装行への橋渡し。scope が膨らむので packageapi 改修後でよい。
- **（別線）** Codex の `llmlog` 仕様の実装 — 過去ログ検索の穴埋め。本書の改善とは独立。

## 7. 根拠ファイル

- ランキング実装: `SourceVault_packageapi.wl:377-465`（`iPABigrams` / `iPAOverlap` / `iPAAuxKeywordBonus` / `SourceVaultPackageApiSearch`。tie-break は 464 行、substring 長さゲートは 426 行、bigram 閾値は 447 行）。
- MCP adapter（`query`/`limit` のみ委譲を確認）: `SourceVault_mcp.wl:2961-2980`（`iSVPackageApiAdapterSearch`）、登録は 3024 行〜。
- MCP 露出仕様: `SourceVault_info/docs/api_packageapi.md`（§「MCP 露出」）。
- マイニング全体像（rerank 層 `SourceVaultMinedSearch` / `SourceVaultMiningRerank` を含む）: `SourceVault_info/docs/api_mining.md`。
- 比較対象タスクの成果物: `ドキュメント/sourcevault_llm_execution_log_ingest_mcp_spec_v0_1.md`。
- レビュー: `ドキュメント/sourcevault_mining_narrowing_vs_fulltext_proposal_v0_1_review.md`（本版で反映）。
- 実測: `sourcevault_search`（packageapi/search）と `Grep`（*.wl）を 2026-07-05 に本セッションで実行。
