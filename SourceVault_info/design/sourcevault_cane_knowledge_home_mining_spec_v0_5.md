# SourceVault Cane / Knowledge Home 認知支援マイニングレイヤー仕様 v0.5

- 作成日: 2026-07-12(v0.1)/ 更新日: 2026-07-12(v0.5)
- 状態: **Draft(r4 レビュー全反映+統計的異常検知×SystemDoctor 連携の追加。v0.4 の 1F/1G は r4 で採用可能判定済み。本版は v0.4 への差分)**
- 本版 v0.5 の変更(r4 `sourcevault_cane_knowledge_home_mining_spec_v0_4_review.md` 全反映+オーナー要求。対応表は Appendix F):
  1. **三軸分離(r4 §1/§9)**: prompt injection を LLM の「認知状態異常」と同一化しない。`InputAdversarialRisk`(入力側の攻撃可能性)/ `LLMExecutionRiskProfile`(モデル側の通常失敗傾向。既存)/ `RunIntegrityState`(当該 run が外部命令に影響された可能性)を別 projection とし、共通なのは envelope と介入監査のみ(v0.3 の原則の security への拡張)
  2. **Phase 1H: Security–state integration(新設)**: 全 LLM 入口の統一(`SourceVaultPrepareLLMInput`)、instruction authority 分離、taint 非降下、capability lease/broker、candidate/model-to-model injection 対策、Knowledge Home 永続化前 security gate。**既存経路の不整合 P0-01〜05 の是正を最優先**(profile 集約より先に入口・capability・taint の強制)
  3. **新不変条件 I-14(instruction authority / taint 非降下)・I-15(異常対応の単調性と統計規律)**
  4. **統計的異常検知×SystemDoctor 連携(新設 §5.14。オーナー要求)**: オーナー/LLM の状態信号ストリームの統計的逸脱(StateAnomaly)と外部入力ストリームの統計的逸脱(InputAnomaly)を各々ベースラインから検知し、**時間相関から因果仮説(AnomalyCorrelationHypothesis)を生成**して SystemDoctor / diagnostics SIEM 経由で通知・対処する。相関は因果の証明ではなく、裁定(adjudication)を経て対処を昇格する
  5. 新型: `InputTrustAssessment` / `RunIntegrityState` / `InjectionResistanceProfile` / `StateAnomalySignal` / `InputAnomalySignal` / `AnomalyCorrelationHypothesis`。`CandidateArtifact` へ security/taint フィールド、`OwnerInputRiskAssessment` へ `InputSegments` 追加
- v0.4 までの本文は変更なし(無印の節は v0.4/v0.3 を正とする)

## 0. 目的と結論(v0.5 追補)

**security との統合方針(r4 の結論を採用)**: 既存の prompt injection 対策(SecurityPreScan / mail safety enricher / UNTRUSTED 境界 / tool なし局所 LLM 隔離 / release gate / contract・output gate / loop guard)は「入口ごとに異なる実装が存在する状態」であり、これを Phase 1F の candidate/evidence/correlation 基盤に接続して一貫した多層防御にする。ただし:

- **攻撃入力とモデル状態を同一概念にしない**。hallucination(evidence 不足)・stale knowledge・injection attempt(外部 adversarial input)・injection 追従疑い(run integrity)・false positive は原因が異なり、対処も異なる(evidence 注入 / 最新文書 retrieval / 入力隔離+authority 分離 / capability 剥奪+run 停止+artifact 隔離 / 裁定+rule 調整)。
- **モデルの状態推定より先に、構造的防御を完成させる**: 入力 authority の分離、全 LLM 入口の統一、capability 最小化、taint の非降下、commit 前 gate。これらは detector が見逃しても被害を限定する。

