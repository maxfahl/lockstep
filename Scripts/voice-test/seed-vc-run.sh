#!/bin/bash
# Runs seed-vc-render.py with the engine's own Python and the environment of seed-vc-env.sh, so that a
# conversion reads nothing from outside the engine folder, asks the internet for nothing and writes no
# cache outside it. Every argument goes on to the render script, for example:
#
#   Scripts/voice-test/seed-vc-run.sh --jobs jobs.json --report report.json [--listener half] [--model half]
#
# The engine folder is build/voice-test/seed-vc unless SEED_VC_ENGINE names another.
# `-I` keeps Python from importing anything from the current folder or the user's site folder: the
# engine's source is reached only through the path the render script adds itself.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/seed-vc-env.sh"
export TQDM_DISABLE=1   # the model prints a bar for every stretch otherwise
exec "$SEED_VC_ENGINE/venv/bin/python" -I "$HERE/seed-vc-render.py" --engine "$SEED_VC_ENGINE" "$@"
