#!/bin/bash
# Says whether it matters if a line is corrected before its voice is made or after: the second half of the
# timing gate of phase 37.
#
#   Scripts/measure-commute.sh --make '<command>' <recording.wav> <voice.wav> <folder>
#   Scripts/measure-commute.sh --make 'Scripts/voice-test/shift.py {in} {out} --depth 6 --pitch -1' \
#       line.wav line-darker.wav build/voice-test/commute/darker
#   Scripts/measure-commute.sh --no-build --same same.wav --make '…' line.wav line-darker.wav <folder>
#
# The app makes the voice of a whole recording once and corrects that voice with the recording's markers.
# That is right when it gives the same sound as making the voice from the corrected recording. So:
#
#   1. The recording is corrected three ways, each at 100 % against a made-up beat of 100 beats a minute:
#      Lines, All, and All with Stretch (`ClipTightening`, as the app does), written to the folder as
#      recording-lines.wav, recording-all.wav and recording-all-stretch.wav.
#   2. `--make` makes the voice of each, with {in} and {out} put in for the two files:
#      made-lines.wav, made-all.wav, made-all-stretch.wav. It must make the voice the way <voice.wav> was
#      made from the recording (the same settings, the same model and sample).
#   3. <voice.wav> is corrected the same three ways with the recording's markers: voice-<way>.wav.
#   4. voice-<way>.wav is held against made-<way>.wav: the displacement where the recording's syllables
#      land (the measure and the marks of Scripts/measure-timing.sh), and the spectral distance over the
#      voiced parts and over the consonants (Scripts/measure-voice.py).
#
# What "the same sound" is, is measured on the line itself: the recording made again by WORLD with nothing
# changed (Scripts/voice-test/shift.py at Depth 0 and Pitch 0, written as same.wav), against the
# recording. That is the cost of one taking apart and putting together, and the two ways of making a
# corrected voice may lie no further apart than that. `--same <file>` names another file for it.
#
# A way passes when its displacement passes and both its spectral distances are no larger than those of
# same.wav against the recording, with 0.5 dB added for what the measure itself wavers. The check passes
# when all three ways do.
#
#   --make <command>   how a voice is made from one file; {in} and {out} are put in. Required.
#   --same <file>      what "the same sound" is measured on, in place of WORLD at no change.
#   --no-build         do not build the package first.
#
# The numbers go to <folder>/commute.json (displacement) and <folder>/<way>.voice.json (spectra); the
# words are printed. Exit code: 0 passed, 1 failed, 2 could not be measured. Nothing is played.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$ROOT/build/uv-cache}"
SLACK_DB=0.5

