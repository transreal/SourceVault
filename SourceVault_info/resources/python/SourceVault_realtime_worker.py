"""SourceVault <-> OpenAI Realtime voice bridge (current default mic / speaker).

This process is intentionally separate from the Wolfram Language kernel: it
owns the long-lived WebSocket and the audio devices, so notebook evaluation and
the front end never sit on an audio or network hot path.  The Wolfram side only
reads a state file and writes a control file.

Modelled on VRCRealtime_worker.py (the VRChat bridge), with three differences:

  * Audio goes to and from the machine's *current* default input/output devices
    through PortAudio (sounddevice), not through VRChat's virtual cables.  The
    stream is opened directly at the API's 24 kHz mono PCM16, so there is no
    resampling code here at all.
  * There is no VRChat, no OSC, no avatar, no vision.  The short lines the
    VRChat build posted to the in-world chatbox are published here as a single
    "statusLine" field (plus a message history), for the notebook to show in
    its window status bar.
  * Half duplex by default.  A real speaker in the room is heard by a real
    microphone, so sending the microphone while the assistant is speaking makes
    the server VAD interrupt on the assistant's own voice.  The microphone is
    therefore not sent while output is playing, plus a short cooldown.  Use
    --allow-barge-in with headphones to get interruption back.
"""

from __future__ import annotations

import argparse
import array
import base64
import json
import os
import queue
import sys
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any
from urllib.parse import quote

import sounddevice as sd
import websocket

#: Bumped whenever the notebook side needs a newer worker than one that may
#: already be running (the control/state contract).  A stale worker is
#: restarted rather than silently ignoring commands it does not know.
WORKER_VERSION = "1.4"

RATE = 24_000  # OpenAI Realtime PCM rate, used for both directions.

#: How much the model says when it answers.  The Realtime API has no verbosity
#: parameter, so this is carried in the session instructions -- plus a hard
#: ceiling on output tokens, because an instruction alone is a request and a
#: ceiling is a limit.  Ordered from terse to expansive.
#: The ceilings are deliberately far above the wording they accompany: a
#: cap that a normal answer can reach is a guillotine, not a limit -- an
#: answer cut mid-sentence was what "応答が長すぎて途中で切られた" was
#: (2026-08-22).
VERBOSITY_LEVELS: dict[str, dict[str, Any]] = {
    "minimal": {
        "rank": 0,
        "text": (
            "返答は一文、可能なら数語で終えてください。"
            "前置き・相槌・言い換え・確認・要約を一切しません。"
            "聞かれたことだけに答え、それ以外は話しません。"
        ),
        "max_tokens": 512,
    },
    "brief": {
        "rank": 1,
        "text": (
            "返答は1〜2文にまとめてください。前置きや言い直しをせず、要点だけを言います。"
        ),
        "max_tokens": 1024,
    },
    "normal": {
        "rank": 2,
        "text": (
            "自然な会話として簡潔に答えてください。必要なら2〜3文まで。"
        ),
        "max_tokens": 2048,
    },
    "detailed": {
        "rank": 3,
        "text": (
            "理由や背景も添えて3〜5文で答えてください。"
            "相手が分かっていなさそうなところは補ってください。"
        ),
        "max_tokens": 4096,
    },
    "thorough": {
        "rank": 4,
        "text": (
            "具体例や補足も交え、聞き手が迷わないように手厚く説明してください。"
            "長い場合は順を追って話し、区切りごとに間を置いてください。"
        ),
        "max_tokens": "inf",
    },
}

VERBOSITY_ORDER = ["minimal", "brief", "normal", "detailed", "thorough"]

#: What the status bar says.  It shows the *mode* only -- what the bridge is
#: doing right now -- the way the VRChat build's chatbox did.  The spoken
#: text itself stays in the state and the message history (the hook a
#: subtitle view would use) but never reaches the status bar: a whole
#: narration scrolling through a one-line strip cannot be read, and it hides
#: the one thing that has to be readable at a glance.
MODE_LABELS = {
    "connecting": "接続中",
    "ready": "質問をどうぞ",
    "muted": "待機中 (マイク切)",
    "listening": "聞いています",
    "thinking": "考えています",
    "answering": "応答中",
    "narrating": "説明中",
    "paused": "一時停止中",
    "ended": "終了しました (話しかけられるまで待機)",
    "reconnecting": "再接続中",
    "stopped": "終了しました",
}


def normalise_verbosity(value: Any) -> str:
    """Accept a level name or a 0..1 number (0 = terse, 1 = expansive)."""
    if isinstance(value, str):
        key = value.strip().casefold()
        if key in VERBOSITY_LEVELS:
            return key
        try:
            value = float(key)
        except ValueError:
            return "normal"
    if isinstance(value, (int, float)):
        position = min(max(float(value), 0.0), 1.0) * (len(VERBOSITY_ORDER) - 1)
        return VERBOSITY_ORDER[int(round(position))]
    return "normal"


def _read_instructions(args: argparse.Namespace) -> str:
    """Instructions come from a file when there is one.

    Not from the environment: a Japanese instruction string in an environment
    variable makes the Wolfram side's StartProcess fail outright on Windows,
    and the failure looks like "the worker would not start" (2026-08-22).
    """
    path = getattr(args, "instructions_file", "")
    if path:
        try:
            text = Path(path).read_bytes().decode("utf-8").strip()
            if text:
                return text
        except (OSError, UnicodeDecodeError):
            pass
    return args.instructions


def _now() -> float:
    return time.time()


