# SourceVault_taint.wl API

Cane Phase 1H-S: taint 伝播 / InputTrustAssessment / RunIntegrityState。
spec v0.7 §4.17/4.17b/4.17c/4.18/4.18b、I-14(taint 非降下)。決定的・LLM 不使用。

### SourceVaultAssessInputTrust[input]
§4.17 InputTrustAssessment(SecurityPreScan の正準化)。input は生 text か `<|InputRef, Text,
(SourceKind), (OriginRef), (InstructionAuthority), (TrustedAttestation)|>`。**InstructionAuthority は
content の自己申告で昇格しない**(既定 UntrustedData)。System/OwnerInstruction への昇格は out-of-band の
`TrustedAttestation->True`(信頼できる呼び出し経路)がある時のみ。
→ `<|ObjectClass, InputRef, SourceKind, InstructionAuthority, AdversarialSignals, PromptInjectionScore,
ToolMisuseScore, ExfiltrationScore, ObfuscationSignals, SafetyState, RequiredIsolationProfile, MatchedRules|>`

### SourceVaultTaintEdgeCarriesContentQ[edgeKind]
§4.17c 表。DerivedFrom/Contains/ExtractedFrom/SummarizedFrom/QuotedFrom/AttachmentOf=True、
Cites/RelatedTo/SameTopic/OwnerReviewed=False。

### SourceVaultComposeCrossObjectRisk[targetRef, edges, assessments]
§4.17b。source graph 上で target へ content-carrying edge 経由で到達する risk を合成(0 固定を廃止)。
→ `<|CrossObjectRisk, ContributingSpanRefs, TaintPath, InheritedSafetyState, PartialTaint, WholeQuarantined|>`

### SourceVaultPropagateTaint[derivedRef, sourceRefs, edgeKind, assessments, opts]
派生物へ source の SafetyState を継承(I-14 非降下)。content-carrying でない edge は伝播しない。
→ PropagationEdge(`CarriesContent/Propagated/ContributingSpanRefs/InheritedSafetyState`)。
Options: "ContributingSpanRefs"、"TransformRef"、"Direction"。

### SourceVaultTaintDeclassify[targetRef, decision, opts]
taint 解除。owner の明示確認(`By->"Owner", OwnerConfirmation->str`)か決定的 sanitizer
(`By->"DeterministicSanitizer", SanitizerResult->True`)のみ許可。LLM/reducer/多数決は Failure(I-14)。

### SourceVaultTransitionRunIntegrity[runRef, toState, opts] / SourceVaultRunIntegrityState[runRef]
§4.18b。RunIntegrityTransitioned(step 単位)を event 化。toState: Clean|Uncertain|CompromiseSuspected|
Contained(Clean は「既知 signal なし+gate 通過」の限定的意味で証明ではない)。RunIntegrityState は
transition の replay で現在状態と TaintLabels を返す。Options: "StepRef"、"TriggerObservationRefs"、
"AffectedArtifactRefs"、"TaintLabels"、"Persist"。
