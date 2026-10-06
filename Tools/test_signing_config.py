#!/usr/bin/env python3
"""Checks that setup-signing.py, project.yml, the build workflow and the
entitlements agree on bundle IDs, profile names, secrets and the App Group.
A mismatch otherwise shows up only as a failed archive on CI.

Run directly:
    python3 -m unittest discover -s Tools -p 'test_*.py'
"""
import base64
import importlib.util
import pathlib
import plistlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
_MODULE_PATH = ROOT / "Tools" / "setup-signing.py"
_spec = importlib.util.spec_from_file_location("setup_signing", _MODULE_PATH)
assert _spec is not None and _spec.loader is not None, f"could not load spec for {_MODULE_PATH}"
signing = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(signing)

ENTITLEMENTS = [
    ROOT / "App" / "JQForShortcuts.entitlements",
    ROOT / "ShareExtension" / "JQShareExtension.entitlements",
    ROOT / "Controls" / "JQControls.entitlements",
]


class ConsistencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = (ROOT / "project.yml").read_text(encoding="utf-8")
        cls.workflow = (ROOT / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")

    def test_three_targets(self):
        self.assertEqual(len(signing.TARGETS), 3)

    def test_bundle_ids_match_project(self):
        for target in signing.TARGETS:
            self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER: {target.bundle_identifier}\n", self.project)

    def test_profile_names_match_project(self):
        for target in signing.TARGETS:
            self.assertIn(f'PROVISIONING_PROFILE_SPECIFIER: "{target.profile_name}"', self.project)

    def test_export_options_map_each_bundle_id_to_its_profile(self):
        for target in signing.TARGETS:
            mapping = (f"<key>{target.bundle_identifier}</key>\n"
                       f"                  <string>{target.profile_name}</string>")
            self.assertIn(mapping, self.workflow)

    def test_workflow_installs_every_profile_secret(self):
        for target in signing.TARGETS:
            self.assertIn(f"install_profile \"${target.secret}\"", self.workflow)
            self.assertIn(f"{target.secret}: ${{{{ secrets.{target.secret} }}}}", self.workflow)

    def test_every_target_entitles_the_app_group(self):
        for path in ENTITLEMENTS:
            with open(path, "rb") as f:
                entitlements = plistlib.load(f)
            self.assertEqual(entitlements.get("com.apple.security.application-groups"), [signing.APP_GROUP], path.name)

    def test_app_group_matches_the_app_code(self):
        app_group = (ROOT / "Shared" / "Core" / "AppGroup.swift").read_text(encoding="utf-8")
        suffix = signing.APP_GROUP.removeprefix("group.")
        self.assertIn(f'expectedSuffix = "{suffix}"', app_group)


class ProfileAppGroupTests(unittest.TestCase):
    def make_profile(self, entitlements):
        plist = plistlib.dumps({"Name": "Test", "Entitlements": entitlements})
        # A real profile wraps the plist in a CMS signature.
        return base64.b64encode(b"\x30\x82\x01\x00signature-bytes" + plist + b"\xa0\x82trailer").decode()

    def test_reads_the_app_groups(self):
        profile = self.make_profile({"com.apple.security.application-groups": [signing.APP_GROUP]})
        self.assertEqual(signing.profile_app_groups(profile), [signing.APP_GROUP])

    def test_missing_entitlement_reads_as_empty(self):
        profile = self.make_profile({"application-identifier": "FHMS65N3XS.com.hmatt1.jqforshortcuts"})
        self.assertEqual(signing.profile_app_groups(profile), [])

    def test_bytes_without_a_plist_read_as_empty(self):
        self.assertEqual(signing.profile_app_groups(base64.b64encode(b"not a profile").decode()), [])


if __name__ == "__main__":
    unittest.main()
