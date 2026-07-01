(* ::Package:: *)

(* SourceVault_searchview.wl
   §6.8 Live hypertext interaction / annotation graph（検索基盤 spec v1, Phase 7.5）。
   検索結果を「たどれる作業面 (live view)」として返し、閲覧/追記行為を interaction meta-layer
   として蓄積する。base topic graph の上に actor/annotation の meta graph を作る。
   依存: SourceVault_searchindex (SourceVaultSearch), SourceVault_oopsseed (ExpandSearchGraph),
         SourceVault_core (AppendEvent/TransactionLog)。
   不変条件: release gate / request-time gate は緩めない。未許可 node は low-leak placeholder。
             raw local path は cell/tooltip/trace に出さない。meta-layer boost は gate を緩めず高機密扱い。 *)

BeginPackage["SourceVault`"]

SourceVaultBuildSearchView::usage =
  "SourceVaultBuildSearchView[query, opts] は gated 検索を走らせ SourceVaultSearchView object を作る (§3.4/§6.8)。" <>
  "RankedList は常に、ContextSubgraph/GraphPlot は TopicGraph+ContextSubgraphRoot 指定時に KG 展開で付く。" <>
  "戻り値 <|ObjectClass, ViewRef, ViewKind, SearchSessionRef, NodeRefs, Ordering, EdgeRefs, Results, ...|> (cache 済)。" <>
  "opts \"ReleaseContext\"(必須), \"Index\", \"Limit\"(10), \"ResultView\"(RankedList|ContextSubgraphNotebook|GraphPlot|All), " <>
  "\"TopicGraph\", \"RelationGraph\", \"RefLabel\", \"ContextSubgraphRoot\", \"ContextSubgraphDepth\"(1), \"SearchSessionRef\"。";
SourceVaultRenderSearchNotebookView::usage =
  "SourceVaultRenderSearchNotebookView[viewRef, opts] は cache した view を notebook cell 構造 (Column/Grid+Button) に整形する。" <>
  "未許可 node は low-leak placeholder。実描画は FE。opts \"MaxRows\"(20), \"Interactivity\"(Live|Static)。";
SourceVaultFollowSearchViewLink::usage =
  "SourceVaultFollowSearchViewLink[viewRef, linkRef, opts] は view 内 link をたどる (gated fetch)。" <>
  "topic ref は RelationGraph で近傍展開、content ref は re-gate。FollowedLink interaction event を記録する。" <>
  "opts \"RelationGraph\", \"RefLabel\", \"Actor\", \"Persist\"(True)。";
SourceVaultRecordTopicItemInteraction::usage =
  "SourceVaultRecordTopicItemInteraction[event, opts] は interaction event (Viewed/FollowedLink/Cited/Annotated/Rejected) を " <>
  "検証し append-only event log に記録する (§6.8。行動ログ=高機密)。LLM actor は owner より低重み。" <>
  "opts \"Persist\"(True)。戻り値 EventId 付き event。";
SourceVaultAppendGraphAnnotation::usage =
  "SourceVaultAppendGraphAnnotation[targetRef, body, opts] は node/view への追記を SourceVaultGraphAnnotation として " <>
  "非破壊に別 object 化し (BranchRef で調査ブランチ)、event log に記録する。" <>
  "opts \"Author\", \"BranchRef\", \"ReviewState\"(Draft), \"Tags\", \"ViewRef\", \"SearchSessionRef\", \"Persist\"(True)。";
SourceVaultBuildInteractionMetaGraph::usage =
  "SourceVaultBuildInteractionMetaGraph[opts] は記録した interaction/annotation event から meta-layer graph を作る。" <>
  "edge=Viewed/Followed/Cited/Annotated/BranchedFrom、actor weighting (Owner>Tool>LLM) + frequency 正規化。" <>
  "meta-layer boost は release gate を緩めない。opts \"Events\"(Automatic=TransactionLog), \"Limit\"(2000), \"ActorWeights\"。";

(* ---- §6.4 Retrieval episode graph (Phase 5) ---- *)
SourceVaultStartRetrievalEpisode::usage =
  "SourceVaultStartRetrievalEpisode[spec, opts] は検索を伴う 1 作業セッションを episode として開始する (§6.4)。" <>
  "spec: <|SessionId, Actor, TaskRef, Inputs|>。戻り値 SourceVaultRetrievalEpisode (EpisodeId、in-memory active cache)。";
SourceVaultRecordSearchAttempt::usage =
  "SourceVaultRecordSearchAttempt[episodeId, attempt, opts] は episode に検索試行を追記する。" <>
  "attempt: <|QueryText, QueryModality, SearchMethod, ResultRefs, ClickedOrReadRefs, IncludedEvidenceRefs, RejectedRefs, ParentAttemptId|>。";
SourceVaultCloseRetrievalEpisode::usage =
  "SourceVaultCloseRetrievalEpisode[episodeId, outputs, opts] は episode を outputs/outcome で確定し event log に記録する " <>
  "(高機密行動ログ: PrivacyLevel 1.0, Tags {PrivateBehaviorLog, NoCloudLLM})。opts \"Outcome\"(Succeeded|Partial|None), \"Persist\"(True)。";
SourceVaultBuildRetrievalEpisodeGraph::usage =
  "SourceVaultBuildRetrievalEpisodeGraph[opts] は記録した episode から探索グラフ (query->result->output) を作る。" <>
  "opts \"Episodes\"(Automatic=TransactionLog), \"Limit\"(1000)。";
SourceVaultEpisodeInfluenceScores::usage =
  "SourceVaultEpisodeInfluenceScores[episodeId, opts] は episode の各 result の output への influence を推定する (§6.4)。" <>
  "citation/read - ignored-after-read/rejected、actor factor (LLM<=0.7)、time decay Exp[-age/180]、自己引用 sublinear。" <>
  "opts \"Episode\"(明示注入), \"HalfLifeDays\"(180)。戻り値 result ref -> score (降順)。";
SourceVaultSearchEpisodeMemory::usage =
  "SourceVaultSearchEpisodeMemory[query, opts] は過去 episode を primer として引き、query 拡張候補 (term/object) を返す。" <>
  "**low-leak projection のみ** (raw path 非開示)。opts \"Episodes\"(Automatic), \"Limit\"(5), \"MinOverlap\"(0.2)。";

(* ---- §6.6 SearchContextProfile (Phase 8) ---- *)
SourceVaultRegisterSearchContextProfile::usage =
  "SourceVaultRegisterSearchContextProfile[id, spec] は search context profile を登録する (§6.6)。" <>
  "spec: <|Intent, PrimaryTemporalFields, SecondaryTemporalFields, MetadataWeights, TemporalInterpretation|>。既定 7 intent は自動登録。";
SourceVaultSelectSearchContextProfile::usage =
  "SourceVaultSelectSearchContextProfile[query, opts] は query intent を rule (LLM-free) で推定し profile を選ぶ。" <>
  "opts \"Intent\"(ユーザー指定=最優先), \"Default\"(FindRecentWork)。戻り値 profile。";
