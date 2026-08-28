# SourceVault_realtime API Reference

LLM-oriented reference for `SourceVault_realtime.wl`. Load order: `SourceVault.wl` -> `SourceVault_core.wl` -> `SourceVault_realtime.wl`, via `Block[{$CharacterEncoding -> "UTF-8"}, Get["SourceVault_realtime.wl"]]`.

## Overview
Runs a live voice conversation with OpenAI's gpt-realtime model using this machine's current default microphone/speaker (no VRChat involved, unlike VRCRealtime). Audio capture/playback and the WebSocket connection live in an external Python worker process (`SourceVault_info/resources/python/SourceVault_realtime_worker.py`); the kernel only writes a control file and polls a JSON state file, so it never sits on the audio/network hot path. Status lines (listening / thinking / response text / errors) are written to a notebook's window status bar, not a chat pane.
Privacy: this is a cloud path — mic audio and conversation text go to OpenAI. For privacy-sensitive material (PL >= 0.5), use the local Piper TTS in `SourceVault_voice` instead. `SourceVaultRealtimeStart` refuses to run unless `NBAccess\`NBProviderCanAccess["openai", 0.5]` allows it, and by default also requires the target notebook's Paid API approval (`NBAccess\`NBGetNotebookPaidAPIAllowed`), overridable via `"RequirePaidAPIApproval" -> False`.
Requires Python 3.10+ with `websocket-client` and `sounddevice`; `SourceVaultRealtimeInstall[]` provisions a dedicated venv under `%LOCALAPPDATA%/SourceVault/realtime/venv`.

## Configuration variables
### $SourceVaultRealtimeModel
型: String, 初期値: "gpt-realtime-2.1"
Default Realtime model used by SourceVaultRealtimeStart when "Model" -> Automatic.

### $SourceVaultRealtimeVoice
型: String, 初期値: "marin"
Default Realtime voice.

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
型: String, 初期値: "1.4"
Worker contract version this package expects; compared against the running worker's reported version (see SourceVaultRealtimeStatus "WorkerVersion").

### $SourceVaultRealtimeSlideHandler
型: Function | None, 初期値: None
Callback for voice-triggered slide navigation. Receives `<|"id", "target" ("next"|"previous"|"first"|"last"|"number"|"title"), "number", "title"|>`, must return `<|"status" -> "ok"|"error", "slide" -> n, "title" -> t, "message" -> reason|>`. Set by SlideWorkflow at load time. When None, the `show_slide` tool is not exposed to the model.

### $SourceVaultRealtimeAskHandler
型: Function | None, 初期値: None
Callback for voice-triggered document lookups. Receives `<|"id", "query", "allowWeb"|>`, must return `<|"status", "answer", "route", "needWeb", ...|>`. Set by SourceVault_talkqa at load time. When None, the `ask_sourcevault` tool is not exposed.

## Runtime / install
### SourceVaultRealtimeRuntime[] → Association
説明: reports whether the worker can run. Keys: "Status" ("OK"|"Missing"), "Python", "PythonSource" ("Venv"|"Custom"|None), "Worker" (script path), "Dependencies" (Boolean), "Root", "Missing" (list), "Hint" (remediation text or None).

### SourceVaultRealtimeInstall[opts]
説明: creates/updates the dedicated venv and installs websocket-client + sounddevice. No-op if already usable, unless "Force" -> True.
→ Association `<|"Status" -> "OK", "Reason" -> "AlreadyInstalled"|"Installed", "Python" -> venvPath, ...|>` or Failure ("SourceVaultRealtimeNoPython" | "SourceVaultRealtimeVenvFailed" | "SourceVaultRealtimePipFailed" | "SourceVaultRealtimeDepsMissing").
Options: "Force" -> False (reinstall even if already usable), "BasePython" -> Automatic (interpreter used to create the venv; Automatic auto-detects via `py -3` / known install locations).

### SourceVaultRealtimeDevices[] → {Association...} | Failure
説明: lists audio devices visible to Python. Each entry: "Index", "Name", "HostAPI", "InputChannels", "OutputChannels", "DefaultInput" (Boolean), "DefaultOutput" (Boolean).

