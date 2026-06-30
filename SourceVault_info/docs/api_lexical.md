# SourceVault_lexical API リファレンス

パッケージ: `SourceVault`
依存: なし（純関数。`SourceVault_core` 非依存）
ロード順: SourceVault.wl → SourceVault_core.wl → SourceVault_mining.wl → **SourceVault_lexical.wl** → SourceVault_searchindex.wl → SourceVault_oopsseed.wl → …
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_lexical.wl"]]`
担当: 日本語に強い lexical 検索層（正規化・n-gram トークナイズ・BM25・転置インデックス・seed entity 辞書による OR-match）。`SourceVault_searchindex` の `KeywordBM25V1` projection index が本層を使う。

## 設計

- 既存 `KeywordBigram` / `iKeywordScore` は無変更で温存。本層は `KeywordBM25V1` 用の純関数。
- lexical 先行: 正規化 → token / unigram / bigram → BM25。形態素解析は v1 非依存（後続 profile）。bigram を OOV 基盤として残す（CJK-IR）。
- スコアは生 Boole でなく BM25（IDF + 文書長正規化 + TF 飽和）。
- entity OR-match: query「Bruce Sterling」と doc「ブルース・スターリング」が、双方に entity term `entity:<topicRef>` が立つことで一致する（表記非一致/OOV 回復）。

## 正規化・トークナイズ

### SourceVaultNormalizeSearchText[text] → String
`ja-nfkc-v1` 正規化を返す。NFKC（全角英数→半角、半角カナ→全角等を `CharacterNormalize` で正準化）→ ASCII 小文字化 → 数値桁区切り（`,`/`，`）除去 → zero-width 除去 → 空白/制御/分離文字を単一空白に畳む → trim。

### SourceVaultSearchTerms[normText] → Association
正規化済みテキストから term stream を返す。
戻り値: `<|"token" -> {...}（空白/句読点分割）, "unigram" -> {...}（CJK・かな・カナの単一文字）, "bigram" -> {...}（区切り除去後の 2-gram）|>`

## Seed entity 辞書

### SourceVaultBuildSurfaceIndex[dict] → Association
seed entity dictionary（`SourceVault_oopsseed` の `SourceVaultBuildSeedEntityDictionary` 等が作る `<|"Entries" -> {<|"TopicItemRef", "SurfaceForms"|>...}|>`）から `<|正規化 surface form -> {topicRef...}|>` を作る。同じ surface form が複数 owner namespace に対応する場合は全 ref を保持（owner-scoped union）。長さ 2 未満の form は除外。

## LexicalStats / BM25

### SourceVaultBuildLexicalStats[chunks, opts] → Association
chunk list から BM25 用 LexicalStats を作る純関数。各 chunk は `"ChunkId"` と `"SearchFields"`（`<|"title","summary","body","tags","author"|>`）または `"Text"` を持つ Association。
Options: `"EntityDictionary" -> None`（seed entity dictionary を渡すと `entity` stream を追加し、surface form OR-match を有効化。§4.1.1）, `"NormalizationProfile" -> "ja-nfkc-v1"`, `"TokenizerProfile" -> "ja-ngram-v1"`
戻り値: `<|"ObjectClass" -> "SourceVaultLexicalStats", "N", "Streams" -> {"token","unigram","bigram"(,"entity")}, "DF", "AvgDL", "Postings"（転置 index: term -> {ChunkId...}）, "ChunkTerms"（per-chunk term counts / NormText / DL）, "SurfaceIndex"|>`

### SourceVaultLexicalRank[query, stats, opts] → {Association...}
LexicalStats に対し転置 index accumulator で BM25 採点し、score 降順に返す。query term の postings に出る doc だけ採点する（query-time を軽くする）。entity dictionary 付き stats なら query 側にも entity term を立てて OR-match する。
Options: `"Limit" -> 20`, `"Breakdown" -> True`（False で top-k の breakdown 再計算を省き高速化。大規模採点の latency / wedge 回避に有効）
戻り値: `{<|"ChunkId", "ObjectURI", "Score", ("Breakdown")|>...}`
BM25: `IDF(t) = Log[1 + (N - df + 0.5)/(df + 0.5)]`、TF 飽和 `(tf(k1+1))/(tf + k1(1 - b + b·dl/avgdl))`、k1=1.2 / b=0.75。field weights: exact 3.0 / entity 0.8 / token 1.0 / unigram 0.35 / bigram 0.65。exact は正規化 query が NormText に substring 一致した場合の bounded boost（MaxExactBoost 3.0、CorrelatedSurfaceCap 3.5 で literal 合算上限）。

### SourceVaultExplainSearchScore[query, chunkIdOrAssoc, stats] → Association
1 chunk の BM25 score breakdown を返すデバッグ用。raw path / 非公開 body は出さず term と score のみ。
戻り値: `<|"ChunkId", "Query", "NormalizedQuery", "Breakdown" -> <|"BM25Token", "BM25Unigram", "BM25Bigram", ("BM25Entity"), "Exact", "Score"|>|>`
