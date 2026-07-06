# SourceVault_lexical API Reference

## 概要
日本語向け lexical 検索層。正規化・token 化・BM25 統計構築・ランキング・スコア説明の一連の純関数を提供する。既存の `KeywordBigram` / `iKeywordScore` とは独立で、両者は無変更のまま温存される。

設計方針:
- 正規化を先行させ (`ja-nfkc-v1`: NFKC + 小文字化 + 数値桁区切り除去 + 空白正規化)、表記ゆれを吸収してから token/unigram/bigram を生成する。形態素解析には依存しない。
- bigram を OOV (未知語) 対策の基盤として保持する (CJK-IR 向け)。
- スコアリングは単純な Boole 一致ではなく BM25 (IDF + 文書長正規化 + TF 飽和) を用いる。
- exact(substring) 一致や entity 一致由来の literal bonus は `CorrelatedSurfaceCap` により合算上限を設ける (後続層で接続)。
- entity dictionary (seed) を渡すと surface form の正規化インデックスを作り、表記非一致・OOV な topic を index/query 双方で結びつける。entity 本体の辞書統合は Increment 3 で行う想定で、本層では hook のみ提供する。

Increment 2 のスコープは辞書なし BM25 ベースライン。entity stream (辞書あり arm) は Increment 3 で entity dictionary と接続する (hook 済み)。

## 正規化・Token化

### SourceVaultNormalizeSearchText[text] → String
`ja-nfkc-v1` 正規化 (NFKC, 小文字化, 数値桁区切り除去, 空白正規化) を行う。

### SourceVaultSearchTerms[normText] → Association
正規化済みテキストから token/unigram/bigram の検索フィールドを生成する。`<|"token"->{...}, "unigram"->{...}, "bigram"->{...}|>` を返す。

## 統計構築・Entity Index

### SourceVaultBuildLexicalStats[chunks, opts]
chunk リストから BM25 用 LexicalStats (N, DF, AvgDL, ChunkTerms) を構築する純関数。各 chunk は `"ChunkId"` と `"SearchFields"` または `"Text"` を持つ Association。
→ Association
Options: "EntityDictionary" -> None (seed entity dictionary (§4.1.1) を渡すと entity stream を追加し、surface form の OR-match で表記非一致/OOV の topic を index/query 両側で結ぶ)

### SourceVaultBuildSurfaceIndex[dict] → Association
seed entity dictionary から `<|正規化 surface form -> {topicRef...}|>` を作る。同一 surface form が複数 owner namespace に対応する場合は全 ref を保持する (owner-scoped union)。

## ランキング・スコア説明

### SourceVaultLexicalRank[query, stats, opts]
LexicalStats に対して query を BM25 でスコアリングし、chunk を score 降順で順位付けする。
→ `{<|"ChunkId"->_, "Score"->_, "Breakdown"->_|>, ...}`
Options: "Limit" -> 20 (返す chunk 件数の上限)

### SourceVaultExplainSearchScore[query, chunkIdOrAssoc, stats] → Association
1 chunk 分の BM25 score breakdown を返すデバッグ用関数。term とスコアのみを含み、raw path や非公開 body は出力しない。