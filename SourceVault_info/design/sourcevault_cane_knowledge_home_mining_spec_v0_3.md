# SourceVault Cane / Knowledge Home 認知支援マイニングレイヤー仕様 v0.3

- 作成日: 2026-07-12(v0.1)/ 更新日: 2026-07-12(v0.3)
- 状態: **Draft(r2 レビュー全反映。再レビュー待ち。Phase 0 / 1A〜1C は r2 判定で条件付き承認済み)**
- 本版 v0.3 の変更(r2 `sourcevault_cane_knowledge_home_mining_spec_v0_2_review.md` 全反映。対応表は Appendix D):
  1. **subject 汎用化の再設計(r2 P0-01/02)**: 「人と LLM は同型の CognitiveState」を撤回し、**共通なのは観測/介入の envelope・provenance・時系列・監査プロトコルのみ**とする三層構造へ変更。state projection は subject-kind 別の typed union(**HumanOperationalSupportProfile** / **LLMExecutionRiskProfile**)で、共通の数値次元・共通 Tier を持たない。Tier は用途名付き(`SupportNeedTier` / `ExecutionRiskTier` / `EvidenceConfidence`)で相互変換しない
  2. **LLM 参照の分解(P0-03)**: `svllm:<AccessProfileId>` を廃止。`ModelArtifactRef / DeploymentRef / AgentConfigurationRef / RunRef` を分離し、AccessProfile は authorization 専用に戻す。集約主キーは `AgentConfigurationRef × TaskDomain`
  3. **detector 発火 ≠ fault(P0-04)**: 観測(`LLMRiskSignalObserved`)/ 判定(`RiskSignalAdjudicated`)/ 介入結果(`InterventionOutcomeRecorded`)の三層 event に分離。failure mode は `HypothesizedFailureMode`(仮説ラベル)に留める
  4. **state-driven policy の shadow 昇格必須化(P0-05)**: 既存の決定的 gate は live 継続、**集約値による新しいモデル選択・検証深度 policy は shadow 昇格ラダーを通す**
  5. **既存 gate の coverage/failure mode の明文化(P0-06)**: GateCoverageRegistry(no-contract pass / fail-open / 誤検出)と risk class 別 degrade 方針
  6. **LLM telemetry の privacy を provenance 合成に(P0-07)**: 固定 0.85 を廃止。run の観測入力最大 PL/DenyTags union を継承、private run 分は local-only store へ。ExposureHistory は同期用と認知目的 local-only を目的分離
  7. **第三者人間の除外(P0-08)**: SubjectKind Human は P1/P2 で owner のみ。第三者は `CommunicationCounterparty`(identity/delivery/authorization/owner 申告 familiarity のみ)
  8. **人への介入ラダーの緩和化(P0-09)**: P1 既定は `SupportivePrompt / AskForConfirmation / ShowSourceOnRequest`。`EvidenceConfrontation` は保護策(topic 除外・cooldown・distress stop・質問への degrade・自動 escalation 禁止)付きで別途昇格
  9. **SensitiveLocalVault の実装契約(P1-01/02/03)**: 暗号化・鍵・secure erasure を Phase 0 必須 decision/DoD へ。消去は crypto-shredding+削除 manifest+削除後検査。bitemporal semantics(OccurredAt/ObservedAt/AdjudicatedAt/ComputedAt)導入。音声・映像 raw は**既定非保存**
  10. その他: task-mix 層別化と `Missing["InsufficientEvidence"]`(P1-04)、Outcome 学習の選択バイアス対策(P1-05)、containment の owner 透明性+`ExecutionContainment` 改名(P1-06)、ContentReliability の二重計上防止(P1-07)
- 対象・依拠資料・前提仕様: v0.2 と同じ(新規 `SourceVault_knowledgehome.wl` / `SourceVault_cognition.wl` + 既存拡張)

## 0. 目的と結論

**目的**(不変): oops メーリングリストをベース基準座標(Knowledge Home)とし、SourceVault の全データをトピックアイテム空間上に位置づけ、(1) 現在の思考位置の推定と近傍提案、(2) ループに陥らない前進支援、(3) 状態変動の推定に応じた検証レベル・提示粒度の制御による不可逆ミスの予防、(4) 送信先等の信頼度推定、を実現する。

**v0.3 で確定する中心思想(r2 の定式化を採用)**:

> 人と LLM を同じ認知主体として数値比較するのではなく、**異なる主体から得られる状態信号を、共通の provenance・時系列・介入監査プロトコルで扱う**。

すなわち共通化するのは次の三つ**だけ**である:

