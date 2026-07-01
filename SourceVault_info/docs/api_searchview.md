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
