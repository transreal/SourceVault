# SourceVault_workflowcatalog API Reference

パッケージ: `SourceVault_workflowcatalog`
GitHub: https://github.com/transreal/SourceVault_workflowcatalog
依存: [SourceVault](https://github.com/transreal/SourceVault), [SourceVault_workflowregistry](https://github.com/transreal/SourceVault_workflowregistry)

仕様生成 (`orch/<project>/...`) と実装 (`impl/<slug>/...`) を束ねる "Workflow Catalog" オブジェクトを提供する。stage 管理 (testing/production/archive)、横断検索 provider 登録、一覧 UI を含む。カタログレコードは SourceVault immutable snapshot (class `"WorkflowCatalog"`, pointer `workflow/<slug>/catalog`) として保存される。

## stage の概念

`$SourceVaultWorkflowStages` に含まれる値: `"testing"` | `"production"` | `"archive"`。真実源はフォルダ位置 (`testing/<slug>` / `production/<slug>` / `archive/<slug>`)。`"system"` はルート直下のシステムワークフローで移動不可。

## モデル指定形式

`claudeModel` / `advisaryModel` の指定形式は2通り:
- ローカル LM Studio: `{"lmstudio", "model-name", "http://127.0.0.1:1234"}` (第3要素省略可)
- クラウド: NBAccess 経由のモデルID文字列

両モデルがローカル (`lmstudio`) のときはローカル LLM で要約。それ以外は `ClaudeQueryBg` (クラウド) → ローカル既定 → 機械抽出の順でフォールバック。

## stage 取得・切替

### SourceVaultWorkflowStatus[slug] → String | Missing
slug のフォルダ位置から現在 stage を返す。戻り値: `"system"` | `"testing"` | `"production"` | `"archive"` | `Missing["NotFound"]`。

### SourceVaultSetWorkflowStatus[slug, stage] → Association
slug を指定 stage のフォルダへ移動し、束ねレコードの Status を更新する。`stage` は `"testing"` | `"production"` | `"archive"` のいずれか。システムワークフロー (root) は移動しない。archive は通常一覧・横断検索に表示されない。
戻り値キー: `Status` (`"Moved"` | `"Unchanged"` | `"SystemWorkflow"` | `"NotFound"` | `"BadStage"` | `"DestExists"` | `"MoveFailed"`), `Slug`, `Stage`, `From`, `To`。

### SourceVaultPromoteWorkflow[slug] → Association
`SourceVaultSetWorkflowStatus[slug, "production"]` の短縮形。

### SourceVaultDemoteWorkflow[slug] → Association
`SourceVaultSetWorkflowStatus[slug, "testing"]` の短縮形。

## カタログレコード CRUD

### SourceVaultWorkflowCatalogRecord[slug] → Association | Missing
slug の束ねレコードを返す。pointer `workflow/<slug>/catalog` を `SourceVaultPointerReplay` で解決し immutable snapshot をロードする。無ければ `Missing["NoCatalog"]`。
戻り値キー例: `Slug`, `Name`, `Summary`, `Keywords`, `Project`, `SpecURI`, `SpecModels`, `ImplModels`, `SummaryMethod`, `SourceNotebookURI`, `Status`, `CreatedAtUTC`, `UpdatedAtUTC`, `Version` (pointer Sequence 由来)。

### SourceVaultRegisterWorkflowCatalog[slug, assoc] → Association
slug の束ねレコードを assoc で更新 (既存レコードとマージ) し immutable snapshot + pointer `workflow/<slug>/catalog` として保存する。`Version` は snapshot に焼かず pointer Sequence を使う。
戻り値はマージ済みレコードに `Ref` と `Version` を追加した Association。保存失敗時は `<|"Status" -> "SaveFailed", "Slug" -> slug|>`。

## カタログ一覧

### SourceVaultWorkflowCatalog[] → Dataset
生成ワークフロー (testing/production) の束ねカタログ一覧を Dataset で返す。system ワークフローは含まない。
列: `Slug`, `Stage`, `Name`, `Summary`, `Keywords`, `Project`, `SpecURI`, `SpecModels`, `ImplModels`, `SummaryMethod`, `SourceNotebookURI`, `Loaded`, `Context`, `Path`, `UpdatedAtUTC`。

## 要約生成

### SourceVaultWorkflowSummarize[slug, opts]
slug の仕様 (SpecURI snapshot 優先、無ければ `example.md` + コード冒頭) から Summary + Keywords を LLM 生成し束ねレコードへ保存する。モデルペアは `ImplModels` > `SpecModels` > ローカル既定の順で決定。
→ Association `<|"Status" -> "Done"|"NoSpec", "Slug", "Method", "Summary", "Keywords"|>`
Options: `"Language" -> Automatic` (Automatic で `$Language` を使用、未設定なら `"Japanese"`), `"Timeout" -> 180` (秒)

### SourceVaultWorkflowSummarizeText[specText, claudeModel, advisaryModel, opts]
仕様テキストとモデルペアから要約を生成する純関数。`SourceVaultWorkflowSummarize` の内部実装だが単体でも使える。
→ Association `<|"Summary" -> String, "Keywords" -> List, "Method" -> "Local"|"Cloud"|"Extract"|"Empty"|>`
Options: `"Language" -> Automatic`, `"Timeout" -> 180`
例: `SourceVaultWorkflowSummarizeText["仕様テキスト...", {"lmstudio","phi-4","http://127.0.0.1:1234"}, {"lmstudio","phi-4","http://127.0.0.1:1234"}]`

## 元ノートブック登録・解決

### SourceVaultRegisterSourceNotebook[path] → String
notebook の絶対パスをシンボリックパスに変換し `"WorkflowSourceNotebook"` snapshot として保存、URI 文字列 (`"sv://snapshot/..."`) を返す。保存不可 (未保存等) のとき `""` を返す。仕様/カタログオブジェクトにはパスでなくこの URI を記録する。

### SourceVaultSourceNotebookPath[uri] → String | Missing
`SourceVaultRegisterSourceNotebook` が返した URI を現 PC の絶対パスへ解決する。解決不可なら `Missing["Unresolved"]`、URI 未指定なら `Missing["NoURI"]`。

### SourceVaultOpenSourceNotebook[uri] → NotebookObject | $Failed
URI が指す元 notebook を開く (既に開いていれば前面化)。ファイルが見つからない/移動された場合は `MessageDialog` で通知。

## UI

### SourceVaultWorkflowPanel[] → Panel
archive を除く testing/production ワークフローの一覧 UI を返す。列: stage バッジ、名前/サマリー (名前クリックで元ノートブックを開く)、起動 (example.md を実行可能セルとして新規ノートに展開)、切替/保管 (testing↔production + アーカイブ送り)、要約更新、フォルダ。検索行右端「アーカイブ」ボタンで `SourceVaultWorkflowArchivePanel` を別ウインドウに開く。手動更新 (`UpdateInterval` 不使用、`TrackedSymbols` のみ)。

### SourceVaultWorkflowArchivePanel[] → Panel
archive ステージのワークフローのみを一覧する UI。`SourceVaultWorkflowPanel` と同体裁。切替列は「testingへ戻す」ボタン (`SourceVaultSetWorkflowStatus[slug, "testing"]`)。

## 移行ユーティリティ

### SourceVaultMigrateWorkflowsToStages[opts]
`SourceVault_workflows/` ルート直下の生成ワークフロー (システムワークフローを除く) を testing/production サブフォルダへ一括移行する (冪等)。slug 比較は Unicode 結合濁点 (U+3099/U+309A) を除去して行う。
→ Dataset (列: `Slug`, `Stage`, `Status` (`"Moved"` | `"DestExists"` | `"MoveFailed"`))
Options:
- `"Production" -> {}` (production に移すスラッグリスト)
- `"Testing" -> {}` (testing に移すスラッグリスト)
- `"Default" -> "testing"` (リストに含まれない slug のデフォルト stage)
- `"SystemSlugs" -> {"spec-review", "spec-impl"}` (移行から除外するシステム slug)
- `"Summarize" -> False` (True にすると移行後に各 slug の要約を生成)

例: `SourceVaultMigrateWorkflowsToStages["Production" -> {"my-tool"}, "Summarize" -> True]`

## 横断検索プロバイダ (内部登録)

ロード時に `SourceVaultRegisterSummaryProvider["workflow", ...]` を呼び出し、横断検索 (`SourceVaultSearch` 等) に `"workflow"` Kind として統合する。archive の行は横断検索にも表示しない。共通行スキーマ: `Kind`, `Id` (= Slug), `URI` (`"sv://workflow/<slug>"`), `Title`, `Summary`, `File` (= Path), `Date` (= UpdatedAtUTC), `Stage`。