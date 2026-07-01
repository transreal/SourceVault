# SourceVault 一般メール構造化 実装仕様 v0.1（§6.5 の seed-optional 拡張）

親仕様: [`sourcevault_search_foundation_implementation_spec_v1.md`](sourcevault_search_foundation_implementation_spec_v1.md) の **§6.5 Mail topic item graph**。
本仕様は §6.5 のメールモデル（返信 session／段落 topic item／topic item graph）を、**OOPS 以外の一般メール（`SourceVault_maildb` の univ 等）**に適用するための実装仕様である。§6.5 のデータモデル（`SourceVaultMailParagraphTopicItem` / `SourceVaultMailQuoteEdge` / `SourceVaultTopicItemGraph` / `SourceVaultMailSession`）はそのまま踏襲し、差分だけを定める。

**改訂履歴**:
- r1（2026-07-01）= レビュー `..._v0_1_review.md` 反映。P1（vocabulary privacy leak／r4 tag-DenyTags 配線／adapter gate shape／Counter 互換／session overmerge／fuzzy quote 候補制限／auto topic 冪等性）を取り込み、P2 と DoD を追加。中心方針: privacy / idempotency / session overmerge を topic 品質より先に潰す。
- r2（2026-07-01）= レビュー `..._v0_1_review_r2.md` 反映。**§6 を「Session 再構築」から「Mail relation graph mining」に昇格**し、正準構造を `SourceVaultMailRelationGraph`（typed directed multi-edge graph）、**session はその projection** に再定義。引用検出を **corpus 全体の quote/reference graph mining**（global fingerprint index ＋ local/global 二段 pass）として独立させ、**長距離・跨 session 引用（1年前の行事メール引用等）を `RelationRole` で区別して現 session に過剰 merge しない**。`Reply-To` と `In-Reply-To/References` の用語分離、nested/multi-source quote、quote fingerprint index の privacy/冪等、長距離引用の DoD を追加。
- r3（2026-07-01）= レビュー `..._v0_1_review_r3.md` 反映（実装前 sign-off ラウンド）。P1×5: **(1) vocab↔session の循環依存**を `GrowTopicVocabulary` の 2-pass（pass A=mail-level provisional／pass B=session-aware refine、`sessions` は opts、`SupportGroupingKind`）で解消、**(2) quote fingerprint を PrivacyScope ごと keyed HMAC/salt** 化・cross-scope 照合既定禁止・debug に生値を出さない、**(3) header token の degraded mode** ＋新規 import の token 生成 hook、**(4) source/query span の役割分離**（`SpanRole`、primary resolution=QuoteQuery→SourceProse）、**(5) `RelationRole` の v0.1 deterministic ルール**＋`RoleConfidence`/`RoleSource`。P2: edge 方向の明文化（citing→cited）＋reverse view、edge-kind別 `EvidenceKey`で `EdgeId` 一般化、global pass の budget/mode（LocalOnly/IndexBuildOnly/Full・`MiningSkippedReason`）、mining projection の incremental update key（`DirtyMailRefs`/`DirtySpanRefs`）。P3: 検索 ranking の `ReferenceIntent`。

---

## 0. 結論 / スコープ

現状、§6.5 の構造化は `SourceVault_oopsseed.wl` に **OOPS-seed 依存**で実装されている（OOPS mbox parse + `item-name.index` seed 辞書 + `quote-table.index`）。一般メール（maildb）には未適用で、maildb 側は per-mail の LLM 派生（Summary/Category/Priority）＋メタデータ索引しか持たない（`ThreadID -> Missing`、topic 層なし）。

本仕様のゴール:

1. **seed 非依存でも構築できる**構造化パイプライン。OOPS topic item が一切無くても、**メールコーパス自身からトピック語彙をブートストラップ**して、段落 topic 付与・topic item graph・session を作れる。
2. **OOPS seed が使えるなら再利用**（既存 topic item に attach）、**無い/カバー外なら新規 AutoExtracted topic item を作成して語彙を拡張**する。
3. maildb（暗号化 at-rest）から **release policy gate** を通して構造化し、**生成物（paragraph/topic/session/summary）と vocabulary label が privacy を継承・尊重**する。

非ゴール（本 v0.1）: LLM 提案 topic（`LLMProposed`）、Negotiation session の speech-act 判定、HTML DOM 段落正規化の高度化（§7.1 で `FlattenedHTML` 品質マークだけ付ける）。

---

## 1. 不変条件

### 1.1 seed-optional（最重要）
- 構造化の全段は **TopicVocabulary が空でも動く**。空語彙時は topic 層が「コーパス由来 AutoExtracted のみ」で構築される。
- OOPS seed の有無は **入力（vocab）** の違いだけで、コード経路を分岐させない。

### 1.2 Privacy / tag 配線（親仕様 r4 準拠）— **改訂**
親仕様 r4 は **object 側に `DenyTags` を置かず**、object の `Tags` に sensitivity（`PrivateML` / `ThirdPartyContent` / `NoCloudLLM` / `NoPublicExport` 等）を付け、**ReleaseContext 側の `DenyTags` が拒否する**設計。本仕様の生成物もこれに従う。

- **継承規則（明記）**: 構造化生成物（paragraph topic item / quote edge / topic node / session / session summary / auto vocab entry）は、supporting mail/paragraph の
  - `PrivacyLevel -> Max[...]`
  - `Tags -> Union[...]`
  を必ず持つ。
- **sensitivity は `Tags` に置く**（release policy が参照）。`AccessTags` は「認可済み scope filter 用の低漏洩 surface」で、sensitivity 判定には使わない（役割分離）。
- private / personal / third-party 検出時（private list、個人間通信、外部本文引用）は `Tags` に `ThirdPartyContent` / `NoCloudLLM` / `NoPublicExport` を入れる（既存 `iSVOOPSListPrivacy` / `SourceVaultMailRecipientPrivacy` を流用）。
- **regression（DoD）**: 構造化済み paragraph/topic/session が cloud LLM context / public export context で **Deny** になること。

### 1.3 語彙 privacy（P1: vocabulary が漏洩源になりうる）— **新設・改訂の核**
auto topic **label は本文由来の派生データ**である。private mail にだけ出る固有名・病名・住所・内部プロジェクト名などが `SurfaceIndex` / query expansion / live view label / GraphPlot に混ざると、**検索語彙そのものが情報漏洩源**になる。従って:

