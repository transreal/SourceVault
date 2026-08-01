# SourceVault`CrossLink API Reference
パッケージ: `SourceVault_crosslink` (SourceVault.wl auto-load / context `SourceVault``)
依存 (すべて任意・呼び出し時に存在確認): SourceVault_mailbrowse, SourceVault_oopsseed,
SourceVault.wl ($SourceVaultSummaryProviders), SourceVault_mining, SourceVault_core, SourceVault_eagle

## 概要

SourceVault のヘテロ DB (一般メール mailbrowse / OOPS アーカイブ / Eagle サマリー /
ingest 済みソース / PDF 索引) を横断して「内容的に近いもの」をリンク解決し、
クリックで各 DB のネイティブビューへ遷移するハイパーテキスト層。

**mining 層の活用**:
- ランキング = provider 横断 RRF 融合 → `SourceVaultMiningRerank` boost
  (TagAssertion/Authorship/ObjectSignals importance、SourceVaultMinedSearch と同型、MaxBoost 0.2)
- リンククリックを `ObjectInteractionRecorded` (Owner/SearchClick) として event log へ
  記録 → importance に還流 (クリックするほど上位に来る学習ループ)
- anchor の topic ラベルを QueryTags として TagAssertion 照合
- `SourceVaultCrossLinkAssertTopics` で anchor の topic を TopicTag (SourceKind=Mining)
  として vault へ委託 (opt-in)
- topic anchor は topic graph (ObservedRelationGraph) の隣接 topic でクエリ拡張

mining 未ロードでも RRF のみで劣化動作 (fail-soft)。

## 使用レシピ (最重要)

```wl
(* 事前: 対象 DB をロードしておく (未ロード DB は黙って skip される) *)
SourceVaultMailBrowseEnsureLoaded["univ", "Period" -> "202606"]
SourceVaultOOPSEnsureLoaded[]

SourceVaultCrossLinksView[<|"Kind" -> "mail", "Id" -> recordId, "MBox" -> "univ"|>]  (* univ メール → 関連 *)
SourceVaultCrossLinksView[<|"Kind" -> "oops-mail", "Id" -> "3522"|>]                (* OOPS メール → 関連 *)
SourceVaultCrossLinksView["可逆計算"]                                                (* 自由クエリ *)
```
各ビュー (MailBrowse*/OOPS*View) の「⇄ 関連」ボタンからも同じものが開く。

## anchor 指定

`SourceVaultCrossLinkAnchor[anchor]` → `<|AnchorURI, Title, Topics, QueryText, Tokens, Author, ExcludeKeys|>`
- 文字列 → 自由クエリ
- `<|"Kind" -> k, "Id" -> id, "MBox" -> mb|>`:
  k = "mail" (mailbrowse メール) | "mail-thread" | "topic" | "oops-mail" (counter) |
  "oops-thread" (sessionId) | "eagle" (item id)
- `<|"Text" -> ...|>` → 自由テキスト
- 既に `QueryText`/`Tokens` を持つ Association はそのまま解決済みプロファイルとして通す

## core

### SourceVaultCrossLinks[anchor, opts] → {Association...}
link row: `<|Kind, Id, MBox, URI, Title, Snippet, Score(RRF), RankScore/MiningBoost(mining時),
Provider, Key, AlsoFoundBy, ...|>`。
Options: "Providers" -> All, "Limit" -> 12, "PerProviderLimit" -> 8, "MiningBoost" -> True,
"QueryTags" -> Automatic (=anchor Topics), "QueryAuthor" -> None, "EventLimit" -> 3000,
"ExcludeSelf" -> True (自分と自スレッドを除外),
"MinScore" -> Automatic (BM25 provider の弱一致ノイズ除外。Automatic = Max[2.0, 0.4*最高スコア]
(provider 内, RRF 融合前)。数値で絶対下限、None で無効。summaries provider には効かない
(固定 Score=1/token))

### SourceVaultCrossLinkOpen[kind, id, mbox, uri] (I/O)
ネイティブビューで開く: oops-thread/oops-mail → OOPS ビュー (機密セル対応 opener 優先),
mail-thread/mail/topic → mailbrowse ビュー, eagle → SourceVaultEagleShowSummary,
その他 → sv:// プロパティ / URL / ファイル。開くたびに ObjectInteraction 記録。

### SourceVaultCrossLinkRecordInteraction[targetURI, kind, queryRef] → event | Missing
mining ObjectInteraction を記録 (fail-soft)。`$SourceVaultCrossLinkAppendEventFn` で
append 先差し替え可 (テスト)。

### SourceVaultCrossLinkAssertTopics[anchor, opts] → {Association...} | Missing
anchor の topic を TopicTag として assert (opt-in I/O)。
Options: "Confidence" -> 0.6, "MaxTags" -> 8, "CommitFn" -> Automatic (テスト注入)

## View

### SourceVaultCrossLinksView[anchor, opts]
ヘッダ (anchor/query/topics) + Grid (種別 / Title ボタン=クリックで開く / Score / Snippet /
出典+boost)。表示上限 `$SourceVaultCrossLinkViewMaxRows` (既定 20)。
オプションは SourceVaultCrossLinks と同じ (Options[SourceVaultCrossLinksView] = Options[SourceVaultCrossLinks])。

## provider registry (拡張点)

### SourceVaultRegisterCrossLinkProvider[name, spec]
spec: `<|"SearchFn" -> fn[query_String, opts_Association] -> {linkRow...}, "Description", "Kinds"|>`。
opts には Query/Tokens/Topics/Limit/MinScore が渡る。登録すると `$SourceVaultCrossLinkProviders[name] = spec`。
組み込み: **oops** (OOPS session BM25。ロード済み時のみ・自動フルロードしない) /
**mailbrowse** (ロード済み全 mbox の session BM25) /
**summaries** ($SourceVaultSummaryProviders=sources/eagle/pdfindex を token 部分一致で横断、
複数 token 一致を加点)。notebook DB 等は今後ここに追加する。

## 設定変数

### $SourceVaultCrossLinkProviders
型: Association (name -> spec), 初期値: `<||>`
横断リンク provider の registry。SourceVaultRegisterCrossLinkProvider で登録。

### $SourceVaultCrossLinkViewMaxRows
型: Integer, 初期値: 20
CrossLinksView の表示上限行数。

### $SourceVaultCrossLinkAppendEventFn
型: Automatic | Function, 初期値: Automatic (= SourceVaultAppendEvent)
interaction event の append 先override。テストで実 event dir への書込を避けるために差し替える。

### $SourceVaultCrossLinkKindNames
型: Association (Kind -> 表示名), 初期値: `oops-thread->"OOPSスレ", oops-mail->"OOPSメール",
mail-thread->"メールスレ", mail->"メール", topic->"topic", eagle->"Eagle", source->"ソース",
pdfindex->"PDF索引", arxiv->"arXiv", web->"Web"`
CrossLinksView 表示用の Kind → ラベル対応表。

## 内部実装メモ (LLM 向け)

- private context は `SourceVault`CrossLinkPrivate``。後ロードされ得るシンボル
  (eagle/mcp/mining/registry) は SourceVault` 完全修飾+DownValues ガードで参照する
  (裸参照は private 孤児シンボル生成の罠)。
- RRF: score = Σ 1/(60+rank) + 0.001·min(nativeScore,20)。同一 (Kind:Id) は代表 row に
  AlsoFoundBy を蓄積。
- MinScore フィルタは各 provider 内 (RRF 融合前) で適用される: oops は
  `iSVCLMinScoreFilter` を明示適用、mailbrowse は SearchThreads へ直接 "MinScore" を渡す、
  summaries は無視 (固定 Score)。
- OOPS メール opener は `SourceVault`Private`iSVOOPSOpenMailDoc` (機密セル焼込) を
  DownValues ガード付きで優先、無ければ public MailView fallback。
- テスト: `test codes/SourceVault_mailbrowse_crosslink_tests.wls` (46/46)。