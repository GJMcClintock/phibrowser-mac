# Folio UI

The third layer, on top of [storage](folio-storage.md) and the
[backend API](folio-api.md). This is a new library page, not an extension
of the current one: the two-pane list-and-reader and the import sheet are
replaced, not kept beside it. What carries over is the reader's typography
and style preferences, which are the person's, and the rule that the page
is Mirage's and the native app only leads into it.

Everything shown is the folder. A scope is a location, a folder is a
directory the person made, an item is a `.md`, a subscription or a run is
a record file. The one thing on screen that is not on disk as a file is
the unread mark, which lives in hidden state.

There is no "keep" step and no second shelf. Saving is the decision; the
Inbox is where everything lives, folders arrange it, Watch tracks it,
Trash ends it.

## Shape

One page, three regions, two modes.

```
┌─────────┬───────────────────────┬──────────────────────────────────────┐
│ ⌘K      │ Inbox       12 new    │ ‹ 3 of 12 ›    Move to…  Watch  Trash │
│         │ ⌕ search              │──────────────────────────────────────│
│ Inbox 12│ ○ All  ○ Articles …   │                                      │
│  rust   │───────────────────────│   Why Rust ships slowly              │
│  work ▸ │ Today                 │   simonwillison.net · 4 min · saved  │
│ Watch  3│ ▣ Why Rust ships …    │                                      │
│         │   simonwillison · 2h  │   body …                             │
│ Feeds ⚙ │ ▣ Some thread on X    │                                      │
│  Tech ▾ │   x.com · 5h          │                                      │
│   Rust 9│ Yesterday             │                                      │
│   HN  18│ ▣ A recipe            │                                      │
│ Imports │   …                   │                                      │
│  Pocket │                       │                                      │
│         │                       │                                      │
│ Tags    │                       │                                      │
│  rust 12│                       │                                      │
│─────────│                       │                                      │
│ Import  │                       │                                      │
│ Subscr. │                       │                                      │
└─────────┴───────────────────────┴──────────────────────────────────────┘
   nav             list                          stage
```

- **Nav** is scopes: the Inbox and Watch, then every subscription
  under Feeds, every run under Imports, then Tags gathered from
  frontmatter. Each scope unfolds to show the folders the person made in
  it, nested as on disk. Counts are items, unread for a feed,
  new-since-last-visit for the Inbox. Two buttons at the bottom start the
  two things that are not browsing: Import and Subscribe.

**Folders of the person's own sit beside the sections.** A **Folders**
heading follows Inbox and Watch and lists the directories the person made
at the library root (`folder/<path>`), each with its count and its
sub-folders; its + makes a new top-level folder, and Move to… offers these
folders after the Inbox tree. The heading itself opens nothing, since the
root holds no items.

**Folio's folders and the person's look different.** A scope Folio owns
has a fixed icon and name (a tray for Inbox, a clock for Watch, waves for
a feed, an arrow for a run) and cannot be renamed or
deleted. A folder the person made shows the plain folder glyph, nests
anywhere inside a scope, and is renamed, moved or deleted in place. On
disk the same distinction is one character: Folio's directories start
with an underscore, the person's never do.
- **List** is the selected scope or folder: a breadcrumb when inside a
  folder, search, filter chips, the folders at the top as rows with a
  count and a chevron, then the items grouped by day. New folder sits in
  the header. Dragging a row onto a folder row or a nav folder moves it;
  the same drag onto a scope is Watch or To inbox. A row is favicon (through the extension favicon
  endpoint, nothing stored), title, a one-line excerpt from the head, site
  and age, and badges. Rows are dense; a shelf of three hundred items
  scrolls.
- **Stage** is whatever is open: the reader, or one of the panels that
  replace it (editor, history, a record). Its toolbar is built from the
  item's location.

**Browse mode** shows all three. **Focus mode** gives the stage the whole
page with a slim toolbar; Escape or the back chevron returns. Below 700px
of width, which is the attached Library panel, the page is always one
region at a time: nav as a popover from the title, list, then stage, with
back navigation. Between 700 and 1100 the nav folds to an icon rail.

