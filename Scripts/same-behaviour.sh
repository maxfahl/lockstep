#!/bin/bash
# Shows whether a built Lockstep still behaves as it did.
#
# Usage: Scripts/same-behaviour.sh --save <folder>     [--app <Lockstep.app>] [--only <run>,<run>...]
#        Scripts/same-behaviour.sh --compare <folder>  [--app <Lockstep.app>] [--only <run>,<run>...]
#
# It builds nothing. Build the app first; without --app it takes
# build/DerivedData/Build/Products/Debug/Lockstep.app of the checkout this script lies in.
#
# It starts that app a number of times, each time in the background with a fresh scratch folder and
# -silent, has it do a fixed list of things through launch arguments and through its menus, quits it
# through its own Quit, and writes down what it printed and saved, with everything that differs from
# one run to the next made the same (ids, dates, folders, timings). That is a "set".
#
#   --save <folder>     makes a set and keeps it in <folder> (which is replaced).
#   --compare <folder>  makes a set in build/same-behaviour/now and lists what differs from the one
#                       in <folder>. Exit code 0: nothing differs. 1: something does. 2: it could not run.
#
# The set every change of phase 29 is compared with is build/same-behaviour/baseline in the main
# checkout. SUMMARY.txt in a set says what was run, what was made the same and what was left out.
#
# The runs (--only takes these names):
#   long      a song opened, beats found, three takes added, words, playhead, click file, a clip sent,
#             Lines, All at 70 %, Stretch, copy and paste
#   loop      Loop switched on and a loop recording added from a file
#   take      a take from Record to Stop with a file in the microphone's place, restarted twice
#             (the app presses Record itself, see -recordTake; this script never presses Record)
#   looptake  the same with Loop on
#   menu      about eighty menu commands pressed one by one, the project and the view kept after each
#   reopen    the project of "long" opened again, another opened over it, and back (needs "long")
#   delete    the speed of Delete and Undo (-deleteClip)
#   drag      the speed of dragging the timeline (-middleDrag)
#
# The menus are pressed through the accessibility API by the process id of the app this script
# started. The app this script runs in (a terminal, an agent app) must be allowed under System
# Settings > Privacy & Security > Accessibility. System Events is never used.
#
# Rules it keeps (AGENTS.md): only the app it started is touched, found by its own scratch folder
# among the running programs; four seconds lie between two starts; the microphone is never opened;
# nothing outside build/same-behaviour of this checkout is written, except the folder given to --save.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 2
HERE="$ROOT/Scripts/same-behaviour"
BASE="$ROOT/build/same-behaviour"
WORK="$BASE/work"
TOOLS="$BASE/tools"
MENU="$TOOLS/menu"
SONG="$ROOT/LockstepKit/Tests/LockstepAudioTests/Fixtures/beatref.wav"
SECOND_SONG="$ROOT/LockstepKit/Tests/LockstepAudioTests/Fixtures/beatshort.wav"
ALL_RUNS="long loop take looptake menu reopen delete drag"
# Seconds between quitting one run and starting the next, so macOS has let go of the first.
PAUSE_BETWEEN_RUNS=4
# After a menu command: the project is saved half a second after a change and the view once a
# second, so this long after a press both files on disk are the ones that follow from it.
SETTLE_AFTER_PRESS=1.3

say() { echo "same-behaviour: $*" >&2; }
fail() { say "$*"; exit 2; }
usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

