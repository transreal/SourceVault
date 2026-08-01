(* ::Package:: *)

(* SourceVault_mailbrowse.wl
   汎用 mbox メールブラウズ層 (OOPS アーカイブブラウザの一般メール版)。

   SourceVault_mailstructure (StructureMail = relation graph / session / 段落 topic /
   topic graph) の上に、OOPS の SourceVaultOOPSSearchThreadsView / ThreadView /
   MailView / TopicThreadList と同等のハイパーテキストブラウズを univ 等の
   任意 mbox に提供する。

   設計原則 (core/View 分離):
   - core 関数 (SourceVaultMailBrowse 系) は連想 (リスト) を返し、次の関数で処理できる。
   - View 関数 (SourceVaultMailBrowse...View / ...ThreadList) はリンク付きセル出力専用。
     表示件数制限も View 層で行う。
   - ボタンに焼き込むのは小さな文字列リテラル (mailRef/sessionId/mbox/topicRef) のみ
     (行連想を埋め込むと "..." 省略でボタンごと消える既知罠)。

   ハイパーテキストリンク:
   - 引用・被引用: relation graph の edge (FromMailRef=citing -> ToMailRef=cited) を
     両方向インデックス化し、メールビューから相手メールを開ける。
   - topic item: 段落 topic (ParagraphTopics) の topic ref ごとに時間順メール列を索引化し、
     スレッドを超えた prev/next 移動と topic->スレッド一覧を提供 (OOPS [ns id] 相当)。
   - cross-session reference: session の CrossSessionReferences (EvidenceCitation /
     AnnualEventReuse 等、merge しなかった歴史参照) をスレッドビューに露出。
   - DB 横断 (⇄ 関連): SourceVault_crosslink がロードされていれば各ビューから
     SourceVaultCrossLinksView へ遷移できる。

   コンテキスト注意: 他パッケージの private helper
   (SourceVault`MailStructPrivate` 等) には依存しない。後からロードされ得る
   シンボル (SourceVaultCrossLinksView 等) は必ず SourceVault` 完全修飾で参照する
   (裸参照は parse 時に private 孤児シンボルを作る罠)。

   依存: SourceVault_mailstructure (必須), SourceVault_maildb (実データロード時),
         SourceVault_searchindex (検索 index build 時), SourceVault_oopsseed
         (本文中の [ns id] OOPS topic ref リンク時のみ・任意)。
   このファイルは UTF-8。Block[{$CharacterEncoding = "UTF-8"}, Get[...]] で読むこと。 *)

BeginPackage["SourceVault`"]

(* ---- core ---- *)

SourceVaultMailBrowseEnsureLoaded::usage =
  "SourceVaultMailBrowseEnsureLoaded[mbox] は mbox のメールを maildb からロードし StructureMail で\n" <>
  "構造化して、ブラウズ用の state ($svMailBrowseState[mbox]) を構築する (冪等)。\n" <>
  "構築結果は暗号封印 (SourceVaultSealPayload) 付き WXF でディスクにキャッシュし、shard ファイルの\n" <>
  "(サイズ,mtime) 指紋が一致する限り次カーネル以降は数秒で復元する (\"Cache\" -> True 既定)。\n" <>
  "Options: \"Period\" -> Automatic (SourceVaultMailEnsureLoaded の period。\"YYYYMM\"|{from,to}|All|n),\n" <>
  "  \"Limit\" -> All, \"Force\" -> False, \"Seed\" -> None (OOPS dict 等の TopicVocabulary seed),\n" <>
  "  \"VocabOptions\" -> {}, \"ReleaseContext\" -> \"mailstruct-local\", \"QuotePass\" -> \"Full\",\n" <>
  "  \"Records\" -> Automatic (テスト/外部注入用: generic record list を渡すと maildb を触らない),\n" <>
  "  \"BuildIndex\" -> True (検索 index を同時構築),\n" <>
  "  \"Cache\" -> True (永続キャッシュ利用), \"RefreshCache\" -> False (True で強制再構築+書き直し)。\n" <>
  "戻り値には CacheHit / CacheWrite / Timings (段階別秒数) が付く。";

SourceVaultMailBrowseSetState::usage =
  "SourceVaultMailBrowseSetState[mbox, structure, indexInfo] は SourceVaultStructureMail の結果から\n" <>
  "ブラウズ state (逆引き索引込み) を直接構築する (テスト/外部構造の注入用)。";

SourceVaultMailBrowseStatus::usage =
  "SourceVaultMailBrowseStatus[mbox] はブラウズ state の概況 (件数/語彙/索引) を返す。";

SourceVaultMailBrowseSessions::usage =
  "SourceVaultMailBrowseSessions[opts] はスレッド (session) 一覧を連想リストで返す (core)。\n" <>
  "Options: \"MBox\" -> Automatic, \"MinMails\" -> 1, \"Limit\" -> 30。";

SourceVaultMailBrowseSearchThreads::usage =
  "SourceVaultMailBrowseSearchThreads[query, opts] は BM25 スレッド検索の結果を連想リストで返す (core)。\n" <>
  "各行: <|Session, Subject, Score, Snippet, MailCount|>。Options: \"MBox\" -> Automatic, \"Limit\" -> 10。";

SourceVaultMailBrowseThread::usage =
  "SourceVaultMailBrowseThread[sessionId, opts] はスレッド詳細 (日付順 MailRefs / digest (current・historical 分離) /\n" <>
  "topic / スレッド内 quote edge / cross-session reference) を連想で返す (core)。Options: \"MBox\" -> Automatic。";

SourceVaultMailBrowseMail::usage =
  "SourceVaultMailBrowseMail[mailRef, opts] はメール 1 通のハイパーテキストノード (record 本体 + Session +\n" <>
  "TopicRefs/TopicLabels + Cites (このメールが引用・参照する edge) + CitedBy (被引用 edge)) を返す (core)。\n" <>
  "mailRef は \"sv://mail/<RecordId>\" または RecordId。Options: \"MBox\" -> Automatic。";

SourceVaultMailBrowseTopicMails::usage =
  "SourceVaultMailBrowseTopicMails[topic, opts] は topic (topic ref または label) を含むメールの\n" <>
  "時間順リストを返す (core)。戻り値: <|TopicRef, Label, MailRefs|>。Options: \"MBox\" -> Automatic。";

SourceVaultMailBrowseTopicSessions::usage =
  "SourceVaultMailBrowseTopicSessions[topic, opts] は topic を含むスレッド一覧 (該当メール付き) を返す (core)。\n" <>
  "Options: \"MBox\" -> Automatic。";

SourceVaultMailBrowseTopicStep::usage =
  "SourceVaultMailBrowseTopicStep[topic, mailRef, dir, opts] は topic の時間順メール列上で mailRef の\n" <>
  "直前 (dir=-1) / 直後 (dir=1) の mailRef を返す (無ければ Missing)。スレッドを超えて移動する (core)。";

SourceVaultMailBrowseTopicRelated::usage =
  "SourceVaultMailBrowseTopicRelated[topic, opts] は topic graph (ObservedRelationGraph) 上の関連 topic\n" <>
  "(QuoteTransition/HistoricalReferenceTransition/CoParagraph 等) を Weight 順に返す (core)。\n" <>
  "Options: \"MBox\" -> Automatic, \"Limit\" -> 10。";

(* ---- View ---- *)

SourceVaultMailBrowseSearchThreadsView::usage =
  "SourceVaultMailBrowseSearchThreadsView[query, opts] はスレッド検索結果を Subject ボタン\n" <>
  "(クリックで ThreadView) 付き Grid で表示する。Options: \"MBox\" -> Automatic, \"Limit\" -> 10。";

SourceVaultMailBrowseThreadList::usage =
  "SourceVaultMailBrowseThreadList[opts] はスレッド一覧をボタン付き Grid で表示する。\n" <>
  "Options: \"MBox\" -> Automatic, \"MinMails\" -> 1, \"Limit\" -> 30。";

SourceVaultMailBrowseThreadView::usage =
  "SourceVaultMailBrowseThreadView[sessionId, opts] はスレッド詳細ビュー (メール一覧ボタン / topic チップ /\n" <>
  "要約 / 歴史参照リンク / ⇄ 関連) を返す。Options: \"MBox\" -> Automatic。";

SourceVaultMailBrowseMailView::usage =
  "SourceVaultMailBrowseMailView[mailRef, opts] はメール 1 通の全文ビューを返す。スレッド/他メール/\n" <>
  "topic チップ (label + prev/next で時間順にスレッド超え移動) / 引用・参照先 / 被引用 / ⇄ 関連 のリンク付き。\n" <>
  "PL > 0.5 は機密セル扱い (NBAccess 規約)。Options: \"MBox\" -> Automatic。";

SourceVaultMailBrowseTopicThreadList::usage =
  "SourceVaultMailBrowseTopicThreadList[topic, opts] は topic を含むスレッド一覧 Grid (topic チップの遷移先)。\n" <>
  "Options: \"MBox\" -> Automatic。";

SourceVaultMailBrowseOpenMail::usage =
  "SourceVaultMailBrowseOpenMail[mailRef, mbox] はメール 1 通を新規ノートブックで開く (I/O)。\n" <>
  "PL > 0.5 は機密セル (NBAccess 規約) で開く。crosslink 層などの外部遷移入口。";

$SourceVaultMailBrowseViewMaxRows::usage =
  "$SourceVaultMailBrowseViewMaxRows は mailbrowse View 層の一覧表示上限行数 (既定 40)。";

$SourceVaultMailBrowseDefaultMBox::usage =
  "$SourceVaultMailBrowseDefaultMBox は MBox -> Automatic のときの既定 mbox (既定 \"univ\")。";

$SourceVaultMailBrowseCacheDir::usage =
  "$SourceVaultMailBrowseCacheDir は EnsureLoaded 永続キャッシュの保存先 override。\n" <>
  "既定 Automatic = LOCALAPPDATA\\SourceVault\\mailbrowse-cache (マシンローカル・Dropbox 非同期)。\n" <>
  "本文込みのため必ず SourceVaultSealPayload で封印して書く (封印不可なら書かない)。";

(* ---- 状態シンボルは SourceVault` 直下に置く (crosslink 等から参照するため) ---- *)
If[! AssociationQ[$svMailBrowseState], $svMailBrowseState = <||>];
If[! StringQ[$SourceVaultMailBrowseDefaultMBox], $SourceVaultMailBrowseDefaultMBox = "univ"];
If[! IntegerQ[$SourceVaultMailBrowseViewMaxRows], $SourceVaultMailBrowseViewMaxRows = 40];
If[! ValueQ[$SourceVaultMailBrowseCacheDir], $SourceVaultMailBrowseCacheDir = Automatic];

Begin["`MailBrowsePrivate`"]

(* ================= 内部 helper (core) ================= *)

iSVMBMailRef[x_String] := If[StringStartsQ[x, "sv://"], x, "sv://mail/" <> x];

iSVMBResolveMBox[mbox_] := Which[
  StringQ[mbox] && mbox =!= "", mbox,
  KeyExistsQ[SourceVault`$svMailBrowseState, $SourceVaultMailBrowseDefaultMBox],
    $SourceVaultMailBrowseDefaultMBox,
  Length[SourceVault`$svMailBrowseState] > 0, First[Keys[SourceVault`$svMailBrowseState]],
  True, $SourceVaultMailBrowseDefaultMBox];

