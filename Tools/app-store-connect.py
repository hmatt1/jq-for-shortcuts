#!/usr/bin/env python3
"""Push the App Store listing copy, categories, age rating and review notes
through the App Store Connect API instead of clicking through App Store
Connect by hand.

It does not and cannot touch the App Privacy label ("Does this app collect
data?"). Apple's API has no resource for it. Answer it once in App Store
Connect: App Privacy, Get Started, "No, we do not collect data from this app".

Requires:
    pip install pyjwt cryptography
    (on a Homebrew Python: pip install --break-system-packages pyjwt
    cryptography, or use a venv)

Credentials, the same App Store Connect API key the build workflow uses:
    ASC_KEY_ID            Key ID (the ADMIN_APPSTORE_KEY_ID secret)
    ASC_ISSUER_ID         Issuer ID (the APPSTORE_ISSUER_ID secret)
    ASC_PRIVATE_KEY_PATH  path to the downloaded AuthKey_<KEY_ID>.p8 file

Usage:
    python3 Tools/app-store-connect.py            # dry run: prints, writes nothing
    python3 Tools/app-store-connect.py --apply    # writes

Read the dry run's payloads before --apply. Every write is a PATCH, or a
create when the record is missing, of the fixed values below, so running it
again changes nothing.

The app record itself has to exist first: App Store Connect, Apps, +, New
App, with the bundle ID com.hmatt1.jqforshortcuts. The API cannot create it.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

API_BASE = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.hmatt1.jqforshortcuts"  # project.yml
LOCALE = "en-US"

# The GitHub repository that serves docs/ with GitHub Pages. Change this if
# the repository has a different name.
REPOSITORY = "hmatt1/jq-for-shortcuts"
PAGES_URL = f"https://{REPOSITORY.split('/')[0]}.github.io/{REPOSITORY.split('/')[1]}/"

# ---------------------------------------------------------------------------
# Keep these in sync with AppStore/listing.md, the same copy for a person to
# review. Tools/test_app_store_listing.py checks that they match and that
# every field fits App Store Connect's limits.
# ---------------------------------------------------------------------------
NAME = "JQ for Shortcuts"
SUBTITLE = "Reshape JSON with one action"
PRIVACY_POLICY_URL = PAGES_URL
SUPPORT_URL = f"{PAGES_URL}support/"
MARKETING_URL = f"https://github.com/{REPOSITORY}"
COPYRIGHT = "2026 Matt"
PRIMARY_CATEGORY = "DEVELOPER_TOOLS"
SECONDARY_CATEGORY = "UTILITIES"
PROMOTIONAL_TEXT = (
    "Pull exactly the values you need out of an API response, an export or a webhook. "
    "Test the filter in a live Playground, save it, and run it from Shortcuts."
)
DESCRIPTION = """JQ for Shortcuts runs jq filters on JSON inside Shortcuts. Give it the response from Get Contents of URL, a file or a dictionary, and one filter returns exactly the values, text or file your shortcut needs.

One filter replaces the long chains of Repeat, If and Add to Variable actions that break when the data changes. Filter a list by a condition, sort by a nested field, group and count, rename keys, add up totals, or flatten nested lists.

Write the filter in the Playground. Paste or import some JSON, type a filter, and the result updates as you type. Tap a value in the tree browser to insert its path. An error shows where the filter went wrong and what to try next. Save the filter with a name, and it appears in the Run Saved Filter action right away.

Actions
• Run JSON Filter: JSON and a filter in, typed results out. Lists stay lists, dictionaries stay dictionaries and numbers stay numbers.
• Run Saved Filter: pick one of your saved filters by name.
• Validate JSON: valid or not, with the line and column of the first problem.
• Format JSON: pretty or compact, with sorted keys if you want them.
• Get Value at Path and Set Value at Path: read or change one value with a path such as .data.items[3].name.
• JSON to CSV: turn a list of objects into a CSV or TSV file.

Also included
• jq 1.7 syntax and builtins, with an offline cheat sheet where every example runs in the Playground
• Presets for common jobs: pick keys, rename keys, sort, group and count, unique, flatten, merge and CSV
• Arguments that pass a search term or a limit into a filter as $name, without building the filter from text
• Six example shortcuts to start from
• A share sheet extension, and Control Center and Lock Screen controls
• Run in App for large exports, and a timeout and memory limit on every run

Everything runs on your iPhone or iPad. The app has no accounts and makes no network requests, so your JSON never leaves the device. No ads, no analytics, nothing to buy."""
KEYWORDS = "json,api,filter,parse,csv,webhook,automation,developer,format,validate,query,data,transform"
REVIEW_NOTES = """JQ for Shortcuts runs jq filters on JSON in its Playground and through seven Shortcuts actions. Everything runs on the device. The app has no accounts and makes no network requests.

