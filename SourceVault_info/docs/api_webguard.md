# SourceVault_webguard API リファレンス

## 概要
SourceVault_webguard は LLM の Web egress guard (関所)・ホスト identity・アクセスログを提供するモジュールである。リポジトリ: https://github.com/transreal/SourceVault_webguard
- 背景: ローカル LLM の Web アクセスは sourcevault_web_search / sourcevault_get_document に限られるが、URL やクエリ文字列へデータを符号化すれば外へ出せる。webingest の SourceVaultWebSearch / SourceVaultWebFetch の入口で次を照合し Allow / Ask / Deny を決める。
  1. URL / クエリの不審度 (決定的・LLM 不使用)
  2. その LLM 呼び出しに渡るデータの PrivacyLevel (文脈 PL。claudecode が申告)
  3. ホスト (ドメイン) の identity と AccessLevel (使用実績から推定・オーナー決定で更新)
- Ask はオーナーに問い合わせる (FE があれば ChoiceDialog、service kernel なら承認 queue)。すべて id 付きで記録する。
- パッケージ: `SourceVault`` コンテキスト (private は `SourceVault`WebGuardPrivate``)。
- 読み込み: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_webguard.wl"]]`
- service-loadable: core 以外に依存しない。identity / privacy / diagnostics / claudecode は弱結合 (DownValues / Names で存在確認)。FE 依存はダイアログのみ ($Notebooks で分岐)。
- fail-closed: guard 未ロード時は webingest 側 (iWebGuardGate) が LLM 主体を Deny する。文脈 PL 不明なら $SourceVaultWebGuardUnknownContextPL (0.5) = 私的データあり側に倒す。
- 設定変数は再 Get で上書きしない (未定義時のみ初期化)。
- 保存先: PrivateVault/identity/webhosts.jsonl (ホスト profile, Dropbox 同期)、PrivateVault/identity/webaccess_review.json、LocalState/hotlog/web_access (ログ。JSONL をプロセス別シャード YYYY-MM-p<pid>.jsonl で追記)、LocalState/webguard/{context,pending,decisions}。
- Actor: HumanUser/Owner は Kind "Owner" (文脈 PL 0・常に Allow)。Provider+Model があれば Kind "Model"、無ければ MCPClient。

## 解析 (純関数)
### SourceVaultWebGuardAnalyzeURL[url] → Association
URL の形から不審度を決定的に計算する (LLM 不使用)。非 String 引数は ToString される。
戻り値: <|Url, Host, Scheme, Port, Suspicion (0..1), Class -> "Plain"|"Opaque"|"Exfil", Reasons -> {理由...}, OpaqueTokens, OpaqueChars, Flags, Length|>
opaque トークン = 16 字以上の英数塊 (hex 32 字以上 / 高エントロピー英数混在 / 大小文字+数字 24 字以上 等)。UUID は Opaque 扱いしない。
YouTube の 11 字 id は Plain、Google Docs の 44 字 id は Opaque、長い符号化塊は Exfil。
パース不能 URL は Suspicion 1.0 / Class "Exfil" / Reasons {"UnparsableURL"}。
加点理由: NonHTTPScheme, UserInfoInURL, EmptyHost, IPLiteralHost, NonStandardPort 等。
Class 閾値: Suspicion >= ExfilScore → Exfil、>= OpaqueScore → Opaque、他 Plain。

### SourceVaultWebGuardAnalyzeQuery[query] → Association
検索クエリの形から不審度を計算する。非 String 引数は ToString される。
戻り値: <|Query (先頭 500 字), Suspicion, Class, Reasons, OpaqueTokens, PIIHints -> {"EmailAddress"|"LongDigitRun"|"SecretKeyword"...}, Length|>
PIIHints はスコアに足さず、文脈 PL が高いときに Ask の根拠になる。
LongDigitRun は 8 桁以上の数字列 (YYYYMMDD 形の日付は除く)。SecretKeyword は password / api key / secret / bearer / パスワード / 暗証。
加点: opaque トークン 1 個 0.5、合計 128 字以上 0.3、300 字超 0.3、3 行以上 0.2。

### SourceVaultWebGuardDecide[spec] → Association
判定表 (spec §8) を純関数で評価する。
spec: <|"Kind" -> "Fetch"|"Search", "ContextPL" -> pl, "Analysis" -> 解析, "Profile" -> ホスト view|>
→ <|Decision -> "Allow"|"Ask"|"Deny", Reason, Reasons, Level|>
Search の規則 (順に評価): Class Exfil → Ask/ExfilShapedQuery; ctx <= LowRiskPL → Allow/LowRiskContext; Class Opaque → Ask/OpaqueQueryWithContext; ctx >= PrivatePL かつ PIIHints あり → Ask/PIIInQueryWithPrivateContext; 他 Allow/Policy。
Fetch の規則はホスト profile (TrustStatus Blocked は Deny 等) と EffectiveLevel と文脈 PL の比較による。

