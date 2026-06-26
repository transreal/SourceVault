# SourceVault マイニング / MetacognitiveAssessment 拡張 — メール・web 実装解説

作成日: 2026-06-24
対象: SourceVault（Mathematica / Wolfram Language）
依拠仕様:
- `ドキュメント/sourcevault_llmwiki_datastore_requirements_draft.md`（データストア・正準モデル）
- `ドキュメント/sourcevault_self_organizing_mining_identity_tag_spec_v0_1.md`（マイニング / identity / tag / 記憶代謝）
- Yona, Geva, Matias, "Hallucinations Undermine Trust; Metacognition is a Way Forward", arXiv:2605.01428v1

目的: 本拡張を実装したとき、**メールと web データを SourceVault で扱う流れがどこでどう変わるか**を、現行実装の事実に基づいて解説する。実装前の確認用ドキュメント。

---

## 0. 要約

本拡張は「取り込み → 保存」だった流れの間に **3 つの新しい層**を差し込み、保存側に正準テーブルを追加する。

1. **SecurityPreScan 関門** — LLM に渡す前の deterministic 検査（`SourceVault_mining.wl` に実装済み。web 経路では配線済み、**メール派生経路は未配線**）。
2. **MetacognitiveAssessment 関門**（新規）— 「自分はどれだけ確かか」を測り、search / hedge / ask user / defer を制御。確信が低ければ確定せず hypothesis として保存。
3. **ObjectInteractions / ObjectSignals 層**（新規）— owner と LLM が「どれだけ触れ・重要視したか」を正準イベント化。

非対称性: **web は安全性・参照・重要度の機構が既にあり**、今回は著者抽出・自動タグ・semantic 検索・認知層が主な追加。**メールは raw header・配送異常・既読/重要度・pre-scan の本配線・認知層**が大きく増える。

---

## 1. パイプライン全体像

```
① 取り込み → ② 安全 pre-scan[関門] → ③ LLM 要約/抽出 → ④ Metacognition[関門] → ⑤ identity/tag → ⑥ 保存・検索・利用
```

| ステージ | メール | web |
|---|---|---|
| ① 取り込み | ＋新規: raw header・配送観測 | ✓既存: fetch→clean→blob |
| ② 安全 pre-scan | ⚠要配線: derive 前に挿入 | ✓既存: pipeline 配線済 |
| ③ LLM 要約/抽出 | ⟳統合: 外部 text を data 境界化 | ＋新規: 著者抽出 schema/XMP |
| ④ Metacognition | ＋新規: 送信者・添付の確信度 | ＋新規: 出典・読了の確信度 |
| ⑤ identity / tag | ⟳統合: delivery feature 追加 | ＋新規: TopicTag 自動・著者 link |
| ⑥ 保存・検索・利用 | ＋新規: 既読・重要度・日本語 lexical | ⟳統合: 参照 → ObjectSignals 合流 |

凡例: ＋新規 / ⟳統合（既存だが挙動変更）/ ✓既存 / ⚠要配線

---

## 2. 追加・正準化されるテーブル

### 新規

| テーブル | 役割 |
|---|---|
| `MailHeaders` | raw RFC5322 header 全体・重複順序つき header fields |
| `MailDeliveryObservations` | Received chain / relay 国・ASN / `DeliveryAnomalyScore` / `BenignExceptionHypotheses` |
| `MetacognitiveAssessment` | faithful uncertainty（intrinsic / expressed / FaithfulnessGap）と search/defer 制御。`MiningObject` の projection |
| `SecurityAssessment` | pre-scan / risk 伝播の正準。`MiningObject` の projection |
| `ObjectInteractions` / `ObjectSignals` | owner/LLM の参照・既読・重要度・pin/dismiss（イベント正準 + projection）|
| 配送 baseline（private profile） | `AccessLevel -> 1.0`、ローカル暗号化。Dropbox 平文に出さない |
| `MemoryVitalityScores`（MA 品質列） | `MetacognitiveFaithfulnessScore`（cMFG 近似）/ `UncertaintyDiscrimination`（AUROC 近似）|

### 既存 → 正準化（`SourceVault_mining.wl` に実装済み）

`SecurityPreScan` / `TagAssertion` / `AuthorshipAssertion` / `EntityLinkProposal` / `DiagnosticProbe` / `ProbeRun` / `ErrorBookEntry`、および web の reference event / importance / priority。

---

