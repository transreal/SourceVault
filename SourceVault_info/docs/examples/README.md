# SourceVault 検索基盤 実行例 (examples)

このフォルダは、検索基盤 v1（OOPS seed オントロジ取り込み → 一般メールの topic 自動付与 → 日本語 BM25 検索 → KG 局所探索 → mining primer）で実装した機能の実例です。掲載コードはすべて実カーネルで評価し、「期待される出力例」は実測値です。

2 つの形式で提供します。

- **Markdown（GitHub で読む用）** — `mining_example.md` と同様に、基本→応用の使い方を出力例つきで解説。GitHub 上で読みやすい。**まずこちらを読んでください。**
- **`.wl` スクリプト（Mathematica で実行する用）** — ノートブックや `Get` でそのまま走らせる実行ファイル。

## Markdown（読み物）

| ファイル | 内容 |
|---|---|
| [**search_foundation_example.md**](search_foundation_example.md) | **OOPS 非依存**の検索基盤。合成データだけで動く、正規化 / BM25 / release gate / entity OR-match / revocation / mining primer / KG。OOPS メールを一切ロードしない状態で使える。**0. 実運用シナリオ**→基本編→中級編→応用編。 |
| [**oops_example.md**](oops_example.md) | **OOPS を用いた**例。seed 辞書取り込み・表記ゆれ回復・MIME 復号・段落 auto-tag・新トピック育成・seed→検索の接続（本文に無い関連トピックでヒット）・OOPS relation の KG。**0. 実運用シナリオ**→基本編→中級編→応用編。 |

この 2 分割は「OOPS メールをロードしなくても使える検索基盤」と「OOPS seed を活かす応用」を分けたものです。前者だけで release gate 付き日本語 BM25 検索・primer・KG が使え、後者で seed オントロジによる精度向上が加わります。

各ファイル冒頭の **「0. 実運用シナリオ」** は、これらの関数が実際にどう呼ばれるか（`ClaudeEval[...]` などの自然文プロンプト → MCP ツール `sourcevault_search` → 検索基盤）と、仕様生成・実装ワークフローでの検索利用を、`mining_example.md` の「実運用シナリオ」と同じ体裁で示します。

## 前提

- `$dropbox`（Dropbox ルート）と `$packageDirectory`（パッケージのパス）が **init ファイルで定義済み**であること。各例はこれらを使ってパスを `FileNameJoin` で組み立てるので PC 非依存（Dropbox が別ドライブでも可）。ハードコードした絶対パスは持たない。`$packageDirectory` はユーザ以外の再定義が禁止のため、各例では**設定せず参照のみ**する。
- OOPS ML archive（seed の `item-name.index` / `item-relation*.index` と `oops*.txt`）が `$dropbox/udb/oops-ml-archive/oops-ml-archive/` 以下にあること。
- `SourceVault.wl` は各例の先頭で `Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]` によりロードする。

各例は自己完結しており、ノートブックのセル group として順に評価するか、読み込んで実行できる。release context を登録する例は末尾で後始末する。

**文字コード**: これらのファイルは UTF-8（日本語のコメント・文字列リテラルを含む）。ShiftJIS 既定のカーネル（Windows の既定）で `Get` する場合は必ず UTF-8 で読むこと:

```mathematica
Block[{$CharacterEncoding = "UTF-8"}, Get["…/examples/01_seed_to_search.wl"]]
```

ノートブックにコピーして評価する場合はこの指定は不要。index を build する例（01/04）は `IndexId` を毎回ユニークにしてあるので再実行できる（immutable snapshot は content-addressed のため固定 id だと再実行で alias 衝突する）。

## `.wl` 実行スクリプト（Mathematica で走らせる用）

.wl は GitHub 上では読みにくいので、閲覧は上の Markdown を推奨します。実行するときはこちら。

| ファイル | 内容 | 主な API |
|---|---|---|
| [01_seed_to_search.wl](01_seed_to_search.wl) | **プロジェクトの核**。mail を topic 注入付き chunk にして BM25 index を build し、**本文に出ない関連トピックで検索ヒット**することを示す（「一般メールを seed 形式に変換して検索精度を上げる」の実証） | `SourceVaultBuildMailChunks` / `SourceVaultTopicEnrichment` / `SourceVaultBuildProjectionIndex` / `SourceVaultSearch` |
| [02_auto_tag_and_kg.wl](02_auto_tag_and_kg.wl) | 段落の **auto-tag**（SeedMatched 正準 ＋ RelationExpanded 関連）と **§6.3 KG 局所探索**（multi-hop） | `SourceVaultAssignParagraphTopics` / `SourceVaultBuildOOPSRelationGraph` / `SourceVaultExpandSearchGraph` |
| [03_ontology_growth.wl](03_ontology_growth.wl) | seed 語彙外の **新トピック候補抽出 → 確認 → 永続 → seed 編入で検索可能**（オントロジ育成ループ） | `SourceVaultExtractCandidateTopics` / `SourceVaultConfirmCandidateTopics` / `SourceVaultSaveExtractedTopics` / `SourceVaultLoadExtractedTopics` |
| [04_mining_primer.wl](04_mining_primer.wl) | **§6.1/6.2 mining primer**。summary 由来 item を importance / freshness 込みで採点する低コスト探索 | `SourceVaultBuildPrimerIndex` / `SourceVaultLoadPrimerIndex` / `SourceVaultPrimerSearch` |
| [05_mail_parsing.wl](05_mail_parsing.wl) | メール解析の品質: **MIME Subject 復号**（ISO-2022-JP 等）、**Latin↔CJK 語境界の照合**、catch-all 退化トピックの除外 | `SourceVaultParseOOPSMailFile` / entity OR-match / `SourceVaultBuildSurfaceIndex` |

## 全体像（seed → 検索の流れ）

```
item-name.index ─▶ SourceVaultImportOOPSSeedDictionary ─▶ dict
                                                           │
                        SourceVaultBuildSurfaceIndex ◀─────┘─▶ surfaceIndex
item-relation*.index ─▶ SourceVaultBuildOOPSRelationGraph ─▶ relationGraph
oops*.txt ─▶ SourceVaultParseOOPSMailFile ─▶ mail
                                              │
   SourceVaultBuildMailChunks(surfaceIndex, relationGraph) ─▶ chunk（SearchFields.topics に auto-tag 注入）
                                              │
   SourceVaultBuildProjectionIndex(IndexKind=KeywordBM25V1, EntityDictionary=dict) ─▶ 永続 index
                                              │
   SourceVaultSearch(ReleaseContext, Index) ─▶ release gate 付き BM25 検索（本文に無い関連トピックでもヒット）
```

参照: 関数の詳細は [../api_oopsseed.md](../api_oopsseed.md) / [../api_lexical.md](../api_lexical.md) / [../api_searchindex.md](../api_searchindex.md)。
