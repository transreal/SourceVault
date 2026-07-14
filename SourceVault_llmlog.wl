(* ::Package:: *)

(* ============================================================
   SourceVault_llmlog.wl -- LLM 実行ログ (Claude Code セッション) ingest / 共有層

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_llmlog.wl"]]

   仕様書: ドキュメント/sourcevault_llm_execution_log_ingest_mcp_spec_v0_1.md
           (Phase 1 rollup + Phase 3 MCP adapter の縦 slice。
            対象ソースは Claude Code の ~/.claude/projects セッション JSONL)

   位置づけ:
     各 PC ローカルの Claude Code 実行ログ (transcript JSONL) は machine-local で
     他 PC から見えない。本層はセッション毎の「ダイジェスト」(メタデータ +
     bounded preview + ツール統計) を抽出し、CoreRoot(Dropbox 同期)/rollup/
     claudecode_sessions/<MachineTag>/YYYY-MM.jsonl へ append-only で集約する。
     生 transcript (数百 MB) は同期しない。読み手は全 machine の rollup を
     dedup (SessionId 毎に最新 digest) して読む。

   service-loadable 制約 (spec v6 §3.4):
     FrontEnd / Notebook / NBAccess / UI 依存を持たない。
     root 解決は core の SourceVaultRoot[...] / $SourceVaultCoreRoot を使う。
     webingest 等の他モジュールにも依存しない (helper は自前・fail-soft)。

   MCP 露出:
     adapter "llmlog" (kinds llmlog/claudecode)。URI は既存 record namespace を
     mail (svmail-) と同様に prefix で間借りする: sv://record/svcclog-<sessionId>。
     search 行は metadata/summary/snippet (bounded preview)。body (全 preview) は
     grant 必須 (RequireGrantFor body/raw)。
   ============================================================ *)

BeginPackage["SourceVault`"]

SourceVaultMachineTag::usage =
  "SourceVaultMachineTag[] は rollup namespace 用の正準 machine tag\n" <>
  "($MachineName を path-safe 化した文字列) を返す。";

$SourceVaultClaudeCodeLogRoots::usage =
  "$SourceVaultClaudeCodeLogRoots は Claude Code セッション JSONL の走査 root リスト\n" <>
  "(既定 {~/.claude/projects})。存在しない root は無視される。";

SourceVaultClaudeCodeSessionDigest::usage =
  "SourceVaultClaudeCodeSessionDigest[jsonlPath] は Claude Code セッション transcript\n" <>
  "(JSONL) からダイジェスト Association を作る。生ログは保存せず、Title/期間/モデル/\n" <>
  "ツール統計/編集ファイル/ユーザー発話 preview (bounded・秘密 token マスク) を抽出する。\n" <>
  "戻り値: <|ObjectClass->\"ClaudeCodeSessionDigest\", SessionId, MachineTag, Project,\n" <>
  "StartedAtUTC, LastAtUTC, ToolCounts, FilesTouched, UserPreviews, ...|>。";

SourceVaultIngestClaudeCodeLogs::usage =
  "SourceVaultIngestClaudeCodeLogs[] はローカル Claude Code セッションログを走査し、\n" <>
  "新規/更新セッションのダイジェストを <CoreRoot>/rollup/claudecode_sessions/<MachineTag>/\n" <>
  "YYYY-MM.jsonl へ追記する (append-only・watermark 冪等・非破壊)。\n" <>
  "オプション: \"DryRun\"(既定 False), \"MaxSessionsPerRun\"(既定 Automatic=無制限),\n" <>
  "\"MaxAgeDays\"(既定 180; All で全期間), \"MaxFileMB\"(既定 200)。\n" <>
  "戻り値: <|Status, MachineTag, Scanned, Changed, Ingested, Skipped, RollupDir, PerSession|>。";

SourceVaultClaudeCodeLogStatus::usage =
  "SourceVaultClaudeCodeLogStatus[] はローカル走査対象と rollup 集約状況\n" <>
  "(<|LocalSessions, UningestedSessions, RollupByMachine, RollupTotal, ...|>) を返す。";

SourceVaultClaudeCodeSessions::usage =
  "SourceVaultClaudeCodeSessions[] は全マシンの rollup からセッションダイジェストを読み、\n" <>
  "SessionId 毎に最新 1 件へ dedup したリストを返す (新しい順)。\n" <>
  "オプション: \"MachineTag\"->All|_String, \"Project\"->All|_String, \"Limit\"->All。";

SourceVaultClaudeCodeSessionSearch::usage =
  "SourceVaultClaudeCodeSessionSearch[query] は共有 rollup 上のセッションダイジェストを\n" <>
  "トークン単位 OR スコアリング (決定論 tie-break) で検索し、Score 付き Association の\n" <>
  "リストを返す (core 版; 表示は SourceVaultClaudeCodeSessionSearchView)。\n" <>
  "オプション: \"Limit\"(既定 20), \"MachineTag\"->All, \"Project\"->All。";

SourceVaultClaudeCodeSessionSearchView::usage =
  "SourceVaultClaudeCodeSessionSearchView[query] は SourceVaultClaudeCodeSessionSearch の\n" <>
  "Dataset 表示版 (表示件数制限付き)。";

SourceVaultClaudeCodeSessionGet::usage =
  "SourceVaultClaudeCodeSessionGet[sessionId] は sessionId のダイジェスト全体を返す\n" <>
  "(見つからなければ Missing[\"NotFound\"])。";

$SourceVaultClaudeCodeRawMirrorRoot::usage =
  "$SourceVaultClaudeCodeRawMirrorRoot は生 transcript ミラーの置き場所。\n" <>
  "既定 Automatic = <CoreRoot の親>/claudecodelogs (例 Dropbox/udb/claudecodelogs)。\n" <>
  "SourceVault store の外のプレーンなフォルダなので、肥大化したらフォルダごと\n" <>
  "オフライン化しても SourceVault 側は破綻しない (mails フォルダと同格の扱い)。";

SourceVaultMirrorClaudeCodeLogs::usage =
  "SourceVaultMirrorClaudeCodeLogs[] はローカル ~/.claude/projects の生ログ一式を\n" <>
  "<mirror>/<MachineTag>/ へ増分コピーする (サイズ差分のみ・tmp+rename・非破壊)。\n" <>
  "SourceVaultIngestClaudeCodeLogs から自動で呼ばれる (service 定期実行に相乗り)。\n" <>
  "オプション: \"DryRun\"(既定 False), \"MaxFilesPerRun\"(既定 Automatic=無制限)。\n" <>
  "戻り値: <|Status, MachineTag, Scanned, Copied, CopiedBytes, Skipped, Deferred, MirrorDir|>。";

SourceVaultClaudeCodeSessionTranscript::usage =
  "SourceVaultClaudeCodeSessionTranscript[sessionId] はセッションの生 transcript を\n" <>
  "ローカル ~/.claude/projects → Dropbox ミラー (他マシン分) の順で探して読み、\n" <>
  "対話 turn のリストに整形して返す (core 版)。生ログが無ければ digest の preview に\n" <>
  "フォールバック (Source -> \"digest\")。\n" <>
  "戻り値: <|SessionId, Source->\"local\"|\"mirror\"|\"digest\", Path, Turns->{<|Role,At,Text,Tools|>..}|>。\n" <>
  "オプション: \"IncludeMeta\"(既定 False; system-reminder 等を残すか)。";

SourceVaultClaudeCodeSessionView::usage =
  "SourceVaultClaudeCodeSessionView[sessionId] はセッション全文の表示版。\n" <>
  "ヘッダ (Title/マシン/期間/要約) + user/assistant の対話を整形表示する。\n" <>
  "オプション: \"MaxTurns\"(既定 80), \"MaxCharsPerTurn\"(既定 2000)。";

SourceVaultClaudeCodeSessionSummary::usage =
  "SourceVaultClaudeCodeSessionSummary[sessionId] はセッションダイジェストを LLM で\n" <>
  "2〜3文に要約し、共有 sidecar (<CoreRoot>/rollup/claudecode_sessions/_summaries/) に\n" <>
  "キャッシュする。キャッシュが Current (digest の LineCount 一致) なら再生成しない。\n" <>
  "ルーティング: digest の privacy <= 0.49 (通常のコード作業) は $ClaudeDocModel を\n" <>
  "主経路で直接呼び、失敗時のみ local ladder へ。privacy > 0.49 は local-first のまま。\n" <>
  "オプション: \"ForceRefresh\"(既定 False), \"MaxLength\"(既定 300),\n" <>
  "\"Model\"->Automatic (明示指定で主経路を上書き),\n" <>
  "\"FallbackToCloud\"(既定 \"Deny\"; local ladder 内の cloud fallback 可否)。\n" <>
  "戻り値: <|Status->\"OK\"|\"Failed\"|.., Summary, Cached, GeneratedBy, SessionId, ...|>。";

SourceVaultClaudeCodeSummarizeSessions::usage =
  "SourceVaultClaudeCodeSummarizeSessions[] は要約が未生成/stale のセッションを新しい順に\n" <>
  "まとめて LLM 要約する (同期実行; ローカル LLM で 1 件数秒〜数十秒)。\n" <>
  "オプション: \"Limit\"(既定 10), \"Query\"->None (文字列なら検索ヒットのみ対象),\n" <>
  "\"MachineTag\"->All, ほか SourceVaultClaudeCodeSessionSummary のオプション。\n" <>
  "戻り値: <|Requested, Generated, Cached, Failed, PerSession|>。";

SourceVaultRegisterLLMLogMCPAdapter::usage =
  "SourceVaultRegisterLLMLogMCPAdapter[] は MCP data adapter \"llmlog\" を登録する\n" <>
  "(kinds: llmlog/claudecode, URI: sv://record/svcclog-<sessionId>)。冪等。\n" <>
  "SourceVault_mcp.wl ロード後に呼ぶ (本ファイルロード時に自動試行)。";

$SourceVaultClaudeCodeIngestIntervalSeconds::usage =
  "$SourceVaultClaudeCodeIngestIntervalSeconds (既定 3600=1h) は service heartbeat ループが\n" <>
  "SourceVaultIngestClaudeCodeLogs を自動実行する最小間隔 (秒)。";

