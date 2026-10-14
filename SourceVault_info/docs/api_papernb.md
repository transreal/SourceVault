# SourceVault_papernb API リファレンス

取り込み済みソース (`src-…` / `sv://snapshot/…` / `arxiv:…` / URL。論文 PDF と種別 web の Web ページ) と Eagle の PDF (`sv://object/eagle-<id>` / `eagle:<id>`、`SourceVaultEagleObjectInfo` で item の実ファイルと実効 PL に解決。SourceId は無いので登録簿は正準 URI で引く) と、documentation_paper2nb.wl で作った翻訳ノートブック (PDF は `DocImportPaper`、HTML / テキスト / Markdown は `DocImportWebPage`) を対応づける登録簿。

**翻訳ノートブック (2026-10-12、旧称「和訳ノートブック」)**: 訳先は `$Language` (`"TargetLanguage"` で変更可)。原文の言語 (`DocPaperDetectLanguage`) が訳先と同じなら翻訳せず構造化だけ行う。登録は (ソース, TargetLanguage) ごとに 1 件なので、多言語の利用者がそれぞれの言語の翻訳ノートを同じソースに持てる。TargetLanguage が空の古い登録はどの言語にも合う。中国語の簡体/繁体は同じ言語とみなす (言語名の比較は大文字小文字・空白・`-`・`_` を無視)。コンテキスト `SourceVault\`` (private `` `PaperNBPrivate` ``)。service-loadable (FrontEnd / NBAccess / documentation は DownValues guard の弱結合)。同ファイルは計算ノート (素材から作った Mathematica の計算と結果のノートブック) の登録簿も持つ (後述)。

