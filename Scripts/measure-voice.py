#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "numpy==2.2.6",
#     "praat-parselmouth==0.4.7",
#     "scipy==1.15.3",
#     "soundfile==0.13.1",
# ]
# ///
"""Compares two sound files of the same line: a recording and a voice made from it.

    Scripts/measure-voice.py <a.wav> <b.wav>
    Scripts/measure-voice.py --json numbers.json line.wav line-darker.wav
    Scripts/measure-voice.py --formant-ceiling 5500 her-line.wav her-line-darker.wav

`a` is the recording and `b` the made voice. Both are mono (or the first channel is taken) at 48,000 Hz,
and sample n of b is taken to belong where sample n of a is, as a made voice of phase 37 must. It prints,
and with --json also writes:

    length        of each, in samples and seconds
    pitch         the middle pitch of each where both are voiced, in Hz, and how far b is from a in
                  semitones: between the two middles, and as the middle of the frames' own distances
    formants      the middle of the first three formants of each over the voiced parts of a, in Hz, and
                  how far b's lie from a's in percent, frame by frame. A Depth of 6 shows as about -6 %
    spectra       the distance between the two spectra, in decibels, over the voiced parts and over the
                  consonants (sound that is not voiced). 0 is the same sound. See "The distance" below
    pauses        the level of what each has where a has its pauses, in dBFS
    loudness      of each whole (the measure Normalize uses: BS.1770 integrated, as `Loudness.integrated`
                  in LockstepCore), and of every stretch of 1 to 4 seconds between pauses, with b first
                  brought to a's loudness as a whole: what is left then is what a single clip can be off
    sound ends    the frequency above which each has no sound

What is voiced, what is a consonant and what is a pause is decided from a alone, so both files are held
against the same parts. A pause is where a is no more than 12 dB above its own quietest tenth. Voiced is
where Praat finds a pitch in a. A consonant is sound in a that is not voiced.

The distance. Both are cut into frames of 21 ms, one every 5 ms. The power of each frame is gathered into
40 bands that are spaced as the ear hears (mel) from 50 to 16,000 Hz, in decibels, and nothing counts as
quieter than -100 dBFS. The distance of a frame is the root of the mean square of the 40 differences, and
the number given is the mean over the frames. b is first brought to a's loudness, so a voice that is only
quieter is not far away. Bands as wide as these do not see single overtones, so a small change of pitch
alone is a small distance and a moved formant is a large one.

Where the sound ends. The spectrum of each over the parts with sound is taken in bands of 250 Hz. A band
has sound when it is more than 6 dB above the same band in the pauses and within 90 dB of the strongest
band. The answer is the top of the highest band that has sound and whose lower neighbour has it too. A
file made at 24,000 Hz and brought up to 48,000 Hz shows 12 kHz here.

Pitch and formants are Praat's (its autocorrelation pitch, looked for around where each voice lies, and
its Burg formants: five below --formant-ceiling, 5,000 Hz for a man's voice and 5,500 for a woman's).

Run it with `uv`, which fetches the packages. To keep them inside the checkout, as the rules of phase 37
ask: `UV_CACHE_DIR=build/uv-cache Scripts/measure-voice.py …`.

Licences. This is a tool of the workshop and no part of the app. It imports Praat through `parselmouth`,
and both are under the GPL, version 3 or later, so the script would be too if it were ever given to anyone.
numpy, scipy and soundfile are under BSD licences, and soundfile's build carries libsndfile (LGPL 2.1).
"""

import argparse
import json
import sys

import numpy as np
import parselmouth
import soundfile
from scipy.signal import lfilter

RATE = 48_000
HOP = 240  # 5 ms
WINDOW = 1024  # 21 ms
BANDS = 40
QUIETEST_DB = -100.0


def read(path):
    """The first channel of a sound file at 48,000 Hz, as 64-bit floats."""
    samples, rate = soundfile.read(path, dtype="float64", always_2d=True)
    if rate != RATE:
        sys.exit(f"{path} is at {rate} Hz. It must be at 48,000 Hz.")
    return np.ascontiguousarray(samples[:, 0])


