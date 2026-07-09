---

# SourceVault 一般メール構造化・検索 使用例 — maildb → session / topic / digest

SourceVault の **一般メール構造化層**（`SourceVault_mailstructure.wl`）の使用例集です。OOPS 以外の一般メール（`SourceVault_maildb` の univ 受信箱等）を、**OOPS シードが無くても** 返信/引用 session・段落 topic・topic graph に構造化し、スレッド検索・要約（digest）・分析につなげます。中核は seed-optional な `TopicVocabulary` と、引用/参照を typed graph として掘る **mail relation graph mining** です。

- OOPS メール（seed 辞書・quote-table あり）の構造化は [`mail_structuring_example.md`](mail_structuring_example.md)
- OOPS 非依存の検索基盤（BM25 / release gate / primer / KG）は [`search_foundation_example.md`](search_foundation_example.md)
- 構造化した session/topic を土台にした **新着取得・返信下書き** は姉妹モジュール `SourceVault_mailsuggest.wl`（`SourceVaultMailFetchNew` / `SourceVaultMailComposeReply`）。本構造化層の出力（session・topic・digest）を入力に使うため、まず本ドキュメントの構造化を通します。
- 関数仕様は [`../api_mailstructure.md`](../api_mailstructure.md) / [`../api_searchview.md`](../api_searchview.md)

構成は 4 部です。

