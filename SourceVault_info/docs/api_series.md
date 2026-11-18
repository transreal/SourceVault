# SourceVault_series API リファレンス
Context: `SourceVault``。ソースは ASCII のみで、UTF-8 草稿から生成される。このファイルは直接編集しない。

## 概要
作業系列モジュール(文書 04「定型業務の検出と自動化」v0.4 のメール入口部分)。文書 15 に基づき、仕事の多くはメールから始まるものとして扱う。
(1) メール索引を作業項目に分ける。1 件の用件はスレッドの 1 回分で、同じ件名が数か月後に再び来た場合は新しい項目になる。全項目にちょうど 1 つの業務状態を付け、黙って落とす項目を作らない。
(2) 送信元ドメイン × 件名の正規形から、定型業務の系列(周期 Month / Quarter / Term / Year)を索引だけで検出する。新しい項目を過去の回と、所有者がその回をどう処理したかに結び付ける(文書 04 6.1 節)。
(3) 所有者の判断を追記専用の台帳に残す。台帳は機械・月ごとに 1 ファイルで、ID と状態のみを持ち、メール本文は持たない。
決定的に動く。LLM、ネットワーク、メール本文は使わず、索引の行だけを読む。
副作用は E0(読み取り)のみ。E1/E2a は所有者の操作時だけで、台帳 1 行の追記と、既存 mailagenda 関数によるノートブックまたは todo の作成である。
状態を変える関数は所有者の操作(NBAccess の承認ヘッド)。束縛された Model / MCP / Service 主体は提案と自分の進捗報告しかできない。
LLM を使うのは SeriesLabelRefresh(ローカル LLM)と SeriesEmbedRefresh(ローカル埋め込み)だけで、どちらも所有者の操作。送り先はローカルのみで、クラウドには送らない。

## 作業状態
Proposed(提案中) / Reproposed(再提案) / InProgress(処理中。Actor は "Owner" か "LLM") / Pending(保留) / Done(処理済み) / Rejected(却下) / NoAction(対応不要) / Unclassified(未判定)
`SourceVaultMailWorkStatesFor` の指定: "Open" = 未処理(Proposed, Reproposed, InProgress, Pending, Unclassified)、"Untracked" = 業務に未反映(Proposed, Reproposed, Unclassified)、"Closed" = Done, Rejected, NoAction。

## 作業項目・状態

### SourceVaultMailWorkItems[opts]
メール索引を作業項目に分け、全項目に状態を 1 つ付けて返す。
→ <|"Items", "Counts", "Total", "MaxPrivacyLevel"|> (Counts の合計 = Total)
Options: "States" (All | "Open" | "Untracked" | 状態名 | そのリスト), "Window" (日数。既定は $SourceVaultMailWorkWindow), "Mails", "Interactions", "Resolutions", "Events", "Todos", "NotebookLinks", "OwnerEmails", "Now" (以上は試験用の差し替え), "MBox", "MaxPrivacyLevel"

### SourceVaultMailWorkStateMap[rids | All, opts] → Association
RecordId -> <|"State", "Label", "Short", "Actor", "WorkId", "Tracked", "Flags"|>。メール一覧の「業務」列と絞り込みが使う。

### SourceVaultMailWorkBadge[e] → Expr
業務状態の短い印を返す。e は StateMap の値か作業項目。状態名は Tooltip に出る。

### SourceVaultMailWorkStatesFor[spec] → {状態名...}
絞り込みの指定を状態名のリストにする("Open" / "Untracked" / "Closed" は上記)。

### SourceVaultMailWorkAct[ref, action, opts]
作業項目(ref は RecordId か WorkId)に所有者の判断を記録する。
action: "Accept" ("Via" -> "Notebook" | "Todo" | "Reply" | "Manual"), "Reject" (却下), "Defer" ("Until" -> 日数 | DateObject), "Done" (処理済み), "Reopen" (判断を取り消す), "Propose" (対応不要と判定された項目をタスクにする), "NoAction" (対応不要)
モデルが呼べるのは "Propose"・"LLMStart"・"LLMDone" だけ。
記録先は追記専用の台帳 `<mail store>/work/events-<機械>-<年月>.jsonl` で、ID と状態だけを書く。

### SourceVaultMailWorkAccept[ref, via]
提案を採用し、実際の作業の入れ物を作る。台帳に Accept を記録し、項目は「処理中」になる。
via "Notebook": 継承ノートブックを $onWork に作る。過去の回の関連資料の一覧付き。添付のあるメールと繰り返す業務の項目は、<日付>-<題名> のフォルダを作ってその中に置く。
via "Todo": 単独の todo を作る。
via "Reply": 返信ノートブックを開く。

### SourceVaultMailWorkEvents[] → {Association...}
台帳の出来事(全機械分)を時刻順に返す。

### SourceVaultMailTaskProposals[opts]
未処理の作業項目に、系列(定型業務)の照合・過去の回の一覧・前回の対応・対応の案を付けて返す。表示は SourceVaultMailTaskProposalsView。
Options: SourceVaultMailWorkItems と同じ。ただし "States" の既定は "Open"。

## 系列(定型業務)

### SourceVaultSeriesDiscover[opts]
メール索引から定型業務の系列の候補を決定的に探す(文書 04 4.2 節のメール部分)。LLM は使わない。確定は所有者(SourceVaultSeriesConfirm)。
まとめる鍵は、差出人のドメイン × 件名の正規形(年度・日付・番号を除く)。件名が違っても、件名と概要の内容が近いものは 1 つの系列にまとめる。
間隔の中央値から周期(Month / Quarter / Term / Year)を推定する。月次は 3 回以上、年次・学期は 2 回以上で候補にする。不規則な間隔は候補にしない。

### SourceVaultSeriesRelated[ref, opts]
作業項目(RecordId か WorkId)に対応する過去の回、その回の対応(返信・ノート・todo・確認のみ)、題名の近い作業ノートを返す(文書 04 6.1 節)。確認していない系列による対応には "MatchStatus" -> "Proposed" が付く。

### SourceVaultSeriesConfirm[seriesId]
系列の候補を所有者が確定する(L0 の記録)。

### SourceVaultSeriesReject[seriesId]
系列の候補を却下する。却下した候補は再提案されず、関連の提示にも使われない。

### SourceVaultSeriesMerge[{seriesId, seriesId, ...}]
件名の型の違う系列を 1 つにまとめる(所有者の操作)。

### SourceVaultSeriesDetach[seriesId]
自動でまとめられた件名の型を系列から外す(所有者の操作)。以後は内容が近くても自動ではまとめない。

### SourceVaultSeriesAddMail[seriesId, ref, opts]
メール(ref は RecordId か WorkId)を系列に加える(所有者の操作)。
Options: "Generalize" -> True (True ならそのメールの件名の型も系列に加え、以後同じ件名のメールは自動で系列に入る)

### SourceVaultSeriesRemoveMail[ref, opts]
メールを系列から外す(所有者の操作)。外すのはそのメールだけで、同じ件名の新着は引き続き系列に入る。

### SourceVaultSeriesInfo[seriesId, opts]
1 つの系列の中身を返す。
→ 件名の型 (Members。自動で加わった未確認のものを含む)、各回 (Occurrences) と対応、周期、内容の近い別の系列 (Similar)

### SourceVaultSeriesDecisions[] → Association
SeriesId -> "Confirmed" | "Rejected"。

### SourceVaultSeriesGenericTitles[opts] → {Association...}
件名が用件を表さない(通知の語だけでできている)ため系列にしないメールの件名を返す。「お知らせ」「同報」のように、あらゆる通知が同じ件名で届くものが当たる。
行: <|"Title", "Sender" (差出人のドメイン), "Count" (用件の数), "Mails", "FirstDate", "LastDate", "PrivacyLevel"|>
こういう件名のメールは、系列にも「前回に対応した」の持ち上げにもならず、新しいメール 1 通ごとに別の用件として扱う(返信は元のメールの用件に入る)。判定の語は $SourceVaultSeriesGenericTitleWords。

## 上位業務(Business)
複数の件名にまたがる上位の定型業務(例:「大学入学共通テスト」)を扱う。

### SourceVaultBusinessConfirm[name, opts]
上位業務を所有者が確定する。業務に属するのは、件名に "Match" の語(既定は name。短い形「共通テスト」を指定できる)を含み "Exclude" の語を含まないメールと、SourceVaultBusinessAddMail で加えたメールで、SourceVaultBusinessRemoveMail で外したメールは除く。
2 つの業務の語を両方含む件名は、語の長い方の業務に入る。
name に BusinessId (biz-...) か確定済みの名前を渡すと、その業務の "Match"・"Exclude" を書き換える。
確定した業務の新着メールは点数によらず提案に上がり、「予定」の帯に出る(昨年度の対応する段階を確認のみ・却下にしていたものは除く)。
Options: "Match" (検索の語), "Exclude" (除外する語)

### SourceVaultBusinessReject[nameOrId, opts]
業務の候補を「業務ではない」と記録する(以後は候補に出さない)。確定済みの業務には確定を取り消す。
Options: "Match" (検索の語)

### SourceVaultBusinessAddMail[nameOrId, ref, opts]
件名に業務の語を含まないメール(ref は RecordId か WorkId)を、確定した業務に加える。

### SourceVaultBusinessRemoveMail[nameOrId, ref, opts]
件名に業務の語を含むが別の用件のメールを、確定した業務から外す。

### SourceVaultBusinessInfo[nameOrId, opts]
1 つの業務の木を返す。業務 → 年度の回 ("Years"、4 月始まり、新しい順) → 段階 ("Steps")。
段階はメールの 1 回分ごとに、日付・件名・添付・対応・業務の状態・ノートブック・前の年度の対応する段階 ("Counterpart") を持つ。
"Progress" は昨年度の段階を日付順に並べ、今年度に対応するメールが届いたか ("Arrived")、これからか ("Upcoming"。昨年の日付の 1 年後が目安 "ExpectedAt")、時期を過ぎても届いていないか ("NotArrived") を示す。
"New" は今年度だけの段階。"Upcoming" は今後 "UpcomingDays" 日に時期が来る段階。
確定していない名前を渡すと、その語("Match" で短い形を指定できる)を件名に含むメールで同じ形の木を作る ("Confirmed" -> False)。
木は保存せず、呼ぶたびに索引と台帳から計算する。
Options: "Match", "UpcomingDays" -> 45

### SourceVaultBusinessDiscover[opts]
確定した業務 ("Confirmed") と、最近 ("RecentDays") のメールの件名から読んだ業務の候補 ("Candidates") を返す。
候補は、2 つ以上の年度にまたがって同じ名前が件名に現れるもので、"MaxCandidates" 件まで。
候補にするのは、3 種類以上の違う件名が同じ名前で始まるものだけ。同じ件名が繰り返し届くだけのものは系列であって上位の業務ではない。多くの件名の末尾に現れる一般的な語も候補にしない。
各行は名前・検索に使う語・年度ごとの通数・件名の種類の数 ("Patterns") を持つ。却下した候補と確定した業務に含まれる名前は出さない。LLM は使わない。
Options: "RecentDays" -> 120, "MaxCandidates"

## 予定・関連ファイル

### SourceVaultSeriesAgendaItems[opts]
所有者が確定した系列(定型業務)に届いた新着メールのうち、所有者の確認が要るものを「予定」の一覧用に返す。
→ <|"Items", "Count", "MaxPrivacyLevel"|>
項目の "Need":
- "CreateNotebook": 新着があり、タスクのノートブックがまだ無い(確認して作る)。
- "ReviewNewMail": ノートブックや Todo で進行中の回に、その後で新着が届いた(確認する)。
"DueT" はメールの〆切。無ければ前回の対応までの日数から出した目安。
確定した系列の新着は、分類や重要度の点数によらず提案に上がる(理由 "SeriesConfirmed")。
SourceVaultRoutineAgendaData / View がこれを読み、期日のある項目を日ごとの一覧に、全部を「定型業務の新着」の帯に出す。
状態は保存せず、呼ぶたびに索引と台帳から計算する。

### SourceVaultSeriesRelatedFiles[ref, opts]
作業項目(RecordId か WorkId)に関連するファイルを探して返す。
→ <|"Groups", "Count", "Notes", "MaxPrivacyLevel"|>
グループは 4 種。
- "Own": この業務のノートブックが入っているプロジェクトのフォルダのファイル。
- "Previous": 過去の回のノートブックが入っているフォルダのファイル(ノートブックとメールのリンクで決まる)。
- "OnWork": $onWork の直下で、名前の中身が近いフォルダとファイル(未確認の候補)。
- "Eagle": Eagle の $SourceVaultSeriesRelatedEagleFolders のフォルダ(既定 ScanSnap)で、題名・要約・タグが系列のメールの内容と近いもの(未確認の候補)。
"Own" と "Previous" は決定的なリンクで "Confirmed" -> True。"OnWork" と "Eagle" は候補で False。
ファイルの中身は読まない(名前だけ。Eagle は保存済みの要約とタグ)。
SourceVaultMailWorkAccept[ref, "Notebook"] がノートブックを作るときにこの一覧を「関連ファイル」として書き込む。ノートブック中の [関連ファイルを更新] (SourceVaultSeriesRelatedFilesRefresh) で作り直せる。

## 埋め込み(意味の近さ)

### SourceVaultSeriesEmbedRefresh[opts]
件名の型ごとの「件名 + 概要」を、ローカルの埋め込みモデル (Global`$embeddingEndpoint / Global`$embeddingModel) でベクトルにして保存する(同期しない LocalState/series/embeddings.wxf)。
保存済みの分は計算しない。送る前に距離の上限の検査 (ClaudeLocalLLMAccessCheck) を通し、クラウドには送らない。
モデルに届かないときは何も変えず、理由と対処を返す(系列の結び付けは語の一致に落ちる)。所有者の操作。
Options: "TimeLimit" -> 300 (秒)

### SourceVaultSeriesEmbedStatus[] → Association
意味による比較の状態を返す。有効か、モデルと送り先、最後に届いたか、届かない理由 (Reason) と対処 (Hint)、保存済みのベクトルの数、いまの比較の方式 ("Mode": "Semantic" | "Partial" | "Lexical")。

## ラベル(業務ラベル)

### SourceVaultSeriesLabelRefresh[opts]
件名の型ごとの「件名 + 概要」に、ローカルの LLM で業務のラベル(「学生の欠席指導」のような短い名詞句)を付けて保存する(同期しない LocalState/series/labels.wxf)。
既にあるラベルの一覧を見せ、同じ業務なら同じラベルを使わせるので、語を共有しない言い換えも同じラベルになる。
ラベルが同じで差出人のドメインが同じ件名の型は、未確認の型として 1 つの系列にまとまる(まとめるかどうかは決定的な規則で、モデルは判定しない)。
モデルはツールなし・思考なしの補完で呼び、送り先はローカルだけ(距離の上限の検査つき)。使えないときは理由と対処を返し、結び付けは埋め込みと語の一致に落ちる。
所有者の操作。
Options: "TimeLimit" -> 600 (秒), "MaxDocuments" -> 300

### SourceVaultSeriesLabelStatus[] → Association
業務のラベルの状態を返す。有効か、最後に届いたか、届かない理由 (Reason) と対処 (Hint)、保存済みのラベルの数、未ラベルの件名の型の数。

## 変数・パラメータ

### $SourceVaultMailWorkRoot
型: String, 初期値: Automatic (<mail store>/work)
台帳の置き場。試験で差し替える。

### $SourceVaultMailWorkWindow
型: Number(日), 初期値: 60
作業項目として一覧に出す期間。

### $SourceVaultSeriesWindow
型: Number(日), 初期値: 1100
系列の検出と過去の回の照合に使う期間。

### $SourceVaultMailWorkProposeThreshold
型: Number, 初期値: 0.5
この点数以上を提案にする。

### $SourceVaultMailWorkEpisodeGapDays
型: Number(日), 初期値: 10
同じ件名の新しい (Re: でない) メールがこの日数より後に届いたら別の回にする。

### $SourceVaultMailWorkMaxReplyGapDays
型: Number(日), 初期値: 45
Re: でもこの日数より空いたら別の回にする。

### $SourceVaultMailWorkMinPriority
型: Number, 初期値: 0.25
重要度がこれ未満のメールは、過去に対応した系列でなければ提案にしない。

### $SourceVaultMailWorkDeadlineLeadDays
型: Number(日), 初期値: 3
却下した項目を、〆切のこの日数前に再提案する。

### $SourceVaultMailWorkSubjectCues
型: {String...}, 初期値: {"依頼", "お願い", "相談", "ご確認", "確認依頼", "回答", "提出", "締切", "〆切", "出欠", "調査", "照会", "要返信", "ご意見", "査読", "推薦", "申請", "至急", "リマインド", "request", "please", "action required", "reminder", "rsvp", "review"}
件名にあれば依頼の手がかりにする語のリスト。

### $SourceVaultMailWorkStateLabels
型: Association, 初期値: 状態名 -> <|"Label", "Short"|>
状態名から表示名と短い印への対応。

### $SourceVaultSeriesGenericTitleWords
型: {String...}
件名からこれらの語(と年度・番号・ひらがな・記号)を除いて 2 字未満しか残らなければ、その件名は用件を表さないとみなし、系列の鍵にしない。
既定は通知・連絡の語(お知らせ・同報・通知・連絡・案内・配信・報告・相談・依頼・確認 など)。語を足す・減らすことができる。

### $SourceVaultSeriesLinkThreshold
型: Number, 初期値: 0.35
件名と概要の内容がこの類似度以上で、共通の語が 3 つ以上、差出人のドメインが同じ件名の型を、自動で 1 つの系列にまとめる。

### $SourceVaultSeriesSuggestThreshold
型: Number, 初期値: 0.15
この類似度以上の系列を「内容の近い系列」として示す。

### $SourceVaultSeriesEmbedding
型: Automatic | False, 初期値: Automatic
Automatic なら、保存済みのベクトルがあれば意味の近さも系列の結び付けに使い、無ければ語の一致だけを使う。False なら埋め込みを使わない。

### $SourceVaultSeriesSemanticThreshold
型: Number, 初期値: 0.40
埋め込みの類似度(全体の平均を引いたベクトルのコサイン)がこの値以上で、差出人のドメインが同じ件名の型を、自動で 1 つの系列にまとめる。0.30 以上で共通の語が 2 つあるものもまとめる。

### $SourceVaultSeriesSemanticSuggestThreshold
型: Number, 初期値: 0.25
埋め込みの類似度がこの値以上の系列を「内容の近い系列」として示す。

### $SourceVaultSeriesEmbedAutoMax
型: Integer, 初期値: 40
未計算の件名の型がこの数以下なら、一覧を作るときに自動で埋め込みを計算する。0 で自動の計算をしない。多いときは SourceVaultSeriesEmbedRefresh か一覧のボタンで行う。

### $SourceVaultSeriesRelatedEagleFolders
型: {String...}, 初期値: {"ScanSnap"}
関連ファイルを探す Eagle のフォルダ名のリスト(子フォルダも含む)。{} なら Eagle を見ない。

### $SourceVaultSeriesEagleAutoLoad
型: Automatic | True | False, 初期値: Automatic
関連ファイルを探すときに Eagle の層 (SourceVault_eagle.wl) が読み込まれていなければ、一度だけ読み込むかどうか。Automatic は FE のあるカーネルでだけ読み込む。True は常に、False は読み込まない(そのときは Notes に "EagleUnavailable" が入る)。

### $SourceVaultSeriesRelatedMaxFiles
型: Integer, 初期値: 12
関連ファイルの 1 グループに載せる件数の上限。

### $SourceVaultSeriesLabeling
型: Automatic | False, 初期値: Automatic
Automatic なら、保存済みの業務のラベルを系列の結び付けに使う。False なら使わない。ラベルを付けるのは SourceVaultSeriesLabelRefresh を呼んだときだけ。

## 補足
- RecordId と WorkId は互換で、WorkId は "wrk-" + 最初のメールの RecordId。
- 作業項目の分割は、同じスレッドキー(MBox|正規化件名)を時刻順に見て、$SourceVaultMailWorkEpisodeGapDays と $SourceVaultMailWorkMaxReplyGapDays で回を切る。
- 一般的な件名(通知の語だけ)のスレッドは、返信でなければ近い時刻でも別の回になる。
- 系列の鍵は "<送信元ドメイン>|<件名の正規形>"。語が無い場合や一般件名では鍵を持たない。
- 台帳のイベント ID は "wev-" で始まり、時刻 → 機械内カウンタ → 乱数の順に整列する。
- 埋め込みの保存先は LocalState/series/embeddings.wxf。ラベルの保存先は LocalState/series/labels.wxf。
- 埋め込みは他モデルのベクトルを無効にし、モデルが使えないときは 10 分間は自動の再試行をしない。