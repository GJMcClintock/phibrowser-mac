// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The page container's mount (mac ADR 0011) puts a tab's web view into the
/// window already at the page area's size. A web view resized after it
/// joined makes Chromium embed the new size with a zero deadline, and the
/// grown strip shows the gutter until the page's next frame. The web view
/// joins in the mount turn, except on the container's first mount, where it
/// joins one turn later.
@MainActor
final class WebContentMountGeometryTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows.removeAll()
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// A background tab that was never shown (opened with Cmd-click next to
    /// docked DevTools, say) gets its controller on its first focus.
    func testNeverShownTabJoinsTheWindowAtThePageAreaSize() throws {
        let fixture = try makeFixture()
        let incoming = fixture.webViews[1]

        fixture.state.focusingTab = fixture.tabs[1]
        try waitUntilMounted(incoming)

        try assertJoinedAtFinalSize(incoming)
    }

    /// A tab mounted before keeps its view tree while away; if the window was
    /// resized meanwhile, it rejoins at the new page area size.
    func testRemountedTabJoinsTheWindowAtTheResizedPageAreaSize() throws {
        let fixture = try makeFixture()
        let outgoing = fixture.webViews[0]
        fixture.state.focusingTab = fixture.tabs[1]
        try waitUntilMounted(fixture.webViews[1])
        XCTAssertNil(outgoing.window)

        let sizeBeforeResize = outgoing.frame.size
        fixture.window.setContentSize(NSSize(width: 1000, height: 640))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        fixture.state.focusingTab = fixture.tabs[0]
        try waitUntilMounted(outgoing)

        // Precondition: the resize changed the page area.
        XCTAssertNotEqual(outgoing.frame.size, sizeBeforeResize)
        try assertJoinedAtFinalSize(outgoing)
    }

    /// A tab mounted before that comes back to an unchanged page area rejoins
    /// at that size too.
    func testRemountedTabJoinsTheWindowAtAnUnchangedPageAreaSize() throws {
        let fixture = try makeFixture()
        let outgoing = fixture.webViews[0]
        fixture.state.focusingTab = fixture.tabs[1]
        try waitUntilMounted(fixture.webViews[1])
        XCTAssertNil(outgoing.window)

        let sizeWhileAway = outgoing.frame.size
        fixture.state.focusingTab = fixture.tabs[0]
        try waitUntilMounted(outgoing)

        // Precondition: the page area did not change.
        XCTAssertEqual(outgoing.frame.size, sizeWhileAway)
        try assertJoinedAtFinalSize(outgoing)
    }

    /// The first tab a page container mounts (a Space's first reveal, a new
    /// window) is mounted in its turn, but its web view joins the window on
    /// the next one, still at the page area's size.
    func testColdMountedWebViewJoinsTheWindowOnTheNextTurn() throws {
        let fixture = try makeFixture(mountingFirstTab: false)
        let incoming = fixture.webViews[0]

        // Mounts the focused tab synchronously.
        fixture.container.mountActiveTabForRestore()

        XCTAssertNotNil(fixture.container.currentWebPanelSize, "the tab was not mounted")
        XCTAssertNil(incoming.window, "the web view joined the window in the mount turn")
        var joinedByNextTurn: Bool?
        // Queued after the deferred update the mount scheduled.
        DispatchQueue.main.async { joinedByNextTurn = incoming.window != nil }
        try waitUntilMounted(incoming)
        XCTAssertEqual(joinedByNextTurn, true)
        try assertJoinedAtFinalSize(incoming)
    }

    /// The cold-mounted tab's web view takes the window's focus once it is in
    /// the window. The fixture's first mount is into an empty container.
    func testColdMountedWebViewTakesFocus() throws {
        let fixture = try makeFixture()

        XCTAssertTrue(fixture.window.firstResponder === fixture.webViews[0],
                      "first responder: \(String(describing: fixture.window.firstResponder))")
    }

    /// Switching away from a mounted tab stays one turn: the incoming web
    /// view is in the window when the mount returns, the outgoing one is out.
    func testSwitchFromAMountedTabJoinsTheWindowInTheMountTurn() throws {
        let fixture = try makeFixture()

        fixture.state.focusingTab = fixture.tabs[1]
        // Mounts the focused tab synchronously.
        fixture.container.mountActiveTabForRestore()

        XCTAssertNotNil(fixture.webViews[1].window)
        XCTAssertNil(fixture.webViews[0].window)
    }

    /// A never-shown successor of the closed current tab finds nothing
    /// current, but it is not the container's first mount: its web view joins
    /// in the mount turn, as the successor can already draw.
    func testSuccessorOfAClosedTabJoinsTheWindowInTheMountTurn() throws {
        let fixture = try makeFixture()

        // The close reaches the container before the focus change, as on
        // device.
        fixture.state.tabs = [fixture.tabs[1]]
        fixture.state.updateNormalTabs()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(fixture.container.currentWebPanelSize, "the closed tab is still current")
        var deferredAtMount: [Bool] = []
        fixture.container.willMountControllerForTesting = {
            deferredAtMount.append($0.hasDeferredContentUpdate)
        }
        fixture.state.focusingTab = fixture.tabs[1]
        // Mounts the focused tab synchronously.
        fixture.container.mountActiveTabForRestore()

        // Precondition: the successor's content waits for the deferred
        // update, so only the container's earlier mount lets it join now.
        XCTAssertEqual(deferredAtMount, [true])
        XCTAssertNotNil(fixture.webViews[1].window)
    }

    /// While AI Chat collapses, the page's web view keeps its pre-animation
    /// frame (frame sync is paused for the animation). If the page card
    /// dropped its inset at the start, the page area would grow around the
    /// frozen web view and uncover a strip above it, under the header, where
    /// the window's backdrop shows.
    func testCollapsingAIChatLeavesNoStripAboveThePausedWebView() throws {
        let restorePreferences = pinAIChatPreferences()
        defer { restorePreferences() }
        let fixture = try makeFixture()
        fixture.state.aiChatTabCreationGateOverrideForTesting = false
        let tab = fixture.tabs[0]
        let webView = fixture.webViews[0]
        let pageArea = try XCTUnwrap(webView.superview as? WebContentHostView)
        fixture.state.setAIChatCollapsed(for: tab, collapsed: false)
        waitForFrameSync(of: pageArea, paused: true)
        waitForFrameSync(of: pageArea, paused: false)

        fixture.state.setAIChatCollapsed(for: tab, collapsed: true)
        waitForFrameSync(of: pageArea, paused: true)
        var tallestStrip: CGFloat = 0
        let deadline = Date().addingTimeInterval(2)
        while pageArea.isFrameSyncPaused, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            // The page area is not flipped: a web view frozen at its old
            // height keeps its bottom edge and loses the top.
            tallestStrip = max(tallestStrip, pageArea.bounds.maxY - webView.frame.maxY)
        }

        XCTAssertFalse(pageArea.isFrameSyncPaused, "the collapse never finished")
        XCTAssertEqual(tallestStrip, 0, "uncovered strip above the paused web view")
        XCTAssertEqual(webView.frame, pageArea.bounds)
    }

    /// A collapse that replaces an expand still in flight keeps the page card
    /// separated until the collapse itself ends. AppKit also runs the
    /// completion of the replaced expand, which must not end the newer
    /// collapse's hold.
    func testCollapseReplacingAnExpandKeepsTheCardUntilItEnds() throws {
        let restorePreferences = pinAIChatPreferences()
        defer { restorePreferences() }
        let fixture = try makeFixture()
        fixture.state.aiChatTabCreationGateOverrideForTesting = false
        let tab = fixture.tabs[0]
        let webView = fixture.webViews[0]
        let pageArea = try XCTUnwrap(webView.superview as? WebContentHostView)
        let card = try XCTUnwrap(pageArea.superview)
        let split = try XCTUnwrap(sequence(first: card, next: \.superview)
            .lazy.compactMap { $0 as? NSSplitView }.first)
        let chatPane = try XCTUnwrap(split.arrangedSubviews.last)
        fixture.state.setAIChatCollapsed(for: tab, collapsed: false)
        waitForFrameSync(of: pageArea, paused: true)
        waitForFrameSync(of: pageArea, paused: false)

        // Collapse, expand and collapse again, each before the last ends.
        for collapsed in [true, false] {
            fixture.state.setAIChatCollapsed(for: tab, collapsed: collapsed)
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        }
        fixture.state.setAIChatCollapsed(for: tab, collapsed: true)
        var droppedWhileChatShows = false
        var tallestStrip: CGFloat = 0
        let deadline = Date().addingTimeInterval(2)
        while !chatPane.isHidden, chatPane.frame.width > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            if !chatPane.isHidden, chatPane.frame.width > 0, card.layer?.borderWidth == 0 {
                droppedWhileChatShows = true
            }
            tallestStrip = max(tallestStrip, pageArea.bounds.maxY - webView.frame.maxY)
        }

        XCTAssertTrue(chatPane.isHidden || chatPane.frame.width == 0, "the collapse never finished")
        XCTAssertFalse(droppedWhileChatShows, "the card dropped its inset mid-collapse")
        XCTAssertEqual(tallestStrip, 0, "uncovered strip above the paused web view")
    }

    /// Closing the extension side panel slides it out with the page's frame
    /// sync paused, as an AI Chat collapse does. If the page card dropped
    /// its inset at the start, the page area would grow around the frozen
    /// web view and uncover a strip above it.
    func testClosingExtensionSidePanelLeavesNoStripAboveThePausedWebView() throws {
        let restorePreferences = pinAIChatPreferences()
        defer { restorePreferences() }
        let fixture = try makeFixture()
        let controller = try showPageColor(in: fixture)
        let webView = fixture.webViews[0]
        let pageArea = try XCTUnwrap(webView.superview as? WebContentHostView)
        let panel = makePanel()
        defer { withExtendedLifetime(panel) {} }
        fixture.state.updateExtensionSidePanel(panel.state)
        waitForFrameSync(of: pageArea, paused: false)

        fixture.state.updateExtensionSidePanel(nil)
        waitForFrameSync(of: pageArea, paused: true)
        var tallestStrip: CGFloat = 0
        let deadline = Date().addingTimeInterval(2)
        while pageArea.isFrameSyncPaused, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            tallestStrip = max(tallestStrip, pageArea.bounds.maxY - webView.frame.maxY)
        }

        XCTAssertFalse(pageArea.isFrameSyncPaused, "the slide-out never finished")
        XCTAssertEqual(tallestStrip, 0, "uncovered strip above the paused web view")
        XCTAssertEqual(webView.frame, pageArea.bounds)
        // The card rejoined the header, and the tab strip with it.
        XCTAssertEqual(controller.tabStripPageColorPresentation.appearance, .dark)
    }

    /// The AI Chat ↔ extension side panel mutex closes the panel before the
    /// chat expands. The tab strip stays on the browser color through the
    /// handoff instead of flashing the page color.
    func testAIChatReplacingExtensionSidePanelKeepsTheTabStripInherited() throws {
        let restorePreferences = pinAIChatPreferences()
        defer { restorePreferences() }
        let fixture = try makeFixture()
        fixture.state.aiChatTabCreationGateOverrideForTesting = false
        let controller = try showPageColor(in: fixture)
        let panel = makePanel()
        defer { withExtendedLifetime(panel) {} }
        fixture.state.updateExtensionSidePanel(panel.state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        fixture.state.extensionSidePanelCloseRequestOverrideForTesting = { [weak state = fixture.state] in
            state?.updateExtensionSidePanel(nil)
        }
        var presentations: [WebContentHeaderPageColorPresentation] = []
        let subscription = controller.tabStripPageColorPresentationPublisher
            .sink { presentations.append($0) }
        defer { subscription.cancel() }

        fixture.state.toggleAIChat(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // Precondition: the chat took over from the panel.
        XCTAssertNil(fixture.state.extensionSidePanel)
        XCTAssertFalse(try chatItem(of: controller).isCollapsed)
        XCTAssertEqual(presentations, [.inherited])
    }

    /// Opening the panel over an expanded chat collapses the chat's split
    /// item synchronously in the container's panel sink. Combine may run
    /// that sink before the tab strip sees the panel; the tab strip stays on
    /// the browser color in between.
    func testExtensionSidePanelReplacingAIChatKeepsTheTabStripInherited() throws {
        let restorePreferences = pinAIChatPreferences()
        defer { restorePreferences() }
        let fixture = try makeFixture()
        fixture.state.aiChatTabCreationGateOverrideForTesting = false
        let controller = try showPageColor(in: fixture)
        fixture.state.toggleAIChat(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(try chatItem(of: controller).isCollapsed)
        let panel = makePanel()
        defer { withExtendedLifetime(panel) {} }
        var presentations: [WebContentHeaderPageColorPresentation] = []
        let subscription = controller.tabStripPageColorPresentationPublisher
            .sink { presentations.append($0) }
        defer { subscription.cancel() }

        // The container's sink, run first.
        _ = controller.collapseAIChatForPanelTransition(ghostIn: fixture.container.view)
        fixture.state.updateExtensionSidePanel(panel.state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // Precondition: the panel took over from the chat.
        XCTAssertTrue(fixture.tabs[0].aiChatCollapsed)
        XCTAssertEqual(presentations, [.inherited])
    }

    // MARK: - Helpers

    /// An extension side panel and the page view it shows, which the caller
    /// holds: a wrapper's `nativeView` is weak.
    private func makePanel() -> (state: BrowserState.ExtensionSidePanelState, view: NSView) {
        let wrapper = PageColorTestWebContentWrapper(urlString: "chrome-extension://test/panel.html")
        let view = NSView()
        wrapper.nativeView = view
        return (BrowserState.ExtensionSidePanelState(extensionId: "test-extension",
                                                     displayName: "Test Extension",
                                                     iconPNG: nil, wrapper: wrapper), view)
    }

    /// Gives the focused page a black page color and returns its controller,
    /// whose tab strip presentation now carries that color.
    private func showPageColor(in fixture: Fixture) throws -> WebContentViewController {
        try XCTUnwrap(fixture.tabs[0].webContentWrapper as? PageColorTestWebContentWrapper)
            .pageColor = .black
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let controller = try XCTUnwrap(fixture.container.children
            .compactMap { $0 as? WebContentViewController }.first)
        XCTAssertEqual(controller.tabStripPageColorPresentation.appearance, .dark)
        return controller
    }

    private func chatItem(of controller: WebContentViewController) throws -> NSSplitViewItem {
        let split = try XCTUnwrap(controller.children.compactMap { $0 as? NSSplitViewController }.first)
        return try XCTUnwrap(split.splitViewItems.last)
    }

    /// Pins the comfortable layout and the AI switch on (expanding the chat
    /// is gated on it). The returned closure gives the user's values back;
    /// setting nil removes a key that was absent.
    private func pinAIChatPreferences() -> () -> Void {
        let pins: [(key: String, value: Any)] = [
            (PhiPreferences.GeneralSettings.layoutModeKey, LayoutMode.comfortable.rawValue),
            (PhiPreferences.AISettings.phiAIEnabled.rawValue, true),
        ]
        let originals = pins.map { UserDefaults.standard.object(forKey: $0.key) }
        for pin in pins {
            UserDefaults.standard.set(pin.value, forKey: pin.key)
        }
        return {
            for (pin, original) in zip(pins, originals) {
                UserDefaults.standard.set(original, forKey: pin.key)
            }
        }
    }

    private struct Fixture {
        let state: BrowserState
        let container: WebContentContainerViewController
        let window: NSWindow
        let tabs: [Tab]
        /// Held here: a wrapper's `nativeView` is weak.
        let webViews: [MountGeometryProbeView]
    }

    /// Two tabs in a visible window, the first one focused and, unless
    /// `mountingFirstTab` is false, mounted. Each web view starts at a size
    /// of its own, as Chromium sizes a background tab to the active tab's
    /// container.
    private func makeFixture(mountingFirstTab: Bool = true) throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 12, localStore: store, profileId: "Default")

        let webViews = (0..<2).map { _ in
            MountGeometryProbeView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        }
        let tabs = webViews.enumerated().map { index, webView in
            let wrapper = PageColorTestWebContentWrapper(urlString: "https://tab\(index).example/")
            wrapper.nativeView = webView
            return Tab(guid: 900 + index, url: wrapper.urlString, isActive: index == 0,
                       index: index, webContentView: wrapper)
        }
        state.tabs = tabs
        state.updateNormalTabs()
        state.focusingTab = tabs[0]

        let container = WebContentContainerViewController(state: state)
        container.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentViewController = container
        window.orderFront(nil)
        if mountingFirstTab {
            try waitUntilMounted(webViews[0])
        }
        return Fixture(state: state, container: container, window: window, tabs: tabs,
                       webViews: webViews)
    }

    /// Waits for `webView` to join the window, then lets the display cycle
    /// run, where a late layout would land.
    private func waitUntilMounted(_ webView: NSView,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        _ = try XCTUnwrap(webView.window, "the tab was never mounted", file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    private func waitForFrameSync(of pageArea: WebContentHostView,
                                  paused: Bool,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while pageArea.isFrameSyncPaused != paused, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(pageArea.isFrameSyncPaused, paused,
                       "frame sync never became \(paused ? "paused" : "live")",
                       file: file, line: line)
    }

    private func assertJoinedAtFinalSize(_ webView: MountGeometryProbeView,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        let pageArea = try XCTUnwrap(webView.superview, file: file, line: line).bounds.size
        XCTAssertGreaterThan(pageArea.height, 0, file: file, line: line)
        XCTAssertEqual(webView.sizesInWindow, [pageArea],
                       "sizes since joining the window: \(webView.timeline)",
                       file: file, line: line)
    }
}

/// Stands in for a tab's web view: records every size it takes from the
/// moment it joins a window, and takes focus as a web view does.
private final class MountGeometryProbeView: NSView {
    private var entries: [(size: NSSize, uptime: TimeInterval)] = []

    override var acceptsFirstResponder: Bool { true }

    var sizesInWindow: [NSSize] { entries.map(\.size) }

    var timeline: String {
        let start = entries.first?.uptime ?? 0
        return entries.map { entry in
            let ms = Int(((entry.uptime - start) * 1000).rounded())
            return "\(Int(entry.size.width))x\(Int(entry.size.height)) at +\(ms) ms"
        }.joined(separator: ", ")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        entries = []
        record()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard window != nil else { return }
        record()
    }

    private func record() {
        guard entries.last?.size != frame.size else { return }
        entries.append((frame.size, ProcessInfo.processInfo.systemUptime))
    }
}
