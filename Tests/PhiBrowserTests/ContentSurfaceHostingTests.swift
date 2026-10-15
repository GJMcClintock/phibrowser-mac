// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// `ContentSurfaceHosting` tells the content surface (chromium ADR 0014)
/// where each web view is and the part of it that shows, as views tells
/// `NativeViewHostMac` upstream: the surface does not see AppKit move a web
/// view's ancestors, nor clip it to them.
@MainActor
final class ContentSurfaceHostingTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        WebContentContainerViewController.panelSlideDurationForTesting = nil
        windows.forEach { $0.close() }
        windows.removeAll()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// In the window from its top left, as Chromium keeps a view's bounds in
    /// its window, and whole while all of it shows.
    func testAWebViewIsToldItsRectInTheWindowFromTheTopLeft() throws {
        let fixture = try makeFixture()

        let sent = try XCTUnwrap(fixture.lastSent(), "the page was told nothing")

        let inWindow = fixture.webView.convert(fixture.webView.bounds, to: nil)
        XCTAssertEqual(sent.frame, fixture.flipped(inWindow))
        XCTAssertEqual(sent.clip, sent.frame, "the whole page shows")
    }

    /// A page whose frame sync is paused for a panel slide keeps its old
    /// width while its host narrows; only the part inside the host shows.
    func testAPageWiderThanItsHostIsClippedToTheHost() throws {
        let fixture = try makeFixture()
        let page = try XCTUnwrap(
            fixture.container.children.compactMap { $0 as? WebContentViewController }.first)
        page.setContentFrameSyncPausedForPanelTransition(true)

        fixture.webView.setFrameSize(NSSize(width: fixture.webView.frame.width + 200,
                                            height: fixture.webView.frame.height))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let sent = try XCTUnwrap(fixture.lastSent())
        let host = page.hostViewForTesting
        let inWindow = fixture.webView.convert(fixture.webView.bounds, to: nil)
        XCTAssertEqual(sent.frame, fixture.flipped(inWindow))
        XCTAssertEqual(sent.clip,
                       fixture.flipped(inWindow.intersection(host.convert(host.bounds, to: nil))))
        XCTAssertLessThan(sent.clip.width, sent.frame.width, "precondition: the page overruns its host")
    }

    /// A web view attached again during a hold starts square and on top
    /// while nothing is sent, so the first pass after the hold tells every
    /// web view again, changed or not.
    func testTheFirstPassAfterAHoldTellsEveryWebViewAgain() throws {
        let fixture = try makeFixture()
        let told = try XCTUnwrap(fixture.lastSent())
        fixture.hosting.isHeld = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let sendCount = fixture.sends.count

        fixture.hosting.isHeld = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(fixture.sends.count, sendCount + 1)
        XCTAssertEqual(fixture.lastSent(), told)
    }

    /// A framework without the rect and clip takes only the radii and the z
    /// order, so a move, which leaves those alone, sends it nothing.
    func testAFrameworkThatTakesNoPlacementIsNotToldAMove() throws {
        let fixture = try makeFixture()
        fixture.hosting.takesPlacement = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(fixture.lastSent()?.frame, .zero, "precondition: the page was told it has no rect")
        let rect = fixture.webView.convert(fixture.webView.bounds, to: nil)
        let sendCount = fixture.sends.count

        fixture.window.setContentSize(NSSize(width: 1300, height: 800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNotEqual(fixture.webView.convert(fixture.webView.bounds, to: nil), rect,
                          "precondition: the resize moved the page")
        XCTAssertEqual(fixture.sends.count, sendCount)
    }

    // MARK: - Extension side panel slide

    /// The extension side panel slides in by a Core Animation group, which
    /// puts the page's host at its end frame at once: the surface's view
    /// stays at its frame and no change to the page is told until the slide
    /// ends.
    func testASidePanelSlideHoldsTheSurfaceAndSendsNothing() throws {
        WebContentContainerViewController.panelSlideDurationForTesting = 60
        let fixture = try makeFixture()
        let surfaceFrame = fixture.surfaceView.frame
        let sendCount = fixture.sends.count

        fixture.slideInSidePanel()
        // The slide pauses the page's frame sync; a page laid out wider
        // meanwhile changes its rect, which a pass not held would send.
        fixture.webView.setFrameSize(NSSize(width: fixture.webView.frame.width + 200,
                                            height: fixture.webView.frame.height))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(fixture.hosting.isHeld)
        XCTAssertTrue(fixture.surfaceView.translatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(fixture.surfaceView.frame, surfaceFrame)
        XCTAssertEqual(fixture.sends.count, sendCount, "the page was told during the slide")
    }

    func testTheSlideEndReleasesTheHold() throws {
        WebContentContainerViewController.panelSlideDurationForTesting = 0.05
        let fixture = try makeFixture()
        let sendCount = fixture.sends.count

        fixture.slideInSidePanel()
        XCTAssertTrue(fixture.hosting.isHeld, "precondition: the slide holds")
        let deadline = Date().addingTimeInterval(2)
        while fixture.hosting.isHeld, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(fixture.hosting.isHeld)
        XCTAssertFalse(fixture.surfaceView.translatesAutoresizingMaskIntoConstraints)
        XCTAssertGreaterThan(fixture.sends.count, sendCount, "the settled page was not told")
    }

    func testATabSwitchReleasesTheHold() throws {
        try assertCuttingTheSlideShortReleasesTheHold { $0.state.focusingTab = $0.otherTab }
    }

    func testClosingTheCurrentTabReleasesTheHold() throws {
        try assertCuttingTheSlideShortReleasesTheHold { fixture in
            fixture.state.tabs = [fixture.otherTab]
            fixture.state.updateNormalTabs()
        }
    }

    func testClosingTheSidePanelReleasesTheHold() throws {
        try assertCuttingTheSlideShortReleasesTheHold { $0.container.detachExtensionSidePanel() }
    }

    func testContentFullscreenReleasesTheHold() throws {
        try assertCuttingTheSlideShortReleasesTheHold { fixture in
            let overlay = NSView(frame: fixture.container.view.bounds)
            fixture.container.view.addSubview(overlay)
            fixture.container.lendContentSurface(to: overlay)
        }
    }

    // MARK: - Helpers

    /// The slide is long enough that only `interrupt` can end it.
    private func assertCuttingTheSlideShortReleasesTheHold(
        _ interrupt: (Fixture) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        WebContentContainerViewController.panelSlideDurationForTesting = 60
        let fixture = try makeFixture()
        fixture.slideInSidePanel()
        XCTAssertTrue(fixture.hosting.isHeld, "precondition: the slide holds", file: file, line: line)

        interrupt(fixture)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(fixture.hosting.isHeld, file: file, line: line)
        XCTAssertFalse(fixture.surfaceView.translatesAutoresizingMaskIntoConstraints,
                       "the surface's view is not back on its constraints", file: file, line: line)
    }

    @MainActor
    private final class Fixture {
        let state: BrowserState
        let container: WebContentContainerViewController
        let window: NSWindow
        let page: PageColorTestWebContentWrapper
        /// Held here: a wrapper's `nativeView` is weak.
        let webView: NSView
        /// A second tab, not shown.
        let otherTab: Tab
        let surfaceView: NSView
        let hosting: ContentSurfaceHosting
        private let sidePanel = PageColorTestWebContentWrapper(urlString: "chrome-extension://panel/")
        private let sidePanelView = NSView()
        var sends: [(address: NSObject, hosting: ContentSurfaceHosting.Hosting)] = []

        init(state: BrowserState, container: WebContentContainerViewController, window: NSWindow,
             page: PageColorTestWebContentWrapper, webView: NSView, otherTab: Tab,
             surfaceView: NSView, hosting: ContentSurfaceHosting) {
            self.state = state
            self.container = container
            self.window = window
            self.page = page
            self.webView = webView
            self.otherTab = otherTab
            self.surfaceView = surfaceView
            self.hosting = hosting
            sidePanel.nativeView = sidePanelView
        }

        func lastSent() -> ContentSurfaceHosting.Hosting? {
            sends.last { $0.address === page }?.hosting
        }

        /// `rect`, in window coordinates, with its origin at the window's top left.
        func flipped(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX, y: window.frame.height - rect.maxY,
                   width: rect.width, height: rect.height)
        }

        /// Opens an extension side panel, which slides in, the window being on screen.
        func slideInSidePanel() {
            container.attachExtensionSidePanel(BrowserState.ExtensionSidePanelState(
                extensionId: "test-extension", displayName: "Test Extension", iconPNG: nil,
                wrapper: sidePanel))
        }
    }

    /// One tab, mounted in a visible window over a content surface, with
    /// every send recorded.
    private func makeFixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 24, localStore: store, profileId: "Default")

        let webView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let page = PageColorTestWebContentWrapper(urlString: "https://page.example/")
        page.nativeView = webView
        let tab = Tab(guid: 2400, url: page.urlString, isActive: true, index: 0, webContentView: page)
        let otherTab = Tab(guid: 2401, url: "https://other.example/", isActive: false, index: 1)
        state.tabs = [tab, otherTab]
        state.updateNormalTabs()
        state.focusingTab = tab

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
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        _ = try XCTUnwrap(webView.window, "the page was never mounted")

        let surfaceView = NSView()
        state.adoptContentSurface(surfaceView)
        let hosting = try XCTUnwrap(container.contentSurfaceHostingForTesting)
        let fixture = Fixture(state: state, container: container, window: window, page: page,
                              webView: webView, otherTab: otherTab, surfaceView: surfaceView,
                              hosting: hosting)
        hosting.sendForTesting = { [weak fixture] in fixture?.sends.append(($0, $1)) }
        // Whatever framework the host links.
        hosting.takesPlacement = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return fixture
    }
}
