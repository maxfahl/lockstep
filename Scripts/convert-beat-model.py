# /// script
# requires-python = ">=3.11,<3.12"
# dependencies = [
#     "beat-this==1.1.0",
#     "coremltools==9.0",
#     "einops==0.8.0",
#     "numpy==1.26.4",
#     "rotary-embedding-torch==0.6.4",
#     "soxr==0.3.7",
#     "torch==2.3.1",
#     "torchaudio==2.3.1",
# ]
# ///
"""Turns the Beat This! checkpoint into a Core ML model and proves the result.

Run by Scripts/install-beat-model.sh, which downloads the checkpoint, checks its
checksum and puts the finished model in its place. On its own:

    uv run --script Scripts/convert-beat-model.py \
        --checkpoint build/beat-model/final0.ckpt --output build/beat-model/BeatThis.mlpackage

The Core ML model:
    input  "spectrogram"  1 x 1500 x 128, 32-bit float: one chunk of the log-mel spectrogram
    output "logits"       1 x 1500 x 2, 32-bit float: for each frame the beat logit, then the
                          bar-start logit

Before the model is saved, it is run on a test input and compared with the PyTorch
original. If the two differ by more than TOLERANCE anywhere, nothing is saved.
"""

import argparse
import shutil
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from beat_this.inference import load_model
from beat_this.preprocessing import LogMelSpect

FRAMES = 1500
BANDS = 128
# Largest difference allowed between a Core ML logit and the PyTorch one. Logits run
# from about -14 to +10 and a beat is a logit above 0; measured differences are near 0.00003.
TOLERANCE = 0.001
UPSTREAM = "CPJKU/beat_this 1.1.0, checkpoint final0"


class BeatAndBarLogits(torch.nn.Module):
    """The original model, with its two outputs put side by side in one array."""

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model

    def forward(self, spectrogram: torch.Tensor) -> torch.Tensor:
        out = self.model(spectrogram)
        return torch.stack([out["beat"], out["downbeat"]], dim=-1)


def test_chunk() -> torch.Tensor:
    """Thirty seconds of a thump every half second over quiet noise, as a spectrogram chunk."""
    rate = 22050
    rng = np.random.default_rng(3)
    sound = rng.standard_normal(rate * 30 - 1) * 0.01
    t = np.arange(2000) / rate
    thump = 0.8 * np.sin(2 * np.pi * 60 * t) * np.exp(-t * 40)
    for start in range(0, len(sound) - len(thump), rate // 2):
        sound[start : start + len(thump)] += thump
    spectrogram = LogMelSpect()(torch.tensor(sound, dtype=torch.float32))
    return spectrogram[:FRAMES].unsqueeze(0).contiguous()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--checkpoint", required=True, type=Path, help="final0.ckpt, already downloaded")
    parser.add_argument("--output", required=True, type=Path, help="where to write BeatThis.mlpackage")
    args = parser.parse_args()

    original = BeatAndBarLogits(load_model(str(args.checkpoint), "cpu")).eval()
    chunk = test_chunk()
    silence = torch.zeros(1, FRAMES, BANDS)
    with torch.inference_mode():
        expected = {"thumps": original(chunk).numpy(), "silence": original(silence).numpy()}

    traced = torch.jit.trace(original, chunk, check_trace=False)
    converted = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spectrogram", shape=(1, FRAMES, BANDS), dtype=np.float32)],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        # 16-bit floats are Core ML's default and are not precise enough for this model.
        compute_precision=ct.precision.FLOAT32,
    )
    converted.short_description = (
        "Beat This! beat and bar-start finder. Takes one 30 second chunk of log-mel "
        "spectrogram (1500 frames x 128 bands at 50 frames per second) and gives, for "
        "each frame, the beat logit and the bar-start logit."
    )
    converted.author = "Institute of Computational Perception, JKU Linz (model); converted for Lockstep"
    converted.license = "MIT"
    converted.version = UPSTREAM
    converted.input_description["spectrogram"] = "1 x 1500 x 128: log(1 + 1000 x mel), frames first"
    converted.output_description["logits"] = "1 x 1500 x 2: beat logit and bar-start logit per frame"

    if args.output.exists():
        shutil.rmtree(args.output)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    converted.save(str(args.output))

    # Compare on the processor only, which is how Lockstep runs it.
    saved = ct.models.MLModel(str(args.output), compute_units=ct.ComputeUnit.CPU_ONLY)
    worst = 0.0
    for name, spectrogram in (("thumps", chunk), ("silence", silence)):
        got = saved.predict({"spectrogram": spectrogram.numpy()})["logits"]
        difference = np.abs(got - expected[name])
        worst = max(worst, float(difference.max()))
        print(
            f"Core ML against PyTorch on {name}: largest difference {difference.max():.6f}, "
            f"average {difference.mean():.6f}"
        )
    if not worst <= TOLERANCE:
        shutil.rmtree(args.output)
        print(f"The converted model is off by {worst:.6f}, more than {TOLERANCE}. Nothing was saved.", file=sys.stderr)
        return 1
    print(f"Saved {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
