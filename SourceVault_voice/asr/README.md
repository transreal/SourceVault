# ローカル音声認識 (Vosk) モデルの導入

文法制約つきのキーワード検出に使う小型モデルです。音声はこの機械から出ません。

## 導入

```wolfram
SourceVaultInstallSpeechModel[]        (* 日本語小モデル vosk-model-small-ja-0.22、約 50 MB *)
SourceVaultInstallSpeechModel["en"]    (* 英語小モデル *)
```

導入済みなら何もしません (冪等)。展開先は `models/` の下です。

```
SourceVault_voice/asr/models/vosk-model-small-ja-0.22/
  am/final.mdl     ← これと graph/ があれば導入済みと判定されます
  graph/
  ...
```

`asr/` 直下に置いても認識しますが、正準は `asr/models/` です (この README を同梱しつつ
モデル本体だけを `excludePatterns` で除外できるように、`tts/` と対称な形にしてあります)。

手で入れる場合も同じ形に展開すれば認識されます。取得できるモデルの一覧は
`SourceVault`$SourceVaultVoiceSpeechModelCatalog` にあります。

## 確認

```wolfram
SourceVaultSpeechModels[]           (* 導入済みモデルの一覧 *)
SourceVaultSpeechModel[]            (* 既定として選ばれるモデル *)
SourceVaultSpeechModelDirectory[]   (* 導入先 *)
```

## 旧い置き場からの移行

以前 VRCRealtime が使っていた `%LOCALAPPDATA%\VRCRealtime\models\` も**読み取りだけ**
互換で探します。すでにそこにモデルがある人は何もしなくて構いません。新しく導入する
ものはこのフォルダに入ります。

## ライセンス

Vosk のモデルは Apache-2.0 で配布されています。実体はリポジトリに同梱していません
(`upload_manifest.json` の `excludePatterns` で除外済み)。
