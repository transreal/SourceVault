"""Render slide narrations to WAV files with the OpenAI Realtime API -- no playback.

SourceVaultRealtimeRender (SourceVault_realtime.wl) starts this once per batch:

    python -X utf8 SourceVault_realtime_render.py --jobs jobs.json --result result.json --api-key-stdin

The voice bridge (SourceVault_realtime_worker.py) reads a script aloud through the
speaker, so a talk takes as long to narrate as it takes to listen to.  Making a
video does not need the speaker: the audio deltas arrive faster than real time and
are written straight to a file here.  Each script gets its own short WebSocket
session (a later slide must not carry the earlier slides' audio in its
conversation -- that is billed as input on every turn), and several sessions run
side by side.

jobs.json (UTF-8):
    {"model": "gpt-realtime-2.1", "voice": "marin",
     "instructions": "<session instructions>",
     "narrationInstructions": "<the deck's delivery notes, never spoken>",
     "parallel": 3,
     "jobs": [{"id": "s3", "heading": "スライド 3", "text": "...", "out": "C:/.../x.wav"}]}

result.json is rewritten (atomically) after every job:
    {"status": "running" | "done", "total": n, "done": k, "failed": f,
     "jobs": {"s3": {"status": "done", "file": "...", "seconds": 12.3,
                     "attempts": 1, "transcript": "..."} | {"status": "failed", "error": "..."}}}

The narration wording (what the model is told so that it reads the script and says
nothing else) is the worker's own, imported from it, so the two never drift apart.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import queue
import re
import sys
import threading
import time
import wave
from pathlib import Path
from typing import Any
from urllib.parse import quote

import websocket

RATE = 24_000  # OpenAI Realtime PCM16 mono

try:  # the worker's wording, when it can be imported (it needs sounddevice)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from SourceVault_realtime_worker import RealtimeBridge as _Bridge  # noqa: E402

    NARRATION_INSTRUCTIONS: str = _Bridge._NARRATION_INSTRUCTIONS
    _opening_sentence = _Bridge._opening_sentence
except Exception:  # pragma: no cover - fallback copy of the worker 1.12 wording
    NARRATION_INSTRUCTIONS = (
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

    def _opening_sentence(text: str) -> str:
        head = text.strip()
        for stop in ("。", "！", "？", ".", "\n"):
            index = head.find(stop)
            if 0 < index <= 60:
                return head[: index + (1 if stop != "\n" else 0)].strip()
        return head[:40].strip()


#: How many times a script is tried (network trouble, a refusal, a reply that is
#: not the script).
ATTEMPTS = 3
#: A take shorter than this share of the expected reading time, whose transcript
#: also covers less than half the script, is not the script ("はい。").
SHORT_TAKE = 0.35
JA_CHARS_PER_SECOND = 7.0
LATIN_CHARS_PER_SECOND = 14.0


def _plain(text: str) -> str:
    return re.sub(r"[\s、。，．,.！？!?「」『』（）()・…ー\-]", "", str(text))


def expected_seconds(text: str) -> float:
    plain = _plain(text)
    if not plain:
        return 0.0
    latin = sum(1 for ch in plain if ord(ch) < 0x80) > len(plain) / 2
    return len(plain) / (LATIN_CHARS_PER_SECOND if latin else JA_CHARS_PER_SECOND)


def narration_prompt(job: dict[str, Any]) -> str:
    """The user message, worded exactly as the worker words it."""
    text = str(job.get("text", "")).strip()
    heading = str(job.get("heading", "")).strip()
    if heading:
        return heading + "の原稿です。\n---\n" + text + "\n---"
    return "原稿です。\n---\n" + text + "\n---"


def narration_instructions(text: str, extra: str) -> str:
    instructions = NARRATION_INSTRUCTIONS
    opening = _opening_sentence(text)
    if opening:
        instructions += "\n最初に発する文は「" + opening + "」です。その前に何も言わないでください。"
    if extra:
        instructions += "\n話し方についての指示 (声に出さない): " + extra
    return instructions


def write_wav(path: str, pcm: bytes, rate: int = RATE) -> None:
    """Write 16-bit mono PCM, atomically (a half-written file must never look done)."""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + ".part")
    with wave.open(str(partial), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(pcm)
    os.replace(partial, target)


class TakeError(Exception):
    """One attempt failed; ``retry`` says whether another attempt can help."""

    def __init__(self, message: str, retry: bool = True) -> None:
        super().__init__(message)
        self.retry = retry


#: Error codes for which a second attempt is pointless.
FATAL_CODES = {
    "invalid_api_key",
    "insufficient_quota",
    "model_not_found",
    "invalid_request_error",
    "unknown_parameter",
    "invalid_value",
}


class Renderer:
    def __init__(self, config: dict[str, Any], api_key: str, result_path: str,
                 connect: Any = None) -> None:
        self.config = config
        self.api_key = api_key
        self.result_path = result_path
        #: Seam for tests: a callable (url, headers, timeout) -> websocket-like.
        self.connect = connect or self._connect
        self.jobs: list[dict[str, Any]] = [
            j for j in config.get("jobs", []) if isinstance(j, dict) and j.get("id")
        ]
        self.lock = threading.Lock()
        self.results: dict[str, dict[str, Any]] = {
            str(j["id"]): {"status": "pending"} for j in self.jobs
        }
        self.fatal: str | None = None
        self.started = time.time()

    # ------------------------------------------------------------ plumbing

    @staticmethod
    def _connect(url: str, headers: list[str], timeout: float) -> Any:
        return websocket.create_connection(url, header=headers, timeout=timeout)

    def _url(self) -> str:
        return "wss://api.openai.com/v1/realtime?model=" + quote(
            str(self.config.get("model", "gpt-realtime-2.1")), safe=""
        )

    def _write_result(self, final: bool = False) -> None:
        with self.lock:
            done = sum(1 for r in self.results.values() if r.get("status") == "done")
            failed = sum(1 for r in self.results.values() if r.get("status") == "failed")
            payload = {
                "status": "done" if final else "running",
                "total": len(self.results),
                "done": done,
                "failed": failed,
                "fatal": self.fatal,
                "elapsed": round(time.time() - self.started, 2),
                "jobs": self.results,
            }
            target = Path(self.result_path)
            partial = target.with_name(target.name + ".part")
            partial.write_bytes(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
            os.replace(partial, target)

    # ------------------------------------------------------------ one take

    def _session_update(self) -> dict[str, Any]:
        return {
            "type": "session.update",
            "session": {
                "type": "realtime",
                "model": self.config.get("model", "gpt-realtime-2.1"),
                "output_modalities": ["audio"],
                "audio": {
                    "output": {
                        "format": {"type": "audio/pcm", "rate": RATE},
                        "voice": self.config.get("voice", "marin"),
                    }
                },
                "instructions": str(self.config.get("instructions", "")),
                "max_output_tokens": "inf",
            },
        }

    def take(self, job: dict[str, Any]) -> tuple[bytes, str]:
        """One narration: returns (pcm, transcript) or raises TakeError."""
        text = str(job.get("text", "")).strip()
        budget = max(90.0, len(text) / 2.0 + 60.0)
        deadline = time.monotonic() + budget
        try:
            ws = self.connect(self._url(), [f"Authorization: Bearer {self.api_key}"], 30.0)
        except Exception as exc:
            # A refused handshake (bad key, no access to the model) will not get
            # better on the next attempt; a dropped network might.
            status = getattr(exc, "status_code", None)
            raise TakeError(f"connect: {type(exc).__name__}: {status or exc}",
                            retry=status not in (401, 403, 404)) from exc
        pcm = bytearray()
        transcript: list[str] = []
        try:
            ws.send(json.dumps(self._session_update(), ensure_ascii=False))
            # The voice is fixed by session.update; wait for it before speaking.
            self._await(ws, deadline, until="session.updated")
            ws.send(json.dumps({
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": narration_prompt(job)}],
                },
            }, ensure_ascii=False))
            ws.send(json.dumps({
                "type": "response.create",
                "response": {
                    "output_modalities": ["audio"],
                    "instructions": narration_instructions(
                        text, str(self.config.get("narrationInstructions", "")).strip()),
                    "tool_choice": "none",
                    "max_output_tokens": "inf",
                },
            }, ensure_ascii=False))
            while True:
                event = self._next(ws, deadline)
                kind = str(event.get("type", ""))
                if kind == "response.output_audio.delta":
                    delta = event.get("delta")
                    if isinstance(delta, str) and delta:
                        pcm += base64.b64decode(delta)
                elif kind == "response.output_audio_transcript.delta":
                    transcript.append(str(event.get("delta", "")))
                elif kind == "response.done":
                    response = event.get("response", {}) or {}
                    status = str(response.get("status", "completed"))
                    if status != "completed":
                        details = response.get("status_details") or {}
                        raise TakeError(f"response {status}: {json.dumps(details, ensure_ascii=False)[:300]}")
                    break
        finally:
            try:
                ws.close()
            except Exception:
                pass
        return bytes(pcm), "".join(transcript)

    def _next(self, ws: Any, deadline: float) -> dict[str, Any]:
        while True:
            if time.monotonic() > deadline:
                raise TakeError("timed out waiting for the narration")
            try:
                message = ws.recv()
            except websocket.WebSocketTimeoutException:
                continue
            except Exception as exc:
                raise TakeError(f"receive: {type(exc).__name__}: {exc}") from exc
            if not message:
                raise TakeError("connection closed")
            try:
                event = json.loads(message)
            except (TypeError, json.JSONDecodeError):
                continue
            if not isinstance(event, dict):
                continue
            if event.get("type") == "error":
                error = event.get("error") or {}
                code = str(error.get("code") or error.get("type") or "error")
                message_text = str(error.get("message", ""))[:300]
                raise TakeError(f"{code}: {message_text}", retry=code not in FATAL_CODES)
            return event

    def _await(self, ws: Any, deadline: float, until: str) -> None:
        while True:
            if self._next(ws, deadline).get("type") == until:
                return

    # ------------------------------------------------------------ one job

    def run_job(self, job: dict[str, Any]) -> None:
        identifier = str(job["id"])
        text = str(job.get("text", "")).strip()
        out = str(job.get("out", "")).strip()
        if not text or not out:
            self._set(identifier, {"status": "failed", "error": "empty text or output path"})
            return
        expected = expected_seconds(text)
        last_error = ""
        for attempt in range(1, ATTEMPTS + 1):
            if self.fatal:
                last_error = self.fatal
                break
            self._set(identifier, {"status": "running", "attempts": attempt})
            try:
                pcm, transcript = self.take(job)
            except TakeError as exc:
                last_error = str(exc)
                if not exc.retry:
                    with self.lock:
                        self.fatal = self.fatal or last_error
                    break
                time.sleep(min(8.0, 1.5 * attempt))
                continue
            seconds = len(pcm) / (2.0 * RATE)
            covered = len(_plain(transcript)) / max(1, len(_plain(text)))
            if seconds < SHORT_TAKE * expected and covered < 0.5:
                last_error = f"short take ({seconds:.1f} s for ~{expected:.0f} s): {transcript[:60]}"
                continue
            try:
                write_wav(out, pcm)
            except OSError as exc:
                last_error = f"write: {exc}"
                break
            self._set(identifier, {
                "status": "done", "file": out, "seconds": round(seconds, 3),
                "attempts": attempt, "transcript": transcript[:2000],
            })
            return
        self._set(identifier, {"status": "failed", "error": last_error or "failed"})

    def _set(self, identifier: str, value: dict[str, Any]) -> None:
        with self.lock:
            self.results[identifier] = value
        self._write_result()

    # ------------------------------------------------------------ batch

    def run(self) -> int:
        work: queue.Queue[dict[str, Any]] = queue.Queue()
        for job in self.jobs:
            work.put(job)
        try:
            parallel = int(self.config.get("parallel", 3))
        except (TypeError, ValueError):
            parallel = 3
        parallel = max(1, min(parallel, 8, max(1, len(self.jobs))))

        def worker() -> None:
            while True:
                try:
                    job = work.get_nowait()
                except queue.Empty:
                    return
                self.run_job(job)

        self._write_result()
        threads = [threading.Thread(target=worker, daemon=True) for _ in range(parallel)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self._write_result(final=True)
        failed = sum(1 for r in self.results.values() if r.get("status") != "done")
        return 0 if failed == 0 else 3


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--jobs", required=True, help="UTF-8 JSON job file")
    parser.add_argument("--result", required=True, help="result JSON (rewritten as jobs finish)")
    parser.add_argument("--api-key-stdin", action="store_true")
    args = parser.parse_args(argv)
    api_key = ""
    if args.api_key_stdin:
        try:
            api_key = (sys.stdin.readline() or "").strip()
        except Exception:
            api_key = ""
    api_key = api_key or os.environ.get("OPENAI_API_KEY", "")
    try:
        config = json.loads(Path(args.jobs).read_bytes().decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"jobs: {exc}\n")
        return 2
    renderer = Renderer(config, api_key, args.result)
    if not api_key:
        renderer.fatal = "OPENAI_API_KEY is not set"
        for identifier in renderer.results:
            renderer.results[identifier] = {"status": "failed", "error": renderer.fatal}
        renderer._write_result(final=True)
        return 2
    return renderer.run()


if __name__ == "__main__":
    raise SystemExit(main())
