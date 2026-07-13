# SourceVault Cane / Knowledge Home 認知支援マイニングレイヤー仕様 v0.4

- 作成日: 2026-07-12(v0.1)/ 更新日: 2026-07-12(v0.4)
- 状態: **Draft(r3 レビュー全反映。v0.3 の基盤は r3 で採用可能判定済み。本版は差分 = Phase 1F/1G の追加と P1-01〜08 の修正)**
- 本版 v0.4 の変更(r3 `sourcevault_cane_knowledge_home_mining_spec_v0_3_review.md` 全反映。対応表は Appendix E):
  1. **Phase 1F: Multi-model adjudication(新設)** — 複数 LLM が同一案件に異なる回答を出したときの**案件単位の裁定プロトコル**。`MultiModelDecisionCase / CandidateArtifact / ClaimEvaluation` を正準に追加し、claim 分解 → 決定的テスト/evidence 検証 → 独立 verifier → conflict 保持 → abstain/commit の順で裁定する。**多数決を正解判定に使わない**(I-11)
  2. **Phase 1G: Owner input assistance(新設)** — 支援必要度が高いときに LLM が作業を請け負う際の安全仕様。`OwnerInputRiskAssessment / OwnerInputAssistanceCase` を追加。**SupportNeedTier は prompt error の証拠ではなく、検証と可逆性を強める bounded trigger**(I-12)。LLM は owner の意図を置換せず解釈候補を管理する
  3. verifier 独立性の定義と correlation group(P1-02)、reducer の conflict 保持契約(P1-05)、AgentConfigurationRef の階層化 backoff(P1-06)、owner 確認不能時の遅延裁定(P1-07)、support profile の LLM prompt 非開示+AssistanceMode 文言 leakage の sink matrix 追加(P1-08/I-13)
  4. 用語の峻別追加: `SupportNeedTier`(操作支援の必要性)/ `PromptInterpretationRisk`(入力解釈の不確かさ)/ `ActionRiskClass`(実行時の客観リスク)/ `EvidenceConfidence`(根拠の確度)。「意識レベル」という語は使わない
- v0.3 からの不変部分(§0 中心思想・三層構造・envelope・SensitiveLocalVault 契約・GateCoverageRegistry・shadow 昇格ラダー I-10・Phase 0/1A〜1E)は変更なし。本文は差分のみ記述し、無印の節は v0.3 を正とする

## 0. 目的と結論(v0.4 追補)

v0.3 までで、(a) Knowledge Home 閲覧/追記/位置づけ/近傍提案、(b) subject 別状態信号(HumanOperationalSupportProfile / LLMExecutionRiskProfile)+共通 envelope、(c) Guard と介入ラダー、が確定した。r3 の指摘どおり、これらは**複数 LLM 判断の基礎データ層**(モデル×設定×task-domain の校正基盤)であって、それだけでは複数回答から正しい最終結果を作れない。v0.4 は残る二つの穴を塞ぐ:

**1. 案件単位の裁定(Phase 1F)** — 精度を上げる鍵は多数決ではなく、**claim 分解・evidence・決定的テスト・独立 verifier・conflict の保持・abstain・transactional commit** である。判断の優先順位を固定する:

```
(1) 決定的テスト・契約・計算結果
(2) 一次資料・SourceVault 内の provenance 付き evidence
(3) claim ごとの独立 verifier
(4) calibrated な task-domain 別モデル履歴(LLMExecutionRiskProfile)
(5) モデル間一致(最下位の補助 signal)
```

**2. owner 入力支援(Phase 1G)** — 正しい接続形は:

> SupportNeedTier が高い、または input 固有の異常 signal がある → **解釈・検証・可逆性を強める** → owner の意図を保持したまま LLM が補助する

であり、「SupportNeedTier が高い → prompt が誤り → LLM が意図を書き換えて代行」は採用しない。LLM が請け負うのは意図候補の整理・根拠収集・draft・sandbox 実行・検証であり、**不可逆な最終決定ではない**。

## 1. 用語(v0.4 追加)

