# SourceVault_maildb API Reference

パッケージ: `SourceVault`` (BeginPackage["SourceVault`", {"NBAccess`"}])
リポジトリ: https://github.com/transreal/SourceVault_maildb

## 概要
旧 maildb (maildb_legacy) 月次 .wl record を `SourceVaultMailSnapshot` に正規化する Phase SV-E5 アダプタ。本文は `SourceVaultEncryptedPut` で暗号化。IMAP 取得・LLM 派生処理・優先度計算・検索・FE UI を含む。

## 依存関係
ロード順: `SourceVault_encryptedstore.wl` → `SourceVault_keys.wl` → `SourceVault_addressbook.wl` → `SourceVault_maildb.wl` → `SourceVault_messagerelease.wl` → `SourceVault_mailui.wl`
関連: [NBAccess](https://github.com/transreal/NBAccess), [SourceVault_core](https://github.com/transreal/SourceVault_core), [SourceVault_crypto](https://github.com/transreal/SourceVault_crypto), [SourceVault_identity](https://github.com/transreal/SourceVault_identity), [Cerezo](https://github.com/transreal/Cerezo) (mailspec enricher 拡張)

## スナップショット構造
`SourceVaultMailSnapshot` は以下のキーを持つ Association:
```
<|
  "RecordId"           -> "...",        (* SourceVault:mailid:mac:v1 keyed HMAC *)
  "MailMetadataPublic" -> <|
    "Subject" -> "...", "From" -> "...", "To" -> "...", "Cc" -> "...",
    "Date"    -> "YYYY-MM-DD...",
    "AttachmentCount" -> n,
    "Attachments" -> {"name1", ...}     (* 再 import で付加 *)
  |>,
  "MailSource"   -> <|"MBox" -> "...", "MessageIDToken" -> "..."|>,
  "Derived"      -> <|
    "DerivedStatus"      -> "Pending"|"Processed",
    "Priority"           -> 0.0-1.0,    (* SourceVaultMailComputePriority で計算 *)
    "PriorityComponents" -> <|...|>,
    "WorkRequest"        -> 0.0-1.0,
    "PrivacyLevel"       -> 0.0-1.0,
    "Category"           -> "TaskRequest"|...,   (* $SourceVaultMailCategories のトークン *)
    "Deadline"           -> "YYYY-MM-DD"|Missing["None"],
    "Summary"            -> "...",
    "DerivedSource"      -> "LocalLLM+Structured",
    "DerivedEnrichment"  -> {...}        (* enricher 名リスト、存在時のみ *)
  |>,
  "AddressBookRefs" -> <|"FromIdentifier" -> "...", "FromContact" -> "..."|>