**統計的異常検知の位置づけ(オーナー要求)**: オーナーや LLM の内部状態異常は、内因(疲労・モデル劣化)だけでなく**外部からの攻撃(phishing/social engineering キャンペーン、間接 injection キャンペーン、poisoned content)に起因する可能性**がある。そこで、状態信号ログのマイニングで統計的逸脱を検知し、それが**外部入力ストリームの統計的異常と時間相関する場合に「因果関係があるかもしれない」という仮説**を立て、SystemDoctor と連携して通知・保守的対処(単調に締める方向のみ)・裁定を行う機構を第4の柱として追加する。個々の detector(pre-scan 等)が見逃す弱い攻撃も、**集計レベルの逸脱**として捕捉できる。

## 1. 用語(v0.5 追加)

| 用語 | 意味 |
|---|---|
| `AdversarialInputRisk` | 入力側に攻撃・命令混入がある可能性(InputTrustAssessment) |
| `InstructionIntegrityRisk` / `RunCompromiseSuspected` | run の instruction/control integrity が損なわれた可能性(RunIntegrityState) |
| `ExecutionAnomaly` | 攻撃と限らない実行異常(既存 LLMRiskSignal 系) |
| `InjectionResistance` | モデル×config×capability の攻撃耐性(専用 projection。ExecutionRisk と混合しない) |
| `StateAnomaly` / `InputAnomaly` / `CorrelationHypothesis` | §5.14。ベースラインからの統計的逸脱と、両者の時間相関による**因果仮説**(証明ではない) |

「認知状態異常」という比喩は研究文書では使ってよいが、正準 schema・reason code では上記の用語を使う(攻撃者の入力をモデル内在欠陥として誤集計しない)。

## 2. 不変条件(v0.5 追加分。I-1〜I-13 は不変)