| 用語 | 意味 | 混同禁止 |
|---|---|---|
| `SupportNeedTier` | 操作支援を増やす必要性の推定(人・owner) | 「意識レベル」(覚醒・意識障害の医療概念)とは別物。この語は仕様・UI・ログで使わない |
| `PromptInterpretationRisk` | 当該入力の解釈が不確かな程度(input 固有) | SupportNeedTier(人の状態)と別軸 |
| `ActionRiskClass` | 実行した場合の客観リスク(§5.7 taxonomy) | — |
| `EvidenceConfidence` | 判断根拠の確度 | モデルの自己申告 confidence と別 |

## 2. 不変条件(v0.4 追加分。I-1〜I-10 は v0.3 のまま)

**I-11. 多数決非依存(裁定の証拠優先)** — 複数モデルの一致は補助 signal であり正解判定ではない。
- `n` 中 `k` の票数だけで candidate を採用する経路を実装しない。判断は §0 の優先順位に従う。
- 同一 family・同一 retrieval・同一 prompt・同一 tool output に依存する回答は独立票として数えず、**correlation group** として扱う。
- deterministic test で refuted された candidate は、モデル confidence・consensus に関係なく採用しない。authorization を満たさない candidate/action は内容品質に関係なく採用しない。
- 高リスク action は LLM consensus だけで commit しない(owner 確認または既存 policy gate)。
- disagreement は失敗ではない: `NeedMoreEvidence / NeedOwnerClarification / SafeDraftOnly / NoCommit` を正規の裁定結果とし、reducer が conflict を消して滑らかな一文にしない。

**I-12. owner 意図の保持** — LLM 補助は owner の意図を置換しない。
- original prompt は immutable に保持(SensitiveLocalVault)。normalization・intent 候補・LLM が補った assumption・owner confirmation・final intent・executed plan を provenance として連結する(§4.16)。
- SupportNeedTier 単独で prompt を誤りと判定しない。prompt 側の評価は必ず `OwnerInputRiskAssessment`(§4.15)を介する。SupportNeedTier はその起動 trigger と確認強度の bounded な一段引き上げにのみ使う。
- SupportNeedTier が高くても **action authorization は一切広がらない**: LLM が準備する範囲(検索・draft・sandbox)は広げてよいが、不可逆 commit の権限は広げない。
- **owner の無応答・確認不能を承認と解釈しない**。確認できない場合は draft/queue に留める(意図を推測して送信しない)。
- owner correction は ground truth として記録するが、SupportNeedTier の自己正当化に循環利用しない。owner は assistance mode を即時解除できる。

**I-13. support profile の非開示** — SupportNeedTier・HumanSupportProfile とその根拠を **LLM prompt / MCP / telemetry に渡さない**。
- 支援フローの変更(proposer 数・verifier 有無・clarification 閾値・draft-only mode・決定的テスト追加・commit 時 owner 確認)は router/orchestrator の内部 policy で行い、モデルには必要な作業指示だけを渡す。「owner の状態が低いから」という理由をモデルに渡さない。
- sink matrix は認知値そのものに加え、**`AssistanceMode` や system prompt の文言から支援状態を推測できる間接 leakage** も試験対象とする。

## 4. データモデル(v0.4 追加)

### 4.5.3 補足: AgentConfigurationRef の階層化(P1-06)

厳密 config digest の細分化で履歴が疎になる問題への対処: identity を階層化する。

```
Level 0: AgentConfigurationRef(厳密 digest。正準)
Level 1: ModelArtifactRef × TaskDomain
Level 2: model family × TaskDomain
```

`SourceVaultLLMExecutionRisk` は Level 0 で SampleCount 不足のときのみ上位 level へ **backoff** し、返値に `CalibrationLevel` を明示する。異質な config(toolset 有無・retrieval 有無が異なる等)は上位 level でも無条件合算しない(Strata が異なる場合は backoff 不可、`Missing["InsufficientEvidence"]`)。

### 4.12 MultiModelDecisionCase(新設。P1-01)【1F】

同一案件に対する複数 candidate の裁定の正準。

