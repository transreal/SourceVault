# SourceVault_seriesview API リファレンス

## 概要
Context: `SourceVault``。SourceVault_series (https://github.com/transreal/SourceVault_series) の表示層 (front end のみ。文書 04 §11.9 の core / view 分離、文書 15)。
ビューは core 関数の返す値を描くだけである。ボタンは core の所有者関数 (作業台帳) と SourceVault_mailagenda (https://github.com/transreal/SourceVault_mailagenda) の既存関数を呼ぶ。ここから送信・提出・公開はしない。
表示するのは件名・差出人・日付・状態のみ。メール本文はクリック時に既存のメール窓で開く。
ソースは ASCII のみで、UTF-8 の下書き `SourceVault_seriesview_draft.wl` から変換して生成する。直接編集すると次回変換で失われる。

## 設計メモ
- データは Dynamic の外で計算する。FE は DynamicEvaluationTimeout 後に $Aborted を出すためである。計算はビュー関数 (メイン評価) とボタン (Queued) が行う。
- 計算結果は内部ストア `$iSVSVStore` にビュー id (kind + options のハッシュ) で保持する。保持するのは最新 6 件 ($iSVSVStoreMax)。
- ビューの Dynamic はストアを描くだけである。ストアが空 (カーネル再起動後) か、最後の所有者操作より古い場合は、その旨と「一覧を作る」ボタンを出し、自ら計算しない。
- $iSVSVTick はデータ版で、所有者操作ごとに上がる。$iSVSVDraw は再描画要求のみ。操作元ビューはキュー内ボタンで再計算し、他ビューは古い旨を表示する。
- ボタンは全て Method -> "Queued" で、描画されたビューの id を保持して実行する。ボタンには文字列リテラルのみを持たせる。
- 描画上限: 1 一覧 200 行 ($iSVSVMaxRows)、1 系列内の過去回 12 行 ($iSVSVMaxOccLines)。超過分は注記に件数で出す。
- ボタンに渡すオプションは "MBox", "Window", "MaxPrivacyLevel" のみ (注入されたメール一覧は渡さない)。
- 機密度: ビューは枠作成時のデータの PrivacyLevel で包む。SourceVaultPrivateView があれば使い、なければ 0.5 以上で警告枠を出す。再描画で機密度が上がれば「機密 / Confidential」警告行を出す。
- 描画関数内で SeriesPrivate`$iSVSRNoExit = True を Block して core を呼ぶ。

## 公開関数
### SourceVaultMailTaskProposalsView[opts]
メールを起点にした提案タスクの一覧を表示する。
→ Dynamic を含む Column (機密度に応じ SourceVaultPrivateView 等で包まれる)
行は 1 件の用件 (作業項目)。列は 状態 / 受信 / 〆切 / 差出人 / 件名 / 業務・過去の回 / 対応の案 / 操作。
- 状態: 提案中 (Proposed)・再提案 (Reproposed)・処理中 (InProgress, 本人 / LLM)・保留 (Pending)・処理済み (Done)・却下 (Rejected)・対応不要 (NoAction)・未判定 (Unclassified)。
- 〆切の色: 過去は赤、今日・明日 (2 日以内) は青、それ以降は黒。
- 定型業務の系列と過去の回 (前回の対応つき) を出す。
- 操作ボタンは状態で変わる:
  - 提案中・再提案・未判定: 返信 / ノート / Todo / 保留 (ActionMenu: 明日まで・3 日・1 週間・2 週間・1 か月) / 却下 / 済。SuggestedAction に当たるボタンは強調する。
  - 処理中: 開く (ノート / Todo / 返信)、新着を確認済み (NewMailSinceTracked 時のみ)、済、戻す。
  - 保留: 再開 / 済。
  - 対応不要: タスクにする。
  - 処理済み・却下: 戻す。
- 上の切り替えで「未処理」「未反映」「処理済み」などに絞る。先頭の件数は全状態の合計で、どのメールも数から漏れない。
Options: "Filter" -> "Open" (初期の絞り込み), "Window" (日数), "MBox", "MaxPrivacyLevel", ほか Options[SourceVaultMailTaskProposals] から "States" を除いたもの全て
- "Filter" と "States" は計算側へは渡されない。内部では States -> "Open" の提案と States -> All の全項目 (SourceVaultMailWorkItems) の 2 呼び出しを 1 回の評価で行う。
- 状態の理由は Tooltip に出る。

