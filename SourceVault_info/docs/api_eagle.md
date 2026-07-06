# SourceVault_eagle API Reference

パッケージ `SourceVault_eagle` は [Eagle](https://eagle.cool) ライブラリを SourceVault のソースとして読み書きするアダプタである。
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_eagle.wl"]]`
依存: SourceVault.wl → SourceVault_core.wl → SourceVault_eagle.wl の順でロード。

**item 指定**: 各関数の `item` 引数は Eagle item の id 文字列、または `SourceVaultEagleItem` / `SourceVaultEagleItems` が返す metadata Association を受け付ける。

## 設定変数

### $SourceVaultEagleLibrary
型: String, 初期値: (未設定)
現在の Eagle ライブラリ (xxx.library フォルダ) の絶対パス。`SourceVaultEagleSetLibrary` で切替。

### $SourceVaultEagleAPIBase
型: String, 初期値: "http://localhost:41595"
Eagle ローカル API のベース URL。

### $SourceVaultEagleAPIToken
型: String|None, 初期値: None
Eagle API トークン (環境設定→開発者向け)。None なら付与しない。

### $SourceVaultEagleStoreRoot
型: String, 初期値: PrivateVault/eagle
Eagle 連携データ (ingest 対応表・summary・ファイルバックアップ) の保存先。

### $SourceVaultEagleOfflineRecheckSeconds
型: Integer, 初期値: 60
オンライン/オフライン判定の再チェック間隔秒。到達不能 NAS への繰り返しタイムアウトを防ぐ。

### $SourceVaultEagleMtimeTTL
型: Integer, 初期値: 5
mtime.json 再読込の間引き秒。大規模ライブラリで連続検索を高速化する。

### $SourceVaultEagleCacheSaveEvery
型: Integer, 初期値: 50
item キャッシュ自動永続化のしきい値 (変更 item 数)。

### $SourceVaultEagleAPIRecheckSeconds
型: Integer, 初期値: 10
Eagle API 死活確認の再チェック間隔秒。`SourceVaultEagleRefresh[]` で即時再判定。

### $SourceVaultEagleCloudPublishableTag
型: String, 初期値: "Cloud-Publishable"
クラウド要約を許可するタグ名 (大文字小文字無視)。このタグが付いた item は "Method"->Automatic の要約でクラウド経路を使い、summary record に PrivacyLevel 0.0 が記録される。クラウド経路は `$ClaudeModel` の provider 準拠: claudecode/未設定→Claude Code CLI、chatgptcodex/codex→Codex CLI (テキストのみ。画像/動画は Codex 未対応のため Claude Code CLI にフォールバックする)。anthropic/openai を明示した場合のみ課金 API を使う。Cloud-Publishable 付き item のサマリーノートでは NBMarkCellConfidential で confidential マークされたセル (privacyLevel > 0.5) を検索インデックス/Note フィールドから除外する。タグ無し item のノートは全文がローカル検索対象 (メタ情報はライブラリ既定 PL の fail-safe マーキングが前提)。

### $SourceVaultEagleNotebookStyle
型: String, 初期値: "SourceVault default.nb"
サマリー/フォルダ表示ノートブックの StyleDefinitions。

### $SourceVaultEaglePrivacyLevel
型: Number|Association, 初期値: 1.0
Eagle View/Dataset/Search/GeoView 出力セルの既定 PrivacyLevel。数値 (全ライブラリ共通) または `<|登録名orライブラリパス -> PL, "Default" -> PL|>`。0.5 以下ならクラウドにも全文可としてマークしない。

## ライブラリ登録・管理

### SourceVaultEagleRegisterLibrary[name, path]
Eagle ライブラリを名前付きで登録する。最初の登録は現在ライブラリになる。パスは `{"$dropbox", "Eagle", "xxx.library"}` 形式のシンボリックパスで `PrivateVault/eagle/libraries.json` に永続化され、実パスが異なる PC でも同じ登録が使える。
→ Association
Options: "Persist" -> True (False で今セッション限り)

### SourceVaultEagleLibraries[] → Association
登録済みライブラリ `<|name -> path|>` を返す (永続化分は自動ロード)。

### SourceVaultEagleSetLibrary[nameOrPath] → Association
現在ライブラリを切り替え、選択を永続化する。

### SourceVaultEagleUnregisterLibrary[name] → Association
ライブラリ登録を削除する (永続化にも反映)。

### SourceVaultEagleStatus[] → Association
現在ライブラリ・item/folder 数・API 状態・summary/ingest 件数の概要を返す。

### SourceVaultEagleRefresh[] → Association
item/メタ/オンライン判定キャッシュを破棄して次回アクセス時に再読込・再判定させる (ディスク永続キャッシュは残る)。

### SourceVaultEagleLibraryOnlineQ[opts] → True|False
現在ライブラリへ到達可能か (NAS オフライン検知)。判定は `$SourceVaultEagleOfflineRecheckSeconds` 秒キャッシュされる。
Options: "Library" -> Automatic

### SourceVaultEagleSaveCache[] → Association
item キャッシュを `PrivateVault/eagle/itemcache` に明示的に永続化する (通常は自動)。

## 読み取り

### SourceVaultEagleLibraryInfo[opts] → Association
ライブラリ `metadata.json` の Association (folders/smartFolders/tagsGroups/...) を返す。オフライン時はキャッシュ値を返す。
Options: "Library" -> Automatic

### SourceVaultEagleFolders[opts] → List
フォルダツリーを平坦化したリストを返す。各要素は Eagle フォルダ Association + "Path" (祖先名リスト)。
Options: "Library" -> Automatic

### SourceVaultEagleFolderList[opts]
フォルダ一覧 (フォルダ/種別/件数/Id/更新日) をノートブックリスト風の表で返す。フォルダ名クリックで `SourceVaultEagleFolderView` を新規ノートブックに開く。
→ Grid (または Dataset)
Options: "IncludeSmart" -> True (False でスマートフォルダを除外), "Links" -> True (False で素のデータ行 Dataset を返す), "Library" -> Automatic

### SourceVaultEagleSmartFolders[opts] → List
スマートフォルダ (保存された検索条件) の平坦化リストを返す。各要素は Eagle の定義 + "Path" + "Supported" (全 rule を評価可能か)。スマートフォルダ名は各関数の "Folder" 指定でも通常フォルダ同様に使える (同名がある場合は通常フォルダ優先)。
Options: "Library" -> Automatic

### SourceVaultEagleShowFolder[folder, opts]
`SourceVaultEagleFolderView` を新規ノートブックで開く (front end)。opts は `SourceVaultEagleFolderView` と同じ。

### SourceVaultEagleFindFolder[nameOrId] → Association | Missing
フォルダを名前または id で検索して返す (children 込み)。見つからなければ Missing。

### SourceVaultEagleItems[opts] → List
全 item の metadata Association リストを返す (mtime.json による増分キャッシュ)。
Options: "Library" -> Automatic

### SourceVaultEagleItem[id, opts] → Association
item 1 件の metadata を返す。
Options: "Library" -> Automatic

### SourceVaultEagleItemPath[item, opts] → String
原本ファイルの絶対パスを返す。
Options: "Library" -> Automatic

### SourceVaultEagleThumbnailPath[item, opts] → String | Missing
サムネイル PNG のパスを返す (無ければ Missing)。
Options: "Library" -> Automatic

### SourceVaultEagleThumbnail[item, opts] → Image
サムネイル Image を返す (無ければ原本から生成を試みる)。
Options: "Library" -> Automatic

### SourceVaultEagleItemsInFolder[folder, opts] → List
フォルダ内 item を返す。folder は通常フォルダの名前/id に加え、スマートフォルダの名前/id も指定できる (条件を評価して該当 item を返す)。
Options: "Recursive" -> True (子フォルダも含む), "Library" -> Automatic

### SourceVaultEagleSearch[query, opts]
name/annotation/tags/url + 保存済みサマリー本文の部分一致 + 各種フィルタで item を検索する。"Folder" にはスマートフォルダの名前/id も指定できる。query は "" で全件マッチ。
→ List
Options:
"Library" -> Automatic,
"Tags" -> Automatic (タグ絞り込み、文字列または文字列リスト),
"TagMode" -> "Any" ("Any"|"All"),
"Folder" -> Automatic (フォルダ名または id),
"Recursive" -> True,
"Ext" -> Automatic (拡張子絞り込み、例: "pdf"),
"DateFrom" -> Automatic (DateObject または {年,月,日}),
"DateTo" -> Automatic,
"DateBy" -> "btime" ("btime"|"mtime"),
"IncludeDeleted" -> False,
"HasAnnotation" -> Automatic,
"IncludeSummary" -> True (サマリー本文・動画フレーム記述・notes/ 補足を一致対象に含む),
"SortBy" -> Automatic,
"SortOrder" -> "Desc",
"Newest" -> True,
"Limit" -> Automatic
例: `SourceVaultEagleSearch["自然計算", "Folder"->"自然計算関連", "Ext"->"pdf", "Limit"->20]`

### SourceVaultEagleTags[opts] → Association
タグ -> 使用数の Association と historyTags/starredTags を返す。
Options: "Library" -> Automatic

## 開く

### SourceVaultEagleOpenItem[item]
原本ファイルを `SystemOpen` で開く。

### SourceVaultEagleShowInApp[item]
`eagle://item/<id>` で Eagle アプリ内に表示する。

## Eagle ローカル API

### SourceVaultEagleAPIAvailable[] → Association
Eagle アプリの API 到達可否と開いているライブラリを返す。結果は `$SourceVaultEagleAPIRecheckSeconds` 秒キャッシュされる (Eagle 未起動時の接続待ちを繰り返さない)。

### SourceVaultEagleAPICall[endpoint, params, opts]
Eagle ローカル API を呼ぶ。params (Association) があれば POST (JSON)、None または省略なら GET。
→ Association
Options: "Timeout" -> 15

## 変更 (Eagle 形式準拠)

書込は Eagle が自分で書く JSON のみ。未知フィールドは `Import("RawJSON") → 変更 → Export("RawJSON")` で完全保全する。item 変更時は modificationTime/lastModified (epoch ms) と mtime.json を自動更新する。ライブラリ metadata.json 変更時は `backup/backup-<日時>.json` を事前作成する。

"Method" -> Automatic|"API"|"File": Automatic は API が使えて対象ライブラリが開いていれば API、閉じていればファイル直接。"API" 強制は Eagle 未起動なら Error。"File" 強制は対象ライブラリが Eagle で開かれていれば Error。

### SourceVaultEagleSetTags[item, tags, opts]
item のタグを tags リストで置き換える。新規タグは `tags.json` の historyTags にもマージされる。
→ Association
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleAddTags[item, tags, opts]
item にタグを追加する (既存タグは保持)。
→ Association
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleRemoveTags[item, tags, opts]
item から指定タグを除去する。
→ Association
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleSetAnnotation[item, text, opts]
item の annotation を設定する。
→ Association
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleSetURL[item, url, opts]
item の url を設定する。
→ Association
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleMoveToFolder[item, folder, opts]
item の所属フォルダを変更する (Eagle API 非対応のためファイル直接のみ。Eagle が対象ライブラリを開いている間は Error)。
→ Association
Options: "Library" -> Automatic

### SourceVaultEagleTrashItem[item, opts]
item をゴミ箱へ移動する (isDeleted=true / API moveToTrash)。原本ファイルは削除しない。
→ Association
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleCreateFolder[name, opts]
フォルダを作成する。ファイル直接時は backup/ を作ってから書く。
→ Association
Options: "Parent" -> Automatic (nameOrId で子フォルダ指定), "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleRenameFolder[folder, newName, opts]
フォルダ名を変更する。
→ Association
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleAddItem[path, opts]
ファイルを Eagle に追加する (API 専用。Eagle 起動時のみ可。ファイル直接生成はしない)。
→ Association
Options: "Name" -> Automatic, "Tags" -> {}, "Annotation" -> "", "URL" -> "", "Folder" -> Automatic

## SourceVault 連携

### SourceVaultEagleIngest[item, opts]
item を SourceVault ソースとして登録する (冪等)。既定 "Copy"->False: 原本はコピーせず SHA-256 ハッシュ付き参照記録のみを `PrivateVault/eagle/ingestmap.jsonl` に残す (Mode->"Reference")。"Copy"->True で `SourceVaultIngest` (TrustLevel LocalFile) により vault へ複製する (Mode->"Vault")。オフライン中でも "Online"->False 付きで登録可能。
→ Association
Options: "Copy" -> False, "Topic" -> Automatic, "PrivacyLabel" -> Automatic, "Library" -> Automatic

### SourceVaultEagleIngestInfo[item] → Association | Missing
ingest 記録 (Mode->"Reference"|"Vault", ContentHash, SourceId 等) を返す。未 ingest なら Missing。

### SourceVaultEagleIngestFolder[folder, opts]
フォルダ内 item を一括 ingest し統計を返す。既定は参照モード (コピーなし)。
→ Association
Options: "Copy" -> False, "Topic" -> Automatic, "PrivacyLabel" -> Automatic, "Recursive" -> True, "Library" -> Automatic

### SourceVaultEagleExtractText[item, opts]
item 本文テキストを抽出する。PDF は原本から直接ページ抽出 (`PrivateVault/eagle/pages` にキャッシュ、テキスト層なしページは `$SourceVaultOCRHook` 設定時に OCR)。vault 複製済みなら `SourceVaultExtractPages` 経由。docx/pptx/txt/html/xlsx/csv はローカル抽出。
→ Association
Options: "MaxPages" -> Automatic, "MaxChars" -> Automatic, "Library" -> Automatic

### SourceVaultEagleSummarize[item, opts]
item のサマリーを LLM で生成・保存する。PDF/Word/PowerPoint/テキストは本文抽出後に要約し書誌情報 (Title/Authors/Published) も同時抽出する。画像はサムネイル優先 (原本フォールバック) で vision 要約する。動画は 2 段 pipeline: Stage 1 で n フレーム ("Frames" 個、nested dyadic 位置) を各 "FrameMaxLength" 文字で個別 vision 記述し record の `"Frames"[*]."Text"` に保存、Stage 2 でフレーム説明を時刻順統合して最終 summary を生成する。既定はローカル LLM (`$ClaudePrivateModel`)。`$SourceVaultEagleCloudPublishableTag` タグ付き item は Automatic でもクラウドへ切り替わる。PDF・画像・動画が混在するフォルダでも batch/summaries/search が一貫動作する (動画は vision 呼び出しが n 回になるためコスト増)。summary は `PrivateVault/eagle/summaries/<id>.json` に保存。
→ Association
Options:
"Method" -> Automatic ("Local"|"Claude"),
"MaxLength" -> Automatic (サマリーの最大文字数),
"MaxChars" -> Automatic (本文抽出の最大文字数),
"MaxPages" -> Automatic (PDF の最大ページ数),
"Frames" -> 5 (動画フレーム数。後から大きい n を指定すると不足分だけ追加 vision),
"FrameMaxLength" -> 200 (各フレーム記述の上限文字数),
"Language" -> Automatic,
"ForceRefresh" -> False,
"Ingest" -> True,
"Copy" -> False,
"WriteAnnotation" -> False (True で Eagle の annotation にも反映),
"Persist" -> True,
"Library" -> Automatic
例: `SourceVaultEagleSummarize[item, "Method"->"Claude", "Frames"->10, "WriteAnnotation"->True]`
例: `SourceVaultEagleSummarize[item, "ForceRefresh"->True, "Frames"->20]` (動画の粒度を上げて再生成)

### SourceVaultEagleSummary[item, opts] → Association | Missing
保存済みサマリー record を返す ("SummaryStatus"->"Current"|"Stale" 付き)。無ければ Missing。
Options: "Library" -> Automatic

### SourceVaultEagleSummaries[query, opts]
保存済みサマリーの一覧をノートブックリスト風の表で返す。query はサマリー本文/ノート補足/ファイル名の部分一致 ("" で全件)。「▶ 開く」クリックで原本を SystemOpen、ファイル名クリックでサマリー全文をウインドウ表示 (Current/Stale 状態付き)。
→ Grid
Options: "Limit" -> Automatic

### SourceVaultEagleExtractBibMeta[item, opts]
要約済み item の書誌情報 (Title/Authors/Published) を本文先頭から LLM で抽出し summary record に追記する (旧 record の backfill 用。新規要約は `SourceVaultEagleSummarize` が同時抽出)。PDF は埋め込みメタデータをフォールバックに使う。既に Title を持つ record はスキップ ("ForceRefresh"->True で再抽出)。
→ Association
Options: "Method" -> Automatic, "MaxChars" -> 2500, "MaxPages" -> 2, "Timeout" -> 120, "ForceRefresh" -> False, "Library" -> Automatic

### SourceVaultEagleExtractBibMetaBatch[query, opts]
保存済みサマリー record のうち書誌情報が無いものへ一括で `SourceVaultEagleExtractBibMeta` を適用し統計を返す。query は部分一致 ("" で全件)。
→ Association
Options: "Ext" -> Automatic, "Limit" -> Automatic, + SourceVaultEagleExtractBibMeta と同じ全オプション
例: `SourceVaultEagleExtractBibMetaBatch["", "Ext"->"pdf", "Limit"->20]`

### SourceVaultEagleSummarizeBatch[items, opts]
item リスト (または検索 query 文字列) を一括要約し統計を返す。生成済み (Current) はスキップ。Kind (PDF/Word/PowerPoint/Sheet/Text/Image/Video) ごとに自動 dispatch するため、種別が混在するフォルダでも一括処理できる (動画はフレーム数ぶん vision 呼び出しが増えるためコスト・時間に注意)。1 件の失敗で全体を止めない。"Method"->Automatic では item ごとに判定: Cloud-Publishable タグ付きはクラウド (`$ClaudeModel`)、それ以外はローカル (`$ClaudePrivateModel`)。
→ Association
Options:
"Method" -> Automatic,
"Folder" -> Automatic, "Ext" -> Automatic, "Tags" -> Automatic, "TagMode" -> "Any",
"DateFrom" -> Automatic, "DateTo" -> Automatic, "DateBy" -> "btime" (SourceVaultEagleSearch と同じ絞り込み),
"Limit" -> Automatic (要約件数の上限),
"Frames" -> 5, "FrameMaxLength" -> 200,
"ForceRefresh" -> False,
"Library" -> Automatic
例: `SourceVaultEagleSummarizeBatch["", "Folder"->"自然計算関連", "Ext"->"pdf", "Limit"->2]`

## インデックス・AND/OR 検索

### SourceVaultEagleExif[item, opts] → Association
item の Exif record `<|HasExif, Exif, BasedOnMTime, ...|>` を返す。未抽出なら原本から抽出して `PrivateVault/eagle/exifindex` に BinarySerialize で永続化 (Eagle 側は不変)。
Options: "Extract" -> True, "ForceRefresh" -> False, "Library" -> Automatic

### SourceVaultEagleBuildExifIndex[query, opts]
検索条件に合う画像 item の Exif を一括抽出して索引化する (冪等、抽出済みはスキップ)。NAS 上の大規模ライブラリでは "Limit" で分割推奨。
→ Association
Options: SourceVaultEagleSearch と同じ全オプション + "ForceRefresh" -> False

### SourceVaultEagleIndexRecord[item] → Association
検索用の統合 record を返す:
`<|Id, Name, Ext, Kind, Star(★数), Width, Height, Megapixels, Size, SizeMB, Added(追加日), Created(作成日), Modified(変更日), Tags, Folders, Annotation, URL, Deleted, Summary(保存済みサマリー本文), HasSummary, SummaryStatus, FrameCount(動画のフレーム数、動画以外は Missing), Note(サマリーノート補足), HasNote, HasExif, CameraModel, TakenAt(撮影日), ISO, FNumber, ExposureTime, FocalLength, GPS, Exif|>`
日付は DateObject。Exif は `SourceVaultEagleBuildExifIndex` 済み分のみ (未索引は Missing)。

### SourceVaultEagleIndexSearch[pred, opts]
統合 record (`SourceVaultEagleIndexRecord`) に述語 pred を適用して検索する。pred 内で `&&` / `||` を使えば AND/OR 検索になる。
→ List
Options: SourceVaultEagleSearch と同じ全オプション + "Query" -> Automatic (文字列部分一致、pred と AND 評価)
例: `SourceVaultEagleIndexSearch[#Star >= 2 && (#Width >= 3000 || MemberQ[#Tags, "Lumix"]) &]`
例: `SourceVaultEagleIndexSearch[TrueQ[#HasSummary] && StringContainsQ[#Summary, "自然計算"] &]`

### SourceVaultEagleIndexDataset[pred, opts]
`SourceVaultEagleIndexSearch` の結果を Dataset で返す (Exif 生データ列は除く)。
→ Dataset
Options: SourceVaultEagleIndexSearch と同じ全オプション

### SourceVaultEagleFolderView[folder, opts]
フォルダ内のファイル情報一覧 (★/解像度/サイズ/追加・作成・変更日/タグ/サマリー) をノートブックリスト風の表で表示する。ファイル名クリックで原本を SystemOpen、サマリー列クリックで全文をウインドウ表示。folder はスマートフォルダ名/id も可。
→ Grid
Options:
"Recursive" -> False,
"Where" -> None (述語 Function による AND/OR 絞り込み。SourceVaultEagleIndexRecord と同じ統合 record を受ける),
"SortBy" -> "Added" ("Added"|"Created"|"Modified"|"Name"|"Size"|"Star"),
"SortOrder" -> "Desc",
"Limit" -> 200 (All で全件。切り詰め時は「全 N 件中 200 件」の注記付き),
"IncludeDeleted" -> False,
"ShowExif" -> False,
"Library" -> Automatic

## 表示

### SourceVaultEagleSummaryRow[item, opts] → Association
一覧用の低漏洩行を SourceVault 共通スキーマで返す:
`<|Kind("eagle"), Id, URI("sv://object/eagle-<id>"), Title, Authors, Published, Summary, URL, File, Date, PrivacyLevel|>` + eagle 固有の `<|Ext, Size, Tags, Folders, Annotation|>`
`SourceVaultSourceRow` (SourceVault.wl) と同じ共通キーを共有し、`SourceVaultSummaries` の横断検索行と互換。混在データセットの汎用 join/参照キーは "URI"。旧キー "Name" は "Title" に改名。
Options: "Library" -> Automatic

### SourceVaultEagleDataset[query, opts]
検索結果を素の Dataset で返す (ボタン無し、プログラム処理用)。
→ Dataset
Options: SourceVaultEagleSearch と同じ全オプション

### SourceVaultEagleView[query, opts]
検索結果を行ごとに 原本を開く(▶)/Eagle で表示(⌂)/サマリー表示(☰) ボタンとサムネイル付きの表で返す。列: ▶/⌂/☰・サムネイル・Date・Name・Ext・Size・Tags・Summary(先頭 150 字、全文は☰)・PL(実効 PrivacyLevel)・URI(`sv://object/eagle-<id>`、`SourceVaultMCPGet` で解決可)。
→ Dataset
Options: SourceVaultEagleSearch と同じ全オプション + "Thumbnails" -> True, "ThumbnailSize" -> Automatic

### SourceVaultEagleShowSummary[item, opts]
サマリーをノートブックで開く (front end)。`PrivateVault/eagle/notes/` に保存済みノートがあればそれを開く (補足メモ・図などの追記が残る)。無ければ `$SourceVaultEagleNotebookStyle` スタイルで生成し「保存」ボタンで notes/ に保存できる。
Options: "Fresh" -> False (True で保存版を無視して最新サマリーから作り直す), "Library" -> Automatic

### SourceVaultEagleGeoView[query, opts]
Exif GPS を持つ写真を地図上にサムネイル表示する (クリックで原本を開く)。
→ GeoGraphics
Options: SourceVaultEagleSearch と同じ全オプション + "GeoRange" -> Automatic, "MarkerScale" -> 1, "ThumbnailSize" -> Automatic

## プライバシー制御

### SourceVaultEagleSetSummaryPrivacy[item, pl] → Association
item の summary record に per-item の "PrivacyLevel" を保存する (ライブラリ既定 `$SourceVaultEaglePrivacyLevel` より優先)。record が無ければ Error (先に `SourceVaultEagleSummarize` を実行)。

### SourceVaultEagleMarkViewCells[nb] → List
Eagle View/Dataset/Search/GeoView の生出力セルを、表示 item の最大 PrivacyLevel で `NBAccess\`NBMarkCellConfidential` する。マーク済み (True/False) セルは触らない。nb 省略時は `EvaluationNotebook[]`。
戻り値: `{<|"Cell"->idx, "PrivacyLevel"->pl|>...}`

### SourceVaultEagleEnableAutoConfidential[]
`NBAccess\`NBMakeContextPacket` にフックを装着し、ClaudeEval/ClaudeQuery の文脈構築直前に `SourceVaultEagleMarkViewCells` を自動適用する (冪等)。SourceVault_maildb.wl の `SourceVaultMailEnableAutoConfidential` が有効な場合は共有 spec 登録経由で Eagle View も対象になるため本フックは maildb 無し環境向け (併用しても二重マークしない)。

### SourceVaultEagleDisableAutoConfidential[]
`SourceVaultEagleEnableAutoConfidential[]` のフックのみ解除する (maildb 側フックには影響しない)。

## オブジェクトビュー (sv:// URI)

### SourceVaultObjectToCell[uri, opts]
sv:// オブジェクトの内容/プロパティをノートブックのセルに出力し、そのセルの PrivacyLevel をオブジェクトの privacy level に継承する (level > 0.5 なら confidential マーク)。ノートブックが無い (headless) 場合は `Status->"NoNotebook"` で値だけ返す。
→ Association `<|Status, URI, PrivacyLevel, Confidential, Cells|>`
Options: "Notebook" -> Automatic (省略時 `InputNotebook[]`), "Show" -> "Both" ("Data"|"Properties"|"Both")

## 動作原則

**オフライン時**: 読み取り系はメモリ/ディスクキャッシュ上の最後に見えた状態をエラー無しで返す。書込系・原本アクセス系は `<|"Status"->"Error","Reason"->"LibraryOffline"|>` を静かに返す (Message なし)。保存済みサマリーはオフラインでも返る。オフライン中でも "Online"->False 付きで ingest 登録は可能。

**item キャッシュ**: `PrivateVault/eagle/itemcache/` に BinarySerialize で永続化。2 回目以降のセッションは blob 1 読込 + mtime.json 差分のみ。mtime.json の再読込は `$SourceVaultEagleMtimeTTL` 秒で間引く。

**URI スキーム**: Eagle item の正準 SourceVault URI は `"sv://object/eagle-<id>"`。`sourcevault_get` / `SourceVaultMCPGet` で解決可。`SourceVaultEagleView` の URI 列に表示される。

**Kind 分類** (SourceVaultEagleExtractText / SourceVaultEagleSummarize が内部で使用):
- "PDF": pdf
- "Word": doc, docx
- "PowerPoint": ppt, pptx
- "Sheet": xls, xlsx, csv
- "Text": txt, md, htm, html, json, tex, wl, m, nb, py, r
- "Image": jpg, jpeg, png, gif, bmp, webp, heic, heif, tif, tiff
- "Video": mp4, mov, avi, mkv, webm, m4v, wmv
- "Audio": mp3, wav, m4a, flac, ogg
- "Other": 上記以外