#!/bin/bash
# The Fast way of phase 37 made with Rubber Band, the library Lockstep already has: the baseline WORLD
# (shift.py) is held against.
#
#   Scripts/voice-test/shift-rb.sh <in.wav> <out.wav> --depth <percent> --pitch <semitones> [--build]
#   Scripts/voice-test/shift-rb.sh line.wav darker.wav --depth 6 --pitch -1
#
# The knobs mean what they mean for shift.py. The voice is shifted by Lockstep's own
# `VoiceShifter.shift(_:semitones:formantScale:)`, run by the gated test `VoiceShifterMeasure` of
# `LockstepAudioTests` in a folder of its own under build/voice-test/rb-work, so it takes the same
# command line as shift.py and Scripts/measure-commute.sh can use it with --make. Depth 0 and Pitch 0
# still go once through the engine (see the test's head for how). For many files and settings at once,
# run the test on a folder: LOCKSTEP_VOICE_TEST=<folder> swift test --package-path LockstepKit
# --filter VoiceShifterMeasure.
#
# The package is not built first (the measuring scripts build it), unless --build is given.
# It prints the test's line: seconds of work for each second of voice. Nothing is played.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ $# -ge 2 ]] || { sed -n '5,6p' "${BASH_SOURCE[0]}" | sed 's/^# //' >&2; exit 2; }
IN="$1"
OUT="$2"
shift 2
DEPTH=""
PITCH=""
BUILD=(--skip-build)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --depth) DEPTH="$2"; shift 2 ;;
        --pitch) PITCH="$2"; shift 2 ;;
        --build) BUILD=(); shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$DEPTH" && -n "$PITCH" && -f "$IN" ]] || { echo "Give a file, --depth and --pitch." >&2; exit 2; }

WORK="$ROOT/build/voice-test/rb-work/$$"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cp "$IN" "$WORK/voice.wav"
if ! LOCKSTEP_VOICE_TEST="$WORK" LOCKSTEP_VOICE_TEST_SETTINGS="$DEPTH,$PITCH" LOCKSTEP_VOICE_TEST_BACK=0 \
    swift test --package-path "$ROOT/LockstepKit" ${BUILD[@]+"${BUILD[@]}"} --filter 'VoiceShifterMeasure' \
    >"$WORK/log" 2>&1; then
    tail -n 30 "$WORK/log" >&2
    exit 2
fi
ANSWER="$(ls "$WORK"/voice.rb.*.wav)"
mv "$ANSWER" "$OUT"
grep -m1 'of work' "$WORK/log" | sed "s|$ANSWER|$OUT|"