## 3. メール: before → after

### 3.1 取り込み（ingest）

| | 現状 | 拡張後 |
|---|---|---|
| metadata | From/To/Cc/Subject/Date 等（`MailMetadataPublic`）+ maildb 由来 Authentication-Results をパースした DKIM/SPF/DMARC/ARC | **+ `MailHeaders`**（raw RFC5322 全体）。From/Received/DKIM-Signature/References の順序・重複が evidence |
| 配送経路 | cloud origin フラグ程度。Received chain は**未保存** | **+ `MailDeliveryObservations`**（hop 数・relay 国/ASN・`DeliveryAnomalyScore`・benign exception）|
| baseline | なし | **private operational profile**（`AccessLevel 1.0`、ローカル暗号化）。ログには hash と coarse score のみ |

→ 「同じ送信者の一通だけ未知 ASN・海外 IP・DMARC 弱」を異常検出。ただし spoofing と断定せず hypothesis として保持。

関連既存関数: `SourceVaultMailFetchNew`（IMAP）, `SourceVaultMailSnapshotFromMaildb`, `SourceVaultSenderAuthentication`（DKIM/SPF/DMARC/ARC パース・authserv-id pinning は実装済み）。

### 3.2 安全性（最も大きく変わる）

- 現状: 要約生成 `SourceVaultMailInferDerived` は body をそのまま LM Studio に渡す。**pre-scan を通っていない**。
- 拡張後: subject/body/添付 OCR を要約・著者抽出に渡す前に**必ず `SourceVaultSecurityPreScan`**。結果を `SecurityAssessment`（MiningObject）に保存し `SafetyState` / `TextTrustState` を mail projection に surface。**添付の risk が高ければ親メールへ伝播**。`quarantined` は LLM mining から除外。
- → 主な配線作業（§5）。

### 3.3 認知（MetacognitiveAssessment）— 新規

要約・締切抽出・送信者同定の前後で評価し、確信が低ければ自動確定しない。

- この送信者は AddressBook / Identity / DKIM-DMARC からどれだけ確からしいか
- 添付や OCR を**読まずに**判断していないか（`EvidenceSufficiency` 低）
- delivery anomaly があれば `UncertaintyKind -> {"Epistemic"}` + `ConflictWithRetrievedEvidence -> True`、`RecommendedAction -> AskUser`（delivery 側に `verifySender` / `inspectHeaders`）

→ 低確信の要約は確定 fact でなく hypothesis として保存し、後日 DKIM / 追加メールで再評価。

### 3.4 既読・重要度 — 新規

- 現状: **既読/未読フラグも refcount も無い**（IMAP `\Seen` も未取得）。
- 拡張後: `MarkRead` / `MarkUnread` / `Open` を `ObjectInteractions` として正準化、`ObjectSignals` に `OwnerReadState` / `OwnerRefCount` / `OwnerImportance`。検索 ranking に bounded boost（owner 明示 > LLM）。
- ⚠ 仕様は「既存 maildb 既読フラグから migration」と書くが、現状その元フラグが無い。実装時は IMAP `\Seen` を新規取得するか、read-state をゼロから開始すると判断する。

### 3.5 検索

- 現状: `SourceVaultSearchMailSnapshots` は `StringContainsQ` の部分一致（lexical index なし）。`SourceVaultMailSearchIndex` は sidecar `.svmailidx` だが述語は同じく部分一致。
- 拡張後: 日本語 multi-channel lexical（Subject / Summary / FromDisplay / かな / ローマ字 / Compound / n-gram）+ hybrid ranking。件名の短文・固有名詞・略称に強くなる。既存部分一致は fallback として残す。

### 3.6 identity / privacy

- identity 二層・`SenderAuthentication`・`EntityLinkProposal` は**既存**。差分は delivery feature（`MailDeliveryAnomalyScore` / `UnexpectedRelayASN`）を `FeatureVector` に足すこと。
- privacy: `Derived.PrivacyLevel`（既定 0.85）を維持しつつ `AccessLevel` 0–1 に統一。delivery baseline は `AccessLevel 1.0` private profile に隔離。

---

## 4. web: before → after

### 4.1 取り込み・著者

