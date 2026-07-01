# SourceVault メール構造化・検索 使用例（§6.5）

メールを **段落トピック → 引用グラフ → スレッド（session）→ topic item graph** に構造化し、**スレッド単位で検索**したり、**スレッド要約（digest）を primer で引く**例集です。OOPS メーリングリストの実データで動かし、末尾の「期待される出力例」は実測値です。

対象: `SourceVault_oopsseed.wl` の §6.5 実装（quote / session / topic graph / session 検索 / session primer / 明示トピック）。関数仕様は [`../api_oopsseed.md`](../api_oopsseed.md)。seed オントロジ・auto-tag の基礎は [`oops_example.md`](oops_example.md) を参照。

構成: **基本編**（引用・スレッド・明示トピック）→ **中級編**（topic graph・スレッド検索）→ **応用編**（スレッド要約 primer・privacy・受信者 defense-in-depth・cloud-safe 検索・MCP tool）。

---

## 事前準備

`$dropbox` / `$packageDirectory` は init ファイルで定義済みとします（参照のみ）。OOPS archive は `$dropbox/udb/oops-ml-archive/oops-ml-archive/` 以下。

> **文字コード**: このファイルは UTF-8。ShiftJIS 既定カーネルで `Get` する場合は `Block[{$CharacterEncoding="UTF-8"}, Get["…"]]` で読むこと。

```mathematica
Block[{$CharacterEncoding = "UTF-8"}, Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]]

$oopsTable = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "db", "table"}];
$oopsMail  = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "oops-ml-generate"}];

(* seed 辞書・surface index・relation graph・quote table・メール（以降で共有）*)
dict = SourceVaultImportOOPSSeedDictionary[FileNameJoin[{$oopsTable, "item-name.index"}]]["Dictionary"];
surfaceIndex = SourceVaultBuildSurfaceIndex[dict];
refLabel = Association[(#["TopicItemRef"] -> #["CanonicalLabel"]) & /@ dict["Entries"]];
relationGraph = SourceVaultBuildOOPSRelationGraph[$oopsTable]["RelationGraph"];
quoteTable = SourceVaultImportOOPSQuoteTable[FileNameJoin[{$oopsTable, "quote-table.index"}]]["Quotes"];
mails = SourceVaultParseOOPSMailFile[FileNameJoin[{$oopsMail, "oops 9805.txt"}]]["Mails"];
```

> `quote-table.index` は約 477KB。S 式リーダは `FromDigits` / `StringJoin[cs[[…]]]` 化により約 6 秒で読める（旧実装は整数ごとの `ToExpression` と `StringTake` の O(n²) で共有カーネルが wedge していた）。

---

# 基本編

## 例 1: 引用グラフ（quote edge）

OOPS はスレッドヘッダ（In-Reply-To / References）を持たず、seed の `quote-table.index` が authoritative な引用グラフです。本文の `-*- Quote (from N) -*-` マーカー（メール番号 / URL）も併用します。

```mathematica
(* seed quote table: メール 5227 が引用している元メールと standard-quote id *)
{#["FromMail"], #["StandardQuoteId"]} & /@ Take[Lookup[quoteTable, 5227, {}], 3]

(* SourceVaultMailQuoteEdge を構築（seed=SeedStandardQuote / 本文=ExplicitMarker・ExternalURL）*)
edges = SourceVaultBuildMailQuoteEdges[mails, "QuoteTable" -> quoteTable];
Tally[#["QuoteKind"] & /@ edges]
```

**期待される出力例:**

```
{{5226, 524}, {5226, 525}, {5226, 526}}          (* 5227 は 5226 を quote *)
{{"ExternalURL", 10}, {"SeedStandardQuote", 84}, {"ExplicitMarker", 4}}
```

各 edge は `<|"FromMailRef" -> "sv://mail/…", "ToMailRef" -> "sv://mail/…", "QuoteKind", "SeedQuoteId", "Confidence"|>`。SeedStandardQuote は Confidence 1.0（authoritative）。

