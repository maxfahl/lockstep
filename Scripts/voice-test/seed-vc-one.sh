#!/bin/bash
# Converts one file with Seed-VC, for tools that make a voice one file at a time, such as the `--make` of
# Scripts/measure-commute.sh:
#
#   Scripts/voice-test/seed-vc-one.sh <in.wav> <out.wav> <reference.wav> <pitch> [<reference seconds, 10>] [<steps, 30>] [<seed, 1>]
#
#   Scripts/measure-commute.sh --make 'Scripts/voice-test/seed-vc-one.sh {in} {out} refs/daniel-darker.wav -1' …
#
# It writes a list of one job and runs it through seed-vc-run.sh, so the answer is made exactly as a job of a
# longer list would be (the same seed, reference, steps and precision). The models are loaded for each file.
# The report lies beside the answer as <out without .wav>.report.json.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -ge 4 ] || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
IN="$1"; OUT="$2"; REF="$3"; PITCH="$4"; REF_SECONDS="${5:-10}"; STEPS="${6:-30}"; SEED="${7:-1}"
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
mkdir -p "$(dirname "$OUT")"
IN="$(abs "$IN")"; OUT="$(abs "$OUT")"; REF="$(abs "$REF")"
JOBS="${OUT%.wav}.job.json"
printf '[{"source": "%s", "reference": "%s", "output": "%s", "pitch": %s, "referenceSeconds": %s, "steps": %s, "seed": %s}]\n' \
    "$IN" "$REF" "$OUT" "$PITCH" "$REF_SECONDS" "$STEPS" "$SEED" > "$JOBS"
"$HERE/seed-vc-run.sh" --jobs "$JOBS" --report "${OUT%.wav}.report.json" 2> "${OUT%.wav}.log" || { cat "${OUT%.wav}.log" >&2; exit 1; }
if ! jq -e '.jobs[0] | has("failed") | not' "${OUT%.wav}.report.json" >/dev/null; then
    jq -r '.jobs[0].failed' "${OUT%.wav}.report.json" >&2
    exit 1
fi
