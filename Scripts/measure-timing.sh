#!/bin/bash
# Says whether a made voice still has its syllables where the recording has them: the timing gate of
# phase 37.
#
#   Scripts/measure-timing.sh <recording.wav> <voice.wav> [<more voices>]
#   Scripts/measure-timing.sh --joins 10,20.5 <recording.wav> <voice.wav>
#   Scripts/measure-timing.sh --no-build <recording.wav> <voice.wav>
#
# Every file is mono (or its first channel is taken) at 48,000 Hz. Each voice is one made from the
# recording, and should be exactly as long.
#
# The measuring is done by Lockstep's own code, in the test `VoiceTimingMeasure` of `LockstepAudioTests`,
# which only runs when this script asks for it. The gate, since 16 November 2026:
#
#   displacement    at every syllable marker, pause edge and line end of the RECORDING, how far the voice's
#                   sound lies from the recording's, measured from the sound itself in five bands
#                   (`VoiceDisplacement`), with how sure each number is. The syllable finder is not run on
#                   the voice for this: the app never runs it on a made voice.
#   corrected line  the line corrected with All at 100 % and Stretch against a beat of 100 beats a minute,
#                   once from the recording and once from the voice, both with the recording's markers; the
#                   same displacement where the recording's syllables land in the two
#
# A part passes when at least 95 % of the places where a sound starts (syllables, pause ends, line starts)
# are within 6 ms, none of them is further than 10 ms, no place where a sound ends (pause starts, line
# ends) is further than 20 ms, and no more than 10 % of the places are unsure: unsure places beyond that
# count as out of place. Places within 70 ms of an end of the file are not measured. The marks come from
# WORLD at no change against the recording on the made-up speech. A voice passes when both parts do.
#
# Also printed, as no pass mark: the numbers of each line of the recording, and how many of the
# recording's markers and pause edges the syllable finder and the pause finder find again in the voice
# within 10 ms (the gate at first). The voice is brought to the recording's loudness before it is measured.
#
# Whether correcting before the voice is made gives the same as correcting after is the other half of the
# gate: Scripts/measure-commute.sh.
#
#   --joins <seconds>,<seconds>   the places where a voice model joined one stretch to the next. The
#                                 numbers within half a second of a join are then given apart, and
#                                 must pass too.
#   --no-build                    do not build the package first. For the second run of many: the
#                                 first one built it.
#
# What it prints for each voice is also written beside the voice, as `<voice without .wav>.timing.json`,
# with every place that was measured: its displacement, how close the sounds fit, how sharp the fit is and
# whether it is sure (the printed list of places out of place stops at eight). A number there is none of,
# such as the middle distance when nothing is sure, is left out of the file.
#
# Exit code: 0 when every voice passed, 1 when one failed, 2 when something could not be measured.
#
# The first run in a checkout builds LockstepKit's tests, which takes a few minutes. Nothing is played.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/build/voice-test/measure-timing"

usage() {
    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

absolute() {
    local folder
    folder="$(cd "$(dirname "$1")" 2>/dev/null && pwd)" || { echo "There is no folder for $1" >&2; exit 2; }
    echo "$folder/$(basename "$1")"
}

JOINS=""
BUILD=()
FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --joins) [[ $# -ge 2 ]] || usage; JOINS="$2"; shift 2 ;;
        --no-build) BUILD=(--skip-build); shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; usage ;;
        *) FILES+=("$1"); shift ;;
    esac
done
[[ ${#FILES[@]} -ge 2 ]] || usage

for file in "${FILES[@]}"; do
    [[ -f "$file" ]] || { echo "There is no file $file" >&2; exit 2; }
done

RECORDING="$(absolute "${FILES[0]}")"
VOICES=""
for file in "${FILES[@]:1}"; do
    VOICES+="$(absolute "$file")"$'\n'
done

mkdir -p "$WORK"
REPORT="$WORK/report.$$.txt"
LOG="$WORK/swift-test.$$.log"
trap 'rm -f "$REPORT" "$LOG"' EXIT

# The test's own exit code says only whether it ran. The verdict is the last line of its report.
if ! LOCKSTEP_VOICE_TIMING="$RECORDING" \
    LOCKSTEP_VOICE_TIMING_VOICES="$VOICES" \
    LOCKSTEP_VOICE_TIMING_JOINS="$JOINS" \
    LOCKSTEP_VOICE_TIMING_REPORT="$REPORT" \
    swift test --package-path "$ROOT/LockstepKit" ${BUILD[@]+"${BUILD[@]}"} \
        --filter 'VoiceTimingMeasure/measure' >"$LOG" 2>&1 || [[ ! -s "$REPORT" ]]; then
    echo "The measuring did not run. What swift test said:" >&2
    tail -n 40 "$LOG" >&2
    exit 2
fi

VERDICT="$(tail -n 1 "$REPORT")"
sed '$d' "$REPORT"
case "$VERDICT" in
    passed) exit 0 ;;
    failed) exit 1 ;;
    *) exit 2 ;;
esac
