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
"""A made voice brought to the loudness of its line, for the files that are listened to.

    Scripts/voice-test/as-loud.py <line.wav> <voice.wav> <out.wav>

The design asks for the files to listen to to be as loud as the line, "so that no file sounds better only
because it is louder". The loudness is the one Normalize uses (BS.1770 integrated), taken from
Scripts/measure-voice.py so the two can never measure differently. If a sample would pass full scale, the
gain is lowered until the highest sample is at -0.1 dBFS, as the app's `takeIn` does, and the line it
prints says so. The answer is WAV, 48,000 Hz, 24-bit, mono. Licences as for measure-voice.py.
"""

import importlib.util
import sys
from pathlib import Path

import numpy as np
import soundfile

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # importing measure-voice.py would otherwise leave Scripts/__pycache__ behind
spec = importlib.util.spec_from_file_location("measure_voice", HERE.parent / "measure-voice.py")
measure_voice = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure_voice)


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    line, voice = measure_voice.read(sys.argv[1]), measure_voice.read(sys.argv[2])
    target, now = measure_voice.loudness(line), measure_voice.loudness(voice)
    gain_db = target - now if target is not None and now is not None else 0.0
    highest = float(np.max(np.abs(voice))) * 10 ** (gain_db / 20)
    ceiling = 10 ** (-0.1 / 20)
    lowered = 0.0
    if highest > ceiling:
        lowered = 20 * np.log10(highest / ceiling)
        gain_db -= lowered
    soundfile.write(sys.argv[3], voice * 10 ** (gain_db / 20), measure_voice.RATE, subtype="PCM_24")
    print(
        f"{sys.argv[3]}: {gain_db:+.2f} dB"
        + (f", {lowered:.2f} dB less than the line's loudness asks, so no sample passes -0.1 dBFS" if lowered else "")
    )


if __name__ == "__main__":
    main()