- auto topic item（vocab entry）は必ず `SupportRefs`（由来 paragraph/mail）、`SupportPrivacyMax`、`SupportTags`、`VisibilityPolicy` を持つ。
- `SourceVaultGrowTopicVocabulary` は **`PrivacyScope`（= release context）ごと**に構築する。**public/cloud scope の vocabulary に private support の label を入れない**（`SupportPrivacyMax` / `SupportTags` が scope の DenyTags/MaxPrivacyLevel を越える候補は除外）。
- `SurfaceIndex` を**検索・query expansion・label 表示・GraphPlot label に使う時も request-time gate** を通し、release context で越える topic label を落とす。
- 既定の `PrivacyScope` は最も保守的（owner-only, MaxPrivacyLevel 1.0）。cloud/export vocab は明示的に生成する。

### 1.4 語彙成長の安全性（自己増幅防止）
- AutoExtracted topic は **human confirm まで seed topic を上書きしない**（§6.5 step 7）。seed item と auto item は別 ref（`svtopic:oops:*` vs `svtopic:auto:*`）。
- 生成は **salience gate（§4.3）** でゲート（1 出現では topic 化しない、bounded growth）。§13 で述べる複合 support（distinct session/sender）を使う。

### 1.5 冪等性（P1: 再実行で重複生成しない）— **改訂**
- auto topic ref は **deterministic**: `owner + normalized-label + scope + ProfileDigest` から導出（sequential id を廃止）。support set 変化時は `SupersededBy` で version 管理。
- vocab は `VocabularyBuildId` / `ProfileDigest` / `ImportRunId` を持つ。
- session / relation edge も **deterministic id**。`EdgeId = Hash[ProfileDigest, FromMailRef, ToMailRef, EdgeKind, EvidenceKey]`（r3）。`EvidenceKey` は edge 種別ごと（header=MessageID/InReplyTo/References token、quote=QuoteSpanRef+SourceSpanRef+QuoteFingerprint、subject=normSubject+timeBucket+policyDigest、participant=participantSetDigest+policyDigest）。同一 mail pair に複数 quote span があっても span ごとに別 EdgeId になる。collision / supersede policy は `SourceVaultMiningProjection` が持つ（§6e）。

### 1.6 Backward compatibility
既存 `SourceVault_oopsseed.wl` の関数は API 破壊なしで再利用。一般化は**オプション追加**で行い、OOPS 経路の既定挙動は不変。

---

## 2. アーキテクチャ

```
maildb snapshot (encrypted)
   │  §5 adapter: SourceVaultMailSnapshotReleaseSource → release gate(Permit) → 復号 → normalize
   ▼   (Deny/復号失敗は Missing。低漏洩 metadata のみ残す)
generic mail record  <|MailRef, Subject, From, To, Date, Body(復号), PrivacyLevel, Tags,
                       ThreadHeaders(MsgId/InReplyTo/References token), ReplyToAddr, BodyWasHTML, LegacyCounterAlias|>
   │
   ├─▶ §6 Mail relation graph mining ── 正準構造 SourceVaultMailRelationGraph
   │      NormalizeMailText → BuildQuoteFingerprintIndex(PrivacyScope,永続) →
   │      GenerateQuoteCandidates(local pass ∪ global LSH pass) → ScoreQuoteCandidate →
   │      ResolveQuoteAmbiguity → BuildMailRelationGraph(typed directed multi-edge) →
   │      MineMailSessions(=graph の projection。RelationRole で継続 vs 参照を分離)
   │
   ├─▶ §4 TopicVocabulary (seed-optional, PrivacyScope 付き)
   │      ・empty | from-seed | seed+grown。§4.3 bootstrap は 2-pass(A=mail-level provisional / B=session-aware refine) + block filter + privacy 継承
   │
   ├─▶ §7 段落 topic 付与 (vocab match ∪ 語彙外 AutoExtracted。privacy 継承)
   │
   ├─▶ §8 topic item graph (SeedRelation + ObservedRelation + QuoteTransition/HistoricalReference/TemplateReuse。support privacy gate)
   │
   └─▶ §9 session chunk → BM25(+dense) projection / primer / digest / §9b live SearchView・annotation
```

中核は 2 つ: `TopicVocabulary`（§4、PrivacyScope 付き）と **`SourceVaultMailRelationGraph`（§6、typed multi-edge。session はその projection）**。quote mining と topic mining は同格の projection として `SourceVaultMiningProjection` に保存し再計算/supersede できる。

---

## 3. データモデル

### 3.1 Generic mail record（adapter 出力）— **改訂: 主キー MailRef ／ ThreadHeaders と Reply-To 分離**
```wl
<|
  "MailRef" -> "sv://mail/<recordId>",   (* 正準主キー。relation/quote edge はこれを使う *)
  "RecordId" -> "<maildb recordId>",
  "Subject" -> _String, "From" -> _String, "To" -> _String, "Cc" -> _String,
  "Date" -> _String,
  "Body" -> _String | Missing["BodyDecryptFailed"],   (* Permit 後のみ復号 *)
  "BodyWasHTML" -> True | False,
  (* ThreadHeaders = thread 同定の最高 confidence signal (§6-P1)。raw header が無ければ HMAC token *)
  "ThreadHeaders" -> <|"MessageIDToken" -> _String, "InReplyToToken" -> _ | Missing[],
                       "ReferencesTokens" -> {_...} |>,
  "ReplyToAddr" -> _String | Missing[],  (* Reply-To は返信先アドレスであって引用元同定に使わない。participant/ML signal 専用 *)
  "PrivacyLevel" -> _Real, "Tags" -> {_String...},     (* §1.2 継承 *)
  "LegacyCounterAlias" -> _Integer,                    (* 既存 oopsseed 関数互換の内部専用。外部 schema/persisted edge には出さない *)
  "SourceRef" -> <|"Kind" -> "MaildbSnapshot", "MBox" -> _, "ShardKey" -> _|>
|>
```
- **`Counter` は廃止**し `LegacyCounterAlias`（既存関数が整数キーを要求するための内部 alias）に降格。持続 edge・外部 schema には出さない。hash 整数化する場合は deterministic salt（`ProfileDigest` 由来）と collision table を持つ（§5）。
- **`Reply-To` と `In-Reply-To`/`References` を混同しない**（§6-P1）: thread 直接手がかりは `ThreadHeaders`（Message-ID/In-Reply-To/References）のみ。`Reply-To` は participant/address signal（ML アドレスなら mailing-list context signal）に降格し、**単独で reply edge を作らない**。

