#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "numpy==2.2.6",
#     "pyworld==0.3.5",
#     "setuptools==75.8.0",   # pyworld asks it for its own version number when it starts
#     "soundfile==0.13.1",
# ]
# ///
"""The Fast way of phase 37, outside the app: a voice made deeper or lighter with the WORLD vocoder.

    Scripts/voice-test/shift.py <in.wav> <out.wav> --depth <percent> --pitch <semitones>

    Scripts/voice-test/shift.py line.wav darker.wav --depth 6 --pitch -1       # the preset Darker
    Scripts/voice-test/shift.py line.wav same.wav --depth 0 --pitch 0          # taken apart and put together
    Scripts/voice-test/shift.py line.wav d.wav --depth 6 --pitch -1 --f0 dio --frame-ms 2.5 --copy-unvoiced

The voice is taken apart into its pitch, its colour (the spectral envelope, where the formants are) and how
much of it is breath, the two knobs change the first two, and it is put together again. The knobs mean
what they mean in the app:

    --depth   whole percent, -15 to 15. Positive is deeper: at 8 every peak of the envelope sits 8 % lower,
              which is what a larger throat does. The pitch stays.
    --pitch   semitones, -4 to 4 in half steps. The pitch is multiplied. The colour stays.

The file that goes in is mono (or its first channel is taken) at 48,000 Hz. The answer is WAV, 48,000 Hz,
24-bit, mono, with exactly as many samples, and sample n of it belongs where sample n of the source is.
Nothing is resampled. With both knobs at 0 the voice is still taken apart and put together: that is the
"no change" measurement of the test. (In the app, 0 and 0 is the recording itself and nothing is made.)

What WORLD lets one choose, for the experiment that compares them:

    --f0 harvest|dio     how the pitch is found: Harvest (the default, slower, steadier) or DIO with
                         StoneMask (faster)
    --frame-ms 5|2.5     how often the voice is looked at: every 5 ms (the default, 200 times a second) or
                         every 2.5 ms
    --copy-unvoiced      the stretches WORLD finds no pitch in (most consonants, and the pauses) are taken
                         from the source as they are, with a short crossfade (--fade-ms, 5 by default), in
                         place of being made again. They then keep the source's colour, at any Depth.
    --f0-floor, --f0-ceil  the lowest and highest pitch that is looked for, in Hz (71 and 800). A creak
                         (vocal fry) lies under 71 Hz, and Harvest then finds no pitch in it at all.
    --fill-gaps-ms <ms>  every stretch of no pitch at most this long, with a pitch on both sides, is
                         given a pitch from its two neighbours before the voice is made again (0: none)
    --creak-floor <Hz>   Harvest looks a second time from this floor (40, say), and its pitch is taken
                         only where the first look found none: a creak gets a pitch, and every pitch the
                         first look found stays (Harvest only; 0: no second look)

It prints one line: the settings, how long the taking apart and the putting together took, and how many
seconds of work that is for each second of voice. The same file and settings give the same samples every
time.

Run it with `uv`, which fetches the packages. To keep them inside the checkout, as the rules of phase 37
ask: `UV_CACHE_DIR=build/uv-cache Scripts/voice-test/shift.py …`. `pyworld` has no ready-made build for
this Mac, so the first run compiles it (it needs the Xcode command line tools).

Licences. WORLD (M. Morise, https://github.com/mmorise/World) is under the modified BSD licence (three
clauses): it may be used in source and binary form, also in an app that is sold, with its copyright notice
kept. `pyworld` (J. Hsu, https://github.com/JeremyCCHsu/Python-Wrapper-for-World-Vocoder), which wraps the
same C++ and carries a copy of it, is under the MIT licence. numpy and soundfile are under BSD licences,
and soundfile's build carries libsndfile, which is under the LGPL, version 2.1.
"""

import argparse
import sys
import time

import numpy as np
import pyworld
import soundfile

RATE = 48_000


def read(path):
    """The first channel of a sound file at 48,000 Hz, as 64-bit floats."""
    samples, rate = soundfile.read(path, dtype="float64", always_2d=True)
    if rate != RATE:
        sys.exit(f"{path} is at {rate} Hz. It must be at 48,000 Hz.")
    return np.ascontiguousarray(samples[:, 0])


def moved_colour(envelope, depth):
    """The envelope with every peak `depth` percent lower (or higher, when negative).

    What stands at the frequency f afterwards is what stood at f / (1 - depth / 100) before. Between two
    of WORLD's frequencies the decibels are joined by a straight line. Above the top of the envelope its
    last value is held.
    """
    if depth == 0:
        return envelope
    bins = envelope.shape[1]
    source = np.arange(bins) / (1 - depth / 100)
    below = np.minimum(np.floor(source).astype(int), bins - 1)
    above = np.minimum(below + 1, bins - 1)
    share = np.clip(source - below, 0, 1)
    logs = np.log(envelope)
    return np.ascontiguousarray(np.exp(logs[:, below] * (1 - share) + logs[:, above] * share))


def filled_gaps(pitch, longest):
    """The pitch with every stretch of no pitch that is at most `longest` frames long, and has a pitch on
    both sides, filled in from its two neighbours (straight in semitones). A short hole in the middle of a
    voiced stretch is the pitch finder losing a creak, not a consonant."""
    pitch = pitch.copy()
    voiced = pitch > 0
    index = 0
    while index < len(pitch):
        if voiced[index]:
            index += 1
            continue
        end = index
        while end < len(pitch) and not voiced[end]:
            end += 1
        if index > 0 and end < len(pitch) and end - index <= longest:
            before, after = np.log2(pitch[index - 1]), np.log2(pitch[end])
            share = np.arange(1, end - index + 1) / (end - index + 1)
            pitch[index:end] = 2 ** (before + (after - before) * share)
        index = end
    return pitch


