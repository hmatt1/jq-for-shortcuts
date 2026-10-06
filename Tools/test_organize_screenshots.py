#!/usr/bin/env python3
"""Unit tests for organize-screenshots.py.

Run directly:
    python3 -m unittest discover -s Tools -p 'test_*.py'
"""
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest

_MODULE_PATH = pathlib.Path(__file__).parent / "organize-screenshots.py"
_spec = importlib.util.spec_from_file_location("organize_screenshots", _MODULE_PATH)
assert _spec is not None and _spec.loader is not None, f"could not load spec for {_MODULE_PATH}"
organize_screenshots = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(organize_screenshots)


class CollectAttachmentsTests(unittest.TestCase):
    def test_real_confirmed_shape_list_of_tests_with_nested_attachments(self):
        manifest = [
            {
                "testIdentifier": "ScreenshotTests/testPlayground()",
                "attachments": [
                    {"exportedFileName": "abc.png", "suggestedHumanReadableName": "01-playground_0_UUID.png"},
                ],
            },
            {
                "testIdentifier": "ScreenshotTests/testLibrary()",
                "attachments": [
                    {"exportedFileName": "def.png", "suggestedHumanReadableName": "02-library_0_UUID.png"},
                    {"exportedFileName": "ghi.png", "suggestedHumanReadableName": "02-gallery_0_UUID.png"},
                ],
            },
        ]
        attachments = organize_screenshots.collect_attachments(manifest)
        self.assertEqual(len(attachments), 3)
        self.assertEqual(attachments[0]["exportedFileName"], "abc.png")

    def test_flat_attachment_dict_fallback_shape(self):
        manifest = [{"exportedFileName": "abc.png", "name": "01-playground"}]
        attachments = organize_screenshots.collect_attachments(manifest)
        self.assertEqual(len(attachments), 1)

    def test_dict_wrapper_shape(self):
        manifest = {"attachments": [
            {"attachments": [{"exportedFileName": "abc.png", "suggestedHumanReadableName": "01-hero_0_UUID.png"}]}
        ]}
        attachments = organize_screenshots.collect_attachments(manifest)
        self.assertEqual(len(attachments), 1)

    def test_garbage_input_returns_empty_list(self):
        self.assertEqual(organize_screenshots.collect_attachments("not a manifest at all"), [])
        self.assertEqual(organize_screenshots.collect_attachments(None), [])
        self.assertEqual(organize_screenshots.collect_attachments([1, 2, "three"]), [])

    def test_entries_with_no_attachments_and_no_flat_shape_are_skipped(self):
        manifest = [{"testIdentifier": "SomeTest/testNothing()"}]
        self.assertEqual(organize_screenshots.collect_attachments(manifest), [])


class ShotNameTests(unittest.TestCase):
    def test_recovers_name_from_suggested_human_readable_name(self):
        attachment = {"suggestedHumanReadableName": "04-reference_0_4CA571A8-DF1C-41F8-8249-0EE40AB8AD66.png"}
        self.assertEqual(organize_screenshots.shot_name(attachment), "04-reference")

    def test_falls_back_to_name_key(self):
        self.assertEqual(organize_screenshots.shot_name({"name": "01-playground"}), "01-playground")

    def test_returns_none_when_neither_key_present(self):
        self.assertIsNone(organize_screenshots.shot_name({}))

    def test_names_without_a_suffix_pass_through_unchanged(self):
        self.assertEqual(organize_screenshots.shot_name({"name": "plain"}), "plain")


class MainEndToEndTests(unittest.TestCase):
    def _run_main(self, *argv):
        old_argv = sys.argv
        try:
            sys.argv = ["organize-screenshots.py", *argv]
            organize_screenshots.main()
        finally:
            sys.argv = old_argv

    def test_organizes_a_real_shaped_export_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            export_dir = pathlib.Path(tmp) / "export"
            dest_dir = pathlib.Path(tmp) / "dest"
            export_dir.mkdir()
            (export_dir / "abc123.png").write_bytes(b"fake png bytes")
            manifest = [{
                "testIdentifier": "ScreenshotTests/testPlayground()",
                "attachments": [
                    {"exportedFileName": "abc123.png", "suggestedHumanReadableName": "01-playground_0_UUID.png"},
                ],
            }]
            (export_dir / "manifest.json").write_text(json.dumps(manifest))

            self._run_main(str(export_dir), str(dest_dir))

            self.assertTrue((dest_dir / "01-playground.png").exists())

    def test_prefix_option_namespaces_output_filenames(self):
        with tempfile.TemporaryDirectory() as tmp:
            export_dir = pathlib.Path(tmp) / "export"
            dest_dir = pathlib.Path(tmp) / "dest"
            export_dir.mkdir()
            (export_dir / "abc123.png").write_bytes(b"fake png bytes")
            manifest = [{"attachments": [
                {"exportedFileName": "abc123.png", "suggestedHumanReadableName": "01-hero_0_UUID.png"}
            ]}]
            (export_dir / "manifest.json").write_text(json.dumps(manifest))

            self._run_main("--prefix", "iphone", str(export_dir), str(dest_dir))

            self.assertTrue((dest_dir / "iphone-01-hero.png").exists())

    def test_raises_when_nothing_matches(self):
        with tempfile.TemporaryDirectory() as tmp:
            export_dir = pathlib.Path(tmp) / "export"
            dest_dir = pathlib.Path(tmp) / "dest"
            export_dir.mkdir()
            (export_dir / "manifest.json").write_text("[]")

            with self.assertRaises(SystemExit):
                self._run_main(str(export_dir), str(dest_dir))

    def test_raises_when_manifest_is_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            export_dir = pathlib.Path(tmp) / "export"
            dest_dir = pathlib.Path(tmp) / "dest"
            export_dir.mkdir()

            with self.assertRaises(SystemExit):
                self._run_main(str(export_dir), str(dest_dir))


if __name__ == "__main__":
    unittest.main()
