(* ::Package:: *)

(* ============================================================
   SourceVault_webguard.wl -- LLM Web egress guard (関所) / ホスト identity / アクセスログ

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_webguard.wl"]]

   仕様書: ドキュメント/sourcevault_web_egress_guard_spec_v0_1.md

   位置づけ:
     ローカル LLM (LM Studio / llama.cpp) の Web アクセスは SourceVault の
     sourcevault_web_search / sourcevault_get_document (SearXNG 中継・URL 取得) に
     限られているが、URL やクエリ文字列へデータを符号化すれば外へ出せる (出力面の盲点)。
     本モジュールは webingest の SourceVaultWebSearch / SourceVaultWebFetch の入口で
       1. URL / クエリの不審度 (決定的・LLM 不使用)
       2. その LLM 呼び出しに渡っているデータの PrivacyLevel (文脈 PL、claudecode が申告)
       3. ホスト (ドメイン) の identity と AccessLevel (使用実績から推定・オーナー決定で更新)
     を照合して Allow / Ask / Deny を決め、Ask はオーナーに問い合わせる
     (FE があれば ChoiceDialog、service kernel なら承認 queue)。すべてを id 付きで記録する。

   service-loadable 制約 (spec v6 §3.4):
     core 以外に依存しない。identity / privacy / diagnostics / claudecode は弱結合
     (Names / DownValues で存在確認してから呼ぶ)。FE 依存はダイアログのみで $Notebooks で分岐。

   fail-closed:
     guard が未ロードのとき webingest 側 (iWebGuardGate) が LLM 主体を Deny する。
     文脈 PL が不明なら $SourceVaultWebGuardUnknownContextPL (0.5) = 私的データあり側に倒す。
   ============================================================ *)

BeginPackage["SourceVault`"]

$SourceVaultWebGuardVersion::usage =
  "$SourceVaultWebGuardVersion は SourceVault_webguard.wl の版 (\"0.1\")。";

(* ---- 解析 (純関数) ---- *)
SourceVaultWebGuardAnalyzeURL::usage =
  "SourceVaultWebGuardAnalyzeURL[url] は URL の形から不審度を決定的に計算する (LLM 不使用)。\n" <>
  "戻り値 <|Url, Host, Scheme, Port, Suspicion (0..1), Class -> \"Plain\"|\"Opaque\"|\"Exfil\",\n" <>
  "Reasons -> {理由...}, OpaqueTokens, OpaqueChars, Flags, Length|>。\n" <>
  "opaque トークン = 16 字以上の英数塊で hex 32 字以上 / 高エントロピー英数混在 / 大小文字+数字 24 字以上 等。\n" <>
  "YouTube の 11 字 id は Plain、Google Docs の 44 字 id は Opaque、長い符号化塊は Exfil になる。";

SourceVaultWebGuardAnalyzeQuery::usage =
  "SourceVaultWebGuardAnalyzeQuery[query] は検索クエリの形から不審度を計算する。\n" <>
  "戻り値 <|Query, Suspicion, Class, Reasons, OpaqueTokens, PIIHints -> {\"EmailAddress\"|\"LongDigitRun\"|\"SecretKeyword\"...}, Length|>。\n" <>
  "PIIHints はスコアに足さず、文脈 PL が高いときに Ask の根拠になる。";

SourceVaultWebGuardDecide::usage =
  "SourceVaultWebGuardDecide[<|\"Kind\" -> \"Fetch\"|\"Search\", \"ContextPL\" -> pl, \"Analysis\" -> 解析, \"Profile\" -> ホスト view|>]\n" <>
  "は判定表 (spec §8) を純関数で評価し <|Decision -> \"Allow\"|\"Ask\"|\"Deny\", Reason, Reasons, Level|> を返す。";

(* ---- 関所本体 ---- *)
SourceVaultWebGuardCheck::usage =
  "SourceVaultWebGuardCheck[request] は Web アクセス 1 件の関所。request:\n" <>
  "  <|\"Kind\" -> \"Fetch\"|\"Search\", \"Url\" -> _, \"Query\" -> _, \"Actor\" -> <|\"Type\" -> \"HumanUser\"|\"MCPClient\", ...|> (自己申告。所有者かどうかは $SourceVaultPrincipal で決まる、I-01),\n" <>
  "    \"Channel\" -> \"MCP\"|\"Notebook\"|.., \"ContextPL\" -> (任意・明示), \"Provider\"/\"Model\" (任意)|>\n" <>
  "文脈 PL の解決 → 不審度 → ホスト profile → 判定表 → Ask なら ticket / prompter → ログ。\n" <>
  "戻り値 <|Decision -> \"Allow\"|\"Deny\"|\"Pending\", Reason, Reasons, DecisionBy, DecisionDetail, RequestId, Message (モデル向け英文),\n" <>
  "Host, ContextPL, Actor, Analysis, Profile, LogEventId|>。webingest の SourceVaultWebSearch / SourceVaultWebFetch から呼ばれる。";

SourceVaultWebGuardNoteURLs::usage =
  "SourceVaultWebGuardNoteURLs[urls, source, <|\"Query\" -> q|>] は、モデルが組み立てたのではない URL (検索結果に出た URL など) を\n" <>
  "このカーネルで一定時間 ($SourceVaultWebGuardProvenanceTTLSeconds) 覚える (W0、文書 11 §5.0)。覚えた URL をそのまま取得するときは、\n" <>
  "符号化された部分があっても関所は通す (Reason \"From\" <> source)。q を渡すと、q の語 (8 文字以上) を含む URL は覚えない\n" <>
  "(検索語がそのまま URL に映った結果を出所ありとしない)。SourceVaultWebSearch が検索のたびに呼ぶ。\n" <>
  "V11: opts の \"PrivateTerms\" -> True は、機密の語を含む検索の結果であることを覚える (その URL の取得は止めず、記録に\n" <>
  "FoundWithPrivateTerms を付けて月次の集計で数える)。戻り値 <|Noted, SkippedEchoesQuery, Size|>。";
SourceVaultWebGuardURLProvenance::usage =
  "SourceVaultWebGuardURLProvenance[url] は url (断片 #... を除き、スキームとホストは小文字にして照合) の出所 (\"SearchResult\" など) を返す。\n" <>
  "覚えていない・有効時間切れなら None。SourceVaultWebGuardURLProvenance[] は覚えている件数と出所ごとの内訳。";
$SourceVaultWebGuardProvenanceTTLSeconds::usage =
  "$SourceVaultWebGuardProvenanceTTLSeconds (既定 7200) は SourceVaultWebGuardNoteURLs で覚えた URL の有効時間 (秒)。";
$SourceVaultWebGuardProvenanceMaxURLs::usage =
  "$SourceVaultWebGuardProvenanceMaxURLs (既定 5000) は覚えておく URL の上限 (超えたら古いものから忘れる)。";
SourceVaultWebGuardDeclareContext::usage =
  "SourceVaultWebGuardDeclareContext[<|\"Provider\" -> p, \"Model\" -> m, \"PrivacyLevel\" -> pl, \"URL\" -> _, \"SessionId\" -> _|>]\n" <>
  "は LLM 呼び出し直前に claudecode が呼ぶ文脈申告。メモリと LocalState/webguard/context/<provider>.json の両方に置き\n" <>
  "(service kernel は file を読む)、TTL ($SourceVaultWebGuardContextTTLSeconds) 内の最大 PL が文脈 PL になる。";

SourceVaultWebGuardContext::usage =
  "SourceVaultWebGuardContext[] は現在の実効文脈 PL を返す。\n" <>
  "<|PrivacyLevel, Source -> \"Declared\"|\"Evaluation\"|\"Unknown\", Declarations -> {申告...}, Freshest -> 最新申告|>。";

SourceVaultWebGuardStatus::usage =
  "SourceVaultWebGuardStatus[] は関所の状態 (有効/方針/文脈/未決件数/保存先/連携モジュールの有無) を返す。";

(* ---- ホスト identity / AccessLevel ---- *)
SourceVaultWebHostProfile::usage =
  "SourceVaultWebHostProfile[host] はホスト (ドメイン) の実効 profile view を返す。\n" <>
  "<|Host, IdentifierId, AccessLevel (保存値), EffectiveLevel (推定との Max), TrustStatus -> \"Observed\"|\"Approved\"|\"Blocked\",\n" <>
  "PolicySource -> \"Default\"|\"Builtin\"|\"Estimated\"|\"Owner\", Confidence, AccessCount (全機), LocalAccessCount, DistinctDays,\n" <>
  "Suspicious, Denied, Approved, Established, Estimate, FirstSeen, LastSeen, Builtin, ByActor|>。";

SourceVaultWebHostProfiles::usage =
  "SourceVaultWebHostProfiles[] は既知ホスト (profile または実績あり) 全件の view リストを返す (core 版)。";

SourceVaultWebHostProfilesView::usage =
  "SourceVaultWebHostProfilesView[] は SourceVaultWebHostProfiles の Dataset 表示版。";

SourceVaultWebHostSetAccess::usage =
  "SourceVaultWebHostSetAccess[host, level, opts] はホストの AccessLevel をオーナーが明示設定する\n" <>
  "(既定 TrustStatus -> \"Approved\", PolicySource -> \"Owner\")。推定はこの値を上下させない。opts \"Note\"/\"Persist\"。\n" <>
  "\"ListOverride\" -> True を付けると、評判のリスト (ホスト単位) に載っていても、このホストは止めない (所有者が誤検出と判断したとき。V7)。\n" <>
  "URL そのものがリストに載っているページは止める。False で外す。許可をやめる・遮断すると自動で外れる。";

SourceVaultWebHostBlock::usage =
  "SourceVaultWebHostBlock[host] はホストを遮断する (TrustStatus Blocked。文脈 PL に関係なく Deny)。";

SourceVaultWebHostEstimateAccess::usage =
  "SourceVaultWebHostEstimateAccess[host] は使用実績からの AccessLevel 推定 <|Host, Level, Basis -> \"Default\"|\"Builtin\"|\"Established\", Confidence|>。\n" <>
  "Established = 累計 >= EstablishedCount (20)・DistinctDays >= 3・不審 0・拒否 0 → PrivatePL (0.5)。自動では 0.5 までしか上げない。";

SourceVaultWebHostRecomputeProfiles::usage =
  "SourceVaultWebHostRecomputeProfiles[opts] はローカル実績を profile の StatsByMachine[<自機>] に写し、\n" <>
  "Owner 設定でないホストの AccessLevel を推定で更新して PrivateVault/identity/webhosts.jsonl に保存する\n" <>
  "(identity がロード済みなら識別子登録と保存も行う)。月次レビュー (SourceVaultWebAccessMarkReviewed) から呼ばれる。opts \"Persist\"(True)。";

SourceVaultWebHostStorePath::usage =
  "SourceVaultWebHostStorePath[] は webhosts.jsonl のパス ($SourceVaultWebHostRoot で上書き可)。";

(* ---- 承認 queue ---- *)
SourceVaultWebGuardPendingRequests::usage =
  "SourceVaultWebGuardPendingRequests[] は未決 (TTL 内・未決定) の許可待ち request のリストを返す。";

SourceVaultWebGuardResolveRequest::usage =
  "SourceVaultWebGuardResolveRequest[requestId, decision] はオーナーの決定を記録する。\n" <>
  "decision: \"AllowOnce\" | \"AllowHost\" | \"Deny\" | \"BlockHost\"。AllowHost/BlockHost は profile に反映、\n" <>
  "AllowOnce/Deny は同じ (種別, 対象, 主体) の次の呼び出しで 1 回だけ消費される ticket になる。opts \"Level\"/\"Note\"。";

SourceVaultWebGuardProcessPending::usage =
  "SourceVaultWebGuardProcessPending[] は未決 request を 1 件ずつ prompter (FE ならダイアログ) に出して決定する。\n" <>
  "FE では共有 polling tick (SourceVaultWebGuardStartPendingWatch) から自動で呼ばれる。";

SourceVaultWebGuardStartPendingWatch::usage =
  "SourceVaultWebGuardStartPendingWatch[] は claudecode の共有 polling tick に未決 request の監視を登録する (10 秒間隔)。\n" <>
  "FE カーネルではロード時に自動登録 (opt-out: Global`$SourceVaultWebGuardDisableAutoWatch = True)。";

SourceVaultWebGuardStopPendingWatch::usage =
  "SourceVaultWebGuardStopPendingWatch[] は監視登録を解除する。";

(* ---- ログ / 集計 / View ---- *)
SourceVaultWebAccessLog::usage =
  "SourceVaultWebAccessLog[opts] は LLM Web アクセスログ (LocalState/hotlog/web_access) を新しい順の Association リストで返す (core 版)。\n" <>
  "opts: \"Days\"(30) / \"Since\" / \"Until\" (DateObject・ISO 文字列・AbsoluteTime) / \"Actor\" (ActorId または表示名部分一致) /\n" <>
  "\"Host\" (完全一致またはサフィックス) / \"Kind\" (\"Search\"|\"Fetch\") / \"Decision\" / \"MinSuspicion\" / \"Limit\" / \"IncludeOwnerDecisions\"(True)。";

SourceVaultWebAccessLogView::usage =
  "SourceVaultWebAccessLogView[opts] は SourceVaultWebAccessLog の Dataset 表示版 ($SourceVaultWebAccessViewMaxRows 行まで描画)。\n" <>
  "行の文脈 PL 最大が 0.5 以上なら SourceVaultPrivateView で赤枠 + PL バッジを付ける。";

SourceVaultWebAccessSummary::usage =
  "SourceVaultWebAccessSummary[opts] は期間集計 <|Days, Since, Until, Total, ByKind, ByDecision, Suspicious, ByActor, ByHost,\n" <>
  "NewHosts, PendingRequests, OwnerDecisions, ReviewStatus, MaxContextPL|> を返す (core 版)。opts は SourceVaultWebAccessLog の期間 opts。\n" <>
  "V11: SearchRoutes (検索の送り先の数: Open / EnginesOnly / WithPrivateTerms / RecordTermRefused / StageRefused、境 SearchTermMaxPL) と\n" <>
  "FoundWithPrivateTerms (機密の語で検索して見つけたページの取得: Fetched / UnknownReputation / Hosts) も返す。";

SourceVaultWebAccessSummaryView::usage =
  "SourceVaultWebAccessSummaryView[opts] は見出し統計 + ホスト別 / 主体別 Dataset + 「レビュー済みにする」ボタンの表示版。\n" <>
  "SystemDoctor の月次レビュー催促 (WebAccessReview) からはこれを見て SourceVaultWebAccessMarkReviewed[] を呼ぶ。";

SourceVaultWebAccessMarkReviewed::usage =
  "SourceVaultWebAccessMarkReviewed[opts] はサマリーをレビューした事実を PrivateVault/identity/webaccess_review.json に記録し、\n" <>
  "ホスト profile の再計算 (SourceVaultWebHostRecomputeProfiles) も行う。opts \"Note\" / \"Recompute\"(True)。";

SourceVaultWebAccessReviewStatus::usage =
  "SourceVaultWebAccessReviewStatus[] は <|LastReviewedAt, DaysSince, Due, IntervalDays, NextDueAt, LastReview|> を返す。";

SourceVaultWebAccessReviewProbe::usage =
  "SourceVaultWebAccessReviewProbe[opts] は SystemDoctor probe \"WebAccessReview\": 前回レビューから $SourceVaultWebGuardReviewIntervalDays (30) 日超で\n" <>
  "アクセスがあれば Degraded / WebAccessReviewDue、2 分以上放置の許可待ちがあれば Degraded / WebAccessApprovalPending。10 分キャッシュ。";

(* ---- 設定 ---- *)
$SourceVaultWebGuardEnabled::usage = "$SourceVaultWebGuardEnabled (既定 True)。False で関所を素通し (ログは残す)。";
$SourceVaultWebGuardRequired::usage = "$SourceVaultWebGuardRequired (既定 True)。guard 未ロード時に webingest が LLM 主体を Deny するか。";
$SourceVaultWebGuardPolicy::usage =
  "$SourceVaultWebGuardPolicy は判定閾値 <|LowRiskPL 0.2, PrivatePL 0.5, DefaultHostLevel 0.2, EstablishedCount 20, EstablishedDays 3, OpaqueScore 0.4, ExfilScore 0.8,\n" <>
  "PageLinkBits 32, FingerprintTermAction \"Log\"|>。PageLinkBits は段 1 の会話で取得したページのリンクから選んで開ける情報量の合計 (ビット、W2)。\n" <>
  "FingerprintTermAction は機密の指紋のうち日本語の語だけが一致したときの扱い (\"Log\" = 記録だけ、\"Ask\" = 承認、W2)。
" <>
  "HostCheck (既定 True、V2) は、モデルが組み立てた URL の初めてのホストについて、取得や承認の前に実在を DNS で確かめるか。
" <>
  "実在しなければ取得せず、所有者にも尋ねず、モデルに理由と次の手段を返す (Reason \"HostDoesNotExist\")。名前解決そのものが使えないときは止めない。\n" <>
  "FetchDecision (既定 \"Verify\"、V4) / SearchDecision (既定 \"Verify\"、V7) は、取得・検索語を所有者に個別に尋ねるか。\"Verify\" は尋ねずに、\n" <>
  "行き先の評価や検索語の形で決めて、止めるときは理由と次の手段を返す。\"Ask\" は以前の動き (承認の窓)。\n" <>
  "ProposalWindowDays 7 / ProposalMinCount 3 / ProposalMinConversations 2 / ProposalDailyLimit 5 / ProposalExpireDays 14 / ProposalQuietDays 30 は、\n" <>
  "繰り返し止まった対象を方針の提案にする条件 (SourceVaultPolicyProposalsRefresh を参照)。\n" <>
  "V11 (2026-11-14): 外向きの制約は検索語の中身ではなく宛先で分ける。SearchEngines (既定 google・google cse・bing・brave・yahoo・duckduckgo・\n" <>
  "startpage・qwant・mojeek・wikipedia・wikidata・arxiv・crossref) は、公開でない資料を読んだ会話の検索を送ってよい検索エンジン (SearXNG の\n" <>
  "エンジンの名前。有効なものとの共通部分を使う)。段 1 以上の検索と、機密の指紋と一致する検索語は、ここだけに送る (結果の SearchRoute \"EnginesOnly\")。\n" <>
  "その検索では、機密の人名・番号・個人を特定する情報を検索語に含めてよい (迷惑メールの判定で最初に試す語)。予備の経路も、この一覧に対応する\n" <>
  "ものだけを使い、公式サイトのサイト内検索はしない。PrivateStageSearch (既定 \"EnginesOnly\") は段 2 の検索の扱いで、\"Deny\" にすると V10 までの\n" <>
  "動き (段 2 の検索を止める・指紋や個人を特定する情報の一致で止める) に戻る。SearchTermMaxPL (既定 0.9) 以上の資料から取った語 (成績・健康などの記録)\n" <>
  "は、検索エンジンにも送らない (Reason \"PrivateRecordTermInSearch\")。None で制限しない。取得 (検索エンジンでない宛先) の規則は変わらない。";
$SourceVaultWebGuardUnknownContextPL::usage = "$SourceVaultWebGuardUnknownContextPL (既定 0.5) は文脈 PL が分からないときに使う値。";
$SourceVaultWebGuardContextTTLSeconds::usage = "$SourceVaultWebGuardContextTTLSeconds (既定 900) は文脈申告の有効時間 (秒)。";
$SourceVaultWebGuardPendingTTLSeconds::usage = "$SourceVaultWebGuardPendingTTLSeconds (既定 600) は許可待ち request / ticket の有効時間 (秒)。";
$SourceVaultWebGuardPrompter::usage =
  "$SourceVaultWebGuardPrompter: Automatic (FE があれば ChoiceDialog、無ければ queue) | \"Queue\" | \"Deny\" | 関数 f[request] -> \"AllowOnce\"|\"AllowHost\"|\"Deny\"|\"BlockHost\"。";
$SourceVaultWebGuardBuiltinHosts::usage =
  "$SourceVaultWebGuardBuiltinHosts は公知ホスト -> AccessLevel の表 (サフィックス一致)。未見でも 0.5 から始める。";
$SourceVaultWebAccessViewMaxRows::usage = "$SourceVaultWebAccessViewMaxRows (既定 200) は View の描画行数上限。";
$SourceVaultWebHostRoot::usage = "$SourceVaultWebHostRoot を文字列にすると webhosts.jsonl / webaccess_review.json の保存先を上書きする (テスト用)。";
$SourceVaultWebGuardReviewIntervalDays::usage = "$SourceVaultWebGuardReviewIntervalDays (既定 30) は月次レビューの間隔 (日)。";
$SourceVaultWebGuardSession::usage =
  "$SourceVaultWebGuardSession は、ローカル LLM のツールループが Block で設定する会話の状態 <|\"PL\" -> 高水位, \"Channel\" -> _, \"JobId\" -> _|> (W1、文書 11 §5.1)。\n" <>
  "高水位 = その会話でモデルに渡した中身の PL の最大 (ループの開始時の申告と、同じ会話の前の往復の高水位から始まり、下がらない)。\n" <>
  "関所は、会話があるときは文脈 PL を高水位で決める (V1、文書 12 §3.2。ほかの会話の申告は使わない。request の明示の ContextPL とは Max)。\n" <>
  "高水位が PrivatePL (0.5) 以上で $SourceVaultWebGuardPrivateStage が \"Restrict\" なら、外部検索を拒否し、取得は検索結果にそのまま出た URL と\n" <>
  "所有者が許可したホストだけにする (§5.4、承認は出さない)。ループの外では None (従来の判定)。";
$SourceVaultWebGuardPrivateStage::usage =
  "$SourceVaultWebGuardPrivateStage (既定 \"Restrict\") は、機密を読んだ後 (会話の高水位 >= PrivatePL) の外向きの扱い (文書 11 §10 の 2)。\n" <>
  "\"Restrict\" = 外部検索を外し、取得は検索結果にそのまま出た URL と所有者が許可したホストに限る。\"Guard\" = 従来の判定 (文脈 PL は高水位で上がる)。\n" <>
  "\"Guard\" 以外の値は \"Restrict\" と同じ。代入は NBAccess の承認対象。";
SourceVaultWebGuardSessionStage::usage =
  "SourceVaultWebGuardSessionStage[pl] は会話の高水位 pl の段 <|\"Stage\" -> 0|1|2, \"PL\", \"Restrict\", \"LowRiskPL\", \"PrivatePL\"|> を返す (文書 11 §4: 0 は <= LowRiskPL、\n" <>
  "2 は >= PrivatePL)。\"Restrict\" は段 2 で外向きを絞るか ($SourceVaultWebGuardPrivateStage)。\n" <>
  "SourceVaultWebGuardSessionStage[] は $SourceVaultWebGuardSession の PL で同じものを返す (ループの外では Stage None)。";

SourceVaultWebGuardSessionNote::usage =
  "SourceVaultWebGuardSessionNote[kind, text, opts] は、ツールループの会話 ($SourceVaultWebGuardSession) に読んだものを書き込む (W2、文書 11 §5.2・§5.3)。\n" <>
  "kind: \"Request\" = 利用者が入力した依頼文 (語は機密の指紋から除き、URL はそのまま取るなら出所あり。段 2 でも)、\n" <>
  "\"Secret\" = 機密の結果 (人名・番号・ID・メールアドレス・辞書にない英字の語・漢字カタカナの語を、会話ごとの塩つきハッシュで指紋にする。平文は持たない。\n" <>
  "opts \"Classes\" -> \"Strong\" で日本語の語を除く)、\"Public\" = 公開の結果 (語を指紋から除く。opts \"Web\" -> True でカーネル全体の公開の語にも足す)、\n" <>
  "\"Page\" = 取得したページ (\"Public\" と同じ + 本文の URL をページのリンクとして覚える。opts \"Parent\" -> ページの URL)。\n" <>
  "ループの外 (会話が無い) では何もしない。戻り値 <|Noted, Kind, Added|>。";
SourceVaultWebGuardSessionNoteToolResult::usage =
  "SourceVaultWebGuardSessionNoteToolResult[toolName, args, text, observedPL] は、ツールループの 1 回の結果 text を会話に書き込む (W2)。\n" <>
  "observedPL が LowRiskPL (0.2) より上なら \"Secret\"、sourcevault_get_document の URL 取得なら \"Page\"、sourcevault_web_search なら公開 (\"Web\")、それ以外は \"Public\"。";
SourceVaultWebGuardSessionSummary::usage =
  "SourceVaultWebGuardSessionSummary[] は会話の状態の要約 <|PL, Stage, FingerprintKeys, FingerprintByClass, AllowedChars, Links (出所ごとの数), LinkBitsUsed, LinkBitsBudget, PublicCorpusChars|> を返す。\n" <>
  "指紋の中身 (語) は返さない。ループの外では <|Session -> None|>。";

(* ---- V1 (文書 12 §3.2、2026-11-12): 会話をまたぐ高水位。範囲は 1 つの会話 (履歴)、解除は履歴の消去か所有者の操作 ---- *)
SourceVaultWebGuardConversation::usage =
  "SourceVaultWebGuardConversation[id] は、会話 id (claudecode が履歴のヘッダーに置く ID) について関所が覚えている高水位を返す:\n" <>
  "<|\"PL\", \"Known\", \"Stage\", \"RaisedBy\", \"UpdatedAtUTC\"|>。覚えが無ければ PL 0・Known False。\n" <>
  "ツールループは、同じ会話の次の往復の高水位の初期値にこれを使う (前の往復で読んだ機密は、履歴としてプロンプトに入るため)。\n" <>
  "別の会話 (別のノートブック、履歴を消した後) には引き継がない。覚える場所は LocalState/webguard/conversations (ファイル名は id のハッシュ、中身は PL と時刻だけ)。";
SourceVaultWebGuardConversationNote::usage =
  "SourceVaultWebGuardConversationNote[id, pl, raisedBy] は、会話 id の高水位を Max[今の値, pl] にする (上げるだけ)。\n" <>
  "戻り値 <|\"PL\", \"Raised\", \"Known\"|>。ツールループが、開始時と高水位が上がるたびに呼ぶ。";
SourceVaultWebGuardConversationReset::usage =
  "SourceVaultWebGuardConversationReset[id] は、会話 id の高水位の覚えを消す (所有者専用。主体が OwnerFE / OwnerCode でなければ Failure[\"WebGuardNotAuthorized\"])。\n" <>
  "履歴に機密が残っていないと所有者が判断したときに使う。消した記録は LocalState/webguard/conversation-resets.jsonl に残る。NBAccess の承認 head。\n" <>
  "ふつうは使わなくてよい: 履歴を消せば会話の ID が新しくなり、高水位は 0 から始まる。";
SourceVaultWebGuardNamedHosts::usage =
  "SourceVaultWebGuardNamedHosts[text] は、文章が名指ししているウェブのホスト名を、書かれた順に返す (小文字、最大 8 個)。\n" <>
  "拾うのは、http(s) の URL のホストと、スキーム無しで書かれたドメイン名 (www. で始まるもの、または .com .org .jp などで終わるもの)。\n" <>
  "メールアドレスの @ の後ろ、ファイル名 (foo.wl など)、コードの属性参照 (logger.info など) は拾わない。通信はしない。\n" <>
  "関所は依頼文のホストの覚え (実在しないときの断り文) に、ツールループは裏付けの検査 (依頼文のホストを開いたか) に使う。";
SourceVaultWebReputation::usage =
  "SourceVaultWebReputation[hostOrUrl] は行き先の評価 <|Host, Rating, Listed, URLListed, Trust, DNSFilter, Lookalike, Verifier, VerifierReason|> を返す (文書 12 §3.3 の L3)。\n" <>
  "Rating: \"Malicious\" (URL がリストにある・ホストが 2 つ以上のリストにある・フィルタ付きの DNS が遮断) / \"Suspicious\" (ホストが 1 つのリストにある) /\n" <>
  "\"Good\" (所有者が許可・公知ホスト表・実績が十分・上位サイト表) / \"Neutral\"。Lookalike は、既知のホストと 1 文字違いのときその相手。\n" <>
  "照合は手元のリストだけで行い、通信はしない (フィルタ付きの DNS を選んでいて、所有者が呼んだときを除く)。関所は取得のたびにこれと同じ評価を使う。";
SourceVaultWebReputationStatus::usage =
  "SourceVaultWebReputationStatus[] は評判のリストの状態 <|Verifier, Reason, DNSFilter, Sources, Directory|> を返す。\n" <>
  "Verifier は \"OK\" (止める側のリストが 1 つ以上、期限内で入っている。またはフィルタ付きの DNS を使っている) か \"Unavailable\"。\n" <>
  "Unavailable の間も、公開の会話 (段 0) の取得は止めない。公開でない資料を読んだ会話 (段 1) では、実績の無いホストへの取得を止める。";
SourceVaultWebReputationUpdate::usage =
  "SourceVaultWebReputationUpdate[] は評判のリストを取り直す (所有者か service 専用。それ以外は Failure[\"WebGuardNotAuthorized\"]。NBAccess の承認 head)。\n" <>
  "既定では、期限の半分を過ぎたものと未取得のものだけを取る。取りに行く先は $SourceVaultWebReputationSources の固定の URL で、こちらからは何も送らない。\n" <>
  "オプション: \"Sources\" -> {名前…}、\"Force\" -> True (新しくても取り直す)、\"MaxSources\" -> n (1 回に取り直す数)。\n" <>
  "戻り値 <|Updated, Skipped, Failed, Status|>。中身が少なすぎる応答は採らず、前のリストを残す。service の定期処理が自動で呼ぶ。\n" <>
  "FE から: SourceVaultIntegrityOwnerAction[SourceVaultWebReputationUpdate[]]。";
$SourceVaultWebReputationSources::usage =
  "$SourceVaultWebReputationSources は評判のリストの取得元 (名前 -> <|Kind (\"Block\"/\"Trust\"), Format, URL, Enabled, MaxAgeHours, …|>)。\n" <>
  "既定は OpenPhish の公開フィード・JPCERT/CC の phishurl-list (止める側)、Tranco の上位サイト表 (正の手がかり)。どれも手元で照合する。\n" <>
  "使わないものは \"Enabled\" -> False にする。代入は NBAccess の承認の対象。";
$SourceVaultWebReputationDNSFilter::usage =
  "$SourceVaultWebReputationDNSFilter (既定 \"Quad9\"。2026-11-13 の所有者の決定) \[LongDash] フィルタ付きの DNS で行き先を確かめるか。\n" <>
  "\"Quad9\" (9.9.9.9) か \"Cloudflare\" (1.1.1.2)。None で使わない。\n" <>
  "使うと、初めてのホストの名前がその事業者に出る (リストで決まらず、良好でもなく、名前に符号化らしい部分が無いホストだけ。\n" <>
  "機密を読んだ会話でモデルが組み立てた URL は、その前に止まるので出ない)。遮断されたホストは Malicious として扱う。\n" <>
  "事業者に届かない回線では使われず (10 分ごとに確かめ直す)、SystemDoctor に知らせが出る。代入は NBAccess の承認の対象。";

(* ---- V7 (文書 12 の 7.2 節、2026-11-13): 方針の提案 ---- *)
SourceVaultPolicyProposals::usage =
  "SourceVaultPolicyProposals[opts] は方針の提案のリストを返す (core 版)。関所が繰り返し止めた対象 (ホスト・検索語) について、\n" <>
  "所有者に「許可するか・このままか・遮断するか」を尋ねる 1 件ずつの記録。重要な順。opts: \"Status\" -> \"Open\" (既定。いま所有者に出しているもの) |\n" <>
  "\"Deferred\" (1 日の上限を超えて後日に回したもの) | \"Resolved\" | \"Withdrawn\" | All、\"Refresh\" -> Automatic (10 分より古ければ集計し直す)。\n" <>
  "各件 <|ProposalId, TargetKind (\"Host\"/\"Search\"), Target, Reason, Count, Conversations, FirstAt, LastAt, MaxContextPL, SuggestedLevel,\n" <>
  "Actors, Examples, Material (実在・評判・実績・所有者の設定), Options, Status, PresentedAtUTC, ExpiresAtUTC, Decision, …|>。\n" <>
  "URL や検索語の抜粋を含む (privacy の区分は Private)。表示は SourceVaultPolicyProposalsView[]。";
SourceVaultPolicyProposalsRefresh::usage =
  "SourceVaultPolicyProposalsRefresh[] は関所の記録を集計して、方針の提案を作り直す。$SourceVaultWebGuardPolicy の ProposalWindowDays (7) 日の間に、\n" <>
  "同じ対象が ProposalMinCount (3) 回以上、または ProposalMinConversations (2) つ以上の会話で止まっていれば提案を 1 件作る。\n" <>
  "所有者に出すのは 1 日 ProposalDailyLimit (5) 件までで、超えた分は後日に回す。答えの無い提案は ProposalExpireDays (14) 日で取り下げる\n" <>
  "(現状のまま。無応答を承認としない)。「このまま」と答えた・取り下げた対象は ProposalQuietDays (30) 日は出さない。通信はしない。\n" <>
  "戻り値 <|Created, Updated, Reopened, Withdrawn, Presented, Open, Deferred, PresentedToday, DailyLimit|>。service の定期処理と probe が呼ぶ。";
SourceVaultPolicyProposalResolve::usage =
  "SourceVaultPolicyProposalResolve[proposalId, choice, opts] は方針の提案に所有者が答える (所有者専用。主体が OwnerFE / OwnerCode でなければ\n" <>
  "Failure[\"WebGuardNotAuthorized\"]。NBAccess の承認 head)。FE からは SourceVaultIntegrityOwnerAction[SourceVaultPolicyProposalResolve[id, choice]]。\n" <>
  "choice は提案の Options のどれか: \"Keep\" (このまま) / \"AllowHost\" (ホストを許可) / \"AllowDespiteList\" (評判のリストに載っていることを承知で許可) /\n" <>
  "\"RaiseLevel\" (許可する機密度を上げる) / \"BlockHost\" (遮断) / \"Unblock\" (遮断を解く)。opts \"Level\" (許可する機密度。既定は提案の SuggestedLevel)、\"Note\"。\n" <>
  "答えは提案の記録と関所の記録 (OwnerDecided) に残る。提示から決定までの秒数と、その日の何件目の決定かも残す。";
SourceVaultPolicyProposalsView::usage =
  "SourceVaultPolicyProposalsView[] は、いま所有者に出している方針の提案の表示版 (FE)。対象・止まった回数と会話の数・判断の材料・選択肢と、\n" <>
  "選んだときに何が変わるかを並べる。選択肢のボタンは、答えの式 (SourceVaultIntegrityOwnerAction[SourceVaultPolicyProposalResolve[…]]) を\n" <>
  "下のセルに置く。評価すると反映される。答えなければ現状のまま。";
SourceVaultPolicyProposalsProbe::usage =
  "SourceVaultPolicyProposalsProbe[] は SystemDoctor probe \"PolicyProposals\": 所有者に出している提案があれば Degraded / PolicyProposalsOpen。\n" <>
  "文面には件数だけを書く (対象の名前は書かない)。10 分キャッシュ。";

(* ---- V8 (文書 12 の 7.3 節、2026-11-13): 所有者の判断の記録と見直し ---- *)
SourceVaultOwnerDecisions::usage =
  "SourceVaultOwnerDecisions[opts] は、関所についての所有者の判断の記録を新しい順に返す (core 版)。ホストの許可・遮断・機密度の変更、\n" <>
  "方針の提案への回答、承認の窓での回答、関所の設定の切り替え (気づいた時点で記録)、再確認。opts: \"Days\" (30) / \"Direction\" (\"Loosen\" | \"Tighten\" | \"Neutral\" | All) /\n" <>
  "\"Target\" / \"Limit\"。各件 <|At, DecisionId, Action, Direction, TargetKind, Target, Via (\"PolicyProposal\" | \"Dialog\" | \"Direct\" | \"Review\" | \"Detected\"),\n" <>
  "Ref, Previous, New, Seconds (提示から決定までの秒数。分からなければ -1), NthThatDay (その日の何件目か), MaterialDigest, Principal, Machine|>。\n" <>
  "置き場は PrivateVault/identity/owner_decisions-<機>.jsonl (追記だけ。機ごとのファイルなので、2 台で書いても衝突しない)。検索語や URL は入れない。";
SourceVaultOwnerDecisionSummary::usage =
  "SourceVaultOwnerDecisionSummary[opts] は所有者の判断の集計 (文書 12 の 7.3 節の「見るもの」) を返す。opts \"Days\" (30)。\n" <>
  "<|Days, Decisions, ByDirection, ByVia, Loosened (期間に緩めたもの。いまも有効かを付ける), WallHeight (許可したホストの数・機密を読んだ会話に許可した数・\n" <>
  "リストを承知で許可した数・遮断した数・緩めている設定)、FastApprovals (速い承認の数と割合)、ConsecutiveLoosening (緩める判断が続いた最大の回数)、\n" <>
  "Inconsistent (許可と遮断が入れ替わった対象)、ReconfirmDue (ReconfirmDays より長く再確認していない緩和)、Posture (関所の設定の今の値)|>。\n" <>
  "指標は見るためのもので、これで何かが止まることは無い。";
SourceVaultOwnerDecisionReconfirm::usage =
  "SourceVaultOwnerDecisionReconfirm[All] / [{host..}] は、緩めた設定 (許可したホスト。All なら緩めている関所の設定も) を「見直して、続ける」と記録する\n" <>
  "(所有者専用。主体が OwnerFE / OwnerCode でなければ Failure[\"WebGuardNotAuthorized\"]。NBAccess の承認 head)。設定そのものは変えない。\n" <>
  "次に「再確認が要るもの」に並ぶのは ReconfirmDays (30) 日後。やめるときは、表示が置く式 (SourceVaultWebHostSetAccess … \"Observed\") を使う。";
SourceVaultOwnerDecisionReviewView::usage =
  "SourceVaultOwnerDecisionReviewView[opts] は所有者の判断の見直しの表示版 (FE)。壁の高さ、指標、この 30 日に緩めたもの、再確認が要るものを並べる。\n" <>
  "操作 (まとめて再確認・許可をやめる) は、式を下のセルに置く。月次のレビュー (SourceVaultWebAccessSummaryView) から開く。opts \"Days\" (30)。";

(* ---- V9 (文書 12 の 4.6 節、2026-11-13): 裏付けの検査の記録と指標 ---- *)
SourceVaultGroundingNote::usage =
  "SourceVaultGroundingNote[rec] は、ツールループの裏付けの検査の結果 1 件を記録する (LocalState/hotlog/grounding/YYYY-MM-p<pid>.jsonl、機ごと)。\n" <>
  "claudecode が回答ごとに呼ぶ。受け取るのは決まった鍵だけ: Status (Grounded | Partial | Ungrounded | BackendUnavailable | WebNotAvailable |\n" <>
  "NotApplicable | NotNeeded)、PartialReason、Rule、件数 (Searches・SearchesWithResults・SearchesRefused・BackendFailures・Fetched・FetchFailed・\n" <>
  "FetchRefused・Internal・FallbackSearches・ClaimsChecked・ClaimsSupported・Cited・CitedVerified)、SentBack、OutputSHA256・FinalSHA256\n" <>
  "(回答の SHA-256。印を付ける前と後)、ConversationId、AtUTC、AtUnixMs、Machine。依頼文・検索語・回答の本文・ホスト名・URL は入らない。\n" <>
  "戻り値 <|\"Noted\" -> True | False, \"Reason\"|>。";
SourceVaultGroundingLog::usage =
  "SourceVaultGroundingLog[opts] は裏付けの検査の記録を新しい順に返す。opts: \"Days\" (30) / \"Status\" (Status の値か、ラベルの値\n" <>
  "\"Grounded\" | \"Partial\" | \"Ungrounded\" | \"NotNeeded\"。\"Ungrounded\" は検索の障害・外部検索が使えない会話も含む) / \"Limit\"。";
SourceVaultGroundingSummary::usage =
  "SourceVaultGroundingSummary[opts] は裏付けの検査の指標を返す (文書 12 の 4.6 節・7.3 節)。opts \"Days\" (30)。\n" <>
  "<|Days, Total, NotNeeded, Needed (外部の事実が要る回答の数 = 分母), ByStatus, Grounded, Partial, Unconfirmed, UngroundedRate (未確認のまま返した割合),\n" <>
  "PartialRate, PartialByReason, SentBack (差し戻した数と、その後 Grounded・未確認で終わった数), Claims (照合した数値・日付・地名の数と、資料にあった数),\n" <>
  "Citations (回答が挙げた URL の数と、検索結果・取得したページにあった数), AfterRefusal (関所が検索か取得を止めた依頼の数と、\n" <>
  "それが未確認・一部・Grounded の回答で終わった数 = 「拒否の後の結果」)|>。見るためのもので、これで何かが止まることは無い。";
SourceVaultGroundingOfText::usage =
  "SourceVaultGroundingOfText[text] は、文章 (LLM の回答) の裏付けの判定を引き当てる: <|\"Grounding\" -> \"Grounded\" | \"Partial\" | \"Ungrounded\" |\n" <>
  "\"NotNeeded\" | \"Unknown\", \"Source\" -> \"Record\" (回答の SHA-256 が裏付けの記録にあった) | \"Mark\" (先頭の [SourceVault] の印から) | None|>。\n" <>
  "自動の取り込み (TurnWiki など) が、外部で未確認の回答を知識に入れないために使う。記録に無く印も無い文章は Unknown (止める理由にはしない)。";

Begin["`WebGuardPrivate`"]

$SourceVaultWebGuardVersion = "0.1";

(* ------------------------------------------------------------
   設定 (再 Get で上書きしない)
   ------------------------------------------------------------ *)
If[! ValueQ[$SourceVaultWebGuardEnabled], $SourceVaultWebGuardEnabled = True];
If[! ValueQ[$SourceVaultWebGuardRequired], $SourceVaultWebGuardRequired = True];
$iWGDefaultPolicy = <|
  "LowRiskPL" -> 0.2, "PrivatePL" -> 0.5, "DefaultHostLevel" -> 0.2,
  "EstablishedCount" -> 20, "EstablishedDays" -> 3,
  "OpaqueScore" -> 0.4, "ExfilScore" -> 0.8,
  (* W2 (文書 11 §5.2・§5.3、2026-11-12): 段 1 でページのリンクから選んで開ける情報量の合計 (ビット) と、
     機密の指紋で日本語の語だけが一致したときの扱い ("Log" = 記録だけ、"Ask" = 承認) *)
  "PageLinkBits" -> 32, "FingerprintTermAction" -> "Log",
  (* V2 (文書 12 §3.3 の L1、2026-11-12): 取得の前にホストの実在を DNS で確かめる。False で確かめない *)
  "HostCheck" -> True,
  (* V4 (文書 12 §3.3 の L3 と判定表、2026-11-13): 取得の判定。"Verify" = 所有者に個別には尋ねず、行き先の評価と会話の段で決める
     (止めるときは理由と次の手段を返す)。"Ask" = 以前の動き (初めてのホスト・符号化らしい URL などを所有者に尋ねる)。
     "Reputation" = 評判のリストに載ったホスト・URL を止めるか (どちらの判定でも効く)。 *)
  "FetchDecision" -> "Verify", "Reputation" -> True,
  (* V7 (文書 12 の 3.3 節・7.2 節、2026-11-13): 検索語の判定。"Verify" = 符号化らしい検索語・機密の指紋と一致する検索語を、
     所有者に個別には尋ねずに止めて、理由と次の手段を返す。"Ask" = 以前の動き (所有者に尋ねる)。
     止めた要求は集計し、同じ対象が繰り返し止まったときにだけ、方針の提案を 1 件作る (SourceVaultPolicyProposals)。
     ProposalWindowDays = 集計する日数、ProposalMinCount = この回数以上、または ProposalMinConversations = この数以上の会話で
     止まったら提案にする、ProposalDailyLimit = 1 日に所有者へ出す提案の上限、ProposalExpireDays = 答えの無い提案を取り下げるまでの日数、
     ProposalQuietDays = 「このまま」と答えた・取り下げた対象を、もう一度提案にしない日数 *)
  "SearchDecision" -> "Verify",
  "ProposalWindowDays" -> 7, "ProposalMinCount" -> 3, "ProposalMinConversations" -> 2, "ProposalDailyLimit" -> 5,
  "ProposalExpireDays" -> 14, "ProposalQuietDays" -> 30,
  (* V8 (文書 12 の 7.3 節、2026-11-13): 所有者の判断の見直し。
     ReconfirmDays = 緩めた設定 (許可したホストなど) を、この日数ごとに「再確認が要るもの」として月次のレビューに並べる。
       期限が来ても、何も取り消さない (所有者の明示の判断を無断で無効にしない。7.4 節)。0 以下か数でない値で、並べない。
     FastDecisionSeconds = 提示からこの秒数より短い時間で緩める判断をしたものを「速い承認」に数える (指標だけ)。
     ConfirmFastSeconds / ConfirmAfterConsecutive = 既定 None (確認を足さない)。数を入れると、方針の提案に「緩める」答えをするとき、
       提示からその秒数より短い・緩める判断がその回数以上続いている、のどちらかで、確認を 1 段足す (止めはしない)。 *)
  "ReconfirmDays" -> 30, "FastDecisionSeconds" -> 5, "ConfirmFastSeconds" -> None, "ConfirmAfterConsecutive" -> None,
  (* V11 (文書 12 の 8.18 節、2026-11-14、所有者の指摘): 外向きの制約は、検索語の中身ではなく宛先で分ける。
     メールの人名・番号・会場名を検索語に入れるのは、まっとうな検索エンジン宛てなら問題ない (迷惑メールの判定では最初に試す語)。
     注意が要るのは、検索エンジンでない宛先へ語を伴って行くこと (モデルが組み立てた URL、サイト内検索、照会サイト)。
     SearchEngines = 公開でない資料を読んだ会話の検索を送ってよい検索エンジン (SearXNG のエンジンの名前。有効なものとの共通部分を使う)。
     PrivateStageSearch = 機密を読んだ会話 (段 2) の検索。"EnginesOnly" = 上の検索エンジンだけに送って通す (既定)。
       "Deny" = V10 までの動き (止める。モデルが組み立てた検索語の、指紋・個人を特定する情報による拒否も戻る)。
     SearchTermMaxPL = この PL 以上の資料から取った語 (所有者が責任を持つ人の成績・健康などの記録) は、検索エンジンにも送らない。
       None で制限しない。 *)
  "SearchEngines" -> {"google", "google cse", "bing", "brave", "yahoo", "duckduckgo", "startpage", "qwant", "mojeek",
    "wikipedia", "wikidata", "arxiv", "crossref"},
  "PrivateStageSearch" -> "EnginesOnly", "SearchTermMaxPL" -> 0.9|>;
If[! AssociationQ[$SourceVaultWebGuardPolicy], $SourceVaultWebGuardPolicy = $iWGDefaultPolicy];
If[! NumericQ[$SourceVaultWebGuardUnknownContextPL], $SourceVaultWebGuardUnknownContextPL = 0.5];
If[! NumericQ[$SourceVaultWebGuardContextTTLSeconds], $SourceVaultWebGuardContextTTLSeconds = 900];
If[! NumericQ[$SourceVaultWebGuardPendingTTLSeconds], $SourceVaultWebGuardPendingTTLSeconds = 600];
If[! NumericQ[$SourceVaultWebGuardProvenanceTTLSeconds], $SourceVaultWebGuardProvenanceTTLSeconds = 7200];
If[! IntegerQ[$SourceVaultWebGuardProvenanceMaxURLs], $SourceVaultWebGuardProvenanceMaxURLs = 5000];
If[! AssociationQ[$iWGProvenance], $iWGProvenance = <||>];
(* W1 (文書 11 §5.1・§5.4、2026-11-12): ツールループの会話の高水位。ループが Block で設定し、外では None *)
If[! ValueQ[$SourceVaultWebGuardSession], $SourceVaultWebGuardSession = None];
If[! StringQ[$SourceVaultWebGuardPrivateStage], $SourceVaultWebGuardPrivateStage = "Restrict"];
(* W2 (2026-11-12): カーネル全体の公開の語 (検索結果・取得したページの本文、NFKC + 小文字)。機密の指紋から除く *)
If[! StringQ[$iWGPublicCorpus], $iWGPublicCorpus = ""];
If[! ValueQ[$SourceVaultWebGuardPrompter], $SourceVaultWebGuardPrompter = Automatic];
(* N10 (02 v1.2 R-03 / 付録 A #40, 2026-11-09): この変数に関数を入れればカーネル内のコードは誰でも
   Ask の結果を作れる。代入 (Module 内でも) は NBAccess の承認対象 ($NBApprovalSetSymbols。NBAccess 側の
   既定表にも同じ 4 名が入っている)。NBAccess が先にロード済みならここでも登録する (弱結合、service では
   NBAccess が無いので no-op)。 *)
If[Length[DownValues[NBAccess`NBRegisterApprovalSetSymbols]] > 0,
  Quiet @ NBAccess`NBRegisterApprovalSetSymbols[{"$SourceVaultWebGuardPrompter",
    "$SourceVaultWebGuardEnabled", "$SourceVaultWebGuardRequired", "$SourceVaultWebGuardPolicy",
    (* W1 (2026-11-12): "Guard" にすると機密を読んだ後の外向きの絞り込みが外れる *)
    "$SourceVaultWebGuardPrivateStage",
    (* W2 (2026-11-12): 会話の状態 (依頼文の URL・ページのリンク・指紋を持つ) と、検索結果の URL の出所・公開の語の置き場 *)
    "$SourceVaultWebGuardSession", "$iWGProvenance", "$iWGPublicCorpus",
    (* V1 (2026-11-12): 会話をまたぐ高水位の覚え (下げると、前の往復で読んだ機密が段 0 の扱いになる) *)
    "$iWGConversations"}]];
(* V1: 会話の高水位を消すのは所有者だけ (提案コードからは承認制) *)
If[Length[DownValues[NBAccess`NBRegisterApprovalHeads]] > 0,
  Quiet @ NBAccess`NBRegisterApprovalHeads[{"SourceVaultWebGuardConversationReset"}]];
If[! IntegerQ[$SourceVaultWebAccessViewMaxRows], $SourceVaultWebAccessViewMaxRows = 200];
If[! NumericQ[$SourceVaultWebGuardReviewIntervalDays], $SourceVaultWebGuardReviewIntervalDays = 30];
If[! AssociationQ[$SourceVaultWebGuardBuiltinHosts],
  $SourceVaultWebGuardBuiltinHosts = <|
    "wikipedia.org" -> 0.5, "wikimedia.org" -> 0.5, "arxiv.org" -> 0.5, "doi.org" -> 0.5,
    "github.com" -> 0.5, "githubusercontent.com" -> 0.5, "youtube.com" -> 0.5, "youtu.be" -> 0.5,
    "google.com" -> 0.5, "scholar.google.com" -> 0.5,
    "python.org" -> 0.5, "reference.wolfram.com" -> 0.5, "wolfram.com" -> 0.5,
    "developer.mozilla.org" -> 0.5, "docs.anthropic.com" -> 0.5, "platform.openai.com" -> 0.5,
    "ai.google.dev" -> 0.5, "nih.gov" -> 0.5, "ieee.org" -> 0.5, "acm.org" -> 0.5,
    "springer.com" -> 0.5, "sciencedirect.com" -> 0.5, "nature.com" -> 0.5,
    "jst.go.jp" -> 0.5, "cinii.ac.jp" -> 0.5, "nii.ac.jp" -> 0.5, "go.jp" -> 0.5, "ac.jp" -> 0.5,
    "stackoverflow.com" -> 0.5, "stackexchange.com" -> 0.5|>];

iWGPol[key_String] := Lookup[$SourceVaultWebGuardPolicy, key, Lookup[$iWGDefaultPolicy, key, 0]];

(* ------------------------------------------------------------
   時刻 / 文字列 / JSON helper
   ------------------------------------------------------------ *)
iWGAbsToIso[abs_?NumericQ] :=
  DateString[TimeZoneConvert[DateObject[abs], 0],
    {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"}];
iWGNowIso[] := iWGAbsToIso[AbsoluteTime[]];

(* "2026-10-14T01:02:03Z" (UTC) -> AbsoluteTime。AbsoluteTime[list, TimeZone->0] は
   TimeZone を無視するので DateObject 経由 (diagnostics と同じ罠回避)。 *)
iWGIsoToAbs[s_String] :=
  Module[{m = StringCases[s,
      RegularExpression["^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})"] :>
        ToExpression[{"$1", "$2", "$3", "$4", "$5", "$6"}], 1]},
    If[m === {}, $Failed,
      Quiet @ Check[AbsoluteTime[DateObject[First[m], TimeZone -> 0]], $Failed]]];
iWGIsoToAbs[_] := $Failed;

iWGLocalTimeString[iso_String] :=
  With[{a = iWGIsoToAbs[iso]},
    If[NumericQ[a], DateString[a, {"Year", "-", "Month", "-", "Day", " ", "Hour", ":", "Minute"}], iso]];
iWGLocalTimeString[x_] := ToString[x];

iWGMachineTag[] :=
  StringReplace[ToString[$MachineName],
    Except[LetterCharacter | DigitCharacter | "-" | "_"] .. -> "-"];

iWGHex[s_String] := Hash[StringToByteArray[s, "UTF-8"], "SHA256", "HexString"];

(* identity 層の iSVIDId と同じ式 (kind <> ":" <> 正規化値 の SHA256 先頭 16 hex)。
   identity 未ロードの service kernel でも同じ id になる。 *)
iWGIdentifierId[kind_String, value_String] :=
  "idf-" <> ToLowerCase[kind] <> "-" <> StringTake[iWGHex[kind <> ":" <> value], 16];

iWGExcerpt[t_String] :=
  If[StringLength[t] > 12, StringTake[t, 12] <> "...(" <> ToString[StringLength[t]] <> ")", t];

iWGJSONSafe[x_] := x /. {d_DateObject :> DateString[d, "ISODateTime"], None -> Null,
  _Missing -> Null, $Failed -> Null, Automatic -> Null};
iWGToJSON[expr_] := Quiet @ Check[
  ByteArrayToString[ExportByteArray[iWGJSONSafe[expr], "RawJSON", "Compact" -> True], "UTF-8"], $Failed];
iWGFromJSON[s_String] := Quiet @ Check[ImportByteArray[StringToByteArray[s, "UTF-8"], "RawJSON"], $Failed];
iWGFixNull[a_Association] := Replace[a, Null -> Missing[], {1}];
iWGFixNull[x_] := x;

iWGEnsureDir[dir_String] :=
  (If[! DirectoryQ[dir], Quiet @ CreateDirectory[dir, CreateIntermediateDirectories -> True]]; dir);

(* atomic JSON write (tmp + rename) *)
iWGWriteJSON[path_String, expr_] := Module[{bytes, tmp, strm},
  bytes = Quiet @ Check[ExportByteArray[iWGJSONSafe[expr], "RawJSON"], $Failed];
  If[! ByteArrayQ[bytes], Return[$Failed]];
  iWGEnsureDir[DirectoryName[path]];
  tmp = path <> ".tmp." <> ToString[$ProcessID] <> "." <> StringTake[CreateUUID[], 6];
  strm = Quiet @ OpenWrite[tmp, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  BinaryWrite[strm, bytes]; Close[strm];
  If[Quiet @ Check[RenameFile[tmp, path, OverwriteTarget -> True], $Failed] === $Failed,
    Quiet @ DeleteFile[tmp]; Return[$Failed]];
  path];
iWGReadJSON[path_String] :=
  If[! FileExistsQ[path], $Failed,
    Quiet @ Check[ImportByteArray[ReadByteArray[path], "RawJSON"], $Failed]];
iWGAppendLine[path_String, line_String] := Module[{strm},
  iWGEnsureDir[DirectoryName[path]];
  strm = Quiet @ OpenAppend[path, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  BinaryWrite[strm, StringToByteArray[line <> "\n", "UTF-8"]]; Close[strm];
  path];
iWGReadJSONL[path_String] :=
  If[! FileExistsQ[path], {},
    Module[{raw = Quiet @ Check[ByteArrayToString[ReadByteArray[path], "UTF-8"], ""]},
      If[! StringQ[raw], Return[{}]];
      Select[iWGFromJSON[StringTrim[#]] & /@ Select[StringSplit[raw, "\n"], StringTrim[#] =!= "" &],
        AssociationQ]]];

(* ------------------------------------------------------------
   保存先 (core の root 解決。未解決なら $Failed = メモリのみで動く)
   ------------------------------------------------------------ *)
iWGLocalStateDir[] :=
  With[{ls = Quiet @ Check[SourceVault`SourceVaultRoot["LocalState"], $Failed]},
    If[StringQ[ls] && ls =!= "", ls, $Failed]];
iWGPrivateVaultDir[] :=
  With[{pv = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[pv] && pv =!= "", pv, $Failed]];
iWGIdentityDir[] := Which[
  StringQ[$SourceVaultWebHostRoot], $SourceVaultWebHostRoot,
  StringQ[iWGPrivateVaultDir[]], FileNameJoin[{iWGPrivateVaultDir[], "identity"}],
  True, $Failed];
iWGSub[dir_String, parts__String] := FileNameJoin[{dir, parts}];
iWGSub[_, ___] := $Failed;

SourceVaultWebHostStorePath[] := iWGSub[iWGIdentityDir[], "webhosts.jsonl"];
iWGReviewPath[] := iWGSub[iWGIdentityDir[], "webaccess_review.json"];
iWGContextDir[] := iWGSub[iWGLocalStateDir[], "webguard", "context"];
iWGPendingDir[] := iWGSub[iWGLocalStateDir[], "webguard", "pending"];
iWGDecisionsDir[] := iWGSub[iWGLocalStateDir[], "webguard", "decisions"];
iWGLogDir[] := iWGSub[iWGLocalStateDir[], "hotlog", "web_access"];

(* ------------------------------------------------------------
   URL / クエリ解析 (spec §6)
   ------------------------------------------------------------ *)
iWGNormHost[h_String] := Module[{s = ToLowerCase[StringTrim[h]]},
  s = StringTrim[s, "."];
  If[StringStartsQ[s, "www."] && StringCount[s, "."] >= 2, s = StringDrop[s, 4]];
  s];
iWGNormHost[_] := "";

iWGPrivateHostQ[host_String] := Or[
  MemberQ[{"localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"}, host],
  StringMatchQ[host, "127." ~~ __], StringMatchQ[host, "10." ~~ __],
  StringMatchQ[host, "192.168." ~~ __],
  StringMatchQ[host, RegularExpression["^172\\.(1[6-9]|2[0-9]|3[01])\\..*"]],
  StringMatchQ[host, RegularExpression["^169\\.254\\..*"]],
  StringEndsQ[host, ".local"] || StringEndsQ[host, ".lan"] ||
    StringEndsQ[host, ".internal"] || StringEndsQ[host, ".home"],
  host =!= "" && ! StringContainsQ[host, "."]];
iWGPrivateHostQ[_] := False;

iWGEntropy[s_String] := Module[{c = Characters[s], p},
  If[c === {}, Return[0.]];
  p = N[Values[Counts[c]]/Length[c]];
  -Total[p Log2[p]]];

$iWGTokenPattern = RegularExpression["[A-Za-z0-9+/=_\\-]{16,}"];
iWGUUIDQ[t_String] := StringMatchQ[t,
  RegularExpression["^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"]];

(* 16 字以上の英数塊が「符号化データ」の形か。自然語の slug (数字無し・単一ケース) は Plain に残す。 *)
iWGTokenClass[t_String] := Module[{len = StringLength[t], hex, hasD, hasL, mixed, ent},
  If[iWGUUIDQ[t], Return["UUID"]];
  hex = StringMatchQ[t, RegularExpression["^[0-9a-fA-F]+$"]];
  hasD = StringContainsQ[t, DigitCharacter];
  hasL = StringContainsQ[t, LetterCharacter];
  mixed = StringContainsQ[t, RegularExpression["[a-z]"]] && StringContainsQ[t, RegularExpression["[A-Z]"]];
  ent = iWGEntropy[t];
  Which[
    hex && len >= 32, "Opaque",
    len >= 20 && hasD && hasL && ent >= 3.5, "Opaque",
    len >= 24 && mixed && hasD, "Opaque",
    len >= 48 && ent >= 4.0, "Opaque",
    True, "Plain"]];

iWGClass[score_?NumericQ] := Which[
  score >= iWGPol["ExfilScore"], "Exfil",
  score >= iWGPol["OpaqueScore"], "Opaque",
  True, "Plain"];

SourceVaultWebGuardAnalyzeURL[url_String] := Module[
  {p, scheme, hostRaw, host, user, port, path, query, frag, labels, segs, qvals, tokens,
   opaque, uuids, totalOpaque, pct, score = 0., reasons = {}, flags = {}, len = StringLength[url]},
  p = Quiet @ Check[URLParse[url], $Failed];
  If[! AssociationQ[p],
    Return[<|"Url" -> url, "Host" -> "", "Scheme" -> "", "Port" -> None, "Suspicion" -> 1.0,
      "Class" -> "Exfil", "Reasons" -> {"UnparsableURL"}, "OpaqueTokens" -> {}, "OpaqueChars" -> 0,
      "Flags" -> {"Unparsable"}, "Length" -> len|>]];
  scheme = ToLowerCase[ToString[Lookup[p, "Scheme", ""] /. None -> ""]];
  hostRaw = ToString[Lookup[p, "Domain", ""] /. None -> ""];
  host = iWGNormHost[hostRaw];
  user = Lookup[p, "User", None]; port = Lookup[p, "Port", None];
  path = Lookup[p, "Path", {}]; If[! ListQ[path], path = {ToString[path]}];
  query = Lookup[p, "Query", {}]; If[! ListQ[query], query = {}];
  frag = Lookup[p, "Fragment", None];
  If[! MemberQ[{"http", "https"}, scheme], score += 1.0; AppendTo[reasons, "NonHTTPScheme:" <> scheme]];
  If[StringQ[user] && user =!= "", score += 0.5; AppendTo[reasons, "UserInfoInURL"]; AppendTo[flags, "UserInfo"]];
  If[host === "", score += 0.5; AppendTo[reasons, "EmptyHost"]];
  If[host =!= "" && (StringMatchQ[host, RegularExpression["^\\d{1,3}(\\.\\d{1,3}){3}$"]] || StringContainsQ[host, ":"]),
    score += 0.3; AppendTo[reasons, "IPLiteralHost"]; AppendTo[flags, "IPLiteral"]];
  If[IntegerQ[port] && ! MemberQ[{80, 443}, port], score += 0.2; AppendTo[reasons, "NonStandardPort:" <> ToString[port]]];
  labels = Select[StringSplit[host, "."], # =!= "" &];
  If[AnyTrue[labels, StringStartsQ[#, "xn--"] &], score += 0.2; AppendTo[reasons, "Punycode"]];
  If[Length[labels] > 5, score += 0.2; AppendTo[reasons, "ManyHostLabels:" <> ToString[Length[labels]]]];
  Scan[Function[l,
    If[StringLength[l] >= 16 &&
       ((StringContainsQ[l, DigitCharacter] && StringContainsQ[l, LetterCharacter]) || iWGEntropy[l] >= 3.5),
      score += 0.5; AppendTo[reasons, "OpaqueHostLabel:" <> iWGExcerpt[l]]]], labels];
  If[iWGPrivateHostQ[host], AppendTo[flags, "PrivateHost"]];
  segs = Select[ToString /@ path, # =!= "" &];
  qvals = Flatten[Cases[query, (k_ -> v_) :> {ToString[k], ToString[v /. None -> ""]}]];
  tokens = Flatten[StringCases[#, $iWGTokenPattern] & /@ Join[segs, qvals, If[StringQ[frag], {frag}, {}]]];
  opaque = Select[tokens, iWGTokenClass[#] === "Opaque" &];
  uuids = Select[tokens, iWGTokenClass[#] === "UUID" &];
  If[uuids =!= {}, score += 0.15; AppendTo[reasons, "UUIDToken"]];
  If[opaque =!= {},
    score += 0.4;
    reasons = Join[reasons, ("OpaqueToken:" <> iWGExcerpt[#]) & /@ Take[opaque, UpTo[3]]]];
  totalOpaque = Total[StringLength /@ opaque];
  If[totalOpaque >= 128, score += 0.4; AppendTo[reasons, "OpaquePayload:" <> ToString[totalOpaque] <> "chars"]];
  If[len > 1500, score += 0.4; AppendTo[reasons, "LongURL:" <> ToString[len]]];
  If[Length[query] > 10, score += 0.2; AppendTo[reasons, "ManyQueryParams:" <> ToString[Length[query]]]];
  pct = StringCases[url, RegularExpression["[A-Za-z0-9%+/=_.\\-]{40,}"]];
  If[AnyTrue[pct, (3 StringCount[#, "%"])/StringLength[#] >= 0.2 &],
    score += 0.3; AppendTo[reasons, "PercentEncodedBlob"]];
  score = Min[1., score];
  <|"Url" -> url, "Host" -> host, "Scheme" -> scheme, "Port" -> port,
    "Suspicion" -> score, "Class" -> iWGClass[score], "Reasons" -> reasons,
    "OpaqueTokens" -> (iWGExcerpt /@ opaque), "OpaqueChars" -> totalOpaque,
    "Flags" -> flags, "Length" -> len|>];
SourceVaultWebGuardAnalyzeURL[x_] := SourceVaultWebGuardAnalyzeURL[ToString[x]];

(* 8 桁以上の数字列 (学籍番号・電話)。YYYYMMDD 形の 8 桁 (19xx/20xx 始まり) は日付とみて除く。 *)
iWGLongDigitRunQ[q_String] := AnyTrue[StringCases[q, RegularExpression["\\d{8,}"]],
  Function[d, ! (StringLength[d] == 8 && StringMatchQ[d, RegularExpression["^(19|20)\\d{6}$"]])]];

SourceVaultWebGuardAnalyzeQuery[q_String] := Module[
  {tokens, opaque, score = 0., reasons = {}, pii = {}, lines, totalOpaque},
  tokens = StringCases[q, $iWGTokenPattern];
  opaque = Select[tokens, iWGTokenClass[#] === "Opaque" &];
  If[opaque =!= {},
    score += 0.5 Length[opaque];
    reasons = Join[reasons, ("OpaqueToken:" <> iWGExcerpt[#]) & /@ Take[opaque, UpTo[3]]]];
  totalOpaque = Total[StringLength /@ opaque];
  If[totalOpaque >= 128, score += 0.3; AppendTo[reasons, "OpaquePayload:" <> ToString[totalOpaque] <> "chars"]];
  If[StringLength[q] > 300, score += 0.3; AppendTo[reasons, "LongQuery:" <> ToString[StringLength[q]]]];
  lines = Length[Select[StringSplit[q, "\n"], StringTrim[#] =!= "" &]];
  If[lines >= 3, score += 0.2; AppendTo[reasons, "MultiLineQuery:" <> ToString[lines]]];
  If[StringContainsQ[q, RegularExpression["[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}"]],
    AppendTo[pii, "EmailAddress"]];
  If[iWGLongDigitRunQ[q], AppendTo[pii, "LongDigitRun"]];
  If[StringContainsQ[q, RegularExpression["(?i)(password|passwd|api[ _-]?key|secret|bearer)"]] ||
     StringContainsQ[q, "パスワード"] || StringContainsQ[q, "暗証"],
    AppendTo[pii, "SecretKeyword"]];
  score = Min[1., score];
  <|"Query" -> StringTake[q, UpTo[500]], "Suspicion" -> score, "Class" -> iWGClass[score],
    "Reasons" -> reasons, "OpaqueTokens" -> (iWGExcerpt /@ opaque), "PIIHints" -> pii,
    "Length" -> StringLength[q]|>];
SourceVaultWebGuardAnalyzeQuery[x_] := SourceVaultWebGuardAnalyzeQuery[ToString[x]];

(* ------------------------------------------------------------
   アクセスログ (append-only JSONL, プロセス別シャード YYYY-MM-p<pid>.jsonl)
   複数カーネル (FE / service / web job 子) が同じ LocalState に書くので
   ファイルを分け、読み手は月の全シャードを読む。
   ------------------------------------------------------------ *)
iWGLogPath[] := With[{d = iWGLogDir[]},
  If[StringQ[d],
    FileNameJoin[{d, DateString[TimeZoneConvert[Now, 0], {"Year", "-", "Month"}] <>
      "-p" <> ToString[$ProcessID] <> ".jsonl"}], $Failed]];

iWGAppendLog[rec_Association] := Module[{r, path, line},
  r = Join[<|"At" -> iWGNowIso[], "EventId" -> StringTake[StringDelete[CreateUUID[], "-"], 12],
    "Machine" -> iWGMachineTag[]|>, rec];
  path = iWGLogPath[];
  line = iWGToJSON[r];
  If[StringQ[path] && StringQ[line], iWGAppendLine[path, line]];
  iWGStatsApply[r];
  r];

iWGMonthsBetween[a_?NumericQ, b_?NumericQ] := Module[
  {d1 = DateList[TimeZoneConvert[DateObject[a], 0]], d2 = DateList[TimeZoneConvert[DateObject[b], 0]], y, m, out = {}},
  {y, m} = d1[[1 ;; 2]];
  While[y*12 + m <= d2[[1]]*12 + d2[[2]] && Length[out] < 240,
    AppendTo[out, IntegerString[y, 10, 4] <> "-" <> IntegerString[m, 10, 2]];
    m++; If[m > 12, m = 1; y++]];
  out];

iWGLogFilesForRange[sinceAbs_, untilAbs_] := Module[{dir = iWGLogDir[], months, files},
  If[! StringQ[dir] || ! DirectoryQ[dir], Return[{}]];
  files = FileNames["*.jsonl", dir];
  months = iWGMonthsBetween[sinceAbs, untilAbs];
  Select[files, StringLength[FileBaseName[#]] >= 7 && MemberQ[months, StringTake[FileBaseName[#], 7]] &]];

iWGToAbs[Automatic, default_] := default;
iWGToAbs[d_DateObject, _] := AbsoluteTime[d];
iWGToAbs[n_?NumericQ, _] := N[n];
iWGToAbs[s_String, default_] := Module[{a = iWGIsoToAbs[s]},
  If[NumericQ[a], Return[a]];
  a = Quiet @ Check[AbsoluteTime[DateObject[s]], $Failed];
  If[NumericQ[a], a, default]];
iWGToAbs[_, default_] := default;

Options[SourceVaultWebAccessLog] = {
  "Days" -> 30, "Since" -> Automatic, "Until" -> Automatic,
  "Actor" -> All, "Host" -> All, "Kind" -> All, "Decision" -> All,
  "MinSuspicion" -> 0, "Limit" -> All, "IncludeOwnerDecisions" -> True};

SourceVaultWebAccessLog[OptionsPattern[]] := Module[
  {now = AbsoluteTime[], since, until, days, recs, act, host, kind, dec, ms, lim},
  days = OptionValue["Days"]; If[! NumericQ[days] || days < 0, days = 30];
  until = iWGToAbs[OptionValue["Until"], now];
  since = iWGToAbs[OptionValue["Since"], until - days*86400];
  recs = Join @@ (iWGReadJSONL /@ iWGLogFilesForRange[since, until]);
  recs = Select[recs,
    With[{a = iWGIsoToAbs[ToString @ Lookup[#, "At", ""]]}, NumericQ[a] && since <= a <= until] &];
  If[! TrueQ[OptionValue["IncludeOwnerDecisions"]],
    recs = Select[recs, Lookup[#, "Decision", ""] =!= "OwnerDecided" &]];
  act = OptionValue["Actor"];
  If[StringQ[act] && act =!= "",
    recs = Select[recs, Lookup[#, "ActorId", ""] === act ||
      StringContainsQ[ToString @ Lookup[#, "ActorDisplay", ""], act, IgnoreCase -> True] ||
      StringContainsQ[ToString @ Lookup[#, "Model", ""], act, IgnoreCase -> True] &]];
  host = OptionValue["Host"];
  If[StringQ[host] && host =!= "",
    With[{h = iWGNormHost[host]},
      recs = Select[recs, With[{rh = ToString @ Lookup[#, "Host", ""]}, rh === h || StringEndsQ[rh, "." <> h]] &]]];
  kind = OptionValue["Kind"];
  If[StringQ[kind], recs = Select[recs, Lookup[#, "Kind", ""] === kind &]];
  dec = OptionValue["Decision"];
  If[StringQ[dec], recs = Select[recs, Lookup[#, "Decision", ""] === dec &]];
  If[ListQ[dec], recs = Select[recs, MemberQ[dec, Lookup[#, "Decision", ""]] &]];
  ms = OptionValue["MinSuspicion"];
  If[NumericQ[ms] && ms > 0,
    recs = Select[recs, With[{s = Lookup[#, "Suspicion", 0]}, NumericQ[s] && s >= ms] &]];
  recs = Reverse @ SortBy[recs, ToString @ Lookup[#, "At", ""] &];
  lim = OptionValue["Limit"];
  If[IntegerQ[lim] && lim >= 0, recs = Take[recs, UpTo[lim]]];
  iWGFixNull /@ recs];

(* ------------------------------------------------------------
   実績 (ログから再構成。カーネル内キャッシュ 10 分 + 自分の追記は即時反映)
   ------------------------------------------------------------ *)
If[! AssociationQ[$iWGStatsCache], $iWGStatsCache = <||>];
If[! IntegerQ[$iWGStatsWindowDays], $iWGStatsWindowDays = 180];

Options[iWGStats] = {"Rebuild" -> False};
iWGStats[OptionsPattern[]] := Module[{now = AbsoluteTime[], at = Lookup[$iWGStatsCache, "BuiltAt", None], recs},
  If[! TrueQ[OptionValue["Rebuild"]] && NumericQ[at] && now - at < 600 &&
     AssociationQ[Lookup[$iWGStatsCache, "Hosts", None]],
    Return[$iWGStatsCache]];
  recs = SourceVaultWebAccessLog["Days" -> $iWGStatsWindowDays, "Limit" -> All];
  $iWGStatsCache = <|"BuiltAt" -> now, "Hosts" -> <||>, "Actors" -> <||>|>;
  Scan[iWGStatsApply, Reverse[recs]];   (* 古い順に適用 *)
  $iWGStatsCache["BuiltAt"] = now;
  $iWGStatsCache];

iWGStatsApply[r_Association] := Module[{host, aid, dec, cls, day, at, hs, as, ba, noHostStats},
  If[! AssociationQ[Lookup[$iWGStatsCache, "Hosts", None]], Return[Null]];
  dec = ToString @ Lookup[r, "Decision", ""];
  If[dec === "OwnerDecided", Return[Null]];
  host = ToString @ Lookup[r, "Host", ""];
  aid = ToString @ Lookup[r, "ActorId", "?"];
  cls = ToString @ Lookup[r, "Class", "Plain"];
  at = ToString @ Lookup[r, "At", ""];
  day = If[StringLength[at] >= 10, StringTake[at, 10], at];
  (* V2: 実在しないホストは、ホストの統計に載せない (主体の統計には数える) *)
  noHostStats = ToString @ Lookup[r, "DecisionReason", ""] === "HostDoesNotExist";
  hs = Lookup[$iWGStatsCache["Hosts"], host,
    <|"AccessCount" -> 0, "Days" -> {}, "Suspicious" -> 0, "Denied" -> 0, "Approved" -> 0,
      "Pending" -> 0, "ByActor" -> <||>, "FirstSeen" -> at, "LastSeen" -> at|>];
  If[dec === "Allow",
    hs["AccessCount"] = hs["AccessCount"] + 1;
    hs["Days"] = DeleteDuplicates @ Append[hs["Days"], day];
    ba = hs["ByActor"]; If[! AssociationQ[ba], ba = <||>];
    hs["ByActor"] = Append[ba, aid -> (Lookup[ba, aid, 0] + 1)]];
  If[cls =!= "Plain", hs["Suspicious"] = hs["Suspicious"] + 1];
  If[dec === "Deny", hs["Denied"] = hs["Denied"] + 1];
  If[dec === "Pending", hs["Pending"] = hs["Pending"] + 1];
  If[dec === "Allow" && MemberQ[{"Owner", "Ticket"}, ToString @ Lookup[r, "DecisionBy", ""]],
    hs["Approved"] = hs["Approved"] + 1];
  hs["LastSeen"] = at;
  If[! noHostStats, $iWGStatsCache["Hosts"] = Append[$iWGStatsCache["Hosts"], host -> hs]];
  as = Lookup[$iWGStatsCache["Actors"], aid,
    <|"Count" -> 0, "Allowed" -> 0, "Denied" -> 0, "Pending" -> 0, "Suspicious" -> 0, "Hosts" -> {},
      "Display" -> ToString @ Lookup[r, "ActorDisplay", aid], "Kind" -> ToString @ Lookup[r, "ActorKind", ""],
      "FirstSeen" -> at, "LastSeen" -> at|>];
  as["Count"] = as["Count"] + 1;
  Switch[dec,
    "Allow", as["Allowed"] = as["Allowed"] + 1,
    "Deny", as["Denied"] = as["Denied"] + 1,
    "Pending", as["Pending"] = as["Pending"] + 1];
  If[cls =!= "Plain", as["Suspicious"] = as["Suspicious"] + 1];
  as["Hosts"] = DeleteDuplicates @ Append[as["Hosts"], host];
  as["LastSeen"] = at;
  $iWGStatsCache["Actors"] = Append[$iWGStatsCache["Actors"], aid -> as];
  Null];

(* ------------------------------------------------------------
   ホスト profile (PrivateVault/identity/webhosts.jsonl, Dropbox 同期)
   書き込みはオーナー決定と再計算時のみ (per-access の churn を避ける)。
   ------------------------------------------------------------ *)
If[! AssociationQ[$iWGProfiles], $iWGProfiles = <||>];
If[! ValueQ[$iWGProfilesMTime], $iWGProfilesMTime = None];

iWGProfilesLoad[] := Module[{path = SourceVaultWebHostStorePath[], recs},
  If[! StringQ[path] || ! FileExistsQ[path],
    If[! AssociationQ[$iWGProfiles], $iWGProfiles = <||>];
    Return[$iWGProfiles]];
  recs = iWGReadJSONL[path];
  $iWGProfiles = Association[
    (Lookup[#, "Host", ""] -> iWGFixNull[#]) & /@ Select[recs, StringQ[Lookup[#, "Host", Null]] &]];
  $iWGProfilesMTime = Quiet @ Check[AbsoluteTime[FileDate[path, "Modification"]], None];
  $iWGProfiles];

(* 別カーネル (FE) がオーナー決定で書き換えた profile を service kernel が拾う *)
iWGProfilesEnsureFresh[] := Module[{path = SourceVaultWebHostStorePath[], mt},
  If[! StringQ[path] || ! FileExistsQ[path], Return[$iWGProfiles]];
  mt = Quiet @ Check[AbsoluteTime[FileDate[path, "Modification"]], None];
  If[mt =!= $iWGProfilesMTime, iWGProfilesLoad[]];
  $iWGProfiles];

iWGProfilesSave[] := Module[{path = SourceVaultWebHostStorePath[], lines, tmp, strm},
  If[! StringQ[path], Return[$Failed]];
  lines = Select[iWGToJSON /@ Values[KeySort[$iWGProfiles]], StringQ];
  iWGEnsureDir[DirectoryName[path]];
  tmp = path <> ".tmp." <> ToString[$ProcessID];
  strm = Quiet @ OpenWrite[tmp, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  Scan[BinaryWrite[strm, StringToByteArray[# <> "\n", "UTF-8"]] &, lines];
  Close[strm];
  If[Quiet @ Check[RenameFile[tmp, path, OverwriteTarget -> True], $Failed] === $Failed,
    Quiet @ DeleteFile[tmp]; Return[$Failed]];
  $iWGProfilesMTime = Quiet @ Check[AbsoluteTime[FileDate[path, "Modification"]], None];
  path];

iWGBuiltinLevel[host_String] := Module[{hits},
  hits = Select[Keys[$SourceVaultWebGuardBuiltinHosts], (host === # || StringEndsQ[host, "." <> #]) &];
  If[hits === {}, Missing["NotBuiltin"], Max[N /@ Lookup[$SourceVaultWebGuardBuiltinHosts, hits]]]];

iWGEstablishedQ[total_, days_, susp_, den_] :=
  total >= iWGPol["EstablishedCount"] && days >= iWGPol["EstablishedDays"] && susp == 0 && den == 0;

iWGEstimate[host_String, total_, days_, susp_, den_] := Module[{b = iWGBuiltinLevel[host]},
  Which[
    iWGEstablishedQ[total, days, susp, den],
      <|"Level" -> Max[N @ iWGPol["PrivatePL"], If[NumericQ[b], b, 0.]], "Basis" -> "Established",
        "Confidence" -> Min[1., total/50.]|>,
    NumericQ[b],
      <|"Level" -> N[b], "Basis" -> "Builtin", "Confidence" -> 0.8|>,
    True,
      <|"Level" -> N @ iWGPol["DefaultHostLevel"], "Basis" -> "Default", "Confidence" -> 0.2|>]];

iWGBasisToSource[basis_String] := Switch[basis, "Established", "Estimated", "Builtin", "Builtin", _, "Default"];

(* ISO 文字列の min/max。文字列に <= は使えない (未評価のまま残る) ので OrderedQ で比較する。 *)
iWGIsoMin[a_, b_] := Which[! StringQ[a] || a === "", b, ! StringQ[b] || b === "", a, OrderedQ[{a, b}], a, True, b];
iWGIsoMax[a_, b_] := Which[! StringQ[a] || a === "", b, ! StringQ[b] || b === "", a, OrderedQ[{a, b}], b, True, a];

(* profile (保存値) + ローカル実績 + 他機スナップショット -> 実効 view *)
iWGHostViewFrom[host_String, prof_Association, st_Association] := Module[
  {others, total, days, susp, den, appr, status, src, est, level, first, last, byActor, stored},
  others = Lookup[prof, "StatsByMachine", <||>];
  If[! AssociationQ[others], others = <||>];
  others = KeyDrop[others, iWGMachineTag[]];
  others = Select[others, AssociationQ];
  total = Lookup[st, "AccessCount", 0] + Total[Lookup[#, "AccessCount", 0] & /@ Values[others]];
  days = Length[DeleteDuplicates[Join[Replace[Lookup[st, "Days", {}], Except[_List] -> {}],
     Flatten[Replace[Lookup[#, "Days", {}], Except[_List] -> {}] & /@ Values[others]]]]];
  susp = Lookup[st, "Suspicious", 0] + Total[Lookup[#, "Suspicious", 0] & /@ Values[others]];
  den = Lookup[st, "Denied", 0] + Total[Lookup[#, "Denied", 0] & /@ Values[others]];
  appr = Lookup[st, "Approved", 0] + Total[Lookup[#, "Approved", 0] & /@ Values[others]];
  status = ToString @ Lookup[prof, "TrustStatus", "Observed"];
  src = ToString @ Lookup[prof, "PolicySource", "Default"];
  est = iWGEstimate[host, total, days, susp, den];
  stored = Lookup[prof, "AccessLevel", est["Level"]]; If[! NumericQ[stored], stored = est["Level"]];
  level = Which[
    status === "Blocked", 0.0,
    src === "Owner", N[stored],
    True, Max[N[stored], est["Level"]]];
  first = iWGIsoMin[Lookup[prof, "FirstSeen", ""], Lookup[st, "FirstSeen", ""]];
  last = iWGIsoMax[Lookup[prof, "LastSeen", ""], Lookup[st, "LastSeen", ""]];
  byActor = Lookup[st, "ByActor", <||>]; If[! AssociationQ[byActor], byActor = <||>];
  <|"Host" -> host, "IdentifierId" -> iWGIdentifierId["WebHost", host],
    "AccessLevel" -> N[stored], "EffectiveLevel" -> level,
    "TrustStatus" -> status, "PolicySource" -> src,
    "Confidence" -> Lookup[prof, "Confidence", est["Confidence"]],
    "AccessCount" -> total, "LocalAccessCount" -> Lookup[st, "AccessCount", 0],
    "DistinctDays" -> days, "Suspicious" -> susp, "Denied" -> den, "Approved" -> appr,
    "Established" -> iWGEstablishedQ[total, days, susp, den], "Estimate" -> est,
    "FirstSeen" -> If[first === "", Missing["Unseen"], first],
    "LastSeen" -> If[last === "", Missing["Unseen"], last],
    "Builtin" -> iWGBuiltinLevel[host], "ByActor" -> byActor,
    "Note" -> Lookup[prof, "Note", Missing["NotSet"]],
    (* V7: 所有者が、評判のリストに載っていることを承知のうえで許可したホスト (方針の提案への回答で付く) *)
    "ListOverride" -> (status === "Approved" && src === "Owner" && TrueQ[Lookup[prof, "ListOverride", False]])|>];

iWGHostView[hostIn_String] := Module[{host = iWGNormHost[hostIn], prof, st},
  iWGProfilesEnsureFresh[];
  prof = Lookup[$iWGProfiles, host, <||>]; If[! AssociationQ[prof], prof = <||>];
  st = Lookup[iWGStats[]["Hosts"], host, <||>]; If[! AssociationQ[st], st = <||>];
  iWGHostViewFrom[host, prof, st]];

SourceVaultWebHostProfile[host_String] := iWGHostView[host];

SourceVaultWebHostProfiles[] := Module[{hosts},
  iWGProfilesEnsureFresh[];
  hosts = DeleteCases[Union[Keys[$iWGProfiles], Keys[iWGStats[]["Hosts"]]], "websearch" | ""];
  iWGHostView /@ Sort[hosts]];

SourceVaultWebHostEstimateAccess[host_String] :=
  With[{v = iWGHostView[host]}, Append[v["Estimate"], "Host" -> v["Host"]]];

(* ------------------------------------------------------------
   V8 (文書 12 の 7.3 節、2026-11-13): 所有者の判断の記録
   ------------------------------------------------------------
   所有者の判断は、これまで関所の記録に 1 行 (OwnerDecided) が残るだけで、所有者が入力セルから直接ホストを許可した分は
   どこにも残らなかった。ここでは、関所についての所有者の判断を 1 つの記録にまとめる。
   - 記録するもの: ホストの許可・遮断・機密度の変更・「リストを承知で許可」(SourceVaultWebHostSetAccess を通るすべて)、
     方針の提案への回答、承認の窓での回答、関所の設定の切り替え (気づいた時点で。iWGPostureCheck)、再確認。
   - 文脈: 提示から決定までの秒数、その日の何件目か、提示した材料の digest、経路 (提案・窓・直接・検出)、前後の値。
   - 緩める方向か締める方向かを付ける (Direction)。壁の高さの推移と、月次の「緩めたもの」の一覧に使う。
   - 置き場は PrivateVault/identity/owner_decisions-<機>.jsonl (追記だけ)。ホストの許可そのものが PrivateVault にあるので、
     記録も同じ所に置く (どの機からも見直せる)。機ごとのファイルにして、2 台で書いても衝突しないようにする。
   - 検索語・URL・依頼文は入れない (対象の名前と、決めた内容だけ)。
   これは所有者の判断を覆すためのものではない (7.4 節)。記録して、緩めたものを定期的に見直せるようにするだけである。 *)
If[! ValueQ[$iWGDecisionContext], $iWGDecisionContext = None];   (* 回答の関数が Block で置く <|Via, Ref, Seconds, MaterialDigest, Action|> *)
iWGDecisionJournalPath[] := iWGSub[iWGIdentityDir[], "owner_decisions-" <> iWGMachineTag[] <> ".jsonl"];
iWGDecisionJournalFiles[] := With[{d = iWGIdentityDir[]},
  If[StringQ[d] && DirectoryQ[d], FileNames["owner_decisions-*.jsonl", d], {}]];
iWGDecisionRead[] := Select[Join @@ (iWGReadJSONL /@ iWGDecisionJournalFiles[]), AssociationQ];
(* 古い順。同じ時刻のものは、ファイルに書いた順のまま (安定な並べ替え) *)
iWGDecisionSorted[rs_List] := SortBy[rs, {ToString @ Lookup[#, "At", ""] &, Replace[Lookup[#, "Ms", 0], Except[_?NumericQ] -> 0] &}];
iWGDigest[x_] := "sha256:" <> StringTake[iWGHex[ToString[x, InputForm]], 32];
iWGNoteOwnerDecision[rec_Association] := Module[{now = AbsoluteTime[], path = iWGDecisionJournalPath[], today, nth, r, line},
  today = iWGLocalDay[now];
  nth = 1 + Count[If[StringQ[path] && FileExistsQ[path], iWGReadJSONL[path], {}],
    q_ /; With[{a = iWGIsoToAbs[ToString @ Lookup[q, "At", ""]]}, NumericQ[a] && iWGLocalDay[a] === today && Lookup[q, "Via", ""] =!= "Detected"]];
  (* "Ms" は秒の中の順番を決めるためのもの (At は秒までなので、同じ秒の判断の前後が分からなくなる) *)
  r = Join[<|"At" -> iWGAbsToIso[now], "Ms" -> Floor[1000*FractionalPart[now]],
      "DecisionId" -> "od-" <> StringTake[StringDelete[CreateUUID[], "-"], 12],
      "Machine" -> iWGMachineTag[], "Domain" -> "WebGuard", "Principal" -> iWGPrincipalKind[],
      "Via" -> "Direct", "Ref" -> "", "Seconds" -> -1, "MaterialDigest" -> "", "NthThatDay" -> nth|>,
    rec];
  line = iWGToJSON[r];
  If[StringQ[path] && StringQ[line], iWGAppendLine[path, line]];
  r];
iWGNoteOwnerDecision[___] := Null;
(* ホストについて所有者が決めていること (前後を比べるための形) *)
iWGHostPolicyState[prof_] := With[{p = If[AssociationQ[prof], prof, <||>]},
  <|"TrustStatus" -> ToString @ Lookup[p, "TrustStatus", "Observed"], "PolicySource" -> ToString @ Lookup[p, "PolicySource", "Default"],
    "Level" -> With[{l = Lookup[p, "AccessLevel", None]}, If[NumericQ[l], N[l], -1.]],
    "ListOverride" -> TrueQ[Lookup[p, "ListOverride", False]]|>];
iWGHostChangeDirection[b_Association, a_Association] := Which[
  b["TrustStatus"] === "Blocked" && a["TrustStatus"] =!= "Blocked", "Loosen",
  a["TrustStatus"] === "Blocked" && b["TrustStatus"] =!= "Blocked", "Tighten",
  a["TrustStatus"] === "Approved" && b["TrustStatus"] =!= "Approved", "Loosen",
  b["TrustStatus"] === "Approved" && a["TrustStatus"] =!= "Approved", "Tighten",
  a["TrustStatus"] === "Approved" && b["TrustStatus"] === "Approved",
    Which[a["Level"] > b["Level"] || (a["ListOverride"] && ! b["ListOverride"]), "Loosen",
      a["Level"] < b["Level"] || (b["ListOverride"] && ! a["ListOverride"]), "Tighten", True, "Neutral"],
  True, "Neutral"];
iWGHostChangeAction[b_Association, a_Association] := Which[
  a["TrustStatus"] === "Blocked", "BlockHost",
  b["TrustStatus"] === "Blocked", "Unblock",
  a["TrustStatus"] === "Approved" && b["TrustStatus"] =!= "Approved", If[a["ListOverride"], "AllowDespiteList", "AllowHost"],
  b["TrustStatus"] === "Approved" && a["TrustStatus"] =!= "Approved", "Revoke",
  a["ListOverride"] && ! b["ListOverride"], "AllowDespiteList",
  a["Level"] > b["Level"], "RaiseLevel", a["Level"] < b["Level"], "LowerLevel", True, "SetAccess"];
(* SourceVaultWebHostSetAccess から呼ぶ。所有者の設定 (PolicySource Owner) に関わる変更と、回答の関数からの呼び出しを記録する。
   何も変わらない呼び出し (起動のたびに同じ許可を入れ直す init など) は記録しない *)
iWGJournalHostChange[host_String, before_Association, after_Association] := Module[{ctx = $iWGDecisionContext},
  If[! AssociationQ[ctx] && (KeyDrop[before, "PolicySource"] === KeyDrop[after, "PolicySource"] ||
      (before["PolicySource"] =!= "Owner" && after["PolicySource"] =!= "Owner")), Return[Null, Module]];
  iWGNoteOwnerDecision[Join[
    <|"Action" -> iWGHostChangeAction[before, after], "Direction" -> iWGHostChangeDirection[before, after],
      "TargetKind" -> "Host", "Target" -> host, "Previous" -> KeyDrop[before, "PolicySource"], "New" -> KeyDrop[after, "PolicySource"]|>,
    If[AssociationQ[ctx], KeyTake[ctx, {"Via", "Ref", "Seconds", "MaterialDigest"}], <||>]]]];
iWGJournalHostChange[___] := Null;

Options[SourceVaultWebHostSetAccess] = {"TrustStatus" -> "Approved", "PolicySource" -> "Owner",
  "Note" -> Missing[], "Persist" -> True, "Confidence" -> 1.0,
  (* V7: True = 評判のリスト (ホスト単位) とフィルタ付きの DNS に載っていても、このホストは止めない。False で外す。
     Automatic は今の値のまま。URL そのものがリストに載っているページは、これを付けても止める *)
  "ListOverride" -> Automatic};
SourceVaultWebHostSetAccess[hostIn_String, level_?NumericQ, OptionsPattern[]] := Module[
  {host = iWGNormHost[hostIn], prof, now = iWGNowIso[], before},
  If[host === "", Return[Failure["EmptyHost", <||>]]];
  iWGProfilesEnsureFresh[];
  prof = Lookup[$iWGProfiles, host, <||>]; If[! AssociationQ[prof], prof = <||>];
  before = iWGHostPolicyState[prof];
  prof = Join[prof, <|"Type" -> "SourceVaultWebHostProfile", "SchemaVersion" -> 1,
    "Host" -> host, "IdentifierId" -> iWGIdentifierId["WebHost", host],
    "AccessLevel" -> Clip[N[level], {0., 1.}],
    "TrustStatus" -> OptionValue["TrustStatus"], "PolicySource" -> OptionValue["PolicySource"],
    "Confidence" -> OptionValue["Confidence"], "UpdatedAt" -> now|>];
  If[! StringQ[Lookup[prof, "FirstSeen", Null]], prof["FirstSeen"] = now];
  If[StringQ[OptionValue["Note"]], prof["Note"] = OptionValue["Note"]];
  Switch[OptionValue["ListOverride"],
    True, prof["ListOverride"] = True; prof["ListOverrideAt"] = now,
    False, prof = KeyDrop[prof, {"ListOverride", "ListOverrideAt"}]];
  (* 許可をやめた・遮断したホストに、リストの無視を残さない *)
  If[OptionValue["TrustStatus"] =!= "Approved", prof = KeyDrop[prof, {"ListOverride", "ListOverrideAt"}]];
  (* V8: 所有者が決め直したら、前の再確認の印は外す (次の再確認の期限は、この変更から数える) *)
  If[iWGHostPolicyState[prof] =!= before, prof = Append[KeyDrop[prof, "ReconfirmedAt"], "PolicyChangedAt" -> now]];
  $iWGProfiles = Append[$iWGProfiles, host -> prof];
  iWGObserveIdentity["WebHost", host];
  If[TrueQ[OptionValue["Persist"]],
    iWGProfilesSave[];
    (* V8 (文書 12 の 7.3 節): 所有者の判断の記録に残す (保存する変更だけ) *)
    Quiet @ Check[iWGJournalHostChange[host, before, iWGHostPolicyState[prof]], Null]];
  prof];

Options[SourceVaultWebHostBlock] = Options[SourceVaultWebHostSetAccess];
SourceVaultWebHostBlock[host_String, opts : OptionsPattern[]] :=
  SourceVaultWebHostSetAccess[host, 0.0, "TrustStatus" -> "Blocked", "PolicySource" -> "Owner", opts];

Options[SourceVaultWebHostRecomputeProfiles] = {"Persist" -> True};
SourceVaultWebHostRecomputeProfiles[OptionsPattern[]] := Module[
  {tag = iWGMachineTag[], stats, hosts, changed = 0, now = iWGNowIso[]},
  iWGProfilesEnsureFresh[];
  stats = iWGStats["Rebuild" -> True]["Hosts"];
  hosts = DeleteCases[Union[Keys[$iWGProfiles], Keys[stats]], "websearch" | ""];
  Scan[Function[h, Module[{prof, prev, snap, sbm, v, est},
     prev = Lookup[$iWGProfiles, h, <||>]; If[! AssociationQ[prev], prev = <||>];
     prof = Join[<|"Type" -> "SourceVaultWebHostProfile", "SchemaVersion" -> 1, "Host" -> h,
        "IdentifierId" -> iWGIdentifierId["WebHost", h], "TrustStatus" -> "Observed",
        "PolicySource" -> "Default", "CreatedAt" -> now|>, prev];
     snap = Lookup[stats, h, <||>]; If[! AssociationQ[snap], snap = <||>];
     sbm = Lookup[prof, "StatsByMachine", <||>]; If[! AssociationQ[sbm], sbm = <||>];
     prof["StatsByMachine"] = Append[sbm, tag ->
        KeyTake[snap, {"AccessCount", "Days", "Suspicious", "Denied", "Approved", "FirstSeen", "LastSeen", "ByActor"}]];
     v = iWGHostViewFrom[h, prof, snap];
     If[Lookup[prof, "PolicySource", "Default"] =!= "Owner" && Lookup[prof, "TrustStatus", ""] =!= "Blocked",
       est = v["Estimate"];
       prof["AccessLevel"] = est["Level"];
       prof["PolicySource"] = iWGBasisToSource[est["Basis"]];
       prof["Confidence"] = est["Confidence"]];
     If[StringQ[v["FirstSeen"]], prof["FirstSeen"] = v["FirstSeen"]];
     If[StringQ[v["LastSeen"]], prof["LastSeen"] = v["LastSeen"]];
     If[KeyDrop[prof, {"UpdatedAt"}] =!= KeyDrop[prev, {"UpdatedAt"}], changed++];
     prof["UpdatedAt"] = now;
     $iWGProfiles = Append[$iWGProfiles, h -> prof];
     iWGObserveIdentity["WebHost", h]]],
    hosts];
  If[TrueQ[OptionValue["Persist"]], iWGProfilesSave[]; iWGIdentitySave[]];
  <|"Status" -> "OK", "Hosts" -> Length[hosts], "Changed" -> changed, "Machine" -> tag,
    "Path" -> SourceVaultWebHostStorePath[]|>];

(* identity 層 (弱結合)。未ロード store を上書きしないよう EnsureLoaded を先に通す。 *)
iWGObserveIdentity[kind_String, value_String, name_: Missing[]] :=
  If[Length[DownValues[SourceVault`SourceVaultObserveIdentifier]] > 0 && value =!= "",
    Quiet @ Check[
      If[Length[DownValues[SourceVault`SourceVaultIdentityEnsureLoaded]] > 0,
        SourceVault`SourceVaultIdentityEnsureLoaded[]];
      SourceVault`SourceVaultObserveIdentifier[kind, value, "ObservedName" -> name, "Persist" -> False],
      Null],
    Null];
iWGIdentitySave[] :=
  If[Length[DownValues[SourceVault`SourceVaultIdentitySave]] > 0 &&
     TrueQ[Quiet @ Check[SourceVault`Private`$iSVIDLoaded, False]],
    Quiet @ Check[SourceVault`SourceVaultIdentitySave[], Null], Null];

(* ------------------------------------------------------------
   文脈 PL (spec §5)
   ------------------------------------------------------------ *)
If[! AssociationQ[$iWGDeclared], $iWGDeclared = <||>];
iWGSafeName[s_String] := StringReplace[ToLowerCase[s],
  Except[LetterCharacter | DigitCharacter | "-" | "_" | "."] -> "_"];

SourceVaultWebGuardDeclareContext[spec_Association] := Module[{prov, model, pl, rec, dir, key},
  prov = ToString @ Lookup[spec, "Provider", "unknown"];
  model = ToString @ Lookup[spec, "Model", ""];
  pl = Lookup[spec, "PrivacyLevel", None];
  If[! NumericQ[pl], pl = $SourceVaultWebGuardUnknownContextPL];
  pl = Clip[N[pl], {0., 1.}];
  rec = <|"Provider" -> prov, "Model" -> model, "PrivacyLevel" -> pl,
    "URL" -> Lookup[spec, "URL", Missing[]], "SessionId" -> Lookup[spec, "SessionId", Missing[]],
    "AtUTC" -> iWGNowIso[], "Abs" -> AbsoluteTime[], "Machine" -> iWGMachineTag[], "Pid" -> $ProcessID|>;
  key = iWGSafeName[prov];
  dir = iWGContextDir[];
  (* I-01 / 02 v1.2 P0-12 (2026-11-09): 後勝ちをやめる。同じ provider の既存申告 (メモリ、無ければファイル) が
     同一 SessionId なら PrivacyLevel は Max でだけ更新する (低い値を後から申告して文脈 PL を下げられない)。
     別 session の申告は置き換える。
     V1 (文書 12 §3.2、2026-11-12): 「同じ session」に範囲と期限を付けた。以前は claudecode が SessionId に定数 "history" を
     渡していたので、どの会話も同じ session とみなされ、一度 1.0 を申告した provider は、申告のたびに時刻だけが新しくなって
     文脈 PL が 1.0 のまま下がらなかった (2026-11-12 の障害)。いまは、(1) SessionId が会話を区別できる文字列であること
     (無い・定数 "history" は別 session 扱い)、(2) 既存の申告が有効時間 ($SourceVaultWebGuardContextTTLSeconds) の中であること、
     の両方を満たすときだけ Max で引き継ぐ。 *)
  Module[{old = Lookup[$iWGDeclared, key, Missing[]], f},
    If[! AssociationQ[old] && StringQ[dir],
      f = FileNameJoin[{dir, key <> ".json"}];
      If[FileExistsQ[f], With[{r = iWGReadJSON[f]}, If[AssociationQ[r], old = iWGFixNull[r]]]]];
    If[AssociationQ[old] && iWGSameSessionQ[old, rec] && iWGDeclarationFreshQ[old] &&
        NumericQ[Lookup[old, "PrivacyLevel", None]] && old["PrivacyLevel"] > pl,
      rec = Join[rec, <|"PrivacyLevel" -> N[old["PrivacyLevel"]], "DeclaredPrivacyLevel" -> pl,
        "RaisedBy" -> "SameSessionMax"|>]]];
  $iWGDeclared = Append[$iWGDeclared, key -> rec];
  If[StringQ[dir], Quiet @ iWGWriteJSON[FileNameJoin[{dir, key <> ".json"}], KeyDrop[rec, "Abs"]]];
  (* FE カーネルで claudecode が LLM を呼ぶ = 未決 request を見る人がいる。ロード時に claudecode が
     未ロードで監視登録できなかった場合もここで遅延登録する (申告は毎回呼ばれるので冪等に 1 回だけ)。 *)
  If[TrueQ[$Notebooks] && ! TrueQ[$iWGWatchRegistered],
    Quiet @ Check[SourceVaultWebGuardStartPendingWatch[], Null]];
  rec];
SourceVaultWebGuardDeclareContext[___] := $Failed;
(* V1: 会話を区別できる SessionId だけを「同じ session」の根拠にする。"history" は claudecode の履歴のタグ名で、
   以前はこれがそのまま渡されていた (全会話で同じ値)。 *)
iWGRealSessionIdQ[id_] := StringQ[id] && StringTrim[id] =!= "" &&
  ! MemberQ[{"history", "unknown", "default"}, ToLowerCase[id]] && ! StringStartsQ[ToLowerCase[id], "history_"];
iWGSameSessionQ[a_Association, b_Association] :=
  With[{x = Lookup[a, "SessionId", Missing[]], y = Lookup[b, "SessionId", Missing[]]},
    iWGRealSessionIdQ[x] && iWGRealSessionIdQ[y] && x === y];
iWGSameSessionQ[___] := False;
iWGDeclarationFreshQ[r_Association] := Module[{a = Lookup[r, "Abs", None], ttl = $SourceVaultWebGuardContextTTLSeconds},
  If[! NumericQ[a], a = iWGIsoToAbs[ToString @ Lookup[r, "AtUTC", ""]]];
  If[! NumericQ[ttl], ttl = 900];
  NumericQ[a] && AbsoluteTime[] - a <= ttl];
iWGDeclarationFreshQ[___] := False;

iWGFreshDeclarations[] := Module[{ttl = $SourceVaultWebGuardContextTTLSeconds, now = AbsoluteTime[], mem, dir, files, recs},
  mem = Select[Values[$iWGDeclared], NumericQ[Lookup[#, "Abs", None]] && now - #["Abs"] <= ttl &];
  dir = iWGContextDir[];
  files = If[StringQ[dir] && DirectoryQ[dir], FileNames["*.json", dir], {}];
  recs = Select[Map[Function[f, Module[{r = iWGReadJSON[f], a},
       If[! AssociationQ[r], Nothing,
         a = iWGIsoToAbs[ToString @ Lookup[r, "AtUTC", ""]];
         If[! NumericQ[a] || now - a > ttl, Nothing, Append[iWGFixNull[r], "Abs" -> a]]]]], files],
    AssociationQ];
  DeleteDuplicatesBy[Join[mem, recs], {Lookup[#, "Provider"], Lookup[#, "Pid"]} &]];

SourceVaultWebGuardContext[] := Module[{decls, pls, evalPL, pl, src, freshest},
  decls = iWGFreshDeclarations[];
  pls = Select[Lookup[#, "PrivacyLevel", None] & /@ decls, NumericQ];
  evalPL = If[Length[DownValues[SourceVault`SourceVaultEvaluationPrivacy]] > 0,
    Quiet @ Check[SourceVault`SourceVaultEvaluationPrivacy[], None], None];
  Which[
    pls =!= {} && NumericQ[evalPL] && evalPL > Max[pls], pl = N[evalPL]; src = "Evaluation",
    pls =!= {}, pl = N @ Max[pls]; src = "Declared",
    NumericQ[evalPL] && evalPL > 0, pl = N[evalPL]; src = "Evaluation",
    True, pl = N[$SourceVaultWebGuardUnknownContextPL]; src = "Unknown"];
  freshest = If[decls === {}, Missing["NoDeclaration"], First[SortBy[decls, -Lookup[#, "Abs", 0] &]]];
  <|"PrivacyLevel" -> pl, "Source" -> src, "Declarations" -> decls, "Freshest" -> freshest|>];

(* W1 (文書 11 §4・§5.1・§5.4、2026-11-12): 会話の高水位と段。高水位はツールループが $SourceVaultWebGuardSession に持ち、
   MCP の返し口 ($SourceVaultMCPCallReport) が呼び出しごとに返す放出 PL で上げる (下げない)。
   段 0 = 高水位 <= LowRiskPL、段 1 = その間、段 2 = >= PrivatePL。段 2 で外向きを絞るのは "Guard" 以外 (fail-closed)。 *)
iWGSessionPL[] := With[{s = $SourceVaultWebGuardSession},
  If[AssociationQ[s] && NumericQ[Lookup[s, "PL", None]], Clip[N[s["PL"]], {0., 1.}], None]];
(* V11 (文書 12 の 8.18 節): "SearchRoute" = この段の検索の送り先。"Open" (段 0、SearXNG の既定のエンジン)・
   "EnginesOnly" (段 1、または段 2 で PrivateStageSearch が "EnginesOnly": 方針の SearchEngines だけ)・"Denied" (段 2 で "Deny")。
   "Restrict" は取得の絞り込み (段 2 は依頼文と検索結果の URL だけ) で、検索とは別に決まる *)
SourceVaultWebGuardSessionStage[pl_?NumericQ] := Module[{p = Clip[N[pl], {0., 1.}], lo = N @ iWGPol["LowRiskPL"], hi = N @ iWGPol["PrivatePL"],
    st, restrict},
  st = Which[p >= hi, 2, p > lo, 1, True, 0];
  restrict = (p >= hi && $SourceVaultWebGuardPrivateStage =!= "Guard");
  <|"Stage" -> st, "PL" -> p, "Restrict" -> restrict,
    "SearchRoute" -> Which[st === 0, "Open", restrict && iWGPol["PrivateStageSearch"] === "Deny", "Denied", True, "EnginesOnly"],
    "LowRiskPL" -> lo, "PrivatePL" -> hi|>];
SourceVaultWebGuardSessionStage[] := With[{p = iWGSessionPL[]},
  If[NumericQ[p], SourceVaultWebGuardSessionStage[p], <|"Stage" -> None, "PL" -> None, "Restrict" -> False, "SearchRoute" -> None|>]];
SourceVaultWebGuardSessionStage[___] := <|"Stage" -> None, "PL" -> None, "Restrict" -> False, "SearchRoute" -> None|>;

(* ------------------------------------------------------------
   V1 (文書 12 §3.2、2026-11-12): 会話をまたぐ高水位
   - 何のため: 前の往復で機密を読んだ会話では、その応答が履歴として次の往復のプロンプトに入る。次の往復のループが
     段 0 から始まると、履歴の中の機密を検索語に載せられる。以前は、申告が張り付いていたために偶然これが覆われていた
     (そのかわり、無関係な会話まで止めていた)。
   - 範囲: 1 つの会話。ID は claudecode が履歴のヘッダーに置く (履歴と一緒に保存され、履歴を消すと新しい ID になる)。
     別のノートブック・履歴を消した後の会話には引き継がない。
   - 上げ方: ツールループが、開始時と高水位が上がるたびに書く (上げるだけ)。値は「モデルに渡した中身の PL」で、
     モデルの AccessLevel (読ませてよい上限) ではない。
   - 解除 (文書 12 の P7): 履歴を消す (新しい ID)、または所有者が SourceVaultWebGuardConversationReset。
   - 置き場: LocalState/webguard/conversations/<id のハッシュ>.json (PL と時刻だけ。機ごと)。メモリにも持ち、大きい方を使う。
   ------------------------------------------------------------ *)
If[! AssociationQ[$iWGConversations], $iWGConversations = <||>];
iWGConvIdQ[id_] := StringQ[id] && 8 <= StringLength[id] <= 200;
iWGConvKey[id_String] := StringTake[iWGHex["conversation|" <> id], 32];
iWGConvDir[] := iWGSub[iWGLocalStateDir[], "webguard", "conversations"];
iWGConvPath[id_String] := With[{d = iWGConvDir[]},
  If[StringQ[d], FileNameJoin[{d, iWGConvKey[id] <> ".json"}], $Failed]];
iWGConvLoad[id_String] := Module[{k = iWGConvKey[id], mem, p, disk = Missing["NotRecorded"], best},
  mem = Lookup[$iWGConversations, k, Missing["NotRecorded"]];
  p = iWGConvPath[id];
  If[StringQ[p] && FileExistsQ[p],
    disk = iWGReadJSON[p];
    disk = If[AssociationQ[disk] && NumericQ[Lookup[disk, "PL", None]], iWGFixNull[disk], Missing["NotRecorded"]]];
  best = Which[
    AssociationQ[mem] && AssociationQ[disk], If[N[disk["PL"]] > N[mem["PL"]], disk, mem],
    AssociationQ[mem], mem,
    AssociationQ[disk], disk,
    True, Missing["NotRecorded"]];
  If[AssociationQ[best], $iWGConversations[k] = best];
  best];
iWGConvLoad[___] := Missing["NotRecorded"];

SourceVaultWebGuardConversation[id_String] := Module[{r, pl},
  If[! iWGConvIdQ[id], Return[<|"PL" -> 0., "Known" -> False|>]];
  r = iWGConvLoad[id];
  If[! AssociationQ[r], Return[<|"PL" -> 0., "Known" -> False|>]];
  pl = Clip[N[r["PL"]], {0., 1.}];
  <|"PL" -> pl, "Known" -> True, "Stage" -> Lookup[SourceVaultWebGuardSessionStage[pl], "Stage", None],
    "RaisedBy" -> Lookup[r, "RaisedBy", Missing[]], "UpdatedAtUTC" -> Lookup[r, "UpdatedAtUTC", Missing[]],
    "FirstAtUTC" -> Lookup[r, "FirstAtUTC", Missing[]]|>];
SourceVaultWebGuardConversation[___] := <|"PL" -> 0., "Known" -> False|>;

SourceVaultWebGuardConversationNote[id_String, plIn_?NumericQ, raisedBy_ : "Unknown"] := Module[{old, oldPL, new, rec, p, now},
  If[! iWGConvIdQ[id], Return[<|"PL" -> 0., "Raised" -> False, "Known" -> False|>]];
  new = Clip[N[plIn], {0., 1.}];
  old = iWGConvLoad[id];
  oldPL = If[AssociationQ[old], Clip[N[old["PL"]], {0., 1.}], 0.];
  If[new <= oldPL, Return[<|"PL" -> oldPL, "Raised" -> False, "Known" -> AssociationQ[old]|>]];
  now = iWGNowIso[];
  rec = <|"PL" -> new,
    "RaisedBy" -> StringTake[StringReplace[ToString[raisedBy], Except[WordCharacter | "_" | "-" | ":" | "."] -> ""], UpTo[80]],
    "UpdatedAtUTC" -> now,
    "FirstAtUTC" -> If[AssociationQ[old] && StringQ[Lookup[old, "FirstAtUTC", None]], old["FirstAtUTC"], now],
    "Machine" -> iWGMachineTag[]|>;
  $iWGConversations[iWGConvKey[id]] = rec;
  p = iWGConvPath[id];
  If[StringQ[p], Quiet @ iWGWriteJSON[p, rec]];
  <|"PL" -> new, "Raised" -> True, "Known" -> True|>];
SourceVaultWebGuardConversationNote[___] := <|"PL" -> 0., "Raised" -> False, "Known" -> False|>;

SourceVaultWebGuardConversationReset[id_String] := Module[{pk = iWGPrincipalKind[], old, p, ls = iWGLocalStateDir[], line},
  If[! MemberQ[{"OwnerFE", "OwnerCode"}, pk],
    Return[Failure["WebGuardNotAuthorized", <|"Function" -> "SourceVaultWebGuardConversationReset", "Principal" -> pk,
      "MessageTemplate" -> "SourceVaultWebGuardConversationReset may be called only by the owner; the current principal is `1`. From the front end use SourceVaultIntegrityOwnerAction[SourceVaultWebGuardConversationReset[id]].",
      "MessageParameters" -> {pk}|>]]];
  If[! iWGConvIdQ[id], Return[<|"Reset" -> False, "Known" -> False|>]];
  old = iWGConvLoad[id];
  $iWGConversations = KeyDrop[$iWGConversations, iWGConvKey[id]];
  p = iWGConvPath[id];
  If[StringQ[p] && FileExistsQ[p], Quiet @ DeleteFile[p]];
  (* 所有者の判断の記録 (文書 12 の P6)。会話の ID はハッシュだけを残す *)
  If[StringQ[ls],
    line = iWGToJSON[<|"AtUTC" -> iWGNowIso[], "Machine" -> iWGMachineTag[], "Principal" -> pk,
      "ConversationKey" -> iWGConvKey[id], "Known" -> AssociationQ[old],
      "PreviousPL" -> If[AssociationQ[old], N[old["PL"]], Missing[]],
      "PreviousRaisedBy" -> If[AssociationQ[old], Lookup[old, "RaisedBy", Missing[]], Missing[]]|>];
    If[StringQ[line], Quiet @ iWGAppendLine[FileNameJoin[{ls, "webguard", "conversation-resets.jsonl"}], line]]];
  <|"Reset" -> AssociationQ[old], "Known" -> AssociationQ[old],
    "PreviousPL" -> If[AssociationQ[old], N[old["PL"]], Missing[]]|>];
SourceVaultWebGuardConversationReset[___] := <|"Reset" -> False, "Known" -> False|>;

(* ------------------------------------------------------------
   W2 (文書 11 §5.2・§5.3、2026-11-12): 会話の機密の指紋と、依頼文・取得したページの URL の出所
   - 指紋: 高水位を LowRiskPL より上に上げる結果 (と、開始時に私的だった会話のプロンプト) から、人名 (敬称の前・
     メールアドレスの前・氏名欄)・番号 (4 桁以上、年を除く)・ID (英字と 3 桁以上の数字)・メールアドレス・辞書にない英字の語
     (4 文字以上) と、漢字・カタカナの 4〜8 文字の語を取り出し、会話ごとの塩つきハッシュで持つ (平文は持たない・記録しない)。
     モデルが組み立てた検索語・URL (出所なし) の語と照らし、一致した語が利用者の依頼文と公開の結果 (検索結果・取得した
     ページ) に出ていなければ一致とする。
   - 段 1 で強い一致 (人名・番号・ID・メールアドレス・英字の語) は承認。日本語の語だけの一致は、一般的な語と見分ける辞書が
     無いので既定では記録だけ (FingerprintTermAction)。段 2 ("Guard" の切替で段 2 でも判定するとき) は拒否。
     所有者が許可したホストへの取得は見ない。
   - 依頼文: claudecode が利用者の入力した部分だけを渡す (プロンプト全体には履歴・ノートブックの内容・モデルの過去の応答が
     入るので使わない)。依頼文の URL はそのまま取るなら出所あり (段 2 でも)。依頼文の語は指紋から除く。
   - ページのリンク: 取得したページの本文に出た URL。段 0 は出所あり、段 1 は選択の情報量 (log2 本数) の合計が
     PageLinkBits (既定 32 ビット) までなら出所あり、段 2 は出所なし (§5.4)。
   ------------------------------------------------------------ *)
$iWGFPMaxKeys = 300000;
$iWGAllowedMaxChars = 400000;
$iWGPublicCorpusMaxChars = 2000000;
$iWGSessionMaxLinks = 3000;
$iWGPageMaxLinks = 300;
$iWGReJa = "[\\p{Han}\\p{Katakana}\\x{30FC}]";
$iWGReEmail = "[a-z0-9._%+\\-]+@[a-z0-9\\-]+(?:\\.[a-z0-9\\-]+)*\\.[a-z]{2,}";
$iWGReURL = "https?://[^\\s<>\"'`\\x{3000}-\\x{30FF}\\x{4E00}-\\x{9FFF}\\x{FF00}-\\x{FFEF}]+";
$iWGHonorifics = {"准教授", "教授", "講師", "助教", "助手", "先生", "先輩", "さん", "さま", "様", "くん", "君", "ちゃん",
  "氏", "殿", "部長", "課長", "係長", "社長"};
$iWGNameLabels = {"氏名", "名前", "差出人", "送信者", "宛先", "宛名"};
(* 敬称の前に来ても人名ではない語・組織の語尾 *)
$iWGNameStop = {"学生", "生徒", "担当", "担当者", "社員", "職員", "教員", "皆", "皆様", "お客", "利用者", "受講生", "院生",
  "先生", "各位", "保護者", "参加者", "名誉", "特任", "客員", "専任", "主任", "非常勤", "本学", "当該", "同", "元", "前", "現"};
$iWGOrgSuffix = {"科", "部", "学", "課", "室", "局", "院", "所", "会", "社", "校", "系", "専攻", "センター", "研究室"};
(* 機密の結果に出ても指紋にしない英字の語 (技術用語・サービス名) *)
$iWGFPLatinStop = {"http", "https", "html", "json", "mailto", "wolfram", "mathematica", "github", "google", "python", "arxiv",
  "latex", "youtube", "amazon", "microsoft", "windows", "linux", "macos", "dropbox", "onedrive", "sharepoint", "outlook",
  "gmail", "zoom", "teams", "slack", "claude", "anthropic", "openai", "chatgpt", "sourcevault", "searxng", "lmstudio",
  "llama", "qwen", "gemma", "notebook", "unicode", "jpeg", "docx", "xlsx", "pptx", "wiki", "blog", "online"};
$iWGSuffixRules = {{"ies", "y"}, {"es", ""}, {"s", ""}, {"ed", ""}, {"ed", "e"}, {"ing", ""}, {"ing", "e"}, {"ly", ""},
  {"er", ""}, {"ers", ""}, {"est", ""}};
If[! AssociationQ[$iWGEnglishWords], $iWGEnglishWords = None];

(* JSON の \uXXXX (ツールの結果は JSON で返ることがある) を文字に戻してから NFKC・小文字にそろえる *)
iWGUnescapeU[s_String] := If[StringContainsQ[s, "\\u"],
  StringReplace[s, RegularExpression["\\\\u([0-9a-fA-F]{4})"] :> FromCharacterCode[FromDigits["$1", 16]]], s];
iWGFPNorm[s_String] := ToLowerCase @ Replace[Quiet @ Check[CharacterNormalize[iWGUnescapeU[s], "NFKC"], s], Except[_String] -> s];
iWGFPNorm[_] := "";
iWGFPHash[salt_String, key_String] := Hash[{salt, key}];
iWGFPClass[key_String] := Switch[StringTake[key, 1], "e", "Email", "n", "Number", "i", "ID", "w", "Word", "m", "Name",
  "t", "Term", _, "Other"];
iWGSubstrings[s_String, lo_Integer, hi_Integer] := Module[{n = StringLength[s]},
  Flatten @ Table[StringTake[s, {i, i + k - 1}], {k, lo, Min[hi, n]}, {i, 1, n - k + 1}]];
(* 英語の辞書 (DictionaryLookup、約 9 万語、初回だけ読む)。読めなければ英字の語の指紋は作らない *)
iWGEnglishWords[] := If[AssociationQ[$iWGEnglishWords], $iWGEnglishWords,
  $iWGEnglishWords = Module[{w = Quiet @ Check[DictionaryLookup[{"English", All}], {}], k},
    k = If[ListQ[w], DeleteDuplicates[ToLowerCase /@ Select[w, StringQ]], {}];
    AssociationThread[k, ConstantArray[True, Length[k]]]]];
iWGWordClassQ[] := Length[iWGEnglishWords[]] > 1000;
iWGDictWordQ[w_String] := With[{d = iWGEnglishWords[]},
  KeyExistsQ[d, w] || AnyTrue[$iWGSuffixRules,
    StringEndsQ[w, #[[1]]] && StringLength[w] > StringLength[#[[1]]] + 2 &&
      KeyExistsQ[d, StringDrop[w, -StringLength[#[[1]]]] <> #[[2]]] &]];
(* 人名の候補 (敬称の前などの漢字・カタカナの並び、空白で姓と名) から指紋の語を作る *)
iWGNameKeys[run0_String] := Module[{parts = StringSplit[run0, " "], run, n},
  run = StringJoin[parts]; n = StringLength[run];
  If[n < 2 || n > 5 || MemberQ[$iWGNameStop, run] || AnyTrue[$iWGOrgSuffix, StringEndsQ[run, #] &], Return[{}, Module]];
  Select[DeleteDuplicates @ Join[{run}, If[Length[parts] >= 2, parts, {}],
      If[n >= 3, {StringTake[run, 2], StringTake[run, -2]}, {}],
      If[n >= 4, {StringTake[run, 3], StringTake[run, -3]}, {}]],
    StringLength[#] >= 2 && ! MemberQ[$iWGNameStop, #] &]];
iWGNameKeys[_] := {};

(* 機密の結果から指紋の語 (種類の印つき) を取り出す。all = False なら日本語の語 (Term) を除く *)
iWGFPSecretKeys[text_String, all_] := Module[{t = iWGFPNorm[text], ja = $iWGReJa, emails, names, rest, nums, ids, words, terms},
  emails = DeleteDuplicates @ StringCases[t, RegularExpression[$iWGReEmail]];
  names = Join[
    StringCases[t, RegularExpression["(" <> ja <> "{2,8})(?:" <> StringRiffle[$iWGHonorifics, "|"] <> ")"] -> "$1"],
    StringCases[t, RegularExpression["(" <> ja <> "{1,4} ?" <> ja <> "{1,4})\\s*[<(\\[]?\\s*" <> $iWGReEmail] -> "$1"],
    StringCases[t, RegularExpression["(?:" <> StringRiffle[$iWGNameLabels, "|"] <> ")\\s*:?\\s*(" <> ja <> "{1,4} ?" <> ja <> "{1,4})"] -> "$1"]];
  names = DeleteDuplicates @ Flatten[iWGNameKeys /@ DeleteDuplicates[names]];
  rest = StringReplace[t, {RegularExpression[$iWGReURL] -> " ", RegularExpression[$iWGReEmail] -> " "}];
  nums = Select[DeleteDuplicates @ StringCases[rest, RegularExpression["(?<![0-9])[0-9]{4,}(?![0-9])"]],
    ! (StringLength[#] === 4 && StringMatchQ[#, RegularExpression["(19|20)[0-9][0-9]"]]) &];
  ids = Select[DeleteDuplicates @ StringCases[rest, RegularExpression["(?<![a-z0-9])[a-z0-9]{5,}(?![a-z0-9])"]],
    StringContainsQ[#, RegularExpression["[a-z]"]] && StringCount[#, DigitCharacter] >= 3 &];
  words = If[iWGWordClassQ[],
    Select[DeleteDuplicates @ StringCases[rest, RegularExpression["(?<![a-z])[a-z]{4,}(?![a-z])"]],
      ! MemberQ[$iWGFPLatinStop, #] && ! iWGDictWordQ[#] &], {}];
  terms = If[TrueQ[all],
    DeleteDuplicates @ Flatten[iWGSubstrings[StringTake[#, UpTo[40]], 4, 8] & /@
      DeleteDuplicates[StringCases[rest, RegularExpression[ja <> "{4,}"]]]], {}];
  DeleteDuplicates @ Join[("e|" <> #) & /@ emails, ("n|" <> #) & /@ nums, ("i|" <> #) & /@ ids,
    ("w|" <> #) & /@ words, ("m|" <> #) & /@ names, ("t|" <> #) & /@ terms]];
iWGFPSecretKeys[___] := {};

(* 検索語・URL から照合する語の候補 {種類, 語, 印つきの語} *)
iWGFPCandidates[target_String, isURL_] := Module[{t, ja = $iWGReJa, emails, rest, runs},
  t = If[TrueQ[isURL],
    iWGFPNorm[Replace[Quiet @ Check[URLDecode[target], target], Except[_String] -> target]], iWGFPNorm[target]];
  emails = DeleteDuplicates @ StringCases[t, RegularExpression[$iWGReEmail]];
  rest = StringReplace[t, RegularExpression[$iWGReEmail] -> " "];
  If[TrueQ[isURL], rest = StringReplace[rest, RegularExpression["[/?&=+.:#%_~;,!*'()\\[\\]@$\\-]"] -> " "]];
  runs = DeleteDuplicates @ StringCases[rest, RegularExpression[ja <> "{2,}"]];
  Join[
    {"Email", #, "e|" <> #} & /@ emails,
    {"Number", #, "n|" <> #} & /@ DeleteDuplicates[StringCases[rest, RegularExpression["(?<![0-9])[0-9]{4,}(?![0-9])"]]],
    {"ID", #, "i|" <> #} & /@ DeleteDuplicates[StringCases[rest, RegularExpression["(?<![a-z0-9])[a-z0-9]{5,}(?![a-z0-9])"]]],
    {"Word", #, "w|" <> #} & /@ DeleteDuplicates[StringCases[rest, RegularExpression["(?<![a-z])[a-z]{4,}(?![a-z])"]]],
    {"Name", #, "m|" <> #} & /@ DeleteDuplicates[Flatten[iWGSubstrings[StringTake[#, UpTo[40]], 2, 5] & /@ runs]],
    {"Term", #, "t|" <> #} & /@ DeleteDuplicates[Flatten[iWGSubstrings[StringTake[#, UpTo[40]], 4, 8] & /@ runs]]]];
iWGFPCandidates[___] := {};

iWGPublicTokenQ[tok_String, allowed_String] :=
  (allowed =!= "" && StringContainsQ[allowed, tok]) ||
  (StringQ[$iWGPublicCorpus] && $iWGPublicCorpus =!= "" && StringContainsQ[$iWGPublicCorpus, tok]);

(* 指紋との一致。<|Strong -> 種類ごとの数 (日本語の語を除く), Term -> 日本語の語の数, Classes|>。指紋が無ければ None *)
iWGFingerprintHits[sess_Association, target_String, kind_] := Module[
  {fp = Lookup[sess, "FP", <||>], salt = Lookup[sess, "FPSalt", None], allowed, hits, cls},
  If[! AssociationQ[fp] || Length[fp] === 0 || ! StringQ[salt], Return[None, Module]];
  hits = Select[iWGFPCandidates[target, kind === "Fetch"], KeyExistsQ[fp, iWGFPHash[salt, #[[3]]]] &];
  allowed = Lookup[sess, "Allowed", ""]; If[! StringQ[allowed], allowed = ""];
  hits = Select[hits, ! iWGPublicTokenQ[#[[2]], allowed] &];
  cls = If[hits === {}, {}, hits[[All, 1]]];
  (* V11: 一致した語 (日本語の語を除く) が出た資料の PL。HighPL = SearchTermMaxPL 以上の資料の語の数 *)
  With[{fppl = Replace[Lookup[sess, "FPPL", <||>], Except[_Association] -> <||>], cut = iWGPol["SearchTermMaxPL"]},
    With[{pls = Cases[Lookup[fppl, iWGFPHash[salt, #[[3]]] & /@ Select[hits, #[[1]] =!= "Term" &], Missing[]], _?NumericQ]},
      <|"Strong" -> Counts[DeleteCases[cls, "Term"]], "Term" -> Count[cls, "Term"], "Classes" -> Union[cls],
        "MaxPL" -> If[pls === {}, Missing["NotRecorded"], Max[pls]],
        "HighPL" -> If[NumericQ[cut], Count[pls, x_ /; x >= cut], 0]|>]]];
iWGFingerprintHits[___] := None;

iWGAppendCapped[base_String, add_String, max_Integer] := With[{x = If[base === "", add, base <> "\n" <> add]},
  If[StringLength[x] > max, StringTake[x, -max], x]];
(* 本文の URL の末尾の句読点・閉じ括弧を外す (括弧の対が合うものは残す) *)
iWGTrimURLTail[u0_String] := Module[{u = u0, changed = True},
  While[changed && StringLength[u] > 0,
    changed = False;
    Which[
      StringEndsQ[u, "." | "," | ";" | ":" | "!" | "?" | "'" | "\"" | "]" | "}" | ">" | "*"], u = StringDrop[u, -1]; changed = True,
      StringEndsQ[u, ")"] && StringCount[u, "("] < StringCount[u, ")"], u = StringDrop[u, -1]; changed = True]];
  u];
iWGExtractURLs[text_String] := DeleteDuplicates @ Select[
  iWGTrimURLTail /@ StringCases[text, RegularExpression["(?i)" <> $iWGReURL]],
  StringLength[#] >= 12 && StringLength[#] <= 4096 &];
iWGExtractURLs[_] := {};

(* ---- 文書 12 の 8.10 (2026-11-12): 文章が名指ししているホスト名 ----
   所有者の実機の試行 (no3): 依頼は「www.fukuui.ac.jp の沿革のページを開いて」。モデルはそのホストを一度も開かず、検索で見つけた
   別の大学のページで答えた。依頼文のホストは URL の形ではないので、依頼文の出所 (W2) にも、実在の確認 (V2) にも掛からなかった。
   ここでは、文章の中のホスト名を決まった規則で取り出す。取りこぼしより誤検出を避ける側に倒す (コードやファイル名を拾わない)。
   - URL (http/https) のホスト。
   - スキーム無しのドメイン名: www. で始まるもの (末尾は 2〜24 字の英字)、または下の語で終わるもの。
     .net .io .info .app .dev .ai .in .it などは、コードの属性参照 (self.net、logger.info) と区別できないので www. が要る。
   - 直前が英数字・_ ・@ (メールアドレス)・. ・/ ・\ ・- のものは拾わない。直後に英数字・_ ・- ・「.英数字」が続くものも拾わない。 *)
$iWGNamedHostTLDs = "com|org|edu|gov|jp|uk|de|fr|cn|kr|tw|au|nz|ca|eu|nl|ru|br";
$iWGReBareHost = "(?i)(?<![A-Za-z0-9_@./\\\\-])((?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+(?:" <> $iWGNamedHostTLDs <>
  "))(?![A-Za-z0-9_-]|\\.[A-Za-z0-9])";
$iWGReWWWHost = "(?i)(?<![A-Za-z0-9_@./\\\\-])(www\\.(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,24})(?![A-Za-z0-9_-]|\\.[A-Za-z0-9])";
iWGNamedHostClean[h_String] := StringTrim[ToLowerCase[StringTrim[h]], "."];
(* 照合用: 先頭の www. を外す *)
iWGNamedHostNorm[h_String] := With[{c = iWGNamedHostClean[h]}, If[StringStartsQ[c, "www."], StringDrop[c, 4], c]];
iWGNamedHostNorm[_] := "";
SourceVaultWebGuardNamedHosts[text_String] := Module[{hits = {}, t = StringTake[text, UpTo[20000]], urlHosts, bare},
  (* 出現位置つきで集め、書かれた順に並べる *)
  urlHosts = Function[u, With[{p = Quiet @ Check[URLParse[u], $Failed], pos = StringPosition[t, u, 1]},
      If[AssociationQ[p] && StringQ[Lookup[p, "Domain", None]] && pos =!= {}, {pos[[1, 1]], iWGNamedHostClean[p["Domain"]]}, Nothing]]] /@
    iWGExtractURLs[t];
  bare = Flatten[Function[re, MapThread[{#1[[1]], iWGNamedHostClean[#2]} &,
      {StringPosition[t, RegularExpression[re], Overlaps -> False], StringCases[t, RegularExpression[re]]}]] /@
    {$iWGReBareHost, $iWGReWWWHost}, 1];
  hits = SortBy[Join[urlHosts, bare], First];
  hits = Select[hits[[All, 2]], StringLength[#] >= 4 && StringLength[#] <= 253 && StringContainsQ[#, "."] &&
    StringMatchQ[#, RegularExpression["[a-z0-9]([a-z0-9.-]*[a-z0-9])?"]] &];
  Take[DeleteDuplicatesBy[hits, iWGNamedHostNorm], UpTo[8]]];
SourceVaultWebGuardNamedHosts[_] := {};

iWGSessionEnsure[s0_Association] := Module[{x = s0},
  If[! StringQ[Lookup[x, "FPSalt", None]], x["FPSalt"] = StringTake[StringDelete[CreateUUID[], "-"], 16]];
  If[! AssociationQ[Lookup[x, "FP", None]], x["FP"] = <||>];
  (* V11: 指紋の語ごとに、その語が出た資料の PL の最大 (SearchTermMaxPL 以上の資料の語は、検索エンジンにも送らない) *)
  If[! AssociationQ[Lookup[x, "FPPL", None]], x["FPPL"] = <||>];
  If[! StringQ[Lookup[x, "Allowed", None]], x["Allowed"] = ""];
  If[! AssociationQ[Lookup[x, "Links", None]], x["Links"] = <||>];
  If[! NumericQ[Lookup[x, "LinkBits", None]], x["LinkBits"] = 0.];
  If[! AssociationQ[Lookup[x, "LinkPicked", None]], x["LinkPicked"] = <||>];
  x];

SourceVaultWebGuardSessionNote[kind_String, text_String, opts_Association : <||>] := Module[
  {s = $SourceVaultWebGuardSession, add = 0, urls, links, fp, salt, keys, parent, pk, n},
  If[! AssociationQ[s], Return[<|"Noted" -> False, "Reason" -> "NoSession"|>, Module]];
  If[! MemberQ[{"Request", "Secret", "Public", "Page"}, kind], Return[<|"Noted" -> False, "Reason" -> "UnknownKind"|>, Module]];
  s = iWGSessionEnsure[s];
  Switch[kind,
    "Request",
      s["Allowed"] = iWGAppendCapped[s["Allowed"], iWGFPNorm[text], $iWGAllowedMaxChars];
      urls = iWGExtractURLs[text]; links = s["Links"];
      Scan[With[{k = iWGProvKey[#]},
        If[KeyExistsQ[links, k] || Length[links] < $iWGSessionMaxLinks, links[k] = <|"Origin" -> "Request"|>; add++]] &, urls];
      s["Links"] = links;
      (* 文書 12 の 8.10: 依頼文が名指ししたホスト (照合用の形)。実在しないときの断り文を、利用者の書いた名前として返すため *)
      s["RequestHosts"] = Take[DeleteDuplicates[Join[Replace[Lookup[s, "RequestHosts", {}], Except[_List] -> {}],
        iWGNamedHostNorm /@ SourceVaultWebGuardNamedHosts[text]]], UpTo[16]],
    "Secret",
      keys = iWGFPSecretKeys[text, Lookup[opts, "Classes", "All"] =!= "Strong"];
      fp = s["FP"]; salt = s["FPSalt"];
      Scan[If[Length[fp] < $iWGFPMaxKeys, fp[iWGFPHash[salt, #]] = iWGFPClass[#]; add++] &, keys];
      s["FP"] = fp;
      (* V11: 資料の PL (opts の "PL") を語ごとに覚える (最大を残す。PL の無い呼び出しは記録しない) *)
      With[{pl = Lookup[opts, "PL", None]},
        If[NumericQ[pl],
          s["FPPL"] = Fold[Function[{acc, k}, With[{h = iWGFPHash[salt, k]},
              If[KeyExistsQ[fp, h], Append[acc, h -> Max[N[pl], Lookup[acc, h, 0.]]], acc]]],
            Replace[Lookup[s, "FPPL", <||>], Except[_Association] -> <||>], keys]]],
    _,
      s["Allowed"] = iWGAppendCapped[s["Allowed"], iWGFPNorm[text], $iWGAllowedMaxChars];
      If[TrueQ[Lookup[opts, "Web", kind === "Page"]],
        $iWGPublicCorpus = iWGAppendCapped[If[StringQ[$iWGPublicCorpus], $iWGPublicCorpus, ""], iWGFPNorm[text],
          $iWGPublicCorpusMaxChars]];
      If[kind === "Page",
        parent = ToString @ Lookup[opts, "Parent", ""]; pk = iWGProvKey[parent];
        urls = Take[Select[iWGExtractURLs[text], iWGProvKey[#] =!= pk &], UpTo[$iWGPageMaxLinks]];
        n = Length[urls]; links = s["Links"];
        Scan[With[{k = iWGProvKey[#], e = Lookup[links, iWGProvKey[#], None]},
          Which[
            AssociationQ[e] && Lookup[e, "Origin", ""] === "Request", Null,
            AssociationQ[e], links[k] = Join[e, <|"Count" -> Max[n, Lookup[e, "Count", 0]]|>],
            Length[links] < $iWGSessionMaxLinks,
              links[k] = <|"Origin" -> "PageLink", "Parent" -> parent, "Count" -> n|>; add++]] &, urls];
        s["Links"] = links]];
  $SourceVaultWebGuardSession = s;
  <|"Noted" -> True, "Kind" -> kind, "Added" -> add|>];
SourceVaultWebGuardSessionNote[___] := <|"Noted" -> False, "Reason" -> "InvalidArguments"|>;

SourceVaultWebGuardSessionNoteToolResult[name_String, args_, text_String, obs_] := Module[
  {lo = N @ iWGPol["LowRiskPL"], url},
  If[! AssociationQ[$SourceVaultWebGuardSession] || StringTrim[text] === "", Return[<|"Noted" -> False|>, Module]];
  url = If[AssociationQ[args], ToString @ Lookup[args, "url", Lookup[args, "snapshotRef", ""]], ""];
  Which[
    ! NumericQ[obs] || obs > lo, SourceVaultWebGuardSessionNote["Secret", text, If[NumericQ[obs], <|"PL" -> N[obs]|>, <|"PL" -> 1.|>]],
    name === "sourcevault_get_document" && StringStartsQ[url, "http://" | "https://", IgnoreCase -> True],
      SourceVaultWebGuardSessionNote["Page", text, <|"Parent" -> url|>],
    name === "sourcevault_web_search", SourceVaultWebGuardSessionNote["Public", text, <|"Web" -> True|>],
    True, SourceVaultWebGuardSessionNote["Public", text]]];
SourceVaultWebGuardSessionNoteToolResult[___] := <|"Noted" -> False|>;

SourceVaultWebGuardSessionSummary[] := Module[{s = $SourceVaultWebGuardSession, fp, links},
  If[! AssociationQ[s], Return[<|"Session" -> None|>, Module]];
  fp = Lookup[s, "FP", <||>]; If[! AssociationQ[fp], fp = <||>];
  links = Lookup[s, "Links", <||>]; If[! AssociationQ[links], links = <||>];
  <|"PL" -> Lookup[s, "PL", Missing[]], "Stage" -> Lookup[SourceVaultWebGuardSessionStage[], "Stage", None],
    "FingerprintKeys" -> Length[fp], "FingerprintByClass" -> Counts[Values[fp]],
    "AllowedChars" -> StringLength[Replace[Lookup[s, "Allowed", ""], Except[_String] -> ""]],
    "Links" -> Counts[Lookup[#, "Origin", "?"] & /@ Values[links]],
    "LinkBitsUsed" -> Lookup[s, "LinkBits", 0.], "LinkBitsBudget" -> iWGPol["PageLinkBits"],
    "PublicCorpusChars" -> StringLength[Replace[$iWGPublicCorpus, Except[_String] -> ""]]|>];

(* 取得する URL の会話の中の出所 (依頼文・ページのリンク)。段 1 のページのリンクは選択の情報量の予算の範囲だけ *)
iWGSessionLinkOrigin[sess_Association, url_String, stage_] := Module[
  {links = Lookup[sess, "Links", <||>], k = iWGProvKey[url], e, cost, used, budget},
  If[! AssociationQ[links], Return[<|"From" -> None|>, Module]];
  e = Lookup[links, k, None];
  If[! AssociationQ[e], Return[<|"From" -> None|>, Module]];
  Switch[Lookup[e, "Origin", None],
    "Request", <|"From" -> "Request", "Key" -> k, "Cost" -> 0.|>,
    "PageLink",
      Which[
        stage === 2, <|"From" -> None, "Note" -> "PageLinkPrivateStage"|>,
        stage === 1,
          cost = If[KeyExistsQ[Replace[Lookup[sess, "LinkPicked", <||>], Except[_Association] -> <||>], k], 0.,
            N @ Log2[Max[2, Replace[Lookup[e, "Count", 2], Except[_Integer] -> 2]]]];
          used = Lookup[sess, "LinkBits", 0.]; If[! NumericQ[used], used = 0.];
          budget = iWGPol["PageLinkBits"]; If[! NumericQ[budget], budget = 32];
          If[used + cost > budget + 10^-9, <|"From" -> None, "Note" -> "PageLinkBudgetExceeded"|>,
            <|"From" -> "PageLink", "Key" -> k, "Cost" -> cost|>],
        True, <|"From" -> "PageLink", "Key" -> k, "Cost" -> 0.|>],
    _, <|"From" -> None|>]];
iWGSessionLinkOrigin[___] := <|"From" -> None|>;
iWGSessionChargeLink[link_Association] := Module[{s = $SourceVaultWebGuardSession, k = Lookup[link, "Key", None],
    c = Lookup[link, "Cost", 0.]},
  If[! AssociationQ[s] || ! StringQ[k], Return[Null, Module]];
  s = iWGSessionEnsure[s];
  s["LinkPicked"] = Append[s["LinkPicked"], k -> True];
  If[NumericQ[c] && c > 0, s["LinkBits"] = N[s["LinkBits"] + c]];
  $SourceVaultWebGuardSession = s;
  Null];

(* ------------------------------------------------------------
   主体 (Actor)
   ------------------------------------------------------------ *)
iWGModelActor[prov_, model_, client_] := With[{v = ToLowerCase[ToString[prov] <> "/" <> ToString[model]]},
  <|"Kind" -> "Model", "Id" -> iWGIdentifierId["Model", v], "Display" -> v,
    "Provider" -> ToString[prov], "Model" -> ToString[model], "ClientName" -> client|>];

(* I-01 (03 v0.4 §6.1、2026-11-09): 所有者かどうかは $SourceVaultPrincipal (5 つの束縛点だけが Block で設定、
   未束縛は Model) で決める。request の "Actor" -> <|"Type" -> "HumanUser"|> という自己申告は ClaimedType に
   残すだけで、主体 OwnerFE / OwnerCode が束縛されていなければ所有者にならない (02 v1.2 P0-12、付録 A の C1・C2)。 *)
iWGPrincipalKind[] := Module[{p},
  p = If[ValueQ[SourceVault`$SourceVaultPrincipal], SourceVault`$SourceVaultPrincipal, Missing[]];
  If[AssociationQ[p] && MemberQ[{"OwnerFE", "OwnerCode", "Service", "Model", "MCP"}, Lookup[p, "Kind", None]],
    p["Kind"], "Model"]];
iWGResolveActor[req_Association, ctx_Association] := Module[{a, type, prov, model, client, fresh, pk, base},
  a = Lookup[req, "Actor", <||>]; If[! AssociationQ[a], a = <||>];
  type = ToString @ Lookup[a, "Type", Lookup[a, "Kind", "Unknown"]];
  prov = Lookup[req, "Provider", Lookup[a, "Provider", Missing[]]];
  model = Lookup[req, "Model", Lookup[a, "Model", Missing[]]];
  client = Lookup[a, "ClientName", Missing[]];
  fresh = Lookup[ctx, "Freshest", Missing[]];
  pk = iWGPrincipalKind[];
  base = <|"Principal" -> pk, "ClaimedType" -> type|>;
  Join[Which[
    MemberQ[{"OwnerFE", "OwnerCode"}, pk],
      <|"Kind" -> "Owner", "Id" -> "ent-1", "Display" -> "Owner", "Provider" -> Missing[],
        "Model" -> Missing[], "ClientName" -> Missing[]|>,
    StringQ[prov] && StringQ[model] && model =!= "", iWGModelActor[prov, model, client],
    AssociationQ[fresh] && StringQ[Lookup[fresh, "Model", None]] && fresh["Model"] =!= "",
      iWGModelActor[Lookup[fresh, "Provider", "unknown"], fresh["Model"], client],
    pk === "Model" && ! (StringQ[client] && client =!= ""),
      (* claudecode の tool loop など: モデルの申告が無ければ「未申告のモデル」として記録する *)
      iWGModelActor["unknown", "undeclared", client],
    True,
      With[{cn = If[StringQ[client] && client =!= "", client, If[pk === "Service", "Service", "MCPClient"]]},
        <|"Kind" -> "MCPClient", "Id" -> iWGIdentifierId["MCPClient", ToLowerCase[cn]], "Display" -> cn,
          "Provider" -> Missing[], "Model" -> Missing[], "ClientName" -> cn|>]], base]];

(* ------------------------------------------------------------
   URL の出所 (W0、2026-11-11、文書 11 §5.0)
   検索結果に出た URL は検索事業者が返したもので、モデルが組み立てたものではない。符号化された部分
   (YouTube の v=…、Amazon の linkId=… など) に機密を載せる余地が無いので、そのまま取得するときは
   符号化の検査で止めない。モデルに残るのは「どれを選ぶか」の数ビットだけ。
   覚えるのはこのカーネルのメモリだけ (検索と取得は同じカーネルで行われる)。照合は完全一致
   (断片 #... を除き、スキームとホストだけ小文字)。モデルが引数を足したり書き換えたりした URL は出所なし。
   取得したページの中のリンクは覚えない (攻撃者のページに 256 本のリンクを並べれば、どれを取るかで
   1 回 8 ビット送れてしまう)。依頼文の URL も今回は覚えない (依頼に添付した機密文書の中の URL と
   区別できないため。W1/W2 の出所検査で扱う)。→ W2 (2026-11-12): 依頼文 (利用者が入力した部分だけ) とページのリンクは、
   会話 ($SourceVaultWebGuardSession) の中で覚える (SourceVaultWebGuardSessionNote・iWGSessionLinkOrigin)。
   ------------------------------------------------------------ *)
iWGProvKey[url_String] := Module[{u = StringTrim[url], m},
  u = StringReplace[u, "#" ~~ ___ ~~ EndOfString -> ""];
  m = StringCases[u, StartOfString ~~ sch : (LetterCharacter ~~ (WordCharacter | "+" | "." | "-") ...) ~~
      "://" ~~ auth : Except["/" | "?"] ... ~~ rest : ___ ~~ EndOfString :> {sch, auth, rest}, 1];
  If[m === {}, u, ToLowerCase[m[[1, 1]]] <> "://" <> ToLowerCase[m[[1, 2]]] <> m[[1, 3]]]];
iWGProvKey[_] := "";
iWGLowerDecoded[s_String] := ToLowerCase @ Replace[Quiet @ Check[URLDecode[s], s], Except[_String] -> s];
iWGProvPrune[now_] := Module[{ttl = $SourceVaultWebGuardProvenanceTTLSeconds, mx = $SourceVaultWebGuardProvenanceMaxURLs},
  If[! NumericQ[ttl], ttl = 7200]; If[! IntegerQ[mx] || mx < 0, mx = 5000];
  $iWGProvenance = Select[$iWGProvenance, AssociationQ[#] && NumericQ[#["At"]] && now - #["At"] <= ttl &];
  If[Length[$iWGProvenance] > mx, $iWGProvenance = Take[SortBy[$iWGProvenance, #["At"] &], -mx]];
  Length[$iWGProvenance]];

SourceVaultWebGuardNoteURLs[urls_List, source_String, opts_Association : <||>] := Module[
  {now = AbsoluteTime[], toks, n = 0, skipped = 0, k, src},
  src = StringReplace[source, Except[WordCharacter] -> ""];
  If[src === "", src = "Noted"];
  If[! AssociationQ[$iWGProvenance], $iWGProvenance = <||>];
  toks = Select[
    StringTrim[#, Except[WordCharacter] ..] & /@ StringSplit[ToLowerCase[ToString @ Lookup[opts, "Query", ""]]],
    StringLength[#] >= 8 &];
  Scan[Function[u,
    If[StringQ[u] && StringLength[u] <= 4096 && StringStartsQ[u, "http://" | "https://", IgnoreCase -> True],
      k = iWGProvKey[u];
      If[toks =!= {} && With[{d = iWGLowerDecoded[k]}, AnyTrue[toks, StringContainsQ[d, #] &]],
        skipped++,
        (* V11 (文書 12 の 8.18 節): 機密の語を含む検索の結果の URL は、その印を持つ (取得を止めはしない。記録して数えるため) *)
        $iWGProvenance[k] = If[TrueQ[Lookup[opts, "PrivateTerms", False]],
          <|"Source" -> src, "At" -> now, "PrivateTerms" -> True|>, <|"Source" -> src, "At" -> now|>]; n++]]],
    urls];
  <|"Noted" -> n, "SkippedEchoesQuery" -> skipped, "Size" -> iWGProvPrune[now]|>];
SourceVaultWebGuardNoteURLs[url_String, source_String, opts_Association : <||>] :=
  SourceVaultWebGuardNoteURLs[{url}, source, opts];
SourceVaultWebGuardNoteURLs[___] := <|"Noted" -> 0, "SkippedEchoesQuery" -> 0, "Size" -> Length[$iWGProvenance]|>;

SourceVaultWebGuardURLProvenance[url_String] := Module[{e, ttl = $SourceVaultWebGuardProvenanceTTLSeconds},
  If[! NumericQ[ttl], ttl = 7200];
  e = If[AssociationQ[$iWGProvenance], Lookup[$iWGProvenance, iWGProvKey[url], Missing[]], Missing[]];
  If[AssociationQ[e] && NumericQ[e["At"]] && AbsoluteTime[] - e["At"] <= ttl && StringQ[e["Source"]], e["Source"], None]];
SourceVaultWebGuardURLProvenance[] := Module[{now = AbsoluteTime[]},
  If[! AssociationQ[$iWGProvenance], $iWGProvenance = <||>];
  iWGProvPrune[now];
  <|"Size" -> Length[$iWGProvenance], "BySource" -> Counts[Lookup[Values[$iWGProvenance], "Source", "?"]],
    "TTLSeconds" -> $SourceVaultWebGuardProvenanceTTLSeconds, "MaxURLs" -> $SourceVaultWebGuardProvenanceMaxURLs|>];
SourceVaultWebGuardURLProvenance[_] := None;
(* V11: この URL が、機密の語を含む検索の結果に出たものか (有効時間の内だけ) *)
iWGProvPrivateTermsQ[url_String] := Module[{e, ttl = $SourceVaultWebGuardProvenanceTTLSeconds},
  If[! NumericQ[ttl], ttl = 7200];
  e = If[AssociationQ[$iWGProvenance], Lookup[$iWGProvenance, iWGProvKey[url], Missing[]], Missing[]];
  AssociationQ[e] && NumericQ[e["At"]] && AbsoluteTime[] - e["At"] <= ttl && TrueQ[Lookup[e, "PrivateTerms", False]]];
iWGProvPrivateTermsQ[_] := False;

(* ------------------------------------------------------------
   V4 (文書 12 §3.3 の L3、2026-11-13): 行き先の評判
   ------------------------------------------------------------
   取得の前に、行き先のホストと URL を手元のリストと照らす。所有者には尋ねない (文書 12 の P5)。
   - 既定で使うのは、手元に取り込んだリストだけ (照合のために外へ出るものは無い):
       OpenPhish の公開フィード (フィッシングの URL)、JPCERT/CC の phishurl-list (月ごとの CSV)、Tranco の上位サイト表 (正の手がかり)。
     abuse.ch (URLhaus・ThreatFox) の一括ファイルは配布が終わっている (410。Auth-Key つきの API だけ) ので入れていない。
   - フィルタ付きの DNS は Quad9 を使う (2026-11-13 の所有者の決定。$SourceVaultWebReputationDNSFilter)。初めてのホストの名前が
     Quad9 に出る。リストで決まらず、良好でもなく、名前に符号化らしい部分が無いホストだけを問い合わせる。
   - 評価: Malicious (URL がリストにある・ホストが 2 つ以上のリストにある・DNS フィルタが遮断)、Suspicious (ホストが 1 つのリストにある)、
     Good (所有者が許可・公知ホスト表・実績が十分・上位サイト表)、Neutral (それ以外)。
   - URL のリストから作ったホストの一致は、そのホストが広く使われる場 (上位サイト表・公知ホスト表・共有の場の表) そのものなら数えない
     (docs.google.com のページ 1 つがフィッシングでも、docs.google.com 全体は止めない)。URL そのものの一致は数える。
   - 検証器が使える (Verifier "OK") = 止める側のリストが 1 つ以上、期限内で入っている (または DNS フィルタを使っている)。
     使えないときは、それを理由に段 0 の取得を止めない。段 1 以上では、実績の無いホストを確かめられないものとして扱う (文書 12 の P7)。
   - 更新は SourceVaultWebReputationUpdate (所有者か service)。service の定期処理が、期限切れのものを 1 回に 1 つずつ取り直す。
     取りに行く先は設定に書いた固定の URL だけで、こちらからは何も送らない。 *)
If[! AssociationQ[$SourceVaultWebReputationSources],
  $SourceVaultWebReputationSources = <|
    "OpenPhish" -> <|"Kind" -> "Block", "Format" -> "URLLines", "Enabled" -> True,
      "URL" -> "https://raw.githubusercontent.com/openphish/public_feed/refs/heads/main/feed.txt",
      "MaxAgeHours" -> 72, "MinIntervalSeconds" -> 3600, "MaxBytes" -> 5*^6, "MinCount" -> 10|>,
    "JPCERT" -> <|"Kind" -> "Block", "Format" -> "MonthlyCSV", "Enabled" -> True,
      "URL" -> "https://raw.githubusercontent.com/JPCERTCC/phishurl-list/main/`1`/`1``2`.csv", "Months" -> 3,
      "MaxAgeHours" -> 24*45, "MinIntervalSeconds" -> 86400, "MaxBytes" -> 2*^7, "MinCount" -> 10|>,
    "Tranco" -> <|"Kind" -> "Trust", "Format" -> "RankZip", "Enabled" -> True,
      "URL" -> "https://tranco-list.eu/top-1m.csv.zip", "Top" -> 100000,
      "MaxAgeHours" -> 24*30, "MinIntervalSeconds" -> 86400, "MaxBytes" -> 4*^7, "MinCount" -> 1000|>|>];
(* 2026-11-13 (所有者の決定、文書 12 の 12 章の 3 の (b)): フィルタ付きの DNS に Quad9 を使う。手元のリストはフィッシングだけで薄い。
   使わないときは None (試験は読み込みの前に None を入れる: 試験からホスト名を外へ出さない) *)
If[! ValueQ[$SourceVaultWebReputationDNSFilter], $SourceVaultWebReputationDNSFilter = "Quad9"];
(* 設定を書き換えると、リストの取得先や検証の有無が変わる。代入は承認の対象。更新は所有者か service だけ *)
If[Length[DownValues[NBAccess`NBRegisterApprovalSetSymbols]] > 0,
  Quiet @ NBAccess`NBRegisterApprovalSetSymbols[{"$SourceVaultWebReputationSources", "$SourceVaultWebReputationDNSFilter", "$iWGRep"}]];
If[Length[DownValues[NBAccess`NBRegisterApprovalHeads]] > 0,
  Quiet @ NBAccess`NBRegisterApprovalHeads[{"SourceVaultWebReputationUpdate"}]];
(* 多くの利用者が中身を置ける場。ここそのものがリストに載っても、ホスト全体は止めない。ここの下のホストは、上位サイト表の親を理由に良好としない *)
$iWGSharedPlatforms = {"github.io", "gitlab.io", "blogspot.com", "wordpress.com", "weebly.com", "wixsite.com", "web.app", "firebaseapp.com",
  "vercel.app", "netlify.app", "pages.dev", "workers.dev", "r2.dev", "herokuapp.com", "glitch.me", "replit.dev", "azurewebsites.net",
  "amazonaws.com", "cloudfront.net", "sites.google.com", "docs.google.com", "drive.google.com", "forms.gle", "dropbox.com",
  "sharepoint.com", "notion.site", "ipfs.io", "bit.ly", "tinyurl.com", "t.co", "sharemyhtml.com"};
iWGRepDir[] := iWGSub[iWGLocalStateDir[], "webguard", "reputation"];
iWGRepFile[name_String] := With[{d = iWGRepDir[]}, If[StringQ[d], FileNameJoin[{d, name <> ".json"}], $Failed]];
iWGRepSources[] := Select[If[AssociationQ[$SourceVaultWebReputationSources], $SourceVaultWebReputationSources, <||>], AssociationQ];
iWGRepEnabled[] := Select[iWGRepSources[], TrueQ[Lookup[#, "Enabled", False]] &];

(* ---- リストの読み方 ---- *)
iWGRepHostOfURL[u_String] := With[{p = Quiet @ Check[URLParse[u], $Failed]},
  If[AssociationQ[p] && StringQ[Lookup[p, "Domain", None]], iWGNormHost[p["Domain"]], ""]];
iWGRepValidHostQ[h_String] := StringLength[h] >= 4 && StringLength[h] <= 253 && StringContainsQ[h, "."] &&
  StringMatchQ[h, RegularExpression["[a-z0-9]([a-z0-9.-]*[a-z0-9])?"]];
iWGRepValidHostQ[_] := False;
(* 1 行に 1 つの URL *)
iWGRepParseURLLines[text_String] := Module[{urls},
  urls = Select[StringTrim /@ StringSplit[text, {"\r\n", "\n", "\r"}], StringStartsQ[#, "http://" | "https://", IgnoreCase -> True] &];
  <|"Hosts" -> Select[DeleteDuplicates[iWGRepHostOfURL /@ urls], iWGRepValidHostQ],
    "URLs" -> DeleteCases[DeleteDuplicates[iWGProvKey /@ urls], ""]|>];
(* 日付,URL,説明 の CSV (JPCERT/CC)。URL の列だけを使う *)
iWGRepParseDatedCSV[text_String] := iWGRepParseURLLines[StringRiffle[
  Flatten[StringCases[#, RegularExpression["^[^,]*,\\s*\"?(https?://[^\\s\",]+)"] -> "$1", 1] & /@
    StringSplit[text, {"\r\n", "\n", "\r"}]], "\n"]];
(* 順位,ドメイン の CSV (Tranco)。上位 top 件 *)
iWGRepParseRankCSV[text_String, top_Integer] := Module[{lines},
  lines = Take[StringSplit[text, {"\r\n", "\n", "\r"}], UpTo[top]];
  <|"Hosts" -> Select[DeleteDuplicates[
      iWGNormHost /@ Flatten[StringCases[#, RegularExpression["^\\s*\\d+\\s*,\\s*([A-Za-z0-9.-]+)\\s*$"] -> "$1", 1] & /@ lines]],
      iWGRepValidHostQ], "URLs" -> {}|>];

(* ---- 取得 (試験では iWGRepHTTPGet を差し替える)。こちらからは何も送らない ---- *)
iWGRepHTTPGet[url_String, maxBytes_] := Module[{r},
  r = Quiet @ Check[TimeConstrained[URLRead[HTTPRequest[url], {"StatusCode", "BodyByteArray"}, TimeConstraint -> 60], 90, $TimedOut], $Failed];
  Which[
    r === $TimedOut, Failure["ReputationFetchTimeout", <|"URL" -> url|>],
    ! AssociationQ[r], Failure["ReputationFetchFailed", <|"URL" -> url|>],
    Lookup[r, "StatusCode", 0] =!= 200, Failure["ReputationHTTPStatus", <|"URL" -> url, "StatusCode" -> Lookup[r, "StatusCode", 0]|>],
    ! ByteArrayQ[Lookup[r, "BodyByteArray", None]], Failure["ReputationNoBody", <|"URL" -> url|>],
    NumericQ[maxBytes] && Length[r["BodyByteArray"]] > maxBytes,
      Failure["ReputationTooLarge", <|"URL" -> url, "Bytes" -> Length[r["BodyByteArray"]]|>],
    True, r["BodyByteArray"]]];
iWGRepText[b_ByteArray] := Quiet @ Check[ByteArrayToString[b, "UTF-8"], Quiet @ Check[ByteArrayToString[b, "ISO8859-1"], ""]];
iWGRepText[_] := "";
iWGRepFetchSource[name_String, cfg_Association] := Module[
  {fmt = Lookup[cfg, "Format", ""], url = Lookup[cfg, "URL", ""], maxB = Lookup[cfg, "MaxBytes", 2*^7], b, parts = {}, got = 0, d, zip, dir, csv, txt},
  Switch[fmt,
    "URLLines",
      b = iWGRepHTTPGet[url, maxB];
      If[FailureQ[b], b, iWGRepParseURLLines[iWGRepText[b]]],
    "MonthlyCSV",
      (* 今月から 8 か月前まで遡り、取れた月を Months 個まで集める (最新の月はまだ無いことがある) *)
      Do[
        If[got >= Lookup[cfg, "Months", 3], Break[]];
        d = DatePlus[DateObject[Now, "Month"], {-k, "Month"}];
        b = iWGRepHTTPGet[StringTemplate[url][DateString[d, "Year"], DateString[d, "Month"]], maxB];
        If[ByteArrayQ[b], AppendTo[parts, iWGRepParseDatedCSV[iWGRepText[b]]]; got++],
        {k, 0, 8}];
      If[parts === {}, Failure["ReputationFetchFailed", <|"URL" -> url, "Detail" -> "no monthly file could be read"|>],
        <|"Hosts" -> DeleteDuplicates[Join @@ Lookup[parts, "Hosts"]], "URLs" -> DeleteDuplicates[Join @@ Lookup[parts, "URLs"]]|>],
    "RankZip",
      b = iWGRepHTTPGet[url, maxB];
      If[FailureQ[b], b,
        dir = FileNameJoin[{$TemporaryDirectory, "svrep_" <> StringDelete[CreateUUID[], "-"]}];
        zip = FileNameJoin[{dir, "list.zip"}];
        Quiet @ CreateDirectory[dir, CreateIntermediateDirectories -> True];
        txt = Quiet @ Check[
          BinaryWrite[zip, b]; Close[zip];
          csv = Select[Flatten[{ExtractArchive[zip, dir]}], StringQ[#] && StringEndsQ[#, ".csv", IgnoreCase -> True] &];
          If[csv === {}, $Failed, iWGRepText[ReadByteArray[First[csv]]]], $Failed];
        Quiet @ DeleteDirectory[dir, DeleteContents -> True];
        If[! StringQ[txt], Failure["ReputationArchiveUnreadable", <|"URL" -> url|>],
          iWGRepParseRankCSV[txt, Replace[Lookup[cfg, "Top", 100000], Except[_Integer?Positive] -> 100000]]]],
    _, Failure["ReputationUnknownFormat", <|"Source" -> name, "Format" -> fmt|>]]];

(* ---- 手元の置き場と、メモリへの読み込み ---- *)
If[! AssociationQ[$iWGRep], $iWGRep = <|"Sets" -> <||>, "Files" -> <||>, "CheckedAbs" -> 0.|>];
(* 文字列のリスト -> 所属を引くための Association *)
iWGRepSet[l_List] := With[{k = DeleteDuplicates[Select[l, StringQ]]}, AssociationThread[k, ConstantArray[True, Length[k]]]];
iWGRepSet[_] := <||>;
iWGRepLoad[] :=Module[{now = AbsoluteTime[], dir = iWGRepDir[], sets, files, f, fd, j},
  If[now - Lookup[$iWGRep, "CheckedAbs", 0.] < 60, Return[Lookup[$iWGRep, "Sets", <||>], Module]];
  sets = Lookup[$iWGRep, "Sets", <||>]; files = Lookup[$iWGRep, "Files", <||>];
  If[! StringQ[dir], $iWGRep = <|"Sets" -> <||>, "Files" -> <||>, "CheckedAbs" -> now|>; Return[<||>, Module]];
  Scan[Function[name,
      f = iWGRepFile[name];
      (* 変わったかどうかは、更新時刻と大きさで見る (時刻は 1 秒刻みのことがある) *)
      fd = If[StringQ[f] && FileExistsQ[f], Quiet @ Check[{AbsoluteTime[FileDate[f]], FileByteCount[f]}, None], None];
      Which[
        fd === None, sets = KeyDrop[sets, name]; files = KeyDrop[files, name],
        Lookup[files, name, None] =!= fd,
          j = iWGReadJSON[f];
          If[AssociationQ[j],
            sets[name] = <|"Kind" -> ToString @ Lookup[j, "Kind", "Block"],
              "Hosts" -> iWGRepSet[Lookup[j, "Hosts", {}]], "URLs" -> iWGRepSet[Lookup[j, "URLs", {}]],
              "FetchedAbs" -> Replace[iWGIsoToAbs[ToString @ Lookup[j, "FetchedAtUTC", ""]], Except[_?NumericQ] -> 0.],
              "FetchedAtUTC" -> Lookup[j, "FetchedAtUTC", Missing[]], "Count" -> Lookup[j, "Count", 0]|>;
            files[name] = fd,
            sets = KeyDrop[sets, name]; files = KeyDrop[files, name]]]],
    Keys[iWGRepSources[]]];
  $iWGRep = <|"Sets" -> sets, "Files" -> files, "CheckedAbs" -> now|>;
  sets];
iWGRepFreshQ[set_, cfg_Association] := AssociationQ[set] && NumericQ[Lookup[set, "FetchedAbs", None]] &&
  AbsoluteTime[] - set["FetchedAbs"] <= 3600. Replace[Lookup[cfg, "MaxAgeHours", 72], Except[_?NumericQ] -> 72];
iWGRepDNSFilterName[] := With[{f = $SourceVaultWebReputationDNSFilter}, If[MemberQ[{"Quad9", "Cloudflare"}, f], f, None]];

SourceVaultWebReputationStatus[] := Module[{sets = iWGRepLoad[], src = iWGRepSources[], rows, blockOK, dnsOK, dns = iWGRepDNSFilterName[]},
  rows = KeyValueMap[Function[{name, cfg}, With[{s = Lookup[sets, name, None]},
      <|"Source" -> name, "Kind" -> Lookup[cfg, "Kind", "Block"], "Enabled" -> TrueQ[Lookup[cfg, "Enabled", False]],
        "Installed" -> AssociationQ[s], "Count" -> If[AssociationQ[s], Lookup[s, "Count", 0], 0],
        "FetchedAtUTC" -> If[AssociationQ[s], Lookup[s, "FetchedAtUTC", Missing[]], Missing["NotInstalled"]],
        "AgeHours" -> If[AssociationQ[s] && NumericQ[s["FetchedAbs"]] && s["FetchedAbs"] > 0, Round[(AbsoluteTime[] - s["FetchedAbs"])/3600., 0.1], Missing[]],
        "Fresh" -> (TrueQ[Lookup[cfg, "Enabled", False]] && iWGRepFreshQ[s, cfg])|>]], src];
  blockOK = AnyTrue[rows, #["Kind"] === "Block" && TrueQ[#["Fresh"]] &];
  (* フィルタ付きの DNS は、届いているときだけ検証器として数える *)
  dnsOK = StringQ[dns] && TrueQ[Quiet @ Check[iWGDNSFilterWorksQ[], False]];
  <|"Verifier" -> If[blockOK || dnsOK, "OK", "Unavailable"],
    "Reason" -> Which[blockOK, "ListsFresh", dnsOK, "DNSFilterOnly",
      AnyTrue[rows, #["Kind"] === "Block" && TrueQ[#["Installed"]] &], "ListsStale", True, "ListsNotInstalled"],
    "DNSFilter" -> dns, "DNSFilterReachable" -> If[StringQ[dns], dnsOK, Missing["NotUsed"]], "Sources" -> rows, "Directory" -> iWGRepDir[]|>];

(* ---- 更新 (所有者か service)。既定は期限切れのものだけ。"MaxSources" で 1 回に取り直す数を絞れる ---- *)
Options[SourceVaultWebReputationUpdate] = {"Sources" -> All, "Force" -> False, "MaxSources" -> Infinity};
If[! AssociationQ[$iWGRepAttempt], $iWGRepAttempt = <||>];
SourceVaultWebReputationUpdate[OptionsPattern[]] := Module[
  {pk = iWGPrincipalKind[], src = iWGRepEnabled[], want = OptionValue["Sources"], force = TrueQ[OptionValue["Force"]],
   maxN = OptionValue["MaxSources"], sets, updated = {}, skipped = {}, failed = {}, done = 0, cfg, old, last, r, n, f},
  If[! MemberQ[{"OwnerFE", "OwnerCode", "Service"}, pk],
    Return[Failure["WebGuardNotAuthorized", <|"Function" -> "SourceVaultWebReputationUpdate", "Principal" -> pk,
      "MessageTemplate" -> "SourceVaultWebReputationUpdate may be called only by the owner or the service; the current principal is `1`. From the front end use SourceVaultIntegrityOwnerAction[SourceVaultWebReputationUpdate[]].",
      "MessageParameters" -> {pk}|>]]];
  If[! StringQ[iWGRepDir[]], Return[Failure["NoLocalState", <|"Function" -> "SourceVaultWebReputationUpdate"|>]]];
  If[ListQ[want], src = KeyTake[src, want]];
  $iWGRep = Append[If[AssociationQ[$iWGRep], $iWGRep, <||>], "CheckedAbs" -> 0.];
  sets = iWGRepLoad[];
  Scan[Function[name,
      cfg = src[name]; old = Lookup[sets, name, None]; last = Lookup[$iWGRepAttempt, name, 0.];
      Which[
        done >= maxN, AppendTo[skipped, <|"Source" -> name, "Reason" -> "Later"|>],
        ! force && iWGRepFreshQ[old, cfg] &&
            AbsoluteTime[] - old["FetchedAbs"] < 0.5*3600. Replace[Lookup[cfg, "MaxAgeHours", 72], Except[_?NumericQ] -> 72],
          AppendTo[skipped, <|"Source" -> name, "Reason" -> "Fresh"|>],
        ! force && AbsoluteTime[] - last < Replace[Lookup[cfg, "MinIntervalSeconds", 3600], Except[_?NumericQ] -> 3600],
          AppendTo[skipped, <|"Source" -> name, "Reason" -> "TriedRecently"|>],
        True,
          $iWGRepAttempt[name] = AbsoluteTime[]; done++;
          r = Quiet @ Check[iWGRepFetchSource[name, cfg], Failure["ReputationFetchError", <|"Source" -> name|>]];
          n = If[AssociationQ[r], Length[Lookup[r, "Hosts", {}]] + Length[Lookup[r, "URLs", {}]], 0];
          Which[
            FailureQ[r], AppendTo[failed, <|"Source" -> name, "Reason" -> ToString[First[r]]|>],
            ! AssociationQ[r] || n < Replace[Lookup[cfg, "MinCount", 10], Except[_?NumericQ] -> 10],
              (* 中身が少なすぎる = 配布元の形式が変わったか、別のものが返った。前のリストを残す *)
              AppendTo[failed, <|"Source" -> name, "Reason" -> "TooFewEntries", "Count" -> n|>],
            True,
              f = iWGWriteJSON[iWGRepFile[name], <|"Source" -> name, "Kind" -> Lookup[cfg, "Kind", "Block"],
                "FetchedAtUTC" -> iWGNowIso[], "Machine" -> iWGMachineTag[], "Count" -> n,
                "Hosts" -> Lookup[r, "Hosts", {}], "URLs" -> Lookup[r, "URLs", {}]|>];
              If[f === $Failed, AppendTo[failed, <|"Source" -> name, "Reason" -> "WriteFailed"|>],
                AppendTo[updated, <|"Source" -> name, "Count" -> n|>]]]]],
    Keys[src]];
  (* 書き直したリストは、次の照合で必ず読み直す *)
  $iWGRep = <|"Sets" -> <||>, "Files" -> <||>, "CheckedAbs" -> 0.|>;
  <|"Updated" -> updated, "Skipped" -> skipped, "Failed" -> failed, "Status" -> KeyDrop[SourceVaultWebReputationStatus[], "Sources"]|>];

(* ---- フィルタ付きの DNS (所有者が選んだときだけ)。ホスト名がその事業者に出る。試験では iWGDNSFilterOnce を差し替える ---- *)
$iWGDNSFilterServers = <|"Quad9" -> "9.9.9.9", "Cloudflare" -> "1.1.1.2"|>;
If[! AssociationQ[$iWGDNSFilterCache], $iWGDNSFilterCache = <||>];
iWGDNSFilterOnce[host_String, server_String] := Module[{r, out, ips},
  r = Quiet @ Check[TimeConstrained[RunProcess[{"nslookup", "-timeout=3", "-retry=1", host <> ".", server}], 12, $TimedOut], $Failed];
  If[! AssociationQ[r], Return["Unavailable", Module]];
  out = ToString @ Lookup[r, "StandardOutput", ""] <> "\n" <> ToString @ Lookup[r, "StandardError", ""];
  (* 応答にある IP アドレスのうち、問い合わせ先自身のものを除く *)
  ips = DeleteCases[StringCases[out, RegularExpression["(?<![0-9A-Fa-f:.])((?:\\d{1,3}\\.){3}\\d{1,3}|(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4})(?![0-9A-Fa-f:.])"]],
    server | "2620:fe::fe" | "2620:fe::9" | "2606:4700:4700::1112" | "2606:4700:4700::1002" | "1.0.0.2"];
  Which[
    ips =!= {} && AllTrue[ips, MatchQ[#, "0.0.0.0" | "::"] &], "Blocked",     (* Cloudflare は遮断を 0.0.0.0 で返す *)
    ips =!= {}, "Clean",
    StringContainsQ[out, "Non-existent domain" | "NXDOMAIN", IgnoreCase -> True], "Blocked",   (* Quad9 は遮断を NXDOMAIN で返す *)
    True, "Unavailable"]];
(* フィルタ付きの DNS に届くか (外向きの DNS を止めている回線がある)。既知の名前 (example.com) が引けるかで見る。10 分覚える。
   届かない間は、検証器として数えず (SourceVaultWebReputationStatus)、ホスト名も送らない *)
If[! ListQ[$iWGDNSFilterState], $iWGDNSFilterState = {None, 0., False}];
iWGDNSFilterWorksQ[] := Module[{name = iWGRepDNSFilterName[], now = AbsoluteTime[], ok},
  If[! StringQ[name], Return[False, Module]];
  If[$iWGDNSFilterState[[1]] === name && now - $iWGDNSFilterState[[2]] < 600,
    Return[TrueQ[$iWGDNSFilterState[[3]]], Module]];
  ok = Quiet @ Check[iWGDNSFilterOnce["example.com", $iWGDNSFilterServers[name]], "Unavailable"] === "Clean";
  $iWGDNSFilterState = {name, now, ok};
  If[! ok, Quiet @ iWGRepPublish["DNSFilterUnreachable",
    "フィルタ付きの DNS (" <> name <> ") に届きません (外向きの DNS が止められている回線かもしれません)。その間は、行き先の検査は手元のリストだけで行います。",
    <|"DNSFilter" -> name|>]];
  ok];
iWGDNSFilter[host_String] := Module[{name = iWGRepDNSFilterName[], now = AbsoluteTime[], c, st},
  If[! StringQ[name], Return["Off", Module]];
  If[! iWGDNSFilterWorksQ[], Return["Unavailable", Module]];
  c = Lookup[$iWGDNSFilterCache, host, None];
  If[ListQ[c] && now - c[[2]] < If[c[[1]] === "Unavailable", 60, 3600], Return[c[[1]], Module]];
  st = Quiet @ Check[iWGDNSFilterOnce[host, $iWGDNSFilterServers[name]], "Unavailable"];
  If[! MemberQ[{"Blocked", "Clean", "Unavailable"}, st], st = "Unavailable"];
  If[Length[$iWGDNSFilterCache] > 2000, $iWGDNSFilterCache = <||>];
  $iWGDNSFilterCache[host] = {st, now};
  st];

(* ---- 照合 ---- *)
(* ホストと、その親のドメイン (ラベル 2 つまで) *)
iWGRepChain[host_String] := With[{labels = StringSplit[host, "."]},
  If[Length[labels] < 2, {host}, Table[StringRiffle[Drop[labels, k], "."], {k, 0, Length[labels] - 2}]]];
iWGRepTrustSet[sets_Association] := With[{t = Select[sets, Lookup[#, "Kind", ""] === "Trust" &]},
  If[Length[t] === 0, <||>, Lookup[First[t], "Hosts", <||>]]];
(* リストの 1 項目が、広く使われる場そのものか *)
iWGRepBroadQ[entry_String, trust_Association] := KeyExistsQ[trust, entry] || MemberQ[$iWGSharedPlatforms, entry] ||
  (AssociationQ[$SourceVaultWebGuardBuiltinHosts] && KeyExistsQ[$SourceVaultWebGuardBuiltinHosts, entry]);
(* 既知のホストに 1 文字違いの名前か。返すのは似ている相手 (無ければ None)。比べるのはラベルの数をそろえた末尾で、
   違うラベルは 1 つだけ・長さ 5 以上・編集距離 1 *)
If[! ListQ[$iWGLookalikeRefs], $iWGLookalikeRefs = {{}, 0.}];
iWGLookalikeRefs[] := Module[{now = AbsoluteTime[], refs, stats},
  If[now - $iWGLookalikeRefs[[2]] < 600, Return[$iWGLookalikeRefs[[1]], Module]];
  iWGProfilesEnsureFresh[];
  stats = Quiet @ Check[iWGStats[]["Hosts"], <||>]; If[! AssociationQ[stats], stats = <||>];
  refs = DeleteDuplicates @ Join[
    If[AssociationQ[$SourceVaultWebGuardBuiltinHosts], Keys[$SourceVaultWebGuardBuiltinHosts], {}],
    Keys @ Select[If[AssociationQ[$iWGProfiles], $iWGProfiles, <||>], AssociationQ[#] && Lookup[#, "TrustStatus", ""] === "Approved" &],
    Keys @ Select[stats, AssociationQ[#] && TrueQ[Lookup[#, "AccessCount", 0] >= iWGPol["EstablishedCount"]] &]];
  refs = Select[refs, StringQ[#] && StringCount[#, "."] >= 1 &];
  $iWGLookalikeRefs = {refs, now};
  refs];
iWGLookalikeOf[host_String, refs_List] := Module[{hl = StringSplit[host, "."], hit},
  hit = SelectFirst[refs, Function[r, Module[{rl = StringSplit[r, "."], cl, diff},
      If[Length[hl] < Length[rl], False,
        cl = Take[hl, -Length[rl]];
        diff = Flatten @ Position[MapThread[UnsameQ, {cl, rl}], True];
        Length[diff] === 1 && StringLength[cl[[First[diff]]]] >= 5 && StringLength[rl[[First[diff]]]] >= 5 &&
          EditDistance[cl[[First[diff]]], rl[[First[diff]]]] === 1]]], None];
  If[StringQ[hit], hit, None]];
iWGLookalikeOf[___] := None;

(* 行き先の評価。url は無くてもよい (ホストだけ)。prof は関所のホストの見方 (iWGHostView) *)
iWGRepRate[url_, hostIn_String, prof_Association, dnsOK_ : False] := Module[
  {host = iWGNormHost[hostIn], sets = iWGRepLoad[], trust, chain, st, listed = {}, urlListed = {}, key, trustWhy = {}, dns = "Off",
   status, rating, look = None, ignored = {}},
  trust = iWGRepTrustSet[sets];
  chain = iWGRepChain[host];
  st = SourceVaultWebReputationStatus[];
  key = If[StringQ[url] && url =!= "", iWGProvKey[url], ""];
  KeyValueMap[Function[{name, s},
      If[Lookup[s, "Kind", ""] === "Block" && TrueQ[Lookup[Lookup[iWGRepSources[], name, <||>], "Enabled", False]],
        If[key =!= "" && KeyExistsQ[s["URLs"], key], AppendTo[urlListed, name]];
        If[AnyTrue[chain, KeyExistsQ[s["Hosts"], #] && ! iWGRepBroadQ[#, trust] &], AppendTo[listed, name]]]], sets];
  status = ToString @ Lookup[prof, "TrustStatus", "Observed"];
  trustWhy = Join[
    If[status === "Approved", {"Approved"}, {}],
    If[NumericQ[Lookup[prof, "Builtin", Missing[]]], {"KnownHosts"}, {}],
    If[TrueQ[Lookup[prof, "Established", False]], {"Established"}, {}],
    (* 上位サイト表: ホストそのもの、または共有の場でない親 *)
    If[KeyExistsQ[trust, host] || AnyTrue[Rest[chain], KeyExistsQ[trust, #] && ! MemberQ[$iWGSharedPlatforms, #] &], {"TopSites"}, {}]];
  (* フィルタ付きの DNS は、所有者が選んでいて、リストで決まらず、良好でもないホストだけに問い合わせる *)
  If[TrueQ[dnsOK] && urlListed === {} && listed === {} && trustWhy === {} && StringQ[iWGRepDNSFilterName[]] && iWGRepValidHostQ[host],
    (* 問い合わせるのは URL に書かれたホスト名。Quad9 は遮断を「存在しない」で返すので、ふつうの名前解決でも引けない名前は
       遮断とは数えない (実在の確認 L1 が「実在しない」と答える) *)
    With[{raw = If[StringQ[url] && url =!= "", iWGRawHost[url, host], host]},
      dns = iWGDNSFilter[raw];
      If[dns === "Blocked" && Quiet @ Check[iWGHostResolve[raw], "Unavailable"] === "NotExist", dns = "NotExist"]]];
  (* V7 (文書 12 の 7.1 節「遮断の解除」): 所有者が、リストに載っていることを承知のうえで許可したホストは、ホスト単位の掲載では
     止めない (掲載の事実は ListedIgnored に残す)。URL そのものが載っているページは止める *)
  If[TrueQ[Lookup[prof, "ListOverride", False]] && listed =!= {}, ignored = listed; listed = {}];
  rating = Which[
    urlListed =!= {} || Length[listed] >= 2 || dns === "Blocked", "Malicious",
    Length[listed] === 1, "Suspicious",
    trustWhy =!= {}, "Good",
    True, "Neutral"];
  If[rating === "Neutral", look = iWGLookalikeOf[host, DeleteCases[iWGLookalikeRefs[], host]]];
  <|"Host" -> host, "Rating" -> rating, "Listed" -> listed, "URLListed" -> urlListed, "Trust" -> trustWhy,
    "DNSFilter" -> dns, "Lookalike" -> look, "Verifier" -> st["Verifier"], "VerifierReason" -> st["Reason"],
    "ListedIgnored" -> ignored|>];
SourceVaultWebReputation[target_String] := Module[{t = StringTrim[target], url, host},
  url = If[StringStartsQ[t, "http://" | "https://", IgnoreCase -> True], t, None];
  host = If[StringQ[url], iWGRepHostOfURL[url], iWGNormHost[t]];
  If[host === "", Return[Failure["ReputationNoHost", <|"Target" -> target|>]]];
  (* フィルタ付きの DNS に問い合わせるのは、所有者が呼んだときだけ (ホスト名が外に出る。モデルが作ったホスト名を出す口にしない) *)
  iWGRepRate[url, host, iWGHostView[host], MemberQ[{"OwnerFE", "OwnerCode"}, iWGPrincipalKind[]]]];
SourceVaultWebReputation[___] := Failure["ReputationNoHost", <||>];

(* 検証器が使えないことを、所有者に知らせる (SystemDoctor。6 時間に 1 回まで) *)
If[! AssociationQ[$iWGRepWarned], $iWGRepWarned = <||>];
iWGRepPublish[rc_String, summary_String, payload_Association] := Module[{now = AbsoluteTime[], prior = Lookup[$iWGRepWarned, rc, None]},
  If[NumericQ[prior] && now - prior < 21600, Return[<|"Published" -> False, "Reason" -> "Suppressed"|>]];
  $iWGRepWarned[rc] = now;
  If[Length[DownValues[SourceVault`SourceVaultDiagnosticsPublish]] === 0, Return[<|"Published" -> False, "Reason" -> "DiagnosticsAbsent"|>]];
  Quiet @ Check[
    SourceVault`SourceVaultDiagnosticsPublish[<|"Type" -> "DiagnosticsEvent", "EventId" -> CreateUUID[],
      "EventClass" -> "WebReputation", "Producer" -> "webguard", "Component" -> "WebGuard",
      "ReasonCode" -> rc, "Severity" -> "Medium", "Health" -> "Degraded", "IssueRequested" -> True,
      "PrivacyLevel" -> 0.0, "Summary" -> summary, "Payload" -> payload|>],
    <|"Published" -> False, "Reason" -> "PublishFailed"|>]];

(* ------------------------------------------------------------
   判定表 (spec §8, 純関数)
   ------------------------------------------------------------ *)
iWGDec[d_, r_, reasons_, level_: Missing[]] :=
  <|"Decision" -> d, "Reason" -> r, "Reasons" -> reasons, "Level" -> level|>;

SourceVaultWebGuardDecide[spec_Association] := Module[{kind, ctx, an, prof, cls, status, level, seen, est, reasons, pii, approved, builtin, from,
    rep, rating, verify, stop, look},
  kind = ToString @ Lookup[spec, "Kind", "Fetch"];
  ctx = Lookup[spec, "ContextPL", $SourceVaultWebGuardUnknownContextPL];
  If[! NumericQ[ctx], ctx = $SourceVaultWebGuardUnknownContextPL]; ctx = N[ctx];
  an = Lookup[spec, "Analysis", <||>]; If[! AssociationQ[an], an = <||>];
  cls = ToString @ Lookup[an, "Class", "Plain"];
  reasons = Replace[Lookup[an, "Reasons", {}], Except[_List] -> {}];
  pii = Replace[Lookup[an, "PIIHints", {}], Except[_List] -> {}];
  If[kind === "Search",
    (* V7 (文書 12 の 3.3 節): 検索語も、所有者に個別には尋ねない ("SearchDecision" が "Verify")。止めて理由を返す。
       繰り返し止まった分は、方針の提案に回る (7.2 節)。"Ask" は以前の動き *)
    With[{sstop = If[iWGPol["SearchDecision"] =!= "Ask", "Deny", "Ask"]},
      Return @ Which[
        cls === "Exfil", iWGDec[sstop, "ExfilShapedQuery", reasons],
        ctx <= iWGPol["LowRiskPL"], iWGDec["Allow", "LowRiskContext", reasons],
        cls === "Opaque", iWGDec[sstop, "OpaqueQueryWithContext", reasons],
        (* V11: 個人を特定する情報 (メールアドレス・電話番号) は、迷惑メールの判定で最初に検索する語でもある。検索エンジンだけに
           送る既定 (PrivateStageSearch "EnginesOnly") では止めない (送り先は関所が SearchEngines に絞る)。"Deny" では以前どおり *)
        ctx >= iWGPol["PrivatePL"] && pii =!= {} && iWGPol["PrivateStageSearch"] === "Deny",
          iWGDec[sstop, "PIIInQueryWithPrivateContext", Join[reasons, pii]],
        True, iWGDec["Allow", "Policy", reasons]]]];
  prof = Lookup[spec, "Profile", <||>]; If[! AssociationQ[prof], prof = <||>];
  status = ToString @ Lookup[prof, "TrustStatus", "Observed"];
  level = Lookup[prof, "EffectiveLevel", Lookup[prof, "AccessLevel", iWGPol["DefaultHostLevel"]]];
  If[! NumericQ[level], level = iWGPol["DefaultHostLevel"]]; level = N[level];
  seen = TrueQ[Lookup[prof, "AccessCount", 0] > 0];
  est = TrueQ @ Lookup[prof, "Established", False];
  (* W0 (2026-11-11、文書 11 §5.0、所有者の最優先: 不自然な符号化の URL をホワイト以外のサイトへ送らせない)。
     ホワイト = 所有者が許可したホスト (TrustStatus Approved) と公知ホスト表 (Builtin)。符号化 (Opaque) の URL を無条件に許すのは
     所有者が許可したホストだけ。公知ホスト表は接尾辞一致で広い (ac.jp・go.jp・google.com など、利用者が中身を置けるホストを含む)
     ので、そこへの Opaque は従来どおり文脈 PL ≤ 信用度なら許可、それ以外は承認。それ以外のホスト (自動の推定で信用度が上がった
     ものを含む) への Opaque は、文脈 PL によらず承認 (私的な文脈なら拒否)、Exfil 形は拒否。以前は「一度アクセスしたことがある」
     ホストへの Opaque を文脈 PL ≤ 信用度で許可していたので、普通の URL で一度取得させてから符号化した URL を送らせる 2 段の
     手口が通り得た。Plain (自然な文字列) の判定は変えない。 *)
  approved = status === "Approved";
  builtin = NumericQ[Lookup[prof, "Builtin", Missing[]]];
  (* URL の出所 (SourceVaultWebGuardNoteURLs): 検索結果に出た URL をそのまま取るなら、符号化や文脈 PL に
     よらず許可 (止めるのは所有者が止めたホストだけ)。URL の中身はモデルが作ったものではない。 *)
  from = Lookup[spec, "Provenance", None];
  If[! StringQ[from] || from === "", from = None];
  (* V4 (文書 12 §3.3、2026-11-13): 行き先の評価 (Check が iWGRepRate で作って渡す。無ければ評価なし) と、判定の方式。
     "Verify" (既定) では、以前所有者に尋ねていた取得を、行き先の評価と会話の段で決める。尋ねない代わりに、止めるときは
     理由と次の手段を返す (文面は iWGReasonText・iWGNextSteps)。"Ask" は以前の動き。
     評判のリストに載ったホスト・URL は、どちらの方式でも、出所 (検索結果・依頼文) があっても止める。 *)
  rep = Lookup[spec, "Reputation", <||>]; If[! AssociationQ[rep], rep = <||>];
  rating = If[iWGPol["Reputation"] === False, "Neutral", ToString @ Lookup[rep, "Rating", "Neutral"]];
  verify = iWGPol["FetchDecision"] =!= "Ask";
  stop = If[verify, "Deny", "Ask"];
  look = Lookup[rep, "Lookalike", None];
  Which[
    status === "Blocked", iWGDec["Deny", "HostBlocked", reasons, level],
    rating === "Malicious",
      iWGDec["Deny", Which[Lookup[rep, "URLListed", {}] =!= {}, "URLListedMalicious",
        Lookup[rep, "DNSFilter", ""] === "Blocked" && Lookup[rep, "Listed", {}] === {}, "HostBlockedByDNSFilter",
        True, "HostListedMalicious"], Join[reasons, ("Listed:" <> #) & /@ Join[Lookup[rep, "URLListed", {}], Lookup[rep, "Listed", {}]]], level],
    rating === "Suspicious",
      iWGDec["Deny", "HostListedSuspicious", Join[reasons, ("Listed:" <> #) & /@ Lookup[rep, "Listed", {}]], level],
    from =!= None, iWGDec["Allow", "From" <> from, Append[reasons, "URLFrom" <> from], level],
    cls === "Exfil" && (approved || builtin), iWGDec[stop, "ExfilShapedURL", reasons, level],
    cls === "Exfil", iWGDec["Deny", "ExfilShapedURLToUntrustedHost", reasons, level],
    cls === "Opaque" && approved, iWGDec["Allow", "OpaqueOnApprovedHost", reasons, level],
    cls === "Opaque" && ! builtin,
      If[ctx >= iWGPol["PrivatePL"],
        iWGDec["Deny", "OpaqueURLToUntrustedHostWithPrivateContext", reasons, level],
        iWGDec[stop, If[seen, "OpaqueURLToUntrustedHost", "OpaqueOnNewHost"], reasons, level]],
    (* モデルが組み立てた URL のホストが、既知のホストの 1 文字違い (良好なホストには付かない) *)
    verify && StringQ[look], iWGDec["Deny", "HostLooksLikeKnownHost", Append[reasons, "LooksLike:" <> look], level],
    ctx <= level,
      If[cls === "Opaque" && ! seen,
        iWGDec[stop, "OpaqueOnNewHost", reasons, level],
        iWGDec["Allow", "WithinHostLevel", reasons, level]],
    (* ここから下は、会話の文脈 PL がホストの信用度を超えている (段 1 以上の会話で、信用度の低いホスト) *)
    ! verify && ! seen, iWGDec["Ask", "NewHostWithPrivateContext", reasons, level],
    cls === "Opaque", iWGDec[stop, "OpaqueWithPrivateContext", reasons, level],
    ! verify && ! est, iWGDec["Ask", "UnestablishedHostWithPrivateContext", reasons, level],
    est, iWGDec["Allow", "AboveLevelEstablished", Append[reasons, "AboveLevelEstablished"], level],
    (* 所有者が許可したホストでも、許可した水準より上の文脈からは送らない *)
    approved, iWGDec["Deny", "ContextAboveApprovedLevel", reasons, level],
    (* 段 2 (機密を読んだ会話): 出所のある URL と、所有者がその水準まで許可したホストだけ *)
    ctx >= iWGPol["PrivatePL"], iWGDec["Deny", "PrivateSessionURLWithoutProvenance", reasons, level],
    (* 段 1: 良好なホストは通す。実績の無いホストは、検証器が使えるときだけ通して記録する *)
    rating === "Good", iWGDec["Allow", "GoodHostRecorded", Append[reasons, "Good:" <> StringRiffle[Lookup[rep, "Trust", {}], "+"]], level],
    Lookup[rep, "Verifier", "Unavailable"] =!= "OK",
      iWGDec["Deny", "DestinationUnverified", Append[reasons, "Verifier:" <> ToString @ Lookup[rep, "VerifierReason", "Unavailable"]], level],
    True, iWGDec["Allow", "NeutralHostRecorded", Append[reasons, "NeutralHost"], level]]];

(* ------------------------------------------------------------
   承認 queue / ticket (spec §9.3)
   ------------------------------------------------------------ *)
$iWGDecisions = {"AllowOnce", "AllowHost", "Deny", "BlockHost"};
iWGSignature[kind_, target_, actorId_] :=
  StringTake[iWGHex[ToString[kind] <> "|" <> ToString[target] <> "|" <> ToString[actorId]], 24];
iWGNewRequestId[] := "wg-" <> StringTake[StringDelete[CreateUUID[], "-"], 12];

iWGWritePending[req_Association] := Module[{dir = iWGPendingDir[], existing, id, rec},
  If[! StringQ[dir], Return[Failure["NoLocalState", <||>]]];
  existing = SelectFirst[SourceVaultWebGuardPendingRequests[],
    Lookup[#, "Signature", ""] === Lookup[req, "Signature", "-"] &, Missing[]];
  If[AssociationQ[existing], Return[existing]];
  id = iWGNewRequestId[];
  rec = Join[req, <|"RequestId" -> id, "CreatedAtUTC" -> iWGNowIso[], "Machine" -> iWGMachineTag[],
    "Pid" -> $ProcessID|>];
  If[iWGWriteJSON[FileNameJoin[{dir, id <> ".json"}], rec] === $Failed,
    Return[Failure["PendingWriteFailed", <|"RequestId" -> id|>]]];
  rec];

SourceVaultWebGuardPendingRequests[] := Module[
  {dir = iWGPendingDir[], ddir = iWGDecisionsDir[], files, now = AbsoluteTime[], ttl = $SourceVaultWebGuardPendingTTLSeconds},
  If[! StringQ[dir] || ! DirectoryQ[dir], Return[{}]];
  files = FileNames["wg-*.json", dir];
  SortBy[
    Select[Map[Function[f, Module[{r = iWGReadJSON[f], a, decided},
        If[! AssociationQ[r], Nothing,
          a = iWGIsoToAbs[ToString @ Lookup[r, "CreatedAtUTC", ""]];
          decided = StringQ[ddir] && FileExistsQ[FileNameJoin[{ddir, ToString @ Lookup[r, "RequestId", "?"] <> ".json"}]];
          If[! NumericQ[a] || now - a > ttl || decided, Nothing,
            Append[iWGFixNull[r], "AgeSeconds" -> Round[now - a]]]]]], files],
      AssociationQ],
    ToString @ Lookup[#, "CreatedAtUTC", ""] &]];

iWGApplyHostDecision[host_String, decision_String, ctxPL_, levelOpt_] :=
  If[host =!= "" && host =!= "websearch",
    Switch[decision,
      "AllowHost",
        SourceVaultWebHostSetAccess[host,
          If[NumericQ[levelOpt], levelOpt,
            Max[N @ iWGPol["PrivatePL"], If[NumericQ[ctxPL], N[ctxPL], 0.]]],
          "TrustStatus" -> "Approved", "PolicySource" -> "Owner"],
      "BlockHost", SourceVaultWebHostBlock[host],
      _, Null],
    Null];

Options[SourceVaultWebGuardResolveRequest] = {"Level" -> Automatic, "Note" -> Missing[]};
SourceVaultWebGuardResolveRequest[id_String, decision_String, OptionsPattern[]] := Module[
  {dir = iWGPendingDir[], ddir = iWGDecisionsDir[], req, rec, host},
  If[! MemberQ[$iWGDecisions, decision],
    Return[Failure["InvalidDecision", <|"Decision" -> decision, "Allowed" -> $iWGDecisions|>]]];
  req = If[StringQ[dir], iWGReadJSON[FileNameJoin[{dir, id <> ".json"}]], $Failed];
  If[! AssociationQ[req], Return[Failure["RequestNotFound", <|"RequestId" -> id|>]]];
  req = iWGFixNull[req];
  host = ToString @ Lookup[req, "Host", ""];
  (* V8 (文書 12 の 7.3 節): 判断の文脈 (尋ねてから答えるまでの秒数、見せた材料の digest) を、判断の記録に残す *)
  Block[{$iWGDecisionContext = <|"Via" -> "Dialog", "Ref" -> id,
      "Seconds" -> With[{a = iWGIsoToAbs[ToString @ Lookup[req, "CreatedAtUTC", ""]]}, If[NumericQ[a], Round[AbsoluteTime[] - a], -1]],
      "MaterialDigest" -> iWGDigest[KeyTake[req, {"Kind", "Host", "Reason", "Reasons", "ContextPL", "HostCheck", "Provenance", "SessionStage", "Profile"}]]|>},
    iWGApplyHostDecision[host, decision, Lookup[req, "ContextPL", Missing[]], OptionValue["Level"]];
    (* 1 回限りの許可・拒否は、ホストの設定を変えないので、ここで記録する。検索語は対象の名前を持たない *)
    If[MemberQ[{"AllowOnce", "Deny"}, decision] || host === "" || host === "websearch",
      Quiet @ Check[iWGNoteOwnerDecision[Join[
        <|"Action" -> decision, "Direction" -> Switch[decision, "AllowOnce" | "AllowHost", "Loosen", _, "Tighten"],
          "TargetKind" -> If[Lookup[req, "Kind", ""] === "Search", "Search", "Host"],
          "Target" -> If[Lookup[req, "Kind", ""] === "Search", "websearch", host], "Persistent" -> False|>,
        $iWGDecisionContext]], Null]]];
  rec = <|"RequestId" -> id, "Signature" -> Lookup[req, "Signature", ""], "Decision" -> decision,
    "DecidedAtUTC" -> iWGNowIso[], "Consumed" -> False, "Host" -> host,
    "Kind" -> Lookup[req, "Kind", ""], "Note" -> OptionValue["Note"], "Machine" -> iWGMachineTag[]|>;
  If[StringQ[ddir], iWGWriteJSON[FileNameJoin[{ddir, id <> ".json"}], rec]];
  iWGAppendLog[<|"Kind" -> Lookup[req, "Kind", ""], "Url" -> Lookup[req, "Url", Missing[]],
    "Host" -> host, "Query" -> Lookup[req, "Query", Missing[]],
    "ActorId" -> Lookup[Lookup[req, "Actor", <||>], "Id", Missing[]],
    "ActorKind" -> Lookup[Lookup[req, "Actor", <||>], "Kind", Missing[]],
    "ActorDisplay" -> Lookup[Lookup[req, "Actor", <||>], "Display", Missing[]],
    "ContextPL" -> Lookup[req, "ContextPL", Missing[]],
    "Class" -> Lookup[req, "Class", Missing[]], "Suspicion" -> Lookup[req, "Suspicion", Missing[]],
    "Decision" -> "OwnerDecided", "DecisionBy" -> "Owner", "DecisionDetail" -> decision,
    "DecisionReason" -> Lookup[req, "Reason", Missing[]], "RequestId" -> id|>];
  rec];

iWGFindTicket[sig_String] := Module[
  {ddir = iWGDecisionsDir[], files, now = AbsoluteTime[], ttl = $SourceVaultWebGuardPendingTTLSeconds, hits},
  If[! StringQ[ddir] || ! DirectoryQ[ddir], Return[Missing["NoTicket"]]];
  files = FileNames["wg-*.json", ddir];
  hits = Select[Map[Function[f, Module[{r = iWGReadJSON[f], a},
      If[! AssociationQ[r] || Lookup[r, "Signature", ""] =!= sig || TrueQ[Lookup[r, "Consumed", False]], Nothing,
        a = iWGIsoToAbs[ToString @ Lookup[r, "DecidedAtUTC", ""]];
        If[! NumericQ[a] || now - a > ttl, Nothing, Append[iWGFixNull[r], "Path" -> f]]]]], files],
    AssociationQ];
  If[hits === {}, Missing["NoTicket"], Last[SortBy[hits, ToString @ Lookup[#, "DecidedAtUTC", ""] &]]]];
iWGConsumeTicket[t_Association] :=
  If[StringQ[Lookup[t, "Path", None]],
    Quiet @ iWGWriteJSON[t["Path"], Append[KeyDrop[t, "Path"], "Consumed" -> True]], Null];

(* 期限切れ (24h) の pending / decision file を掃く *)
iWGHousekeep[] := Module[{now = AbsoluteTime[]},
  Scan[Function[dir,
    If[StringQ[dir] && DirectoryQ[dir],
      Scan[Function[f, With[{mt = Quiet @ Check[AbsoluteTime[FileDate[f, "Modification"]], now]},
         If[now - mt > 86400, Quiet @ DeleteFile[f]]]], FileNames["wg-*.json", dir]]]],
    {iWGPendingDir[], iWGDecisionsDir[]}]];

(* ------------------------------------------------------------
   問い合わせ (prompter) spec §9
   ------------------------------------------------------------ *)
iWGPromptDecision[req_Association] := Module[{p = $SourceVaultWebGuardPrompter},
  Which[
    p === "Queue", "Queue",
    p === "Deny", "Deny",
    p === Automatic, If[TrueQ[$Notebooks], iWGDialogPrompt[req], "Queue"],
    True, With[{r = Quiet @ Check[p[req], "Deny"]}, If[MemberQ[Append[$iWGDecisions, "Queue"], r], r, "Deny"]]]];

(* 所有者が読む窓に出す理由の文 (モデル向けの英文は iWGReasonText)。関所が出しうる理由コードのすべてに 1 文を持つ *)
iWGReasonTextJa[code_String, kind_String] := Switch[code,
  "NewHostWithPrivateContext", "このホストは初めてで、この会話は公開でない資料を読んでいます",
  "UnestablishedHostWithPrivateContext", "このホストは利用の実績が少なく、この会話は公開でない資料を読んでいます",
  "OpaqueOnNewHost", "URL に符号化らしい文字列があり、このホストは初めてです",
  "OpaqueURLToUntrustedHost", "URL に符号化らしい文字列があり、このホストは信頼済みではありません",
  "OpaqueWithPrivateContext", "URL に符号化らしい文字列があり、この会話は公開でない資料を読んでいます",
  "ExfilShapedURL", "URL に長い符号化文字列が含まれています",
  "ExfilShapedQuery", "検索語が、語ではなく符号化されたデータのように見えます",
  "OpaqueQueryWithContext", "検索語に符号化らしい文字列があり、この会話は公開でない資料を読んでいます",
  "PIIInQueryWithPrivateContext", "検索語に個人を特定する情報 (メールアドレスや長い番号) らしいものがあり、この会話は機密を読んでいます",
  "SecretFingerprintMatch",
    If[kind === "Search", "検索語", "URL"] <> " に、この会話が読んだ機密にしか出てこない名前・番号・ID が含まれています",
  "HostDoesNotExist", "このホストは実在しません (DNS で引けません)",
  "HostBlocked", "このホストは所有者が遮断しています",
  "URLListedMalicious", "この URL は、フィッシングやマルウェアのページのリストに載っています",
  "HostListedMalicious", "このホストは、フィッシングやマルウェアのサイトのリストの 2 つ以上に載っています",
  "HostListedSuspicious", "このホストは、フィッシングやマルウェアのサイトのリストに載っています",
  "HostBlockedByDNSFilter", "フィルタ付きの DNS が、このホストを悪性として遮断しています",
  "HostLooksLikeKnownHost", "このホストは、既知のホストと 1 文字違いで、利用の実績がありません",
  "DestinationUnverified", "この会話は公開でない資料を読んでいて、ホストに実績が無く、評判のリストが未取得か期限切れです",
  "ContextAboveApprovedLevel", "所有者がこのホストに許可した水準より、この会話が読んだ資料の機密度が上です",
  "ExfilShapedURLToUntrustedHost", "URL に長い符号化文字列があり、ホストは信頼済みではありません",
  "OpaqueURLToUntrustedHostWithPrivateContext", "URL に符号化らしい文字列があり、ホストは信頼済みでなく、この会話は機密を読んでいます",
  "PrivateSessionNoExternalSearch", "この会話は機密を読んだので、ここで組み立てた検索語は外へ出しません",
  "PrivateRecordTermInSearch", "検索語に、所有者が責任を持つ人の記録 (成績・健康など、PL の高い資料) にだけ出てくる語が含まれています",
  "PrivateSessionURLWithoutProvenance", "この会話は機密を読んだので、取得できるのは依頼文か検索結果にそのまま出た URL だけです",
  _, "関所の規則 " <> code <> " に当たります"];
iWGReasonTextJa[___] := "関所の規則に当たります";
iWGHostCheckLabel[hc_] := Switch[hc,
  "Exists", "確認済み (DNS で引ける)",
  "Unavailable", "確かめられなかった (名前解決が使えない)",
  "NotExist", "実在しない",
  _, "確かめていない (許可済み・実績あり・出所ありのいずれか)"];
iWGProvenanceLabel[from_] := Switch[from,
  "SearchResult", "検索結果にそのまま出た URL",
  "Request", "依頼文にそのまま出た URL",
  "PageLink", "取得したページのリンク",
  _String, from,
  _, "モデルが組み立てた (依頼文・検索結果に無い)"];
(* 窓の中身 (上から順の行)。ChoiceDialog と分けてあるのは、FE なしでも中身を試験できるようにするため *)
iWGDialogItems[req_Association] := Module[{kind, host, target, reasons, prof, actor, ctx},
  kind = ToString @ Lookup[req, "Kind", "Fetch"];
  host = ToString @ Lookup[req, "Host", ""];
  target = ToString @ If[kind === "Search", Lookup[req, "Query", ""], Lookup[req, "Url", ""]];
  reasons = Replace[Lookup[req, "Reasons", {}], Except[_List] -> {}];
  prof = Lookup[req, "Profile", <||>]; If[! AssociationQ[prof], prof = <||>];
  actor = Lookup[req, "Actor", <||>]; If[! AssociationQ[actor], actor = <||>];
  ctx = Lookup[req, "ContextPL", Missing[]];
  {
    Style["LLM の Web アクセス確認", Bold, 13, RGBColor[0.75, 0.3, 0.1]],
    Row[{"主体: ", Style[ToString @ Lookup[actor, "Display", "?"], Bold],
      "    文脈 PL: ", Style[ToString[ctx], Bold],
      "    種別: ", If[kind === "Search", "検索 (SearXNG 中継)", "URL 取得"]}],
    If[kind === "Fetch", Row[{"ホスト: ", Style[host, Bold, 12]}], Nothing],
    Pane[Style[target, 10, LineBreakWithin -> True], {540, Automatic}],
    If[reasons =!= {},
      Column[Style["理由: " <> ToString[#], 10, RGBColor[0.7, 0.1, 0.1]] & /@ reasons], Nothing],
    (* V2 (文書 12 の 1.2 節 #6・5 章): 判断の材料。理由は文で出し、コードは添えるだけにする *)
    Row[{"尋ねている理由: ", Style[iWGReasonTextJa[ToString @ Lookup[req, "Reason", ""], kind], Bold]}],
    If[kind === "Fetch",
      Row[{"ホストの実在: ", Style[iWGHostCheckLabel[Lookup[req, "HostCheck", Missing[]]], Bold]}], Nothing],
    If[kind === "Fetch",
      Row[{"URL の出所: ", Style[iWGProvenanceLabel[Lookup[req, "Provenance", Missing[]]], Bold]}], Nothing],
    If[IntegerQ[Lookup[req, "SessionStage", None]],
      Row[{"会話の段: ", ToString[req["SessionStage"]],
        Switch[req["SessionStage"], 0, " (機密を読んでいない)", 1, " (内部の資料を読んだ)", _, " (機密を読んだ)"]}],
      Nothing],
    Row[{"規則: ", ToString @ Lookup[req, "Reason", ""],
      If[StringQ[Lookup[req, "RequestId", None]], "   request " <> req["RequestId"], ""]}],
    If[kind === "Fetch",
      Row[{"実績: ", ToString @ Lookup[prof, "AccessCount", 0], " 回 / レベル ",
        ToString @ Lookup[prof, "EffectiveLevel", "?"], " / ", ToString @ Lookup[prof, "TrustStatus", "?"],
        If[StringQ @ Lookup[prof, "LastSeen", None], " / 最終 " <> iWGLocalTimeString[prof["LastSeen"]], ""]}],
      Nothing]}];
iWGDialogItems[_] := {};
iWGDialogPrompt[req_Association] := Module[{kind, items, choices, res},
  kind = ToString @ Lookup[req, "Kind", "Fetch"];
  items = iWGDialogItems[req];
  choices = If[kind === "Search",
    {"今回だけ許可" -> "AllowOnce", "拒否" -> "Deny"},
    {"今回だけ許可" -> "AllowOnce", "このホストを許可" -> "AllowHost", "拒否" -> "Deny", "このホストを遮断" -> "BlockHost"}];
  res = Quiet @ Check[
    ChoiceDialog[Column[items, Spacings -> 0.8], choices, WindowTitle -> "SourceVault Web guard"],
    $Canceled];
  If[MemberQ[$iWGDecisions, res], res, "Deny"]];

(* ------------------------------------------------------------
   関所本体 (spec §4 / §9)
   ------------------------------------------------------------ *)
(* ---- V2 (文書 12 の 5 章、2026-11-12): 止めるとき・待たせるときの返し方 ----
   契約: 拒否 (Deny) と保留 (Pending) の応答は <|Outcome, Reason, WhatYouCanDo, Provided, Retry, OwnerNotified, Code|> を持ち、
   モデルへの文面 (Message) はこの順に作る。理由は人が読める 1 文にし、内部のコードは末尾に添えるだけにする。
   次に取れる手段を必ず 1 つ以上示す。確かめられない事実を記憶で埋めさせる言い方 (「手元の情報で答えよ」) はしない。
   2026-11-12 の障害では、"denied by the SourceVault web guard (NewHostWithPrivateContext). Do not retry this URL; use a
   different source." が返った。理由はコードだけで、別の情報源は無かった (検索は 0 件)。 *)
iWGReasonText[code_String, kind_String, host_String] := Switch[code,
  "HostDoesNotExist",
    "the host " <> host <> " does not exist (it has no DNS record), so the address was probably guessed",
  (* 依頼文が名指ししたホスト (文書 12 の 8.10): 推測ではなく、利用者の書いた名前が見つからない *)
  "HostDoesNotExist:NamedInRequest",
    "the host " <> host <> ", which the user's request names, does not exist (it has no DNS record); the name may be misspelled",
  "HostBlocked", "the owner has blocked the host " <> host,
  (* V4 (文書 12 §3.3 の L3): 行き先の評判 *)
  "URLListedMalicious", "this URL is on a list of known phishing or malware pages",
  "HostListedMalicious", "the host " <> host <> " is on more than one list of known phishing or malware sites",
  "HostListedSuspicious", "the host " <> host <> " is on a list of known phishing or malware sites",
  "HostBlockedByDNSFilter", "a security DNS filter blocks the host " <> host <> " as malicious",
  "HostLooksLikeKnownHost",
    "the host " <> host <> " differs by one character from a host that is known here and has no record of its own, so the name may be a typo or an imitation",
  "DestinationUnverified",
    "this conversation has read non-public data, the host " <> host <> " has no track record here, and the lists used to check destinations " <>
      "are not installed or are out of date",
  "ContextAboveApprovedLevel",
    "the owner allows " <> host <> " only for conversations that have read less sensitive data than this one",
  "ExfilShapedURLToUntrustedHost",
    "the URL carries a long encoded string and " <> host <> " is not a host the owner trusts",
  "OpaqueURLToUntrustedHostWithPrivateContext",
    "the URL contains an encoded-looking string, " <> host <> " is not a trusted host, and this conversation has read private data",
  "PrivateSessionNoExternalSearch",
    "this conversation has already read private data, so search words composed here are not sent out",
  (* V11: 検索エンジンにも送らない語 (SearchTermMaxPL 以上の資料の語) *)
  "PrivateRecordTermInSearch",
    "the search words include names, numbers or identifiers that appear only in highly private records this conversation has read " <>
      "(for example grades or health records of people the owner is responsible for); such words are not sent even to search engines",
  "PrivateSessionURLWithoutProvenance",
    "this conversation has already read private data, so only URLs that appear unchanged in the user's request or in earlier web " <>
      "search results (or hosts the owner approved) can be fetched",
  "SecretFingerprintMatch",
    If[kind === "Search", "the search", "the URL"] <>
      " contains names, numbers or identifiers that appear only in private data this conversation has read",
  "ExfilShapedQuery", "the query looks like encoded data rather than search words",
  "OpaqueQueryWithContext",
    "the query contains an encoded-looking string and this conversation has read non-public data",
  "PIIInQueryWithPrivateContext",
    "the query contains what looks like a personal identifier (an e-mail address or a long number) and this conversation has read private data",
  "NewHostWithPrivateContext",
    "the host " <> host <> " has not been used before and this conversation has read non-public data",
  "UnestablishedHostWithPrivateContext",
    "the host " <> host <> " has been used only a few times and this conversation has read non-public data",
  "OpaqueOnNewHost",
    "the URL contains an encoded-looking string and the host " <> host <> " has not been used before",
  "OpaqueURLToUntrustedHost", "the URL contains an encoded-looking string and " <> host <> " is not a trusted host",
  "OpaqueWithPrivateContext",
    "the URL contains an encoded-looking string and this conversation has read non-public data",
  "ExfilShapedURL", "the URL carries a long encoded string",
  _, "the web guard rule " <> code <> " applies"];
iWGOutcomeText[decision_String, code_String, kind_String, host_String, reqId_] := Which[
  decision === "Pending" && kind === "Search",
    "This web search requires owner approval and is waiting (request " <> ToString[reqId] <> ").",
  decision === "Pending",
    "Web access to " <> host <> " requires owner approval and is waiting (request " <> ToString[reqId] <> ").",
  code === "PrivateSessionNoExternalSearch", "External web search is not available in this conversation.",
  code === "PrivateRecordTermInSearch", "This web search was not sent.",
  kind === "Search", "This web search was not sent.",
  True, "Nothing was fetched from " <> host <> "."];
iWGNextSteps[decision_String, code_String, kind_String] := Which[
  code === "HostDoesNotExist:NamedInRequest",
    {"say in the answer that this host could not be found and that the name may be misspelled",
     "run a web search for what the user asked about; if a result is clearly the site the user meant, you may open it, but say " <>
       "in the answer which site you used instead and why",
     "do not present another site's content as if it came from the host the user named"},
  code === "HostDoesNotExist",
    {"run a web search and open a URL that appears in the results",
     "if the user gave a URL, use it exactly as written",
     "if the address cannot be confirmed, say so in the answer instead of guessing another one"},
  (* V4: 評判のリストに載った行き先 *)
  MemberQ[{"URLListedMalicious", "HostListedMalicious", "HostListedSuspicious", "HostBlockedByDNSFilter"}, code],
    {"do not open this page or other pages on the same site",
     "use a different source, for example another result of the web search",
     "say in the answer that this page was not opened because the site is listed as unsafe"},
  code === "HostLooksLikeKnownHost",
    {"if you meant the well-known host, use its address exactly",
     "if this really is a different site, open it from a web search result or from a URL the user wrote",
     "otherwise say in the answer that the page was not opened and why"},
  code === "DestinationUnverified",
    {"use a URL that appears in the web search results or in the user's request",
     "if this page is essential, say in the answer that it could not be opened because the destination could not be verified; " <>
       "the owner can update the reputation lists or approve the host"},
  code === "ContextAboveApprovedLevel",
    {"use what has already been retrieved in this conversation",
     "say in the answer that this page could not be opened in this conversation; it can be opened in a new conversation that has not read private data"},
  code === "PrivateSessionNoExternalSearch",
    {"use what has already been retrieved in this conversation",
     "for facts that need the web, state plainly that they could not be checked here and can be looked up in a new conversation " <>
       "that has not read private data; do not fill them in from memory"},
  code === "PrivateSessionURLWithoutProvenance",
    {"fetch only URLs that appear unchanged in the user's request or in earlier search results",
     "otherwise state in the answer that this page could not be opened in this conversation"},
  code === "PrivateRecordTermInSearch",
    {"search without those words, for example with the name of the organisation or the topic only",
     "if the task cannot be done without them, say in the answer that this search could not be made here"},
  code === "SecretFingerprintMatch" && decision === "Deny",
    {"leave the private details out" <> If[kind === "Search", " and search with general words only", ""],
     "answer from what was actually retrieved and say what could not be checked"},
  decision === "Pending" && kind === "Search",
    {"continue with plainer search words in the meantime",
     "retry this exact search once, later",
     "if it is still waiting, say in the answer that this search is waiting for the owner's approval"},
  decision === "Pending",
    {"continue with other sources in the meantime, for example URLs from the search results",
     "retry this exact call once, later",
     "if it is still waiting, say in the answer that this page is waiting for the owner's approval"},
  kind === "Search",
    {"rephrase the search with plain words, without identifiers or encoded strings",
     "if it cannot be searched, say in the answer that it could not be looked up"},
  True,
    {"use a different source, for example a URL that appears in the search results or in the user's request",
     "if this page is essential, say in the answer that it could not be opened and why"}];
iWGRetryText[decision_String, code_String, kind_String] := Which[
  decision === "Pending", "Retrying the same call later is fine (once or twice).",
  code === "PrivateSessionNoExternalSearch", "Do not retry or rephrase the search.",
  code === "PrivateSessionURLWithoutProvenance", "Do not retry or rewrite this URL.",
  code === "SecretFingerprintMatch", "Do not retry or rephrase it with the same details.",
  code === "PrivateRecordTermInSearch", "Do not retry it with the same names or numbers.",
  StringStartsQ[code, "HostDoesNotExist"], "Do not retry this address or variations of it.",
  MemberQ[{"URLListedMalicious", "HostListedMalicious", "HostListedSuspicious", "HostBlockedByDNSFilter"}, code],
    "Do not retry this URL or other URLs on this host.",
  kind === "Search", "Do not retry the same query.",
  True, "Do not retry this URL."];
iWGRefusal[decision_String, by_String, reasonIn_, kind_String, host_String, reqId_, detail_ : Missing[]] := Module[
  {code = ToString[reasonIn], tcode, rt, ownerQ = MemberQ[{"Owner", "Ticket"}, by]},
  If[! MemberQ[{"Deny", "Pending"}, decision], Return[Missing["NotRefused"]]];
  (* 文面だけが変わる場合 (記録のコードは同じ): 依頼文が名指ししたホストが実在しない *)
  tcode = If[code === "HostDoesNotExist" && detail === "NamedInRequest", "HostDoesNotExist:NamedInRequest", code];
  rt = iWGReasonText[tcode, kind, host];
  (* 似ている相手の名前が分かっているときは、それを書く (V4) *)
  If[code === "HostLooksLikeKnownHost" && StringQ[detail] && StringStartsQ[detail, "LooksLike:"],
    rt = "the host " <> host <> " differs by one character from the known host " <> StringDrop[detail, 10] <>
      " and has no record of its own, so the name may be a typo or an imitation"];
  If[decision === "Deny" && ownerQ, rt = "the owner declined it (it was put to the owner because " <> rt <> ")"];
  <|"Outcome" -> iWGOutcomeText[decision, code, kind, host, reqId], "Reason" -> rt,
    "WhatYouCanDo" -> iWGNextSteps[decision, tcode, kind], "Provided" -> None,
    "Retry" -> iWGRetryText[decision, tcode, kind],
    "OwnerNotified" -> (decision === "Pending" || ownerQ),
    "OwnerText" -> Which[decision === "Pending", "The owner has been asked.",
      ownerQ, "The owner made this decision.",
      True, "This was decided automatically; the owner was not asked."],
    "Code" -> code|>];
iWGRefusal[___] := Missing["NotRefused"];
iWGRefusalText[ref_Association] :=
  ref["Outcome"] <> " Reason: " <> ref["Reason"] <> ". What you can do: " <>
    StringRiffle[MapIndexed[("(" <> ToString[First[#2]] <> ") " <> #1) &, ref["WhatYouCanDo"]], "; "] <> ". " <>
    ref["Retry"] <> " " <> ref["OwnerText"] <> " [code: " <> ref["Code"] <> "]";
iWGRefusalText[_] := "";

iWGFinish[logRec_Association, decision_String, by_String, reason_, an_Association, prof_Association,
    actor_Association, ctxPL_, reqId_, detail_: Missing[]] := Module[{rec, msg, ref},
  (* 文面のホスト名は、確かめた名前 (URL に書かれたもの) があればそれを使う *)
  ref = iWGRefusal[decision, by, reason, ToString @ Lookup[logRec, "Kind", ""],
    ToString @ Lookup[logRec, "HostChecked", Lookup[logRec, "Host", ""]], reqId, detail];
  msg = iWGRefusalText[ref];
  rec = iWGAppendLog[Join[logRec, <|"Decision" -> decision, "DecisionBy" -> by,
    "DecisionReason" -> reason, "DecisionDetail" -> detail, "RequestId" -> reqId|>]];
  <|"Decision" -> decision, "Reason" -> reason, "Reasons" -> Lookup[an, "Reasons", {}],
    "DecisionBy" -> by, "DecisionDetail" -> detail, "RequestId" -> reqId, "Message" -> msg, "Refusal" -> ref,
    "Host" -> Lookup[logRec, "Host", ""], "ContextPL" -> ctxPL, "Actor" -> actor, "Analysis" -> an,
    "Profile" -> KeyTake[prof, {"AccessLevel", "EffectiveLevel", "TrustStatus", "AccessCount", "Established"}],
    "HostCheck" -> Lookup[logRec, "HostCheck", Missing["NotChecked"]],
    (* V11: 検索の送り先 ("Open" / "EnginesOnly") と、その理由・送ってよい検索エンジン (呼び出し側の SourceVaultWebSearch が使う) *)
    "SearchRoute" -> Lookup[logRec, "SearchRoute", Missing[]], "SearchRouteWhy" -> Lookup[logRec, "SearchRouteWhy", Missing[]],
    "SearchEngines" -> If[Lookup[logRec, "SearchRoute", None] === "EnginesOnly",
      Select[Replace[iWGPol["SearchEngines"], Except[_List] -> {}], StringQ], Missing[]],
    "LogEventId" -> Lookup[rec, "EventId", Missing[]]|>];

(* ---- V2 (文書 12 §3.3 の L1、2026-11-12): ホストの実在の確認 ----
   モデルが組み立てた URL の、初めてのホストについて、取得や承認の前に DNS で引けるかを確かめる。引けなければ取得せず、
   所有者にも尋ねず、モデルに「このホストは存在しない。URL を推測せず、検索結果の URL を使う」と返す。
   2026-11-12 の障害では、実在しないホスト (www.fukuui.ac.jp) の取得が所有者の承認の窓に出た。
   - 確かめる条件 (iWGHostCheckWantedQ): 取得・判定が Allow か Ask・URL の形が Plain・出所なし (検索結果や依頼文の URL ではない)・
     所有者が許可したホストでない・取得した実績が無い・IP アドレスや内部のホストでない・ホスト名に符号化らしい部分が無い・
     機密の指紋と一致していない。DNS の問い合わせは、ホスト名を名前解決の経路へ出す。機密を載せ得る形のホスト名
     (符号化らしいラベル・指紋と一致) では問い合わせない (DNS を使った持ち出しの口にしないため)。
   - 名前解決そのものが使えないとき (既知のホストも引けない・時間切れ) は "Unavailable" とし、止めない (文書 12 の P7:
     検証器の故障を禁止にしない)。判定は従来どおり進む。
   - 結果は覚える (実在 1 時間・実在しない 5 分・不明 30 秒)。試験は iWGLookupOnce を差し替える。 *)
If[! AssociationQ[$iWGHostExists], $iWGHostExists = <||>];
If[! ListQ[$iWGResolverState], $iWGResolverState = {0, False}];
$iWGHostCanaries = {"example.com", "www.iana.org"};
iWGLookupOnce[host_String] := With[{r = TimeConstrained[Quiet @ HostLookup[host], 6, $TimedOut]},
  Which[ListQ[r] && r =!= {}, True, r === $TimedOut, $TimedOut, True, False]];
iWGResolverWorksQ[] := Module[{now = AbsoluteTime[], ok},
  If[now - $iWGResolverState[[1]] < 60, Return[$iWGResolverState[[2]]]];
  ok = AnyTrue[$iWGHostCanaries, iWGLookupOnce[#] === True &];
  $iWGResolverState = {now, ok};
  ok];
iWGHostResolve[host_String] := Module[{now = AbsoluteTime[], c, st, ttl, r},
  c = Lookup[$iWGHostExists, host, None];
  If[ListQ[c] && Length[c] === 2,
    ttl = Switch[c[[1]], "Exists", 3600, "NotExist", 300, _, 30];
    If[now - c[[2]] <= ttl, Return[c[[1]]]]];
  r = iWGLookupOnce[host];
  st = Which[
    r === True, "Exists",
    r === $TimedOut, "Unavailable",
    TrueQ[iWGResolverWorksQ[]], "NotExist",
    True, "Unavailable"];
  If[Length[$iWGHostExists] > 2000, $iWGHostExists = <||>];
  $iWGHostExists[host] = {st, now};
  st];
iWGHostResolve[_] := "Unavailable";
(* 確かめるのは、URL に書かれたホスト名そのもの。関所の Host は記録用に正規化してあり (先頭の www. を外す)、
   www.example.org はあっても example.org は引けない、ということがある。 *)
iWGRawHost[url_String, fallback_String] := Module[{p = Quiet @ Check[URLParse[url], $Failed], h},
  h = If[AssociationQ[p], Lookup[p, "Domain", None], None];
  If[StringQ[h] && StringTrim[h] =!= "", StringTrim[ToLowerCase[StringTrim[h]], "."], fallback]];
iWGRawHost[_, fallback_] := fallback;
(* ホスト名を名前解決の経路 (実在の確認・フィルタ付きの DNS) に出してよい形か: URL が Plain で、IP や内部のホストでなく、
   ホスト名に符号化らしい部分が無い *)
iWGHostNameSafeQ[an_Association, host_String] := Module[
  {reasons = ToString /@ Replace[Lookup[an, "Reasons", {}], Except[_List] -> {}], flags = Replace[Lookup[an, "Flags", {}], Except[_List] -> {}]},
  host =!= "" && ToString @ Lookup[an, "Class", "Plain"] === "Plain" && ! MemberQ[flags, "IPLiteral" | "PrivateHost"] &&
    StringMatchQ[host, RegularExpression["[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?"]] &&
    NoneTrue[reasons, StringStartsQ[#, "OpaqueHostLabel" | "Punycode" | "ManyHostLabels" | "EmptyHost" | "NonHTTPScheme" | "UserInfoInURL"] &]];
iWGHostNameSafeQ[___] := False;
iWGHostCheckWantedQ[dec_Association, an_Association, prof_Association, from_, host_String] := Module[{reasons, flags},
  reasons = ToString /@ Replace[Lookup[an, "Reasons", {}], Except[_List] -> {}];
  flags = Replace[Lookup[an, "Flags", {}], Except[_List] -> {}];
  (* 出所なし (モデルが組み立てた URL) と、依頼文の URL (利用者の書き間違い。文書 12 の 8.10) を確かめる。
     検索結果・ページのリンクの URL は、既に取得できた所から来ているので確かめない *)
  iWGPol["HostCheck"] =!= False && host =!= "" && (from === None || from === "Request") &&
    ToString @ Lookup[an, "Class", "Plain"] === "Plain" &&
    Lookup[dec, "Reason", ""] =!= "SecretFingerprintMatch" &&
    ToString @ Lookup[prof, "TrustStatus", "Observed"] =!= "Approved" &&
    ! TrueQ[Lookup[prof, "AccessCount", 0] > 0] &&
    ! MemberQ[flags, "IPLiteral" | "PrivateHost"] &&
    StringMatchQ[host, RegularExpression["[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?"]] &&
    NoneTrue[reasons, StringStartsQ[#, "OpaqueHostLabel" | "Punycode" | "ManyHostLabels" | "EmptyHost" | "NonHTTPScheme" | "UserInfoInURL"] &]];
iWGHostCheckWantedQ[___] := False;

SourceVaultWebGuardCheck[reqIn_Association] := Module[
  {req = reqIn, kind, url, query, channel, an, host, ctx, actor, ctxPL, ctxSrc, prof, logRec, dec,
   sig, ticket, pend, reqId, choice, target, from, sessPL, sess, sStage, link, fpHits, hostCheck = Missing["NotChecked"], rep = <||>,
   sRoute, sRouteWhy},
  kind = ToString @ Lookup[req, "Kind", If[KeyExistsQ[req, "Query"], "Search", "Fetch"]];
  url = ToString @ Lookup[req, "Url", ""];
  query = ToString @ Lookup[req, "Query", ""];
  channel = ToString @ Lookup[req, "Channel", "Unknown"];
  an = If[kind === "Search", SourceVaultWebGuardAnalyzeQuery[query], SourceVaultWebGuardAnalyzeURL[url]];
  host = If[kind === "Search", "websearch", ToString @ Lookup[an, "Host", ""]];
  ctx = SourceVaultWebGuardContext[];
  actor = iWGResolveActor[req, ctx];
  (* W1 (文書 11 §5.1): ツールループの会話の高水位。所有者の呼び出しは対象外。
     V1 (文書 12 §3.2、2026-11-12): 会話があるときは、文脈 PL を会話の高水位で決める。申告 (SourceVaultWebGuardContext) は
     provider ごと・有効時間内の最大で、ほかの会話の値が混ざる。以前は Max[申告, 高水位] だったので、ほかの会話 (や過去に
     張り付いた値) の PL で、何も読んでいない会話の取得が承認待ちになった。この会話の申告は、ループが高水位の初期値に
     入れている (claudecode の iToolLoopNewSession)。request が明示した ContextPL とは Max (下げない)。
     会話が無い呼び出し (ループの外の MCP など) は、従来どおり申告で決める。 *)
  sessPL = iWGSessionPL[];
  Which[
    actor["Kind"] === "Owner" && ! NumericQ[Lookup[req, "ContextPL", None]], ctxPL = 0.0; ctxSrc = "Owner",
    NumericQ[Lookup[req, "ContextPL", None]],
      ctxPL = N[req["ContextPL"]]; ctxSrc = "Explicit";
      If[NumericQ[sessPL] && actor["Kind"] =!= "Owner" && sessPL > ctxPL, ctxPL = sessPL; ctxSrc = "Session"],
    NumericQ[sessPL], ctxPL = sessPL; ctxSrc = "Session",
    True, ctxPL = ctx["PrivacyLevel"]; ctxSrc = ctx["Source"]];
  prof = If[kind === "Fetch" && host =!= "", iWGHostView[host], <||>];
  (* 出所は関所の中の記録だけを見る (request の自己申告 "UrlOrigin" 等は使わない) *)
  from = If[kind === "Fetch", SourceVaultWebGuardURLProvenance[url], None];
  (* W2 (文書 11 §5.3): 依頼文とページのリンクの出所 (会話の中だけ)。所有者の呼び出しは対象外 *)
  sess = $SourceVaultWebGuardSession;
  sStage = If[NumericQ[sessPL], Lookup[SourceVaultWebGuardSessionStage[sessPL], "Stage", None], None];
  link = <|"From" -> None|>;
  If[kind === "Fetch" && from === None && AssociationQ[sess] && actor["Kind"] =!= "Owner",
    link = Quiet @ Check[iWGSessionLinkOrigin[sess, url, sStage], <|"From" -> None|>];
    If[StringQ[Lookup[link, "From", None]], from = link["From"]]];
  (* W2 (§5.2): 機密の指紋。モデルが組み立てた検索語・URL (出所なし) だけを見る。所有者が許可したホストへの取得は見ない *)
  fpHits = If[actor["Kind"] =!= "Owner" && AssociationQ[sess] &&
      (kind === "Search" || (kind === "Fetch" && from === None &&
        ToString @ Lookup[prof, "TrustStatus", "Observed"] =!= "Approved")),
    Quiet @ Check[iWGFingerprintHits[sess, If[kind === "Search", query, url], kind], None], None];
  (* V11 (文書 12 の 8.18 節): 検索の送り先。段 0 (と所有者) は SearXNG の既定のまま、段 1 以上・会話の無い呼び出しで文脈 PL が
     LowRiskPL より上・機密の指紋と一致する検索語は、方針の SearchEngines だけに送る。段 2 で "Deny" なら下で止める *)
  sRoute = Which[
    kind =!= "Search", None,
    actor["Kind"] === "Owner", "Open",
    NumericQ[sessPL], Lookup[SourceVaultWebGuardSessionStage[sessPL], "SearchRoute", "EnginesOnly"],
    NumericQ[ctxPL] && ctxPL > iWGPol["LowRiskPL"], "EnginesOnly",
    True, "Open"];
  sRouteWhy = Which[
    sRoute =!= "EnginesOnly" && sRoute =!= "Denied", None,
    AssociationQ[fpHits] && Lookup[fpHits, "Classes", {}] =!= {}, "PrivateTerms",
    True, "PrivateContext"];
  If[sRoute === "Open" && AssociationQ[fpHits] && Lookup[fpHits, "Classes", {}] =!= {}, sRoute = "EnginesOnly"; sRouteWhy = "PrivateTerms"];
  logRec = <|"Kind" -> kind,
    "SearchRoute" -> If[StringQ[sRoute], sRoute, Missing[]], "SearchRouteWhy" -> If[StringQ[sRouteWhy], sRouteWhy, Missing[]],
    (* V11 (12 章の 18 の決定: 止めない): 機密の語で検索して見つけたページの取得。評判 (下の "Reputation") と合わせて数える *)
    "FoundWithPrivateTerms" -> If[kind === "Fetch" && StringQ[from] && StringStartsQ[from, "SearchResult"] && iWGProvPrivateTermsQ[url],
      True, Missing[]],
    "Url" -> If[kind === "Fetch", url, Missing[]], "Host" -> host,
    "Query" -> If[kind === "Search", StringTake[query, UpTo[500]], Missing[]],
    "HostIdentifierId" -> If[kind === "Fetch" && host =!= "", iWGIdentifierId["WebHost", host], Missing[]],
    "ActorId" -> actor["Id"], "ActorKind" -> actor["Kind"], "ActorDisplay" -> actor["Display"],
    "Provider" -> actor["Provider"], "Model" -> actor["Model"], "ClientName" -> actor["ClientName"],
    "Principal" -> Lookup[actor, "Principal", Missing[]], "ClaimedActorType" -> Lookup[actor, "ClaimedType", Missing[]],
    "Channel" -> channel, "ContextPL" -> ctxPL, "ContextSource" -> ctxSrc,
    "Suspicion" -> Lookup[an, "Suspicion", 0.], "Class" -> Lookup[an, "Class", "Plain"],
    "Reasons" -> Lookup[an, "Reasons", {}], "PIIHints" -> Lookup[an, "PIIHints", {}],
    "HostAccessLevel" -> Lookup[prof, "EffectiveLevel", Missing[]],
    "HostAccessCount" -> Lookup[prof, "AccessCount", Missing[]],
    "URLProvenance" -> If[StringQ[from], from, Missing[]],
    "SessionPL" -> If[NumericQ[sessPL], sessPL, Missing[]],
    "SessionStage" -> If[IntegerQ[sStage], sStage, Missing[]], "LinkNote" -> Lookup[link, "Note", Missing[]],
    "FingerprintHits" -> If[AssociationQ[fpHits] && Lookup[fpHits, "Classes", {}] =!= {},
      KeyTake[fpHits, {"Strong", "Term"}], Missing[]],
    "SessionId" -> Lookup[req, "SessionId", Missing[]],
    (* V7 (文書 12 の 7.2 節): 止めた要求を「いくつの会話で止まったか」で数えるための、会話の ID (中身は持たない) *)
    "ConversationId" -> If[AssociationQ[sess] && StringQ[Lookup[sess, "ConversationId", None]], sess["ConversationId"], Missing[]]|>;
  If[actor["Kind"] =!= "Owner",
    iWGObserveIdentity[If[actor["Kind"] === "Model", "Model", "MCPClient"],
      ToString @ Lookup[actor, "Display", ""], actor["Display"]]];
  If[! TrueQ[$SourceVaultWebGuardEnabled],
    Return[iWGFinish[logRec, "Allow", "Policy", "GuardDisabled", an, prof, actor, ctxPL, Missing[]]]];
  If[actor["Kind"] === "Owner",
    Return[iWGFinish[logRec, "Allow", "Policy", "OwnerActor", an, prof, actor, ctxPL, Missing[]]]];
  (* W1 (文書 11 §5.4): 機密を読んだ後の会話 (高水位 >= PrivatePL、"Restrict") では外部検索を拒否し、取得は検索結果に
     そのまま出た URL と所有者が許可したホストだけにする。承認は出さない (外向きを外す設計、§10 の 2)。
     段は会話自身の高水位で決める (ほかの申告で上がった文脈 PL では外さない)。止めたホストは下の判定表が拒否する。 *)
  If[NumericQ[sessPL] && TrueQ[Lookup[SourceVaultWebGuardSessionStage[sessPL], "Restrict", False]],
    Which[
      (* V11: 段 2 の検索は、送り先を検索エンジンに絞って通す (既定)。止めるのは PrivateStageSearch が "Deny" のときだけ *)
      kind === "Search" && sRoute === "Denied",
        Return[iWGFinish[logRec, "Deny", "Policy", "PrivateSessionNoExternalSearch", an, prof, actor, ctxPL, Missing[]]],
      kind === "Fetch" && from === None && ToString @ Lookup[prof, "TrustStatus", "Observed"] =!= "Approved",
        Return[iWGFinish[logRec, "Deny", "Policy", "PrivateSessionURLWithoutProvenance", an, prof, actor, ctxPL, Missing[]]]]];
  (* V4 (文書 12 §3.3 の L3): 行き先の評価。フィルタ付きの DNS に問い合わせるのは、ホスト名に機密を載せ得ない形のときだけ。
     既知のホストに似た名前の疑いは、モデルが組み立てた URL だけに掛ける (出所のある URL、依頼文が名指ししたホストには掛けない) *)
  If[kind === "Fetch" && host =!= "" && iWGPol["Reputation"] =!= False,
    rep = Quiet @ Check[iWGRepRate[url, host, prof,
      iWGHostNameSafeQ[an, host] && ! (AssociationQ[fpHits] && Length[Lookup[fpHits, "Strong", <||>]] > 0)], <||>];
    If[! AssociationQ[rep], rep = <||>];
    If[StringQ[Lookup[rep, "Lookalike", None]] && (from =!= None ||
        (AssociationQ[sess] && MemberQ[Replace[Lookup[sess, "RequestHosts", {}], Except[_List] -> {}], iWGNamedHostNorm[iWGRawHost[url, host]]])),
      rep["Lookalike"] = None];
    logRec = Join[logRec, <|"Reputation" -> Lookup[rep, "Rating", Missing[]],
      "ReputationListed" -> With[{l = Join[Lookup[rep, "URLListed", {}], Lookup[rep, "Listed", {}]]}, If[l === {}, Missing[], l]],
      "ReputationVerifier" -> Lookup[rep, "Verifier", Missing[]]|>]];
  dec = SourceVaultWebGuardDecide[<|"Kind" -> kind, "ContextPL" -> ctxPL, "Analysis" -> an, "Profile" -> prof,
    "Provenance" -> from, "Reputation" -> rep|>];
  (* W2 (§5.2): 機密の指紋と一致 → 段 1 は承認、段 2 ("Guard" の切替で判定するとき) は拒否。
     日本語の語だけの一致は FingerprintTermAction が "Ask" のときだけ (既定 "Log" = 記録だけ)。
     V4: 取得は、段 1 でも所有者に尋ねずに止めて理由を返す ("FetchDecision" が "Verify" のとき)。検索は従来どおり尋ねる *)
  (* V11: 検索エンジンだけに送る検索では、機密の語 (人名・番号など) を止めない (迷惑メールの判定で最初に試す語)。
     止めるのは、SearchTermMaxPL 以上の資料 (所有者が責任を持つ人の記録) から取った語だけ *)
  If[kind === "Search" && sRoute === "EnginesOnly" && iWGPol["PrivateStageSearch"] =!= "Deny" && AssociationQ[fpHits] &&
      dec["Decision"] =!= "Deny" && TrueQ[Lookup[fpHits, "HighPL", 0] > 0],
    Return[iWGFinish[logRec, "Deny", "Policy", "PrivateRecordTermInSearch", an, prof, actor, ctxPL, Missing[],
      StringRiffle[fpHits["Classes"], ","]]]];
  If[AssociationQ[fpHits] && dec["Decision"] =!= "Deny" &&
      ! (kind === "Search" && sRoute === "EnginesOnly" && iWGPol["PrivateStageSearch"] =!= "Deny") &&
      (Length[Lookup[fpHits, "Strong", <||>]] > 0 || (Lookup[fpHits, "Term", 0] > 0 && iWGPol["FingerprintTermAction"] === "Ask")),
    If[sStage === 2 || (kind === "Fetch" && iWGPol["FetchDecision"] =!= "Ask") ||
        (* V7: 検索語も、段 1 で所有者に尋ねずに止めて理由を返す ("SearchDecision" が "Verify" のとき) *)
        (kind === "Search" && iWGPol["SearchDecision"] =!= "Ask"),
      Return[iWGFinish[logRec, "Deny", "Policy", "SecretFingerprintMatch", an, prof, actor, ctxPL, Missing[],
        StringRiffle[fpHits["Classes"], ","]]],
      dec = iWGDec["Ask", "SecretFingerprintMatch",
        Join[Replace[Lookup[dec, "Reasons", {}], Except[_List] -> {}], ("Fingerprint:" <> #) & /@ fpHits["Classes"]],
        Lookup[dec, "Level", Missing[]]]]];
  (* V2 (文書 12 §3.3 の L1): 実在の確認。通す・尋ねる、のどちらになる取得でも、その前にホストが実在するかを確かめる。
     実在しなければ、取得も承認の問い合わせもせず、理由と次の手段を返す。条件は iWGHostCheckWantedQ。 *)
  (* V4: 「行き先を確かめられない」で止める取得も、先に実在を確かめる (実在しないなら、その方が正確な理由になる) *)
  If[kind === "Fetch" && (MemberQ[{"Allow", "Ask"}, dec["Decision"]] || dec["Reason"] === "DestinationUnverified") &&
      iWGHostCheckWantedQ[dec, an, prof, from, host],
    With[{raw = iWGRawHost[url, host]},
      hostCheck = Quiet @ Check[iWGHostResolve[raw], "Unavailable"];
      logRec = Join[logRec, <|"HostCheck" -> hostCheck, "HostChecked" -> raw|>]];
    If[hostCheck === "NotExist",
      (* 依頼文が名指ししたホスト (URL そのもの、またはホスト名) なら、その旨を添える: 断り文が「利用者の書いた名前が見つからない」になる *)
      Return[iWGFinish[logRec, "Deny", "Policy", "HostDoesNotExist", an, prof, actor, ctxPL, Missing[],
        If[from === "Request" || (AssociationQ[sess] && MemberQ[Replace[Lookup[sess, "RequestHosts", {}], Except[_List] -> {}],
            iWGNamedHostNorm[iWGRawHost[url, host]]]), "NamedInRequest", Missing[]]]]]];
  (* W2 (§5.3): 段 1 のページのリンクは、開いたら選択の情報量を会話の予算から引く *)
  If[dec["Decision"] === "Allow" && from === "PageLink", iWGSessionChargeLink[link]];
  If[dec["Decision"] =!= "Ask",
    (* V4: 検証器が使えないために止めたときは、所有者に知らせる (リストの更新か、ホストの許可で解ける) *)
    If[dec["Reason"] === "DestinationUnverified",
      Quiet @ iWGRepPublish["ReputationListsUnavailable",
        "行き先の評判のリストが未取得か期限切れのため、公開でない資料を読んだ会話からの、実績の無いホストへの取得を止めました。" <>
          "SourceVaultWebReputationUpdate[] で取り直すか、必要なホストを SourceVaultWebHostSetAccess で許可してください。",
        <|"VerifierReason" -> Lookup[rep, "VerifierReason", Missing[]]|>]];
    Return[iWGFinish[logRec, dec["Decision"], "Policy", dec["Reason"], an, prof, actor, ctxPL, Missing[],
      If[dec["Reason"] === "HostLooksLikeKnownHost" && StringQ[Lookup[rep, "Lookalike", None]], "LooksLike:" <> rep["Lookalike"], Missing[]]]]];
  (* Ask: 先に未消費 ticket (オーナーの既決) を探す *)
  target = If[kind === "Search", query, url];
  sig = iWGSignature[kind, target, actor["Id"]];
  ticket = iWGFindTicket[sig];
  If[AssociationQ[ticket],
    iWGConsumeTicket[ticket];
    Return[iWGFinish[logRec,
      If[MemberQ[{"AllowOnce", "AllowHost"}, ticket["Decision"]], "Allow", "Deny"],
      "Ticket", dec["Reason"], an, prof, actor, ctxPL, Lookup[ticket, "RequestId", Missing[]], ticket["Decision"]]]];
  (* pending-first: ダイアログが打ち切られても request は残る *)
  pend = iWGWritePending[<|"Signature" -> sig, "Kind" -> kind, "Url" -> url,
    "Query" -> StringTake[query, UpTo[500]], "Host" -> host, "Actor" -> actor, "ContextPL" -> ctxPL,
    "Reason" -> dec["Reason"], "Reasons" -> dec["Reasons"],
    "Class" -> Lookup[an, "Class", "Plain"], "Suspicion" -> Lookup[an, "Suspicion", 0.],
    "Profile" -> KeyTake[prof, {"AccessCount", "EffectiveLevel", "TrustStatus", "LastSeen", "FirstSeen"}],
    (* V2: 所有者の判断の材料 (実在の確認の結果・URL の出所・会話の段) *)
    "HostCheck" -> hostCheck, "Provenance" -> If[StringQ[from], from, Missing["None"]],
    "SessionStage" -> If[IntegerQ[sStage], sStage, Missing["NoSession"]],
    "Channel" -> channel|>];
  reqId = If[AssociationQ[pend], Lookup[pend, "RequestId", Missing[]], Missing["NoLocalState"]];
  choice = iWGPromptDecision[<|"Kind" -> kind, "Url" -> url, "Query" -> query, "Host" -> host,
    "Reasons" -> dec["Reasons"], "Reason" -> dec["Reason"], "Profile" -> prof, "Actor" -> actor,
    "ContextPL" -> ctxPL, "RequestId" -> reqId,
    "HostCheck" -> hostCheck, "Provenance" -> If[StringQ[from], from, Missing["None"]],
    "SessionStage" -> If[IntegerQ[sStage], sStage, Missing["NoSession"]]|>];
  Which[
    choice === "Queue",
      iWGFinish[logRec, "Pending", "Queue", dec["Reason"], an, prof, actor, ctxPL, reqId],
    MemberQ[$iWGDecisions, choice],
      If[StringQ[reqId],
        Quiet @ SourceVaultWebGuardResolveRequest[reqId, choice];
        With[{t = iWGFindTicket[sig]}, If[AssociationQ[t], iWGConsumeTicket[t]]],
        iWGApplyHostDecision[host, choice, ctxPL, Automatic]];
      iWGFinish[logRec, If[MemberQ[{"AllowOnce", "AllowHost"}, choice], "Allow", "Deny"],
        "Owner", dec["Reason"], an, prof, actor, ctxPL, reqId, choice],
    True,
      iWGFinish[logRec, "Deny", "Owner", dec["Reason"], an, prof, actor, ctxPL, reqId, "Deny"]]];
SourceVaultWebGuardCheck[___] :=
  <|"Decision" -> "Deny", "Reason" -> "InvalidRequest", "Message" -> "Invalid web guard request."|>;

(* ------------------------------------------------------------
   未決 request の処理 / 監視 (FE main kernel)
   ------------------------------------------------------------ *)
SourceVaultWebGuardProcessPending[] := Module[{pend, n = 0, choice},
  pend = SourceVaultWebGuardPendingRequests[];
  If[$SourceVaultWebGuardPrompter === Automatic && ! TrueQ[$Notebooks],
    Return[<|"Status" -> "NoFrontEnd", "Pending" -> Length[pend], "Resolved" -> 0|>]];
  Scan[Function[r,
    choice = iWGPromptDecision[r];
    If[MemberQ[$iWGDecisions, choice],
      Quiet @ SourceVaultWebGuardResolveRequest[ToString @ Lookup[r, "RequestId", ""], choice]; n++]],
    pend];
  iWGHousekeep[];
  <|"Status" -> "Processed", "Resolved" -> n, "Pending" -> Length[pend]|>];

$iWGWatchKey = "sourcevault-webguard-pending";
If[! NumericQ[$iWGWatchLastAt], $iWGWatchLastAt = 0];
If[! ValueQ[$iWGWatchRegistered], $iWGWatchRegistered = False];
iWGWatchTick[] := Module[{now = AbsoluteTime[]},
  If[now - $iWGWatchLastAt < 10, Return[Null]];
  $iWGWatchLastAt = now;
  If[SourceVaultWebGuardPendingRequests[] =!= {},
    Quiet @ Check[SourceVaultWebGuardProcessPending[], Null]];
  Null];

iWGClaudeSym[base_String] :=
  Module[{nm = Join[Names["ClaudeCode`" <> base], Names[base]]},
    If[Length[nm] == 0, $Failed, Symbol[First[nm]]]];

SourceVaultWebGuardStartPendingWatch[] := Module[{reg = iWGClaudeSym["ClaudeRegisterPollingTick"]},
  If[reg === $Failed, Return[<|"Status" -> "ClaudeCodeAbsent", "Key" -> $iWGWatchKey|>]];
  If[Quiet @ Check[
      reg[$iWGWatchKey, Function[Null, iWGWatchTick[]],
        "Phase" -> "SourceVaultWebGuard", "Caller" -> "SourceVaultWebGuard",
        "Priority" -> 1, "Suppressible" -> True, "RunInline" -> True];
      True, False],
    $iWGWatchRegistered = True];
  <|"Status" -> "Registered", "Key" -> $iWGWatchKey, "Watching" -> TrueQ[$iWGWatchRegistered]|>];

SourceVaultWebGuardStopPendingWatch[] := Module[{unreg = iWGClaudeSym["ClaudeUnregisterPollingTick"]},
  $iWGWatchRegistered = False;
  If[unreg === $Failed, Return[<|"Status" -> "ClaudeCodeAbsent"|>]];
  Quiet @ Check[unreg[$iWGWatchKey], $Failed];
  <|"Status" -> "Unregistered", "Key" -> $iWGWatchKey|>];

(* ------------------------------------------------------------
   集計 / レビュー (spec §11, §12)
   ------------------------------------------------------------ *)
iWGMaxPL[rs_List] := Max[0., Select[Lookup[#, "ContextPL", 0] & /@ rs, NumericQ]];
iWGLastAt[rs_List] := With[{ats = Select[Lookup[#, "At", ""] & /@ rs, StringQ]}, If[ats === {}, "", Last[Sort[ats]]]];

iWGActorAgg[rs_List] := <|
  "Display" -> ToString @ Lookup[First[rs], "ActorDisplay", ""],
  "Kind" -> ToString @ Lookup[First[rs], "ActorKind", ""],
  "Count" -> Length[rs],
  "Allowed" -> Count[rs, r_ /; Lookup[r, "Decision", ""] === "Allow"],
  "Denied" -> Count[rs, r_ /; Lookup[r, "Decision", ""] === "Deny"],
  "Pending" -> Count[rs, r_ /; Lookup[r, "Decision", ""] === "Pending"],
  "Suspicious" -> Count[rs, r_ /; Lookup[r, "Class", "Plain"] =!= "Plain"],
  "Hosts" -> Length[DeleteDuplicates[Lookup[#, "Host", ""] & /@ rs]],
  "MaxContextPL" -> iWGMaxPL[rs], "LastAt" -> iWGLastAt[rs]|>;

iWGHostAgg[rs_List] := Module[{host = ToString @ Lookup[First[rs], "Host", ""], v},
  v = iWGHostView[host];
  <|"Count" -> Length[rs],
    "Allowed" -> Count[rs, r_ /; Lookup[r, "Decision", ""] === "Allow"],
    "Denied" -> Count[rs, r_ /; Lookup[r, "Decision", ""] === "Deny"],
    "Pending" -> Count[rs, r_ /; Lookup[r, "Decision", ""] === "Pending"],
    "Suspicious" -> Count[rs, r_ /; Lookup[r, "Class", "Plain"] =!= "Plain"],
    "Actors" -> Length[DeleteDuplicates[Lookup[#, "ActorId", ""] & /@ rs]],
    "MaxContextPL" -> iWGMaxPL[rs], "LastAt" -> iWGLastAt[rs],
    "Level" -> Lookup[v, "EffectiveLevel", Missing[]], "TrustStatus" -> Lookup[v, "TrustStatus", "Observed"],
    "FirstSeen" -> Lookup[v, "FirstSeen", Missing[]]|>];

Options[SourceVaultWebAccessSummary] = {"Days" -> 30, "Since" -> Automatic, "Until" -> Automatic};
SourceVaultWebAccessSummary[OptionsPattern[]] := Module[
  {now = AbsoluteTime[], days, since, until, recs, acc, byKind, byDec, byActor, byHost, newHosts, susp, pend, own},
  days = OptionValue["Days"]; If[! NumericQ[days] || days < 0, days = 30];
  until = iWGToAbs[OptionValue["Until"], now];
  since = iWGToAbs[OptionValue["Since"], until - days*86400];
  recs = SourceVaultWebAccessLog["Since" -> since, "Until" -> until, "Limit" -> All];
  acc = Select[recs, Lookup[#, "Decision", ""] =!= "OwnerDecided" &];
  byKind = Counts[ToString @ Lookup[#, "Kind", "?"] & /@ acc];
  byDec = Counts[ToString @ Lookup[#, "Decision", "?"] & /@ acc];
  byActor = KeySort @ GroupBy[acc, ToString @ Lookup[#, "ActorId", "?"] &, iWGActorAgg];
  byHost = GroupBy[Select[acc, Lookup[#, "Kind", ""] === "Fetch" &], ToString @ Lookup[#, "Host", "?"] &, iWGHostAgg];
  susp = Count[acc, r_ /; Lookup[r, "Class", "Plain"] =!= "Plain"];
  newHosts = Select[Keys[byHost],
    With[{fs = Lookup[byHost[#], "FirstSeen", Missing[]]},
      StringQ[fs] && NumericQ[iWGIsoToAbs[fs]] && iWGIsoToAbs[fs] >= since] &];
  pend = SourceVaultWebGuardPendingRequests[];
  (* V8: 所有者の判断の見直しの件数 (この期間に緩めた数・いま緩めてある数・再確認が要る数)。中身は SourceVaultOwnerDecisionSummary *)
  own = Quiet @ Check[SourceVaultOwnerDecisionSummary["Days" -> Max[1, Round[(until - since)/86400.]]], $Failed];
  <|"Days" -> Round[(until - since)/86400.], "Since" -> iWGAbsToIso[since], "Until" -> iWGAbsToIso[until],
    "Total" -> Length[acc], "ByKind" -> byKind, "ByDecision" -> byDec, "Suspicious" -> susp,
    "ByActor" -> byActor, "ByHost" -> byHost, "NewHosts" -> newHosts,
    "PendingRequests" -> Length[pend],
    "OwnerReview" -> If[AssociationQ[own],
      <|"LoosenedInPeriod" -> own["WallHeight"]["LoosenedInPeriod"], "LoosenedNow" -> Length[own["LoosenedNow"]],
        "ReconfirmDue" -> Length[own["ReconfirmDue"]], "ReconfirmDays" -> own["ReconfirmDays"]|>,
      <|"LoosenedInPeriod" -> 0, "LoosenedNow" -> 0, "ReconfirmDue" -> 0, "ReconfirmDays" -> iWGPol["ReconfirmDays"]|>],
    (* V9 (文書 12 の 4.6 節・9 章): 指標。裏付け (未確認の割合)、止めた割合、所有者に尋ねた回数 *)
    "Grounding" -> With[{gs = Quiet @ Check[SourceVaultGroundingSummary["Days" -> Max[1, Round[(until - since)/86400.]]], $Failed]},
      If[AssociationQ[gs], KeyTake[gs, {"Needed", "Grounded", "Partial", "Unconfirmed", "UngroundedRate", "SentBack", "AfterRefusal"}],
        <|"Needed" -> 0, "Grounded" -> 0, "Partial" -> 0, "Unconfirmed" -> 0, "UngroundedRate" -> Missing["NoData"]|>]],
    "Indicators" -> <|
      "DenyRate" -> If[Length[acc] > 0, N[Lookup[byDec, "Deny", 0]/Length[acc]], Missing["NoData"]],
      "OwnerAsked" -> Lookup[byDec, "Pending", 0] + Count[recs, r_ /; Lookup[r, "Decision", ""] === "OwnerDecided"]|>,
    (* V11 (文書 12 の 8.18 節、12 章の 17・18): 検索の送り先と、記録の語で止めた数 (境 SearchTermMaxPL を再評価するときの材料)。
       機密の語で検索して見つけたページの取得の数と、そのうち評判の分からないホスト (Neutral) の数 (止めずに数える) *)
    "SearchRoutes" -> With[{ss = Select[acc, Lookup[#, "Kind", ""] === "Search" &]},
      <|"Open" -> Count[ss, r_ /; Lookup[r, "SearchRoute", None] === "Open"],
        "EnginesOnly" -> Count[ss, r_ /; Lookup[r, "SearchRoute", None] === "EnginesOnly" && Lookup[r, "Decision", ""] === "Allow"],
        "WithPrivateTerms" -> Count[ss, r_ /; Lookup[r, "SearchRouteWhy", None] === "PrivateTerms" && Lookup[r, "Decision", ""] === "Allow"],
        "RecordTermRefused" -> Count[ss, r_ /; Lookup[r, "DecisionReason", None] === "PrivateRecordTermInSearch"],
        "StageRefused" -> Count[ss, r_ /; Lookup[r, "DecisionReason", None] === "PrivateSessionNoExternalSearch"],
        "SearchTermMaxPL" -> iWGPol["SearchTermMaxPL"], "PrivateStageSearch" -> iWGPol["PrivateStageSearch"]|>],
    "FoundWithPrivateTerms" -> With[{fs = Select[acc, Lookup[#, "Kind", ""] === "Fetch" && TrueQ[Lookup[#, "FoundWithPrivateTerms", False]] &]},
      <|"Fetched" -> Count[fs, r_ /; Lookup[r, "Decision", ""] === "Allow"],
        "UnknownReputation" -> Count[fs, r_ /; Lookup[r, "Decision", ""] === "Allow" && Lookup[r, "Reputation", None] === "Neutral"],
        "Hosts" -> Length[DeleteDuplicates[ToString @ Lookup[#, "Host", ""] & /@ Select[fs, Lookup[#, "Reputation", None] === "Neutral" &]]]|>],
    "OwnerDecisions" -> Count[recs, r_ /; Lookup[r, "Decision", ""] === "OwnerDecided"],
    "ReviewStatus" -> SourceVaultWebAccessReviewStatus[], "MaxContextPL" -> iWGMaxPL[acc]|>];

SourceVaultWebAccessReviewStatus[] := Module[{p = iWGReviewPath[], r, last, now = AbsoluteTime[], days},
  days = $SourceVaultWebGuardReviewIntervalDays;
  r = If[StringQ[p], iWGReadJSON[p], $Failed];
  last = If[AssociationQ[r], iWGIsoToAbs[ToString @ Lookup[r, "LastReviewedAtUTC", ""]], $Failed];
  <|"LastReviewedAt" -> If[NumericQ[last], Lookup[r, "LastReviewedAtUTC"], Missing["NeverReviewed"]],
    "DaysSince" -> If[NumericQ[last], (now - last)/86400., Missing["NeverReviewed"]],
    "Due" -> (! NumericQ[last] || now - last > days*86400),
    "IntervalDays" -> days,
    "NextDueAt" -> If[NumericQ[last], iWGAbsToIso[last + days*86400], Missing["NeverReviewed"]],
    "LastReview" -> If[AssociationQ[r], iWGFixNull[r], Missing["NeverReviewed"]]|>];

If[! AssociationQ[$iWGProbeCache], $iWGProbeCache = <||>];

Options[SourceVaultWebAccessMarkReviewed] = {"Note" -> Missing[], "Recompute" -> True};
SourceVaultWebAccessMarkReviewed[OptionsPattern[]] := Module[{p = iWGReviewPath[], st, sm, rec, days},
  st = SourceVaultWebAccessReviewStatus[];
  days = If[NumericQ[st["DaysSince"]], Min[Ceiling[st["DaysSince"]], 400], $SourceVaultWebGuardReviewIntervalDays];
  sm = SourceVaultWebAccessSummary["Days" -> days];
  rec = <|"LastReviewedAtUTC" -> iWGNowIso[], "Machine" -> iWGMachineTag[],
    "ReviewedPeriodDays" -> days, "Total" -> sm["Total"], "Suspicious" -> sm["Suspicious"],
    "Denied" -> Lookup[sm["ByDecision"], "Deny", 0], "Pending" -> Lookup[sm["ByDecision"], "Pending", 0],
    "NewHosts" -> Length[sm["NewHosts"]],
    (* V8: レビューのときに、緩めたものが何件あったか (再確認そのものは SourceVaultOwnerDecisionReconfirm で別に記録する) *)
    "LoosenedInPeriod" -> Lookup[Lookup[sm, "OwnerReview", <||>], "LoosenedInPeriod", 0],
    "ReconfirmDue" -> Lookup[Lookup[sm, "OwnerReview", <||>], "ReconfirmDue", 0],
    (* V11: 境の再評価の材料 (検索エンジンだけに送った検索・記録の語で止めた検索・評判の分からないホストからの取得) *)
    "SearchEnginesOnly" -> Lookup[Lookup[sm, "SearchRoutes", <||>], "EnginesOnly", 0],
    "SearchWithPrivateTerms" -> Lookup[Lookup[sm, "SearchRoutes", <||>], "WithPrivateTerms", 0],
    "RecordTermRefused" -> Lookup[Lookup[sm, "SearchRoutes", <||>], "RecordTermRefused", 0],
    "FoundWithPrivateTermsUnknownHost" -> Lookup[Lookup[sm, "FoundWithPrivateTerms", <||>], "UnknownReputation", 0],
    "Note" -> OptionValue["Note"]|>;
  If[StringQ[p], iWGWriteJSON[p, rec]];
  If[TrueQ[OptionValue["Recompute"]], Quiet @ Check[SourceVaultWebHostRecomputeProfiles[], Null]];
  $iWGProbeCache = <||>;
  rec];

Options[SourceVaultWebAccessReviewProbe] = {"UseCache" -> True, "Now" -> Automatic, "PendingStaleSeconds" -> 120};
SourceVaultWebAccessReviewProbe[OptionsPattern[]] := Module[
  {now, st, days, sm, pend, stale, reasons = {}, msgs = {}, res, interval = $SourceVaultWebGuardReviewIntervalDays, rdue},
  now = Replace[OptionValue["Now"], Automatic :> AbsoluteTime[]];
  If[TrueQ[OptionValue["UseCache"]] && NumericQ[Lookup[$iWGProbeCache, "At", None]] &&
     now - $iWGProbeCache["At"] < 600 && KeyExistsQ[$iWGProbeCache, "Result"],
    Return[$iWGProbeCache["Result"]]];
  st = SourceVaultWebAccessReviewStatus[];
  days = If[NumericQ[st["DaysSince"]], Min[Ceiling[st["DaysSince"]], 400], interval];
  sm = SourceVaultWebAccessSummary["Days" -> days];
  pend = SourceVaultWebGuardPendingRequests[];
  stale = Select[pend, Lookup[#, "AgeSeconds", 0] >= OptionValue["PendingStaleSeconds"] &];
  If[TrueQ[st["Due"]] && sm["Total"] > 0,
    AppendTo[reasons, "WebAccessReviewDue"];
    AppendTo[msgs, "LLM の Web アクセス記録のレビューが " <> ToString[interval] <> " 日以上ありません: 直近 " <>
      ToString[days] <> " 日で " <> ToString[sm["Total"]] <> " 件 (検索 " <> ToString[Lookup[sm["ByKind"], "Search", 0]] <>
      " / 取得 " <> ToString[Lookup[sm["ByKind"], "Fetch", 0]] <> "、不審 " <> ToString[sm["Suspicious"]] <>
      "、拒否 " <> ToString[Lookup[sm["ByDecision"], "Deny", 0]] <> "、新規ホスト " <> ToString[Length[sm["NewHosts"]]] <>
      ")。SourceVaultWebAccessSummaryView[] で確認し、SourceVaultWebAccessMarkReviewed[] で記録してください。"]];
  (* V8 (文書 12 の 7.3 節): 緩めた設定の再確認。期限 (ReconfirmDays) を過ぎた緩和があれば、件数だけを知らせる (名前は書かない)。
     まとめて再確認すれば、次に知らせるのは ReconfirmDays 日後。何も止めない *)
  rdue = Lookup[Lookup[sm, "OwnerReview", <||>], "ReconfirmDue", 0];
  If[IntegerQ[rdue] && rdue > 0,
    AppendTo[reasons, "OwnerDecisionReconfirmDue"];
    AppendTo[msgs, "所有者が緩めた関所の設定のうち、" <> ToString[Lookup[sm["OwnerReview"], "ReconfirmDays", 30]] <> " 日より長く見直していないものが " <>
      ToString[rdue] <> " 件あります。SourceVaultOwnerDecisionReviewView[] で確かめ、続けるなら再確認を記録してください (何も止まりません)。"]];
  If[stale =!= {},
    AppendTo[reasons, "WebAccessApprovalPending"];
    AppendTo[msgs, "LLM の Web アクセス許可待ちが " <> ToString[Length[stale]] <>
      " 件あります (SourceVaultWebGuardProcessPending[] で応答)。"]];
  res = If[reasons === {},
    <|"Component" -> "WebAccessReview", "Health" -> "OK", "ReasonCode" -> "WebAccessReviewOK",
      "Total" -> sm["Total"], "WindowDays" -> days, "NextDueAt" -> st["NextDueAt"],
      "LastReviewedAt" -> st["LastReviewedAt"]|>,
    <|"Component" -> "WebAccessReview", "Health" -> "Degraded", "ReasonCode" -> First[reasons],
      "ReasonCodes" -> reasons, "Message" -> StringRiffle[msgs, " "],
      "Total" -> sm["Total"], "Suspicious" -> sm["Suspicious"],
      "Denied" -> Lookup[sm["ByDecision"], "Deny", 0], "NewHosts" -> Length[sm["NewHosts"]],
      "PendingStale" -> Length[stale], "ReconfirmDue" -> If[IntegerQ[rdue], rdue, 0],
      "WindowDays" -> days, "LastReviewedAt" -> st["LastReviewedAt"]|>];
  If[OptionValue["Now"] === Automatic, $iWGProbeCache = <|"At" -> now, "Result" -> res|>];
  res];

SourceVaultWebGuardStatus[] := <|
  "Version" -> $SourceVaultWebGuardVersion, "Enabled" -> TrueQ[$SourceVaultWebGuardEnabled],
  "Policy" -> $SourceVaultWebGuardPolicy, "UnknownContextPL" -> $SourceVaultWebGuardUnknownContextPL,
  "PrivateStage" -> $SourceVaultWebGuardPrivateStage,
  "Fingerprint" -> <|"TermAction" -> iWGPol["FingerprintTermAction"], "PageLinkBits" -> iWGPol["PageLinkBits"],
    "PublicCorpusChars" -> StringLength[Replace[$iWGPublicCorpus, Except[_String] -> ""]]|>,
  "Context" -> KeyDrop[SourceVaultWebGuardContext[], "Declarations"],
  "Prompter" -> If[$SourceVaultWebGuardPrompter === Automatic, If[TrueQ[$Notebooks], "Dialog", "Queue"], $SourceVaultWebGuardPrompter],
  "PendingRequests" -> Length[SourceVaultWebGuardPendingRequests[]],
  "KnownHosts" -> Length[SourceVaultWebHostProfiles[]],
  "ReviewStatus" -> KeyDrop[SourceVaultWebAccessReviewStatus[], "LastReview"],
  "Paths" -> <|"Profiles" -> SourceVaultWebHostStorePath[], "Log" -> iWGLogDir[],
    "Pending" -> iWGPendingDir[], "Context" -> iWGContextDir[], "Review" -> iWGReviewPath[]|>,
  "Modules" -> <|"Identity" -> Length[DownValues[SourceVault`SourceVaultObserveIdentifier]] > 0,
    "Privacy" -> Length[DownValues[SourceVault`SourceVaultPrivateView]] > 0,
    "Diagnostics" -> Length[DownValues[SourceVault`SourceVaultDiagnosticsRegisterProbe]] > 0,
    "ClaudeCode" -> iWGClaudeSym["ClaudeRegisterPollingTick"] =!= $Failed|>|>;

(* ------------------------------------------------------------
   V7 (文書 12 の 7.2 節、2026-11-13): 方針の提案
   ------------------------------------------------------------
   V4 と V7 で、取得と検索語について所有者に個別に尋ねることをやめた (止めて、モデルに理由と次の手段を返す)。
   尋ねなくなった分、所有者に届く経路が要る。ここでは、止めた要求を集計して、同じ対象が繰り返し止まったときにだけ、
   所有者に「この対象をどう扱うか」を 1 件の提案として出す。作業の途中に窓は出さない。
   - 集計: 関所の記録 (拒否、自動の判定) を、対象 (ホスト。検索語は "websearch")・理由・種別ごとに、ProposalWindowDays (7) 日分。
   - 提案にする条件: 同じ対象が ProposalMinCount (3) 回以上、または ProposalMinConversations (2) つ以上の会話で止まった。
   - 提案にしない理由: 実在しないホスト・機密を読んだ会話の検索の拒否・関所が無効、など。所有者が対象ごとに決めることが無い
     (7.1 節の「尋ねない」)。$iWGProposalReasons にある理由だけを扱う。
   - 1 日に出す数の上限: ProposalDailyLimit (5)。超えた分は Deferred のまま翌日以降に回す (重要な順)。
   - 答えが無い提案は、現状のまま。ProposalExpireDays (14) 日で取り下げる (Withdrawn)。無応答を承認としない。
   - 「このまま」と答えた・取り下げた対象は、ProposalQuietDays (30) 日は提案にしない。その後も止まり続けていれば、もう一度出す。
   - 答えるのは所有者だけ (SourceVaultPolicyProposalResolve。主体が OwnerFE / OwnerCode。NBAccess の承認 head)。
     答えは提案のファイルと関所の記録 (OwnerDecided) に残す。提示から決定までの秒数と、その日の何件目かも残す (7.3 節の材料)。
   - 提案は、モデルの行動から作られる。モデルが同じ悪性のホストを繰り返し求めれば、そのホストの提案が出る。
     そのため、提案には判断の材料 (評判・実在・実績・止まったときの文脈) を必ず載せ、「遮断」「このまま」を選べるようにする。
   - 置き場は LocalState/webguard/proposals/pp-<id>.json (機ごと。関所の記録が機ごとなので)。URL や検索語の抜粋を含むので、
     privacy の区分は Private (View は文脈 PL の最大で枠を付ける)。
   sv:// の対象 (PL が届かずに止まった読み取り) の集計は未実装。 *)
iWGProposalDir[] := iWGSub[iWGLocalStateDir[], "webguard", "proposals"];
(* 理由 -> {重要度 (小さいほど先に出す), 取得での選択肢, 検索での選択肢}。選択肢の先頭に意味は無い (既定の答えは無い) *)
$iWGProposalReasons = <|
  "URLListedMalicious" -> {1, {"Keep", "BlockHost"}, {}},
  "HostListedMalicious" -> {1, {"Keep", "BlockHost", "AllowDespiteList"}, {}},
  "HostBlockedByDNSFilter" -> {1, {"Keep", "BlockHost", "AllowHost"}, {}},
  "HostListedSuspicious" -> {2, {"Keep", "BlockHost", "AllowDespiteList"}, {}},
  "HostLooksLikeKnownHost" -> {2, {"AllowHost", "Keep", "BlockHost"}, {}},
  "ExfilShapedURLToUntrustedHost" -> {2, {"Keep", "BlockHost"}, {}},
  "ExfilShapedURL" -> {2, {"Keep", "BlockHost"}, {}},
  "OpaqueURLToUntrustedHostWithPrivateContext" -> {3, {"AllowHost", "Keep", "BlockHost"}, {}},
  "OpaqueOnNewHost" -> {3, {"AllowHost", "Keep", "BlockHost"}, {}},
  "OpaqueURLToUntrustedHost" -> {3, {"AllowHost", "Keep", "BlockHost"}, {}},
  "OpaqueWithPrivateContext" -> {3, {"AllowHost", "Keep", "BlockHost"}, {}},
  "DestinationUnverified" -> {3, {"AllowHost", "Keep", "BlockHost"}, {}},
  "SecretFingerprintMatch" -> {3, {"AllowHost", "Keep", "BlockHost"}, {"Keep"}},
  "ContextAboveApprovedLevel" -> {4, {"RaiseLevel", "Keep"}, {}},
  "PrivateSessionURLWithoutProvenance" -> {4, {"AllowHost", "Keep", "BlockHost"}, {}},
  "HostBlocked" -> {5, {"Keep", "Unblock"}, {}},
  "ExfilShapedQuery" -> {3, {}, {"Keep"}},
  "OpaqueQueryWithContext" -> {4, {}, {"Keep"}},
  "PIIInQueryWithPrivateContext" -> {4, {}, {"Keep"}},
  (* V11: 記録の語は、所有者が対象ごとに許可するものではない (PL の境 SearchTermMaxPL で決める) *)
  "PrivateRecordTermInSearch" -> {4, {}, {"Keep"}}|>;
iWGProposalOptions[kind_String, reason_String] := With[{e = Lookup[$iWGProposalReasons, reason, None]},
  If[ListQ[e], If[kind === "Search", e[[3]], e[[2]]], {}]];
iWGProposalPriority[reason_String] := With[{e = Lookup[$iWGProposalReasons, reason, None]}, If[ListQ[e], e[[1]], 9]];
iWGProposalId[kind_, target_, reason_] :=
  "pp-" <> StringTake[iWGHex["proposal|" <> ToString[kind] <> "|" <> ToString[target] <> "|" <> ToString[reason]], 16];
iWGProposalPath[id_String] := With[{d = iWGProposalDir[]},
  If[StringQ[d] && StringMatchQ[id, RegularExpression["pp-[0-9a-f]{16}"]], FileNameJoin[{d, id <> ".json"}], $Failed]];
iWGProposalPath[_] := $Failed;
iWGProposalsReadAll[] := Module[{d = iWGProposalDir[]},
  If[! StringQ[d] || ! DirectoryQ[d], Return[<||>]];
  Association[(Lookup[#, "ProposalId", ""] -> #) & /@
    Select[iWGFixNull /@ (iWGReadJSON /@ FileNames["pp-*.json", d]), AssociationQ[#] && StringQ[Lookup[#, "ProposalId", None]] &]]];
iWGProposalWrite[rec_Association] := With[{p = iWGProposalPath[ToString @ Lookup[rec, "ProposalId", ""]]},
  If[StringQ[p], iWGWriteJSON[p, rec], $Failed]];
iWGLocalDay[abs_?NumericQ] := DateString[abs, {"Year", "-", "Month", "-", "Day"}];
iWGLocalDay[_] := "";
iWGProposalAbs[rec_, key_String] := With[{a = iWGIsoToAbs[ToString @ Lookup[rec, key, ""]]}, If[NumericQ[a], a, None]];
(* 集計の対象になる記録: 自動の判定で止めたもの (所有者が答えたもの・所有者自身の呼び出しは除く) で、提案にできる理由のもの *)
iWGProposalRecords[days_] := Select[
  SourceVaultWebAccessLog["Days" -> days, "Decision" -> "Deny", "IncludeOwnerDecisions" -> False, "Limit" -> All],
  Function[r, Lookup[r, "DecisionBy", ""] === "Policy" && Lookup[r, "ActorKind", ""] =!= "Owner" &&
    iWGProposalOptions[ToString @ Lookup[r, "Kind", ""], ToString @ Lookup[r, "DecisionReason", ""]] =!= {} &&
    (Lookup[r, "Kind", ""] === "Search" || (StringQ[Lookup[r, "Host", None]] && r["Host"] =!= ""))]];
iWGProposalKey[r_Association] := {ToString @ Lookup[r, "Kind", ""],
  If[Lookup[r, "Kind", ""] === "Search", "websearch", ToString @ Lookup[r, "Host", ""]], ToString @ Lookup[r, "DecisionReason", ""]};
(* 1 つの対象についての数と、判断の材料。通信はしない (評判は手元のリスト、実在は記録に残った確認の結果) *)
iWGProposalAggregate[kind_String, target_String, reason_String, rs_List] := Module[
  {convs, ats, maxPL, prof, rep, hostChecks},
  convs = DeleteDuplicates @ Select[Lookup[#, "ConversationId", None] & /@ rs, StringQ];
  ats = Sort @ Select[ToString @ Lookup[#, "At", ""] & /@ rs, # =!= "" &];
  maxPL = iWGMaxPL[rs];
  prof = If[kind === "Fetch", iWGHostView[target], <||>];
  rep = If[kind === "Fetch", Quiet @ Check[iWGRepRate[None, target, prof, False], <||>], <||>];
  If[! AssociationQ[rep], rep = <||>];
  hostChecks = DeleteDuplicates @ Select[Lookup[#, "HostCheck", None] & /@ rs, StringQ];
  <|"Count" -> Length[rs], "Conversations" -> Length[convs], "FirstAt" -> First[ats, ""], "LastAt" -> Last[ats, ""],
    "MaxContextPL" -> maxPL, "SuggestedLevel" -> Clip[Max[N @ iWGPol["PrivatePL"], maxPL], {0., 1.}],
    "Actors" -> Take[DeleteDuplicates[ToString @ Lookup[#, "ActorDisplay", "?"] & /@ rs], UpTo[3]],
    "Channels" -> Take[DeleteDuplicates[ToString @ Lookup[#, "Channel", "?"] & /@ rs], UpTo[3]],
    "Examples" -> Take[DeleteDuplicates[iWGShort[Lookup[#, If[kind === "Fetch", "Url", "Query"], ""], 100] & /@ rs], UpTo[3]],
    "Material" -> If[kind === "Fetch",
      <|"HostCheck" -> Which[MemberQ[hostChecks, "Exists"], "Exists", hostChecks === {}, "NotChecked", True, First[hostChecks]],
        "Reputation" -> ToString @ Lookup[rep, "Rating", "Unknown"],
        "Listed" -> Join[Lookup[rep, "URLListed", {}], Lookup[rep, "Listed", {}], Lookup[rep, "ListedIgnored", {}]],
        "Verifier" -> ToString @ Lookup[rep, "Verifier", "Unknown"],
        "Lookalike" -> With[{l = Lookup[rep, "Lookalike", None]}, If[StringQ[l], l, ""]],
        "TrustStatus" -> ToString @ Lookup[prof, "TrustStatus", "Observed"],
        "AccessCount" -> Lookup[prof, "AccessCount", 0],
        "HostLevel" -> With[{l = Lookup[prof, "EffectiveLevel", None]}, If[NumericQ[l], l, -1]],
        "FirstSeen" -> With[{f = Lookup[prof, "FirstSeen", ""]}, If[StringQ[f], f, ""]]|>,
      <||>]|>];
iWGProposalThresholdQ[rs_List] := Length[rs] >= iWGPol["ProposalMinCount"] ||
  Length[DeleteDuplicates @ Select[Lookup[#, "ConversationId", None] & /@ rs, StringQ]] >= iWGPol["ProposalMinConversations"];
If[! NumericQ[$iWGProposalRefreshedAt], $iWGProposalRefreshedAt = 0.];
If[! ValueQ[$iWGProposalProbeCache], $iWGProposalProbeCache = None];
Options[SourceVaultPolicyProposalsRefresh] = {"Now" -> Automatic};
SourceVaultPolicyProposalsRefresh[OptionsPattern[]] := Module[
  {now, days = iWGPol["ProposalWindowDays"], groups, all, created = 0, updated = 0, reopened = 0, withdrawn = 0, presented = 0,
   limit = iWGPol["ProposalDailyLimit"], expire = iWGPol["ProposalExpireDays"], quiet = iWGPol["ProposalQuietDays"], today, presentedToday, deferred},
  now = Replace[OptionValue["Now"], Except[_?NumericQ] :> AbsoluteTime[]];
  If[! StringQ[iWGProposalDir[]], Return[Failure["NoLocalState", <|"Function" -> "SourceVaultPolicyProposalsRefresh"|>]]];
  If[! NumericQ[days] || days <= 0, days = 7];
  If[! IntegerQ[limit] || limit < 0, limit = 5];
  If[! NumericQ[expire] || expire <= 0, expire = 14];
  If[! NumericQ[quiet] || quiet < 0, quiet = 30];
  all = iWGProposalsReadAll[];
  (* 1. 答えの無いまま期限が来た提案を取り下げる (現状のまま。無応答を承認としない) *)
  all = Map[Function[p,
      If[Lookup[p, "Status", ""] === "Open" && NumericQ[iWGProposalAbs[p, "ExpiresAtUTC"]] && now > iWGProposalAbs[p, "ExpiresAtUTC"],
        withdrawn++;
        With[{q = Join[p, <|"Status" -> "Withdrawn", "Decision" -> "NoAnswer", "ClosedAtUTC" -> iWGAbsToIso[now]|>]}, iWGProposalWrite[q]; q],
        p]], all];
  (* 2. 止めた要求を集計して、提案を作る・数を更新する・(静かな期間の後も止まり続けていれば) 出し直す *)
  groups = GroupBy[iWGProposalRecords[days], iWGProposalKey];
  KeyValueMap[Function[{key, rs}, Module[{kind = key[[1]], target = key[[2]], reason = key[[3]], id, old, agg, closedAt, later, rec},
      id = iWGProposalId[kind, target, reason];
      old = Lookup[all, id, None];
      Which[
        ! AssociationQ[old],
          If[iWGProposalThresholdQ[rs],
            agg = iWGProposalAggregate[kind, target, reason, rs];
            rec = Join[<|"Type" -> "SourceVaultPolicyProposal", "SchemaVersion" -> 1, "ProposalId" -> id,
              "TargetKind" -> If[kind === "Fetch", "Host", "Search"], "Kind" -> kind, "Target" -> target, "Reason" -> reason,
              "Priority" -> iWGProposalPriority[reason], "Options" -> iWGProposalOptions[kind, reason],
              "Status" -> "Deferred", "Round" -> 1, "CreatedAtUTC" -> iWGAbsToIso[now], "Machine" -> iWGMachineTag[]|>, agg];
            iWGProposalWrite[rec]; all[id] = rec; created++],
        MemberQ[{"Open", "Deferred"}, Lookup[old, "Status", ""]],
          agg = iWGProposalAggregate[kind, target, reason, rs];
          If[Lookup[old, "Count", 0] =!= agg["Count"] || Lookup[old, "LastAt", ""] =!= agg["LastAt"],
            rec = Join[old, agg]; iWGProposalWrite[rec]; all[id] = rec; updated++],
        True,
          (* 答えた・取り下げた提案: 静かな期間が過ぎ、閉じた後の分だけで条件を満たすなら、出し直す *)
          closedAt = iWGProposalAbs[old, "ClosedAtUTC"];
          later = If[NumericQ[closedAt], Select[rs, With[{a = iWGIsoToAbs[ToString @ Lookup[#, "At", ""]]}, NumericQ[a] && a > closedAt] &], rs];
          If[(! NumericQ[closedAt] || now - closedAt >= quiet*86400) && iWGProposalThresholdQ[later],
            agg = iWGProposalAggregate[kind, target, reason, later];
            rec = Join[KeyDrop[old, {"Decision", "ClosedAtUTC", "DecidedAtUTC", "PresentedAtUTC", "ExpiresAtUTC", "Applied", "Note",
                "SecondsSincePresented", "DecisionsThatDay"}],
              <|"Status" -> "Deferred", "Round" -> Replace[Lookup[old, "Round", 1], Except[_Integer] -> 1] + 1,
                "History" -> Append[Replace[Lookup[old, "History", {}], Except[_List] -> {}],
                  <|"Decision" -> ToString @ Lookup[old, "Decision", "?"], "ClosedAtUTC" -> ToString @ Lookup[old, "ClosedAtUTC", ""]|>],
                "Options" -> iWGProposalOptions[kind, reason]|>, agg];
            iWGProposalWrite[rec]; all[id] = rec; reopened++]]]], groups];
  (* 3. 1 日の上限までを所有者に出す (重要な順、同じ重要度なら回数の多い順)。残りは Deferred のまま *)
  today = iWGLocalDay[now];
  presentedToday = Count[Values[all], p_ /; With[{a = iWGProposalAbs[p, "PresentedAtUTC"]}, NumericQ[a] && iWGLocalDay[a] === today]];
  deferred = SortBy[Select[Values[all], Lookup[#, "Status", ""] === "Deferred" &],
    {Lookup[#, "Priority", 9] &, -Lookup[#, "Count", 0] &, ToString @ Lookup[#, "CreatedAtUTC", ""] &}];
  Scan[Function[p,
      If[presentedToday < limit,
        With[{q = Join[p, <|"Status" -> "Open", "PresentedAtUTC" -> iWGAbsToIso[now], "ExpiresAtUTC" -> iWGAbsToIso[now + expire*86400]|>]},
          iWGProposalWrite[q]; all[q["ProposalId"]] = q; presentedToday++; presented++]]], deferred];
  (* V8 (文書 12 の 7.3 節): ついでに、関所の設定の切り替えに気づいて記録する。service の定期処理 (1 時間に 1 回) がここを通るので、
     service のカーネルの設定 (MCP の経路の関所が使う値) も追える。FE のカーネルでは、集計を作るときにも見ている *)
  Quiet @ Check[iWGPostureCheck[], Null];
  $iWGProposalRefreshedAt = AbsoluteTime[];
  $iWGProposalProbeCache = None;
  <|"Created" -> created, "Updated" -> updated, "Reopened" -> reopened, "Withdrawn" -> withdrawn, "Presented" -> presented,
    "Open" -> Count[Values[all], p_ /; Lookup[p, "Status", ""] === "Open"],
    "Deferred" -> Count[Values[all], p_ /; Lookup[p, "Status", ""] === "Deferred"],
    "PresentedToday" -> presentedToday, "DailyLimit" -> limit|>];

Options[SourceVaultPolicyProposals] = {"Status" -> "Open", "Refresh" -> Automatic};
SourceVaultPolicyProposals[OptionsPattern[]] := Module[{st = OptionValue["Status"], all},
  If[OptionValue["Refresh"] === True || (OptionValue["Refresh"] === Automatic && AbsoluteTime[] - $iWGProposalRefreshedAt > 600),
    Quiet @ Check[SourceVaultPolicyProposalsRefresh[], Null]];
  all = Values[iWGProposalsReadAll[]];
  all = Which[st === All, all, StringQ[st], Select[all, Lookup[#, "Status", ""] === st &],
    ListQ[st], Select[all, MemberQ[st, Lookup[#, "Status", ""]] &], True, all];
  SortBy[all, {Lookup[#, "Priority", 9] &, -Lookup[#, "Count", 0] &, ToString @ Lookup[#, "CreatedAtUTC", ""] &}]];

(* 選んだときに何が変わるか (所有者が読む文) *)
iWGProposalEffectText[choice_String, p_Association] := With[
  {host = ToString @ Lookup[p, "Target", ""], lv = ToString[NumberForm[N @ Lookup[p, "SuggestedLevel", 0.5], {3, 2}]],
   quiet = ToString @ iWGPol["ProposalQuietDays"]},
  Switch[choice,
    "Keep", "何も変えません。この対象は今後も止まります。同じ提案は " <> quiet <> " 日は出しません。",
    "AllowHost", host <> " を許可します。機密度 " <> lv <> " までの資料を読んだ会話から取得でき、符号化らしい URL も通るようになります。",
    "AllowDespiteList", "評判のリストに載っていることを承知のうえで、" <> host <> " を許可します (機密度 " <> lv <>
      " まで)。\nURL そのものがリストに載っているページは、引き続き止めます。",
    "RaiseLevel", host <> " に許可する機密度を " <> lv <> " に上げます。",
    "BlockHost", host <> " を遮断します。検索結果や依頼文に出た URL でも開かなくなります。",
    "Unblock", host <> " の遮断を解きます。以後は、ほかのホストと同じ規則で判定します。",
    _, ""]];
iWGProposalChoiceLabel[choice_String] := Switch[choice,
  "Keep", "このまま", "AllowHost", "許可", "AllowDespiteList", "リストを承知で許可", "RaiseLevel", "機密度を上げる",
  "BlockHost", "遮断", "Unblock", "遮断を解く", _, choice];

(* V8 (文書 12 の 7.3 節): 緩める答えに、確認を 1 段足すか。既定では足さない (しきい値は所有者が決める)。
   足すのは、提示からの時間が ConfirmFastSeconds より短い、または緩める判断が ConfirmAfterConsecutive 回以上続いているとき。
   止めはしない: 理由を返し、同じ式に "Confirm" -> True を付けて評価し直せば通る *)
$iWGLooseningChoices = {"AllowHost", "AllowDespiteList", "RaiseLevel", "Unblock"};
iWGTrailingLoosening[] := Module[{rs},
  rs = iWGDecisionSorted[Select[iWGDecisionRead[], ! MemberQ[{"Detected", "Review"}, Lookup[#, "Via", ""]] &]];
  Length[TakeWhile[Reverse[rs], Lookup[#, "Direction", ""] === "Loosen" &]]];
iWGConfirmReason[choice_String, seconds_] := Module[{fast = iWGPol["ConfirmFastSeconds"], run = iWGPol["ConfirmAfterConsecutive"], n},
  If[! MemberQ[$iWGLooseningChoices, choice], Return[None, Module]];
  Which[
    NumericQ[fast] && NumericQ[seconds] && seconds >= 0 && seconds < fast,
      "この提案を見せてから " <> ToString[Round[seconds]] <> " 秒です (材料を読むには短い時間です)。",
    IntegerQ[run] && run > 0 && (n = iWGTrailingLoosening[]) >= run,
      "緩める判断が " <> ToString[n] <> " 回続いています。",
    True, None]];
Options[SourceVaultPolicyProposalResolve] = {"Note" -> Missing[], "Level" -> Automatic, "Confirm" -> False};
SourceVaultPolicyProposalResolve[id_String, choice_String, OptionsPattern[]] := Module[
  {pk = iWGPrincipalKind[], p, host, lv, applied = Null, now = AbsoluteTime[], presentedAt, today, nth, rec, secs, why, ctx},
  If[! MemberQ[{"OwnerFE", "OwnerCode"}, pk],
    Return[Failure["WebGuardNotAuthorized", <|"Function" -> "SourceVaultPolicyProposalResolve", "Principal" -> pk,
      "MessageTemplate" -> "SourceVaultPolicyProposalResolve may be called only by the owner; the current principal is `1`. From the front end use SourceVaultIntegrityOwnerAction[SourceVaultPolicyProposalResolve[id, choice]].",
      "MessageParameters" -> {pk}|>]]];
  p = With[{path = iWGProposalPath[id]}, If[StringQ[path], iWGFixNull @ iWGReadJSON[path], $Failed]];
  If[! AssociationQ[p], Return[Failure["ProposalNotFound", <|"ProposalId" -> id|>]]];
  If[! MemberQ[{"Open", "Deferred"}, Lookup[p, "Status", ""]],
    Return[Failure["ProposalClosed", <|"ProposalId" -> id, "Status" -> Lookup[p, "Status", ""], "Decision" -> Lookup[p, "Decision", Missing[]]|>]]];
  If[! MemberQ[Replace[Lookup[p, "Options", {}], Except[_List] -> {}], choice],
    Return[Failure["InvalidChoice", <|"ProposalId" -> id, "Choice" -> choice, "Allowed" -> Lookup[p, "Options", {}]|>]]];
  host = ToString @ Lookup[p, "Target", ""];
  lv = If[NumericQ[OptionValue["Level"]], Clip[N @ OptionValue["Level"], {0., 1.}],
    Clip[N @ Replace[Lookup[p, "SuggestedLevel", 0.5], Except[_?NumericQ] -> 0.5], {0., 1.}]];
  presentedAt = iWGProposalAbs[p, "PresentedAtUTC"];
  secs = If[NumericQ[presentedAt], Round[now - presentedAt], -1];
  (* V8: 確認を 1 段足す (しきい値が設定されているときだけ)。何も変えずに、理由と、通すための式の書き方を返す *)
  why = If[TrueQ[OptionValue["Confirm"]], None, iWGConfirmReason[choice, secs]];
  If[StringQ[why],
    Return[<|"ProposalId" -> id, "Status" -> "ConfirmRequired", "Decision" -> choice, "Target" -> host, "Reason" -> why,
      "Effect" -> iWGProposalEffectText[choice, p],
      "ToConfirm" -> "材料を確かめたうえで続けるなら、同じ式に \"Confirm\" -> True を付けて評価してください。何もしなければ、現状のままです。"|>]];
  ctx = <|"Via" -> "PolicyProposal", "Ref" -> id, "Seconds" -> secs,
    "MaterialDigest" -> iWGDigest[KeyTake[p, {"Target", "Reason", "Count", "Conversations", "MaxContextPL", "Material", "Options"}]]|>;
  applied = Block[{$iWGDecisionContext = ctx}, Switch[choice,
    "AllowHost" | "RaiseLevel", SourceVaultWebHostSetAccess[host, lv, "TrustStatus" -> "Approved", "PolicySource" -> "Owner",
      "Note" -> "policy proposal " <> id],
    "AllowDespiteList", SourceVaultWebHostSetAccess[host, lv, "TrustStatus" -> "Approved", "PolicySource" -> "Owner",
      "ListOverride" -> True, "Note" -> "policy proposal " <> id <> " (listed host allowed by the owner)"],
    "BlockHost", SourceVaultWebHostBlock[host, "Note" -> "policy proposal " <> id],
    "Unblock", SourceVaultWebHostSetAccess[host, N @ iWGPol["DefaultHostLevel"], "TrustStatus" -> "Observed", "PolicySource" -> "Default",
      "Note" -> "policy proposal " <> id <> " (unblocked by the owner)"],
    _, Null]];
  If[FailureQ[applied], Return[applied]];
  (* V8: 「このまま」は設定を変えないので、ここで判断の記録に残す (ほかの答えは SourceVaultWebHostSetAccess が残す) *)
  If[choice === "Keep",
    Quiet @ Check[iWGNoteOwnerDecision[Join[<|"Action" -> "Keep", "Direction" -> "Neutral",
      "TargetKind" -> ToString @ Lookup[p, "TargetKind", "Host"], "Target" -> host|>, ctx]], Null]];
  (* 7.3 節の材料: 提示から決定までの秒数と、その日の何件目の決定か *)
  today = iWGLocalDay[now];
  nth = 1 + Count[Values[iWGProposalsReadAll[]], q_ /; With[{a = iWGProposalAbs[q, "DecidedAtUTC"]}, NumericQ[a] && iWGLocalDay[a] === today]];
  rec = Join[p, <|"Status" -> "Resolved", "Decision" -> choice, "DecidedAtUTC" -> iWGAbsToIso[now], "ClosedAtUTC" -> iWGAbsToIso[now],
    "SecondsSincePresented" -> If[NumericQ[presentedAt], Round[now - presentedAt], -1], "DecisionsThatDay" -> nth,
    "Note" -> With[{n = OptionValue["Note"]}, If[StringQ[n], n, ""]],
    "Applied" -> <|"Choice" -> choice, "Host" -> If[Lookup[p, "Kind", ""] === "Fetch", host, ""],
      "Level" -> If[MemberQ[{"AllowHost", "AllowDespiteList", "RaiseLevel"}, choice], lv, -1]|>|>];
  iWGProposalWrite[rec];
  iWGAppendLog[<|"Kind" -> Lookup[p, "Kind", ""], "Host" -> host, "Decision" -> "OwnerDecided", "DecisionBy" -> "Owner",
    "DecisionDetail" -> choice, "DecisionReason" -> Lookup[p, "Reason", Missing[]], "RequestId" -> id, "Channel" -> "PolicyProposal",
    "ContextPL" -> Lookup[p, "MaxContextPL", Missing[]]|>];
  $iWGProbeCache = <||>; $iWGProposalProbeCache = None;
  <|"ProposalId" -> id, "Status" -> "Resolved", "Decision" -> choice, "Target" -> host, "Applied" -> rec["Applied"],
    "Effect" -> iWGProposalEffectText[choice, p]|>];
SourceVaultPolicyProposalResolve[___] := Failure["BadArguments", <|"Function" -> "SourceVaultPolicyProposalResolve"|>];

(* SystemDoctor の probe: 所有者に出している提案があれば Degraded。対象の名前は書かない (件数だけ) *)
Options[SourceVaultPolicyProposalsProbe] = {"UseCache" -> True};
SourceVaultPolicyProposalsProbe[OptionsPattern[]] := Module[{now = AbsoluteTime[], c = $iWGProposalProbeCache, open, deferred, res},
  If[TrueQ[OptionValue["UseCache"]] && AssociationQ[c] && NumericQ[Lookup[c, "At", None]] && now - c["At"] < 600, Return[c["Result"]]];
  open = Quiet @ Check[SourceVaultPolicyProposals["Status" -> "Open"], {}];
  If[! ListQ[open], open = {}];
  deferred = Count[Values[iWGProposalsReadAll[]], p_ /; Lookup[p, "Status", ""] === "Deferred"];
  res = If[open === {},
    <|"Component" -> "PolicyProposals", "Health" -> "OK", "ReasonCode" -> "PolicyProposalsNone", "Open" -> 0, "Deferred" -> deferred|>,
    <|"Component" -> "PolicyProposals", "Health" -> "Degraded", "ReasonCode" -> "PolicyProposalsOpen",
      "Message" -> "関所が繰り返し止めている対象について、方針の提案が " <> ToString[Length[open]] <> " 件あります" <>
        If[deferred > 0, " (ほかに " <> ToString[deferred] <> " 件を後日に回しています)", ""] <>
        "。SourceVaultPolicyProposalsView[] で内容を見て答えてください。答えなければ現状のままで、" <>
        ToString @ iWGPol["ProposalExpireDays"] <> " 日で取り下げます。",
      "Open" -> Length[open], "Deferred" -> deferred,
      "Hosts" -> Count[open, p_ /; Lookup[p, "TargetKind", ""] === "Host"],
      "Searches" -> Count[open, p_ /; Lookup[p, "TargetKind", ""] === "Search"]|>];
  $iWGProposalProbeCache = <|"At" -> now, "Result" -> res|>;
  res];

(* ------------------------------------------------------------
   V8 (文書 12 の 7.3 節、2026-11-13): 所有者の判断の見直し
   ------------------------------------------------------------
   記録 (iWGNoteOwnerDecision) を読んで、「見るもの」を作る: 壁の高さ・速い承認・連続の承認・一貫性と、この期間に緩めたもの・
   再確認が要るもの。どれも見るためのもので、これで何かが止まることは無い。所有者の判断を取り消すこともしない (7.4 節)。
   「拒否のあとの結果」(拒否のあと、依頼が未確認の回答で終わった件数) は、裏付けの検査の結果を会話ごとに残していないので、
   まだ作れない (V9)。台帳 (integrity) の側の所有者の操作 (基準の受け入れ・認可・AcceptedRisk) は、台帳に ticket つきで
   記録されている。ここには含めない。 *)
(* ---- 関所の設定の今の値と、緩めた状態か。既定より緩い値を「緩めている」と見る ---- *)
iWGPolicyPosture[] := Module[{num, row},
  num = Function[{k, looserIf}, With[{v = iWGPol[k], d = Lookup[$iWGDefaultPolicy, k, None]},
    <|"Value" -> ToString[v], "Loosened" -> (NumericQ[v] && NumericQ[d] && looserIf[v, d])|>]];
  row = Function[{v, loose}, <|"Value" -> ToString[v], "Loosened" -> TrueQ[loose]|>];
  <|"GuardEnabled" -> row[TrueQ[$SourceVaultWebGuardEnabled], ! TrueQ[$SourceVaultWebGuardEnabled]],
    "GuardRequired" -> row[TrueQ[$SourceVaultWebGuardRequired], ! TrueQ[$SourceVaultWebGuardRequired]],
    "PrivateStage" -> row[$SourceVaultWebGuardPrivateStage, $SourceVaultWebGuardPrivateStage =!= "Restrict"],
    "Prompter" -> With[{p = $SourceVaultWebGuardPrompter},
      row[If[MemberQ[{Automatic, "Queue", "Deny"}, p], p, "Function"], ! MemberQ[{Automatic, "Queue", "Deny"}, p]]],
    "HostCheck" -> row[iWGPol["HostCheck"], iWGPol["HostCheck"] === False],
    "Reputation" -> row[iWGPol["Reputation"], iWGPol["Reputation"] === False],
    "DNSFilter" -> With[{f = If[ValueQ[$SourceVaultWebReputationDNSFilter], $SourceVaultWebReputationDNSFilter, None]},
      row[f, ! MemberQ[{"Quad9", "Cloudflare"}, f]]],
    "FetchDecision" -> row[iWGPol["FetchDecision"], False], "SearchDecision" -> row[iWGPol["SearchDecision"], False],
    "FingerprintTermAction" -> row[iWGPol["FingerprintTermAction"], False],
    "LowRiskPL" -> num["LowRiskPL", Greater], "PrivatePL" -> num["PrivatePL", Greater], "DefaultHostLevel" -> num["DefaultHostLevel", Greater],
    "PageLinkBits" -> num["PageLinkBits", Greater], "OpaqueScore" -> num["OpaqueScore", Greater], "ExfilScore" -> num["ExfilScore", Greater],
    "EstablishedCount" -> num["EstablishedCount", Less], "EstablishedDays" -> num["EstablishedDays", Less]|>];
(* 設定の切り替えを、気づいた時点で記録する。値はカーネルごとなので、FE のカーネルと service のカーネルを別に覚える。
   試験やスクリプトのカーネルでは何もしない (その場かぎりの値で、記録を汚さない) *)
If[! ValueQ[$iWGPostureRole], $iWGPostureRole = Automatic];
iWGPostureRoleNow[] := Which[StringQ[$iWGPostureRole], $iWGPostureRole, TrueQ[$Notebooks], "FE",
  iWGPrincipalKind[] === "Service", "Service", True, None];
iWGPosturePath[role_String] := iWGSub[iWGLocalStateDir[], "webguard", "policy_posture-" <> role <> ".json"];
iWGPostureAssoc[o_, key_String] := If[AssociationQ[o], Replace[Lookup[o, key, <||>], Except[_Association] -> <||>], <||>];
iWGPostureCheck[] := Module[{role = iWGPostureRoleNow[], path, now = iWGPolicyPosture[], old, prev, changed = {}, iso = iWGNowIso[],
    since, newSince, rc, newRc, looseKeys},
  If[! StringQ[role], Return[<|"Role" -> None, "Changed" -> {}|>, Module]];
  path = iWGPosturePath[role];
  If[! StringQ[path], Return[<|"Role" -> role, "Changed" -> {}|>, Module]];
  old = iWGReadJSON[path];
  prev = If[AssociationQ[old], iWGPostureAssoc[old, "Posture"], None];
  If[AssociationQ[prev],
    changed = Select[Keys[now], Function[k, AssociationQ[Lookup[prev, k, None]] && Lookup[prev[k], "Value", ""] =!= now[k]["Value"]]];
    Scan[Function[k, Quiet @ Check[iWGNoteOwnerDecision[<|"Action" -> "PolicyChanged", "TargetKind" -> "Policy", "Target" -> k,
        "Direction" -> Which[now[k]["Loosened"] && ! TrueQ[Lookup[prev[k], "Loosened", False]], "Loosen",
          ! now[k]["Loosened"] && TrueQ[Lookup[prev[k], "Loosened", False]], "Tighten", True, "Neutral"],
        "Previous" -> <|"Value" -> ToString @ Lookup[prev[k], "Value", ""]|>, "New" -> <|"Value" -> now[k]["Value"]|>,
        "Via" -> "Detected", "Role" -> role|>], Null]], changed]];
  (* 緩めている設定ごとに「いつから」(気づいた時刻) と再確認の時刻を持つ。値が変わったら、数え直す *)
  looseKeys = Select[Keys[now], TrueQ[now[#]["Loosened"]] &];
  since = iWGPostureAssoc[old, "Since"]; rc = iWGPostureAssoc[old, "ReconfirmedAt"];
  newSince = Association[Function[k, k -> If[StringQ[Lookup[since, k, None]] && ! MemberQ[changed, k], since[k], iso]] /@ looseKeys];
  newRc = KeyTake[KeyDrop[rc, changed], looseKeys];
  If[! AssociationQ[prev] || changed =!= {} || newSince =!= since || newRc =!= rc,
    iWGWriteJSON[path, <|"At" -> iso, "Role" -> role, "Posture" -> now, "Since" -> newSince, "ReconfirmedAt" -> newRc|>]];
  <|"Role" -> role, "Changed" -> changed|>];
(* 役割ごとに覚えてある値 (設定の値・「いつから」・再確認の時刻)。記録が無ければ None。
   FE と service は同じ機の LocalState を使うので、FE から service の分も読める (service が最後に見た時点の値) *)
$iWGPostureRoles = {"FE", "Service"};
iWGPostureStoredFor[role_String] := With[{o = Quiet @ Check[iWGReadJSON[iWGPosturePath[role]], $Failed]},
  If[AssociationQ[o], <|"Posture" -> iWGPostureAssoc[o, "Posture"], "Since" -> iWGPostureAssoc[o, "Since"],
    "ReconfirmedAt" -> iWGPostureAssoc[o, "ReconfirmedAt"]|>, None]];
iWGPostureStoredFor[_] := None;

Options[SourceVaultOwnerDecisions] = {"Days" -> 30, "Direction" -> All, "Target" -> All, "Limit" -> All};
SourceVaultOwnerDecisions[OptionsPattern[]] := Module[{now = AbsoluteTime[], days = OptionValue["Days"], rs, dir = OptionValue["Direction"],
    tg = OptionValue["Target"], lim = OptionValue["Limit"]},
  If[! NumericQ[days] || days < 0, days = 30];
  rs = Select[iWGFixNull /@ iWGDecisionRead[],
    With[{a = iWGIsoToAbs[ToString @ Lookup[#, "At", ""]]}, NumericQ[a] && now - a <= days*86400] &];
  If[StringQ[dir], rs = Select[rs, Lookup[#, "Direction", ""] === dir &]];
  If[StringQ[tg], rs = Select[rs, Lookup[#, "Target", ""] === iWGNormHost[tg] || Lookup[#, "Target", ""] === tg &]];
  rs = Reverse @ iWGDecisionSorted[rs];
  If[IntegerQ[lim] && lim >= 0, Take[rs, UpTo[lim]], rs]];

(* いま緩めてあるもの: 所有者が許可したホスト (PrivateVault の profile。どの機で決めたものも入る) と、緩めた状態の設定 *)
iWGLoosenedNow[] := Module[{hosts, own = iWGPostureRoleNow[], pols = {}},
  iWGProfilesEnsureFresh[];
  (* "Since" は、所有者の設定が最後に変わった時刻 (PolicyChangedAt)。UpdatedAt は実績の再計算でも動くので使わない。
     V8 より前に許可したホストには無い = 「いつ許可したか分からない」として、最初の見直しに並ぶ *)
  hosts = KeyValueMap[Function[{h, p}, <|"Kind" -> "Host", "Target" -> h, "Level" -> With[{l = Lookup[p, "AccessLevel", None]}, If[NumericQ[l], N[l], -1.]],
        "ListOverride" -> TrueQ[Lookup[p, "ListOverride", False]], "Since" -> ToString @ Replace[Lookup[p, "PolicyChangedAt", ""], Except[_String] -> ""],
        "ReconfirmedAt" -> ToString @ Replace[Lookup[p, "ReconfirmedAt", ""], Except[_String] -> ""]|>],
    Select[If[AssociationQ[$iWGProfiles], $iWGProfiles, <||>],
      AssociationQ[#] && Lookup[#, "TrustStatus", ""] === "Approved" && Lookup[#, "PolicySource", ""] === "Owner" &]];
  (* 設定の切り替えは、役割のあるカーネル (FE・service) でだけ追う。試験やスクリプトのカーネルの値はその場かぎりなので、
     見直しの対象に入れない (今の値は "Posture" と WallHeight の "LoosenedSettings" で見える)。
     設定の値はカーネルごとなので、役割ごとに並べる: 自分の役割は今の値、もう一方 (FE から見た service など) は、
     そのカーネルが最後に覚えた値。MCP の経路の関所が使うのは service の値なので、FE の見直しにも service の分を出す *)
  If[StringQ[own],
    pols = Join @@ Map[Function[role, Module[{st = iWGPostureStoredFor[role], posture},
        posture = Which[role === own, iWGPolicyPosture[], AssociationQ[st], st["Posture"], True, <||>];
        If[! AssociationQ[st], st = <|"Since" -> <||>, "ReconfirmedAt" -> <||>|>];
        KeyValueMap[Function[{k, v}, <|"Kind" -> "Policy", "Target" -> k, "Role" -> role, "Value" -> ToString @ Lookup[v, "Value", ""],
            "Since" -> ToString @ Replace[Lookup[st["Since"], k, ""], Except[_String] -> ""],
            "ReconfirmedAt" -> ToString @ Replace[Lookup[st["ReconfirmedAt"], k, ""], Except[_String] -> ""]|>],
          Select[posture, AssociationQ[#] && TrueQ[Lookup[#, "Loosened", False]] &]]]], $iWGPostureRoles]];
  Join[hosts, pols]];
iWGReconfirmDueQ[item_Association, now_, days_] := Module[{t},
  If[! NumericQ[days] || days <= 0, Return[False, Module]];
  t = Max[Select[{iWGIsoToAbs[item["Since"]], iWGIsoToAbs[item["ReconfirmedAt"]]}, NumericQ]];
  (* いつ緩めたか分からないもの (設定の切り替えで、再確認の記録も無い) は、見直しの対象に入れる *)
  ! NumericQ[t] || now - t > days*86400];

Options[SourceVaultOwnerDecisionSummary] = {"Days" -> 30};
SourceVaultOwnerDecisionSummary[OptionsPattern[]] := Module[
  {now = AbsoluteTime[], days = OptionValue["Days"], rs, seq, loose, timed, fast, fastT = iWGPol["FastDecisionSeconds"], runs, byT, nowL, due,
   rdays = iWGPol["ReconfirmDays"], blocked, own = iWGPostureRoleNow[], known},
  If[! NumericQ[days] || days < 0, days = 30];
  If[! NumericQ[fastT], fastT = 5];
  Quiet @ Check[iWGPostureCheck[], Null];
  rs = SourceVaultOwnerDecisions["Days" -> days];
  (* 判断の列 (古い順)。再確認と、検出しただけの設定の切り替えは、「続けて緩めた回数」に数えない *)
  seq = Reverse @ Select[rs, ! MemberQ[{"Detected", "Review"}, Lookup[#, "Via", ""]] &];
  loose = Select[rs, Lookup[#, "Direction", ""] === "Loosen" &];
  timed = Select[loose, With[{s = Lookup[#, "Seconds", -1]}, NumericQ[s] && s >= 0] &];
  fast = Select[timed, Lookup[#, "Seconds", -1] < fastT &];
  runs = Length /@ Select[Split[Lookup[#, "Direction", ""] & /@ seq], First[#] === "Loosen" &];
  byT = GroupBy[Select[rs, Lookup[#, "TargetKind", ""] === "Host" &], ToString @ Lookup[#, "Target", ""] &];
  nowL = iWGLoosenedNow[];
  due = Select[nowL, iWGReconfirmDueQ[#, now, rdays] &];
  (* 設定の値を知っているカーネル: 自分の役割と、記録のあるもう一方 *)
  known = If[StringQ[own], Select[$iWGPostureRoles, # === own || AssociationQ[iWGPostureStoredFor[#]] &], {}];
  blocked = Count[If[AssociationQ[$iWGProfiles], Values[$iWGProfiles], {}], p_ /; AssociationQ[p] && Lookup[p, "TrustStatus", ""] === "Blocked"];
  <|"Days" -> days, "Decisions" -> Length[rs],
    "ByDirection" -> Counts[ToString @ Lookup[#, "Direction", "?"] & /@ rs], "ByVia" -> Counts[ToString @ Lookup[#, "Via", "?"] & /@ rs],
    (* この期間に緩めたもの。いまも有効か (その後に締め直していないか) を付ける *)
    "Loosened" -> Map[Function[r, Append[KeyTake[r, {"At", "DecisionId", "Action", "TargetKind", "Target", "Via", "Ref", "Seconds", "New", "Previous", "Role"}],
        "InEffect" -> Which[
          Lookup[r, "Persistent", True] === False, False,
          Lookup[r, "TargetKind", ""] === "Host", AnyTrue[nowL, #["Kind"] === "Host" && #["Target"] === Lookup[r, "Target", ""] &],
          (* 設定の値はカーネルごと。そのカーネルの値を知らないとき (役割の無いカーネルから見たとき、記録がまだ無いとき) は、
             今も有効かは分からない *)
          Lookup[r, "TargetKind", ""] === "Policy", If[MemberQ[known, Lookup[r, "Role", ""]],
            AnyTrue[nowL, #["Kind"] === "Policy" && #["Target"] === Lookup[r, "Target", ""] && Lookup[#, "Role", ""] === Lookup[r, "Role", ""] &],
            Missing["OtherKernel"]],
          True, False]]], loose],
    "WallHeight" -> <|"ApprovedHosts" -> Count[nowL, x_ /; x["Kind"] === "Host"],
      "ApprovedForPrivate" -> Count[nowL, x_ /; x["Kind"] === "Host" && x["Level"] >= N @ iWGPol["PrivatePL"]],
      "ListOverrides" -> Count[nowL, x_ /; x["Kind"] === "Host" && TrueQ[x["ListOverride"]]],
      "BlockedHosts" -> blocked,
      (* 既定より緩めている設定。役割のあるカーネルでは、もう一方のカーネルの分も (役割の名前を付けて) 入れる *)
      "LoosenedSettings" -> If[StringQ[own],
        (#["Target"] <> If[#["Role"] =!= own, " [" <> #["Role"] <> "]", ""]) & /@ Select[nowL, #["Kind"] === "Policy" &],
        Keys[Select[iWGPolicyPosture[], TrueQ[#["Loosened"]] &]]],
      (* 一回だけの許可・拒否 (Persistent False) は設定を変えないので、壁の高さには数えない *)
      "LoosenedInPeriod" -> Count[loose, r_ /; Lookup[r, "Persistent", True] =!= False],
      "OneTimeAllows" -> Count[loose, r_ /; Lookup[r, "Persistent", True] === False],
      "TightenedInPeriod" -> Count[rs, r_ /; Lookup[r, "Direction", ""] === "Tighten" && Lookup[r, "Persistent", True] =!= False]|>,
    "FastApprovals" -> <|"Count" -> Length[fast], "Of" -> Length[timed], "ThresholdSeconds" -> fastT,
      "Share" -> If[Length[timed] > 0, N[Length[fast]/Length[timed]], 0.]|>,
    "ConsecutiveLoosening" -> If[runs === {}, 0, Max[runs]],
    "Inconsistent" -> Keys @ Select[byT, MemberQ[Lookup[#, "Direction", ""], "Loosen"] && MemberQ[Lookup[#, "Direction", ""], "Tighten"] &],
    "LoosenedNow" -> nowL, "ReconfirmDue" -> due, "ReconfirmDays" -> rdays,
    (* V9 (7.3 節の「拒否の後の結果」): 関所が検索か取得を止めた依頼が、どういう回答で終わったか (裏付けの記録から) *)
    "RefusalOutcomes" -> With[{gs = Quiet @ Check[SourceVaultGroundingSummary["Days" -> days], $Failed]},
      If[AssociationQ[gs], gs["AfterRefusal"], <|"Requests" -> 0, "EndedUnconfirmed" -> 0, "EndedPartial" -> 0, "EndedGrounded" -> 0|>]],
    "Posture" -> iWGPolicyPosture[]|>];

(* 緩めた設定を「見直して、続ける」と記録する。設定は変えない *)
SourceVaultOwnerDecisionReconfirm[spec_] := Module[{pk = iWGPrincipalKind[], nowL, hosts, pols, polItems, iso = iWGNowIso[]},
  If[! MemberQ[{"OwnerFE", "OwnerCode"}, pk],
    Return[Failure["WebGuardNotAuthorized", <|"Function" -> "SourceVaultOwnerDecisionReconfirm", "Principal" -> pk,
      "MessageTemplate" -> "SourceVaultOwnerDecisionReconfirm may be called only by the owner; the current principal is `1`. From the front end use SourceVaultIntegrityOwnerAction[SourceVaultOwnerDecisionReconfirm[All]].",
      "MessageParameters" -> {pk}|>]]];
  Quiet @ Check[iWGPostureCheck[], Null];
  nowL = iWGLoosenedNow[];
  hosts = Which[
    spec === All, #["Target"] & /@ Select[nowL, #["Kind"] === "Host" &],
    ListQ[spec] && AllTrue[spec, StringQ], Intersection[iWGNormHost /@ spec, #["Target"] & /@ Select[nowL, #["Kind"] === "Host" &]],
    StringQ[spec], Intersection[{iWGNormHost[spec]}, #["Target"] & /@ Select[nowL, #["Kind"] === "Host" &]],
    True, Return[Failure["BadArguments", <|"Function" -> "SourceVaultOwnerDecisionReconfirm"|>]]];
  polItems = If[spec === All, Select[nowL, #["Kind"] === "Policy" &], {}];
  pols = DeleteDuplicates[#["Target"] & /@ polItems];
  Scan[Function[h, $iWGProfiles[h] = Append[$iWGProfiles[h], "ReconfirmedAt" -> iso]], hosts];
  If[hosts =!= {}, iWGProfilesSave[]];
  (* 設定の再確認は、役割 (カーネル) ごとの記録に書く。FE から service の分も書ける (同じ機の LocalState) *)
  Scan[Function[grp, Module[{role = First[grp]["Role"], keys = #["Target"] & /@ grp, path, old},
      path = iWGPosturePath[role]; old = If[StringQ[path], iWGReadJSON[path], $Failed];
      If[AssociationQ[old], iWGWriteJSON[path, Append[old, "ReconfirmedAt" ->
        Join[iWGPostureAssoc[old, "ReconfirmedAt"], AssociationThread[keys, ConstantArray[iso, Length[keys]]]]]]]]],
    GatherBy[polItems, #["Role"] &]];
  iWGNoteOwnerDecision[<|"Action" -> "Reconfirm", "Direction" -> "Neutral", "TargetKind" -> "Review", "Target" -> If[spec === All, "All", "Hosts"],
    "Via" -> "Review", "Hosts" -> Length[hosts], "Settings" -> Length[polItems]|>];
  $iWGProbeCache = <||>;
  <|"Status" -> "Reconfirmed", "Hosts" -> hosts, "Settings" -> pols, "At" -> iso|>];
SourceVaultOwnerDecisionReconfirm[___] := Failure["BadArguments", <|"Function" -> "SourceVaultOwnerDecisionReconfirm"|>];

(* ------------------------------------------------------------
   V9 (文書 12 の 4.6 節、2026-11-13): 裏付けの検査の記録と指標
   ------------------------------------------------------------
   ツールループ (claudecode) は、回答ごとに裏付けの検査の結果を出す。ここでは、それを会話ごとに残して指標を作る。
   - 置き場は LocalState/hotlog/grounding/YYYY-MM-p<pid>.jsonl (関所の記録と同じく機ごと)。
   - 入れるもの: 判定 (Status・PartialReason・規則)、件数 (検索・取得・関所が止めた数・照合した数)、差し戻しの有無、
     回答の SHA-256 (印を付ける前と後)、会話の ID、時刻。依頼文・検索語・回答の本文・ホスト名・URL は入れない
     (決まった鍵だけを受け取る)。
   - 指標: 外部の事実が要る回答のうち未確認のままの割合 (UngroundedRate)、差し戻しで直った数、照合の結果、
     関所が要求を止めた依頼が未確認の回答で終わった数 (7.3 節の「拒否の後の結果」)。見るためのもので、何も止めない。
   - 文章からの引き当て (SourceVaultGroundingOfText): 回答の SHA-256 が記録にあればその判定、無ければ先頭の印 (「外部で未確認」など)。
     自動の取り込み (TurnWiki など) が、未確認の回答を知識に入れないために使う。 *)
iWGGroundingDir[] := iWGSub[iWGLocalStateDir[], "hotlog", "grounding"];
$iWGGroundingKeys = {"Status", "PartialReason", "Rule", "Searches", "SearchesWithResults", "SearchesRefused", "BackendFailures", "Fetched",
  "FetchFailed", "FetchRefused", "Internal", "FallbackSearches", "SentBack", "ClaimsChecked", "ClaimsSupported", "Cited", "CitedVerified",
  "OutputSHA256", "FinalSHA256", "LLMCallOutputSHA256", "ConversationId", "AtUTC", "AtUnixMs", "Machine"};
$iWGGroundingStatuses = {"Grounded", "Partial", "Ungrounded", "BackendUnavailable", "WebNotAvailable", "NotApplicable", "NotNeeded"};
(* ラベルの値 (文書 12 の 4.6 節): 検索の障害・外部検索が使えない会話・検索のツールが無い接続も「外部で未確認」に入れる *)
iWGGroundingClass[status_] := Switch[status,
  "Grounded", "Grounded", "Partial", "Partial", "NotNeeded", "NotNeeded",
  "Ungrounded" | "BackendUnavailable" | "WebNotAvailable" | "NotApplicable", "Ungrounded", _, "Unknown"];
If[! AssociationQ[$iWGGroundingIndex], $iWGGroundingIndex = <|"At" -> 0, "Map" -> <||>|>];
SourceVaultGroundingNote[rec_Association] := Module[{dir = iWGGroundingDir[], r, line, path},
  If[! MemberQ[$iWGGroundingStatuses, Lookup[rec, "Status", None]], Return[<|"Noted" -> False, "Reason" -> "InvalidStatus"|>, Module]];
  (* 決まった鍵だけを、決まった型で受け取る (本文や URL が紛れ込まないように) *)
  r = Association @ KeyValueMap[Function[{k, v}, Which[
      MemberQ[{"Status", "PartialReason", "Rule", "ConversationId", "AtUTC", "Machine"}, k],
        If[StringQ[v] && StringLength[v] <= 120 && StringFreeQ[v, "http" | "\n"], k -> v, Nothing],
      MemberQ[{"OutputSHA256", "FinalSHA256", "LLMCallOutputSHA256"}, k],
        If[StringQ[v] && StringMatchQ[v, RegularExpression["^[0-9a-fA-F]{64}$"]], k -> ToLowerCase[v], Nothing],
      k === "SentBack", k -> TrueQ[v],
      True, If[IntegerQ[v] && v >= 0, k -> v, Nothing]]], KeyTake[rec, $iWGGroundingKeys]];
  If[! StringQ[Lookup[r, "AtUTC", None]], r["AtUTC"] = iWGNowIso[]];
  If[! StringQ[Lookup[r, "Machine", None]], r["Machine"] = iWGMachineTag[]];
  If[! StringQ[dir], Return[<|"Noted" -> False, "Reason" -> "NoLocalState"|>, Module]];
  line = iWGToJSON[r];
  path = iWGSub[dir, DateString[TimeZoneConvert[Now, 0], {"Year", "-", "Month"}] <> "-p" <> ToString[$ProcessID] <> ".jsonl"];
  If[! StringQ[line] || iWGAppendLine[path, line] === $Failed, Return[<|"Noted" -> False, "Reason" -> "WriteFailed"|>, Module]];
  $iWGGroundingIndex = <|"At" -> 0, "Map" -> <||>|>;
  <|"Noted" -> True, "Status" -> r["Status"]|>];
SourceVaultGroundingNote[___] := <|"Noted" -> False, "Reason" -> "InvalidArguments"|>;

Options[SourceVaultGroundingLog] = {"Days" -> 30, "Status" -> All, "Limit" -> All};
SourceVaultGroundingLog[OptionsPattern[]] := Module[{dir = iWGGroundingDir[], now = AbsoluteTime[], days = OptionValue["Days"], rs,
    st = OptionValue["Status"], lim = OptionValue["Limit"]},
  If[! NumericQ[days] || days < 0, days = 30];
  If[! StringQ[dir] || ! DirectoryQ[dir], Return[{}, Module]];
  rs = Select[iWGFixNull /@ (Join @@ (iWGReadJSONL /@ FileNames["*.jsonl", dir])),
    AssociationQ[#] && With[{a = iWGIsoToAbs[ToString @ Lookup[#, "AtUTC", ""]]}, NumericQ[a] && now - a <= days*86400] &];
  If[StringQ[st], rs = Select[rs, Lookup[#, "Status", ""] === st || iWGGroundingClass[Lookup[#, "Status", ""]] === st &]];
  rs = Reverse @ SortBy[rs, {ToString @ Lookup[#, "AtUTC", ""] &, Replace[Lookup[#, "AtUnixMs", 0], Except[_Integer] -> 0] &}];
  If[IntegerQ[lim] && lim >= 0, Take[rs, UpTo[lim]], rs]];

Options[SourceVaultGroundingSummary] = {"Days" -> 30};
SourceVaultGroundingSummary[OptionsPattern[]] := Module[{days = OptionValue["Days"], rs, needed, cls, n, unconf, partial, sent, refused, int},
  If[! NumericQ[days] || days < 0, days = 30];
  rs = SourceVaultGroundingLog["Days" -> days];
  int = Function[{r, k}, Replace[Lookup[r, k, 0], Except[_Integer] -> 0]];
  cls = iWGGroundingClass[Lookup[#, "Status", ""]] & /@ rs;
  (* 分母は「外部の事実が要る回答」(NotNeeded を除く) *)
  needed = Pick[rs, (# =!= "NotNeeded" && # =!= "Unknown") & /@ cls];
  n = Length[needed];
  unconf = Select[needed, iWGGroundingClass[Lookup[#, "Status", ""]] === "Ungrounded" &];
  partial = Select[needed, Lookup[#, "Status", ""] === "Partial" &];
  sent = Select[needed, TrueQ[Lookup[#, "SentBack", False]] &];
  (* 関所が、検索か取得を 1 回でも止めた依頼 *)
  refused = Select[needed, int[#, "SearchesRefused"] + int[#, "FetchRefused"] > 0 &];
  <|"Days" -> days, "Total" -> Length[rs], "NotNeeded" -> Count[cls, "NotNeeded"], "Needed" -> n,
    "ByStatus" -> Counts[ToString @ Lookup[#, "Status", "?"] & /@ rs],
    "Grounded" -> Count[needed, r_ /; Lookup[r, "Status", ""] === "Grounded"], "Partial" -> Length[partial], "Unconfirmed" -> Length[unconf],
    "UngroundedRate" -> If[n > 0, N[Length[unconf]/n], Missing["NoData"]],
    "PartialRate" -> If[n > 0, N[Length[partial]/n], Missing["NoData"]],
    "PartialByReason" -> Counts[ToString @ Lookup[#, "PartialReason", "?"] & /@ partial],
    "SentBack" -> <|"Count" -> Length[sent], "EndedGrounded" -> Count[sent, r_ /; Lookup[r, "Status", ""] === "Grounded"],
      "EndedUnconfirmed" -> Count[sent, r_ /; iWGGroundingClass[Lookup[r, "Status", ""]] === "Ungrounded"]|>,
    "Claims" -> <|"Checked" -> Total[int[#, "ClaimsChecked"] & /@ needed], "Supported" -> Total[int[#, "ClaimsSupported"] & /@ needed]|>,
    "Citations" -> <|"Cited" -> Total[int[#, "Cited"] & /@ needed], "Verified" -> Total[int[#, "CitedVerified"] & /@ needed]|>,
    (* 7.3 節の「拒否の後の結果」: 関所が要求を止めた依頼のうち、未確認の回答で終わったもの *)
    "AfterRefusal" -> <|"Requests" -> Length[refused],
      "EndedUnconfirmed" -> Count[refused, r_ /; iWGGroundingClass[Lookup[r, "Status", ""]] === "Ungrounded"],
      "EndedPartial" -> Count[refused, r_ /; Lookup[r, "Status", ""] === "Partial"],
      "EndedGrounded" -> Count[refused, r_ /; Lookup[r, "Status", ""] === "Grounded"]|>|>];

(* 文章 (回答) の裏付けの判定を引き当てる。claudecode の iClaudeProvTextSHA と同じ正規化 (先頭 BOM を除く・改行は LF) で SHA-256 を取る *)
iWGTextSHA[s_String] := Hash[StringToByteArray[StringReplace[StringDelete[s, StartOfString ~~ "\:feff"], {"\r\n" -> "\n", "\r" -> "\n"}], "UTF-8"],
  "SHA256", "HexString"];
iWGGroundingIndexEnsure[] := Module[{now = AbsoluteTime[], m = <||>},
  If[now - Lookup[$iWGGroundingIndex, "At", 0] < 60, Return[$iWGGroundingIndex["Map"], Module]];
  Scan[Function[r, With[{c = iWGGroundingClass[Lookup[r, "Status", ""]]},
      Scan[Function[k, With[{h = Lookup[r, k, None]}, If[StringQ[h], m[h] = c]]], {"OutputSHA256", "FinalSHA256", "LLMCallOutputSHA256"}]]],
    Reverse @ SourceVaultGroundingLog["Days" -> 400]];
  $iWGGroundingIndex = <|"At" -> now, "Map" -> m|>;
  m];
(* 先頭の印 (claudecode の iGroundingNoticeText が書く 1 行)。⚠ = 外部で未確認、△ = 一部だけ、✓ = ウェブの資料あり *)
iWGGroundingMark[text_String] := Module[{line = First[Select[StringSplit[StringTake[text, UpTo[2000]], "\n"], StringTrim[#] =!= "" &], ""]},
  Which[
    ! StringContainsQ[line, "[SourceVault]"], None,
    StringContainsQ[line, "[SourceVault] \:26a0"], "Ungrounded",
    StringContainsQ[line, "[SourceVault] \:25b3"], "Partial",
    StringContainsQ[line, "[SourceVault] \:2713"], "Grounded",
    True, None]];
iWGStripGroundingMark[text_String] :=
  StringReplace[text, RegularExpression["\\A\\s*\\*\\*\\[SourceVault\\][^\\n]*\\n\\n?"] -> "", 1];
SourceVaultGroundingOfText[text_String] := Module[{m = iWGGroundingIndexEnsure[], h, mark},
  h = SelectFirst[{iWGTextSHA[text], iWGTextSHA[iWGStripGroundingMark[text]]}, KeyExistsQ[m, #] &, None];
  mark = iWGGroundingMark[text];
  Which[
    StringQ[h], <|"Grounding" -> m[h], "Source" -> "Record"|>,
    StringQ[mark], <|"Grounding" -> mark, "Source" -> "Mark"|>,
    True, <|"Grounding" -> "Unknown", "Source" -> None|>]];
SourceVaultGroundingOfText[_] := <|"Grounding" -> "Unknown", "Source" -> None|>;

(* ------------------------------------------------------------
   View (Dataset + 行数制限 + privacy 層の正準 exit、弱結合)
   ------------------------------------------------------------ *)
iWGPrivView[expr_, pl_] :=
  If[Length[DownValues[SourceVault`SourceVaultPrivateView]] > 0 && NumericQ[pl] && pl >= 0.5,
    SourceVault`SourceVaultPrivateView[expr, pl], expr];

iWGShort[s_, n_Integer] := With[{t = ToString[s /. _Missing -> ""]}, If[StringLength[t] > n, StringTake[t, n] <> "...", t]];

iWGLogRow[r_Association] := <|
  "日時" -> iWGLocalTimeString[ToString @ Lookup[r, "At", ""]],
  "種別" -> Switch[Lookup[r, "Kind", ""], "Search", "検索", "Fetch", "取得", _, ToString @ Lookup[r, "Kind", ""]],
  "主体" -> iWGShort[Lookup[r, "ActorDisplay", Lookup[r, "ActorId", ""]], 40],
  "ホスト" -> iWGShort[Lookup[r, "Host", ""], 40],
  "対象" -> iWGShort[Lookup[r, "Url", Lookup[r, "Query", ""]], 90],
  "文脈PL" -> Lookup[r, "ContextPL", Missing[]],
  "不審度" -> Lookup[r, "Suspicion", Missing[]],
  "判定" -> ToString @ Lookup[r, "Decision", ""] <>
    If[StringQ @ Lookup[r, "DecisionDetail", None], "/" <> r["DecisionDetail"], ""],
  "理由" -> iWGShort[Lookup[r, "DecisionReason", ""], 40]|>;

SourceVaultWebAccessLogView[opts : OptionsPattern[SourceVaultWebAccessLog]] := Module[{recs, rows, maxPL, ds, n},
  recs = SourceVaultWebAccessLog[opts];
  n = Length[recs];
  maxPL = iWGMaxPL[recs];
  rows = iWGLogRow /@ Take[recs, UpTo[$SourceVaultWebAccessViewMaxRows]];
  ds = If[rows === {}, Style["(該当するアクセスはありません)", Gray],
    Dataset[rows, MaxItems -> {$SourceVaultWebAccessViewMaxRows, All}]];
  iWGPrivView[Column[{
    Style["LLM Web アクセスログ (" <> ToString[n] <> " 件" <>
      If[n > $SourceVaultWebAccessViewMaxRows, "、先頭 " <> ToString[$SourceVaultWebAccessViewMaxRows] <> " 件を表示", ""] <> ")", Bold],
    Pane[ds, {Automatic, UpTo[600]}, Scrollbars -> Automatic]}], maxPL]];

SourceVaultWebAccessSummaryView[opts : OptionsPattern[SourceVaultWebAccessSummary]] := Module[
  {sm, rs, hostRows, actorRows},
  sm = SourceVaultWebAccessSummary[opts];
  rs = sm["ReviewStatus"];
  hostRows = ReverseSortBy[KeyValueMap[<|"ホスト" -> #1, "回数" -> #2["Count"], "許可" -> #2["Allowed"],
      "拒否" -> #2["Denied"], "保留" -> #2["Pending"], "不審" -> #2["Suspicious"], "主体数" -> #2["Actors"],
      "最大文脈PL" -> #2["MaxContextPL"], "レベル" -> #2["Level"], "状態" -> #2["TrustStatus"],
      "新規" -> If[MemberQ[sm["NewHosts"], #1], "新", ""]|> &, sm["ByHost"]], #["回数"] &];
  actorRows = ReverseSortBy[KeyValueMap[<|"主体" -> #2["Display"], "種類" -> #2["Kind"], "回数" -> #2["Count"],
      "許可" -> #2["Allowed"], "拒否" -> #2["Denied"], "保留" -> #2["Pending"], "不審" -> #2["Suspicious"],
      "ホスト数" -> #2["Hosts"], "最大文脈PL" -> #2["MaxContextPL"], "Id" -> #1|> &, sm["ByActor"]], #["回数"] &];
  iWGPrivView[Column[{
    Style["LLM Web アクセス サマリー (" <> iWGLocalTimeString[sm["Since"]] <> " 〜 " <> iWGLocalTimeString[sm["Until"]] <> ")", Bold, 13],
    Row[{"合計 ", sm["Total"], "   検索 ", Lookup[sm["ByKind"], "Search", 0], "   取得 ", Lookup[sm["ByKind"], "Fetch", 0],
      "   不審 ", sm["Suspicious"], "   拒否 ", Lookup[sm["ByDecision"], "Deny", 0],
      "   保留 ", Lookup[sm["ByDecision"], "Pending", 0], "   新規ホスト ", Length[sm["NewHosts"]],
      "   未決 ", sm["PendingRequests"]}],
    Row[{"前回レビュー: ", If[StringQ[rs["LastReviewedAt"]], iWGLocalTimeString[rs["LastReviewedAt"]], "(未実施)"],
      If[TrueQ[rs["Due"]], Style["   レビュー期限超過", Bold, RGBColor[0.8, 0.1, 0.1]], ""],
      "    ",
      Button["レビュー済みにする",
        Module[{rr = SourceVaultWebAccessMarkReviewed[]},
          Print[Style["[WebGuard] レビューを記録しました: " <> ToString @ Lookup[rr, "LastReviewedAtUTC", ""], 10]]],
        Method -> "Queued"]}],
    (* V8: 所有者の判断の見直し (この期間に緩めたもの・再確認が要るもの) への入口。式を下のセルに置く *)
    With[{ow = Replace[Lookup[sm, "OwnerReview", <||>], Except[_Association] -> <||>]},
      Row[{"所有者の判断: この期間に緩めた ", Lookup[ow, "LoosenedInPeriod", 0], " 件   いま緩めてある ", Lookup[ow, "LoosenedNow", 0],
        " 件   再確認が要る ", If[Lookup[ow, "ReconfirmDue", 0] > 0, Style[Lookup[ow, "ReconfirmDue", 0], Bold, RGBColor[0.8, 0.1, 0.1]], 0], " 件    ",
        iWGTemplateButton["見直しを開く", SourceVault`SourceVaultOwnerDecisionReviewView[]]}]],
    (* V9: 指標 (裏付けの検査・止めた割合・所有者に尋ねた回数)。見るためのもの *)
    With[{g = Replace[Lookup[sm, "Grounding", <||>], Except[_Association] -> <||>], ind = Replace[Lookup[sm, "Indicators", <||>], Except[_Association] -> <||>],
        pct = Function[x, If[NumericQ[x], ToString[Round[100 x]] <> "%", "—"]]},
      Row[{"裏付け: 外部の事実が要る回答 ", Lookup[g, "Needed", 0], " 件のうち、未確認のまま ", Lookup[g, "Unconfirmed", 0], " 件 (",
        pct[Lookup[g, "UngroundedRate", None]], ")・一部だけ ", Lookup[g, "Partial", 0], " 件     止めた割合 ", pct[Lookup[ind, "DenyRate", None]],
        "   所有者に尋ねた回数 ", Lookup[ind, "OwnerAsked", 0]}]],
    (* V11: 検索の送り先 (12 章の 17 の再評価の材料) と、機密の語で見つけたページの取得 (12 章の 18、止めずに数える) *)
    With[{sr = Replace[Lookup[sm, "SearchRoutes", <||>], Except[_Association] -> <||>],
        fw = Replace[Lookup[sm, "FoundWithPrivateTerms", <||>], Except[_Association] -> <||>]},
      Row[{"検索の送り先: 検索エンジンだけ ", Lookup[sr, "EnginesOnly", 0], " 件 (機密の語を含む ", Lookup[sr, "WithPrivateTerms", 0],
        " 件)・記録の語で止めた ", Lookup[sr, "RecordTermRefused", 0], " 件 (境 PL ", ToString @ Lookup[sr, "SearchTermMaxPL", "—"],
        ")     機密の語で見つけたページの取得 ", Lookup[fw, "Fetched", 0], " 件 (評判の分からないホスト ",
        Lookup[fw, "UnknownReputation", 0], " 件・", Lookup[fw, "Hosts", 0], " ホスト)"}]],
    Style["ホスト別", Bold],
    If[hostRows === {}, Style["(なし)", Gray], Dataset[hostRows, MaxItems -> {$SourceVaultWebAccessViewMaxRows, All}]],
    Style["主体別", Bold],
    If[actorRows === {}, Style["(なし)", Gray], Dataset[actorRows]]}, Spacings -> 1],
    sm["MaxContextPL"]]];

SourceVaultWebHostProfilesView[] := Module[{vs = SourceVaultWebHostProfiles[], rows},
  rows = <|"ホスト" -> #["Host"], "レベル" -> #["EffectiveLevel"], "保存値" -> #["AccessLevel"],
     "状態" -> #["TrustStatus"], "出所" -> #["PolicySource"], "回数" -> #["AccessCount"], "日数" -> #["DistinctDays"],
     "不審" -> #["Suspicious"], "拒否" -> #["Denied"], "実績十分" -> #["Established"],
     "初回" -> iWGLocalTimeString[ToString[#["FirstSeen"] /. _Missing -> ""]],
     "最終" -> iWGLocalTimeString[ToString[#["LastSeen"] /. _Missing -> ""]]|> & /@ vs;
  If[rows === {}, Style["(既知ホストはありません)", Gray],
    Column[{Style["Web ホスト profile (" <> ToString[Length[rows]] <> ")", Bold],
      Dataset[rows, MaxItems -> {$SourceVaultWebAccessViewMaxRows, All}]}]]];

(* ---- V7 (文書 12 の 7.2 節): 方針の提案の表示 ----
   選択肢のボタンは、記入済みの式テンプレートを下のセルに置くだけで、評価はしない (式中心の UI。integrityview と同じやり方)。
   所有者の操作は SourceVaultIntegrityOwnerAction[...] で包む。提案は多くても 1 日 5 件なので、Dataset は使わず Grid で組む
   (Dataset の中のボタンは、列の位置や式の大きさで押せなくなることがある)。 *)
iWGInsertTemplate[h : HoldComplete[_]] := Module[{boxes, nb, idx},
  boxes = Replace[h, HoldComplete[x_] :> MakeBoxes[x, StandardForm]];
  If[Length[DownValues[NBAccess`NBInsertInputTemplate]] === 0, Return[$Failed]];
  nb = Quiet @ Check[NBAccess`NBParentNotebookOfCurrentCell[], $Failed];
  If[Head[nb] =!= NotebookObject, Return[$Failed]];
  idx = Quiet @ Check[NBAccess`NBCurrentCellIndex[nb], 0];
  If[IntegerQ[idx] && idx > 0, NBAccess`NBMoveAfterCell[nb, idx]];
  NBAccess`NBInsertInputTemplate[nb, boxes]];
SetAttributes[iWGTemplateButton, HoldRest];
iWGTemplateButton[label_, expr_] := Button[Style[label, 10], iWGInsertTemplate[HoldComplete[expr]], Appearance -> "Frameless",
  Method -> "Queued", BaseStyle -> {FontColor -> RGBColor[0.15, 0.35, 0.70]}];
iWGPVText[s_] := Style[ToString[s], "Text", 11];
iWGPVSmall[s_] := Style[ToString[s], "Text", 9, GrayLevel[0.45]];
iWGProposalMaterialRows[p_Association] := Module[
  {m = Replace[Lookup[p, "Material", <||>], Except[_Association] -> <||>], fetch = Lookup[p, "Kind", ""] === "Fetch", rows = {}, listed, lv},
  If[fetch,
    listed = Replace[Lookup[m, "Listed", {}], Except[_List] -> {}];
    lv = Lookup[m, "HostLevel", -1];
    rows = {
      {"実在の確認", Switch[Lookup[m, "HostCheck", "NotChecked"], "Exists", "実在する (DNS で引けた)", "NotExist", "実在しない",
        "Unavailable", "確かめられなかった", _, "確かめていない"]},
      {"評判", Switch[Lookup[m, "Reputation", ""], "Malicious", "悪性 (リストに掲載)", "Suspicious", "不審 (リストに掲載)", "Good", "良好",
          "Neutral", "どのリストにも無い", _, "不明"] <>
        If[listed =!= {}, "  [" <> StringRiffle[ToString /@ listed, ", "] <> "]", ""] <>
        If[Lookup[m, "Verifier", "OK"] =!= "OK", "  (評判のリストが未取得か期限切れ)", ""]},
      If[StringQ[Lookup[m, "Lookalike", ""]] && Lookup[m, "Lookalike", ""] =!= "", {"似た名前", "既知のホスト " <> m["Lookalike"] <> " と 1 文字違い"}, Nothing],
      {"実績", ToString @ Lookup[m, "AccessCount", 0] <> " 回" <>
        With[{f = Lookup[m, "FirstSeen", ""]}, If[StringQ[f] && f =!= "", "、初回 " <> iWGLocalTimeString[f], ""]]},
      {"所有者の設定", Switch[Lookup[m, "TrustStatus", "Observed"],
        "Approved", "許可済み" <> If[NumericQ[lv] && lv >= 0, " (機密度 " <> ToString[NumberForm[N[lv], {3, 2}]] <> " まで)", ""],
        "Blocked", "遮断中", _, "なし"]}}];
  Join[rows, {
    {"止まったときの機密度", "最大 " <> ToString[NumberForm[N @ Replace[Lookup[p, "MaxContextPL", 0.], Except[_?NumericQ] -> 0.], {3, 2}]]},
    {"主体", StringRiffle[ToString /@ Replace[Lookup[p, "Actors", {}], Except[_List] -> {}], ", "]},
    {If[fetch, "URL の例", "検索語の例"], Column[
      Join[iWGPVText /@ (ToString /@ Replace[Lookup[p, "Examples", {}], Except[_List] -> {}]), {iWGPVSmall["モデルが組み立てたものです"]}],
      Spacings -> 0.2]}}]];
iWGProposalPanel[p_Association] := Module[{id = ToString @ Lookup[p, "ProposalId", ""], fetch = Lookup[p, "Kind", ""] === "Fetch", opts},
  opts = ToString /@ Replace[Lookup[p, "Options", {}], Except[_List] -> {}];
  Framed[Column[{
    Row[{Style[If[fetch, ToString @ Lookup[p, "Target", ""], "検索語"], Bold, 13], "   ",
      iWGPVText[iWGReasonTextJa[ToString @ Lookup[p, "Reason", ""], ToString @ Lookup[p, "Kind", "Fetch"]]]}],
    iWGPVSmall["直近 " <> ToString @ iWGPol["ProposalWindowDays"] <> " 日で " <> ToString @ Lookup[p, "Count", 0] <> " 回、会話 " <>
      ToString @ Lookup[p, "Conversations", 0] <> " つ。最初 " <> iWGLocalTimeString[ToString @ Lookup[p, "FirstAt", ""]] <> "、最後 " <>
      iWGLocalTimeString[ToString @ Lookup[p, "LastAt", ""]] <> "。期限 " <> iWGLocalTimeString[ToString @ Lookup[p, "ExpiresAtUTC", ""]] <>
      "  (" <> id <> ")"],
    Grid[{iWGPVSmall[#[[1]]], If[StringQ[#[[2]]], iWGPVText[#[[2]]], #[[2]]]} & /@ iWGProposalMaterialRows[p],
      Alignment -> {Left, Top}, Spacings -> {1.5, 0.4}],
    Grid[Function[c, {With[{i = id, ch = c},
          iWGTemplateButton[iWGProposalChoiceLabel[c],
            SourceVault`SourceVaultIntegrityOwnerAction[SourceVault`SourceVaultPolicyProposalResolve[i, ch]]]],
        iWGPVText[iWGProposalEffectText[c, p]]}] /@ opts,
      Alignment -> {Left, Top}, Spacings -> {1.5, 0.4}, Dividers -> {False, {True, False}}]},
    Spacings -> 0.8], FrameStyle -> GrayLevel[0.8], RoundingRadius -> 4, FrameMargins -> 10]];
SourceVaultPolicyProposalsView[] := Module[{ps, all, deferred, maxPL},
  ps = Quiet @ Check[SourceVaultPolicyProposals["Status" -> "Open"], {}];
  If[! ListQ[ps], ps = {}];
  all = Values[iWGProposalsReadAll[]];
  deferred = Count[all, q_ /; Lookup[q, "Status", ""] === "Deferred"];
  If[ps === {},
    Return[Panel[Column[{Style["方針の提案", Bold, 13],
      iWGPVText["いま答える提案はありません。" <> If[deferred > 0, " (後日に回しているものが " <> ToString[deferred] <> " 件あります)", ""]]}]]]];
  maxPL = Max[0., Select[Lookup[#, "MaxContextPL", 0] & /@ ps, NumericQ]];
  iWGPrivView[Column[Join[{
      Style["方針の提案 (" <> ToString[Length[ps]] <> " 件" <> If[deferred > 0, "、ほかに " <> ToString[deferred] <> " 件を後日に回しています", ""] <> ")", Bold, 13],
      iWGPVSmall["関所が繰り返し止めた対象です。答えなければ現状のまま (止めたまま) で、期限が来たら取り下げます。" <>
        "青い字のボタンは、答えの式を下のセルに置きます。その式を評価すると反映されます。"]},
    iWGProposalPanel /@ ps], Spacings -> 1], maxPL]];

(* ---- V8 (文書 12 の 7.3 節): 所有者の判断の見直しの表示 ----
   壁の高さ・指標・この期間に緩めたもの・再確認が要るものを並べる。操作 (まとめて再確認・許可をやめる) は、式を下のセルに置くだけ。
   行は多くても数十なので Grid で組む。載せるのはホストの名前と決めた内容だけで、検索語や URL は載せない。 *)
iWGDecisionActionJa[a_] := Switch[ToString[a],
  "AllowHost", "許可", "AllowDespiteList", "リストを承知で許可", "RaiseLevel", "機密度を上げた", "LowerLevel", "機密度を下げた",
  "Unblock", "遮断を解いた", "BlockHost", "遮断", "Revoke", "許可をやめた", "AllowOnce", "一回だけ許可", "Deny", "拒否",
  "Keep", "このまま", "PolicyChanged", "設定の切り替え", "Reconfirm", "再確認", "SetAccess", "設定", _, ToString[a]];
iWGDecisionViaJa[v_] := Switch[ToString[v],
  "PolicyProposal", "提案への回答", "Dialog", "承認の窓", "Direct", "直接", "Review", "見直し", "Detected", "検出", _, ToString[v]];
iWGPostureLabelJa[k_] := Switch[ToString[k],
  "GuardEnabled", "関所を使う ($SourceVaultWebGuardEnabled)",
  "GuardRequired", "関所が無ければ止める ($SourceVaultWebGuardRequired)",
  "PrivateStage", "機密を読んだ後の扱い ($SourceVaultWebGuardPrivateStage)",
  "Prompter", "承認の尋ね方 ($SourceVaultWebGuardPrompter)",
  "HostCheck", "実在の確認 (HostCheck)", "Reputation", "評判の確認 (Reputation)",
  "DNSFilter", "フィルタ付きの DNS ($SourceVaultWebReputationDNSFilter)",
  _, "関所の設定 " <> ToString[k]];
iWGDecisionTargetText[r_Association] := Switch[ToString @ Lookup[r, "TargetKind", ""],
  (* 設定の値はカーネルごと。service のカーネルで気づいた切り替えには、そう書き添える (MCP の経路の関所が使う値) *)
  "Policy", iWGPostureLabelJa[Lookup[r, "Target", ""]] <> If[Lookup[r, "Role", ""] === "Service", "  [service のカーネル]", ""],
  "Search", "検索語", _, ToString @ Lookup[r, "Target", ""]];
iWGLevelText[lv_] := If[NumericQ[lv] && lv >= 0, "機密度 " <> ToString[NumberForm[N[lv], {3, 2}]] <> " まで", ""];
iWGDecisionChangeText[r_Association] := Module[
  {n = Replace[Lookup[r, "New", <||>], Except[_Association] -> <||>], b = Replace[Lookup[r, "Previous", <||>], Except[_Association] -> <||>], act},
  act = ToString @ Lookup[r, "Action", ""];
  iWGDecisionActionJa[act] <> Which[
    Lookup[r, "TargetKind", ""] === "Policy", "  " <> ToString @ Lookup[b, "Value", "?"] <> " → " <> ToString @ Lookup[n, "Value", "?"],
    MemberQ[{"AllowHost", "AllowDespiteList", "RaiseLevel", "LowerLevel"}, act] && iWGLevelText[Lookup[n, "Level", -1]] =!= "",
      " (" <> iWGLevelText[Lookup[n, "Level", -1]] <> ")",
    True, ""]];
iWGSecondsText[s_] := If[NumericQ[s] && s >= 0, ToString[Round[s]] <> " 秒", "—"];
Options[SourceVaultOwnerDecisionReviewView] = {"Days" -> 30};
SourceVaultOwnerDecisionReviewView[OptionsPattern[]] := Module[
  {sm, wh, fa, loose, due, days, maxRows = 40, defLv = N @ iWGPol["DefaultHostLevel"], hd, looseGrid, dueGrid, incons},
  sm = Quiet @ Check[SourceVaultOwnerDecisionSummary["Days" -> OptionValue["Days"]], $Failed];
  If[! AssociationQ[sm], Return[Style["(所有者の判断の集計を作れませんでした)", Gray]]];
  wh = sm["WallHeight"]; fa = sm["FastApprovals"]; loose = sm["Loosened"]; due = sm["ReconfirmDue"]; days = sm["Days"];
  incons = sm["Inconsistent"];
  hd = Function[s, Style[s, Bold, 10, GrayLevel[0.35]]];
  looseGrid = If[loose === {}, iWGPVText["(この期間に緩めたものはありません)"],
    Grid[Join[{hd /@ {"日時", "対象", "決めたこと", "経路", "決めるまで", "いま"}},
        Function[r, {iWGPVSmall[iWGLocalTimeString[ToString @ Lookup[r, "At", ""]]], iWGPVText[iWGDecisionTargetText[r]],
            iWGPVText[iWGDecisionChangeText[r]], iWGPVSmall[iWGDecisionViaJa[Lookup[r, "Via", ""]]],
            iWGPVSmall[iWGSecondsText[Lookup[r, "Seconds", -1]]],
            iWGPVSmall[Which[TrueQ[Lookup[r, "InEffect", False]], "有効", MissingQ[Lookup[r, "InEffect", False]], "ここからは不明",
              Lookup[r, "Action", ""] === "AllowOnce", "一回限り", True, "いまは無効"]]}] /@
          Take[loose, UpTo[maxRows]]],
      Alignment -> {Left, Top}, Spacings -> {1.5, 0.5}, Dividers -> {False, {False, True}}]];
  dueGrid = If[due === {}, iWGPVText["(いま再確認が要るものはありません)"],
    Grid[Join[{hd /@ {"対象", "いまの設定", "いつから", "前回の再確認", ""}},
        Function[x, {
            iWGPVText[If[x["Kind"] === "Host", x["Target"],
              iWGPostureLabelJa[x["Target"]] <> If[Lookup[x, "Role", ""] === "Service", "  [service のカーネル]", ""]]],
            iWGPVText[If[x["Kind"] === "Host",
              "許可" <> If[iWGLevelText[x["Level"]] =!= "", " (" <> iWGLevelText[x["Level"]] <> ")", ""] <>
                If[TrueQ[x["ListOverride"]], "、評判のリストに載っていても許可", ""],
              "いまの値 " <> ToString[x["Value"]] <> " (既定より緩い)"]],
            iWGPVSmall[If[x["Since"] =!= "", iWGLocalTimeString[x["Since"]], "記録なし"]],
            iWGPVSmall[If[x["ReconfirmedAt"] =!= "", iWGLocalTimeString[x["ReconfirmedAt"]], "まだ"]],
            If[x["Kind"] === "Host",
              With[{h = x["Target"], lv = defLv},
                iWGTemplateButton["許可をやめる",
                  SourceVault`SourceVaultIntegrityOwnerAction[
                    SourceVault`SourceVaultWebHostSetAccess[h, lv, "TrustStatus" -> "Observed", "PolicySource" -> "Default"]]]],
              iWGPVSmall["変数を既定の値に戻すと締まります"]]}] /@ Take[due, UpTo[maxRows]]],
      Alignment -> {Left, Top}, Spacings -> {1.5, 0.5}, Dividers -> {False, {False, True}}]];
  Column[{
    Style["所有者の判断の見直し (直近 " <> ToString[days] <> " 日)", Bold, 13],
    iWGPVSmall["関所について所有者が決めたことの記録です。見るためのもので、これで何かが止まることはありません。" <>
      "青い字のボタンは、式を下のセルに置きます。その式を評価すると反映されます。"],
    Grid[{
        {hd["壁の高さ"], iWGPVText["許可したホスト " <> ToString[wh["ApprovedHosts"]] <> " (うち機密を読んだ会話にも許可 " <> ToString[wh["ApprovedForPrivate"]] <>
          "、評判のリストを承知で許可 " <> ToString[wh["ListOverrides"]] <> ")    遮断したホスト " <> ToString[wh["BlockedHosts"]] <>
          "    既定より緩めている設定 " <> ToString[Length[wh["LoosenedSettings"]]]]},
        {hd["この期間"], iWGPVText["緩めた " <> ToString[wh["LoosenedInPeriod"]] <> " 件    締めた " <> ToString[wh["TightenedInPeriod"]] <>
          " 件    一回だけの許可 " <> ToString[wh["OneTimeAllows"]] <> " 件    判断の合計 " <> ToString[sm["Decisions"]] <> " 件"]},
        {hd["速い承認"], iWGPVText[ToString[fa["ThresholdSeconds"]] <> " 秒より短い時間で緩めた判断 " <> ToString[fa["Count"]] <> " 件 (時間が分かる " <>
          ToString[fa["Of"]] <> " 件のうち)"]},
        {hd["連続の承認"], iWGPVText["緩める判断が続いた回数は、最大 " <> ToString[sm["ConsecutiveLoosening"]] <> " 回"]},
        {hd["一貫性"], iWGPVText[If[incons === {}, "許可と拒否が入れ替わった対象はありません",
          "許可と拒否が入れ替わった対象: " <> StringRiffle[Take[incons, UpTo[8]], ", "] <> If[Length[incons] > 8, " ほか", ""]]]},
        (* V9: 関所が止めたことの副作用。止めた依頼が、未確認の回答で終わっていないか *)
        {hd["拒否の後の結果"], With[{ro = Replace[Lookup[sm, "RefusalOutcomes", <||>], Except[_Association] -> <||>]},
          iWGPVText[If[Lookup[ro, "Requests", 0] === 0, "関所が検索や取得を止めた依頼はありません",
            "関所が検索や取得を止めた依頼 " <> ToString[ro["Requests"]] <> " 件のうち、外部で未確認の回答で終わったもの " <>
              ToString[Lookup[ro, "EndedUnconfirmed", 0]] <> " 件、一部だけ確認できたもの " <> ToString[Lookup[ro, "EndedPartial", 0]] <> " 件"]]]}},
      Alignment -> {Left, Top}, Spacings -> {1.5, 0.5}],
    Style["この期間に緩めたもの (" <> ToString[Length[loose]] <> " 件" <>
      If[Length[loose] > maxRows, "、新しい " <> ToString[maxRows] <> " 件を表示", ""] <> ")", Bold],
    looseGrid,
    Style["再確認が要るもの (" <> ToString[Length[due]] <> " 件。" <> ToString[sm["ReconfirmDays"]] <> " 日より長く見直していない緩和)", Bold],
    dueGrid,
    If[due === {} && sm["LoosenedNow"] === {}, Nothing,
      Row[{iWGTemplateButton["見直した。このまま続ける (まとめて再確認)",
          SourceVault`SourceVaultIntegrityOwnerAction[SourceVault`SourceVaultOwnerDecisionReconfirm[All]]],
        iWGPVSmall["   設定は変えません。次に並ぶのは " <> ToString[sm["ReconfirmDays"]] <> " 日後です。"]}]]},
    Spacings -> 1]];

(* ------------------------------------------------------------
   SystemDoctor probe 登録 (弱結合)
   ------------------------------------------------------------ *)
If[Length[DownValues[SourceVault`SourceVaultDiagnosticsRegisterProbe]] > 0,
  Quiet @ Check[
    SourceVault`SourceVaultDiagnosticsRegisterProbe["WebAccessReview",
      Function[SourceVault`SourceVaultWebAccessReviewProbe[]]], Null];
  (* V7: 方針の提案 *)
  Quiet @ Check[
    SourceVault`SourceVaultDiagnosticsRegisterProbe["PolicyProposals",
      Function[SourceVault`SourceVaultPolicyProposalsProbe[]]], Null]];
(* V7: 提案に答えるのは所有者だけ (提案コードからは承認制)。ホストの許可・遮断の関数も、ここで承認の対象に入れる:
   これまで対象に入っておらず、モデルの提案コードが所有者の承認なしにホストを許可できた。V7 で「評判のリストに載っていても
   許可」("ListOverride") が加わるので、放置できない。所有者が入力セルから呼ぶ分と、承認の窓・提案への回答の中から呼ぶ分は、
   これまでどおり動く (承認の検査は提案コードだけに掛かる) *)
(* V8: 再確認 (SourceVaultOwnerDecisionReconfirm) も所有者だけ。提案コードが「見直した」と記録できると、再確認の意味が無くなる。
   判断の記録の文脈と、確認を足す選択肢の一覧・役割の指定は、提案コードから代入させない *)
If[Length[DownValues[NBAccess`NBRegisterApprovalHeads]] > 0,
  Quiet @ NBAccess`NBRegisterApprovalHeads[{"SourceVaultPolicyProposalResolve", "SourceVaultWebHostSetAccess", "SourceVaultWebHostBlock",
    "SourceVaultOwnerDecisionReconfirm",
    (* V9: 裏付けの記録を書く口。提案コードが「Grounded」の記録を作れると、未確認の回答を確認済みに見せられる。
       ツールループ (claudecode の本体) は NBAccess の検査を通らずに直接呼ぶので、これまでどおり書ける *)
    "SourceVaultGroundingNote"}]];
If[Length[DownValues[NBAccess`NBRegisterApprovalSetSymbols]] > 0,
  Quiet @ NBAccess`NBRegisterApprovalSetSymbols[{"$iWGProposalReasons", "$iWGDecisionContext", "$iWGLooseningChoices", "$iWGPostureRole"}]];

(* ------------------------------------------------------------
   privacy 契約 (弱結合)。ログ / 集計はクエリ文字列 (私的文脈由来の可能性) を含むので Private、
   それ以外は決定・方針・簿記のみで私的データを返さない。
   ------------------------------------------------------------ *)
Quiet @ Check[
  If[Length[DownValues[SourceVault`SourceVaultRegisterPrivacyContract]] > 0,
    Scan[SourceVault`SourceVaultRegisterPrivacyContract[First[#],
        <|"Class" -> "Private", "Exit" -> Last[#], "Sources" -> {},
          "Module" -> "SourceVault_webguard.wl",
          "Note" -> "LLM web access log rows carry query/url text produced under a private context; PL = max ContextPL of the rows."|>] &,
      {{"SourceVaultWebAccessLog", "Result"}, {"SourceVaultWebAccessLogView", "View"},
       {"SourceVaultWebAccessSummary", "Result"}, {"SourceVaultWebAccessSummaryView", "View"},
       {"SourceVaultWebGuardPendingRequests", "Result"},
       (* V7: 方針の提案は URL・検索語の抜粋を持つ *)
       {"SourceVaultPolicyProposals", "Result"}, {"SourceVaultPolicyProposalsView", "View"}}];
    Scan[SourceVault`SourceVaultRegisterPrivacyContract[#,
        <|"Class" -> "Public", "Module" -> "SourceVault_webguard.wl",
          "NoDataFlow" -> "URL/query shape analysis, host access policy, guard decisions and review bookkeeping; no stored private data is returned."|>] &,
      {"SourceVaultWebGuardAnalyzeURL", "SourceVaultWebGuardAnalyzeQuery", "SourceVaultWebGuardDecide",
       "SourceVaultWebGuardCheck", "SourceVaultWebGuardDeclareContext", "SourceVaultWebGuardContext",
       "SourceVaultWebGuardStatus", "SourceVaultWebHostProfile", "SourceVaultWebHostProfiles",
       "SourceVaultWebHostProfilesView", "SourceVaultWebHostSetAccess", "SourceVaultWebHostBlock",
       "SourceVaultWebHostEstimateAccess", "SourceVaultWebHostRecomputeProfiles", "SourceVaultWebHostStorePath",
       "SourceVaultWebGuardResolveRequest", "SourceVaultWebGuardProcessPending",
       "SourceVaultWebGuardStartPendingWatch", "SourceVaultWebGuardStopPendingWatch",
       "SourceVaultWebAccessMarkReviewed", "SourceVaultWebAccessReviewStatus", "SourceVaultWebAccessReviewProbe",
       (* V7: 集計の件数・決定の記録・件数だけの probe *)
       "SourceVaultPolicyProposalsRefresh", "SourceVaultPolicyProposalResolve", "SourceVaultPolicyProposalsProbe",
       (* V8: 所有者の判断の記録と見直し。ホストの名前と決めた内容だけで、検索語・URL・依頼文は持たない *)
       "SourceVaultOwnerDecisions", "SourceVaultOwnerDecisionSummary", "SourceVaultOwnerDecisionReconfirm",
       "SourceVaultOwnerDecisionReviewView",
       (* V9: 裏付けの検査の記録と指標。判定・件数・回答の SHA-256 だけで、依頼文・検索語・本文・URL は持たない *)
       "SourceVaultGroundingNote", "SourceVaultGroundingLog", "SourceVaultGroundingSummary", "SourceVaultGroundingOfText"}]],
  Null];

End[];
EndPackage[];

(* FE カーネルでは未決 request (service kernel / web job 子が queue した問い合わせ) の監視を
   claudecode の共有 polling tick に自動登録する。service / script カーネルでは何もしない。
   Opt out: Global`$SourceVaultWebGuardDisableAutoWatch = True before load. *)
If[TrueQ[$Notebooks] && ! TrueQ[Global`$SourceVaultWebGuardDisableAutoWatch],
  Quiet @ Check[SourceVault`SourceVaultWebGuardStartPendingWatch[], Null]];
