"""Connection test for the voice worker's audio devices (like Zoom's mic test).

Run by SourceVaultRealtimeAudioCheck[] with the realtime venv python.  Devices
are resolved exactly as the worker resolves them (same function, same rate,
same block size), so what passes here is what the worker will open.

Two directions:

  output  The AI's voice goes out here.  A test sound is written the way the
          worker writes speech.  Writes that stop returning mean the device has
          stalled (measured 2026-10-19: the laptop speaker after waking from
          Modern Standby -- the first write never came back, so the worker
          played nothing).  When the output is a virtual cable ("CABLE Input",
          "CABLE-A Input", ...), its other end ("CABLE Output", ...) is recorded
          at the same time to prove the sound arrives there -- the end Zoom
          takes as its microphone.
  input   The AI listens here.  Recorded for a few seconds with a level per
          100 ms (the notebook draws a meter from the progress file).  Exact
          digital zeros mean nothing is playing into the device at all.

The result is one JSON object (--result-file, and stdout).  Nothing here needs
the network; nothing is kept except the optional capture (--capture-file).
"""

from __future__ import annotations

import argparse
import array
import json
import math
import os
import re
import sys
import threading
import time
import wave
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import sounddevice as sd  # noqa: E402

import SourceVault_realtime_worker as worker  # noqa: E402

RATE = worker.RATE
BLOCK = max(1, int(RATE * 20 / 1000))      # the worker's 20 ms chunk
WINDOW_BLOCKS = 5                           # 100 ms per level window
TONE_HZ = 880.0
TONE_LEVELS = {"beep": 0.18, "quiet": 0.001}   # about -15 dBFS / -60 dBFS
#: Below this the input counts as digital silence (VB-Cable idles at 0..1 LSB).
ZERO_PEAK = 4 / 32768.0
SIGNAL_RMS_DB = -50.0


def resolve(spec: str, kind: str) -> int | None:
    return worker.RealtimeBridge._resolve_device(spec, kind)


def device_name(index: int | None, kind: str) -> str:
    return worker.RealtimeBridge._device_name(index, kind)


def loopback_spec(output_name: str) -> str | None:
    """The other end of a virtual cable, from the output device's name.

    VB-Audio: "CABLE Input" / "CABLE In 16ch" -> "CABLE Output",
    "CABLE-A Input" -> "CABLE-A Output".  Anything else (a real speaker) has no
    end that can be recorded."""
    match = re.match(r"\s*(CABLE(?:-[A-Z])?)\s+In(?:put)?\b", output_name, re.IGNORECASE)
    if not match:
        return None
    return match.group(1) + " Output"


def samples_of(raw: bytes) -> array.array:
    values = array.array("h")
    values.frombytes(raw[: len(raw) - (len(raw) % 2)])
    return values


def peak_of(values: array.array) -> float:
    return max((abs(v) for v in values), default=0) / 32768.0


def rms_db(values: array.array) -> float:
    if not values:
        return -120.0
    mean = sum(v * v for v in values) / len(values)
    if mean <= 0:
        return -120.0
    return 20.0 * math.log10(math.sqrt(mean) / 32768.0)


def tone_fraction(values: array.array) -> float:
    """Share of the block's energy at TONE_HZ (Goertzel)."""
    n = len(values)
    if n == 0:
        return 0.0
    total = sum(v * v for v in values)
    if total <= 0:
        return 0.0
    k = 2.0 * math.cos(2.0 * math.pi * TONE_HZ / RATE)
    s1 = s2 = 0.0
    for v in values:
        s0 = v + k * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - k * s1 * s2
    # A pure tone filling the block gives power ~ total * n / 2.
    return max(0.0, min(1.0, 2.0 * power / (n * total)))


def test_sound(level: float) -> list[bytes]:
    """0.2 s quiet, three 0.25 s beeps 0.15 s apart, 0.3 s quiet, in blocks."""
    amp = int(32767 * level)
    pcm = array.array("h")
    pcm.extend([0] * int(RATE * 0.2))
    beep = int(RATE * 0.25)
    fade = int(RATE * 0.01)
    for i in range(3):
        for j in range(beep):
            env = min(1.0, j / fade, (beep - 1 - j) / fade)
            pcm.append(int(amp * env * math.sin(2.0 * math.pi * TONE_HZ * j / RATE)))
        if i < 2:
            pcm.extend([0] * int(RATE * 0.15))
    pcm.extend([0] * int(RATE * 0.3))
    raw = pcm.tobytes()
    size = BLOCK * 2
    raw += bytes((-len(raw)) % size)
    return [raw[i:i + size] for i in range(0, len(raw), size)]