### SourceVaultSeriesCandidatesView[opts]
メール索引から見つけた定型業務の系列の候補を表示する (名前・周期・回数・各回の日付・次回の予測)。
→ Dynamic を含む Column
件名が違っても件名と概要の内容が近いものは 1 つの系列にまとめて出す。
列: 状態 (確定 / 候補) / 業務 (直近の件名) / 周期 / 回数 (対応済み件数つき) / 直近の回 / 次回の予測 / 操作。
行を開くと次が出る:
- 件名の型 (自動で加わった未確認のものは [この型を外す])
- 各回 ([外す] でそのメールだけ外す)
- 内容の近い別の系列 ([統合する])
操作: [系列にする] で確定、[却下] で以後の提案から外す。
上部に内容比較方式 (意味: ローカル埋め込み / 部分 / 語の一致) の行と業務ラベルの行を出す。
Options: Options[SourceVaultSeriesDiscover] を継承。"IncludeNotifications" -> False (通知メールを含めるか), "MaxPrivacyLevel", ほか SourceVaultSeriesDiscover のオプション全て

### SourceVaultBusinessView[opts]
上位の業務 (件名の違う多くのメールが 1 年を通して属す定型業務) の一覧を表示する。
→ Dynamic を含む Column
所有者が確定した業務と、最近のメールの件名から読んだ候補を出す。各行に年度別の通数 (直近 3 年度 + それ以前) と件名の語、除く語、例を付ける。
[業務として確定] で確定、[業務ではない] で以後の候補から外す。[木を開く] で 1 つの業務の木を別窓で開く。
Options: "Match" -> Automatic (検索の語), ほか Options[SourceVaultBusinessDiscover] 全て

### SourceVaultBusinessView[nameOrId, opts]
1 つの業務の木 (業務 → 年度 → 段階) を表示する。
→ Dynamic を含む Column
- 昨年度の段階 (メールの 1 回分) を日付順に並べ、その右に今年度の対応するメール (状態つき) を出す。
- まだなら「これから (昨年は MM/DD)」(期日超過なら「そろそろ」) か「今年度はまだ届いていません」を出す。
- 続いて今年度だけの段階と過去の年度を出す。
- 到着した今年度の未処理メールには [ノート] / [Todo] / [済] 等を出す。昨年度の対応種別 (ノート・Todo・返信・済) に当たるボタンを強調し、「昨年度は: …」を添える。
- 各段階の [外す] でそのメールを業務から外す (件名に語を含むが別用件のもの)。
- 確定していない名前でも、その語を件名に含むメールで同じ木を見られる。"Match" で検索の語を指定する。
→ 内部では Options に "Ref" -> nameOrId が加わり、SourceVaultBusinessInfo[ref, ...] で計算する。
Options: "Match" -> Automatic, Options[SourceVaultBusinessDiscover] 全て
例: SourceVaultBusinessView["大学入学共通テスト", "Match" -> "共通テスト"]

### SourceVaultSeriesRelatedFilesRefresh[nb, opts] / [nb, recordId, opts]
タスクのノートブックの「関連ファイル」の部分を作り直す。所有者の操作である。
→ <|"Status", "RecordId", "Count", "Groups", "Notes", "Where"|>
nb は NotebookObject またはノートブックのパス (文字列)。
SourceVaultSeriesRelatedFiles で $onWork と Eagle (ScanSnap) を探し直し、前の「関連ファイル」のセル (CellTags SVSeriesRelatedFiles) を外して新しいものを末尾に書く。関連メール (上位の業務・過去の回) もファイルと一緒に書き直す (CellTags SeriesRelatedMail 相当)。
開いているノートブックは FE を通して書き換え、開いていないものはファイルを書き換える。
recordId を省くと (Automatic)、ノートブックの状態セルの MailRecordId を使う。
ノートブック内の [関連ファイルを更新] ボタンがこれを呼ぶ。
失敗時の戻り値:
- 所有者でない: <|"Status" -> "Refused", "Reason" -> "OwnerOnly", "Actor" -> actor|>
- nb が不正: <|"Status" -> "Failed", "Reason" -> "expects a notebook (NotebookObject or path)"|>
- 未保存: "Reason" -> "NotebookNotSaved" (+ "Hint")
- メールへのリンクなし: "Reason" -> "NoMailLink" (+ "Hint": RecordId を第 2 引数に渡す)
- 検索失敗: "Reason" -> "RelatedFilesFailed", "Result" -> 検索結果
Options: Options[SourceVaultSeriesRelatedFiles] を継承。"NotebookPath" は内部で nb のパスに上書きされる (渡しても除かれる)。

