#!/usr/bin/env python3
"""Copy XCTAttachment screenshots out of an xcresult export (made with
`xcrun xcresulttool export attachments`) into a folder with stable names.

The export directory holds the attachment files under opaque names and a
manifest.json: a list with one entry per test method, each with a nested
"attachments" list shaped like:

    {"exportedFileName": "263386A9-....png",
     "suggestedHumanReadableName": "01-playground_0_4CA571A8-....png",
     ...}

"suggestedHumanReadableName" is the XCTAttachment name given in the UI test
(AppScreenshots/Navigation.swift, captureScreenshot(named:)) plus a
"_<index>_<uuid>" suffix, which is removed by splitting on the first "_".
Shot names therefore never contain "_" (AppScreenshots/ScreenshotTests.swift).

Usage:
    python3 Tools/organize-screenshots.py <export-dir> <dest-dir> [--prefix name]

<export-dir> is the --output-path given to xcresulttool. <dest-dir> receives
the renamed PNGs and is created when missing. --prefix namespaces the file
names, such as "iphone" or "ipad".
"""
import json
import shutil
import sys
from pathlib import Path


def find_manifest(export_dir):
    for name in ("manifest.json", "Manifest.json"):
        candidate = export_dir / name
        if candidate.exists():
            return candidate
    raise SystemExit(
        f"No manifest found in {export_dir}. List its contents and compare "
        "them with what this script expects: xcresulttool's output can "
        "change between Xcode versions."
    )


def collect_attachments(manifest):
    """Flattens the manifest's per-test entries into one list of attachment
    dicts. Also accepts a flat list and a wrapping dict, in case a later
    Xcode changes the shape."""
    if isinstance(manifest, dict):
        manifest = manifest.get("attachments", manifest.get("data", manifest.get("tests", [])))
    if not isinstance(manifest, list):
        return []

    attachments = []
    for entry in manifest:
        if not isinstance(entry, dict):
            continue
        nested = entry.get("attachments")
        if isinstance(nested, list):
            attachments.extend(a for a in nested if isinstance(a, dict))
        elif "exportedFileName" in entry:
            attachments.append(entry)
    return attachments


def shot_name(attachment):
    """The XCTAttachment name, recovered from xcresulttool's
    "<name>_<index>_<uuid>" suggested name."""
    suggested = attachment.get("suggestedHumanReadableName") or attachment.get("name")
    if not suggested:
        return None
    return Path(suggested).stem.split("_")[0]


def main():
    args = sys.argv[1:]
    prefix = ""
    if "--prefix" in args:
        i = args.index("--prefix")
        prefix = args[i + 1] + "-"
        del args[i:i + 2]

    if len(args) != 2:
        raise SystemExit(__doc__)

    export_dir = Path(args[0])
    dest_dir = Path(args[1])
    dest_dir.mkdir(parents=True, exist_ok=True)

    manifest_path = find_manifest(export_dir)
    manifest = json.loads(manifest_path.read_text())
    attachments = collect_attachments(manifest)

    copied = 0
    for attachment in attachments:
        exported = attachment.get("exportedFileName")
        name = shot_name(attachment)
        if not exported or not name:
            print(f"  skipping unrecognized attachment entry: {attachment}")
            continue
        src = export_dir / exported
        if not src.exists():
            print(f"  exported file not found: {src}")
            continue
        dest = dest_dir / f"{prefix}{name}{src.suffix}"
        shutil.copy2(src, dest)
        print(f"  {src.name} -> {dest}")
        copied += 1

    if copied == 0:
        raise SystemExit(
            f"No screenshots copied from {export_dir}. The manifest was read, "
            f"but no entry matched the expected shape. Print {manifest_path} "
            "and adjust collect_attachments() and shot_name() to its keys."
        )
    print(f"Copied {copied} screenshot(s) into {dest_dir}")


if __name__ == "__main__":
    main()