|>
```

## $SourceVaultMailCategories
### $SourceVaultMailCategories
型: 語彙定数
メール派生カテゴリトークン一覧。`Derived.Category` および検索オプション `"Category"` で使う。
| トークン | 日本語名 |
|---|---|
| `"InfoProvision"` | 情報提供 |
| `"AttendanceRequest"` | 出席依頼 |
| `"TaskRequest"` | 作業・仕事の依頼 |
| `"Confirmation"` | 確認・承認依頼 |
| `"Report"` | 報告 |
| `"Notice"` | 通知・一斉配信 |
| `"Other"` | その他 |

## ストア / シャード管理
ストアは mbox × 月 (yyyymm) の月次シャードで構成される。

### $SourceVaultMailStoreRoot
型: String, 初期値: `PrivateVault/mail/snapshots`
mail snapshot store のルートパス。テスト時に上書き可。

### SourceVaultMailStoreRoot[] → String
snapshot store のルートパスを返す。

### SourceVaultMailStorePath[] → String
旧単一ファイル `snapshots.svmail` のパスを返す (移行用)。

### SourceVaultMailShardPath["mbox/yyyymm"] → String
月次シャードのファイルパスを返す。

### SourceVaultMailAvailableShards[mbox_:All] → List
ディスク上のシャード `{mbox, yyyymm}` の一覧をメモリへロードせずに返す。

### SourceVaultMailEnsureLoaded[mbox_String, period_:Automatic]
指定 mbox の必要分シャードだけをメモリへ遅延ロードする。既ロードは再読込しない。
period: `"YYYYMM"` | `{from, to}` | `"Latest"` / `Automatic` | `n` (直近 n 月) | `All`

### SourceVaultMailLoadShard["mbox/yyyymm"] → Association
1 シャードをロードする。戻り値: `<|"Status"->"Loaded"|"AlreadyLoaded", ...|>`

### SourceVaultMailStoreLoad[] → Association
全シャードを読み込む (重い)。通常は `SourceVaultMailEnsureLoaded` を使う。

### SourceVaultMailStoreSave["All"->False] → Association
変更のあった月次シャードのみを byte-exact 保存する。`"All"->True` で全シャード保存。

### SourceVaultMailUnloadAll[] → Association
メモリ上の snapshot を解放する。

### SourceVaultMailLoadedCount[] → Integer
現在メモリにある snapshot 数を返す。

### SourceVaultMailMigrateToShards[] → Association
旧単一ファイル `snapshots.svmail` を mbox × 月のシャードに移行し、旧ファイルを `.bak` にリネームする。

## スナップショット CRUD

### SourceVaultMailSnapshotPut[snapshot, opts]
snapshot を RecordId をキーにストアへ保存する (冪等)。
→ Association
Options: `"Persist" -> True` (即時ディスク書き込み)

### SourceVaultMailSnapshotGet[recordId_String] → Association | Missing
保存済み snapshot を RecordId で取得する。存在しなければ `Missing["NotFound"]`。

### SourceVaultMailSnapshotList[] → List
ロード済み snapshot の全リストを返す。

### SourceVaultMailSnapshotDecryptBody[snapshot_Association] → Association
snapshot の暗号化 body を MAC 検証経由で復号する。
戻り値: `<|"Status"->"Ok", "Body"->"..."|>` または `<|"Status"->"Error", "Reason"->...|>`

### SourceVaultMailParseEmails[headerValue_String] → List
ヘッダ文字列からメールアドレス文字列のリストを抽出する。

## インポート (旧 maildb)

### SourceVaultMailSnapshotFromMaildb[record_Association, mbox_String, opts]
旧 maildb record を SourceVaultMailSnapshot に変換する。body は暗号化、PL は fail-safe。
→ Association
Options: `"EncryptHeaders" -> False` (True で subject/from/to も暗号化)

### SourceVaultImportMaildbFile[file_String, mbox_String, opts]
旧 maildb 月次 .wl を読み、各 record を MailSnapshot に変換する。
→ Association (`<|"Status", "Imported", "Skipped", ...|>`)
Options: `"Persist" -> True` (変換後に snapshot store へ保存), `"EncryptHeaders" -> False`

### SourceVaultIdentityBackfillFromMail[]
ロード済み snapshot の平文 From/To/Cc を走査して識別子(2層アドレス帳)を一括生成する。再取込不要。スコープは先に `SourceVaultMailEnsureLoaded` で決める。
→ Association

### $SourceVaultDefaultImportedMailPL
型: Real, 初期値: `0.85`
import 時のメール本文 PL 既定 (fail-safe)。maildb privacy フィールドは信用しない。

## IMAP 取得

### $SourceVaultMailConfigRoot
型: String, 初期値: `PrivateVault/config`
IMAP アカウント設定の保存ルート。テストで上書き可。

### SourceVaultRegisterMailAccount[assoc_Association, opts]
IMAP アカウント設定を登録し vault config に保存する。パスワードは保存せず CredKey (SystemCredential 名) のみ。同一 MBox は上書き。
assoc キー: `"MBox"`, `"User"`, `"Email"`, `"CredKey"`, `"Server"`, `"Port"` (既定 993)
→ `<|"Status"->"Registered", "MBox"->...|>` または `<|"Status"->"Error", "Reason"->...|>`
Options: `"Persist" -> True`
例: `SourceVaultRegisterMailAccount[<|"MBox"->"work", "User"->"user@example.com", "Email"->"user@example.com", "CredKey"->"sv_work_imap", "Server"->"imap.example.com"|>]`

### SourceVaultGetMailAccount[mbox_String] → Association | Missing
登録済みアカウント設定を返す。未登録なら `Missing["NotRegistered"]`。

### SourceVaultMailAccounts[] → Dataset
登録済み IMAP アカウント設定を Dataset で返す (パスワードは含まない)。

### SourceVaultRemoveMailAccount[mbox_String, opts]
アカウント登録を削除する。
→ `<|"Status"->"Removed", "MBox"->...|>`
Options: `"Persist" -> True`

### SourceVaultMailAccountsLoad[] → Association
vault config からアカウント設定を読み込む。

### SourceVaultMailFetchNew[mbox_String, opts]
IMAP から新着のみ取得し snapshot 化して store に保存する。RecordId で既存と重複排除。既定は LLM 処理なし。
→ Association (`<|"Status", "Fetched", "New", "Skipped", ...|>`)
Options:
- `"Period" -> "Latest"` (`"Latest"` | n日 | `{from,to}` | `"YYYYMM"`)
- `"Process" -> False` (True で取得後に LLM 派生も実行)
- `"MessageSource" -> 実IMAP` (テスト用 fake 注入可)
- `"Inferencer" -> 実LLM` (テスト用 fake 注入可)
- `"Persist" -> True`
- `"MaxEmails" -> Infinity`

## 派生処理 (LLM)

### SourceVaultMailInferDerived[mailspec_Association] → Association
mailspec (`<|"date","subject","from","to","cc","body"|>`) からローカル LLM (LM Studio, OpenAI 互換) で派生を生成する。
戻り値キー: `"WorkRequest"` (0.0-1.0), `"PrivacyLevel"` (0.0-1.0), `"Category"` ($SourceVaultMailCategories トークン), `"Deadline"` (ISO 文字列 or `Missing["None"]`), `"Summary"` (1行), `"Status"` ("Ok"|"Error")

### SourceVaultMailDerivedPendingQ[snapshot_Association] → True | False
snapshot の派生が未処理 ("Pending") なら True。`DerivedStatus` が無い旧 snapshot は Summary が空なら True。

### SourceVaultMailDerivedPending[] → List
ロード済みストアの中で派生未処理の snapshot リストを返す。

### SourceVaultInferMailDerivedBatch[opts]
未処理 snapshot の派生をローカル LLM で増分生成し in-place 更新する。中断耐性あり (CheckpointEvery 件ごとに保存)。
→ Association (`<|"Status", "Processed", "Skipped", "Total", ...|>`)
Options:
- `"Limit" -> 50` (フィルタ後の件数上限。全件なら `Infinity`)
- `"DateFrom" -> Automatic` (DateObject / 文字列 / `{y,m,d}`)
- `"DateTo" -> Automatic`
- `"Refresh" -> None` (`None`=Pending のみ, `"MissingCategory"`=Category 未生成の処理済みも対象, `All`=全件再処理, `Function`=述語に一致する snapshot を再処理)
- `"Inferencer" -> 実LLM` (注入可)
- `"CheckpointEvery" -> 20`
- `"Persist" -> True`

例:
```mathematica
(* 今月分のメールで Category が欠けているものを再処理 *)
SourceVaultInferMailDerivedBatch["Refresh" -> "MissingCategory", "DateFrom" -> {2026,6,1}]

