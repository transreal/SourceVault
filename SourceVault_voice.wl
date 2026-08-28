(* ::Package:: *)

(* ============================================================
   SourceVault_voice.wl -- local (credential-free) voice assets layer
     Piper Plus TTS runtime / voice models, AivisSpeech Engine (HTTP),
     Vosk ASR models

   This file is encoded in UTF-8.
   Load order: SourceVault.wl -> SourceVault_core.wl -> SourceVault_voice.wl
   Load via:   Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_voice.wl"]]

   == なぜ SourceVault 管轄か ==
     ローカル TTS は SourceVault の Privacy.Level 契約の実装部品である。
     PL >= 0.5 の資料は OpenAI などの外部エンドポイントへ渡さず、この
     ローカル音声合成だけで読み上げる。ポリシー (privacy) を持つ層と
     その実行部品を同じリポジトリに置く。ASR (Vosk) も同じ理由で
     「音声が機械の外へ出ない」ことが要件なのでここに同居する。

   == このファイルが実装する範囲 ==
     - 音声資産 root の解決 (複数 root を横断走査、書き込み先は 1 つ)。
     - Piper Plus ランタイム (piper 実行ファイル) の探索と状態報告。
     - AivisSpeech Engine (Style-Bert-VITS2 系、VOICEVOX 互換 HTTP API) の
       探索・自動起動・話者列挙。合成先は localhost のみ (音声もテキストも
       機械の外へ出ない。エンジン自体のモデル更新確認だけは AivisHub へ出る)。
     - 声モデルの列挙・選択。config.json / <model>.onnx.json を実際に読み、
       language / sample_rate / speaker 数 / 推論既定値を声ごとに返す。
       AivisSpeech の話者も同じ形の Association に正規化して同じ一覧に出す。
       ★ 特定の声 (tsukuyomi 等) をハードコードしない。既定の声の永続化は
         <root>/local/voice_config.json (リポジトリ非同梱) に置く。
     - Vosk ASR モデルの列挙・選択・ダウンロード導入。
     - SourceVaultVoiceStatus[] : 何が欠けていて、どう入れるかを返す。
       セットアップ文書・診断・呼び出し側のエラーメッセージの単一の情報源。
     - SourceVaultVoiceSpeak[] : WL から 1 発でローカル合成する薄い口。

   == このファイルが実装しない範囲 ==
     - 会話パイプライン (VAD / barge-in / privacy scrub / 読み上げ打ち切り)。
       それは利用側 (VRCRealtime の private TTS broker) が持つ。ここは
       「どの実行ファイルとどの声を使うか」の解決層に閉じる。

   == 資産の置き場と配布 ==
     $packageDirectory/SourceVault_voice/
       tts/runtime/  Piper Plus ランタイム  ... リポジトリ非同梱 (excludePatterns)
       tts/models/   声モデル               ... リポジトリ非同梱 (excludePatterns)
       asr/          Vosk モデル            ... リポジトリ非同梱 (excludePatterns)
     いずれも第三者の配布物で、ライセンスが利用者ごとに異なる。README と
     sources.json だけを同梱し、実体は各自が入れる (この層が導入を助ける)。
   ============================================================ *)

BeginPackage["SourceVault`"];

(* ---- 設定 ---- *)

$SourceVaultVoiceRoot::usage =
  "$SourceVaultVoiceRoot はローカル音声資産 (TTS ランタイム / 声モデル / ASR モデル) の root ディレクトリ override。\n" <>
  "既定 None のときは SourceVaultVoiceSearchPath[] の順に探す。";

$SourceVaultVoiceDefault::usage =
  "$SourceVaultVoiceDefault は SourceVaultVoice[] が返す既定の声の名前 (声モデルのフォルダ名またはファイル名)。\n" <>
  "既定 Automatic のときは導入済みの声を名前順に並べた先頭を使う (決定論的)。";

$SourceVaultVoiceSpeechModelDefault::usage =
  "$SourceVaultVoiceSpeechModelDefault は SourceVaultSpeechModel[] が返す既定の ASR モデル名。既定 Automatic。";

$SourceVaultVoiceAivisEndpoint::usage =
  "$SourceVaultVoiceAivisEndpoint は AivisSpeech Engine の HTTP エンドポイント。既定 \"http://127.0.0.1:10101\"。";

$SourceVaultVoiceAivisExecutable::usage =
  "$SourceVaultVoiceAivisExecutable は AivisSpeech Engine の実行ファイル (run.exe) の解決方法。\n" <>
  "Automatic (既定) = 環境変数 SOURCEVAULT_AIVIS_ENGINE と標準の導入先を探す。パス文字列 = そのファイルだけを使う。None = エンジンを使わない。";

$SourceVaultVoiceAivisAutoStart::usage =
  "$SourceVaultVoiceAivisAutoStart が True (既定) のとき、AivisSpeech の声が必要なのにエンジンが未起動なら\n" <>
  "SourceVaultVoiceSpeak が一度だけ自動起動を試みる (localhost エンドポイントのときのみ)。";

$SourceVaultVoiceAivisStartTimeout::usage =
  "$SourceVaultVoiceAivisStartTimeout は AivisSpeech Engine の自動起動後に応答を待つ秒数 (既定 180)。\n" <>
  "初回起動はモデルの読み込みで 1〜2 分かかることがある (実測 90 秒超)。";

$SourceVaultVoiceSpeechModelCatalog::usage =
  "$SourceVaultVoiceSpeechModelCatalog は SourceVaultInstallSpeechModel が導入できる ASR モデルの一覧 (言語コード -> <|\"Name\", \"URL\", \"ApproxMB\", \"License\"|>)。";

(* ---- root / 探索 ---- *)

SourceVaultVoiceRoot::usage =
  "SourceVaultVoiceRoot[] は音声資産の書き込み先 root を返す (存在しなければ作らずにパスだけ返す)。";

SourceVaultVoiceSearchPath::usage =
  "SourceVaultVoiceSearchPath[] は音声資産を探す root の一覧を優先順に返す。";

(* ---- TTS ---- *)

SourceVaultVoiceRuntime::usage =
  "SourceVaultVoiceRuntime[] はローカル音声合成ランタイム (Piper Plus) の状態を Association で返す。\n" <>
  "\"Status\" が \"OK\" のとき \"Executable\" に実行ファイルの絶対パスが入る。";

SourceVaultVoices::usage =
  "SourceVaultVoices[] は導入済みの声モデルを Association のリストで返す (名前順)。\n" <>
  "各要素: \"Name\", \"Engine\", \"Model\" (.onnx), \"Config\" (.json), \"Language\", \"SampleRate\", \"Speakers\", \"NoiseScale\", \"LengthScale\", \"NoiseW\", \"Multilingual\", \"Root\"。\n" <>
  "特定の声を前提にしない: フォルダ名がそのまま声の名前になり、パラメータは各声の config から読む。";

SourceVaultVoice::usage =
  "SourceVaultVoice[] は既定の声を Association で返す。SourceVaultVoice[name] は名前で選ぶ。\n" <>
  "導入済みの声が無ければ Failure[\"SourceVaultVoiceUnavailable\", ...] を返す (\"Hint\" に導入手順)。";

SourceVaultVoiceAvailableQ::usage =
  "SourceVaultVoiceAvailableQ[] はローカル音声合成が使える状態なら True を返す\n" <>
  "(Piper のランタイム+声、または AivisSpeech Engine のどちらかがあればよい)。";

SourceVaultVoiceAivisStatus::usage =
  "SourceVaultVoiceAivisStatus[] は AivisSpeech Engine の状態を Association で返す。\n" <>
  "\"Status\" は \"Running\" (稼働中) | \"Installed\" (導入済・未起動) | \"Missing\"。稼働中は \"Version\" と \"Voices\" (話者名) も入る。";