1. **観測 envelope**(`SubjectStateObservation`): 誰の・どの producer が・何を・いつ観測したかの外枠と bitemporal 時刻
2. **介入 envelope**(`SubjectInterventionDecision`): トリガ・リスク・選択肢・選択・結果の監査形式
3. **昇格プロトコル**: 新しい統計的 policy は subject 種別を問わず shadow → calibration → 限定昇格を通す

その内側の**状態の意味は共通化しない**。人の忘却は記憶の状態であり、LLM の context truncation は入力パイプラインの制約、knowledge cutoff は静的 artifact 属性であって、同じ「Forgetting」尺度に載らない(r2 P0-01)。人は `HumanOperationalSupportProfile`(支援必要度)、LLM は `LLMExecutionRiskProfile`(実行リスク)という別の typed projection を持ち、共通 Tier を返す API は存在しない。

ユーザー要求の本質 — 「思い込み状態の人や LLM に対して、証拠を示して指摘するか、上位レイヤーでエラーを止めるか」— はこの形で保持される: 介入選択(§4.9)は envelope 層の共通プロトコルであり、**可用性と表現だけが subject 種別で異なる**(LLM への ExecutionContainment は既存決定的 gate の継続として live、人へは緩やかな支援的介入から段階昇格、第三者へは介入しない)。

**段階方針**(r2 判定を反映): Phase 0(暗号化・消去方式を必須 decision に追加)と 1A〜1C は本仕様で着手可能。1D/1E は本版の三層構造・shadow ラダーを前提に着手する。

## 1. 概念モデルと用語

### 1.1 資料 → 本仕様マッピング(v0.3 改訂分のみ。他は v0.2 §1.1 のまま)

| 資料/論文の概念 | 本仕様の用語 | 備考 |
|---|---|---|
| cognitive level(subject の時刻依存状態) | 人(owner): **HumanOperationalSupportProfile**(P1 の観測面は OperationalSupportSignal)。LLM: **LLMExecutionRiskProfile** | 共通 CognitiveState 型は廃止。共通なのは envelope(§4.5.1) |
| ハルシネーション/思い込み/忘却/堂々巡り(LLM) | `HypothesizedFailureMode`(仮説ラベル)+ detector 観測/判定/結果の三層 event | 確定診断ラベルとして記録しない(P0-04) |
| execute/stop/camouflage | InterventionPolicy(§4.9)。LLM 側の吸収・停止は **ExecutionContainment** と呼ぶ(owner には透明) | 「camouflage の一般化」という呼称は LLM 側では使わない(P1-06) |
| 送信相手(第三者) | **CommunicationCounterparty**(§4.6b) | 第三者の状態推定は行わない(P0-08) |

### 1.2 subject の参照形式(v0.3 改訂)

```
SubjectRef(人):    "ent-..."。P1/P2 で SubjectKind -> "Owner" のみ。
                    第三者人間は subject ではなく CommunicationCounterparty(§4.6b)。

LLM/agent 側の参照(分離。P0-03):
  ModelArtifactRef      "svmodel:<provider>:<family>:<revision>"   (* immutable revision *)
  DeploymentRef         "svdeploy:<endpoint/quantization/runtime digest>"
  AgentConfigurationRef "svagentcfg:<digest>"   (* system prompt/directive set/toolset/
                                                   contract registry version/retrieval snapshot/
                                                   sampling config の合成 digest *)
  RunRef                "svrun:<id>"            (* 個々の実行・session *)
  AccessProfileRef      (既存。authorization 専用。上記から独立)
```

- **時系列集約の主キーは `AgentConfigurationRef × TaskDomain`**。per-run の信号は RunRef に紐づけて保持し、集約と混同しない。
- AccessProfile の TrustDomain/MaxAccessLevel は authorization の正準であり続け、ExecutionRiskProfile はこれを一切変更しない。

## 2. 不変条件(v0.2 からの差分中心。番号は継続)

**I-1. 保存境界(v0.3 改訂)**

| データ | 保存先(正準) | v0.3 変更点 |
|---|---|---|
| owner の認知系(OperationalSupportSignal/SelfReport/RecallAssessment/ThinkingContext/Familiarity/対人 InterventionDecision) | `SensitiveLocalVault`(専用 append API 経由のみ) | 変更なし |
| **LLM telemetry(RiskSignal/Adjudication/Outcome)** | **provenance 依存**: event の `Privacy` は当該 run の観測入力・出力・EvidenceRefs の最大 PL を継承し DenyTags を union(固定 0.85 を廃止)。**private run(観測 PL ≥ 0.5 または NoCloudLLM/PrivateBehaviorLog を含む)由来の telemetry は local-only store `<LocalState>/telemetry/llm/`** に置き、Dropbox/PrivateVault に作らない。非 private 分のみ通常 event store 可 | P0-07 |
| **ExposureHistory** | **目的分離**: 既存 ObjectInteractions(PrivateVault、importance/ranking 用途、既存規約のまま)と、**認知目的 feature set(local-only、SensitiveLocalVault、明示 opt-in 時に集約コピー)**を分ける。認知推定は後者のみを読む | P0-07 |
| 音声・映像 raw(P3) | **既定非保存**。ストリーム内特徴抽出のみ。明示 opt-in 時のみ短期保存(owner 設定 retention) | P1-01 |