### ShowRoutineWorkPalette[] → NotebookObject
メールを起点にした定型業務の機能 (文書 15) を並べた浮動パレットを開く (ShowClaudePalette / ShowSystemDoctorPalette と同じ形)。
既に開いていれば閉じて作り直す。WindowTitle "Routine Work", WindowSize {105, All}, WindowFloating -> True, Saveable -> False, WindowMargins -> {{Automatic, 331}, {Automatic, 4}}。メニューの パレット > Routine Work からも開ける。
パレットの項目:
- 一覧: 提案タスク ("proposals")、予定 ("agenda", SourceVaultRoutineAgendaView)、系列の候補 ("series")、上位の業務 ("business")
- メールの一覧: 業務に未反映 ("mail-untracked", SourceVaultMailSearchIndexView "Work" -> "Untracked")、未処理 ("mail-open", "Work" -> "Open")。どちらも "DateFrom" は $SourceVaultMailWorkWindow 日前から。
- 業務の木を開く / 業務を確定する (名前・件名の語・除く語を入力するダイアログ。確定済みの業務は選択メニューから選べる)
- いま使っているノートブックの関連 (上位の業務・関連ファイル) の書き直し
- ローカルモデルによる比較 (SourceVaultSeriesEmbedRefresh) とラベルの更新 (SourceVaultSeriesLabelRefresh "TimeLimit" -> 240)
- 状態 ("status": 件数・判断・ローカルモデル・台帳、読み込んだコードがディスク上のコードと同じか)
- 台帳 ("ledger": SourceVaultMailWorkEvents を新しい順に最大 200 件)
- 使い方 ("help": 各関数の usage)
パレット自身は計算せず (Dynamic・タイマーなし)、ボタンを押したときだけ計算する。一覧は別窓 (キーごとに 1 窓) に開き、同じボタンをもう一度押すと窓を作り直す。ボタン実行中は ClaudeCode`ClaudeHoldFrontEnd (claudecode が読み込まれている場合) で共有ポーリングを止める。窓は保存できない。

## 内部変数 (参考)
### $iSVSVTick / $iSVSVDraw
型: Integer, 初期値: 0
データ版 / 再描画要求。

### $iSVSVStore
型: Association, 初期値: <||>
ビュー id → <|"Kind", "Opts", "Data", "Tick", "At", "Seconds"|>。

### $iSVSPCreateWindow
型: Automatic | Function, 初期値: Automatic
テスト用。CreateDocument の代わりに Function[{title, content}] を指定する。

### $iSVSPLedgerMax
型: Integer, 初期値: 200
台帳ビューの最大表示件数。

## 内部の表示ラベル
- $iSVSVAction: Reply→返信, Notebook→ノート, Todo→Todo, Confirm→確認のみ
- $iSVSVBasis: SameAsLast→前回と同じ, BusinessLastYear→昨年度の同じ段階と同じ, Category→分類から
- $iSVSVHandling: Replied→返信, Notebook→ノートブック, Todo→Todo, MarkedDone→処理済みにした, Dismissed→確認のみ, Rejected→却下, None→記録なし
- 日付表示は "月/日(曜) HH:MM"。曜日は 月火水木金土日。

## 利用上の注意
- ビュー関数は評価時にメイン評価でデータを計算するため、実メールストアでは時間がかかる。表示は Dynamic (DynamicEvaluationTimeout -> 60) がストアを描くだけである。
- 所有者でないアクターのボタン操作は core 側で Refused になり、「操作を記録できませんでした」のダイアログが出る。
- 関連パッケージの依存: SourceVault_series (core)、SourceVault_mailagenda (SourceVaultMailAgendaOpen / SourceVaultMailShowBody)、SourceVault_todo (SourceVaultTodoShowSummary, 任意)、SourceVault_searchview (SourceVaultMailSearchIndexView, 任意)、SourceVault_routine (SourceVaultRoutineAgendaView, 任意)。