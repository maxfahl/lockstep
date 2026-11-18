#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "numpy==2.2.6",
#     "soundfile==0.13.1",
# ]
# ///
"""Gives made-up speech the quiet room a microphone would have recorded with it.

    Scripts/voice-test/add-room.py <in.wav> <out.wav> [--level -66] [--seed 1]

`say` puts perfect silence between its words. A real recording never has that, and Lockstep decides what
is sound and what is pause from a recording's own quietest tenth. With perfect silence under it, the
faintest tail of a word counts as sound, and every measurement of pause edges and syllables turns on
details 70 dB below the voice that no microphone would show. So the made-up speech gets a room: a steady
hiss that is stronger in the lows (pink noise), at --level dBFS (-66 unless said), added to the whole
file.

The same file, level and seed give the same samples every time. The answer is WAV, 48,000 Hz, 24-bit,
mono, as long as the file that went in. Run by Scripts/voice-test/make-speech.sh.
"""

import argparse
import sys

import numpy as np
import soundfile

RATE = 48_000


def main():
    parser = argparse.ArgumentParser(description="Adds a quiet room to made-up speech.")
    parser.add_argument("source")
    parser.add_argument("output")
    parser.add_argument("--level", type=float, default=-66.0, help="the room's level in dBFS")
    parser.add_argument("--seed", type=int, default=1)
    arguments = parser.parse_args()

    samples, rate = soundfile.read(arguments.source, dtype="float64", always_2d=True)
    if rate != RATE:
        sys.exit(f"{arguments.source} is at {rate} Hz. It must be at 48,000 Hz.")
    speech = samples[:, 0]

    # White noise whose spectrum is tilted by 3 dB an octave above 20 Hz, and flat below.
    white = np.fft.rfft(np.random.default_rng(arguments.seed).standard_normal(len(speech)))
    frequencies = np.fft.rfftfreq(len(speech), 1 / RATE)
    room = np.fft.irfft(white / np.sqrt(np.maximum(frequencies, 20.0)), len(speech))
    room *= 10 ** (arguments.level / 20) / np.sqrt(np.mean(room * room))

    soundfile.write(arguments.output, speech + room, RATE, subtype="PCM_24")


if __name__ == "__main__":
    main()
