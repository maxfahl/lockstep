#!/bin/bash
# Saves a picture of every window the app has on screen.
#
# Usage: Scripts/screenshot.sh [--app <name>] <output.png> [launch arguments...]
#
# --app picks the app: Lockstep (the default) or LockstepDesign, the design
# lab. The launch arguments choose what the app shows, for example
# "-state Main" in the design lab.
#
# Builds the Debug app if needed, starts it with the launch arguments, waits
# for its window, saves the pictures and quits the app. The app is started
# behind the windows that are already open and does not take the keyboard.
# Lockstep itself is always started with -scratch and a fresh folder that is
# deleted afterwards, and with -silent, so it never touches Max's settings or
# projects and makes no sound. The design lab needs neither.
# The pictures show each window completely, also where others cover it. With one window the
# picture is <output.png>. With more, the largest is <output.png> and the
# others are saved next to it as <output>-2.png, <output>-3.png and so on.
# The saved paths are printed on standard output, everything else on standard
# error.

set -u

# The app to build and photograph, by the name of its scheme.
APP_NAME="Lockstep"
PROJECT_FILE="Lockstep.xcodeproj"
WINDOW_TIMEOUT_SECONDS=20

say() { echo "screenshot: $*" >&2; }
fail() { say "$*"; exit 1; }

usage() {
  echo "Usage: Scripts/screenshot.sh [--app Lockstep|LockstepDesign] <output.png> [launch arguments...]" >&2
  exit 64
}

if [ "${1:-}" = "--app" ]; then
  [ $# -ge 2 ] || usage
  APP_NAME="$2"
  shift 2
fi
[ $# -ge 1 ] || usage

# The .app and the program inside it carry the name people see, which for
# the design lab is not the name of its scheme.
case "$APP_NAME" in
  Lockstep) PRODUCT_NAME="Lockstep" ;;
  LockstepDesign) PRODUCT_NAME="Lockstep Design" ;;
  *) say "there is no app called \"$APP_NAME\""; usage ;;
esac

OUTPUT="$1"
shift
case "$OUTPUT" in
  /*) ;;
  *) OUTPUT="$PWD/$OUTPUT" ;;
esac

# The repository is found from where this script lies, so it works the same
# in every worktree and from any current folder.
ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
BUILD_DIR="$ROOT/build/screenshot"
APP_BUNDLE="$BUILD_DIR/DerivedData/Build/Products/Debug/$PRODUCT_NAME.app"
APP_PROGRAM="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/screenshot.XXXXXX")" || exit 1
APP_PID=""

quit_app() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 0.25
    done
    kill -KILL "$APP_PID" 2>/dev/null
  fi
  APP_PID=""
}

cleanup() {
  quit_app
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The name of the app this script was started from (a terminal, an editor or
# an agent app). macOS gives the Screen Recording permission to that app.
host_app() {
  local pid=$$ command name
  while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    command="$(ps -o comm= -p "$pid" 2>/dev/null)"
    case "$command" in
      *.app/*)
        name="${command%%.app/*}"
        echo "${name##*/}"
        return
        ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
  echo "the terminal this script was run from"
}

permission_missing() {
  say "the Screen Recording permission is missing: allow it for \"$(host_app)\" in System Settings > Privacy & Security > Screen & System Audio Recording, then run this again."
  exit 1
}

# --- Build ---------------------------------------------------------------

mkdir -p "$BUILD_DIR" || fail "could not create $BUILD_DIR"
say "building $APP_NAME (Debug)"
if ! xcodebuild -project "$ROOT/$PROJECT_FILE" -scheme "$APP_NAME" \
    -configuration Debug -derivedDataPath "$BUILD_DIR/DerivedData" \
    build >"$BUILD_DIR/build.log" 2>&1; then
  tail -n 40 "$BUILD_DIR/build.log" >&2
  fail "the build failed, the full log is in $BUILD_DIR/build.log"
fi
[ -x "$APP_PROGRAM" ] || fail "the build did not produce $APP_PROGRAM"

# --- Start the app -------------------------------------------------------

# The freshly built app is started through "open -g", which is how macOS
# starts an app behind the windows that are already open, without making it
# the active app and without giving it the keyboard. Starting the program
# inside the app directly would put its window in front of whoever is working
# on this Mac. -n starts this copy even when another Lockstep is open.
#
# -ApplePersistenceIgnoreState YES makes macOS forget which windows were open
# or closed the last time the app ran. Without it the app can come up with
# no window at all, and the picture would depend on what happened before.

# Prints the process ids of every running copy of the freshly built app.
app_pids() {
  ps -axo pid=,comm= | while read -r pid command; do
    [ "$command" = "$APP_PROGRAM" ] && echo "$pid"
  done
}

