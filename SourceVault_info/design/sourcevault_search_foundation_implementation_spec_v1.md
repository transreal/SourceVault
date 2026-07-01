# SourceVault 検索基盤 実装仕様 v1

- Status: **Draft / implementation-ready**
- Date: 2026-06-30
- 入力文書: `sourcevault_agentic_search_japanese_retrieval_integrated_v1.md`
- 対象: `SourceVault_searchindex.wl`, `SourceVault_mining.wl`, `SourceVault_mcp.wl`, `SourceVault_eagle.wl`, `SourceVault_info/docs/api_*.md`
- 目的: SourceVault の既存 release gate / revocation / MCP access 境界を維持したまま、日本語検索に強い lexical 基盤、マイニング primer、KG 局所探索、agentic keyword/cascade 検索を段階実装する。

---

## 0. 結論

SourceVault の検索基盤は、以下の順に実装する。

1. **安全境界は既存 `SourceVaultSearch` を基準に固定**する。検索時は必ず request-time release gate、revocation、raw path 非返却を通す。
2. **日本語 lexical を先に強化**する。正規化、unigram+bigram、BM25 を `KeywordBM25V1` として追加し、現行 `KeywordBigram` は互換維持する。
3. **サマリーとマイニングは primer にする**。サマリーを事実回答の根拠にせず、候補 object の絞り込みと follow-up 生成の起点に使う。
4. **マイニング層は KG 局所探索に接続**する。tag、author、links、ObjectSignals を辿り、ranking boost は bounded に保つ。
5. **agentic search はゲート付きツールの反復**として実装する。素の filesystem grep や raw body 直読は不可。
6. **複雑クエリだけ Cascade に上げる**。単純クエリは BM25 / mined lexical で返し、multi-hop・曖昧・根拠不足だけ agentic 反復する。
7. **OOPS seed ontology は owner-scoped topic 空間として扱う**。`ki` は owner 本人の topic namespace、`mi`/`aga` 等は別 owner の topic namespace であり、同じ表層語でも namespace が違えば別 item とする。namespace は enum で決め打ちしない。
8. **検索 v1 と研究トラックを分離**する。検索 v1 は BM25 / seed 辞書 / mined / primer / KG までを最小完了条件とし、retrieval episode 学習・mail topic graph・associative level は独立評価を通した後に昇格する。

---

## 1. 不変条件

### 1.1 Security / privacy

- `ReleaseContext` 未指定の検索は fail-closed。
- build-time gate は index 収録範囲を減らすために使う。request-time gate は必ず再評価する。
- `SourceVaultBuildRevocationSet[]` に含まれる object は検索結果から除外する。
- `SecurityPreScan` が `quarantined` の object は primer、KG、agentic 反復、LLM reasoning retrieval から除外する。
- raw local path、実ファイルパス、credential、profile 実体は SearchResult / MCP response に出さない。
- external text、mail body、web ingest body、directive chunk 本文は LLM 命令ではなく data として隔離する。

### 1.2 Ranking safety

- mining boost は ranking のみで、access level / release gate / safety gate を緩めない。
- `ObjectSignals` の LLM 寄与は既存どおり 0.7 係数で抑制する。
- owner dismissed object は importance 寄与を 0 にする。
- サマリーや stale snapshot の score は候補選択の prior に限定し、最終回答は生 chunk / body evidence で接地する。
- retrieval episode などの行動 popularity feedback 由来 boost は time decay と frequency normalization を持ち、単一 object に collapse しないようにする。
- topic item / mail session / archived content の古さは一律 penalty にしない。古いが関連する記憶を想起する目的を壊さないため、content age は ranking decay の対象外とし、recency decay は行動 feedback に限定する。
- cognitive level による privacy lowering operation の execute / camouflage は本仕様の対象外。associative level は ranking / presentation control のみに使う。

### 1.3 Backward compatibility

- 既存 `KeywordBigram` projection index は読み込み・検索可能なまま残す。
- `SourceVaultSearch[query, "ReleaseContext" -> rc, "Index" -> idx]` の既存戻り値 schema は壊さない。
- 新しい情報は `ScoreBreakdown`, `RankScore`, `Trace`, `RetrievalKind` などの追加キーで表す。

---

## 2. 全体アーキテクチャ

```text
User / LLM / MCP
  |
  v
SourceVaultSearch / SourceVaultMCPSearch
  |
  +-- GateContext: ReleaseContext + AccessRequest + RevocationEpoch
  |
  +-- B1 Lexical: KeywordBM25V1
  |      normalization -> unigram/bigram/exact -> BM25 -> request-time gate
  |
  +-- B2 Mining Primer
  |      summary/tag/author/ObjectSignals -> bounded prior -> candidate objects
  |
  +-- B3 KG Local Expand
  |      [[links]] / tags / author / interactions -> candidate expansion
  |
  +-- B4 Gated Body Search
  |      SourceVaultSearch / sourcevault_get view=body with grant when required
  |
  +-- B5 Optional Dense / Rerank
         small-N summaries/mining nodes only -> RRF -> optional JaColBERT
```

`AgenticKeywordSearch` と `Cascade` は B2-B4 を ReAct 風に反復する workflow kind として実体化する。

---

## 3. データモデル

### 3.1 Chunk schema 拡張

既存 §7.2 chunk に以下を追加可能にする。すべて optional で、無い場合は互換動作。

```wl
<|
  "ChunkId" -> "chunk:...",
  "SourceVaultObjectId" -> "obj:...",
  "ObjectURI" -> "sv://...",
  "Text" -> "...",
  "NormalizedText" -> "...",
  "SearchFields" -> <|
    "title" -> "...",
    "summary" -> "...",
    "body" -> "...",
    "tags" -> {"..."},
    "author" -> {"..."}
  |>,
  "SearchMeta" -> <|
    "Tokenizer" -> "ja-ngram-v1",
    "NormalizationProfile" -> "ja-nfkc-v1",
    "SourceEpoch" -> 123,
    "DerivedFrom" -> {"snapshot:..."},
    "SafetyState" -> "active" | "warning" | "quarantined",
    "Freshness" -> "Fresh" | "StalePrimer" | "Unknown"
  |>
|>
```

`SafetyState` の正準位置は `SearchMeta.SafetyState` とする。旧データや外部 adapter が top-level `SafetyState` を持つ場合は import/search 時に `SearchMeta.SafetyState` へ正規化してから使う。

### 3.2 Projection index `KeywordBM25V1`

`SourceVaultProjectionIndex` の `IndexKind` に `"KeywordBM25V1"` を追加する。

```wl
<|
  "ObjectClass" -> "SourceVaultProjectionIndex",
  "IndexId" -> indexId,
  "IndexKind" -> "KeywordBM25V1",
  "ReleaseContextRef" -> contextName,
  "PolicyDigest" -> digest,
  "NormalizationProfile" -> "ja-nfkc-v1",
  "TokenizerProfile" -> "ja-ngram-v1",
  "ScoringProfile" -> "bm25-ja-v1",
  "Chunks" -> permittedChunks,
  "LexicalStats" -> <|
    "N" -> n,
    "Fields" -> <|
      "body" -> <|"AvgDL" -> _, "DF" -> <|term -> df|>|>,
      "bigram" -> <|"AvgDL" -> _, "DF" -> <|term -> df|>|>,
      "unigram" -> <|"AvgDL" -> _, "DF" -> <|term -> df|>|>
    |>
  |>,
  "RevocationEpochAtBuild" -> SourceVaultRevocationEpoch[],
  "BuiltAtUTC" -> "...",
  "ChunkCount" -> n,
  "ExcludedCount" -> m
|>
```

`LexicalStats` は immutable snapshot に保存する。巨大化する場合は `Artifacts` へ分離し、index record には artifact ref と digest だけを持つ。

### 3.3 SearchResult 拡張

既存 SearchResult に以下を追加する。

```wl
<|
  "Score" -> primaryScore,
  "RankScore" -> finalScore,
  "ScoreBreakdown" -> <|
    "Exact" -> _,
    "BM25Unigram" -> _,
    "BM25Bigram" -> _,
    "Entity" -> _,
    "MiningBoost" -> _,
    "FreshnessPenalty" -> _,
    "RRF" -> Missing[] | _
  |>,
  "RetrievalKind" -> "KeywordBM25" | "MinedKeyword" | "AgenticKeywordSearch" | "Cascade",
  "EvidenceKind" -> "Chunk" | "SummaryPrimer" | "BodyGrounding",
  "ObjectURI" -> "sv://...",
  "ViewRefs" -> {"svview:..."},
  "TraceRef" -> "svtrace:..."
|>
```

`EvidenceKind -> "SummaryPrimer"` の結果だけで最終回答してはならない。回答生成に渡す evidence は `"Chunk"` または `"BodyGrounding"` を含むこと。

### 3.4 Live search view schema

検索結果はランキングリストだけでなく、たどれる作業面として返せるようにする。HTML hypertext の旧方式をそのまま踏襲する必要はないが、SourceVault URI、topic item、mail paragraph、quote edge、summary、annotation を軽快に参照できる live view を first-class object とする。

```wl
<|
  "ObjectClass" -> "SourceVaultSearchView",
  "ViewRef" -> "svview:...",
  "ViewKind" -> "RankedList" | "LiveNotebookHypertext" |
    "ContextSubgraphNotebook" | "GraphPlot" | "OrderedTree",
  "SearchSessionRef" -> "svsession:...",
  "RootQueryRef" -> "svquery:...",
  "RootNodeRefs" -> {"svtopic:...", "svmailpara:...", "sv://..."},
  "NodeRefs" -> {"svtopic:...", "svmailpara:...", "svquote:...", "svannotation:..."},
  "EdgeRefs" -> {"svedge:...", "svquote:..."},
  "Ordering" -> {"svtopic:...", "svmailpara:..."},
  "NotebookCellRefs" -> {"svcell:..."},
  "GraphLayout" -> "LayeredDigraphEmbedding" | "RadialDrawing" |
    "SpringElectricalEmbedding" | "TreeEmbedding" | Automatic,
  "LazyLoadPolicy" -> <|"MaxInitialNodes" -> 80, "ExpandDepth" -> 1|>,
  "ReleaseContextRef" -> "...",
  "BuiltAtUTC" -> "..."
|>
```

`LiveNotebookHypertext` は Mathematica notebook 上のセル群として返す。各 topic item / mail / quote / annotation は notebook 内リンクまたは button として表示し、クリック時に gated fetch で本文や近傍 node を lazy load する。`ContextSubgraphNotebook` は検索コンテクストを topic item graph の部分グラフとして切り出し、順序木に線形化した「一件書類」として notebook cell に展開する。`GraphPlot` は Wolfram Language の `Graph` / `GraphPlot` 系 option を受け、近傍 topic の関係を図として返す。

返却形式 options:

```wl
"ResultView" -> "RankedList" | "LiveNotebookHypertext" |
  "ContextSubgraphNotebook" | "GraphPlot" | "OrderedTree" | "All"
"GraphLayout" -> Automatic
"ContextSubgraphRoot" -> Automatic | "svtopic:..." | "sv://..."
"ContextSubgraphDepth" -> 1 | 2 | 3
"NotebookInteractivity" -> "Live" | "Static"
```

