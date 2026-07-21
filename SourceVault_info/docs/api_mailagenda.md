# SourceVault_mailagenda API

routine attention R9 (mail)。**オーナー宛ての要対応メール**(返信が必要/作業・出席依頼)を
routine アジェンダへ供給する薄い層。maildb の既存派生(Summary/Category/Priority/Deadline =
SourceVaultInferMailDerivedBatch が事前計算)を**索引だけ**で読む(アジェンダ経路で LLM/IMAP/
シャード本体ロードなし)。maildb / identity へは弱結合(不在なら空)。
仕様 = `sourcevault_routine_mail_agenda_spec_v0_1.md`。

## 候補パイプライン

### SourceVaultMailAgendaItems[opts] → <|"Items"→{item...}, "PendingCount"→n|>
窓内(既定 45 日)の索引行を、①カテゴリゲート(TaskRequest/AttendanceRequest/Confirmation
または推定 Deadline あり)→ ②SPAM/無関係ゲート(Priority < $SourceVaultMailAgendaMinPriority
を除外)→ ③**オーナー宛て判定**(To ∋ identity の SourceVaultOwnerEmails → 1.0、To ∋
組織アドレス → 0.6、不足時のみ遅延 snapshot probe: Cc ∋ owner → 0.7、本文冒頭に宛名パターン
「今井」等 → +0.3。閾値 $SourceVaultMailAgendaDirectionThreshold=0.7 以上のみ)→
④解決済み除外(interaction.json の RepliedAt / agenda.json の Dismissed・NotebookCreated)
の順に絞る。item = <|RecordId, Subject, From, Date(abs), Category, Priority, Deadline,
Summary, DirectionScore, DirectionEvidence, MBox|>、新しい順。
Category/Priority 未生成のメールは除外せず PendingCount で返す(見逃し防止。要約計算は
SourceVaultMailAddSummaries[mbox] を明示実行)。
**スレッド(セッション)集約**: 同一スレッド(Re/Fwd を剥いだ正規化件名+MBox、
"ThreadKeyFunction" で mailstructure セッション等に差替可)は 1 項目に集約。代表=
オーナー宛て条件を満たす最新メール(ThreadCount/ThreadRecordIds 付き)。スレッドの
最新受信より後に解決(返信/対応済み)されていれば消え、より新しい Re: が来ると再浮上。
**プライバシー**: "MaxPrivacyLevel"(既定 1.0)を超える派生 PrivacyLevel のメールは
除外(PL 欠落は 1.0 扱い= fail-safe)。item は PrivacyLevel を運ぶ。
Options: "Mails"/"Interactions"/"Resolutions"/"SnapshotProbe"(すべて Automatic=ライブ、
テスト注入可)、"Window", "Now", "MaxItems"(60), "MaxPrivacyLevel"(1.0),
"ThreadKeyFunction"。

## 解決状態機械 (R9-5)

Pending → Done(Replied | NotebookCreated | Dismissed)。返信は既存 maildb の返信ノートブック
送信で interaction.json に RepliedAt が自動記録され、次回から消える。何もしなければ残る。

### SourceVaultMailAgendaResolve[recordId, "Dismissed"|"NotebookCreated", opts]
解決を `<mailStoreRoot>/agenda.json`(Dropbox 共有・内容最小化=RecordId のみ、件名/本文なし)
へ記録。Option "NotebookPath"。

### SourceVaultMailAgendaReopen[recordId] / SourceVaultMailAgendaResolutions[]
解決の取り消し(再列挙される)/ 解決一覧 assoc。

## アクション UI (R9-4)

### SourceVaultMailAgendaOpen[recordId | item]
対応ウィンドウ(FE)を開く: 件名+Summary+明示アクション
**[↩ 返信する]**(SourceVaultMailOpenReplyNotebook; 送信で自動 Done)
**[📓 ノートブックを作成して継承]**(下記 Inherit)
**[✓ 確認のみ・対応済み]**(Resolve Dismissed+ウィンドウ閉)
+ スレッド全体表示(SourceVaultMailThreadNotebook)/ 本文表示。
アジェンダ(SourceVaultRoutineAgendaView の ✉ バンド)の項目クリックがここに来る。

## 継承ノートブック (R9-6)