## 関所本体
### SourceVaultWebGuardCheck[request] → Association
Web アクセス 1 件の関所。文脈 PL の解決 → 不審度 → ホスト profile → 判定表 → Ask なら ticket / prompter → ログ。無効な引数は Deny / "InvalidRequest"。
request: <|"Kind" -> "Fetch"|"Search", "Url" -> _, "Query" -> _, "Actor" -> <|"Type" -> "HumanUser"|"MCPClient", ...|>, "Channel" -> "MCP"|"Notebook"|.., "ContextPL" -> (任意・明示), "Provider"/"Model" (任意), "SessionId" (任意)|>
Kind 省略時は Query キーがあれば Search、無ければ Fetch。
文脈 PL 解決順: 明示 ContextPL → Owner なら 0.0 → SourceVaultWebGuardContext[] の PrivacyLevel。
戻り値: <|Decision -> "Allow"|"Deny"|"Pending", Reason, Reasons, DecisionBy, DecisionDetail, RequestId, Message (モデル向け英文), Host, ContextPL, Actor, Analysis, Profile, LogEventId|>
Search の Host は "websearch"。$SourceVaultWebGuardEnabled が False なら Allow/GuardDisabled (ログは残す)。Owner actor は Allow/OwnerActor。
Ask の場合: 未消費 ticket (AllowOnce/Deny) があれば 1 回だけ消費。無ければ pending request を作り prompter で処理。DecisionBy は "Policy"|"Owner"|"Ticket" 等。
webingest の SourceVaultWebSearch / SourceVaultWebFetch から呼ばれる。

### SourceVaultWebGuardDeclareContext[assoc] → Association
LLM 呼び出し直前に claudecode が呼ぶ文脈申告。
assoc: <|"Provider" -> p, "Model" -> m, "PrivacyLevel" -> pl, "URL" -> _, "SessionId" -> _|>
メモリと LocalState/webguard/context/<provider>.json の両方に置く (service kernel は file を読む)。TTL ($SourceVaultWebGuardContextTTLSeconds) 内の最大 PL が文脈 PL になる。不正引数は $Failed。

### SourceVaultWebGuardContext[] → Association
現在の実効文脈 PL を返す。
<|PrivacyLevel, Source -> "Declared"|"Evaluation"|"Unknown", Declarations -> {申告...}, Freshest -> 最新申告|>
SourceVaultEvaluationPrivacy[] (弱結合) が申告最大値より高ければ Source "Evaluation"。申告も評価も無ければ $SourceVaultWebGuardUnknownContextPL で "Unknown"。

### SourceVaultWebGuardStatus[] → Association
関所の状態を返す。Version, Enabled, Policy, UnknownContextPL, Context (Declarations 除く), Prompter ("Dialog"|"Queue"|設定値), PendingRequests (件数), KnownHosts (件数), ReviewStatus, Paths (Profiles/Log/Pending/Context/Review), Modules (Identity/Privacy/Diagnostics 等の有無)。

## ホスト identity / AccessLevel
### SourceVaultWebHostProfile[host] → Association
ホスト (ドメイン) の実効 profile view を返す。host は正規化される (小文字・www. 除去)。
<|Host, IdentifierId, AccessLevel (保存値), EffectiveLevel (推定との Max), TrustStatus -> "Observed"|"Approved"|"Blocked", PolicySource -> "Default"|"Builtin"|"Estimated"|"Owner", Confidence, AccessCount (全機), LocalAccessCount, DistinctDays, Suspicious, Denied, Approved, Established, Estimate, FirstSeen, LastSeen, Builtin, ByActor|>

### SourceVaultWebHostProfiles[] → {Association...}
既知ホスト (profile または実績あり) 全件の view リストを返す (core 版)。

### SourceVaultWebHostProfilesView[] → Dataset 表示
SourceVaultWebHostProfiles の Dataset 表示版。空なら「既知ホストはありません」。

### SourceVaultWebHostSetAccess[host, level, opts] 
ホストの AccessLevel をオーナーが明示設定する。推定はこの値を上下させない。level は 0..1 に Clip。
→ 保存した profile Association (host 空なら Failure["EmptyHost"])
Options: "TrustStatus" -> "Approved", "PolicySource" -> "Owner", "Note" -> Missing[] (文字列で記録), "Persist" -> True (webhosts.jsonl に保存), "Confidence" -> 1.0

### SourceVaultWebHostBlock[host, opts]
ホストを遮断する (TrustStatus "Blocked"、level 0.0。文脈 PL に関係なく Deny)。SourceVaultWebHostSetAccess と同じ Options を取る。
→ profile Association