live view は release gate / request-time gate を緩めない。未許可 node は存在だけを示す low-leak placeholder にするか、edge ごと隠す。raw local path は notebook cell / tooltip / trace に出さない。

---

## 4. 日本語 lexical 実装

### 4.1 正規化

内部関数を `SourceVault_searchindex.wl` に追加する。

```wl
iSVNormalizeSearchText[text_String, profile_: "ja-nfkc-v1"] := ...
iSVNormalizeQuery[query_String, profile_: "ja-nfkc-v1"] := ...
```

`ja-nfkc-v1` の必須処理:

- `NFKC` 相当の正規化。WL 標準で直接足りない場合は安全な置換表から開始する。
- 全角英数を半角へ寄せる。
- 英字は lower-case。
- 空白、制御文字、ゼロ幅文字を canonical space へ寄せる。
- 句読点、記号の代表形を統一する。
- 数値の桁区切りを検索用 field では除去した variant も作る。

初期実装では旧字体、送りがな、同義語展開は profile の `SynonymMap` / `VariantMap` として optional にする。

### 4.1.1 Seed ontology entity dictionary

OOPS seed ontology は、mail topic graph の前に lexical 層へ投入する。`item-name.index` は正準 label、別名、日英併記語、人物別 topic namespace を含むため、日本語検索の OOV / 表記ゆれ対策として最も安く効く。

辞書 schema:

```wl
<|
  "ObjectClass" -> "SourceVaultSeedEntityDictionary",
  "DictionaryId" -> "svdict:oops-topic:...",
  "Entries" -> {
    <|
      "TopicItemRef" -> "svtopic:oops:ki:2573",
      "Namespace" -> "ki",
      "LocalId" -> 2573,
      "OwnerRef" -> "sventity:owner:imai",
      "OwnerConfidence" -> 1.0,
      "CanonicalLabel" -> "iChat",
      "SurfaceForms" -> {"iChat", ...},
      "LanguageHints" -> {"ja", "en"},
      "PrivacyLevel" -> _,
      "SourceRefs" -> {"table/item-name.index"}
    |>
  },
  "BuiltAtUTC" -> "..."
|>
```

適用:

- `iSVNormalizeSearchText` は profile の `EntityDictionaryRefs` を受け、surface form を canonical topic ref と normalized alias に展開できる。
- BM25 では raw token に加え `entity:svtopic:oops:ki:2573` のような entity term を追加する。
- 同じ label でも namespace / owner が違えば別 entity term にする。例: `svtopic:oops:ki:...` と `svtopic:oops:mi:...` は統合しない。
- query 時に surface form が複数 owner namespace に対応する場合は、owner-scoped entity の union に展開する。各 term は owner provenance を保持し、ranking では current owner / current project と一致する entity を軽く優遇できるが、他 owner namespace を落とさない。
- seed relation は query expansion の候補に使うが、初期 v1 では bounded expansion とし、1 hop / top weighted neighbors に制限する。
- owner が未解決の namespace は `OwnerRef -> Missing["UnknownOwner"]` として保持し、drop しない。
- `entity` field は bounded bonus とし、同一 surface form から派生した `exact` / `token` / `entity` signal の合算には上限を設ける。単一語の字面一致だけで ranking が支配されないよう、`CorrelatedSurfaceCap` を scoring profile に持たせる。

評価:

- 明示 topic を伏せた OOPS paragraph held-out set を作り、`SurfaceForms + relation expansion` ありと辞書なし BM25 を同一条件で比較する。成功判定は「辞書あり - 辞書なし」の recall@k / NDCG@k 改善が、着手前に事前登録した閾値以上であること。
- held-out は time split を基本にし、train は時刻 T 以前、test は T 以後に分ける。random split だけでは新規 topic の難しさを測れない。
- 評価は、正解 label / alias が本文に字面で出る literal surface match 層と、字面が出ない semantic / hard 層に層別する。seed-hit rate と novel-topic ratio を併記し、語彙既知問題と新規 topic 問題を混同しない。
- seed-hit 率が低い場合でも、辞書は表記ゆれ対策として維持し、auto topic graph への昇格は延期する。

### 4.2 Token fields

`iTokenize` / `iBigrams` を置換せず、下位互換のため残す。新規に field 別 term 生成を追加する。

```wl
iSVSearchTerms[text_String, profile_: "ja-ngram-v1"] := <|
  "unigram" -> {...},
  "bigram" -> {...},
  "token" -> {...}
|>
```

`ja-ngram-v1`:

- `token`: 空白・句読点分割。英数字や明示区切りのある語に効かせる。
- `unigram`: CJK 文字、かな、カナ、英数字連続の 1-gram。
- `bigram`: 正規化済み文字列から空白・句読点を除いた 2-gram。
- stopword は初期実装では入れない。入れる場合は profile 明示。

形態素解析は v1 の必須にしない。Sudachi / MeCab は `TokenizerProfile -> "sudachi-hybrid-v1"` として後続追加にする。

### 4.3 BM25

BM25 は field 別に計算し、weighted sum する。

```text
BM25(t,d) = IDF(t) * ((tf * (k1 + 1)) / (tf + k1 * (1 - b + b * dl / avgdl)))
IDF(t) = Log[1 + (N - df + 0.5)/(df + 0.5)]
```

既定値:

```wl
<|
  "k1" -> 1.2,
  "b" -> 0.75,
  "FieldWeights" -> <|
    "exact" -> 3.0,
    "entity" -> 0.8,
    "token" -> 1.0,
    "unigram" -> 0.35,
    "bigram" -> 0.65
  |>,
  "MaxExactBoost" -> 3.0,
  "CorrelatedSurfaceCap" -> 3.5
|>
```

`exact` は BM25 ではなく、正規化 query が field に substring として含まれる場合の bounded boost。
`entity` は owner-scoped entity term の bounded bonus。`exact` / `token` / `entity` が同一 surface form から来る場合は `CorrelatedSurfaceCap` で合算上限をかける。

### 4.4 Scoring API

private:

```wl
iSVBuildLexicalStats[chunks_List, opts___] := lexicalStats
iSVBM25Score[chunk_Association, query_String, stats_Association, opts___] := <|
  "Score" -> _Real,
  "Breakdown" -> <|...|>
|>
```

public / semi-public:

```wl
SourceVaultExplainSearchScore[query_String, chunk_Association, opts___] := <|...|>
```

`SourceVaultExplainSearchScore` はデバッグ用。raw path や非公開 body を出さず、term と score だけ返す。

---

## 5. Projection index build / search

### 5.1 `SourceVaultBuildProjectionIndex`

既存 options に追加する。

```wl
Options[SourceVaultBuildProjectionIndex] = {
  "Chunks" -> None,
  "IndexId" -> Automatic,
  "IndexKind" -> "KeywordBigram",
  "NormalizationProfile" -> "ja-nfkc-v1",
  "TokenizerProfile" -> "ja-ngram-v1",
  "ScoringProfile" -> "bm25-ja-v1",
  "ExcludeQuarantined" -> True
};
```

動作:

1. `ReleaseContext` を解決。失敗なら Failure。
2. `Chunks` を受け取る。list でなければ Failure。
3. `ExcludeQuarantined -> True` のとき、正規化後の `SearchMeta.SafetyState == "quarantined"` の chunk を除外。
4. build-time release gate で `Permit` のみ収録。
5. `IndexKind == "KeywordBM25V1"` のとき、正規化 field と `LexicalStats` を作る。
6. immutable snapshot 保存。

### 5.2 `iNativeSearch`

`IndexKind` で dispatch する。

```wl
Switch[Lookup[rec, "IndexKind", "KeywordBigram"],
  "KeywordBigram", iNativeSearchKeywordBigram[...],
  "KeywordBM25V1", iNativeSearchBM25[...],
  _, Failure["UnsupportedIndexKind", ...]
]
```

`iNativeSearchBM25` は以下を守る。

- query も同じ normalization/tokenizer profile で処理。
- score <= 0 は候補から落とす。
- 上位候補を取ったあとではなく、最終返却前に request-time gate と revocation を再評価する。
- gate で落ちた件数を `Trace` に記録できるようにする。
- `Snippet` は正規化前 text があればそれを優先し、検索位置は正規化 text から近似する。難しければ初期実装は正規化 text snippet でよい。

### 5.3 Default 切替

初期リリースでは default は `"KeywordBigram"` のまま。評価セットで B1 が既存以上かつ leak/gate violation 0 を確認後、purpose index / 新規 projection の default を `"KeywordBM25V1"` に切り替える。

---

## 6. Mining primer / KG local search

### 6.1 Primer snapshot

マイニング・サマリー由来の低コスト探索対象を `SourceVaultPrimerIndex` として immutable 保存する。

```wl
<|
  "ObjectClass" -> "SourceVaultPrimerIndex",
  "PrimerId" -> primerId,
  "ReleaseContextRef" -> rc,
  "Items" -> {
    <|
      "ObjectURI" -> "sv://...",
      "SourceVaultObjectId" -> "...",
      "Title" -> "...",
      "Summary" -> "...",
      "Tags" -> {...},
      "Authors" -> {...},
      "Links" -> {...},
      "Signals" -> <|"EffectiveImportance" -> _|>,
      "SafetyState" -> "active",
      "PrivacyLevel" -> _,
      "State" -> "Published",
      "SourceEpoch" -> _,
      "SummaryEpoch" -> _,
      "Freshness" -> "Fresh" | "StalePrimer"
    |>
  },
  "BuiltAtUTC" -> "...",
  "RevocationEpochAtBuild" -> _
|>
```

Public API:

```wl
SourceVaultBuildPrimerIndex[contextName_String, opts___] := ...
SourceVaultLoadPrimerIndex[primerIdOrRef_String, opts___] := ...
SourceVaultPrimerSearch[query_String, opts___] := ...
```

Options:

```wl
{
  "ReleaseContext" -> None,
  "PrimerIndex" -> Automatic,
  "Limit" -> 20,
  "UseSummaries" -> True,
  "UseMining" -> True,
  "MaxBoost" -> 0.2,
  "FreshnessPenalty" -> 0.15
}
```

### 6.2 Primer scoring

Primer score は以下の和にする。

```text
PrimerScore =
  BM25(summary/title/tags/authors, query)
  + bounded MiningBoost
  + EffectiveImportance * ImportanceWeight
  - StalePrimerPenalty
```

既定:

```wl
"ImportanceWeight" -> 0.1
"MaxBoost" -> 0.2
"StalePrimerPenalty" -> 0.15
```

サマリーは `EvidenceKind -> "SummaryPrimer"` とし、回答根拠にはしない。

### 6.3 KG local expansion

Public API:

```wl
SourceVaultExpandSearchGraph[seeds_List, opts___] := <|
  "Seeds" -> seeds,
  "Expanded" -> {...},
  "Edges" -> {...},
  "Trace" -> {...}
|>
```

Options:

