# SourceVault_maildb API リファレンス

## 概要
SourceVault mail サブシステム。旧 maildb (maildb_legacy.wl) の月次 .wl レコードを `SourceVaultMailSnapshot` に正規化し、暗号化ストア (shard 単位) へ保存・検索・表示・返信するアダプタ層。context は `SourceVault`。依存: NBAccess。ロード順は `... → SourceVault_encryptedstore.wl → SourceVault_keys.wl → SourceVault_addressbook.wl → SourceVault_maildb.wl → SourceVault_messagerelease.wl → SourceVault_mailui.wl`。IMAP 新着取得と派生生成は SourceVault_imap.wl が担う。

設計上の要点:
- RecordId / MessageIDToken は keyed HMAC (`SourceVault:mailid:mac:v1`)。RecordId は `svmail-` 接頭辞付き。
- body は `SourceVaultEncryptedPut` で暗号化 (inline)。PrivacyLevel は fail-safe (既定 0.85)。maildb privacy(0/1) は provenance のみで release/cloud 判定の真実源にしない。
- header (subject/from/to) は既定で平文 + token (Dropbox 前提)。`EncryptHeaders->True` で暗号化。
- 本文は ingest 時に「読める平文」へ正規化 (改行 LF 統一・HTML→テキスト化)。HTML 原文は BodyRaw に温存。
- ストアは `<root>/<mbox>/<yyyymm>.svmail` の月次 shard + 並置の軽量メタデータ索引 `.svmailidx` sidecar。索引は本文暗号文を含まず、ロードせず検索できる。
- Category は `$SourceVaultMailCategories` のトークン。Derived に PL/優先度/概要/Category/Deadline を格納。
- privacy > 0.5 のメールは `$ClaudePrivateModel` (ローカル LLM) へルーティング。

旧 maildb.wl は参照専用。新規コードでは本パッケージの公開 API を使う。関連: SourceVault_imap, SourceVault_mining, SourceVault_addressbook, SourceVault_mcp, SourceVault_searchindex。

## Ingest / 変換
### SourceVaultMailSnapshotFromMaildb[record_Association, mbox_String, opts]
旧 maildb record を SourceVaultMailSnapshot に変換する。body は暗号化、PL は fail-safe。HTML 本文はテキスト化して Body に格納し原文を BodyRaw に温存。id/subject/from/to/cc/body/privacy/rawheader キーを読む。
→ Association (snapshot)
Options: "PrivacyLevel" -> Automatic (Automatic は $SourceVaultDefaultImportedMailPL), "EncryptHeaders" -> False (True で header 暗号化), "StoreBody" -> "Encrypted"

### SourceVaultImportMaildbFile[file_String, mbox_String, opts]
旧 maildb 月次 .wl を読み、各 record を MailSnapshot に変換する。
→ snapshot のリスト
Options: "Persist" -> True (True で snapshot store に保存)

### SourceVaultMailParseEmails[headerValue_String] → {String..}
ヘッダ文字列からメールアドレスを抽出する。

## スナップショット保存・取得
### SourceVaultMailSnapshotPut[snapshot, opts] → RecordId
snapshot を RecordId をキーに store へ保存 (冪等)。

### SourceVaultMailSnapshotGet[recordId] → Association
保存済み snapshot を返す。

### SourceVaultMailSnapshotList[] → {Association..}
保存済み (ロード済み) snapshot を返す。

### SourceVaultMailSnapshotDecryptBody[snapshot] → String
snapshot の暗号化 body を復号して返す (MAC 検証経由)。

### SourceVaultBackfillMailBodies[opts]
ロード済み snapshot のうち本文が HTML の旧 record を、読める平文へ変換して再格納する (原文は BodyRaw に温存、MailMetadataPublic["BodyWasHTML"]->True)。要約再生成は別途 SourceVaultInferMailDerivedBatch["Refresh"->...] を実行。
→ 集計 Association
Options: "Limit" -> Infinity, "DryRun" -> False (True で件数だけ数え書込まない), "Persist" -> True, "CheckpointEvery" -> 20

### SourceVaultIdentityBackfillFromMail[]
現在ロード済み snapshot の平文 From/To/Cc を走査し識別子 (2層アドレス帳) を一括生成する。再取込不要。対象はスコープを先に `SourceVaultMailEnsureLoaded` で決める。
→ 集計 Association

