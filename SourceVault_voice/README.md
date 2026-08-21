# SourceVault_voice — ローカル音声資産

このフォルダは **credential-free なローカル音声処理**の資産置き場です。合成 (TTS) も
認識 (ASR) もこの機械の中で完結し、テキストも音声もネットワークへ出ません。

解決・列挙・導入は [`SourceVault_voice.wl`](../SourceVault_voice.wl) が行います。

```
SourceVault_voice/
  tts/
    runtime/piper/   Piper Plus ランタイム   … リポジトリ非同梱
    models/<voice>/  声モデル (.onnx + json) … リポジトリ非同梱
  asr/
    models/<model>/  Vosk モデル             … リポジトリ非同梱
```

## なぜ実体が同梱されていないのか

`runtime/` と `models/` と `asr/` の中身は**第三者の配布物**で、ライセンス条件が
配布元・声ごとに異なります (声モデルは商用利用の可否や表記義務が個別に定められて
いることが多く、一括で再配布できません)。加えて Piper のランタイムには 103 MB の
OpenJTalk 辞書が含まれ、GitHub の 1 ファイル 100 MB 制限を超えます。

そのため `upload_manifest.json` の `excludePatterns` で以下を恒久的に除外しています。

```
SourceVault_voice/tts/runtime/
SourceVault_voice/tts/models/
SourceVault_voice/asr/models/
```

**この 3 行は消さないでください。** 消すと手元の声モデルが公開リポジトリへ入ります。

## 何も入れなくても動くか

動きます。導入されていない資産は「無い」として扱われ、それを必要とする機能だけが
静かに落ちます。呼び出し側 (例: VRCRealtime) は起動を止めず、何が足りないかを
報告します。状態はいつでも次で確認できます。

```wolfram
SourceVaultVoiceView[]      (* 表示つき *)
SourceVaultVoiceStatus[]    (* Association *)
SourceVaultVoiceInstallHint[]  (* 足りない物の導入手順だけ *)
```

## 導入

- 合成ランタイムと声 → [`tts/README.md`](tts/README.md)
- 音声認識モデル → [`asr/README.md`](asr/README.md)

各資産の出所とライセンスは [`sources.json`](sources.json) にあります。