```wl
{
  "ReleaseContext" -> None,
  "MaxHops" -> 2,
  "MaxNodes" -> 50,
  "EdgeKinds" -> {"ExplicitLink", "SharedTag", "SharedAuthor", "Interaction"},
  "MinEdgeWeight" -> 0.1
}
```

Edge sources:

- `[[links]]` / `ObjectInteractions` / explicit object refs。
- tag projection from `SourceVaultObjectTags`。
- authorship projection from `SourceVaultObjectAuthorships`。
- `ObjectSignals` from `SourceVaultReplayObjectSignals`。

Expansion 後も各 node は release gate、revocation、safety gate を通す。gate で落ちた node は trace に reason だけ残し、内容は返さない。

### 6.4 Retrieval episode graph

検索を伴う 1 作業セッションを、最終出力 object に向かう探索グラフとして記録する。これは「ユーザ/LLM がどの検索キーを組み立て、どの検索結果を見て、どれを根拠として最終 object を作ったか」を学習するための派生データである。

対象:

- `SourceVaultSearch` / `SourceVaultMCPSearch`
- `sourcevault_search` / `sourcevault_get`
- web search / SearXNG / browser ingest / MCP 経由検索
- 画像、音声フラグメント、ファイル、URI、query text などの multimodal query
- LLM が生成した最終出力、ユーザが保存した出力、SourceVault に格納された derived object

データモデル:

```wl
<|
  "ObjectClass" -> "SourceVaultRetrievalEpisode",
  "EpisodeId" -> "svepisode:...",
  "SessionId" -> "...",
  "Actor" -> <|"Kind" -> "Owner" | "LLM" | "Tool", "Ref" -> "... "|>,
  "TaskRef" -> "svtask:..." | Missing[],
  "Inputs" -> {"sv://...", "query:..."},
  "SearchAttempts" -> {
    <|
      "AttemptId" -> "svattempt:...",
      "ParentAttemptId" -> Missing[] | "svattempt:...",
      "QueryObjectRef" -> "svquery:...",
      "QueryText" -> "...",
      "QueryModality" -> "text" | "image" | "audio" | "mixed",
      "SearchMethod" -> "bm25" | "primer" | "web" | "mcp" | "agentic" | "cascade",
      "ResultRefs" -> {"sv://...", "svweb://...", "evid:..."},
      "ClickedOrReadRefs" -> {"sv://..."},
      "IncludedEvidenceRefs" -> {"evid:..."},
      "RejectedRefs" -> {"sv://..."},
      "StartedAtUTC" -> "...",
      "EndedAtUTC" -> "...",
      "TraceRef" -> "svtrace:..."
    |>
  },
  "Outputs" -> {"sv://derived/..."},
  "Outcome" -> "Succeeded" | "Partial" | "None",
  "BuiltAtUTC" -> "..."
|>
```

重要度推定:

```text
EpisodeResultInfluence(result, output) =
  direct citation / evidence inclusion
  + semantic overlap(result, output)
  + graph proximity(result object, output object)
  + user/LLM read dwell or explicit include
  + owner explicit reuse
  - ignored-after-read penalty
  - contradicted/rejected penalty
```

正規化:

- influence は `(actor, context profile, task kind, time window)` ごとに frequency normalization する。
- 行動 popularity feedback に限り time decay を既定で適用する。例: `Exp[-ageDays/180]`。対象 object / mail / topic の作成日や古さにはこの decay を掛けない。
- LLM actor の influence は owner action より低く扱い、既定係数 0.7 を上限にする。
- 同一 object の自己増幅を抑えるため、同じ output family からの繰り返し citation は sublinear に集計する。

Public API:

```wl
SourceVaultStartRetrievalEpisode[spec_Association, opts___] := ...
SourceVaultRecordSearchAttempt[episodeId_String, attempt_Association, opts___] := ...
SourceVaultCloseRetrievalEpisode[episodeId_String, outputs_List, opts___] := ...
SourceVaultBuildRetrievalEpisodeGraph[opts___] := ...
SourceVaultEpisodeInfluenceScores[episodeId_String, opts___] := ...
SourceVaultSearchEpisodeMemory[query_String, opts___] := ...
```

検索への使い方:

- query 拡張: 過去 episode で最終出力に強く寄与した query term / object / topic を候補 query に足す。
- ranking prior: 同じ SearchContextProfile / task type で高 influence だった object を bounded boost する。
- negative signal: 読まれたが出力に寄与しなかった result、明示 reject された result は bounded penalty。
- agentic loop: 再検索時に `SearchEpisodeMemory` を primer として呼び、過去の良い探索経路を follow-up query 候補にする。

安全条件:

- influence boost は release gate / revocation / safety gate を緩めない。
- web 検索ログの external text は data boundary として扱う。検索語・URL・snippet は LLM 命令にならない。
- episode trace の local-only 部分は cloud prompt に出さない。
- LLM 自己強化を避けるため、LLM actor の influence は既定 0.7 係数で抑制し、owner action を優先する。
- retrieval episode store 自体は高機密の行動ログである。既定 `PrivacyLevel -> 1.0`, `Tags -> {"PrivateBehaviorLog", "NoCloudLLM"}` とし、cloud LLM ReleaseContext の `DenyTags` で拒否する。検索対象にする場合も低漏洩 projection のみを返す。

### 6.5 Mail topic item graph

PDF `20250718-ICNGCT2025.pdf` のメールモデルを SourceVault の一般メールに拡張する。元モデルは、メールを「write once の改訂履歴つきアウトライン」と見なし、各段落に topic item を付け、quote / quoted 関係と topic-to-topic relation から session / cluster を作る。一般メールでは明示 topic item が無いので、段落ごとに自動 topic item を生成し、seed ontology に既存 OOPS topic item を使う。

Seed data:

- `table.zip`
  - `item-name.index`: `(namespace localId) -> label` の topic item 名。例: `(ki 2573) -> "iChat"`。
  - `item-relation.index` / `item-relation-up.index`: 重み付き・有向 topic-to-topic relation。
  - `item-to-mail.index` / `mail-to-item.index`: topic item と mail number の対応。
  - `quote-table.index` / `quoted-table.index`: quote / quoted relation。
  - `mail-info.index`: mail number、list、author、source file offset。list 名は privacy / trust class の入力。
- `oops 200506.txt`
  - `◎` / `○` / `・` による title topic item。
  - `{... [namespace n]}` による body topic item。
  - `-*- Quote (from n) -*-` / `-*- Unquote -*-` による引用範囲。
  - `X-Ml-Counter` による mail number。

#### 6.5.1 Owner-scoped topic item

OOPS topic item は、単なる global keyword ではなく、所有者ごとの topic namespace に属する。単一ユーザ SourceVault の初期前提では current owner は `ki -> sventity:owner:imai` とし、`mi` / `aga` 等は別 owner の namespace として扱う。同じ label でも owner が違えば別 topic item であり、文脈・privacy・由来を統合しない。

Importer は namespace を enum で決め打ちしない。`(SYMBOL INT)` を総称的に読み、未知 namespace を drop せず `OwnerRef -> Missing["UnknownOwner"]` として保持する。`e` のように個人でない可能性のある namespace は、`NamespaceKind -> "Shared" | "Event" | "Unknown"` の推定を持たせ、確定しないまま provenance として保持する。

```wl
<|
  "ObjectClass" -> "SourceVaultTopicItem",
  "TopicItemRef" -> "svtopic:oops:<namespace>:<localId>",
  "Namespace" -> _String,
  "LocalId" -> _Integer,
  "OwnerRef" -> "sventity:owner:..." | Missing["UnknownOwner"],
  "NamespaceKind" -> "Person" | "Shared" | "Event" | "Unknown",
  "CanonicalLabel" -> "...",
  "Aliases" -> {...},
  "SourceSystem" -> "OOPS",
  "SourceRefs" -> {"table/item-name.index"},
  "PrivacyLevel" -> _,
  "ReviewState" -> "Imported" | "NeedsOwnerMapping" | "HumanConfirmed"
|>
```

#### 6.5.2 Seed import parser

`table.zip` の index は Common Lisp S式として読む。正規表現や単純な行分割で読まない。
ただし Phase 0.5 の seed lexical dictionary では、`item-name.index` に限定した軽量 reader から始めてよい。relation / quote / mail mapping を扱う Phase 6 では、下記の完全な S式 reader に置き換える。

必須:

- nested list, symbol, integer, string, escaped string, `nil` に対応する。
- record 境界は括弧バランスで決める。長大行、CR / LF / NEL 混在を許容する。
- `nil` は位置に応じて空リストまたは `Missing["Nil"]` へ写像する。写像規則を parser option として固定する。
- 構造部分は ASCII として読み、文字列 field は `iSVDecodeLegacyJapanese` で個別 decode する。

legacy Japanese decode:

```wl
iSVDecodeLegacyJapanese[bytes_] :=
  quotedPrintableDecode
  -> mimeWordDecode
  -> ISO-2022-JP
  -> CP932
  -> UTF-8
  -> replacementWithWarnings
```

引用テキストには ISO-2022-JP escape が quoted-printable 化された断片と生日本語が混在するため、ファイル単位 encoding ではなく文字列単位で fallback する。

#### 6.5.3 Seed privacy / trust class

OOPS ingest では、元メール header の宛先 (`To`, `Cc`, `Delivered-To`, `X-Original-To`) を privacy の主入力にし、`mail-info.index` の list 名は補助入力として release metadata に反映する。Recipient pattern は display name ではなく、lowercase 正規化した addr-spec 全体に対して評価する。

既定 mapping:

```wl
<|
  "RecipientPatterns" -> {
    <|"Pattern" -> "oops@*", "PrivacyLevel" -> 0.6,
      "Tags" -> {"OOPS", "MailingList"}|>,
    <|"Pattern" -> "oops-ura@*", "PrivacyLevel" -> 0.6,
      "Tags" -> {"OOPS", "MailingList", "PrivateML",
        "NoCloudLLM", "NoPublicExport"}|>,
    <|"Pattern" -> "oops-omote@*", "PrivacyLevel" -> 0.4,
      "Tags" -> {"OOPS", "MailingList"}|>
  },
  "ListFallbacks" -> <|
    "oops" -> <|"PrivacyLevel" -> 0.6, "Tags" -> {"OOPS", "MailingList"}|>,
    "oops-ura" -> <|"PrivacyLevel" -> 0.6,
      "Tags" -> {"OOPS", "MailingList", "PrivateML",
        "NoCloudLLM", "NoPublicExport"}|>,
    "oops-omote" -> <|"PrivacyLevel" -> 0.4, "Tags" -> {"OOPS", "MailingList"}|>
  |>
|>
```

宛先と list fallback が矛盾する場合は、より高い `PrivacyLevel` と sensitivity tag の union を採用する。この mapping は profile 化し、owner が明示承認してから bulk import する。`oops-ura` は silent public import しない。topic item relation だけを取り込む場合も、supporting mail / quoted text が private list 由来なら、その provenance と privacy を保持する。

