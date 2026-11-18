"""The try of SoulX-Singer-SVC in phase 37: one process that loads the models once and converts a list of jobs.

    build/voice-test/soulx/venv/bin/python -I Scripts/voice-test/soulx-render.py \
        --root build/voice-test/soulx --jobs jobs.json --report report.jsonl [--device mps|cpu]

`Scripts/voice-test/soulx-setup.sh` makes the folder `--root` names: `source/` (Soul-AILab/SoulX-Singer at
the commit the setup script pins), `weights/` and `venv/`. This file is not a `uv` script, because it has
to run in that environment, with the model's source beside it.

A job is one line converted toward one reference. `--jobs` names a JSON list of objects:

    source      the line: WAV, mono (or its first channel is taken), 48,000 Hz. Its words, timing and
                melody are kept
    reference   the voice whose colour is taken: WAV at 48,000 Hz, 30 seconds at most (the listener hears
                no more than that)
    out         where the answer goes: WAV, 48,000 Hz, 24-bit, mono, exactly as long as the source
    pitch       semitones the line's pitch is moved by (0 when left out). Half steps are allowed
    seed        the seed set before the job (0 when left out)
    steps, cfg  the model's own two settings (32 and 3, its defaults, when left out)

For each job one line of JSON is printed and added to `--report`: how long each part took, the seconds of
work for each second of voice, where the model joined one stretch to the next, and what the process held.

How it differs from the project's own `cli/inference_svc.py`, and why.

- Every file is loaded by its own path. The project's listener asks the internet for `openai/whisper-base`
  by name, so the listener here is the same class with only its loading replaced, and the libraries are
  told to stay offline.
- Every checkpoint is read as numbers only (`weights_only=True`). The project reads them as pickled Python,
  which lets a model file run code.
- Full precision in every part. The project uses half precision only on NVIDIA cards.
- The pitch is moved by multiplying the line's pitch curve before the model sees it. The model's own
  `pitch_shift` adds whole semitones to the same curve after it is sorted into steps of 20 cents, so for
  whole semitones this is the same thing, and it also allows the half steps the Pitch knob has.
- The model works at 24,000 Hz, so the line and the reference are brought down to that and the answer back
  up (soxr, which keeps sample n where it was). Nothing above 12 kHz comes back.

What the model does with a long line (read in `soulxsinger/models/soulxsinger_svc.py`): a line under 30
seconds is made in one piece. A longer one is cut where no pitch is found for 0.2 seconds or more, into
stretches of 15 to 30 seconds, each made with a stretch of what came before it and cut to its own part.
The parts are laid end to end with no crossfade. The report gives those places as `joins`.

Licences. SoulX-Singer's code and its model files are under Apache-2.0, RMVPE's checkpoint comes from the
same publisher's page (Apache-2.0 there), Whisper base is under Apache-2.0 (MIT at OpenAI's own
repository), PyTorch under a BSD licence. This script imports them and is a tool of the workshop, no part
of the app.
"""

import argparse
import ctypes
import importlib.util
import json
import os
import sys
import time
import traceback

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

RATE = 48_000  # everything in Lockstep
MODEL_RATE = 24_000  # what the model works at
HOP = 480  # one frame of the model: 20 ms


def footprint():
    """What macOS counts as this process's memory, the graphics processor's share included: now and at its most.

    It is the number Activity Monitor shows. The resident size alone leaves out what Metal holds.
    """
    buffer = (ctypes.c_uint64 * 37)()  # rusage_info_v4: 16 bytes of uuid, then 35 numbers
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    if libproc.proc_pid_rusage(os.getpid(), 4, ctypes.byref(buffer)) != 0:
        return None, None
    return int(buffer[2 + 7]), int(buffer[2 + 28])


def megabytes(count):
    return None if count is None else round(count / 1_048_576, 1)


