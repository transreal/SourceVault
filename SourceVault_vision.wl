(* ::Package:: *)

(* ============================================================
   SourceVault_vision.wl -- local (credential-free) vision model assets layer
     MediaPipe person detection / pose landmark ONNX models

   This file is encoded in UTF-8.
   Load order: SourceVault.wl -> SourceVault_core.wl -> SourceVault_vision.wl
   Load via:   Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_vision.wl"]]

   == なぜ SourceVault 管轄か ==
     人物検出・姿勢推定はどの用途からも使えるローカル推論資産で、特定の
     アプリ (VRChat 連携など) の持ち物ではない。フレームが機械の外へ出ない
     ことが要件である点も SourceVault の privacy 契約と同じ筋にある。

   == このファイルが実装する範囲 ==
     - モデル資産 root の解決 (複数 root を横断走査、書き込み先は 1 つ)。
     - 同梱モデルの目録 (出所 / ライセンス / SHA256) と実在確認。
     - 欠けている場合の配布元からの取得 (SHA256 検証つき)。
     - SourceVaultVisionStatus[] : 何が欠けていて、どう入れるか。

   == このファイルが実装しない範囲 ==
     - 推論そのもの。前処理・アンカー生成・NMS は利用側 (OpenCV DNN を使う
       Python 実装) が持つ。ここは「どのファイルを読ませるか」の解決層。

   == 資産の置き場と配布 ==
     $packageDirectory/SourceVault_vision/
       <model-dir>/<model>.onnx + NOTICE.md
     モデルは OpenCV Model Zoo の Apache-2.0 配布物で、NOTICE つきの再配布が
     許されるためリポジトリに同梱する。欠けていても取得できる。
   ============================================================ *)

BeginPackage["SourceVault`"];

$SourceVaultVisionRoot::usage =
  "$SourceVaultVisionRoot はローカル視覚モデル資産の root ディレクトリ override。既定 None。";

$SourceVaultVisionModelCatalog::usage =
  "$SourceVaultVisionModelCatalog は既知の視覚モデルの目録 (名前 -> <|\"Directory\", \"File\", \"URL\", \"SHA256\", \"License\", \"Source\", \"Task\"|>)。";

SourceVaultVisionRoot::usage =
  "SourceVaultVisionRoot[] は視覚モデル資産の root を返す。";

SourceVaultVisionSearchPath::usage =
  "SourceVaultVisionSearchPath[] は視覚モデルを探す root の一覧を優先順に返す。";

SourceVaultVisionModels::usage =
  "SourceVaultVisionModels[] は既知の視覚モデルの一覧を Association のリストで返す。\n" <>
  "各要素: \"Name\", \"Task\", \"Path\" (未導入なら None), \"Present\", \"License\", \"Source\"。";

SourceVaultVisionModel::usage =
  "SourceVaultVisionModel[name] は視覚モデルの絶対パスを返す。未導入なら Failure を返す。\n" <>
  "name は \"PersonDetector\" / \"PoseEstimator\" など $SourceVaultVisionModelCatalog の鍵。";

SourceVaultVisionStatus::usage =
  "SourceVaultVisionStatus[] は視覚モデル資産の総合状態 (\"Status\", \"Missing\", \"Models\", \"Hint\") を返す。";

SourceVaultVisionView::usage =
  "SourceVaultVisionView[] は SourceVaultVisionStatus[] を Dataset / Grid で表示する。";

SourceVaultInstallVisionModel::usage =
  "SourceVaultInstallVisionModel[name] は配布元から視覚モデルを取得して導入する (SHA256 検証つき)。\n" <>
  "SourceVaultInstallVisionModel[] は目録の全モデルについて、欠けているものだけ取得する。";

Begin["`Private`"];