**I-2. 単調安全性と介入の非対称(v0.3 改訂)** — 認知系/リスク系推定はいかなる authorization も緩めない。
- 人(owner)への介入は**支援的ラダー**(§4.9): P1 既定は `SupportivePrompt / AskForConfirmation / ShowSourceOnRequest` まで。`EvidenceConfrontation` は保護策付きで別途昇格。`SoftFriction`(確認追加/TimedDefer)は Guard 昇格規則に従う。人への containment(camouflage)は P3 倫理凍結(不変)。
- 第三者人間: **状態推定経路そのものを持たない**(P0-08)。システムは第三者に直接介入せず、owner への下書き支援に限る。
- LLM: 既存の**決定的 gate(契約検証・output gate・loop guard)は live 継続**。**集約 state による新 policy(モデル選択・検証深度変更)は shadow 昇格必須**(I-10)。

**I-3 / I-3b. ベース不変と retention・消去** — v0.2 のまま。ただし消去の実装方式を Phase 0 で確定する(§4.11): crypto-shredding(subject×期間別 data key)+ 削除 manifest(全派生物列挙)+ 削除後検査。best-effort の限界(OS レベル複製)は明示する。

**I-4〜I-8** — v0.2 のまま(gate 全経由 / bounded influence / ゆるい運用・owner controls / 可搬性 / FE 非ブロック)。

**I-9. 観測と推論の分離+bitemporal(v0.3 拡張)** — 観測 event は不変の事実のみ。推定は ModelVersion 付き projection。全 envelope は `OccurredAtUTC / ObservedAtUTC`(+判定は `AdjudicatedAtUTC`、projection は `ComputedAtUTC`、構成の有効期間は `ValidFrom/ValidTo`)を持ち、履歴照会は「当時利用可能だった情報での再現」と「現在の知見での再評価」を引数で区別する(§6)。

**I-10. state-driven policy の shadow 昇格(新設。P0-05)** — 決定的 rule(個々の違反をその場で止める既存 gate)と、統計的 policy(過去の集約値で将来の選択・コストを変える)を区別する。後者は subject 種別を問わず、次のラダーを通らずに live にしない:
```
(1) producer 接続 → (2) offline replay → (3) shadow recommendation
→ (4) task-domain 別 calibration → (5) 低リスク class での bounded A/B
→ (6) 昇格(高リスク class では人間確認 or 決定的 verifier を維持)
```

## 3. アーキテクチャ

```
L0 ベース基準座標        oopsseed(既存)
L1 Knowledge Home 層     【1A/1B】閲覧+非破壊追記
L2 位置づけ層            【1C】KnowledgeHomeTopicPosition
L3 思考文脈層            【1C】ThinkingContext + 近傍提案 + ProgressScore
L4 状態信号層            【1D】共通 envelope(SubjectStateObservation)
   ├ 人(owner):  HumanOperationalSupportProfile(shadow・local-only)
   └ LLM/agent:  LLMExecutionRiskProfile(層別集約・shadow ラダー)
L5 介入・ガード層        【1E】SubjectInterventionDecision + TaskValidationLevel + Commitment
```

L4 の二つの profile は**別型**であり、L5 の policy は必要な値を型ごとに明示的に受け取る(共通 Tier の暗黙変換をしない)。Phase 0 のデータフロー図は v0.3 の store 分離(telemetry local-only 分岐、ExposureHistory 目的分離)を含めて更新する。

## 4. データモデル

### 4.1〜4.4, 4.7, 4.8 — v0.2 のまま

(KnowledgeHomeTopicPosition / KH 追記と ULID 採番 / AuthorOperationalContextAtCreation / 想起系三分割 / ThinkingContext+ProgressScore / Task-Commitment。変更なし。)

### 4.5 状態信号の三層構造(v0.3 全面改訂)

#### 4.5.1 共通層: 観測・介入 envelope【1D】