### 3.2 TopicVocabulary — **改訂: privacy/idempotency フィールド追加**
```wl
<|
  "ObjectClass" -> "SourceVaultTopicVocabulary",
  "VocabularyBuildId" -> "svvocab:<hash>",
  "ProfileDigest" -> "<正規化/抽出プロファイルの digest>",   (* 冪等性の基準 *)
  "PrivacyScope" -> <|"ReleaseContext" -> _, "MaxPrivacyLevel" -> _, "DenyTags" -> {...}|>,
  "Entries" -> { topicItem... },   (* 各 auto entry は下記 privacy フィールドを持つ *)
  "SurfaceIndex" -> <| surfaceForm -> {TopicItemRef...} |>,
  "SeedRelationGraph" -> <| ref -> {<|To,Weight,Direction|>...} |>,   (* seed 由来 *)
  "ObservedRelationGraph" -> <| ref -> {<|To,Weight,Confidence,EvidenceRefs,PrivacyMax|>...} |>,  (* コーパス由来。§8 *)
  "RefLabel" -> <| TopicItemRef -> CanonicalLabel |>,
  "Provenance" -> <|"SeedSource" -> _ | None, "GrownCount" -> _Integer, "ImportRunId" -> _|>
|>
```
auto topic item（entry）拡張:
```wl
<|
  "TopicItemRef" -> "svtopic:auto:<owner>:<normLabelHash>",   (* deterministic。§1.5 *)
  "CanonicalLabel" -> _, "SurfaceForms" -> {...},
  "NamespaceKind" -> "Extracted", "OwnerRef" -> _,
  "SupportRefs" -> {"svmailpara:...", "sv://mail/..."},
  "SupportPrivacyMax" -> _Real, "SupportTags" -> {...},
  "DistinctMails" -> _Integer, "DistinctSenders" -> _Integer,
  "DistinctPreliminaryThreads" -> _Integer, "DistinctSessions" -> _Integer | Missing[],  (* Session は pass B のみ *)
  "SupportGroupingKind" -> "Mail" | "PreliminaryThread" | "Session",   (* salience を満たした粒度。§4.3 *)
  "ReviewState" -> "Candidate" | "Confirmed" | "Merged" | "Split" | "Tombstoned",
  "VisibilityPolicy" -> <|"MaxPrivacyLevel" -> _, "DenyTags" -> {...}|>,
  "SupersededBy" -> _ | Missing[],
  "Provenance" -> <|"Source" -> "AutoExtracted", "ProfileDigest" -> _, "ImportRunId" -> _|>
|>
```

### 3.3 Mail relation graph（r2 新設・正準構造）
session は線形リストでなく、**typed directed multi-edge graph の projection** とする（§6-P1）。
```wl
<|
  "ObjectClass" -> "SourceVaultMailRelationGraph",
  "GraphId" -> "svmailrel:<hash>", "BuildId" -> _, "ProfileDigest" -> _, "ImportRunId" -> _,
  "PrivacyScope" -> <|"ReleaseContext" -> _, "MaxPrivacyLevel" -> _, "DenyTags" -> {...}|>,
  "Nodes" -> {"sv://mail/..."},
  "Edges" -> { SourceVaultMailRelationEdge... }
|>
```
```wl
(* SourceVaultMailRelationEdge: 1 つの mail pair に複数 edge 可 (edge ごとに種別/役割/confidence) *)
<|
  "ObjectClass" -> "SourceVaultMailRelationEdge",
  (* EdgeId = Hash[ProfileDigest, FromMailRef, ToMailRef, EdgeKind, EvidenceKey] (§1.5 冪等・r3 一般化) *)
  "EdgeId" -> "svrel:<deterministic hash>",
  (* 方向固定 (r3): From = relation を発生させた citing/reply/derived mail、To = cited/parent/source mail。
     すなわち矢印は「引用/返信している側 → 引用元/親」。時系列 forward 走査は §3.3 note の reverse view を使う *)
  "FromMailRef" -> "sv://mail/...", "ToMailRef" -> "sv://mail/...",
  "EdgeKind" -> "ReplyHeader" | "ReferenceHeader" | "QuoteExact" | "QuoteFuzzy" |
     "ForwardedMessage" | "SubjectFallback" | "ParticipantContinuation" |
     "EventReuse" | "ExternalCitation",
  (* EvidenceKey: EdgeId の材料。edge 種別ごとに定義 (r3)。header=MsgId/InReplyTo/RefTokens、
     quote=QuoteSpanRef+SourceSpanRef+QuoteFingerprint、subject=normSubject+timeBucket+policyDigest、
     participant=participantSetDigest+policyDigest *)
  "EvidenceKey" -> _String,
  (* RelationRole: 「同じ議論の継続」か「過去メールの参照」かを分ける (§6-P1)。session merge policy が使う。
     RoleConfidence は別フィールド、後で human/LLM review で上書き可 (§6c, r3) *)
  "RelationRole" -> "ThreadContinuation" | "EvidenceCitation" | "TemplateReuse" |
     "AnnualEventReuse" | "ForwardedContext" | "UnknownReference",
  "RoleConfidence" -> 0.0..1.0, "RoleSource" -> "Deterministic" | "Human" | "LLM",
  "Confidence" -> 0.0..1.0,
  "TemporalDistanceDays" -> _,                          (* Date 差。絶対 filter でなく feature (§6b) *)
  "CandidateGenerationPass" -> "Local" | "GlobalQuoteIndex" | "Header",
  "Matcher" -> _, "AmbiguityCount" -> _Integer,
  "FeatureScores" -> <|"TextOverlap" -> _, "LineOrder" -> _, "QuoteDepth" -> _,
     "TemporalDirection" -> _, "ParticipantRelation" -> _, "SubjectSimilarity" -> _,
     "MessageIdProximity" -> _, "BlockQuality" -> _|>,
  (* SpanRole (r3): source/query の役割分離。primary resolution は QuoteQuery -> SourceProse *)
  "SourceSpanRole" -> "SourceProse" | "QuoteQuery" | "ForwardedBlock" | "ReQuote",
  "MatchedSpanRefs" -> {"span:..."}, "EvidenceRefs" -> {...},
  "QuoteLineage" -> "Direct" | "ReQuote" | Missing[],   (* nested quote の直接/再引用 (§6c) *)
  "PrivacyLevel" -> _Real, "Tags" -> {...}              (* §1.2 継承 *)
|>
```
`MailSession` は relation graph の **clustering 結果**であり、edge を失わず `SessionGraphRef -> "svmailrel:..."` を持つ（§6d）。
**方向と走査（r3）**: edge の矢印は citing→cited 固定。時系列 forward（古→新）で辿るビューが要る箇所は `reverse edge view`（`TemporalFrom`/`TemporalTo` を Date 昇順に張り直したもの）を別途構築する。GraphPlot / notebook view は arrow の意味（引用→引用元）を legend に出す。

### 3.4 その他
`SourceVaultMailParagraphTopicItem` / `MailQuoteEdge` / `TopicItemGraph` / `MailSession` / `MailSessionSummary` は §6.5 スキーマ踏襲。ただし本仕様の継承規則（§1.2/§1.3）と id 冪等性（§1.5）を必須とし、quote/relation edge は §3.3 の拡張フィールドを持つ。`MailQuoteEdge` は `SourceVaultMailRelationEdge`（EdgeKind ∈ {QuoteExact, QuoteFuzzy}）の specialization とみなす。

