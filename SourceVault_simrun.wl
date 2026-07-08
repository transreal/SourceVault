(* ::Package:: *)

(* ============================================================
   SourceVault_simrun.wl -- シミュレーション実行基盤
   (マシンプロファイル / 参照ベース実行フォルダ / サブカーネル burst / CUDA)

   This file is encoded in UTF-8.
   SourceVault.wl から自動ロードされる (Block[{$CharacterEncoding="UTF-8"}, Get[...]])。

   位置づけ:
     数値シミュレーション等の「高負荷・大容量出力」ワークフローの実行クラス
     (ExecutionClass = "simulation") を支える共通基盤。出力の扱いは二層:
       - バルク出力 (データ/画像/動画/フレーム列) は vault の blob には入れず、
         <Dropbox>/udb/simruns/<yyyymmddHHmm>-<machine>-<slug>/ に書く (参照ベース)。
       - メタデータ/パラメータ/ファイル一覧/小さな要約のみを immutable snapshot
         (class "SimulationRun") として保存し、sv://snapshot/SimulationRun/<hex>
         URI で参照する。pointer は simrun/<slug>/latest。
     フォルダは Dropbox 同期なので他マシンからも同じ相対パスで解決できる
     (snapshot には udb 相対の FolderSymbolic を記録し、読む側で復元する)。

   マシンプロファイル:
     各 PC で SourceVaultMachineProfileRefresh[] を実行すると CPU コア数 / メモリ /
     GPU (nvidia-smi) / nvcc の実測プロファイルを <PrivateVault>/machines/<tag>.wl
     に書く (Dropbox 同期で全マシン共有)。仕様生成はこの表をプロンプトに注入し、
     「rapterlake4t で CUDA」のようなマシン指定つき仕様を書けるようにする。

   サブカーネル:
     SourceVaultWithSubkernels[body] は「その時使えるサブカーネルを全て起動し、
     body 実行後に (自分が起動した分を) 必ず停止して次のワークフローに備える」
     burst 実行プリミティブ。license 席は使い終わったら返す。

   service-loadable 制約 (spec v6 §3.4):
     FrontEnd / Notebook / NBAccess / UI 依存を持たない。root 解決は core の
     SourceVaultRoot[...] を使う。他モジュールへの参照は実行時 fail-soft。
   ============================================================ *)

BeginPackage["SourceVault`"]

(* ---- マシンプロファイル ---- *)

SourceVaultMachineProfile::usage =
  "SourceVaultMachineProfile[] は現在のマシンの実測プロファイル Association を返す (セッション内 memoize)。\n" <>
  "キー: MachineName, MachineTag, OS, ProcessorCount, MemoryGB, WolframVersion,\n" <>
  "GPUs ({<|Name, MemoryMB|>...}; Nvidia のみ), GPUAvailable, NvccAvailable, NvccPath,\n" <>
  "SubkernelTarget, ProbedAtUTC。SourceVaultMachineProfile[\"Refresh\"->True] で再実測。";

SourceVaultMachineProfileRefresh::usage =
  "SourceVaultMachineProfileRefresh[] は現在のマシンを再実測し、共有ストア\n" <>
  "<PrivateVault>/machines/<tag>.wl (Dropbox 同期) へ書き込んで profile を返す。\n" <>
  "各 PC で一度実行しておくと SourceVaultMachineSpecs[] で全マシンのスペックを共有できる。";

SourceVaultMachineSpecs::usage =
  "SourceVaultMachineSpecs[] は共有ストアに記録された全マシンのプロファイルを\n" <>
  "<|tag -> profile...|> で返す (現在のマシンは常に最新の実測で上書き)。core 版。";

SourceVaultMachineSpecsView::usage =
  "SourceVaultMachineSpecsView[] は SourceVaultMachineSpecs[] の Dataset 表示版。";

SourceVaultMachineSpecsText::usage =
  "SourceVaultMachineSpecsText[] は全マシンスペックの compact なテキスト表を返す\n" <>
  "(仕様生成プロンプトへの注入用)。記録が無ければその旨の 1 行を返す。";

(* ---- GPU / CUDA ---- *)

