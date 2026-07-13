# SourceVault Cane / Knowledge Home 認知支援マイニングレイヤー仕様 v0.2

- 作成日: 2026-07-12(v0.1)/ 更新日: 2026-07-12(v0.2)
- 状態: **Draft(r1 レビュー全反映+subject 汎用化。再レビュー待ち)**
- 本版 v0.2 の変更(要約):
  1. **r1 レビュー(`sourcevault_cane_knowledge_home_mining_spec_review.md`)の P0-01〜06・P1-01〜09・§8 最小修正 12 項目を全反映**(対応表は Appendix C)
  2. **認知変動枠組みの subject 汎用化**: 認知状態を「人(オーナー/他者)や LLM とタイムスタンプを引数とした関数」に一般化。ハルシネーション・思い込み(confabulation)・忘却による LLM の「認知変動」を同一のイベント/projection 枠組みで保持し、思い込み状態の subject への対応を **EvidenceConfrontation(証拠提示による指摘)/ HigherLayerContainment(上位レイヤーでの停止・吸収=カモフラージュの一般化)/ ObserveOnly** の介入ポリシー格子として統一。**可用性は subject 種別で非対称**(LLM への containment は即時可、人への camouflage は倫理レビューまで凍結)
  3. 概念の改名・分解: OntologyPosition→**KnowledgeHomeTopicPosition**(UnknownMass/evidence provenance 付き)、RecallLevel→**ExposureHistory / RetrievalFamiliarityEstimate / RecallAssessment** の三分割、P1 のオーナー認知推定→**OperationalSupportSignal**(観測専用・shadow)、TrustAssessment→**5 面分解**
  4. 保存境界の是正(認知系正準は SensitiveLocalVault、CoreRoot rollup 撤回)、retention/消去、Guard の decision class 再定義(認知単独で deny しない・TimedDefer)、action risk taxonomy、Task/Commitment モデル、評価計画と shadow 昇格条件、Phase 0 / 1A〜1E 再編
- 対象:
  - 新規 `SourceVault_knowledgehome.wl`(Knowledge Home 閲覧/追記/位置づけ/近傍提案)
  - 新規 `SourceVault_cognition.wl`(認知状態/介入ポリシー/ガード。人間 subject の正準は SensitiveLocalVault)
  - 既存の拡張: `SourceVault_oopsseed.wl` / `SourceVault_mailsuggest.wl` / `SourceVault_mining.wl` / `SourceVault_searchindex.wl` / `SourceVault_lexical.wl` / `SourceVault_identity.wl` / `SourceVault_maildb.wl` / `SourceVault_llmlog.wl` / `SourceVault_diagnostics.wl` / `SourceVault_servicemanager.wl`(output gate)
- 依拠資料: v0.1 と同じ(SSI2019 / cane3 抜粋 / Masui / Toffoli / Lieder)
- 前提仕様: v0.1 と同じ(datastore draft / mining-identity / search foundation / general mail / universal MCP access v2 / autotrigger+SIEM)。加えて Function Contract/Wiring 仕様(幻 option 実行前拒否=LLM containment の実装済み実例)

## 0. 目的と結論

**目的**(v0.1 から不変): oops メーリングリストをベースの基準座標(Knowledge Home)とし、SourceVault の全データをそのトピックアイテム空間上に位置づけ、(1) 現在の思考位置の推定と近傍提案、(2) ループに陥らない前進支援、(3) 認知変動の推定に応じた検証レベル・提示粒度の制御による不可逆ミスの予防、(4) 送信先等の信頼度推定、を実現する。対象は認知症に限らずあらゆる認知能力変動(健常者の日内変動を含む)。

**v0.2 で確定する中心思想(subject 汎用化)**: 「認知変動」はオーナー固有の概念ではない。**人(オーナー/家族/メール相手)も LLM も、忘却・思い込み(confabulation/ハルシネーション)・堂々巡り(looping)という同型の状態変動を持つ subject** であり、本仕様はその状態を `(SubjectRef, timestamp) → CognitiveState` の同一枠組みで保持する。そして「思い込み状態の subject が誤りを犯しつつあるとき、**証拠を示して指摘する**か、**カモフラージュして上位レイヤーでエラーを止める**か」という介入選択を、subject 種別・誤りのリスク・関係性から決める **InterventionPolicy** として統一する。

この汎用化は理念ではなく実装の合流である。SourceVault/claudecode には LLM に対する containment が**既に実装されて動いている**:

- Function Contract 層の**幻 option 実行前拒否+自動修復**(LLM は指摘されず、上位層が誤りを吸収)
- ClaudeEval **ループガード**(同一署名再掲で即終了、MaxContinuations)= LLM の堂々巡り検出・停止
- `SourceVaultEvaluateOutputGate` / action gate(誤出力の遮断)
- `SourceVaultAssessUncertainty`(self-consistency)/ `SourceVaultMakeMetacognitiveAssessment`(ConfidentErrorRisk 等)= LLM の思い込み検出

本仕様の新規部分は、これらを **LLM-subject の CognitiveState イベント producer / InterventionDecision として同一の正準に登録**し、オーナー(人間 subject)側には**観測専用・shadow・local-only** の慎重な段階(r1 レビュー準拠)で同じ枠組みを適用することである。

**結論(段階方針、r1 反映)**: Phase 1 を一括着手しない。低リスクな Knowledge Home 閲覧(1A)→追記(1B)→位置づけ・近傍(1C)を独立に完成させ、認知推定(1D)は観測専用・shadow・local-only、行動介入(1E)は shadow mode で評価してから action class 単位で昇格する。LLM-subject の containment は既存実装の正準化なので 1D/1E の先行トラックとして有効化できる。

## 1. 概念モデルと用語

### 1.1 資料 → 本仕様マッピング(v0.2 改訂)