---

## 4. TopicVocabulary（seed-optional 語彙）

### 4.1 生成
```wl
SourceVaultNewTopicVocabulary[opts___]                 (* 空。opts OwnerRef, PrivacyScope *)
SourceVaultTopicVocabularyFromSeed[dict_Association, opts___]   (* seed 再利用。opts SeedRelationGraph, SeedSource, PrivacyScope *)
```

### 4.2 冪等性（P1）
- 語彙は immutable value。auto topic ref は §1.5 の deterministic 導出。
- `ProfileDigest`（正規化・抽出プロファイル・stoplist・salience 閾値の digest）を持ち、**同一 profile + 同一 corpus → 同一 ref/label** を保証。profile 変化時は新 `VocabularyBuildId`。
- support set が変わっても label が同じなら同 ref を維持し `SupportRefs`/`SupportPrivacyMax` だけ更新。label が変わる merge/split は `SupersededBy` で版管理。

### 4.3 Bootstrap（コーパスからの語彙成長）＝ seed-optional の核 — **改訂（r3: 循環依存回避の 2-pass）**
```wl
SourceVaultGrowTopicVocabulary[vocab_, mails_List, opts___]  ->  vocab'   (* sessions は opts (r3) *)
```
**循環依存の解消（r3-P1）**: 語彙成長は session を要求し、session は relation graph mining（Inc 3）の結果である。よって Grow を明示的に 2 パスに分ける。`sessions_List` は必須引数でなく `"Sessions"` オプション（既定 `None`）。

- **pass A（provisional）**: seed/empty vocab ＋ **mail-level salience** で仮語彙を作る。support grouping は `DistinctMails`/`DistinctSenders`/`PreliminaryThreadGroups`（Subject 正規化 ∪ ThreadHeaders の軽量グルーピング。relation graph 不要）。Inc 1 で完結。
- **pass B（refined）**: Inc 3 の relation graph / sessions 構築後に `"Sessions" -> {...}` を渡し、**session-aware salience**（`DistinctSessions`）で語彙を refine / supersede（deterministic ref ゆえ pass A と同 label は同 ref を維持、閾値変化分だけ `SupersededBy`）。

手順（各パス共通）:
1. **候補 block filter（P2）**: 各メールを段落分割し、**quote / signature / footer / header / chat block を除外**。prose 段落のみを候補抽出対象にする。HTML 由来（`BodyWasHTML`）は `ParagraphQuality -> "FlattenedHTML"` として confidence を下げる。
2. 各 prose 段落から `SourceVaultExtractCandidateTopics`（`KnownSurfaceIndex = vocab["SurfaceIndex"]` で既知除外）。
3. **複合 support 集計（P2/P1.5）**: 単純出現数でなく、pass A は `DistinctMails`/`DistinctSenders`/`DistinctPreliminaryThreads`、pass B は `DistinctSessions`、＋ `ProseCount`・（任意）IDF・position salience を集計。**salience gate**: 使用中の grouping で `Distinct* >= *Min`（既定 2）等を満たすものを採用。
4. **privacy 継承（P1.3）**: 各候補に support paragraph の `PrivacyLevel` Max / `Tags` Union を付与。**現 `PrivacyScope` の MaxPrivacyLevel/DenyTags を越える候補は除外**（public/cloud vocab に private label を入れない）。
5. 採用候補を `SourceVaultConfirmCandidateTopics`（auto-confirm、**deterministic ref** = `svtopic:auto:<owner>:<normLabelHash>`）で auto topic item 化し、`SupportRefs`/`SupportPrivacyMax`/`SupportTags`/`SupportGroupingKind`/`ReviewState="Candidate"`/`VisibilityPolicy` を付けて Entries に merge。
6. `SurfaceIndex` 再構築 → vocab'。`Provenance.GrownCount += 採用数`、`ImportRunId` 記録。

各 entry の `SupportGroupingKind -> "Mail" | "PreliminaryThread" | "Session"`（どの粒度で salience を満たしたか）を持ち、pass B で昇格したら更新。

`opts`: `"ReleaseContext"`/`"PrivacyScope"`, `"Sessions"`(None), `"DistinctSessionMin"`(2)/`"DistinctMailMin"`(2)/`"DistinctThreadMin"`(2), `"MaxNewTopics"`(200), `"MaxTopicsPerSession"`, `"MaxTopicsPerSender"`, `"OwnerRef"`, `"Rounds"`(1), `"CandidateBlockFilters"`(既定 {Quote,Signature,Footer,Header,Chat}), `"Extractor"`(将来 LLM 差し替え点), `"Persist"`(§4.5)。

**評価 report（DoD）**: `rejected top candidates`（gate 落ち上位）と `SupportGroupingKind` 分布を返し stoplist 改善に使う。

### 4.4 収束
`Rounds` で複数パス。各パス末で新規追加が閾値未満なら早期終了。

### 4.5 永続 / 状態遷移（P1: open issue でなく v0.1 policy）
- confirmed auto topic は `SourceVaultSaveExtractedTopics`（既存）で WXF 永続し、次セッションで `LoadExtractedTopics` → `TopicVocabularyFromSeed` 相当で再利用（deterministic ref ゆえ再現）。
- 最小状態遷移: `Candidate -> Confirmed`（owner or auto-confirm）、`Confirmed -> Merged/Split`（label 統合/分割、`SupersededBy`）、`* -> Tombstoned`（撤回。SurfaceIndex から除外、ref は墓標として残す）。
- 永続は **PrivacyScope 単位**。cloud vocab の永続には private support label を含めない。

---

## 5. maildb アダプタ — **改訂: canonical gate source + fail-safe**

```wl
SourceVaultMailSnapshotReleaseSource[snap_Association] -> source     (* release policy 入力の canonical projection *)
SourceVaultMailToGenericRecord[snap_Association, opts___] -> §3.1 record | Missing["Gated"] | Missing["BodyDecryptFailed"]
SourceVaultMailRecordsForStructuring[opts___] -> {record...}
```
- **`SourceVaultMailSnapshotReleaseSource[snap]`**: `SourceVaultEvaluateReleasePolicy` に渡す canonical source。
  - `PrivacyLevel` = `snap["Derived"]["PrivacyLevel"]` が numeric ならそれ、**欠落/未生成なら `1.0`（fail-safe）**。
  - `Tags` = `Derived.AccessTags` / 旧 `Derived.DenyTags` を親仕様 r4 の `Tags`（sensitivity）へ**正規化**（`SourceVaultMailRecipientPrivacy` / list privacy の tag も union）。
  - `State`/`ValidFrom/Until` は Published 相当（maildb は保存済み）。
