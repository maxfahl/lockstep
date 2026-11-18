#!/usr/bin/env python3
"""The part of Scripts/same-behaviour.sh that reads and compares. Only that script calls it.

    normalize.py make-set <work folder> <set folder> --root <checkout> --app <app> --runs "<names>" --seconds <n>
    normalize.py compare <set of before> <set of now> --runs "<names>"
    normalize.py select-pieces <project folder>
    normalize.py list-files <scratch folder>

make-set turns what the runs left in the work folder (standard error, copies of project.json and
view.json after each step, the scratch folders) into a set: text files in which everything that
differs between two runs of the same app has been made the same or moved to `not-compared/`.
What is done to each kind of file is in RULES below, and is written into the set's SUMMARY.txt.

compare lists the files of two sets that differ, run by run, with the first lines of the first
difference, then the three counts and the speeds side by side. It exits with 1 when something
that is compared differs.

select-pieces writes the view.json between the two starts of the menu run by hand.
"""

import argparse
import difflib
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

UUID = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
NUMBER = re.compile(r"-?\d+(?:\.\d+)?")
COUNTS = re.compile(
    r"^Lockstep: counted (\d+) writes of what the window shows, (\d+) orders to the player, "
    r"(\d+) times the window was worked out$"
)

# What each run was started with, for SUMMARY.txt. The script has the same list in its run_ functions.
WHAT_RUNS_DO = {
    "long": "-open beatref.wav -addTake voice-a.wav -addTake voice-b.wav -addTake voice-c.wav@20 "
            "-clipText \"one two three\" -playhead 21.5 -clickFile <scratch>/click.wav -sendClip <scratch>/sent.wav "
            "-strength 70 -tighten -stretch -pasteClip",
    "loop": "-open beatref.wav -playhead 12.1 -loop 4.9,9.7 -loopTake voice-long.wav",
    "take": "-open beatref.wav -playhead 4.9 -recordTake voice-long.wav",
    "looptake": "-open beatref.wav -playhead 4.9 -loop 4.9,7.3 -recordTake voice-long.wav",
    "menu": "start 1: -open beatref.wav -addTake voice-a.wav -addTake voice-b.wav -addTake voice-c.wav@20 "
            "-addTake voice-long.wav@30 -playhead 2.5, then Edit > Split at Playhead, Next Clip twice, Delete, "
            "Zoom In, Zoom Out. A view.json written by hand selects both pieces of the cut line, and the scratch "
            "settings get animations off. start 2: -open <the project>, then the menu commands listed in "
            "menu/presses.txt (all of both starts, in order)",
    "reopen": "start 1: -open beatshort.wav. start 2: -open <a copy of the project \"long\" saved>, then "
              "File > Open Recent > beatshort, Track > New Track, File > Open Recent > beatref",
    "delete": "-open beatref.wav -addTake voice-a.wav -addTake voice-b.wav -deleteClip",
    "drag": "-open beatref.wav -addTake voice-a.wav -middleDrag",
}

# Runs whose lines come in an order the clock decides: their lines are compared sorted.
SORTED_RUNS = {"long", "loop", "menu", "reopen", "delete", "drag"}

# In a take the recorder stamps each block with the moment it arrived, so where a clip lands
# differs by some milliseconds from run to run. These are made the same in the two take runs.
TAKE_RUNS = {"take", "looptake"}
TAKE_LINE_MASKS = [
    (re.compile(r"became a clip from \d+\.\d+ s to \d+\.\d+ s"), "became a clip from <place> to <place>"),
    (re.compile(r"at sample \d+ of the song"), "at sample <place> of the song"),
    (re.compile(r"and \d+ samples long"), "and <length> samples long"),
]
# Keys of project.json and view.json whose value the clock decides, by run. In a take: where the
# recording starts in the song, and where the playhead stood when Stop was pressed. In the two speed
# runs the song is playing when the run ends.
WAVERING_KEYS = {
    "take": {"rawStart", "playheadSeconds"},
    "looptake": {"rawStart", "playheadSeconds"},
    "delete": {"playheadSeconds"},
    "drag": {"playheadSeconds"},
}
# Keys that are the sum of many small moves and differ in their last digits. Kept to a millionth.
ROUNDED_KEYS = {"drag": {"scrollOffsetSeconds"}}

