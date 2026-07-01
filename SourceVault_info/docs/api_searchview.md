# SourceVault_searchview API リファレンス

パッケージ: `SourceVault`
依存: `SourceVault_searchindex`（`SourceVaultSearch`）, `SourceVault_oopsseed`（`SourceVaultExpandSearchGraph`）, `SourceVault_core`（`SourceVaultAppendEvent`/`SourceVaultTransactionLog`）
ロード順: … → searchindex → oopsseed → mailstructure → **searchview** → …
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_searchview.wl"]]`
担当: 検索基盤 spec v1 **§6.8 / Phase 7.5 Live hypertext interaction / annotation graph**。検索結果を「たどれる作業面（live view）」として返し、閲覧/追記行為を interaction meta-layer として蓄積する。base topic graph の上に actor/annotation の meta graph を作る。

## 不変条件

- **release gate / request-time gate は緩めない**。未許可 node は low-leak placeholder（`BuildSearchView` は `SourceVaultSearch` の gate を通し、view 側でも Permit・非 revoked のみを保持＝二重防御）。
- raw local path は cell / tooltip / trace に出さない。
- **meta-layer boost は release gate を緩めず、行動ログとして高機密に扱う**。LLM actor の signal は owner より低く抑える。

## API

### SourceVaultBuildSearchView[query, opts] → SourceVaultSearchView（§3.4/§6.8）
gated 検索を走らせ live view object を作り cache する。`RankedList` は常に、`ContextSubgraphNotebook`/`GraphPlot`/`OrderedTree` は `TopicGraph`＋`ContextSubgraphRoot`（topic ref）＋`RelationGraph` 指定時に `SourceVaultExpandSearchGraph`（KG §6.3）で subgraph を付ける。
戻り値: `<|ObjectClass, ViewRef(svview:…), ViewKind, SearchSessionRef, RootQueryRef, Query, RootNodeRefs, NodeRefs, EdgeRefs, Ordering, GraphLayout, LazyLoadPolicy, ReleaseContextRef, BuiltAtUTC, Results, Subgraph|>`。
Options: `"ReleaseContext"`（必須）, `"Index"`, `"Limit"`(10), `"ResultView"`(RankedList|ContextSubgraphNotebook|GraphPlot|OrderedTree|All), `"TopicGraph"`, `"RelationGraph"`, `"RefLabel"`, `"ContextSubgraphRoot"`, `"ContextSubgraphDepth"`(1), `"SearchSessionRef"`。

### SourceVaultRenderSearchNotebookView[viewRef, opts] → Association
cache した view を notebook cell 構造（`Column` の `Framed` ランキング＋score/snippet/node ref）に整形。未許可 node は除外済、raw path 非開示。**実描画は FE**。戻り値 `<|ViewRef, ViewKind, Query, RowCount, Notebook(Column 式)|>`。Options: `"MaxRows"`(20), `"Interactivity"`(Live|Static)。

### SourceVaultFollowSearchViewLink[viewRef, linkRef, opts] → Association
view 内 link をたどる（gated fetch）。topic ref は `RelationGraph` で 1-hop 近傍展開（metadata。content の gate は取得時）、content ref（`sv://…`/`svmailpara:…`）は low-leak placeholder（本文は検索経由で gate 越しに取得）。`FollowedLink` interaction event を記録する。Options: `"RelationGraph"`, `"RefLabel"`, `"Actor"`, `"MaxNeighbors"`(8), `"Persist"`(True)。

### SourceVaultRecordTopicItemInteraction[event, opts] → event
interaction event（`Viewed`/`FollowedLink`/`ExpandedNode`/`Cited`/`Copied`/`Annotated`/`Rejected`）を検証し append-only event log（`EventClass="TopicItemInteraction"`）に記録。不正 `ActionKind` は `Failure`。戻り値は `EventId` 補完済 event。Options: `"Persist"`(True。テストは False で非永続)。

### SourceVaultAppendGraphAnnotation[targetRef, body, opts] → SourceVaultGraphAnnotation
node/view への追記を**非破壊に別 object 化**（元 object を破壊しない）し、`BranchRef` で調査ブランチを作り、event log（`EventClass="GraphAnnotation"`）に記録。
戻り値: `<|ObjectClass, AnnotationRef(svannotation:…), TargetNodeRef, BranchRef(svbranch:…), Body, AuthorRef, CreatedAtUTC, Provenance, ReviewState, Tags|>`。Options: `"Author"`, `"BranchRef"`, `"ReviewState"`(Draft), `"Tags"`, `"ViewRef"`, `"SearchSessionRef"`, `"Persist"`(True)。

