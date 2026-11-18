#!/bin/bash
# Makes the folder the SoulX-Singer-SVC try of phase 37 runs in, with nothing taken from outside it:
#
#   Scripts/voice-test/soulx-setup.sh [<folder, default build/voice-test/soulx>]
#
# and then converts with
#
#   <folder>/venv/bin/python -I Scripts/voice-test/soulx-render.py --root <folder> --jobs jobs.json
#
# What it puts there, each step skipped when it is already done, so nothing is fetched twice:
#
#   python/   CPython 3.10.20, installed by uv (the project asks for 3.10)
#   venv/     the packages a conversion from sound alone needs, at the versions the try ran with
#             (753 MB). The project's requirements.txt also lists its separator, transcriber, note
#             finder, web page and tracker (nemo, funasr, gradio, wandb and more), which a conversion
#             never imports. PyTorch is 2.5.1, not the project's 2.2.0: 2.5.1 runs the model on the
#             graphics processor, with one step moved to the processor in soulx-render.py
#   source/   github.com/Soul-AILab/SoulX-Singer at commit 81aeb3a (31 MB), Apache-2.0
#   weights/  2.9 GB, each file at a pinned revision and checked against its SHA-256:
#             soulx-singer/model-svc.pt   2,793,965,154 bytes  Soul-AILab/SoulX-Singer, Apache-2.0
#             soulx-singer/config.yaml    the model card's own (the source's copy is the one read)
#             rmvpe/rmvpe.pt                181,184,272 bytes  Soul-AILab/SoulX-Singer-Preprocess,
#                                                              Apache-2.0 (RMVPE, the pitch follower)
#             whisper-base/model.safetensors 290,403,936 bytes openai/whisper-base, Apache-2.0 on its
#                                                              card (MIT at OpenAI's own repository),
#                                                              with its config.json and
#                                                              preprocessor_config.json
#
# uv's cache is build/uv-cache, as the rules of phase 37 ask. Nothing is installed outside the folder
# and the checkout, and no file of a model is run as code: soulx-render.py reads checkpoints as
# numbers only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOME_FOLDER="${1:-$ROOT/build/voice-test/soulx}"
mkdir -p "$HOME_FOLDER"
HOME_FOLDER="$(cd "$HOME_FOLDER" && pwd)"
export UV_CACHE_DIR="$ROOT/build/uv-cache"
export UV_PYTHON_INSTALL_DIR="$HOME_FOLDER/python"

SOURCE_COMMIT=81aeb3ae772c70093c3de74dc23c92d983801ae4
SINGER_REVISION=40493ad90286056c7a9095035164434a79daa8c9
PREPROCESS_REVISION=83dc50289d22a81b1e9998f5b9e111aef7c1fdcd
WHISPER_REVISION=e37978b90ca9030d5170a5c07aadb050351a65bb

# Python and the packages.
if [[ ! -x "$HOME_FOLDER/venv/bin/python" ]]; then
    uv python install 3.10.20
    uv venv --python 3.10.20 "$HOME_FOLDER/venv"
fi
uv pip install --python "$HOME_FOLDER/venv/bin/python" \
    torch==2.5.1 torchaudio==2.5.1 numpy==1.26.4 transformers==4.41.2 tokenizers==0.19.1 \
    huggingface_hub==0.36.2 accelerate==1.11.0 librosa==0.11.0 scipy==1.15.3 omegaconf==2.3.0 \
    soundfile==0.13.1 soxr==1.1.0 tqdm==4.67.1

# The model's source.
if [[ ! -d "$HOME_FOLDER/source/.git" ]]; then
    git clone --quiet https://github.com/Soul-AILab/SoulX-Singer.git "$HOME_FOLDER/source"
fi
git -C "$HOME_FOLDER/source" checkout --quiet "$SOURCE_COMMIT"

# fetch <repository> <revision> <path there> <path here> <sha256>
fetch() {
    local target="$HOME_FOLDER/weights/$4"
    if [[ -f "$target" ]] && shasum -a 256 "$target" | grep -q "^$5 "; then
        return
    fi
    mkdir -p "$(dirname "$target")"
    curl --fail --location --silent --show-error -o "$target.part" \
        "https://huggingface.co/$1/resolve/$2/$3"
    if ! shasum -a 256 "$target.part" | grep -q "^$5 "; then
        echo "$4 is not the file that was tried (SHA-256 differs)" >&2
        rm -f "$target.part"
        exit 1
    fi
    mv "$target.part" "$target"
}

fetch Soul-AILab/SoulX-Singer "$SINGER_REVISION" model-svc.pt soulx-singer/model-svc.pt \
    38e72d9e15be6eef3cc937daaf81421a7b5b546816786530bb9aa346cee5d43c
fetch Soul-AILab/SoulX-Singer "$SINGER_REVISION" config.yaml soulx-singer/config.yaml \
    d164c978dde6f57e1075bc21ef5f9b7b27895267f35b735cebe863418492be38
fetch Soul-AILab/SoulX-Singer-Preprocess "$PREPROCESS_REVISION" rmvpe/rmvpe.pt rmvpe/rmvpe.pt \
    6d62215f4306e3ca278246188607209f09af3dc77ed4232efdd069798c4ec193
fetch openai/whisper-base "$WHISPER_REVISION" model.safetensors whisper-base/model.safetensors \
    07cadb9f25677c8d50df603e66a98fbd842cce45047139baeb16e6219a1e807b
fetch openai/whisper-base "$WHISPER_REVISION" config.json whisper-base/config.json \
    a153c53883a6799b6f056b4a8d1a515c9926d03994682ba88a7616618d7da0c1
fetch openai/whisper-base "$WHISPER_REVISION" preprocessor_config.json whisper-base/preprocessor_config.json \
    9b5cd03a36fbb8a627c64d98a5b5b126ead95a77720723944487311f0110b666

echo "SoulX-Singer-SVC is ready in $HOME_FOLDER"
