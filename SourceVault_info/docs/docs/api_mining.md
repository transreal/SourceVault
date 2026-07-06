# SourceVault_mining API リファレンス

## 概要
SourceVault の自己組織化マイニングサブシステム。既存データ (Eagle / mail / web) から由来つき assertion を投影し、event log に append-only で記録し、検索 ranking を bounded boost で補強し、LLM 検証 (記憶代謝) で健全性を維持する。全 event は `SourceVault` context で公開され、`SourceVaultAppendEvent` を通じて正準ストアに追加される。

設計原則:
- タグは string list ではなく由来つき TagAssertion の projection。SourceKind (Manual/Imported/Mining/System) を区別し検索 ranking feature にする。
- TopicTag と AccessTag を分離。AccessTag 自動付与は既定 TightenOnly。
- mining 結果と human decision を分離。reject は削除でなく抑制 (negative)。
- tombstone / superseded object を参照する assertion は正準 record を残し projection から除外。
- 候補リンク (EntityLinkProposal) と確定リンクを分離。auto confirm 既定 off (human-in-the-loop)。
- 正準は event、projection はローカル再生成 (rev7)。LLM 寄与は 0.7 係数で抑制 (自己増幅防止)。
- boost/importance は AccessLevel/SafetyState/release gate を緩めない (ranking のみ)。

パターン: 各 record は `Make*` builder → `*Event` wrapper → `Replay*` 純関数 → projection → `*DecisionEvent` の統一形。純関数 (builder/replay/projection/score) と I/O wrapper (`Assert*`/`Extract*`/`Commit*`) を分離。ID は `CreateUUID`、時刻は UTC。