# Which lines of a list of the menus are kept. Transport, Song, Track, Clip and Debug are Lockstep's own
# menus and are kept whole. File, Edit and View are the system's, with Lockstep's commands put into them:
# only those are kept, by how their titles begin (Undo and Delete go on with what they act on). macOS
# adds items of its own there (Close, Enter Full Screen, and AutoFill, which turned up in the middle of
# one run and not of another), and whether those can act depends on the window and the screens, not on
# the project. The Window and Help menus are left out for the same reason.
OWN_MENUS = ("Transport", "Song", "Track", "Clip", "Debug")
OWN_ITEMS = {
    "File": ("Open...", "Open Recent", "Create Click Track...", "Send to DaVinci..."),
    "Edit": ("Undo", "Redo", "Cut", "Copy", "Paste", "Select All", "Delete", "Snapping", "Snap To",
             "Split at Playhead", "Join Clips", "Clear Marked Stretch"),
    "View": ("Zoom In", "Zoom Out", "Zoom to Fit", "Taller Tracks", "Lower Tracks"),
}

# The lines of the two speed runs that are timings. Their numbers are kept in not-compared/speed.txt.
SPEED_LINE = re.compile(r"^Lockstep: (selected the clip|deleted the clip|brought the clip back with Undo|dragged |deleting the clip|dragging )")

# Files of a scratch folder whose bytes hold a path, a date or ids, and so are listed by name only.
# What is in them is compared as text in a file of its own.
LISTED_BY_NAME = {"Settings.plist", "project.json", "view.json", "clips.lua"}

