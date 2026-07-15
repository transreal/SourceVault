# SourceVault_anomaly.wl API

Cane Phase 1H-A: 異常分析ワークフロー(**observe-only**)。
spec v0.5/v0.6 §5.14 / §4.20 / §4.23 / §5.14 追補 / §5.15 改訂、不変条件 I-15 / I-16。決定的・LLM 不使用。

**最重要(I-16)**: これは明示的に実行する観測専用ワークフローで、enforcement(通知・Warning 昇格・isolation
変更・policy freeze・taint 変更・containment)を**一切行わない**。出力(event/hypothesis/report)は別の昇格
ゲートが消費する。store は local-only(`<LocalState>/cane/anomaly/`。PrivateVault/CoreRoot 配下は I-1 sink guard で拒否)。

### SourceVaultAnomalyInitialize[opts] / SourceVaultAnomalyStatus[opts]
store(runs/events/baselines/profile)と MAC 鍵を初期化(冪等)。Options: `"Root"`(Automatic=<LocalState>/cane/anomaly)。
Status は初期化・run 件数・active baseline 数・profile version・OwnerStateOptIn・active pair 数を返す。

### SourceVaultDetectStreamAnomalies[streamData, opts]
1 stream の逸脱を決定的に検知(observe-only)。`streamData=<|"StreamKind","Points"->{<|WindowStart,WindowEnd,
EventCount,ExposureCount,MissingCount,(InputRefs),(RunRefs),(SourceGroups)|>...}|>`。
**rate=EventCount/ExposureCount・CoverageRatio・ConfidenceInterval(Wilson)・DataQualityFlags 必須**。
collection 停止による rate 低下は `PossibleCollectionGap` として flag(改善と誤認しない)。
**cold start**(reference < MinBaselineSamples)は `Missing["InsufficientBaseline"]` を返し何も通知しない(I-15)。
Options: `"Baseline"`(Automatic|record)、`"ReferenceCount"`、`"DeviationThreshold"`(3.0)、`"MinBaselineSamples"`(8)、
`"Method"`("MADControl"|"EWMAControl")。→ `<|StreamKind, StreamKindClass, Baseline, BaselineSampleCount,
Evaluations(per window: Rate/DeviationScore/ConfidenceInterval/CoverageRatio/DataQualityFlags/IsAnomaly/Direction),
Anomalies(StateAnomalyDetected|InputAnomalyDetected events)|>`。

### SourceVaultClassifyLineageDependence[eventA, eventB]
相関の**前に必須**の provenance 依存分類(§4.20)。共有 InputRef/RunRef → `DirectLineage`(機械的共起=相関仮説に
しない)、SourceGroup 共有 → `SharedUpstream`、provenance 独立 → `IndependentStreams`、参照不明 → `UnknownDependence`。

### SourceVaultCorrelateAnomalies[pairSpec, evalA, evalB, opts]
lag 付きクロス相関から `AnomalyCorrelationHypothesis` を生成(observe-only)。**DirectLineage は
`Missing["MechanicallyCoupled"]`**(相関仮説にしない)。HypothesisStatus は association/causality 分離で、
workflow は最大 `AssociationSupported`(`SharedUpstream` も同上限)。`CausalEvidenceSupported` へは到達しない。
`RecommendedResponse` は observe-only 語彙("None"|"LocalReviewSuggested")のみ。Options: `"MaxLagWindows"`(3)、
`"MinEffectSize"`(0.5)、`"MinOverlapWindows"`(5)、`"DeviationThreshold"`(3.0)。→ Hypothesis に
`LineageDependence, LagEstimate, CorrelationScore, DependenceAdjustment, EffectiveSampleSize, AttributionConfidence,
CandidateCauseRefs, HypothesisStatus`。

### SourceVaultAdjudicateAnomalyHypothesis[hypothesis, decision]
裁定で HypothesisStatus を更新(**containment はしない**)。`decision=<|"By","Verdict"->"Coincidental"|"CommonCause"|
"Association"|"Causal",("CausalEvidence")|>`。**Verdict Causal** は `CausalEvidence` in
{ControlledReplay,DeterministicAttackChain,IsolationStoppedRecurrence} **かつ** LineageDependence=IndependentStreams
のときのみ `CausalEvidenceSupported`(owner 確認単独・SharedUpstream では到達不可=I-15)。SharedUpstream は
AssociationSupported を超えない。

### SourceVaultGenerateCaneBaselineCandidate / SourceVaultValidateCaneBaseline / SourceVaultActivateCaneBaseline / SourceVaultCaneBaselineCandidates / SourceVaultCaneActiveBaseline
baseline 更新の**三段階**(I-16)。Generate は異常 window(robust z 閾値超)と suspected/pending window を除外して
median/MAD 推定(**poisoning 対策**、state="candidate")。Validate は holdout backtest(false-alarm 率)+ 更新前後 diff
で state を "validated"/"rejected"(Options `"HoldoutPoints"`、`"MaxFalseAlarmRate"`(0.2))。Activate は
**検証済みのみ**受理(未検証は Failure。無条件自動 activate なし)。

