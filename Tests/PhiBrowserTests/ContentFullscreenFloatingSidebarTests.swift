// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// A page in content fullscreen is lifted into an overlay over the shell's
/// content view, while the floating sidebar still slides in from the left
/// edge above it. The panel has to take the clicks it shows, not the page
/// under it, and the page still covers every other view in the shell and
/// keeps every click outside the panel.
@MainActor
final class ContentFullscreenFloatingSidebarTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var slots: [SpaceWindowSlot] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 123458789
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "fullscreen-floating-sidebar-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: LocalStore.defaultProfileId))
        context.insert(SpaceModel(spaceId: "first", profileId: LocalStore.defaultProfileId,
            name: "first", colorHex: "#AAAAAA", iconName: "target", sortOrder: 0))
        try context.save()
        manager.bind(to: store.account)
        await drainMainQueue()
    }

    override func tearDown() async throws {
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
        webViews.removeAll()
        await drainMainQueue()
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        try await super.tearDown()
    }

    func testTheFloatingSidebarTakesClicksOverAFullscreenPage() throws {
        let (slot, session, webView) = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window)
        let tab = try XCTUnwrap(session.browserState.focusingTab)

        tab.isInContentFullscreen = true
        defer { exitFullscreen(tab) }
        let panel = try showPanel(in: slot)

        try assertClicks(in: window, reach: panel, andPage: webView)

        // AppKit's fullscreen transition resizes the window under the lifted page.
        window.setContentSize(NSSize(width: 1200, height: 800))
        slot.shell?.split.view.layoutSubtreeIfNeeded()
        try assertClicks(in: window, reach: panel, andPage: webView)

        exitFullscreen(tab)
        let panelFrame = panel.convert(panel.bounds, to: nil)
        let hit = try XCTUnwrap(hitTest(window, at: NSPoint(x: panelFrame.midX, y: panelFrame.midY)))
        XCTAssertTrue(hit.isDescendant(of: panel), "the panel keeps its clicks after fullscreen, not \(hit)")
    }

    /// The strip at the left edge only tracks the pointer to open the panel;
    /// while the panel is closed, a click on it reaches the fullscreen page.
    func testTheTriggerStripLeavesItsClicksToTheFullscreenPage() throws {
        let (slot, session, webView) = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window)
        let split = try XCTUnwrap(slot.shell?.split)
        let tab = try XCTUnwrap(session.browserState.focusingTab)

        tab.isInContentFullscreen = true
        defer { exitFullscreen(tab) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        split.setSidebarCollapsed(true, animated: false)
        let host = split.floatingSidebarHost
        // The strip comes up a moment after the column collapses.
        func visibleStrip() -> NSView? {
            host.view.subviews.first {
                !$0.isHidden && $0.frame.width == FloatingSidebarHostViewController.floatingSidebarTriggerWidth
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while visibleStrip() == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        split.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.isVisible, "precondition: the panel is closed")
        let strip = try XCTUnwrap(visibleStrip(), "precondition: the trigger strip is up")
        let stripFrame = strip.convert(strip.bounds, to: nil)

        let hit = try XCTUnwrap(hitTest(window, at: NSPoint(x: stripFrame.midX, y: stripFrame.midY)))
        XCTAssertTrue(hit.isDescendant(of: webView), "a click on the strip reaches the page, not \(hit)")
    }

    /// Search Tabs adds a full-window background to the shell's content
    /// view, after the panel's host. A page entering fullscreen covers it.
    func testAShellViewAddedAfterThePanelStaysUnderTheFullscreenPage() throws {
        let (slot, session, webView) = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window)
        let contentView = try XCTUnwrap(window.contentView)
        let later = NSView()
        contentView.addSubview(later)
        later.frame = contentView.bounds
        let tab = try XCTUnwrap(session.browserState.focusingTab)

        tab.isInContentFullscreen = true
        defer { exitFullscreen(tab) }
        let panel = try showPanel(in: slot)

        try assertClicks(in: window, reach: panel, andPage: webView)
    }

    /// A click in the panel takes the keyboard from the fullscreen page, and
    /// Esc leaves fullscreen only through the page. The panel gives the
    /// keyboard back as it hides.
    func testHidingThePanelGivesTheKeyboardBackToTheFullscreenPage() throws {
        let (slot, session, webView) = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window)
        let tab = try XCTUnwrap(session.browserState.focusingTab)

        tab.isInContentFullscreen = true
        defer { exitFullscreen(tab) }
        let panel = try showPanel(in: slot)
        XCTAssertTrue(window.firstResponder === webView, "precondition: the fullscreen page has the keyboard")
        // Stands in for a sidebar row that takes the keyboard when clicked.
        let row = FocusableView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
        panel.addSubview(row)
        XCTAssertTrue(window.makeFirstResponder(row), "precondition: the panel takes the keyboard")

        try XCTUnwrap(slot.shell?.split).floatingSidebarHost.hideFloatingSidebar(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(window.firstResponder === webView,
                      "the page has the keyboard again, not \(String(describing: window.firstResponder))")
    }

    /// The keyboard somewhere else (the omnibox, the AI chat) stays there
    /// when the panel hides over a fullscreen page.
    func testHidingThePanelLeavesTheKeyboardElsewhereAlone() throws {
        let (slot, session, _) = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window)
        let tab = try XCTUnwrap(session.browserState.focusingTab)

        tab.isInContentFullscreen = true
        defer { exitFullscreen(tab) }
        _ = try showPanel(in: slot)
        let elsewhere = FocusableView(frame: NSRect(x: 600, y: 10, width: 40, height: 20))
        try XCTUnwrap(window.contentView).addSubview(elsewhere)
        XCTAssertTrue(window.makeFirstResponder(elsewhere), "precondition: another view has the keyboard")

        try XCTUnwrap(slot.shell?.split).floatingSidebarHost.hideFloatingSidebar(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(window.firstResponder === elsewhere,
                      "the keyboard stays where it was, not \(String(describing: window.firstResponder))")
    }

    // MARK: - Helpers

    /// The sidebar column collapsed and its floating panel shown, over the
    /// page that has just been told it is fullscreen.
    private func showPanel(in slot: SpaceWindowSlot,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> NSView {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let split = try XCTUnwrap(slot.shell?.split, file: file, line: line)
        split.setSidebarCollapsed(true, animated: false)
        let host = split.floatingSidebarHost
        host.showFloatingSidebar()
        XCTAssertTrue(host.isVisible, "precondition: the panel is shown", file: file, line: line)
        let panel = try XCTUnwrap(host.floatingSidebarContainerView, file: file, line: line)
        split.view.layoutSubtreeIfNeeded()
        return panel
    }

    private func assertClicks(in window: NSWindow, reach panel: NSView, andPage webView: NSView,
                              file: StaticString = #filePath,
                              line: UInt = #line) throws {
        let contentView = try XCTUnwrap(window.contentView, file: file, line: line)
        let windowBounds = contentView.convert(contentView.bounds, to: nil)
        XCTAssertEqual(webView.convert(webView.bounds, to: nil), windowBounds,
                       "precondition: the page covers the window", file: file, line: line)
        let panelFrame = panel.convert(panel.bounds, to: nil)
        XCTAssertLessThan(panelFrame.maxX, windowBounds.maxX - 40,
                          "precondition: the panel leaves room for the page", file: file, line: line)

        let panelHit = try XCTUnwrap(hitTest(window, at: NSPoint(x: panelFrame.midX, y: panelFrame.midY)),
                                     file: file, line: line)
        XCTAssertTrue(panelHit.isDescendant(of: panel),
                      "a click on the panel lands in it, not in \(panelHit)"
                        + (panelHit.isDescendant(of: webView) ? " (the page)" : ""),
                      file: file, line: line)
        let pagePoint = NSPoint(x: windowBounds.maxX - 20, y: windowBounds.midY)
        let pageHit = try XCTUnwrap(hitTest(window, at: pagePoint), file: file, line: line)
        XCTAssertTrue(pageHit.isDescendant(of: webView),
                      "a click beside the panel reaches the page, not \(pageHit)", file: file, line: line)
        // The panel's glass starts an inset in from its container's edge.
        let gapPoint = NSPoint(x: panelFrame.minX + FloatingSidebarHostViewController.floatingSidebarInset / 2,
                               y: panelFrame.midY)
        let gapHit = try XCTUnwrap(hitTest(window, at: gapPoint), file: file, line: line)
        XCTAssertTrue(gapHit.isDescendant(of: webView),
                      "a click in the gap left of the panel reaches the page, not \(gapHit)"
                        + " (gap \(gapPoint), panel \(panelFrame), window \(windowBounds))",
                      file: file, line: line)
    }

    /// The view a mouse-down at `point`, in window coordinates, goes to. It
    /// asks the content view, not the window's frame view: in this windowed
    /// fixture the frame view keeps a few points at the window's edges for
    /// resizing, and a fullscreen window has no such edges.
    private func hitTest(_ window: NSWindow, at point: NSPoint) -> NSView? {
        window.contentView?.hitTest(point)
    }

    private func exitFullscreen(_ tab: Tab) {
        guard tab.isInContentFullscreen else { return }
        tab.isInContentFullscreen = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// A shell presenting one Space with one focused, mounted tab.
    private func makeSlot() throws -> (SpaceWindowSlot, SpaceSessionController, NSView) {
        let slot = SpaceWindowSlot(manager: manager, initialSpaceId: "first")
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        slots.append(slot)
        nextWindowId += 1
        let state = UnseededBrowserState(windowId: nextWindowId, localStore: store,
            profileId: LocalStore.defaultProfileId, spaceId: "first")
        let webView = FocusableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        webViews.append(webView)
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://first.example/")
        wrapper.nativeView = webView
        let tab = Tab(guid: nextWindowId, url: wrapper.urlString, isActive: true,
            index: 0, webContentView: wrapper)
        state.tabs = [tab]
        state.updateNormalTabs()
        state.focusingTab = tab
        let session = SpaceSessionController(window: slot.shell!.window, windowId: state.windowId,
            profileId: state.profileId, spaceId: "first", account: store.account,
            slot: slot, browserState: state, dormant: true)
        slot.registerWindow(session, for: "first")
        XCTAssertTrue(session.isPresented, "precondition: the Space is presented")
        slot.shell?.window.orderFront(nil)
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(webView.window, "precondition: the page is mounted")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return (slot, session, webView)
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

/// These Browsers have their tab already, and must never seed one.
private final class UnseededBrowserState: BrowserState {
    override func createQuickLookupTab(customGuid: String? = nil) {}
}

/// A view that can hold the keyboard, as a web view and a sidebar row can.
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