RULES = """\
What is compared, and what was done to it first
- Standard error: only the lines that start with "Lockstep: ". The folder of the run reads <scratch>, the
  checkout <root>. Lines of macOS itself (the first line about ApplePersistenceIgnoreState, anything Core
  Audio says) are in not-compared/other-lines.txt.
- The lines of the runs long, loop, menu, reopen, delete and drag are sorted, because lines that are printed
  when background work ends (beats found, a click file written, a clip sent) come in the order the clock
  decides. The lines of take and looptake are in the order they were printed: there the order is the point.
- take and looptake: where a clip landed ("became a clip from X s to Y s", "at sample N of the song") and a
  length that follows from the place ("and N samples long") read <place> and <length>. In project.json the
  rawStart of each recording, and in view.json the playhead, read "<wavers>". The recorder stamps a block
  with the moment it arrived, so these differ by some milliseconds between two runs of the same app. The
  order of the lines, the samples each attempt held, the take numbers, the undo steps, the clips' own
  numbers and the checksums of the recorded files are compared.
- delete and drag: the playhead in view.json reads "<wavers>", because the song is playing when they end.
  In drag the timeline's place (scrollOffsetSeconds) is kept to a millionth of a second.
- project.json and view.json: keys sorted, every id replaced by ID-001, ID-002 and so on in the order it
  first appears in the run, so the same id reads the same in every file of the run. The ids of the selected
  clips in view.json are sorted.
- The scratch folder after each Quit: every file with its size and a checksum of its bytes
  (files-after-start-N.txt), ids in names replaced as above. project.json, view.json, Settings.plist and
  DaVinci/clips.lua are listed by name only and compared as text (end/, settings.txt, clips.lua). The first
  start of menu ends with a deleted clip, so its list shows that closing a project removes the files of a
  recording no clip uses.
- The menus (steps/NN-menus-*.txt): every command of Transport, Song, Track, Clip and Debug, and
  Lockstep's own commands in File, Edit and View, with "off" when it is greyed out and "ticked" when it is,
  the titles as they read at that moment (Undo and Redo name the edit, Delete says what it deletes, Merge
  Into and Open Recent list their choices). The Window and Help menus and what macOS puts into File, Edit
  and View (Close, AutoFill, Enter Full Screen) are left out. A command added to File, Edit or View later
  has to be added to OWN_ITEMS in normalize.py to be listed.
- presses.txt: what each press of a menu command answered ("pressed" or "off").
- problems.txt: empty unless something did not happen (a line waited for in vain, an app that did not quit).
- counts.txt: the line of three counts the app prints at Quit, shown apart from the rest. They are less
  steady than the files. How often what the window shows was written, and how many orders the player was
  told, were the same in ten sets of one build for loop, take, looptake, delete and the first start of
  menu, and must be the same there. So must the orders of drag and of the first start of reopen, whose
  writes differed by one. In long and in the second starts of menu and reopen both differed between sets
  of the same build, by up to 3 writes and up to 5 orders: there a difference inside what was seen is
  called "wavers" and is no difference. So one extra write in long would not show; ten extra would. How often the
  window was worked out is not steady at all (14 to 78 in the starts of reopen, 83 to 105 in long): it
  counts as a difference only when it is more than twice the count before plus 40, or less than half of
  the count before less 40. It is there to show a window that works itself out hundreds of times.
- menu: the second start runs with animations off (general.animationSpeed in the scratch folder's own
  settings), so the zoom and the place of the timeline after a command are where the command sends them.
  With animations on, the timeline of a window that lies behind others stops part of the way at a place
  the clock decides. The first start ends with a Zoom In and a Zoom Out with animations on, of which
  nothing is kept: it only runs the code that glides.

What is not compared
- not-compared/speed.txt of the runs delete and drag: the timings, as printed. In the compared lines every
  number of a timing line reads #. A comparison shows the timings of both sets side by side to look at.
- not-compared/other-lines.txt: what macOS printed.
- The dates and the process ids, which are only in lines of macOS.

What a set depends on besides the app
- The Mac: the size of the window decides how wide the timeline is, and so the zoom that "fit" gives
  (pointsPerSecond in view.json). A set made on another screen arrangement can differ there.
- Nobody touching the scratch windows. The app is started behind the other apps. If its window is clicked,
  it takes the keys typed after that. The script notices the app in front, says DISTURBED in problems.txt
  and makes that run again, twice at most.
- The beat model at ~/Library/Application Support/Lockstep/Models and the two songs and four voices in the
  repository.

What no run reaches
- A take through the real microphone and its place against the clock, anything done with the pointer (drags
  of clips, of the loop, of beats, a click in the ruler), the settings window, the sheets (Send to DaVinci,
  Calibrate Delay), the panels of Open and Create Click Track, typing a name (Rename Track, Rename Clip),
  the speech model (never loaded with -silent), a sound device that comes or goes, and sound that is heard:
  -silent plays to nowhere.
"""


def sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()[:16]


class Ids:
    """One run's ids, numbered in the order they are first seen."""

    def __init__(self):
        self.names = {}

    def learn(self, text):
        def name(match):
            key = match.group(0).upper()
            if key not in self.names:
                self.names[key] = f"ID-{len(self.names) + 1:03d}"
            return self.names[key]
        return UUID.sub(name, text)

    def known(self, text):
        """For names of files: an id no project file named is not numbered, since nothing orders it."""
        return UUID.sub(lambda match: self.names.get(match.group(0).upper(), "ID-unnamed"), text)


class Places:
    """The folders of one run, longest first, and what they read in a set."""

    def __init__(self, scratch, root):
        pairs = []
        for folder, name in ((scratch, "<scratch>"), (root, "<root>"), (Path.home(), "<home>")):
            for spelling in {str(folder), str(Path(folder).resolve())}:
                pairs.append((spelling, name))
                pairs.append(("/private" + spelling, name))
        self.pairs = sorted(set(pairs), key=lambda pair: -len(pair[0]))

    def hide(self, text):
        for folder, name in self.pairs:
            text = text.replace(folder, name)
        return re.sub(r"/(?:private/)?var/folders/[^ ]*?/T/", "<tmp>/", text)