```
<|ObjectClass -> "SourceVaultMultiModelDecisionCase", DecisionCaseId(ULID),
  InputRef, TaskDomain, ActionRiskClass,
  RequiredEvidencePolicy,             (* この案件で claim 採用に必要な evidence 水準 *)
  CandidateRefs -> {CandidateRef..},
  CorrelationGroups -> {{CandidateRef..}..},   (* family/retrieval/prompt/tool 共有で同群 *)
  DeterministicTestRefs, ConflictSet,
  Decision -> "Accept"|"Merge"|"NeedMoreEvidence"|"NeedOwnerClarification"|
              "SafeDraftOnly"|"Reject"|"NoCommit",
  DecisionBasis,                      (* §0 優先順位のどの層で決まったか+根拠 refs *)
  FinalArtifactRef, CommitAuthorizationRef,    (* commit は既存 transactional 経路の認可 ref *)
  Privacy, Tags, CreatedAtUTC, DecidedAtUTC|>
```

### 4.13 CandidateArtifact(新設)【1F】

```
<|CandidateRef, AgentRefs, Role -> "Proposer"|"Critic"|"Verifier"|"Judge",
  EvidenceVisibility,                 (* 見えた evidence 集合(EvidenceSetRef)と redaction の有無 *)
  EffectiveAccessProfile,
  SawOtherCandidates -> True|False,   (* 他モデルの回答を見たか(独立性の記録) *)
  Claims -> {ClaimRef..},             (* 必須: claim/plan/action へ構造化 *)
  PlanSteps, ProposedActions,
  Assumptions,                        (* 必須: LLM が補った前提 *)
  UnresolvedQuestions,                (* 必須 *)
  SelfReportedConfidence,             (* 参考値。裁定の主根拠にしない *)
  ExecutionRiskSnapshotRef,           (* 生成時点の profile snapshot(prior 用) *)
  OutputPrivacy|>
```

- **verifier の独立性の定義(P1-02)**: 「独立」とは最低限 (a) 別 run、(b) proposer と別 correlation group(別 family または別 evidence view)、(c) proposer の結論を隠した blind 判定、を満たすこと。verifier 自身も CandidateArtifact として AgentRefs・EvidenceVisibility・ExecutionRiskSnapshotRef を記録する(verifier も誤るため)。
- **anchoring 回避手順**: ①proposer 回答を claim/plan に構造化 → ②verifier には claim と evidence のみ渡す → ③結論を隠して独立判定 → ④最後に conflict を比較。

### 4.14 ClaimEvaluation(新設)【1F】

```
<|ClaimRef, NormalizedClaim, EvidenceRefs,
  DeterministicTestResult, VerifierAssessments,
  Verdict -> "Supported"|"Refuted"|"Unresolved"|"Conflicting",
  EvidenceConfidence, Privacy|>
```

- supported claim だけを final artifact に入れる。unresolved/conflicting は明示して残すか owner clarification に戻す。
- **privacy visibility 規則**: private evidence を cloud judge に渡さない。選択肢は (a) local verifier が private claim を検証、(b) cloud-safe な derived fact のみ release gate 経由で渡す、(c) privacy を保った決定的 test result のみ共有、(d) 判定不能として owner/local path に戻す。EvidenceVisibility が異なる candidate 間の disagreement を能力差として ExecutionRiskProfile に計上しない。

### 4.15 OwnerInputRiskAssessment(新設。P1-03)【1G】

prompt 固有の評価。SupportNeedTier から prompt error への直結を禁止する中間層。

```
<|InputRef, OriginalPromptDigest,
  AmbiguitySignals, MissingArgumentSignals,
  TargetOrRecipientMismatch,          (* 本文中の人名/文脈と宛先 identity の不整合 *)
  NumericalOrDateAnomaly,
  ConflictWithKnownCommitments,       (* §4.8 Commitment との矛盾 *)
  ConflictWithRecentOwnerDecision,    (* KH/最近の決定との矛盾 *)
  PrivacyMismatch, IrreversibleActionRequested,
  NoveltyFromOwnerBaseline,
  InterpretationConfidence, PromptInterpretationRisk,
  CandidateIntentRefs|>
```

