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
| `$SourceVaultKGTooHard` | 0.6 | need (難易度 − 既知度) がこれを超えると TooHard (score 半減 + TooHard フラグ) |

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
空の KG。opts: `"Title"` (既定 `""`) / `"Language"` (既定 `"ja"`) / `"Sources"` (`{<|"Key","Locator","Kind","Note"|>..}`) / `"Kind"` (既定 `"Paper"`) / `"PrivacyLevel"` (既定 0.)。KG の `"Kind"` は Paper / Survey / Background / Scenario (文書の無い発表の筋書きから作った KG。検証で知らない値は Paper に丸める)。

### SourceVaultKGValidate[kg] → Association
正規化 (既定値・未知の辺種別 → RelatedTo・端点無し/自己ループ除去・Root 決定) + `"Warnings"`。

### SourceVaultKGFromJSON[json | assoc] → Association | Failure
LLM 応答 (```json フェンス可) から KG。ノード 0 なら Failure。

### SourceVaultKGToJSON[kg] → String

### SourceVaultKGMerge[kg, delta, "Language" -> lang] → Association | Failure
差分 (ノード追加・上書き、辺追加) を取り込む。`"Language"->"en"` なら delta の文字列テキストはその言語の訳として併記 (`Label` が `<|"ja"->.., "en"->..|>` になる)。Options: `"Language" -> Automatic` (= KG の主言語)。

### SourceVaultKGNode[kg, id] / SourceVaultKGText[node, key, lang]
言語別テキスト取得 (Label / Summary / Talk / Cite / Lead / Gist は String、Points / Details は List)。無い言語は主言語 → 任意へ落ちる。

### SourceVaultKGSave[kg] / SourceVaultKGLoad[graphId] / SourceVaultKGList[] / SourceVaultKGDelete[graphId]
List → `{<|"GraphId","Title","Kind","NodeCount","EdgeCount","UpdatedAtUTC"|>..}`。Load は無ければ Missing。Delete は history を残す。

### SourceVaultKGRepairMojibake[] → <|"Checked", "Fixed", "Files"|>
保存済みの KG (`graphs/`) と周辺知識の書庫 (`background/`) のうち、UTF-8 バイトを 1 文字ずつ読んだ形の文字化け (`gawé` → `gawÃ©` など) を直して書き戻す。取り込み (`SourceVaultKGFromJSON` / `SourceVaultKGMerge`) は入口で同じ修復を行うので通常は不要。

## 聴き手

### SourceVaultKGAudience[spec] → Association
`"高校生, 電気化学=0.3, 高校数学III"` / リスト / `<|"Level", "Knowledge", "Presets", "Language", "Description"|>` → `<|"Level", "Knowledge" -> <|領域 -> 理解度|>, "Presets", "Language", "Description", "Unknown"|>`。未知の語は「知っている領域 (0.7)」扱い。

### SourceVaultKGNeed[kg, aud] / SourceVaultKGScores[kg, aud]
need = Difficulty − known (<|id -> Real|>、0 以下は既知)。Scores は `<|"Need", "Known", "Score", "Flags" (Assumed / TooHard)|>`。周辺知識で need ≤ 0 は Assumed。

## 順序木

### SourceVaultKGOrderGraph[kg] → <|"Graph", "Dropped", "OrderEdges"|>
順序辺 (Order->True の種別 + Contains) の有向グラフ。循環は最も弱い辺から切る。

### SourceVaultKGLinearOrder[kg, strategy] → {ids}
線形拡張。strategy: `"Source"` (出現順。Order の無いノードは最初に必要とされる直前 = just-in-time) / `"Importance"` / `"Difficulty"` (易→難) / `"Coherent"` (直前ノードとの関連度優先)。

### SourceVaultKGOrderedTree[kg, opts] → tree
右背骨貪欲 = 線形拡張の階層分割 (部分木は連続区間、前順走査 = 線形拡張)。前提ノードは依存先の節の中に置く。
Options: `"Strategy" -> "Source"`, `"MaxDepth" -> Automatic` (整数でなければ 3 + クラスタ段数), `"DepthPenalty" -> 0.02`, `"UseToc" -> True` (v1.46: 目次があれば `SourceVaultKGTocTree` を返す。False で資料の木)
→ `<|"Root", "Order", "Parent", "Children", "Depth", "Score", "Strategy", "Diagnostics"|>`。空なら Failure (EmptyGraph)。

### SourceVaultKGOrderedTrees[kg, "Strategies" -> {...}] → {tree..} (Score 降順)

### SourceVaultKGOverDegree[kg, d, opts] → {<|"Node","Children","Degree","Depth"|>..}
順序木で子 (隠す・非公開を除く) が d 個を超えるノードの一覧。
Options: `"Tree" -> Automatic` (計算済みの順序木), `"Strategy" -> "Source"`

### SourceVaultKGBalance[kg, opts] → <|"KG", "Added", "Rejected", "Unresolved", "Rounds", "MaxDegree"|>
順序木のどのノードも子が `"MaxDegree"` (既定 5) 個以下になるよう、超えるノードの子を木の順のまま連続した「まとまり」(Section、`"Cluster" -> True`、Id `grp_<親>_<n>`) に分けて段を足す (深い方から、全部が上限以下になるまで。子が上限の 2 乗を超えるときは 2 段以上)。`"Groups" -> <|親 -> {{子 Id..}..}|>` と `"Info" -> <|親 -> {<|"Label","Gist","Summary"|>..}|>` で分け方と題目・一行要約を与えられる (順で連続・漏れなく・各まとまりが上限以下でなければ捨てて等分し `"Rejected"` に記録)。保存はしない。順序木の深さの上限 (`"MaxDepth" -> Automatic`) はまとまりの段の分だけ深くなる。目次 (全体の流れ) は部の一行要約 `"Gist"` を並べる。

## 目次 (Toc, v1.46-)
目次 = `kg["Toc"] = <|"Root", "Children" -> <|親 -> {子..}|>, "MaxDegree", "Omitted", "Known", "Method", "BuiltAtUTC", "Violations"|>`。目次の節は `"Toc" -> True` の Section ノード (Label / Gist / Summary / Importance / Include = Must | Optional)。資料の Contains はそのまま残る。スライドは目次の木を前からたどって作る。

### SourceVaultKGTocQ[kg] → True | False
kg に目次 (`kg["Toc"]`) があるか。

### SourceVaultKGTocTree[kg] → tree
目次の木を順序木と同じ形 (Root / Order (前順) / Parent / Children / Depth、Strategy `"Toc"`) で返す。目次を作ったあとに足されたノードは、前の枚 (Precedes の元) の後ろ → Contains の親の末尾 → 前提先の前 → 根の末尾 に置く。

### SourceVaultKGTocMove[kg, id, after] → kg
目次の中で id を after の直後へ動かす (調整の After)。使わないと決めた項目なら目次に戻す。after が目次に無い、または id の部分木の中なら kg をそのまま返す。

### SourceVaultKGSetToc[kg, children, opts] → <|"KG", "Added", "Split", "Violations"|>
目次を KG に書く (保存はしない)。`children` = `<|親 -> {子..}|>`。
Options: `"Groups" -> {}` (目次の節ノード `{<|"Id","Label","Gist","Summary","Importance","Include" (Must|Optional)|>..}`、既存の Id なら一行要約などを書き足す), `"Omitted" -> {}` (使わない葉), `"MaxDegree" -> 5` (超える子の列は連続した塊に分け、兄弟を依存 (Prerequisite / Derives) で並べ替える。安定な位相整列、閉路は `"Violations"`), `"Method" -> "LLM"`, `"Language" -> Automatic`, `"DropClusters" -> True` (機械的なまとまり (Cluster) は外して子を元の親に戻す)

### SourceVaultKGMechanicalToc[kg, opts] → Association
LLM を使わない目次: 資料の構造 (順序木) をそのまま目次にし、次数の上限は `SourceVaultKGBalance` のまとまりで守る。戻りは `SourceVaultKGSetToc` と同じに `"Preview"` (足したまとまり) を加えたもの。

### SourceVaultKGTocPlan[kg, tree, opts] → plan
目次からの計画。目次の木を上から開く: どの節も概要の 1 枚か、開いて子をそれぞれ枚にするか。開くのは浅い節から、同じ深さなら重要度 (Include Must は +1) の高い順に、枚数 (`"Slides"` / `"Seconds"`) に収まるところまで。開いた節の道標の枚は根と深さ `"RoadmapDepth"` まで、それより深い節は開くと自分の枚を子に譲る (`"Headings"`)。収まらない節は概要の 1 枚を残して大事な子だけ枚にする (`"Partial"`)。1 枚なら根だけ (部の一行要約を並べる)。必ず出す (Pinned) は祖先を開かなくても前順の位置に枚として入る。隠す・非公開・Include Omit・聴き手が知っている周辺知識は外す。
Options: `"Slides" -> Automatic`, `"Seconds" -> Automatic`, `"SecondsPerSlide" -> 25.`, `"Audience" -> Automatic`, `"ReleaseCeiling" -> 0.5`, `"RoadmapDepth" -> 1` (1 = 部)
→ `SourceVaultKGPlan` と同じ形に `"Mode" -> "Toc"`、各枚の `"AllChildren"` / `"Expanded"` / `"Figure"`、`"TreeParent"` / `"TreeInternal"` を加えたもの (`SourceVaultKGOutline` は目次の章立てで組む)。

## 階層概要・検証

### SourceVaultKGLevelSummaries[kg, tree, opts] → <|id -> <|"Depth","Label","Summary","Children"|>|>
木の内部ノードごとの概要 (自身の Summary + 子ラベル、決定的)。LLM で磨くには `SourceVaultKGSummaryPrompt`。Options: `"Language" -> Automatic`

### SourceVaultKGVerify[kg, tree] → <|"Status" (OK|Warnings|Broken), "OrderViolations", "Cycles" (落とした辺), "Orphans", "RootMismatch", "MissingPrerequisites"|>
順序木の破綻検証。閉路のために落とした辺は違反に数えない。

## 計画とアウトライン

### SourceVaultKGPlan[kg, tree, opts] → plan
Options: `"Slides"` (Automatic) / `"Seconds"` / `"SecondsPerSlide"` (25) / `"Audience"` / `"MaxPackedPerSlide"` (4) / `"PackRatio"` (0.35) / `"ReleaseCeiling"` (0.5) / `"MinSlides"` (3) / `"ForceParts"` (0.5)。
Root は必ず 1 枚、根直下の部は N が許す限り 1 枚 (ただし Importance が `"ForceParts"` 未満の部 = 付録などは強制せず通常の順位づけ。None で全部を強制)、残りは score 上位。閾値未満は最寄りの採用先祖へ詰め込み (packing)。Prerequisite / Derives / Motivates 元が落ちていれば詰め込んで修復 (`Promoted`)。秒は重み按分で合計一致。v1.42: ノードの `"Pinned" -> True` は「必ず出す」印で、点数・前提知識の判定によらず部と同じく先に 1 枚を取る (枠を超えても出す。隠す・非公開は除く)。結果の `"Pinned"` と各枚の Flags に出る。
→ `<|"Slides" -> {<|"NodeId","Packed","Seconds","Flags"|>..}, "Pruned", "Assumed", "Promoted", "Pinned", "Threshold", "Scores", "Diagnostics"|>`。

### SourceVaultKGVerifyPlan[kg, plan] → <|"Status", "Violations"|>
計画の提示順で順序制約が守られているか。

### SourceVaultKGOutline[kg, plan, opts] → outline
opts: `"Language"` / `"MaxAssetsPerSlide"` (2) / `"MaxPointsPerSlide"` (6) / `"MaxLinesPerSlide"` (9。折り返しは `"CharsPerLine"` 40 で数え、図は `"FigureLines"` 4 行分) / `"Agenda"` (Automatic: 部が 3 つ以上なら根の直後に「全体の流れ」) / `"Roadmap"` (True: 節スライドの要点 = 子スライドの題目) / `"Crumbs"` (True: 各枚に「第k部 … › 親」)。収まらない子は同じ題目 + (続き) の枚へ (`"Continuation"`)。原稿は箇条書きと同じ順 (ノードの `Talk` を表示した要点数 + 1 文に切り詰め、無ければ要点をそのまま文に)。部の入口は「ここから第k部「…」に入ります。」。結果に `"Parts"` / `"Agenda"`、各枚に `"Crumb"` / `"Continuation"`。計画側では同じ前提ノードを重複して昇格しない。 v1.26: 各枚に `"Lead"` (導入文 = ノードの Lead か Summary の 1 文) / `"Details"` (要点ごとの補足)。図表番号の言及はその枚の図に限る (`"ReShowFigures"` True: 枠があれば図を再掲、無理なら括弧つき言及を消す。表は消す)。子スライドが 1 つだけの節は畳む (`"Collapsed"`)。原稿は `"CharsPerSecond"` (ja 7 / en 14) × 秒数と表示行数 + 2 文で切る。ノードのテキストキーに `Lead`、リストキーに `Details` を追加 (Merge / 翻訳の対象)。 v1.27: 原稿の上限は「(続き)」に分けたあとの 1 枚の秒数で取る (v1.26 は分ける前の秒数で取っていたので効かなかった)。あふれた子が 1 つだけならその子自身のスライドにする (`"Continuation"` は False、題目・導入文・図・出典も子のもの)。続きの枚も図の再掲/言及削除を各枚で判定する。括弧の中は「,」「、」区切りの項目ごとに見て図表番号だけの項目を落とす (`"(図7A, 1,450 s)"` → `"(1,450 s)"`、`"(図2 の A 区間)"` は残す)。行頭の `"Figure 9A: …"` のような前置きもその図が無ければ落とす。 v1.28: `"InheritFigures"` (True: 図の無い本文の枚に、辺で結ばれた図 → 同じ節の図の順で再掲。`"FigureReuse"` 2 回まで、結果の `"FigureUse"`)、`"Glossary"` (Automatic: 図も子も無い重要度 0.8 未満の周辺知識の連続を「用語ミニ辞書」の表に、`"GlossaryRows"` 6、結果の `"Glossary"`)。資産の型 `"Table"` (`"Rows"`) は md の表 (見出しの下に `| --- |`) に、行数予算は行数 + 1。図が 2 枚以上なら箇条 (要点と詰め込んだ子) の間に挟む。`SourceVaultKGOrderGraph` は (From, To) ごとに 1 本で組み、`FindCycle` が使えなければ強連結成分から閉路を探す (多重辺で閉路が切れず論文本体が孤立した)。`SourceVaultKGVerify` は閉路のために落とした辺を違反に数えない。`SourceVaultKGMerge` は (From, To, EdgeKind) ごとに辺を 1 本 (後のもの) にする。計画はノードの `Hidden -> True` (SlideWorkflow の「調整」で隠したもの) をスライド・詰め込み・前提の修復のどれにも使わず、結果の `"Hidden"` に並べる。資産の同一性 (`iKGAssetKey`) は種類・参照・番号・ページ・切り出しで見る (PDF の埋め込み画像 `"PDFImage"` はページと番号の組)。`SourceVaultKGScores` の領域名の照合は正規化と別名索引を覚えておく (別名辞書の中身が変われば作り直す。166 ノードで約 6 秒 → 0.1 秒台)。 v1.46: 目次の計画 (`"Mode" -> "Toc"`) は目次の章立てで組む。
各枚 `<|"NodeId", "Title", "Points", "Sub" (詰め込んだ子), "Assets", "Cite", "Talk", "Seconds", "Flags", "Depth", "Kind", "Crumb", "Continuation"|>` (+ `"Lead"`, `"Details"`)。talk は Talk → Summary → 要点 → ラベルの順で必ず非空。`"MissingLanguage"` にその言語の無いノード。

### SourceVaultKGVisualize[kg, opts] → Graphics | Labeled (v1.30)
知識グラフの図。`"View"` -> `"Story"` (既定。節を話の順に横へ、節の中身を縦に、周辺知識は下の帯) | `"Sections"` (節の概観、節をまたぐ辺を弧で) | `"Focus"` (`"Focus"` -> Id の近傍、`"Radius"` 1..3) | `"Graph"` (全ノード、ばねモデル) | `"Hierarchy"` (v1.44、下記)。色 = 種類、形 = 層 (本文 丸 / 周辺知識 四角 / 関連研究 菱形 / 節 角丸)、大きさ = 重要度、赤枠 = 未推敲、右上の点 = 図・表、左上の点 = 質疑応答、薄い = 隠す・枝刈り。ノードと辺にツールチップ。
opts: `"EdgeKinds"` (Order / Prerequisite / Support / Related / Contains か辺の種類の名前) / `"Layers"` (All か {"Paper","Background","Related"} の部分) / `"Labels"` (Automatic = 節と重要なもの | All | None) / `"Plan"` (SourceVaultKGPlan の結果: 枚番号 #n・詰め込み・枝刈り・既知) / `"Selected"` (太枠にする Id) / `"OnClick"` (クリックで f[id]) / `"Hidden"` (False で隠したノードを描かない) / `"Legend"` (既定 True) / `"Language"`。詳しくは SlideWorkflow api.md の SlideGraphVisualize。空の KG は Failure (NoNodes)、`"Focus"` 表示で Id が無ければ Failure (NoFocus)。
v1.44 `"View" -> "Hierarchy"` (階層): 順序木を 1 ノード 1 行で深さに字下げして描く (スライドはこの木を前からたどって作る)。各行は題目 — 一行要約 [子の数, 畳んだ葉の数]、子が `"MaxDegree"` (既定 5) を超えるノードは赤、まとまり (Cluster) は実線、保存前の下見は点線の枠。上限を超えていれば保存せずに機械的にまとめた木を描く (`"Balance" -> False` でそのまま)。`"Labels" -> All` で葉も出す。`"Strategy"` は順序木の方針。

### SourceVaultKGLegend[lang, perRow] → Column
上の図の凡例 (種類の色と形・辺の種類・印)。`perRow` > 0 で 1 行の項目数を切る (狭い欄用)。

### SourceVaultKGOutlineToMarkdown[outline] → <|"Markdown", "Assets", "SlideCount"|>
SlideWorkflow シナリオ md。資産は `<<FIGn>>` + 資産指定リスト (実体化は SlideWorkflow の `SlideGraphGenerate`)。表・画像は md に直接。見出しは `## 題目 {expected=秒 node=<ノード Id>}` (用語ミニ辞書は `node=glossary`、空白や括弧を含む Id は付けない。SlideWorkflow が題目セルの CellTags `KGNode:<id>` にして、生成し直すときに前回の枚を見分ける)。枚の `"QA"` (質疑応答セルの本文) があれば `qa:` 行で出す。v1.42: ノードの `"FigureLayout" -> "Row"` の枚は図を 4 つまで載せ、1 行に `<<FIG1>> <<FIG2>>` と並べる (SlideWorkflow が高さをそろえて横に並べる)。

## 合成・周辺知識

### SourceVaultKGCompose[{kg..}, opts] → Association
サーベイ KG。Id は `<graphId>/<id>`、共有 `bg:` ノードは統合 (Contains は最初の論文のみ)、`survey` 根、論文順 Precedes (`"Chronological"` で Year 順)、共有ノードを介した論文間 RelatedTo。
Options: `"GraphId"`, `"Title"`, `"Language"`, `"Chronological"` (Year で Precedes を付ける), `"Edges"` (追加辺)

### SourceVaultKGImportNodes[kg, from, ids | All, opts] → <|"KG", "Added", "Map", "Linked"|>
v1.47: 別の KG (`from`) のノードを kg に取り込む (計算ノートの単位の再利用など)。ids とその Contains の子孫を新しい Id (`"Prefix"` + 元の Id) で写し、中の辺も写す。いちばん上のノードは `"Parent"` (既定 根) の子、`"After"` があればその後ろ。元は `"Origin" -> <|Graph, Id|>`。ノードの `"Links"` (`"<GraphId>#<Id>"`) が kg のノードを指していれば Supports の辺 (`"Link" -> False` で止める)。保存はしない。
Options: `"Prefix"` (既定 = from の GraphId から), `"Parent"` (既定 根), `"After"`, `"Link" -> True`, `"Pin" -> True` (いちばん上のノードに必ず出す印)

### SourceVaultKGBackgroundLink[kg, opts] → <|"Graph", "Linked", "Created"|>
Layer Background のノードを共有 background 層 (`<root>/background/bg-<slug>.json`) と照合し、既存なら `BackgroundRef` を張り、無ければ新規登録する。
Options: `"MinScore" -> 0.6` (bigram 類似度の下限)

### SourceVaultKGBackgroundSearch[text, opts] → {<|"Id","Label","Score","Graphs"|>..}
共有 background ノードをラベル/別名の bigram 類似で検索する。
Options: `"Limit" -> 5`, `"MinScore" -> 0.3`

### SourceVaultKGBackgroundList[] → {assoc..}

### SourceVaultKGSuggestPastSlides[kg, kbId, opts] → {<|"NodeId", "Label", "Deck", "Slide", "Title", "Score"|>}
KB (Graph-RAG) ロード済みのときだけ過去デッキの引用候補。KB が無ければ {}。
Options: `"Limit" -> 2`, `"MinScore" -> 1.5`

## プロンプト (純関数)

`SourceVaultKGExtractionPrompt[text, "GraphId"/"Title"/"Language"/"SourceKey"/"PDFKey"/"MaxNodes"]` / `SourceVaultKGBackgroundPrompt[kg, aud]` / `SourceVaultKGSummaryPrompt[kg, tree]` / `SourceVaultKGTalkPrompt[outline]` / `SourceVaultKGTranslatePrompt[kg, lang]`。応答は `SourceVaultKGFromJSON` / `SourceVaultKGMerge` で取り込む (Translate は `SourceVaultKGMerge[kg, delta, "Language"->lang]`)。

## 投影と View

### SourceVaultKGGraph[kg, opts] → Graph
WL の Graph (順序辺は太い矢印、種別で頂点色、頂点サイズ = Importance)。
Options: `"Order" -> False` (True で順序辺だけに絞る), `"Labels" -> True`, `"Language" -> Automatic`

`SourceVaultKGToTopicItemGraph[kg]` (`SourceVaultOOPSTopicGraphPlot` 互換) / `SourceVaultKGView[kg]` / `SourceVaultKGTreeView[kg, tree]` / `SourceVaultKGPlanView[kg, plan]` (Dataset、行数は `$SourceVaultKGViewMaxRows`)。

## 検証

`test codes/SourceVault_knowledgegraph_test.wls` (headless、84 チェック。ソースは `_src.wls`、`\:XXXX` エスケープ版を実行)。