# ローカル音声合成 (Piper) の導入

## 1. ランタイム

`piper-plus` (rhasspy/piper の多言語 + OpenJTalk 対応フォーク) の Windows ビルドを
取得し、次の形に展開します。

```
SourceVault_voice/tts/runtime/piper/
  bin/piper.exe          ← これが見つかればランタイムありと判定されます
  bin/*.dll
  lib/
  share/open_jtalk/dic/  ← 日本語の読み付与に必要 (約 103 MB)
  share/piper/dicts/     ← 英語 cmudict / 中国語 pinyin 辞書
```

`piper` をすでに PATH に通してある場合はそちらも自動で使われます
(`SourceVaultVoiceRuntime[]` の `"Executable"` に解決結果が出ます)。

置き場所を変えたい場合は次のどちらかで上書きできます。

```wolfram
SourceVault`$SourceVaultVoiceRoot = "D:\\voice";   (* D:\voice\tts\runtime\piper\bin\piper.exe *)
```

```
setx SOURCEVAULT_VOICE_ROOT D:\voice
```

## 2. 声モデル

**特定の声は前提にしていません。** 次のどちらかの形で置けば、その声が使われます。

```
tts/models/<声の名前>/<なんでも>.onnx
tts/models/<声の名前>/config.json
```

```
tts/models/<声の名前>.onnx
tts/models/<声の名前>.onnx.json     ← piper の素の配布形
```

声の名前 = フォルダ名 (またはファイル名) です。言語・サンプリング周波数・話者数・
推論の既定値 (`noise_scale` / `length_scale` / `noise_w`) は**すべて config から
読みます**。ハードコードされた値はありません。

確認:

```wolfram
SourceVaultVoices[]     (* 導入済みの声の一覧 *)
SourceVaultVoice[]      (* 既定として選ばれる声 *)
```

複数入れた場合、既定は**名前順の先頭**です (決定論的)。明示するなら:

```wolfram
SourceVault`$SourceVaultVoiceDefault = "tsukuyomi";
```

指定した声が後で消えても停止はせず、警告を出して先頭の声に落ちます。

## 3. 動作確認

```wolfram
SourceVaultVoiceView[]
SourceVaultVoiceSpeak["こんにちは。ローカル合成のテストです。"]
```

`SourceVaultVoiceSpeak` は `Audio` を返します。音声もテキストも外へ出ません。

## 声を選ぶときの注意

- **多言語の声** (config の `phoneme_type` が `multilingual`、または言語コードが
  `ja-en-zh-es-fr-pt` のようにハイフンを含む) にだけ、合成要求で `language` を
  渡します。単言語の声には渡しません — 渡すと拒否するビルドがあるためです。
  この判定は `SourceVaultVoices[]` の `"Multilingual"` に出ます。
- 日本語を読ませるなら `share/open_jtalk/dic/` が要ります。これが無いと日本語の
  声を入れてもランタイム側で読みが付きません。

## 実装上の注意 (この層を触る人向け)

piper への合成要求は **生の UTF-8 バイトで書き込みます** (`BinaryWrite`)。
`WriteLine` / `WriteString` は stream の文字エンコーディングで符号化するため、
`$CharacterEncoding` が UTF-8 でないカーネル (日本語 Windows の FE メインカーネルは
既定 ShiftJIS) では JSON 内の日本語が化け、piper が要求を読めずに即終了します。
そのときの症状は **stdout が `EndOfFile` になるだけ**で、原因がまったく見えません。

回帰テストが `test codes/sourcevault_voice_test.wls` にあります (UTF-8 / ShiftJIS /
ASCII / ISOLatin1 の 4 通りで日本語合成を通します)。

```
wolframscript -file "test codes/sourcevault_voice_test.wls"
```

## ライセンス

ランタイムと声モデルはそれぞれ配布元のライセンスに従います。**声モデルは商用
利用の可否や表記義務が個別に定められていることが多い**ので、使う前に配布元の
条件を確認してください。ここに置いたものは公開リポジトリへは入りません
(`upload_manifest.json` の `excludePatterns` で除外済み)。
