# SourceVault_maildb API リファレンス

パッケージ: `SourceVault``
リポジトリ: https://github.com/transreal/SourceVault_maildb
ロード順: SourceVault_encryptedstore.wl → SourceVault_keys.wl → SourceVault_addressbook.wl → SourceVault_maildb.wl → SourceVault_imap.wl → SourceVault_mailui.wl
依存: [NBAccess](https://github.com/transreal/NBAccess), [SourceVault_core](https://github.com/transreal/SourceVault_core), [SourceVault_crypto](https://github.com/transreal/SourceVault_crypto), [SourceVault_identity](https://github.com/transreal/SourceVault_identity)

旧 [maildb_legacy](https://github.com/transreal/maildb_legacy) の月次 .wl record を SourceVaultMailSnapshot に正規化するアダプタ。IMAP 新着取得・ローカル LLM 派生処理・FE UI を含む。

## スナップショット構造

snapshot は Association。主要キー:
- `"RecordId"` — keyed HMAC (SourceVault:mailid:mac:v1)
- `"MailMetadataPublic"` — `<|"Date", "Subject", "From", "To", "Cc", "AttachmentCount", "Attachments"|>`
- `"MailSource"` — `<|"MBox", "MessageIDToken"|>`
- `"Derived"` — `<|"Priority", "PriorityComponents", "WorkRequest", "PrivacyLevel", "Category", "Deadline", "Summary", "DerivedStatus", "DerivedSource", "DerivedEnrichment"|>`
- `"AddressBookRefs"` — `<|"FromContact", "FromIdentifier"|>`

`Derived.DerivedStatus`: `"Pending"` | `"Processed"`。DerivedStatus なし + Summary 空も Pending 扱い。

## maildb → スナップショット変換

### SourceVaultMailSnapshotFromMaildb[record_Association, mbox_String, opts] → Association
旧 maildb record を SourceVaultMailSnapshot に変換する。body は暗号化、PL は fail-safe (既定 0.85)。From/To/Cc を AddressBook に照合。
Options: "EncryptHeaders" -> False (True でヘッダ subject/from/to も暗号化、Dropbox 非前提時に使う)

### SourceVaultImportMaildbFile[file_String, mbox_String, opts] → Association
旧 maildb 月次 .wl を読み、各 record を MailSnapshot に変換する。
→ `<|"Status", "Imported", "Skipped"|>`
Options: "Persist" -> True

## スナップショット CRUD

### SourceVaultMailSnapshotPut[snapshot, opts] → Association
snapshot を RecordId をキーに store へ保存 (冪等)。
Options: "Persist" -> True

### SourceVaultMailSnapshotGet[recordId_String] → Association | Missing
保存済み snapshot を返す。未登録は Missing。

### SourceVaultMailSnapshotList[] → List
ロード済み全 snapshot のリストを返す。

### SourceVaultMailSnapshotDecryptBody[snapshot_Association] → Association
snapshot の暗号化 body を復号して返す (MAC 検証経由)。
→ `<|"Status"->"Ok", "Body"->String|>` または `<|"Status"->"Error", "Reason"->...|>`

### SourceVaultMailParseEmails[headerValue_String] → List
ヘッダ文字列からメールアドレス文字列のリストを抽出する。

## ストア・シャード管理

### $SourceVaultMailStoreRoot
型: String, 初期値: PrivateVault/mail/snapshots
mail snapshot store のルート。テストで上書き可。

### SourceVaultMailStoreRoot[] → String
snapshot store のルートパスを返す。

### SourceVaultMailStorePath[] → String
旧単一ファイル snapshots.svmail のパスを返す (移行用)。

### SourceVaultMailShardPath["mbox/yyyymm"] → String
月次シャードのパスを返す。

### SourceVaultMailAvailableShards[mbox_:All] → List
ディスク上のシャード `{mbox, yyyymm}` の一覧をロードせずに返す。

### SourceVaultMailLoadShard["mbox/yyyymm"] → Association
1シャードをロードする。

### SourceVaultMailEnsureLoaded[mbox_String, period_:Automatic] → Association
指定 mbox の期間分シャードだけをメモリへ遅延ロードする。既ロードは再読込しない。
period: `"YYYYMM"` | `{from, to}` | `"Latest"` / Automatic | n (直近 n 月) | All

### SourceVaultMailStoreLoad[] → Association
全シャードを読み込む (重い)。通常は SourceVaultMailEnsureLoaded で必要分だけ遅延ロードする。

### SourceVaultMailStoreSave["All"->False] → Association
変更のあった月次シャードのみ (All->True で全シャード) を byte-exact 保存する。

### SourceVaultMailUnloadAll[] → Association
メモリ上の snapshot を解放する。

### SourceVaultMailLoadedCount[] → Integer
現在メモリにある snapshot 数を返す。

### SourceVaultMailMigrateToShards[] → Association
旧単一ファイル snapshots.svmail を mbox×月のシャードに移行し、旧ファイルを .bak にする。

## カテゴリ語彙・検索

### $SourceVaultMailCategories
メール派生カテゴリの語彙 (Association)。
トークン: `"InfoProvision"` (情報提供), `"AttendanceRequest"` (出席依頼), `"TaskRequest"` (作業依頼), `"Confirmation"` (確認・承認), `"Report"` (報告), `"Notice"` (通知・一斉配信・広告), `"Other"` (その他)。
`Derived.Category` および検索オプション `"Category"` で使う。日本語名でも指定可。

### SourceVaultSearchMailSnapshots[query_String:"", opts] → List
subject/summary 部分一致 + フィールドフィルタで snapshot を検索し、リストを返す。
Options:
- "From" -> All (送信者メールアドレス)
- "To" -> All
- "FromContact" -> All (AddressBook の ContactId)
- "MBox" -> All
- "DateFrom" -> Automatic (DateObject/文字列/{y,m,d}、日単位包含)
- "DateTo" -> Automatic
- "HasAttachment" -> Automatic (True/False)
- "Category" -> All ($SourceVaultMailCategories トークンまたは日本語名)
- "HasDeadline" -> Automatic (True/False)
- "DeadlineFrom" -> Automatic (〆切日範囲、日単位包含)
- "DeadlineTo" -> Automatic
- "Newest" -> True (日付降順)
- "Limit" -> All
- "SortBy" -> "Date" ("Date"|"Priority"|"PrivacyLevel"|"Deadline")

例: `SourceVaultSearchMailSnapshots["", "Category"->"TaskRequest", "DeadlineFrom"->Today, "DeadlineTo"->weekEnd]`

### SourceVaultMailSummaryRow[snapshot_Association] → Association
一覧表示用の低漏洩行を返す。
→ `<|"Date", "From", "Subject", "Category", "Deadline", "Attach", "MBox", "RecordId", "BodyEncrypted"|>`
From は AddressBook 解決時は表示名。Deadline は ISO 文字列または Missing。

### SourceVaultMailSearchSummary[query_String:"", opts] → List
検索結果を SummaryRow のリスト (新着順・Limit 適用) で返す。opts は SourceVaultSearchMailSnapshots と同じ。

### SourceVaultMailDataset[query_String:"", opts] → Dataset
検索結果を素の Dataset で返す (列ソート用、ボタン無し)。opts は SourceVaultSearchMailSnapshots と同じ。

### SourceVaultIdentityBackfillFromMail[] → Association
ロード済み snapshot の平文 From/To/Cc を走査して識別子 (2層アドレス帳) を一括生成する。再取込不要。スコープは先に SourceVaultMailEnsureLoaded で決める。

## 変数

### $SourceVaultDefaultImportedMailPL
型: Real, 初期値: 0.85
import 時のメール本文 PL 既定 (fail-safe)。maildb privacy フィールドは信用しない。

## IMAP 取得

### SourceVaultMailFetchNew[mbox_String, opts] → Association
IMAP から新着のみ取得し snapshot 化して store に保存する。RecordId で重複排除。既定は LLM 処理なし。
→ `<|"Status", "Fetched", "Skipped", "Errors"|>`
Options:
- "Period" -> "Latest" ("Latest" | n日 | {from,to} | "YYYYMM")
- "Process" -> False (True で取込時に LLM 派生も実行)
- "MessageSource" -> Automatic (実 IMAP。テスト用 fake 注入可)
- "Inferencer" -> Automatic (実 LLM。テスト用 fake 注入可)
- "Persist" -> True
- "MaxEmails" -> Infinity

## 派生処理 (ローカル LLM)

### SourceVaultMailDerivedPendingQ[snapshot_Association] → True | False
派生が未処理 (DerivedStatus="Pending" または DerivedStatus 無しで Summary 空) なら True。

### SourceVaultMailDerivedPending[] → List
ロード済み store の中で派生未処理の snapshot リストを返す。

### SourceVaultMailInferDerived[mailspec_Association] → Association
mailspec (date/subject/from/to/cc/body) からローカル LLM (LM Studio, OpenAI 互換) で派生を生成する。
→ `<|"Status"->"Ok"|"Error", "WorkRequest"->0.0~1.0, "PrivacyLevel"->0.0~1.0, "Category"->token, "Deadline"->ISO文字列|Missing["None"], "Summary"->String|>`

### SourceVaultInferMailDerivedBatch[opts] → Association
未処理 snapshot の派生をローカル LLM で増分生成し in-place 更新する。CheckpointEvery 件ごとに dirty シャードを保存する中断耐性あり。
→ `<|"Status", "Processed", "Skipped", "Errors"|>`
Options:
- "Limit" -> 50 (フィルタ後の件数上限。全件は Infinity)
- "DateFrom" -> Automatic
- "DateTo" -> Automatic
- "Refresh" -> None (None=Pending のみ / "MissingCategory"=Category 未生成の処理済みも再処理 / All=全件再処理 / Function=述語一致を再処理)
- "Inferencer" -> Automatic (テスト用 fake 注入可)
- "CheckpointEvery" -> 20
- "Persist" -> True

例: `SourceVaultInferMailDerivedBatch["Refresh"->Function[s, StringContainsQ[ToString@s["MailMetadataPublic"]["Subject"], "Cerezo"]], "Limit"->Infinity]`

## mailspec Enricher

### SourceVaultRegisterMailspecEnricher[name_String, f_] → Association
派生時に LLM へ渡す mailspec を拡張する enricher を登録する。f[mailspec, snapshot] → Association。非該当/失敗時は mailspec をそのまま返す。保存レコード形式には影響せず、Derived.DerivedEnrichment に名前が記録される。

### SourceVaultUnregisterMailspecEnricher[name_String] → Association
mailspec enricher の登録を解除する。

### SourceVaultMailspecEnrichers[] → List
登録済み mailspec enricher 名のリストを返す。

## 優先度計算

### SourceVaultMailComputePriority[snap_Association, workRequest_:Missing[], category_:Missing[]] → Association
構造シグナル (送信者グループ重み + To/Cc 位置 + 一斉配信判定 + LLM 依頼度 + カテゴリ) から重要度を決定的に計算する。category="Notice" なら -0.30 減点。
→ `<|"Priority"->0.0~1.0, "Components"-><|"SenderWeight","OwnerPosition","Bulk","WorkRequest","Category","PositionAdj","BulkAdj","CategoryAdj"|>|>`

### SourceVaultMailExplainPriority[snap_Association] → Association
snapshot の保存済み WorkRequest/Category を使って重要度の内訳を返す。SourceVaultMailComputePriority と同じ構造。

### SourceVaultMailRecomputePriorities[opts] → Association
ロード済み snapshot のうち PriorityComponents を持つもの (SourceVault 構造計算由来) について、Priority を LLM なしで再計算し in-place 更新する。legacy maildb 由来 (PriorityComponents 無し) は変更しない。
→ `<|"Status", "Eligible", "Recomputed", "Total"|>`
Options: "Persist" -> True

## グループ重み

### SourceVaultSetPriorityGroupWeight[group_String, weight_?NumericQ, opts] → Association
グループの優先度重み (0.0~1.0) を登録し vault config に保存する。送信者実体の Group フィールドで照合される。
Options: "Persist" -> True

### SourceVaultPriorityGroupWeights[] → Association
登録済みグループ重みの Association (group -> weight) を返す。

### SourceVaultGroupWeightFor[group_] → Real | Missing
グループの重みを返す。未登録は Missing["NotSet"]。

### SourceVaultPriorityGroupsLoad[] → Association
グループ重み config を vault config から読み込む。

## IMAP アカウント管理

### $SourceVaultMailConfigRoot
型: String, 初期値: PrivateVault/config
IMAP アカウント設定の保存ルート。テストで上書き可。

### SourceVaultRegisterMailAccount[assoc_Association, opts] → Association
IMAP アカウント設定を登録し vault config に保存する。パスワードは保存せず CredKey (SystemCredential 名) のみ。同一 MBox は上書き。
assoc 必須キー: `"MBox"`, `"CredKey"`, `"Server"`。省略可: `"User"`, `"Email"`, `"Port"` (既定 993)。
Options: "Persist" -> True
→ `<|"Status"->"Registered"|"Error", "MBox"|>`

### SourceVaultMailAccounts[] → Dataset
登録済み IMAP アカウント設定を Dataset で返す (パスワードは含まない)。

### SourceVaultGetMailAccount[mbox_String] → Association | Missing
登録済みアカウント設定を返す。未登録は Missing["NotRegistered"]。

### SourceVaultRemoveMailAccount[mbox_String, opts] → Association
アカウント登録を削除する。
Options: "Persist" -> True

### SourceVaultMailAccountsLoad[] → Association
vault config からアカウント設定を読み込む。

## UI (front end 必須の関数)

### $SourceVaultLegacyMailRoot
型: String, 初期値: PrivateVault/../mails
旧 maildb のメールルート (添付ディレクトリの親)。

### $SourceVaultMailNotebookStyle
型: String, 初期値: "SourceVault default.nb"
本文表示・返信ノートブックの StyleDefinitions。

### $SourceVaultMailViewMaxRows
型: Integer | Symbol, 初期値: 25
メール一覧 Dataset が一度に描画する最大行数。All で無制限。Windows FrontEnd の重さ対策。

### SourceVaultMailGetBody[recordId_String | snap_Association] → Association
snapshot の暗号化本文を復号して文字列で返す (headless 可)。
→ `<|"Status"->"Ok", "Body"->String|>` または `<|"Status"->"Error", "Reason"->...|>`

### SourceVaultMailShowBody[recordId_String | snap_Association] → Association
本文を新規ノートブックで表示する (front end)。復号失敗時は理由をノートブックに表示。

### SourceVaultMailAttachmentDir[mbox_String, yyyymm_String] → String
旧 maildb 添付ディレクトリのパスを返す (パスのみ、存在確認なし)。

### SourceVaultMailAttachments[recordId_String | snap_Association] → List
添付 `{<|"Name", "Path", "Exists"|>}` のリストを返す。添付名が snapshot にない旧形式は再 import を促す Association を返す。

### SourceVaultMailOpenAttachment[recordId_String | snap_Association, name_String] → Association
添付ファイルを SystemOpen で開く (front end)。
→ `<|"Status"->"Opened"|"Error", ...|>`

### SourceVaultMailComposeReply[recordId_String | snap_Association, opts] → Association
返信ドラフトを生成する (headless テスト可)。オーナー自身は Cc から除外される。
→ `<|"Status"->"Draft", "To", "Cc", "Subject", "InReplyToToken", "Quoted", "Body", "RecordId"|>`
Options: "ReplyAll" -> False, "Body" -> ""

### SourceVaultMailOpenReplyNotebook[recordId_String | snap_Association, opts] → Association
返信ドラフトのノートブックを開く (front end)。opts は SourceVaultMailComposeReply と同じ。

### SourceVaultMailRowActions[snapshot_Association] → Row
1行分のアクション (本文✉ / 添付 / 返信↩ ボタン) を返す。SourceVaultMailView の各行用。

### SourceVaultMailView[query_String:"", opts] → Dataset | Style
検索結果を本文表示/添付/返信の操作ボタン付き表 (Dataset) で返す。旧 maildb showMails 踏襲。opts は SourceVaultSearchMailSnapshots と同じ。表示行数は $SourceVaultMailViewMaxRows で制限。PL >= 0.5 のメールを含む場合は Confidential 値として返す。

### SourceVaultAddressBookView[] → Dataset | Style
連絡先を整形表 (Dataset) で表示する。列: Uid/表示名/かな/メール/分類/信頼/MaxPL/AccessTags。

### SourceVaultIdentityLinkUI[opts] → DynamicModule
識別子を実体に紐付ける編集表 (front end)。各行で 新規 (ヘッダ継承で実体作成) / マージ (既存実体にアドレス追加) を実行できる。
Options: "ShowLinked" -> False (True で既リンクも表示), "Limit" -> 200

### SourceVaultEntityView[] → Dataset | Style
実体 (人/組織/Bot/ML) の一覧表 (Dataset)。各行に編集ボタン。列: Uid/種別/表示名/かな/識別子数/グループ/重み。

### SourceVaultEntityEditUI[entityIdOrUid] → Dynamic
実体1件の編集フォーム (front end)。表示名/種別/漢字/ローマ字/かな/分類/グループ/重み/所属/信頼を編集し保存。

## 機密マーク

### SourceVaultMarkConfidentialViewCells[nb_:EvaluationNotebook[]] → List
notebook 内の「生データを表示する出力セル」(SourceVaultMailView / MailDataset / MailSearchSummary、Todo 生テキスト) を最大プライバシーで機密マークする。クラウド LLM (閾値0.5) にはスキーマのみ、ローカル LLM (閾値1.0) には全文。SourceVault_eagle.wl ロード時は Eagle View 等も対象。サマリー/予定表は対象外。
→ `{<|"Cell"->idx, "PrivacyLevel"->pl|>...}`

### SourceVaultMailMarkViewCells[nb_:EvaluationNotebook[]] → List
SourceVaultMarkConfidentialViewCells の別名 (後方互換)。

### SourceVaultMailEnableAutoConfidential[] → Null
NBAccess`NBMakeContextPacket にフックを装着し、ClaudeEval/ClaudeQuery の文脈構築直前に SourceVaultMarkConfidentialViewCells を自動実行する。冪等。

### SourceVaultMailDisableAutoConfidential[] → Null
SourceVaultMailEnableAutoConfidential[] で装着したフックを解除し、NBMakeContextPacket を元に戻す。