依存: [SourceVault](https://github.com/transreal/SourceVault) 本体 (`SourceVaultAppendEvent`/`SourceVaultSearch`/`SourceVaultMailSnapshot*`)、[SourceVault_eagle](https://github.com/transreal/SourceVault_eagle)、[SourceVault_maildb](https://github.com/transreal/SourceVault_maildb)、[SourceVault_webingest](https://github.com/transreal/SourceVault_webingest)、[ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) (可用時 WorkflowNet 実行、無ければ直接)、[NBAccess](https://github.com/transreal/NBAccess) (local LLM key)。

## TagAssertion (§3.1 / §3.4)

### SourceVaultMakeTagAssertion[targetURI, tag, opts]
由来つき TagAssertion record を作る純関数。
→ Association
Options: "SourceKind" -> "Mining" (Manual/Imported/Mining/System), "TagClass" -> Automatic (実効既定 TopicTag; UserTag/TopicTag/AccessTag/DenyTag/Facet), "TagNamespace" -> Automatic, "Confidence" -> Automatic, "ReviewState" -> Automatic, "AccessImpact" -> Automatic, "SourceRef", "CreatedBy" -> "workflow", "CreatedAtUTC" -> Automatic, "EvidenceRefs" -> {}, "ExpiresAtUTC", "AccessLevel" -> 0.85, "TagAssertionID" -> Automatic, "Status" -> "active", "PinnedByProbeRefs" -> {}, "ErrorBookRefs" -> {}, "AuditState" -> "none"

### SourceVaultTagAssertionEvent[assertion] → Association
TagAssertion を EventClass="TagAsserted" の event に包む。EventID/CreatedAtUTC/Digest は AppendEvent が補完する。

### SourceVaultTagAssertionSupersededEvent[tagAssertionID, opts]
tag を Status superseded にする event。
→ Association
Options: "SupersededBy", "SupersededAtUTC"

### SourceVaultTagDecisionEvent[tagAssertionID, decision, opts]
accept/reject/snooze の判断を EventClass="TagDecisionRecorded" event にする。decision: "accept" (Status->active, ReviewState->HumanReviewed) / "reject" (Status->rejected)。
→ Association
Options: "Reviewer" -> "owner", "Reason", "DecidedAtUTC", "SnoozedUntilUTC"

### SourceVaultReplayTagAssertions[events] → List
event list を replay し、TagAsserted に後続 TagDecisionRecorded と TagAssertionSuperseded を適用した最終 assertion list を返す純関数。

### SourceVaultObjectTags[assertions, targetURI, opts]
TagAssertion list から object のタグ projection (§3.4) を作る純関数。規則: active のみ採用 / 明示 rejected は同 SourceKind+Tag を抑制 / Manual active は残る / ExpiresAtUTC 経過は除外 / tombstone target は空 / loosening AccessTag は human review 済みのみ AccessTags (未レビューは PendingAccessTags)。
→ <|"Tags", "TopicTags", "AccessTags", "PendingAccessTags", "DenyTags", "Assertions"|>
Options: "Now" -> Automatic (ExpiresAtUTC 比較の基準 UTC), "TombstonedTargets" -> {} (除外する targetURI list)

### SourceVaultEagleTagsToAssertions[targetURI, eagleTags, opts]
Eagle 由来タグを SourceKind=Imported / TagNamespace=Eagle の TagAssertion list に変換 (§3.2)。
→ List
Options: "EagleItemRef" -> Missing["NoEagleRef"], "CreatedAtUTC" -> Automatic

### SourceVaultAssertTag[targetURI, tag, opts]
TagAssertion を作り TagAsserted event として AppendEvent で正準ストアに追加 (I/O)。opts は Make と同じ。
→ <|"Status", "TagAssertionID", "EventRef", "Assertion"|>

## Identity: Authorship (§2.2) / EntityLink (§2.3)

### SourceVaultMakeAuthorshipAssertion[objectURI, opts]
object と著者/送信者/作成者の関係を作る。EntityRef は確定 entity がある場合のみ補完、候補段階では入れない。
→ Association
Options: "Role" -> "Author", "IdentifierRef" -> Missing["NoIdentifier"], "EntityRef" -> Missing["Unlinked"], "ObjectClass" -> Missing["NoClass"], "DisplayName" -> Missing["NoName"], "SourceField" -> Missing["NoField"], "ExtractionSource" -> "parser", "Confidence" -> 1.0, "EvidenceRefs" -> {}, "AccessLevel" -> 0.85, "CreatedAtUTC" -> Automatic, "AuthorshipID" -> Automatic, "Status" -> "active"

### SourceVaultAuthorshipObservedEvent[assertion] → Association
AuthorshipAssertion を EventClass="AuthorshipObserved" event にする。

### SourceVaultObjectAuthorships[assertions, objectURI] → List
object の active な authorship assertion list を返す純関数。

### SourceVaultMakeEntityLinkProposal[identifierRef, entityRef, opts]
Identifier↔Entity の候補リンクを作る。確定リンクと分離、Status 既定 pending。
→ Association
Options: "CandidateKind" -> "SamePerson", "Score" -> 0.0, "ScoreVersion" -> "EntityScorer-v0", "FeatureVector" -> <||>, "PositiveEvidenceRefs" -> {}, "NegativeEvidenceRefs" -> {}, "ProposedByRunID" -> Missing["NoRun"], "CreatedAtUTC" -> Automatic, "AccessLevel" -> 0.85, "ProposalID" -> Automatic, "Status" -> "pending"

### SourceVaultEntityLinkProposedEvent[proposal] → Association
EntityLinkProposal を EventClass="EntityLinkProposed" event にする。

### SourceVaultEntityLinkDecisionEvent[proposalID, decision, opts] → Association
accept/reject/snooze を EventClass="EntityLinkDecisionRecorded" event にする。accept->accepted, reject->rejected, snooze->pending。
Options: "Reviewer" -> "owner", "Reason", "DecidedAtUTC"

### SourceVaultReplayEntityLinkProposals[events] → List
EntityLinkProposed に後続 EntityLinkDecisionRecorded を DecidedAtUTC 順で適用した最終 proposal list を返す純関数。人間判断は再スコアで覆さない。

### SourceVaultEntityLinkProposals[proposals, opts]
proposal を filter する。
→ List
Options: "Status" -> All, "IdentifierRef" -> All, "EntityRef" -> All

### SourceVaultEntityLinkAutoConfirmEligibleQ[proposal, allProposals, policy, opts]
自動確定可否。条件: policy["Enabled"] かつ Score>=policy["Threshold"] かつ 同 (Identifier,Entity) の明示 reject 履歴なし、かつ blocking open ErrorBook 無し・audit suspension 中でない (§10.5)。初期運用は policy["Enabled"]->False。
→ True|False
Options: "OpenErrorBookEntries" -> {}, "AuditSuspendedRefs" -> {}

### SourceVaultAssertAuthorship[objectURI, opts]
AuthorshipAssertion を作り AuthorshipObserved event として追加 (I/O)。
→ <|"Status", "AuthorshipID", "EventRef", "Assertion"|>

### SourceVaultProposeEntityLink[identifierRef, entityRef, opts]
EntityLinkProposal を作り EntityLinkProposed event として追加 (I/O)。
→ <|"Status", "ProposalID", "EventRef", "Proposal"|>

### SourceVaultDecideEntityLink[proposalID, decision, opts]
accept/reject/snooze を EntityLinkDecisionRecorded event として追加 (I/O)。
→ <|"Status", "ProposalID", "Decision", "EventRef"|>

## Deterministic extraction (Mining Phase 1, LLM 不使用)

### SourceVaultEagleRowToAssertions[row, objectURI, opts]
Eagle summary row (Tags list / Authors 文字列) を TagAssertion (Imported) と AuthorshipAssertion (Role Author, ExtractionSource parser) に投影する純関数。Authors は カンマ/セミコロン/読点/and/& で分割、IdentifierRef=idf:personname:<正規化名>。
→ <|"TagAssertions", "AuthorshipAssertions"|>
Options: "EagleItemRef" -> Missing["NoEagleRef"], "CreatedAtUTC" -> Automatic, "AuthorConfidence" -> 0.9

### SourceVaultMailToAuthorship[snapshot, objectURI, opts]
SourceVaultMailSnapshot の From (MailMetadataPublic.From) を AuthorshipAssertion (Role Sender, ExtractionSource MailHeader) に投影する純関数。From が暗号化/欠落なら Missing。EntityRef は入れない。
→ Association | Missing
Options: "CreatedAtUTC" -> Automatic

### SourceVaultCommitAssertions[assertions] → <|"Committed", "Failed", "Results"|>
TagAssertion/AuthorshipAssertion/EntityLinkProposal の list を種別判定し対応 event (TagAsserted/AuthorshipObserved/EntityLinkProposed) で AppendEvent に commit する (I/O)。

### SourceVaultExtractFromEagleRow[row, objectURI, opts]
Eagle row を投影し TagAssertion/AuthorshipAssertion を実 vault に commit (I/O)。戻り値は CommitAssertions と同じ。

### SourceVaultExtractFromMailSnapshot[snapshot, objectURI, opts]
mail snapshot の From を AuthorshipAssertion に投影し commit (I/O)。From 暗号化/欠落なら Skipped->True。

### SourceVaultExtractAllMail[opts]
mail snapshot 群の From を Sender authorship に投影・commit するバッチ (I/O)。objectURI 規約 sv://mail/<RecordId>。冪等 (取り込むたびに安全に再実行可)。
→ <|"Processed", "Committed", "Skipped" (From 暗号化/欠落), "AlreadyPresent" (既存で抑止)|>
Options: "Snapshots" -> Automatic (SourceVaultMailSnapshotList[] を実呼び、list 指定でテスト可), "SkipExisting" -> True (既存 authorship を replay して同 (objectURI,identifierRef) の再 commit を抑止)

### SourceVaultExtractAllEagle[opts]
Eagle summary row 群を投影・commit するバッチ (I/O)。
→ <|"Processed", "Committed"|>
Options: "Rows" -> {} (row list)

## Security pre-scan (§15.6.3.1, deterministic first-pass)

### SourceVaultSecurityPreScan[text]
LLM を使わない deterministic な prompt injection / tool misuse / credential / 難読化 (不可視 Unicode, HTML comment) 検査。既知パターンの first-pass (false negative はありうる、多層防御の一層)。閾値: CredentialExfiltration>=0.5 or Max>=0.65 -> quarantined、>=0.35 -> warning。
→ <|"RiskVector", "SafetyScore" (=Max[RiskVector]), "SafetyState" (active/warning/quarantined), "TextTrustState", "MatchedRules", "RequiresLLMIsolation", "RecommendedAction"|>

### SourceVaultSafetyQuarantinedQ[assessment] → True|False
SecurityPreScan 結果が quarantined か返す。True の object は後続 LLM mining / compile / reasoning retrieval から除外 (safety gate)。

## 検索 ranking 統合 (§8.3)
SourceKind 重み: Manual 1.0 / Imported 0.8 / Mining 0.5 / System 0.3 / その他 0.4。

### SourceVaultTagMatchScore[tagsProjection, queryTags] → Real (0..1)
ObjectTags projection と query tags の一致を SourceKind 重み × confidence で scoring する純関数。

### SourceVaultAuthorMatchScore[authorships, queryRef, opts]
author 一致 score。確定 EntityRef 一致=1.0、IdentifierRef 候補一致 (IncludeCandidate->True 時)=CandidateScore、不一致=0.0。
→ Real
Options: "IncludeCandidate" -> False, "CandidateScore" -> 0.5

### SourceVaultMiningBoost[tagsProjection, authorships, opts]
tag/author 一致 (relevance) と ObjectSignals importance (salience) の Max を MaxBoost で bounded した ranking boost。OwnerDismissed の object は importance 寄与を抑制。AccessLevel/SafetyState/release gate は緩めない。
→ Real
Options: "QueryTags" -> {}, "QueryAuthor" -> None, "MaxBoost" -> 0.2, "IncludeCandidate" -> False, "ObjectSignals" -> <||>, "ImportanceWeight" -> 1.0

### SourceVaultMiningRerank[searchResults, opts]
既存 SourceVaultSearch の SearchResult に mining boost を足して並べ替える。各 result の "MiningProjection" -> <|"Tags"->ObjectTags projection, "Authorships"->authorship list|> を参照。既存検索は無改変。
→ List (Score+boost=RankScore 降順)
Options: "QueryTags" -> {}, "QueryAuthor" -> None, "MaxBoost" -> 0.2, "IncludeCandidate" -> False, "AssertionsKey" -> "MiningProjection"

### SourceVaultMinedSearch[query, opts]
SourceVaultSearch を呼び、各 SearchResult に MiningProjection (タグ/著者/ObjectSignals を event log から再構成) を後付けして MiningRerank で並べ替える opt-in ラッパー。result の SourceVaultObjectId / Citation.DocId / 明示 ObjectURI を mining targetURI と照合、一致無しは boost 0 (順位そのまま=安全な no-op)。
→ List
Options: "QueryTags" -> {}, "QueryAuthor" -> None, "MaxBoost" -> 0.2, "IncludeCandidate" -> False, "EventLimit" -> 5000 (replay 上限), "SearchFn" -> Automatic (既定 SourceVaultSearch、テスト用注入)。その他 opts は SourceVaultSearch にそのまま渡す

## 記憶代謝 / 検証 (§10.2)

### SourceVaultMakeDiagnosticProbe[targetURI, question, opts]
compiled wiki/projection が保持すべき情報を検査する probe を作る。
→ Association
Options: "ProbeKind" -> "QA" (QA/FactPresence/LinkPresence/TagPresence/Contradiction/AccessPolicy), "ExpectedAnswer" -> Missing["NoExpected"], "SourceEvidenceRefs" -> {}, "MustPreserve" -> False, "CreatedFrom" -> "workflow", "Status" -> "active", "ProbeID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultDiagnosticProbeAddedEvent[probe] → Association
EventClass="DiagnosticProbeAdded" の event。

### SourceVaultMakeProbeRun[probeID, result, opts]
probe の実行結果を作る。result=pass/fail/partial/inconclusive。
→ Association
Options: "RunID" -> Missing["NoRun"], "EvaluatedArtifactRef" -> Missing["NoArtifact"], "Score" -> 0.0, "ObservedAnswer" -> Missing["NoAnswer"], "FailureClass" -> Missing["NoFailure"] (missingFact/wrongLink/wrongTag/accessBlocked/insufficientRetrieval), "ErrorBookRef" -> Missing["NoError"], "ProbeRunID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultProbeRunRecordedEvent[run] → Association
EventClass="ProbeRunRecorded" の event。

### SourceVaultMakeErrorBookEntry[errorClass, symptom, opts]
失敗の永続記録を作る。Status 既定 open。
→ Association
Options: "TargetRefs" -> {}, "Diagnosis" -> Missing["NoDiagnosis"], "EvidenceRefs" -> {}, "Severity" -> "warning" (info/warning/blocking), "ProposedFix" -> Missing["NoFix"], "Status" -> "open", "OpenedByRunID" -> Missing["NoRun"], "ErrorID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultErrorBookAddedEvent[entry] → Association
EventClass="ErrorBookEntryAdded" の event。

### SourceVaultErrorBookClosedEvent[errorID, opts] → Association
EventClass="ErrorBookEntryClosed" の event (Status->fixed)。
Options: "ClosedByRunID" -> Missing["NoRun"], "ClosedAtUTC" -> Automatic

### SourceVaultErrorBookReopenedEvent[errorID, opts] → Association
EventClass="ErrorBookEntryReopened" の event (Status->open)。
Options: "Reason" -> Missing["NoReason"], "ReopenedAtUTC" -> Automatic

### SourceVaultReplayErrorBook[events] → List
Added に Closed/Reopened を時刻順適用した最終 entry list を返す純関数 (open->fixed->open)。

### SourceVaultOpenErrorBookEntries[entries] → List
Status が open/monitoring の entry を返す。

### SourceVaultErrorReopenRate[events] → Real
closed した entry のうち reopened された比率 (vitality 指標, rev3)。

### SourceVaultErrorBookBlocksAutoConfirmQ[targetRef, openEntries] → True|False
targetRef に対する blocking severity の open ErrorBook entry があれば True (§10.5: 自動確定停止)。

### SourceVaultMakePinnedFact[factKind, targetURI, fact, opts]
次回 compilation に保持させる固定 fact を作る。
→ Association
Options: "SourceEvidenceRefs" -> {}, "CreatedByProbeRunID" -> Missing["NoProbeRun"], "ConstraintStrength" -> "ShouldPreserve" (MustPreserve/ShouldPreserve/NegativeConstraint), "Status" -> "active", "ReviewState" -> "AutoGenerated", "PinnedFactID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultPinnedFactAddedEvent[fact] → Association
EventClass="PinnedFactAdded" の event。

### SourceVaultProbeRunToPinnedFact[probeRun, factKind, targetURI, fact] → Association
失敗 probe で失われた fact を PinnedFact に昇格する (§10.3-2)。ConstraintStrength=MustPreserve, ReviewState=NeedsReview, CreatedByProbeRunID=run。

## ObjectSignals / importance (§8.8.4, rev7)
ObjectInteractions が正準 (append-only)、ObjectSignals は再生成可能なローカル projection。InteractionKind 別 Weight: Open/Read 0.3, MarkRead/MarkUnread 0.1, SearchClick 0.4, Retrieve 0.2, ContextInclude/Cite/Edit/Pin 1.0, Annotate/Tag/Star 0.8, Accept 0.7, Reject/Dismiss 0.3/0.2, その他 0.5。

### SourceVaultMakeObjectInteraction[targetURI, actorKind, interactionKind, opts]
owner/LLM/workflow の操作観測を作る。actorKind=Owner/LLM/Workflow/System。
→ Association
Options: "Weight" -> Automatic (InteractionKind 別既定), "ObjectClass" -> Missing["NoClass"], "ActorID" -> Missing["NoActor"], "QueryRef" -> Missing["NoQuery"], "RunID" -> Missing["NoRun"], "ContextRef" -> Missing["NoContext"], "AccessLevel" -> 0.85, "InteractionID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultObjectInteractionRecordedEvent[interaction] → Association
EventClass="ObjectInteractionRecorded" の event。

### SourceVaultObjectImportanceSetEvent[targetURI, actorKind, importance, opts] → Association
owner/LLM の明示重要度 (0..1) を EventClass="ObjectImportanceSet" で記録。
Options: "SetAtUTC" -> Automatic

### SourceVaultReplayObjectSignals[events, targetURI]
ObjectInteraction/ImportanceSet から ObjectSignals projection を再生成する純関数。LLM 寄与は 0.7 係数で抑制。importance は AccessLevel/SafetyState/release gate を緩めない。
→ <|"OwnerRefCount", "LLMRefCount" (Weight 加重和), "OwnerImportance", "LLMImportance", "PinState", "OwnerReadState", "OwnerDismissed", "EffectiveImportance"|>

## 記憶代謝 残テーブル (§10.2.7/10.2.8/10.2.9)

### SourceVaultMakeMemoryBranch[branchKind, opts]
少数仮説/競合を早期に消さず保持する branch を作る。branchKind=MinorityHypothesis/AlternativeEntityLink/AlternativeTag/PageRevision。
→ Association
Options: "TargetRefs" -> {}, "Rationale" -> "", "Gravity" -> 0.5, "Status" -> "active", "ReviewAfterUTC" -> Missing["NoReview"], "BranchID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultMemoryBranchOpenedEvent[branch] → Association
EventClass="MemoryBranchOpened" の event。

### SourceVaultMakeAuditRecord[targetRef, opts]
確定済み link/tag/claim の一時停止検査を作る。
→ Association
Options: "AuditKind" -> "Suspension" (Suspension/Challenge/Reaffirmation/ImpactTest), "SuspendedProjectionRefs" -> {}, "ProbeRunRefs" -> {}, "Outcome" -> "needsReview" (reaffirmed/weakened/reversed/needsReview), "AuditID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultAuditRecordAddedEvent[audit] → Association
EventClass="AuditRecordAdded" の event。

### SourceVaultProbePassRate[probeRuns] → Real | Missing
probe run list の pass/total を返す (空は Missing)。

### SourceVaultMemoryVitalityScore[scopeRef, opts]
記憶の健全性指標 (rev3)。dashboard 専用・近似で検索 ranking には使わない。ProbePassRate と ErrorReopenRate は本実装で算出、他は近似 proxy を opts で与える。
→ Association
Options: "ProbeRuns" -> {}, "Events" (ErrorBook events), "CoherenceStability", "FragilityResistance", "MinorityInfluence", "MetacognitiveAssessments" (FaithfulnessScore 算出), "UncertaintyOutcomes" (Discrimination 算出)

### SourceVaultMetacognitiveFaithfulnessScore[maList] → Real | Missing
MA 群の cMFG 近似 = 1 - Mean[Abs[FaithfulnessGap]] (§8.8.5.1)。gap が Missing の MA は除外。該当無しは Missing。集計指標なので Abs を使う。

### SourceVaultUncertaintyDiscrimination[outcomes] → Real | Missing
IntrinsicUncertainty が事後正誤を弁別できたかの AUROC 近似。outcomes = {<|"IntrinsicUncertainty"->u, "Correct"->True|False|>, ...}。誤り側の不確実性が高いほど 1。正例(誤り)/負例(正答)どちらか欠けると Missing。ground truth は owner 訂正・ProbeRun・ErrorBook から供給。

## CompilationConstraint (§10.2.4)

### SourceVaultMakeCompilationConstraint[constraintKind, opts]
pinned fact/ErrorBook/policy 由来の workflow 制約を作る。constraintKind=PreserveFact/PreserveMinority/AvoidLink/AvoidTag/AccessGuard/StructuralRule。
→ Association
Options: "AppliesTo" -> "workflow", "Payload" -> <||>, "SourceRef" -> Missing["NoSource"], "Active" -> True, "ConstraintID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultCompilationConstraintAddedEvent[constraint] → Association
EventClass="CompilationConstraintAdded" の event。

### SourceVaultPinnedFactToConstraint[pinnedFact] → Association
PinnedFact を ConstraintKind=PreserveFact の CompilationConstraint に変換する (§10.4)。

## mining workflow orchestration 骨格 (§7.1 / §9.4, rev6)

### SourceVaultRunMiningPipeline[objects, opts]
mining workflow の骨格。各 object を SecurityPreScan し quarantined object は後続 extractor に渡さない (safety gate、pre-scan を最初の LLM 利用前に)。
→ <|"Processed", "Quarantined", "Extracted", "Results"|>
Options: "TextFn" -> Automatic (object->text, 既定 object["Text"]), "ExtractorFn" -> Automatic (object->結果, deterministic/LLM を注入), "AssessUncertainty" -> True (True で各 object に iSVMDefaultUncertaintyMA 相当の MetacognitiveAssessment を付与), "UncertaintyFn" -> Automatic (既定 iSVMDefaultUncertaintyMA、注入可)

### SourceVaultIterateUntilStable[fn, init, opts]
compile-refine/reasoning retrieval の反復骨格。fn[state, i] を反復し MaxIterations 到達 か NoProgressTermination (同一署名再掲) で停止。
→ <|"State", "Iterations", "Stopped"|>
Options: "MaxIterations" -> 2, "NoProgressTermination" -> True, "SignatureFn" -> Automatic (既定 Hash)

## 実 LLM extractor (§6.1 stage3, rev6 LLM judge isolation)

### SourceVaultLLMExtractAuthors[text, objectURI, opts]
LLM で著者名を抽出し AuthorshipAssertion (ExtractionSource=LLM) を返す。text を UNTRUSTED data として system prompt で隔離・data boundary で囲み tool を渡さず JSON 配列出力に限定、local model 既定。LLM 不達は Missing、JSON 失敗は {}。
→ List | Missing
Options: "LLMFn" -> Automatic (text->response, 既定 local LM Studio), "Confidence" -> 0.7, "CreatedAtUTC" -> Automatic

### SourceVaultQueryLocalLLM[prompt, timeout] → String | Missing
local LM Studio (OpenAI 互換 chat.completions, $ClaudePrivateModel) に temperature 0・tool 無しで問い合わせ応答文字列を返す。接続不可は Missing。LLMExtractAuthors の既定 LLMFn。Authorization token は $SourceVaultLocalLLMKey -> NBAccess`NBGetLocalLLMAPIKey -> "lm-studio" の順で解決。

### $SourceVaultLocalLLMKey
型: String | Automatic, 初期値: Automatic
local LLM (LM Studio) の API token override。未設定なら NBAccess`NBGetLocalLLMAPIKey、それも無ければ "lm-studio"。

## ClaudeOrchestrator workflow net 統合 (§6.3)

### SourceVaultRunIdentityTagMining[objects, opts]
mining を実行する公開 API。ClaudeOrchestrator 可用なら WorkflowNet (source->Mine[PureFunction: RunMiningPipeline]->Done) として実行 (並列/retry/approval/observability に乗る)、無ければ RunMiningPipeline 直接にフォールバック。
→ <|"Mode" -> "Orchestrator"|"Direct", ...|> (Direct は "Pipeline"、Orchestrator は "WorkflowId"/"Result")
Options: "ExtractorFn" -> Automatic (LLM/deterministic 注入), "UseOrchestrator" -> Automatic (自動判定 / True / False)

## 本番フロー結線 (§6.3 / §15.6)

### $SourceVaultMiningProductionHooksEnabled
型: Boolean, 初期値: True
mining の本番フック (メールサマリー pre-scan 等) を SourceVault ロード時に自動装着するかのトグル。False で素の mining 関数のみ (自動結線しない)。

### SourceVaultMiningSafetyEnricher[mailspec, snapshot]
mailspec の body を SecurityPreScan で検査し quarantined なら body を安全注記へ置換して LLM 要約器に汚染本文を渡さない enricher (シナリオ A)。正常時は body 不変。透明性のため _safetyState (active/quarantined) を付す (_ 接頭辞は LLM 非送信メタ)。
→ Association

### SourceVaultMiningAuthorshipFetchHook[mbox, fetchResult]
SourceVaultMailFetchNew の post-fetch フック。新着/更新があれば SourceVaultExtractAllMail (冪等) を呼び From を Sender authorship として記録する。新着が無ければ何もしない。

### SourceVaultMiningWireProductionHooks[opts]
mining を既存フローへ結線する (冪等)。(1) メール派生 (RegisterMailspecEnricher) に "security-prescan" enricher、(2) メール取り込み (RegisterPostFetchHook) に "mining-authorship" フック、(3) webingest に "mining-webingest"、security-prescan の後に "metacog" を登録。依存先 API 無しは skip。SourceVault ロード末尾で自動呼び出し。
→ <|"Status", "Wired", "Skipped"|>
Options: "Force" -> False ($SourceVaultMiningProductionHooksEnabled=False でも強制装着)

### SourceVaultMiningUnwireProductionHooks[]
WireProductionHooks が装着したフックを解除する (security-prescan enricher など)。

## MetacognitiveAssessment / faithful uncertainty (§8.8.5, arXiv:2605.01428)

### SourceVaultMakeMetacognitiveAssessment[targetRef, opts]
faithful-uncertainty 評価の record を作る。IntrinsicUncertainty/ExpressedUncertainty から IntrinsicConfidence・符号付き FaithfulnessGap・ConfidentErrorRisk=Max[0,gap]・OverHedgeRisk=Max[0,-gap] を導出。faithfulness は内部状態との一致で外部証拠の十分性ではない。取得不能な不確実性は Missing のまま、依存導出値も Missing。
→ Association
Options: "AssessmentID" -> Automatic, "MiningObjectID" -> Automatic, "AssessmentScope" -> "Answer", "IntrinsicUncertainty" -> Missing["NoIntrinsic"], "ExpressedUncertainty" -> Missing["NoExpressed"], "EvidenceSufficiency" -> Missing["NoEvidence"], "UncertaintyKind" -> {} ({Aleatoric|Epistemic|Normative}), "RecommendedAction" -> Automatic (導出), "SearchTriggered" -> Automatic, "ConflictWithRetrievedEvidence" -> False, "LinguisticMarker" -> Missing["NoMarker"], "ProbeRefs" -> {}, "ErrorBookRefs" -> {}, "RunID" -> Missing["NoRun"], "CreatedAtUTC" -> Automatic, "AccessLevel" -> 0.85

### SourceVaultMetacognitiveAssessmentToMiningObject[a] → Association
MetacognitiveAssessment を正準 MiningObject (MiningObjectType -> "MetacognitiveAssessment") に写す。正準は MiningObject、本 record はその projection。

### SourceVaultMiningObjectAddedEvent[obj] → Association
MiningObject を EventClass="MiningObjectAdded" event に包む (正準 fact)。

### SourceVaultMetacognitiveAssessmentEvent[a] → Association
EventClass="MetacognitiveAssessmentAdded" の wrapper event。同一 MiningObjectID を保持し replay では MiningObjectAdded と重複登録しない。

### SourceVaultReplayMetacognitiveAssessments[events] → List
MiningObjectAdded[MetacognitiveAssessment] と MetacognitiveAssessmentAdded を replay し MiningObjectID で dedup した assessment list を返す純関数。

### SourceVaultMetacognitiveBlocksAutoConfirmQ[a, opts]
不変条件判定: EvidenceSufficiency が低い、ConfidentErrorRisk が高い、または ConflictWithRetrievedEvidence のとき True (自動確定を止める)。
→ True|False
Options: "EvidenceSufficiencyMin" -> 0.6, "ConfidentErrorRiskMax" -> 0.5

### SourceVaultAddMetacognitiveAssessment[a, opts]
assessment を append-only event として保存する wrapper (I/O)。AppendEvent が無ければ event を返す。
→ 結果 Association | event
Options: "EmitMiningObjectEvent" -> True (正準 MiningObjectAdded を emit)

### SourceVaultMailMetacognitiveAssessment[signals, opts]
メール派生(要約)前に使う MA ビルダ (Appendix A.1)。signals=<|SafetyState, SenderAuthenticated, DeliveryAnomalyScore, HasAttachments, AttachmentsRead, TargetRef|> から EvidenceSufficiency と ConflictWithRetrievedEvidence・RecommendedAction を導出。IntrinsicUncertainty は LLM 前には取れず Missing。
→ Association
Options: "TargetRef" -> "sv://mail/unknown"

### SourceVaultMiningMetacognitiveEnricher[mailspec, snapshot]
MailMetacognitiveAssessment を用いて mailspec に _metacogAction / _metacogEvidenceSufficiency / _metacogConflict / _metacogState を付す enricher。WireProductionHooks が security-prescan の後に "metacog" として登録。
→ Association

## MailHeaders / MailDeliveryObservations (§8.1.1)

### SourceVaultParseMailHeaders[rawHeader, opts]
raw RFC5322 header を構造化する。折返し行を unfold。認証解析は SourceVaultParseAuthenticationResults があれば流用、無ければ regex。
→ <|"HeaderFieldsOrdered" (重複・順序保持), "ParsedHeaders", "ReceivedChain" (上から), "AuthenticationResults", "DKIMSignatures", "SPFResult", "DKIMResult", "DMARCResult", "ARCResult", "OriginatingIPRefs", "RawHeaderHash", "ReceivedHopCount"|>
Options: "HeaderAccessLevel" -> 0.85

### SourceVaultMailDeliveryObservation[mailHeaders, opts]
MailHeaders から配送経路 feature を作る。
→ <|"ReceivedHopCount", "OriginatingIPRefs", "RelayCountries", "RelayASNs", "RelayOrgs", "SPFResult", "DKIMResult", "DMARCResult"|>
Options: "GeoFn" -> Automatic (ip->Assoc[Country/ASN/Org]、既定 geo 無), "SourceID" -> Missing["NoSource"], "ObservationID" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultMailDeliveryAnomalyScore[observation, baseline, opts]
通常配送 profile からの外れを採点する。baseline=<|Countries, ASNs, Orgs|> (private profile、AccessLevel 1.0 で別管理)。baseline 空なら country/ASN は flag しない (auth failure のみ)。spoofing と断定せず benign 仮説も保持し MA へ conflict として渡す。
→ <|"DeliveryAnomalyScore", "DeliveryAnomalyKinds" (UnexpectedCountry/UnexpectedASN/AuthFailure), "BenignExceptionHypotheses" (Travel/VPN/転送/ML relay), "RecommendedAction"|>
Options: "BenignExceptionHypotheses" -> Automatic (既定の仮説導出を上書き)

### SourceVaultMailHeadersCapturedEvent[mh] → Association
EventClass="MailHeadersCaptured" の event。

### SourceVaultMailDeliveryObservationAddedEvent[obs] → Association
EventClass="MailDeliveryObservationAdded" の event。

### SourceVaultMailDeliveryAnomalyDetectedEvent[obs, anomaly] → Association
EventClass="MailDeliveryAnomalyDetected" の event。

### SourceVaultMiningMailHeaderObservation[rawHeader, opts]
raw RFC5322 header を parse→DeliveryObservation→anomaly し純関数で返す。SnapshotFeatures は raw header を載せず coarse な feature のみ (privacy 保全、raw header は MailHeadersCaptured event 側)。DeliveryAnomalyScore は metacog enricher の conflict 入力。
→ <|"MailHeaders", "Observation", "Anomaly", "SnapshotFeatures" (RawHeaderHash/SPF・DKIM・DMARC/DeliveryAnomalyScore/Kinds), "Events"|>
Options: "Baseline" -> Automatic (private profile <|Countries,ASNs|>), "GeoFn" -> Automatic (ip->geo), "BaselineFn" -> Automatic, "SourceID" -> Missing["NoSource"], "HeaderAccessLevel" -> 0.85。GeoFn/Baseline/BaselineFn 省略 (Automatic) で $SourceVaultMailGeoFn / $SourceVaultMailDeliveryBaselineFn と送信者ドメインの登録 baseline から自動解決

### $SourceVaultMailGeoFn
型: Function | Automatic, 初期値: Automatic (geo 無し)
IP文字列→<|Country,ASN,Org|> を返す関数。設定すると mail 配送 anomaly が国/ASN ベースで効く。GeoIP データ源はユーザー注入。

### $SourceVaultMailDeliveryBaselineFn
型: Function | Automatic, 初期値: Automatic (ドメイン登録 baseline を引く)
<|FromDomain,From|>→baseline <|Countries,ASNs|> を返す関数。

### SourceVaultMailDeliveryBaseline[domain] → Association
登録済み配送 baseline を返す (無ければ <||>)。

### SourceVaultSetMailDeliveryBaseline[domain, <|Countries,ASNs|>]
送信者ドメインの通常配送 baseline を登録する (private operational profile, AccessLevel 1.0 相当・local 限定)。

### SourceVaultSaveMailDeliveryBaselines[opts]
baseline を $UserBaseDirectory/SourceVault/private (Dropbox 非同期=local 限定) に保存。鍵初期化済 (SourceVaultInitializeEncryption) なら SourceVaultSealPayload で encrypt-then-MAC 暗号化 at-rest、未初期化なら平文 fallback (警告付)。
Options: "Path" -> Automatic (テスト用)

### SourceVaultLoadMailDeliveryBaselines[opts]
保存済み baseline を読み込む (暗号化 record は SourceVaultUnsealPayload で復号、平文はそのまま)。
Options: "Path" -> Automatic

### SourceVaultMailGeoLookup[ip] → <|Country,ASN,Org|> | Missing
IP→geo を ip-api.com で照会 (無料/キー不要)。内部/予約 IP は問い合わせず Missing、結果は $SourceVaultMailGeoCache にキャッシュ。privacy: public relay IP を外部送信するため $SourceVaultMailGeoFn = SourceVaultMailGeoLookup と明示設定したときだけ有効化 (opt-in)。
Options: "Endpoint" -> "http://ip-api.com/json/", "UseCache" -> True

### SourceVaultSaveMailGeoCache[]
GeoIP キャッシュを local (Dropbox 非同期) に保存する。

### SourceVaultLoadMailGeoCache[]
GeoIP キャッシュを読み込む。

### SourceVaultLearnMailDeliveryBaselines[opts]
取り込み済みメール snapshot の MailDelivery (RelayCountries/RelayASNs) を送信者ドメインごとに集約して配送 baseline を学習・登録する (GeoFn を設定して取り込んだメールが対象)。
→ <|"Learned", "Domains", "Baselines"|>
Options: "Snapshots" -> Automatic (MailSnapshotList), "MinObservations" -> 1, "Apply" -> True (即 SetMailDeliveryBaseline)

## web 著者抽出 + TopicTag 自動マイニング (§4.1, §11.6)

### SourceVaultExtractWebMetadata[html, opts]
raw HTML から著者・タイトル・キーワード metadata を best-effort 抽出 (meta name=author/citation_author/dc.creator、article:author、JSON-LD author.name、arXiv Atom <author><name>、keywords、title/og:title)。HTML 解析は regex の best-effort。opts は現状未使用 (拡張余地)。
→ <|"Title", "Authors" (list), "Keywords" (list), "Source"|>

### SourceVaultWebMetadataToAuthorship[meta, objectURI, opts]
web metadata の著者を AuthorshipAssertion (Role Author) に投影。web/PDF metadata の著者は偽装可能なので MetadataTrustClass="UnverifiedMetadata"・Confidence 控えめ (既定 0.6、mail<web)、確定 EntityRef は入れない (候補段階)。
→ List
Options: "ObjectClass" -> "web", "ExtractionSource" -> "WebMetadata", "SourceField" -> "meta:author", "Confidence" -> 0.6, "MetadataTrustClass" -> "UnverifiedMetadata", "CreatedAtUTC" -> Automatic

### SourceVaultWebTopicTags[meta, objectURI, opts]
web metadata の keywords (または opts "TagFn") から TopicTag を自動マイニング。SourceKind="Mining"・ReviewState=NeedsHumanReview・Confidence 控えめ (既定 0.5)。
→ List
Options: "TagFn" -> Automatic, "Confidence" -> 0.5, "CreatedAtUTC" -> Automatic, "SourceRef" -> Missing["NoSourceRef"]

### SourceVaultWebDocumentToAssertions[doc, objectURI, opts] → <|"TagAssertions", "AuthorshipAssertions", "Metadata"|>
web document ("HTML" or "Metadata") を投影する純関数 (Eagle 版と対称)。
Options: "CreatedAtUTC" -> Automatic, "AuthorConfidence" -> 0.6, "TagConfidence" -> 0.5, "ExtractionSource" -> "WebMetadata", "MetadataTrustClass" -> "UnverifiedMetadata", "TagFn" -> Automatic

### SourceVaultExtractFromWebDocument[doc, objectURI, opts]
web document を投影し SourceVaultCommitAssertions で実 vault に commit する (I/O)。opts は SourceVaultWebDocumentToAssertions と同じ。

### SourceVaultMiningWebIngestAssertions[fetchResult, opts]
SourceVaultWebFetch の結果から raw HTML を読み (RawBlobRef→blob、または fetchResult["RawHTML"] 注入)、著者/TopicTag を投影する純関数。objectURI 規約 = sv://web/<ContentHash>。HTML 取得不可は Status="NoHTML"。
→ <|"TagAssertions", "AuthorshipAssertions", "ObjectURI", "Status"|>
Options: "AuthorConfidence" -> 0.6, "TagConfidence" -> 0.5, "TagFn" -> Automatic, "CreatedAtUTC" -> Automatic

### SourceVaultMiningWebIngestExtract[fetchResult, opts]
MiningWebIngestAssertions の投影を実 vault に commit する (I/O)。webingest は post-fetch hook を持たないため現状 opt-in (明示呼び出し)。
→ <|"Committed", "AlreadyPresent", "Failed", "ObjectURI"|>
Options: MiningWebIngestAssertions と同じ ("AuthorConfidence", "TagConfidence", "TagFn", "CreatedAtUTC") + "SkipExisting" -> True (既存 authorship/tag を replay 照合し冪等化)

### SourceVaultMiningWebIngestHook[ctx]
SourceVaultRegisterWebIngestHook 用フック。ctx["Result"] (WebFetch 結果) から著者/タグを冪等抽出・commit。WireProductionHooks が "mining-webingest" として登録 (取り込み後 auto 抽出)。

## 記憶代謝の実 LLM 連携 (§10.4.3, arXiv:2605.01428)

### SourceVaultAssessUncertainty[question, opts]
LLM の self-consistency (繰り返し sampling での矛盾率) で IntrinsicUncertainty を測り MetacognitiveAssessment を生成する。Samples 回 sampling (Temperature>0)→正規化→modal 一致率=Consistency、IntrinsicUncertainty=1-Consistency。LLM 不達は Status LLMUnavailable。
→ <|"Status", "Answer" (modal), "IntrinsicUncertainty", "Consistency", "Samples", "Assessment" (MA)|>
Options: "LLMFn" -> Automatic (テスト mock), "Samples" -> 3, "Temperature" -> 0.7, "Timeout" -> 60, "Evidence" -> Missing["NoEvidence"], "EvidenceSufficiency" -> Automatic, "ExpressedUncertainty" -> Automatic, "TargetRef" -> "answer", "AssessmentScope" -> "Answer", "AnswerNormalizeFn" -> Automatic

### SourceVaultCheckRetrievalSufficiency[assessResult, opts]
assessUncertainty 結果が十分か (IntrinsicUncertainty<=IntrinsicUncertaintyMax) を判定する。
→ True|False
Options: "IntrinsicUncertaintyMax" -> 0.4

### SourceVaultReasoningRetrieve[query, opts]
agent-native retrieval: assessUncertainty→(低確信なら)search→evidence 蓄積→再 assess を IterateUntilStable で回す。確信で停止し回答、検索しても確信できない/SearchFn 無しは insufficient で ErrorBookEntry を作る。ClaudeOrchestrator 可用時は Step→[Continue(loopback) | Finish | Fail | ForceStop] の WorkflowNet、無ければ直接ループ (Mode=Direct)。1 反復ロジックは純関数 iSVMReasoningStepCore を両経路で共有。
→ <|"Mode", "Answer", "Sufficient", "Assessment", "Evidence", "Trace", "Iterations", "ErrorBookEntry"|> (Orchestrator 時は WorkflowId/RunStatus も)
Options: "LLMFn" -> Automatic, "SearchFn" -> Automatic (query→結果 list), "MaxIterations" -> 4, "Samples" -> 3, "Temperature" -> 0.7, "IntrinsicUncertaintyMax" -> 0.4, "TargetRef" -> "query", "UseOrchestrator" -> Automatic

### SourceVaultRunWikiCompileRefine[source, opts]
WiCER 型 compile→evaluate→diagnose→refine を IterateUntilStable で回す (§10.4.1)。各反復: CompileFn[source, mustFacts] で wiki artifact 生成→各 DiagnosticProbe を EvaluateFn で評価 (ProbeRun)→失敗 (missingFact) は PinnedFact→CompilationConstraint に昇格し次回 compile の must-facts に→全 pass か MaxIterations/no-progress で停止。残った失敗は ErrorBook(Compilation) へ。CompileFn 既定=QueryLocalLLM (compile 用 system prompt)、EvaluateFn 既定=FactPresence は artifact 包含・QA は LLM 回答包含。ClaudeOrchestrator 可用時は compile→[Accept | Refine(loopback) | GiveUp] の WorkflowNet、無ければ直接ループ。
→ <|"Mode", "Artifact", "ProbeRuns", "PinnedFacts", "Constraints", "ProbePassRate", "AllPass", "Iterations", "ErrorBookEntries"|> (Orchestrator 時は WorkflowId/RunStatus も)
Options: "Probes" -> {}, "CompileFn" -> Automatic, "EvaluateFn" -> Automatic, "LLMFn" -> Automatic, "MaxIterations" -> 2, "TargetURI" -> "wiki", "RunID" -> Automatic, "UseOrchestrator" -> Automatic

## 非同期ジョブ API (長時間ジョブの Orchestrator 化)

### SourceVaultSubmitReasoningRetrieve[query, opts]
reasoning retrieval を ClaudeOrchestrator に非同期投入し即座に返す (FE 非ブロック)。共有 ScheduledTask が背後で 1 step ずつ駆動。要 ClaudeOrchestrator。
→ <|"WorkflowId", "Kind", "Mode", "Status"|>
Options: ReasoningRetrieve と同じ + "MaxWaitSeconds" -> 3600, "AsyncLLM" -> False (True で assess の k sampling を URLSubmit で非同期化、HTTP 飛行中はカーネルを空ける), "SubmitFn" -> Automatic (submit 関数注入、テスト), "Persist" -> False

### SourceVaultSubmitWikiCompileRefine[source, opts]
WiCER compile-refine を ClaudeOrchestrator に非同期投入し即座に返す。要 ClaudeOrchestrator。
→ <|"WorkflowId", "Kind", "Mode", "Status"|>
Options: RunWikiCompileRefine と同じ (含む "RunID" -> Automatic) + "MaxWaitSeconds" -> 3600, "AsyncLLM" -> False (True で compile を URLSubmit で非同期化), "SubmitFn" -> Automatic, "Temperature" -> 0, "Persist" -> False

### SourceVaultJobStatus[wid]
非同期ジョブの進捗を返す。
→ <|"Kind", "Status" (Running/Completed), "WorkflowStatus", "Done", "Steps", "TerminationReason"|>

### SourceVaultJobResult[wid]
完了済みなら同期版と同形の結果、未完了なら <|Status->Running, Steps|> を返す (Kind で抽出を振り分け)。

### SourceVaultAwaitJob[wid, opts]
ClaudeWaitWorkflow で完了まで待ち (進捗ポーリング) SourceVaultJobResult を返す。
→ Association
Options: "MaxWait" -> Quantity[3600, "Seconds"]

### SourceVaultListMiningJobs[] → List
投入済み非同期ジョブの一覧 {<|WorkflowId, Kind, Status, SubmittedAt|>...} を返す。

### SourceVaultCancelJob[wid]
非同期ジョブを Cancel し registry/polling tick をクリーンアップする。

### $SourceVaultMiningJobDir
型: String | Automatic, 初期値: Automatic (= <CoreRoot>/mining-jobs)
永続化ジョブ snapshot の保存先。

### SourceVaultPersistJob[wid]
非同期ジョブ (workflow marking + mining context) を snapshot にディスク永続化し、カーネル再起動後に RestoreJobs で復元可能にする。完了済みジョブは restore 後に結果を抽出できる (抽出は marking 由来で closure 非依存)。

### SourceVaultRestoreJobs[opts]
永続化された全ジョブを現カーネルへ復元する (workflow を新 WorkflowId で再構築し mining registry に再登録)。以後 JobStatus/JobResult は復元ジョブでも marking から完了判定・抽出する。
→ {<|"OriginalWid", "WorkflowId" (新), "Kind", "Done"|>...}
Options: "SnapshotDir" -> Automatic (既定 $SourceVaultMiningJobDir)

### SourceVaultListPersistedJobs[] → List
永続化済みジョブ snapshot の一覧 {<|OriginalWid, Kind, SnapshotDir, PersistedAt|>...} を返す。