### SourceVaultAnomalyWorkflowProfile / SourceVaultSetAnomalyWorkflowProfile / SourceVaultProposeAnomalyProfileChange / SourceVaultRegisterCaneAnomalySchedule
`AnomalyWorkflowProfile` は**署名付き trusted config**(I-16)。Set は `"OwnerAuthorization"->True` 必須
(LLM/external content 不到達)、versioned+history(rollback 可)、MAC 署名、baseline epoch 切替。改ざん検出時は既定へ
fail-closed(`ProfileIntegrity->"TamperedFellBackToDefault"`)。Propose は external content 由来の変更提案を
`PendingReview` に保存(自動適用しない)。RegisterCaneAnomalySchedule は owner 登録の ScheduleSpec(**分析権限のみ・
enforcement 権限なし**、OS ScheduledTask は作らない)。
**既定 profile**: 初期 active pair は LLM 系(InjectionSignalRate×RunIntegrityRate)+ system 系(PreScanFailureRate×
UnexpectedToolRequestRate)のみ。owner 状態 pair(MailSenderNovelty×OwnerOperationalSignal)は `Active->False,
ResearchOnly->True`(§5.14 追補)。

### SourceVaultCollectCaneAnomalyStreams[opts](2026-07-15 追加)
既存の observe-only event store から**決定的に**(LLM 不使用)rate stream(CreatedAtUTC 日次ビン化)を
構築する。既定 stream: `LLMBoundaryMismatchRate`(LLMBoundaryGate/Shadow の非 Verified/mismatch 率)、
`GuardMailMisalignedRate`(GuardMailParallelRecorded の非 aligned 率)。**owner 状態系は opt-in**:
`"IncludeOwnerState"->True` で `OwnerInputHighRiskRate`(OwnerInputShadowRecorded の High 率)を追加。
Options: "WindowDays"(14)、"Limit"(5000)。→ RunCaneAnomalyWorkflow の "Streams" にそのまま渡せる
Association。**実データが無い stream は含めない**(空捏造しない=I-15)。分子/分母を数え Wilson CI と
baseline は DetectStreamAnomalies が付ける(cold start=MinBaselineSamples 未満は InsufficientBaseline)。
schedule tick の既定 RunFn がこれを呼んで実 stream を供給する(owner 状態は profile の OwnerStateOptIn に従う)。
罠: 文字列の日付比較は `>=` でなく `OrderedQ`(WL の `>=` は文字列を評価しない)。

### SourceVaultCaneAnomalyScheduleTick[opts](2026-07-14 追加)
service 低頻度 hook 用の due 判定+実行 tick(servicemanager の service ループから弱結合で定期呼び出し。
判定周期は `$SourceVaultCaneAnomalyTickIntervalSeconds`(既定 600s)、実行間隔は profile 内 ScheduleSpec の
IntervalSeconds)。Enabled/Scheduled/非 Paused かつ前回 run から IntervalSeconds 経過のときだけ
`SourceVaultRunCaneAnomalyWorkflow[]` を **1 回**実行(catch-up は遅延分を多重実行しない)。多重 tick は
run の idempotency(同一 idemKey→Reused)で安全。**Reused でも pipeline-status の liveness を更新**
(LastScheduleOutcome 付き。空 streams の縮退で probe が偽 PipelineStale にならない)。決して throw せず
`<|Status: Disabled|NotDue|Ran|Reused|RunFailed|ProfileUnavailable|>`。Options: "RunFn"(注入シーム=テスト用)。
有効化手順: owner が `SourceVaultRegisterCaneAnomalySchedule[<|"IntervalSeconds"->86400|>,
"OwnerAuthorization"->True]` → service 再起動(rule105 §8)で反映。

### SourceVaultRunCaneAnomalyWorkflow[input, opts] / SourceVaultCaneAnomalyWorkflowRuns[opts]
観測専用ワークフロー本体。`input=<|"Streams"-><|streamKind->streamData...|>, ("Window")|>`。段階: baseline 維持 →
stream 別逸脱検知 → lineage 分類 → 事前登録 active pair のみ相関 → hypothesis → report。**owner 状態ストリームは
OwnerStateOptIn 無しに読まない**(SkippedOwnerStateStreams。受入 100)。`ProfileVersion x InputSnapshotDigest x Window`
の idempotency key で**冪等**(再実行は既存 completed run を再利用、event/baseline を二重更新しない=§4.23)。
戻り値 `CaneAnomalyWorkflowRun` は `Enforcement->"ObserveOnly", EnforcementActions->{}`(Notifications/Containments
キーを持たない)。Runs は run record を新しい順に返す(Options `"Limit"`)。

### SourceVaultCaneDiagnosticsProbe[] / SourceVaultCaneSensitiveDoctor[opts] / SourceVaultRegisterCaneDiagnostics[]
**二層分離**(§5.15)。通常 probe は `<|"Health"->"OK"|"Degraded"|"Failing","ReasonCode"->"PipelineHealthy"|
"PipelineStale"|"PipelineFailed"|>` **のみ**。Health は検知 pipeline の liveness だけで決まり、**sensitive alert の
有無で変化しない**(PendingSensitiveAlerts/owner 状態/hypothesis id/SLV ref を出さない)。SensitiveDoctor は local UI
限定の詳細(逸脱・仮説・lineage・分母/coverage・PendingSensitiveAlerts。heartbeat/cloud/mail に出してはならない)。
Register は `SourceVaultDiagnosticsRegisterProbe` へ弱く冪等に登録(未ロードなら no-op=rule 11)。
