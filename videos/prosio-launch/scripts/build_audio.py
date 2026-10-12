#!/usr/bin/env python3
"""Compose Prosio's original 60 s launch soundtrack, without sampled music.

Requires numpy and ffmpeg. Run with the motion-design Python environment.
All oscillators, rhythms, voicings and UI sounds below are generated locally.
Two-pass EBU R128 normalization targets -17 LUFS and -1.5 dBTP.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

SR = 48_000
DURATION = 60.0
BPM = 120
BEAT = 60.0 / BPM
N = int(SR * DURATION)
RNG = np.random.default_rng(8102026)
MUSIC = np.zeros((N, 2), dtype=np.float64)
SFX = np.zeros_like(MUSIC)
CUES: list[dict] = []


def hz(note: float) -> float:
    return 440.0 * 2 ** ((note - 69.0) / 12.0)


def timeline(seconds: float) -> np.ndarray:
    return np.arange(round(seconds * SR), dtype=np.float64) / SR


def edge_envelope(t: np.ndarray, attack: float, release: float) -> np.ndarray:
    """Raised cosine at both ends prevents audible boundary clicks."""
    rise = np.sin(np.minimum(t / attack, 1.0) * np.pi / 2.0) ** 2
    fall = np.sin(np.clip((len(t) / SR - t) / release, 0, 1) * np.pi / 2.0) ** 2
    return rise * fall


def add(target: np.ndarray, at: float, mono: np.ndarray, gain=1.0, pan=0.0):
    start = round(at * SR)
    skip = max(0, -start)
    start = max(start, 0)
    length = min(len(mono) - skip, N - start)
    if length <= 0:
        return
    # Constant-power panning, kept near the centre for laptop playback.
    angle = (np.clip(pan, -1, 1) + 1.0) * np.pi / 4.0
    source = mono[skip : skip + length] * gain
    target[start : start + length, 0] += source * np.cos(angle)
    target[start : start + length, 1] += source * np.sin(angle)


def keys(note: float, duration=2.1, soft=1.0) -> np.ndarray:
    t = timeline(duration)
    f = hz(note)
    body = np.sin(2 * np.pi * f * t + 0.42 * soft * np.exp(-t / 0.13) * np.sin(2 * np.pi * 2 * f * t))
    body += 0.22 * np.sin(2 * np.pi * 2 * f * t) * np.exp(-t / 0.35)
    body += 0.075 * soft * np.sin(2 * np.pi * 3 * f * t) * np.exp(-t / 0.10)
    return body * np.exp(-t / 0.78) * edge_envelope(t, 0.009, 0.18)


def wood(note: float, duration=0.85) -> np.ndarray:
    t = timeline(duration)
    f = hz(note)
    body = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.27)
    body += 0.19 * np.sin(2 * np.pi * f * 2.006 * t) * np.exp(-t / 0.095)
    body += 0.05 * np.sin(2 * np.pi * f * 3.98 * t) * np.exp(-t / 0.035)
    return body * edge_envelope(t, 0.005, 0.08)


def bass(note: float, duration=0.5) -> np.ndarray:
    t = timeline(duration)
    f = hz(note)
    body = np.sin(2 * np.pi * f * t)
    body += 0.19 * np.sin(2 * np.pi * 2 * f * t)
    body += 0.055 * np.sin(2 * np.pi * 3 * f * t)
    return body * np.exp(-t / 0.7) * edge_envelope(t, 0.022, 0.14)


def pad(notes: list[int], duration: float) -> np.ndarray:
    t = timeline(duration)
    signal = np.zeros_like(t)
    for index, note in enumerate(notes):
        f = hz(note)
        signal += np.sin(2 * np.pi * f * t + index * 0.71)
        signal += 0.30 * np.sin(2 * np.pi * f * 1.0012 * t + index * 0.29)
    return signal / len(notes) * edge_envelope(t, 0.5, 1.0)


def kick() -> np.ndarray:
    t = timeline(0.24)
    phase = 2 * np.pi * (48.0 * t + 2.5 * (1 - np.exp(-t / 0.030)))
    return np.sin(phase) * np.exp(-t / 0.072) * edge_envelope(t, 0.004, 0.07)


def shaker(strength=1.0) -> np.ndarray:
    t = timeline(0.070)
    noise = RNG.normal(0, 0.50, len(t))
    # Short FIR band shaping removes both low rumble and piercing white hiss.
    shaped = np.convolve(noise, [0.18, 0.28, 0.0, -0.28, -0.18], mode="same")
    return shaped * np.exp(-t / 0.021) * edge_envelope(t, 0.004, 0.020) * strength


def rim() -> np.ndarray:
    t = timeline(0.09)
    body = 0.5 * np.sin(2 * np.pi * 440 * t) + 0.23 * np.sin(2 * np.pi * 730 * t)
    body += RNG.normal(0, 0.07, len(t))
    return body * np.exp(-t / 0.017) * edge_envelope(t, 0.0025, 0.025)


def ui_click(pitch=830.0) -> np.ndarray:
    t = timeline(0.10)
    body = np.sin(2 * np.pi * pitch * t) * np.exp(-t / 0.016)
    body += 0.24 * np.sin(2 * np.pi * pitch * 1.49 * t) * np.exp(-t / 0.008)
    return body * edge_envelope(t, 0.002, 0.025)


def air(seconds=0.48) -> np.ndarray:
    t = timeline(seconds)
    noise = RNG.normal(0, 1, len(t))
    smooth = np.convolve(noise, np.hanning(31) / np.hanning(31).sum(), mode="same")
    envelope = np.sin(np.pi * t / seconds) ** 2
    return smooth * envelope


def arrange():
    # Dmaj9 / Aadd9-C# / Bm7 / Gmaj9. Open voicings avoid a dense jingle feel.
    harmony = [([62, 66, 69, 73, 76], 38), ([61, 64, 69, 71, 76], 37),
               ([62, 66, 69, 71, 74], 35), ([62, 66, 69, 71, 74], 31)]

    # Intro is spacious, with an identifiable three-note motif, no full drums.
    add(MUSIC, 0.10, pad([62, 69, 73, 76], 4.6), 0.12, -0.15)
    add(MUSIC, 3.75, pad([61, 69, 71, 76], 3.8), 0.11, 0.15)
    for at, note, gain in [(0.32, 74, .15), (1.3, 78, .13), (2.3, 76, .12),
                           (4.15, 73, .14), (5.15, 76, .11), (6.25, 81, .09)]:
        add(MUSIC, at, keys(note, 2.0, .65), gain, -.2 if note % 2 else .2)
    for at in [5.5, 6.0, 6.5]:
        add(MUSIC, at, shaker(), .043, .20)

    for bar, start in enumerate(np.arange(7.0, 49.0, 2.0)):
        chord, root = harmony[bar % 4]
        middle = 17 <= start < 27
        expanded = start >= 27
        # Slightly different chord articulations keep the accompaniment alive.
        main_gain = .108 if not expanded else .112
        for i, note in enumerate(chord):
            add(MUSIC, start + i * .020, keys(note, 2.35), main_gain, (i - 2) * .13)
        if bar % 2 == 1:
            for i, note in enumerate(chord[2:]):
                add(MUSIC, start + 1.25 + i * .018, keys(note, 1.4, .65), .046, .17)
        if expanded:
            add(MUSIC, start - .18, pad(chord[1:], 2.8), .092, .12 * (-1) ** bar)

        # Sparse syncopated bass; each four-bar phrase has a different ending.
        add(MUSIC, start, bass(root, .7), .21)
        add(MUSIC, start + .875, bass(root, .42), .115)
        add(MUSIC, start + 1.5, bass(root + (12 if bar % 4 == 3 else 7), .40), .095)

        for beat in [0, 2]:
            add(MUSIC, start + beat * BEAT, kick(), .205 if middle else .17)
        if expanded and bar % 4 == 2:
            add(MUSIC, start + 1.75, kick(), .09)
        for beat in [1, 3]:
            add(MUSIC, start + beat * BEAT, rim(), .047)
        for eighth in range(8):
            if start < 17 and eighth % 2 == 0:
                continue
            add(MUSIC, start + eighth * .25 + (.012 if eighth % 2 else 0),
                shaker(), .044 if eighth % 2 else .030, .24 * (-1) ** eighth)

        # Original call/response, developed across three sections rather than
        # repeating one insistent high arpeggio for the entire film.
        phrases = [
            [(0.50, 74), (1.25, 78), (1.75, 76)],
            [(0.25, 73), (1.00, 76)],
            [(0.50, 74), (1.00, 73), (1.50, 71)],
            [(0.75, 69), (1.50, 74)],
        ]
        notes = phrases[bar % 4]
        if start < 17 and bar % 2 == 1:
            notes = notes[:1]
        if expanded and bar % 8 >= 4:
            notes = [(a + .125, n + (12 if n < 74 else 0)) for a, n in notes[:2]]
        for j, (offset, note) in enumerate(notes):
            gain = .093 if middle else .078
            add(MUSIC, start + offset, wood(note), gain, -.25 if j % 2 else .25)

    # Price: drop drums/bass, leave slower keys and air so text gets attention.
    for start, notes in [(49.0, [62, 66, 69, 73, 76]), (52.5, [59, 62, 66, 69, 74])]:
        add(MUSIC, start, pad(notes[1:], 4.4), .105, -.1)
        for i, note in enumerate(notes):
            add(MUSIC, start + i * .060, keys(note, 3.7, .5), .08, (i - 2) * .12)
    for at, note in [(50.5, 78), (51.5, 76), (54.0, 74)]:
        add(MUSIC, at, wood(note, 1.2), .064, .14)

    # Brand resolution: a single warm Dmaj9 chord with a slow tail.
    for i, note in enumerate([50, 62, 66, 69, 73, 76]):
        add(MUSIC, 56.0 + i * .045, keys(note, 3.9, .48), .11, (i - 2.5) * .10)
    add(MUSIC, 55.9, pad([62, 66, 73, 76], 4.1), .11, .10)
    for at, note in [(56.5, 74), (57.0, 78), (57.5, 81)]:
        add(MUSIC, at, wood(note, 1.6), .063, -.12)

    # Gentle auditory punctuation, intentionally sparse, no continuous typing.
    for at in [0.0, 4.0, 7.0, 17.0, 27.0, 34.0, 40.0, 45.0, 49.0, 56.0]:
        if at > 0:
            add(SFX, at - .24, air(), .048 if at in [7, 27, 56] else .033, -.1)
        CUES.append({"time": at, "type": "soft scene transition"})
    # The pointer and the UI own these exact frame numbers. Never place a click
    # independently of the action table, including keyboard starts and drag ends.
    event_file = Path(__file__).resolve().parents[1] / "design/interaction-events.json"
    interactions = json.loads(event_file.read_text())
    for event in interactions["events"]:
        kind = event["type"]
        if kind not in ["click", "down", "up", "key"]:
            continue
        at = event["frame"] / interactions["fps"]
        pitch = 640 if kind == "key" else 720 if kind == "up" else 850
        add(SFX, at, ui_click(pitch), .052 if kind in ["up", "key"] else .075)
        CUES.append({"time": at, "frame": event["frame"], "type": kind, "scene": event["scene"], "action": event["id"]})
    # Echoed selection notes at key reveal moments, in the same harmonic family.
    for at in [7.0, 27.0, 56.0]:
        add(SFX, at + .07, wood(81, 1.1), .07, -.1)
        add(SFX, at + .19, wood(86, .9), .039, .1)


def space(signal: np.ndarray) -> np.ndarray:
    result = signal.copy()
    # Short low-level stereo room. Nonfeedback taps keep tails controlled.
    for seconds, level in [(.071, .072), (.113, .053), (.179, .037), (.281, .025), (.413, .014)]:
        delay = round(seconds * SR)
        result[delay:, 0] += signal[:-delay, 1] * level
        result[delay:, 1] += signal[:-delay, 0] * level
    return result


def write_pcm16(path: Path, signal: np.ndarray):
    pcm = np.rint(np.clip(signal, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(SR)
        handle.writeframes(pcm.tobytes())


def run(command: list[str]) -> str:
    proc = subprocess.run(command, check=True, capture_output=True, text=True)
    return proc.stderr


def parse_meter(log: str) -> dict:
    begin, end = log.rfind("{"), log.rfind("}")
    if begin < 0 or end < begin:
        raise RuntimeError(f"Missing ffmpeg loudness report: {log[-1200:]}")
    return json.loads(log[begin : end + 1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "public/audio/soundtrack.wav")
    args = parser.parse_args()
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required for measured two-pass normalization")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    arrange()
    mix = space(MUSIC) + space(SFX)
    # Global click-free boundaries; the final second closes to exact zero.
    t = np.arange(N) / SR
    envelope = np.minimum(t / .045, 1) * np.sin(np.minimum((DURATION - t) / 1.15, 1) * np.pi / 2) ** 2
    mix *= envelope[:, None]
    mix -= np.mean(mix, axis=0, keepdims=True)
    mix *= .72 / np.max(np.abs(mix))
    # Reinstate exact zero after DC removal.
    mix *= envelope[:, None]
    loudnorm = "loudnorm=I=-17:TP=-1.5:LRA=9"
    with tempfile.TemporaryDirectory(prefix="prosio-original-audio-") as temp:
        raw = Path(temp) / "mix.wav"
        write_pcm16(raw, mix)
        meter = parse_meter(run([ffmpeg, "-hide_banner", "-i", str(raw), "-af", loudnorm + ":print_format=json", "-f", "null", "-"]))
        measured = (f":measured_I={meter['input_i']}:measured_TP={meter['input_tp']}"
                    f":measured_LRA={meter['input_lra']}:measured_thresh={meter['input_thresh']}"
                    f":offset={meter['target_offset']}:linear=true:print_format=json")
        run([ffmpeg, "-hide_banner", "-y", "-i", str(raw), "-af", loudnorm + measured,
             "-ar", str(SR), "-ac", "2", "-t", str(DURATION), "-c:a", "pcm_s24le", str(args.output)])
    final = parse_meter(run([ffmpeg, "-hide_banner", "-i", str(args.output), "-af", loudnorm + ":print_format=json", "-f", "null", "-"]))
    # Decode independently to verify exact sample count and sample peak.
    decoded = subprocess.run([ffmpeg, "-v", "error", "-i", str(args.output), "-f", "f32le", "-acodec", "pcm_f32le", "-"], capture_output=True, check=True).stdout
    pcm = np.frombuffer(decoded, dtype="<f4").reshape(-1, 2)
    peak = float(np.max(np.abs(pcm)))
    report = {
        "title": "Prosio - Follow the Thought",
        "source": "Original deterministic synthesis; no external music, samples or voice",
        "bpm": BPM, "key": "D major", "duration_seconds": len(pcm) / SR,
        "sample_rate": SR, "channels": 2, "sample_format": "24-bit PCM WAV",
        "integrated_lufs": float(final["input_i"]),
        "true_peak_dbtp": float(final["input_tp"]),
        "sample_peak_dbfs": round(20 * math.log10(peak), 3),
        "loudness_range_lu": float(final["input_lra"]),
        "sections": [{"start": 0, "end": 7, "arrangement": "spacious keys and soft pad"},
                     {"start": 7, "end": 27, "arrangement": "restrained syncopated rhythm"},
                     {"start": 27, "end": 49, "arrangement": "open harmony and developing pluck motif"},
                     {"start": 49, "end": 56, "arrangement": "price: drums and bass removed"},
                     {"start": 56, "end": 60, "arrangement": "Dmaj9 brand resolution and fade"}],
        "transition_cues": CUES,
        "verification": "Measured electronically, not auditioned. Final listening review is recommended with picture.",
    }
    assert report["duration_seconds"] == 60.0, report
    assert -18.0 <= report["integrated_lufs"] <= -16.0, report
    assert report["true_peak_dbtp"] < -1.0, report
    assert report["sample_peak_dbfs"] < -1.0, report
    args.output.with_suffix(".json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"output": str(args.output), **report}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
