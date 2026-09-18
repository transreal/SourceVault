(* ::Package:: *)

(* ============================================================
   SourceVault_knowledgegraph.wl -- 発表用知識グラフ (KG) 層

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_knowledgegraph.wl"]]

   仕様書: SlideWorkflow_info/design/slide_knowledge_graph_spec_v0_1.md

   位置づけ:
     論文 1 本 (または複数) の内容と周辺知識を「順序・難易度つきの知識グラフ」として
     保持し、聴き手 (理解度・前提知識) と時間 (枚数・分) を与えると
       I  知識グラフ (Nodes / Edges: 関連度 + 因果/年代/導出/難易度の順序辺)
       II 周辺知識ノードの追加と共有 background 層への連結
       III 最小全域順序木 (複数候補: 右背骨貪欲 = 線形拡張の階層分割)
       IV 階層ごとの概要 + 破綻検証 (順序違反 / 前提欠落 / 循環)
       V  枚数・時間による詰め込み (packing) と枝刈り (pruning)
       VI トポロジカル順のシリアライズ → 言語別アウトライン → シナリオ md
     を決定的に計算する。生成物はスライドではなく KG (スライドは KG の投影)。

   資産の再利用 (oops-ml 由来のグラフ枠組み):
     - 辺レコードは SourceVault_oopsseed.wl の TopicItemGraph と同形
       {From, To, EdgeKind, Weight, EvidenceRefs} (+ Order / OrderKind / Confidence)。
       SourceVaultKGToTopicItemGraph で SourceVaultOOPSTopicGraphPlot にそのまま渡せる。
     - 周辺知識 (background) ノードは bg:<slug> の共有 ID で複数論文から参照される
       (Knowledge Home の svtopic:kh:* と同じ「追記して共有する」考え方)。
     - 過去デッキの再利用は SourceVault_kb.wl (Graph-RAG) の検索で slide 資産を提案する。

   service-loadable 制約:
     FrontEnd / Notebook / NBAccess / UI 依存を持たない。他 SourceVault モジュールは
     DownValues guard 付きの弱結合 (CoreRoot / KB / OOPS plot) のみ。
     単体 Get でも動く ($SourceVaultKGRoot を与えればテスト可能)。
     LLM は呼ばない: プロンプトは純関数で組み立て、応答 JSON は SourceVaultKGFromJSON /
     SourceVaultKGMerge で検証して取り込む (実行はエージェント側の責務)。

   privacy:
     KG / ノードは PrivacyLevel (0.0-1.0, 大きいほど厳格) を持つ。既定 0.0 (公開論文)。
     アウトライン化は "ReleaseCeiling" (既定 0.5) を超えるノードを fail-closed で落とす。
   ============================================================ *)

BeginPackage["SourceVault`"]

$SourceVaultKGRoot::usage = "$SourceVaultKGRoot は知識グラフ層の保存先 (Automatic = SourceVaultCoreRoot[]/knowledgegraph、無ければ LOCALAPPDATA/SourceVault/knowledgegraph)。テストではディレクトリを与えて隔離する。";
$SourceVaultKGEdgeKinds::usage = "$SourceVaultKGEdgeKinds は辺種別の表。<|kind -> <|\"Order\" (From を To より先に提示する順序制約か), \"OrderKind\" (Difficulty|Temporal|Derivation|Narrative|Causal|Hierarchy|None), \"Parent\" (階層化で親候補になる側: From|To|Either|None), \"Affinity\" (親子親和度の係数)|>|>。";
$SourceVaultKGNodeKinds::usage = "$SourceVaultKGNodeKinds はノード種別の一覧 (Claim / Concept / Definition / Method / Experiment / Result / Equation / Figure / Question / Conclusion / Background / Section / Survey)。";
$SourceVaultKGAudiencePresets::usage = "$SourceVaultKGAudiencePresets は聴き手プリセット (\"高校生\" / \"大学理系学部卒\" / \"ITエンジニア\" / \"高校数学III\" など) -> <|\"Level\", \"Knowledge\" -> <|領域 -> 理解度|>|> の表。SourceVaultKGAudience が参照する。";
$SourceVaultKGDomainAliases::usage = "$SourceVaultKGDomainAliases は領域名の別名表 (英語名 -> 正準日本語名)。ノードの Domains と聴き手の Knowledge の照合に使う。";
$SourceVaultKGViewMaxRows::usage = "$SourceVaultKGViewMaxRows は View 関数が Dataset に出す最大行数 (既定 200)。";
$SourceVaultKGTooHard::usage = "$SourceVaultKGTooHard は「聴き手にとって難しすぎる」と判定する need (難易度 - 既知度) の閾値 (既定 0.6)。超えたノードは score を半減し TooHard フラグを付ける。";

SourceVaultKGRoot::usage = "SourceVaultKGRoot[] は知識グラフ層の保存ディレクトリを返す (無ければ作る)。";
SourceVaultKGNew::usage = "SourceVaultKGNew[graphId, opts] は空の知識グラフ連想を返す。opts: \"Title\" / \"Language\" (既定 \"ja\") / \"Sources\" ({<|\"Key\",\"Locator\",\"Kind\",\"Note\"|>..}) / \"Kind\" (Paper|Survey|Background) / \"PrivacyLevel\"。";
SourceVaultKGValidate::usage = "SourceVaultKGValidate[kg] はノード・辺を正規化し (既定値補完・未知の辺種別を RelatedTo に丸める・端点の無い辺や自己ループを落とす・Root を決める)、\"Warnings\" を付けた KG を返す。すべての取り込み口がこれを通る。";
SourceVaultKGFromJSON::usage = "SourceVaultKGFromJSON[json] は LLM 応答 (```json フェンス付き可) や JSON 文字列 / 連想を KG に変換して SourceVaultKGValidate を通す。失敗は Failure。";
SourceVaultKGToJSON::usage = "SourceVaultKGToJSON[kg] は KG を JSON 文字列にする。";
SourceVaultKGMerge::usage = "SourceVaultKGMerge[kg, delta, opts] は差分 KG (ノード/辺の追加・上書き) を取り込む。同じ Id のノードは delta のキーだけ上書き、辺は (From, To, EdgeKind) で重複排除。\"Language\"->\"en\" を与えると delta の文字列テキスト (Label/Summary/Points/Talk) はその言語の訳として既存テキストに併記される。";
SourceVaultKGNode::usage = "SourceVaultKGNode[kg, id] はノード連想 (無ければ Missing)。";
SourceVaultKGText::usage = "SourceVaultKGText[node, key, lang] は言語別テキスト (\"Label\"/\"Summary\"/\"Talk\"/\"Cite\" は String、\"Points\" は List) を返す。lang が無ければ主言語 → 任意の言語の順で落ちる。";
SourceVaultKGSave::usage = "SourceVaultKGSave[kg] は KG を <root>/graphs/<graphId>.json に保存する (前版は graphs/history/ に退避)。";
SourceVaultKGLoad::usage = "SourceVaultKGLoad[graphId] は保存済み KG を読む (無ければ Missing)。";
SourceVaultKGList::usage = "SourceVaultKGList[] は保存済み KG の一覧 ({<|\"GraphId\",\"Title\",\"Kind\",\"NodeCount\",\"EdgeCount\",\"UpdatedAtUTC\"|>..})。";
SourceVaultKGDelete::usage = "SourceVaultKGDelete[graphId] は保存済み KG を削除する (history は残す)。";

SourceVaultKGAudience::usage = "SourceVaultKGAudience[spec] は聴き手指定を正規化する。spec: プリセット名 (\"大学理系学部卒\") / カンマ区切り (\"高校生, 電気化学=0.3, 高校数学III\") / リスト / <|\"Level\", \"Knowledge\", \"Presets\", \"Language\", \"Description\"|>。結果は <|\"Level\" (主題の理解度 0-1), \"Knowledge\" -> <|領域 -> 理解度|>, \"Presets\", \"Language\", \"Description\", \"Unknown\" (解釈できなかった語)|>。";
SourceVaultKGNeed::usage = "SourceVaultKGNeed[kg, audience] は各ノードの need = 難易度 - 聴き手の既知度 (<|id -> Real|>)。0 以下なら既知として扱える。";
SourceVaultKGScores::usage = "SourceVaultKGScores[kg, audience] は各ノードの <|\"Need\", \"Known\", \"Score\" (重要度 x 聴き手にとっての必要度), \"Flags\" (TooHard / Assumed)|>。";

SourceVaultKGOrderGraph::usage = "SourceVaultKGOrderGraph[kg] は順序制約辺 (Order->True の種別 + Contains) だけの有向 Graph と、循環を切るために落とした辺の一覧を <|\"Graph\", \"Dropped\"|> で返す。";
SourceVaultKGLinearOrder::usage = "SourceVaultKGLinearOrder[kg, strategy] は順序制約を満たす線形拡張 (トポロジカル順) を返す。strategy: \"Source\" (論文の出現順優先) / \"Importance\" / \"Difficulty\" (易→難) / \"Coherent\" (直前ノードとの関連度優先)。";
SourceVaultKGOrderedTree::usage = "SourceVaultKGOrderedTree[kg, opts] は最小全域順序木 (線形拡張の階層分割) を返す。<|\"Root\", \"Order\" (前順走査 = 線形拡張), \"Parent\", \"Children\", \"Depth\", \"Score\", \"Strategy\", \"Diagnostics\"|>。opts: \"Strategy\" (既定 \"Source\") / \"MaxDepth\" (既定 3) / \"DepthPenalty\" (既定 0.02)。";
SourceVaultKGOrderedTrees::usage = "SourceVaultKGOrderedTrees[kg, opts] は複数戦略で順序木候補を作り Score 降順で返す。\"Strategies\"->{...}。";
SourceVaultKGLevelSummaries::usage = "SourceVaultKGLevelSummaries[kg, tree, opts] は木の内部ノードごとに概要 (自身の Summary + 子ラベル) を <|id -> <|\"Depth\", \"Label\", \"Summary\", \"Children\"|>|> で返す (決定的)。LLM で磨くには SourceVaultKGSummaryPrompt。";
SourceVaultKGVerify::usage = "SourceVaultKGVerify[kg, tree] は順序木の破綻検証: <|\"Status\" (OK|Warnings|Broken), \"OrderViolations\", \"Cycles\" (落とした辺), \"Orphans\", \"RootMismatch\", \"MissingPrerequisites\"|>。";

SourceVaultKGPlan::usage = "SourceVaultKGPlan[kg, tree, opts] は枚数/時間と聴き手からスライド計画を作る。opts: \"Slides\" (枚数 | Automatic) / \"Seconds\" (総秒数) / \"SecondsPerSlide\" (既定 25) / \"Audience\" / \"MaxPackedPerSlide\" (既定 4) / \"PackRatio\" (既定 0.35) / \"ReleaseCeiling\" (既定 0.5) / \"ForceParts\" (既定 0.5: root 直下の部を必ず 1 枚にする Importance の下限。None で全部)。結果 <|\"Slides\" -> {<|\"NodeId\", \"Packed\", \"Seconds\", \"Flags\"|>..}, \"Pruned\", \"Assumed\", \"Promoted\", \"Threshold\", \"Scores\", \"Diagnostics\"|>。";
SourceVaultKGVerifyPlan::usage = "SourceVaultKGVerifyPlan[kg, plan] は計画の提示順で順序制約が守られているかを検証する (<|\"Status\", \"Violations\"|>)。";
SourceVaultKGOutline::usage = "SourceVaultKGOutline[kg, plan, opts] は計画を言語別のアウトライン (1 枚 = <|NodeId, Title, Points, Sub, Assets, Cite, Talk, Seconds, Flags, Depth, Kind, Crumb, Continuation|>) にする。opts: \"Language\" / \"MaxAssetsPerSlide\" (2) / \"MaxPointsPerSlide\" (6) / \"MaxLinesPerSlide\" (8、折り返しは \"CharsPerLine\" 40 で数える、図は \"FigureLines\" 4 行分) / \"Agenda\" (Automatic: 部が 3 つ以上なら根の直後に「全体の流れ」を 1 枚) / \"Roadmap\" (True: 節スライドの要点をその節の子スライドの題目にする) / \"Crumbs\" (True: 各枚に「第k部 … › 親」のパンくず)。収まらない子は同じ題目 + (続き) のスライドへ。原稿は箇条書きと同じ順 (ノードの Talk を表示した要点数に切り詰め、無ければ要点をそのまま文に)。結果に \"Parts\" と \"Agenda\"。";
SourceVaultKGOutlineToMarkdown::usage = "SourceVaultKGOutlineToMarkdown[outline] は SlideWorkflow のシナリオ Markdown と、<<FIGn>> に対応する資産指定リストを <|\"Markdown\", \"Assets\"|> で返す (資産の実体化は SlideWorkflow 側)。";

SourceVaultKGCompose::usage = "SourceVaultKGCompose[{kg1, kg2, ..}, opts] は複数 KG を 1 つのサーベイ KG に合成する (ノード Id は <graphId>/<id> に、bg: の周辺知識ノードは共有・統合、共有ノードを介した論文間 RelatedTo を付与)。opts: \"GraphId\" / \"Title\" / \"Language\" / \"Chronological\" (Year で Precedes を付ける) / \"Edges\" (追加辺)。";

SourceVaultKGBackgroundLink::usage = "SourceVaultKGBackgroundLink[kg] は Layer Background のノードを共有 background 層 (<root>/background/bg-<slug>.json) と照合し、既存なら BackgroundRef を張り、無ければ新規登録する。<|\"Graph\", \"Linked\", \"Created\"|>。";
SourceVaultKGBackgroundSearch::usage = "SourceVaultKGBackgroundSearch[text, opts] は共有 background ノードをラベル/別名の bigram 類似で検索する ({<|\"Id\",\"Label\",\"Score\",\"Graphs\"|>..})。";
SourceVaultKGBackgroundList::usage = "SourceVaultKGBackgroundList[] は共有 background ノードの一覧。";
SourceVaultKGSuggestPastSlides::usage = "SourceVaultKGSuggestPastSlides[kg, kbId] は SourceVault_kb (Graph-RAG) がロード済みなら、周辺知識ノードごとに過去デッキのスライドを検索して引用候補 ({<|\"NodeId\",\"Label\",\"Deck\",\"Slide\",\"Title\",\"Score\"|>..}) を返す。KB が無ければ {}。";

SourceVaultKGExtractionPrompt::usage = "SourceVaultKGExtractionPrompt[sourceText, opts] は論文本文から KG JSON を抽出させるプロンプト (純関数)。opts: \"GraphId\" / \"Title\" / \"Language\" / \"SourceKey\" / \"PDFKey\" / \"MaxNodes\"。応答は SourceVaultKGFromJSON で取り込む。";
SourceVaultKGBackgroundPrompt::usage = "SourceVaultKGBackgroundPrompt[kg, audience, opts] は聴き手に足りない周辺知識ノードと Prerequisite 辺を差分 JSON で出させるプロンプト。応答は SourceVaultKGMerge で取り込む。";
SourceVaultKGSummaryPrompt::usage = "SourceVaultKGSummaryPrompt[kg, tree, opts] は階層ごとの概要と破綻の指摘を出させるプロンプト。";
SourceVaultKGTalkPrompt::usage = "SourceVaultKGTalkPrompt[outline, opts] はアウトラインの各枚の talk を接続詞つきで磨かせるプロンプト (構成・順序・タイトルは変えない)。";
SourceVaultKGTranslatePrompt::usage = "SourceVaultKGTranslatePrompt[kg, lang, opts] はノード単位の翻訳 JSON を出させるプロンプト。応答は SourceVaultKGMerge[kg, delta, \"Language\"->lang]。";

SourceVaultKGGraph::usage = "SourceVaultKGGraph[kg, opts] は WL の Graph を返す (順序辺は太い矢印、種別で頂点色)。opts: \"Order\" (順序辺だけ) / \"Labels\"。";
SourceVaultKGToTopicItemGraph::usage = "SourceVaultKGToTopicItemGraph[kg] は oopsseed の TopicItemGraph 形 (SourceVaultOOPSTopicGraphPlot に渡せる) に投影する。";
SourceVaultKGView::usage = "SourceVaultKGView[kg] はノード一覧 Dataset (行数は $SourceVaultKGViewMaxRows で制限)。";
SourceVaultKGTreeView::usage = "SourceVaultKGTreeView[kg, tree] は順序木を字下げつきの Dataset で表示する。";
SourceVaultKGVisualize::usage = "SourceVaultKGVisualize[kg, opts] は知識グラフの図 (Graphics) を返す (v1.30)。\"View\" -> \"Story\" (既定: 節を話の順に横へ、節の中身を縦に並べ、周辺知識は下の帯) | \"Sections\" (節の概観: 節を一列に並べ、節をまたぐ辺を弧で) | \"Focus\" (\"Focus\" -> ノード Id の近傍、\"Radius\" -> 1..3) | \"Graph\" (全ノードをばねモデルで)。色 = 種類、大きさ = 重要度、形 = 層 (本文 丸 / 周辺知識 四角 / 関連研究 菱形 / 節 角丸)、赤枠 = 未推敲、右上の点 = 図・表、左上の点 = 質疑応答、薄い = 隠す・枝刈り。ノードと辺にツールチップ。opts: \"EdgeKinds\" (Order / Prerequisite / Support / Related / Contains か辺の種類の名前)、\"Layers\" (All か {\"Paper\", \"Background\", \"Related\"} の部分)、\"Labels\" (Automatic = 節と重要なもの | All | None)、\"Plan\" (SourceVaultKGPlan の結果を重ねる: 枚番号 #n・詰め込み・枝刈り・既知)、\"Selected\" (太枠にする Id)、\"OnClick\" (クリックで f[id] を呼ぶ)、\"Hidden\" (False で隠したノードを描かない)、\"Legend\" (既定 True = 凡例つき)、\"Language\"。";
SourceVaultKGLegend::usage = "SourceVaultKGLegend[lang] は SourceVaultKGVisualize の凡例 (種類の色と形・辺の種類・印)。";
SourceVaultKGPlanView::usage = "SourceVaultKGPlanView[kg, plan] はスライド計画の Dataset (番号 / タイトル / 詰め込み / 秒 / フラグ)。";

Begin["`KGPrivate`"]

If[! ValueQ[SourceVault`$SourceVaultKGRoot], SourceVault`$SourceVaultKGRoot = Automatic];
If[! ValueQ[SourceVault`$SourceVaultKGViewMaxRows], SourceVault`$SourceVaultKGViewMaxRows = 200];
If[! ValueQ[SourceVault`$SourceVaultKGTooHard], SourceVault`$SourceVaultKGTooHard = 0.6];

$kgSchemaVersion = 1;

(* ---------------- 辺・ノード種別 ----------------
   すべての順序辺は「From を To より先に提示する」向きで書く。 *)
SourceVault`$SourceVaultKGEdgeKinds = <|
  "Prerequisite" -> <|"Order" -> True, "OrderKind" -> "Difficulty", "Parent" -> "From", "Affinity" -> 0.5|>,
  "Precedes" -> <|"Order" -> True, "OrderKind" -> "Temporal", "Parent" -> "From", "Affinity" -> 0.4|>,
  "Derives" -> <|"Order" -> True, "OrderKind" -> "Derivation", "Parent" -> "From", "Affinity" -> 0.8|>,
  "Motivates" -> <|"Order" -> True, "OrderKind" -> "Narrative", "Parent" -> "From", "Affinity" -> 0.7|>,
  "LeadsTo" -> <|"Order" -> True, "OrderKind" -> "Causal", "Parent" -> "From", "Affinity" -> 0.6|>,
  "Contains" -> <|"Order" -> True, "OrderKind" -> "Hierarchy", "Parent" -> "From", "Affinity" -> 1.0|>,
  "Supports" -> <|"Order" -> False, "OrderKind" -> None, "Parent" -> "To", "Affinity" -> 0.9|>,
  "Explains" -> <|"Order" -> False, "OrderKind" -> None, "Parent" -> "To", "Affinity" -> 0.9|>,
  "Contrasts" -> <|"Order" -> False, "OrderKind" -> None, "Parent" -> "Either", "Affinity" -> 0.3|>,
  "RelatedTo" -> <|"Order" -> False, "OrderKind" -> None, "Parent" -> "Either", "Affinity" -> 0.3|>,
  "Cites" -> <|"Order" -> False, "OrderKind" -> None, "Parent" -> "Either", "Affinity" -> 0.2|>|>;

SourceVault`$SourceVaultKGNodeKinds = {"Claim", "Concept", "Definition", "Method", "Experiment",
  "Result", "Equation", "Figure", "Question", "Conclusion", "Background", "Section", "Survey",
  "RelatedWork", "Example"};

$kgRootKinds = {"Claim", "Conclusion", "Survey"};
$kgTextKeys = {"Label", "Summary", "Talk", "Cite", "Lead"};
$kgListTextKeys = {"Points", "Details"};

(* ---------------- 保存場所 ---------------- *)

iKGLocalFallbackRoot[] := Module[{base},
  base = Quiet @ Check[Environment["LOCALAPPDATA"], $Failed];
  If[! StringQ[base] || StringLength[base] === 0,
    base = Quiet @ Check[$TemporaryDirectory, "."]];
  FileNameJoin[{base, "SourceVault", "knowledgegraph"}]];

iKGResolveRoot[] := Module[{override, core},
  override = SourceVault`$SourceVaultKGRoot;
  If[StringQ[override] && StringLength[override] > 0, Return[override]];
  core = If[Length[DownValues[SourceVault`SourceVaultCoreRoot]] > 0,
    Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed], $Failed];
  If[StringQ[core] && StringLength[core] > 0,
    FileNameJoin[{core, "knowledgegraph"}],
    iKGLocalFallbackRoot[]]];

iKGEnsureDirectory[dir_String] := (
  If[! DirectoryQ[dir],
    Quiet @ Check[CreateDirectory[dir, CreateIntermediateDirectories -> True], Null]];
  dir);

SourceVaultKGRoot[] := iKGEnsureDirectory[iKGResolveRoot[]];
iKGGraphDir[] := iKGEnsureDirectory[FileNameJoin[{SourceVaultKGRoot[], "graphs"}]];
iKGHistoryDir[] := iKGEnsureDirectory[FileNameJoin[{SourceVaultKGRoot[], "graphs", "history"}]];
iKGBackgroundDir[] := iKGEnsureDirectory[FileNameJoin[{SourceVaultKGRoot[], "background"}]];

iKGUTCNow[] := DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z";

(* ---------------- JSON I/O (SourceVault_slidedeck.wl と同じ単一エンコード) ---------------- *)

iKGJSONSafe[expr_] := expr /. {
  m_Missing :> Null, None -> Null,
  dt_DateObject :> DateString[dt, "ISODateTime"]};

$kgRetryCount = 5;
$kgRetryPause = 0.05;

iKGWriteJSON[path_String, data_] := Module[{ba, dir = DirectoryName[path], tmp, done},
  iKGEnsureDirectory[dir];
  ba = Quiet @ Check[ExportByteArray[iKGJSONSafe[data], "RawJSON"], $Failed];
  If[! ByteArrayQ[ba], Return[$Failed]];
  tmp = path <> ".tmp";
  done = False;
  Do[
    done = TrueQ @ Quiet @ Check[
      Module[{strm = OpenWrite[tmp, BinaryFormat -> True]},
        If[Head[strm] =!= OutputStream, Return[False, Module]];
        WithCleanup[BinaryWrite[strm, ba], Quiet @ Close[strm]];
        RenameFile[tmp, path, OverwriteTarget -> True];
        True],
      False];
    If[done, Break[]];
    Pause[$kgRetryPause],
    {$kgRetryCount}];
  If[done, path, $Failed]];

iKGReadJSON[path_String] := Module[{bytes, parsed},
  If[! FileExistsQ[path], Return[Missing["NoFile"]]];
  Do[
    bytes = Quiet @ Check[ReadByteArray[path], $Failed];
    If[ByteArrayQ[bytes],
      parsed = Quiet @ Check[ImportByteArray[bytes, "RawJSON"], $Failed];
      If[parsed =!= $Failed, Return[parsed, Module]]];
    Pause[$kgRetryPause],
    {$kgRetryCount}];
  If[ByteArrayQ[bytes], Missing["BadJSON"], Missing["Unreadable"]]];

iKGJSONString[data_] := Module[{ba},
  ba = Quiet @ Check[ExportByteArray[iKGJSONSafe[data], "RawJSON"], $Failed];
  If[ByteArrayQ[ba], ByteArrayToString[ba, "UTF-8"], $Failed]];

