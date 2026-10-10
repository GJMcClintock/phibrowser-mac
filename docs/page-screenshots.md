# Page screenshots

File > Capture Full Page captures the current webpage through
`PageScreenshotService`, copies a binary JPEG to the macOS clipboard, and opens
the screenshot editor. The
service opens `AppDevToolsPageSession` on the selected tab's `devToolsTargetId`,
queries `Page.getFrameTree`, `Page.getLayoutMetrics`, and the page's
`window.devicePixelRatio`, then sends `Page.captureScreenshot` with
`format: "jpeg"`, `quality: 85`, `fromSurface: true`, `captureBeyondViewport: true`, and an
explicit clip from `cssContentSize`. Width and height are rounded up. The clip
scale first fits the physical dimensions within 16,384 pixels per axis. If the
rounded output would still exceed 64 million pixels, it is reduced further in
both axes, with a one-pixel rounding margin. Pages already within both limits
keep scale 1. The pixel budget is checked after scaling, so wide or long pages
are not rejected merely because their unscaled dimensions exceed the budget.
Chromium encodes JPEG at quality 85; Swift copies and saves those bytes without
re-encoding. The returned JPEG still passes the validation limits below.
A final frame-tree query rejects a changed top-level
frame, loader, or URL. The session closes with `defer` on success and failure.

The page target, tab title, and originating `BrowserState.windowId` are snapped before the
first suspension. Switching tabs or windows while waiting does not change the
requested target or completion-toast destination. A missing target or native
new-tab page disables the menu action.

This is an app-owned socket-pair connection to Chromium, independent of Mirage
and external-agent consent. It neither enables Developer mode nor changes the
Allow agents to control Phi setting. No screenshot extension messages or chunk
reassembly are used. Switching agent access off closes all injected DevTools
connections, including an in-flight app screenshot; that capture reports failure.

One native operation may run at a time. Its monotonic deadline is 60 seconds,
including opening the session. The handshake is limited to 10 seconds and each command to 15 seconds,
both bounded by the remaining operation budget; late responses are rejected before committing to the clipboard. Only
screenshot sessions raise the CDP message limit from 8 MiB to 30 MiB plus 4 KiB
of JSON overhead. Other callers retain their existing 8 MiB limit. Fragmented
messages are subject to the same aggregate limit.

Before committing a copy, native code verifies JPEG type, start/end markers, readable
image data, a maximum of 30 MiB of base64, at most 32,768 pixels per dimension,
and at most 64 million pixels in total. Dimension limits are checked before
allocating a decoded bitmap. A changed pasteboard count preserves the user's
newer copy. Validation and capture failures leave clipboard contents intact;
AppKit's clear/write sequence is not transactional, so a write failure after
clearing can leave an empty clipboard and must report failure.

The success toast offers Save for six seconds. `PageScreenshotPresenter` retains
that operation's JPEG in the toast action, opens an asynchronous JPEG save panel,
and writes to the user-selected destination. Later clipboard changes and later
captures cannot change the image or title being saved. The default file name is
the captured tab title followed by `.jpg`, using the existing export filename
sanitizer for invalid characters and length limits. Empty or unusable titles
fall back to `Screenshot.jpg`; the system save panel confirms any overwrite.

Native tests cover target snapshots, single-flight capture, success and failure,
timeout, CDP ordering and parameters, dimensions and scale limits, document
identity changes, JPEG validation, clipboard preservation, menu placement and
the save action. Build and unit tests do not establish real page capture in the packaged
browser; that requires manual full-page JPEG inspection.

Sources: [native service](../Sources/States/PageScreenshotService.swift),
[CDP session](../Sources/ChromiumBridge/AgentCDP/AppDevToolsPageSession.swift),
[menu](../Sources/Application/AppController+Menu.swift).

## Visible-area capture

File > Capture Area lets the user drag over the focused page's visible content.
Release finishes a selection of at least two view points on each axis. Escape,
a secondary click, a click in another app window, a changed focused tab,
navigation/loading, a closed or hidden origin, or a changed page-view frame
cancels selection. User wheel scrolling is intercepted while the overlay is up.
The common-mode validity timer and local event monitor are removed on completion
and cancellation. A canceled operation leaves the clipboard untouched and
releases the single-flight capture gate.

`PageScreenshotRegionSelector` owns the AppKit overlay and returns a rectangle
in top-left page-view proportions. It does not call Chromium or pass screen
coordinates to CDP. `PageScreenshotRegion` normalizes flipped and unflipped
AppKit bounds and clamps the selection. The service maps those proportions into
`cssVisualViewport.pageX/pageY/clientWidth/clientHeight`. The visible CSS extent
also includes classic scrollbar thickness, divided by visual-viewport pinch
scale; the clip is then intersected with page content so scrollbar-only
selections are rejected. `window.devicePixelRatio` controls the physical image
budget and includes browser page zoom. Retina backing pixels never enter the
native selection rectangle.

