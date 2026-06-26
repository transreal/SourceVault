# SourceVault_maildb API Reference

パッケージ: `SourceVault`` (BeginPackage["SourceVault`", {"NBAccess`"}])
ソース: https://github.com/transreal/SourceVault_maildb
ロード順: SourceVault_encryptedstore.wl → SourceVault_keys.wl → SourceVault_addressbook.wl → SourceVault_maildb.wl → SourceVault_messagerelease.wl → SourceVault_mailui.wl

旧 maildb (https://github.com/transreal/maildb_legacy) 月次 .wl record を SourceVaultMailSnapshot に正規化するアダプタ。RecordId は `sourcevault:mailid:mac:v1` keyed HMAC、body は SourceVaultEncryptedPut で暗号化、From/To/Cc は AddressBook に照合する。

## スナップショット変換・永続化

### SourceVaultMailSnapshotFromMaildb[record_Association, mbox_String, opts]
旧 maildb record を SourceVaultMailSnapshot に変換する。body を暗号化し PL を fail-safe (既定 0.85) で設定する。
→ Association (MailSnapshot)
Options: "EncryptHeaders" -> False (True で subject/from/to も暗号化), "PrivacyLevel" -> $SourceVaultDefaultImportedMailPL (本文 PL)

### SourceVaultImportMaildbFile[file_String, mbox_String, opts]
旧 maildb 月次 .wl を読み込み各 record を MailSnapshot に変換して store に put する (冪等)。
→ Association `<|Status, MBox, Count, Stored, Persisted, Snapshots|>`
Options: SourceVaultMailSnapshotFromMaildb のすべてのオプション, "Persist" -> False (True でディスク保存)
例: `SourceVaultImportMaildbFile["/vault/mail/imai/202505.wl", "imai", "Persist"->True]`

### SourceVaultMailSnapshotPut[snapshot, opts]
snapshot を RecordId をキーに store へ保存する (冪等)。
→ Association
Options: "Persist" -> False

### SourceVaultMailSnapshotGet[recordId_String]
→ Association | Missing 保存済み snapshot を返す。

### SourceVaultMailSnapshotList[]
→ List[Association] ロード済み snapshot の全リストを返す。

### SourceVaultMailSnapshotDecryptBody[snapshot_Association]
snapshot の暗号化 body を復号して返す (MAC 検証経由)。
→ Association `<|Status, Body|>` または `<|Status, Reason|>`

### SourceVaultMailParseEmails[headerValue_String]
ヘッダ文字列からメールアドレス文字列のリストを抽出する。
→ List[String]

## ストア操作

### SourceVaultMailStoreRoot[]
→ String snapshot store のルートディレクトリパスを返す。

### SourceVaultMailStorePath[]
→ String 旧単一ファイル snapshots.svmail のパス (移行用)。

### SourceVaultMailShardPath["mbox/yyyymm"]
→ String 月次シャードファイルのパスを返す。

### SourceVaultMailStoreLoad[]
全シャードをメモリへ読み込む (重い)。通常は SourceVaultMailEnsureLoaded を使う。
→ Association `<|Status, Root, Shards, Count|>`

### SourceVaultMailStoreSave["All"->False]
変更のあった月次シャードのみ (All->True で全シャード) を byte-exact 保存し、索引 sidecar (.svmailidx) を自動更新する。
→ Association `<|Status, Shards, ...|>`

### SourceVaultMailAvailableShards[mbox_:All]
ディスク上のシャード `{mbox, yyyymm}` の一覧をロードせずに返す。
→ List[{String, String}]

### SourceVaultMailEnsureLoaded[mbox_String, period_:Automatic]
指定 mbox の必要分シャードのみをメモリへ遅延ロードする。既ロードは再読込しない。
period: `"YYYYMM"` | `{fromYYYYMM, toYYYYMM}` | `"Latest"` / Automatic | 整数n (直近n月) | All
→ Association `<|Status, MBox, Period, Shards, NewlyLoaded, InMemory|>`
例: `SourceVaultMailEnsureLoaded["imai", 3]` (直近3月ロード)

### SourceVaultMailLoadShard["mbox/yyyymm"]
1シャードをロードする。
→ Integer (ロードした snapshot 数)

### SourceVaultMailUnloadAll[]
メモリ上の全 snapshot を解放する。
→ Association `<|Status -> "Unloaded"|>`

### SourceVaultMailLoadedCount[]
→ Integer 現在メモリにある snapshot 数。

### SourceVaultMailMigrateToShards[]
旧単一ファイル snapshots.svmail を mbox×月のシャードに移行し、旧ファイルを .premigration.bak にリネームする。
→ Association `<|Status, Snapshots, Shards, OldFile|>`

## 検索・索引

### $SourceVaultMailCategories
型: Association, メールカテゴリ語彙。
トークン: `"InfoProvision"` (情報提供), `"AttendanceRequest"` (出席依頼), `"TaskRequest"` (作業依頼), `"Confirmation"` (確認・承認依頼), `"Report"` (報告), `"Notice"` (通知・一斉配信), `"Other"` (その他)。
Derived.Category と検索オプション `"Category"` で使う。日本語名 (`"作業依頼"` 等) でも検索可。

### SourceVaultSearchMailSnapshots[query_String:"", opts]
ロード済みスナップショットを subject/summary 部分一致 + フィルタ条件で検索する。
→ List[Association]
Options: "From" -> Automatic, "To" -> Automatic, "FromContact" -> Automatic, "MBox" -> Automatic, "DateFrom" -> Automatic, "DateTo" -> Automatic, "HasAttachment" -> Automatic, "Category" -> Automatic, "HasDeadline" -> Automatic, "DeadlineFrom" -> Automatic, "DeadlineTo" -> Automatic, "MinPriority" -> Automatic, "MaxPriority" -> Automatic, "MinPrivacy" -> Automatic, "MaxPrivacy" -> Automatic, "Newest" -> True, "Limit" -> Automatic, "SortBy" -> Automatic ("Date"|"Priority"|"PrivacyLevel"|"Deadline"), "SortOrder" -> Automatic
例: `SourceVaultSearchMailSnapshots["Cerezo", "Category"->"TaskRequest", "DeadlineFrom"->今日, "DeadlineTo"->週末, "Limit"->20]`

### SourceVaultMailSummaryRow[snapshot_Association]
一覧表示用の低漏洩行を返す。From は AddressBook 解決時は表示名。
→ Association `<|Date, From, Subject, Category, Deadline, Attach, MBox, RecordId, BodyEncrypted|>`

### SourceVaultMailSearchSummary[query_String:"", opts]
検索結果を SummaryRow のリスト (新着順・Limit 適用) で返す。opts は SourceVaultSearchMailSnapshots と同じ。
→ List[Association]

### SourceVaultMailDataset[query_String:"", opts]
検索結果を素の Dataset で返す (列ソート用、ボタン無し)。opts は SourceVaultSearchMailSnapshots と同じ。
→ Dataset

### SourceVaultMailSearchIndex[query_String:"", opts]
ディスク上の軽量メタデータ索引 (.svmailidx sidecar) のみを走査し、snapshot 本体 (本文暗号文) をメモリへロードせずに低漏洩メタ/サマリー行を返す。To/Cc/FromContact 等 index 非保持の項目は無視される。opts は SourceVaultSearchMailSnapshots と同じ。
→ List[Association] (SummaryRow 形 + Summary + FromRaw/ToRaw/FromContact/AttachmentCount/ShardKey/AccessTags/IndexSchemaVersion)
例: `SourceVaultMailSearchIndex["報告", "MBox"->"imai", "Limit"->50]`

### SourceVaultMailIndexGet[recordId_String]
索引 sidecar から該当 RecordId の低漏洩メタ/サマリー行を1件返す (snapshot 本体はロードしない)。MCP の単一 URI 解決用。
→ Association | Missing["NotFound"]

### SourceVaultMailIndexedCount[mbox_:All]
→ Integer ディスク上の索引 sidecar に含まれる行数 (索引済みメール数)。

### SourceVaultMailRebuildMetadataIndex[mbox_:All]
ディスク上の各 shard を一時的に読み、低漏洩メタデータ索引 sidecar (.svmailidx) を再生成する ($iSVMDStore は変更しない)。既存 .svmail からの初回構築・再構築に使う。
→ Association `<|Status, Shards, Rows, Root|>`

### SourceVaultIdentityBackfillFromMail[]
ロード済み snapshot の平文 From/To/Cc を走査して識別子 (2層アドレス帳) を一括生成する。再取込不要。スコープは先に SourceVaultMailEnsureLoaded で決める。
→ Association

## IMAP 取得

### SourceVaultMailFetchNew[mbox_String, opts]
IMAP から新着のみ取得し snapshot 化して store に保存する。RecordId で既存と重複排除する。既定は LLM 処理なし。
→ Association `<|Status, MBox, ...|>`
Options: "Period" -> Automatic ("Latest"|n日|{from,to}|"YYYYMM"), "Process" -> False (True で取込時に LLM 派生処理), "MessageSource" -> (実IMAP, 注入可), "Inferencer" -> (実LLM, 注入可), "Persist" -> True, "MaxEmails" -> Automatic

### SourceVaultRegisterPostFetchHook[name_String, f]
SourceVaultMailFetchNew の取り込み完了時に呼ぶフック `f[mbox, fetchResult]` を登録する。フック失敗は fetch を壊さない。
→ (副作用)

### SourceVaultUnregisterPostFetchHook[name_String]
post-fetch フックの登録を解除する。
→ (副作用)

### SourceVaultPostFetchHooks[]
→ List[String] 登録済み post-fetch フック名のリスト。

## 派生処理 (LLM)

### SourceVaultMailDerivedPendingQ[snapshot_Association]
→ True | False 派生 (PL/優先度/概要) が未処理 ("Pending") なら True。旧 snapshot は Summary 空で True。

### SourceVaultMailDerivedPending[]
→ List[Association] ロード済み store の中で派生未処理の snapshot リスト。

### SourceVaultMailInferDerived[mailspec_Association]
mailspec (date/subject/from/to/cc/body) からローカル LLM で派生を推論する。Category は $SourceVaultMailCategories のトークン。Deadline は ISO 文字列または Missing["None"]。
→ Association `<|WorkRequest, PrivacyLevel, Category, Deadline, Summary, Status|>`

### SourceVaultInferMailDerivedBatch[opts]
未処理 snapshot の派生をローカル LLM で増分生成し in-place 更新する。CheckpointEvery 件ごとに dirty シャードを保存する (中断耐性)。
→ Association `<|Status, Processed, Skipped, ...|>`
Options: "Limit" -> 50 (Infinity で範囲内全件), "DateFrom" -> Automatic, "DateTo" -> Automatic, "Refresh" -> None (None=Pending のみ / "MissingCategory"=Category 未生成の処理済み旧 snapshot も再処理 / All=全件 / Function=述語一致を再処理), "Inferencer" -> (実LLM, 注入可), "CheckpointEvery" -> 20, "Persist" -> True
例: `SourceVaultInferMailDerivedBatch["Limit"->Infinity, "DateFrom"->{2026,6,1}, "Refresh"->"MissingCategory"]`
例: `SourceVaultInferMailDerivedBatch["Refresh"->Function[s, StringContainsQ[ToString@s["MailMetadataPublic"]["Subject"], "Cerezo"]]]`

### SourceVaultMailAddSummaries[mbox_String, period_:"Latest", opts]
mbox の指定期間を SourceVaultMailEnsureLoaded でロードしてから SourceVaultInferMailDerivedBatch で一括生成・保存する。EnsureLoaded とバッチを内包する正準エントリポイント。
→ Association `<|Status, MBox, Period, Loaded, Batch|>`
Options: "Limit" -> Infinity, "Persist" -> True

### SourceVaultRegisterMailspecEnricher[name_String, f]
LLM へ渡す mailspec を拡張する enricher を登録する。`f[mailspec, snapshot]` が変更後の mailspec を返す。非該当/失敗時は mailspec をそのまま返す。Derived.DerivedEnrichment に名前が記録される。
→ (副作用)

### SourceVaultUnregisterMailspecEnricher[name_String]
mailspec enricher の登録を解除する。
→ (副作用)

### SourceVaultMailspecEnrichers[]
→ List[String] 登録済み mailspec enricher 名のリスト。

## 優先度計算

### SourceVaultMailComputePriority[snapshot_Association, workRequest_, category_String]
構造シグナル (送信者グループ重み + To/Cc 位置 + ML 判定 + LLM 依頼度 + LLM カテゴリ) から重要度 0.0–1.0 を決定的に計算する。"Notice" カテゴリは -0.30 減点。
→ Association `<|Priority, Components|>`

### SourceVaultMailExplainPriority[snapshot_Association]
snapshot の保存済み WorkRequest/Category を使って重要度の内訳 (Components) を返す。
→ Association `<|Priority, Components|>`

### SourceVaultMailRecomputePriorities[opts]
ロード済み snapshot のうち PriorityComponents ありのものについて、保存済み WorkRequest/Category から Priority を LLM なしで再計算し in-place 更新する。優先度式変更を既処理メールへ反映するために使う。legacy maildb 由来の Priority は触らない。
→ Association
Options: "Persist" -> True

### SourceVaultSetPriorityGroupWeight[group_String, weight_Real]
グループの重み (0.0–1.0) を登録し vault config に保存する。
→ Association

### SourceVaultPriorityGroupWeights[]
→ Association 登録済みグループ重みの全マップ。

### SourceVaultGroupWeightFor[group_String]
→ Real | Missing グループの重み。未登録なら Missing。

### SourceVaultPriorityGroupsLoad[]
グループ重み config をディスクから読み込む。
→ Association

## アカウント管理

### SourceVaultRegisterMailAccount[assoc_Association, opts]
IMAP アカウント設定を登録し vault config に保存する。パスワードは保存せず CredKey (SystemCredential 名) のみ記録する。同一 MBox は上書き。
必須キー: "MBox", "CredKey", "Server"。任意: "User", "Email", "Port" (既定 993)。
→ Association `<|Status, MBox|>`
Options: "Persist" -> True
例: `SourceVaultRegisterMailAccount[<|"MBox"->"imai", "User"->"k.imai@...", "Email"->"k.imai@...", "CredKey"->"sv-imap-imai", "Server"->"imap.example.com"|>]`

### SourceVaultGetMailAccount[mbox_String]
→ Association | Missing["NotRegistered"] 登録済みアカウント設定 (パスワードは含まない)。

### SourceVaultMailAccounts[]
→ Dataset 登録済み IMAP アカウント設定の全件 (パスワードは含まない)。

### SourceVaultRemoveMailAccount[mbox_String, opts]
登録を削除する。
→ Association `<|Status, MBox|>`
Options: "Persist" -> True

### SourceVaultMailAccountsLoad[]
vault config からアカウント設定を読み込む。
→ Association `<|Status, Count|>`

## UI 操作 (front end 必須)

### SourceVaultMailGetBody[recordId_String]
snapshot の暗号化本文を復号して文字列で返す。
→ Association `<|Status->"Ok", Body->String|>` または `<|Status->"Error", Reason->String|>`

### SourceVaultMailShowBody[recordId_String]
本文を新規ノートブックで表示する (front end 必須)。
→ Association `<|Status->"Shown"|>`

### SourceVaultMailAttachmentDir[mbox_String, yyyymm_String]
→ String 旧 maildb 添付ディレクトリのパス (`<legacyRoot>/<mbox>/<yyyymm>_attachment`)。

### SourceVaultMailAttachments[recordId_String]
添付ファイルの `{Name, Path, Exists}` リストを返す。AttachmentCount > 0 だが名前が snapshot 未記録の旧レコードはヒント付き Association を返す。
→ List[Association]

### SourceVaultMailOpenAttachment[recordId_String, name_String]
添付ファイルを SystemOpen で開く (front end 必須)。
→ Association `<|Status, Path|>` または `<|Status->"Error", Reason, Name|>`

### SourceVaultMailComposeReply[recordId_String, opts]
返信ドラフトを生成する (ロジックのみ、front end 不要)。
→ Association `<|Status->"Draft", To, Cc, Subject, InReplyToToken, Quoted, Body, RecordId|>`
Options: "ReplyAll" -> False (True で Cc 含む), "Body" -> "" (本文初期値)

### SourceVaultMailOpenReplyNotebook[recordId_String, opts]
返信ドラフトのノートブックを開く (front end 必須)。opts は SourceVaultMailComposeReply と同じ。
→ Association `<|Status->"ReplyNotebookOpened", Draft|>`

### SourceVaultMailView[query_String:"", opts]
検索結果を、行ごとに本文表示(✉)/添付ポップアップ(📎)/返信(↩) のクリック操作を備えた Dataset で返す (旧 maildb showMails 踏襲)。opts は SourceVaultSearchMailSnapshots と同じ。
→ Dataset

### SourceVaultMailRowActions[snapshot_Association]
1行分のアクション (Body/Attachments/Reply ボタン Row) を返す。SourceVaultMailView の内部行に使われる。
→ Row

### SourceVaultAddressBookView[]
連絡先を整形 Dataset で表示する。列: Uid/表示名/かな/メール/分類/信頼/MaxPL/AccessTags。
→ Dataset

### SourceVaultIdentityLinkUI[opts]
識別子を実体に紐付ける編集表 (front end)。各行で新規実体作成またはマージ操作。
→ (front end 表)
Options: "ShowLinked" -> False (True で既リンクも表示), "Limit" -> 200

### SourceVaultEntityView[]
実体 (人/組織/Bot/ML) の一覧 Dataset。列: Uid/種別/表示名/かな/識別子数/グループ/重み/信頼。
→ Dataset

### SourceVaultEntityEditUI[entityIdOrUid]
実体1件の編集フォーム (front end)。表示名/種別/漢字/ローマ字/かな/分類/グループ/重み/所属/信頼を編集して保存する。
→ (front end フォーム)

### SourceVaultMarkConfidentialViewCells[nb_:EvaluationNotebook[]]
notebook 内の生データ出力セル (SourceVaultMailView / MailDataset / MailSearchSummary / SourceVaultFindTodos 等) を含まれる最大 PL で機密マークする。メールは Derived.PrivacyLevel、Todo はソースノートブックの Publishable による。検出対象は共有レジストリで拡張される。
→ List[Association] `{<|"Cell"->idx, "PrivacyLevel"->pl|>, ...}`

### SourceVaultMailMarkViewCells[nb_:EvaluationNotebook[]]
SourceVaultMarkConfidentialViewCells の別名 (後方互換)。
→ List[Association]

### SourceVaultMailEnableAutoConfidential[]
NBAccess`NBMakeContextPacket にフックを装着し、ClaudeEval/ClaudeQuery の文脈構築直前に SourceVaultMarkConfidentialViewCells で生データ出力セルを自動機密マークする (冪等)。
→ (副作用)

### SourceVaultMailDisableAutoConfidential[]
SourceVaultMailEnableAutoConfidential[] で装着したフックを解除し、NBMakeContextPacket を元に戻す。
→ (副作用)

## 設定変数

### $SourceVaultMailStoreRoot
型: String, 初期値: PrivateVault/mail/snapshots
mail snapshot store のルート。テストで上書き可能。

### $SourceVaultDefaultImportedMailPL
型: Real, 初期値: 0.85
import 時のメール本文 PL 既定 (fail-safe)。maildb の privacy フィールドは信用しない。

### $SourceVaultMailConfigRoot
型: String, 初期値: PrivateVault/config
IMAP アカウント設定の保存ルート。テストで上書き可能。

### $SourceVaultLegacyMailRoot
型: String, 初期値: PrivateVault と同階層の udb/mails
旧 maildb のメールルート (添付ディレクトリの親)。

### $SourceVaultMailNotebookStyle
型: String, 初期値: "SourceVault default.nb"
本文表示・返信ノートブックの StyleDefinitions。

### $SourceVaultMailViewMaxRows
型: Integer | All, 初期値: 25
SourceVaultMailView 等が一度に描画する最大行数。Windows 版 FrontEnd の描画負荷対策。All で無制限。