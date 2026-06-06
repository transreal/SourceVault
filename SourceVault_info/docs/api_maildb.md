# api_maildb.md — SourceVault_maildb API リファレンス

SourceVault パッケージ群の mail サブシステム。旧 maildb の月次 .wl record を `SourceVaultMailSnapshot` に正規化し、暗号化保存・検索・派生(PL/優先度/概要)・FE 操作を提供する。`BeginPackage["SourceVault`", {"NBAccess`"}]`。snapshot adapter・IMAP 取得+派生・mail FE 操作はすべて `SourceVault_maildb.wl` に統合済み (旧 SourceVault_imap/mailui.wl は廃止)。
依存パッケージ: [NBAccess](https://github.com/transreal/NBAccess)、[SourceVault](https://github.com/transreal/SourceVault)、[SourceVault_identity](https://github.com/transreal/SourceVault_identity)、[maildb_legacy](https://github.com/transreal/maildb_legacy)。

設計原則:
- RecordId / MessageIDToken は keyed HMAC (`SourceVault:mailid:mac:v1`)。
- body は `SourceVaultEncryptedPut` で暗号化保存。PL は fail-safe (既定 0.85)。maildb の privacy(0/1) は provenance のみで release/cloud 判定の真実源にしない。
- snapshot は mbox×月のシャードに分割保存。`SourceVaultMailEnsureLoaded` で必要分だけ遅延ロードする。
- 取り込み(IMAP) と派生処理(ローカル LLM) は完全分離。派生は後から増分バッチ。
- IMAP / LLM は注入可能 (`"MessageSource"` / `"Inferencer"`)。テストは fake を注入して headless 検証。

## snapshot 変換・取込

### SourceVaultMailSnapshotFromMaildb[record_Association, mbox_String, opts]
旧 maildb record を `SourceVaultMailSnapshot` に変換する。body は暗号化、PL は fail-safe。RecordId/MessageIDToken は keyed HMAC、From/To/Cc を AddressBook に照合 (AddressBookRefs)、ヘッダは既定平文+token、添付は件数のみ。
→ Association (snapshot)
Options: `EncryptHeaders -> False` (True で subject/from/to を暗号化), PL 既定は `$SourceVaultDefaultImportedMailPL`。

### SourceVaultImportMaildbFile[file_String, mbox_String, opts]
旧 maildb 月次 .wl を読み、各 record を MailSnapshot に変換する。
→ Association (取込サマリ)
Options: `Persist -> True` (snapshot store に保存)。

### SourceVaultMailParseEmails[headerValue_String] → {String...}
ヘッダ文字列からメールアドレスを抽出する。

### $SourceVaultDefaultImportedMailPL
型: Real, 初期値: 0.85
import 時のメール本文 PL 既定 (fail-safe)。maildb privacy は信用しない。

## snapshot store 操作

### SourceVaultMailSnapshotPut[snapshot, opts]
snapshot を RecordId をキーに store へ保存 (冪等)。
→ Association
Options: `"Persist" -> True` (False でメモリのみ更新、ディスク保存しない)。

### SourceVaultMailSnapshotGet[recordId] → Association
保存済み snapshot を返す。

### SourceVaultMailSnapshotList[] → {Association...}
保存済み(ロード済み) snapshot を全件返す。

### SourceVaultMailSnapshotDecryptBody[snapshot] → Association
snapshot の暗号化 body を復号して返す (MAC 検証経由)。`<|"Status"->"Ok","Body"->String|>` または失敗時 Status≠"Ok"+Reason。

### SourceVaultMailStoreSave["All"->False]
変更のあった月次シャードのみを byte-exact 保存する。
→ Association
Options: `"All" -> False` (True で全シャード保存)。

### SourceVaultMailStoreLoad[] → Association
全シャードを読み込む(重い)。通常は `SourceVaultMailEnsureLoaded` で必要分だけ遅延ロード。

### SourceVaultMailAvailableShards[mbox_:All] → {{mbox, yyyymm}...}
ディスク上のシャード一覧をロードせずに返す。mbox 指定で絞り込み。

### SourceVaultMailEnsureLoaded[mbox_String, period_:Automatic]
指定 mbox の期間分シャードだけをメモリへ遅延ロードする。既ロードは再読込しない。
→ Association
period: `"YYYYMM"` | `{from,to}` | `"Latest"`/Automatic | n(直近n月の整数) | All。
例: SourceVaultMailEnsureLoaded["work", 3] は work の直近3ヶ月をロード。

### SourceVaultMailLoadShard["mbox/yyyymm"] → Association
1シャードをロードする。

### SourceVaultMailUnloadAll[] → Association
メモリ上の snapshot を解放する。

### SourceVaultMailLoadedCount[] → Integer
現在メモリにある snapshot 数を返す。

### SourceVaultMailStoreRoot[] → String
snapshot store のルートを返す。

### SourceVaultMailShardPath["mbox/yyyymm"] → String
月次シャードのパスを返す。

### SourceVaultMailStorePath[] → String
旧単一ファイル (移行用) のパスを返す。

### SourceVaultMailMigrateToShards[] → Association
旧単一ファイル snapshots.svmail を mbox×月のシャードに移行し、旧ファイルを .bak にする。

### $SourceVaultMailStoreRoot
型: String, 初期値: PrivateVault/mail/snapshots
mail snapshot store のルート。テストで上書き可。

## 検索・一覧

### SourceVaultSearchMailSnapshots[query_String:"", opts]
subject/summary 部分一致 + 各種フィルタで検索する。
→ {Association(snapshot)...}
Options: `From` (送信者メール部分一致), `FromContact` (連絡先Uid), `MBox`, `DateFrom`, `DateTo`, `HasAttachment`, `Newest -> True` (日付降順), `Limit` (件数制限)。

### SourceVaultMailSummaryRow[snapshot] → Association
一覧表示用の低漏洩行 `<|Date, From, Subject, Attach, MBox, RecordId, BodyEncrypted|>` を返す。From は AddressBook 解決時は表示名。

### SourceVaultMailSearchSummary[query_String:"", opts]
検索結果を SummaryRow のリスト(新着順・Limit 適用)で返す。
→ {Association...}
Options: SourceVaultSearchMailSnapshots と同じ。

### SourceVaultMailDataset[query_String:"", opts]
検索結果を素の Dataset で返す(列ソート用、ボタン無し)。
→ Dataset
Options: SourceVaultSearchMailSnapshots と同じ。

### SourceVaultIdentityBackfillFromMail[] → Association
ロード済み snapshot の平文 From/To/Cc を走査して識別子(2層アドレス帳)を一括生成する。再取込不要。スコープは先に `SourceVaultMailEnsureLoaded` で決める。

## IMAP 取得

### SourceVaultMailFetchNew[mbox, opts]
IMAP から新着のみ取得し snapshot 化して store に保存する。既定は LLM 処理なし。RecordId で既存と重複排除。
→ Association (取得サマリ)
Options: `"Period" -> "Latest"` (`"Latest"`|n日(整数)|`{from,to}`|`"YYYYMM"`), `"Process" -> False` (True で派生も実行), `"MessageSource" -> Automatic` (既定=実IMAP/Python imaplib、注入可), `"Inferencer" -> Automatic`, `"Persist" -> True`, `"MaxEmails" -> Automatic`。
例: SourceVaultMailFetchNew["work", "Period"->7] は直近7日を取得。事前に SourceVaultRegisterMailAccount で登録要。

## 派生処理 PL/優先度/概要

### SourceVaultMailDerivedPending[] → {Association...}
ロード済み store の中で派生未処理の snapshot を返す。

### SourceVaultMailDerivedPendingQ[snapshot] → Boolean
派生が未処理 ("Pending"、または DerivedStatus 無しで Summary 空) なら True。

### SourceVaultInferMailDerivedBatch[opts]
未処理 snapshot の派生をローカル LLM で増分生成し in-place 更新する。中断耐性 (CheckpointEvery 件ごとに保存、Processed 済みは再処理しない)。
→ Association `<|Status, PendingBefore, Selected, Processed, Failed, FailedBodyDecrypt, FailedLLM, RemainingPending|>`
Options: `"Limit" -> 50`, `"Inferencer" -> Automatic` (既定=実LLM `SourceVaultMailInferDerived`、注入可), `"CheckpointEvery" -> 20`, `"Persist" -> True`。

### SourceVaultMailInferDerived[mailspec_Association] → Association
mailspec(date/subject/from/to/cc/body) からローカル LLM (LM Studio, OpenAI 互換) で `<|WorkRequest, PrivacyLevel, Summary, Status|>` を返す。優先度は構造的に別計算。失敗時 Status="Error", Reason="LLMUnavailable"。

### SourceVaultMailComputePriority[snapshot, workRequest_:Missing[]] → Association
構造シグナル(送信者グループ重み + To/Cc 位置 + bulk判定 + LLM 依頼度)から重要度 0.0-1.0 を決定的に計算する。
→ `<|"Priority"->Real, "Components"-><|SenderWeight, OwnerPosition, Bulk, WorkRequest, PositionAdj, BulkAdj|>|>`
計算式: Clip[senderWeight + 0.30*workRequest + posAdj + bulkAdj, {0,1}]。posAdj: To→+0.15, Cc→0.0, Bulk→-0.25。bulkAdj: bulk なら -0.15。

### SourceVaultMailExplainPriority[snapshot] → Association
snapshot の保存済み WorkRequest を使って重要度の内訳(Components)を返す。

## 優先度グループ重み

### SourceVaultSetPriorityGroupWeight[group_String, weight_?NumericQ, opts]
グループの重み(0.0-1.0)を登録し vault config に保存する。実体の Group がこれに解決される。
→ Association `<|Status->"Set", Group, Weight|>`
Options: `"Persist" -> True`。

### SourceVaultPriorityGroupWeights[] → Association
登録済みグループ重みを返す (group->weight)。

### SourceVaultGroupWeightFor[group] → Real | Missing
グループの重みを返す。無ければ `Missing["NotSet"]`。

### SourceVaultPriorityGroupsLoad[] → Association
グループ重み config を読み込む。

## IMAP アカウント設定

### SourceVaultRegisterMailAccount[assoc_Association, opts]
IMAP アカウント設定を登録し vault config に保存する。パスワードは保存せず CredKey(SystemCredential 名)のみ。同一 MBox は上書き。私的データはソースに置かずここで登録する。
→ Association `<|Status->"Registered", MBox|>` (失敗時 Status="Error"+Reason)
assoc キー: `"MBox"`, `"User"`, `"Email"`, `"CredKey"`(必須), `"Server"`(必須), `"Port"`(既定993)。小文字キーも可。
Options: `"Persist" -> True`。
例: SourceVaultRegisterMailAccount[<|"MBox"->"work","User"->"u@x.com","Email"->"u@x.com","CredKey"->"work_imap","Server"->"imap.x.com","Port"->993|>]

### SourceVaultMailAccounts[] → Dataset
登録済み IMAP アカウント設定を Dataset で返す(パスワードは含まない)。

### SourceVaultGetMailAccount[mbox] → Association | Missing
登録済みアカウント設定を返す。無ければ `Missing["NotRegistered"]`。

### SourceVaultRemoveMailAccount[mbox_String, opts]
登録を削除する。
→ Association `<|Status->"Removed", MBox|>`
Options: `"Persist" -> True`。

### SourceVaultMailAccountsLoad[] → Association
vault config からアカウント設定を読み込む。

### $SourceVaultMailConfigRoot
型: String, 初期値: PrivateVault/config
IMAP アカウント設定の保存ルート。テストで上書き可。

## 本文・添付・返信 FE

### SourceVaultMailGetBody[recordId] → Association
snapshot の暗号化本文を復号して返す。`<|"Status"->"Ok","Body"->String|>` または失敗時 Status≠"Ok"。recordId は文字列または snapshot Association を受ける。

### SourceVaultMailShowBody[recordId] → Association
本文を新規ノートブックで表示する (front end)。`<|Status->"Shown"|>`、復号失敗時は理由ノートブックを出し復号結果を返す。

### SourceVaultMailAttachmentDir[mbox_String, yyyymm_String] → String
旧 maildb 添付ディレクトリ `<legacyRoot>/<mbox>/<yyyymm>_attachment` のパスを返す。

### SourceVaultMailAttachments[recordId] → {Association...}
添付 `{<|Name, Path, Exists|>...}` のリストを返す。snapshot に名前が無い場合は再 import を促す Hint Association を返す。

### SourceVaultMailOpenAttachment[recordId, name_String] → Association
添付ファイルを開く (front end / SystemOpen)。`<|Status->"Opened", Path|>` または "Error"+Reason="AttachmentNotFound"。

### SourceVaultMailComposeReply[recordId, opts]
返信ドラフトを生成する。
→ `<|Status->"Draft", To, Cc, Subject, InReplyToToken, Quoted, Body, RecordId|>`
Options: `"ReplyAll" -> False` (True で Cc 含む、オーナー宛は除外), `"Body" -> ""` (本文初期値)。Subject は既に "Re:" 始まりでなければ付与。

### SourceVaultMailOpenReplyNotebook[recordId, opts]
返信ドラフトのノートブックを開く (front end)。
→ `<|Status->"ReplyNotebookOpened", Draft|>`
Options: SourceVaultMailComposeReply と同じ (`"ReplyAll"`, `"Body"`)。

### SourceVaultMailView[query_String:"", opts]
検索結果を、行ごとに 本文表示(✉)/添付ポップアップ(📎)/返信(↩) のクリック操作を備えた表 (Dataset) で返す。旧 maildb showMails 踏襲。
→ Dataset (Pane 包み)
Options: SourceVaultSearchMailSnapshots と同じ。

### SourceVaultMailRowActions[snapshot] → Row
1行分のアクション (Body/Attachments/Reply ボタン) を返す。

## アドレス帳・実体 UI

### SourceVaultAddressBookView[] → Dataset
連絡先を整形表で表示する。列: Uid/表示名/かな/メール/分類/信頼/MaxPL/AccessTags。

### SourceVaultIdentityLinkUI[opts]
識別子を実体に紐付ける編集表(front end)。各行で 新規(ヘッダ継承で実体作成)/マージ(既存実体にアドレス追加)。
→ DynamicModule
Options: `"ShowLinked" -> False` (既定=未リンクのみ), `"Limit" -> 200`。

### SourceVaultEntityView[] → Dataset
実体(人/組織/Bot/ML)の一覧表。各行に編集ボタン。列: Uid/種別/表示名/かな/識別子数/グループ/重み/信頼。

### SourceVaultEntityEditUI[entityIdOrUid] → Panel
実体1件の編集フォーム(front end)。表示名/種別/漢字/ローマ字/かな/分類/グループ/重み/所属/信頼/主メール/LLMプロフィール を編集し保存。

### $SourceVaultLegacyMailRoot
型: String, 初期値: PrivateVault と同階層の udb/mails
旧 maildb のメールルート (添付ディレクトリの親)。

### $SourceVaultMailNotebookStyle
型: String, 初期値: "SourceVault default.nb"
本文表示・返信ノートブックの StyleDefinitions。

## 典型ワークフロー
1. `SourceVaultRegisterMailAccount[...]` でアカウント登録 (CredKey に SystemCredential 名)。
2. `SourceVaultMailFetchNew[mbox, "Period"->"Latest"]` で新着取得 (LLM なし、高速)。
3. `SourceVaultInferMailDerivedBatch["Limit"->50]` で派生(PL/優先度/概要)を増分生成。
4. `SourceVaultMailView[query]` で対話表示、または `SourceVaultSearchMailSnapshots[query, opts]` でプログラム検索。
5. 大量データは `SourceVaultMailEnsureLoaded[mbox, period]` で必要分のみ遅延ロード。