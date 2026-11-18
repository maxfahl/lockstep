#!/bin/bash
# Converts one line with SoulX-Singer-SVC, for the commutation check, which makes a voice by a command
# with {in} and {out} in it:
#
#   Scripts/voice-test/soulx-one.sh <in.wav> <out.wav> <reference.wav> [<pitch in semitones>]
#
#   Scripts/measure-commute.sh --make \
#       'Scripts/voice-test/soulx-one.sh {in} {out} build/voice-test/soulx-test/refs/daniel-darker.wav -1' \
#       line.wav line-darker.wav <folder>
#
# It runs soulx-render.py on a list of one job, with seed 0, as every other conversion of the try, in the
# folder Scripts/voice-test/soulx-setup.sh made (build/voice-test/soulx unless SOULX_ROOT names another).
# The model is loaded for each call, which takes 10 to 25 seconds; the speed numbers come from the runs
# of many jobs, not from this. The job's line of JSON goes to standard error, and the exit code is 1 when
# the job failed.
set -euo pipefail

[[ $# -ge 3 ]] || { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOULX_ROOT="${SOULX_ROOT:-$ROOT/build/voice-test/soulx}"
export HF_HOME="$SOULX_ROOT/cache/hf" NUMBA_CACHE_DIR="$SOULX_ROOT/cache/numba" TMPDIR="$SOULX_ROOT/tmp"
export TQDM_DISABLE=1
mkdir -p "$TMPDIR"

WORK="$(mktemp -d "$TMPDIR/one.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

"$SOULX_ROOT/venv/bin/python" -I - "$1" "$2" "$3" "${4:-0}" "$WORK/jobs.json" <<'PYTHON'
import json, os, sys
source, out, reference, pitch, jobs = sys.argv[1:6]
job = {"source": os.path.abspath(source), "out": os.path.abspath(out),
       "reference": os.path.abspath(reference), "pitch": float(pitch), "seed": 0}
json.dump([job], open(jobs, "w"))
PYTHON

"$SOULX_ROOT/venv/bin/python" -I "$ROOT/Scripts/voice-test/soulx-render.py" --root "$SOULX_ROOT" \
    --jobs "$WORK/jobs.json" --report "$WORK/report.jsonl" >/dev/null 2>"$WORK/stderr.txt" \
    || { tail -n 20 "$WORK/stderr.txt" >&2; exit 1; }

tail -n 1 "$WORK/report.jsonl" >&2
grep -q '"ok": true' <(tail -n 1 "$WORK/report.jsonl")
