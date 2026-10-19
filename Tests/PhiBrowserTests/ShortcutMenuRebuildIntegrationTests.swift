// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import ObjectiveC
import XCTest
@testable import Phi

// Forward the real shortcut/configuration boundary while making the menu's
// access gate deterministic. Fixture windows must not become native Spaces.
private final class ShortcutMenuBridgeTestDelegate: NSObject {
    let original: NSObject
    var allowsBrowserAccess = true

    init(original: NSObject) { self.original = original }

    @objc func canShowChromiumWindow() -> Bool { allowsBrowserAccess }

    override func responds(to selector: Selector!) -> Bool {
        if NSStringFromSelector(selector).hasPrefix("mainBrowserWindowCreated:") { return false }
        return super.responds(to: selector) || original.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { original }
}

@MainActor
final class ShortcutMenuRebuildIntegrationTests: XCTestCase {
    private func setDelegate(_ delegate: AnyObject?, on bridge: NSObject) throws {
        let selector = NSSelectorFromString("setDelegate:")
        let implementation = try XCTUnwrap(bridge.method(for: selector))
        typealias Invoke = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(implementation, to: Invoke.self)(bridge, selector, delegate)
    }

    private func controller() throws -> NSObject {
        let type = try XCTUnwrap(NSClassFromString("PhiAppController"))
        let selector = NSSelectorFromString("sharedController")
        let method = try XCTUnwrap(class_getClassMethod(type, selector))
        typealias Invoke = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
        return try XCTUnwrap(unsafeBitCast(method_getImplementation(method), to: Invoke.self)(
            type, selector).takeUnretainedValue() as? NSObject)
    }

    private func menu(_ role: ChromiumMainMenuRole) throws -> NSMenu {
        try XCTUnwrap(NSApp.mainMenu?.item(withTag: role.rawValue)?.submenu)
    }

