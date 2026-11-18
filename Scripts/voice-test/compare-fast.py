#!/usr/bin/env python3
"""Compares the ways the Fast voice of phase 37 can be made, on the same lines, with the same tools, and
writes one table: the experiment that tried the Fast way on made-up speech.

    Scripts/voice-test/compare-fast.py                       everything, into build/voice-test/fast
    Scripts/voice-test/compare-fast.py --stage summary       only the table, from what is there
    Scripts/voice-test/compare-fast.py --ways world-harvest-5,rubberband --lines daniel-fast
    Scripts/voice-test/compare-fast.py --speech <folder> --out <folder>    on other lines (Max's own)

The ways are WORLD (Scripts/voice-test/shift.py) with each choice it offers, and Rubber Band
(Scripts/voice-test/shift-rb.sh, Lockstep's own VoiceShifter). Each line is made at no change, at the
three amounts of the design and, on the fast lines, at the four extremes, and every amount also there
and back. Then, stage by stage (each can be named with --stage, several with commas):

    make       the voices: <out>/<way>/<line>.d<depth>.p<pitch>.wav, and .back.wav there and back
    timing     Scripts/measure-timing.sh on every voice (the gate: displacement and corrected line)
    commute    Scripts/measure-commute.sh on every voice of the main settings, and on the extremes of
               the fast lines: <out>/<way>/commute/<line>.<setting>/
    closeness  Scripts/measure-voice.py, the recording against each voice and each there and back
    speed      seconds of work for each second of voice on 3, 10 and 60 seconds of a long line, and how
               long 3 seconds take from the start to the finished file
    listen     the fast lines at the three amounts by each way, as loud as the line, in <out>/listen
    summary    <out>/SUMMARY.md and <out>/summary.json

A file that is already there is not made again, so a run that was stopped goes on where it was;
--again makes everything anew. --jobs (4) says how many measurements run at once. The first stage that
measures builds LockstepKit's tests once. Nothing is played. Only the standard library is used here; the
tools it runs fetch their own packages with uv into build/uv-cache.
"""

import argparse
import json
import os
import re
import shlex
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "Scripts"

# Every choice step 1 of the task names, and the remedies tried for Daniel's creak.
WAYS = {
    "world-harvest-5": "",
    "world-harvest-2.5": "--frame-ms 2.5",
    "world-dio-5": "--f0 dio",
    "world-dio-2.5": "--f0 dio --frame-ms 2.5",
    "world-harvest-5-copy": "--copy-unvoiced",
    "world-harvest-2.5-copy": "--frame-ms 2.5 --copy-unvoiced",
    "world-harvest-5-floor40": "--f0-floor 40",
    "world-harvest-5-creak40": "--creak-floor 40",
    "world-harvest-5-fill30": "--fill-gaps-ms 30",
    "rubberband": None,
}
# The ways only tried on the fast lines: each failed a gate there at no change.
SCREENED = {"world-harvest-5-floor40", "world-harvest-5-creak40", "world-harvest-5-fill30"}

LINES = [f"{voice}-{kind}" for voice in ("daniel", "samantha") for kind in ("fast", "short", "gap", "long", "fast-sped-up")]
FAST_LINES = ["daniel-fast", "samantha-fast"]
NO_CHANGE = (0, 0)
AMOUNTS = [(3, -0.5), (6, -1), (10, -2)]
EXTREMES = [(15, 4), (15, -4), (-15, 4), (-15, -4)]
AMOUNT_NAMES = {(3, -0.5): "a little darker", (6, -1): "darker", (10, -2): "much darker"}


def number(value):
    return str(int(value)) if float(value) == int(value) else str(value)


def setting_name(setting):
    return f"d{number(setting[0])}.p{number(setting[1])}"


def opposite(setting):
    return (-setting[0], -setting[1])


def maker(way, setting, source="{in}", output="{out}"):
    """The command that makes the voice of one file by `way` at `setting`."""
    depth, pitch = setting
    if WAYS[way] is None:
        return f"Scripts/voice-test/shift-rb.sh {source} {output} --depth {number(depth)} --pitch {number(pitch)}"
    return (
        f"Scripts/voice-test/shift.py {source} {output} --depth {number(depth)} --pitch {number(pitch)} "
        + WAYS[way]
    ).strip()


