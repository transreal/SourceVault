# SourceVault_oopsseed API リファレンス

パッケージ: `SourceVault`
依存: `SourceVault_lexical`（`SourceVaultNormalizeSearchText` / surface index を使う）
ロード順: … → SourceVault_lexical.wl → SourceVault_searchindex.wl → **SourceVault_oopsseed.wl** → …
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_oopsseed.wl"]]`
担当: OOPS メーリングリスト（1992–2005 の個人 ML、約 6500 通・約 4100 topic item）の seed オントロジ取り込みと、一般メールへの topic 自動付与（auto-tag）。「seed を取り込み、一般メールを同形式に変換して検索精度を上げる」方針の基盤。

## 設計（レビューで確立）

- index は「S式風」でなく **Common Lisp S式**。正規表現/単純行分割では読まない（深い入れ子・長大行・引用文字列のため）。
- 名前空間は enum で決め打ちしない。実データに `ki/aga/e/mi/caitsith/tom/ara/anonymous` 等 10 種以上＋typo が存在する。`(SYMBOL INT)` を総称的に読み、未解決 owner は drop せず `Missing["UnknownOwner"]`。
- encoding は実測で確定: `item-name.index` は CR 区切りの **ShiftJIS(CP932)**（ESC=0 ゆえ ISO-2022-JP ではない）。mail 本文（`oops*.txt`）は再エンコード済みで **UTF-8**。2005 年の `mail-info.index` byte offset は現 UTF-8 ファイルでは無効ゆえ、本文は mbox 直接 parse で取る。
- owner-scoped: `ki`=owner(自分) namespace、`mi`/`aga` 等は別 owner。

## S式リーダ・legacy decode

### SourceVaultReadSExprString[s] → List
Common Lisp S式の文字列を読み top-level S式のリストを返す。`(...)`→List, `"..."`→String, 整数→Integer, bareword（`nil` 含む）→`SourceVault\`Private\`SVSym[name]`。

## seed オントロジ取り込み

### SourceVaultImportOOPSItemNames[path, opts] → Association
`item-name.index` を読み topic name records を返す。Options: `"Encoding" -> "ShiftJIS"`。
戻り値: `<|"Items" -> {<|"Namespace", "LocalId", "CanonicalLabel", "SurfaceForms"（"日本語 English"・"日本語(English)" 併記を別名分割）, "LanguageHints"|>...}, "Count", "Warnings", "SourcePath", "Encoding"|>`

### SourceVaultBuildSeedEntityDictionary[itemsOrImport, opts] → Association
item-name records から owner-scoped な seed entity dictionary（§4.1.1）を作る。
Options: `"OwnerMap" -> <|"ki" -> "sventity:owner:imai"|>`, `"SharedNamespaces" -> {"e"}`, `"DictionaryId" -> Automatic`
戻り値: `<|"ObjectClass" -> "SourceVaultSeedEntityDictionary", "DictionaryId", "Entries" -> {<|"TopicItemRef" -> "svtopic:oops:<ns>:<id>", "Namespace", "LocalId", "OwnerRef", "OwnerConfidence", "NamespaceKind" -> "Person"|"Shared"|"Unknown", "CanonicalLabel", "SurfaceForms", "LanguageHints", "PrivacyLevel", "SourceRefs"|>...}, "EntryCount"|>`
この `Entries` を `SourceVault_lexical` の `SourceVaultBuildSurfaceIndex` / `SourceVaultBuildLexicalStats["EntityDictionary"->…]` に渡すと entity OR-match が効く。

### SourceVaultImportOOPSSeedDictionary[itemNameIndexPath, opts] → Association
import + dictionary build を一括で行う便宜関数。戻り値: `<|"Dictionary", "Import"|>`。

### SourceVaultSeedDictionaryStats[dict] → Association
検証用統計（namespace 分布、owner 解決率、bilingual 数、surface form 総数、sample）。

### SourceVaultImportOOPSMailToItem[path] → Association
`mail-to-item.index` を読み `<|mailNumber -> {<|"Namespace", "LocalId", "Role"(title/body)|>...}|>` を返す。人手が付与した topic の **gold** データ（評価用）。

### SourceVaultImportOOPSMailInfo[path] → Association
`mail-info.index` を読み `<|mailNumber -> <|"List", "Hash", "Author", "SourceFile", "ByteStart", "ByteEnd"|>|>` を返す。`List`（`oops`/`oops-ura`）は privacy 入力。**注意**: ByteStart/ByteEnd は 2005 年原ファイル基準で現 UTF-8 ファイルでは無効。本文抽出は `SourceVaultParseOOPSMailFile` を使う。

## mail parse・auto-tag

### SourceVaultParseOOPSMailFile[path] → Association
UTF-8 の `oops*.txt` を mbox として parse（CR 行終端）。`X-Ml-Counter` で gold と join する。
戻り値: `<|"Mails" -> {<|"Counter", "MlName", "Subject", "From", "Date", "Body"|>...}, "MailCount", "SourcePath"|>`

