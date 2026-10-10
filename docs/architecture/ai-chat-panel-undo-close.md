# AI Chat panel across undo close

Undo close brings a page tab back with the AI Chat panel it had when it was
closed: an expanded panel comes back expanded, on the same conversation. The
decision and the rejected alternatives are in the Chromium fork's
`docs/adr/0017-undo-close-carries-the-ai-chat-panel-in-the-closed-entry.md`.

## Panel record

Each page tab has at most one panel record: whether its panel is expanded and
which conversation the panel shows. A tab has a record while its panel is
expanded, or collapsed on a conversation; otherwise it has none. The client owns
the format (`AIChatPanelRecord`, JSON with a version `v`); Chromium stores the
string without reading it. A record in another version, or one that does not
parse, counts as none.

The conversation is read off the panel tab's URL. Chromium hands it over as
`chrome://conversation/<uuid>?...` (the page itself is
`index.html?...&conv_id=<uuid>`); both forms are read. Until a restored tab's panel
tab exists, the conversation it came back with stands in for it.

In a split the record stays with the pane that holds the shared panel
(`chatIdentifier(for:)`).

## Pushing it to Chromium

`BrowserState` recomputes a tab's record when the tab expands or collapses, when
its panel tab appears, and when the panel's URL names another conversation, and
pushes it through `AIChatPanelBridging.setAIChatPanelRecord(_:forTabId:)` only
when it changed. Closing the page tab pushes nothing: Chromium writes the record
it holds into the tab's recently-closed entry. A push that has not reached
Chromium when the tab closes is lost, so a conversation switched right before the
close comes back as the previous one.

## Coming back

Chromium hands the record back as `aiChatPanelRecord` in the new-tab payload of
the tab undo close restored, and only in the window it was restored into, so a
tab later moved to another window does not bring its panel along. `BrowserState`
pushes an expanded record straight back when it takes it over, which ends the
hand-back, so moving the tab away and back does not bring the panel again either.
When such a tab arrives with an expanded record, `BrowserState` expands it (subject to the AI
switch) and keeps the conversation. When it is the current tab, `BrowserState`
asks for its panel tab at once with `conv_id` in the panel URL, so the chat finds
the panel already there and leaves focus on the page; other tabs get theirs from
the ordinary on-demand path when shown.

A page controller created for a tab whose panel is already expanded expands the
chat pane while it is still appearing itself, and AppKit then sends the chat
controller no appearance callbacks; the page controller sets the chat up when
that expansion finishes. Without it the pane stays empty until the tab is shown
again.

Current limitations: a collapsed record is left alone on arrival; windows and
tab groups restored as a whole, the AI switch being off, guest mode and the
split handoff get no special handling yet; session restore never carries
records.

## Source and checks

- [Record, pushes and arrival](../../Sources/States/BrowserState+AIChatPanelRecord.swift)
- [Bridge seam](../../Sources/ChromiumBridge/AIChatPanelBridging.swift)
- [Panel creation](../../Sources/States/BrowserState.swift) (`createAIChatTab(for:chromeTabId:)`)
- [Chat pane expansion](../../Sources/UserInterface/WebContent/WebContentViewController.swift) (`animateAIChatCollapseTransition`)
- [Tests](../../Tests/PhiBrowserTests/BrowserStateAIChatPanelRecordTests.swift)

Check expanding and collapsing, switching conversations, closing the tab, and
undo close from Cmd+Shift+T, the History menu and Search Tabs on a signed-in build.