- **release gate**: `opts["ReleaseContext"]`（既定 `local-only`）で Permit のみ。**`local-only` は「全許可」ではなく MaxPrivacyLevel 1.0 かつ DenyTags を評価する release context**（cloud/export は別 context で私的除外）。Deny は `Missing["Gated"]`。
- **復号は Permit 後のみ**。`SourceVaultMailSnapshotDecryptBody` 失敗は `Missing["BodyDecryptFailed"]` として session/topic 生成から除外し、低漏洩 metadata（Subject/summary 等）だけ残す。
- `MailRef`/`RecordId` を正準に。`LegacyCounterAlias` は RecordId の deterministic hash（salt=ProfileDigest）＋ collision table（衝突時は連番 suffix、report に記録）。
- `InReplyToToken`/`ReferencesTokens`/`MessageIDToken`: snapshot が保持していれば正規化して載せる（§6）。**新規 fetch/import は raw header から `InReplyToToken`/`ReferencesTokens` を必ず生成する hook を通す**（r3-P1。既存 snapshot は degraded mode、§6b）。
- `MailRecordsForStructuring` opts: `"MBox"`, `"DateFrom"`/`"DateTo"`, `"ReleaseContext"`, `"Limit"`。

**Inc 2 完了条件（DoD）**: `InReplyToToken`/`ReferencesTokens`/`MessageIDToken` の **availability report**（保持率）を出す。閾値未満なら Header pass を **degraded mode** と明示し（§6b）、既存 corpus の backfill 可否を report。raw header を保存できない場合の HMAC token 方針（§6）を確定。

---

## 6. Mail relation graph mining（引用/参照検出）— **r2 で昇格**

引用/参照検出は session 再構築のサブルーチンではなく、**corpus 全体の quote/reference graph mining**（topic mining と同格の projection）。正準構造 `SourceVaultMailRelationGraph`（§3.3）を作り、session はその projection（§6d）。

### 6a. Mining pipeline（7 段）
```
1. NormalizeMailText     : 復号本文 → paragraph / quote block / signature / footer / forwarded block に分割
2. BuildQuoteFingerprintIndex : 各 span に SpanRole (SourceProse|QuoteQuery|ForwardedBlock|ReQuote) を付け (r3)、
                           line hash / shingle / simhash / MinHash signature を作る
                           (PrivacyScope ごと keyed HMAC・永続。§6e)
3. GenerateQuoteCandidates :  primary resolution は QuoteQuery -> SourceProse (r3)。
     LocalCandidatePass    : 近い thread / subject / participant / time window
     GlobalQuoteIndexPass  : LSH / hash match で **全 corpus** 探索 (長距離引用を落とさない)。budget 内 (§6f)
4. ScoreQuoteCandidate   : FeatureScores (§3.3) から confidence。TemporalDistance は feature (絶対 filter でない)。
                           QuoteQuery->QuoteQuery は ReQuote/ForwardedContext 候補として別扱い・低 confidence
5. ResolveQuoteAmbiguity : 同一 quote が複数候補に当たれば edge を複数保持しつつ primary を選ぶ。
                           高 AmbiguityCount edge は session merge に使わない
6. BuildMailRelationGraph : header / quote / subject / participant / event-reuse edge を typed multi-edge に統合。
                           各 edge に RelationRole + RoleConfidence を付与 (§6c の v0.1 ルール)
7. MineMailSessions      : relation graph の目的別 projection (thread view / event view / evidence view)。
                           session merge は direct SourceProse high-confidence + ThreadContinuation のみ
```

### 6b. Edge 生成規則（confidence 降順の signal）
- **ThreadHeaders**（`Message-ID`/`In-Reply-To`/`References` token グラフ）→ `ReplyHeader`/`ReferenceHeader`（最高 confidence。`CandidateGenerationPass -> "Header"`）。raw header 平文が無ければ HMAC token グラフ。**`Reply-To` は使わない**（§3.1）。
  - **degraded mode（r3-P1）**: 既存 snapshot は `MessageIDToken` はあっても `InReplyToToken`/`ReferencesTokens` を欠くことがある。availability が閾値未満の corpus では **Header pass を degraded mode と明示**し、`ReplyHeader` edge recall を評価から分離（§11 Inc 2 DoD）。`ReplyHeader` が張れない corpus では **SubjectFallback の promotion をさらに厳しく**し（quote/global pass の evidence が無い merge を抑制）、header 由来と quote 由来の session を report で区別。新規 fetch/import は raw header から `InReplyToToken`/`ReferencesTokens` を必ず生成する hook を通す（§5）。backfill 可否は Inc 2 で report。
- **Quote**（§6a の 2-pass）→ `QuoteExact`/`QuoteFuzzy`。**候補生成は local pass ∪ global LSH pass の二段**で、`Date < reply date`・same account 等は **scoring feature**（絶対 filter にしない）。未来日/TZ 誤差/転送/取り込み逆順は `TemporalAnomaly` として扱い、`MaxQuoteLookbackDays` は無制限/大きな既定（**1 年前の行事メール引用を落とさない**）。
- **Forwarded**（転送ブロック）→ `ForwardedMessage`。
- **Subject fallback（過結合防止・P1r1）**: 同一 subject を**単独では連結しない**。date window ∩ participant overlap ∩ (mbox | quote 一致 | 本文類似) を複数満たす場合のみ `SubjectFallback` + 低 confidence。汎用 subject stoplist（`会議`/`確認`/`資料`/`よろしくお願いします`/空 等）は対象外。max cluster size + time-gap split。
- **Participant continuation** → `ParticipantContinuation`（弱 signal）。

### 6c. RelationRole（「継続」か「参照」か）— **r2 の核**
1 つの引用 edge が「同じ議論 session の継続」か「過去メールの参照」かを分ける:
- `ThreadContinuation`（進行中スレッド）／ `EvidenceCitation`（根拠として過去メール引用）／ `TemplateReuse`（雛形流用）／ `AnnualEventReuse`（毎年の行事メール流用）／ `ForwardedContext`／ `UnknownReference`。
- **v0.1 deterministic 判定ルール（r3-P1、上から順に最初に成立したもの）**:
  1. `ReplyHeader`/`ReferenceHeader` かつ TemporalDistance が過大でない（既定 ≤ `MaxContinuationGapDays`）→ **`ThreadContinuation`**。
  2. direct quote（`QuoteLineage=Direct` の `SourceProse` match）かつ「same normalized subject / strong participant overlap / short temporal distance」の**複数成立** → **`ThreadContinuation`**。
  3. `ForwardedBlock` 由来 → **`ForwardedContext`**。
  4. yearly date pattern（約 1 年差）∨ event-title similarity → **`AnnualEventReuse`**。
  5. TemporalDistance 大 ∨ subject 変化 ∨ participant overlap 弱 ∨ 長い過去本文断片の引用 → **`EvidenceCitation`**。
  6. AmbiguityCount 高 → **`UnknownReference`**。
  7. 雛形句が支配的（定型文 stoplist 一致率高） → **`TemplateReuse`**。