If[! ValueQ[SourceVault`$SourceVaultVisionRoot],
  SourceVault`$SourceVaultVisionRoot = None];

SourceVault`$SourceVaultVisionModelCatalog = <|
  "PersonDetector" -> <|
    "Task" -> "人物検出 (MediaPipe Pose detector, 224px)",
    "Directory" -> "person_detection_mediapipe",
    "File" -> "person_detection_mediapipe_2023mar.onnx",
    "URL" -> "https://github.com/opencv/opencv_zoo/raw/main/models/person_detection_mediapipe/person_detection_mediapipe_2023mar.onnx",
    "SHA256" -> "47fd5599d6fa17608f03e0eb0ae230baa6e597d7e8a2c8199fe00abea55a701f",
    "License" -> "Apache-2.0",
    "Source" -> "https://github.com/opencv/opencv_zoo/tree/main/models/person_detection_mediapipe"|>,
  "PoseEstimator" -> <|
    "Task" -> "姿勢ランドマーク (MediaPipe BlazePose, 33 keypoints, 256px)",
    "Directory" -> "pose_estimation_mediapipe",
    "File" -> "pose_estimation_mediapipe_2023mar.onnx",
    "URL" -> "https://github.com/opencv/opencv_zoo/raw/main/models/pose_estimation_mediapipe/pose_estimation_mediapipe_2023mar.onnx",
    "SHA256" -> "9d89c599319a18fb7d2e28451a883476164543182bafca5f09eb2cf767ed2f3f",
    "License" -> "Apache-2.0",
    "Source" -> "https://github.com/opencv/opencv_zoo/tree/main/models/pose_estimation_mediapipe"|>
|>;

iVisStringQ[x_] := StringQ[x] && StringLength[x] > 0;
iVisDir[p_] := iVisStringQ[p] && Quiet @ Check[DirectoryQ[p], False];
iVisFile[p_] := iVisStringQ[p] && Quiet @ Check[FileExistsQ[p], False];

iVisEnv[name_String] := Module[{v},
  v = Quiet @ Check[Environment[name], $Failed];
  If[iVisStringQ[v], v, ""]];

iVisPackageDirectory[] := Module[{d},
  d = Quiet @ Check[Global`$packageDirectory, ""];
  If[iVisDir[d], Return[d]];
  d = Quiet @ Check[DirectoryName[$InputFileName], ""];
  If[iVisDir[d], d, ""]];

iVisLocalAppData[] := Module[{b},
  b = iVisEnv["LOCALAPPDATA"];
  If[iVisStringQ[b], Return[b]];
  b = Quiet @ Check[$HomeDirectory, ""];
  If[iVisStringQ[b], FileNameJoin[{b, ".local", "share"}], ""]];

SourceVaultVisionSearchPath[] := Module[{roots = {}, pkg, lad},
  If[iVisStringQ[SourceVault`$SourceVaultVisionRoot],
    AppendTo[roots, SourceVault`$SourceVaultVisionRoot]];
  With[{e = iVisEnv["SOURCEVAULT_VISION_ROOT"]},
    If[iVisStringQ[e], AppendTo[roots, e]]];
  pkg = iVisPackageDirectory[];
  If[iVisStringQ[pkg],
    AppendTo[roots, FileNameJoin[{pkg, "SourceVault_vision"}]]];
  lad = iVisLocalAppData[];
  If[iVisStringQ[lad],
    AppendTo[roots, FileNameJoin[{lad, "SourceVault", "vision"}]]];
  DeleteDuplicates[Select[roots, iVisStringQ]]];

SourceVaultVisionRoot[] := Module[{paths, existing},
  paths = SourceVaultVisionSearchPath[];
  If[paths === {}, Return[""]];
  existing = Select[paths, iVisDir];
  If[existing =!= {}, First[existing], First[paths]]];

iVisWritableRoot[] := Module[{paths},
  paths = SourceVaultVisionSearchPath[];
  If[paths === {}, "", First[paths]]];