SourceVaultVoiceAivisEnsure::usage =
  "SourceVaultVoiceAivisEnsure[] は AivisSpeech Engine が応答することを確かめて True | False を返す。\n" <>
  "未起動なら一度だけ自動起動を試みる (最大 90 秒待つ)。VRCRealtime など外部の利用側が合成前に呼ぶための口。";

SourceVaultVoiceSetDefault::usage =
  "SourceVaultVoiceSetDefault[name] は既定の声を <root>/local/voice_config.json に永続化する (再起動後も有効)。\n" <>
  "name は SourceVaultVoices[] の \"Name\" (前方一致でもよい)。$SourceVaultVoiceDefault を設定するとそちらが優先される。";

SourceVaultVoiceDefaultName::usage =
  "SourceVaultVoiceDefaultName[] は設定されている既定の声の名前を返す ($SourceVaultVoiceDefault > voice_config.json)。\n" <>
  "どちらも未設定なら None。声の実体が今あるかどうかは調べない (解決は SourceVaultVoice[] が行う)。";

SourceVaultVoiceStatus::usage =
  "SourceVaultVoiceStatus[] はローカル音声資産の総合状態を返す。\n" <>
  "\"Status\" (\"OK\"|\"Incomplete\"), \"Missing\" (欠けている物), \"Hint\" (導入手順), \"Runtime\", \"Voices\", \"SpeechModels\"。";

SourceVaultVoiceView::usage =
  "SourceVaultVoiceView[] は SourceVaultVoiceStatus[] を Dataset / Grid で表示する。";

SourceVaultVoiceInstallHint::usage =
  "SourceVaultVoiceInstallHint[] は不足している音声資産の導入手順を複数行の文字列で返す。";

SourceVaultVoiceSpeak::usage =
  "SourceVaultVoiceSpeak[text] はローカルの音声合成 (Piper または AivisSpeech) で text を合成し Audio を返す (音声もテキストも機械の外へ出ない)。\n" <>
  "SourceVaultVoiceSpeak[text, \"Voice\" -> name, \"OutputFile\" -> path] で声と出力先を指定できる。\n" <>
  "AivisSpeech の声には \"Style\" -> スタイル名 (前方一致可) で感情スタイルを指定できる。";

(* ---- ASR ---- *)

SourceVaultSpeechModels::usage =
  "SourceVaultSpeechModels[] は導入済みのローカル音声認識 (Vosk) モデルを Association のリストで返す。";

SourceVaultSpeechModel::usage =
  "SourceVaultSpeechModel[] は既定の ASR モデルを Association で返す。SourceVaultSpeechModel[name] は名前で選ぶ。\n" <>
  "未導入なら Failure[\"SourceVaultSpeechModelUnavailable\", ...] を返す。";

SourceVaultSpeechModelDirectory::usage =
  "SourceVaultSpeechModelDirectory[] は ASR モデルの導入先ディレクトリを返す。";

SourceVaultInstallSpeechModel::usage =
  "SourceVaultInstallSpeechModel[] は日本語小モデル (vosk-model-small-ja-0.22、約 50 MB) をダウンロードして導入する。\n" <>
  "SourceVaultInstallSpeechModel[\"en\"] のように $SourceVaultVoiceSpeechModelCatalog の言語コードを指定できる。\n" <>
  "導入済みなら何もしない (冪等)。";

Begin["`Private`"];

(* ============================================================
   設定既定値 (再ロードで利用者の設定を潰さない)
   ============================================================ *)

