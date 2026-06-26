# SourceVault`Mining API Reference
パッケージ: `SourceVault_mining` | GitHub: https://github.com/transreal/SourceVault_mining
依存: [SourceVault](https://github.com/transreal/SourceVault), [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator), [NBAccess](https://github.com/transreal/NBAccess)

## TagAssertion (§3.1)

### SourceVaultMakeTagAssertion[targetURI, tag, opts]
由来つき TagAssertion レコード (§3.1) を作る純関数。
→ Association
Options: "SourceKind" -> "Mining" (Manual/Imported/Mining/System), "TagClass" -> "TopicTag" (UserTag/TopicTag/AccessTag/DenyTag/Facet), "TagNamespace" -> Missing, "Confidence" -> 0.85, "ReviewState" -> Automatic, "AccessImpact" -> Missing, "SourceRef" -> Missing, "CreatedBy" -> Missing, "CreatedAtUTC" -> Automatic, "EvidenceRefs" -> {}, "ExpiresAtUTC" -> Missing, "AccessLevel" -> 0.85, "TagAssertionID" -> Automatic, "Status" -> "active"

### SourceVaultTagAssertionEvent[assertion]
TagAssertion を EventClass="TagAsserted" の event Association に包む。EventID/CreatedAtUTC/Digest は SourceVaultAppendEvent が補完する。
→ Association

### SourceVaultReplayTagAssertions[events]
event list を replay し TagAsserted の Assertion に後続 TagDecisionRecorded (accept/reject/snooze) と TagAssertionSuperseded を適用した最終 assertion list を返す純関数。
→ List

### SourceVaultTagAssertionSupersededEvent[tagAssertionID, opts]
tag を Status=superseded にする EventClass="TagAssertionSuperseded" の event を作る。
→ Association
Options: "SupersededBy" -> Missing, "SupersededAtUTC" -> Automatic

### SourceVaultTagDecisionEvent[tagAssertionID, decision, opts]
accept/reject/snooze の判断を EventClass="TagDecisionRecorded" の event Association にする。decision: "accept" (Status->active, ReviewState->HumanReviewed) / "reject" (Status->rejected)。
→ Association
Options: "Reviewer" -> "owner", "Reason" -> Missing, "DecidedAtUTC" -> Automatic

### SourceVaultObjectTags[assertions, targetURI, opts]
TagAssertion list から object のタグ projection (§3.4) を作る純関数。active のみ採用 / 明示 rejected は同 SourceKind+Tag を抑制 / Manual active は残る / ExpiresAtUTC 経過は除外 / tombstone target は空 / loosening AccessTag は human review 済みのみ AccessTags (未レビューは PendingAccessTags)。
→ `<|"Tags", "TopicTags", "AccessTags", "PendingAccessTags", "DenyTags", "Assertions"|>`
Options: "Now" -> Automatic (ExpiresAtUTC 比較の基準 UTC), "TombstonedTargets" -> {} (除外する targetURI list)

### SourceVaultEagleTagsToAssertions[targetURI, eagleTags, opts]
Eagle 由来タグを SourceKind=Imported / TagNamespace=Eagle の TagAssertion list に変換する (§3.2)。
→ List
Options: "EagleItemRef" -> Missing, "CreatedAtUTC" -> Automatic

### SourceVaultAssertTag[targetURI, tag, opts]
TagAssertion を作り EventClass="TagAsserted" event として SourceVaultAppendEvent で正準ストアに追加する (I/O)。opts は SourceVaultMakeTagAssertion と同じ。
→ `<|"Status", "TagAssertionID", "EventRef", "Assertion"|>`

## Identity / Authorship (§2.2 / §2.3)

### SourceVaultMakeAuthorshipAssertion[objectURI, opts]
object と著者/送信者/作成者の関係 (§2.2) を作る。EntityRef は確定 entity がある場合のみ補完し、候補段階では入れない。
→ Association
Options: "Role" -> "Author", "IdentifierRef" -> Missing["NoIdentifier"], "EntityRef" -> Missing["Unlinked"], "ObjectClass" -> Missing, "DisplayName" -> Missing, "SourceField" -> Missing, "ExtractionSource" -> "parser", "Confidence" -> 1.0, "EvidenceRefs" -> {}, "AccessLevel" -> 0.85, "CreatedAtUTC" -> Automatic, "AuthorshipID" -> Automatic, "Status" -> "active"

### SourceVaultAuthorshipObservedEvent[assertion]
AuthorshipAssertion を EventClass="AuthorshipObserved" の event にする。
→ Association

### SourceVaultObjectAuthorships[assertions, objectURI]
object の active な authorship assertion list を返す純関数。
→ List

### SourceVaultMakeEntityLinkProposal[identifierRef, entityRef, opts]
Identifier↔Entity の候補リンク (§2.3) を作る。確定リンクとは分離し Status 既定 pending。
→ Association
Options: "CandidateKind" -> "SamePerson", "Score" -> Missing, "ScoreVersion" -> Missing, "FeatureVector" -> {}, "ProposedByRunID" -> Missing, "CreatedAtUTC" -> Automatic, "AccessLevel" -> 0.85

### SourceVaultEntityLinkProposedEvent[proposal]
EntityLinkProposal を EventClass="EntityLinkProposed" の event にする。
→ Association

### SourceVaultEntityLinkDecisionEvent[proposalID, decision, opts]
accept/reject/snooze を EventClass="EntityLinkDecisionRecorded" の event にする。accept->accepted, reject->rejected, snooze->pending。
→ Association

### SourceVaultReplayEntityLinkProposals[events]
EntityLinkProposed に後続 EntityLinkDecisionRecorded を DecidedAtUTC 順で適用した最終 proposal list を返す純関数。人間判断 (accept/reject) は再スコアで覆さない。
→ List

### SourceVaultEntityLinkProposals[proposals, opts]
proposal を filter する。
→ List
Options: "Status" -> All, "IdentifierRef" -> All, "EntityRef" -> All

### SourceVaultEntityLinkAutoConfirmEligibleQ[proposal, allProposals, policy, opts]
自動確定可否を返す。条件: policy["Enabled"] かつ Score>=policy["Threshold"] かつ 同 (Identifier,Entity) の明示 reject 履歴なし、かつ proposal 対象に blocking severity の open ErrorBook が無い・audit suspension 中でない (§10.5)。初期運用は policy["Enabled"]->False (human-in-the-loop only)。
→ True | False
Options: "OpenErrorBookEntries" -> {}, "AuditSuspendedRefs" -> {}

### SourceVaultAssertAuthorship[objectURI, opts]
AuthorshipAssertion を作り EventClass="AuthorshipObserved" event として SourceVaultAppendEvent で正準ストアに追加する (I/O)。
→ `<|"Status", "AuthorshipID", "EventRef", "Assertion"|>`

### SourceVaultProposeEntityLink[identifierRef, entityRef, opts]
EntityLinkProposal を作り EventClass="EntityLinkProposed" event として追加する (I/O)。
→ `<|"Status", "ProposalID", "EventRef", "Proposal"|>`

### SourceVaultDecideEntityLink[proposalID, decision, opts]
accept/reject/snooze を EventClass="EntityLinkDecisionRecorded" event として追加する (I/O)。
→ `<|"Status", "ProposalID", "Decision", "EventRef"|>`

## 決定論的抽出 (Mining Phase 1)

### SourceVaultEagleRowToAssertions[row, objectURI, opts]
Eagle summary row (Tags list / Authors 文字列) を TagAssertion (Imported) と AuthorshipAssertion (Role Author, ExtractionSource parser) に投影する純関数。
→ `<|"TagAssertions", "AuthorshipAssertions"|>`
Options: "EagleItemRef" -> Missing, "CreatedAtUTC" -> Automatic, "AuthorConfidence" -> 0.9

### SourceVaultMailToAuthorship[snapshot, objectURI, opts]
SourceVaultMailSnapshot の From (MailMetadataPublic.From) を AuthorshipAssertion (Role Sender, ExtractionSource MailHeader) に投影する純関数。From が暗号化/欠落なら Missing を返す。EntityRef は確定しないので入れない。
→ Association | Missing
Options: "CreatedAtUTC" -> Automatic

### SourceVaultCommitAssertions[assertions]
TagAssertion/AuthorshipAssertion/EntityLinkProposal の list を種別判定し対応 event (TagAsserted/AuthorshipObserved/EntityLinkProposed) で SourceVaultAppendEvent に commit する (I/O)。
→ `<|"Committed", "Failed", "Results"|>`

### SourceVaultExtractFromEagleRow[row, objectURI, opts]
Eagle summary row を投影し TagAssertion と AuthorshipAssertion を実 vault に commit する (I/O)。戻り値は SourceVaultCommitAssertions と同じ。

### SourceVaultExtractFromMailSnapshot[snapshot, objectURI, opts]
mail snapshot の From を AuthorshipAssertion に投影し実 vault に commit する (I/O)。From が暗号化/欠落なら Skipped->True。

### SourceVaultExtractAllMail[opts]
mail snapshot 群の From を Sender authorship に投影・commit するバッチ (I/O)。objectURI 規約は sv://mail/<RecordId>。"SkipExisting"->True で冪等化。
→ `<|"Processed", "Committed", "Skipped", "AlreadyPresent"|>`
Options: "Snapshots" -> Automatic (SourceVaultMailSnapshotList[] を実呼び), "SkipExisting" -> True

### SourceVaultExtractAllEagle[opts]
Eagle summary row 群を投影・commit するバッチ (I/O)。
→ `<|"Processed", "Committed"|>`
Options: "Rows" -> {}

## Security Pre-scan (§15.6.3.1)

### SourceVaultSecurityPreScan[text]
LLM を使わない deterministic な prompt injection / tool misuse / credential / 難読化 (不可視 Unicode, HTML comment) 検査を行い assessment Association を返す。既知パターンの first-pass であり false negative はありうる (多層防御の一層、LLM judge の前段)。pre-scan risk は後段 LLM judge で下げられない。
→ `<|"RiskVector", "SafetyScore", "SafetyState", "TextTrustState", "MatchedRules", "RequiresLLMIsolation", "RecommendedAction"|>`
SafetyState: "active" (SafetyScore<0.35) / "warning" (0.35<=score<0.65) / "quarantined" (score>=0.65 または CredentialExfiltration>=0.5)

### SourceVaultSafetyQuarantinedQ[assessment]
SecurityPreScan 結果が quarantined か返す。True の object は後続 LLM mining / compile / reasoning retrieval から除外する (safety gate)。
→ True | False

## 検索 Ranking 統合 (§8.3)

### SourceVaultTagMatchScore[tagsProjection, queryTags]
ObjectTags projection と query tags の一致を SourceKind 重み (Manual=1.0 > Imported=0.8 > Mining=0.5 > System=0.3) × confidence で 0..1 に scoring する純関数。
→ Real

### SourceVaultAuthorMatchScore[authorships, queryRef, opts]
author 一致 score。確定 EntityRef 一致=1.0、IdentifierRef 候補一致 (IncludeCandidate->True 時)=CandidateScore、不一致=0.0。
→ Real
Options: "IncludeCandidate" -> False, "CandidateScore" -> 0.5

### SourceVaultMiningBoost[tagsProjection, authorships, opts]
tag/author 一致 (relevance) と ObjectSignals importance (salience) の Max を MaxBoost で bounded した ranking boost を返す。OwnerDismissed の object は importance 寄与を抑制。AccessLevel/SafetyState/release gate は緩めない (ranking のみ)。
→ Real (0..MaxBoost)
Options: "QueryTags" -> {}, "QueryAuthor" -> None, "MaxBoost" -> 0.2, "IncludeCandidate" -> False, "ObjectSignals" -> <||>, "ImportanceWeight" -> 1.0

### SourceVaultMiningRerank[searchResults, opts]
既存 SourceVaultSearch の SearchResult に mining boost を足して並べ替える。各 result の "MiningProjection" -> <|"Tags"->ObjectTags projection, "Authorships"->authorship list|> を参照する。既存検索は改変しない。戻り値は Score+boost=RankScore 降順。
→ List
Options: "QueryTags" -> {}, "QueryAuthor" -> None, "MaxBoost" -> 0.2, "IncludeCandidate" -> False, "AssertionsKey" -> Automatic

### SourceVaultMinedSearch[query, opts]
SourceVaultSearch を呼び、各 SearchResult に MiningProjection (タグ/著者/ObjectSignals を event log から再構成) を後付けして SourceVaultMiningRerank で並べ替える opt-in ラッパー。既存 SourceVaultSearch は無改変。一致が無ければ boost 0 (順位そのまま=安全な no-op)。
→ List
Options: "QueryTags" -> {}, "QueryAuthor" -> None, "MaxBoost" -> 0.2, "IncludeCandidate" -> False, "EventLimit" -> 5000, "SearchFn" -> SourceVaultSearch (テスト用注入可)。その他 opts は SourceVaultSearch に渡す。

## 記憶代謝 / 検証 (§10.2)

### SourceVaultMakeDiagnosticProbe[targetURI, question, opts]
compiled wiki/projection が保持すべき情報を検査する probe (§10.2.1) を作る。
→ Association
Options: "ProbeKind" -> "QA" (QA/FactPresence/LinkPresence/TagPresence/Contradiction/AccessPolicy), "ExpectedAnswer" -> Missing, "SourceEvidenceRefs" -> {}, "MustPreserve" -> False, "CreatedFrom" -> "workflow", "Status" -> "active", "ProbeID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultDiagnosticProbeAddedEvent[probe]
EventClass="DiagnosticProbeAdded" の event を作る。
→ Association

### SourceVaultMakeProbeRun[probeID, result, opts]
probe の実行結果 (§10.2.2) を作る。result=pass/fail/partial/inconclusive。
→ Association
Options: "RunID" -> Missing, "EvaluatedArtifactRef" -> Missing, "Score" -> 0.0, "ObservedAnswer" -> Missing, "FailureClass" -> Missing (missingFact/wrongLink/wrongTag/accessBlocked/insufficientRetrieval), "ErrorBookRef" -> Missing, "ProbeRunID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultProbeRunRecordedEvent[run]
EventClass="ProbeRunRecorded" の event を作る。
→ Association

### SourceVaultMakeErrorBookEntry[errorClass, symptom, opts]
失敗の永続記録 (§10.2.5) を作る。Status 既定 open。
→ Association
Options: "TargetRefs" -> {}, "Diagnosis" -> Missing, "EvidenceRefs" -> {}, "Severity" -> "warning" (info/warning/blocking), "ProposedFix" -> Missing, "OpenedByRunID" -> Missing

### SourceVaultErrorBookAddedEvent[entry]
EventClass="ErrorBookEntryAdded" の event を作る。
→ Association

### SourceVaultErrorBookClosedEvent[errorID, opts]
EventClass="ErrorBookEntryClosed" の event を作る (Status->fixed)。
→ Association

### SourceVaultErrorBookReopenedEvent[errorID, opts]
EventClass="ErrorBookEntryReopened" の event を作る (Status->open)。
→ Association

### SourceVaultReplayErrorBook[events]
Added に Closed/Reopened を時刻順適用した最終 entry list を返す純関数 (open->fixed->open)。
→ List

### SourceVaultOpenErrorBookEntries[entries]
Status が open/monitoring の entry を返す。
→ List

### SourceVaultErrorReopenRate[events]
closed した entry のうち reopened された比率 (vitality 指標)。
→ Real | Missing

### SourceVaultErrorBookBlocksAutoConfirmQ[targetRef, openEntries]
targetRef に対する blocking severity の open ErrorBook entry があれば True (§10.5: 自動確定停止)。
→ True | False

### SourceVaultMakePinnedFact[factKind, targetURI, fact, opts]
次回 compilation に保持させる固定 fact (§10.2.3) を作る。
→ Association
Options: "SourceEvidenceRefs" -> {}, "CreatedByProbeRunID" -> Missing, "ConstraintStrength" -> "ShouldPreserve" (MustPreserve/ShouldPreserve/NegativeConstraint), "ReviewState" -> "NeedsReview"

### SourceVaultPinnedFactAddedEvent[fact]
EventClass="PinnedFactAdded" の event を作る。
→ Association

### SourceVaultProbeRunToPinnedFact[probeRun, factKind, targetURI, fact]
失敗 probe で失われた fact を PinnedFact に昇格する (§10.3-2)。ConstraintStrength=MustPreserve, ReviewState=NeedsReview, CreatedByProbeRunID=run。
→ Association

## ObjectSignals / Importance (§8.8.4)

### SourceVaultMakeObjectInteraction[targetURI, actorKind, interactionKind, opts]
owner/LLM/workflow の操作観測 (§8.8.4) を作る。actorKind=Owner/LLM/Workflow/System。interactionKind=Open/Read/MarkRead/SearchClick/ContextInclude/Cite/Edit/Annotate/Tag/Pin/Dismiss 等。Weight は InteractionKind 別の既定値を持ち opts で上書き可。
→ Association
既定 Weight: ContextInclude/Cite/Edit/Pin=1.0, Annotate/Tag/Star=0.8, Accept=0.7, SearchClick=0.4, Open/Read=0.3, Reject/Dismiss=0.2..0.3
Options: "Weight" -> Automatic, "ObjectClass" -> Missing, "ActorID" -> Missing, "QueryRef" -> Missing, "RunID" -> Missing, "ContextRef" -> Missing, "AccessLevel" -> 0.85, "InteractionID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultObjectInteractionRecordedEvent[interaction]
EventClass="ObjectInteractionRecorded" の event を作る。
→ Association

### SourceVaultObjectImportanceSetEvent[targetURI, actorKind, importance, opts]
owner/LLM の明示重要度 (0..1) を EventClass="ObjectImportanceSet" で記録する。
→ Association

### SourceVaultReplayObjectSignals[events, targetURI]
ObjectInteraction/ImportanceSet から ObjectSignals projection を再生成する純関数。LLM 寄与は 0.7 係数で抑制 (自己増幅防止)。importance は AccessLevel/SafetyState/release gate を緩めない。
→ `<|"OwnerRefCount", "LLMRefCount", "OwnerImportance", "LLMImportance", "PinState", "OwnerReadState", "OwnerDismissed", "EffectiveImportance"|>`

## 記憶代謝 残テーブル (§10.2.7/10.2.8/10.2.9)

### SourceVaultMakeMemoryBranch[branchKind, opts]
少数仮説/競合を早期に消さず保持する branch (§10.2.7) を作る。branchKind=MinorityHypothesis/AlternativeEntityLink/AlternativeTag/PageRevision。
→ Association
Options: "TargetRefs" -> {}, "Rationale" -> "", "Gravity" -> 0.5, "Status" -> "active", "ReviewAfterUTC" -> Missing, "BranchID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultMemoryBranchOpenedEvent[branch]
EventClass="MemoryBranchOpened" の event を作る。
→ Association

### SourceVaultMakeAuditRecord[targetRef, opts]
確定済み link/tag/claim の一時停止検査 (§10.2.8) を作る。
→ Association
Options: "AuditKind" -> "Suspension" (Suspension/Challenge/Reaffirmation/ImpactTest), "SuspendedProjectionRefs" -> {}, "ProbeRunRefs" -> {}, "Outcome" -> "needsReview" (reaffirmed/weakened/reversed/needsReview), "AuditID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultAuditRecordAddedEvent[audit]
EventClass="AuditRecordAdded" の event を作る。
→ Association

### SourceVaultProbePassRate[probeRuns]
probe run list の pass/total を返す (空は Missing)。
→ Real | Missing

### SourceVaultMemoryVitalityScore[scopeRef, opts]
記憶の健全性指標 (§10.2.9) を返す。dashboard 専用・近似で、検索 ranking には使わない。ProbePassRate と ErrorReopenRate は本実装で算出、CoherenceStability/FragilityResistance/MinorityInfluence は近似 proxy を opts で与える。
→ Association
Options: "ProbeRuns" -> {}, "Events" -> {} (ErrorBook events), "CoherenceStability" -> 0.7, "FragilityResistance" -> 0.7, "MinorityInfluence" -> 0.5, "MetacognitiveAssessments" -> {}, "UncertaintyOutcomes" -> {}

### SourceVaultMetacognitiveFaithfulnessScore[maList]
MA 群の cMFG 近似 = 1 - Mean[Abs[FaithfulnessGap]] を返す (§8.8.5.1)。gap が Missing の MA は除外。該当無しは Missing。集計指標なので Abs を使う (per-instance は ConfidentErrorRisk/OverHedgeRisk)。
→ Real | Missing

### SourceVaultUncertaintyDiscrimination[outcomes]
IntrinsicUncertainty が事後正誤を弁別できたかの AUROC 近似 (§8.8.5.1)。outcomes = {<|"IntrinsicUncertainty"->u, "Correct"->True|False|>, ...}。誤り側の不確実性が高いほど 1 に近づく。ground truth は owner 訂正・ProbeRun・ErrorBook から供給。正例(誤り)/負例(正答)のどちらか欠けると Missing。
→ Real | Missing

## CompilationConstraint (§10.2.4)

### SourceVaultMakeCompilationConstraint[constraintKind, opts]
pinned fact/ErrorBook/policy 由来の workflow 制約 (§10.2.4) を作る。constraintKind=PreserveFact/PreserveMinority/AvoidLink/AvoidTag/AccessGuard/StructuralRule。
→ Association
Options: "AppliesTo" -> "workflow", "Payload" -> <||>, "SourceRef" -> Missing, "Active" -> True, "ConstraintID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultCompilationConstraintAddedEvent[constraint]
EventClass="CompilationConstraintAdded" の event を作る。
→ Association

### SourceVaultPinnedFactToConstraint[pinnedFact]
PinnedFact を ConstraintKind=PreserveFact の CompilationConstraint に変換する (§10.4)。
→ Association

## Mining Workflow 骨格 (§7.1 / §9.4)

### SourceVaultRunMiningPipeline[objects, opts]
mining workflow の骨格。各 object を SecurityPreScan し、quarantined object は後続 extractor に渡さない (safety gate)。deterministic でも LLM でも ExtractorFn に注入可。
→ `<|"Processed", "Quarantined", "Extracted", "Results"|>`
Options: "TextFn" -> Automatic (object["Text"]), "ExtractorFn" -> Automatic, "AssessUncertainty" -> True, "UncertaintyFn" -> Automatic

### SourceVaultIterateUntilStable[fn, init, opts]
compile-refine/reasoning retrieval の反復骨格 (§9.4.1/§9.4.3)。fn[state, i] を反復し、MaxIterations 到達か NoProgressTermination (同一署名再掲) で停止する。
→ `<|"State", "Iterations", "Stopped"|>`
Options: "MaxIterations" -> 2, "NoProgressTermination" -> True, "SignatureFn" -> Hash

## 実 LLM Extractor (§6.1)

### SourceVaultLLMExtractAuthors[text, objectURI, opts]
LLM で著者名を抽出し AuthorshipAssertion (ExtractionSource=LLM) を返す。text を UNTRUSTED data として system prompt で隔離・data boundary で囲み、tool を渡さず、JSON 配列出力に限定、local model 既定 (rev6 isolation)。LLM 不達は Missing、JSON 失敗は {}。
→ List | Missing
Options: "LLMFn" -> Automatic (SourceVaultQueryLocalLLM), "Confidence" -> 0.7

### SourceVaultQueryLocalLLM[prompt, timeout]
local LM Studio (OpenAI 互換 chat.completions, $ClaudePrivateModel) に temperature 0・tool 無しで問い合わせ、応答文字列を返す。接続不可は Missing。Authorization Bearer token は $SourceVaultLocalLLMKey -> NBAccess`NBGetLocalLLMAPIKey -> "lm-studio" の順で解決。
→ String | Missing

### $SourceVaultLocalLLMKey
型: String | Automatic, 初期値: Automatic
local LLM (LM Studio) の API token override。未設定 (Automatic) なら NBAccess`NBGetLocalLLMAPIKey、それも無ければ "lm-studio"。

## ClaudeOrchestrator 統合 (§6.3)

### SourceVaultRunIdentityTagMining[objects, opts]
mining を実行する公開 API。ClaudeOrchestrator が利用可能なら WorkflowNet として実行し、無ければ RunMiningPipeline 直接にフォールバックする (§6.3)。
→ `<|"Mode" -> "Orchestrator"|"Direct", ...|>` (Direct は "Pipeline", Orchestrator は "WorkflowId"/"Result")
Options: "ExtractorFn" -> Automatic, "UseOrchestrator" -> Automatic

## 本番フロー結線 (§6.3 / §15.6)

### $SourceVaultMiningProductionHooksEnabled
型: True | False, 初期値: True
mining の本番フック (メールサマリー pre-scan 等) を SourceVault ロード時に自動装着するかのトグル。False にすると素の mining 関数のみで自動結線しない。

### SourceVaultMiningSafetyEnricher[mailspec, snapshot]
mailspec の body を SourceVaultSecurityPreScan で検査し、quarantined なら body を安全注記へ置換して LLM 要約器に汚染本文を渡さない enricher (§15.6)。正常時は body 不変。いずれも _safetyState (_ 接頭辞=LLM 非送信メタ) を mailspec に付す。SourceVaultRegisterMailspecEnricher 経由でサマリー生成直前に呼ばれる。

### SourceVaultMiningAuthorshipFetchHook[mbox, fetchResult]
SourceVaultMailFetchNew の post-fetch フック。新着/更新があれば SourceVaultExtractAllMail (冪等) を呼び From を Sender authorship として記録する。SourceVaultRegisterPostFetchHook 経由で呼ばれる。新着が無ければ何もしない。

### SourceVaultMiningWireProductionHooks[opts]
mining を既存フローへ結線する (冪等)。(1) メール派生に "security-prescan" enricher、(2) メール取り込みに "mining-authorship" フック、(3) metacog enricher を登録。依存先 API が無ければその結線は skip。SourceVault ロード末尾で自動呼び出し。
→ `<|"Status", "Wired", "Skipped"|>`
Options: "Force" -> False ($SourceVaultMiningProductionHooksEnabled=False でも強制装着)

### SourceVaultMiningUnwireProductionHooks[]
SourceVaultMiningWireProductionHooks が装着したフックを解除する。

## MetacognitiveAssessment / Faithful Uncertainty (§8.8.5)

### SourceVaultMakeMetacognitiveAssessment[targetRef, opts]
faithful-uncertainty 評価 (§8.8.5) の record を作る。IntrinsicUncertainty / ExpressedUncertainty から IntrinsicConfidence・FaithfulnessGap・ConfidentErrorRisk=Max[0,gap]・OverHedgeRisk=Max[0,-gap] を導出する (arXiv:2605.01428)。取得不能な不確実性は Missing のままにし、依存導出値も Missing にする。
→ Association
Options: "AssessmentScope" -> "Claim", "IntrinsicUncertainty" -> Missing, "ExpressedUncertainty" -> Missing, "EvidenceSufficiency" -> Missing, "UncertaintyKind" -> {} ({Aleatoric|Epistemic|Normative}), "RecommendedAction" -> Automatic (導出), "ConflictWithRetrievedEvidence" -> False, "LinguisticMarker" -> Missing, "RunID" -> Missing, "AccessLevel" -> 0.85

### SourceVaultMetacognitiveAssessmentToMiningObject[a]
MetacognitiveAssessment を正準 MiningObject (MiningObjectType -> "MetacognitiveAssessment") に写す (§8.8.5.1)。
→ Association

### SourceVaultMiningObjectAddedEvent[obj]
MiningObject を EventClass="MiningObjectAdded" の event に包む (正準 fact)。
→ Association

### SourceVaultMetacognitiveAssessmentEvent[a]
EventClass="MetacognitiveAssessmentAdded" の wrapper event を作る。同一 MiningObjectID を保持し、replay では MiningObjectAdded と重複登録しない (§8.8.5.1)。
→ Association

### SourceVaultReplayMetacognitiveAssessments[events]
MiningObjectAdded[MetacognitiveAssessment] と MetacognitiveAssessmentAdded を replay し、MiningObjectID で dedup した assessment list を返す純関数。
→ List

### SourceVaultMetacognitiveBlocksAutoConfirmQ[a, opts]
不変条件 (§8.8.5) を判定する: EvidenceSufficiency が低い、ConfidentErrorRisk が高い、または ConflictWithRetrievedEvidence のとき True (自動確定を止める)。
→ True | False
Options: "EvidenceSufficiencyMin" -> 0.6, "ConfidentErrorRiskMax" -> 0.5

### SourceVaultAddMetacognitiveAssessment[a, opts]
assessment を append-only event として保存する wrapper (I/O)。既定 "EmitMiningObjectEvent"->True で正準 MiningObjectAdded を emit する。SourceVaultAppendEvent が無ければ event を返す。
Options: "EmitMiningObjectEvent" -> True

### SourceVaultMailMetacognitiveAssessment[signals, opts]
メール派生(要約)前に使う MA ビルダ (§8.8.5, Appendix A.1)。signals=<|SafetyState, SenderAuthenticated, DeliveryAnomalyScore, HasAttachments, AttachmentsRead, TargetRef|> から EvidenceSufficiency と ConflictWithRetrievedEvidence・RecommendedAction を導出する。IntrinsicUncertainty は LLM 前には取れず Missing。
→ Association

### SourceVaultMiningMetacognitiveEnricher[mailspec, snapshot]
SourceVaultMailMetacognitiveAssessment を用いて mailspec に _metacogAction / _metacogEvidenceSufficiency / _metacogConflict / _metacogState (_ 接頭辞=LLM 非送信メタ) を付す enricher。SourceVaultMiningWireProductionHooks が security-prescan の後に "metacog" として登録する。

## Mail Headers / Delivery Observations (§8.1.1)

### SourceVaultParseMailHeaders[rawHeader, opts]
raw RFC5322 header を構造化する (§8.1.1)。折返し行を unfold し、HeaderFieldsOrdered(重複・順序保持)/ParsedHeaders/ReceivedChain(上から)/AuthenticationResults/DKIMSignatures/SPF・DKIM・DMARC・ARCResult/OriginatingIPRefs/RawHeaderHash/ReceivedHopCount を返す。認証解析は SourceVaultParseAuthenticationResults があれば流用、無ければ regex。
→ Association
Options: "HeaderAccessLevel" -> 0.85

### SourceVaultMailDeliveryObservation[mailHeaders, opts]
MailHeaders から配送経路 feature (§8.1.1 MailDeliveryObservations) を作る。ReceivedHopCount/OriginatingIPRefs/Relay 国・ASN・Org/SPF・DKIM・DMARCResult。
→ Association
Options: "GeoFn" -> Automatic (ip->Assoc[Country/ASN/Org])

### SourceVaultMailDeliveryAnomalyScore[observation, baseline, opts]
通常配送 profile からの外れを採点する。baseline=<|Countries, ASNs, Orgs|> (private profile, AccessLevel 1.0 で別管理)。spoofing と断定せず benign 仮説も保持し MA へ conflict として渡す。baseline 空なら country/ASN は flag しない (auth failure のみ)。
→ `<|"DeliveryAnomalyScore", "DeliveryAnomalyKinds", "BenignExceptionHypotheses", "RecommendedAction"|>`
DeliveryAnomalyKinds: UnexpectedCountry/UnexpectedASN/AuthFailure
BenignExceptionHypotheses: Travel/VPN/転送/ML relay

### SourceVaultMailHeadersCapturedEvent[mh]
EventClass="MailHeadersCaptured" の event を作る。
→ Association

### SourceVaultMailDeliveryObservationAddedEvent[obs]
EventClass="MailDeliveryObservationAdded" の event を作る。
→ Association

### SourceVaultMailDeliveryAnomalyDetectedEvent[obs, anomaly]
EventClass="MailDeliveryAnomalyDetected" の event を作る。
→ Association

### SourceVaultMiningMailHeaderObservation[rawHeader, opts]
raw RFC5322 header を parse→DeliveryObservation→anomaly し、<|MailHeaders, Observation, Anomaly, SnapshotFeatures, Events|> を返す純関数 (§8.1.1)。SnapshotFeatures は raw header を載せず coarse な feature のみ (privacy 保全)。DeliveryAnomalyScore は metacog enricher の conflict 入力になる。GeoFn/Baseline 省略時は $SourceVaultMailGeoFn と送信者ドメインの登録 baseline から自動解決する。
→ `<|"MailHeaders", "Observation", "Anomaly", "SnapshotFeatures", "Events"|>`
Options: "Baseline" -> Automatic (<|Countries,ASNs|>), "GeoFn" -> Automatic, "SourceID" -> Missing, "HeaderAccessLevel" -> 0.85

### $SourceVaultMailGeoFn
型: Function | Automatic, 初期値: Automatic
IP 文字列→<|Country,ASN,Org|> を返す関数。Automatic=geo 無し。設定すると mail 配送 anomaly が国/ASN ベースで効く。GeoIP データ源はユーザー注入。opt-in: SourceVaultMailGeoLookup を明示設定したときだけ有効化する。

### $SourceVaultMailDeliveryBaselineFn
型: Function | Automatic, 初期値: Automatic
<|FromDomain,From|>→baseline <|Countries,ASNs|> を返す関数。Automatic=ドメイン登録 baseline を引く。

### SourceVaultMailDeliveryBaseline[domain]
登録済み配送 baseline を返す (無ければ <||>)。
→ Association

### SourceVaultSetMailDeliveryBaseline[domain, baseline]
送信者ドメインの通常配送 baseline を登録する (private operational profile, AccessLevel 1.0 相当・local 限定)。

### SourceVaultSaveMailDeliveryBaselines[opts]
baseline を $UserBaseDirectory/SourceVault/private (Dropbox 非同期=local 限定) に保存する。鍵初期化済なら SourceVaultSealPayload で encrypt-then-MAC 暗号化 at-rest、未初期化なら平文 fallback (警告付)。
Options: "Path" -> Automatic

### SourceVaultLoadMailDeliveryBaselines[opts]
保存済み baseline を読み込む (暗号化 record は SourceVaultUnsealPayload で復号、平文はそのまま)。
Options: "Path" -> Automatic

### SourceVaultMailGeoLookup[ip]
IP→<|Country,ASN,Org|> を ip-api.com で照会する (無料/キー不要)。内部/予約 IP は問い合わせず Missing、結果は $SourceVaultMailGeoCache にキャッシュ。privacy: public relay IP を外部送信するため $SourceVaultMailGeoFn = SourceVaultMailGeoLookup と明示設定したときだけ有効化する (opt-in)。
→ Association | Missing

### SourceVaultSaveMailGeoCache[]
GeoIP キャッシュを local (Dropbox 非同期) に保存する。

### SourceVaultLoadMailGeoCache[]
GeoIP キャッシュを読み込む。

### SourceVaultLearnMailDeliveryBaselines[opts]
取り込み済みメール snapshot の MailDelivery(RelayCountries/RelayASNs) を送信者ドメインごとに集約して配送 baseline を学習・登録する (GeoFn を設定して取り込んだメールが対象)。
→ `<|"Learned", "Domains", "Baselines"|>`
Options: "Snapshots" -> Automatic (MailSnapshotList), "MinObservations" -> 1, "Apply" -> True (即 SourceVaultSetMailDeliveryBaseline)

## Web 著者抽出 / TopicTag 自動マイニング (§4.1 / §11.6)

### SourceVaultExtractWebMetadata[html, opts]
raw HTML から著者・タイトル・キーワード metadata を best-effort 抽出する (§4.1)。meta name=author/citation_author/dc.creator、article:author、JSON-LD author.name、arXiv Atom author/name、keywords、title/og:title を解析。HTML 解析は regex の best-effort。
→ `<|"Title", "Authors", "Keywords", "Source"|>`

### SourceVaultWebMetadataToAuthorship[meta, objectURI, opts]
web metadata の著者を AuthorshipAssertion (Role Author) に投影する。§11.6: web/PDF metadata の著者は偽装可能なので MetadataTrustClass="UnverifiedMetadata"・Confidence 控えめ (既定 0.6)、確定 EntityRef は入れない (候補段階)。
→ List
Options: "Confidence" -> 0.6

### SourceVaultWebTopicTags[meta, objectURI, opts]
web metadata の keywords (または opts "TagFn") から TopicTag を自動マイニングする。SourceKind="Mining"・ReviewState=NeedsHumanReview・Confidence 控えめ (既定 0.5)。
→ List
Options: "TagFn" -> Automatic, "Confidence" -> 0.5

### SourceVaultWebDocumentToAssertions[doc, objectURI, opts]
web document ("HTML" or "Metadata") を投影し <|TagAssertions, AuthorshipAssertions, Metadata|> を返す純関数 (Eagle 版と対称)。
→ `<|"TagAssertions", "AuthorshipAssertions", "Metadata"|>`

### SourceVaultExtractFromWebDocument[doc, objectURI, opts]
web document を投影し SourceVaultCommitAssertions で実 vault に commit する (I/O)。

### SourceVaultMiningWebIngestAssertions[fetchResult, opts]
SourceVaultWebFetch の結果から raw HTML を読み (RawBlobRef→blob または fetchResult["RawHTML"] 注入)、著者/TopicTag を投影して返す純関数。ObjectURI 規約=sv://web/<ContentHash>。HTML 取得不可は Status="NoHTML"。
→ `<|"TagAssertions", "AuthorshipAssertions", "ObjectURI", "Status"|>`

### SourceVaultMiningWebIngestExtract[fetchResult, opts]
SourceVaultMiningWebIngestAssertions の投影を実 vault に commit する (I/O)。"SkipExisting"->True (既定) で冪等化。webingest は post-fetch hook を持たないため現状 opt-in (明示呼び出し)。
→ `<|"Committed", "AlreadyPresent", "Failed", "ObjectURI"|>`
Options: "SkipExisting" -> True

### SourceVaultMiningWebIngestHook[ctx]
SourceVaultRegisterWebIngestHook 用フック。ctx["Result"](SourceVaultWebFetch 結果)から著者/タグを冪等抽出・commit する。WireProductionHooks が "mining-webingest" として登録 (取り込み後 auto 抽出)。

## Reasoning Retrieval / WiCER (§10.4)

### SourceVaultAssessUncertainty[question, opts]
LLM の self-consistency (繰り返し sampling での矛盾率) で IntrinsicUncertainty を測り MetacognitiveAssessment を生成する (§10.4.3, arXiv:2605.01428)。Samples 回 sampling(Temperature>0)→正規化→modal 一致率=Consistency、IntrinsicUncertainty=1-Consistency。LLM 不達は Status LLMUnavailable。
→ `<|"Status", "Answer", "IntrinsicUncertainty", "Consistency", "Samples", "Assessment"|>`
Options: "Samples" -> 3, "Temperature" -> 0.7, "Evidence" -> {}, "EvidenceSufficiency" -> Missing, "TargetRef" -> Missing, "LLMFn" -> Automatic

### SourceVaultCheckRetrievalSufficiency[assessResult, opts]
assessUncertainty 結果が十分か (IntrinsicUncertainty<=IntrinsicUncertaintyMax) を判定する。
→ True | False
Options: "IntrinsicUncertaintyMax" -> 0.4

### SourceVaultReasoningRetrieve[query, opts]
agent-native retrieval (§10.4.3): assessUncertainty→(低確信なら)search→evidence 蓄積→再 assess を SourceVaultIterateUntilStable で回す。確信 (IntrinsicUncertainty<=閾値) で停止し回答、検索しても確信できない/SearchFn 無しは insufficient で ErrorBookEntry を作る。ClaudeOrchestrator 可用時は WorkflowNet で実行、無ければ直接ループ (Mode=Direct)。1 反復ロジックは純関数 iSVMReasoningStepCore を両経路で共有。
→ `<|"Mode", "Answer", "Sufficient", "Assessment", "Evidence", "Trace", "Iterations", "ErrorBookEntry"|>` (Orchestrator 時は WorkflowId/RunStatus も)
Options: "SearchFn" -> None (query→結果 list), "LLMFn" -> Automatic, "MaxIterations" -> 4, "Samples" -> 3, "Temperature" -> 0.7, "IntrinsicUncertaintyMax" -> 0.4, "TargetRef" -> Missing, "UseOrchestrator" -> Automatic

### SourceVaultRunWikiCompileRefine[source, opts]
WiCER 型 compile→evaluate→diagnose→refine を SourceVaultIterateUntilStable で回す (§10.4.1)。各反復: CompileFn[source, mustFacts]→DiagnosticProbe 評価(ProbeRun)→失敗(missingFact)は PinnedFact→CompilationConstraint に昇格し次回 compile の must-facts に→全 pass か MaxIterations/no-progress で停止。残った失敗は ErrorBook(Compilation)へ。CompileFn/EvaluateFn/LLMFn 注入可 (テスト mock)。ClaudeOrchestrator 可用時は WorkflowNet で実行、無ければ直接ループ。
→ `<|"Mode", "Artifact", "ProbeRuns", "PinnedFacts", "Constraints", "ProbePassRate", "AllPass", "Iterations", "ErrorBookEntries"|>` (Orchestrator 時は WorkflowId/RunStatus も)
Options: "Probes" -> {}, "CompileFn" -> Automatic (SourceVaultQueryLocalLLM), "EvaluateFn" -> Automatic, "LLMFn" -> Automatic, "MaxIterations" -> 2, "TargetURI" -> Missing, "UseOrchestrator" -> Automatic

## 非同期ジョブ API

### SourceVaultSubmitReasoningRetrieve[query, opts]
reasoning retrieval を ClaudeOrchestrator に非同期投入し即座に返す (FE 非ブロック)。"AsyncLLM"->True で assess の k sampling を URLSubmit で非同期化 (AwaitingLLM 機構)、HTTP 飛行中はカーネルを空ける=真の非ブロック。要 [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)。
→ `<|"WorkflowId", "Kind", "Mode", "Status"|>`
Options: SourceVaultReasoningRetrieve と同じ + "MaxWaitSeconds" -> 3600, "AsyncLLM" -> False, "SubmitFn" -> Automatic

### SourceVaultSubmitWikiCompileRefine[source, opts]
WiCER compile-refine を ClaudeOrchestrator に非同期投入し即座に返す。"AsyncLLM"->True で compile を URLSubmit で非同期化 (AwaitingLLM)。要 ClaudeOrchestrator。
→ `<|"WorkflowId", "Kind", "Mode", "Status"|>`
Options: SourceVaultRunWikiCompileRefine と同じ + "MaxWaitSeconds" -> 3600, "AsyncLLM" -> False, "SubmitFn" -> Automatic, "Temperature" -> 0.7

### SourceVaultJobStatus[wid]
非同期ジョブの進捗を返す。
→ `<|"Kind", "Status" (Running/Completed), "WorkflowStatus", "Done", "Steps", "TerminationReason"|>`

### SourceVaultJobResult[wid]
完了済みなら同期版と同形の結果を、未完了なら <|Status->Running, Steps|> を返す (Kind で抽出を振り分け)。
→ Association

### SourceVaultAwaitJob[wid, opts]
ClaudeWaitWorkflow で完了まで待ち (進捗ポーリング)、SourceVaultJobResult を返す。
Options: "PollInterval" -> Automatic, "MaxWait" -> Automatic

### SourceVaultListMiningJobs[]
投入済み非同期ジョブの一覧を返す。
→ `{<|"WorkflowId", "Kind", "Status", "SubmittedAt"|>...}`

### SourceVaultCancelJob[wid]
非同期ジョブを Cancel し registry/polling tick をクリーンアップする。