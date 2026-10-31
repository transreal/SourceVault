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

   == 2 つの API (モデルで決まる) ==
     gpt-realtime-*  Realtime API。1 つのモデルが聞いて考えて話し、show_slide /
                     ask_sourcevault を関数呼び出しで呼ぶ。
     gpt-live-*      GPT-Live (全二重: 聞きながら話す)。作業はクライアント委譲で
                     アプリ側へ回ってくる。ワーカーが直近の書き起こしから依頼を読み、
                     同じ handler ($SourceVaultRealtimeSlideHandler /
                     $SourceVaultRealtimeAskHandler = SourceVault → 許可が出たらウェブ)
                     で答えを作って返す。カーネル側の契約 (状態ファイルの slideRequest /
                     askRequest、Narrate / NarrationDone) は両者で同じ。

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
  "$SourceVaultRealtimeModel は音声会話に使うモデル (既定 \"gpt-realtime-2.1\")。\n" <>
  "\"gpt-live-1\" にすると GPT-Live (全二重・クライアント委譲) で会話する。候補は SourceVaultRealtimeModels[]。";

$SourceVaultRealtimeModels::usage =
  "$SourceVaultRealtimeModels は利用者が足す/上書きする音声会話モデル (既定 <||>)。\n" <>
  "形は <|\"モデル名\" -> <|\"Provider\" -> \"OpenAI\", \"API\" -> \"Realtime\"|\"Live\", \"Label\" -> 短い表示名, \"Description\" -> 説明|>|>。組み込みの登録簿に足される。";

SourceVaultRealtimeModels::usage =
  "SourceVaultRealtimeModels[] は選べる音声会話モデルの登録簿 (モデル名 -> <|Provider, API, Label, Description|>) を返す。\n" <>
  "SourceVaultRealtimeModels[\"ByProvider\"] はプロバイダ -> モデル名の一覧、SourceVaultRealtimeModels[provider] はそのプロバイダのモデル名の一覧。";

SourceVaultRealtimeModelAPI::usage =
  "SourceVaultRealtimeModelAPI[model] はモデルが話す API (\"Realtime\" | \"Live\") を返す。登録簿に無い gpt-live-* も \"Live\"。";

$SourceVaultRealtimeVoice::usage =
  "$SourceVaultRealtimeVoice は Realtime の声 (既定 \"marin\")。";

$SourceVaultRealtimeKeepAliveLevel::usage =
  "$SourceVaultRealtimeKeepAliveLevel は、話していない間もスピーカーへ流し続ける聞こえない小さなノイズの大きさ (dBFS、既定 -70)。Bluetooth スピーカーなどが無音で休み、話し始めが欠けるのを防ぐ (ワーカー 1.12)。それでも欠けるときは -60 くらいまで上げる。None で流さない (以前の動き)。SourceVaultRealtimeStart の \"KeepAliveLevel\" で 1 回だけ変えることもできる。";

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
  "既に使える状態なら何もしない。\"Force\" -> True で再導入。\"Vosk\" -> True で vosk も入れる (発表中の許可ワードでの割り込みに使う。モデルは SourceVault_voice の SourceVaultSpeechModel[])。";

SourceVaultRealtimeDevices::usage =
  "SourceVaultRealtimeDevices[] は Python から見えるオーディオデバイスの一覧を返す (既定デバイスに \"DefaultInput\" / \"DefaultOutput\" が立つ)。";

SourceVaultRealtimeAudioCheck::usage =
  "SourceVaultRealtimeAudioCheck[] は音声会話が使う出力 (AI の声) と入力 (AI の耳) が本当につながっているかを確かめ、結果を Association で返す (Zoom のマイクテストに相当)。\n" <>
  "出力: 試験音 (ピッ 3 回) をワーカーと同じ方法で書き込み、書き込みが止まらないか (スタンバイ復帰後の固まり) を見る。出力が仮想ケーブル (\"CABLE Input\" など) なら反対側 (\"CABLE Output\" = Zoom のマイクにする側) で届いたかも録音して確かめる。\n" <>
  "入力: \"ListenSeconds\" 秒 (既定 8) 聞いて 100 ms ごとのレベルを測る。その間に Zoom の「スピーカーのテスト」を押すか、相手に話してもらう。\n" <>
  "デバイスは既定で次に始める音声会話と同じ (SetOptions[SourceVaultRealtimeStart, \"OutputDevice\" -> .., \"InputDevice\" -> ..] の値、無ければ Windows の既定)。音声会話が動いていれば、実際に使っているデバイスと mute も報告する。\n" <>
  "opts: \"OutputDevice\" / \"InputDevice\" (名前の一部), \"Tone\" (\"Beep\" 既定 / \"Quiet\" = -60 dBFS でほぼ聞こえない), \"Loopback\" (Automatic / None / 録音デバイス名), \"ListenSeconds\", \"Output\" / \"Input\" (False で省く), " <>
  "\"Speak\" (True = 動いている音声会話に短く話させ、ワーカーが再生したか・ケーブルの反対側に届いたかを確かめる。相手にも聞こえる), \"Audio\" (True = 聞いた音を \"Audio\" に入れる), \"Progress\" (FE でレベルを表示)。\n" <>
  "戻り値: \"Verdict\" (\"OK\" / \"Check\" / \"Problem\"), \"Findings\" (部分ごとの判定と日本語の説明), \"Output\", \"Input\", \"Session\", \"Speak\", \"Audio\"。表で見るには SourceVaultRealtimeAudioCheckView。";

SourceVaultRealtimeAudioCheckView::usage =
  "SourceVaultRealtimeAudioCheckView[] / SourceVaultRealtimeAudioCheckView[opts] は SourceVaultRealtimeAudioCheck[opts] を実行して、判定・説明・入力レベルの図・聞いた音を 1 枚にまとめて見せる。\n" <>
  "SourceVaultRealtimeAudioCheckView[result] は既にある結果を見せる。";

(* ---- 会話の開始 / 停止 ---- *)

SourceVaultRealtimeStart::usage =
  "SourceVaultRealtimeStart[] はこの機械の既定のマイクとスピーカーで音声会話 (既定 gpt-realtime、\"Model\" -> \"gpt-live-1\" で GPT-Live) を開始する (非ブロック)。\n" <>
  "経過はノートブックのウインドウステータスバーへ 1 行ずつ出る。宛先は \"Notebook\" (既定 Automatic = 評価中のノートブック)。\n" <>
  "そのノートブックが非公開 (Private) と宣言されていれば始めない (Failure[\"SourceVaultRealtimePrivateNotebook\"]。SourceVaultRealtimeRender も同じ)。\n" <>
  "主なオプション: \"Model\", \"API\" (既定 Automatic = モデルから決める), \"Voice\", \"Instructions\", \"InputDevice\", \"OutputDevice\", \"AllowBargeIn\" (既定 False = 応答中はマイクを送らない), \"StartMuted\" (接続だけ先にしてマイクは後から), \"TranscribeInput\" (既定 False = こちらの発話は文字にしない。GPT-Live は常に書き起こす), \"RequirePaidAPIApproval\" (既定 True), \"StatusBar\", \"PollSeconds\"。";

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
  "オプション: \"Heading\" (「スライド 3」など見出し), \"Instructions\" (この原稿だけへの追加指示), \"Slide\" (スライド番号。質疑でスライドが動いたら再開時に戻す),\n" <>
  "\"Interrupt\" (GPT-Live のみ。None = 割り込みなし (質問タイム)、\"Words\" = 許可ワード (\"InterruptWords\"、既定 $SourceVaultRealtimeInterruptWords) を含む発話でだけ中断して質疑、\"Detect\" = 別の声を検知したら中断し質問かどうかはモデルが判断)。\n" <>
  "中断中も NarrationDone は出ない (質疑が静かになったら中断した文から再開し、読み終えて出る)。\n" <>
  "\"RecordFile\" -> \"x.wav\" (ワーカー 1.13): その読み上げでスピーカーに流した音を 24 kHz の wav に書く。NarrationDone より先に書くので、NarrationDone を見たときにはファイルがある (GPT-Live のように実時間でしか話せないモデルで、動画用の音声を録るため)。";

SourceVaultRealtimeRender::usage =
  "SourceVaultRealtimeRender[jobs, opts] は原稿を Realtime API (gpt-realtime-*) の声で wav に書く。スピーカーには出さず、届いた音声をそのままファイルへ書くので実時間より速く、\"Parallel\" 本のセッションを並べて進める (1 原稿 1 セッション)。\n" <>
  "jobs は <|\"Id\" -> \"s3\", \"Text\" -> 原稿, \"File\" -> 出力 wav, \"Heading\" -> \"スライド 3\"|> のリスト。読ませ方の指示 (原稿だけを読む・前置きをしない) は SourceVaultRealtimeNarrate と同じ文面 (ワーカーから読み込む)。\n" <>
  "オプション: \"Model\" (既定 $SourceVaultRealtimeModel。GPT-Live のモデルは不可 = 実時間でしか話さないので SourceVaultRealtimeNarrate の \"RecordFile\" を使う), \"Voice\", \"Instructions\" (セッションの指示), \"NarrationInstructions\" (話し方の指示、声に出さない), \"Parallel\" (既定 3), \"Notebook\" / \"RequirePaidAPIApproval\" (SourceVaultRealtimeStart と同じ確認), \"Progress\" (関数。<|\"Done\", \"Failed\", \"Total\", \"Elapsed\"|> で呼ばれる), \"TimeConstraint\"。\n" <>
  "戻り値 <|\"Status\" -> \"OK\"|\"Partial\"|\"Failed\", \"Files\" -> <|id -> wav|>, \"Seconds\" -> <|id -> 長さ|>, \"Failed\" -> <|id -> 理由|>, \"Elapsed\"|>。";

