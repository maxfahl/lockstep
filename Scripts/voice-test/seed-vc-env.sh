# Sourced by the Seed-VC scripts of phase 37 (seed-vc-setup.sh, seed-vc-run.sh). Not run by itself.
#
# It names the engine folder and points every cache and temporary folder of the tools into it, so that
# nothing is written outside. The folder is build/voice-test/seed-vc of this checkout unless
# SEED_VC_ENGINE names another.
#
#   python/   Python, uv's own build          venv/     the packages
#   source/   Seed-VC at the pinned commit    weights/  every model file, each under a path of its own
#   cache/, tmp/   what the tools keep        dl/       the source archive as it was fetched

SEED_VC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SEED_VC_ENGINE="${SEED_VC_ENGINE:-$SEED_VC_ROOT/build/voice-test/seed-vc}"
mkdir -p "$SEED_VC_ENGINE"/{python,source,weights,cache,tmp,dl}

export UV_CACHE_DIR="$SEED_VC_ENGINE/cache/uv"
export UV_PYTHON_INSTALL_DIR="$SEED_VC_ENGINE/python"
export UV_NO_CONFIG=1
export HF_HOME="$SEED_VC_ENGINE/cache/huggingface"
export TORCH_HOME="$SEED_VC_ENGINE/cache/torch"
export XDG_CACHE_HOME="$SEED_VC_ENGINE/cache/xdg"
export NUMBA_CACHE_DIR="$SEED_VC_ENGINE/cache/numba"
export MPLCONFIGDIR="$SEED_VC_ENGINE/cache/matplotlib"
export TMPDIR="$SEED_VC_ENGINE/tmp"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1

# The libraries never ask the internet for anything: every file is loaded by its own path.
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