| 資料/論文の概念 | 本仕様の用語 | 実体 |
|---|---|---|
| Knowledge Home / oops ML | ベース基準座標(base reference frame) | 既存 oopsseed(read-only)。※「オントロジ」を名乗らない(P1-01): 概念型・制約・版管理を持つ形式オントロジではなく、owner の長期的トピック基準座標である |
| topic item | TopicItem | 既存 `svtopic:oops:<ns>:<localId>`。KH 拡張分は ULID 正準+`ki <n>` 表示 alias(§4.2) |
| paragraph / quoting graph / session / cluster | 既存(`svmailpara:` / QuoteEdge / MailSession) | 変更なし |
| associative level(ノード毎の想起可能度) | **ExposureHistory**(観測事実)/ **RetrievalFamiliarityEstimate**(弱い推定, projection)/ **RecallAssessment**(能動測定) | §4.4。単一 RecallLevel を廃止(P1-03) |
| cognitive level(subject の時刻依存状態) | **CognitiveState**(subject 汎用の枠組み)。P1 のオーナー推定器の出力は **OperationalSupportSignal**(観測可能事実のみ・shadow) | §4.5。「認知レベル」の名称は妥当性確認まで人間 subject の下流で使わない(P0-04) |
| (新規一般化)LLM のハルシネーション/思い込み/忘却/堂々巡り | CognitiveState の **Confabulation / Forgetting / Looping** 次元(SubjectKind→LLM) | §4.5/§5.10。既存 detector 群が producer |
| privacy level 降下操作の execute/stop/**camouflage** | **InterventionPolicy**: EvidenceConfrontation / HigherLayerContainment / ObserveOnly | §4.9。人への camouflage は P3 倫理凍結、LLM への containment は即時可 |
| 全データの位置づけ | **KnowledgeHomeTopicPosition**(旧 OntologyPosition) | §4.1。UnknownMass 必須(P1-01) |
| variable briefing level | BriefingProfile | §5.5。まず owner 手動モード |
| compress items | SimilarNode 通知 / CompressedNode | P2(変更なし) |
| me' | me' 起票 | P2/P3(変更なし) |
| 送信先信頼度 | **5 面分解**: IdentityAssurance / DeliveryAssurance / RecipientAuthorization / Familiarity / SourceReliability | §4.6(P0-06) |
| 見落とし・忘れの予防 | **Task/Commitment モデル**(独立設計) | §4.8(P1-07)。cognition の特徴量として先に使わない |

### 1.2 subject の種別と参照形式

```
SubjectRef:
  "ent-..."                       (* 人。owner は SourceVaultOwnerEntity[] *)
  "svllm:<AccessProfileId>"       (* LLM。universal MCP access v2 §2.5 の model AccessProfile を正準参照。
                                     モデル名+版+提供元は AccessProfile 側が保持 *)
SubjectKind: "Owner" | "Human" | "LLM"
```

認知状態・信頼度は **`(SubjectRef, AsOfUTC)` を引数とする関数**として公開する(§6)。同一 API・同一 event 語彙で、保存クラスと介入可用性だけが SubjectKind で異なる(§2 I-1 / §4.9)。

## 2. 不変条件(安全境界。v0.2 全面改訂)

**I-1. 保存境界(P0-01 是正)** — 「クラウド投入禁止」を保存先の実体で保証する。

| データ | 保存先(正準) | 備考 |
|---|---|---|
| 人間 subject の CognitiveState / OperationalSupportSignal / RecallAssessment / ThinkingContext / Familiarity・OwnerGrade / Guard・Intervention の対人判断ログ | **新設 root `SensitiveLocalVault`**(既定 `<LocalState>/sensitive/cognition/`。**Dropbox/CoreRoot/PrivateVault に置かない**。同期対象外・バックアップ除外リスト付き) | 専用 append API `SourceVaultCognitionAppendEvent`(保存先を強制し、通常 event store への書込みを拒否)。汎用 `SourceVaultAppendEvent` を人間 subject 認知系に使わない |
| 同・特徴量 raw(プロンプト断片・打鍵・将来の音声/映像特徴) | `SensitiveLocalVault` 内の短期領域(retention 後に物理削除。§ I-3b) | event には集約値と粗い Basis のみ |
| LLM subject の CognitiveState(幻 option 率・self-consistency 分散・loop 検出等の運用テレメトリ) | 通常 event store(PrivateVault)、`AccessLevel -> 0.85` | 個人生体情報ではない。ただし prompt 断片を含めない |
| ExposureHistory(閲覧等の観測事実) | 既存 ObjectInteractions(PrivateVault)。**opt-in**(1A では既定 off) | 既存規約どおり MCP deny |
| KnowledgeHomeTopicPosition cache | Dropbox 外 cache dir。**低機密とみなさない**(topic ref 列から生活・健康・対人関係が推測可能。P1-02): `MaxInputPrivacyLevel` を保持し、gate は最厳格入力に従う | 再生成可能 |

- **マルチデバイス同期は Phase 1 から除外**する。v0.1 §4.5 の CoreRoot rollup 案は撤回。将来必要なら「本人明示 opt-in・端末間 E2E 暗号化・鍵管理・端末失効・最小化統計のみ」を別仕様として起こす。
- MCP surface は人間 subject 認知系を**既定 deny**。prompt/ログ/トレースへは tier(`Low|Mid|High`)すら**出さない**のが既定で、owner の明示 opt-in(`IncludeSensitive -> True`)時のみ tier を返す。
- 到達不能性はデータフロー試験で保証する: Dropbox/CoreRoot/PrivateVault・MCP・LLM prompt・診断ログ/SIEM・例外メッセージ・クラッシュダンプ・バックアップ・Notebook output・clipboard を含む **sink matrix の自動試験**(§8)。

**I-2. 単調安全性と介入の非対称** — 認知系推定はいかなる privacy/release gate も緩めない。作用は (a) 検証レベルの引き上げ (b) 提示の絞り込み (c) ランキング/表示 (d) §4.9 の介入選択、のみ。
- **認知系推定単独で action を deny しない**(P0-02)。deny できるのは既存 policy(release gate / 宛先認可)だけである。
- 人間 subject への介入は **EvidenceConfrontation(証拠の提示)と可逆な摩擦(確認追加・TimedDefer)まで**。人への HigherLayerContainment(camouflage: 本人に知らせず上位で偽装・停止する)は **P3 の倫理仕様(同意・意思決定能力・代理権・緊急停止・監査)が承認されるまで実装しない**。
- LLM subject への HigherLayerContainment は制約なく可(output gate/契約層拒否/再試行/破棄)。第三者の人間へは**システムが直接対峙しない**: 介入は常に owner を介する(owner への「証拠つき指摘案」の提示まで)。

**I-3. ベース不変(適用範囲を限定。P0-03)** — 「何も削除しない」は **oops 原本と、owner が残すと決めた Knowledge Home 記述(KH パラグラフ/topic item/annotation)に限定**する。訂正は Supersede、圧縮は CompressedNode+edge。

**I-3b. 認知系データの retention と消去(新設)** —
- 再生成可能な推定 projection: いつでも削除・再計算可。
- 特徴量 raw: 短期 retention(既定 30 日、owner 設定可)、目的達成後に物理削除。
- 認知・信頼推定 event: retention 上限(既定 2 年、owner 設定可)。
- **owner はいつでも「推定停止」「subject/期間指定の消去」「全消去」を実行できる**: `SourceVaultCognitionErase[...]` は SensitiveLocalVault 内の event・projection・cache を物理削除し、**消去後の replay で復活しない**(認知系 store は独立しており、通常 event store に複製が存在しないことを I-1 が保証する)。
- 法的保全・監査が必要な action decision(Guard の送信判断等)は内容を最小化(action class・判定・理由コードのみ、認知数値は含めない)して通常監査系に置く。

**I-4. 既存 gate 全経由**(v0.1 から不変) — 閲覧/検索/提案/View は `ReleaseContext` + request-time release gate + revocation を必ず通る。KH の read/search API は **`ReleaseContext` を明示引数に持つ**(P1-08)。private scope の topic label を cloud/public scope の出力・vocabulary に混入させない。

**I-5. bounded influence**(不変) — boost は既存規約(MaxBoost 0.2、LLM 寄与 0.7 係数、OwnerDismissed 抑制)内。認知系が検索スコアへ与える影響も同上限クラス。

**I-6. ゆるい運用と介入の可逆性(P0-02 反映で改訂)** — auto-confirm 既定 off、me' 起票は Pending、通知 rate limit。Guard の decision class は §5.7 の 4 分類とし、`TimedDefer` は期限・再提示時刻・**即時 override**・理由説明・緊急経路を必ず持つ。介入は shadow mode から始め、昇格条件(§8)を満たした action class のみ有効化する。owner は「提案を減らす」「今日は介入しない」「この話題を出さない」「全推定を停止」を即時選べる(`SourceVaultCognitionControls[]`)。

**I-7. 可搬性**(不変) — 正準は JSONL/markdown/既存 index 形式。cache は再生成可能。可搬性は永久保存を意味しない(I-3b と両立)。schema migration と export・消去を含む移行演習を P2 で定期化。

**I-8. FE 非ブロック**(不変)。

**I-9. 観測と推論の分離(新設。P1-03/P0-04)** — 観測 event(ExposureHistory 等)は不変の事実のみを記録する。減衰・推定は **model version 付き projection の計算結果**であり、擬似 event(v0.1 の `Decayed`)として履歴に混ぜない。推定値は必ず `ModelVersion`/`Confidence` を持ち、`Missing`(未推定)と低値を区別する。

## 3. アーキテクチャ

```
L0 ベース基準座標        oopsseed(既存): seed辞書 / relation graph / quote / session / chunk / primer
L1 Knowledge Home 層     【1A/1B】NB ハイパーテキスト閲覧 + 非破壊追記
L2 位置づけ層            【1C】KnowledgeHomeTopicPosition(UnknownMass・evidence 付き projection)
L3 思考文脈層            【1C】ThinkingContext + 近傍提案(3リング+ProgressScore)
L4 認知層(subject汎用)  【1D】CognitiveState: 人=観測専用 shadow / LLM=既存 detector の正準化
L5 介入・ガード層        【1E】InterventionPolicy + TaskValidationLevel + Task/Commitment
```

依存方向は L5→L4→L3→L2→L1→L0。人間 subject の L4/L5 データは `SourceVault_cognition.wl` + SensitiveLocalVault に閉じる。**Phase 0 で source→transform→store→sink のデータフロー図と data inventory を作成し、以後の Inc はこの図の更新を DoD に含める**(レビュー §6 Phase 0)。

## 4. データモデル

### 4.1 KnowledgeHomeTopicPosition(旧 OntologyPosition。P1-01/P1-02 反映)【1C】

```
<|ObjectClass -> "SourceVaultKnowledgeHomeTopicPosition",
  ObjectURI,                       (* object 全体 or 根拠 segment 単位(SegmentRef 付き) *)
  TopicEvidence -> {
    <|TopicRef, Weight, Method -> "SeedMatched"|"RelationExpanded"|"DenseProjected"|
                                   "LLMProposed"|"OwnerConfirmed",
      SourceSegmentRef, Confidence, ModelVersion, VocabularyVersion, PrivacyLevel|>, ...},
  UnknownMass -> 0..1,             (* どの topic にも帰属しない質量。無理に押し込まない *)
  Space -> "OOPSSeed"|"KHExtension"|"Mixed",   (* oops 空間 / post-oops 拡張空間の区別 *)
  AnchorTopicRefs,                 (* OwnerConfirmed のみ(機械推定と明確に区別) *)
  MaxInputPrivacyLevel,            (* 全入力の最大 PL。position 自体の gate に使用 *)
  DerivedAtUTC, PipelineVersion, InputDigest|>
```

- topic alias・改名・分割・統合は versioned mapping(`kh-topic-alias.jsonl`、alias 履歴付き)で扱い、position は VocabularyVersion で再現可能にする。
- `UnknownMass` が閾値(既定 0.5)超の object は近傍提案で「未マップ領域」として明示し、oops topic への誤射影で提示しない。未マップ領域の成長は KH 拡張空間の新 topic 候補(P2 の圧縮/成長と接続)。

### 4.2 Knowledge Home 拡張パラグラフと topic 採番(P1-05 反映)【1B】

- パラグラフ: `svkhpara:<ULID>`(ULID 正準。デバイス間衝突なし)。event `KnowledgeHomeParagraphAdded` は v0.1 §4.2 と同じフィールド構成、ただし `CognitiveLevelAtCreation` を廃止し §4.3 の参照 ID に置換。
- **topic item の正準 ID は `svtopic:kh:<ULID>`**。`ki <n>` 形式は**表示用 alias** として `SourceVaultKnowledgeHomeMintItem[label]` が extension index に割り当てる(mint は `.lockdir` lock + compare-and-swap、オフライン合流時の番号衝突は**正準 ID 無傷のまま alias を振り直して merge**、alias 履歴を保持)。
- label の「重複候補提示」(検索して既にあれば再利用を促す)と「identity の同一性判断」(同義語/改名の同一 topic 化)は別ステップとし、後者は owner 確認必須(auto-confirm off)。

### 4.3 AuthorOperationalContextAtCreation(P0-05 反映)【1D 以降】

作成時の owner 状態と内容の信頼性を**分離**する:

- `AuthorOperationalContextAtCreation`: 作成時の OperationalSupportSignal への **local-only 参照 ID**(SensitiveLocalVault 側)。event 本体に tier を複製しない。**既定非表示・owner のみ・明示 opt-in で表示**。メール受信者・共同編集者へ自動添付しない。
- `AssertionEvidence`: 根拠・出典・検証状況・後続訂正(既存 mining assertion / EvidenceRefs)。
- `ContentReliability`: AssertionEvidence から評価する(既存 MetacognitiveAssessment 系)。**作成時の操作状態だけで下げない**。

### 4.4 想起系の三分割(P1-03 反映)【1A(観測 opt-in)→ 1D → P2】

| 層 | 内容 | 実体 |
|---|---|---|
| **ExposureHistory** | 開いた/辿った/引用したという観測事実のみ | 既存 ObjectInteractions(opt-in)。event は不変 |
| **RetrievalFamiliarityEstimate** | 観測からの弱い推定(親密度)。減衰は projection 計算内(ModelVersion 付き)。擬似 event を作らない | `SourceVaultRetrievalFamiliarity[targetURI, "AsOfUTC"->t]` projection |
| **RecallAssessment** | self-report・能動再認課題(「覚えていますか」)による直接測定 | event `RecallAssessed`(SensitiveLocalVault)。P2 |

閲覧・想起・理解・同意は**別イベント**として記録する(受け入れ基準 6)。「未閲覧=Forgotten」とは呼ばない。encode 表示(P2)の駆動は RecallAssessment を主、Familiarity を従とする。

### 4.5 CognitiveState(subject 汎用)と OperationalSupportSignal(P0-04+汎用化)【1D】

**枠組み(全 subject 共通)**:

```
projection: SourceVaultCognitiveState[subjectRef, "AsOfUTC"->t, "Window"->w, opts] ->
<|SubjectRef, SubjectKind,
  Dimensions -> <|
    "Forgetting"    -> <|Value, Confidence|>,   (* 忘却: 人=想起失敗率 / LLM=文脈喪失・知識鮮度切れ *)
    "Confabulation" -> <|Value, Confidence|>,   (* 思い込み: 人=誤想起・勘違い / LLM=ハルシネーション・幻option・過信 *)
    "Looping"       -> <|Value, Confidence|>,   (* 堂々巡り: 人=同一topic再訪(新規なし) / LLM=同一署名出力反復 *)
    "Instability"   -> <|Value, Confidence|>|>, (* 変動性: 推定のばらつき自体 *)
  Tier -> "Low"|"Mid"|"High",                   (* 総合。人間 subject は P1 でこの tier も下流に出さない *)
  ModelVersion, BasisEventRefs, WindowStart, WindowEnd, Freshness|>
```

**人間 subject(P1 = 1D)**: 推定器の名称と出力は **`OperationalSupportSignal`**(観測可能事実のみ)。
- event `OperationalSignalSampled`(SensitiveLocalVault): 再試行/やり直しループ率、プロンプト修正率、深夜比率などの**集約値**+共変量(曜日・時刻・作業種別・既知の障害イベント)。個人内ベースラインからの偏差で表現する。
- **返信遅延・締切見落としを推定入力に使わない**(P0-04 の循環回避): これらは §4.8 Task/Commitment の outcome として独立に記録し、前向き評価(§8)でのみ突合する。
- 介入先は**可逆な UI 変更(候補数削減)に限定**し、shadow mode で self-report(`CognitiveSelfReported` event)との比較画面のみ提供。妥当性が §8 の基準を満たすまで「認知能力」「認知レベル」「データ信頼性」という表示・語を UI に出さない。

**LLM subject(1D 先行トラック)**: 既存 detector を producer として正準化する。
- event `LLMCognitiveEventObserved`(通常 event store、AccessLevel 0.85):
  - Confabulation: 幻 option 実行前拒否(Contract 層)、`SourceVaultAssessUncertainty` の self-consistency 分散、`MetacognitiveAssessment.ConfidentErrorRisk`、judge/検証 chain の反証成立、出典要求に対する引用失敗
  - Forgetting: コンテキスト超過による切り詰め検出、既出情報の再質問(「過去の検索結果が見えない」型)、knowledge cutoff 起因の陳腐化検出
  - Looping: ClaudeEval ループガードの同一署名再掲検出、MaxContinuations 到達、web 検索の反復
- 資料 p20「faults の数で推定する」の LLM 版そのもの: fault = 上記 detector の発火。モデル×版(AccessProfileId)ごとに (subject, t) の関数として集約し、**モデル選択・検証深度の決定に即時利用してよい**(人間 subject と違い shadow 縛りなし。ただし I-2: モデルの authorization は AccessProfile が正準で、CognitiveState で緩めない)。

### 4.6 信頼度の 5 面分解(P0-06 反映)【1E 最小】

単一 [0,1] の TrustAssessment を廃止し、次を別フィールドで保持する:

| 面 | 問い | 正準/保存先 |
|---|---|---|
| IdentityAssurance | 名乗る本人か | 既存 identity 層(認証タグ・SPF/DKIM 系)。通常 store |
| DeliveryAssurance | 配送経路・ドメインが妥当か | 既存 MailDelivery/配送異常。通常 store |
| **RecipientAuthorization** | この情報を受け取る権限があるか | **既存 `ContactAccessProfile`/`MaxPlaintextPL` が正準のまま**(本仕様は変更しない・緩めない) |
| Familiarity | owner との交流の深さ | SensitiveLocalVault(対人プロファイルは秘匿) |
| SourceReliability | その subject の主張の正確さ | assertion/ContentReliability 系(§4.3)。LLM は §4.5 の Confabulation 履歴と AccessProfile |

- **単一合成 trust score で release を判断しない**(受け入れ基準 7)。Guard(§5.7)は各面を独立入力として使い、release 可否は従来どおり RecipientAuthorization(既存 gate)のみが決める。
- LLM の「信頼度」: authorization は AccessProfile(TrustDomain/MaxAccessLevel)が正準。SourceReliability は観測履歴(§4.5)で、検証深度にのみ影響する。

### 4.7 ThinkingContext と ProgressScore(P1-04 反映)【1C】

- ThinkingContext は v0.1 §4.7 と同構成(SensitiveLocalVault)。複数同時タスクを許すため `EstimatedPosition` は単一でなく **成分分解(最大 3 クラスタ)** を返せる。
- **ProgressScore**: 「newer=前進」を廃し、bounded な一特徴に格下げする。前進の判定は:
  - resolved/unresolved・next action・deadline の状態遷移(§4.8 Commitment と接続)
  - 新しい evidence・decision・artifact の生成有無
  - owner feedback(「前進した」「脱線した」「もう出すな」= dismiss/snooze/never-suggest)
  - 同一 topic 内の異なる subproblem への移動
- LoopScore は「新規ノード作成なし」を唯一根拠にしない(長時間の読解・検証をループと誤判定しない): 同一ノード集合の**周回**(順序付き再訪パターン)+進捗イベント欠如の複合で判定し、**判定根拠と提案理由を UI に表示**する。
- LLM subject の Looping(§4.5)は同じ event 語彙(`LoopDetected`, SubjectRef 付き)で記録される — 人の思考ループも LLM の生成ループも L3 の同一枠組みで扱う。

### 4.8 Task/Commitment モデル(P1-07 反映。新設)【1E 最小 → P2】

「返信すべきメール」「締切のある Todo」「行事の準備」を cognition の特徴量にする前に、独立した正準モデルとして設計する:

```
<|ObjectClass -> "SourceVaultCommitment", CommitmentId(ULID),
  Kind -> "MailReply"|"Todo"|"EventPreparation"|"Deadline"|"Recurring",
  SourceRefs,                       (* sv://mail/... / iCal event / $onWork NB / KH パラグラフ *)
  Status -> "Open"|"Done"|"NotNeeded"|"HandledElsewhere"|"Delegated"|"Snoozed",
  OwnerCorrection,                  (* 「返信不要」等の owner 訂正。ground truth 化 *)
  Deadline, ReminderAt, PreparationLeadTime, GracePeriod,
  DetectionBasis, FalseAlarmFlag|>
```

- 供給源: maildb(返信要否の推定)、NotebookExtensions iCal、`$onWork` NB、KH。同一 task への重複検出・統合、同期失敗・タイムゾーン変更への対処を含む。
- 用途は第一に**本人支援**(リマインド提案。autotrigger 経由、rate limited)、第二に §8 の評価(見落とし ground truth と false alarm 記録)。OperationalSupportSignal の入力には**使わない**(循環回避)。

### 4.9 InterventionPolicy / InterventionDecision(新設。ユーザー要求の汎用化)【1E】

思い込み・忘却・ループ状態の subject が誤り(または誤りに向かう行為)を示したときの対応を統一する:

```
InterventionKind:
  "ObserveOnly"                (* 記録のみ(shadow)。既定 *)
  "EvidenceConfrontation"      (* 証拠を示して指摘する:
                                   人(owner): 反証となる KH ノード/メール/記録を提示し、齟齬を指摘
                                   人(第三者): owner に「証拠つき指摘の下書き」を提案(直接対峙しない)
                                   LLM: 反証 evidence を次 turn に注入 / 出典要求 / 反証つき再生成 *)
  "SoftFriction"               (* 可逆な摩擦: 確認追加・TimedDefer・候補絞り(人間 subject の上限) *)
  "HigherLayerContainment"     (* 本人/本 model に知らせず上位レイヤーで停止・吸収:
                                   LLM: output gate 遮断・幻option拒否+修復・破棄・再試行・別モデル切替
                                   人: = camouflage。P3 倫理仕様承認まで実装禁止 *)

event: InterventionDecisionRecorded   (* 対人判断は SensitiveLocalVault / 対LLM は通常 store *)
<|SubjectRef, SubjectKind, TriggerKind(Confabulation|Forgetting|Looping|RiskAction),
  ClaimOrActionRef, EvidenceRefs, RiskClass(§5.7 taxonomy),
  ChosenKind, Availability, Outcome -> "Accepted"|"Overridden"|"Ineffective"|Missing,
  Reasons, ShadowMode -> True|False, DecidedAtUTC|>
```

**可用性行列(不変条件 I-2 の具体化)**:

| SubjectKind | ObserveOnly | EvidenceConfrontation | SoftFriction | HigherLayerContainment |
|---|---|---|---|---|
| LLM | ○ | ○ | ○(検証深度引上げ) | **○(既存 output gate/契約層=即時可)** |
| Owner | ○ | ○(提示は非侵襲・理由表示) | ○(override 可・期限付き) | **×(P3 倫理凍結)** |
| Human(第三者) | ○ | △(owner 経由の下書き提案のみ) | ×(システムは第三者を制御しない) | × |

- 選択入力: subject 種別、誤りの RiskClass(§5.7)、証拠の強度(AssertionEvidence)、subject の現在状態(指摘が有効に働く状態か — 資料 p18: 認知レベルが高い時は通知、低い時は許して後で圧縮)、過去の介入 Outcome(効かなかった指摘を繰り返さない)。
- Outcome の記録により「指摘 vs 吸収」の効果を subject ごとに学習する(P2)。ただし学習は選択の重みに限り、可用性行列は変更しない。

### 4.10 event class 一覧(v0.2)

通常 store: `KnowledgeHomeParagraphAdded` / `KnowledgeHomeTopicItemMinted` / `TopicAliasAssigned` / `LLMCognitiveEventObserved` / `LoopDetected(SubjectKind->LLM)` / `TrustEvidenceRecorded(Identity/Delivery 面)` / `CommitmentObserved`・`CommitmentStatusChanged` / `GuardDecisionRecorded(内容最小化版)` / `InterventionDecisionRecorded(対LLM)`。
SensitiveLocalVault(`SourceVaultCognitionAppendEvent` 経由のみ): `OperationalSignalSampled` / `CognitiveSelfReported` / `RecallAssessed` / `ThinkingContextSnapshotted` / `LoopDetected(SubjectKind->Owner)` / `FamiliarityObserved` / `InterventionDecisionRecorded(対人)`。

## 5. 機能仕様(v0.1 からの差分中心)

### 5.1 Knowledge Home NB ブラウザ【1A】
v0.1 §5.1 のとおり。ただし: interaction 記録(ExposureHistory)は **opt-in で既定 off**、記録しても 1A では推定に接続しない。実 API 名は `SourceVaultBuildSearchView` / `SourceVaultRenderSearchNotebookView`(P1-08 の表記修正)。read/search API は `ReleaseContext` 明示。1A の DoD に private topic label 漏洩試験を含める。

### 5.2 Knowledge Home 追記【1B】
v0.1 §5.2 + §4.2 の ULID/alias/CAS/merge。supersede(訂正)UI と undo(直近追記の supersede による取り消し)を追加。

### 5.3 位置づけ【1C】
v0.1 §5.3 + §4.1 の UnknownMass/TopicEvidence/Space。owner の held-out anchor(gold set、Phase 0 で作成)に対する Recall@k / nDCG / calibration / Unknown 判定精度が §8 の基準を満たすまで、position を「前進」介入の根拠に使わない。

### 5.4 現在位置推定・近傍提案・前進支援【1C】
v0.1 §5.4 + §4.7 の ProgressScore。3 リング構成は維持するが、リング 1 の「newer」は bounded 特徴。提案 UI は理由(どの edge/評価で選ばれたか)と dismiss/snooze/never-suggest を必ず持つ。cognition 依存の件数絞りは 1D 昇格後。

### 5.5 可変 briefing【1D shadow → P2】
**まず owner 手動モード**(`SourceVaultBriefingProfileSet["Compact"]` 等)から始める。OperationalSupportSignal による自動切替は可逆な候補数削減のみ・shadow 評価後。encode 表示(粒度可変)は P2(RecallAssessment 導入後)。

### 5.6 類似反復の圧縮【P2】(v0.1 のまま)

### 5.7 Guard(P0-02/P1-06 反映)【1E: shadow → 段階昇格】

**decision class(4 分類)**:

| Class | 意味 | 認知系の関与 |
|---|---|---|
| `Standard` | 既存 gate のまま | — |
| `Confirm` | 確認を 1 段追加(理由表示付き) | 可(昇格済み action class のみ) |
| `TimedDefer` | 期限付き延期+再提示。**即時 override・緊急経路・期限超過時の自動再浮上**を必ず持つ | 可(同上)。期限付き action では延期損失を評価済みであること |
| `DenyByExistingPolicy` | 既存 policy(release gate/宛先認可)による拒否 | **認知系は関与しない**(reason code も分離) |

**action risk taxonomy(P1-06)** — Guard 入力の主軸は action の客観リスク:

```
<|Reversibility -> "Draft"|"Undoable"|"Irreversible",
  Reach -> "Self"|"KnownRecipients"|"Organization"|"Public",
  SensitivityGap,                  (* content PL − 宛先 RecipientAuthorization の差(privacy 降下量) *)
  TimeConstraint -> "Urgent"|"Deadline"|"Deferrable",
  ImpactDomains -> {"Financial","Legal","Health","Safety",...},
  RecipientCount, HasAttachments, HasExternalLinks, IsReplyVsNew,
  Confidence, EvidenceCompleteness|>
```

- 認知系(OperationalSupportSignal / LLM CognitiveState)は**一入力**にすぎず、しかも人間 subject 分は 1D の昇格基準を満たすまで入力に含めない。
- 運用順序: (1) shadow mode で decision を記録するだけ(既存 gate と並走)→ (2) §8 の false intervention 基準を満たした action class から `Confirm` を有効化 → (3) `TimedDefer` は期限処理の評価後。
- LLM subject が実行主体の action(自動送信ドラフト・一括処理)は、LLM の CognitiveState(Confabulation 履歴)で**検証チェーン深度**(self-consistency サンプル数・judge 段数・人間確認の要否)を引き上げる — これは既存 output gate 運用の正準化であり shadow 不要。

### 5.8 me' 起票【P2/P3】(v0.1 のまま。表示切替は P3 倫理枠)

### 5.9 6 問題対応マップ(v0.1 のまま。問題 1=1C、2/3/4=P2、5/6=P3)

### 5.10 LLM 認知変動への適用(新設。ユーザー要求の中核)【1D/1E 先行トラック】

同一枠組みの LLM 側の具体結線:

1. **状態の保持**: §4.5 の producer 群(幻 option 拒否・self-consistency・loop guard・output gate 反証・MetacognitiveAssessment)を `LLMCognitiveEventObserved` として event 化し、`SourceVaultCognitiveState["svllm:<profile>", "AsOfUTC"->t]` で照会可能にする。モデル版更新は AccessProfileId が変わるので状態は版ごとに分離される(「あのモデルのあの版は思い込みが強い」を保持)。
2. **介入選択**(§4.9): 誤り検出時に
   - EvidenceConfrontation: 反証 evidence(KH/検索結果/契約定義)を次 turn に注入して自己訂正させる(修復可能な誤りに有効。既存の幻 option「自動修復」がこの形)
   - HigherLayerContainment: 出力を遮断・破棄・再試行・別モデル切替(修復不能/高リスク時。既存 output gate・ループガードの即終了がこの形)
   - 選択規準: RiskClass が高い/Confabulation 履歴が高い model には confrontation を試さず containment(トークン浪費と誤収束の回避。ClaudeEval ループガードの知見: 効かないモデルに再考を促し続けない)
3. **利用面**: モデル選択(タスクの RiskClass × model の CognitiveState 履歴)、検証深度の動的決定、`ContentReliability` への反映(LLM 産の assertion は生成時の model 状態を SourceReliability の弱い事前分布として使う — ただし evidence があれば evidence が常に優先。§4.3 の原則の LLM 版)。
4. **対称性の明示**: 人の「勘違いによるメール返信」も LLM の「ハルシネーションによる誤回答」も、`(subject, t)` の Confabulation 状態+InterventionDecision という同一スキーマで監査できる。異なるのは可用性行列(§4.9)と保存クラス(§2 I-1)だけである。

## 6. Public API(草案 v0.2。P1-08 の契約反映)

共通契約: 認知系 API は `SubjectRef` / `"AsOfUTC"`(既定 Now、as-of セマンティクス)/ `"Window"` / `"ModelVersion"`(既定 latest、pin 可)/ `"Purpose"`(監査用)/ `"IncludeSensitive" -> False`(安全既定)を持つ。読み系は `Missing["NotEstimated"]` と低値を区別し、projection の `Freshness`/stale を返す。KH read/search は `"ReleaseContext"` 必須(未指定 fail-closed)。書込み系の失敗は fail-closed、読み系の推定欠落は fail-soft(`Missing`)。

`SourceVault_knowledgehome.wl`:
```
SourceVaultKnowledgeHomeEnsureLoaded[opts]
SourceVaultKnowledgeHomeView[entry, "ReleaseContext"->rc, opts]      (* core/View/Window 3層 *)
SourceVaultKnowledgeHomeParagraphs[topicRef, "ReleaseContext"->rc]
SourceVaultKnowledgeHomeAppend[body, opts]                            (* + AppendTemplate / Supersede / UndoLast *)
SourceVaultKnowledgeHomeMintItem[label, opts]                         (* ULID 正準 + ki alias、CAS *)
SourceVaultComputeTopicPositions[uris, opts]                          (* 旧 ComputeOntologyPositions *)
SourceVaultTopicPositionOf[uri, "ReleaseContext"->rc]
SourceVaultNeighborhoodSearch[posOrUriOrText, "ReleaseContext"->rc, opts]
SourceVaultThinkingContextEstimate[opts]                              (* SensitiveLocalVault 書込み *)
SourceVaultSuggestNextNodes[context, opts]                            (* + ...View。理由・dismiss/snooze 付き *)
```

`SourceVault_cognition.wl`:
```
SourceVaultCognitionAppendEvent[event]            (* SensitiveLocalVault 強制。誤ルート拒否 *)
SourceVaultCognitiveState[subjectRef, opts]       (* (subject, t) 関数。人=1D 中は shadow surface のみ *)
SourceVaultOperationalSignalEstimate[opts]        (* 人間 owner。観測専用・外部ワーカー実行 *)
SourceVaultRecordCognitiveSelfReport[v, opts]
SourceVaultRetrievalFamiliarity[targetURI, opts]  (* projection。ModelVersion 付き *)
SourceVaultRecordRecallAssessment[targetURI, outcome, opts]
SourceVaultTrustFacets[subjectRef, opts]          (* 5面を別フィールドで返す。単一値は返さない *)
SourceVaultRecordTrustEvidence[subjectRef, facet, evidence, opts]
SourceVaultCommitments[opts]                      (* Task/Commitment の照会/訂正 *)
SourceVaultTaskValidationLevel[actionSpec, opts]  (* risk taxonomy 主入力。decision class を返す *)
SourceVaultGuardEvaluate[actionDraft, opts]       (* shadow 既定。既存 gate の判定に不干渉 *)
SourceVaultInterventionPlan[subjectRef, trigger, opts]   (* §4.9 の選択。可用性行列を強制 *)
SourceVaultCognitionControls[]                    (* 停止/消去/snooze/話題除外の即時 UI *)
SourceVaultCognitionErase[subjectOrAll, opts]     (* 物理削除。replay 復活なし *)
```

## 7. フェーズ再編(レビュー §6 準拠)

### Phase 0: 契約・脅威モデル・評価基盤【実装前・必須】
- data inventory と source→transform→store→sink データフロー図
- `SensitiveLocalVault` root 追加(core)、retention/消去/バックアップ除外の実装、`SourceVaultCognitionAppendEvent`/`Erase` と sink matrix 試験ハーネス
- 用語確定(本 v0.2 の改名の反映)、action risk taxonomy と guard decision contract の型定義
- owner feedback・gold set(topic anchor / 探索セッション)・shadow decision の保存形式
- DoD: sink matrix 試験が空実装に対して green / gold set 初版(anchor ≥ 100 件目安)

### Phase 1A: 読み取り専用 Knowledge Home
- topic prev/next、quote 双方向、時系列、`SourceVaultBuildSearchView` binding。interaction 記録は opt-in・推定未接続
- DoD: 閲覧往復 NB 実機 / release gate・private label 漏洩試験 green

### Phase 1B: 非破壊追記
- ULID 正準 ID+alias、supersede/undo、CAS/offline merge、追記→検索→閲覧の往復
- DoD: 原本不変(ハッシュ)/ 競合合成テスト / NB 実機

### Phase 1C: 位置づけと近傍検索(cognition 非依存)
- KnowledgeHomeTopicPosition(UnknownMass/evidence)、3 リング+ProgressScore(owner feedback 語彙含む)、mailsuggest 統合 View
- DoD: gold set で Recall@k/nDCG/Unknown 判定が Phase 0 で定めた基準以上。自動「前進」介入なし

### Phase 1D: 観測専用の支援信号(shadow・local-only・single-device)
- 人: OperationalSupportSignal+self-report 比較画面(下流接続なし)。LLM(先行トラック): `LLMCognitiveEventObserved` の producer 結線と `SourceVaultCognitiveState["svllm:..."]`、検証深度への利用
- DoD: I-1/I-3b のデータフロー試験 green / 人間系が prompt・MCP・通常 store に到達しないこと / LLM 状態照会の NB 実機

### Phase 1E: Guard shadow → soft intervention
- Commitment 最小(MailReply/Deadline)、risk taxonomy 実装、shadow 記録、InterventionPolicy(LLM 分は即時有効・対人分は shadow)
- 昇格: §8 基準を満たした action class のみ `Confirm` 有効化 → `TimedDefer`。認知系単独 deny は恒久に不可
- DoD: shadow 並走ログ / false intervention 集計画面 / privacy 降下シナリオ e2e(モック送信)/ 既存送信テスト回帰 green

### Phase 2(半年〜2年)
dense hybrid(bge-m3/JaColBERT)、全 object class の位置づけ、RecallAssessment(能動確認)と encode 表示、compress items、me' 定型起票、宛先入れ違い検出(local LLM)、認知系のマルチデバイス同期**別仕様**(E2E 暗号化・鍵管理・端末失効)、Intervention Outcome 学習、移行演習の定期化

### Phase 3(2年以降・独立倫理仕様が前提)
音声・カメラ・バイオメトリクス(consent・retention・端末内特徴抽出・raw 非保存を別仕様化)、家族/介護者共有(universal MCP access grant 基盤+同意・代理権・緊急停止・監査)、問題 5/6(常時自己提示)、**人への camouflage(HigherLayerContainment)— 倫理仕様の承認が解除条件**、me' 混合表示

## 8. 評価計画(P1-09 反映。新設)

測定方法と昇格条件を実装前に固定する。数値目標は owner が実データで設定するが、**「基準未達なら介入を有効化しない」という昇格ゲートの存在自体は規範**である。

| 対象 | 指標 | ゲート |
|---|---|---|
| topic position | held-out anchor への Recall@k / nDCG / calibration / Unknown 判定精度 | 1C の DoD。未達なら前進介入に使わない |
| neighborhood | 既知探索セッションでの next useful node MRR / Recall@k | 同上 |
| loop support | owner 評価(helpful/irrelevant/disruptive)、同一作業への復帰時間 | リング 1 重み付けの調整のみに使用 |
| familiarity/recall | RetrievalFamiliarityEstimate と self-report/能動確認の calibration(観測のみ推定と分離) | P2 encode 表示の解禁条件 |
| operational signal | 個人内ベースライン比 false alarm 率、曜日・時刻・作業難度別誤差、self-report との前向き相関 | 1D→1E 入力昇格の条件。未達なら Guard 入力に含めない |
| guard | risky action recall / false confirmation rate / false defer rate / override 率 / 期限損失 | action class 毎の Confirm/TimedDefer 有効化条件 |
| LLM cognition | detector 発火と最終誤り(人手確定)の precision、containment による手戻り削減 | 検証深度ポリシーの調整 |
| privacy | non-interference(認知系有無で gate 判定不変)、sink matrix(Dropbox/CoreRoot/PrivateVault/MCP/LLM prompt/診断ログ/例外/バックアップ/NB output/clipboard)自動試験 | 全 Phase の恒常ゲート |
| usability | 確認疲れ・通知疲れ・提案による脱線の owner 評価 | 介入頻度上限の調整 |

shadow decision・owner feedback・gold set は Phase 0 で定義した形式で保存し、昇格判定は記録された系列に対して行う(その場の印象で有効化しない)。

## 9. 受け入れ基準(v0.2 全面改訂)

1. 人間 subject の認知系(正準・projection・cache・バックアップ)が Dropbox/CoreRoot/PrivateVault に一切作られないこと(sink matrix 自動試験)
2. 認知系の値・tier が cloud LLM prompt / MCP レスポンス / 診断ログ / 例外 / NB output / clipboard に出現しないこと(既定。opt-in 表示は owner 明示時のみ)
3. 認知系推定だけで action が deny されないこと。`TimedDefer` に期限・即時 override・緊急経路があること
4. raw feature と projection を owner が停止・消去でき、消去後の replay で復活しないこと
5. topic position が `UnknownMass` を返せ、無理に oops topic へ割り当てないこと。各 TopicEvidence から根拠 segment・method・ModelVersion/VocabularyVersion・PrivacyLevel を追跡できること
6. 閲覧(ExposureHistory)・想起(RecallAssessment)・理解・同意が別イベントであること。観測 event に推定由来の擬似 event が混入しないこと
7. trust の単一値が存在せず、release authorization は既存 RecipientAuthorization(ContactAccessProfile/MaxPlaintextPL)のみが決めること
8. Guard が shadow mode で評価され、action class ごとの false intervention が owner 設定の許容内であること。昇格前の class では UI 介入が発生しないこと
9. 期限付き action で延期損失が試験されていること
10. cache 全削除→再生成の一致は、決定的パイプラインは byte 等価、非決定モデル使用時は model pin+許容差で定義されること
11. InterventionPolicy の可用性行列が強制されること: 人への HigherLayerContainment 経路がコード上存在しない(P3 解禁は別実装)こと、第三者への直接介入が存在しないこと
12. owner が「提案を減らす」「今日は介入しない」「この話題を出さない」「全推定を停止」を即時選べること
13. oops 原本・gold index のハッシュ不変 / FE 同期 LLM 呼び出しゼロ / 既存 gate 回帰 green(v0.1 から継続)
14. LLM subject の CognitiveState が AccessProfile の authorization を一切変更しないこと(検証深度・モデル選択のみ)

## 10. Open issues(v0.2)

1. OperationalSupportSignal→「認知レベル」への名称昇格条件の定量化(§8 の前向き相関をどの水準・期間で判定するか)
2. 人への camouflage の倫理仕様(P3): 事前指示書(元気なうちの同意)・代理権・緊急停止・監査の枠組み。me/me' 攻防(資料 p34)の受動防御をどこまで許すか
3. 認知系マルチデバイス同期の別仕様(E2E 暗号化・鍵失効)。それまで推定は端末毎に独立(端末間で Tier が食い違う場合の表示)
4. LLM CognitiveState の集約単位: AccessProfileId 毎で十分か、タスク種別(コード/検索/要約)毎の分解が必要か
5. cluster 境界の定義(v0.1 から継続)、RecallAssessment の忘却曲線パラメータ(P2 データ待ち)
6. Commitment の「返信すべきメール」判定の初期規則と owner 訂正の UI
7. SensitiveLocalVault のディスク暗号化(OS 任せか、application-level 暗号を足すか)

## Appendix A: 資料の要点(v0.1 から不変。実装への写像根拠)

(v0.1 Appendix A を参照。p16-17 の cognitive level と execute/stop/camouflage は §4.9 InterventionPolicy に、p20 の faults による推定は §4.5(人)と §5.10(LLM の fault=detector 発火)に写像した。)

## Appendix B: 既存資産マップ(v0.2 改訂)

| 必要機能 | 既存資産(再利用) |
|---|---|
| ベース基準座標 | `SourceVaultOOPSEnsureLoaded` / seed 辞書 / relation graph(read-only) |
| パラグラフ topic 付与 / 引用 / セッション | `SourceVaultAssignParagraphTopics` / `SourceVaultBuildMailQuoteEdges` / `SourceVaultBuildMailSessions` |
| 検索 / NB ハイパーテキスト | `SourceVaultMinedSearch` / `SourceVaultHybridSearch` / **`SourceVaultBuildSearchView`** + interaction meta-layer |
| セッション提案 | `SourceVaultMailSessionSuggest`(IdentityTags boost) |
| 観測記録 | ObjectInteractions(opt-in)/ `SourceVaultReplayObjectSignals` |
| 宛先認可(正準・不変更) | `SourceVaultResolveRecipientProfile`(fail-closed)/ `SourceVaultPlanMessageRelease` / `SourceVaultTagPolicyEvaluate` |
| LLM 思い込み検出 | Contract 層の幻 option 実行前拒否 / `SourceVaultAssessUncertainty` / `SourceVaultMakeMetacognitiveAssessment` |
| LLM ループ検出・停止 | ClaudeEval ループガード(同一署名再掲・MaxContinuations) |
| LLM containment | `SourceVaultEvaluateOutputGate` / `SourceVaultEvaluateActionGate` / Contract 層自動修復 |
| LLM authorization(正準・不変更) | model AccessProfile(TrustDomain / MaxAccessLevel。universal MCP access v2 §2.5) |
| プロンプト信号 | `SourceVaultClaudeCodeSessionDigest` / `SourceVaultIngestClaudeCodeLogs`(集約は端末内) |
| 秘匿 LLM 処理 | `SourceVaultQueryLocalLLM`(LM Studio・UNTRUSTED 隔離) |
| 通知 | diagnostics SIEM(自分宛固定・metadata only・rate limited)+ autotrigger |

## Appendix C: r1 レビュー対応表

| レビュー項目 | 反映箇所 |
|---|---|
| P0-01 保存先矛盾 | §2 I-1(SensitiveLocalVault 新設・CoreRoot rollup 撤回・専用 append API・sink matrix 試験)。受入 1,2 |
| P0-02 Hold=実質ブロック | §5.7 decision class 4 分類・TimedDefer 契約・shadow 先行。§2 I-2/I-6。受入 3,8,9 |
| P0-03 削除禁止の過剰適用 | §2 I-3 範囲限定+I-3b(retention/消去/`SourceVaultCognitionErase`)。受入 4 |
| P0-04 CognitiveLevel proxy の妥当性・循環 | §4.5 OperationalSupportSignal 改名・観測専用・共変量・self-report 前向き評価・返信遅延/見落としを入力から除外(§4.8 へ分離)。§8 昇格ゲート |
| P0-05 作成時レベル=信頼性の混同 | §4.3 三分離(AuthorOperationalContext / AssertionEvidence / ContentReliability)。local-only 参照 ID・既定非表示 |
| P0-06 trust の概念混同 | §4.6 5 面分解。RecipientAuthorization 正準維持。受入 7 |
| P1-01 オントロジ強制射影 | §1.1(名称)・§4.1(UnknownMass/Space/versioned alias/segment 単位/OwnerConfirmed 区別)。受入 5 |
| P1-02 position の provenance/privacy | §4.1 TopicEvidence/MaxInputPrivacyLevel、§2 I-1(cache を低機密としない) |
| P1-03 RecallLevel 推定不能 | §4.4 三分割・擬似 event 廃止(§2 I-9)。受入 6 |
| P1-04 newer=前進の単純化 | §4.7 ProgressScore・LoopScore 複合判定・理由表示・dismiss/snooze |
| P1-05 採番競合 | §4.2 ULID 正準+alias+CAS/merge/alias 履歴 |
| P1-06 risk taxonomy 欠如 | §5.7 taxonomy(主入力)。認知系は一入力 |
| P1-07 見落とし検出仕様なし | §4.8 Task/Commitment モデル(独立設計・循環回避) |
| P1-08 API 契約不足・関数名 | §6 共通契約(SubjectRef/AsOfUTC/Purpose/ReleaseContext/IncludeSensitive 既定 False/fail 区別/freshness)。`SourceVaultBuildSearchView` 表記修正 |
| P1-09 評価計画 | §8(指標・gold set・shadow 昇格条件) |
| §6 フェーズ再編 | §7(Phase 0 / 1A〜1E。C1〜C7 一括を廃止) |
| §7 受け入れ追加 12 項目 | §9 に全数取り込み(1〜12)+継続分(13,14) |
| (ユーザー指示)subject 汎用化 | §0 / §1.2 / §4.5 / §4.9 / §5.10(人⊕LLM 同一枠組み・介入格子・可用性行列) |