宛先 / list fallback による privacy は下限であり、最終 privacy ではない。import 時に PII / third-party content を検出し、住所、電話番号、個人メール、私的 chat log、第三者メール全文、実名と私的内容の組み合わせを含む場合は `PrivacyLevel` を引き上げ、`ThirdPartyContent`, `NoCloudLLM`, `NoPublicExport` を object `Tags` に付ける。owner 承認には第三者素材の扱いを含める。

v1 の PII / third-party floor detector は決定的規則から始める。電話番号 `\d{2,4}-\d{2,4}-\d{4}`、郵便番号 `\d{3}-\d{4}`、メールアドレス、URL、住所らしい都道府県/市区町村列、`AIM IM` / `chat log` / `との.*IM` など第三者会話 marker、引用直後の対話ログ marker を検出し、確信が低い場合は fail-safe に `NeedsHumanReview` と `ThirdPartyContent` を付ける。

`PrivateML` / `ThirdPartyContent` / `NoCloudLLM` / `NoPublicExport` の enforcement は新経路を作らず、既存 `SourceVaultEvaluateReleasePolicy` の `DenyTags` / release-policy 機構に載せる。object 側には `DenyTags` を置かず、sensitivity を `Tags` として保持する。cloud LLM sink の ReleaseContext は `DenyTags -> {"PrivateML", "ThirdPartyContent", "NoCloudLLM"}`、public export の ReleaseContext は `DenyTags -> {"PrivateML", "ThirdPartyContent", "NoPublicExport"}` を持つ。

trust / deny tag vocabulary:

| Tag | Meaning | Default handling |
|---|---|---|
| `OOPS` | OOPS corpus 由来 | provenance 表示 |
| `MailingList` | mailing list 投稿 | list profile を適用 |
| `PrivateML` | private / closed list | cloud / public export deny |
| `ThirdPartyContent` | 第三者発話、第三者 PII、私的 chat / mail 引用 | cloud / public export deny |
| `NoCloudLLM` | cloud LLM prompt への投入禁止 trigger tag | cloud LLM context の `DenyTags` で拒否 |
| `NoPublicExport` | public export 禁止 trigger tag | export context の `DenyTags` で拒否 |

#### 6.5.4 Weighted directed relations

`item-relation.index` と `item-relation-up.index` は別方向の relation として読む。各 edge は count / weight を保持する。

```wl
<|"From" -> topicRefA, "To" -> topicRefB,
  "EdgeKind" -> "SeedRelationDown" | "SeedRelationUp",
  "Weight" -> count, "SourceRefs" -> {...}|>
```

KG local expansion では `Weight` を edge prior として使い、`MinEdgeWeight` と top-k neighbor 制限を適用する。

一般メール向けの paragraph topic item:

```wl
<|
  "ObjectClass" -> "SourceVaultMailParagraphTopicItem",
  "TopicItemId" -> "svtopic:auto:...",
  "CanonicalLabel" -> "...",
  "Aliases" -> {...},
  "SeedRefs" -> {"svtopic:oops:ki:2573", "svtopic:oops:mi:33", ...},
  "ParagraphRef" -> "svmailpara:...",
  "MailRef" -> "sv://mail/...",
  "Confidence" -> 0.0..1.0,
  "AssignmentKind" -> "ExplicitOOPS" | "SeedMatched" | "AutoExtracted" | "LLMProposed" | "HumanConfirmed",
  "TopicRole" -> "Primary" | "Secondary" | "Mentioned",
  "EvidenceSpanRefs" -> {"span:..."},
  "CreatedAtUTC" -> "..."
|>
```

段落分割:

- plain text mail は空行区切りを基本にする。
- quote block は独立 paragraph とし、`QuotedFrom` を付ける。
- 署名、引用ヘッダ、ML footer は paragraph から分離する。
- HTML mail は DOM block を paragraph に正規化する。

topic 付与:

1. 明示 topic item があればそれを採用する。OOPS 形式では `◎` primary、`○` secondary、`・` mentioned。
2. 本文中の `{label[namespace n]}` と `[namespace n]` を owner-scoped seed topic item に解決する。
3. seed ontology の item name / aliases / relation 近傍で lexical match する。
4. BM25 / embedding / LLM extractor で paragraph keyword を提案する。
5. 既存 topic に近い場合は既存 item に attach、遠い場合は `AutoExtracted` topic item を新規作成する。
6. LLM 提案は `ReviewState -> NeedsReview` とし、検索 ranking には低重みで使う。human confirmed で昇格する。
7. auto topic は human confirm まで seed item を上書きしない。同一 label でも owner namespace が違えば merge しない。

quote tracking:

```wl
<|
  "ObjectClass" -> "SourceVaultMailQuoteEdge",
  "QuoteEdgeId" -> "svquote:...",
  "SeedQuoteId" -> Missing[] | "standard-quote:524",
  "FromParagraphRef" -> "svmailpara:reply:...",
  "ToParagraphRef" -> "svmailpara:source:...",
  "FromMailRef" -> "sv://mail/...",
  "ToMailRef" -> "sv://mail/...",
  "QuoteKind" -> "SeedStandardQuote" | "ExplicitMarker" | "HeaderInReplyTo" |
    "LinePrefix" | "FuzzyTextMatch" | "ExternalURL" | "Unresolved",
  "QuotedTextHash" -> "...",
  "Confidence" -> 0.0..1.0,
  "SourceMarker" -> "-*- Quote (from 6539) -*-"
|>
```

厳密 tracking の順序:

1. ML counter / `Message-ID` / `In-Reply-To` / `References` を使う。
2. OOPS marker `Quote (from n)` を mail number に解決する。
3. seed の `(standard-quote qid)` は `SeedQuoteId` として保持し、`quoted-table.index` の引用テキスト・出現数へ接続する。OOPS seed 由来メールでは seed quote table を authoritative graph とし、hash / fuzzy 再導出で上書きしない。
4. quoted text の normalized hash / simhash / line hash は、必ず `iSVDecodeLegacyJapanese` と正規化の後に計算する。これは seed table で解決できない非 seed / 一般メールの照合に使う。
5. `>` prefix の通常メール引用は quote block として抽出し、候補元メール内 paragraph と fuzzy match する。
6. URL quote は `ExternalURL` edge にする。web ingest 済みなら svweb URI へ解決する。

topic item graph:

```wl
<|
  "ObjectClass" -> "SourceVaultTopicItemGraph",
  "GraphId" -> "svtopicgraph:...",
  "Nodes" -> {
    <|"TopicItemRef" -> "svtopic:...", "Label" -> "...", "SupportParagraphs" -> {...}|>
  },
  "Edges" -> {
    <|"From" -> "svtopic:...", "To" -> "svtopic:...",
      "EdgeKind" -> "CoParagraph" | "QuoteTransition" | "ReplyContinuation" |
        "NegotiationUpdate" | "Contradiction" | "Resolution" | "SeedRelation",
      "Weight" -> _, "EvidenceRefs" -> {...}|>
  },
  "MailSessionRefs" -> {...},
  "BuiltAtUTC" -> "..."
|>
```

メールセッション:

```wl
<|
  "ObjectClass" -> "SourceVaultMailSession",
  "MailSessionId" -> "svmailsession:...",
  "MailRefs" -> {"sv://mail/..."},
  "ParagraphRefs" -> {"svmailpara:..."},
  "TopicItemRefs" -> {"svtopic:..."},
  "StartDate" -> _,
  "EndDate" -> _,
  "Status" -> "Open" | "Resolved" | "Dormant" | "Split" | "Merged",
  "SessionKind" -> "ReplyThread" | "QuoteCluster" | "Negotiation" | "TopicCluster",
  "ResolutionRefs" -> {"svmailpara:..."},
  "SummaryRef" -> "svsummary:..."
|>
```

session / cluster 推定:

- `ReplyThread`: `In-Reply-To` / `References` / Subject `Re:`。
- `QuoteCluster`: quote edge の連結成分。
- `TopicCluster`: topic item graph の密な部分グラフ。
- `Negotiation`: 日程、可否、提案、承認、決定、キャンセルなどの speech act が時系列に現れる cluster。
- 終了判定: 明示的結論、決定表現、以後一定期間 reply なし、または owner が close。

メールセッションサマリー:

単一メールではなく `SourceVaultMailSession` 単位に作る。

```wl
<|
  "ObjectClass" -> "SourceVaultMailSessionSummary",
  "MailSessionId" -> "svmailsession:...",
  "Summary" -> "...",
  "Timeline" -> {
    <|"Date" -> _, "MailRef" -> _, "Event" -> "Proposal" | "CounterProposal" | "Decision" | "Cancellation", "Text" -> "... "|>
  },
  "TopicEvolution" -> {
    <|"TopicItemRef" -> _, "State" -> "Introduced" | "Changed" | "Resolved", "EvidenceRefs" -> {...}|>
  },
  "OpenIssues" -> {...},
  "ResolvedItems" -> {...},
  "GroundingRefs" -> {"svmailpara:...", "svquote:..."},
  "PrivacyLevel" -> _,
  "SafetyState" -> "active" | "warning" | "quarantined"
|>
```

検索への使い方:

- `SourceVaultPrimerIndex` に mail session summary を入れる。
- paragraph topic item は `KG local expansion` の node として使う。
- quote edge は `QuoteTransition` / `ReplyContinuation` edge として使う。
- 日程や事項の最終結論を探す query では、単一メールより `MailSessionSummary` を優先する。
- 最終回答は session summary だけでなく、該当 paragraph / quote edge の grounding refs を必ず含める。

Public API:

```wl
SourceVaultImportOOPSTopicSeed[zipPath_String, opts___] := ...
SourceVaultParseMailParagraphs[mail_Association, opts___] := ...
SourceVaultAssignParagraphTopics[paragraphs_List, opts___] := ...
SourceVaultBuildMailQuoteGraph[mails_List, opts___] := ...
SourceVaultBuildMailTopicItemGraph[mails_List, opts___] := ...
SourceVaultDetectMailSessions[topicGraph_Association, opts___] := ...
SourceVaultSummarizeMailSession[session_Association, opts___] := ...
SourceVaultBuildMailSessionPrimerIndex[contextName_String, opts___] := ...
```

### 6.6 SearchContextProfile

同じ metadata でも、検索目的により意味が変わる。作成日、変更日、撮影日、イベント実施日、受信日、ingest 日、返信日、引用元の日付を区別し、検索 context ごとに重みを変える。

```wl
<|
  "ObjectClass" -> "SourceVaultSearchContextProfile",
  "ProfileId" -> "svsearchctx:...",
  "Intent" -> "FindEvent" | "FindCreation" | "FindIngest" | "FindNegotiationOutcome" |
    "FindRecentWork" | "FindOriginalArtifact" | "RecallPersonalMemory",
  "PrimaryTemporalFields" -> {"EventDate", "MailSessionResolutionDate"},
  "SecondaryTemporalFields" -> {"MessageDate", "FileCreatedAt", "IngestedAt"},
  "MetadataWeights" -> <|
    "Title" -> 1.0,
    "Author" -> 0.7,
    "Sender" -> 0.7,
    "TopicItems" -> 1.0,
    "EventDate" -> 1.0,
    "MessageDate" -> 0.4,
    "IngestedAt" -> 0.2,
    "EXIFOriginalDate" -> 0.9,
    "FileMTime" -> 0.2
  |>,
  "TemporalInterpretation" -> <|
    "next Friday" -> "EventDatePreferred",
    "recently added" -> "IngestedAtPreferred",
    "taken in 2020" -> "EXIFOriginalDatePreferred"
  |>
|>
```

