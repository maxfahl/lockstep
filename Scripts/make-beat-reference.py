# /// script
# requires-python = ">=3.11,<3.12"
# dependencies = [
#     "beat-this==1.1.0",
#     "einops==0.8.0",
#     "numpy==1.26.4",
#     "rotary-embedding-torch==0.6.4",
#     "soxr==0.3.7",
#     "torch==2.3.1",
#     "torchaudio==2.3.1",
# ]
# ///
"""Writes the reference results that the Swift beat finding is compared with.

    uv run --script Scripts/make-beat-reference.py

It makes two fixed test sounds, runs the original Beat This! code on them (its own
spectrogram, its PyTorch model "final0" on the processor, its beat picking without the
DBN) and writes the results into LockstepKit/Tests/LockstepAudioTests/Fixtures/:

    beatref.wav         70 s, 22,050 Hz, mono, 16-bit: 3,501 frames, so three chunks
    beatref-mel.f32     the log-mel spectrogram: frames x 128 little-endian 32-bit floats
    beatref-logits.f32  frames x 2: the beat logit, then the bar-start logit
    beatref-beats.json  the picked beat and bar-start times in seconds

and the same four files named beatshort for a 12 s sound (601 frames, less than a chunk).

The spectrogram is worked out from the samples as they are stored in the WAV file, so a
program that reads the WAV starts from exactly the same numbers. A second run writes the
same bytes. The checkpoint (81 MB) is downloaded to build/beat-model/ on the first run.
"""

import hashlib
import json
import sys
import urllib.request
import wave
from pathlib import Path

import numpy as np
import torch
from beat_this.inference import Audio2Beats

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "LockstepKit" / "Tests" / "LockstepAudioTests" / "Fixtures"
CHECKPOINT = ROOT / "build" / "beat-model" / "final0.ckpt"
# The same two values are in Scripts/install-beat-model.sh.
CHECKPOINT_URL = "https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt"
CHECKPOINT_SHA256 = "8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331"

RATE = 22050
FRAMES_PER_SECOND = 50
BEAT_SECONDS = 0.6
FIRST_BEAT_SECONDS = 0.1
SEED = 20261112


def checkpoint() -> Path:
    """The checkpoint file, downloaded if it is not there, with its checksum checked."""

    def matches() -> bool:
        return CHECKPOINT.exists() and hashlib.sha256(CHECKPOINT.read_bytes()).hexdigest() == CHECKPOINT_SHA256

    if not matches():
        print("Downloading the checkpoint (81 MB)...")
        CHECKPOINT.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(CHECKPOINT_URL, CHECKPOINT)
        if not matches():
            CHECKPOINT.unlink()
            sys.exit("The downloaded checkpoint does not have the expected checksum.")
    return CHECKPOINT


def test_sound(seconds: int) -> np.ndarray:
    """A simple drum pattern at 100 beats per minute, as 16-bit samples.

    A kick-like thump on every beat (every 0.6 s, the first at 0.1 s), a quieter tick on
    every off-beat, and low noise throughout. A noise burst on beats 2 and 4 and a bass
    note on beat 1 tell the model where the bars are. Without them it hears a metronome
    and its bar starts sit so close to the threshold that the smallest difference in the
    numbers would move them.
    """
    count = seconds * RATE
    rng = np.random.default_rng(SEED)
    sound = rng.standard_normal(count) * 0.002

    t = np.arange(int(0.25 * RATE)) / RATE
    kick = np.sin(2 * np.pi * (50 * t + (100 / 30) * (1 - np.exp(-30 * t)))) * np.exp(-t * 18)
    kick += 0.3 * np.sin(2 * np.pi * 2500 * t) * np.exp(-t * 900)
    t = np.arange(int(0.03 * RATE)) / RATE
    tick = np.sin(2 * np.pi * 6000 * t) * np.exp(-t * 250)
    t = np.arange(int(0.12 * RATE)) / RATE
    burst = rng.standard_normal(len(t)) * np.exp(-t * 35) + 0.5 * np.sin(2 * np.pi * 190 * t) * np.exp(-t * 40)
    t = np.arange(int(0.55 * RATE)) / RATE
    bass_notes = [
        (np.sin(2 * np.pi * hertz * t) * np.exp(-t * 4) + 0.3 * np.sin(4 * np.pi * hertz * t) * np.exp(-t * 6))
        * (1 - np.exp(-t * 300))
        for hertz in (55.0, 55.0, 73.42, 65.41)
    ]

    def add(start: int, shape: np.ndarray, level: float) -> None:
        if start < count:
            length = min(len(shape), count - start)
            sound[start : start + length] += level * shape[:length]

    beat = round(BEAT_SECONDS * RATE)
    for number, start in enumerate(range(round(FIRST_BEAT_SECONDS * RATE), count, beat)):
        add(start, kick, 0.35)
        add(start + beat // 2, tick, 0.08)
        if number % 2 == 1:
            add(start, burst, 0.16)
        if number % 4 == 0:
            add(start, bass_notes[(number // 4) % 4], 0.2)

    assert np.abs(sound).max() < 0.98, "the test sound would clip"
    return np.round(sound * 32767).astype("<i2")


def write_reference(name: str, seconds: int, model: Audio2Beats) -> None:
    samples = test_sound(seconds)
    with wave.open(str(FIXTURES / f"{name}.wav"), "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(RATE)
        file.writeframes(samples.tobytes())

    # From here on, exactly what upstream's Audio2Beats does, step by step, so that the
    # results in between can be saved. The samples are the ones a reader of the WAV gets.
    signal = samples.astype(np.float64) / 32768.0
    spectrogram = model.signal2spect(signal, RATE)
    beat_logits, bar_logits = model.spect2frames(spectrogram)
    beats, bar_starts = model.frames2beats(beat_logits, bar_logits)

    spectrogram.numpy().astype("<f4").tofile(FIXTURES / f"{name}-mel.f32")
    torch.stack([beat_logits, bar_logits], dim=1).numpy().astype("<f4").tofile(FIXTURES / f"{name}-logits.f32")
    picked = {
        "sampleRate": RATE,
        "samples": len(samples),
        "frames": spectrogram.shape[0],
        "framesPerSecond": FRAMES_PER_SECOND,
        "beats": [float(time) for time in beats],
        "barStarts": [float(time) for time in bar_starts],
    }
    (FIXTURES / f"{name}-beats.json").write_text(json.dumps(picked, indent=1) + "\n")
    print(
        f"{name}: {seconds} s, {spectrogram.shape[0]} frames, {len(beats)} beats, {len(bar_starts)} bar starts, "
        f"beat logits from {float(beat_logits.min()):.2f} to {float(beat_logits.max()):.2f}"
    )


def main() -> None:
    # One thread and no random choices, so a second run gives the same bytes.
    torch.set_num_threads(1)
    torch.manual_seed(0)
    model = Audio2Beats(checkpoint_path=str(checkpoint()), device="cpu", dbn=False)
    FIXTURES.mkdir(parents=True, exist_ok=True)
    write_reference("beatref", 70, model)
    write_reference("beatshort", 12, model)


if __name__ == "__main__":
    main()