- 取り込み本体（`SourceVaultWebFetch`: fetch → clean text → blob → immutable snapshot → provenance）は**現状維持**。
- **新規**: web ページ著者（schema.org / rel=author / PDF XMP / arXiv API）を `Identifier` + `AuthorshipAssertion` として観測し `EntityLinkProposal` を作る。現状は Eagle の `Authors` 文字列を denormalize するのみ（web HTML メタ抽出は未実装）。
- ⚠ web/PDF metadata の author は偽装可能。`MetadataTrustClass` を付け、DMARC pass の mail sender と同列にしない。

### 4.2 タグ

- 現状: Eagle imported tag のみ（`SourceKind -> "Imported"`）。
- 拡張後: 本文 / title / abstract から TopicTag を**自動マイニング**（`SourceKind -> "Mining"`, `NeedsHumanReview`）。AccessTag は tightening のみ自動。

### 4.3 検索

- 現状: legacy PDFIndex adapter の keyword 検索のみ。embedding / semantic・chunking **未実装**。
- 拡張後: 日本語 lexical + **bge-m3 ローカル embedding の hybrid**、構造＋日本語境界を意識した chunking、`EmbeddingMetadata` / `TokenizationMetadata` を保存して再現可能に。

### 4.4 安全性 — ほぼ現状維持＋正準化

- web は**すでに `SourceVaultRunMiningPipeline` で pre-scan を配線済み**（`SourceVaultSafetyQuarantinedQ` で gate）。今回は結果を `SecurityAssessment`（MiningObject）として正準保存し、cross-object contamination / 伝播を足す程度。メールより進んでいる。

### 4.5 参照・重要度 — 統合される

- web は**すでに** reference event / recency decay（`SourceVaultRecordImportance`）/ rollup（`SourceVaultRollupReferenceEvents`）/ `SourceVaultWebComputePriority` / domain weight を持つ（メールより先行）。
- 拡張後: これらを `ObjectInteractions` / `ObjectSignals` の統一モデルに合流。`SearchClickCount` / `LLMRefCount`（context-include / cite）/ `LLMUsefulCount` / `PinState` を追加し `EffectiveImportance` に集約。web priority は維持しつつこの層に吸収。

### 4.6 認知（MetacognitiveAssessment）— 新規

web / PDF / arXiv の要約・claim で:「著者は本文由来か metadata 由来か LLM 由来か」「引用・関連論文を**実際に読んだか**、title/abstract だけか」「既存 claim / entity と矛盾しないか」「OCR 品質や chunk 境界が低く読めたつもりになっていないか」→ 不足なら `Search` / `ReadMore` / `CreateProbe` / `Defer`、十分なら通常通り MiningObject / TagAssertion / AuthorshipAssertion へ投影。

---

## 5. メール派生経路の配線（pre-scan / Metacognition gate）

### 5.1 BEFORE（現状）

```
① SourceVaultMailFetchNew
   → ② SourceVaultMailSnapshotFromMaildb
   → ③ iSVDerivePrompt（raw body 同梱）
   → ④ SourceVaultMailInferDerived → LM Studio
   → ⑤ SourceVaultMailSnapshotPut（Derived 確定）

✗ raw body が pre-scan なしで LLM へ
✗ 確信度評価なし＝要約をそのまま確定
✗ 既読・重要度なし
```

### 5.2 AFTER（拡張後）

```
① SourceVaultMailFetchNew（+ raw header / Received）
   → ② SourceVaultMailSnapshotFromMaildb（+ MailHeaders / MailDeliveryObservations）
   → ③ [関門] SourceVaultSecurityPreScan(body, 添付OCR) → SecurityAssessment
          └─ SourceVaultSafetyQuarantinedQ?  ── quarantined → LLM 派生を除外、lexical 表示のみ（警告付）
   → ④ iSVDerivePrompt（data-boundary 包囲：外部 text を data block 化）
   → ⑤ SourceVaultMailInferDerived（tool-less）
   → ⑥ [関門] SourceVaultAssessUncertainty / SourceVaultAddMetacognitiveAssessment
          └─ 低確信 / ConfidentErrorRisk 高 → 要約を hypothesis 保存、RecommendedAction = AskUser / verifySender（自動確定しない）
   → ⑦ SourceVaultMailSnapshotPut（Derived）
        + MiningObjectAdded（Security / Metacognitive）
        + ObjectInteractions（MarkRead 等）
```

### 5.3 配線の要点