In the app: the Playground opens with sample JSON and a filter already loaded. Edit the filter and the result updates as you type. Save Filter stores it, and it then appears in the Run Saved Filter action.

The actions, in the Shortcuts app:
1. Create a new shortcut and add a Text action containing {"items":[{"name":"a","n":1},{"name":"b","n":2}]}
2. Add Run JSON Filter from JQ for Shortcuts. Set Filter to .items[].name and Input to the Text.
3. Run the shortcut. The result is a list with "a" and "b".

The Library tab holds Presets and an example gallery. Each gallery entry lists the steps to build its shortcut in the Shortcuts app.

The share extension (share a .json file from Files) and the controls (Control Center, add a control, JQ for Shortcuts) open the app.

No accounts, no network access, no analytics, no ads, no in-app purchases."""

# The contact App Review uses for questions about this submission.
REVIEW_CONTACT = {
    "contactFirstName": "Matt",
    "contactLastName": "Developer",
    "contactEmail": "support@example.com",
    "contactPhone": "+44 844 209 0611",
}

# A 4+ profile: every content descriptor NONE and every capability false.
# The rare override fields are left out, and a PATCH leaves fields it is not
# given alone.
AGE_RATING_ATTRIBUTES = {
    "alcoholTobaccoOrDrugUseOrReferences": "NONE",
    "contests": "NONE",
    "gambling": False,
    "gamblingSimulated": "NONE",
    "gunsOrOtherWeapons": "NONE",
    "medicalOrTreatmentInformation": "NONE",
    "profanityOrCrudeHumor": "NONE",
    "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE",
    "horrorOrFearThemes": "NONE",
    "matureOrSuggestiveThemes": "NONE",
    "violenceCartoonOrFantasy": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    "violenceRealistic": "NONE",
    "advertising": False,
    "healthOrWellnessTopics": False,
    "lootBox": False,
    "messagingAndChat": False,
    "parentalControls": False,
    "ageAssurance": False,
    "socialMedia": False,
    "socialMediaAgeRestricted": False,
    "unrestrictedWebAccess": False,
    "userGeneratedContent": False,
    "kidsAgeBand": None,
}

DRY_RUN = "--apply" not in sys.argv
_token = None


def make_jwt():
    try:
        import jwt
    except ImportError:
        raise SystemExit("Missing dependency: pip install pyjwt cryptography")
    key_id = os.environ["ASC_KEY_ID"]
    issuer_id = os.environ["ASC_ISSUER_ID"]
    with open(os.environ["ASC_PRIVATE_KEY_PATH"]) as f:
        private_key = f.read()
    now = int(time.time())
    # 19 minutes: Apple's hard cap is 20.
    payload = {"iss": issuer_id, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


class APIError(Exception):
    pass


def api(method, path, body=None):
    global _token
    if _token is None:
        _token = make_jwt()
    url = path if path.startswith("http") else f"{API_BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {_token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        raise APIError(f"{method} {url} -> {e.code}\n{detail}")


def write(method, path, body, label):
    print(f"{'[DRY RUN] ' if DRY_RUN else ''}{method} {path}")
    print(json.dumps(body, indent=2, ensure_ascii=False))
    if DRY_RUN:
        print(f"  (not sent. Rerun with --apply to {label})\n")
        return
    api(method, path, body)
    print("  done\n")


def find_app():
    result = api("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")
    apps = [a for a in result.get("data", []) if a["attributes"].get("bundleId") == BUNDLE_ID]
    if not apps:
        raise SystemExit(f"No app in App Store Connect for bundle ID {BUNDLE_ID}. Create the app record first.")
    return apps[0]["id"]


def find_app_info_id(app_id):
    result = api("GET", f"/apps/{app_id}/appInfos")
    infos = result.get("data", [])
    if not infos:
        raise SystemExit("The app has no appInfos, which App Store Connect creates with the app record.")
    editable_states = {None, "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED"}
    editable = [i for i in infos if i["attributes"].get("appStoreState") in editable_states]
    return (editable or infos)[0]["id"]


def find_editable_version(app_id):
    result = api("GET", f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=5")
    versions = result.get("data", [])
    editable_states = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"}
    for v in versions:
        if v["attributes"].get("appVersionState") in editable_states:
            return v["id"], v["attributes"].get("versionString")
    if versions:
        v = versions[0]
        print(f"  warning: no version is in an editable state. Using "
              f"{v['attributes'].get('versionString')}, which may fail.\n")
        return v["id"], v["attributes"].get("versionString")
    raise SystemExit("The app has no App Store version yet. Create one in App Store Connect first.")


def set_name_and_subtitle(app_info_id):
    result = api("GET", f"/appInfos/{app_info_id}/appInfoLocalizations")
    existing = next((l for l in result.get("data", []) if l["attributes"].get("locale") == LOCALE), None)
    attrs = {"name": NAME, "subtitle": SUBTITLE, "privacyPolicyUrl": PRIVACY_POLICY_URL}
    if existing:
        write("PATCH", f"/appInfoLocalizations/{existing['id']}",
              {"data": {"type": "appInfoLocalizations", "id": existing["id"], "attributes": attrs}},
              "update the name, subtitle and privacy policy URL")
    else:
        write("POST", "/appInfoLocalizations",
              {"data": {"type": "appInfoLocalizations",
                        "attributes": {**attrs, "locale": LOCALE},
                        "relationships": {"appInfo": {"data": {"type": "appInfos", "id": app_info_id}}}}},
              "create the name, subtitle and privacy policy URL")


def set_categories(app_info_id):
    relationships = {
        "primaryCategory": {"data": {"type": "appCategories", "id": PRIMARY_CATEGORY}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": SECONDARY_CATEGORY}},
    }
    write("PATCH", f"/appInfos/{app_info_id}",
          {"data": {"type": "appInfos", "id": app_info_id, "relationships": relationships}},
          "set the categories")


def set_age_rating(app_info_id):
    result = api("GET", f"/appInfos/{app_info_id}/ageRatingDeclaration")
    declaration_id = result["data"]["id"]
    write("PATCH", f"/ageRatingDeclarations/{declaration_id}",
          {"data": {"type": "ageRatingDeclarations", "id": declaration_id, "attributes": AGE_RATING_ATTRIBUTES}},
          "set the age rating")


def set_version_metadata(version_id):
    result = api("GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    existing = next((l for l in result.get("data", []) if l["attributes"].get("locale") == LOCALE), None)
    attrs = {
        "description": DESCRIPTION,
        "keywords": KEYWORDS,
        "promotionalText": PROMOTIONAL_TEXT,
        "supportUrl": SUPPORT_URL,
        "marketingUrl": MARKETING_URL,
    }
    if existing:
        write("PATCH", f"/appStoreVersionLocalizations/{existing['id']}",
              {"data": {"type": "appStoreVersionLocalizations", "id": existing["id"], "attributes": attrs}},
              "update the version metadata")
    else:
        write("POST", "/appStoreVersionLocalizations",
              {"data": {"type": "appStoreVersionLocalizations",
                        "attributes": {**attrs, "locale": LOCALE},
                        "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}},
              "create the version metadata")


def set_version_details(version_id):
    write("PATCH", f"/appStoreVersions/{version_id}",
          {"data": {"type": "appStoreVersions", "id": version_id, "attributes": {"copyright": COPYRIGHT}}},
          "update the copyright")


def set_review_details(version_id):
    result = api("GET", f"/appStoreVersions/{version_id}/appStoreReviewDetail")
    existing = result.get("data")
    # The contact fields are required whenever they are still empty in App
    # Store Connect, so they are always sent.
    attrs = {"notes": REVIEW_NOTES, "demoAccountRequired": False, **REVIEW_CONTACT}
    if existing:
        write("PATCH", f"/appStoreReviewDetails/{existing['id']}",
              {"data": {"type": "appStoreReviewDetails", "id": existing["id"], "attributes": attrs}},
              "update the review notes")
    else:
        write("POST", "/appStoreReviewDetails",
              {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
                        "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}},
              "create the review notes")


def main():
    missing = [v for v in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PATH") if v not in os.environ]
    if missing:
        raise SystemExit(f"Missing environment variable(s): {', '.join(missing)}. See the script's docstring.")

    print('App Privacy ("Data Not Collected") has no API. Answer it by hand in App Store\n'
          "Connect. This script handles the listing copy, categories, age rating and\n"
          "review notes.\n")
    if DRY_RUN:
        print("=== DRY RUN: nothing will be written. Pass --apply to send these. ===\n")

    try:
        app_id = find_app()
        print(f"App: {BUNDLE_ID} -> id {app_id}\n")

        app_info_id = find_app_info_id(app_id)
        set_name_and_subtitle(app_info_id)
        set_age_rating(app_info_id)

        version_id, version_string = find_editable_version(app_id)
        print(f"Version: {version_string} -> id {version_id}\n")
        set_version_metadata(version_id)
        set_version_details(version_id)
        set_review_details(version_id)
    except APIError as e:
        raise SystemExit(str(e))

    # Last, and not fatal: the listing above is already in place if
    # App Store Connect refuses a category.
    try:
        set_categories(app_info_id)
    except APIError as e:
        print(f"Could not set the categories. Set them by hand in App Store Connect.\n{e}")


if __name__ == "__main__":
    main()