def main():
    parser = argparse.ArgumentParser(description="Converts lines with SoulX-Singer-SVC.")
    parser.add_argument("--root", required=True, help="the folder soulx-setup.sh made")
    parser.add_argument("--jobs", required=True, help="a JSON list of jobs")
    parser.add_argument("--report", help="a file each job's line of JSON is added to")
    parser.add_argument("--device", default="mps", choices=["mps", "cpu"])
    parser.add_argument("--pitch-device", default="cpu", choices=["mps", "cpu"],
                        help="where the pitch follower runs (it is small, and fast on the processor)")
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    source = os.path.join(root, "source")
    weights = os.path.join(root, "weights")
    with open(args.jobs, encoding="utf-8") as handle:
        jobs = json.load(handle)

    started = time.perf_counter()
    import numpy as np
    import soundfile
    import soxr
    import torch

    # Model files are data from outside: read numbers, never pickled code.
    plain_load = torch.load

    def load_numbers_only(*positional, **named):
        named["weights_only"] = True
        return plain_load(*positional, **named)

    torch.load = load_numbers_only

    sys.path.insert(0, source)
    from omegaconf import OmegaConf
    from transformers import WhisperFeatureExtractor, WhisperModel

    import soulxsinger.models.soulxsinger_svc as svc
    from soulxsinger.models.modules.whisper_encoder import WHISPER_MEL_FRAMES, WhisperEncoder

    whisper_folder = os.path.join(weights, "whisper-base")

    class ListenerFromFolder(WhisperEncoder):
        """The project's listener, loaded from a folder in place of by name from the internet.

        Its sound is also brought down to 16 kHz on the processor: torchaudio does that with a conv1d that
        the graphics processor refuses ("Output channels > 65536 not supported at the MPS device"), and
        the project's own code hands the result to numpy at once anyway. Everything after that is the
        project's `encode`, line for line, on the device the sound came from.
        """

        def __init__(self, device=None):
            self.fe = WhisperFeatureExtractor.from_pretrained(whisper_folder, local_files_only=True)
            self.model = WhisperModel.from_pretrained(whisper_folder, local_files_only=True).float().eval()

        def encode(self, wav, sr):
            import torchaudio

            device = wav.device
            low = torchaudio.functional.resample(wav.detach().float().cpu(), orig_freq=sr,
                                                 new_freq=self.fe.sampling_rate)
            inputs = self.fe(low.numpy(), sampling_rate=self.fe.sampling_rate, return_tensors="pt",
                             padding=False, truncation=False, return_attention_mask=True)

            features = inputs.input_features
            frames = features.shape[-1]
            if frames < WHISPER_MEL_FRAMES:
                features = torch.nn.functional.pad(features, (0, WHISPER_MEL_FRAMES - frames))
            else:
                features = features[..., :WHISPER_MEL_FRAMES]

            if self.model.device != device:
                self.model = self.model.to(device)
            encoded = self.model.encoder(features.to(device)).last_hidden_state

            valid_mel_frames = inputs.attention_mask.sum(dim=1)
            valid_frames = (valid_mel_frames + 1) // 2
            most = min(int(valid_frames.max().item()), encoded.shape[1])
            encoded = encoded[:, :most, :]
            valid = min(int(valid_frames[0].item()), most)
            if valid < most:
                encoded[0, valid:, :] = 0
            return encoded

    svc.WhisperEncoder = ListenerFromFolder

    # The pitch follower's file is loaded by path: importing its package would pull in the project's
    # separator, transcriber and note finder, which a conversion from sound alone never touches.
    spec = importlib.util.spec_from_file_location(
        "soulx_f0_extraction", os.path.join(source, "preprocess", "tools", "f0_extraction.py"))
    f0_extraction = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(f0_extraction)
    imported = time.perf_counter()

    config = OmegaConf.load(os.path.join(source, "soulxsinger", "config", "soulxsinger.yaml"))
    assert config.audio.sample_rate == MODEL_RATE and config.audio.hop_size == HOP
    model = svc.SoulXSingerSVC(config)
    checkpoint = torch.load(os.path.join(weights, "soulx-singer", "model-svc.pt"), map_location="cpu")
    model.load_state_dict(checkpoint["state_dict"], strict=True)
    del checkpoint
    model = model.float().eval().to(args.device)
    pitch_follower = f0_extraction.F0Extractor(
        os.path.join(weights, "rmvpe", "rmvpe.pt"), device=args.pitch_device,
        target_sr=MODEL_RATE, hop_size=HOP, verbose=False)
    loaded = time.perf_counter()
    now, most = footprint()
    opening = {
        "loaded": True, "device": args.device, "pitch_device": args.pitch_device,
        "torch": torch.__version__, "python": sys.version.split()[0],
        "import_seconds": round(imported - started, 2), "load_seconds": round(loaded - imported, 2),
        "parameters_million": round(sum(p.numel() for p in model.parameters()) / 1e6, 1),
        "listener_parameters_million": round(
            sum(p.numel() for p in model.whisper_encoder.model.parameters()) / 1e6, 1),
        "footprint_mb": megabytes(now), "most_footprint_mb": megabytes(most),
    }
    emit(opening, args.report)

    def read(path):
        sound, rate = soundfile.read(path, dtype="float32", always_2d=True)
        if rate != RATE:
            raise ValueError(f"{path} is at {rate} Hz, not 48,000")
        return np.ascontiguousarray(sound[:, 0])

    def pitch_of(path, length_at_model_rate):
        """The pitch curve of a file, one value every 20 ms, as many as the model has frames for it."""
        curve = pitch_follower.process(path).astype(np.float32)
        frames = -(-length_at_model_rate // HOP)
        return np.pad(curve, (0, max(0, frames - len(curve))))[:frames]

    references = {}
    for number, job in enumerate(jobs, start=1):
        line = {"job": number, "source": job["source"], "reference": job["reference"], "out": job["out"]}
        try:
            begin = time.perf_counter()
            seed = int(job.get("seed", 0))
            pitch = float(job.get("pitch", 0))
            steps = int(job.get("steps", config.infer.n_steps))
            cfg = float(job.get("cfg", config.infer.cfg))

            recording = read(job["source"])
            recording_low = soxr.resample(recording, RATE, MODEL_RATE, quality="VHQ").astype(np.float32)
            if job["reference"] not in references:
                voice = read(job["reference"])
                voice_low = soxr.resample(voice, RATE, MODEL_RATE, quality="VHQ").astype(np.float32)
                references[job["reference"]] = (voice_low, pitch_of(job["reference"], len(voice_low)))
            voice_low, voice_pitch = references[job["reference"]]
            recording_pitch = pitch_of(job["source"], len(recording_low))
            moved_pitch = recording_pitch * np.float32(2.0 ** (pitch / 12.0))  # 0, no pitch, stays 0
            prepared = time.perf_counter()

            joins = []
            if len(recording_low) >= 30 * MODEL_RATE:
                # The same call the model makes itself, to learn where it will join.
                _, parts = svc.SoulXSingerSVC.build_vocal_segments(
                    torch.from_numpy(moved_pitch)[None], f0_rate=MODEL_RATE // HOP, uv_frames_th=10,
                    min_duration_sec=15.0, max_duration_sec=30.0)
                joins = sorted({round(edge, 3) for part in parts for edge in part}
                               - {0.0, round(len(moved_pitch) * HOP / MODEL_RATE, 3)})
                line["parts"] = [[round(a, 3), round(b, 3)] for a, b in parts]

            torch.manual_seed(seed)
            with torch.no_grad():
                answer, _ = model.infer(
                    pt_wav=torch.from_numpy(voice_low)[None].to(args.device),
                    gt_wav=torch.from_numpy(recording_low)[None].to(args.device),
                    pt_f0=torch.from_numpy(voice_pitch)[None].to(args.device),
                    gt_f0=torch.from_numpy(moved_pitch)[None].to(args.device),
                    auto_shift=False, pitch_shift=0, n_steps=steps, cfg=cfg, use_fp16=False)
            answer = answer.squeeze().float().cpu().numpy()
            converted = time.perf_counter()

            if not np.all(np.isfinite(answer)):
                raise ValueError("the answer holds a value that is not a number")
            answer_length = len(answer)
            up = soxr.resample(answer, MODEL_RATE, RATE, quality="VHQ").astype(np.float32)
            out = np.zeros(len(recording), dtype=np.float32)
            out[:min(len(up), len(out))] = up[:len(out)]
            os.makedirs(os.path.dirname(os.path.abspath(job["out"])), exist_ok=True)
            soundfile.write(job["out"], out, RATE, subtype="PCM_24")
            done = time.perf_counter()

            seconds = len(recording) / RATE
            now, most = footprint()
            line.update({
                "ok": True, "seed": seed, "pitch": pitch, "steps": steps, "cfg": cfg,
                "source_seconds": round(seconds, 3), "reference_seconds": round(len(voice_low) / MODEL_RATE, 3),
                "source_samples": len(recording), "answer_samples_at_24k": answer_length,
                "source_samples_at_24k": len(recording_low), "upsampled_samples": len(up),
                "voiced_share": round(float(np.mean(recording_pitch > 0)), 3),
                "prepare_seconds": round(prepared - begin, 3),
                "convert_seconds": round(converted - prepared, 3),
                "write_seconds": round(done - converted, 3),
                "work_seconds": round(done - begin, 3),
                "work_per_second_of_voice": round((done - begin) / seconds, 3),
                "peak": round(float(np.max(np.abs(out))), 4), "joins": joins,
                "footprint_mb": megabytes(now), "most_footprint_mb": megabytes(most),
            })
            if args.device == "mps":
                line["mps_allocated_mb"] = megabytes(torch.mps.current_allocated_memory())
                line["mps_driver_mb"] = megabytes(torch.mps.driver_allocated_memory())
        except Exception as problem:  # one job that fails must not lose the others' numbers
            line.update({"ok": False, "error": f"{type(problem).__name__}: {problem}",
                         "where": traceback.format_exc(limit=-6).splitlines()[1:]})
        emit(line, args.report)


def emit(line, report):
    text = json.dumps(line, ensure_ascii=False)
    print(text, flush=True)
    if report:
        with open(report, "a", encoding="utf-8") as handle:
            handle.write(text + "\n")


if __name__ == "__main__":
    main()
