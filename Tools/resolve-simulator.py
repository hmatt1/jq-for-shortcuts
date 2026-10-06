#!/usr/bin/env python3
"""Resolve which iOS Simulator device types and runtime to boot for
.github/workflows/screenshots.yml, without hardcoding an iPhone or iPad
generation, or an iOS version, that the runner's Xcode might not ship.

Picks the iPhone 13 Pro Max (whose 1284x2778 screenshots fit App Store
Connect's 6.5-inch slot) or else the newest Pro Max, the newest iPad Pro,
and the newest available iOS runtime, by querying `xcrun simctl list -j`.

Prints three `KEY=value` lines for the workflow to append to $GITHUB_ENV.
It is a script, not an inline heredoc, because a heredoc inside a YAML
`run: |` block inherits the block's indentation and breaks Python's.

Exits non-zero with the raw `simctl list` output on stderr when a device
type or the runtime cannot be resolved, so a CI failure shows what was
available.
"""
import json
import subprocess
import sys


def simctl_json(*args):
    result = subprocess.run(["xcrun", "simctl", "list", *args, "-j"], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def newest(candidates, key):
    if not candidates:
        return None
    return sorted(candidates, key=key)[-1]


# Device type identifiers embed the generation as a number, such as
# "...iPhone-17-Pro-Max", so a string sort orders them while the number has
# two digits. One function per selection, so each is unit-testable against a
# synthetic list (Tools/test_resolve_simulator.py).

def find_iphone_pro_max(devicetypes):
    # App Store Connect's 6.5-inch slot takes 1284x2778 or 1242x2688. Newer
    # Pro Max models have other sizes, so the 13 Pro Max comes first.
    for t in devicetypes:
        if t["name"] == "iPhone 13 Pro Max":
            return t
    return newest(
        [t for t in devicetypes if "iPhone" in t["name"] and "Pro Max" in t["name"]],
        key=lambda t: t["identifier"],
    )


def find_ipad_pro(devicetypes):
    return newest(
        [t for t in devicetypes if "iPad Pro" in t["name"]],
        key=lambda t: t["identifier"],
    )


def version_key(version):
    """Orders "27.0" after "9.3", which a string sort gets wrong."""
    return tuple(int(part) if part.isdigit() else 0 for part in version.split("."))


def find_latest_ios_runtime(runtimes):
    return newest(
        [r for r in runtimes if r["name"].startswith("iOS") and r.get("isAvailable", True)],
        key=lambda r: version_key(r["version"]),
    )


def main():
    devicetypes = simctl_json("devicetypes")["devicetypes"]

    iphone = find_iphone_pro_max(devicetypes)
    ipad = find_ipad_pro(devicetypes)
    if not iphone or not ipad:
        print("Could not resolve a simulator device type. Available device types:", file=sys.stderr)
        print(json.dumps(devicetypes, indent=2), file=sys.stderr)
        sys.exit(1)

    runtimes = simctl_json("runtimes")["runtimes"]
    runtime = find_latest_ios_runtime(runtimes)
    if not runtime:
        print("Could not resolve an iOS simulator runtime. Available runtimes:", file=sys.stderr)
        print(json.dumps(runtimes, indent=2), file=sys.stderr)
        sys.exit(1)

    print(f"IPHONE_TYPE={iphone['identifier']}")
    print(f"IPAD_TYPE={ipad['identifier']}")
    print(f"RUNTIME={runtime['identifier']}")


if __name__ == "__main__":
    main()