$SourceVaultRealtimeInterruptWords::usage =
  "$SourceVaultRealtimeInterruptWords は発表中の割り込み (\"Interrupt\" -> \"Words\") を許す語 (既定 {\"質問\", \"スライド\"})。ローカルの Vosk (文法制限) で聞き取る。";

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

SourceVaultRealtimeAddContext::usage =
  "SourceVaultRealtimeAddContext[text] は質問に答えるときの背景 (発表全体の要約など) を音声会話に渡す (ワーカー 1.9 以降)。\n" <>
  "GPT-Live では 1 回に渡せる量に上限があるので、ワーカーが分けて順に渡す。読み上げ中に送ると読み上げが遅れるので、読み上げの無いときに使う。";

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
If[! ValueQ[SourceVault`$SourceVaultRealtimeKeepAliveLevel],
  SourceVault`$SourceVaultRealtimeKeepAliveLevel = -70.];
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
If[! ValueQ[SourceVault`$SourceVaultRealtimeModels],
  SourceVault`$SourceVaultRealtimeModels = <||>];
If[! ValueQ[SourceVault`$SourceVaultRealtimeInterruptWords],
  SourceVault`$SourceVaultRealtimeInterruptWords = {"質問", "スライド"}];

$iSVRTPackageDirectory = Quiet @ Check[DirectoryName[$InputFileName], ""];

(* 走っているワーカーが古い契約のままなら、黙って知らないコマンドを捨てるより
   入れ直したい。利用側 (SlideWorkflow) はこの値と Status の "WorkerVersion" を比べる。
   1.5 = GPT-Live (--api live)、1.6 = 発表中の割り込み (narrate の interrupt / slide)、
   1.7 = 原稿は先に文脈として渡してから読ませる / 答えはモデルが資料から組み立てる、
   1.11 = GPT-Live で原稿の代わりに「はい」と答えたら読み直しを頼む、
   1.12 = 話していない間も小さなノイズを流してスピーカーを休ませない (話し始めが欠ける対策)、
   1.13 = narrate の "record" (読み上げの音を wav に書く。GPT-Live で動画の音声を録る) *)
SourceVault`$SourceVaultRealtimeWorkerVersion = "1.13";

(* ---- 音声会話モデルの登録簿 ----
   組み込みは毎回ここで作り直す (再ロードで新しいモデルが見えるように)。
   利用者の追加/上書きは $SourceVaultRealtimeModels に置く *)
$iSVRTBuiltinModels = <|
  "gpt-realtime-2.1" -> <|"Provider" -> "OpenAI", "API" -> "Realtime",
    "Label" -> "realtime-2.1",
    "Description" -> "1 つのモデルが聞いて考えて話す。スライド操作と資料の問い合わせは関数呼び出し。"|>,
  "gpt-realtime-2.1-mini" -> <|"Provider" -> "OpenAI", "API" -> "Realtime",
    "Label" -> "rt-2.1-mini",
    "Description" -> "gpt-realtime-2.1 の軽量・低価格版。"|>,
  "gpt-live-1" -> <|"Provider" -> "OpenAI", "API" -> "Live",
    "Label" -> "live-1",
    "Description" -> "GPT-Live。全二重 (聞きながら話す)。作業はアプリ側へ委譲 (スライド操作 / SourceVault / 許可を得てウェブ)。音声 $0.05/分。"|>|>;

iSVRTModelRegistry[] := Join[$iSVRTBuiltinModels,
  If[AssociationQ[SourceVault`$SourceVaultRealtimeModels],
    Select[SourceVault`$SourceVaultRealtimeModels, AssociationQ], <||>]];

SourceVaultRealtimeModels[] := iSVRTModelRegistry[];

SourceVaultRealtimeModels["ByProvider"] :=
  GroupBy[Normal[iSVRTModelRegistry[]],
    (With[{p = Lookup[Last[#], "Provider", "OpenAI"]}, If[StringQ[p], p, "OpenAI"]] &) -> First];

SourceVaultRealtimeModels[provider_String] :=
  Lookup[SourceVaultRealtimeModels["ByProvider"], provider, {}];

SourceVaultRealtimeModelAPI[Automatic] :=
  SourceVaultRealtimeModelAPI[SourceVault`$SourceVaultRealtimeModel];

SourceVaultRealtimeModelAPI[model_String] := Module[{entry},
  entry = Lookup[iSVRTModelRegistry[], model, None];
  Which[
    AssociationQ[entry] && MemberQ[{"Realtime", "Live"}, Lookup[entry, "API", None]],
      entry["API"],
    StringStartsQ[ToLowerCase[StringTrim[model]], "gpt-live"], "Live",
    True, "Realtime"]];

SourceVaultRealtimeModelAPI[_] := "Realtime";

(* このファイルだけを読み直しても、動いている音声会話を見失わない (プロセス・状態ファイル・
   送り番号は前の値を保つ) *)
If[! ValueQ[$iSVRTProcess], $iSVRTProcess = None];
If[! ValueQ[$iSVRTStateFile], $iSVRTStateFile = None];
If[! ValueQ[$iSVRTControlFile], $iSVRTControlFile = None];
If[! ValueQ[$iSVRTNotebook], $iSVRTNotebook = None];
If[! ValueQ[$iSVRTPumpTask], $iSVRTPumpTask = None];
If[! ValueQ[$iSVRTLastSeq], $iSVRTLastSeq = -1];
If[! ValueQ[$iSVRTLastSlideRequest], $iSVRTLastSlideRequest = None];
If[! ValueQ[$iSVRTLastAskRequest], $iSVRTLastAskRequest = None];
If[! ValueQ[$iSVRTCommandCount], $iSVRTCommandCount = 0];
$iSVRTDepsOK = None;   (* セッションキャッシュ: 依存の確認は毎回プロセスを起こさない *)
$iSVRTVoskOK = None;   (* 同上: 発表中の割り込み (許可ワード) に使う vosk の有無 *)

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

(* vosk (任意): 許可ワードでの割り込みにだけ要る。無ければワーカーは「別の声の検知」
   だけで動く。確認は 1 度だけ (Install で無効化) *)
iSVRTVoskQ[exe_] := If[BooleanQ[$iSVRTVoskOK], $iSVRTVoskOK,
  With[{r = iSVRTRunPython[exe, {"-c", "import vosk; print('vosk-ok')"}, 60]},
    $iSVRTVoskOK = AssociationQ[r] && Lookup[r, "ExitCode", 1] === 0 &&
      StringContainsQ[Lookup[r, "StandardOutput", ""], "vosk-ok"];
    $iSVRTVoskOK]];

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
    (* 任意: 許可ワードでの割り込み。False なら SourceVaultRealtimeInstall["Vosk" -> True] *)
    "Vosk" -> If[StringQ[python] && TrueQ[deps], TrueQ[iSVRTVoskQ[python]], False],
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

Options[SourceVaultRealtimeInstall] = {"Force" -> False, "BasePython" -> Automatic,
  "Vosk" -> False};

SourceVaultRealtimeInstall[OptionsPattern[]] := Module[
  {force, base, venvPython, root, r, packages, vosk},
  force = TrueQ[OptionValue["Force"]];
  vosk = TrueQ[OptionValue["Vosk"]];
  $iSVRTDepsOK = None;
  $iSVRTVoskOK = None;
  venvPython = iSVRTVenvPython[];
  If[! force && iSVRTPythonWorksQ[venvPython] && iSVRTDepsQ[venvPython] &&
      (! vosk || TrueQ[iSVRTVoskQ[venvPython]]),
    Return[<|"Status" -> "OK", "Reason" -> "AlreadyInstalled",
      "Python" -> venvPython|>]];
  $iSVRTVoskOK = None;
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
  packages = Join[{"websocket-client", "sounddevice"}, If[vosk, {"vosk>=0.3.45"}, {}]];
  r = iSVRTRunPython[venvPython,
    Join[{"-m", "pip", "install", "--upgrade", "--disable-pip-version-check"}, packages], 600];
  If[! AssociationQ[r] || Lookup[r, "ExitCode", 1] =!= 0,
    Return[iSVRTFailure["SourceVaultRealtimePipFailed",
      "依存パッケージ (websocket-client / sounddevice) を導入できませんでした。",
      <|"Python" -> venvPython, "Result" -> r|>]]];
  $iSVRTDepsOK = None;
  $iSVRTVoskOK = None;
  If[! iSVRTDepsQ[venvPython],
    Return[iSVRTFailure["SourceVaultRealtimeDepsMissing",
      "導入後も websocket-client / sounddevice を読み込めません。",
      <|"Python" -> venvPython|>]]];
  If[vosk && ! TrueQ[iSVRTVoskQ[venvPython]],
    Return[iSVRTFailure["SourceVaultRealtimeDepsMissing",
      "導入後も vosk を読み込めません。", <|"Python" -> venvPython|>]]];
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

(* ---- 接続テスト (Zoom のマイクテストに相当) ----
   音を出すのも聞くのも外部の Python (SourceVault_realtime_audiocheck.py) で、デバイスの
   解決はワーカーと同じ関数・同じ 24 kHz / 20 ms。ここは結果を読んで説明を付けるだけ。
   2026-10-19: スタンバイ復帰後に本体スピーカーが書き込みを受け付けなくなり、ワーカーの
   再生が最初の 1 回で止まったまま無音だった。その固まりも「書き込みが終わらない」で分かる。 *)

If[! ValueQ[$iSVRTAudioCheckProgress], $iSVRTAudioCheckProgress = <||>];

iSVRTAudioCheckHelper[] := FileNameJoin[{DirectoryName[iSVRTWorkerPath[]],
  "SourceVault_realtime_audiocheck.py"}];

(* 仮想ケーブルの反対側 (Python の loopback_spec と同じ規則) と、出口から見た入口 *)
iSVRTLoopbackOf[name_String] := With[{m = StringCases[name,
    RegularExpression["(?i)^\\s*(CABLE(?:-[A-Z])?)\\s+In(?:put)?\\b"] :> "$1 Output", 1]},
  If[m === {}, None, First[m]]];
iSVRTLoopbackOf[_] := None;
iSVRTInletOf[name_String] := With[{m = StringCases[name,
    RegularExpression["(?i)^\\s*(CABLE(?:-[A-Z])?)\\s+Output\\b"] :> "$1 Input", 1]},
  If[m === {}, None, First[m]]];
iSVRTInletOf[_] := None;

(* Automatic = 次に始める音声会話が使うデバイス (SourceVaultRealtimeStart の既定値) *)
iSVRTAudioDeviceSpec[value_, key_String] := Module[{v = value},
  If[v === Automatic, v = OptionValue[SourceVaultRealtimeStart, key]];
  If[StringQ[v], StringTrim[v], ""]];

iSVRTReadJSONFile[path_String] := If[FileExistsQ[path],
  With[{v = Quiet @ Check[Import[path, "RawJSON"], None]}, If[AssociationQ[v], v, None]], None];

iSVRTWriteJSONFile[path_String, data_Association] := Quiet @ Check[
  Module[{strm = OpenWrite[path, BinaryFormat -> True]},
    If[Head[strm] === OutputStream,
      WithCleanup[BinaryWrite[strm, ExportByteArray[data, "RawJSON"]], Quiet @ Close[strm]]];
    path],
  $Failed];

(* 測っている間の表示 (FE のみ)。$iSVRTAudioCheckProgress は Python の進捗ファイルの写し *)
iSVRTAudioCheckBar[db_?NumericQ] := Graphics[{
    GrayLevel[0.88], Rectangle[{0, 0}, {1, 1}],
    Which[db > -6, RGBColor[0.85, 0.3, 0.2], db > -50, RGBColor[0.25, 0.65, 0.35], True, GrayLevel[0.6]],
    Rectangle[{0, 0}, {Clip[(db + 70.)/70., {0, 1}], 1}]},
  ImageSize -> {180, 12}, PlotRange -> {{0, 1}, {0, 1}}, PlotRangePadding -> 0];

iSVRTAudioCheckMeter[p_Association] := Module[
  {phase = Lookup[p, "phase", ""], levels = Lookup[p, "levels", {}], db, t},
  Switch[phase,
    "output", Row[{"AI の声を流しています: ", Lookup[p, "device", ""],
      If[StringQ[Lookup[p, "loopback", None]], " \[RightArrow] " <> p["loopback"] <> " で聞いています", ""]}],
    "input",
      db = If[MatchQ[levels, {__List}], N[levels[[-1, 3]]], -90.];
      t = If[MatchQ[levels, {__List}], levels[[-1, 1]], 0];
      Row[{"聞いています: ", Lookup[p, "device", ""], "   ", iSVRTAudioCheckBar[db], " ",
        ToString[Round[db]], " dBFS   ", ToString[t], " / ", ToString[Lookup[p, "seconds", "?"]], " 秒"}],
    "speak", Row[{"音声会話に話させています。", Lookup[p, "device", ""], " で聞いています"}],
    _, "準備しています\[Ellipsis]"]];
iSVRTAudioCheckMeter[_] := "準備しています\[Ellipsis]";

(* Python を 1 回走らせる。onStart はプロセスを起こした直後、onTick は待つ間 0.1 s ごと *)
iSVRTAudioCheckRun[python_String, helper_String, spec_Association, args_List,
    wantAudio_, progress_, timeout_?NumericQ, onStart_ : None, onTick_ : None] := Module[
  {tag = StringReplace[CreateUUID[], "-" -> ""], specFile, progFile, resFile, capFile,
   proc, deadline, p, res, audio = None, data, cleanup},
  {specFile, progFile, resFile, capFile} = FileNameJoin[{$TemporaryDirectory,
      "sourcevault-audiocheck-" <> # <> "-" <> tag}] & /@ {"spec.json", "progress.json", "result.json", "capture.wav"};
  cleanup := Quiet[If[FileExistsQ[#], DeleteFile[#]] & /@ {specFile, progFile, resFile, capFile,
    resFile <> ".tmp", progFile <> ".tmp"}];
  If[iSVRTWriteJSONFile[specFile, spec] === $Failed,
    Return[iSVRTFailure["SourceVaultRealtimeAudioCheckFailed", "試験の設定を書き出せませんでした。"]]];
  $iSVRTAudioCheckProgress = <|"phase" -> "starting"|>;
  If[progress =!= False && $Notebooks,
    PrintTemporary[Dynamic[iSVRTAudioCheckMeter[$iSVRTAudioCheckProgress],
      TrackedSymbols :> {$iSVRTAudioCheckProgress}]]];
  (* 環境は渡さない (SourceVaultRealtimeStart と同じ)。デバイス名は spec ファイルで渡す *)
  proc = Quiet @ Check[StartProcess[Join[{python, "-X", "utf8", helper,
      "--spec-file", specFile, "--progress-file", progFile, "--result-file", resFile},
      If[TrueQ[wantAudio], {"--capture-file", capFile}, {}], args]], $Failed];
  If[! MatchQ[proc, _ProcessObject],
    cleanup;
    Return[iSVRTFailure["SourceVaultRealtimeAudioCheckFailed", "試験用の Python を起動できませんでした。",
      <|"Python" -> python, "Helper" -> helper|>]]];
  If[onStart =!= None, onStart[]];
  deadline = AbsoluteTime[] + timeout;
  While[ProcessStatus[proc] === "Running" && AbsoluteTime[] < deadline,
    p = iSVRTReadJSONFile[progFile];
    If[AssociationQ[p], $iSVRTAudioCheckProgress = p];
    If[onTick =!= None, onTick[]];
    Pause[0.1]];
  If[ProcessStatus[proc] === "Running",
    Quiet[KillProcess[proc]]; cleanup;
    Return[iSVRTFailure["SourceVaultRealtimeAudioCheckTimeout",
      "試験が " <> ToString[Round[timeout]] <> " 秒で終わりませんでした。"]]];
  res = iSVRTReadJSONFile[resFile];
  If[! AssociationQ[res],
    res = Quiet @ Check[ImportByteArray[StringToByteArray[
      Replace[Quiet[ReadString[ProcessConnection[proc, "StandardOutput"], EndOfBuffer]], Except[_String] -> ""],
      "UTF-8"], "RawJSON"], None]];
  If[TrueQ[wantAudio] && FileExistsQ[capFile],
    data = Quiet @ Check[Import[capFile, "Data"], None];
    If[ArrayQ[data, _, NumericQ] && Length[Flatten[data]] > 0,
      audio = Quiet @ Check[Audio[Flatten[data], SampleRate -> Lookup[Replace[res, Except[_Association] -> <||>], "rate", 24000]], None]]];
  cleanup;
  If[! AssociationQ[res],
    Return[iSVRTFailure["SourceVaultRealtimeAudioCheckFailed", "試験の結果を読めませんでした。"]]];
  <|"Result" -> res, "Audio" -> audio|>];

iSVRTAudioCheckOutput[o_Association] := <|
  "Status" -> Lookup[o, "status", None],
  "Requested" -> Lookup[o, "requested", ""],
  "Device" -> Lookup[o, "device", None],
  "Loopback" -> Lookup[o, "loopback", None],
  "LoopbackStatus" -> Lookup[o, "loopbackStatus", None],
  "LatencyMilliseconds" -> Lookup[o, "latencyMs", None],
  "Tone" -> Lookup[o, "tone", None],
  "Seconds" -> Lookup[o, "seconds", None],
  "Elapsed" -> Lookup[o, "elapsed", None],
  "Pace" -> Lookup[o, "pace", None],
  "Error" -> FirstCase[Lookup[o, {"error", "writeError", "loopbackError"}, Null], _String, None]|>;
iSVRTAudioCheckOutput[_] := None;

iSVRTAudioCheckInput[i_Association] := <|
  "Status" -> Lookup[i, "status", None],
  "Requested" -> Lookup[i, "requested", ""],
  "Device" -> Lookup[i, "device", None],
  "Seconds" -> Lookup[i, "seconds", None],
  "Peak" -> Lookup[i, "peak", None],
  "PeakDB" -> Lookup[i, "peakDb", None],
  "Levels" -> Replace[Lookup[i, "levels", {}], Except[_List] -> {}],
  "Error" -> Replace[Lookup[i, "error", None], Except[_String] -> None]|>;
iSVRTAudioCheckInput[_] := None;

iSVRTAudioCheckSession[None, _, _] := <|"Running" -> False|>;
iSVRTAudioCheckSession[state_Association, outName_, inName_] := Module[
  {so = Lookup[state, "resolvedOutputDevice", None], si = Lookup[state, "resolvedInputDevice", None]},
  <|"Running" -> True,
    "Connected" -> TrueQ[Lookup[state, "connected", False]],
    "Model" -> Lookup[state, "model", None],
    "OutputDevice" -> so, "InputDevice" -> si,
    "Muted" -> TrueQ[Lookup[state, "muted", False]],
    "OutputChunks" -> Lookup[state, "outputChunks", None],
    (* 名前はワーカーと同じ関数で作っているので、同じデバイスなら同じ文字列 *)
    "OutputMatches" -> (! StringQ[outName] || ! StringQ[so] || so === outName),
    "InputMatches" -> (! StringQ[inName] || ! StringQ[si] || si === inName)|>];

(* 動いている音声会話に短く話させる。ワーカーが再生したか (speaking / outputChunks)、
   出口が仮想ケーブルなら反対側に声が出たか *)
iSVRTAudioCheckSpeak[python_String, helper_String, state_Association, progress_] := Module[
  {lb, chunks0, maxChunks, spoke = False, said = False, r, heard = None, tick, say},
  lb = iSVRTLoopbackOf[Lookup[state, "resolvedOutputDevice", None]];
  chunks0 = Replace[Lookup[state, "outputChunks", 0], Except[_Integer] -> 0];
  maxChunks = chunks0;
  tick := With[{st = iSVRTReadState[]},
    If[TrueQ[Lookup[st, "speaking", False]], spoke = True];
    maxChunks = Max[maxChunks, Replace[Lookup[st, "outputChunks", 0], Except[_Integer] -> 0]]];
  say := (Pause[0.8]; said = ! FailureQ[Quiet[SourceVaultRealtimeSay[
      "接続のテストです。「こちらは音声のテストです。聞こえていますか。」とだけ、声に出して言ってください。"]]]);
  If[StringQ[lb],
    r = iSVRTAudioCheckRun[python, helper, <|"inputDevice" -> lb|>,
      {"--skip-output", "--listen-seconds", "10"}, False, progress, 30, say & , tick &];
    If[FailureQ[r], Return[<|"Status" -> "Error", "Loopback" -> lb, "Failure" -> r|>]];
    heard = Lookup[Lookup[r["Result"], "input", <||>], "status", None] === "Signal",
    say; Do[tick; Pause[0.1], {100}]];
  If[spoke || maxChunks > chunks0, Null, tick];
  <|"Status" -> Which[! said, "NotSent", ! (spoke || maxChunks > chunks0), "Silent",
      heard === False, "NotHeard", True, "OK"],
    "Spoke" -> (spoke || maxChunks > chunks0),
    "OutputChunks" -> {chunks0, maxChunks},
    "Loopback" -> lb, "Heard" -> heard|>];

iSVRTAudioCheckFindings[out_, in_, session_Association, speak_] := Module[{f = {}, add, name},
  (* 「…」の前後の空白は詰める (コードの読みやすさのために空白を入れて連結している) *)
  add[part_, level_, msg_] := AppendTo[f, <|"Part" -> part, "Level" -> level,
    "Message" -> StringReplace[msg, {" \:300c" -> "\:300c", "\:300d " -> "\:300d"}]|>];
  (* MME の名前は 31 文字で切れる ("CABLE-B Output (VB-Audio Virtua")。仮想ケーブルは Zoom の
     一覧と照らせる短い名前 ("CABLE-B Output") で言う *)
  name[x_] := Which[
    ! StringQ[x] || x === "", "(既定のデバイス)",
    StringStartsQ[x, "CABLE", IgnoreCase -> True], "\:300c" <> StringTrim[First[StringSplit[x, " ("]]] <> "\:300d",
    True, "\:300c" <> x <> "\:300d"];
  If[AssociationQ[out],
    With[{dev = name[out["Device"]], lb = name[out["Loopback"]]},
      Switch[out["Status"],
        "NotFound", add["Output", "Problem", "出力デバイス" <> name[out["Requested"]] <>
          " が見つかりません。SourceVaultRealtimeDevices[] で名前を確かめてください。"],
        "Error", add["Output", "Problem", "出力 " <> dev <> " を開けません: " <> ToString[out["Error"]]],
        "Stalled", add["Output", "Problem", "出力 " <> dev <> " が音を受け取りません (書き込みが終わりません)。" <>
          "スタンバイ復帰のあとに起きることがあります。デバイスマネージャで無効→有効にするか、Windows Audio を再起動するか、" <>
          "PC を再起動してから、音声会話を入れ直してください (応答off→on)。"],
        "Unpaced", add["Output", "Problem", "出力 " <> dev <> " が音を実時間で流していません (" <>
          ToString[out["Seconds"]] <> " 秒分が " <> ToString[out["Elapsed"]] <> " 秒で入りました)。鳴っていない疑いがあります。"],
        "Played", Switch[out["LoopbackStatus"],
          "Arrived", add["Output", "OK", "AI の声は " <> dev <> " から " <> lb <> " まで届いています" <>
            If[NumericQ[out["LatencyMilliseconds"]], " (遅れ 約 " <> ToString[out["LatencyMilliseconds"]] <> " ms)", ""] <>
            "。Zoom のマイクを " <> lb <> " にすれば相手に聞こえます。"],
          "Silent" | "OtherSound", add["Output", "Problem", dev <> " に流した試験音が " <> lb <> " に出てきません。"],
          "Error", add["Output", "Check", "書き込みは正常でしたが、反対側 " <> lb <> " を録音できませんでした: " <> ToString[out["Error"]]],
          _, add["Output", "Check", If[out["Tone"] === "quiet",
            "出力 " <> dev <> " への書き込みは正常に進みました (小さな試験音なので耳では確かめられません)。",
            "出力 " <> dev <> " で試験音 (ピッ 3 回) を鳴らしました。聞こえたかを耳で確かめてください (このデバイスは録音して確かめられません)。"]]],
        _, add["Output", "Problem", "出力の試験が終わりませんでした。"]]]];
  If[AssociationQ[in],
    With[{dev = name[in["Device"]], inlet = iSVRTInletOf[in["Device"]]},
      Switch[in["Status"],
        "Signal", add["Input", "OK", "AI の耳 " <> dev <> " に音が来ています (最大 " <> ToString[in["PeakDB"]] <> " dBFS)。"],
        "Quiet", add["Input", "Check", dev <> " は動いていますが、聞こえたのは小さな雑音だけでした。" <>
          "テスト中に Zoom の「スピーカーのテスト」を押すか、相手に話してもらってください。"],
        "Zeros", add["Input", "Check", dev <> " には何も流れてきませんでした (デジタル無音)。" <>
          If[StringQ[inlet], "Zoom のスピーカーを\:300c" <> inlet <> "\:300dにして、", ""] <>
          "テスト中に Zoom の「スピーカーのテスト」を押すか、相手に話してもらってください。"],
        "NotFound", add["Input", "Problem", "入力デバイス" <> name[in["Requested"]] <>
          " が見つかりません。SourceVaultRealtimeDevices[] で名前を確かめてください。"],
        "Stalled", add["Input", "Problem", "入力 " <> dev <> " から音が読めません (録音が止まりました)。"],
        _, add["Input", "Problem", "入力 " <> dev <> " を開けません: " <> ToString[in["Error"]]]]]];
  If[TrueQ[session["Running"]],
    If[! session["Connected"], add["Session", "Problem", "音声会話はサーバーにつながっていません。"]];
    If[! session["OutputMatches"], add["Session", "Problem", "動いている音声会話は出力 " <> name[session["OutputDevice"]] <>
      " を使っています (確かめたのは " <> name[Lookup[Replace[out, Except[_Association] -> <||>], "Device", None]] <> ")。応答off→on で入れ直すと新しい設定になります。"]];
    If[! session["InputMatches"], add["Session", "Problem", "動いている音声会話は入力 " <> name[session["InputDevice"]] <>
      " を使っています (確かめたのは " <> name[Lookup[Replace[in, Except[_Association] -> <||>], "Device", None]] <> ")。応答off→on で入れ直すと新しい設定になります。"]];
    If[session["Muted"], add["Session", "Check", "音声会話のマイクはいま閉じています (mute)。質問を聞かせるときは開けてください。"]];
    If[session["Connected"] && session["OutputMatches"] && session["InputMatches"] && ! session["Muted"],
      add["Session", "OK", "音声会話は同じデバイスで動いています (" <> ToString[session["Model"]] <> ")。"]],
    add["Session", "Info", "音声会話は止まっています。応答on にすると、ここで確かめたデバイスで始まります。"]];
  If[AssociationQ[speak],
    Switch[speak["Status"],
      "OK", add["Speak", "OK", If[StringQ[speak["Loopback"]],
        "音声会話が話した声が\:300c" <> speak["Loopback"] <> "\:300dまで届きました。", "音声会話が話しました (ワーカーの再生は動いています)。"]],
      "NotHeard", add["Speak", "Problem", "ワーカーは話しましたが、声が\:300c" <> speak["Loopback"] <> "\:300dに出てきません。"],
      "Silent", add["Speak", "Problem", "音声会話に話させましたが、ワーカーが音を再生しませんでした (再生が止まっている疑い)。応答off→on で入れ直してください。"],
      "NoSession", add["Speak", "Info", "音声会話が動いていないので、話させる試験はしませんでした。"],
      _, add["Speak", "Problem", "音声会話に話させる依頼を送れませんでした。"]]];
  f];

Options[SourceVaultRealtimeAudioCheck] = {
  "OutputDevice" -> Automatic, "InputDevice" -> Automatic,
  "Tone" -> "Beep", "Loopback" -> Automatic, "ListenSeconds" -> 8,
  "Output" -> True, "Input" -> True, "Speak" -> False,
  "Audio" -> True, "Progress" -> Automatic};

SourceVaultRealtimeAudioCheck[OptionsPattern[]] := Module[
  {runtime, helper, outSpec, inSpec, tone, loop, listen, doOut, doIn, state, run = None,
   res = <||>, out, in, session, speak = None, findings, levels},
  runtime = SourceVaultRealtimeRuntime[];
  If[runtime["Status"] =!= "OK",
    Return[iSVRTFailure["SourceVaultRealtimeUnavailable",
      "音声会話ワーカーの Python を実行できません。", <|"Hint" -> runtime["Hint"]|>]]];
  helper = iSVRTAudioCheckHelper[];
  If[! FileExistsQ[helper],
    Return[iSVRTFailure["SourceVaultRealtimeAudioCheckFailed",
      "SourceVault_realtime_audiocheck.py が見つかりません。", <|"Helper" -> helper|>]]];
  outSpec = iSVRTAudioDeviceSpec[OptionValue["OutputDevice"], "OutputDevice"];
  inSpec = iSVRTAudioDeviceSpec[OptionValue["InputDevice"], "InputDevice"];
  tone = If[ToLowerCase[ToString[OptionValue["Tone"]]] === "quiet", "quiet", "beep"];
  loop = Replace[OptionValue["Loopback"], {Automatic -> "auto", None -> "none",
    s_String :> s, _ -> "auto"}];
  listen = N[Clip[Replace[OptionValue["ListenSeconds"], Except[_?NumericQ] -> 8], {1, 60}]];
  doOut = TrueQ[OptionValue["Output"]];
  doIn = TrueQ[OptionValue["Input"]];
  state = If[iSVRTRunningQ[], iSVRTReadState[], None];
  If[doOut || doIn,
    run = iSVRTAudioCheckRun[runtime["Python"], helper,
      <|"outputDevice" -> outSpec, "inputDevice" -> inSpec, "loopback" -> loop|>,
      Join[{"--tone", tone, "--listen-seconds", ToString[listen]},
        If[doOut, {}, {"--skip-output"}], If[doIn, {}, {"--skip-input"}]],
      TrueQ[OptionValue["Audio"]] && doIn, OptionValue["Progress"],
      listen + If[doOut, 10, 0] + 25];
    If[FailureQ[run], Return[run]];
    res = run["Result"]];
  out = iSVRTAudioCheckOutput[Lookup[res, "output", None]];
  in = iSVRTAudioCheckInput[Lookup[res, "input", None]];
  session = iSVRTAudioCheckSession[state,
    If[AssociationQ[out], out["Device"], None], If[AssociationQ[in], in["Device"], None]];
  If[TrueQ[OptionValue["Speak"]],
    speak = If[AssociationQ[state] && iSVRTRunningQ[],
      iSVRTAudioCheckSpeak[runtime["Python"], helper, state, OptionValue["Progress"]],
      <|"Status" -> "NoSession"|>]];
  findings = iSVRTAudioCheckFindings[out, in, session, speak];
  <|"Verdict" -> Which[
      MemberQ[Lookup[findings, "Level"], "Problem"], "Problem",
      MemberQ[Lookup[findings, "Level"], "Check"], "Check",
      True, "OK"],
    "Findings" -> findings,
    "Output" -> out, "Input" -> in, "Session" -> session, "Speak" -> speak,
    "Audio" -> If[AssociationQ[run], run["Audio"], None],
    "Error" -> Lookup[res, "error", None],
    "Date" -> DateString[{"Year", "-", "Month", "-", "Day", " ", "Hour", ":", "Minute", ":", "Second"}]|>];

(* ---- View ---- *)

$iSVRTAudioCheckParts = <|"Output" -> "AI の声 (出力)", "Input" -> "AI の耳 (入力)",
  "Session" -> "音声会話", "Speak" -> "話させた声"|>;

iSVRTAudioCheckMark[level_] := Switch[level,
  "OK", Style["\[Checkmark]", Bold, RGBColor[0.15, 0.55, 0.25]],
  "Check", Style["\[WarningSign]", Bold, RGBColor[0.85, 0.55, 0.1]],
  "Problem", Style["\[Times]", Bold, RGBColor[0.8, 0.2, 0.15]],
  _, Style["\[CenterDot]", GrayLevel[0.5]]];

SourceVaultRealtimeAudioCheckView[r_Association] := Module[{levels, verdict = Lookup[r, "Verdict", "?"]},
  levels = Lookup[Replace[Lookup[r, "Input", None], Except[_Association] -> <||>], "Levels", {}];
  Panel[Column[DeleteCases[{
      Row[{Style["接続テスト  ", Bold, 14],
        Style[Switch[verdict, "OK", "つながっています", "Check", "確かめてください", "Problem", "問題があります", _, verdict],
          Bold, 14, Switch[verdict, "OK", RGBColor[0.15, 0.55, 0.25], "Check", RGBColor[0.85, 0.55, 0.1],
            _, RGBColor[0.8, 0.2, 0.15]]],
        Style["   " <> ToString[Lookup[r, "Date", ""]], GrayLevel[0.5], 10]}],
      Grid[{iSVRTAudioCheckMark[#Level], Style[Lookup[$iSVRTAudioCheckParts, #Part, #Part], GrayLevel[0.35]],
          Pane[#Message, ImageSize -> {560, Automatic}]} & /@ Lookup[r, "Findings", {}],
        Alignment -> {Left, Top}, Spacings -> {1, 0.6}],
      If[MatchQ[levels, {{_?NumericQ, _?NumericQ, _?NumericQ} ..}],
        ListLinePlot[levels[[All, {1, 3}]], PlotRange -> {All, {-80, 0}}, Filling -> Bottom,
          GridLines -> {None, {-50}}, AxesLabel -> {"秒", "dBFS"}, ImageSize -> 460, AspectRatio -> 0.22,
          PlotLabel -> "AI の耳のレベル (100 ms ごとの RMS、-50 dBFS より上を音とみなす)"],
        Nothing],
      If[Head[Lookup[r, "Audio", None]] === Audio, Row[{"聞いた音: ", r["Audio"]}], Nothing]},
    Nothing], Spacings -> 1]]];
SourceVaultRealtimeAudioCheckView[f_Failure] := f;
SourceVaultRealtimeAudioCheckView[opts___Rule] :=
  SourceVaultRealtimeAudioCheckView[SourceVaultRealtimeAudioCheck[opts]];

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
(* 診断用の記録 (SlideWorkflow の $SlideTrace と同じファイル)。FE を使わない *)
iSVRTTrace[tag_String] := If[TrueQ[SourceVault`$SourceVaultRealtimeTrace], Quiet @ Check[
  Module[{strm = OpenAppend[FileNameJoin[{$TemporaryDirectory, "slideworkflow-trace.log"}], CharacterEncoding -> "UTF-8"]},
    If[Head[strm] === OutputStream,
      WriteString[strm, DateString[{"Hour", ":", "Minute", ":", "Second", ".", "Millisecond"}] <> " SV:" <> tag <> "\n"];
      Close[strm]]], Null]];

iSVRTSetStatusBar[line_] := Module[{nbs},
  If[Head[$iSVRTNotebook] =!= NotebookObject, Return[Null]];
  iSVRTTrace["StatusBar Notebooks >"];
  nbs = Quiet[Notebooks[]];
  iSVRTTrace["StatusBar Notebooks <"];
  If[ListQ[nbs] && ! MemberQ[nbs, $iSVRTNotebook], Return[Null]];
  Quiet[CurrentValue[$iSVRTNotebook, WindowStatusArea] = line];
  iSVRTTrace["StatusBar set <"];
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
  (* 呼び出し側 (SlideWorkflow のボタン) が FE とやり取りしている間はこの回を飛ばす。
     割り込みから FE を呼ぶと互いの返事を待ち合って止まる (2026-09-28) *)
  If[TrueQ[SourceVault`$SourceVaultRealtimeHoldFE], Return[Null]];
  iSVRTTrace["Pump >"];
  state = iSVRTReadState[];
  seq = Lookup[state, "statusSeq", None];
  If[NumericQ[seq] && seq =!= $iSVRTLastSeq,
    $iSVRTLastSeq = seq;
    line = Lookup[state, "statusLine", ""];
    If[StringQ[line], iSVRTSetStatusBar[line]]];
  iSVRTDispatchSlideRequest[state];
  iSVRTDispatchAskRequest[state];
  If[! iSVRTRunningQ[], iSVRTPumpStop[]];
  iSVRTTrace["Pump <"];
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
  (* 受け口が後から SourceVaultRealtimeAskResult で答える (非同期の LLM など) *)
  If[res === "Deferred", Return[Null]];
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

(* 非公開 (Private) 宣言のノートのための会話・読み上げはクラウド (OpenAI) で行わない (rule 61、2026-10-31)。
   有料 API の許可と同じく、"Notebook" のノートを単位に判断する。判定は NBAccess (Private = 1.0)。
   NBAccess が答えられないときも断る (fail-closed)。ノートが無ければ判断しない (None) *)
iSVRTPrivateNotebookFailure[nb_NotebookObject] :=
  If[TrueQ[Quiet @ Check[NBAccess`NBNotebookRequiredAccessLevel[nb], 1.0] < 0.5], None,
    iSVRTFailure["SourceVaultRealtimePrivateNotebook",
      "このノートブックは非公開 (Private) と宣言されているので、クラウドの音声 (OpenAI) へは送りません。"]];
iSVRTPrivateNotebookFailure[_] := None;

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
  "API" -> Automatic,
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
  (* GPT-Live の発表中の割り込み: 自分の声 (エコー) より何倍大きければ人の声か /
     "Detect" で質疑を開くまでの連続発話 / 人の声と数える最小の音量 / 質疑が
     静かになってから発表に戻るまで *)
  "InterruptMargin" -> 2.0,
  "InterruptMilliseconds" -> 350,
  "InterruptFloor" -> 0.03,
  "ResumeQuietSeconds" -> 4,
  (* 1.12: 話していない間もスピーカーへ流す聞こえないノイズ (dBFS。Automatic = $SourceVaultRealtimeKeepAliveLevel、
     None = 流さない) と、しばらく鳴っていなかったあとの話し始めの前に置く助走。どちらも話し始めが欠けるのを防ぐ *)
  "KeepAliveLevel" -> Automatic,
  "LeadInMilliseconds" -> 100,
  "Python" -> Automatic};

SourceVaultRealtimeStart[OptionsPattern[]] := Module[
  {runtime, python, worker, nb, apiKey, model, api, voice, instructions,
   inputDevice, outputDevice, stateFile, controlFile, command,
   process, deadline, state, workerError, instructionsFile},

  If[iSVRTRunningQ[],
    Return[iSVRTFailure["SourceVaultRealtimeAlreadyRunning",
      "音声会話は既に動いています (SourceVaultRealtimeStop[] で終了)。",
      <|"Status" -> SourceVaultRealtimeStatus[]|>]]];

  iSVRTTrace["Start runtime >"];
  runtime = SourceVaultRealtimeRuntime[];
  python = iSVRTResolvePython[OptionValue["Python"]];
  iSVRTTrace["Start runtime <"];
  If[! StringQ[python] || runtime["Status"] =!= "OK",
    Return[iSVRTFailure["SourceVaultRealtimeUnavailable",
      "音声会話ワーカーを実行できません。",
      <|"Hint" -> runtime["Hint"], "Runtime" -> runtime|>]]];
  worker = runtime["Worker"];

  If[! TrueQ[iSVRTEnsureNBAccess[]],
    Return[iSVRTFailure["SourceVaultRealtimeNBAccessUnavailable",
      "NBAccess.wl を読み込めません (API キーの取得に必要)。"]]];

  iSVRTTrace["Start nbaccess <"];
  nb = iSVRTResolveNotebook[OptionValue["Notebook"]];
  If[TrueQ[OptionValue["RequirePaidAPIApproval"]],
    If[! MatchQ[nb, _NotebookObject],
      Return[iSVRTFailure["SourceVaultRealtimeNotebookRequired",
        "Paid API の承認確認にはノートブックが要ります (\"Notebook\" を指定するか \"RequirePaidAPIApproval\" -> False)。"]]];
    If[! TrueQ @ Quiet @ NBAccess`NBGetNotebookPaidAPIAllowed[nb],
      Return[iSVRTFailure["SourceVaultRealtimePaidAPINotAllowed",
        "このノートブックは有料 API を許可していません。NBAccess`NBSetNotebookPaidAPIAllowed[nb, True] で許可してください。"]]]];

  With[{f = iSVRTPrivateNotebookFailure[nb]}, If[FailureQ[f], Return[f]]];

  (* クラウド経路のプロバイダゲート: SourceVault のプライバシー契約と同じ入口 *)
  If[! TrueQ @ Quiet @ NBAccess`NBProviderCanAccess["openai", 0.5],
    Return[iSVRTFailure["SourceVaultRealtimeOpenAIDisabled",
      "NBAccess のプロバイダ方針が現在 OpenAI へのアクセスを認めていません。"]]];

  apiKey = Quiet @ NBAccess`NBGetAPIKey["openai",
    NBAccess`PrivacySpec -> <|"AccessLevel" -> 1.0|>];
  If[! StringQ[apiKey] || StringLength[apiKey] === 0,
    Return[iSVRTFailure["SourceVaultRealtimeAPIKeyMissing",
      "OPENAI_API_KEY を NBAccess / SystemCredential から取得できませんでした。"]]];

  iSVRTTrace["Start key <"];
  model = Replace[OptionValue["Model"], Automatic :> SourceVault`$SourceVaultRealtimeModel];
  If[! StringQ[model] || StringTrim[model] === "", model = "gpt-realtime-2.1"];
  (* どちらの API で話すか: 明示が無ければモデルから (gpt-live-* = Live) *)
  api = Replace[OptionValue["API"], Automatic :> SourceVaultRealtimeModelAPI[model]];
  If[! MemberQ[{"Realtime", "Live"}, api], api = SourceVaultRealtimeModelAPI[model]];
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
     "--api", ToLowerCase[api],
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
     "--bargein-margin", iSVRTNumberString[OptionValue["InterruptMargin"]],
     "--bargein-ms", ToString[Round[OptionValue["InterruptMilliseconds"]]],
     "--bargein-floor", iSVRTNumberString[OptionValue["InterruptFloor"]],
     "--resume-quiet-ms", ToString[Round[1000 OptionValue["ResumeQuietSeconds"]]],
     "--lead-in-ms", ToString[Max[0, Round[Replace[OptionValue["LeadInMilliseconds"], Except[_?NumericQ] -> 0]]]],
     "--instructions-file", instructionsFile, "--api-key-stdin"},
    With[{level = Replace[OptionValue["KeepAliveLevel"], Automatic :> SourceVault`$SourceVaultRealtimeKeepAliveLevel]},
      If[NumericQ[level], {"--keepalive-db", iSVRTNumberString[N[level]]}, {"--no-keepalive"}]],
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
  iSVRTTrace["Start process >"];
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
  iSVRTTrace["Start waited <"];
  (* Module を挟まずに書くのは、Return が最内 Module から返ってしまい
     失敗しても後続が走ってしまうため (VRCRealtime で踏んだ形) *)
  If[ProcessStatus[process] =!= "Running" ||
      (AssociationQ[state] && Lookup[state, "status", ""] === "error"),
    (* 溜まっている分だけ読む (EndOfBuffer)。status が error でもワーカーは後片付け
       (音声デバイス・WebSocket) の間は生きていて、素の ReadString は標準エラーの終わり
       (= 終了) を待つのでカーネルがそこで止まる。止めた後は接続が消えて読めない *)
    workerError = Quiet @ Check[
      ReadString[ProcessConnection[process, "StandardError"], EndOfBuffer], ""];
    Quiet[KillProcess[process]];
    $iSVRTProcess = None;
    Return[iSVRTFailure["SourceVaultRealtimeWorkerDied",
      "ワーカーが起動直後に終了しました。",
      <|"Reason" -> Lookup[state, "lastError", None],
        "StandardError" -> If[StringQ[workerError],
          StringTake[workerError, UpTo[2000]], ""]|>]]];

  If[TrueQ[OptionValue["StatusBar"]], iSVRTPumpStart[OptionValue["PollSeconds"]]];

  <|"Status" -> "Started", "Model" -> model, "API" -> api, "Voice" -> voice,
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
    (* 1.4 以前のワーカーは api を書かない = Realtime *)
    "API" -> Replace[Lookup[state, "api", None],
      {"live" -> "Live", "realtime" -> "Realtime", None -> If[state === <||>, None, "Realtime"]}],
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
    "LastRecording" -> Lookup[state, "lastRecording", None],
    "LastUserText" -> Lookup[state, "lastUserText", ""],
    "LastAssistantText" -> Lookup[state, "lastAssistantText", ""],
    "LastError" -> Lookup[state, "lastError", None],
    "Reconnects" -> Lookup[state, "reconnects", 0],
    (* GPT-Live だけが書く: セッション ID / 累計の音声秒数 (課金の元) / 委譲の回数と直近 *)
    "SessionId" -> Lookup[state, "sessionId", None],
    "UsageSeconds" -> Lookup[state, "usageSeconds", None],
    "Delegations" -> Lookup[state, "delegations", None],
    "LastDelegation" -> Lookup[state, "lastDelegation", None],
    "CloseReason" -> Lookup[state, "closeReason", None],
    (* 発表中の割り込み (GPT-Live): 指定されたモード / 実際に効いている門
       ("words" でも Vosk が無ければ "detect") / 質疑中か / 発表を中断中か *)
    "InterruptMode" -> Lookup[state, "interruptMode", None],
    "InterruptGate" -> Lookup[state, "interruptGate", None],
    "QAOpen" -> TrueQ[Lookup[state, "qaOpen", False]],
    "Interrupted" -> TrueQ[Lookup[state, "interrupted", False]],
    "Interruptions" -> Lookup[state, "interruptions", None],
    "LastInterrupt" -> Lookup[state, "lastInterrupt", None],
    "KeywordStatus" -> Lookup[state, "keywordStatus", None],
    "EchoCoupling" -> Lookup[state, "echoCoupling", None],
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

(* 質問に答えるときの背景 (発表全体など)。GPT-Live は上限ごとに分けて順に渡す *)
SourceVaultRealtimeAddContext[text_String] :=
  iSVRTSend[<|"command" -> "context", "text" -> text|>];

SourceVaultRealtimeSetVerbosity[level_] := (
  SourceVault`$SourceVaultRealtimeVerbosity = level;
  iSVRTSend[<|"command" -> "verbosity",
    "value" -> iSVRTVerbosityString[level]|>]);

SourceVaultRealtimeLine[text_String] :=
  iSVRTSend[<|"command" -> "line", "text" -> text|>];

Options[SourceVaultRealtimeNarrate] = {"Heading" -> "", "Instructions" -> "",
  "Slide" -> None, "Interrupt" -> None, "InterruptWords" -> Automatic,
  "SpeechModel" -> Automatic, "RecordFile" -> None};

(* 許可ワードの聞き取りに使う Vosk モデルのディレクトリ (SourceVault_voice の資産)。
   見つからなければ "" = ワーカーは別の声の検知だけで判断する *)
iSVRTSpeechModelDirectory[Automatic] := Module[{m},
  If[Length[DownValues[SourceVault`SourceVaultSpeechModel]] === 0, Return[""]];
  m = Quiet @ Check[SourceVault`SourceVaultSpeechModel[], $Failed];
  If[AssociationQ[m] && StringQ[Lookup[m, "Directory", None]], m["Directory"], ""]];
iSVRTSpeechModelDirectory[dir_String] := dir;
iSVRTSpeechModelDirectory[_] := "";

iSVRTInterruptMode[None | False | "None" | "QuestionTime"] := "none";
iSVRTInterruptMode[s_String] := Switch[ToLowerCase[s],
  "words" | "keyword" | "keywords", "words",
  "detect" | "always" | "voice", "detect",
  _, "none"];
iSVRTInterruptMode[_] := "none";

SourceVaultRealtimeNarrate[id_, text_String, OptionsPattern[]] := Module[
  {mode, words, slide},
  mode = iSVRTInterruptMode[OptionValue["Interrupt"]];
  words = Replace[OptionValue["InterruptWords"],
    Automatic :> SourceVault`$SourceVaultRealtimeInterruptWords];
  words = Select[Flatten[{words}], StringQ[#] && StringTrim[#] =!= "" &];
  slide = OptionValue["Slide"];
  iSVRTSend[Join[
    <|"command" -> "narrate", "id" -> ToString[id], "text" -> text,
      "heading" -> ToString[OptionValue["Heading"]],
      "instructions" -> ToString[OptionValue["Instructions"]],
      "interrupt" -> mode|>,
    If[IntegerQ[slide] && slide > 0, <|"slide" -> slide|>, <||>],
    (* 1.13: この読み上げの音を wav に残す (NarrationDone より先に書かれる) *)
    With[{rec = OptionValue["RecordFile"]},
      If[StringQ[rec] && StringTrim[rec] =!= "", <|"record" -> ExpandFileName[rec]|>, <||>]],
    If[mode === "words",
      <|"interruptWords" -> words,
        "speechModel" -> iSVRTSpeechModelDirectory[OptionValue["SpeechModel"]]|>,
      <||>]]]];

SourceVaultRealtimeCancel[] := iSVRTSend[<|"command" -> "cancel"|>];

Options[SourceVaultRealtimeEndTalk] = {"QuietSeconds" -> 4.};

SourceVaultRealtimeEndTalk[OptionsPattern[]] :=
  iSVRTSend[<|"command" -> "endtalk",
    "quietSeconds" -> N[OptionValue["QuietSeconds"]]|>];

(* ---- 原稿を wav に書く (再生しない。動画用) ----
   会話のワーカーは原稿をスピーカーで鳴らすので、発表の長さだけ時間がかかる。動画を作るのに
   スピーカーは要らない: 届いた音声をそのままファイルへ書けば実時間より速い (Realtime API は
   生成した分から送ってくる)。1 原稿 1 セッション (前の枚の音声を会話に持ち越すと、以後の枚で
   毎回入力として課金される) を "Parallel" 本並べる。読ませ方の文面はワーカーから読み込む
   (SourceVault_realtime_render.py)。GPT-Live はセッションの時間が入力フレームで進むので
   速くならない: そちらは SourceVaultRealtimeNarrate の "RecordFile" で再生しながら録る。 *)

iSVRTRenderScriptPath[] := FileNameJoin[{$iSVRTPackageDirectory, "SourceVault_info", "resources",
  "python", "SourceVault_realtime_render.py"}];

(* 結果ファイルはスクリプトが原子的に置き換える。読む瞬間に無ければ <||> *)
iSVRTReadJSONFile[path_String] := Module[{bytes, value},
  If[! FileExistsQ[path], Return[<||>]];
  bytes = Quiet @ Check[ReadByteArray[path], $Failed];
  If[! ByteArrayQ[bytes], Return[<||>]];
  value = Quiet @ Check[ImportByteArray[bytes, "RawJSON"], <||>];
  If[AssociationQ[value], value, <||>]];

iSVRTWriteJSONFile[path_String, value_] := Module[{bytes, strm},
  bytes = Quiet @ Check[ExportByteArray[value, "RawJSON", "Compact" -> True], $Failed];
  If[! ByteArrayQ[bytes], Return[$Failed]];
  strm = Quiet @ OpenWrite[path, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  WithCleanup[BinaryWrite[strm, bytes], Quiet @ Close[strm]];
  path];

Options[SourceVaultRealtimeRender] = {
  "Model" -> Automatic, "Voice" -> Automatic, "Instructions" -> Automatic,
  "NarrationInstructions" -> "", "Parallel" -> 3,
  "Notebook" -> Automatic, "RequirePaidAPIApproval" -> True,
  "Python" -> Automatic, "Progress" -> None, "TimeConstraint" -> Automatic,
  "PollSeconds" -> 0.5};

SourceVaultRealtimeRender[jobsIn_List, OptionsPattern[]] := Module[
  {jobs, model, api, voice, instructions, python, script, nb, apiKey, tag, jobsFile, resultFile,
   config, process, started, limit, poll, progress, last = None, result, done, failed, total,
   files, seconds, errors, stderr},
  jobs = Select[jobsIn, AssociationQ[#] && StringQ[Lookup[#, "Text", None]] &&
      StringTrim[#["Text"]] =!= "" && StringQ[Lookup[#, "File", None]] &];
  If[jobs === {},
    Return[<|"Status" -> "OK", "Files" -> <||>, "Seconds" -> <||>, "Failed" -> <||>, "Elapsed" -> 0.|>]];
  model = Replace[OptionValue["Model"], Automatic :> SourceVault`$SourceVaultRealtimeModel];
  If[! StringQ[model] || StringTrim[model] === "", model = "gpt-realtime-2.1"];
  api = SourceVaultRealtimeModelAPI[model];
  If[api =!= "Realtime",
    Return[iSVRTFailure["SourceVaultRealtimeRenderLive",
      "GPT-Live (" <> model <> ") は実時間でしか話さないので wav へ速く書けません。SourceVaultRealtimeNarrate の \"RecordFile\" で再生しながら録ってください。",
      <|"Model" -> model|>]]];
  voice = Replace[OptionValue["Voice"], Automatic :> SourceVault`$SourceVaultRealtimeVoice];
  instructions = Replace[OptionValue["Instructions"], Automatic :> SourceVault`$SourceVaultRealtimeInstructions];
  python = iSVRTResolvePython[OptionValue["Python"]];
  script = iSVRTRenderScriptPath[];
  If[! StringQ[python] || ! FileExistsQ[script],
    Return[iSVRTFailure["SourceVaultRealtimeUnavailable",
      "音声を書く Python 環境かスクリプトがありません。",
      <|"Hint" -> If[StringQ[python], "見つかりません: " <> script, iSVRTInstallHint[]]|>]]];
  If[! TrueQ[iSVRTEnsureNBAccess[]],
    Return[iSVRTFailure["SourceVaultRealtimeNBAccessUnavailable",
      "NBAccess.wl を読み込めません (API キーの取得に必要)。"]]];
  (* 確認は SourceVaultRealtimeStart と同じ: ノートブックの有料 API 許可・プロバイダ方針・キー *)
  nb = iSVRTResolveNotebook[OptionValue["Notebook"]];
  If[TrueQ[OptionValue["RequirePaidAPIApproval"]],
    If[! MatchQ[nb, _NotebookObject],
      Return[iSVRTFailure["SourceVaultRealtimeNotebookRequired",
        "Paid API の承認確認にはノートブックが要ります (\"Notebook\" を指定するか \"RequirePaidAPIApproval\" -> False)。"]]];
    If[! TrueQ @ Quiet @ NBAccess`NBGetNotebookPaidAPIAllowed[nb],
      Return[iSVRTFailure["SourceVaultRealtimePaidAPINotAllowed",
        "このノートブックは有料 API を許可していません。NBAccess`NBSetNotebookPaidAPIAllowed[nb, True] で許可してください。"]]]];
  With[{f = iSVRTPrivateNotebookFailure[nb]}, If[FailureQ[f], Return[f]]];
  If[! TrueQ @ Quiet @ NBAccess`NBProviderCanAccess["openai", 0.5],
    Return[iSVRTFailure["SourceVaultRealtimeOpenAIDisabled",
      "NBAccess のプロバイダ方針が現在 OpenAI へのアクセスを認めていません。"]]];

  tag = StringReplace[CreateUUID[], "-" -> ""];
  jobsFile = FileNameJoin[{$TemporaryDirectory, "sourcevault-render-jobs-" <> tag <> ".json"}];
  resultFile = FileNameJoin[{$TemporaryDirectory, "sourcevault-render-result-" <> tag <> ".json"}];
  config = <|"model" -> model, "voice" -> ToString[voice], "instructions" -> ToString[instructions],
    "narrationInstructions" -> ToString[OptionValue["NarrationInstructions"]],
    "parallel" -> Replace[OptionValue["Parallel"], Except[_Integer?Positive] -> 3],
    "jobs" -> Map[<|"id" -> ToString[Lookup[#, "Id", ""]], "heading" -> ToString[Lookup[#, "Heading", ""]],
        "text" -> #["Text"], "out" -> ExpandFileName[#["File"]]|> &, jobs]|>;
  If[iSVRTWriteJSONFile[jobsFile, config] === $Failed,
    Return[iSVRTFailure["SourceVaultRealtimeRenderIO", "原稿の受け渡しファイルを書けませんでした。"]]];

  apiKey = Quiet @ NBAccess`NBGetAPIKey["openai", NBAccess`PrivacySpec -> <|"AccessLevel" -> 1.0|>];
  If[! StringQ[apiKey] || StringLength[apiKey] === 0,
    apiKey =.;
    Quiet[DeleteFile[jobsFile]];
    Return[iSVRTFailure["SourceVaultRealtimeAPIKeyMissing",
      "OPENAI_API_KEY を NBAccess / SystemCredential から取得できませんでした。"]]];
  (* 環境は渡さない ($Language が Japanese だと落ちる)。キーは標準入力から 1 行だけ *)
  process = Quiet @ Check[StartProcess[{python, "-X", "utf8", script,
      "--jobs", jobsFile, "--result", resultFile, "--api-key-stdin"}], $Failed];
  If[MatchQ[process, _ProcessObject], Quiet @ Check[WriteLine[process, apiKey], Null]];
  apiKey =.;
  If[! MatchQ[process, _ProcessObject],
    Quiet[DeleteFile[jobsFile]];
    Return[iSVRTFailure["SourceVaultRealtimeStartFailed", "音声を書くプロセスを起動できませんでした。"]]];

  total = Length[jobs];
  started = AbsoluteTime[];
  limit = Replace[OptionValue["TimeConstraint"], Automatic :>
    120. + Total[StringLength[#["Text"]] & /@ jobs]/2.];
  poll = Replace[OptionValue["PollSeconds"], Except[_?NumericQ] -> 0.5];
  progress = OptionValue["Progress"];
  While[ProcessStatus[process] === "Running" && AbsoluteTime[] - started < limit,
    Pause[poll];
    result = iSVRTReadJSONFile[resultFile];
    If[progress =!= None && AssociationQ[result] && KeyExistsQ[result, "done"],
      With[{p = <|"Done" -> result["done"], "Failed" -> Lookup[result, "failed", 0], "Total" -> total,
          "Elapsed" -> Round[AbsoluteTime[] - started, 0.1]|>},
        If[KeyDrop[p, "Elapsed"] =!= last, last = KeyDrop[p, "Elapsed"]; Quiet[progress[p]]]]]];
  If[ProcessStatus[process] === "Running", Quiet[KillProcess[process]]];
  stderr = Quiet @ Check[ReadString[ProcessConnection[process, "StandardError"], EndOfBuffer], ""];
  result = iSVRTReadJSONFile[resultFile];
  Quiet[DeleteFile[jobsFile]];
  Quiet[DeleteFile[resultFile]];
  If[! AssociationQ[result] || ! AssociationQ[Lookup[result, "jobs", None]],
    Return[iSVRTFailure["SourceVaultRealtimeRenderFailed", "音声を書くプロセスが結果を残しませんでした。",
      <|"StandardError" -> If[StringQ[stderr], StringTake[stderr, UpTo[2000]], ""]|>]]];
  files = Association @ KeyValueMap[If[Lookup[#2, "status", ""] === "done" && StringQ[Lookup[#2, "file", None]] &&
      FileExistsQ[#2["file"]], #1 -> #2["file"], Nothing] &, result["jobs"]];
  seconds = Association @ KeyValueMap[If[KeyExistsQ[files, #1], #1 -> N[Lookup[#2, "seconds", 0]], Nothing] &, result["jobs"]];
  errors = Association @ KeyValueMap[If[KeyExistsQ[files, #1], Nothing,
      #1 -> ToString[Lookup[#2, "error", Lookup[#2, "status", "unfinished"]]]] &, result["jobs"]];
  done = Length[files]; failed = Length[errors];
  <|"Status" -> Which[failed === 0, "OK", done > 0, "Partial", True, "Failed"],
    "Files" -> files, "Seconds" -> seconds, "Failed" -> errors,
    "Fatal" -> Lookup[result, "fatal", None], "Model" -> model, "Voice" -> voice,
    "Elapsed" -> Round[AbsoluteTime[] - started, 0.1],
    "TimedOut" -> (AbsoluteTime[] - started >= limit)|>];

(* privacy contracts for functions added after the module's initial review (model:
   iSVMDRegisterPrivacyContracts in SourceVault_maildb.wl). No-op without the privacy layer. *)
iSVRTRegisterPrivacyContracts[] :=
  Quiet @ Check[
    If[Length[DownValues[SourceVault`SourceVaultRegisterPrivacyContract]] > 0,
      Scan[SourceVault`SourceVaultRegisterPrivacyContract[First[#],
          <|"Class" -> "Internal", "Module" -> "SourceVault_realtime.wl", "NoDataFlow" -> Last[#]|>] &,
        {{"SourceVaultRealtimeAddContext", "Forwards caller-supplied text to the running voice session and returns the worker's acknowledgement; reads no store."},
         {"SourceVaultRealtimeRender", "Renders caller-supplied scripts to wav files; returns file paths, durations and status; reads no store."},
         {"SourceVaultRealtimeAudioCheck", "Device check: test tone and live input levels; the optional Audio is a fresh capture the caller asked for, not stored data."},
         {"SourceVaultRealtimeAudioCheckView", "Displays an SourceVaultRealtimeAudioCheck result (same data)."}}];
      Scan[SourceVault`SourceVaultRegisterPrivacyContract[First[#],
          <|"Class" -> "Public", "Module" -> "SourceVault_realtime.wl", "NoDataFlow" -> Last[#]|>] &,
        {{"SourceVaultRealtimeModels", "Static model registry."},
         {"SourceVaultRealtimeModelAPI", "Model name -> API kind lookup."},
         {"$SourceVaultRealtimeModels", "Setting (user-added model entries)."},
         {"$SourceVaultRealtimeInterruptWords", "Setting (word list)."},
         {"$SourceVaultRealtimeKeepAliveLevel", "Setting (dBFS)."}}]];
    Null, Null];
iSVRTRegisterPrivacyContracts[];

End[];

EndPackage[];
