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

Two APIs are spoken, chosen by the model (or --api):

  * Realtime (gpt-realtime-*): ``RealtimeBridge``.  One model hears, reasons,
    calls show_slide / ask_sourcevault and speaks.
  * Live (gpt-live-*): ``LiveBridge``.  A full-duplex voice front end that
    delegates task work.  This worker uses *client* delegation: when GPT-Live
    hands a task over, the worker reads the recent transcript and serves it
    from the same notebook-side handlers the Realtime tools use (slide
    control, SourceVault and -- with permission -- the web), then returns the
    verified result with session.commentary.append.
"""

from __future__ import annotations

import argparse
import array
import base64
import json
import os
import queue
import re
import sys
import threading
import time
import unicodedata
from collections import deque
from pathlib import Path
from typing import Any
from urllib.parse import quote

import sounddevice as sd
import websocket

#: Bumped whenever the notebook side needs a newer worker than one that may
#: already be running (the control/state contract).  A stale worker is
#: restarted rather than silently ignoring commands it does not know.
#: 1.5: GPT-Live (--api live, client delegation).
#: 1.6: narrate carries "interrupt" / "interruptWords" / "speechModel" / "slide"
#:      (always-on question modes during a GPT-Live talk).
#: 1.7: GPT-Live scripts go in as quiet context first (no mid-script stalls);
#:      answers are composed by the model from the lookup (matchedQuestion).
WORKER_VERSION = "1.7"

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
    "interrupted": "発表を一時中断 (質疑中)",
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
    #: Which API this bridge speaks (published in the state as "api").
    API = "realtime"

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
            "api": self.API,
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
        #: HTTP status of a refused WebSocket handshake (401 / 403 / ...).
        self.handshake_status: int | None = None
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
        # A refused handshake carries the HTTP status.  401/403/404 do not get
        # better by retrying, so the run loop stops on them (see run()).
        status = getattr(error, "status_code", None)
        if isinstance(status, int):
            self.handshake_status = status
            self._write_state(
                lastError=f"{type(error).__name__}: {error}", handshakeStatus=status
            )
            return
        self._write_state(lastError=f"{type(error).__name__}: {error}")

    def _handshake_message(self, status: int) -> str:
        if status == 401:
            return "API キーが受け付けられませんでした (401)。"
        if status == 403:
            return "接続が拒否されました (403)。この API キー / プロジェクトの権限とモデルを確認してください。"
        return f"モデルまたは接続先が見つかりません ({status})。モデル名を確認してください。"

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

    def _ws_url(self) -> str:
        return "wss://api.openai.com/v1/realtime?model=" + quote(
            self.args.model, safe=""
        )

    def _ws_headers(self) -> list[str]:
        headers = [f"Authorization: Bearer {self.api_key}"]
        if self.args.safety_identifier:
            headers.append(f"OpenAI-Safety-Identifier: {self.args.safety_identifier}")
        return headers

    def _extra_threads(self) -> list[threading.Thread]:
        """Threads a subclass needs besides audio, control and status."""
        return []

    def _run_forever_options(self) -> dict[str, Any]:
        """Extra keyword arguments for WebSocketApp.run_forever."""
        return {}

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
        ] + self._extra_threads()
        for thread in threads:
            thread.start()
        self._mode("connecting")

        reconnects = 0
        failed_starts = 0
        try:
            while not self.stop_event.is_set():
                self.session_ok = False
                url = self._ws_url()
                headers = self._ws_headers()
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
                self.handshake_status = None
                app.run_forever(
                    ping_interval=20, ping_timeout=10, **self._run_forever_options()
                )
                with self.ws_lock:
                    self.ws = None
                self.ws_ready.clear()
                if self.stop_event.is_set():
                    break
                if not self.session_ok and self.handshake_status in (401, 403, 404):
                    # Refused outright: retrying cannot change the answer.
                    self._write_state(status="error")
                    self._line(
                        "エラー: " + self._handshake_message(self.handshake_status),
                        kind="error",
                        keep=True,
                    )
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


# =========================================================================
# GPT-Live (gpt-live-*) -- full duplex voice with client delegation
# =========================================================================

LIVE_URL = "wss://api.openai.com/v1/live/sessions"

#: session.instructions/thinking/commentary.append carry at most 500 tokens.
#: Japanese runs close to one token per character, so budgets are counted
#: with ``estimate_tokens`` and kept well under the cap.
LIVE_APPEND_MAX_TOKENS = 460
#: Script carried by one narration append (the directions around it use the
#: rest of the 500-token budget).  Longer talks go out in several appends,
#: each after the previous one has been heard.
LIVE_NARRATION_CHUNK_CHARS = 260
#: Output chunks whose peak is below this count as silence, not speech.
LIVE_VOICED_PEAK = 0.01
#: A needWeb answer waits this long for the room's yes/no.
LIVE_WEB_PERMISSION_SECONDS = 45.0

_SENTENCE_END = re.compile(r"(?<=[。！？!?\n])")
_KANJI_DIGITS = {
    "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4,
    "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
}
_NUM = r"(\d+|[〇零一二三四五六七八九十百]+)"
#: Words that ask for the display to *move*.  "前のスライドの図は何?" is a
#: question about content, not a request to go back.
_MOVE = re.compile(
    r"戻|進め|進ん|進も|進む|めく|送っ|送り|送れ|見せ|出して|出せ|表示|開い|開け|開こ|"
    r"移っ|移動|行っ|行こ|行け|飛ん|飛ば|映し|映せ|切り替え|切替|ジャンプ|お願い|"
    r"go to|go back|show|open|next slide|previous slide",
    re.IGNORECASE,
)
_QUESTION = re.compile(
    r"[?？]|何|なに|なん|どう|なぜ|どこ|だれ|誰|いつ|教えて|とは|ですか|ますか|でしょうか"
)
_YES = re.compile(
    r"^(はい|ええ|うん|お願い|おねがい|どうぞ|いいよ|いいです|いいですよ|構いません|"
    r"かまいません|調べて|しらべて|ok|okay|オーケー|yes|sure|please|go ahead)",
    re.IGNORECASE,
)
_NO = re.compile(
    r"(いいえ|いや|結構です|けっこうです|やめて|やめとく|不要|いらない|要らない|"
    r"しなくて|調べなくて|\bno\b|don't|do not)",
    re.IGNORECASE,
)


def resolve_api(model: str, requested: str = "auto") -> str:
    """"live" for gpt-live-* models, "realtime" otherwise (or as requested)."""
    requested = str(requested or "auto").strip().casefold()
    if requested in ("live", "realtime"):
        return requested
    return "live" if str(model).strip().casefold().startswith("gpt-live") else "realtime"


def estimate_tokens(text: str) -> int:
    """Rough token count: CJK about one token a character, other text a quarter."""
    wide = sum(1 for ch in text if ord(ch) > 0x2E7F)
    return wide + (len(text) - wide + 3) // 4


def split_sentences(text: str) -> list[str]:
    return [piece for piece in _SENTENCE_END.split(text) if piece.strip()]


def clip_for_append(text: str, limit: int = LIVE_APPEND_MAX_TOKENS) -> str:
    """Fit one append's content under the token cap, cutting at a sentence."""
    text = str(text).strip()
    if estimate_tokens(text) <= limit:
        return text
    out = ""
    for piece in split_sentences(text):
        if estimate_tokens(out + piece) > limit - 2:
            break
        out += piece
    if not out:
        out = text
        while out and estimate_tokens(out) > limit - 2:
            out = out[: max(1, int(len(out) * 0.9))]
    return out.rstrip() + "…"


def narration_chunks(text: str, limit: int = LIVE_NARRATION_CHUNK_CHARS) -> list[str]:
    """Split a script into appends of at most ``limit`` characters.

    Cuts fall between sentences; a single sentence longer than the limit is
    cut at a comma (or hard, as a last resort).  Nothing is dropped: joining
    the chunks gives the script back.
    """
    chunks: list[str] = []
    current = ""
    for sentence in split_sentences(text.strip()):
        while len(sentence) > limit:
            if current:
                chunks.append(current)
                current = ""
            cut = sentence.rfind("、", 0, limit)
            cut = cut + 1 if cut > limit // 3 else limit
            chunks.append(sentence[:cut])
            sentence = sentence[cut:]
        if current and len(current) + len(sentence) > limit:
            chunks.append(current)
            current = sentence
        else:
            current += sentence
    if current.strip():
        chunks.append(current)
    return [chunk for chunk in chunks if chunk.strip()]


def _to_int(token: str) -> int | None:
    token = unicodedata.normalize("NFKC", token)
    if token.isdigit():
        return int(token)
    total, current = 0, 0
    for ch in token:
        if ch in _KANJI_DIGITS:
            current = _KANJI_DIGITS[ch]
        elif ch == "十":
            total += (current or 1) * 10
            current = 0
        elif ch == "百":
            total += (current or 1) * 100
            current = 0
        else:
            return None
    total += current
    return total or None