## ストア / shard 管理
### SourceVaultMailStoreRoot[] → String
snapshot store のルートを返す。

### $SourceVaultMailStoreRoot
型: String, 初期値: PrivateVault/mail/snapshots
mail snapshot store のルート。テストで上書き可。

### SourceVaultMailStorePath[] → String
旧単一ファイル (移行用) のパスを返す。

### SourceVaultMailShardPath["mbox/yyyymm"] → String
月次 shard (.svmail) のパスを返す。

### SourceVaultMailStoreSave[opts]
変更のあった月次シャードのみを byte-exact 保存する。索引 sidecar (.svmailidx) も自動更新。
→ 保存 shard 数
Options: "All" -> False (True で全シャード保存)

### SourceVaultMailStoreLoad[] → Integer
全シャードを読み込む (重い)。通常は SourceVaultMailEnsureLoaded で必要分だけ遅延ロードする。

### SourceVaultMailAvailableShards[mbox_:All] → {{mbox, yyyymm}..}
ディスク上のシャード一覧をロードせずに返す。

### SourceVaultMailEnsureLoaded[mbox_String, period_:Automatic] → Integer
指定 mbox の期間分シャードだけをメモリへ遅延ロードする。既ロードは再読込しない。
period: "YYYYMM" | {from,to} | "Latest"/Automatic | n(直近n月, 整数) | All。
例: SourceVaultMailEnsureLoaded["univ", 3]

### SourceVaultMailLoadShard["mbox/yyyymm"] → Integer
1 シャードをロードする。

### SourceVaultMailUnloadAll[]
メモリ上の snapshot を解放する。

### SourceVaultMailLoadedCount[] → Integer
現在メモリにある snapshot 数を返す。

### SourceVaultMailMigrateToShards[]
旧単一ファイル snapshots.svmail を mbox×月のシャードに移行し、旧ファイルを .bak にする。

## 軽量メタデータ索引 (sidecar)
本文暗号文をロードせず検索する仕組み。各 shard 並置の `.svmailidx` (1行 = BinarySerialize した索引行: SummaryRow 形 + Summary + FromRaw/ToRaw/FromContact/AttachmentCount/AccessTags/ShardKey)。SourceVaultMailStoreSave 時に自動更新。
### SourceVaultMailSearchIndex[query_String:"", opts]
ディスク上の索引 sidecar だけを走査し、snapshot 本体をロードせず低漏洩メタ/サマリー行 (SummaryRow 形 + Summary) を返す。年単位の全メールロード不要で検索できる。
→ {Association..}
Options: SourceVaultSearchMailSnapshots と同じ (To/Cc/FromContact 等 index 非保持の項目は無視)

### SourceVaultMailRebuildMetadataIndex[mbox_:All] → Integer
ディスク上の各 shard を一時的に読み、索引 sidecar (.svmailidx) を再生成する ($iSVMDStore は変更しない)。既存 .svmail からの初回構築/再構築に使う。

### SourceVaultMailIndexedCount[mbox_:All] → Integer
ディスク上の索引 sidecar に含まれる行数 (索引済みメール数) を返す。

### SourceVaultMailIndexGet[recordId_String] → Association | Missing["NotFound"]
索引 sidecar から該当 RecordId の低漏洩メタ/サマリー行を1件返す (snapshot 本体はロードしない)。MCP の単一 URI 解決 (sourcevault_get) 用。

## 検索・一覧
### SourceVaultSearchMailSnapshots[query_String:"", opts]
subject/summary 部分一致 + 各種条件で検索。Newest で日付降順、Limit で件数制限。要 EnsureLoaded (ロード済み snapshot が対象)。
→ {snapshot..}
Options: "From", "To", "FromContact", "MBox", "DateFrom", "DateTo", "HasAttachment", "Category" ($SourceVaultMailCategories のトークン。日本語名 "作業依頼" 等でも可), "HasDeadline", "DeadlineFrom", "DeadlineTo" (〆切を日単位包含で範囲指定), "Newest" -> True (日付降順), "Limit", "SortBy" ("Date"|"Priority"|"PrivacyLevel"|"Deadline")
例: SourceVaultSearchMailSnapshots["", "Category"->"TaskRequest", "DeadlineFrom"->今日, "DeadlineTo"->週末]