## 例 2: スレッド（mail session）

quote edge の連結成分と Subject の `Re:`/`Fwd:` 正規化でメールをスレッド（session）にまとめます。

```mathematica
sessions = SourceVaultBuildMailSessions[mails, edges];
{Length[sessions], Tally[#["SessionKind"] & /@ sessions]}

(* 最大スレッド *)
SelectFirst[sessions, #["MailCount"] == 9 &] //
  KeyTake[#, {"MailSessionId", "MailCount", "SessionKind", "Subject"}] &
```

**期待される出力例:**

```
{12, {{"QuoteCluster", 4}, {"ReplyThread", 1}, {"Singleton", 7}}}
<|"MailSessionId" -> "svmailsession:4431-4449", "MailCount" -> 9,
  "SessionKind" -> "QuoteCluster", "Subject" -> "Re: DV, FireWire, I-Link"|>
```

30 通が 12 スレッドに。「Re: DV, FireWire, I-Link」は 9 通の QuoteCluster（引用で連結したスレッド）。

## 例 3: 明示トピック（◎/○/・, TopicRole）

OOPS メールは本文冒頭に **人手で付けた明示トピック** `◎(Primary)/○(Secondary)/・(Mentioned) <label>[ns id]` を持ちます。`[ns id]` が topic ref を直接与える最高品質シグナルです（surface form 照合より上位）。

```mathematica
m4439 = SelectFirst[mails, #["Counter"] == 4439 &];
{#["CanonicalLabel"], #["TopicRole"]} & /@ SourceVaultExtractExplicitTopics[m4439["Body"]]
```

**期待される出力例:**

```
{{"映画", "Primary"}, {"Total Recall", "Secondary"},
 {"Starship Troopers", "Mentioned"}, {"Adobe After Effects", "Mentioned"}}
```

この 3 つ（映画 / Total Recall / Starship Troopers）は mail 4439 の gold そのもの。`SourceVaultAssignParagraphTopics`（`"ExplicitTopics" -> True` 既定）はこれを `AssignmentKind = "ExplicitOOPS"`（conf 1.0）で最優先に付与し、検索の topic に載せます。

---

# 中級編

## 例 4: topic item graph

段落トピックをノード、同一段落共起を CoParagraph、引用越しを QuoteTransition、seed 関係を SeedRelation とするグラフを作ります（スレッド内）。

```mathematica
dv = Select[mails, MemberQ[{4431, 4440, 4441, 4442, 4443, 4446, 4447, 4448, 4449}, #["Counter"]] &];
dvEdges = SourceVaultBuildMailQuoteEdges[dv, "QuoteTable" -> quoteTable];
graph = SourceVaultBuildTopicItemGraph[dv,
  "SurfaceIndex" -> surfaceIndex, "RelationGraph" -> relationGraph,
  "RefLabel" -> refLabel, "QuoteEdges" -> dvEdges];  (* MaxTopicsPerMailForQuote 既定 4 *)

{graph["NodeCount"], graph["EdgeKindTally"]}
(* 中心トピック（支持段落数）*)
{#["Label"], Length[#["SupportParagraphs"]]} & /@
  Take[ReverseSortBy[graph["Nodes"], Length[#["SupportParagraphs"]] &], 3]
```

**期待される出力例:**

```
{39, <|"CoParagraph" -> 19, "QuoteTransition" -> 160, "SeedRelation" -> 16|>}
{{"FireWire", 12}, {"Radius EditDV", 6}, {"HandyCam", 6}}
```

スレッドの中心は **FireWire**（12 段落で支持）。QuoteTransition は各メール上位 4 トピックに絞って bounded（`MaxTopicsPerMailForQuote`）。

## 例 5: スレッド単位の検索