保存は SensitiveLocalVault(owner の入力断片を含むため)。clarification/verification を強めるのは、この assessment が**具体的な anomaly を示した場合のみ**。

### 4.16 OwnerInputAssistanceCase(新設。P1-04)【1G】

```
<|AssistanceCaseId, OriginalInputRef,     (* original prompt は immutable *)
  InputRiskAssessmentRef,
  HumanSupportProfileRef,                 (* local-only link。モデルへ渡さない(I-13) *)
  NormalizedInputRef, CandidateIntentRefs,
  ClarificationQuestion,                  (* 結果を分ける最小の一問(A/B 形式) *)
  ChosenIntentRef, Assumptions,
  AssistanceMode -> "Normal"|"ReviewEnhanced"|"DraftOnly"|"ConfirmBeforeCommit",
  ExecutedPlanRef, ResultRef,
  OwnerCorrection, IntentPreserved -> True|False|Missing|>
```

## 5. 機能仕様(v0.4 追加)

### 5.11 Multi-model adjudication ワークフロー【1F】

```
owner input
  → OwnerInputRiskAssessment(1G 連携。単体でも可)
  → intent 仮説 + Knowledge Home / task context retrieval
  → proposer A/B/C(correlation group を意識した構成)
  → claim/plan 正規化 → deterministic tests / evidence checks
  → independent critic/verifier(blind、別 correlation group)
  → MultiModelDecisionCase(conflict 保持)
  → Accept / SafeDraftOnly / AskOwner / NoCommit
  → transactional commit + audit
```

- **実装基盤**: ClaudeOrchestrator の Planner/Worker/Reducer/Verifier/Committer 役割分離と transactional commit を再利用する。ただし claim-level evidence adjudication・モデル相関・privacy visibility・abstain policy は orchestrator には無いため、本仕様の DecisionCase 群(SourceVault 側)として追加する。
- **Reducer の出力契約(P1-05)**: `ConflictSet / UnresolvedClaims / ExcludedCandidates` を必須フィールドとし、conflict は最終 artifact の provenance として保持する。
- **裁定規則**(正規化。I-11 と §0 優先順位の適用): ①refuted candidate 不採用 → ②authorization 不足の candidate/action 不採用 → ③supported claim のみ採用 → ④unresolved/conflicting は明示残置か owner clarification → ⑤ExecutionRiskProfile は事前重み/verifier 深度にのみ使用(evidence を上書きしない) → ⑥CI が広い profile は重み付けせず InsufficientEvidence → ⑦同一 correlation group を独立票として加算しない → ⑧high-risk は consensus だけで commit しない。
- multi-model workflow が single-model baseline より改善しない task domain では**無効化できる**(per-domain トグル+shadow 比較を常設)。

### 5.12 Owner input assistance【1G】

**risk 別の「請け負う」範囲(I-12 の具体化)**:

| ActionRiskClass | LLM が先行してよい範囲 |
|---|---|
| 低・可逆 | sandbox 実行、検索、下書き、候補生成、preview |
| 中 | plan と draft、別モデル review。commit 前に短い確認 |
| 高・不可逆 | evidence 収集と plan のみ。送信・公開・削除・支払いは owner 確認または既存 policy gate 必須 |
| 緊急 | emergency policy を別定義(単なる TimedDefer で期限損失を増やさない) |

- 確認質問は「結果を分ける最小の一問」(A/B 選択形式)に限定し、大量の確認で疲れさせない。
- **owner 確認困難時(P1-07)**: 毎回 owner を adjudicator にしない。低リスクは preview・決定的テスト・**後で確認(遅延裁定)** を使い、高リスクは commit しない。確認不能は同意ではない(I-12)。
- **補完の common-mode failure 対策**: 誤った過去メール根拠・古い KH 記述の優先・類似人物/予定の取り違え・過度の具体化・複数 LLM の同一誤前提、に対して、補完結果の `Assumptions / EvidenceRefs / UnresolvedQuestions` を必須にし、verifier は文章の上手さではなくこれらを検証する(1F の ClaimEvaluation に接続)。
- UI: assistance mode を常時表示し、owner が即時解除できる。

