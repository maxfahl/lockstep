# Makes onsetref.f32 and onsetref-curve.f32: one second of test sound and librosa's own onset curve
# for it, so OnsetStrengthTests can prove the Swift version gives the same numbers.
#
# Run in this folder:
#   uv run --python 3.11 --with numpy==2.2.6 --with librosa==0.10.2 python make-onset-reference.py
import numpy as np, librosa

rng = np.random.default_rng(3)
sr = 48000
n = sr
y = 0.002 * rng.standard_normal(n)
# Six thumps with a noisy attack, at positions that are not multiples of the hop, over quiet hiss.
for k in range(6):
    p = 5000 + k * 7011
    decay = np.exp(-np.arange(4000) / 600.0)
    y[p:p + 4000] += 0.6 * decay * np.sin(2 * np.pi * (60 + 30 * k) * np.arange(4000) / sr)
    y[p:p + 4000] += 0.2 * decay * rng.standard_normal(4000)
y[:3000] = 0  # true silence first, to test the quietest level that counts
y = y.astype(np.float32)
curve = librosa.onset.onset_strength(y=y, sr=sr, hop_length=32, n_fft=1024)
y.astype("<f4").tofile("onsetref.f32")
curve.astype("<f4").tofile("onsetref-curve.f32")
print(librosa.__version__, np.__version__, len(curve), curve.max())
