# SourceVault OOPS seed 使用例 — 日本語オントロジと auto-tag

SourceVault の **OOPS seed オントロジ層**（`SourceVault_oopsseed.wl`）の使用例集です。個人メーリングリスト OOPS（1992–2005、約 6500 通・約 4100 topic item）から作った seed 辞書を取り込み、**一般メールを同じ topic 付き形式に自動変換して日本語検索の精度を上げる**、というのが狙いです。

検索基盤そのもの（BM25 / release gate / primer / KG）を OOPS 抜きで使う例は [`search_foundation_example.md`](search_foundation_example.md) にあります。本ファイルは OOPS archive を前提とします。

構成は 4 部です。

1. **[基本編](#基本編)** — seed 辞書の取り込み、表記非一致（entity OR-match）、メール解析の品質（MIME 復号・語境界・退化トピック除去）。
2. **[中級編](#中級編)** — 段落の auto-tag（正準＋関連トピック）、seed 語彙外の新トピック育成。
3. **[応用編](#応用編)** — seed→検索の接続（本文に無い関連トピックでヒット）、OOPS relation の KG 局所探索。
4. **[可視化・ユーティリティ層](#可視化ユーティリティ層)** — 単一初期化（`SourceVaultOOPSEnsureLoaded`）、topic item graph 描画、スレッド詳細ビュー / 一覧。

メール構造化（引用グラフ・スレッド・privacy・cloud-safe 検索・MCP tool）そのものの例は [`mail_structuring_example.md`](mail_structuring_example.md) にあります。本ファイルの第 4 部は、その上に載る**可視化とノートブック操作**を示します。

関数仕様は [`../api_oopsseed.md`](../api_oopsseed.md) / [`../api_lexical.md`](../api_lexical.md) / [`../api_searchindex.md`](../api_searchindex.md) を参照。

---

## 事前準備

`$dropbox`（Dropbox ルート）と `$packageDirectory`（パッケージのパス）は init ファイルで定義済みとします（PC 非依存。`$packageDirectory` は参照のみ）。OOPS archive は `$dropbox/udb/oops-ml-archive/oops-ml-archive/` 以下にあるものとします。

```mathematica
Block[{$CharacterEncoding = "UTF-8"}, Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]]

$oopsTable = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "db", "table"}];
$oopsMail  = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "oops-ml-generate"}];

(* seed 辞書を一度取り込んでおく（以降の例で使う）*)
dict = SourceVaultImportOOPSSeedDictionary[FileNameJoin[{$oopsTable, "item-name.index"}]]["Dictionary"];
surfaceIndex = SourceVaultBuildSurfaceIndex[dict];
refLabel = Association[(#["TopicItemRef"] -> #["CanonicalLabel"]) & /@ dict["Entries"]];
```

> index を build する例（応用編）は末尾で release context を登録解除します。`IndexId` は `CreateUUID` で毎回ユニークにしてあり、再実行しても衝突しません。

---

# 0. 実運用シナリオ — OOPS seed の検索が実際に呼ばれる場面

seed オントロジの効果（表記ゆれ回復・関連トピック注入）は、ふだんは **LLM が MCP ツール `sourcevault_search` を呼んだとき** に効きます。`ClaudeEval[...]` や Claude Code / LM Studio / Codex から検索すると、`sourcevault_search` → `iSVSearchAdapterSearch` → `SourceVaultSearch` → `iNativeSearch` と流れ、seed 辞書を積んだ `KeywordBM25V1` 索引が使われます。ここでは OOPS メールを索引した状態で、その経路を示します（索引の作り方は応用編 例 6 と同じ `SourceVaultBuildMailChunks` + `SourceVaultBuildProjectionIndex`）。

## シナリオ 0.1: 自然文プロンプト → seed→検索 でヒット

まず OOPS メール数通を topic 注入つきで索引します。

```mathematica
relationGraph = SourceVaultBuildOOPSRelationGraph[$oopsTable]["RelationGraph"];
mails = SourceVaultParseOOPSMailFile[FileNameJoin[{$oopsMail, "oops 9805.txt"}]]["Mails"];
sub = Select[mails, MemberQ[{4439, 4420, 4421, 4425, 4427, 4444}, #["Counter"]] &];  (* 4439 を含む *)
chunks = Flatten[SourceVaultBuildMailChunks[#, surfaceIndex,
  "Granularity" -> "Mail", "RelationGraph" -> relationGraph, "RefLabel" -> refLabel,
  "PrivacyLevel" -> 0.3] & /@ sub];

SourceVaultRegisterReleaseContext["oops-kb", <|"MaxPrivacyLevel" -> 1.0|>];
oIdx = "oops-kb-bm25-" <> StringTake[StringDelete[CreateUUID[], "-"], 8];
SourceVaultBuildProjectionIndex["oops-kb", "Chunks" -> chunks,
  "IndexKind" -> "KeywordBM25V1", "EntityDictionary" -> dict, "IndexId" -> oIdx];
```

この索引ができた状態で、ClaudeEval に次のような自然文を投げます（**これは実行イメージで、そのまま評価するセルではありません**。実際に走らせる前提は下の注記を参照）:

```text
ClaudeEval["oops-kb で『Independence Day』を検索して"]
```

すると LLM は次のツール呼び出しを発行します:

```json
{ "name": "sourcevault_search",
  "arguments": { "query": "Independence Day",
                 "scope": { "releaseContext": "oops-kb" }, "methods": ["bm25"], "limit": 2 } }
```

ツールが内部で行うことは次と等価で、**こちらは（上の索引 build 後に）実行して挙動を確認できます**（`iSVSearchAdapterSearch`）:

```mathematica
SourceVault`MCPPrivate`iSVSearchAdapterSearch[
  <|"query" -> "Independence Day",
    "scope" -> <|"releaseContext" -> "oops-kb", "bm25Index" -> oIdx|>,
    "methods" -> {"bm25"}, "limit" -> 2|>, <||>] //
  Map[<|"title" -> #["Title"], "kind" -> #["Metadata"]["RetrievalKind"], "decision" -> #["Decision"]|> &]
```

**期待される出力例:**

```
{<|"title" -> "Starship Troopers", "kind" -> "KeywordBM25", "decision" -> "Permit"|>, ...}
```

トップにヒットする「Starship Troopers」は mail 4439 の件名です。**本文に「Independence Day」という語は無い**のに引けるのは、auto-tag が relation 経由でその関連トピックを chunk の検索フィールドに注入したから（＝seed→検索の接続）。これが「ClaudeEval のプロンプト → OOPS seed 検索」の経路です。

> **ClaudeEval プロンプト自体を走らせる場合の前提**: (1) 上のように `oops-kb` と `<rc>-bm25` 索引を **事前に build 済み**にすること、(2) 初回は権限ダイアログで **`sourcevault_search` ツールを承認**すること。索引が無い / 未承認だと LLM は「検索を実行できませんでした（承認してください）」と返し、ローカルモデルによってはツール失敗でリトライを繰り返して停滞し、メッセージ窓に `[LLMGraph] カスケード失敗` が並ぶことがあります（検索関数側でなく、未セットアップ＋ツール未承認＋モデルのリトライ挙動）。そのため本書は、確実に検証できる上の Wolfram 等価コードで挙動を示しています。

## シナリオ 0.2: 調査ワークフロー — 検索 × KG 展開 × 再検索

あるトピックの周辺を掘る調査では、**KG 局所探索で関連トピックへ広げ、各関連トピックで再検索する** ワークフローが有効です（上の `oops-kb` 索引を再利用）。

```mathematica
(* Total Recall (ki:99) の関連トピックへ 1-hop 展開 *)
kg = SourceVaultExpandSearchGraph[{"svtopic:oops:ki:99"},
  "RelationGraph" -> relationGraph, "RefLabel" -> refLabel,
  "MaxHops" -> 1, "MaxNodes" -> 4, "MinEdgeWeight" -> 3];
relatedLabels = #["Label"] & /@ kg["Expanded"];   (* => {"映画", "テレビ", "Starship Troopers"} *)

(* 各関連トピックのラベルで索引を再検索して該当メールを引く *)
searchTop = Function[q, Module[{r = SourceVaultSearch[q,
    "ReleaseContext" -> "oops-kb", "Index" -> oIdx, "Limit" -> 1]},
  If[r === {}, "(なし)", r[[1]]["ChunkId"]]]];
(# -> searchTop[#]) & /@ relatedLabels

(* 後始末 *)
SourceVault`SearchIndexPrivate`$registries["ReleaseContext"] =
  KeyDrop[SourceVault`SearchIndexPrivate`$registries["ReleaseContext"], {"oops-kb"}];
SourceVault`SearchIndexPrivate`iRegistrySave[];
```

**期待される出力例:**

```
{"映画"              -> "oops-4439",
 "テレビ"            -> "oops-4425",
 "Starship Troopers" -> "oops-4439"}
```

「Total Recall」から広げた関連トピック（映画 / テレビ / Starship Troopers）で再検索し、該当メールを引き当てます。仕様生成・実装の側でも、同じ `sourcevault_search` を呼べば、OOPS の topic 付きコンテンツを retrieval-augmented に参照できます（release gate 付き）。汎用（OOPS 非依存）の仕様実装ワークフロー例は [`search_foundation_example.md`](search_foundation_example.md) のシナリオ 0.2 を参照。

---

# 基本編

## 例 1: seed 辞書の取り込みと owner-scoped 統計

`item-name.index`（Common Lisp S 式・ShiftJIS）を読み、owner 名前空間つきの topic 辞書にします。名前空間は enum 決め打ちせず実データの分布をそのまま保持します（typo も落とさない）。

```mathematica
stats = SourceVaultSeedDictionaryStats[dict];
KeyTake[stats, {"EntryCount", "NamespaceTally", "OwnerResolved",
  "BilingualCount", "TotalSurfaceForms"}]

(* surface form → topic ref（同名は owner union で複数保持）*)
Lookup[surfaceIndex, "映画", {}]
```

**期待される出力例:**

```
<|"EntryCount"        -> 4099,
  "NamespaceTally"    -> <|"ki" -> 3332, "aga" -> 347, "e" -> 298, "mi" -> 60,
                          "caitsith" -> 55, "tom" -> 2, "ara" -> 2,
                          "catisith" -> 1, "lki" -> 1, "anonymous" -> 1|>,
  "OwnerResolved"     -> 3332,
  "BilingualCount"    -> 238,
  "TotalSurfaceForms" -> 5394|>

{"svtopic:oops:ki:195", "svtopic:oops:e:203"}
```

4099 topic を 10 名前空間で取り込み、「日本語 English」「日本語(English)」併記は別名に分割（bilingual 238）。surface form「映画」は 2 つの正当な topic（ki:195 と e:203）に張られます。

---

## 例 2: entity OR-match — 英語 query が日本語 doc に一致（表記非一致/OOV 回復）

seed 辞書を BM25 stats に渡すと、query と doc の**表記が違っても**、同じ topic の別名どうしが `entity:<ref>` で結ばれてヒットします。

```mathematica
docs = {
  <|"ChunkId" -> "sf1", "SearchFields" -> <|"title" -> "SF", "body" -> "ブルース・スターリングの新作を読んだ"|>|>,
  <|"ChunkId" -> "sf2", "SearchFields" -> <|"title" -> "料理", "body" -> "今日はカレーを作った"|>|>};

withDict = SourceVaultBuildLexicalStats[docs, "EntityDictionary" -> dict];
plain    = SourceVaultBuildLexicalStats[docs];

{"辞書あり" -> ({#["ChunkId"], Round[#["Score"], 0.01]} & /@
    SourceVaultLexicalRank["Bruce Sterling", withDict, "Limit" -> 3, "Breakdown" -> False]),
 "辞書なし" -> ({#["ChunkId"], Round[#["Score"], 0.01]} & /@
    SourceVaultLexicalRank["Bruce Sterling", plain, "Limit" -> 3, "Breakdown" -> False])}
```

**期待される出力例:** `{"辞書あり" -> {{"sf1", 0.55}}, "辞書なし" -> {}}`

英語の「Bruce Sterling」で、本文が日本語「ブルース・スターリング…」の sf1 にヒットします（seed 辞書が両表記を同じ topic の別名として結ぶ）。辞書が無ければ 1 件も出ません＝seed オントロジの OOV/表記ゆれ回復の価値。

---

## 例 3: メール解析の品質 — MIME 復号 / 語境界 / 退化トピック除去

一般メールを検索に載せる前の 3 つの品質担保です。

```mathematica
mails = SourceVaultParseOOPSMailFile[FileNameJoin[{$oopsMail, "oops 9805.txt"}]]["Mails"];

(* (a) RFC 2047 MIME encoded-word の Subject 復号（ISO-2022-JP を含む）*)
subj = SelectFirst[mails, #["Counter"] == 4444 &]["Subject"];
encodedLeft = Count[#["Subject"] & /@ mails,
  s_ /; StringContainsQ[s, "=?"] && StringContainsQ[s, "?="]];

(* (b) Latin↔CJK の語境界照合（"itmsの" のように CJK に隣接しても拾う。語中誤一致は防ぐ）*)
present = SourceVault`Private`iSVSurfaceFormPresentQ;

{"(a) mail4444 Subject" -> subj,
 "(a) 未復号 encoded-word 数" -> encodedLeft,
 "(b) itmsの提供 に itms?" -> present["itmsの提供", "itms"],
 "(b) starship に tar?(誤一致防止)" -> present["starship", "tar"],
 "(c) 映画→refs(退化 anonymous:0 は除外済)" -> Lookup[surfaceIndex, "映画", {}]}
```

**期待される出力例:**

```
{"(a) mail4444 Subject"          -> "転勤",
 "(a) 未復号 encoded-word 数"     -> 0,
 "(b) itmsの提供 に itms?"        -> True,
 "(b) starship に tar?(誤一致防止)" -> False,
 "(c) 映画→refs(退化 anonymous:0 は除外済)" -> {"svtopic:oops:ki:195", "svtopic:oops:e:203"}}
```

- (a) `=?ISO-2022-JP?B?GyRCRT42UBsoSg==?=` が「転勤」に復号され、encoded-word の残りは 0。
- (b) 「itmsの」の `itms` は拾い（Latin が CJK に隣接）、「starship」の `tar` は拾わない（語中誤一致を防ぐ）。
- (c) ラベル「・」で数百 surface form を持つ catch-all の `anonymous:0` は surface index 構築時に除外され、「映画」は正当な 2 topic だけを指します。

---

# 中級編

## 例 4: 段落の auto-tag — 正準トピック＋関連トピック（relation 1-hop）

一般メールの段落に seed topic を自動付与します。本文に出現する named topic（SeedMatched）に加え、`RelationGraph` を渡すと 1-hop の関連 topic（RelationExpanded、本文に無くてもよい）も低 confidence で付きます。

```mathematica
relationGraph = SourceVaultBuildOOPSRelationGraph[$oopsTable]["RelationGraph"];
Length[relationGraph]   (* => 2875 : relation を持つ topic 数 *)

label = Function[r, Lookup[refLabel, r, r]];
mail4439 = SelectFirst[mails, #["Counter"] == 4439 &];
paragraphs = SourceVaultParseMailParagraphs[SourceVaultStripOOPSMarkers[mail4439["Body"]]];

assigned = SourceVaultAssignParagraphTopics[paragraphs, surfaceIndex,
  "RelationGraph" -> relationGraph,   (* RelationExpanded を有効化 *)
  "RefLabel" -> refLabel];            (* 同一ラベルの重複 topic を collapse *)

byKind = GroupBy[
  SelectFirst[assigned, #["Assignments"] =!= {} &]["Assignments"],
  #["AssignmentKind"] &];
{"SeedMatched"      -> (label[#["TopicItemRef"]] & /@ Lookup[byKind, "SeedMatched", {}]),
 "RelationExpanded" -> (label[#["TopicItemRef"]] & /@ Take[Lookup[byKind, "RelationExpanded", {}], UpTo[4]])}
```

**期待される出力例:**

```
{"SeedMatched"      -> {"Total Recall", "Starship Troopers", "映画"},
 "RelationExpanded" -> {"ヨーク軍曹", "映画", "宇宙の戦士", "テレビ"}}
```

映画「Total Recall」「Starship Troopers」を語る段落に、その関連トピック（「宇宙の戦士」= Starship Troopers の小説邦題、など）が付きます。SeedMatched は常に RelationExpanded より高 confidence です。

---

## 例 5: 新トピック育成 — 候補抽出 → 確認 → 永続 → 検索可能

seed（1992–2005 語彙）に無い語（例: 2005 年の "iTMS"）を一般メールから候補として抽出し、owner が確認したら seed 同形の topic にして辞書へ編入します。編入後は SeedMatched で引けます。

```mathematica
mails06 = SourceVaultParseOOPSMailFile[FileNameJoin[{$oopsMail, "oops 200506.txt"}]]["Mails"];
paragraph = First@Select[
  Flatten[SourceVaultParseMailParagraphs[SourceVaultStripOOPSMarkers[#["Body"]]] & /@ Take[mails06, UpTo[10]]],
  #["Kind"] === "Prose" && StringContainsQ[#["Text"], "iTMS"] &];

(* 新トピック候補（seed 既知語は除外）*)
#["Surface"] & /@ SourceVaultExtractCandidateTopics[paragraph["Text"],
  "KnownSurfaceIndex" -> surfaceIndex, "Limit" -> 6]
(* => {アップルコンピュータ, iTunes, 日本経済新聞, Store, Music, iTMS} *)

(* iTMS を確認 → 辞書に merge → 再 index すると SeedMatched で引ける *)
confirmed = SourceVaultConfirmCandidateTopics[
  {<|"Surface" -> "iTMS", "ExtractionKind" -> "Latin"|>},
  "ExistingDictionary" -> dict, "OwnerRef" -> "sventity:owner:imai"];
sidx2 = SourceVaultBuildSurfaceIndex[confirmed["MergedDictionary"]];

paraAssoc = {<|"Index" -> 1, "Kind" -> "Prose", "Text" -> paragraph["Text"]|>};
before = SelectFirst[First[SourceVaultAssignParagraphTopics[paraAssoc, surfaceIndex,
    "ExtractCandidates" -> True]]["Assignments"], Lookup[#, "ProposedLabel", ""] === "iTMS" &];
after = SelectFirst[First[SourceVaultAssignParagraphTopics[paraAssoc, sidx2]]["Assignments"],
    StringQ[#["TopicItemRef"]] && StringContainsQ[#["TopicItemRef"], "extracted"] &];

{"確認前" -> before["AssignmentKind"],
 "確認後" -> {after["AssignmentKind"], after["TopicItemRef"]}}
```

**期待される出力例:**

```
{アップルコンピュータ, iTunes, 日本経済新聞, Store, Music, iTMS}
{"確認前" -> "AutoExtracted", "確認後" -> {"SeedMatched", "svtopic:extracted:1"}}
```

「iTMS」は確認前は要確認候補（AutoExtracted）、確認・辞書編入後は SeedMatched で引けます。確認済みトピックは `SourceVaultSaveExtractedTopics[entries, path]` で永続でき、`SourceVaultLoadExtractedTopics` で読み戻して seed に Join できます。

---

# 応用編

## 例 6: seed→検索の接続 — 本文に無い関連トピックでヒット（プロジェクトの核）

mail を **topic 注入つきの検索 chunk** にして BM25 index を build します。auto-tag が relation 経由で「Independence Day」を chunk の `topics` に注入するので、本文にその語が無くても検索でヒットします。

```mathematica
chunks = SourceVaultBuildMailChunks[mail4439, surfaceIndex,
  "Granularity" -> "Mail", "RelationGraph" -> relationGraph,
  "RefLabel" -> refLabel, "PrivacyLevel" -> 0.3];
(* chunks[[1]]["SearchFields"]["topics"] に auto-tag した topic ラベルが入る:
   "Total Recall ... Starship Troopers 宇宙の戦士 ... Independence Day (ID4) ..." *)

SourceVaultRegisterReleaseContext["oops-example", <|"MaxPrivacyLevel" -> 1.0|>];
idx = "oops-bm25-" <> StringTake[StringDelete[CreateUUID[], "-"], 8];
SourceVaultBuildProjectionIndex["oops-example", "Chunks" -> chunks,
  "IndexKind" -> "KeywordBM25V1", "EntityDictionary" -> dict, "IndexId" -> idx];

(* "Independence Day" は mail 4439 の本文に literal では出てこない関連トピック *)
{#["ChunkId"], Round[#["Score"], 0.01], #["RetrievalKind"], #["ReleaseDecision"]} & /@
  SourceVaultSearch["Independence Day", "ReleaseContext" -> "oops-example", "Index" -> idx, "Limit" -> 3]

SourceVault`SearchIndexPrivate`$registries["ReleaseContext"] =
  KeyDrop[SourceVault`SearchIndexPrivate`$registries["ReleaseContext"], {"oops-example"}];
SourceVault`SearchIndexPrivate`iRegistrySave[];
```

**期待される出力例:** `{{"oops-4439", 6.29, "KeywordBM25", "Permit"}}`

mail 4439 は本文で「Total Recall」「Starship Troopers」を語りますが、「Independence Day」という語は本文にありません。それでもヒットするのは、relation-aware auto-tag が関連トピック「Independence Day (ID4)」を chunk の検索フィールドに注入したからです。＝「一般メールを seed 形式に変換して検索精度を上げる」の end-to-end 実証。topics を注入しない index ではヒットしません。

---

## 例 7: OOPS relation の KG 局所探索（§6.3）

OOPS の重み付き topic relation を multi-hop で辿ります。ある映画トピックから、関連する映画・テレビ・作品へと広がる「局所近傍」を取り出せます。

```mathematica
kg = SourceVaultExpandSearchGraph[{"svtopic:oops:ki:99"} (* Total Recall *),
  "RelationGraph" -> relationGraph, "RefLabel" -> refLabel,
  "MaxHops" -> 2, "MaxNodes" -> 8, "MinEdgeWeight" -> 2];

{"nodes/edges" -> {kg["NodeCount"], kg["EdgeCount"]},
 "expanded" -> ({#["Hop"], #["Label"]} & /@ kg["Expanded"])}
```

**期待される出力例:**

```
{"nodes/edges" -> {8, 20},
 "expanded" -> {{1, "映画"}, {1, "テレビ"}, {1, "Starship Troopers"},
                {2, "チャーリーズ・エンジェル"}, {2, "任天堂"}, {2, "Independence Day (ID4)"},
                {2, "吾妻ひでお"}, {2, "ウゴウゴルーガ"}}}
```

「Total Recall」の 1-hop（映画 / テレビ / Starship Troopers）と、そこから 2-hop（Independence Day など）が展開されます。`MaxNodes` / `MinEdgeWeight` / per-node top-k で近傍の広がりを制御でき、cycle 安全です。例 6 で検索ヒットに使った関連トピックが、この KG 近傍として可視化されているのが分かります。

---

# 可視化・ユーティリティ層

第 1–3 部は seed 辞書・auto-tag・検索の**部品**を個別に見ました。第 4 部は、それらを **1 発で初期化して**（`SourceVaultOOPSEnsureLoaded`）スレッドを一覧・描画・閲覧する高レベル関数です。これらは ClaudeEval のプロンプトからも（MCP tool 経由で）呼べます。関数仕様は [`../api_oopsseed.md`](../api_oopsseed.md) の「可視化（ノートブック表示）」節。

> 第 4 部は自己完結です（上の `dict` / `surfaceIndex` に依存しません）。`SourceVaultOOPSEnsureLoaded` が seed 辞書・surface index・relation graph・quote table・メール・引用・session をまとめてメモリ状態 `$svOOPSState` に載せます（冪等）。

## 例 8: 単一初期化とスレッド一覧（`SourceVaultOOPSEnsureLoaded` / `...Sessions`）

```mathematica
SourceVaultOOPSEnsureLoaded["MailFiles" -> "oops 9805.txt"]   (* 冪等。戻り値は状態要約 *)

SourceVaultOOPSSessions["Limit" -> 5]   (* MailCount 降順の Dataset *)
```

**期待される出力例:**

```
<|"Loaded" -> True, "MailCount" -> 30, "SessionCount" -> 12,
  "TopicCount" -> 4099, "Files" -> 1, "SessionIndexBuilt" -> False|>

(* Dataset: Session / Subject / Kind / Mails *)
svmailsession:4431-4449   Re: DV, FireWire, I-Link   QuoteCluster   9
svmailsession:4432-4437   Adaptec 2940UW             QuoteCluster   6
svmailsession:4428-4430   LA Symposium               QuoteCluster   3
svmailsession:4421-4424   Sorenson Video             QuoteCluster   3
svmailsession:4444-4445   転勤                        ReplyThread    2
```

30 通が引用連結で 12 スレッドに構造化されます（QuoteCluster / ReplyThread / Singleton）。この状態の上で以降の描画・閲覧・検索が動きます。スレッド検索（`SourceVaultOOPSSearchThreads`、`CloudSafe` 付き）とスレッド詳細（`SourceVaultOOPSThread`）は [`mail_structuring_example.md`](mail_structuring_example.md) の例 9 を参照。

## 例 9: topic item graph の描画（`SourceVaultOOPSThreadGraph`）

スレッドの話題どうしの関係を `Graph` で可視化します。ノード = 話題（topic item）、辺は 3 種を色分けし、ノードサイズは支持段落数に比例します。

```mathematica
SourceVaultOOPSThreadGraph["svmailsession:4431-4449", "MaxNodes" -> 12]
```

**期待される出力例:** ノートブックに `Graph` が描画されます（頂点 12 / 辺 44）。

```
Graph[ 頂点 12・辺 44 ]
  ノード: 話題ラベル（サイズ = 支持段落数。FireWire が中心の大ノード）
  辺の色: 青 = 同段落共起(CoParagraph) / 赤 = 引用遷移(QuoteTransition) / 灰 = seed relation
```

DV/FireWire スレッドでは「FireWire」を中心に「Radius EditDV」「HandyCam」等が同段落共起（青）で結ばれ、引用をまたぐ話題遷移（赤）や seed 由来の関係（灰）が重なります。`SourceVaultOOPSThreadGraph` は内部で `SourceVaultBuildTopicItemGraph`（引用エッジ込み）を構築してから `SourceVaultOOPSTopicGraphPlot` で描画します。topic item graph を自分で組んで `SourceVaultOOPSTopicGraphPlot` に直接渡すこともできます（`$svOOPSState` は `SourceVaultOOPSEnsureLoaded` が用意した状態）:

```mathematica
st = SourceVault`$svOOPSState;
tg = SourceVaultBuildTopicItemGraph[st["Mails"],
  "SurfaceIndex" -> st["SurfaceIndex"], "RelationGraph" -> st["RelationGraph"],
  "RefLabel" -> st["RefLabel"], "QuoteEdges" -> st["QuoteEdges"]];
SourceVaultOOPSTopicGraphPlot[tg, "MaxNodes" -> 15]   (* 全メール横断の話題ネットワーク *)
```

## 例 10: スレッド詳細ビューと一覧（`SourceVaultOOPSThreadView` / `...ThreadList`）

`SourceVaultOOPSThreadView` は 1 スレッドの Subject・種別・話題・**決定的 digest**（LLM 非依存）を枠付きの `Column` で表示します。`SourceVaultOOPSThreadList` はスレッド一覧を `Grid` で出し、Subject ボタンを押すと該当スレッドの詳細ビューが新規ノートブックで開きます。

```mathematica
SourceVaultOOPSThreadView["svmailsession:4431-4449"]   (* 枠付き Column *)

SourceVaultOOPSThreadList["Limit" -> 6]                 (* ボタン付き Grid *)
```

**期待される出力例:**

```
(* ThreadView: Framed[Column[...]] *)
Re: DV, FireWire, I-Link  (9通 / QuoteCluster)
話題: HandyCam, PowerPC 750, おめでた, テレビ, AltaVista
#4431 "Katsunobu IMAI":  HandyCam  Radius EditDV  FireWire …
#4440 "T. EBINE": やっぱり物量が必要だから，そう簡単には普及しな いか． …

(* ThreadList: Grid[7 行 (ヘッダ + 6 スレッド) × 3 列] *)
Subject(ボタン)            種別           通数
Re: DV, FireWire, I-Link   QuoteCluster   9
Adaptec 2940UW             QuoteCluster   6
…
```

話題行は各メールの ◎ Primary 明示トピックに限定され精密です（`SourceVaultBuildSessionDigest` の既定）。一覧の Subject ボタンは `CreateDocument[SourceVaultOOPSThreadView[…]]` を呼ぶので、ノートブック上でスレッドをドリルダウンできます。

---

## クリーンアップ

seed 辞書の取り込みと auto-tag は読み取りと純関数だけで、実 vault に痕跡を残しません。release context を登録した例 6 は末尾で登録解除しています。例 5 の `SourceVaultSaveExtractedTopics` を実ファイルに保存した場合のみ、そのファイルが残ります（不要なら削除してください）。