SourceVaultGPUAvailableQ::usage =
  "SourceVaultGPUAvailableQ[] は現在のマシンに Nvidia GPU があるか (nvidia-smi 実測、memoize) を返す。";

SourceVaultNvccPath::usage =
  "SourceVaultNvccPath[] は nvcc 実行ファイルのパスを返す (見つからなければ Missing[\"NotFound\"])。";

SourceVaultCUDARequire::usage =
  "SourceVaultCUDARequire[] は CUDA 実行の前提 (Nvidia GPU) を検査する。\n" <>
  "満たせば <|\"OK\"->True, \"GPUs\"->...|>、満たさなければ Failure[\"NoNvidiaGPU\", ...]\n" <>
  "(メッセージに GPU を持つ既知マシン一覧を含む) を返す。CUDA ワークフローは冒頭でこれを呼び、\n" <>
  "Failure ならそのまま返して graceful に停止すること。";

SourceVaultCUDACompile::usage =
  "SourceVaultCUDACompile[cuFile] は .cu を nvcc -O3 でコンパイルし、実行ファイルのパスを返す。\n" <>
  "出力先は <LocalState>/cudabin/<name>-<srchash8>.exe (ソース内容でキャッシュ; 同一ソースは再利用)。\n" <>
  "失敗時は Failure[\"NvccUnavailable\"|\"CompileFailed\", ...]。\n" <>
  "オプション: \"ExtraArgs\" -> {..} (nvcc 追加引数), \"Force\" -> False。";

(* ---- サブカーネル burst ---- *)

$SourceVaultSubkernelMax::usage =
  "$SourceVaultSubkernelMax はサブカーネル burst の上限 (既定 16 = ライセンスの subkernel 席実測)。";

SourceVaultSubkernelTarget::usage =
  "SourceVaultSubkernelTarget[] は burst 時に目標とするサブカーネル数\n" <>
  "(Min[$ProcessorCount, $SourceVaultSubkernelMax]) を返す。";

SourceVaultWithSubkernels::usage =
  "SourceVaultWithSubkernels[body] は使えるサブカーネルを全て起動して body を評価し、\n" <>
  "評価後に自分が起動したサブカーネルを必ず停止して席を返す (次のワークフロー実行に備える)。\n" <>
  "SourceVaultWithSubkernels[n, body] は目標 n 基。body 内では ParallelMap / ParallelTable /\n" <>
  "DistributeDefinitions / ParallelEvaluate がそのまま使える。戻り値は body の値。\n" <>
  "起動済みカーネルが既にある場合はそれも使うが、停止するのは自分が起動した分だけ。";

(* ---- 参照ベース実行フォルダ (SimulationRun) ---- *)

$SourceVaultSimRunRoot::usage =
  "$SourceVaultSimRunRoot はシミュレーション実行フォルダの root。Automatic (既定) で\n" <>
  "<Dropbox>/udb/simruns (= PrivateVault の親 udb 直下)。文字列で明示上書き可。";

SourceVaultSimRunRoot::usage =
  "SourceVaultSimRunRoot[] は解決済みの simrun root パスを返す (未作成でも返す)。";

SourceVaultSimRunCreate::usage =
  "SourceVaultSimRunCreate[slug] / SourceVaultSimRunCreate[slug, params] は実行フォルダ\n" <>
  "<simrunroot>/<yyyymmddHHmm>-<machinetag>-<slug>/ を作成し、run メタ\n" <>
  "<|\"RunId\", \"Folder\", \"Slug\", \"Machine\", \"Params\", \"StartedAtUTC\"|> を返す\n" <>
  "(フォルダ内 run.wl にも書く)。バルク出力は全てこの Folder 配下に書くこと。";

SourceVaultSimRunFinalize::usage =
  "SourceVaultSimRunFinalize[run] / SourceVaultSimRunFinalize[run, extra] は実行フォルダの\n" <>
  "ファイル一覧 (相対パス+バイト数) を採取し、メタデータのみを immutable snapshot\n" <>
  "(class \"SimulationRun\") として保存、pointer simrun/<slug>/latest を更新して\n" <>
  "<|\"Status\", \"URI\", \"Ref\", \"RunId\", \"Folder\", \"Files\", \"TotalBytes\"|> を返す。\n" <>
  "extra には小さな要約のみ入れる (例 \"Summary\" -> assoc, \"Status\" -> \"Done\"|\"Failed\")。\n" <>
  "バルクデータ・画像・巨大リストを extra に入れてはならない (参照ベース原則)。";