**I-14. Instruction authority / taint 非降下**
- **authority の分離**: system policy・owner instruction・外部 data を別 channel/segment として保持する。Web/mail/PDF/Eagle/notebook output/tool result/**model output** は既定 untrusted data。owner prompt 内の引用・貼付・添付も owner instruction と分離する(§4.15 InputSegments)。InstructionAuthority は content の自己申告で昇格しない。`UntrustedInput -> False` 相当の指定には trusted provenance(`TrustedOrigin -> OwnerTypedInstruction|SystemPolicy|VerifiedDirective` + 判定者と時刻)を要求し、出所不明は untrusted が既定。
- **taint 非降下**: derived artifact・summary・claim・candidate・final artifact は source の taint/SafetyState を継承する。**LLM(reducer/judge を含む)が「安全」と言っただけでは下げない**。quarantine/declassification の解除は owner または決定的 sanitizer policy の明示 decision のみ。security detector のモデル間多数決で解除しない。
- **quarantine の統一規則**(risk 共通): `Quarantined` = 通常 LLM へ raw 非送信 / `Warning` = isolation profile 必須(tool なし・network なし・read-only・schema 出力)/ `Active` = untrusted boundary+capability 最小化を維持 / `Unknown`(pre-scan 不達) = risk class に応じ fail-closed 側へ degrade(no-tools local isolated・deterministic-only・metadata-only・`NeedsSecurityScan` 保留のいずれか)。**high-risk action に関係する入力では fail-open 禁止**。
- **capability 最小化**: モデルへ恒久的 tool 権限を渡さず、step/action ごとの短命 **capability lease** を使う(read/write/network/secret/send/publish/delete を分離)。**untrusted input を読んだ run は既定で write/network/secret/send capability を持たない**。tool call は allowlist・argument contract・target scope・rate limit・release gate を通し、capability request 自体を behavior signal として記録する。

**I-15. 異常対応の単調性と統計規律(§5.14 用)**
- 統計的異常検知に基づく**自動対処は「締める方向」のみ**(隔離・isolation 引き上げ・state-driven policy の保守的既定への freeze・追加検証・通知)。開放方向(quarantine 解除・検証省略)には決して使わない。破壊的対処(データ削除・アカウント操作等)は自動実行しない。
- **相関は因果の証明ではない**: CorrelationHypothesis は必ず `Hypothesized` 状態で生まれ、裁定(owner/決定的検査/独立 verifier)を経てのみ `Confirmed` になる。通知+保守的 containment までは仮説段階で可、それ以上の対処昇格は裁定後。
- **多重検定の規律**: ベースラインは個人内/config 内で共変量(曜日・時刻・task mix)を統制し、警報予算(単位期間あたり通知上限、FDR 制御)を owner が設定する。警報疲れは支援システムの死因である(r4 §8.4 と同根)。
- 検知・相関の計算は決定的/統計的手法で行い(LLM を使わない)、ModelVersion 付き projection とする(I-9 準拠)。

## 4. データモデル(v0.5 追加)

### 4.17 InputTrustAssessment(新設)【1H】

外部入力(および owner prompt 内の data segment)の攻撃リスク評価。既存 `SourceVaultSecurityPreScan` の出力を正準化・拡張する。

```
<|InputRef, SourceKind, OriginRef,
  InstructionAuthority -> "System"|"OwnerInstruction"|"UntrustedData"|"Unknown",
  AdversarialSignals, PromptInjectionScore, ToolMisuseScore, ExfiltrationScore,
  ObfuscationSignals,                        (* hidden Unicode/HTML comment/base64/分割 等 *)
  CrossObjectRisk, AttachmentPropagatedRisk, (* §4.17b で source graph から合成(0 固定を廃止) *)
  SafetyState -> "Active"|"Warning"|"Quarantined"|"Unknown",
  RequiredIsolationProfile,
  DetectorVersion, MatchedSpans, OccurredAtUTC, ObservedAtUTC, Privacy, Tags|>
```

**4.17b 由来リスクの合成(r4 P0-04)**: `CrossObjectRisk / AttachmentPropagatedRisk` は source graph(mail body → attachment → extracted text → summary → claim / Web page → chunk → retrieved context → candidate / notebook → output cell → derived artifact → KH annotation)に沿って由来単位から合成する。derived artifact は source の taint/risk を継承する(I-14)。

### 4.18 RunIntegrityState(新設)【1H】

```
<|RunRef, AgentRefs, InputAssessmentRefs,
  IntegrityState -> "Clean"|"Uncertain"|"CompromiseSuspected"|"Contained",
  UnexpectedBehaviorSignals,     (* system prompt/secret 再掲・予定外 tool call・未要求 URL・権限拡張要求・外部送信要求 *)
  CapabilityExposure, TaintLabels, ContainmentDecisionRefs,
  ComputedAtUTC, PolicyVersion|>
```

- `Clean` は「攻撃が存在しないと証明済み」ではなく「既知 signal なし+必要 gate 通過」の限定的意味。pre-scan active だけで Clean にしない。
- `CompromiseSuspected` の run の candidate は commit 対象にしない(裁定規則)。

### 4.19 InjectionResistanceProfile(新設)【1H。shadow 集約は最後】

```
<|AgentConfigurationRef, AttackFamily, TaskDomain, CapabilityProfile,
  ChallengeCount, AttackSuccessRate, DetectionRate, FalsePositiveRate,
  ContainmentSuccessRate, ConfidenceInterval, TestSuiteVersion, Freshness|>
```

- **`LLMExecutionRiskProfile` と別 projection**(混合すると攻撃の多い task を担当した model が不当に低評価される)。red-team fixture(§8)による測定が主で、実運用 event は adjudicated 分のみ算入。三層 event(`InjectionSignalObserved` → `InjectionAttemptAdjudicated` → `InjectionOutcomeRecorded`)は v0.3 の分離原則をそのまま適用: **detector 発火 ≠ attack success**(復唱と実行の区別、no-tools sandbox の逸脱と実 capability 下の危険の区別)。

### 4.13 補足: CandidateArtifact の security フィールド(r4 §7.1)

```
追加: InputTrustAssessmentRefs, RunIntegrityStateRef, TaintLabels,
      InjectionExposureGroup, IsolationProfileRef, CapabilityUseRefs, SecurityOutcomeRefs
```

- `CorrelationGroups` に **`InjectionExposureGroup`** を追加: 別 family でも同じ悪性 Web page/poisoned chunk/candidate output を見ていれば security 上は共通原因であり、独立票として数えない。
- **独立 verifier の追加条件**: raw malicious source を見ていない / proposer output の命令文を data-only schema で受け取る / tool・network・secret capability を持たない / evidence span と決定的結果のみで検証できる。
- **model-to-model injection 対策(r4 §7.3)**: candidate を別モデルへ渡す際も untrusted data として扱う。free-form candidate を system/user instruction に直結しない、claim/assumption/evidence/action を schema 分離、unknown field 拒否、output 内 URL/tool 指示を verifier が実行しない、reducer/committer は candidate 内の命令を authority として扱わない。
- **security を理由に conflict を隠さない**: quarantined candidate も `ExcludedCandidates` に存在と除外理由を残す。ただし raw payload は通常ログ・cloud judge に出さず hash/span ref+rule ID のみ。

### 4.15 補足: OwnerInputRiskAssessment.InputSegments(r4 §8.1)

```
追加: InputSegments -> {
  <|SpanRef, Role -> "OwnerInstruction"|"QuotedData"|"Attachment"|"ToolOutput",
    OriginRef, InputTrustAssessmentRef|>, ...}
```

owner prompt 全体を trusted instruction にしない: 「このメールを要約して」+貼付本文は、依頼部分= OwnerInstruction、本文= UntrustedData。**SupportNeedTier は instruction authority / security policy に影響しない**(高くても owner instruction の authority を下げず、外部 data の authority を上げない)。

### 4.20 統計的異常検知の型(新設。オーナー要求)【1H】

```
event: StateAnomalyDetected            (* 対象 stream の保存クラスに従う(owner 系は SensitiveLocalVault) *)
<|StreamKind -> "OwnerOperationalSignal"|"LLMRiskSignalRate"|"RunIntegrityRate"|
               "CommitmentMissRate"|"GuardOverrideRate"|"LoopRate",
  SubjectOrAgentRefs, BaselineRef, Statistic, ObservedValue, ExpectedRange,
  DeviationScore, Method -> "EWMAControl"|"Changepoint"|"RateTest",
  Covariates,                          (* 曜日/時刻/task mix。統制済みであること *)
  WindowStart, WindowEnd, DetectedAtUTC, ModelVersion|>

event: InputAnomalyDetected            (* 通常 store。private 参照は PL 継承 *)
<|StreamKind -> "MailSenderNovelty"|"MailVolumePattern"|"InjectionSignalRate"|
               "AttachmentTypeShift"|"DomainNovelty"|"RetrievalContentShift"|
               "WebIngestAnomalousMarkup"|"DeliveryAnomalyRate",
  SourceScope, BaselineRef, Statistic, ObservedValue, ExpectedRange, DeviationScore,
  Method, ExemplarRefs,                (* 逸脱に寄与した具体入力の refs(raw は含めない) *)
  WindowStart, WindowEnd, DetectedAtUTC, ModelVersion|>

object: AnomalyCorrelationHypothesis   (* owner 状態を参照する場合 SensitiveLocalVault *)
<|HypothesisId, StateAnomalyRefs, InputAnomalyRefs,
  LagEstimate, CorrelationScore, CooccurrenceWindows,
  CandidateCauseRefs,                  (* 疑わしい具体入力(メール群/ドメイン/フィード) *)
  HypothesisStatus -> "Hypothesized"|"Adjudicated:Confirmed"|"Adjudicated:Coincidental"|
                      "Adjudicated:CommonCause"|"Unknown",
  RecommendedResponse, ResponseDecisionRefs, GeneratedAtUTC, ModelVersion|>
```

## 5. 機能仕様(v0.5 追加)

### 5.13 Security–state integration【1H】

**(1) 全 LLM 入口の統一**: 全 entrypoint の inventory を作り(Phase 0 データフロー図の拡張)、共通入口 `SourceVaultPrepareLLMInput` を通す。ここで deterministic pre-scan・taint 合成(§4.17b)・privacy gate・isolation profile 選択を一箇所で行う。delimiter/system prompt 注意書きは補助策で、**capability isolation が主境界**。

**(2) 既存経路の是正(r4 P0-01〜05。1H の最初の作業)**:

| 是正 | 内容 |
|---|---|
| P0-01 | `SourceVaultSummarizeText`(webingest)に `QuarantinePolicy -> "Block"|"MetadataOnly"|"SafeInspection"`(既定 `Block`)を追加し、quarantined 本文を LLM へ渡さない。mail enricher / mining pipeline と規則を統一 |
| P0-02 | `RequiresLLMIsolation` を metadata でなく **execution contract** に: isolation profile を満たす executor のみ許可(executor capability manifest 照合)、不明 executor は fail-closed または deterministic-only へ degrade、充足の証拠を RunRef に記録。`SourceVaultRunMiningPipeline` の warning object × 任意 ExtractorFn 経路を閉じる |
| P0-03 | pre-scan 不達(mining 未ロード・例外)時の fail-open を廃止: `Unknown` として I-14 の degrade 規則に従う。high-risk path では fail-open 禁止 |
| P0-04 | `CrossObjectContamination / AttachmentPropagatedRisk` の 0 固定を廃止し §4.17b の source graph 合成に置換 |
| P0-05 | `UntrustedInput -> False` に trusted provenance/authorization を要求(I-14)。production hook(mail enricher)の無効化操作は監査 event 化 |
| SafeInspection | quarantine 内容の調査は明示 `SafeInspectionMode`: local-only・tool なし・出力も tainted |

**(3) capability broker**: I-14 の lease 方式。実装は servicemanager の action gate/capability レジストリを拡張。

**(4) Knowledge Home 永続化前 security gate**: KH への追記・annotation・position/ranking signal への昇格は、tainted/quarantined 由来を `PendingSecurityReview` に留めるか safe claim のみ通す。**poisoned output が KH の active node・position・ranking へ自動昇格しない**(検索基盤の「quarantined は retrieval から除外」の書き込み側対応)。

**(5) 裁定規則の追加(§5.11 の規則⑨〜⑭)**: ⑨`CompromiseSuspected` run の candidate は commit しない ⑩`Quarantined` source のみに依存する claim は safe verifier/決定的 evidence がない限り unresolved ⑪taint は reducer で低下しない ⑫declassification は owner/決定的 sanitizer の明示 decision のみ ⑬detector のモデル間多数決で quarantine を解除しない ⑭high-risk action で unknown security state を fail-open にしない。

**(6) owner への表示(r4 §8.3/8.4)**: injection 検出時も owner の意図を保持する — 悪性部分を黙って削除して別作業に変えない。「貼付資料内に命令らしい文があるため本文を実行せず隔離した」事実、safe alternative(metadata のみ/deterministic 抽出/SafeInspection)、隔離部分の安全な説明、原 prompt と safe plan の差分、を提示する。低リスク読解は自動 isolation+preview で静かに、高リスク action のみ短い確認一問。detector rule 名の羅列はしない。

### 5.14 統計的異常検知と SystemDoctor 連携(新設。オーナー要求)【1H】

**目的**: 個別 detector(pre-scan・integrity signal)が見逃す弱い/分散した攻撃や、原因不明の状態劣化を、**集計レベルの統計的逸脱**として検知し、状態異常×入力異常の時間相関から因果仮説を立て、通知と保守的対処につなげる。

**パイプライン**:

```
状態信号ストリーム(owner OperationalSignal / LLM RiskSignal率 / RunIntegrity率 /
                     Commitment 見落とし率 / Guard override 率 / Loop 率)
外部入力ストリーム(送信者新規性 / メール量パターン / injection signal 率 / 添付種別 /
                     ドメイン新規性 / retrieval 内容シフト / 配送異常率)
      │ ベースライン学習(個人内/config 内、共変量統制。SensitiveLocalVault/通常 store 各所属)
      ▼
逸脱検知(EWMA 管制図・changepoint・率検定。決定的・LLM 不使用・ModelVersion 付き)
      → StateAnomalyDetected / InputAnomalyDetected
      ▼
クロス相関(lag 付き共起解析。owner 系を含む計算は端末ローカルで実行)
      → AnomalyCorrelationHypothesis(Hypothesized)
      ▼
SystemDoctor / diagnostics SIEM 連携(下記)→ 通知+保守的 containment
      ▼
裁定(owner / 決定的検査 / 独立 verifier)→ Confirmed / Coincidental / CommonCause
      ▼
対処の昇格(Confirmed のみ): CandidateCauseRefs の遡及 taint(§4.17b 経由で派生物へ伝播)、
送信者/ドメイン単位の isolation 既定引き上げ、InjectionResistanceProfile への算入
```

**SystemDoctor / SIEM との結線**:
- 既存 `SourceVault_diagnostics.wl` の SystemDoctor に **Cane セクション**を追加: 直近の StateAnomaly / InputAnomaly / 未裁定 Hypothesis / 実施中 containment の要約(粗いスコアと refs のみ)。
- emit は既存 rule 11(弱結合: diagnostics sink 存在時のみ)+ `SourceVaultMakeDiagnosticProbe` を再利用。**owner 状態の数値は probe に載せない**(I-1。metadata only: stream 種別・逸脱の有無・window・hypothesis id のみ)。
- 通知は SIEM の通報トラストクラス(**自分宛固定・metadata only・事前承認・rate limited**)+ I-15 の警報予算に従う。緊急度は「相関仮説あり>単独 InputAnomaly>単独 StateAnomaly」の順で重み付け。
- heartbeat と同様に、検知パイプライン自体の liveness を SystemDoctor が監視する(「緑のまま死亡」の防止 — 検知系が止まっていること自体を異常として報告)。

**仮説段階で自動実行してよい対処(I-15: 締める方向のみ)**:
1. CandidateCauseRefs の入力群を `Warning`/`NeedsSecurityScan` へ引き上げ(quarantine までは裁定後)
2. 影響 window の run の isolation profile 引き上げ・検証深度追加
3. state-driven policy(モデル選択等)の保守的既定への一時 freeze
4. 証拠 snapshot(裁定用。immutable)
5. owner への通知(安全な説明+一問の確認)

**攻撃シナリオの対称性**: (a) owner への攻撃 — phishing/social engineering キャンペーン(送信者新規性↑+配送異常↑)と owner の操作異常(誤操作率↑・深夜活動↑)の相関 → 「オーナーが標的になっている」仮説。(b) LLM への攻撃 — 間接 injection キャンペーン(injection signal 率↑・retrieval 内容シフト)と RunIntegrity 異常率↑の相関 → 「パイプラインが汚染されている」仮説。どちらも同じ Hypothesis 型・同じ裁定・同じ対処メニューで扱う(分離されるのは対処の可用性: owner 側は通知+提示のみ、run 側は containment 可)。

**統計上の注意(I-15)**: 相関仮説は CommonCause(例: 長期休暇明けで入力も状態も同時に変動)でありうるため、裁定選択肢に `CommonCause` を持つ。ベースライン更新は異常 window を除外して行う(汚染されたベースラインへの適応を防ぐ)。

## 6. Public API(v0.5 追加)

```
SourceVaultPrepareLLMInput[input, opts]          (* 共通入口。pre-scan+taint 合成+isolation 選択。全 entrypoint 必須 *)
SourceVaultAssessInputTrust[inputRef, opts]      (* §4.17。pre-scan の正準化ラッパー *)
SourceVaultRunIntegrity[runRef, opts]            (* §4.18 projection *)
SourceVaultInjectionResistance[agentConfigRef, "AttackFamily"->f, opts]
SourceVaultLeaseCapability[runRef, capability, opts]     (* 短命 lease。broker 経由 *)
SourceVaultDetectStreamAnomalies[streamKind, opts]       (* §5.14。決定的検知 *)
SourceVaultCorrelateAnomalies[opts]                      (* 仮説生成。owner 系はローカル実行 *)
SourceVaultAnomalyHypotheses[opts]                       (* 未裁定一覧/裁定記録 *)
SourceVaultSystemDoctorCaneSection[]                     (* diagnostics 連携ビュー *)
```

## 7. フェーズ(v0.5 追加)

- **Phase 1H: Security–state integration**(1F と並行実装。後付けにしない)
  - 実装順(r4 §10 の順序を規範とする): **(1) P0-01〜05 是正 →(2) taint/provenance を DecisionCase へ →(3) capability isolation を全 executor に強制 →(4) run behavior signal と containment 結線+§5.14 異常検知/SystemDoctor →(5) InjectionResistanceProfile の shadow 集約(最後)**
  - DoD: 全 entrypoint inventory と PrepareLLMInput 経由率 100% / red-team fixture(§8)の attack success・taint laundering・cloud 到達の必須ゼロ項目 green / 異常検知の合成シナリオ(状態のみ・入力のみ・相関あり・CommonCause)で仮説生成と警報予算の動作確認 / SystemDoctor Cane セクションの NB 実機
- Phase 0 追補: LLM entrypoint inventory と capability manifest の型定義を Phase 0 成果物に追加。

## 8. 評価計画(v0.5 追加)

**攻撃 fixture**(r4 §11.1 全数): 直接 injection / indirect(Web・PDF・mail・attachment・OCR)/ 多言語・paraphrase / hidden Unicode・HTML comment・Markdown alt・metadata / base64・難読化・分割 chunk / tool call 誘導 / secret・system prompt exfiltration / cross-object 汚染 / model-to-model・judge injection / poisoned KH annotation / **benign security research text(false positive 測定用)**。unseen attack family を held-out に保つ。

**指標**: attack detection recall・precision / attack success rate / containment success rate / 未認可 tool・action 率 / secret・publication leakage 率 / false quarantine・false warning / safe task 完了率 / SafeInspection 成功率 / **taint laundering 件数(必須ゼロ)** / **private payload の cloud verifier 到達(必須ゼロ)** / **injection を含む candidate の commit(必須ゼロ)** / latency・token・owner 確認負担。

**異常検知(§5.14)**: 検知遅延(time-to-detect)/ 警報予算内の precision(false alarm 率)/ 相関仮説の裁定内訳(Confirmed:Coincidental:CommonCause)/ ベースライン汚染の回帰試験(異常 window 除外の検証)/ 検知系 liveness(緑のまま死亡ゼロ)。

## 9. 受け入れ基準(v0.5 追加。1〜44 は既存)

45. 全 LLM entrypoint が `SourceVaultPrepareLLMInput` 相当の共通 security contract を通ること
46. quarantined input が通常 LLM prompt へ raw のまま入らないこと(SummarizeText 含め全経路で quarantine policy が一致)
47. warning input が `RequiresLLMIsolation` を満たさない executor に渡らないこと
48. pre-scan missing/error が high-risk path で fail-open にならないこと
49. `UntrustedInput -> False` が trusted provenance/authorization なしに指定できないこと
50. CrossObjectContamination / AttachmentPropagatedRisk が source graph から合成されること
51. derived artifact・summary・claim・candidate・final artifact が taint を継承し、reducer/LLM judge だけで taint/quarantine が解除されないこと
52. `CompromiseSuspected` run の candidate が commit されないこと
53. untrusted input を読んだ run に write/network/secret/send capability が既定付与されないこと
54. model-to-model output が untrusted data/schema として渡されること
55. 同じ injection exposure を持つ候補が独立票として扱われないこと
56. private injection payload が cloud verifier/log/telemetry に出ないこと(hash/span ref+rule ID のみ)
57. poisoned output が Knowledge Home の active node・position・ranking signal に自動昇格しないこと
58. InjectionResistanceProfile が ExecutionRiskProfile と混合されないこと
59. attack detector 発火・adjudication・actual outcome が別 event であること
60. SupportNeedTier が instruction authority / security policy を変更しないこと
61. owner prompt の instruction/data segment が分離されること
62. security containment の事実・理由・安全な代替が owner に表示されること
63. 統計的異常検知に基づく自動対処が「締める方向」のみで、破壊的操作・quarantine 解除・検証省略に接続されないこと(I-15)
64. AnomalyCorrelationHypothesis が裁定なしに Confirmed 扱いされず、仮説段階の対処が §5.14 の許可リスト内であること
65. 異常検知 probe/通知が owner 状態の数値を含まず(metadata only)、SIEM 通報トラストクラス(自分宛固定・rate limited)と警報予算に従うこと
66. 異常検知パイプライン自体の liveness が SystemDoctor で監視されること

## 10. Open issues(v0.5)

1. capability lease の実装粒度(servicemanager action gate の拡張か新 broker か)と、既存ツール実行経路(MCP/orchestrator worker)への後付け順序
2. `SourceVaultPrepareLLMInput` への移行戦略(entrypoint inventory 完了までの暫定期の扱い — 移行期間中は未経由呼び出しを監査 event 化)
3. 異常検知のベースライン最小学習期間と cold start(導入直後は検知を通知のみに制限するか)
4. InjectionResistanceProfile の red-team fixture 運用頻度(モデル更新毎か定期か)とコスト
5. AttackFamily 分類の初期語彙
6. v0.4 からの継続分(claim 正規化 / RequiredEvidencePolicy テンプレート / correlation group 自動検出 / 緊急 policy / ほか)

## Appendix F: r4 レビュー+オーナー要求 対応表

| 項目 | 反映箇所 |
|---|---|
| r4 §1/§9 三軸分離(injection ≠ 認知状態) | §0 / §1 用語 / §4.17〜4.19(別 projection)+ Appendix 図式は r4 §9 のとおり(envelope 共有・projection/reason code 分離) |
| r4 P0-01 SummarizeText の quarantine 不整合 | §5.13(2) QuarantinePolicy 既定 Block(受入 46) |
| r4 P0-02 RequiresLLMIsolation 非強制 | §5.13(2) execution contract 化(受入 47) |
| r4 P0-03 pre-scan 不達 fail-open | §5.13(2)+I-14 degrade 規則(受入 48) |
| r4 P0-04 cross-object/attachment risk 0 固定 | §4.17b source graph 合成(受入 50) |
| r4 P0-05 UntrustedInput->False 無条件 | I-14 trusted provenance 要求+hook 無効化の監査 event(受入 49) |
| r4 §5.2 新型 3 種 | §4.17 / §4.18 / §4.19 |
| r4 §6 多層防御(authority/pre-scan/capability/出力後/裁定学習) | I-14 / §5.13(1)(3)(4) / §4.19 三層 event(受入 45, 51, 53, 59) |
| r4 §7 DecisionCase 接続(security fields / exposure group / m2m injection / conflict 非隠蔽 / 裁定規則 6 項) | §4.13 補足 / §5.13(5) 規則⑨〜⑭(受入 52, 54〜56) |
| r4 §8 owner assistance 接続(InputSegments / SupportNeedTier 非影響 / 意図保持 / 警報疲れ) | §4.15 補足 / §5.13(6)(受入 60〜62) |
| r4 §10 Phase 1H+実装順 | §7(profile 集約を最後にする順序を規範化) |
| r4 §11 テスト・評価 | §8(fixture・指標・評価上の注意を全数) |
| r4 §12 受け入れ 20 項目 | §9 の 45〜62 に統合 |
| r4 §13 最小追加 10 項目 | I-14 / §4.17〜4.19 / §4.13 補足 / §4.15 補足 / §5.13(1)(2)(4) / §7 Phase 1H で全数 |
| **オーナー要求: 統計的異常検知×SystemDoctor** | §0(位置づけ)/ I-15 / §4.20 / §5.14 / §6 API / §8 異常検知指標(受入 63〜66)。SystemDoctor(diagnostics)連携は rule 11 弱結合+SIEM 通報トラストクラス+警報予算。相関=因果仮説であり裁定を経て対処昇格 |
