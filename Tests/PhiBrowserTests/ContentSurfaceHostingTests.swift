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

    // MARK: - Helpers

    private final class Fixture {
        let container: WebContentContainerViewController
        let window: NSWindow
        let page: PageColorTestWebContentWrapper
        /// Held here: a wrapper's `nativeView` is weak.
        let webView: NSView
        let hosting: ContentSurfaceHosting
        var sends: [(address: NSObject, hosting: ContentSurfaceHosting.Hosting)] = []

        init(container: WebContentContainerViewController, window: NSWindow,
             page: PageColorTestWebContentWrapper, webView: NSView, hosting: ContentSurfaceHosting) {
            self.container = container
            self.window = window
            self.page = page
            self.webView = webView
            self.hosting = hosting
        }

        func lastSent() -> ContentSurfaceHosting.Hosting? {
            sends.last { $0.address === page }?.hosting
        }

        /// `rect`, in window coordinates, with its origin at the window's top left.
        func flipped(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX, y: window.frame.height - rect.maxY,
                   width: rect.width, height: rect.height)
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
        state.tabs = [tab]
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

        state.adoptContentSurface(NSView())
        let hosting = try XCTUnwrap(container.contentSurfaceHostingForTesting)
        let fixture = Fixture(container: container, window: window, page: page, webView: webView,
                              hosting: hosting)
        hosting.sendForTesting = { [unowned fixture] in fixture.sends.append(($0, $1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return fixture
    }
}