### SourceVaultMailSummaryRow[snapshot] → Association
一覧表示用の低漏洩行 <|Date, From, Subject, Category, Deadline, Attach, MBox, RecordId, BodyEncrypted|> を返す。From は AddressBook 解決時は表示名。Category は依頼カテゴリトークン。Deadline は〆切 ISO 文字列 (無ければ Missing)。

### SourceVaultMailSearchSummary[query_String:"", opts] → {Association..}
検索結果を SummaryRow のリスト (新着順・Limit 適用) で返す。opts は SourceVaultSearchMailSnapshots と同じ。

### SourceVaultMailDataset[query_String:"", opts] → Dataset
検索結果を素の Dataset で返す (列ソート用、ボタン無し)。opts は SourceVaultSearchMailSnapshots と同じ。

### $SourceVaultMailCategories
型: Association (トークン→説明), 
メール派生カテゴリの語彙: InfoProvision=情報提供, AttendanceRequest=出席依頼, TaskRequest=作業・仕事の依頼, Confirmation=確認・承認依頼, Report=報告, Notice=通知・一斉配信, Other=その他。Derived.Category と検索オプション "Category" で使う。

## 操作記録 (開封回数 / 返信済)
記録は `<storeRoot>/interaction.json` (Dropbox 共有、RecordId キー、本文・ヘッダは含めない)。
### SourceVaultMailInteractionStats[recordId] → Association
そのメールの操作記録 <|"OpenCount","LastOpened","RepliedCount","RepliedAt"|> を返す。
### SourceVaultMailInteractionStats[] → Association
全件 (RecordId キー) を返す。

## IMAP 取得・派生 (SourceVault_imap.wl)
### SourceVaultMailFetchNew[mbox, opts]
IMAP から新着のみ取得し snapshot 化して store に保存する。既定は LLM 処理なし。RecordId で既存と重複排除。
→ 集計 Association
Options: "Period" ("Latest"|n日|{from,to}|"YYYYMM"), "Process" -> False, "MessageSource" -> 実IMAP (注入可), "Inferencer", "Persist" -> True, "MaxEmails"

### SourceVaultMailDerivedPending[opts]
ロード済み store のうち派生 (PL/優先度/概要) 未処理の snapshot を返す。
→ {snapshot..}
Options: "MBox" -> Automatic (文字列でその mbox に限定), "DateFrom" -> Automatic, "DateTo" -> Automatic (DateObject/文字列/{y,m,d}、日単位包含)

### SourceVaultMailDerivedPendingQ[snapshot] → Bool
派生が未処理 ("Pending") なら True。

### SourceVaultInferMailDerivedBatch[opts]
未処理 snapshot の派生をローカル LLM で増分生成し in-place 更新する。中断耐性 (CheckpointEvery 件ごとに保存)。
→ 集計 Association
Options: "MBox" -> Automatic (文字列で mbox 限定, Automatic=ロード済み全 mbox), "Limit" -> 50 (フィルタ後件数上限, 範囲内すべてなら Infinity), "DateFrom" -> Automatic, "DateTo" -> Automatic, "Refresh" -> None (None=Pending のみ, "MissingCategory"=Category 未生成の処理済み旧も再処理, All=全件再処理, Function=述語一致を再処理), "Inferencer" -> 実LLM (注入可), "CheckpointEvery" -> 20, "Persist" -> True
例: SourceVaultInferMailDerivedBatch["Refresh"->Function[s, StringContainsQ[ToString@s["MailMetadataPublic"]["Subject"], "Cerezo"]]]

### SourceVaultMailInferDerived[mailspec] → Association
mailspec (date/subject/from/to/cc/body) からローカル LLM で <|WorkRequest, PrivacyLevel, Category, Deadline, Summary, Status|> を返す (優先度は構造的に別計算)。Category は $SourceVaultMailCategories のトークン、Deadline は ISO 文字列または Missing["None"]。

