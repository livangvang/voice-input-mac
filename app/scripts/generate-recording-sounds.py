#!/usr/bin/env python3
"""Generate wooden taps: two for start, one for finish, with 15% more gain."""
import math
import pathlib
import random
import struct
import wave

RATE = 48000
GAIN_INCREASE = 1.15
ROOT = pathlib.Path(__file__).resolve().parents[1] / "Assets" / "Sounds"
ROOT.mkdir(parents=True, exist_ok=True)


def tap():
    rng = random.Random(42)
    length = round(RATE * 0.12)
    samples = []
    previous_noise = 0
    for i in range(length):
        t = i / RATE
        noise = rng.uniform(-1, 1)
        transient = (noise - 0.75 * previous_noise) * math.exp(-t / 0.004)
        previous_noise = noise
        body = 0.65 * math.sin(2 * math.pi * 520 * t) * math.exp(-t / 0.014)
        body += 0.25 * math.sin(2 * math.pi * 1380 * t) * math.exp(-t / 0.006)
        attack = min(1, t / 0.0006)
        tail = min(1, (length - 1 - i) / (RATE * 0.01))
        samples.append((body + 0.38 * transient) * attack * tail)
    gain = 32767 * 0.86 * GAIN_INCREASE / max(abs(x) for x in samples)
    return [round(x * gain) for x in samples]


knock = tap()
for name, samples in {
    "start": knock + [0] * round(RATE * 0.075) + knock + [0] * round(RATE * 0.04),
    "finish": knock + [0] * round(RATE * 0.04),
}.items():
    with wave.open(str(ROOT / (name + ".wav")), "wb") as wav:
        wav.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        wav.writeframes(struct.pack("<" + "h" * len(samples), *samples))