SourceVaultApplySearchContextProfile::usage =
  "SourceVaultApplySearchContextProfile[results, profile, opts] は profile の MetadataWeights/temporal field で results を再ランクする。" <>
  "**ranking のみ変更・release gate は変えない**。各 result の Metadata (Title/Author/TopicItems/date) を重み付け。opts \"BoostWeight\"(0.5)。";
SourceVaultExplainSearchContext::usage =
  "SourceVaultExplainSearchContext[result, profile] は 1 result の metadata contribution 内訳を返す (score breakdown に明示)。";

(* ---- §7 AgenticKeywordSearch / Cascade (Phase 9-10) ---- *)
SourceVaultClassifyQueryComplexity::usage =
  "SourceVaultClassifyQueryComplexity[query, opts] は query を rule ベースで Simple|Complex 分類する (§7.5)。" <>
  "multi-hop キーワード(比較/関係/なぜ/経緯/根拠…)・長クエリ・(index 指定時) BM25 top score 低で Complex。" <>
  "opts \"ReleaseContext\", \"Index\", \"LongQueryTerms\"(6), \"LowScoreThreshold\"(3.0)。";
SourceVaultAgenticSearch::usage =
  "SourceVaultAgenticSearch[query, opts] は §7 の agentic keyword search ループ (既定 deterministic planner)。" <>
  "complexity 分類→context profile 選択→episode memory→primer/chunk 検索→graph 展開→evidence 充足判定→" <>
  "不足なら deterministic follow-up query→停止条件、を反復し、retrieval episode 記録＋SearchView 構築。" <>
  "戻り値 <|Results, Views, AnswerDraft, Trace, Stopped(EnoughEvidence|MaxIterations|NoProgress|BudgetExceeded)|>。" <>
  "opts \"ReleaseContext\"(必須), \"Index\", \"Limit\"(10), \"MaxIterations\"(3), \"MaxToolCalls\"(12), " <>
  "\"MinGroundedEvidence\"(2), \"AllowLLMPlanning\"(False), \"PlannerFn\", \"RelationGraph\", \"RefLabel\", " <>
  "\"ResultView\"(RankedList), \"RecordEpisode\"(True), \"ReturnTrace\"(True)。";
SourceVaultCascadeSearch::usage =
  "SourceVaultCascadeSearch[query, opts] は complexity で dispatch する (§7.5): Simple->SourceVaultSearch (BM25)、" <>
  "Complex->SourceVaultAgenticSearch。戻り値は AgenticSearch 形。opts は両者に透過。";

Begin["`SearchViewPrivate`"]

If[! AssociationQ[$svSearchViews], $svSearchViews = <||>];   (* viewRef -> view (cache) *)

iSVSVId[prefix_String] := prefix <> ":" <> StringTake[StringDelete[CreateUUID[], "-"], 16];
iSVSVNow[] := Quiet@Check[DateString["ISODateTime"], "unknown"];

$svSVActorWeights = <|"Owner" -> 1.0, "Tool" -> 0.5, "LLM" -> 0.3|>;
$svSVActionWeights = <|"Cited" -> 1.0, "Annotated" -> 0.8, "Copied" -> 0.7,
  "FollowedLink" -> 0.4, "ExpandedNode" -> 0.4, "Viewed" -> 0.2, "Rejected" -> -0.4|>;

(* ---- BuildSearchView (§3.4/§6.8) ---- *)
Options[SourceVaultBuildSearchView] = {"ReleaseContext" -> None, "Index" -> None, "Limit" -> 10,
  "ResultView" -> "RankedList", "TopicGraph" -> None, "RelationGraph" -> None, "RefLabel" -> None,
  "ContextSubgraphRoot" -> Automatic, "ContextSubgraphDepth" -> 1, "SearchSessionRef" -> Automatic};