iSVMBState[mbox_] := Lookup[SourceVault`$svMailBrowseState, iSVMBResolveMBox[mbox], <||>];
iSVMBLoadedQ[st_Association] := TrueQ[Lookup[st, "Loaded", False]];
iSVMBLoadedQ[_] := False;

(* 日付ソートキー: ISO/RFC 文字列 -> AbsoluteTime (失敗は 0 = 先頭寄せ) *)
iSVMBDateKey[d_String] := With[{dd = Quiet @ Check[DateObject[d], $Failed]},
  If[DateObjectQ[dd], Quiet @ Check[N @ AbsoluteTime[dd], 0.], 0.]];
iSVMBDateKey[_] := 0.;

iSVMBShort[s_, n_Integer] := StringTake[
  StringReplace[ToString[s], {"\n" -> " ", "\r" -> ""}], UpTo[n]];

(* record の PL (欠落は fail-safe 1.0) *)
iSVMBPL[rec_Association] := With[{p = Lookup[rec, "PrivacyLevel", 1.0]},
  If[NumericQ[p], N[p], 1.0]];
iSVMBPL[_] := 1.0;

(* session 代表 subject (最頻の非空 subject) *)
iSVMBSessionSubject[sm_List] := With[
  {subs = Select[Lookup[#, "Subject", ""] & /@ Select[sm, AssociationQ],
     StringQ[#] && StringTrim[#] =!= "" &]},
  If[subs === {}, "(件名なし)", First[Commonest[subs]]]];

(* label 正規化キー (lexical の公開正規化。未ロード時は小文字化 fallback) *)
iSVMBNormKey[s_String] := With[
  {n = Quiet @ Check[SourceVault`SourceVaultNormalizeSearchText[s], $Failed]},
  If[StringQ[n] && n =!= "", n, ToLowerCase[StringTrim[s]]]];

(* ================= state 構築 ================= *)

