# SourceVault_searchview API リファレンス

## 概要
§6.8 Live hypertext interaction / annotation graph を実装するパッケージ (検索基盤 spec v1, Phase 5-10)。gated 検索結果を「たどれる作業面 (live view)」として返し、閲覧/追記行為を interaction meta-layer として蓄積する。base topic graph の上に actor/annotation の meta graph を構築する。§6.4 retrieval episode graph、§6.6 SearchContextProfile、§7 AgenticKeywordSearch/Cascade も含む。

依存: [SourceVault_searchindex](https://github.com/transreal/SourceVault_searchindex) (SourceVaultSearch/SourceVaultNormalizeSearchText)、[SourceVault_oopsseed](https://github.com/transreal/SourceVault_oopsseed) (ExpandSearchGraph)、[SourceVault_core](https://github.com/transreal/SourceVault_core) (AppendEvent/TransactionLog)。context は全て `SourceVault``。

不変条件 (安全設計・変更禁止):
- release gate / request-time gate は緩めない。未許可 node は low-leak placeholder として扱う。
- raw local path は cell/tooltip/trace/projection に出さない。
- meta-layer boost / influence boost / context profile は ranking のみ変更し release gate を緩めない。行動ログ (interaction/episode) は高機密扱い。
- actor weighting は Owner > Tool > LLM。LLM actor は influence 上限 0.7 (自己強化抑制)。

## §3.4/§6.8 SearchView 構築・描画

### SourceVaultBuildSearchView[query, opts]
gated 検索を走らせ SourceVaultSearchView object を作り cache する。SourceVaultSearch を Permit のみ・非 revoked で二重防御フィルタ。RankedList は常に付く。ContextSubgraph/GraphPlot 系は TopicGraph 相当 (ContextSubgraphRoot が topic ref かつ RelationGraph 指定) 時に SourceVaultExpandSearchGraph で KG 展開して付く。
→ Association <|ObjectClass, ViewRef, ViewKind, SearchSessionRef, RootQueryRef, Query, RootNodeRefs, NodeRefs, EdgeRefs, Ordering, GraphLayout, LazyLoadPolicy, ReleaseContextRef, BuiltAtUTC, Results, Subgraph|>。ReleaseContext 非文字列なら Failure["ReleaseContextRequired"]。SourceVaultSearch が Failure ならそれを返す。
Options:
- "ReleaseContext" -> None (必須・String)
- "Index" -> None
- "Limit" -> 10
- "ResultView" -> "RankedList" ("RankedList"|"ContextSubgraphNotebook"|"GraphPlot"|"OrderedTree"|"All")
- "TopicGraph" -> None
- "RelationGraph" -> None (subgraph 展開に必要な Association)
- "RefLabel" -> None
- "ContextSubgraphRoot" -> Automatic (topic ref の String 時のみ展開)
- "ContextSubgraphDepth" -> 1 (MaxHops)
- "SearchSessionRef" -> Automatic (Automatic 時 svsession id 生成)

### SourceVaultRenderSearchNotebookView[viewRef, opts]
cache 済 view を notebook cell 構造 (Framed/Column/Style の Grid) に整形する。実描画は FE 側。未許可 node は BuildSearchView で除外済。link は raw path を出さず node id (ChunkId) のみ表示。
→ Association <|ViewRef, ViewKind, Query, RowCount, Notebook|>。viewRef 未登録なら Missing["ViewNotFound"]。
Options:
- "MaxRows" -> 20
- "Interactivity" -> "Live" ("Live"|"Static")

### SourceVaultFollowSearchViewLink[viewRef, linkRef, opts]
view 内 link をたどる (gated fetch)。linkRef が svtopic: 始まりなら Topic として RelationGraph で 1-hop 近傍展開、sv:// / svmailpara: 始まりなら Content として re-gate (raw path 非開示の note のみ返す)、その他は Node。必ず FollowedLink interaction event を記録する。
→ Association <|Kind, Ref, (Neighbors|Note)|>。viewRef 未登録なら Missing["ViewNotFound"]。
Options:
- "RelationGraph" -> None
- "RefLabel" -> None
- "Actor" -> <|"Kind" -> "Owner", "Ref" -> "sventity:owner:imai"|>
- "MaxNeighbors" -> 8
- "Persist" -> True

### SourceVaultRecordTopicItemInteraction[event, opts]
interaction event を検証し append-only event log に記録する。行動ログ=高機密。ActionKind は Viewed/FollowedLink/ExpandedNode/Cited/Copied/Annotated/Rejected のいずれか (それ以外は Failure["BadActionKind"])。event の欠損キーは既定補完 (EventId 自動生成、Actor.Kind 既定 "Tool")。
→ Association (EventId 付き正規化 event、ObjectClass "SourceVaultTopicItemInteractionEvent")。
Options:
- "Persist" -> True (True 時 EventClass "TopicItemInteraction" で AppendEvent)

### SourceVaultAppendGraphAnnotation[targetRef, body, opts]
node/view への追記を SourceVaultGraphAnnotation として非破壊に別 object 化し (BranchRef で調査ブランチ分岐)、event log に記録する。既存 object は改変しない。
→ Association <|ObjectClass, AnnotationRef, TargetNodeRef, BranchRef, Body, AuthorRef, CreatedAtUTC, Provenance, ReviewState, Tags|>。
Options:
- "Author" -> "sventity:owner:imai"
- "BranchRef" -> Automatic (Automatic 時 svbranch id 生成)
- "ReviewState" -> "Draft"
- "Tags" -> {}
- "ViewRef" -> Missing[]
- "SearchSessionRef" -> Missing[]
- "Persist" -> True (True 時 EventClass "GraphAnnotation" で AppendEvent)

### SourceVaultBuildInteractionMetaGraph[opts]
記録した interaction/annotation event から meta-layer graph を作る。edge = interaction (actor -> ToNodeRef、Kind=ActionKind) + annotation (author -> target、Kind="Annotated"、weight 0.8)。weight は actor weight × action weight ÷ max(1, sqrt(actor 頻度)) で frequency 正規化 (同一 actor の反復行動を抑制)。boost は release gate を緩めない。action weight: Cited 1.0/Annotated 0.8/Copied 0.7/FollowedLink 0.4/ExpandedNode 0.4/Viewed 0.2/Rejected -0.4。
→ Association <|ObjectClass, NodeCount, EdgeCount, Nodes, Edges, InteractionEventCount, AnnotationCount, Note|>。
Options:
- "Events" -> Automatic (Automatic 時 SourceVaultTransactionLog)
- "Limit" -> 2000
- "ActorWeights" -> Automatic (Automatic 時 <|"Owner"->1.0, "Tool"->0.5, "LLM"->0.3|>)

## §6.4 Retrieval episode graph
検索を伴う 1 作業セッションを episode として記録し、探索グラフ・influence・episode memory を提供する。

### SourceVaultStartRetrievalEpisode[spec] → Association
検索を伴う 1 作業セッションを episode として開始し in-memory active cache に登録する。spec: <|SessionId, Actor, TaskRef, Inputs|>。戻り値 ObjectClass "SourceVaultRetrievalEpisode" (EpisodeId 付き、SearchAttempts/Outputs 空、Outcome "None")。

### SourceVaultRecordSearchAttempt[episodeId, attempt] → Association
open episode に検索試行を追記する。attempt: <|AttemptId, ParentAttemptId, QueryObjectRef, QueryText, QueryModality, SearchMethod, ResultRefs, ClickedOrReadRefs, IncludedEvidenceRefs, RejectedRefs, StartedAtUTC, EndedAtUTC, TraceRef|> (欠損は既定補完)。open episode でないなら Failure["EpisodeNotOpen"]。

### SourceVaultCloseRetrievalEpisode[episodeId, outputs, opts]
episode を outputs/outcome で確定し event log に記録、active cache から除去する。高機密行動ログとして PrivacyLevel 1.0, Tags {PrivateBehaviorLog, NoCloudLLM} で記録。
→ 確定済 episode Association。open でないなら Failure["EpisodeNotOpen"]。
Options:
- "Outcome" -> "Succeeded" ("Succeeded"|"Partial"|"None")
- "Persist" -> True (True 時 EventClass "RetrievalEpisode" で AppendEvent)

### SourceVaultBuildRetrievalEpisodeGraph[opts]
記録した episode から探索グラフ (query -> result "Retrieved"、result -> output "Influenced" (weight=influence)、attempt refinement chain "RefinedTo") を作る。
→ Association <|ObjectClass, EpisodeCount, NodeCount, EdgeCount, Nodes, Edges, Note|>。
Options:
- "Episodes" -> Automatic (Automatic 時 TransactionLog から RetrievalEpisode 抽出)
- "Limit" -> 1000

### SourceVaultEpisodeInfluenceScores[episodeId, opts]
episode の各 result の output への influence を推定する。structural スコア: evidence inclusion=1.0 / read-click=0.3 / merely retrieved=0.05、rejected -0.4、ignored-after-read -0.1、actor factor (Owner 1.0/Tool 0.5/LLM 0.7 上限)、time decay Exp[-age/HalfLife]、自己引用 sublinear (÷sqrt(引用回数))。
→ result ref -> score の Association (降順)。episode 未発見なら Failure["EpisodeNotFound"]。
Options:
- "Episode" -> Automatic (Automatic 時 active cache 参照。閉じた episode は明示注入)
- "HalfLifeDays" -> 180

### SourceVaultSearchEpisodeMemory[query, opts]
過去 episode を primer として引き、query 拡張候補 (term/object ref) を返す。overlap = Jaccard(query terms, episode query terms)。low-leak projection のみ (raw local path 非開示)。
→ Association <|CandidateTerms, CandidateObjectRefs, MatchedEpisodes, Matches, Note|>。query terms 空なら空候補。
Options:
- "Episodes" -> Automatic (Automatic 時 TransactionLog から RetrievalEpisode 抽出)
- "Limit" -> 5 (matched episode 上限)
- "MinOverlap" -> 0.2

## §6.6 SearchContextProfile
query intent を rule (LLM-free) で推定し、metadata weight/temporal field で results を再ランクする (ranking のみ・release gate は変えない)。既定 7 intent: FindEvent, FindRecentWork, FindIngest, FindNegotiationOutcome, FindOriginalArtifact, RecallPersonalMemory, FindCreation。

### SourceVaultRegisterSearchContextProfile[id, spec] → Association
search context profile を登録する。spec: <|Intent, PrimaryTemporalFields, SecondaryTemporalFields, MetadataWeights, TemporalInterpretation|> (欠損は既定補完)。既定 7 intent は初回 select/apply 時に "svsearchctx:default:<intent>" として自動登録 (冪等)。戻り値 ObjectClass "SourceVaultSearchContextProfile"。

### SourceVaultSelectSearchContextProfile[query, opts]
query intent を rule (キーワード一致数) で推定し profile を選ぶ。既定 profile を確保してから判定。
→ profile Association。該当なければ最初の登録 profile または Missing["NoProfile"]。
Options:
- "Intent" -> Automatic (String で既知 intent ならユーザー指定=最優先)
- "Default" -> "FindRecentWork" (キーワード一致 0 時の既定 intent)

### SourceVaultApplySearchContextProfile[results, profile, opts]
profile の MetadataWeights/primary・secondary temporal field で results を再ランクする。各 result の metadata (Citation.Title/Author/Sender/TopicRefs ∪ result["Metadata"]) の field 有無を重み付けし [0,1] 正規化した contribution を得る。ContextScore = BaseScore × (1 + BoostWeight × contribution)。release gate は変えない (results は既に gated)。
→ ContextScore 降順の result リスト (各 result に BaseScore/ContextScore/ContextProfile/ContextContribution を付加)。
Options:
- "BoostWeight" -> 0.5

### SourceVaultExplainSearchContext[result, profile] → Association
1 result の metadata contribution 内訳を返す (score breakdown 明示用)。→ <|ProfileId, Intent, Contribution, MetadataContribution (正の field 部分のみ), PrimaryTemporalHit, SecondaryTemporalHit, Note|>。

## §7 AgenticKeywordSearch / Cascade
query complexity で dispatch する agentic 検索ループ。既定は deterministic planner (LLM-free)。

### SourceVaultClassifyQueryComplexity[query, opts]
query を rule ベースで Simple|Complex 分類する。signal: multi-hop キーワード ("比較"/"関係"/"なぜ"/"経緯"/"根拠"/"why"/"compare"… に一致) → "MultiHopKeyword"、term 数 ≥ LongQueryTerms → "LongQuery"、(ReleaseContext と Index 両指定時) BM25 top score < LowScoreThreshold → "LowBM25(...)"。signal が 1 つでもあれば Complex。
→ Association <|Query, Complexity, Signals|>。
Options:
- "ReleaseContext" -> None
- "Index" -> None
- "LongQueryTerms" -> 6
- "LowScoreThreshold" -> 3.0

### SourceVaultAgenticSearch[query, opts]
§7 の agentic keyword search ループ。手順: complexity 分類 → context profile 選択 → episode memory recall → episode 開始 → (search → gate フィルタ → context profile 適用 → evidence 蓄積 → 充足判定 → 不足なら deterministic follow-up query 生成 → 停止条件) を反復 → episode close → SearchView 構築。follow-up は top evidence title terms + episode memory terms + relation 1-hop neighbor label から既出語除外で最大 2 語。
→ Association <|Results, Views, AnswerDraft, Complexity, Trace, Stopped|>。Stopped は EnoughEvidence|MaxIterations|NoProgress|BudgetExceeded。ReleaseContext 非文字列なら Failure["ReleaseContextRequired"]。
例: SourceVaultAgenticSearch["交渉の経緯", "ReleaseContext" -> ctx, "Index" -> idx, "RelationGraph" -> rg]
Options:
- "ReleaseContext" -> None (必須・String)
- "Index" -> None
- "PrimerIndex" -> Automatic
- "Limit" -> 10
- "MaxIterations" -> 3
- "MaxToolCalls" -> 12
- "MinGroundedEvidence" -> 2 (充足判定閾値)
- "NoProgressTermination" -> True
- "AllowLLMPlanning" -> False (True かつ PlannerFn 指定時のみ LLM planner 使用)
- "PlannerFn" -> Automatic (<|Query, Evidence, Tried|> -> follow-up terms リスト)
- "ReadBody" -> False
- "Grant" -> None
- "ResultView" -> "RankedList"
- "ContextSubgraphDepth" -> 1
- "RelationGraph" -> None
- "RefLabel" -> None
- "RecordEpisode" -> True (retrieval episode を記録)
- "ReturnTrace" -> True
- "EvidenceScoreMin" -> 0.0 (evidence 採用 score floor)
- "Actor" -> <|"Kind" -> "Owner", "Ref" -> "sventity:owner:imai"|>

### SourceVaultCascadeSearch[query, opts]
complexity で dispatch する。Complex → SourceVaultAgenticSearch (agentic loop)、Simple → SourceVaultSearch (BM25 直接、loop なし)。opts は SourceVaultAgenticSearch と同一で両者に透過。
→ AgenticSearch 形の Association <|Results, Views, AnswerDraft, Complexity, Trace, Stopped|>。Simple 時 Stopped は hits ≥ MinGroundedEvidence なら EnoughEvidence、そうでなければ None。