## 6. Public API(v0.4 追加)

```
SourceVaultOpenDecisionCase[inputRef, opts]              (* 1F: case 生成 *)
SourceVaultAddCandidate[caseId, candidate, opts]         (* Claims/Assumptions/UnresolvedQuestions 必須 *)
SourceVaultEvaluateClaims[caseId, opts]                  (* 決定的テスト→evidence→verifier の順で ClaimEvaluation *)
SourceVaultDecideCase[caseId, opts]                      (* I-11 規則で Decision。abstain を正規結果として返す *)
SourceVaultAssessOwnerInput[inputRef, opts]              (* 1G: OwnerInputRiskAssessment。SensitiveLocalVault *)
SourceVaultAssistOwnerInput[inputRef, opts]              (* 1G: AssistanceCase 生成〜mode 決定。I-13 を強制 *)
```

既存 API は v0.3 のまま。`SourceVaultLLMExecutionRisk` は `CalibrationLevel`(§4.5.3 補足)を返値に追加。

## 7. フェーズ(v0.4 追加)

- **Phase 1F: Multi-model adjudication**(1E と独立に着手可、1G より先行推奨)
  - DecisionCase/CandidateArtifact/ClaimEvaluation、correlation group と EvidenceVisibility、role 契約、conflict-preserving reducer、abstain、transactional committer 接続、single-model baseline との shadow 比較
  - DoD: 合成 conflict ケースで裁定規則①〜⑧の単体テスト green / privacy visibility 試験(private evidence の cloud judge 到達ゼロ)/ baseline 比較ハーネス
- **Phase 1G: Owner input assistance**(1F の裁定基盤を利用)
  - OwnerInputRiskAssessment/AssistanceCase、original input と assumptions の provenance、SupportNeedTier は bounded trigger のみ、low-risk preview/medium confirm/high no-commit、paired shadow 評価(SupportNeedTier あり/なし)、owner controls
  - DoD: I-12/I-13 の強制テスト(意図置換・無応答承認・prompt leakage の経路が存在しないこと)/ intent preservation 測定の NB 実機

## 8. 評価計画(v0.4 追加)

| 対象 | 指標 |
|---|---|
| 1F 複数 LLM | single-model baseline 比の task success 改善率 / claim-level precision・recall・unresolved 率 / deterministic test pass 率 / disagreement 時の正しい abstain 率 / judge・verifier の false accept・false reject / common-mode error 率 / correlation group 無視との比較 / privacy visibility 違反ゼロ / 追加 latency・token・local compute コスト / owner 最終修正率 |
| 1G 入力支援 | owner correction 率 / intent preservation 率 / false clarification 率 / 確認回数と確認疲れ / unsafe commit 減少 / **正しい prompt を誤って疑った率** / assistance による新規誤り混入率 / preview 取り消し率 / SupportNeedTier あり・なしの paired shadow 比較 / 時刻・task domain・risk 別の効果差 |

「精度が上がった」の判定は LLM 自己評価やモデル間一致ではなく、owner correction・決定的テスト・後続 outcome・確定 evidence で測る。

## 9. 受け入れ基準(v0.4 追加。1〜29 は v0.3 のまま)

30. 複数モデルの票数だけで candidate を採用する経路が存在しないこと
31. candidate が claim・evidence・assumptions・unresolved questions を返すこと(欠落 candidate は裁定に参加できない)
32. deterministic test / evidence がモデル confidence と consensus より優先されること
33. verifier の AgentRefs・EvidenceVisibility・correlation group が記録されること(blind 判定の検証可能性)
34. reducer が conflict を消さず、ConflictSet/UnresolvedClaims/ExcludedCandidates が final decision に残ること
35. disagreement から `NeedMoreEvidence / NeedOwnerClarification / SafeDraftOnly / NoCommit` を返せること
36. private evidence を見られない model の disagreement が能力差として計上されないこと(EvidenceVisibility 突合)
37. SupportNeedTier 単独で prompt error と判定されないこと(OwnerInputRiskAssessment を経由しない接続経路が存在しない)
38. SupportNeedTier・HumanSupportProfile が LLM prompt / MCP / telemetry へ渡らないこと(AssistanceMode 等からの間接 leakage を含む sink matrix 試験)
39. original prompt・candidate intents・assumptions・owner confirmation・executed plan が追跡可能であること
40. SupportNeedTier が高くても action authorization が広がらないこと
41. high-risk action が LLM consensus だけで commit されないこと
42. owner の無応答・確認不能が承認と解釈されないこと
43. assistance の intent preservation と新規誤り混入率が測定されること
44. multi-model workflow を task domain 単位で無効化でき、baseline 比較が常設されること

