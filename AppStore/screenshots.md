# Screenshot shot list

Six shots tell the app's story in the order a new user meets it. Apple
allows up to ten per device class. Suggested captions are in *italics*.

1. **The Playground at first launch** (`01-playground`).
   The sample bookstore JSON, the sample filter and its two results, with
   the result types shown.
   *Write a filter. See the result as you type.*

2. **The tree browser** (`02-tree`).
   The Tree pane with `items` and its first object expanded.
   *Tap a value to insert its path.*

3. **An error with a next step** (`03-error`).
   `.names[]` on the cheat sheet's sample: the error under the editor, the
   position underlined, and the hint to use `.names[]?`. The symbol row above
   the keyboard shows too.
   *Errors say where, and what to try next.*

4. **The Library** (`04-library`).
   A saved filter at the top and the Presets below it.
   *Save a filter. It appears in Shortcuts by name.*

5. **An example shortcut** (`05-gallery`).
   The Latest release entry: steps, filter, values to change and sample input.
   *Six example shortcuts to start from.*

6. **The cheat sheet** (`06-reference`).
   The searchable Reference tab, where every example runs in the Playground.
   *jq 1.7, with examples that run offline.*

A seventh shot is worth taking by hand on a device: the **Run JSON Filter**
action in a shortcut in the Shortcuts app, with its sentence reading
"Run Filter … on …, output One item per result". UI tests cannot drive the
Shortcuts app.

## Automated: `.github/workflows/screenshots.yml`

Run it by hand (`gh workflow run screenshots.yml`) when the UI changes. It
boots an iPhone and an iPad Simulator on the `xcode-27` runner, runs the
`AppScreenshotsUITests` target (`AppScreenshots/ScreenshotTests.swift`), and
attaches the shots as a zip to a `screenshots-run-<N>` prerelease, a separate
tag namespace from the app's `v*` releases.

`Tools/resolve-simulator.py` picks the iPhone 13 Pro Max when the runner has
it, because its 1284x2778 shots fit App Store Connect's 6.5-inch slot, and
the newest iPad Pro for the 13-inch slot. The status bar is set to 9:41 with
full battery and signal.

The first run may need a small correction (an `xcresulttool` flag, a device
type name, an animation delay), since none of this can run outside a macOS
runner.
