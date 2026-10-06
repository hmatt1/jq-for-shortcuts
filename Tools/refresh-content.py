#!/usr/bin/env python3
"""Recomputes the expected output stored with every Playground sample, preset,
cheat sheet example and gallery filter in App/Resources, by running each one
through real jq 1.7.1.

The engine's ContentFixtureTests and the app's AppLogicTests compare the
engine's output with these values on every CI run (design R9.13), so a
content edit that changes an example's result shows up as a test failure
until this script is run again.

Usage:
    python3 Tools/refresh-content.py [path/to/jq]        # rewrite the files
    python3 Tools/refresh-content.py --check [path/to/jq] # fail if any is stale

Needs jq 1.7.1 on PATH (Ubuntu 24.04's jq package is 1.7.1, although its
`jq --version` prints "jq-1.7").
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "App" / "Resources"


def run_jq(jq, program, given, arguments=None):
    """Compact outputs and debug messages, exactly as jq 1.7.1 prints them."""
    command = [jq, "-c"]
    for name, value in json.loads(arguments).items() if arguments else []:
        command += ["--argjson", name, json.dumps(value, ensure_ascii=False)]
    command.append(program)
    result = subprocess.run(command, input=given.encode(), capture_output=True, timeout=60)
    if result.returncode != 0:
        raise SystemExit(f"jq failed on {program!r}:\n{result.stderr.decode()}")
    outputs = result.stdout.decode().split("\n")[:-1]
    debug = [line for line in result.stderr.decode().split("\n") if line.startswith('["DEBUG:"')]
    return outputs, debug


def refresh_example(jq, example, input_key="input"):
    outputs, debug = run_jq(jq, example["filter"], example[input_key], example.get("arguments"))
    changed = example.get("expected") != outputs
    example["expected"] = outputs
    if debug:
        changed = changed or example.get("debug") != debug
        example["debug"] = debug
    elif "debug" in example:
        del example["debug"]
        changed = True
    return changed


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check_only = "--check" in sys.argv
    jq = args[0] if args else "jq"

    stale = []

    presets_path = RESOURCES / "Presets.json"
    presets = json.loads(presets_path.read_text(encoding="utf-8"))
    if refresh_example(jq, presets["sample"]):
        stale.append("sample")
    for preset in presets["presets"]:
        if refresh_example(jq, preset):
            stale.append(f"preset {preset['id']}")

    cheat_path = RESOURCES / "CheatSheet.json"
    cheat = json.loads(cheat_path.read_text(encoding="utf-8"))
    for section in cheat["sections"]:
        for entry in section["entries"]:
            if refresh_example(jq, entry):
                stale.append(f"cheat sheet {entry['id']}")

    gallery_path = RESOURCES / "Gallery.json"
    gallery = json.loads(gallery_path.read_text(encoding="utf-8"))
    for entry in gallery["entries"]:
        if refresh_example(jq, entry, input_key="sampleInput"):
            stale.append(f"gallery {entry['id']}")

    if check_only:
        if stale:
            raise SystemExit("Stale expected output: " + ", ".join(stale))
        print("All expected outputs match jq.")
        return

    for path, content in ((presets_path, presets), (cheat_path, cheat), (gallery_path, gallery)):
        path.write_text(json.dumps(content, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Refreshed {len(stale)} example(s).")


if __name__ == "__main__":
    main()