def mask_keys(value, wavering, rounded):
    if isinstance(value, dict):
        return {
            key: "<wavers>" if key in wavering
            else round(inner, 6) if key in rounded and isinstance(inner, float)
            else mask_keys(inner, wavering, rounded)
            for key, inner in value.items()
        }
    if isinstance(value, list):
        return [mask_keys(inner, wavering, rounded) for inner in value]
    return value


def menus_text(text):
    """A list of the menus with only Lockstep's own commands."""
    kept = []
    for line in text.splitlines():
        menu, _, item = line.partition(" > ")
        if menu in OWN_MENUS or item.startswith(OWN_ITEMS.get(menu, ())) and menu in OWN_ITEMS:
            kept.append(line)
    return "\n".join(kept) + "\n"


def json_text(path, ids, places, run):
    """A project.json or view.json as it is compared."""
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        return f"could not be read: {type(error).__name__}\n"
    value = mask_keys(value, WAVERING_KEYS.get(run, set()), ROUNDED_KEYS.get(run, set()))
    text = ids.learn(json.dumps(value, indent=1, sort_keys=True, ensure_ascii=False))
    value = json.loads(text)
    if isinstance(value, dict) and isinstance(value.get("selectedClipIDs"), list):
        value["selectedClipIDs"].sort()
        text = json.dumps(value, indent=1, sort_keys=True, ensure_ascii=False)
    return places.hide(text) + "\n"


def printed_lines(raw, ids, places, run):
    """Standard error of every start of a run: the compared lines, the counts, the speeds, the rest."""
    compared, counts, speed, other = [], [], [], []
    for log in sorted(raw.glob("stderr-*.txt")):
        start = log.stem.split("-")[1]
        ours = []
        for line in log.read_text(errors="replace").splitlines():
            line = places.hide(line)
            if not line.startswith("Lockstep: "):
                other.append(f"start {start}: {line}")
                continue
            if COUNTS.match(line):
                counts.append(f"start {start}: {line[len('Lockstep: '):]}")
                continue
            line = ids.learn(line)
            if run in TAKE_RUNS:
                for pattern, name in TAKE_LINE_MASKS:
                    line = pattern.sub(name, line)
            if SPEED_LINE.match(line):
                speed.append(f"start {start}: {line}")
                line = NUMBER.sub("#", line)
            ours.append(line)
        if run in SORTED_RUNS:
            ours.sort()
        compared.append(f"--- start {start} ---")
        compared.extend(ours)
    return compared, counts, speed, other


def settings_text(path, places):
    try:
        with open(path, "rb") as file:
            value = plistlib.load(file)
    except Exception as error:  # a scratch run that never wrote a setting has no file
        return f"no settings: {type(error).__name__}\n"
    return places.hide(json.dumps(value, indent=1, sort_keys=True, ensure_ascii=False, default=str)) + "\n"


def list_files(arguments):
    """Every file of a scratch folder with its size and a checksum, as it is right now. The script calls
    this after each Quit. Ids are still as they are: make-set numbers them."""
    scratch = Path(arguments.scratch)
    for path in sorted(scratch.rglob("*")):
        if not path.is_file():
            continue
        name = str(path.relative_to(scratch))
        print(name if path.name in LISTED_BY_NAME else f"{name}  {path.stat().st_size} bytes  {sha(path)}")
    return 0