(* LLM 応答: ```json フェンスや前置きを剥がして最初の { .. 最後の } を取る *)
iKGParseJSONText[s_String] := Module[{t = s, a, b, parsed},
  t = StringReplace[t, {"```json" -> "", "```JSON" -> "", "```" -> ""}];
  a = StringPosition[t, "{", 1];
  b = StringPosition[t, "}"];
  If[a === {} || b === {}, Return[$Failed]];
  t = StringTake[t, {a[[1, 1]], b[[-1, 2]]}];
  parsed = Quiet @ Check[ImportByteArray[StringToByteArray[t, "UTF-8"], "RawJSON"], $Failed];
  If[parsed === $Failed,
    parsed = Quiet @ Check[ImportString[t, "RawJSON"], $Failed]];
  parsed];

(* ---------------- 小さな道具 ---------------- *)

iKGStr[v_] := Which[StringQ[v], v, v === Null || MissingQ[v] || v === None, "", True, ToString[v]];
iKGNum[v_, default_] := If[NumericQ[v], N[v], default];
iKGClip[v_, default_] := If[NumericQ[v], Clip[N[v], {0., 1.}], default];
iKGList[v_] := Which[ListQ[v], v, v === Null || MissingQ[v] || v === None, {}, True, {v}];
iKGStrList[v_] := Select[iKGStr /@ iKGList[v], # =!= "" &];
iKGAssocQ[v_] := AssociationQ[v] || MatchQ[v, {___Rule}];
iKGAssoc[v_] := If[MatchQ[v, {___Rule}], Association[v], v];

iKGNormalizeKey[value_] := Module[{t},
  t = iKGStr[value];
  t = Quiet @ Check[CharacterNormalize[t, "NFKC"], t];
  If[! StringQ[t], t = iKGStr[value]];
  t = ToLowerCase[t];
  StringJoin @ Select[Characters[t], StringMatchQ[#, LetterCharacter | DigitCharacter] &]];

iKGBigrams[s_String] := With[{t = iKGNormalizeKey[s]},
  If[StringLength[t] < 2, {t}, StringPartition[t, 2, 1]]];
iKGBigramSimilarity[a_String, b_String] := Module[{x = iKGBigrams[a], y = iKGBigrams[b], u},
  u = Length[Union[x, y]];
  If[u === 0, 0., N[Length[Intersection[x, y]] / u]]];

iKGSlug[label_String] := With[{k = iKGNormalizeKey[label]},
  If[k === "", "node", StringTake[k, UpTo[48]]]];

(* 言語別テキスト: String | <|lang -> String|> *)
iKGTextValue[v_String, ___] := v;
iKGTextValue[v_Association, lang_String, primary_String] := Module[{r},
  r = Lookup[v, lang, Lookup[v, primary, None]];
  If[! StringQ[r] || r === "",
    r = FirstCase[Values[v], s_String /; s =!= "", ""]];
  r];
iKGTextValue[v_List, ___] := v;
iKGTextValue[_, ___] := "";

iKGListValue[v_List, ___] := iKGStrList[v];
iKGListValue[v_Association, lang_String, primary_String] := Module[{r},
  r = Lookup[v, lang, Lookup[v, primary, None]];
  If[! ListQ[r] || r === {}, r = FirstCase[Values[v], l_List /; l =!= {}, {}]];
  iKGStrList[r]];
iKGListValue[v_String, ___] := If[v === "", {}, {v}];
iKGListValue[_, ___] := {};

iKGHasLanguageQ[v_String, lang_, primary_] := lang === primary;
iKGHasLanguageQ[v_Association, lang_, _] := StringQ[Lookup[v, lang, None]] || ListQ[Lookup[v, lang, None]];
iKGHasLanguageQ[v_List, lang_, primary_] := lang === primary;
iKGHasLanguageQ[___] := True;

(* テキスト連想の正規化: String はそのまま、連想は言語キーの String だけ残す *)
iKGNormText[v_String] := StringTrim[v];
iKGNormText[v_?iKGAssocQ] := Module[{a = iKGAssoc[v]},
  a = KeySelect[Select[a, StringQ], StringQ];
  Which[Length[a] === 0, "", Length[a] === 1, First[a], True, a]];
iKGNormText[v_List] := StringRiffle[iKGStrList[v], " "];
iKGNormText[_] := "";

iKGNormListText[v_List] := iKGStrList[v];
iKGNormListText[v_?iKGAssocQ] := Module[{a = iKGAssoc[v]},
  a = KeySelect[Map[iKGStrList, Select[a, ListQ]], StringQ];
  Which[Length[a] === 0, {}, Length[a] === 1, First[a], True, a]];
iKGNormListText[v_String] := If[StringTrim[v] === "", {}, {v}];
iKGNormListText[_] := {};

SourceVaultKGText[node_Association, key_String, lang_String : "ja"] := Module[
  {primary = iKGStr[Lookup[node, "PrimaryLanguage", "ja"]], v = Lookup[node, key, None]},
  If[primary === "", primary = "ja"];
  If[MemberQ[$kgListTextKeys, key], iKGListValue[v, lang, primary],
    With[{r = iKGTextValue[v, lang, primary]}, If[StringQ[r], r, ""]]]];
SourceVaultKGText[_, _, ___] := "";

(* ---------------- 正規化と検証 ---------------- *)

iKGNormalizeNode[n_?iKGAssocQ, primary_String] := Module[{e = iKGAssoc[n], id, kind, layer},
  id = StringTrim @ iKGStr[Lookup[e, "Id", Lookup[e, "id", ""]]];
  If[id === "", Return[$Failed]];
  e = KeyMap[ToString, e];
  e["Id"] = id;
  kind = iKGStr[Lookup[e, "Kind", "Concept"]];
  If[! MemberQ[SourceVault`$SourceVaultKGNodeKinds, kind], kind = "Concept"];
  e["Kind"] = kind;
  Do[e[k] = iKGNormText[Lookup[e, k, ""]], {k, $kgTextKeys}];
  Do[e[k] = iKGNormListText[Lookup[e, k, {}]], {k, $kgListTextKeys}];
  If[e["Label"] === "", e["Label"] = id];
  e["Difficulty"] = iKGClip[Lookup[e, "Difficulty", 0.5], 0.5];
  e["Importance"] = iKGClip[Lookup[e, "Importance", 0.5], 0.5];
  e["Domains"] = iKGStrList[Lookup[e, "Domains", {}]];
  e["Aliases"] = iKGStrList[Lookup[e, "Aliases", {}]];
  e["Year"] = With[{y = Lookup[e, "Year", None]}, If[IntegerQ[y], y, None]];
  e["Order"] = With[{o = Lookup[e, "Order", None]}, If[NumericQ[o], o, None]];
  layer = iKGStr[Lookup[e, "Layer", ""]];
  If[! MemberQ[{"Paper", "Background", "Shared"}, layer],
    layer = If[kind === "Background", "Background", "Paper"]];
  e["Layer"] = layer;
  e["Assets"] = Select[iKGAssoc /@ Select[iKGList[Lookup[e, "Assets", {}]], iKGAssocQ],
    StringQ[Lookup[#, "Type", None]] &];
  e["PrivacyLevel"] = iKGClip[Lookup[e, "PrivacyLevel", 0.], 0.];
  e["PrimaryLanguage"] = primary;
  e["Source"] = With[{s = Lookup[e, "Source", <||>]}, If[iKGAssocQ[s], iKGAssoc[s], <||>]];
  e["BackgroundRef"] = With[{b = Lookup[e, "BackgroundRef", None]}, If[StringQ[b] && b =!= "", b, None]];
  e];
iKGNormalizeNode[___] := $Failed;

(* 検証中の警告は動的スコープの $kgWarn に集める (引数の参照渡しは WL では評価済みの値になる) *)
$kgWarn = {};

iKGNormalizeEdge[ed_?iKGAssocQ] := Module[{e = iKGAssoc[ed], kind, spec},
  e = KeyMap[ToString, e];
  e["From"] = StringTrim @ iKGStr[Lookup[e, "From", Lookup[e, "from", ""]]];
  e["To"] = StringTrim @ iKGStr[Lookup[e, "To", Lookup[e, "to", ""]]];
  If[e["From"] === "" || e["To"] === "", Return[$Failed]];
  kind = iKGStr[Lookup[e, "EdgeKind", Lookup[e, "Kind", Lookup[e, "Relation", "RelatedTo"]]]];
  If[! KeyExistsQ[SourceVault`$SourceVaultKGEdgeKinds, kind],
    AppendTo[$kgWarn, "UnknownEdgeKind: " <> kind <> " -> RelatedTo"];
    kind = "RelatedTo"];
  spec = SourceVault`$SourceVaultKGEdgeKinds[kind];
  e["EdgeKind"] = kind;
  e["Weight"] = iKGClip[Lookup[e, "Weight", 0.5], 0.5];
  e["Confidence"] = iKGClip[Lookup[e, "Confidence", 0.7], 0.7];
  e["Order"] = With[{o = Lookup[e, "Order", Automatic]},
    If[BooleanQ[o], o, TrueQ[spec["Order"]]]];
  e["OrderKind"] = With[{k = Lookup[e, "OrderKind", None]},
    If[StringQ[k] && k =!= "", k, spec["OrderKind"]]];
  e["EvidenceRefs"] = iKGStrList[Lookup[e, "EvidenceRefs", {}]];
  KeyTake[e, {"From", "To", "EdgeKind", "Weight", "Confidence", "Order", "OrderKind", "EvidenceRefs"}]];
iKGNormalizeEdge[___] := $Failed;

iKGPickRoot[nodes_List, explicit_] := Module[{ids = Lookup[nodes, "Id"], cand},
  If[StringQ[explicit] && MemberQ[ids, explicit], Return[explicit]];
  cand = Select[nodes, MemberQ[$kgRootKinds, #["Kind"]] &];
  If[cand === {}, cand = nodes];
  If[cand === {}, None, First[MaximalBy[cand, #["Importance"] &]]["Id"]]];

Options[SourceVaultKGNew] = {"Title" -> "", "Language" -> "ja", "Sources" -> {},
  "Kind" -> "Paper", "PrivacyLevel" -> 0.};
SourceVaultKGNew[graphId_String, OptionsPattern[]] := <|
  "ObjectClass" -> "SourceVaultKnowledgeGraph", "SchemaVersion" -> $kgSchemaVersion,
  "GraphId" -> graphId, "Title" -> iKGStr[OptionValue["Title"]],
  "Kind" -> iKGStr[OptionValue["Kind"]], "Language" -> iKGStr[OptionValue["Language"]],
  "Sources" -> Select[iKGAssoc /@ Select[iKGList[OptionValue["Sources"]], iKGAssocQ], AssociationQ],
  "PrivacyLevel" -> iKGClip[OptionValue["PrivacyLevel"], 0.],
  "Nodes" -> {}, "Edges" -> {}, "Root" -> None, "Warnings" -> {},
  "UpdatedAtUTC" -> iKGUTCNow[]|>;

SourceVaultKGValidate[kgIn_?iKGAssocQ] := Block[{$kgWarn = {}}, iKGValidate[kgIn]];

iKGValidate[kgIn_] := Module[
  {kg = KeyMap[ToString, iKGAssoc[kgIn]], primary, nodes, ids, seen, edges, warnings = {}, root},
  primary = iKGStr[Lookup[kg, "Language", "ja"]];
  If[primary === "", primary = "ja"];
  kg["Language"] = primary;
  kg["ObjectClass"] = "SourceVaultKnowledgeGraph";
  kg["SchemaVersion"] = $kgSchemaVersion;
  kg["GraphId"] = With[{g = iKGStr[Lookup[kg, "GraphId", Lookup[kg, "graphId", ""]]]},
    If[g === "", "kg-" <> StringTake[CreateUUID[], 8], g]];
  kg["Title"] = iKGStr[Lookup[kg, "Title", ""]];
  kg["Kind"] = With[{k = iKGStr[Lookup[kg, "Kind", "Paper"]]},
    If[MemberQ[{"Paper", "Survey", "Background", "Scenario"}, k], k, "Paper"]];
  kg["PrivacyLevel"] = iKGClip[Lookup[kg, "PrivacyLevel", 0.], 0.];
  kg["Sources"] = Select[iKGAssoc /@ Select[iKGList[Lookup[kg, "Sources", {}]], iKGAssocQ], AssociationQ];
  nodes = DeleteCases[iKGNormalizeNode[#, primary] & /@ iKGList[Lookup[kg, "Nodes", {}]], $Failed];
  (* 同じ Id は先勝ち *)
  seen = <||>;
  nodes = Select[nodes, Function[n,
    If[KeyExistsQ[seen, n["Id"]],
      AppendTo[warnings, "DuplicateNode: " <> n["Id"]]; False,
      seen[n["Id"]] = True; True]]];
  ids = Lookup[nodes, "Id", {}];
  edges = DeleteCases[iKGNormalizeEdge /@ iKGList[Lookup[kg, "Edges", {}]], $Failed];
  warnings = Join[warnings, $kgWarn];
  edges = Select[edges, Function[e,
    Which[
      e["From"] === e["To"], AppendTo[warnings, "SelfLoop: " <> e["From"]]; False,
      ! MemberQ[ids, e["From"]] || ! MemberQ[ids, e["To"]],
        AppendTo[warnings, "DanglingEdge: " <> e["From"] <> " -> " <> e["To"]]; False,
      True, True]]];
  edges = DeleteDuplicatesBy[edges, {#["From"], #["To"], #["EdgeKind"]} &];
  root = iKGPickRoot[nodes, Lookup[kg, "Root", None]];
  kg["Nodes"] = nodes;
  kg["Edges"] = edges;
  kg["Root"] = root;
  kg["Warnings"] = warnings;
  kg["UpdatedAtUTC"] = iKGUTCNow[];
  kg];
SourceVaultKGValidate[_] := Failure["NotAGraph", <|"MessageTemplate" -> "expected an Association"|>];

SourceVaultKGFromJSON[s_String] := Module[{parsed = iKGParseJSONText[s]},
  If[! iKGAssocQ[parsed],
    Return[Failure["BadJSON", <|"MessageTemplate" -> "could not parse a JSON object from the text"|>]]];
  SourceVaultKGFromJSON[parsed]];
SourceVaultKGFromJSON[a_?iKGAssocQ] := Module[{kg = SourceVaultKGValidate[a]},
  If[! AssociationQ[kg], Return[kg]];
  If[kg["Nodes"] === {},
    Return[Failure["NoNodes", <|"MessageTemplate" -> "the graph has no nodes"|>]]];
  kg];
SourceVaultKGFromJSON[_] := Failure["BadJSON", <|"MessageTemplate" -> "expected JSON text or an Association"|>];

SourceVaultKGToJSON[kg_Association] := iKGJSONString[kg];

SourceVaultKGNode[kg_Association, id_String] :=
  FirstCase[Lookup[kg, "Nodes", {}], n_Association /; n["Id"] === id, Missing["NoNode", id]];

iKGNodeIndex[kg_Association] := AssociationMap[SourceVaultKGNode[kg, #] &, Lookup[Lookup[kg, "Nodes", {}], "Id", {}]];
iKGNodeIndex[kg_Association] := Association[(#["Id"] -> #) & /@ Lookup[kg, "Nodes", {}]];

(* ---------------- 差分取り込み ---------------- *)

iKGMergeText[old_, new_String, lang_String, primary_String] := Which[
  new === "", old,
  lang === primary && (old === "" || StringQ[old]), new,
  StringQ[old] && old === "", <|lang -> new|>,
  StringQ[old], <|primary -> old, lang -> new|>,
  AssociationQ[old], Append[old, lang -> new],
  True, new];
iKGMergeText[old_, new_Association, ___] := Which[
  StringQ[old] && old =!= "", Join[<|"ja" -> old|>, new],
  AssociationQ[old], Join[old, new],
  True, new];
iKGMergeText[old_, _, ___] := old;

iKGMergeListText[old_, new_List, lang_String, primary_String] := Which[
  new === {}, old,
  lang === primary && (old === {} || ListQ[old]), new,
  ListQ[old] && old === {}, <|lang -> new|>,
  ListQ[old], <|primary -> old, lang -> new|>,
  AssociationQ[old], Append[old, lang -> new],
  True, new];
iKGMergeListText[old_, new_Association, ___] := If[AssociationQ[old], Join[old, new], new];
iKGMergeListText[old_, _, ___] := old;

Options[SourceVaultKGMerge] = {"Language" -> Automatic};
SourceVaultKGMerge[kg_Association, deltaIn_, OptionsPattern[]] := Module[
  {delta, primary = iKGStr[Lookup[kg, "Language", "ja"]], lang, index, newNodes, e2, nodes, edges, res},
  delta = Which[StringQ[deltaIn], iKGParseJSONText[deltaIn], iKGAssocQ[deltaIn], iKGAssoc[deltaIn], True, $Failed];
  If[! iKGAssocQ[delta], Return[Failure["BadDelta", <|"MessageTemplate" -> "delta must be JSON text or an Association"|>]]];
  delta = KeyMap[ToString, delta];
  lang = Replace[OptionValue["Language"], Automatic -> primary];
  index = iKGNodeIndex[kg];
  newNodes = Select[iKGAssoc /@ Select[iKGList[Lookup[delta, "Nodes", {}]], iKGAssocQ], AssociationQ];
  Do[
    Module[{id = StringTrim @ iKGStr[Lookup[n, "Id", Lookup[n, "id", ""]]], old, m},
      If[id === "", Continue[]];
      m = KeyMap[ToString, n];
      If[KeyExistsQ[index, id],
        old = index[id];
        Do[If[KeyExistsQ[m, k],
          old[k] = iKGMergeText[Lookup[old, k, ""], iKGNormText[m[k]], lang, primary]],
          {k, $kgTextKeys}];
        Do[If[KeyExistsQ[m, k],
          old[k] = iKGMergeListText[Lookup[old, k, {}], iKGNormListText[m[k]], lang, primary]],
          {k, $kgListTextKeys}];
        Do[If[KeyExistsQ[m, k], old[k] = m[k]],
          {k, Complement[Keys[m], Join[$kgTextKeys, $kgListTextKeys, {"Id", "id"}]]}];
        If[KeyExistsQ[m, "Aliases"], old["Aliases"] = Union[iKGStrList[Lookup[old, "Aliases", {}]], iKGStrList[m["Aliases"]]]];
        If[KeyExistsQ[m, "Domains"], old["Domains"] = Union[iKGStrList[Lookup[old, "Domains", {}]], iKGStrList[m["Domains"]]]];
        index[id] = old,
        (* 新規ノード: 主言語でない訳だけを持たせない (ラベルは必要) *)
        If[lang =!= primary,
          Do[If[KeyExistsQ[m, k] && StringQ[m[k]], m[k] = <|lang -> m[k]|>], {k, $kgTextKeys}];
          Do[If[KeyExistsQ[m, k] && ListQ[m[k]], m[k] = <|lang -> m[k]|>], {k, $kgListTextKeys}]];
        m["Id"] = id;
        index[id] = m]],
    {n, newNodes}];
  (* "Remove": ノードを落とし、そのノードに触れる辺も落とす (推敲で段落を統合するとき) *)
  Do[KeyDropFrom[index, r], {r, iKGStrList[Lookup[delta, "Remove", {}]]}];
  nodes = Values[index];
  e2 = Select[iKGAssoc /@ Select[iKGList[Lookup[delta, "Edges", {}]], iKGAssocQ], AssociationQ];
  edges = Select[Join[Lookup[kg, "Edges", {}], e2],
    KeyExistsQ[index, iKGStr[Lookup[#, "From", ""]]] && KeyExistsQ[index, iKGStr[Lookup[#, "To", ""]]] &];
  (* 推敲や周辺知識を回すたびに同じ辺が積み重なる (実測: 同じ向きの辺が 2 本ずつ)。種類ごとに 1 本、後のものを残す *)
  edges = Reverse[DeleteDuplicatesBy[Reverse[edges],
    {iKGStr[Lookup[#, "From", ""]], iKGStr[Lookup[#, "To", ""]], iKGStr[Lookup[#, "EdgeKind", ""]]} &]];
  res = SourceVaultKGValidate[Join[kg, <|"Nodes" -> nodes, "Edges" -> edges,
    "Root" -> Lookup[delta, "Root", Lookup[kg, "Root", None]]|>]];
  If[AssociationQ[res],
    res["Warnings"] = Join[Lookup[kg, "Warnings", {}], Lookup[res, "Warnings", {}]] // DeleteDuplicates];
  res];

(* ---------------- 保存 / 読込 ---------------- *)

iKGGraphFile[graphId_String] := FileNameJoin[{iKGGraphDir[], iKGSlug[graphId] <> ".json"}];

SourceVaultKGSave[kg_Association] := Module[{path, prev, hist},
  If[! StringQ[Lookup[kg, "GraphId", None]], Return[$Failed]];
  path = iKGGraphFile[kg["GraphId"]];
  If[FileExistsQ[path],
    prev = Quiet @ Check[ReadByteArray[path], $Failed];
    If[ByteArrayQ[prev],
      hist = FileNameJoin[{iKGHistoryDir[],
        iKGSlug[kg["GraphId"]] <> "-" <> StringReplace[iKGUTCNow[], {":" -> "", "-" -> ""}] <> ".json"}];
      Quiet @ Check[
        Module[{strm = OpenWrite[hist, BinaryFormat -> True]},
          WithCleanup[BinaryWrite[strm, prev], Quiet @ Close[strm]]], Null]]];
  iKGWriteJSON[path, Append[kg, "UpdatedAtUTC" -> iKGUTCNow[]]]];

SourceVaultKGLoad[graphId_String] := Module[{d = iKGReadJSON[iKGGraphFile[graphId]]},
  If[MissingQ[d], d, SourceVaultKGValidate[d]]];

SourceVaultKGList[] := Module[{files},
  files = Quiet @ Check[FileNames["*.json", iKGGraphDir[]], {}];
  Select[Map[Function[f, With[{d = iKGReadJSON[f]},
    If[! AssociationQ[d], Nothing,
      <|"GraphId" -> iKGStr[Lookup[d, "GraphId", ""]], "Title" -> iKGStr[Lookup[d, "Title", ""]],
        "Kind" -> iKGStr[Lookup[d, "Kind", ""]],
        "NodeCount" -> Length[iKGList[Lookup[d, "Nodes", {}]]],
        "EdgeCount" -> Length[iKGList[Lookup[d, "Edges", {}]]],
        "UpdatedAtUTC" -> iKGStr[Lookup[d, "UpdatedAtUTC", ""]], "File" -> f|>]]], files], AssociationQ]];

SourceVaultKGDelete[graphId_String] := With[{p = iKGGraphFile[graphId]},
  If[FileExistsQ[p], Quiet @ Check[DeleteFile[p]; True, False], False]];

(* ---------------- 聴き手モデル ---------------- *)

SourceVault`$SourceVaultKGDomainAliases = <|
  "electrochemistry" -> "電気化学", "hydrogel" -> "ハイドロゲル", "hydrogels" -> "ハイドロゲル",
  "polymer" -> "高分子", "polymers" -> "高分子", "materials" -> "材料科学", "materials science" -> "材料科学",
  "machine learning" -> "機械学習", "reinforcement learning" -> "強化学習", "deep learning" -> "深層学習",
  "neural network" -> "ニューラルネット", "neural networks" -> "ニューラルネット",
  "calculus" -> "微積分", "linear algebra" -> "線形代数", "differential equations" -> "微分方程式",
  "statistics" -> "統計", "probability" -> "確率", "mathematics" -> "数学", "math" -> "数学",
  "physics" -> "物理", "chemistry" -> "化学", "biology" -> "生物学", "neuroscience" -> "神経科学",
  "thermodynamics" -> "熱力学", "electromagnetism" -> "電磁気学", "general relativity" -> "一般相対論",
  "computer science" -> "計算機科学", "programming" -> "プログラミング", "network" -> "ネットワーク",
  "networking" -> "ネットワーク", "control theory" -> "制御", "control" -> "制御",
  "cellular automata" -> "セルオートマトン", "cellular automaton" -> "セルオートマトン",
  "complex systems" -> "複雑系", "emergence" -> "創発", "unconventional computing" -> "非従来型計算",
  "reservoir computing" -> "リザバー計算", "game theory" -> "ゲーム理論", "optics" -> "光学",
  "high school math" -> "高校数学", "high school physics" -> "高校物理", "high school chemistry" -> "高校化学"|>;

SourceVault`$SourceVaultKGAudiencePresets = <|
  "一般" -> <|"Level" -> 0.2, "Knowledge" -> <||>|>,
  "小学生" -> <|"Level" -> 0.05, "Knowledge" -> <|"算数" -> 0.3|>|>,
  "中学生" -> <|"Level" -> 0.15, "Knowledge" -> <|"数学" -> 0.2, "理科" -> 0.2|>|>,
  "高校生" -> <|"Level" -> 0.3, "Knowledge" -> <|"高校数学" -> 0.5, "高校物理" -> 0.4, "高校化学" -> 0.4, "数学" -> 0.35, "物理" -> 0.3, "化学" -> 0.3|>|>,
  "大学理系学部卒" -> <|"Level" -> 0.5, "Knowledge" -> <|"数学" -> 0.6, "微積分" -> 0.7, "線形代数" -> 0.6, "物理" -> 0.6, "化学" -> 0.55, "プログラミング" -> 0.5, "統計" -> 0.5|>|>,
  "大学文系学部卒" -> <|"Level" -> 0.35, "Knowledge" -> <|"数学" -> 0.3, "統計" -> 0.3|>|>,
  "大学院生" -> <|"Level" -> 0.65, "Knowledge" -> <|"数学" -> 0.7, "物理" -> 0.65, "プログラミング" -> 0.6|>|>,
  "研究者" -> <|"Level" -> 0.85, "Knowledge" -> <|"数学" -> 0.8, "物理" -> 0.75|>|>,
  "同分野の研究者" -> <|"Level" -> 0.95, "Knowledge" -> <||>|>,
  "ITエンジニア" -> <|"Level" -> 0.45, "Knowledge" -> <|"プログラミング" -> 0.9, "計算機科学" -> 0.7, "ネットワーク" -> 0.7, "機械学習" -> 0.5, "数学" -> 0.5|>|>,
  "ネットワークエンジニア" -> <|"Level" -> 0.45, "Knowledge" -> <|"ネットワーク" -> 0.95, "プログラミング" -> 0.6, "計算機科学" -> 0.6|>|>,
  "基本情報技術者" -> <|"Level" -> 0.4, "Knowledge" -> <|"計算機科学" -> 0.6, "プログラミング" -> 0.6, "ネットワーク" -> 0.5, "数学" -> 0.4|>|>,
  "高校数学III" -> <|"Level" -> 0., "Knowledge" -> <|"高校数学" -> 0.9, "微積分" -> 0.75, "数学" -> 0.6|>|>,
  "一般相対論" -> <|"Level" -> 0., "Knowledge" -> <|"一般相対論" -> 0.8, "微分幾何" -> 0.6, "物理" -> 0.75, "数学" -> 0.7|>|>,
  "電気化学" -> <|"Level" -> 0., "Knowledge" -> <|"電気化学" -> 0.8, "化学" -> 0.7|>|>,
  "機械学習" -> <|"Level" -> 0., "Knowledge" -> <|"機械学習" -> 0.8, "統計" -> 0.6, "プログラミング" -> 0.7|>|>,
  (* English aliases of the presets above *)
  "general public" -> <|"Level" -> 0.2, "Knowledge" -> <||>|>,
  "high school" -> <|"Level" -> 0.3, "Knowledge" -> <|"高校数学" -> 0.5, "高校物理" -> 0.4, "高校化学" -> 0.4, "数学" -> 0.35, "物理" -> 0.3, "化学" -> 0.3|>|>,
  "undergraduate" -> <|"Level" -> 0.5, "Knowledge" -> <|"数学" -> 0.6, "微積分" -> 0.7, "線形代数" -> 0.6, "物理" -> 0.6, "化学" -> 0.55, "プログラミング" -> 0.5, "統計" -> 0.5|>|>,
  "graduate" -> <|"Level" -> 0.65, "Knowledge" -> <|"数学" -> 0.7, "物理" -> 0.65, "プログラミング" -> 0.6|>|>,
  "researcher" -> <|"Level" -> 0.85, "Knowledge" -> <|"数学" -> 0.8, "物理" -> 0.75|>|>,
  "software engineer" -> <|"Level" -> 0.45, "Knowledge" -> <|"プログラミング" -> 0.9, "計算機科学" -> 0.7, "ネットワーク" -> 0.7, "機械学習" -> 0.5, "数学" -> 0.5|>|>,
  "network engineer" -> <|"Level" -> 0.45, "Knowledge" -> <|"ネットワーク" -> 0.95, "プログラミング" -> 0.6, "計算機科学" -> 0.6|>|>|>;

(* 領域名の正規化は結果を覚えておく。聴き手の必要度 (SourceVaultKGScores) はノード × 領域 × 聴き手の知識の
   組ごとに別名辞書の全キーを正規化し直しており、166 ノードの KG で計画 1 回に約 6 秒かかっていた
   (「生成」を押してから十数秒なにも出ない主因)。別名辞書は中身のハッシュで索引を作り直す *)
$kgNormKeyCache = <||>;
iKGNormKeyCached[s_String] := If[KeyExistsQ[$kgNormKeyCache, s], $kgNormKeyCache[s],
  If[Length[$kgNormKeyCache] > 20000, $kgNormKeyCache = <||>];
  $kgNormKeyCache[s] = iKGNormalizeKey[s]];
$kgAliasIndex = <|"Hash" -> None, "Index" -> <||>|>;
iKGAliasIndex[] := With[{al = SourceVault`$SourceVaultKGDomainAliases},
  With[{h = Hash[al]},
    If[$kgAliasIndex["Hash"] =!= h,
      (* 同じ正規形のキーが複数あれば先に書かれたものが勝つ (旧実装の SelectFirst と同じ) *)
      $kgAliasIndex = <|"Hash" -> h, "Index" -> If[AssociationQ[al],
        Association[Map[iKGNormKeyCached[#] -> al[#] &, Reverse[Select[Keys[al], StringQ]]]], <||>]|>];
    $kgAliasIndex["Index"]]];
iKGCanonicalDomain[d_String] := Lookup[iKGAliasIndex[], iKGNormKeyCached[d], StringTrim[d]];

iKGDomainMatchQ[nodeDomain_String, audienceDomain_String] := Module[
  {a = iKGNormKeyCached[iKGCanonicalDomain[nodeDomain]], b = iKGNormKeyCached[iKGCanonicalDomain[audienceDomain]]},
  a =!= "" && b =!= "" && (a === b || StringContainsQ[a, b] || StringContainsQ[b, a])];

(* 関数型: 更新した聴き手連想を返す (引数の書き換えは WL では効かない) *)
iKGAudienceKnow[aud_Association, domain_String, level_] :=
  Module[{a = aud}, a["Knowledge"][domain] = Max[Lookup[a["Knowledge"], domain, 0.], level]; a];

iKGAudienceToken[aud_Association, tok_String] := Module[{t = StringTrim[tok], m, preset, a = aud},
  If[t === "", Return[a]];
  m = StringCases[t, StartOfString ~~ name__ ~~ ("=" | ":" | "＝") ~~ v__ ~~ EndOfString :>
    {StringTrim[name], Quiet @ Check[ToExpression[StringTrim[v]], $Failed]}, 1];
  If[m =!= {} && NumericQ[m[[1, 2]]],
    a["Knowledge"][iKGCanonicalDomain[m[[1, 1]]]] = Clip[N[m[[1, 2]]], {0., 1.}];
    Return[a]];
  preset = SelectFirst[Keys[SourceVault`$SourceVaultKGAudiencePresets], iKGNormalizeKey[#] === iKGNormalizeKey[t] &, None];
  If[preset =!= None,
    With[{p = SourceVault`$SourceVaultKGAudiencePresets[preset]},
      a["Presets"] = Append[a["Presets"], preset];
      a["Level"] = Max[a["Level"], p["Level"]];
      Do[a = iKGAudienceKnow[a, k, p["Knowledge"][k]], {k, Keys[p["Knowledge"]]}]];
    Return[a]];
  (* 未知の語は「その領域は知っている (0.7)」として扱い、Unknown にも記録する *)
  a = iKGAudienceKnow[a, iKGCanonicalDomain[t], 0.7];
  a["Unknown"] = Append[a["Unknown"], t];
  a];

iKGAudienceTokens[aud_Association, toks_List] := Fold[iKGAudienceToken[#1, iKGStr[#2]] &, aud, toks];

SourceVaultKGAudience[spec_] := Module[{aud, tokens, a, k},
  aud = <|"Level" -> 0., "Knowledge" -> <||>, "Presets" -> {}, "Language" -> "ja",
    "Description" -> "", "Unknown" -> {}|>;
  Which[
    spec === Automatic || spec === None || spec === Null, aud = iKGAudienceToken[aud, "一般"],
    StringQ[spec], tokens = StringSplit[spec, {",", "、", ";", "\n"}];
      aud = If[tokens === {}, iKGAudienceToken[aud, "一般"], iKGAudienceTokens[aud, tokens]],
    ListQ[spec], Do[Which[StringQ[x], aud = iKGAudienceToken[aud, x],
        MatchQ[x, _Rule], aud["Knowledge"][iKGCanonicalDomain[iKGStr[First[x]]]] = iKGClip[Last[x], 0.7],
        True, Null], {x, spec}],
    iKGAssocQ[spec], a = KeyMap[ToString, iKGAssoc[spec]];
      aud = iKGAudienceTokens[aud, iKGStrList[Lookup[a, "Presets", {}]]];
      If[NumericQ[Lookup[a, "Level", None]], aud["Level"] = iKGClip[a["Level"], aud["Level"]]];
      k = Lookup[a, "Knowledge", <||>];
      If[iKGAssocQ[k], Do[aud["Knowledge"][iKGCanonicalDomain[iKGStr[d]]] = iKGClip[iKGAssoc[k][d], 0.5], {d, Keys[iKGAssoc[k]]}]];
      If[ListQ[k], aud = iKGAudienceTokens[aud, k]];
      If[StringQ[Lookup[a, "Language", None]], aud["Language"] = a["Language"]];
      If[StringQ[Lookup[a, "Description", None]], aud["Description"] = a["Description"]];
      If[StringQ[Lookup[a, "Audience", None]], aud = iKGAudienceTokens[aud, StringSplit[a["Audience"], {",", "、"}]]],
    True, aud = iKGAudienceToken[aud, "一般"]];
  If[aud["Presets"] === {} && aud["Knowledge"] === <||>, aud = iKGAudienceToken[aud, "一般"]];
  aud];

iKGKnown[node_Association, aud_Association] := Module[{doms = Lookup[node, "Domains", {}], hits},
  hits = Flatten[Map[Function[d,
    Select[Keys[aud["Knowledge"]], iKGDomainMatchQ[d, #] &] /. k_String :> aud["Knowledge"][k]], doms]];
  hits = Select[hits, NumericQ];
  If[hits === {}, aud["Level"], Max[Append[hits, aud["Level"]]]]];

SourceVaultKGNeed[kg_Association, audSpec_] := Module[{aud = SourceVaultKGAudience[audSpec]},
  Association[(#["Id"] -> N[#["Difficulty"] - iKGKnown[#, aud]]) & /@ Lookup[kg, "Nodes", {}]]];

SourceVaultKGScores[kg_Association, audSpec_] := Module[{aud = SourceVaultKGAudience[audSpec], too = SourceVault`$SourceVaultKGTooHard},
  Association[Map[Function[n,
    Module[{known = iKGKnown[n, aud], need, rel, score, flags = {}},
      need = N[n["Difficulty"] - known];
      rel = If[n["Layer"] === "Paper", 1., Clip[need, {0., 1.}]];
      If[n["Layer"] =!= "Paper" && need <= 0., AppendTo[flags, "Assumed"]];
      score = n["Importance"] * rel;
      If[need > too, AppendTo[flags, "TooHard"]; score *= 0.5];
      n["Id"] -> <|"Need" -> need, "Known" -> known, "Score" -> score, "Flags" -> flags|>]],
    Lookup[kg, "Nodes", {}]]]];

(* ---------------- 順序グラフと線形拡張 ---------------- *)

iKGEdgeStrength[e_Association] := e["Weight"] * e["Confidence"];

(* 閉路を 1 つ見つける (FindCycle が使えないときの代わり): 強連結成分の中を辺に沿って歩けば
   必ず同じ頂点に戻る。自己ループはそれ自体が閉路 *)
iKGCycleBySCC[g_Graph] := Module[{loops, sccs, scc, adj, path, nx, p},
  loops = Select[EdgeList[g], #[[1]] === #[[2]] &];
  If[loops =!= {}, Return[{{First[loops]}}]];
  sccs = Select[ConnectedComponents[g], Length[#] > 1 &];
  If[sccs === {}, Return[{}]];
  scc = First[sccs];
  adj = GroupBy[Select[EdgeList[g], MemberQ[scc, #[[1]]] && MemberQ[scc, #[[2]]] &], First -> Last];
  path = {First[scc]};
  Do[
    nx = First[Lookup[adj, Last[path], {None}]];
    If[nx === None, Return[{}, Module]];
    If[MemberQ[path, nx],
      p = First[FirstPosition[path, nx]];
      Return[{DirectedEdge @@@ Partition[Append[path[[p ;;]], nx], 2, 1]}, Module]];
    AppendTo[path, nx],
    {Length[scc] + 1}];
  {}];

SourceVaultKGOrderGraph[kg_Association] := Module[
  {ids = Lookup[Lookup[kg, "Nodes", {}], "Id", {}], oedges, g, dropped = {}, cyc, worst, k = 0, pw, build},
  oedges = Select[Lookup[kg, "Edges", {}], TrueQ[#["Order"]] &];
  (* 同じ向きの辺が複数ある (Contains と LeadsTo が並ぶ等) と重みつき多重グラフになり、FindCycle が
     評価されずに返る (15.0 実測)。すると閉路が切れないまま線形拡張が止まり、論文本体が丸ごと
     順序木から落ちた (計算と自然33: 166 ノード中 89 が孤立し、45 枚の指定で 23 枚しか出なかった)。
     グラフは (From, To) ごとに 1 本、重みはその最大で組む *)
  pw[es_] := GroupBy[es, {#["From"], #["To"]} &, Max[iKGEdgeStrength /@ #] &];
  build[es_] := With[{w = pw[es]}, Graph[ids, DirectedEdge @@@ Keys[w], EdgeWeight -> Values[w]]];
  g = build[oedges];
  While[! AcyclicGraphQ[g] && k < Length[oedges],
    k++;
    cyc = Quiet @ Check[FindCycle[g, Infinity, 1], {}];
    If[! MatchQ[cyc, {{__DirectedEdge}, ___}], cyc = iKGCycleBySCC[g]];
    If[cyc === {}, Break[]];
    cyc = First[cyc];
    With[{w = pw[oedges]},
      worst = First[MinimalBy[cyc, Lookup[w, Key[{#[[1]], #[[2]]}], 1.] &]]];
    AppendTo[dropped, <|"From" -> worst[[1]], "To" -> worst[[2]], "Reason" -> "Cycle"|>];
    oedges = DeleteCases[oedges, e_ /; e["From"] === worst[[1]] && e["To"] === worst[[2]]];
    g = build[oedges]];
  <|"Graph" -> g, "Dropped" -> dropped, "OrderEdges" -> oedges|>];

(* 関連度行列 (無向): 任意の辺の Weight を両向きに *)
iKGRelatedness[kg_Association] := Module[{r = <||>},
  Do[r[{e["From"], e["To"]}] = Max[Lookup[r, Key[{e["From"], e["To"]}], 0.], e["Weight"]];
     r[{e["To"], e["From"]}] = Max[Lookup[r, Key[{e["To"], e["From"]}], 0.], e["Weight"]],
    {e, Lookup[kg, "Edges", {}]}];
  r];

iKGPriority["Source", n_, ___] := {If[NumericQ[n["Order"]], n["Order"], Infinity], -n["Importance"], n["Id"]};
iKGPriority["Importance", n_, ___] := {-n["Importance"], If[NumericQ[n["Order"]], n["Order"], Infinity], n["Id"]};
iKGPriority["Difficulty", n_, ___] := {n["Difficulty"], If[NumericQ[n["Order"]], n["Order"], Infinity], n["Id"]};
iKGPriority["Coherent", n_, placed_, last_, rel_] := {
  -(2. * Lookup[rel, Key[{last, n["Id"]}], 0.] + Total[Lookup[rel, Key[{#, n["Id"]}], 0.] & /@ placed]),
  If[NumericQ[n["Order"]], n["Order"], Infinity], -n["Importance"], n["Id"]};
iKGPriority[_, n_, rest___] := iKGPriority["Source", n, rest];

SourceVaultKGLinearOrder[kg_Association, strategy_String : "Source"] :=
  iKGLinearOrder[kg, SourceVaultKGOrderGraph[kg], strategy]["Order"];

iKGEffectiveOrders[index_Association, succ_Association] := Module[{ix = index, changed = True, k = 0, vals},
  While[changed && k < Length[ix],
    changed = False; k++;
    Do[If[! NumericQ[ix[id]["Order"]],
        vals = Select[Lookup[ix[#], "Order", None] & /@ Lookup[succ, id, {}], NumericQ];
        If[vals =!= {}, ix[id]["Order"] = Min[vals] - 0.5; changed = True]],
      {id, Keys[ix]}]];
  ix];

iKGLinearOrder[kg_Association, og_Association, strategy_String] := Module[
  {index = iKGNodeIndex[kg], root = Lookup[kg, "Root", None], oedges = og["OrderEdges"],
   indeg, succ, ready, order = {}, placed = {}, last = None, rel, pick, dropped = og["Dropped"], ids},
  ids = Keys[index];
  (* Root が最初に来るように Root への順序辺は落とす (診断に記録) *)
  If[StringQ[root],
    With[{into = Select[oedges, #["To"] === root &]},
      If[into =!= {},
        dropped = Join[dropped, <|"From" -> #["From"], "To" -> #["To"], "Reason" -> "RootIncoming"|> & /@ into];
        oedges = DeleteCases[oedges, e_ /; e["To"] === root]]]];
  indeg = AssociationMap[0 &, ids];
  succ = AssociationMap[{} &, ids];
  Do[indeg[e["To"]] += 1; succ[e["From"]] = Append[succ[e["From"]], e["To"]], {e, oedges}];
  (* 出現順 (Order) の無いノード (LLM が後から足した前提知識など) は「最初に必要とされる
     ノードの直前」に置く (just-in-time)。末尾に沈めると依存ノードまで引きずられる *)
  index = iKGEffectiveOrders[index, succ];
  rel = If[strategy === "Coherent", iKGRelatedness[kg], <||>];
  ready = Select[ids, indeg[#] === 0 &];
  While[ready =!= {},
    pick = If[StringQ[root] && MemberQ[ready, root] && order === {}, root,
      First[SortBy[ready, iKGPriority[strategy, index[#], placed, last, rel] &]]];
    AppendTo[order, pick]; AppendTo[placed, pick]; last = pick;
    ready = DeleteCases[ready, pick];
    Do[indeg[s] -= 1; If[indeg[s] === 0, AppendTo[ready, s]], {s, succ[pick]}]];
  <|"Order" -> order, "Dropped" -> dropped, "Unplaced" -> Complement[ids, order]|>];

(* ---------------- 最小全域順序木 (右背骨貪欲 = 線形拡張の階層分割) ----------------
   子は親より後に、部分木は連続区間に置かれる。前順走査 = 線形拡張そのもの。 *)

iKGAffinityTable[kg_Association] := Module[{t = <||>, spec},
  Do[
    spec = SourceVault`$SourceVaultKGEdgeKinds[e["EdgeKind"]];
    Switch[spec["Parent"],
      "From", t[{e["From"], e["To"]}] = Max[Lookup[t, Key[{e["From"], e["To"]}], 0.], e["Weight"] * spec["Affinity"]],
      "To", t[{e["To"], e["From"]}] = Max[Lookup[t, Key[{e["To"], e["From"]}], 0.], e["Weight"] * spec["Affinity"]],
      "Either", t[{e["From"], e["To"]}] = Max[Lookup[t, Key[{e["From"], e["To"]}], 0.], e["Weight"] * spec["Affinity"]];
        t[{e["To"], e["From"]}] = Max[Lookup[t, Key[{e["To"], e["From"]}], 0.], e["Weight"] * spec["Affinity"]],
      _, Null],
    {e, Lookup[kg, "Edges", {}]}];
  t];

Options[SourceVaultKGOrderedTree] = {"Strategy" -> "Source", "MaxDepth" -> 3, "DepthPenalty" -> 0.02};
SourceVaultKGOrderedTree[kg_Association, OptionsPattern[]] := Module[
  {og, lin, order, root, aff, succ, stack, parent = <||>, children = <||>, depth = <||>, score = 0.,
   maxDepth = OptionValue["MaxDepth"], pen = OptionValue["DepthPenalty"], strategy = OptionValue["Strategy"], best, cand},
  og = SourceVaultKGOrderGraph[kg];
  lin = iKGLinearOrder[kg, og, strategy];
  order = lin["Order"];
  If[order === {}, Return[Failure["EmptyGraph", <|"MessageTemplate" -> "no nodes to order"|>]]];
  root = First[order];
  aff = iKGAffinityTable[kg];
  (* 前提ノードは、それを必要とするノードの節の中に置く: x -> w の順序辺があれば
     w に対する親和度を (0.8 倍で) x にも継承する *)
  succ = <||>;
  Do[succ[e["From"]] = Append[Lookup[succ, e["From"], {}], e["To"]], {e, og["OrderEdges"]}];
  stack = {root}; children[root] = {}; depth[root] = 0;
  Do[
    cand = Map[Function[y, {y,
      Max[Prepend[0.8 * Lookup[aff, Key[{y, #}], 0.] & /@ Lookup[succ, x, {}], Lookup[aff, Key[{y, x}], 0.]]] -
        pen * depth[y]}], stack];
    (* 親候補は右背骨上のノード。深さ上限を超える親は許さない *)
    cand = Select[cand, depth[#[[1]]] + 1 <= maxDepth &];
    best = If[cand === {}, {root, 0.}, First[MaximalBy[cand, Last]]];
    (* 親和度が無い (0) ときは最上位 (root) に付けて新しい部を始める *)
    If[Last[best] <= 0., best = {root, 0.}];
    parent[x] = First[best];
    children[First[best]] = Append[Lookup[children, First[best], {}], x];
    children[x] = {};
    depth[x] = depth[First[best]] + 1;
    score += Max[Last[best], 0.];
    stack = Append[Take[stack, First[FirstPosition[stack, First[best]]]], x],
    {x, Rest[order]}];
  <|"ObjectClass" -> "SourceVaultKGOrderedTree", "GraphId" -> Lookup[kg, "GraphId", ""],
    "Strategy" -> strategy, "Root" -> root, "Order" -> order, "Parent" -> parent,
    "Children" -> children, "Depth" -> depth, "Score" -> score,
    "Diagnostics" -> <|"Dropped" -> lin["Dropped"], "Unplaced" -> lin["Unplaced"],
      "RootMismatch" -> If[StringQ[Lookup[kg, "Root", None]] && root =!= kg["Root"], kg["Root"], None]|>|>];

Options[SourceVaultKGOrderedTrees] = {"Strategies" -> {"Source", "Coherent", "Importance", "Difficulty"},
  "MaxDepth" -> 3, "DepthPenalty" -> 0.02};
SourceVaultKGOrderedTrees[kg_Association, OptionsPattern[]] := ReverseSortBy[
  Select[Map[SourceVaultKGOrderedTree[kg, "Strategy" -> #, "MaxDepth" -> OptionValue["MaxDepth"],
      "DepthPenalty" -> OptionValue["DepthPenalty"]] &, OptionValue["Strategies"]], AssociationQ],
  #["Score"] &];

iKGSubtree[tree_Association, id_String] := Module[{out = {id}, q = {id}, c},
  While[q =!= {},
    c = Flatten[Lookup[tree["Children"], q, {}]];
    out = Join[out, c]; q = c];
  out];

Options[SourceVaultKGLevelSummaries] = {"Language" -> Automatic};
SourceVaultKGLevelSummaries[kg_Association, tree_Association, OptionsPattern[]] := Module[
  {lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]], index = iKGNodeIndex[kg]},
  Association[Map[Function[id,
    With[{n = index[id], kids = Lookup[tree["Children"], id, {}]},
      id -> <|"Depth" -> tree["Depth"][id], "Label" -> SourceVaultKGText[n, "Label", lang],
        "Summary" -> With[{s = SourceVaultKGText[n, "Summary", lang]},
          If[s === "", SourceVaultKGText[n, "Label", lang], s]],
        "Children" -> (SourceVaultKGText[index[#], "Label", lang] & /@ kids),
        "Subtree" -> Length[iKGSubtree[tree, id]] - 1|>]],
    Select[tree["Order"], Lookup[tree["Children"], #, {}] =!= {} &]]]];

iKGOrderViolations[kg_Association, pos_Association] := Select[Map[Function[e,
    If[TrueQ[e["Order"]] && KeyExistsQ[pos, e["From"]] && KeyExistsQ[pos, e["To"]] && pos[e["From"]] > pos[e["To"]],
      <|"From" -> e["From"], "To" -> e["To"], "EdgeKind" -> e["EdgeKind"]|>, Nothing]],
  Lookup[kg, "Edges", {}]], AssociationQ];

SourceVaultKGVerify[kg_Association, tree_Association] := Module[{pos, viol, orphans, dropped, status},
  pos = AssociationThread[tree["Order"] -> Range[Length[tree["Order"]]]];
  orphans = Complement[Lookup[Lookup[kg, "Nodes", {}], "Id", {}], tree["Order"]];
  dropped = Lookup[tree["Diagnostics"], "Dropped", {}];
  (* 閉路を切るために落とした辺は違反ではない (Cycles に出る) *)
  viol = Select[iKGOrderViolations[kg, pos],
    Function[v, ! AnyTrue[dropped, #["From"] === v["From"] && #["To"] === v["To"] &]]];
  status = Which[viol =!= {} || orphans =!= {}, "Broken",
    dropped =!= {} || Lookup[tree["Diagnostics"], "RootMismatch", None] =!= None, "Warnings", True, "OK"];
  <|"Status" -> status, "OrderViolations" -> viol, "Cycles" -> Select[dropped, #["Reason"] === "Cycle" &],
    "RootIncomingDropped" -> Select[dropped, #["Reason"] === "RootIncoming" &],
    "Orphans" -> orphans, "RootMismatch" -> Lookup[tree["Diagnostics"], "RootMismatch", None],
    "MissingPrerequisites" -> {}|>];

(* ---------------- 詰め込みと枝刈り ---------------- *)

(* s の子孫のうち、スライドとして提示される最も近いもの (子がスライドならその子、でなければその子の下を探す) *)
iKGSlideChildren[tree_Association, slides_List, s_String] := Flatten[Map[Function[c,
  If[MemberQ[slides, c], {c}, iKGSlideChildren[tree, slides, c]]], Lookup[tree["Children"], s, {}]]];

Options[SourceVaultKGPlan] = {"Slides" -> Automatic, "Seconds" -> Automatic, "SecondsPerSlide" -> 25.,
  "Audience" -> Automatic, "MaxPackedPerSlide" -> 4, "PackRatio" -> 0.35, "ReleaseCeiling" -> 0.5,
  "MinSlides" -> 3, "ForceParts" -> 0.5};
SourceVaultKGPlan[kg_Association, tree_Association, OptionsPattern[]] := Module[
  {index = iKGNodeIndex[kg], scores, order = tree["Order"], root = tree["Root"], nSlides, seconds, floor = OptionValue["ForceParts"],
   sps = N[OptionValue["SecondsPerSlide"]], assumed, withheld, cands, forced, parts, take, theta, slides,
   packed = <||>, host = <||>, pruned, promoted = {}, cap = OptionValue["MaxPackedPerSlide"],
   ratio = OptionValue["PackRatio"], ceiling = OptionValue["ReleaseCeiling"], remaining, pos, diag = {},
   weights, total, secs, presented, packSet, posOf, oedges, predsOf, succOf, slideAncestor, subtreeSlides,
   presentedPos, hostFor, hidden},
  scores = SourceVaultKGScores[kg, OptionValue["Audience"]];
  (* privacy: fail-closed *)
  withheld = Select[order, index[#]["PrivacyLevel"] > ceiling &];
  (* 調整で「隠す」にしたノード (Hidden) はスライドにも詰め込みにも前提の修復にも使わない *)
  hidden = Select[order, TrueQ[Lookup[index[#], "Hidden", False]] && # =!= root &];
  order = Complement[order, withheld, hidden] // SortBy[FirstPosition[tree["Order"], #] &];
  assumed = Select[order, MemberQ[scores[#]["Flags"], "Assumed"] && # =!= root &];
  seconds = OptionValue["Seconds"];
  nSlides = OptionValue["Slides"];
  If[! IntegerQ[nSlides] || nSlides < 1,
    nSlides = Which[NumericQ[seconds] && seconds > 0, Max[1, Round[seconds / sps]],
      True, Length[order] - Length[assumed]]];
  nSlides = Max[nSlides, Min[OptionValue["MinSlides"], Length[order]]];
  cands = Select[order, # =!= root && ! MemberQ[assumed, #] &];
  (* 部 (root 直下) は必ず 1 枚にする。ただし Importance が "ForceParts" (既定 0.5) 未満の部 (付録など) は
     強制せず、他のノードと同じ順位づけに任せる (None で全部を強制) *)
  parts = Select[Lookup[tree["Children"], root, {}], MemberQ[cands, #] &&
    (! NumericQ[floor] || Lookup[index[#], "Importance", 0.5] >= floor) &];
  forced = If[nSlides >= 1 + Length[parts], parts, {}];
  remaining = Select[cands, ! MemberQ[forced, #] &];
  take = Max[0, nSlides - 1 - Length[forced]];
  remaining = SortBy[remaining, {-scores[#]["Score"], FirstPosition[order, #]} &];
  slides = Join[{root}, forced, Take[remaining, UpTo[take]]];
  theta = If[take > 0 && Length[remaining] > 0, scores[remaining[[Min[take, Length[remaining]]]]]["Score"], 1.];
  slides = SortBy[slides, FirstPosition[order, #] &];
  (* 詰め込み先の規則 (順序を壊さない):
       x の最寄りのスライド先祖 A の部分木にあるスライドのうち、位置が x 以前で、かつ
       x の提示済み先行ノードの位置以上・後続ノードの位置以下のものの中から最も後ろのものを選ぶ。
     先祖スライドへ詰めると、先祖と x の間にある先行ノードより前に出てしまう (実測: 図が機構の説明より
     前に出る / 結論が結果より前に出る)。部分木は L の連続区間なので、この規則なら節をまたがず、
     どの順で詰めても提示順が順序辺と矛盾しない *)
  posOf = AssociationThread[order -> Range[Length[order]]];
  oedges = Select[Lookup[kg, "Edges", {}], TrueQ[#["Order"]] &];
  predsOf = <||>; succOf = <||>;
  Do[predsOf[e["To"]] = Append[Lookup[predsOf, e["To"], {}], e["From"]];
     succOf[e["From"]] = Append[Lookup[succOf, e["From"], {}], e["To"]], {e, oedges}];
  slideAncestor[x_] := Module[{p = Lookup[tree["Parent"], x, None]},
    While[p =!= None && ! MemberQ[slides, p], p = Lookup[tree["Parent"], p, None]];
    If[p === None, root, p]];
  subtreeSlides[a_] := subtreeSlides[a] = Select[iKGSubtree[tree, a], MemberQ[slides, #] &];
  presentedPos[y_] := Which[MemberQ[slides, y], posOf[y], KeyExistsQ[host, y], posOf[host[y]], True, None];
  hostFor[x_, allowOverflow_] := Module[{cands, lb, ub, ok},
    cands = ReverseSortBy[Select[subtreeSlides[slideAncestor[x]], posOf[#] <= posOf[x] &], posOf];
    lb = Max[Prepend[Select[presentedPos /@ Lookup[predsOf, x, {}], IntegerQ], 0]];
    ub = Min[Prepend[Select[presentedPos /@ Lookup[succOf, x, {}], IntegerQ], Infinity]];
    cands = Select[cands, lb <= posOf[#] <= ub &];
    (* 図のある枚は行数が少ないので詰め込みは半分まで (続きスライドが増えすぎない) *)
    ok = SelectFirst[cands, Length[Lookup[packed, #, {}]] < If[Lookup[index[#], "Assets", {}] =!= {}, 1, cap] &, None];
    Which[ok =!= None, ok, allowOverflow && cands =!= {}, First[cands], True, None]];
  (* 閾値未満でも PackRatio 以上なら箇条書きとして詰め込む (容量のある先が無ければ落とす) *)
  Do[If[! MemberQ[slides, x] && ! MemberQ[assumed, x] && scores[x]["Score"] >= theta * ratio,
      With[{h = hostFor[x, False]},
        If[h =!= None, packed[h] = Append[Lookup[packed, h, {}], x]; host[x] = h]]],
    {x, order}];
  (* 前提の修復: 提示されるノードの Prerequisite / Derives / Motivates 元が落ちていれば詰め込む
     (容量超過を許す。置き場が無ければ Unplaceable に記録) *)
  Do[
    presented = Join[slides, Keys[host]];
    (* 同じ前提ノードが複数の依存先から昇格されて何度も詰め込まれないよう、host は即時に見る
       (実測: bg ノードが 4 枚に重複して現れた) *)
    Do[If[MemberQ[{"Prerequisite", "Derives", "Motivates"}, e["EdgeKind"]] && MemberQ[presented, e["To"]] &&
        ! MemberQ[presented, e["From"]] && ! KeyExistsQ[host, e["From"]] && ! MemberQ[slides, e["From"]] &&
        ! MemberQ[assumed, e["From"]] && MemberQ[order, e["From"]],
        With[{h = hostFor[e["From"], True]},
          If[h =!= None,
            packed[h] = Append[Lookup[packed, h, {}], e["From"]]; host[e["From"]] = h;
            AppendTo[promoted, e["From"]],
            AppendTo[diag, "Unplaceable prerequisite: " <> e["From"] <> " -> " <> e["To"]]]]],
      {e, oedges}],
    {3}];
  packSet = Keys[host];
  pruned = Select[order, ! MemberQ[slides, #] && ! MemberQ[packSet, #] && ! MemberQ[assumed, #] &];
  (* 秒配分 *)
  weights = Map[Function[s, 1. + 0.25 * Length[Lookup[packed, s, {}]] +
    If[Lookup[index[s], "Assets", {}] =!= {}, 0.4, 0.]], slides];
  total = If[NumericQ[seconds] && seconds > 0, N[seconds], sps * Length[slides]];
  secs = If[Total[weights] > 0, Round[total * weights / Total[weights]], ConstantArray[Round[sps], Length[slides]]];
  (* 丸めの誤差は最後の 1 枚で吸収し、合計を総秒数に一致させる *)
  If[secs =!= {}, secs[[-1]] += Round[total] - Total[secs]];
  If[withheld =!= {}, AppendTo[diag, "Withheld (privacy): " <> StringRiffle[withheld, ", "]]];
  <|"ObjectClass" -> "SourceVaultKGPlan", "GraphId" -> Lookup[kg, "GraphId", ""],
    "Slides" -> MapThread[Function[{s, sec},
      <|"NodeId" -> s, "Packed" -> SortBy[Lookup[packed, s, {}], FirstPosition[order, #] &],
        "Seconds" -> sec, "Depth" -> tree["Depth"][s], "Flags" -> scores[s]["Flags"],
        (* 節スライドの目次用: 部分木の中でスライドになった直近の子孫 (子がスライドでなければその下を辿る) *)
        "Children" -> Select[iKGSlideChildren[tree, slides, s], # =!= s &]|>], {slides, secs}],
    "Pruned" -> pruned, "Assumed" -> assumed, "Withheld" -> withheld, "Hidden" -> hidden, "Promoted" -> DeleteDuplicates[promoted],
    "Threshold" -> theta, "Scores" -> scores, "SlideCount" -> Length[slides],
    "TotalSeconds" -> Total[secs], "Audience" -> SourceVaultKGAudience[OptionValue["Audience"]],
    "Diagnostics" -> diag|>];

SourceVaultKGVerifyPlan[kg_Association, plan_Association] := Module[{pos = <||>, viol},
  MapIndexed[Function[{s, i},
    pos[s["NodeId"]] = First[i];
    Do[pos[p] = First[i], {p, s["Packed"]}]], plan["Slides"]];
  viol = Select[Map[Function[e,
    If[TrueQ[e["Order"]] && KeyExistsQ[pos, e["From"]] && KeyExistsQ[pos, e["To"]] && pos[e["From"]] > pos[e["To"]],
      <|"From" -> e["From"], "To" -> e["To"], "EdgeKind" -> e["EdgeKind"], "Slides" -> {pos[e["From"]], pos[e["To"]]}|>, Nothing]],
    Lookup[kg, "Edges", {}]], AssociationQ];
  <|"Status" -> If[viol === {}, "OK", "Broken"], "Violations" -> viol|>];

(* ---------------- アウトライン (言語別) ---------------- *)

Options[SourceVaultKGOutline] = {"Language" -> Automatic, "MaxAssetsPerSlide" -> 2, "MaxPointsPerSlide" -> 6,
  "MaxLinesPerSlide" -> 9, "CharsPerLine" -> 40, "FigureLines" -> 4, "Agenda" -> Automatic, "Roadmap" -> True,
  "Crumbs" -> True, "CharsPerSecond" -> Automatic, "ReShowFigures" -> True,
  "InheritFigures" -> True, "FigureReuse" -> 2, "Glossary" -> Automatic, "GlossaryRows" -> 6};

(* 1 行の表示コスト: 長い行は折り返して 2 行以上を占める (16:9 で 1 行 ≈ 40 全角字) *)
iKGLineCost[s_String, cpl_Integer] := Max[1, Ceiling[StringLength[s] / Max[10, cpl]]];
iKGLineCost[_, _] := 1;
(* 1 枚の行数: 導入文 + 要点 (+ 補足) + 詰め込んだ子 (ラベル + 行) *)
iKGSlideLines[lead_String, points_List, details_List, sub_List, cpl_Integer] :=
  If[lead === "", 0, iKGLineCost[lead, cpl]] +
  Total[iKGLineCost[#, cpl] & /@ points] +
  Total[iKGLineCost[#, cpl] & /@ Select[details, StringQ[#] && # =!= "" &]] +
  Total[Map[iKGLineCost[#["Label"], cpl] + Total[iKGLineCost[#, cpl] & /@ #["Points"]] &, sub]];
iKGSlideLines[points_List, sub_List, cpl_Integer] := iKGSlideLines["", points, {}, sub, cpl];

(* 1 枚の行数を予算に収める。1. 末尾の子の行 → 2. 補足を末尾から → 3. 自身の要点を minOwn 行まで →
   4. それでも超える子は「続き」スライドへ (行は元に戻して渡す)。
   旧実装は Total[.., 0] の誤りで一度も削れなかった (実測: 1 枚 29 行)。 *)
iKGFitLines[lead_String, points_List, detailsIn_List, subIn_List, budget_Integer, cpl_Integer, minOwn_: 2] :=
  Module[{pts = points, det = PadRight[Take[detailsIn, UpTo[Length[points]]], Length[points], ""], sub = subIn, k, overflow = {}, orig, lines},
  orig = Association[Map[#["NodeId"] -> # &, subIn]];
  lines[] := iKGSlideLines[lead, pts, det, sub, cpl];
  k = Length[sub];
  While[lines[] > budget && k >= 1,
    If[sub[[k, "Points"]] =!= {}, sub[[k, "Points"]] = Most[sub[[k, "Points"]]], k--]];
  k = Length[det];
  While[lines[] > budget && k >= 1, If[det[[k]] =!= "", det[[k]] = "", k--]];
  While[lines[] > budget && Length[pts] > minOwn, pts = Most[pts]; det = Most[det]];
  While[lines[] > budget && Length[sub] > 0,
    PrependTo[overflow, orig[Last[sub]["NodeId"]]]; sub = Most[sub]];
  {pts, det, sub, overflow}];
iKGFitLines[points_List, subIn_List, budget_Integer, cpl_Integer, minOwn_: 2] :=
  With[{r = iKGFitLines["", points, {}, subIn, budget, cpl, minOwn]}, {r[[1]], r[[3]], r[[4]]}];

iKGSentences[t_String, lang_String] := Select[StringTrim /@ StringSplit[t, If[lang === "ja", "。", ". "]], # =!= "" &];
(* ノードの原稿: Talk (要点順の文) を表示した要点数 + 1 文に切り詰める。無ければ要点をそのまま文に (Summary は要点と
   対応しないことがある)。要点も無ければ Summary *)
iKGNodeTalk[n_Association, nShown_Integer, lang_String] := Module[{t = SourceVaultKGText[n, "Talk", lang], ss},
  If[t === "", Return[With[{ps = SourceVaultKGText[n, "Points", lang]},
    If[ListQ[ps] && Select[ps, StringQ] =!= {}, iKGTalkFallback[Take[Select[ps, StringQ], UpTo[Max[1, nShown]]], "", lang],
      SourceVaultKGText[n, "Summary", lang]]]]];
  ss = iKGSentences[t, lang];
  If[nShown >= 1 && Length[ss] > nShown + 1, ss = Take[ss, nShown + 1]];
  If[ss === {}, "", StringRiffle[ss, If[lang === "ja", "。", ". "]] <> If[lang === "ja", "。", "."]]];
(* 原稿の長さ上限: 秒数 × 話速 (ja 7 字/秒、en 14 字/秒) と、表示行数 + 2 文。文の切れ目で切る *)
iKGCapTalk[talk_String, seconds_, lang_String, maxSentences_Integer, cpsIn_] := Module[
  {ss = iKGSentences[talk, lang], cps, maxChars, out = {}, len = 0, sep = If[lang === "ja", "。", ". "]},
  cps = If[NumericQ[cpsIn] && cpsIn > 0, cpsIn, If[lang === "ja", 7., 14.]];
  maxChars = Max[80, Round[If[NumericQ[seconds] && seconds > 0, seconds, 25] * cps]];
  Do[If[out === {} || (len + StringLength[s] <= maxChars && Length[out] < Max[1, maxSentences]),
      AppendTo[out, s]; len += StringLength[s]], {s, ss}];
  If[out === {}, "", StringRiffle[out, sep] <> StringTrim[sep]]];
iKGFirstSentence[t_String, lang_String] := With[{ss = iKGSentences[t, lang]},
  If[ss === {}, "", First[ss] <> If[lang === "ja", "。", "."]]];

(* 本文中の図表番号の言及: 図2 / 図 2 / Figure 2 / Fig. 2 *)
iKGFigureRefs[t_String] := DeleteDuplicates[StringCases[t,
  ("図" | "Figure" | "Fig." | "Fig") ~~ WhitespaceCharacter ... ~~ d : DigitCharacter .. :> ToExpression[d]]];
(* 図表番号の言及 1 つ分 (図2 / 図 7A / Figure 3 / 表1 / Table 2-1) *)
$iKGRefToken = RegularExpression["(?:図|表|Figure|Fig\\.|Fig|Table|Tab\\.)[ 　]*[0-9]+(?:[A-Za-z]\\b|[-–][0-9]+)?"];
(* keep に無い図と、スライドに載らない表の言及を落とす *)
iKGStripRefTokens[t_String, keep_List] := StringReplace[t, tok : $iKGRefToken :>
  If[StringStartsQ[tok, "表" | "Table" | "Tab."] || ! AnyTrue[iKGFigureRefs[tok], MemberQ[keep, #] &], "", tok]];
(* スライドに無い図表への言及を消す。括弧の中は区切りごとに見て、図表番号だけの項目を落とす:
   (図2) / （図2, 表1） は丸ごと、"(図7A, 1,450 s)" は "(1,450 s)" になる。
   項目が地の文のときは文が壊れるので残す ("(図2 の A 区間)")。
   括弧の外は、行頭の "Figure 9A: …" のような前置きだけ落とす *)
iKGStripFigureRefs[t_String, keep_List] := Module[{s, trim, dropQ},
  trim[x_String] := StringTrim[x, (WhitespaceCharacter | "," | "、" | "・" | ";" | "；" | "/" | "-" | "–") ..];
  dropQ[item_String] := With[{r = iKGStripRefTokens[item, keep]}, r =!= item && trim[r] === ""];
  s = StringReplace[t, whole : (("(" | "（") ~~ inner : Shortest[Except[")" | "）"] ..] ~~ (")" | "）")) :>
    Module[{parts = StringSplit[inner, x : ("," | "、" | ";" | "；") :> x], items, seps, keepIdx, res},
      items = parts[[1 ;; ;; 2]]; seps = If[Length[parts] >= 2, parts[[2 ;; ;; 2]], {}];
      keepIdx = Select[Range[Length[items]], ! dropQ[items[[#]]] &];
      Which[
        Length[keepIdx] === Length[items], whole,
        keepIdx === {}, "",
        True,
          res = trim[StringJoin[MapIndexed[If[First[#2] === 1, items[[#1]], seps[[#1 - 1]] <> items[[#1]]] &, keepIdx]]];
          If[res === "", "", StringTake[whole, 1] <> res <> StringTake[whole, -1]]]]];
  s = StringReplace[s, StartOfString ~~ tok : $iKGRefToken ~~ sep : (WhitespaceCharacter ... ~~ (":" | "：") ~~ WhitespaceCharacter ...) :>
    If[iKGStripRefTokens[tok, keep] === tok, tok <> sep, ""]];
  StringTrim[StringReplace[s, {"  " -> " ", " 。" -> "。", " 、" -> "、", " ." -> ".", " ," -> ","}]]];
iKGStripFigureRefs[x_, _] := x;
(* KG の図ノード → 論文中の番号 (キャプションの番号 > 出現順) と資産 *)
iKGFigureNumberOf[n_Association] := With[{src = Lookup[n, "Source", <||>]},
  With[{c = Lookup[If[AssociationQ[src], src, <||>], "Caption", None]},
    If[IntegerQ[c], c, With[{f = Lookup[If[AssociationQ[src], src, <||>], "Figure", None]}, If[IntegerQ[f], f, None]]]]];
(* 資産の同一性: 種類・参照・番号・ページ・切り出し (PDF の埋め込み画像はページと番号の組で決まる) *)
iKGAssetKey[a_Association] := {Lookup[a, "Type", ""], Lookup[a, "Ref", ""], Lookup[a, "N", None], Lookup[a, "Page", None], Lookup[a, "Crop", None]};
(* スライドの図の解決: 言及された図がこの枚に無ければ再掲 (枠があれば)。
   戻りは {この枚の資産, この枚にある図の番号} *)
iKGResolveFigs[texts_List, assetsIn_List, figNodes_List, figNumOf_Association, figByNum_Association, maxA_, reshowQ_] :=
  Module[{assets = assetsIn, refs, on},
    on[] := Select[Map[Function[fn, If[MemberQ[iKGAssetKey /@ assets, iKGAssetKey[First[fn["Assets"]]]], figNumOf[fn["Id"]], None]], figNodes], IntegerQ];
    refs = DeleteDuplicates[Flatten[iKGFigureRefs /@ Select[texts, StringQ]]];
    Do[If[! MemberQ[on[], m] && KeyExistsQ[figByNum, m] && TrueQ[reshowQ] && Length[assets] < maxA,
        AppendTo[assets, First[figByNum[m]["Assets"]]]], {m, refs}];
    {assets, on[]}];

iKGWord[lang_String, key_String] := Lookup[If[lang === "ja",
  <|"Cont" -> " (続き)", "Agenda" -> "全体の流れ", "Part" -> "第", "PartSuffix" -> "部", "Sep" -> " › "|>,
  <|"Cont" -> " (cont.)", "Agenda" -> "Outline", "Part" -> "Part ", "PartSuffix" -> "", "Sep" -> " › "|>], key, ""];
iKGPartLabel[lang_String, k_Integer, title_String] :=
  iKGWord[lang, "Part"] <> ToString[k] <> iKGWord[lang, "PartSuffix"] <> " " <> title;

(* 資産が占める行数: 図 (何枚でも縮めて並べる) は figLines、表は行数 + 見出し *)
iKGTableAssetQ[a_] := AssociationQ[a] && Lookup[a, "Type", ""] === "Table";
iKGAssetLines[assets_List, figLines_Integer] :=
  If[AnyTrue[assets, ! iKGTableAssetQ[#] &], figLines, 0] +
  Total[(Length[iKGList[Lookup[#, "Rows", {}]]] + 1) & /@ Select[assets, iKGTableAssetQ]];
(* 表のセルや読み上げに使う平文: **強調** と $…$ の印を外す *)
iKGPlain[s_String] := StringTrim[StringReplace[s, {"**" -> "", "$" -> "", "\\mathrm" -> "", "\\" -> ""}]];
iKGPlain[_] := "";
(* 用語ミニ辞書の 1 行: 題目 | 意味 (Lead > 最初の要点 > 要約の 1 文) *)
iKGGlossRow[n_Association, lang_String] := Module[{m},
  m = SourceVaultKGText[n, "Lead", lang];
  If[m === "", m = First[Replace[SourceVaultKGText[n, "Points", lang], Except[{__String}] -> {""}]]];
  If[m === "", m = iKGFirstSentence[SourceVaultKGText[n, "Summary", lang], lang]];
  m = iKGPlain[m];
  If[StringLength[m] > 46, m = StringTake[m, 45] <> "…"];
  {iKGPlain[StringReplace[SourceVaultKGText[n, "Label", lang], RegularExpression["\\s+[—–-]\\s+.*$"] -> ""]], m}];

SourceVaultKGOutline[kg_Association, plan_Association, OptionsPattern[]] := Module[
  {lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]], index = iKGNodeIndex[kg],
   primary = Lookup[kg, "Language", "ja"], missing = {}, maxA = OptionValue["MaxAssetsPerSlide"],
   maxP = OptionValue["MaxPointsPerSlide"], cpl = OptionValue["CharsPerLine"], figLines = OptionValue["FigureLines"],
   maxL = OptionValue["MaxLinesPerSlide"], cps = OptionValue["CharsPerSecond"], reshowQ = TrueQ[OptionValue["ReShowFigures"]],
   slides, labelOf, agendaQ, partTitles, crumbs, contSuffix, containsParent, secIds, rootId = Lookup[kg, "Root", "root"],
   slideIds, pslides, collapsed = <||>, figNodes, figNumOf, figByNum, topOf, partNodes, partOf, slideParentOf, entryIdx,
   figUse = <||>, adjAll, inheritFor, figOfAsset, glossary, reuse = Max[0, Replace[OptionValue["FigureReuse"], Except[_Integer] -> 2]]},
  If[! IntegerQ[cpl] || cpl < 10, cpl = 40];
  contSuffix = iKGWord[lang, "Cont"];
  labelOf[id_] := If[KeyExistsQ[index, id], SourceVaultKGText[index[id], "Label", lang], ""];
  (* 章構造は KG の Contains で見る (順序木は連続性のために付け替えるので Depth は章の深さではない) *)
  containsParent = Association[Map[#["To"] -> #["From"] &, Reverse[Select[Lookup[kg, "Edges", {}], #["EdgeKind"] === "Contains" &]]]];
  secIds = DeleteDuplicates[Lookup[Select[Lookup[kg, "Edges", {}], #["EdgeKind"] === "Contains" &], "From", {}]];
  (* 図ノードの番号表 (図表番号の言及の照合と再掲に使う) *)
  (* 図ノード = 図の資産を持つノード (推敲で Kind が Result 等に変わっていることがある) *)
  figNodes = Select[Lookup[kg, "Nodes", {}], AnyTrue[Replace[Lookup[#, "Assets", {}], Except[_List] -> {}],
    AssociationQ[#] && MemberQ[{"NotebookFigure", "PDFFigure", "PDFImage", "DeckSlide", "Image"}, Lookup[#, "Type", ""]] &] &];
  figNumOf = Association[Map[#["Id"] -> iKGFigureNumberOf[#] &, figNodes]];
  figByNum = Association[Map[Function[f, With[{m = figNumOf[f["Id"]]}, If[IntegerQ[m], m -> f, Nothing]]], Reverse[figNodes]]];
  (* 図の継承: 図の無い枚に、辺で結ばれた図 (無ければ同じ節の図) を再掲する。論文の図は枚数が少ないので、
     1 つの図を何枚かで見せ直す (32 回のように図が主役の枚にする)。継承で見せ直すのは図ごとに "FigureReuse" 回まで
     (図自身の枚は数えない)。figUse = 継承した回数 *)
  adjAll = Merge[Join[Map[#["From"] -> #["To"] &, Lookup[kg, "Edges", {}]], Map[#["To"] -> #["From"] &, Lookup[kg, "Edges", {}]]],
    DeleteDuplicates];
  figOfAsset[a_] := SelectFirst[figNodes, iKGAssetKey[First[#["Assets"]]] === iKGAssetKey[a] &, None];
  (* 子スライドが 1 つだけの節は道標にならない (1 行だけの枚になる) ので枚を畳み、秒は次の枚 (その子) へ *)
  slideIds = Lookup[plan["Slides"], "NodeId", {}];
  pslides = Module[{out = {}, carry = 0}, Do[
    Module[{s = ps, kids = Select[Lookup[ps, "Children", {}], MemberQ[slideIds, #] &]},
      If[TrueQ[OptionValue["Roadmap"]] && MemberQ[secIds, s["NodeId"]] && s["NodeId"] =!= rootId &&
          Lookup[s, "Packed", {}] === {} && Length[kids] === 1 && Lookup[index[s["NodeId"]], "Assets", {}] === {},
        collapsed[s["NodeId"]] = First[kids]; carry += Lookup[s, "Seconds", 0],
        If[carry > 0, s["Seconds"] = Lookup[s, "Seconds", 0] + carry; carry = 0]; AppendTo[out, s]]],
    {ps, plan["Slides"]}]; out];
  slideIds = Lookup[pslides, "NodeId", {}];
  (* 図の継承の割り当て: 1 段目 = 辺で結ばれた図、2 段目 = 同じ節の図 (出現順の近い順)。
     図の無い本文の枚だけが対象 (節の枚・根・詰め込んだ子に図がある枚は除く) *)
  inheritFor = <||>;
  If[TrueQ[OptionValue["InheritFigures"]] && figNodes =!= {},
    Module[{elig, pick},
      elig = Select[pslides, Function[ps, With[{id = ps["NodeId"]},
        id =!= rootId && ! MemberQ[secIds, id] && KeyExistsQ[index, id] &&
        Replace[Lookup[index[id], "Assets", {}], Except[_List] -> {}] === {} &&
        AllTrue[Lookup[ps, "Packed", {}], Replace[Lookup[Lookup[index, #, <||>], "Assets", {}], Except[_List] -> {}] === {} &]]]];
      pick[id_, cands_] := With[{ok = Select[cands, Lookup[figUse, #["Id"], 0] < reuse &]},
        If[ok =!= {},
          inheritFor[id] = First[ok]; figUse[First[ok]["Id"]] = Lookup[figUse, First[ok]["Id"], 0] + 1]];
      Do[With[{id = ps["NodeId"]},
          pick[id, SortBy[Select[figNodes, MemberQ[Lookup[adjAll, id, {}], #["Id"]] &], Lookup[figUse, #["Id"], 0] &]]],
        {ps, elig}];
      Do[With[{id = ps["NodeId"], n0 = index[ps["NodeId"]]},
          If[! KeyExistsQ[inheritFor, id] && Lookup[n0, "Layer", "Paper"] === "Paper" &&
              KeyExistsQ[containsParent, id] && containsParent[id] =!= rootId,
            pick[id, SortBy[Select[figNodes, Lookup[containsParent, #["Id"], None] === containsParent[id] &],
              Abs[Replace[Lookup[#, "Order", None], Except[_?NumericQ] -> 10^6] -
                Replace[Lookup[n0, "Order", None], Except[_?NumericQ] -> 0]] &]]]],
        {ps, elig}]]];
  slides = Flatten[Map[Function[s,
    Module[{n = index[s["NodeId"]], points, own, details, lead, sub, assets, cite, talk, title, budget, overflow, out, k = 0,
            secs, contSlides, children, roadmapQ, refs, onSlide, keepNums, shown, cap},
      If[! iKGHasLanguageQ[Lookup[n, "Label", ""], lang, primary] || ! iKGHasLanguageQ[Lookup[n, "Points", {}], lang, primary],
        AppendTo[missing, s["NodeId"]]];
      title = SourceVaultKGText[n, "Label", lang];
      own = Take[SourceVaultKGText[n, "Points", lang], UpTo[maxP]];
      details = Replace[SourceVaultKGText[n, "Details", lang], Except[_List] -> {}];
      children = Select[labelOf /@ Select[Lookup[s, "Children", {}], MemberQ[slideIds, #] &], # =!= "" &];
      (* 節スライド = 道標: その節でスライドになる子の題目 (2 つ以上) を要点にして、部の中の位置づけを見せる。
         LLM が節に付けた要点は原稿へ。節 = KG で Contains の子を持つノード (推敲で Kind が変わっていてもよい) *)
      roadmapQ = TrueQ[OptionValue["Roadmap"]] && MemberQ[secIds, s["NodeId"]] && s["NodeId"] =!= rootId && Length[children] >= 2;
      points = If[roadmapQ, Take[children, UpTo[maxP]], own];
      If[roadmapQ, details = {}];
      (* 導入文: ノードの Lead、無ければ Summary の最初の 1 文 (スライドだけ見ても何の話か分かるように) *)
      lead = SourceVaultKGText[n, "Lead", lang];
      If[lead === "" && s["NodeId"] =!= rootId, lead = iKGFirstSentence[SourceVaultKGText[n, "Summary", lang], lang]];
      If[lead =!= "" && points =!= {} && StringTrim[lead, "。" | "."] === StringTrim[First[points], "。" | "."], lead = ""];
      (* 詰め込んだ子: ラベル + 1 行 (Lead があればそれ、無ければ要点 2 つまで) *)
      sub = Map[Function[p, With[{m = index[p]},
        <|"NodeId" -> p, "Label" -> SourceVaultKGText[m, "Label", lang],
          "Points" -> With[{ld = SourceVaultKGText[m, "Lead", lang]},
            If[ld =!= "", {ld}, Take[SourceVaultKGText[m, "Points", lang], UpTo[2]]]]|>]], Lookup[s, "Packed", {}]];
      If[points === {} && MemberQ[secIds, s["NodeId"]] && s["NodeId"] =!= rootId, points = Take[children, UpTo[maxP]]];
      If[points === {} && sub === {} && lead === "" && SourceVaultKGText[n, "Summary", lang] =!= "",
        points = {SourceVaultKGText[n, "Summary", lang]}];
      assets = Take[Join[Lookup[n, "Assets", {}], Flatten[Lookup[index[#], "Assets", {}] & /@ Lookup[s, "Packed", {}], 1]], UpTo[maxA]];
      If[assets === {} && TrueQ[OptionValue["InheritFigures"]] && ! roadmapQ && s["NodeId"] =!= rootId,
        With[{fn = Lookup[inheritFor, s["NodeId"], None]}, If[AssociationQ[fn], assets = {First[fn["Assets"]]}]]];
      (* スライドはその枚にある図表しか指せない: 言及された図がこの枚に無ければ再掲 (枠があれば)、
         無理なら括弧つきの言及を消す。表は資産にならないので言及を消す *)
      {assets, keepNums} = iKGResolveFigs[Join[{lead}, points, details, Flatten[Lookup[sub, "Points", {}]]],
        assets, figNodes, figNumOf, figByNum, maxA, reshowQ];
      lead = iKGStripFigureRefs[lead, keepNums];
      points = iKGStripFigureRefs[#, keepNums] & /@ points;
      details = iKGStripFigureRefs[#, keepNums] & /@ details;
      sub = Map[Append[#, "Points" -> (iKGStripFigureRefs[#, keepNums] & /@ #["Points"])] &, sub];
      budget = Max[3, maxL - iKGAssetLines[assets, figLines]];
      (* 図のある枚は自身の要点を 1 行まで削ってよい (図が主役) *)
      {points, details, sub, overflow} = iKGFitLines[lead, points, details, sub, budget, cpl, If[assets =!= {}, 1, 2]];
      cite = SourceVaultKGText[n, "Cite", lang];
      If[cite === "", cite = FirstCase[Join[SourceVaultKGText[index[#], "Cite", lang] & /@ Lookup[sub, "NodeId", {}],
        Map[Function[a, With[{f = SelectFirst[figNodes, iKGAssetKey[First[#["Assets"]]] === iKGAssetKey[a] &, None]},
          If[AssociationQ[f], SourceVaultKGText[f, "Cite", lang], ""]]], assets]], c_String /; c =!= "", ""]];
      (* 原稿は箇条書きと同じ順に対応させる (冒頭の概要説明が箇条書きと食い違うと、聴き手はトークと
         スライドのどちらを追えばよいか迷う): 自身の要点 → 詰め込んだ子の順。長さは秒数と行数で抑える *)
      talk = If[roadmapQ,
        If[lang === "ja", "この部では、" <> StringRiffle[points, "、"] <> " の順に見ていきます。",
          "In this part we look at " <> StringRiffle[points, ", "] <> "."] <>
          With[{s0 = SourceVaultKGText[n, "Summary", lang]}, If[s0 === "", "", " " <> s0]],
        iKGNodeTalk[n, Length[points], lang]];
      talk = StringRiffle[Select[Prepend[Map[iKGNodeTalk[index[#["NodeId"]], Length[#["Points"]], lang] &, sub], talk], # =!= "" &], " "];
      If[talk === "", talk = iKGTalkFallback[Join[points, Flatten[Lookup[sub, "Points", {}]]], title, lang]];
      talk = iKGStripFigureRefs[talk, keepNums];
      (* 続きスライド: 収まらなかった子を同じ題目 + (続き) で後ろに並べる。秒は均等に分ける。
         あふれたのが子 1 つだけなら (続き) にせず、その子自身のスライドに昇格する (項目 1 つだけの枚を作らない) *)
      contSlides = {};
      While[overflow =!= {} && k < 8,
        k++;
        Module[{p2, d2, s2, o2, t2, a2 = {}, keep2, lead2 = "", title2, cite2 = "", node2, contQ, m2, r2},
          {p2, d2, s2, o2} = iKGFitLines["", {}, {}, overflow, Max[3, maxL], cpl];
          contQ = ! (p2 === {} && Length[s2] === 1 && KeyExistsQ[index, First[s2]["NodeId"]]);
          If[contQ,
            title2 = title <> contSuffix; node2 = s["NodeId"];
            cite2 = FirstCase[SourceVaultKGText[index[#], "Cite", lang] & /@ Lookup[s2, "NodeId", {}], c_String /; c =!= "", ""],
            (* 昇格: 詰め込みを解いて子ノードのスライドにする *)
            m2 = index[First[s2]["NodeId"]]; node2 = Lookup[m2, "Id", First[s2]["NodeId"]];
            title2 = SourceVaultKGText[m2, "Label", lang];
            lead2 = SourceVaultKGText[m2, "Lead", lang];
            If[lead2 === "", lead2 = iKGFirstSentence[SourceVaultKGText[m2, "Summary", lang], lang]];
            p2 = Take[Replace[SourceVaultKGText[m2, "Points", lang], Except[_List] -> {}], UpTo[maxP]];
            If[p2 === {}, p2 = First[s2]["Points"]];
            d2 = Replace[SourceVaultKGText[m2, "Details", lang], Except[_List] -> {}];
            If[lead2 =!= "" && p2 =!= {} && StringTrim[lead2, "。" | "."] === StringTrim[First[p2], "。" | "."], lead2 = ""];
            a2 = Take[Replace[Lookup[m2, "Assets", {}], Except[_List] -> {}], UpTo[maxA]];
            cite2 = SourceVaultKGText[m2, "Cite", lang]; s2 = {}];
          {a2, keep2} = iKGResolveFigs[Join[{lead2}, p2, d2, Flatten[Lookup[s2, "Points", {}]]], a2, figNodes, figNumOf, figByNum, maxA, reshowQ];
          lead2 = iKGStripFigureRefs[lead2, keep2];
          p2 = iKGStripFigureRefs[#, keep2] & /@ p2;
          d2 = iKGStripFigureRefs[#, keep2] & /@ d2;
          s2 = Map[Append[#, "Points" -> (iKGStripFigureRefs[#, keep2] & /@ #["Points"])] &, s2];
          r2 = iKGFitLines[lead2, p2, d2, s2, Max[3, maxL - iKGAssetLines[a2, figLines]], cpl, If[a2 =!= {}, 1, 2]];
          p2 = r2[[1]]; d2 = r2[[2]]; s2 = r2[[3]]; o2 = Join[r2[[4]], o2];
          t2 = If[contQ,
            StringRiffle[Select[Map[iKGNodeTalk[index[#["NodeId"]], Length[#["Points"]], lang] &, s2], # =!= "" &], " "],
            iKGNodeTalk[index[node2], Length[p2], lang]];
          If[t2 === "", t2 = iKGTalkFallback[Join[p2, Flatten[Lookup[s2, "Points", {}]]], title2, lang]];
          AppendTo[contSlides, <|"NodeId" -> node2, "Title" -> title2, "Lead" -> lead2, "Points" -> p2, "Details" -> d2, "Sub" -> s2,
            "Assets" -> a2, "Cite" -> cite2, "Talk" -> iKGStripFigureRefs[t2, keep2],
            "Seconds" -> 0, "Flags" -> s["Flags"], "Depth" -> s["Depth"], "Kind" -> Lookup[n, "Kind", ""], "Continuation" -> contQ|>];
          overflow = o2]];
      out = Prepend[contSlides, <|"NodeId" -> s["NodeId"], "Title" -> title, "Lead" -> lead, "Points" -> points, "Details" -> details,
        "Sub" -> sub, "Assets" -> assets, "Cite" -> cite, "Talk" -> talk, "Seconds" -> Lookup[s, "Seconds", 25], "Flags" -> s["Flags"],
        "Depth" -> s["Depth"], "Kind" -> n["Kind"], "Continuation" -> False|>];
      If[Length[out] > 1,
        secs = Quotient[Lookup[s, "Seconds", 25], Length[out]];
        out = MapIndexed[Append[#1, "Seconds" -> secs + If[First[#2] === 1, Lookup[s, "Seconds", 25] - secs * Length[out], 0]] &, out]];
      (* 原稿の長さは、続きに分けたあとの 1 枚あたりの秒数と行数で抑える
         (v1.26 は分ける前の秒数で上限を取っていたので、一度も切り詰められなかった) *)
      out = Map[Function[sl, Append[sl, "Talk" -> iKGCapTalk[sl["Talk"], sl["Seconds"], lang,
        iKGSlideLines[sl["Lead"], sl["Points"], sl["Details"], sl["Sub"], cpl] + 2, cps]]], out];
      out]], pslides], 1];
  (* 用語ミニ辞書: 図も子も無い周辺知識の枚が続くところは、1 枚ずつ概念スライドにせず表にまとめる
     (計算と自然33: 周辺知識の文字だけの枚が 16 枚続き、論文の図が出る前に枚数を使い切った)。
     重要度 0.8 以上の周辺知識は 1 枚のまま。表は "GlossaryRows" 行ずつ *)
  glossary = Replace[OptionValue["Glossary"], Automatic -> True];
  If[TrueQ[glossary],
    Module[{eligible, runs, out = {}, rowsMax = Max[2, OptionValue["GlossaryRows"]]},
      eligible[sl_] := ! TrueQ[sl["Continuation"]] && sl["Assets"] === {} && sl["Sub"] === {} &&
        KeyExistsQ[index, sl["NodeId"]] && Lookup[index[sl["NodeId"]], "Layer", ""] === "Background" &&
        Lookup[index[sl["NodeId"]], "Importance", 0.5] < 0.8 && ! MemberQ[secIds, sl["NodeId"]];
      runs = Split[slides, eligible[#1] && eligible[#2] &];
      Do[
        If[Length[run] >= 2 && eligible[First[run]],
          MapIndexed[Function[{chunk, ci},
            Module[{rows = iKGGlossRow[index[#["NodeId"]], lang] & /@ chunk, secs = Total[Lookup[chunk, "Seconds", 0]], talk},
              talk = If[lang === "ja",
                "ここで、この先に出てくる言葉をまとめておきます。" <> StringJoin[Map[#[[1]] <> "は、" <> StringTrim[#[[2]], "。" | "…"] <> "。" &, rows]],
                "Here are the terms we will need. " <> StringRiffle[Map[#[[1]] <> ": " <> StringTrim[#[[2]], "." | "…"] <> "." &, rows], " "]];
              AppendTo[out, <|"NodeId" -> First[chunk]["NodeId"],
                "Title" -> If[lang === "ja", "用語ミニ辞書", "Glossary"] <> If[First[ci] > 1, contSuffix, ""],
                "Lead" -> "", "Points" -> {}, "Details" -> {}, "Sub" -> {},
                "Assets" -> {<|"Type" -> "Table", "Rows" -> Prepend[rows, If[lang === "ja", {"用語", "意味"}, {"Term", "Meaning"}]]|>},
                "Cite" -> "", "Talk" -> iKGCapTalk[talk, secs, lang, Length[rows] + 2, cps], "Seconds" -> secs,
                "Flags" -> First[chunk]["Flags"], "Depth" -> First[chunk]["Depth"], "Kind" -> "Glossary",
                "Continuation" -> False, "Merged" -> Lookup[chunk, "NodeId"]|>]]],
            With[{ch = Partition[run, UpTo[rowsMax]]},
              (* 最後の 1 行だけの表は作らず前の表に足す *)
              If[Length[ch] >= 2 && Length[Last[ch]] === 1, Append[Drop[ch, -2], Join[ch[[-2]], ch[[-1]]]], ch]]],
          out = Join[out, run]],
        {run, runs}];
      slides = out]];
  (* 部 = 根の直下 (Contains) の節のうち、その部分木にスライドがあるもの (節自身が畳まれていてもよい)。
     各スライドの部は Contains の親を根の直下まで辿って決め、親スライドはスライドに当たるまで辿る *)
  topOf[id_] := Module[{x = id, k = 0}, If[! KeyExistsQ[containsParent, x] || x === rootId, Return[None]];
    While[k < 50 && KeyExistsQ[containsParent, x] && containsParent[x] =!= rootId, x = containsParent[x]; k++];
    If[KeyExistsQ[containsParent, x] && containsParent[x] === rootId, x, None]];
  partNodes = DeleteDuplicates[Select[Map[topOf, Lookup[Select[slides, ! TrueQ[#["Continuation"]] && #["NodeId"] =!= rootId &], "NodeId", {}]],
    # =!= None && MemberQ[secIds, #] &]];
  partTitles = labelOf /@ partNodes;
  partOf[id_] := With[{t = topOf[id]}, If[MemberQ[partNodes, t], t, None]];
  slideParentOf[id_] := Module[{x = Lookup[containsParent, id, None], k = 0},
    While[k < 50 && x =!= None && x =!= rootId && ! MemberQ[slideIds, x], x = Lookup[containsParent, x, None]; k++];
    If[x === None || x === rootId, None, x]];
  crumbs = Map[Function[sl, Module[{id = sl["NodeId"], part, k, parent},
    part = partOf[id];
    Which[
      ! TrueQ[OptionValue["Crumbs"]] || part === None, "",
      True,
        k = FirstPosition[partNodes, part][[1]];
        parent = slideParentOf[id];
        If[id === part || parent === None || parent === part,
          iKGPartLabel[lang, k, labelOf[part]],
          iKGPartLabel[lang, k, labelOf[part]] <> iKGWord[lang, "Sep"] <> labelOf[parent]]]]], slides];
  slides = MapThread[Append[#1, "Crumb" -> #2] &, {slides, crumbs}];
  (* 部の入口 (その部の最初の枚) には原稿に橋渡しを足す。続きスライドにも一言 *)
  entryIdx = Map[Function[p, FirstPosition[slides, sl_ /; partOf[sl["NodeId"]] === p && ! TrueQ[sl["Continuation"]], {0}, {1}][[1]]], partNodes];
  slides = MapIndexed[Function[{sl, ii}, With[{i = First[ii]},
    Which[
      MemberQ[entryIdx, i],
        Append[sl, "Talk" -> With[{k = FirstPosition[entryIdx, i][[1]]}, If[lang === "ja",
          "ここから第" <> ToString[k] <> "部「" <> labelOf[partNodes[[k]]] <> "」に入ります。",
          "We now turn to Part " <> ToString[k] <> ", " <> labelOf[partNodes[[k]]] <> ". "]] <> sl["Talk"]],
      TrueQ[sl["Continuation"]],
        Append[sl, "Talk" -> If[lang === "ja", "続きです。", "Continued. "] <> sl["Talk"]],
      True, sl]]], slides];
  (* 目次スライド: 部が 3 つ以上なら根の直後に全体の流れを 1 枚 (重要度 0.5 以上の部だけ、最大 MaxPointsPerSlide 行) *)
  agendaQ = Replace[OptionValue["Agenda"], Automatic :> Length[partNodes] >= 3];
  If[TrueQ[agendaQ] && partNodes =!= {} && Length[slides] >= 1,
    With[{titles = partTitles, rows = Module[{lab = MapIndexed[{First[#2], #1} &, partTitles], keep},
        keep = Select[lab, Lookup[index[partNodes[[#[[1]]]]], "Importance", 0.5] >= 0.5 &];
        If[keep === {}, keep = lab];
        If[Length[keep] > maxP, Append[Take[keep, maxP - 1], {0, "…"}], keep]]},
      slides = Insert[slides, <|"NodeId" -> "agenda", "Title" -> iKGWord[lang, "Agenda"], "Lead" -> "",
        "Points" -> Map[If[#[[1]] === 0, #[[2]], iKGPartLabel[lang, #[[1]], #[[2]]]] &, rows], "Details" -> {}, "Sub" -> {}, "Assets" -> {}, "Cite" -> "",
        "Talk" -> If[lang === "ja",
          "本日は " <> ToString[Length[titles]] <> " 部構成です。" <> StringRiffle[titles, "、"] <> " の順に進めます。",
          "The talk has " <> ToString[Length[titles]] <> " parts: " <> StringRiffle[titles, ", "] <> "."],
        "Seconds" -> 20, "Flags" -> {}, "Depth" -> 1, "Kind" -> "Agenda", "Continuation" -> False, "Crumb" -> ""|>, 2]]];
  <|"ObjectClass" -> "SourceVaultKGOutline", "GraphId" -> Lookup[kg, "GraphId", ""],
    "Title" -> SourceVaultKGText[<|"Label" -> Lookup[kg, "Title", ""], "PrimaryLanguage" -> primary|>, "Label", lang],
    "Language" -> lang, "Slides" -> slides, "MissingLanguage" -> DeleteDuplicates[missing],
    "Parts" -> partTitles, "Agenda" -> TrueQ[agendaQ] && partNodes =!= {}, "Collapsed" -> Keys[collapsed],
    "Glossary" -> Flatten[Lookup[Select[slides, KeyExistsQ[#, "Merged"] &], "Merged", {}]],
    "FigureUse" -> figUse,
    "TotalSeconds" -> Lookup[plan, "TotalSeconds", 0]|>];

iKGMdLine[s_String] := StringReplace[StringTrim[s], {"\r\n" -> " ", "\n" -> " "}];

(* 枚の出どころ: ノードの枚はノード Id、用語ミニ辞書は glossary、目次は agenda (空白や括弧を含む Id は付けない) *)
iKGSlideNodeTag[s_Association] := With[{id = If[Lookup[s, "Kind", ""] === "Glossary", "glossary", Lookup[s, "NodeId", None]]},
  If[StringQ[id] && id =!= "" && StringFreeQ[id, WhitespaceCharacter | "{" | "}"], id, None]];

iKGTalkFallback[points_List, title_String, lang_String] := Module[{ps = Select[points, StringQ[#] && # =!= "" &], sep},
  sep = If[lang === "ja", "。", ". "];
  Which[
    ps =!= {}, StringRiffle[StringTrim[#, sep] & /@ ps, sep] <> StringTrim[sep],
    title =!= "", title <> StringTrim[sep],
    True, ""]];

SourceVaultKGOutlineToMarkdown[outline_Association] := Module[{lines = {}, assets = {}, k = 0, title, det},
  title = iKGStr[Lookup[outline, "Title", ""]];
  If[title =!= "", lines = Join[lines, {"---", "Title: " <> title, "---", ""}]];
  Do[
    (* node= は枚の出どころ (題目セルの CellTags "KGNode:<id>")。生成し直すときに前回の枚を見分け、質疑応答を引き継ぐ *)
    AppendTo[lines, "## " <> iKGMdLine[s["Title"]] <> " {expected=" <> ToString[Round[s["Seconds"]]] <>
      With[{nid = iKGSlideNodeTag[s]}, If[StringQ[nid], " node=" <> nid, ""]] <> "}"];
    If[StringQ[Lookup[s, "Crumb", ""]] && s["Crumb"] =!= "", AppendTo[lines, "crumb: " <> iKGMdLine[s["Crumb"]]]];
    (* 導入文は箇条書きの前に地の文で *)
    If[StringQ[Lookup[s, "Lead", ""]] && s["Lead"] =!= "", AppendTo[lines, iKGMdLine[s["Lead"]]]];
    det = PadRight[Replace[Lookup[s, "Details", {}], Except[_List] -> {}], Length[s["Points"]], ""];
    (* 図が 2 枚以上で箇条 (要点と詰め込んだ子) も 2 つ以上なら、箇条の間に図を挟む
       (箇条 → 図 → 箇条 → 図)。表は最後 *)
    Module[{figs = Select[s["Assets"], ! MemberQ[{"Table", "Image"}, Lookup[#, "Type", ""]] &],
            blocks, nbk, breaks, fi = 0, emitFig},
      emitFig[] := (fi++; k++; AppendTo[assets, figs[[fi]]]; AppendTo[lines, "<<FIG" <> ToString[k] <> ">>"]);
      blocks = Join[Table[{"P", i}, {i, Length[s["Points"]]}], Table[{"S", j}, {j, Length[s["Sub"]]}]];
      nbk = Length[blocks];
      breaks = If[Length[figs] >= 2 && nbk >= 2, Table[Ceiling[i * nbk / Length[figs]], {i, Length[figs] - 1}], {}];
      Do[
        With[{blk = blocks[[b]]},
          If[First[blk] === "P",
            AppendTo[lines, "- " <> iKGMdLine[s["Points"][[Last[blk]]]]];
            If[StringQ[det[[Last[blk]]]] && det[[Last[blk]]] =!= "", AppendTo[lines, "  - " <> iKGMdLine[det[[Last[blk]]]]]],
            With[{sub = s["Sub"][[Last[blk]]]},
              AppendTo[lines, "- " <> iKGMdLine[sub["Label"]]];
              Do[AppendTo[lines, "  - " <> iKGMdLine[p]], {p, sub["Points"]}]]]];
        Do[If[fi < Length[figs], emitFig[]], {Count[breaks, b]}],
        {b, nbk}];
      While[fi < Length[figs], emitFig[]]];
    Do[Switch[Lookup[a, "Type", ""],
        "Table", With[{rows = iKGList[Lookup[a, "Rows", {}]]},
          AppendTo[lines, ""];
          Do[AppendTo[lines, "| " <> StringRiffle[StringReplace[iKGStr /@ iKGList[r], "|" -> "/"], " | "] <> " |"];
            If[ri === 1 && Length[rows] > 1, AppendTo[lines, "| " <> StringRiffle[ConstantArray["---", Length[iKGList[r]]], " | "] <> " |"]],
            {ri, Length[rows]}, {r, {rows[[ri]]}}]],
        "Image", AppendTo[lines, "![](" <> iKGStr[Lookup[a, "Path", ""]] <> ")"],
        _, Null],
      {a, s["Assets"]}];
    If[s["Cite"] =!= "", AppendTo[lines, "cite: " <> iKGMdLine[s["Cite"]]]];
    If[s["Talk"] =!= "", AppendTo[lines, "talk: " <> iKGMdLine[s["Talk"]]]];
    (* 想定問答 (KG のノードに保存したもの。質疑応答セルの本文をそのまま) *)
    If[StringQ[Lookup[s, "QA", None]] && StringTrim[s["QA"]] =!= "",
      Do[AppendTo[lines, "qa: " <> q], {q, StringSplit[StringReplace[s["QA"], "\r\n" -> "\n"], "\n"]}]];
    AppendTo[lines, ""],
    {s, Lookup[outline, "Slides", {}]}];
  <|"Markdown" -> StringRiffle[lines, "\n"], "Assets" -> assets, "SlideCount" -> Length[Lookup[outline, "Slides", {}]]|>];

(* ---------------- 複数 KG の合成 (サーベイ) ---------------- *)

iKGPrefixId[gid_String, id_String] := If[StringStartsQ[id, "bg:"] || StringContainsQ[id, "/"], id, gid <> "/" <> id];

Options[SourceVaultKGCompose] = {"GraphId" -> Automatic, "Title" -> "", "Language" -> Automatic,
  "Chronological" -> False, "Edges" -> {}, "CrossWeight" -> 0.3};
SourceVaultKGCompose[kgs_List, OptionsPattern[]] := Module[
  {valid = Select[SourceVaultKGValidate /@ kgs, AssociationQ], nodes = <||>, edges = {}, roots = {},
   gid, lang, bgOwners = <||>, rootId = "survey", pairs, cross = {}, res},
  If[valid === {}, Return[Failure["NoGraphs", <|"MessageTemplate" -> "no valid graphs"|>]]];
  gid = Replace[OptionValue["GraphId"], Automatic -> "survey-" <> StringRiffle[Lookup[valid, "GraphId"], "+"]];
  lang = Replace[OptionValue["Language"], Automatic -> First[valid]["Language"]];
  Do[
    Module[{g = valid[[gi]]["GraphId"], kg = valid[[gi]], map},
      (* 共有 background 層に連結済みの周辺知識ノードは bg: の共有 Id に付け替える (論文間で 1 つに統合される) *)
      map = Association[Map[Function[n, n["Id"] ->
        If[n["Layer"] =!= "Paper" && StringQ[n["BackgroundRef"]], n["BackgroundRef"], iKGPrefixId[g, n["Id"]]]], kg["Nodes"]]];
      Do[Module[{id = map[n["Id"]], m = n},
          m["Id"] = id;
          (* 論文ごとに出現順をずらし、Source 戦略で論文の部分木が連続するようにする
             (Order の無いノードは just-in-time 規則に任せる) *)
          m["Order"] = If[NumericQ[n["Order"]], gi * 10000 + n["Order"], None];
          If[StringStartsQ[id, "bg:"],
            If[KeyExistsQ[nodes, id],
              nodes[id]["Importance"] = Max[nodes[id]["Importance"], m["Importance"]];
              nodes[id]["Domains"] = Union[nodes[id]["Domains"], m["Domains"]];
              nodes[id]["Aliases"] = Union[nodes[id]["Aliases"], m["Aliases"]],
              m["Layer"] = "Shared"; nodes[id] = m],
            m["Graph"] = g; nodes[id] = m];
          bgOwners[id] = Append[Lookup[bgOwners, id, {}], g]],
        {n, kg["Nodes"]}];
      (* 論文ノードの BackgroundRef は bg ノードへの Prerequisite として辺に落とす *)
      Do[If[StringQ[n["BackgroundRef"]] && KeyExistsQ[nodes, n["BackgroundRef"]],
          AppendTo[edges, <|"From" -> n["BackgroundRef"], "To" -> map[n["Id"]], "EdgeKind" -> "Prerequisite", "Weight" -> 0.6|>]],
        {n, kg["Nodes"]}];
      edges = Join[edges, Map[Function[e, Join[e, <|"From" -> map[e["From"]], "To" -> map[e["To"]]|>]], kg["Edges"]]];
      If[StringQ[kg["Root"]], AppendTo[roots, <|"Id" -> map[kg["Root"]], "Graph" -> g,
        "Year" -> With[{y = SourceVaultKGNode[kg, kg["Root"]]["Year"]}, If[IntegerQ[y], y, None]]|>]]],
    {gi, Length[valid]}];
  (* 共有 bg ノードへの Contains は最初の論文のものだけ残す。両方の節が含むと、後の論文の節が
     置かれるまで共有ノードが提示できず、先の論文の依存ノードが後の論文の区間へ押し出される *)
  edges = Join[
    Select[edges, ! (#["EdgeKind"] === "Contains" && StringStartsQ[#["To"], "bg:"]) &],
    DeleteDuplicatesBy[Select[edges, #["EdgeKind"] === "Contains" && StringStartsQ[#["To"], "bg:"] &], #["To"] &]];
  (* サーベイ根 *)
  nodes[rootId] = <|"Id" -> rootId, "Kind" -> "Survey", "Label" -> OptionValue["Title"],
    "Summary" -> "", "Points" -> (SourceVaultKGText[nodes[#["Id"]], "Label", lang] & /@ roots),
    "Importance" -> 1., "Difficulty" -> 0.2, "Layer" -> "Paper", "Domains" -> {}, "Order" -> -1|>;
  Do[AppendTo[edges, <|"From" -> rootId, "To" -> r["Id"], "EdgeKind" -> "Contains", "Weight" -> 1.|>], {r, roots}];
  If[TrueQ[OptionValue["Chronological"]],
    With[{sorted = SortBy[Select[roots, IntegerQ[#["Year"]] &], #["Year"] &]},
      Do[AppendTo[edges, <|"From" -> sorted[[i, "Id"]], "To" -> sorted[[i + 1, "Id"]], "EdgeKind" -> "Precedes", "Weight" -> 0.5|>],
        {i, Length[sorted] - 1}]],
    Do[AppendTo[edges, <|"From" -> roots[[i, "Id"]], "To" -> roots[[i + 1, "Id"]], "EdgeKind" -> "Precedes", "Weight" -> 0.4|>],
      {i, Length[roots] - 1}]];
  (* 共有 bg ノードを介した論文間の関連 *)
  Do[
    Module[{users = Select[edges, #["From"] === bg && #["EdgeKind"] === "Prerequisite" &]},
      pairs = Subsets[DeleteDuplicates[Lookup[users, "To"]], {2}];
      Do[If[Lookup[nodes[p[[1]]], "Graph", ""] =!= Lookup[nodes[p[[2]]], "Graph", ""],
          AppendTo[cross, <|"From" -> p[[1]], "To" -> p[[2]], "EdgeKind" -> "RelatedTo",
            "Weight" -> OptionValue["CrossWeight"], "EvidenceRefs" -> {bg}|>]], {p, pairs}]],
    {bg, Select[Keys[nodes], StringStartsQ[#, "bg:"] &]}];
  res = SourceVaultKGValidate[<|"GraphId" -> gid, "Title" -> OptionValue["Title"], "Kind" -> "Survey",
    "Language" -> lang, "Sources" -> Flatten[Lookup[valid, "Sources", {}], 1],
    "PrivacyLevel" -> Max[Lookup[valid, "PrivacyLevel", 0.]],
    "Nodes" -> Values[nodes], "Edges" -> Join[edges, cross, Select[iKGAssoc /@ iKGList[OptionValue["Edges"]], AssociationQ]],
    "Root" -> rootId|>];
  If[AssociationQ[res], res["Members"] = Lookup[valid, "GraphId"]];
  res];

(* ---------------- 共有 background 層 ---------------- *)

iKGBackgroundFile[bgId_String] := FileNameJoin[{iKGBackgroundDir[],
  StringReplace[bgId, StartOfString ~~ "bg:" -> "bg-"] <> ".json"}];

SourceVaultKGBackgroundList[] := Select[Map[Function[f, With[{d = iKGReadJSON[f]},
    If[AssociationQ[d], KeyMap[ToString, d], Nothing]]],
  Quiet @ Check[FileNames["bg-*.json", iKGBackgroundDir[]], {}]], AssociationQ];

Options[SourceVaultKGBackgroundSearch] = {"Limit" -> 5, "MinScore" -> 0.3};
SourceVaultKGBackgroundSearch[text_String, OptionsPattern[]] := Module[{all = SourceVaultKGBackgroundList[], scored},
  scored = Map[Function[b,
    With[{cands = Join[{iKGStr[Lookup[b, "Label", ""]]}, iKGStrList[Lookup[b, "Aliases", {}]]]},
      <|"Id" -> iKGStr[Lookup[b, "Id", ""]], "Label" -> iKGStr[Lookup[b, "Label", ""]],
        "Score" -> Max[Prepend[iKGBigramSimilarity[text, #] & /@ cands, 0.]],
        "Graphs" -> iKGStrList[Lookup[b, "Graphs", {}]]|>]], all];
  Take[ReverseSortBy[Select[scored, #["Score"] >= OptionValue["MinScore"] &], #["Score"] &], UpTo[OptionValue["Limit"]]]];

Options[SourceVaultKGBackgroundLink] = {"MinScore" -> 0.6};
SourceVaultKGBackgroundLink[kgIn_Association, OptionsPattern[]] := Module[
  {kg = kgIn, linked = {}, created = {}, gid = Lookup[kgIn, "GraphId", ""], nodes},
  nodes = Map[Function[n,
    If[n["Layer"] =!= "Background" && n["Kind"] =!= "Background", n,
      Module[{label = iKGTextValue[n["Label"], "ja", n["PrimaryLanguage"]], hits, bgId, file, rec},
        hits = If[StringQ[n["BackgroundRef"]] && FileExistsQ[iKGBackgroundFile[n["BackgroundRef"]]],
          {<|"Id" -> n["BackgroundRef"], "Score" -> 1.|>},
          SourceVaultKGBackgroundSearch[label, "Limit" -> 1, "MinScore" -> OptionValue["MinScore"]]];
        If[hits =!= {},
          bgId = hits[[1, "Id"]]; file = iKGBackgroundFile[bgId];
          rec = iKGReadJSON[file];
          If[AssociationQ[rec],
            rec = KeyMap[ToString, rec];
            rec["Graphs"] = Union[iKGStrList[Lookup[rec, "Graphs", {}]], {gid}];
            rec["Aliases"] = Union[iKGStrList[Lookup[rec, "Aliases", {}]], {label}, iKGStrList[n["Aliases"]]];
            iKGWriteJSON[file, rec]];
          AppendTo[linked, {n["Id"], bgId}];
          Append[n, "BackgroundRef" -> bgId],
          bgId = "bg:" <> iKGSlug[label];
          rec = Join[KeyDrop[n, {"BackgroundRef", "Source", "Order"}],
            <|"Id" -> bgId, "Layer" -> "Shared", "Graphs" -> {gid}, "CreatedAtUTC" -> iKGUTCNow[]|>];
          iKGWriteJSON[iKGBackgroundFile[bgId], rec];
          AppendTo[created, {n["Id"], bgId}];
          Append[n, "BackgroundRef" -> bgId]]]]],
    Lookup[kg, "Nodes", {}]];
  kg["Nodes"] = nodes;
  <|"Graph" -> kg, "Linked" -> linked, "Created" -> created|>];

(* 過去デッキの再利用候補 (SourceVault_kb がロード済みのときだけ) *)
Options[SourceVaultKGSuggestPastSlides] = {"Limit" -> 2, "MinScore" -> 1.5};
SourceVaultKGSuggestPastSlides[kg_Association, kbId_String, OptionsPattern[]] := Module[{srcs, pathOf, out = {}},
  If[Length[DownValues[SourceVault`SourceVaultKBSearch]] === 0 ||
     ! TrueQ[Quiet @ Check[SourceVault`SourceVaultKBLoadedQ[kbId], False]], Return[{}]];
  srcs = Quiet @ Check[SourceVault`SourceVaultKBSources[kbId], {}];
  pathOf = Association[Map[(iKGStr[Lookup[#, "SourceId", ""]] -> iKGStr[Lookup[#, "Path", ""]]) &, Select[srcs, AssociationQ]]];
  Do[
    Module[{label = iKGTextValue[n["Label"], "ja", n["PrimaryLanguage"]], hits},
      hits = Quiet @ Check[SourceVault`SourceVaultKBSearch[kbId, label, "Limit" -> OptionValue["Limit"]], {}];
      hits = Select[iKGList[hits], AssociationQ[#] && iKGNum[Lookup[#, "Score", 0.], 0.] >= OptionValue["MinScore"] &];
      Do[AppendTo[out, <|"NodeId" -> n["Id"], "Label" -> label,
          "Deck" -> Lookup[pathOf, iKGStr[Lookup[h, "SourceId", ""]], ""],
          "Slide" -> Lookup[h, "SlideIndex", None], "Title" -> iKGStr[Lookup[h, "Title", ""]],
          "Score" -> iKGNum[Lookup[h, "Score", 0.], 0.]|>], {h, hits}]],
    {n, Select[Lookup[kg, "Nodes", {}], #["Layer"] =!= "Paper" &]}];
  out];

(* ---------------- プロンプト (純関数) ---------------- *)

iKGEdgeKindDoc[] := StringRiffle[Map[Function[k,
  "  - " <> k <> ": " <> Switch[k,
    "Prerequisite", "From は To を理解するための前提 (From を先に説明する。難易度順序)",
    "Precedes", "From は To より先に起きた / 先に行われた (年代・実験の順序)",
    "Derives", "To は From から導かれる (導出順序)",
    "Motivates", "From (問い・課題) が To (手法・実験) を動機づける",
    "LeadsTo", "From (結果) が To (結論・含意) につながる (因果)",
    "Contains", "From (節・まとまり) が To を含む (階層)",
    "Supports", "From (証拠・図・データ) が To (主張) を支える (順序制約なし)",
    "Explains", "From が To を解説する (順序制約なし)",
    "Contrasts", "From と To は対比される (順序制約なし)",
    "RelatedTo", "関連がある (順序制約なし)",
    "Cites", "From が To を引用する (順序制約なし)",
    _, ""]], Keys[SourceVault`$SourceVaultKGEdgeKinds]], "\n"];

iKGSchemaDoc[] := "{\n  \"GraphId\": \"<id>\", \"Title\": \"<論文題目>\", \"Language\": \"ja\", \"Kind\": \"Paper\",\n" <>
  "  \"Root\": \"<主張ノードの Id>\",\n" <>
  "  \"Nodes\": [{\"Id\": \"claim\", \"Kind\": \"Claim|Concept|Definition|Method|Experiment|Result|Equation|Figure|Question|Conclusion|Background|Section\",\n" <>
  "    \"Label\": \"短い名詞句 (スライドタイトルになる)\", \"Summary\": \"1-2 文の要約 (talk の骨子)\",\n" <>
  "    \"Points\": [\"体言止めの箇条書き 2-5 行\"], \"Difficulty\": 0.0-1.0, \"Importance\": 0.0-1.0,\n" <>
  "    \"Domains\": [\"電気化学\", \"高分子\"], \"Year\": 2024 (背景事実の年代。無ければ省略), \"Order\": 出現順の整数,\n" <>
  "    \"Layer\": \"Paper|Background\", \"Cite\": \"(著者 年) Fig. n\",\n" <>
  "    \"Assets\": [{\"Type\": \"NotebookFigure\", \"Ref\": \"<key>\", \"N\": 3}, {\"Type\": \"Formula\", \"Ref\": \"<key>\", \"N\": 1},\n" <>
  "               {\"Type\": \"PDFFigure\", \"Ref\": \"<pdfkey>\", \"Page\": 4, \"Crop\": [[0.1,0.9],[0.2,0.6]]}, {\"Type\": \"Table\", \"Rows\": [[\"項目\",\"値\"],[\"a\",\"1\"]]}]}],\n" <>
  "  \"Edges\": [{\"From\": \"q1\", \"To\": \"method\", \"EdgeKind\": \"Motivates\", \"Weight\": 0.0-1.0, \"Confidence\": 0.0-1.0, \"EvidenceRefs\": [\"[FIG2]\"]}]\n}";

Options[SourceVaultKGExtractionPrompt] = {"GraphId" -> "paper", "Title" -> "", "Language" -> "ja",
  "SourceKey" -> "", "PDFKey" -> "", "MaxNodes" -> 60, "MinNodes" -> 25};
SourceVaultKGExtractionPrompt[sourceText_String, OptionsPattern[]] :=
  "あなたは論文の内容を「発表用の知識グラフ」に構造化する専門家です。以下の本文から、スライドや解説を動的に生成するための知識グラフを JSON だけで出力してください。\n\n" <>
  "対象: " <> If[OptionValue["Title"] =!= "", OptionValue["Title"], "(題目は本文から取る)"] <>
  "  GraphId: " <> OptionValue["GraphId"] <> "  言語: " <> OptionValue["Language"] <> "\n" <>
  If[OptionValue["SourceKey"] =!= "", "本文ノートブックの key: " <> OptionValue["SourceKey"] <> " (Assets の NotebookFigure / Formula の Ref に使う。[FIGn] / [EQn] は本文中の番号)\n", ""] <>
  If[OptionValue["PDFKey"] =!= "", "原論文 PDF の key: " <> OptionValue["PDFKey"] <> " (Assets の PDFFigure の Ref に使う)\n", ""] <>
  "\n出力 JSON のスキーマ:\n" <> iKGSchemaDoc[] <> "\n\n" <>
  "辺 (Edges) の種別。順序制約のある種別はすべて「From を To より先に提示する」向きで書く:\n" <> iKGEdgeKindDoc[] <> "\n\n" <>
  "作り方の規則:\n" <>
  "1. ノードは " <> ToString[OptionValue["MinNodes"]] <> "〜" <> ToString[OptionValue["MaxNodes"]] <> " 個。1 ノード = 1 枚のスライドになりうる粒度 (1 つの問い・手法・実験・結果・式・図・概念)。Root は論文の主張 (Claim) 1 つ。\n" <>
  "2. 論文の節 (背景 / 手法 / 結果 / 議論 / 結論) は Kind=Section のノードにして Contains 辺で下位ノードをまとめる。Order は本文の出現順。\n" <>
  "3. 論文本文に無いが理解に必要な前提知識 (定義・古典的な式・先行研究の事実) は Layer=Background のノードとして追加し、それを前提とする論文ノードへ Prerequisite 辺を張る。Domains (領域名) と Difficulty (その領域の学部レベルを 0.5 とする) を必ず付ける。\n" <>
  "4. 実験・定理・先行研究の年代順は Precedes、式や量の導出順は Derives、問い→手法は Motivates、結果→結論は LeadsTo、図やデータ→主張は Supports で表す。難しい概念の前に易しい概念が来るよう Prerequisite を張る (例: Lagrangian の後に F=ma の説明が来てはいけない)。\n" <>
  "5. Importance は「その論文の主張を伝えるのに欠かせない度合い」。Difficulty は聴き手の前提知識なしで理解するのに要する水準 (0=常識, 0.3=高校, 0.5=学部, 0.7=大学院, 0.9=専門家)。\n" <>
  "6. 図・式・写真は本文の [FIGn] / [EQn] を Assets で参照し、Cite に出典を書く。式は文字列で書き直さない (Formula 資産で原式を引用する)。\n" <>
  "7. Points は体言止めで短く、Summary は です・ます調 1-2 文。すべて " <> OptionValue["Language"] <> " で書く。\n" <>
  "8. 出力は JSON オブジェクトのみ (前置き・説明・コードフェンス以外の文章を付けない)。\n\n" <>
  "=== 本文 ===\n" <> sourceText <> "\n=== 本文ここまで ===";

Options[SourceVaultKGBackgroundPrompt] = {"MaxNodes" -> 12};
SourceVaultKGBackgroundPrompt[kg_Association, audSpec_, OptionsPattern[]] := Module[
  {aud = SourceVaultKGAudience[audSpec], lang = Lookup[kg, "Language", "ja"], listing},
  listing = StringRiffle[Map[Function[n,
    "- " <> n["Id"] <> " [" <> n["Kind"] <> ", D=" <> ToString[n["Difficulty"]] <> ", " <> StringRiffle[n["Domains"], "/"] <> "] " <>
      SourceVaultKGText[n, "Label", lang]], Lookup[kg, "Nodes", {}]], "\n"];
  "以下は論文「" <> Lookup[kg, "Title", ""] <> "」の知識グラフのノード一覧です。聴き手は次の通り:\n" <>
  "  主題の理解度: " <> ToString[aud["Level"]] <> "  前提にできる領域と理解度: " <>
    StringRiffle[KeyValueMap[#1 <> "=" <> ToString[#2] &, aud["Knowledge"]], ", "] <>
  If[aud["Description"] =!= "", "  補足: " <> aud["Description"], ""] <> "\n\n" <>
  listing <> "\n\n" <>
  "この聴き手がノードを理解するのに足りない前提知識 (定義・基礎概念・古典的な結果・用語) を、最大 " <> ToString[OptionValue["MaxNodes"]] <>
  " 個の Layer=Background ノードとして追加し、各ノードから、それを前提とする既存ノードへ Prerequisite 辺 (From=新ノード, To=既存ノード) を張ってください。" <>
  "聴き手が既に知っている領域 (理解度が Difficulty 以上) のものは追加しないでください。各ノードには Label / Summary (1-2 文) / Points (2-4 行) / Difficulty / Domains / Year (古典的結果なら) を付けます。\n" <>
  "出力は差分 JSON {\"Nodes\": [...], \"Edges\": [...]} のみ。すべて " <> lang <> " で書く。"];

Options[SourceVaultKGSummaryPrompt] = {"Language" -> Automatic};
SourceVaultKGSummaryPrompt[kg_Association, tree_Association, OptionsPattern[]] := Module[
  {lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]], index = iKGNodeIndex[kg], lines},
  lines = Map[Function[id, StringRepeat["  ", tree["Depth"][id]] <> "- " <> id <> ": " <>
    SourceVaultKGText[index[id], "Label", lang]], tree["Order"]];
  "以下は発表の順序木 (字下げが階層、上から順に話す) です。\n" <> StringRiffle[lines, "\n"] <> "\n\n" <>
  "各内部ノード (子を持つノード) について、その部分木全体を 1-2 文で要約した Summary を書いてください。" <>
  "また、この順序で説明したとき破綻する箇所 (前提が後に出る / 飛躍 / 重複 / 抜け) があれば Issues に列挙してください。\n" <>
  "出力は JSON {\"Nodes\": [{\"Id\": \"...\", \"Summary\": \"...\"}], \"Issues\": [{\"NodeId\": \"...\", \"Issue\": \"...\", \"Fix\": \"...\"}]} のみ。言語は " <> lang <> "。"];

Options[SourceVaultKGTalkPrompt] = {"Style" -> "です・ます調、1 枚 2-6 文、冒頭に前のスライドからの接続を一言"};
SourceVaultKGTalkPrompt[outline_Association, OptionsPattern[]] := Module[{lines},
  lines = MapIndexed[Function[{s, i},
    ToString[First[i]] <> ". " <> s["Title"] <> "\n   points: " <> StringRiffle[s["Points"], " / "] <>
      If[s["Sub"] =!= {}, "\n   sub: " <> StringRiffle[Lookup[s["Sub"], "Label"], " / "], ""] <>
      "\n   talk(draft): " <> s["Talk"]], Lookup[outline, "Slides", {}]];
  "以下はスライドの構成 (順序・タイトル・箇条書きは確定。変更しない) と talk の下書きです。\n" <> StringRiffle[lines, "\n"] <> "\n\n" <>
  "各枚の talk を発表原稿として磨いてください (" <> OptionValue["Style"] <> ")。スライドに無い事実・数値を作らない。" <>
  "原稿は箇条書きと同じ順序で 1 項目につき 1〜2 文ずつ対応させ、箇条書きに無い話題から始めない (冒頭の概要説明が箇条書きと食い違うと聴き手が迷う)。部の入口の橋渡しの一文は残す。" <>
  "出力は JSON {\"Talks\": [{\"Slide\": 1, \"Talk\": \"...\"}]} のみ。言語は " <> Lookup[outline, "Language", "ja"] <> "。"];

Options[SourceVaultKGTranslatePrompt] = {};
SourceVaultKGTranslatePrompt[kg_Association, lang_String, OptionsPattern[]] := Module[
  {primary = Lookup[kg, "Language", "ja"], items},
  items = Map[Function[n, <|"Id" -> n["Id"], "Label" -> SourceVaultKGText[n, "Label", primary],
    "Summary" -> SourceVaultKGText[n, "Summary", primary], "Points" -> SourceVaultKGText[n, "Points", primary],
    "Talk" -> SourceVaultKGText[n, "Talk", primary]|>], Lookup[kg, "Nodes", {}]];
  "以下の知識グラフのノードのテキスト (Label / Summary / Points / Talk) を " <> lang <> " に翻訳してください。" <>
  "Id はそのまま、構造も変えず、専門用語は分野の標準訳を使います。空の項目は空のまま。\n" <>
  "出力は JSON {\"Nodes\": [{\"Id\": \"...\", \"Label\": \"...\", \"Summary\": \"...\", \"Points\": [...], \"Talk\": \"...\"}]} のみ。\n\n" <>
  iKGJSONString[<|"Nodes" -> items|>]];

(* ---------------- Graph 投影と View ---------------- *)

$kgKindColors = <|"Claim" -> RGBColor[0.88, 0.49, 0.08], "Conclusion" -> RGBColor[0.88, 0.49, 0.08],
  "Survey" -> RGBColor[0.88, 0.49, 0.08], "Section" -> RGBColor[0.55, 0.55, 0.55],
  "Background" -> RGBColor[0.35, 0.6, 0.6], "Equation" -> RGBColor[0.45, 0.42, 0.7],
  "Figure" -> RGBColor[0.45, 0.42, 0.7], "Result" -> RGBColor[0.62, 0.11, 0.11],
  "Experiment" -> RGBColor[0.62, 0.11, 0.11], "Method" -> RGBColor[0.3, 0.55, 0.5]|>;

Options[SourceVaultKGGraph] = {"Order" -> False, "Labels" -> True, "Language" -> Automatic};
SourceVaultKGGraph[kg_Association, OptionsPattern[]] := Module[
  {lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]], nodes = Lookup[kg, "Nodes", {}],
   edges = Lookup[kg, "Edges", {}], es, styles},
  If[TrueQ[OptionValue["Order"]], edges = Select[edges, TrueQ[#["Order"]] &]];
  es = If[TrueQ[#["Order"]], DirectedEdge[#["From"], #["To"]], UndirectedEdge[#["From"], #["To"]]] & /@ edges;
  styles = MapThread[Function[{e, ed}, e -> If[TrueQ[ed["Order"]], Directive[Thick, GrayLevel[0.25]], Directive[Dashed, GrayLevel[0.65]]]], {es, edges}];
  Graph[Lookup[nodes, "Id", {}], es,
    VertexLabels -> If[TrueQ[OptionValue["Labels"]],
      Map[(#["Id"] -> Placed[SourceVaultKGText[#, "Label", lang], Tooltip]) &, nodes], None],
    VertexStyle -> Map[(#["Id"] -> Lookup[$kgKindColors, #["Kind"], RGBColor[0.62, 0.11, 0.11]]) &, nodes],
    VertexSize -> Map[(#["Id"] -> 0.2 + 0.6 * #["Importance"]) &, nodes],
    EdgeStyle -> styles, GraphLayout -> "LayeredDigraphEmbedding"]];

SourceVaultKGToTopicItemGraph[kg_Association] := Module[
  {lang = Lookup[kg, "Language", "ja"], nodes = Lookup[kg, "Nodes", {}], edges = Lookup[kg, "Edges", {}]},
  <|"ObjectClass" -> "SourceVaultTopicItemGraph", "GraphId" -> "svtopicgraph:" <> Lookup[kg, "GraphId", ""],
    "Nodes" -> Map[<|"TopicItemRef" -> #["Id"], "Label" -> SourceVaultKGText[#, "Label", lang], "SupportParagraphs" -> {}|> &, nodes],
    "Edges" -> Map[<|"From" -> #["From"], "To" -> #["To"], "EdgeKind" -> #["EdgeKind"], "Weight" -> #["Weight"],
      "EvidenceRefs" -> #["EvidenceRefs"]|> &, edges],
    "MailSessionRefs" -> {}, "NodeCount" -> Length[nodes], "EdgeCount" -> Length[edges],
    "EdgeKindTally" -> Counts[Lookup[edges, "EdgeKind", {}]]|>];

iKGViewRows[rows_List] := Take[rows, UpTo[SourceVault`$SourceVaultKGViewMaxRows]];

SourceVaultKGView[kg_Association] := Module[{lang = Lookup[kg, "Language", "ja"]},
  Dataset[iKGViewRows[Map[Function[n,
    <|"Id" -> n["Id"], "Kind" -> n["Kind"], "Label" -> SourceVaultKGText[n, "Label", lang],
      "Layer" -> n["Layer"], "Difficulty" -> n["Difficulty"], "Importance" -> n["Importance"],
      "Domains" -> StringRiffle[n["Domains"], ", "], "Assets" -> Length[n["Assets"]],
      "Background" -> Replace[n["BackgroundRef"], None -> ""]|>], Lookup[kg, "Nodes", {}]]]]];

SourceVaultKGTreeView[kg_Association, tree_Association] := Module[{index = iKGNodeIndex[kg], lang = Lookup[kg, "Language", "ja"]},
  Dataset[iKGViewRows[Map[Function[id,
    <|"Label" -> StringRepeat["\[LongDash] ", tree["Depth"][id]] <> SourceVaultKGText[index[id], "Label", lang],
      "Depth" -> tree["Depth"][id], "Id" -> id, "Kind" -> index[id]["Kind"],
      "Importance" -> index[id]["Importance"]|>], tree["Order"]]]]];

SourceVaultKGPlanView[kg_Association, plan_Association] := Module[{index = iKGNodeIndex[kg], lang = Lookup[kg, "Language", "ja"]},
  Dataset[iKGViewRows[MapIndexed[Function[{s, i},
    <|"No" -> First[i], "Title" -> StringRepeat["\[LongDash] ", s["Depth"]] <> SourceVaultKGText[index[s["NodeId"]], "Label", lang],
      "Packed" -> StringRiffle[SourceVaultKGText[index[#], "Label", lang] & /@ s["Packed"], " / "],
      "Seconds" -> s["Seconds"], "Assets" -> Length[index[s["NodeId"]]["Assets"]],
      "Flags" -> StringRiffle[s["Flags"], ","]|>], plan["Slides"]]]]];

(* ---------------- 可視化 (v1.30) ----------------
   話の流れ (Story): 節を話の順に横へ、節の中身を縦に並べ、周辺知識は下の帯。
   節 (Sections): 節を横一列に並べ、節をまたぐ辺を弧で描く (太さ = 本数)。
   周辺 (Focus): 選んだノードの近傍をばねモデルで。全体 (Graph): 全ノードをばねモデルで。
   色 = 種類、大きさ = 重要度、形 = 層 (本文 丸・周辺知識 四角・関連研究 菱形)、枠 = 状態 (赤 = 未推敲、黒の太枠 = 選択中、
   点線 = 計画で他の枚に詰め込み)、右上の点 = 図・表あり、左上の点 = 質疑応答あり、薄い = 隠す・枝刈り。
   計画を重ねると枚番号 (#n) が付く *)

$kgVizEdgeGroups = <|
  "Order" -> {"Precedes", "LeadsTo", "Derives", "Motivates"},
  "Prerequisite" -> {"Prerequisite"},
  "Support" -> {"Supports", "Explains"},
  "Related" -> {"Contrasts", "RelatedTo", "Cites"},
  "Contains" -> {"Contains"}|>;
$kgVizEdgeColors = <|
  "Order" -> GrayLevel[0.4], "Prerequisite" -> RGBColor[0.88, 0.49, 0.08], "Support" -> RGBColor[0.2, 0.55, 0.3],
  "Related" -> RGBColor[0.55, 0.42, 0.72], "Contains" -> GrayLevel[0.78]|>;
$kgVizEdgeDash = <|"Order" -> {}, "Prerequisite" -> {4, 3}, "Support" -> {}, "Related" -> {1, 3}, "Contains" -> {}|>;
$kgVizDirectedGroups = {"Order", "Prerequisite", "Support", "Contains"};

iKGVizEdgeGroup[kind_] := First[Keys[Select[$kgVizEdgeGroups, MemberQ[#, kind] &]], "Related"];
iKGVizEdgeStyle[g_String] := Directive @@ Join[
  {Lookup[$kgVizEdgeColors, g, GrayLevel[0.5]], AbsoluteThickness[If[g === "Contains", 0.6, 1.0]]},
  If[Lookup[$kgVizEdgeDash, g, {}] === {}, {}, {AbsoluteDashing[$kgVizEdgeDash[g]]}],
  If[MemberQ[{"Prerequisite", "Related"}, g], {Opacity[0.55]}, {}]];

(* EdgeKinds: 群の名前 (Order / Prerequisite / Support / Related / Contains) か辺の種類の名前のリスト *)
iKGVizGroups[spec_, default_List] := Which[
  spec === Automatic, default,
  spec === All, Keys[$kgVizEdgeGroups],
  ListQ[spec], DeleteDuplicates[Map[If[KeyExistsQ[$kgVizEdgeGroups, #], #, iKGVizEdgeGroup[#]] &, Select[spec, StringQ]]],
  True, default];

$kgVizKindColors = <|
  "Claim" -> RGBColor[0.88, 0.49, 0.08], "Conclusion" -> RGBColor[0.88, 0.49, 0.08], "Survey" -> RGBColor[0.88, 0.49, 0.08],
  "Section" -> GrayLevel[0.55],
  "Concept" -> RGBColor[0.33, 0.47, 0.68], "Definition" -> RGBColor[0.33, 0.47, 0.68], "Example" -> RGBColor[0.5, 0.64, 0.84],
  "Method" -> RGBColor[0.28, 0.56, 0.5], "Experiment" -> RGBColor[0.28, 0.56, 0.5],
  "Result" -> RGBColor[0.62, 0.11, 0.11], "Question" -> RGBColor[0.72, 0.56, 0.28],
  "Equation" -> RGBColor[0.45, 0.4, 0.72], "Figure" -> RGBColor[0.45, 0.4, 0.72],
  "Background" -> RGBColor[0.3, 0.64, 0.64], "RelatedWork" -> RGBColor[0.82, 0.44, 0.12],
  "Assumed" -> GrayLevel[0.78]|>;

iKGVizT[lang_, ja_String, en_String] := If[lang === "ja", ja, en];
iKGVizShort[s_String, k_Integer] := If[StringLength[s] > k, StringTake[s, k - 1] <> "…", s];
iKGVizShort[_, _] := "";

iKGVizSectionIds[kg_Association] := With[{root = Lookup[kg, "Root", "root"]},
  DeleteCases[DeleteDuplicates[Join[
    Lookup[Select[kg["Nodes"], Lookup[#, "Kind", ""] === "Section" &], "Id", {}],
    Lookup[Select[kg["Edges"], #["EdgeKind"] === "Contains" &], "From", {}]]], root]];

iKGVizPlanInfo[plan_] := If[! AssociationQ[plan], <||>,
  Module[{slides = Select[Replace[Lookup[plan, "Slides", {}], Except[_List] -> {}], AssociationQ], head = <||>, packed = <||>},
    MapIndexed[Function[{s, i},
        If[StringQ[Lookup[s, "NodeId", None]] && ! KeyExistsQ[head, s["NodeId"]], head[s["NodeId"]] = First[i]];
        Do[If[StringQ[p] && ! KeyExistsQ[packed, p], packed[p] = First[i]], {p, Replace[Lookup[s, "Packed", {}], Except[_List] -> {}]}]],
      slides];
    <|"Head" -> head, "Packed" -> packed,
      "Pruned" -> Replace[Lookup[plan, "Pruned", {}], Except[_List] -> {}],
      "Assumed" -> Replace[Lookup[plan, "Assumed", {}], Except[_List] -> {}],
      "Hidden" -> Replace[Lookup[plan, "Hidden", {}], Except[_List] -> {}]|>]];

(* ノードごとの表示情報 *)
iKGVizInfo[kg_Association, lang_String, planInfo_Association, selected_] := Module[
  {root = Lookup[kg, "Root", "root"], secs = iKGVizSectionIds[kg]},
  Association[Map[Function[n, Module[{id = n["Id"], layer = Lookup[n, "Layer", "Paper"], kind = Lookup[n, "Kind", "Concept"],
      pts = SourceVaultKGText[n, "Points", lang], text = Replace[Lookup[n, "Text", ""], Except[_String] -> ""],
      assets = Select[Replace[Lookup[n, "Assets", {}], Except[_List] -> {}], AssociationQ],
      qa = Replace[Lookup[n, "QA", {}], {s_String :> {s}, Except[_List] -> {}}], sectionQ, headQ, assumed, pruned, slide},
    sectionQ = MemberQ[secs, id] || id === root;
    headQ = sectionQ;
    slide = Lookup[Lookup[planInfo, "Head", <||>], id, None];
    assumed = MemberQ[Lookup[planInfo, "Assumed", {}], id];
    pruned = MemberQ[Lookup[planInfo, "Pruned", {}], id];
    id -> <|"Id" -> id, "Kind" -> kind, "Layer" -> layer,
      "Label" -> SourceVaultKGText[n, "Label", lang],
      "Importance" -> Replace[Lookup[n, "Importance", 0.5], Except[_?NumericQ] -> 0.5],
      "Section" -> sectionQ, "Root" -> id === root,
      "Group" -> Which[kind === "RelatedWork", "Related", layer =!= "Paper", "Background", True, "Paper"],
      "Shape" -> Which[headQ, "Header", kind === "RelatedWork", "Diamond", layer =!= "Paper", "Square", True, "Disk"],
      "ColorKey" -> Which[assumed, "Assumed", layer =!= "Paper" && kind =!= "RelatedWork", "Background", True, kind],
      "Unrefined" -> ! sectionQ && layer === "Paper" && StringTrim[text] =!= "" && ! MatchQ[pts, {__String}],
      "Hidden" -> TrueQ[Lookup[n, "Hidden", False]],
      "Assets" -> Length[assets] > 0, "AssetTypes" -> DeleteDuplicates[Lookup[assets, "Type", {}]],
      "QA" -> AnyTrue[qa, StringQ[#] && StringTrim[#] =!= "" &],
      "Slide" -> slide, "Packed" -> KeyExistsQ[Lookup[planInfo, "Packed", <||>], id] && slide === None,
      "PackedInto" -> Lookup[Lookup[planInfo, "Packed", <||>], id, None],
      "Pruned" -> pruned, "Assumed" -> assumed,
      "Faded" -> TrueQ[Lookup[n, "Hidden", False]] || pruned,
      "Selected" -> id === selected,
      "Order" -> Replace[Lookup[n, "Order", None], Except[_?NumericQ] -> 10.^6]|>]],
    kg["Nodes"]]]];

iKGVizTip[n_Association, i_Association, lang_String] := Module[
  {pts = SourceVaultKGText[n, "Points", lang], lead = SourceVaultKGText[n, "Lead", lang],
   cite = SourceVaultKGText[n, "Cite", lang], text = Replace[Lookup[n, "Text", ""], Except[_String] -> ""], flags = {}},
  If[TrueQ[i["Unrefined"]], AppendTo[flags, iKGVizT[lang, "未推敲 (要点なし)", "not refined"]]];
  If[TrueQ[i["Hidden"]], AppendTo[flags, iKGVizT[lang, "隠す (スライドにしない)", "hidden"]]];
  If[IntegerQ[i["Slide"]], AppendTo[flags, iKGVizT[lang, "計画の " <> ToString[i["Slide"]] <> " 枚目", "slide " <> ToString[i["Slide"]]]]];
  If[IntegerQ[i["PackedInto"]] && ! IntegerQ[i["Slide"]],
    AppendTo[flags, iKGVizT[lang, ToString[i["PackedInto"]] <> " 枚目に詰め込み", "packed into slide " <> ToString[i["PackedInto"]]]]];
  If[TrueQ[i["Pruned"]], AppendTo[flags, iKGVizT[lang, "枝刈り (時間に入らない)", "pruned"]]];
  If[TrueQ[i["Assumed"]], AppendTo[flags, iKGVizT[lang, "聴き手は知っている (省く)", "assumed known"]]];
  If[i["AssetTypes"] =!= {}, AppendTo[flags, iKGVizT[lang, "図: ", "assets: "] <> StringRiffle[i["AssetTypes"], ", "]]];
  If[TrueQ[i["QA"]], AppendTo[flags, iKGVizT[lang, "質疑応答あり", "has Q&A"]]];
  Framed[Pane[Column[Join[
      {Style[i["Label"], Bold, 12],
       Style[i["Id"] <> " · " <> i["Kind"] <> " · " <> i["Layer"] <> " · " <> iKGVizT[lang, "重要度 ", "importance "] <>
         ToString[Round[i["Importance"], 0.01]], 9, GrayLevel[0.4]]},
      If[lead =!= "", {Style[lead, 10]}, {}],
      If[MatchQ[pts, {__String}], {Column[Style["• " <> #, 10] & /@ Take[pts, UpTo[6]], Spacings -> 0.1]}, {}],
      If[flags =!= {}, {Style[StringRiffle[flags, " / "], 9, RGBColor[0.55, 0.3, 0.1]]}, {}],
      If[cite =!= "", {Style[iKGVizT[lang, "出典: ", "source: "] <> iKGVizShort[cite, 160], 9, GrayLevel[0.35]]}, {}],
      If[StringTrim[text] =!= "" && ! MatchQ[pts, {__String}], {Style[iKGVizShort[StringReplace[text, "\n" -> " "], 240], 9, GrayLevel[0.3]]}, {}]],
    Spacings -> 0.35], 380], Background -> White, FrameStyle -> GrayLevel[0.8], FrameMargins -> 6]];

(* ノードの図形 (位置 p、半径 r) *)
iKGVizPrim[p : {x_, y_}, r_, i_Association] := Module[{col, shape, outline, marks = {}},
  col = Lookup[$kgVizKindColors, i["ColorKey"], GrayLevel[0.5]];
  shape = Switch[i["Shape"],
    "Square", Rectangle[{x - r, y - r}, {x + r, y + r}],
    "Diamond", Polygon[{{x, y + 1.3 r}, {x + 1.3 r, y}, {x, y - 1.3 r}, {x - 1.3 r, y}}],
    "Header", Rectangle[{x - 1.7 r, y - 0.75 r}, {x + 1.7 r, y + 0.75 r}, RoundingRadius -> 0.35 r],
    _, Disk[p, r]];
  outline = Which[
    TrueQ[i["Selected"]], Directive[Black, AbsoluteThickness[2.6]],
    TrueQ[i["Unrefined"]], Directive[RGBColor[0.85, 0.1, 0.1], AbsoluteThickness[1.8]],
    TrueQ[i["Packed"]], Directive[GrayLevel[0.25], AbsoluteThickness[1.], AbsoluteDashing[{2, 2}]],
    IntegerQ[i["Slide"]], Directive[GrayLevel[0.1], AbsoluteThickness[1.4]],
    True, Directive[White, AbsoluteThickness[0.6]]];
  If[TrueQ[i["Assets"]], AppendTo[marks, {RGBColor[0.45, 0.4, 0.72], Disk[{x + 0.95 r, y + 0.95 r}, 0.38 r]}]];
  If[TrueQ[i["QA"]], AppendTo[marks, {RGBColor[0.82, 0.44, 0.12], Disk[{x - 0.95 r, y + 0.95 r}, 0.38 r]}]];
  {Opacity[If[TrueQ[i["Faded"]], 0.25, 1.]], EdgeForm[outline], FaceForm[col], shape, EdgeForm[None], marks}];

iKGVizLabelText[i_Association, k_Integer] := (If[IntegerQ[i["Slide"]], "#" <> ToString[i["Slide"]] <> " ", ""] <> iKGVizShort[i["Label"], k]);

iKGVizLabelQ[i_Association, mode_] := Which[
  mode === All, True,
  mode === None, TrueQ[i["Section"]],
  True, TrueQ[i["Section"]] || i["Importance"] >= 0.75 || IntegerQ[i["Slide"]] || TrueQ[i["Selected"]]];

(* クリックとツールチップを付けたノード *)
iKGVizNode[p_, r_, i_Association, n_Association, lang_, onClick_] := With[{prim = Tooltip[iKGVizPrim[p, r, i], iKGVizTip[n, i, lang]]},
  If[onClick === None, prim,
    With[{f = onClick, id = i["Id"]}, EventHandler[prim, {"MouseClicked" :> f[id]}]]]];

iKGVizEdgePrims[edges_List, coords_Association, info_Association, groups_List, radius_, lang_, sameColumn_, arrow_ : 0.006] := Module[{out = {}},
  Do[Module[{g = iKGVizEdgeGroup[e["EdgeKind"]], a = e["From"], b = e["To"], p1, p2, c, d, curve},
      If[MemberQ[groups, g] && KeyExistsQ[coords, a] && KeyExistsQ[coords, b] && a =!= b,
        p1 = coords[a]; p2 = coords[b]; d = p2 - p1;
        c = If[TrueQ[sameColumn] && Abs[d[[1]]] < 0.3,
          (p1 + p2)/2 + {0.35 + 0.18 * Abs[d[[2]]], 0},
          (p1 + p2)/2 + {0, 0.12 * Norm[d]}];
        curve = BezierCurve[{p1, c, p2}];
        AppendTo[out, Tooltip[
          {iKGVizEdgeStyle[g], Arrowheads[{{arrow, 1}}], If[MemberQ[$kgVizDirectedGroups, g], Arrow[curve, {radius[a], radius[b]}], curve]},
          e["EdgeKind"] <> ": " <> iKGVizShort[info[a]["Label"], 30] <> " → " <> iKGVizShort[info[b]["Label"], 30]]]]],
    {e, edges}];
  out];

iKGVizRadius[i_Association] := If[TrueQ[i["Section"]], 0.2, 0.09 + 0.14 * Clip[i["Importance"], {0, 1}]];

(* ---- 話の流れ ---- *)
iKGVizStory[kg_, info_, index_, lang_, groups_, labels_, onClick_, keepQ_] := Module[
  {root = Lookup[kg, "Root", "root"], secs, parent, secOf, cols, colW = 2.6, rowH = 0.62, coords = <||>, maxRows = 0,
   bg, bandY, buckets = <||>, nodes, prims, edges, radius, xmax, ymin, colIndex, width},
  secs = SortBy[Select[iKGVizSectionIds[kg], KeyExistsQ[info, #] &], {info[#]["Order"] &, # &}];
  parent = Association[Map[#["To"] -> #["From"] &, Reverse[Select[kg["Edges"], #["EdgeKind"] === "Contains" &]]]];
  secOf[id_] := Module[{c = id, k = 0}, While[k < 30, c = Lookup[parent, c, None]; k++;
    Which[c === None, Return[None, Module], MemberQ[secs, c], Return[c, Module], c === root, Return[root, Module]]]; None];
  colIndex = Association[Join[{root -> 0}, MapIndexed[#1 -> First[#2] &, secs]]];
  (* 列: 0 = 根の直下、1.. = 節の順 *)
  cols = GroupBy[Select[Values[info], ! TrueQ[#["Section"]] && keepQ[#] &], With[{s = secOf[#["Id"]]}, If[s === None, None, s]] &];
  Do[coords[id] = {colW * colIndex[id], 0.}, {id, Keys[colIndex]}];
  KeyValueMap[Function[{s, members},
      If[s =!= None,
        With[{sorted = SortBy[members, {#["Order"] &, #["Id"] &}]},
          maxRows = Max[maxRows, Length[sorted]];
          Do[coords[sorted[[j, "Id"]]] = {colW * colIndex[s], -rowH * j}, {j, Length[sorted]}]]]],
    cols];
  (* 周辺知識 (どの節にも入らないノード): 下の帯。つながるノードの列の平均の位置に *)
  bg = Lookup[cols, Key[None], {}];
  bandY = -rowH * (maxRows + 1.6);
  Do[Module[{nbrs, xs, k},
      nbrs = Join[Lookup[Select[kg["Edges"], #["From"] === b["Id"] &], "To", {}], Lookup[Select[kg["Edges"], #["To"] === b["Id"] &], "From", {}]];
      xs = Lookup[coords, Select[nbrs, KeyExistsQ[coords, #] &]][[All, 1]];
      k = If[xs === {}, Length[secs] + 1, Round[Mean[xs]/colW]];
      buckets[k] = Append[Lookup[buckets, k, {}], b["Id"]]],
    {b, SortBy[bg, {#["Order"] &, #["Id"] &}]}];
  KeyValueMap[Function[{k, ids}, Do[coords[ids[[j]]] = {colW * k + 0.25, bandY - rowH * (j - 1)}, {j, Length[ids]}]], buckets];
  radius = Association[Map[#["Id"] -> iKGVizRadius[#] &, Values[info]]];
  xmax = colW * (Max[Append[Values[colIndex], 0]] + 2);
  width = Round[38 * (xmax + 0.8)];
  edges = iKGVizEdgePrims[kg["Edges"], coords, info, groups, radius, lang, True, 9./width];
  nodes = KeyValueMap[Function[{id, p},
      With[{i = info[id]}, {
        iKGVizNode[p, radius[id], i, index[id], lang, onClick],
        If[iKGVizLabelQ[i, labels],
          If[TrueQ[i["Section"]],
            Text[Style[iKGVizShort[If[TrueQ[i["Root"]], iKGVizT[lang, "(全体) ", "(top) "], ""] <> i["Label"], 12], 8, Bold, GrayLevel[0.2]],
              p + {0, If[OddQ[Round[p[[1]]/colW]], 0.62, 0.3]}, {0, -1}],
            Text[Style[iKGVizLabelText[i, 12], 7, GrayLevel[0.15]], p + {radius[id] + 0.06, 0}, {-1, 0}]],
          Nothing]}]],
    coords];
  ymin = Min[Append[Values[coords][[All, 2]], 0.]] - rowH;
  prims = {edges, nodes,
    If[buckets =!= <||>, Text[Style[iKGVizT[lang, "周辺知識 (どの節にも入らない前提)", "background (outside the sections)"], 9, Italic, GrayLevel[0.4]],
      {-0.3, bandY + 0.45}, {-1, 0}], Nothing]};
  Graphics[prims, PlotRange -> {{-0.8, xmax}, {ymin, 1.05}}, ImageSize -> width,
    ImagePadding -> 6, Background -> White]];

(* ---- 節の概観 (弧の図) ---- *)
iKGVizSections[kg_, info_, index_, lang_, groups_, onClick_] := Module[
  {root = Lookup[kg, "Root", "root"], secs, parent, secOf, members = <||>, x = <||>, gap = 1.7, cross = <||>, bgCount = <||>,
   prims = {}, bgX, maxC, up, down},
  secs = SortBy[Select[iKGVizSectionIds[kg], KeyExistsQ[info, #] &], {info[#]["Order"] &, # &}];
  parent = Association[Map[#["To"] -> #["From"] &, Reverse[Select[kg["Edges"], #["EdgeKind"] === "Contains" &]]]];
  secOf[id_] := Module[{c = id, k = 0}, If[MemberQ[secs, id], Return[id, Module]];
    While[k < 30, c = Lookup[parent, c, None]; k++;
      Which[c === None, Return[None, Module], MemberQ[secs, c], Return[c, Module], c === root, Return[root, Module]]]; None];
  Do[x[s] = gap * i, {s, secs}, {i, {Position[secs, s][[1, 1]]}}];
  x[root] = 0.;
  bgX = gap * (Length[secs] + 1);
  Do[With[{s = secOf[id]}, members[s] = Append[Lookup[members, Key[s], {}], id]], {id, Keys[info]}];
  Do[Module[{g = iKGVizEdgeGroup[e["EdgeKind"]], sa = secOf[e["From"]], sb = secOf[e["To"]]},
      If[MemberQ[groups, g] && g =!= "Contains",
        Which[
          sa =!= None && sb =!= None && sa =!= sb, cross[{sa, sb}] = Append[Lookup[cross, Key[{sa, sb}], {}], g],
          sa === None && sb =!= None, bgCount[sb] = Lookup[bgCount, sb, 0] + 1,
          sb === None && sa =!= None, bgCount[sa] = Lookup[bgCount, sa, 0] + 1]]],
    {e, kg["Edges"]}];
  maxC = Max[1, Max[Append[Length /@ Values[cross], 1]]];
  up = 0.5; down = 0.5;
  KeyValueMap[Function[{pair, gs}, Module[{xa = x[pair[[1]]], xb = x[pair[[2]]], g = First[Commonest[gs]]},
      AppendTo[prims, Tooltip[{Lookup[$kgVizEdgeColors, g, GrayLevel[0.5]], Opacity[0.7],
          AbsoluteThickness[0.8 + 4 * Length[gs]/maxC],
          Arrowheads[{{0.008, 1}}],
          Arrow[BezierCurve[{{xa, 0.25}, {(xa + xb)/2, (up = Max[up, 0.3 + 0.2 * Abs[xb - xa]]; 0.3 + 0.2 * Abs[xb - xa])}, {xb, 0.25}}]]},
        info[pair[[1]]]["Label"] <> " → " <> info[pair[[2]]]["Label"] <> ": " <> ToString[Length[gs]] <> iKGVizT[lang, " 本 (", " edges ("] <>
          StringRiffle[KeyValueMap[#1 <> " " <> ToString[#2] &, Counts[gs]], ", "] <> ")"]]]],
    cross];
  KeyValueMap[Function[{s, c}, AppendTo[prims, Tooltip[{RGBColor[0.3, 0.64, 0.64], Opacity[0.6], AbsoluteThickness[0.8 + Min[c, 12]/2.],
        BezierCurve[{{bgX, -0.25}, {(bgX + x[s])/2, (down = Max[down, 0.3 + 0.12 * Abs[bgX - x[s]]]; -0.3 - 0.12 * Abs[bgX - x[s]])}, {x[s], -0.25}}]},
      iKGVizT[lang, "周辺知識 との辺 ", "background edges "] <> ToString[c]]]],
    Select[bgCount, # > 0 &]];
  Do[Module[{ids = DeleteCases[Lookup[members, Key[s], {}], s], i = info[s], nUn, nFig, nQA, r},
      nUn = Count[info /@ ids, j_ /; TrueQ[j["Unrefined"]]];
      nFig = Count[info /@ ids, j_ /; TrueQ[j["Assets"]]];
      nQA = Count[info /@ ids, j_ /; TrueQ[j["QA"]]];
      r = 0.12 + 0.05 * Sqrt[Length[ids]];
      AppendTo[prims, {
        With[{prim = Tooltip[{EdgeForm[If[nUn > 0, Directive[RGBColor[0.85, 0.1, 0.1], AbsoluteThickness[2]],
              If[TrueQ[i["Selected"]], Directive[Black, AbsoluteThickness[2.6]], Directive[White]]]],
            FaceForm[If[TrueQ[i["Root"]], $kgVizKindColors["Claim"], GrayLevel[0.55]]], Disk[{x[s], 0}, Min[r, 0.7]]},
          Column[{Style[i["Label"], Bold, 12],
            Style[SourceVaultKGText[index[s], "Summary", lang], 10],
            Style[iKGVizT[lang, "ノード ", "nodes "] <> ToString[Length[ids]] <> iKGVizT[lang, " / 図 ", " / figures "] <> ToString[nFig] <>
              iKGVizT[lang, " / 質疑応答 ", " / Q&A "] <> ToString[nQA] <> iKGVizT[lang, " / 未推敲 ", " / unrefined "] <> ToString[nUn], 9, GrayLevel[0.35]]},
            Spacings -> 0.3]]},
          If[onClick === None, prim, With[{f = onClick, id = s}, EventHandler[prim, {"MouseClicked" :> f[id]}]]]],
        Text[Style[iKGVizShort[i["Label"], 14] <> " (" <> ToString[Length[ids]] <> ")", 8, GrayLevel[0.15]], {x[s], -0.05 - Min[r, 0.7]}, {-1, 0}, {0, -1}]}]],
    {s, Prepend[secs, root]}];
  With[{nbg = Length[Lookup[members, Key[None], {}]]},
    If[nbg > 0,
      AppendTo[prims, {Tooltip[{FaceForm[$kgVizKindColors["Background"]], EdgeForm[White],
          Rectangle[{bgX - 0.25, -0.25}, {bgX + 0.25, 0.25}]}, iKGVizT[lang, "周辺知識 ", "background "] <> ToString[nbg]],
        Text[Style[iKGVizT[lang, "周辺知識 (", "background ("] <> ToString[nbg] <> ")", 8, GrayLevel[0.15]], {bgX, -0.35}, {-1, 0}, {0, -1}]}]]];
  Graphics[prims, PlotRange -> {{-0.9, bgX + 0.9}, {-Max[down / 2 + 0.2, 2.4], up / 2 + 0.4}},
    ImageSize -> Round[44 * (bgX + 1.8)], ImagePadding -> 6, Background -> White]];

(* ---- 周辺 / 全体 (ばねモデル) ---- *)
iKGVizSpring[kg_, info_, index_, lang_, groups_, labels_, onClick_, ids_List, focus_] := Module[{es, radius, g},
  es = Select[kg["Edges"], MemberQ[ids, #["From"]] && MemberQ[ids, #["To"]] && #["From"] =!= #["To"] &&
    MemberQ[groups, iKGVizEdgeGroup[#["EdgeKind"]]] &];
  radius = Association[Map[# -> 0.6 * iKGVizRadius[info[#]] &, ids]];
  g = Graph[ids, UndirectedEdge[#["From"], #["To"]] & /@ es, GraphLayout -> "SpringElectricalEmbedding"];
  With[{coords = AssociationThread[VertexList[g], GraphEmbedding[g]]},
    Graphics[{
      iKGVizEdgePrims[es, coords, info, groups, radius, lang, False, If[Length[ids] <= 40, 9./700, 9./1100]],
      KeyValueMap[Function[{id, p}, With[{i = info[id]}, {
          iKGVizNode[p, radius[id], i, index[id], lang, onClick],
          If[iKGVizLabelQ[i, labels] || id === focus || Length[ids] <= 40,
            Text[Style[iKGVizLabelText[i, 16], If[id === focus, 9, 7], If[id === focus, Bold, Plain], GrayLevel[0.15]],
              p + {0, -radius[id] - 0.04}, {0, 1}], Nothing]}]],
        coords]},
      ImageSize -> If[Length[ids] <= 40, 700, 1100], ImagePadding -> 10, Background -> White]]];

Options[SourceVaultKGVisualize] = {"View" -> "Story", "Focus" -> None, "Radius" -> 1, "EdgeKinds" -> Automatic,
  "Layers" -> All, "Labels" -> Automatic, "Plan" -> None, "Selected" -> None, "OnClick" -> None,
  "Language" -> Automatic, "Legend" -> True, "Hidden" -> True};
SourceVaultKGVisualize[kg_Association, OptionsPattern[]] := Module[
  {lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]], view = OptionValue["View"],
   info, index, groups, layers, keepQ, g, planInfo, focus = OptionValue["Focus"], ids},
  If[! ListQ[Lookup[kg, "Nodes", None]] || kg["Nodes"] === {}, Return[Failure["NoNodes", <|"MessageTemplate" -> "the graph has no nodes"|>]]];
  index = iKGNodeIndex[kg];
  planInfo = iKGVizPlanInfo[OptionValue["Plan"]];
  info = iKGVizInfo[kg, lang, planInfo, OptionValue["Selected"]];
  layers = Replace[OptionValue["Layers"], All -> {"Paper", "Background", "Related"}];
  If[! ListQ[layers], layers = {"Paper", "Background", "Related"}];
  keepQ = Function[i, (TrueQ[i["Section"]] || MemberQ[layers, i["Group"]]) &&
    (TrueQ[OptionValue["Hidden"]] || ! TrueQ[i["Hidden"]])];
  g = Switch[view,
    "Sections",
      iKGVizSections[kg, info, index, lang, iKGVizGroups[OptionValue["EdgeKinds"], {"Order", "Prerequisite", "Support", "Related"}],
        OptionValue["OnClick"]],
    "Focus",
      If[! (StringQ[focus] && KeyExistsQ[info, focus]),
        Return[Failure["NoFocus", <|"MessageTemplate" -> "choose a node to focus on (\"Focus\" -> id)"|>]]];
      With[{gs = iKGVizGroups[OptionValue["EdgeKinds"], Keys[$kgVizEdgeGroups]]},
        ids = Select[VertexList[NeighborhoodGraph[
          Graph[Keys[info], UndirectedEdge[#["From"], #["To"]] & /@ Select[kg["Edges"],
            MemberQ[gs, iKGVizEdgeGroup[#["EdgeKind"]]] && #["From"] =!= #["To"] &]],
          focus, Max[1, Min[3, Replace[OptionValue["Radius"], Except[_Integer] -> 1]]]]], keepQ[info[#]] || # === focus &];
        info[focus] = Append[info[focus], "Selected" -> True];
        iKGVizSpring[kg, info, index, lang, gs, OptionValue["Labels"], OptionValue["OnClick"], ids, focus]],
    "Graph",
      With[{gs = iKGVizGroups[OptionValue["EdgeKinds"], {"Order", "Prerequisite", "Support", "Related", "Contains"}]},
        iKGVizSpring[kg, info, index, lang, gs, OptionValue["Labels"], OptionValue["OnClick"],
          Select[Keys[info], keepQ[info[#]] &], None]],
    _,
      iKGVizStory[kg, info, index, lang, iKGVizGroups[OptionValue["EdgeKinds"], {"Order", "Prerequisite", "Support"}],
        OptionValue["Labels"], OptionValue["OnClick"], keepQ]];
  If[TrueQ[OptionValue["Legend"]], Labeled[g, SourceVaultKGLegend[lang], Bottom], g]];
SourceVaultKGVisualize[_, ___] := Failure["NotAGraph", <|"MessageTemplate" -> "expected a knowledge graph Association"|>];

SourceVaultKGLegend[lang_String : "ja", perRow_Integer : 0] := Module[{sw, kinds, edges, marks, rows},
  sw[col_, shape_] := Graphics[{FaceForm[col], EdgeForm[White], Switch[shape,
      "Square", Rectangle[{-0.8, -0.8}, {0.8, 0.8}], "Diamond", Polygon[{{0, 1}, {1, 0}, {0, -1}, {-1, 0}}],
      "Header", Rectangle[{-1.3, -0.6}, {1.3, 0.6}, RoundingRadius -> 0.3], _, Disk[]]}, ImageSize -> 12];
  kinds = {
    {sw[$kgVizKindColors["Claim"], "Disk"], iKGVizT[lang, "主張・結論", "claim"]},
    {sw[$kgVizKindColors["Section"], "Header"], iKGVizT[lang, "節", "section"]},
    {sw[$kgVizKindColors["Concept"], "Disk"], iKGVizT[lang, "概念・定義", "concept"]},
    {sw[$kgVizKindColors["Method"], "Disk"], iKGVizT[lang, "方法・実験", "method"]},
    {sw[$kgVizKindColors["Result"], "Disk"], iKGVizT[lang, "結果", "result"]},
    {sw[$kgVizKindColors["Figure"], "Disk"], iKGVizT[lang, "式・図", "equation/figure"]},
    {sw[$kgVizKindColors["Question"], "Disk"], iKGVizT[lang, "問い", "question"]},
    {sw[$kgVizKindColors["Background"], "Square"], iKGVizT[lang, "周辺知識", "background"]},
    {sw[$kgVizKindColors["RelatedWork"], "Diamond"], iKGVizT[lang, "関連研究", "related work"]}};
  edges = Map[{Graphics[{iKGVizEdgeStyle[#[[1]]], AbsoluteThickness[1.8], Arrowheads[0.3],
        If[MemberQ[$kgVizDirectedGroups, #[[1]]], Arrow[{{0, 0}, {1, 0}}], Line[{{0, 0}, {1, 0}}]]},
      ImageSize -> {28, 10}, PlotRange -> {{-0.05, 1.05}, {-0.2, 0.2}}, AspectRatio -> Full], #[[2]]} &,
    {{"Order", iKGVizT[lang, "順序", "order"]}, {"Prerequisite", iKGVizT[lang, "前提", "prerequisite"]},
     {"Support", iKGVizT[lang, "支え", "support"]}, {"Related", iKGVizT[lang, "対比・関連", "related"]},
     {"Contains", iKGVizT[lang, "包含", "contains"]}}];
  marks = {
    {Graphics[{FaceForm[GrayLevel[0.85]], EdgeForm[Directive[RGBColor[0.85, 0.1, 0.1], AbsoluteThickness[1.8]]], Disk[]}, ImageSize -> 12], iKGVizT[lang, "未推敲", "unrefined"]},
    {Graphics[{FaceForm[GrayLevel[0.85]], EdgeForm[Directive[Black, AbsoluteThickness[2.4]]], Disk[]}, ImageSize -> 12], iKGVizT[lang, "選択中", "selected"]},
    {Graphics[{FaceForm[GrayLevel[0.85]], EdgeForm[Directive[GrayLevel[0.25], AbsoluteDashing[{2, 2}]]], Disk[]}, ImageSize -> 12], iKGVizT[lang, "詰め込み", "packed"]},
    {Graphics[{FaceForm[GrayLevel[0.85]], Disk[], RGBColor[0.45, 0.4, 0.72], Disk[{0.9, 0.9}, 0.4]}, ImageSize -> 12], iKGVizT[lang, "図・表あり", "has figure"]},
    {Graphics[{FaceForm[GrayLevel[0.85]], Disk[], RGBColor[0.82, 0.44, 0.12], Disk[{-0.9, 0.9}, 0.4]}, ImageSize -> 12], iKGVizT[lang, "質疑応答あり", "has Q&A"]},
    {Graphics[{Opacity[0.25], GrayLevel[0.3], Disk[]}, ImageSize -> 12], iKGVizT[lang, "隠す・枝刈り", "hidden/pruned"]},
    {Style["#n", 8], iKGVizT[lang, "計画の枚番号", "slide no. in the plan"]}};
  rows = If[perRow > 0, Flatten[Map[Partition[#, UpTo[perRow]] &, {kinds, edges, marks}], 1], {kinds, edges, marks}];
  Column[Map[Row[Riffle[Map[Row[{#[[1]], " ", Style[#[[2]], 8]}] &, #], Spacer[10]]] &, rows], Spacings -> 0.4]];

End[]

EndPackage[]

Print[Style["SourceVault_knowledgegraph.wl がロードされました。", Bold]];
Print["
  SourceVaultKGFromJSON[json] / SourceVaultKGMerge[kg, delta]      → LLM 応答の取り込み (検証つき)
  SourceVaultKGSave / Load / List[]                                  → <root>/knowledgegraph/graphs/
  SourceVaultKGAudience[spec] / SourceVaultKGScores[kg, aud]         → 聴き手モデルと必要度
  SourceVaultKGOrderedTree[kg] / OrderedTrees / Verify               → 最小全域順序木と破綻検証
  SourceVaultKGPlan[kg, tree, \"Slides\"->n, \"Audience\"->..]        → 詰め込み・枝刈り計画
  SourceVaultKGOutline[kg, plan] / OutlineToMarkdown                 → 言語別アウトライン → シナリオ md
  SourceVaultKGCompose[{kg1, kg2}] / BackgroundLink / SuggestPastSlides
  SourceVaultKGGraph / View / TreeView / PlanView / ToTopicItemGraph
"];
