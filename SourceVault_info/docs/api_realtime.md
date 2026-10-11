# SourceVault_realtime API Reference

LLM-oriented reference for `SourceVault_realtime.wl`. Load order: `SourceVault.wl` -> `SourceVault_core.wl` -> `SourceVault_realtime.wl`, via `Block[{$CharacterEncoding -> "UTF-8"}, Get["SourceVault_realtime.wl"]]`.

## Overview
Runs a live voice conversation with OpenAI's gpt-realtime model using this machine's current default microphone/speaker (no VRChat involved, unlike VRCRealtime). Audio capture/playback and the WebSocket connection live in an external Python worker process (`SourceVault_info/resources/python/SourceVault_realtime_worker.py`); the kernel only writes a control file and polls a JSON state file, so it never sits on the audio/network hot path. Status lines (listening / thinking / response text / errors) are written to a notebook's window status bar, not a chat pane.
Privacy: this is a cloud path — mic audio and conversation text go to OpenAI. For privacy-sensitive material (PL >= 0.5), use the local Piper TTS in `SourceVault_voice` instead. `SourceVaultRealtimeStart` (and `SourceVaultRealtimeRender`) refuse to run unless `NBAccess\`NBProviderCanAccess["openai", 0.5]` allows it, and by default also require the target notebook's Paid API approval (`NBAccess\`NBGetNotebookPaidAPIAllowed`), overridable via `"RequirePaidAPIApproval" -> False`.
Requires Python 3.10+ with `websocket-client` and `sounddevice`; `SourceVaultRealtimeInstall[]` provisions a dedicated venv under `%LOCALAPPDATA%/SourceVault/realtime/venv`.
Undeclared kernel-side flags (no usage string): `$SourceVaultRealtimeHoldFE` (True = the status-bar poll skips its turn so a caller talking to the FE is not interrupted; set by SlideWorkflow buttons), `$SourceVaultRealtimeTrace` (True = diagnostic lines to `$TemporaryDirectory/slideworkflow-trace.log`).

### Two APIs (chosen by the model)
- `gpt-realtime-*` → Realtime API (`wss://api.openai.com/v1/realtime?model=...`). One model hears, reasons, calls the `show_slide` / `ask_sourcevault` functions and speaks.
- `gpt-live-*` (e.g. `gpt-live-1`) → GPT-Live (`wss://api.openai.com/v1/live/sessions`, `session.start` first). Full duplex (listens while speaking). Runs with **client delegation**: GPT-Live emits `session.delegation.created` (no task text); the worker reads the recent transcript and serves the request with the same handlers — slide moves via $SourceVaultRealtimeSlideHandler (Japanese phrasing is parsed: 次/前/最初/最後/N枚目/「〜のスライド」, questions *about* a slide are not moves), everything else via $SourceVaultRealtimeAskHandler (SourceVault; on `needWeb` the room is asked and a "yes" re-runs the lookup with `allowWeb -> True`). Lookup results go in as quiet context (`session.thinking.append`: the question, the material and — from TalkQA — the prepared question it matched, `matchedQuestion`) followed by a short `session.instructions.append` telling the model to answer from the material if it fits the question, otherwise briefly from general knowledge; refusals (blocked) and failures are spoken as they are (`session.commentary.append`). Reading a prepared answer verbatim answered "ハイドロゲルって何?" with the answer to a neighbouring question (measured 2026-09-19). Scripts (SourceVaultRealtimeNarrate) are delivered in ≤260-character pieces in two steps: the piece as quiet context, then — once `session.thinking.appended` confirms it was taken in — a short instruction to read it (sent as one instruction, GPT-Live started reading while the text was still being injected and stalled mid-script). A piece counts as heard when voiced audio has stopped and ≥80 % of it appears in the output transcript (or after a 6 s stall), so a pause inside a script does not advance the deck. Worker 1.11: a reply that is not the script — under 40 % of it in the transcript *and* voiced audio shorter than 35 % of the time reading it takes (e.g. "はい。") — is asked for again (at once for a bare acknowledgement, after the stall otherwise), at most twice, before the deck gets its turn back; before 1.11 such a reply plus the stall counted as the whole slide and the deck skipped it (2026-10-04). Coverage weighs kana 0.6 so scripts with reading-dictionary kana still match a kanji transcript. The script's context label no longer asks "指示があるまで声に出さないでください" (it drew "はい"), and the read instruction forbids additions and asks for a presenter's delivery; the deck's NarrationInstructions are carried up to 160 characters. The microphone always sends frames (silence while muted / half-duplex blocked) because the Live timeline advances with input frames. Background context for questions (SourceVaultRealtimeAddContext) is delivered the same quiet way and is split into pieces if it exceeds GPT-Live's per-message limit.
- The kernel-side contract (state file `slideRequest` / `askRequest`, `Narrate` / `NarrationDone`, mute / cancel / endtalk) is identical for both, so callers only choose the model. Voice sessions on GPT-Live are billed per second of session ($0.05/min); backend lookups are billed by whatever the handler uses.
- The Live worker connects without an `Origin` header (websocket-client adds one by default; GPT-Live answered it with a bare 403 after authentication). A refused handshake (401/403/404) stops the worker at once with the reason instead of reconnecting.
- GPT-Live speaks only in real time, so it cannot be used for fast wav rendering: use SourceVaultRealtimeRender with a Realtime model, or SourceVaultRealtimeNarrate `"RecordFile"` to record while playing.

