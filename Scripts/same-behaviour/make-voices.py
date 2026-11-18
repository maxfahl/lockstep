#!/usr/bin/env python3
"""Makes the voice files Scripts/same-behaviour.sh feeds to Lockstep in the microphone's place.

    python3 Scripts/same-behaviour/make-voices.py

It writes four WAV files (48,000 Hz, mono, 16-bit) beside itself. They are in the repository, so
this is run again only to change them, and a changed voice means a new baseline. Every run
writes the same bytes: nothing is random but a generator with a fixed seed.

A "voice" here is rows of short buzzing syllables with a hiss in front of each, loud enough for
Lockstep to find lines and syllables in. The song the check uses (beatref.wav) has a beat every
0.6 s from 0.1 s, so a sub-beat every 0.15 s. The syllables stand some tens of milliseconds
beside those, so Lines and All have something to move.

    voice-a.wav  5 s    two lines, the first take of the line at the song's start
    voice-b.wav  5 s    the same line said later and lower: its second take
    voice-c.wav  3 s    one line, aimed at another place in the song
    voice-long.wav 16 s lines all the way, for the loop recording and for -recordTake
"""

import math
import random
import struct
import wave
from pathlib import Path

RATE = 48000
HERE = Path(__file__).resolve().parent


def syllable(samples, start, length, pitch, loudness, rng):
    """Adds one syllable: 25 ms of hiss, then a buzz that swells fast and dies slowly."""
    first = int(start * RATE)
    hiss = int(0.025 * RATE)
    total = int(length * RATE)
    for i in range(total):
        at = first + i
        if at >= len(samples):
            return
        if i < hiss:
            value = (rng.random() * 2 - 1) * 0.5 * (i / hiss)
        else:
            t = (i - hiss) / RATE
            rise = min(1.0, t / 0.008)
            fall = math.exp(-3.0 * t / length)
            end = min(1.0, (total - i) / (0.02 * RATE))
            buzz = sum(math.sin(2 * math.pi * pitch * k * t) / k for k in range(1, 9))
            value = buzz * 0.45 * rise * fall * end
        samples[at] += value * loudness


def voice(name, seconds, lines, seed):
    """`lines`: for each line its start in seconds, its pitch, and its syllables as (offset from a
    sub-beat in ms) one per sub-beat or None for a sub-beat left empty."""
    rng = random.Random(seed)
    samples = [0.0] * int(seconds * RATE)
    for start, pitch, steps in lines:
        for index, offset in enumerate(steps):
            if offset is None:
                continue
            at = start + index * 0.15 + offset / 1000
            syllable(samples, at, 0.11, pitch * (1 + 0.03 * (index % 3)), 0.8, rng)
    with wave.open(str(HERE / name), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"".join(
            struct.pack("<h", max(-32767, min(32767, round(s * 32767 * 0.6)))) for s in samples
        ))


# Sub-beats of the song are at 0.1 + n * 0.15 s. A line that starts at 0.7 s stands on one.
voice("voice-a.wav", 5, [
    (0.70, 140, [30, -20, 15, None, 40, -35, 10, 25]),
    (2.95, 150, [-25, 20, 35, -15, None, 30, -40]),
], seed=1)
voice("voice-b.wav", 5, [
    (0.85, 110, [45, 10, -30, 20, None, -10, 35, -25]),
    (3.10, 120, [20, -35, 15, 40, -20, None, 25]),
], seed=2)
voice("voice-c.wav", 3, [
    (0.40, 170, [-40, 25, 10, -15, 35, None, -30, 20]),
], seed=3)
voice("voice-long.wav", 16, [
    (0.25 + 2.4 * bar, 130 + 7 * (bar % 4), [((bar * 17 + i * 29) % 81) - 40 if (bar + i) % 6 else None for i in range(10)])
    for bar in range(6)
] + [(15.0, 125, [20, -10, 30])], seed=4)
