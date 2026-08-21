# SourceVault_vision — ローカル視覚モデル

このフォルダは **credential-free なローカル推論**用の ONNX モデル置き場です。
フレームはこの機械から出ません。

解決・列挙・導入は [`SourceVault_vision.wl`](../SourceVault_vision.wl) が行います。

```
SourceVault_vision/
  person_detection_mediapipe/    人物検出 (MediaPipe Pose detector, 224px)
  pose_estimation_mediapipe/     姿勢ランドマーク (BlazePose, 33 keypoints, 256px)
```

## 同梱について

こちらは音声資産と違い、**モデル本体をリポジトリに同梱しています**。OpenCV Model
Zoo の Apache-2.0 配布物で、NOTICE つきの再配布が許されているためです。各フォルダの
`NOTICE.md` に出所を記載しています。

## 確認と導入

```wolfram
SourceVaultVisionView[]                          (* 状態表示 *)
SourceVaultVisionModel["PersonDetector"]         (* 絶対パス、未導入なら Failure *)
SourceVaultVisionModel["PoseEstimator"]
SourceVaultInstallVisionModel[]                  (* 欠けている物だけ配布元から取得 *)
```

`SourceVaultInstallVisionModel` は目録に記録された SHA256 と照合し、一致しなければ
破棄します。目録は `SourceVault`$SourceVaultVisionModelCatalog` にあります。

置き場所を変えたい場合:

```wolfram
SourceVault`$SourceVaultVisionRoot = "D:\\vision";
```

```
setx SOURCEVAULT_VISION_ROOT D:\vision
```

Python 側からも同じ環境変数 `SOURCEVAULT_VISION_ROOT` が効きます。

## ライセンス

`person_detection_mediapipe` / `pose_estimation_mediapipe` はいずれも
[OpenCV Model Zoo](https://github.com/opencv/opencv_zoo) 由来で Apache-2.0 です。
詳細は各フォルダの `NOTICE.md` を参照してください。
