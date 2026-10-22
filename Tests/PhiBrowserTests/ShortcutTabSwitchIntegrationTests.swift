// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class ShortcutTabSwitchIntegrationTests: XCTestCase {
    private var previousConfiguration: ShortcutConfiguration!
    private var directory: URL!
    private var accountDirectory: URL!
    private var store: LocalStore!
    private var controller: SpaceSessionController!
    private var window: NSWindow!
    private var wrappers: [PageColorTestWebContentWrapper] = []
    private var manager: TabSwitchManager { controller.browserState.tabSwitchManager }
    private var activations: [Int] { wrappers.map(\.setAsActiveTabCallCount) }
    private let forward = ShortcutsKey(characters: "j", modifiers: .control)
    private let backward = ShortcutsKey(characters: "k", modifiers: .command)

    override func setUp() async throws {
        previousConfiguration = Shortcuts.configuration
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "shortcut-switcher-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        window = makeWindow()
        let state = BrowserState(windowId: 987654323, localStore: store,
                                 profileId: LocalStore.defaultProfileId, spaceId: UUID().uuidString)
        controller = SpaceSessionController(window: window, windowId: state.windowId,
            profileId: state.profileId, spaceId: state.spaceId, account: account,
            browserState: state, dormant: true)
        wrappers = (1...3).map { PageColorTestWebContentWrapper(urlString: "https://example.test/tab-\($0)") }
        state.tabs = wrappers.enumerated().map { index, wrapper in
            Tab(guid: 987654330 + index, url: wrapper.urlString,
                isActive: index == 0, index: index, webContentView: wrapper)
        }
        state.focusingTab = state.tabs[0]
        for tab in state.tabs.reversed() { manager.recordActiveTab(tab) }
        XCTAssertEqual(manager.recentTabIDs, state.tabs.map(\.guid))
        configure(forward: forward, backward: backward)
    }

    override func tearDown() async throws {
        manager.cancelSession()
        controller.discardDormant()
        window.close()
        controller = nil
        window = nil
        wrappers = []
        Shortcuts.configuration = previousConfiguration
        CommandDispatcher.reloadPhiShortcutMap()
        let drained = expectation(description: "Switcher fixture UI updates drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func testEachDirectionUsesItsOwnInitiatingBinding() throws {
        try press(backward)
        try flags(.command)
        XCTAssertEqual(activations, [0, 0, 0])
        try flags([])
        XCTAssertEqual(activations, [0, 0, 1])
        try press(forward)
        try flags(.control)
        XCTAssertEqual(activations, [0, 0, 1])
        try flags([])
        XCTAssertEqual(activations, [0, 1, 1])
    }

    func testReverseStillWorksWithForwardDisabledAndOldKeysDoNotMatch() throws {
        configure(forward: nil, backward: backward)
        try press(forward, handled: false)
        try press(.init(characters: "\t", modifiers: .control), handled: false)
        try press(.init(characters: "\t", modifiers: [.control, .shift]), handled: false)
        try press(backward)
        try flags(.command)
        XCTAssertEqual(activations, [0, 0, 0])
        try flags([])
        XCTAssertEqual(activations, [0, 0, 1])
    }

    func testShiftAndCapsLockDoNotProlongTheGesture() throws {
        let key = ShortcutsKey(characters: "\t", modifiers: [.control, .shift])
        configure(forward: key, backward: .init(characters: "k", modifiers: [.control, .shift]))
        try press(key)
        try flags([.control, .shift, .capsLock])
        XCTAssertEqual(activations, [0, 0, 0])
        try flags([.shift, .capsLock])
        XCTAssertEqual(activations, [0, 1, 0])
    }

    func testReleasingEitherInitiatingHoldKeyCommitsExactlyOnce() throws {
        let key = ShortcutsKey(characters: "j", modifiers: [.command, .control])
        configure(forward: key, backward: backward)
        for remaining in [NSEvent.ModifierFlags.command, .control] {
            let before = wrappers[1].setAsActiveTabCallCount
            try press(key)
            try flags([.command, .control])
            XCTAssertEqual(wrappers[1].setAsActiveTabCallCount, before)
            try flags(remaining)
            try flags([])
            XCTAssertEqual(wrappers[1].setAsActiveTabCallCount, before + 1)
        }
    }

    func testRebindingDuringGestureDoesNotReplaceItsAnchor() throws {
        try press(forward)
        configure(forward: .init(characters: "j", modifiers: .option), backward: nil)
        try flags(.control)
        XCTAssertEqual(activations, [0, 0, 0])
        try flags(.option)
        XCTAssertEqual(activations, [0, 1, 0])
        try press(forward, handled: false)
    }

    func testChangingDirectionKeepsAnchorAndDismissesVisibleOverlayOnRelease() throws {
        try press(forward)
        // Subsequent steps use the active session's candidates and anchor.
        try press(backward)
        XCTAssertEqual(window.childWindows?.filter(\.isVisible).count, 1)
        try flags(.control)
        XCTAssertEqual(activations, [0, 0, 0])
        try flags([])
        XCTAssertEqual(activations, [1, 0, 0])
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
    }

    func testForeignWindowEventsAreIgnoredAndLosingContextCancels() throws {
        let otherWindow = makeWindow()
        defer { otherWindow.close() }
        try press(forward)
        try flags([], in: otherWindow)
        XCTAssertEqual(activations, [0, 0, 0])
        try flags([])
        XCTAssertEqual(activations, [0, 1, 0])
        for notification in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            try press(forward)
            NotificationCenter.default.post(name: notification,
                object: notification == NSWindow.didResignKeyNotification ? window : NSApp)
            try flags([])
            manager.revealOverlayIfAnchorStillDown(modifiers: [])
            XCTAssertEqual(activations, [0, 1, 0])
            XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        }
    }

    func testShiftOnlyNavigationAndMenuInvocationCommitImmediately() throws {
        let key = ShortcutsKey(characters: "\u{F72D}", modifiers: .shift)
        configure(forward: key, backward: backward)
        try press(key)
        XCTAssertEqual(activations, [0, 1, 0])
        let item = NSMenuItem(title: "Previous recent tab", action: nil, keyEquivalent: "")
        item.tag = CommandWrapper.PHI_TAB_SWITCHER_BACKWARD.rawValue
        XCTAssertTrue(CommandDispatcher.dispatchCommand(item, window: window))
        XCTAssertEqual(activations, [0, 1, 1])
        try flags([])
        XCTAssertEqual(activations, [0, 1, 1])
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
    }

    func testDelayedCheckRevealsHeldGestureAndCommitsMissedRelease() throws {
        try press(backward)
        manager.revealOverlayIfAnchorStillDown(modifiers: .command)
        XCTAssertEqual(window.childWindows?.filter(\.isVisible).count, 1)
        XCTAssertEqual(activations, [0, 0, 0])
        try flags([])
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        try press(forward)
        manager.revealOverlayIfAnchorStillDown(modifiers: [])
        manager.revealOverlayIfAnchorStillDown(modifiers: [])
        XCTAssertEqual(activations, [0, 1, 1])
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        try press(forward)
        manager.cancelSession()
        manager.revealOverlayIfAnchorStillDown(modifiers: .control)
        XCTAssertEqual(activations, [0, 1, 1])
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
    }

    private func configure(forward: ShortcutsKey?, backward: ShortcutsKey?) {
        Shortcuts.configuration = ShortcutConfiguration(overrides: [
            CommandWrapper.PHI_TAB_SWITCHER_FORWARD.rawValue: forward.map(ShortcutOverride.custom) ?? .disabled,
            CommandWrapper.PHI_TAB_SWITCHER_BACKWARD.rawValue: backward.map(ShortcutOverride.custom) ?? .disabled
        ])
        CommandDispatcher.reloadPhiShortcutMap()
    }

    private func press(_ key: ShortcutsKey, handled: Bool = true) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: key.modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: 38))
        XCTAssertEqual(CommandDispatcher.handleKeyEquivalent(event, window: window), handled)
    }

    private func flags(_ modifiers: NSEvent.ModifierFlags, in otherWindow: NSWindow? = nil) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
            modifierFlags: modifiers, timestamp: 0, windowNumber: (otherWindow ?? window).windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59))
        manager.handleFlagsChanged(event)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
