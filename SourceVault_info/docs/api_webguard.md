# SourceVault_webguard API リファレンス

## 概要
SourceVault_webguard は LLM の Web egress guard (関所)・ホスト identity・アクセスログ・行き先の評判・方針の提案・所有者判断の記録・裏付け検査の記録を提供するモジュールである。リポジトリ: https://github.com/transreal/SourceVault_webguard
- 背景: ローカル LLM の Web アクセスは sourcevault_web_search / sourcevault_get_document に限られるが、URL やクエリ文字列へデータを符号化すれば外へ出せる。webingest の SourceVaultWebSearch / SourceVaultWebFetch の入口で次を照合し Allow / Ask / Deny を決める。
  1. URL / クエリの不審度 (決定的・LLM 不使用)
  2. その LLM 呼び出しに渡るデータの PrivacyLevel (文脈 PL。claudecode が申告。会話があれば会話の高水位)
  3. ホスト (ドメイン) の identity と AccessLevel (使用実績から推定・オーナー決定で更新)
  4. 行き先の評判 (手元のリスト照合。SourceVaultWebReputation)
- Ask はオーナーに問い合わせる (FE があれば ChoiceDialog、service kernel なら承認 queue)。すべて id 付きで記録する。FetchDecision / SearchDecision が "Verify" (既定) のときは個別に尋ねず、行き先の評価・検索語の形・会話の段で決め、止めるときは理由と次の手段を返す。
- パッケージ: `SourceVault`` コンテキスト (private は `SourceVault`WebGuardPrivate``)。
- 読み込み: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_webguard.wl"]]`
- service-loadable: core 以外に依存しない。identity / privacy / diagnostics / claudecode は弱結合 (DownValues / Names で存在確認)。FE 依存はダイアログのみ ($Notebooks で分岐)。
- fail-closed: guard 未ロード時は webingest 側 (iWebGuardGate) が LLM 主体を Deny する。文脈 PL 不明なら $SourceVaultWebGuardUnknownContextPL (0.5) = 私的データあり側に倒す。
- 設定変数は再 Get で上書きしない (未定義時のみ初期化)。
- 保存先: PrivateVault/identity/webhosts.jsonl (ホスト profile, Dropbox 同期)、PrivateVault/identity/webaccess_review.json、PrivateVault/identity/owner_decisions-<機>.jsonl、LocalState/hotlog/web_access (ログ。JSONL をプロセス別シャード YYYY-MM-p<pid>.jsonl で追記)、LocalState/hotlog/grounding、LocalState/webguard/{context,pending,decisions,conversations,conversation-resets.jsonl}。
- Actor: HumanUser/Owner は Kind "Owner" (文脈 PL 0・常に Allow)。Provider+Model があれば Kind "Model"、無ければ MCPClient。所有者かどうかは $SourceVaultPrincipal で決まる (Actor は自己申告)。
- 所有者専用関数 (SourceVaultWebGuardConversationReset / SourceVaultWebReputationUpdate (service も可) / SourceVaultPolicyProposalResolve / SourceVaultOwnerDecisionReconfirm) は主体が OwnerFE / OwnerCode (Update は Service も) でなければ Failure["WebGuardNotAuthorized"]。NBAccess の承認 head。FE からは SourceVaultIntegrityOwnerAction[...] で包む。
- 段 (Stage): 会話の高水位 PL が <= LowRiskPL で 0、>= PrivatePL で 2、その間 1。段 2 かつ $SourceVaultWebGuardPrivateStage が "Restrict" なら外部検索を拒否し、取得は検索結果にそのまま出た URL・依頼文の URL・所有者許可ホストに限る (承認は出さない)。

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

### SourceVaultWebGuardNamedHosts[text] → {String...}
文章が名指ししているウェブのホスト名を書かれた順に返す (小文字、最大 8 個)。拾うのは http(s) URL のホストと、スキーム無しのドメイン名 (www. 始まり、または .com .org .jp 等で終わるもの)。メールの @ の後ろ・ファイル名 (foo.wl)・コードの属性参照 (logger.info) は拾わない。通信しない。非 String は {}。
関所は依頼文ホストの覚え (実在しないときの断り文)、ツールループは裏付け検査 (依頼文のホストを開いたか) に使う。