    private func waitForTabTitle(_ title: String) async throws {
        for _ in 0..<100 {
            // Startup/account callbacks may replace the menu while the page
            // loads. Detached menus must stop receiving updates; follow the
            // currently installed menu just as the user would.
            let menu = try menu(.tab)
            menu.delegate?.menuNeedsUpdate?(menu)
            if menu.items.contains(where: { $0.title == title && $0.action == NSSelectorFromString("activateTab:") }) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let menu = try menu(.tab)
        let observed = menu.items.filter { $0.action == NSSelectorFromString("activateTab:") }.map(\.title)
        _ = try XCTUnwrap(menu.items.first { $0.title == title && $0.action == NSSelectorFromString("activateTab:") },
                          "The Tab menu did not receive \(title); observed fixture titles: \(observed)")
    }

    private func waitForHistoryTitle(_ title: String) async throws {
        for _ in 0..<100 {
            let menu = try menu(.history)
            if menu.items.contains(where: { $0.title == title && $0.action == NSSelectorFromString("openHistoryMenuItem:") }) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let menu = try menu(.history)
        let observed = menu.items.filter { $0.action == NSSelectorFromString("openHistoryMenuItem:") }.map(\.title)
        _ = try XCTUnwrap(menu.items.first { $0.title == title && $0.action == NSSelectorFromString("openHistoryMenuItem:") },
                          "The History menu did not receive \(title); observed fixture titles: \(observed)")
    }

    func testShortcutChangesRebindDynamicMenusAndKeepReceivingTabUpdates() async throws {
        let dataDirectory = try XCTUnwrap(FileSystemUtils.launchUserDataDirectory)
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let isolatedPath = URL(fileURLWithPath: dataDirectory).resolvingSymlinksInPath().path
        _ = try XCTUnwrap(isolatedPath.hasPrefix(temporaryRoot + "/") ? dataDirectory : nil,
                          "This integration fixture requires the test launch's temporary Chromium profile")
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        let bridgeObject = try XCTUnwrap(bridge as? NSObject)
        let previousDelegate = try XCTUnwrap(bridge.delegate as? NSObject)
        let testDelegate = ShortcutMenuBridgeTestDelegate(original: previousDelegate)
        try setDelegate(testDelegate, on: bridgeObject)
        defer {
            try? setDelegate(previousDelegate, on: bridgeObject)
            bridge.requestRebuildMainMenu()
        }
        let controller = try controller()
        let previousConfiguration = Shortcuts.configuration
        let previousMainWindow = NSApp.mainWindow
        // An agent browser is hidden and excluded from session restore. Only
        // local data URLs are loaded; no user tabs are edited or closed.
        let browser = try XCTUnwrap(bridge.createAgentBrowser(withProfileId: nil))
        let window = try XCTUnwrap(browser["window"] as? NSWindow)
        let windowID = try XCTUnwrap(browser["windowId"] as? NSNumber).int64Value
        defer {
            bridge.executeCommand(Int32(CommandWrapper.IDC_CLOSE_WINDOW.rawValue), windowId: windowID)
            if let previousMainWindow {
                controller.perform(NSSelectorFromString("windowDidBecomeMain:"),
                                   with: Notification(name: NSWindow.didBecomeMainNotification,
                                                      object: previousMainWindow) as NSNotification)
            }
            Shortcuts.configuration = previousConfiguration
            CommandDispatcher.reloadPhiShortcutMap()
        }
        Shortcuts.configuration = ShortcutConfiguration(
            fileURL: previousConfiguration.fileURL,
            files: .init(read: { _ in Data("[]".utf8) }, write: { _, _ in }, backup: { _, _ in })
        )

        func addTab(_ title: String) throws {
            let url = "data:text/html,<title>\(title)</title>".addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
            XCTAssertTrue(bridge.createNewTabStrictly(withUrl: try XCTUnwrap(url),
                                                       windowId: windowID, focusAfterCreate: true))
        }
        try addTab("ShortcutMenuFirst")
        controller.perform(NSSelectorFromString("windowDidBecomeMain:"),
                           with: Notification(name: NSWindow.didBecomeMainNotification, object: window) as NSNotification)
        // A previous test may have detached bridges behind the denied access
        // gate without changing the loaded profile. Rebuild for this fixture's
        // allowed state rather than relying on a profile-change callback.
        bridge.requestRebuildMainMenu()
        try await waitForTabTitle("ShortcutMenuFirst")
        XCTAssertNotNil(try menu(.history).delegate)
        try await waitForHistoryTitle("ShortcutMenuFirst")

        for index in 0..<3 {
            let oldTabMenu = try menu(.tab)
            let oldHistoryMenu = try menu(.history)
            let oldTabDelegate = try XCTUnwrap(oldTabMenu.delegate)
            let oldHistoryDelegate = try XCTUnwrap(oldHistoryMenu.delegate)
            try Shortcuts.setOverride(.custom(.init(characters: String(index + 1), modifiers: [.control, .option])),
                                      for: .IDC_RELOAD).get()

            let newTabMenu = try menu(.tab)
            let newHistoryMenu = try menu(.history)
            XCTAssertFalse(newTabMenu === oldTabMenu)
            XCTAssertFalse(newHistoryMenu === oldHistoryMenu)
            XCTAssertNil(oldTabMenu.delegate)
            XCTAssertNil(oldHistoryMenu.delegate)
            XCTAssertFalse(try XCTUnwrap(newTabMenu.delegate) === oldTabDelegate)
            XCTAssertFalse(try XCTUnwrap(newHistoryMenu.delegate) === oldHistoryDelegate)
            XCTAssertFalse(oldTabMenu.items.contains { $0.action == NSSelectorFromString("activateTab:") })
            XCTAssertFalse(oldHistoryMenu.items.contains { $0.action == NSSelectorFromString("openHistoryMenuItem:") })
            try await waitForTabTitle("ShortcutMenuFirst")
            try await waitForHistoryTitle("ShortcutMenuFirst")

            let title = "ShortcutMenuUpdate\(index)"
            try addTab(title)
            try await waitForTabTitle(title)
            try await waitForHistoryTitle(title)
            let dynamicItems = try menu(.tab).items.filter { $0.action == NSSelectorFromString("activateTab:") }
            XCTAssertEqual(dynamicItems.count, index + 2)
            XCTAssertEqual(dynamicItems.filter { $0.title == title }.count, 1)

            // Bookmarks remain native-owned after the Chromium menu swap.
            let bookmarks = try XCTUnwrap(NSApp.mainMenu?.items.first {
                $0.tag == AppController.bookmarksMenuItemTag
            }?.submenu)
            XCTAssertTrue(bookmarks.delegate === NSApp.delegate)
            bookmarks.delegate?.menuWillOpen?(bookmarks)
            XCTAssertTrue(bookmarks.delegate === NSApp.delegate)
        }

        // A loaded profile does not bypass the browser-access gate on rebuild.
        testDelegate.allowsBrowserAccess = false
        bridge.requestRebuildMainMenu()
        XCTAssertNil(try menu(.tab).delegate)
        XCTAssertNil(try menu(.history).delegate)
        testDelegate.allowsBrowserAccess = true
        bridge.requestRebuildMainMenu()
        try await waitForTabTitle("ShortcutMenuFirst")
        XCTAssertNotNil(try menu(.history).delegate)
    }
}