session を 1 つの検索 chunk（全メール本文＋topic 注入）にして BM25 index を作ると、**query がスレッド全体を引けます**。

```mathematica
sessionChunks = SourceVaultBuildSessionChunks[mails, sessions,
  "SurfaceIndex" -> surfaceIndex, "RelationGraph" -> relationGraph, "RefLabel" -> refLabel];

SourceVaultRegisterReleaseContext["mail-search", <|"MaxPrivacyLevel" -> 1.0|>];
idx = "mail-bm25-" <> StringTake[StringDelete[CreateUUID[], "-"], 8];
SourceVaultBuildProjectionIndex["mail-search", "Chunks" -> sessionChunks,
  "IndexKind" -> "KeywordBM25V1", "EntityDictionary" -> dict, "IndexId" -> idx];

{#["ChunkId"], Round[#["Score"], 0.01], #["ReleaseDecision"]} & /@
  SourceVaultSearch["FireWire", "ReleaseContext" -> "mail-search", "Index" -> idx, "Limit" -> 2]
```

**期待される出力例:**

```
{{"svmailsession:4431-4449", 9.7,  "Permit"},
 {"svmailsession:4432-4437", 7.78, "Permit"}}
```

「FireWire」で DV/FireWire スレッド（9 通）が 1 件目、Adaptec スレッドが 2 件目。個別メールではなく**スレッドが検索単位**になります。（context は応用編の末尾で登録解除）

---

# 応用編

## 例 6: スレッド要約を primer で引く（結論探し）

session を primer item にすると、`SourceVaultPrimerSearch` が **LLM 非依存の決定的 digest** 付きでスレッドを引きます。大きいスレッドほど importance で上位に。

```mathematica
primerItems = SourceVaultBuildSessionPrimerItems[mails, sessions,
  "SurfaceIndex" -> surfaceIndex, "RelationGraph" -> relationGraph, "RefLabel" -> refLabel];

pid = "mail-primer-" <> StringTake[StringDelete[CreateUUID[], "-"], 8];
SourceVaultBuildPrimerIndex["mail-search", "Items" -> primerItems, "PrimerId" -> pid];
SourceVaultLoadPrimerIndex[pid];

<|"obj" -> #["SourceVaultObjectId"], "score" -> Round[#["Score"], 0.01], "ev" -> #["EvidenceKind"]|> & /@
  SourceVaultPrimerSearch["FireWire", "ReleaseContext" -> "mail-search", "PrimerIndex" -> pid, "Limit" -> 2]

(* スレッドの決定的 digest（要約）*)
SelectFirst[primerItems, #["SourceVaultObjectId"] === "svmailsession:4431-4449" &]["Summary"]
```

**期待される出力例:**

```
{<|"obj" -> "svmailsession:4431-4449", "score" -> 11.07, "ev" -> "SummaryPrimer"|>,
 <|"obj" -> "svmailsession:4420-4420", "score" -> 4.22,  "ev" -> "SummaryPrimer"|>}

[スレッド] Re: DV, FireWire, I-Link (9通/QuoteCluster)
話題: HandyCam, PowerPC 750, おめでた, テレビ, AltaVista
#4431 "Katsunobu IMAI":  HandyCam  Radius EditDV  FireWire …
#4440 "T. EBINE": やっぱり物量が必要だから，そう簡単には普及しな いか． …
```

digest は Subject＋話題＋各メールの `#番号 著者: 先頭段落` のタイムライン。**話題は既定で各メールの ◎(Primary) 明示トピックに限定**され精密です（`PrimaryTopicsOnly -> True`）。◎ の無いスレッドは enrichment 上位に fallback。「日程・事項の結論」を探す query は、個別メールより session の digest primer が向きます。

## 例 7: 私的リストの gate（§6.5.3 privacy / trust class）