- 判定は決定論だが、`RoleConfidence` を別フィールドに持ち（`RoleSource="Deterministic"`）、後で human/LLM review が `RoleSource="Human"|"LLM"` で上書き可能。閾値（`MaxContinuationGapDays` 等）は §13 open issue で較正。
- **nested / multi-source quote**（§3.3 `QuoteLineage`）: 1 quote block から複数 `SourceVaultMailRelationEdge` を張れる（`>` 深さ・`On ... wrote:`・転送ブロックで境界判定）。direct quote は強く、re-quote/forwarded は低 confidence（§6a step 4）。

### 6d. Session = relation graph の projection
`MineMailSessions` は relation graph を clustering:
- **`ThreadContinuation`（ReplyHeader/ReferenceHeader/direct QuoteExact）を強 edge に session を作る**。
- **`EvidenceCitation`/`TemplateReuse`/`AnnualEventReuse` は session merge に使わず、cross-session reference edge として残す**（過去メールを引用しても現交渉 session に過剰 merge しない）。
- 高 AmbiguityCount / 低 confidence edge は merge に使わない。
- `MailSession` は `SessionGraphRef` を持ち edge を失わない。summary は current session の結論と historical reference を分けて表示（§9）。

### 6e. Quote fingerprint index の privacy / 冪等（P2, r3 強化）
- fingerprint も本文由来の派生情報 → **`PrivacyScope` ごと構築**。raw quote text は保存せず normalized signature / span ref のみ。短すぎる line・固有名だけの line は永続対象外。
- **keyed / scope-salted signature（r3-P1）**: 生の normalized hash を**そのまま永続しない**。fingerprint は **`PrivacyScope` ごとの keyed HMAC / salt** で作る。安定 hash を複数 scope で共有すると private/public 間で存在連結が起きるため、**cross-scope matching は既定禁止**。owner-only scope 内でのみ global match し、public/cloud scope はその scope に許された span だけで index を作る。
- `QuoteFingerprintProfileDigest` に **normalization profile / shingle size / HMAC key id / salt id / scope id** を含める（scope/key を変えれば別 index）。
- candidate の表示・GraphPlot label・Notebook view は support privacy gate（§1.3）。**debug report でも fingerprint 値そのものは出さず**、候補件数・confidence・span refs のみ返す。
- `QuoteIndexBuildId` / `ProfileDigest` / `ImportRunId` を持ち、再構築で edge が重複しない（deterministic EdgeId、§3.3）。
- **mining projection の incremental update（r3-P2）**: `SourceVaultMiningProjection` は `CorpusSnapshotId` / `MailSetDigest` / `QuoteIndexBuildId` / `DirtyMailRefs` / `DirtySpanRefs` を持つ。
  - 新規メール追加時は、**新規 mail の quote span を既存 source index に照合**（既存 mail が新規 mail の source になる場合も拾う）。**既存 mail 同士の edge は原則再計算しない**。
  - `normalization/profile 変更時のみ full rebuild`。full rebuild と incremental の結果差分を report。
  - collision / supersede policy（同一 EdgeId 再出現・label merge/split）を projection が保持。

### 6f. 実装の切り方（既存関数との関係）＋ budget
Inc 3 は「`BuildMailQuoteEdges` にオプション追加」ではなく **`SourceVaultBuildMailRelationGraph`（mining projection）として新設**する。最小実装は LocalCandidatePass から始めてよいが、**API と schema は global quote index / 長距離 quote / cross-session reference を受けられる形**にしておく。既存 `BuildMailQuoteEdges`/`BuildMailSessions` は relation graph 構築の下請けとして再利用（`ReplyHeaders`/`SubjectFallbackPolicy` オプション追加）。OOPS 経路の既定は不変。

**計算 budget / mode（r3-P2）**: runaway 防止に v0.1 で以下を既定に持つ:
- `MaxGlobalCandidatesPerQuote`・`MaxQuoteBlocksPerMail`・`MinQuoteChars`・`MinShingles`・`MaxAmbiguityForMerge`。
- budget 超過時は `CandidateGenerationPass -> "GlobalQuoteIndex"` の edge を**作らず**、`MiningSkippedReason -> "BudgetExceeded"` を report に残す（silent truncation にしない）。
- 明示 mode: **`"QuotePass" -> "LocalOnly"`**（local pass だけで動く。最小実装既定）／**`"QuotePass" -> "IndexBuildOnly"`**（global index 構築のみ・edge は張らない）／`"Full"`。

---

## 7. 段落 topic 付与（seed-optional）

### 7.1 段落分割
既存 `SourceVaultParseMailParagraphs`（空行区切り／Quote/Signature/Footer 分離）。一般メールは OOPS マーカーを持たないので strip 無効で動く。`BodyWasHTML` の本文は `ParagraphQuality -> "FlattenedHTML"`（table/list-heavy は topic assignment confidence を下げる）。DOM parser は後続（BodyRaw 再構築/supersede policy は将来）。

### 7.2 付与
`SourceVaultAssignParagraphTopics[paragraphs, vocab["SurfaceIndex"], opts]`（既存）。§6.5 順（明示→seed/vocab match→relation 1-hop→語彙外 AutoExtracted）。§4.3 で語彙成長させた後は繰り返し語が vocab に居るので SeedMatched 側に載る。付与結果の paragraph topic item は §1.2/§1.3 の privacy を継承。

### 7.3 owner / privacy
auto topic は current owner namespace。confidence は既存設計踏襲。**paragraph topic item / 付与ラベルの表示・展開は §1.3 の request-time gate を通す。**

---

## 8. topic item graph — **改訂: ObservedRelationGraph**

既存 `SourceVaultBuildTopicItemGraph[mails, opts]` を relation graph（§6）駆動で使う。
- edge 種: `CoParagraph` / `SeedRelation`（`SeedRelationGraph`）／ **relation graph の RelationRole を topic transition に写像**（r2）:
  - `ThreadContinuation` の quote edge → `QuoteTransition`（強）
  - `EvidenceCitation`/`AnnualEventReuse` → **`HistoricalReferenceTransition`**（過去参照。current topic cluster に強 merge しない）
  - `TemplateReuse` → **`TemplateReuseTransition`**
