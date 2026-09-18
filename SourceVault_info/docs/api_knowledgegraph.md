# SourceVault_knowledgegraph API リファレンス

発表用知識グラフ (KG) 層。論文の内容と周辺知識を「関連度 + 順序制約 (因果 / 年代 / 導出 / 難易度)」つきのグラフとして保持し、聴き手と時間 (枚数・分) を与えるとスライド構成を決定的に計算する。コンテキスト: `SourceVault\`` (private `` `KGPrivate` ``)。仕様: `SlideWorkflow_info/design/slide_knowledge_graph_spec_v0_1.md`。

- **LLM も FrontEnd も呼ばない** (service-loadable)。プロンプトは純関数、応答 JSON は検証して取り込む。
- 辺レコードは oopsseed の TopicItemGraph と同形 `{From, To, EdgeKind, Weight, EvidenceRefs}` + `Order / OrderKind / Confidence`。
- 保存先: `SourceVaultCoreRoot[]/knowledgegraph/graphs/<graphId>.json` (前版は `graphs/history/`)、共有周辺知識 `background/bg-<slug>.json`。
- privacy: ノードの `PrivacyLevel` (0-1、大きいほど厳格)。アウトライン化は `ReleaseCeiling` (既定 0.5) 超を fail-closed で落とす。

## 定数

| 記号 | 既定 | 意味 |
|---|---|---|
| `$SourceVaultKGRoot` | Automatic | 保存ルート (テストでは隔離ディレクトリを与える) |
| `$SourceVaultKGEdgeKinds` | 表 | 辺種別 → `<\|Order, OrderKind, Parent, Affinity\|>`。**順序制約のある種別はすべて From を To より先に提示する向き** |
| `$SourceVaultKGNodeKinds` | 一覧 | Claim / Concept / Definition / Method / Experiment / Result / Equation / Figure / Question / Conclusion / Background / Section / Survey / RelatedWork / Example (v1.30: シナリオ KG の関連研究の紹介と例) |
| `$SourceVaultKGAudiencePresets` | 表 | 聴き手プリセット (小学生〜研究者、ITエンジニア、高校数学III、一般相対論、英語別名) |
| `$SourceVaultKGDomainAliases` | 表 | 領域名の英→日別名 |
| `$SourceVaultKGViewMaxRows` | 200 | View の最大行数 |
| `$SourceVaultKGTooHard` | 0.6 | need (難易度 − 既知度) がこれを超えると TooHard |

## 辺種別

| EdgeKind | Order | OrderKind | 意味 |
|---|---|---|---|
| Prerequisite | ✓ | Difficulty | From は To の前提 |
| Precedes | ✓ | Temporal | 年代・実験の順 |
| Derives | ✓ | Derivation | To は From から導かれる |
| Motivates | ✓ | Narrative | 問い → 手法 |
| LeadsTo | ✓ | Causal | 結果 → 結論 |
| Contains | ✓ | Hierarchy | 節が下位を含む |
| Supports / Explains | – | – | 証拠・解説 (主張の下に付く) |
| Contrasts / RelatedTo / Cites | – | – | 関連度のみ |

## 取り込み・保存

### SourceVaultKGRoot[] → String
知識グラフ層の保存ディレクトリ (無ければ作成)。`$SourceVaultKGRoot` が Automatic なら `SourceVaultCoreRoot[]/knowledgegraph`、CoreRoot が無ければ `LOCALAPPDATA/SourceVault/knowledgegraph`。

### SourceVaultKGNew[graphId, opts] → Association
空の KG。opts: `"Title"` / `"Language"` (既定 `"ja"`) / `"Sources"` / `"Kind"` / `"PrivacyLevel"`。KG の `"Kind"` は Paper / Survey / Background / Scenario (文書の無い発表の筋書きから作った KG。検証で知らない値は Paper に丸める)。

### SourceVaultKGValidate[kg] → Association
正規化 (既定値・未知の辺種別 → RelatedTo・端点無し/自己ループ除去・Root 決定) + `"Warnings"`。

