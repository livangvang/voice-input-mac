#!/usr/bin/env python3
"""Generate soft wooden taps: two for start, one for finish.

2026-10-08：原本太尖銳，尤其最大聲的時候。尖的來源有三個，一起調軟：
開頭那記雜訊爆點（transient 0.38 → 0.07）、1380 Hz 泛音（0.25 → 0.08、衰減更快）、
0.6 ms 的瞬間起音（→ 5 ms）。低頻本體的尾巴拉長（0.014 → 0.018 秒）補回厚度，
整體音量也降一階（主頻由約 3.5 kHz 降到約 650 Hz）。

兩聲之間也從 0.075 秒收到 0.06 秒。
實聽調過兩輪：第一輪一路調到主頻 530 Hz（transient 0.03、泛音 0.04、起音 10 ms），
太悶，這一版往回硬一階。"""
import math
import pathlib
import random
import struct
import wave

RATE = 48000
GAIN_INCREASE = 0.95       # 2026-10-08：比原本的 1.15 小一階，最大聲時才不刺耳
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
        body = 0.65 * math.sin(2 * math.pi * 520 * t) * math.exp(-t / 0.018)
        body += 0.08 * math.sin(2 * math.pi * 1380 * t) * math.exp(-t / 0.004)
        attack = min(1, t / 0.005)
        tail = min(1, (length - 1 - i) / (RATE * 0.01))
        samples.append((body + 0.07 * transient) * attack * tail)
    gain = 32767 * 0.78 * GAIN_INCREASE / max(abs(x) for x in samples)
    return [round(x * gain) for x in samples]


knock = tap()
for name, samples in {
    # 兩聲之間 0.06 秒（原本 0.075 太散、0.035 太黏）
    "start": knock + [0] * round(RATE * 0.06) + knock + [0] * round(RATE * 0.04),
    "finish": knock + [0] * round(RATE * 0.04),
}.items():
    with wave.open(str(ROOT / (name + ".wav")), "wb") as wav:
        wav.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        wav.writeframes(struct.pack("<" + "h" * len(samples), *samples))
