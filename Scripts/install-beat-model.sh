#!/bin/bash
# Makes the beat-finding model and installs it on this Mac.
#
#   Scripts/install-beat-model.sh            install it, unless it is already there
#   Scripts/install-beat-model.sh --force    make and install it again
#
# The model is "Beat This!" (https://github.com/CPJKU/beat_this, MIT licence), checkpoint
# "final0". This script downloads the checkpoint (81 MB), checks its checksum, converts it
# to Core ML with Scripts/convert-beat-model.py, and puts the result here:
#
#   ~/Library/Application Support/Lockstep/Models/BeatThis.mlpackage
#
# That is outside the repository on purpose: the model is not committed, and every git
# worktree finds the one copy. Needs `uv` and a network connection. Python packages go
# into uv's own cache and nothing is installed on the system.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/build/beat-model"
MODELS="$HOME/Library/Application Support/Lockstep/Models"
MODEL="$MODELS/BeatThis.mlpackage"
COMPILED="$MODELS/BeatThis.mlmodelc"

# The same two values are in Scripts/make-beat-reference.py.
CHECKPOINT_URL="https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt"
CHECKPOINT_SHA256="8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331"
CHECKPOINT="$WORK/final0.ckpt"

if [[ "${1:-}" != "--force" && -d "$MODEL" ]]; then
    echo "The beat model is already installed at $MODEL"
    echo "Run with --force to make it again."
    exit 0
fi

checksum_matches() {
    [[ -f "$CHECKPOINT" ]] && [[ "$(shasum -a 256 "$CHECKPOINT" | cut -d ' ' -f 1)" == "$CHECKPOINT_SHA256" ]]
}

mkdir -p "$WORK"
if ! checksum_matches; then
    echo "Downloading the checkpoint (81 MB)..."
    curl --fail --location --silent --show-error --output "$CHECKPOINT" "$CHECKPOINT_URL"
    if ! checksum_matches; then
        rm -f "$CHECKPOINT"
        echo "The downloaded checkpoint does not have the expected checksum. Nothing was installed." >&2
        exit 1
    fi
fi

# A conversion is not the same byte for byte each time, so there is no checksum for its
# result. The conversion script compares the result with the original model instead and
# saves nothing if they differ.
FRESH="$WORK/BeatThis.mlpackage"
uv run --script "$ROOT/Scripts/convert-beat-model.py" --checkpoint "$CHECKPOINT" --output "$FRESH"

mkdir -p "$MODELS"
# The compiled copy Lockstep keeps next to the model belongs to the old model, so it goes too.
rm -rf "$MODEL" "$COMPILED"
mv "$FRESH" "$MODEL"
echo "Installed the beat model at $MODEL"