class Progress:
    def __init__(self, path: str | None) -> None:
        self.path = Path(path) if path else None
        self.state: dict[str, Any] = {"phase": "starting", "levels": []}

    def update(self, **fields: Any) -> None:
        self.state.update(fields)
        if self.path is None:
            return
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        try:
            temporary.write_text(json.dumps(self.state, ensure_ascii=False), encoding="utf-8")
            os.replace(temporary, self.path)
        except OSError:
            pass


# ------------------------------------------------------------------ output

def check_output(spec: str, loopback: str, tone: str, progress: Progress) -> dict[str, Any]:
    result: dict[str, Any] = {"requested": spec}
    try:
        index = resolve(spec, "output")
    except Exception as exc:
        result.update(status="NotFound", error=f"{type(exc).__name__}: {exc}")
        return result
    name = device_name(index, "output")
    result.update(device=name, index=index)

    lb_spec = loopback_spec(name) if loopback == "auto" else (None if loopback == "none" else loopback)
    lb_index = None
    if lb_spec:
        try:
            lb_index = resolve(lb_spec, "input")
            result.update(loopback=device_name(lb_index, "input"))
        except Exception as exc:
            result.update(loopback=None, loopbackError=f"{type(exc).__name__}: {exc}")
            lb_spec = None

    level = TONE_LEVELS.get(tone, TONE_LEVELS["beep"])
    blocks = test_sound(level)
    expected = len(blocks) * BLOCK / RATE
    result.update(tone=tone, toneLevel=level, seconds=round(expected, 3))
    progress.update(phase="output", device=name, loopback=result.get("loopback"))

    captured: list[tuple[float, float, float]] = []   # (t, peak, tone fraction)
    capture_stop = threading.Event()
    capture_error: list[str] = []

    def capture() -> None:
        try:
            with sd.RawInputStream(samplerate=RATE, channels=1, dtype="int16",
                                   blocksize=BLOCK, device=lb_index) as stream:
                while not capture_stop.is_set():
                    data, _overflow = stream.read(BLOCK)
                    values = samples_of(bytes(data))
                    captured.append((time.monotonic(), peak_of(values), tone_fraction(values)))
        except Exception as exc:
            capture_error.append(f"{type(exc).__name__}: {exc}")

    written = {"blocks": 0, "toneAt": None, "done": False, "error": None, "opened": None}

    def play() -> None:
        try:
            with sd.RawOutputStream(samplerate=RATE, channels=1, dtype="int16",
                                    blocksize=BLOCK, device=index) as stream:
                written["opened"] = time.monotonic()
                for i, block in enumerate(blocks):
                    stream.write(block)
                    written["blocks"] = i + 1
                    if written["toneAt"] is None and any(samples_of(block)):
                        written["toneAt"] = time.monotonic()
                written["done"] = True
        except Exception as exc:
            written["error"] = f"{type(exc).__name__}: {exc}"

    reader = None
    if lb_spec:
        reader = threading.Thread(target=capture, daemon=True)
        reader.start()
        time.sleep(0.15)          # the recording is running before the sound starts
    started = time.monotonic()
    writer = threading.Thread(target=play, daemon=True)
    writer.start()
    writer.join(expected + 3.0)
    elapsed = time.monotonic() - started
    stalled = writer.is_alive()
    time.sleep(0.3)               # the tail through the cable
    capture_stop.set()
    if reader is not None:
        reader.join(1.0)

    result.update(
        stalled=stalled,
        blocksWritten=written["blocks"],
        blocksTotal=len(blocks),
        elapsed=round(elapsed, 3),
        writeError=written["error"],
    )
    if written["error"]:
        result["status"] = "Error"
    elif stalled:
        result["status"] = "Stalled"
    else:
        # The last write returns once the device has taken it in; a device that
        # accepts everything at once without playing (seen: DirectSound on the
        # stalled speaker, 2 s in 0 s) finishes far faster than real time.
        pace = elapsed / expected if expected > 0 else 1.0
        result["pace"] = round(pace, 3)
        result["status"] = "Played" if pace >= 0.5 else "Unpaced"

    if lb_spec:
        if capture_error:
            result.update(loopbackStatus="Error", loopbackError=capture_error[0])
        else:
            tone_hits = [c for c in captured if c[2] > 0.5 and c[1] > 0.3 * level]
            loudest = max((c[1] for c in captured), default=0.0)
            result.update(
                loopbackBlocks=len(captured),
                loopbackPeak=round(loudest, 4),
                toneBlocks=len(tone_hits),
            )
            if len(tone_hits) >= 5:
                result["loopbackStatus"] = "Arrived"
                if written["toneAt"] is not None:
                    result["latencyMs"] = max(0, round(1000 * (tone_hits[0][0] - written["toneAt"])))
            elif loudest > 0:
                result["loopbackStatus"] = "OtherSound"
            else:
                result["loopbackStatus"] = "Silent"
    return result


# ------------------------------------------------------------------- input