### SourceVaultBuildInteractionMetaGraph[opts] → SourceVaultInteractionMetaGraph
記録した interaction/annotation event から meta-layer graph を作る。edge kind = 行動（Viewed/FollowedLink/Cited/Annotated…）、**weight = actor 重み（Owner 1.0 > Tool 0.5 > LLM 0.3）× action 重み（Cited 1.0 / Annotated 0.8 / Viewed 0.2 / Rejected −0.4 …）÷ frequency 正規化**（同一 actor 反復抑制）。
戻り値: `<|ObjectClass, NodeCount, EdgeCount, Nodes, Edges(From/To/Kind/Weight), InteractionEventCount, AnnotationCount|>`。Options: `"Events"`(Automatic=`SourceVaultTransactionLog`), `"Limit"`(2000), `"ActorWeights"`。

## §6.4 Retrieval episode graph（Phase 5）

検索を伴う 1 作業セッションを「どの検索キーを組み立て、どの結果を見て、どれを根拠に最終 object を作ったか」の探索グラフとして記録し、query 拡張 / ranking prior / agentic follow-up の学習に使う派生データ。**episode store は高機密行動ログ**（persist 時 `PrivacyLevel -> 1.0`, `Tags -> {"PrivateBehaviorLog", "NoCloudLLM"}`、cloud ReleaseContext の DenyTags で拒否）。influence boost は release gate / revocation / safety を緩めない。

### SourceVaultStartRetrievalEpisode[spec, opts] → SourceVaultRetrievalEpisode
episode を開始（in-memory active cache）。spec `<|SessionId, Actor, TaskRef, Inputs|>`。戻り値に `EpisodeId`(svepisode:…)。

### SourceVaultRecordSearchAttempt[episodeId, attempt, opts] → attempt
active episode に検索試行を追記。attempt `<|QueryText, QueryModality, SearchMethod(bm25|primer|web|mcp|agentic|cascade), ResultRefs, ClickedOrReadRefs, IncludedEvidenceRefs, RejectedRefs, ParentAttemptId|>`。

### SourceVaultCloseRetrievalEpisode[episodeId, outputs, opts] → episode
episode を `outputs` / `Outcome`(Succeeded|Partial|None) で確定し event log（`EventClass="RetrievalEpisode"`、PrivacyLevel 1.0、PrivateBehaviorLog/NoCloudLLM）に記録。Options: `"Outcome"`, `"Persist"`(True)。

### SourceVaultEpisodeInfluenceScores[episodeId, opts] → \<ref → score\>
各 result の output への influence を推定（**structural**: 引用/evidence 1.0・read 0.3・retrieved 0.05 − ignored-after-read 0.1 − rejected 0.4、× **actor factor**（LLM ≤ 0.7）× **time decay** `Exp[-age/HalfLifeDays]` × 自己引用 sublinear `÷√count`）。降順。Options: `"Episode"`(明示注入), `"HalfLifeDays"`(180)。※semantic overlap / graph proximity は今後（structural signals が MVP）。

### SourceVaultBuildRetrievalEpisodeGraph[opts] → SourceVaultRetrievalEpisodeGraph
記録 episode から `query -[Retrieved]-> result -[Influenced,weight=influence]-> output`＋attempt refinement chain を構築。Options: `"Episodes"`(Automatic=`SourceVaultTransactionLog` の RetrievalEpisode), `"Limit"`(1000)。

### SourceVaultSearchEpisodeMemory[query, opts] → Association
過去 episode を primer として引き、query 拡張候補を **low-leak projection**（term / sv-ref のみ、raw path 非開示）で返す。戻り値 `<|CandidateTerms, CandidateObjectRefs, MatchedEpisodes, Matches|>`。Options: `"Episodes"`, `"Limit"`(5), `"MinOverlap"`(0.2)。agentic loop の再検索で follow-up query 候補に使う。

## §6.6 SearchContextProfile（Phase 8）

同じ metadata でも検索目的（intent）で意味が変わる（作成日／変更日／イベント日／受信日／ingest 日…）。intent ごとに temporal field と metadata weight を変えて **ranking のみ**を調整する（release gate は変えない）。

### SourceVaultRegisterSearchContextProfile[id, spec] → profile
profile を登録。spec `<|Intent, PrimaryTemporalFields, SecondaryTemporalFields, MetadataWeights, TemporalInterpretation|>`。既定 7 intent（FindEvent / FindRecentWork / FindIngest / FindNegotiationOutcome / FindOriginalArtifact / RecallPersonalMemory / FindCreation）は初回に自動登録。

### SourceVaultSelectSearchContextProfile[query, opts] → profile
query intent を **rule ベース（LLM-free）** で推定し profile を選ぶ（「次の運動会」→FindEvent、「去年」→RecallPersonalMemory 等）。Options: `"Intent"`（ユーザー指定＝最優先）, `"Default"`(FindRecentWork)。

### SourceVaultApplySearchContextProfile[results, profile, opts] → results（再ランク）
各 result の Metadata（Title/Author/TopicItems/日付。result の `"Metadata"` に注入可）を profile の `MetadataWeights`＋primary/secondary temporal field で重み付けし、`ContextScore = BaseScore × (1 + BoostWeight × 正規化 contribution)` で再ランク。`BaseScore`/`ContextScore`/`ContextContribution` を各 result に付す。**gate は変えない**。Options: `"BoostWeight"`(0.5)。