If[! ValueQ[SourceVault`$SourceVaultVoiceRoot],
  SourceVault`$SourceVaultVoiceRoot = None];
If[! ValueQ[SourceVault`$SourceVaultVoiceDefault],
  SourceVault`$SourceVaultVoiceDefault = Automatic];
If[! ValueQ[SourceVault`$SourceVaultVoiceSpeechModelDefault],
  SourceVault`$SourceVaultVoiceSpeechModelDefault = Automatic];
If[! ValueQ[SourceVault`$SourceVaultVoiceAivisEndpoint],
  SourceVault`$SourceVaultVoiceAivisEndpoint = "http://127.0.0.1:10101"];
If[! ValueQ[SourceVault`$SourceVaultVoiceAivisExecutable],
  SourceVault`$SourceVaultVoiceAivisExecutable = Automatic];
If[! ValueQ[SourceVault`$SourceVaultVoiceAivisAutoStart],
  SourceVault`$SourceVaultVoiceAivisAutoStart = True];
If[! ValueQ[SourceVault`$SourceVaultVoiceAivisStartTimeout],
  SourceVault`$SourceVaultVoiceAivisStartTimeout = 180.];

SourceVault`$SourceVaultVoiceSpeechModelCatalog = <|
  "ja" -> <|
    "Name" -> "vosk-model-small-ja-0.22",
    "URL" -> "https://alphacephei.com/vosk/models/vosk-model-small-ja-0.22.zip",
    "ApproxMB" -> 48,
    "License" -> "Apache-2.0"|>,
  "en" -> <|
    "Name" -> "vosk-model-small-en-us-0.15",
    "URL" -> "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip",
    "ApproxMB" -> 40,
    "License" -> "Apache-2.0"|>
|>;

$iVoiceEngine = "PiperPlus";
$iVoiceAivisEngine = "AivisSpeech";

(* 自動起動 (StartProcess) は 1 カーネルにつき 1 回だけ。ただし起動した
   プロセスが生きて立ち上がり途中なら、以後の呼び出しは新プロセスを起こさずに
   応答を待ち直す (初回起動はモデル読込で 90 秒を超えることがある実測)。 *)
$iVoiceAivisStartTried = False;
$iVoiceAivisProcess = None;
$iVoiceAivisSpeakersCache = <|"Time" -> -1., "Endpoint" -> "", "Value" -> {}|>;

(* ============================================================
   小道具
   ============================================================ *)

iVoiceFailure[tag_String, message_String, extra_ : <||>] :=
  Failure[tag, Join[<|"MessageTemplate" -> message|>, extra]];

iVoiceStringQ[x_] := StringQ[x] && StringLength[x] > 0;

iVoiceEnv[name_String] := Module[{v},
  v = Quiet @ Check[Environment[name], $Failed];
  If[iVoiceStringQ[v], v, ""]];

iVoiceDir[path_] := iVoiceStringQ[path] && Quiet @ Check[DirectoryQ[path], False];

iVoiceFile[path_] := iVoiceStringQ[path] && Quiet @ Check[FileExistsQ[path], False];

(* パッケージディレクトリ: Global`$packageDirectory が正 (init.m が設定)。
   未設定の環境 (素の wolframscript など) ではこのファイルの位置から引く。 *)
iVoicePackageDirectory[] := Module[{d},
  d = Quiet @ Check[Global`$packageDirectory, ""];
  If[iVoiceDir[d], Return[d]];
  d = Quiet @ Check[DirectoryName[$InputFileName], ""];
  If[iVoiceDir[d], d, ""]];

iVoiceLocalAppData[] := Module[{b},
  b = iVoiceEnv["LOCALAPPDATA"];
  If[iVoiceStringQ[b], Return[b]];
  b = Quiet @ Check[$HomeDirectory, ""];
  If[iVoiceStringQ[b], FileNameJoin[{b, ".local", "share"}], ""]];

(* JSON を byte 経由で読む。ImportString は日本語を含む JSON で
   二重 encode になりうるので、必ず ByteArray から parse する。 *)
iVoiceReadJSON[path_String] := Module[{ba, res},
  If[! iVoiceFile[path], Return[$Failed]];
  ba = Quiet @ Check[ReadByteArray[path], $Failed];
  If[! ByteArrayQ[ba], Return[$Failed]];
  res = Quiet @ Check[ImportByteArray[ba, "RawJSON"], $Failed];
  If[AssociationQ[res], res, $Failed]];

iVoiceNumber[assoc_, keys_List, default_] := Module[{v = assoc},
  Do[
    If[! AssociationQ[v], Return[default, Module]];
    v = Lookup[v, k, Missing["kv"]],
    {k, keys}];
  If[NumericQ[v], N[v], default]];

iVoiceString[assoc_, keys_List, default_] := Module[{v = assoc},
  Do[
    If[! AssociationQ[v], Return[default, Module]];
    v = Lookup[v, k, Missing["kv"]],
    {k, keys}];
  If[iVoiceStringQ[v], v, default]];

(* ============================================================
   root 解決
   ============================================================ *)

SourceVaultVoiceSearchPath[] := Module[{roots, pkg, lad},
  roots = {};
  If[iVoiceStringQ[SourceVault`$SourceVaultVoiceRoot],
    AppendTo[roots, SourceVault`$SourceVaultVoiceRoot]];
  With[{e = iVoiceEnv["SOURCEVAULT_VOICE_ROOT"]},
    If[iVoiceStringQ[e], AppendTo[roots, e]]];
  pkg = iVoicePackageDirectory[];
  If[iVoiceStringQ[pkg],
    AppendTo[roots, FileNameJoin[{pkg, "SourceVault_voice"}]]];
  lad = iVoiceLocalAppData[];
  If[iVoiceStringQ[lad],
    AppendTo[roots, FileNameJoin[{lad, "SourceVault", "voice"}]];
    (* 旧 VRCRealtime 配下に入れてしまった ASR モデルも読める (後方互換)。
       新規の書き込みはここには行わない。 *)
    AppendTo[roots, FileNameJoin[{lad, "VRCRealtime"}]]];
  DeleteDuplicates[Select[roots, iVoiceStringQ]]];

SourceVaultVoiceRoot[] := Module[{paths, existing},
  paths = SourceVaultVoiceSearchPath[];
  If[paths === {}, Return[""]];
  existing = Select[paths, iVoiceDir];
  If[existing =!= {}, First[existing], First[paths]]];

(* 書き込み先: 明示 override > env > $packageDirectory/SourceVault_voice。
   LOCALAPPDATA の後方互換 root は書き込み先にしない。 *)
iVoiceWritableRoot[] := Module[{paths},
  paths = SourceVaultVoiceSearchPath[];
  paths = Select[paths, ! StringEndsQ[#, "VRCRealtime"] &];
  If[paths === {}, "", First[paths]]];

(* ============================================================
   TTS ランタイム (Piper Plus)
   ============================================================ *)

iVoiceRuntimeCandidates[] := Module[{names, out = {}},
  names = If[$OperatingSystem === "Windows", {"piper.exe"}, {"piper"}];
  Do[
    Do[
      AppendTo[out, FileNameJoin[{root, "tts", "runtime", "piper", "bin", n}]];
      AppendTo[out, FileNameJoin[{root, "tts", "runtime", "piper", n}]],
      {n, names}],
    {root, SourceVaultVoiceSearchPath[]}];
  (* 資産 root に無ければ PATH 上の piper を使う (自前導入した利用者向け) *)
  Do[
    With[{p = iVoiceEnv["PATH"]},
      If[iVoiceStringQ[p],
        Do[AppendTo[out, FileNameJoin[{d, n}]],
          {d, Select[StringSplit[p, If[$OperatingSystem === "Windows", ";", ":"]], iVoiceStringQ]}]]],
    {n, names}];
  DeleteDuplicates[out]];

SourceVaultVoiceRuntime[] := Module[{hit},
  hit = SelectFirst[iVoiceRuntimeCandidates[], iVoiceFile, None];
  If[hit === None,
    <|"Status" -> "Missing",
      "Engine" -> $iVoiceEngine,
      "Executable" -> None,
      "Root" -> SourceVaultVoiceRoot[],
      "Hint" -> iVoiceRuntimeHint[]|>,
    <|"Status" -> "OK",
      "Engine" -> $iVoiceEngine,
      "Executable" -> hit,
      "Root" -> SourceVaultVoiceRoot[],
      "Hint" -> None|>]];

iVoiceRuntimeHint[] :=
  "ローカル音声合成ランタイム (Piper) が見つかりません。\n" <>
  "  " <> FileNameJoin[{iVoiceWritableRoot[], "tts", "runtime", "piper"}] <> "\n" <>
  "の下に piper の bin/ share/ lib/ を配置するか、piper を PATH に通してください。\n" <>
  "手順は SourceVault_voice/tts/README.md にあります。";

(* ============================================================
   TTS エンジン 2: AivisSpeech Engine (VOICEVOX 互換 HTTP API)
     Style-Bert-VITS2 系の高品質日本語合成。合成要求は localhost の
     エンジンに閉じる (音声もテキストも機械の外へ出ない)。エンジン
     自体は起動時にモデル更新確認のため AivisHub へアクセスする。
     話者 (声) はエンジン側の Models/ ディレクトリで管理され、この層は
     /speakers で列挙して Piper の声と同じ形に正規化する。
   ============================================================ *)

iVoiceAivisEndpoint[] := With[{e = SourceVault`$SourceVaultVoiceAivisEndpoint},
  If[iVoiceStringQ[e], StringTrim[e, "/"], "http://127.0.0.1:10101"]];

iVoiceAivisLocalQ[] :=
  StringContainsQ[iVoiceAivisEndpoint[], "127.0.0.1" | "localhost"];

iVoiceAivisPort[] := With[{p = Quiet @ Check[URLParse[iVoiceAivisEndpoint[], "Port"], None]},
  If[IntegerQ[p], p, 10101]];

iVoiceAivisExecutable[] := Module[{o, cands = {}, lad},
  o = SourceVault`$SourceVaultVoiceAivisExecutable;
  If[o === None, Return[None]];
  If[iVoiceStringQ[o], Return[If[iVoiceFile[o], o, None]]];
  With[{e = iVoiceEnv["SOURCEVAULT_AIVIS_ENGINE"]},
    If[iVoiceStringQ[e], AppendTo[cands, e]]];
  If[$OperatingSystem === "Windows",
    lad = iVoiceLocalAppData[];
    If[iVoiceStringQ[lad],
      (* 単体配布の AivisSpeech-Engine (GitHub Releases の 7z を展開した形) *)
      AppendTo[cands, FileNameJoin[{lad, "Programs", "AivisSpeech-Engine", "Windows-x64", "run.exe"}]];
      (* デスクトップアプリ AivisSpeech に同梱されるエンジン *)
      AppendTo[cands, FileNameJoin[{lad, "Programs", "AivisSpeech", "AivisSpeech-Engine", "run.exe"}]]];
    AppendTo[cands, "C:\\Program Files\\AivisSpeech\\AivisSpeech-Engine\\run.exe"]];
  SelectFirst[cands, iVoiceFile, None]];

iVoiceAivisVersion[] := Module[{r},
  r = Quiet @ Check[TimeConstrained[
    URLRead[HTTPRequest[iVoiceAivisEndpoint[] <> "/version", <|"Method" -> "GET"|>],
      {"StatusCode", "Body"}], 3, $Failed], $Failed];
  If[AssociationQ[r] && r["StatusCode"] === 200,
    StringTrim[StringTrim[r["Body"]], "\""], $Failed]];

iVoiceAivisRunningQ[] := StringQ[iVoiceAivisVersion[]];

iVoiceAivisStartTimeout[] := With[{t = SourceVault`$SourceVaultVoiceAivisStartTimeout},
  If[NumericQ[t] && t > 0, N[t], 180.]];

(* 応答が返るまで待つ (deadline 秒)。返ったら話者キャッシュを捨てて True *)
iVoiceAivisAwait[seconds_] := Module[{},
  With[{deadline = AbsoluteTime[] + seconds},
    While[! iVoiceAivisRunningQ[] && AbsoluteTime[] < deadline, Pause[1.]]];
  If[iVoiceAivisRunningQ[],
    $iVoiceAivisSpeakersCache = <|"Time" -> -1., "Endpoint" -> "", "Value" -> {}|>;
    True,
    False]];

(* エンジンが未起動なら一度だけ起動を試み、応答するまで待つ
   ($SourceVaultVoiceAivisStartTimeout 秒、既定 180)。すでに起動を試みて
   プロセスが生きている (= 立ち上がり途中の) 場合は、新しいプロセスを
   起こさずに待ち直す。起動できた/すでに動いていたら True。 *)
iVoiceAivisEnsure[] := Module[{exe},
  If[iVoiceAivisRunningQ[], Return[True]];
  If[! TrueQ[SourceVault`$SourceVaultVoiceAivisAutoStart], Return[False]];
  If[! iVoiceAivisLocalQ[], Return[False]];
  If[TrueQ[$iVoiceAivisStartTried],
    (* 起動済みプロセスの立ち上がり待ちだけ再開する。死んでいたら諦める
       (壊れた起動を繰り返してタイムアウトを払い続けない) *)
    If[MatchQ[$iVoiceAivisProcess, _ProcessObject] &&
        Quiet @ Check[ProcessStatus[$iVoiceAivisProcess], ""] === "Running",
      Return[iVoiceAivisAwait[iVoiceAivisStartTimeout[]]],
      Return[False]]];
  exe = iVoiceAivisExecutable[];
  If[exe === None, Return[False]];
  $iVoiceAivisStartTried = True;
  Print["AivisSpeech Engine を起動しています (初回は 1〜2 分かかることがあります) ..."];
  $iVoiceAivisProcess = Quiet @ Check[
    StartProcess[{exe, "--port", ToString[iVoiceAivisPort[]]}], $Failed];
  If[! MatchQ[$iVoiceAivisProcess, _ProcessObject],
    $iVoiceAivisProcess = None;
    Return[False]];
  iVoiceAivisAwait[iVoiceAivisStartTimeout[]]];

(* /speakers は Status / Voices / Speak で繰り返し呼ばれるので 30 秒キャッシュ。
   エンジン停止中の失敗もキャッシュされるが、iVoiceAivisEnsure が成功時に破棄する。 *)
iVoiceAivisSpeakers[] := Module[{now, ep, r, data},
  now = AbsoluteTime[];
  ep = iVoiceAivisEndpoint[];
  If[$iVoiceAivisSpeakersCache["Endpoint"] === ep &&
     now - $iVoiceAivisSpeakersCache["Time"] < 30.,
    Return[$iVoiceAivisSpeakersCache["Value"]]];
  r = Quiet @ Check[TimeConstrained[
    URLRead[HTTPRequest[ep <> "/speakers", <|"Method" -> "GET"|>],
      {"StatusCode", "BodyByteArray"}], 5, $Failed], $Failed];
  data = If[AssociationQ[r] && r["StatusCode"] === 200,
    Quiet @ Check[ImportByteArray[r["BodyByteArray"], "RawJSON"], $Failed], $Failed];
  data = If[ListQ[data], Select[data, AssociationQ], {}];
  $iVoiceAivisSpeakersCache = <|"Time" -> now, "Endpoint" -> ep, "Value" -> data|>;
  data];

(* AivisSpeech の話者を Piper の声と同じキー構成の Association に正規化する。
   "StyleId" が既定スタイル (先頭)、"Styles" が <|スタイル名 -> id|>。
   SampleRate はエンジン既定 44100 (実際の値は合成結果の WAV が持つ)。 *)
iVoiceAivisVoices[] := Module[{sp},
  sp = iVoiceAivisSpeakers[];
  Select[
    Map[Function[s, Module[{styles, names},
      styles = Select[Lookup[s, "styles", {}], AssociationQ];
      names = Lookup[#, "name", ""] & /@ styles;
      <|"Name" -> Lookup[s, "name", ""],
        "Engine" -> $iVoiceAivisEngine,
        "Model" -> iVoiceAivisEndpoint[],
        "Config" -> None,
        "Language" -> "ja",
        "SampleRate" -> 44100,
        "Speakers" -> 1,
        "StyleId" -> If[styles === {}, 0, Lookup[First[styles], "id", 0]],
        "Styles" -> AssociationThread[names -> (Lookup[#, "id", 0] & /@ styles)],
        "NoiseScale" -> 0., "LengthScale" -> 1., "NoiseW" -> 0.,
        "Multilingual" -> False,
        "Root" -> iVoiceAivisEndpoint[]|>]], sp],
    iVoiceStringQ[#["Name"]] &]];

SourceVaultVoiceAivisEnsure[] := TrueQ[iVoiceAivisEnsure[]];

SourceVaultVoiceAivisStatus[] := Module[{ver, exe},
  ver = iVoiceAivisVersion[];
  exe = iVoiceAivisExecutable[];
  Which[
    StringQ[ver],
      <|"Status" -> "Running", "Engine" -> $iVoiceAivisEngine,
        "Endpoint" -> iVoiceAivisEndpoint[], "Version" -> ver,
        "Executable" -> exe,
        "Voices" -> (#["Name"] & /@ iVoiceAivisVoices[]),
        "Hint" -> None|>,
    exe =!= None,
      <|"Status" -> "Installed", "Engine" -> $iVoiceAivisEngine,
        "Endpoint" -> iVoiceAivisEndpoint[], "Version" -> None,
        "Executable" -> exe, "Voices" -> {},
        "Hint" -> "AivisSpeech Engine は導入済みですが未起動です。" <>
          "SourceVaultVoiceSpeak が必要時に自動起動します (手動なら " <> exe <> " --port " <>
          ToString[iVoiceAivisPort[]] <> ")。"|>,
    True,
      <|"Status" -> "Missing", "Engine" -> $iVoiceAivisEngine,
        "Endpoint" -> iVoiceAivisEndpoint[], "Version" -> None,
        "Executable" -> None, "Voices" -> {},
        "Hint" -> iVoiceAivisHint[]|>]];

iVoiceAivisHint[] :=
  "AivisSpeech Engine が見つかりません (無くても Piper があれば合成はできます)。\n" <>
  "導入するなら GitHub Releases (Aivis-Project/AivisSpeech-Engine) の\n" <>
  "AivisSpeech-Engine-Windows-x64 を %LOCALAPPDATA%\\Programs\\AivisSpeech-Engine\\\n" <>
  "に展開してください。手順は SourceVault_voice/tts/README.md にあります。";

(* ============================================================
   声モデル
   ============================================================ *)

(* 1 つの .onnx から声の Association を作る。config は
     1. <model>.onnx.json          (piper 標準の配布形)
     2. 同じフォルダの config.json (フォルダ 1 つ = 声 1 つの形)
     3. 同じフォルダに 1 つだけある *.json
   の順に探す。どれも無ければ config 無しの声として返す (Status で分かる)。 *)
iVoiceFromModel[modelPath_String, root_String, nameHint_String] :=
  Module[{dir, cfgPath, cfg, name, lang, sr, speakers, ns, ls, nw, ptype, jsons},
    dir = DirectoryName[modelPath];
    cfgPath = modelPath <> ".json";
    If[! iVoiceFile[cfgPath],
      cfgPath = FileNameJoin[{dir, "config.json"}]];
    If[! iVoiceFile[cfgPath],
      jsons = Quiet @ Check[FileNames["*.json", dir], {}];
      cfgPath = If[Length[jsons] === 1, First[jsons], ""]];
    cfg = If[iVoiceFile[cfgPath], iVoiceReadJSON[cfgPath], $Failed];
    name = If[iVoiceStringQ[nameHint], nameHint, FileBaseName[modelPath]];
    If[AssociationQ[cfg],
      lang = iVoiceString[cfg, {"language", "code"}, ""];
      If[! iVoiceStringQ[lang], lang = iVoiceString[cfg, {"espeak", "voice"}, ""]];
      sr = iVoiceNumber[cfg, {"audio", "sample_rate"}, 22050.];
      speakers = iVoiceNumber[cfg, {"num_speakers"}, 1.];
      ns = iVoiceNumber[cfg, {"inference", "noise_scale"}, 0.667];
      ls = iVoiceNumber[cfg, {"inference", "length_scale"}, 1.];
      nw = iVoiceNumber[cfg, {"inference", "noise_w"}, 0.8];
      ptype = iVoiceString[cfg, {"phoneme_type"}, ""],
    (* else: config が読めない声。既定値で動かす *)
      lang = ""; sr = 22050.; speakers = 1.;
      ns = 0.667; ls = 1.; nw = 0.8; ptype = ""];
    <|
      "Name" -> name,
      "Engine" -> $iVoiceEngine,
      "Model" -> modelPath,
      "Config" -> If[iVoiceFile[cfgPath], cfgPath, None],
      "Language" -> lang,
      "SampleRate" -> Round[sr],
      "Speakers" -> Max[1, Round[speakers]],
      "NoiseScale" -> ns,
      "LengthScale" -> ls,
      "NoiseW" -> nw,
      (* multilingual な声だけが 1 回の合成要求で language を受け付ける。
         単言語の声に language を送ると拒否されうるので区別する。 *)
      "Multilingual" -> (ptype === "multilingual" || StringContainsQ[lang, "-"]),
      "Root" -> root
    |>];

iVoicesInRoot[root_String] := Module[{base, subdirs, flat, out = {}},
  base = FileNameJoin[{root, "tts", "models"}];
  If[! iVoiceDir[base], Return[{}]];
  (* フォルダ 1 つ = 声 1 つ *)
  subdirs = Quiet @ Check[Select[FileNames["*", base], DirectoryQ], {}];
  Do[
    With[{onnx = Quiet @ Check[Sort @ FileNames["*.onnx", d], {}]},
      If[onnx =!= {},
        AppendTo[out, iVoiceFromModel[First[onnx], root, FileNameTake[d]]]]],
    {d, Sort[subdirs]}];
  (* base 直下に .onnx を置いた形 (piper の素の配布形) *)
  flat = Quiet @ Check[Sort @ FileNames["*.onnx", base], {}];
  Do[AppendTo[out, iVoiceFromModel[f, root, FileBaseName[f]]], {f, flat}];
  out];

(* AivisSpeech の声 (稼働中のエンジンから列挙) と Piper の声を 1 つの一覧に
   まとめる。列挙は受動的: エンジンが止まっていてもここでは起こさない
   (起動が要るのは合成時で、それは SourceVaultVoiceSpeak が行う)。
   同名の声は AivisSpeech > 探索順の root の順で優先。 *)
SourceVaultVoices[] := Module[{all},
  all = Join[iVoiceAivisVoices[],
    Join @@ (iVoicesInRoot /@ SourceVaultVoiceSearchPath[])];
  all = DeleteDuplicatesBy[all, #["Name"] &];
  SortBy[all, #["Name"] &]];

(* ---- 既定の声の永続化 --------------------------------------------------
   <writable root>/local/voice_config.json の "DefaultVoice"。local/ は
   利用者ごとの好みなのでリポジトリ非同梱 (upload_manifest の excludePatterns)。
   優先順: $SourceVaultVoiceDefault (セッション内 override) > この設定 > 名前順先頭。 *)

iVoiceConfigPath[] := With[{r = iVoiceWritableRoot[]},
  If[iVoiceStringQ[r], FileNameJoin[{r, "local", "voice_config.json"}], ""]];

iVoiceConfiguredDefault[] := Module[{cfg, v},
  cfg = iVoiceReadJSON[iVoiceConfigPath[]];
  If[! AssociationQ[cfg], Return[None]];
  v = iVoiceString[cfg, {"DefaultVoice"}, ""];
  If[iVoiceStringQ[v], v, None]];

SourceVaultVoiceSetDefault[name_String] := Module[{path, cfg, ba, st},
  path = iVoiceConfigPath[];
  If[! iVoiceStringQ[path],
    Return[iVoiceFailure["SourceVaultVoiceConfigUnavailable",
      "音声資産 root が解決できないため設定を保存できません。"]]];
  Quiet @ Check[
    CreateDirectory[DirectoryName[path], CreateIntermediateDirectories -> True], Null];
  cfg = Replace[iVoiceReadJSON[path], Except[_Association] -> <||>];
  cfg["DefaultVoice"] = name;
  (* JSON は必ず UTF-8 の生バイトで書く (ShiftJIS カーネル対策、合成要求と同じ理由) *)
  ba = Quiet @ Check[ExportByteArray[cfg, "RawJSON"], $Failed];
  If[! ByteArrayQ[ba],
    Return[iVoiceFailure["SourceVaultVoiceConfigWriteFailed",
      "設定を書き出せませんでした。", <|"File" -> path|>]]];
  st = Quiet @ Check[OpenWrite[path, BinaryFormat -> True], $Failed];
  If[st === $Failed,
    Return[iVoiceFailure["SourceVaultVoiceConfigWriteFailed",
      "設定ファイルを開けませんでした。", <|"File" -> path|>]]];
  BinaryWrite[st, ba];
  Close[st];
  <|"Status" -> "OK", "DefaultVoice" -> name, "File" -> path|>];

(* 名前解決: 完全一致 > 前方一致。AivisSpeech の話者名は
   「ほのか(~現実20代女子AIボイチェン~リアボVC公式モデル)」のように長い
   正式名なので、前方一致を許して短い名前で指せるようにする。 *)
iVoiceMatch[voices_List, want_String] := Module[{hit},
  hit = SelectFirst[voices, #["Name"] === want &, None];
  If[hit =!= None, Return[hit]];
  SelectFirst[voices, StringStartsQ[#["Name"], want] &, None]];

iVoiceDefaultName[] := With[{w = SourceVault`$SourceVaultVoiceDefault},
  If[iVoiceStringQ[w], w, iVoiceConfiguredDefault[]]];

SourceVaultVoiceDefaultName[] := iVoiceDefaultName[];

SourceVaultVoice[] := Module[{voices, want, hit},
  voices = SourceVaultVoices[];
  If[voices === {},
    Return[iVoiceFailure["SourceVaultVoiceUnavailable",
      "導入済みの声モデルがありません。",
      <|"Hint" -> iVoiceModelHint[], "SearchPath" -> SourceVaultVoiceSearchPath[]|>]]];
  want = iVoiceDefaultName[];
  If[iVoiceStringQ[want],
    hit = iVoiceMatch[voices, want];
    If[hit =!= None, Return[hit]];
    (* 指定された声が消えていても停止させない: 先頭へ落として続ける *)
    Message[SourceVaultVoice::novoice, want]];
  First[voices]];

SourceVaultVoice[name_String] := Module[{hit},
  hit = iVoiceMatch[SourceVaultVoices[], name];
  If[hit === None,
    iVoiceFailure["SourceVaultVoiceUnavailable",
      "指定された声モデルが見つかりません: " <> name,
      <|"Hint" -> iVoiceModelHint[],
        "Available" -> (#["Name"] & /@ SourceVaultVoices[])|>],
    hit]];

SourceVaultVoice::novoice =
  "$SourceVaultVoiceDefault で指定された声 `1` が見つかりません。導入済みの先頭の声を使います。";

iVoiceModelHint[] :=
  "声モデル (Piper voice) が 1 つも見つかりません。\n" <>
  "  " <> FileNameJoin[{iVoiceWritableRoot[], "tts", "models"}] <> "\n" <>
  "の下に <声の名前>/ フォルダを作り、その中に .onnx と config.json (または\n" <>
  "<model>.onnx.json) を置いてください。声の名前・言語・サンプリング周波数は\n" <>
  "config から読むので、どの声でも構いません。\n" <>
  "入手先は SourceVault_voice/tts/README.md にあります。";

(* AivisSpeech は "Installed" (未起動) でも True: 合成時に自動起動できる。 *)
SourceVaultVoiceAvailableQ[] :=
  SourceVaultVoiceAivisStatus[]["Status"] =!= "Missing" ||
  (SourceVaultVoiceRuntime[]["Status"] === "OK" && SourceVaultVoices[] =!= {});

(* ============================================================
   ASR (Vosk)
   ============================================================ *)

iSpeechModelPresentQ[dir_String] :=
  iVoiceFile[FileNameJoin[{dir, "am", "final.mdl"}]] &&
  iVoiceDir[FileNameJoin[{dir, "graph"}]];

iSpeechModelsInRoot[root_String] := Module[{bases, out = {}},
  (* 正: <root>/asr/models/<model> (tts と対称。README を同梱しつつ models だけ
     除外できる形)。<root>/asr/<model> に直接置かれたものも拾う。
     旧: <LOCALAPPDATA>/VRCRealtime/models/<model> *)
  bases = {FileNameJoin[{root, "asr", "models"}],
    FileNameJoin[{root, "asr"}], FileNameJoin[{root, "models"}]};
  Do[
    If[iVoiceDir[b],
      Do[
        If[iSpeechModelPresentQ[d],
          AppendTo[out, <|
            "Name" -> FileNameTake[d],
            "Engine" -> "Vosk",
            "Directory" -> d,
            "Root" -> root|>]],
        {d, Sort @ Quiet @ Check[Select[FileNames["*", b], DirectoryQ], {}]}]],
    {b, bases}];
  out];

SourceVaultSpeechModels[] := Module[{all},
  all = Join @@ (iSpeechModelsInRoot /@ SourceVaultVoiceSearchPath[]);
  all = DeleteDuplicatesBy[all, #["Name"] &];
  SortBy[all, #["Name"] &]];

SourceVaultSpeechModel[] := Module[{models, want, hit},
  models = SourceVaultSpeechModels[];
  If[models === {},
    Return[iVoiceFailure["SourceVaultSpeechModelUnavailable",
      "導入済みのローカル音声認識モデルがありません。",
      <|"Hint" -> iSpeechModelHint[], "SearchPath" -> SourceVaultVoiceSearchPath[]|>]]];
  want = SourceVault`$SourceVaultVoiceSpeechModelDefault;
  If[iVoiceStringQ[want],
    hit = SelectFirst[models, #["Name"] === want &, None];
    If[hit =!= None, Return[hit]]];
  First[models]];

SourceVaultSpeechModel[name_String] := Module[{hit},
  hit = SelectFirst[SourceVaultSpeechModels[], #["Name"] === name &, None];
  If[hit === None,
    iVoiceFailure["SourceVaultSpeechModelUnavailable",
      "指定された音声認識モデルが見つかりません: " <> name,
      <|"Hint" -> iSpeechModelHint[],
        "Available" -> (#["Name"] & /@ SourceVaultSpeechModels[])|>],
    hit]];

SourceVaultSpeechModelDirectory[] :=
  FileNameJoin[{iVoiceWritableRoot[], "asr", "models"}];

iSpeechModelHint[] :=
  "ローカル音声認識モデル (Vosk) が見つかりません。\n" <>
  "  SourceVaultInstallSpeechModel[]        (日本語小モデル、約 50 MB)\n" <>
  "  SourceVaultInstallSpeechModel[\"en\"]    (英語小モデル)\n" <>
  "で " <> SourceVaultSpeechModelDirectory[] <> " へ導入できます。";

SourceVaultInstallSpeechModel[] := SourceVaultInstallSpeechModel["ja"];

SourceVaultInstallSpeechModel[language_String] :=
  Module[{entry, name, url, targetDir, target, tmp, dl, extracted, moved},
    entry = Lookup[SourceVault`$SourceVaultVoiceSpeechModelCatalog, language, Missing["NoEntry"]];
    If[! AssociationQ[entry],
      Return[<|"Status" -> "Error", "Reason" -> "UnknownLanguage",
        "Language" -> language,
        "Available" -> Keys[SourceVault`$SourceVaultVoiceSpeechModelCatalog]|>]];
    name = entry["Name"];
    url = entry["URL"];
    targetDir = SourceVaultSpeechModelDirectory[];
    target = FileNameJoin[{targetDir, name}];
    If[iSpeechModelPresentQ[target],
      Return[<|"Status" -> "OK", "Reason" -> "AlreadyInstalled",
        "Name" -> name, "Directory" -> target|>]];
    Quiet @ Check[CreateDirectory[targetDir, CreateIntermediateDirectories -> True], Null];
    If[! iVoiceDir[targetDir],
      Return[<|"Status" -> "Error", "Reason" -> "TargetDirectoryUnavailable",
        "Directory" -> targetDir|>]];
    tmp = FileNameJoin[{$TemporaryDirectory,
      "sourcevault-voice-" <> StringReplace[CreateUUID[], "-" -> ""] <> ".zip"}];
    dl = Quiet @ Check[URLDownload[url, tmp], $Failed];
    If[dl === $Failed || ! iVoiceFile[tmp],
      Quiet @ DeleteFile[tmp];
      Return[<|"Status" -> "Error", "Reason" -> "DownloadFailed",
        "URL" -> url, "Hint" -> "ネットワークまたは配布元の状態を確認してください。"|>]];
    extracted = Quiet @ Check[ExtractArchive[tmp, targetDir, OverwriteTarget -> True], $Failed];
    Quiet @ DeleteFile[tmp];
    If[extracted === $Failed,
      Return[<|"Status" -> "Error", "Reason" -> "ExtractFailed", "Directory" -> targetDir|>]];
    (* zip の中身が別名フォルダで展開された場合は名前をそろえる *)
    If[! iSpeechModelPresentQ[target],
      moved = SelectFirst[
        Sort @ Quiet @ Check[Select[FileNames["*", targetDir], DirectoryQ], {}],
        iSpeechModelPresentQ, None];
      If[moved =!= None && moved =!= target,
        Quiet @ Check[RenameDirectory[moved, target], Null]]];
    If[iSpeechModelPresentQ[target],
      <|"Status" -> "OK", "Reason" -> "Installed", "Name" -> name,
        "Directory" -> target, "License" -> Lookup[entry, "License", ""]|>,
      <|"Status" -> "Error", "Reason" -> "ModelIncomplete", "Directory" -> target|>]];

(* ============================================================
   総合状態 / 導入手順
   ============================================================ *)

SourceVaultVoiceStatus[] := Module[{runtime, aivis, voices, speech, missing = {}, hints = {}},
  runtime = SourceVaultVoiceRuntime[];
  aivis = SourceVaultVoiceAivisStatus[];
  voices = SourceVaultVoices[];
  speech = SourceVaultSpeechModels[];
  (* TTS はエンジンがどちらか 1 つあればよい。AivisSpeech は "Installed"
     (未起動) でも合成時に自動起動できるので欠品扱いにしない。 *)
  If[runtime["Status"] =!= "OK" && aivis["Status"] === "Missing",
    AppendTo[missing, "TTSRuntime"];
    AppendTo[hints, iVoiceRuntimeHint[]]; AppendTo[hints, iVoiceAivisHint[]]];
  If[voices === {} && aivis["Status"] === "Missing",
    AppendTo[missing, "TTSVoice"]; AppendTo[hints, iVoiceModelHint[]]];
  If[speech === {},
    AppendTo[missing, "SpeechModel"]; AppendTo[hints, iSpeechModelHint[]]];
  <|
    "Status" -> If[missing === {}, "OK", "Incomplete"],
    "Missing" -> missing,
    "Root" -> SourceVaultVoiceRoot[],
    "SearchPath" -> SourceVaultVoiceSearchPath[],
    "Runtime" -> runtime,
    "AivisEngine" -> aivis,
    "Voices" -> voices,
    "DefaultVoice" -> If[voices === {}, None, SourceVaultVoice[]],
    "SpeechModels" -> speech,
    "Hint" -> If[hints === {}, None, StringRiffle[hints, "\n\n"]]
  |>];

SourceVaultVoiceInstallHint[] := Module[{h},
  h = SourceVaultVoiceStatus[]["Hint"];
  If[iVoiceStringQ[h], h, "ローカル音声資産はそろっています。"]];

SourceVaultVoiceView[] := Module[{st, voiceRows, speechRows},
  st = SourceVaultVoiceStatus[];
  voiceRows = If[st["Voices"] === {}, {},
    KeyTake[#, {"Name", "Engine", "Language", "SampleRate", "Speakers", "Multilingual", "Model"}] & /@ st["Voices"]];
  speechRows = If[st["SpeechModels"] === {}, {},
    KeyTake[#, {"Name", "Engine", "Directory"}] & /@ st["SpeechModels"]];
  Column[{
    Style["SourceVault ローカル音声資産", Bold],
    Grid[{
      {"状態", st["Status"]},
      {"不足", If[st["Missing"] === {}, "なし", StringRiffle[st["Missing"], ", "]]},
      {"root", st["Root"]},
      {"合成ランタイム (Piper)", Lookup[st["Runtime"], "Executable", None] /. None -> "未導入"},
      {"AivisSpeech Engine", With[{a = st["AivisEngine"]},
        Switch[a["Status"],
          "Running", "稼働中 " <> ToString[a["Version"]] <> " (" <> a["Endpoint"] <> ")",
          "Installed", "導入済 (未起動・合成時に自動起動)",
          _, "未導入"]]}},
      Alignment -> Left, Frame -> All, FrameStyle -> LightGray],
    Style["声モデル", Bold],
    If[voiceRows === {}, Style["未導入", Gray], Dataset[voiceRows]],
    Style["音声認識モデル", Bold],
    If[speechRows === {}, Style["未導入", Gray], Dataset[speechRows]],
    If[st["Hint"] === None, Nothing,
      Style[st["Hint"], Gray, FontFamily -> "Consolas", FontSize -> 11]]
  }, Alignment -> Left, Spacings -> 1]];

(* ============================================================
   薄い合成の口 (WL から 1 発)
   ============================================================ *)

Options[SourceVaultVoiceSpeak] = {
  "Voice" -> Automatic,
  "Style" -> Automatic,
  "OutputFile" -> Automatic,
  "LengthScale" -> Automatic,
  "NoiseScale" -> Automatic,
  "TimeConstraint" -> 120
};

(* 合成に使う声の解決。列挙 (受動) で目当ての声が見つからないときだけ、
   AivisSpeech の自動起動を一度試して再列挙する。明示指定 ("Voice" -> name)
   が見つからないときは黙って別の声に切り替えず Failure を返す。 *)
iVoiceResolveVoice[want_] := Module[{name, voices, hit},
  name = If[iVoiceStringQ[want], want, iVoiceDefaultName[]];
  voices = SourceVaultVoices[];
  If[(iVoiceStringQ[name] && iVoiceMatch[voices, name] === None) ||
     (! iVoiceStringQ[name] && voices === {}),
    If[! iVoiceAivisRunningQ[] && iVoiceAivisEnsure[],
      voices = SourceVaultVoices[]]];
  If[voices === {},
    Return[iVoiceFailure["SourceVaultVoiceUnavailable",
      "導入済みの声モデルがありません。",
      <|"Hint" -> iVoiceModelHint[] <> "\n\n" <> iVoiceAivisHint[],
        "SearchPath" -> SourceVaultVoiceSearchPath[]|>]]];
  If[iVoiceStringQ[name],
    hit = iVoiceMatch[voices, name];
    If[hit =!= None, Return[hit]];
    If[iVoiceStringQ[want],
      Return[iVoiceFailure["SourceVaultVoiceUnavailable",
        "指定された声モデルが見つかりません: " <> name,
        <|"Available" -> (#["Name"] & /@ voices)|>]]];
    (* 既定 (設定ファイル / $SourceVaultVoiceDefault) の声が見つからないとき:
       停止させず先頭の声へ落とす *)
    Message[SourceVaultVoice::novoice, name]];
  First[voices]];

SourceVaultVoiceSpeak[text_String, opts : OptionsPattern[]] :=
  Module[{voice, runtime, out, ls, ns, style, limit},
    If[StringTrim[text] === "",
      Return[iVoiceFailure["SourceVaultVoiceEmptyText", "合成するテキストが空です。"]]];
    voice = iVoiceResolveVoice[OptionValue["Voice"]];
    If[! AssociationQ[voice], Return[voice]];
    out = Replace[OptionValue["OutputFile"], Automatic :>
      FileNameJoin[{$TemporaryDirectory,
        "sourcevault-voice-" <> StringReplace[CreateUUID[], "-" -> ""] <> ".wav"}]];
    ls = Replace[OptionValue["LengthScale"], Automatic :> voice["LengthScale"]];
    ns = Replace[OptionValue["NoiseScale"], Automatic :> voice["NoiseScale"]];
    style = Replace[OptionValue["Style"], Automatic -> None];
    limit = OptionValue["TimeConstraint"];
    If[voice["Engine"] === $iVoiceAivisEngine,
      Return[iVoiceAivisSpeak[voice, text, out, ls, style, limit]]];
    runtime = SourceVaultVoiceRuntime[];
    If[runtime["Status"] =!= "OK",
      Return[iVoiceFailure["SourceVaultVoiceUnavailable",
        "ローカル音声合成ランタイムがありません。",
        <|"Hint" -> runtime["Hint"]|>]]];
    iVoicePiperSpeak[runtime["Executable"], voice, text, out, ls, ns, limit]];

(* ---- AivisSpeech (VOICEVOX 互換 2 段 API: audio_query -> synthesis) ---- *)

iVoiceAivisSpeak[voice_Association, text_String, out_String, ls_, styleName_, limit_] :=
  Module[{ep, sid, styleKey, r1, query, payload, r2, wav, st},
    ep = iVoiceAivisEndpoint[];
    sid = voice["StyleId"];
    If[iVoiceStringQ[styleName],
      styleKey = SelectFirst[Keys[voice["Styles"]],
        # === styleName || StringStartsQ[#, styleName] &, None];
      If[styleKey === None,
        Return[iVoiceFailure["SourceVaultVoiceUnknownStyle",
          "指定されたスタイルがありません: " <> styleName,
          <|"Voice" -> voice["Name"], "Available" -> Keys[voice["Styles"]]|>]]];
      sid = voice["Styles"][styleKey]];
    (* URL の percent-encode / JSON の encode がカーネルの $CharacterEncoding に
       依存しないよう UTF-8 に固定する (piper 経路と同じ理由) *)
    Block[{$CharacterEncoding = "UTF-8"},
      r1 = Quiet @ Check[TimeConstrained[
        URLRead[HTTPRequest[ep <> "/audio_query",
          <|"Method" -> "POST",
            "Query" -> {"speaker" -> ToString[sid], "text" -> text}|>],
          {"StatusCode", "BodyByteArray"}], limit, $Failed], $Failed];
      If[! (AssociationQ[r1] && r1["StatusCode"] === 200),
        Return[iVoiceFailure["SourceVaultVoiceSynthesisFailed",
          "AivisSpeech への合成要求 (audio_query) に失敗しました。",
          <|"Voice" -> voice["Name"], "Endpoint" -> ep,
            "StatusCode" -> If[AssociationQ[r1], r1["StatusCode"], None],
            "Hint" -> "エンジンが起動しているか SourceVaultVoiceAivisStatus[] で確認してください。"|>]]];
      query = Quiet @ Check[ImportByteArray[r1["BodyByteArray"], "RawJSON"], $Failed];
      If[! AssociationQ[query],
        Return[iVoiceFailure["SourceVaultVoiceSynthesisFailed",
          "AivisSpeech の audio_query 応答を読めませんでした。",
          <|"Voice" -> voice["Name"], "Endpoint" -> ep|>]]];
      (* LengthScale は piper の流儀 (>1 = ゆっくり)。AivisSpeech の speedScale
         (>1 = 速い) へは逆数で写す *)
      If[NumericQ[ls] && ls > 0 && ls != 1.,
        query["speedScale"] = N[1/ls]];
      payload = Quiet @ Check[
        ExportByteArray[query, "RawJSON", "Compact" -> True], $Failed];
      If[! ByteArrayQ[payload],
        Return[iVoiceFailure["SourceVaultVoiceRequestFailed",
          "合成要求を組み立てられませんでした。", <|"Voice" -> voice["Name"]|>]]];
      r2 = Quiet @ Check[TimeConstrained[
        URLRead[HTTPRequest[ep <> "/synthesis",
          <|"Method" -> "POST",
            "Query" -> {"speaker" -> ToString[sid]},
            "ContentType" -> "application/json",
            "Body" -> payload|>],
          {"StatusCode", "BodyByteArray"}], limit, $Failed], $Failed]];
    If[! (AssociationQ[r2] && r2["StatusCode"] === 200 &&
          ByteArrayQ[r2["BodyByteArray"]] && Length[r2["BodyByteArray"]] > 0),
      Return[iVoiceFailure["SourceVaultVoiceSynthesisFailed",
        "AivisSpeech での合成 (synthesis) に失敗しました。",
        <|"Voice" -> voice["Name"], "Endpoint" -> ep,
          "StatusCode" -> If[AssociationQ[r2], r2["StatusCode"], None]|>]]];
    wav = r2["BodyByteArray"];
    st = Quiet @ Check[OpenWrite[out, BinaryFormat -> True], $Failed];
    If[st === $Failed,
      Return[iVoiceFailure["SourceVaultVoiceReadFailed",
        "合成結果を書き出せませんでした。", <|"File" -> out|>]]];
    BinaryWrite[st, wav];
    Close[st];
    Quiet @ Check[Import[out, "Audio"],
      iVoiceFailure["SourceVaultVoiceReadFailed",
        "合成結果を読み込めませんでした。", <|"File" -> out|>]]];

(* ---- Piper (プロセス起動 + JSON 1 行の往復) ---- *)

iVoicePiperSpeak[exe_String, voice_Association, text_String, out_String, ls_, ns_, limit_] :=
  Module[{request, payload, proc, line, stderr, waited},
    request = <|"text" -> text, "output_file" -> out,
      "speaker_id" -> 0, "noise_scale" -> N[ns], "length_scale" -> N[ls]|>;
    (* 単言語の声に language を送ると弾かれうる。multilingual の声にだけ付ける *)
    If[TrueQ[voice["Multilingual"]] && iVoiceStringQ[voice["Language"]],
      request["language"] = voice["Language"]];
    (* ---- 要求の書き込みは必ず生バイトで ------------------------------------
       WriteLine / WriteString は stream の文字エンコーディングで符号化するため、
       $CharacterEncoding が UTF-8 でないカーネル (日本語 Windows の FE メイン
       カーネルは既定 ShiftJIS) では JSON 内の日本語が化け、piper が JSON を
       解釈できずに即終了する。症状は stdout が EndOfFile になるだけで、
       原因がまったく見えない。UTF-8 バイトをそのまま流し込むことで、呼び出し側の
       カーネルのエンコーディングに一切依存させない。
       ($CharacterEncoding も Block しておく: 応答行の読み取り側も同じ理由で
        UTF-8 でないと壊れうる。) *)
    payload = Quiet @ Check[
      ExportByteArray[request, "RawJSON", "Compact" -> True], $Failed];
    If[! ByteArrayQ[payload],
      Return[iVoiceFailure["SourceVaultVoiceRequestFailed",
        "合成要求を組み立てられませんでした。", <|"Voice" -> voice["Name"]|>]]];
    line = $Failed;
    stderr = "";
    Block[{$CharacterEncoding = "UTF-8"},
      proc = Quiet @ Check[
        StartProcess[{exe, "--model", voice["Model"],
          If[voice["Config"] === None, Nothing, Sequence @@ {"--config", voice["Config"]}],
          "--json-input", "--quiet"}],
        $Failed];
      If[! MatchQ[proc, _ProcessObject],
        Return[iVoiceFailure["SourceVaultVoiceRuntimeFailed",
          "音声合成ランタイムを起動できませんでした。", <|"Executable" -> exe|>]]];
      Quiet @ Check[
        Module[{in = ProcessConnection[proc, "StandardInput"]},
          BinaryWrite[in, Join[Normal[payload], {10}]];
          Flush[in]],
        Null];
      line = Quiet @ Check[TimeConstrained[ReadLine[proc], limit, $Failed], $Failed];
      (* 失敗時の診断のために stderr を拾う。成功時は空 *)
      If[line === $Failed || line === EndOfFile,
        stderr = Quiet @ Check[
          TimeConstrained[
            ReadString[ProcessConnection[proc, "StandardError"]], 3, ""], ""]];
      (* piper は 1 要求につき 1 行返してから次の要求を待つ。ここは 1 発なので閉じる *)
      Quiet @ Check[KillProcess[proc], Null]];
    waited = 0;
    While[! iVoiceFile[out] && waited < 20, Pause[0.05]; waited++];
    If[! iVoiceFile[out],
      Return[iVoiceFailure["SourceVaultVoiceSynthesisFailed",
        "ローカル音声合成に失敗しました。",
        <|"Voice" -> voice["Name"], "Response" -> line,
          "StandardError" -> If[StringQ[stderr], StringTake[stderr, UpTo[1000]], ""],
          "Executable" -> exe, "Model" -> voice["Model"],
          "Hint" -> "piper が要求を読めずに終了した可能性があります。" <>
            "SourceVaultVoiceStatus[] で声と config を確認してください。"|>]]];
    Quiet @ Check[Import[out, "Audio"],
      iVoiceFailure["SourceVaultVoiceReadFailed",
        "合成結果を読み込めませんでした。", <|"File" -> out|>]]];

End[];

EndPackage[];