def run(command, log=None):
    """Runs a command line from the checkout's root; its words go to `log`. Returns the exit code."""
    environment = dict(os.environ, UV_CACHE_DIR=str(ROOT / "build" / "uv-cache"))
    with open(log, "w") if log else open(os.devnull, "w") as out:
        return subprocess.run(command, shell=True, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, env=environment).returncode


def settings_of(line):
    return [NO_CHANGE] + AMOUNTS + (EXTREMES if line in FAST_LINES else [])


class Experiment:
    def __init__(self, arguments):
        self.speech = Path(arguments.speech).resolve()
        self.out = Path(arguments.out).resolve()
        self.ways = arguments.ways
        self.lines = arguments.lines
        self.jobs = arguments.jobs
        self.again = arguments.again

    def recording(self, line):
        return self.speech / f"{line}.wav"

    def voice(self, way, line, setting, back=False):
        return self.out / way / f"{line}.{setting_name(setting)}{'.back' if back else ''}.wav"

    def lines_of(self, way):
        return [line for line in self.lines if way not in SCREENED or line in FAST_LINES]

    def wanted(self, path):
        return self.again or not Path(path).exists()

    def parallel(self, jobs, what):
        jobs = list(jobs)
        started = time.time()
        print(f"{what}: {len(jobs)} to do", flush=True)
        with ThreadPoolExecutor(self.jobs) as pool:
            codes = list(pool.map(lambda job: job(), jobs))
        print(f"{what}: done in {time.time() - started:.0f} s", flush=True)
        return codes

    def build(self):
        log = self.out / "build.log"
        self.out.mkdir(parents=True, exist_ok=True)
        if run("swift build --package-path LockstepKit --build-tests", log) != 0:
            sys.exit(f"LockstepKit's tests did not build: see {log}")

    # MARK: The stages

    def make(self):
        def job(way, line, setting):
            def do():
                target = self.voice(way, line, setting)
                target.parent.mkdir(parents=True, exist_ok=True)
                if self.wanted(target):
                    code = run(maker(way, setting, shlex.quote(str(self.recording(line))), shlex.quote(str(target))),
                               target.with_suffix(".make.log"))
                    if code != 0:
                        return code
                if setting != NO_CHANGE and setting in AMOUNTS:
                    back = self.voice(way, line, setting, back=True)
                    if self.wanted(back):
                        return run(maker(way, opposite(setting), shlex.quote(str(target)), shlex.quote(str(back))),
                                   back.with_suffix(".make.log"))
                return 0
            return do

        codes = self.parallel(
            (job(way, line, setting) for way in self.ways for line in self.lines_of(way) for setting in settings_of(line)),
            "make",
        )
        if any(codes):
            sys.exit("Some voices could not be made: see the .make.log beside them.")

    def timing(self):
        def job(way, line):
            def do():
                voices = [self.voice(way, line, setting) for setting in settings_of(line)]
                if not any(self.wanted(voice.with_suffix(".timing.json")) for voice in voices):
                    return 0
                command = "Scripts/measure-timing.sh --no-build " + " ".join(
                    shlex.quote(str(path)) for path in [self.recording(line)] + voices
                )
                return run(command, self.out / way / f"{line}.timing.txt")
            return do

        self.parallel((job(way, line) for way in self.ways for line in self.lines_of(way)), "timing")

    def commute_settings(self, line):
        return [NO_CHANGE] + AMOUNTS + (EXTREMES if line in FAST_LINES else [])

    def commute(self):
        def job(way, line, setting):
            def do():
                folder = self.out / way / "commute" / f"{line}.{setting_name(setting)}"
                words = folder.parent / f"{folder.name}.txt"
                if not self.wanted(words):
                    return 0
                folder.parent.mkdir(parents=True, exist_ok=True)
                command = (
                    f"Scripts/measure-commute.sh --no-build --make {shlex.quote(maker(way, setting))} "
                    f"{shlex.quote(str(self.recording(line)))} {shlex.quote(str(self.voice(way, line, setting)))} "
                    f"{shlex.quote(str(folder))}"
                )
                return run(command, words)
            return do

        self.parallel(
            (job(way, line, setting) for way in self.ways for line in self.lines_of(way)
             for setting in self.commute_settings(line)),
            "commute",
        )

    def closeness(self):
        def job(line, voice):
            def do():
                numbers = voice.with_suffix(".voice.json")
                if not self.wanted(numbers):
                    return 0
                ceiling = "5500" if line.startswith("samantha") else "5000"
                command = (
                    f"Scripts/measure-voice.py --formant-ceiling {ceiling} --json {shlex.quote(str(numbers))} "
                    f"{shlex.quote(str(self.recording(line)))} {shlex.quote(str(voice))}"
                )
                return run(command, voice.with_suffix(".voice.txt"))
            return do

        jobs = []
        for way in self.ways:
            for line in self.lines_of(way):
                for setting in settings_of(line):
                    jobs.append(job(line, self.voice(way, line, setting)))
                    if setting in AMOUNTS:
                        jobs.append(job(line, self.voice(way, line, setting, back=True)))
        self.parallel(jobs, "closeness")

    def speed(self):
        """One job at a time, so the numbers are not slowed by each other. Three runs of each, the middle
        one kept."""
        cuts = self.out / "speed"
        cuts.mkdir(parents=True, exist_ok=True)
        long_line = self.recording("daniel-long")
        for seconds in (3, 10, 60):
            cut = cuts / f"daniel-{seconds}s.wav"
            if not cut.exists():
                subprocess.run(["python3", "-c", TRIM, str(long_line), str(cut), str(seconds)], check=True)
        results = {}
        for way in self.ways:
            if way in SCREENED:
                continue
            results[way] = {}
            for seconds in (3, 10, 60):
                cut = cuts / f"daniel-{seconds}s.wav"
                works, walls = [], []
                for attempt in range(3):
                    output = cuts / f"{way}.{seconds}s.wav"
                    log = cuts / f"{way}.{seconds}s.log"
                    started = time.perf_counter()
                    run(maker(way, (6, -1), shlex.quote(str(cut)), shlex.quote(str(output))), log)
                    walls.append(time.perf_counter() - started)
                    said = log.read_text()
                    found = re.search(r"([0-9.]+) s of work for each second of voice", said)
                    to_file = re.search(r"([0-9.]+) s to the file", said)
                    if found:
                        works.append(float(found.group(1)))
                    if to_file:
                        walls[-1] = float(to_file.group(1))
                results[way][f"{seconds}s"] = {
                    "workPerSecond": statistics.median(works) if works else None,
                    "secondsToFile": statistics.median(walls),
                    "toFileIsProcess": WAYS[way] is not None,
                }
                print(f"speed {way} {seconds} s: {results[way][f'{seconds}s']}", flush=True)
        load = os.getloadavg()
        (self.out / "speed.json").write_text(json.dumps({"load": load, "ways": results}, indent=1) + "\n")

    def listen(self):
        folder = self.out / "listen"
        folder.mkdir(parents=True, exist_ok=True)
        jobs = []
        for way in self.ways:
            if way in SCREENED:
                continue
            for line in FAST_LINES:
                for setting in AMOUNTS:
                    name = AMOUNT_NAMES[setting].replace(" ", "-")
                    target = folder / f"{line}.{name}.{way}.wav"
                    source = self.voice(way, line, setting)
                    if self.wanted(target):
                        jobs.append(lambda s=source, t=target, l=line: run(
                            f"Scripts/voice-test/as-loud.py {shlex.quote(str(self.recording(l)))} "
                            f"{shlex.quote(str(s))} {shlex.quote(str(t))}"))
            for line in FAST_LINES:
                original = folder / f"{line}.0-the-line.wav"
                if not original.exists():
                    original.write_bytes(self.recording(line).read_bytes())
        self.parallel(jobs, "listen")

    def summary(self):
        write_summary(self)