- **quote edge の confidence が低い場合は topic relation boost も bounded**（低 confidence 引用が topic を過剰結合しない）。
- **`ObservedRelationGraph`（P2）**: auto topic 間の上記 transition から `confidence`/`evidence refs`/`PrivacyMax` 付きで構築し vocab に格納。query expansion では seed より低重み・再検索候補に使える。**support privacy で gate**（§1.3）。
- 既存 `"MaxTopicsPerMailForQuote"` 剪定を踏襲。

---

## 9. 検索 / primer への接続

既存資産を vocab 経由で再利用: `BuildSessionChunks`（`SurfaceIndex -> vocab`）→ `BuildProjectionIndex`（KeywordBM25V1、`EntityDictionary -> vocab dict`）→ 任意 DenseV1/HybridSearch → `BuildSessionPrimerItems`（digest）。privacy: chunk/primer は §1.2 継承 PrivacyLevel、cloud gate は release context（`oops-corpus-cloud` と同型の一般メール版）。

**session summary は current session の結論と historical reference を分離する（r2）**: `BuildSessionDigest` / primer は relation graph の RelationRole を尊重し、`ThreadContinuation` で結ばれたメール群を「現行の議論・結論」として要約し、`EvidenceCitation`/`AnnualEventReuse`/`TemplateReuse` で参照された過去メールは `HistoricalReferences`（別フィールド）として「根拠・前例・テンプレート」に分けて列挙する。過去参照を current session の結論本文に混ぜて要約しない（overmerge した要約 = 誤った結論の温床）。primer/検索 view でも両者は別セクション。

**検索 ranking での historical reference の扱い（r3-P3）**: `SearchContextProfile` に `ReferenceIntent -> CurrentConclusion | HistoricalEvidence | TemplateReuse` を追加。
- query が「経緯／前回／去年／同じ行事／根拠／引用元」等を含む → `HistoricalReferences` を上げる。
- 「結論／最新／次にすること」等 → current session を上げ、historical reference は根拠セクションに留める。
- 既定は `CurrentConclusion`（意図が曖昧なら現行議論優先、過去参照は evidence として下段表示）。

### 9b. Live SearchView / annotation branch（P2）
親仕様の `SourceVaultSearchView` / `LiveNotebookHypertext` / `ContextSubgraphNotebook` / `SourceVaultTopicItemInteractionEvent` / `SourceVaultGraphAnnotation` に接続:
- `SourceVaultBuildSearchView[..., "Corpus" -> "MailStructure"]` 連携（一般メール構造化結果を live view として返す）。
- session / topic graph / quote edge から `ContextSubgraphNotebook` を作れること（DoD）。
- `Viewed`/`FollowedLink`/`Cited`/`Annotated` を mail topic graph の meta-layer に反映（interaction event）。
- `SourceVaultAppendGraphAnnotation` で session summary / paragraph topic / quote edge に追記。**すべて §1.3 の request-time gate 下で。**

---

## 10. Public API

```wl
(* 語彙 (PrivacyScope 付き) *)
SourceVaultNewTopicVocabulary[opts___]
SourceVaultTopicVocabularyFromSeed[dict_, opts___]
SourceVaultGrowTopicVocabulary[vocab_, mails_List, opts___]   (* sessions は opts "Sessions"。pass A=mail-level / pass B=session-aware (§4.3) *)

(* maildb アダプタ *)
SourceVaultMailSnapshotReleaseSource[snap_]
SourceVaultMailToGenericRecord[snap_, opts___]
SourceVaultMailRecordsForStructuring[opts___]

(* Mail relation graph mining (§6。quote/reference graph) *)
SourceVaultBuildQuoteFingerprintIndex[mails_List, opts___]      (* PrivacyScope・永続。§6e *)
SourceVaultBuildMailRelationGraph[mails_List, opts___]          (* typed multi-edge。opts QuoteIndex, LocalOnly, MaxQuoteLookbackDays *)
SourceVaultMineMailSessions[relationGraph_, opts___]            (* graph projection。RelationRole で継続/参照分離 *)

(* 統合 *)
SourceVaultStructureMail[mails_List, opts___] ->
   <|"Vocabulary", "RelationGraph", "Sessions", "TopicGraph", "ParagraphTopics", "Report"|>
   (* opts Seed(dict|None), Grow(True), Quote(Local|Global), ReplyHeaders, ReleaseContext, PrivacyScope *)

(* ユーティリティ + live view *)
SourceVaultMailStructureEnsureLoaded[opts___]
SourceVaultMailStructureSearchThreads[query, opts___]
SourceVaultMailStructureThread[sessionId, opts___]
SourceVaultMailStructureSearchView[query, opts___]   (* §9b。BuildSearchView 連携 *)
```

---

## 11. 増分計画 + acceptance tests（DoD）

- **Inc 1: TopicVocabulary（seed-optional, pass A）** — New/FromSeed/Grow（**pass A = mail-level salience、sessions は opts で未指定**、§4.3）。**DoD**: (a) seed なし合成 corpus で同一語が複数メール（`DistinctMails`/`PreliminaryThread`）で同じ auto topic ref、(b) 一回性語は topic 化しない、(c) 再実行で ref/label 重複生成なし（deterministic）、(d) private support の label が public/cloud PrivacyScope の vocab に入らない、(e) 各 entry に `SupportGroupingKind` が付く。
- **Inc 2: maildb アダプタ + release source** — `SnapshotReleaseSource`/`ToGenericRecord`/`RecordsForStructuring`。**DoD**: (a) Deny/復号失敗が Missing で除外され低漏洩 metadata が残る、(b) `PrivacyLevel` 欠落時 1.0 fail-safe、(c) header token availability report、(d) 実 univ 1 シャードで privacy 継承・冪等 MailRef、(e) **token availability が閾値未満なら Header pass を degraded mode と明示し `ReplyHeader` recall を分離**、backfill 可否と新規 import の token 生成 hook を report（r3-P1）。
- **Inc 3: Mail relation graph mining（§6）** — `BuildQuoteFingerprintIndex`（PrivacyScope）/`BuildMailRelationGraph`（typed multi-edge、local+global pass、RelationRole）/`MineMailSessions`（projection）。既存 `BuildMailQuoteEdges`/`BuildMailSessions` は下請け（ReplyHeaders/SubjectFallbackPolicy 追加）。**DoD**: (a) `InReplyTo/References` 付き合成 corpus で session recall ≥ 閾値、(b) same-subject unrelated mails が巨大 session にならない（overmerge 防止）、(c) fuzzy quote が短文/署名/footer で edge を作らない、(d) **1 年前の行事メール引用で `AnnualEventReuse`/`EvidenceCitation` の historical reference edge が張られ、current session に過剰 merge されず cross-session reference として残る**、(e) subject/participants が変わっても十分長い quote 断片から元メール候補を発見（global pass）、(f) 複数候補に当たる定型文引用は `AmbiguityCount` が上がり session merge に使われない、(g) nested quote で `QuoteLineage` の direct/requote が区別される、(h) 再実行で edge/session 重複なし（deterministic EdgeId・edge-kind別 EvidenceKey）、(i) **quote fingerprint が PrivacyScope ごと keyed HMAC で、cross-scope match が起きない・debug report に fingerprint 値が出ない**（r3-P1）、(j) `RelationRole` が §6c の deterministic ルールで付き `RoleConfidence`/`RoleSource` を持つ、(k) global pass の budget 超過が `MiningSkippedReason` で report される。最小実装は LocalCandidatePass のみ稼働可（global pass は index 構築のみ先行、§6f）。**pass B（session-aware vocab refine, §4.3）は本 Inc の relation graph/session を入力に走らせ、pass A 語彙を supersede しても deterministic ref が保たれること**を確認。
- **Inc 4: 段落 topic 付与 + topic graph** — `StructureMail` 配線、ObservedRelationGraph。**DoD**: seed 無し/有り両方で paragraph topic・graph が繋がり、cloud context で private topic node が Deny。
- **Inc 5: 検索/primer + live SearchView + annotation** — ユーティリティ、`MailStructureSearchView`。**DoD**: 実 univ で「スレッド検索」end-to-end、`ContextSubgraphNotebook`/link follow/annotation が interaction event になる。
- **Inc 6（任意）**: LLMProposed topic、Negotiation session、HTML DOM parser。