def files_text(listing, ids):
    return "\n".join(sorted(ids.known(line) for line in listing.read_text().splitlines())) + "\n"


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def make_run(run, work, out, root):
    raw, scratch = work / run / "raw", work / run / "scratch"
    if not raw.is_dir():
        return
    ids, places = Ids(), Places(scratch, root)
    # The copies made after each step come first, in the order they were made, so ids are numbered
    # in the order the run made them.
    for step in sorted((raw / "steps").glob("*")):
        if step.name.endswith(".json"):
            write(out / run / "steps" / step.name, json_text(step, ids, places, run))
        else:
            write(out / run / "steps" / step.name, menus_text(places.hide(step.read_text(errors="replace"))))
    for project in sorted(scratch.glob("Projects/*.lockstep")):
        for name in ("project.json", "view.json"):
            if (project / name).exists():
                write(out / run / "end" / f"{project.stem}.{name}", json_text(project / name, ids, places, run))
    compared, counts, speed, other = printed_lines(raw, ids, places, run)
    write(out / run / "printed.txt", "\n".join(compared) + "\n")
    write(out / run / "counts.txt", "\n".join(counts) + "\n")
    write(out / run / "not-compared" / "other-lines.txt", "\n".join(other) + "\n")
    if speed:
        write(out / run / "not-compared" / "speed.txt", "\n".join(speed) + "\n")
    write(out / run / "presses.txt", (raw / "presses.txt").read_text() if (raw / "presses.txt").exists() else "")
    write(out / run / "problems.txt", places.hide((raw / "problems.txt").read_text()) if (raw / "problems.txt").exists() else "")
    lua = scratch / "DaVinci" / "clips.lua"
    if lua.exists():
        write(out / run / "clips.lua", places.hide(ids.learn(lua.read_text())))
    write(out / run / "settings.txt", settings_text(scratch / "Settings.plist", places))
    for listing in sorted(raw.glob("files-*.txt")):
        write(out / run / f"files-after-start-{listing.stem.split('-')[1]}.txt", files_text(listing, ids))


def git(root, *arguments):
    try:
        return subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def make_set(arguments):
    work, out, root = Path(arguments.work), Path(arguments.set), Path(arguments.root)
    runs = arguments.runs.split()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for run in runs:
        make_run(run, work, out, root)
    commit = git(root, "rev-parse", "--short", "HEAD") or "unknown"
    changed = " with uncommitted changes" if git(root, "status", "--porcelain", "--untracked-files=no") else ""
    lines = [
        "A set made by Scripts/same-behaviour.sh",
        "",
        f"Made: {datetime.now().strftime('%Y-%m-%d %H:%M')}, in {arguments.seconds} s",
        f"Checkout: {root} at commit {commit}{changed}",
        f"App: {arguments.app}",
        "(The commit is the checkout's. The script builds nothing, so the app is whatever was last built.)",
        "",
        "The runs, each started with -scratch <its own fresh folder> first and -silent last,",
        "and quit through the app's own Quit:",
    ]
    for run in runs:
        lines.append(f"- {run}: {WHAT_RUNS_DO[run]}")
    lines += ["", "The three counts at Quit (writes of what the window shows, orders to the player, times the window was worked out):"]
    for run in runs:
        for line in (out / run / "counts.txt").read_text().splitlines() if (out / run / "counts.txt").exists() else []:
            numbers = COUNTS.match("Lockstep: " + line.split(": ", 1)[1])
            lines.append(f"- {run}, {line.split(':')[0]}: " + (" / ".join(numbers.groups()) if numbers else line))
    problems = []
    for run in runs:
        text = (out / run / "problems.txt").read_text().strip() if (out / run / "problems.txt").exists() else "the run left nothing"
        problems += [f"- {run}: {line}" for line in text.splitlines()]
    lines += ["", "Problems while it was made:"] + (problems or ["- none"])
    lines += ["", RULES]
    write(out / "SUMMARY.txt", "\n".join(lines))
    if problems:
        print("same-behaviour: problems while the set was made:\n" + "\n".join(problems), file=sys.stderr)
    return 0


