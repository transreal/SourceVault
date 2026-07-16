# SourceVault_maildb API Reference

パッケージ: `SourceVault`` (BeginPackage["SourceVault`", {"NBAccess`"}])
ソース: https://github.com/transreal/SourceVault_maildb
ロード順: SourceVault_encryptedstore.wl → SourceVault_keys.wl → SourceVault_addressbook.wl → SourceVault_maildb.wl → SourceVault_messagerelease.wl → SourceVault_mailui.wl

旧 maildb (https://github.com/transreal/maildb_legacy) 月次 .wl record を SourceVaultMailSnapshot に正規化するアダプタ。RecordId は `sourcevault:mailid:mac:v1` keyed HMAC、body は SourceVaultEncryptedPut で暗号化、From/To/Cc は AddressBook に照合する。本文は ingest 時に「読める平文」へ正規化する (改行 LF 統一 + HTML メールはテキスト化、原文 HTML は BodyRaw に暗号化温存し MailMetadataPublic["BodyWasHTML"]->True)。取込元 record に "rawheader" (生ヘッダ) があり SourceVault_mining の配送特徴抽出器がロード済みなら、配送 coarse feature も SnapshotFeatures として併せて解析する (無ければ Missing、生ヘッダ自体は snapshot に保存しない)。

## スナップショット変換・永続化

### SourceVaultMailSnapshotFromMaildb[record_Association, mbox_String, opts]
旧 maildb record を SourceVaultMailSnapshot に変換する。body を読める平文化してから暗号化し PL を fail-safe で設定する。
→ Association (MailSnapshot)
Options: "PrivacyLevel" -> Automatic (本文 PL。Automatic は $SourceVaultDefaultImportedMailPL=0.85 に解決), "EncryptHeaders" -> False (True で subject/from/to/cc も暗号化), "StoreBody" -> "Encrypted" ("Encrypted" 以外なら本文を暗号化せず Missing 参照)

### SourceVaultImportMaildbFile[file_String, mbox_String, opts]
旧 maildb 月次 .wl を読み込み各 record を MailSnapshot に変換して store に put する (冪等)。
→ Association `<|Status, MBox, Count, Stored, Persisted, Snapshots|>`
Options: SourceVaultMailSnapshotFromMaildb のすべてのオプション, "Persist" -> False (True でディスク保存)
例: `SourceVaultImportMaildbFile["/vault/mail/imai/202505.wl", "imai", "Persist"->True]`

### SourceVaultMailSnapshotPut[snapshot, opts]
snapshot を RecordId をキーに store へ保存する (冪等)。
→ Association
Options: "Persist" -> False

### SourceVaultBackfillMailBodies[opts]
ロード済み snapshot のうち本文が HTML の旧 record を、読める平文へ変換して再格納する (原文は暗号化 payload の BodyRaw に温存、MailMetadataPublic["BodyWasHTML"]->True)。ingest 時 HTML テキスト化導入前のメール用 backfill。要約も作り直すには別途 SourceVaultInferMailDerivedBatch["Refresh"->...] を実行する。
→ Association
Options: "Limit" -> Infinity, "DryRun" -> False (True で件数だけ数え書込まない), "Persist" -> True, "CheckpointEvery" -> 20

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
**注**: 検索して表示するだけなら EnsureLoaded は不要 — `SourceVaultMailSearchIndexView`（索引 sidecar 検索＋✉/☰ で必要シャードだけ遅延ロード）を使う。`All` の全ロードは全期間の一括処理（サマリー付与・identity backfill 等）専用。

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

### SourceVaultMailInteractionStats[recordId_String]
メール操作記録 `<|"OpenCount","LastOpened","RepliedCount","RepliedAt"|>` を返す。本文表示で開封回数、返信送信で返信済を記録する。引数なし版 `SourceVaultMailInteractionStats[]` は全件 (RecordId キー) を返す。記録は `<storeRoot>/interaction.json` (Dropbox 共有)。
→ Association

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
ディスク上の軽量メタデータ索引 (.svmailidx sidecar) のみを走査し、snapshot 本体 (本文暗号文) をメモリへロードせずに低漏洩メタ/サマリー行を返す。To/Cc/FromContact 等 index 非保持の項目は無視される。索引は SourceVaultMailStoreSave 時に自動更新され、既存データには SourceVaultMailRebuildMetadataIndex で一括生成する。opts は SourceVaultSearchMailSnapshots と同じ。**ノートブックに表示するときは View 版 `SourceVaultMailSearchIndexView` を使う**（core=連想を返す純データ関数／View=Dataset+UI+表示件数制限、の役割分担）。
→ List[Association] (SummaryRow 形 + Summary + FromRaw/ToRaw/FromContact/AttachmentCount/ShardKey/AccessTags/IndexSchemaVersion)
例: `SourceVaultMailSearchIndex["報告", "MBox"->"imai", "Limit"->50]`

### SourceVaultMailSearchIndexView[query_String:"", opts]
`SourceVaultMailSearchIndex` の **View 版**。索引 sidecar だけで検索し（**SourceVaultMailEnsureLoaded 不要・シャード非ロード＝速い/省メモリ**）、結果を UI つき Dataset で表示する。行ごとに **✉**（本文表示: その行の shard だけを遅延ロードして復号・別窓表示）と **☰**（スレッド窓: `SourceVaultMailThreadNotebook`）。表示件数は `$SourceVaultMailViewMaxRows` で制限。PL≥0.5 を含む結果は機密ラップ。索引 sidecar 必須 (無ければ `SourceVaultMailRebuildMetadataIndex[]` で構築)。**メール検索のノートブック表示はまずこれを使う**（全シャードロードが不要）。opts は SourceVaultMailSearchIndex と同じ。
→ Pane[Dataset] (UI)
例: `SourceVaultMailSearchIndexView["Zoom", "MBox"->"univ", "SortBy"->"Date", "SortOrder"->"Desc"]`

### SourceVaultMailThreadNotebook[recordIdOrRow, opts]
スレッド全体を **1 つのノートブック窓にアウトライン表示**する (front end)。スレッド＝同一 MBox・正規化件名（Re:/Fwd: 剥がし）一致で、**メンバー特定は索引 sidecar のみ**。本文表示に必要なシャードだけ遅延ロードして復号し、各メールを `Section`（日付＋差出人）＋`Subsection`（件名）＋本文 `Text` のセルグループで並べる＝FE のアウトライン/折りたたみ操作がそのまま効く。全セルはスレッド最大 PrivacyLevel で機密マーク（この窓からの LLM 呼び出しは cloud gate 対象）。開封記録も付く。opts: `"MaxMails"`(50)。
→ Association `<|Status("Shown"|"NoFrontEnd"), Mails, PrivacyLevel, LoadedShards|>`
例: 検索行の ☰ ボタン、または `SourceVaultMailThreadNotebook[recordId]`

### SourceVaultMailIndexGet[recordId_String]
索引 sidecar から該当 RecordId の低漏洩メタ/サマリー行を1件返す (snapshot 本体はロードしない)。MCP の単一 URI 解決 (sourcevault_get) 用。
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

### SourceVaultMailDerivedPending[opts]
→ List[Association] ロード済み store の中で派生未処理の snapshot リスト。
Options: "MBox" -> Automatic (文字列でその mbox に限定), "DateFrom" -> Automatic, "DateTo" -> Automatic (DateObject/文字列/{y,m,d}、日単位包含)
注: オプション付きでも必ず評価されるので `Length[SourceVaultMailDerivedPending["MBox"->"univ", ...]]` は実件数を返す (未評価式の引数数ではない)。
例: `Length[SourceVaultMailDerivedPending["MBox"->"univ", "DateFrom"->{2026,6,1}, "DateTo"->{2026,6,30}]]`

### SourceVaultMailInferDerived[mailspec_Association]
mailspec (date/subject/from/to/cc/body) からローカル LLM で派生を推論する (優先度は構造的に別計算)。Category は $SourceVaultMailCategories のトークン。Deadline は ISO 文字列または Missing["None"]。
→ Association `<|WorkRequest, PrivacyLevel, Category, Deadline, Summary, Status|>`

> **受信者ベースの決定的 privacy フロア (defense-in-depth)**: snapshot に派生を適用する際、LLM 推論 PrivacyLevel に **受信者(To/Cc)由来の下限**を `Max` で additive 適用する。**オーナーが直接の To/Cc 受信者・非 bulk・少数宛 (≤ 4 名)** のメール = 個人/小グループ通信とみなし `PrivacyLevel` を `$SourceVaultMailPersonalPrivacyFloor` (既定 0.6) 以上に保証する (LLM が個人メールの privacy を下げ過ぎて cloud gate を漏れるのを防ぐ)。ML/一斉配信はオーナーが To/Cc に入らず (position=Bulk)・bulk/多数宛は対象外 (floor 0.0)。フロアは privacy を**上げるだけ** (高い LLM 値は下げない)。`$SourceVaultMailPersonalPrivacyFloor = 0.0` で無効化。owner 未設定時は無効。

### SourceVaultInferMailDerivedBatch[opts]
未処理 snapshot の派生をローカル LLM で増分生成し in-place 更新する。CheckpointEvery 件ごとに dirty シャードを保存する (中断耐性)。
**「<mbox> の (期間) メールにサマリーを追加」は SourceVaultMailAddSummaries[mbox, period] を使うこと** (EnsureLoaded を内包し外部ジョブでも自己完結)。本関数を直接呼ぶときは "MBox" で対象 mbox を必ず絞る — 無指定だとロード済み全 mbox を処理する。
→ Association `<|Status, Processed, Skipped, ...|>`
Options: "MBox" -> Automatic (文字列でその mbox に限定 / Automatic=ロード済み全 mbox), "Limit" -> 50 (フィルタ後の件数上限。範囲内全件なら Infinity), "DateFrom" -> Automatic, "DateTo" -> Automatic (DateObject/文字列/{y,m,d} で対象を日付範囲に限定、日単位包含), "Refresh" -> None (None=Pending のみ / "MissingCategory"=Category 未生成の処理済み旧 snapshot も再処理 / All=全件 / Function=述語一致を再処理), "Inferencer" -> (実LLM, 注入可), "CheckpointEvery" -> 20, "Persist" -> True
例: `SourceVaultInferMailDerivedBatch["MBox"->"univ", "Limit"->Infinity, "DateFrom"->{2026,6,1}, "DateTo"->{2026,6,30}]`
例: `SourceVaultInferMailDerivedBatch["Refresh"->Function[s, StringContainsQ[ToString@s["MailMetadataPublic"]["Subject"], "Cerezo"]]]`

### SourceVaultMailAddSummaries[mbox_String, period_:"Latest", opts]
mbox の指定期間を SourceVaultMailEnsureLoaded でロードしてから SourceVaultInferMailDerivedBatch で一括生成・保存する。EnsureLoaded とバッチを内包する正準エントリポイント (外部 WolframScript ジョブへ退避してもロードから自己完結)。**「<mbox> の<期間>メールにサマリーを追加」はこの1関数で完結する** — 直接 EnsureLoaded+InferMailDerivedBatch を組まないこと。period は "Latest"/n日/{年,月}/{年,月,日}/"YYYYMM"/"YYYY" を受ける (「6月」= 当年なら "202606" または {2026,6})。
→ Association `<|Status, MBox, Period, Loaded, Batch|>`
Options: "Limit" -> Infinity, "Persist" -> True
例: `SourceVaultMailAddSummaries["univ", "202606"]`  (univ の 2026 年 6 月メールに一括サマリー)

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

### SourceVaultMailTranslateBody[recordId_String]
メール本文を $Language (表示言語) に翻訳して返す (LLM, headless テスト可)。本文は readable 化 (HTML/改行正規化) してから翻訳する。
→ Association `<|Status->"Ok", Text->訳文, Translated->True, Lang->...|>` または `<|Status->"Error", Reason|>`

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
返信用ウインドウ (To/Cc/件名/本文編集・ファイル添付・確認付き送信) を開く (front end 必須)。
→ Association `<|Status->"ReplyNotebookOpened", Draft|>`
Options: "ReplyAll" -> False (True で全員に返信), "Translate" -> False (True で日本語で書いて元メールの言語に翻訳して送る。旧 maildb replyMailTr 踏襲)

### SourceVaultMailSend[spec_Association]
メールを送信する。spec=`<|"To","Cc","Bcc","Subject","Body","Attachments"->{パス...}|>`。Bcc 省略時、$SourceVaultMailSendBccSelf が True ならオーナー主アドレス宛に控えを送る。$SourceVaultMailSignature が非空なら本文末尾に署名付加。存在しない添付は送信前に弾く。Mathematica の SendMail 設定が必要。
→ Association `<|Status->"Sent", To, Cc, Bcc, Subject, Attachments|>` または `<|Status->"Error", Reason, ...|>`

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
notebook 内の生データ出力セル (SourceVaultMailView / MailDataset / MailSearchSummary / SourceVaultFindTodos 等) を含まれる最大 PL で機密マークする。メールは Derived.PrivacyLevel、Todo はソースノートブックの Publishable による。クラウド LLM (閾値0.5) へはスキーマのみ、ローカル LLM (閾値1.0) へは全文。検出対象は共有レジストリで拡張される (Eagle View 等)。
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

## 横断検索連携 (SourceVaultSummaries provider)

mail は SourceVaultSummaries 横断検索 (eagle/sources 等と混在検索) の provider として自己登録する。`.svmailidx` sidecar のみを走査し本文暗号文はロードしない。共通スキーマ `<|Kind->"mail", Id, URI->"sv://record/<RecordId>", Title(=Subject), Authors(=From), Summary, Date, PrivacyLevel|>` へ投影する (PrivacyLevel 欠落は fail-safe で 1.0)。全文/サマリーの詳細取得は本 API (SourceVaultMailSearchSummary 等) を別途使う。この連携は自動登録のみで公開関数は無い。

## 設定変数

### $SourceVaultMailStoreRoot
型: String, 初期値: PrivateVault/mail/snapshots
mail snapshot store のルート。テストで上書き可能。

### $SourceVaultDefaultImportedMailPL
型: Real, 初期値: 0.85
import 時のメール本文 PL 既定 (fail-safe)。maildb の privacy フィールドは信用しない。

### $SourceVaultMailPersonalPrivacyFloor
型: Real, 初期値: 0.6
個人宛メール (オーナーが直接の To/Cc・非 bulk・少数宛 ≤4 名) の派生 PrivacyLevel 下限。LLM 推論が個人メールの PL を下げ過ぎて cloud gate を漏れるのを防ぐ決定的フロア。0.0 で無効化。owner 未設定時は無効。

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

### $SourceVaultMailSignature
型: String, 初期値: ""
SourceVaultMailSend 送信本文の末尾に付加する署名文字列。空なら付加しない。

### $SourceVaultMailSendBccSelf
型: True | False, 初期値: True
True のとき SourceVaultMailSend は Bcc 省略時にオーナー主メールアドレスを Bcc に入れ、自分に控えを送る。