def parse_slide_intent(text: str) -> dict[str, Any] | None:
    """Read a slide-control request out of a transcript, or None.

    GPT-Live delegates without saying what the task is, so the request has to
    come from the words.  Only phrasings that ask the display to move count:
    a question *about* a slide ("前のスライドの図は何?") is left to the
    knowledge lookup.
    """
    t = re.sub(r"\s+", "", unicodedata.normalize("NFKC", str(text)))
    if not t:
        return None
    moving = bool(_MOVE.search(t))
    short = len(t) <= 12
    if _QUESTION.search(t) and not moving:
        return None
    if not moving and not short:
        return None
    number = re.search(_NUM + r"(?:枚目|ページ目|ページ|番目のスライド|番目のページ)", t) or re.search(
        r"(?:スライド|ページ)(?:の)?(?:番号)?" + _NUM + r"(?:枚目|番目|番)?", t
    )
    if number:
        value = _to_int(number.group(1))
        if value:
            return {"target": "number", "number": value}
    if re.search(r"(最初|先頭|はじめ|始め|初め)(の|に)?(スライド|ページ)|最初に戻|先頭に戻", t):
        return {"target": "first"}
    if re.search(r"最後(の)?(スライド|ページ)|最後まで(進|飛|行)", t):
        return {"target": "last"}
    if re.search(
        r"(一つ前|ひとつ前|1つ前|前)(の)?(スライド|ページ)|(スライド|ページ)を?(一つ|ひとつ|1つ)?戻|"
        r"(一つ|ひとつ|1つ)?前に戻|戻して|戻って|previousslide|goback",
        t, re.IGNORECASE,
    ):
        return {"target": "previous"}
    if re.search(
        r"次(の)?(スライド|ページ)|(スライド|ページ)を?(進め|めく|送)|次へ(進|行)|"
        r"次に(進|行)|先に進|進めて|めくって|nextslide",
        t, re.IGNORECASE,
    ):
        return {"target": "next"}
    titled = re.search(
        r"(.{1,30}?)(?:について|に関する|の話)?の(?:スライド|ページ)(?:を|に|へ)?"
        r"(?:見せ|出し|表示|開|映|戻|移|行)",
        t,
    )
    if titled:
        title = re.sub(r"^(あの|その|この|さっきの|例の)", "", titled.group(1))
        if title and title not in ("次", "前", "最初", "最後", "一つ前", "ひとつ前"):
            return {"target": "title", "title": title}
    return None


#: Leading hesitations.  あの / その / まあ are also ordinary words
#: ("そのテキストは?"), so they only count when a pause follows.
_FILLERS = re.compile(
    r"^(?:(?:えっと|えーと|ええと|えー|あのー|あのう|うーん)[、,。\s]*"
    r"|(?:あの|その|まあ|すみません)[、,。\s]+)"
)


def strip_fillers(text: str) -> str:
    """Drop leading hesitations: "えっと、計算と自然って…" -> "計算と自然って…"."""
    original = str(text).strip()
    text = original
    for _ in range(3):
        stripped = _FILLERS.sub("", text)
        if stripped == text:
            break
        text = stripped
    return text.strip() or original


def is_affirmative(text: str) -> bool:
    t = re.sub(r"\s+", "", unicodedata.normalize("NFKC", str(text))).casefold()
    return bool(t) and not _NO.search(t) and bool(_YES.search(t))


def is_negative(text: str) -> bool:
    t = re.sub(r"\s+", "", unicodedata.normalize("NFKC", str(text))).casefold()
    return bool(t) and bool(_NO.search(t))


