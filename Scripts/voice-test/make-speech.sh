#!/bin/bash
# Makes the made-up speech that the measurements of phase 37 are first taken on, before Max's own voice
# is there.
#
#   Scripts/voice-test/make-speech.sh             into build/voice-test/speech (ignored by git)
#   Scripts/voice-test/make-speech.sh <folder>    into another folder
#
# Two voices of the Mac's `say`, a man's (Daniel) and a woman's (Samantha). For each, with the voice's
# name in front (`daniel-fast.wav`):
#
#   fast.wav          a fast line of about 12 seconds, with t, k, p and s in it, a pause and a line end
#   short.wav         a line of about half a second
#   gap.wav           a line with two seconds of silence in the middle
#   long.wav          a line of about 60 seconds
#   sample.wav        about 25 seconds of plain speech: the voice's sample, for a voice model
#   fast-slow.wav     the fast line slowed to 85 %, as if recorded against the slowed song
#   fast-sped-up.wav  that brought back with `SpedUpTake`, as a take recorded slower comes into the app
#
# Every file is WAV, 48,000 Hz, 24-bit, mono. `say` speaks, `afconvert` brings its sound to 48,000 Hz,
# `add-room.py` puts a quiet room under it (see there for why), and `slow-take.sh` makes the last two with
# Lockstep's own code. The first run in a checkout builds LockstepKit's tests for that, which takes a few
# minutes, and fetches numpy with `uv` into build/uv-cache.
#
# The files are the same on every run on this Mac, as long as macOS keeps the two voices as they are: the
# list it prints at the end has the SHA-256 of each, so two agents can see that they measure the same
# speech. What `say` cannot give: its voices hold no sound above 11 kHz, so where a made voice's sound
# ends has to be judged on Max's own recording. Nothing is played.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/build/voice-test/speech}"
TMP="$ROOT/build/voice-test/speech-work.$$"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$ROOT/build/uv-cache}"

mkdir -p "$OUT" "$TMP"
OUT="$(cd "$OUT" && pwd)"
trap 'rm -rf "$TMP"' EXIT

# A line of rap: hard consonants close together, a breath in the middle, and an end.
FAST="Tick tock, pick the lock, pack the bag and take a walk. Stack the paper, skip the talk, kick the pedal, \
pop the cork. [[slnc 450]] Step back, set the pace, keep the tempo, cut the bass. Tap the snare and tape the \
take, split the second, stick the break. [[slnc 300]] Stop."

SHORT="Kick it back."

GAP="Pick the pocket, pack the kit, take the ticket. [[slnc 2000]] Skip the step, stack the set, keep the secret."

LONG="Tick tock, pick the lock, pack the bag and take a walk. Stack the paper, skip the talk, kick the pedal, \
pop the cork. [[slnc 400]] Step back, set the pace, keep the tempo, cut the bass. Tap the snare and tape the \
take, split the second, stick the break. [[slnc 500]] Cold cup, copper pot, capture every single shot. Put \
the pieces in the spot, tip the bucket, take the lot. [[slnc 400]] Speak quick, spit the script, stick the \
tape and strip the clip. Pick a pocket, pack a kit, skip the socket, take the hit. [[slnc 600]] Past the \
station, cross the street, kept the pattern, caught the beat. Postcard, passport, ticket, seat, set the \
table, time to eat. [[slnc 400]] Top speed, sixteen bars, stop the tape and park the cars. Skip the city, \
count the stars, pack the suitcase, take guitars. [[slnc 500]] Tight grip, steady step, cut the static, \
keep the rep. Spotless kitchen, set the prep, pick the pepper, check the pep. [[slnc 400]] Six takes, stack \
the tracks, tap the pedal, pass the sax. Catch the tempo, cut the slack, pack the speakers, take it back. \
[[slnc 600]] Tick tock, stop the clock, pack the kit and pick the lock. Keep the secret, skip the talk, \
tape the ticket to the dock. [[slnc 400]] Sticks and kicks and tiptoe steps, capture what the tape accepts. \
Stop."

# Plain talk, as someone says who he is and what he does, for a voice model to hear the voice in.
SAMPLE="Most mornings I walk down to the harbour before the town wakes up. The boats are still tied to the \
quay and the water is flat and grey. I buy a cup of coffee from the small kiosk by the ferry, and I sit on \
the long wooden bench and watch the gulls. Later the market opens, and the whole square smells of bread, \
oranges and smoked fish. I usually stay until the first ferry leaves, and then I take the path along the shore and go home to work."

# speak <voice of say> <words a minute> <file name> <seed of the room> <text>
speak() {
    say -v "$1" -r "$2" -o "$TMP/$3.aiff" "$5"
    afconvert -f WAVE -d LEI24@48000 -c 1 "$TMP/$3.aiff" "$TMP/$3.wav"
    "$ROOT/Scripts/voice-test/add-room.py" "$TMP/$3.wav" "$OUT/$3.wav" --seed "$4"
}

# voice <name in the files> <voice of say> <first seed>
voice() {
    speak "$2" 250 "$1-fast" "$3" "$FAST"
    speak "$2" 250 "$1-short" "$(($3 + 1))" "$SHORT"
    speak "$2" 250 "$1-gap" "$(($3 + 2))" "$GAP"
    speak "$2" 250 "$1-long" "$(($3 + 3))" "$LONG"
    speak "$2" 175 "$1-sample" "$(($3 + 4))" "$SAMPLE"
    "$ROOT/Scripts/voice-test/slow-take.sh" ${BUILT:+--no-build} --keep-slow "$OUT/$1-fast-slow.wav" \
        "$OUT/$1-fast.wav" "$OUT/$1-fast-sped-up.wav" >/dev/null
    BUILT=1
}

BUILT=""
voice daniel Daniel 10
voice samantha Samantha 20

echo "The made-up speech is in $OUT"
for file in "$OUT"/*.wav; do
    seconds="$(afinfo "$file" | sed -n 's/^estimated duration: \([0-9.]*\) sec.*/\1/p')"
    printf '  %-28s %7.2f s  %s\n' "$(basename "$file")" "$seconds" "$(shasum -a 256 "$file" | cut -c 1-16)"
done