def source_share(pitch, count, frame_ms, fade_ms):
    """For every sample, how much of it is taken from the source: 1 where WORLD found no pitch, 0 where
    it found one, and a crossfade of `fade_ms` around every change from one to the other."""
    frames = np.minimum((np.arange(count) / (RATE * frame_ms / 1000) + 0.5).astype(int), len(pitch) - 1)
    share = (pitch[frames] == 0).astype(np.float64)
    fade = max(int(RATE * fade_ms / 1000), 1)
    window = np.hanning(fade + 2)[1:-1]
    return np.convolve(share, window / window.sum(), mode="same")


def main():
    parser = argparse.ArgumentParser(description="A voice made deeper or lighter with the WORLD vocoder.")
    parser.add_argument("source")
    parser.add_argument("output")
    parser.add_argument("--depth", type=float, required=True, help="percent, -15 to 15; positive is deeper")
    parser.add_argument("--pitch", type=float, required=True, help="semitones, -4 to 4")
    parser.add_argument("--f0", choices=["harvest", "dio"], default="harvest")
    parser.add_argument("--frame-ms", type=float, choices=[5.0, 2.5], default=5.0)
    parser.add_argument("--copy-unvoiced", action="store_true")
    parser.add_argument("--fade-ms", type=float, default=5.0)
    parser.add_argument("--f0-floor", type=float, default=71.0)
    parser.add_argument("--fill-gaps-ms", type=float, default=0.0)
    parser.add_argument("--creak-floor", type=float, default=0.0)
    parser.add_argument("--f0-ceil", type=float, default=800.0)
    arguments = parser.parse_args()
    if not -15 <= arguments.depth <= 15:
        sys.exit("--depth is from -15 to 15.")
    if not -4 <= arguments.pitch <= 4:
        sys.exit("--pitch is from -4 to 4.")

    voice = read(arguments.source)
    if len(voice) == 0:
        sys.exit(f"{arguments.source} holds no sound.")

    started = time.perf_counter()
    if arguments.f0 == "harvest":
        pitch, times = pyworld.harvest(
            voice, RATE, f0_floor=arguments.f0_floor, f0_ceil=arguments.f0_ceil, frame_period=arguments.frame_ms
        )
    else:
        rough, times = pyworld.dio(
            voice, RATE, f0_floor=arguments.f0_floor, f0_ceil=arguments.f0_ceil, frame_period=arguments.frame_ms
        )
        pitch = pyworld.stonemask(voice, rough, times, RATE)
    floor = arguments.f0_floor
    if arguments.creak_floor:
        # A second, lower look, used only where the first found no pitch: a creak gets one, and the pitch
        # the first look found stays wherever it found one.
        low, _ = pyworld.harvest(
            voice, RATE, f0_floor=arguments.creak_floor, f0_ceil=arguments.f0_ceil, frame_period=arguments.frame_ms
        )
        count = min(len(low), len(pitch))
        pitch[:count] = np.where(pitch[:count] > 0, pitch[:count], low[:count])
        floor = min(floor, arguments.creak_floor)
    if arguments.fill_gaps_ms > 0:
        pitch = filled_gaps(pitch, arguments.fill_gaps_ms / arguments.frame_ms)
    # A lower floor makes the colour's analysis window longer, and the breath must be read with the same
    # size, or WORLD cannot put the two together again.
    size = pyworld.get_cheaptrick_fft_size(RATE, floor)
    envelope = pyworld.cheaptrick(voice, pitch, times, RATE, f0_floor=floor, fft_size=size)
    breath = pyworld.d4c(voice, pitch, times, RATE, fft_size=size)
    apart = time.perf_counter()

    made = pyworld.synthesize(
        pitch * 2 ** (arguments.pitch / 12),
        moved_colour(envelope, arguments.depth),
        breath,
        RATE,
        arguments.frame_ms,
    )
    # WORLD's answer can be a few samples short of the source or long. It is made exactly as long.
    made = np.concatenate([made[: len(voice)], np.zeros(max(len(voice) - len(made), 0))])
    if arguments.copy_unvoiced:
        share = source_share(pitch, len(voice), arguments.frame_ms, arguments.fade_ms)
        made = share * voice + (1 - share) * made
    together = time.perf_counter()

    highest = float(np.max(np.abs(made)))
    soundfile.write(arguments.output, made, RATE, subtype="PCM_24")

    seconds = len(voice) / RATE
    work = together - started
    print(
        f"{arguments.output}: depth {arguments.depth:g} %, pitch {arguments.pitch:g} semitones, "
        f"{arguments.f0}, a frame every {arguments.frame_ms:g} ms"
        + (f", no-pitch stretches copied with a {arguments.fade_ms:g} ms crossfade" if arguments.copy_unvoiced else "")
        + (f", pitch from {arguments.f0_floor:g} Hz" if arguments.f0_floor != 71 else "")
        + (f", holes of up to {arguments.fill_gaps_ms:g} ms filled" if arguments.fill_gaps_ms > 0 else "")
        + (f", a creak looked for from {arguments.creak_floor:g} Hz" if arguments.creak_floor else "")
        + f"; {len(made)} samples ({seconds:.2f} s); taken apart in {apart - started:.2f} s, put together in "
        f"{together - apart:.2f} s, {work / seconds:.2f} s of work for each second of voice"
        + (f"; THE HIGHEST SAMPLE IS {highest:.2f} OF FULL SCALE AND WAS CUT OFF IN THE FILE" if highest > 1 else "")
    )


if __name__ == "__main__":
    main()