COUNT_NAMES = ("writes", "orders", "window")
# How far a count may be from the one before and still be what two runs of the same app give, by
# run and start. Found by making the set ten times from one build on 15 November 2026. Where nothing
# is listed the count was the same every time and has to be the same.
# - Writes of what the window shows: 119 to 122 in long, 206 to 208 in the second start of menu, 82 or
#   83 in the first start of reopen, 121 to 123 in its second, 108 or 109 in drag. These starts open a
#   project while other work goes on, or play the song: the progress of opening and the player coming
#   to rest are written once more or less.
# - Orders to the player: 12 to 17 in long, 88 to 93 in the second start of menu, 24 to 26 in the second
#   start of reopen. Background work (Lines, All, a clip sent, a project opened over another) ends in an
#   order the clock decides, which hands the clips to the player once more or less, and the song plays
#   for a time the clock measures.
WRITES_MAY_DIFFER_BY = {("long", 1): 3, ("menu", 2): 3, ("reopen", 1): 2, ("reopen", 2): 2, ("drag", 1): 1}
ORDERS_MAY_DIFFER_BY = {("long", 1): 5, ("menu", 2): 6, ("reopen", 2): 3}
COUNT_RULE = (
    "Writes and orders must be the same, except where two runs of the same app differ (\"wavers\"): writes by up "
    "to 3 in long and in the second start of menu, 2 in the starts of reopen and 1 in drag; orders by up to 5 in "
    "long, 6 in the second start of menu and 3 in the second start of reopen. A count that differs by one where it "
    "should be the same is worth one more run of that run alone (--only) before it is called a fault: ten runs are "
    "not many. How often the window is worked out differed between 14 and 78 in one start of ten runs of the same "
    "app, so it only counts as a difference when it is more than twice the count before plus 40, or less than half "
    "of the count before less 40: it is there to show a window that works itself out hundreds of times."
)


def read_counts(path):
    """The three numbers of each start of a run."""
    counts = []
    for line in path.read_text().splitlines() if path.exists() else []:
        match = COUNTS.match("Lockstep: " + line.split(": ", 1)[1])
        if match:
            counts.append(tuple(int(number) for number in match.groups()))
    return counts


def show_counts(counts):
    return "nothing" if counts is None else " / ".join(str(number) for number in counts)


def count_verdict(run, start, position, before, now):
    """Nothing when a count is as before, "DIFFERS" when it is not, "wavers" when it differs by no more
    than two runs of the same app do."""
    if before == now:
        return None
    if position == 2:
        return "wavers" if (before - 40) / 2 <= now <= 2 * before + 40 else "DIFFERS"
    allowed = (WRITES_MAY_DIFFER_BY, ORDERS_MAY_DIFFER_BY)[position].get((run, start), 0)
    return "wavers" if abs(now - before) <= allowed else "DIFFERS"


def compared_files(folder):
    if not folder.is_dir():
        return {}
    return {
        str(path.relative_to(folder)): path
        for path in sorted(folder.rglob("*"))
        if path.is_file() and "not-compared" not in path.parts and path.name != "counts.txt"
    }