usage() {
    sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

absolute() {
    local folder
    folder="$(cd "$(dirname "$1")" 2>/dev/null && pwd)" || { echo "There is no folder for $1" >&2; exit 2; }
    echo "$folder/$(basename "$1")"
}

MAKE=""
SAME=""
BUILD=()
FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --make) [[ $# -ge 2 ]] || usage; MAKE="$2"; shift 2 ;;
        --same) [[ $# -ge 2 ]] || usage; SAME="$2"; shift 2 ;;
        --no-build) BUILD=(--skip-build); shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; usage ;;
        *) FILES+=("$1"); shift ;;
    esac
done
[[ ${#FILES[@]} -eq 3 && -n "$MAKE" ]] || usage
[[ "$MAKE" == *"{in}"* && "$MAKE" == *"{out}"* ]] || { echo "--make must have {in} and {out} in it" >&2; exit 2; }
for file in "${FILES[@]:0:2}" ${SAME:+"$SAME"}; do
    [[ -f "$file" ]] || { echo "There is no file $file" >&2; exit 2; }
done
RECORDING="$(absolute "${FILES[0]}")"
VOICE="$(absolute "${FILES[1]}")"
mkdir -p "${FILES[2]}"
FOLDER="$(cd "${FILES[2]}" && pwd)"
LOG="$FOLDER/swift-test.log"
REPORT="$FOLDER/report.txt"
WAYS=(lines all all-stretch)

commute() {
    # One run of the tool in VoiceTimingMeasure. With a voice it compares; without, it corrects the recording.
    if ! env LOCKSTEP_VOICE_COMMUTE="$RECORDING" LOCKSTEP_VOICE_COMMUTE_FOLDER="$FOLDER" \
        LOCKSTEP_VOICE_COMMUTE_REPORT="$REPORT" "$@" \
        swift test --package-path "$ROOT/LockstepKit" ${BUILD[@]+"${BUILD[@]}"} \
            --filter 'VoiceTimingMeasure/commute' >"$LOG" 2>&1 || [[ ! -s "$REPORT" ]]; then
        echo "The measuring did not run. What swift test said:" >&2
        tail -n 40 "$LOG" >&2
        exit 2
    fi
}

# 1. The recording, corrected.
rm -f "$REPORT"
commute
[[ "$(tail -n 1 "$REPORT")" == passed ]] || { sed '$d' "$REPORT" >&2; exit 2; }
BUILD=(--skip-build)

# 2. The voice of each corrected recording, and what "the same" is.
for way in "${WAYS[@]}"; do
    command="${MAKE//\{in\}/\"$FOLDER/recording-$way.wav\"}"
    command="${command//\{out\}/\"$FOLDER/made-$way.wav\"}"
    (cd "$ROOT" && eval "$command") >"$FOLDER/make-$way.log" 2>&1 || {
        echo "Making the voice of recording-$way.wav failed. What it said:" >&2
        tail -n 20 "$FOLDER/make-$way.log" >&2
        exit 2
    }
done
if [[ -z "$SAME" ]]; then
    SAME="$FOLDER/same.wav"
    "$ROOT/Scripts/voice-test/shift.py" "$RECORDING" "$SAME" --depth 0 --pitch 0 >"$FOLDER/make-same.log" 2>&1
fi

# 3 and 4. The voice corrected, held against the voice of the corrected recording.
rm -f "$REPORT"
commute LOCKSTEP_VOICE_COMMUTE_VOICE="$VOICE"
VERDICT="$(tail -n 1 "$REPORT")"
sed '$d' "$REPORT"
[[ "$VERDICT" == passed || "$VERDICT" == failed ]] || exit 2

spectra() {
    # The two spectral distances of b against a, as "voiced consonants".
    "$ROOT/Scripts/measure-voice.py" --json "$3" "$1" "$2" >/dev/null 2>"$3.log" || { cat "$3.log" >&2; exit 2; }
    python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["spectra"]; print(s["voicedDb"], s["consonantsDb"])' "$3"
}
read -r SAME_VOICED SAME_CONSONANTS < <(spectra "$RECORDING" "$SAME" "$FOLDER/same.voice.json")
printf '  the same sound, measured on this line (%s against the recording): spectra %.1f dB apart voiced, %.1f dB consonants\n' \
    "$(basename "$SAME")" "$SAME_VOICED" "$SAME_CONSONANTS"
for way in "${WAYS[@]}"; do
    read -r VOICED CONSONANTS < <(spectra "$FOLDER/made-$way.wav" "$FOLDER/voice-$way.wav" "$FOLDER/$way.voice.json")
    if python3 -c 'import sys; v,c,sv,sc,k=map(float,sys.argv[1:]); sys.exit(0 if v<=sv+k and c<=sc+k else 1)' \
        "$VOICED" "$CONSONANTS" "$SAME_VOICED" "$SAME_CONSONANTS" "$SLACK_DB"; then
        WORD=passed
    else
        WORD=FAILED
        VERDICT=failed
    fi
    printf '  %s: spectra %.1f dB apart voiced, %.1f dB consonants (at most %.1f and %.1f): %s\n' \
        "$way" "$VOICED" "$CONSONANTS" "$(python3 -c "print($SAME_VOICED+$SLACK_DB)")" \
        "$(python3 -c "print($SAME_CONSONANTS+$SLACK_DB)")" "$WORD"
done
echo "  ${VERDICT/failed/FAILED}"
[[ "$VERDICT" == passed ]] && exit 0 || exit 1