### SourceVaultWebHostEstimateAccess[host] → Association
使用実績からの AccessLevel 推定 <|Host, Level, Basis -> "Default"|"Builtin"|"Established", Confidence|>。
Established = 累計 >= EstablishedCount (20)・DistinctDays >= 3・不審 0・拒否 0 → PrivatePL (0.5)。自動では 0.5 までしか上げない。

### SourceVaultWebHostRecomputeProfiles[opts]
ローカル実績を profile の StatsByMachine[<自機>] に写し、Owner 設定・Blocked でないホストの AccessLevel/PolicySource/Confidence を推定で更新して保存する。identity ロード済みなら識別子登録と保存も行う。月次レビュー (SourceVaultWebAccessMarkReviewed) から呼ばれる。
→ <|Status -> "OK", Hosts, Changed, Machine, Path|>
Options: "Persist" -> True

### SourceVaultWebHostStorePath[] → String
webhosts.jsonl のパス ($SourceVaultWebHostRoot で上書き可)。解決不能なら $Failed。

## 承認 queue
### SourceVaultWebGuardPendingRequests[] → {Association...}
未決 (TTL 内・未決定) の許可待ち request のリストを作成日時順で返す。各要素に AgeSeconds が付く。

### SourceVaultWebGuardResolveRequest[requestId, decision, opts]
オーナーの決定を記録する。decision: "AllowOnce" | "AllowHost" | "Deny" | "BlockHost"。
AllowHost は SourceVaultWebHostSetAccess (level 既定 Max[PrivatePL, 要求時文脈 PL]、Approved/Owner)、BlockHost は SourceVaultWebHostBlock を profile に反映。AllowOnce/Deny は同じ (種別, 対象, 主体) 署名の次の呼び出しで 1 回だけ消費される ticket になる (TTL = $SourceVaultWebGuardPendingTTLSeconds)。ログに Decision "OwnerDecided" を追記する。
→ 決定 record Association。不正 decision は Failure["InvalidDecision"]、不明 id は Failure["RequestNotFound"]。
Options: "Level" -> Automatic (AllowHost 時の AccessLevel), "Note" -> Missing[]

### SourceVaultWebGuardProcessPending[] → Association
未決 request を 1 件ずつ prompter (FE ならダイアログ) に出して決定する。FE では共有 polling tick から自動で呼ばれる。
→ <|Status -> "Processed", Resolved, Pending|>。Prompter Automatic かつ FE 無しなら <|Status -> "NoFrontEnd", Pending, Resolved -> 0|>。

