# SourceVault_taskdates API リファレンス

## 概要
作業ノートの 3 つの日付 Deadline / Eventdate / NextReview を扱う純関数モジュール（FE・LLM・ネットワーク不使用）。コンテキストは `SourceVault``。
- Deadline: 実際の〆切がある場合
- Eventdate: ノートが行事（会議・学会等）に関する場合
- NextReview: ノートを再び見る日
- 今日の予定・リマインダーはこの 3 日付で動くため、作業ノートや todo を作る箇所は Deadline と Eventdate をできるだけ抽出して 3 つとも書く。
- キー名は "Eventdate" と綴る（所有者の綴り）。読み取り側は "EventDate" も受理する。
- 値は DateObject[{y, m, d}]。見つからない日付は Missing。
- 依存: NBAccess（NBOnWorkTasks, NBFileSetStatusFields, NBRegisterApprovalHeads）、SourceVault_diagnostics（プローブ登録）、SourceVault_privacy（プライバシー契約・SourceVaultPrivateResult）。いずれも未ロードなら該当機能のみ縮退する。
- 登録: Backfill は承認ヘッド・Private 契約（Exit=Result）、他は Internal 契約、Probe は診断プローブ "TaskDates" として自動登録される。

## 関数

### SourceVaultTaskDateCandidates[text_String, ref_:Automatic] → List[Association]
text 中の日付を出現順に返す。各要素は <|"Date" -> DateObject[{y,m,d}], "YMD" -> {y,m,d}, "Role", "HasTime", "Weekday", "Position" -> {start,end}|>。
- "Role": "Deadline"（「まで」「締切」「〆切」「期限」「必着」「提出」「回答」「申込」等が前後）/ "Event"（「開催」「実施」「会議」「説明会」「研修」「研究会」「日時」等、または時刻が続く）/ "Unknown"。
- 前後の語は隣の日付と文の切れ目（。・改行）で区切る。
- 判定は Deadline 語 → Event 語 → 時刻付き(Event) → Unknown の順。
- "HasTime": 日付直後に時刻（9:00 / 9時 等）が続くか。"Weekday": 直後に曜日（(金) 等）があるか。
- ref: 年の無い日付を最も近い年にする基準。DateObject / 絶対秒 / {y,m,d} / "yyyy-mm-dd" / Automatic（今日）。
- 対応書式: 2026年11月20日・2026/11/20・2026-11-20・令和8年11月20日（元年可）・20261120・11月20日・11/20(金)（年なし m/d は曜日か時刻が続く場合のみ）。NFKC 正規化後に解析。年は 1990–2100 のみ有効。
- 解析不能・非文字列は {}。
例: SourceVaultTaskDateCandidates["11月20日(金)までに提出。12/5 10:00 開催", Now]

### SourceVaultTaskDates[spec_Association, opts]
作業ノート（や todo）の 3 日付を返す。
→ <|"Deadline", "Eventdate", "NextReview", "Basis"|>
spec キー: "Title"（無ければ "Subject"）, "Summary", "Body", "Deadline"（明示値。DateObject か "yyyy-mm-dd"）, "Eventdate"（明示値。"EventDate" も可）, "ReferenceDate"（メールの日付。既定は今日）。
Options: "Now" -> Automatic (今日の基準。DateObject/絶対秒), "ReviewLeadDays" -> Automatic (NextReview を期日の何日前にするか。非負整数、Automatic なら $SourceVaultTaskReviewLeadDays), "DeadlineFromEvent" -> Automatic (Boolean、Automatic なら $SourceVaultTaskDeadlineFromEvent)
- Deadline: 明示値 → 件名の〆切 → 概要・本文の〆切 の順。
- Eventdate: 明示値 → 件名の開催日 → 概要・本文の開催日 の順。件名に限り、曜日のみ続く Unknown 日付（「11月20日(金)の件」）も Event とする。
- ReferenceDate より前の日付は採らない。
- 〆切が無く開催日があるとき Deadline = Eventdate（DeadlineFromEvent が True の場合）。
- NextReview: Now 以降の Deadline と Eventdate のうち早い方の lead 日前（Now より前なら Now の日）。どちらも無ければ Quantity[1, "Weeks"]。
- "Basis": 各キーの出どころ。Deadline/Eventdate は "Explicit" / "Title" / "Summary" / "Body"（Deadline は加えて "Eventdate"）、NextReview は "BeforeDate" / "Default"。
- Association 以外の引数 → 全 Missing・NextReview=Quantity[1,"Weeks"]・Basis=<||>。
例: SourceVaultTaskDates[<|"Title" -> "11月20日(金)締切 報告書", "Summary" -> "12/5 10:00 開催"|>]

### SourceVaultTaskHeaderString[assoc_Association] → String
作業ノートの状態ヘッダー（NotebookStatus のセル）を、編集できる入力文字列にする。
キー順は Keywords, Deadline, Eventdate, NextReview, Status, Title、その他は渡した順。DateObject は `DateObject[{y, m, d}]` 形、他は InputForm。Missing と None の値は書かない。Association 以外 → "<||>"。
例: SourceVaultTaskHeaderString[<|"Keywords" -> {"mail"}, "Deadline" -> DateObject[{2026,12,2}], "NextReview" -> Quantity[1, "Weeks"], "Status" -> "Todo", "Title" -> "件名"|>]

### SourceVaultTaskDatesBackfill[opts]
$onWork の未処理ノートのうち Deadline・Eventdate が無いもの（や NextReview が既定の相対値のもの）に、題名と元のメール（MailRecordId があれば索引の件名・概要・〆切）から日付を求めて書き足す。既にある Deadline・Eventdate は書き換えない。
→ <|"Status" -> "OK", "DryRun", "Checked", "Count", "Written", "Plans" -> {<|"Path", "MailRecordId", "Set" -> <|...|>, "Basis" -> <|...|>, ("Result" -> <|"Status",...|>)|>...}|>（Private 契約・結果はプライバシー出口を通る）
Options: "DryRun" -> True (True は書かずに案を返す。False で NBAccess`NBFileSetStatusFields により書く。FE で開いているノートは書かず "NotebookIsOpen"), "Directory" -> Automatic (NBOnWorkTasks の探索ディレクトリ), "Records" -> Automatic (レコードの Association リストを直接渡す), "MailRow" -> Automatic (関数 rid -> 索引行。既定は SourceVaultMailIndexGet), "Now" -> Automatic (今日の基準), "Paths" -> All (対象パスのリストで絞る)
- 対象: State が Done/Pass/Keep 以外で Path を持つ記録。DeadlineDue と EventDue の両方が既にあるノートは対象外。
- 参照日: 索引行の "Date"、無ければファイル名先頭の yyyymmdd、無ければ更新日。
- NextReview は、日付を何か書き足す場合で、かつ ReviewKind が "Date" でない（所有者の日付が無い）ときのみ設定する。
- 書き込みで NBFileSetStatusFields が無ければ "Result" -> <|"Status" -> "Failed", "Reason" -> "NBAccessUnavailable"|>。
- 不正な引数 → <|"Status" -> "Failed", "Reason" -> "expects [opts]"|>。
例: SourceVaultTaskDatesBackfill[] （案の確認）→ SourceVaultTaskDatesBackfill["DryRun" -> False]