**PL の継承**: 生成ノートブックは元ソースの `PrivacyLevel` を継承する。`CloudPublishable` 宣言 = PL < 0.5 (NBAccess`NBSetCloudPublishable でファイルに書く。NBAccess の経路規則 `NBPrivacyLevelToRoutes` と同じ境界)。翻訳の LLM 経路も PL で決める: PL < 0.5 は既定 (Claude Code CLI / パレットのモデル)、PL ≥ 0.5 は `$ClaudePrivateModel` のみ (未設定なら fail-closed で Failure)。ローカル PDF パスを直接 `DocImportPaper` に渡す従来の呼び方は PL を継承しない (宣言なし)。

保存: `SourceVaultCoreRoot[]/papernb/registry.json` と `papernb/<題名>_<SourceId>.nb` (既定のパスを別の言語の登録が使っていれば `<題名>_<SourceId>_<言語>.nb`)。`File` は root 内なら相対パス (Dropbox の root は PC ごとに違う)。登録簿 JSON は一時ファイル経由のアトミック書き込み (Dropbox 向けにリトライ)、読みはファイル更新日でキャッシュ。

## 定数

| 記号 | 既定 | 意味 |
|---|---|---|
| `$SourceVaultPaperNBRoot` | Automatic | 保存先 (テストでは隔離ディレクトリ)。Automatic = `SourceVaultCoreRoot[]/papernb`、無ければ `LOCALAPPDATA/SourceVault/papernb` |
| `$SourceVaultComputeNBRoot` | Automatic | 計算ノート登録簿の保存先。Automatic = `SourceVaultCoreRoot[]/computenb`、無ければ `LOCALAPPDATA/SourceVault/computenb` |

## 関数

### SourceVaultPaperNotebookRoot[] → String
登録簿と生成ノートブックの保存ディレクトリ (無ければ作る)。

### SourceVaultPaperNotebook[ref, opts] → path | Missing
登録済み翻訳ノートブックの絶対パス。`SlideWorkflow` の文献解決 (`iSWSourceNBPath` / References の `"Notebook"` キー) と `SourceVaultResolveReference[..]["Notebook"]` がこれを引く。未登録・ファイル無しは Missing。
Options: "Language" -> Automatic (`$Language` の訳を優先し、無ければ他の言語の登録 = 文献解決が途切れない) | "English" 等 (その言語の登録だけ。一覧の列と「訳」ボタンは `"Language" -> $Language` で引く)

### SourceVaultPaperNotebookEntry[ref, opts] → Association | Missing
`<|"SourceId", "URI", "File", "Notebook" (絶対パス), "Title", "PrivacyLevel", "CloudPublishable", "TargetLanguage", "SourceLanguage", "Translated", "Format" (pdf / html / markdown / text), "PDFSourceId", "Status", "FailedPages", "Pages", "CreatedAtUTC", "UpdatedAtUTC"|>`。まず登録簿を ref の SourceId / URI / PDFSourceId で引き、見つからない時だけ参照解決を通す (再帰しない)。"Language" は SourceVaultPaperNotebook と同じ。
Options: "Language" -> Automatic

### SourceVaultRegisterPaperNotebook[ref, nbPath, opts] → entry | Failure
既存ノートブックの登録。登録は (SourceId / URI, TargetLanguage) ごと: `"TargetLanguage"` を指定したらその言語の登録だけを差分マージ (無ければ追加。別の言語の登録は残る)、Automatic なら既存の登録 (`$Language` 優先、無ければ先頭) を更新する。戻り値は entry に `"Notebook"`, `"Declared"` を加えたもの。Failure: `NoFile` / `SaveFailed`。
Options: "PrivacyLevel" -> Automatic (元ソースから。解決できなければ 1.0。[0,1] に clip), "Title" -> Automatic, "TargetLanguage" -> Automatic (新規なら `$Language`), "SourceLanguage" -> Automatic, "Translated" -> Automatic, "Format" -> Automatic (元ソースのファイルの拡張子から), "PDFSourceId" -> Automatic (論文ページを OA PDF から作ったときの PDF のソース。登録の照合に使う), "Declare" -> True (`NBSetCloudPublishable`。NBAccess 無しなら `"Declared" -> "Skipped"`), "Status" -> "OK", "FailedPages" -> {}, "Pages" -> Automatic

### SourceVaultUnregisterPaperNotebook[ref, opts] → True | False
登録を外す (ファイルは消さない)。
Options: "Language" -> Automatic (SourceVaultPaperNotebookEntry が返す 1 件) | 言語名 | All (そのソースの全言語)

### SourceVaultPaperNotebooks[] → {entry..}
登録一覧 (各 entry に "Notebook" 付き)。

### SourceVaultPaperNotebooksView[] → Dataset
列: SourceId, Title, PL, Public, Language (訳先), From (原文の言語), Translated, Format, Status, Exists, Updated, Notebook。

### SourceVaultPaperNotebookPath[ref] → String
### SourceVaultPaperNotebookPath[ref, lang] → String
新規生成の既定パス `<root>/<安全化した題名>_<SourceId>.nb`。2 引数は言語名付き `<root>/<題名>_<SourceId>_<lang>.nb` (既定のパスを別の言語の登録が使っているとき Make が使う)。

### SourceVaultSourcePrivacy[ref] → Real
元ソースの PL (解決不能は 1.0)。

### SourceVaultMakePaperNotebook[ref, opts] → entry | Failure
訳先 (`"TargetLanguage"`、既定 `$Language`) の登録があってファイルがあれば生成せず返す (`"Status" -> "Existing"`、FE なら開く。別の言語の登録しか無ければ新しく作る)。無ければ元ソースのファイル形式で振り分けて生成し登録する: PDF → `DocImportPaper`、HTML / テキスト / Markdown (種別 web のソースの raw snapshot) → `DocImportWebPage` (`"BaseURL"` = ソースの URL、`"Title"` = ソースの題)。共通に `"OutputPath"` (作り直しはその言語の登録のファイル、新規は既定パス・衝突時は言語名付き), `"TargetLanguage"`, `"CloudPublishable" -> (PL < 0.5)`, `Model -> PL 経路` を渡す。上記以外のオプションは変換関数へ渡す (`"Pages"` / `"Reconstruct"` / `"Translate"` / `"Images"` / `"MaxImages"` / `Model` / `Fallback` …。`"OutputPath"`/`"Save"`/`"CloudPublishable"` は無視)。PL ≥ 0.5 では Model は `$ClaudePrivateModel` のみ、Fallback は False (PL < 0.5 の Fallback 既定はパレットの `GetPaletteFallback[]`)。登録には変換結果の `SourceLanguage` / `Translated` / `Format` / `FailedPages` を記録する。
**論文ページは OA PDF から** (2026-10-12): web の HTML ソースにオープンアクセス PDF が結ばれていれば (SourceVault_oapdf.wl。未確認ならその場で `SourceVaultIngestOpenAccessPDF` で探して取り込む) PDF から `DocImportPaper` で作る (数式・図表・段組みが崩れない)。登録はページの SourceId のまま `"Format" -> "pdf"`, `"PDFSourceId" -> <PDF のソース>` を記録し、PDF のソースからも同じノートを引ける。PDF のソースから作った同じ言語のノートがあればそれを `Existing` で返す。PL はページと PDF の大きい方。
Options: "Force" -> False (作り直し), "Open" -> Automatic (False 以外で FE なら開く。既に開いているノートは前面へ出す), "Interactive" -> False (True = 現在のノートブックに評価セルを書いて実行。一覧の「＋ 翻訳NB」がこれ), "Verbose" -> True, "PreferPDF" -> Automatic (False = OA PDF があっても HTML から作る)
Failure: `SourceNotFound` / `UnsupportedFormat` (PDF・HTML・テキスト・Markdown 以外) / `DocumentationNotLoaded` / `PrivateModelUnavailable` / `ImportFailed` (変換が $Failed かファイルを作らなかった)。

### SourceVaultOpenPaperNotebook[ref]
`$Language` の翻訳ノートブックが登録済みなら開く (既に開いていれば前面へ。FE 無しならパス)、無ければ `SourceVaultMakePaperNotebook[ref, "Interactive" -> True]`。

## 計算ノート

1 本の論文ではなく複数素材 (論文・SourceVault の文書・KG のノード・過去のスライド) から作った計算ノートブックを管理する。Id = `cnb-<8桁>`、URI = `sv://computenb/<Id>`。セルの単位 (CellTags `"CNU:<unit>"`) は KG のノードになり、セルの並びは 1 つのストーリーとして KG (GraphId = Id、Kind Notebook) に入る (SlideWorkflow の SlideComputeGraph)。保存: `SourceVaultCoreRoot[]/computenb/registry.json` と `<題名>_<Id>.nb` (File は root 内なら相対パス)。

### SourceVaultComputeNotebookRoot[] → String
計算ノート登録簿と既定保存先のディレクトリ (無ければ作る)。

### SourceVaultComputeNotebookPath[title, id] → String
新規計算ノートの既定パス `<root>/<題名>_<Id>.nb` (題名が空なら `<Id>.nb`)。

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

`SourceVaultEagleView` の 1 列目にも PDF なら「訳」ボタン (`$Language` の訳が登録済みなら太字 = 開く、未登録 = 生成)。`SourceVaultSourcesView` / `SourceVaultArXivView` (`iSVRenderRowsGrid`) に「翻訳NB」列 (種別 arxiv / web / local): `$Language` の訳が登録済み = 「▶ 翻訳NB」(開く)、未登録 = 「＋ 翻訳NB」(生成、tooltip に訳先と継承する PL)。ボタンには SourceId だけを焼く。`DocImportPaper["src-…"]` も同じ経路に委譲する。

## 検証

`test codes/SourceVault_papernb_test.wls` (61、standalone。T10 = 言語ごとの登録、T11 = PDF / Web / 非対応形式の振り分け (documentation は stub)。SourceVault.wl 側の完全修飾と workflowcatalog との名前衝突、`SourceVaultResolveReference` との相互再帰も監視)、`slidegraph_test.wls` T11 (文献 `src-…` → 登録済みノートで Seed)。