```
SourceVaultSubjectStateObservation(event の外枠。全 subject 共通):
<|SubjectRef | AgentRefs -> <|ModelArtifactRef, DeploymentRef, AgentConfigurationRef, RunRef|>,
  SubjectKind -> "Owner"|"LLM",
  ObservationKind,                  (* subject-kind 別語彙(下記) *)
  ProducerRef, EvidenceRefs, TaskContextRef,
  OccurredAtUTC, ObservedAtUTC,     (* bitemporal *)
  Confidence, Privacy, Tags, SchemaVersion|>

SourceVaultSubjectInterventionDecision(§4.9 の監査形式。全 subject 共通):
<|SubjectRef|AgentRefs, SubjectKind, TriggerObservationRefs, RiskClass,
  AvailableActions, ChosenAction, PolicyVersion, ShadowMode,
  SelectionBasis -> <|Features, Rule|Probability|>,       (* P1-05: 選択バイアス記録 *)
  Outcome -> "Accepted"|"Overridden"|"Ineffective"|"CounterfactualUnavailable"|Missing,
  Cost, DecidedAtUTC|>
```

共通なのはこの外枠と保存・照会・監査 API だけである。**共通の数値次元・共通 Tier は存在しない。**

#### 4.5.2 人間 subject 層(owner のみ)【1D shadow】

```
projection: SourceVaultHumanSupportProfile[ownerRef, opts] ->
<|ObservableSignals -> <|RetryLoopRate, PromptEditRate, LateHourRate, ...|>,
                                    (* 個人内ベースライン偏差+共変量。観測可能事実のみ *)
  SelfReport,                       (* CognitiveSelfReported の系列 *)
  SupportNeedEstimate -> <|SupportNeedTier -> "Low"|"Medium"|"High", Confidence|>,
                                    (* 「支援必要度」。能力の高低ではない。P1 は shadow surface のみ *)
  Window, BaselineVersion, ModelVersion, Freshness|>
```

- clinical label を持たない。「認知レベル」「認知能力」の語は妥当性確認(§8)まで UI・API に出さない。
- 返信遅延・締切見落としは入力に使わない(Commitment へ分離。v0.2 のまま)。
- ObservationKind(人): `PromptRetryLoop` / `PromptHeavyEdit` / `LateHourActivity` / `SelfReport` / `RecallAssessed` 等。

#### 4.5.3 LLM/agent 層【1D 先行トラック(ただし I-10 のラダー適用)】

**三層 event(P0-04)**:

```
event 1: LLMRiskSignalObserved          (* detector が発火したという事実。fault ではない *)
<|AgentRefs, ObservationKind ->
    "ContractViolation"|"SelfConsistencyDivergence"|"CitationFailure"|
    "ContextTruncation"|"StaleKnowledgeSuspected"|"NearDuplicateResponseLoop"|
    "ContinuationBudgetExhausted"|"OutputGateRejection"|"JudgeRefutation",
  HypothesizedFailureMode -> "Confabulation"|"Forgetting"|"Looping"|"Other"|Missing,
                                         (* 仮説ラベル。確定診断ではない *)
  DetectorVersion, RunRef, TaskDomain, RiskClass, EvidenceRefs,
  OccurredAtUTC, ObservedAtUTC, Privacy(provenance 合成。I-1)|>

event 2: RiskSignalAdjudicated           (* owner・決定的テスト・独立 verifier による判定 *)
<|TargetObservationRefs, Verdict -> "Confirmed"|"FalsePositive"|"Unknown",
  AdjudicatorKind -> "Owner"|"DeterministicTest"|"IndependentVerifier",
  AdjudicatedAtUTC, EvidenceRefs|>

event 3: InterventionOutcomeRecorded     (* 停止・再生成・切替後に改善したか *)
<|InterventionDecisionRef, Improved -> True|False|Missing, Metrics, RecordedAtUTC|>
```

**projection(層別集約。P1-04)**:

```
SourceVaultLLMExecutionRisk[agentConfigRef, "TaskDomain"->d, opts] ->
<|DetectorRates,                    (* 発火率(観測) *)
  ConfirmedErrorRates,              (* Adjudication で Confirmed になった率 *)
  FalsePositiveRates,
  ContextAndToolFailures, LoopGuardEvents,
  ExecutionRiskTier -> "Low"|"Medium"|"High" | Missing["InsufficientEvidence"],
  SampleCount, ConfidenceInterval, Freshness,
  Strata -> <|TaskDomain, RiskClass, Toolset, RetrievalAvailable, Language, ContextLengthBand|>|>
```

