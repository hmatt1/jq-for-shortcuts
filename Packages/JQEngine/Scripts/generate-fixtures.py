#!/usr/bin/env python3
"""Regenerates Tests/JQEngineTests/Fixtures/jq-1.7.1.json, the expected
output of real jq 1.7.1 for every case in Tests/JQEngineTests/Fixtures/Sources.

The engine's conformance test (ConformanceTests.swift) runs each case and
compares its output with these expectations byte for byte, the way `jq -c`
prints them, including the text of every error message.

Sources:
    *.test        jq's own test files from the jq 1.7.1 release (jq.test,
                  man.test, onig.test, manonig.test, base64.test). Only the
                  filter and input are used; the expected output comes from
                  running jq, so it is exact rather than jq's own loose
                  comparison.
    *.json        extra cases written for this engine: edge cases for numbers,
                  strings, paths and errors (edge-cases.json), and filters
                  people paste into Shortcuts (realistic.json). Each case is
                  {"filter", "input", "flags"?}, where flags are jq CLI flags
                  (-s, -S, -a, --arg name value, --argjson name json).

Cases that read files, the environment or the clock, or that write to stderr,
are skipped: the engine removes those features or the result depends on
the machine.

Usage:
    python3 Scripts/generate-fixtures.py [path/to/jq]

Needs jq 1.7.1. Ubuntu 24.04's jq package is 1.7.1, although its
`jq --version` prints "jq-1.7".
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Tests" / "JQEngineTests" / "Fixtures" / "Sources"
OUTPUT = ROOT / "Tests" / "JQEngineTests" / "Fixtures" / "jq-1.7.1.json"

SKIP = re.compile(
    r"\$ENV\b|\$__prog_args\b|"
    r"\b(import|include|modulemeta|input|inputs|input_filename|env|get_search_list|"
    r"get_prog_origin|get_jq_origin|now|localtime|strflocaltime|halt|halt_error|"
    r"stderr|debug|input_line_number)\b"
)
ERROR_PREFIX = re.compile(r"^jq: error \(at <stdin>:\d+\)", re.M)


def load_test_file(path):
    """(id, filter, input, compile_error) for each case in a jq .test file."""
    lines = path.read_text(encoding="utf-8").split("\n")
    cases = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == "" or line.startswith("#"):
            i += 1
            continue
        if line.startswith("%%FAIL"):
            cases.append((f"{path.name}:{i + 2}", lines[i + 1], "null", True))
            j = i + 2
            while j < len(lines) and lines[j].strip() != "":
                j += 1
            i = j
            continue
        program = line
        given = lines[i + 1] if i + 1 < len(lines) else "null"
        cases.append((f"{path.name}:{i + 1}", program, given, False))
        j = i + 2
        while j < len(lines) and lines[j].strip() != "" and not lines[j].startswith("#"):
            j += 1
        i = j
    return cases


def options_and_arguments(flags):
    """CLI flags as fixture options, and arguments as JSON text by name."""
    options = {}
    arguments = {}
    k = 0
    while k < len(flags):
        flag = flags[k]
        if flag == "-s":
            options["slurp"] = True
        elif flag == "-S":
            options["sortKeys"] = True
        elif flag == "-a":
            options["ascii"] = True
        elif flag == "--arg":
            arguments[flags[k + 1]] = json.dumps(flags[k + 2], ensure_ascii=False)
            k += 2
        elif flag == "--argjson":
            arguments[flags[k + 1]] = flags[k + 2]
            k += 2
        else:
            raise SystemExit(f"unsupported flag {flag}")
        k += 1
    return options, arguments


def run_jq(jq, program, given, flags):
    result = subprocess.run(
        [jq, "-c", *flags, program], input=given.encode(), capture_output=True, timeout=60
    )
    stdout = result.stdout.decode("utf-8")
    stderr = result.stderr.decode("utf-8")
    outputs = stdout.split("\n")[:-1] if stdout else []
    errors = []
    parts = ERROR_PREFIX.split(stderr)
    for part in parts[1:]:
        text = part[:-1] if part.endswith("\n") else part
        if text.startswith(": "):
            errors.append(text[2:])
        elif text.startswith(" (not a string): "):
            errors.append(text[1:])
        else:
            errors.append(text.strip())
    return result.returncode, outputs, errors


def main():
    jq = sys.argv[1] if len(sys.argv) > 1 else "jq"
    raw = []
    for path in sorted(SOURCES.glob("*.test")):
        for case_id, program, given, compile_error in load_test_file(path):
            raw.append((case_id, program, given, [], compile_error))
    for path in sorted(SOURCES.glob("*.json")):
        for index, case in enumerate(json.loads(path.read_text(encoding="utf-8"))):
            raw.append((f"{path.name}:{index}", case["filter"], case.get("input", "null"),
                        case.get("flags", []), False))

    seen = set()
    fixtures = []
    skipped = 0
    for case_id, program, given, flags, compile_error in raw:
        key = (program, given, tuple(flags))
        if key in seen:
            continue
        seen.add(key)
        if SKIP.search(program):
            skipped += 1
            continue
        code, outputs, errors = run_jq(jq, program, given, flags)
        fixture = {"id": case_id, "filter": program, "input": given}
        options, arguments = options_and_arguments(flags)
        if options:
            fixture["options"] = options
        if arguments:
            fixture["arguments"] = arguments
        if code == 3:
            fixture["compileError"] = True
        elif compile_error:
            raise SystemExit(f"{case_id}: jq compiled a %%FAIL case (exit {code})")
        else:
            fixture["outputs"] = outputs
            if code == 2 and errors:
                fixture["inputError"] = errors.pop()
            if errors:
                fixture["errors"] = errors
            if code not in (0, 2, 5):
                raise SystemExit(f"{case_id}: unexpected jq exit code {code}")
        fixtures.append(fixture)

    OUTPUT.write_text(
        json.dumps({"jq": "1.7.1", "cases": fixtures}, indent=1, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"{len(fixtures)} fixtures written to {OUTPUT.relative_to(ROOT)} ({skipped} skipped)")


if __name__ == "__main__":
    main()