### Interruptions during a talk (GPT-Live only, worker 1.6)
`SourceVaultRealtimeNarrate[..., "Interrupt" -> mode]` decides how a listener may interrupt the script:
- `None` (question time): nothing local; the caller mutes the microphone while the script is read (SlideWorkflow's default).
- `"Words"`: the model hears nothing of the room during the talk. The worker listens locally: an echo-aware detector (microphone peak vs. what was just played; coupling = 90th percentile of the echo ratio, learned in the first second) marks frames where a person is louder than our own echo (strict ≈ margin, soft ≈ margin×0.55). A grammar-restricted Vosk recogniser (`"InterruptWords"`, default $SourceVaultRealtimeInterruptWords = {"質問", "スライド"}) decodes the stream continuously; an allowed word counts only if ≥30 % of its frames are soft-flagged and a strict flag is within 1 s — so the narration's own "スライド" is rejected. Measured with the real model on synthetic speech over 0.4 echo: 3/3 questions opened, 3/3 remarks and the echo-only "スライド" ignored. Needs `vosk` (`SourceVaultRealtimeInstall["Vosk" -> True]`) and a speech model (`SourceVaultSpeechModel[]`); without them the gate falls back to `"Detect"`.
- `"Detect"`: a person speaking for `"InterruptMilliseconds"` (350) opens the Q&A and the words already spoken are replayed; GPT-Live judges whether it was a question (it is told to stay silent for remarks).
On opening, the narration is suspended (playback dropped, its tail discarded), the model is told to invite / listen, and everything is heard until the exchange has been quiet for `"ResumeQuietSeconds"` (4 s; 8 s if nobody spoke yet after a keyword, 3.5 s after a detection that heard nothing). Then, if a slide was shown during the Q&A, the worker asks the slide handler to show `"Slide"` again, and resumes from the sentence it was stopped in with "それでは、説明に戻ります". `NarrationActive` stays set throughout, so a caller waiting for `NarrationDone` simply keeps waiting. Cancel / end of talk leave the gate (the room is heard normally again). Slide requests made during such a Q&A (and the one that restores the slide) carry `"keepNarration" -> True`: the slide handler must then only move the display, not restart the talk from that slide (SlideWorkflow's handler did, and lost the resumed narration — measured 2026-09-19). A narrate that arrives while a Q&A is open (the notebook moved on just as someone spoke) is held, reported as `NarrationActive`, and read after the Q&A with the bridge phrase. Lookups from the Q&A carry `"slide"` (the talk's slide) and a query with leading hesitations (えっと、あの、…) removed.

## Configuration variables
### $SourceVaultRealtimeModel
型: String, 初期値: "gpt-realtime-2.1"
Default model used by SourceVaultRealtimeStart when "Model" -> Automatic (also by SourceVaultRealtimeRender). "gpt-live-1" selects GPT-Live (client delegation).

### $SourceVaultRealtimeInterruptWords
型: {String...}, 初期値: {"質問", "スライド"}
Words allowed to interrupt a GPT-Live talk in `"Interrupt" -> "Words"` (must be in the Vosk model's vocabulary; multi-token phrases are space-separated).

### $SourceVaultRealtimeModels
型: Association, 初期値: <||>
User additions/overrides to the built-in model registry: `<|"model" -> <|"Provider" -> "OpenAI", "API" -> "Realtime"|"Live", "Label" -> short name, "Description" -> text|>|>`. Built-ins: gpt-realtime-2.1, gpt-realtime-2.1-mini (Realtime), gpt-live-1 (Live).

### $SourceVaultRealtimeVoice
型: String, 初期値: "marin"
Default Realtime voice.

### $SourceVaultRealtimeKeepAliveLevel
型: Real | None, 初期値: -70.
Peak level (dBFS) of an inaudible noise written to the speaker between utterances so Bluetooth speakers etc. do not power down and drop the first syllables (worker 1.12). Raise to about -60 if the onset is still clipped. None = write nothing (pre-1.12 behaviour). Overridable per session via SourceVaultRealtimeStart `"KeepAliveLevel"`.

### $SourceVaultRealtimeInstructions
型: String, 初期値: "日本語で自然かつ簡潔に会話してください。聞き取れなかったときは聞き返してください。"
Default session instructions.

### $SourceVaultRealtimeVerbosity
型: String | Real (0..1), 初期値: "Normal"
Response length/detail: "Minimal" | "Brief" | "Normal" | "Detailed" | "Thorough", or a 0..1 number (0 = shortest). Does not affect SourceVaultRealtimeNarrate readings.

### $SourceVaultRealtimePython
型: String | Automatic, 初期値: Automatic
Explicit path to the Python interpreter running the worker; Automatic uses the dedicated venv.

### $SourceVaultRealtimeRoot
型: String | None, 初期値: None
Override for the root directory holding the worker venv; None uses `%LOCALAPPDATA%/SourceVault/realtime`.

### $SourceVaultRealtimeWorkerVersion
型: String, 初期値: "1.13"
Worker contract version this package expects; compared against the running worker's reported version (see SourceVaultRealtimeStatus "WorkerVersion"). 1.5 added GPT-Live (`--api live`), 1.6 talk interruptions (narrate `interrupt` / `slide`), 1.7 two-step script delivery and model-composed answers, 1.9 the `context` command (SourceVaultRealtimeAddContext), 1.11 re-asking when GPT-Live answers "はい" instead of the script, 1.12 keep-alive noise between utterances (`--keepalive-db` / `--no-keepalive`, `--lead-in-ms`), 1.13 narrate `record` (wav recording of a reading, SourceVaultRealtimeNarrate "RecordFile").

### $SourceVaultRealtimeSlideHandler
型: Function | None, 初期値: None
Callback for voice-triggered slide navigation. Receives `<|"id", "target" ("next"|"previous"|"first"|"last"|"number"|"title"), "number", "title"|>`, must return `<|"status" -> "ok"|"error", "slide" -> n, "title" -> t, "message" -> reason|>`. Set by SlideWorkflow at load time. When None, the `show_slide` tool is not exposed to the model.

### $SourceVaultRealtimeAskHandler
型: Function | None, 初期値: None
Callback for voice-triggered document lookups. Receives `<|"id", "query", "allowWeb"|>` (GPT-Live also sends `"context"` = the assistant's last words, for resolving "that"), must return `<|"status", "answer", "route", "needWeb", ...|>`, or the string `"Deferred"` to answer later via SourceVaultRealtimeAskResult. Set by SourceVault_talkqa at load time. When None, the `ask_sourcevault` tool is not exposed (Realtime) / delegations are answered without a lookup (Live).

## Model registry
### SourceVaultRealtimeModels[] → Association
説明: the registry, model name → `<|"Provider", "API", "Label", "Description"|>` (built-ins joined with $SourceVaultRealtimeModels).

### SourceVaultRealtimeModels["ByProvider"] → Association
説明: provider → list of model names, e.g. `<|"OpenAI" -> {"gpt-realtime-2.1", "gpt-realtime-2.1-mini", "gpt-live-1"}|>`.

### SourceVaultRealtimeModels[provider_String] → {String...}
説明: model names of one provider ({} if unknown).

### SourceVaultRealtimeModelAPI[model] → "Realtime" | "Live"
説明: the API a model speaks. Registry entry first; unregistered `gpt-live-*` names are "Live"; anything else "Realtime". `SourceVaultRealtimeModelAPI[Automatic]` uses $SourceVaultRealtimeModel.

## Runtime / install
### SourceVaultRealtimeRuntime[] → Association
説明: reports whether the worker can run. Keys: "Status" ("OK"|"Missing"), "Vosk" (Boolean; optional, for keyword interruptions), "Python", "PythonSource" ("Venv"|"Custom"|None), "Worker" (script path), "Dependencies" (Boolean), "Root", "Missing" (list of "Worker"|"Python"|"PythonPackages"), "Hint" (remediation text or None).

### SourceVaultRealtimeInstall[opts]
説明: creates/updates the dedicated venv and installs websocket-client + sounddevice. No-op if already usable, unless "Force" -> True.
→ Association `<|"Status" -> "OK", "Reason" -> "AlreadyInstalled"|"Installed", "Python" -> venvPath, ...|>` or Failure ("SourceVaultRealtimeNoPython" | "SourceVaultRealtimeVenvFailed" | "SourceVaultRealtimePipFailed" | "SourceVaultRealtimeDepsMissing").
Options: "Force" -> False (reinstall even if already usable), "BasePython" -> Automatic (interpreter used to create the venv; Automatic auto-detects via `py -3` / known install locations), "Vosk" -> False (also install `vosk>=0.3.45` for keyword interruptions).

### SourceVaultRealtimeDevices[] → {Association...} | Failure
説明: lists audio devices visible to Python. Each entry: "Index", "Name", "HostAPI", "InputChannels", "OutputChannels", "DefaultInput" (Boolean), "DefaultOutput" (Boolean). Failure: "SourceVaultRealtimeUnavailable" | "SourceVaultRealtimeDeviceQueryFailed".

## Session control
### SourceVaultRealtimeStart[opts]
説明: starts the voice conversation (non-blocking) using this machine's default mic/speaker; fails with Failure if already running, runtime unavailable, notebook/Paid-API approval missing, OpenAI provider access denied, or no API key found. Status lines are written to the target notebook's window status bar.
→ Association `<|"Status" -> "Started", "Model", "API", "Voice", "Notebook", "StateFile", "Python", "AllowBargeIn", "TranscribeInput"|>` or Failure ("SourceVaultRealtimeAlreadyRunning" | "SourceVaultRealtimeUnavailable" | "SourceVaultRealtimeNBAccessUnavailable" | "SourceVaultRealtimeNotebookRequired" | "SourceVaultRealtimePaidAPINotAllowed" | "SourceVaultRealtimeOpenAIDisabled" | "SourceVaultRealtimeAPIKeyMissing" | "SourceVaultRealtimeStartFailed" | "SourceVaultRealtimeWorkerDied").
Options: "Notebook" -> Automatic (Automatic = EvaluationNotebook[]; status bar destination and Paid-API approval target), "RequirePaidAPIApproval" -> True, "Model" -> Automatic ($SourceVaultRealtimeModel), "API" -> Automatic ("Realtime" | "Live"; Automatic = SourceVaultRealtimeModelAPI[model]), "Voice" -> Automatic ($SourceVaultRealtimeVoice; GPT-Live also accepts marin/cedar and its own voices such as quartz, gleam, vesper), "Instructions" -> Automatic ($SourceVaultRealtimeInstructions), "InputDevice" -> Automatic, "OutputDevice" -> Automatic, "Verbosity" -> Automatic ($SourceVaultRealtimeVerbosity), "AllowBargeIn" -> False (False = mic is not sent while the model is speaking), "StartMuted" -> False (connect first, unmute later), "SlideControl" -> Automatic (Automatic = expose `show_slide` tool iff $SourceVaultRealtimeSlideHandler =!= None), "AskControl" -> Automatic (Automatic = expose `ask_sourcevault` tool iff $SourceVaultRealtimeAskHandler =!= None), "TranscribeInput" -> False (False = user speech is not transcribed to text), "TranscriptionModel" -> "gpt-4o-mini-transcribe", "ChunkMilliseconds" -> 20 (mic audio chunk size sent to worker), "TurnDetection" -> "Semantic" (lowercased and passed to worker), "Eagerness" -> "Low" (VAD eagerness, lowercased), "InputLevelGate" -> 0. (minimum input level before audio is sent), "VADThreshold" -> 0.5, "PrefixPaddingMilliseconds" -> 200, "SilenceDurationMilliseconds" -> 350, "OutputCooldownMilliseconds" -> 400 (mic re-enable delay after output, relevant with AllowBargeIn -> False), "SafetyIdentifier" -> "" (OpenAI safety_identifier, sent only if non-empty), "StatusBar" -> True (poll worker state and write to notebook status bar), "PollSeconds" -> 0.4 (status-bar poll interval), "InterruptMargin" -> 2.0, "InterruptMilliseconds" -> 350, "InterruptFloor" -> 0.03, "ResumeQuietSeconds" -> 4, "KeepAliveLevel" -> Automatic, "LeadInMilliseconds" -> 100, "Python" -> Automatic (override interpreter for this session).
With GPT-Live the turn-detection options (TurnDetection / Eagerness / VADThreshold / PrefixPadding / SilenceDuration) and TranscribeInput are ignored: GPT-Live decides when to speak and always transcribes both sides. Talk interruptions: "InterruptMargin" (how much louder than the expected echo a person must be), "InterruptMilliseconds" (continuous speech before Detect opens a Q&A), "InterruptFloor" (minimum microphone peak counted as a voice), "ResumeQuietSeconds" (quiet time before the talk resumes). Speech onset (worker 1.12): "KeepAliveLevel" (dBFS peak of an inaudible noise written to the speaker between utterances so that Bluetooth speakers and similar outputs do not power down and drop the first syllables; Automatic = $SourceVaultRealtimeKeepAliveLevel, default -70; None = write nothing between utterances, as before 1.12), "LeadInMilliseconds" (keep-alive written before speech that follows at least 1 s of quiet). GPT-Live also keeps the last 200 ms of sub-threshold output before the first voiced chunk (a soft onset), and a Realtime narration no longer falls into the 1.5 s quiet window opened by its own cancel of a reply still speaking.

### SourceVaultRealtimeStop[opts] → Association
説明: ends the conversation; waits up to "TimeConstraint" seconds for graceful exit, then force-kills.
→ `<|"Status" -> "Stopped"|"NotRunning"|>`
Options: "TimeConstraint" -> 8. (seconds to wait for graceful stop), "ClearStatusBar" -> True (blank the status bar line on stop).

### SourceVaultRealtimeStatus[] → Association
説明: current conversation state, read from the worker's state file. Keys: "Running" (Boolean, process alive), "Connected", "WorkerStatus", "WorkerVersion", "Model", "API" ("Realtime" | "Live"), "Voice", "Muted", "Verbosity", "TurnDetection", "InputPeak", "SlideTool" (Boolean), "AskTool" (Boolean), "AllowBargeIn", "Mode", "StatusLine", "InputDevice", "OutputDevice", "Speaking", "NarrationActive", "NarrationDone" (matches the id passed to SourceVaultRealtimeNarrate once playback finishes), "LastRecording" (info on the last "RecordFile" recording, worker 1.13; None if none), "LastUserText", "LastAssistantText", "LastError", "Reconnects", "Notebook", "StateFile", and for GPT-Live: "SessionId", "UsageSeconds" (cumulative billed voice seconds), "Delegations" (count), "LastDelegation" (`<|"id", "text"|>`), "CloseReason", "InterruptMode" / "InterruptGate" ("none"|"words"|"detect"; the gate is "detect" when words cannot run), "QAOpen", "Interrupted" (the talk is suspended), "Interruptions", "LastInterrupt" (`<|"kind", "heard", "at", "suspended"|>`), "KeywordStatus" ("off"|"loading"|"ready"|"unavailable: …"), "EchoCoupling".

### SourceVaultRealtimeMessages[] → {Association...}
### SourceVaultRealtimeMessages[n_Integer] → {Association...}
説明: history of conversation lines; `[n]` returns only the last n. Each entry: "Sequence" (Integer), "Time" (DateObject | None), "Kind", "Text".

## During a session
### SourceVaultRealtimeMute[value:(True|False):True] → Association | Failure
説明: pauses/resumes mic transmission. Sends a control command; Failure["SourceVaultRealtimeNotRunning", ...] if not running.

### SourceVaultRealtimeSay[text_String] → Association | Failure
説明: injects `text` as if spoken by the user and triggers a response (no audio needed). GPT-Live: sent as a `session.instructions.append` asking the model to answer the typed text.

### SourceVaultRealtimeAddContext[text_String] → Association | Failure
説明: sends background context (e.g. a presentation summary) for the model to draw on when it answers questions later (worker 1.9+). GPT-Live has a per-message size limit, so the worker splits long context into pieces and delivers them in sequence. Sending it while a narration is in progress delays the reading, so call it only when nothing is being read aloud.

### SourceVaultRealtimeSetVerbosity[level] → Association | Failure
説明: changes response detail mid-session; also updates $SourceVaultRealtimeVerbosity. `level`: "Minimal"|"Brief"|"Normal"|"Detailed"|"Thorough" or a 0..1 number.

### SourceVaultRealtimeSetInstructions[text_String] → Association | Failure
説明: replaces the running session's instructions. GPT-Live cannot replace startup instructions; the text is appended (≤500 tokens) as "from now on" guidance.

### SourceVaultRealtimeNarrate[id, text_String, opts] → Association | Failure
説明: has the model read a prepared script aloud (for presentations). Watch SourceVaultRealtimeStatus[]["NarrationDone"] for `id` to know playback has finished. Not finished while a Q&A interruption is open (resumes from the interrupted sentence).
Options: "Heading" -> "" (spoken/context heading, e.g. "スライド 3"), "Instructions" -> "" (extra instructions scoped to this narration only), "Slide" -> None (slide number shown again when resuming after a Q&A moved the deck), "Interrupt" -> None | "Words" | "Detect" (GPT-Live only; see Interruptions during a talk), "InterruptWords" -> Automatic ($SourceVaultRealtimeInterruptWords), "SpeechModel" -> Automatic (Vosk model directory; Automatic = SourceVaultSpeechModel[]), "RecordFile" -> None (worker 1.13: path of a 24 kHz wav the audio played to the speaker during this reading is written to; the file is written before NarrationDone, so it exists once NarrationDone is seen; for recording video audio from GPT-Live, which speaks only in real time).
例: SourceVaultRealtimeNarrate["s3", script, "Heading" -> "スライド 3", "Interrupt" -> "Words", "Slide" -> 3, "RecordFile" -> "C:/tmp/s3.wav"]

### SourceVaultRealtimeCancel[] → Association | Failure
説明: interrupts the current response and discards any buffered audio.

### SourceVaultRealtimeEndTalk[opts] → Association | Failure
説明: wraps up a presentation and goes quiet — cuts current speech, suppresses model-initiated responses for "QuietSeconds", then only responds when spoken to. Mic stays open.
Options: "QuietSeconds" -> 4. (seconds before the model may speak unprompted again).

### SourceVaultRealtimeLine[text_String] → Association | Failure
説明: writes an arbitrary line to the status bar via the same path as conversation status lines.

## Offline rendering (no speaker)
### SourceVaultRealtimeRender[jobs_List, opts]
説明: renders scripts to wav files with a Realtime API model (gpt-realtime-*) without playing them: received audio is written straight to files, so it is faster than real time; `"Parallel"` sessions run side by side (one session per script, so earlier slides' audio is not carried over and re-billed as input). Uses an external script `SourceVault_info/resources/python/SourceVault_realtime_render.py`; the narration wording (read only the script, no preamble) is the same as SourceVaultRealtimeNarrate. Runs the same checks as SourceVaultRealtimeStart (Paid API approval, OpenAI provider gate, API key). Blocks until done or timed out.
jobs: list of `<|"Id" -> "s3", "Text" -> script, "File" -> out.wav, "Heading" -> "スライド 3"|>` (Text/File required; "Id" and "Heading" optional).
→ `<|"Status" -> "OK"|"Partial"|"Failed", "Files" -> <|id -> wav|>, "Seconds" -> <|id -> duration|>, "Failed" -> <|id -> reason|>, "Fatal", "Model", "Voice", "Elapsed", "TimedOut"|>`; empty/invalid jobs → `<|"Status" -> "OK", "Files" -> <||>, ...|>`. Failure: "SourceVaultRealtimeRenderLive" (GPT-Live model given) | "SourceVaultRealtimeUnavailable" | "SourceVaultRealtimeNBAccessUnavailable" | "SourceVaultRealtimeNotebookRequired" | "SourceVaultRealtimePaidAPINotAllowed" | "SourceVaultRealtimeOpenAIDisabled" | "SourceVaultRealtimeRenderIO" | "SourceVaultRealtimeAPIKeyMissing" | "SourceVaultRealtimeStartFailed" | "SourceVaultRealtimeRenderFailed".
Options: "Model" -> Automatic ($SourceVaultRealtimeModel; GPT-Live not allowed), "Voice" -> Automatic ($SourceVaultRealtimeVoice), "Instructions" -> Automatic ($SourceVaultRealtimeInstructions; session instructions), "NarrationInstructions" -> "" (delivery instructions, not spoken), "Parallel" -> 3 (concurrent sessions), "Notebook" -> Automatic, "RequirePaidAPIApproval" -> True, "Python" -> Automatic, "Progress" -> None (function called with `<|"Done", "Failed", "Total", "Elapsed"|>` on each change), "TimeConstraint" -> Automatic (seconds; Automatic = 120 + total script characters / 2), "PollSeconds" -> 0.5.
例: SourceVaultRealtimeRender[{<|"Id" -> "s1", "Text" -> t1, "File" -> "s1.wav"|>, <|"Id" -> "s2", "Text" -> t2, "File" -> "s2.wav"|>}, "Parallel" -> 2]

## Voice-triggered handlers (slide / ask)
These pair with $SourceVaultRealtimeSlideHandler / $SourceVaultRealtimeAskHandler: the worker posts a request into the state file, the kernel's status-bar poll task dispatches it to the registered handler, and the result is sent back automatically. Manual result-posting is only needed for custom dispatch (e.g. a handler returning "Deferred").
### SourceVaultRealtimeSlideRequest[] → Association | None
説明: pending slide-navigation request, if any.

### SourceVaultRealtimeSlideResult[id, result_Association] → Association | Failure
説明: returns a slide-navigation result to the worker (normally sent automatically via $SourceVaultRealtimeSlideHandler).

### SourceVaultRealtimeAskResult[id, result_Association] → Association | Failure
説明: returns a document-lookup result to the worker (normally sent automatically via $SourceVaultRealtimeAskHandler).

## Status bar destination
### SourceVaultRealtimeStatusNotebook[] → NotebookObject | None
説明: current status-bar destination notebook.

### SourceVaultRealtimeStatusNotebook[nb_NotebookObject | None]
説明: changes the status-bar destination notebook mid-session.