MODE=""; SET=""; APP="$ROOT/build/DerivedData/Build/Products/Debug/Lockstep.app"; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --save|--compare) [ $# -ge 2 ] || usage; MODE="${1#--}"; SET="$2"; shift 2 ;;
    --app) [ $# -ge 2 ] || usage; APP="$2"; shift 2 ;;
    --only) [ $# -ge 2 ] || usage; ONLY="$(echo "$2" | tr ',' ' ')"; shift 2 ;;
    # For trying the script itself: other folders for its work, to see that no path leaks into a set.
    --work) [ $# -ge 2 ] || usage; WORK="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$MODE" ] || usage
case "$SET" in /*) ;; *) SET="$PWD/$SET" ;; esac
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac
case "$WORK" in /*) ;; *) WORK="$PWD/$WORK" ;; esac
PROGRAM="$APP/Contents/MacOS/Lockstep"
[ -x "$PROGRAM" ] || fail "there is no built app at $APP. Build it first (AGENTS.md has the command), or name one with --app."
[ "$MODE" = compare ] && [ ! -f "$SET/SUMMARY.txt" ] && fail "there is no set in $SET"
RUNS="${ONLY:-$ALL_RUNS}"
for run in $RUNS; do
  case " $ALL_RUNS " in *" $run "*) ;; *) fail "there is no run called \"$run\". The runs are: $ALL_RUNS" ;; esac
done

mkdir -p "$TOOLS" "$WORK" || fail "could not create $BASE"
# One at a time in a checkout: two would share the work folder.
LOCK="$WORK/running"
mkdir "$LOCK" 2>/dev/null || fail "another same-behaviour.sh is running in this checkout (or one was stopped hard: then remove $LOCK)"

PID=""
# Ends the app this script started, if it is still there. Only used when something went wrong:
# every run quits through the app's own Quit.
end_app_hard() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$PID" 2>/dev/null
  fi
  PID=""
}
cleanup() { end_app_hard; rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# The helper that presses menus. Made again when its source is newer.
if [ ! -x "$MENU" ] || [ "$HERE/menu.swift" -nt "$MENU" ]; then
  say "making the menu helper"
  swiftc -O -o "$MENU" "$HERE/menu.swift" 2>"$TOOLS/menu-build.log" || { cat "$TOOLS/menu-build.log" >&2; fail "could not make the menu helper"; }
fi

# The part that reads and compares is tried before the app is started ten times for nothing.
python3 "$HERE/normalize.py" list-files "$HERE" >/dev/null || fail "Scripts/same-behaviour/normalize.py does not run"

# --- One run -------------------------------------------------------------------------------

RUN=""       # the name of the run that is going
SCRATCH=""   # its scratch folder
RAW=""       # where what it printed is kept before it is made the same
STAGE=0      # which start of the run this is: a run starts the app once, or twice with something done to its files in between
LOG=""       # standard error of the start that is going
STEP=0       # menu commands pressed so far in this run
STARTED_ANY=""

# What went wrong in a run is written into its set, so it shows as a difference.
problem() { echo "$*" >>"$RAW/problems.txt"; say "$RUN: $*"; }

begin_run() {
  RUN="$1"; SCRATCH="$WORK/$RUN/scratch"; RAW="$WORK/$RUN/raw"; STAGE=0; STEP=0; DISTURBED=""
  rm -rf "$WORK/$RUN"; mkdir -p "$SCRATCH" "$RAW/steps" || fail "could not create $WORK/$RUN"
  : >"$RAW/problems.txt"; : >"$RAW/presses.txt"
  say "run \"$RUN\""
}

# start <launch arguments...>: starts the app in the background on this run's scratch folder.
# -silent is put last, after every argument that takes a value (AGENTS.md says why).
start() {
  [ -n "$STARTED_ANY" ] && sleep "$PAUSE_BETWEEN_RUNS"
  STARTED_ANY=yes
  STAGE=$((STAGE + 1)); LOG="$RAW/stderr-$STAGE.txt"; : >"$LOG"
  open -g -n --stdout "$LOG" --stderr "$LOG" "$APP" --args -scratch "$SCRATCH" "$@" -silent \
    || { problem "the app could not be started"; return 1; }
  PID=""
  # "open" does not say which process it started. It is the one with this scratch folder.
  for _ in $(seq 1 40); do
    PID="$(ps -axo pid=,command= | awk -v program="$PROGRAM" -v scratch="-scratch $SCRATCH " \
      'index($0, program " " scratch) { print $1; exit }')"
    [ -n "$PID" ] && break
    sleep 0.25
  done
  [ -n "$PID" ] || { problem "the app did not start, or quit at once"; return 1; }
  "$MENU" "$PID" ready 2>>"$RAW/menu-errors.txt" || { problem "the app showed no menu bar"; return 1; }
}

# wait_for <seconds> <pattern>: until a line of this start's standard error matches.
wait_for() {
  local limit="$1" pattern="$2"
  for _ in $(seq 1 $((limit * 4))); do
    grep -qE "$pattern" "$LOG" && return 0
    kill -0 "$PID" 2>/dev/null || { problem "the app was gone while waiting for: $pattern"; return 1; }
    sleep 0.25
  done
  problem "waited $limit s in vain for: $pattern"
  return 1
}

# wait_for_count <seconds> <count> <pattern>: until that many lines match.
wait_for_count() {
  local limit="$1" count="$2" pattern="$3"
  for _ in $(seq 1 $((limit * 4))); do
    [ "$(grep -cE "$pattern" "$LOG")" -ge "$count" ] && return 0
    kill -0 "$PID" 2>/dev/null || { problem "the app was gone while waiting for: $pattern"; return 1; }
    sleep 0.25
  done
  problem "waited $limit s in vain for $count lines of: $pattern"
  return 1
}

# wait_until_able <seconds> <menu> <item>: until that menu command can act, which is how a
# project that is being opened says it is open.
wait_until_able() {
  local limit="$1"; shift
  "$MENU" "$PID" able "$limit" "$@" >/dev/null 2>>"$RAW/menu-errors.txt" \
    || problem "waited $limit s in vain for the menu command: $*"
}

project_folder() { ls -d "$SCRATCH"/Projects/*.lockstep 2>/dev/null | head -1; }

# keep <name> [<project folder>]: copies the project and the view as they are on disk right now.
keep() {
  local name="$1" folder="${2:-$(project_folder)}"
  cp "$folder/project.json" "$RAW/steps/$name.project.json" 2>/dev/null || problem "no project.json to keep as $name"
  cp "$folder/view.json" "$RAW/steps/$name.view.json" 2>/dev/null || true
}

# Writes down, once a run, that the app is in front of the others. It is started behind them and
# nothing here brings it forward, so somebody clicked its window: keys typed since then went to it,
# and what the run kept may not be what this script did. The run is then made again (see the end).
DISTURBED=""
watch_front() {
  [ -z "$DISTURBED" ] && "$MENU" "$PID" front 2>/dev/null && {
    DISTURBED=yes
    problem "DISTURBED: the app was in front of the other apps at step $STEP of start $STAGE. Somebody clicked its window."
  }
}

# press <menu> <item> [<item in submenu>]: presses the command, waits for the project and the view
# to be saved, and keeps both. A command that is greyed out is written down as "off" and not pressed.
press() {
  STEP=$((STEP + 1))
  watch_front
  "$MENU" "$PID" press "$@" >>"$RAW/presses.txt" 2>>"$RAW/menu-errors.txt"
  case $? in 0|2) ;; *) echo "missing: $*" >>"$RAW/presses.txt"; problem "the menu command is not there: $*" ;; esac
  sleep "$SETTLE_AFTER_PRESS"
  keep "$(printf '%02d' "$STEP")-$(echo "$*" | tr -cs 'A-Za-z0-9' '-' | sed 's/-$//')"
}

# press_only: the same without waiting and keeping, for a command whose result depends on the clock.
press_only() {
  "$MENU" "$PID" press "$@" >>"$RAW/presses.txt" 2>>"$RAW/menu-errors.txt"
  case $? in 0|2) ;; *) echo "missing: $*" >>"$RAW/presses.txt"; problem "the menu command is not there: $*" ;; esac
}

# list_menus <name>: every menu command with whether it can act and whether it is ticked.
list_menus() {
  "$MENU" "$PID" list >"$RAW/steps/$(printf '%02d' "$STEP")-menus-$1.txt" 2>>"$RAW/menu-errors.txt" \
    || problem "the menus could not be listed ($1)"
}

# Quits through the app's own Quit, so the project is saved and closed as when Max quits.
quit_app() {
  [ -n "$PID" ] || return
  watch_front
  "$MENU" "$PID" quit >/dev/null 2>>"$RAW/menu-errors.txt" || problem "Quit could not be pressed (start $STAGE)"
  for _ in $(seq 1 80); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
  if kill -0 "$PID" 2>/dev/null; then
    problem "the app did not quit within 20 s of Quit and was ended with a signal (start $STAGE)"
    end_app_hard
  fi
  grep -q "^Lockstep: counted " "$LOG" || problem "no line of counts at Quit (start $STAGE)"
  PID=""
  # What the scratch folder holds now that the project is closed: closing is the only code that
  # removes the files of recordings no clip uses.
  python3 "$HERE/normalize.py" list-files "$SCRATCH" >"$RAW/files-$STAGE.txt" 2>>"$RAW/problems.txt"
}

# --- The runs ------------------------------------------------------------------------------

V="$HERE"

run_long() {
  begin_run long
  start -open "$SONG" -addTake "$V/voice-a.wav" -addTake "$V/voice-b.wav" -addTake "$V/voice-c.wav@20" \
    -clipText "one two three" -playhead 21.5 -clickFile "$SCRATCH/click.wav" -sendClip "$SCRATCH/sent.wav" \
    -strength 70 -tighten -stretch -pasteClip || return
  wait_for 60 "found [0-9]+ beats|found no beats"
  wait_for 30 "tightened the track|could not tighten|did not tighten"
  wait_for 30 "set the strength|could not set the strength"
  wait_for 30 "wrote the list for the Resolve script|could not send|did not send"
  wait_for 30 "the click file"
  wait_for 10 "pasted a copy|could not paste|did not paste"
  sleep 2.5
  keep end
  quit_app
}

run_loop() {
  begin_run loop
  start -open "$SONG" -playhead 12.1 -loop 4.9,9.7 -loopTake "$V/voice-long.wav" || return
  wait_for 60 "found [0-9]+ beats|found no beats"
  wait_for 30 "looping from|could not loop"
  wait_for 30 "added pass [0-9]+ of ([0-9]+) of the loop take|loop take"
  sleep 2.5
  keep end
  quit_app
}

# The take takes about 20 s: three count-ins of a bar and three attempts of 3 s.
run_take() {
  begin_run take
  start -open "$SONG" -playhead 4.9 -recordTake "$V/voice-long.wav" || return
  wait_for 60 "found [0-9]+ beats|found no beats"
  wait_for 90 "stopped the take|could not record a take|the take ended by itself|did not go on"
  sleep 3
  keep end
  quit_app
}

run_looptake() {
  begin_run looptake
  start -open "$SONG" -playhead 4.9 -loop 4.9,7.3 -recordTake "$V/voice-long.wav" || return
  wait_for 60 "found [0-9]+ beats|found no beats"
  wait_for 90 "stopped the take|could not record a take|the take ended by itself|did not go on"
  sleep 3
  keep end
  quit_app
}

run_menu() {
  begin_run menu
  # First start: a project with a line of two takes and two clips further on. The line is cut in
  # two at the playhead with nothing selected, and the last clip is deleted and not brought back,
  # so this Quit has a recording no clip uses: closing the project must remove its files
  # (files-after-start-1.txt).
  start -open "$SONG" -addTake "$V/voice-a.wav" -addTake "$V/voice-b.wav" -addTake "$V/voice-c.wav@20" \
    -addTake "$V/voice-long.wav@30" -playhead 2.5 || return
  wait_for 60 "found [0-9]+ beats|found no beats"
  wait_for 10 "moved the playhead"
  sleep 2
  list_menus first-start
  press Edit "Split at Playhead"
  press Transport "Next Clip"
  press Transport "Next Clip"
  press Edit "Delete*"
  # A zoom with the animation on, so the code that glides the timeline is run. Where the glide stands
  # when the view is written follows the display's frames, so nothing is kept of it: the view written
  # by hand below starts from "fit" again.
  press_only View "Zoom In"
  sleep 0.6
  press_only View "Zoom Out"
  sleep 0.6
  quit_app

  # Between the two starts: a view written by hand, which selects both pieces of the cut line, so
  # Join Clips has something to join. Nothing but a pointer selects two clips in the app.
  python3 "$HERE/normalize.py" select-pieces "$(project_folder)" 2>>"$RAW/problems.txt" \
    || problem "the view could not be written by hand"
  # And animations off in this scratch folder's own settings (Settings > General has the same choice),
  # so a zoom from the menu is where it is going at once. With them on, the timeline of a window that
  # lies behind others stops part of the way until its next frame, at a place the clock decides, and
  # the zoom kept after a press differed from run to run.
  defaults write "$SCRATCH/Settings" general.animationSpeed -string off 2>>"$RAW/problems.txt" \
    || problem "the animations could not be switched off in the scratch settings"
  cp "$(project_folder)/view.json" "$RAW/steps/04b-view-written-by-hand.view.json" 2>/dev/null

  # Second start: the project opened again, and the menus.
  start -open "$(project_folder)" || return
  wait_until_able 30 Track "New Track"
  sleep 2
  keep 04c-opened-again
  list_menus opened-again

  # Clips: the line that was cut.
  press Edit "Join Clips"
  press Edit "Undo*"
  press Edit "Redo*"
  press Clip "Next Take"
  press Clip "Previous Take"
  press Clip "Previous Take"
  press Clip "Normalize"
  press Clip "Mute Clip"
  press Clip "Mute Clip"
  press Clip "Correction" "Lines"
  press Clip "Correction" "All"
  press Clip "Correction On or Off"
  press Clip "Correction On or Off"
  press Clip "Sub-beats" "Triplets"
  press Clip "Sub-beats" "Auto"
  press Clip "Write Out Words Again"
  list_menus clip-chosen
  press Edit "Copy"
  press Transport "Go to Start"
  press Transport "Next Beat"
  press Transport "Next Half Beat"
  press Transport "Next Sub-beat"
  press Transport "Previous Sub-beat"
  press Transport "Previous Half Beat"
  press Transport "Previous Beat"
  press Transport "Next Clip"
  press Transport "Next Clip"
  press Transport "Previous Clip"

  # Tracks.
  press Track "New Track"
  press Edit "Paste"
  press Track "Duplicate Track"
  press Track "Mute Track"
  press Transport "Clip Above"
  press Transport "Clip Above"
  press Track "Duplicate Track with Clips"
  press Track "Normalize Track"
  list_menus four-tracks
  press Track "Merge Into" "Track 2"
  press Track "Delete Track"
  press Edit "Undo*"
  press Edit "Undo*"
  press Edit "Redo*"

  # The song: tempo, beat one, the click, the beats found again.
  press Song "Halve Tempo"
  press Song "Double Tempo"
  press Transport "Next Beat"
  press Song "This Is Beat 1"
  press Transport "Click On or Off"
  press Song "Find Beats Again"
  wait_for 60 "found [0-9]+ beats|found no beats"
  sleep 1.5
  keep "$(printf '%02d' "$STEP")b-beats-found-again"

  # The loop, and playing. While the song plays the place follows the clock, so nothing is kept
  # until the playhead is back at the start.
  press Transport "Set Loop In"
  press Transport "Next Beat"
  press Transport "Next Beat"
  press Transport "Next Beat"
  press Transport "Next Beat"
  press Transport "Set Loop Out"
  press Transport "Loop"
  list_menus loop-on
  press_only Transport "Play or Stop"
  sleep 1.5
  press_only Transport "Play or Stop"
  sleep 0.5
  press Transport "Go to Start"
  press Transport "Loop"
  press Transport "Clear Loop In and Out"
  press_only Transport "Play or Stop"
  sleep 1.5
  press_only Transport "Play or Stop"
  sleep 0.5
  press Transport "Go Back"
  press Transport "Go to Start"

  # The view.
  press View "Zoom In"
  press View "Zoom In"
  press Transport "Next Screen"
  press Transport "Previous Screen"
  press View "Zoom Out"
  press View "Zoom to Fit"
  press View "Taller Tracks"
  press View "Lower Tracks"
  press View "Lower Tracks"

  # Settings of the app that the menus switch.
  press Edit "Snapping"
  press Edit "Snap To" "Playhead"
  press Edit "Snap To" "Grid in Beats"

  # Last: a clip with two takes loses the other one, and a clip is deleted. Neither is undone, so
  # quitting has recordings no clip uses, and closing the project removes their files.
  press Transport "Next Clip"
  press Clip "Delete Other Takes"
  press Transport "Next Clip"
  press Edit "Delete*"
  press Edit "Undo*"
  press Edit "Redo*"
  list_menus end
  quit_app
}

run_reopen() {
  begin_run reopen
  local saved="$WORK/long/scratch/Projects/beatref.lockstep"
  [ -f "$saved/project.json" ] || { problem "the run \"long\" left no project to open again"; return; }
  # First start: a second song, so there is another project to open over the first.
  start -open "$SECOND_SONG" || return
  wait_for 60 "found [0-9]+ beats|found no beats"
  sleep 2.5
  keep 1-second-song
  quit_app

  # Second start: the project the long run saved, a copy of it in this run's own folder.
  cp -R "$saved" "$SCRATCH/Projects/beatref.lockstep" || { problem "could not copy the project of \"long\""; return; }
  start -open "$SCRATCH/Projects/beatref.lockstep" || return
  wait_until_able 30 Track "New Track"
  sleep 2.5
  keep 2-opened-again "$SCRATCH/Projects/beatref.lockstep"
  list_menus opened-again
  press_only File "Open Recent" "beatshort"
  sleep 3
  wait_until_able 30 Track "New Track"
  keep 3-other-opened-over-it "$SCRATCH/Projects/beatshort.lockstep"
  keep 3-the-one-left "$SCRATCH/Projects/beatref.lockstep"
  list_menus other-opened
  press_only Track "New Track"
  sleep "$SETTLE_AFTER_PRESS"
  press_only File "Open Recent" "beatref"
  sleep 3
  wait_until_able 30 Track "New Track"
  keep 4-back "$SCRATCH/Projects/beatref.lockstep"
  keep 4-the-other-left "$SCRATCH/Projects/beatshort.lockstep"
  quit_app
}

run_delete() {
  begin_run delete
  start -open "$SONG" -addTake "$V/voice-a.wav" -addTake "$V/voice-b.wav" -deleteClip || return
  wait_for 60 "found [0-9]+ beats|found no beats"
  # The third Delete is made while the song plays and is not undone.
  wait_for_count 60 3 "^Lockstep: deleted the clip|could not delete|did not delete"
  sleep 2.5
  keep end
  quit_app
}

run_drag() {
  begin_run drag
  start -open "$SONG" -addTake "$V/voice-a.wav" -middleDrag || return
  wait_for 60 "found [0-9]+ beats|found no beats"
  wait_for_count 90 6 "^Lockstep: dragged |could not drag|did not drag"
  sleep 2.5
  keep end
  quit_app
}

# --- Make the set --------------------------------------------------------------------------

STARTED_AT=$(date +%s)
for run in $RUNS; do
  # A run somebody disturbed is made again, twice at most. After that it stays in the set as it is,
  # with the disturbance among its problems, so it shows as a difference and not as a clean run.
  for attempt in 1 2 3; do
    "run_$run"
    end_app_hard
    [ -z "$DISTURBED" ] && break
    [ "$attempt" -lt 3 ] && say "the run \"$run\" was disturbed and is made again"
  done
done

if [ "$MODE" = save ]; then OUT="$SET"; else OUT="$BASE/now"; fi
python3 "$HERE/normalize.py" make-set "$WORK" "$OUT" --root "$ROOT" --app "$APP" --runs "$RUNS" \
  --seconds $(( $(date +%s) - STARTED_AT )) || fail "the set could not be made"

if [ "$MODE" = save ]; then
  say "saved the set in $OUT ($(( $(date +%s) - STARTED_AT )) s)"
  exit 0
fi
python3 "$HERE/normalize.py" compare "$SET" "$OUT" --runs "$RUNS"
RESULT=$?
say "compared in $(( $(date +%s) - STARTED_AT )) s. The set of now is in $OUT, what each run did is in $WORK"
exit $RESULT