`X-Ml-Name` が `"OOPS Mailing List Under Ground"`（= 私的 oops-ura）のメールは `PrivacyLevel 0.6` ＋ `{"PrivateML", "NoCloudLLM", "NoPublicExport"}` タグを得ます。session は 1 通でも私的なら私的扱い（max / union）。cloud LLM / public export の release context はこれらを `DenyTags` に持つので自動除外されます。

```mathematica
(* session chunk の tags 分布（例 5 の sessionChunks）*)
Tally[Sort /@ (#["Tags"] & /@ sessionChunks)]

(* cloud LLM 用 context（PrivateML / NoCloudLLM を deny）で gate *)
SourceVaultRegisterReleaseContext["cloud-llm",
  <|"MaxPrivacyLevel" -> 1.0, "DenyTags" -> {"PrivateML", "NoCloudLLM"}|>];
Tally[SourceVaultEvaluateReleasePolicy[#, "cloud-llm"]["Decision"] & /@ sessionChunks]

(* 後始末 *)
SourceVault`SearchIndexPrivate`$registries["ReleaseContext"] =
  KeyDrop[SourceVault`SearchIndexPrivate`$registries["ReleaseContext"], {"mail-search", "cloud-llm"}];
SourceVault`SearchIndexPrivate`iRegistrySave[];
```

**期待される出力例:**

```
{{{"MailingList", "OOPS"}, 9},
 {{"MailingList", "NoCloudLLM", "NoPublicExport", "OOPS", "PrivateML"}, 3}}
{{"Permit", 9}, {"Deny", 3}}
```

12 スレッド中 3 つが私的リスト由来（PrivateML）。cloud-llm context では公開 9 が Permit、私的 3 が **Deny**＝私的リストの内容が cloud LLM / 公開へ漏れません。

## 例 8: 受信者(To/Cc)ベース privacy（defense-in-depth）

`X-Ml-Name` に加え、**`To`/`Cc` の addr-spec だけからも** privacy を判定します（`SourceVaultMailRecipientPrivacy`）。私的リストアドレス（`oops-ura@…`）宛なら、たとえ `X-Ml-Name` が欠落・詐称されても私的と判定できます（独立した第 2 の防御）。ML でない一般メール（個人宛）にも使えます。

```mathematica
(* 私的メール（To: oops-ura@…）*)
m = SelectFirst[mails, StringContainsQ[#["To"], "oops-ura"] &];
KeyDrop[SourceVaultMailRecipientPrivacy[m], "Recipients"]

(* defense-in-depth: X-Ml-Name を消しても To から私的判定できる *)
KeyDrop[SourceVaultMailRecipientPrivacy[Append[m, "MlName" -> ""]], "Recipients"]

(* 個人宛のみ / 公開リスト宛 *)
KeyDrop[SourceVaultMailRecipientPrivacy[<|"To" -> "alice@example.com, bob@example.co.jp"|>], "Recipients"]
KeyDrop[SourceVaultMailRecipientPrivacy[<|"To" -> "oops@satsuki.net"|>], "Recipients"]
```

**期待される出力例:**

```
<|"PrivacyLevel" -> 0.6, "Tags" -> {"PrivateML", "NoCloudLLM", "NoPublicExport"}, "Signal" -> "PrivateRecipient"|>
<|"PrivacyLevel" -> 0.6, "Tags" -> {"PrivateML", "NoCloudLLM", "NoPublicExport"}, "Signal" -> "PrivateRecipient"|>
<|"PrivacyLevel" -> 0.5, "Tags" -> {"DirectRecipients"}, "Signal" -> "IndividualRecipients"|>
<|"PrivacyLevel" -> 0., "Tags" -> {}, "Signal" -> "None"|>
```

`SourceVaultBuildSessionChunks` / `...PrimerItems` は session の privacy を **list 名由来 ∪ 受信者由来** の max / union で採ります（`X-Ml-Name` と `To` の二重防御）。

## 例 9: cloud-safe スレッド検索・詳細（MCP と同じ gate）

