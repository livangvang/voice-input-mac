#!/usr/bin/env python3
"""Generate original, distinct recording cues with smooth envelopes and no clipping."""
import math
import pathlib
import struct
import wave

RATE = 48000
ROOT = pathlib.Path(__file__).resolve().parents[1] / "Assets" / "Sounds"
ROOT.mkdir(parents=True, exist_ok=True)


def tone(frequency):
    length = round(RATE * 0.15)
    fade = round(RATE * 0.012)
    result = []
    for i in range(length):
        edge = min(1, i / fade, (length - 1 - i) / fade)
        envelope = 0.5 - 0.5 * math.cos(math.pi * edge)
        phase = 2 * math.pi * frequency * i / RATE
        sample = (math.sin(phase) + 0.18 * math.sin(2 * phase)) / 1.18
        result.append(round(32767 * 0.78 * envelope * sample))
    return result


for name, notes in {"start": (660, 990), "finish": (990, 660)}.items():
    samples = tone(notes[0]) + [0] * round(RATE * 0.055) + tone(notes[1]) + [0] * round(RATE * 0.02)
    with wave.open(str(ROOT / (name + ".wav")), "wb") as wav:
        wav.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        wav.writeframes(struct.pack("<" + "h" * len(samples), *samples))
