#!/usr/bin/env python3
"""Checks the App Store listing in app-store-connect.py against App Store
Connect's field limits, against AppStore/listing.md (the same copy for a
person to review), and against project.yml.

Run directly:
    python3 -m unittest discover -s Tools -p 'test_*.py'
"""
import importlib.util
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
_MODULE_PATH = ROOT / "Tools" / "app-store-connect.py"
_spec = importlib.util.spec_from_file_location("app_store_connect", _MODULE_PATH)
assert _spec is not None and _spec.loader is not None, f"could not load spec for {_MODULE_PATH}"
listing = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(listing)


def normalized(text):
    return re.sub(r"\s+", " ", text).strip()


class FieldLimitTests(unittest.TestCase):
    def test_name_fits(self):
        self.assertLessEqual(len(listing.NAME), 30)

    def test_subtitle_fits(self):
        self.assertLessEqual(len(listing.SUBTITLE), 30)

    def test_promotional_text_fits(self):
        self.assertLessEqual(len(listing.PROMOTIONAL_TEXT), 170)

    def test_description_fits(self):
        self.assertLessEqual(len(listing.DESCRIPTION), 4000)

    def test_review_notes_fit(self):
        self.assertLessEqual(len(listing.REVIEW_NOTES), 4000)

    def test_keywords_fit(self):
        self.assertLessEqual(len(listing.KEYWORDS), 100)

    def test_copyright_is_set(self):
        self.assertTrue(listing.COPYRIGHT.strip())


class KeywordTests(unittest.TestCase):
    def setUp(self):
        self.keywords = listing.KEYWORDS.split(",")

    def test_no_spaces_around_commas(self):
        for keyword in self.keywords:
            self.assertEqual(keyword, keyword.strip(), f"{keyword!r} has surrounding spaces")

    def test_no_empty_or_repeated_keywords(self):
        self.assertTrue(all(self.keywords))
        self.assertEqual(len(self.keywords), len(set(k.lower() for k in self.keywords)))

    def test_no_words_from_the_name(self):
        # App Store search already indexes the name, so a repeat wastes space.
        name_words = {word.lower() for word in listing.NAME.split()}
        for keyword in self.keywords:
            self.assertNotIn(keyword.lower(), name_words)


class URLTests(unittest.TestCase):
    def test_urls_use_https(self):
        for url in (listing.PRIVACY_POLICY_URL, listing.SUPPORT_URL, listing.MARKETING_URL):
            self.assertTrue(url.startswith("https://"), url)

    def test_support_url_is_the_docs_support_page(self):
        self.assertTrue((ROOT / "docs" / "support" / "index.html").exists())
        self.assertTrue(listing.SUPPORT_URL.endswith("/support/"))

    def test_privacy_policy_page_exists(self):
        self.assertTrue((ROOT / "docs" / "index.html").exists())


class ListingDocumentTests(unittest.TestCase):
    """AppStore/listing.md holds the same copy, wrapped for reading."""

    @classmethod
    def setUpClass(cls):
        cls.document = normalized((ROOT / "AppStore" / "listing.md").read_text(encoding="utf-8"))

    def assertInDocument(self, text):
        self.assertIn(normalized(text), self.document)

    def test_name(self):
        self.assertInDocument(listing.NAME)

    def test_subtitle(self):
        self.assertInDocument(listing.SUBTITLE)

    def test_promotional_text(self):
        self.assertInDocument(listing.PROMOTIONAL_TEXT)

    def test_description(self):
        self.assertInDocument(listing.DESCRIPTION)

    def test_keywords(self):
        self.assertInDocument(listing.KEYWORDS)

    def test_review_notes(self):
        self.assertInDocument(listing.REVIEW_NOTES)


class ProjectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = (ROOT / "project.yml").read_text(encoding="utf-8")

    def test_name_matches_the_home_screen_name(self):
        self.assertIn(f"CFBundleDisplayName: {listing.NAME}\n", self.project)

    def test_bundle_id_matches_the_app_target(self):
        self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER: {listing.BUNDLE_ID}\n", self.project)


if __name__ == "__main__":
    unittest.main()
