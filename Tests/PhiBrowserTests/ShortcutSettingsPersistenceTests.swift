// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

private final class ReleasedShortcutActionTarget: NSObject {
    var invocationCount = 0
    @objc func invoke(_ sender: Any?) { invocationCount += 1 }
}

final class ShortcutSettingsPersistenceTests: XCTestCase {
    private var previousConfiguration: ShortcutConfiguration?
    private var contents = Data("[]".utf8)
    private var backups: [Data] = []
    private var rejectsWrites = false
    private var writeCount = 0
    private let customKey = ShortcutsKey(characters: "j", modifiers: [.command, .control])

    override func setUpWithError() throws {
        previousConfiguration = Shortcuts.configuration
        let url = try XCTUnwrap(previousConfiguration?.fileURL)
        contents = Data("[]".utf8)
        backups = []
        rejectsWrites = false
        writeCount = 0
        Shortcuts.configuration = ShortcutConfiguration(
            fileURL: url,
            files: .init(
                read: { [unowned self] _ in self.contents },
                write: { [unowned self] data, _ in
                    if self.rejectsWrites { throw CocoaError(.fileWriteNoPermission) }
                    self.contents = data
                    self.writeCount += 1
                },
                backup: { [unowned self] _, _ in self.backups.append(self.contents) }
            )
        )
        CommandDispatcher.reloadPhiShortcutMap()
    }

    override func tearDownWithError() throws {
        Shortcuts.configuration = try XCTUnwrap(previousConfiguration)
        CommandDispatcher.reloadPhiShortcutMap()
        ChromiumLauncher.sharedInstance().bridge?.requestRebuildMainMenu()
        previousConfiguration = nil
    }

    private func item(_ command: CommandWrapper, in model: ShortcutsViewModel) throws -> ShortcutItem {
        try XCTUnwrap(model.sections.flatMap(\.items).first { $0.command == command })
    }

    func testSaveFailureKeepsUIAndBridgeAtPreviousBindingThenRetrySucceeds() throws {
        let model = ShortcutsViewModel()
        let command = CommandWrapper.PHI_COPY_URL
        let previousKey = Shortcuts.key(for: command)
        rejectsWrites = true
        model.setCustomShortcut(for: command, key: customKey)

        XCTAssertEqual(model.persistenceFailure, .save)
        XCTAssertEqual(try item(command, in: model).shortcutKey, previousKey)
        XCTAssertNil(Shortcuts.overrideState(for: command.rawValue))
        XCTAssertNil(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(contents, Data("[]".utf8))

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: customKey.modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38
        ))
        XCTAssertNil(CommandDispatcher.interceptedPhiCommand(
            for: event, inputSourceIdentifier: "com.apple.keylayout.US"
        ))