def compare(arguments):
    before, now = Path(arguments.before), Path(arguments.now)
    runs = arguments.runs.split()
    report, differs = [], False
    report.append(f"Compared with {before}")
    for run in runs:
        old, new = compared_files(before / run), compared_files(now / run)
        if not old:
            report.append(f"\n{run}: the set compared with has no such run")
            differs = True
            continue
        changed = [name for name in sorted(set(old) | set(new))
                   if name not in old or name not in new or old[name].read_bytes() != new[name].read_bytes()]
        if not changed:
            report.append(f"\n{run}: the same ({len(new)} files)")
            continue
        differs = True
        report.append(f"\n{run}: {len(changed)} of {len(set(old) | set(new))} files differ")
        for name in changed[:12]:
            note = "" if name in old and name in new else ("  (only now)" if name in new else "  (only before)")
            report.append(f"  {name}{note}")
        if len(changed) > 12:
            report.append(f"  and {len(changed) - 12} more")
        first = next((name for name in changed if name in old and name in new), None)
        if first:
            diff = list(difflib.unified_diff(
                old[first].read_text(errors="replace").splitlines(), new[first].read_text(errors="replace").splitlines(),
                "before", "now", lineterm="", n=2,
            ))
            report.append(f"  The first of them, {first}:")
            report += ["    " + line[:300] for line in diff[2:42]]
            if len(diff) > 42:
                report.append(f"    and {len(diff) - 42} more lines")

    report.append("\nThe three counts at Quit (writes of what the window shows / orders to the player / times the window was worked out):")
    for run in runs:
        old, new = read_counts(before / run / "counts.txt"), read_counts(now / run / "counts.txt")
        for index in range(max(len(old), len(new))):
            a = old[index] if index < len(old) else None
            b = new[index] if index < len(new) else None
            if a is None or b is None:
                differs = True
                report.append(f"  {run}, start {index + 1}: DIFFERS, before: {show_counts(a)}, now: {show_counts(b)}")
                continue
            notes = []
            for position, name in enumerate(COUNT_NAMES):
                verdict = count_verdict(run, index + 1, position, a[position], b[position])
                if verdict:
                    notes.append(f"{name} {verdict}, before {a[position]}")
                    differs = differs or verdict == "DIFFERS"
            report.append(f"  {run}, start {index + 1}: {show_counts(b)}" + ("  " + "; ".join(notes) if notes else "  the same"))
    report.append("  " + COUNT_RULE)

    for run in runs:
        old, new = before / run / "not-compared" / "speed.txt", now / run / "not-compared" / "speed.txt"
        if old.exists() or new.exists():
            report.append(f"\nSpeed of {run}, not compared. Before:")
            report += ["  " + line[:400] for line in (old.read_text().splitlines() if old.exists() else ["nothing"])]
            report.append("Now:")
            report += ["  " + line[:400] for line in (new.read_text().splitlines() if new.exists() else ["nothing"])]

    report.append("\nRESULT: " + ("SOMETHING DIFFERS" if differs else "nothing that is compared differs"))
    text = "\n".join(report) + "\n"
    write(now / "COMPARISON.txt", text)
    print(text)
    return 1 if differs else 0


def select_pieces(arguments):
    """Selects the two pieces of the line that was cut: the two shown clips of the first track that play
    the same recording. The playhead goes to 1 s, inside the first piece, and the zoom back to "fit".
    Everything else in view.json stays as the app wrote it."""
    folder = Path(arguments.project)
    project = json.loads((folder / "project.json").read_text())
    track = project["tracks"][0]
    by_recording = {}
    for clip in track["clips"]:
        if clip.get("isActiveTake", True) and clip["segments"]:
            by_recording.setdefault(clip["segments"][0]["recordingID"], []).append(clip)
    pieces = next((clips for clips in by_recording.values() if len(clips) == 2), None)
    if pieces is None:
        print("no line of the first track is in two pieces", file=sys.stderr)
        return 1
    view = json.loads((folder / "view.json").read_text())
    view["selectedTrackID"] = track["id"]
    view["selectedClipIDs"] = [clip["id"] for clip in pieces]
    view["playheadSeconds"] = 1.0
    # The first start ends with a zoom that is not kept. Zero points per second means "fit".
    view["pointsPerSecond"] = 0
    view["scrollOffsetSeconds"] = 0
    (folder / "view.json").write_text(json.dumps(view, indent=2, sort_keys=True))
    return 0


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    making = commands.add_parser("make-set")
    making.add_argument("work")
    making.add_argument("set")
    making.add_argument("--root", required=True)
    making.add_argument("--app", required=True)
    making.add_argument("--runs", required=True)
    making.add_argument("--seconds", default="?")
    comparing = commands.add_parser("compare")
    comparing.add_argument("before")
    comparing.add_argument("now")
    comparing.add_argument("--runs", required=True)
    selecting = commands.add_parser("select-pieces")
    selecting.add_argument("project")
    listing = commands.add_parser("list-files")
    listing.add_argument("scratch")
    arguments = parser.parse_args()
    return {"make-set": make_set, "compare": compare, "select-pieces": select_pieces, "list-files": list_files}[arguments.command](arguments)


if __name__ == "__main__":
    sys.exit(main())
