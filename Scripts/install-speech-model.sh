#!/bin/bash
# Downloads the speech models that write out the words of clips, and installs them on this Mac.
#
#   Scripts/install-speech-model.sh                 install both models, unless they are there
#   Scripts/install-speech-model.sh swedish         only the Swedish model (488 MB)
#   Scripts/install-speech-model.sh multilingual    only the model for other languages (574 MB)
#   Scripts/install-speech-model.sh ... --force     download and install again
#
# Settings > Recording > "Language of the words" picks the model: Swedish uses the Swedish one,
# "Any language" the multilingual one. Both are whisper.cpp models from Hugging Face:
#
#   swedish        KBLab's KB-Whisper Small (Apache 2.0), https://huggingface.co/KBLab/kb-whisper-small
#   multilingual   OpenAI's Whisper large-v3-turbo (MIT), quantised to q5_0 by the whisper.cpp
#                  project, https://huggingface.co/ggerganov/whisper.cpp
#
# Each file is downloaded into build/speech-model/ in this repository, its SHA-256 is checked,
# and only then is it moved here:
#
#   ~/Library/Application Support/Lockstep/Models/Speech/
#
# That is outside the repository on purpose: the models are not committed, and every git
# worktree finds the one copy. The names, sizes and checksums below are also in
# LockstepSpeechKit/Sources/LockstepSpeech/SpeechModelFile.swift; change both together.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/build/speech-model"
MODELS="$HOME/Library/Application Support/Lockstep/Models/Speech"

FORCE=0
CHOSEN=()
for argument in "$@"; do
    case "$argument" in
        --force) FORCE=1 ;;
        swedish | multilingual) CHOSEN+=("$argument") ;;
        *)
            echo "Unknown argument: $argument" >&2
            echo "Usage: Scripts/install-speech-model.sh [swedish | multilingual] [--force]" >&2
            exit 2
            ;;
    esac
done
if [[ ${#CHOSEN[@]} -eq 0 ]]; then
    CHOSEN=(swedish multilingual)
fi

# Sets URL, NAME, SIZE and SHA256 for one model. Each URL names a fixed commit of its repository,
# so the file behind it never changes.
describe() {
    case "$1" in
        swedish)
            URL="https://huggingface.co/KBLab/kb-whisper-small/resolve/066ef166dd25b4b27039517ca77af30c1c10688a/ggml-model.bin"
            NAME="kb-whisper-small.bin"
            SIZE=487601984
            SHA256="de6911330cbdc131362f7a955682b65c8a5a2394caba73e7ea821a9822efb8c6"
            ;;
        multilingual)
            URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin"
            NAME="whisper-large-v3-turbo-q5_0.bin"
            SIZE=574041195
            SHA256="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
            ;;
    esac
}

# Whether the file at $1 is the model: the right length, then the right SHA-256.
is_whole() {
    [[ -f "$1" ]] \
        && [[ "$(stat -f %z "$1")" == "$SIZE" ]] \
        && [[ "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" == "$SHA256" ]]
}

install_model() {
    describe "$1"
    local installed="$MODELS/$NAME"
    local downloaded="$WORK/$NAME"

    if [[ $FORCE -eq 0 ]] && is_whole "$installed"; then
        echo "The $1 speech model is already installed at $installed"
        return
    fi

    mkdir -p "$WORK"
    if [[ $FORCE -eq 1 ]] || ! is_whole "$downloaded"; then
        echo "Downloading the $1 speech model ($((SIZE / 1000000)) MB)..."
        rm -f "$downloaded"
        curl --fail --location --silent --show-error --output "$downloaded.partial" "$URL"
        mv "$downloaded.partial" "$downloaded"
        if ! is_whole "$downloaded"; then
            rm -f "$downloaded"
            echo "The downloaded $1 speech model is not the expected file. Nothing was installed." >&2
            exit 1
        fi
    fi

    # Lockstep never loads a file of the wrong length, and the file is moved beside its place
    # first and only then renamed into it, so Lockstep never meets a half-moved model.
    mkdir -p "$MODELS"
    mv "$downloaded" "$installed.partial"
    mv "$installed.partial" "$installed"
    echo "Installed the $1 speech model at $installed"
}

for model in "${CHOSEN[@]}"; do
    install_model "$model"
done
