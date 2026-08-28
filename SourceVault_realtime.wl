(* ::Package:: *)

(* ============================================================
   SourceVault_realtime.wl -- OpenAI Realtime 音声ブリッジ
     (この機械で「現在選ばれているマイクとスピーカー」で会話する)

   This file is encoded in UTF-8.
   Load order: SourceVault.wl -> SourceVault_core.wl -> SourceVault_realtime.wl
   Load via:   Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_realtime.wl"]]

   == 何をするか ==
     VRCRealtime が VRChat の仮想ケーブル越しにやっていた「gpt-realtime との
     音声会話」を、VRChat 抜きで、この機械の既定の入出力デバイス (Windows で
     いま選ばれているマイクとスピーカー) に対して行う。開始と停止は関数
     SourceVaultRealtimeStart[] / SourceVaultRealtimeStop[] で行う。

     VRCRealtime がワールドのチャット欄へ出していた短い行 (聞いています /
     考えています / 応答本文 / エラー) は、ここではノートブックの
     ウインドウステータスバーへ出す ("Notebook" オプションで宛先を指定。
     既定は評価中のノートブック = スライドを開いていればそのスライド窓)。

   == 実行の形 ==
     音声と WebSocket は外部 Python プロセスが持つ (SourceVault_info/
     resources/python/SourceVault_realtime_worker.py)。カーネルは状態ファイルを
     読むだけで、音声やネットワークのホットパスに座らない。この分離は
     VRCRealtime と同じ理由 — FE とカーネルを止めないため。

   == プライバシー (重要) ==
     これはクラウド経路である。マイク音声と会話テキストは OpenAI へ送られる。
     ローカルで完結させたい読み上げ (PL >= 0.5 の資料) は従来どおり
     SourceVault_voice の Piper を使うこと。この層は
       - NBAccess`NBProviderCanAccess["openai", 0.5] を通らなければ起動しない
       - 既定でノートブックの Paid API 許可を要求する
         ("RequirePaidAPIApproval" -> False で外せる)
     非公開資料を音声で読み上げる用途には使わない。

   == 依存 ==
     Python 3.10+ と 2 つのパッケージ (websocket-client, sounddevice)。
     SourceVaultRealtimeInstall[] が %LOCALAPPDATA%/SourceVault/realtime/venv に
     専用の venv を作って入れる。SourceVaultRealtimeRuntime[] が不足を報告する。
   ============================================================ *)

BeginPackage["SourceVault`"];

(* ---- 設定 ---- *)

$SourceVaultRealtimeModel::usage =
  "$SourceVaultRealtimeModel は音声会話に使う OpenAI Realtime モデル (既定 \"gpt-realtime-2.1\")。";

$SourceVaultRealtimeVoice::usage =
  "$SourceVaultRealtimeVoice は Realtime の声 (既定 \"marin\")。";

$SourceVaultRealtimeInstructions::usage =
  "$SourceVaultRealtimeInstructions は Realtime セッションへ渡す既定の instructions。";

$SourceVaultRealtimeWorkerVersion::usage =
  "$SourceVaultRealtimeWorkerVersion はこのパッケージが期待するワーカーの版。走っているワーカーがこれと違えば入れ直す。";

$SourceVaultRealtimeVerbosity::usage =
  "$SourceVaultRealtimeVerbosity は応答の詳しさ (既定 \"Normal\")。\n" <>
  "\"Minimal\" (数語で用件だけ) | \"Brief\" (1〜2文) | \"Normal\" (2〜3文) | \"Detailed\" (3〜5文, 理由も) | \"Thorough\" (例や補足つき)。\n" <>
  "0〜1 の数値でも指定できる (0 が最短、1 が最も丁寧)。原稿の読み上げ (SourceVaultRealtimeNarrate) には効かない。";

$SourceVaultRealtimePython::usage =
  "$SourceVaultRealtimePython はワーカーを動かす Python 実行ファイルの明示指定 (既定 Automatic = 専用 venv)。";

$SourceVaultRealtimeRoot::usage =
  "$SourceVaultRealtimeRoot は Realtime ワーカー用 venv を置く root の override (既定 None = %LOCALAPPDATA%/SourceVault/realtime)。";

(* ---- 実行環境 ---- *)

SourceVaultRealtimeRuntime::usage =
  "SourceVaultRealtimeRuntime[] は音声会話ワーカーを動かせるかを Association で返す。\n" <>
  "\"Status\" が \"OK\" なら \"Python\" にインタプリタ、\"Worker\" にスクリプトのパスが入る。不足があれば \"Missing\" と \"Hint\"。";

SourceVaultRealtimeInstall::usage =
  "SourceVaultRealtimeInstall[] は音声会話ワーカー用の Python venv を作り、websocket-client と sounddevice を導入する。\n" <>
  "既に使える状態なら何もしない。\"Force\" -> True で再導入。";

SourceVaultRealtimeDevices::usage =
  "SourceVaultRealtimeDevices[] は Python から見えるオーディオデバイスの一覧を返す (既定デバイスに \"DefaultInput\" / \"DefaultOutput\" が立つ)。";

(* ---- 会話の開始 / 停止 ---- *)

SourceVaultRealtimeStart::usage =
  "SourceVaultRealtimeStart[] はこの機械の既定のマイクとスピーカーで gpt-realtime との音声会話を開始する (非ブロック)。\n" <>
  "経過はノートブックのウインドウステータスバーへ 1 行ずつ出る。宛先は \"Notebook\" (既定 Automatic = 評価中のノートブック)。\n" <>
  "主なオプション: \"Model\", \"Voice\", \"Instructions\", \"InputDevice\", \"OutputDevice\", \"AllowBargeIn\" (既定 False = 応答中はマイクを送らない), \"StartMuted\" (接続だけ先にしてマイクは後から), \"TranscribeInput\" (既定 False = こちらの発話は文字にしない), \"RequirePaidAPIApproval\" (既定 True), \"StatusBar\", \"PollSeconds\"。";

SourceVaultRealtimeStop::usage =
  "SourceVaultRealtimeStop[] は音声会話を終了する (最大 8 秒待ち、応答しなければ強制終了)。";

SourceVaultRealtimeStatus::usage =
  "SourceVaultRealtimeStatus[] は音声会話の状態 (Running / Connected / StatusLine / Devices / LastError など) を返す。";

SourceVaultRealtimeMessages::usage =
  "SourceVaultRealtimeMessages[] は会話中に出た行の履歴を返す。SourceVaultRealtimeMessages[n] で末尾 n 行。";

SourceVaultRealtimeMute::usage =
  "SourceVaultRealtimeMute[True|False] はマイク送信を一時停止/再開する。";

SourceVaultRealtimeSay::usage =
  "SourceVaultRealtimeSay[text] は text を利用者の発話として送り、応答させる (声を出さずに指示したいとき)。";

SourceVaultRealtimeSetVerbosity::usage =
  "SourceVaultRealtimeSetVerbosity[level] は実行中の応答の詳しさを変える。\n" <>
  "level は \"Minimal\" | \"Brief\" | \"Normal\" | \"Detailed\" | \"Thorough\" か 0〜1 の数値。";

SourceVaultRealtimeSetInstructions::usage =
  "SourceVaultRealtimeSetInstructions[text] は実行中のセッションの instructions を差し替える。";

SourceVaultRealtimeNarrate::usage =
  "SourceVaultRealtimeNarrate[id, text] は用意した原稿を Realtime の声で読み上げさせる (発表用)。\n" <>
  "読み終えて実際に音が鳴り終わると SourceVaultRealtimeStatus[][\"NarrationDone\"] が id になる。\n" <>
  "オプション: \"Heading\" (「スライド 3」など見出し), \"Instructions\" (この原稿だけへの追加指示)。";

SourceVaultRealtimeCancel::usage =
  "SourceVaultRealtimeCancel[] は今しゃべっている応答を中断し、溜まっている音声を捨てる。";

SourceVaultRealtimeEndTalk::usage =
  "SourceVaultRealtimeEndTalk[] は発表を終わらせて黙らせる。
" <>
  "しゃべっている分を切り、数秒間は自分から始める応答を作らせず (\"QuietSeconds\"、既定 4)、
" <>
  "以後は話しかけられたときだけ答えるよう文脈を閉じる。マイクは開いたまま。";

SourceVaultRealtimeLine::usage =
  "SourceVaultRealtimeLine[text] はステータスバーへ任意の 1 行を出す (会話中の表示と同じ経路)。";

$SourceVaultRealtimeSlideHandler::usage =
  "$SourceVaultRealtimeSlideHandler は音声からのスライド表示要求を処理する関数 (既定 None)。\n" <>
  "要求 <|\"id\", \"target\" (\"next\"|\"previous\"|\"first\"|\"last\"|\"number\"|\"title\"), \"number\", \"title\"|> を受け取り、\n" <>
  "表示を変えて <|\"status\" -> \"ok\"|\"error\", \"slide\" -> 番号, \"title\" -> 見出し, \"message\" -> 理由|> を返す。\n" <>
  "SlideWorkflow がロード時に登録する。None のときは show_slide ツール自体を出さない。";

$SourceVaultRealtimeAskHandler::usage =
  "$SourceVaultRealtimeAskHandler は音声からの資料問い合わせを処理する関数 (既定 None)。\n" <>
  "要求 <|\"id\", \"query\", \"allowWeb\"|> を受け取り、<|\"status\", \"answer\", \"route\", \"needWeb\", ...|> を返す。\n" <>
  "SourceVault_talkqa がロード時に登録する。None のときは ask_sourcevault ツールを出さない。";

SourceVaultRealtimeAskResult::usage =
  "SourceVaultRealtimeAskResult[id, result] は資料問い合わせの結果をワーカーへ返す (通常は handler 経由で自動)。";

SourceVaultRealtimeSlideRequest::usage =
  "SourceVaultRealtimeSlideRequest[] は処理待ちのスライド表示要求を返す (無ければ None)。";

SourceVaultRealtimeSlideResult::usage =
  "SourceVaultRealtimeSlideResult[id, result] はスライド表示要求の結果をワーカーへ返す (通常は handler 経由で自動)。";

SourceVaultRealtimeStatusNotebook::usage =
  "SourceVaultRealtimeStatusNotebook[nb] は実行中にステータスバーの出力先ノートブックを変更する。SourceVaultRealtimeStatusNotebook[] で現在の宛先。";

Begin["`Private`"];

(* ---- 既定値 (再ロードで利用者の設定を潰さない) ---- *)

If[! ValueQ[SourceVault`$SourceVaultRealtimeModel],
  SourceVault`$SourceVaultRealtimeModel = "gpt-realtime-2.1"];
If[! ValueQ[SourceVault`$SourceVaultRealtimeVoice],
  SourceVault`$SourceVaultRealtimeVoice = "marin"];
If[! ValueQ[SourceVault`$SourceVaultRealtimeInstructions],
  SourceVault`$SourceVaultRealtimeInstructions =
    "日本語で自然かつ簡潔に会話してください。聞き取れなかったときは聞き返してください。"];
If[! ValueQ[SourceVault`$SourceVaultRealtimeVerbosity],
  SourceVault`$SourceVaultRealtimeVerbosity = "Normal"];
If[! ValueQ[SourceVault`$SourceVaultRealtimePython],
  SourceVault`$SourceVaultRealtimePython = Automatic];
If[! ValueQ[SourceVault`$SourceVaultRealtimeRoot],
  SourceVault`$SourceVaultRealtimeRoot = None];
If[! ValueQ[SourceVault`$SourceVaultRealtimeSlideHandler],
  SourceVault`$SourceVaultRealtimeSlideHandler = None];
If[! ValueQ[SourceVault`$SourceVaultRealtimeAskHandler],
  SourceVault`$SourceVaultRealtimeAskHandler = None];

$iSVRTPackageDirectory = Quiet @ Check[DirectoryName[$InputFileName], ""];

(* 走っているワーカーが古い契約のままなら、黙って知らないコマンドを捨てるより
   入れ直したい。利用側 (SlideWorkflow) はこの値と Status の "WorkerVersion" を比べる *)
SourceVault`$SourceVaultRealtimeWorkerVersion = "1.4";

$iSVRTProcess = None;
$iSVRTStateFile = None;
$iSVRTControlFile = None;
$iSVRTNotebook = None;
$iSVRTPumpTask = None;
$iSVRTLastSeq = -1;
$iSVRTLastSlideRequest = None;
$iSVRTLastAskRequest = None;
$iSVRTCommandCount = 0;
$iSVRTDepsOK = None;   (* セッションキャッシュ: 依存の確認は毎回プロセスを起こさない *)

iSVRTFailure[tag_String, message_String, extra_: <||>] :=
  Failure[tag, Join[<|"MessageTemplate" -> message|>, extra]];

(* ---- パス解決 ---- *)

iSVRTWorkerPath[] := Module[{modern, legacy},
  modern = FileNameJoin[{$iSVRTPackageDirectory, "SourceVault_info", "resources",
    "python", "SourceVault_realtime_worker.py"}];
  legacy = FileNameJoin[{$iSVRTPackageDirectory, "SourceVault_realtime_worker.py"}];
  Which[FileExistsQ[modern], modern, FileExistsQ[legacy], legacy, True, modern]];

iSVRTRoot[] := Module[{override, local},
  override = SourceVault`$SourceVaultRealtimeRoot;
  If[StringQ[override] && StringLength[override] > 0, Return[override]];
  local = Environment["LOCALAPPDATA"];
  If[! StringQ[local] || local === "",
    local = FileNameJoin[{$HomeDirectory, ".sourcevault"}]];
  FileNameJoin[{local, "SourceVault", "realtime"}]];

iSVRTVenvPython[] := If[$OperatingSystem === "Windows",
  FileNameJoin[{iSVRTRoot[], "venv", "Scripts", "python.exe"}],
  FileNameJoin[{iSVRTRoot[], "venv", "bin", "python"}]];

(* ---- Python の解決 ---- *)

(* ProcessEnvironment は渡さない: $Language が "Japanese" のカーネルでは
   StartProcess/RunProcess が LibraryFunction::badenv で落ちる (実測)。
   出力を UTF-8 にするのは環境変数ではなく python の -X utf8 で行う。 *)
iSVRTRunPython[exe_String, args_List, seconds_: 30] :=
  Quiet @ TimeConstrained[
    RunProcess[Join[{exe, "-X", "utf8"}, args], All],
    seconds, $Failed];

iSVRTPythonWorksQ[exe_] := StringQ[exe] && FileExistsQ[exe] &&
  With[{r = iSVRTRunPython[exe, {"-c", "import sys; sys.stdout.write('ok')"}, 20]},
    AssociationQ[r] && Lookup[r, "ExitCode", 1] === 0 &&
      StringContainsQ[Lookup[r, "StandardOutput", ""], "ok"]];

(* 依存 (websocket-client / sounddevice) が入っているか。プロセスを 1 度起こすので
   セッション内でキャッシュする。Install / Force で無効化する。 *)
iSVRTDepsQ[exe_] := If[$iSVRTDepsOK === True, True,
  With[{r = iSVRTRunPython[exe,
      {"-c", "import sounddevice, websocket; print('deps-ok')"}, 60]},
    $iSVRTDepsOK = AssociationQ[r] && Lookup[r, "ExitCode", 1] === 0 &&
      StringContainsQ[Lookup[r, "StandardOutput", ""], "deps-ok"];
    $iSVRTDepsOK]];

(* venv を作るための「素の」Python。Windows の PATH 上の python.exe は Store の
   スタブのことがあるので、必ず実際に動くか確かめてから採る。 *)
iSVRTBasePythonCandidates[] := Module[{out = {}, local, r},
  If[StringQ[SourceVault`$SourceVaultRealtimePython],
    AppendTo[out, SourceVault`$SourceVaultRealtimePython]];
  (* py ランチャに実体を訊く *)
  r = Quiet @ TimeConstrained[
    RunProcess[{"py", "-3", "-c", "import sys; sys.stdout.write(sys.executable)"}, All],
    30, $Failed];
  If[AssociationQ[r] && Lookup[r, "ExitCode", 1] === 0,
    With[{p = StringTrim[Lookup[r, "StandardOutput", ""]]},
      If[StringQ[p] && FileExistsQ[p], AppendTo[out, p]]]];
  local = Environment["LOCALAPPDATA"];
  If[StringQ[local],
    (* PyManager (pythoncore-3.x-64) と従来のインストーラ配置 *)
    out = Join[out,
      Reverse @ Sort @ Flatten[{
        FileNames["python.exe", FileNameJoin[{local, "Python"}], 2],
        FileNames["python.exe", FileNameJoin[{local, "Programs", "Python"}], 2]}]]];
  out = Join[out, Reverse @ Sort @ FileNames["python.exe", {"C:\\Python313", "C:\\Python312", "C:\\Python311"}]];
  DeleteDuplicates @ Select[out, StringQ[#] && FileExistsQ[#] &]];

iSVRTBasePython[] := SelectFirst[iSVRTBasePythonCandidates[], iSVRTPythonWorksQ, None];

iSVRTResolvePython[spec_] := Which[
  StringQ[spec] && FileExistsQ[spec], spec,
  StringQ[SourceVault`$SourceVaultRealtimePython] &&
    FileExistsQ[SourceVault`$SourceVaultRealtimePython],
    SourceVault`$SourceVaultRealtimePython,
  FileExistsQ[iSVRTVenvPython[]], iSVRTVenvPython[],
  True, None];

iSVRTInstallHint[] :=
  "音声会話ワーカーの Python 環境がありません。次を一度だけ評価してください:\n" <>
  "  SourceVaultRealtimeInstall[]\n" <>
  "  (" <> iSVRTVenvPython[] <> " に venv を作り、websocket-client と sounddevice を入れます)\n" <>
  "既存の Python を使うなら $SourceVaultRealtimePython にそのパスを設定してください。";

SourceVaultRealtimeRuntime[] := Module[{python, worker, missing = {}, hints = {}, deps},
  worker = iSVRTWorkerPath[];
  If[! FileExistsQ[worker],
    AppendTo[missing, "Worker"];
    AppendTo[hints, "SourceVault_realtime_worker.py が見つかりません: " <> worker]];
  python = iSVRTResolvePython[Automatic];
  deps = False;
  If[! StringQ[python],
    AppendTo[missing, "Python"]; AppendTo[hints, iSVRTInstallHint[]],
    deps = TrueQ[iSVRTDepsQ[python]];
    If[! deps,
      AppendTo[missing, "PythonPackages"];
      AppendTo[hints, "websocket-client / sounddevice が入っていません。SourceVaultRealtimeInstall[] を評価してください。"]]];
  <|"Status" -> If[missing === {}, "OK", "Missing"],
    "Python" -> If[StringQ[python], python, None],
    "PythonSource" -> Which[
      ! StringQ[python], None,
      python === iSVRTVenvPython[], "Venv",
      True, "Custom"],
    "Worker" -> worker,
    "Dependencies" -> deps,
    "Root" -> iSVRTRoot[],
    "Missing" -> missing,
    "Hint" -> If[hints === {}, None, StringRiffle[hints, "\n"]]|>];

Options[SourceVaultRealtimeInstall] = {"Force" -> False, "BasePython" -> Automatic};

SourceVaultRealtimeInstall[OptionsPattern[]] := Module[
  {force, base, venvPython, root, r, packages},
  force = TrueQ[OptionValue["Force"]];
  $iSVRTDepsOK = None;
  venvPython = iSVRTVenvPython[];
  If[! force && iSVRTPythonWorksQ[venvPython] && iSVRTDepsQ[venvPython],
    Return[<|"Status" -> "OK", "Reason" -> "AlreadyInstalled",
      "Python" -> venvPython|>]];
  base = OptionValue["BasePython"];
  If[base === Automatic, base = iSVRTBasePython[]];
  If[! iSVRTPythonWorksQ[base],
    Return[iSVRTFailure["SourceVaultRealtimeNoPython",
      "使える Python が見つかりません。$SourceVaultRealtimePython に python.exe のパスを設定するか、\"BasePython\" で指定してください。",
      <|"Candidates" -> iSVRTBasePythonCandidates[]|>]]];
  root = iSVRTRoot[];
  Quiet[CreateDirectory[root, CreateIntermediateDirectories -> True]];
  If[! FileExistsQ[venvPython],
    r = iSVRTRunPython[base, {"-m", "venv", FileNameJoin[{root, "venv"}]}, 300];
    If[! AssociationQ[r] || Lookup[r, "ExitCode", 1] =!= 0,
      Return[iSVRTFailure["SourceVaultRealtimeVenvFailed",
        "venv を作れませんでした。",
        <|"BasePython" -> base, "Result" -> r|>]]]];
  packages = {"websocket-client", "sounddevice"};
  r = iSVRTRunPython[venvPython,
    Join[{"-m", "pip", "install", "--upgrade", "--disable-pip-version-check"}, packages], 600];
  If[! AssociationQ[r] || Lookup[r, "ExitCode", 1] =!= 0,
    Return[iSVRTFailure["SourceVaultRealtimePipFailed",
      "依存パッケージ (websocket-client / sounddevice) を導入できませんでした。",
      <|"Python" -> venvPython, "Result" -> r|>]]];
  $iSVRTDepsOK = None;
  If[! iSVRTDepsQ[venvPython],
    Return[iSVRTFailure["SourceVaultRealtimeDepsMissing",
      "導入後も websocket-client / sounddevice を読み込めません。",
      <|"Python" -> venvPython|>]]];
  <|"Status" -> "OK", "Reason" -> "Installed", "Python" -> venvPython,
    "Packages" -> packages, "Root" -> root|>];

SourceVaultRealtimeDevices[] := Module[{runtime, r, json},
  runtime = SourceVaultRealtimeRuntime[];
  If[runtime["Status"] =!= "OK",
    Return[iSVRTFailure["SourceVaultRealtimeUnavailable",
      "音声会話ワーカーを実行できません。", <|"Hint" -> runtime["Hint"]|>]]];
  r = iSVRTRunPython[runtime["Python"], {runtime["Worker"], "--list-devices"}, 60];
  If[! AssociationQ[r] || Lookup[r, "ExitCode", 1] =!= 0,
    Return[iSVRTFailure["SourceVaultRealtimeDeviceQueryFailed",
      "オーディオデバイスを列挙できませんでした。", <|"Result" -> r|>]]];
  json = Quiet @ ImportByteArray[
    StringToByteArray[Lookup[r, "StandardOutput", ""], "UTF-8"], "RawJSON"];
  If[! AssociationQ[json], Return[iSVRTFailure["SourceVaultRealtimeDeviceQueryFailed",
    "デバイス一覧を解釈できませんでした。", <|"Raw" -> Lookup[r, "StandardOutput", ""]|>]]];
  Association[
    "Index" -> #["index"], "Name" -> #["name"], "HostAPI" -> #["hostApi"],
    "InputChannels" -> #["inputChannels"], "OutputChannels" -> #["outputChannels"],
    "DefaultInput" -> TrueQ[#["defaultInput"]],
    "DefaultOutput" -> TrueQ[#["defaultOutput"]]] & /@ Lookup[json, "devices", {}]];

(* ---- プロセス / 状態 ---- *)

iSVRTRunningQ[] := MatchQ[$iSVRTProcess, _ProcessObject] &&
  TrueQ[Quiet[ProcessStatus[$iSVRTProcess] === "Running"]];

iSVRTReadState[] := Module[{value},
  If[! StringQ[$iSVRTStateFile] || ! FileExistsQ[$iSVRTStateFile], Return[<||>]];
  value = Quiet @ Check[Import[$iSVRTStateFile, "RawJSON"], <||>];
  If[AssociationQ[value], value, <||>]];

(* 制御は原子的にファイルへ置く。uv/python の stdin は Windows で当てにならない
   (VRCRealtime で踏んだ) ので、同じくファイル経由にする。 *)
iSVRTSend[command_Association] := Module[{payload, temporary, bytes},
  If[! iSVRTRunningQ[],
    Return[iSVRTFailure["SourceVaultRealtimeNotRunning", "音声会話は動いていません。"]]];
  If[! StringQ[$iSVRTControlFile],
    Return[iSVRTFailure["SourceVaultRealtimeNoControlFile", "制御ファイルがありません。"]]];
  $iSVRTCommandCount++;
  (* キーは "commandId"。"id" にすると narrate が渡す読み上げ ID を潰し、
     完了通知が通し番号で返ってきて呼び出し側の照合が永久に一致しなくなる
     (実測 2026-08-22: スライドが送られない原因はこれだった) *)
  payload = Append[command, "commandId" -> ToString[$iSVRTCommandCount]];
  (* 1 行 1 コマンドのキューなので必ず Compact (既定は整形されて改行が入る) *)
  bytes = Quiet @ Check[ExportByteArray[payload, "RawJSON", "Compact" -> True], $Failed];
  If[! ByteArrayQ[bytes],
    Return[iSVRTFailure["SourceVaultRealtimeBadCommand", "制御コマンドを組み立てられません。"]]];
  (* 追記キュー: 1 スロットのファイルだと、続けて送った 2 つのうち先の 1 つが
     ワーカーに読まれる前に消える (mute -> narrate で mute が落ちた) *)
  Quiet @ Check[
    Module[{strm = OpenAppend[$iSVRTControlFile, BinaryFormat -> True]},
      If[Head[strm] =!= OutputStream, Return[$Failed, Module]];
      WithCleanup[BinaryWrite[strm, Join[Normal[bytes], {10}]], Quiet @ Close[strm]]],
    $Failed];
  <|"Status" -> "Sent", "Command" -> Lookup[command, "command", None]|>];

(* ---- ステータスバーへの吐き出し ---- *)

(* 宛先が閉じられていたら書かない。ただし Notebooks[] が取れないときは
   「閉じた」ではなく「判定材料が無い」なので、書きにいって静かに失敗させる *)
iSVRTSetStatusBar[line_] := Module[{nbs},
  If[Head[$iSVRTNotebook] =!= NotebookObject, Return[Null]];
  nbs = Quiet[Notebooks[]];
  If[ListQ[nbs] && ! MemberQ[nbs, $iSVRTNotebook], Return[Null]];
  Quiet[CurrentValue[$iSVRTNotebook, WindowStatusArea] = line];
  Null];

iSVRTPumpStop[] := (
  If[Head[$iSVRTPumpTask] === TaskObject, Quiet[TaskRemove[$iSVRTPumpTask]]];
  $iSVRTPumpTask = None);

iSVRTPumpStart[seconds_] := (iSVRTPumpStop[];
  $iSVRTLastSeq = -1;
  $iSVRTPumpTask = Quiet[SessionSubmit[ScheduledTask[iSVRTPump[], seconds]]]);

(* ワーカーが出した行だけをステータスバーへ移す。カーネル側で文面を作らないのは、
   表示と実際の状態がずれないようにするため (行の出所は 1 つ)。 *)
iSVRTPump[] := Module[{state, seq, line},
  state = iSVRTReadState[];
  seq = Lookup[state, "statusSeq", None];
  If[NumericQ[seq] && seq =!= $iSVRTLastSeq,
    $iSVRTLastSeq = seq;
    line = Lookup[state, "statusLine", ""];
    If[StringQ[line], iSVRTSetStatusBar[line]]];
  iSVRTDispatchSlideRequest[state];
  iSVRTDispatchAskRequest[state];
  If[! iSVRTRunningQ[], iSVRTPumpStop[]];
  Null];

(* 声からのスライド表示要求。FE を触れるのはカーネルだけなので、ワーカーは
   要求を state に置くだけにして、ここで登録済みの handler に渡す。
   handler が返した内容をそのままワーカーへ戻し、モデルに結果を伝えさせる。 *)
iSVRTDispatchSlideRequest[state_Association] := Module[{req, id, handler, res},
  req = Lookup[state, "slideRequest", None];
  If[! AssociationQ[req], $iSVRTLastSlideRequest = None; Return[Null]];
  id = ToString[Lookup[req, "id", ""]];
  If[id === "" || id === $iSVRTLastSlideRequest, Return[Null]];
  $iSVRTLastSlideRequest = id;
  handler = SourceVault`$SourceVaultRealtimeSlideHandler;
  If[handler === None,
    SourceVaultRealtimeSlideResult[id,
      <|"status" -> "error", "message" -> "スライドを操作できる相手がいません。"|>];
    Return[Null]];
  res = Quiet[handler[req]];
  SourceVaultRealtimeSlideResult[id,
    If[AssociationQ[res], res,
      <|"status" -> "error", "message" -> "スライドを動かせませんでした。"|>]];
  Null];

(* 資料への問い合わせ。答えてよい内容かの判断は handler (TalkQA) 側にある *)
iSVRTDispatchAskRequest[state_Association] := Module[{req, id, handler, res},
  req = Lookup[state, "askRequest", None];
  If[! AssociationQ[req], $iSVRTLastAskRequest = None; Return[Null]];
  id = ToString[Lookup[req, "id", ""]];
  If[id === "" || id === $iSVRTLastAskRequest, Return[Null]];
  $iSVRTLastAskRequest = id;
  handler = SourceVault`$SourceVaultRealtimeAskHandler;
  If[handler === None,
    SourceVaultRealtimeAskResult[id,
      <|"status" -> "error", "message" -> "資料を引ける相手がいません。"|>];
    Return[Null]];
  res = Quiet[handler[req]];
  SourceVaultRealtimeAskResult[id,
    If[AssociationQ[res], res,
      <|"status" -> "error", "message" -> "資料を引けませんでした。"|>]];
  Null];

SourceVaultRealtimeAskResult[id_, result_Association] :=
  iSVRTSend[<|"command" -> "askresult", "id" -> ToString[id], "result" -> result|>];

SourceVaultRealtimeSlideRequest[] := Module[{req = Lookup[iSVRTReadState[], "slideRequest", None]},
  If[AssociationQ[req], req, None]];

SourceVaultRealtimeSlideResult[id_, result_Association] :=
  iSVRTSend[<|"command" -> "slideresult", "id" -> ToString[id], "result" -> result|>];

SourceVaultRealtimeStatusNotebook[] := $iSVRTNotebook;

SourceVaultRealtimeStatusNotebook[nb_NotebookObject] := ($iSVRTNotebook = nb);

SourceVaultRealtimeStatusNotebook[None] := ($iSVRTNotebook = None);

(* ---- 起動 ---- *)

iSVRTEnsureNBAccess[] := Module[{path, loaded},
  If[Length[DownValues[NBAccess`NBGetAPIKey]] > 0, Return[True]];
  path = FileNameJoin[{$iSVRTPackageDirectory, "NBAccess.wl"}];
  If[! FileExistsQ[path], Return[False]];
  loaded = Quiet @ Check[Block[{$CharacterEncoding = "UTF-8"}, Get[path]], $Failed];
  loaded =!= $Failed && Length[DownValues[NBAccess`NBGetAPIKey]] > 0];

iSVRTResolveNotebook[Automatic] := Quiet @ Check[EvaluationNotebook[], None];
iSVRTResolveNotebook[None] := None;
iSVRTResolveNotebook[nb_] := nb;

iSVRTNumberString[value_] := ToString[N[value], InputForm];

(* 応答の詳しさ。名前でも 0〜1 の数値でも受ける (ワーカー側でも同じ正規化をする) *)
iSVRTVerbosityString[Automatic] :=
  iSVRTVerbosityString[SourceVault`$SourceVaultRealtimeVerbosity];
iSVRTVerbosityString[s_String] := ToLowerCase[StringTrim[s]];
iSVRTVerbosityString[x_?NumericQ] := iSVRTNumberString[Clip[N[x], {0., 1.}]];
iSVRTVerbosityString[_] := "normal";

Options[SourceVaultRealtimeStart] = {
  "Notebook" -> Automatic,
  "RequirePaidAPIApproval" -> True,
  "Model" -> Automatic,
  "Voice" -> Automatic,
  "Instructions" -> Automatic,
  "InputDevice" -> Automatic,
  "OutputDevice" -> Automatic,
  "Verbosity" -> Automatic,
  "AllowBargeIn" -> False,
  "StartMuted" -> False,
  "SlideControl" -> Automatic,
  "AskControl" -> Automatic,
  "TranscribeInput" -> False,
  "TranscriptionModel" -> "gpt-4o-mini-transcribe",
  "ChunkMilliseconds" -> 20,
  "TurnDetection" -> "Semantic",
  "Eagerness" -> "Low",
  "InputLevelGate" -> 0.,
  "VADThreshold" -> 0.5,
  "PrefixPaddingMilliseconds" -> 200,
  "SilenceDurationMilliseconds" -> 350,
  "OutputCooldownMilliseconds" -> 400,
  "SafetyIdentifier" -> "",
  "StatusBar" -> True,
  "PollSeconds" -> 0.4,
  "Python" -> Automatic};

SourceVaultRealtimeStart[OptionsPattern[]] := Module[
  {runtime, python, worker, nb, apiKey, model, voice, instructions,
   inputDevice, outputDevice, stateFile, controlFile, command,
   process, deadline, state, workerError, instructionsFile},

  If[iSVRTRunningQ[],
    Return[iSVRTFailure["SourceVaultRealtimeAlreadyRunning",
      "音声会話は既に動いています (SourceVaultRealtimeStop[] で終了)。",
      <|"Status" -> SourceVaultRealtimeStatus[]|>]]];

  runtime = SourceVaultRealtimeRuntime[];
  python = iSVRTResolvePython[OptionValue["Python"]];
  If[! StringQ[python] || runtime["Status"] =!= "OK",
    Return[iSVRTFailure["SourceVaultRealtimeUnavailable",
      "音声会話ワーカーを実行できません。",
      <|"Hint" -> runtime["Hint"], "Runtime" -> runtime|>]]];
  worker = runtime["Worker"];

  If[! TrueQ[iSVRTEnsureNBAccess[]],
    Return[iSVRTFailure["SourceVaultRealtimeNBAccessUnavailable",
      "NBAccess.wl を読み込めません (API キーの取得に必要)。"]]];

  nb = iSVRTResolveNotebook[OptionValue["Notebook"]];
  If[TrueQ[OptionValue["RequirePaidAPIApproval"]],
    If[! MatchQ[nb, _NotebookObject],
      Return[iSVRTFailure["SourceVaultRealtimeNotebookRequired",
        "Paid API の承認確認にはノートブックが要ります (\"Notebook\" を指定するか \"RequirePaidAPIApproval\" -> False)。"]]];
    If[! TrueQ @ Quiet @ NBAccess`NBGetNotebookPaidAPIAllowed[nb],
      Return[iSVRTFailure["SourceVaultRealtimePaidAPINotAllowed",
        "このノートブックは有料 API を許可していません。NBAccess`NBSetNotebookPaidAPIAllowed[nb, True] で許可してください。"]]]];

  (* クラウド経路のプロバイダゲート: SourceVault のプライバシー契約と同じ入口 *)
  If[! TrueQ @ Quiet @ NBAccess`NBProviderCanAccess["openai", 0.5],
    Return[iSVRTFailure["SourceVaultRealtimeOpenAIDisabled",
      "NBAccess のプロバイダ方針が現在 OpenAI へのアクセスを認めていません。"]]];

  apiKey = Quiet @ NBAccess`NBGetAPIKey["openai",
    NBAccess`PrivacySpec -> <|"AccessLevel" -> 1.0|>];
  If[! StringQ[apiKey] || StringLength[apiKey] === 0,
    Return[iSVRTFailure["SourceVaultRealtimeAPIKeyMissing",
      "OPENAI_API_KEY を NBAccess / SystemCredential から取得できませんでした。"]]];

  model = Replace[OptionValue["Model"], Automatic :> SourceVault`$SourceVaultRealtimeModel];
  voice = Replace[OptionValue["Voice"], Automatic :> SourceVault`$SourceVaultRealtimeVoice];
  instructions = Replace[OptionValue["Instructions"],
    Automatic :> SourceVault`$SourceVaultRealtimeInstructions];
  inputDevice = Replace[OptionValue["InputDevice"], Automatic -> ""];
  outputDevice = Replace[OptionValue["OutputDevice"], Automatic -> ""];

  (* 指示文はファイルで渡す。環境変数に日本語を入れると StartProcess が失敗する *)
  instructionsFile = FileNameJoin[{$TemporaryDirectory,
    "sourcevault-realtime-instructions-" <>
      StringReplace[CreateUUID[], "-" -> ""] <> ".txt"}];
  Quiet @ Check[
    Module[{strm = OpenWrite[instructionsFile, BinaryFormat -> True]},
      If[Head[strm] === OutputStream,
        WithCleanup[
          BinaryWrite[strm, StringToByteArray[ToString[instructions], "UTF-8"]],
          Quiet @ Close[strm]]]],
    Null];
  stateFile = FileNameJoin[{$TemporaryDirectory,
    "sourcevault-realtime-" <> StringReplace[CreateUUID[], "-" -> ""] <> ".json"}];
  controlFile = FileNameJoin[{$TemporaryDirectory,
    "sourcevault-realtime-control-" <> StringReplace[CreateUUID[], "-" -> ""] <> ".json"}];

  command = Join[
    {python, "-X", "utf8", worker,
     "--state-file", stateFile,
     "--control-file", controlFile,
     "--model", ToString[model],
     "--voice", ToString[voice],
     "--chunk-ms", ToString[OptionValue["ChunkMilliseconds"]],
     "--vad-threshold", iSVRTNumberString[OptionValue["VADThreshold"]],
     "--prefix-padding-ms", ToString[OptionValue["PrefixPaddingMilliseconds"]],
     "--silence-duration-ms", ToString[OptionValue["SilenceDurationMilliseconds"]],
     "--output-cooldown-ms", ToString[OptionValue["OutputCooldownMilliseconds"]],
     "--input-gate", iSVRTNumberString[OptionValue["InputLevelGate"]],
     "--turn-detection", ToLowerCase[ToString[OptionValue["TurnDetection"]]],
     "--vad-eagerness", ToLowerCase[ToString[OptionValue["Eagerness"]]],
     "--verbosity", iSVRTVerbosityString[OptionValue["Verbosity"]],
     "--instructions-file", instructionsFile, "--api-key-stdin"},
    If[StringQ[inputDevice] && inputDevice =!= "", {"--input-device", inputDevice}, {}],
    If[StringQ[outputDevice] && outputDevice =!= "", {"--output-device", outputDevice}, {}],
    If[TrueQ[OptionValue["AllowBargeIn"]], {"--allow-barge-in"}, {}],
    If[TrueQ[OptionValue["StartMuted"]], {"--start-muted"}, {}],
    (* 表示を変える相手がいるときだけ show_slide を出す。誰も応えないツールを
       モデルに見せると、呼んで待たされるだけになる *)
    If[Replace[OptionValue["SlideControl"], Automatic :>
        (SourceVault`$SourceVaultRealtimeSlideHandler =!= None)] === True,
      {"--slide-tool"}, {}],
    If[Replace[OptionValue["AskControl"], Automatic :>
        (SourceVault`$SourceVaultRealtimeAskHandler =!= None)] === True,
      {"--ask-tool"}, {}],
    If[TrueQ[OptionValue["TranscribeInput"]],
      {"--transcribe-input", "--transcription-model",
       ToString[OptionValue["TranscriptionModel"]]}, {}],
    With[{sid = OptionValue["SafetyIdentifier"]},
      If[StringQ[sid] && sid =!= "", {"--safety-identifier", sid}, {}]]];

  (* 環境も渡さない ($Language が Japanese だと StartProcess ごと落ちる)。
     キーは標準入力から 1 行だけ渡す: 環境にもディスクにも残さない *)
  process = Quiet @ Check[StartProcess[command], $Failed];
  If[MatchQ[process, _ProcessObject],
    Quiet @ Check[WriteLine[process, apiKey], Null]];
  apiKey =.;
  If[! MatchQ[process, _ProcessObject],
    Return[iSVRTFailure["SourceVaultRealtimeStartFailed",
      "ワーカープロセスを起動できませんでした。", <|"Command" -> First[command]|>]]];

  $iSVRTProcess = process;
  $iSVRTStateFile = stateFile;
  $iSVRTControlFile = controlFile;
  $iSVRTNotebook = If[TrueQ[OptionValue["StatusBar"]] && MatchQ[nb, _NotebookObject],
    nb, None];

  (* 引数の検証に落ちるとワーカーは 1 秒足らずで死ぬ。ここで見ないと
     「起動したのに話しかけても答えない」だけが残る (VRCRealtime と同じ扱い)。
     非ブロックの原則は保つ: 上限 4 秒、生きていれば即抜ける。 *)
  deadline = AbsoluteTime[] + 4.;
  While[AbsoluteTime[] < deadline,
    Pause[0.15];
    If[ProcessStatus[process] =!= "Running", Break[]];
    state = iSVRTReadState[];
    If[AssociationQ[state] && Lookup[state, "status", ""] === "error", Break[]];
    If[AssociationQ[state] && KeyExistsQ[state, "connected"], Break[]]];
  state = iSVRTReadState[];
  (* Module を挟まずに書くのは、Return が最内 Module から返ってしまい
     失敗しても後続が走ってしまうため (VRCRealtime で踏んだ形) *)
  If[ProcessStatus[process] =!= "Running" ||
      (AssociationQ[state] && Lookup[state, "status", ""] === "error"),
    workerError = Quiet @ Check[
      ReadString[ProcessConnection[process, "StandardError"]], ""];
    Quiet[KillProcess[process]];
    $iSVRTProcess = None;
    Return[iSVRTFailure["SourceVaultRealtimeWorkerDied",
      "ワーカーが起動直後に終了しました。",
      <|"Reason" -> Lookup[state, "lastError", None],
        "StandardError" -> If[StringQ[workerError],
          StringTake[workerError, UpTo[2000]], ""]|>]]];

  If[TrueQ[OptionValue["StatusBar"]], iSVRTPumpStart[OptionValue["PollSeconds"]]];

  <|"Status" -> "Started", "Model" -> model, "Voice" -> voice,
    "Notebook" -> $iSVRTNotebook, "StateFile" -> stateFile,
    "Python" -> python, "AllowBargeIn" -> TrueQ[OptionValue["AllowBargeIn"]],
    "TranscribeInput" -> TrueQ[OptionValue["TranscribeInput"]]|>];

(* ---- 停止 ---- *)

Options[SourceVaultRealtimeStop] = {"TimeConstraint" -> 8., "ClearStatusBar" -> True};

SourceVaultRealtimeStop[OptionsPattern[]] := Module[{deadline, wasRunning},
  wasRunning = iSVRTRunningQ[];
  If[wasRunning, iSVRTSend[<|"command" -> "stop"|>]];
  deadline = AbsoluteTime[] + OptionValue["TimeConstraint"];
  While[iSVRTRunningQ[] && AbsoluteTime[] < deadline, Pause[0.2]];
  If[iSVRTRunningQ[], Quiet[KillProcess[$iSVRTProcess]]];
  iSVRTPumpStop[];
  If[TrueQ[OptionValue["ClearStatusBar"]], iSVRTSetStatusBar[""]];
  $iSVRTProcess = None;
  <|"Status" -> If[wasRunning, "Stopped", "NotRunning"]|>];

(* ---- 状態 / 操作 ---- *)

SourceVaultRealtimeStatus[] := Module[{state = iSVRTReadState[]},
  <|"Running" -> iSVRTRunningQ[],
    "Connected" -> TrueQ[Lookup[state, "connected", False]],
    "WorkerStatus" -> Lookup[state, "status", None],
    "WorkerVersion" -> Lookup[state, "workerVersion", None],
    "Model" -> Lookup[state, "model", None],
    "Voice" -> Lookup[state, "voice", None],
    "Muted" -> TrueQ[Lookup[state, "muted", False]],
    "Verbosity" -> Lookup[state, "verbosity", None],
    "TurnDetection" -> Lookup[state, "turnDetection", None],
    "InputPeak" -> Lookup[state, "inputPeak", 0.],
    "SlideTool" -> TrueQ[Lookup[state, "slideTool", False]],
    "AskTool" -> TrueQ[Lookup[state, "askTool", False]],
    "AllowBargeIn" -> TrueQ[Lookup[state, "allowBargeIn", False]],
    "Mode" -> Lookup[state, "mode", None],
    "StatusLine" -> Lookup[state, "statusLine", ""],
    "InputDevice" -> Lookup[state, "resolvedInputDevice", None],
    "OutputDevice" -> Lookup[state, "resolvedOutputDevice", None],
    "Speaking" -> TrueQ[Lookup[state, "speaking", False]],
    "NarrationActive" -> Lookup[state, "narrationActive", None],
    "NarrationDone" -> Lookup[state, "narrationDone", None],
    "LastUserText" -> Lookup[state, "lastUserText", ""],
    "LastAssistantText" -> Lookup[state, "lastAssistantText", ""],
    "LastError" -> Lookup[state, "lastError", None],
    "Reconnects" -> Lookup[state, "reconnects", 0],
    "Notebook" -> $iSVRTNotebook,
    "StateFile" -> $iSVRTStateFile|>];

SourceVaultRealtimeMessages[] := SourceVaultRealtimeMessages[All];

SourceVaultRealtimeMessages[n_] := Module[{state = iSVRTReadState[], messages},
  messages = Lookup[state, "messages", {}];
  If[! ListQ[messages], messages = {}];
  messages = Association["Sequence" -> Lookup[#, "seq", 0],
      "Time" -> With[{t = Lookup[#, "t", 0]},
        If[NumericQ[t], Quiet[FromUnixTime[t]], None]],
      "Kind" -> Lookup[#, "kind", "status"],
      "Text" -> Lookup[#, "text", ""]] & /@ Select[messages, AssociationQ];
  If[IntegerQ[n] && n > 0, Take[messages, -Min[n, Length[messages]]], messages]];

SourceVaultRealtimeMute[value : (True | False) : True] :=
  iSVRTSend[<|"command" -> "mute", "value" -> value|>];

SourceVaultRealtimeSay[text_String] :=
  iSVRTSend[<|"command" -> "say", "text" -> text|>];

SourceVaultRealtimeSetInstructions[text_String] :=
  iSVRTSend[<|"command" -> "instructions", "text" -> text|>];

SourceVaultRealtimeSetVerbosity[level_] := (
  SourceVault`$SourceVaultRealtimeVerbosity = level;
  iSVRTSend[<|"command" -> "verbosity",
    "value" -> iSVRTVerbosityString[level]|>]);

SourceVaultRealtimeLine[text_String] :=
  iSVRTSend[<|"command" -> "line", "text" -> text|>];

Options[SourceVaultRealtimeNarrate] = {"Heading" -> "", "Instructions" -> ""};

SourceVaultRealtimeNarrate[id_, text_String, OptionsPattern[]] :=
  iSVRTSend[<|"command" -> "narrate", "id" -> ToString[id], "text" -> text,
    "heading" -> ToString[OptionValue["Heading"]],
    "instructions" -> ToString[OptionValue["Instructions"]]|>];

SourceVaultRealtimeCancel[] := iSVRTSend[<|"command" -> "cancel"|>];

Options[SourceVaultRealtimeEndTalk] = {"QuietSeconds" -> 4.};

SourceVaultRealtimeEndTalk[OptionsPattern[]] :=
  iSVRTSend[<|"command" -> "endtalk",
    "quietSeconds" -> N[OptionValue["QuietSeconds"]]|>];

End[];

EndPackage[];
