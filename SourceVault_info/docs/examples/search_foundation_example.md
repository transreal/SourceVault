# SourceVault 検索基盤 使用例 — OOPS 非依存（汎用データ）

SourceVault の **検索基盤**（`SourceVault_lexical.wl` / `SourceVault_searchindex.wl`）を、**OOPS メールを一切ロードせず**、任意の合成データだけで使う例集です。日本語 BM25・公開ポリシー（release gate）・失効（revocation）・mining primer・KG 局所探索を、手元の Association だけで動かせます。

OOPS seed オントロジ（辞書取り込み・auto-tag・表記ゆれ回復など）を使う例は [`oops_example.md`](oops_example.md) を参照してください。本ファイルはそれらに依存しません。

構成は 3 部です。

1. **[基本編](#基本編)** — 純関数レベル（正規化 / トークナイズ / BM25 採点 / 公開ポリシー評価）。
2. **[中級編](#中級編)** — 永続 index の build と gate 付き検索、entity OR-match（表記非一致の吸収）、object 失効。
3. **[応用編](#応用編)** — mining primer（重要度 / 鮮度つき採点）、KG 局所探索。

各例は **合成データ（一時的な Association）** だけで完結し、実データや API キー・ネットワークは不要です。関数仕様は [`api_lexical.md`](api_lexical.md 相当は [../api_lexical.md](../api_lexical.md)) / [`../api_searchindex.md`](../api_searchindex.md) を参照。

---

## 事前準備

`$packageDirectory`（パッケージのパス）は init ファイルで定義済みとします（ユーザ以外の再定義は禁止なので参照のみ）。

```mathematica
Block[{$CharacterEncoding = "UTF-8"}, Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]]

(* 検索基盤の関数がロードされているか確認 *)
Names["SourceVault`SourceVaultBuildProjectionIndex"]
```

**期待される出力例:** `{"SourceVaultBuildProjectionIndex"}`

> release context を登録する例（中級編以降）は末尾で必ず登録解除します。immutable index の `IndexId` は `CreateUUID` で毎回ユニークにしてあり、再実行しても alias 衝突しません。

---

# 0. 実運用シナリオ — これらの関数はいつ呼ばれるか

基本編以降の関数を、ユーザーが 1 つずつ手で呼ぶことは多くありません。実際には **LLM が MCP ツール `sourcevault_search` を呼んだとき** に、内部でこれらの関数が走ります。`ClaudeEval[...]`（claudecode）・Claude Code・LM Studio・Codex いずれも、SourceVault MCP に接続した LLM クライアントで、`claudecode` 自身は package-neutral（SourceVault を直接呼ばず、ツール経由）です。

以降の 2 シナリオは共通の索引を使うので、まずそれを用意します。

## 共通セットアップ: 検索対象の索引を用意する

API ドキュメントを chunk 化して `KeywordBM25V1` 索引にします（0.1・0.2 で共有。release context 名は `sv-kb`）。

```mathematica
norm = SourceVaultNormalizeSearchText;
mk = Function[{id, title, body},
  <|"ChunkId" -> id, "SourceVaultObjectId" -> "svobj:" <> id,
    "SearchFields" -> <|"title" -> title, "body" -> body|>,
    "Text" -> body, "NormalizedText" -> norm[body],
    "PrivacyLevel" -> 0.2, "State" -> "Published", "Tags" -> {},
    "SourceRef" -> <|"Title" -> title|>|>];
apiDocs = {
  mk["bm25",   "BM25 索引の作成", "SourceVaultBuildProjectionIndex で chunk から KeywordBM25V1 の永続索引を作り日本語全文検索する"],
  mk["gate",   "公開ポリシー",     "SourceVaultEvaluateReleasePolicy と release context で公開範囲を Permit Deny 制御する"],
  mk["primer", "要約プライマー",   "SourceVaultPrimerSearch は重要度と鮮度で要約を採点する低コスト探索"],
  mk["kg",     "KG 局所探索",       "SourceVaultExpandSearchGraph は関連トピックを multi-hop で展開する"]};

SourceVaultRegisterReleaseContext["sv-kb", <|"MaxPrivacyLevel" -> 0.5|>];
kbIdx = "sv-kb-bm25-" <> StringTake[StringDelete[CreateUUID[], "-"], 8];
SourceVaultBuildProjectionIndex["sv-kb", "Chunks" -> apiDocs,
  "IndexKind" -> "KeywordBM25V1", "IndexId" -> kbIdx];
```

## シナリオ 0.1: 自然文プロンプト → `sourcevault_search` → 検索基盤

ClaudeEval で次のような自然文を投げます（**これは実行イメージで、そのまま評価するセルではありません**。実際に走らせる前提は下の注記を参照）:

```text
ClaudeEval["release context sv-kb で『日本語の全文検索を実装したい』を検索して"]
```

すると LLM は次の MCP ツール呼び出しを発行します（引数は LLM が組み立て）:

```json
{ "name": "sourcevault_search",
  "arguments": { "query": "日本語の全文検索を実装したい",
                 "scope": { "releaseContext": "sv-kb" }, "methods": ["bm25"], "limit": 2 } }
```

このツールは SourceVault MCP サーバ内で
`sourcevault_search` → `iSVSearchAdapterSearch` → `SourceVaultSearch` → `iNativeSearch`
と流れ、`methods` に `"bm25"` があり `<rc>-bm25` 索引が登録されていれば、**基本編・中級編の日本語 BM25 + release gate** がそのまま走ります。ツールが内部で行うことは次の Wolfram コードと等価で、**こちらは（上の共通セットアップ後に）実行して挙動を確認できます**:

```mathematica
(* 上の共通セットアップで build した kbIdx を使う *)
SourceVault`MCPPrivate`iSVSearchAdapterSearch[
  <|"query" -> "日本語の全文検索を実装したい",
    "scope" -> <|"releaseContext" -> "sv-kb", "bm25Index" -> kbIdx|>,
    "methods" -> {"bm25"}, "limit" -> 2|>, <||>] //
  Map[<|"title" -> #["Title"], "kind" -> #["Metadata"]["RetrievalKind"], "decision" -> #["Decision"]|> &]
```

**期待される出力例（title / retrievalKind / decision）:**

```
{<|"title" -> "BM25 索引の作成", "kind" -> "KeywordBM25", "decision" -> "Permit"|>,
 <|"title" -> "KG 局所探索",     "kind" -> "KeywordBM25", "decision" -> "Permit"|>}
```

LLM 側には URI・title・snippet・citation だけが返り（高機密の本文は返らず、必要なら `sourcevault_get` + 承認）、request 時に release gate を再評価します。**「ClaudeEval のプロンプト → これらの検索関数」の経路自体はこの 1 本**です。

> **ClaudeEval プロンプト自体を走らせる場合の前提**: (1) 対象の release context（例では `sv-kb`）と `<rc>-bm25` 索引を **事前に build 済み**にすること（上の共通セットアップ）、(2) 初回は表示される権限ダイアログで **`sourcevault_search` ツールを承認**すること。索引が無い / 未承認だと LLM は「検索を実行できませんでした（承認してください）」と返し、ローカルモデルによってはツール失敗でリトライを繰り返して停滞し、メッセージ窓に `[LLMGraph] カスケード失敗` が並ぶことがあります。これは検索関数側でなく「未セットアップ＋ツール未承認＋モデルのリトライ」挙動です。そのため本書は、確実に検証できる上の Wolfram 等価コードで挙動を示しています。

## シナリオ 0.2: 仕様生成・実装ワークフローでの検索

少し複雑なワークフロー（仕様生成やその実装）では、**各サブタスクの前に「関連する API / 既存仕様」を検索して文脈に入れる** 使い方が有効です。上の共通セットアップで作った索引に対し、実装サブタスクごとに関連 API を引きます。

```mathematica
(* 実装サブタスクごとに、関連する API ドキュメントを検索して引き当てる（kbIdx は共通セットアップで build 済み）*)
searchTop = Function[t, Module[{r = SourceVaultSearch[t,
    "ReleaseContext" -> "sv-kb", "Index" -> kbIdx, "Limit" -> 1]},
  If[r === {}, "(なし)", r[[1]]["ChunkId"]]]];
subtasks = {"日本語の全文検索を実装する", "公開範囲を制御する", "重要度で結果を並べ替える"};
(# -> searchTop[#]) & /@ subtasks

(* 後始末（共通セットアップで登録した release context を解除）*)
SourceVault`SearchIndexPrivate`$registries["ReleaseContext"] =
  KeyDrop[SourceVault`SearchIndexPrivate`$registries["ReleaseContext"], {"sv-kb"}];
SourceVault`SearchIndexPrivate`iRegistrySave[];
```

**期待される出力例:**

```
{"日本語の全文検索を実装する"     -> "bm25",
 "公開範囲を制御する"             -> "gate",
 "重要度で結果を並べ替える"       -> "primer"}
```

各サブタスク文に対し、実装すべき API（BM25 索引 / release gate / primer）を検索で引き当てます。同じ `sourcevault_search` を仕様生成側でも呼べば、既存の仕様書・api ドキュメント・関連コードを **retrieval-augmented** に参照しながら生成・実装できます（release gate が付くので、公開してよい範囲だけが文脈に入ります）。

---

# 基本編

## 例 1: 日本語正規化・トークナイズ・BM25 採点（純関数）

lexical 層は core に依存しない純関数です。正規化（NFKC・全半角・半角カナ・桁区切り）、n-gram トークナイズ、BM25 採点を単体で動かせます。

```mathematica
(* NFKC 正規化: 全角英数→半角, 半角カナ→全角, 桁区切り除去, lower *)
SourceVaultNormalizeSearchText["Hello 全角ＡＢＣ　123,456ﾃｽﾄ"]
(* => "hello 全角abc 123456テスト" *)

(* term stream: token / unigram(CJK単字) / bigram *)
SourceVaultSearchTerms["機械学習 transformer"]
(* => <|"token" -> {"機械学習", "transformer"},
        "unigram" -> {"機", "械", "学", "習"},
        "bigram"  -> {"機械", "械学", "学習", ...}|> *)

(* 3 文書から BM25 stats を作り採点する *)
chunks = {
  <|"ChunkId" -> "d1", "SearchFields" -> <|"title" -> "注意機構", "body" -> "Transformer は注意機構で系列を処理する"|>|>,
  <|"ChunkId" -> "d2", "SearchFields" -> <|"title" -> "畳み込み", "body" -> "CNN は画像の畳み込み特徴を学習する"|>|>,
  <|"ChunkId" -> "d3", "SearchFields" -> <|"title" -> "再帰",     "body" -> "RNN は系列を再帰的に処理する"|>|>};
stats = SourceVaultBuildLexicalStats[chunks];
{#["ChunkId"], Round[#["Score"], 0.01]} & /@
  SourceVaultLexicalRank["注意機構 系列", stats, "Limit" -> 3, "Breakdown" -> False]
```

**期待される出力例:** `{{"d1", 5.91}, {"d3", 0.69}}`

「注意機構 系列」の両語を含む d1 が最上位、「系列」だけの d3 が続き、無関係な d2 は 0 で落ちます（BM25 = IDF + 文書長正規化 + TF 飽和）。

---

## 例 2: 公開ポリシー評価（release gate）

`SourceVaultEvaluateReleasePolicy[source, context]` は、source を release context の条件（`MaxPrivacyLevel` / `DenyTags` / `RequiredTags` / State / 期限）で評価し `Permit` / `Deny` を返します。検索・index build の両方でこの gate が効きます。

```mathematica
SourceVaultRegisterReleaseContext["docs-public",
  <|"MaxPrivacyLevel" -> 0.4, "DenyTags" -> {"secret"}|>];

gate = SourceVaultEvaluateReleasePolicy[#, "docs-public"] &;

{"permit"     -> gate[<|"PrivacyLevel" -> 0.3, "State" -> "Published", "Tags" -> {"public"}|>]["Decision"],
 "deny 機密度" -> gate[<|"PrivacyLevel" -> 0.8, "State" -> "Published", "Tags" -> {}|>]["Why"],
 "deny タグ"   -> gate[<|"PrivacyLevel" -> 0.2, "State" -> "Published", "Tags" -> {"secret"}|>]["Why"],
 "deny 状態"   -> gate[<|"PrivacyLevel" -> 0.2, "State" -> "Draft",     "Tags" -> {}|>]["Why"]}

(* 後始末 *)
SourceVault`SearchIndexPrivate`$registries["ReleaseContext"] =
  KeyDrop[SourceVault`SearchIndexPrivate`$registries["ReleaseContext"], {"docs-public"}];
SourceVault`SearchIndexPrivate`iRegistrySave[];
```

**期待される出力例:**

```
{"permit"     -> "Permit",
 "deny 機密度" -> {"PrivacyLevelExceedsMax(0.8>0.4)"},
 "deny タグ"   -> {"HasDenyTag({secret})"},
 "deny 状態"   -> {"StateNotReleasable(Draft)"}}
```

`State` が `Approved` / `Published` / `Released` 以外、`PrivacyLevel` が上限超、`DenyTags` に一致、いずれも `Deny` になり、理由が `Why` に入ります。

---

# 中級編

## 例 3: BM25 projection index を build して gate 付き検索

合成 chunk 群を build-time gate（Permit のみ収録）して `KeywordBM25V1` の永続 index にし、`SourceVaultSearch` で検索します。request 時にも gate を再評価します。

```mathematica
norm = SourceVaultNormalizeSearchText;
mk = Function[{id, title, body, pl},
  <|"ChunkId" -> id, "SourceVaultObjectId" -> "svobj:" <> id,
    "SearchFields" -> <|"title" -> title, "body" -> body|>,
    "Text" -> body, "NormalizedText" -> norm[body],
    "PrivacyLevel" -> pl, "State" -> "Published", "Tags" -> {},
    "SourceRef" -> <|"Title" -> title|>|>];
docs = {
  mk["ml",     "機械学習入門",       "教師あり学習と教師なし学習の基礎", 0.2],
  mk["cnn",    "畳み込みネットワーク", "画像認識の畳み込み特徴抽出",       0.2],
  mk["secret", "社外秘メモ",         "非公開の内部情報",                 0.8]};  (* 機密度 0.8 *)

SourceVaultRegisterReleaseContext["kb", <|"MaxPrivacyLevel" -> 0.5|>];
idx = "kb-bm25-" <> StringTake[StringDelete[CreateUUID[], "-"], 8];
built = SourceVaultBuildProjectionIndex["kb", "Chunks" -> docs,
  "IndexKind" -> "KeywordBM25V1", "IndexId" -> idx];
{built["ChunkCount"], built["ExcludedCount"]}   (* => {2, 1} : secret は build 時に除外 *)

{#["ChunkId"], Round[#["Score"], 0.01], #["ReleaseDecision"]} & /@
  SourceVaultSearch["学習", "ReleaseContext" -> "kb", "Index" -> idx, "Limit" -> 5]

SourceVault`SearchIndexPrivate`$registries["ReleaseContext"] =
  KeyDrop[SourceVault`SearchIndexPrivate`$registries["ReleaseContext"], {"kb"}];
SourceVault`SearchIndexPrivate`iRegistrySave[];
```

**期待される出力例:**

```
{2, 1}
{{"ml", 4.48, "Permit"}}
```

機密度 0.8 の `secret` は build-time gate で index に入らず（`ExcludedCount` 1）、「学習」検索でも当然出ません。返る結果はすべて `Permit`。

---

## 例 4: entity OR-match — 表記非一致を entity 辞書で吸収

surface form（別名）を持つ entity 辞書を渡すと、query と doc が **異なる表記**でも、双方に立つ `entity:<ref>` で一致します。辞書は手元の Association で作れます（OOPS でなくてよい）。

```mathematica
edict = <|"Entries" -> {
  <|"TopicItemRef" -> "t:ml", "CanonicalLabel" -> "機械学習",
    "SurfaceForms" -> {"機械学習", "Machine Learning", "ML"}|>,
  <|"TopicItemRef" -> "t:tf", "CanonicalLabel" -> "Transformer",
    "SurfaceForms" -> {"Transformer", "トランスフォーマー"}|>}|>;

echunks = {
  <|"ChunkId" -> "e1", "SearchFields" -> <|"title" -> "入門", "body" -> "機械学習の教科書"|>|>,
  <|"ChunkId" -> "e2", "SearchFields" -> <|"title" -> "画像", "body" -> "畳み込みの解説"|>|>};

est = SourceVaultBuildLexicalStats[echunks, "EntityDictionary" -> edict];
{#["ChunkId"], Round[#["Score"], 0.01]} & /@
  SourceVaultLexicalRank["ML", est, "Limit" -> 3, "Breakdown" -> False]
```

**期待される出力例:** `{{"e1", 0.39}}`

query は「ML」なのに、本文が「機械学習」の e1 にヒットします（両者が同じ topic `t:ml` の別名なので `entity:t:ml` で結ばれる）。辞書を渡さなければヒットしません。

---

## 例 5: object 失効（revocation）— 失効した object を検索から除外

`SourceVaultRevokeObject` で object にトゥームストーン event を書くと、以降の検索は request 時にそれを Deny にして落とします（index を作り直す必要はありません）。ここでは実 vault を汚さないよう一時 core root を使います。

```mathematica
tmp = FileNameJoin[{$TemporaryDirectory, "sv-rev-" <> StringDelete[CreateUUID[], "-"]}];
CreateDirectory[tmp, CreateIntermediateDirectories -> True];
SourceVault`$SourceVaultCoreRoot = tmp;   (* revocation event を一時 vault に隔離 *)

norm = SourceVaultNormalizeSearchText;
mk = Function[{id, title, body},
  <|"ChunkId" -> id, "SourceVaultObjectId" -> "svobj:" <> id,
    "SearchFields" -> <|"title" -> title, "body" -> body|>,
    "Text" -> body, "NormalizedText" -> norm[body],
    "PrivacyLevel" -> 0.2, "State" -> "Published", "Tags" -> {},
    "SourceRef" -> <|"Title" -> title|>|>];
docs = {mk["a", "文書A", "公開文書アルファ"], mk["b", "文書B", "公開文書ベータ"]};

SourceVaultRegisterReleaseContext["rev-ctx", <|"MaxPrivacyLevel" -> 0.5|>];
idx = "rev-bm25-" <> StringTake[StringDelete[CreateUUID[], "-"], 8];
SourceVaultBuildProjectionIndex["rev-ctx", "Chunks" -> docs,
  "IndexKind" -> "KeywordBM25V1", "IndexId" -> idx];

before = #["ChunkId"] & /@ SourceVaultSearch["文書", "ReleaseContext" -> "rev-ctx", "Index" -> idx];

SourceVaultRevokeObject["svobj:a", "Reason" -> "example demo"];   (* a を失効 *)

after = #["ChunkId"] & /@ SourceVaultSearch["文書", "ReleaseContext" -> "rev-ctx", "Index" -> idx];

(* 後始末 *)
SourceVault`SearchIndexPrivate`$registries["ReleaseContext"] =
  KeyDrop[SourceVault`SearchIndexPrivate`$registries["ReleaseContext"], {"rev-ctx"}];
SourceVault`SearchIndexPrivate`iRegistrySave[];
SourceVault`$SourceVaultCoreRoot = .;
DeleteDirectory[tmp, DeleteContents -> True];

{"revoke前" -> before, "revoke後" -> after}
```

**期待される出力例:** `{"revoke前" -> {"b", "a"}, "revoke後" -> {"b"}}`

失効後は `a` が検索結果から消えます。index はそのまま（再 build 不要）で、request 時の gate + revocation 照合だけで除外されます。

---

# 応用編

## 例 6: mining primer — 重要度 / 鮮度つきの低コスト探索（§6.1/6.2）

raw chunk でなく **サマリー item** を index し、`BM25 + bounded MiningBoost + EffectiveImportance·weight − StalePrimerPenalty` で採点します。結果は `EvidenceKind = "SummaryPrimer"`（回答根拠にはしない）。ここでは importance / freshness の効きを見るため title/summary を同一にして BM25 を揃えています。

```mathematica
mkItem = Function[{id, imp, freshness},
  <|"ObjectURI" -> "sv://primer/" <> id, "SourceVaultObjectId" -> "synth:" <> id,
    "Title" -> "PRIMER", "Summary" -> "人工生命 alpha 共通サマリー",
    "Tags" -> {"alife"}, "Authors" -> {"imai"},
    "Signals" -> <|"EffectiveImportance" -> imp|>, "Freshness" -> freshness,
    "PrivacyLevel" -> 0.2, "State" -> "Published"|>];
items = {mkItem["hi", 0.9, "Fresh"], mkItem["lo", 0.1, "Fresh"], mkItem["stale", 0.9, "StalePrimer"]};

SourceVaultRegisterReleaseContext["primer-rc", <|"MaxPrivacyLevel" -> 1.0|>];
pid = "primer-rc-primer-" <> StringTake[StringDelete[CreateUUID[], "-"], 8];
SourceVaultBuildPrimerIndex["primer-rc", "Items" -> items, "PrimerId" -> pid];
SourceVaultLoadPrimerIndex[pid];

Grid[Prepend[
  {StringDrop[#["SourceVaultObjectId"], 6], Round[#["Score"], 0.001],
   Round[#["MiningBoost"], 0.001], Round[#["ImportanceTerm"], 0.001],
   #["FreshnessPenalty"], #["EvidenceKind"]} & /@
    SourceVaultPrimerSearch["人工生命", "ReleaseContext" -> "primer-rc", "PrimerIndex" -> pid, "Limit" -> 5],
  {"id", "Score", "MiningBoost", "ImportanceTerm", "Penalty", "EvidenceKind"}], Frame -> All]

SourceVault`SearchIndexPrivate`$registries["ReleaseContext"] =
  KeyDrop[SourceVault`SearchIndexPrivate`$registries["ReleaseContext"], {"primer-rc"}];
SourceVault`SearchIndexPrivate`iRegistrySave[];
```

**期待される出力例（全 item は BM25 = 3.581 で揃う）:**

```
id     Score   MiningBoost  ImportanceTerm  Penalty  EvidenceKind
hi     3.851   0.18         0.09            0.       SummaryPrimer
stale  3.701   0.18         0.09            0.15     SummaryPrimer
lo     3.611   0.02         0.01            0.       SummaryPrimer
```

順位は **hi > stale > lo**。importance が高い hi が boost で上に、同じ importance でも `StalePrimer` の stale は penalty 0.15 で hi より下、importance の低い lo が最下位になります。boost は `MaxBoost`（0.2）で bounded で、gate は緩めません。

---

## 例 7: KG 局所探索 — 重み付きグラフを multi-hop 展開（§6.3）

`SourceVaultExpandSearchGraph` は seed から重み付き有向グラフを BFS 展開します。グラフは手元の Association でよく（OOPS の relation でなくてよい）、hop 上限・node 上限・weight 閾値・per-node top-k で bounded、cycle 安全です。

```mathematica
relationGraph = <|
  "topic:ml" -> {<|"To" -> "topic:dl",    "Weight" -> 5, "Direction" -> "Down"|>,
                 <|"To" -> "topic:stats", "Weight" -> 3, "Direction" -> "Down"|>},
  "topic:dl" -> {<|"To" -> "topic:transformer", "Weight" -> 4, "Direction" -> "Down"|>,
                 <|"To" -> "topic:cnn",         "Weight" -> 2, "Direction" -> "Down"|>}|>;

kg = SourceVaultExpandSearchGraph[{"topic:ml"},
  "RelationGraph" -> relationGraph, "MaxHops" -> 2, "MaxNodes" -> 10, "MinEdgeWeight" -> 1];

{"nodes" -> kg["NodeCount"], "edges" -> kg["EdgeCount"],
 "expanded" -> ({#["Hop"], #["Ref"]} & /@ kg["Expanded"])}
```

**期待される出力例:**

```
{"nodes" -> 4, "edges" -> 4,
 "expanded" -> {{1, "topic:dl"}, {1, "topic:stats"}, {2, "topic:transformer"}, {2, "topic:cnn"}}}
```

`topic:ml` の 1-hop（dl / stats）と、そこから 2-hop（transformer / cnn）が展開されます。`Expanded` の各 node は `Hop` / `Weight` / `ViaSeed` を持ち、`Edges` にグラフ構造、`Trace` に各 hop の統計が入ります。

---

## クリーンアップ

すべての例は合成データと一時 vault（例 5）で完結します。release context を登録した例（3・5・6）は各末尾で登録解除しています。immutable index / primer snapshot は content-addressed で `IndexId`/`PrimerId` をユニークにしているため、残っても無害（再実行で衝突しません）。