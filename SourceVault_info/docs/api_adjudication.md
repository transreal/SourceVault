# SourceVault_adjudication.wl API

Cane Phase 1F: 複数 LLM 案件裁定の決定的コア(spec v0.4 §4.12-4.14/§5.11/I-11)。
**多数決非依存**: 優先順位=決定的テスト>evidence>verifier 判定>calibrated 履歴>モデル間一致。
同一 CorrelationGroup は独立票に数えない。abstain(NeedMoreEvidence/NeedOwnerClarification/
SafeDraftOnly/NoCommit)は正規の裁定結果。conflict は消さず final に保持。LLM 呼び出しは含まない
(proposer/verifier の実行は orchestrator 側。本モジュールは裁定のみ)。

### SourceVaultOpenDecisionCase[inputRef, opts]
案件を開く。→ DecisionCaseId("svcase:<ULID>")。case はメモリ registry、最終判定のみ event 化。
Options: "TaskDomain"("General")、"ActionRiskClass"(Low|Medium|High, 既定 Low)、"RequiredEvidencePolicy"。

### SourceVaultAddCandidate[caseId, candidate]
候補登録。**必須**: AgentRefs/Role/Claims({<|Claim,(DeterministicTest),(EvidenceRefs),(Contradicts)|>...})/
Assumptions/UnresolvedQuestions(欠落は Failure=受入31)。任意: CorrelationGroup(未指定=自 group)、
Authorized(既定 True)、EvidenceVisibility、SelfReportedConfidence(参考値)。→ CandidateRef。

### SourceVaultEvaluateClaims[caseId, opts]
claim 単位評価(NormalizedClaim で候補横断突合)。Verdict = DeterministicTest(True→Supported/
False→Refuted)> "VerifierVerdicts"(opts 注入)> Contradicts 宣言→Conflicting > EvidenceRefs→
Supported(弱)> Unresolved。→ {ClaimEvaluation...}。

### SourceVaultDecideCase[caseId, opts]
裁定規則①〜⑧: ①refuted claim 保持候補は不採用 ②Authorized->False 不採用 ③supported のみ final
④unresolved/conflicting 明示保持 ⑤"RiskPriors" は並びのみ ⑥tier Missing 無重み ⑦correlation group
単位の独立票 ⑧High risk は "OwnerConfirmed"->True なしに Accept しない(SafeDraftOnly 止まり)。
→ <|Decision, FinalClaims, ConflictSet, UnresolvedClaims, ExcludedCandidates, DecisionBasis,
IndependentGroups|>。MultiModelDecisionRecorded(内容最小化)を event 化("Persist"->True)。

### SourceVaultDecisionCase[caseId]
case の現在状態(Candidates/ClaimEvaluations/Decision)。

### SourceVaultRunMultiModelDecision[inputRef, proposerFns, opts]
裁定を end-to-end 実行する runnable driver。**proposer/verifier LLM の実走は proposerFns/VerifierFn に注入**
(orchestrator 結線点。mock 可。本 driver は LLM を直接呼ばない)。proposerFns: {inputRef->candidate assoc...}
(欠落候補は driver で除外し ExcludedProposers に記録)。open→addCandidate→evaluateClaims(VerifierFn を
claim ごとに blind 判定して VerifierVerdicts に注入)→decideCase を実行。
→ decision fields + `<|DecisionCaseId, ExcludedProposers, CandidateCount|>`
Options: "VerifierFn"(None)、"TaskDomain"、"ActionRiskClass"(Low)、"OwnerConfirmed"(False)、"RiskPriors"、"Persist"(True)。