- **層別化必須**: `TaskDomain / RiskClass / Toolset / RetrievalAvailable / Language / ContextLengthBand`。global tier を作らない。サンプル不足は `Missing["InsufficientEvidence"]`(0 や Low と区別)。
- detector 発火率と confirmed error 率は常に別フィールド。policy が参照すべき既定は confirmed 系+CI。

### 4.6 信頼度の 5 面分解 — v0.2 のまま。ただし:

### 4.6b CommunicationCounterparty(新設。P0-08)【1E 最小】

第三者人間は状態推定の subject にしない。持ってよい情報は:

```
<|CounterpartyRef -> "ent-..."|"idf-...",
  IdentityAssurance, DeliveryAssurance,          (* 既存 identity/配送層の事実 *)
  RecipientAuthorization,                        (* 既存 ContactAccessProfile(正準) *)
  OwnerDeclaredFamiliarity,                      (* owner の明示申告のみ。推定しない *)
  InteractionFacts|>                             (* 交信の存在・頻度等の客観事実 *)
```

- メール文面・応答パターンからの第三者の忘却/思い込み/認知変動の推定経路は**実装しない**(受け入れ基準)。将来、本人がシステム参加者となり、目的への明示同意・閲覧/訂正/停止/消去の権利・データ ownership 分離が成立した場合のみ、別仕様で SubjectKind を拡張する。

### 4.9 InterventionPolicy(v0.3 改訂)【1E】

```
InterventionKind(人・owner 向けラダー。下ほど強い):
  "ObserveOnly"            (* 既定(shadow) *)
  "SupportivePrompt"       (* 非侵襲の支援的提示(関連ノードを静かに出す) *)   ← P1 上限(既定)
  "AskForConfirmation"     (* 「〜で合っていますか?」と確認を求める *)          ← P1 上限(既定)
  "ShowSourceOnRequest"    (* 求めに応じて出典・過去記録を提示 *)               ← P1 上限(既定)
  "EvidenceConfrontation"  (* 齟齬の能動的指摘。保護策(下記)付きで別途昇格 *)
  "SoftFriction"           (* 確認追加・TimedDefer。Guard 昇格規則に従う *)
  ("HigherLayerContainment" は人に対して存在しない。P3 倫理仕様まで実装禁止)

InterventionKind(LLM 向け):
  "ObserveOnly" / "EvidenceInjection"(反証注入・出典要求・再生成)
  "VerificationDeepening"(検証チェーン深化)
  "ExecutionContainment"(遮断・破棄・再試行・別モデル切替。旧称 HigherLayerContainment)
```

- **人への EvidenceConfrontation の保護策(P0-09。昇格の前提条件)**: `DoNotConfrontTopics` / `DoNotSurfaceEvidenceRefs` の owner 設定、wording/強度の owner 選択、distress・拒否の即時停止 signal、同一指摘の cooldown、証拠確度不足時は質問(`AskForConfirmation`)へ degrade、医療・家族連絡への自動 escalation 禁止。
- **ExecutionContainment の owner 透明性(P1-06)**: LLM に対しては非表示でよいが、**owner には** 遮断・修復・再生成・切替の事実、policy reason と detector confidence、最終出力の provenance、追加コスト・遅延、(安全に保持できる場合)元出力の監査参照、fallback 全滅時の明示エラー、を表示する。owner に黙って出力を差し替えない。
- Outcome 学習(P2)は `SelectionBasis`(policy version・features・選択規則/確率・cost・counterfactual 可否)の記録を前提とし、探索的 A/B は低リスク task に限定、高リスクは固定 policy。**人への介入の自動最適化は別の同意・倫理設計なしに行わない**(P1-05)。

### 4.10 event class 一覧(v0.3)

通常 store: KH 系(v0.2 のまま)/ `LLMRiskSignalObserved`(非 private run 分)/ `RiskSignalAdjudicated` / `InterventionOutcomeRecorded` / `TrustEvidenceRecorded(Identity/Delivery)` / Commitment 系 / `GuardDecisionRecorded`(内容最小化)/ `SubjectInterventionDecision(対 LLM・非 private)`。
local-only telemetry(`<LocalState>/telemetry/llm/`): private run 由来の LLM 三層 event。
SensitiveLocalVault: `OperationalSignalSampled` / `CognitiveSelfReported` / `RecallAssessed` / `ThinkingContextSnapshotted` / `FamiliarityObserved(owner 申告)` / `SubjectInterventionDecision(対人)` / 認知目的 ExposureHistory feature set。

### 4.11 SensitiveLocalVault 実装契約(新設。P1-01/02。**Phase 0 必須 decision**)

