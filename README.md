# JQ for Shortcuts

Runs jq filters on JSON inside Shortcuts. One `Run JSON Filter` action takes JSON from `Get Contents of URL`, a file or a dictionary and returns exactly the values, text or file the shortcut needs, in place of long chains of `Repeat`, `If` and `Add to Variable`. The app is a Playground for writing and testing filters, a Library of saved filters and presets, and an offline jq cheat sheet.

iOS 27. XcodeGen. GitHub Actions builds, tests, signs and uploads every push to TestFlight. No accounts, no network access, no analytics, nothing to buy.

The design document in the claude.ai project (`Design Document jq for iOS Shortcuts (working title).md`) is the specification. Requirement IDs such as `R3.12` in code comments refer to it.

## What it does

Seven Shortcuts actions, all on one filter engine:

| Action | Parameters | Returns |
| --- | --- | --- |
| `Run JSON Filter` | Filter, Input, Output Mode; Arguments when set; Slurp, Sort Keys, Timeout, Run in App under Show More | the results, by output mode |
| `Run Saved Filter` | Saved Filter (picked by name, description as subtitle), Input, Output Mode (defaults to the filter's own), the rest as above | the results |
| `Validate JSON` | Input | a Validation Result: Valid, Line, Column, Message |
| `Format JSON` | Input, Style (Pretty or Compact), Sort Keys | JSON text |
| `Get Value at Path` | Input, Path such as `.data.items[3].name`, If Missing | the value |
| `Set Value at Path` | Input, Path, Value | the updated JSON text |
| `JSON to CSV` | Input, Columns; Delimiter (Comma or Tab) and Header Row under Show More | a `.csv` or `.tsv` file |

The app has three tabs:

- **Playground**: an input pane (paste, import, share sheet), a filter editor with jq syntax colors, bracket matching and a symbol row, a result pane that updates as you type and shows what Shortcuts would receive, a tree browser that inserts paths, an Arguments editor, and a Debug area for `debug` and `stderr`.
- **Library**: saved filters (edit, duplicate, delete), the nine presets from R6.13, the six-entry example gallery from R10, and recent runs when input history is on.
- **Reference**: a searchable cheat sheet where every example has **Run in Playground**, and the list of differences from jq 1.7.

Other entry points: a share extension (**Open in Playground**, or run a saved filter with a **Copy** button), two Control Center and Lock Screen controls (**Open Playground**, **Run Saved Filter on Clipboard**), and App Shortcuts with one Siri phrase per action. **Open Playground** can be bound to the Action Button.

Every entry point goes through `Shared/Core/FilterRunner.swift`, so they share the engine, the Saved Filter store in the App Group and the limits in `Shared/Core/RunLimits.swift`.

## Decisions

The design document leaves an engine choice and nine open questions to a spike. This is what the build does for each.

### The filter engine

`Packages/JQEngine` is a jq 1.7.1 implementation in Swift, written for this app. I went this way instead of wrapping `libjq`, `jaq` or `gojq` for these reasons:

- **Stopping a run** (spike question 3). Every 1,024 steps the interpreter checks for cancellation, the timeout and the memory budget, and every call checks the stack depth, so `[range(1e12)]` and runaway recursion stop with R8.5, R8.12 or a recursion error and never hang the intent.
- **Disabled features** (R4.7, R9.7). `include`, `import`, `input`, `inputs`, `input_filename`, `env`, `$ENV` and the module builtins do not exist in the language, so no spelling of a filter reaches files or the environment.
- **Readable errors** (R8). The parser reports byte positions, which the app underlines, and run-time errors carry the value involved, which feeds the hints in R8.2 and R8.11.
- **64-bit IDs** (spike question 6). Numbers keep their original digits until arithmetic touches them, as in jq 1.7.
- **No C toolchain in CI.** The same code builds for the app, both extensions and `swift test` on the runner.

Compatibility decides the engine (design, "Decisions for the owner"), so it is tested against real jq 1.7.1 output:

- `Tests/JQEngineTests/Fixtures/jq-1.7.1.json`: 1386 cases. `Scripts/generate-fixtures.py` built them by running jq 1.7.1 on jq's own test suite (`jq.test`, `man.test`, `onig.test`, `base64.test`) plus edge cases and realistic filters, recording outputs and error messages byte for byte.
- `Fixtures/requirements.json`: the R9.13 cases (a 64-bit integer, non-ASCII text, a filter with no output, a run-time error, each disabled feature, a runaway filter, a large input).
- `ContentFixtureTests`: every preset, cheat sheet example and gallery filter in `App/Resources`.

Regular expressions run on ICU through `NSRegularExpression`, with jq's Oniguruma syntax translated. The Reference tab lists this and the other known differences (R4.12).

### Open questions

| # | Question | What the build does |
| --- | --- | --- |
| 1 | Built-in Shortcuts filtering | Nothing changes in the app; the pitch stands. |
| 2, 3, 6 | Engine | See above. |
| 4 | Dictionaries and lists as Input | `Input` is `[IntentFile]` with `.json`, `.plainText`, `.text` and `.data`. Shortcuts hands a Dictionary or List over as JSON, Text as text, and a file as itself. Any other type, such as an image, stops with R8.4. |
| 5 | Background input size | 50 MB in the background, 250 MB with Run in App, 10 MB in the share extension, and a background timeout cap of 25 seconds, since iOS ends background actions at about 30. All placeholders, in `RunLimits.swift`. |
| 7 | Types in Shortcuts | An App Intent returns one static type, so results go out as Text: strings as themselves, everything else as JSON text, which `Get Dictionary Value` and the list actions read as a Dictionary or List. `null` is the text `null`. With **One item per result**, a single list result is split into its items, so an array of objects arrives as a list of dictionaries. |
| 8 | Clipboard after a control opens the app | The clipboard runner uses the system Paste button, which reads the clipboard on a tap without the paste permission prompt. |
| 9 | Adding a signed `.shortcut` | A signed file cannot be produced outside Shortcuts, so each gallery entry ships its steps, filter, values to change and sample input (the spike's fallback), and gains an **Add to Shortcuts** button once a signed file or an iCloud link is added. See "Gallery shortcuts" below. |

R9.1 in the design says iOS 18 as a placeholder. The build targets iOS 27 only, so controls, `supportedModes` and `continueInForeground` need no availability checks.

### Other choices worth knowing

- **Arguments is a Text parameter holding a JSON object.** App Intents has no Dictionary parameter type. A Dictionary variable placed in Arguments arrives as JSON, so Numbers, Booleans, Lists and Dictionaries keep their types (R2.9). Typed by hand, it is JSON such as `{"limit": 5}`, and anything else stops with a message that says so.
- **Run Saved Filter starts from the saved arguments.** The values in the Playground's Arguments editor are saved with the filter and used as defaults by the action, the share sheet and the clipboard runner. The action's own Arguments replace them key by key.
- **An empty input gives no results** (R2.3: the filter runs once per input value, as in jq), so the `If ... has any value` step after the action handles an empty response. With Slurp on, the filter runs once on `[]`.
- **Lists from Shortcuts become one JSON array.** A list with one item arrives as that item, because Shortcuts hands both over the same way. A filter that must take either can start with `if type == "array" then .[] else . end`.
- **Run in App hands the result back as soon as the run ends.** The app then shows how the run ended and a **Back to Shortcuts** button. It does not switch apps by itself, because a shortcut can also run from Siri, a widget or the Home Screen.
- **The clipboard control needs one tap.** It opens the clipboard runner, and the system Paste button runs the filter, which avoids the paste permission prompt.
- **Two gallery filters produce nothing instead of `null` text**, so their `If ... has any value` step works (R10.10): Latest release adds `// empty`, and API response to a notification checks `.main.temp` first.

## Build locally

On a Mac with Xcode 27:

```bash
brew install xcodegen
xcodegen generate
open JQForShortcuts.xcodeproj
```

Debug builds use Automatic signing with team `FHMS65N3XS`. To build with another team, change `DEVELOPMENT_TEAM` in `project.yml`, and change the bundle IDs and App Group too, since IDs are unique across Apple. `Shared/Core/AppGroup.swift` finds any entitled group that ends in `com.hmatt1.jqforshortcuts`, and an `APP_GROUP_ID` key in `Info.plist` overrides it.

Try the engine from the command line, on macOS or Linux:

```bash
swift run --package-path Packages/JQEngine jqswift -c '.items[] | select(.n > 1)' <<< '{"items":[{"n":1},{"n":2}]}'
```

## Tests

| Suite | Runs | Command |
| --- | --- | --- |
| Engine | 1386 jq 1.7.1 cases, the R9.13 fixtures, every bundled example, errors, limits, paths, syntax colors | `swift test --package-path Packages/JQEngine` |
| `AppLogicTests` | the run pipeline, every R8 message, output modes, the JSON tools, the stores, the tree browser, the bundled content | `xcodebuild test -project JQForShortcuts.xcodeproj -scheme JQForShortcuts -only-testing:AppLogicTests -destination 'platform=iOS Simulator,name=iPhone 17'` |
| Tools | the Python scripts, the listing limits, signing names that must match across files | `python3 -m unittest discover -s Tools -p 'test_*.py'` |
| `AppScreenshotsUITests` | captures the App Store screenshots | `.github/workflows/screenshots.yml` |

`.github/workflows/build.yml` runs the first three on every push and pull request, before anything is signed.

After editing a preset, cheat sheet example or gallery filter, refresh the expected outputs with jq 1.7.1:

```bash
python3 Tools/refresh-content.py
```

## Release setup

Do this once. Steps 2 to 4 follow the same pattern as the Shortcut Launcher Widget repository and reuse its App Store Connect API key.

### 1. Create the repository

Create `hmatt1/jq-for-shortcuts` on GitHub and push this folder to `main`. The privacy and support URLs assume that name; if it differs, change `REPOSITORY` in `Tools/app-store-connect.py` and the two links in `App/Views/Settings/AboutView.swift`.

The workflows run on the `xcode-27` runner label, like the widget repository. Make sure the new repository can use it.

### 2. Register the App Group

In the [Developer Portal](https://developer.apple.com/account/resources/identifiers), switch the list to **App Groups**, press **+** and register `group.com.hmatt1.jqforshortcuts`.

### 3. Create the signing certificate and profiles

```bash
pip install pyjwt cryptography
export ASC_KEY_ID=...            # the ADMIN_APPSTORE_KEY_ID key
export ASC_ISSUER_ID=...
export ASC_PRIVATE_KEY_PATH=~/Downloads/AuthKey_XXXXXXXXXX.p8
python3 Tools/setup-signing.py
```

The script registers the three bundle IDs (`com.hmatt1.jqforshortcuts`, `.ShareExtension`, `.Controls`), turns on App Groups for each, creates one Apple Distribution certificate and three App Store profiles, and checks that each profile carries the App Group. The API cannot assign an App Group to a bundle ID, so the first run usually stops with the portal steps to do that by hand. Do them and run the script again; it reuses the certificate it already made.

### 4. Add the GitHub secrets

The script prints the first five, with `gh secret set` commands:

| Secret | Value |
| --- | --- |
| `IOS_DIST_CERT_P12_BASE64` | `.signing/distribution.p12.b64` |
| `IOS_DIST_CERT_PASSWORD` | `.signing/distribution.p12.password.txt` |
| `IOS_PROFILE_APP_BASE64` | `.signing/app.mobileprovision.b64` |
| `IOS_PROFILE_SHARE_BASE64` | `.signing/share.mobileprovision.b64` |
| `IOS_PROFILE_CONTROLS_BASE64` | `.signing/controls.mobileprovision.b64` |
| `APPSTORE_ISSUER_ID` | the API key's issuer ID |
| `ADMIN_APPSTORE_KEY_ID` | the API key's ID |
| `ADMIN_APPSTORE_P8_KEY` | the contents of the `.p8` file |

Delete `.signing/` afterwards. It holds a private key and is in `.gitignore`.

#### How these secrets were actually set up (a recipe for the next app)

GitHub never shows a secret's value again, so the secrets in another repository can't be copied with `gh`. They can only be re-created, or copied by a workflow that runs *inside* the repository that holds them. This project did the second, from `hmatt1/ios-shortcut-launcher-widget`, which already had the API key and a Distribution certificate. The same steps work for any new app.

**What you need to know first**

- **App IDs are explicit**, one per target: `com.hmatt1.jqforshortcuts`, `.ShareExtension`, `.Controls`. A wildcard (`com.hmatt1.*`) cannot use App Groups. The `group.` prefix belongs only to the App Group identifier, never to a bundle ID.
- **The only capability is App Groups.** All three targets' `.entitlements` files contain just `com.apple.security.application-groups`. The long *Capability Requests* list in the Developer Portal (CarPlay, DriverKit, Family Controls and so on) is for restricted entitlements Apple approves case by case. Ignore it unless the app uses one.
- **The App Group must be assigned by hand**, even though the script turns the capability on. In the portal: Identifiers, App Groups, register `group.com.hmatt1.jqforshortcuts`. Then for each App ID open it, App Groups, **Configure**, tick the group, Save. Ticking the capability box alone is not enough: profiles made without the group fail the script's check.
- **An account may hold only two Distribution certificates.** Creating a third fails with `409 You already have a current Distribution certificate or a pending certificate request`. One certificate signs every app on the account, so reuse an existing one instead of minting another (below). Check what exists under Certificates in the portal, or with `python3 Tools/setup-signing.py`, which lists them.
- **One App Store Connect API key serves every repository.** The three secrets `ADMIN_APPSTORE_KEY_ID`, `APPSTORE_ISSUER_ID` and `ADMIN_APPSTORE_P8_KEY` are the same in all of them. The key needs the Admin role to create profiles. If the `.p8` is lost, Apple cannot re-issue it: create a new key under Users and Access, Integrations.
- **The profiles are per app.** Each app needs its own, made by `setup-signing.py`.

**Copying the secrets with a one-off workflow**

1. Create a fine-grained personal access token with **Secrets: Read and write** on the new repository only (Settings, Developer settings). The built-in `GITHUB_TOKEN` cannot write to another repository. (For this project the `gh auth token` login token was used instead, which also works because it has the `repo` scope, but it reaches every repository, so prefer the fine-grained one.) Store it in the source repository as `JQ_REPO_SECRETS_TOKEN`:
   ```bash
   gh secret set JQ_REPO_SECRETS_TOKEN -R <owner>/<source-repo>
   ```
2. Add this workflow to the source repository (the one that already has the API key and certificate), changing `TARGET_REPO` and `DVHUU4ZMJ7` (the ID of the certificate to reuse, listed by the script's note or the portal):
   ```yaml
   name: Provision signing secrets
   on: workflow_dispatch
   permissions:
     contents: read
   jobs:
     provision:
       runs-on: ubuntu-latest
       env:
         TARGET_REPO: hmatt1/jq-for-shortcuts
         GH_TOKEN: ${{ secrets.JQ_REPO_SECRETS_TOKEN }}
       steps:
         - uses: actions/checkout@v4          # the new app, for Tools/setup-signing.py
           with:
             repository: ${{ env.TARGET_REPO }}
             token: ${{ secrets.JQ_REPO_SECRETS_TOKEN }}
         - run: pip install pyjwt cryptography
         - name: Reuse the existing Distribution certificate
           env:
             IOS_DIST_CERT_P12_BASE64: ${{ secrets.IOS_DIST_CERT_P12_BASE64 }}
             IOS_DIST_CERT_PASSWORD: ${{ secrets.IOS_DIST_CERT_PASSWORD }}
           run: |
             umask 077
             mkdir -p .signing
             printf '%s' "$IOS_DIST_CERT_P12_BASE64" > .signing/distribution.p12.b64
             printf '%s' "$IOS_DIST_CERT_PASSWORD" > .signing/distribution.p12.password.txt
             printf '{"id": "DVHUU4ZMJ7"}' > .signing/certificate.json
         - name: Create the profiles
           env:
             ASC_KEY_ID: ${{ secrets.ADMIN_APPSTORE_KEY_ID }}
             ASC_ISSUER_ID: ${{ secrets.APPSTORE_ISSUER_ID }}
             ADMIN_APPSTORE_P8_KEY: ${{ secrets.ADMIN_APPSTORE_P8_KEY }}
           run: |
             umask 077
             printf '%s\n' "$ADMIN_APPSTORE_P8_KEY" > "$RUNNER_TEMP/AuthKey.p8"
             ASC_PRIVATE_KEY_PATH="$RUNNER_TEMP/AuthKey.p8" python3 Tools/setup-signing.py
         - name: Store the secrets in the new repository
           env:
             ADMIN_APPSTORE_KEY_ID: ${{ secrets.ADMIN_APPSTORE_KEY_ID }}
             APPSTORE_ISSUER_ID: ${{ secrets.APPSTORE_ISSUER_ID }}
             ADMIN_APPSTORE_P8_KEY: ${{ secrets.ADMIN_APPSTORE_P8_KEY }}
           run: |
             set -e
             set_from_file() { gh secret set "$1" -R "$TARGET_REPO" < "$2"; }
             set_from_file IOS_DIST_CERT_P12_BASE64 .signing/distribution.p12.b64
             set_from_file IOS_DIST_CERT_PASSWORD .signing/distribution.p12.password.txt
             set_from_file IOS_PROFILE_APP_BASE64 .signing/app.mobileprovision.b64
             set_from_file IOS_PROFILE_SHARE_BASE64 .signing/share.mobileprovision.b64
             set_from_file IOS_PROFILE_CONTROLS_BASE64 .signing/controls.mobileprovision.b64
             printf '%s' "$ADMIN_APPSTORE_KEY_ID" | gh secret set ADMIN_APPSTORE_KEY_ID -R "$TARGET_REPO"
             printf '%s' "$APPSTORE_ISSUER_ID" | gh secret set APPSTORE_ISSUER_ID -R "$TARGET_REPO"
             printf '%s\n' "$ADMIN_APPSTORE_P8_KEY" | gh secret set ADMIN_APPSTORE_P8_KEY -R "$TARGET_REPO"
             gh secret list -R "$TARGET_REPO"
         - name: Delete key material
           if: always()
           run: rm -rf .signing "$RUNNER_TEMP/AuthKey.p8"
   ```
   The script prints only names and IDs, never key material, and the secrets are masked in the logs. If the source repository is public, never upload `.signing/` as an artifact.
3. Run it: `gh workflow run <file>.yml -R <owner>/<source-repo>`, then watch it with `gh run watch`.
4. **Afterwards**, delete the token secret, the workflow file, and the personal access token if you made one.

**Things that went wrong, and why**

| Symptom | Cause and fix |
| --- | --- |
| `The App Group ... is not assigned to` the three IDs | The group is not configured on the App IDs. Configure it in the portal, then re-run. |
| `409 You already have a current Distribution certificate` | The two-certificate cap. Reuse a certificate (above) or revoke an unused one in the portal. |
| An unusable certificate appeared after a failed run | The workflow deletes `.signing/` at the end, so a run that fails *after* creating a certificate loses its private key. Re-running mints another. Reusing an existing certificate avoids this; otherwise revoke the orphan. |
| `Unable to find Apple ID for Bundle ID` at the TestFlight upload | The app record does not exist yet. Create it in App Store Connect (step 5); the API cannot. |

### 5. Create the app in App Store Connect

**Apps**, **+**, **New App**: platform iOS, name `JQ for Shortcuts`, primary language English (U.S.), bundle ID `com.hmatt1.jqforshortcuts`, any SKU such as `jq-for-shortcuts`. The API cannot create the app record.

### 6. Turn on GitHub Pages

**Settings**, **Pages**: deploy from the `main` branch, `/docs` folder. This serves the privacy policy and the support page.

### 7. Build

Push to `main`, or run **iOS Build** from the Actions tab. The build tests everything, archives with the fixed certificate, checks that the seven actions' App Intents metadata is in the app and not in an extension, uploads to TestFlight and attaches the `.ipa` to a `build-<N>` release. Until the first `v*` tag, builds are version `1.0.0`.

### 8. Fill in the listing

Run **Update App Store Listing** from the Actions tab (leave **apply** off for a dry run first). It sets the name, subtitle, description, keywords, URLs, categories, age rating and review notes from `Tools/app-store-connect.py`; `AppStore/listing.md` has the same copy for reading. Then, by hand in App Store Connect:

- **App Privacy**: Get Started, **No, we do not collect data from this app**. The API has no resource for it.
- **Screenshots**: run **Generate App Store Screenshots**, download the zip from its `screenshots-run-<N>` release, and upload the iPhone and iPad sets. `AppStore/screenshots.md` has the shot list and captions.
- Pick the TestFlight build for the version and submit.

### 9. Release

Tag the version you submitted:

```bash
gh release create v1.0.0 --generate-notes
```

The tagged build uploads that exact version. Untagged pushes after it build the next patch version, `1.0.1`.

## Gallery shortcuts

R10.7 asks for each gallery entry to add a signed shortcut. Shortcuts signs files itself, so make them on a device once the app is on TestFlight:

1. Build the shortcut from the entry's steps in the Shortcuts app.
2. Share it, **Options**, **Anyone**, **Save to Files**.
3. Add the file to the repository as `App/Resources/Shortcuts/<entry id>.shortcut`, with the ids from `App/Resources/Gallery.json`: `latest-release`, `api-notification`, `array-to-spreadsheet`, `export-analysis`, `webhook-cleanup`, `folder-of-json`.

The entry then shows **Add to Shortcuts**, which hands the file to Shortcuts. An iCloud link works too: put it in the entry's `shortcutURL` in `Gallery.json`. Entries with neither show **Open Shortcuts to Build It**.

## Files

```
project.yml                          XcodeGen spec: app, share extension, controls, logic tests, screenshot tests
Packages/JQEngine/                   the jq 1.7.1 engine, its jqswift CLI and its tests
  Sources/JQEngine/Syntax/           lexer, parser, AST
  Sources/JQEngine/Compiler/         compiler and the builtin.jq prelude
  Sources/JQEngine/Runtime/          interpreter, builtins, regex, dates, @formats, limits
  Sources/JQEngine/JSON/             parser, writer, number formatting
  Sources/JQEngine/API/              JQFilter, errors, paths, syntax highlighting, the large-stack thread
  Scripts/generate-fixtures.py       records the conformance fixtures from real jq 1.7.1
Shared/Core/                         compiled into every target: the run pipeline, R8 messages, limits,
                                     output modes, JSON tools, stores, App Group, tree model, inbox
Shared/Intents/                      the open intents and Saved Filter entity, shared by the app and the controls
App/JQForShortcutsApp.swift          entry point; installs intent navigation before any window exists
App/Intents/                         the seven actions and the App Shortcuts
App/Model/                           app state and the Playground model
App/Views/                           Playground, Library, Gallery, Reference, Settings, Run in App, clipboard runner
App/Resources/                       sample, presets, cheat sheet and gallery as JSON
ShareExtension/                      Open in Playground and Run Saved Filter from the share sheet
Controls/                            the two Control Center and Lock Screen controls
AppLogicTests/                       host-less XCTest bundle over Shared/Core and the bundled content
AppScreenshots/                      UI tests that capture the App Store screenshots
Tools/setup-signing.py               one-time: bundle IDs, App Groups, certificate and the three profiles
Tools/app-store-connect.py           pushes the listing, categories, age rating and review notes
Tools/resolve-simulator.py           picks Simulator device types for screenshots.yml
Tools/organize-screenshots.py        renames screenshots exported from an xcresult bundle
Tools/refresh-content.py             recomputes bundled example outputs with jq 1.7.1
AppStore/listing.md                  the listing copy and review notes, for reading
AppStore/screenshots.md              the shot list
docs/                                GitHub Pages: privacy policy and support
.github/workflows/build.yml          test, archive, App Intents check, TestFlight upload, releases
.github/workflows/screenshots.yml    App Store screenshots on iPhone and iPad Simulators
.github/workflows/update-app-store.yml  runs Tools/app-store-connect.py
.github/workflows/list-certificates.yml lists or revokes signing certificates
.github/workflows/runner-info.yml    prints the runner's Xcode and Simulator runtimes
```

## Notes

- **The seven actions live only in the app.** `App/Intents` is compiled into the app alone, so Shortcuts runs actions in the app's process, with its memory budget and the Run in App option. The control intents in `Shared/Intents` are compiled into both the app and the controls extension, because a control that opens its app needs its intent in both. The build fails if an action's metadata shows up in an extension.
- **Background runs stop before iOS does.** iOS ends a background action at about 30 seconds, so the Timeout is capped at 25 seconds there and the action returns R8.5 with "turn on Run in App" as the next step. With Run in App the Timeout goes up to 600 seconds.
- **The engine runs on a 256 MB stack.** jq filters recurse, and a thread with a large stack turns deep recursion into an error instead of a crash (`JQThread.swift`).
- **The share extension has a small memory budget.** It takes inputs up to 10 MB and runs with a 48 MB memory cap. **Open in Playground** hands the file to the app through the App Group, and the app deletes it once read.
- **Input history is off by default.** When on, it keeps 10 runs, 1 MB per input and 20 MB in total, excluded from backups (R9.5).

## License

MIT, see `LICENSE`. The engine adapts jq's `builtin.jq` and is tested with jq's test suite, both MIT; see `THIRD_PARTY_NOTICES.md`.
