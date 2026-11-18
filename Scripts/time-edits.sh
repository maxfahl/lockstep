#!/bin/bash
# Measures how fast edits are in the big test project, several runs in a row, and makes one table of them.
#
#   Scripts/time-edits.sh [--app <Lockstep.app>] [--runs <n>] [--song <file>] <folder>
#
# Each run starts the built app behind the other windows with a fresh scratch folder under <folder>/work,
# `-silent -bigProject -timeEdits`, waits until the edits are timed (about five minutes), and ends the app
# by its process id. What a run printed is kept in <folder>/run-<n>.txt, and the table of all runs is
# written to <folder>/TABLE.md and printed. Builds nothing: build the app first.
#
# --app   the app to measure. Left out: build/DerivedData/Build/Products/Debug/Lockstep.app
# --runs  how many runs. Left out: 3
# --song  a song to open. Left out, a song of three and a half minutes with a plain drum beat at 120 beats
#         a minute is made in <folder>/song.wav, the same every time.
#
# A window that is covered completely by other windows is not drawn, and the run then says "window hidden":
# its "window drawn" holds no drawing. The table says how many runs were hidden.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Debug/Lockstep.app"
RUNS=3
SONG=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --song) SONG="$2"; shift 2 ;;
    *) OUT="$1"; shift ;;
  esac
done
[ -n "$OUT" ] || { echo "usage: Scripts/time-edits.sh [--app <Lockstep.app>] [--runs <n>] [--song <file>] <folder>" >&2; exit 64; }
[ -d "$APP" ] || { echo "no app at $APP: build it first" >&2; exit 66; }
mkdir -p "$OUT/work"
OUT="$(cd "$OUT" && pwd)"

if [ -z "$SONG" ]; then
  SONG="$OUT/song.wav"
  [ -f "$SONG" ] || /usr/bin/python3 - "$SONG" <<'PY'
import math, random, struct, sys, wave
rate, seconds, beat = 48000, 210, 0.5
count = rate * seconds
sound = [0.0] * count
random.seed(7)
def add(start, length, shape):
    first = int(start * rate)
    for index in range(int(length * rate)):
        if first + index >= count:
            break
        sound[first + index] += shape(index / rate)
