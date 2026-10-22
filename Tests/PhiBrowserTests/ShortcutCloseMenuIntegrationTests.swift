// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import ObjectiveC
import XCTest
@testable import Phi

@MainActor
final class ShortcutCloseMenuIntegrationTests: XCTestCase {
    private var previousConfiguration: ShortcutConfiguration?

    override func setUpWithError() throws {
        previousConfiguration = Shortcuts.configuration
    }

    override func tearDownWithError() throws {
        Shortcuts.configuration = try XCTUnwrap(previousConfiguration)
        ChromiumLauncher.sharedInstance().bridge?.requestRebuildMainMenu()
        previousConfiguration = nil
    }

    private func buildMenu(_ overrides: [CommandWrapper: ShortcutOverride]) throws -> NSMenu {
        Shortcuts.configuration = ShortcutConfiguration(
            overrides: Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }),
            fileURL: previousConfiguration?.fileURL,
            files: .init(
                read: { _ in throw CocoaError(.fileReadNoPermission) },
                write: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                backup: { _, _ in throw CocoaError(.fileWriteNoPermission) }
            )
        )
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        bridge.requestRebuildMainMenu()
        return try XCTUnwrap(NSApp.mainMenu)
    }

    private func closeItem(_ identifier: String, in menu: NSMenu) throws -> NSMenuItem {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.identifier?.rawValue == identifier { return item }
                if let submenu = item.submenu, let result = find(submenu) { return result }
            }
            return nil
        }
        return try XCTUnwrap(find(menu), "Missing stable close-menu identity: \(identifier)")
    }

    // Exercise the real controller's role adaptation with both window contexts,
    // without closing a user window or depending on desktop activation.
    private func updateRoles(hasBrowserTabs: Bool) throws {
        let controllerClass = try XCTUnwrap(NSClassFromString("PhiAppController"))
        let sharedSelector = NSSelectorFromString("sharedController")
        let sharedMethod = try XCTUnwrap(class_getClassMethod(controllerClass, sharedSelector))
        typealias Shared = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
        let controller = unsafeBitCast(method_getImplementation(sharedMethod), to: Shared.self)(
            controllerClass, sharedSelector).takeUnretainedValue()
        let selector = NSSelectorFromString("updateCloseMenuItemsForBrowserWindow:")
        let method = try XCTUnwrap(class_getInstanceMethod(controllerClass, selector))
        typealias Update = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Update.self)(controller, selector, hasBrowserTabs)
    }

    private func assertRole(_ item: NSMenuItem, command: CommandWrapper, action: String,
                            hidden: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(item.tag, hidden ? 0 : command.rawValue, file: file, line: line)
        XCTAssertEqual(item.action, hidden ? nil : NSSelectorFromString(action), file: file, line: line)
        XCTAssertEqual(item.isHidden, hidden, file: file, line: line)
    }

    func testSwappedCloseKeysKeepCommandIdentityAcrossWindowChangesAndRebuilds() throws {
        for _ in 0..<2 {
            let menu = try buildMenu([
                .IDC_CLOSE_TAB: .custom(.init(characters: "w", modifiers: [.command, .shift])),
                .IDC_CLOSE_WINDOW: .custom(.init(characters: "w", modifiers: .command))
            ])
            let tab = try closeItem("phi.closeTab", in: menu)
            let window = try closeItem("phi.closeWindow", in: menu)
            for hasTabs in [true, false, true] {
                try updateRoles(hasBrowserTabs: hasTabs)
                assertRole(tab, command: .IDC_CLOSE_TAB, action: "commandDispatch:", hidden: !hasTabs)
                assertRole(window, command: .IDC_CLOSE_WINDOW, action: "performClose:")
                XCTAssertEqual(tab.keyEquivalent, "W")
                XCTAssertEqual(window.keyEquivalent, "w")
                XCTAssertEqual(tab.keyEquivalentModifierMask, .command)
                XCTAssertEqual(window.keyEquivalentModifierMask, .command)
            }
        }
    }

    func testDisabledCloseKeysNeverAcquireTheOtherCommand() throws {
        for disabled in [CommandWrapper.IDC_CLOSE_TAB, .IDC_CLOSE_WINDOW] {
            let menu = try buildMenu([disabled: .disabled])
            let tab = try closeItem("phi.closeTab", in: menu)
            let window = try closeItem("phi.closeWindow", in: menu)
            for hasTabs in [true, false, true] {
                try updateRoles(hasBrowserTabs: hasTabs)
                assertRole(tab, command: .IDC_CLOSE_TAB, action: "commandDispatch:", hidden: !hasTabs)
                assertRole(window, command: .IDC_CLOSE_WINDOW, action: "performClose:")
                XCTAssertEqual(tab.keyEquivalent, disabled == .IDC_CLOSE_TAB ? "" : "w")
                XCTAssertEqual(window.keyEquivalent, disabled == .IDC_CLOSE_WINDOW ? "" : "W")
            }
        }
    }

    func testDefaultCloseKeysRetainNativeWindowBehaviorAndRestoreTabRole() throws {
        let menu = try buildMenu([:])
        let tab = try closeItem("phi.closeTab", in: menu)
        let window = try closeItem("phi.closeWindow", in: menu)
        for hasTabs in [true, false, true, false] {
            try updateRoles(hasBrowserTabs: hasTabs)
            assertRole(tab, command: hasTabs ? .IDC_CLOSE_TAB : .IDC_CLOSE_WINDOW,
                       action: hasTabs ? "commandDispatch:" : "performClose:")
            assertRole(window, command: .IDC_CLOSE_WINDOW, action: "performClose:", hidden: !hasTabs)
            XCTAssertEqual(tab.keyEquivalent, "w")
            XCTAssertEqual(window.keyEquivalent, "W")
        }
    }

    func testUnrelatedOwnerOfCommandWIsNotRewritten() throws {
        let menu = try buildMenu([
            .IDC_CLOSE_TAB: .custom(.init(characters: "x", modifiers: [.command, .control])),
            .IDC_RELOAD: .custom(.init(characters: "w", modifiers: .command))
        ])
        func findReload(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.tag == CommandWrapper.IDC_RELOAD.rawValue { return item }
                if let submenu = item.submenu, let found = findReload(submenu) { return found }
            }
            return nil
        }
        let reload = try XCTUnwrap(findReload(menu))
        for hasTabs in [true, false, true] {
            try updateRoles(hasBrowserTabs: hasTabs)
            XCTAssertEqual(reload.tag, CommandWrapper.IDC_RELOAD.rawValue)
            XCTAssertEqual(reload.action, NSSelectorFromString("commandDispatch:"))
            XCTAssertEqual(reload.keyEquivalent, "w")
        }
    }

    func testDefaultNonBrowserCloseAliasDoesNotConflictWithBrowserCloseTab() throws {
        let menu = try buildMenu([:])
        let commandW = ShortcutsKey(characters: "w", modifiers: .command)
        for hasTabs in [true, false, true, false] {
            try updateRoles(hasBrowserTabs: hasTabs)
            let inventory = Shortcuts.bindingInventory(additionalBindings: Shortcuts.menuBindings(in: menu))
            let closeTabConflicts = inventory.conflicts(for: CommandWrapper.IDC_CLOSE_TAB.rawValue,
                key: commandW, in: CommandWrapper.IDC_CLOSE_TAB.shortcutScope)
            XCTAssertFalse(closeTabConflicts.contains { $0.commandID == CommandWrapper.IDC_CLOSE_WINDOW.rawValue },
                           "The default non-browser Cmd-W role must not overlap browser Close Tab")
            let model = ShortcutsViewModel(additionalBindings: { Shortcuts.menuBindings(in: menu) })
            for (command, other) in [(CommandWrapper.IDC_CLOSE_TAB, CommandWrapper.IDC_CLOSE_WINDOW),
                                     (.IDC_CLOSE_WINDOW, .IDC_CLOSE_TAB)] {
                let item = try XCTUnwrap(model.sections.flatMap(\.items).first { $0.command == command })
                XCTAssertFalse(item.conflictingCommandNames.contains(other.displayName))
            }
            if !hasTabs {
                let owner = try XCTUnwrap(inventory.bindings.first {
                    $0.source == .menu && $0.commandID == CommandWrapper.IDC_CLOSE_WINDOW.rawValue
                        && $0.key.menuKeyEquivalent == commandW.menuKeyEquivalent
                })
                XCTAssertFalse(owner.scope.contains(.browser))
                XCTAssertFalse(owner.scope.contains(.kiosk))
                XCTAssertFalse(owner.scope.isEmpty, "Retain the real active owner for chord search and app-wide conflicts")
                XCTAssertTrue(inventory.occupants(of: commandW).contains(owner))
                XCTAssertTrue(inventory.conflicts(for: CommandWrapper.IDC_OPTIONS.rawValue,
                    key: commandW, in: CommandWrapper.IDC_OPTIONS.shortcutScope).contains(owner))
            }
        }
    }

    func testPairedMainMenuSnapshotKeepsDefaultCloseCommandsSeparate() throws {
        let menu = try buildMenu([:])
        let bindings = Shortcuts.menuBindings(in: menu)
        let closeBindings = bindings.filter {
            $0.commandID == CommandWrapper.IDC_CLOSE_TAB.rawValue
                || $0.commandID == CommandWrapper.IDC_CLOSE_WINDOW.rawValue
        }
        XCTAssertFalse(closeBindings.isEmpty)
        let model = ShortcutsViewModel(additionalBindings: { bindings })
        for (command, other) in [(CommandWrapper.IDC_CLOSE_TAB, CommandWrapper.IDC_CLOSE_WINDOW),
                                 (.IDC_CLOSE_WINDOW, .IDC_CLOSE_TAB)] {
            XCTAssertFalse(model.conflicts(for: command).contains { $0.id == .command(other.rawValue) },
                           "Paired Framework close bindings: \(closeBindings)")
        }
    }

    func testExplicitCloseCommandConflictRemainsVisibleInBothDirections() throws {
        let commandW = ShortcutsKey(characters: "w", modifiers: .command)
        let menu = try buildMenu([.IDC_CLOSE_WINDOW: .custom(commandW)])
        for hasTabs in [true, false, true] {
            try updateRoles(hasBrowserTabs: hasTabs)
            let inventory = Shortcuts.bindingInventory(additionalBindings: Shortcuts.menuBindings(in: menu))
            for (command, other) in [(CommandWrapper.IDC_CLOSE_TAB, CommandWrapper.IDC_CLOSE_WINDOW),
                                     (.IDC_CLOSE_WINDOW, .IDC_CLOSE_TAB)] {
                XCTAssertTrue(inventory.conflicts(for: command.rawValue, key: commandW,
                    in: command.shortcutScope).contains { $0.commandID == other.rawValue })
            }
        }
    }
}