class LiveBridge(RealtimeBridge):
    """GPT-Live over the primary WebSocket with client delegation.

    What changes against the Realtime bridge, and why:

      * The session timeline advances with input frames, so the microphone is
        never simply withheld: while it is muted or half-duplex blocked, the
        worker sends silence instead of nothing.
      * GPT-Live decides by itself when to speak and has no response.create /
        response.done for speech.  An utterance is the stretch of voiced
        output audio; it is over when no voiced audio has arrived for a while
        and everything received has been played.
      * Tool calls become delegations.  session.delegation.created carries no
        task text, so the worker reads the recent transcript and serves the
        request itself: slide moves through the notebook's slide handler,
        questions through its ask handler (SourceVault, then -- only after the
        room says yes -- the web).  The verified result goes back with
        session.commentary.append under the same delegation id.
      * A prepared script is spoken through session.instructions.append (the
        documented way to request specific wording), in pieces under the
        500-token cap, each sent after the previous one has been heard.
    """

    API = "live"

    def __init__(self, args: argparse.Namespace) -> None:
        super().__init__(args)
        self._event_counter = 0
        self.session_id: str | None = None
        self.session_closed = threading.Event()
        #: Acknowledgments of our appends (client_event_id -> event).
        self.ack_lock = threading.Lock()
        self.acks: dict[str, threading.Event] = {}
        #: Bumped whenever the narration being delivered changes (new piece,
        #: cancel, suspend), so a late delivery thread knows to stand down.
        self.narration_gen = 0
        #: What the model has said of the current piece (output transcript).
        self.narration_spoken = ""
        #: Transcript fragments as they arrive: (seq, monotonic, text).
        self.transcript_lock = threading.Lock()
        self.user_fragments: deque[tuple[int, float, str]] = deque(maxlen=600)
        self.user_seq = 0
        self.user_cut = 0
        self.last_user_delta_at = 0.0
        self._utterance = ""
        #: Recent text history, used to seed a replacement session.
        self.history: deque[dict[str, str]] = deque(maxlen=24)
        #: Output bookkeeping (see _maybe_finish_live_output).
        self.voiced_lock = threading.Lock()
        self.voiced_pending = 0
        self.last_voiced_output_at = 0.0
        self.discard_until_gap = False
        self.discard_last_voiced = 0.0
        self.discard_deadline = 0.0
        #: Narration in pieces.
        self.narration_rest: list[str] = []
        self.narration_extra = ""
        self.narration_sent_at = 0.0
        self.narration_current = ""
        self.narration_resent = False
        self.narration_started_speaking = False
        #: Delegations being served, and serialization of notebook requests
        #: (the state file has one slot for each kind of request).
        self.delegation_lock = threading.Lock()
        self.active_delegations: set[str] = set()
        self.kernel_lock = threading.Lock()
        #: A lookup that found nothing locally and waits for web permission:
        #: (query, delegation id, when).
        self.pending_web: tuple[str, str, float] | None = None
        self.web_claimed_at = 0.0
        # ---- being interrupted during a talk (always-on question modes) ----
        #: "none" = question time only (the notebook mutes the microphone while
        #: a script is read); "detect" = someone else speaking over the talk
        #: opens a Q&A and GPT-Live judges whether it was a question; "words"
        #: = only an utterance containing an allowed word ("質問", "スライド")
        #: opens it.  Outside a Q&A the model hears nothing of the room.
        self.interrupt_mode = "none"
        self.interrupt_words: list[str] = []
        self.qa_open = False
        self.qa_opened_at = 0.0
        self.qa_kind = ""
        #: The slide the talk was on when the Q&A opened, and whether the
        #: Q&A moved the deck (then it is put back before the talk goes on).
        self.qa_home_slide: int | None = None
        self.qa_slide_moves = 0
        #: A narrate that arrived while a Q&A was open (the notebook moved on
        #: to the next slide just as someone spoke): read after the Q&A.
        self.deferred_narration: dict[str, Any] | None = None
        self.suspended: dict[str, Any] | None = None
        self.resuming = False
        self.interruptions = 0
        self.narration_slide: int | None = None
        per_second = max(1, int(1000 / max(1, args.chunk_ms)))
        self._frames_per_second = per_second
        self.mic_ring: deque[bytes] = deque(maxlen=per_second * 2)
        #: Peaks of what was just played, to tell our own echo from a person.
        self.far_peaks: deque[tuple[float, float]] = deque(maxlen=600)
        self.echo_ratios: deque[float] = deque(maxlen=per_second * 5)
        self.floor_peaks: deque[float] = deque(maxlen=per_second * 5)
        self.speech_flags: deque[bool] = deque(
            maxlen=max(1, int(args.bargein_ms / max(1, args.chunk_ms)))
        )
        self.segment: list[bytes] | None = None
        self.segment_started = 0.0
        self.segment_last_speech = 0.0
        #: Local keyword spotting (Vosk, grammar-restricted) for "words".
        self.keyword_model: Any = None
        self.keyword_model_path = ""
        self.keyword_status = "off"
        self.keyword_unknown: list[str] = []
        self.keyword_queue: queue.Queue[tuple[str, Any]] = queue.Queue(maxsize=600)
        self._write_state(
            api=self.API,
            delegation="client",
            turnDetection="live",
            sessionId=None,
            usageSeconds=0,
            contextUsage=None,
            delegations=0,
            lastDelegation=None,
            closeReason=None,
            interruptMode="none",
            interruptGate="none",
            qaOpen=False,
            interrupted=False,
            interruptions=0,
            lastInterrupt=None,
            keywordStatus="off",
            echoCoupling=None,
        )

    # ------------------------------------------------------------ plumbing

    def _ws_url(self) -> str:
        return LIVE_URL

    def _run_forever_options(self) -> dict[str, Any]:
        # websocket-client adds "Origin: https://api.openai.com" unless told
        # not to.  The official SDK (websockets) sends no Origin, and an
        # Origin marks the request as coming from a browser -- where a
        # standard API key must never be used.  GPT-Live refused this worker
        # with a bare 403 after the key had authenticated (2026-09-19).
        return {"suppress_origin": True}

    def _handshake_message(self, status: int) -> str:
        if status == 403:
            return (
                "GPT-Live への接続が拒否されました (403)。この API キー / プロジェクトで "
                f"{self.args.model} が使えるか (権限・モデル制限) を確認してください。"
            )
        return super()._handshake_message(status)

    def _extra_threads(self) -> list[threading.Thread]:
        return [
            threading.Thread(target=self._live_housekeeping, daemon=True),
            threading.Thread(target=self._keyword_worker, daemon=True),
        ]

    def _next_event_id(self, prefix: str) -> str:
        self._event_counter += 1
        return f"sv_{prefix}_{self._event_counter}"

    def _append(self, kind: str, delegation_id: str | None, content: str) -> str | None:
        """session.instructions|thinking|commentary.append; the event id, or
        None when nothing was sent.  _wait_ack(id) waits for its injection."""
        text = clip_for_append(content)
        if not text:
            return None
        event_id = self._next_event_id(kind)
        with self.ack_lock:
            if len(self.acks) > 200:
                self.acks.clear()
            self.acks[event_id] = threading.Event()
        sent = self._send(
            {
                "type": f"session.{kind}.append",
                "event_id": event_id,
                "delegation_id": delegation_id,
                "content": text,
            }
        )
        return event_id if sent else None

    def _ack(self, event_id: Any) -> None:
        with self.ack_lock:
            waiter = self.acks.get(str(event_id)) if event_id else None
        if waiter is not None:
            waiter.set()

    def _wait_ack(self, event_id: str | None, timeout: float) -> bool:
        """Wait until the model has taken an append in (or it was refused)."""
        if not event_id:
            return False
        with self.ack_lock:
            waiter = self.acks.get(event_id)
        if waiter is None:
            return False
        done = waiter.wait(timeout)
        with self.ack_lock:
            self.acks.pop(event_id, None)
        return done

    def _live_instructions(self) -> str:
        """Session instructions: the notebook's, the verbosity clause, and how
        to use the backend this worker provides."""
        lines = [self._effective_instructions()]
        if self.args.slide_tool:
            lines.append(
                "スライドの表示を変える依頼 (次・前・最初・最後・何枚目・特定の内容のスライド) "
                "を受けたら、自分で「表示しました」とは言わず、必ずバックエンドに委譲してください。"
                "結果が返ったら一言だけ短く伝えてください。"
            )
        if self.args.ask_tool:
            lines.append(
                "発表の内容や、そこで触れた事実・数値・出典について聞かれたら、推測で答えずに"
                "必ずバックエンドに委譲してください。結果を待つ間は「確認しますね」などの一言だけで"
                "つなぎ、結果が届いたら添えられた指示に従って短く答えてください。"
                "結果が「ウェブで調べてよいか」を尋ねるものなら、利用者に一言だけ尋ね、"
                "その返事 (はい・いいえ) もバックエンドに委譲してください。"
            )
        lines.append(
            "原稿を読むよう指示されたときは、その原稿だけを書かれたとおりに読み、"
            "前置きや感想を足さず、読み終えたら黙って待ってください。"
        )
        lines.append(
            "聞き手の独り言・相槌・雑談・咳などには反応しないでください。"
            "あなたへの質問や呼びかけのときだけ答えてください。"
        )
        return "\n".join(line for line in lines if line)

    def _session_start_event(self) -> dict[str, Any]:
        session: dict[str, Any] = {
            "model": self.args.model,
            "instructions": self._live_instructions(),
            "audio": {
                "format": {"type": "audio/pcm", "rate": RATE},
                "output": {"voice": self.args.voice},
            },
            "delegation": {"type": "client"},
        }
        seed = self._seed_history()
        if seed:
            session["input"] = seed
        return {
            "type": "session.start",
            "event_id": self._next_event_id("start"),
            "session": session,
        }

    def _seed_history(self) -> list[dict[str, Any]]:
        """Recent text for a replacement session (empty on the first one).

        The Live history accepts up to 128 messages and 8,192 tokens; this
        stays far below both.
        """
        items: list[dict[str, Any]] = []
        budget = 5000
        for entry in reversed(list(self.history)):
            text = entry["text"][:400]
            cost = estimate_tokens(text)
            if cost > budget:
                break
            budget -= cost
            part = "input_text" if entry["role"] == "user" else "output_text"
            items.append(
                {
                    "type": "message",
                    "role": entry["role"],
                    "content": [{"type": part, "text": text}],
                }
            )
        items.reverse()
        return items

    def _remember(self, role: str, text: str) -> None:
        text = " ".join(str(text).split())
        if text:
            self.history.append({"role": role, "text": text})

    # --------------------------------------------------------------- audio

    def _input_blocked(self) -> bool:
        # During a talk in an always-on mode the model hears the room only
        # once a Q&A has been opened; until then the worker listens locally.
        if self.interrupt_mode != "none" and not self.qa_open:
            return True
        return super()._input_blocked()

    def _input_frame(self, raw: bytes) -> bytes:
        """What is sent for one captured frame: the audio, or silence.

        Withholding frames would stall the session timeline (acknowledgments
        wait for frame progress), so a closed microphone sends zeros.
        """
        if self._input_blocked():
            return bytes(len(raw))
        peak = self._peak_of(raw)
        if peak > self._input_peak:
            self._input_peak = peak
        if peak < self.args.input_gate:
            return bytes(len(raw))
        return raw

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
                    if not self.ws_ready.is_set():
                        continue
                    raw = bytes(data)
                    # Local listening first (it may open a Q&A and queue the
                    # words already spoken), then this frame.
                    self._observe_mic(raw)
                    self.mic_ring.append(raw)
                    event = {
                        "type": "session.input_audio.append",
                        "audio": base64.b64encode(self._input_frame(raw)).decode("ascii"),
                    }
                    try:
                        self.input_events.put_nowait(event)
                    except queue.Full:
                        try:
                            self.input_events.get_nowait()
                            self.input_events.put_nowait(event)
                        except (queue.Empty, queue.Full):
                            pass
        except Exception as exc:
            self._fatal(f"microphone: {type(exc).__name__}: {exc}")

    def _input_sender(self) -> None:
        sent = 0
        while not self.stop_event.is_set():
            try:
                event = self.input_events.get(timeout=0.1)
            except queue.Empty:
                continue
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
                while not self.stop_event.is_set():
                    try:
                        item = self.play_queue.get(timeout=0.05)
                    except queue.Empty:
                        self._maybe_finish_live_output()
                        continue
                    self._consume_play_item(item, stream.write)
        except Exception as exc:
            self._fatal(f"speaker: {type(exc).__name__}: {exc}")

    def _consume_play_item(self, item: Any, write: Any) -> None:
        """Play one queued chunk and settle the utterance bookkeeping."""
        chunk, voiced = item if isinstance(item, tuple) else (item, True)
        if chunk:
            # What the room is about to hear: the reference for telling our
            # own echo in the microphone from a person speaking.
            self.far_peaks.append((time.monotonic(), self._peak_of(chunk)))
            write(chunk)
            self._played_chunks = getattr(self, "_played_chunks", 0) + 1
            if self._played_chunks % 25 == 0:
                self._write_state(outputChunks=self._played_chunks)
        if voiced:
            with self.voiced_lock:
                self.voiced_pending = max(0, self.voiced_pending - 1)
        self._maybe_finish_live_output()

    def _drop_playback(self) -> None:
        super()._drop_playback()
        with self.voiced_lock:
            self.voiced_pending = 0

    def _idle_seconds(self) -> float:
        idle = self.args.live_idle_ms / 1000.0
        if self.pending_narration is not None:
            idle = max(idle, self.args.live_narration_idle_ms / 1000.0)
        return idle

    def _maybe_finish_live_output(self) -> None:
        """Close the utterance once it has been heard and nothing follows."""
        if not self.output_active.is_set():
            return
        with self.voiced_lock:
            pending = self.voiced_pending
        if pending > 0:
            return
        quiet = time.monotonic() - self.last_voiced_output_at
        if quiet < self._idle_seconds():
            return
        if (
            self.pending_narration is not None
            and self.narration_started_speaking
            and self._narration_coverage() < 0.8
            and quiet < self.args.live_narration_stall_ms / 1000.0
        ):
            # A pause inside the script (measured 2026-09-19: "配信" … 1.5 s …
            # "されているのは…") is not its end; the deck must not move on.
            return
        self._finish_output()

    @staticmethod
    def _plain_length(text: str) -> int:
        return len(re.sub(r"[\s、。，．,.！？!?「」『』（）()・…ー-]", "", str(text)))

    def _narration_coverage(self) -> float:
        """How much of the current piece the model has said (transcript)."""
        piece = self._plain_length(self.narration_current)
        if piece <= 0:
            return 1.0
        spoken = self._plain_length(self.narration_spoken.replace("それでは、説明に戻ります", ""))
        return spoken / piece

    def _begin_output(self) -> None:
        self.output_active.set()
        self.output_done.clear()
        with self.purpose_lock:
            narration = self.pending_narration
            if narration is not None and not self.narration_started_speaking:
                self.narration_started_speaking = True
        self._write_state(speaking=True)
        if narration is not None:
            self._mode("narrating", self.narration_label)
        else:
            self._mode("answering")

    def _on_output_audio(self, audio: str) -> None:
        try:
            raw = base64.b64decode(audio)
        except Exception as exc:
            self._write_state(lastError=f"decode: {type(exc).__name__}: {exc}")
            return
        now = time.monotonic()
        voiced = self._peak_of(raw) >= LIVE_VOICED_PEAK
        if now < self.suppress_until:
            # Asked to be quiet: nothing reaches the room.
            return
        if self.discard_until_gap:
            # The tail of a cancelled utterance keeps arriving until the model
            # has taken the stop instruction in.  The first pause ends it.
            if now > self.discard_deadline or now - self.discard_last_voiced > 0.6:
                self.discard_until_gap = False
            else:
                if voiced:
                    self.discard_last_voiced = now
                return
        if not self.output_active.is_set():
            if not voiced:
                return
            self._begin_output()
        if voiced:
            self.last_voiced_output_at = now
            with self.voiced_lock:
                self.voiced_pending += 1
        self.play_queue.put((raw, voiced))

    def _finish_output(self) -> None:
        self.output_active.clear()
        self.output_done.clear()
        self.input_blocked_until = (
            time.monotonic() + self.args.output_cooldown_ms / 1000.0
        )
        text = self._assistant_text.strip()
        self._assistant_text = ""
        with self.purpose_lock:
            narration = self.pending_narration
            heard = self.narration_started_speaking
            follow = self.narration_rest.pop(0) if (narration and heard and self.narration_rest) else None
        if text:
            self._write_state(lastAssistantText=text[-4000:])
            self._record("assistant", text)
            if narration is None:
                # A script is remembered once, as sent (see _narrate).
                self._remember("assistant", text)
        if narration is not None and heard and follow is not None:
            # The next piece of the same script: the deck waits for the whole.
            self._write_state(speaking=False)
            self._send_narration_piece(follow, first=False)
            return
        if narration is not None and heard:
            with self.purpose_lock:
                self.pending_narration = None
                self.narration_rest = []
            self._write_state(narrationActive=None, narrationDone=narration, speaking=False)
        else:
            self._write_state(speaking=False)
        if time.monotonic() >= self.suppress_until:
            self.narration_label = ""
            self._mode(self._ready_mode())

    # ------------------------------------------------------------- events

    def _on_open(self, ws: websocket.WebSocketApp) -> None:
        # Audio waits for session.started: ws_ready is set there, not here.
        self.session_closed.clear()
        self._write_state(connected=False, lastError=None)
        try:
            ws.send(
                json.dumps(
                    self._session_start_event(),
                    separators=(",", ":"),
                    ensure_ascii=False,
                )
            )
        except Exception as exc:
            self._write_state(lastError=f"session.start: {type(exc).__name__}: {exc}")

    def _on_message(self, _ws: websocket.WebSocketApp, message: str) -> None:
        try:
            event = json.loads(message)
        except json.JSONDecodeError:
            self._write_state(lastError="received malformed JSON")
            return
        kind = str(event.get("type", ""))
        self._set_state(lastEvent=kind)

        if kind == "session.output_audio.delta":
            audio = event.get("delta")
            if isinstance(audio, str) and audio:
                self._on_output_audio(audio)
        elif kind == "session.output_transcript.delta":
            delta = str(event.get("delta", ""))
            self._assistant_text += delta
            if self.pending_narration is not None:
                self.narration_spoken += delta
            self._set_state(lastAssistantText=self._assistant_text[-4000:])
        elif kind in ("session.instructions.appended", "session.thinking.appended",
                      "session.commentary.appended"):
            self._ack(event.get("client_event_id"))
        elif kind == "session.input_transcript.delta":
            self._on_user_transcript(str(event.get("delta", "")))
        elif kind == "session.delegation.created":
            delegation = event.get("delegation") or {}
            identifier = str(delegation.get("id", ""))
            if identifier and delegation.get("target", "client") == "client":
                threading.Thread(
                    target=self._serve_delegation,
                    args=(identifier,),
                    daemon=True,
                ).start()
        elif kind == "session.started":
            session = event.get("session") or {}
            self.session_id = str(session.get("id", "")) or None
            self.session_ok = True
            self.ws_ready.set()
            self._write_state(
                status="running",
                connected=True,
                sessionId=self.session_id,
                lastError=None,
            )
            self._record(
                "status", f"接続しました ({self.args.model} / {self.args.voice})"
            )
            self._mode(self._ready_mode())
        elif kind == "session.usage.updated":
            usage = event.get("usage") or {}
            window = event.get("context_window") or {}
            self._write_state(
                usageSeconds=usage.get("seconds", 0),
                contextUsage=window.get("usage_ratio"),
            )
        elif kind == "session.closed":
            usage = event.get("usage") or {}
            self.session_closed.set()
            self.ws_ready.clear()
            self._write_state(
                closeReason=event.get("reason"),
                usageSeconds=usage.get("seconds", self.state.get("usageSeconds", 0)),
                connected=False,
            )
        elif kind == "error":
            detail = event.get("error", event)
            text = json.dumps(detail, ensure_ascii=False)[:400]
            self._write_state(lastError=text)
            if isinstance(detail, dict):
                # A refused append must not leave a waiter hanging.
                self._ack(detail.get("client_event_id"))
            self._line(
                "エラー: " + self._error_summary(detail, text), kind="error", keep=True
            )
        elif kind == "info":
            self._record("status", json.dumps(event.get("info", event), ensure_ascii=False)[:300])

    def _on_user_transcript(self, delta: str) -> None:
        if not delta:
            return
        now = time.monotonic()
        with self.transcript_lock:
            if now - self.last_user_delta_at > 1.5:
                self._flush_utterance_locked()
            self.user_seq += 1
            self.user_fragments.append((self.user_seq, now, delta))
            self.last_user_delta_at = now
            self._utterance += delta
            utterance = self._utterance
        self._set_state(lastUserText=utterance[-2000:])
        if (
            not self.output_active.is_set()
            and self.pending_narration is None
            and self.state.get("mode") not in ("listening", "thinking")
        ):
            self._mode("listening")

    def _flush_utterance_locked(self) -> None:
        text = self._utterance.strip()
        self._utterance = ""
        if text:
            self._record("user", text)
            self._remember("user", text)

    # ---------------------------------------------------------- delegation

    def _settled_user_text(self, wait: float | None = None) -> str:
        """The words the delegation is about.

        A delegation can arrive before the sentence is complete in the
        transcript, so wait for a short pause first; then take what was said
        since the previous delegation (or, failing that, the last utterance).
        """
        settle = self.args.live_settle_ms / 1000.0
        deadline = time.monotonic() + (wait if wait is not None else settle * 4)
        while time.monotonic() < deadline and not self.stop_event.is_set():
            if time.monotonic() - self.last_user_delta_at >= settle:
                break
            time.sleep(0.05)
        with self.transcript_lock:
            fresh = [f for f in self.user_fragments if f[0] > self.user_cut]
            if self.user_fragments:
                self.user_cut = self.user_fragments[-1][0]
            if not fresh:
                horizon = time.monotonic() - 20.0
                fresh = [f for f in self.user_fragments if f[1] >= horizon]
        return "".join(f[2] for f in fresh).strip()

    def _claim_pending_web(self) -> tuple[str, str, float] | None:
        with self.delegation_lock:
            pending = self.pending_web
            if pending is None:
                return None
            if time.monotonic() - pending[2] > LIVE_WEB_PERMISSION_SECONDS:
                self.pending_web = None
                return None
            self.pending_web = None
            self.web_claimed_at = time.monotonic()
            return pending

    def _serve_delegation(self, delegation_id: str) -> None:
        with self.delegation_lock:
            if delegation_id in self.active_delegations:
                return
            self.active_delegations.add(delegation_id)
            count = int(self.state.get("delegations", 0)) + 1
        self._write_state(delegations=count)
        self._mode("thinking")
        try:
            text = self._settled_user_text()
            self._write_state(lastDelegation={"id": delegation_id, "text": text[-300:]})
            self._record("status", "委譲: " + (text[:80] or "(聞き取れず)"))
            self._handle_request(delegation_id, text)
        except Exception as exc:
            self._write_state(lastError=f"delegation: {type(exc).__name__}: {exc}")
            self._append("commentary", delegation_id, "うまく調べられませんでした。")
        finally:
            with self.delegation_lock:
                self.active_delegations.discard(delegation_id)

    def _handle_request(self, delegation_id: str, text: str) -> None:
        # 1. The answer to "may I search the web?"
        if self.pending_web is not None and (is_affirmative(text) or is_negative(text)):
            pending = self._claim_pending_web()
            if pending is not None:
                if is_negative(text):
                    self._append(
                        "thinking", delegation_id,
                        "利用者はウェブ検索を望みませんでした。ウェブでは調べません。",
                    )
                    return
                self._run_ask(pending[1], pending[0], allow_web=True)
                return
        if (
            text
            and (is_affirmative(text) or is_negative(text))
            and len(text) <= 16
            and time.monotonic() - self.web_claimed_at < 20.0
        ):
            # The watcher already acted on this yes/no.
            self._append("thinking", delegation_id, "ウェブでの確認はすでに進めています。")
            return
        # 2. Moving the deck.
        if self.args.slide_tool and text:
            intent = parse_slide_intent(text)
            if intent is not None:
                self._run_slide(delegation_id, intent)
                return
        # 3. The knowledge lookup.
        if not text:
            self._append(
                "commentary", delegation_id,
                "すみません、うまく聞き取れませんでした。もう一度お願いできますか。",
            )
            return
        if self.args.ask_tool:
            self._run_ask(delegation_id, text, allow_web=False)
            return
        self._append(
            "thinking", delegation_id,
            "手元の資料を引く手段はありません。分かる範囲で短く答え、分からなければそう伝えてください。",
        )

    def _kernel_request(self, slot: str, results: dict[str, dict[str, Any]],
                        request: dict[str, Any], timeout: float) -> dict[str, Any] | None:
        """Publish a request for the notebook and wait for its result."""
        with self.kernel_lock:
            self._write_state(**{slot: request})
            deadline = time.monotonic() + timeout
            result: dict[str, Any] | None = None
            while time.monotonic() < deadline and not self.stop_event.is_set():
                result = results.pop(request["id"], None)
                if result is not None:
                    break
                time.sleep(0.05)
            self._write_state(**{slot: None})
        return result

    def _run_slide(self, delegation_id: str, intent: dict[str, Any]) -> None:
        during_talk = self.qa_open or self.suspended is not None
        if during_talk:
            # Moved during a Q&A: the talk's slide is put back on resuming.
            self.qa_slide_moves += 1
        request = {
            "id": delegation_id,
            "target": intent.get("target", ""),
            "number": intent.get("number"),
            "title": intent.get("title", ""),
            # The notebook must only move the display: the talk is still
            # where it was (the worker resumes it and restores the slide).
            "keepNarration": during_talk,
            "at": _now(),
        }
        result = self._kernel_request(
            "slideRequest", self.slide_results, request, self.args.slide_tool_timeout
        )
        if result is None:
            content = "ノートブックが応答せず、スライドを動かせませんでした。"
        elif str(result.get("status", "")).lower() == "ok":
            number = result.get("slide")
            title = str(result.get("title", "") or "").strip()
            content = (
                f"スライド {number} を表示しました" if number else "スライドを表示しました"
            ) + (f" (「{title}」)" if title else "") + "。"
        else:
            content = str(result.get("message", "") or "スライドを動かせませんでした。")
        self._append("commentary", delegation_id, content)

    def _run_ask(self, delegation_id: str, query: str, *, allow_web: bool) -> None:
        if allow_web:
            # A web lookup takes ten-odd seconds; silence reads as a freeze.
            self._append("commentary", delegation_id, "少し調べますね。")
        else:
            self._append(
                "thinking", delegation_id,
                "資料を確認しています。まだ答えは出ていません。推測で答えないでください。",
            )
        context = self.state.get("lastAssistantText", "") or ""
        request = {
            "id": delegation_id + (":web" if allow_web else ""),
            "query": strip_fillers(query),
            "allowWeb": allow_web,
            "context": str(context)[-300:],
            "at": _now(),
        }
        # The slide being talked about narrows the lookup (TalkQA searches
        # around it first).
        slide = (self.suspended or {}).get("slide") or self.narration_slide
        if isinstance(slide, int) and slide > 0:
            request["slide"] = slide
        timeout = self.args.ask_tool_timeout * (2.0 if allow_web else 1.0)
        result = self._kernel_request("askRequest", self.ask_results, request, timeout)
        for kind, content in self._ask_updates(result, request["query"], delegation_id,
                                               from_web=allow_web):
            self._append(kind, delegation_id, content)

    #: How the model should use a lookup.  The material is context, not a
    #: script: read out verbatim, a prepared answer to a *neighbouring*
    #: question answered "ハイドロゲルって何?" with "ただしそれは今後の検証
    #: 課題で…" (measured 2026-09-19).
    _ANSWER_FROM_MATERIAL = (
        "聞き手の質問に短く答えてください。いま渡した資料が質問に合っていれば資料に沿って答え、"
        "合っていなければ資料には触れず一般的な知識で答えてください。"
        "資料と違うことを事実のように言わないでください。"
    )
    _ANSWER_WITHOUT_MATERIAL = (
        "手元の資料には答えがありません。一般的な知識で答えられる質問なら短く答えてください。"
        "最新の情報や、この発表に固有の事実が必要なら、ウェブで調べてよいか一言だけ尋ねてください。"
        "推測を事実のように言わないでください。"
    )

    def _ask_updates(self, result: dict[str, Any] | None, query: str, delegation_id: str,
                     *, from_web: bool = False) -> list[tuple[str, str]]:
        """What to send GPT-Live for a lookup result: (kind, content) pairs.

        Refusals and failures are spoken as they are (commentary).  Material
        goes in as quiet context with the question it answered, and the
        model is told how to use it -- it composes the answer itself.
        """
        if result is None:
            return [("commentary", "資料を引けませんでした。")]
        status = str(result.get("status", "")).lower()
        answer = str(result.get("answer", "") or "").strip()
        matched = str(result.get("matchedQuestion", "") or "").strip()
        if status == "blocked":
            return [("commentary", "その内容は非公開の資料が必要なため、この場ではお答えできません。")]
        if result.get("needWeb") or status == "needweb":
            with self.delegation_lock:
                self.pending_web = (query, delegation_id, time.monotonic())
            return [("thinking", f"質問「{query}」について、手元の資料には答えがありませんでした。"),
                    ("instructions", self._ANSWER_WITHOUT_MATERIAL)]
        if answer and status in ("ok", ""):
            source = "ウェブで調べた結果" if from_web else "手元の資料"
            about = f" (想定問答「{matched}」の答え)" if matched else ""
            return [("thinking", f"質問「{query}」について{source}{about}: {answer}"),
                    ("instructions", self._ANSWER_FROM_MATERIAL)]
        if result.get("serviceDown") or status == "unavailable":
            return [("thinking", "いまは手元の資料を引けません。"),
                    ("instructions", "資料が引けないことを一言伝え、一般的な知識で答えられる範囲だけ短く答えてください。")]
        if status == "notfound":
            return [("thinking", f"質問「{query}」について、手元の資料には答えがありませんでした。"),
                    ("instructions", "一般的な知識で答えられる範囲だけ短く答え、分からなければそう伝えてください。")]
        return [("commentary", str(result.get("message", "") or "資料を引けませんでした。"))]

    # ------------------------------------------------- interruptions (talk)

    def _speech_flag(self, raw: bytes, now: float) -> bool:
        # Once a person has been heard, a softer syllable must not end the
        # utterance: the bar drops inside a segment (hysteresis).  Measured
        # 2026-09-19: with one bar, "すみません、質問いいですか" broke at the
        # comma and the "質問" half never started a segment.
        strict, soft = self._speech_levels(raw, now)
        return soft if self.segment is not None else strict

    def _speech_levels(self, raw: bytes, now: float) -> tuple[bool, bool]:
        """(strict, soft): a person clearly / plausibly over our echo.

        strict = louder than margin x the echo we expect; soft = louder than
        about the echo itself (margin x 0.55, at least 1).  Echo alone rarely
        passes even the soft bar (it is the 90th percentile of the echo).
        """
        margin = self.args.bargein_margin
        return (self._speech_flag_at(raw, now, margin, learn=True),
                self._speech_flag_at(raw, now, max(1.0, margin * 0.55), learn=False))

    def _speech_flag_at(self, raw: bytes, now: float, margin: float,
                        learn: bool = True) -> bool:
        """Is somebody other than the loudspeaker speaking in this frame?

        While we play, the microphone hears our own voice.  The ratio of the
        microphone's peak to what was just played is tracked while nobody else
        speaks (its 90th percentile is the echo coupling); a frame counts as a
        person only when it is clearly louder than that echo would be.  Between
        sentences it is compared with the room's own floor instead.  Frames
        judged to be a person never feed the estimates, so a long question
        does not teach the detector to ignore questions.
        """
        mic = self._peak_of(raw)
        # Echo arrives within the output latency (tens of ms, ~100 ms on some
        # Windows devices); a wider window only raises the bar.
        far = max((p for t, p in self.far_peaks if now - t <= 0.3), default=0.0)
        floor = self.args.bargein_floor
        if far >= 0.02:
            ratio = mic / far
            if len(self.echo_ratios) < self._frames_per_second:
                # Calibrating on the first second of our own voice.
                if learn:
                    self.echo_ratios.append(ratio)
                return False
            ordered = sorted(self.echo_ratios)
            coupling = max(0.02, ordered[int(0.9 * (len(ordered) - 1))])
            speech = mic >= max(floor, margin * coupling * far)
            if learn and not speech:
                self.echo_ratios.append(ratio)
                self._set_state(echoCoupling=round(coupling, 3))
            return speech
        if len(self.floor_peaks) < self._frames_per_second // 2:
            if learn:
                self.floor_peaks.append(mic)
            return mic >= max(floor, 0.1)
        ordered = sorted(self.floor_peaks)
        room = ordered[len(ordered) // 2]
        speech = mic >= max(floor, 2.0 * margin * room)
        if learn and not speech:
            self.floor_peaks.append(mic)
        return speech

    def _gate(self) -> str:
        """The interruption gate actually in force ("none"|"detect"|"words")."""
        mode = self.interrupt_mode
        if mode == "words" and self.keyword_status != "ready":
            return "detect"
        return mode

    def _observe_mic(self, raw: bytes) -> None:
        """Local listening during a talk; opens a Q&A when a person asks."""
        mode = self._gate()
        if mode == "none" or self.qa_open or self.muted.is_set():
            self.segment = None
            self.speech_flags.clear()
            return
        now = time.monotonic()
        if mode == "words":
            # The recogniser hears the whole stream; a keyword counts only if
            # a person was speaking while it was said (_keyword_judge).
            # Cutting the stream into segments first lost half-utterances and
            # made fragments read as 質問 (measured 2026-09-19).
            strict, soft = self._speech_levels(raw, now)
            self._keyword_put(("frame", (raw, strict, soft)))
            return
        speech = self._speech_flag(raw, now)
        self.speech_flags.append(speech)
        # detect: a person speaking for bargein_ms opens the Q&A; the words
        # already spoken (since the segment began) are replayed to the model.
        if self.segment is None:
            if sum(list(self.speech_flags)[-5:]) < 3:
                return
            lead = max(1, int(400 / max(1, self.args.chunk_ms)))
            self.segment = list(self.mic_ring)[-lead:] + [raw]
            self.segment_started = now
            self.segment_last_speech = now
            return
        self.segment.append(raw)
        if speech:
            self.segment_last_speech = now
        window = self.speech_flags.maxlen or 1
        if len(self.speech_flags) >= window and sum(self.speech_flags) >= 0.8 * window:
            segment = self.segment
            self.segment = None
            self._trigger_qa("detect", "", segment[-self._frames_per_second:])
            return
        if (now - self.segment_last_speech >= 0.8
                or now - self.segment_started >= 8.0):
            self.segment = None

    # -- keyword spotting (Vosk) ---------------------------------------------

    def _keyword_put(self, message: tuple[str, Any]) -> None:
        try:
            self.keyword_queue.put_nowait(message)
        except queue.Full:
            pass

    def _ensure_keyword_model(self, path: str) -> None:
        """Load the Vosk model once, off the audio threads."""
        if not path:
            if self.keyword_status in ("off",):
                self.keyword_status = "unavailable: no speech model"
                self._write_state(keywordStatus=self.keyword_status)
            return
        if path == self.keyword_model_path and self.keyword_status in ("ready", "loading"):
            return
        self.keyword_model_path = path
        self.keyword_status = "loading"
        self._write_state(keywordStatus="loading")

        def load() -> None:
            try:
                from vosk import Model, SetLogLevel  # type: ignore

                SetLogLevel(-1)
                model = Model(path)
                vocabulary_file = Path(path) / "graph" / "words.txt"
                unknown: list[str] = []
                if vocabulary_file.is_file():
                    vocabulary = {
                        line.split()[0]
                        for line in vocabulary_file.read_text(encoding="utf-8").splitlines()
                        if line.strip()
                    }
                    unknown = [
                        word for word in self.interrupt_words
                        if any(token not in vocabulary for token in word.split())
                    ]
                self.keyword_model = model
                self.keyword_unknown = unknown
                self.keyword_status = "ready"
            except Exception as exc:
                self.keyword_status = f"unavailable: {type(exc).__name__}: {exc}"
            self._write_state(
                keywordStatus=self.keyword_status,
                keywordUnknown=self.keyword_unknown,
                interruptGate=self._gate(),
            )

        threading.Thread(target=load, daemon=True).start()

    def _keyword_recognizer(self) -> Any:
        from vosk import KaldiRecognizer  # type: ignore

        grammar = [word for word in self.interrupt_words if word not in self.keyword_unknown]
        recognizer = KaldiRecognizer(
            self.keyword_model, RATE, json.dumps(grammar + ["[unk]"], ensure_ascii=False)
        )
        recognizer.SetWords(True)   # word times: whose voice said it?
        return recognizer

    def _keyword_judge(self, words: list[dict[str, Any]], flags: list[bool],
                       strict: list[bool] | None = None) -> str | None:
        """An allowed word, said while a *person* was speaking, or None.

        The narration itself says スライド and sometimes 質問; our own echo is
        not flagged as a person (_speech_levels), so those are rejected here
        by looking at the frames the word occupies: at least 30 % of them
        plausibly a person (soft flags) and a clear person (strict flag)
        within a second of it.  One strict bar alone missed a real 質問
        spoken over the talk (15 % of its frames, measured 2026-09-19).
        """
        frame_seconds = max(1, self.args.chunk_ms) / 1000.0
        strict = flags if strict is None else strict
        near = max(1, int(1.0 / frame_seconds))
        tokens = [w for w in words if isinstance(w, dict) and w.get("word") != "[unk]"]
        for phrase in self.interrupt_words:
            parts = phrase.split()
            for i in range(len(tokens) - len(parts) + 1):
                run = tokens[i:i + len(parts)]
                if [w.get("word") for w in run] != parts:
                    continue
                if min(float(w.get("conf", 1.0)) for w in run) < 0.5:
                    continue
                first = max(0, int(float(run[0].get("start", 0.0)) / frame_seconds) - 5)
                last = min(len(flags), int(float(run[-1].get("end", 0.0)) / frame_seconds) + 5)
                span = flags[first:last]
                if not span or sum(span) < 0.3 * len(span):
                    continue
                if any(strict[max(0, first - near):min(len(strict), last + near)]):
                    return phrase
        return None

    def _keyword_worker(self) -> None:
        """Continuous grammar-restricted decoding of the talk's microphone.

        Only whole results count (a partial result misread "なるほど、そういう
        ことか" as 質問 when measured; the final result did not).  A result is
        forced 0.8 s after a person stops speaking -- Vosk's own endpointer
        rarely fires while the loudspeaker keeps talking -- and every 10 s
        regardless, so word times stay short and the recogniser fresh.
        """
        recognizer: Any = None
        soft: list[bool] = []
        strict: list[bool] = []
        frames_08 = max(1, int(800 / max(1, self.args.chunk_ms)))
        frames_10s = max(1, int(10000 / max(1, self.args.chunk_ms)))
        while not self.stop_event.is_set():
            try:
                kind, payload = self.keyword_queue.get(timeout=0.3)
            except queue.Empty:
                recognizer, soft, strict = None, [], []   # the talk paused
                continue
            if kind == "reset":
                recognizer, soft, strict = None, [], []
                continue
            if kind != "frame":
                continue
            try:
                raw, clear, plausible = payload
                if recognizer is None:
                    recognizer, soft, strict = self._keyword_recognizer(), [], []
                strict.append(bool(clear))
                soft.append(bool(plausible))
                words: list[dict[str, Any]] = []
                if recognizer.AcceptWaveform(raw):
                    words = json.loads(recognizer.Result()).get("result", [])
                # A person's utterance is over when not even the soft bar has
                # been passed for 0.8 s (a comma pause must not split it).
                person_ended = any(strict) and not any(soft[-frames_08:])
                if not words and (person_ended or len(soft) >= frames_10s):
                    words = json.loads(recognizer.FinalResult()).get("result", [])
                    finished = True
                else:
                    finished = bool(words)
                hit = self._keyword_judge(words, soft, strict) if words else None
                if finished:
                    recognizer, soft, strict = None, [], []
                if hit and self.interrupt_mode == "words" and not self.qa_open:
                    self._trigger_qa("words", hit, None)
            except Exception as exc:
                recognizer, soft, strict = None, [], []
                self._write_state(lastError=f"keyword: {type(exc).__name__}: {exc}")

    # -- opening and closing a Q&A -----------------------------------------------

    @staticmethod
    def _resume_text(piece: str, spoken: str) -> str:
        """The script from the sentence the talk was stopped in."""
        sentences = split_sentences(piece)
        if not sentences:
            return piece
        said = len(re.sub(r"[\s、。，．,.！？!?「」]", "", spoken))
        done = 0
        for index, sentence in enumerate(sentences):
            length = len(re.sub(r"[\s、。，．,.！？!?「」]", "", sentence))
            if done + length > said * 1.02:
                return "".join(sentences[index:])
            done += length
        return ""

    def _suspend_narration(self, now: float) -> bool:
        with self.purpose_lock:
            narration = self.pending_narration
            if narration is None or self.suspended is not None:
                return False
            self.narration_gen += 1
            spoken = self.narration_spoken.replace("それでは、説明に戻ります", "")
            rest = self._resume_text(self.narration_current, spoken)
            self.suspended = {
                "id": narration,
                "text": rest + "".join(self.narration_rest),
                "slide": self.narration_slide,
                "heading": self.narration_label,
                "extra": self.narration_extra,
                "since": now,
                "slideMoves": 0,
            }
            self.pending_narration = None
            self.narration_rest = []
        # The room has to be quiet for the question.
        self._drop_playback()
        self.output_active.clear()
        self.output_done.clear()
        self._assistant_text = ""
        self.discard_until_gap = True
        self.discard_last_voiced = now
        self.discard_deadline = now + 2.5
        return True

    def _trigger_qa(self, kind: str, heard: str, preroll: list[bytes] | None) -> None:
        if self.qa_open:
            return
        now = time.monotonic()
        suspended = self._suspend_narration(now)
        self.qa_open = True
        self.qa_opened_at = now
        self.qa_kind = kind
        self.qa_home_slide = self.narration_slide
        self.qa_slide_moves = 0
        self.segment = None
        self.speech_flags.clear()
        self._keyword_put(("reset", None))
        self.interruptions += 1
        self._write_state(
            qaOpen=True,
            interrupted=suspended,
            interruptions=self.interruptions,
            speaking=False,
            lastInterrupt={"kind": kind, "heard": heard, "at": _now(), "suspended": suspended},
        )
        # Short on purpose: an instruction takes effect only once it has been
        # injected, and a long one made "はい、どうぞ" arrive after the
        # listener had already started asking (measured 2026-09-19).
        stop = "説明を止めて" if suspended else ""
        if kind == "words":
            text = (
                f"聞き手が「{heard}」と、質問しようとしています。{stop}聞き手の話を聞いて答えてください。"
                "聞き手が黙っているときだけ「はい、どうぞ」と短く促してください。"
            )
        else:
            text = (
                f"聞き手が話し始めました。{stop}最後まで聞き、質問なら答え、"
                "独り言や相槌なら黙っていてください。"
            )
        self._append("instructions", None, text + "発表の続きはこちらから指示します。")
        # Words already spoken over the talk (detect): let the model hear them.
        for frame in preroll or []:
            try:
                self.input_events.put_nowait({
                    "type": "session.input_audio.append",
                    "audio": base64.b64encode(frame).decode("ascii"),
                })
            except queue.Full:
                break
        self._record("status", ("発表を一時中断: " if suspended else "質疑: ") +
                     (heard or "聞き手の発話"))
        self._mode("interrupted" if suspended else "listening", self.narration_label)

    def _close_qa(self) -> None:
        """Back to the talk once the exchange has gone quiet."""
        try:
            suspended = self.suspended
            deferred = self.deferred_narration
            home = (
                deferred.get("slide") if deferred is not None
                else suspended["slide"] if suspended is not None
                else self.qa_home_slide
            )
            if self.qa_slide_moves and isinstance(home, int) and home > 0:
                # A slide was shown during the Q&A: put the talk's slide back.
                self._kernel_request(
                    "slideRequest", self.slide_results,
                    {"id": f"resume-{self.interruptions}", "target": "number",
                     "number": home, "title": "", "keepNarration": True,
                     "at": _now()},
                    self.args.slide_tool_timeout,
                )
            with self.purpose_lock:
                if suspended is not self.suspended or deferred is not self.deferred_narration:
                    return   # superseded by a narrate / cancel meanwhile
                self.suspended = None
                self.deferred_narration = None
                self.qa_open = False
                self.qa_slide_moves = 0
                pieces = narration_chunks(suspended["text"]) if suspended else []
                if suspended is not None and pieces:
                    self.pending_narration = suspended["id"]
                    self.narration_rest = pieces[1:]
            self._write_state(qaOpen=False, interrupted=False)
            if deferred is not None and suspended is None:
                # The next slide's script, held back while the Q&A ran.
                self._record("status", "発表に戻ります")
                self._narrate(deferred, resume=True)
                return
            if suspended is None:
                self._record("status", "質疑を終えました")
                self._mode(self._ready_mode())
                return
            if not pieces:
                self._write_state(narrationActive=None, narrationDone=suspended["id"])
                self._mode(self._ready_mode())
                return
            self.narration_label = suspended["heading"]
            self.narration_extra = suspended["extra"]
            self._record("status", "発表に戻ります")
            self._send_narration_piece(pieces[0], first=True, resume=True)
        finally:
            self.resuming = False

    def _reset_interrupts(self) -> None:
        """Leave the talk's interruption state (cancel / end of talk).

        The room is heard normally again until the next narrate says how it
        may be interrupted (a paused talk must not leave the model deaf).
        """
        with self.purpose_lock:
            self.suspended = None
            self.deferred_narration = None
        self.qa_open = False
        self.qa_slide_moves = 0
        self.interrupt_mode = "none"
        self.segment = None
        self.speech_flags.clear()
        self._keyword_put(("reset", None))
        self._write_state(qaOpen=False, interrupted=False,
                          interruptMode="none", interruptGate="none")

    # ------------------------------------------------------------ control

    def _apply_command(self, command: dict[str, Any]) -> None:
        name = str(command.get("command", "")).lower()
        if name == "stop":
            self._line("終了します", keep=True)
            self._live_close()
        elif name == "mute":
            value = bool(command.get("value", True))
            if value:
                self.muted.set()
            else:
                self.muted.clear()
            self._write_state(muted=value)
            self._mode(self._ready_mode())
        elif name == "instructions":
            text = str(command.get("text", "")).strip()
            if text:
                self.instructions = text
                self._append("instructions", None, "以後は次の方針で会話してください。\n" + text)
        elif name == "verbosity":
            level = normalise_verbosity(command.get("value", "normal"))
            self.verbosity = level
            self._write_state(verbosity=level)
            self._append(
                "instructions", None,
                "以後の返答の長さ: " + VERBOSITY_LEVELS[level]["text"],
            )
            self._record("status", "応答の詳しさ: " + level)
        elif name == "say":
            text = str(command.get("text", "")).strip()
            if text:
                self._append(
                    "instructions", None,
                    "利用者が文字で次のように話しかけました。声で短く答えてください。\n「" + text + "」",
                )
                self._record("user", text)
                self._remember("user", text)
        else:
            super()._apply_command(command)

    def _live_close(self) -> None:
        """session.close, then wait (briefly) for session.closed."""
        if self.ws_ready.is_set():
            self._send({"type": "session.close", "event_id": self._next_event_id("close")})
            self.session_closed.wait(4.0)
        self.stop_event.set()
        with self.ws_lock:
            ws = self.ws
        if ws is not None:
            try:
                ws.close()
            except Exception:
                pass

    def _narration_direction(self, *, first: bool = True, resume: bool = False) -> str:
        """The short spoken-now instruction; the script itself is already in
        the model's context (_deliver_piece)."""
        head = (
            "質疑はここまでです。「それでは、説明に戻ります」と言ってから、" if resume
            else "" if first else "続けて、"
        )
        direction = (
            head + "いま渡した原稿を、書かれたとおりに最後まで声に出して読んでください。"
            "前置き・言い換え・感想は付けず、読み終えたら黙って待ってください。"
        )
        if self.narration_extra:
            direction += "話し方 (声に出さない): " + self.narration_extra
        return direction

    def _send_narration_piece(self, piece: str, *, first: bool, resume: bool = False) -> None:
        """Deliver one piece of script in two steps (on a thread).

        Measured 2026-09-19: sent as one instruction with the script inside,
        GPT-Live starts reading while the text is still being injected and
        stalls where the injection has not caught up ("配信" … pause … "され
        ているのは", "それでは…それでは、説明に戻ります").  So the script goes
        in first as quiet context, and only once it has been taken in does a
        short instruction ask for it to be read.
        """
        with self.purpose_lock:
            self.narration_gen += 1
            generation = self.narration_gen
            self.narration_current = piece
            # The start timeout counts from the instruction, not from here
            # (the script is still being taken in): _deliver_piece resets it.
            self.narration_sent_at = time.monotonic() + self.args.live_ack_timeout_ms / 1000.0
            self.narration_resent = False
            self.narration_started_speaking = False
            self.narration_spoken = ""
        self._mode("narrating", self.narration_label)
        threading.Thread(
            target=self._deliver_piece,
            args=(generation, piece, first, resume),
            daemon=True,
        ).start()

    def _deliver_piece(self, generation: int, piece: str, first: bool, resume: bool) -> None:
        label = "次に読み上げる原稿" if first or resume else "次に読み上げる原稿の続き"
        context = self._append(
            "thinking", None, f"{label}です。指示があるまで声に出さないでください。\n{piece}"
        )
        self._wait_ack(context, self.args.live_ack_timeout_ms / 1000.0)
        with self.purpose_lock:
            if generation != self.narration_gen or self.pending_narration is None:
                return   # cancelled, suspended or superseded meanwhile
            self.narration_sent_at = time.monotonic()
        self._append("instructions", None,
                     self._narration_direction(first=first, resume=resume))

    def _narrate(self, command: dict[str, Any], resume: bool = False) -> None:
        identifier = str(command.get("id", "")).strip()
        if self.qa_open and identifier:
            # Someone asked just as the notebook moved on: answer first, read
            # this after the Q&A.  narrationActive keeps the deck waiting.
            with self.purpose_lock:
                self.deferred_narration = dict(command)
            self._write_state(narrationActive=identifier, narrationDone=None)
            self._record("status", (str(command.get("heading", "")) + " 質疑のあとで読みます").strip())
            return
        self.suppress_until = 0.0
        if self.output_active.is_set() or self.state.get("speaking"):
            # The script request itself redirects the model.  Discarding the
            # "tail" here would clip the opening of the script when the model
            # switches without a pause.
            self._cancel_speech(tell_model=False)
            self.suppress_until = 0.0
            self.discard_until_gap = False
        text = str(command.get("text", "")).strip()
        identifier = str(command.get("id", "")).strip()
        if not text or not identifier:
            return
        if not self.ws_ready.is_set():
            self._write_state(
                narrationActive=None,
                narrationDone=None,
                lastError="narrate: the Live session is not ready",
            )
            self._line("接続待ちのため読み上げできません", kind="error", keep=True)
            return
        pieces = narration_chunks(text) or [text]
        extra = " ".join(str(command.get("instructions", "")).split())
        self.narration_extra = extra[:80]
        self.narration_label = str(command.get("heading", "")).strip()
        self._configure_interrupts(command)
        with self.purpose_lock:
            self.suspended = None
            self.pending_narration = identifier
            self.narration_rest = pieces[1:]
        self.qa_open = False
        self._write_state(narrationActive=identifier, narrationDone=None,
                          qaOpen=False, interrupted=False)
        self._record("status", (self.narration_label + " 説明開始").strip())
        self._remember("assistant", text)
        self._send_narration_piece(pieces[0], first=True, resume=resume)

    def _configure_interrupts(self, command: dict[str, Any]) -> None:
        """How this narration may be interrupted (per narrate command)."""
        mode = str(command.get("interrupt", "none") or "none").strip().lower()
        if mode not in ("none", "detect", "words"):
            mode = "none"
        words = command.get("interruptWords")
        if isinstance(words, list):
            self.interrupt_words = [
                " ".join(str(w).split()) for w in words if str(w).strip()
            ]
        slide = command.get("slide")
        self.narration_slide = slide if isinstance(slide, int) and slide > 0 else None
        if mode == "words":
            if not self.interrupt_words:
                mode = "detect"
            else:
                self._ensure_keyword_model(str(command.get("speechModel", "") or ""))
        self.interrupt_mode = mode
        self._write_state(interruptMode=mode, interruptGate=self._gate(),
                          interruptWords=self.interrupt_words)

    def _cancel_speech(self, tell_model: bool = True) -> None:
        now = time.monotonic()
        was_speaking = (
            self.output_active.is_set()
            or bool(self.state.get("speaking"))
            or now - self.last_voiced_output_at < 1.5
        )
        with self.purpose_lock:
            self.output_purpose = "normal"
            self.pending_narration = None
            self.narration_rest = []
            self.narration_gen += 1
        self._reset_interrupts()
        self._drop_playback()
        self.output_active.clear()
        self.output_done.clear()
        self._assistant_text = ""
        if was_speaking:
            self.discard_until_gap = True
            self.discard_last_voiced = now
            self.discard_deadline = now + 6.0
            if tell_model:
                self._append(
                    "instructions", None,
                    "いま話している内容はそこでやめて、何も言わずに黙って待ってください。",
                )
        self.narration_label = ""
        self._write_state(narrationActive=None, speaking=False)
        self.suppress_until = max(self.suppress_until, now + 1.5)
        self._mode(self._ready_mode())

    def _end_talk(self, command: dict[str, Any]) -> None:
        quiet = float(command.get("quietSeconds", 4.0))
        self._cancel_speech(tell_model=False)
        # The talk is over: the room is heard normally again.
        self.interrupt_mode = "none"
        self._write_state(interruptMode="none", interruptGate="none")
        now = time.monotonic()
        self.suppress_until = now + max(0.0, quiet)
        self.input_blocked_until = max(
            self.input_blocked_until, now + min(2.0, max(0.0, quiet))
        )
        self._append(
            "instructions", None,
            "発表はここで終了しました。いまは何も言わずに待ってください。"
            "以後は自分から話し始めず、話しかけられたときだけ、聞かれたことに短く答えてください。",
        )
        self._record("status", "発表を終了しました")
        self._mode("ended")

    # ------------------------------------------------------- housekeeping

    def _live_housekeeping(self) -> None:
        """Mode, utterance boundaries, stalled narration, web permission."""
        while not self.stop_event.is_set():
            time.sleep(0.1)
            try:
                self._housekeeping_tick()
            except Exception as exc:
                self._write_state(lastError=f"housekeeping: {type(exc).__name__}: {exc}")

    def _housekeeping_tick(self) -> None:
        now = time.monotonic()
        with self.transcript_lock:
            if self._utterance and now - self.last_user_delta_at > 1.5:
                self._flush_utterance_locked()
        # A script request the model never started on: ask once more, then
        # give the deck its turn back instead of holding the talk forever.
        with self.purpose_lock:
            narration = self.pending_narration
            started = self.narration_started_speaking
            waited = now - self.narration_sent_at
            resend = narration is not None and not started and not self.narration_resent and waited > 10.0
            if resend:
                self.narration_resent = True
            piece = self.narration_current
        if narration is not None and not started and not self.output_active.is_set():
            if resend and piece:
                self._append("instructions", None, self._narration_direction(first=True))
                self._record("status", "読み上げを再依頼しました")
            elif waited > 25.0:
                with self.purpose_lock:
                    self.pending_narration = None
                    self.narration_rest = []
                self._write_state(
                    narrationActive=None,
                    narrationDone=narration,
                    lastError="narrate: GPT-Live did not start speaking the script",
                )
                self._line("読み上げが始まらなかったため次へ進みます", kind="error", keep=True)
        # The room said yes to the web but the model did not delegate it.
        pending = self.pending_web
        if (
            pending is not None
            and not self.active_delegations
            and self.last_user_delta_at > pending[2]
            and now - self.last_user_delta_at >= 2.0
        ):
            with self.transcript_lock:
                said = "".join(
                    f[2] for f in self.user_fragments if f[1] > pending[2]
                ).strip()
            if is_affirmative(said):
                claimed = self._claim_pending_web()
                if claimed is not None:
                    threading.Thread(
                        target=self._run_ask,
                        args=(claimed[1], claimed[0]),
                        kwargs={"allow_web": True},
                        daemon=True,
                    ).start()
            elif is_negative(said):
                self._claim_pending_web()
        # A Q&A opened during the talk closes once the exchange has gone
        # quiet; the talk then resumes from the sentence it was stopped in.
        if (
            self.qa_open
            and not self.resuming
            and not self.output_active.is_set()
            and not self.active_delegations
        ):
            opened = self.qa_opened_at
            spoke = self.last_user_delta_at > opened
            quiet_user = now - max(self.last_user_delta_at, opened)
            quiet_out = now - max(self.last_voiced_output_at, opened)
            need = self.args.resume_quiet_ms / 1000.0
            if self.pending_web is not None:
                need *= 2.0   # waiting for a yes / no to the web
            if not spoke:
                # Nobody has said anything since it opened: after "はい、どうぞ"
                # people take a moment to put the question; after a detection
                # that heard nothing it was noise, so do not keep the room waiting.
                need = max(need, 8.0 if self.qa_kind == "words" else 3.5)
            if now - opened >= 2.5 and quiet_user >= need and quiet_out >= 1.5:
                self.resuming = True
                threading.Thread(target=self._close_qa, daemon=True).start()
        # What the status bar says between utterances.
        if self.output_active.is_set() or self.pending_narration is not None:
            return
        mode = self.state.get("mode")
        if self.active_delegations:
            if mode != "thinking":
                self._mode("thinking")
        elif now - self.last_user_delta_at < 1.2 and not self.muted.is_set():
            if mode != "listening":
                self._mode("listening")
        elif self.suspended is not None:
            if mode != "interrupted" and now >= self.suppress_until:
                self._mode("interrupted", self.suspended.get("heading", ""))
        elif mode in ("listening", "thinking", "answering") and now >= self.suppress_until:
            self._mode(self._ready_mode())


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
    parser.add_argument(
        "--api",
        choices=("auto", "realtime", "live"),
        default="auto",
        help="auto = live for gpt-live-* models, realtime otherwise",
    )
    parser.add_argument(
        "--live-idle-ms",
        type=int,
        default=900,
        help="GPT-Live: an utterance is over after this long without voiced audio",
    )
    parser.add_argument(
        "--live-narration-idle-ms",
        type=int,
        default=1400,
        help="GPT-Live: the same, while a script is being read (sentence pauses)",
    )
    parser.add_argument(
        "--live-settle-ms",
        type=int,
        default=700,
        help="GPT-Live: pause in the transcript that marks a delegated request as complete",
    )
    parser.add_argument(
        "--live-narration-stall-ms",
        type=int,
        default=6000,
        help="GPT-Live: a pause this long ends a script even if less of it was heard",
    )
    parser.add_argument(
        "--live-ack-timeout-ms",
        type=int,
        default=8000,
        help="GPT-Live: wait this long for a script to be taken in before asking to read it",
    )
    parser.add_argument(
        "--bargein-margin",
        type=float,
        default=2.0,
        help="GPT-Live talk interruptions: how much louder than our own echo a voice must be",
    )
    parser.add_argument(
        "--bargein-ms",
        type=int,
        default=350,
        help="GPT-Live talk interruptions (detect): sustained speech needed to open a Q&A",
    )
    parser.add_argument(
        "--bargein-floor",
        type=float,
        default=0.03,
        help="GPT-Live talk interruptions: minimum microphone peak (0..1) counted as a voice",
    )
    parser.add_argument(
        "--resume-quiet-ms",
        type=int,
        default=4000,
        help="GPT-Live: quiet after a Q&A before the talk resumes",
    )
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
    bridge_class = LiveBridge if resolve_api(args.model, args.api) == "live" else RealtimeBridge
    return bridge_class(args).run()


if __name__ == "__main__":
    raise SystemExit(main())