def check_input(spec: str, seconds: float, capture_file: str | None,
                progress: Progress) -> dict[str, Any]:
    result: dict[str, Any] = {"requested": spec, "seconds": seconds}
    try:
        index = resolve(spec, "input")
    except Exception as exc:
        result.update(status="NotFound", error=f"{type(exc).__name__}: {exc}")
        return result
    name = device_name(index, "input")
    result.update(device=name, index=index)
    progress.update(phase="input", device=name, levels=[], seconds=seconds)

    levels: list[list[float]] = []    # [t, peak, rms dB] per 100 ms
    pcm = bytearray()
    peak = 0.0
    any_nonzero = False
    error: list[str] = []
    done = threading.Event()

    def record() -> None:
        nonlocal peak, any_nonzero
        try:
            with sd.RawInputStream(samplerate=RATE, channels=1, dtype="int16",
                                   blocksize=BLOCK, device=index) as stream:
                total = int(seconds * RATE / BLOCK)
                window = array.array("h")
                for i in range(total):
                    data, _overflow = stream.read(BLOCK)
                    raw = bytes(data)
                    pcm.extend(raw)
                    window.extend(samples_of(raw))
                    if (i + 1) % WINDOW_BLOCKS == 0 or i + 1 == total:
                        p = peak_of(window)
                        if p > ZERO_PEAK:
                            any_nonzero = True
                        peak = max(peak, p)
                        levels.append([round((i + 1) * BLOCK / RATE, 2), round(p, 4), round(rms_db(window), 1)])
                        progress.update(levels=levels)
                        window = array.array("h")
        except Exception as exc:
            error.append(f"{type(exc).__name__}: {exc}")
        finally:
            done.set()

    reader = threading.Thread(target=record, daemon=True)
    reader.start()
    done.wait(seconds + 4.0)
    if not done.is_set():
        result.update(status="Stalled", levels=levels)
        return result
    if error:
        result.update(status="Error", error=error[0], levels=levels)
        return result

    loud = sum(1 for _t, _p, db in levels if db > SIGNAL_RMS_DB)
    result.update(
        levels=levels,
        peak=round(peak, 4),
        peakDb=round(20 * math.log10(peak), 1) if peak > 0 else None,
        loudWindows=loud,
        status="Signal" if loud >= 3 else ("Quiet" if any_nonzero else "Zeros"),
    )
    if capture_file:
        try:
            target = Path(capture_file)
            with wave.open(str(target), "wb") as handle:
                handle.setnchannels(1)
                handle.setsampwidth(2)
                handle.setframerate(RATE)
                handle.writeframes(bytes(pcm))
            result["captureFile"] = str(target)
        except OSError as exc:
            result["captureError"] = f"{type(exc).__name__}: {exc}"
    return result


# -------------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output-device", default="")
    parser.add_argument("--input-device", default="")
    parser.add_argument("--loopback", default="auto", help="auto | none | a capture device name")
    parser.add_argument("--tone", default="beep", choices=["beep", "quiet"])
    parser.add_argument("--listen-seconds", type=float, default=8.0)
    parser.add_argument("--skip-output", action="store_true")
    parser.add_argument("--skip-input", action="store_true")
    parser.add_argument("--progress-file")
    parser.add_argument("--result-file")
    parser.add_argument("--capture-file")
    parser.add_argument("--spec-file", help="UTF-8 JSON: outputDevice / inputDevice / loopback "
                        "(device names may be Japanese; the notebook does not put them on the command line)")
    args = parser.parse_args(argv)
    if args.spec_file:
        spec = json.loads(Path(args.spec_file).read_text(encoding="utf-8"))
        args.output_device = str(spec.get("outputDevice", args.output_device) or "")
        args.input_device = str(spec.get("inputDevice", args.input_device) or "")
        args.loopback = str(spec.get("loopback", args.loopback) or "auto")

    progress = Progress(args.progress_file)
    result: dict[str, Any] = {"version": 1, "rate": RATE}
    try:
        if not args.skip_output:
            result["output"] = check_output(args.output_device, args.loopback, args.tone, progress)
        if not args.skip_input:
            result["input"] = check_input(args.input_device, max(1.0, args.listen_seconds),
                                          args.capture_file, progress)
    except Exception as exc:   # never leave the notebook without an answer
        result["error"] = f"{type(exc).__name__}: {exc}"
    payload = json.dumps(result, ensure_ascii=False)
    if args.result_file:
        temporary = Path(args.result_file + ".tmp")
        temporary.write_text(payload, encoding="utf-8")
        os.replace(temporary, args.result_file)
    progress.update(phase="done")
    sys.stdout.write(payload + "\n")
    sys.stdout.flush()
    # A stalled device keeps its writer thread stuck in PortAudio; closing the
    # stream from here would hang too.  The answer is out: leave at once.
    os._exit(0)


if __name__ == "__main__":
    main()