## Session control
### SourceVaultRealtimeStart[opts]
説明: starts the voice conversation (non-blocking) using this machine's default mic/speaker; fails with Failure if already running, runtime unavailable, notebook/Paid-API approval missing, OpenAI provider access denied, or no API key found. Status lines are written to the target notebook's window status bar.
→ Association `<|"Status" -> "Started", "Model", "Voice", "Notebook", "StateFile", "Python", "AllowBargeIn", "TranscribeInput"|>` or Failure ("SourceVaultRealtimeAlreadyRunning" | "SourceVaultRealtimeUnavailable" | "SourceVaultRealtimeNBAccessUnavailable" | "SourceVaultRealtimeNotebookRequired" | "SourceVaultRealtimePaidAPINotAllowed" | "SourceVaultRealtimeOpenAIDisabled" | "SourceVaultRealtimeAPIKeyMissing" | "SourceVaultRealtimeStartFailed" | "SourceVaultRealtimeWorkerDied").
Options: "Notebook" -> Automatic (Automatic = EvaluationNotebook[]; status bar destination and Paid-API approval target), "RequirePaidAPIApproval" -> True, "Model" -> Automatic ($SourceVaultRealtimeModel), "Voice" -> Automatic ($SourceVaultRealtimeVoice), "Instructions" -> Automatic ($SourceVaultRealtimeInstructions), "InputDevice" -> Automatic, "OutputDevice" -> Automatic, "Verbosity" -> Automatic ($SourceVaultRealtimeVerbosity), "AllowBargeIn" -> False (False = mic is not sent while the model is speaking), "StartMuted" -> False (connect first, unmute later), "SlideControl" -> Automatic (Automatic = expose `show_slide` tool iff $SourceVaultRealtimeSlideHandler =!= None), "AskControl" -> Automatic (Automatic = expose `ask_sourcevault` tool iff $SourceVaultRealtimeAskHandler =!= None), "TranscribeInput" -> False (False = user speech is not transcribed to text), "TranscriptionModel" -> "gpt-4o-mini-transcribe", "ChunkMilliseconds" -> 20 (mic audio chunk size sent to worker), "TurnDetection" -> "Semantic" (lowercased and passed to worker), "Eagerness" -> "Low" (VAD eagerness, lowercased), "InputLevelGate" -> 0. (minimum input level before audio is sent), "VADThreshold" -> 0.5, "PrefixPaddingMilliseconds" -> 200, "SilenceDurationMilliseconds" -> 350, "OutputCooldownMilliseconds" -> 400 (mic re-enable delay after output, relevant with AllowBargeIn -> False), "SafetyIdentifier" -> "" (OpenAI safety_identifier, sent only if non-empty), "StatusBar" -> True (poll worker state and write to notebook status bar), "PollSeconds" -> 0.4 (status-bar poll interval), "Python" -> Automatic (override interpreter for this session).

### SourceVaultRealtimeStop[opts] → Association
説明: ends the conversation; waits up to "TimeConstraint" seconds for graceful exit, then force-kills.
→ `<|"Status" -> "Stopped"|"NotRunning"|>`
Options: "TimeConstraint" -> 8. (seconds to wait for graceful stop), "ClearStatusBar" -> True (blank the status bar line on stop).

### SourceVaultRealtimeStatus[] → Association
説明: current conversation state, read from the worker's state file. Keys: "Running" (Boolean, process alive), "Connected", "WorkerStatus", "WorkerVersion", "Model", "Voice", "Muted", "Verbosity", "TurnDetection", "InputPeak", "SlideTool" (Boolean), "AskTool" (Boolean), "AllowBargeIn", "Mode", "StatusLine", "InputDevice", "OutputDevice", "Speaking", "NarrationActive", "NarrationDone" (matches the id passed to SourceVaultRealtimeNarrate once playback finishes), "LastUserText", "LastAssistantText", "LastError", "Reconnects", "Notebook", "StateFile".

### SourceVaultRealtimeMessages[] → {Association...}
### SourceVaultRealtimeMessages[n_Integer] → {Association...}
説明: history of conversation lines; `[n]` returns only the last n. Each entry: "Sequence" (Integer), "Time" (DateObject | None), "Kind", "Text".

## During a session
### SourceVaultRealtimeMute[value:(True|False):True] → Association | Failure
説明: pauses/resumes mic transmission. Sends a control command; Failure["SourceVaultRealtimeNotRunning", ...] if not running.

### SourceVaultRealtimeSay[text_String] → Association | Failure
説明: injects `text` as if spoken by the user and triggers a response (no audio needed).

### SourceVaultRealtimeSetVerbosity[level] → Association | Failure
説明: changes response detail mid-session; also updates $SourceVaultRealtimeVerbosity. `level`: "Minimal"|"Brief"|"Normal"|"Detailed"|"Thorough" or a 0..1 number.

### SourceVaultRealtimeSetInstructions[text_String] → Association | Failure
説明: replaces the running session's instructions.

### SourceVaultRealtimeNarrate[id, text_String, opts] → Association | Failure
説明: has the model read a prepared script aloud (for presentations). Watch SourceVaultRealtimeStatus[]["NarrationDone"] for `id` to know playback has finished.
Options: "Heading" -> "" (spoken/context heading, e.g. "スライド 3"), "Instructions" -> "" (extra instructions scoped to this narration only).

### SourceVaultRealtimeCancel[] → Association | Failure
説明: interrupts the current response and discards any buffered audio.

### SourceVaultRealtimeEndTalk[opts] → Association | Failure
説明: wraps up a presentation and goes quiet — cuts current speech, suppresses model-initiated responses for "QuietSeconds", then only responds when spoken to. Mic stays open.
Options: "QuietSeconds" -> 4. (seconds before the model may speak unprompted again).

### SourceVaultRealtimeLine[text_String] → Association | Failure
説明: writes an arbitrary line to the status bar via the same path as conversation status lines.

## Voice-triggered handlers (slide / ask)
These pair with $SourceVaultRealtimeSlideHandler / $SourceVaultRealtimeAskHandler: the worker posts a request into the state file, the kernel's status-bar poll task dispatches it to the registered handler, and the result is sent back automatically. Manual result-posting is only needed for custom dispatch.
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