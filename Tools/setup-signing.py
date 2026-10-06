#!/usr/bin/env python3
"""One-time setup for CI code signing. Creates one Apple Distribution
certificate and three App Store provisioning profiles (the app, the share
extension and the controls extension), and writes everything CI needs into
.signing/ (gitignored, never committed).

Automatic signing mints a new certificate on every fresh CI runner, because
the private key never leaves the runner it was made on, and those pile up
until the account's certificate cap is reached. One fixed Distribution
certificate never needs to be regenerated.

Run this locally, never in CI: it creates a private key, and Actions logs and
artifacts on a public repository are public.

Requires:
    pip install pyjwt cryptography
    openssl on PATH (Git for Windows, macOS and Linux all ship one)

Credentials, the same App Store Connect API key the build workflow uses:
    ASC_KEY_ID            Key ID (the ADMIN_APPSTORE_KEY_ID secret)
    ASC_ISSUER_ID         Issuer ID (the APPSTORE_ISSUER_ID secret)
    ASC_PRIVATE_KEY_PATH  path to the downloaded AuthKey_<KEY_ID>.p8 file

Usage:
    python3 Tools/setup-signing.py

What it does, in order:
    1. Registers the three bundle IDs if they are missing, and turns on the
       App Groups capability for each.
    2. Creates the Distribution certificate, or reuses the one an earlier
       run left in .signing/.
    3. Creates the three profiles, replacing any with the same name.
    4. Checks that each profile carries the App Group. The API cannot assign
       an App Group to a bundle ID, so the first run usually stops here with
       the Developer Portal steps to do by hand. Run it again afterwards: it
       reuses the certificate and only recreates the profiles.

When it finishes it prints the five values to store as GitHub secrets. Delete
.signing/ once they are stored, since it holds a private key.
"""
import base64
import json
import os
import plistlib
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

API_BASE = "https://api.appstoreconnect.apple.com/v1"
APP_GROUP = "group.com.hmatt1.jqforshortcuts"
CERTIFICATE_COMMON_NAME = "JQ for Shortcuts CI Distribution"

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".signing")


@dataclass(frozen=True)
class SigningTarget:
    secret: str
    bundle_identifier: str
    portal_name: str
    # Must match PROVISIONING_PROFILE_SPECIFIER in project.yml and the
    # provisioningProfiles map in .github/workflows/build.yml.
    profile_name: str
    output_file: str


TARGETS = [
    SigningTarget("IOS_PROFILE_APP_BASE64", "com.hmatt1.jqforshortcuts",
                  "JQ for Shortcuts", "JQ for Shortcuts App Store", "app.mobileprovision.b64"),
    SigningTarget("IOS_PROFILE_SHARE_BASE64", "com.hmatt1.jqforshortcuts.ShareExtension",
                  "JQ for Shortcuts Share Extension", "JQ for Shortcuts Share Extension App Store",
                  "share.mobileprovision.b64"),
    SigningTarget("IOS_PROFILE_CONTROLS_BASE64", "com.hmatt1.jqforshortcuts.Controls",
                  "JQ for Shortcuts Controls", "JQ for Shortcuts Controls App Store",
                  "controls.mobileprovision.b64"),
]


# make_jwt() and api() repeat Tools/app-store-connect.py. Each script runs on
# its own, and the repository has no installable Python package to share.
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


_token = None


def api(method, path, body=None, allow_missing=False):
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
        if allow_missing and e.code == 404:
            return None
        detail = e.read().decode(errors="replace")
        raise SystemExit(f"{method} {url} -> {e.code}\n{detail}")


def run(*cmd):
    # MSYS_NO_PATHCONV stops Git Bash on Windows from rewriting arguments
    # that start with "/", such as openssl's "/CN=..." subject.
    env = {**os.environ, "MSYS_NO_PATHCONV": "1"}
    result = subprocess.run(cmd, capture_output=True, env=env)
    if result.returncode != 0:
        raise SystemExit(f"Command failed: {' '.join(cmd)}\n{result.stderr.decode(errors='replace')}")
    return result


def check_prerequisites():
    missing = [v for v in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PATH") if v not in os.environ]
    if missing:
        raise SystemExit(f"Missing environment variable(s): {', '.join(missing)}. See the script's docstring.")
    try:
        subprocess.run(["openssl", "version"], capture_output=True, check=True)
    except (FileNotFoundError, subprocess.CalledProcessError):
        raise SystemExit("openssl not found on PATH. It ships with Git for Windows, macOS and Linux.")


# ---------------------------------------------------------------------------
# Bundle IDs and the App Groups capability
# ---------------------------------------------------------------------------

def ensure_bundle_id(target):
    query = urllib.parse.quote(target.bundle_identifier)
    result = api("GET", f"/bundleIds?filter[identifier]={query}&limit=200")
    # The filter can also return longer identifiers that start with this
    # one, so match exactly.
    for item in result.get("data", []):
        if item["attributes"].get("identifier") == target.bundle_identifier:
            return item["id"]
    print(f"Registering bundle ID {target.bundle_identifier}...")
    created = api("POST", "/bundleIds", {
        "data": {
            "type": "bundleIds",
            "attributes": {
                "identifier": target.bundle_identifier,
                "name": target.portal_name,
                "platform": "IOS",
            },
        }
    })
    print(f"  created id={created['data']['id']}\n")
    return created["data"]["id"]


def ensure_app_groups_capability(bundle_id, identifier):
    result = api("GET", f"/bundleIds/{bundle_id}/bundleIdCapabilities")
    enabled = {c["attributes"].get("capabilityType") for c in result.get("data", [])}
    if "APP_GROUPS" in enabled:
        return
    print(f"Turning on App Groups for {identifier}...")
    api("POST", "/bundleIdCapabilities", {
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": "APP_GROUPS"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}}},
        }
    })
    print("  done\n")