検証は [[verify-loop-workflow]]（.wl は Claude 編集→ユーザー NB 検証、FE 依存部は NB）。**実装順序（r1 方針）: privacy / idempotency / session overmerge を topic 品質より先に潰す。** 最初は合成 corpus + 小 `univ` subset。

---

## 12. 既存資産の再利用 / 一般化

| 既存関数（oopsseed.wl） | 再利用 | 一般化（オプション追加） |
|---|---|---|
| `ParseMailParagraphs` | そのまま | `ParagraphQuality`（FlattenedHTML）付与 |
| `ExtractCandidateTopics`/`ConfirmCandidateTopics` | §4.3 語彙成長 | deterministic ref・support privacy・block filter は §4.3/§5 の呼び側で付与 |
| `BuildSurfaceIndex` | vocab SurfaceIndex | — |
| `AssignParagraphTopics` | 段落付与 | 既存オプションで足りる |
| `BuildMailSessions` | `MineMailSessions` の下請け | **`SubjectFallbackPolicy`/`ReplyHeaders` 追加、RelationRole を尊重（historical reference を merge しない）** |
| `BuildMailQuoteEdges` | `BuildMailRelationGraph` の local quote 下請け | **`FuzzyQuote`/`ReplyHeaders` 追加（候補制限・二段階照合・ambiguity）。global pass は §6e の新規 index が担う** |
| `BuildTopicItemGraph` | topic graph | ObservedRelationGraph 出力 |
| `BuildSessionChunks`/`BuildSessionPrimerItems`/`BuildSessionDigest` | 検索/primer | `SurfaceIndex -> vocab`、historical reference を current session と分離表示（§9） |
| `SaveExtractedTopics`/`LoadExtractedTopics` | §4.5 永続 | PrivacyScope 単位 |

**新規実装**: TopicVocabulary 3 関数（§4、privacy/idempotency 込み）、maildb アダプタ 3 関数（§5、canonical gate source）、**Mail relation graph mining 3 関数**（§6: `BuildQuoteFingerprintIndex`／`BuildMailRelationGraph`（typed multi-edge・local+global pass・RelationRole）／`MineMailSessions`（projection））、`ObservedRelationGraph`（§8）、統合 `StructureMail` ＋ ユーティリティ＋SearchView 連携（§9b/§10）。既存 `BuildMailQuoteEdges`/`BuildMailSessions` は下請けに降格し、canonical 構造は `SourceVaultMailRelationGraph`。

---

## 13. 残オープン issue（r2 後）

1. **複合 support の閾値**（DistinctSessionMin=2 等）と position/IDF salience の重みは実 univ で要調整。rejected-candidate report で反復調整。
2. **auto topic の owner namespace のマルチ owner 化**（現 v0.1 は single owner）。
3. maildb の raw header 保持が無い環境での **HMAC token graph の完全性**（token 衝突・privacy）。degraded mode と新規 import hook は §6b/§5 で規定済み、残るは **availability 閾値の較正と既存 corpus backfill 運用**。Inc 2 availability report 後に確定。
4. **ObservedRelationGraph の cross-session 集約と減衰**（自己増幅・古さ扱い）。親仕様の rollup/importance と整合させる。
5. **seed↔auto の label 衝突**（同一 label が seed と auto に出る）: 別 topic 維持を既定とし、live view で soft-merge 表示するかは §9b で別途。
6. **（r2）global quote index の scale/LSH パラメータ**（shingle 幅・simhash bit・MinHash band/row・候補上限）は実 univ で要調整。最小実装は local pass のみ稼働・global pass は index 構築だけ先行し、閾値は held-out quote pair で較正。
7. **（r2/r3）RelationRole 判定の閾値較正**: v0.1 deterministic ルール（§6c）は確定。残るは `MaxContinuationGapDays`・約 1 年差の許容幅・participant overlap 閾値等の**値の較正**と、role ごとの precision/recall 監視。誤って historical を継続と判定すると overmerge、逆は session 断片化。
8. **（r2/r3）mining projection の incremental update**: key（`CorpusSnapshotId`/`MailSetDigest`/`DirtyMailRefs`/`DirtySpanRefs`）と「新規 mail span を既存 source index に照合・既存同士は非再計算・profile 変更時のみ full rebuild」は §6e で確定。残るは **full rebuild トリガの閾値**（corpus 規模変化）と incremental/full 差分の許容範囲を Inc 3 実測後に確定。
9. **（r2）nested / multi-source quote の source 帰属**: `QuoteLineage` で直接引用と再引用を区別するが、複数候補に同程度当たる場合の primary 選択と、direct/requote の confidence 減衰係数は実データで較正。
10. **（r3）quote fingerprint の HMAC key/salt 管理**: scope ごと keyed HMAC（§6e）の key id/salt id の保管・rotation・cross-scope 照合の明示的許可フロー（owner が意図的に private↔public を突き合わせたい場合）を後続で定義。
11. **（r3）ReferenceIntent 分類の精度**: query の「経緯/去年/根拠」等から `CurrentConclusion`/`HistoricalEvidence`/`TemplateReuse` を推定するルール（§9）の語彙・精度は実クエリで較正。誤分類時は current session 優先の保守側に倒す。
