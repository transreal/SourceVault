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
  "  <|\"Kind\" -> \"Fetch\"|\"Search\", \"Url\" -> _, \"Query\" -> _, \"Actor\" -> <|\"Type\" -> \"HumanUser\"|\"MCPClient\", ...|>,\n" <>
  "    \"Channel\" -> \"MCP\"|\"Notebook\"|.., \"ContextPL\" -> (任意・明示), \"Provider\"/\"Model\" (任意)|>\n" <>
  "文脈 PL の解決 → 不審度 → ホスト profile → 判定表 → Ask なら ticket / prompter → ログ。\n" <>
  "戻り値 <|Decision -> \"Allow\"|\"Deny\"|\"Pending\", Reason, Reasons, DecisionBy, DecisionDetail, RequestId, Message (モデル向け英文),\n" <>
  "Host, ContextPL, Actor, Analysis, Profile, LogEventId|>。webingest の SourceVaultWebSearch / SourceVaultWebFetch から呼ばれる。";

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
  "(既定 TrustStatus -> \"Approved\", PolicySource -> \"Owner\")。推定はこの値を上下させない。opts \"Note\"/\"Persist\"。";

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
  "NewHosts, PendingRequests, OwnerDecisions, ReviewStatus, MaxContextPL|> を返す (core 版)。opts は SourceVaultWebAccessLog の期間 opts。";

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
  "$SourceVaultWebGuardPolicy は判定閾値 <|LowRiskPL 0.2, PrivatePL 0.5, DefaultHostLevel 0.2, EstablishedCount 20, EstablishedDays 3, OpaqueScore 0.4, ExfilScore 0.8|>。";
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
  "OpaqueScore" -> 0.4, "ExfilScore" -> 0.8|>;
If[! AssociationQ[$SourceVaultWebGuardPolicy], $SourceVaultWebGuardPolicy = $iWGDefaultPolicy];
If[! NumericQ[$SourceVaultWebGuardUnknownContextPL], $SourceVaultWebGuardUnknownContextPL = 0.5];
If[! NumericQ[$SourceVaultWebGuardContextTTLSeconds], $SourceVaultWebGuardContextTTLSeconds = 900];
If[! NumericQ[$SourceVaultWebGuardPendingTTLSeconds], $SourceVaultWebGuardPendingTTLSeconds = 600];
If[! ValueQ[$SourceVaultWebGuardPrompter], $SourceVaultWebGuardPrompter = Automatic];
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

iWGStatsApply[r_Association] := Module[{host, aid, dec, cls, day, at, hs, as, ba},
  If[! AssociationQ[Lookup[$iWGStatsCache, "Hosts", None]], Return[Null]];
  dec = ToString @ Lookup[r, "Decision", ""];
  If[dec === "OwnerDecided", Return[Null]];
  host = ToString @ Lookup[r, "Host", ""];
  aid = ToString @ Lookup[r, "ActorId", "?"];
  cls = ToString @ Lookup[r, "Class", "Plain"];
  at = ToString @ Lookup[r, "At", ""];
  day = If[StringLength[at] >= 10, StringTake[at, 10], at];
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
  $iWGStatsCache["Hosts"] = Append[$iWGStatsCache["Hosts"], host -> hs];
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
    "Note" -> Lookup[prof, "Note", Missing["NotSet"]]|>];

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

Options[SourceVaultWebHostSetAccess] = {"TrustStatus" -> "Approved", "PolicySource" -> "Owner",
  "Note" -> Missing[], "Persist" -> True, "Confidence" -> 1.0};