# ---------------------------------------------------------------------------
# Certificate
# ---------------------------------------------------------------------------

def paths():
    return {
        "key": os.path.join(OUT_DIR, "distribution.key"),
        "csr": os.path.join(OUT_DIR, "distribution.csr"),
        "cer": os.path.join(OUT_DIR, "distribution.cer"),
        "pem": os.path.join(OUT_DIR, "distribution.pem"),
        "p12": os.path.join(OUT_DIR, "distribution.p12"),
        "p12_b64": os.path.join(OUT_DIR, "distribution.p12.b64"),
        "password": os.path.join(OUT_DIR, "distribution.p12.password.txt"),
        "state": os.path.join(OUT_DIR, "certificate.json"),
    }


def reusable_certificate():
    """The certificate an earlier run created, when its files are still in
    .signing/ and Apple still lists it."""
    p = paths()
    if not all(os.path.exists(p[k]) for k in ("state", "p12_b64", "password")):
        return None
    with open(p["state"]) as f:
        certificate_id = json.load(f).get("id")
    if not certificate_id:
        return None
    result = api("GET", f"/certificates/{certificate_id}", allow_missing=True)
    if result is None:
        print(f"The certificate from an earlier run ({certificate_id}) is gone from the account. Creating a new one.\n")
        return None
    print(f"Reusing the certificate from an earlier run: id={certificate_id}\n")
    return certificate_id


def warn_if_distribution_certificate_exists():
    result = api("GET", "/certificates?filter[certificateType]=DISTRIBUTION&limit=50")
    existing = result.get("data", [])
    if existing:
        print(f"NOTE: {len(existing)} DISTRIBUTION certificate(s) already on this account:")
        for c in existing:
            a = c["attributes"]
            print(f"  id={c['id']}  name={a.get('name')!r}  expires={a.get('expirationDate')}")
        print("Creating one more. Press Ctrl-C now if you are at the account's certificate limit.\n")
        time.sleep(5)


def export_p12(key_path, pem_path, p12_path, password):
    # -legacy: OpenSSL 3 writes PKCS12 with AES and a SHA-256 MAC by
    # default, which macOS `security import` rejects with a misleading "MAC
    # verification failed" error. LibreSSL (macOS /usr/bin/openssl) and
    # OpenSSL 1.1 have no -legacy flag and already write the old format.
    command = ["openssl", "pkcs12", "-export", "-inkey", key_path, "-in", pem_path,
               "-out", p12_path, "-passout", f"pass:{password}"]
    env = {**os.environ, "MSYS_NO_PATHCONV": "1"}
    result = subprocess.run(command[:3] + ["-legacy"] + command[3:], capture_output=True, env=env)
    if result.returncode == 0:
        return
    if b"legacy" in result.stderr.lower():
        run(*command)
        return
    raise SystemExit(f"openssl pkcs12 failed:\n{result.stderr.decode(errors='replace')}")


def create_certificate():
    p = paths()
    warn_if_distribution_certificate_exists()

    print("Generating a 2048-bit RSA key and CSR locally. Only the CSR is sent to Apple.")
    run("openssl", "genrsa", "-out", p["key"], "2048")
    run("openssl", "req", "-new", "-key", p["key"], "-out", p["csr"], "-subj", f"/CN={CERTIFICATE_COMMON_NAME}")
    with open(p["csr"]) as f:
        csr_pem = f.read()
    print("  done\n")

    print("Creating the Apple Distribution certificate...")
    result = api("POST", "/certificates", {
        "data": {
            "type": "certificates",
            "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr_pem},
        }
    })
    certificate = result["data"]
    certificate_id = certificate["id"]
    print(f"  created id={certificate_id}  name={certificate['attributes'].get('name')!r}\n")

    with open(p["cer"], "wb") as f:
        f.write(base64.b64decode(certificate["attributes"]["certificateContent"]))
    run("openssl", "x509", "-inform", "DER", "-in", p["cer"], "-out", p["pem"])

    password = secrets.token_urlsafe(24)
    export_p12(p["key"], p["pem"], p["p12"], password)
    with open(p["p12"], "rb") as f:
        p12_b64 = base64.b64encode(f.read()).decode()
    with open(p["p12_b64"], "w") as f:
        f.write(p12_b64)
    with open(p["password"], "w") as f:
        f.write(password)
    with open(p["state"], "w") as f:
        json.dump({"id": certificate_id}, f)
    print(f"Wrote the .p12, its base64 form and its password to {OUT_DIR}\n")
    return certificate_id


# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

def delete_profiles_named(name):
    # Profile names are unique per account, and a rerun must replace the
    # profiles it made before. Only project.yml refers to them, by name.
    result = api("GET", f"/profiles?filter[name]={urllib.parse.quote(name)}")
    for profile in result.get("data", []):
        if profile["attributes"].get("name") == name:
            print(f"  removing existing profile {profile['id']} with the same name")
            api("DELETE", f"/profiles/{profile['id']}")


def create_profile(target, bundle_id, certificate_id):
    delete_profiles_named(target.profile_name)
    print(f"Creating profile {target.profile_name!r}...")
    result = api("POST", "/profiles", {
        "data": {
            "type": "profiles",
            "attributes": {"name": target.profile_name, "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                "certificates": {"data": [{"type": "certificates", "id": certificate_id}]},
            },
        }
    })
    profile = result["data"]
    print(f"  created id={profile['id']}  uuid={profile['attributes'].get('uuid')}\n")
    # Already base64, which is the form the GitHub secret takes.
    return profile["attributes"]["profileContent"]


def profile_app_groups(profile_b64):
    """The App Groups in a profile's entitlements. A profile is a signed
    message that wraps a plain XML property list, so the plist is cut out
    of the bytes without needing a CMS parser."""
    raw = base64.b64decode(profile_b64)
    start = raw.find(b"<?xml")
    end = raw.rfind(b"</plist>")
    if start < 0 or end < 0:
        return []
    plist = plistlib.loads(raw[start:end + len(b"</plist>")])
    return list(plist.get("Entitlements", {}).get("com.apple.security.application-groups", []))


def print_app_group_instructions(identifiers):
    print("=" * 72)
    print(f"The App Group {APP_GROUP} is not assigned to:")
    for identifier in identifiers:
        print(f"  {identifier}")
    print("=" * 72)
    print(f"""
The App Store Connect API cannot assign App Groups, so this part is done by
hand at https://developer.apple.com/account/resources/identifiers:

  1. Switch the list filter to App Groups. If {APP_GROUP} is missing,
     press + and register it.
  2. Switch back to App IDs. For each identifier above: open it, find App
     Groups (already turned on by this script), press Configure, check
     {APP_GROUP}, Continue, then Save.

Then run this script again. It reuses the certificate in .signing/ and
only recreates the three profiles.
""")


def main():
    check_prerequisites()
    os.makedirs(OUT_DIR, exist_ok=True)

    bundle_ids = {}
    for target in TARGETS:
        bundle_id = ensure_bundle_id(target)
        ensure_app_groups_capability(bundle_id, target.bundle_identifier)
        bundle_ids[target.bundle_identifier] = bundle_id

    certificate_id = reusable_certificate() or create_certificate()

    profiles = {}
    missing_group = []
    for target in TARGETS:
        profile_b64 = create_profile(target, bundle_ids[target.bundle_identifier], certificate_id)
        profiles[target] = profile_b64
        if APP_GROUP not in profile_app_groups(profile_b64):
            missing_group.append(target.bundle_identifier)

    if missing_group:
        print_app_group_instructions(missing_group)
        sys.exit(1)

    for target, profile_b64 in profiles.items():
        with open(os.path.join(OUT_DIR, target.output_file), "w") as f:
            f.write(profile_b64)

    p = paths()
    print("=" * 72)
    print("Done. Store these five values as GitHub secrets, and nowhere else.")
    print("=" * 72)
    rows = [("IOS_DIST_CERT_P12_BASE64", f"contents of {p['p12_b64']}"),
            ("IOS_DIST_CERT_PASSWORD", f"contents of {p['password']}")]
    rows += [(t.secret, f"contents of {os.path.join(OUT_DIR, t.output_file)}") for t in TARGETS]
    for name, value in rows:
        print(f"  {name:<28} <- {value}")
    print("\nWith the gh CLI, from the repository folder:\n")
    print(f'  gh secret set IOS_DIST_CERT_P12_BASE64 < "{p["p12_b64"]}"')
    print(f'  gh secret set IOS_DIST_CERT_PASSWORD < "{p["password"]}"')
    for target in TARGETS:
        print(f'  gh secret set {target.secret} < "{os.path.join(OUT_DIR, target.output_file)}"')
    print("""
The build also needs the App Store Connect API key secrets used for the
upload: APPSTORE_ISSUER_ID, ADMIN_APPSTORE_KEY_ID and ADMIN_APPSTORE_P8_KEY.

Once the secrets are set, delete the .signing/ directory. It holds a
private key, and everything in it now lives in GitHub.
""")


if __name__ == "__main__":
    main()
