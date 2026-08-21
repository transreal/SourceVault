# SourceVault_voice API Reference

Local (credential-free) voice assets layer: Piper Plus TTS runtime/voice models, Vosk ASR models. Implements the execution side of SourceVault's Privacy.Level contract — resources with PL >= 0.5 must not be sent to external endpoints (e.g. OpenAI), so this package provides local speech synthesis; Vosk ASR is included for the same reason (audio must not leave the machine).

Load order: SourceVault.wl -> SourceVault_core.wl -> SourceVault_voice.wl. Load via `Block[{$CharacterEncoding -> "UTF-8"}, Get["SourceVault_voice.wl"]]`.

Scope: resolves which executable and which voice/model to use (asset discovery, selection, status reporting, install helpers) and offers one thin synthesis call. Conversation-level concerns (VAD, barge-in, privacy scrub, playback cutoff) belong to the caller (e.g. VRCRealtime's private TTS broker), not here.

Asset layout under `$packageDirectory/SourceVault_voice/` (third-party distributions, not repo-tracked — only README/sources.json ship in-repo):
- `tts/runtime/` — Piper Plus runtime (executable + bin/share/lib)
- `tts/models/` — voice models (one folder per voice, or flat .onnx files)
- `asr/` — Vosk ASR models

No specific voice (e.g. "tsukuyomi") is hardcoded; voice name/language/sample rate/inference defaults are read from each voice's `config.json` / `<model>.onnx.json`.

## Configuration

### $SourceVaultVoiceRoot
型: String | None, 初期値: None
Override root directory for local voice assets. When None, SourceVaultVoiceSearchPath[] order is used instead.

### $SourceVaultVoiceDefault
型: String | Automatic, 初期値: Automatic
Name of the default voice returned by SourceVaultVoice[] (voice model folder or file name). Automatic picks the first installed voice in name order (deterministic).

### $SourceVaultVoiceSpeechModelDefault
型: String | Automatic, 初期値: Automatic
Name of the default ASR model returned by SourceVaultSpeechModel[].

### $SourceVaultVoiceSpeechModelCatalog
型: Association, 初期値: <|"ja" -> <|"Name" -> "vosk-model-small-ja-0.22", "URL" -> ..., "ApproxMB" -> 48, "License" -> "Apache-2.0"|>, "en" -> <|"Name" -> "vosk-model-small-en-us-0.15", "URL" -> ..., "ApproxMB" -> 40, "License" -> "Apache-2.0"|>|>
ASR models installable via SourceVaultInstallSpeechModel, keyed by language code. Each entry has "Name", "URL", "ApproxMB", "License".

## Root / Search Path

### SourceVaultVoiceSearchPath[] → List[String]
Ordered list of candidate roots for voice assets: $SourceVaultVoiceRoot override, then `SOURCEVAULT_VOICE_ROOT` env var, then `$packageDirectory/SourceVault_voice`, then `%LOCALAPPDATA%/SourceVault/voice`, then the legacy `%LOCALAPPDATA%/VRCRealtime` (read-only compatibility, never a write target).

### SourceVaultVoiceRoot[] → String
Write-destination root for voice assets: first existing directory among SourceVaultVoiceSearchPath[], else the first candidate path (may not exist yet). The legacy VRCRealtime compat root is never selected as a write target.

## TTS Runtime (Piper Plus)

### SourceVaultVoiceRuntime[] → Association
Locates the Piper Plus executable. Searches `<root>/tts/runtime/piper/bin/piper[.exe]` and `<root>/tts/runtime/piper/piper[.exe]` across all search-path roots, then falls back to `PATH`.
Returns `<|"Status" -> "OK"|"Missing", "Engine" -> "PiperPlus", "Executable" -> path|None, "Root" -> ..., "Hint" -> string|None|>`.

## Voice Models

### SourceVaultVoices[] → List[Association]
Installed voice models across all search-path roots, sorted by name, deduplicated by name (first root found wins). Each element: `<|"Name", "Engine" -> "PiperPlus", "Model" (.onnx path), "Config" (.json path or None), "Language", "SampleRate", "Speakers", "NoiseScale", "LengthScale", "NoiseW", "Multilingual" (Boolean — True if config phoneme_type is "multilingual" or Language contains "-"; only multilingual voices accept a "language" field in a synthesis request), "Root"|>`.
Voices are discovered as `<root>/tts/models/<voice-name>/*.onnx` (one folder per voice) or flat `<root>/tts/models/*.onnx`. Config is read from `<model>.onnx.json`, else `config.json` in the same folder, else the sole `*.json` in that folder; missing config falls back to defaults (SampleRate 22050, Speakers 1, NoiseScale 0.667, LengthScale 1, NoiseW 0.8).

### SourceVaultVoice[] → Association | Failure
Default voice: uses $SourceVaultVoiceDefault by name if set and present (else issues `SourceVaultVoice::novoice` and falls back), otherwise the first voice in SourceVaultVoices[] (name order). Returns `Failure["SourceVaultVoiceUnavailable", ...]` with "Hint" and "SearchPath" if none installed.

### SourceVaultVoice[name] → Association | Failure
Look up a voice by name. Returns `Failure["SourceVaultVoiceUnavailable", ...]` with "Hint" and "Available" (list of names) if not found.

### SourceVaultVoiceAvailableQ[] → Boolean
True iff SourceVaultVoiceRuntime[]["Status"] === "OK" and SourceVaultVoices[] is non-empty.

## Status / Diagnostics

### SourceVaultVoiceStatus[] → Association
Single source of truth for what's missing and how to install it.
Returns `<|"Status" -> "OK"|"Incomplete", "Missing" -> {"TTSRuntime", "TTSVoice", "SpeechModel"} subset, "Root", "SearchPath", "Runtime" (SourceVaultVoiceRuntime[] result), "Voices" (SourceVaultVoices[] result), "DefaultVoice" (SourceVaultVoice[] result or None), "SpeechModels" (SourceVaultSpeechModels[] result), "Hint" -> combined multi-line string or None|>`.

### SourceVaultVoiceInstallHint[] → String
Install instructions for whatever's missing (from SourceVaultVoiceStatus[]["Hint"]), or a "everything is installed" message if nothing is missing.

### SourceVaultVoiceView[] → Column
Human-readable Dataset/Grid view of SourceVaultVoiceStatus[] (status, missing items, root, runtime executable, voice table, speech-model table, hints). For notebook display, not for machine consumption.

## Synthesis

### SourceVaultVoiceSpeak[text, opts]
Synthesizes `text` locally via the resolved Piper runtime/voice and returns an Audio object (neither text nor audio leaves the machine). Requires SourceVaultVoiceRuntime[] and a resolved voice to be available, else returns Failure.
→ Audio | Failure
Options: "Voice" -> Automatic (voice name string, or Automatic for SourceVaultVoice[]), "OutputFile" -> Automatic (output .wav path, or Automatic for a temp file), "LengthScale" -> Automatic (overrides the voice's config LengthScale), "NoiseScale" -> Automatic (overrides the voice's config NoiseScale), "TimeConstraint" -> 120 (seconds to wait for the synthesis response line)
Sends a JSON request (`text`, `output_file`, `speaker_id` -> 0, `noise_scale`, `length_scale`, plus `language` only when the voice is Multilingual) as raw UTF-8 bytes over the piper process's stdin (`--json-input --quiet`), reads one response line, then kills the process. On failure returns `Failure["SourceVaultVoiceSynthesisFailed", ...]` with "Response", "StandardError", "Executable", "Model", "Hint".
例: `SourceVaultVoiceSpeak["こんにちは", "Voice" -> "tsukuyomi", "OutputFile" -> "C:\\tmp\\out.wav"]`

## ASR (Vosk)

### SourceVaultSpeechModels[] → List[Association]
Installed local ASR (Vosk) models across all search-path roots, sorted/deduplicated by name. Each element: `<|"Name", "Engine" -> "Vosk", "Directory", "Root"|>`. Discovered under `<root>/asr/models/<name>`, `<root>/asr/<name>`, or `<root>/models/<name>` (legacy), where a model is "present" iff it has `am/final.mdl` and a `graph/` directory.

### SourceVaultSpeechModel[] → Association | Failure
Default ASR model: uses $SourceVaultVoiceSpeechModelDefault by name if set and present, otherwise the first in SourceVaultSpeechModels[]. Returns `Failure["SourceVaultSpeechModelUnavailable", ...]` with "Hint" and "SearchPath" if none installed.

### SourceVaultSpeechModel[name] → Association | Failure
Look up an ASR model by name. Returns `Failure["SourceVaultSpeechModelUnavailable", ...]` with "Hint" and "Available" if not found.

### SourceVaultSpeechModelDirectory[] → String
Install-destination directory for ASR models: `<writable-root>/asr/models`.

### SourceVaultInstallSpeechModel[] → Association
Equivalent to `SourceVaultInstallSpeechModel["ja"]`.

### SourceVaultInstallSpeechModel[language] → Association
Downloads and installs the ASR model for `language` from $SourceVaultVoiceSpeechModelCatalog (e.g. "ja" for vosk-model-small-ja-0.22, ~48 MB; "en" for vosk-model-small-en-us-0.15, ~40 MB) into SourceVaultSpeechModelDirectory[]. Idempotent — no-op if already installed. Handles zip extraction and renames the extracted folder to match the catalog name if needed.
Returns `<|"Status" -> "OK"|"Error", "Reason" -> "AlreadyInstalled"|"Installed"|"UnknownLanguage"|"TargetDirectoryUnavailable"|"DownloadFailed"|"ExtractFailed"|"ModelIncomplete", "Name", "Directory", "License", ...|>`. On "UnknownLanguage", "Available" lists valid catalog keys.