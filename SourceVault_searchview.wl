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

End[]

EndPackage[]