(* 目録の 1 エントリを、実在する root 上で解決する *)
iVisResolve[entry_Association] := Module[{rel, hit},
  rel = {entry["Directory"], entry["File"]};
  hit = SelectFirst[
    (FileNameJoin[Flatten[{#, rel}]] &) /@ SourceVaultVisionSearchPath[],
    iVisFile, None];
  If[hit === None, None, hit]];

SourceVaultVisionModels[] :=
  KeyValueMap[
    Function[{name, entry},
      With[{path = iVisResolve[entry]},
        <|"Name" -> name,
          "Task" -> entry["Task"],
          "Path" -> path,
          "Present" -> (path =!= None),
          "License" -> entry["License"],
          "Source" -> entry["Source"]|>]],
    SourceVault`$SourceVaultVisionModelCatalog];

SourceVaultVisionModel[name_String] := Module[{entry, path},
  entry = Lookup[SourceVault`$SourceVaultVisionModelCatalog, name, Missing["NoEntry"]];
  If[! AssociationQ[entry],
    Return[Failure["SourceVaultVisionUnknownModel", <|
      "MessageTemplate" -> "未知の視覚モデル名です: " <> name,
      "Available" -> Keys[SourceVault`$SourceVaultVisionModelCatalog]|>]]];
  path = iVisResolve[entry];
  If[path === None,
    Failure["SourceVaultVisionModelUnavailable", <|
      "MessageTemplate" -> "視覚モデルが未導入です: " <> name,
      "Hint" -> iVisHint[name],
      "SearchPath" -> SourceVaultVisionSearchPath[]|>],
    path]];

iVisHint[name_String] :=
  "視覚モデル " <> name <> " が見つかりません。\n" <>
  "  SourceVaultInstallVisionModel[\"" <> name <> "\"]\n" <>
  "で " <> FileNameJoin[{iVisWritableRoot[]}] <> " へ取得できます\n" <>
  "(配布元 " <> Lookup[Lookup[SourceVault`$SourceVaultVisionModelCatalog, name, <||>],
    "Source", "OpenCV Model Zoo"] <> ")。";

SourceVaultVisionStatus[] := Module[{models, missing},
  models = SourceVaultVisionModels[];
  missing = #["Name"] & /@ Select[models, ! TrueQ[#["Present"]] &];
  <|
    "Status" -> If[missing === {}, "OK", "Incomplete"],
    "Missing" -> missing,
    "Root" -> SourceVaultVisionRoot[],
    "SearchPath" -> SourceVaultVisionSearchPath[],
    "Models" -> models,
    "Hint" -> If[missing === {}, None,
      StringRiffle[iVisHint /@ missing, "\n\n"]]
  |>];

SourceVaultVisionView[] := Module[{st},
  st = SourceVaultVisionStatus[];
  Column[{
    Style["SourceVault ローカル視覚モデル", Bold],
    Grid[{
      {"状態", st["Status"]},
      {"不足", If[st["Missing"] === {}, "なし", StringRiffle[st["Missing"], ", "]]},
      {"root", st["Root"]}},
      Alignment -> Left, Frame -> All, FrameStyle -> LightGray],
    Dataset[KeyTake[#, {"Name", "Task", "Present", "License", "Path"}] & /@ st["Models"]],
    If[st["Hint"] === None, Nothing,
      Style[st["Hint"], Gray, FontFamily -> "Consolas", FontSize -> 11]]
  }, Alignment -> Left, Spacings -> 1]];

SourceVaultInstallVisionModel[] :=
  Module[{names},
    names = #["Name"] & /@ Select[SourceVaultVisionModels[], ! TrueQ[#["Present"]] &];
    If[names === {},
      Return[<|"Status" -> "OK", "Reason" -> "AlreadyInstalled", "Installed" -> {}|>]];
    <|"Status" -> "OK", "Results" -> (SourceVaultInstallVisionModel /@ names)|>];

SourceVaultInstallVisionModel[name_String] :=
  Module[{entry, dir, target, tmp, dl, digest},
    entry = Lookup[SourceVault`$SourceVaultVisionModelCatalog, name, Missing["NoEntry"]];
    If[! AssociationQ[entry],
      Return[<|"Status" -> "Error", "Reason" -> "UnknownModel", "Name" -> name,
        "Available" -> Keys[SourceVault`$SourceVaultVisionModelCatalog]|>]];
    If[iVisResolve[entry] =!= None,
      Return[<|"Status" -> "OK", "Reason" -> "AlreadyInstalled", "Name" -> name,
        "Path" -> iVisResolve[entry]|>]];
    dir = FileNameJoin[{iVisWritableRoot[], entry["Directory"]}];
    Quiet @ Check[CreateDirectory[dir, CreateIntermediateDirectories -> True], Null];
    If[! iVisDir[dir],
      Return[<|"Status" -> "Error", "Reason" -> "TargetDirectoryUnavailable", "Directory" -> dir|>]];
    target = FileNameJoin[{dir, entry["File"]}];
    tmp = target <> ".part";
    dl = Quiet @ Check[URLDownload[entry["URL"], tmp], $Failed];
    If[dl === $Failed || ! iVisFile[tmp],
      Quiet @ DeleteFile[tmp];
      Return[<|"Status" -> "Error", "Reason" -> "DownloadFailed",
        "Name" -> name, "URL" -> entry["URL"]|>]];
    digest = Quiet @ Check[FileHash[tmp, "SHA256", "HexString"], $Failed];
    If[! StringQ[digest] || ToLowerCase[digest] =!= ToLowerCase[entry["SHA256"]],
      Quiet @ DeleteFile[tmp];
      Return[<|"Status" -> "Error", "Reason" -> "ChecksumMismatch",
        "Name" -> name, "Expected" -> entry["SHA256"], "Actual" -> digest|>]];
    Quiet @ Check[RenameFile[tmp, target, OverwriteTarget -> True], Null];
    If[iVisFile[target],
      <|"Status" -> "OK", "Reason" -> "Installed", "Name" -> name, "Path" -> target,
        "License" -> entry["License"]|>,
      <|"Status" -> "Error", "Reason" -> "InstallFailed", "Name" -> name|>]];

End[];

EndPackage[];