### SourceVaultKGFromJSON[json | assoc] → Association | Failure
LLM 応答 (```json フェンス可) から KG。ノード 0 なら Failure。

### SourceVaultKGToJSON[kg] → String

### SourceVaultKGMerge[kg, delta, "Language" -> lang] → Association | Failure
差分 (ノード追加・上書き、辺追加) を取り込む。`"Language"->"en"` なら delta の文字列テキストはその言語の訳として併記 (`Label` が `<|"ja"->.., "en"->..|>` になる)。

### SourceVaultKGNode[kg, id] / SourceVaultKGText[node, key, lang]
言語別テキスト取得 (Label / Summary / Talk / Cite / Lead は String、Points / Details は List)。無い言語は主言語 → 任意へ落ちる。

### SourceVaultKGSave[kg] / SourceVaultKGLoad[graphId] / SourceVaultKGList[] / SourceVaultKGDelete[graphId]

## 聴き手

### SourceVaultKGAudience[spec] → Association
`"高校生, 電気化学=0.3, 高校数学III"` / リスト / `<|"Level", "Knowledge", "Presets", ..|>` → `<|"Level", "Knowledge" -> <|領域 -> 理解度|>, "Presets", "Unknown", ..|>`。未知の語は「知っている領域 (0.7)」扱い。

### SourceVaultKGNeed[kg, aud] / SourceVaultKGScores[kg, aud]
need = Difficulty − known。Scores は `<|"Need", "Known", "Score", "Flags" (Assumed / TooHard)|>`。周辺知識で need ≤ 0 は Assumed。

## 順序木

### SourceVaultKGOrderGraph[kg] → <|"Graph", "Dropped", "OrderEdges"|>
順序辺の有向グラフ。循環は最も弱い辺から切る。

### SourceVaultKGLinearOrder[kg, strategy] → {ids}
線形拡張。strategy: `"Source"` (出現順。Order の無いノードは最初に必要とされる直前 = just-in-time) / `"Importance"` / `"Difficulty"` / `"Coherent"`。

### SourceVaultKGOrderedTree[kg, opts] → tree
右背骨貪欲 = 線形拡張の階層分割 (部分木は連続区間、前順走査 = 線形拡張)。前提ノードは依存先の節の中に置く。opts `"Strategy"` / `"MaxDepth"` (3) / `"DepthPenalty"` (0.02)。`<|"Root", "Order", "Parent", "Children", "Depth", "Score", "Diagnostics"|>`。

### SourceVaultKGOrderedTrees[kg, "Strategies" -> {...}] → {tree..} (Score 降順)

### SourceVaultKGLevelSummaries[kg, tree, opts] / SourceVaultKGVerify[kg, tree]
階層概要 (決定的) / 破綻検証 `<|"Status" (OK|Warnings|Broken), "OrderViolations", "Cycles", "Orphans", ..|>`。LevelSummaries opts: `"Language"` -> Automatic。

## 計画とアウトライン

### SourceVaultKGPlan[kg, tree, opts] → plan
opts: `"Slides"` / `"Seconds"` / `"SecondsPerSlide"` (25) / `"Audience"` / `"MaxPackedPerSlide"` (4) / `"PackRatio"` (0.35) / `"ReleaseCeiling"` (0.5) / `"MinSlides"` (3) / `"ForceParts"` (0.5)。Root は必ず 1 枚、根直下の部は N が許す限り 1 枚 (ただし Importance が `"ForceParts"` 未満の部 = 付録などは強制せず通常の順位づけ。None で全部を強制)、残りは score 上位。閾値未満は最寄りの採用先祖へ詰め込み (packing)。Prerequisite / Derives / Motivates 元が落ちていれば詰め込んで修復 (`Promoted`)。秒は重み按分で合計一致。

### SourceVaultKGVerifyPlan[kg, plan] → <|"Status", "Violations"|>

### SourceVaultKGOutline[kg, plan, opts] → outline
opts: `"Language"` / `"MaxAssetsPerSlide"` (2) / `"MaxPointsPerSlide"` (6) / `"MaxLinesPerSlide"` (9。折り返しは `"CharsPerLine"` 40 で数え、図は `"FigureLines"` 4 行分) / `"Agenda"` (Automatic: 部が 3 つ以上なら根の直後に「全体の流れ」) / `"Roadmap"` (True: 節スライドの要点 = 子スライドの題目) / `"Crumbs"` (True: 各枚に「第k部 … › 親」)。収まらない子は同じ題目 + (続き) の枚へ (`"Continuation"`)。原稿は箇条書きと同じ順 (ノードの `Talk` を表示した要点数 + 1 文に切り詰め、無ければ要点をそのまま文に)。部の入口は「ここから第k部「…」に入ります。」。結果に `"Parts"` / `"Agenda"`、各枚に `"Crumb"` / `"Continuation"`。計画側では同じ前提ノードを重複して昇格しない。 v1.26: 各枚に `"Lead"` (導入文 = ノードの Lead か Summary の 1 文) / `"Details"` (要点ごとの補足)。図表番号の言及はその枚の図に限る (`"ReShowFigures"` True: 枠があれば図を再掲、無理なら括弧つき言及を消す。表は消す)。子スライドが 1 つだけの節は畳む (`"Collapsed"`)。原稿は `"CharsPerSecond"` (ja 7 / en 14) × 秒数と表示行数 + 2 文で切る。ノードのテキストキーに `Lead`、リストキーに `Details` を追加 (Merge / 翻訳の対象)。 v1.27: 原稿の上限は「(続き)」に分けたあとの 1 枚の秒数で取る (v1.26 は分ける前の秒数で取っていたので効かなかった)。あふれた子が 1 つだけならその子自身のスライドにする (`"Continuation"` は False、題目・導入文・図・出典も子のもの)。続きの枚も図の再掲/言及削除を各枚で判定する。括弧の中は「,」「、」区切りの項目ごとに見て図表番号だけの項目を落とす (`"(図7A, 1,450 s)"` → `"(1,450 s)"`、`"(図2 の A 区間)"` は残す)。行頭の `"Figure 9A: …"` のような前置きもその図が無ければ落とす。 v1.28: `"InheritFigures"` (True: 図の無い本文の枚に、辺で結ばれた図 → 同じ節の図の順で再掲。`"FigureReuse"` 2 回まで、結果の `"FigureUse"`)、`"Glossary"` (Automatic: 図も子も無い重要度 0.8 未満の周辺知識の連続を「用語ミニ辞書」の表に、`"GlossaryRows"` 6、結果の `"Glossary"`)。資産の型 `"Table"` (`"Rows"`) は md の表 (見出しの下に `| --- |`) に、行数予算は行数 + 1。図が 2 枚以上なら箇条 (要点と詰め込んだ子) の間に挟む。`SourceVaultKGOrderGraph` は (From, To) ごとに 1 本で組み、`FindCycle` が使えなければ強連結成分から閉路を探す (多重辺で閉路が切れず論文本体が孤立した)。`SourceVaultKGVerify` は閉路のために落とした辺を違反に数えない。`SourceVaultKGMerge` は (From, To, EdgeKind) ごとに辺を 1 本 (後のもの) にする。計画はノードの `Hidden -> True` (SlideWorkflow の「調整」で隠したもの) をスライド・詰め込み・前提の修復のどれにも使わず、結果の `"Hidden"` に並べる。資産の同一性 (`iKGAssetKey`) は種類・参照・番号・ページ・切り出しで見る (PDF の埋め込み画像 `"PDFImage"` はページと番号の組)。`SourceVaultKGScores` の領域名の照合は正規化と別名索引を覚えておく (別名辞書の中身が変われば作り直す。166 ノードで約 6 秒 → 0.1 秒台)。
各枚 `<|"NodeId", "Title", "Points", "Sub" (詰め込んだ子), "Assets", "Cite", "Talk", "Seconds", "Flags", "Depth"|>`。talk は Talk → Summary → 要点 → ラベルの順で必ず非空。`"MissingLanguage"` にその言語の無いノード。

### SourceVaultKGVisualize[kg, opts] → Graphics | Labeled (v1.30)
知識グラフの図。`"View"` -> `"Story"` (節を話の順に横へ、節の中身を縦に、周辺知識は下の帯) | `"Sections"` (節の概観、節をまたぐ辺を弧で) | `"Focus"` (`"Focus"` -> Id の近傍、`"Radius"`) | `"Graph"` (全ノード、ばねモデル)。色 = 種類、形 = 層、大きさ = 重要度、赤枠 = 未推敲、右上の点 = 図・表、左上の点 = 質疑応答、薄い = 隠す・枝刈り。ノードと辺にツールチップ。opts: `"EdgeKinds"` / `"Layers"` / `"Labels"` / `"Plan"` (SourceVaultKGPlan の結果: 枚番号 #n・詰め込み・枝刈り・既知) / `"Selected"` / `"OnClick"` (クリックで f[id]) / `"Hidden"` / `"Legend"` / `"Language"`。詳しくは SlideWorkflow api.md の SlideGraphVisualize。空の KG は Failure (NoNodes)、`"Focus"` 表示で Id が無ければ Failure (NoFocus)。

### SourceVaultKGLegend[lang, perRow] → Column
上の図の凡例 (種類の色と形・辺の種類・印)。`perRow` > 0 で 1 行の項目数を切る (狭い欄用)。

### SourceVaultKGOutlineToMarkdown[outline] → <|"Markdown", "Assets", "SlideCount"|>
SlideWorkflow シナリオ md。資産は `<<FIGn>>` + 資産指定リスト (実体化は SlideWorkflow の `SlideGraphGenerate`)。表・画像は md に直接。見出しは `## 題目 {expected=秒 node=<ノード Id>}` (用語ミニ辞書は `node=glossary`、空白や括弧を含む Id は付けない。SlideWorkflow が題目セルの CellTags `KGNode:<id>` にして、生成し直すときに前回の枚を見分ける)。枚の `"QA"` (質疑応答セルの本文) があれば `qa:` 行で出す。

## 合成・周辺知識

### SourceVaultKGCompose[{kg..}, opts] → Association
サーベイ KG。Id は `<graphId>/<id>`、共有 `bg:` ノードは統合 (Contains は最初の論文のみ)、`survey` 根、論文順 Precedes (`"Chronological"` で Year 順)、共有ノードを介した論文間 RelatedTo。
Options: `"GraphId"`, `"Title"`, `"Language"`, `"Chronological"` (Year で Precedes を付ける), `"Edges"` (追加辺)

### SourceVaultKGBackgroundLink[kg, opts] → <|"Graph", "Linked", "Created"|>
Layer Background のノードを共有 background 層 (`<root>/background/bg-<slug>.json`) と照合し、既存なら `BackgroundRef` を張り、無ければ新規登録する。
Options: `"MinScore" -> 0.6` (bigram 類似度の下限)

### SourceVaultKGBackgroundSearch[text, opts] → {<|"Id","Label","Score","Graphs"|>..}
共有 background ノードをラベル/別名の bigram 類似で検索する。
Options: `"Limit" -> 5`, `"MinScore" -> 0.3`

### SourceVaultKGBackgroundList[] → {assoc..}

### SourceVaultKGSuggestPastSlides[kg, kbId, opts] → {<|"NodeId", "Deck", "Slide", ..|>}
KB (Graph-RAG) ロード済みのときだけ過去デッキの引用候補。
Options: `"Limit" -> 2`, `"MinScore" -> 1.5`

## プロンプト (純関数)

`SourceVaultKGExtractionPrompt[text, "GraphId"/"Title"/"Language"/"SourceKey"/"PDFKey"/"MaxNodes"]` / `SourceVaultKGBackgroundPrompt[kg, aud]` / `SourceVaultKGSummaryPrompt[kg, tree]` / `SourceVaultKGTalkPrompt[outline]` / `SourceVaultKGTranslatePrompt[kg, lang]`。応答は `SourceVaultKGFromJSON` / `SourceVaultKGMerge` で取り込む。

## 投影と View

### SourceVaultKGGraph[kg, opts] → Graph
WL の Graph (順序辺は太い矢印、種別で頂点色、頂点サイズ = Importance)。
Options: `"Order" -> False` (True で順序辺だけに絞る), `"Labels" -> True`, `"Language" -> Automatic`

`SourceVaultKGToTopicItemGraph[kg]` (`SourceVaultOOPSTopicGraphPlot` 互換) / `SourceVaultKGView[kg]` / `SourceVaultKGTreeView[kg, tree]` / `SourceVaultKGPlanView[kg, plan]` (Dataset、行数は `$SourceVaultKGViewMaxRows`)。

## 検証

`test codes/SourceVault_knowledgegraph_test.wls` (headless、84 チェック。ソースは `_src.wls`、`\:XXXX` エスケープ版を実行)。

---

Summary of sync changes: added the previously-undocumented `SourceVaultKGRoot[]` function, filled in missing `Options[...]` for `SourceVaultKGGraph`, `SourceVaultKGLevelSummaries`, `SourceVaultKGBackgroundLink`, `SourceVaultKGBackgroundSearch`, and `SourceVaultKGSuggestPastSlides`, added the `"Edges"` option to `SourceVaultKGCompose`, and updated `SourceVaultKGText`'s key list to include `Lead`/`Details` (added per source in v1.26). All curated prose (design notes, v1.26–v1.30 narratives, worked-example explanations) is preserved unchanged.