The service snapshots document identity and viewport data before selection,
then compares them after selection and after capture. Scroll, page zoom, pinch
scale, scrollbar changes, and viewport resize invalidate an area result. The
final document-identity query is the last suspension before returning image
bytes, so a navigation during viewport validation cannot commit an old result.
The native origin is checked again before copying. The 60-second operation
budget includes selection. The full-page command order, JPEG settings,
16K-axis/64-million-pixel scaling, and clipboard guards remain in use.

Area capture sends its CSS clip directly to `Page.captureScreenshot`; it does
not first capture the full page and crop it. Neither capture mode changes
viewport emulation, resizes the page, or requests system screen-capture access.
The native overlay is outside Chromium's captured surface.

## Screenshot editor

The separate editor opens after a successful clipboard copy and stays alive
independently of the originating browser window. The shared AppKit module also
runs in a standalone synthetic app. It exposes Select, Crop, Arrow, Freehand, Text,
Rectangle, Ellipse, color, source-pixel stroke and text size, optional shape fill,
layer order, duplicate/delete, Undo/Redo, preview zoom, and JPG/PDF export.

Completed annotations remain separate editable objects. Select and drag an
object to move it; drag bounding-box handles to resize shapes/freehand/text, or
an arrow's two endpoint handles to change its geometry. Double-click retained
text to edit its content using a native NSTextView. Text box resize reflows and fits display text while retaining its base font size.
Marquee and Command-A select multiple objects; move, resize, style, duplicate,
delete and clipboard operations apply to the selected set.

V/C/A/P/T/R/O select the tools while the canvas has focus. Drawing completes in
Select mode by default; Shift repeats the tool. Shift marquee adds and Command
marquee subtracts. Option mirrors resize across the opposite edge. Command-D
duplicates, Delete removes selection, arrow keys move it (Shift for 10 pixels),
and native Edit menu Cut/Copy/Paste handles retained annotations. Space-drag
pans; pinch and Command-scroll zoom around the pointer. Command-Z and
Shift-Command-Z use this document's native undo manager, or the independent
typing undo manager while editing text.

Each completed pointer gesture, text session, or command records one undo
transaction, with at most 100 transactions retained. Escape, focus loss during
drawing, tool change, or export cancels an incomplete drag. Escape cancels text;
Command-Return, focus loss, another command, or export commits text. Each source
CGImage revision is immutable; cropping replaces the document image reference. The preview uses a background layer, per-object shape or
text layers, and a screen-size selection overlay. Zoom changes no source pixels.
Shape layer bounds cover only each object. Text previews render only that object
at preview scale; export lays out text at source size. No alpha scan or full
source bitmap redraw occurs on pointer input.

## Export and editor lifecycle

Export uses an asynchronous NSSavePanel sheet. Cancel performs no write and does
not mark edits saved. After confirmation, the editor snapshots the ordered
objects and source image; ImageIO JPEG encoding or CoreGraphics single-page PDF
writing happens off the main actor. Atomic writes use the current image dimensions, including confirmed crops.
JPG quality is 0.9; PDF uses one point per source pixel, with the background
image and vector/text annotations. Transparent pixels use a white backdrop.
Preview magnification and screen backing scale do not affect either export.
The unedited Save toast writes the captured JPG bytes unchanged.

A generation captured before writing prevents successful exports from marking
later edits saved. Failure preserves the document and undo history and offers
retry advice. Close rejects an active write or existing sheet and prompts for
unsaved edits. The existing PhiApplication quit entry reviews screenshot windows
before Chromium teardown. It awaits confirmed writes, rechecks generations,
then closes approved screenshot windows in one actor turn before browser prompts.
Approval does not latch across a canceled review. A final application gate waits
for screenshot and bookmark writes started during later browser quit prompts.
Screenshot window lifecycle is owned by the editor window controllers.

Decode checks image properties before allocation: at most 32,768 pixels per axis
and 64 million total pixels. These align with the capture budget. Unsupported
or invalid images retain the original Save action and are never silently reduced.

## Testing

[The screenshot testing guide](page-screenshot-testing.md) describes the
isolated test suites, standalone synthetic app and browser acceptance checks.

## Crop

The lasso toolbar entry (C) arms rectangular image selection without selecting
annotations, even with Shift or Command held. Crop appears when the drag ends.
Confirming crops the source pixels, rebases retained annotations and returns to
Select. Objects wholly outside the crop are removed; partially intersecting
objects remain editable and are clipped to the new canvas. Undo/redo restores
the image and annotations together. Unconfirmed selections do not add history.

Pointer drags use the canvas's shared autoscroll path. A 50 ms timer continues
scrolling when the pointer remains outside the viewport; each tick converts the
window position into image coordinates after scrolling. Mouse-up, Escape,
focus loss and tool changes stop the timer. The confirmation button stays within
the visible part of the canvas when a selection extends beyond the viewport.
