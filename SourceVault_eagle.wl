(* ::Package:: *)

(* ============================================================
   SourceVault_eagle.wl -- Eagle library adapter
     (read / search / open / Eagle-API mutation / SourceVault ingest / LLM summary)

   This file is encoded in UTF-8.
   Load order: SourceVault.wl -> (SourceVault_core.wl ...) -> SourceVault_eagle.wl
   Load via:   Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_eagle.wl"]]

   Eagle ライブラリ (https://eagle.cool) のデータフォルダ
     <lib>/metadata.json            フォルダツリー / smartFolders / tagsGroups
     <lib>/tags.json                historyTags / starredTags
     <lib>/mtime.json               itemId -> lastModified(ms), "all" -> item 数
     <lib>/backup/backup-*.json     metadata.json のバックアップ (Eagle 形式)
     <lib>/images/<ID>.info/        原本ファイル / <name>_thumbnail.png / metadata.json
   を SourceVault のソースとして読み書きする。

   == Eagle 形式準拠の原則 (絶対遵守) ==
   1. 原本ファイル・サムネイルには一切書き込まない (read-only)。
   2. 書込は Eagle が自分で書く JSON のみ。既知フィールドだけを変更し、
      未知フィールドは Import("RawJSON") -> 変更 -> Export("RawJSON") で完全保存する。
   3. item metadata 変更時は modificationTime / lastModified (epoch ms) を更新し、
      mtime.json の該当エントリを同期する。"all" は「ライブラリの総 item 数」なので
      書き換えない (mtime.json は最近変更された item の部分インデックスであり、
      全 item は載らない。実ライブラリで実測: エントリ 1k 件 / all 56k)。
   4. ライブラリ metadata.json 変更時は事前に backup/backup-<Eagle命名>.json を作る。
   5. Eagle アプリが対象ライブラリを開いている間のファイル直接書込は禁止
      (アプリ内メモリ状態と衝突する)。その場合は Eagle ローカル HTTP API
      (http://localhost:41595) 経由で変更する。API は Eagle 自身が書くので常に準拠。
   6. item の新規追加はサムネイル・palette 生成を伴うため API 専用
      (Eagle 起動時のみ可。ファイル直接生成はしない)。

   == mutation の経路選択 ==
     "Method" -> Automatic : API が使えて対象ライブラリが開いていれば API、
                             閉じていればファイル直接 (安全)。
                  "API"    : API 強制 (不可なら Error)。
                  "File"   : ファイル直接強制 (対象ライブラリが開いていれば Error)。

   == SourceVault 連携 ==
     - SourceVaultEagleIngest    : 既定 "Copy"->False (参照モード)。Eagle ライブラリが
                                   正本なので原本はコピーせず、SHA-256 ハッシュ付き
                                   参照記録のみを PrivateVault/eagle に残す。
                                   "Copy"->True 指定時のみ SourceVaultIngest で vault へ複製
                                   (SourceVault 側のページキャッシュ/claim 抽出を使う場合)。
     - SourceVaultEagleSummarize : PDF/Word/PowerPoint/テキスト系は本文抽出、
                                   画像/動画はフレームを vision LLM へ。
                                   既定はローカル LLM (fail-safe。クラウドは明示指定)。
     - PDF 本文は原本から直接ページ抽出 (コピーなし)。テキスト層が無いページは
       $SourceVaultOCRHook (設定時) を直接呼ぶ。抽出結果は PrivateVault/eagle/pages に
       キャッシュ。vault 複製済みなら SourceVaultExtractPages 経由。
     - summary は PrivateVault/eagle/summaries/<id>.json に保存 (Eagle 側は汚さない)。
       "WriteAnnotation" -> True で Eagle の annotation にも反映 (Eagle 準拠の書込)。

   == NAS / オフライン / 大規模ライブラリ ==
     - ライブラリが NAS 上にある場合、サブネット切替等で到達不能 (オフライン) になりうる。
       オンライン判定は metadata.json の存在確認 1 回のみで行い、結果を
       $SourceVaultEagleOfflineRecheckSeconds (既定 60 秒) キャッシュする
       (到達不能 UNC パスへの繰り返しタイムアウト待ちを避ける)。
     - オフライン中: 読み取り系はメモリ/ディスクキャッシュ上の「最後に見えた状態」を
       エラー無しで返す。書込系・原本アクセス系は <|"Status"->"Error",
       "Reason"->"LibraryOffline"|> を静かに返す (Message は出さない)。
       保存済みサマリーはオフラインでも返る。復帰は自動 (次回オンライン判定で再同期)。
     - オフライン中でも登録は可能 ("Online"->False 付きで Registered)。
     - item キャッシュは PrivateVault/eagle/itemcache/ に BinarySerialize で永続化。
       大規模ライブラリでも 2 回目以降のセッションは blob 1 読込 + mtime.json 差分のみ。
       mtime.json の再読込は $SourceVaultEagleMtimeTTL (既定 5 秒) で間引く。
   ============================================================ *)

BeginPackage["SourceVault`"];

(* ---- 設定 / ライブラリ登録 ---- *)
$SourceVaultEagleLibrary::usage = "$SourceVaultEagleLibrary は現在の Eagle ライブラリ (xxx.library フォルダ) の絶対パス。SourceVaultEagleSetLibrary で切替。";
$SourceVaultEagleAPIBase::usage = "$SourceVaultEagleAPIBase は Eagle ローカル API のベース URL (既定 http://localhost:41595)。";
$SourceVaultEagleAPIToken::usage = "$SourceVaultEagleAPIToken は Eagle API トークン (環境設定→開発者向け)。None なら付与しない。";
$SourceVaultEagleStoreRoot::usage = "$SourceVaultEagleStoreRoot は Eagle 連携データ (ingest 対応表・summary・ファイルバックアップ) の保存先。既定 PrivateVault/eagle。";
SourceVaultEagleRegisterLibrary::usage = "SourceVaultEagleRegisterLibrary[name, path] は Eagle ライブラリを名前付きで登録する。最初の登録は現在ライブラリになる。登録は PrivateVault/eagle/libraries.json に永続化され、次回セッションから自動復元される。パスは {\"$dropbox\", \"Eagle\", \"xxx.library\"} 形式のシンボリックパスで保存されるため、$dropbox / $onWork 等の実パスが異なる PC でも同じ登録が使える。\"Persist\"->False で今セッション限り。";
SourceVaultEagleLibraries::usage = "SourceVaultEagleLibraries[] は登録済みライブラリ <|name -> path|> を返す (永続化分は自動ロード)。";
SourceVaultEagleSetLibrary::usage = "SourceVaultEagleSetLibrary[nameOrPath] は現在ライブラリを切り替え、選択を永続化する。";
SourceVaultEagleUnregisterLibrary::usage = "SourceVaultEagleUnregisterLibrary[name] はライブラリ登録を削除する (永続化にも反映)。";
SourceVaultEagleStatus::usage = "SourceVaultEagleStatus[] は現在ライブラリ・item/folder 数・API 状態・summary/ingest 件数の概要を返す。";
SourceVaultEagleRefresh::usage = "SourceVaultEagleRefresh[] は item/メタ/オンライン判定キャッシュを破棄して次回アクセス時に再読込・再判定させる (ディスク永続キャッシュは残る)。";
SourceVaultEagleLibraryOnlineQ::usage = "SourceVaultEagleLibraryOnlineQ[] は現在ライブラリへ到達可能か (NAS オフライン検知)。判定は $SourceVaultEagleOfflineRecheckSeconds 秒キャッシュされる。";
SourceVaultEagleSaveCache::usage = "SourceVaultEagleSaveCache[] は item キャッシュを PrivateVault/eagle/itemcache に明示的に永続化する (通常は自動)。";
$SourceVaultEagleOfflineRecheckSeconds::usage = "オンライン/オフライン判定の再チェック間隔秒 (既定 60)。到達不能 NAS への繰り返しタイムアウトを避ける。";
$SourceVaultEagleMtimeTTL::usage = "mtime.json 再読込の間引き秒 (既定 5)。大規模ライブラリで連続検索を高速化する。";
$SourceVaultEagleCacheSaveEvery::usage = "item キャッシュ自動永続化のしきい値 (変更 item 数、既定 50)。";

(* ---- 読み取り ---- *)
SourceVaultEagleLibraryInfo::usage = "SourceVaultEagleLibraryInfo[] はライブラリ metadata.json の Association (folders/smartFolders/tagsGroups/...) を返す。";
SourceVaultEagleFolders::usage = "SourceVaultEagleFolders[] はフォルダツリーを平坦化したリストを返す。各要素は Eagle のフォルダ Association + \"Path\" (祖先名リスト)。";
SourceVaultEagleFolderList::usage = "SourceVaultEagleFolderList[] はフォルダ一覧 (フォルダ/種別/件数/Id/更新日) をノートブックリスト風の表で返す。フォルダ名クリックで SourceVaultEagleFolderView を新規ノートブックに開く。スマートフォルダも既定で含む (\"IncludeSmart\"->False で除外)。\"Links\"->False で素のデータ行 Dataset (プログラム処理用) を返す。";
SourceVaultEagleSmartFolders::usage = "SourceVaultEagleSmartFolders[] はスマートフォルダ (保存された検索条件) の平坦化リストを返す。各要素は Eagle の定義 + \"Path\" + \"Supported\" (全 rule を評価可能か)。スマートフォルダ名は SourceVaultEagleFolderView / SourceVaultEagleItemsInFolder / 各関数の \"Folder\" 指定でも通常フォルダ同様に使える (同名がある場合は通常フォルダ優先)。";
SourceVaultEagleShowFolder::usage = "SourceVaultEagleShowFolder[folder, opts] は SourceVaultEagleFolderView を新規ノートブックで開く (front end)。opts は SourceVaultEagleFolderView と同じ。";
SourceVaultEagleFindFolder::usage = "SourceVaultEagleFindFolder[nameOrId] はフォルダを名前または id で検索して返す (children 込み)。見つからなければ Missing。";
SourceVaultEagleItems::usage = "SourceVaultEagleItems[] は全 item の metadata Association リストを返す (mtime.json による増分キャッシュ)。";
SourceVaultEagleItem::usage = "SourceVaultEagleItem[id] は item 1 件の metadata を返す。";
SourceVaultEagleItemPath::usage = "SourceVaultEagleItemPath[item] は原本ファイルの絶対パスを返す。";
SourceVaultEagleThumbnailPath::usage = "SourceVaultEagleThumbnailPath[item] はサムネイル PNG のパスを返す (無ければ Missing)。";
SourceVaultEagleThumbnail::usage = "SourceVaultEagleThumbnail[item] はサムネイル Image を返す (無ければ原本から生成を試みる)。";
SourceVaultEagleItemsInFolder::usage = "SourceVaultEagleItemsInFolder[folder, opts] はフォルダ内 item を返す。folder は通常フォルダの名前/id に加え、スマートフォルダの名前/id も指定できる (条件を評価して該当 item を返す)。\"Recursive\"->True で子フォルダも含む。";
SourceVaultEagleSearch::usage = "SourceVaultEagleSearch[query, opts] は name/annotation/tags/url + 保存済みサマリー本文の部分一致 + \"Tags\"/\"Folder\"/\"Ext\"/\"DateFrom\"/\"DateTo\" などで item を検索する。opts: \"Tags\", \"TagMode\"(\"Any\"|\"All\"), \"Folder\", \"Recursive\", \"Ext\", \"DateFrom\", \"DateTo\", \"DateBy\"(\"btime\"|\"mtime\"), \"IncludeDeleted\", \"HasAnnotation\", \"IncludeSummary\"(既定 True: サマリー本文と notes/ のサマリーノート補足も一致対象), \"SortBy\", \"Newest\", \"Limit\"。\"Folder\" にはスマートフォルダの名前/id も指定できる。";
SourceVaultEagleTags::usage = "SourceVaultEagleTags[] はタグ -> 使用数の Association と historyTags/starredTags を返す。";

(* ---- 開く ---- *)
SourceVaultEagleOpenItem::usage = "SourceVaultEagleOpenItem[item] は原本ファイルを SystemOpen で開く。";
SourceVaultEagleShowInApp::usage = "SourceVaultEagleShowInApp[item] は eagle://item/<id> で Eagle アプリ内に表示する。";

(* ---- Eagle ローカル API ---- *)
SourceVaultEagleAPIAvailable::usage = "SourceVaultEagleAPIAvailable[] は Eagle アプリの API 到達可否と開いているライブラリを返す。結果は $SourceVaultEagleAPIRecheckSeconds (既定 10 秒) キャッシュされる (Eagle 未起動時の接続待ちを繰り返さない)。";
$SourceVaultEagleAPIRecheckSeconds::usage = "Eagle API 死活確認の再チェック間隔秒 (既定 10)。SourceVaultEagleRefresh[] で即時再判定。";
SourceVaultEagleAPICall::usage = "SourceVaultEagleAPICall[endpoint, params, opts] は Eagle ローカル API を呼ぶ。params があれば POST(JSON)、無ければ GET。";

(* ---- 変更 (Eagle 形式準拠) ---- *)
SourceVaultEagleSetTags::usage = "SourceVaultEagleSetTags[item, tags, opts] は item のタグを置き換える。\"Method\"->Automatic|\"API\"|\"File\"。";
SourceVaultEagleAddTags::usage = "SourceVaultEagleAddTags[item, tags, opts] は item にタグを追加する。";
SourceVaultEagleRemoveTags::usage = "SourceVaultEagleRemoveTags[item, tags, opts] は item からタグを除去する。";
SourceVaultEagleSetAnnotation::usage = "SourceVaultEagleSetAnnotation[item, text, opts] は item の annotation を設定する。";
SourceVaultEagleSetURL::usage = "SourceVaultEagleSetURL[item, url, opts] は item の url を設定する。";
SourceVaultEagleMoveToFolder::usage = "SourceVaultEagleMoveToFolder[item, folder, opts] は item の所属フォルダを変更する (API 非対応のためファイル直接のみ。Eagle が対象ライブラリを開いている間は Error)。";
SourceVaultEagleTrashItem::usage = "SourceVaultEagleTrashItem[item, opts] は item をゴミ箱へ (isDeleted=true / API moveToTrash)。原本ファイルは消さない。";
SourceVaultEagleCreateFolder::usage = "SourceVaultEagleCreateFolder[name, opts] はフォルダを作成する。\"Parent\"->nameOrId で子フォルダ。ファイル直接時は backup/ を作ってから書く。";
SourceVaultEagleRenameFolder::usage = "SourceVaultEagleRenameFolder[folder, newName, opts] はフォルダ名を変更する。";
SourceVaultEagleAddItem::usage = "SourceVaultEagleAddItem[path, opts] はファイルを Eagle に追加する (API 専用。Eagle 起動時のみ)。opts: \"Name\", \"Tags\", \"Annotation\", \"URL\", \"Folder\"。";

(* ---- SourceVault 連携 ---- *)
SourceVaultEagleIngest::usage = "SourceVaultEagleIngest[item, opts] は item を SourceVault ソースとして登録する (冪等)。既定 \"Copy\"->False: Eagle ライブラリが正本なので原本はコピーせず、SHA-256 ハッシュ付き参照記録のみを残す。\"Copy\"->True で SourceVaultIngest (TrustLevel LocalFile) により vault へ複製する。opts: \"Copy\", \"Topic\", \"PrivacyLabel\"。";
SourceVaultEagleIngestInfo::usage = "SourceVaultEagleIngestInfo[item] は ingest 記録 (Mode->\"Reference\"|\"Vault\", ContentHash, SourceId 等) を返す。未 ingest なら Missing。";
SourceVaultEagleIngestFolder::usage = "SourceVaultEagleIngestFolder[folder, opts] はフォルダ内 item を一括 ingest し統計を返す。既定は参照モード (コピーなし)。";
SourceVaultEagleExtractText::usage = "SourceVaultEagleExtractText[item, opts] は item 本文テキストを抽出する。PDF は原本から直接ページ抽出 (コピーなし、PrivateVault/eagle/pages にキャッシュ、テキスト層が無いページは $SourceVaultOCRHook 設定時に OCR)。vault 複製済み (\"Copy\"->True で ingest 済み) なら SourceVaultExtractPages 経由。docx/pptx/txt/html/xlsx はローカル抽出。opts: \"MaxPages\", \"MaxChars\"。";
SourceVaultEagleSummarize::usage = "SourceVaultEagleSummarize[item, opts] は item のサマリーを LLM で生成・保存する。PDF/Word/PowerPoint/テキストは本文抽出後に要約、画像/動画は vision。既定はローカル LLM ($ClaudePrivateModel 経由。\"Method\"->\"Claude\" でクラウド)、原本コピーなし (\"Copy\"->True で vault 複製)。$SourceVaultEagleCloudPublishableTag (既定 \"Cloud-Publishable\") のタグが付いた item は Automatic でもクラウドへ切り替わり、summary record に PrivacyLevel 0.0 を記録する。クラウド経路は $ClaudeModel の provider に従う: claudecode/未設定→Claude Code CLI、chatgptcodex/codex→Codex CLI (テキスト。画像/動画は Codex 未対応のため Claude Code CLI で実行)。課金 API は {\"anthropic\"|\"openai\", ...} 明示時のみ。文書系 (PDF/Word/PowerPoint/テキスト) は同じ LLM 呼び出しで書誌情報 (Title/Authors/Published) も抽出して record に保存する (PDF は埋め込みメタデータをフォールバック。旧 record の backfill は SourceVaultEagleExtractBibMeta)。opts: \"Method\"(Automatic|\"Local\"|\"Claude\"), \"MaxLength\", \"MaxChars\", \"MaxPages\", \"Frames\", \"Language\", \"ForceRefresh\", \"Ingest\", \"Copy\", \"WriteAnnotation\", \"Persist\"。";
SourceVaultEagleSummary::usage = "SourceVaultEagleSummary[item] は保存済みサマリー record を返す (\"SummaryStatus\"->\"Current\"|\"Stale\" 付き)。無ければ Missing。一覧は SourceVaultEagleSummaries[]、全文表示は SourceVaultEagleShowSummary[item]、表中では View の Memo 列にも出る。";
SourceVaultEagleSummaries::usage = "SourceVaultEagleSummaries[query, opts] は保存済みサマリーの一覧をノートブックリスト風の表で返す。「▶ 開く」クリックで原本ファイルを SystemOpen、ファイル名クリックでサマリー全文をウインドウ表示 (Current/Stale 状態付き)。query はサマリー本文/ノート補足/ファイル名の部分一致。opts: \"Limit\"。";
SourceVaultEagleExtractBibMeta::usage = "SourceVaultEagleExtractBibMeta[item, opts] は要約済み item の書誌情報 (Title/Authors/Published) を本文先頭から LLM で抽出し summary record に追記する (旧 record の backfill 用。新規要約は SourceVaultEagleSummarize が同時抽出)。PDF は埋め込みメタデータをフォールバックに使う。既に Title を持つ record はスキップ (\"ForceRefresh\"->True で再抽出)。Method 解決は Summarize と同じ fail-safe (Cloud-Publishable タグ無しはローカル LLM)。opts: \"Method\", \"MaxChars\"(2500), \"MaxPages\"(2), \"Timeout\", \"ForceRefresh\"。";
SourceVaultEagleExtractBibMetaBatch::usage = "SourceVaultEagleExtractBibMetaBatch[query, opts] は保存済みサマリー record のうち書誌情報が無いものへ一括で SourceVaultEagleExtractBibMeta を適用し統計を返す。query は SourceVaultEagleSummaries と同じ部分一致 (\"\" で全件)。opts: \"Ext\"->\"pdf\" 等の絞り込み, \"Limit\", ほか SourceVaultEagleExtractBibMeta と同じ。例: SourceVaultEagleExtractBibMetaBatch[\"\", \"Ext\"->\"pdf\", \"Limit\"->20]。";
SourceVaultEagleSummarizeBatch::usage = "SourceVaultEagleSummarizeBatch[items, opts] は item リスト (または検索 query 文字列) を一括要約し統計を返す。生成済み (Current) はスキップ。検索オプション (\"Folder\", \"Ext\", \"Tags\", \"DateFrom\" 等 SourceVaultEagleSearch と同じ) を併用でき、\"Limit\" は要約件数の上限。例: SourceVaultEagleSummarizeBatch[\"\", \"Folder\"->\"自然計算関連\", \"Ext\"->\"pdf\", \"Limit\"->2]。\"Method\"->Automatic では item ごとに判定: Cloud-Publishable タグ付きはクラウド ($ClaudeModel)、それ以外はローカル ($ClaudePrivateModel)。";
$SourceVaultEagleCloudPublishableTag::usage = "$SourceVaultEagleCloudPublishableTag はクラウド要約を許可するタグ名 (既定 \"Cloud-Publishable\"、大文字小文字無視)。このタグが付いた item は \"Method\"->Automatic の要約でローカル LLM ではなくクラウド経路を使い、summary record に PrivacyLevel 0.0 が記録される。クラウド経路は $ClaudeModel の provider 準拠 (claudecode→Claude Code CLI、codex→Codex CLI。課金 API は anthropic/openai 明示時のみ)。また、このタグ付き item のサマリーノート (notes/*.nb) では NBMarkCellConfidential で秘匿マークされたセル (confidential=True または privacyLevel>0.5) を検索インデックス/メタ情報 (Note フィールド) から除外する — サマリー等のメタ情報を Cloud-Publishable な PL に保つため。タグ無し item のノートは全文がローカル検索対象 (メタ情報はライブラリ既定 PL の fail-safe マーキングが前提)。";

(* ---- インデックス (Eagle 情報 + Exif) と AND/OR 検索 ---- *)
SourceVaultEagleExif::usage = "SourceVaultEagleExif[item, opts] は item の Exif record <|HasExif, Exif, BasedOnMTime, ...|> を返す。未抽出なら原本から抽出して PrivateVault/eagle/exifindex に永続化 (Eagle 側は不変)。opts: \"Extract\"->True, \"ForceRefresh\"->False。";
SourceVaultEagleBuildExifIndex::usage = "SourceVaultEagleBuildExifIndex[query, opts] は検索条件に合う画像 item の Exif を一括抽出して索引化する (冪等、抽出済みはスキップ)。opts は SourceVaultEagleSearch と同じ + \"ForceRefresh\"。NAS 上の大規模ライブラリでは時間がかかるので \"Limit\" で分割推奨。";
SourceVaultEagleIndexRecord::usage = "SourceVaultEagleIndexRecord[item] は検索用の統合 record を返す: <|Id, Name, Ext, Kind, Star(★数), Width, Height, Megapixels, Size, SizeMB, Added(追加日), Created(作成日), Modified(変更日), Tags, Folders, Annotation, URL, Deleted, Summary(保存済みサマリー本文), HasSummary, SummaryStatus, Note(サマリーノート補足の本文), HasNote, HasExif, CameraModel, TakenAt(撮影日), ISO, FNumber, ExposureTime, FocalLength, GPS, Exif|>。日付は DateObject。Exif は SourceVaultEagleBuildExifIndex 済み分のみ (未索引は Missing)。";
SourceVaultEagleIndexSearch::usage = "SourceVaultEagleIndexSearch[pred, opts] は統合 record (SourceVaultEagleIndexRecord) に述語 pred を適用して検索する。pred 内で && / || を使えば AND / OR 検索になる。例: SourceVaultEagleIndexSearch[#Star >= 2 && (#Width >= 3000 || MemberQ[#Tags, \"Lumix\"]) &]、SourceVaultEagleIndexSearch[TrueQ[#HasSummary] && StringContainsQ[#Summary, \"自然計算\"] &]。opts: SourceVaultEagleSearch と同じ + \"Query\" (文字列部分一致)。Limit は pred 適用後に効く。";
SourceVaultEagleIndexDataset::usage = "SourceVaultEagleIndexDataset[pred, opts] は SourceVaultEagleIndexSearch の結果を Dataset で返す (Exif 生データ列は除く)。";
SourceVaultEagleFolderView::usage = "SourceVaultEagleFolderView[folder, opts] はフォルダ内のファイル情報一覧 (★/解像度/サイズ/追加・作成・変更日/タグ/サマリー) をノートブックリスト風の表で表示する。ファイル名クリックで原本を SystemOpen、サマリー列 (生成済みの場合) クリックで全文をウインドウ表示。folder はスマートフォルダ名/id も可。既定 \"Limit\"->200 で並び順上位のみ表示し、切り詰め時は「全 N 件中 200 件」の注記を付ける (\"Limit\"->All で全件)。opts: \"Recursive\", \"Where\"->述語 (AND/OR 絞り込み), \"SortBy\"(\"Added\"|\"Created\"|\"Modified\"|\"Name\"|\"Size\"|\"Star\"), \"SortOrder\", \"Limit\", \"IncludeDeleted\", \"ShowExif\"。";

(* ---- 表示 ---- *)
SourceVaultEagleSummaryRow::usage = "SourceVaultEagleSummaryRow[item] は一覧用の低漏洩行を SourceVault 共通スキーマで返す: <|Kind(\"eagle\"),Id,Title,Authors,Published,Summary,URL,File,Date,PrivacyLevel|> + eagle 固有の <|Ext,Size,Tags,Folders,Annotation|>。SourceVaultSourceRow (SourceVault.wl) と同じ共通キーを共有し、SourceVaultSummaries の横断検索行と互換。(旧キー \"Name\" は \"Title\" に改名)";
SourceVaultEagleDataset::usage = "SourceVaultEagleDataset[query, opts] は検索結果を素の Dataset で返す (ボタン無し)。";
SourceVaultEagleView::usage = "SourceVaultEagleView[query, opts] は検索結果を、行ごとに 原本を開く(▶)/Eagleで表示(⌂)/サマリー表示(☰) ボタンとサムネイル付きの表 (Dataset) で返す。opts は SourceVaultEagleSearch + \"Thumbnails\", \"ThumbnailSize\"。";
SourceVaultEagleShowSummary::usage = "SourceVaultEagleShowSummary[item, opts] はサマリーをノートブックで開く (front end)。PrivateVault/eagle/notes/ に保存済みノートがあればそれを開く (補足メモ・図などの追記が残る)。無ければ $SourceVaultEagleNotebookStyle のスタイルで生成し、ノート内の「保存」ボタンで notes/ に保存できる (以後 Ctrl+S で上書き、次回からは保存版が開く)。\"Fresh\"->True で保存版を無視して最新サマリーから作り直す (保存ボタンで上書き)。";
$SourceVaultEagleNotebookStyle::usage = "$SourceVaultEagleNotebookStyle はサマリー/フォルダ表示ノートブックの StyleDefinitions。既定 \"SourceVault default.nb\"。";
SourceVaultEagleGeoView::usage = "SourceVaultEagleGeoView[query, opts] は Exif GPS を持つ写真を地図上にサムネイル表示する (クリックで原本を開く)。opts は SourceVaultEagleSearch + \"GeoRange\", \"MarkerScale\", \"ThumbnailSize\"。";

(* ---- View 出力セルの自動機密マーク (クラウド LLM 送信制御) ---- *)
$SourceVaultEaglePrivacyLevel::usage = "$SourceVaultEaglePrivacyLevel は Eagle View/Dataset/Search/GeoView 出力セルの既定 PrivacyLevel。数値 (全ライブラリ共通)、または <|登録名orライブラリパス -> PL, \"Default\" -> PL|>。既定 1.0 (クラウド LLM へはスキーマのみ・ローカル LLM へは全文)。0.5 以下ならクラウドにも全文可としてマークしない。";
SourceVaultEagleSetSummaryPrivacy::usage = "SourceVaultEagleSetSummaryPrivacy[item, pl] は item の summary record に per-item の \"PrivacyLevel\" を保存する (ライブラリ既定 $SourceVaultEaglePrivacyLevel より優先)。record が無ければ Error (先に SourceVaultEagleSummarize を実行)。";
SourceVaultEagleMarkViewCells::usage = "SourceVaultEagleMarkViewCells[nb] は Eagle View/Dataset/Search/GeoView の生出力セルを、表示 item の最大 PrivacyLevel で NBAccess`NBMarkCellConfidential する。マーク済み (True/False) セルは触らない。nb 省略時は EvaluationNotebook[]。返り値: {<|\"Cell\"->idx,\"PrivacyLevel\"->pl|>...}。";
SourceVaultEagleEnableAutoConfidential::usage = "SourceVaultEagleEnableAutoConfidential[] は NBAccess`NBMakeContextPacket にフックを装着し、ClaudeEval/ClaudeQuery の文脈構築直前に SourceVaultEagleMarkViewCells を自動適用する。冪等。SourceVault_maildb.wl の SourceVaultMailEnableAutoConfidential が有効なら共有 spec 登録経由で Eagle View も対象になるため本フックは maildb 無し環境向け (併用しても二重マークしない)。";
SourceVaultEagleDisableAutoConfidential::usage = "SourceVaultEagleDisableAutoConfidential[] は SourceVaultEagleEnableAutoConfidential[] のフックのみ解除する (maildb 側フックには影響しない)。";

Begin["`Private`"];

(* ============================================================
   設定・パス
   ============================================================ *)

If[! AssociationQ[$iSVEGLibraries], $iSVEGLibraries = <||>];
If[! ValueQ[$SourceVaultEagleAPIBase], $SourceVaultEagleAPIBase = "http://localhost:41595"];
If[! ValueQ[$SourceVaultEagleAPIToken], $SourceVaultEagleAPIToken = None];

iSVEGNormPath[p_String] := ToLowerCase@StringReplace[ExpandFileName[p], "\\" -> "/"];
iSVEGNormPath[_] := "";

iSVEGLibraryQ[p_] :=
  StringQ[p] && DirectoryQ[p] &&
  FileExistsQ[FileNameJoin[{p, "metadata.json"}]] &&
  DirectoryQ[FileNameJoin[{p, "images"}]];

(* ---- ライブラリ登録の永続化 + シンボリックパス ----
   登録は PrivateVault/eagle/libraries.json に保存し、次回セッションで自動復元する。
   パスは保存時に {"$dropbox", "Eagle", "xxx.library"} 形式へ正規化する
   (SourceVault.wl の iSVSymbolicPath / iSVResolvePath と同じ規則。ロード済みなら
   本家を使い $SourceVaultCloudRootAliases の旧 PC エイリアスにも対応)。
   各シンボルは Global` 変数 ($dropbox / $onWork 等) として PC ごとに解決されるので、
   実パスが異なる環境でも同じ登録が使える。 *)

If[! ValueQ[$iSVEGLibRegistryLoaded], $iSVEGLibRegistryLoaded = False];

iSVEGLibRegistryPath[] := FileNameJoin[{iSVEGStoreRoot[], "libraries.json"}];

$iSVEGDefaultRootSymbols = {"$packageDirectory", "$dropbox", "$onWork",
  "$offWork", "$mathematicaWork"};

iSVEGRootValue[symName_String] :=
  Module[{v = Quiet@ToExpression["Global`" <> symName]},
    If[StringQ[v], ExpandFileName[v], Missing[]]];

(* 絶対パス -> シンボリックパス。どのルートにも一致しなければ {"<ABS>", abs}。 *)
iSVEGSymbolizePath[abs_String] :=
  Module[{r, norm, cands, hits, best, rootSlash},
    If[Length[DownValues[SourceVault`Private`iSVSymbolicPath]] > 0,
      r = Quiet@Check[SourceVault`Private`iSVSymbolicPath[abs], $Failed];
      If[ListQ[r] && r =!= {}, Return[r]]];
    norm = StringReplace[ExpandFileName[abs], "\\" -> "/"];
    cands = Select[({#, iSVEGRootValue[#]} & /@ $iSVEGDefaultRootSymbols),
      StringQ[#[[2]]] &];
    hits = Select[cands,
      Function[c,
        With[{rk = ToLowerCase@StringTrim[StringReplace[c[[2]], "\\" -> "/"], "/"]},
          rk =!= "" &&
          (ToLowerCase[norm] === rk ||
           StringStartsQ[ToLowerCase[norm], rk <> "/"])]]];
    If[hits === {}, Return[{"<ABS>", ExpandFileName[abs]}]];
    best = First@SortBy[hits, -StringLength[#[[2]]] &];
    rootSlash = StringTrim[StringReplace[best[[2]], "\\" -> "/"], "/"];
    Prepend[
      StringSplit[StringTrim[StringDrop[norm, StringLength[rootSlash]], "/"], "/"],
      best[[1]]]];

(* シンボリックパス / 絶対パス文字列 -> 現 PC の絶対パス。解決不能は $Failed。 *)
iSVEGResolvePathSpec[spec_String] := ExpandFileName[spec];
iSVEGResolvePathSpec[spec_List] :=
  Module[{r},
    If[Length[DownValues[SourceVault`Private`iSVResolvePath]] > 0,
      r = Quiet@Check[SourceVault`Private`iSVResolvePath[spec], Missing[]];
      If[StringQ[r], Return[r]]];
    Which[
      spec === {}, $Failed,
      First[spec] === "<ABS>", If[Length[spec] >= 2, spec[[2]], $Failed],
      True,
        With[{root = iSVEGRootValue[ToString@First[spec]]},
          If[StringQ[root],
            FileNameJoin[Prepend[ToString /@ Rest[spec], root]], $Failed]]]];
iSVEGResolvePathSpec[_] := $Failed;

iSVEGLibRegistrySave[] :=
  Module[{path = iSVEGLibRegistryPath[], entries, current},
    entries = KeyValueMap[
      Function[{name, p}, <|"Name" -> name, "Path" -> iSVEGSymbolizePath[p]|>],
      $iSVEGLibraries];
    current = If[StringQ[$SourceVaultEagleLibrary],
      With[{hit = SelectFirst[Keys[$iSVEGLibraries],
          iSVEGNormPath[$iSVEGLibraries[#]] ===
            iSVEGNormPath[$SourceVaultEagleLibrary] &, Missing[]]},
        If[StringQ[hit], hit, Null]], Null];
    iSVEGEnsureDir[DirectoryName[path]];
    If[iSVEGAtomicExportJSON[path,
        <|"Libraries" -> entries, "Current" -> current|>] === $Failed,
      <|"Status" -> "Error", "Reason" -> "WriteFailed", "Path" -> path|>,
      <|"Status" -> "Saved", "Count" -> Length[entries]|>]];

iSVEGLibRegistryEnsure[] :=
  Module[{j, cur},
    If[TrueQ[$iSVEGLibRegistryLoaded], Return[Null]];
    $iSVEGLibRegistryLoaded = True;
    j = iSVEGImportJSON[iSVEGLibRegistryPath[]];
    If[! AssociationQ[j], Return[Null]];
    Scan[
      Function[e,
        Module[{name = ToString@Lookup[e, "Name", ""], p},
          p = iSVEGResolvePathSpec[Lookup[e, "Path", $Failed]];
          (* 今セッションで明示登録済みの名前は上書きしない *)
          If[name =!= "" && StringQ[p] && ! KeyExistsQ[$iSVEGLibraries, name],
            AssociateTo[$iSVEGLibraries, name -> p]]]],
      Select[Lookup[j, "Libraries", {}], AssociationQ]];
    cur = Lookup[j, "Current", Null];
    If[StringQ[cur] && ! StringQ[$SourceVaultEagleLibrary] &&
       KeyExistsQ[$iSVEGLibraries, cur],
      $SourceVaultEagleLibrary = $iSVEGLibraries[cur]];
    Null];

(* オフライン中でも登録できる (NAS が後で復帰するケース)。
   到達できるのに Eagle 形式でない場合のみエラーにする。 *)
Options[SourceVaultEagleRegisterLibrary] = {"Persist" -> True};
SourceVaultEagleRegisterLibrary[name_String, path_String, OptionsPattern[]] :=
  Module[{p = ExpandFileName[path], online, res, old},
    iSVEGLibRegistryEnsure[];
    old = Lookup[$iSVEGLibraries, name, Missing[]];
    online = iSVEGOnlineProbe[p];
    If[online && ! iSVEGLibraryQ[p],
      Return[<|"Status" -> "Error", "Reason" -> "NotAnEagleLibrary", "Path" -> p,
        "Hint" -> "metadata.json と images/ を持つ xxx.library フォルダを指定してください。"|>]];
    (* 同名の再登録でパスが変わる場合: 旧パス由来の name キー付きキャッシュ blob を破棄し、
       現在ライブラリが旧パスを指していれば新パスへ切り替える (取り違え防止) *)
    If[StringQ[old] && iSVEGNormPath[old] =!= iSVEGNormPath[p],
      Quiet@DeleteFile[iSVEGCachePath[old]];
      Quiet@DeleteFile[iSVEGExifPath[old]];
      iSVEGDropLibCaches[old];
      iSVEGDropLibCaches[p];
      If[StringQ[$SourceVaultEagleLibrary] &&
         iSVEGNormPath[$SourceVaultEagleLibrary] === iSVEGNormPath[old],
        $SourceVaultEagleLibrary = p]];
    AssociateTo[$iSVEGLibraries, name -> p];
    AssociateTo[$iSVEGOnlineCache, p -> {AbsoluteTime[], online}];
    If[! StringQ[$SourceVaultEagleLibrary], $SourceVaultEagleLibrary = p];
    If[TrueQ[OptionValue["Persist"]], iSVEGLibRegistrySave[]];
    res = <|"Status" -> "Registered", "Name" -> name, "Path" -> p,
      "Online" -> online, "Persisted" -> TrueQ[OptionValue["Persist"]],
      "Current" -> (iSVEGNormPath[$SourceVaultEagleLibrary] === iSVEGNormPath[p])|>;
    If[online, res,
      Append[res, "Hint" ->
        "現在オフラインです。到達可能になれば自動的にオンライン動作へ復帰します。"]]];

SourceVaultEagleLibraries[] := (iSVEGLibRegistryEnsure[]; $iSVEGLibraries);

Options[SourceVaultEagleSetLibrary] = {"Persist" -> True};
SourceVaultEagleSetLibrary[spec_String, OptionsPattern[]] :=
  Module[{p, online},
    iSVEGLibRegistryEnsure[];
    p = ExpandFileName[Lookup[$iSVEGLibraries, spec, spec]];
    online = iSVEGOnlineProbe[p];
    If[online && ! iSVEGLibraryQ[p],
      Return[<|"Status" -> "Error", "Reason" -> "NotAnEagleLibrary", "Path" -> p|>]];
    $SourceVaultEagleLibrary = p;
    AssociateTo[$iSVEGOnlineCache, p -> {AbsoluteTime[], online}];
    If[TrueQ[OptionValue["Persist"]], iSVEGLibRegistrySave[]];
    <|"Status" -> "Set", "Path" -> p, "Online" -> online|>];

SourceVaultEagleUnregisterLibrary[name_String] :=
  (iSVEGLibRegistryEnsure[];
   If[! KeyExistsQ[$iSVEGLibraries, name],
     <|"Status" -> "Error", "Reason" -> "NotRegistered", "Name" -> name|>,
     ($iSVEGLibraries = KeyDrop[$iSVEGLibraries, name];
      iSVEGLibRegistrySave[];
      <|"Status" -> "Unregistered", "Name" -> name|>)]);

(* 現在ライブラリの解決。spec: Automatic / 登録名 / パス。失敗は $Failed。
   FS には触れない (オフライン中の呼び出しごとの NAS タイムアウトを避ける)。
   実在検証は登録時 + 使用時のオンライン判定で行う。 *)
iSVEGLib[] := iSVEGLib[Automatic];
iSVEGLib[Automatic] :=
  (iSVEGLibRegistryEnsure[];
   If[StringQ[$SourceVaultEagleLibrary], $SourceVaultEagleLibrary, $Failed]);
iSVEGLib[spec_String] :=
  (iSVEGLibRegistryEnsure[];
   ExpandFileName[Lookup[$iSVEGLibraries, spec, spec]]);
iSVEGLib[_] := $Failed;

(* ライブラリの保存キー: 登録名があれば "name:<登録名>" (PC 間で安定)、
   無ければ正規化パス。ingest 対応表・キャッシュ blob 名に使う。 *)
iSVEGNameKeyForNorm[norm_String] :=
  Module[{hit},
    iSVEGLibRegistryEnsure[];
    hit = SelectFirst[Keys[$iSVEGLibraries],
      iSVEGNormPath[$iSVEGLibraries[#]] === norm &, Missing[]];
    If[StringQ[hit], "name:" <> hit, norm]];
iSVEGLibStoreKey[lib_String] := iSVEGNameKeyForNorm[iSVEGNormPath[lib]];

iSVEGNoLib[] := <|"Status" -> "Error", "Reason" -> "NoLibrary",
  "Hint" -> "SourceVaultEagleRegisterLibrary[name, path] でライブラリを登録してください。"|>;

iSVEGStoreRoot[] :=
  If[StringQ[$SourceVaultEagleStoreRoot], $SourceVaultEagleStoreRoot,
    With[{r = Quiet@Check[SourceVault`$SourceVaultRoots["PrivateVault"], $Failed]},
      FileNameJoin[{If[StringQ[r], r, $TemporaryDirectory], "eagle"}]]];

iSVEGEnsureDir[dir_String] :=
  If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];

(* epoch ms (Eagle の modificationTime / lastModified / btime / mtime と同じ単位) *)
iSVEGNowMs[] := Round[1000*(AbsoluteTime[TimeZone -> 0] - 2208988800)];

(* ============================================================
   オンライン/オフライン判定 (NAS 対応)
   metadata.json の存在確認 1 回だけで判定し、結果を TTL キャッシュする。
   到達不能 UNC パスへの FS アクセスは Windows でタイムアウト待ちになるため、
   オフライン中に繰り返し probe しないことが重要。
   ============================================================ *)

If[! AssociationQ[$iSVEGOnlineCache], $iSVEGOnlineCache = <||>]; (* lib -> {t, bool} *)
If[! ValueQ[$SourceVaultEagleOfflineRecheckSeconds],
  $SourceVaultEagleOfflineRecheckSeconds = 60];
If[! ValueQ[$SourceVaultEagleMtimeTTL], $SourceVaultEagleMtimeTTL = 5];
If[! ValueQ[$SourceVaultEagleCacheSaveEvery], $SourceVaultEagleCacheSaveEvery = 50];

iSVEGOnlineProbe[lib_String] :=
  TrueQ[Quiet@Check[FileExistsQ[FileNameJoin[{lib, "metadata.json"}]], False]];

iSVEGOnlineQ[lib_String] :=
  Module[{now = AbsoluteTime[], e = Lookup[$iSVEGOnlineCache, lib, Missing[]], ttl, b},
    ttl = If[NumericQ[$SourceVaultEagleOfflineRecheckSeconds],
      $SourceVaultEagleOfflineRecheckSeconds, 60];
    If[ListQ[e] && now - e[[1]] < ttl, Return[TrueQ[e[[2]]]]];
    b = iSVEGOnlineProbe[lib];
    AssociateTo[$iSVEGOnlineCache, lib -> {now, b}];
    b];
iSVEGOnlineQ[_] := False;

(* オンラインと思って I/O したら失敗した場合に即オフラインへ落とす *)
iSVEGMarkOffline[lib_String] :=
  AssociateTo[$iSVEGOnlineCache, lib -> {AbsoluteTime[], False}];

Options[SourceVaultEagleLibraryOnlineQ] = {"Library" -> Automatic};
SourceVaultEagleLibraryOnlineQ[OptionsPattern[]] :=
  With[{lib = iSVEGLib[OptionValue["Library"]]},
    StringQ[lib] && iSVEGOnlineQ[lib]];

iSVEGOffline[] := <|"Status" -> "Error", "Reason" -> "LibraryOffline",
  "Hint" -> "ライブラリへ到達できません (NAS オフライン?)。復帰すれば自動的に再同期します。"|>;

(* ============================================================
   JSON I/O (Eagle 準拠: 未知フィールド保存・atomic 書込)
   ============================================================ *)

(* RawJSON 読み込み。Developer`ReadRawJSONFile (C 実装) があれば優先する —
   Import の ~25 倍速で、5 万 item 級ライブラリのフルスキャンを数秒にする。 *)
iSVEGImportJSON[path_String] :=
  Module[{r},
    If[! FileExistsQ[path], Return[$Failed]];
    r = Quiet@Check[Developer`ReadRawJSONFile[path], $Failed];
    If[AssociationQ[r] || ListQ[r], r,
      Quiet@Check[Import[path, "RawJSON"], $Failed]]];

(* tmp へ Export してから差し替える。RawJSON Compact は Eagle と同じ minified JSON。
   非 ASCII は \uXXXX エスケープになるが JSON 仕様準拠で Eagle はそのまま読める。 *)
iSVEGAtomicExportJSON[path_String, expr_] :=
  Module[{tmp = path <> ".svtmp", r},
    r = Quiet@Check[Export[tmp, expr, "RawJSON", "Compact" -> True], $Failed];
    If[r === $Failed, Quiet@DeleteFile[tmp]; Return[$Failed]];
    Quiet@Check[
      RenameFile[tmp, path, OverwriteTarget -> True],
      (* 旧 WL 向けフォールバック *)
      Quiet@Check[DeleteFile[path]; RenameFile[tmp, path], $Failed]];
    If[FileExistsQ[path] && ! FileExistsQ[tmp], path, $Failed]];

(* PrivateVault 側への退避コピー (Eagle ライブラリ内は汚さない) *)
iSVEGShadowBackup[path_String] :=
  Module[{dir = FileNameJoin[{iSVEGStoreRoot[], "filebackups"}], dest},
    If[! FileExistsQ[path], Return[None]];
    iSVEGEnsureDir[dir];
    dest = FileNameJoin[{dir,
      FileBaseName[DirectoryName[path]] <> "." <> ToString[iSVEGNowMs[]] <> "." <> FileNameTake[path]}];
    Quiet@Check[CopyFile[path, dest], None]];

(* ライブラリ metadata.json の Eagle 形式バックアップ (Eagle 自身と同じ命名で backup/ へ) *)
iSVEGEagleBackupLibraryMetadata[lib_String] :=
  Module[{src = FileNameJoin[{lib, "metadata.json"}], dir = FileNameJoin[{lib, "backup"}], name},
    If[! FileExistsQ[src], Return[None]];
    iSVEGEnsureDir[dir];
    name = "backup-" <> DateString[Now,
       {"Year", "-", "Month", "-", "Day", " ", "Hour", ".", "Minute", ".", "Second", ".", "Millisecond"}] <> ".json";
    Quiet@Check[CopyFile[src, FileNameJoin[{dir, name}]], None]];

(* ============================================================
   item 読み取り (mtime.json による増分キャッシュ)
   ============================================================ *)

If[! AssociationQ[$iSVEGItemCache], $iSVEGItemCache = <||>];      (* lib -> <|id -> meta|> *)
If[! AssociationQ[$iSVEGItemCacheSeen], $iSVEGItemCacheSeen = <||>]; (* lib -> <|id -> ms|> *)
If[! AssociationQ[$iSVEGMtimeCache], $iSVEGMtimeCache = <||>];    (* lib -> {t, stamp} *)
If[! AssociationQ[$iSVEGItemsStamp], $iSVEGItemsStamp = <||>];    (* lib -> 前回照合時の stamp *)
If[! AssociationQ[$iSVEGCacheLoadedFromDisk], $iSVEGCacheLoadedFromDisk = <||>];
If[! AssociationQ[$iSVEGCacheDirty], $iSVEGCacheDirty = <||>];    (* lib -> 未永続化の変更数 *)

SourceVaultEagleRefresh[] := (
  $iSVEGItemCache = <||>; $iSVEGItemCacheSeen = <||>; $iSVEGLibMetaCache = <||>;
  $iSVEGFolderFlatCache = <||>;
  $iSVEGMtimeCache = <||>; $iSVEGItemsStamp = <||>;
  $iSVEGOnlineCache = <||>; $iSVEGCacheLoadedFromDisk = <||>;
  $iSVEGExifIndex = <||>; $iSVEGExifLoaded = <||>; $iSVEGAPIAvailCache = None;
  $iSVEGSummaryCache = None; $iSVEGNoteCache = <||>;
  <|"Status" -> "Refreshed"|>);

(* 名前の付け替え時などにライブラリ単位でメモリキャッシュを落とす *)
iSVEGDropLibCaches[lib_String] := (
  $iSVEGItemCache = KeyDrop[$iSVEGItemCache, lib];
  $iSVEGItemCacheSeen = KeyDrop[$iSVEGItemCacheSeen, lib];
  $iSVEGMtimeCache = KeyDrop[$iSVEGMtimeCache, lib];
  $iSVEGItemsStamp = KeyDrop[$iSVEGItemsStamp, lib];
  $iSVEGLibMetaCache = KeyDrop[$iSVEGLibMetaCache, lib];
  $iSVEGFolderFlatCache = KeyDrop[$iSVEGFolderFlatCache, lib];
  $iSVEGExifIndex = KeyDrop[$iSVEGExifIndex, lib];
  $iSVEGExifLoaded = KeyDrop[$iSVEGExifLoaded, lib];
  $iSVEGCacheLoadedFromDisk = KeyDrop[$iSVEGCacheLoadedFromDisk, lib];);

iSVEGMtimePath[lib_String] := FileNameJoin[{lib, "mtime.json"}];

iSVEGMtimes[lib_String] :=
  With[{mt = iSVEGImportJSON[iSVEGMtimePath[lib]]},
    If[AssociationQ[mt], mt, $Failed]];

(* mtime.json のファイル stamp。Eagle は item を変更するたびに mtime.json を書き換えるので、
   stamp 不変 = ライブラリ不変とみなしてよい (再照合の要否判定に使う)。 *)
iSVEGMtimeStamp[lib_String] :=
  {Quiet@Check[FileDate[iSVEGMtimePath[lib], "Modification"], $Failed],
   Quiet@Check[FileByteCount[iSVEGMtimePath[lib]], $Failed]};

iSVEGInfoDir[lib_String, id_String] := FileNameJoin[{lib, "images", id <> ".info"}];

iSVEGLoadItemMeta[lib_String, id_String] :=
  With[{m = iSVEGImportJSON[FileNameJoin[{iSVEGInfoDir[lib, id], "metadata.json"}]]},
    If[AssociationQ[m], m, $Failed]];

(* mtime.json が無い/壊れている場合の全走査フォールバック *)
iSVEGScanIds[lib_String] :=
  (FileBaseName /@ Select[FileNames["*.info", FileNameJoin[{lib, "images"}]], DirectoryQ]);

(* ---- item キャッシュのディスク永続化 (PrivateVault 側、ローカルなので常に到達可能)。
   大規模ライブラリのコールドスタートを blob 1 読込 + mtime.json 差分に短縮し、
   オフライン時には「最後に見えた状態」の供給源になる。 ---- *)

iSVEGCachePath[lib_String] :=
  FileNameJoin[{iSVEGStoreRoot[], "itemcache",
    StringTake[IntegerString[Hash[iSVEGLibStoreKey[lib], "SHA256"], 16, 64], 16] <>
    ".svegcache"}];

iSVEGDiskCacheLoad[lib_String] :=
  Module[{path, blob},
    If[TrueQ[Lookup[$iSVEGCacheLoadedFromDisk, lib, False]], Return[Null]];
    AssociateTo[$iSVEGCacheLoadedFromDisk, lib -> True];
    If[Length[Lookup[$iSVEGItemCache, lib, <||>]] > 0, Return[Null]];
    path = iSVEGCachePath[lib];
    If[! TrueQ[Quiet@Check[FileExistsQ[path], False]], Return[Null]];
    blob = Quiet@Check[BinaryDeserialize[ReadByteArray[path]], $Failed];
    If[AssociationQ[blob] &&
       AssociationQ[Lookup[blob, "Items", $Failed]] &&
       AssociationQ[Lookup[blob, "Seen", $Failed]],
      AssociateTo[$iSVEGItemCache, lib -> blob["Items"]];
      AssociateTo[$iSVEGItemCacheSeen, lib -> blob["Seen"]];
      With[{md = Lookup[blob, "LibraryMeta", $Failed]},
        If[AssociationQ[md] && ! KeyExistsQ[$iSVEGLibMetaCache, lib],
          AssociateTo[$iSVEGLibMetaCache, lib -> {Missing["FromDiskCache"], md}]]]];
    Null];

iSVEGDiskCacheSave[lib_String] :=
  Module[{path = iSVEGCachePath[lib], cache, seen, md, blob, strm},
    cache = Lookup[$iSVEGItemCache, lib, <||>];
    seen = Lookup[$iSVEGItemCacheSeen, lib, <||>];
    If[Length[cache] === 0, Return[<|"Status" -> "Skipped", "Reason" -> "EmptyCache"|>]];
    md = With[{e = Lookup[$iSVEGLibMetaCache, lib, Missing[]]},
      If[ListQ[e], e[[2]], Quiet@Check[
        SourceVaultEagleLibraryInfo["Library" -> lib], $Failed]]];
    blob = <|"Library" -> iSVEGNormPath[lib], "Items" -> cache, "Seen" -> seen,
      "SavedAt" -> DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z"|>;
    If[AssociationQ[md] && ListQ[Lookup[md, "folders", $Failed]],
      blob["LibraryMeta"] = md];
    iSVEGEnsureDir[DirectoryName[path]];
    Quiet@Check[
      (strm = OpenWrite[path, BinaryFormat -> True];
       BinaryWrite[strm, BinarySerialize[blob]];
       Close[strm];
       $iSVEGCacheDirty[lib] = 0;
       <|"Status" -> "Saved", "Count" -> Length[cache], "Path" -> path|>),
      <|"Status" -> "Error", "Reason" -> "WriteFailed", "Path" -> path|>]];

Options[SourceVaultEagleSaveCache] = {"Library" -> Automatic};
SourceVaultEagleSaveCache[OptionsPattern[]] :=
  With[{lib = iSVEGLib[OptionValue["Library"]]},
    If[! StringQ[lib], iSVEGNoLib[], iSVEGDiskCacheSave[lib]]];

Options[SourceVaultEagleItems] = {"Library" -> Automatic, "Force" -> False};
SourceVaultEagleItems[OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], force, now, ttl, st, mt, ids,
      seen, cache, changed, nChanged = 0, dropped},
    If[! StringQ[lib], Return[{}]];
    iSVEGDiskCacheLoad[lib];
    cache = Lookup[$iSVEGItemCache, lib, <||>];
    force = TrueQ[OptionValue["Force"]];
    (* オフライン: キャッシュ上の「最後に見えた状態」をエラー無しで返す *)
    If[! iSVEGOnlineQ[lib], Return[Values[cache]]];
    (* stamp チェック自体も TTL で間引く (連続検索の高速化) *)
    now = AbsoluteTime[];
    ttl = If[NumericQ[$SourceVaultEagleMtimeTTL], $SourceVaultEagleMtimeTTL, 5];
    If[! force && Length[cache] > 0,
      With[{e = Lookup[$iSVEGMtimeCache, lib, Missing[]]},
        If[ListQ[e] && now - e[[1]] < ttl, Return[Values[cache]]]]];
    st = iSVEGMtimeStamp[lib];
    If[! force && Length[cache] > 0 && st === Lookup[$iSVEGItemsStamp, lib, None],
      AssociateTo[$iSVEGMtimeCache, lib -> {now, st}];
      Return[Values[cache]]];
    (* 照合: id の真実源は images/ ディレクトリ走査。
       mtime.json は「最近変更された item」の部分インデックスで全 item は載らないため
       (実ライブラリで実測: エントリ 1k / 総数 56k)、変更検知のオーバーレイとしてだけ使う。
       エントリが無い item は「前回読み込み以降未変更」とみなす。 *)
    mt = iSVEGMtimes[lib];
    If[! AssociationQ[mt],
      If[! iSVEGOnlineProbe[lib],
        iSVEGMarkOffline[lib]; Return[Values[cache]]];
      mt = <||>];
    ids = iSVEGScanIds[lib];
    If[ids === {} && ! iSVEGOnlineProbe[lib],
      (* NAS 瞬断で空走査になった場合はキャッシュを破棄せず温存 *)
      iSVEGMarkOffline[lib]; Return[Values[cache]]];
    seen = Lookup[$iSVEGItemCacheSeen, lib, <||>];
    changed = If[force, ids,
      Select[ids,
        ! KeyExistsQ[cache, #] || Lookup[seen, #, -2] =!= Lookup[mt, #, -1] &]];
    Scan[
      Function[id,
        With[{m = iSVEGLoadItemMeta[lib, id]},
          If[AssociationQ[m],
            (cache[id] = m;
             seen[id] = Lookup[mt, id, -1];
             nChanged++),
            (* 読込失敗 (Eagle 書込途中 / NAS 瞬断): 既存 entry は保持し、
               seen を更新しないことで次回再試行する *)
            Null]]],
      changed];
    dropped = Length[cache];
    cache = KeyTake[cache, ids];   (* ディレクトリから消えた item を落とす *)
    dropped = dropped - Length[cache];
    seen = KeyTake[seen, ids];
    AssociateTo[$iSVEGItemCache, lib -> cache];
    AssociateTo[$iSVEGItemCacheSeen, lib -> seen];
    AssociateTo[$iSVEGItemsStamp, lib -> st];
    AssociateTo[$iSVEGMtimeCache, lib -> {now, st}];
    $iSVEGCacheDirty[lib] = Lookup[$iSVEGCacheDirty, lib, 0] + nChanged + dropped;
    If[Length[cache] > 0 &&
       ($iSVEGCacheDirty[lib] >= If[NumericQ[$SourceVaultEagleCacheSaveEvery],
           $SourceVaultEagleCacheSaveEvery, 50] ||
        ($iSVEGCacheDirty[lib] > 0 &&
         ! TrueQ[Quiet@Check[FileExistsQ[iSVEGCachePath[lib]], False]])),
      iSVEGDiskCacheSave[lib]];
    Values[cache]];

Options[SourceVaultEagleItem] = {"Library" -> Automatic};
SourceVaultEagleItem[id_String, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], cache},
    If[lib === $Failed, Return[Missing["NoLibrary"]]];
    SourceVaultEagleItems["Library" -> lib];   (* キャッシュ更新 *)
    cache = Lookup[$iSVEGItemCache, lib, <||>];
    Lookup[cache, id, Missing["ItemNotFound", id]]];

(* item 指定の正規化: id 文字列 / item Association *)
iSVEGItemOf[lib_, x_Association] := If[KeyExistsQ[x, "id"], x, $Failed];
iSVEGItemOf[lib_, id_String] :=
  With[{m = SourceVaultEagleItem[id, "Library" -> lib]},
    If[AssociationQ[m], m, $Failed]];
iSVEGItemOf[___] := $Failed;

iSVEGItemId[x_Association] := ToString@Lookup[x, "id", ""];
iSVEGItemId[id_String] := id;

(* 原本/サムネイルのパス。name はファイル名サニタイズの可能性があるので
   metadata 由来の名前が無ければ .info 内の実ファイルへフォールバックする。 *)
Options[SourceVaultEagleItemPath] = {"Library" -> Automatic};
SourceVaultEagleItemPath[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], item, dir, byName, files},
    If[lib === $Failed, Return[Missing["NoLibrary"]]];
    If[! iSVEGOnlineQ[lib], Return[Missing["Offline"]]];
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed, Return[Missing["ItemNotFound"]]];
    dir = iSVEGInfoDir[lib, iSVEGItemId[item]];
    byName = FileNameJoin[{dir,
      ToString@Lookup[item, "name", ""] <> "." <> ToString@Lookup[item, "ext", ""]}];
    If[FileExistsQ[byName], Return[byName]];
    files = Select[FileNames["*", dir],
      FileNameTake[#] =!= "metadata.json" &&
      ! StringEndsQ[FileNameTake[#], "_thumbnail.png"] &];
    If[files === {}, Missing["FileNotFound", dir], First[files]]];

Options[SourceVaultEagleThumbnailPath] = {"Library" -> Automatic};
SourceVaultEagleThumbnailPath[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], item, dir, cands},
    If[lib === $Failed, Return[Missing["NoLibrary"]]];
    If[! iSVEGOnlineQ[lib], Return[Missing["Offline"]]];
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed, Return[Missing["ItemNotFound"]]];
    dir = iSVEGInfoDir[lib, iSVEGItemId[item]];
    cands = FileNames["*_thumbnail.png", dir];
    If[cands === {}, Missing["NoThumbnail"], First[cands]]];

Options[SourceVaultEagleThumbnail] = {"Library" -> Automatic, "Size" -> Automatic};
SourceVaultEagleThumbnail[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], tp, img, path, sz = OptionValue["Size"]},
    tp = SourceVaultEagleThumbnailPath[itemSpec, "Library" -> lib];
    img = If[StringQ[tp], Quiet@Check[Import[tp], $Failed], $Failed];
    If[! ImageQ[img],
      path = SourceVaultEagleItemPath[itemSpec, "Library" -> lib];
      If[StringQ[path],
        img = Quiet@Check[Thumbnail[Import[path]], $Failed]]];
    Which[
      ! ImageQ[img], Missing["NoThumbnail"],
      IntegerQ[sz], ImageResize[img, {UpTo[sz], UpTo[sz]}],
      True, img]];

(* ============================================================
   フォルダ
   ============================================================ *)

(* metadata.json はファイル日付+サイズで簡易キャッシュ (View の行ごと再 Import を回避) *)
If[! AssociationQ[$iSVEGLibMetaCache], $iSVEGLibMetaCache = <||>];
(* フォルダツリーの平坦化結果 + id->名前 表のキャッシュ (lib -> {md, flat, byId})。
   1000 フォルダ級ライブラリで行ごとの再走査を避ける。 *)
If[! AssociationQ[$iSVEGFolderFlatCache], $iSVEGFolderFlatCache = <||>];

iSVEGLibMetaStamp[lib_String] :=
  With[{p = FileNameJoin[{lib, "metadata.json"}]},
    {Quiet@Check[FileDate[p, "Modification"], $Failed],
     Quiet@Check[FileByteCount[p], $Failed]}];

Options[SourceVaultEagleLibraryInfo] = {"Library" -> Automatic};
SourceVaultEagleLibraryInfo[OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], stamp, cached, md},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    iSVEGDiskCacheLoad[lib];
    cached = Lookup[$iSVEGLibMetaCache, lib, Missing[]];
    If[! iSVEGOnlineQ[lib],
      (* オフライン: 最後に読めた metadata (メモリ/ディスクキャッシュ) を返す *)
      Return[If[ListQ[cached], cached[[2]],
        <|"Status" -> "Error", "Reason" -> "LibraryOffline"|>]]];
    stamp = iSVEGLibMetaStamp[lib];
    If[ListQ[cached] && cached[[1]] === stamp, Return[cached[[2]]]];
    md = iSVEGImportJSON[FileNameJoin[{lib, "metadata.json"}]];
    Which[
      AssociationQ[md],
        (AssociateTo[$iSVEGLibMetaCache, lib -> {stamp, md}]; md),
      ListQ[cached], cached[[2]],   (* 瞬断: 前回読めた値で継続 *)
      True, <|"Status" -> "Error", "Reason" -> "MetadataUnreadable"|>]];

iSVEGWalkFolders[fs_List, path_List, cb_] :=
  Scan[Function[f,
     With[{p = Append[path, ToString@Lookup[f, "name", ""]]},
       cb[f, p];
       iSVEGWalkFolders[Lookup[f, "children", {}], p, cb]]], fs];

Options[SourceVaultEagleFolders] = {"Library" -> Automatic};
SourceVaultEagleFolders[OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], md, e, out = {}, byId},
    If[! StringQ[lib], Return[{}]];
    md = SourceVaultEagleLibraryInfo["Library" -> lib];
    If[! AssociationQ[md] || ! ListQ[Lookup[md, "folders", $Failed]], Return[{}]];
    e = Lookup[$iSVEGFolderFlatCache, lib, Missing[]];
    If[ListQ[e] && e[[1]] === md, Return[e[[2]]]];
    iSVEGWalkFolders[md["folders"], {},
      Function[{f, p}, AppendTo[out, Join[f, <|"Path" -> p|>]]]];
    byId = Association[
      (ToString@Lookup[#, "id", ""] -> ToString@Lookup[#, "name", ""]) & /@ out];
    AssociateTo[$iSVEGFolderFlatCache, lib -> {md, out, byId}];
    out];

(* フォルダ id -> 名前 の表 (キャッシュ済み)。IndexRecord / View の行ごと解決用。 *)
iSVEGFolderById[lib_] :=
  (SourceVaultEagleFolders["Library" -> lib];
   With[{e = Lookup[$iSVEGFolderFlatCache, lib, Missing[]]},
     If[ListQ[e] && Length[e] >= 3, e[[3]], <||>]]);

(* フォルダ一覧の Dataset (階層パス + 直属 item 数)。中身の確認の起点。
   Folder 名はクリックで SourceVaultEagleShowFolder (FolderView を新規ノートブックに表示)。 *)
(* 既定は notebook list 風 Grid (フォルダ名クリックで FolderView を新規ノートブックに)。
   "Links"->False は素のデータ行 Dataset (プログラム処理・テスト用)。
   Dataset はセル内の式に含まれる文字列をクォート付き表示するため、
   リンク付き表示には Grid を使う。 *)
Options[SourceVaultEagleFolderList] = {"Library" -> Automatic,
  "IncludeDeleted" -> False, "Links" -> True, "IncludeSmart" -> True};
SourceVaultEagleFolderList[OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], links = TrueQ[OptionValue["Links"]],
      fs, sfs, items, counts, ff, mkData, rows, header, body},
    If[! StringQ[lib],
      Return[If[links, Style["Eagle ライブラリが未登録です。", "Text"], Dataset[{}]]]];
    fs = SourceVaultEagleFolders["Library" -> lib];
    sfs = If[TrueQ[OptionValue["IncludeSmart"]],
      SourceVaultEagleSmartFolders["Library" -> lib], {}];
    items = SourceVaultEagleItems["Library" -> lib];
    If[! TrueQ[OptionValue["IncludeDeleted"]],
      items = Select[items, ! TrueQ[Lookup[#, "isDeleted", False]] &]];
    counts = Counts[Flatten[(ToString /@ Lookup[#, "folders", {}]) & /@ items]];
    mkData = Function[{f, kind, n},
      <|"Folder" -> StringRiffle[
          Lookup[f, "Path", {ToString@Lookup[f, "name", ""]}], " / "],
        "Kind" -> kind, "Items" -> n,
        "Id" -> ToString@Lookup[f, "id", ""],
        "Modified" -> iSVEGDateStr[Lookup[f, "modificationTime", Missing[]]]|>];
    rows = Join[
      (mkData[#, "Folder", Lookup[counts, ToString@Lookup[#, "id", ""], 0]] &) /@ fs,
      (mkData[#, If[TrueQ[Lookup[#, "Supported", True]], "Smart",
           "Smart (一部条件未対応)"],
         Count[items, it_ /; iSVEGSmartMatch[it, #]]] &) /@ sfs];
    If[! links, Return[Dataset[rows]]];
    ff = iSVEGFont[];
    header = (Style[#, Bold, FontFamily -> ff] &) /@
      {"フォルダ", "種別", "件数", "Id", "更新日"};
    body = Function[row,
      {Button[Style[Row[{row["Folder"]}], "Hyperlink", FontFamily -> ff],
         SourceVaultEagleShowFolder[row["Id"], "Library" -> lib],
         Appearance -> "Frameless", Method -> "Queued",
         BaseStyle -> "Hyperlink"],
       row["Kind"], row["Items"], row["Id"], row["Modified"]}] /@ rows;
    Grid[Prepend[body, header],
      Frame -> All, FrameStyle -> Directive[GrayLevel[0.85]],
      Background -> {None, {GrayLevel[0.92], {White}}},
      Alignment -> {Left, Center}, Spacings -> {1.2, 0.7},
      BaseStyle -> {FontFamily -> ff}]];

Options[SourceVaultEagleFindFolder] = {"Library" -> Automatic};
SourceVaultEagleFindFolder[spec_String, OptionsPattern[]] :=
  Module[{fs = SourceVaultEagleFolders["Library" -> OptionValue["Library"]], hit},
    hit = SelectFirst[fs, ToString@Lookup[#, "id", ""] === spec &, Missing[]];
    If[AssociationQ[hit], Return[hit]];
    hit = SelectFirst[fs, ToString@Lookup[#, "name", ""] === spec &, Missing[]];
    If[AssociationQ[hit], hit, Missing["FolderNotFound", spec]]];

(* ============================================================
   スマートフォルダ (metadata.json の smartFolders = 保存された検索条件)
   実ライブラリで使用されている rule (rating / type / tags / folders /
   mtime between / fileSize+unit) を中心に評価する。未知の property /
   method は安全側 (不一致) に倒し、Supported フラグで判別できる。
   ============================================================ *)

$iSVEGVideoExts = {"mp4", "mov", "avi", "mkv", "webm", "m4v", "wmv",
  "flv", "mpg", "mpeg", "3gp"};
$iSVEGAudioExts = {"mp3", "wav", "m4a", "flac", "ogg", "aac", "wma"};
$iSVEGImageExtsAll = {"jpg", "jpeg", "png", "gif", "bmp", "webp",
  "heic", "heif", "tif", "tiff", "svg"};

iSVEGSmartNum[v_] := Which[
  NumericQ[v], N[v],
  StringQ[v],
    Quiet@Check[With[{n = ToExpression[v]}, If[NumericQ[n], N[n], $Failed]], $Failed],
  True, $Failed];

iSVEGSmartSizeBytes[amount_, unit_] :=
  With[{a = iSVEGSmartNum[amount],
      mult = Switch[ToLowerCase[ToString[unit]],
        "kb", 2.^10, "mb", 2.^20, "gb", 2.^30, "tb", 2.^40, _, 1.]},
    If[NumericQ[a], a*mult, $Failed]];

(* 数値/日付(ms) 比較。between は val={lo,hi} (両端含む)。 *)
iSVEGSmartCmp[x_, method_, val_] :=
  Module[{v},
    If[! NumericQ[x], Return[False]];
    If[method === "between",
      Return[ListQ[val] && Length[val] >= 2 &&
        NumericQ[iSVEGSmartNum[val[[1]]]] && NumericQ[iSVEGSmartNum[val[[2]]]] &&
        iSVEGSmartNum[val[[1]]] <= x <= iSVEGSmartNum[val[[2]]]]];
    v = iSVEGSmartNum[If[ListQ[val], First[val, $Failed], val]];
    If[! NumericQ[v], Return[False]];
    Switch[method,
      ">", x > v, "<", x < v, ">=", x >= v, "<=", x <= v,
      "equal" | "=", x == v, "unequal" | "!=", x != v, _, False]];

iSVEGSmartRuleMatch[item_Association, rule_Association] :=
  Module[{prop, method, val},
    prop = ToLowerCase@ToString@Lookup[rule, "property", ""];
    method = ToLowerCase@ToString@Lookup[rule, "method", ""];
    val = Lookup[rule, "value", Missing["NoValue"]];
    Switch[prop,
      "tags" | "folders",
        Module[{vals = ToString /@ Flatten[{val}],
            have = ToString /@ Lookup[item, prop, {}]},
          Switch[method,
            "union", IntersectingQ[have, vals],          (* いずれかを含む *)
            "intersection", SubsetQ[have, vals],         (* すべて含む *)
            "exclusion", ! IntersectingQ[have, vals],    (* いずれも含まない *)
            _, False]],
      "rating",
        iSVEGSmartCmp[Lookup[item, "star", 0], method, val],
      "type",
        Module[{v = ToLowerCase@ToString@If[ListQ[val], First[val, ""], val],
            e = ToLowerCase@ToString@Lookup[item, "ext", ""]},
          Which[
            v === "video", MemberQ[$iSVEGVideoExts, e],
            v === "audio", MemberQ[$iSVEGAudioExts, e],
            v === "image", MemberQ[$iSVEGImageExtsAll, e],
            True, e === v]],
      "ext",
        ToLowerCase@ToString@Lookup[item, "ext", ""] ===
          ToLowerCase@ToString@If[ListQ[val], First[val, ""], val],
      "name" | "annotation" | "url",
        Module[{s = ToString@Lookup[item, prop, ""],
            v = ToString@If[ListQ[val], First[val, ""], val]},
          Switch[method,
            "contain", StringContainsQ[s, v, IgnoreCase -> True],
            "uncontain" | "notcontain" | "exclude",
              ! StringContainsQ[s, v, IgnoreCase -> True],
            "equal", ToLowerCase[s] === ToLowerCase[v],
            "startwith", StringStartsQ[s, v, IgnoreCase -> True],
            "endwith", StringEndsQ[s, v, IgnoreCase -> True],
            "empty", StringTrim[s] === "",
            "notempty" | "filled", StringTrim[s] =!= "",
            _, False]],
      "filesize",
        Module[{size = Lookup[item, "size", Missing["NoSize"]],
            unit = Lookup[rule, "unit", "b"], lo, hi, thr},
          Which[
            ! NumericQ[size], False,
            method === "between" && ListQ[val] && Length[val] >= 2,
              lo = iSVEGSmartSizeBytes[val[[1]], unit];
              hi = iSVEGSmartSizeBytes[val[[2]], unit];
              NumericQ[lo] && NumericQ[hi] && lo <= size <= hi,
            True,
              (* Eagle は value を {amount, _} のリストで保存する ("unit" 別キー) *)
              thr = iSVEGSmartSizeBytes[If[ListQ[val], First[val, $Failed], val], unit];
              NumericQ[thr] && Switch[method,
                ">", size > thr, "<", size < thr, ">=", size >= thr,
                "<=", size <= thr, "equal" | "=", size == thr, _, False]]],
      "width" | "height" | "duration",
        iSVEGSmartCmp[Lookup[item, prop, Missing["None"]], method, val],
      "btime" | "mtime" | "lastmodified" | "modificationtime",
        With[{key = prop /. {"lastmodified" -> "lastModified",
            "modificationtime" -> "modificationTime"}},
          iSVEGSmartCmp[Lookup[item, key, Missing["None"]], method, val]],
      _, False]];
iSVEGSmartRuleMatch[___] := False;

iSVEGSmartRuleSupportedQ[rule_Association] :=
  MemberQ[{"tags", "folders", "rating", "type", "ext", "name", "annotation",
    "url", "filesize", "width", "height", "duration", "btime", "mtime",
    "lastmodified", "modificationtime"},
    ToLowerCase@ToString@Lookup[rule, "property", ""]];

iSVEGSmartSupportedQ[sf_Association] :=
  AllTrue[
    Flatten[(Lookup[#, "rules", {}] &) /@
      Select[Lookup[sf, "conditions", {}], AssociationQ]],
    iSVEGSmartRuleSupportedQ];

(* 条件グループ: rules を match (OR/AND) で結合し boolean=FALSE なら反転。
   グループどうしは AND。 *)
iSVEGSmartGroupMatch[item_, g_Association] :=
  Module[{rules = Select[Lookup[g, "rules", {}], AssociationQ], m, r},
    m = ToUpperCase@ToString@Lookup[g, "match", "OR"];
    r = If[m === "AND",
      AllTrue[rules, iSVEGSmartRuleMatch[item, #] &],
      AnyTrue[rules, iSVEGSmartRuleMatch[item, #] &]];
    If[ToUpperCase@ToString@Lookup[g, "boolean", "TRUE"] === "FALSE", ! r, r]];

iSVEGSmartMatch[item_Association, sf_Association] :=
  With[{conds = Select[Lookup[sf, "conditions", {}], AssociationQ]},
    conds =!= {} && AllTrue[conds, iSVEGSmartGroupMatch[item, #] &]];

(* Recursive 時は子スマートフォルダも OR で含める *)
iSVEGSmartNodes[sf_Association, recursive_] :=
  If[! TrueQ[recursive], {sf},
    Module[{out = {}},
      iSVEGWalkFolders[{sf}, {}, Function[{f, p}, AppendTo[out, f]]];
      out]];

iSVEGSmartPredOf[sf_Association, recursive_] :=
  With[{nodes = iSVEGSmartNodes[sf, recursive]},
    Function[item, AnyTrue[nodes, iSVEGSmartMatch[item, #] &]]];

Options[SourceVaultEagleSmartFolders] = {"Library" -> Automatic};
SourceVaultEagleSmartFolders[OptionsPattern[]] :=
  Module[{md = SourceVaultEagleLibraryInfo["Library" -> OptionValue["Library"]],
      out = {}},
    If[! AssociationQ[md] || ! ListQ[Lookup[md, "smartFolders", $Failed]],
      Return[{}]];
    iSVEGWalkFolders[md["smartFolders"], {},
      Function[{f, p}, AppendTo[out,
        Join[f, <|"Path" -> p, "Smart" -> True,
          "Supported" -> iSVEGSmartSupportedQ[f]|>]]]];
    out];

(* フォルダ指定の一元解決: 通常フォルダ (id/名前) 優先、無ければスマートフォルダ。 *)
iSVEGResolveFolderSpec[lib_, spec_, recursive_] :=
  Module[{f, sfs, hit, s},
    Which[
      AssociationQ[spec] && KeyExistsQ[spec, "conditions"],
        <|"Type" -> "Smart", "Folder" -> spec|>,
      AssociationQ[spec],
        <|"Type" -> "Folder", "Folder" -> spec,
          "Ids" -> If[TrueQ[recursive], iSVEGFolderSubtreeIds[spec],
            {ToString@Lookup[spec, "id", ""]}]|>,
      True,
        s = ToString[spec];
        f = SourceVaultEagleFindFolder[s, "Library" -> lib];
        If[AssociationQ[f],
          <|"Type" -> "Folder", "Folder" -> f,
            "Ids" -> If[TrueQ[recursive], iSVEGFolderSubtreeIds[f],
              {ToString@Lookup[f, "id", ""]}]|>,
          sfs = SourceVaultEagleSmartFolders["Library" -> lib];
          hit = SelectFirst[sfs,
            ToString@Lookup[#, "id", ""] === s ||
            ToString@Lookup[#, "name", ""] === s &, Missing[]];
          If[AssociationQ[hit],
            <|"Type" -> "Smart", "Folder" -> hit|>,
            Missing["FolderNotFound", s]]]]];

iSVEGFolderSubtreeIds[f_Association] :=
  Prepend[Flatten[iSVEGFolderSubtreeIds /@ Lookup[f, "children", {}]],
    ToString@Lookup[f, "id", ""]];

Options[SourceVaultEagleItemsInFolder] = {"Library" -> Automatic, "Recursive" -> False,
  "IncludeDeleted" -> False};
SourceVaultEagleItemsInFolder[folderSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], res, items},
    If[lib === $Failed, Return[{}]];
    res = iSVEGResolveFolderSpec[lib, folderSpec, TrueQ[OptionValue["Recursive"]]];
    If[! AssociationQ[res], Return[{}]];
    items = SourceVaultEagleItems["Library" -> lib];
    items = If[res["Type"] === "Smart",
      With[{pred = iSVEGSmartPredOf[res["Folder"], TrueQ[OptionValue["Recursive"]]]},
        Select[items, pred]],
      With[{ids = res["Ids"]},
        Select[items, IntersectingQ[ToString /@ Lookup[#, "folders", {}], ids] &]]];
    If[TrueQ[OptionValue["IncludeDeleted"]], items,
      Select[items, ! TrueQ[Lookup[#, "isDeleted", False]] &]]];

Options[SourceVaultEagleTags] = {"Library" -> Automatic};
SourceVaultEagleTags[OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], items, counts, tj},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    items = Select[SourceVaultEagleItems["Library" -> lib],
      ! TrueQ[Lookup[#, "isDeleted", False]] &];
    counts = ReverseSort@Association[Rule @@@ Tally[
       Flatten[(ToString /@ Lookup[#, "tags", {}]) & /@ items]]];
    tj = If[iSVEGOnlineQ[lib],
      iSVEGImportJSON[FileNameJoin[{lib, "tags.json"}]], $Failed];
    <|"Counts" -> counts,
      "HistoryTags" -> If[AssociationQ[tj], Lookup[tj, "historyTags", {}], {}],
      "StarredTags" -> If[AssociationQ[tj], Lookup[tj, "starredTags", {}], {}]|>];

(* ============================================================
   日付フィルタ (maildb の日単位包含比較と同じ流儀)
   ============================================================ *)

iSVEGDayListOf[Automatic] := Automatic;
iSVEGDayListOf[x_] := Quiet@Check[DateValue[x, {"Year", "Month", "Day"}], $Failed];

iSVEGItemDay[ms_?NumericQ] :=
  Quiet@Check[DateValue[FromUnixTime[ms/1000.], {"Year", "Month", "Day"}], $Failed];
iSVEGItemDay[_] := $Failed;

iSVEGDateInRange[ms_, fromDay_, toDay_] :=
  Module[{dDay},
    If[fromDay === Automatic && toDay === Automatic, Return[True]];
    dDay = iSVEGItemDay[ms];
    If[! MatchQ[dDay, {_Integer, _Integer, _Integer}], Return[False]];
    And[
      fromDay === Automatic || ! MatchQ[fromDay, {_Integer, _Integer, _Integer}] ||
        OrderedQ[{fromDay, dDay}],
      toDay === Automatic || ! MatchQ[toDay, {_Integer, _Integer, _Integer}] ||
        OrderedQ[{dDay, toDay}]]];

(* ============================================================
   検索
   ============================================================ *)

Options[SourceVaultEagleSearch] = {
  "Library" -> Automatic,
  "Tags" -> Automatic, "TagMode" -> "Any",
  "Folder" -> Automatic, "Recursive" -> True,
  "Ext" -> Automatic,
  "DateFrom" -> Automatic, "DateTo" -> Automatic, "DateBy" -> "btime",
  "IncludeDeleted" -> False, "HasAnnotation" -> Automatic,
  "IncludeSummary" -> True,
  "SortBy" -> Automatic, "SortOrder" -> "Desc", "Newest" -> True,
  "Limit" -> Automatic};

iSVEGDateMsOf[item_, by_] :=
  Lookup[item, by, Lookup[item, "btime", Lookup[item, "modificationTime", 0]]];

(* テキスト一致: name / annotation / url / tags + (既定で) 保存済みサマリー本文
   + サマリーノート (notes/*.nb の補足追記)。
   sums は id -> summary record、notes は id -> {stamp, text} のキャッシュ。 *)
iSVEGMatchQuery[item_, q_String, sums_Association, notes_Association] :=
  q === "" || With[{id = ToString@Lookup[item, "id", ""]},
    AnyTrue[
      Flatten[{ToString@Lookup[item, "name", ""],
        ToString@Lookup[item, "annotation", ""],
        ToString@Lookup[item, "url", ""],
        ToString /@ Lookup[item, "tags", {}],
        With[{r = Lookup[sums, id, Missing[]]},
          If[AssociationQ[r], ToString@Lookup[r, "Summary", ""], Nothing]],
        With[{n = Lookup[notes, id, Missing[]]},
          If[ListQ[n] && StringQ[n[[2]]], n[[2]], Nothing]]}],
      StringContainsQ[#, q, IgnoreCase -> True] &]];

SourceVaultEagleSearch[query_String : "", OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], q = StringTrim[query],
      tags, tagMode, folder, ext, df, dt, dateBy, hasAnn, items, folderPred,
      by, hits, lim, sums, notes},
    If[lib === $Failed, Return[{}]];
    tags = OptionValue["Tags"];
    tags = Which[tags === Automatic, Automatic, StringQ[tags], {tags}, ListQ[tags], tags, True, Automatic];
    tagMode = OptionValue["TagMode"];
    folder = OptionValue["Folder"];
    ext = OptionValue["Ext"];
    ext = Which[ext === Automatic, Automatic, StringQ[ext], {ToLowerCase[ext]},
      ListQ[ext], ToLowerCase /@ ext, True, Automatic];
    df = iSVEGDayListOf[OptionValue["DateFrom"]];
    dt = iSVEGDayListOf[OptionValue["DateTo"]];
    dateBy = OptionValue["DateBy"];
    hasAnn = OptionValue["HasAnnotation"];
    (* "Folder" は通常フォルダ (id/名前) に加えスマートフォルダも指定できる *)
    folderPred = If[folder === Automatic, None,
      With[{res = iSVEGResolveFolderSpec[lib, folder,
          TrueQ[OptionValue["Recursive"]]]},
        Which[
          ! AssociationQ[res], (False &),
          res["Type"] === "Smart",
            iSVEGSmartPredOf[res["Folder"], TrueQ[OptionValue["Recursive"]]],
          True, With[{ids = res["Ids"]},
            Function[it,
              IntersectingQ[ToString /@ Lookup[it, "folders", {}], ids]]]]]];
    items = SourceVaultEagleItems["Library" -> lib];
    (* サマリー本文とノート本文もテキスト一致の対象 (query があるときだけロード)。
       ノートの Cloud-Publishable 判定に item キャッシュを使うため items の後。 *)
    sums = If[TrueQ[OptionValue["IncludeSummary"]] && q =!= "",
      iSVEGSummaryCacheEnsure[], <||>];
    notes = If[TrueQ[OptionValue["IncludeSummary"]] && q =!= "",
      iSVEGNotesEnsure[], <||>];
    hits = Select[items, Function[it,
      And[
        TrueQ[OptionValue["IncludeDeleted"]] || ! TrueQ[Lookup[it, "isDeleted", False]],
        iSVEGMatchQuery[it, q, sums, notes],
        tags === Automatic ||
          With[{itTags = ToString /@ Lookup[it, "tags", {}]},
            If[tagMode === "All", SubsetQ[itTags, tags], IntersectingQ[itTags, tags]]],
        folderPred === None || TrueQ[folderPred[it]],
        ext === Automatic || MemberQ[ext, ToLowerCase@ToString@Lookup[it, "ext", ""]],
        hasAnn === Automatic ||
          TrueQ[StringQ[Lookup[it, "annotation", ""]] &&
            StringTrim[ToString@Lookup[it, "annotation", ""]] =!= ""] === TrueQ[hasAnn],
        iSVEGDateInRange[iSVEGDateMsOf[it, dateBy], df, dt]]]];
    by = OptionValue["SortBy"] /. Automatic ->
      If[TrueQ[OptionValue["Newest"]], "Date", None];
    If[by =!= None,
      hits = SortBy[hits, Switch[by,
        "Name", ToString@Lookup[#, "name", ""],
        "Size", Lookup[#, "size", 0],
        "MTime", Lookup[#, "mtime", 0],
        _, iSVEGDateMsOf[#, dateBy]] &];
      If[OptionValue["SortOrder"] === "Desc" || OptionValue["SortOrder"] === Descending,
        hits = Reverse[hits]]];
    lim = OptionValue["Limit"];
    If[IntegerQ[lim] && lim >= 0, hits = Take[hits, UpTo[lim]]];
    hits];

(* ============================================================
   開く
   ============================================================ *)

Options[SourceVaultEagleOpenItem] = {"Library" -> Automatic};
SourceVaultEagleOpenItem[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], p},
    If[StringQ[lib] && ! iSVEGOnlineQ[lib], Return[iSVEGOffline[]]];
    p = SourceVaultEagleItemPath[itemSpec, "Library" -> OptionValue["Library"]];
    If[StringQ[p] && FileExistsQ[p],
      (Quiet@Check[SystemOpen[p], Null]; <|"Status" -> "Opened", "Path" -> p|>),
      <|"Status" -> "Error", "Reason" -> "FileNotFound", "Path" -> p|>]];

SourceVaultEagleShowInApp[itemSpec_] :=
  With[{id = If[AssociationQ[itemSpec], iSVEGItemId[itemSpec], ToString[itemSpec]]},
    Quiet@Check[SystemOpen["eagle://item/" <> id], Null];
    <|"Status" -> "Opened", "Link" -> "eagle://item/" <> id|>];

(* ============================================================
   Eagle ローカル HTTP API
   ============================================================ *)

iSVEGAPIBase[] :=
  If[StringQ[$SourceVaultEagleAPIBase], $SourceVaultEagleAPIBase, "http://localhost:41595"];

iSVEGAPIQuery[] :=
  If[StringQ[$SourceVaultEagleAPIToken] && $SourceVaultEagleAPIToken =!= "",
    {"token" -> $SourceVaultEagleAPIToken}, {}];

(* 一時ファイル経由で UTF-8 bytes を作る (maildb で実証済みの Windows 安全パターン) *)
iSVEGTmpJSON[tag_] := FileNameJoin[{$TemporaryDirectory,
  "sv_eagle_" <> tag <> "_" <> IntegerString[$ProcessID] <> "_" <>
  IntegerString[RandomInteger[{0, 999999999}]] <> ".json"}];

iSVEGJSONBytes[expr_] :=
  Module[{f = iSVEGTmpJSON["req"], bytes},
    Quiet@Check[Export[f, expr, "RawJSON", "Compact" -> True], Return[$Failed]];
    bytes = Quiet@Check[ByteArray[BinaryReadList[f]], $Failed];
    Quiet@DeleteFile[f];
    bytes];

iSVEGParseJSONBytes[bytes_] :=
  Module[{f = iSVEGTmpJSON["resp"], strm, json},
    If[Head[bytes] =!= ByteArray, Return[$Failed]];
    Quiet[strm = OpenWrite[f, BinaryFormat -> True];
      BinaryWrite[strm, Normal[bytes]]; Close[strm]];
    json = Quiet@Check[Import[f, "RawJSON"], $Failed];
    Quiet@DeleteFile[f];
    json];

Options[SourceVaultEagleAPICall] = {"Timeout" -> 15};
SourceVaultEagleAPICall[endpoint_String, params : (_Association | None) : None,
    OptionsPattern[]] :=
  Module[{url, req, body, resp, json},
    url = URLBuild[iSVEGAPIBase[] <> endpoint, iSVEGAPIQuery[]];
    req = If[params === None || params === <||>,
      HTTPRequest[url, <|"Method" -> "GET"|>],
      (body = iSVEGJSONBytes[params];
       If[body === $Failed,
         Return[<|"Status" -> "Error", "Reason" -> "RequestEncodeFailed"|>]];
       HTTPRequest[url, <|"Method" -> "POST",
         "Headers" -> {"Content-Type" -> "application/json; charset=utf-8"},
         "Body" -> body|>])];
    resp = Quiet@Check[URLRead[req, TimeConstraint -> OptionValue["Timeout"]], $Failed];
    If[! MatchQ[resp, _HTTPResponse],
      Return[<|"Status" -> "Error", "Reason" -> "Unreachable", "Endpoint" -> endpoint|>]];
    If[resp["StatusCode"] =!= 200,
      Return[<|"Status" -> "Error", "Reason" -> "HTTP" <> ToString[resp["StatusCode"]],
        "Endpoint" -> endpoint,
        "Hint" -> "トークンが必要なら $SourceVaultEagleAPIToken を設定してください。"|>]];
    json = iSVEGParseJSONBytes[Quiet@Check[resp["BodyByteArray"], $Failed]];
    If[! AssociationQ[json],
      Return[<|"Status" -> "Error", "Reason" -> "BadJSON", "Endpoint" -> endpoint|>]];
    If[ToString@Lookup[json, "status", ""] =!= "success",
      Return[<|"Status" -> "Error", "Reason" -> "APIStatus",
        "Detail" -> Lookup[json, "data", Lookup[json, "message", Missing[]]],
        "Endpoint" -> endpoint|>]];
    <|"Status" -> "OK", "Data" -> Lookup[json, "data", Missing[]]|>];

iSVEGAPIAvailableNow[] :=
  Module[{app, libinfo, path = Missing["Unknown"]},
    app = SourceVaultEagleAPICall["/api/application/info"];
    If[Lookup[app, "Status", ""] =!= "OK",
      Return[<|"Available" -> False, "Reason" -> Lookup[app, "Reason", "Unreachable"]|>]];
    libinfo = SourceVaultEagleAPICall["/api/library/info"];
    If[Lookup[libinfo, "Status", ""] === "OK",
      path = Quiet@Check[libinfo["Data"]["library"]["path"],
        Quiet@Check[libinfo["Data"]["path"], Missing["Unknown"]]]];
    <|"Available" -> True,
      "Version" -> Quiet@Check[app["Data"]["version"], Missing[]],
      "OpenLibrary" -> path|>];

(* Eagle 未起動時は接続失敗まで数秒かかるので、判定を TTL キャッシュする
   (変更系は呼び出しごとに死活確認するため、連続操作の体感に効く)。 *)
If[! ValueQ[$SourceVaultEagleAPIRecheckSeconds], $SourceVaultEagleAPIRecheckSeconds = 10];

SourceVaultEagleAPIAvailable[] :=
  Module[{now = AbsoluteTime[], ttl, r},
    ttl = If[NumericQ[$SourceVaultEagleAPIRecheckSeconds],
      $SourceVaultEagleAPIRecheckSeconds, 10];
    If[ListQ[$iSVEGAPIAvailCache] && now - $iSVEGAPIAvailCache[[1]] < ttl,
      Return[$iSVEGAPIAvailCache[[2]]]];
    r = iSVEGAPIAvailableNow[];
    $iSVEGAPIAvailCache = {now, r};
    r];

(* Eagle が対象ライブラリを「開いている」か。API 不達なら False (閉じているとみなす)。
   注意: API 無効設定のまま Eagle が起動している場合は検知できない。
   その間のファイル直接書込は避けること (usage 参照)。 *)
iSVEGEagleHasLibraryOpen[lib_String] :=
  Module[{st = SourceVaultEagleAPIAvailable[]},
    TrueQ[Lookup[st, "Available", False]] &&
    StringQ[Lookup[st, "OpenLibrary", Missing[]]] &&
    iSVEGNormPath[st["OpenLibrary"]] === iSVEGNormPath[lib]];

(* ============================================================
   変更 (mutation) -- Eagle 形式準拠の中核
   ============================================================ *)

(* mtime.json 同期: [id] = ms のみ。
   "all" は「ライブラリの総 item 数」であってエントリ数ではない (mtime.json は
   最近変更分の部分インデックス) ので、既存値を保持する。ファイル直接書込で
   item 数が変わる操作は行わないため再計算不要。欠損時のみ実数で補う。 *)
iSVEGTouchMtime[lib_String, id_String, ms_Integer] :=
  Module[{path = iSVEGMtimePath[lib], mt},
    $iSVEGMtimeCache = KeyDrop[$iSVEGMtimeCache, lib];
    $iSVEGItemsStamp = KeyDrop[$iSVEGItemsStamp, lib];
    mt = iSVEGImportJSON[path];
    If[! AssociationQ[mt], mt = <||>];
    mt[id] = ms;
    If[! KeyExistsQ[mt, "all"], mt["all"] = Length[iSVEGScanIds[lib]]];
    iSVEGAtomicExportJSON[path, mt]];

(* item metadata.json のフィールド更新 (ファイル直接)。
   ディスクから読み直し -> 既知フィールドのみ変更 -> 全フィールド書き戻し。 *)
iSVEGFileUpdateItem[lib_String, id_String, fields_Association] :=
  Module[{path, meta, ms = iSVEGNowMs[]},
    path = FileNameJoin[{iSVEGInfoDir[lib, id], "metadata.json"}];
    meta = iSVEGImportJSON[path];
    If[! AssociationQ[meta],
      Return[<|"Status" -> "Error", "Reason" -> "ItemMetadataUnreadable", "Path" -> path|>]];
    iSVEGShadowBackup[path];
    meta = Join[meta, fields];
    meta["modificationTime"] = ms;
    meta["lastModified"] = ms;
    If[iSVEGAtomicExportJSON[path, meta] === $Failed,
      Return[<|"Status" -> "Error", "Reason" -> "WriteFailed", "Path" -> path|>]];
    iSVEGTouchMtime[lib, id, ms];
    (* キャッシュへ反映 *)
    If[KeyExistsQ[$iSVEGItemCache, lib],
      $iSVEGItemCache[lib, id] = meta;
      $iSVEGItemCacheSeen[lib, id] = ms];
    $iSVEGCacheDirty[lib] = Lookup[$iSVEGCacheDirty, lib, 0] + 1;
    <|"Status" -> "Updated", "Method" -> "File", "Id" -> id|>];

(* 新規タグを tags.json の historyTags にマージ (Eagle のタグ履歴と整合) *)
iSVEGMergeHistoryTags[lib_String, newTags_List] :=
  Module[{path = FileNameJoin[{lib, "tags.json"}], tj, hist},
    tj = iSVEGImportJSON[path];
    If[! AssociationQ[tj], tj = <|"historyTags" -> {}, "starredTags" -> {}|>];
    hist = Lookup[tj, "historyTags", {}];
    tj["historyTags"] = DeleteDuplicates[Join[hist, ToString /@ newTags]];
    iSVEGAtomicExportJSON[path, tj]];

(* API 経由更新後はキャッシュを無効化 (Eagle のディスク書込が遅延するため) *)
iSVEGDropCacheEntry[lib_String, id_String] :=
  (If[KeyExistsQ[$iSVEGItemCacheSeen, lib],
     $iSVEGItemCacheSeen[lib] = KeyDrop[$iSVEGItemCacheSeen[lib], id]];
   If[KeyExistsQ[$iSVEGItemCache, lib],
     $iSVEGItemCache[lib] = KeyDrop[$iSVEGItemCache[lib], id]]);

(* item フィールド更新の経路振り分け。
   apiFields: /api/item/update で送れる形 (id/tags/annotation/url/star)。None なら API 不可。 *)
iSVEGUpdateItem[lib_String, itemSpec_, fields_Association, apiFields_, method_] :=
  Module[{item, id, open},
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed, Return[<|"Status" -> "Error", "Reason" -> "ItemNotFound"|>]];
    id = iSVEGItemId[item];
    open = iSVEGEagleHasLibraryOpen[lib];
    (* Eagle が開いていれば API 経由で書けるが、開いておらず FS も到達不能なら不可 *)
    If[! open && ! iSVEGOnlineQ[lib], Return[iSVEGOffline[]]];
    Which[
      method === "API" || (method === Automatic && open && AssociationQ[apiFields]),
        If[! open,
          Return[<|"Status" -> "Error", "Reason" -> "EagleNotOpenForAPI",
            "Hint" -> "Eagle を起動して対象ライブラリを開いてください。"|>]];
        If[! AssociationQ[apiFields],
          Return[<|"Status" -> "Error", "Reason" -> "NotSupportedByAPI",
            "Hint" -> "この変更は API 非対応です。Eagle を閉じて \"Method\"->\"File\" で実行してください。"|>]];
        With[{r = SourceVaultEagleAPICall["/api/item/update", Append[apiFields, "id" -> id]]},
          If[Lookup[r, "Status", ""] === "OK",
            (iSVEGDropCacheEntry[lib, id];
             <|"Status" -> "Updated", "Method" -> "API", "Id" -> id|>),
            r]],
      open,   (* method === "File" or Automatic だが対象ライブラリが開いている *)
        <|"Status" -> "Error", "Reason" -> "EagleHasLibraryOpen",
          "Hint" -> "Eagle が対象ライブラリを開いています。API 経由 (Automatic) を使うか、Eagle を閉じてから実行してください。"|>,
      True,
        iSVEGFileUpdateItem[lib, id, fields]]];

Options[SourceVaultEagleSetTags] = {"Library" -> Automatic, "Method" -> Automatic};
SourceVaultEagleSetTags[itemSpec_, tags_List, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], ts = ToString /@ tags, r},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    r = iSVEGUpdateItem[lib, itemSpec, <|"tags" -> ts|>, <|"tags" -> ts|>,
      OptionValue["Method"]];
    If[Lookup[r, "Status", ""] === "Updated" && Lookup[r, "Method", ""] === "File",
      iSVEGMergeHistoryTags[lib, ts]];
    r];

Options[SourceVaultEagleAddTags] = Options[SourceVaultEagleSetTags];
SourceVaultEagleAddTags[itemSpec_, tags_List, opts : OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], item},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed, Return[<|"Status" -> "Error", "Reason" -> "ItemNotFound"|>]];
    SourceVaultEagleSetTags[item,
      DeleteDuplicates[Join[ToString /@ Lookup[item, "tags", {}], ToString /@ tags]],
      opts]];

Options[SourceVaultEagleRemoveTags] = Options[SourceVaultEagleSetTags];
SourceVaultEagleRemoveTags[itemSpec_, tags_List, opts : OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], item},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed, Return[<|"Status" -> "Error", "Reason" -> "ItemNotFound"|>]];
    SourceVaultEagleSetTags[item,
      DeleteCases[ToString /@ Lookup[item, "tags", {}],
        Alternatives @@ (ToString /@ tags)],
      opts]];

Options[SourceVaultEagleSetAnnotation] = {"Library" -> Automatic, "Method" -> Automatic};
SourceVaultEagleSetAnnotation[itemSpec_, text_String, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]]},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    iSVEGUpdateItem[lib, itemSpec, <|"annotation" -> text|>, <|"annotation" -> text|>,
      OptionValue["Method"]]];

Options[SourceVaultEagleSetURL] = {"Library" -> Automatic, "Method" -> Automatic};
SourceVaultEagleSetURL[itemSpec_, url_String, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]]},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    iSVEGUpdateItem[lib, itemSpec, <|"url" -> url|>, <|"url" -> url|>,
      OptionValue["Method"]]];

Options[SourceVaultEagleMoveToFolder] = {"Library" -> Automatic, "Method" -> Automatic};
SourceVaultEagleMoveToFolder[itemSpec_, folderSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], f},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    f = If[AssociationQ[folderSpec], folderSpec,
      SourceVaultEagleFindFolder[ToString[folderSpec], "Library" -> lib]];
    If[! AssociationQ[f],
      Return[<|"Status" -> "Error", "Reason" -> "FolderNotFound"|>]];
    (* /api/item/update は folders 非対応 -> apiFields = None でファイル経路のみ *)
    iSVEGUpdateItem[lib, itemSpec,
      <|"folders" -> {ToString@Lookup[f, "id", ""]}|>, None, OptionValue["Method"]]];

Options[SourceVaultEagleTrashItem] = {"Library" -> Automatic, "Method" -> Automatic};
SourceVaultEagleTrashItem[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], item, id, open, method = OptionValue["Method"]},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed, Return[<|"Status" -> "Error", "Reason" -> "ItemNotFound"|>]];
    id = iSVEGItemId[item];
    open = iSVEGEagleHasLibraryOpen[lib];
    If[! open && ! iSVEGOnlineQ[lib], Return[iSVEGOffline[]]];
    Which[
      method === "API" || (method === Automatic && open),
        With[{r = SourceVaultEagleAPICall["/api/item/moveToTrash", <|"itemIds" -> {id}|>]},
          If[Lookup[r, "Status", ""] === "OK",
            (iSVEGDropCacheEntry[lib, id]; <|"Status" -> "Trashed", "Method" -> "API", "Id" -> id|>),
            r]],
      open,
        <|"Status" -> "Error", "Reason" -> "EagleHasLibraryOpen",
          "Hint" -> "Eagle が対象ライブラリを開いています。Automatic (API) を使ってください。"|>,
      True,
        With[{r = iSVEGFileUpdateItem[lib, id, <|"isDeleted" -> True|>]},
          If[Lookup[r, "Status", ""] === "Updated",
            <|"Status" -> "Trashed", "Method" -> "File", "Id" -> id|>, r]]]];

(* ---- フォルダ作成 / 改名 ---- *)

(* Eagle 風 id: 大文字英数 13 桁 (timestamp base36 + random) *)
iSVEGNewFolderId[] :=
  Module[{base = ToUpperCase@IntegerString[iSVEGNowMs[], 36], pad},
    pad = StringJoin[
      RandomChoice[Characters["0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"],
        Max[13 - StringLength[base], 0]]];
    StringTake[base <> pad, 13]];

iSVEGWriteLibraryMetadata[lib_String, md_Association] :=
  Module[{path = FileNameJoin[{lib, "metadata.json"}], md2 = md},
    iSVEGEagleBackupLibraryMetadata[lib];
    md2["modificationTime"] = iSVEGNowMs[];
    $iSVEGLibMetaCache = KeyDrop[$iSVEGLibMetaCache, lib];
    If[iSVEGAtomicExportJSON[path, md2] === $Failed,
      <|"Status" -> "Error", "Reason" -> "WriteFailed", "Path" -> path|>,
      <|"Status" -> "Updated"|>]];

(* フォルダツリーの変換 (id 一致ノードに f を適用)。見つかれば {newTree, True} *)
iSVEGMapFolderTree[fs_List, id_String, f_] :=
  Module[{found = False, out},
    out = Function[node,
      Which[
        ToString@Lookup[node, "id", ""] === id,
          (found = True; f[node]),
        ListQ[Lookup[node, "children", {}]] && Lookup[node, "children", {}] =!= {},
          With[{r = iSVEGMapFolderTree[node["children"], id, f]},
            If[r[[2]], found = True];
            Append[node, "children" -> r[[1]]]],
        True, node]] /@ fs;
    {out, found}];

Options[SourceVaultEagleCreateFolder] = {"Library" -> Automatic, "Method" -> Automatic,
  "Parent" -> Automatic};
SourceVaultEagleCreateFolder[name_String, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], parent = OptionValue["Parent"],
      method = OptionValue["Method"], open, parentId = None, md, node, r},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    If[parent =!= Automatic,
      With[{f = If[AssociationQ[parent], parent,
          SourceVaultEagleFindFolder[ToString[parent], "Library" -> lib]]},
        If[! AssociationQ[f],
          Return[<|"Status" -> "Error", "Reason" -> "ParentFolderNotFound"|>]];
        parentId = ToString@Lookup[f, "id", ""]]];
    open = iSVEGEagleHasLibraryOpen[lib];
    If[! open && ! iSVEGOnlineQ[lib], Return[iSVEGOffline[]]];
    Which[
      method === "API" || (method === Automatic && open),
        If[! open,
          Return[<|"Status" -> "Error", "Reason" -> "EagleNotOpenForAPI"|>]];
        r = SourceVaultEagleAPICall["/api/folder/create",
          Join[<|"folderName" -> name|>,
            If[parentId === None, <||>, <|"parent" -> parentId|>]]];
        If[Lookup[r, "Status", ""] === "OK",
          <|"Status" -> "Created", "Method" -> "API",
            "Folder" -> Lookup[r, "Data", Missing[]]|>, r],
      open,
        <|"Status" -> "Error", "Reason" -> "EagleHasLibraryOpen",
          "Hint" -> "Automatic (API) を使うか Eagle を閉じてください。"|>,
      True,
        md = SourceVaultEagleLibraryInfo["Library" -> lib];
        If[! AssociationQ[md] || ! ListQ[Lookup[md, "folders", $Failed]],
          Return[<|"Status" -> "Error", "Reason" -> "MetadataUnreadable"|>]];
        node = <|"id" -> iSVEGNewFolderId[], "name" -> name, "description" -> "",
          "children" -> {}, "modificationTime" -> iSVEGNowMs[], "tags" -> {},
          "password" -> "", "passwordTips" -> ""|>;
        If[parentId === None,
          md["folders"] = Append[md["folders"], node],
          With[{r2 = iSVEGMapFolderTree[md["folders"], parentId,
              Function[n, Append[n, "children" -> Append[Lookup[n, "children", {}], node]]]]},
            If[! r2[[2]],
              Return[<|"Status" -> "Error", "Reason" -> "ParentFolderNotFound"|>]];
            md["folders"] = r2[[1]]]];
        r = iSVEGWriteLibraryMetadata[lib, md];
        If[Lookup[r, "Status", ""] === "Updated",
          <|"Status" -> "Created", "Method" -> "File", "Folder" -> node|>, r]]];

Options[SourceVaultEagleRenameFolder] = {"Library" -> Automatic, "Method" -> Automatic};
SourceVaultEagleRenameFolder[folderSpec_, newName_String, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], f, id, open, md, r,
      method = OptionValue["Method"]},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    f = If[AssociationQ[folderSpec], folderSpec,
      SourceVaultEagleFindFolder[ToString[folderSpec], "Library" -> lib]];
    If[! AssociationQ[f], Return[<|"Status" -> "Error", "Reason" -> "FolderNotFound"|>]];
    id = ToString@Lookup[f, "id", ""];
    open = iSVEGEagleHasLibraryOpen[lib];
    If[! open && ! iSVEGOnlineQ[lib], Return[iSVEGOffline[]]];
    Which[
      method === "API" || (method === Automatic && open),
        If[! open, Return[<|"Status" -> "Error", "Reason" -> "EagleNotOpenForAPI"|>]];
        r = SourceVaultEagleAPICall["/api/folder/rename",
          <|"folderId" -> id, "newName" -> newName|>];
        If[Lookup[r, "Status", ""] === "OK",
          <|"Status" -> "Renamed", "Method" -> "API", "Id" -> id, "Name" -> newName|>, r],
      open,
        <|"Status" -> "Error", "Reason" -> "EagleHasLibraryOpen"|>,
      True,
        md = SourceVaultEagleLibraryInfo["Library" -> lib];
        If[! AssociationQ[md] || ! ListQ[Lookup[md, "folders", $Failed]],
          Return[<|"Status" -> "Error", "Reason" -> "MetadataUnreadable"|>]];
        With[{r2 = iSVEGMapFolderTree[md["folders"], id,
            Function[n, Join[n, <|"name" -> newName, "modificationTime" -> iSVEGNowMs[]|>]]]},
          If[! r2[[2]], Return[<|"Status" -> "Error", "Reason" -> "FolderNotFound"|>]];
          md["folders"] = r2[[1]]];
        r = iSVEGWriteLibraryMetadata[lib, md];
        If[Lookup[r, "Status", ""] === "Updated",
          <|"Status" -> "Renamed", "Method" -> "File", "Id" -> id, "Name" -> newName|>, r]]];

(* ---- item 追加 (API 専用) ---- *)
Options[SourceVaultEagleAddItem] = {"Library" -> Automatic, "Name" -> Automatic,
  "Tags" -> {}, "Annotation" -> "", "URL" -> "", "Folder" -> Automatic};
SourceVaultEagleAddItem[path_String, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], p = ExpandFileName[path],
      folderId = None, params, r},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    If[! FileExistsQ[p],
      Return[<|"Status" -> "Error", "Reason" -> "FileNotFound", "Path" -> p|>]];
    If[! iSVEGEagleHasLibraryOpen[lib],
      Return[<|"Status" -> "Error", "Reason" -> "EagleNotOpenForAPI",
        "Hint" -> "item 追加はサムネイル生成等を伴うため Eagle API 専用です。Eagle で対象ライブラリを開いてから実行してください。"|>]];
    If[OptionValue["Folder"] =!= Automatic,
      With[{f = SourceVaultEagleFindFolder[ToString[OptionValue["Folder"]], "Library" -> lib]},
        If[AssociationQ[f], folderId = ToString@Lookup[f, "id", ""]]]];
    params = <|"path" -> p,
      "name" -> (OptionValue["Name"] /. Automatic -> FileBaseName[p]),
      "tags" -> (ToString /@ OptionValue["Tags"]),
      "annotation" -> OptionValue["Annotation"],
      "website" -> OptionValue["URL"]|>;
    If[folderId =!= None, params["folderId"] = folderId];
    r = SourceVaultEagleAPICall["/api/item/addFromPath", params];
    If[Lookup[r, "Status", ""] === "OK",
      (SourceVaultEagleRefresh[];
       <|"Status" -> "Added", "Method" -> "API", "Data" -> Lookup[r, "Data", Missing[]]|>),
      r]];

(* ============================================================
   SourceVault ingest 連携
   ============================================================ *)

If[! AssociationQ[$iSVEGIngestMap], $iSVEGIngestMap = <||>];
If[! ValueQ[$iSVEGIngestMapLoaded], $iSVEGIngestMapLoaded = False];

iSVEGIngestMapPath[] := FileNameJoin[{iSVEGStoreRoot[], "ingestmap.jsonl"}];

iSVEGIngestKey[lib_String, id_String] := iSVEGLibStoreKey[lib] <> "::" <> id;

(* record 側の Library 値 ("name:<登録名>" / 旧形式の正規化パス) からキーを再構成。
   旧形式は登録済みなら name キーへ昇格させ、PC 間で照合できるようにする。 *)
iSVEGIngestKeyOfRec[rec_Association] :=
  iSVEGNameKeyForNorm[ToString@Lookup[rec, "Library", ""]] <> "::" <>
  ToString@Lookup[rec, "EagleId", ""];

iSVEGIngestMapLoad[] :=
  Module[{path = iSVEGIngestMapPath[], txt, recs},
    txt = If[FileExistsQ[path],
      Quiet@Check[Import[path, "Text", CharacterEncoding -> "UTF-8"], ""], ""];
    recs = If[! StringQ[txt] || StringTrim[txt] === "", {},
      DeleteCases[(Quiet@Check[ImportString[#, "RawJSON"], $Failed] &) /@
        Select[StringSplit[txt, "\n"], StringTrim[#] =!= "" &], $Failed]];
    $iSVEGIngestMap = Association[
      (iSVEGIngestKeyOfRec[#] -> #) & /@ Select[recs, AssociationQ]];
    $iSVEGIngestMapLoaded = True;
    <|"Status" -> "Loaded", "Count" -> Length[$iSVEGIngestMap]|>];

iSVEGIngestMapEnsure[] := If[! TrueQ[$iSVEGIngestMapLoaded], iSVEGIngestMapLoad[]];

iSVEGIngestMapAppend[rec_Association] :=
  Module[{path = iSVEGIngestMapPath[], line},
    iSVEGEnsureDir[DirectoryName[path]];
    line = Quiet@Check[ExportString[rec, "RawJSON", "Compact" -> True], $Failed];
    If[StringQ[line],
      Module[{strm = Quiet@Check[OpenAppend[path, BinaryFormat -> True], $Failed]},
        If[strm =!= $Failed,
          BinaryWrite[strm, StringToByteArray[line <> "\n", "UTF-8"]];
          Close[strm]]]];
    AssociateTo[$iSVEGIngestMap, iSVEGIngestKeyOfRec[rec] -> rec]];

(* RawJSON 化できない Missing 値を除いてから jsonl へ *)
iSVEGDropMissing[a_Association] := Select[a, ! MissingQ[#] &];

Options[SourceVaultEagleIngest] = {"Library" -> Automatic, "Topic" -> Automatic,
  "PrivacyLabel" -> Automatic, "Copy" -> False};
SourceVaultEagleIngest[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], item, id, path, hash, existing,
      ingOpts, res, rec},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed, Return[<|"Status" -> "Error", "Reason" -> "ItemNotFound"|>]];
    id = iSVEGItemId[item];
    If[! iSVEGOnlineQ[lib], Return[Append[iSVEGOffline[], "Id" -> id]]];
    path = SourceVaultEagleItemPath[item, "Library" -> lib];
    If[! StringQ[path] || ! FileExistsQ[path],
      Return[<|"Status" -> "Error", "Reason" -> "FileNotFound", "Id" -> id|>]];
    iSVEGIngestMapEnsure[];
    If[! TrueQ[OptionValue["Copy"]],
      (* 参照モード (既定): Eagle ライブラリが正本なので原本はコピーしない。
         SHA-256 ハッシュ付き参照記録のみを残す (冪等)。 *)
      hash = Quiet@Check["sha256-" <>
        ToLowerCase@IntegerString[FileHash[path, "SHA256"], 16, 64], Missing["HashFailed"]];
      existing = Lookup[$iSVEGIngestMap, iSVEGIngestKey[lib, id], Missing[]];
      If[AssociationQ[existing] &&
         Lookup[existing, "Mode", ""] === "Reference" &&
         StringQ[hash] && Lookup[existing, "ContentHash", ""] === hash,
        Return[Join[existing, <|"Status" -> "AlreadyCurrent"|>]]];
      rec = iSVEGDropMissing@<|"EagleId" -> id, "Library" -> iSVEGLibStoreKey[lib],
        "Mode" -> "Reference",
        "Name" -> ToString@Lookup[item, "name", ""],
        "Ext" -> ToString@Lookup[item, "ext", ""],
        "Path" -> path,
        "ContentHash" -> hash,
        "IngestStatus" -> "Referenced",
        "At" -> DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z"|>;
      iSVEGIngestMapAppend[rec];
      Return[Join[rec, <|"Status" -> "OK"|>]]];
    (* vault 複製モード ("Copy"->True): SourceVaultIngest で content-addressed store へ *)
    If[Length[DownValues[SourceVault`SourceVaultIngest]] === 0,
      Return[<|"Status" -> "Error", "Reason" -> "SourceVaultNotLoaded",
        "Hint" -> "SourceVault.wl を先にロードしてください。"|>]];
    ingOpts = Join[
      {Topic -> (OptionValue["Topic"] /. Automatic -> "eagle"),
       TrustLevel -> "LocalFile"},
      If[NumericQ[OptionValue["PrivacyLabel"]],
        {PrivacyLabel -> OptionValue["PrivacyLabel"]}, {}]];
    res = Quiet@Check[SourceVault`SourceVaultIngest[path, Sequence @@ ingOpts], $Failed];
    If[! AssociationQ[res],
      Return[<|"Status" -> "Error", "Reason" -> "IngestFailed", "Id" -> id|>]];
    rec = iSVEGDropMissing@<|"EagleId" -> id, "Library" -> iSVEGLibStoreKey[lib],
      "Mode" -> "Vault",
      "Name" -> ToString@Lookup[item, "name", ""], "Ext" -> ToString@Lookup[item, "ext", ""],
      "Path" -> path,
      "SourceId" -> Lookup[res, "SourceId", Missing[]],
      "SnapshotId" -> Lookup[res, "SnapshotId", Missing[]],
      "ContentHash" -> Lookup[res, "ContentHash", Missing[]],
      "IngestStatus" -> Lookup[res, "Status", Missing[]],
      "At" -> DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z"|>;
    iSVEGIngestMapAppend[rec];
    Join[rec, <|"Status" -> "OK"|>]];

Options[SourceVaultEagleIngestInfo] = {"Library" -> Automatic};
SourceVaultEagleIngestInfo[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], id},
    If[lib === $Failed, Return[Missing["NoLibrary"]]];
    id = If[AssociationQ[itemSpec], iSVEGItemId[itemSpec], ToString[itemSpec]];
    iSVEGIngestMapEnsure[];
    Lookup[$iSVEGIngestMap, iSVEGIngestKey[lib, id], Missing["NotIngested"]]];

Options[SourceVaultEagleIngestFolder] = Join[
  Options[SourceVaultEagleIngest], {"Recursive" -> True, "Limit" -> Automatic}];
SourceVaultEagleIngestFolder[folderSpec_, opts : OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], items, lim, ok = 0, failed = 0},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    items = SourceVaultEagleItemsInFolder[folderSpec, "Library" -> lib,
      "Recursive" -> OptionValue["Recursive"]];
    lim = OptionValue["Limit"];
    If[IntegerQ[lim] && lim >= 0, items = Take[items, UpTo[lim]]];
    Scan[
      Function[it,
        With[{r = SourceVaultEagleIngest[it, "Library" -> lib,
            "Copy" -> OptionValue["Copy"],
            "Topic" -> OptionValue["Topic"], "PrivacyLabel" -> OptionValue["PrivacyLabel"]]},
          If[MemberQ[{"OK", "AlreadyCurrent"}, Lookup[r, "Status", ""]], ok++, failed++]]],
      items];
    <|"Status" -> "Done", "Selected" -> Length[items], "Ingested" -> ok, "Failed" -> failed|>];

(* ============================================================
   本文テキスト抽出
   ============================================================ *)

iSVEGItemKind[ext_String] :=
  With[{e = ToLowerCase[ext]},
    Which[
      e === "pdf", "PDF",
      MemberQ[{"doc", "docx"}, e], "Word",
      MemberQ[{"ppt", "pptx"}, e], "PowerPoint",
      MemberQ[{"xls", "xlsx", "csv"}, e], "Sheet",
      MemberQ[{"txt", "md", "htm", "html", "json", "tex", "wl", "m", "nb", "py", "r"}, e], "Text",
      MemberQ[{"jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif", "tif", "tiff"}, e], "Image",
      MemberQ[{"mp4", "mov", "avi", "mkv", "webm", "m4v", "wmv"}, e], "Video",
      MemberQ[{"mp3", "wav", "m4a", "flac", "ogg"}, e], "Audio",
      True, "Other"]];

iSVEGTruncate[s_String, maxChars_Integer] :=
  If[StringLength[s] > maxChars, StringTake[s, maxChars] <> "\n...(以下省略)", s];
iSVEGTruncate[s_, _] := s;

(* zip (docx/pptx) からエントリのテキストを取り出す *)
iSVEGZipEntryStrings[zipPath_String, patt_] :=
  Module[{tmp, files, out},
    tmp = FileNameJoin[{$TemporaryDirectory,
      "sv_eagle_zip_" <> IntegerString[$ProcessID] <> "_" <>
      IntegerString[RandomInteger[{0, 999999999}]]}];
    Quiet@CreateDirectory[tmp];
    files = Quiet@Check[ExtractArchive[zipPath, tmp, patt], {}];
    out = (Quiet@Check[Import[#, "Text", CharacterEncoding -> "UTF-8"], ""] &) /@
      Select[Flatten[{files}], StringQ];
    Quiet@DeleteDirectory[tmp, DeleteContents -> True];
    Select[out, StringQ]];

iSVEGXMLEntities[s_String] := StringReplace[s,
  {"&amp;" -> "&", "&lt;" -> "<", "&gt;" -> ">", "&quot;" -> "\"", "&apos;" -> "'"}];

(* 開始タグは "<w:t>" または "<w:t ...>" のみ ("<w:tbl>" 等の前方一致を排除) *)
iSVEGStripXMLTag[xml_String, tag_String] :=
  iSVEGXMLEntities@StringRiffle[
    StringCases[xml,
      (("<" <> tag <> ">") |
       ("<" <> tag ~~ WhitespaceCharacter ~~ Shortest[___] ~~ ">")) ~~
        t : Shortest[___] ~~ ("</" <> tag <> ">") :> t],
    " "];

iSVEGDocxText[path_String] :=
  Module[{t = Quiet@Check[Import[path, "Plaintext"], $Failed]},
    If[StringQ[t] && StringTrim[t] =!= "", Return[t]];
    StringRiffle[
      iSVEGStripXMLTag[#, "w:t"] & /@ iSVEGZipEntryStrings[path, "word/document.xml"],
      "\n"]];

iSVEGPptxText[path_String] :=
  StringRiffle[
    iSVEGStripXMLTag[#, "a:t"] & /@
      iSVEGZipEntryStrings[path, "ppt/slides/" ~~ __ ~~ ".xml"],
    "\n\n"];

iSVEGSheetText[path_String] :=
  Module[{ds},
    ds = Quiet@Check[Import[path, {"Dataset"}], $Failed];
    If[ListQ[ds] && ds =!= {}, ds = First[ds]];   (* XLSX はシートのリストを外す *)
    If[ds === $Failed || ds === {}, Return[""]];
    Quiet@Check[ToString[Normal[Take[ds, UpTo[200]]], InputForm], ""]];

iSVEGPdfPageCount[path_String, maxPages_Integer] :=
  With[{pc = Quiet@Check[Import[path, "PageCount"], $Failed]},
    If[IntegerQ[pc] && pc > 0, Min[pc, maxPages], maxPages]];

(* ページテキストのローカルキャッシュ (原本はコピーしない)。
   item の mtime/size に紐付け、変わっていたら破棄して再抽出する。 *)
iSVEGPagesDir[id_String] := FileNameJoin[{iSVEGStoreRoot[], "pages", id}];

iSVEGPagesEnsureFresh[id_String, item_Association] :=
  Module[{dir = iSVEGPagesDir[id], metaPath, meta, want},
    metaPath = FileNameJoin[{dir, "meta.json"}];
    want = <|"MTime" -> Lookup[item, "mtime", 0], "Size" -> Lookup[item, "size", 0]|>;
    meta = iSVEGImportJSON[metaPath];
    If[! AssociationQ[meta] ||
       Lookup[meta, "MTime", -1] =!= want["MTime"] ||
       Lookup[meta, "Size", -1] =!= want["Size"],
      Quiet@DeleteDirectory[dir, DeleteContents -> True];
      iSVEGEnsureDir[dir];
      iSVEGAtomicExportJSON[metaPath, want]];
    dir];

(* $SourceVaultOCRHook を原本パスで直接呼ぶ (SourceVault の raw コピー不要)。
   hook は <|"RawPath", "Page", "SnapshotId"|> -> text。 *)
iSVEGOCRHookCall[path_String, page_Integer, id_String] :=
  Module[{hook, t},
    hook = If[ValueQ[SourceVault`$SourceVaultOCRHook],
      SourceVault`$SourceVaultOCRHook, None];
    If[hook === None || hook === Null, Return[""]];
    t = Quiet@Check[
      hook[<|"RawPath" -> path, "Page" -> page, "SnapshotId" -> "eagle:" <> id|>], ""];
    If[StringQ[t] && ! StringStartsQ[t, "Error"], t, ""]];

(* PDF テキスト (コピーなし経路): 原本から Import[{"Plaintext", page}] で直接抽出し、
   PrivateVault/eagle/pages/<id>/ にキャッシュ。テキスト層が短いページ (< 5 文字、
   SourceVaultExtractPages と同じ閾値) と $SourceVaultOCRMode === "Force" は OCR hook。 *)
iSVEGPdfTextLocal[item_Association, path_String, maxPages_Integer] :=
  Module[{id = iSVEGItemId[item], dir, np, mode, texts},
    dir = iSVEGPagesEnsureFresh[id, item];
    np = iSVEGPdfPageCount[path, maxPages];
    mode = If[ValueQ[SourceVault`$SourceVaultOCRMode],
      SourceVault`$SourceVaultOCRMode, "Auto"];
    texts = Table[
      Module[{pf = FileNameJoin[{dir, IntegerString[p, 10, 4] <> ".txt"}], raw},
        If[FileExistsQ[pf],
          Quiet@Check[Import[pf, "Text", CharacterEncoding -> "UTF-8"], ""],
          (raw = Quiet@Check[Import[path, {"Plaintext", p}], ""];
           If[! StringQ[raw], raw = ""];
           If[mode === "Force" || StringLength[StringTrim[raw]] < 5,
             With[{ocr = iSVEGOCRHookCall[path, p, id]},
               If[StringTrim[ocr] =!= "", raw = ocr]]];
           Quiet@Check[Export[pf, raw, "Text", CharacterEncoding -> "UTF-8"], Null];
           raw)]],
      {p, np}];
    StringRiffle[Select[texts, StringQ[#] && StringTrim[#] =!= "" &], "\n\n"]];

(* PDF: vault 複製済み (Mode "Vault"、SourceId あり) なら SourceVaultExtractPages
   (キャッシュ/OCR は SourceVault 側)。それ以外は原本から直接 (コピーなし)。 *)
iSVEGPdfText[lib_, item_, path_String, maxPages_Integer] :=
  Module[{ing, ex, texts, joined},
    ing = SourceVaultEagleIngestInfo[item, "Library" -> lib];
    If[AssociationQ[ing] && StringQ[Lookup[ing, "SourceId", Missing[]]] &&
       Length[DownValues[SourceVault`SourceVaultExtractPages]] > 0,
      ex = Quiet@Check[SourceVault`SourceVaultExtractPages[ing["SourceId"],
        Range[iSVEGPdfPageCount[path, maxPages]]], $Failed];
      If[AssociationQ[ex] && AssociationQ[Lookup[ex, "Pages", $Failed]],
        texts = Values[ex["Pages"]];
        If[AnyTrue[texts, StringQ[#] && StringTrim[#] =!= "" &],
          Return[StringRiffle[Select[texts, StringQ], "\n\n"]]]]];
    joined = iSVEGPdfTextLocal[item, path, maxPages];
    If[StringTrim[joined] =!= "", joined,
      Quiet@Check[Import[path, "Plaintext"], ""]]];

Options[SourceVaultEagleExtractText] = {"Library" -> Automatic,
  "MaxPages" -> 15, "MaxChars" -> 8000};
SourceVaultEagleExtractText[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], item, path, kind, text,
      maxChars = OptionValue["MaxChars"]},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed, Return[<|"Status" -> "Error", "Reason" -> "ItemNotFound"|>]];
    If[! iSVEGOnlineQ[lib], Return[iSVEGOffline[]]];
    path = SourceVaultEagleItemPath[item, "Library" -> lib];
    If[! StringQ[path] || ! FileExistsQ[path],
      Return[<|"Status" -> "Error", "Reason" -> "FileNotFound"|>]];
    kind = iSVEGItemKind[ToString@Lookup[item, "ext", ""]];
    text = Switch[kind,
      "PDF", iSVEGPdfText[lib, item, path, OptionValue["MaxPages"]],
      "Word", iSVEGDocxText[path],
      "PowerPoint", iSVEGPptxText[path],
      "Sheet", iSVEGSheetText[path],
      "Text", Quiet@Check[Import[path, "Plaintext"], ""],
      "Image" | "Video" | "Audio",
        Return[<|"Status" -> "Error", "Reason" -> "NeedsVision", "Kind" -> kind,
          "Hint" -> "画像/動画/音声は SourceVaultEagleSummarize が vision 経由で扱います。"|>],
      _, Quiet@Check[Import[path, "Plaintext"], ""]];
    If[! StringQ[text] || StringTrim[text] === "",
      Return[<|"Status" -> "Error", "Reason" -> "NoTextExtracted", "Kind" -> kind|>]];
    <|"Status" -> "OK", "Kind" -> kind, "Chars" -> StringLength[text],
      "Text" -> iSVEGTruncate[text, maxChars]|>];

(* ============================================================
   LLM (要約)。既定はローカル LM Studio (fail-safe)。
   ============================================================ *)

iSVEGLocalLLMKey[url_String] :=
  Module[{k},
    k = Quiet@Check[
      If[Length[Names["NBAccess`NBGetLocalLLMAPIKey"]] > 0,
        NBAccess`NBGetLocalLLMAPIKey["lmstudio", url,
          NBAccess`PrivacySpec -> <|"AccessLevel" -> 1.0|>], $Failed], $Failed];
    If[StringQ[k] && k =!= "", k, "lm-studio"]];

iSVEGResolveLocalLLM[] :=
  Module[{model = "", url = "http://127.0.0.1:1234/v1/chat/completions", pm},
    pm = Quiet@Check[ClaudeCode`$ClaudePrivateModel, $Failed];
    If[ListQ[pm] && Length[pm] >= 2 && StringQ[pm[[2]]], model = pm[[2]]];
    If[ListQ[pm] && Length[pm] >= 3 && StringQ[pm[[3]]],
      url = With[{u = pm[[3]]},
        Which[StringEndsQ[u, "/v1/chat/completions"], u,
          StringEndsQ[u, "/"], u <> "v1/chat/completions",
          True, u <> "/v1/chat/completions"]]];
    If[model === "",
      Module[{base = StringReplace[url, "/v1/chat/completions" -> "/v1/models"], r, j},
        r = Quiet@Check[URLRead[HTTPRequest[base], TimeConstraint -> 10], $Failed];
        If[MatchQ[r, _HTTPResponse] && r["StatusCode"] === 200,
          j = iSVEGParseJSONBytes[Quiet@Check[r["BodyByteArray"], $Failed]];
          If[AssociationQ[j] && ListQ[Lookup[j, "data", $Failed]] && Length[j["data"]] > 0,
            model = Quiet@Check[j["data"][[1]]["id"], ""];
            If[! StringQ[model], model = ""]]]]];
    <|"URL" -> url, "Model" -> model|>];

(* OpenAI 互換 chat.completions (テキスト/vision 共通)。messages は最終形を受け取る。 *)
iSVEGQueryLocalLLMMessages[messages_List, timeout_] :=
  Module[{llm = iSVEGResolveLocalLLM[], reqData, bodyBytes, resp, json, content},
    reqData = <|"messages" -> messages, "temperature" -> 0.2, "stream" -> False,
      "chat_template_kwargs" -> <|"enable_thinking" -> False|>|> ~Join~
      If[llm["Model"] =!= "", <|"model" -> llm["Model"]|>, <||>];
    bodyBytes = iSVEGJSONBytes[reqData];
    If[bodyBytes === $Failed, Return[""]];
    resp = Quiet@Check[URLRead[HTTPRequest[llm["URL"], <|
        "Method" -> "POST",
        "Headers" -> {"Content-Type" -> "application/json; charset=utf-8",
          "Authorization" -> "Bearer " <> iSVEGLocalLLMKey[llm["URL"]]},
        "Body" -> bodyBytes|>], TimeConstraint -> timeout], $Failed];
    If[! MatchQ[resp, _HTTPResponse] || resp["StatusCode"] =!= 200, Return[""]];
    json = iSVEGParseJSONBytes[Quiet@Check[resp["BodyByteArray"], $Failed]];
    If[! AssociationQ[json], Return[""]];
    content = Quiet@Check[json["choices"][[1]]["message"]["content"], ""];
    If[! (StringQ[content] && StringTrim[content] =!= ""),
      content = Quiet@Check[json["choices"][[1]]["message"]["reasoning_content"], ""]];
    If[StringQ[content], content, ""]];

iSVEGQueryLocalLLMText[prompt_String, timeout_] :=
  iSVEGQueryLocalLLMMessages[{<|"role" -> "user", "content" -> prompt|>}, timeout];

iSVEGB64PNG[img_?ImageQ] :=
  Quiet@Check[
    BaseEncode[ExportByteArray[ImageResize[img, {UpTo[1024], UpTo[1024]}], "PNG"]],
    $Failed];

iSVEGQueryLocalLLMVision[prompt_String, imgs_List, timeout_] :=
  Module[{parts, b64s},
    b64s = Select[iSVEGB64PNG /@ Select[imgs, ImageQ], StringQ];
    If[b64s === {}, Return[""]];
    parts = Join[{<|"type" -> "text", "text" -> prompt|>},
      (<|"type" -> "image_url",
         "image_url" -> <|"url" -> "data:image/png;base64," <> #|>|> &) /@ b64s];
    iSVEGQueryLocalLLMMessages[{<|"role" -> "user", "content" -> parts|>}, timeout]];

(* ---- クラウド経路 ($ClaudeModel の provider に従う) ----
   ユーザーポリシー: claudecode / codex が指定されていれば必ず CLI
   (サブスクリプション内、課金 API なし) を使う。
   課金 API へ行くのは $ClaudeModel = {"anthropic"|"openai", ...} 明示時のみ。
   注意: ClaudeQueryBg のオプション symbol (Model/Timeout/NonBlocking) は
   ClaudeCode`Private` 文脈にあるため、外部パッケージからは文字列名で渡す
   (symbol で渡すと無言で無視される)。 *)

iSVEGClaudeProvider[] :=
  With[{m = If[ValueQ[ClaudeCode`$ClaudeModel], ClaudeCode`$ClaudeModel, Missing[]]},
    If[ListQ[m] && Length[m] >= 1 && StringQ[m[[1]]],
      ToLowerCase[StringTrim[m[[1]]]],
      (* 未設定 / 文字列 ("claude-opus-4-8" 等) は Claude Code CLI 既定 *)
      "claudecode"]];

iSVEGCodexQ[p_String] :=
  MemberQ[{"chatgptcodex", "chatgpt-codex", "codex", "gptcodex"},
    ToLowerCase[StringTrim[p]]];
iSVEGCodexQ[_] := False;

(* Codex CLI (ClaudeEval と同じ runner) でテキストプロンプトを実行。課金 API なし。 *)
iSVEGQueryCodex[prompt_String] :=
  Module[{raw, dec},
    If[Length[DownValues[ClaudeCode`Private`iRunChatgptCodexCLI]] === 0,
      Return["Error: Codex CLI runner (iRunChatgptCodexCLI) not available"]];
    raw = Quiet@Check[ClaudeCode`Private`iRunChatgptCodexCLI[prompt], $Failed];
    dec = Quiet@Check[ClaudeCode`Private`iDecodeProviderResult[raw], $Failed];
    Which[
      AssociationQ[dec] && StringQ[Lookup[dec, "Response", Missing[]]] &&
        StringTrim[dec["Response"]] =!= "",
        StringTrim[dec["Response"]],
      StringQ[raw] && StringTrim[raw] =!= "", StringTrim[raw],
      True, "Error: Codex CLI returned no response"]];

iSVEGQueryClaude[parts_List, timeout_] :=
  Module[{prov, r},
    If[Length[Names["ClaudeCode`ClaudeQueryBg"]] === 0,
      Return["Error: ClaudeQueryBg not available (claudecode.wl をロードしてください)"]];
    prov = iSVEGClaudeProvider[];
    If[iSVEGCodexQ[prov] && AllTrue[parts, StringQ],
      (* Codex 指定 + テキスト: 必ず Codex CLI *)
      Return[iSVEGQueryCodex[StringRiffle[parts, "\n"]]]];
    r = Quiet[Block[{ClaudeCode`$iMediaMaxImageSize = 1568},
      If[iSVEGCodexQ[prov],
        (* Codex 指定 + 画像/動画: Codex CLI に画像配線が無いため
           Claude Code CLI (課金なし) で実行する。課金 API には送らない。 *)
        ClaudeCode`ClaudeQueryBg[If[Length[parts] === 1, First[parts], parts],
          "NonBlocking" -> True, "Timeout" -> timeout,
          "Model" -> {"claudecode", ""}],
        (* claudecode / 未設定 / 文字列: ClaudeQueryBg が CLI へルーティング。
           anthropic / openai 明示時のみ API。 *)
        ClaudeCode`ClaudeQueryBg[If[Length[parts] === 1, First[parts], parts],
          "NonBlocking" -> True, "Timeout" -> timeout]]]];
    If[StringQ[r], StringTrim[r], "Error: API returned non-string"]];

(* ============================================================
   サマリー生成・保存
   ============================================================ *)

iSVEGSummaryPath[id_String] :=
  FileNameJoin[{iSVEGStoreRoot[], "summaries", id <> ".json"}];

(* ---- サマリーのメモリキャッシュ ----
   検索 (サマリー本文マッチ) や IndexRecord で item ごとにファイルを
   読まないための一括キャッシュ。ファイル数が変わったら再構築し、
   この package 内の書込は iSVEGSummaryCachePut で同期する。 *)
If[! ValueQ[$iSVEGSummaryCache], $iSVEGSummaryCache = None]; (* {count, <|id->rec|>} *)

iSVEGSummaryDir[] := FileNameJoin[{iSVEGStoreRoot[], "summaries"}];

iSVEGSummaryCacheEnsure[] :=
  Module[{dir = iSVEGSummaryDir[], files},
    files = If[Quiet@Check[DirectoryQ[dir], False], FileNames["*.json", dir], {}];
    If[ListQ[$iSVEGSummaryCache] && $iSVEGSummaryCache[[1]] === Length[files],
      Return[$iSVEGSummaryCache[[2]]]];
    $iSVEGSummaryCache = {Length[files], Association[
      Function[f, With[{r = iSVEGImportJSON[f]},
        If[AssociationQ[r], FileBaseName[f] -> r, Nothing]]] /@ files]};
    $iSVEGSummaryCache[[2]]];

iSVEGSummaryCachePut[id_String, rec_Association] :=
  If[ListQ[$iSVEGSummaryCache],
    $iSVEGSummaryCache = {
      $iSVEGSummaryCache[[1]] +
        If[KeyExistsQ[$iSVEGSummaryCache[[2]], id], 0, 1],
      Append[$iSVEGSummaryCache[[2]], id -> rec]}];

iSVEGSummaryRecord[id_String] :=
  Lookup[iSVEGSummaryCacheEnsure[], id, Missing["NoSummary"]];

(* Cloud-Publishable タグ: 付いていれば "Method"->Automatic の要約をクラウド
   (ClaudeQueryBg / $ClaudeModel) へ切り替えてよい、というユーザーの明示宣言。 *)
If[! ValueQ[$SourceVaultEagleCloudPublishableTag],
  $SourceVaultEagleCloudPublishableTag = "Cloud-Publishable"];

iSVEGCloudPublishableQ[item_Association] :=
  With[{tag = ToLowerCase@ToString[$SourceVaultEagleCloudPublishableTag]},
    AnyTrue[ToString /@ Lookup[item, "tags", {}], ToLowerCase[#] === tag &]];
iSVEGCloudPublishableQ[_] := False;

iSVEGSummaryCurrentQ[rec_Association, item_Association] :=
  Lookup[rec, "BasedOnMTime", -1] === Lookup[item, "mtime", -2] &&
  Lookup[rec, "BasedOnSize", -1] === Lookup[item, "size", -2];

Options[SourceVaultEagleSummary] = {"Library" -> Automatic};
SourceVaultEagleSummary[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], id, rec, item},
    id = If[AssociationQ[itemSpec], iSVEGItemId[itemSpec], ToString[itemSpec]];
    rec = iSVEGSummaryRecord[id];
    If[! AssociationQ[rec], Return[Missing["NoSummary", id]]];
    item = If[lib === $Failed, $Failed, iSVEGItemOf[lib, itemSpec]];
    Append[rec, "SummaryStatus" ->
      If[AssociationQ[item],
        If[iSVEGSummaryCurrentQ[rec, item], "Current", "Stale"], "Unknown"]]];

iSVEGLangInstruction[lang_] :=
  Switch[lang,
    "English", "Write the summary in English.",
    "Japanese", "要約は日本語で書く。",
    _, If[$Language === "Japanese", "要約は日本語で書く。", "Write the summary in English."]];

iSVEGItemContextLine[item_Association] :=
  "ファイル名: " <> ToString@Lookup[item, "name", ""] <> "." <>
  ToString@Lookup[item, "ext", ""] <>
  With[{tags = ToString /@ Lookup[item, "tags", {}]},
    If[tags === {}, "", " / タグ: " <> StringRiffle[tags, ", "]]] <>
  With[{ann = ToString@Lookup[item, "annotation", ""]},
    If[StringTrim[ann] === "", "", " / 既存メモ: " <> iSVEGTruncate[ann, 200]]];

(* 書誌情報 (タイトル/著者/発行日) を要約と同じ 1 回の LLM 呼び出しで抽出する
   ための定型末尾 3 行。iSVEGParseBibTail が応答から分離する。 *)
iSVEGBibTailInstruction[] :=
  "要約本文の後に、本文から分かる場合のみ次の 3 行を原文の表記のまま出力する " <>
  "(分からない項目は NONE):\n" <>
  "TITLE: <文書の正式タイトル>\n" <>
  "AUTHORS: <著者名をカンマ区切り>\n" <>
  "DATE: <出版/発行年月 YYYY-MM または YYYY>";

iSVEGTextPrompt[item_, text_, maxLen_, lang_] :=
  "以下の[ファイル内容]を要約せよ。\n" <>
  iSVEGItemContextLine[item] <> "\n" <>
  "出力は要約本文のみ。" <> ToString[maxLen] <> "文字以内の平文。" <>
  "前置き・見出し・箇条書き記号・コードブロックは不要。" <>
  iSVEGLangInstruction[lang] <> "\n" <>
  iSVEGBibTailInstruction[] <> "\n\n[ファイル内容]\n" <> text;

(* LLM 応答から TITLE:/AUTHORS:/DATE: 行を分離する。
   戻り値: {要約本文 (3 行を除去), <|"Title"->_, "Authors"->_, "Published"->_|>}
   (不明値 NONE/N/A/不明 は "" に正規化。行が無ければ <||> 側キーも "") *)
iSVEGParseBibTail[raw_String] :=
  Module[{lines, isBib, val, title = "", authors = "", date = "", rest},
    val[line_, key_] := Module[{m},
      m = StringCases[line,
        RegularExpression["(?i)^[\\s*#>-]*" <> key <> "\\s*[:：]\\s*(.*)$"] -> "$1", 1];
      If[m === {}, Missing[],
        With[{v = StringTrim[StringReplace[First[m],
            {RegularExpression["^[\\s*]+"] -> "",
             RegularExpression["[\\s*]+$"] -> ""}]]},
          If[MemberQ[{"none", "n/a", "na", "不明", "unknown", ""},
             ToLowerCase[v]], "", v]]]];
    isBib[line_] :=
      StringMatchQ[line,
        RegularExpression["(?i)^[\\s*#>-]*(TITLE|AUTHORS?|DATE)\\s*[:：].*"]];
    lines = StringSplit[raw, "\n"];
    Scan[Function[line,
       Module[{v},
         v = val[line, "TITLE"];
         If[StringQ[v] && title === "", title = v];
         v = val[line, "AUTHORS?"];
         If[StringQ[v] && authors === "", authors = v];
         v = val[line, "DATE"];
         If[StringQ[v] && date === "", date = v]]],
      lines];
    rest = StringRiffle[Select[lines, ! isBib[#] &], "\n"];
    {StringTrim[rest],
     <|"Title" -> title, "Authors" -> authors, "Published" -> date|>}];
iSVEGParseBibTail[raw_] := {ToString[raw], <|"Title" -> "", "Authors" -> "", "Published" -> ""|>};

(* PDF 埋め込みメタデータ (Info 辞書) からのフォールバック。junk は捨てる。 *)
iSVEGBibFromPDFInfo[path_String] :=
  Module[{mi, t, a, d},
    mi = Quiet@Check[
      TimeConstrained[Import[path, "MetaInformation"], 15, $Failed], $Failed];
    Which[
      AssociationQ[mi], Null,
      MatchQ[mi, {__Rule}], mi = Association[mi],
      True, Return[<||>]];
    t = StringTrim@ToString@(Lookup[mi, "Title", ""] /. _Missing | None | Null -> "");
    a = StringTrim@ToString@(Lookup[mi, "Author", ""] /. _Missing | None | Null -> "");
    d = Lookup[mi, "CreationDate", ""];
    d = Which[
      Head[d] === DateObject, DateString[d, {"Year", "-", "Month"}],
      StringQ[d] && StringLength[d] >= 4, StringTake[d, UpTo[7]],
      True, ""];
    If[StringLength[t] < 4 ||
       StringContainsQ[ToLowerCase[t], "untitled"] ||
       StringStartsQ[t, "Microsoft "] || StringStartsQ[t, "arXiv:"],
      t = ""];
    DeleteCases[<|"Title" -> t, "Authors" -> a, "Published" -> d|>, ""]];
iSVEGBibFromPDFInfo[___] := <||>;

(* 書誌 assoc の空でないキーだけを record に合流させる *)
iSVEGBibMergeIntoRec[rec_Association, bib_Association] :=
  Join[rec, DeleteCases[KeyTake[bib, {"Title", "Authors", "Published"}], ""]];

iSVEGImagePrompt[item_, maxLen_, lang_] :=
  "この画像の内容を説明せよ。写っている対象・場面・読み取れる文字情報 (あれば) を含める。\n" <>
  iSVEGItemContextLine[item] <> "\n" <>
  "出力は説明本文のみ。" <> ToString[maxLen] <> "文字以内の平文。" <>
  iSVEGLangInstruction[lang];

iSVEGVideoPrompt[item_, nFrames_, duration_, maxLen_, lang_] :=
  "以下は1本の動画から等間隔に抽出した " <> ToString[nFrames] <> " 枚のフレームである。" <>
  If[NumericQ[duration], "動画の長さは約 " <> ToString[Round[duration]] <> " 秒。", ""] <>
  "動画全体の内容を推定して説明せよ。\n" <>
  iSVEGItemContextLine[item] <> "\n" <>
  "出力は説明本文のみ。" <> ToString[maxLen] <> "文字以内の平文。" <>
  iSVEGLangInstruction[lang];

iSVEGVisionImages[lib_, item_, path_String] :=
  Module[{tp, img},
    (* Eagle のサムネイルがあれば優先 (HEIC 等で原本 Import 不可でも動く) *)
    tp = SourceVaultEagleThumbnailPath[item, "Library" -> lib];
    img = If[StringQ[tp], Quiet@Check[Import[tp], $Failed], $Failed];
    If[! ImageQ[img], img = Quiet@Check[Import[path], $Failed]];
    If[ImageQ[img], {img}, {}]];

iSVEGVideoFrames[path_String, n_Integer] :=
  Module[{v, frames},
    v = Quiet@Check[Video[path], $Failed];
    If[Head[v] =!= Video, Return[{}]];
    frames = Quiet@Check[VideoFrameList[v, n], {}];
    Select[Flatten[{frames}], ImageQ]];

Options[SourceVaultEagleSummarize] = {
  "Library" -> Automatic, "Method" -> Automatic,
  "MaxLength" -> 400, "MaxChars" -> 8000, "MaxPages" -> 15, "Frames" -> 3,
  "Language" -> Automatic, "Timeout" -> 240,
  "ForceRefresh" -> False, "Ingest" -> True, "Copy" -> False,
  "WriteAnnotation" -> False, "Persist" -> True};

SourceVaultEagleSummarize[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], item, id, path, kind, existing,
      method, cloudByTag = False,
      maxLen = OptionValue["MaxLength"], lang = OptionValue["Language"],
      timeout = OptionValue["Timeout"], txtR, prompt, raw = "", usedModel = Missing[],
      imgs, duration, rec, summaryText, bib = <||>},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed, Return[<|"Status" -> "Error", "Reason" -> "ItemNotFound"|>]];
    id = iSVEGItemId[item];
    (* 保存済みサマリーはローカル store にあるので、オフラインでも返せるよう
       原本アクセスより先に判定する *)
    existing = SourceVaultEagleSummary[item, "Library" -> lib];
    If[AssociationQ[existing] && ! TrueQ[OptionValue["ForceRefresh"]] &&
       Lookup[existing, "SummaryStatus", ""] === "Current",
      Return[Append[existing, "Status" -> "Current"]]];
    If[! iSVEGOnlineQ[lib], Return[Append[iSVEGOffline[], "Id" -> id]]];
    path = SourceVaultEagleItemPath[item, "Library" -> lib];
    If[! StringQ[path] || ! FileExistsQ[path],
      Return[<|"Status" -> "Error", "Reason" -> "FileNotFound", "Id" -> id|>]];
    kind = iSVEGItemKind[ToString@Lookup[item, "ext", ""]];
    If[kind === "Audio",
      Return[<|"Status" -> "Error", "Reason" -> "AudioNotSupported", "Id" -> id|>]];
    If[TrueQ[OptionValue["Ingest"]],
      (* 既定は参照記録のみ (原本コピーなし)。"Copy"->True で vault 複製。 *)
      Quiet@Check[SourceVaultEagleIngest[item, "Library" -> lib,
        "Copy" -> OptionValue["Copy"]], Null]];
    (* Method 解決: Automatic は item ごとに判定 —
       Cloud-Publishable タグ付きはクラウド (ClaudeQueryBg / $ClaudeModel)、
       それ以外はローカル ($ClaudePrivateModel) の fail-safe。 *)
    method = OptionValue["Method"] /. "LocalLLM" -> "Local";
    cloudByTag = method === Automatic && iSVEGCloudPublishableQ[item];
    method = method /. Automatic -> If[cloudByTag, "Claude", "Local"];
    Which[
      MemberQ[{"PDF", "Word", "PowerPoint", "Sheet", "Text", "Other"}, kind],
        txtR = SourceVaultEagleExtractText[item, "Library" -> lib,
          "MaxPages" -> OptionValue["MaxPages"], "MaxChars" -> OptionValue["MaxChars"]];
        If[Lookup[txtR, "Status", ""] =!= "OK", Return[txtR]];
        prompt = iSVEGTextPrompt[item, txtR["Text"], maxLen, lang];
        raw = Switch[method,
          "Local", (usedModel = iSVEGResolveLocalLLM[]["Model"];
            iSVEGQueryLocalLLMText[prompt, timeout]),
          "Claude", (usedModel = iSVEGClaudeProvider[];
            iSVEGQueryClaude[{prompt}, timeout]),
          _, ""],
      kind === "Image",
        imgs = iSVEGVisionImages[lib, item, path];
        If[imgs === {},
          Return[<|"Status" -> "Error", "Reason" -> "ImageUnreadable", "Id" -> id|>]];
        prompt = iSVEGImagePrompt[item, maxLen, lang];
        raw = Switch[method,
          "Local", (usedModel = iSVEGResolveLocalLLM[]["Model"];
            iSVEGQueryLocalLLMVision[prompt, imgs, timeout]),
          "Claude", (usedModel = iSVEGClaudeProvider[];
            iSVEGQueryClaude[Join[{prompt}, imgs], timeout]),
          _, ""],
      kind === "Video",
        imgs = iSVEGVideoFrames[path, OptionValue["Frames"]];
        If[imgs === {},
          Return[<|"Status" -> "Error", "Reason" -> "VideoFramesUnavailable", "Id" -> id|>]];
        duration = Quiet@Check[QuantityMagnitude[Import[path, "Duration"], "Seconds"],
          Quiet@Check[Import[path, "Duration"], Missing[]]];
        prompt = iSVEGVideoPrompt[item, Length[imgs], duration, maxLen, lang];
        raw = Switch[method,
          "Local", (usedModel = iSVEGResolveLocalLLM[]["Model"];
            iSVEGQueryLocalLLMVision[prompt, imgs, timeout]),
          "Claude", (usedModel = iSVEGClaudeProvider[];
            iSVEGQueryClaude[Join[{prompt}, imgs], timeout]),
          _, ""]];
    Which[
      StringQ[raw] && StringStartsQ[raw, "Error:"],
        Return[<|"Status" -> "Error", "Reason" -> raw, "Id" -> id|>],
      ! StringQ[raw] || StringTrim[raw] === "",
        Return[<|"Status" -> "Error", "Reason" -> "LLMUnavailableOrEmpty", "Id" -> id,
          "Hint" -> If[method === "Local",
            "ローカル LLM (LM Studio) が応答しません。起動を確認するか \"Method\"->\"Claude\" (クラウド送信に注意) を指定してください。",
            "Claude 経由の要約に失敗しました。"]|>]];
    (* 書誌情報: 文書系は LLM 応答末尾の TITLE/AUTHORS/DATE 行を分離。
       PDF で LLM がタイトルを返さなかった場合は埋め込みメタデータで補完。 *)
    If[MemberQ[{"PDF", "Word", "PowerPoint", "Sheet", "Text", "Other"}, kind],
      {summaryText, bib} = iSVEGParseBibTail[raw];
      If[StringTrim[summaryText] === "", summaryText = StringTrim[raw]];
      If[kind === "PDF" && Lookup[bib, "Title", ""] === "",
        bib = Join[iSVEGBibFromPDFInfo[path], DeleteCases[bib, ""]]],
      summaryText = StringTrim[raw]];
    rec = <|"EagleId" -> id, "Library" -> iSVEGLibStoreKey[lib],
      "Name" -> ToString@Lookup[item, "name", ""],
      "Ext" -> ToString@Lookup[item, "ext", ""], "Kind" -> kind,
      "Summary" -> summaryText, "Method" -> method, "Model" -> usedModel,
      "MaxLength" -> maxLen,
      "BasedOnMTime" -> Lookup[item, "mtime", Missing[]],
      "BasedOnSize" -> Lookup[item, "size", Missing[]],
      "CreatedAt" -> DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z"|>;
    rec = iSVEGBibMergeIntoRec[rec, bib];
    If[cloudByTag,
      (* タグによる明示宣言なので、summary 自体もクラウド可 (PL 0.0) と記録する *)
      rec = Join[rec, <|"CloudByTag" -> True, "PrivacyLevel" -> 0.0|>]];
    If[TrueQ[OptionValue["Persist"]],
      iSVEGEnsureDir[DirectoryName[iSVEGSummaryPath[id]]];
      iSVEGAtomicExportJSON[iSVEGSummaryPath[id], rec];
      iSVEGSummaryCachePut[id, rec]];
    If[TrueQ[OptionValue["WriteAnnotation"]],
      Quiet@Check[
        SourceVaultEagleSetAnnotation[item, summaryText, "Library" -> lib], Null]];
    Append[rec, "Status" -> "OK"]];

(* 検索オプション ("Folder"/"Ext"/"Tags"/"DateFrom" 等) も受け取り Search へ転送する。
   "Limit" は「要約する件数の上限」(検索結果の上位から)。 *)
Options[SourceVaultEagleSummarizeBatch] = DeleteDuplicatesBy[Join[
  Options[SourceVaultEagleSummarize], Options[SourceVaultEagleSearch],
  {"Limit" -> Automatic}], First];
SourceVaultEagleSummarizeBatch[spec_, opts : OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], items, lim,
      done = 0, current = 0, failed = 0, searchOpts, sumOpts},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    searchOpts = DeleteCases[
      FilterRules[Flatten[{opts}], Options[SourceVaultEagleSearch]],
      HoldPattern["Limit" -> _]];
    items = Which[
      StringQ[spec],
        SourceVaultEagleSearch[spec, Sequence @@ searchOpts, "Library" -> lib],
      ListQ[spec], spec,
      True, {}];
    lim = OptionValue["Limit"];
    If[IntegerQ[lim] && lim >= 0, items = Take[items, UpTo[lim]]];
    sumOpts = FilterRules[{opts}, Options[SourceVaultEagleSummarize]];
    Scan[
      Function[it,
        With[{r = SourceVaultEagleSummarize[it, Sequence @@ sumOpts, "Library" -> lib]},
          Switch[Lookup[r, "Status", ""],
            "OK", done++, "Current", current++, _, failed++]]],
      items];
    <|"Status" -> "Done", "Selected" -> Length[items],
      "Generated" -> done, "AlreadyCurrent" -> current, "Failed" -> failed|>];

(* ============================================================
   既存サマリー record への書誌情報の後追い抽出
   (新規要約は SourceVaultEagleSummarize が同時抽出する。こちらは
    旧 record の backfill 用: 本文先頭のみを LLM に渡し
    TITLE/AUTHORS/DATE を抽出して record に追記する)
   ============================================================ *)

iSVEGRecBibMissingQ[rec_] :=
  ! StringQ[Lookup[rec, "Title", Missing[]]] ||
    StringTrim[ToString@Lookup[rec, "Title", ""]] === "";

Options[SourceVaultEagleExtractBibMeta] = {
  "Library" -> Automatic, "Method" -> Automatic,
  "MaxChars" -> 2500, "MaxPages" -> 2, "Timeout" -> 120,
  "ForceRefresh" -> False};

SourceVaultEagleExtractBibMeta[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], item, id, rec, kind, path,
      method, txtR, prompt, raw, bib, timeout = OptionValue["Timeout"]},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed,
      Return[<|"Status" -> "Error", "Reason" -> "ItemNotFound"|>]];
    id = iSVEGItemId[item];
    rec = iSVEGSummaryRecord[id];
    If[! AssociationQ[rec],
      Return[<|"Status" -> "Error", "Reason" -> "NoSummary", "Id" -> id,
        "Hint" -> "summary record がありません。SourceVaultEagleSummarize[id] を実行してください (新規要約は書誌も同時抽出)。"|>]];
    If[! TrueQ[OptionValue["ForceRefresh"]] && ! iSVEGRecBibMissingQ[rec],
      Return[Append[rec, "Status" -> "Current"]]];
    kind = iSVEGItemKind[ToString@Lookup[item, "ext", ""]];
    If[! MemberQ[{"PDF", "Word", "PowerPoint", "Sheet", "Text", "Other"}, kind],
      Return[<|"Status" -> "Error", "Reason" -> "NotDocumentKind",
        "Id" -> id, "Kind" -> kind|>]];
    If[! iSVEGOnlineQ[lib], Return[Append[iSVEGOffline[], "Id" -> id]]];
    path = SourceVaultEagleItemPath[item, "Library" -> lib];
    If[! StringQ[path] || ! FileExistsQ[path],
      Return[<|"Status" -> "Error", "Reason" -> "FileNotFound", "Id" -> id|>]];
    (* 本文先頭のみ抽出 (pages キャッシュがあれば Import なし) *)
    txtR = SourceVaultEagleExtractText[item, "Library" -> lib,
      "MaxPages" -> OptionValue["MaxPages"],
      "MaxChars" -> OptionValue["MaxChars"]];
    If[Lookup[txtR, "Status", ""] =!= "OK", Return[txtR]];
    (* Method 解決は Summarize と同じ fail-safe (タグ無しはローカル LLM) *)
    method = OptionValue["Method"] /. "LocalLLM" -> "Local";
    method = method /. Automatic ->
      If[iSVEGCloudPublishableQ[item], "Claude", "Local"];
    prompt = "以下の[文書先頭]から書誌情報のみを抽出せよ。説明や要約は不要。\n" <>
      iSVEGItemContextLine[item] <> "\n" <>
      "出力は次の 3 行のみ (分からない項目は NONE、原文の表記のまま):\n" <>
      "TITLE: <文書の正式タイトル>\n" <>
      "AUTHORS: <著者名をカンマ区切り>\n" <>
      "DATE: <出版/発行年月 YYYY-MM または YYYY>\n\n[文書先頭]\n" <>
      txtR["Text"];
    raw = Switch[method,
      "Local", iSVEGQueryLocalLLMText[prompt, timeout],
      "Claude", iSVEGQueryClaude[{prompt}, timeout],
      _, ""];
    bib = If[StringQ[raw] && ! StringStartsQ[raw, "Error:"],
      Last[iSVEGParseBibTail[raw]],
      <|"Title" -> "", "Authors" -> "", "Published" -> ""|>];
    If[kind === "PDF" && Lookup[bib, "Title", ""] === "",
      bib = Join[iSVEGBibFromPDFInfo[path], DeleteCases[bib, ""]]];
    If[DeleteCases[KeyTake[bib, {"Title", "Authors", "Published"}], ""] === <||>,
      Return[<|"Status" -> "Error", "Reason" -> "BibNotFound", "Id" -> id|>]];
    rec = iSVEGBibMergeIntoRec[rec, bib];
    If[iSVEGAtomicExportJSON[iSVEGSummaryPath[id], rec] === $Failed,
      <|"Status" -> "Error", "Reason" -> "WriteFailed", "Id" -> id|>,
      (iSVEGSummaryCachePut[id, rec]; Append[rec, "Status" -> "OK"])]];

(* 保存済みサマリー全体への一括 backfill。query は iSVEGSummaryListRows と同じ
   (サマリー本文/ノート/ファイル名の部分一致、"" で全件)。既に Title を持つ
   record はスキップ ("ForceRefresh"->True で再抽出)。 *)
Options[SourceVaultEagleExtractBibMetaBatch] = DeleteDuplicatesBy[Join[
  Options[SourceVaultEagleExtractBibMeta],
  {"Limit" -> Automatic, "Ext" -> Automatic}], First];
SourceVaultEagleExtractBibMetaBatch[query_String : "", opts : OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], rows, exts, lim, bibOpts,
      done = 0, current = 0, failed = 0},
    If[lib === $Failed, Return[iSVEGNoLib[]]];
    rows = iSVEGSummaryListRows[query, lib];
    exts = OptionValue["Ext"];
    If[exts =!= Automatic,
      exts = ToLowerCase /@ (ToString /@ Flatten[{exts}]);
      rows = Select[rows,
        MemberQ[exts,
          ToLowerCase@ToString@Lookup[Lookup[#, "Rec", <||>], "Ext", ""]] &]];
    If[! TrueQ[OptionValue["ForceRefresh"]],
      rows = Select[rows, iSVEGRecBibMissingQ[Lookup[#, "Rec", <||>]] &]];
    lim = OptionValue["Limit"];
    If[IntegerQ[lim] && lim >= 0, rows = Take[rows, UpTo[lim]]];
    bibOpts = FilterRules[Flatten[{opts}],
      Options[SourceVaultEagleExtractBibMeta]];
    Scan[Function[row,
       With[{r = Quiet@Check[
           SourceVaultEagleExtractBibMeta[row["Id"],
             Sequence @@ bibOpts, "Library" -> lib],
           <|"Status" -> "Error"|>]},
         Switch[Lookup[r, "Status", ""],
           "OK", done++, "Current", current++, _, failed++]]],
      rows];
    <|"Status" -> "Done", "Selected" -> Length[rows],
      "Extracted" -> done, "AlreadyCurrent" -> current, "Failed" -> failed|>];

(* ============================================================
   インデックス (Eagle 情報 + Exif) と AND/OR 検索
   - Eagle 情報 (★/解像度/サイズ/追加・作成・変更日/タグ) は item metadata 由来。
   - Exif は原本から抽出して PrivateVault/eagle/exifindex/ に BinarySerialize で
     永続化する (Eagle ライブラリ側は一切変更しない)。
   - 検索条件は統合 record を受ける述語 Function。&& / || がそのまま AND / OR。
   ============================================================ *)

If[! AssociationQ[$iSVEGExifIndex], $iSVEGExifIndex = <||>]; (* lib -> <|id -> rec|> *)
If[! AssociationQ[$iSVEGExifLoaded], $iSVEGExifLoaded = <||>];
If[! ValueQ[$iSVEGExifBatch], $iSVEGExifBatch = False];

(* 索引する Exif キー (サイズ抑制のため絞る)。GPS は iSVEGExifPosition で位置化。 *)
$iSVEGExifKeys = {"Make", "Model", "LensModel", "Software",
  "DateTimeOriginal", "DateTime", "ISOSpeedRatings", "FNumber", "ExposureTime",
  "FocalLength", "FocalLengthIn35mmFilm", "Orientation",
  "PixelXDimension", "PixelYDimension",
  "GPSLatitude", "GPSLatitudeRef", "GPSLongitude", "GPSLongitudeRef", "GPSAltitude"};

iSVEGExifPath[lib_String] :=
  FileNameJoin[{iSVEGStoreRoot[], "exifindex",
    StringTake[IntegerString[Hash[iSVEGLibStoreKey[lib], "SHA256"], 16, 64], 16] <>
    ".svegexif"}];

iSVEGExifEnsureLoaded[lib_String] :=
  Module[{path, blob},
    If[TrueQ[Lookup[$iSVEGExifLoaded, lib, False]], Return[Null]];
    AssociateTo[$iSVEGExifLoaded, lib -> True];
    path = iSVEGExifPath[lib];
    If[! TrueQ[Quiet@Check[FileExistsQ[path], False]], Return[Null]];
    blob = Quiet@Check[BinaryDeserialize[ReadByteArray[path]], $Failed];
    If[AssociationQ[blob] && AssociationQ[Lookup[blob, "Exif", $Failed]],
      AssociateTo[$iSVEGExifIndex, lib -> blob["Exif"]]];
    Null];

iSVEGExifSave[lib_String] :=
  Module[{path = iSVEGExifPath[lib], strm},
    iSVEGEnsureDir[DirectoryName[path]];
    Quiet@Check[
      (strm = OpenWrite[path, BinaryFormat -> True];
       BinaryWrite[strm, BinarySerialize[
         <|"Library" -> iSVEGNormPath[lib],
           "Exif" -> Lookup[$iSVEGExifIndex, lib, <||>],
           "SavedAt" -> DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z"|>]];
       Close[strm];
       <|"Status" -> "Saved", "Count" -> Length[Lookup[$iSVEGExifIndex, lib, <||>]]|>),
      <|"Status" -> "Error", "Reason" -> "WriteFailed", "Path" -> path|>]];

iSVEGExifCurrentQ[rec_Association, item_Association] :=
  Lookup[rec, "BasedOnMTime", -1] === Lookup[item, "mtime", -2] &&
  Lookup[rec, "BasedOnSize", -1] === Lookup[item, "size", -2];

(* 保存済み Exif record (抽出はしない)。無い/stale は Missing。オフラインでも使える。 *)
iSVEGExifStored[lib_String, item_Association] :=
  Module[{rec},
    iSVEGExifEnsureLoaded[lib];
    rec = Lookup[Lookup[$iSVEGExifIndex, lib, <||>], iSVEGItemId[item],
      Missing["NotIndexed"]];
    If[AssociationQ[rec] && iSVEGExifCurrentQ[rec, item], rec, Missing["NotIndexed"]]];

iSVEGExtractExifAssoc[path_String] :=
  Module[{e = Quiet@Check[Import[path, "Exif"], $Failed]},
    Which[
      AssociationQ[e], KeyTake[e, $iSVEGExifKeys],
      MatchQ[e, {__Rule}], KeyTake[Association[e], $iSVEGExifKeys],
      True, $Failed]];

Options[SourceVaultEagleExif] = {"Library" -> Automatic, "Extract" -> True,
  "ForceRefresh" -> False};
SourceVaultEagleExif[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], item, id, stored, path, ex, rec},
    If[! StringQ[lib], Return[Missing["NoLibrary"]]];
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed, Return[Missing["ItemNotFound"]]];
    id = iSVEGItemId[item];
    stored = iSVEGExifStored[lib, item];
    If[AssociationQ[stored] && ! TrueQ[OptionValue["ForceRefresh"]], Return[stored]];
    If[! TrueQ[OptionValue["Extract"]], Return[Missing["NotIndexed"]]];
    If[! iSVEGOnlineQ[lib], Return[Missing["Offline"]]];
    path = SourceVaultEagleItemPath[item, "Library" -> lib];
    If[! StringQ[path] || ! FileExistsQ[path], Return[Missing["FileNotFound"]]];
    ex = If[iSVEGItemKind[ToString@Lookup[item, "ext", ""]] === "Image",
      iSVEGExtractExifAssoc[path], $Failed];
    rec = <|"EagleId" -> id,
      "HasExif" -> (AssociationQ[ex] && Length[ex] > 0),
      "Exif" -> If[AssociationQ[ex], ex, <||>],
      "BasedOnMTime" -> Lookup[item, "mtime", Missing[]],
      "BasedOnSize" -> Lookup[item, "size", Missing[]],
      "At" -> DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z"|>;
    If[! KeyExistsQ[$iSVEGExifIndex, lib], $iSVEGExifIndex[lib] = <||>];
    $iSVEGExifIndex[lib, id] = rec;
    If[! TrueQ[$iSVEGExifBatch], iSVEGExifSave[lib]];
    rec];

Options[SourceVaultEagleBuildExifIndex] = Join[Options[SourceVaultEagleSearch],
  {"ForceRefresh" -> False}];
SourceVaultEagleBuildExifIndex[query_String : "", opts : OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], items, indexed = 0, current = 0,
      noExif = 0, failed = 0, searchOpts},
    If[! StringQ[lib], Return[iSVEGNoLib[]]];
    If[! iSVEGOnlineQ[lib], Return[iSVEGOffline[]]];
    searchOpts = FilterRules[Flatten[{opts}], Options[SourceVaultEagleSearch]];
    items = SourceVaultEagleSearch[query, Sequence @@ searchOpts, "Library" -> lib];
    items = Select[items, iSVEGItemKind[ToString@Lookup[#, "ext", ""]] === "Image" &];
    Block[{$iSVEGExifBatch = True},
      Scan[
        Function[it,
          Module[{stored = iSVEGExifStored[lib, it], r},
            If[AssociationQ[stored] && ! TrueQ[OptionValue["ForceRefresh"]],
              current++,
              r = SourceVaultEagleExif[it, "Library" -> lib,
                "ForceRefresh" -> OptionValue["ForceRefresh"]];
              Which[
                ! AssociationQ[r], failed++,
                TrueQ[r["HasExif"]], indexed++,
                True, noExif++]]]],
        items]];
    iSVEGExifSave[lib];
    <|"Status" -> "Done", "Selected" -> Length[items], "Indexed" -> indexed,
      "AlreadyCurrent" -> current, "NoExif" -> noExif, "Failed" -> failed|>];

(* ---- 統合 record ---- *)

iSVEGMsDate[ms_] :=
  If[NumericQ[ms] && ms > 0, FromUnixTime[ms/1000.], Missing["NoDate"]];

(* Exif の "2023:08:23 18:09:02" 形式 / DateObject の両方を受ける *)
iSVEGExifDate[ex_Association] :=
  Module[{d = Lookup[ex, "DateTimeOriginal", Lookup[ex, "DateTime", Missing[]]]},
    Which[
      Head[d] === DateObject, d,
      StringQ[d],
        Quiet@Check[DateObject[ToExpression /@ StringSplit[d, ":" | " "]],
          Missing["BadDate"]],
      True, Missing["NoDate"]]];
iSVEGExifDate[_] := Missing["NoExif"];

iSVEGFolderNameList[lib_, item_Association] :=
  With[{byId = iSVEGFolderById[lib]},
    Select[(Lookup[byId, ToString[#], Missing[]] &) /@ Lookup[item, "folders", {}],
      StringQ]];

iSVEGIndexRecord[lib_, item_Association] :=
  Module[{id = iSVEGItemId[item], kind, exrec, ex, w, h, size},
    kind = iSVEGItemKind[ToString@Lookup[item, "ext", ""]];
    exrec = iSVEGExifStored[lib, item];
    ex = If[AssociationQ[exrec], Lookup[exrec, "Exif", <||>], Missing["NotIndexed"]];
    w = Lookup[item, "width", Missing["NoSize"]];
    h = Lookup[item, "height", Missing["NoSize"]];
    size = Lookup[item, "size", Missing["NoSize"]];
    <|"Id" -> id,
      "Name" -> ToString@Lookup[item, "name", ""],
      "Ext" -> ToString@Lookup[item, "ext", ""],
      "Kind" -> kind,
      "Star" -> Lookup[item, "star", 0],
      "Width" -> w, "Height" -> h,
      "Megapixels" -> If[NumberQ[w] && NumberQ[h] && kind === "Image",
        Round[w h/10.^6, 0.1], Missing["NotImage"]],
      "Size" -> size,
      "SizeMB" -> If[NumberQ[size], Round[size/10.^6, 0.01], Missing["NoSize"]],
      "Added" -> iSVEGMsDate[Lookup[item, "modificationTime", Missing[]]],
      "Created" -> iSVEGMsDate[Lookup[item, "btime", Missing[]]],
      "Modified" -> iSVEGMsDate[Lookup[item, "mtime", Missing[]]],
      "Tags" -> (ToString /@ Lookup[item, "tags", {}]),
      "Folders" -> iSVEGFolderNameList[lib, item],
      "Annotation" -> ToString@Lookup[item, "annotation", ""],
      "URL" -> ToString@Lookup[item, "url", ""],
      "Deleted" -> TrueQ[Lookup[item, "isDeleted", False]],
      "Summary" -> With[{srec = iSVEGSummaryRecord[id]},
        If[AssociationQ[srec], ToString@Lookup[srec, "Summary", ""],
          Missing["NoSummary"]]],
      "HasSummary" -> AssociationQ[iSVEGSummaryRecord[id]],
      "SummaryStatus" -> With[{srec = iSVEGSummaryRecord[id]},
        If[AssociationQ[srec],
          If[iSVEGSummaryCurrentQ[srec, item], "Current", "Stale"],
          Missing["NoSummary"]]],
      "Note" -> iSVEGNoteTextOf[id],
      "HasNote" -> StringQ[iSVEGNoteTextOf[id]],
      "HasExif" -> If[AssociationQ[exrec], TrueQ[exrec["HasExif"]],
        Missing["NotIndexed"]],
      "CameraModel" -> If[AssociationQ[ex],
        Lookup[ex, "Model", Missing["NoExif"]], Missing["NotIndexed"]],
      "TakenAt" -> If[AssociationQ[ex], iSVEGExifDate[ex], Missing["NotIndexed"]],
      "ISO" -> If[AssociationQ[ex],
        Lookup[ex, "ISOSpeedRatings", Missing["NoExif"]], Missing["NotIndexed"]],
      "FNumber" -> If[AssociationQ[ex],
        Lookup[ex, "FNumber", Missing["NoExif"]], Missing["NotIndexed"]],
      "ExposureTime" -> If[AssociationQ[ex],
        Lookup[ex, "ExposureTime", Missing["NoExif"]], Missing["NotIndexed"]],
      "FocalLength" -> If[AssociationQ[ex],
        Lookup[ex, "FocalLength", Missing["NoExif"]], Missing["NotIndexed"]],
      "GPS" -> If[AssociationQ[ex], iSVEGExifPosition[ex], Missing["NotIndexed"]],
      "Exif" -> ex|>];

Options[SourceVaultEagleIndexRecord] = {"Library" -> Automatic};
SourceVaultEagleIndexRecord[itemSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], item},
    If[! StringQ[lib], Return[Missing["NoLibrary"]]];
    item = iSVEGItemOf[lib, itemSpec];
    If[item === $Failed, Return[Missing["ItemNotFound"]]];
    iSVEGNotesEnsure[];
    iSVEGIndexRecord[lib, item]];

(* ---- 述語 (AND/OR) 検索。Missing を含む比較は TrueQ で安全に False 扱い。 ---- *)

Options[SourceVaultEagleIndexSearch] = Join[Options[SourceVaultEagleSearch],
  {"Query" -> ""}];
SourceVaultEagleIndexSearch[pred : (_Function | All) : All, opts : OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], searchOpts, items, recs, lim},
    If[! StringQ[lib], Return[{}]];
    iSVEGExifEnsureLoaded[lib];
    (* Limit は pred 適用後に効かせる *)
    searchOpts = DeleteCases[
      FilterRules[Flatten[{opts}], Options[SourceVaultEagleSearch]],
      HoldPattern["Limit" -> _]];
    items = SourceVaultEagleSearch[ToString[OptionValue["Query"]],
      Sequence @@ searchOpts, "Library" -> lib];
    iSVEGNotesEnsure[];   (* Cloud-Publishable 判定に item キャッシュを使うため items の後 *)
    recs = iSVEGIndexRecord[lib, #] & /@ items;
    If[pred =!= All, recs = Select[recs, TrueQ[pred[#]] &]];
    lim = OptionValue["Limit"];
    If[IntegerQ[lim] && lim >= 0, recs = Take[recs, UpTo[lim]]];
    recs];

Options[SourceVaultEagleIndexDataset] = Options[SourceVaultEagleIndexSearch];
SourceVaultEagleIndexDataset[pred : (_Function | All) : All, opts : OptionsPattern[]] :=
  Dataset[(KeyDrop[#, "Exif"] &) /@ SourceVaultEagleIndexSearch[pred, opts]];

(* ---- フォルダ一覧 (notebook list 風 Grid、ファイル名クリックで SystemOpen) ---- *)

iSVEGRecDateStr[d_] :=
  If[Head[d] === DateObject,
    DateString[d, {"Year", "/", "Month", "/", "Day"}], ""];

iSVEGRecNum[x_] := If[NumberQ[x], x, 0];

iSVEGRecSortKey[by_][r_] := Switch[by,
  "Name", ToString@Lookup[r, "Name", ""],
  "Size", iSVEGRecNum[Lookup[r, "Size", 0]],
  "Star", iSVEGRecNum[Lookup[r, "Star", 0]],
  "Created", Quiet@Check[AbsoluteTime[r["Created"]], 0],
  "Modified", Quiet@Check[AbsoluteTime[r["Modified"]], 0],
  _, Quiet@Check[AbsoluteTime[r["Added"]], 0]];

Options[SourceVaultEagleFolderView] = {"Library" -> Automatic, "Recursive" -> False,
  "Where" -> All, "SortBy" -> "Added", "SortOrder" -> "Desc",
  "Limit" -> 200, "IncludeDeleted" -> False, "ShowExif" -> False};
SourceVaultEagleFolderView[folderSpec_, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], f, items, recs, total,
      pred = OptionValue["Where"], ff, cols, header, body, showExif, grid},
    If[! StringQ[lib],
      Return[Style["Eagle ライブラリが未登録です。", "Text"]]];
    (* 通常フォルダに加えスマートフォルダ名/id も指定できる *)
    f = iSVEGResolveFolderSpec[lib, folderSpec, TrueQ[OptionValue["Recursive"]]];
    If[! AssociationQ[f],
      Return[Style["フォルダが見つかりません: " <> ToString[folderSpec], "Text"]]];
    f = f["Folder"];
    iSVEGExifEnsureLoaded[lib];
    items = SourceVaultEagleItemsInFolder[f, "Library" -> lib,
      "Recursive" -> OptionValue["Recursive"],
      "IncludeDeleted" -> OptionValue["IncludeDeleted"]];
    iSVEGNotesEnsure[];   (* Cloud-Publishable 判定に item キャッシュを使うため items の後 *)
    recs = iSVEGIndexRecord[lib, #] & /@ items;
    If[pred =!= All && pred =!= None, recs = Select[recs, TrueQ[pred[#]] &]];
    recs = SortBy[recs, iSVEGRecSortKey[OptionValue["SortBy"]]];
    If[OptionValue["SortOrder"] === "Desc" || OptionValue["SortOrder"] === Descending,
      recs = Reverse[recs]];
    total = Length[recs];
    (* 大規模フォルダ対策: 既定 200 件で切り、切り詰めは下で明示する (無言で隠さない) *)
    If[IntegerQ[OptionValue["Limit"]], recs = Take[recs, UpTo[OptionValue["Limit"]]]];
    If[recs === {}, Return[Style["該当する item がありません。", "Text"]]];
    ff = iSVEGFont[];
    showExif = TrueQ[OptionValue["ShowExif"]];
    cols = Join[{"ファイル", "★", "解像度", "サイズ", "追加日", "作成日", "変更日",
        "タグ", "サマリー"},
      If[showExif, {"カメラ", "撮影日"}, {}]];
    body = Function[r,
      Join[
        {Button[
           Style[Row[{r["Name"] <> If[r["Ext"] === "", "", "." <> r["Ext"]]}],
             "Hyperlink", FontFamily -> ff],
           SourceVaultEagleOpenItem[r["Id"], "Library" -> lib],
           Appearance -> "Frameless", Method -> "Queued", BaseStyle -> "Hyperlink"],
         With[{s = Lookup[r, "Star", 0]},
           If[IntegerQ[s] && s > 0, StringRepeat["★", Min[s, 5]], ""]],
         With[{w = r["Width"], h = r["Height"]},
           If[NumberQ[w] && NumberQ[h],
             ToString[Round[w]] <> "×" <> ToString[Round[h]], ""]],
         iSVEGSizeStr[Lookup[r, "Size", Missing[]]],
         iSVEGRecDateStr[r["Added"]],
         iSVEGRecDateStr[r["Created"]],
         iSVEGRecDateStr[r["Modified"]],
         StringRiffle[Lookup[r, "Tags", {}], ", "],
         (* サマリーがあれば本文 (切り詰め) 全体がリンク -> 全文をウインドウ表示 *)
         With[{sm = Lookup[r, "Summary", Missing[]], rid = r["Id"]},
           If[StringQ[sm] && StringTrim[sm] =!= "",
             Button[Style[Row[{iSVEGTruncate[sm, 80]}], "Hyperlink",
                 FontFamily -> ff],
               SourceVaultEagleShowSummary[rid],
               Appearance -> "Frameless", Method -> "Queued",
               BaseStyle -> "Hyperlink"],
             ""]]},
        If[showExif,
          {With[{cm = r["CameraModel"]}, If[StringQ[cm], cm, ""]],
           iSVEGRecDateStr[r["TakenAt"]]}, {}]]] /@ recs;
    header = (Style[#, Bold, FontFamily -> ff] &) /@ cols;
    (* SourceVaultFormatNotebookList と同じ表スタイル *)
    grid = Grid[Prepend[body, header],
      Frame -> All, FrameStyle -> Directive[GrayLevel[0.85]],
      Background -> {None, {GrayLevel[0.92], {White}}},
      Alignment -> {Left, Center}, Spacings -> {1.2, 0.7},
      BaseStyle -> {FontFamily -> ff}];
    If[Length[recs] < total,
      Column[{
        Style["全 " <> ToString[total] <> " 件中 " <> ToString[Length[recs]] <>
          " 件を表示 (並び順: " <> ToString[OptionValue["SortBy"]] <>
          ")。全件は \"Limit\" -> All、絞り込みは \"Where\" を使用。",
          FontFamily -> ff, GrayLevel[0.45]],
        grid}],
      grid]];

(* FolderView を新規ノートブックで開く front end ラッパ (FolderList のリンク先)。 *)
Options[SourceVaultEagleShowFolder] = Options[SourceVaultEagleFolderView];
SourceVaultEagleShowFolder[folderSpec_, opts : OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], view, res, title},
    view = SourceVaultEagleFolderView[folderSpec, opts];
    res = iSVEGResolveFolderSpec[lib, folderSpec, False];
    title = If[AssociationQ[res],
      ToString@Lookup[res["Folder"], "name", ""], ToString[folderSpec]];
    Quiet@Check[
      CreateDocument[ExpressionCell[view, "Output"],
        WindowTitle -> "Eagle folder: " <> title,
        WindowSize -> {1100, 700},
        StyleDefinitions -> $SourceVaultEagleNotebookStyle], $Failed];
    view];

(* ============================================================
   表示 (Dataset / View / GeoView)
   ============================================================ *)

iSVEGFont[] := If[$Language === "Japanese", "Yu Gothic UI", "Segoe UI"];

iSVEGTextCell[s_] :=
  With[{t = If[StringQ[s], s, ToString[s]], ff = iSVEGFont[]},
    Item[Tooltip[Style[t, "Text", FontFamily -> ff], t], Alignment -> Left]];

iSVEGSizeStr[b_?NumericQ] :=
  Which[b >= 1.*^9, ToString[Round[b/1.*^9, 0.1]] <> " GB",
    b >= 1.*^6, ToString[Round[b/1.*^6, 0.1]] <> " MB",
    b >= 1000., ToString[Round[b/1000.]] <> " KB",
    True, ToString[Round[b]] <> " B"];
iSVEGSizeStr[_] := "";

iSVEGDateStr[ms_?NumericQ] :=
  Quiet@Check[DateString[FromUnixTime[ms/1000.],
    {"Year", "/", "Month", "/", "Day", " ", "Hour", ":", "Minute"}], ""];
iSVEGDateStr[_] := "";

iSVEGFolderNames[lib_, item_Association] :=
  StringRiffle[iSVEGFolderNameList[lib, item], ", "];

(* SourceVault 共通スキーマ (SourceVaultSourceRow / SourceVaultSummaries と
   同じキー) + eagle 固有キー。旧キー "Name" は "Title" に改名。 *)
Options[SourceVaultEagleSummaryRow] = {"Library" -> Automatic};
SourceVaultEagleSummaryRow[item_Association, OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], sm, url, file, pl, fname,
      bibTitle},
    sm = SourceVaultEagleSummary[item, "Library" -> lib];
    url = ToString@Lookup[item, "url", ""];
    If[! StringStartsQ[url, "http"], url = ""];
    file = Quiet@Check[
      SourceVaultEagleItemPath[item, "Library" -> OptionValue["Library"]],
      $Failed];
    If[! StringQ[file], file = ""];
    pl = With[{p = If[AssociationQ[sm],
        Lookup[sm, "PrivacyLevel", Missing[]], Missing[]]},
      If[NumericQ[p], N[p], If[StringQ[lib], iSVEGLibraryPL[lib], 1.0]]];
    fname = ToString@Lookup[item, "name", ""] <>
      With[{e = ToString@Lookup[item, "ext", ""]},
        If[e === "", "", "." <> e]];
    (* 書誌タイトル (Summarize / ExtractBibMeta が record に保存) があれば優先 *)
    bibTitle = If[AssociationQ[sm], ToString@Lookup[sm, "Title", ""], ""];
    <|"Kind" -> "eagle",
      "Id" -> iSVEGItemId[item],
      "Title" -> If[StringTrim[bibTitle] =!= "", bibTitle, fname],
      "Authors" -> If[AssociationQ[sm], ToString@Lookup[sm, "Authors", ""], ""],
      "Published" -> If[AssociationQ[sm], ToString@Lookup[sm, "Published", ""], ""],
      "Summary" -> If[AssociationQ[sm], ToString@Lookup[sm, "Summary", ""], ""],
      "URL" -> url,
      "File" -> file,
      "Date" -> iSVEGDateStr[Lookup[item, "btime", Missing[]]],
      "PrivacyLevel" -> pl,
      (* eagle 固有の補助キー *)
      "FileName" -> fname,
      "Ext" -> ToString@Lookup[item, "ext", ""],
      "Size" -> iSVEGSizeStr[Lookup[item, "size", Missing[]]],
      "Tags" -> StringRiffle[ToString /@ Lookup[item, "tags", {}], ", "],
      "Folders" -> iSVEGFolderNames[lib, item],
      "Annotation" -> ToString@Lookup[item, "annotation", ""]|>];

Options[SourceVaultEagleDataset] = Options[SourceVaultEagleSearch];
SourceVaultEagleDataset[query_String : "", opts : OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]]},
    Dataset[(SourceVaultEagleSummaryRow[#, "Library" -> lib] &) /@
      SourceVaultEagleSearch[query, opts]]];

(* 保存済みサマリーの一覧 (notebook list 風 Grid)。
   「▶ 開く」= 原本を SystemOpen、ファイル名 = サマリー全文をウインドウ表示。
   (Dataset はセル内の式に含まれる文字列をクォート付きで表示するため Grid を使う) *)
(* 保存済みサマリー一覧の内部行 (新しい順):
   {<|"Id", "NameDisp", "Rec", "Status"|>..}
   query はサマリー本文/ノート補足/ファイル名の部分一致。
   SourceVaultEagleSummaries と横断検索 provider (iSVEGCommonRows) が共用する。 *)
iSVEGSummaryListRows[query_String, lib_] :=
  Module[{sums, key, cache, q, rows},
    sums = iSVEGSummaryCacheEnsure[];
    q = StringTrim[query];
    key = If[StringQ[lib], iSVEGLibStoreKey[lib], None];
    cache = If[StringQ[lib],
      (SourceVaultEagleItems["Library" -> lib];
       Lookup[$iSVEGItemCache, lib, <||>]), <||>];
    iSVEGNotesEnsure[];   (* Cloud-Publishable 判定に item キャッシュを使うため items の後 *)
    rows = KeyValueMap[
      Function[{id, r},
        Module[{recLib = ToString@Lookup[r, "Library", ""], item, name, status},
          (* 他ライブラリの record は除外 (Library 未記録の旧 record は含める) *)
          If[key =!= None && recLib =!= "" && recLib =!= key, Nothing,
            item = Lookup[cache, id, $Failed];
            status = If[AssociationQ[item],
              If[iSVEGSummaryCurrentQ[r, item], "Current", "Stale"], "Unknown"];
            name = ToString@Lookup[r, "Name", id] <>
              With[{e = ToString@Lookup[r, "Ext", ""]}, If[e === "", "", "." <> e]];
            If[q =!= "" && ! AnyTrue[
                {name, ToString@Lookup[r, "Summary", ""],
                 ToString@Lookup[r, "Title", ""],
                 ToString@Lookup[r, "Authors", ""],
                 With[{nt = iSVEGNoteTextOf[id]}, If[StringQ[nt], nt, ""]]},
                StringContainsQ[#, q, IgnoreCase -> True] &],
              Nothing,
              <|"Id" -> id, "NameDisp" -> name, "Rec" -> r, "Status" -> status|>]]]],
      sums];
    ReverseSortBy[Select[rows, AssociationQ],
      ToString@Lookup[Lookup[#, "Rec", <||>], "CreatedAt", ""] &]];

Options[SourceVaultEagleSummaries] = {"Library" -> Automatic, "Limit" -> Automatic};
SourceVaultEagleSummaries[query_String : "", OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], rows, lim,
      total, header, body, grid, ff = iSVEGFont[]},
    rows = iSVEGSummaryListRows[query, lib];
    total = Length[rows];
    lim = OptionValue["Limit"];
    If[IntegerQ[lim] && lim >= 0, rows = Take[rows, UpTo[lim]]];
    If[rows === {},
      Return[Style["保存済みサマリーはありません。", "Text"]]];
    header = (Style[#, Bold, FontFamily -> ff] &) /@
      {"原本", "ファイル", "サマリー", "Method", "PL", "生成日時", "状態", "ノート"};
    body = Function[row,
      With[{id = row["Id"], r = row["Rec"]},
        {Button[Style[Row[{"▶ 開く"}], "Hyperlink", FontFamily -> ff],
           SourceVaultEagleOpenItem[id],
           Appearance -> "Frameless", Method -> "Queued",
           BaseStyle -> "Hyperlink"],
         Button[Style[Row[{row["NameDisp"]}], "Hyperlink", FontFamily -> ff],
           SourceVaultEagleShowSummary[id],
           Appearance -> "Frameless", Method -> "Queued",
           BaseStyle -> "Hyperlink"],
         iSVEGTruncate[ToString@Lookup[r, "Summary", ""], 120],
         ToString@Lookup[r, "Method", ""],
         With[{pl = Lookup[r, "PrivacyLevel", Missing[]]},
           If[NumericQ[pl], ToString[N[pl]], ""]],
         ToString@Lookup[r, "CreatedAt", ""],
         row["Status"],
         (* 保存済みノート (追記つき) があるか *)
         If[StringQ[iSVEGSummaryNoteFile[id]], "あり", ""]}]] /@ rows;
    grid = Grid[Prepend[body, header],
      Frame -> All, FrameStyle -> Directive[GrayLevel[0.85]],
      Background -> {None, {GrayLevel[0.92], {White}}},
      Alignment -> {Left, Center}, Spacings -> {1.2, 0.7},
      BaseStyle -> {FontFamily -> ff}];
    If[Length[rows] < total,
      Column[{
        Style["全 " <> ToString[total] <> " 件中 " <> ToString[Length[rows]] <>
          " 件を表示。全件は \"Limit\" -> All。", FontFamily -> ff,
          GrayLevel[0.45]], grid}],
      grid]];

(* ---- SourceVault 横断検索 provider (SourceVault`SourceVaultSummaries) ----
   保存済みサマリー (SourceVaultEagleSummaries と同じ対象) を共通スキーマ行で
   返す。SourceVault.wl の SourceVaultRegisterSummaryProvider 経由で "eagle"
   provider として登録する (ロード順不問・再ロード冪等)。 *)
iSVEGCommonRows[query_String, opts_Association] :=
  Module[{lib, listRows, libPL, cache},
    lib = iSVEGLib[Automatic];
    listRows = Quiet@Check[iSVEGSummaryListRows[query, lib], {}];
    If[! ListQ[listRows], Return[{}]];
    libPL = If[StringQ[lib], iSVEGLibraryPL[lib], 1.0];
    cache = If[StringQ[lib], Lookup[$iSVEGItemCache, lib, <||>], <||>];
    Map[Function[row,
      Module[{id, r, item, url, file, pl},
        id = ToString@Lookup[row, "Id", ""];
        r = Lookup[row, "Rec", <||>];
        item = Lookup[cache, id, Missing[]];
        url = If[AssociationQ[item], ToString@Lookup[item, "url", ""], ""];
        If[! StringStartsQ[url, "http"], url = ""];
        file = Quiet@Check[
          SourceVaultEagleItemPath[id, "Library" -> lib], $Failed];
        If[! StringQ[file], file = ""];
        pl = With[{p = Lookup[r, "PrivacyLevel", Missing[]]},
          If[NumericQ[p], N[p], libPL]];
        <|"Kind" -> "eagle",
          "Id" -> id,
          (* 書誌タイトル (record の "Title") があれば優先、無ければファイル名 *)
          "Title" -> With[{bt = ToString@Lookup[r, "Title", ""]},
            If[StringTrim[bt] =!= "", bt, ToString@Lookup[row, "NameDisp", id]]],
          "Authors" -> ToString@Lookup[r, "Authors", ""],
          "Published" -> ToString@Lookup[r, "Published", ""],
          "Summary" -> ToString@Lookup[r, "Summary", ""],
          "URL" -> url,
          "File" -> file,
          "Date" -> ToString@Lookup[r, "CreatedAt", ""],
          "PrivacyLevel" -> pl,
          "FileName" -> ToString@Lookup[row, "NameDisp", id],
          "Status" -> ToString@Lookup[row, "Status", ""]|>]],
      listRows]];
iSVEGCommonRows[query_String] := iSVEGCommonRows[query, <||>];

(* provider / 行アクション登録 (SourceVault.wl 側のレジストリ。旧版 SourceVault.wl
   でレジストリが無い環境でも落ちないようにガードする) *)
If[! AssociationQ[$SourceVaultSummaryProviders],
  $SourceVaultSummaryProviders = <||>];
$SourceVaultSummaryProviders["eagle"] = iSVEGCommonRows;

If[! AssociationQ[$iSVRowTitleActions], $iSVRowTitleActions = <||>];
$iSVRowTitleActions["eagle"] = Function[id, SourceVaultEagleShowSummary[id]];
If[! AssociationQ[$iSVRowOpenActions], $iSVRowOpenActions = <||>];
$iSVRowOpenActions["eagle"] = Function[id, SourceVaultEagleOpenItem[id]];

If[! ValueQ[$SourceVaultEagleNotebookStyle],
  $SourceVaultEagleNotebookStyle = "SourceVault default.nb"];

(* ユーザー追記つきサマリーノートの保存先 (Eagle 側は汚さない) *)
iSVEGNotesDir[] := FileNameJoin[{iSVEGStoreRoot[], "notes"}];

iSVEGSafeFileName[s_String] :=
  StringTake[
    StringReplace[s, "\\" | "/" | ":" | "*" | "?" | "\"" | "<" | ">" | "|" -> "_"],
    UpTo[60]];

(* id に対応する保存済みノート (<名前>_<id>.nb)。無ければ Missing。 *)
iSVEGSummaryNoteFile[id_String] :=
  Module[{dir = iSVEGNotesDir[], hits},
    If[! TrueQ[Quiet@Check[DirectoryQ[dir], False]], Return[Missing["NoNote"]]];
    hits = FileNames["*" <> id <> ".nb", dir];
    If[hits === {}, Missing["NoNote"], First[hits]]];

(* ---- ノート本文のキャッシュ (検索対象化) ----
   notes/*.nb はユーザーが Ctrl+S で随時編集するため、ファイルごとの
   {更新日, サイズ} スタンプで差分再抽出する。 *)
If[! AssociationQ[$iSVEGNoteCache], $iSVEGNoteCache = <||>]; (* id -> {stamp, text} *)

iSVEGNoteIdOf[file_String] :=
  With[{parts = StringSplit[FileBaseName[file], "_"]},
    If[parts === {}, FileBaseName[file], Last[parts]]];

iSVEGNoteStamp[file_String] :=
  {Quiet@Check[FileDate[file, "Modification"], $Failed],
   Quiet@Check[FileByteCount[file], $Failed]};

(* ---- ノートの秘匿セル ----
   NBAccess`NBSetConfidentialTag / NBMarkCellConfidential が保存する
   TaggingRules 構造 ("claudecode" -> {"confidential" -> True|False,
   "privacyLevel" -> num}) を読む。NBAccess の公開 API は NotebookObject
   (front end) ベースのため、ディスク上のセル式にはこの永続化契約を参照する。
   判定は NBMarkCellConfidential と同じ「confidential===True または
   privacyLevel > 0.5」。 *)
iSVEGCellConfidentialQ[cell_Cell] :=
  Module[{trs, tags, cc, conf, pl},
    trs = Cases[cell, (TaggingRules -> tr_) :> tr, {1}];
    If[trs === {}, Return[False]];
    tags = First[trs];
    tags = If[AssociationQ[tags], Normal[tags], tags];
    If[! ListQ[tags], Return[False]];
    cc = Lookup[tags, "claudecode", {}];
    cc = If[AssociationQ[cc], Normal[cc], cc];
    If[! ListQ[cc], Return[False]];
    conf = Lookup[cc, "confidential", Missing[]];
    pl = Lookup[cc, "privacyLevel", Missing[]];
    TrueQ[conf] || (NumericQ[pl] && pl > 0.5)];
iSVEGCellConfidentialQ[___] := False;

(* Notebook 式からトップレベルのセル列を取り出す (CellGroupData 展開)。
   Cases の深い走査だと秘匿セル内のインラインセルまで拾うので使わない。 *)
iSVEGNotebookCells[Notebook[cells_List, ___]] :=
  Flatten[iSVEGExpandCellGroup /@ cells];
iSVEGNotebookCells[___] := {};
iSVEGExpandCellGroup[Cell[CellGroupData[cells_List, ___], ___]] :=
  Flatten[iSVEGExpandCellGroup /@ cells];
iSVEGExpandCellGroup[c_Cell] := {c};
iSVEGExpandCellGroup[___] := {};

(* NBAccess ロード済みなら NBCellExprToText (DownValues で判定 — Names は
   シンボル参照だけで非空になるため不可)。フォールバックはセル内容
   (第1引数) のみから文字列抽出 (スタイル名や TaggingRules を拾わない)。 *)
iSVEGCellExprText[c_Cell] :=
  Module[{s},
    If[Length[DownValues[NBAccess`NBCellExprToText]] > 0,
      s = Quiet@Check[NBAccess`NBCellExprToText[c], $Failed];
      If[StringQ[s] && StringTrim[s] =!= "", Return[s]]];
    StringRiffle[Cases[{First[c]}, t_String :> t, {0, Infinity}], " "]];

(* ノート本文。filterConf=True (Cloud-Publishable item) のときは
   秘匿セルを除外する。それ以外は全文 (Import Plaintext の速い経路)。 *)
iSVEGNotePlaintext[file_String, filterConf_ : False] :=
  Module[{t, nb, cells},
    If[! TrueQ[filterConf],
      t = Quiet@Check[Import[file, "Plaintext"], $Failed];
      If[StringQ[t] && StringTrim[t] =!= "", Return[t]]];
    nb = Quiet@Check[Get[file], $Failed];
    If[Head[nb] =!= Notebook, Return[""]];
    cells = iSVEGNotebookCells[nb];
    If[TrueQ[filterConf],
      cells = Select[cells, ! iSVEGCellConfidentialQ[#] &]];
    StringRiffle[Select[iSVEGCellExprText /@ cells, # =!= "" &], "\n"]];

(* item が Cloud-Publishable か (現在ライブラリの item キャッシュから判定)。
   item が見つからない場合は False = 無指定扱い (全文・ローカル検索のみ)。 *)
iSVEGNoteCloudPubQ[id_String] :=
  With[{lib = iSVEGLib[]},
    StringQ[lib] &&
    With[{it = Lookup[Lookup[$iSVEGItemCache, lib, <||>], id, $Failed]},
      AssociationQ[it] && iSVEGCloudPublishableQ[it]]];

iSVEGNotesEnsure[] :=
  Module[{dir = iSVEGNotesDir[], files},
    files = If[TrueQ[Quiet@Check[DirectoryQ[dir], False]],
      FileNames["*.nb", dir], {}];
    $iSVEGNoteCache = KeyTake[$iSVEGNoteCache, iSVEGNoteIdOf /@ files];
    Scan[
      Function[f,
        Module[{id = iSVEGNoteIdOf[f], cloudPub, st, e},
          cloudPub = iSVEGNoteCloudPubQ[id];
          (* stamp に Cloud-Publishable フラグも含める: タグの付け外しで
             フィルタ要否が変わったら再抽出する *)
          st = Append[iSVEGNoteStamp[f], cloudPub];
          e = Lookup[$iSVEGNoteCache, id, Missing[]];
          If[! (ListQ[e] && e[[1]] === st),
            $iSVEGNoteCache[id] = {st, iSVEGNotePlaintext[f, cloudPub]}]]],
      files];
    $iSVEGNoteCache];

(* キャッシュからノート本文 (ensure は呼び出し側エントリポイントで実施済み) *)
iSVEGNoteTextOf[id_String] :=
  With[{e = Lookup[$iSVEGNoteCache, id, Missing[]]},
    If[ListQ[e] && StringQ[e[[2]]] && StringTrim[e[[2]]] =!= "",
      e[[2]], Missing["NoNote"]]];

Options[SourceVaultEagleShowSummary] = {"Fresh" -> False};
SourceVaultEagleShowSummary[itemSpec_, OptionsPattern[]] :=
  Module[{id, rec, title, noteFile, notesDir, savePath},
    id = If[AssociationQ[itemSpec], iSVEGItemId[itemSpec], ToString[itemSpec]];
    rec = SourceVaultEagleSummary[id];
    (* 保存済みノートがあればそれを開く (ユーザーの追記が正本) *)
    noteFile = iSVEGSummaryNoteFile[id];
    If[! TrueQ[OptionValue["Fresh"]] && StringQ[noteFile],
      Quiet@Check[NotebookOpen[noteFile], $Failed];
      Return[rec]];
    title = If[AssociationQ[rec],
      ToString@Lookup[rec, "Name", id] <> "." <> ToString@Lookup[rec, "Ext", ""], id];
    notesDir = iSVEGNotesDir[];
    savePath = FileNameJoin[{notesDir,
      iSVEGSafeFileName[If[AssociationQ[rec], ToString@Lookup[rec, "Name", id], id]] <>
      "_" <> id <> ".nb"}];
    Quiet@Check[
      CreateDocument[
        Join[
          If[AssociationQ[rec],
            {Cell[title, "Subtitle"],
             Cell["生成: " <> ToString@Lookup[rec, "CreatedAt", ""] <>
               " / Method: " <> ToString@Lookup[rec, "Method", ""] <>
               " / 状態: " <> ToString@Lookup[rec, "SummaryStatus", ""], "Text"],
             Cell[ToString@Lookup[rec, "Summary", ""], "Text"]},
            {Cell["サマリー未生成", "Subtitle"],
             Cell["SourceVaultEagleSummarize[\"" <> id <> "\"] を実行してください。", "Text"]}],
          (* 保存ボタン: notes/ へ即保存し、以後はその保存版が開かれる。
             With で保存先パスをリテラル埋め込み (再オープン後も動作するよう
             System` シンボルのみで構成する)。 *)
          {With[{p = savePath, ndir = notesDir},
             Cell[BoxData[ToBoxes[
               Button[
                 Style[Row[{"このノートを保存する (補足を追記したら押す。以後この保存版が開きます)"}],
                   "Hyperlink"],
                 (If[! DirectoryQ[ndir],
                    CreateDirectory[ndir, CreateIntermediateDirectories -> True]];
                  NotebookSave[ButtonNotebook[], p]),
                 Method -> "Queued", Appearance -> "Frameless",
                 BaseStyle -> "Hyperlink"]]], "Text"]]}],
        WindowTitle -> "Eagle summary: " <> title,
        StyleDefinitions -> $SourceVaultEagleNotebookStyle],
      $Failed];
    rec];

Options[SourceVaultEagleView] = Join[Options[SourceVaultEagleSearch],
  {"Thumbnails" -> True, "ThumbnailSize" -> 48}];
SourceVaultEagleView[query_String : "", opts : OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], items, rows, ff = iSVEGFont[],
      showThumbs = TrueQ[OptionValue["Thumbnails"]], tsz = OptionValue["ThumbnailSize"],
      searchOpts, lim, total, out},
    If[lib === $Failed, Return[Style["Eagle ライブラリが未登録です。", "Text"]]];
    searchOpts = DeleteCases[
      FilterRules[Flatten[{opts}], Options[SourceVaultEagleSearch]],
      HoldPattern["Limit" -> _]];
    lim = OptionValue["Limit"] /. Automatic -> 50;   (* View はサムネイル読込があるので既定 50 件 *)
    items = SourceVaultEagleSearch[query, Sequence @@ searchOpts, "Library" -> lib];
    total = Length[items];
    If[IntegerQ[lim], items = Take[items, UpTo[lim]]];
    If[items === {},
      (* テキスト検索が空振りでも同名フォルダがあれば案内する
         (View の引数はテキスト検索であってフォルダ指定ではない) *)
      Return[If[StringTrim[query] =!= "" &&
          AssociationQ[iSVEGResolveFolderSpec[lib, StringTrim[query], True]],
        Style["「" <> StringTrim[query] <>
          "」にテキスト一致する item はありません。同名のフォルダがあります: " <>
          "フォルダ内一覧は SourceVaultEagleFolderView[\"" <> StringTrim[query] <>
          "\"]、または SourceVaultEagleView[\"\", \"Folder\" -> \"" <> StringTrim[query] <>
          "\"] を使ってください。", "Text"],
        Style["該当する item がありません。", "Text"]]]];
    rows = Function[it,
      With[{id = iSVEGItemId[it]},
        Join[
          <|"" -> Tooltip[Button["\:25b6", SourceVaultEagleOpenItem[id],
               Appearance -> "Frameless", Method -> "Queued"], "原本ファイルを開く"],
            "App" -> Tooltip[Button["\:2302", SourceVaultEagleShowInApp[id],
               Appearance -> "Frameless", Method -> "Queued"], "Eagle で表示"],
            "Sum" -> Tooltip[Button["\:2630", SourceVaultEagleShowSummary[id],
               Appearance -> "Frameless", Method -> "Queued"], "サマリー表示"]|>,
          If[showThumbs,
            <|"Img" -> With[{th = SourceVaultEagleThumbnail[id, "Library" -> lib,
                  "Size" -> tsz]},
                If[ImageQ[th], th, ""]]|>, <||>],
          <|"Date" -> Style[iSVEGDateStr[Lookup[it, "btime", Missing[]]], FontFamily -> ff],
            "Name" -> iSVEGTextCell[ToString@Lookup[it, "name", ""]],
            "Ext" -> Style[ToString@Lookup[it, "ext", ""], FontFamily -> ff],
            "Size" -> Style[iSVEGSizeStr[Lookup[it, "size", Missing[]]], FontFamily -> ff],
            "Tags" -> iSVEGTextCell[StringRiffle[ToString /@ Lookup[it, "tags", {}], ", "]],
            "Memo" -> iSVEGTextCell[
              With[{sm = SourceVaultEagleSummary[it, "Library" -> lib]},
                Which[
                  AssociationQ[sm], ToString@Lookup[sm, "Summary", ""],
                  StringTrim[ToString@Lookup[it, "annotation", ""]] =!= "",
                    ToString@Lookup[it, "annotation", ""],
                  True, ""]]]|>]]] /@ items;
    out = Pane[
      Dataset[rows,
        ItemSize -> {2, If[showThumbs,
          {2, 2, 2, 6, 12, 22, 4, 6, 18, 36}, {2, 2, 2, 12, 22, 4, 6, 18, 36}]},
        Alignment -> {Left, Center},
        MaxItems -> {All, All}],
      ImageSize -> Full];
    If[Length[items] < total,
      Column[{
        Style["全 " <> ToString[total] <> " 件中 " <> ToString[Length[items]] <>
          " 件を表示。全件は \"Limit\" -> All (サムネイル読込に注意)。",
          FontFamily -> ff, GrayLevel[0.45]],
        out}],
      out]];

(* ---- Exif GPS 地図表示 (eagle_example_codes.nb の eagleGeoMarkers を踏襲) ---- *)

iSVEGExifDeg[v_] :=
  Which[QuantityQ[v], QuantityMagnitude[v], NumericQ[v], v, True, Missing["NoGPS"]];

iSVEGExifPosition[exif_Association] :=
  Module[{lat = iSVEGExifDeg[Lookup[exif, "GPSLatitude", Missing[]]],
      lon = iSVEGExifDeg[Lookup[exif, "GPSLongitude", Missing[]]],
      latRef = ToString@Lookup[exif, "GPSLatitudeRef", "North"],
      lonRef = ToString@Lookup[exif, "GPSLongitudeRef", "East"]},
    If[! NumericQ[lat] || ! NumericQ[lon], Return[Missing["NoGPS"]]];
    {If[MemberQ[{"North", "N"}, latRef], 1, -1]*lat,
     If[MemberQ[{"East", "E"}, lonRef], 1, -1]*lon}];
iSVEGExifPosition[_] := Missing["NoGPS"];

Options[SourceVaultEagleGeoView] = Join[Options[SourceVaultEagleSearch],
  {"GeoRange" -> Automatic, "MarkerScale" -> 0.003, "ThumbnailSize" -> 64}];
SourceVaultEagleGeoView[query_String : "", opts : OptionsPattern[]] :=
  Module[{lib = iSVEGLib[OptionValue["Library"]], items, searchOpts, markers},
    If[lib === $Failed, Return[Style["Eagle ライブラリが未登録です。", "Text"]]];
    searchOpts = FilterRules[Flatten[{opts}], Options[SourceVaultEagleSearch]];
    items = SourceVaultEagleSearch[query, Sequence @@ searchOpts, "Library" -> lib];
    items = Select[items, iSVEGItemKind[ToString@Lookup[#, "ext", ""]] === "Image" &];
    markers = Map[
      Function[it,
        Module[{path = SourceVaultEagleItemPath[it, "Library" -> lib], exif, pos, th},
          If[! StringQ[path], Nothing,
            exif = Quiet@Check[Import[path, "Exif"], $Failed];
            pos = If[AssociationQ[exif], iSVEGExifPosition[exif],
              If[ListQ[exif], iSVEGExifPosition[Association[exif]], Missing["NoGPS"]]];
            If[! ListQ[pos], Nothing,
              th = SourceVaultEagleThumbnail[it, "Library" -> lib,
                "Size" -> OptionValue["ThumbnailSize"]];
              GeoMarker[GeoPosition[pos],
                EventHandler[If[ImageQ[th], th, ToString@Lookup[it, "name", ""]],
                  {"MouseClicked" :> SystemOpen[path]}],
                "Scale" -> OptionValue["MarkerScale"]]]]]],
      items];
    markers = DeleteCases[markers, Nothing];
    If[markers === {},
      Return[Style["GPS 情報を持つ写真がありません。", "Text"]]];
    GeoGraphics[markers,
      If[OptionValue["GeoRange"] === Automatic, Sequence @@ {},
        GeoRange -> OptionValue["GeoRange"]]]];

(* ============================================================
   状態
   ============================================================ *)

SourceVaultEagleStatus[] :=
  Module[{lib = iSVEGLib[], api = SourceVaultEagleAPIAvailable[], items, sumDir, nSum},
    items = If[lib === $Failed, {}, SourceVaultEagleItems["Library" -> lib]];
    sumDir = FileNameJoin[{iSVEGStoreRoot[], "summaries"}];
    nSum = If[DirectoryQ[sumDir], Length[FileNames["*.json", sumDir]], 0];
    iSVEGIngestMapEnsure[];
    <|"Library" -> If[lib === $Failed, Missing["NotSet"], lib],
      "Online" -> If[lib === $Failed, False, iSVEGOnlineQ[lib]],
      "RegisteredLibraries" -> $iSVEGLibraries,
      "Items" -> Length[items],
      "Deleted" -> Count[items, _?(TrueQ[Lookup[#, "isDeleted", False]] &)],
      "Folders" -> Length[SourceVaultEagleFolders[]],
      "API" -> api,
      "EagleHasCurrentLibraryOpen" ->
        If[lib === $Failed, False, iSVEGEagleHasLibraryOpen[lib]],
      "StoreRoot" -> iSVEGStoreRoot[],
      "Summaries" -> nSum,
      "IngestRecords" -> Length[$iSVEGIngestMap]|>];

(* ════════════════════════════════════════════════════════
   Eagle View 出力セルの自動機密マーク (2026-06)
   ────────────────────────────────────────────────────────
   方針: SourceVaultEagleView/Dataset/Search/GeoView の出力は item の
   name/annotation/summary (私的写真のメタデータ) を含む「生データ」なので、
   表示 item の最大 PrivacyLevel をそのセルの PrivacyLevel として機密マークする
   (SourceVault_maildb.wl のメール View 自動機密マークと同じ枠組み)。
   PL の決定規則:
     item PL = summary record の "PrivacyLevel" (per-item 上書き、
               SourceVaultEagleSetSummaryPrivacy で設定)
               / 無ければ所属ライブラリの既定 ($SourceVaultEaglePrivacyLevel)
     セル PL = 表示 item の Max (結果が空ならライブラリ既定、失敗時 1.0)
   maildb ロード時は共有レジストリ $iSVConfidentialViewSpecRegistry に spec を
   登録するので、SourceVaultMarkConfidentialViewCells と
   SourceVaultMailEnableAutoConfidential のフックがそのまま Eagle View も扱う。
   maildb 無し環境向けに単独フック (SourceVaultEagleEnableAutoConfidential、
   再入ガード $iSVEGCtxReentry) も持つ。maildb の $iSVMailCtxReentry とは独立で、
   併用時も互いのガードを素通りして各 1 回ずつ走査され、マーク済みセルは
   触らないため二重マークは起きない。
   ════════════════════════════════════════════════════════ *)

(* 既定 PL 1.0 = fail-safe (クラウドはスキーマのみ / ローカル LLM は全文) *)
If[! ValueQ[$SourceVaultEaglePrivacyLevel], $SourceVaultEaglePrivacyLevel = 1.0];

(* ライブラリ既定 PL: 数値ならそのまま、Association なら 登録名 -> パス -> "Default"
   の順で引く。決められなければ 1.0 (安全側)。 *)
iSVEGLibraryPL[lib_String] :=
  Module[{spec = $SourceVaultEaglePrivacyLevel, norm = iSVEGNormPath[lib],
      names, cands},
    Which[
      NumericQ[spec], N[spec],
      AssociationQ[spec],
        names = Select[Keys[$iSVEGLibraries],
          iSVEGNormPath[Lookup[$iSVEGLibraries, #, ""]] === norm &];
        cands = Select[Join[
            (Lookup[spec, #, Missing[]] &) /@ names,
            Values@KeySelect[spec, Function[k,
              StringQ[k] && k =!= "Default" && iSVEGNormPath[k] === norm]],
            {Lookup[spec, "Default", Missing[]]}], NumericQ];
        If[cands === {}, 1.0, N@First[cands]],
      True, 1.0]];
iSVEGLibraryPL[_] := 1.0;

(* summary record を持つ id の集合 (ディレクトリ走査 1 回。item ごとの
   FileExistsQ 呼び出しを避ける) *)
iSVEGSummaryRecIdSet[] :=
  Module[{dir = Quiet@Check[FileNameJoin[{iSVEGStoreRoot[], "summaries"}], $Failed]},
    If[StringQ[dir] && DirectoryQ[dir],
      Association[(# -> True) & /@ (FileBaseName /@ FileNames["*.json", dir])],
      <||>]];

(* item 1 件の PL: summary record の "PrivacyLevel" 優先、無ければライブラリ既定 *)
iSVEGItemPL[item_, libPL_?NumericQ, recIdSet_Association] :=
  Module[{id = iSVEGItemId[item], rec, pl},
    If[! KeyExistsQ[recIdSet, id], Return[libPL]];
    rec = iSVEGImportJSON[iSVEGSummaryPath[id]];
    pl = If[AssociationQ[rec], Lookup[rec, "PrivacyLevel", Missing[]], Missing[]];
    If[NumericQ[pl], N[pl], libPL]];
iSVEGItemPL[___] := 1.0;

SourceVaultEagleSetSummaryPrivacy[itemSpec_, pl_?NumericQ] :=
  Module[{id, p, rec},
    id = If[AssociationQ[itemSpec], iSVEGItemId[itemSpec], ToString[itemSpec]];
    p = Quiet@Check[iSVEGSummaryPath[id], $Failed];
    rec = If[StringQ[p], iSVEGImportJSON[p], $Failed];
    If[! AssociationQ[rec],
      Return[<|"Status" -> "Error", "Reason" -> "NoSummary", "Id" -> id,
        "Hint" -> "summary record がありません。先に SourceVaultEagleSummarize[id] を実行するか、ライブラリ単位の $SourceVaultEaglePrivacyLevel を使ってください。"|>]];
    rec["PrivacyLevel"] = N[pl];
    If[iSVEGAtomicExportJSON[p, rec] === $Failed,
      <|"Status" -> "Error", "Reason" -> "WriteFailed", "Id" -> id|>,
      (iSVEGSummaryCachePut[id, rec];
       <|"Status" -> "Set", "Id" -> id, "PrivacyLevel" -> N[pl]|>)]];

(* 入力テキストが Eagle View 系呼び出しを含むか *)
iSVEGViewInputQ[text_String] :=
  StringContainsQ[text,
    RegularExpression["SourceVaultEagle(GeoView|View|Dataset|Search)\\s*\\["]];
iSVEGViewInputQ[_] := False;

(* View/Dataset/Search/GeoView を read-only に差し替えるプローブ: 同じ引数で
   SourceVaultEagleSearch (メモリ内キャッシュの選別のみ) を再実行し、表示 item の
   最大 PL を返す。View の既定 Limit は適用しないので superset を見ることになるが、
   過剰側 (安全側) にしかずれない。 *)
iSVEGPLProbe[query_String : "", opts : OptionsPattern[]] :=
  Module[{sopts, lib, items, libPL, recIds},
    sopts = FilterRules[Flatten[{opts}], Options[SourceVaultEagleSearch]];
    lib = iSVEGLib[Lookup[sopts, "Library", Automatic]];
    If[lib === $Failed, Return[1.0]];
    items = Quiet@Check[
      SourceVaultEagleSearch[query, Sequence @@ sopts, "Library" -> lib], $Failed];
    If[! ListQ[items], Return[1.0]];
    libPL = iSVEGLibraryPL[lib];
    If[items === {}, Return[libPL]];
    recIds = iSVEGSummaryRecIdSet[];
    Max[iSVEGItemPL[#, libPL, recIds] & /@ items]];
iSVEGPLProbe[___] := 1.0;

(* 入力テキストから View 呼び出しだけを抜き出してプローブ評価し、最大 PL を得る。
   入力全体は再評価しない (maildb の iSVMailCellMaxPLFromText と同じ方式)。
   失敗時は安全側 1.0。 *)
iSVEGCellMaxPLFromText[text_String] :=
  Module[{held, vals},
    held = Quiet@Check[ToExpression[text, InputForm, HoldComplete], $Failed];
    If[held === $Failed, Return[1.0]];
    vals = Quiet@Check[
      Cases[held,
        HoldPattern[(SourceVaultEagleView | SourceVaultEagleDataset |
            SourceVaultEagleSearch | SourceVaultEagleGeoView)[a___]] :>
          iSVEGPLProbe[a],
        {0, Infinity}], {}];
    If[ListQ[vals] && Length[vals] > 0 && AllTrue[vals, NumericQ], Max[vals], 1.0]];
iSVEGCellMaxPLFromText[_] := 1.0;

(* maildb の SourceVaultMarkConfidentialViewCells / 自動フックへの spec 登録
   (SourceVault`Private` 共有レジストリ。ロード順不問・再ロード冪等)。 *)
If[! ListQ[$iSVConfidentialViewSpecRegistry], $iSVConfidentialViewSpecRegistry = {}];
$iSVConfidentialViewSpecRegistry = Append[
  DeleteCases[$iSVConfidentialViewSpecRegistry, {iSVEGViewInputQ, _}],
  {iSVEGViewInputQ, iSVEGCellMaxPLFromText}];

(* 既存の機密/非機密タグ (True/False) は尊重し再マークしない (maildb と同じ規則) *)
iSVEGCellTaggedQ[nb_, i_] :=
  With[{t = Quiet@Check[NBAccess`NBGetConfidentialTag[nb, i], Missing[]]},
    t === True || t === False];

SourceVaultEagleMarkViewCells[nb_NotebookObject] :=
  Module[{n, lastIn = 0, lastInText = "", marked = {}},
    (* $iCellsCache は sticky なので走査前に必ず無効化 (maildb と同じ) *)
    Quiet@Check[NBAccess`NBInvalidateCellsCache[nb], Null];
    n = Quiet@Check[NBAccess`NBCellCount[nb], 0];
    If[! IntegerQ[n] || n <= 0, Return[{}]];
    Do[
      Module[{style = Quiet@Check[NBAccess`NBCellStyle[nb, i], ""]},
        Which[
          MemberQ[{"Input", "Code"}, style],
            lastIn = i;
            lastInText = Quiet@Check[NBAccess`NBCellReadInputText[nb, i], ""],
          style === "Output" && lastIn > 0 && StringQ[lastInText] &&
            ! iSVEGCellTaggedQ[nb, i] && iSVEGViewInputQ[lastInText],
            Module[{pl = iSVEGCellMaxPLFromText[lastInText]},
              If[! NumericQ[pl], pl = 1.0];
              (* 最大PL<=0.5 はクラウドでも全文可なのでマークしない *)
              If[pl > 0.5,
                Quiet@Check[NBAccess`NBMarkCellConfidential[nb, i, pl], Null];
                AppendTo[marked, <|"Cell" -> i, "PrivacyLevel" -> pl|>]]],
          True, Null]],
      {i, n}];
    marked];
SourceVaultEagleMarkViewCells[] :=
  With[{nb = Quiet@Check[EvaluationNotebook[], $Failed]},
    If[Head[nb] === NotebookObject, SourceVaultEagleMarkViewCells[nb], {}]];

(* ── NBMakeContextPacket 単独フック (opt-in。maildb 無し環境向け)。
   maildb のフックと同型の「再入ガード付き高優先 DownValue 追加」。ガード変数は
   $iSVEGCtxReentry で maildb の $iSVMailCtxReentry とは独立 (互いの
   Disable の DeleteCases にも掛からない)。 ── *)
If[! ValueQ[$iSVEGCtxHookInstalled], $iSVEGCtxHookInstalled = False];

SourceVaultEagleEnableAutoConfidential[] :=
  (If[! TrueQ[$iSVEGCtxHookInstalled],
     NBAccess`NBMakeContextPacket[nb_NotebookObject, spec_Association,
         o : OptionsPattern[]] /; ! TrueQ[$iSVEGCtxReentry] :=
       Block[{$iSVEGCtxReentry = True},
         Quiet@Check[SourceVaultEagleMarkViewCells[nb], Null];
         NBAccess`NBMakeContextPacket[nb, spec, o]];
     $iSVEGCtxHookInstalled = True];
   <|"Status" -> "Enabled", "Hook" -> "NBMakeContextPacket"|>);

SourceVaultEagleDisableAutoConfidential[] :=
  (If[TrueQ[$iSVEGCtxHookInstalled],
     DownValues[NBAccess`NBMakeContextPacket] =
       DeleteCases[DownValues[NBAccess`NBMakeContextPacket],
         _?(! FreeQ[#, $iSVEGCtxReentry] &)];
     $iSVEGCtxHookInstalled = False];
   <|"Status" -> "Disabled"|>);

End[];
EndPackage[];

(* ============================================================
   $ClaudePackageAuxKeywordMap への登録 (api_eagle.md 自動注入)

   ClaudeEval/ClaudeQuery のタスクに以下のキーワードが含まれると
   SourceVault の docs (api.md + api_eagle.md) がプロンプトに自動注入され、
   SourceVaultEagleSummarize / SourceVaultEagleSummarizeBatch 等が
   正しい関数名・オプションで提案されるようになる。
   このリストは「補助 api_eagle.md を注入する条件」も兼ねる
   (claudecode.wl iAuxApiRelevantQ)。Eagle 無関係のタスク (メール等)
   では api_eagle.md は注入されない。
   ============================================================ *)
If[AssociationQ[ClaudeCode`$ClaudePackageAuxKeywordMap],
  Module[{auxMap},
    auxMap = Lookup[ClaudeCode`$ClaudePackageAuxKeywordMap,
      "SourceVault", <||>];
    If[!AssociationQ[auxMap], auxMap = <||>];
    auxMap["eagle"] = {
      "Eagle", "イーグル",
      "SourceVaultEagle",   (* 全 Eagle 関数名を部分一致でカバー *)
      "サマリー", "summarize",
      "アノテーション", "annotation",
      "Exif", "スマートフォルダ"};
    ClaudeCode`$ClaudePackageAuxKeywordMap["SourceVault"] = auxMap]];
