#!/bin/bash
# Sets Seed-VC up for the test of phase 37, outside the app. The installer of a later task is written
# from this.
#
#   Scripts/voice-test/seed-vc-setup.sh                 into build/voice-test/seed-vc (ignored by git)
#   Scripts/voice-test/seed-vc-setup.sh --comparison    also the speech model without pitch (440 MB)
#   SEED_VC_ENGINE=<folder> Scripts/voice-test/seed-vc-setup.sh
#
# Its steps: Python 3.10 through the `uv` on this Mac, the packages of seed-vc-requirements.lock (or of
# seed-vc-requirements.txt while there is no lock yet), Seed-VC's source as an archive of the pinned
# commit, and the model files of seed-vc-weights.json, each at its page's pinned revision.
#
# It can be run again. A file that is there with the right size and checksum is skipped, and a download
# that stopped goes on where it was (`curl -C -`), tried again up to twenty times. Everything it fetches
# comes from astral's Python builds on github.com, pypi.org, codeload.github.com and huggingface.co, about
# 2.7 GB. Nothing is sent but the requests themselves. Every cache and temporary folder is inside the
# engine folder (seed-vc-env.sh).
#
# What is downloaded is data from outside. Nothing of Seed-VC's source is run here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/seed-vc-env.sh"
E="$SEED_VC_ENGINE"

PYTHON_BUILD="cpython-3.10.20-macos-aarch64-none"
COMMIT="51383efd921027683c89e5348211d93ff12ac2a8"
ARCHIVE_SHA="501f89707e61ed346f05e59049c413b881043ecad823049ffc14917777016a7d"
USE="conversion"
[ "${1:-}" = "--comparison" ] && USE="conversion comparison"

say() { printf '%s\n' "$*" >&2; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Fetches <url> to <path>, going on where an earlier try stopped, and checks the size and the checksum.
fetch() {
    local url="$1" path="$2" size="$3" sum="$4"
    if [ -f "$path" ] && [ "$(stat -f %z "$path")" = "$size" ] && { [ -z "$sum" ] || [ "$(sha "$path")" = "$sum" ]; }; then
        say "  there already: ${path#$E/}"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    local try
    for try in $(seq 1 20); do
        if curl -sS -L --fail -C - --connect-timeout 30 --speed-limit 1000 --speed-time 60 \
            -A "curl" -o "$path.partial" "$url"; then
            break
        fi
        say "  the download stopped (try $try of 20), going on in 5 s: ${path#$E/}"
        sleep 5
    done
    local got; got="$(stat -f %z "$path.partial")"
    if [ "$got" != "$size" ]; then
        say "  WRONG SIZE: ${path#$E/} has $got bytes, expected $size. Run the script again."
        return 1
    fi
    if [ -n "$sum" ] && [ "$(sha "$path.partial")" != "$sum" ]; then
        say "  WRONG CHECKSUM: ${path#$E/}. The partial file is removed. Run the script again."
        rm -f "$path.partial"
        return 1
    fi
    mv "$path.partial" "$path"
    say "  fetched: ${path#$E/} ($size bytes)"
}

say "step 1 of 4: Python ($PYTHON_BUILD)"
# --no-bin: uv otherwise also puts a python3.10 into ~/.local/bin, outside the engine folder.
uv python install --no-bin "$PYTHON_BUILD" >&2
PY="$(uv python find "$PYTHON_BUILD")"

say "step 2 of 4: the packages"
[ -x "$E/venv/bin/python" ] || uv venv --python "$PY" "$E/venv" >&2
if [ -f "$HERE/seed-vc-requirements.lock" ]; then
    uv pip sync --python "$E/venv/bin/python" --require-hashes "$HERE/seed-vc-requirements.lock" >&2
else
    uv pip install --python "$E/venv/bin/python" -r "$HERE/seed-vc-requirements.txt" >&2
fi

say "step 3 of 4: Seed-VC's source at $COMMIT"
if [ ! -f "$E/source/inference.py" ]; then
    ARCHIVE="$E/dl/seed-vc-${COMMIT:0:8}.tar.gz"
    for try in $(seq 1 20); do
        curl -sS -L --fail --connect-timeout 30 -A "curl" -o "$ARCHIVE" \
            "https://codeload.github.com/Plachtaa/seed-vc/tar.gz/$COMMIT" && break
        sleep 5
    done
    # GitHub makes the archive when it is asked for, so its bytes are not promised to stay the same.
    # A checksum that differs is said, and the folder inside must still be named after the commit.
    [ "$(sha "$ARCHIVE")" = "$ARCHIVE_SHA" ] || say "  note: the archive's checksum differs from the one of 16 November 2026"
    tar -tzf "$ARCHIVE" | head -1 | grep -q "^seed-vc-$COMMIT/" || { say "  the archive is not of that commit"; exit 1; }
    tar -xzf "$ARCHIVE" -C "$E/source" --strip-components 1
fi

say "step 4 of 4: the model files"
/usr/bin/python3 - "$HERE/seed-vc-weights.json" $USE <<'EOF' > "$E/tmp/weights.list"
import json, sys
uses = sys.argv[2:]
for f in json.load(open(sys.argv[1]))["files"]:
    if f["use"] in uses:
        url = "https://huggingface.co/%s/resolve/%s/%s" % (f["page"], f["revision"], f["file"])
        print("\t".join([url, f["path"], str(f["size"]), f["sha256"] or "-"]))
EOF
FAILED=0
while IFS=$'\t' read -r url path size sum; do
    [ "$sum" = "-" ] && sum=""
    fetch "$url" "$E/weights/$path" "$size" "$sum" || FAILED=1
done < "$E/tmp/weights.list"
rm -f "$E/tmp/weights.list"
[ "$FAILED" = 0 ] || { say "Some model files are missing. Run the script again."; exit 1; }

say "Seed-VC is set up in $E"
