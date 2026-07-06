# SourceVault_eagle API リファレンス

Eagle ライブラリ (https://eagle.cool) のデータフォルダを SourceVault のソースとして読み書きするアダプタ。読み取り・検索・オープン・Eagle-API 経由のメタ変更・SourceVault ingest・LLM サマリーを提供する。context は `SourceVault``。ロードは `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_eagle.wl"]]`。

## 概要
Eagle データフォルダ (`xxx.library`) 内の以下を扱う:
- `<lib>/metadata.json` — フォルダツリー / smartFolders / tagsGroups
- `<lib>/tags.json` — historyTags / starredTags
- `<lib>/mtime.json` — itemId→lastModified(ms)、"all"→総 item 数
- `<lib>/backup/backup-*.json` — metadata.json の Eagle 形式バックアップ
- `<lib>/images/<ID>.info/` — 原本ファイル / `<name>_thumbnail.png` / metadata.json

## 設計原則 (Eagle 形式準拠・絶対遵守)
1. 原本ファイル・サムネイルには一切書き込まない (read-only)。
2. 書込は Eagle が自分で書く JSON のみ。既知フィールドだけ変更し、未知フィールドは `Import("RawJSON")→変更→Export("RawJSON")` で完全保存。
3. item metadata 変更時は modificationTime / lastModified (epoch ms) を更新し mtime.json の該当エントリを同期。"all" は総 item 数なので書き換えない。
4. ライブラリ metadata.json 変更時は事前に `backup/backup-<Eagle命名>.json` を作る。
5. Eagle アプリが対象ライブラリを開いている間のファイル直接書込は禁止。その場合は Eagle ローカル HTTP API (http://localhost:41595) 経由で変更する。
6. item の新規追加はサムネイル/palette 生成を伴うため API 専用 (Eagle 起動時のみ)。

## mutation の経路選択 ("Method")
- `Automatic`: API が使えて対象ライブラリが開いていれば API、閉じていればファイル直接 (安全)。
- `"API"`: API 強制 (不可なら Error)。
- `"File"`: ファイル直接強制 (対象ライブラリが開いていれば Error)。

## NAS / オフライン / 大規模ライブラリ
- オンライン判定は metadata.json の存在確認 1 回のみで行い、結果を `$SourceVaultEagleOfflineRecheckSeconds` (既定 60 秒) キャッシュ。
- オフライン中: 読み取り系はメモリ/ディスクキャッシュ上の「最後に見えた状態」をエラー無しで返す。書込系・原本アクセス系は `<|"Status"->"Error","Reason"->"LibraryOffline"|>` を静かに返す (Message は出さない)。保存済みサマリーはオフラインでも返る。復帰は自動。オフライン中でも登録は可能 (`"Online"->False` 付きで Registered)。
- item キャッシュは PrivateVault/eagle/itemcache/ に BinarySerialize で永続化。2 回目以降のセッションは blob 1 読込 + mtime.json 差分のみ。mtime.json 再読込は `$SourceVaultEagleMtimeTTL` (既定 5 秒) で間引く。

## 設定変数

### $SourceVaultEagleLibrary
型: String (絶対パス)
現在の Eagle ライブラリ (`xxx.library` フォルダ) の絶対パス。SourceVaultEagleSetLibrary で切替。

### $SourceVaultEagleAPIBase
型: String, 初期値: "http://localhost:41595"
Eagle ローカル API のベース URL。

### $SourceVaultEagleAPIToken
型: String | None, 初期値: None
Eagle API トークン (環境設定→開発者向け)。None なら付与しない。

### $SourceVaultEagleStoreRoot
型: String, 初期値: PrivateVault/eagle
Eagle 連携データ (ingest 対応表・summary・ファイルバックアップ) の保存先。

### $SourceVaultEagleOfflineRecheckSeconds
型: Number, 初期値: 60
オンライン/オフライン判定の再チェック間隔秒。到達不能 NAS への繰り返しタイムアウトを避ける。

### $SourceVaultEagleMtimeTTL
型: Number, 初期値: 5
mtime.json 再読込の間引き秒。大規模ライブラリで連続検索を高速化。

### $SourceVaultEagleCacheSaveEvery
型: Integer, 初期値: 50
item キャッシュ自動永続化のしきい値 (変更 item 数)。

### $SourceVaultEagleAPIRecheckSeconds
型: Number, 初期値: 10
Eagle API 死活確認の再チェック間隔秒。SourceVaultEagleRefresh[] で即時再判定。

### $SourceVaultEagleCloudPublishableTag
型: String, 初期値: "Cloud-Publishable" (大文字小文字無視)
クラウド要約を許可するタグ名。このタグが付いた item は `"Method"->Automatic` の要約でローカル LLM ではなくクラウド経路を使い、summary record に PrivacyLevel 0.0 を記録する。クラウド経路は `$ClaudeModel` の provider 準拠 (claudecode→Claude Code CLI、codex→Codex CLI。課金 API は anthropic/openai 明示時のみ)。またこのタグ付き item のサマリーノート (notes/*.nb) では NBMarkCellConfidential で秘匿マークされたセル (confidential=True または privacyLevel>0.5) を検索インデックス/メタ情報 (Note フィールド) から除外する。タグ無し item のノートは全文がローカル検索対象。

### $SourceVaultEaglePrivacyLevel
型: Number | Association, 初期値: 1.0
Eagle View/Dataset/Search/GeoView 出力セルの既定 PrivacyLevel。数値 (全ライブラリ共通)、または `<|登録名orライブラリパス -> PL, "Default" -> PL|>`。1.0 = クラウド LLM へはスキーマのみ・ローカル LLM へは全文。0.5 以下ならクラウドにも全文可としてマークしない。

### $SourceVaultEagleNotebookStyle
型: String, 初期値: "SourceVault default.nb"
サマリー/フォルダ表示ノートブックの StyleDefinitions。

## ライブラリ登録・管理

### SourceVaultEagleRegisterLibrary[name, path, opts] → Association
Eagle ライブラリを名前付きで登録する。最初の登録が現在ライブラリになる。登録は PrivateVault/eagle/libraries.json に永続化され次回セッションから自動復元。パスは `{"$dropbox", "Eagle", "xxx.library"}` 形式のシンボリックパスで保存され、実パスが異なる PC でも同じ登録が使える。
Options: "Persist" -> True (False で今セッション限り), "Online" -> Automatic (False でオフライン登録)

### SourceVaultEagleLibraries[] → Association
登録済みライブラリ `<|name -> path|>` を返す (永続化分は自動ロード)。

### SourceVaultEagleSetLibrary[nameOrPath] → Association
現在ライブラリを切り替え、選択を永続化する。

### SourceVaultEagleUnregisterLibrary[name] → Association
ライブラリ登録を削除する (永続化にも反映)。

### SourceVaultEagleStatus[] → Association
現在ライブラリ・item/folder 数・API 状態・summary/ingest 件数の概要を返す。

### SourceVaultEagleRefresh[] → Association
item/メタ/オンライン判定/API/Exif/summary の各キャッシュを破棄して次回アクセス時に再読込・再判定させる (ディスク永続キャッシュは残る)。返り値 `<|"Status"->"Refreshed"|>`。

### SourceVaultEagleLibraryOnlineQ[opts] → Bool
現在ライブラリへ到達可能か (NAS オフライン検知)。判定は `$SourceVaultEagleOfflineRecheckSeconds` 秒キャッシュ。
Options: "Library" -> Automatic

### SourceVaultEagleSaveCache[] → Association
item キャッシュを PrivateVault/eagle/itemcache に明示的に永続化する (通常は自動)。

## 読み取り

### SourceVaultEagleLibraryInfo[opts] → Association
ライブラリ metadata.json の Association (folders/smartFolders/tagsGroups/...) を返す。
Options: "Library" -> Automatic

### SourceVaultEagleFolders[opts] → List
フォルダツリーを平坦化したリスト。各要素は Eagle のフォルダ Association + "Path" (祖先名リスト)。
Options: "Library" -> Automatic

### SourceVaultEagleFolderList[opts]
フォルダ一覧 (フォルダ/種別/件数/Id/更新日) をノートブックリスト風の表で返す。フォルダ名クリックで SourceVaultEagleFolderView を新規ノートブックに開く。スマートフォルダも既定で含む。
→ Grid | Dataset
Options: "Library" -> Automatic, "IncludeSmart" -> True (False で除外), "Links" -> True (False で素のデータ行 Dataset)

### SourceVaultEagleSmartFolders[opts] → List
スマートフォルダ (保存された検索条件) の平坦化リスト。各要素は Eagle 定義 + "Path" + "Supported" (全 rule を評価可能か)。スマートフォルダ名は FolderView / ItemsInFolder / 各関数の "Folder" 指定でも通常フォルダ同様に使える (同名は通常フォルダ優先)。
Options: "Library" -> Automatic

### SourceVaultEagleShowFolder[folder, opts] → NotebookObject
SourceVaultEagleFolderView を新規ノートブックで開く (front end)。opts は SourceVaultEagleFolderView と同じ。

### SourceVaultEagleFindFolder[nameOrId, opts] → Association | Missing
フォルダを名前または id で検索して返す (children 込み)。
Options: "Library" -> Automatic

### SourceVaultEagleItems[opts] → List
全 item の metadata Association リスト (mtime.json による増分キャッシュ)。
Options: "Library" -> Automatic

### SourceVaultEagleItem[id, opts] → Association
item 1 件の metadata を返す。
Options: "Library" -> Automatic

### SourceVaultEagleItemPath[item, opts] → String
原本ファイルの絶対パスを返す。item は id か metadata Association。
Options: "Library" -> Automatic

### SourceVaultEagleThumbnailPath[item, opts] → String | Missing
サムネイル PNG のパスを返す (無ければ Missing)。
Options: "Library" -> Automatic

### SourceVaultEagleThumbnail[item, opts] → Image | Missing
サムネイル Image を返す (無ければ原本から生成を試みる)。
Options: "Library" -> Automatic

### SourceVaultEagleItemsInFolder[folder, opts] → List
フォルダ内 item を返す。folder は通常フォルダの名前/id に加えスマートフォルダの名前/id も指定可 (条件を評価して該当 item を返す)。
Options: "Library" -> Automatic, "Recursive" -> False (True で子フォルダも含む)

### SourceVaultEagleSearch[query, opts] → List
name/annotation/tags/url + 保存済みサマリー本文の部分一致 + 各種フィルタで item を検索する。"Folder" にはスマートフォルダの名前/id も指定可。
→ item metadata Association のリスト
Options:
- "Library" -> Automatic
- "Tags" -> Automatic (タグ絞り込み)
- "TagMode" -> "Any" ("Any"|"All")
- "Folder" -> Automatic (通常/スマートフォルダ名 or id)
- "Recursive" -> True
- "Ext" -> Automatic (拡張子絞り込み)
- "DateFrom" -> Automatic
- "DateTo" -> Automatic
- "DateBy" -> "btime" ("btime"|"mtime")
- "IncludeDeleted" -> False
- "HasAnnotation" -> Automatic
- "IncludeSummary" -> True (サマリー本文と notes/ のサマリーノート補足も一致対象)
- "SortBy" -> Automatic
- "SortOrder" -> "Desc"
- "Newest" -> True
- "Limit" -> Automatic

### SourceVaultEagleTags[opts] → Association
タグ→使用数の Association と historyTags/starredTags を返す。
Options: "Library" -> Automatic

## 開く

### SourceVaultEagleOpenItem[item, opts]
原本ファイルを SystemOpen で開く。
Options: "Library" -> Automatic

### SourceVaultEagleShowInApp[item, opts]
`eagle://item/<id>` で Eagle アプリ内に表示する。
Options: "Library" -> Automatic

## Eagle ローカル HTTP API

### SourceVaultEagleAPIAvailable[] → Association
Eagle アプリの API 到達可否と開いているライブラリを返す。結果は `$SourceVaultEagleAPIRecheckSeconds` (既定 10 秒) キャッシュ。

### SourceVaultEagleAPICall[endpoint, params, opts] → Association
Eagle ローカル API を呼ぶ。params があれば POST(JSON)、無ければ GET。params は Association | None。
Options: "Timeout" -> 15

## 変更 (mutation・Eagle 形式準拠)
以下すべて `"Method" -> Automatic | "API" | "File"` と `"Library" -> Automatic` を持つ。

### SourceVaultEagleSetTags[item, tags, opts] → Association
item のタグを置き換える。tags は文字列リスト。
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleAddTags[item, tags, opts] → Association
item にタグを追加する。
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleRemoveTags[item, tags, opts] → Association
item からタグを除去する。
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleSetAnnotation[item, text, opts] → Association
item の annotation を設定する。
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleSetURL[item, url, opts] → Association
item の url を設定する。
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleMoveToFolder[item, folder, opts] → Association
item の所属フォルダを変更する (API 非対応のためファイル直接のみ。Eagle が対象ライブラリを開いている間は Error)。
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleTrashItem[item, opts] → Association
item をゴミ箱へ (isDeleted=true / API moveToTrash)。原本ファイルは消さない。
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleCreateFolder[name, opts] → Association
フォルダを作成する。ファイル直接時は backup/ を作ってから書く。
Options: "Method" -> Automatic, "Library" -> Automatic, "Parent" -> None (nameOrId で子フォルダ)

### SourceVaultEagleRenameFolder[folder, newName, opts] → Association
フォルダ名を変更する。
Options: "Method" -> Automatic, "Library" -> Automatic

### SourceVaultEagleAddItem[path, opts] → Association
ファイルを Eagle に追加する (API 専用。Eagle 起動時のみ)。
Options: "Library" -> Automatic, "Name" -> Automatic, "Tags" -> {}, "Annotation" -> None, "URL" -> None, "Folder" -> None

## SourceVault 連携

### SourceVaultEagleIngest[item, opts] → Association
item を SourceVault ソースとして登録する (冪等)。既定 `"Copy"->False`: Eagle ライブラリが正本なので原本はコピーせず、SHA-256 ハッシュ付き参照記録のみを PrivateVault/eagle に残す。`"Copy"->True` で SourceVaultIngest (TrustLevel LocalFile) により vault へ複製。
Options: "Library" -> Automatic, "Copy" -> False, "Topic" -> Automatic, "PrivacyLabel" -> Automatic

### SourceVaultEagleIngestInfo[item, opts] → Association | Missing
ingest 記録 (Mode->"Reference"|"Vault", ContentHash, SourceId 等) を返す。未 ingest なら Missing。
Options: "Library" -> Automatic

### SourceVaultEagleIngestFolder[folder, opts] → Association
フォルダ内 item を一括 ingest し統計を返す。既定は参照モード (コピーなし)。
Options: "Library" -> Automatic, "Copy" -> False, "Recursive" -> False, "Topic" -> Automatic, "PrivacyLabel" -> Automatic, "Limit" -> Automatic

### SourceVaultEagleExtractText[item, opts] → Association
item 本文テキストを抽出する。PDF は原本から直接ページ抽出 (コピーなし、PrivateVault/eagle/pages にキャッシュ、テキスト層が無いページは `$SourceVaultOCRHook` 設定時に OCR)。vault 複製済みなら SourceVaultExtractPages 経由。docx/pptx/txt/html/xlsx はローカル抽出。
Options: "Library" -> Automatic, "MaxPages" -> Automatic, "MaxChars" -> Automatic

### SourceVaultEagleSummarize[item, opts] → Association
item のサマリーを LLM で生成・保存する。PDF/Word/PowerPoint/テキストは本文抽出後に要約、画像はサムネイル優先 (原本フォールバック) で vision 要約。動画は 2 段 pipeline: Stage 1 で n 枚 (既定 5) のフレームを nested dyadic 位置で抽出し各フレームを個別 vision 記述 (各 200 文字)、Stage 2 でフレーム説明を時刻順に統合。各フレーム記述は record の "Frames"[*]."Text" に保存され検索対象になる。後から "Frames"→大きい n を指定すると既存記述を再利用して不足分だけ追加 vision (`"ForceRefresh"->True` で全再生成)。既定はローカル LLM (`$ClaudePrivateModel` 経由)、原本コピーなし。`$SourceVaultEagleCloudPublishableTag` が付いた item は Automatic でもクラウドへ切替し PrivacyLevel 0.0 を記録。文書系は同じ LLM 呼び出しで書誌情報 (Title/Authors/Published) も抽出 (PDF は埋め込みメタデータをフォールバック)。summary は PrivateVault/eagle/summaries/<id>.json に保存。
Options:
- "Library" -> Automatic
- "Method" -> Automatic (Automatic|"Local"|"Claude")
- "MaxLength" -> (要約の上限)
- "MaxChars", "MaxPages" -> (本文抽出量)
- "Frames" -> 5 (動画フレーム数)
- "FrameMaxLength" -> 200 (各フレーム記述の上限)
- "Language" -> Automatic
- "ForceRefresh" -> False
- "Ingest" -> (ingest 併用)
- "Copy" -> False (True で vault 複製)
- "WriteAnnotation" -> False (True で Eagle annotation にも反映)
- "Persist" -> True
例: SourceVaultEagleSummarize["<id>", "Method"->"Local", "MaxLength"->400]
例 (動画粒度上げ): SourceVaultEagleSummarize[vid, "Frames"->10]

### SourceVaultEagleSummary[item, opts] → Association | Missing
保存済みサマリー record を返す ("SummaryStatus"->"Current"|"Stale" 付き)。無ければ Missing。一覧は SourceVaultEagleSummaries、全文表示は SourceVaultEagleShowSummary。
Options: "Library" -> Automatic

### SourceVaultEagleSummaries[query, opts]
保存済みサマリー一覧をノートブックリスト風の表で返す。「▶ 開く」で原本を SystemOpen、ファイル名クリックでサマリー全文をウインドウ表示 (Current/Stale 状態付き)。query はサマリー本文/ノート補足/ファイル名の部分一致。
→ Grid
Options: "Library" -> Automatic, "Limit" -> Automatic

### SourceVaultEagleExtractBibMeta[item, opts] → Association
要約済み item の書誌情報 (Title/Authors/Published) を本文先頭から LLM で抽出し summary record に追記する (旧 record の backfill 用)。PDF は埋め込みメタデータをフォールバック。既に Title を持つ record はスキップ。Method 解決は Summarize と同じ fail-safe。record が無ければ Error (先に Summarize)。
Options: "Library" -> Automatic, "Method" -> Automatic, "MaxChars" -> 2500, "MaxPages" -> 2, "Timeout" -> 120, "ForceRefresh" -> False

### SourceVaultEagleExtractBibMetaBatch[query, opts] → Association
保存済みサマリー record のうち書誌情報が無いものへ一括で ExtractBibMeta を適用し統計を返す。query は Summaries と同じ部分一致 ("" で全件)。
Options: ExtractBibMeta と同じ + "Ext" -> Automatic (絞り込み), "Limit" -> Automatic
例: SourceVaultEagleExtractBibMetaBatch["", "Ext"->"pdf", "Limit"->20]

### SourceVaultEagleSummarizeBatch[items, opts] → Association
item リスト (または検索 query 文字列) を一括要約し統計を返す。生成済み (Current) はスキップ。検索オプションを併用でき "Limit" は要約件数の上限。Kind ごとに dispatch して PDF・画像・動画混在フォルダも全件処理 (1 件失敗で全体を止めない)。"Frames"/"FrameMaxLength" 等 Summarize の option も継承。"Method"->Automatic では item ごとに判定: Cloud-Publishable タグ付きはクラウド ($ClaudeModel)、それ以外はローカル ($ClaudePrivateModel)。
Options: SourceVaultEagleSearch の検索オプション ("Folder", "Ext", "Tags", "DateFrom" 等) + SourceVaultEagleSummarize の option + "Limit"
例: SourceVaultEagleSummarizeBatch["", "Folder"->"自然計算関連", "Ext"->"pdf", "Limit"->2]

## インデックス (Eagle 情報 + Exif) と AND/OR 検索

### SourceVaultEagleExif[item, opts] → Association
item の Exif record `<|HasExif, Exif, BasedOnMTime, ...|>` を返す。未抽出なら原本から抽出して PrivateVault/eagle/exifindex に永続化 (Eagle 側は不変)。
Options: "Library" -> Automatic, "Extract" -> True, "ForceRefresh" -> False

### SourceVaultEagleBuildExifIndex[query, opts] → Association
検索条件に合う画像 item の Exif を一括抽出して索引化する (冪等、抽出済みはスキップ)。NAS 上の大規模ライブラリでは時間がかかるので "Limit" で分割推奨。
Options: SourceVaultEagleSearch と同じ + "ForceRefresh"

### SourceVaultEagleIndexRecord[item, opts] → Association
検索用の統合 record を返す: `<|Id, Name, Ext, Kind, Star(★数), Width, Height, Megapixels, Size, SizeMB, Added, Created, Modified, Tags, Folders, Annotation, URL, Deleted, Summary(保存済みサマリー本文), HasSummary, SummaryStatus, FrameCount(動画のフレーム数。動画以外 Missing), Note(サマリーノート補足の本文), HasNote, HasExif, CameraModel, TakenAt, ISO, FNumber, ExposureTime, FocalLength, GPS, Exif|>`。日付は DateObject。Exif は BuildExifIndex 済み分のみ (未索引は Missing)。
Options: "Library" -> Automatic

### SourceVaultEagleIndexSearch[pred, opts] → List
統合 record (IndexRecord) に述語 pred を適用して検索する。pred 内で && / || を使えば AND / OR 検索。Limit は pred 適用後に効く。
Options: SourceVaultEagleSearch と同じ + "Query" (文字列部分一致)
例: SourceVaultEagleIndexSearch[#Star >= 2 && (#Width >= 3000 || MemberQ[#Tags, "Lumix"]) &]
例: SourceVaultEagleIndexSearch[TrueQ[#HasSummary] && StringContainsQ[#Summary, "自然計算"] &]

### SourceVaultEagleIndexDataset[pred, opts] → Dataset
IndexSearch の結果を Dataset で返す (Exif 生データ列は除く)。
Options: IndexSearch と同じ

### SourceVaultEagleFolderView[folder, opts]
フォルダ内のファイル情報一覧 (★/解像度/サイズ/追加・作成・変更日/タグ/サマリー) をノートブックリスト風の表で表示する。ファイル名クリックで原本を SystemOpen、サマリー列クリックで全文をウインドウ表示。folder はスマートフォルダ名/id も可。既定 `"Limit"->200` で並び順上位のみ表示し、切り詰め時は「全 N 件中 200 件」の注記を付ける。
→ Grid
Options: "Library" -> Automatic, "Recursive" -> False, "Where" -> None (述語で AND/OR 絞り込み), "SortBy" -> "Added" ("Added"|"Created"|"Modified"|"Name"|"Size"|"Star"), "SortOrder" -> "Desc", "Limit" -> 200 (All で全件), "IncludeDeleted" -> False, "ShowExif" -> False

## 表示 (Dataset / View / GeoView)

### SourceVaultEagleSummaryRow[item, opts] → Association
一覧用の低漏洩行を SourceVault 共通スキーマで返す: `<|Kind("eagle"),Id,URI(sv://object/eagle-<id>),Title,Authors,Published,Summary,URL,File,Date,PrivacyLevel|>` + eagle 固有の `<|Ext,Size,Tags,Folders,Annotation|>`。SourceVaultSourceRow と同じ共通キーを共有し SourceVaultSummaries の横断検索行と互換。汎用 join/参照キーは "URI"。(旧キー "Name" は "Title" に改名)
Options: "Library" -> Automatic

### SourceVaultEagleDataset[query, opts] → Dataset
検索結果を素の Dataset で返す (ボタン無し)。
Options: SourceVaultEagleSearch と同じ

### SourceVaultEagleView[query, opts] → Dataset
検索結果を、行ごとに 原本を開く(▶)/Eagleで表示(⌂)/サマリー表示(☰) ボタンとサムネイル付きの表で返す。列は ▶/⌂/☰・(サムネイル)・Date・Name・Ext・Size・Tags・Summary(先頭150字、全文は☰)・PL(実効 PrivacyLevel)・URI(正準 sv://object/eagle-<id>、sourcevault_get / SourceVaultMCPGet で解決可)。
Options: SourceVaultEagleSearch + "Thumbnails" -> True, "ThumbnailSize" -> Automatic

### SourceVaultEagleShowSummary[item, opts] → NotebookObject
サマリーをノートブックで開く (front end)。PrivateVault/eagle/notes/ に保存済みノートがあればそれを開く (補足メモ・図などの追記が残る)。無ければ `$SourceVaultEagleNotebookStyle` のスタイルで生成し、ノート内「保存」ボタンで notes/ に保存できる (以後 Ctrl+S で上書き、次回から保存版が開く)。
Options: "Library" -> Automatic, "Fresh" -> False (True で保存版を無視して最新サマリーから作り直す)

### SourceVaultEagleGeoView[query, opts] → Graphics
Exif GPS を持つ写真を地図上にサムネイル表示する (クリックで原本を開く)。
Options: SourceVaultEagleSearch + "GeoRange" -> Automatic, "MarkerScale" -> Automatic, "ThumbnailSize" -> Automatic

## View 出力セルの自動機密マーク (クラウド LLM 送信制御)

### SourceVaultEagleSetSummaryPrivacy[item, pl, opts] → Association
item の summary record に per-item の "PrivacyLevel" を保存する (ライブラリ既定 $SourceVaultEaglePrivacyLevel より優先)。record が無ければ Error (先に SourceVaultEagleSummarize)。
Options: "Library" -> Automatic

### SourceVaultEagleMarkViewCells[nb] → List
Eagle View/Dataset/Search/GeoView の生出力セルを、表示 item の最大 PrivacyLevel で `NBAccess`NBMarkCellConfidential` する。マーク済み (True/False) セルは触らない。nb 省略時は EvaluationNotebook[]。返り値: `{<|"Cell"->idx,"PrivacyLevel"->pl|>...}`。

### SourceVaultEagleEnableAutoConfidential[] → Association
`NBAccess`NBMakeContextPacket` にフックを装着し、ClaudeEval/ClaudeQuery の文脈構築直前に SourceVaultEagleMarkViewCells を自動適用する。冪等。SourceVault_maildb.wl の SourceVaultMailEnableAutoConfidential が有効なら共有 spec 登録経由で Eagle View も対象になるため本フックは maildb 無し環境向け (併用しても二重マークしない)。

### SourceVaultEagleDisableAutoConfidential[] → Association
SourceVaultEagleEnableAutoConfidential[] のフックのみ解除する (maildb 側フックには影響しない)。

## sv:// object → notebook cell

### SourceVaultObjectToCell[uri, opts] → Association
オブジェクトの内容/プロパティをノートブックのセルに出力し、そのセルの PrivacyLevel をオブジェクトの privacy level に継承する (level > 0.5 なら confidential マーク)。ノートブックが無い (headless) 場合は Status->NoNotebook で値だけ返す。
→ `<|Status, URI, PrivacyLevel, Confidential, Cells|>`
Options: "Notebook" -> Automatic (InputNotebook[]), "Show" -> "Both" ("Both"|"Data"|"Properties")

## 関連パッケージ
[SourceVault](https://github.com/transreal/SourceVault) / [SourceVault_core](https://github.com/transreal/SourceVault_core) / [SourceVault_mcp](https://github.com/transreal/SourceVault_mcp) / [SourceVault_maildb](https://github.com/transreal/SourceVault_maildb) / [NBAccess](https://github.com/transreal/NBAccess)