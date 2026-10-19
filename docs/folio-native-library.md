# Folio library

Mirage's `library.html` extension page is the only Folio UI. The native client
has no reader, library model, or database of its own: it opens that page and
otherwise leaves the saved Markdown/MHTML pairs to the extension, which reads
them through the file broker in `SaveForLaterService`.

File > Open Folio calls `SaveForLaterService.openLibrary()`, which opens the
page as a tab of the active browser Profile.

The Library's Folio section is a pane that hosts `library.html` itself, in the
attached Library panel and in the standalone Library window alike. The page is
a live Chromium tab of the Library's browser window kept off the Mac strip
(`BrowserState.libraryPaneTab`) — the off-strip pattern of a reader surface,
so Chromium owns its WebContents and the extension sees an ordinary tab (its
broker calls name it; a link from it opens a new tab), while the pane mounts
its native view in whichever window the Library is in. A web view mounted
outside the browser window's page container draws itself rather than through
the content surface, as Peek's and Reader's do, so the window it is in does
not matter.

The pane asks for the tab when it enters a window (`requestLibraryPaneTab`),
which creates `library.html#pane=<token>`; the arrival is held like a reader
surface and becomes the pane's tab only when its token answers the pending
request, so a session-restored copy of the URL is closed instead of hijacking
the pane. The tab is inserted in the background — a foreground insert would
activate it, which in hosted mode raises the shell window and takes key status
from the Library — and the same visibility exemption Peek and Reader use keeps
the inactive page painting. The pane closes the tab when it leaves its window —
a section switch, the panel's dismissal or the Library window closing — so
the page lives exactly as long as it is on screen. A link followed inside the
page navigates the tab away from `library.html`; it is then adopted into the
strip as a normal, focused tab and the Library yields to its browser window
(the standalone window stays open and asks for a fresh page). A stale `.folio`
selection falls back to Downloads only when the feature is off. It follows the
feature flag and Guest Mode restrictions.

The broker's listing reads only a bounded head of each Markdown file. Every
item's frontmatter block is served first, because the extension matches an item
by its `source` and an item listed without one would be saved again; whatever
budget remains extends the newest heads into the body. Basename validation and
the path jail apply to every broker file operation.

Validation lives in `SaveForLaterPathJailTests` and `SaveForLaterListingTests`.