- **差し込み位置は ② と ③ の間**。`iSVDerivePrompt` が raw body を直接 prompt に載せている手前に `SourceVaultSecurityPreScan`（実装済み）を挟む。
- **③ pre-scan は LLM 不使用の deterministic 関門**なので `SourceVaultMailInferDerived` の前に同期実行できる。`quarantined` なら LLM 派生をスキップし `DerivedStatus` を pending のまま残す運用に乗せやすい。
- **④⑤ は既存関数の挙動変更**：本文を data block として境界化し、tool/MCP を渡さない（external-origin の命令を instruction 化しない）。新関数は不要で、prompt 組み立てと LLM 呼び出しオプションの変更で済む。
- **⑥ Metacognition は新規関門**（MiningObject wrapper）。`IntrinsicUncertainty` は LM Studio の logprob / self-consistency が取れなければ `Missing` とし、`EvidenceSufficiency`（添付を読んだか・delivery anomaly）を主ゲートに degrade。
- **⑦ 保存は追加のみ**：既存 `SourceVaultMailSnapshotPut` に `MiningObjectAdded`（Security / Metacognitive）と `ObjectInteractions` を同一 event transaction で append。既存 snapshot スキーマは壊さない。

---

## 6. 横断的不変条件（メール・web 共通）

1. external-origin text は `SafetyState -> active` でも**全 LLM stage で data boundary 化**。本文中の命令を instruction として実行しない。
2. deterministic pre-scan の risk を **LLM 判定で下げられない**（下げるには human review）。
3. importance / refcount は **AccessLevel / SafetyState / DenyTag を緩めない**。owner 明示 > LLM、LLM 自己増幅は bounded。
4. 確定 entity link / tag は event-sourced で観測・候補・確定を分離（auto-confirm 既定 off）。
5. faithful uncertainty は**内部状態との一致**であって外部証拠の十分性ではない（arXiv:2605.01428）。`IntrinsicUncertainty` は self-consistency から、`EvidenceSufficiency` とは独立に算出。
6. 「今は不確か（候補 / 仮説 / 要検索 / 要人間確認 / source conflict）」を**正準状態として保存**し、後日 evidence で再評価。

---

## 7. 実装インパクト / 移行手順（既存を壊さない）

既存の maildb snapshot / web snapshot / identity 二層 / reference event は**そのまま**。追加分は event + projection で重ねる。

| 優先 | 作業 | 場所 |
|---|---|---|
| 高 | mail derive 経路に pre-scan gate を挿入（現状バイパス） | `SourceVaultMailInferDerived` 前段（`SourceVault_maildb.wl`）|
| 高 | `MailHeaders` / `MailDeliveryObservations` の取り込み | IMAP fetch で raw header / Received chain を保持。legacy 分は header 不在のため新規取得分から |
| 中 | read-state を IMAP `\Seen` から `ObjectInteractions` 化 | maildb fetch + `ObjectInteractions` |
| 中 | web 著者抽出と TopicTag 自動マイニングを stage 追加 | mining pipeline |
| 中 | web reference event → `ObjectInteractions` / `ObjectSignals` 統合 | `SourceVault_webingest.wl` の importance/priority を合流 |
| 中 | `MetacognitiveAssessment` を MiningObject wrapper として ingest / reasoning-retrieval に付与 | mining / orchestrator |
| 低〜中 | 検索を部分一致 / PDFIndex から日本語 lexical + bge-m3 hybrid へ | mail/web 共通 `AnalyzerProfile` |

最小の実装単位は「② snapshot の後に pre-scan gate を 1 つ挟む」こと。⑥⑦（認知層・ObjectInteractions）は段階的に足せる。

---

## 8. 注意点

- **read-state の migration 元が無い**: 仕様は既存 maildb 既読フラグからの projection を想定するが、現状フラグが存在しない。IMAP `\Seen` の新規取得か、ゼロ開始を選ぶ。
- **IntrinsicUncertainty の取得性**: cloud Claude では logprobs 不可、self-consistency はコスト増。取得不能時は `Missing` とし `EvidenceSufficiency` 主ゲートに degrade。self-consistency のコストは workflow の `MaxIterations` / budget に乗せる。
- **pre-scan は false negative を完全には防げない**ため、external-origin text は `active` でも常に data boundary 化する（不変条件1）。
- **web/PDF metadata author は偽装可能**: `MetadataTrustClass` を持たせ、未認証 metadata 由来だけで high-confidence link にしない。
- **MA は MiningObject の projection**（`MiningObjectID` で正準接続）。専用 event / API / segment は wrapper + surface であり正準事実を二重保持しない。