### SourceVaultTaskDatesProbe[opts___] → Association
SystemDoctor の検査（"TaskDates"）。$onWork の未処理ノートについて、題名に日付（〆切・開催日・曜日付き日付）が書かれているのに Deadline も Eventdate も無いもの（"DatesMissing"）と、Deadline か Eventdate を過ぎても未処理のもの（"PastOpen"）を数える。題名やパスは返さない（件数と要約値だけ）。
→ <|"Component" -> "TaskDates", "Health" -> "OK"|"Degraded", "ReasonCode" -> "TaskDatesOK"|"TaskDatesMissing", "OpenNotes", "DatesMissing", "PastOpen", "MissingDigests" (パスの 10 文字ダイジェスト最大 5 件), "Remediation" (DatesMissing があれば Backfill の案内文)|>
NBOnWorkTasks が使えず記録も無い場合 → <|"Health" -> "OK", "ReasonCode" -> "NotApplicable", "Component" -> "TaskDates"|>。
opts（Association 化して参照）: "Records" -> Automatic, "Directory" -> Automatic, "Now" -> Automatic。DatesMissing があれば Degraded。

## 変数

### $SourceVaultTaskReviewLeadDays
型: Integer, 初期値: 1
NextReview を Deadline・Eventdate の何日前にするか。"ReviewLeadDays" オプションで上書き可。

### $SourceVaultTaskDeadlineFromEvent
型: Boolean, 初期値: True
〆切が見つからず開催日があるとき、Deadline を開催日にするか（所有者のノートの書き方）。"DeadlineFromEvent" オプションで上書き可。