1. **[0. 実運用シナリオ](#0-実運用シナリオ--mcp-ツールから引く)** — MCP ツール `sourcevault_mail_*` からの検索・digest 取得。
2. **[基本編](#基本編)** — 実 univ シャードのロード → adapter → `SourceVaultStructureMail` 一発構造化。合成コーパスで中身（RelationRole・topic graph）を観察。
3. **[中級編](#中級編)** — スレッド検索（BM25）、current/historical を分離した session digest、私的メールの cloud-safe 二重防御。
4. **[応用編](#応用編)** — 語彙 tuning（`VocabOptions`）、agentic/cascade 検索接続（§7）、HTML 本文・交渉スレッド判定・LLM 提案トピック（Inc 6）。

---

## 事前準備

`$packageDirectory` は init ファイルで定義済みとします（参照のみ）。

```mathematica
Block[{$CharacterEncoding = "UTF-8"}, Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]]
```

> **実データ例（univ シャード）の前提**: maildb の snapshot store と復号鍵が要るため **FE（ノートブック）カーネル**で実行し、**必ず先に `SourceVaultMailEnsureLoaded["univ", "202606"]` でシャードをロード**してください（未ロードだと `SourceVaultMailSnapshotList[]` が空 → records 0 件 → 全て 0 件になります）。「期待される出力例」の実データ部分は univ/202606（299 通、うち 100 通処理）の実測値です。
> **合成コーパス例**はどのカーネルでも動きます（store・鍵不要）。

---

# 0. 実運用シナリオ — MCP ツールから引く

ふだんの入口は **LLM（ClaudeEval / Claude Code / LM Studio / Codex）が MCP ツールを呼ぶ経路**です。一般メール用に 3 ツールがあります（すべて cloud-safe: 私的/第三者メールは gate されます）。

```text
ClaudeEval["大学メールで Zoom 関連のスレッドを探して"]
```

LLM が発行するツール呼び出し:

```json
{ "name": "sourcevault_mail_search_threads",
  "arguments": { "query": "Zoom", "limit": 5 } }
```

3 ツールの役割:

| ツール | 役割 | 実体 |
|---|---|---|
| `sourcevault_mail_status` | scope（`$svMailStructMCPScope`、既定 `{"univ","202606"}`）をロード→構造化→索引 build（冪等）し状態を返す | `SourceVaultMailStructEnsureIndex` |
| `sourcevault_mail_search_threads` | query → `{Session, Subject, Score, Snippet}` | `SourceVaultMailStructSearchThreads` |
| `sourcevault_mail_thread` | session id → **current/historical 分離 digest**。私的 session は `Released:false` | `SourceVaultMailStructThread` |

ツールと等価な Wolfram 呼び出し（dispatch 経由）は次のとおりで、中級編の関数がそのまま裏で動きます:

```mathematica
SourceVaultMCPCallTool["sourcevault_mail_status", <||>]
SourceVaultMCPCallTool["sourcevault_mail_search_threads", <|"query" -> "Zoom", "limit" -> 5|>]
SourceVaultMCPCallTool["sourcevault_mail_thread", <|"session" -> "svmailsess:..."|>]
```

> 初回の `sourcevault_mail_status` は service カーネルで `SourceVaultMailEnsureLoaded` を伴うため maildb store / 鍵に依存します。scope を変えるには service カーネルで `SourceVault`$svMailStructMCPScope = {"<mbox>", "<yyyymm>"}` を設定し `SourceVaultMailStructEnsureIndex["Rebuild" -> True]`。

---

# 基本編

## 例 1: 実 univ シャードのロード → generic record → header 可用性

maildb snapshot を release gate（Permit のみ）→ 復号 → §3.1 generic record に変換します。復号失敗メールは `Body -> Missing["BodyDecryptFailed"]` で低漏洩 metadata だけ残ります。

```mathematica
SourceVaultMailEnsureLoaded["univ", "202606"]
recs = SourceVaultMailRecordsForStructuring["MBox" -> "univ", "Limit" -> 100];
SourceVaultMailStructHeaderAvailability[SourceVaultMailSnapshotList[]]
```

**期待される出力例（実測）:**

```
<|"Status" -> "Ensured", "MBox" -> "univ", "Period" -> "202606", "Shards" -> 1,
  "NewlyLoaded" -> 299, "InMemory" -> 299|>

<|"Total" -> 299,
  "MessageIDToken"  -> <|"Count" -> 0, "Fraction" -> 0.|>,
  "InReplyToToken"  -> <|"Count" -> 0, "Fraction" -> 0.|>,
  "ReferencesTokens" -> <|"Count" -> 0, "Fraction" -> 0.|>,
  "Threshold" -> 0.5, "HeaderPassMode" -> "Degraded",
  "Note" -> "InReplyTo/References token 保持率が閾値未満。Header pass は degraded: ..."|>
```

`HeaderPassMode -> "Degraded"` は「返信ヘッダの token graph が使えない corpus」という報告です。**degraded でも session は引用（quote fingerprint）と厳格 subject fallback で形成されます**（例 2）。

## 例 2: `SourceVaultStructureMail` — 一発構造化（実 univ）

語彙成長（pass A）→ relation graph + session mining → session-aware 語彙 refine（pass B）→ 段落 topic 付与 → topic graph、を 1 呼び出しで行います。

```mathematica
st = SourceVaultStructureMail[recs, "OwnerRef" -> "owner:imai", "QuotePass" -> "Full"];
st["Report"]
Counts[#["Kind"] & /@ Flatten[Values[st["TopicGraph"]]]]
```

**期待される出力例（実測）:**

```
<|"MailCount" -> 100, "VocabSize" -> 400, "RelationEdges" -> 149,
  "SessionCount" -> 73, "TopicGraphEdges" -> 3056, "AssignedMails" -> 98|>

<|"QuoteTransition" -> 984, "HistoricalReferenceTransition" -> 359, "CoParagraph" -> 1713|>
```

header が完全 degraded な実データでも 100 通 → 73 session に集約され、topic transition 3 種（引用継続 / 過去参照 / 共起）がすべて機能しています。段落 topic の例:

```mathematica
rl = st["Vocabulary"]["RefLabel"];
Take[Select[Normal[#["TopicRefs"] & /@ st["ParagraphTopics"]], Last[#] =!= {} &], UpTo[2]] /.
  r_String :> Lookup[rl, r, r]
```

```
{"sv://mail/svmail-54ca…" -> {"Katsunobu", "サインイン", "Zoom", "デバイス", "Imai", ...},
 "sv://mail/svmail-f00b…" -> {"アカウント", "Katsunobu", "パスワード", "fukuyama-u", ...}}
```

## 例 3: 合成コーパスで中身を観察 — RelationRole と過剰マージ防止

どのカーネルでも動く自己完結例です。**1 年前の行事メールを引用したメール（a2→a1）が「過去参照」（`AnnualEventReuse`）として区別され、現 session にマージされない**こと、引用継続（k2→k1）が topic graph の `QuoteTransition` になることを見ます。

```mathematica
mk[ref_, subj_, from_, to_, date_, body_] := <|"MailRef" -> ref, "Subject" -> subj,
  "From" -> from, "To" -> to, "Cc" -> "", "Date" -> date, "Body" -> body, "BodyWasHTML" -> False,
  "ThreadHeaders" -> <|"MessageIDToken" -> Missing[], "InReplyToToken" -> Missing[], "ReferencesTokens" -> {}|>,
  "ReplyToAddr" -> Missing[], "PrivacyLevel" -> 0.3, "Tags" -> {},
  "SourceRef" -> <|"Kind" -> "MaildbSnapshot", "MBox" -> "demo"|>|>;

demoMails = {
  mk["sv://mail/k1", "予算相談",     "a@example.com", "b@example.com", "2026-05-01",
     "予算計画の件でご相談です\n\n詳細は後日お送りします。"],
  mk["sv://mail/k2", "Re: 予算相談", "b@example.com", "a@example.com", "2026-05-02",
     ">予算計画の件でご相談です\n\n会場手配も並行して進めています。"],
  mk["sv://mail/k3", "予算報告",     "a@example.com", "c@example.com", "2026-05-03",
     "予算計画は承認されました。ご報告まで。"],
  mk["sv://mail/k4", "会場について", "b@example.com", "c@example.com", "2026-05-04",
     "会場手配の担当を決めます。候補を確認中。"],
  mk["sv://mail/a1", "運動会について",   "x@example.com", "y@example.com", "2025-05-10",
     "運動会の案内です。\n\n今年の運動会は10月に体育館前に集合ABCDEF\n\n準備をお願いします。"],
  mk["sv://mail/a2", "来年度の行事予定", "x@example.com", "y@example.com", "2026-05-12",
     ">今年の運動会は10月に体育館前に集合ABCDEF\n\n来年度もこの案内を流用します。"]};

stDemo = SourceVaultStructureMail[demoMails, "OwnerRef" -> "owner:imai", "QuotePass" -> "Full"];
rl = stDemo["Vocabulary"]["RefLabel"]; lb[x_] := Lookup[rl, x, x];
<|"vocab" -> (#["CanonicalLabel"] & /@ stDemo["Vocabulary"]["Dictionary"]["Entries"]),
  "roleDist" -> Counts[#["RelationRole"] & /@ stDemo["RelationGraph"]["Edges"]],
  "sessions" -> (Sort[#["MailRefs"]] & /@ stDemo["Sessions"]),
  "transitions" -> (lb[#["From"]] <> " -[" <> #["Kind"] <> "]-> " <> lb[#["To"]] & /@
     Flatten[Values[stDemo["TopicGraph"]]])|>
```

**期待される出力例:**

```
<|"vocab" -> {"会場手配", "予算計画"},
  "roleDist" -> <|"ThreadContinuation" -> 1, "AnnualEventReuse" -> 1|>,
  "sessions" -> {{"sv://mail/k1", "sv://mail/k2"}, {"sv://mail/a1"}, {"sv://mail/k4"},
                 {"sv://mail/a2"}, {"sv://mail/k3"}},
  "transitions" -> {"会場手配 -[QuoteTransition]-> 予算計画"}|>
```

読みどころ:

- **語彙は seed 無しで corpus から成長**（2 通以上で支持された「予算計画」「会場手配」だけが topic。一回性の語は入らない）。
- k2 は k1 を引用 → `ThreadContinuation` → **同一 session** `{k1, k2}`。
- a2 は 1 年前の a1 を引用 → **`AnnualEventReuse`**（決定論 RelationRole）→ session は**別のまま**（過剰マージ防止）。参照は失われず session の `CrossSessionReferences` に残ります。
- 引用でつながったメールの topic 間に `QuoteTransition`（bounded weight）が張られます。

---

# 中級編

## 例 4: スレッド検索 — session chunk → BM25 index → release-gate 付き検索

session 単位の chunk（privacy は record 継承・topic enrichment 注入）から `KeywordBM25V1` projection index を作り検索します。

```mathematica
idxDemo = SourceVaultMailStructBuildSearchIndex[stDemo];   (* 既定 ReleaseContext: mailstruct-local *)
hits = SourceVaultMailStructSearch["予算計画", idxDemo, "Limit" -> 3];
<|"Title" -> #["Citation"]["Title"], "Score" -> Round[#["Score"], 0.01]|> & /@ hits
```

**期待される出力例:**

```
{<|"Title" -> "予算報告", "Score" -> 9.04|>,
 <|"Title" -> "予算相談", "Score" -> 8.22|>,
 <|"Title" -> "来年度の行事予定", "Score" -> 0.19|>}
```

実 univ（例 2 の `st`）でも同様に:

```mathematica
idx = SourceVaultMailStructBuildSearchIndex[st];
res = SourceVaultMailStructSearch["Zoom", idx, "Limit" -> 5];
#["Citation"]["Title"] & /@ res
```

**期待される出力例（実測）:**

```
{"Re: zoom", "いよいよ明日！Zoom Phoneひとつで実現するコスト削減と業務効率化",
 "アカウントにサインインするためのパスキーを追加しました。",
 "新しいZoomサインインが検出されました", "Zoomにサインインするためのコード"}
```

## 例 5: session digest — current と historical の分離

digest は relation graph の RelationRole を尊重し、**現行スレッドの timeline（CurrentDigest）と過去参照（HistoricalReferences）を混ぜません**。例 3 の a2 session:

```mathematica
sessA2 = SelectFirst[stDemo["Sessions"], MemberQ[#["MailRefs"], "sv://mail/a2"] &];
SourceVaultMailStructSessionDigest[sessA2, stDemo]
```

**期待される出力例:**

```
<|"Subject" -> "来年度の行事予定", "MailCount" -> 1,
  "CurrentDigest" -> "[スレッド] 来年度の行事予定 (1通)\nx@example.com: 来年度もこの案内を流用します。",
  "HistoricalReferences" -> {<|"Role" -> "AnnualEventReuse", "ToMailRef" -> "sv://mail/a1",
     "Subject" -> "運動会について", "Excerpt" -> "運動会の案内です。", "ToSession" -> 2|>}, ...|>
```

実 univ での実測例（放送大学教材スレッド）では、`CurrentDigest` が現スレッドの per-mail timeline、`HistoricalReferences` に `{Role: EvidenceCitation, Excerpt: "共著者の今井先生からさらに訂正箇所の指摘がありました。", ToSession: 12}` と `{Role: ForwardedContext, ToSession: 68}` が分離されました — **過去メールの引用が「根拠」「転送文脈」として別 session への参照になり、現行の結論に混ざりません**。

```mathematica
h = Select[st["Sessions"], #["CrossSessionReferences"] =!= {} &];
SourceVaultMailStructSessionDigest[First[h], st]
```

## 例 6: 私的メールの cloud-safe 二重防御

`ThirdPartyContent`/`NoCloudLLM` 等の tag や高 PrivacyLevel を持つメールは、(1) cloud index の build-time gate で chunk ごと除外され検索でヒットせず、(2) session id を直接指定しても digest が出ません。

```mathematica
mkP[ref_, subj_, date_, body_, tags_, pl_] :=
  Append[mk[ref, subj, "a@example.com", "b@example.com", date, body],
    <|"Tags" -> tags, "PrivacyLevel" -> pl|>];
pMails = {
  mkP["sv://mail/pub1", "公開案件", "2026-05-01",
      "公開プロジェクトベータの進捗を共有します。ベータ計画を進めます。", {}, 0.3],
  mkP["sv://mail/prv1", "機密案件", "2026-05-03",
      "機密プロジェクトガンマの詳細。関係者限り。", {"ThirdPartyContent", "NoCloudLLM"}, 0.9]};
cloudScope = <|"ReleaseContext" -> "mailstruct-cloud", "MaxPrivacyLevel" -> 1.0,
  "DenyTags" -> {"NoCloudLLM", "NoPublicExport", "PrivateML", "ThirdPartyContent"}|>;

stP = SourceVaultStructureMail[pMails, "PrivacyScope" -> cloudScope, "QuotePass" -> "Full",
  "OwnerRef" -> "owner:imai"];
idxP = SourceVaultMailStructBuildSearchIndex[stP, "ReleaseContext" -> "mailstruct-cloud"];
SourceVaultMailStructSetIndex[stP, idxP];   (* MCP domain の cache に載せる *)

{KeyTake[idxP, {"ChunkCount", "ExcludedCount"}],
 Length @ SourceVaultMailStructSearchThreads["ベータ"],
 Length @ SourceVaultMailStructSearchThreads["ガンマ"],
 KeyTake[SourceVaultMailStructThread[
    SelectFirst[stP["Sessions"], MemberQ[#["MailRefs"], "sv://mail/prv1"] &]["MailSessionId"]],
   {"Subject", "Released", "Why"}]}
```

**期待される出力例:**

```
{<|"ChunkCount" -> 1, "ExcludedCount" -> 1|>,   (* 機密 session は index から除外 *)
 1,                                             (* 「ベータ」(公開) → 1 件ヒット *)
 0,                                             (* 「ガンマ」(機密) → 0 件 *)
 <|"Subject" -> "機密案件", "Released" -> False, "Why" -> {"PrivateMail"}|>}
```

---

# 応用編

## 例 7: 語彙の tuning — `VocabOptions`

pass A/B の語彙成長には汎用語 stoplist と遍在語除外（`MaxDocFreqFraction`）が入っていますが、`VocabSize` は `MaxNewTopics`（1 pass 200）× 2 pass = **最大 400 で頭打ち**になります。絞るには `VocabOptions` を渡します:

```mathematica
stS = SourceVaultStructureMail[recs, "OwnerRef" -> "owner:imai",
  "VocabOptions" -> {"MaxNewTopics" -> 120, "MaxDocFreqFraction" -> 0.3, "DistinctMailMin" -> 3}];
stS["Report"]["VocabSize"]
Take[#["CanonicalLabel"] & /@ stS["Vocabulary"]["Dictionary"]["Entries"], UpTo[20]]
```

**期待される出力例（実測）:**

```
240

{"Cerezo", "情報工学科", "リマインダ", "ログイン", "コース", "福山大学", "課題",
 "レポート", "工学部", "コースニュース", "広島県福山市", "コンピュータグラフィックス",
 "モデリング", "就職情報", "AI", ...}
```

学科・大学・課題・CG など**実質的なトピックが中心**になります（`詳細`/`送信`/`通知`/`reminder` 等の mail-mechanics 語は bilingual stoplist が除去。閾値は corpus 固有なので `MaxDocFreqFraction`/`DistinctMailMin`/`TopicStoplist` で調整）。

## 例 8: agentic / cascade 検索への接続（§7）

一般メール index は検索基盤の agentic 層（[`../api_searchview.md`](../api_searchview.md)）からそのまま使えます。`SourceVaultCascadeSearch` は query の複雑さで dispatch します: **Simple → BM25 直接／Complex（なぜ・経緯・根拠…）→ agentic ループ**（deterministic follow-up・episode 記録・SearchView 構築）。

```mathematica
csS = SourceVaultCascadeSearch["予算計画", "ReleaseContext" -> "mailstruct-local",
  "Index" -> idxDemo["IndexId"], "MinGroundedEvidence" -> 1, "RecordEpisode" -> False];
csC = SourceVaultCascadeSearch["なぜ予算計画が承認された経緯", "ReleaseContext" -> "mailstruct-local",
  "Index" -> idxDemo["IndexId"], "MinGroundedEvidence" -> 1, "RecordEpisode" -> False];
{csS["Complexity"], csS["Trace"]["Dispatch"], csC["Complexity"], csC["Stopped"]}
```

**期待される出力例:**

```
{"Simple", "BM25", "Complex", "EnoughEvidence"}
```

> `RecordEpisode -> True`（既定）なら探索が retrieval episode（高機密行動ログ）として記録され、`SourceVaultSearchEpisodeMemory` が次回の query 拡張候補を返します。live view（`SourceVaultBuildSearchView`）にもこの index を渡せます。

## 例 9: Inc 6 — HTML 本文・交渉スレッド判定・LLM 提案トピック

**(a) HTML 本文の構造的段落分割**（`BodyWasHTML` メール向け。blockquote は `Kind -> "Quote"`、entity 復号）:

```mathematica
SourceVaultParseHTMLMailParagraphs[
  "<p>ご確認ください。</p><blockquote>元の提案です&amp;詳細</blockquote><div>了解です<br>進めます</div>"]
```

```
{<|"Kind" -> "Prose", "Text" -> "ご確認ください。", "Index" -> 1, ...|>,
 <|"Kind" -> "Quote", "Text" -> "元の提案です&詳細", "Index" -> 2, ...|>,
 <|"Kind" -> "Prose", "Text" -> "了解です 進めます", "Index" -> 3, ...|>}
```

**(b) 交渉（日程調整）スレッドの speech-act 判定**（提案＋承諾/却下 → Negotiation、resolution = 最後の承諾メール）:

```mathematica
nrec = {mk["sv://mail/n1", "日程", "a@example.com", "b@example.com", "2026-05-01",
          "来週の会議はいかがでしょうか。候補は月曜です。"],
        mk["sv://mail/n2", "Re: 日程", "b@example.com", "a@example.com", "2026-05-02",
          "承知しました。月曜でお願いします。"]};
SourceVaultClassifyMailSessionKind[<|"MailRefs" -> {"sv://mail/n1", "sv://mail/n2"}|>, nrec]
```

```
<|"SessionKind" -> "Negotiation", "IsNegotiation" -> True,
  "ResolutionMailRef" -> "sv://mail/n2", "ResolutionDate" -> "2026-05-02", ...|>
```

`ResolutionDate` は SearchContextProfile の `FindNegotiationOutcome`（`MailSessionResolutionDate`）に対応する「結論の日付」です。

**(c) LLM 提案トピック**（`queryFn` は外部注入。決定論抽出の代わりに `GrowTopicVocabulary` の `"Extractor"` へ渡せます）:

```mathematica
mockQ = Function[prompt, "プロジェクトアルファ\n量子コンピュータ\n詳細\n- 深層学習\n"];
SourceVaultLLMProposeTopics["本文サンプル", mockQ]
```

```
{<|"Surface" -> "プロジェクトアルファ", "ExtractionKind" -> "LLMProposed"|>,
 <|"Surface" -> "量子コンピュータ", "ExtractionKind" -> "LLMProposed"|>,
 <|"Surface" -> "深層学習", "ExtractionKind" -> "LLMProposed"|>}
```

（`詳細` は stoplist で除外、箇条書き記号は剥がされます。）実運用では `mockQ` を LM Studio / Claude 呼び出しに差し替え:

```mathematica
extractor = Function[{body, known, limit},
  SourceVaultLLMProposeTopics[body, myLLMQueryFn, "MaxTopics" -> limit, "KnownSurfaceIndex" -> known]];
vLLM = SourceVaultGrowTopicVocabulary[SourceVaultNewTopicVocabulary[], mails,
  "Extractor" -> extractor, "CandidateSource" -> "LLMProposed", "OwnerRef" -> "owner:imai"];
```

提案トピックは `Provenance.Source -> "LLMProposed"`・`ReviewState -> "Candidate"` で決定論抽出と区別され、human 確認前提で扱えます。

---

## 全体像（maildb → 検索/digest の流れ）

```
maildb snapshot ─▶ SourceVaultMailRecordsForStructuring   (release gate → 復号 → generic record)
                       │
        SourceVaultStructureMail ──▶ <|Vocabulary, RelationGraph, Sessions, TopicGraph, ParagraphTopics|>
          │  pass A 語彙 → relation graph mining (RelationRole: 継続 vs 過去参照)
          │  → session projection → pass B 語彙 refine → 段落 topic → topic graph
                       │
   SourceVaultMailStructBuildSearchIndex ─▶ KeywordBM25V1 index (session chunk, privacy 継承)
                       │
   ┌───────────────────┼──────────────────────┐
   ▼                   ▼                      ▼
 MailStructSearch   MailStructSessionDigest   CascadeSearch / BuildSearchView (§7/§6.8)
 (スレッド検索)      (current/historical 分離)  (agentic 検索・live view)
                       │
   MCP: sourcevault_mail_status / _search_threads / _thread   (cloud-safe 二重防御)
                       │
   下流: SourceVault_mailsuggest.wl (SourceVaultMailFetchNew / SourceVaultMailComposeReply)
         ── 本層の session/topic/digest を土台に新着取得・返信下書きを生成
```

> **姉妹モジュール `SourceVault_mailsuggest.wl`**: 本構造化層の出力（session・topic・digest）を入力に、新着メールの取得（`SourceVaultMailFetchNew`）と返信下書きの生成（`SourceVaultMailComposeReply`）を担います。構造化を前提に動くため、本ドキュメントのフロー（構造化 → index / digest）を先に通してから利用します。このモジュールは常時ロード（auto-trigger catalog に登録済み）で、SourceVault ロード時に自動で使えます。

参照: [../api_mailstructure.md](../api_mailstructure.md)（本層の全 API）/ [../api_searchview.md](../api_searchview.md)（SearchView / episode / context profile / agentic）/ [../api_searchindex.md](../api_searchindex.md)（BM25 / release gate）。