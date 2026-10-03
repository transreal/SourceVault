# SourceVault_papernb API リファレンス

取り込み済み論文 (`src-…` / `sv://snapshot/…` / `arxiv:…` / URL) と Eagle の PDF (`sv://object/eagle-<id>` / `eagle:<id>`、`SourceVaultEagleObjectInfo` で item の実ファイルと実効 PL に解決。SourceId は無いので登録簿は正準 URI で引く) と、`DocImportPaper` (documentation_paper2nb.wl) で作った和訳ノートブックを対応づける登録簿。コンテキスト `SourceVault\`` (private `` `PaperNBPrivate` ``)。service-loadable (FrontEnd / NBAccess / documentation は DownValues guard の弱結合)。同ファイルは計算ノート (素材から作った Mathematica の計算と結果のノートブック) の登録簿も持つ (後述)。

**PL の継承**: 生成ノートブックは元ソースの `PrivacyLevel` を継承する。`CloudPublishable` 宣言 = PL < 0.5 (NBAccess`NBSetCloudPublishable でファイルに書く。NBAccess の経路規則 `NBPrivacyLevelToRoutes` と同じ境界)。翻訳の LLM 経路も PL で決める: PL < 0.5 は既定 (Claude Code CLI / パレットのモデル)、PL ≥ 0.5 は `$ClaudePrivateModel` のみ (未設定なら fail-closed で Failure)。ローカル PDF パスを直接 `DocImportPaper` に渡す従来の呼び方は PL を継承しない (宣言なし)。

保存: `SourceVaultCoreRoot[]/papernb/registry.json` と `papernb/<題名>_<SourceId>.nb`。`File` は root 内なら相対パス (Dropbox の root は PC ごとに違う)。

## 定数

| 記号 | 既定 | 意味 |
|---|---|---|
| `$SourceVaultPaperNBRoot` | Automatic | 保存先 (テストでは隔離ディレクトリ)。Automatic = `SourceVaultCoreRoot[]/papernb`、無ければ `LOCALAPPDATA/SourceVault/papernb` |
| `$SourceVaultComputeNBRoot` | Automatic | 計算ノート登録簿の保存先。Automatic = `SourceVaultCoreRoot[]/computenb` |

## 関数

### SourceVaultPaperNotebookRoot[] → String
登録簿と生成ノートブックの保存ディレクトリ (無ければ作る)。

### SourceVaultPaperNotebook[ref] → path | Missing
登録済み和訳ノートブックの絶対パス。`SlideWorkflow` の文献解決 (`iSWSourceNBPath` / References の `"Notebook"` キー) と `SourceVaultResolveReference[..]["Notebook"]` がこれを引く。未登録・ファイル無しは Missing。

### SourceVaultPaperNotebookEntry[ref] → Association | Missing
`<|"SourceId", "URI", "File", "Notebook" (絶対パス), "Title", "PrivacyLevel", "CloudPublishable", "TargetLanguage", "Status", "FailedPages", "Pages", "CreatedAtUTC", "UpdatedAtUTC"|>`。まず登録簿を ref の SourceId / URI で引き、見つからない時だけ参照解決を通す (再帰しない)。

### SourceVaultRegisterPaperNotebook[ref, nbPath, opts] → entry | Failure
既存ノートブックの登録。同じ SourceId / URI は差分マージ。戻り値は entry に `"Notebook"`, `"Declared"` を加えたもの。Failure: `NoFile` / `SaveFailed`。
Options: "PrivacyLevel" -> Automatic (元ソースから。解決できなければ 1.0。[0,1] に clip), "Title" -> Automatic, "TargetLanguage" -> Automatic (無ければ `$Language`), "Declare" -> True (`NBSetCloudPublishable`。NBAccess 無しなら `"Declared" -> "Skipped"`), "Status" -> "OK", "FailedPages" -> {}, "Pages" -> Automatic

### SourceVaultUnregisterPaperNotebook[ref] → True | False
登録を外す (ファイルは消さない)。

### SourceVaultPaperNotebooks[] → {entry..}
登録一覧 (各 entry に "Notebook" 付き)。

### SourceVaultPaperNotebooksView[] → Dataset
列: SourceId, Title, PL, Public, Language, Status, Exists, Updated, Notebook。

### SourceVaultPaperNotebookPath[ref] → String
新規生成の既定パス `<root>/<安全化した題名>_<SourceId>.nb`。

### SourceVaultSourcePrivacy[ref] → Real
元ソースの PL (解決不能は 1.0)。

### SourceVaultMakePaperNotebook[ref, opts] → entry | Failure
登録済みでファイルがあれば生成せず返す (`"Status" -> "Existing"`、FE なら開く)。無ければ `DocImportPaper[file, "OutputPath" -> 既定パス, "CloudPublishable" -> (PL < 0.5), Model -> PL 経路, ...]` で生成して登録。上記以外のオプションは DocImportPaper へ渡す (`"Pages"` / `"Reconstruct"` / `"TargetLanguage"` / `Model` / `Fallback` …。`"OutputPath"`/`"Save"`/`"CloudPublishable"` は無視)。PL ≥ 0.5 では Model は `$ClaudePrivateModel` のみ、Fallback は False。
Options: "Force" -> False (作り直し), "Open" -> Automatic (False 以外で FE なら開く), "Interactive" -> False (True = 現在のノートブックに評価セルを書いて実行。一覧の「＋ 和訳NB」がこれ), "Verbose" -> True
Failure: `SourceNotFound` / `DocumentationNotLoaded` / `PrivateModelUnavailable` / `ImportFailed`。

### SourceVaultOpenPaperNotebook[ref]
登録済みなら開く (FE 無しならパス)、無ければ `SourceVaultMakePaperNotebook[ref, "Interactive" -> True]`。

## 計算ノート

1 本の論文ではなく複数素材 (論文・SourceVault の文書・KG のノード・過去のスライド) から作った計算ノートブックを管理する。Id = `cnb-<8桁>`、URI = `sv://computenb/<Id>`。セルの単位 (CellTags `"CNU:<unit>"`) は KG のノードになり、セルの並びは 1 つのストーリーとして KG (GraphId = Id、Kind Notebook) に入る (SlideWorkflow の SlideComputeGraph)。保存: `SourceVaultCoreRoot[]/computenb/registry.json` と `<題名>_<Id>.nb` (File は root 内なら相対パス)。

### SourceVaultComputeNotebookRoot[] → String
計算ノート登録簿と既定保存先のディレクトリ (無ければ作る)。

### SourceVaultComputeNotebookPath[title, id] → String
新規計算ノートの既定パス `<root>/<題名>_<Id>.nb`。

### SourceVaultRegisterComputeNotebook[nbPath, opts] → entry | Failure
計算ノートの登録。戻り値は entry に `"Notebook"`, `"Declared"` を加えたもの。Failure: `NoFile` / `SaveFailed`。entry キー: Id, URI, File, Title, Sources, PrivacyLevel, CloudPublishable, Language, Units, Graph, Status, CreatedAtUTC, UpdatedAtUTC。
Options: "Id" -> Automatic (同じファイルの登録を引き継ぐか新規), "Title" -> Automatic (無ければ登録済み/ファイル名), "Sources" -> Automatic ({<|"Key", "Ref"|>..} 素材の locator。文字列リストも可), "PrivacyLevel" -> Automatic (素材の最大。sv:// / src- / Eagle は解決した PL で解けなければ 1.0、計算ノートはその登録の PL、URL・arXiv・ファイル・KG ノードは 0), "Language" -> Automatic (`$Language`), "Units" -> Automatic, "Graph" -> Automatic (ノートの KG、既定 Id), "Status" -> "OK", "Copy" -> False (True で登録簿の場所へ写す), "Declare" -> True (CloudPublishable の宣言)

### SourceVaultComputeNotebookEntry[ref] → Association | Missing
ref = Id / `sv://computenb/<Id>` / 登録したファイルのパス。"Notebook" (絶対パス) 付き。

### SourceVaultComputeNotebook[ref] → path | Missing
登録された計算ノートの絶対パス。SlideWorkflow の文献解決が `sv://computenb/<Id>` をこれで引く。

### SourceVaultComputeNotebooks[] → {entry..}
計算ノートの登録一覧。

### SourceVaultComputeNotebooksView[] → Dataset
列: Id, Title, Units, Sources, PL, Public, Status, Exists, Updated, Notebook。

### SourceVaultUnregisterComputeNotebook[ref] → True | False
登録を外す (ファイルは消さない)。

## 一覧との接続

`SourceVaultEagleView` の 1 列目にも PDF なら「訳」ボタン (登録済みは太字 = 開く、未登録 = 生成)。`SourceVaultSourcesView` / `SourceVaultArXivView` (`iSVRenderRowsGrid`) に「和訳NB」列: 登録済み = 「▶ 和訳NB」(開く)、未登録 = 「＋ 和訳NB」(生成、tooltip に継承する PL)。ボタンには SourceId だけを焼く。`DocImportPaper["src-…"]` も同じ経路に委譲する。

## 検証

`test codes/SourceVault_papernb_test.wls` (31、standalone。SourceVault.wl 側の完全修飾と workflowcatalog との名前衝突、`SourceVaultResolveReference` との相互再帰も監視)、`slidegraph_test.wls` T11 (文献 `src-…` → 登録済みノートで Seed)。