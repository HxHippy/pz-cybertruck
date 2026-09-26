#!/usr/bin/env python3
"""Synthesizes the Cybertruck's motor loop and start/stop chimes (no samples, nothing licensed).

Writes media/sound/cybertruck_{motor,start,stop}.ogg. Needs numpy and ffmpeg with libvorbis.
"""
import os
import subprocess
import wave

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Contents", "mods", "Cybertruck", "42",
                   "media", "sound")


def write(name, x):
    x = np.clip(x / (np.max(np.abs(x)) + 1e-9) * 0.8, -1, 1)
    tmp = f"/tmp/{name}.wav"
    with wave.open(tmp, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())
    os.makedirs(OUT, exist_ok=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-c:a", "libvorbis", "-q:a", "4",
                    os.path.join(OUT, name + ".ogg")], check=True)


def motor():
    # 4 s loop; every partial completes whole cycles so the seam is silent.
    t = np.arange(SR * 4) / SR
    hum = 0.35 * np.sin(2 * np.pi * 110 * t) + 0.15 * np.sin(2 * np.pi * 220 * t)
    whine = 0.07 * np.sin(2 * np.pi * 1320 * t) * (0.75 + 0.25 * np.sin(2 * np.pi * 0.5 * t))
    rng = np.random.default_rng(7)
    noise = rng.standard_normal(len(t))
    noise = np.convolve(noise, np.ones(40) / 40, mode="same") * 0.25  # soft tire/air rush
    fade = np.ones(len(t))
    edge = 2000  # crossfade the noise at the seam
    fade[:edge] = np.linspace(0, 1, edge)
    fade[-edge:] = np.linspace(1, 0, edge)
    noise = noise * fade + np.roll(noise * (1 - fade), edge)
    return hum + whine + noise


def chime(freqs, dur=0.22):
    parts = []
    for f in freqs:
        t = np.arange(int(SR * dur)) / SR
        env = np.minimum(1, t / 0.01) * np.exp(-t * 9)
        parts.append((np.sin(2 * np.pi * f * t) + 0.3 * np.sin(2 * np.pi * 2 * f * t)) * env)
    return np.concatenate(parts + [np.zeros(int(SR * 0.1))])


if __name__ == "__main__":
    write("cybertruck_motor", motor())
    write("cybertruck_start", chime([659.3, 987.8]))
    write("cybertruck_stop", chime([987.8, 659.3]))
    print("wrote", sorted(os.listdir(OUT)))