        rejectsWrites = false
        model.setCustomShortcut(for: command, key: customKey)
        XCTAssertNil(model.persistenceFailure)
        XCTAssertEqual(try item(command, in: model).shortcutKey, customKey)
        XCTAssertEqual(Shortcuts.overrideState(for: command.rawValue), .custom(customKey))
        XCTAssertEqual(writeCount, 1)
        let bridge = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
        XCTAssertEqual(bridge["keyEquivalent"] as? String, "j")
        XCTAssertEqual(bridge["modifierFlags"] as? UInt, customKey.menuKeyEquivalent.modifiers.rawValue)
        XCTAssertEqual(CommandDispatcher.interceptedPhiCommand(
            for: event, inputSourceIdentifier: "com.apple.keylayout.US"
        ), command)
    }

    func testDisableAndRestoreExposeDistinctBridgeStates() throws {
        let model = ShortcutsViewModel()
        let command = CommandWrapper.IDC_RELOAD
        model.disableShortcut(for: command)
        XCTAssertNil(try item(command, in: model).shortcutKey)
        let bridge = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
        XCTAssertEqual(bridge["keyEquivalent"] as? String, "")
        XCTAssertEqual(Shortcuts.overrideState(for: command.rawValue), .disabled)

        model.restoreDefaultShortcut(for: command)
        XCTAssertNil(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
        XCTAssertEqual(try item(command, in: model).shortcutKey, Shortcuts.DefaultShortcuts[command])
        XCTAssertEqual(contents, Data("[]".utf8))
    }

    func testCorruptConfigurationBlocksChangesUntilRecoveryPreservesOriginal() throws {
        let damaged = Data("damaged configuration".utf8)
        contents = damaged
        _ = Shortcuts.reloadOverrides()
        let model = ShortcutsViewModel()
        XCTAssertEqual(model.persistenceFailure, .load)
        XCTAssertFalse(model.canEdit)
        model.setCustomShortcut(for: .PHI_COPY_URL, key: customKey)
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(contents, damaged)

        model.restoreAllShortcuts()
        XCTAssertEqual(backups, [damaged])
        XCTAssertEqual(contents, Data("[]".utf8))
        XCTAssertNil(model.persistenceFailure)
        XCTAssertTrue(model.canEdit)
    }

    func testRetryLoadingRepairedConfigurationReenablesEditing() throws {
        contents = Data("broken".utf8)
        _ = Shortcuts.reloadOverrides()
        let model = ShortcutsViewModel()
        contents = Data("[]".utf8)
        model.retryLoadingShortcuts()
        XCTAssertNil(model.persistenceFailure)
        XCTAssertTrue(model.canEdit)
        XCTAssertEqual(writeCount, 0)
    }

    func testFailedResetKeepsExistingBindingAndReportsFailure() throws {
        let model = ShortcutsViewModel()
        model.setCustomShortcut(for: .PHI_COPY_URL, key: customKey)
        let saved = contents
        rejectsWrites = true
        model.restoreAllShortcuts()
        XCTAssertEqual(model.persistenceFailure, .save)
        XCTAssertEqual(try item(.PHI_COPY_URL, in: model).shortcutKey, customKey)
        XCTAssertEqual(contents, saved)
    }

    func testDisablingCommandWithNoDefaultStillPersistsExplicitDisable() throws {
        let command = CommandWrapper.IDC_DUPLICATE_TAB
        XCTAssertNil(Shortcuts.DefaultShortcuts[command])
        let model = ShortcutsViewModel()
        model.disableShortcut(for: command)
        _ = Shortcuts.reloadOverrides()
        XCTAssertEqual(Shortcuts.overrideState(for: command.rawValue), .disabled)
        XCTAssertTrue(try item(command, in: model).isOverridden)
    }

    func testRecordingDefaultRemovesCustomOverride() throws {
        let model = ShortcutsViewModel()
        let command = CommandWrapper.PHI_COPY_URL
        model.setCustomShortcut(for: command, key: customKey)
        model.setCustomShortcut(for: command, key: try XCTUnwrap(Shortcuts.DefaultShortcuts[command]))
        XCTAssertNil(Shortcuts.overrideState(for: command.rawValue))
        XCTAssertFalse(try item(command, in: model).isOverridden)
        XCTAssertEqual(contents, Data("[]".utf8))
    }

    func testReassignmentRequiresConfirmationAndCommitsAllOwnersTogether() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        let reload = try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_RELOAD])
        model.requestCustomShortcut(for: .IDC_DUPLICATE_TAB, key: reload)
        XCTAssertTrue(try XCTUnwrap(model.reassignment).canReassign)
        XCTAssertEqual(writeCount, 0)
        XCTAssertNil(Shortcuts.overrideState(for: CommandWrapper.IDC_DUPLICATE_TAB.rawValue))
        model.confirmReassignment(model.reassignment)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(Shortcuts.overrideState(for: CommandWrapper.IDC_RELOAD.rawValue), .disabled)
        XCTAssertEqual(Shortcuts.overrideState(for: CommandWrapper.IDC_DUPLICATE_TAB.rawValue), .custom(reload))
    }

    func testReassignmentConfirmationUsesPresentedSnapshotAfterAlertDismissal() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        let reload = try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_RELOAD])
        model.requestCustomShortcut(for: .IDC_DUPLICATE_TAB, key: reload)
        let presented = try XCTUnwrap(model.reassignment)
        model.reassignment = nil
        model.confirmReassignment(presented)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(Shortcuts.overrideState(for: CommandWrapper.IDC_RELOAD.rawValue), .disabled)
        XCTAssertEqual(Shortcuts.overrideState(for: CommandWrapper.IDC_DUPLICATE_TAB.rawValue), .custom(reload))
    }

    func testFailedReassignmentRetainsEveryBindingAndCanBeRetried() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        let reload = try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_RELOAD])
        model.requestCustomShortcut(for: .IDC_DUPLICATE_TAB, key: reload)
        rejectsWrites = true
        model.confirmReassignment(model.reassignment)
        XCTAssertEqual(model.persistenceFailure, .save)
        XCTAssertTrue(Shortcuts.configuration.overrides.isEmpty)
        XCTAssertEqual(contents, Data("[]".utf8))
        rejectsWrites = false
        model.requestCustomShortcut(for: .IDC_DUPLICATE_TAB, key: reload)
        model.confirmReassignment(model.reassignment)
        XCTAssertEqual(writeCount, 1)
    }

    func testCancelingReassignmentDoesNotWrite() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.requestCustomShortcut(for: .IDC_DUPLICATE_TAB,
                                    key: try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_RELOAD]))
        XCTAssertNotNil(model.reassignment)
        model.reassignment = nil
        model.confirmReassignment(model.reassignment)
        XCTAssertEqual(writeCount, 0)
        XCTAssertTrue(Shortcuts.configuration.overrides.isEmpty)
    }

    func testNativeActionConflictIsReadOnlyAndCannotBeReassigned() throws {
        let model = ShortcutsViewModel(additionalBindings: { [self.customNativeBinding()] })
        model.requestCustomShortcut(for: .IDC_DUPLICATE_TAB, key: customKey)
        let pending = try XCTUnwrap(model.reassignment)
        XCTAssertFalse(pending.canReassign)
        XCTAssertTrue(pending.names.contains("Copy"))
        model.confirmReassignment(model.reassignment)
        XCTAssertEqual(writeCount, 0)
        XCTAssertFalse(model.reservedShortcuts.contains { $0.id == .nativeAction("copy:") })
        XCTAssertFalse(model.inventory.occupants(of: customKey).isEmpty)
    }

    private func customNativeBinding() -> ShortcutBinding {
        ShortcutBinding(owner: .nativeAction("copy:"), key: customKey,
                        scope: .all, source: .menu, title: "Copy")
    }

    func testStaleReassignmentCannotOverwriteExternallyReloadedConfiguration() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.requestCustomShortcut(for: .IDC_DUPLICATE_TAB,
                                    key: try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_RELOAD]))
        let presented = try XCTUnwrap(model.reassignment)
        contents = Data("[{\"commandId\":\(CommandWrapper.IDC_RELOAD.rawValue),\"key\":null}]".utf8)
        let external = contents
        _ = Shortcuts.reloadOverrides()
        model.reassignment = nil
        model.confirmReassignment(presented)
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(contents, external)
        XCTAssertNil(Shortcuts.overrideState(for: CommandWrapper.IDC_DUPLICATE_TAB.rawValue))
    }

    func testSearchCaptureDoesNotWriteOrExecuteAReassignment() throws {
        let model = ShortcutsViewModel(additionalBindings: { [self.customNativeBinding()] })
        model.capture = .search
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: customKey.modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        model.handleCaptureEvent(event)
        XCTAssertEqual(model.searchedKey, customKey)
        XCTAssertNil(model.capture)
        XCTAssertTrue(model.matchesSearch(.nativeAction("copy:")))
        XCTAssertFalse(model.matchesSearch(.command(CommandWrapper.IDC_RELOAD.rawValue)))
        XCTAssertNil(model.reassignment)
        XCTAssertEqual(writeCount, 0)
    }

    func testPairedFrameworkExportsAliasesAndHonorsRebindDisableRestore() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        XCTAssertTrue(bridge.responds(to: NSSelectorFromString("shortcutBindings")))
        let command = CommandWrapper.IDC_SELECT_NEXT_TAB
        let pageDown = ShortcutsKey(characters: "\u{F72D}", modifiers: .control)
        bridge.requestRebuildMainMenu()
        func aliases() -> [ShortcutBinding] {
            Shortcuts.additionalBindings().filter { $0.commandID == command.rawValue && $0.source == .hidden }
        }
        XCTAssertTrue(aliases().contains { $0.key.menuKeyEquivalent == pageDown.menuKeyEquivalent })
        let model = ShortcutsViewModel()
        model.setCustomShortcut(for: command, key: customKey)
        XCTAssertFalse(aliases().isEmpty)
        XCTAssertTrue(aliases().allSatisfy { $0.key.menuKeyEquivalent == customKey.menuKeyEquivalent })
        model.disableShortcut(for: command)
        XCTAssertTrue(aliases().isEmpty)
        model.restoreDefaultShortcut(for: command)
        XCTAssertTrue(aliases().contains { $0.key.menuKeyEquivalent == pageDown.menuKeyEquivalent })
    }

    private var productOwnedCommands: [CommandWrapper] {
        [.PHI_NEW_KIOSK_WINDOW, .PHI_COPY_URL, .PHI_SELECT_NEXT_SPACE,
         .PHI_SELECT_PREVIOUS_SPACE, .PHI_TOGGLE_READER, .PHI_TOGGLE_SIDEBAR]
    }

    func testProductDefaultsHaveOneOwnerAndKeepOtherChromiumAliases() throws {
        try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge).requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        for command in productOwnedCommands {
            let key = try XCTUnwrap(Shortcuts.DefaultShortcuts[command])
            XCTAssertEqual(Set(model.inventory.occupants(of: key).map(\.owner)),
                           [.command(command.rawValue)], "Product default: \(command)")
            XCTAssertFalse(try item(command, in: model).hasConflict)
        }
        for (command, key) in [
            (CommandWrapper.IDC_DEV_TOOLS_INSPECT, ShortcutsKey(characters: "c", modifiers: [.command, .option])),
            (.IDC_SELECT_NEXT_TAB, ShortcutsKey(characters: "\u{F72D}", modifiers: .control)),
            (.IDC_SELECT_PREVIOUS_TAB, ShortcutsKey(characters: "\u{F72C}", modifiers: .control)),
            (.IDC_SELECT_NEXT_TAB, try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_SELECT_NEXT_TAB])),
            (.IDC_SELECT_PREVIOUS_TAB, try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_SELECT_PREVIOUS_TAB]))
        ] {
            XCTAssertTrue(model.inventory.bindings(for: command.rawValue).contains {
                $0.key.menuKeyEquivalent == key.menuKeyEquivalent
            }, "Unrelated alias must remain: \(command)")
        }
        XCTAssertFalse(model.reservedShortcuts.contains { $0.id == .command(CommandWrapper.IDC_NEW_SPLIT_TAB.rawValue) })
        XCTAssertFalse(model.reservedShortcuts.contains { $0.id == .command(CommandWrapper.IDC_SHOW_READING_MODE_KEYBOARD.rawValue) })

        func find(_ command: CommandWrapper, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.tag == command.rawValue, item.action != nil { return item }
                if let submenu = item.submenu, let found = find(command, in: submenu) { return found }
            }
            return nil
        }
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let split = try XCTUnwrap(find(.IDC_NEW_SPLIT_TAB, in: menu))
        XCTAssertEqual(split.keyEquivalent, "", "Remove the default binding, not the menu command")
        XCTAssertEqual(split.action, NSSelectorFromString("commandDispatch:"))
    }

    func testProductDefaultsDoNotReviveAfterRebindDisableOrRestore() throws {
        try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge).requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        for command in productOwnedCommands {
            let key = try XCTUnwrap(Shortcuts.DefaultShortcuts[command])
            model.setCustomShortcut(for: command, key: customKey)
            XCTAssertTrue(model.inventory.occupants(of: key).isEmpty, "Rebound: \(command)")
            model.disableShortcut(for: command)
            XCTAssertTrue(model.inventory.occupants(of: key).isEmpty, "Disabled: \(command)")
            model.restoreDefaultShortcut(for: command)
            XCTAssertEqual(Set(model.inventory.occupants(of: key).map(\.owner)),
                           [.command(command.rawValue)], "Restored: \(command)")
        }
        XCTAssertTrue(Shortcuts.configuration.overrides.isEmpty,
                      "Product defaults must not be persisted as user disables")
    }

    func testExplicitUserConflictWithProductKeyStillRequiresReassignment() throws {
        try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge).requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        let copyKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.PHI_COPY_URL])
        model.requestCustomShortcut(for: .IDC_DEV_TOOLS_INSPECT, key: copyKey)
        let pending = try XCTUnwrap(model.reassignment)
        XCTAssertEqual(pending.owners, [.command(CommandWrapper.PHI_COPY_URL.rawValue)])
        XCTAssertTrue(pending.canReassign)
        model.confirmReassignment(pending)
        XCTAssertNil(Shortcuts.key(for: .PHI_COPY_URL))
        XCTAssertEqual(Set(model.inventory.occupants(of: copyKey).map(\.owner)),
                       [.command(CommandWrapper.IDC_DEV_TOOLS_INSPECT.rawValue)])
        XCTAssertTrue(model.inventory.bindings(for: CommandWrapper.IDC_DEV_TOOLS_INSPECT.rawValue).contains {
            $0.source == .hidden && $0.key.menuKeyEquivalent == copyKey.menuKeyEquivalent
        }, "Explicit user overrides must still reach the Framework")
        model.restoreAllShortcuts()
        XCTAssertEqual(Set(model.inventory.occupants(of: copyKey).map(\.owner)),
                       [.command(CommandWrapper.PHI_COPY_URL.rawValue)])
    }

    func testPhiSwitcherChangesNeverReviveChromiumCycleKeys() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        bridge.requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        let oldKey = ShortcutsKey(characters: "\t", modifiers: .control)
        for disabled in [false, true] {
            if disabled { model.disableShortcut(for: .PHI_TAB_SWITCHER_FORWARD) }
            else { model.setCustomShortcut(for: .PHI_TAB_SWITCHER_FORWARD, key: customKey) }
            XCTAssertTrue(model.inventory.occupants(of: oldKey).isEmpty)
            for command in [CommandWrapper.IDC_CYCLE_TO_NEXT_TAB, .IDC_CYCLE_TO_PREV_TAB] {
                let state = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
                XCTAssertEqual(state["keyEquivalent"] as? String, "")
                XCTAssertFalse(Shortcuts.menuBindings().contains { $0.commandID == command.rawValue })
            }
        }
        model.restoreDefaultShortcut(for: .PHI_TAB_SWITCHER_FORWARD)
        XCTAssertEqual(Set(model.inventory.occupants(of: oldKey).map(\.owner)), [.command(CommandWrapper.PHI_TAB_SWITCHER_FORWARD.rawValue)])
    }

    func testLiveHiddenOwnersHaveNamesAndBrowserBindingsCanBeReassigned() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        XCTAssertTrue(bridge.responds(to: NSSelectorFromString("shortcutBindings")))
        bridge.requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        let hidden = model.inventory.bindings.filter { $0.source == .hidden }
        XCTAssertFalse(hidden.isEmpty)
        for binding in hidden {
            let command = try XCTUnwrap(binding.commandID.flatMap(CommandWrapper.init(rawValue:)))
            let name = model.sections.flatMap(\.items).first { $0.command == command }?.name
                ?? model.reservedShortcuts.first { $0.id == binding.owner }?.name
            XCTAssertFalse(try XCTUnwrap(name).isEmpty)
            XCTAssertNotEqual(name, "Reserved browser shortcut")
        }
        let reserved = try XCTUnwrap(hidden.first { $0.commandID == CommandWrapper.IDC_MOVE_TAB_NEXT.rawValue })
        let row = try item(.IDC_MOVE_TAB_NEXT, in: model)
        XCTAssertEqual(row.name, "Move Tab Right")
        XCTAssertEqual(row.shortcutKey, reserved.key)
        model.requestCustomShortcut(for: .IDC_DUPLICATE_TAB, key: reserved.key)
        XCTAssertTrue(try XCTUnwrap(model.reassignment).canReassign)
        model.confirmReassignment(model.reassignment)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(Shortcuts.overrideState(for: CommandWrapper.IDC_MOVE_TAB_NEXT.rawValue), .disabled)
        XCTAssertNil(try item(.IDC_MOVE_TAB_NEXT, in: model).shortcutKey)
    }

    func testBrowserCommandsCanBeCustomizedDisabledAndRestoredInLiveTables() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        bridge.requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        for command in [CommandWrapper.IDC_RELOAD_BYPASSING_CACHE, .IDC_MOVE_TAB_PREVIOUS,
                        .IDC_ADD_NEW_TAB_TO_GROUP] {
            let original = try XCTUnwrap(try item(command, in: model).shortcutKey)
            model.setCustomShortcut(for: command, key: customKey)
            XCTAssertEqual(try item(command, in: model).shortcutKey, customKey)
            let customized = model.inventory.bindings(for: command.rawValue)
                .filter { $0.source != .configured }
            XCTAssertFalse(customized.isEmpty)
            XCTAssertTrue(customized.allSatisfy { $0.key.menuKeyEquivalent == customKey.menuKeyEquivalent })
            XCTAssertFalse(customized.contains { $0.key.menuKeyEquivalent == original.menuKeyEquivalent })

            model.disableShortcut(for: command)
            XCTAssertNil(try item(command, in: model).shortcutKey)
            XCTAssertTrue(model.inventory.bindings(for: command.rawValue).isEmpty)

            model.restoreDefaultShortcut(for: command)
            XCTAssertEqual(try item(command, in: model).shortcutKey?.menuKeyEquivalent, original.menuKeyEquivalent)
            XCTAssertTrue(model.inventory.bindings(for: command.rawValue).contains {
                $0.source != .configured && $0.key.menuKeyEquivalent == original.menuKeyEquivalent
            })
        }
    }

    private var productDisabledKeys: [(CommandWrapper, ShortcutsKey, UInt16)] {
        [(.IDC_FOCUS_NEXT_PANE, .init(characters: "\u{F701}", modifiers: [.command, .option]), 125),
         (.IDC_FOCUS_PREVIOUS_PANE, .init(characters: "\u{F700}", modifiers: [.command, .option]), 126),
         (.IDC_FOCUS_INACTIVE_POPUP_FOR_ACCESSIBILITY, .init(characters: "a", modifiers: [.command, .option, .shift]), 0),
         (.IDC_SHOW_AVATAR_MENU, .init(characters: "m", modifiers: [.command, .shift]), 46),
         (.IDC_TOGGLE_FULLSCREEN_TOOLBAR, .init(characters: "f", modifiers: [.command, .shift]), 3),
         (.IDC_HELP_PAGE_VIA_MENU, .init(characters: "?", modifiers: [.command, .shift]), 44)]
    }

    func testProductDisabledCommandsStayUnboundAfterReloadRestoreAndMenuRebuild() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        func assertReleased() throws {
            bridge.requestRebuildMainMenu()
            let actual = Shortcuts.additionalBindings()
            let hidden = bridge.shortcutBindings()
            let model = ShortcutsViewModel()
            for (command, _, _) in productDisabledKeys {
                XCTAssertFalse(actual.contains { $0.commandID == command.rawValue })
                XCTAssertFalse(hidden.contains { ($0["commandId"] as? Int) == command.rawValue })
                XCTAssertNil(Shortcuts.key(for: command))
                XCTAssertFalse(model.sections.flatMap(\.items).contains { $0.command == command })
                let override = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
                XCTAssertEqual(override["keyEquivalent"] as? String, "")
            }
        }
        try assertReleased()
        // Simulate an existing configuration loaded on startup. The records
        // remain stored, but product policy wins over every saved custom key.
        contents = try JSONSerialization.data(withJSONObject: productDisabledKeys.map { command, _, _ in
            ["commandId": command.rawValue,
             "key": ["characters": customKey.characters, "modifiersRaw": customKey.modifiersRaw]] as [String: Any]
        })
        let saved = contents
        try Shortcuts.reloadOverrides().get()
        XCTAssertEqual(Shortcuts.configuration.overrides.count, productDisabledKeys.count)
        XCTAssertEqual(contents, saved)
        try assertReleased()
        try Shortcuts.restoreOverrides().get()
        try assertReleased()
    }

    func testReleasedCombinationsCanBeAssignedToAndInvokeAnotherMenuCommand() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        bridge.requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        func findReload(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.tag == CommandWrapper.IDC_RELOAD.rawValue, item.action != nil { return item }
                if let submenu = item.submenu, let found = findReload(in: submenu) { return found }
            }
            return nil
        }
        for (_, key, keyCode) in productDisabledKeys {
            model.requestCustomShortcut(for: .IDC_RELOAD, key: key)
            XCTAssertNil(model.reassignment)
            XCTAssertEqual(Shortcuts.key(for: .IDC_RELOAD), key)
            XCTAssertEqual(Set(model.inventory.occupants(of: key).map(\.owner)),
                           [.command(CommandWrapper.IDC_RELOAD.rawValue)])
            let menu = try XCTUnwrap(NSApp.mainMenu)
            let item = try XCTUnwrap(findReload(in: menu))
            let target = ReleasedShortcutActionTarget()
            let originalTarget = item.target
            let originalAction = item.action
            let originalEnabled = item.isEnabled
            defer {
                item.target = originalTarget
                item.action = originalAction
                item.isEnabled = originalEnabled
            }
            // Exercise AppKit key matching without reloading a user's page.
            item.target = target
            item.action = #selector(ReleasedShortcutActionTarget.invoke(_:))
            item.isEnabled = true
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: key.modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: key.menuKeyEquivalent.characters,
                charactersIgnoringModifiers: key.menuKeyEquivalent.characters,
                isARepeat: false, keyCode: keyCode))
            XCTAssertTrue(menu.performKeyEquivalent(with: event))
            XCTAssertEqual(target.invocationCount, 1)
        }
    }

    func testOpenSettingsRefreshesAfterExternalReloadAndCancelsStaleRecording() throws {
        let model = ShortcutsViewModel()
        let command = CommandWrapper.PHI_COPY_URL
        // Drain the initial spaces subscription so it cannot mask a missing
        // shortcuts notification subscription by rebuilding at the same time.
        let ready = expectation(description: "Initial settings subscriptions settle")
        DispatchQueue.main.async { ready.fulfill() }
        wait(for: [ready], timeout: 2)
        let refreshed = expectation(description: "Open settings observes a reloaded binding")
        let subscription = model.$sections.dropFirst()
            .filter { sections in
                sections.flatMap(\.items).first(where: { $0.command == command })?.shortcutKey == nil
            }
            .prefix(1)
            .sink { _ in refreshed.fulfill() }
        model.editingCommand = command
        contents = Data("[{\"commandId\":\(command.rawValue),\"key\":null}]".utf8)
        _ = Shortcuts.reloadOverrides()
        wait(for: [refreshed], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertNil(model.editingCommand)
        XCTAssertNil(try item(command, in: model).shortcutKey)
    }
}