SourceVault`SourceVaultMailBrowseSetState[mbox_String, st_Association, idxInfo_: <||>] := Module[
  {records, recByRef, dateOf, sessions, sessById, sessOf, edges, edgesFrom, edgesTo,
   paraTopics, topicPairs, topicIdx, refLabel, labelIdx},
  records = Lookup[st, "Records", {}];
  recByRef = Association[(Lookup[#, "MailRef", ""] -> #) & /@ Select[records, AssociationQ]];
  dateOf = Function[mr, iSVMBDateKey[Lookup[Lookup[recByRef, mr, <||>], "Date", ""]]];
  (* session: MailRefs を日付順に整列し SessionKind (speech-act rule) を焼き込む *)
  sessions = Map[Function[s, Join[s, <|
      "MailRefs" -> SortBy[Lookup[s, "MailRefs", {}], {dateOf[#], #} &],
      "SessionKind" -> Quiet @ Check[
        Lookup[SourceVault`SourceVaultClassifyMailSessionKind[s, records],
          "SessionKind", "Reply"], "Reply"]|>]],
    Lookup[st, "Sessions", {}]];
  sessById = Association[(Lookup[#, "MailSessionId", ""] -> #) & /@ sessions];
  sessOf = Association @ Flatten[
    Function[s, (# -> s["MailSessionId"]) & /@ Lookup[s, "MailRefs", {}]] /@ sessions];
  edges = Lookup[Lookup[st, "RelationGraph", <||>], "Edges", {}];
  edgesFrom = GroupBy[edges, Lookup[#, "FromMailRef", ""] &];
  edgesTo = GroupBy[edges, Lookup[#, "ToMailRef", ""] &];
  (* topic ref -> 時間順 mailRef 列 (スレッド超え prev/next の土台) *)
  paraTopics = Lookup[st, "ParagraphTopics", <||>];
  topicPairs = Flatten[
    Function[pt, ({#, Lookup[pt, "MailRef", ""]} & /@ Lookup[pt, "TopicRefs", {}])] /@
      Values[paraTopics], 1];
  topicIdx = GroupBy[topicPairs, First -> Last,
    Function[ms, SortBy[DeleteDuplicates[ms], {dateOf[#], #} &]]];
  refLabel = Lookup[Lookup[st, "Vocabulary", <||>], "RefLabel", <||>];
  If[! AssociationQ[refLabel], refLabel = <||>];
  (* label (正規化) -> topic ref の逆引き *)
  labelIdx = Association[
    (iSVMBNormKey[ToString[#[[2]]]] -> #[[1]]) & /@ Normal[refLabel]];
  SourceVault`$svMailBrowseState[mbox] = <|
    "Loaded" -> True, "MBox" -> mbox,
    "Structure" -> Join[st, <|"Sessions" -> sessions|>],
    "IndexInfo" -> If[AssociationQ[idxInfo], idxInfo, <||>],
    "RecordByRef" -> recByRef, "SessionById" -> sessById, "SessionOfMail" -> sessOf,
    "EdgesFrom" -> edgesFrom, "EdgesTo" -> edgesTo,
    "TopicMailIndex" -> topicIdx, "RefLabel" -> refLabel, "TopicLabelIndex" -> labelIdx|>;
  SourceVault`$svMailBrowseState[mbox]];

(* ---- 永続キャッシュ (EnsureLoaded の cold build を 1 回きりにする) ----
   鮮度判定: 対象 period の shard ファイル (key, サイズ, mtime) 指紋。maildb をロード/復号
   せずに判定できるため warm start は WXF 読込+封印解除+索引再構築のみ。
   privacy: Structure は復号済み本文を含むため、SourceVaultSealPayload (encrypt-then-MAC)
   で封印できるときだけ書く。封印不可なら書かない (平文 fallback はしない)。 *)

(* v2: 期間フィルタ導入前 (SnapshotList 全 shard 混入状態) に書かれた v1 cache を無効化 *)
$svMBCacheVersion = 2;

(* maildb private の iSVMDResolvePeriod と同じ規則 (avail = {{mbox, yyyymm}...}) *)
iSVMBResolvePeriodKeys[avail_List, period_] := Module[{mbox, yms, sel},
  If[avail === {}, Return[{}]];
  mbox = avail[[1, 1]]; yms = Sort[DeleteDuplicates[avail[[All, 2]]]];
  sel = Which[
    period === All, yms,
    period === Automatic || period === "Latest", {Last[yms]},
    StringQ[period], Select[yms, # === period &],
    MatchQ[period, {_String, _String}],
      Select[yms, OrderedQ[{period[[1]], #}] && OrderedQ[{#, period[[2]]}] &],
    IntegerQ[period] && period > 0, Take[yms, -Min[period, Length[yms]]],
    True, {}];
  (mbox <> "/" <> #) & /@ sel];

(* record の所属 shard key (maildb iSVMDShardKey と同一規則: MBox + Date の年月)。
   SourceVaultMailSnapshotList はカーネルに載っている全 shard の snapshot を返すため、
   agenda/routine 等が先にロードした他月のメールが Period 指定に混入する —
   record 側から所属 shard を決定論に再計算し、要求 period の shard だけ残す。 *)
iSVMBRecordShardKey[rec_Association] := Module[
  {mb = Lookup[Lookup[rec, "SourceRef", <||>], "MBox", Missing[]],
   d = Lookup[rec, "Date", ""]},
  If[! StringQ[mb], mb = "unknown"];
  mb <> "/" <> If[StringQ[d] && StringLength[d] >= 7,
    StringTake[d, 4] <> StringTake[d, {6, 7}], "unknown"]];

iSVMBFilterRecordsByPeriod[records_List, keys_List] :=
  Select[records, AssociationQ[#] && MemberQ[keys, iSVMBRecordShardKey[#]] &];

iSVMBShardFingerprint[mbox_String, period_] := Module[{avail, keys, rows},
  If[Length[DownValues[SourceVault`SourceVaultMailAvailableShards]] === 0 ||
     Length[DownValues[SourceVault`SourceVaultMailShardPath]] === 0,
    Return[Missing["MaildbUnavailable"]]];
  avail = Quiet @ Check[SourceVault`SourceVaultMailAvailableShards[mbox], $Failed];
  If[! ListQ[avail] || avail === {}, Return[Missing["NoShards"]]];
  keys = iSVMBResolvePeriodKeys[avail, period];
  If[keys === {}, Return[Missing["NoShards"]]];
  rows = Map[Function[k, Module[
    {p = Quiet @ Check[SourceVault`SourceVaultMailShardPath[k], ""]},
    If[StringQ[p] && FileExistsQ[p],
      {k, Quiet @ Check[FileByteCount[p], 0],
       Quiet @ Check[Round @ AbsoluteTime[FileDate[p, "Modification"]], 0]},
      {k, 0, 0}]]], keys];
  <|"Keys" -> keys,
    "Digest" -> IntegerString[Hash[{$svMBCacheVersion, rows}, "SHA256"], 36]|>];

iSVMBCacheDir[] := Module[{base},
  base = If[StringQ[SourceVault`$SourceVaultMailBrowseCacheDir],
    SourceVault`$SourceVaultMailBrowseCacheDir,
    With[{la = Environment["LOCALAPPDATA"]},
      FileNameJoin[{If[StringQ[la], la, $UserBaseDirectory],
        "SourceVault", "mailbrowse-cache"}]]];
  If[! DirectoryQ[base],
    Quiet @ CreateDirectory[base, CreateIntermediateDirectories -> True]];
  base];

iSVMBCachePath[mbox_String, period_] := FileNameJoin[{iSVMBCacheDir[],
  "mailbrowse-" <> mbox <> "-" <>
    IntegerString[Hash[{ToString[period, InputForm]}, "SHA256"], 36] <> ".wxf"}];

iSVMBCacheRead[mbox_String, period_, fp_Association] := Module[{path, rec, data},
  path = iSVMBCachePath[mbox, period];
  If[! FileExistsQ[path], Return[Missing["NoCache"]]];
  rec = Quiet @ Check[Import[path, "WXF"], $Failed];
  If[! AssociationQ[rec] || Lookup[rec, "Version", 0] =!= $svMBCacheVersion ||
     Lookup[rec, "Digest", ""] =!= fp["Digest"], Return[Missing["Stale"]]];
  If[! TrueQ[Lookup[rec, "Sealed", False]], Return[Missing["NotSealed"]]];
  If[Length[DownValues[SourceVault`SourceVaultUnsealPayload]] === 0,
    Return[Missing["NoUnseal"]]];
  data = Quiet @ Check[SourceVault`SourceVaultUnsealPayload[rec["Data"]], $Failed];
  If[! AssociationQ[data] || Lookup[data, "Status", ""] =!= "Ok",
    Return[Missing["UnsealFailed"]]];
  data = Lookup[data, "Payload", Missing["NoPayload"]];
  If[! AssociationQ[data] || ! AssociationQ[Lookup[data, "Structure", Missing[]]],
    Return[Missing["BadCache"]]];
  data];

iSVMBCacheWrite[mbox_String, period_, fp_Association, st_Association, idxInfo_] := Module[
  {sealRes, rec, path},
  If[Length[DownValues[SourceVault`SourceVaultSealPayload]] === 0,
    Return["SkippedNoSeal"]];
  sealRes = Quiet @ Check[SourceVault`SourceVaultSealPayload[
    <|"Structure" -> st, "IndexInfo" -> If[AssociationQ[idxInfo], idxInfo, <||>]|>],
    $Failed];
  If[! AssociationQ[sealRes] ||
     ! MatchQ[Lookup[sealRes, "Status", ""], "Stored" | "Ok"],
    Return["SkippedSealFailed"]];
  rec = <|"Version" -> $svMBCacheVersion, "MBox" -> mbox,
    "Period" -> ToString[period, InputForm],
    "Digest" -> fp["Digest"], "Keys" -> fp["Keys"], "Sealed" -> True,
    "Data" -> Lookup[sealRes, "Record", sealRes]|>;
  path = iSVMBCachePath[mbox, period];
  Quiet @ Check[(Export[path, rec, "WXF"]; "Written"), "WriteFailed"]];

Options[SourceVault`SourceVaultMailBrowseEnsureLoaded] = {"Period" -> Automatic, "Limit" -> All,
  "Force" -> False, "Seed" -> None, "VocabOptions" -> {},
  "ReleaseContext" -> "mailstruct-local", "QuotePass" -> "Full",
  "Records" -> Automatic, "BuildIndex" -> True,
  "Cache" -> True, "RefreshCache" -> False};
SourceVault`SourceVaultMailBrowseEnsureLoaded[mbox_String: "univ", OptionsPattern[]] := Module[
  {ctx = OptionValue["ReleaseContext"], period = OptionValue["Period"],
   injected = OptionValue["Records"], cacheOn, records, scope, st, idxInfo,
   fp = Missing["CacheOff"], cached, cacheNote = "Disabled", timings = <||>, t,
   periodKeys = Missing["Unfiltered"]},
  If[iSVMBLoadedQ[Lookup[SourceVault`$svMailBrowseState, mbox, <||>]] &&
      ! TrueQ[OptionValue["Force"]] && ! TrueQ[OptionValue["RefreshCache"]],
    Return[SourceVault`SourceVaultMailBrowseStatus[mbox]]];
  (* 注入 Records では実 shard と食い違うキャッシュを作らない *)
  cacheOn = TrueQ[OptionValue["Cache"]] && ! ListQ[injected];
  If[cacheOn,
    {t, fp} = AbsoluteTiming[iSVMBShardFingerprint[mbox, period]];
    timings["Fingerprint"] = Round[t, 0.001]];
  (* ---- warm path: 指紋一致キャッシュから復元 ---- *)
  If[cacheOn && AssociationQ[fp] && ! TrueQ[OptionValue["RefreshCache"]],
    {t, cached} = AbsoluteTiming[iSVMBCacheRead[mbox, period, fp]];
    timings["CacheRead"] = Round[t, 0.001];
    If[AssociationQ[cached],
      idxInfo = Lookup[cached, "IndexInfo", <||>];
      (* 永続 BM25 index の再ロード (失敗時は破棄 → 初回検索時に lazy rebuild) *)
      If[StringQ[Lookup[idxInfo, "IndexId", None]],
        Module[{r, idxOk},
          {t, r} = AbsoluteTiming[Quiet @ Check[
            SourceVault`SourceVaultLoadSearchIndex[idxInfo["IndexId"]], $Failed]];
          timings["IndexLoad"] = Round[t, 0.001];
          idxOk = ! FailureQ[r] && r =!= $Failed;
          If[! idxOk, idxInfo = <||>]]];
      t = First @ AbsoluteTiming[
        SourceVault`SourceVaultMailBrowseSetState[mbox, cached["Structure"], idxInfo]];
      timings["SetState"] = Round[t, 0.001];
      SourceVault`$svMailBrowseState[mbox] = Append[SourceVault`$svMailBrowseState[mbox],
        "PeriodKeys" -> Lookup[fp, "Keys", Missing["Unknown"]]];
      Return[Join[SourceVault`SourceVaultMailBrowseStatus[mbox],
        <|"CacheHit" -> True, "Timings" -> timings|>]]]];
  (* ---- cold path: maildb → 期間フィルタ → StructureMail → index → キャッシュ書込 ---- *)
  records = injected;
  If[! ListQ[records],
    t = First @ AbsoluteTiming[
      Quiet @ Check[SourceVault`SourceVaultMailEnsureLoaded[mbox, period], $Failed]];
    timings["MaildbLoad"] = Round[t, 0.001];
    {t, records} = AbsoluteTiming[Quiet @ Check[
      SourceVault`SourceVaultMailRecordsForStructuring["MBox" -> mbox,
        "ReleaseContext" -> ctx, "Limit" -> OptionValue["Limit"]], {}]];
    timings["Records"] = Round[t, 0.001];
    (* SnapshotList はロード済み全 shard を返す — 要求 period の shard に限定する。
       (これをしないと agenda 等が先にロードした他月のメールが混入し、
        検索結果・スレッドが「ロードしたつもりのない」メールを含む) *)
    periodKeys = If[AssociationQ[fp], Lookup[fp, "Keys", Missing[]],
      With[{av = If[Length[DownValues[SourceVault`SourceVaultMailAvailableShards]] > 0,
          Quiet @ Check[SourceVault`SourceVaultMailAvailableShards[mbox], $Failed], $Failed]},
        If[ListQ[av] && av =!= {}, iSVMBResolvePeriodKeys[av, period], Missing[]]]];
    If[ListQ[periodKeys] && periodKeys =!= {},
      records = iSVMBFilterRecordsByPeriod[records, periodKeys]]];
  If[! ListQ[records] || records === {},
    Return[<|"Loaded" -> False, "MBox" -> mbox, "Reason" -> "NoRecords",
      "Timings" -> timings|>]];
  scope = <|"ReleaseContext" -> ctx, "MaxPrivacyLevel" -> 1.0, "DenyTags" -> {}|>;
  {t, st} = AbsoluteTiming[
    SourceVault`SourceVaultStructureMail[records, "PrivacyScope" -> scope,
      "QuotePass" -> OptionValue["QuotePass"], "OwnerRef" -> "owner:mailbrowse:" <> mbox,
      "Seed" -> OptionValue["Seed"], "VocabOptions" -> OptionValue["VocabOptions"]]];
  timings["Structure"] = Round[t, 0.001];
  {t, idxInfo} = AbsoluteTiming[If[TrueQ[OptionValue["BuildIndex"]],
    Quiet @ Check[SourceVault`SourceVaultMailStructBuildSearchIndex[st,
      "ReleaseContext" -> ctx], <||>],
    <||>]];
  timings["Index"] = Round[t, 0.001];
  SourceVault`SourceVaultMailBrowseSetState[mbox, st, idxInfo];
  SourceVault`$svMailBrowseState[mbox] = Append[SourceVault`$svMailBrowseState[mbox],
    "PeriodKeys" -> If[ListQ[periodKeys], periodKeys, Missing["Unfiltered"]]];
  If[cacheOn,
    If[AssociationQ[fp],
      {t, cacheNote} = AbsoluteTiming[iSVMBCacheWrite[mbox, period, fp, st, idxInfo]];
      timings["CacheWrite"] = Round[t, 0.001],
      cacheNote = "SkippedNoShardInfo"],
    cacheNote = If[ListQ[injected], "SkippedInjectedRecords", "Disabled"]];
  Join[SourceVault`SourceVaultMailBrowseStatus[mbox],
    <|"CacheHit" -> False, "CacheWrite" -> cacheNote, "Timings" -> timings|>]];

SourceVault`SourceVaultMailBrowseStatus[mbox_: Automatic] := Module[{st = iSVMBState[mbox]},
  If[! iSVMBLoadedQ[st],
    <|"Loaded" -> False, "MBox" -> iSVMBResolveMBox[mbox]|>,
    <|"Loaded" -> True, "MBox" -> st["MBox"],
      "MailCount" -> Length[st["RecordByRef"]],
      "SessionCount" -> Length[st["SessionById"]],
      "TopicCount" -> Length[st["TopicMailIndex"]],
      "RelationEdges" -> Length[Lookup[Lookup[st["Structure"], "RelationGraph", <||>], "Edges", {}]],
      "VocabSize" -> Lookup[Lookup[st["Structure"], "Report", <||>], "VocabSize", 0],
      "IndexId" -> Lookup[st["IndexInfo"], "IndexId", Missing["NoIndex"]],
      "PeriodShards" -> Lookup[st, "PeriodKeys", Missing["Unknown"]]|>]];

(* ================= core: 一覧 / 検索 / スレッド / メール ================= *)

Options[SourceVault`SourceVaultMailBrowseSessions] = {"MBox" -> Automatic, "MinMails" -> 1,
  "Limit" -> 30};
SourceVault`SourceVaultMailBrowseSessions[OptionsPattern[]] := Module[
  {st = iSVMBState[OptionValue["MBox"]], sess},
  If[! iSVMBLoadedQ[st], Return[{}]];
  sess = Select[Values[st["SessionById"]],
    Lookup[#, "MailCount", 0] >= OptionValue["MinMails"] &];
  sess = Take[ReverseSortBy[sess, Lookup[#, "MailCount", 0] &],
    UpTo[OptionValue["Limit"] /. All -> Length[sess]]];
  Map[Function[s, Module[{sm},
    sm = DeleteMissing[Lookup[st["RecordByRef"], Lookup[s, "MailRefs", {}]]];
    <|"Session" -> s["MailSessionId"], "Subject" -> iSVMBSessionSubject[sm],
      "SessionKind" -> Lookup[s, "SessionKind", "Reply"],
      "MailCount" -> Lookup[s, "MailCount", Length[sm]],
      "FirstDate" -> If[sm === {}, "", Lookup[First[sm], "Date", ""]],
      "LastDate" -> If[sm === {}, "", Lookup[Last[sm], "Date", ""]]|>]], sess]];

(* 検索 index が無ければ一度だけ lazy build を試みる *)
iSVMBEnsureIndex[mbox_] := Module[{key = iSVMBResolveMBox[mbox], st, idxInfo},
  st = Lookup[SourceVault`$svMailBrowseState, key, <||>];
  If[! iSVMBLoadedQ[st], Return[<||>]];
  idxInfo = Lookup[st, "IndexInfo", <||>];
  If[StringQ[Lookup[idxInfo, "IndexId", None]], Return[idxInfo]];
  idxInfo = Quiet @ Check[
    SourceVault`SourceVaultMailStructBuildSearchIndex[st["Structure"],
      "ReleaseContext" -> "mailstruct-local"], <||>];
  If[AssociationQ[idxInfo] && StringQ[Lookup[idxInfo, "IndexId", None]],
    SourceVault`$svMailBrowseState[key] =
      Append[SourceVault`$svMailBrowseState[key], "IndexInfo" -> idxInfo]];
  idxInfo];

Options[SourceVault`SourceVaultMailBrowseSearchThreads] = {"MBox" -> Automatic, "Limit" -> 10,
  "MinScore" -> Automatic};
SourceVault`SourceVaultMailBrowseSearchThreads[query_String, OptionsPattern[]] := Module[
  {st = iSVMBState[OptionValue["MBox"]], idxInfo, res, rows, minS, top},
  If[! iSVMBLoadedQ[st], Return[{}]];
  idxInfo = iSVMBEnsureIndex[OptionValue["MBox"]];
  If[! StringQ[Lookup[idxInfo, "IndexId", None]], Return[{}]];
  res = Quiet @ Check[SourceVault`SourceVaultMailStructSearch[query, idxInfo,
    "Limit" -> OptionValue["Limit"]], {}];
  rows = Which[Head[res] === Dataset, Normal[res], ListQ[res], res, True, {}];
  rows = Select[rows, AssociationQ[#] && NumericQ[Lookup[#, "Score", None]] &];
  (* 現 state に存在しない session への hit は落とす (stale な永続 index への防御。
     クリックしても解決できないリンクを出さない) *)
  rows = Select[rows, KeyExistsQ[st["SessionById"], Lookup[#, "ChunkId", ""]] &];
  (* 弱一致ノイズ除去: BM25 は無関係 query でも bigram 部分一致の低スコア行を返す。
     Automatic = Max[2.0, 0.4 * 最高スコア] 未満を落とす。None/0 で全件。 *)
  minS = OptionValue["MinScore"];
  top = If[rows === {}, 0., Max[N @ Lookup[#, "Score", 0.] & /@ rows]];
  minS = Which[
    minS === None || minS === 0 || minS === 0., -Infinity,
    NumericQ[minS], N[minS],
    True, If[rows === {}, -Infinity, Max[2.0, 0.4*top]]];
  rows = Select[rows, Lookup[#, "Score", 0.] >= minS &];
  Map[Function[r, Module[{sid = Lookup[r, "ChunkId", ""], sess},
    sess = Lookup[st["SessionById"], sid, <||>];
    <|"Session" -> sid,
      "Subject" -> With[{t = Lookup[Lookup[r, "Citation", <||>], "Title", ""]},
        If[t =!= "", t, iSVMBShort[Lookup[sess, "MailRefs", {}], 40]]],
      "Score" -> Round[Lookup[r, "Score", 0.], 0.01],
      "Snippet" -> iSVMBShort[Lookup[r, "Snippet", ""], 80],
      "MailCount" -> Lookup[sess, "MailCount", Missing[]]|>]], rows]];

Options[SourceVault`SourceVaultMailBrowseThread] = {"MBox" -> Automatic};
SourceVault`SourceVaultMailBrowseThread[sessionId_String, OptionsPattern[]] := Module[
  {st = iSVMBState[OptionValue["MBox"]], sess, dig, refs, topicRefs, inner},
  If[! iSVMBLoadedQ[st], Return[Missing["NotLoaded"]]];
  sess = Lookup[st["SessionById"], sessionId, Missing["SessionNotFound", sessionId]];
  If[MissingQ[sess], Return[sess]];
  dig = SourceVault`SourceVaultMailStructSessionDigest[sess, st["Structure"]];
  refs = Lookup[sess, "MailRefs", {}];
  topicRefs = DeleteDuplicates @ Flatten[
    Lookup[Lookup[Lookup[st["Structure"], "ParagraphTopics", <||>], #, <||>],
      "TopicRefs", {}] & /@ refs];
  inner = Select[Flatten[Lookup[st["EdgesFrom"], refs, {}]],
    AssociationQ[#] && MemberQ[refs, Lookup[#, "ToMailRef", ""]] &];
  <|"Session" -> sessionId, "Subject" -> Lookup[dig, "Subject", ""],
    "SessionKind" -> Lookup[sess, "SessionKind", "Reply"],
    "MailRefs" -> refs, "MailCount" -> Lookup[sess, "MailCount", Length[refs]],
    "Digest" -> Lookup[dig, "CurrentDigest", ""],
    "HistoricalReferences" -> Lookup[dig, "HistoricalReferences", {}],
    "CrossSessionReferences" -> Lookup[sess, "CrossSessionReferences", {}],
    "Topics" -> Lookup[dig, "Topics", {}],
    "TopicRefs" -> topicRefs,
    "TopicLabels" -> DeleteDuplicates @ DeleteCases[
      (Lookup[st["RefLabel"], #, ""] & /@ topicRefs), ""],
    "QuoteEdges" -> inner, "Released" -> True|>];

Options[SourceVault`SourceVaultMailBrowseMail] = {"MBox" -> Automatic};
SourceVault`SourceVaultMailBrowseMail[mailRefIn_String, OptionsPattern[]] := Module[
  {st = iSVMBState[OptionValue["MBox"]], mailRef, rec, topicRefs},
  If[! iSVMBLoadedQ[st], Return[Missing["NotLoaded"]]];
  mailRef = iSVMBMailRef[mailRefIn];
  rec = Lookup[st["RecordByRef"], mailRef, Missing["MailNotFound", mailRef]];
  If[MissingQ[rec], Return[rec]];
  topicRefs = Lookup[Lookup[Lookup[st["Structure"], "ParagraphTopics", <||>], mailRef, <||>],
    "TopicRefs", {}];
  Join[rec, <|
    "Session" -> Lookup[st["SessionOfMail"], mailRef, Missing["NoSession"]],
    "TopicRefs" -> topicRefs,
    "TopicLabels" -> DeleteDuplicates @ DeleteCases[
      (Lookup[st["RefLabel"], #, ""] & /@ topicRefs), ""],
    "Cites" -> Lookup[st["EdgesFrom"], mailRef, {}],
    "CitedBy" -> Lookup[st["EdgesTo"], mailRef, {}]|>]];

(* ================= core: topic ================= *)

(* topic ref または label -> topic ref *)
iSVMBResolveTopic[st_Association, topic_String] := Which[
  KeyExistsQ[Lookup[st, "TopicMailIndex", <||>], topic], topic,
  KeyExistsQ[Lookup[st, "RefLabel", <||>], topic], topic,   (* mail 0 通でも label は引ける *)
  KeyExistsQ[Lookup[st, "TopicLabelIndex", <||>], iSVMBNormKey[topic]],
    st["TopicLabelIndex"][iSVMBNormKey[topic]],
  True, Missing["TopicNotFound", topic]];

Options[SourceVault`SourceVaultMailBrowseTopicMails] = {"MBox" -> Automatic};
SourceVault`SourceVaultMailBrowseTopicMails[topic_String, OptionsPattern[]] := Module[
  {st = iSVMBState[OptionValue["MBox"]], ref},
  If[! iSVMBLoadedQ[st], Return[Missing["NotLoaded"]]];
  ref = iSVMBResolveTopic[st, topic];
  If[MissingQ[ref], Return[ref]];
  <|"TopicRef" -> ref, "Label" -> Lookup[st["RefLabel"], ref, ref],
    "MailRefs" -> Lookup[st["TopicMailIndex"], ref, {}]|>];

Options[SourceVault`SourceVaultMailBrowseTopicSessions] = {"MBox" -> Automatic};
SourceVault`SourceVaultMailBrowseTopicSessions[topic_String, OptionsPattern[]] := Module[
  {st = iSVMBState[OptionValue["MBox"]], tm, bySess, order},
  If[! iSVMBLoadedQ[st], Return[Missing["NotLoaded"]]];
  tm = SourceVault`SourceVaultMailBrowseTopicMails[topic, "MBox" -> OptionValue["MBox"]];
  If[MissingQ[tm], Return[tm]];
  bySess = GroupBy[tm["MailRefs"],
    Lookup[st["SessionOfMail"], #, Missing["NoSession"]] &];
  bySess = KeySelect[bySess, StringQ];
  (* 該当メールの時間順 (tm["MailRefs"] が時間順なので初出順に並ぶ) *)
  order = Select[DeleteDuplicates[
    Lookup[st["SessionOfMail"], #, Missing["NoSession"]] & /@ tm["MailRefs"]], StringQ];
  Map[Function[sid, Module[{sess = Lookup[st["SessionById"], sid, <||>], sm},
    sm = DeleteMissing[Lookup[st["RecordByRef"], Lookup[sess, "MailRefs", {}]]];
    <|"Session" -> sid, "Subject" -> iSVMBSessionSubject[sm],
      "MailCount" -> Lookup[sess, "MailCount", 0],
      "MatchingMailRefs" -> Lookup[bySess, sid, {}]|>]], order]];

Options[SourceVault`SourceVaultMailBrowseTopicStep] = {"MBox" -> Automatic};
SourceVault`SourceVaultMailBrowseTopicStep[topic_String, mailRefIn_String, dir_Integer,
  OptionsPattern[]] := Module[
  {st = iSVMBState[OptionValue["MBox"]], tm, lst, mailRef, pos},
  If[! iSVMBLoadedQ[st], Return[Missing["NotLoaded"]]];
  tm = SourceVault`SourceVaultMailBrowseTopicMails[topic, "MBox" -> OptionValue["MBox"]];
  If[MissingQ[tm], Return[tm]];
  lst = tm["MailRefs"]; mailRef = iSVMBMailRef[mailRefIn];
  pos = FirstPosition[lst, mailRef, Missing[], {1}, Heads -> False];
  Which[
    MissingQ[pos],
      (* 現メールが列に無い場合は日付基準で前後を探す *)
      Module[{k = iSVMBDateKey[Lookup[Lookup[st["RecordByRef"], mailRef, <||>], "Date", ""]], cand},
        cand = If[dir < 0,
          Select[lst, iSVMBDateKey[Lookup[Lookup[st["RecordByRef"], #, <||>], "Date", ""]] < k &],
          Select[lst, iSVMBDateKey[Lookup[Lookup[st["RecordByRef"], #, <||>], "Date", ""]] > k &]];
        If[cand === {}, Missing["NoStep"], If[dir < 0, Last[cand], First[cand]]]],
    dir < 0, If[pos[[1]] <= 1, Missing["NoStep"], lst[[pos[[1]] - 1]]],
    True, If[pos[[1]] >= Length[lst], Missing["NoStep"], lst[[pos[[1]] + 1]]]]];

Options[SourceVault`SourceVaultMailBrowseTopicRelated] = {"MBox" -> Automatic, "Limit" -> 10};
SourceVault`SourceVaultMailBrowseTopicRelated[topic_String, OptionsPattern[]] := Module[
  {st = iSVMBState[OptionValue["MBox"]], ref, tg, out, incoming},
  If[! iSVMBLoadedQ[st], Return[Missing["NotLoaded"]]];
  ref = iSVMBResolveTopic[st, topic];
  If[MissingQ[ref], Return[ref]];
  tg = Lookup[st["Structure"], "TopicGraph", <||>];
  out = (<|"Topic" -> #["To"], "Label" -> Lookup[st["RefLabel"], #["To"], #["To"]],
      "Kind" -> #["Kind"], "Weight" -> #["Weight"], "Direction" -> "Out"|>) & /@
    Select[Lookup[tg, ref, {}], AssociationQ];
  incoming = (<|"Topic" -> #["From"], "Label" -> Lookup[st["RefLabel"], #["From"], #["From"]],
      "Kind" -> #["Kind"], "Weight" -> #["Weight"], "Direction" -> "In"|>) & /@
    Select[Flatten[Values[tg]], AssociationQ[#] && Lookup[#, "To", ""] === ref &];
  Take[ReverseSortBy[Join[out, incoming], Lookup[#, "Weight", 0.] &],
    UpTo[OptionValue["Limit"]]]];

(* ================= View helper ================= *)

(* NBAccess の機密セル視覚オプション (未ロード時は赤背景 fallback) *)
iSVMBConfCellOpts[] := With[{o = NBAccess`$NBConfidentialCellOpts},
  If[ListQ[o], o, {Background -> RGBColor[1, 0.9, 0.9]}]];

(* ボタンから開く新規ノートブックは Output スタイル (ShowStringCharacters 無効) *)
iSVMBOpenDoc[expr_] := CreateDocument[ExpressionCell[expr, "Output"]];

(* 複数行文字列は行分割 Column (Style[複数行] は改行が \n 文字で見える既知罠) *)
iSVMBTextBlock[s_String, size_: 11] := Column[
  Style[If[# === "", " ", #], size] & /@
    StringSplit[StringReplace[s, {"\r\n" -> "\n", "\r" -> "\n"}], "\n"],
  Spacings -> 0.1];
iSVMBTextBlock[s_, size_: 11] := Style[ToString[s], size, GrayLevel[0.5]];

(* インライン評価の Out セルを機密マーク (OOPS 第8.5R と同型)。
   Out セルは評価終了後に FE が書くため、EvaluationCell を捕まえ ScheduledTask で
   NextCell[Out] に SetOptions する (冪等)。headless は $Notebooks ガードで no-op。 *)
iSVMBMarkEvaluationOutput[pl_?NumericQ] := Quiet @ Check[
  If[pl > 0.5 && ! TrueQ[$svMBInDocCell] && TrueQ[$Notebooks],
    Module[{ec = EvaluationCell[]},
      If[Head[ec] === CellObject,
        With[{ecL = ec, plL = N[pl]},
          SessionSubmit[ScheduledTask[
            Module[{out = NextCell[ecL, CellStyle -> "Output"]},
              If[Head[out] === CellObject,
                SetOptions[out, Sequence @@ iSVMBConfCellOpts[],
                  TaggingRules -> {"claudecode" ->
                    {"privacyLevel" -> plL, "confidential" -> True}}]]],
            {0.5, 4}]]]]]], Null];

(* メール本文ノートブックのセル式 (headless テスト可能)。PL > 0.5 は機密セル。 *)
iSVMBMailDocCell[mailRef_String, mbox_String] := Module[{m, pl, confOpts, view},
  m = SourceVault`SourceVaultMailBrowseMail[mailRef, "MBox" -> mbox];
  pl = If[AssociationQ[m], iSVMBPL[m], 1.0];
  confOpts = If[pl > 0.5, iSVMBConfCellOpts[], {}];
  view = Block[{$svMBInDocCell = True},
    SourceVault`SourceVaultMailBrowseMailView[mailRef, "MBox" -> mbox]];
  ExpressionCell[view, "Output",
    TaggingRules -> {"claudecode" ->
      {"privacyLevel" -> pl, "confidential" -> (pl > 0.5)}},
    Sequence @@ confOpts]];

iSVMBOpenMailDoc[mailRef_String, mbox_String] :=
  CreateDocument[iSVMBMailDocCell[mailRef, mbox]];

SourceVault`SourceVaultMailBrowseOpenMail[mailRefIn_String, mbox_String: ""] :=
  iSVMBOpenMailDoc[iSVMBMailRef[mailRefIn], iSVMBResolveMBox[If[mbox === "", Automatic, mbox]]];

(* ボタン: 値 (文字列) だけ With で焼き込む (Module シンボル焼込は無反応の既知罠) *)
iSVMBMailButton[mailRef_String, mbox_String, label_] := With[{mr = mailRef, mb = mbox},
  Button[Style[label, 10, RGBColor[0.1, 0.3, 0.7]],
    iSVMBOpenMailDoc[mr, mb], Appearance -> "Frameless", Alignment -> Left]];

iSVMBSessionButton[sessionId_String, mbox_String, label_] := With[{sid = sessionId, mb = mbox},
  Button[Style[label, 10, RGBColor[0.1, 0.3, 0.7]],
    iSVMBOpenDoc[SourceVault`SourceVaultMailBrowseThreadView[sid, "MBox" -> mb]],
    Appearance -> "Frameless", Alignment -> Left]];

(* ⇄ 関連 (crosslink 層への遷移。後ロードのため必ず完全修飾・未ロードならダイアログ) *)
iSVMBCrossLinkButton[kind_String, id_String, mbox_String] := With[{k = kind, i = id, b = mbox},
  Button[Style["⇄ 関連", 10, RGBColor[0., 0.45, 0.35]],
    If[DownValues[SourceVault`SourceVaultCrossLinksView] === {},
      MessageDialog["DB 横断リンク層 (SourceVault_crosslink.wl) が未ロードです。"],
      iSVMBOpenDoc[SourceVault`SourceVaultCrossLinksView[
        <|"Kind" -> k, "Id" -> i, "MBox" -> b|>]]],
    Appearance -> "Frameless", Method -> "Queued"]];

(* topic チップ: [label](prev/next)。label -> topic スレッド一覧、prev/next ->
   時間順 (スレッド超え) の前後メール。OOPS の [ns id](prev/next) と同型。 *)
iSVMBTopicStepOpen[topicRef_String, mailRef_String, mbox_String, dir_Integer] := Module[{nxt},
  nxt = SourceVault`SourceVaultMailBrowseTopicStep[topicRef, mailRef, dir, "MBox" -> mbox];
  If[MissingQ[nxt],
    MessageDialog["topic を含む" <> If[dir < 0, "前", "次"] <> "のメールはありません。"],
    iSVMBOpenMailDoc[nxt, mbox]]];

iSVMBTopicChip[topicRef_String, label_String, mailRef_String, mbox_String] := With[
  {tr = topicRef, lb = label, mr = mailRef, mb = mbox},
  Row[{
    Button[Style["[" <> lb <> "]", 10, RGBColor[0.55, 0.25, 0.65]],
      iSVMBOpenDoc[SourceVault`SourceVaultMailBrowseTopicThreadList[tr, "MBox" -> mb]],
      Appearance -> "Frameless"],
    Style["(", 10, GrayLevel[0.5]],
    Button[Style["prev", 10, RGBColor[0.1, 0.3, 0.7]],
      iSVMBTopicStepOpen[tr, mr, mb, -1], Appearance -> "Frameless"],
    Style["/", 10, GrayLevel[0.5]],
    Button[Style["next", 10, RGBColor[0.1, 0.3, 0.7]],
      iSVMBTopicStepOpen[tr, mr, mb, 1], Appearance -> "Frameless"],
    Style[")", 10, GrayLevel[0.5]]}]];

(* 引用/被引用 edge の 1 行リンク: [Role] 相手メールボタン *)
iSVMBEdgeRow[edge_Association, other_String, mbox_String, st_Association] := Module[
  {rec = Lookup[Lookup[st, "RecordByRef", <||>], other, <||>], label},
  label = Row[{
    iSVMBShort[Lookup[rec, "Subject", other], 44], "  (",
    iSVMBShort[Lookup[rec, "Date", ""], 16], ")"}];
  Row[{
    Style["[" <> ToString @ Lookup[edge, "RelationRole", Lookup[edge, "EdgeKind", ""]] <> "] ",
      9, GrayLevel[0.45]],
    iSVMBMailButton[other, mbox, label]}]];

(* ---- 本文レンダリング: URL リンク + [ns id] OOPS topic ref リンク ---- *)

iSVMBLineTokens[line_String] := Module[{refs, urls, all, out = {}, lastEnd = 0},
  refs = {#[[1]], #[[2]], "OOPSRef"} & /@
    StringPosition[line, RegularExpression["\\[[A-Za-z]+[ \\t]*[0-9]+\\]"]];
  urls = {#[[1]], #[[2]], "URL"} & /@
    StringPosition[line,
      RegularExpression["(?:https?|ftp)://[0-9A-Za-z\\-._~:/?#@!$&*+,;=%]+"]];
  all = SortBy[Join[refs, urls], First];
  Do[If[t[[1]] > lastEnd, AppendTo[out, t]; lastEnd = t[[2]]], {t, all}];
  out];

(* [ns id] は OOPS topic ref とみなし、クリックで OOPS 側のスレッド一覧を開く
   (OOPS アーカイブ未ロード時はダイアログ)。一般メールから OOPS への横断リンク。 *)
iSVMBLineToken["OOPSRef", tok_String, size_] := Module[{m},
  m = StringCases[tok, RegularExpression["\\[([A-Za-z]+)[ \\t]*([0-9]+)\\]"] -> {"$1", "$2"}];
  If[m === {}, Style[tok, size],
    With[{ns = m[[1, 1]], id = m[[1, 2]], tk = tok},
      Button[Style[tk, size, RGBColor[0.55, 0.25, 0.65]],
        If[DownValues[SourceVault`SourceVaultOOPSTopicThreadList] === {} ||
            ! TrueQ[Lookup[SourceVault`$svOOPSState, "Loaded", False]],
          MessageDialog["OOPS アーカイブが未ロードです (SourceVaultOOPSEnsureLoaded[])。"],
          iSVMBOpenDoc[SourceVault`SourceVaultOOPSTopicThreadList[ns <> " " <> id]]],
        Appearance -> "Frameless", Method -> "Queued"]]]];
iSVMBLineToken["URL", tok_String, size_] := Module[{url = tok, trail = ""},
  While[StringLength[url] > 0 && MemberQ[{".", ",", ";", ":"}, StringTake[url, -1]],
    trail = StringTake[url, -1] <> trail; url = StringDrop[url, -1]];
  Row[{Hyperlink[Style[url, size], url],
    If[trail === "", Nothing, Style[trail, size]]}]];
iSVMBLineToken[_, tok_String, size_] := Style[tok, size];

iSVMBBodyLine[line_String, size_: 11] := Module[{toks, out = {}, last = 1},
  toks = iSVMBLineTokens[line];
  If[toks === {},
    Return[Style[If[StringTrim[line] === "", " ", line], size]]];
  Do[Module[{s = t[[1]], e = t[[2]]},
    If[s > last, AppendTo[out, Style[StringTake[line, {last, s - 1}], size]]];
    AppendTo[out, iSVMBLineToken[t[[3]], StringTake[line, {s, e}], size]];
    last = e + 1], {t, toks}];
  If[last <= StringLength[line],
    AppendTo[out, Style[StringTake[line, {last, -1}], size]]];
  Row[out]];

iSVMBBodyBlock[body_String, size_: 11] := Column[
  iSVMBBodyLine[#, size] & /@
    StringSplit[StringReplace[body, {"\r\n" -> "\n", "\r" -> "\n"}], "\n"],
  Spacings -> 0.1];

(* ================= View ================= *)

Options[SourceVault`SourceVaultMailBrowseMailView] = {"MBox" -> Automatic};
SourceVault`SourceVaultMailBrowseMailView[mailRefIn_String, OptionsPattern[]] := Module[
  {mbox, st, m, mailRef, pl, sess, sessRow, topicRow, citeRows, citedRows, body, bodyDisp},
  mbox = iSVMBResolveMBox[OptionValue["MBox"]];
  st = iSVMBState[mbox];
  If[! iSVMBLoadedQ[st],
    Return[Style["mailbrowse 未ロード: SourceVaultMailBrowseEnsureLoaded[\"" <> mbox <> "\"]",
      Italic, GrayLevel[0.4]]]];
  m = SourceVault`SourceVaultMailBrowseMail[mailRefIn, "MBox" -> mbox];
  If[MissingQ[m],
    Return[Style["メールが見つかりません: " <> mailRefIn <>
      "  (state 再構築後の古いリンク、または別 mbox の可能性)", Italic, GrayLevel[0.4]]]];
  mailRef = Lookup[m, "MailRef", iSVMBMailRef[mailRefIn]];
  pl = iSVMBPL[m];
  iSVMBMarkEvaluationOutput[pl];
  sess = Lookup[m, "Session", Missing[]];
  sessRow = If[! StringQ[sess], Nothing,
    Module[{sids = Lookup[Lookup[st["SessionById"], sess, <||>], "MailRefs", {}], sibs},
      sibs = Take[DeleteCases[sids, mailRef], UpTo[24]];
      Row[{Style["スレッド: ", GrayLevel[0.3], 10],
        iSVMBSessionButton[sess, mbox, iSVMBShort[sess, 40]],
        If[sibs === {}, Nothing,
          Row[{Style["   他メール: ", GrayLevel[0.3], 10],
            Row[MapIndexed[Function[{mr, i},
              iSVMBMailButton[mr, mbox, "#" <> ToString[i[[1]]]]], sibs], "  "]}]],
        With[{rest = Length[sids] - 1 - 24},
          If[rest > 0, Style[Row[{"  … 他 ", rest, " 通"}], GrayLevel[0.5], 10], Nothing]]}]]];
  topicRow = If[Lookup[m, "TopicRefs", {}] === {}, Nothing,
    Row[Prepend[
      Riffle[MapThread[
        iSVMBTopicChip[#1, iSVMBShort[#2, 22], mailRef, mbox] &,
        {Lookup[m, "TopicRefs", {}],
         With[{rl = st["RefLabel"]},
           Lookup[rl, #, StringTake[#, UpTo[18]]] & /@ Lookup[m, "TopicRefs", {}]]}], "  "],
      Style["topic: ", GrayLevel[0.3], 10]]]];
  citeRows = If[Lookup[m, "Cites", {}] === {}, Nothing,
    Column[Prepend[
      iSVMBEdgeRow[#, Lookup[#, "ToMailRef", ""], mbox, st] & /@
        Take[Lookup[m, "Cites", {}], UpTo[12]],
      Style["引用・参照先:", Bold, 10]], Spacings -> 0.15]];
  citedRows = If[Lookup[m, "CitedBy", {}] === {}, Nothing,
    Column[Prepend[
      iSVMBEdgeRow[#, Lookup[#, "FromMailRef", ""], mbox, st] & /@
        Take[Lookup[m, "CitedBy", {}], UpTo[12]],
      Style["被引用 (このメールを引用):", Bold, 10]], Spacings -> 0.15]];
  body = Lookup[m, "Body", ""];
  bodyDisp = Which[
    ! StringQ[body],
      Style["(本文なし: " <> ToString[body] <> ")", Italic, GrayLevel[0.5]],
    StringLength[body] > 3000,
      Pane[iSVMBBodyBlock[body], ImageSize -> {Full, 480},
        Scrollbars -> {False, Automatic}],
    True, iSVMBBodyBlock[body]];
  Column[{
    Style[Row[{Lookup[m, "Subject", "(件名なし)"]}], Bold, 14],
    Row[{Style[Row[{"From: ", iSVMBShort[Lookup[m, "From", ""], 40],
        "    Date: ", iSVMBShort[Lookup[m, "Date", ""], 20],
        "    To: ", iSVMBShort[Lookup[m, "To", ""], 30], "    PL: "}], GrayLevel[0.4], 10],
      Style[pl, 10, Bold,
        If[pl > 0.5, RGBColor[0.75, 0.1, 0.1], GrayLevel[0.4]]],
      Style["   ", 10],
      iSVMBCrossLinkButton["mail", mailRef, mbox]}],
    sessRow, topicRow, citeRows, citedRows,
    Framed[bodyDisp, FrameStyle -> LightGray, Background -> GrayLevel[0.985]]},
    Spacings -> 1]];

Options[SourceVault`SourceVaultMailBrowseThreadView] = {"MBox" -> Automatic};
SourceVault`SourceVaultMailBrowseThreadView[sessionId_String, OptionsPattern[]] := Module[
  {mbox, st, det, cap, mailRows, topicRow, histRows},
  mbox = iSVMBResolveMBox[OptionValue["MBox"]];
  st = iSVMBState[mbox];
  If[! iSVMBLoadedQ[st],
    Return[Style["mailbrowse 未ロード: SourceVaultMailBrowseEnsureLoaded[\"" <> mbox <> "\"]",
      Italic, GrayLevel[0.4]]]];
  det = SourceVault`SourceVaultMailBrowseThread[sessionId, "MBox" -> mbox];
  If[MissingQ[det],
    Return[Style["スレッドが見つかりません: " <> sessionId <>
      "  (state 再構築後の古いリンク、または別 mbox の可能性。" <>
      "SourceVaultMailBrowseEnsureLoaded を実行した最新の出力から辿り直してください)",
      Italic, GrayLevel[0.4]]]];
  cap = SourceVault`$SourceVaultMailBrowseViewMaxRows;
  mailRows = Function[mr, Module[{rec = Lookup[st["RecordByRef"], mr, <||>]},
    iSVMBMailButton[mr, mbox, Row[{
      iSVMBShort[Lookup[rec, "From", ""], 26], " — ",
      iSVMBShort[Lookup[rec, "Subject", ""], 44], "  (",
      iSVMBShort[Lookup[rec, "Date", ""], 17], ")"}]]]] /@
    Take[det["MailRefs"], UpTo[cap]];
  If[Length[det["MailRefs"]] > cap,
    AppendTo[mailRows, Style[Row[{"… 他 ", Length[det["MailRefs"]] - cap,
      " 通 (SourceVaultMailBrowseMailView[mailRef] で個別に開く)"}], GrayLevel[0.5], 10]]];
  topicRow = If[det["TopicRefs"] === {}, Nothing,
    Row[Prepend[
      Riffle[Map[Function[tr, With[{trL = tr, mb = mbox,
          lb = iSVMBShort[Lookup[st["RefLabel"], tr, StringTake[tr, UpTo[18]]], 22]},
        Button[Style["[" <> lb <> "]", 10, RGBColor[0.55, 0.25, 0.65]],
          iSVMBOpenDoc[SourceVault`SourceVaultMailBrowseTopicThreadList[trL, "MBox" -> mb]],
          Appearance -> "Frameless"]]], Take[det["TopicRefs"], UpTo[12]]], "  "],
      Style["topic: ", GrayLevel[0.3], 10]]]];
  histRows = If[Lookup[det, "CrossSessionReferences", {}] === {}, Nothing,
    Column[Prepend[
      Map[Function[cr, Module[{toSess},
        toSess = Lookup[st["SessionOfMail"], Lookup[cr, "To", ""], Missing[]];
        Row[{Style["[" <> ToString @ Lookup[cr, "Role", ""] <> "] ", 9, GrayLevel[0.45]],
          iSVMBMailButton[Lookup[cr, "From", ""], mbox,
            iSVMBShort[Lookup[Lookup[st["RecordByRef"], Lookup[cr, "From", ""], <||>],
              "Subject", Lookup[cr, "From", ""]], 30]],
          Style[" → ", 10, GrayLevel[0.5]],
          iSVMBMailButton[Lookup[cr, "To", ""], mbox,
            iSVMBShort[Lookup[Lookup[st["RecordByRef"], Lookup[cr, "To", ""], <||>],
              "Subject", Lookup[cr, "To", ""]], 30]],
          If[StringQ[toSess] && toSess =!= sessionId,
            Row[{Style["  (", 9, GrayLevel[0.5]],
              iSVMBSessionButton[toSess, mbox, "→スレッド"],
              Style[")", 9, GrayLevel[0.5]]}], Nothing]}]]],
        Take[Lookup[det, "CrossSessionReferences", {}], UpTo[12]]],
      Style["歴史参照 (別スレッドとの引用関係):", Bold, 10]], Spacings -> 0.15]];
  Column[{
    Style[det["Subject"], Bold, 16],
    Row[{Style[Row[{det["SessionKind"], " — ", det["MailCount"], " 通   "}], GrayLevel[0.4]],
      iSVMBCrossLinkButton["mail-thread", sessionId, mbox]}],
    topicRow,
    Style["メール一覧 (クリックで全文):", Bold],
    Column[mailRows, Spacings -> 0.2],
    histRows,
    Style["スレッド要約:", Bold],
    Framed[iSVMBTextBlock[det["Digest"]], FrameStyle -> LightGray,
      Background -> GrayLevel[0.97]]},
    Spacings -> 1]];

Options[SourceVault`SourceVaultMailBrowseTopicThreadList] = {"MBox" -> Automatic};
SourceVault`SourceVaultMailBrowseTopicThreadList[topic_String, OptionsPattern[]] := Module[
  {mbox, st, tm, sessRows, cap, rows},
  mbox = iSVMBResolveMBox[OptionValue["MBox"]];
  st = iSVMBState[mbox];
  If[! iSVMBLoadedQ[st],
    Return[Style["mailbrowse 未ロード: SourceVaultMailBrowseEnsureLoaded[\"" <> mbox <> "\"]",
      Italic, GrayLevel[0.4]]]];
  tm = SourceVault`SourceVaultMailBrowseTopicMails[topic, "MBox" -> mbox];
  If[MissingQ[tm],
    Return[Style["topic が見つかりません: " <> topic, Italic, GrayLevel[0.4]]]];
  sessRows = SourceVault`SourceVaultMailBrowseTopicSessions[topic, "MBox" -> mbox];
  If[sessRows === {} || MissingQ[sessRows],
    Return[Style["topic [" <> tm["Label"] <> "] を含むメールはありません。",
      Italic, GrayLevel[0.4]]]];
  cap = SourceVault`$SourceVaultMailBrowseViewMaxRows;
  rows = Map[Function[s,
    {iSVMBSessionButton[s["Session"], mbox,
       Style[If[s["Subject"] === "", s["Session"], iSVMBShort[s["Subject"], 50]], 12]],
     s["MailCount"],
     Row[MapIndexed[Function[{mr, i},
       iSVMBMailButton[mr, mbox, "#" <> ToString[i[[1]]]]],
       Take[s["MatchingMailRefs"], UpTo[12]]], "  "]}],
    Take[sessRows, UpTo[cap]]];
  Column[{
    Row[{Style[Row[{"topic [", tm["Label"], "] を含むスレッド (",
        Length[sessRows], " 件 / 該当 ", Length[tm["MailRefs"]], " 通)   "}], Bold, 13],
      iSVMBCrossLinkButton["topic", tm["TopicRef"], mbox]}],
    Grid[Prepend[rows,
      Style[#, Bold] & /@ {"Subject (クリックでスレッド)", "通数", "該当メール (時間順)"}],
      Frame -> All, Alignment -> {Left, Center},
      Background -> {None, {LightBlue, None}}],
    If[Length[sessRows] > cap,
      Style[Row[{"… 他 ", Length[sessRows] - cap, " スレッド"}], GrayLevel[0.5], 10], Nothing]},
    Spacings -> 1]];

Options[SourceVault`SourceVaultMailBrowseSearchThreadsView] = {"MBox" -> Automatic, "Limit" -> 10,
  "MinScore" -> Automatic};
SourceVault`SourceVaultMailBrowseSearchThreadsView[query_String, OptionsPattern[]] := Module[
  {mbox, rows, minS = OptionValue["MinScore"]},
  mbox = iSVMBResolveMBox[OptionValue["MBox"]];
  rows = SourceVault`SourceVaultMailBrowseSearchThreads[query,
    "MBox" -> mbox, "Limit" -> OptionValue["Limit"], "MinScore" -> minS];
  If[rows === {}, Return[Style["(ヒットなし)", Italic, GrayLevel[0.5]]]];
  Column[{
    Grid[Prepend[
      Map[Function[r,
        {iSVMBSessionButton[r["Session"], mbox,
           Style[If[r["Subject"] === "", r["Session"], iSVMBShort[r["Subject"], 50]], 12]],
         Lookup[r, "MailCount", ""], r["Score"],
         Style[r["Snippet"], 10, GrayLevel[0.35]]}], rows],
      Style[#, Bold] & /@ {"Subject (クリックでスレッド)", "通数", "Score", "Snippet"}],
      Frame -> All, Alignment -> {Left, Center},
      Background -> {None, {LightBlue, None}}],
    If[minS === None || minS === 0 || minS === 0., Nothing,
      Style["低スコアの弱一致 (bigram 部分一致) は非表示。全件は \"MinScore\" -> None。",
        8.5, GrayLevel[0.55]]]},
    Spacings -> 0.4]];

Options[SourceVault`SourceVaultMailBrowseThreadList] = {"MBox" -> Automatic, "MinMails" -> 1,
  "Limit" -> 30};
SourceVault`SourceVaultMailBrowseThreadList[OptionsPattern[]] := Module[{mbox, rows},
  mbox = iSVMBResolveMBox[OptionValue["MBox"]];
  rows = SourceVault`SourceVaultMailBrowseSessions["MBox" -> mbox,
    "MinMails" -> OptionValue["MinMails"], "Limit" -> OptionValue["Limit"]];
  If[rows === {}, Return[Style["(スレッドなし: SourceVaultMailBrowseEnsureLoaded[\"" <>
    mbox <> "\"] を先に実行)", Italic, GrayLevel[0.5]]]];
  Grid[Prepend[
    Map[Function[s,
      {iSVMBSessionButton[s["Session"], mbox,
         Style[If[s["Subject"] === "", s["Session"], iSVMBShort[s["Subject"], 50]], 12]],
       s["SessionKind"], s["MailCount"],
       Style[iSVMBShort[s["LastDate"], 17], 10, GrayLevel[0.4]]}], rows],
    Style[#, Bold] & /@ {"Subject (クリックで詳細)", "Kind", "通数", "最終"}],
    Frame -> All, Alignment -> {Left, Center},
    Background -> {None, {LightBlue, None}}]];

End[]

EndPackage[]