SourceVaultSimRunRecord::usage =
  "SourceVaultSimRunRecord[uriOrRef] は SimulationRun snapshot を読み、Ref/URI を補った\n" <>
  "Association を返す (無ければ Missing)。";

SourceVaultSimRunFolder::usage =
  "SourceVaultSimRunFolder[uriOrRefOrRunId] は SimulationRun の実行フォルダを現在のマシンの\n" <>
  "絶対パスへ解決して返す。フォルダが (Dropbox 未同期等で) 無ければ Missing[\"NotSynced\", path]。";

SourceVaultSimRuns::usage =
  "SourceVaultSimRuns[slug] は slug の SimulationRun 履歴 (pointer simrun/<slug>/latest の\n" <>
  "履歴) を新しい順の URI リストで返す。";

Begin["`Private`"]

(* ============================================================
   小物
   ============================================================ *)

iSRNowUTC[] := Quiet @ Check[
  DateString[Now, {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"},
    TimeZone -> 0], ""];

iSRStamp[] := Quiet @ Check[
  DateString[Now, {"Year", "Month", "Day", "Hour", "Minute"}], "000000000000"];

(* machine tag: llmlog の SourceVaultMachineTag があればそれ、無ければ自前 sanitize *)
iSRMachineTag[] := Module[{r},
  r = Quiet @ Check[
    If[Length[Names["SourceVault`SourceVaultMachineTag"]] > 0 &&
        Length[DownValues[SourceVault`SourceVaultMachineTag]] > 0,
      SourceVault`SourceVaultMachineTag[], $Failed], $Failed];
  If[StringQ[r] && r =!= "", r,
    StringReplace[ToLowerCase[ToString[$MachineName]],
      Except[LetterCharacter | DigitCharacter | "-" | "_"] -> "-"]]];

iSRSanitizeSlug[s_String] := Module[{t},
  t = StringReplace[s, {"\\" -> "-", "/" -> "-", ":" -> "-", "*" -> "-", "?" -> "-",
    "\"" -> "-", "<" -> "-", ">" -> "-", "|" -> "-", " " -> "-"}];
  t = StringTrim[t, "-" | "."];
  If[t === "", "run", t]];

iSRWriteWL[p_, expr_] := Quiet @ Check[
  Block[{$CharacterEncoding = "UTF-8"}, Put[expr, p]], $Failed];

iSREnsureDir[d_String] :=
  If[! DirectoryQ[d], Quiet @ Check[CreateDirectory[d, CreateIntermediateDirectories -> True], $Failed]];

iSRRefToURI[ref_String] := Module[{p = StringSplit[ref, ":"]},
  If[Length[p] >= 3 && p[[1]] === "snapshot",
    "sv://snapshot/" <> p[[2]] <> "/" <> p[[3]], ref]];
iSRRefToURI[_] := "<no-ref>";

iSRURIToRef[s_String] := Module[{body, parts},
  Which[
    StringStartsQ[s, "snapshot:"], s,
    StringStartsQ[s, "sv://snapshot/"],
      body = StringDrop[s, StringLength["sv://snapshot/"]];
      parts = StringSplit[body, {"/", ":"}];
      If[Length[parts] >= 2, "snapshot:" <> parts[[1]] <> ":" <> Last[parts], s],
    True, s]];
iSRURIToRef[x_] := x;

(* ============================================================
   マシンプロファイル (probe + 共有ストア)
   ============================================================ *)

(* nvidia-smi: Nvidia GPU の名前と搭載メモリ (MiB)。無ければ {} *)
iSRProbeGPUs[] := Module[{res, out, lines},
  res = Quiet @ Check[
    TimeConstrained[
      RunProcess[{"nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"}, All],
      15, $Failed],
    $Failed];
  If[! AssociationQ[res] || res["ExitCode"] =!= 0, Return[{}]];
  out = Lookup[res, "StandardOutput", ""];
  lines = Select[StringTrim /@ StringSplit[out, "\n"], # =!= "" &];
  Map[
    Function[ln, Module[{parts = StringTrim /@ StringSplit[ln, ","], mem},
      mem = If[Length[parts] >= 2,
        With[{d = StringCases[parts[[2]], DigitCharacter ..]},
          If[d =!= {}, ToExpression[First[d]], Missing["Unknown"]]],
        Missing["Unknown"]];
      <|"Name" -> If[parts =!= {}, First[parts], "GPU"], "MemoryMB" -> mem|>]],
    lines]];

(* nvcc: PATH -> CUDA_PATH -> 既定インストール場所の順で探す (memoize) *)
iSRFindNvcc[] := Module[{exe, res, out, cands},
  exe = If[$OperatingSystem === "Windows", "nvcc.exe", "nvcc"];
  res = Quiet @ Check[
    TimeConstrained[
      RunProcess[If[$OperatingSystem === "Windows", {"where", "nvcc"}, {"which", "nvcc"}], All],
      10, $Failed],
    $Failed];
  If[AssociationQ[res] && res["ExitCode"] === 0,
    out = SelectFirst[StringTrim /@ StringSplit[Lookup[res, "StandardOutput", ""], "\n"],
      # =!= "" && FileExistsQ[#] &, $Failed];
    If[StringQ[out], Return[out]]];
  cands = Flatten[{
    With[{cp = Environment["CUDA_PATH"]},
      If[StringQ[cp], {FileNameJoin[{cp, "bin", exe}]}, {}]],
    If[$OperatingSystem === "Windows",
      Quiet @ Check[
        Reverse @ Sort @ FileNames[
          FileNameJoin[{"C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA", "*", "bin", exe}]], {}],
      {"/usr/local/cuda/bin/nvcc", "/opt/cuda/bin/nvcc"}]}];
  SelectFirst[cands, StringQ[#] && FileExistsQ[#] &, Missing["NotFound"]]];

If[! ValueQ[$iSRNvccPath], $iSRNvccPath = None];
SourceVaultNvccPath[] := ($iSRNvccPath = If[$iSRNvccPath === None, iSRFindNvcc[], $iSRNvccPath]);

If[! ValueQ[$iSRGPUs], $iSRGPUs = None];
iSRGPUs[] := ($iSRGPUs = If[$iSRGPUs === None, iSRProbeGPUs[], $iSRGPUs]);

SourceVaultGPUAvailableQ[] := iSRGPUs[] =!= {};

If[! ValueQ[$SourceVaultSubkernelMax], $SourceVaultSubkernelMax = 16];

SourceVaultSubkernelTarget[] := Max[1, Min[$ProcessorCount, $SourceVaultSubkernelMax]];

iSRProbeProfile[] := Module[{gpus = iSRProbeGPUs[], nvcc = iSRFindNvcc[]},
  <|
    "MachineName" -> ToString[$MachineName],
    "MachineTag" -> iSRMachineTag[],
    "OS" -> $OperatingSystem,
    "ProcessorCount" -> $ProcessorCount,
    "MemoryGB" -> Quiet @ Check[Round[$SystemMemory/2.^30, 0.1], Missing["Unknown"]],
    "WolframVersion" -> ToString[$VersionNumber],
    "GPUs" -> gpus,
    "GPUAvailable" -> (gpus =!= {}),
    "NvccPath" -> If[StringQ[nvcc], nvcc, Missing["NotFound"]],
    "NvccAvailable" -> StringQ[nvcc],
    "SubkernelTarget" -> SourceVaultSubkernelTarget[],
    "ProbedAtUTC" -> iSRNowUTC[]|>];

If[! ValueQ[$iSRProfile], $iSRProfile = None];

Options[SourceVaultMachineProfile] = {"Refresh" -> False};
SourceVaultMachineProfile[OptionsPattern[]] := (
  If[$iSRProfile === None || TrueQ[OptionValue["Refresh"]],
    (* probe は GPU/nvcc をまとめて再実測し、memo も更新する *)
    $iSRGPUs = None; $iSRNvccPath = None;
    $iSRProfile = iSRProbeProfile[];
    $iSRGPUs = Lookup[$iSRProfile, "GPUs", {}];
    $iSRNvccPath = Lookup[$iSRProfile, "NvccPath", Missing["NotFound"]] /.
      m_Missing :> Missing["NotFound"]];
  $iSRProfile);

iSRMachinesDir[] := Module[{pv = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
  If[StringQ[pv], FileNameJoin[{pv, "machines"}], $Failed]];

SourceVaultMachineProfileRefresh[] := Module[{prof, dir, path},
  prof = SourceVaultMachineProfile["Refresh" -> True];
  dir = iSRMachinesDir[];
  If[StringQ[dir],
    iSREnsureDir[dir];
    path = FileNameJoin[{dir, prof["MachineTag"] <> ".wl"}];
    iSRWriteWL[path, prof]];
  prof];

SourceVaultMachineSpecs[] := Module[{dir, files, all, self},
  dir = iSRMachinesDir[];
  files = If[StringQ[dir] && DirectoryQ[dir], FileNames["*.wl", dir], {}];
  all = Association @ Map[
    Function[f, Module[{a = Quiet @ Check[Get[f], $Failed]},
      If[AssociationQ[a], Lookup[a, "MachineTag", FileBaseName[f]] -> a, Nothing]]],
    files];
  (* 現在のマシンは常にライブ実測で上書き *)
  self = SourceVaultMachineProfile[];
  Append[all, self["MachineTag"] -> self]];

SourceVaultMachineSpecsView[] :=
  Dataset @ Map[
    Function[p, <|
      "Machine" -> Lookup[p, "MachineTag", "?"],
      "OS" -> Lookup[p, "OS", "?"],
      "Cores" -> Lookup[p, "ProcessorCount", Missing[]],
      "MemGB" -> Lookup[p, "MemoryGB", Missing[]],
      "GPU" -> With[{g = Lookup[p, "GPUs", {}]},
        If[g === {}, "-", StringRiffle[Lookup[#, "Name", "?"] & /@ g, "; "]]],
      "GPUMemMB" -> With[{g = Lookup[p, "GPUs", {}]},
        If[g === {}, "-", StringRiffle[ToString[Lookup[#, "MemoryMB", "?"]] & /@ g, "; "]]],
      "nvcc" -> TrueQ[Lookup[p, "NvccAvailable", False]],
      "Subkernels" -> Lookup[p, "SubkernelTarget", Missing[]],
      "ProbedAtUTC" -> Lookup[p, "ProbedAtUTC", ""]|>],
    Values[SourceVaultMachineSpecs[]]];

SourceVaultMachineSpecsText[] := Module[{specs = SourceVaultMachineSpecs[], rows},
  If[Length[specs] === 0,
    Return["(no machine profiles recorded; run SourceVaultMachineProfileRefresh[] on each PC)"]];
  rows = Map[
    Function[p, StringJoin[
      "- ", Lookup[p, "MachineTag", "?"],
      ": OS=", ToString @ Lookup[p, "OS", "?"],
      ", cores=", ToString @ Lookup[p, "ProcessorCount", "?"],
      ", memGB=", ToString @ Lookup[p, "MemoryGB", "?"],
      ", GPU=", With[{g = Lookup[p, "GPUs", {}]},
        If[g === {}, "none",
          StringRiffle[
            Map[ToString[Lookup[#, "Name", "?"]] <> " (" <>
              ToString[Lookup[#, "MemoryMB", "?"]] <> " MiB)" &, g], "; "]]],
      ", nvcc=", If[TrueQ[Lookup[p, "NvccAvailable", False]], "yes", "no"],
      ", subkernels=", ToString @ Lookup[p, "SubkernelTarget", "?"]]],
    Values[specs]];
  StringRiffle[rows, "\n"]];

(* ============================================================
   CUDA gate + compile
   ============================================================ *)

SourceVaultCUDARequire[] := Module[{gpus = iSRGPUs[], known},
  If[gpus =!= {},
    <|"OK" -> True, "GPUs" -> gpus|>,
    known = Select[Values[Quiet @ Check[SourceVaultMachineSpecs[], <||>]],
      Lookup[#, "GPUs", {}] =!= {} &];
    Failure["NoNvidiaGPU", <|
      "MessageTemplate" ->
        "this machine (`machine`) has no Nvidia GPU; run this CUDA workflow on: `targets`",
      "MessageParameters" -> <|
        "machine" -> iSRMachineTag[],
        "targets" -> If[known === {}, "(no GPU machine recorded yet)",
          StringRiffle[Lookup[#, "MachineTag", "?"] & /@ known, ", "]]|>|>]]];

Options[SourceVaultCUDACompile] = {"ExtraArgs" -> {}, "Force" -> False};

SourceVaultCUDACompile[cuFile_String, OptionsPattern[]] := Module[
  {nvcc, src, hash8, ls, binDir, exe, res, errText},
  If[! FileExistsQ[cuFile],
    Return[Failure["CompileFailed", <|
      "MessageTemplate" -> "CUDA source not found: `f`",
      "MessageParameters" -> <|"f" -> cuFile|>|>]]];
  nvcc = SourceVaultNvccPath[];
  If[! StringQ[nvcc],
    Return[Failure["NvccUnavailable", <|
      "MessageTemplate" ->
        "nvcc was not found on this machine (`machine`); install the CUDA toolkit or run on a GPU machine",
      "MessageParameters" -> <|"machine" -> iSRMachineTag[]|>|>]]];
  src = Quiet @ Check[ByteArrayToString[ReadByteArray[cuFile], "UTF-8"], ""];
  hash8 = StringTake[IntegerString[Hash[src, "SHA256"], 16, 64], 8];
  ls = Quiet @ Check[SourceVault`SourceVaultRoot["LocalState"], $Failed];
  binDir = If[StringQ[ls], FileNameJoin[{ls, "cudabin"}],
    FileNameJoin[{$TemporaryDirectory, "svcudabin"}]];
  iSREnsureDir[binDir];
  exe = FileNameJoin[{binDir, FileBaseName[cuFile] <> "-" <> hash8 <>
    If[$OperatingSystem === "Windows", ".exe", ""]}];
  If[FileExistsQ[exe] && ! TrueQ[OptionValue["Force"]], Return[exe]];
  res = Quiet @ Check[
    TimeConstrained[
      RunProcess[Join[{nvcc, "-O3", "-o", exe, cuFile}, OptionValue["ExtraArgs"]], All],
      600, $Failed],
    $Failed];
  If[AssociationQ[res] && res["ExitCode"] === 0 && FileExistsQ[exe],
    exe,
    errText = If[AssociationQ[res],
      StringTake[Lookup[res, "StandardError", ""] <> "\n" <> Lookup[res, "StandardOutput", ""],
        UpTo[1500]],
      "nvcc did not run (timeout or launch failure)"];
    Failure["CompileFailed", <|
      "MessageTemplate" -> "nvcc failed for `f`: `err`",
      "MessageParameters" -> <|"f" -> cuFile, "err" -> errText|>|>]]];

(* ============================================================
   サブカーネル burst
   ============================================================ *)

SetAttributes[SourceVaultWithSubkernels, HoldAll];

SourceVaultWithSubkernels[n_, body_] := Module[
  {nval, target, pre, need, launched},
  (* HoldAll なので n は明示評価する (変数渡し / Automatic の両対応) *)
  nval = n;
  target = If[nval === Automatic, SourceVaultSubkernelTarget[],
    If[IntegerQ[nval], Max[0, nval], SourceVaultSubkernelTarget[]]];
  pre = Quiet @ Check[Kernels[], {}];
  need = Max[0, target - Length[pre]];
  launched = If[need > 0, Quiet @ Check[LaunchKernels[need], {}], {}];
  If[! ListQ[launched], launched = {}];
  WithCleanup[
    body,
    (* body 実行中に増えたカーネル (自分の launch + ParallelMap 等の暗黙起動) を
       必ず停止して license 席を返す (standby)。元からあった分は残す。 *)
    Quiet @ Check[
      Module[{extra = Complement[Quiet @ Check[Kernels[], {}], pre]},
        If[extra =!= {}, CloseKernels[extra]]], Null]]];

SourceVaultWithSubkernels[body_] := SourceVaultWithSubkernels[Automatic, body];

(* ============================================================
   参照ベース実行フォルダ (SimulationRun)
   ============================================================ *)

If[! ValueQ[$SourceVaultSimRunRoot], $SourceVaultSimRunRoot = Automatic];

(* udb root = PrivateVault (<Dropbox>/udb/sourcevault) の親 *)
iSRUdbRoot[] := Module[{pv = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
  If[StringQ[pv], DirectoryName[pv], $Failed]];

SourceVaultSimRunRoot[] := Which[
  StringQ[$SourceVaultSimRunRoot] && $SourceVaultSimRunRoot =!= "",
    $SourceVaultSimRunRoot,
  StringQ[iSRUdbRoot[]],
    FileNameJoin[{iSRUdbRoot[], "simruns"}],
  True,
    FileNameJoin[{$TemporaryDirectory, "simruns"}]];

SourceVaultSimRunCreate[slug_String] := SourceVaultSimRunCreate[slug, <||>];

SourceVaultSimRunCreate[slug_String, params_Association] := Module[
  {root, tag, base, runId, folder, run, k = 2},
  root = SourceVaultSimRunRoot[];
  iSREnsureDir[root];
  tag = iSRMachineTag[];
  base = iSRStamp[] <> "-" <> tag <> "-" <> iSRSanitizeSlug[slug];
  runId = base;
  While[DirectoryQ[FileNameJoin[{root, runId}]] && k < 100,
    runId = base <> "-" <> ToString[k]; k++];
  folder = FileNameJoin[{root, runId}];
  iSREnsureDir[folder];
  run = <|
    "RunId" -> runId,
    "Folder" -> folder,
    "Slug" -> slug,
    "Machine" -> tag,
    "Params" -> params,
    "StartedAtUTC" -> iSRNowUTC[]|>;
  iSRWriteWL[FileNameJoin[{folder, "run.wl"}], run];
  run];

iSRScanFiles[folder_String] := Module[{files},
  files = Quiet @ Check[Select[FileNames["*", folder, Infinity], ! DirectoryQ[#] &], {}];
  Map[
    Function[f, <|
      "RelPath" -> StringReplace[
        StringDrop[f, StringLength[folder] + 1], "\\" -> "/"],
      "Bytes" -> Quiet @ Check[FileByteCount[f], 0]|>],
    files]];

SourceVaultSimRunFinalize[run_Association] := SourceVaultSimRunFinalize[run, <||>];

SourceVaultSimRunFinalize[run_Association, extra_Association] := Module[
  {folder, slug, files, total, udb, folderSym, rec, snap, ref, uri, status},
  folder = Lookup[run, "Folder", ""];
  slug = Lookup[run, "Slug", "run"];
  If[! (StringQ[folder] && DirectoryQ[folder]),
    Return[Failure["NoRunFolder", <|
      "MessageTemplate" -> "run folder does not exist: `f`",
      "MessageParameters" -> <|"f" -> folder|>|>]]];
  files = iSRScanFiles[folder];
  total = Total[Lookup[#, "Bytes", 0] & /@ files];
  udb = iSRUdbRoot[];
  folderSym = If[StringQ[udb] && StringStartsQ[folder, udb],
    StringReplace[StringTrim[StringDrop[folder, StringLength[udb]], "\\" | "/"], "\\" -> "/"],
    (* root が udb 外 (テスト等): 絶対パスをそのまま記録 *)
    StringReplace[folder, "\\" -> "/"]];
  status = Lookup[extra, "Status", "Done"];
  rec = Join[
    KeyDrop[run, {"Folder"}],
    <|
      "ObjectClass" -> "SimulationRun",
      "ExecutionClass" -> "simulation",
      "FolderSymbolic" -> folderSym,
      "FolderAbsoluteAtWrite" -> folder,
      "Files" -> files,
      "FileCount" -> Length[files],
      "TotalBytes" -> total,
      "MachineProfile" -> KeyTake[SourceVaultMachineProfile[],
        {"MachineTag", "OS", "ProcessorCount", "MemoryGB", "GPUs"}],
      "FinishedAtUTC" -> iSRNowUTC[],
      "Status" -> status|>,
    KeyDrop[extra, {"Status"}]];
  snap = Quiet @ Check[SourceVault`SourceVaultSaveImmutableSnapshot["SimulationRun", rec], $Failed];
  If[! AssociationQ[snap] || ! StringQ[Lookup[snap, "Ref", None]],
    Return[Failure["SaveFailed", <|
      "MessageTemplate" -> "could not save the SimulationRun snapshot for `id`",
      "MessageParameters" -> <|"id" -> Lookup[run, "RunId", "?"]|>|>]]];
  ref = snap["Ref"];
  uri = iSRRefToURI[ref];
  Quiet @ Check[
    SourceVault`SourceVaultAtomicUpdatePointer["simrun/" <> slug <> "/latest", ref], Null];
  Quiet @ Check[
    SourceVault`SourceVaultAppendEvent[<|
      "EventClass" -> "SimulationRun", "Slug" -> slug,
      "RunId" -> Lookup[run, "RunId", ""], "Machine" -> Lookup[run, "Machine", ""],
      "Status" -> status, "TotalBytes" -> total, "Value" -> ref|>], Null];
  (* run.wl も確定内容で更新 (フォルダ単体でも自己記述に) *)
  iSRWriteWL[FileNameJoin[{folder, "run.wl"}], Append[rec, "Ref" -> ref]];
  <|"Status" -> status, "URI" -> uri, "Ref" -> ref,
    "RunId" -> Lookup[run, "RunId", ""], "Folder" -> folder,
    "Files" -> files, "TotalBytes" -> total|>];

SourceVaultSimRunRecord[uriOrRef_String] := Module[{rec},
  rec = Quiet @ Check[
    SourceVault`SourceVaultLoadImmutableSnapshot[iSRURIToRef[uriOrRef]], $Failed];
  If[! AssociationQ[rec], Return[Missing["NotFound", uriOrRef]]];
  Join[rec, <|"Ref" -> iSRURIToRef[uriOrRef], "URI" -> iSRRefToURI[iSRURIToRef[uriOrRef]]|>]];

SourceVaultSimRunFolder[arg_String] := Module[{rec, sym, udb, path},
  rec = If[StringStartsQ[arg, "sv://"] || StringStartsQ[arg, "snapshot:"],
    SourceVaultSimRunRecord[arg], Missing["NotARef"]];
  Which[
    AssociationQ[rec],
      sym = Lookup[rec, "FolderSymbolic", ""];
      udb = iSRUdbRoot[];
      path = Which[
        StringQ[sym] && sym =!= "" && StringQ[udb] &&
          ! StringStartsQ[sym, "/"] && ! StringContainsQ[sym, ":"],
          FileNameJoin[Join[{udb}, StringSplit[sym, "/"]]],
        StringQ[sym] && sym =!= "",
          (* 絶対パスで記録されたもの (テスト等) *)
          FileNameJoin[StringSplit[sym, "/"]],
        True, ""],
    True,
      (* RunId 直指定: simrun root 配下 *)
      path = FileNameJoin[{SourceVaultSimRunRoot[], arg}]];
  Which[
    path === "", Missing["NotFound", arg],
    DirectoryQ[path], path,
    True, Missing["NotSynced", path]]];

SourceVaultSimRuns[slug_String] := Module[{h},
  h = Quiet @ Check[
    SourceVault`SourceVaultPointerHistory["simrun/" <> slug <> "/latest"], $Failed];
  If[! ListQ[h], Return[{}]];
  (* PointerHistory は Sequence 昇順 -> 新しい順に並べ替えて返す *)
  iSRRefToURI[Lookup[#, "Value", ""]] & /@
    ReverseSortBy[h, Lookup[#, "Sequence", 0] &]];

End[]
EndPackage[]

(* SourceVault.wl から自動ロードされるためロードバナーは出さない (他 subsystem と同様) *)