## 10. Open issues(v0.4)

1. claim 正規化の方法(自然文 → claim/plan の構造化を誰がやるか: 専用小モデルか決定的パーサか。anchoring 回避との両立)
2. `RequiredEvidencePolicy` の初期テンプレート(task domain × risk class の表)
3. correlation group の判定精度(family は既知だが retrieval/prompt 共有の自動検出)
4. 緊急時 emergency policy の具体化(1G の「緊急」行。Guard の TimedDefer との整合)
5. v0.3 からの継続分(支援必要度昇格条件 / camouflage 倫理 / マルチデバイス同期 / TaskDomain 語彙 / adjudication 運用コスト / Commitment 初期規則 / telemetry サイズ管理)

## Appendix E: r3 レビュー対応表

| r3 項目 | 反映箇所 |
|---|---|
| §1.1 案件単位裁定の欠落(P1-01) | §4.12〜4.14 / §5.11 / Phase 1F(受入 30〜36, 44) |
| §1.2 owner 支援の正しい接続 | §0 / I-12 / §4.15〜4.16 / §5.12 / Phase 1G(受入 37〜43) |
| §3.1 多数決は正解判定でない | I-11 / §0 優先順位 / 裁定規則①〜⑧(受入 30, 32) |
| §3.2 独立性の記録 | §4.13(SawOtherCandidates/EvidenceVisibility)/ §4.12 CorrelationGroups(受入 33) |
| §3.3 verifier も誤る・anchoring | §4.13 独立性定義+blind 手順(受入 33) |
| §3.4 privacy の異なる出力の比較 | §4.14 privacy visibility 規則(受入 36。private evidence の cloud judge 禁止) |
| §3.5 abstain の正規化 | I-11 / §4.12 Decision / §5.11(受入 35) |
| §4.1 SupportNeedTier→prompt error 直結禁止(P1-03) | I-12 / §4.15(受入 37) |
| §4.2 「意識レベル」を使わない | §1 用語表 |
| §4.3 LLM に SupportNeedTier を知らせない(P1-08) | I-13(受入 38) |
| §4.4 意図の置換禁止・provenance(P1-04) | I-12 / §4.16(受入 39) |
| §4.5 risk 別の請け負い範囲 | §5.12 表(受入 40, 41) |
| §4.6 補完の common-mode failure | §5.12(Assumptions/EvidenceRefs/UnresolvedQuestions 必須) |
| §5 データモデル 4 種 | §4.12〜4.16 にほぼそのまま採用 |
| §6 ワークフローと orchestrator 再利用 | §5.11(不足分を SourceVault 側 DecisionCase で補うことも明記) |
| §7.1/7.2 判断規則 | §5.11 裁定規則 / I-12(1〜8 を全数取り込み) |
| §8 評価指標 | §8(全数取り込み) |
| P1-02 IndependentVerifier 未定義 | §4.13 独立性定義 |
| P1-05 reducer が disagreement を隠す | §5.11 Reducer 出力契約(受入 34) |
| P1-06 AgentConfigurationRef 細分化 | §4.5.3 補足(階層化 backoff+CalibrationLevel、異質 config 非合算) |
| P1-07 owner adjudication 依存 | §5.12(遅延裁定・最小質問・確認不能≠同意)(受入 42) |
| §11 受け入れ 15 項目 | §9 の 30〜44 に全数統合 |
| §10 Phase 1F/1G 追加 | §7(1F 先行、1G が 1F 基盤を利用) |