## 関所本体
### SourceVaultWebGuardCheck[request] → Association
Web アクセス 1 件の関所。文脈 PL の解決 → 不審度 → ホスト profile → 評判 → 判定表 → Ask なら ticket / prompter → ログ。無効な引数は Deny / "InvalidRequest"。
request: <|"Kind" -> "Fetch"|"Search", "Url" -> _, "Query" -> _, "Actor" -> <|"Type" -> "HumanUser"|"MCPClient", ...|>, "Channel" -> "MCP"|"Notebook"|.., "ContextPL" -> (任意・明示), "Provider"/"Model" (任意), "SessionId" (任意)|>
Kind 省略時は Query キーがあれば Search、無ければ Fetch。
文脈 PL 解決順: $SourceVaultWebGuardSession があれば高水位 (明示 ContextPL とは Max。他会話の申告は使わない) → 明示 ContextPL → Owner なら 0.0 → SourceVaultWebGuardContext[] の PrivacyLevel。
戻り値: <|Decision -> "Allow"|"Deny"|"Pending", Reason, Reasons, DecisionBy, DecisionDetail, RequestId, Message (モデル向け英文), Host, ContextPL, Actor, Analysis, Profile, LogEventId|>
Search の Host は "websearch"。$SourceVaultWebGuardEnabled が False なら Allow/GuardDisabled (ログは残す)。Owner actor は Allow/OwnerActor。
モデルが組み立てた URL の初めてのホストは取得前に DNS で実在確認 (Policy HostCheck)。実在しなければ Deny / "HostDoesNotExist" (所有者には尋ねない)。名前解決自体が使えないときは止めない。
検索は V11 の送り先規則: 段 1 以上の検索と機密の指紋に一致する検索語は SearchEngines にだけ送る (結果の SearchRoute "EnginesOnly")。SearchTermMaxPL 以上の資料から取った語は Deny / "PrivateRecordTermInSearch"。
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

## URL の出所 (provenance)
### SourceVaultWebGuardNoteURLs[urls, source, opts] → Association
モデルが組み立てたのではない URL (検索結果に出た URL など) をこのカーネルで $SourceVaultWebGuardProvenanceTTLSeconds の間覚える (W0)。覚えた URL をそのまま取得するときは符号化部分があっても通す (Reason "From" <> source)。urls は String または List、opts は Association (省略時 <||>)。
opts: "Query" -> q (q の語 (8 文字以上) を含む URL は覚えない)、"PrivateTerms" -> True (機密の語を含む検索の結果であることを覚える。取得は止めず、記録に FoundWithPrivateTerms を付けて月次集計で数える)。
→ <|Noted, SkippedEchoesQuery, Size|>。SourceVaultWebSearch が検索のたびに呼ぶ。
例: SourceVaultWebGuardNoteURLs[{"https://example.com/a"}, "SearchResult", <|"Query" -> "..."|>]

