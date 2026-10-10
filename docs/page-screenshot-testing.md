# Screenshot testing

## Isolated suites

Run from the repository root with Xcode command-line tools installed:

```sh
osascript -e 'tell application id "com.phibrowser.canary.Mac" to quit'
build-scripts/test-page-screenshots.sh
```

The script generates a dependency-free Swift package in
`build/PageScreenshotHarness`. It compiles the production screenshot service,
region selector, editor and exporters with controlled browser/CDP stubs.
The suites cover capture deadlines and identity checks, coordinate conversion,
clipboard preservation, retained annotations, selection modifiers, text editing,
undo/redo, crop geometry, continuous autoscroll and JPG/PDF output.

These tests do not launch the browser. They exercise the shared implementation
but do not establish packaged browser or Chromium integration behavior.

## Standalone app

```sh
build-scripts/test-page-screenshots.sh --fixture
build-scripts/test-page-screenshots.sh --render
```

`--fixture` builds and opens `Phi Screenshot Editor.app` in the harness directory.
The app uses a generated 1000 by 800 image and the shared production editor.
Its bundle identifier is `com.phibrowser.screenshot.fixture`.

`--render` writes offscreen editor layouts, a JPEG and a single-page PDF into
`build/PageScreenshotHarness/evidence`. Offscreen images check rendering;
interactive behavior requires exercising the app.

## Native integration

Provide the repository's Phi Framework build and resolve the Xcode project's
package dependencies. Run Xcode verification outside a restricted sandbox:

```sh
osascript -e 'tell application id "com.phibrowser.canary.Mac" to quit'
xcodebuild build-for-testing -project Phi.xcodeproj -scheme PhiBrowser-canary \
  -destination platform=macOS -derivedDataPath build/DerivedData-Screenshots
```

Hosted tests launch Phi and require a suitable test browser environment. Run
relevant screenshot test classes using `test-without-building` with the same
scheme, destination and derived-data directory.

## Interactive checks

- Capture full-page and visible-area screenshots; check dimensions, page identity
  and clipboard contents, including cancellation and capture failures.
- Create arrow, freehand, shape and text annotations. Verify drawing returns to
  Select, Shift repeats the tool and retained objects remain editable.
- Exercise selection, group transforms, text-local undo and document undo/redo.
- Enter Crop over an annotation and confirm that it remains unselected. At 100%
  zoom, drag beyond each viewport edge and hold the pointer stationary. Scrolling
  must continue until release or cancellation, with the image-space anchor fixed.
- Confirm Crop, undo and redo. Check image dimensions and retained annotation
  positions. Verify Escape and tool changes cancel the unconfirmed selection.
- Export JPG and PDF, inspect the output and exercise save cancellation, errors,
  unsaved close prompts and application quit while a write is pending.