- **暗号化**: threat model を Phase 0 で確定する。最低ライン = OS フルディスク暗号化(BitLocker)必須+アプリ層で subject×期間別 data key による暗号化(crypto-shredding 前提)。鍵は OS 資格情報ストア(DPAPI)に保存し、rotation・recovery(recovery key の紙保管等 owner 選択)・端末廃棄手順・**鍵喪失時は当該データを復元不能として扱う**(仕様上の明示)を定義。
- **漏洩面の除外**: crash dump・swap・Windows Search index・antivirus クラウド提出・OS/クラウドバックアップ・Dropbox selective sync からの除外設定を Phase 0 の DoD に含め、sink matrix 試験の対象にする。
- **消去(P1-02)**: subject×期間別の小 shard+per-shard data key。`SourceVaultCognitionErase` は (1) 削除 manifest(events/index/projection/cache/temp/鍵の全派生物列挙)を生成 → (2) data key 破棄(crypto-shredding)+ファイル削除 → (3) 削除後検査(manifest 全項目の不存在確認)→ (4) best-effort の限界(OS レベルの残存複製)を owner に表示。
- **bitemporal(P1-03)**: §2 I-9 の時刻群を全認知系 event/projection に必須化。

## 5. 機能仕様(v0.3 差分)

### 5.1〜5.6, 5.8, 5.9 — v0.2 のまま

### 5.7 Guard(v0.3 追補)

v0.2 の decision class 4 分類・risk taxonomy・shadow 先行は不変。追加:

- **GateCoverageRegistry(P0-06)**: 既存 gate の適用範囲と failure mode を registry 化し、policy から参照可能にする:

| Gate | Coverage | Failure mode(明記) |
|---|---|---|
| Function Contract 検証 | **contract を持つ関数のみ**。契約外関数は既定 pass | validator hook 不在・例外・timeout・非 Association は **fail-open** |
| Output gate | 定義済み adapter/action policy の範囲のみ。意味的誤答は非網羅 | policy 未定義 sink は既定拒否だが評価自体の網羅性はない |
| ClaudeEval loop guard | 連続する近似署名応答という狭い detector | 有用な反復の false positive がありうる |
| MaxContinuations | 予算上限であり looping の診断ではない | 到達 event は `ContinuationBudgetExhausted` として記録(Looping と自動同定しない) |

- **risk class 別 degrade 方針**: 高リスク action(Irreversible×Public/Financial 等)では、検証 hook の timeout/例外を fail-open にせず、**決定的 deny または人間確認へ degrade** する。低リスクは現行 fail-open を許容(コスト優先)。degrade 表は Phase 0 の contract に含める。

### 5.10 LLM 実行リスクへの適用(v0.3 全面改訂)

1. **live 継続(変更なし)**: 契約検証・output gate・loop guard など**個々の違反をその場で止める決定的 rule** は従来どおり動き続ける。本仕様はそれらを三層 event の producer として記録に接続するだけで、動作を変えない。
2. **新規の state-driven policy は shadow ラダー(I-10)**: 「過去の発火率の集約でモデル選択・検証深度・ルーティングを変える」ことは新しい統計 policy であり、producer 接続 → offline replay → shadow recommendation → task-domain calibration → 低リスク bounded A/B → 昇格、の順を踏む。昇格後も高リスク class は人間確認/決定的 verifier を維持。
3. **判定の分離**: policy が既定で参照するのは ConfirmedErrorRates(+CI)。DetectorRates のみでの切替は shadow 段階に限る。self-consistency 分散・contract violation 単独を confirmed confabulation として記録しない(adjudication を経る)。
4. **ContentReliability との関係(P1-07)**: ContentReliability は claim-specific evidence が主。生成時の ExecutionRiskProfile は (a) evidence が無い場合の provenance metadata、または (b) calibration prior としてのみ使い、適用条件(task-domain calibration 済み・minimum sample)、evidence 到着時の posterior 更新、**同一 detector event の二重計上防止(EvidenceRefs での dedup)** を実装する。
5. **透明性**: ExecutionContainment の owner 表示(§4.9)。

## 6. Public API(v0.3 差分)

共通契約(v0.2)に追加: 履歴照会は `"AsOfUTC"`(対象時点)+ `"KnowledgeAsOfUTC"`(その時点までに観測/判定された情報のみ使うか、現在の知見で再評価するか。既定 = 現在)を区別する(P1-03)。