time, number = 0.0, 0
while time < seconds - 1:
    loud = 0.7 if number % 4 == 0 else 0.5
    add(time, 0.18, lambda x, loud=loud: loud * math.sin(2 * math.pi * (55 + 90 * math.exp(-x * 30)) * x) * math.exp(-x * 18))
    if number % 4 in (1, 3):
        add(time, 0.12, lambda x: 0.35 * (random.random() * 2 - 1) * math.exp(-x * 30))
    add(time + beat / 2, 0.04, lambda x: 0.15 * (random.random() * 2 - 1) * math.exp(-x * 90))
    if number % 4 == 0:
        note = [55, 65.4, 49, 73.4][(number // 4) % 4]
        add(time, beat * 3.5, lambda x, note=note: 0.12 * math.sin(2 * math.pi * note * x) * min(1, x * 50) * math.exp(-x * 0.6))
    time += beat
    number += 1
with wave.open(sys.argv[1], "wb") as file:
    file.setnchannels(1)
    file.setsampwidth(2)
    file.setframerate(rate)
    file.writeframes(b"".join(struct.pack("<h", max(-32767, min(32767, int(v * 26000)))) for v in sound))
PY
fi
[ -f "$SONG" ] || { echo "no song at $SONG" >&2; exit 66; }
# The app is started with another folder as its own, so it needs the whole path.
SONG="$(cd "$(dirname "$SONG")" && pwd)/$(basename "$SONG")"

PID=""
end_app() {
  [ -n "$PID" ] || return 0
  kill -TERM "$PID" 2>/dev/null
  for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
  kill -KILL "$PID" 2>/dev/null
  PID=""
}
trap end_app EXIT

for RUN in $(seq 1 "$RUNS"); do
  SCRATCH="$OUT/work/run-$RUN"
  LOG="$OUT/run-$RUN.txt"
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"; : > "$LOG"
  open -g -n --stdout "$LOG" --stderr "$LOG" "$APP" --args -scratch "$SCRATCH" -open "$SONG" -silent -bigProject -timeEdits
  sleep 3
  PID="$(pgrep -f -- "-scratch $SCRATCH" | head -1)"
  if [ -z "$PID" ]; then echo "run $RUN: the app did not start" >&2; continue; fi
  for SECOND in $(seq 1 900); do
    grep -qE "Lockstep: (timed the edits|could not (build|time))" "$LOG" && break
    kill -0 "$PID" 2>/dev/null || { echo "run $RUN: the app was gone before the edits were timed" >&2; break; }
    # The beats are found within a minute or so. A run that has said nothing by then never opened the song.
    if [ "$SECOND" -eq 180 ] && ! grep -q "^Lockstep: " "$LOG"; then
      echo "run $RUN: the app said nothing in three minutes, so the song was not opened" >&2; break
    fi
    sleep 1
  done
  end_app
  # The scratch project is only for this run.
  rm -rf "$SCRATCH"
  echo "run $RUN: $(grep -c "ms at the longest" "$LOG") edits timed"
  sleep 5
done
rmdir "$OUT/work" 2>/dev/null

/usr/bin/python3 - "$OUT" "$APP" <<'PY' | tee "$OUT/TABLE.md"
import glob, os, re, sys
out, app = sys.argv[1], sys.argv[2]
rows, order, hidden, runs, built = {}, [], 0, 0, []
for path in sorted(glob.glob(os.path.join(out, "run-*.txt"))):
    runs += 1
    zoom = ""
    for line in open(path, errors="replace"):
        if not line.startswith("Lockstep: "):
            continue
        line = line[len("Lockstep: "):].strip()
        if line.startswith("built the big project"):
            built.append(line)
        header = re.match(r"will time edits of .*, with (.*) in the window \(.*window (\w+)\)", line)
        if header:
            zoom = header.group(1)
            hidden += header.group(2) == "hidden"
            continue
        edit = re.match(r"(.*?) \((\d) of (\d)(, while the song plays)?\): (.*)\. In the second after, the main thread worked ([\d.]+) ms, ([\d.]+) ms at the longest", line)
        if not edit:
            continue
        name, playing, steps = edit.group(1), bool(edit.group(4)), edit.group(5)
        marks = [(m.group(1), float(m.group(2))) for m in re.finditer(r"(?:^|, )(.*?) after ([\d.]+) ms", steps)]
        names = [m[0] for m in marks]
        drawn = names.index("window drawn")
        first, later = marks[:drawn], marks[drawn + 1:]
        def share(step):
            # How long the step itself took, every time it was made before the window was drawn.
            total, before = 0.0, 0.0
            for mark, at in first:
                if mark == step:
                    total += at - before
                before = at
            return total
        done = first[-1][1] if first else 0.0
        passes, pass_time, started = 0, 0.0, None
        for mark, at in later:
            if mark == "later pass for remade sounds started":
                started = at
            elif mark == "later pass done" and started is not None:
                passes += 1
                pass_time += at - started
                started = None
        values = [
            share("project changed"), share("tightened sounds gone through"), share("rows made"),
            share("feels shown") + share("markers shown"), share("words shown"),
            share("rows handed to the window") + share("takes shown") + share("Send panel followed"),
            done, marks[drawn][1], dict(marks).get("player has the clips", 0.0),
            float(passes), pass_time, float(edit.group(6)), float(edit.group(7)),
        ]
        key = (zoom, "song playing" if playing else "song stopped", name)
        if key not in rows:
            rows[key] = []
            order.append(key)
        rows[key].append(values)
print(f"# Edits timed in the big test project\n")
print(f"App: `{app}`. Runs: {runs}, of them with the window hidden at a zoom's start: {hidden} of {runs * 2} starts.\n")
for line in built:
    print(f"- {line}")
print("\nMilliseconds, the mean of every time the edit was made (twice a run with the song stopped, once with it playing).")
print("The first six columns are how long that step itself took. \"Done\", \"window drawn\" and \"player\" count from the start of the edit.")
print("\"Later passes\" is how many times the clips were handed over again within the second after the window was drawn, and how long those took together.")
print("\"Work after\" is how long the main thread worked in the second after the window was drawn, and \"longest\" the longest stretch of it.\n")
heads = ["edit", "n", "project changed", "tightened sounds", "rows made", "feels and markers", "words", "window, takes, Send",
         "done", "window drawn", "player has the clips", "later passes", "their time", "work after", "longest"]
last = None
for key in order:
    if key[:2] != last:
        last = key[:2]
        print(f"\n## {key[0]}, {key[1]}\n")
        print("| " + " | ".join(heads) + " |")
        print("|" + "|".join(["---"] + ["---:"] * (len(heads) - 1)) + "|")
    lists = rows[key]
    means = [sum(v[i] for v in lists) / len(lists) for i in range(len(lists[0]))]
    cells = [f"{m:.1f}" if i == 9 else f"{m:.0f}" for i, m in enumerate(means)]
    print(f"| {key[2]} | {len(lists)} | " + " | ".join(cells) + " |")
PY