検索時の適用:

- query intent を rule / LLM-free classifier で推定し、profile を選ぶ。
- ユーザ指定があればそれを優先する。
- date filter は単一 field に落とさず、profile の primary / secondary field に分配する。
- score breakdown に metadata contribution を明示する。
- context profile は ranking だけを変え、release gate は変えない。

Public API:

```wl
SourceVaultRegisterSearchContextProfile[id_String, spec_Association, opts___] := ...
SourceVaultSelectSearchContextProfile[query_String, opts___] := ...
SourceVaultApplySearchContextProfile[results_List, profile_Association, opts___] := ...
SourceVaultExplainSearchContext[result_Association, profile_Association, opts___] := ...
```

### 6.7 Associative level

PDF の「associative level」を、検索提示と ranking の補助信号として扱う。これは privacy level ではなく、ユーザがその node をどの程度すぐ思い出せるかの推定である。

入力:

- 過去 episode での read / cite / include / reject。
- 同じ topic item / mail session への再訪頻度。
- ユーザが要約だけで理解できたか、本文まで読んだか。
- optional biometric / UI dwell は将来拡張。

使い方:

- associative level が高い node は concise summary を優先表示。
- 低い node は詳細、経緯、引用関係、周辺 topic を厚く表示。
- ranking では「現在の思考に近いが忘れていそうな node」を探索候補に残す。
- 古い content であること自体は negative signal にしない。古い、関連が強い、associative level が低い node は、再想起支援のため候補に残すか、context profile に応じて上げる。
- privacy lowering operation には使わない。認知状態や privacy gate とは別の presentation control とする。

### 6.8 Live hypertext interaction / annotation graph

`LiveNotebookHypertext` / `ContextSubgraphNotebook` でユーザや LLM がリンクをたどる行為は、新しい検索信号として SourceVault に蓄積する。閲覧 UI は単なる表示ではなく、topic item graph の上に interaction meta-layer を作る入口である。

interaction event:

```wl
<|
  "ObjectClass" -> "SourceVaultTopicItemInteractionEvent",
  "EventId" -> "svinteract:...",
  "Actor" -> <|"Kind" -> "Owner" | "LLM" | "Tool", "Ref" -> "... "|>,
  "ActionKind" -> "Viewed" | "FollowedLink" | "ExpandedNode" |
    "Cited" | "Copied" | "Annotated" | "Rejected",
  "ViewRef" -> "svview:...",
  "SearchSessionRef" -> "svsession:...",
  "FromNodeRef" -> Missing[] | "svtopic:..." | "svmailpara:...",
  "ToNodeRef" -> "svtopic:..." | "svmailpara:..." | "svquote:..." | "svannotation:...",
  "EdgeRef" -> Missing[] | "svedge:..." | "svquote:...",
  "OutputRef" -> Missing[] | "sv://derived/...",
  "AnnotationRef" -> Missing[] | "svannotation:...",
  "OccurredAtUTC" -> "...",
  "ReleaseContextRef" -> "..."
|>
```

`FollowedLink` / `ExpandedNode` は navigation prior として bounded に使う。`Cited` は evidence inclusion として強い positive signal、`Rejected` は bounded negative signal とする。LLM actor の signal は owner action より低く抑え、retrieval episode と同じ actor weighting / frequency normalization を適用する。

annotation / branch:

```wl
<|
  "ObjectClass" -> "SourceVaultGraphAnnotation",
  "AnnotationRef" -> "svannotation:...",
  "TargetNodeRef" -> "svtopic:..." | "svmailpara:..." | "svquote:..." | "svview:...",
  "BranchRef" -> "svbranch:...",
  "Body" -> "...",
  "AuthorRef" -> "sventity:owner:imai" | "svactor:llm:...",
  "CreatedAtUTC" -> "...",
  "Provenance" -> <|"ViewRef" -> "svview:...", "SearchSessionRef" -> "svsession:..."|>,
  "ReviewState" -> "Draft" | "Published" | "NeedsReview",
  "Tags" -> {...}
|>
```

検索結果 view 上の summary / node / edge には追記できる。追記は元 object を破壊せず `SourceVaultGraphAnnotation` として別 object に保存し、`BranchRef` により新しい解釈・調査ブランチを作る。既存 notebook summary append 機能と同じ思想で、検索結果から到達した node に対しても `SourceVaultAppendGraphAnnotation` を使えるようにする。

meta-layer graph:

- node: actor, search view, topic item, mail paragraph, quote edge, annotation, derived output。
- edge: `Viewed`, `Followed`, `Cited`, `Annotated`, `BranchedFrom`, `Supports`, `Contradicts`。
- search は base topic graph と meta-layer graph の両方を使える。ただし meta-layer boost は release gate を緩めず、行動ログとして高機密に扱う。
- notebook UI では、annotation branch を折りたたみ可能な cell group として表示し、元 topic item graph と区別して色・style を変える。

Public API:

```wl
SourceVaultBuildSearchView[query_String, opts___] := ...
SourceVaultRenderSearchNotebookView[viewRef_String, opts___] := ...
SourceVaultFollowSearchViewLink[viewRef_String, linkRef_String, opts___] := ...
SourceVaultRecordTopicItemInteraction[event_Association, opts___] := ...
SourceVaultAppendGraphAnnotation[targetRef_String, body_String, opts___] := ...
SourceVaultBuildInteractionMetaGraph[opts___] := ...
```

---

## 7. AgenticKeywordSearch / Cascade

### 7.1 Workflow kinds

既存 enum の `"AgenticKeywordSearch"` と `"Cascade"` を実装対象にする。

`AgenticKeywordSearch`: index-free / query-time 型。小さな primer とゲート付き body search を反復する。

`Cascade`: BM25 / mined lexical / optional dense / agentic を query complexity に応じて段階的に使う。

### 7.2 Public API

```wl
SourceVaultAgenticSearch[query_String, opts___] := <|
  "Results" -> {...},
  "Views" -> {"svview:..."},
  "AnswerDraft" -> Missing[] | _String,
  "Trace" -> <|...|>,
  "Stopped" -> "EnoughEvidence" | "MaxIterations" | "NoProgress" | "BudgetExceeded"
|>
```

Options:

```wl
{
  "ReleaseContext" -> None,
  "Index" -> None,
  "PrimerIndex" -> Automatic,
  "Limit" -> 10,
  "MaxIterations" -> 3,
  "MaxToolCalls" -> 12,
  "MinGroundedEvidence" -> 2,
  "NoProgressTermination" -> True,
  "AllowLLMPlanning" -> False,
  "PlannerFn" -> Automatic,
  "ReadBody" -> False,
  "Grant" -> None,
  "ResultView" -> "RankedList",
  "GraphLayout" -> Automatic,
  "ContextSubgraphDepth" -> 1,
  "NotebookInteractivity" -> "Static",
  "ReturnTrace" -> True
}
```

`AllowLLMPlanning -> False` の既定では deterministic planner を使う。LLM planning を使う場合でも、入力 text は data boundary で囲み、tool 権限は検索 tool のみに限定する。
`ResultView -> "LiveNotebookHypertext"` または `"ContextSubgraphNotebook"` の場合、answer draft ではなく live notebook view を主成果物として返せる。LLM actor が view 内リンクをたどる場合も、各 navigation / citation / annotation は interaction event として記録する。

### 7.3 Agent tools

内部 tool は直接 FS を読まない。

```wl
SearchPrimer[query, filters]       -> SourceVaultPrimerSearch
SearchChunks[query, objectFilter]  -> SourceVaultSearch
ExpandGraph[objects, edgeKinds]    -> SourceVaultExpandSearchGraph
GetSummary[uri]                    -> SourceVaultMCPGet view=summary
GetBody[uri, grant]                -> SourceVaultMCPGet view=body
RecallEpisodeMemory[query, ctx]    -> SourceVaultSearchEpisodeMemory
SearchMailSessions[query, ctx]     -> SourceVaultSearch with MailSessionPrimerIndex
ApplySearchContext[results, ctx]   -> SourceVaultApplySearchContextProfile
RecordInteraction[uri, kind]       -> SourceVaultObjectInteractionRecordedEvent
BuildSearchView[results, opts]     -> SourceVaultBuildSearchView
FollowViewLink[view, link]         -> SourceVaultFollowSearchViewLink
AppendGraphAnnotation[target, txt] -> SourceVaultAppendGraphAnnotation
```

`GetBody` は grant が無い場合、本文を返さず `RequiresGrantFor` を trace に残す。agent は grant なしで本文取得を再試行しない。

### 7.4 Loop

```text
state = <|Query, Candidates->{}, Evidence->{}, TriedQueries->{}, Trace|>

1. classify complexity
2. select SearchContextProfile
3. recall retrieval episode memory
4. primer search, including mail session primer when relevant
5. graph expansion, including topic item / quote graph
6. chunk/body search for selected objects
7. apply context profile and evidence sufficiency check
8. if insufficient: generate follow-up query deterministically or via PlannerFn
9. stop on EnoughEvidence / NoProgress / budget
10. record confirmed retrieve/cite/search attempts as retrieval episode
```

### 7.5 Complexity classifier

初期実装は rule-based。

`Simple`:

- query length が短い。
- 固有名詞・型番・単一語検索。
- `SourceVaultSearch` BM25 top score が閾値以上かつ evidence 2 件以上。

`Complex`:

- 「比較」「関係」「なぜ」「経緯」「誰が」「いつから」「矛盾」「根拠」など multi-hop 兆候。
- BM25 top score が低い。
- primer と body result が一致しない。
- stale primer の上位比率が高い。
- 日程交渉、結論、議論の推移、過去にどう調べたかを問う。

`Cascade` は `Simple -> BM25/MinedSearch`、`Complex -> AgenticKeywordSearch` に dispatch する。

### 7.6 Deterministic follow-up query generation

`AllowLLMPlanning -> False` の follow-up query は、LLM なしで以下から作る。

1. top grounded evidence の title / topic item / entity terms。
2. seed entity dictionary の aliases。
3. weighted topic relation の 1 hop neighbor（top-k、weight 閾値あり）。
4. retrieval episode memory の high-influence query terms。
5. SearchContextProfile の primary metadata field。例: event query なら `EventDate`、ingest query なら `IngestedAt`。

制約:

- query expansion は最大 2 個まで同時に足す。
- seed relation expansion は owner namespace を跨ぐ場合、edge provenance と confidence を trace に残す。
- expansion 後の query が既に `TriedQueries` にある場合は採用しない。
- follow-up で得た候補も request-time gate / revocation / safety gate を通す。

---

## 8. MCP 統合

### 8.1 SearchSpec 拡張

`SourceVaultNormalizeSearchSpec` の `methods` に以下を許可する。