TRIM = """
import sys, wave
source, target, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
with wave.open(source) as file:
    frames = file.readframes(int(seconds * file.getframerate()))
    parameters = file.getparams()
with wave.open(target, "wb") as file:
    file.setparams(parameters)
    file.writeframes(frames)
"""


# MARK: The table


def load(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def commute_verdicts(words):
    """From the words of measure-commute.sh: each way's verdict, the furthest start per way, and the
    spectra per way."""
    if not words.exists():
        return None
    text = words.read_text()
    found = {"passed": text.rstrip().endswith("passed"), "parts": {}}
    for way in ("lines", "all", "all-stretch"):
        timing = re.search(rf"^  {way}: \d+ places.*furthest where a sound starts ([0-9.]+) ms: (passed|FAILED)", text, re.M)
        spectra = re.search(rf"^  {way}: spectra ([0-9.]+) dB apart voiced, ([0-9.]+) dB consonants.*: (passed|FAILED)", text, re.M)
        found["parts"][way] = {
            "furthestStartMs": float(timing.group(1)) if timing else None,
            "timingPassed": timing.group(2) == "passed" if timing else None,
            "voicedDb": float(spectra.group(1)) if spectra else None,
            "consonantsDb": float(spectra.group(2)) if spectra else None,
            "spectraPassed": spectra.group(3) == "passed" if spectra else None,
        }
    return found


def write_summary(experiment):
    out = experiment.out
    table = {}
    for way in experiment.ways:
        entry = table[way] = {"timing": {}, "commute": {}, "closeness": {}}
        for line in experiment.lines_of(way):
            for setting in settings_of(line):
                key = f"{line}.{setting_name(setting)}"
                voice = experiment.voice(way, line, setting)
                gate = load(voice.with_suffix(".timing.json"))
                if gate:
                    entry["timing"][key] = {
                        "passed": gate["passed"],
                        "displacement": gate["gate"]["displacement"],
                        "correctedLine": gate["gate"]["correctedLine"],
                    }
                verdict = commute_verdicts(out / way / "commute" / f"{key}.txt")
                if verdict:
                    entry["commute"][key] = verdict
                close = load(voice.with_suffix(".voice.json"))
                if close:
                    entry["closeness"][key] = close
                if setting in AMOUNTS:
                    back = load(experiment.voice(way, line, setting, back=True).with_suffix(".voice.json"))
                    if back:
                        entry["closeness"][key + ".back"] = back
    speed = load(out / "speed.json")
    (out / "summary.json").write_text(json.dumps({"ways": table, "speed": speed}, indent=1) + "\n")
    (out / "SUMMARY.md").write_text(words_of(experiment, table, speed))
    print(f"The table is in {out / 'SUMMARY.md'}")


def mean(values):
    values = [value for value in values if value is not None]
    return statistics.mean(values) if values else None


def worst(values):
    values = [value for value in values if value is not None]
    return max(values) if values else None


def show(value, places=1):
    return "–" if value is None else f"{value:.{places}f}"


def words_of(experiment, table, speed):
    said = ["# The Fast way on made-up speech: the ways compared", ""]
    said.append(
        "Written by Scripts/voice-test/compare-fast.py. Timing: Scripts/measure-timing.sh (displacement at the "
        "recording's places, and the corrected line); commutation: Scripts/measure-commute.sh (Lines, All, All "
        "with Stretch); closeness: Scripts/measure-voice.py. Settings are d<Depth>.p<Pitch>."
    )
    said.append("")
    said.append("## The gate")
    said.append("")
    said.append("| Way | Timing passed | Commutation passed | Furthest start, line / corrected (ms) | Failed |")
    said.append("|---|---|---|---|---|")
    for way, entry in table.items():
        timing, commute = entry["timing"], entry["commute"]
        timing_failed = [key for key, value in timing.items() if not value["passed"]]
        commute_failed = [key for key, value in commute.items() if not value["passed"]]
        furthest_line = worst(value["displacement"].get("furthestStartMs") for value in timing.values())
        furthest_corrected = worst(value["correctedLine"].get("furthestStartMs") for value in timing.values())
        failed = [f"timing {key}" for key in timing_failed] + [
            f"commute {key} ({', '.join(part for part, value in commute[key]['parts'].items() if value['timingPassed'] is False or value['spectraPassed'] is False)})"
            for key in commute_failed
        ]
        said.append(
            f"| {way} | {len(timing) - len(timing_failed)} of {len(timing)} | {len(commute) - len(commute_failed)} of "
            f"{len(commute)} | {show(furthest_line)} / {show(furthest_corrected)} | "
            f"{'; '.join(failed[:12]) + (' …' if len(failed) > 12 else '') or 'none'} |"
        )
    said.append("")
    said.append("## Closeness (means over the lines; dB of spectral distance, lower is closer)")
    said.append("")
    said.append(
        "| Way | No change voiced / consonants | Pauses, voice minus recording (dB) | There and back voiced / consonants: "
        "a little darker, darker, much darker | Line-sized stretches, furthest off (dB) |"
    )
    said.append("|---|---|---|---|---|")
    for way, entry in table.items():
        close = entry["closeness"]
        same = [value for key, value in close.items() if ".d0.p0" in key]
        pause = mean(
            (value["pauses"]["bDbfs"] - value["pauses"]["aDbfs"])
            for value in same if value["pauses"]["aDbfs"] is not None and value["pauses"]["bDbfs"] is not None
        )
        backs = []
        for setting in AMOUNTS:
            values = [value for key, value in close.items() if key.endswith(f".{setting_name(setting)}.back")]
            backs.append(f"{show(mean(v['spectra']['voicedDb'] for v in values))} / {show(mean(v['spectra']['consonantsDb'] for v in values))}")
        stretches = worst(
            value["loudness"]["stretchesFurthest"] for key, value in close.items() if not key.endswith(".back")
        )
        said.append(
            f"| {way} | {show(mean(v['spectra']['voicedDb'] for v in same))} / "
            f"{show(mean(v['spectra']['consonantsDb'] for v in same))} | {show(pause)} | {', '.join(backs)} | {show(stretches, 2)} |"
        )
    said.append("")
    said.append("## What the knobs did (means over the lines: formants F1, F2, F3 in percent, pitch in semitones)")
    said.append("")
    said.append("| Way | " + " | ".join(f"{AMOUNT_NAMES[s]} ({setting_name(s)})" for s in AMOUNTS) + " |")
    said.append("|---|---|---|---|")
    for way, entry in table.items():
        cells = []
        for setting in AMOUNTS:
            values = [value for key, value in entry["closeness"].items() if key.endswith(f".{setting_name(setting)}")]
            formants = [mean(v["formants"]["changePercent"][n] for v in values) for n in range(3)]
            pitch = mean(v["pitch"]["semitones"] for v in values)
            cells.append(f"{', '.join(show(f) for f in formants)}; {show(pitch, 2)} st")
        said.append(f"| {way} | " + " | ".join(cells) + " |")
    if speed:
        said.append("")
        said.append(
            f"## Speed (Darker; seconds of work for each second of voice; load average {', '.join(f'{v:.1f}' for v in speed['load'])})"
        )
        said.append("")
        said.append("| Way | 3 s | 10 s | 60 s | 3 s from the start to the file (s) |")
        said.append("|---|---|---|---|---|")
        for way, numbers in speed["ways"].items():
            said.append(
                f"| {way} | " + " | ".join(show(numbers[f"{s}s"]["workPerSecond"], 3) for s in (3, 10, 60))
                + f" | {show(numbers['3s']['secondsToFile'], 2)} |"
            )
    said.append("")
    return "\n".join(said)


def main():
    parser = argparse.ArgumentParser(description="Compares the ways of making the Fast voice.")
    parser.add_argument("--speech", default=str(ROOT / "build" / "voice-test" / "speech"))
    parser.add_argument("--out", default=str(ROOT / "build" / "voice-test" / "fast"))
    parser.add_argument("--ways", default=",".join(WAYS))
    parser.add_argument("--lines", default=",".join(LINES))
    parser.add_argument("--stage", default="make,timing,commute,closeness,speed,listen,summary")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--again", action="store_true")
    arguments = parser.parse_args()
    arguments.ways = [way for way in arguments.ways.split(",") if way]
    arguments.lines = [line for line in arguments.lines.split(",") if line]
    for way in arguments.ways:
        if way not in WAYS:
            sys.exit(f"There is no way {way}. The ways: {', '.join(WAYS)}")
    experiment = Experiment(arguments)
    stages = arguments.stage.split(",")
    if any(stage in stages for stage in ("timing", "commute", "make")):
        experiment.build()
    for stage in stages:
        getattr(experiment, stage)()


if __name__ == "__main__":
    main()