```
(廃止) SourceVaultCognitiveState[subjectRef, ...]        (* 共通型を返す API は存在しない *)

SourceVaultSubjectObservations[subjectOrAgentRefs, opts]  (* envelope 照会(共通) *)
SourceVaultHumanSupportProfile[ownerRef, opts]            (* typed projection(人・owner) *)
SourceVaultLLMExecutionRisk[agentConfigRef, "TaskDomain"->d, opts]
                                                          (* typed projection(LLM)。層別必須、
                                                             不足時 Missing["InsufficientEvidence"] *)
SourceVaultRecordRiskSignalAdjudication[obsRefs, verdict, opts]
SourceVaultInterventionPlan[subjectOrAgentRefs, trigger, opts]   (* ラダー・可用性・保護策を強制 *)
SourceVaultGateCoverage[gateName]                         (* GateCoverageRegistry 照会 *)
SourceVaultCounterparty[ref]                              (* §4.6b。状態推定を含まない *)
```

他(knowledgehome 側、CognitionControls/Erase 等)は v0.2 のまま。`SourceVaultCognitionErase` は §4.11 の manifest+crypto-shredding+削除後検査を実装する。

## 7. フェーズ(v0.3 差分)

- **Phase 0(追加 DoD)**: §4.11 の暗号化・鍵・除外・消去方式の decision record と実装、GateCoverageRegistry と risk class 別 degrade 表、bitemporal スキーマ、telemetry の provenance privacy 分岐、データフロー図の v0.3 化。
- **Phase 1A〜1C**: 変更なし(r2 で条件付き承認)。
- **Phase 1D**: 人(owner)= OperationalSupportSignal の shadow(v0.2 のまま、ただし認知目的 ExposureHistory の目的分離)。LLM = 三層 event の producer 接続と offline replay・shadow recommendation まで(**「shadow 不要」を撤回**。live なのは既存決定的 gate のみ)。
- **Phase 1E**: Guard shadow(v0.2 のまま)+ state-driven policy の calibration/bounded A/B(低リスク class)。人への介入は SupportivePrompt/AskForConfirmation/ShowSourceOnRequest の範囲で soft 昇格、EvidenceConfrontation は保護策実装+別評価の後。
- **Phase 2/3**: v0.2 のまま+第三者 subject 化は「本人参加+明示同意+権利保障+ownership 分離」を満たす別仕様としてのみ(P3 以降)。

## 8. 評価計画(v0.3 追補)

v0.2 の表に追加:

| 対象 | 指標 | ゲート |
|---|---|---|
| LLM risk profile | 層別(TaskDomain 等)の DetectorRates vs ConfirmedErrorRates の calibration、FalsePositiveRates、CI 幅 | state-driven policy の shadow→A/B 昇格条件。層別サンプル不足時は昇格不可 |
| adjudication | 判定率(Unknown 滞留の監視)、adjudicator 間一致 | ConfirmedErrorRates の信頼性前提 |
| intervention outcome | SelectionBasis 記録率 100%、低リスク A/B の効果推定、counterfactual unavailable の明示率 | Outcome 学習(P2)の解禁条件 |
| owner 介入 | SupportivePrompt/AskForConfirmation の受容率・distress stop 発生率・cooldown 違反ゼロ | EvidenceConfrontation 昇格条件 |
| 消去 | 削除 manifest 網羅率、削除後検査 green、鍵破棄の検証 | Phase 0 DoD・恒常 |

## 9. 受け入れ基準(v0.3 統合版)

v0.2 の 1〜14 を維持(ただし 14 の「CognitiveState」は「ExecutionRiskProfile」に読み替え)し、以下を追加:

15. 共通 Tier を返す API が存在せず、state projection が SubjectKind 別の typed union であること(`SupportNeedTier`/`ExecutionRiskTier`/`EvidenceConfidence` は相互変換されない)
16. `AccessProfileRef` と `ModelArtifactRef/DeploymentRef/AgentConfigurationRef/RunRef` が分離され、authorization が AccessProfile のみで決まること
17. detector observation / adjudication / intervention outcome が別 event であり、self-consistency 分散や contract violation 単独が confirmed 扱いで記録されないこと
18. 既存決定的 gate の live 継続と、新しい state-driven policy の shadow 昇格ラダー(I-10)が分離されていること
19. GateCoverageRegistry(no-contract pass / fail-open / false positive を含む)が policy から参照でき、高リスク action の hook timeout が fail-open にならないこと
20. LLM telemetry の Privacy/Tags が run の観測入力・出力・EvidenceRefs の最大値/union を継承し、private run の telemetry が Dropbox/PrivateVault に作られないこと
21. 認知目的の ExposureHistory feature set が local-only store に目的分離されていること
22. 第三者人間の状態推定経路が(明示同意の別仕様なしには)存在しないこと
23. owner への EvidenceConfrontation に topic 除外・cooldown・distress stop・質問への degrade があり、P1 既定の介入上限が SupportivePrompt/AskForConfirmation/ShowSourceOnRequest であること
24. SensitiveLocalVault への最初の書込み前に、暗号化・鍵管理・backup/index/swap 除外が確定していること(Phase 0 DoD)
25. 音声・映像 raw が既定非保存であること
26. subject/期間消去が削除 manifest(全 shard/index/cache/temp/key)を列挙し、削除後検査を行うこと
27. LLM profile が task-domain 別に calibration され、サンプル不足時に `Missing["InsufficientEvidence"]` を返すこと(global tier を作らない)
28. ExecutionContainment が LLM に非表示でも、owner には decision/provenance/cost が表示されること
29. 履歴照会が event time と observation/adjudication time を区別すること(bitemporal)