### SourceVaultExplainSearchContext[result, profile] → Association
1 result の metadata contribution 内訳（`MetadataContribution` field→weight, `PrimaryTemporalHit`）を返す（score breakdown への明示）。

## §7 AgenticKeywordSearch / Cascade（Phase 9-10）

検索の最上位オーケストレーション層。**既定は deterministic planner（`AllowLLMPlanning -> False`）**＝LLM 呼び出し無しの純関数ループ。LLM planning は `PlannerFn` フック（入力 text は data boundary、tool 権限は検索のみ）。§6.4 episode memory・§6.6 context profile・§6.8 SearchView を部品に使う。

### SourceVaultClassifyQueryComplexity[query, opts] → Association（§7.5）
rule ベースで `Simple`|`Complex` 分類。multi-hop キーワード（比較/関係/なぜ/経緯/根拠/矛盾…）・長クエリ・(index 指定時) BM25 top score 低 → Complex。戻り値 `<|Query, Complexity, Signals|>`。Options: `"ReleaseContext"`, `"Index"`, `"LongQueryTerms"`(6), `"LowScoreThreshold"`(3.0)。

### SourceVaultAgenticSearch[query, opts] → Association（§7.2/§7.4）
agentic ループ: **classify → context profile 選択 → episode memory recall → chunk 検索 → context profile 適用 → evidence 充足判定 → 不足なら deterministic follow-up query（§7.6: evidence title terms ∪ episode memory terms ∪ relation 1-hop neighbor、同時 ≤2、既出 query 除外）→ 停止条件** を反復。retrieval episode（§6.4）を記録し SearchView（§6.8）を構築。
戻り値 `<|Results, Views(svview:…), AnswerDraft(deterministic は Missing), Complexity, Trace(Steps/Profile/TriedQueries/Iterations/ToolCalls), Stopped(EnoughEvidence|MaxIterations|NoProgress|BudgetExceeded)|>`。
Options: `"ReleaseContext"`(必須), `"Index"`, `"Limit"`(10), `"MaxIterations"`(3), `"MaxToolCalls"`(12), `"MinGroundedEvidence"`(2), `"NoProgressTermination"`(True), `"AllowLLMPlanning"`(False), `"PlannerFn"`, `"RelationGraph"`, `"RefLabel"`, `"ResultView"`(RankedList), `"RecordEpisode"`(True), `"ReturnTrace"`(True)。

### SourceVaultCascadeSearch[query, opts] → Association（§7.5）
complexity で dispatch: **Simple → `SourceVaultSearch`（BM25 直接、ループ無し）／Complex → `SourceVaultAgenticSearch`**。戻り値は AgenticSearch 形。opts は両者に透過。

**安全**: follow-up 候補も request-time gate / revocation / safety を通す。seed relation expansion が owner namespace を跨ぐ場合は provenance/confidence を trace に残す（今後）。LLM planning でも tool 権限は検索のみ。

## 一般メール構造化との接続（§9b）

一般メール構造化（[api_mailstructure.md](api_mailstructure.md)）の結果を live view にできる。`SourceVaultMailStructBuildSearchIndex` で作った index を `BuildSearchView["...", "Index" -> idx, "ReleaseContext" -> "mailstruct-cloud"]` に渡せば、mail session の RankedList view が返る。topic graph（`st["TopicGraph"]`）と relation graph を `TopicGraph`/`RelationGraph`/`ContextSubgraphRoot` に渡せば ContextSubgraph も付く。annotation / interaction は session / paragraph topic / quote edge の ref を `targetRef`/`ToNodeRef` に使う。

## 使用例

```wolfram
idx = SourceVaultMailStructBuildSearchIndex[st];   (* 一般メール index *)
view = SourceVaultBuildSearchView["予算", "ReleaseContext" -> "mailstruct-cloud", "Index" -> idx["IndexId"]];
SourceVaultRenderSearchNotebookView[view["ViewRef"]]["Notebook"]   (* FE で表示 *)

(* 閲覧行為を記録し meta graph を作る *)
SourceVaultRecordTopicItemInteraction[<|"Actor" -> <|"Kind" -> "Owner", "Ref" -> "sventity:owner:imai"|>,
   "ActionKind" -> "Cited", "ViewRef" -> view["ViewRef"], "ToNodeRef" -> First[view["Ordering"]]|>];
SourceVaultAppendGraphAnnotation[First[view["Ordering"]], "このスレッドが結論。"];
SourceVaultBuildInteractionMetaGraph[]
```

## 注意

- interaction/annotation は `SourceVaultAppendEvent` で永続（append-only・digest 付き・高機密行動ログ）。テストは `"Persist" -> False` で非永続。
- `$svSearchViews`（viewRef→view）は in-memory cache。永続 view が要る場合は別途 snapshot 化（今後）。
- 未実装（今後）: retrieval episode graph（§6.4）と meta-layer の検索 boost 統合（§6.7 associative level との接続）。
