#!/usr/bin/env python3
# The render script of phase 37's test of Seed-VC: one process that loads the models once and converts
# a list of jobs. The helper the app talks to (lockstep_voice.py, a later task) is written from this.
#
# LICENCE. This file imports Seed-VC (https://github.com/Plachtaa/seed-vc, GPL-3.0), and its `convert`
# follows `main` of Seed-VC's inference.py. It is therefore under the GNU General Public License,
# version 3. It is a workshop tool, run as a program of its own, and no part of the Lockstep app.
#
#   Scripts/voice-test/seed-vc-run.sh --jobs jobs.json --report report.json [--listener half] [--model half]
#
# (seed-vc-run.sh sets the environment and starts this with the engine's own Python.)
#
# jobs.json is a list. Each job:
#   "source"            the line, WAV, 48,000 Hz, mono. Its words, timing and melody are kept
#   "reference"         the voice whose colour is taken, WAV, 48,000 Hz, mono
#   "output"            where the answer is written: WAV, 48,000 Hz, mono, 24-bit
#   "pitch"             semitones the model's own pitch control moves the pitch by (default 0)
#   "steps"             steps of the model for each stretch (default 30, as inference.py)
#   "seed"              set before the job (default 1)
#   "referenceSeconds"  how much of the reference is listened to, from its start (default and most: 25)
#   "fill"              false keeps the answer as short as the model gave it (default: silence is added
#                       at the end up to the source's length, so that every tool can compare the two)
#
# What differs from Seed-VC's own inference.py, and why:
# - Every file is loaded by its own path from seed-vc-weights.json. hf_utils.py is not used: it fetches
#   into ./checkpoints whatever the environment says, and Whisper and BigVGAN are loaded by name there.
# - Checkpoints are read with `weights_only=True`, so a checkpoint cannot run code when it is loaded.
# - The precision of each part is set here. inference.py loads Whisper in half precision whatever its
#   flag says. Here the listener (Whisper) and the model (the diffusion transformer) each get what the
#   command line says, full by default. RMVPE, CAM++ and BigVGAN are always full, as in inference.py.
# - A seed is set before each job. inference.py sets none.
# - RMVPE's pitch, which it gives in float64, is made float32 before it goes to MPS, which has no float64
#   (inference.py fails there with "Cannot convert a MPS Tensor to float64 dtype").
# - The pitch may be moved by half semitones (inference.py takes whole ones only, by its argument's type).
# - Files are 48,000 Hz outside and 44,100 Hz inside, resampled with soxr at its highest quality.
# - Two packages that Seed-VC imports but a conversion with this model never uses are replaced by
#   empty stand-ins, so they need not be installed: descript-audio-codec (its VectorQuantize is only
#   built when the model's configuration says `vector_quantize: true`, and it says false) and matplotlib
#   (BigVGAN's utils import it for plots).
# - The report says where the stretches of a long source were joined, so the timing can be measured there.

import argparse
import ctypes
import json
import os
import sys
import time
import traceback
import types

SR = 44100            # the model's own rate
HOP = 512             # samples of a frame of the model at that rate (11.6 ms)
OUT_SR = 48000        # Lockstep's rate
WINDOW_SECONDS = 30   # the reference and a stretch of the source share this window
OVERLAP_FRAMES = 16   # the crossfade between two stretches (186 ms)
CFG_RATE = 0.7        # inference.py's default


def footprint():
    """What this process holds, in bytes: now, and the most it ever held. The graphics processor's
    memory is part of both on Apple Silicon (it is the same memory)."""
    buf = (ctypes.c_uint64 * 40)()
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    if libc.proc_pid_rusage(os.getpid(), 4, ctypes.byref(buf)) != 0:   # RUSAGE_INFO_V4
        return 0, 0
    fields = buf[2:]   # after the 16 bytes of the uuid
    return int(fields[7]), int(fields[28])   # ri_phys_footprint, ri_lifetime_max_phys_footprint


def stand_in_for_unused_packages():
    class VectorQuantize:
        def __init__(self, *args, **kwargs):
            raise RuntimeError("descript-audio-codec is not installed: this model must not need it")
    dac, dac_nn, quantize = types.ModuleType("dac"), types.ModuleType("dac.nn"), types.ModuleType("dac.nn.quantize")
    quantize.VectorQuantize = VectorQuantize
    dac.nn, dac_nn.quantize = dac_nn, quantize
    sys.modules.update({"dac": dac, "dac.nn": dac_nn, "dac.nn.quantize": quantize})
    matplotlib, pylab = types.ModuleType("matplotlib"), types.ModuleType("matplotlib.pylab")
    matplotlib.use = lambda *args, **kwargs: None
    matplotlib.pylab = pylab
    sys.modules.update({"matplotlib": matplotlib, "matplotlib.pylab": pylab})


