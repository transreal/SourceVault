# SourceVault_eagle API リファレンス

パッケージ: `SourceVault`` (コンテキスト `SourceVault``)
リポジトリ: https://github.com/transreal/SourceVault_eagle
依存: SourceVault.wl → SourceVault_eagle.wl
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_eagle.wl"]]`

Eagle ライブラリ (https://eagle.cool) のデータフォルダを SourceVault のソースとして読み書き・検索・要約する。item 引数は metadata Association または id 文字列を受け付ける。

## 設定変数

### $SourceVaultEagleLibrary
型: String, 初期値: (未設定)
現在の Eagle ライブラリ (xxx.library フォルダ) の絶対パス。SourceVaultEagleSetLibrary で切り替える。
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
オンライン/オフライン判定の再チェック間隔秒。到達不能 NAS への繰り返しタイムアウトを避ける。
### $SourceVaultEagleMtimeTTL
型: Integer, 初期値: 5
mtime.json 再読込の間引き秒。大規模ライブラリで連続検索を高速化する。
### $SourceVaultEagleCacheSaveEvery
型: Integer, 初期値: 50
item キャッシュ自動永続化のしきい値 (変更 item 数)。
### $SourceVaultEagleAPIRecheckSeconds
型: Integer, 初期値: 10
Eagle API 死活確認の再チェック間隔秒。SourceVaultEagleRefresh[] で即時再判定。
### $SourceVaultEagleCloudPublishableTag
型: String, 初期値: "Cloud-Publishable"
クラウド要約を許可するタグ名 (大文字小文字無視)。このタグが付いた item は "Method"->Automatic の要約でクラウド経路 ($ClaudeModel に従う: claudecode→Claude Code CLI、codex→Codex CLI、anthropic/openai→課金 API) を使い、summary record に PrivacyLevel 0.0 が記録される。このタグ付き item のサマリーノートでは NBMarkCellConfidential で秘匿マーク済みセルを検索インデックス/Note フィールドから除外する。
### $SourceVaultEaglePrivacyLevel
型: Number|Association, 初期値: 1.0
Eagle View/Dataset/Search/GeoView 出力セルの既定 PrivacyLevel。数値 (全ライブラリ共通) または `<|登録名orライブラリパス -> PL, "Default" -> PL|>`。0.5 以下ならクラウドにも全文可としてマークしない。
### $SourceVaultEagleNotebookStyle
型: String, 初期値: "SourceVault default.nb"
サマリー/フォルダ表示ノートブックの StyleDefinitions。

## ライブラリ管理

### SourceVaultEagleRegisterLibrary[name, path]
Eagle ライブラリを名前付きで登録する。最初の登録は現在ライブラリになる。パスは {"$dropbox", "Eagle", "xxx.library"} 形式のシンボリックパスで永続化 (PrivateVault/eagle/libraries.json) されるため、実パスが異なる PC でも同じ登録が使える。
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
### SourceVaultEagleLibraryOnlineQ[]
現在ライブラリへ到達可能か。判定は $SourceVaultEagleOfflineRecheckSeconds 秒キャッシュされる。
→ True|False
Options: "Library" -> Automatic
### SourceVaultEagleSaveCache[] → Association
item キャッシュを PrivateVault/eagle/itemcache に明示的に永続化する (通常は自動)。

## 読み取り

### SourceVaultEagleLibraryInfo[]
ライブラリ metadata.json の Association (folders/smartFolders/tagsGroups/...) を返す。オフライン時は最後に読めた値を返す。
→ Association
Options: "Library" -> Automatic
### SourceVaultEagleFolders[]
フォルダツリーを平坦化したリストを返す。各要素は Eagle のフォルダ Association + "Path" (祖先名リスト)。
→ List
Options: "Library" -> Automatic
### SourceVaultEagleFolderList[]
フォルダ一覧をノートブックリスト風の表で返す。フォルダ名クリックで SourceVaultEagleFolderView を新規ノートブックに開く。スマートフォルダも既定で含む。
→ Grid|Dataset
Options: "IncludeSmart" -> True (False でスマートフォルダ除外), "Links" -> True (False で素の Dataset を返す)
### SourceVaultEagleSmartFolders[]
スマートフォルダ (保存された検索条件) の平坦化リストを返す。各要素は Eagle の定義 + "Path" + "Supported" (全 rule 評価可能か)。スマートフォルダ名は SourceVaultEagleFolderView/SourceVaultEagleItemsInFolder 等でも通常フォルダ同様に使える (同名がある場合は通常フォルダ優先)。
→ List
### SourceVaultEagleShowFolder[folder, opts] → Null
SourceVaultEagleFolderView を新規ノートブックで開く (front end)。opts は SourceVaultEagleFolderView と同じ。
### SourceVaultEagleFindFolder[nameOrId] → Association|Missing
フォルダを名前または id で検索して返す (children 込み)。
### SourceVaultEagleItems[]
全 item の metadata Association リストを返す (mtime.json による増分キャッシュ。2 回目以降はディスクキャッシュ blob 1 読込 + 差分のみ)。
→ List
Options: "Library" -> Automatic
### SourceVaultEagleItem[id] → Association
item 1 件の metadata を返す。
### SourceVaultEagleItemPath[item] → String
原本ファイルの絶対パスを返す。
### SourceVaultEagleThumbnailPath[item] → String|Missing
サムネイル PNG のパスを返す (無ければ Missing)。
### SourceVaultEagleThumbnail[item] → Image
サムネイル Image を返す (無ければ原本から生成を試みる)。
### SourceVaultEagleItemsInFolder[folder, opts]
フォルダ内 item を返す。folder はフォルダ名/id またはスマートフォルダ名/id (条件を評価して該当 item を返す)。
→ List
Options: "Recursive" -> True (子フォルダも含む), "Library" -> Automatic
### SourceVaultEagleSearch[query, opts]
name/annotation/tags/url + 保存済みサマリー本文の部分一致で item を検索する。"Folder" にはスマートフォルダの名前/id も指定できる。
→ List
Options: "Library" -> Automatic, "Tags" -> Automatic (タグ絞り込みリスト), "TagMode" -> "Any" ("All" で全タグ一致), "Folder" -> Automatic (フォルダ名/id), "Recursive" -> True, "Ext" -> Automatic (拡張子絞り込み), "DateFrom" -> Automatic, "DateTo" -> Automatic, "DateBy" -> "btime" ("mtime" も可), "IncludeDeleted" -> False, "HasAnnotation" -> Automatic, "IncludeSummary" -> True (サマリー本文とノート補足も一致対象), "SortBy" -> Automatic, "SortOrder" -> "Desc", "Newest" -> True, "Limit" -> Automatic
例: SourceVaultEagleSearch["自然計算", "Folder"->"論文", "Ext"->"pdf", "Limit"->20]
### SourceVaultEagleTags[] → Association
タグ -> 使用数の Association と historyTags/starredTags を含む Association を返す。

## 開く

### SourceVaultEagleOpenItem[item] → Null
原本ファイルを SystemOpen で開く。
### SourceVaultEagleShowInApp[item] → Null
eagle://item/<id> で Eagle アプリ内に表示する。

## Eagle ローカル API

### SourceVaultEagleAPIAvailable[] → Association
Eagle アプリの API 到達可否と開いているライブラリを返す。結果は $SourceVaultEagleAPIRecheckSeconds 秒キャッシュされる。
### SourceVaultEagleAPICall[endpoint, params, opts]
Eagle ローカル API を呼ぶ。params があれば POST (JSON)、None または省略で GET。
→ Association
Options: "Timeout" -> 15

## 変更

mutation の "Method" 共通値: Automatic (API が使えて対象ライブラリが開いていれば API、閉じていればファイル直接)、"API" (強制)、"File" (ファイル直接強制。対象ライブラリが Eagle で開いていれば Error)。ファイル直接書込時は変更フィールドのみ上書きし未知フィールドは保存する。modificationTime/lastModified と mtime.json を自動更新する。

### SourceVaultEagleSetTags[item, tags, opts]
item のタグを tags (リスト) で置き換える。
→ Association
Options: "Method" -> Automatic, "Library" -> Automatic
### SourceVaultEagleAddTags[item, tags, opts]
item にタグを追加する。
→ Association
Options: "Method" -> Automatic, "Library" -> Automatic
### SourceVaultEagleRemoveTags[item, tags, opts]
item からタグを除去する。
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
item の所属フォルダを変更する (API 非対応のためファイル直接のみ。Eagle が対象ライブラリを開いている間は Error)。
→ Association
Options: "Method" -> "File", "Library" -> Automatic
### SourceVaultEagleTrashItem[item, opts]
item をゴミ箱へ (isDeleted=true / API moveToTrash)。原本ファイルは消さない。
→ Association
Options: "Method" -> Automatic, "Library" -> Automatic
### SourceVaultEagleCreateFolder[name, opts]
フォルダを作成する。ファイル直接時は metadata.json の backup/ を作成してから書き込む。
→ Association
Options: "Parent" -> Automatic (nameOrId を指定で子フォルダとして作成), "Method" -> Automatic, "Library" -> Automatic
### SourceVaultEagleRenameFolder[folder, newName, opts]
フォルダ名を変更する。
→ Association
Options: "Method" -> Automatic, "Library" -> Automatic
### SourceVaultEagleAddItem[path, opts]
ファイルを Eagle に追加する (API 専用。Eagle 起動時のみ可)。
→ Association
Options: "Name" -> Automatic, "Tags" -> {}, "Annotation" -> "", "URL" -> "", "Folder" -> Automatic

## SourceVault 連携

### SourceVaultEagleIngest[item, opts]
item を SourceVault ソースとして登録する (冪等)。"Copy"->False (既定) は SHA-256 ハッシュ付き参照記録のみを PrivateVault/eagle に残す。"Copy"->True は SourceVaultIngest (TrustLevel LocalFile) で vault へ複製する。
→ Association
Options: "Copy" -> False, "Topic" -> Automatic, "PrivacyLabel" -> Automatic, "Library" -> Automatic
### SourceVaultEagleIngestInfo[item] → Association|Missing
ingest 記録 (Mode->"Reference"|"Vault", ContentHash, SourceId 等) を返す。未 ingest なら Missing。
### SourceVaultEagleIngestFolder[folder, opts]
フォルダ内 item を一括 ingest し統計を返す。既定は参照モード (コピーなし)。
→ Association
Options: "Copy" -> False, "Topic" -> Automatic, "PrivacyLabel" -> Automatic, "Recursive" -> True, "Library" -> Automatic
### SourceVaultEagleExtractText[item, opts]
item 本文テキストを抽出する。PDF は原本から直接ページ抽出 (PrivateVault/eagle/pages にキャッシュ。テキスト層が無いページは $SourceVaultOCRHook 設定時に OCR)。vault 複製済みなら SourceVaultExtractPages 経由。docx/pptx/txt/html/xlsx はローカル抽出。
→ Association (`<|"Status"->"OK","Text"->...|>`)
Options: "MaxPages" -> Automatic, "MaxChars" -> Automatic, "Library" -> Automatic
### SourceVaultEagleSummarize[item, opts]
item のサマリーを LLM で生成・保存する。PDF/Word/PowerPoint/テキストは本文抽出後に要約、画像/動画は vision LLM へ。書誌情報 (Title/Authors/Published) も同時抽出して record に保存する。結果は PrivateVault/eagle/summaries/<id>.json に保存。"WriteAnnotation"->True で Eagle の annotation にも反映。
→ Association
Options: "Method" -> Automatic ("Local" でローカル LLM 強制、"Claude" でクラウド強制。Automatic は Cloud-Publishable タグ有りならクラウド ($ClaudeModel)、無しはローカル ($ClaudePrivateModel)), "MaxLength" -> Automatic, "MaxChars" -> Automatic, "MaxPages" -> Automatic, "Frames" -> Automatic (動画フレーム数), "Language" -> Automatic, "ForceRefresh" -> False, "Ingest" -> False (True で同時 ingest), "Copy" -> False (True で vault 複製), "WriteAnnotation" -> False, "Persist" -> True, "Library" -> Automatic
例: SourceVaultEagleSummarize[item, "Method"->"Claude", "WriteAnnotation"->True]
例: SourceVaultEagleSummarize[item, "ForceRefresh"->True, "Ingest"->True]
### SourceVaultEagleSummary[item]
保存済みサマリー record を返す ("SummaryStatus"->"Current"|"Stale" 付き)。BasedOnMTime/BasedOnSize で item の現在の mtime/size と照合して Current/Stale を判定する。
→ Association|Missing
Options: "Library" -> Automatic
### SourceVaultEagleSummaries[query, opts]
保存済みサマリーの一覧をノートブックリスト風の表で返す。「▶ 開く」クリックで原本を SystemOpen、ファイル名クリックでサマリー全文をウインドウ表示 (Current/Stale 状態付き)。query はサマリー本文/ノート補足/ファイル名の部分一致。
→ Grid
Options: "Limit" -> Automatic
### SourceVaultEagleExtractBibMeta[item, opts]
要約済み item の書誌情報 (Title/Authors/Published) を本文先頭から LLM で抽出し summary record に追記する (旧 record の backfill 用。新規要約は SourceVaultEagleSummarize が同時抽出)。既に Title を持つ record はスキップ。PDF は埋め込みメタデータをフォールバックに使う。
→ Association
Options: "Method" -> Automatic, "MaxChars" -> 2500, "MaxPages" -> 2, "Timeout" -> 120, "ForceRefresh" -> False, "Library" -> Automatic
### SourceVaultEagleExtractBibMetaBatch[query, opts]
保存済みサマリー record のうち書誌情報が無いものへ一括で SourceVaultEagleExtractBibMeta を適用し統計を返す。query は部分一致 ("" で全件)。
→ Association
Options: "Ext" -> Automatic (拡張子絞り込み), "Limit" -> Automatic, + SourceVaultEagleExtractBibMeta と同じ
例: SourceVaultEagleExtractBibMetaBatch["", "Ext"->"pdf", "Limit"->20]
### SourceVaultEagleSummarizeBatch[items, opts]
item リスト (または検索 query 文字列) を一括要約し統計を返す。生成済み (Current) はスキップ。"Method"->Automatic では item ごとに判定: Cloud-Publishable タグ付きはクラウド、それ以外はローカル。
→ Association
Options: "Method" -> Automatic, "Folder" -> Automatic, "Ext" -> Automatic, "Tags" -> Automatic, "DateFrom" -> Automatic, "DateTo" -> Automatic (SourceVaultEagleSearch と同じ検索オプションを併用可), "Limit" -> Automatic, + SourceVaultEagleSummarize と同じ
例: SourceVaultEagleSummarizeBatch["", "Folder"->"自然計算関連", "Ext"->"pdf", "Limit"->2]

## インデックス・AND/OR 検索

### SourceVaultEagleExif[item, opts]
item の Exif record `<|HasExif, Exif, BasedOnMTime, ...|>` を返す。未抽出なら原本から抽出して PrivateVault/eagle/exifindex に BinarySerialize で永続化する (Eagle ライブラリ側は不変)。
→ Association
Options: "Extract" -> True (False なら索引済み分のみ返す), "ForceRefresh" -> False, "Library" -> Automatic
### SourceVaultEagleBuildExifIndex[query, opts]
検索条件に合う画像 item の Exif を一括抽出して索引化する (冪等、抽出済みはスキップ)。NAS 上の大規模ライブラリでは "Limit" で分割推奨。
→ Association
Options: SourceVaultEagleSearch と同じ + "ForceRefresh" -> False
### SourceVaultEagleIndexRecord[item] → Association
検索用の統合 record を返す。キー: Id, Name, Ext, Kind, Star(★数), Width, Height, Megapixels, Size, SizeMB, Added(追加日 DateObject), Created(作成日), Modified(変更日), Tags, Folders, Annotation, URL, Deleted, Summary(サマリー本文), HasSummary, SummaryStatus, Note(サマリーノート補足本文), HasNote, HasExif, CameraModel, TakenAt(撮影日), ISO, FNumber, ExposureTime, FocalLength, GPS, Exif。Exif は SourceVaultEagleBuildExifIndex 済み分のみ (未索引は Missing)。
### SourceVaultEagleIndexSearch[pred, opts]
統合 record (SourceVaultEagleIndexRecord) に述語 pred を適用して検索する。pred 内で && / || を使えば AND/OR 検索になる。"Limit" は pred 適用後に効く。
→ List
Options: SourceVaultEagleSearch と同じ + "Query" -> "" (文字列部分一致)
例: SourceVaultEagleIndexSearch[#Star >= 2 && (#Width >= 3000 || MemberQ[#Tags, "Lumix"]) &]
例: SourceVaultEagleIndexSearch[TrueQ[#HasSummary] && StringContainsQ[#Summary, "自然計算"] &]
### SourceVaultEagleIndexDataset[pred, opts]
SourceVaultEagleIndexSearch の結果を Dataset で返す (Exif 生データ列は除く)。
→ Dataset
Options: SourceVaultEagleIndexSearch と同じ
### SourceVaultEagleFolderView[folder, opts]
フォルダ内のファイル情報一覧 (★/解像度/サイズ/追加・作成・変更日/タグ/サマリー) をノートブックリスト風の表で表示する。ファイル名クリックで原本を SystemOpen、サマリー列 (生成済みの場合) クリックで全文をウインドウ表示。folder はスマートフォルダ名/id も可。切り詰め時は「全 N 件中 n 件」の注記を付ける。
→ Grid
Options: "Recursive" -> False, "Where" -> (True &) (述語による AND/OR 絞り込み。SourceVaultEagleIndexRecord のキーを参照), "SortBy" -> "Added" ("Created"|"Modified"|"Name"|"Size"|"Star"), "SortOrder" -> "Desc", "Limit" -> 200 (All で全件), "IncludeDeleted" -> False, "ShowExif" -> False, "Library" -> Automatic
例: SourceVaultEagleFolderView["論文", "Where"->(#Star >= 2 &), "SortBy"->"Modified"]

## 表示

### SourceVaultEagleSummaryRow[item]
一覧用の低漏洩行を SourceVault 共通スキーマで返す。SourceVaultSourceRow と同じ共通キーを共有し SourceVaultSummaries の横断検索行と互換。
→ Association (キー: Kind("eagle"), Id, Title(書誌タイトル優先、無ければファイル名), Authors, Published, Summary, URL, File, Date, PrivacyLevel, Ext, Size, Tags, Folders, Annotation)
Options: "Library" -> Automatic
### SourceVaultEagleDataset[query, opts]
検索結果を素の Dataset で返す (ボタン無し)。
→ Dataset
Options: SourceVaultEagleSearch と同じ
### SourceVaultEagleView[query, opts]
検索結果を、行ごとに 原本を開く(▶)/Eagle で表示(⌂)/サマリー表示(☰) ボタンとサムネイル付きの表で返す。
→ Dataset
Options: SourceVaultEagleSearch と同じ + "Thumbnails" -> True, "ThumbnailSize" -> Automatic
### SourceVaultEagleShowSummary[item, opts]
サマリーをノートブックで開く (front end)。PrivateVault/eagle/notes/ に保存済みノートがあればそれを開く (補足メモ・図などの追記が残る)。無ければ $SourceVaultEagleNotebookStyle で生成し、ノート内の「保存」ボタンで notes/ に保存できる (以後 Ctrl+S で上書き)。
→ Null
Options: "Fresh" -> False (True で保存版を無視して最新サマリーから作り直す), "Library" -> Automatic
### SourceVaultEagleGeoView[query, opts]
Exif GPS を持つ写真を地図上にサムネイル表示する (クリックで原本を開く)。
→ GeoGraphics
Options: SourceVaultEagleSearch と同じ + "GeoRange" -> Automatic, "MarkerScale" -> Automatic, "ThumbnailSize" -> Automatic

## プライバシー制御

### SourceVaultEagleSetSummaryPrivacy[item, pl] → Association
item の summary record に per-item の "PrivacyLevel" を保存する ($SourceVaultEaglePrivacyLevel より優先)。record が無ければ Error (先に SourceVaultEagleSummarize を実行)。
### SourceVaultEagleMarkViewCells[nb]
Eagle View/Dataset/Search/GeoView の生出力セルを、表示 item の最大 PrivacyLevel で NBAccess`NBMarkCellConfidential する。マーク済み (True/False) セルは触らない。nb 省略時は EvaluationNotebook[]。
→ List (`{<|"Cell"->idx,"PrivacyLevel"->pl|>...}`)
### SourceVaultEagleEnableAutoConfidential[] → Null
NBAccess`NBMakeContextPacket にフックを装着し、ClaudeEval/ClaudeQuery の文脈構築直前に SourceVaultEagleMarkViewCells を自動適用する (冪等)。maildb 側フックが有効な場合は共有 spec 登録経由で Eagle View も対象になるため、本フックは maildb 無し環境向け (併用しても二重マークしない)。
### SourceVaultEagleDisableAutoConfidential[] → Null
SourceVaultEagleEnableAutoConfidential[] のフックのみ解除する (maildb 側フックには影響しない)。