The command palette, ⌘K, is the fourth way around: it searches items in
every scope by title, site, tag and excerpt, and offers every action by
name (Move to…, Watch, Subscribe…, Manage feeds…, Import…, Clean up…,
Check now, Poll now).
Contents search is a second step inside it, "Search inside items", which
reads files on demand with the bounded reader and is honest about taking
a moment. There is no index.

## The reader

The stage's default. Typography and the style controls are the reader
surface's, as today, with a header that states what the item is:

```
Why Rust ships slowly
simonwillison.net · saved Oct 21 · re-captured Nov 10 · edited Nov 12
[Article] [Webpage copy] [Original PDF]            ✎ Edit   ⟲ History
```

The segmented control switches between the markdown, the in-page MHTML
view, and for a file the file itself (`[Article] [Original]`: Article is
the markdown converted from it, Original the saved PDF or EPUB) in a
frame below the header, which shrinks to a strip so the surfaces stay a
click apart. A PDF's bytes come through the service as a
blob URL for the browser's own viewer. An EPUB renders through epub.js
(`stage/epub.ts`: `ePub(bytes).renderTo(holder, { flow: "scrolled-doc" })`,
scripts off, a default theme in the reader's colours and type), a
chapter at a time; the header carries previous/next chapter arrows and a
**Contents** picker built from the book's own navigation. A file opens
on itself, and its text renders when the
Article tab is first chosen, since a book's worth of markdown is slow to
lay out. An open-in-app icon hands the file to the system
(`openOriginal`). The provenance line is the frontmatter in words; a
partial or imported extraction keeps its note in the body.

Highlights are shown in place as marked passages with a margin marker,
and the toolbar's highlight count scrolls to the section. A note under a
highlight reads as a callout.

A watched item's header carries its status line, last checked, last
changed, next check, or the error, and a **Changes** strip (below). A feed
entry's header names the subscription, as a link to it.

## Triage

Nothing has to be done to a saved item; it is already where it lives.
But new arrivals are worth a pass, so the Inbox's new items form a queue
and the stage shows it as one: opening a new item puts `3 of 12` with
previous and next in the toolbar, and three actions, **Move to…**,
**Watch**, **Trash**. Move to… files the item in a folder of the Inbox
through a picker that remembers the last choice; Watch moves it to the
Watch shelf; each advances to the next new item without leaving the
stage, and skipping is just as fine, since an item left alone is simply
in the Inbox. Keyboard: `M`, `W`, Backspace, `→`/`←` to skip. A move
made by mistake is one `⌘Z` away for the length of the session.

The same queue toolbar appears on a run's items and a feed's entries,
with **To inbox** in place of Move to…, since the decision there is "do I
want this at all" rather than "where does it go". To inbox takes an
optional folder the same way.

## Editor

**Edit** turns the stage into a writing surface. Focus mode is implied: the
page gets out of the way.

```
Why Rust ships slowly                                      Preview ▢  Save
tags  rust  compilers  +
──────────────────────────────────────────────────────────────────────────
body, the reader's font, soft-wrapped, caret where you clicked

──────────────────────────────────────────────────────────────────────────
Highlights (2) are kept as they are                                   ▸
```

- The body is a live markdown editor (`stage/live-markdown.ts`,
  CodeMirror 6 with the GFM grammar): one text, decorated as it is read.
  Headings sit at their size, emphasis, code, links and quotes wear their
  look, bullets and rules draw as such, and the marks that say so (`#`,
  `**`, backticks, `[]()`) are hidden on every line but the ones the
  selection touches, where the source shows whole. ⌘B and ⌘I wrap or
  unwrap, Enter continues lists and quotes, Tab indents.
- Title and tags are fields; the rest of the frontmatter is not editable
  here and is rebuilt from the parsed block on save with `edited` set. The
  `## Highlights` section is outside the text and appended verbatim. A
  person cannot break the block the listing parses.
- **Preview** splits the stage, rendered on the right, scroll-locked by
  paragraph. Off by default, remembered.
- Save is `fs.writeText` with `expect` and `snapshot: "edit"`; ⌘S. The
  draft lives in `sessionStorage` per `location/basename` until saved or
  discarded, so leaving the stage does not lose it, and a row with an
  unsaved draft shows a dot in the list.
- A `conflict` reply shows a bar across the top: "Changed on disk since
  you opened it", with **Reload** (the draft goes to the clipboard first)
  and **Overwrite** (the other text is already in history as `external`).
- Plain `<textarea>`, no rich editing. The file is markdown and the
  preview is the reader.

## History

**History** replaces the reader with a timeline across the top of the
stage and a viewer under it.

```
Oct 21 ●───────● Nov 5 ──● Nov 10 ────────● Nov 12 ──○ now
      capture  external   capture ⧉       edit
──────────────────────────────────────────────────────────────────────────
[ Snapshot | Changes from previous | Changes to now ]            Restore
```

- The timeline is `fs.versions.list`, each version a dot labelled by kind
  in words: Re-captured, Changed outside Folio, Edited here, Rebuilt
  summary, Restored. `⧉` marks a capture that has its own webpage copy.
  Hovering shows the stamp; clicking selects; `←`/`→` walk it.
- The viewer renders the snapshot through the reader's sanitize pass, or
  a line diff computed in the page between the selected version and its
  predecessor or the current head, additions tinted, removals struck,
  frontmatter folded.
- **Restore** is two-step and calls `fs.versions.restore`; the old head
  becomes the newest dot, so a wrong restore is undone by restoring that.
- An item with no history shows the timeline with one dot, now, and says
  that versions start with the first edit or re-capture.

## Watch

An item is watched by being on the Watch shelf: the Watch action, File >
Watch This Page, or a file dragged into `_watch/`. On that shelf the
reader's header gains:

```
Checked 2h ago · unchanged since Nov 10 · next check tomorrow 6:00
Every [day ▾]   Only within [css selector          ]      Check now
Changes:  Nov 10 (+12 −4)   Oct 28 (+2 −2)   Oct 21 first capture
```

The **Changes** strip is the capture history as cards with the line
counts, each opening History on that diff. Schedule and selector write
the frontmatter with an `edit` snapshot. **Check now** is `sfl:watchCheck`
and the line follows `sfl:watchProgress`. In error, the line says why and
when it stopped, and Check now is the retry. **Stop watching** is To
inbox.

## Feeds

A subscription is a scope in the nav. Selecting it lists its entries,
unread first with a dot, read below; opening an entry marks it read.
Selecting the subscription's own name in the list header opens the
**record** on the stage:

```
Simon Willison                                     Poll now   Unsubscribe
https://simonwillison.net/atom/everything/
Every [hour ▾]   Fetch [entry ▾]   Keep for [30 days ▾]   tags  ai  python
Last polled 12 min ago · 9 unread · 27 entries                Mark all read
──────────────────────────────────────────────────────────────────────────
notes (the record's body, yours)
```

**Subscribe** in the nav opens a sheet: one field that takes a feed URL or
a page URL (a page goes to `sfl:discoverFeed` and the sheet lists what it
found), then the three settings with defaults. Unsubscribe is two-step
and says it trashes the entries that were not moved out.

**Manage feeds** is the gear beside the Feeds heading in the nav, and
"Manage feeds…" in the palette. It opens a screen on the stage that
lists every subscription as a table, one row each, across all feed
folders:

```
Feeds · 7 subscriptions · 27 unread                 Poll all   Import OPML   Export OPML   Subscribe
☐  Name                    Folder   Every   Fetch   Keep    Last polled    Unread  Status
☐  Rust Notes              Tech     hour    entry   30 d    12 min ago        9    active
☐  Hacker News front page  Tech     hour    entry   30 d    12 min ago       18    active
☐  Pragmatic Weekly        —        week    page    90 d    3 d ago           0    active
☐  Northwind changelog     Work     day     entry   30 d    Nov 9             0    error · 404 three times
☐  Old blog                —        paused  entry   forever  Sep 2            0    paused
  with 2 selected:  Pause   Resume   Move to folder…   Every ▾   Fetch ▾   Keep ▾   Unsubscribe…
```

- Every cell that is a setting is editable in place and writes that
  record's frontmatter; a row's name opens the record. Sorting is by any
  column; a filter chip narrows to errors, paused or unread.
- The checkbox column enables bulk changes: pause or resume, move to a
  feed folder, set schedule, fetch mode or keep policy for all selected,
  unsubscribe (two-step, with the count of entries that go).
- **Poll all** runs every active subscription now through the normal
  queue. **Import OPML** goes to the import flow; **Export OPML** writes
  the subscriptions, folders as outlines, to a file the person saves.
- A row in error shows the reason inline with Retry; a paused row keeps
  its entries and simply stops polling.

## Imports

**Import** in the nav opens the Import screen on the stage:

```
From a site you use
  [X] Bookmarks  Likes      [R] Saved  Upvoted      [▶] Liked  Watch later

From a file
  ┌─────────────────────────────────────────────────────────────────┐
  │   Drop an export here, or choose a file                        │
  │   Pocket · Instapaper · Raindrop · Omnivore · Bookmarks HTML   │
  │   OPML (subscriptions) · a folder of markdown                  │
  └─────────────────────────────────────────────────────────────────┘

Runs
  Pocket · Oct 21 · 2,993 imported, 7 failed · done     Move all to Inbox
  X bookmarks · Oct 22 · 140 of 200 · running  ▮▮▮▮▮▮▯▯▯▯      Stop
```

A dropped or chosen file is streamed to a new run's store and the run
starts; progress is in place and the run appears in the nav. Each run is
a scope with its items; its header on the stage carries the record,
**Resume** for a stopped or orphaned run, **Move all to Inbox** with the
count and an optional folder, and
**Delete run** (two-step, with the count that goes with it). Site imports
get the same record and scope.

## Drops

Anywhere on the page: a `.pdf` or `.epub` becomes an inbox item through
the chunked write and the worker's extraction; an export file starts a
run; a `.md` is declined with a line saying to put it in the folder,
which is the same thing. Several files run in order with one progress
line.

## Repair and clean-up

After each listing the page runs the re-pairing pass silently: an orphan
original matched to an item is moved beside it. One that matches nothing
is a dimmed row on its shelf, "webpage copy without an article", with
Reveal and Trash. Two files with one id are resolved on sight.

**Clean up…** from ⌘K or the nav's overflow lists what `fs.cleanup.list`
returns, each with what it was the history of and its size, nothing
pre-selected.

## States

| Where | Empty | Trouble |
| --- | --- | --- |
| Inbox | "Nothing to sort. Pages you save land here first." | |
| A folder | "Nothing in this folder yet. Drag items here, or move them from the palette." | |
| Watch | "Watch a page and Folio tells you when it changes." | error dot on the row, reason in the header |
| Feed | "Nothing yet. Poll now?" | reason in the record header |
| Run | "Nothing left here. Everything was moved or trashed." | failed count opens the ledger's failures |
| Page | | app too old: the scope says the feature is off; folder unreadable: one full-page notice, as today |

## Folio's window

File › Open Folio opens the library in a window of its own, a Kiosk made
for it (`KioskBrowserWindowController.configureAsFolioSurface`): the
address field, profile, extension and Space controls are gone, replaced by
Folio's title bar (`FolioTitleBarView`), a 30pt strip the traffic lights
sit centred in, with a book mark and the title in the middle, and the
whole strip a drag handle (double-click zooms). It wears the page's
sidebar colours: the page sends its sidebar background and text
(`saveForLater.windowChrome`) once it is up and again whenever the reading
theme changes them, so the bar and the sidebar below it read as one. The zoom
button is the ordinary zoom and the frame is remembered apart from other
Kiosks. A second Open Folio brings that window to the front. The page is
told it owns the window by the `#surface=window` fragment. The attached
Library panel is unchanged.

## Rail and one column

The page is the rail plus one column. The column is the list until
something opens on the stage (an item, a subscription, an import, the
editor); then the stage takes the column and Back, Escape, closing the
item or choosing another scope in the sidebar brings the list back. Rows
are wide: a 44px site tile, a 15px title, a two-line excerpt, the site and
badges (Webpage copy, PDF, EPUB, edited), the time on the right. A file's
excerpt line leads with its page count ("1373 pages · …"). The header carries the scope's title and counts
("35 entries · 14 unread"), search, the filter pills (All, Articles,
Videos, Books for EPUBs, PDFs, Highlighted), and on a
subscription Poll now and Mark all read.

## Sidebar foot and Settings

The sidebar ends in a quiet foot with no rule above it: **Settings** on
the left and the palette's ⌘ on the right. Import and Subscribe are `+`
buttons on the Imports and Feeds headings, as New folder is on Folders;
the Feeds heading keeps its gear for Manage feeds. Settings is a sheet:
Library (Show the library in Finder, Browser settings… which opens Phi's
General pane through `saveForLater.openSettings`, where the folder and
auto-save live), Feeds (Manage feeds…, Poll all), Maintenance (Clean up…,
Repair the library). Every entry is also a palette command.

## Sidebar rail

Collapsed, the sidebar is a 54px rail of one button per section and
nothing of what is inside: Inbox (new count as a badge), Watch, Folders,
then Feeds (unread count), Imports and Tags, with the palette, Import and
Subscribe at the foot. Each button opens its section in the column: Inbox,
Watch and Folders show their items and folders; Feeds, Imports and Tags
show their subscriptions, runs and tags as rows to pick from (with unread
counts on feeds). The panel toggle at the top of either state switches and
remembers the choice. The page's controls are shielded from the window
theme's button recolouring, which Phi injects into every page.

## Right-click

The page replaces the browser's context menu on its own rows, the way
web apps such as Notion do: one `contextmenu` listener on the app root
reads the thing under the pointer from the row's `data-ctx` marker and
shows a page-rendered `role="menu"` at the pointer, kept inside the
viewport, behind a full-screen overlay. An item offers Open, Move to… (or
To inbox), Watch (or To inbox), Show in Finder, Open original for a PDF or
EPUB, and Trash; a folder offers Open, New folder…, Rename folder… and
Delete folder…; a scope or the list background offers New folder…; a
feed offers Open, Poll now, Mark all read and Unsubscribe. Escape, an
outside click, scrolling and a window resize close it; the arrow keys walk
the items. Text fields keep the browser's menu.

## Keyboard

`↑`/`↓` select, Enter opens, Escape leaves focus mode, `M` move to…, `W`
watch, `E` edit, `H` history, Backspace arms trash, `⌘Z` undoes a move,
`1`–`2` the shelves, `⌘K` the palette, `⌘F` the list search, `⌘S` saves
in the editor. Suppressed inside fields and sheets.

## Refresh

The list refreshes on Folio's own writes, on focus and on
`saveForLater.folderChanged` for the scopes it shows, so a file saved in
Obsidian appears without a click. A refresh never drops an open draft, a
selected history dot or the triage position.

## Native entry points

| Where | Item | Does |
| --- | --- | --- |
| File menu | Save to Folio ⌥⌘S | unchanged; lands in the Inbox |
| File menu | Watch This Page | `save` with `location: watch` |
| File menu | Import into Folio… | open panel; a document is copied into the Inbox and `importFile` sent, an export becomes a run and `importRun` is sent; Folio opens on the right scope |
| File menu | Open Folio | unchanged |
| Page context menu | Save to Folio, Watch This Page | the same |
| Save toast | Add Note (exists), **Subscribe** when the page advertised a feed | opens the Subscribe sheet with the URL filled |
| Change toast | "Acme pricing changed" | opens History on the diff |

A feed poll never toasts; the unread count is the signal.

## Ownership

Mirage renders everything on the page and runs every long operation in
its worker. The native app contributes menus, the open panel, the context
menu, toasts and their actions, the settings row and the folder watcher,
and answers every broker call under the jail. No native view knows what an
item is. Every string comes from the message catalog under `folio_*` keys;
file names, frontmatter keys and section headings are structure and are
never localized.

## Out of scope

Rich editing, a full-text index, feed discovery in the address bar, and
a Chromium-side reader for `.mhtml`.