### SourceVaultStripOOPSMarkers[text] → String
OOPS の topic ID ref（`[ns n]`）・brace wrapper・`◎○・` structural marker を除去して plain text を返す。label 本文は残す（held-out 評価で cheat 防止／一般メール化）。

### SourceVaultParseMailParagraphs[body] → {Association...}
mail 本文を段落に分割する（空行区切り、引用/署名/footer を分離。§6.5）。
戻り値: `{<|"Index", "Kind" -> "Prose"|"Quote"|"Signature"|"Footer", "Text"|>...}`

### SourceVaultAssignParagraphTopics[paragraphs, surfaceIndex, opts] → {Association...}
各 prose 段落に seed 辞書の surface form OR-match で topic item を自動付与する（auto-tag）。`surfaceIndex` は `SourceVaultBuildSurfaceIndex[dict]`。
`"RelationGraph"`（`SourceVaultBuildOOPSRelationGraph` の結果）を渡すと、SeedMatched の named topic から 1-hop の関連 topic を低 confidence の `AssignmentKind = "RelationExpanded"`（`ViaSeed` / `RelationWeight` 付き）として追加する。SeedMatched（conf ≤ 1.0）が常に RelationExpanded（conf = `Min[0.45, 0.2 + 0.03·Weight]`）より上位。`RelationGraph` 無しなら SeedMatched のみ（後方互換）。
Options: `"MinSurfaceLength" -> 2`, `"TopicLimit" -> 10`, `"ProseOnly" -> True`, `"RelationGraph" -> None`, `"MaxRelationTopics" -> 8`, `"MinRelationWeight" -> 2`
戻り値: `{<|"ParagraphIndex", "Kind", "Assignments" -> {<|"TopicItemRef", "MatchedSurfaceForms", "AssignmentKind" -> "SeedMatched"|"RelationExpanded", "Confidence", ("ViaSeed", "RelationWeight")|>...}|>...}`
ノイズ対策（解消済み）: 短い Latin surface form の語中誤一致（例「tar」が「s**tar**ship」）は `iSVSurfaceFormPresentQ` の単語境界一致で解消（api_lexical 参照）。catch-all/退化 topic（ラベル「・」で数百 form を持つ `anonymous:0` 等）も `SourceVaultBuildSurfaceIndex` 構築時に除外済み。残: 同名 topic（例 ki195/e203 とも「映画」）は両方とも正当な topic ゆえ両マッチを許容（owner による後段 disambiguate は将来課題）。

## relation（重み付き有向）取り込み・1-hop 拡張

`item-relation.index` は topic 間の **重み付き有向リンク**（`(ns localId)` → `(((ns localId) weight)...)`）。これを取り込むと「named topic に関連するが本文に名前が出ていない topic」を回収できる（KG 局所探索 §6.3、auto-tag の RelationExpanded）。

### SourceVaultImportOOPSItemRelations[path, opts] → Association
`item-relation.index` / `item-relation-up.index` を S式 parse する。Options: `"Direction" -> "Down"`（`item-relation-up.index` には `"Up"` を渡す）。
戻り値: `<|"Relations" -> <|"<TopicItemRef>" -> {<|"To" -> "<TopicItemRef>", "Weight", "Direction"|>...}|>, "Count", "SourcePath", "Direction"|>`

### SourceVaultBuildOOPSRelationGraph[tableDir] → Association
`tableDir` の `item-relation.index`（Down）＋`item-relation-up.index`（Up）を結合した relation graph を作る。
戻り値: `<|"RelationGraph" -> <|"<TopicItemRef>" -> {neighbor...}|>, "Count", "TableDir"|>`（OOPS 実データで約 2875 ノード）。

### SourceVaultExpandTopicsByRelation[refs, relationGraph, opts] → {Association...}
seed topic 集合（`refs`）を重み付き 1-hop 近傍へ拡張する。seed 自身は除外、`To` 単位で最大重みに dedup、重み降順。
Options: `"MaxNeighborsPerSeed" -> 5`, `"MinWeight" -> 1`, `"MaxTotal" -> 20`
戻り値: `{<|"To", "Weight", "Direction", "ViaSeed"|>...}`

## 利用例

```mathematica
(* seed 辞書を build → surface index → BM25 index に entity stream を載せる *)
dict = SourceVaultImportOOPSSeedDictionary["…/db/table/item-name.index"]["Dictionary"];
sidx = SourceVaultBuildSurfaceIndex[dict];

(* relation graph を build *)
graph = SourceVaultBuildOOPSRelationGraph["…/db/table"]["RelationGraph"];

(* 一般メールを段落 topic 付与（named ＋ relation 1-hop の related） *)
mails = SourceVaultParseOOPSMailFile["…/oops-ml-generate/oops 200506.txt"]["Mails"];
paras = SourceVaultParseMailParagraphs[SourceVaultStripOOPSMarkers[First[mails]["Body"]]];
SourceVaultAssignParagraphTopics[paras, sidx, "RelationGraph" -> graph]
```