### SourceVaultMailAgendaInherit[recordId, opts] → <|Status, NotebookPath, RecordId|>
$onWork に作業ノートを作成しメールを**継承**する: newNote 規約のメタセル
`<|Title(件名), Keywords→{"mail"}, Status→"Todo", Deadline(推定〆切), MailRecordId|>`
(InputForm テキストセル=非評価往復可能)+「✉ 元メール・返信を開く」ボタンセル。
NotebookCreated を記録(アジェンダから消える)し、$SourceVaultMailAgendaEventSink へ
継承イベント <|Type→"MailInheritedByNotebook",RecordId,NotebookPath,At|> を emit
(マイニング層 seam、rule 11)。**プライバシー継承**: 作成ノートはメール内容(件名+本文導線)
を含むため TaggingRules→SourceVault→CloudPublishable→False を明示宣言して書き出す
(宣言なしでも PL 1.0 fail-safe だが原則を明示)。Options: "Directory"(Automatic→$onWork),
"Open"(True→SystemOpen), "Deadline", "Title"。

### SourceVaultMailForNotebook[nbPath | NotebookObject] → recordId
継承ノートのメタデータ MailRecordId を**非評価**で読み(NBAccess safe extractor、whitelist
に MailRecordId 追加済み)、SourceVaultMailThreadNotebook でスレッド(後続の返信含む)を開く。
ノートブック→メールの逆参照。

## アジェンダ統合 (routineplan 側)

SourceVaultRoutineAgendaData に "IncludeMail"(Automatic=AccessLevel≥1.0 なら含む) /
"MailItems"(注入) / "MailMaxPrivacyLevel"(既定 1.0、注入項目にも適用) が追加され、
結果に "Mail"→{item...}, "MailPendingCount" を持つ。〆切が明確なメールは日別カレンダー
の該当日に Kind "MailDeadline"(【✉〆切】、クリック→AgendaOpen)としても入る。
SourceVaultRoutineAgendaView の表示順は 日別カレンダー→期限超過→「✉ 要対応メール (n)」
バンド(【依頼】【出席】【確認】タグ+件名クリック→AgendaOpen+(スレッド n 通)+受信日
+〆切日=過去赤/今日明日青/未来黒+Summary 行)。
**バンド内のメール並び順**(view 層のみ、Data の "Mail" は正準の受信新しい順を維持):
①**⚠ 〆切超過**(〆切が現在時刻より過去、超過が大きい順=最も過去の〆切が先頭)→
②**今後の〆切**(〆切が未来、近い順)→ ③**〆切なし**(受信新しい順)。①②③の各グループは
非空のときだけ小見出しを出す(全て〆切なしなら見出しなし)。**秘匿**: PL≥0.5 のメールを 1 通でも
含む View 出力は ClaudeCode`Confidential でラップ(不在時は
SourceVaultMarkConfidentialViewCells を遅延実行)= maildb View と同じ機密規約。

## 一覧側からの差し引き (二度手間回避)

maildb の検索/一覧/View 関数 (`SourceVaultSearchMailSnapshots` / `MailSearchSummary` /
`MailDataset` / `MailView` / `MailSearchIndex` / `MailSearchIndexView`) は
`"ExcludeAgenda"->True` で**このアジェンダが拾っているメール(とそのスレッド)を除外**する。
アジェンダで対応する要対応メールと、一覧で見る「それ以外のメール」を重複なく分けられる。
`"Item"` で代表のみ除外 / `{rid,..}` で明示指定、`"AgendaItems"` に
`SourceVaultMailAgendaItems[]` や `SourceVaultRoutineAgendaData[]` の戻り値を注入すれば
再計算しない (既定 `Automatic` はライブ計算+`$SourceVaultMailAgendaExcludeCacheTTL` 秒キャッシュ)。
詳細 = `api_maildb.md`。

## 設定

$SourceVaultMailAgendaWindow(45)/ MinPriority(0.5)/ DirectionThreshold(0.7)/
OrgAddresses({})/ OwnerAddresses(identity 不在時 fallback {})/ AddresseePatterns({"今井"})/
Categories({TaskRequest,AttendanceRequest,Confirmation})/ EventSink(None)。
個人アドレスはコードに焼き込まず `PrivateVault/config/mailagenda.json`
(OrgAddresses/OwnerAddresses/AddresseePatterns/MinPriority/Window)で環境設定。