SourceVaultWebHostSetAccess[hostIn_String, level_?NumericQ, OptionsPattern[]] := Module[
  {host = iWGNormHost[hostIn], prof, now = iWGNowIso[]},
  If[host === "", Return[Failure["EmptyHost", <||>]]];
  iWGProfilesEnsureFresh[];
  prof = Lookup[$iWGProfiles, host, <||>]; If[! AssociationQ[prof], prof = <||>];
  prof = Join[prof, <|"Type" -> "SourceVaultWebHostProfile", "SchemaVersion" -> 1,
    "Host" -> host, "IdentifierId" -> iWGIdentifierId["WebHost", host],
    "AccessLevel" -> Clip[N[level], {0., 1.}],
    "TrustStatus" -> OptionValue["TrustStatus"], "PolicySource" -> OptionValue["PolicySource"],
    "Confidence" -> OptionValue["Confidence"], "UpdatedAt" -> now|>];
  If[! StringQ[Lookup[prof, "FirstSeen", Null]], prof["FirstSeen"] = now];
  If[StringQ[OptionValue["Note"]], prof["Note"] = OptionValue["Note"]];
  $iWGProfiles = Append[$iWGProfiles, host -> prof];
  iWGObserveIdentity["WebHost", host];
  If[TrueQ[OptionValue["Persist"]], iWGProfilesSave[]];
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
  $iWGDeclared = Append[$iWGDeclared, key -> rec];
  dir = iWGContextDir[];
  If[StringQ[dir], Quiet @ iWGWriteJSON[FileNameJoin[{dir, key <> ".json"}], KeyDrop[rec, "Abs"]]];
  (* FE カーネルで claudecode が LLM を呼ぶ = 未決 request を見る人がいる。ロード時に claudecode が
     未ロードで監視登録できなかった場合もここで遅延登録する (申告は毎回呼ばれるので冪等に 1 回だけ)。 *)
  If[TrueQ[$Notebooks] && ! TrueQ[$iWGWatchRegistered],
    Quiet @ Check[SourceVaultWebGuardStartPendingWatch[], Null]];
  rec];
SourceVaultWebGuardDeclareContext[___] := $Failed;

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

(* ------------------------------------------------------------
   主体 (Actor)
   ------------------------------------------------------------ *)
iWGModelActor[prov_, model_, client_] := With[{v = ToLowerCase[ToString[prov] <> "/" <> ToString[model]]},
  <|"Kind" -> "Model", "Id" -> iWGIdentifierId["Model", v], "Display" -> v,
    "Provider" -> ToString[prov], "Model" -> ToString[model], "ClientName" -> client|>];

iWGResolveActor[req_Association, ctx_Association] := Module[{a, type, prov, model, client, fresh},
  a = Lookup[req, "Actor", <||>]; If[! AssociationQ[a], a = <||>];
  type = ToString @ Lookup[a, "Type", Lookup[a, "Kind", "Unknown"]];
  prov = Lookup[req, "Provider", Lookup[a, "Provider", Missing[]]];
  model = Lookup[req, "Model", Lookup[a, "Model", Missing[]]];
  client = Lookup[a, "ClientName", Missing[]];
  fresh = Lookup[ctx, "Freshest", Missing[]];
  Which[
    MemberQ[{"HumanUser", "Owner"}, type],
      <|"Kind" -> "Owner", "Id" -> "ent-1", "Display" -> "Owner", "Provider" -> Missing[],
        "Model" -> Missing[], "ClientName" -> Missing[]|>,
    StringQ[prov] && StringQ[model] && model =!= "", iWGModelActor[prov, model, client],
    AssociationQ[fresh] && StringQ[Lookup[fresh, "Model", None]] && fresh["Model"] =!= "",
      iWGModelActor[Lookup[fresh, "Provider", "unknown"], fresh["Model"], client],
    True,
      With[{cn = If[StringQ[client] && client =!= "", client, "MCPClient"]},
        <|"Kind" -> "MCPClient", "Id" -> iWGIdentifierId["MCPClient", ToLowerCase[cn]], "Display" -> cn,
          "Provider" -> Missing[], "Model" -> Missing[], "ClientName" -> cn|>]]];

(* ------------------------------------------------------------
   判定表 (spec §8, 純関数)
   ------------------------------------------------------------ *)
iWGDec[d_, r_, reasons_, level_: Missing[]] :=
  <|"Decision" -> d, "Reason" -> r, "Reasons" -> reasons, "Level" -> level|>;