# The loudness, as `Loudness.integrated` in LockstepCore measures it.


def k_weighted_energy(samples):
    """The samples after the two filters of BS.1770 for 48 kHz, squared."""
    shelved = lfilter(
        [1.53512485958697, -2.69169618940638, 1.19839281085285], [1.0, -1.69065929318241, 0.73248077421585], samples
    )
    passed = lfilter([1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621], shelved)
    return passed * passed


def lufs(mean_square):
    return -0.691 + 10 * np.log10(mean_square) if mean_square > 0 else -np.inf


def loudness(samples):
    """The integrated loudness in LUFS, or None when there is nothing louder than -70 LUFS."""
    if len(samples) == 0:
        return None
    energy = k_weighted_energy(samples)
    block, step = 19_200, 4_800
    if len(samples) < block:
        value = lufs(energy.sum() / len(samples))
        return float(value) if value > -70 else None
    steps = energy[: len(energy) // step * step].reshape(-1, step).sum(axis=1)
    blocks = (steps[:-3] + steps[1:-2] + steps[2:-1] + steps[3:]) / block
    audible = [value for value in blocks if lufs(value) > -70]
    if not audible:
        return None
    threshold = lufs(np.mean(audible)) - 10
    counted = [value for value in audible if lufs(value) > threshold]
    return float(lufs(np.mean(counted))) if counted else None


# Frames.


def frames_of(samples, count):
    """`count` frames of WINDOW samples, frame i centred on sample i * HOP, with silence past the ends."""
    padded = np.concatenate([np.zeros(WINDOW // 2), samples, np.zeros(WINDOW + count * HOP)])
    index = np.arange(count)[:, None] * HOP + np.arange(WINDOW)[None, :]
    return padded[index]


def decibels(power):
    return 10 * np.log10(np.maximum(power, 1e-30))


def mel_bands():
    """A row for each of the 40 bands: how much of each frequency of a frame's spectrum it gathers."""

    def mel(hertz):
        return 2595 * np.log10(1 + hertz / 700)

    def hertz(mel_value):
        return 700 * (10 ** (mel_value / 2595) - 1)

    edges = hertz(np.linspace(mel(50.0), mel(16_000.0), BANDS + 2))
    frequencies = np.fft.rfftfreq(WINDOW, 1 / RATE)
    rows = np.zeros((BANDS, len(frequencies)))
    for band in range(BANDS):
        low, middle, high = edges[band], edges[band + 1], edges[band + 2]
        rising = (frequencies - low) / (middle - low)
        falling = (high - frequencies) / (high - middle)
        rows[band] = np.maximum(0, np.minimum(rising, falling))
        rows[band] /= max(rows[band].sum(), 1e-12)
    return rows


def spectra(frames):
    """The power spectrum of every frame, with a full-scale sine reading 1."""
    window = np.hanning(WINDOW)
    return np.abs(np.fft.rfft(frames * window, axis=1)) ** 2 / (window.sum() / 2) ** 2


def band_levels(power):
    """Each frame's power in the 40 bands, in decibels and never under -100."""
    return np.maximum(decibels(power @ mel_bands().T), QUIETEST_DB)


# Praat.


def pitch_of(samples, times):
    """The pitch at each time in Hz, and 0 where Praat finds none.

    Praat is asked twice, as is usual: once from 60 to 600 Hz, and then again between three quarters of
    the lower quartile of what it found and twice the upper one. Looking only where this voice is keeps it
    from taking an overtone or half the pitch for the pitch.
    """
    sound = parselmouth.Sound(samples, RATE)

    def track(floor, ceiling):
        return sound.to_pitch_ac(time_step=HOP / RATE, pitch_floor=floor, pitch_ceiling=ceiling)

    first = track(60.0, 600.0).selected_array["frequency"]
    first = first[first > 0]
    if len(first) == 0:
        return np.zeros(len(times))
    lower, upper = np.percentile(first, [25, 75])
    second = track(max(0.75 * lower, 50.0), min(2 * upper, 800.0))
    values = second.selected_array["frequency"]
    nearest = np.clip(np.rint((times - second.xs()[0]) / second.dx).astype(int), 0, len(values) - 1)
    found = values[nearest]
    found[(times < second.xmin) | (times > second.xmax)] = 0
    return found


def formants_of(samples, times, ceiling):
    """The first three formants at each time in Hz, a row for each time. Not a number where Praat has none."""
    track = parselmouth.Sound(samples, RATE).to_formant_burg(
        time_step=HOP / RATE, max_number_of_formants=5, maximum_formant=ceiling
    )
    return np.array([[track.get_value_at_time(number, time) for number in (1, 2, 3)] for time in times])


# The parts of the line.


def runs(mask):
    """The stretches where a row of yes and no says yes, as pairs of first index and one past the last."""
    edges = np.flatnonzero(np.diff(np.concatenate([[0], mask.astype(int), [0]])))
    return list(zip(edges[::2], edges[1::2]))


def stretches(sound, level):
    """The stretches of 1 to 4 seconds between pauses, in frames.

    A pause of a quarter of a second or more separates two stretches, as it separates two lines in the app.
    A stretch longer than 4 seconds is cut at its quietest frame between 1 and 4 seconds from its start, as
    often as it takes. What is left shorter than a second is not measured.
    """
    second = RATE // HOP
    filled = sound.copy()
    for first, last in runs(~sound):
        if last - first < second // 4 and first > 0 and last < len(sound):
            filled[first:last] = True
    found = []
    for first, last in runs(filled):
        while last - first > 4 * second:
            cut = first + second + int(np.argmin(level[first + second : first + 4 * second]))
            found.append((first, cut))
            first = cut
        if last - first >= second:
            found.append((first, last))
    return found


def sound_ends(power, sound, pause):
    """The frequency above which there is no sound, in Hz."""
    if not sound.any():
        return 0.0
    width = 250.0
    frequencies = np.fft.rfftfreq(WINDOW, 1 / RATE)
    band_of = np.minimum((frequencies / width).astype(int), int(RATE / 2 / width) - 1)
    count = band_of.max() + 1

    def levels(mask):
        mean = power[mask].mean(axis=0)
        return decibels(np.array([mean[band_of == band].mean() for band in range(count)]))

    in_sound = levels(sound)
    has = in_sound > in_sound.max() - 90
    if pause.any():
        has &= in_sound > levels(pause) + 6
    for band in range(count - 1, 0, -1):
        if has[band] and has[band - 1]:
            return float((band + 1) * width)
    return float(width) if has[0] else 0.0


def middle(values):
    values = np.asarray(values, dtype=float)
    values = values[np.isfinite(values)]
    return float(np.median(values)) if len(values) else None


def rounded(value, places=2):
    return None if value is None else round(float(value), places)


def measure(a, b, ceiling):
    count = min(len(a), len(b)) // HOP
    if count < 4:
        sys.exit("The files are too short to compare: less than 20 ms.")
    times = np.arange(count) * HOP / RATE
    a_cut, b_cut = a[: count * HOP], b[: count * HOP]

    loud_a, loud_b = loudness(a), loudness(b)
    gain = 10 ** ((loud_a - loud_b) / 20) if loud_a is not None and loud_b is not None else 1.0
    b_matched = b_cut * gain

    power_a, power_b = spectra(frames_of(a_cut, count)), spectra(frames_of(b_matched, count))

    # What is sound in a: more than 12 dB above its own quietest tenth.
    frame_level = decibels((frames_of(a_cut, count) ** 2).mean(axis=1))
    floor = max(float(np.percentile(frame_level, 10)), -90.0)
    sound = frame_level > floor + 12
    pause = ~sound

    pitch_a, pitch_b = pitch_of(a_cut, times), pitch_of(b_cut, times)
    voiced = sound & (pitch_a > 0)
    consonant = sound & ~voiced
    both = voiced & (pitch_b > 0)

    formants_a, formants_b = formants_of(a_cut, times, ceiling), formants_of(b_cut, times, ceiling)
    with np.errstate(invalid="ignore", divide="ignore"):
        formant_change = (formants_b / formants_a - 1) * 100
        pitch_change = 12 * np.log2(pitch_b[both] / pitch_a[both]) if both.any() else np.array([])

    levels_a, levels_b = band_levels(power_a), band_levels(power_b)
    distance = np.sqrt(((levels_b - levels_a) ** 2).mean(axis=1))

    def level_in(samples, mask):
        if not mask.any():
            return None
        return float(decibels((frames_of(samples, count)[mask] ** 2).mean()))

    # The two middles are taken over the same frames, so they differ by the pitch and not by which
    # frames each happens to be voiced in. A file that is voiced nowhere the other is has no middle.
    middle_a = middle(pitch_a[both]) if both.any() else None
    middle_b = middle(pitch_b[both]) if both.any() else None

    pieces = []
    for first, last in stretches(sound, frame_level):
        piece_a = loudness(a_cut[first * HOP : last * HOP])
        piece_b = loudness(b_matched[first * HOP : last * HOP])
        pieces.append(
            {
                "fromSeconds": rounded(first * HOP / RATE, 3),
                "toSeconds": rounded(last * HOP / RATE, 3),
                "a": rounded(piece_a),
                "b": rounded(piece_b),
                "difference": rounded(piece_b - piece_a) if piece_a is not None and piece_b is not None else None,
            }
        )
    differences = [abs(piece["difference"]) for piece in pieces if piece["difference"] is not None]

    return {
        "length": {
            "aSamples": len(a),
            "bSamples": len(b),
            "aSeconds": rounded(len(a) / RATE, 3),
            "bSeconds": rounded(len(b) / RATE, 3),
            "differenceSamples": len(b) - len(a),
        },
        "parts": {
            "voicedSeconds": rounded(voiced.sum() * HOP / RATE, 2),
            "consonantSeconds": rounded(consonant.sum() * HOP / RATE, 2),
            "pauseSeconds": rounded(pause.sum() * HOP / RATE, 2),
            "soundAboveDb": rounded(floor + 12, 1),
        },
        "pitch": {
            "aHz": rounded(middle_a, 1),
            "bHz": rounded(middle_b, 1),
            "semitones": rounded(12 * np.log2(middle_b / middle_a)) if middle_a and middle_b else None,
            "semitonesFrameByFrame": rounded(middle(pitch_change)) if len(pitch_change) else None,
        },
        "formants": {
            "aHz": [rounded(middle(formants_a[voiced, n]), 0) for n in range(3)],
            "bHz": [rounded(middle(formants_b[voiced, n]), 0) for n in range(3)],
            "changePercent": [rounded(middle(formant_change[voiced, n]), 1) for n in range(3)],
            "ceilingHz": ceiling,
        },
        "spectra": {
            "voicedDb": rounded(distance[voiced].mean()) if voiced.any() else None,
            "consonantsDb": rounded(distance[consonant].mean()) if consonant.any() else None,
        },
        "pauses": {
            "aDbfs": rounded(level_in(a_cut, pause), 1),
            "bDbfs": rounded(level_in(b_cut, pause), 1),
        },
        "loudness": {
            "aLufs": rounded(loud_a),
            "bLufs": rounded(loud_b),
            "difference": rounded(loud_b - loud_a) if loud_a is not None and loud_b is not None else None,
            "stretches": pieces,
            "stretchesFurthest": rounded(max(differences)) if differences else None,
            "stretchesMean": rounded(float(np.mean(differences))) if differences else None,
        },
        "soundEnds": {
            "aHz": sound_ends(power_a, sound, pause),
            "bHz": sound_ends(power_b, sound, pause),
        },
    }


def said(value, unit="", places=1):
    return "none" if value is None else f"{value:.{places}f}{unit}"


def words(found, a_path, b_path):
    length, parts, pitch = found["length"], found["parts"], found["pitch"]
    formants, spectra_found, pauses = found["formants"], found["spectra"], found["pauses"]
    loud, ends = found["loudness"], found["soundEnds"]
    lines = [
        f"a: {a_path}",
        f"b: {b_path}",
        f"  length: a {length['aSamples']} samples ({length['aSeconds']:.3f} s), b {length['bSamples']} samples "
        f"({length['bSeconds']:.3f} s)"
        + (
            ", the same"
            if length["differenceSamples"] == 0
            else f": b is {abs(length['differenceSamples'])} samples "
            + ("longer" if length["differenceSamples"] > 0 else "shorter")
        ),
        f"  parts of a: {parts['voicedSeconds']:.2f} s voiced, {parts['consonantSeconds']:.2f} s consonants, "
        f"{parts['pauseSeconds']:.2f} s pauses (sound is what is above {parts['soundAboveDb']:.1f} dBFS)",
        f"  pitch: a {said(pitch['aHz'], ' Hz')}, b {said(pitch['bHz'], ' Hz')}: b is "
        f"{said(pitch['semitones'], ' semitones', 2)} from a "
        f"(frame by frame {said(pitch['semitonesFrameByFrame'], ' semitones', 2)})",
        "  formants: a "
        + ", ".join(said(value, " Hz", 0) for value in formants["aHz"])
        + "; b "
        + ", ".join(said(value, " Hz", 0) for value in formants["bHz"])
        + "; b's lie "
        + ", ".join(said(value, " %") for value in formants["changePercent"])
        + " from a's, frame by frame",
        f"  spectra: {said(spectra_found['voicedDb'], ' dB', 2)} apart over the voiced parts, "
        f"{said(spectra_found['consonantsDb'], ' dB', 2)} over the consonants",
        f"  pauses: a holds {said(pauses['aDbfs'], ' dBFS')} there, b {said(pauses['bDbfs'], ' dBFS')}",
        f"  loudness: a {said(loud['aLufs'], ' LUFS', 2)}, b {said(loud['bLufs'], ' LUFS', 2)}: b is "
        f"{said(loud['difference'], ' dB', 2)} from a",
    ]
    if loud["stretches"]:
        lines.append(
            f"  loudness of the {len(loud['stretches'])} stretches of 1 to 4 s, with b brought to a's loudness: "
            f"furthest {said(loud['stretchesFurthest'], ' dB', 2)} off, mean {said(loud['stretchesMean'], ' dB', 2)}"
        )
        for piece in loud["stretches"]:
            lines.append(
                f"    {piece['fromSeconds']:.3f} to {piece['toSeconds']:.3f} s: a {said(piece['a'], ' LUFS', 2)}, "
                f"b {said(piece['b'], ' LUFS', 2)}, {said(piece['difference'], ' dB', 2)}"
            )
    else:
        lines.append("  loudness of stretches: a has no stretch of a second or more between pauses")
    lines.append(f"  sound ends: a at {ends['aHz']:.0f} Hz, b at {ends['bHz']:.0f} Hz")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Compares two sound files of the same line.")
    parser.add_argument("a", help="the recording")
    parser.add_argument("b", help="the voice made from it")
    parser.add_argument("--json", help="also write the numbers to this file")
    parser.add_argument("--formant-ceiling", type=float, default=5000.0)
    arguments = parser.parse_args()

    found = measure(read(arguments.a), read(arguments.b), arguments.formant_ceiling)
    print(words(found, arguments.a, arguments.b))
    if arguments.json:
        with open(arguments.json, "w") as file:
            json.dump({"a": arguments.a, "b": arguments.b, **found}, file, indent=1)
            file.write("\n")


if __name__ == "__main__":
    main()