class RealtimeBridge:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.api_key = getattr(args, "api_key", "") or os.environ.get(
            "OPENAI_API_KEY", ""
        )
        self.instructions = _read_instructions(args)
        self.verbosity = normalise_verbosity(args.verbosity)
        self.turn_detection = args.turn_detection
        #: Loudest sample seen since the last status write, as 0..1.  Published
        #: so the room level can be read off and an input gate chosen.
        self._input_peak = 0.0

        self.state_lock = threading.Lock()
        self.state: dict[str, Any] = {
            "status": "starting",
            "workerVersion": WORKER_VERSION,
            "pid": os.getpid(),
            "startedAt": _now(),
            "connected": False,
            "model": args.model,
            "voice": args.voice,
            "muted": False,
            "verbosity": normalise_verbosity(args.verbosity),
            "turnDetection": args.turn_detection,
            "allowBargeIn": bool(args.allow_barge_in),
            "transcribeInput": bool(args.transcribe_input),
            "resolvedInputDevice": None,
            "resolvedOutputDevice": None,
            "mode": "connecting",
            "statusLine": "",
            "statusSeq": 0,
            "statusAt": 0.0,
            "messages": [],
            "messageSeq": 0,
            "lastAssistantText": "",
            "lastUserText": "",
            "speaking": False,
            "narrationActive": None,
            "narrationDone": None,
            "slideRequest": None,
            "slideTool": bool(args.slide_tool),
            "askRequest": None,
            "askTool": bool(args.ask_tool),
            "lastEvent": None,
            "lastError": None,
            "inputPeak": 0.0,
            "inputChunks": 0,
            "outputChunks": 0,
            "reconnects": 0,
        }
        self.messages: deque[dict[str, Any]] = deque(maxlen=max(4, args.max_messages))

        self.stop_event = threading.Event()
        self.ws: websocket.WebSocketApp | None = None
        self.ws_lock = threading.Lock()
        self.ws_ready = threading.Event()

        self.muted = threading.Event()
        if args.start_muted:
            self.muted.set()
            self.state["muted"] = True
        self.output_active = threading.Event()
        self.output_done = threading.Event()
        # A response is in flight.  The server refuses a second one
        # (conversation_already_has_active_response), so anything that wants to
        # make the model speak has to wait for this to clear.
        self.response_active = threading.Event()
        self.input_blocked_until = 0.0

        self.input_events: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=64)
        self.play_queue: queue.Queue[bytes] = queue.Queue()

        self._assistant_text = ""
        self._assistant_flush = 0.0
        #: Which request the response now playing belongs to.  A narration
        #: driven from the notebook has to know when *its own* audio finished
        #: playing -- not merely when the model stopped generating -- because
        #: the slide may only advance after the room has heard the sentence.
        self.output_purpose = "normal"
        self.purpose_lock = threading.Lock()
        #: The narration the notebook is waiting on.  Tracked here rather than
        #: only through the response metadata: if the server ever omits the
        #: metadata echo, the slide would never advance and the deck would sit
        #: on one page for the whole talk.
        self.pending_narration: str | None = None
        #: Until this moment, any response the model starts on its own is
        #: cancelled the instant it is created.  Stopping a talk has to mean
        #: silence: a response already in flight (or one the server VAD starts
        #: on the tail of the room) otherwise has the model carry on presenting
        #: -- "次のスライドを送ってください" seconds after the stop button.
        self.suppress_until = 0.0
        #: Heading of the narration in progress ("スライド 3/24"), shown as
        #: the detail next to the mode while it is being spoken.
        self.narration_label = ""
        #: call_id -> the result the notebook sent back, and the ids we
        #: have already served (a response.done can repeat).
        self.slide_results: dict[str, dict[str, Any]] = {}
        self.ask_results: dict[str, dict[str, Any]] = {}
        self.handled_tool_calls: set[str] = set()
        #: Set once the server has accepted this connection (session.created).
        #: A connection that never reaches it is a configuration failure --
        #: a bad key, a bad model -- and retrying it forever only hammers the
        #: API while the room sees nothing.
        self.session_ok = False
        #: How far into the control queue we have read.  The notebook appends
        #: one JSON line per command: a single-slot file loses a command when
        #: two are sent inside one poll interval.
        self._control_offset = 0

        self._write_state()

    # ------------------------------------------------------------------ state

    def _write_state(self, **updates: Any) -> None:
        """Publish state atomically.  The notebook polls this file."""
        with self.state_lock:
            self.state.update(updates)
            self.state["messages"] = list(self.messages)
            payload = json.dumps(self.state, ensure_ascii=False)
        path = Path(self.args.state_file)
        temporary = path.with_suffix(path.suffix + ".tmp")
        try:
            temporary.write_bytes(payload.encode("utf-8"))
            os.replace(temporary, path)
        except OSError:
            # A state write failing is not a reason to drop the conversation.
            pass

    def _set_state(self, **updates: Any) -> None:
        with self.state_lock:
            self.state.update(updates)

    def _line(self, text: str, *, kind: str = "status", keep: bool = False) -> None:
        """Publish one short line -- the equivalent of the VRChat chatbox.

        `statusLine` is what the notebook shows in its window status bar right
        now; `keep` also files the line in the message history so the whole
        exchange can be read back afterwards.
        """
        line = " ".join(str(text).split())[:180]
        if not line:
            return
        with self.state_lock:
            # Sequence numbers are handed out under the lock: two threads
            # publishing at once must not produce the same seq, or the
            # notebook's poller would skip one of the lines.
            self.state["statusSeq"] = int(self.state.get("statusSeq", 0)) + 1
            self.state["statusLine"] = line
            self.state["statusAt"] = _now()
            if keep:
                mseq = int(self.state.get("messageSeq", 0)) + 1
                self.messages.append(
                    {"seq": mseq, "t": _now(), "kind": kind, "text": line}
                )
                self.state["messageSeq"] = mseq
        self._write_state()

    def _record(self, kind: str, text: str) -> None:
        """File a line in the history without touching the status bar."""
        line = " ".join(str(text).split())[:2000]
        if not line:
            return
        with self.state_lock:
            seq = int(self.state.get("messageSeq", 0)) + 1
            self.messages.append(
                {"seq": seq, "t": _now(), "kind": kind, "text": line}
            )
            self.state["messageSeq"] = seq
        self._write_state()

    def _mode(self, name: str, detail: str = "") -> None:
        """Publish the current mode -- all the status bar ever shows."""
        label = MODE_LABELS.get(name, name)
        text = (detail + " " + label).strip() if detail else label
        with self.state_lock:
            self.state["mode"] = name
        self._line(text)

    def _ready_mode(self) -> str:
        return "muted" if self.muted.is_set() else "ready"

    # ----------------------------------------------------------------- audio

    @staticmethod
    def _resolve_device(spec: str, kind: str) -> int | None:
        """Empty spec keeps PortAudio's default device (= the one Windows is
        currently set to).  A number is an index, anything else is matched
        against device names."""
        spec = (spec or "").strip()
        if not spec:
            return None
        if spec.lstrip("-").isdigit():
            return int(spec)
        want = spec.casefold()
        channels = "max_input_channels" if kind == "input" else "max_output_channels"
        for index, device in enumerate(sd.query_devices()):
            if device.get(channels, 0) <= 0:
                continue
            if want in str(device.get("name", "")).casefold():
                return index
        raise ValueError(f"{kind} device not found: {spec}")

    @staticmethod
    def _device_name(index: int | None, kind: str) -> str:
        try:
            if index is None:
                index = sd.default.device[0 if kind == "input" else 1]
            if index is None or index < 0:
                return "(default)"
            return str(sd.query_devices(index).get("name", "(default)"))
        except Exception:
            return "(unknown)"

    @staticmethod
    def _peak_of(raw: bytes) -> float:
        """Loudest sample in one chunk, 0..1 (int16 PCM, no numpy)."""
        if not raw:
            return 0.0
        samples = array.array("h")
        try:
            samples.frombytes(raw[: len(raw) - (len(raw) % 2)])
        except ValueError:
            return 0.0
        if not samples:
            return 0.0
        return max(abs(min(samples)), abs(max(samples))) / 32768.0

    def _input_blocked(self) -> bool:
        if self.muted.is_set():
            return True
        if self.args.allow_barge_in:
            return False
        if self.output_active.is_set():
            return True
        return time.monotonic() < self.input_blocked_until

    def _microphone_worker(self) -> None:
        frames = max(1, int(RATE * self.args.chunk_ms / 1000))
        try:
            device = self._resolve_device(self.args.input_device, "input")
            with sd.RawInputStream(
                samplerate=RATE,
                channels=1,
                dtype="int16",
                blocksize=frames,
                device=device,
            ) as stream:
                self._write_state(
                    resolvedInputDevice=self._device_name(device, "input")
                )
                while not self.stop_event.is_set():
                    data, _overflowed = stream.read(frames)
                    if self._input_blocked():
                        continue
                    if not self.ws_ready.is_set():
                        continue
                    raw = bytes(data)
                    peak = self._peak_of(raw)
                    if peak > self._input_peak:
                        self._input_peak = peak
                    if peak < self.args.input_gate:
                        # Below the room's noise floor: never let it reach the
                        # server, or quiet noise becomes a question.
                        continue
                    event = {
                        "type": "input_audio_buffer.append",
                        "audio": base64.b64encode(raw).decode("ascii"),
                    }
                    try:
                        self.input_events.put_nowait(event)
                    except queue.Full:
                        # Late audio is worse than dropped audio: keep the
                        # newest chunk and discard the oldest.
                        try:
                            self.input_events.get_nowait()
                            self.input_events.put_nowait(event)
                        except (queue.Empty, queue.Full):
                            pass
        except Exception as exc:
            self._fatal(f"microphone: {type(exc).__name__}: {exc}")

    def _input_sender(self) -> None:
        sent = 0
        blocked = True
        while not self.stop_event.is_set():
            try:
                event = self.input_events.get(timeout=0.1)
            except queue.Empty:
                continue
            if self._input_blocked():
                blocked = True
                continue
            if blocked:
                # Reopening the microphone: drop whatever the server still
                # holds.  Otherwise the tail of the previous turn (or the room
                # echo of our own voice) is committed as a new question and
                # answered out of nowhere.
                blocked = False
                self._send({"type": "input_audio_buffer.clear"})
            if self._send(event):
                sent += 1
                if sent % 50 == 0:
                    self._write_state(inputChunks=sent)

    def _playback_worker(self) -> None:
        frames = max(1, int(RATE * self.args.chunk_ms / 1000))
        try:
            device = self._resolve_device(self.args.output_device, "output")
            with sd.RawOutputStream(
                samplerate=RATE,
                channels=1,
                dtype="int16",
                blocksize=frames,
                device=device,
            ) as stream:
                self._write_state(
                    resolvedOutputDevice=self._device_name(device, "output")
                )
                played = 0
                while not self.stop_event.is_set():
                    try:
                        chunk = self.play_queue.get(timeout=0.1)
                    except queue.Empty:
                        if self.output_active.is_set() and self.output_done.is_set():
                            self._finish_output()
                        continue
                    if chunk:
                        stream.write(chunk)
                        played += 1
                        if played % 25 == 0:
                            self._write_state(outputChunks=played)
        except Exception as exc:
            self._fatal(f"speaker: {type(exc).__name__}: {exc}")

    def _finish_output(self) -> None:
        self.output_active.clear()
        self.output_done.clear()
        self.input_blocked_until = (
            time.monotonic() + self.args.output_cooldown_ms / 1000.0
        )
        self._send({"type": "input_audio_buffer.clear"})
        with self.purpose_lock:
            purpose = self.output_purpose
            self.output_purpose = "normal"
            narration = self.pending_narration
            if narration is None and purpose.startswith("narrate:"):
                narration = purpose.split(":", 1)[1]
            self.pending_narration = None
        if narration is not None:
            # The notebook waits for exactly this: the narration was not just
            # generated, it was heard.
            self._write_state(narrationActive=None, narrationDone=narration)
        if time.monotonic() >= self.suppress_until:
            self.narration_label = ""
            self._mode(self._ready_mode())

    def _drop_playback(self) -> None:
        while True:
            try:
                self.play_queue.get_nowait()
            except queue.Empty:
                break

    # ------------------------------------------------------------- websocket

    def _send(self, event: dict[str, Any]) -> bool:
        with self.ws_lock:
            ws = self.ws
        if ws is None or not self.ws_ready.is_set():
            return False
        try:
            ws.send(json.dumps(event, separators=(",", ":"), ensure_ascii=False))
            return True
        except Exception as exc:
            self._write_state(lastError=f"send: {type(exc).__name__}: {exc}")
            return False

    def _effective_instructions(self) -> str:
        """Base instructions plus the verbosity clause.

        Kept as one string rather than a second session field: the API has no
        verbosity knob, and the wording has to sit next to the role for the
        model to weigh them together.
        """
        clause = VERBOSITY_LEVELS[self.verbosity]["text"]
        # Never start a turn on its own.  Without this the model fills silences
        # -- including the silence right after a talk was stopped.
        clause += "\n話しかけられたときだけ答え、自分から話し始めないでください。"
        base = (self.instructions or "").strip()
        return (base + "\n" + clause).strip() if base else clause

    def _turn_detection(self) -> dict[str, Any]:
        """How the server decides the person has finished speaking.

        semantic_vad asks a model whether the sentence is finished, which is
        what Japanese needs: the meaning is not settled until the end, and a
        pause mid-thought is not a turn.  server_vad (a silence timer) is kept
        as the fallback for when semantic_vad is not available.
        """
        if self.turn_detection == "semantic":
            return {
                "type": "semantic_vad",
                "eagerness": self.args.vad_eagerness,
                "create_response": True,
                "interrupt_response": bool(self.args.allow_barge_in),
            }
        return {
            "type": "server_vad",
            "threshold": self.args.vad_threshold,
            "prefix_padding_ms": self.args.prefix_padding_ms,
            "silence_duration_ms": self.args.silence_duration_ms,
            "create_response": True,
            "interrupt_response": bool(self.args.allow_barge_in),
        }

    def _session_update(self) -> dict[str, Any]:
        session: dict[str, Any] = {
            "type": "realtime",
            "model": self.args.model,
            "output_modalities": ["audio"],
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": RATE},
                    "turn_detection": self._turn_detection(),
                },
                "output": {
                    "format": {"type": "audio/pcm", "rate": RATE},
                    "voice": self.args.voice,
                },
            },
            "instructions": self._effective_instructions(),
            "max_output_tokens": VERBOSITY_LEVELS[self.verbosity]["max_tokens"],
        }
        if self.args.transcribe_input:
            session["audio"]["input"]["transcription"] = {
                "model": self.args.transcription_model
            }
        if self.args.slide_tool:
            session["tools"] = [
                {
                    "type": "function",
                    "name": "show_slide",
                    "description": (
                        "表示しているスライドを変える。"
                        "「次/前のスライド」「一つ前に戻して」「最初/最後のスライド」"
                        "「三枚目」「〜のスライドを見せて」など、表示するスライドに"
                        "ついての依頼には、答える前に必ずこの関数を呼ぶ。"
                        "呼ばずに「戻します」「表示します」とだけ言ってはいけない。"
                        "呼んだあとは一言だけ短く応じる。"
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "target": {
                                "type": "string",
                                "enum": [
                                    "next",
                                    "previous",
                                    "first",
                                    "last",
                                    "number",
                                    "title",
                                ],
                                "description": (
                                    "どれを出すか。番号指定は number、"
                                    "内容や見出しでの指定は title。"
                                ),
                            },
                            "number": {
                                "type": "integer",
                                "description": "target=number のときのスライド番号 (1 始まり)",
                            },
                            "title": {
                                "type": "string",
                                "description": (
                                    "target=title のとき、探す語 "
                                    "(利用者が言った言葉をそのまま入れる)"
                                ),
                            },
                        },
                        "required": ["target"],
                    },
                }
            ]
            session["tool_choice"] = "auto"
        if self.args.ask_tool:
            session.setdefault("tools", []).append(
                {
                    "type": "function",
                    "name": "ask_sourcevault",
                    "description": (
                        "手元の資料 (SourceVault) から質問の答えを引く。"
                        "発表の内容や、そこで触れた事実について聞かれたら、"
                        "推測で答える前に必ずこれを呼ぶ。"
                        "答えが返ったらその内容だけを短く伝える。"
                        "needWeb が返ったら、ウェブで調べてよいか一言尋ね、"
                        "許しが出てから allow_web=true でもう一度呼ぶ。"
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "query": {
                                "type": "string",
                                "description": "利用者の質問を短い日本語の問いにしたもの",
                            },
                            "allow_web": {
                                "type": "boolean",
                                "description": "ウェブ検索の許しが出たときだけ true",
                            },
                        },
                        "required": ["query"],
                    },
                }
            )
            session["tool_choice"] = "auto"
        return {"type": "session.update", "session": session}

    def _on_open(self, ws: websocket.WebSocketApp) -> None:
        self.ws_ready.set()
        self._write_state(status="running", connected=True, lastError=None)
        try:
            ws.send(json.dumps(self._session_update(), separators=(",", ":"), ensure_ascii=False))
        except Exception as exc:
            self._write_state(lastError=f"session update: {type(exc).__name__}: {exc}")
        self._record(
            "status", f"接続しました ({self.args.model} / {self.args.voice})"
        )
        self._mode(self._ready_mode())

    def _on_message(self, _ws: websocket.WebSocketApp, message: str) -> None:
        try:
            event = json.loads(message)
        except json.JSONDecodeError:
            self._write_state(lastError="received malformed JSON")
            return
        kind = str(event.get("type", ""))
        self._set_state(lastEvent=kind)

        if kind in ("session.created", "session.updated"):
            self.session_ok = True
        if kind == "response.output_audio.delta":
            audio = event.get("delta")
            if isinstance(audio, str) and audio:
                if (self.pending_narration is None
                        and self.state.get("mode") == "thinking"):
                    self._mode("answering")
                try:
                    self.play_queue.put(base64.b64decode(audio))
                except Exception as exc:
                    self._write_state(lastError=f"decode: {type(exc).__name__}: {exc}")
        elif kind == "response.created":
            if time.monotonic() < self.suppress_until:
                # Asked to be quiet: kill it before a syllable reaches the room.
                self._send({"type": "response.cancel"})
                self._drop_playback()
                return
            self.output_active.set()
            self.output_done.clear()
            self.response_active.set()
            self._assistant_text = ""
            response = event.get("response", {})
            metadata = response.get("metadata", {}) if isinstance(response, dict) else {}
            purpose = "normal"
            if isinstance(metadata, dict):
                purpose = str(metadata.get("sourcevault_purpose", "normal"))
            with self.purpose_lock:
                self.output_purpose = purpose
            self._write_state(speaking=True)
            if self.pending_narration is not None:
                self._mode("narrating", self.narration_label)
            else:
                self._mode("thinking")
        elif kind == "response.output_audio_transcript.delta":
            delta = str(event.get("delta", ""))
            # Kept for whoever wants the words (history, a future subtitle
            # view) -- deliberately never shown on the status bar.
            self._assistant_text += delta
            self._set_state(lastAssistantText=self._assistant_text[-4000:])
        elif kind == "response.output_audio.done":
            self.output_done.set()
        elif kind == "response.done":
            self.response_active.clear()
            self._handle_tool_calls(event)
            self.output_done.set()
            self._write_state(speaking=False)
            # If no audio period was ever opened (no response.created seen, or
            # a text-only response), close it here instead of leaving the
            # notebook waiting for audio that will never play.
            if self.pending_narration is not None and not self.output_active.is_set():
                self._finish_output()
            text = self._assistant_text.strip()
            if text:
                self._write_state(lastAssistantText=text[-4000:])
                self._record("assistant", text)
        elif kind == "input_audio_buffer.speech_started":
            if self.args.allow_barge_in and self.output_active.is_set():
                self._drop_playback()
            self._mode("listening")
        elif kind == "conversation.item.input_audio_transcription.completed":
            text = str(event.get("transcript", "")).strip()
            if text:
                self._write_state(lastUserText=text[-2000:])
                self._record("user", text)
        elif kind == "error":
            detail = event.get("error", event)
            text = json.dumps(detail, ensure_ascii=False)[:400]
            self._write_state(lastError=text)
            code = detail.get("code") if isinstance(detail, dict) else None
            if (
                self.turn_detection == "semantic"
                and "semantic_vad" in text
            ):
                # Not available on this account/model: fall back rather than
                # run with no turn detection at all.
                self.turn_detection = "server"
                self._write_state(turnDetection="server")
                self._send(self._session_update())
                self._record("status", "semantic_vad が使えないので server_vad に切替")
                return
            if code in ("response_cancel_not_active",):
                # Racing a response that had already finished.  Recorded, but
                # not worth showing: nothing went wrong for the listener.
                return
            if code == "conversation_already_has_active_response":
                # Two responses raced; the listener heard the other one.
                return
            # The status bar is for the listener, not for JSON.  The full text
            # stays in lastError for whoever is debugging.
            self._line("エラー: " + self._error_summary(detail, text),
                       kind="error", keep=True)

    _ERROR_SUMMARIES = {
        "session_expired": "接続の有効期限が切れました。",
        "invalid_api_key": "API キーが受け付けられませんでした。",
        "insufficient_quota": "API の残高が足りません。",
        "rate_limit_exceeded": "呼び出しが多すぎます。少し待ってください。",
    }

    def _error_summary(self, detail: Any, text: str) -> str:
        code = detail.get("code") if isinstance(detail, dict) else None
        if code in self._ERROR_SUMMARIES:
            return self._ERROR_SUMMARIES[code]
        message = detail.get("message") if isinstance(detail, dict) else None
        if isinstance(message, str) and message.strip():
            return message.strip()[:120]
        return text[:120]

    def _on_error(self, _ws: websocket.WebSocketApp, error: Any) -> None:
        self._write_state(lastError=f"{type(error).__name__}: {error}")

    def _on_close(self, _ws: websocket.WebSocketApp, *_rest: Any) -> None:
        self.ws_ready.clear()
        self._write_state(connected=False)
        if not self.stop_event.is_set():
            self._mode("reconnecting")

    def _fatal(self, reason: str) -> None:
        self._write_state(status="error", lastError=reason)
        self._line("エラー: " + reason[:150], kind="error", keep=True)
        self.stop_event.set()
        with self.ws_lock:
            ws = self.ws
        if ws is not None:
            try:
                ws.close()
            except Exception:
                pass

    # --------------------------------------------------------------- control

    def _apply_command(self, command: dict[str, Any]) -> None:
        name = str(command.get("command", "")).lower()
        if name == "stop":
            self._line("終了します", keep=True)  # 終了します
            self.stop_event.set()
            with self.ws_lock:
                ws = self.ws
            if ws is not None:
                try:
                    ws.close()
                except Exception:
                    pass
        elif name == "mute":
            value = bool(command.get("value", True))
            if value:
                self.muted.set()
            else:
                self.muted.clear()
            self._write_state(muted=value)
            self._send({"type": "input_audio_buffer.clear"})
            self._mode(self._ready_mode())
        elif name == "instructions":
            text = str(command.get("text", "")).strip()
            if text:
                self.instructions = text
                self._send(self._session_update())
        elif name == "verbosity":
            level = normalise_verbosity(command.get("value", "normal"))
            self.verbosity = level
            self._write_state(verbosity=level)
            self._send(self._session_update())
            self._record("status", "応答の詳しさ: " + level)
        elif name == "say":
            text = str(command.get("text", "")).strip()
            if text:
                self._send(
                    {
                        "type": "conversation.item.create",
                        "item": {
                            "type": "message",
                            "role": "user",
                            "content": [{"type": "input_text", "text": text}],
                        },
                    }
                )
                self._send({"type": "response.create"})
                self._record("user", text)
        elif name == "narrate":
            self._narrate(command)
        elif name == "cancel":
            self._cancel_speech()
        elif name == "endtalk":
            self._end_talk(command)
        elif name == "askresult":
            identifier = str(command.get("id", ""))
            if identifier:
                payload = command.get("result")
                self.ask_results[identifier] = (
                    payload if isinstance(payload, dict) else {"status": "error"}
                )
        elif name == "slideresult":
            identifier = str(command.get("id", ""))
            if identifier:
                payload = command.get("result")
                self.slide_results[identifier] = (
                    payload if isinstance(payload, dict) else {"status": "error"}
                )
        elif name == "line":
            # Let the notebook put its own line on the status bar through the
            # same channel (e.g. "スライド 7").
            self._line(str(command.get("text", "")), keep=bool(command.get("keep")))

    #: Read *this script*, do not improvise around it, and above all do not
    #: say the directions out loud.  A model given "話してください" style
    #: guidance tends to open by paraphrasing it -- "イメージしやすいように
    #: 自然な流れでお話しします" -- which is a note to the reader, not
    #: something the audience should ever hear (observed 2026-08-22).
    _NARRATION_INSTRUCTIONS = (
        "直前のメッセージにある原稿を、聞き手に向けて声に出してください。\n"
        "守ること:\n"
        "- 原稿の内容だけを話し、原稿に無い文を足さない。\n"
        "- 前置きをしない。「〜についてお話しします」「〜のように説明します」"
        "のような、これから何をどう話すかの説明は絶対に言わない。\n"
        "- 話し方や進め方の指示 (この指示文を含む) は、言い換えも要約もせず、"
        "一切声に出さない。ト書きであって原稿ではない。\n"
        "- 自然な発表口調で話す。棒読みにしない。記号・URL・括弧内の注記は読まない。\n"
        "- 読み終えたら、次へ進む合図や質問をせずに黙る。"
    )

    @staticmethod
    def _opening_sentence(text: str) -> str:
        """The first sentence of the script.

        Naming it in the request is what actually stops a preamble: a rule
        ("前置きをしない") is advice, "最初の文はこれ" is checkable.
        """
        head = text.strip()
        for stop in ("。", "！", "？", ".", "\n"):
            index = head.find(stop)
            if 0 < index <= 60:
                return head[: index + (1 if stop != "\n" else 0)].strip()
        return head[:40].strip()

    def _narrate(self, command: dict[str, Any]) -> None:
        """Speak one prepared script and report when the room has heard it."""
        # A narration is explicitly asked for, so it lifts any quiet window a
        # previous stop left behind.
        self.suppress_until = 0.0
        # Two responses cannot be in flight at once: without this the server
        # rejects the narration and the slide sits there in silence.
        if self.output_active.is_set() or self.state.get("speaking"):
            self._cancel_speech()
            time.sleep(0.2)
        text = str(command.get("text", "")).strip()
        identifier = str(command.get("id", "")).strip()
        if not text or not identifier:
            return
        heading = str(command.get("heading", "")).strip()
        extra = str(command.get("instructions", "")).strip()
        if not self.ws_ready.is_set():
            self._write_state(
                narrationActive=None,
                narrationDone=None,
                lastError="narrate: the Realtime connection is not ready",
            )
            self._line("接続待ちのため読み上げできません", kind="error", keep=True)
            return
        with self.purpose_lock:
            self.pending_narration = identifier
        self._write_state(narrationActive=identifier, narrationDone=None)
        prompt = (heading + "の原稿です。\n---\n" + text + "\n---") if heading else (
            "原稿です。\n---\n" + text + "\n---"
        )
        self._send(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": prompt}],
                },
            }
        )
        instructions = self._NARRATION_INSTRUCTIONS
        opening = self._opening_sentence(text)
        if opening:
            instructions += (
                "\n最初に発する文は「" + opening + "」です。"
                "その前に何も言わないでください。"
            )
        if extra:
            # The deck's own guidance is a direction too, so it is labelled as
            # one: unlabelled, it gets read out with the script.
            instructions += (
                "\n話し方についての指示 (声に出さない): " + extra
            )
        self._send(
            {
                "type": "response.create",
                "response": {
                    "metadata": {"sourcevault_purpose": "narrate:" + identifier},
                    "output_modalities": ["audio"],
                    "instructions": instructions,
                    "tool_choice": "none",
                    # No ceiling: the length of a narration is the length of
                    # the script.  A numeric cap here (the session's verbosity
                    # ceiling, or any generous-looking constant) cuts long
                    # slides off mid-sentence, and the cut reads as "finished"
                    # so the deck advances -- observed 2026-08-22.
                    "max_output_tokens": "inf",
                },
            }
        )
        self.narration_label = heading
        self._record("status", (heading + " 説明開始").strip())
        self._mode("narrating", heading)

    def _handle_tool_calls(self, event: dict[str, Any]) -> None:
        """Serve show_slide calls found in a finished response."""
        response = event.get("response", {})
        output = response.get("output", []) if isinstance(response, dict) else []
        for item in output:
            if not isinstance(item, dict):
                continue
            if item.get("type") != "function_call":
                continue
            name = item.get("name")
            if name not in ("show_slide", "ask_sourcevault"):
                continue
            call_id = str(item.get("call_id", ""))
            if not call_id or call_id in self.handled_tool_calls:
                continue
            self.handled_tool_calls.add(call_id)
            target = (
                self._serve_show_slide
                if name == "show_slide"
                else self._serve_ask_sourcevault
            )
            threading.Thread(target=target, args=(item,), daemon=True).start()

    def _serve_show_slide(self, item: dict[str, Any]) -> None:
        """Hand the request to the notebook and wait for what it did.

        Only the kernel can drive the front end, so the request is published in
        the state file and the answer comes back through the control file.  The
        model is told the outcome either way -- a silent tool call would leave
        it guessing whether the slide moved.
        """
        call_id = str(item.get("call_id", ""))
        try:
            arguments = json.loads(item.get("arguments") or "{}")
        except json.JSONDecodeError:
            arguments = {}
        request = {
            "id": call_id,
            "target": str(arguments.get("target", "")).strip().lower(),
            "number": arguments.get("number"),
            "title": str(arguments.get("title", "")).strip(),
            "at": _now(),
        }
        self._write_state(slideRequest=request)
        deadline = time.monotonic() + self.args.slide_tool_timeout
        result: dict[str, Any] | None = None
        while time.monotonic() < deadline and not self.stop_event.is_set():
            result = self.slide_results.pop(call_id, None)
            if result is not None:
                break
            time.sleep(0.1)
        self._write_state(slideRequest=None)
        if result is None:
            self._send_function_output(
                call_id,
                {"status": "error", "message": "ノートブックが応答しませんでした。"},
            )
        else:
            self._send_function_output(call_id, result)
        # The model has to be asked to speak again: a tool result on its own
        # produces no audio.
        self._create_response(
            {
                "type": "response.create",
                "response": {
                    "metadata": {"sourcevault_purpose": "slide_ack"},
                    "output_modalities": ["audio"],
                    "instructions": (
                        "スライドを動かした結果を、一言だけ短く伝えてください。"
                        "内容の説明はしないでください。"
                    ),
                    "tool_choice": "none",
                },
            }
        )

    def _serve_ask_sourcevault(self, item: dict[str, Any]) -> None:
        """Ask the notebook's knowledge layer and let the model say the answer.

        The worker never sees the material itself -- only what the Wolfram side
        decided may be spoken.  That is where the privacy rule lives.
        """
        call_id = str(item.get("call_id", ""))
        try:
            arguments = json.loads(item.get("arguments") or "{}")
        except json.JSONDecodeError:
            arguments = {}
        query = str(arguments.get("query", "")).strip()
        request = {
            "id": call_id,
            "query": query,
            "allowWeb": bool(arguments.get("allow_web", False)),
            "at": _now(),
        }
        self._write_state(askRequest=request)
        self._mode("thinking")
        if request.get("allowWeb"):
            # A web lookup takes ten-odd seconds.  Silence reads as a freeze to
            # the room, so say something first -- and only then start waiting.
            self._create_response(
                {
                    "type": "response.create",
                    "response": {
                        "metadata": {"sourcevault_purpose": "ask_wait"},
                        "output_modalities": ["audio"],
                        "instructions": (
                            "「少し調べますね」とだけ短く言ってください。"
                            "内容についての推測は言わないでください。"
                        ),
                        "tool_choice": "none",
                    },
                }
            )
        deadline = time.monotonic() + self.args.ask_tool_timeout
        result: dict[str, Any] | None = None
        while time.monotonic() < deadline and not self.stop_event.is_set():
            result = self.ask_results.pop(call_id, None)
            if result is not None:
                break
            time.sleep(0.05)
        self._write_state(askRequest=None)
        if result is None:
            self._send_function_output(
                call_id,
                {"status": "error", "message": "資料を引けませんでした。"},
            )
        else:
            self._send_function_output(call_id, result)
        self._create_response(
            {
                "type": "response.create",
                "response": {
                    "metadata": {"sourcevault_purpose": "ask_ack"},
                    "output_modalities": ["audio"],
                    "instructions": (
                        "いま返ってきた資料の answer だけを根拠に、日本語で短く答えてください。"
                        "answer に無いことを足さないでください。"
                        "status が blocked なら、その内容は非公開の資料が必要なので"
                        "この場では答えられない、と一言で伝えてください。"
                        "needWeb が true なら、ウェブで調べてよいか一言だけ尋ねてください。"
                    ),
                    "tool_choice": "none",
                },
            }
        )

    def _create_response(self, payload: dict[str, Any], wait: float = 12.0) -> bool:
        """Ask the model to speak, but never while it is already speaking.

        Serving a tool call takes a notebook round-trip, and by the time the
        answer comes back the room may have opened another turn.  Sending into
        that earns conversation_already_has_active_response and no audio at
        all, so wait for the running response to finish first.  Called from the
        tool-serving threads, never from the event loop.
        """
        deadline = time.monotonic() + max(0.0, wait)
        while self.response_active.is_set() and not self.stop_event.is_set():
            if time.monotonic() >= deadline:
                self._write_state(
                    lastError="応答が重なったため、追加の発話を見送りました。"
                )
                return False
            time.sleep(0.05)
        self._send(payload)
        return True

    def _send_function_output(self, call_id: str, payload: dict[str, Any]) -> None:
        self._send(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "function_call_output",
                    "call_id": call_id,
                    "output": json.dumps(
                        payload, ensure_ascii=False, separators=(",", ":")
                    ),
                },
            }
        )

    def _end_talk(self, command: dict[str, Any]) -> None:
        """Stop presenting and stay quiet until spoken to.

        Three separate things have to happen, because each covers a different
        way the model starts talking again: cancel what is playing, refuse any
        response that appears in the next few seconds (one may already be in
        flight), and close the presentation context so the *next* real turn is
        answered as a question rather than continued as a talk.
        """
        quiet = float(command.get("quietSeconds", 4.0))
        self._cancel_speech()
        self.suppress_until = time.monotonic() + max(0.0, quiet)
        # Do not let the room's noise (or the tail of the speaker) open a turn
        # while the stop is settling.
        self.input_blocked_until = max(
            self.input_blocked_until, time.monotonic() + min(2.0, max(0.0, quiet))
        )
        self._send({"type": "input_audio_buffer.clear"})
        self._send(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [
                        {
                            "type": "input_text",
                            "text": (
                                "発表はここで終了しました。"
                                "以後は自分から話し始めないでください。"
                                "話しかけられたときだけ、聞かれたことに答えてください。"
                            ),
                        }
                    ],
                },
            }
        )
        self._record("status", "発表を終了しました")
        self._mode("ended")

    def _cancel_speech(self) -> None:
        """Stop the current utterance and drop what is still queued."""
        # Clear the purpose *before* letting the playback loop finish the
        # period, or the cancelled narration would still be reported as heard
        # and the notebook would advance the slide.
        with self.purpose_lock:
            self.output_purpose = "normal"
            self.pending_narration = None
        # Only cancel something that is actually running: cancelling nothing
        # comes back as an error event and that error is what the room would
        # be left looking at on the status bar.
        if self.output_active.is_set() or self.state.get("speaking"):
            self._send({"type": "response.cancel"})
        self._drop_playback()
        self.output_done.set()
        self.narration_label = ""
        self._write_state(narrationActive=None, speaking=False)
        # Late lines from the response just killed must not paint over the
        # mode the caller is about to set.
        self.suppress_until = max(self.suppress_until, time.monotonic() + 1.5)
        self._mode(self._ready_mode())

    def _control_worker(self) -> None:
        path = Path(self.args.control_file) if self.args.control_file else None
        while not self.stop_event.is_set():
            time.sleep(0.1)
            if path is None:
                continue
            try:
                size = path.stat().st_size
            except OSError:
                continue
            if size < self._control_offset:
                # Truncated or replaced: start over rather than read garbage.
                self._control_offset = 0
            if size == self._control_offset:
                continue
            try:
                with path.open("rb") as handle:
                    handle.seek(self._control_offset)
                    chunk = handle.read()
            except OSError:
                continue
            # Only whole lines: a writer may be mid-append.
            cut = chunk.rfind(b"\n")
            if cut < 0:
                continue
            self._control_offset += cut + 1
            for line in chunk[: cut + 1].splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    command = json.loads(line.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if not isinstance(command, dict):
                    continue
                try:
                    self._apply_command(command)
                except Exception as exc:
                    self._write_state(
                        lastError=f"control: {type(exc).__name__}: {exc}"
                    )

    def _status_worker(self) -> None:
        while not self.stop_event.is_set():
            time.sleep(1.0)
            peak = self._input_peak
            self._input_peak = 0.0
            self._write_state(heartbeat=_now(), inputPeak=round(peak, 3))

    # ------------------------------------------------------------------- run

    def run(self) -> int:
        if not self.api_key:
            self._write_state(status="error", lastError="OPENAI_API_KEY is not set")
            return 2
        threads = [
            threading.Thread(target=self._microphone_worker, daemon=True),
            threading.Thread(target=self._input_sender, daemon=True),
            threading.Thread(target=self._playback_worker, daemon=True),
            threading.Thread(target=self._control_worker, daemon=True),
            threading.Thread(target=self._status_worker, daemon=True),
        ]
        for thread in threads:
            thread.start()
        self._mode("connecting")

        reconnects = 0
        failed_starts = 0
        try:
            while not self.stop_event.is_set():
                self.session_ok = False
                url = (
                    "wss://api.openai.com/v1/realtime?model="
                    + quote(self.args.model, safe="")
                )
                headers = [f"Authorization: Bearer {self.api_key}"]
                if self.args.safety_identifier:
                    headers.append(
                        f"OpenAI-Safety-Identifier: {self.args.safety_identifier}"
                    )
                app = websocket.WebSocketApp(
                    url,
                    header=headers,
                    on_open=self._on_open,
                    on_message=self._on_message,
                    on_error=self._on_error,
                    on_close=self._on_close,
                )
                with self.ws_lock:
                    self.ws = app
                app.run_forever(ping_interval=20, ping_timeout=10)
                with self.ws_lock:
                    self.ws = None
                self.ws_ready.clear()
                if self.stop_event.is_set():
                    break
                if self.session_ok:
                    failed_starts = 0
                else:
                    failed_starts += 1
                    if failed_starts >= 3:
                        # Three connections that never reached session.created:
                        # the key, the model or the network is wrong, and
                        # retrying is just noise on someone else's bill.
                        self._write_state(status="error")
                        self._line(
                            "接続できません。APIキーとモデル名を確認してください",
                            kind="error",
                            keep=True,
                        )
                        break
                # Back off so a flapping connection does not spin.
                if self.stop_event.wait(min(2.0 ** failed_starts, 15.0)):
                    break
                reconnects += 1
                self._write_state(reconnects=reconnects)
        finally:
            self.stop_event.set()
            self.ws_ready.clear()
            if self.args.control_file:
                try:
                    Path(self.args.control_file).unlink()
                except OSError:
                    pass
            # A run that ended on an error keeps the error on the status bar:
            # overwriting it with "終了しました" would hide the only clue the
            # notebook ever gets about why the conversation never started.
            with self.state_lock:
                failed = self.state.get("status") == "error"
            self._write_state(
                status="error" if failed else "stopped", connected=False
            )
            if not failed:
                self._mode("stopped")
        return 0


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-file", default="")
    parser.add_argument("--control-file", default="")
    parser.add_argument("--model", default="gpt-realtime-2.1")
    parser.add_argument("--voice", default="marin")
    parser.add_argument(
        "--instructions",
        default=os.environ.get(
            "SOURCEVAULT_REALTIME_INSTRUCTIONS",
            "日本語で自然かつ簡潔に会話してください。",
        ),
    )
    parser.add_argument(
        "--api-key-stdin",
        action="store_true",
        help="read the API key as the first line of stdin (not via the environment)",
    )
    parser.add_argument(
        "--instructions-file",
        default="",
        help="UTF-8 file holding the session instructions (wins over --instructions)",
    )
    parser.add_argument(
        "--verbosity",
        default="normal",
        help="minimal | brief | normal | detailed | thorough, or 0..1",
    )
    parser.add_argument(
        "--slide-tool",
        action="store_true",
        help="expose the show_slide function so the deck can be driven by voice",
    )
    parser.add_argument("--slide-tool-timeout", type=float, default=8.0)
    parser.add_argument(
        "--ask-tool",
        action="store_true",
        help="expose ask_sourcevault so questions are answered from the vault",
    )
    parser.add_argument("--ask-tool-timeout", type=float, default=45.0)
    parser.add_argument(
        "--input-gate",
        type=float,
        default=0.0,
        help="drop microphone chunks whose peak is below this (0..1); 0 = off",
    )
    parser.add_argument("--input-device", default="")
    parser.add_argument("--output-device", default="")
    parser.add_argument("--chunk-ms", type=int, default=20)
    parser.add_argument("--vad-threshold", type=float, default=0.5)
    # 350 ms は日本語の自然な間で切れる: 言い終える前に答えられてしまう。
    parser.add_argument("--prefix-padding-ms", type=int, default=300)
    parser.add_argument("--silence-duration-ms", type=int, default=800)
    # 400ms では自分の声の反響を拾って勝手に答え始めることがある。
    parser.add_argument("--output-cooldown-ms", type=int, default=1200)
    parser.add_argument(
        "--turn-detection",
        choices=("semantic", "server"),
        default="semantic",
        help="semantic = 言い終えたかをモデルが判断する (日本語向け)",
    )
    parser.add_argument(
        "--vad-eagerness",
        choices=("low", "medium", "high", "auto"),
        default="low",
        help="semantic のとき、どれだけ早く話し終えたと見なすか",
    )
    parser.add_argument("--allow-barge-in", action="store_true")
    parser.add_argument(
        "--start-muted",
        action="store_true",
        help="connect but do not send the microphone until unmuted",
    )
    parser.add_argument("--transcribe-input", action="store_true")
    parser.add_argument("--transcription-model", default="gpt-4o-mini-transcribe")
    parser.add_argument("--safety-identifier", default="")
    parser.add_argument("--max-messages", type=int, default=40)
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="print the audio devices as JSON and exit",
    )
    return parser.parse_args(argv)


def _list_devices() -> int:
    default_input, default_output = sd.default.device
    devices = []
    for index, device in enumerate(sd.query_devices()):
        devices.append(
            {
                "index": index,
                "name": str(device.get("name", "")),
                "hostApi": str(
                    sd.query_hostapis(device.get("hostapi", 0)).get("name", "")
                ),
                "inputChannels": int(device.get("max_input_channels", 0)),
                "outputChannels": int(device.get("max_output_channels", 0)),
                "defaultInput": index == default_input,
                "defaultOutput": index == default_output,
            }
        )
    sys.stdout.write(
        json.dumps(
            {"status": "ok", "devices": devices},
            ensure_ascii=False,
        )
    )
    sys.stdout.write("\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    if args.list_devices:
        return _list_devices()
    # The key arrives on stdin so that nothing has to put it in the
    # environment (the Wolfram side cannot pass one) or on disk.
    args.api_key = ""
    if args.api_key_stdin:
        try:
            args.api_key = (sys.stdin.readline() or "").strip()
        except Exception:
            args.api_key = ""
    if not args.state_file:
        sys.stderr.write("--state-file is required\n")
        return 2
    return RealtimeBridge(args).run()


if __name__ == "__main__":
    raise SystemExit(main())