### SourceVaultWebGuardURLProvenance[url] → String | None
url (断片 #... を除き、スキームとホストは小文字で照合) の出所 ("SearchResult" など)。未記憶・期限切れは None。
SourceVaultWebGuardURLProvenance[] → <|Size, BySource, TTLSeconds, MaxURLs|>

## 会話の状態 (W1/W2/V1)
### $SourceVaultWebGuardSession
型: Association | None, 初期値: None
ローカル LLM のツールループが Block で設定する会話の状態 <|"PL" -> 高水位, "Channel" -> _, "JobId" -> _|>。高水位 = その会話でモデルに渡した中身の PL の最大 (下がらない)。ループの外では None (従来の判定)。

### SourceVaultWebGuardSessionStage[pl] → Association
会話の高水位 pl の段 <|"Stage" -> 0|1|2, "PL", "Restrict", "LowRiskPL", "PrivatePL"|>。"Restrict" は段 2 で外向きを絞るか ($SourceVaultWebGuardPrivateStage)。
SourceVaultWebGuardSessionStage[] は $SourceVaultWebGuardSession の PL で同じものを返す (ループの外では Stage None)。

### SourceVaultWebGuardSessionNote[kind, text, opts] → Association
ツールループの会話に読んだものを書き込む (W2)。ループの外では何もしない。→ <|Noted, Kind, Added|>
kind: "Request" (利用者の依頼文。語は機密の指紋から除き、URL はそのまま取るなら出所あり。段 2 でも)、"Secret" (機密の結果。人名・番号・ID・メール・辞書にない英字語・漢字カタカナ語を会話ごとの塩つきハッシュで指紋化。平文は持たない)、"Public" (公開の結果。語を指紋から除く)、"Page" (取得ページ。"Public" と同じ + 本文 URL をページのリンクとして覚える)。
Options: "Classes" -> (Secret 用。"Strong" で日本語の語を除く), "Web" -> False (Public 用。True でカーネル全体の公開語にも足す), "Parent" -> (Page 用。ページの URL)

### SourceVaultWebGuardSessionNoteToolResult[toolName, args, text, observedPL] → Association
ツールループ 1 回の結果 text を会話に書き込む (W2)。observedPL > LowRiskPL (0.2) なら "Secret"、sourcevault_get_document の URL 取得なら "Page"、sourcevault_web_search なら公開 ("Web")、他は "Public"。

### SourceVaultWebGuardSessionSummary[] → Association
<|PL, Stage, FingerprintKeys, FingerprintByClass, AllowedChars, Links (出所ごとの数), LinkBitsUsed, LinkBitsBudget, PublicCorpusChars|>。指紋の語は返さない。ループの外では <|Session -> None|>。

### SourceVaultWebGuardConversation[id] → Association
会話 id (claudecode が履歴ヘッダーに置く ID) について関所が覚えている高水位 <|"PL", "Known", "Stage", "RaisedBy", "UpdatedAtUTC"|>。覚えが無ければ PL 0・Known False。ツールループが同じ会話の次の往復の高水位の初期値に使う。別会話には引き継がない。保存は LocalState/webguard/conversations (ファイル名は id のハッシュ、中身は PL と時刻のみ)。

### SourceVaultWebGuardConversationNote[id, pl, raisedBy] → Association
会話 id の高水位を Max[今の値, pl] にする (上げるだけ)。→ <|"PL", "Raised", "Known"|>。ツールループが開始時と高水位上昇のたびに呼ぶ。

### SourceVaultWebGuardConversationReset[id] → Association | Failure
会話 id の高水位の覚えを消す (所有者専用。非所有者は Failure["WebGuardNotAuthorized"])。→ <|"Reset", "Known", "PreviousPL"|>。記録は LocalState/webguard/conversation-resets.jsonl。ふつうは履歴を消せば ID が新しくなり 0 から始まるので不要。FE から: SourceVaultIntegrityOwnerAction[SourceVaultWebGuardConversationReset[id]]

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
Options: "TrustStatus" -> "Approved", "PolicySource" -> "Owner", "Note" -> Missing[] (文字列で記録), "Persist" -> True (webhosts.jsonl に保存), "Confidence" -> 1.0, "ListOverride" -> (True で評判リスト (ホスト単位) に載っていてもこのホストは止めない (V7)。URL 自体がリストにあるページは止める。False で外す。許可をやめる・遮断すると自動で外れる)
所有者の判断として owner_decisions に記録される (V8)。

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

## 行き先の評判 (V4/L3)
### SourceVaultWebReputation[hostOrUrl] → Association
行き先の評価 <|Host, Rating, Listed, URLListed, Trust, DNSFilter, Lookalike, Verifier, VerifierReason|>。
Rating: "Malicious" (URL がリストにある・ホストが 2 つ以上のリストにある・フィルタ付き DNS が遮断) / "Suspicious" (ホストが 1 つのリストにある) / "Good" (所有者許可・公知ホスト表・実績十分・上位サイト表) / "Neutral"。Lookalike は既知ホストと 1 文字違いのときその相手。
照合は手元のリストのみで通信しない (フィルタ付き DNS を選び所有者が呼んだときを除く)。関所は取得のたびに同じ評価を使う。

### SourceVaultWebReputationStatus[] → Association
<|Verifier, Reason, DNSFilter, Sources, Directory|>。Verifier は "OK" (止める側リストが 1 つ以上期限内、またはフィルタ付き DNS 使用) か "Unavailable"。Unavailable の間も段 0 の取得は止めない。段 1 では実績の無いホストへの取得を止める。

### SourceVaultWebReputationUpdate[opts] → Association | Failure
評判リストを取り直す (所有者か service 専用。それ以外 Failure["WebGuardNotAuthorized"]。ローカル状態が無ければ Failure["NoLocalState"])。既定では期限の半分を過ぎたものと未取得のみ取る。取得先は $SourceVaultWebReputationSources の固定 URL で、こちらからは何も送らない。中身が少なすぎる応答は採らず前のリストを残す。service の定期処理が自動で呼ぶ。
→ <|Updated, Skipped, Failed, Status|>
Options: "Sources" -> All (名前のリストで限定), "Force" -> False (True で新しくても取り直す), "MaxSources" -> Infinity (1 回に取り直す数)
例: SourceVaultIntegrityOwnerAction[SourceVaultWebReputationUpdate[]]

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

## 方針の提案 (V7)
### SourceVaultPolicyProposals[opts] → {Association...}
関所が繰り返し止めた対象 (ホスト・検索語) について「許可するか・このままか・遮断するか」を所有者に尋ねる提案のリストを重要な順に返す (core 版)。URL・検索語の抜粋を含む (privacy 区分 Private)。
各件: <|ProposalId, TargetKind ("Host"/"Search"), Target, Reason, Count, Conversations, FirstAt, LastAt, MaxContextPL, SuggestedLevel, Actors, Examples, Material (実在・評判・実績・所有者の設定), Options, Status, PresentedAtUTC, ExpiresAtUTC, Decision, …|>
Options: "Status" -> "Open" ("Deferred" (1 日上限超過で後日回し) | "Resolved" | "Withdrawn" | All), "Refresh" -> Automatic (10 分より古ければ集計し直す)

### SourceVaultPolicyProposalsRefresh[] → Association
関所の記録を集計して提案を作り直す。ProposalWindowDays (7) 日内に同じ対象が ProposalMinCount (3) 回以上、または ProposalMinConversations (2) 会話以上で止まっていれば 1 件作る。所有者に出すのは 1 日 ProposalDailyLimit (5) 件まで (超過は後日)。無応答の提案は ProposalExpireDays (14) 日で取り下げる (現状維持。無応答を承認としない)。「このまま」・取り下げ対象は ProposalQuietDays (30) 日出さない。通信しない。
→ <|Created, Updated, Reopened, Withdrawn, Presented, Open, Deferred, PresentedToday, DailyLimit|>。service の定期処理と probe が呼ぶ。

### SourceVaultPolicyProposalResolve[proposalId, choice, opts]
提案に所有者が答える (所有者専用。非所有者 Failure["WebGuardNotAuthorized"])。
choice (提案の Options のどれか): "Keep" | "AllowHost" | "AllowDespiteList" (リスト掲載を承知で許可) | "RaiseLevel" | "BlockHost" | "Unblock"。
Options: "Level" -> (許可する機密度。既定は提案の SuggestedLevel), "Note"
答えは提案の記録と関所の記録 (OwnerDecided) に残り、提示から決定までの秒数とその日の何件目かも残る。
例: SourceVaultIntegrityOwnerAction[SourceVaultPolicyProposalResolve[id, "AllowHost", "Level" -> 0.5]]

### SourceVaultPolicyProposalsView[] → 表示
いま所有者に出している提案の表示版 (FE)。対象・回数・会話数・材料・選択肢と変化を並べ、ボタンは答えの式を下のセルに置く (評価すると反映。答えなければ現状のまま)。

### SourceVaultPolicyProposalsProbe[] → Association
SystemDoctor probe "PolicyProposals"。所有者に出している提案があれば Degraded / PolicyProposalsOpen (文面は件数のみ)。10 分キャッシュ。

## 所有者の判断の記録 (V8)
### SourceVaultOwnerDecisions[opts] → {Association...}
関所についての所有者の判断の記録を新しい順に返す (core 版)。対象: ホストの許可・遮断・機密度変更、提案への回答、承認の窓での回答、関所設定の切り替え (気づいた時点で記録)、再確認。
Options: "Days" -> 30, "Direction" -> All ("Loosen"|"Tighten"|"Neutral"), "Target", "Limit"
各件: <|At, DecisionId, Action, Direction, TargetKind, Target, Via ("PolicyProposal"|"Dialog"|"Direct"|"Review"|"Detected"), Ref, Previous, New, Seconds (分からなければ -1), NthThatDay, MaterialDigest, Principal, Machine|>
追記のみ。機ごとのファイル。検索語や URL は入れない。

### SourceVaultOwnerDecisionSummary[opts] → Association
所有者の判断の集計。Options: "Days" -> 30
<|Days, Decisions, ByDirection, ByVia, Loosened, WallHeight (許可ホスト数・機密を読んだ会話に許可した数・リストを承知で許可した数・遮断数・緩めている設定), FastApprovals (数と割合), ConsecutiveLoosening, Inconsistent, ReconfirmDue (ReconfirmDays より長く再確認していない緩和), Posture|>
指標は見るためのもので、これで何かが止まることは無い。

### SourceVaultOwnerDecisionReconfirm[All | {host..}]
緩めた設定 (許可ホスト。All なら緩めている関所設定も) を「見直して、続ける」と記録する (所有者専用。非所有者 Failure["WebGuardNotAuthorized"])。設定自体は変えない。次に再確認が要るのは ReconfirmDays (30) 日後。やめるときは SourceVaultWebHostSetAccess[... , "TrustStatus" -> "Observed"] を使う。

### SourceVaultOwnerDecisionReviewView[opts] → 表示
所有者の判断の見直し表示 (FE)。壁の高さ・指標・この 30 日に緩めたもの・再確認が要るものを並べ、操作は式を下のセルに置く。月次レビュー (SourceVaultWebAccessSummaryView) から開く。Options: "Days" -> 30

## 裏付けの検査の記録 (V9)
### SourceVaultGroundingNote[rec] → Association
ツールループの裏付け検査の結果 1 件を記録する (LocalState/hotlog/grounding/YYYY-MM-p<pid>.jsonl)。claudecode が回答ごとに呼ぶ。受け取る鍵のみ: Status (Grounded|Partial|Ungrounded|BackendUnavailable|WebNotAvailable|NotApplicable|NotNeeded)、PartialReason、Rule、件数 (Searches, SearchesWithResults, SearchesRefused, BackendFailures, Fetched, FetchFailed, FetchRefused, Internal, FallbackSearches, ClaimsChecked, ClaimsSupported, Cited, CitedVerified)、SentBack、OutputSHA256・FinalSHA256、ConversationId、AtUTC、AtUnixMs、Machine。依頼文・検索語・回答本文・ホスト名・URL は入らない。
→ <|"Noted" -> True|False, "Reason"|>

### SourceVaultGroundingLog[opts] → {Association...}
裏付け検査の記録を新しい順に返す。Options: "Days" -> 30, "Status" -> (Status 値、またはラベル "Grounded"|"Partial"|"Ungrounded"|"NotNeeded"。"Ungrounded" は検索障害・外部検索不可の会話も含む), "Limit"

### SourceVaultGroundingSummary[opts] → Association
裏付け検査の指標。Options: "Days" -> 30
<|Days, Total, NotNeeded, Needed (分母), ByStatus, Grounded, Partial, Unconfirmed, UngroundedRate, PartialRate, PartialByReason, SentBack, Claims, Citations, AfterRefusal|>。見るためのもので何も止めない。

### SourceVaultGroundingOfText[text] → Association
LLM の回答 text の裏付け判定を引き当てる: <|"Grounding" -> "Grounded"|"Partial"|"Ungrounded"|"NotNeeded"|"Unknown", "Source" -> "Record" (回答の SHA-256 が記録にあった)|"Mark" (先頭の [SourceVault] の印)|None|>。TurnWiki 等の取り込みが未確認回答を知識に入れないために使う。記録も印も無ければ Unknown (止める理由にしない)。

## ログ / 集計 / View
### SourceVaultWebAccessLog[opts] → {Association...}
LLM Web アクセスログ (LocalState/hotlog/web_access) を新しい順の Association リストで返す (core 版)。
Options: "Days" -> 30, "Since" -> Automatic, "Until" -> Automatic (DateObject・ISO 文字列・AbsoluteTime), "Actor" -> All (ActorId または表示名部分一致), "Host" -> All (完全一致またはサフィックス), "Kind" -> All ("Search"|"Fetch"), "Decision" -> All, "MinSuspicion" -> 0, "Limit" -> All, "IncludeOwnerDecisions" -> True (False で Decision "OwnerDecided" 行を除外)

### SourceVaultWebAccessLogView[opts]
SourceVaultWebAccessLog の Dataset 表示版 ($SourceVaultWebAccessViewMaxRows 行まで描画)。行の文脈 PL 最大が 0.5 以上なら SourceVaultPrivateView で赤枠 + PL バッジを付ける。opts は SourceVaultWebAccessLog と同じ。

### SourceVaultWebAccessSummary[opts] → Association
期間集計 <|Days, Since, Until, Total, ByKind, ByDecision, Suspicious, ByActor, ByHost, NewHosts, PendingRequests, OwnerDecisions, ReviewStatus, MaxContextPL, SearchRoutes, FoundWithPrivateTerms|> (core 版)。
SearchRoutes (V11): 検索の送り先の数 <|Open, EnginesOnly, WithPrivateTerms, RecordTermRefused, StageRefused|> と境 SearchTermMaxPL。FoundWithPrivateTerms: 機密の語で検索して見つけたページの取得 <|Fetched, UnknownReputation, Hosts|>。
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
型: Association, 初期値: <|"LowRiskPL" -> 0.2, "PrivatePL" -> 0.5, "DefaultHostLevel" -> 0.2, "EstablishedCount" -> 20, "EstablishedDays" -> 3, "OpaqueScore" -> 0.4, "ExfilScore" -> 0.8, "PageLinkBits" -> 32, "FingerprintTermAction" -> "Log", "HostCheck" -> True, "FetchDecision" -> "Verify", "Reputation" -> True, "SearchDecision" -> "Verify", "ProposalWindowDays" -> 7, "ProposalMinCount" -> 3, "ProposalMinConversations" -> 2, "ProposalDailyLimit" -> 5, "ProposalExpireDays" -> 14, "ProposalQuietDays" -> 30, "ReconfirmDays" -> 30, ...|>
判定閾値。欠けたキーは既定値 ($iWGDefaultPolicy) にフォールバックする。追加キー (SearchEngines, PrivateStageSearch "EnginesOnly", SearchTermMaxPL 0.9, FastDecisionSeconds 等) も同様。
- PageLinkBits: 段 1 の会話で取得ページのリンクから選んで開ける情報量の合計 (ビット、W2)。
- FingerprintTermAction: 機密指紋のうち日本語の語だけ一致したときの扱い ("Log" = 記録のみ、"Ask" = 承認)。
- HostCheck (V2): モデルが組み立てた URL の初めてのホストを DNS で実在確認するか。
- FetchDecision (V4) / SearchDecision (V7): "Verify" は個別に尋ねず評価と形で決め、止めるとき理由と次の手段を返す。"Ask" は以前の動き (承認の窓)。
- Reputation: 評判リストに載ったホスト・URL を止めるか (どちらの判定でも効く)。
- Proposal*: 方針の提案の条件 (SourceVaultPolicyProposalsRefresh 参照)。
- ReconfirmDays: 緩めた設定を再確認に並べる日数 (0 以下や非数で並べない。期限が来ても何も取り消さない)。
- SearchEngines (V11): 公開でない資料を読んだ会話の検索を送ってよい検索エンジン (SearXNG のエンジン名。有効なものとの共通部分)。既定 google・google cse・bing・brave・yahoo・duckduckgo・startpage・qwant・mojeek・wikipedia・wikidata・arxiv・crossref。段 1 以上の検索と機密指紋に一致する検索語はここだけに送る。予備経路もこの一覧に対応するものだけで公式サイトのサイト内検索はしない。
- PrivateStageSearch: 段 2 の検索の扱い (既定 "EnginesOnly"。"Deny" で V10 までの動き)。
- SearchTermMaxPL: 既定 0.9。以上の資料から取った語は検索エンジンにも送らない (Reason "PrivateRecordTermInSearch")。None で制限しない。

### $SourceVaultWebGuardUnknownContextPL
型: Number, 初期値: 0.5
文脈 PL が分からないときに使う値。

### $SourceVaultWebGuardContextTTLSeconds
型: Number, 初期値: 900
文脈申告の有効時間 (秒)。

### $SourceVaultWebGuardPendingTTLSeconds
型: Number, 初期値: 600
許可待ち request / ticket の有効時間 (秒)。

### $SourceVaultWebGuardProvenanceTTLSeconds
型: Number, 初期値: 7200
SourceVaultWebGuardNoteURLs で覚えた URL の有効時間 (秒)。

### $SourceVaultWebGuardProvenanceMaxURLs
型: Integer, 初期値: 5000
覚えておく URL の上限 (超えたら古いものから忘れる)。

### $SourceVaultWebGuardPrivateStage
型: String, 初期値: "Restrict"
機密を読んだ後 (会話の高水位 >= PrivatePL) の外向きの扱い。"Restrict" = 外部検索を外し、取得は検索結果にそのまま出た URL と所有者許可ホストに限る。"Guard" = 従来の判定 (文脈 PL は高水位で上がる)。"Guard" 以外は "Restrict" と同じ。代入は NBAccess の承認対象。

### $SourceVaultWebGuardPrompter
型: Automatic | "Queue" | "Deny" | Function, 初期値: Automatic
Automatic は FE があれば ChoiceDialog、無ければ queue。関数は f[request] -> "AllowOnce"|"AllowHost"|"Deny"|"BlockHost" を返す。

### $SourceVaultWebGuardBuiltinHosts
型: Association, 初期値: 公知ホスト (wikipedia.org, arxiv.org, github.com, youtube.com, google.com, python.org, wolfram.com, stackoverflow.com, nih.gov, ieee.org, springer.com, nature.com, go.jp, ac.jp 等) -> 0.5
公知ホスト -> AccessLevel の表 (サフィックス一致)。未見でも 0.5 から始める。

### $SourceVaultWebReputationSources
型: Association
評判リストの取得元 (名前 -> <|Kind ("Block"/"Trust"), Format, URL, Enabled, MaxAgeHours, …|>)。既定は OpenPhish 公開フィード・JPCERT/CC phishurl-list (止める側)、Tranco 上位サイト表 (正の手がかり)。使わないものは "Enabled" -> False。代入は NBAccess の承認対象。

### $SourceVaultWebReputationDNSFilter
型: String | None, 初期値: "Quad9"
フィルタ付き DNS で行き先を確かめるか。"Quad9" (9.9.9.9) / "Cloudflare" (1.1.1.2) / None。使うと初めてのホスト名がその事業者に出る (リストで決まらず、良好でもなく、名前に符号化らしい部分が無いホストのみ)。遮断されたホストは Malicious。事業者に届かない回線では使われず (10 分ごとに確かめ直し)、SystemDoctor に知らせが出る。代入は NBAccess の承認対象。

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