SourceVaultWebGuardDecide[spec_Association] := Module[{kind, ctx, an, prof, cls, status, level, seen, est, reasons, pii},
  kind = ToString @ Lookup[spec, "Kind", "Fetch"];
  ctx = Lookup[spec, "ContextPL", $SourceVaultWebGuardUnknownContextPL];
  If[! NumericQ[ctx], ctx = $SourceVaultWebGuardUnknownContextPL]; ctx = N[ctx];
  an = Lookup[spec, "Analysis", <||>]; If[! AssociationQ[an], an = <||>];
  cls = ToString @ Lookup[an, "Class", "Plain"];
  reasons = Replace[Lookup[an, "Reasons", {}], Except[_List] -> {}];
  pii = Replace[Lookup[an, "PIIHints", {}], Except[_List] -> {}];
  If[kind === "Search",
    Return @ Which[
      cls === "Exfil", iWGDec["Ask", "ExfilShapedQuery", reasons],
      ctx <= iWGPol["LowRiskPL"], iWGDec["Allow", "LowRiskContext", reasons],
      cls === "Opaque", iWGDec["Ask", "OpaqueQueryWithContext", reasons],
      ctx >= iWGPol["PrivatePL"] && pii =!= {}, iWGDec["Ask", "PIIInQueryWithPrivateContext", Join[reasons, pii]],
      True, iWGDec["Allow", "Policy", reasons]]];
  prof = Lookup[spec, "Profile", <||>]; If[! AssociationQ[prof], prof = <||>];
  status = ToString @ Lookup[prof, "TrustStatus", "Observed"];
  level = Lookup[prof, "EffectiveLevel", Lookup[prof, "AccessLevel", iWGPol["DefaultHostLevel"]]];
  If[! NumericQ[level], level = iWGPol["DefaultHostLevel"]]; level = N[level];
  seen = TrueQ[Lookup[prof, "AccessCount", 0] > 0];
  est = TrueQ @ Lookup[prof, "Established", False];
  Which[
    status === "Blocked", iWGDec["Deny", "HostBlocked", reasons, level],
    cls === "Exfil", iWGDec["Ask", "ExfilShapedURL", reasons, level],
    ctx <= level,
      If[cls === "Opaque" && ! seen,
        iWGDec["Ask", "OpaqueOnNewHost", reasons, level],
        iWGDec["Allow", "WithinHostLevel", reasons, level]],
    ! seen, iWGDec["Ask", "NewHostWithPrivateContext", reasons, level],
    cls === "Opaque", iWGDec["Ask", "OpaqueWithPrivateContext", reasons, level],
    ! est, iWGDec["Ask", "UnestablishedHostWithPrivateContext", reasons, level],
    True, iWGDec["Allow", "AboveLevelEstablished", Append[reasons, "AboveLevelEstablished"], level]]];

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
  iWGApplyHostDecision[host, decision, Lookup[req, "ContextPL", Missing[]], OptionValue["Level"]];
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