ユーティリティ層 `SourceVaultOOPSEnsureLoaded` で 1 発初期化し、`SourceVaultOOPSSearchThreads` / `SourceVaultOOPSThread` を使います。**`CloudSafe -> True`** で §6.5.3 私的リストスレッドを gate します（後述の MCP tool `sourcevault_oops_*` はこれを常用）。

```mathematica
SourceVaultOOPSEnsureLoaded["MailFiles" -> "oops 9805.txt"];

(* 「転勤」は私的スレッド: 通常検索では出るが CloudSafe では除外される *)
#["Subject"] & /@ Normal @ SourceVaultOOPSSearchThreads["転勤"]
#["Subject"] & /@ Normal @ SourceVaultOOPSSearchThreads["転勤", "CloudSafe" -> True]

(* 私的スレッドの詳細は CloudSafe では withheld（Released -> False）*)
SourceVaultOOPSThread["svmailsession:4444-4445", "CloudSafe" -> True]

(* 公開スレッドの TopicLabels は ◎ Primary 寄せ（AllTopics に広い enrichment）*)
th = SourceVaultOOPSThread["svmailsession:4431-4449"];
{th["TopicLabels"], th["AllTopics"]}
```

**期待される出力例:**

```
{転勤, Adaptec 2940UW, Re: DV, FireWire, I-Link}
{Adaptec 2940UW, Re: DV, FireWire, I-Link}
<|"Session" -> "svmailsession:4444-4445", "Subject" -> "転勤", "SessionKind" -> "ReplyThread", "Released" -> False, "Why" -> {"PrivateList", "NoCloudLLM"}|>
{{HandyCam, PowerPC 750, おめでた, テレビ, AltaVista},
 {コンセント, Macintosh, アポロ計画, Motorola, goo.ne.jp, quote, Radius EditDV, PowerPC 750, 何でも鑑定団, PowerBook}}
```

私的「転勤」は CloudSafe 検索で消え、詳細も `Released -> False`。`TopicLabels`（◎ 主題のみで簡潔）と `AllTopics`（広い enrichment ＝俯瞰 / recall 用）を使い分けます。

## MCP tool（ClaudeEval / LM Studio / Codex）

上記の操作は MCP tool として自然文プロンプトから呼べます（実体は `SourceVaultOOPS...` の thin wrapper）。MCP は cloud 到達し得るため **3 tool すべて `CloudSafe -> True` を常用**し、私的リストスレッドを返しません。

```text
sourcevault_oops_status                          → 冪等ロード＋状態（MailCount/SessionCount/…）
sourcevault_oops_search_threads {query, limit}   → スレッド検索（Session/Subject/Score/Snippet）
sourcevault_oops_thread {session}                → スレッド詳細（Digest/TopicLabels/…、私的は Released:false）

例）ユーザー: 「OOPS の転勤の話のスレッドを探して要点を教えて」
  → sourcevault_oops_search_threads {"query": "転勤"}       （私的スレッドは gate 済で出ない）
  → sourcevault_oops_thread {"session": "svmailsession:…"}  （公開スレッドの決定的 digest を要約）
```

負荷制御のため service カーネルでは既定で最新 1 ファイル（`$svOOPSMCPScope`）に絞ります。詳細は [`../api_mcp.md`](../api_mcp.md) の「OOPS メールスレッド検索ツール」節。

---

## クリーンアップ

引用・スレッド・グラフ・digest は読み取りと純関数で完結します。release context を登録した例 5–7 は末尾で登録解除しています。index / primer snapshot は content-addressed で `IndexId`/`PrimerId` をユニークにしているため、残っても無害（再実行で衝突しません）。

例 9 の `SourceVaultOOPSSearchThreads` は OOPS 検索の内部 release context `oops-corpus` / `oops-corpus-cloud` を登録します。これらは OOPS 検索インフラ本体（テスト用の使い捨てではない）なので**登録したまま**にします。
