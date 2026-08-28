# SourceVault_voice API Reference

Local (credential-free) voice assets layer: Piper Plus TTS runtime/voice models, AivisSpeech Engine (VOICEVOX-compatible local HTTP TTS), Vosk ASR models. Implements the execution side of SourceVault's Privacy.Level contract — resources with PL >= 0.5 must not be sent to external endpoints (e.g. OpenAI), so this package provides local speech synthesis; Vosk ASR is included for the same reason (audio must not leave the machine).

Load order: SourceVault.wl -> SourceVault_core.wl -> SourceVault_voice.wl. Load via `Block[{$CharacterEncoding -> "UTF-8"}, Get["SourceVault_voice.wl"]]`.

Scope: resolves which executable and which voice/model to use (asset discovery, selection, status reporting, install helpers) and offers one thin synthesis call. Conversation-level concerns (VAD, barge-in, privacy scrub, playback cutoff) belong to the caller (e.g. VRCRealtime's private TTS broker), not here.

Asset layout under `$packageDirectory/SourceVault_voice/` (third-party distributions, not repo-tracked — only README/sources.json ship in-repo):
- `tts/runtime/` — Piper Plus runtime (executable + bin/share/lib)
- `tts/models/` — voice models (one folder per voice, or flat .onnx files)
- `asr/` — Vosk ASR models

No specific voice (e.g. "tsukuyomi") is hardcoded; voice name/language/sample rate/inference defaults are read from each voice's `config.json` / `<model>.onnx.json`.

A second TTS engine, AivisSpeech Engine (Style-Bert-VITS2 based, VOICEVOX-compatible HTTP API on localhost), is supported alongside Piper. Its speakers are enumerated from the running engine (`/speakers`) and appear in the same SourceVaultVoices[] list normalized to the same Association shape (`"Engine" -> "AivisSpeech"`). Synthesis requests stay on localhost; the engine itself contacts AivisHub at startup for model update checks. The persistent default voice lives in `<root>/local/voice_config.json` (not repo-tracked).

## Configuration

### $SourceVaultVoiceRoot
型: String | None, 初期値: None
Override root directory for local voice assets. When None, SourceVaultVoiceSearchPath[] order is used instead.

### $SourceVaultVoiceDefault
型: String | Automatic, 初期値: Automatic
Session override for the default voice name returned by SourceVaultVoice[] (exact or prefix match). Automatic falls through to the persisted default in `<root>/local/voice_config.json` (see SourceVaultVoiceSetDefault), then to the first installed voice in name order (deterministic).

### $SourceVaultVoiceAivisEndpoint
型: String, 初期値: "http://127.0.0.1:10101"
HTTP endpoint of the AivisSpeech Engine.

### $SourceVaultVoiceAivisExecutable
型: Automatic | String | None, 初期値: Automatic
How to locate the engine executable (run.exe). Automatic searches the `SOURCEVAULT_AIVIS_ENGINE` env var, `%LOCALAPPDATA%/Programs/AivisSpeech-Engine/Windows-x64/run.exe`, the desktop-app bundle paths. A path string uses only that file; None disables the engine.

### $SourceVaultVoiceAivisAutoStart
型: Boolean, 初期値: True
When True and an AivisSpeech voice is needed but the engine is not running, SourceVaultVoiceSpeak starts it once per kernel (localhost endpoints only). While the started process is alive but not yet answering, later calls wait again instead of failing (a first boot loads models and can exceed 90 s).

### $SourceVaultVoiceAivisStartTimeout
型: Number, 初期値: 180.
Seconds to wait for the engine to answer after an auto-start.

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

## TTS Engine 2 (AivisSpeech Engine)

### SourceVaultVoiceAivisStatus[] → Association
State of the AivisSpeech Engine: `<|"Status" -> "Running"|"Installed"|"Missing", "Engine" -> "AivisSpeech", "Endpoint", "Version" (string when Running), "Executable" (path or None), "Voices" (speaker names when Running), "Hint"|>`. "Installed" means the executable was found but the server is not responding; SourceVaultVoiceSpeak auto-starts it when an AivisSpeech voice is needed (once per kernel, localhost only, `$SourceVaultVoiceAivisAutoStart`).

### SourceVaultVoiceAivisEnsure[] → Boolean
Makes sure the AivisSpeech Engine is responding, returning True|False. If not running (and `$SourceVaultVoiceAivisAutoStart` allows it and the endpoint is localhost), attempts one auto-start and waits up to `$SourceVaultVoiceAivisStartTimeout` seconds; if a previously-started process is still coming up, waits again instead of relaunching. Intended for external callers (e.g. VRCRealtime) that need the engine ready before speaking, independent of SourceVaultVoiceSpeak.

## Voice Models

### SourceVaultVoices[] → List[Association]
Installed voices across both engines, sorted by name, deduplicated by name (AivisSpeech wins over Piper, then first root found). Piper element: `<|"Name", "Engine" -> "PiperPlus", "Model" (.onnx path), "Config" (.json path or None), "Language", "SampleRate", "Speakers", "NoiseScale", "LengthScale", "NoiseW", "Multilingual" (Boolean — True if config phoneme_type is "multilingual" or Language contains "-"; only multilingual voices accept a "language" field in a synthesis request), "Root"|>`. AivisSpeech element: same keys plus `"StyleId"` (default style id) and `"Styles"` (`<|styleName -> id|>`), with `"Engine" -> "AivisSpeech"`, `"Model"/"Root"` -> endpoint, `"Config"` -> None.
Enumeration is passive: AivisSpeech speakers appear only while the engine is running (the auto-start happens at synthesis time, not here). The `/speakers` result is cached for 30 s.
Voices are discovered as `<root>/tts/models/<voice-name>/*.onnx` (one folder per voice) or flat `<root>/tts/models/*.onnx`. Config is read from `<model>.onnx.json`, else `config.json` in the same folder, else the sole `*.json` in that folder; missing config falls back to defaults (SampleRate 22050, Speakers 1, NoiseScale 0.667, LengthScale 1, NoiseW 0.8).

### SourceVaultVoice[] → Association | Failure
Default voice: $SourceVaultVoiceDefault, else the persisted `voice_config.json` default, matched exactly then by prefix (AivisSpeech speaker names are long official names, so e.g. "ほのか" matches). If the wanted name is missing, issues `SourceVaultVoice::novoice` and falls back to the first voice (name order). Returns `Failure["SourceVaultVoiceUnavailable", ...]` with "Hint" and "SearchPath" if none installed.

### SourceVaultVoice[name] → Association | Failure
Look up a voice by name (exact, then prefix). Returns `Failure["SourceVaultVoiceUnavailable", ...]` with "Hint" and "Available" (list of names) if not found.

### SourceVaultVoiceDefaultName[] → String | None
The configured default voice name ($SourceVaultVoiceDefault, else voice_config.json), without checking whether that voice currently exists. None when nothing is configured.

### SourceVaultVoiceSetDefault[name] → Association | Failure
Persists the default voice name into `<root>/local/voice_config.json` (written as raw UTF-8 bytes, kernel-encoding independent). Returns `<|"Status" -> "OK", "DefaultVoice", "File"|>`.

### SourceVaultVoiceAvailableQ[] → Boolean
True iff the AivisSpeech engine is available (Running or Installed — an installed engine can be auto-started at synthesis time), or Piper is usable (runtime OK and voices non-empty).

## Status / Diagnostics

### SourceVaultVoiceStatus[] → Association
Single source of truth for what's missing and how to install it.
Returns `<|"Status" -> "OK"|"Incomplete", "Missing" -> {"TTSRuntime", "TTSVoice", "SpeechModel"} subset, "Root", "SearchPath", "Runtime" (SourceVaultVoiceRuntime[] result), "AivisEngine" (SourceVaultVoiceAivisStatus[] result), "Voices" (SourceVaultVoices[] result), "DefaultVoice" (SourceVaultVoice[] result or None), "SpeechModels" (SourceVaultSpeechModels[] result), "Hint" -> combined multi-line string or None|>`. TTS items count as missing only when neither engine can provide them (an Installed-but-not-running AivisSpeech engine is not missing).

### SourceVaultVoiceInstallHint[] → String
Install instructions for whatever's missing (from SourceVaultVoiceStatus[]["Hint"]), or a "everything is installed" message if nothing is missing.

### SourceVaultVoiceView[] → Column
Human-readable Dataset/Grid view of SourceVaultVoiceStatus[] (status, missing items, root, runtime executable, voice table, speech-model table, hints). For notebook display, not for machine consumption.

## Synthesis

### SourceVaultVoiceSpeak[text, opts]
Synthesizes `text` locally via the resolved voice's engine (Piper subprocess, or AivisSpeech over localhost HTTP `audio_query` -> `synthesis`) and returns an Audio object (neither text nor audio leaves the machine). If the wanted voice is not visible because the AivisSpeech engine is not running, the engine is auto-started once and the lookup retried. An explicitly requested voice that cannot be found returns Failure (never a silent switch to another voice); a configured default that is missing degrades to the first available voice with `SourceVaultVoice::novoice`.
→ Audio | Failure
Options: "Voice" -> Automatic (voice name string — exact or prefix — or Automatic for the configured default), "Style" -> Automatic (AivisSpeech only: style name, exact or prefix, e.g. "ノーマル"; unknown style returns Failure), "OutputFile" -> Automatic (output .wav path, or Automatic for a temp file), "LengthScale" -> Automatic (>1 = slower; for AivisSpeech mapped to speedScale = 1/LengthScale), "NoiseScale" -> Automatic (Piper only), "TimeConstraint" -> 120 (seconds per synthesis step)
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