```json
["keyword", "bm25", "mined", "primer", "episode", "mailSession", "topicGraph",
 "contextual", "liveView", "agentic", "cascade", "dense", "hybrid"]
```

既定は現行どおり `["keyword", "metadata"]`。`"all"` は既存動作を維持する。
SearchSpec は method とは別に `resultView` を持てる。`resultView` は `"rankedList" | "liveNotebook" | "contextSubgraphNotebook" | "graphPlot" | "orderedTree" | "all"` とし、未指定なら `"rankedList"`。

### 8.2 sourcevault_search

`SourceVaultMCPSearch` は method に応じて adapter search を選ぶ。

- `bm25`: `SourceVaultSearch` with `KeywordBM25V1` index。
- `mined`: `SourceVaultMinedSearch`。
- `primer`: `SourceVaultPrimerSearch`。`SummaryPrimer` と明示。
- `episode`: `SourceVaultSearchEpisodeMemory`。過去の検索試行錯誤から query / object prior を返す。
- `mailSession`: メール返信・引用・topic item graph から作った session summary を検索する。
- `topicGraph`: paragraph topic item / quote edge / topic-to-topic relation を graph search する。
- `contextual`: `SearchContextProfile` を明示適用した検索。
- `liveView`: ranking results から `SourceVaultSearchView` を作り、Notebook / graph / ordered tree の view ref を返す。
- `agentic`: `SourceVaultAgenticSearch`。本文が必要なら grant を尊重。
- `cascade`: complexity classifier による自動 dispatch。

MCP response は `AccessRequest` を内部用に保持し、外部返却では既存どおり必要に応じて落とす。
`resultView != "rankedList"` の response は、通常の `results` に加えて `views -> {ViewRef, ViewKind, RootNodeRefs, NotebookRef|Missing[]}` を返す。外部クライアントが notebook を直接開けない場合でも、view ref を使ってリンク展開・annotation 追記を継続できる。

### 8.3 sourcevault_get

`sourcevault_get view=body` は既存 grant gate を使う。agentic loop から呼ぶ場合も同じ。

`view=summary` と `view=metadata` は低漏洩 projection。`view=raw` / file path 相当は追加しない。

---

## 9. Optional dense / rerank

v1 の必須実装ではない。導入する場合は以下に限定する。

- 対象は primer item、summary、mining node の小 N。
- 生 body 全チャンクへの全面 embedding は初期実装しない。
- 外部 API embedding は ReleaseContext / sink / cloud publishable policy を通す。
- lexical と dense は RRF で融合する。

RRF:

```text
RRF(d) = Sum_i 1 / (k + rank_i(d)), k = 60
```

Rerank は上位 50-100 件だけ。JaColBERT / cross-encoder は外部 serving stack が必要なため profile 登録制にする。

```wl
SourceVaultRegisterSearchBackend["jacolbert-local", <|
  "Kind" -> "Reranker",
  "Provider" -> "LocalHTTP",
  "EndpointRef" -> "profile:..."
|>]
```

---

## 10. Evaluation / promotion

### 10.1 Baselines

評価 arm:

- B0: 現行 `KeywordBigram` / `iKeywordScore`。
- B1: `KeywordBM25V1`。
- B2: `SourceVaultMinedSearch`。
- B3: `PrimerSearch -> BM25 body grounding`。
- B4: `AgenticKeywordSearch`。
- B5: `Cascade`。
- B6: optional dense / hybrid / rerank。

### 10.2 Metrics

既存 `SourceVaultEvaluateRetrievalWorkflow` に加えて、retrieval metrics を追加する。

```wl
<|
  "RecallAt20" -> _,
  "NDCGAt10" -> _,
  "MAPAt100" -> _,
  "GroundedEvidenceRate" -> _,
  "PrimerOnlyAnswerCount" -> 0,
  "ReleasePolicyViolationCount" -> 0,
  "RawPathLeakCount" -> 0,
  "LatencyP50Ms" -> _,
  "LatencyP95Ms" -> _,
  "ToolCallCount" -> _,
  "LLMCallCount" -> _,
  "TokenCost" -> _
|>
```

`PrimerOnlyAnswerCount > 0` は promotion 禁止。

### 10.3 Evaluation item schema

```wl
<|
  "Question" -> "...",
  "RelevantObjectRefs" -> {"sv://..."},
  "RelevantEvidenceRefs" -> {"evid:..."},
  "RelevanceJudgments" -> <|"evid:..." -> 2, "evid:..." -> 1|>,
  "ExpectedAnswerContains" -> "...",
  "ExpectInScope" -> True,
  "QueryClass" -> "Simple" | "Complex" | "JapaneseLexical" | "MultiHop"
|>
```

Track A の promotion gate に使う judged retrieval eval corpus は Phase 1 で作る。初期は少数の実 SourceVault query と、OOPS held-out から作った query/evidence pair を混ぜ、各 evidence に 0/1/2 の relevance judgment を持たせる。OOPS topic 復元 held-out は seed dictionary の仮説検証には使うが、BM25 core promotion では実 vault query の judged set と分けて report する。

### 10.4 Promotion gate

Workflow promotion 条件:

- `ReleasePolicyViolationCount == 0`
- `RawPathLeakCount == 0`
- `PrimerOnlyAnswerCount == 0`
- B1 は B0 に対して `RecallAt20` と `NDCGAt10` が同等以上。
- Cascade は simple query の latency P95 を B1 の 2 倍以内に保つ。超える場合は adaptive classifier を調整する。

---

## 11. 実装フェーズ

本仕様は実装トラックを分ける。

- **Track A: Search v1**。Phase 0, 0.5, 1, 2, 3, 4。検索精度をすぐ上げる最小実装。seed ontology はまず lexical entity dictionary として使う。
- **Track B: Mail topic graph**。Phase 6, 7。OOPS seed ontology importer と一般メール topic item graph。Track A をブロックしない。
- **Track C: Retrieval episode / associative research**。Phase 5 と associative level。自己強化と行動ログ機密性の評価が必要。Track A をブロックしない。
- **Track D: Agentic / Cascade integration**。Phase 8 以降。Track A の安定後に接続する。

### Phase 0: API skeleton / docs

- `SourceVault_searchindex.wl` に `KeywordBM25V1` 用 private 関数の skeleton を追加。
- `SourceVaultBuildProjectionIndex` options を拡張。
- `SourceVaultListRetrievalWorkflowKinds[]` にある `AgenticKeywordSearch` / `Cascade` の spec 例を docs に追加。
- API docs を更新。

完了条件:

- 既存テスト・既存 `KeywordBigram` 動作が変わらない。
- 新 options を指定しなければ snapshot schema が実質同じ。

### Phase 0.5: seed lexical dictionary and hypothesis test

- `SourceVaultImportOOPSTopicSeed` のうち `item-name.index` だけを読む最小 importer。
- owner-scoped `SourceVaultSeedEntityDictionary` を作る。
- 明示 topic `[namespace n]` を伏せた OOPS paragraph held-out set を作る。
- lexical entity dictionary のみで topic item 復元を評価する。
- 評価開始前に、辞書あり BM25 と辞書なし BM25 の差分成功閾値を事前登録する。

完了条件:

- namespace を enum で決め打ちせず、`mi` など未知 namespace も保持する。
- query surface を owner-scoped entity union に解決し、owner provenance を保持したまま検索できる。
- held-out paragraph で recall@k / precision@k / seed-hit rate / novel-topic ratio を出せる。
- held-out は literal surface match 層と semantic / hard 層に層別し、train<=T / test>T の time split を含める。
- 辞書あり BM25 と辞書なし BM25 の counterfactual 比較で、事前登録閾値を満たすか判定できる。
- seed-hit が低い場合、Track B は延期する。Phase 0.5 は additive feature であり、Phase 1 BM25 の独立昇格をブロックしない。

### Phase 1: normalization / BM25

- `iSVNormalizeSearchText`
- `iSVSearchTerms`
- `iSVBuildLexicalStats`
- `iSVBM25Score`
- `iNativeSearchBM25`
- `SourceVaultExplainSearchScore`
- judged retrieval eval corpus の最小セットを作る。実 SourceVault query と OOPS held-out 由来 query/evidence pair を含め、0/1/2 relevance judgment を持たせる。
- optional: `EntityDictionaryRefs` による seed entity term 展開。Phase 0.5 が未昇格なら無効のままでもよい。

完了条件:

- 日本語連続文、英数字型番、全角半角混在で score が正になる。
- release gate / revocation / raw path leak 0。
- B1/B0 比較に使う judged retrieval eval corpus が存在し、評価 item の出所が report に出る。
- B1 は B0 に対して `RecallAt20` と `NDCGAt10` が同等以上。Phase 0.5 の seed dictionary が未昇格でも、この条件を満たせば BM25 は独立に promotion できる。

### Phase 2: mined lexical integration

- `SourceVaultMinedSearch` の replay cost を抑える cache を追加する。
- `MiningProjection` を `ScoreBreakdown.MiningBoost` に反映する。
- `ObjectSignals.EffectiveImportance` の bounded prior を有効化する。
- agentic loop 内で候補ごとに event log を replay しない。tag / author / ObjectSignals projection は primer index または専用 cache に precompute する。

完了条件:

- boost が `MaxBoost` を超えない。
- gate で Deny の object が boost により復活しない。

### Phase 3: primer index

- `SourceVaultBuildPrimerIndex`
- `SourceVaultPrimerSearch`
- Eagle summary / mining projection から primer item を生成。
- tag / author / ObjectSignals projection を primer item に precompute し、query-time replay を避ける。
- stale 判定: `SummaryEpoch < SourceEpoch` または `BuiltAtUTC` が source 更新より古い場合 `StalePrimer`。

完了条件:

- primer result は `EvidenceKind -> "SummaryPrimer"`。
- primer のみで answer draft を作らない。

### Phase 4: KG local expansion

- `SourceVaultExpandSearchGraph`
- tag/author/link/interaction edge の重み付け。
- hop/node budget と no-progress stop。

完了条件:

- `MaxHops`, `MaxNodes` を超えない。
- gated out node の内容を返さない。

### Phase 5: retrieval episode feedback

- `SourceVaultStartRetrievalEpisode`
- `SourceVaultRecordSearchAttempt`
- `SourceVaultCloseRetrievalEpisode`
- `SourceVaultEpisodeInfluenceScores`
- `SourceVaultSearchEpisodeMemory`
- MCP / web search / SourceVault search call の attempt 記録。

完了条件:

- 最終 output object と evidence refs から influence score が計算できる。
- LLM actor の influence は bounded / damped。
- episode boost で gate Deny result が復活しない。

### Phase 6: OOPS seed ontology importer

