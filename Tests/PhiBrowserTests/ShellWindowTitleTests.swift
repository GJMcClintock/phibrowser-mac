// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The hosted shell is the window on screen for every Space instance it
/// presents, so the Dock menu, the Window menu and Mission Control read its
/// title. It carries the presented instance's: the Space name until the
/// instance's Browser exists, then the title Chromium gives the hidden
/// window, which follows the active tab.
@MainActor
final class ShellWindowTitleTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var slots: [SpaceWindowSlot] = []
    private var chromiumWindows: [NSWindow] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 123460100

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "shell-title-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        // A switch goes only to a Space the manager knows.
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: LocalStore.defaultProfileId))
        for (index, name) in ["First Space", "Second Space"].enumerated() {
            context.insert(SpaceModel(spaceId: Self.spaceIds[index], profileId: LocalStore.defaultProfileId,
                name: name, colorHex: "#AAAAAA", iconName: "target", sortOrder: index))
        }
        try context.save()
        manager.bind(to: store.account)
        await drainMainQueue()
    }

    override func tearDown() async throws {
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
        chromiumWindows.forEach { $0.close() }
        chromiumWindows.removeAll()
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

    func testAnInstanceWithoutItsBrowserShowsTheSpaceName() throws {
        let (slot, _) = try makeSlot()

        XCTAssertEqual(slot.shell?.window.title, "First Space")
    }

    func testThePresentedInstancesBrowserTitlesTheShell() throws {
        let (slot, sessions) = try makeSlot()
        let shell = try XCTUnwrap(slot.shell?.window)
        let chromiumWindow = attachChromiumWindow(titled: "First page", to: sessions[0])
        XCTAssertEqual(shell.title, "First page", "the Browser's arrival puts its title on the shell")

        chromiumWindow.title = "First page, next tab"

        XCTAssertEqual(shell.title, "First page, next tab", "a tab switch or a navigation retitles the shell")
    }

    func testOnlyThePresentedInstanceTitlesTheShell() throws {
        let (slot, sessions) = try makeSlot()
        let shell = try XCTUnwrap(slot.shell?.window)
        let first = attachChromiumWindow(titled: "First page", to: sessions[0])
        let second = attachChromiumWindow(titled: "Second page", to: sessions[1])
        second.title = "Second page, next tab"
        XCTAssertEqual(shell.title, "First page", "a background instance leaves the shell's title alone")

        slot.activate(spaceId: Self.spaceIds[1], animated: false)
        XCTAssertTrue(slot.visibleController === sessions[1], "precondition: the switch presented the second Space")
        first.title = "First page, next tab"

        XCTAssertEqual(shell.title, "Second page, next tab", "the switch hands the shell to the entering instance")
    }

    // MARK: - Helpers

    private static let spaceIds = ["first", "second"]

    /// A shell presenting the first of two Space instances, neither with its
    /// Browser yet.
    private func makeSlot() throws -> (SpaceWindowSlot, [SpaceSessionController]) {
        let slot = SpaceWindowSlot(manager: manager, initialSpaceId: Self.spaceIds[0])
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        slots.append(slot)
        let sessions = Self.spaceIds.map { spaceId in
            nextWindowId += 1
            let state = UnseededBrowserState(windowId: nextWindowId, localStore: store,
                profileId: LocalStore.defaultProfileId, spaceId: spaceId)
            let session = SpaceSessionController(window: slot.shell!.window, windowId: state.windowId,
                profileId: state.profileId, spaceId: spaceId, account: store.account,
                slot: slot, browserState: state, dormant: true)
            slot.registerWindow(session, for: spaceId)
            return session
        }
        XCTAssertTrue(sessions[0].isPresented, "precondition: the first Space is presented")
        return (slot, sessions)
    }

    /// Stands in for the hidden window of the Browser Chromium spawns for
    /// `session`, titled as Chromium titles it.
    private func attachChromiumWindow(titled title: String, to session: SpaceSessionController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = title
        chromiumWindows.append(window)
        session.attachChromiumWindow(window)
        return window
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

/// A switch seeds an empty Browser with a tab through the bridge, which
/// these tests have no Chromium for.
private final class UnseededBrowserState: BrowserState {
    override func createQuickLookupTab(customGuid: String? = nil) {}
}
