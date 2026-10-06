# App Store listing copy

The copy for the "Prepare for Submission" page in App Store Connect, wrapped
for reading. `Tools/app-store-connect.py` sends the same text through the
App Store Connect API (`.github/workflows/update-app-store.yml`), and
`Tools/test_app_store_listing.py` fails when the two differ or a field is
over its limit.

## Name (30 characters)

    JQ for Shortcuts

Matches `CFBundleDisplayName`, so the listing and the Home Screen agree.

## Subtitle (30 characters)

    Reshape JSON with one action

## Promotional text (170 characters, editable without a new build)

    Pull exactly the values you need out of an API response, an export or a
    webhook. Test the filter in a live Playground, save it, and run it from
    Shortcuts.

## Description (4000 characters)

    JQ for Shortcuts runs jq filters on JSON inside Shortcuts. Give it the
    response from Get Contents of URL, a file or a dictionary, and one
    filter returns exactly the values, text or file your shortcut needs.

    One filter replaces the long chains of Repeat, If and Add to Variable
    actions that break when the data changes. Filter a list by a condition,
    sort by a nested field, group and count, rename keys, add up totals, or
    flatten nested lists.

    Write the filter in the Playground. Paste or import some JSON, type a
    filter, and the result updates as you type. Tap a value in the tree
    browser to insert its path. An error shows where the filter went wrong
    and what to try next. Save the filter with a name, and it appears in the
    Run Saved Filter action right away.

    Actions
    • Run JSON Filter: JSON and a filter in, typed results out. Lists stay
      lists, dictionaries stay dictionaries and numbers stay numbers.
    • Run Saved Filter: pick one of your saved filters by name.
    • Validate JSON: valid or not, with the line and column of the first
      problem.
    • Format JSON: pretty or compact, with sorted keys if you want them.
    • Get Value at Path and Set Value at Path: read or change one value with
      a path such as .data.items[3].name.
    • JSON to CSV: turn a list of objects into a CSV or TSV file.

    Also included
    • jq 1.7 syntax and builtins, with an offline cheat sheet where every
      example runs in the Playground
    • Presets for common jobs: pick keys, rename keys, sort, group and
      count, unique, flatten, merge and CSV
    • Arguments that pass a search term or a limit into a filter as $name,
      without building the filter from text
    • Six example shortcuts to start from
    • A share sheet extension, and Control Center and Lock Screen controls
    • Run in App for large exports, and a timeout and memory limit on every
      run

    Everything runs on your iPhone or iPad. The app has no accounts and
    makes no network requests, so your JSON never leaves the device. No ads,
    no analytics, nothing to buy.

## Keywords (100 characters, comma-separated, no spaces after commas)

    json,api,filter,parse,csv,webhook,automation,developer,format,validate,query,data,transform

"JQ" and "Shortcuts" are left out because the name is already indexed.

## Category

- Primary: **Developer Tools**
- Secondary: **Utilities**

## URLs

- Privacy policy: https://hmatt1.github.io/jq-for-shortcuts/ (`docs/index.html`)
- Support: https://hmatt1.github.io/jq-for-shortcuts/support/ (`docs/support/index.html`)
- Marketing: https://github.com/hmatt1/jq-for-shortcuts

The URLs assume the repository is `hmatt1/jq-for-shortcuts` with GitHub Pages
serving the `docs/` folder of `main`. Change `REPOSITORY` in
`Tools/app-store-connect.py` if the repository has another name.

## App Privacy

Answer by hand in App Store Connect, since the API has no resource for it:
App Privacy, Get Started, **No, we do not collect data from this app**. The
app contains no networking code (design R9.3).

## Age rating

4+. Every content question is None and every capability is No. The script
sets this through the API.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in `project.yml`, so builds skip
the encryption question.

## Notes for Review

    JQ for Shortcuts runs jq filters on JSON in its Playground and through
    seven Shortcuts actions. Everything runs on the device. The app has no
    accounts and makes no network requests.

    In the app: the Playground opens with sample JSON and a filter already
    loaded. Edit the filter and the result updates as you type. Save Filter
    stores it, and it then appears in the Run Saved Filter action.

    The actions, in the Shortcuts app:
    1. Create a new shortcut and add a Text action containing
    {"items":[{"name":"a","n":1},{"name":"b","n":2}]}
    2. Add Run JSON Filter from JQ for Shortcuts. Set Filter to
    .items[].name and Input to the Text.
    3. Run the shortcut. The result is a list with "a" and "b".

    The Library tab holds Presets and an example gallery. Each gallery entry
    lists the steps to build its shortcut in the Shortcuts app.

    The share extension (share a .json file from Files) and the controls
    (Control Center, add a control, JQ for Shortcuts) open the app.

    No accounts, no network access, no analytics, no ads, no in-app
    purchases.