# "open" does not say which process it started. The new one is the copy that
# was not running before, so another Lockstep that is already open is neither
# photographed nor closed.
PIDS_BEFORE=" $(app_pids | tr '\n' ' ')"
: >"$BUILD_DIR/app.log"
# Lockstep gets a scratch folder inside this script's own temporary folder,
# which is deleted when the script ends. -silent comes last, after the
# caller's arguments, so it is never taken as the value of the one before it.
AGENT_ARGUMENTS=()
LAST_ARGUMENTS=()
if [ "$APP_NAME" = "Lockstep" ]; then
  AGENT_ARGUMENTS=(-scratch "$WORK_DIR/scratch")
  LAST_ARGUMENTS=(-silent)
fi
open -g -n --stdout "$BUILD_DIR/app.log" --stderr "$BUILD_DIR/app.log" \
    "$APP_BUNDLE" --args -ApplePersistenceIgnoreState YES \
    ${AGENT_ARGUMENTS[@]+"${AGENT_ARGUMENTS[@]}"} "$@" \
    ${LAST_ARGUMENTS[@]+"${LAST_ARGUMENTS[@]}"} \
  || fail "could not start $APP_BUNDLE"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  for pid in $(app_pids); do
    case "$PIDS_BEFORE" in
      *" $pid "*) ;;
      *) APP_PID="$pid" ;;
    esac
  done
  [ -n "$APP_PID" ] && break
  sleep 0.25
done
if [ -z "$APP_PID" ]; then
  tail -n 20 "$BUILD_DIR/app.log" >&2
  fail "$APP_NAME did not start, or quit at once. Its output is in $BUILD_DIR/app.log"
fi
say "started $APP_NAME in the background (process $APP_PID)"

# --- Find its windows ----------------------------------------------------

# Prints the ids of the windows the process has on screen, largest first.
# Exit codes: 3 no Screen Recording permission, 4 the app quit, 5 no window
# appeared in time.
cat >"$WORK_DIR/windows.swift" <<'SWIFT'
import CoreGraphics
import Foundation

let processID = Int32(CommandLine.arguments[1])!
let timeout = Double(CommandLine.arguments[2])!

guard CGPreflightScreenCaptureAccess() else { exit(3) }

func windows() -> [(id: Int, area: Double)] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return list.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? Int32) == processID,
              let id = window[kCGWindowNumber as String] as? Int,
              let bounds = window[kCGWindowBounds as String] as? [String: Double],
              let width = bounds["Width"], let height = bounds["Height"],
              width > 1, height > 1,
              (window[kCGWindowAlpha as String] as? Double ?? 1) > 0
        else { return nil }
        return (id, width * height)
    }
}

let deadline = Date().addingTimeInterval(timeout)
while windows().isEmpty {
    if kill(processID, 0) != 0 { exit(4) }
    if Date() > deadline { exit(5) }
    Thread.sleep(forTimeInterval: 0.1)
}

// A window is listed before it has finished appearing, and a view opened by
// a launch argument can follow a moment after the main window.
Thread.sleep(forTimeInterval: 1.5)

for window in windows().sorted(by: { $0.area > $1.area }) {
    print(window.id)
}
SWIFT

WINDOW_IDS="$(swift "$WORK_DIR/windows.swift" "$APP_PID" "$WINDOW_TIMEOUT_SECONDS" 2>"$WORK_DIR/windows.log")"
case $? in
  0) ;;
  3) permission_missing ;;
  4) tail -n 20 "$BUILD_DIR/app.log" >&2
     fail "$APP_NAME quit before it showed a window, its output is in $BUILD_DIR/app.log" ;;
  5) fail "$APP_NAME showed no window within $WINDOW_TIMEOUT_SECONDS seconds" ;;
  *) cat "$WORK_DIR/windows.log" >&2
     fail "could not list the windows of $APP_NAME" ;;
esac
[ -n "$WINDOW_IDS" ] || fail "$APP_NAME closed its windows before they could be saved"

# --- Save the pictures ---------------------------------------------------

mkdir -p "$(dirname "$OUTPUT")" || fail "could not create the folder for $OUTPUT"
case "$OUTPUT" in
  *.*) OUTPUT_STEM="${OUTPUT%.*}"; OUTPUT_SUFFIX=".${OUTPUT##*.}" ;;
  *) OUTPUT_STEM="$OUTPUT"; OUTPUT_SUFFIX="" ;;
esac

count=0
for window_id in $WINDOW_IDS; do
  count=$((count + 1))
  if [ "$count" -eq 1 ]; then
    file="$OUTPUT"
  else
    file="$OUTPUT_STEM-$count$OUTPUT_SUFFIX"
  fi
  rm -f "$file"
  # -x: no camera sound. -o: no window shadow, so the picture is the window
  # alone. -t png: a PNG whatever the file is called.
  if ! screencapture -x -o -t png -l "$window_id" "$file" 2>"$WORK_DIR/capture.log" || [ ! -s "$file" ]; then
    cat "$WORK_DIR/capture.log" >&2
    fail "could not save window $window_id. If the Screen Recording permission was just changed for \"$(host_app)\", restart that app and run this again."
  fi
  echo "$file"
done

quit_app
say "saved $count window(s) and quit $APP_NAME"