- `SourceVaultImportOOPSTopicSeed`
- Common Lisp S式 reader。
- `iSVDecodeLegacyJapanese`。
- `item-name.index`, `item-relation*.index`, `mail-to-item.index`, `item-to-mail.index`, `quote-table.index`, `quoted-table.index`, `mail-info.index` の parser。
- OOPS topic item を `SourceVaultTopicItem` として immutable snapshot 化。
- `oops 200506.txt` のような mbox-like archive から mail number / explicit topic / quote marker を照合。
- 元メール header の宛先と `mail-info.index` list 名から privacy / trust class を付与し、owner 承認なしに private ML を public import しない。
- import mutation は `ImportRunId` を持ち、同一 source identity の再 import は既存 object を重複生成せず supersede / version update する。
- PII / third-party content scan で list privacy を引き上げ、`ThirdPartyContent`, `NoCloudLLM`, `NoPublicExport` の sensitivity tags を付与できる。

完了条件:

- `(namespace localId)` topic item が label, owner namespace, privacy provenance, relation を持って読める。
- relation の weight と direction を保持する。
- `oops@...` / `oops-ura@...` 宛メールは `PrivacyLevel -> 0.6`、`oops-omote@...` 宛メールは `PrivacyLevel -> 0.4` として ingest される。PII / third-party detector はこの値を下限として引き上げられる。
- PII / third-party floor detector が電話番号、郵便番号、メールアドレス、URL、住所らしい文字列、第三者会話 marker を検出し、`NeedsHumanReview` / `ThirdPartyContent` を付けられる。
- `X-Ml-Counter` と table の mail number が結合できる。
- `Quote (from n)` と `(standard-quote qid)` が quote edge に変換できる。OOPS seed 由来では seed quote table を authoritative とし、hash は decode / normalization 後に非 seed fallback として使う。
- import consistency report 不合格後に parser / decode を修正して再 import しても、重複 topic / mail / quote edge が増えない。
- PDF 記載の概数（mail count / topic title / quote link / relation link）に対する import count consistency report を出せる。

### Phase 7: mail paragraph topic item graph

- `SourceVaultParseMailParagraphs`
- `SourceVaultAssignParagraphTopics`
- `SourceVaultBuildMailQuoteGraph`
- `SourceVaultBuildMailTopicItemGraph`
- `SourceVaultDetectMailSessions`
- `SourceVaultSummarizeMailSession`
- `SourceVaultBuildMailSessionPrimerIndex`

完了条件:

- 明示 OOPS topic は `ExplicitOOPS` として保持される。
- 一般メール paragraph に `AutoExtracted` topic item が付与される。
- quote edge は marker / header / fuzzy text の confidence を区別する。
- session summary は grounding paragraph / quote refs を持つ。
- negotiation / contradiction / resolution の種別推定は best-effort signal とし、v1 の昇格 DoD にはしない。

### Phase 7.5: live notebook search view / annotation branch

- `SourceVaultBuildSearchView`
- `SourceVaultRenderSearchNotebookView`
- `SourceVaultFollowSearchViewLink`
- `SourceVaultRecordTopicItemInteraction`
- `SourceVaultAppendGraphAnnotation`
- `SourceVaultBuildInteractionMetaGraph`

完了条件:

- 同じ検索結果から `RankedList`, `LiveNotebookHypertext`, `ContextSubgraphNotebook`, `GraphPlot`, `OrderedTree` を選択して返せる。
- Mathematica notebook cell 上で topic item / mail paragraph / quote / annotation をたどれる。リンク先は lazy load され、request-time gate を通る。
- 検索コンテクストを topic item graph の部分グラフとして切り出し、順序木として notebook cell group に展開できる。
- `FollowedLink`, `Viewed`, `Cited`, `Annotated` が interaction event として保存され、retrieval episode / meta-layer graph に接続できる。
- 検索結果 view 上の summary / node / edge に追記でき、元 object を破壊せず annotation branch を作れる。

### Phase 8: SearchContextProfile

- `SourceVaultRegisterSearchContextProfile`
- `SourceVaultSelectSearchContextProfile`
- `SourceVaultApplySearchContextProfile`
- `SourceVaultExplainSearchContext`
- date / metadata field の context-sensitive weighting。

完了条件:

- イベント日、メール送信日、写真撮影日、file mtime、ingest 日を別 field として扱える。
- query intent により primary temporal field が変わる。
- score breakdown に metadata contribution が出る。

### Phase 9: AgenticKeywordSearch

- deterministic planner。
- internal tool dispatcher。
- trace schema。
- interaction write-back。
- retrieval episode memory / mail session primer / SearchContextProfile の利用。

完了条件:

- `MaxIterations`, `MaxToolCalls` で停止する。
- 同じ query / 同じ index で deterministic mode の trace が安定する。
- body grant が無い場合に本文を返さず停止・継続判断できる。
- episode / mail session / topic graph を使っても grounded evidence なしで answer しない。

### Phase 10: Cascade / MCP

- complexity classifier。
- `methods -> {"cascade"}` support。
- `methods -> {"episode"|"mailSession"|"topicGraph"|"contextual"|"liveView"}` support。
- `sourcevault_search` response に `RetrievalKind` と gated trace summary を含める。
- `resultView` に応じて `views` を返し、Notebook を開けない client でも `ViewRef` から follow / annotation を継続できる。

完了条件:

- simple query は agentic loop に上がらない。
- complex query は evidence 不足時のみ agentic に上がる。
- 日程交渉・結論探索 query は mail session summary を primer にする。
- `resultView -> "rankedList"` 以外でも release gate / raw path leak / primer-only answer の安全条件が変わらない。

### Phase 11: optional dense / rerank

- 小 N primer embedding profile。
- RRF fusion。
- reranker backend profile。

完了条件:

- external sending policy を通さない data は cloud embedding に送らない。
- dense-only arm が lexical を置換しない。

---

## 12. 変更対象ファイル

### `SourceVault_searchindex.wl`

- normalization / tokenizer / BM25
- `SourceVaultBuildProjectionIndex` option 拡張
- `iNativeSearch` dispatch
- score explanation
- retrieval metrics 拡張
- workflow snapshot examples
- `SearchContextProfile` registry / application / explanation
- `ResultView` option と `SourceVaultSearchView` refs の返却

### `SourceVault_mining.wl`

- `SourceVaultMinedSearch` cache / score breakdown
- `SourceVaultBuildPrimerIndex`
- `SourceVaultPrimerSearch`
- `SourceVaultExpandSearchGraph`
- interaction write-back helper
- retrieval episode graph / influence scoring
- OOPS seed ontology importer
- paragraph topic item graph / mail session summary
- topic item interaction event の ranking prior 反映

### `SourceVault_mcp.wl`

- `methods` enum 拡張
- `SourceVaultMCPSearch` method dispatch
- `agentic` / `cascade` response rendering
- trace の prompt-visible / local-only 分離
- episode / mailSession / topicGraph / contextual / liveView method support
- `resultView` / `views` response rendering

### `SourceVault_eagle.wl`

- summary record から primer item を作る helper
- `SummaryStatus` / privacy / stale 情報の projection

### `SourceVault_maildb.wl`

- mail paragraph extraction
- quote block / reply header / References parser
- mail session object generation
- mail session summary grounding refs

### `SourceVault_topicgraph.wl`（新規推奨）

- `SourceVaultTopicItem`
- `SourceVaultMailParagraphTopicItem`
- `SourceVaultMailQuoteEdge`
- `SourceVaultTopicItemGraph`
- graph build / traversal / session detection

### `SourceVault_searchview.wl`（新規推奨）

- `SourceVaultSearchView`
- `SourceVaultBuildSearchView`
- `SourceVaultRenderSearchNotebookView`
- `SourceVaultFollowSearchViewLink`
- `SourceVaultRecordTopicItemInteraction`
- `SourceVaultAppendGraphAnnotation`
- `SourceVaultBuildInteractionMetaGraph`
- notebook cell group / GraphPlot / ordered tree rendering

### docs

- `SourceVault_info/docs/api_searchindex.md`
- `SourceVault_info/docs/api_mining.md`
- `SourceVault_info/docs/api_mcp.md`
- `SourceVault_info/docs/api_maildb.md`
- `SourceVault_info/docs/api_topicgraph.md`
- 必要なら `SourceVault_info/docs/examples/*`

---

## 13. Trace / observability

Trace は内容漏洩を避けるため、prompt-visible と local-only を分ける。

```wl
<|
  "TraceId" -> "svtrace:...",
  "RetrievalKind" -> "Cascade",
  "PromptVisible" -> <|
    "Iterations" -> 2,
    "ToolCalls" -> 5,
    "Stopped" -> "EnoughEvidence",
    "GatedOutCount" -> 3,
    "PrimerUsed" -> True,
    "GroundedEvidenceCount" -> 2
  |>,
  "LocalOnly" -> <|
    "CandidateObjectRefs" -> {...},
    "DroppedReasons" -> {...},
    "PlannerQueries" -> {...},
    "TimingsMs" -> <|...|>
  |>
|>
```

`LocalOnly` は cloud prompt / MCP structured response に出さない。

---

## 14. Failure modes

| Failure | 戻り値 | 備考 |
|---|---|---|
| ReleaseContext missing | `Failure["ReleaseContextRequired", ...]` | 既存維持 |
| Unsupported index kind | `Failure["UnsupportedIndexKind", ...]` | index id / kind を含める |
| Primer unavailable | lexical に fallback | warning に残す |
| Body grant missing | body は返さず `RequiresGrantFor` | agent は再試行しない |
| LLM planner timeout | deterministic follow-up または stop | answer を捏造しない |
| No grounded evidence | `Results -> {}` or primer refs only | answer draft は Missing |
| Gate mismatch at request time | result 除外 | trace count に残す |
| OOPS table parse error | partial seed ontology + warning | 元メール検索は継続 |
| Quote source unresolved | `QuoteKind -> "Unresolved"` | edge は低 confidence で保持 |
| SearchContext ambiguous | default profile + explanation | date filter を単一 field に固定しない |
| Live view link denied | placeholder cell or hidden edge | request-time gate を優先し、node 本文を出さない |
| Annotation target denied | `Failure["TargetNotVisible", ...]` | annotation で非公開 node の存在を漏らさない |

---

## 15. Test plan

### Unit

- 正規化: 全角/半角、英字大小、空白、句読点。
- token: 日本語連続文、型番、英数字混在、短い 1 文字 query。
- BM25: df/idf、文書長正規化、exact boost 上限。
- entity scoring: query surface の owner-scoped union 解決、`entity` field weight、同一 surface 由来 signal の `CorrelatedSurfaceCap`。
- gate: privacy exceed、deny tag、expired、revoked。
- mining boost: max bound、owner dismissed、LLM 0.7。
- KG: hop limit、node limit、cycle。
- OOPS seed parser: Common Lisp S式 reader で `item-name.index`, `mail-to-item.index`, `quote-table.index` を読む。
- legacy Japanese decoder: quoted-printable / MIME-word / ISO-2022-JP / CP932 / UTF-8 fallback を文字列単位で適用する。
- paragraph splitter: normal paragraph / quote block / signature / footer を分離する。
- quote matcher: marker, header, fuzzy text の confidence を区別する。
- quote hash: legacy decode / normalization 後の hash が一致し、seed quote table がある場合は fuzzy result で上書きしない。
- privacy classifier: OOPS 宛先 mapping により `oops@...` / `oops-ura@...` を 0.6、`oops-omote@...` を 0.4 にし、PII / third-party content で `PrivacyLevel` と sensitivity tags を引き上げる。
- PII / third-party floor detector: 電話番号、郵便番号、メールアドレス、URL、住所らしい文字列、第三者会話 marker で `NeedsHumanReview` / `ThirdPartyContent` を付ける。
- SearchContextProfile: date field weighting と score breakdown。
- SearchView renderer: `RankedList`, `LiveNotebookHypertext`, `ContextSubgraphNotebook`, `GraphPlot`, `OrderedTree` の view schema を作れる。
- interaction recorder: `Viewed` / `FollowedLink` / `Cited` / `Annotated` / `Rejected` を actor/time/view/node 付きで保存できる。
- annotation branch: target node に追記しても元 object を破壊せず、`SourceVaultGraphAnnotation` と `BranchRef` が作られる。