### SourceVaultWebGuardStartPendingWatch[] → Association
claudecode の共有 polling tick (ClaudeRegisterPollingTick) に未決 request の監視を登録する (10 秒間隔)。FE カーネルではロード時に自動登録 (opt-out: Global`$SourceVaultWebGuardDisableAutoWatch = True)。
→ <|Status -> "Registered"|"ClaudeCodeAbsent", Key, Watching|>

### SourceVaultWebGuardStopPendingWatch[] → Association
監視登録を解除する。→ <|Status -> "Unregistered"|"ClaudeCodeAbsent", Key|>

## ログ / 集計 / View
### SourceVaultWebAccessLog[opts] → {Association...}
LLM Web アクセスログ (LocalState/hotlog/web_access) を新しい順の Association リストで返す (core 版)。
Options: "Days" -> 30, "Since" -> Automatic, "Until" -> Automatic (DateObject・ISO 文字列・AbsoluteTime), "Actor" -> All (ActorId または表示名部分一致), "Host" -> All (完全一致またはサフィックス), "Kind" -> All ("Search"|"Fetch"), "Decision" -> All, "MinSuspicion" -> 0, "Limit" -> All, "IncludeOwnerDecisions" -> True (False で Decision "OwnerDecided" 行を除外)

### SourceVaultWebAccessLogView[opts]
SourceVaultWebAccessLog の Dataset 表示版 ($SourceVaultWebAccessViewMaxRows 行まで描画)。行の文脈 PL 最大が 0.5 以上なら SourceVaultPrivateView で赤枠 + PL バッジを付ける。opts は SourceVaultWebAccessLog と同じ。

### SourceVaultWebAccessSummary[opts] → Association
期間集計 <|Days, Since, Until, Total, ByKind, ByDecision, Suspicious, ByActor, ByHost, NewHosts, PendingRequests, OwnerDecisions, ReviewStatus, MaxContextPL|> (core 版)。
Options: "Days" -> 30, "Since" -> Automatic, "Until" -> Automatic

### SourceVaultWebAccessSummaryView[opts]
見出し統計 + ホスト別 / 主体別 Dataset + 「レビュー済みにする」ボタンの表示版。opts は SourceVaultWebAccessSummary と同じ。SystemDoctor の月次レビュー催促 (WebAccessReview) からはこれを見て SourceVaultWebAccessMarkReviewed[] を呼ぶ。

### SourceVaultWebAccessMarkReviewed[opts] → Association
サマリーをレビューした事実を PrivateVault/identity/webaccess_review.json に記録し、ホスト profile 再計算も行う。
→ <|LastReviewedAtUTC, Machine, ReviewedPeriodDays, Total, Suspicious, Denied, Pending, NewHosts, Note|>
Options: "Note" -> Missing[], "Recompute" -> True (SourceVaultWebHostRecomputeProfiles を呼ぶ)

### SourceVaultWebAccessReviewStatus[] → Association
<|LastReviewedAt, DaysSince, Due, IntervalDays, NextDueAt, LastReview|> を返す。

### SourceVaultWebAccessReviewProbe[opts] → Association
SystemDoctor probe "WebAccessReview"。前回レビューから $SourceVaultWebGuardReviewIntervalDays 日超でアクセスがあれば Degraded / WebAccessReviewDue、PendingStaleSeconds 以上放置の許可待ちがあれば Degraded / WebAccessApprovalPending (ReasonCodes に併記)。正常時 Health "OK" / ReasonCode "WebAccessReviewOK"。10 分キャッシュ。
Options: "UseCache" -> True, "Now" -> Automatic, "PendingStaleSeconds" -> 120
ロード時に SourceVaultDiagnosticsRegisterProbe があれば自動登録される。

## 設定変数
### $SourceVaultWebGuardVersion
型: String, 初期値: "0.1"
SourceVault_webguard.wl の版。

### $SourceVaultWebGuardEnabled
型: Boolean, 初期値: True
False で関所を素通し (Allow/GuardDisabled。ログは残す)。

### $SourceVaultWebGuardRequired
型: Boolean, 初期値: True
guard 未ロード時に webingest が LLM 主体を Deny するか。

### $SourceVaultWebGuardPolicy
型: Association, 初期値: <|"LowRiskPL" -> 0.2, "PrivatePL" -> 0.5, "DefaultHostLevel" -> 0.2, "EstablishedCount" -> 20, "EstablishedDays" -> 3, "OpaqueScore" -> 0.4, "ExfilScore" -> 0.8|>
判定閾値。欠けたキーは既定値にフォールバックする。

### $SourceVaultWebGuardUnknownContextPL
型: Number, 初期値: 0.5
文脈 PL が分からないときに使う値。

### $SourceVaultWebGuardContextTTLSeconds
型: Number, 初期値: 900
文脈申告の有効時間 (秒)。

### $SourceVaultWebGuardPendingTTLSeconds
型: Number, 初期値: 600
許可待ち request / ticket の有効時間 (秒)。

### $SourceVaultWebGuardPrompter
型: Automatic | "Queue" | "Deny" | Function, 初期値: Automatic
Automatic は FE があれば ChoiceDialog、無ければ queue。関数は f[request] -> "AllowOnce"|"AllowHost"|"Deny"|"BlockHost" を返す。

### $SourceVaultWebGuardBuiltinHosts
型: Association, 初期値: 公知ホスト (wikipedia.org, arxiv.org, github.com, youtube.com, google.com, python.org, wolfram.com, stackoverflow.com, nih.gov, ieee.org, springer.com, nature.com, go.jp, ac.jp 等) -> 0.5
公知ホスト -> AccessLevel の表 (サフィックス一致)。未見でも 0.5 から始める。

### $SourceVaultWebAccessViewMaxRows
型: Integer, 初期値: 200
View の描画行数上限。

### $SourceVaultWebHostRoot
型: String | 未設定
文字列にすると webhosts.jsonl / webaccess_review.json の保存先を上書きする (テスト用)。

### $SourceVaultWebGuardReviewIntervalDays
型: Number, 初期値: 30
月次レビューの間隔 (日)。

## 使用例
例: SourceVaultWebGuardCheck[<|"Kind" -> "Fetch", "Url" -> "https://arxiv.org/abs/2401.00001", "Actor" -> <|"Type" -> "MCPClient"|>, "Channel" -> "MCP", "Provider" -> "lmstudio", "Model" -> "qwen"|>]
例: SourceVaultWebGuardDeclareContext[<|"Provider" -> "lmstudio", "Model" -> "qwen", "PrivacyLevel" -> 0.5|>]
例: SourceVaultWebGuardResolveRequest["wg-...", "AllowHost", "Level" -> 0.5]
例: SourceVaultWebAccessLog["Days" -> 7, "Kind" -> "Fetch", "Decision" -> "Deny"]