Begin["`PrivateLLMLog`"]

(* ============================================================
   小物 helper (service-loadable・自己完結。webingest と同型だが依存しない)
   ============================================================ *)

iSVLLEnsureDir[dir_String] :=
  If[! DirectoryQ[dir], Quiet @ CreateDirectory[dir, CreateIntermediateDirectories -> True], dir];
iSVLLEnsureDir[_] := $Failed;

iSVLLNowIso[] := DateString[DateObject[Now, TimeZone -> 0],
  {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"}];

(* JSON へ落とせない値の正規化 *)
iSVLLJSONSafe[expr_] := expr /. {
  d_DateObject :> DateString[d, "ISODateTime"],
  None -> Null,
  _Missing -> Null};

(* atomic overwrite JSON (UTF-8 bytes; 二重 encode しない) *)
iSVLLPutJSON[path_String, expr_] := Module[{bytes, tmp, strm},
  bytes = Quiet @ Check[ExportByteArray[iSVLLJSONSafe[expr], "RawJSON"], $Failed];
  If[! ByteArrayQ[bytes], Return[$Failed]];
  iSVLLEnsureDir[DirectoryName[path]];
  tmp = path <> ".tmp." <> ToString[$ProcessID] <> "." <> StringTake[CreateUUID[], 6];
  strm = Quiet @ OpenWrite[tmp, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  BinaryWrite[strm, bytes]; Close[strm];
  If[Quiet @ Check[RenameFile[tmp, path, OverwriteTarget -> True], $Failed] === $Failed,
    Quiet @ DeleteFile[tmp]; Return[$Failed]];
  path];

iSVLLGetJSON[path_String] := If[FileExistsQ[path],
  Quiet @ Check[ImportByteArray[ReadByteArray[path], "RawJSON"], $Failed],
  Missing["NoFile"]];

(* byte-safe JSONL 行読み (UTF-8 明示; CRLF/LF 両対応) *)
iSVLLReadJSONLLines[path_String] := Module[{ba, txt},
  If[! FileExistsQ[path], Return[{}]];
  ba = Quiet @ Check[ReadByteArray[path], $Failed];
  If[! ByteArrayQ[ba], Return[{}]];
  txt = Quiet @ Check[ByteArrayToString[ba, "UTF-8"], $Failed];
  If[! StringQ[txt], Return[{}]];
  Select[StringTrim /@ StringSplit[txt, {"\r\n", "\n"}], # =!= "" &]];
iSVLLReadJSONLLines[_] := {};

iSVLLParseJSONLine[line_String] :=
  Quiet @ Check[ImportByteArray[StringToByteArray[line, "UTF-8"], "RawJSON"], $Failed];

iSVLLAppendLines[path_String, lines_List] := Module[{strm},
  If[lines === {}, Return[path]];
  iSVLLEnsureDir[DirectoryName[path]];
  strm = Quiet @ OpenAppend[path, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  BinaryWrite[strm, StringToByteArray[StringRiffle[lines, "\n"] <> "\n", "UTF-8"]];
  Close[strm];
  path];

iSVLLEncodeJSONLine[rec_Association] := Quiet @ Check[
  ByteArrayToString[ExportByteArray[iSVLLJSONSafe[rec], "RawJSON", "Compact" -> True], "UTF-8"],
  $Failed];

(* ============================================================
   machine tag / directory 解決
   ============================================================ *)

SourceVault`SourceVaultMachineTag[] := Module[
  {h = StringReplace[ToString[$MachineName], Except[WordCharacter | "-"] -> "_"]},
  If[StringQ[h] && h =!= "", h, "unknown-host"]];

If[! ListQ[SourceVault`$SourceVaultClaudeCodeLogRoots],
  SourceVault`$SourceVaultClaudeCodeLogRoots =
    {FileNameJoin[{$HomeDirectory, ".claude", "projects"}]}];

If[! NumericQ[SourceVault`$SourceVaultClaudeCodeIngestIntervalSeconds],
  SourceVault`$SourceVaultClaudeCodeIngestIntervalSeconds = 3600];  (* 1h *)

iSVLLLocalStateDir[] := Module[{ls = SourceVault`SourceVaultRoot["LocalState"]},
  If[StringQ[ls], ls, $Failed]];

(* watermark: sessionKey -> <|"Bytes", "IngestedAtUTC"|> (LocalState 側; 生ログと同じ機械のみ) *)
iSVLLWatermarkPath[] := Module[{ls = iSVLLLocalStateDir[]},
  If[StringQ[ls], FileNameJoin[{ls, "hotlog", "claudecode_rollup", ".watermark.json"}], $Failed]];
iSVLLReadWatermark[] := Module[{p = iSVLLWatermarkPath[], r},
  If[! StringQ[p], Return[<||>]];
  r = iSVLLGetJSON[p];
  If[AssociationQ[r], r, <||>]];
iSVLLWriteWatermark[wm_Association] := Module[{p = iSVLLWatermarkPath[]},
  If[StringQ[p], iSVLLPutJSON[p, wm], $Failed]];

iSVLLRollupBaseDir[] := Module[{cr = SourceVault`SourceVaultCoreRoot[]},
  If[StringQ[cr], FileNameJoin[{cr, "rollup", "claudecode_sessions"}], $Failed]];
iSVLLRollupMachineDir[] := Module[{b = iSVLLRollupBaseDir[]},
  If[StringQ[b], FileNameJoin[{b, SourceVault`SourceVaultMachineTag[]}], $Failed]];

(* ============================================================
   セッション transcript のダイジェスト抽出
   ============================================================ *)

$iSVLLMaxLineChars = 2*10^6;      (* これより長い行 (巨大 tool result 等) は JSON parse しない *)
$iSVLLPreviewChars = 400;
$iSVLLMaxPreviews = 12;           (* 先頭 8 + 末尾 4 *)
$iSVLLMaxFiles = 40;

(* 秘密らしき token を preview から落とす (保存前 redaction は最小限; 高 privacy 既定で fail-closed) *)
iSVLLRedact[s_String] := StringReplace[s, {
  RegularExpression["(sk|key|token|pat|ghp|gho)-[A-Za-z0-9_\\-]{8,}"] -> "***",
  RegularExpression["(?i)bearer\\s+[A-Za-z0-9._\\-]{8,}"] -> "Bearer ***",
  RegularExpression["(?i)authorization:\\s*\\S+"] -> "Authorization: ***"}];
iSVLLRedact[_] := "";

(* system-reminder 等の注入ブロックを preview から除去して人間発話を残す *)
iSVLLCleanUserText[s_String] := StringTrim @ StringReplace[s, {
  Shortest["<system-reminder>" ~~ ___ ~~ "</system-reminder>"] -> "",
  Shortest["<command-message>" ~~ ___ ~~ "</command-message>"] -> ""}];

(* ハーネス生成プロンプト (ClaudeEval / doc updater 等のワンショット) から
   実タスク本文を抽出する。boilerplate ("You are an expert ..." /
   "## Project guidelines (CLAUDE.md)" + 注入 docs) を Title/preview/検索から
   排除するため。マーカーが無ければ原文を返す (対話セッションは素通し)。
   形式1 (documentation updater):
     "=== TASK OVERVIEW (...) ===\n<task>\n(Full task details ...)\n=== END TASK OVERVIEW ==="
   形式2 (ClaudeEval codegen): 末尾の "Task: <task>" (iClaudeSysPrompt/contextPrompt) *)
iSVLLExtractTaskText[s_String] := Module[{m, t},
  (* 形式1: TASK OVERVIEW ブロック *)
  m = StringCases[s,
    Shortest["=== TASK OVERVIEW" ~~ __ ~~ "===" ~~ body__ ~~ "=== END TASK OVERVIEW"] :> body, 1];
  If[m =!= {},
    t = StringReplace[First[m], Shortest["(Full task details" ~~ ___ ~~ ")"] -> ""];
    t = StringTrim[t];
    If[t =!= "", Return[t]]];
  (* 形式2: boilerplate らしき冒頭のときのみ、最後の "Task: " 以降を採る *)
  If[StringStartsQ[s, "You are an expert"] ||
     StringStartsQ[s, "## Project guidelines"],
    m = StringPosition[s, "\nTask: "];
    If[m =!= {},
      t = StringTrim @ StringDrop[s, m[[-1, 2]]];
      If[t =!= "", Return[t]]]];
  s];
iSVLLExtractTaskText[x_] := ToString[x];

(* セッション種別: ワンショット・ハーネス (Claude Working の一時 project) か対話か *)
iSVLLSessionKind[project_, cwd_] := If[
  StringContainsQ[ToString[project], "claude-project-", IgnoreCase -> True] ||
    StringContainsQ[ToString[cwd], "Claude Working", IgnoreCase -> True],
  "harness", "interactive"];

iSVLLPreview[s_String] := iSVLLRedact @ StringTake[s, UpTo[$iSVLLPreviewChars]];