## 10. Open issues(v0.3)

1. OperationalSupportSignal→支援必要度表示への昇格条件の定量化(継続)
2. 人への camouflage の倫理仕様(P3。継続)
3. 認知系マルチデバイス同期の別仕様(継続)
4. `AgentConfigurationRef` digest の構成要素粒度(system prompt の軽微変更で別 config になりすぎないか — 正規化規則の設計)
5. adjudication の運用コスト: owner 判定に頼りすぎない decision test / independent verifier の整備順序
6. TaskDomain 分類の初期語彙(コード/検索/要約/翻訳/計画…)と自動付与の精度
7. Commitment の「返信すべきメール」初期規則(継続)/ cluster 境界(継続)
8. local-only telemetry store のサイズ管理(retention と集約のバランス)

## Appendix A/B — v0.2 のまま(Appendix B の containment 行は GateCoverageRegistry の限定つきで読む)

## Appendix C — r1 対応表(v0.2 に収録。変更なし)

## Appendix D: r2 レビュー対応表

| r2 項目 | 反映箇所 |
|---|---|
| P0-01 共通次元は成立しない | §0(中心思想の言い換え採用)/ §4.5 三層構造(envelope+typed projection)/ 受入 15 |
| P0-02 Tier の方向曖昧 | 共通 Tier 廃止。`SupportNeedTier`(人)/`ExecutionRiskTier`(LLM)/`EvidenceConfidence` に分離・相互変換禁止(§4.5.2/4.5.3、受入 15) |
| P0-03 AccessProfileId はモデル ID でない | §1.2 参照分解(ModelArtifact/Deployment/AgentConfiguration/Run)。集約主キー=AgentConfigurationRef×TaskDomain。AccessProfile は authorization 専用(受入 16) |
| P0-04 detector 発火 ≠ fault | §4.5.3 三層 event(Observed/Adjudicated/Outcome)、`LLMRiskSignalObserved` 改名、HypothesizedFailureMode(受入 17) |
| P0-05 集約 policy に shadow 必須 | §2 I-10 昇格ラダー / §5.10(「shadow 不要」撤回。live は決定的 gate のみ)(受入 18) |
| P0-06 containment 適用範囲の過大評価 | §5.7 GateCoverageRegistry+risk class 別 degrade(高リスクは fail-open 禁止)(受入 19) |
| P0-07 telemetry 固定 0.85 不可 | §2 I-1 provenance 合成+private run は local-only store+ExposureHistory 目的分離(受入 20,21) |
| P0-08 第三者を subject にしない | §1.2 / §4.6b CommunicationCounterparty(受入 22) |
| P0-09 EvidenceConfrontation は上限でない | §4.9 支援的ラダー(P1 既定 = SupportivePrompt/AskForConfirmation/ShowSourceOnRequest)+保護策(受入 23) |
| P1-01 暗号化を Phase 0 必須に | §4.11(threat model/鍵/除外/鍵喪失)+音声・映像 raw 既定非保存(受入 24,25) |
| P1-02 物理削除方式 | §4.11 crypto-shredding+削除 manifest+削除後検査(受入 26) |
| P1-03 bitemporal | §2 I-9 拡張+§6 `KnowledgeAsOfUTC`(受入 29) |
| P1-04 task mix 補正 | §4.5.3 層別集約+CI+`Missing["InsufficientEvidence"]`(受入 27) |
| P1-05 Outcome 学習の選択バイアス | §4.5.1 SelectionBasis / §4.9(低リスク A/B 限定・人は自動最適化しない) |
| P1-06 owner 透明性 | §4.9 ExecutionContainment 改名+owner 表示要件(受入 28) |
| P1-07 ContentReliability 二重計上 | §5.10-4(claim evidence 主・prior 条件・dedup) |
| §7 受入 17 項目 | §9 の 15〜29 に統合 |
| §8 最小修正 12 項目 | 上記各行+§7 Phase 差分に反映 |