### SourceVaultMailAddSummaries[mbox_String, period_:"Latest", opts]
mbox の指定期間メールを SourceVaultMailEnsureLoaded でロードしてから、その mbox の未処理 snapshot の派生 (概要/カテゴリ/優先度) を付ける。EnsureLoaded を内包し外部ジョブでも自己完結。opts は SourceVaultInferMailDerivedBatch と同じ。
→ 集計 Association

## 本文・添付・返信・送信 (SourceVault_mailui.wl)
### SourceVaultMailGetBody[recordId] → Association
snapshot の暗号化本文を復号して <|"Status","Body",...|> で返す (Status="Ok" 判定して Body を使う)。

### SourceVaultMailShowBody[recordId]
本文を新規ノートブックで表示する (front end)。

### SourceVaultMailAttachmentDir[mbox, yyyymm] → String
旧 maildb 添付ディレクトリ `<legacyRoot>/<mbox>/<yyyymm>_attachment/` のパスを返す。

### SourceVaultMailAttachments[recordId] → {Association..}
添付 {Name, Path, Exists} のリストを返す。

### SourceVaultMailOpenAttachment[recordId, name]
添付ファイルを開く (front end / SystemOpen)。

### SourceVaultMailComposeReply[recordId, opts]
返信ドラフト <|To,Cc,Subject,InReplyToToken,Quoted,Body|> を生成する。
→ Association
Options: "ReplyAll" -> False (True で Cc 含む)

### SourceVaultMailOpenReplyNotebook[recordId, opts]
返信用ウインドウ (To/Cc/件名/本文編集・ファイル添付・確認付き送信) を開く (front end)。
Options: "ReplyAll" -> False (True で全員返信), "Translate" -> False (True で日本語で書いて元メールの言語へ翻訳送信)

### SourceVaultMailView[query_String:"", opts] → Dataset
検索結果を、行ごとに 本文表示/添付ポップアップ/返信 のクリック操作を備えた表 (Dataset) で返す。旧 maildb showMails 踏襲。opts は検索系と同じ。

### SourceVaultMailSearchIndexView[query_String:"", opts] → Dataset
SourceVaultMailSearchIndex (sidecar 索引検索、シャード非ロード) の View 版。行ごとに 本文 (必要シャードを遅延ロードして表示)/スレッド ボタンを備える。表示件数は $SourceVaultMailViewMaxRows で制限。EnsureLoaded 不要 (索引 sidecar 必須: 無ければ SourceVaultMailRebuildMetadataIndex[] で構築)。opts は SourceVaultMailSearchIndex と同じ。

### SourceVaultMailThreadNotebook[recordIdOrRow, opts]
スレッド全体 (同一正規化件名・同一 MBox) を 1 ノートブック窓にアウトライン表示する (front end)。各メール = Section セル + 本文 Text セルのセルグループ。索引 sidecar でメンバーを特定し必要シャードだけ遅延ロードして復号。セルは最大 PrivacyLevel で機密マーク。
→ <|Status, Mails, PrivacyLevel, LoadedShards|>
Options: "MaxMails" -> 50

### SourceVaultMailRowActions[snapshot]
1行分のアクション (Body/Attachments/Reply ボタン) を返す。

### SourceVaultMailSend[spec]
メールを送信する。spec は <|To, Cc, Subject, Body, ...|> 形。

### SourceVaultMailTranslateBody[record] → Association
外国語メール本文を読み手言語 ($Language) へ翻訳して返す (headless)。HTML/改行は readable 化してから翻訳。
→ 成功時 <|"Status"->"Ok","Text","Translated"->True,"Lang"|>、失敗時 <|"Status"->"Error","Reason","Lang"|>

## 変数・既定値
### $SourceVaultDefaultImportedMailPL
型: Real, 初期値: 0.85
import 時のメール本文 PL 既定 (fail-safe)。maildb privacy は信用しない。

### $SourceVaultMailPersonalPrivacyFloor
型: Real, 初期値: 0.6
個人宛メール (オーナーが直接の To/Cc・非 bulk・少数宛) の派生 PrivacyLevel 下限。LLM 推論が個人メールの privacy を下げ過ぎるのを防ぐ決定的 defense-in-depth。0.0 で無効化。

### $SourceVaultMailSignature
型: String, 初期値: ""
返信・送信の署名。

### $SourceVaultMailSendBccSelf
型: Bool, 初期値: True
送信時に自分を Bcc に入れるか。