iWGDialogPrompt[req_Association] := Module[{kind, host, target, reasons, prof, actor, ctx, items, choices, res},
  kind = ToString @ Lookup[req, "Kind", "Fetch"];
  host = ToString @ Lookup[req, "Host", ""];
  target = ToString @ If[kind === "Search", Lookup[req, "Query", ""], Lookup[req, "Url", ""]];
  reasons = Replace[Lookup[req, "Reasons", {}], Except[_List] -> {}];
  prof = Lookup[req, "Profile", <||>]; If[! AssociationQ[prof], prof = <||>];
  actor = Lookup[req, "Actor", <||>]; If[! AssociationQ[actor], actor = <||>];
  ctx = Lookup[req, "ContextPL", Missing[]];
  items = {
    Style["LLM の Web アクセス確認", Bold, 13, RGBColor[0.75, 0.3, 0.1]],
    Row[{"主体: ", Style[ToString @ Lookup[actor, "Display", "?"], Bold],
      "    文脈 PL: ", Style[ToString[ctx], Bold],
      "    種別: ", If[kind === "Search", "検索 (SearXNG 中継)", "URL 取得"]}],
    If[kind === "Fetch", Row[{"ホスト: ", Style[host, Bold, 12]}], Nothing],
    Pane[Style[target, 10, LineBreakWithin -> True], {540, Automatic}],
    If[reasons =!= {},
      Column[Style["理由: " <> ToString[#], 10, RGBColor[0.7, 0.1, 0.1]] & /@ reasons], Nothing],
    Row[{"判定理由: ", ToString @ Lookup[req, "Reason", ""],
      If[StringQ[Lookup[req, "RequestId", None]], "   request " <> req["RequestId"], ""]}],
    If[kind === "Fetch",
      Row[{"実績: ", ToString @ Lookup[prof, "AccessCount", 0], " 回 / レベル ",
        ToString @ Lookup[prof, "EffectiveLevel", "?"], " / ", ToString @ Lookup[prof, "TrustStatus", "?"],
        If[StringQ @ Lookup[prof, "LastSeen", None], " / 最終 " <> iWGLocalTimeString[prof["LastSeen"]], ""]}],
      Nothing]};
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
iWGMessage["Allow", ___] := "";
iWGMessage["Pending", reason_, kind_, host_, reqId_] :=
  If[kind === "Search",
    "This web search requires owner approval (request " <> ToString[reqId] <> "; " <> ToString[reason] <>
      "). The owner has been asked; retry this exact search in a minute, or narrow the query.",
    "Web access to " <> host <> " requires owner approval (request " <> ToString[reqId] <> "; " <>
      ToString[reason] <> "). The owner has been asked; retry this exact call in a minute, or use a different source."];
iWGMessage["Deny", reason_, kind_, host_, _] :=
  If[kind === "Search",
    "This web search was denied by the SourceVault web guard (" <> ToString[reason] <>
      "). Do not retry the same query; rephrase it without identifiers or opaque strings.",
    "Web access to " <> host <> " was denied by the SourceVault web guard (" <> ToString[reason] <>
      "). Do not retry this URL; use a different source."];
iWGMessage[___] := "";

iWGFinish[logRec_Association, decision_String, by_String, reason_, an_Association, prof_Association,
    actor_Association, ctxPL_, reqId_, detail_: Missing[]] := Module[{rec, msg},
  msg = iWGMessage[decision, reason, Lookup[logRec, "Kind", ""], Lookup[logRec, "Host", ""], reqId];
  rec = iWGAppendLog[Join[logRec, <|"Decision" -> decision, "DecisionBy" -> by,
    "DecisionReason" -> reason, "DecisionDetail" -> detail, "RequestId" -> reqId|>]];
  <|"Decision" -> decision, "Reason" -> reason, "Reasons" -> Lookup[an, "Reasons", {}],
    "DecisionBy" -> by, "DecisionDetail" -> detail, "RequestId" -> reqId, "Message" -> msg,
    "Host" -> Lookup[logRec, "Host", ""], "ContextPL" -> ctxPL, "Actor" -> actor, "Analysis" -> an,
    "Profile" -> KeyTake[prof, {"AccessLevel", "EffectiveLevel", "TrustStatus", "AccessCount", "Established"}],
    "LogEventId" -> Lookup[rec, "EventId", Missing[]]|>];

SourceVaultWebGuardCheck[reqIn_Association] := Module[
  {req = reqIn, kind, url, query, channel, an, host, ctx, actor, ctxPL, ctxSrc, prof, logRec, dec,
   sig, ticket, pend, reqId, choice, target},
  kind = ToString @ Lookup[req, "Kind", If[KeyExistsQ[req, "Query"], "Search", "Fetch"]];
  url = ToString @ Lookup[req, "Url", ""];
  query = ToString @ Lookup[req, "Query", ""];
  channel = ToString @ Lookup[req, "Channel", "Unknown"];
  an = If[kind === "Search", SourceVaultWebGuardAnalyzeQuery[query], SourceVaultWebGuardAnalyzeURL[url]];
  host = If[kind === "Search", "websearch", ToString @ Lookup[an, "Host", ""]];
  ctx = SourceVaultWebGuardContext[];
  actor = iWGResolveActor[req, ctx];
  Which[
    NumericQ[Lookup[req, "ContextPL", None]], ctxPL = N[req["ContextPL"]]; ctxSrc = "Explicit",
    actor["Kind"] === "Owner", ctxPL = 0.0; ctxSrc = "Owner",
    True, ctxPL = ctx["PrivacyLevel"]; ctxSrc = ctx["Source"]];
  prof = If[kind === "Fetch" && host =!= "", iWGHostView[host], <||>];
  logRec = <|"Kind" -> kind,
    "Url" -> If[kind === "Fetch", url, Missing[]], "Host" -> host,
    "Query" -> If[kind === "Search", StringTake[query, UpTo[500]], Missing[]],
    "HostIdentifierId" -> If[kind === "Fetch" && host =!= "", iWGIdentifierId["WebHost", host], Missing[]],
    "ActorId" -> actor["Id"], "ActorKind" -> actor["Kind"], "ActorDisplay" -> actor["Display"],
    "Provider" -> actor["Provider"], "Model" -> actor["Model"], "ClientName" -> actor["ClientName"],
    "Channel" -> channel, "ContextPL" -> ctxPL, "ContextSource" -> ctxSrc,
    "Suspicion" -> Lookup[an, "Suspicion", 0.], "Class" -> Lookup[an, "Class", "Plain"],
    "Reasons" -> Lookup[an, "Reasons", {}], "PIIHints" -> Lookup[an, "PIIHints", {}],
    "HostAccessLevel" -> Lookup[prof, "EffectiveLevel", Missing[]],
    "HostAccessCount" -> Lookup[prof, "AccessCount", Missing[]],
    "SessionId" -> Lookup[req, "SessionId", Missing[]]|>;
  If[actor["Kind"] =!= "Owner",
    iWGObserveIdentity[If[actor["Kind"] === "Model", "Model", "MCPClient"],
      ToString @ Lookup[actor, "Display", ""], actor["Display"]]];
  If[! TrueQ[$SourceVaultWebGuardEnabled],
    Return[iWGFinish[logRec, "Allow", "Policy", "GuardDisabled", an, prof, actor, ctxPL, Missing[]]]];
  If[actor["Kind"] === "Owner",
    Return[iWGFinish[logRec, "Allow", "Policy", "OwnerActor", an, prof, actor, ctxPL, Missing[]]]];
  dec = SourceVaultWebGuardDecide[<|"Kind" -> kind, "ContextPL" -> ctxPL, "Analysis" -> an, "Profile" -> prof|>];
  If[dec["Decision"] =!= "Ask",
    Return[iWGFinish[logRec, dec["Decision"], "Policy", dec["Reason"], an, prof, actor, ctxPL, Missing[]]]];
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
    "Channel" -> channel|>];
  reqId = If[AssociationQ[pend], Lookup[pend, "RequestId", Missing[]], Missing["NoLocalState"]];
  choice = iWGPromptDecision[<|"Kind" -> kind, "Url" -> url, "Query" -> query, "Host" -> host,
    "Reasons" -> dec["Reasons"], "Reason" -> dec["Reason"], "Profile" -> prof, "Actor" -> actor,
    "ContextPL" -> ctxPL, "RequestId" -> reqId|>];
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
  {now = AbsoluteTime[], days, since, until, recs, acc, byKind, byDec, byActor, byHost, newHosts, susp, pend},
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
  <|"Days" -> Round[(until - since)/86400.], "Since" -> iWGAbsToIso[since], "Until" -> iWGAbsToIso[until],
    "Total" -> Length[acc], "ByKind" -> byKind, "ByDecision" -> byDec, "Suspicious" -> susp,
    "ByActor" -> byActor, "ByHost" -> byHost, "NewHosts" -> newHosts,
    "PendingRequests" -> Length[pend],
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
    "NewHosts" -> Length[sm["NewHosts"]], "Note" -> OptionValue["Note"]|>;
  If[StringQ[p], iWGWriteJSON[p, rec]];
  If[TrueQ[OptionValue["Recompute"]], Quiet @ Check[SourceVaultWebHostRecomputeProfiles[], Null]];
  $iWGProbeCache = <||>;
  rec];

Options[SourceVaultWebAccessReviewProbe] = {"UseCache" -> True, "Now" -> Automatic, "PendingStaleSeconds" -> 120};
SourceVaultWebAccessReviewProbe[OptionsPattern[]] := Module[
  {now, st, days, sm, pend, stale, reasons = {}, msgs = {}, res, interval = $SourceVaultWebGuardReviewIntervalDays},
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
      "PendingStale" -> Length[stale], "WindowDays" -> days, "LastReviewedAt" -> st["LastReviewedAt"]|>];
  If[OptionValue["Now"] === Automatic, $iWGProbeCache = <|"At" -> now, "Result" -> res|>];
  res];

SourceVaultWebGuardStatus[] := <|
  "Version" -> $SourceVaultWebGuardVersion, "Enabled" -> TrueQ[$SourceVaultWebGuardEnabled],
  "Policy" -> $SourceVaultWebGuardPolicy, "UnknownContextPL" -> $SourceVaultWebGuardUnknownContextPL,
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

(* ------------------------------------------------------------
   SystemDoctor probe 登録 (弱結合)
   ------------------------------------------------------------ *)
If[Length[DownValues[SourceVault`SourceVaultDiagnosticsRegisterProbe]] > 0,
  Quiet @ Check[
    SourceVault`SourceVaultDiagnosticsRegisterProbe["WebAccessReview",
      Function[SourceVault`SourceVaultWebAccessReviewProbe[]]], Null]];

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
       {"SourceVaultWebGuardPendingRequests", "Result"}}];
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
       "SourceVaultWebAccessMarkReviewed", "SourceVaultWebAccessReviewStatus", "SourceVaultWebAccessReviewProbe"}]],
  Null];

End[];
EndPackage[];

(* FE カーネルでは未決 request (service kernel / web job 子が queue した問い合わせ) の監視を
   claudecode の共有 polling tick に自動登録する。service / script カーネルでは何もしない。
   Opt out: Global`$SourceVaultWebGuardDisableAutoWatch = True before load. *)
If[TrueQ[$Notebooks] && ! TrueQ[Global`$SourceVaultWebGuardDisableAutoWatch],
  Quiet @ Check[SourceVault`SourceVaultWebGuardStartPendingWatch[], Null]];
