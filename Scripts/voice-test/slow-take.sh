#!/bin/bash
# Makes a line as a take recorded slower comes into Lockstep: sped up to the song's speed with
# `SpedUpTake`, which is the sound a track's Voice is made from for such a take.
#
#   Scripts/voice-test/slow-take.sh <line.wav> <sped-up.wav>
#   Scripts/voice-test/slow-take.sh --rate 0.9 --keep-slow <slow.wav> <line.wav> <sped-up.wav>
#   Scripts/voice-test/slow-take.sh --is-slow <line-slow.wav> <sped-up.wav>
#
# Without --is-slow the line is one at full speed. It is first slowed to the speed (0.85 unless --rate
# says 0.9) at the same pitch, as if it had been recorded against the slowed song, and then brought back.
# The answer is about as long as the line and has been through the stretcher twice.
#
# With --is-slow the line was really recorded slower (Max's `line-slow.wav`), and it is only brought back.
#
#   --rate <speed>         the speed the take was recorded at, as a share of the song's: 0.85 or 0.9
#   --keep-slow <file>     also write the slow sound there
#   --no-build             do not build the package first
#
# Every file is mono at 48,000 Hz, and the answers are WAV, 48,000 Hz, 24-bit. The work is done by
# Lockstep's own code, in the test `VoiceTimingMeasure` of `LockstepAudioTests`. Nothing is played.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/build/voice-test/measure-timing"

usage() {
    sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

absolute() {
    local folder
    folder="$(cd "$(dirname "$1")" 2>/dev/null && pwd)" || { echo "There is no folder for $1" >&2; exit 2; }
    echo "$folder/$(basename "$1")"
}

RATE="0.85"
SLOW=""
IS_SLOW=""
BUILD=()
FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rate) [[ $# -ge 2 ]] || usage; RATE="$2"; shift 2 ;;
        --keep-slow) [[ $# -ge 2 ]] || usage; SLOW="$(absolute "$2")"; shift 2 ;;
        --is-slow) IS_SLOW=1; shift ;;
        --no-build) BUILD=(--skip-build); shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; usage ;;
        *) FILES+=("$1"); shift ;;
    esac
done
[[ ${#FILES[@]} -eq 2 ]] || usage
[[ -f "${FILES[0]}" ]] || { echo "There is no file ${FILES[0]}" >&2; exit 2; }

mkdir -p "$WORK"
LOG="$WORK/slow-take.$$.log"
trap 'rm -f "$LOG"' EXIT
OUTPUT="$(absolute "${FILES[1]}")"
rm -f "$OUTPUT"

# A variable that is set at all means "yes" to the test, so the two that are optional are only set when
# they are wanted.
ENVIRONMENT=(
    "LOCKSTEP_VOICE_SLOW_TAKE=$(absolute "${FILES[0]}")"
    "LOCKSTEP_VOICE_SLOW_TAKE_OUT=$OUTPUT"
    "LOCKSTEP_VOICE_SLOW_TAKE_RATE=$RATE"
)
[[ -n "$IS_SLOW" ]] && ENVIRONMENT+=("LOCKSTEP_VOICE_SLOW_TAKE_IS_SLOW=1")
[[ -n "$SLOW" ]] && ENVIRONMENT+=("LOCKSTEP_VOICE_SLOW_TAKE_SLOW=$SLOW")

if ! env "${ENVIRONMENT[@]}" swift test --package-path "$ROOT/LockstepKit" ${BUILD[@]+"${BUILD[@]}"} \
    --filter 'VoiceTimingMeasure/slowTake' >"$LOG" 2>&1 || [[ ! -f "$OUTPUT" ]]; then
    echo "The take could not be made. What swift test said:" >&2
    tail -n 40 "$LOG" >&2
    exit 2
fi
grep '^slow take: ' "$LOG" || true
