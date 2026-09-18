# SourceVault_papernb API リファレンス

取り込み済み論文 (`src-…` / `sv://snapshot/…` / `arxiv:…` / URL) と Eagle の PDF (`sv://object/eagle-<id>` / `eagle:<id>`、`SourceVaultEagleObjectInfo` で item の実ファイルと実効 PL に解決。SourceId は無いので登録簿は正準 URI で引く) と、`DocImportPaper` (documentation_paper2nb.wl) で作った和訳ノートブックを対応づける登録簿。コンテキスト `SourceVault\`` (private `` `PaperNBPrivate` ``)。service-loadable (FrontEnd / NBAccess / documentation は DownValues guard の弱結合)。

**PL の継承**: 生成ノートブックは元ソースの `PrivacyLevel` を継承する。`CloudPublishable` 宣言 = PL < 0.5 (NBAccess`NBSetCloudPublishable でファイルに書く。NBAccess の経路規則 `NBPrivacyLevelToRoutes` と同じ境界)。翻訳の LLM 経路も PL で決める: PL < 0.5 は既定 (Claude Code CLI / パレットのモデル)、PL ≥ 0.5 は `$ClaudePrivateModel` のみ (未設定なら fail-closed で Failure)。ローカル PDF パスを直接 `DocImportPaper` に渡す従来の呼び方は PL を継承しない (宣言なし)。

保存: `SourceVaultCoreRoot[]/papernb/registry.json` と `papernb/<題名>_<SourceId>.nb`。`File` は root 内なら相対パス (Dropbox の root は PC ごとに違う)。

## 定数

| 記号 | 既定 | 意味 |
|---|---|---|
| `$SourceVaultPaperNBRoot` | Automatic | 保存先 (テストでは隔離ディレクトリ) |

## 関数

### SourceVaultPaperNotebookRoot[] → String

### SourceVaultPaperNotebook[ref] → path | Missing
登録済み和訳ノートブックの絶対パス。`SlideWorkflow` の文献解決 (`iSWSourceNBPath` / References の `"Notebook"` キー) と `SourceVaultResolveReference[..]["Notebook"]` がこれを引く。

### SourceVaultPaperNotebookEntry[ref] → Association | Missing
`<|"SourceId", "URI", "File", "Notebook" (絶対パス), "Title", "PrivacyLevel", "CloudPublishable", "TargetLanguage", "Status", "FailedPages", "Pages", "CreatedAtUTC", "UpdatedAtUTC"|>`。

### SourceVaultRegisterPaperNotebook[ref, nbPath, opts] → entry | Failure
既存ノートブックの登録。opts: `"PrivacyLevel"` (Automatic = 元ソースから。解決できなければ 1.0) / `"Title"` / `"TargetLanguage"` / `"Declare"` (既定 True: `NBSetCloudPublishable`。NBAccess 無しなら `"Declared" -> "Skipped"`) / `"Status"` / `"FailedPages"` / `"Pages"`。同じ SourceId / URI は差分マージ。

### SourceVaultUnregisterPaperNotebook[ref] → True | False

### SourceVaultPaperNotebooks[] → {entry..} / SourceVaultPaperNotebooksView[] → Dataset

### SourceVaultPaperNotebookPath[ref] → String
新規生成の既定パス `<root>/<安全化した題名>_<SourceId>.nb`。

### SourceVaultSourcePrivacy[ref] → Real
元ソースの PL (解決不能は 1.0)。

### SourceVaultMakePaperNotebook[ref, opts] → entry | Failure
登録済みでファイルがあれば生成せず返す (FE なら開く)。無ければ `DocImportPaper[file, "OutputPath" -> 既定パス, "CloudPublishable" -> (PL < 0.5), Model -> PL 経路, ...]` で生成して登録。opts: `"Force"` / `"Open"` / `"Interactive"` (True = 現在のノートブックに評価セルを書いて実行。一覧の「＋ 和訳NB」がこれ) / `"Verbose"` + DocImportPaper のオプション (`"Pages"` / `"Reconstruct"` / `"TargetLanguage"` / `Model` / `Fallback` …)。Failure: `SourceNotFound` / `DocumentationNotLoaded` / `PrivateModelUnavailable` / `ImportFailed`。

### SourceVaultOpenPaperNotebook[ref]
登録済みなら開く、無ければ `SourceVaultMakePaperNotebook[ref, "Interactive" -> True]`。

## 一覧との接続

`SourceVaultEagleView` の 1 列目にも PDF なら「訳」ボタン (登録済みは太字 = 開く、未登録 = 生成)。`SourceVaultSourcesView` / `SourceVaultArXivView` (`iSVRenderRowsGrid`) に「和訳NB」列: 登録済み = 「▶ 和訳NB」(開く)、未登録 = 「＋ 和訳NB」(生成、tooltip に継承する PL)。ボタンには SourceId だけを焼く。`DocImportPaper["src-…"]` も同じ経路に委譲する。

## 検証

`test codes/SourceVault_papernb_test.wls` (31、standalone。SourceVault.wl 側の完全修飾と workflowcatalog との名前衝突、`SourceVaultResolveReference` との相互再帰も監視)、`slidegraph_test.wls` T11 (文献 `src-…` → 登録済みノートで Seed)。