### Integration

- `KeywordBigram` 旧 index を検索できる。
- `KeywordBM25V1` index を build/load/search できる。
- Phase 1 BM25 は seed dictionary 未使用でも B1>=B0 の promotion 判定ができる。
- judged retrieval eval corpus から B1/B0 の `RecallAt20` / `NDCGAt10` を計算でき、OOPS topic 復元評価とは別 report になる。
- Phase 0.5 は seed dictionary あり / なし BM25 を同一 held-out で比較し、literal / semantic 層別と time split の report を出せる。
- `SourceVaultMinedSearch` が existing `SourceVaultSearch` を壊さない。
- `PrimerSearch` の result が `SummaryPrimer` になる。
- `table.zip` seed ontology と `oops 200506.txt` archive を結合し、明示 topic item と quote edge を再構成できる。
- `ImportRunId` 付き re-import が冪等で、同一 source identity の topic / mail / quote edge を重複生成しない。
- owner-scoped namespace により、同じ label でも `ki` と他 owner namespace の topic item を別 item として保持できる。
- 一般メール paragraph に `AutoExtracted` topic item を付け、mail session summary primer を作れる。
- retrieval episode を close したあと、final output に寄与した search attempt が high influence になる。
- contextual search で「イベント日」「メール送信日」「ingest 日」の優先 field が切り替わる。
- `ResultView -> "LiveNotebookHypertext"` で notebook cell group が生成され、リンク先をたどると gated lazy load と interaction write-back が発火する。
- `ResultView -> "ContextSubgraphNotebook"` で topic item graph の部分グラフを順序木として一件書類の cell group にできる。
- `ResultView -> "GraphPlot"` で Graph / GraphPlot option を反映した近傍 graph view を返せる。
- `AgenticKeywordSearch` が grounded evidence なしで answer を返さない。
- `SourceVaultMCPSearch` method dispatch が gate を通す。

### Regression

- `ReleasePolicyViolationCount == 0`
- `RawPathLeakCount == 0`
- quarantined object result count 0
- revoked object result count 0
- simple query が agentic 常用にならない
- episode / topic / mail-session boost で release gate を迂回しない
- `PrivateML` / `ThirdPartyContent` / `NoCloudLLM` tagged object は cloud LLM ReleaseContext で Deny になる
- `PrivateML` / `ThirdPartyContent` / `NoPublicExport` tagged object は public export ReleaseContext で Deny になる
- live view の follow / annotation で release gate を迂回しない
- archived content の古さだけで score が decay しない
- mail session summary の grounding refs が空なら promotion しない

---

## 16. 初期 default 値

```wl
$SourceVaultSearchDefaults = <|
  "DefaultIndexKind" -> "KeywordBigram",
  "ExperimentalIndexKind" -> "KeywordBM25V1",
  "NormalizationProfile" -> "ja-nfkc-v1",
  "TokenizerProfile" -> "ja-ngram-v1",
  "BM25" -> <|"k1" -> 1.2, "b" -> 0.75|>,
  "MiningMaxBoost" -> 0.2,
  "AgenticMaxIterations" -> 3,
  "AgenticMaxToolCalls" -> 12,
  "DefaultResultView" -> "RankedList",
  "DefaultGraphLayout" -> Automatic,
  "LiveViewMaxInitialNodes" -> 80,
  "CascadeSimpleLatencyBudgetMs" -> 1000,
  "CascadeComplexLatencyBudgetMs" -> 8000
|>
```

global 変数にする場合も、workflow snapshot には値を展開して保存し、後から default が変わっても再現性を保つ。

---

## 17. 実装時の注意

- Wolfram Language 標準関数でできる正規化・BM25 から始める。Sudachi / MeCab / JaColBERT は外部依存なので後続 profile。
- `AppendTo` 多用は大規模 index build で遅くなるため、term stats は `Counts`, `Merge`, `GroupBy` で作る。
- 巨大 `DF` association を snapshot 本体に入れて重い場合は artifact 分離する。
- `StringContainsQ` の連発から始めてよいが、BM25 index では chunk ごとの term counts を保存して query-time を軽くする。
- private 関数名は既存 `i...` スタイルに合わせる。
- docs 生成時は `api_searchindex.md` の chunk schema を必ず更新する。
- Phase 0.5 では `item-name.index` 限定の軽量 reader を使ってよい。Phase 6 の `table.zip` 全体 import では Common Lisp S式として読み、regex と単純行分割は禁止。
- 文字列 field は quoted-printable / MIME-word / ISO-2022-JP / CP932 / UTF-8 の順で decode し、構造部と文字列部を分けて扱う。
- OOPS の明示 topic item は seed ontology の正解データとして扱い、一般メール用 auto topic extractor の評価セットにも使う。
- 自動 topic item は human confirm まで既存 seed item を上書きしない。近傍候補として attach する。
- date metadata は必ず provenance を持たせる。`MessageDate`, `EventDate`, `EXIFOriginalDate`, `FileCreatedAt`, `FileMTime`, `IngestedAt` を混同しない。
- OOPS seed の `mail-info.index` は主に source file offset と list/author を持つ。送信日時は元メール header の `Date` / `X-Ml-Posted` から再パースする。
- chat log、貼付ニュース記事、長い引用本文を単純な空行段落で粉砕しない。段落分割器は quote/article/chat-log block を別扱いする。
- OOPS ingest の privacy は元メール header の宛先を優先する。`oops@...` / `oops-ura@...` は 0.6、`oops-omote@...` は 0.4 を下限にし、PII / third-party content 検出で引き上げる。
- cloud / export の禁止は object `DenyTags` ではなく object `Tags` と ReleaseContext `DenyTags` の積で発火させる。object には `NoCloudLLM` / `NoPublicExport` を tag として付ける。
- live notebook view は軽快さを優先し、初期表示 node 数を制限して lazy load する。リンク先取得、annotation 追記、引用操作はすべて request-time gate を通す。
- notebook での追記は元 summary / topic item / paragraph を直接更新せず、annotation branch として保存する。published summary への昇格は別の review / merge 操作にする。
- `e` など owner が明確でない namespace は Phase 0.5 で label 傾向を観察し、`NamespaceKind -> "Event" | "Shared" | "Unknown"` を後から確定できるようにする。

---

## 18. Definition of Done

### Track A: Search v1 完了条件

- `KeywordBM25V1` index を build/load/search できる。
- 既存 `KeywordBigram` が壊れていない。
- 日本語 query で unigram+bigram+BM25 の score breakdown が出る。
- `SourceVaultMinedSearch` の boost が search result schema に統合される。
- `SourceVaultPrimerSearch` と `SourceVaultExpandSearchGraph` が gate 付きで動く。
- promotion gate で release violation / raw path leak / primer-only answer が 0。
- judged retrieval eval corpus に基づいて B1/B0 を比較でき、評価 item の出所が trace/report に残る。
- B1 は B0 に対して `RecallAt20` と `NDCGAt10` が同等以上。seed dictionary は Track A の加点機能であり、BM25 core promotion の必須条件ではない。

### Track A add-on: Seed lexical dictionary 昇格条件

- OOPS seed ontology の `item-name.index` から owner-scoped entity dictionary を作り、BM25 query/index term に使える。
- query surface は owner-scoped entity union に解決され、current owner 一致は軽い ranking prior に留まる。
- `entity` field weight と同一 surface 由来 signal の合算上限が score breakdown に出る。
- seed held-out 実験で recall@k / precision@k / seed-hit rate / novel-topic ratio を出せる。
- seed dictionary あり / なし BM25 の counterfactual 比較で、事前登録閾値を満たすか判定できる。

### Track B: Mail topic graph 昇格条件

- OOPS seed ontology を `table.zip` 形式から読み、mail archive の明示 topic item / quote marker と結合できる。
- namespace を enum で決め打ちせず、`ki` / `mi` / `aga` / 未知 namespace を owner-scoped topic item として保持できる。
- relation の weight / direction と seed quote QID を保持できる。
- OOPS 宛先 mapping と list fallback から privacy / trust class を付与でき、`oops@...` / `oops-ura@...` は 0.6、`oops-omote@...` は 0.4 として ingest される。PII / third-party content で privacy を引き上げられる。
- legacy Japanese decode と Common Lisp S式 reader が import consistency test を通る。
- `ImportRunId` による re-import が冪等で、同一 source identity の object を重複生成しない。
- seed quote table を authoritative とし、hash / fuzzy quote は decode / normalization 後の非 seed fallback として扱える。
- 一般メール paragraph に自動 topic item を付与し、quote edge と topic transition graph を作れる。
- mail session summary が単一メールではなく session 単位で作られ、grounding refs を持つ。
- topic item graph / mail session graph から live notebook view と ordered tree view を生成できる。
- auto topic assignment は OOPS held-out gold set で事前に評価され、実用閾値未満なら search v1 の必須経路にしない。

### Track C: Retrieval episode / associative research 昇格条件

- retrieval episode から influence score と query/object prior を作れる。
- live view 上の `Viewed` / `FollowedLink` / `Cited` / `Annotated` event を meta-layer graph に取り込める。
- influence は frequency normalization / actor weighting を持ち、time decay は行動 popularity feedback に限定して適用できる。
- episode store は行動ログとして private trust class に入り、低漏洩 projection 以外を cloud prompt へ出さない。
- episode boost で release gate / revocation / safety gate を迂回しない。
- associative level は presentation / ranking のみに使い、privacy lowering operation の自動実行には使わない。

### Track D: Agentic / Cascade 完了条件

- SearchContextProfile により、イベント日・作成日・変更日・ingest 日などの metadata 重みを query intent ごとに変えられる。
- `SourceVaultAgenticSearch` が bounded loop と trace を持つ。
- `SourceVaultMCPSearch` から `methods -> {"cascade"|"episode"|"mailSession"|"topicGraph"|"contextual"|"liveView"}` を呼べる。
- `resultView` により `RankedList` 以外の `LiveNotebookHypertext` / `ContextSubgraphNotebook` / `GraphPlot` / `OrderedTree` を返せる。
- live notebook view 上でリンクをたどる、引用する、追記する行為が interaction event として保存され、annotation branch を作れる。
- episode / mail session / topic graph を使っても grounded evidence なしで answer しない。