(* content ブロックリストから text を集める (tool_result は無視) *)
iSVLLBlocksText[blocks_List] := StringRiffle[
  Select[
    Map[If[AssociationQ[#] && Lookup[#, "type", ""] === "text",
      ToString @ Lookup[#, "text", ""], ""] &, blocks],
    # =!= "" &], "\n"];
iSVLLBlocksText[_] := "";

(* ホームパスを ~ に縮めて絶対パス露出を抑える *)
iSVLLShortenPath[p_String] := StringReplace[p,
  {StringReplace[$HomeDirectory, "\\" -> "/"] -> "~", $HomeDirectory -> "~"}];
iSVLLShortenPath[x_] := ToString[x];

Options[SourceVault`SourceVaultClaudeCodeSessionDigest] = {"MachineTag" -> Automatic};
SourceVault`SourceVaultClaudeCodeSessionDigest[jsonlPath_String, OptionsPattern[]] := Module[
  {lines, recs, sessionId, cwd = Missing[], gitBranch = Missing[], version = Missing[],
   models = {}, toolCounts = <||>, files = {}, userTexts = {}, summaries = {},
   assistantTail = "", firstTs = Missing[], lastTs = Missing[],
   nUser = 0, nAssistant = 0, nLines, nSkipped = 0, mt, title, previews, pl, project},
  If[! FileExistsQ[jsonlPath], Return[Failure["NoSuchFile", <|"Path" -> jsonlPath|>]]];
  lines = iSVLLReadJSONLLines[jsonlPath];
  nLines = Length[lines];
  sessionId = FileBaseName[jsonlPath];
  project = FileNameTake[DirectoryName[jsonlPath]];
  Scan[Function[line,
    Module[{r, type, msg, content, ts},
      If[StringLength[line] > $iSVLLMaxLineChars, nSkipped++,
        r = iSVLLParseJSONLine[line];
        If[! AssociationQ[r], nSkipped++,
          type = Lookup[r, "type", ""];
          ts = Lookup[r, "timestamp", Missing[]];
          If[StringQ[ts],
            If[! StringQ[firstTs], firstTs = ts]; lastTs = ts];
          If[! StringQ[cwd] && StringQ[Lookup[r, "cwd", Null]], cwd = r["cwd"]];
          If[! StringQ[gitBranch] && StringQ[Lookup[r, "gitBranch", Null]], gitBranch = r["gitBranch"]];
          If[! StringQ[version] && StringQ[Lookup[r, "version", Null]], version = r["version"]];
          Switch[type,
            "summary",
              With[{s = Lookup[r, "summary", ""]},
                If[StringQ[s] && s =!= "", AppendTo[summaries, StringTake[s, UpTo[300]]]]],
            "user",
              If[! TrueQ[Lookup[r, "isSidechain", False]] && ! TrueQ[Lookup[r, "isMeta", False]],
                msg = Lookup[r, "message", <||>];
                content = If[AssociationQ[msg], Lookup[msg, "content", ""], ""];
                With[{txt = iSVLLExtractTaskText @ iSVLLCleanUserText @ Which[
                    StringQ[content], content,
                    ListQ[content], iSVLLBlocksText[content],
                    True, ""]},
                  If[txt =!= "", nUser++; AppendTo[userTexts, txt]]]],
            "assistant",
              If[! TrueQ[Lookup[r, "isSidechain", False]],
                msg = Lookup[r, "message", <||>];
                If[AssociationQ[msg],
                  With[{m = Lookup[msg, "model", Missing[]]},
                    If[StringQ[m], models = Union[models, {m}]]];
                  content = Lookup[msg, "content", {}];
                  If[ListQ[content],
                    Scan[Function[b,
                      If[AssociationQ[b],
                        Switch[Lookup[b, "type", ""],
                          "text",
                            With[{t = ToString @ Lookup[b, "text", ""]},
                              If[t =!= "", nAssistant++; assistantTail = t]],
                          "tool_use",
                            With[{nm = ToString @ Lookup[b, "name", "?"],
                                  inp = Lookup[b, "input", <||>]},
                              toolCounts[nm] = Lookup[toolCounts, nm, 0] + 1;
                              If[AssociationQ[inp],
                                With[{fp = Lookup[inp, "file_path",
                                    Lookup[inp, "notebook_path", Lookup[inp, "path", Missing[]]]]},
                                  If[StringQ[fp] && Length[files] < $iSVLLMaxFiles,
                                    files = DeleteDuplicates @ Append[files, iSVLLShortenPath[fp]]]]]]]]],
                      content]]]],
            _, Null]]]]],
    lines];
  previews = iSVLLPreview /@ If[Length[userTexts] > $iSVLLMaxPreviews,
    Join[Take[userTexts, 8], Take[userTexts, -($iSVLLMaxPreviews - 8)]],
    userTexts];
  title = Which[
    summaries =!= {}, First[summaries],
    previews =!= {}, First @ StringSplit[First[previews], "\n"],
    True, "(no user message)"];
  title = StringTake[StringTrim[title], UpTo[120]];
  (* privacy: package root 下の通常コード作業=0.4 / それ以外は fail-closed 0.75 (spec §7.1) *)
  pl = If[StringQ[cwd] && StringContainsQ[cwd, "MyPackages", IgnoreCase -> True], 0.4, 0.75];
  mt = With[{o = OptionValue["MachineTag"]},
    If[StringQ[o] && o =!= "", o, SourceVault`SourceVaultMachineTag[]]];
  <|"ObjectClass" -> "ClaudeCodeSessionDigest", "SchemaVersion" -> 2,
    "SessionId" -> sessionId,
    "MachineTag" -> mt,
    "Project" -> project,
    "SessionKind" -> iSVLLSessionKind[project, cwd],
    "Cwd" -> If[StringQ[cwd], iSVLLShortenPath[cwd], Missing[]],
    "GitBranch" -> gitBranch, "ClientVersion" -> version,
    "StartedAtUTC" -> firstTs, "LastAtUTC" -> lastTs,
    "Models" -> models,
    "LineCount" -> nLines, "SkippedLines" -> nSkipped,
    "UserMessageCount" -> nUser, "AssistantMessageCount" -> nAssistant,
    "ToolCounts" -> toolCounts,
    "FilesTouched" -> files,
    "Title" -> title,
    "Summaries" -> Take[summaries, UpTo[5]],
    "UserPreviews" -> previews,
    "AssistantTail" -> iSVLLRedact @ StringTake[assistantTail, UpTo[800]],
    "EffectivePrivacyLevel" -> pl,
    "DigestAtUTC" -> iSVLLNowIso[]|>
];

(* ============================================================
   ingest: ローカル走査 -> 変更セッションを digest -> rollup へ追記 (watermark 冪等)
   ============================================================ *)

(* 走査対象 = <root>/<projectDir>/<uuid>.jsonl (depth 2 のみ; subagents/ は含めない) *)
iSVLLLocalSessionFiles[] := Module[{roots},
  roots = Select[SourceVault`$SourceVaultClaudeCodeLogRoots, StringQ[#] && DirectoryQ[#] &];
  Flatten @ Map[Function[root,
    Select[FileNames["*.jsonl", root, 2],
      FileNameDepth[#] === FileNameDepth[root] + 2 &]],
    roots]];

iSVLLSessionKey[path_String] :=
  FileNameTake[DirectoryName[path]] <> "/" <> FileNameTake[path];

(* rollup shard 月 = セッション開始月 (無ければファイル更新月) *)
iSVLLShardMonth[digest_Association, path_String] := Module[{ts},
  ts = Lookup[digest, "StartedAtUTC", Missing[]];
  If[StringQ[ts] && StringLength[ts] >= 7, StringTake[ts, 7],
    DateString[FileDate[path, "Modification"], {"Year", "-", "Month"}]]];

Options[SourceVault`SourceVaultIngestClaudeCodeLogs] = {
  "DryRun" -> False, "MaxSessionsPerRun" -> Automatic,
  "MaxAgeDays" -> 180, "MaxFileMB" -> 200,
  (* True: watermark を無視して全セッションを digest し直す (digest スキーマ更新後の
     再取り込み用。append-only なので旧行は残るが、読み手が最新 DigestAtUTC を採る) *)
  "ForceRefresh" -> False,
  (* 生 transcript の Dropbox ミラー (増分) も同時に実行する *)
  "MirrorRaw" -> True};
SourceVault`SourceVaultIngestClaudeCodeLogs[OptionsPattern[]] := Module[
  {dry, maxRun, maxAge, maxMB, hostDir, wm, files, changed, todo,
   ingested = 0, skipped = 0, perSession = <||>, cutoff},
  dry = TrueQ[OptionValue["DryRun"]];
  maxRun = OptionValue["MaxSessionsPerRun"];
  maxAge = OptionValue["MaxAgeDays"];
  maxMB = OptionValue["MaxFileMB"];
  hostDir = iSVLLRollupMachineDir[];
  If[! StringQ[hostDir], Return[<|"Status" -> "Error", "Reason" -> "NoCoreRoot"|>]];
  wm = iSVLLReadWatermark[];
  files = iSVLLLocalSessionFiles[];
  cutoff = If[NumericQ[maxAge], AbsoluteTime[] - maxAge*86400, -Infinity];
  (* 変更検出: watermark の Bytes と現サイズが違うセッションだけ digest し直す
     (ForceRefresh は watermark 照合を無視して全対象) *)
  changed = With[{force = TrueQ[OptionValue["ForceRefresh"]]},
    Select[files, Function[f,
      Module[{key = iSVLLSessionKey[f], bytes = Quiet @ FileByteCount[f]},
        IntegerQ[bytes] && bytes > 0 &&
          (force || bytes =!= Lookup[Lookup[wm, key, <||>], "Bytes", -1]) &&
          (cutoff === -Infinity || AbsoluteTime[FileDate[f, "Modification"]] >= cutoff)]]]];
  (* 古い順に処理し、cap は残りを次回へ回す (service tick で少しずつ消化) *)
  changed = SortBy[changed, Quiet @ AbsoluteTime[FileDate[#, "Modification"]] &];
  todo = If[IntegerQ[maxRun] && maxRun > 0 && Length[changed] > maxRun,
    Take[changed, maxRun], changed];
  Scan[Function[f,
    Module[{key = iSVLLSessionKey[f], bytes = Quiet @ FileByteCount[f], digest, line, dest},
      Which[
        NumericQ[maxMB] && IntegerQ[bytes] && bytes > maxMB*10^6,
          skipped++; perSession[key] = <|"Status" -> "SkippedTooLarge", "Bytes" -> bytes|>,
        True,
          digest = Quiet @ Check[SourceVault`SourceVaultClaudeCodeSessionDigest[f], $Failed];
          If[! AssociationQ[digest],
            skipped++; perSession[key] = <|"Status" -> "DigestFailed"|>,
            line = iSVLLEncodeJSONLine[digest];
            If[! StringQ[line],
              skipped++; perSession[key] = <|"Status" -> "EncodeFailed"|>,
              If[dry,
                ingested++;
                perSession[key] = <|"Status" -> "DryRun", "Bytes" -> bytes,
                  "Title" -> Lookup[digest, "Title", ""]|>,
                dest = FileNameJoin[{hostDir, iSVLLShardMonth[digest, f] <> ".jsonl"}];
                If[iSVLLAppendLines[dest, {line}] === $Failed,
                  skipped++; perSession[key] = <|"Status" -> "AppendFailed"|>,
                  ingested++;
                  wm[key] = <|"Bytes" -> bytes, "IngestedAtUTC" -> iSVLLNowIso[]|>;
                  perSession[key] = <|"Status" -> "Ingested", "Bytes" -> bytes,
                    "Title" -> Lookup[digest, "Title", ""]|>]]]]]]],
    todo];
  If[! dry && ingested > 0, iSVLLWriteWatermark[wm]];
  iSVLLInvalidateDigestCache[];
  <|"Status" -> If[dry, "DryRun", "OK"],
    "MachineTag" -> SourceVault`SourceVaultMachineTag[],
    "Scanned" -> Length[files], "Changed" -> Length[changed],
    "Ingested" -> ingested, "Skipped" -> skipped,
    "Deferred" -> Length[changed] - Length[todo],
    "RollupDir" -> hostDir, "PerSession" -> perSession,
    (* 生 transcript ミラー (増分・fail-soft)。DryRun は伝搬する *)
    "Mirror" -> If[TrueQ[OptionValue["MirrorRaw"]],
      Quiet @ Check[
        KeyDrop[SourceVault`SourceVaultMirrorClaudeCodeLogs["DryRun" -> dry],
          {"MachineTag", "Status"}],
        <|"Error" -> "MirrorException"|>],
      Missing["Disabled"]]|>
];

SourceVault`SourceVaultClaudeCodeLogStatus[] := Module[
  {files, wm, uningested, base, rollupFiles, byMachine},
  files = iSVLLLocalSessionFiles[];
  wm = iSVLLReadWatermark[];
  uningested = Count[files, f_ /; Module[{key = iSVLLSessionKey[f]},
    Quiet[FileByteCount[f]] =!= Lookup[Lookup[wm, key, <||>], "Bytes", -1]]];
  base = iSVLLRollupBaseDir[];
  rollupFiles = If[StringQ[base] && DirectoryQ[base],
    FileNames["*.jsonl", base, Infinity], {}];
  byMachine = Merge[
    (FileNameTake[DirectoryName[#]] -> Length[iSVLLReadJSONLLines[#]]) & /@ rollupFiles, Total];
  <|"MachineTag" -> SourceVault`SourceVaultMachineTag[],
    "LocalSessions" -> Length[files],
    "UningestedSessions" -> uningested,
    "WatermarkedSessions" -> Length[wm],
    "RollupByMachine" -> byMachine,
    "RollupTotal" -> Total[Values[byMachine]],
    "LogRoots" -> SourceVault`$SourceVaultClaudeCodeLogRoots,
    "RollupDir" -> base,
    "WatermarkPath" -> iSVLLWatermarkPath[],
    "MirrorRoot" -> iSVLLRawMirrorRoot[],
    "MirrorByMachine" -> Module[{mb = iSVLLRawMirrorRoot[], dirs},
      If[! StringQ[mb] || ! DirectoryQ[mb], <||>,
        dirs = Select[FileNames["*", mb], DirectoryQ];
        Association @ Map[
          FileNameTake[#] -> Length[Select[FileNames["*.jsonl", #, 3], FileExistsQ]] &,
          dirs]]]|>
];

(* ============================================================
   読み: 全マシン rollup -> dedup (SessionId 毎最新)。軽量 signature キャッシュ付き。
   ============================================================ *)

$iSVLLDigestCache = <||>;
iSVLLInvalidateDigestCache[] := ($iSVLLDigestCache = <||>);

iSVLLRollupSignature[] := Module[{base = iSVLLRollupBaseDir[], fs},
  If[! StringQ[base] || ! DirectoryQ[base], Return[{}]];
  fs = FileNames["*.jsonl", base, Infinity];
  {Length[fs], Total @ Select[Quiet[FileByteCount[#]] & /@ fs, IntegerQ]}];

iSVLLAllDigests[] := Module[{sig, base, fs, recs, dedup},
  sig = iSVLLRollupSignature[];
  If[Lookup[$iSVLLDigestCache, "Sig", None] === sig && sig =!= {},
    Return[Lookup[$iSVLLDigestCache, "Digests", {}]]];
  base = iSVLLRollupBaseDir[];
  If[! StringQ[base] || ! DirectoryQ[base], Return[{}]];
  fs = FileNames["*.jsonl", base, Infinity];
  recs = Select[
    Flatten[Map[Function[f, iSVLLParseJSONLine /@ iSVLLReadJSONLLines[f]], fs]],
    AssociationQ];
  (* 同一 SessionId は最新 digest (DigestAtUTC 最大) を採る *)
  dedup = Values @ GroupBy[recs, Lookup[#, "SessionId", ""] &,
    Last @ SortBy[#, ToString @ Lookup[#, "DigestAtUTC", ""] &] &];
  dedup = Reverse @ SortBy[dedup, ToString @ Lookup[#, "LastAtUTC", ""] &];
  $iSVLLDigestCache = <|"Sig" -> sig, "Digests" -> dedup|>;
  dedup];

(* 旧 (SchemaVersion 1) 行に SessionKind が無い場合は読み側で補完 *)
iSVLLEnsureKind[d_Association] := If[KeyExistsQ[d, "SessionKind"], d,
  Append[d, "SessionKind" -> iSVLLSessionKind[
    Lookup[d, "Project", ""], Lookup[d, "Cwd", ""]]]];

Options[SourceVault`SourceVaultClaudeCodeSessions] = {
  "MachineTag" -> All, "Project" -> All, "Limit" -> All, "Kind" -> All};
SourceVault`SourceVaultClaudeCodeSessions[OptionsPattern[]] := Module[
  {recs = iSVLLAllDigests[], mt = OptionValue["MachineTag"],
   proj = OptionValue["Project"], lim = OptionValue["Limit"],
   kind = OptionValue["Kind"], summaries},
  recs = iSVLLEnsureKind /@ recs;
  If[StringQ[kind],
    recs = Select[recs, Lookup[#, "SessionKind", "interactive"] === kind &]];
  If[StringQ[mt], recs = Select[recs, Lookup[#, "MachineTag", ""] === mt &]];
  If[StringQ[proj],
    recs = Select[recs, StringContainsQ[ToString @ Lookup[#, "Project", ""], proj,
      IgnoreCase -> True] &]];
  If[IntegerQ[lim] && lim > 0, recs = Take[recs, UpTo[lim]]];
  (* 共有 sidecar の LLM 要約を join (あれば SummaryLLM / SummaryStale が付く) *)
  summaries = iSVLLAllSummaries[];
  If[summaries === <||>, recs, iSVLLJoinSummary[#, summaries] & /@ recs]];

SourceVault`SourceVaultClaudeCodeSessionGet[sessionId_String] := Module[
  {hit = SelectFirst[iSVLLAllDigests[], Lookup[#, "SessionId", ""] === sessionId &]},
  If[AssociationQ[hit], iSVLLJoinSummary[hit, iSVLLAllSummaries[]],
    Missing["NotFound", sessionId]]];

(* ============================================================
   生 transcript の Dropbox ミラー
   ------------------------------------------------------------
   ~/.claude/projects 一式を <mirror>/<MachineTag>/ へ増分コピーする。
   置き場所は SourceVault store (CoreRoot) の外 = udb/mails と同格のプレーン
   フォルダ。設計意図: 肥大化に耐えられなくなったらフォルダごとオフライン化
   してよく、そうしても SourceVault (digest/要約/索引) は破綻しない。
   マシンごとに自分の subtree のみ書く (クロスマシン書き込み衝突なし)。
   MCP には露出しない (MCP は digest 経由のみ。生ログ閲覧は NB の
   SourceVaultClaudeCodeSessionTranscript/View)。
   ============================================================ *)

If[! ValueQ[SourceVault`$SourceVaultClaudeCodeRawMirrorRoot],
  SourceVault`$SourceVaultClaudeCodeRawMirrorRoot = Automatic];

iSVLLRawMirrorRoot[] := Module[{v = SourceVault`$SourceVaultClaudeCodeRawMirrorRoot, cr},
  If[StringQ[v] && v =!= "", Return[v]];
  cr = SourceVault`SourceVaultCoreRoot[];
  If[! StringQ[cr], Return[$Failed]];
  FileNameJoin[{ParentDirectory[cr], "claudecodelogs"}]];

iSVLLRawMirrorMachineDir[] := Module[{b = iSVLLRawMirrorRoot[]},
  If[StringQ[b], FileNameJoin[{b, SourceVault`SourceVaultMachineTag[]}], $Failed]];

(* 1 ファイルの安全コピー (tmp + rename。Dropbox 同期中の中途半端な状態を作らない) *)
iSVLLCopyFile[src_String, dst_String] := Module[{ba, tmp, strm},
  ba = Quiet @ Check[ReadByteArray[src], $Failed];
  If[! ByteArrayQ[ba], Return[$Failed]];
  iSVLLEnsureDir[DirectoryName[dst]];
  tmp = dst <> ".tmp." <> ToString[$ProcessID];
  strm = Quiet @ OpenWrite[tmp, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  BinaryWrite[strm, ba]; Close[strm];
  If[Quiet @ Check[RenameFile[tmp, dst, OverwriteTarget -> True], $Failed] === $Failed,
    Quiet @ DeleteFile[tmp]; Return[$Failed]];
  Length[ba]];

Options[SourceVault`SourceVaultMirrorClaudeCodeLogs] = {
  "DryRun" -> False, "MaxFilesPerRun" -> Automatic};
SourceVault`SourceVaultMirrorClaudeCodeLogs[OptionsPattern[]] := Module[
  {dry, maxRun, dstBase, roots, todo = {}, copied = 0, copiedBytes = 0,
   skipped = 0, scanned = 0},
  dry = TrueQ[OptionValue["DryRun"]];
  maxRun = OptionValue["MaxFilesPerRun"];
  dstBase = iSVLLRawMirrorMachineDir[];
  If[! StringQ[dstBase], Return[<|"Status" -> "Error", "Reason" -> "NoMirrorRoot"|>]];
  roots = Select[SourceVault`$SourceVaultClaudeCodeLogRoots, StringQ[#] && DirectoryQ[#] &];
  Scan[Function[root,
    Scan[Function[src,
      Module[{rel, dst, sb, db},
        scanned++;
        rel = StringDrop[src, StringLength[root]];
        dst = FileNameJoin[{dstBase, StringTrim[rel, ("\\" | "/") ...]}];
        sb = Quiet @ FileByteCount[src];
        db = Quiet @ FileByteCount[dst];
        If[IntegerQ[sb] && sb =!= db, AppendTo[todo, {src, dst, sb}]]]],
      Select[FileNames["*", root, Infinity], ! DirectoryQ[#] &]]],
    roots];
  If[IntegerQ[maxRun] && maxRun > 0 && Length[todo] > maxRun,
    todo = Take[todo, maxRun]];
  Scan[Function[t,
    If[dry, copied++; copiedBytes += t[[3]],
      If[iSVLLCopyFile[t[[1]], t[[2]]] === $Failed, skipped++,
        copied++; copiedBytes += t[[3]]]]],
    todo];
  <|"Status" -> If[dry, "DryRun", "OK"],
    "MachineTag" -> SourceVault`SourceVaultMachineTag[],
    "Scanned" -> scanned, "Copied" -> copied,
    "CopiedBytes" -> copiedBytes, "Skipped" -> skipped,
    "Deferred" -> 0, "MirrorDir" -> dstBase|>];

(* ============================================================
   全文閲覧: local raw -> mirror raw -> digest フォールバック
   ============================================================ *)

(* sessionId から生 transcript ファイルを探す。local 優先、次に全マシンの mirror *)
iSVLLFindRawTranscript[sessionId_String] := Module[{roots, hit, mbase},
  roots = Select[SourceVault`$SourceVaultClaudeCodeLogRoots, StringQ[#] && DirectoryQ[#] &];
  hit = SelectFirst[
    Flatten[FileNames[sessionId <> ".jsonl", #, 2] & /@ roots],
    FileExistsQ, Missing[]];
  If[StringQ[hit], Return[<|"Path" -> hit, "Source" -> "local"|>]];
  mbase = iSVLLRawMirrorRoot[];
  If[StringQ[mbase] && DirectoryQ[mbase],
    hit = SelectFirst[FileNames[sessionId <> ".jsonl", mbase, 3], FileExistsQ, Missing[]];
    If[StringQ[hit], Return[<|"Path" -> hit, "Source" -> "mirror"|>]]];
  Missing["RawNotFound"]];

Options[SourceVault`SourceVaultClaudeCodeSessionTranscript] = {"IncludeMeta" -> False};
SourceVault`SourceVaultClaudeCodeSessionTranscript[sessionId_String, OptionsPattern[]] := Module[
  {raw, lines, turns = {}, includeMeta, d},
  includeMeta = TrueQ[OptionValue["IncludeMeta"]];
  raw = iSVLLFindRawTranscript[sessionId];
  If[! AssociationQ[raw],
    (* digest フォールバック (生ログ未同期/オフライン化済みでも閲覧は生き残る) *)
    d = SourceVault`SourceVaultClaudeCodeSessionGet[sessionId];
    If[! AssociationQ[d], Return[Failure["SessionNotFound", <|"SessionId" -> sessionId|>]]];
    Return[<|"SessionId" -> sessionId, "Source" -> "digest", "Path" -> Missing[],
      "Turns" -> Join[
        Map[<|"Role" -> "user", "At" -> Missing[], "Text" -> #, "Tools" -> {}|> &,
          Lookup[d, "UserPreviews", {}]],
        {<|"Role" -> "assistant", "At" -> Missing[],
           "Text" -> Lookup[d, "AssistantTail", ""], "Tools" -> {}|>}]|>]];
  lines = iSVLLReadJSONLLines[raw["Path"]];
  Scan[Function[line,
    Module[{r, type, msg, content, txt, tools},
      If[StringLength[line] <= $iSVLLMaxLineChars,
        r = iSVLLParseJSONLine[line];
        If[AssociationQ[r],
          type = Lookup[r, "type", ""];
          msg = Lookup[r, "message", <||>];
          Switch[type,
            "user",
              If[! TrueQ[Lookup[r, "isSidechain", False]] &&
                 (includeMeta || ! TrueQ[Lookup[r, "isMeta", False]]),
                content = If[AssociationQ[msg], Lookup[msg, "content", ""], ""];
                txt = Which[StringQ[content], content,
                  ListQ[content], iSVLLBlocksText[content], True, ""];
                If[! includeMeta, txt = iSVLLCleanUserText[txt]];
                If[StringTrim[txt] =!= "",
                  AppendTo[turns, <|"Role" -> "user",
                    "At" -> Lookup[r, "timestamp", Missing[]],
                    "Text" -> txt, "Tools" -> {}|>]]],
            "assistant",
              If[! TrueQ[Lookup[r, "isSidechain", False]] && AssociationQ[msg],
                content = Lookup[msg, "content", {}];
                If[ListQ[content],
                  txt = iSVLLBlocksText[content];
                  tools = Cases[content,
                    b_Association /; Lookup[b, "type", ""] === "tool_use" :>
                      ToString @ Lookup[b, "name", "?"]];
                  If[StringTrim[txt] =!= "" || tools =!= {},
                    AppendTo[turns, <|"Role" -> "assistant",
                      "At" -> Lookup[r, "timestamp", Missing[]],
                      "Text" -> txt, "Tools" -> tools|>]]]],
            _, Null]]]]],
    lines];
  <|"SessionId" -> sessionId, "Source" -> raw["Source"], "Path" -> raw["Path"],
    "Turns" -> turns|>];

Options[SourceVault`SourceVaultClaudeCodeSessionView] = {
  "MaxTurns" -> 80, "MaxCharsPerTurn" -> 2000};
SourceVault`SourceVaultClaudeCodeSessionView[sessionId_String, OptionsPattern[]] := Module[
  {tr, d, maxTurns = OptionValue["MaxTurns"], maxChars = OptionValue["MaxCharsPerTurn"],
   turns, header, cells},
  tr = SourceVault`SourceVaultClaudeCodeSessionTranscript[sessionId];
  If[FailureQ[tr], Return[tr]];
  d = SourceVault`SourceVaultClaudeCodeSessionGet[sessionId];
  If[! AssociationQ[d], d = <||>];
  turns = Lookup[tr, "Turns", {}];
  header = Column[{
    Style[ToString @ Lookup[d, "Title", sessionId], Bold, 14],
    Style[StringRiffle[{
      ToString @ Lookup[d, "MachineTag", "?"],
      ToString @ Lookup[d, "SessionKind", "?"],
      ToString @ Lookup[d, "StartedAtUTC", "?"] <> " .. " <>
        ToString @ Lookup[d, "LastAtUTC", "?"],
      "source: " <> ToString @ Lookup[tr, "Source", "?"],
      ToString[Length[turns]] <> " turns"}, " | "], Gray, 10],
    If[StringQ[Lookup[d, "SummaryLLM", Missing[]]],
      Style[d["SummaryLLM"], Italic, 11], Nothing]}];
  cells = Map[Function[t,
    Panel[Column[{
      Style[StringRiffle[{
        ToString @ Lookup[t, "Role", "?"],
        StringTake[ToString @ Lookup[t, "At", ""], UpTo[16]],
        If[Lookup[t, "Tools", {}] =!= {},
          "tools: " <> StringRiffle[ToString /@ t["Tools"], ","], Nothing]}, " | "],
        If[Lookup[t, "Role", ""] === "user", RGBColor[0.1, 0.3, 0.7], Gray], 9],
      StringTake[ToString @ Lookup[t, "Text", ""], UpTo[maxChars]]}],
      Background -> If[Lookup[t, "Role", ""] === "user",
        RGBColor[0.93, 0.96, 1.], White]]],
    Take[turns, UpTo[If[IntegerQ[maxTurns] && maxTurns > 0, maxTurns, 80]]]];
  Column[Join[{header}, cells],
    Dividers -> {False, {2 -> GrayLevel[0.7]}}, Spacings -> 1]];

(* ============================================================
   LLM 要約 (notebook summary と同型: local-first LLM + キャッシュ)
   ------------------------------------------------------------
   sidecar: <CoreRoot>/rollup/claudecode_sessions/_summaries/<sessionId>.json
   (Dropbox 共有 = どのマシンで生成しても全マシンから見える。atomic write・
    last-writer-wins。digest 本体の rollup shard = .jsonl は変更しない)。
   Current 判定 = 保存時 SourceLineCount と現 digest の LineCount 一致。
   LLM ルートは SourceVault.wl の iCallSummaryLLMWithFallback を再利用
   (未ロード環境 = service kernel では LLMRouteUnavailable で fail-soft)。
   ============================================================ *)

iSVLLSummaryDir[] := Module[{b = iSVLLRollupBaseDir[]},
  If[StringQ[b], FileNameJoin[{b, "_summaries"}], $Failed]];
iSVLLSummaryPath[sid_String] := Module[{d = iSVLLSummaryDir[]},
  If[StringQ[d], FileNameJoin[{d, sid <> ".json"}], $Failed]];
iSVLLLoadSummary[sid_String] := Module[{p = iSVLLSummaryPath[sid], r},
  If[! StringQ[p], Return[Missing["NoCoreRoot"]]];
  r = iSVLLGetJSON[p];
  If[AssociationQ[r], r, Missing["NoSummary"]]];

(* 全 summary の一括読み (digest join 用)。signature キャッシュ付き *)
$iSVLLSummaryCache = <||>;
iSVLLInvalidateSummaryCache[] := ($iSVLLSummaryCache = <||>);
iSVLLAllSummaries[] := Module[{d = iSVLLSummaryDir[], fs, sig, recs},
  If[! StringQ[d] || ! DirectoryQ[d], Return[<||>]];
  fs = FileNames["*.json", d];
  sig = {Length[fs], Total @ Select[Quiet[FileByteCount[#]] & /@ fs, IntegerQ]};
  If[Lookup[$iSVLLSummaryCache, "Sig", None] === sig,
    Return[Lookup[$iSVLLSummaryCache, "Summaries", <||>]]];
  recs = Association @ Map[
    Function[f, Module[{r = iSVLLGetJSON[f]},
      If[AssociationQ[r] && StringQ[Lookup[r, "SessionId", Null]],
        r["SessionId"] -> r, Nothing]]],
    fs];
  $iSVLLSummaryCache = <|"Sig" -> sig, "Summaries" -> recs|>;
  recs];

(* digest に要約 join: SummaryLLM / SummaryStale (digest が要約後に伸びた) *)
iSVLLJoinSummary[d_Association, summaries_Association] := Module[
  {sid = ToString @ Lookup[d, "SessionId", ""], s},
  s = Lookup[summaries, sid, Missing[]];
  If[! AssociationQ[s], d,
    Join[d, <|
      "SummaryLLM" -> Lookup[s, "Summary", Missing[]],
      "SummaryGeneratedAtUTC" -> Lookup[s, "GeneratedAtUTC", Missing[]],
      "SummaryStale" -> (Lookup[s, "SourceLineCount", -1] =!=
        Lookup[d, "LineCount", -2])|>]]];

iSVLLSummaryLLMAvailableQ[] :=
  Length[DownValues[SourceVault`iCallSummaryLLMWithFallback]] > 0;

(* digest は privacy 0.4 が主 (package root のコード作業) なので、cloud 可の範囲では
   $ClaudeDocModel (doc 生成用・安価高品質) を主経路にする。iCallSummaryLLM は
   String モデルを Automatic に落とす仕様のため、ここで ClaudeQuerySync を直接呼ぶ
   薄いラッパを持つ (エラー本文検出は notebook summary と同じ)。 *)
iSVLLDocModel[] := Which[
  Length[Names["ClaudeCode`$ClaudeDocModel"]] === 0, Missing["NoClaudeCode"],
  True, With[{m = Quiet @ Symbol["ClaudeCode`$ClaudeDocModel"]},
    Which[
      StringQ[m] && m =!= "", m,
      ListQ[m] && Length[m] >= 2, m,
      True, Missing["NoDocModel"]]]];

iSVLLCallSummaryModel[prompt_String, model_] := Module[{resp, gnames, guard},
  Quiet @ Needs["ClaudeCode`"];
  If[Length[Names["ClaudeCode`ClaudeQuerySync"]] === 0,
    Return[<|"Status" -> "Failed", "Reason" -> "ClaudeQuerySyncNotAvailable"|>]];
  (* Phase 28 課金 API ゲート (ClaudeEval と同じ先制 guard)。metered API
     (anthropic/openai/zai 等) は paidAPIAllowed を許可したノートブックからの
     直接実行のみ。headless (service/wolframscript/テスト) は NotebookObject が
     無いため常に拒否される。CLI (claudecode/chatgptcodex) と lmstudio は
     サブスクリプション/ローカルなので guard 対象外 (システム仕様)。
     guard シンボルが無い環境でも、下層 (iQueryViaAPI 等) の同一ゲートが
     "Error: ..." を返し、下の iSVLooksLikeLLMError 検査で Failed に落ちる
     (呼び出し自体が API に届く前に遮断される二重防御)。 *)
  (* 注意 1: guard 判定を入れ子 Module/With に包むと Return が内側から返るだけで
     本体を抜けない (WL の Return スコープ)。必ずこの Module 直下で判定する。
     注意 2: Names パターンの * はコンテキスト区切り (`) を跨がない。
     "ClaudeCode`*name" は ClaudeCode`Private`name にマッチしない ({} を返し
     guard 素通しになる)。先頭 "*`name" 形はコンテキスト横断でマッチする。 *)
  gnames = Names["*`iClaudePaidModelGuard"];
  guard = If[gnames === {}, None,
    Quiet @ Check[Symbol[First[gnames]][model], None]];
  If[StringQ[guard],
    Return[<|"Status" -> "Failed", "Reason" -> "PaidAPIBlocked",
      "Detail" -> StringTake[guard, UpTo[200]], "Model" -> model|>]];
  (* 1H-S boundary gate: ClaudeQuerySync 委譲の最終境界 (paid guard 通過後。
     capbroker 不在は fail-open) *)
  If[TrueQ[SourceVault`SourceVaultLLMBoundarySelfGateRefusedQ["llmlog:iSVLLCallSummaryModel",
      <|"Provider" -> "claudecode", "Model" -> ToString[model],
        "Messages" -> {<|"role" -> "user", "content" -> prompt|>}|>]],
    Return[<|"Status" -> "Failed", "Reason" -> "LLMBoundaryRefused", "Model" -> model|>]];
  resp = Quiet @ ClaudeCode`ClaudeQuerySync[prompt, ClaudeCode`Model -> model];
  Which[
    ! StringQ[resp],
      <|"Status" -> "Failed", "Reason" -> "NonStringResponse", "Model" -> model|>,
    TrueQ[Quiet @ SourceVault`iSVLooksLikeLLMError[resp]],
      <|"Status" -> "Failed", "Reason" -> "LLMReturnedErrorText", "Model" -> model|>,
    StringTrim[resp] === "",
      <|"Status" -> "Failed", "Reason" -> "LLMReturnedEmptyText", "Model" -> model|>,
    True,
      <|"Status" -> "OK", "Response" -> resp, "Model" -> model|>]];

(* cloud 投入可とみなす privacy 上限 (システムの cloud cap 0.49 に整合) *)
$iSVLLCloudMaxPrivacy = 0.49;

iSVLLBuildSummaryPrompt[d_Association, maxLength_Integer] := Module[
  {previews, files, tools},
  previews = StringTake[
    StringRiffle[ToString /@ Lookup[d, "UserPreviews", {}], "\n- "], UpTo[4000]];
  files = StringRiffle[ToString /@ Take[Lookup[d, "FilesTouched", {}], UpTo[10]], ", "];
  tools = StringRiffle[
    KeyValueMap[ToString[#1] <> ":" <> ToString[#2] &,
      iSVLLTopTools[d, 5]], ", "];
  StringJoin[
    "以下は Claude Code の 1 セッションのダイジェストです。このセッションで「何を行い、何が結果だったか」を日本語で 2〜3 文 (最大 ",
    ToString[maxLength], " 文字) に要約してください。ファイル名・関数名・パッケージ名は保持してください。",
    "前置き・見出し・箇条書きは不要で、要約本文のみを返してください。\n\n",
    "タイトル: ", ToString @ Lookup[d, "Title", ""], "\n",
    "期間: ", ToString @ Lookup[d, "StartedAtUTC", "?"], " .. ",
    ToString @ Lookup[d, "LastAtUTC", "?"],
    " | マシン: ", ToString @ Lookup[d, "MachineTag", "?"], "\n",
    "編集ファイル: ", files, "\n",
    "ツール使用: ", tools, "\n",
    "最後のアシスタント発話: ",
    StringTake[ToString @ Lookup[d, "AssistantTail", ""], UpTo[600]], "\n\n",
    "ユーザー発話 (抜粋):\n- ", previews]];

Options[SourceVault`SourceVaultClaudeCodeSessionSummary] = {
  "ForceRefresh" -> False, "MaxLength" -> 300,
  "Model" -> Automatic, "FallbackToCloud" -> "Deny"};
SourceVault`SourceVaultClaudeCodeSessionSummary[sessionId_String, OptionsPattern[]] := Module[
  {d, cached, maxLength, llmResult, summaryText, rec, p},
  d = SourceVault`SourceVaultClaudeCodeSessionGet[sessionId];
  If[! AssociationQ[d],
    Return[<|"Status" -> "Failed", "Reason" -> "SessionNotFound",
      "SessionId" -> sessionId|>]];
  If[Lookup[d, "UserMessageCount", 0] === 0,
    Return[<|"Status" -> "Failed", "Reason" -> "EmptySession",
      "SessionId" -> sessionId|>]];
  cached = iSVLLLoadSummary[sessionId];
  If[! TrueQ[OptionValue["ForceRefresh"]] && AssociationQ[cached] &&
     StringQ[Lookup[cached, "Summary", Null]] &&
     Lookup[cached, "SourceLineCount", -1] === Lookup[d, "LineCount", -2] &&
     ! TrueQ[Quiet @ SourceVault`iSVLooksLikeLLMError[cached["Summary"]]],
    Return[Join[cached, <|"Status" -> "OK", "Cached" -> True|>]]];
  maxLength = OptionValue["MaxLength"];
  (* ルーティング:
     - privacy <= 0.49 (cloud 可 = 通常のコード作業 digest): $ClaudeDocModel
       (または明示 Model) を主経路で直接呼ぶ。失敗時のみ local ladder へ。
     - privacy > 0.49: 従来どおり local-first ladder (FallbackToCloud 既定 Deny)。 *)
  llmResult = Module[{pl = Lookup[d, "EffectivePrivacyLevel", 0.75],
      prompt = iSVLLBuildSummaryPrompt[d, maxLength], primModel, r = None},
    If[pl <= $iSVLLCloudMaxPrivacy,
      primModel = With[{m = OptionValue["Model"]},
        If[m =!= Automatic, m, iSVLLDocModel[]]];
      If[! MissingQ[primModel],
        r = Quiet @ Check[iSVLLCallSummaryModel[prompt, primModel],
          <|"Status" -> "Failed", "Reason" -> "LLMException"|>]]];
    If[AssociationQ[r] && Lookup[r, "Status", ""] === "OK", r,
      (* fallback: local-first ladder (オフライン/API 不通でも LM Studio で生きる) *)
      If[! iSVLLSummaryLLMAvailableQ[],
        <|"Status" -> "Failed", "Reason" -> "LLMRouteUnavailable",
          "Detail" -> "SourceVault.wl (iCallSummaryLLMWithFallback) が未ロード",
          "Primary" -> r|>,
        Module[{fb = Quiet @ Check[
            SourceVault`iCallSummaryLLMWithFallback[prompt,
              OptionValue["Model"], pl, "",
              ToString @ OptionValue["FallbackToCloud"]],
            <|"Status" -> "Failed", "Reason" -> "LLMException"|>]},
          If[AssociationQ[fb] && r =!= None, Append[fb, "Primary" -> r], fb]]]]];
  If[Lookup[If[AssociationQ[llmResult], llmResult, <||>], "Status", ""] === "Failed" &&
     Lookup[llmResult, "Reason", ""] === "LLMRouteUnavailable",
    Return[Append[llmResult, "SessionId" -> sessionId]]];
  If[! AssociationQ[llmResult] || Lookup[llmResult, "Status", ""] =!= "OK",
    Return[<|"Status" -> "Failed",
      "Reason" -> Lookup[If[AssociationQ[llmResult], llmResult, <||>], "Reason", "LLMFailed"],
      "SessionId" -> sessionId, "LLMResult" -> llmResult|>]];
  summaryText = StringTrim @ ToString @ Lookup[llmResult, "Response", ""];
  If[summaryText === "" ||
     TrueQ[Quiet @ SourceVault`iSVLooksLikeLLMError[summaryText]],
    Return[<|"Status" -> "Failed", "Reason" -> "EmptyOrErrorLLMResponse",
      "SessionId" -> sessionId|>]];
  rec = <|"SessionId" -> sessionId,
    "Summary" -> summaryText,
    "GeneratedAtUTC" -> iSVLLNowIso[],
    "GeneratedBy" -> ToString @ Lookup[llmResult, "Model",
      Lookup[llmResult, "ResolvedModel", ToString @ OptionValue["Model"]]],
    "GeneratedOn" -> SourceVault`SourceVaultMachineTag[],
    "SourceLineCount" -> Lookup[d, "LineCount", 0],
    "SourceDigestAtUTC" -> Lookup[d, "DigestAtUTC", Missing[]],
    "PrivacyLevel" -> Lookup[d, "EffectivePrivacyLevel", 0.75]|>;
  p = iSVLLSummaryPath[sessionId];
  If[! StringQ[p] || iSVLLPutJSON[p, rec] === $Failed,
    Return[<|"Status" -> "Failed", "Reason" -> "SummarySaveFailed",
      "SessionId" -> sessionId|>]];
  iSVLLInvalidateSummaryCache[];
  Join[rec, <|"Status" -> "OK", "Cached" -> False|>]];

Options[SourceVault`SourceVaultClaudeCodeSummarizeSessions] = Join[
  (* Kind 既定 "interactive": ワンショット・ハーネス (doc 更新等の自動呼び出し) は
     大量で LLM コストに見合わない。含めたいときは "Kind" -> All *)
  {"Limit" -> 10, "Query" -> None, "MachineTag" -> All, "Kind" -> "interactive"},
  Options[SourceVault`SourceVaultClaudeCodeSessionSummary]];
SourceVault`SourceVaultClaudeCodeSummarizeSessions[OptionsPattern[]] := Module[
  {recs, summaries, todo, results, per = <||>, lim = OptionValue["Limit"],
   sumOpts},
  recs = If[StringQ[OptionValue["Query"]],
    SourceVault`SourceVaultClaudeCodeSessionSearch[OptionValue["Query"],
      "Limit" -> If[IntegerQ[lim], lim, 10],
      "MachineTag" -> OptionValue["MachineTag"], "Kind" -> OptionValue["Kind"]],
    SourceVault`SourceVaultClaudeCodeSessions[
      "MachineTag" -> OptionValue["MachineTag"], "Kind" -> OptionValue["Kind"]]];
  summaries = iSVLLAllSummaries[];
  (* 未生成 or stale のみ対象 (新しい順のまま)。発話ゼロのセッションは要約対象外 *)
  todo = Select[recs, Function[d,
    Module[{s = Lookup[summaries, ToString @ Lookup[d, "SessionId", ""], Missing[]]},
      Lookup[d, "UserMessageCount", 0] > 0 &&
       (! AssociationQ[s] ||
          Lookup[s, "SourceLineCount", -1] =!= Lookup[d, "LineCount", -2])]]];
  If[IntegerQ[lim] && lim > 0, todo = Take[todo, UpTo[lim]]];
  sumOpts = Sequence @@ FilterRules[
    {"ForceRefresh" -> OptionValue["ForceRefresh"],
     "MaxLength" -> OptionValue["MaxLength"],
     "Model" -> OptionValue["Model"],
     "FallbackToCloud" -> OptionValue["FallbackToCloud"]},
    Options[SourceVault`SourceVaultClaudeCodeSessionSummary]];
  results = Map[Function[d,
    Module[{sid = ToString @ Lookup[d, "SessionId", ""], r},
      r = SourceVault`SourceVaultClaudeCodeSessionSummary[sid, sumOpts];
      per[sid] = <|"Status" -> Lookup[r, "Status", "?"],
        "Reason" -> Lookup[r, "Reason", Missing[]],
        "Cached" -> Lookup[r, "Cached", Missing[]],
        "Title" -> StringTake[ToString @ Lookup[d, "Title", ""], UpTo[60]]|>;
      r]],
    todo];
  <|"Requested" -> Length[todo],
    "Generated" -> Count[results, r_ /; Lookup[r, "Status", ""] === "OK" &&
      ! TrueQ[Lookup[r, "Cached", False]]],
    "Cached" -> Count[results, r_ /; TrueQ[Lookup[r, "Cached", False]]],
    "Failed" -> Count[results, r_ /; Lookup[r, "Status", ""] =!= "OK"],
    "PerSession" -> per|>];

(* ============================================================
   検索 (core): トークン単位 OR スコアリング + 決定論 tie-break
   (mining_narrowing 提案 §4-B の教訓: クエリは 1 個の不透明文字列にしない)
   ============================================================ *)

iSVLLQueryTokens[q_String] := Select[
  StringSplit[ToLowerCase[q],
    {" ", "\t", "\n", ",", ".", ";", ":", "|", "/", "、", "。", "・", "「", "」", "(", ")"}],
  StringLength[#] >= 2 &];

(* digest -> 検索対象 field テキスト (weight 付き) *)
iSVLLSearchFields[d_Association] := {
  {ToString @ Lookup[d, "Title", ""], 3.},
  {ToString @ Lookup[d, "SummaryLLM", ""], 2.5},
  {StringRiffle[ToString /@ Lookup[d, "Summaries", {}], " "], 2.5},
  {StringRiffle[ToString /@ Lookup[d, "UserPreviews", {}], " "], 2.},
  {StringRiffle[ToString /@ Lookup[d, "FilesTouched", {}], " "], 2.},
  {ToString @ Lookup[d, "AssistantTail", ""], 1.},
  {ToString @ Lookup[d, "Project", ""] <> " " <> ToString @ Lookup[d, "Cwd", ""], 1.},
  {StringRiffle[ToString /@ Keys[Lookup[d, "ToolCounts", <||>]], " "], 0.5},
  {ToString @ Lookup[d, "MachineTag", ""] <> " " <>
     StringRiffle[ToString /@ Lookup[d, "Models", {}], " "], 1.}};

iSVLLScoreDigest[d_Association, tokens_List] := Module[{fields, score = 0., sid},
  sid = ToLowerCase @ ToString @ Lookup[d, "SessionId", ""];
  fields = {ToLowerCase[First[#]], Last[#]} & /@ iSVLLSearchFields[d];
  Scan[Function[t,
    If[t === sid, score += 10.];
    Scan[Function[fw,
      If[StringContainsQ[First[fw], t], score += Last[fw]]],
      fields]],
    tokens];
  score];

Options[SourceVault`SourceVaultClaudeCodeSessionSearch] = {
  "Limit" -> 20, "MachineTag" -> All, "Project" -> All, "Kind" -> All};
SourceVault`SourceVaultClaudeCodeSessionSearch[query_String, OptionsPattern[]] := Module[
  {tokens, recs, scored, lim = OptionValue["Limit"]},
  tokens = iSVLLQueryTokens[query];
  If[tokens === {}, Return[{}]];
  recs = SourceVault`SourceVaultClaudeCodeSessions[
    "MachineTag" -> OptionValue["MachineTag"], "Project" -> OptionValue["Project"],
    "Kind" -> OptionValue["Kind"]];
  scored = Select[
    Map[Append[#, "Score" -> iSVLLScoreDigest[#, tokens]] &, recs],
    #["Score"] > 0. &];
  (* 決定論 tie-break: Score 降順 -> LastAtUTC 降順 -> SessionId (固定順) *)
  scored = Reverse @ SortBy[scored,
    {#["Score"], ToString @ Lookup[#, "LastAtUTC", ""],
     ToString @ Lookup[#, "SessionId", ""]} &];
  If[IntegerQ[lim] && lim > 0, Take[scored, UpTo[lim]], scored]];

(* 概要列: LLM 要約 (キャッシュ) > digest 由来の先頭発話 fallback。
   "Summarize"->True で表示行の未生成分をその場で LLM 生成する
   (同期・1 件数秒〜数十秒かかるので既定 False。一括生成は
    SourceVaultClaudeCodeSummarizeSessions を使う)。 *)
iSVLLGaiyou[d_Association] := Module[{s = Lookup[d, "SummaryLLM", Missing[]]},
  Which[
    StringQ[s] && TrueQ[Lookup[d, "SummaryStale", False]],
      s <> " (追記あり・要約は旧版)",
    StringQ[s], s,
    True,
      StringTake[
        StringReplace[
          StringRiffle[ToString /@ Take[Lookup[d, "UserPreviews", {}], UpTo[2]], " / "],
          {"\n" -> " "}], UpTo[160]] <> " …(要約未生成)"]];

Options[SourceVault`SourceVaultClaudeCodeSessionSearchView] = Join[
  Options[SourceVault`SourceVaultClaudeCodeSessionSearch],
  {"Summarize" -> False, "MaxRows" -> 25}];
SourceVault`SourceVaultClaudeCodeSessionSearchView[query_String, opts : OptionsPattern[]] := Module[
  {hits, maxRows = OptionValue["MaxRows"]},
  hits = SourceVault`SourceVaultClaudeCodeSessionSearch[query,
    Sequence @@ FilterRules[{opts},
      Options[SourceVault`SourceVaultClaudeCodeSessionSearch]]];
  hits = Take[hits, UpTo[If[IntegerQ[maxRows] && maxRows > 0, maxRows, 25]]];
  If[TrueQ[OptionValue["Summarize"]],
    Scan[Function[d,
      If[! StringQ[Lookup[d, "SummaryLLM", Missing[]]] ||
         TrueQ[Lookup[d, "SummaryStale", False]],
        Quiet @ SourceVault`SourceVaultClaudeCodeSessionSummary[
          ToString @ Lookup[d, "SessionId", ""]]]],
      hits];
    (* 生成後に join し直す *)
    hits = iSVLLJoinSummary[#, iSVLLAllSummaries[]] & /@ hits];
  Dataset[Map[
    <|"Score" -> #["Score"],
      "Machine" -> Lookup[#, "MachineTag", ""],
      "Last" -> StringTake[ToString @ Lookup[#, "LastAtUTC", ""], UpTo[16]],
      "Kind" -> Lookup[#, "SessionKind", "interactive"],
      "Title" -> StringTake[ToString @ Lookup[#, "Title", ""], UpTo[60]],
      "概要" -> iSVLLGaiyou[#],
      "SessionId" -> StringTake[ToString @ Lookup[#, "SessionId", ""], UpTo[12]]|> &,
    hits]]];

(* ============================================================
   MCP adapter "llmlog"
   URI: sv://record/svcclog-<sessionId> (mail の svmail- と同じ record 間借り方式;
   URI namespace table (mcp.wl) の変更を要しない)
   ============================================================ *)

$iSVLLUriPrefix = "svcclog-";

iSVLLUriFor[sessionId_String] :=
  "sv://record/" <> $iSVLLUriPrefix <> sessionId;

iSVLLOwnsURIQ[parsed_Association] :=
  Lookup[parsed, "Namespace", ""] === "record" &&
    StringQ[Lookup[parsed, "Id", Null]] && StringStartsQ[parsed["Id"], $iSVLLUriPrefix];

iSVLLSessionIdFromParsed[parsed_Association] :=
  StringDrop[ToString @ Lookup[parsed, "Id", ""], StringLength[$iSVLLUriPrefix]];

iSVLLTopTools[d_Association, n_Integer] := Association @ Take[
  ReverseSortBy[Normal @ Lookup[d, "ToolCounts", <||>], Last], UpTo[n]];

iSVLLRow[d_Association] := Module[{sid = ToString @ Lookup[d, "SessionId", ""]},
  <|"URI" -> iSVLLUriFor[sid],
    "Kind" -> "llmlog",
    "Title" -> Lookup[d, "Title", "(untitled session)"],
    "Summary" -> StringRiffle[Flatten @ {
      (* LLM 要約があれば先頭に (何が行われたかを一読で伝える) *)
      With[{s = Lookup[d, "SummaryLLM", Missing[]]},
        If[StringQ[s], {s}, {}]],
      "machine " <> ToString @ Lookup[d, "MachineTag", "?"],
      "project " <> ToString @ Lookup[d, "Project", "?"],
      ToString @ Lookup[d, "StartedAtUTC", "?"] <> " .. " <>
        ToString @ Lookup[d, "LastAtUTC", "?"],
      ToString @ Lookup[d, "UserMessageCount", 0] <> " user msgs",
      ToString @ Lookup[d, "AssistantMessageCount", 0] <> " assistant msgs"}, " | "],
    "Snippet" -> StringTake[
      StringRiffle[ToString /@ Take[Lookup[d, "UserPreviews", {}], UpTo[3]], " / "],
      UpTo[500]],
    "Score" -> Lookup[d, "Score", Missing[]],
    "PrivacyLevel" -> Lookup[d, "EffectivePrivacyLevel", 0.75],
    "PrivacyClass" -> If[TrueQ[Lookup[d, "EffectivePrivacyLevel", 0.75] <= 0.4],
      "CodeWork", "Unclassified"],
    "Metadata" -> <|
      "SessionId" -> sid,
      "SessionKind" -> Lookup[d, "SessionKind", "interactive"],
      "MachineTag" -> Lookup[d, "MachineTag", Missing[]],
      "Project" -> Lookup[d, "Project", Missing[]],
      "GitBranch" -> Lookup[d, "GitBranch", Missing[]],
      "StartedAtUTC" -> Lookup[d, "StartedAtUTC", Missing[]],
      "LastAtUTC" -> Lookup[d, "LastAtUTC", Missing[]],
      "Models" -> Lookup[d, "Models", {}],
      "UserMessageCount" -> Lookup[d, "UserMessageCount", 0],
      "AssistantMessageCount" -> Lookup[d, "AssistantMessageCount", 0],
      "TopTools" -> iSVLLTopTools[d, 5],
      "FilesTouched" -> Take[Lookup[d, "FilesTouched", {}], UpTo[8]]|>|>];

iSVLLAdapterSearch[spec_Association, accessRequest_Association] := Module[
  {q, lim, filt, mt, proj, kind, hits},
  q = ToString @ Lookup[spec, "query", ""];
  If[StringTrim[q] === "", Return[{}]];
  lim = Lookup[spec, "limit", 10];
  filt = Lookup[spec, "filters", <||>];
  {mt, proj, kind} = If[AssociationQ[filt],
    {Lookup[filt, "machineTag", All], Lookup[filt, "project", All],
     Lookup[filt, "kind", All]}, {All, All, All}];
  hits = Quiet @ Check[
    SourceVault`SourceVaultClaudeCodeSessionSearch[q,
      "Limit" -> If[IntegerQ[lim] && lim > 0, lim, 10],
      "MachineTag" -> If[StringQ[mt], mt, All],
      "Project" -> If[StringQ[proj], proj, All],
      "Kind" -> If[StringQ[kind], kind, All]], {}];
  If[! ListQ[hits], Return[{}]];
  iSVLLRow /@ Select[hits, AssociationQ]];

iSVLLAdapterResolve[parsed_Association, accessRequest_Association] := Module[
  {sid = iSVLLSessionIdFromParsed[parsed], d},
  If[sid === "", Return[Missing["NoId"]]];
  d = SourceVault`SourceVaultClaudeCodeSessionGet[sid];
  If[! AssociationQ[d], Return[Missing["NotFound"]]];
  iSVLLRow[d]];

(* body = digest 全文の整形テキスト (bounded preview の集合; 生 transcript ではない)。
   grant 必須 (RequireGrantFor body/raw)。grant 検証は呼び出し側 (iSVMCPGetBody)。 *)
iSVLLAdapterReadBody[parsed_Association, grant_, accessRequest_Association, view_: "body"] := Module[
  {sid = iSVLLSessionIdFromParsed[parsed], d, txt},
  If[sid === "", Return[Missing["NoId"]]];
  d = SourceVault`SourceVaultClaudeCodeSessionGet[sid];
  If[! AssociationQ[d], Return[Missing["NotFound"]]];
  txt = StringRiffle[Flatten @ {
    "# Claude Code session " <> sid,
    "machine: " <> ToString @ Lookup[d, "MachineTag", "?"] <>
      " | project: " <> ToString @ Lookup[d, "Project", "?"] <>
      " | cwd: " <> ToString @ Lookup[d, "Cwd", "?"],
    "period: " <> ToString @ Lookup[d, "StartedAtUTC", "?"] <> " .. " <>
      ToString @ Lookup[d, "LastAtUTC", "?"] <>
      " | models: " <> StringRiffle[ToString /@ Lookup[d, "Models", {}], ", "],
    With[{s = Lookup[d, "SummaryLLM", Missing[]]},
      If[StringQ[s], {"## llm summary", s}, {}]],
    "## summaries", ToString /@ Lookup[d, "Summaries", {}],
    "## user messages (bounded previews)",
    MapIndexed[ToString[First[#2]] <> ". " <> ToString[#1] &, Lookup[d, "UserPreviews", {}]],
    "## last assistant text", ToString @ Lookup[d, "AssistantTail", ""],
    "## files touched", ToString /@ Lookup[d, "FilesTouched", {}],
    "## tool counts",
    KeyValueMap[ToString[#1] <> ": " <> ToString[#2] &, Lookup[d, "ToolCounts", <||>]]},
    "\n"];
  <|"Body" -> txt, "Kind" -> "llmlog", "SessionId" -> sid,
    "Chars" -> StringLength[txt], "View" -> view|>];

SourceVault`SourceVaultRegisterLLMLogMCPAdapter[] :=
  If[Length[DownValues[SourceVault`SourceVaultRegisterMCPDataAdapter]] > 0,
    SourceVault`SourceVaultRegisterMCPDataAdapter["llmlog", <|
      "Kinds" -> {"llmlog", "claudecode"},
      "Available" -> True,
      "Description" -> "Claude Code session/work logs (digests) from ALL machines: " <>
        "what was implemented, discussed or fixed in past coding sessions, which files " <>
        "were touched, on which PC. Use for questions about past work/implementation logs. " <>
        "NOT git commit history (use sourcevault_commit_log for that).",
      "Capabilities" -> <|"Search" -> True, "ReadMetadata" -> True,
        "ReadSummary" -> True, "MetadataFilter" -> True,
        "ResolveObjectURI" -> True, "ReadBody" -> True|>,
      "RequireGrantFor" -> {"body", "raw"},
      "FilterKeys" -> {"machineTag", "project", "kind"},
      "FilterExamples" -> {"filters.machineTag=\"rapterlake4t\"",
        "filters.project=\"MyPackages\"",
        "filters.kind=\"interactive\" (excludes one-shot harness calls)"},
      "Search" -> iSVLLAdapterSearch,
      "OwnsURIQ" -> iSVLLOwnsURIQ,
      "Resolve" -> iSVLLAdapterResolve,
      "ReadBody" -> iSVLLAdapterReadBody|>],
    <|"Status" -> "Skipped", "Reason" -> "MCPLayerUnavailable"|>];

(* ロード時に自動登録 (mcp.wl が先にロードされていれば有効; 後ロードなら
   SourceVaultRegisterLLMLogMCPAdapter[] を明示呼びするか本ファイルを再 Get) *)
Quiet @ Check[SourceVault`SourceVaultRegisterLLMLogMCPAdapter[], Null];

End[]

EndPackage[]