SourceVaultBuildSearchView[query_String, OptionsPattern[]] := Module[
  {ctx = OptionValue["ReleaseContext"], idx = OptionValue["Index"], lim = OptionValue["Limit"],
   viewKind = OptionValue["ResultView"], rg = OptionValue["RelationGraph"], refLabel = OptionValue["RefLabel"],
   subRoot = OptionValue["ContextSubgraphRoot"], subDepth = OptionValue["ContextSubgraphDepth"],
   results, rows, viewRef, sessRef, ordering, nodeRefs, subgraph, edgeRefs, view},
  If[! StringQ[ctx],
    Return[Failure["ReleaseContextRequired",
      <|"MessageTemplate" -> "SourceVaultBuildSearchView requires \"ReleaseContext\"."|>]]];
  results = SourceVaultSearch[query, "ReleaseContext" -> ctx, "Index" -> idx, "Limit" -> lim];
  If[FailureQ[results], Return[results]];
  rows = If[Head[results] === Dataset, Normal[results], If[ListQ[results], results, {}]];
  (* SourceVaultSearch は gate 済だが view 側でも Permit のみ・非 revoked を保証 (二重防御) *)
  rows = Select[rows, Lookup[#, "ReleaseDecision", "Permit"] === "Permit" && ! TrueQ[Lookup[#, "Revoked", False]] &];
  ordering = DeleteCases[Lookup[#, "ChunkId", ""] & /@ rows, ""];
  nodeRefs = DeleteDuplicates[Lookup[#, "SourceVaultObjectId", Lookup[#, "ChunkId", ""]] & /@ rows];
  viewRef = iSVSVId["svview"];
  sessRef = OptionValue["SearchSessionRef"] /. Automatic -> iSVSVId["svsession"];
  (* ContextSubgraph: topic ref root + relation graph があれば KG 展開 (既存 §6.3) *)
  subgraph = If[MemberQ[{"ContextSubgraphNotebook", "GraphPlot", "OrderedTree", "All"}, viewKind] &&
       StringQ[subRoot] && AssociationQ[rg],
    Quiet@Check[SourceVaultExpandSearchGraph[{subRoot}, "RelationGraph" -> rg, "MaxHops" -> subDepth,
       "RefLabel" -> refLabel, "ReleaseContext" -> ctx], Missing["ExpandFailed"]],
    Missing["NoSubgraph"]];
  edgeRefs = If[AssociationQ[subgraph],
    (("svedge:" <> ToString[#["From"]] <> "->" <> ToString[#["To"]]) & /@ Lookup[subgraph, "Edges", {}]), {}];
  If[AssociationQ[subgraph],
    nodeRefs = DeleteDuplicates[Join[nodeRefs, {subRoot}, Lookup[#, "Ref", Nothing] & /@ Lookup[subgraph, "Expanded", {}]]]];
  view = <|"ObjectClass" -> "SourceVaultSearchView", "ViewRef" -> viewRef, "ViewKind" -> viewKind,
    "SearchSessionRef" -> sessRef, "RootQueryRef" -> iSVSVId["svquery"], "Query" -> query,
    "RootNodeRefs" -> Take[ordering, UpTo[3]], "NodeRefs" -> nodeRefs,
    "EdgeRefs" -> edgeRefs, "Ordering" -> ordering, "GraphLayout" -> Automatic,
    "LazyLoadPolicy" -> <|"MaxInitialNodes" -> 80, "ExpandDepth" -> 1|>,
    "ReleaseContextRef" -> ctx, "BuiltAtUTC" -> iSVSVNow[],
    "Results" -> rows, "Subgraph" -> subgraph|>;
  $svSearchViews[viewRef] = view;
  view];

(* ---- RenderSearchNotebookView (§6.8。cell 構造。実描画は FE) ---- *)
Options[SourceVaultRenderSearchNotebookView] = {"MaxRows" -> 20, "Interactivity" -> "Live"};
SourceVaultRenderSearchNotebookView[viewRef_String, OptionsPattern[]] := Module[
  {view = Lookup[$svSearchViews, viewRef, Missing["ViewNotFound"]], rows, maxRows = OptionValue["MaxRows"], cells},
  If[! AssociationQ[view], Return[view]];
  rows = Take[Lookup[view, "Results", {}], UpTo[maxRows]];
  cells = MapIndexed[Function[{r, i}, With[
     {title = Lookup[Lookup[r, "Citation", <||>], "Title", "(no title)"],
      snip = StringTake[StringReplace[Lookup[r, "Snippet", ""], {"\n" -> " ", "\r" -> ""}], UpTo[160]],
      cid = Lookup[r, "ChunkId", ""], sc = Round[Lookup[r, "Score", 0.], 0.01]},
     (* 未許可 node は BuildSearchView で除外済。link は viewRef 経由の follow を促す (raw path は出さない) *)
     Framed[Column[{
        Style[ToString[First[i]] <> ". " <> title <> "  (score " <> ToString[sc] <> ")", Bold],
        Style[snip, Gray],
        Style["node: " <> cid, Small, Gray]}], RoundingRadius -> 4]]], rows];
  <|"ViewRef" -> viewRef, "ViewKind" -> view["ViewKind"], "Query" -> Lookup[view, "Query", ""],
    "RowCount" -> Length[rows], "Notebook" -> Column[Prepend[cells,
       Style["検索 view: " <> Lookup[view, "Query", ""] <> "  [" <> view["ViewKind"] <> "]", Bold, 14]], Spacings -> 1]|>];

(* ---- interaction event の検証+記録 (§6.8) ---- *)
iSVSVEnsureEvent[event_Association] := Module[{actor = Lookup[event, "Actor", <||>]},
  <|"ObjectClass" -> "SourceVaultTopicItemInteractionEvent",
    "EventId" -> Lookup[event, "EventId", iSVSVId["svinteract"]],
    "Actor" -> <|"Kind" -> Lookup[actor, "Kind", "Tool"], "Ref" -> Lookup[actor, "Ref", "svactor:unknown"]|>,
    "ActionKind" -> Lookup[event, "ActionKind", "Viewed"],
    "ViewRef" -> Lookup[event, "ViewRef", Missing[]],
    "SearchSessionRef" -> Lookup[event, "SearchSessionRef", Missing[]],
    "FromNodeRef" -> Lookup[event, "FromNodeRef", Missing[]],
    "ToNodeRef" -> Lookup[event, "ToNodeRef", Missing[]],
    "EdgeRef" -> Lookup[event, "EdgeRef", Missing[]],
    "OutputRef" -> Lookup[event, "OutputRef", Missing[]],
    "AnnotationRef" -> Lookup[event, "AnnotationRef", Missing[]],
    "OccurredAtUTC" -> Lookup[event, "OccurredAtUTC", iSVSVNow[]],
    "ReleaseContextRef" -> Lookup[event, "ReleaseContextRef", Missing[]]|>];

Options[SourceVaultRecordTopicItemInteraction] = {"Persist" -> True};
SourceVaultRecordTopicItemInteraction[event_Association, OptionsPattern[]] := Module[{ev},
  ev = iSVSVEnsureEvent[event];
  If[! MemberQ[{"Viewed", "FollowedLink", "ExpandedNode", "Cited", "Copied", "Annotated", "Rejected"},
      ev["ActionKind"]],
    Return[Failure["BadActionKind", <|"MessageTemplate" -> "Unknown ActionKind: `1`",
      "MessageParameters" -> {ev["ActionKind"]}|>]]];
  If[TrueQ[OptionValue["Persist"]],
    Quiet@Check[SourceVault`SourceVaultAppendEvent[Append[ev, "EventClass" -> "TopicItemInteraction"]], $Failed]];
  ev];

(* ---- annotation (§6.8。非破壊・別 object・BranchRef) ---- *)
Options[SourceVaultAppendGraphAnnotation] = {"Author" -> "sventity:owner:imai", "BranchRef" -> Automatic,
  "ReviewState" -> "Draft", "Tags" -> {}, "ViewRef" -> Missing[], "SearchSessionRef" -> Missing[], "Persist" -> True};
SourceVaultAppendGraphAnnotation[targetRef_String, body_String, OptionsPattern[]] := Module[{ann},
  ann = <|"ObjectClass" -> "SourceVaultGraphAnnotation",
    "AnnotationRef" -> iSVSVId["svannotation"],
    "TargetNodeRef" -> targetRef,
    "BranchRef" -> (OptionValue["BranchRef"] /. Automatic -> iSVSVId["svbranch"]),
    "Body" -> body, "AuthorRef" -> OptionValue["Author"], "CreatedAtUTC" -> iSVSVNow[],
    "Provenance" -> <|"ViewRef" -> OptionValue["ViewRef"], "SearchSessionRef" -> OptionValue["SearchSessionRef"]|>,
    "ReviewState" -> OptionValue["ReviewState"], "Tags" -> OptionValue["Tags"]|>;
  If[TrueQ[OptionValue["Persist"]],
    Quiet@Check[SourceVault`SourceVaultAppendEvent[
       Append[ann, "EventClass" -> "GraphAnnotation"]], $Failed]];
  ann];

(* ---- FollowSearchViewLink (§6.8。gated fetch + FollowedLink 記録) ---- *)
Options[SourceVaultFollowSearchViewLink] = {"RelationGraph" -> None, "RefLabel" -> None,
  "Actor" -> <|"Kind" -> "Owner", "Ref" -> "sventity:owner:imai"|>, "MaxNeighbors" -> 8, "Persist" -> True};
SourceVaultFollowSearchViewLink[viewRef_String, linkRef_String, OptionsPattern[]] := Module[
  {view = Lookup[$svSearchViews, viewRef, Missing["ViewNotFound"]], rg = OptionValue["RelationGraph"],
   refLabel = OptionValue["RefLabel"], neighbors, kind, payload},
  If[! AssociationQ[view], Return[view]];
  (* topic ref は近傍展開 (metadata。§6.3 の gate=content 取得時)、その他 content ref は low-leak placeholder *)
  kind = Which[StringStartsQ[linkRef, "svtopic:"], "Topic",
     StringStartsQ[linkRef, "sv://"] || StringStartsQ[linkRef, "svmailpara:"], "Content", True, "Node"];
  neighbors = If[kind === "Topic" && AssociationQ[rg],
     Lookup[Quiet@Check[SourceVaultExpandSearchGraph[{linkRef}, "RelationGraph" -> rg, "MaxHops" -> 1,
        "RefLabel" -> refLabel, "MaxNodes" -> OptionValue["MaxNeighbors"]], <||>], "Expanded", {}], {}];
  payload = Which[
     kind === "Topic", <|"Kind" -> "Topic", "Ref" -> linkRef, "Neighbors" -> neighbors|>,
     kind === "Content", <|"Kind" -> "Content", "Ref" -> linkRef,
        "Note" -> "content は release gate 越しに検索経由で取得 (raw path 非開示)"|>,
     True, <|"Kind" -> "Node", "Ref" -> linkRef|>];
  (* FollowedLink interaction を記録 *)
  SourceVaultRecordTopicItemInteraction[<|"Actor" -> OptionValue["Actor"], "ActionKind" -> "FollowedLink",
     "ViewRef" -> viewRef, "SearchSessionRef" -> Lookup[view, "SearchSessionRef", Missing[]],
     "ToNodeRef" -> linkRef, "ReleaseContextRef" -> Lookup[view, "ReleaseContextRef", Missing[]]|>,
     "Persist" -> OptionValue["Persist"]];
  payload];

(* ---- BuildInteractionMetaGraph (§6.8。actor weighting + frequency 正規化) ---- *)
Options[SourceVaultBuildInteractionMetaGraph] = {"Events" -> Automatic, "Limit" -> 2000,
  "ActorWeights" -> Automatic};
SourceVaultBuildInteractionMetaGraph[OptionsPattern[]] := Module[
  {evs = OptionValue["Events"], aw = OptionValue["ActorWeights"], intev, annev, edges, freq, nodes},
  aw = aw /. Automatic -> $svSVActorWeights;
  evs = evs /. Automatic :> Quiet@Check[
     SourceVault`SourceVaultTransactionLog["Limit" -> OptionValue["Limit"]], {}];
  If[! ListQ[evs], evs = {}];
  intev = Select[evs, Lookup[#, "EventClass", ""] === "TopicItemInteraction" &];
  annev = Select[evs, Lookup[#, "EventClass", ""] === "GraphAnnotation" &];
  (* frequency 正規化 (同一 actor の反復行動を抑制) *)
  freq = Counts[Lookup[Lookup[#, "Actor", <||>], "Ref", "?"] & /@ intev];
  edges = DeleteMissing@Map[Function[e, With[
     {actorKind = Lookup[Lookup[e, "Actor", <||>], "Kind", "Tool"],
      actorRef = Lookup[Lookup[e, "Actor", <||>], "Ref", "?"],
      action = Lookup[e, "ActionKind", "Viewed"], to = Lookup[e, "ToNodeRef", Missing[]]},
     If[MissingQ[to], Missing[],
       <|"From" -> actorRef, "To" -> to, "Kind" -> action,
         "Weight" -> Round[Lookup[aw, actorKind, 0.3] * Lookup[$svSVActionWeights, action, 0.2] /
            Max[1, Sqrt[Lookup[freq, actorRef, 1]]], 0.001]|>]]], intev];
  (* annotation edge (BranchedFrom / Annotated) *)
  edges = Join[edges, Map[Function[a,
     <|"From" -> Lookup[a, "AuthorRef", "?"], "To" -> Lookup[a, "TargetNodeRef", "?"],
       "Kind" -> "Annotated", "AnnotationRef" -> Lookup[a, "AnnotationRef", Missing[]], "Weight" -> 0.8|>], annev]];
  nodes = DeleteDuplicates[Flatten[{#["From"], #["To"]} & /@ edges]];
  <|"ObjectClass" -> "SourceVaultInteractionMetaGraph",
    "NodeCount" -> Length[nodes], "EdgeCount" -> Length[edges],
    "Nodes" -> nodes, "Edges" -> edges,
    "InteractionEventCount" -> Length[intev], "AnnotationCount" -> Length[annev],
    "Note" -> "meta-layer は行動ログ (高機密)。boost は release gate を緩めない。"|>];

(* ================= §6.4 Retrieval episode graph (Phase 5) ================= *)

If[! AssociationQ[$svActiveEpisodes], $svActiveEpisodes = <||>];   (* episodeId -> open episode *)
$svSVLLMInfluenceCap = 0.7;   (* LLM actor の influence 上限 (自己強化抑制) *)

iSVSVActorFactor[kind_] := Switch[kind, "Owner", 1.0, "Tool", 0.5, "LLM", $svSVLLMInfluenceCap, _, 0.5];
iSVSVAgeDays[utc_] := Quiet@Check[
  With[{d = DateObject[utc]}, If[Head[d] === DateObject, Max[0., QuantityMagnitude[DateDifference[d, Now, "Day"]]], 0.]], 0.];
iSVSVTimeDecay[utc_, half_] := Exp[-iSVSVAgeDays[utc]/N[half]];

Options[SourceVaultStartRetrievalEpisode] = {};
SourceVaultStartRetrievalEpisode[spec_Association, OptionsPattern[]] := Module[{ep},
  ep = <|"ObjectClass" -> "SourceVaultRetrievalEpisode", "EpisodeId" -> iSVSVId["svepisode"],
    "SessionId" -> Lookup[spec, "SessionId", iSVSVId["svsession"]],
    "Actor" -> Lookup[spec, "Actor", <|"Kind" -> "Owner", "Ref" -> "sventity:owner:imai"|>],
    "TaskRef" -> Lookup[spec, "TaskRef", Missing[]],
    "Inputs" -> Lookup[spec, "Inputs", {}],
    "SearchAttempts" -> {}, "Outputs" -> {}, "Outcome" -> "None",
    "StartedAtUTC" -> iSVSVNow[], "BuiltAtUTC" -> Missing["Open"]|>;
  $svActiveEpisodes[ep["EpisodeId"]] = ep; ep];

Options[SourceVaultRecordSearchAttempt] = {};
SourceVaultRecordSearchAttempt[episodeId_String, attempt_Association, OptionsPattern[]] := Module[
  {ep = Lookup[$svActiveEpisodes, episodeId, Missing[]], att},
  If[! AssociationQ[ep], Return[Failure["EpisodeNotOpen", <|"MessageTemplate" -> "No open episode: `1`",
    "MessageParameters" -> {episodeId}|>]]];
  att = <|"AttemptId" -> Lookup[attempt, "AttemptId", iSVSVId["svattempt"]],
    "ParentAttemptId" -> Lookup[attempt, "ParentAttemptId", Missing[]],
    "QueryObjectRef" -> Lookup[attempt, "QueryObjectRef", iSVSVId["svquery"]],
    "QueryText" -> Lookup[attempt, "QueryText", ""],
    "QueryModality" -> Lookup[attempt, "QueryModality", "text"],
    "SearchMethod" -> Lookup[attempt, "SearchMethod", "bm25"],
    "ResultRefs" -> Lookup[attempt, "ResultRefs", {}],
    "ClickedOrReadRefs" -> Lookup[attempt, "ClickedOrReadRefs", {}],
    "IncludedEvidenceRefs" -> Lookup[attempt, "IncludedEvidenceRefs", {}],
    "RejectedRefs" -> Lookup[attempt, "RejectedRefs", {}],
    "StartedAtUTC" -> Lookup[attempt, "StartedAtUTC", iSVSVNow[]],
    "EndedAtUTC" -> Lookup[attempt, "EndedAtUTC", iSVSVNow[]],
    "TraceRef" -> Lookup[attempt, "TraceRef", Missing[]]|>;
  ep["SearchAttempts"] = Append[ep["SearchAttempts"], att];
  $svActiveEpisodes[episodeId] = ep; att];

Options[SourceVaultCloseRetrievalEpisode] = {"Outcome" -> "Succeeded", "Persist" -> True};
SourceVaultCloseRetrievalEpisode[episodeId_String, outputs_List, OptionsPattern[]] := Module[
  {ep = Lookup[$svActiveEpisodes, episodeId, Missing[]]},
  If[! AssociationQ[ep], Return[Failure["EpisodeNotOpen", <|"MessageTemplate" -> "No open episode: `1`",
    "MessageParameters" -> {episodeId}|>]]];
  ep = Append[ep, <|"Outputs" -> outputs, "Outcome" -> OptionValue["Outcome"], "BuiltAtUTC" -> iSVSVNow[]|>];
  (* episode store は高機密行動ログ (§6.4 安全条件) *)
  If[TrueQ[OptionValue["Persist"]],
    Quiet@Check[SourceVault`SourceVaultAppendEvent[Append[ep,
       <|"EventClass" -> "RetrievalEpisode", "PrivacyLevel" -> 1.0,
         "Tags" -> {"PrivateBehaviorLog", "NoCloudLLM"}|>]], $Failed]];
  $svActiveEpisodes = KeyDrop[$svActiveEpisodes, episodeId];
  ep];

(* result ref -> influence (structural: citation/read - ignored/rejected、actor factor、time decay、自己引用 sublinear) *)
iSVSVEpisodeInfluence[ep_Association, half_] := Module[
  {atts = Lookup[ep, "SearchAttempts", {}], factor, decay, raw = <||>, cites = <||>},
  factor = iSVSVActorFactor[Lookup[Lookup[ep, "Actor", <||>], "Kind", "Owner"]];
  decay = iSVSVTimeDecay[Lookup[ep, "BuiltAtUTC", Lookup[ep, "StartedAtUTC", Missing[]]], half];
  Do[With[{inc = Lookup[att, "IncludedEvidenceRefs", {}], read = Lookup[att, "ClickedOrReadRefs", {}],
      rej = Lookup[att, "RejectedRefs", {}], res = Lookup[att, "ResultRefs", {}]},
    Do[cites[r] = Lookup[cites, r, 0] + 1;
       raw[r] = Lookup[raw, r, 0.] + Which[
          MemberQ[inc, r], 1.0,                              (* evidence inclusion = strong *)
          MemberQ[read, r], 0.3,                             (* read/click *)
          True, 0.05],                                       (* merely retrieved *)
       {r, DeleteDuplicates[Join[res, read, inc]]}];
    Do[raw[r] = Lookup[raw, r, 0.] - 0.4, {r, rej}];         (* rejected penalty *)
    Do[If[MemberQ[read, r] && ! MemberQ[inc, r], raw[r] = Lookup[raw, r, 0.] - 0.1],
       {r, read}]],                                          (* ignored-after-read penalty *)
    {att, atts}];
  (* 自己引用 sublinear + actor factor + time decay *)
  KeySort@Association@KeyValueMap[Function[{r, s},
    r -> Round[factor * decay * s / Max[1., Sqrt[Lookup[cites, r, 1]]], 0.001]], raw]];

Options[SourceVaultEpisodeInfluenceScores] = {"Episode" -> Automatic, "HalfLifeDays" -> 180};
SourceVaultEpisodeInfluenceScores[episodeId_String, OptionsPattern[]] := Module[
  {ep = OptionValue["Episode"], scores},
  If[ep === Automatic, ep = Lookup[$svActiveEpisodes, episodeId, Missing[]]];
  If[! AssociationQ[ep], Return[Failure["EpisodeNotFound", <|"MessageTemplate" -> "Episode not found: `1` (pass \"Episode\")",
    "MessageParameters" -> {episodeId}|>]]];
  scores = iSVSVEpisodeInfluence[ep, OptionValue["HalfLifeDays"]];
  ReverseSort[scores]];

iSVSVEpisodesFromStore[injected_, limit_] := If[ListQ[injected], injected,
  Select[Quiet@Check[SourceVault`SourceVaultTransactionLog["Limit" -> limit], {}] /. Except[_List] -> {},
    Lookup[#, "EventClass", ""] === "RetrievalEpisode" &]];

Options[SourceVaultBuildRetrievalEpisodeGraph] = {"Episodes" -> Automatic, "Limit" -> 1000};
SourceVaultBuildRetrievalEpisodeGraph[OptionsPattern[]] := Module[
  {eps = iSVSVEpisodesFromStore[OptionValue["Episodes"] /. Automatic -> Null, OptionValue["Limit"]],
   edges = {}, nodes},
  Do[With[{outs = Lookup[ep, "Outputs", {}], infl = iSVSVEpisodeInfluence[ep, 180]},
    Do[With[{q = Lookup[att, "QueryObjectRef", "svquery:?"]},
      (* query -> result (Retrieved) *)
      Do[AppendTo[edges, <|"From" -> q, "To" -> r, "Kind" -> "Retrieved", "Weight" -> 0.2|>],
         {r, Lookup[att, "ResultRefs", {}]}];
      (* result -> output (Influenced, weight=influence) *)
      Do[Do[AppendTo[edges, <|"From" -> r, "To" -> o, "Kind" -> "Influenced",
             "Weight" -> Lookup[infl, r, 0.]|>], {o, outs}],
         {r, Lookup[att, "IncludedEvidenceRefs", Lookup[att, "ResultRefs", {}]]}];
      (* attempt refinement chain *)
      If[StringQ[Lookup[att, "ParentAttemptId", Missing[]]],
        AppendTo[edges, <|"From" -> att["ParentAttemptId"], "To" -> att["AttemptId"],
          "Kind" -> "RefinedTo", "Weight" -> 0.1|>]]],
      {att, Lookup[ep, "SearchAttempts", {}]}]],
    {ep, eps}];
  nodes = DeleteDuplicates[Flatten[{#["From"], #["To"]} & /@ edges]];
  <|"ObjectClass" -> "SourceVaultRetrievalEpisodeGraph",
    "EpisodeCount" -> Length[eps], "NodeCount" -> Length[nodes], "EdgeCount" -> Length[edges],
    "Nodes" -> nodes, "Edges" -> edges,
    "Note" -> "episode store は高機密行動ログ。influence boost は release gate を緩めない。"|>];

iSVSVTerms[s_String] := DeleteCases[StringSplit[SourceVaultNormalizeSearchText[s], RegularExpression["\\s+"]], ""];

Options[SourceVaultSearchEpisodeMemory] = {"Episodes" -> Automatic, "Limit" -> 5, "MinOverlap" -> 0.2};
SourceVaultSearchEpisodeMemory[query_String, OptionsPattern[]] := Module[
  {eps = iSVSVEpisodesFromStore[OptionValue["Episodes"] /. Automatic -> Null, 1000],
   qterms, matched, minOv = OptionValue["MinOverlap"]},
  qterms = iSVSVTerms[query];
  If[qterms === {}, Return[<|"CandidateTerms" -> {}, "CandidateObjectRefs" -> {}, "MatchedEpisodes" -> 0|>]];
  matched = DeleteMissing@Map[Function[ep, Module[
     {epTerms = DeleteDuplicates[Flatten[iSVSVTerms[Lookup[#, "QueryText", ""]] & /@ Lookup[ep, "SearchAttempts", {}]]],
      ov, infl},
     ov = N[Length[Intersection[qterms, epTerms]]/Max[1, Length[Union[qterms, epTerms]]]];
     If[ov < minOv, Missing[],
       infl = ReverseSort[iSVSVEpisodeInfluence[ep, 180]];
       <|"EpisodeId" -> Lookup[ep, "EpisodeId", "?"], "Overlap" -> Round[ov, 0.01],
         "TopResultRefs" -> Take[Keys@Select[infl, # > 0 &], UpTo[5]],
         "Terms" -> Complement[epTerms, qterms]|>]]], eps];
  matched = Take[ReverseSortBy[matched, #["Overlap"] &], UpTo[OptionValue["Limit"]]];
  (* low-leak projection: term / sv-ref のみ (raw local path 非開示) *)
  <|"CandidateTerms" -> Take[DeleteDuplicates[Flatten[#["Terms"] & /@ matched]], UpTo[20]],
    "CandidateObjectRefs" -> DeleteDuplicates[Flatten[#["TopResultRefs"] & /@ matched]],
    "MatchedEpisodes" -> Length[matched], "Matches" -> matched,
    "Note" -> "low-leak projection (raw path 非開示)。influence boost は release gate を緩めない。"|>];

(* ================= §6.6 SearchContextProfile (Phase 8) ================= *)

If[! AssociationQ[$svSearchContextProfiles], $svSearchContextProfiles = <||>];

(* intent -> query キーワード (rule ベース LLM-free classifier) *)
$svSVIntentKeywords = <|
  "FindEvent" -> {"イベント", "開催", "行事", "予定", "運動会", "会議", "次の金曜", "next friday", "当日"},
  "FindRecentWork" -> {"最近", "最新", "直近", "新しい", "次にすること", "todo", "recent", "latest"},
  "FindIngest" -> {"追加", "取り込", "保存した", "ingest", "added", "recently added"},
  "FindNegotiationOutcome" -> {"結論", "経緯", "前回", "交渉", "決定", "合意", "outcome", "まとめ"},
  "FindOriginalArtifact" -> {"撮影", "元", "オリジナル", "原本", "original", "taken", "初出"},
  "RecallPersonalMemory" -> {"去年", "昨年", "以前", "あの時", "思い出", "last year", "去々年"},
  "FindCreation" -> {"作成", "書いた", "created", "初稿", "起草"}|>;

(* 既定 profile を登録 (冪等) *)
iSVSVEnsureContextProfiles[] := If[$svSearchContextProfiles === <||>,
  Module[{baseW = <|"Title" -> 1.0, "Author" -> 0.7, "Sender" -> 0.7, "TopicItems" -> 1.0,
     "EventDate" -> 1.0, "MessageDate" -> 0.4, "IngestedAt" -> 0.2,
     "EXIFOriginalDate" -> 0.9, "FileMTime" -> 0.2, "CreatedAt" -> 0.6|>,
    prim},
   prim = <|"FindEvent" -> {"EventDate"}, "FindRecentWork" -> {"MessageDate", "IngestedAt"},
     "FindIngest" -> {"IngestedAt"}, "FindNegotiationOutcome" -> {"MailSessionResolutionDate", "MessageDate"},
     "FindOriginalArtifact" -> {"EXIFOriginalDate", "CreatedAt"}, "RecallPersonalMemory" -> {"EventDate", "MessageDate"},
     "FindCreation" -> {"CreatedAt"}|>;
   Do[SourceVaultRegisterSearchContextProfile["svsearchctx:default:" <> intent,
       <|"Intent" -> intent, "PrimaryTemporalFields" -> prim[intent],
         "SecondaryTemporalFields" -> {"MessageDate", "IngestedAt", "FileMTime"},
         "MetadataWeights" -> baseW|>],
     {intent, Keys[$svSVIntentKeywords]}]]];

SourceVaultRegisterSearchContextProfile[id_String, spec_Association] := (
  $svSearchContextProfiles[id] = <|"ObjectClass" -> "SourceVaultSearchContextProfile", "ProfileId" -> id,
    "Intent" -> Lookup[spec, "Intent", "FindRecentWork"],
    "PrimaryTemporalFields" -> Lookup[spec, "PrimaryTemporalFields", {"MessageDate"}],
    "SecondaryTemporalFields" -> Lookup[spec, "SecondaryTemporalFields", {"IngestedAt"}],
    "MetadataWeights" -> Lookup[spec, "MetadataWeights", <|"Title" -> 1.0, "TopicItems" -> 1.0|>],
    "TemporalInterpretation" -> Lookup[spec, "TemporalInterpretation", <||>]|>;
  $svSearchContextProfiles[id]);

Options[SourceVaultSelectSearchContextProfile] = {"Intent" -> Automatic, "Default" -> "FindRecentWork"};
SourceVaultSelectSearchContextProfile[query_String, OptionsPattern[]] := Module[
  {qn = ToLowerCase[query], scores, intent, prof},
  iSVSVEnsureContextProfiles[];
  intent = OptionValue["Intent"];   (* ユーザー指定=最優先 *)
  If[! StringQ[intent] || ! KeyExistsQ[$svSVIntentKeywords, intent],
    scores = Association@KeyValueMap[Function[{it, kws},
       it -> Total[Boole[StringContainsQ[qn, ToLowerCase[#]]] & /@ kws]], $svSVIntentKeywords];
    intent = If[Max[Values[scores]] > 0, First[Keys[ReverseSort[scores]]], OptionValue["Default"]]];
  prof = Lookup[$svSearchContextProfiles, "svsearchctx:default:" <> intent, Missing[]];
  If[! AssociationQ[prof], prof = First[Values[$svSearchContextProfiles], Missing["NoProfile"]]];
  prof];

(* result の metadata を取り出す (Citation/既知キー ∪ result["Metadata"] 注入) *)
iSVSVResultMeta[r_Association] := Join[
  <|"Title" -> Lookup[Lookup[r, "Citation", <||>], "Title", Lookup[r, "Title", ""]],
    "Author" -> Lookup[r, "Author", ""], "Sender" -> Lookup[r, "Sender", ""],
    "TopicItems" -> Lookup[r, "TopicRefs", {}]|>,
  Lookup[r, "Metadata", <||>]];

iSVSVFieldPresent[v_] := Which[StringQ[v], StringTrim[v] =!= "", ListQ[v], v =!= {}, True, ! MissingQ[v] && v =!= Null && v =!= 0];

(* profile contribution: MetadataWeights × field 有無 + primary/secondary temporal 加点、正規化 [0,1] *)
iSVSVContextContribution[r_Association, profile_Association] := Module[
  {meta = iSVSVResultMeta[r], weights = Lookup[profile, "MetadataWeights", <||>],
   prim = Lookup[profile, "PrimaryTemporalFields", {}], sec = Lookup[profile, "SecondaryTemporalFields", {}],
   parts, primPart, secPart, denom, total},
  parts = Association@KeyValueMap[Function[{field, w},
     field -> If[iSVSVFieldPresent[Lookup[meta, field, Missing[]]], N[w], 0.]], weights];
  primPart = Total[If[iSVSVFieldPresent[Lookup[meta, #, Missing[]]], 1.0, 0.] & /@ prim];
  secPart = 0.5 * Total[If[iSVSVFieldPresent[Lookup[meta, #, Missing[]]], 1.0, 0.] & /@ sec];
  total = Total[Values[parts]] + primPart + secPart;
  denom = Total[Values[weights]] + Length[prim] + 0.5 * Length[sec];
  <|"Contribution" -> If[denom > 0, N[total/denom], 0.], "FieldParts" -> parts,
    "PrimaryTemporalHit" -> primPart, "SecondaryTemporalHit" -> secPart|>];

Options[SourceVaultApplySearchContextProfile] = {"BoostWeight" -> 0.5};
SourceVaultApplySearchContextProfile[results_List, profile_Association, OptionsPattern[]] := Module[
  {bw = OptionValue["BoostWeight"], scored},
  (* ranking のみ変更。release gate は変えない (results は既に gated) *)
  scored = Map[Function[r, Module[{base = N[Lookup[r, "Score", 0.]], c},
     c = iSVSVContextContribution[r, profile];
     Append[r, <|"BaseScore" -> base,
        "ContextScore" -> Round[base * (1. + bw * c["Contribution"]), 0.0001],
        "ContextProfile" -> Lookup[profile, "ProfileId", "?"],
        "ContextContribution" -> Round[c["Contribution"], 0.001]|>]]], results];
  ReverseSortBy[scored, #["ContextScore"] &]];

SourceVaultExplainSearchContext[result_Association, profile_Association] := Module[
  {c = iSVSVContextContribution[result, profile]},
  <|"ProfileId" -> Lookup[profile, "ProfileId", "?"], "Intent" -> Lookup[profile, "Intent", "?"],
    "Contribution" -> Round[c["Contribution"], 0.001],
    "MetadataContribution" -> Select[c["FieldParts"], # > 0 &],
    "PrimaryTemporalHit" -> c["PrimaryTemporalHit"], "SecondaryTemporalHit" -> c["SecondaryTemporalHit"],
    "Note" -> "context profile は ranking のみ変更・release gate は変えない。"|>];

(* ================= §7 AgenticKeywordSearch / Cascade (Phase 9-10) ================= *)

$svSVComplexKeywords = {"比較", "関係", "なぜ", "理由", "経緯", "誰が", "いつから", "矛盾", "根拠",
  "違い", "推移", "結論", "交渉", "日程", "まとめ", "比べ", "どう", "背景", "対立",
  "because", "why", "how", "compare", "relationship", "conflict", "history"};

Options[SourceVaultClassifyQueryComplexity] = {"ReleaseContext" -> None, "Index" -> None,
  "LongQueryTerms" -> 6, "LowScoreThreshold" -> 3.0};
SourceVaultClassifyQueryComplexity[query_String, OptionsPattern[]] := Module[
  {qn = ToLowerCase[query], terms, signals = {}, ctx = OptionValue["ReleaseContext"],
   idx = OptionValue["Index"], topScore},
  terms = iSVSVTerms[query];
  If[AnyTrue[$svSVComplexKeywords, StringContainsQ[qn, ToLowerCase[#]] &],
    AppendTo[signals, "MultiHopKeyword"]];
  If[Length[terms] >= OptionValue["LongQueryTerms"], AppendTo[signals, "LongQuery"]];
  If[StringQ[ctx] && StringQ[idx],
    topScore = Quiet@Check[With[{r = SourceVaultSearch[query, "ReleaseContext" -> ctx, "Index" -> idx, "Limit" -> 3]},
       If[Head[r] === Dataset, r = Normal[r]]; If[ListQ[r] && r =!= {}, Lookup[First[r], "Score", 0.], 0.]], 0.];
    If[topScore < OptionValue["LowScoreThreshold"], AppendTo[signals, "LowBM25(" <> ToString[Round[topScore, 0.1]] <> ")"]]];
  <|"Query" -> query, "Complexity" -> If[signals === {}, "Simple", "Complex"], "Signals" -> signals|>];

(* result 群 + episode memory + relation neighbor から deterministic follow-up query 語を作る (§7.6) *)
iSVSVFollowUpTerms[state_Association, evidence_List, episodeMem_Association, rg_, refLabel_] := Module[
  {qterms, evTerms, memTerms, relTerms, cand},
  qterms = iSVSVTerms[state["Query"]];
  (* 1. top evidence の title terms *)
  evTerms = Flatten[iSVSVTerms[Lookup[Lookup[#, "Citation", <||>], "Title", ""]] & /@ Take[evidence, UpTo[3]]];
  (* 4. episode memory の high-influence terms *)
  memTerms = Lookup[episodeMem, "CandidateTerms", {}];
  (* 3. relation 1-hop neighbor label (evidence の topic ref から) *)
  relTerms = If[AssociationQ[rg],
    Module[{topicRefs = DeleteDuplicates[Flatten[Lookup[#, "TopicRefs", {}] & /@ Take[evidence, UpTo[3]]]]},
      If[topicRefs === {}, {},
        Lookup[Lookup[Quiet@Check[SourceVaultExpandSearchGraph[topicRefs, "RelationGraph" -> rg, "MaxHops" -> 1,
           "RefLabel" -> refLabel, "MaxNodes" -> 6], <||>], "Expanded", {}], "Label", ""]]], {}];
  (* 既出 query 語を除き最大 2 語 (制約: 同時 <=2) *)
  cand = DeleteCases[DeleteDuplicates[Join[evTerms, memTerms, relTerms]], "" | Alternatives @@ qterms];
  Take[cand, UpTo[2]]];

Options[SourceVaultAgenticSearch] = {"ReleaseContext" -> None, "Index" -> None, "PrimerIndex" -> Automatic,
  "Limit" -> 10, "MaxIterations" -> 3, "MaxToolCalls" -> 12, "MinGroundedEvidence" -> 2,
  "NoProgressTermination" -> True, "AllowLLMPlanning" -> False, "PlannerFn" -> Automatic,
  "ReadBody" -> False, "Grant" -> None, "ResultView" -> "RankedList", "ContextSubgraphDepth" -> 1,
  "RelationGraph" -> None, "RefLabel" -> None, "RecordEpisode" -> True, "ReturnTrace" -> True,
  "EvidenceScoreMin" -> 0.0, "Actor" -> <|"Kind" -> "Owner", "Ref" -> "sventity:owner:imai"|>};
SourceVaultAgenticSearch[query_String, OptionsPattern[]] := Module[
  {ctx = OptionValue["ReleaseContext"], idx = OptionValue["Index"], lim = OptionValue["Limit"],
   maxIter = OptionValue["MaxIterations"], maxTools = OptionValue["MaxToolCalls"],
   minEv = OptionValue["MinGroundedEvidence"], noProg = TrueQ[OptionValue["NoProgressTermination"]],
   allowLLM = TrueQ[OptionValue["AllowLLMPlanning"]], plannerFn = OptionValue["PlannerFn"],
   rg = OptionValue["RelationGraph"], refLabel = OptionValue["RefLabel"],
   recEp = TrueQ[OptionValue["RecordEpisode"]], evMin = OptionValue["EvidenceScoreMin"],
   complexity, profile, episodeMem, curQuery, tried = {}, trace = {}, iter = 0, toolCalls = 0,
   evidenceById = <||>, ranked = {}, stopped = "MaxIterations", ep, epId = Missing[], view, followTerms, newQuery},
  If[! StringQ[ctx], Return[Failure["ReleaseContextRequired",
    <|"MessageTemplate" -> "SourceVaultAgenticSearch requires \"ReleaseContext\"."|>]]];
  (* 1-3: classify / profile / episode memory recall *)
  complexity = SourceVaultClassifyQueryComplexity[query, "ReleaseContext" -> ctx, "Index" -> idx];
  profile = SourceVaultSelectSearchContextProfile[query];
  episodeMem = Quiet@Check[SourceVaultSearchEpisodeMemory[query], <|"CandidateTerms" -> {}|>];
  If[recEp, ep = SourceVaultStartRetrievalEpisode[<|"Actor" -> OptionValue["Actor"],
     "Inputs" -> {"query:" <> query}|>]; epId = ep["EpisodeId"]];
  curQuery = query;
  While[iter < maxIter && toolCalls < maxTools,
    iter++; AppendTo[tried, curQuery];
    Module[{results, rows, rk, evRefs},
     results = SourceVaultSearch[curQuery, "ReleaseContext" -> ctx, "Index" -> idx, "Limit" -> lim];
     toolCalls++;
     rows = If[Head[results] === Dataset, Normal[results], If[ListQ[results], results, {}]];
     rows = Select[rows, Lookup[#, "ReleaseDecision", "Permit"] === "Permit" && ! TrueQ[Lookup[#, "Revoked", False]] &];
     rk = SourceVaultApplySearchContextProfile[rows, profile];   (* 7: apply context profile *)
     ranked = rk;
     (* evidence 蓄積 (score floor 越え・distinct chunk) *)
     Do[If[Lookup[r, "ContextScore", Lookup[r, "Score", 0.]] >= evMin,
        evidenceById[Lookup[r, "ChunkId", ""]] = r], {r, rk}];
     evRefs = DeleteCases[Keys[evidenceById], ""];
     AppendTo[trace, <|"Iteration" -> iter, "Query" -> curQuery, "Hits" -> Length[rows],
        "EvidenceTotal" -> Length[evRefs], "ToolCalls" -> toolCalls|>];
     If[recEp, SourceVaultRecordSearchAttempt[epId, <|"QueryText" -> curQuery, "SearchMethod" -> "agentic",
        "ResultRefs" -> (Lookup[#, "ChunkId", ""] & /@ rows),
        "IncludedEvidenceRefs" -> (Lookup[#, "ChunkId", ""] & /@ Take[rk, UpTo[minEv]])|>]];
     (* 充足判定 *)
     If[Length[evRefs] >= minEv, stopped = "EnoughEvidence"; Break[]];
     (* 8: follow-up query (deterministic or PlannerFn) *)
     followTerms = If[allowLLM && (plannerFn =!= Automatic),
        Quiet@Check[plannerFn[<|"Query" -> curQuery, "Evidence" -> Values[evidenceById], "Tried" -> tried|>], {}],
        iSVSVFollowUpTerms[<|"Query" -> curQuery|>, Values[evidenceById], episodeMem, rg, refLabel]];
     followTerms = If[ListQ[followTerms], Take[followTerms, UpTo[2]], {}];
     newQuery = If[followTerms === {}, Missing[], curQuery <> " " <> StringRiffle[followTerms, " "]];
     If[MissingQ[newQuery] || MemberQ[tried, newQuery],
        If[noProg, stopped = "NoProgress"; Break[]], curQuery = newQuery]];
  ];
  If[iter >= maxIter && stopped === "MaxIterations", Null];
  If[toolCalls >= maxTools && stopped =!= "EnoughEvidence", stopped = "BudgetExceeded"];
  If[recEp, SourceVaultCloseRetrievalEpisode[epId, DeleteCases[Keys[evidenceById], ""],
     "Outcome" -> If[stopped === "EnoughEvidence", "Succeeded", "Partial"], "Persist" -> True]];
  (* SearchView 構築 (§6.8) *)
  view = Quiet@Check[SourceVaultBuildSearchView[query, "ReleaseContext" -> ctx, "Index" -> idx,
     "Limit" -> lim, "ResultView" -> OptionValue["ResultView"], "RelationGraph" -> rg, "RefLabel" -> refLabel], Missing[]];
  <|"Results" -> ranked, "Views" -> If[AssociationQ[view], {view["ViewRef"]}, {}],
    "AnswerDraft" -> Missing["DeterministicPlanner"],
    "Complexity" -> complexity["Complexity"],
    "Trace" -> If[TrueQ[OptionValue["ReturnTrace"]], <|"Steps" -> trace, "Complexity" -> complexity,
       "Profile" -> Lookup[profile, "ProfileId", "?"], "TriedQueries" -> tried,
       "Iterations" -> iter, "ToolCalls" -> toolCalls|>, Missing[]],
    "Stopped" -> stopped|>];

Options[SourceVaultCascadeSearch] = Options[SourceVaultAgenticSearch];
SourceVaultCascadeSearch[query_String, opts : OptionsPattern[]] := Module[
  {ctx = OptionValue["ReleaseContext"], idx = OptionValue["Index"], cx, rows},
  cx = SourceVaultClassifyQueryComplexity[query, "ReleaseContext" -> ctx, "Index" -> idx];
  If[cx["Complexity"] === "Complex",
    (* Complex -> agentic *)
    SourceVaultAgenticSearch[query, opts],
    (* Simple -> BM25 直接 (agentic loop を回さない) *)
    Module[{results},
     results = SourceVaultSearch[query, "ReleaseContext" -> ctx, "Index" -> idx, "Limit" -> OptionValue["Limit"]];
     rows = If[Head[results] === Dataset, Normal[results], If[ListQ[results], results, {}]];
     <|"Results" -> rows, "Views" -> {}, "AnswerDraft" -> Missing[],
       "Complexity" -> "Simple", "Trace" -> <|"Complexity" -> cx, "Dispatch" -> "BM25"|>,
       "Stopped" -> If[Length[rows] >= OptionValue["MinGroundedEvidence"], "EnoughEvidence", "None"]|>]]];

End[]

EndPackage[]