class Engine:
    def __init__(self, engine, weights_list, device, listener_half, model_half):
        import torch
        import yaml
        self.torch = torch
        self.device = torch.device(device)
        self.model_half = model_half

        weights = {f["path"]: f for f in json.load(open(weights_list))["files"]}
        def path(name):
            assert name in weights, name
            return os.path.join(engine, "weights", name)

        stand_in_for_unused_packages()
        sys.path.insert(0, os.path.join(engine, "source"))
        load = torch.load
        torch.load = lambda *args, **kwargs: load(*args, **{**kwargs, "weights_only": True})

        from modules.commons import build_model, load_checkpoint, recursive_munch
        from modules.rmvpe import RMVPE
        from modules.campplus.DTDNN import CAMPPlus
        from modules.bigvgan import bigvgan
        from modules.audio import mel_spectrogram
        from transformers import WhisperFeatureExtractor, WhisperModel

        # The model, with its length regulator.
        config = yaml.safe_load(open(path("seed-vc/config_dit_mel_seed_uvit_whisper_base_f0_44k.yml")))
        spect = config["preprocess_params"]["spect_params"]
        assert config["preprocess_params"]["sr"] == SR and spect["hop_length"] == HOP
        params = recursive_munch(config["model_params"])
        params.dit_type = "DiT"
        self.model = build_model(params, stage="DiT")
        self.model, _, _, _ = load_checkpoint(
            self.model, None, path("seed-vc/DiT_seed_v2_uvit_whisper_base_f0_44k_bigvgan_pruned_ft_ema_v2.pth"),
            load_only_params=True, ignore_modules=[], is_distributed=False)
        for key in self.model:
            self.model[key].eval()
            self.model[key].to(self.device)
        self.model.cfm.estimator.setup_caches(max_batch_size=1, max_seq_length=8192)

        # RMVPE follows the pitch. CAM++ hears who speaks.
        self.f0 = RMVPE(path("rmvpe/rmvpe.pt"), is_half=False, device=self.device).infer_from_audio
        self.campplus = CAMPPlus(feat_dim=80, embedding_size=192)
        self.campplus.load_state_dict(torch.load(path("campplus/campplus_cn_common.bin"), map_location="cpu"))
        self.campplus.eval().to(self.device)

        # BigVGAN makes the sound. Loaded as its own `_from_pretrained` does, from the two files.
        h = bigvgan.AttrDict(json.load(open(path("bigvgan_v2_44khz_128band_512x/config.json"))))
        vocoder = bigvgan.BigVGAN(h, use_cuda_kernel=False)
        state = torch.load(path("bigvgan_v2_44khz_128band_512x/bigvgan_generator.pt"), map_location="cpu")
        try:
            vocoder.load_state_dict(state["generator"])
            vocoder.remove_weight_norm()
        except RuntimeError:
            vocoder.remove_weight_norm()
            vocoder.load_state_dict(state["generator"])
        self.vocoder = vocoder.eval().to(self.device)

        # Whisper is the listener. Only its encoder is used.
        whisper_folder = os.path.dirname(path("whisper-small/model.safetensors"))
        self.whisper = WhisperModel.from_pretrained(
            whisper_folder, torch_dtype=torch.float16 if listener_half else torch.float32,
            local_files_only=True).to(self.device)
        del self.whisper.decoder
        self.whisper_features = WhisperFeatureExtractor.from_pretrained(whisper_folder, local_files_only=True)

        self.mel = lambda wave: mel_spectrogram(
            wave, n_fft=spect["n_fft"], win_size=spect["win_length"], hop_size=HOP, num_mels=spect["n_mels"],
            sampling_rate=SR, fmin=spect.get("fmin", 0), fmax=None, center=False)
        torch.load = load

    def listen(self, wave_16k):
        """What is said, 50 times a second, as `semantic_fn` of inference.py."""
        torch = self.torch
        inputs = self.whisper_features([wave_16k.squeeze(0).cpu().numpy()], return_tensors="pt",
                                       return_attention_mask=True, sampling_rate=16000)
        features = self.whisper._mask_input_features(
            inputs.input_features, attention_mask=inputs.attention_mask).to(self.device)
        out = self.whisper.encoder(features.to(self.whisper.encoder.dtype), head_mask=None,
                                   output_attentions=False, output_hidden_states=False, return_dict=True)
        return out.last_hidden_state.to(torch.float32)[:, :wave_16k.size(-1) // 320 + 1]

    def listen_long(self, wave_16k):
        """Whisper hears 30 seconds at a time. A longer source is heard in pieces that share 5 seconds."""
        torch = self.torch
        if wave_16k.size(-1) <= 16000 * 30:
            return self.listen(wave_16k)
        share, pieces, buffer, at = 5, [], None, 0
        while at < wave_16k.size(-1):
            if buffer is None:
                chunk = wave_16k[:, at:at + 16000 * 30]
            else:
                chunk = torch.cat([buffer, wave_16k[:, at:at + 16000 * (30 - share)]], dim=-1)
            heard = self.listen(chunk)
            pieces.append(heard if at == 0 else heard[:, 50 * share:])
            buffer = chunk[:, -16000 * share:]
            at += 30 * 16000 if at == 0 else chunk.size(-1) - 16000 * share
        return torch.cat(pieces, dim=1)

    def convert(self, source, reference, pitch, steps, seed, progress=lambda fraction: None):
        """`source` and `reference` are mono float32 arrays at 44,100 Hz. Gives the answer at 44,100 Hz
        and the places, in seconds of the source, where two stretches were joined."""
        import numpy as np
        import random
        import torchaudio
        torch = self.torch
        device = self.device
        random.seed(seed)
        np.random.seed(seed)
        torch.manual_seed(seed)

        source = torch.tensor(source).unsqueeze(0).float().to(device)
        reference = torch.tensor(reference).unsqueeze(0).float().to(device)
        source_16k = torchaudio.functional.resample(source, SR, 16000)
        reference_16k = torchaudio.functional.resample(reference, SR, 16000)
        said = self.listen_long(source_16k)
        said_reference = self.listen(reference_16k)

        frames = torch.LongTensor([self.mel(source).size(2)]).to(device)
        prompt_mel = self.mel(reference)
        prompt_frames = torch.LongTensor([prompt_mel.size(2)]).to(device)

        fbank = torchaudio.compliance.kaldi.fbank(reference_16k, num_mel_bins=80, dither=0, sample_frequency=16000)
        style = self.campplus((fbank - fbank.mean(dim=0, keepdim=True)).unsqueeze(0))

        # The pitch of the source is handed to the model as it is, moved by `pitch` semitones where there
        # is voice. The option that brings it to the reference's level (`auto_f0_adjust`) stays off.
        # RMVPE answers in float64, which MPS cannot hold: it is brought to float32 on the processor first.
        f0_reference = torch.from_numpy(self.f0(reference_16k[0], thred=0.03).astype(np.float32)).to(device)[None]
        f0_source = torch.from_numpy(self.f0(source_16k[0], thred=0.03).astype(np.float32)).to(device)[None]
        f0_moved = torch.exp(torch.log(f0_source + 1e-5))
        if pitch != 0:
            f0_moved[f0_source > 1] = f0_moved[f0_source > 1] * 2 ** (pitch / 12)

        regulate = self.model.length_regulator
        condition = regulate(said, ylens=frames, n_quantizers=3, f0=f0_moved)[0]
        prompt_condition = regulate(said_reference, ylens=prompt_frames, n_quantizers=3, f0=f0_reference)[0]

        # The source is worked through in stretches: the reference and a stretch share the window.
        window = SR // HOP * WINDOW_SECONDS - prompt_mel.size(2)
        overlap = OVERLAP_FRAMES * HOP
        done, chunks, joins, previous = 0, [], [], None
        while done < condition.size(1):
            stretch = condition[:, done:done + window]
            last = done + window >= condition.size(1)
            both = torch.cat([prompt_condition, stretch], dim=1)
            with torch.autocast(device_type=device.type, dtype=torch.float16, enabled=self.model_half):
                made = self.model.cfm.inference(
                    both, torch.LongTensor([both.size(1)]).to(device), prompt_mel, style, None, steps,
                    inference_cfg_rate=CFG_RATE)
            made = made[:, :, prompt_mel.size(-1):]
            wave = self.vocoder(made.float()).squeeze()[None, :]
            if previous is not None:
                joins.append(done * HOP / SR)
            body = wave[0] if last else wave[0, :-overlap]
            body = body.cpu().numpy()
            if previous is not None:
                fade_out = np.cos(np.linspace(0, np.pi / 2, overlap)) ** 2
                fade_in = np.cos(np.linspace(np.pi / 2, 0, overlap)) ** 2
                n = min(len(body), overlap)
                body[:n] = body[:n] * fade_in[:n] + (previous * fade_out)[:n]
            chunks.append(body)
            if last:
                break
            previous = wave[0, -overlap:].cpu().numpy()
            done += made.size(2) - OVERLAP_FRAMES
            progress(min(1.0, done / condition.size(1)))
        progress(1.0)
        return np.concatenate(chunks).astype(np.float32), joins


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", required=True)
    parser.add_argument("--jobs", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--weights", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "seed-vc-weights.json"))
    parser.add_argument("--device", default="mps", choices=["mps", "cpu"])
    parser.add_argument("--listener", default="full", choices=["full", "half"])
    parser.add_argument("--model", default="full", choices=["full", "half"])
    parser.add_argument("--empty-cache", action="store_true",
                        help="hand the graphics processor's unused memory back after each job")
    args = parser.parse_args()

    started = time.time()
    import numpy as np
    import soundfile
    import soxr
    import torch
    torch.set_grad_enabled(False)
    engine = Engine(os.path.abspath(args.engine), args.weights, args.device, args.listener == "half", args.model == "half")
    load_seconds = time.time() - started
    now, most = footprint()
    report = {
        "python": sys.version.split()[0], "torch": torch.__version__, "device": args.device,
        "listener": args.listener, "model": args.model, "loadSeconds": round(load_seconds, 2),
        "afterLoad": {"footprintMB": round(now / 2**20), "mostMB": round(most / 2**20),
                      "graphicsMB": round(torch.mps.driver_allocated_memory() / 2**20) if args.device == "mps" else 0},
        "jobs": [],
    }
    print(f"loaded in {load_seconds:.1f} s on {args.device}, holding {now / 2**20:.0f} MB", file=sys.stderr, flush=True)

    def read(path):
        wave, rate = soundfile.read(path, dtype="float32", always_2d=True)
        assert rate == OUT_SR, f"{path} is not at 48,000 Hz"
        assert wave.shape[1] == 1, f"{path} is not mono"
        return wave[:, 0]

    for number, job in enumerate(json.load(open(args.jobs)), 1):
        source = read(job["source"])
        reference = read(job["reference"])
        reference_seconds = min(25.0, float(job.get("referenceSeconds", 25)))
        entry = {"output": job["output"], "sourceSamples": len(source), "sourceSeconds": round(len(source) / OUT_SR, 3),
                 "pitch": job.get("pitch", 0), "steps": job.get("steps", 30), "seed": job.get("seed", 1)}
        began = time.time()
        try:
            inside = soxr.resample(source, OUT_SR, SR, quality="VHQ")
            reference_inside = soxr.resample(reference, OUT_SR, SR, quality="VHQ")[:int(SR * reference_seconds)]
            entry["referenceSeconds"] = round(len(reference_inside) / SR, 3)
            with torch.no_grad():
                answer, joins = engine.convert(inside, reference_inside, float(entry["pitch"]), int(entry["steps"]),
                                               int(entry["seed"]))
            out = soxr.resample(answer, SR, OUT_SR, quality="VHQ").astype(np.float32)
            entry["rawSamples"] = len(out)
            entry["shortBy"] = len(source) - len(out)
            if job.get("fill", True) and len(out) < len(source):
                out = np.concatenate([out, np.zeros(len(source) - len(out), dtype=np.float32)])
            assert np.isfinite(out).all(), "the answer holds a value that is not a number"
            os.makedirs(os.path.dirname(os.path.abspath(job["output"])), exist_ok=True)
            # 24-bit, as every file Lockstep writes. A float file without a length chunk is read some
            # hundred samples short by Lockstep's own reader. A peak above full scale is noted, not hidden.
            entry["peak"] = round(float(np.abs(out).max()), 4)
            entry["clipped"] = bool(entry["peak"] > 1.0)
            soundfile.write(job["output"], np.clip(out, -1.0, 1.0), OUT_SR, subtype="PCM_24")
            entry["samples"] = len(out)
            entry["joins"] = [round(j, 4) for j in joins]
        except Exception as error:   # the next job still runs: one bad file must not end the run
            entry["failed"] = f"{type(error).__name__}: {error}"
            traceback.print_exc(file=sys.stderr)
        if args.device == "mps":
            torch.mps.synchronize()
        entry["workSeconds"] = round(time.time() - began, 3)
        entry["secondsPerSecond"] = round(entry["workSeconds"] / max(entry["sourceSeconds"], 1e-9), 3)
        if args.empty_cache and args.device == "mps":
            torch.mps.empty_cache()
        now, most = footprint()
        entry["footprintMB"], entry["mostMB"] = round(now / 2**20), round(most / 2**20)
        if args.device == "mps":
            entry["graphicsMB"] = round(torch.mps.driver_allocated_memory() / 2**20)
            entry["graphicsInUseMB"] = round(torch.mps.current_allocated_memory() / 2**20)
        report["jobs"].append(entry)
        json.dump(report, open(args.report, "w"), indent=1)
        print(f"job {number}: {entry.get('failed') or 'done'}, {entry['sourceSeconds']} s of voice in "
              f"{entry['workSeconds']} s, holding {entry['footprintMB']} MB: {job['output']}", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