(* 件名に "Cerezo" を含む snapshot だけ再処理 *)
SourceVaultInferMailDerivedBatch["Refresh" -> Function[s, StringContainsQ[ToString@s["MailMetadataPublic"]["Subject"], "Cerezo"]]]
```

### SourceVaultRegisterMailspecEnricher[name_String, f_]
派生(サマリー作成)時に LLM へ渡す mailspec を拡張する enricher を登録する (Cerezo.wl 等の拡張用)。`f[mailspec, snapshot]` が変更後の mailspec (Association) を返すとそれが LLM 入力になる。非該当/失敗時は mailspec をそのまま返す。保存レコード形式には影響せず、`Derived.DerivedEnrichment` に名前が記録される。
→ `<|"Status"->"Registered", "Name"->...|>`

### SourceVaultUnregisterMailspecEnricher[name_String] → Association
mailspec enricher の登録を解除する。

### SourceVaultMailspecEnrichers[] → List
登録済み mailspec enricher 名のリストを返す。

## 優先度計算

### SourceVaultMailComputePriority[snapshot_Association, workRequest_:Missing[], category_:Missing[]]
構造シグナル (送信者グループ重み + To/Cc 位置 + LLM 依頼度 + LLM カテゴリ) から重要度 0.0-1.0 を決定的に計算する。category が `"Notice"` なら -0.30 減点。
→ `<|"Priority"->0.0-1.0, "Components"-><|"SenderWeight","OwnerPosition","Bulk","WorkRequest","Category","PositionAdj","BulkAdj","CategoryAdj"|>|>`

### SourceVaultMailExplainPriority[snapshot_Association] → Association
snapshot の保存済み `WorkRequest` / `Category` を使って `SourceVaultMailComputePriority` を呼び、重要度の内訳 (Components) を返す。LLM 不要。

### SourceVaultMailRecomputePriorities[opts]
ロード済み snapshot のうち `PriorityComponents` を持つもの (構造計算済み) の Priority を LLM なしで再計算し in-place 更新する。優先度式の変更を既処理メールへ反映するために使う。legacy maildb 由来 (PriorityComponents 無し) は変更しない。
→ `<|"Status", "Eligible", "Recomputed", "Total"|>`
Options: `"Persist" -> True`

### SourceVaultSetPriorityGroupWeight[group_String, weight_?NumericQ, opts]
グループの重み (0.0-1.0) を登録し vault config に保存する。
→ `<|"Status"->"Set", "Group"->..., "Weight"->...|>`
Options: `"Persist" -> True`

### SourceVaultPriorityGroupWeights[] → Association
登録済みグループ重み `<|group -> weight, ...|>` を返す。

### SourceVaultGroupWeightFor[group_] → Real | Missing
グループの重みを返す。未登録なら `Missing["NotSet"]`。

### SourceVaultPriorityGroupsLoad[] → Association
グループ重み config をディスクから読み込む。

## 検索・一覧

### SourceVaultSearchMailSnapshots[query_String:"", opts]
subject / summary 部分一致 + フィルタで snapshot を検索する。
→ List of snapshot Association
Options:
- `"From" -> All` (送信者メールアドレス)
- `"To" -> All` (受信者メールアドレス)
- `"FromContact" -> All` (AddressBook の ContactId)
- `"MBox" -> All` (メールボックス名)
- `"DateFrom" -> All` (DateObject / 文字列 / `{y,m,d}`)
- `"DateTo" -> All`
- `"HasAttachment" -> All` (True/False/All)
- `"Category" -> All` ($SourceVaultMailCategories トークン or 日本語名 "作業依頼" 等)
- `"HasDeadline" -> All`
- `"DeadlineFrom" -> All` (〆切日 日単位包含)
- `"DeadlineTo" -> All`
- `"Newest" -> True` (日付降順)
- `"Limit" -> Infinity`
- `"SortBy" -> "Date"` (`"Date"` | `"Priority"` | `"PrivacyLevel"` | `"Deadline"`)

例:
```mathematica
(* 今週〆切の作業依頼 *)
SourceVaultSearchMailSnapshots["", "Category" -> "TaskRequest", "DeadlineFrom" -> Today, "DeadlineTo" -> Today + 6]
(* 優先度降順で直近50件 *)
SourceVaultSearchMailSnapshots["", "SortBy" -> "Priority", "Limit" -> 50]
```

### SourceVaultMailSummaryRow[snapshot_Association] → Association
一覧表示用の低漏洩行を返す。From は AddressBook 解決時は表示名。
戻り値キー: `"Date"`, `"From"`, `"Subject"`, `"Category"`, `"Deadline"` (ISO 文字列 or `Missing`), `"Attach"`, `"MBox"`, `"RecordId"`, `"BodyEncrypted"`

### SourceVaultMailSearchSummary[query_String:"", opts]
検索結果を SummaryRow のリスト (新着順・Limit 適用) で返す。opts は `SourceVaultSearchMailSnapshots` と同一。
→ List of Association

### SourceVaultMailDataset[query_String:"", opts]
検索結果を素の Dataset で返す (列ソート用、ボタン無し)。opts は `SourceVaultSearchMailSnapshots` と同一。
→ Dataset

## フロントエンド UI

### SourceVaultMailGetBody[recordId_String | snapshot_Association] → Association
snapshot の暗号化本文を復号して返す。
戻り値: `<|"Status"->"Ok", "Body"->".."|>` または `<|"Status"->"Error", "Reason"->...|>`

### SourceVaultMailShowBody[recordId_String | snapshot_Association] → Association
本文を新規ノートブックで表示する (front end 必須)。復号失敗時は理由をノートブックに表示。

### SourceVaultMailAttachmentDir[mbox_String, yyyymm_String] → String
旧 maildb 添付ディレクトリのパスを返す。パターン: `$SourceVaultLegacyMailRoot/mbox/yyyymm_attachment/`

### SourceVaultMailAttachments[recordId_String | snapshot_Association] → List
添付 `{<|"Name","Path","Exists"|>,...}` のリストを返す。Attachments キーが無い旧 snapshot は再 import を促すヒントを返す。

### SourceVaultMailOpenAttachment[recordId_String | snapshot_Association, name_String] → Association
添付ファイルを SystemOpen で開く (front end)。

### SourceVaultMailComposeReply[recordId_String | snapshot_Association, opts]
返信ドラフトを生成する (headless 対応)。
→ `<|"Status"->"Draft", "To","Cc","Subject","InReplyToToken","Quoted","Body","RecordId"|>`
Options: `"ReplyAll" -> False` (True で Cc 含む), `"Body" -> ""` (本文初期値)

### SourceVaultMailOpenReplyNotebook[recordId_String | snapshot_Association, opts]
返信ドラフトのノートブックを開く (front end)。opts は `SourceVaultMailComposeReply` と同一。

### SourceVaultMailView[query_String:"", opts]
検索結果を、行ごとに 本文表示(✉)/添付ポップアップ(📎)/返信(↩) のクリック操作を備えた表 (Dataset + Pane) で返す。opts は `SourceVaultSearchMailSnapshots` と同一。
→ Pane[Dataset[...]] または `Style["該当するメールがありません。", "Text"]`
列順: 操作ボタン / 添付 / 返信 / 日付 / 重要 / 秘匿 / 分類 / 〆切 / 件名 / 差出人 / 概要

### SourceVaultMailRowActions[snapshot_Association] → Row
1行分のアクション (✉本文/📎添付メニュー/↩返信 ボタン) を Row で返す。

### $SourceVaultMailNotebookStyle
型: String, 初期値: `"SourceVault default.nb"`
本文表示・返信ノートブックの StyleDefinitions。

### $SourceVaultLegacyMailRoot
型: String, 初期値: `PrivateVault と同階層の udb/mails`
旧 maildb のメールルート (添付ディレクトリの親)。

## アドレス帳・識別子 UI

### SourceVaultAddressBookView[] → Pane[Dataset]
連絡先を整形表で表示する。列: Uid / 表示名 / かな / メール / 分類 / 信頼 / PL / AccessTags。

### SourceVaultIdentityLinkUI[opts]
識別子を実体に紐付ける編集表 (front end, Dynamic)。各行で 新規(ヘッダ継承で実体作成) / マージ(既存実体にアドレス追加) が操作できる。
→ DynamicModule[...]
Options: `"ShowLinked" -> False` (False=未リンクのみ), `"Limit" -> 200`

### SourceVaultEntityView[] → Pane[Dataset]
実体 (人/組織/Bot/ML) の一覧表。各行に編集ボタン。列: Uid / 種別 / 表示名 / かな / 識別子数 / グループ / 重み / 信頼。

### SourceVaultEntityEditUI[entityIdOrUid_] → Pane
実体 1件の編集フォーム (front end)。表示名/種別/漢字/ローマ字/かな/分類/グループ/重み/所属/信頼 を編集し保存。

## 機密マーク

### SourceVaultMarkConfidentialViewCells[nb_:EvaluationNotebook[]] → List
notebook 内の「生データ出力セル」(SourceVaultMailView / MailDataset / MailSearchSummary / SourceVaultFindTodos 等) を含まれる項目の最大 PL で機密マークする。メールは `Derived.PrivacyLevel`、Todo はソースノートブックの Publishable に基づく。検出対象は共有レジストリで拡張される (SourceVault_eagle.wl ロード時は Eagle 系も対象)。
戻り値: `{<|"Cell"->idx, "PrivacyLevel"->pl|>,...}`

### SourceVaultMailMarkViewCells[nb_:EvaluationNotebook[]] → List
`SourceVaultMarkConfidentialViewCells` の別名 (後方互換)。

### SourceVaultMailEnableAutoConfidential[]
`NBAccess``NBMakeContextPacket` にフックを装着し、ClaudeEval/ClaudeQuery の文脈構築直前に `SourceVaultMarkConfidentialViewCells` を自動実行する。冪等。

### SourceVaultMailDisableAutoConfidential[]
`SourceVaultMailEnableAutoConfidential` で装着したフックを解除し `NBMakeContextPacket` を元に戻す。