// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

final class ShortcutInventoryIntegrationTests: XCTestCase {
    func testMenuEncodedShiftIsVisibleWithoutChangingBindingIdentity() {
        let menuKey = ShortcutsKey(characters: "C", modifiers: .command)
        XCTAssertEqual(menuKey.displayString, "⇧⌘C")
        XCTAssertEqual(menuKey.keycapTokens, ["⇧", "⌘", "C"])
        XCTAssertEqual(menuKey.modifiers, .command)
        XCTAssertEqual(ShortcutsKey(characters: "c", modifiers: .command).displayString, "⌘C")
        XCTAssertEqual(ShortcutsKey(characters: "C", modifiers: [.command, .shift]).keycapTokens,
                       ["⇧", "⌘", "C"])
    }

    func testHiddenNavigationAndSystemKeyLabelsRemainReadable() {
        for (characters, label) in [("\u{F72C}", "⇞"), ("\u{F72D}", "⇟"),
                                    ("\u{F729}", "↖"), ("\u{F72B}", "↘"),
                                    ("\u{F728}", "⌦"), ("\u{F70F}", "F12"), (" ", "␣")] {
            XCTAssertEqual(ShortcutsKey(characters: characters, modifiers: .control).displayString, "⌃" + label)
        }
        XCTAssertEqual(ShortcutsKey(characters: "e", modifiers: .function).keycapTokens, ["fn", "E"])
    }

    private var previousConfiguration: ShortcutConfiguration?

    override func setUp() {
        previousConfiguration = Shortcuts.configuration
        install([:])
    }

    override func tearDownWithError() throws {
        Shortcuts.configuration = try XCTUnwrap(previousConfiguration)
        previousConfiguration = nil
    }

    private func install(_ overrides: [CommandWrapper: ShortcutOverride]) {
        Shortcuts.configuration = ShortcutConfiguration(
            overrides: Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }),
            fileURL: previousConfiguration?.fileURL,
            files: .init(
                read: { _ in throw CocoaError(.fileReadNoPermission) },
                write: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                backup: { _, _ in throw CocoaError(.fileWriteNoPermission) }
            )
        )
    }

    private func item(_ command: CommandWrapper, in model: ShortcutsViewModel) throws -> ShortcutItem {
        try XCTUnwrap(model.sections.flatMap(\.items).first { $0.command == command })
    }

    func testTwoCustomOnlyCommandsReportEachOther() throws {
        let key = ShortcutsKey(characters: "d", modifiers: [.control, .option])
        install([.IDC_DUPLICATE_TAB: .custom(key), .IDC_WINDOW_MUTE_SITE: .custom(key)])
        let model = ShortcutsViewModel(additionalBindings: { [] })
        let duplicate = try item(.IDC_DUPLICATE_TAB, in: model)
        let mute = try item(.IDC_WINDOW_MUTE_SITE, in: model)
        XCTAssertTrue(duplicate.conflictingCommandNames.contains(mute.name))
        XCTAssertTrue(mute.conflictingCommandNames.contains(duplicate.name))
    }

    func testDefaultAndCustomOnlyConflictIsSymmetric() throws {
        install([.IDC_DUPLICATE_TAB: .custom(try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_RELOAD]))])
        let model = ShortcutsViewModel(additionalBindings: { [] })
        let duplicate = try item(.IDC_DUPLICATE_TAB, in: model)
        let reload = try item(.IDC_RELOAD, in: model)
        XCTAssertTrue(duplicate.conflictingCommandNames.contains(reload.name))
        XCTAssertTrue(reload.conflictingCommandNames.contains(duplicate.name))
    }

    func testHiddenAliasConflictsInBothDirectionsDespiteDifferentPrimaryKey() throws {
        let pageDown = ShortcutsKey(characters: "\u{F72D}", modifiers: .control)
        install([.IDC_OPTIONS: .custom(pageDown)])
        let model = ShortcutsViewModel(additionalBindings: {
            [ShortcutBinding(commandID: CommandWrapper.IDC_SELECT_NEXT_TAB.rawValue,
                             key: pageDown, scope: .browser, source: .hidden)]
        })
        let settings = try item(.IDC_OPTIONS, in: model)
        let next = try item(.IDC_SELECT_NEXT_TAB, in: model)
        XCTAssertTrue(settings.conflictingCommandNames.contains(next.name))
        XCTAssertTrue(next.conflictingCommandNames.contains(settings.name))
        XCTAssertNotEqual(next.shortcutKey, pageDown)
        XCTAssertEqual(Set(model.inventory.occupants(of: pageDown).map(\.commandID)),
                       [CommandWrapper.IDC_OPTIONS.rawValue, CommandWrapper.IDC_SELECT_NEXT_TAB.rawValue])
    }

    func testDisabledCustomOnlyOwnerIsRemovedFromConflicts() throws {
        let key = ShortcutsKey(characters: "d", modifiers: [.control, .option])
        install([.IDC_DUPLICATE_TAB: .custom(key), .IDC_WINDOW_MUTE_SITE: .disabled])
        let model = ShortcutsViewModel(additionalBindings: { [] })
        XCTAssertFalse(try item(.IDC_DUPLICATE_TAB, in: model).hasConflict)
        XCTAssertTrue(model.inventory.bindings(for: CommandWrapper.IDC_WINDOW_MUTE_SITE.rawValue).isEmpty)
    }

    func testOpenFileAndQuitAreDiscoverableAndExplainConflicts() throws {
        install([.IDC_DUPLICATE_TAB: .custom(try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_EXIT]))])
        let model = ShortcutsViewModel(additionalBindings: { [] })
        XCTAssertEqual(try item(.IDC_OPEN_FILE, in: model).shortcutKey,
                       ShortcutsKey(characters: "o", modifiers: .command))
        let quit = try item(.IDC_EXIT, in: model)
        XCTAssertEqual(quit.shortcutKey, ShortcutsKey(characters: "q", modifiers: .command))
        XCTAssertTrue(try item(.IDC_DUPLICATE_TAB, in: model).conflictingCommandNames.contains(quit.name))
    }

    func testSystemServicesAreHiddenButStillReportConflictingAssignments() throws {
        let bindings: [ShortcutBinding] = [
            .init(commandID: CommandWrapper.IDC_CONTENT_CONTEXT_SELECTALL.rawValue,
                  key: .init(characters: "a", modifiers: .command), scope: .all, source: .menu, title: "Select All"),
            .init(commandID: CommandWrapper.IDC_CONTENT_CONTEXT_UNDO.rawValue,
                  key: .init(characters: "z", modifiers: .command), scope: .all, source: .menu, title: "Undo"),
            .init(commandID: CommandWrapper.IDS_EDIT_USE_SELECTION_MAC.rawValue,
                  key: .init(characters: "e", modifiers: .command), scope: .all, source: .menu, title: "Use Selection for Find"),
            .init(owner: .nativeAction("orderFrontCharacterPalette:"),
                  key: .init(characters: " ", modifiers: [.command, .control]),
                  scope: .all, source: .menu, title: "Emoji & Symbols")
        ]
        let model = ShortcutsViewModel(additionalBindings: { bindings })
        for binding in bindings {
            XCTAssertFalse(model.reservedShortcuts.contains { $0.id == binding.owner })
            XCTAssertFalse(model.sections.flatMap(\.items).contains { $0.command.rawValue == binding.commandID })
            XCTAssertTrue(model.inventory.occupants(of: binding.key).contains(binding))
            install([.IDC_DUPLICATE_TAB: .custom(binding.key)])
            model.rebuildSections()
            let conflict = try XCTUnwrap(model.conflicts(for: .IDC_DUPLICATE_TAB).first { $0.id == binding.owner })
            XCTAssertNil(conflict.command)
            XCTAssertEqual(conflict.name, try XCTUnwrap(binding.title))
        }
        for command in [CommandWrapper.IDC_FIND, .IDC_FIND_NEXT, .IDC_FIND_PREVIOUS, .IDC_FOCUS_SEARCH] {
            XCTAssertNotNil(try item(command, in: model).shortcutKey)
        }
    }

    func testBrowserRowsUseRuntimeDefaultsAndKeepDisabledDiscoveredCommandsEditable() throws {
        let move = ShortcutsKey(characters: "\u{F72C}", modifiers: [.control, .shift])
        let focus = ShortcutsKey(characters: "c", modifiers: [.command, .control])
        let model = ShortcutsViewModel(additionalBindings: {
            [.init(commandID: CommandWrapper.IDC_MOVE_TAB_PREVIOUS.rawValue, key: move, scope: .browser, source: .hidden),
             .init(commandID: CommandWrapper.IDC_ADD_NEW_TAB_TO_GROUP.rawValue, key: focus, scope: .browser, source: .hidden)]
        })
        XCTAssertEqual(try item(.IDC_MOVE_TAB_PREVIOUS, in: model).shortcutKey, move)
        XCTAssertEqual(try item(.IDC_ADD_NEW_TAB_TO_GROUP, in: model).shortcutKey, focus)
        XCTAssertEqual(try item(.IDC_RELOAD_BYPASSING_CACHE, in: model).shortcutKey,
                       ShortcutsKey(characters: "r", modifiers: [.command, .shift]))
        install([.IDC_DUPLICATE_TAB: .custom(focus)])
        model.rebuildSections()
        XCTAssertTrue(model.conflicts(for: .IDC_DUPLICATE_TAB).contains { $0.command == .IDC_ADD_NEW_TAB_TO_GROUP })

        install([.IDC_ADD_NEW_TAB_TO_GROUP: .disabled])
        let disabled = ShortcutsViewModel(additionalBindings: { [] })
        XCTAssertNil(try item(.IDC_ADD_NEW_TAB_TO_GROUP, in: disabled).shortcutKey)
        XCTAssertTrue(disabled.inventory.bindings(for: CommandWrapper.IDC_ADD_NEW_TAB_TO_GROUP.rawValue).isEmpty)
    }

    func testProductPolicyOverridesSavedKeysAndStaleRuntimeBindings() throws {
        let releasedKey = ShortcutsKey(characters: "m", modifiers: [.command, .shift])
        let commands: [CommandWrapper] = [.IDC_FOCUS_NEXT_PANE, .IDC_FOCUS_PREVIOUS_PANE,
            .IDC_FOCUS_INACTIVE_POPUP_FOR_ACCESSIBILITY, .IDC_SHOW_AVATAR_MENU,
            .IDC_TOGGLE_FULLSCREEN_TOOLBAR, .IDC_HELP_PAGE_VIA_MENU]
        install(Dictionary(uniqueKeysWithValues: commands.map { ($0, .custom(releasedKey)) }))
        let saved = Shortcuts.configuration.overrides
        let stale = commands.flatMap { command in
            [ShortcutBinding.Source.menu, .hidden, .webContents].map {
                ShortcutBinding(commandID: command.rawValue, key: releasedKey, scope: .all, source: $0)
            }
        }
        let model = ShortcutsViewModel(additionalBindings: { stale })
        for command in commands {
            XCTAssertNil(Shortcuts.key(for: command))
            XCTAssertEqual(Shortcuts.chromiumOverrideState(for: command.rawValue), .disabled)
            let menuItem = NSMenuItem(title: "Unsupported command", action: nil, keyEquivalent: "m")
            menuItem.tag = command.rawValue
            menuItem.keyEquivalentModifierMask = [.command, .shift]
            Shortcuts.updateShortcut(for: menuItem)
            XCTAssertTrue(menuItem.keyEquivalent.isEmpty)
            XCTAssertEqual(menuItem.keyEquivalentModifierMask.rawValue, 0)
            XCTAssertFalse(Shortcuts.configurableCommands.contains(command))
            XCTAssertFalse(model.sections.flatMap(\.items).contains { $0.command == command })
            XCTAssertFalse(model.reservedShortcuts.contains { $0.id == .command(command.rawValue) })
            XCTAssertTrue(model.inventory.bindings(for: command.rawValue).isEmpty)
        }
        XCTAssertTrue(model.inventory.occupants(of: releasedKey).isEmpty)
        XCTAssertEqual(Shortcuts.configuration.overrides, saved)

        install([.IDC_RELOAD: .custom(releasedKey)])
        model.rebuildSections()
        XCTAssertEqual(Shortcuts.key(for: .IDC_RELOAD), releasedKey)
        XCTAssertEqual(Set(model.inventory.occupants(of: releasedKey).map(\.owner)),
                       [.command(CommandWrapper.IDC_RELOAD.rawValue)])
    }

    func testUnavailableServicesDoNotConflictButOtherServiceStatesStillDo() throws {
        let menu = NSMenu()
        let services = NSMenu(title: "Services")
        services.autoenablesItems = false
        let parent = NSMenuItem()
        parent.submenu = services
        menu.addItem(parent)
        // Services may be grouped into nested submenus.
        let group = NSMenuItem()
        let nested = NSMenu(title: "Text")
        nested.autoenablesItems = false
        group.submenu = nested
        services.addItem(group)
        let service = NSMenuItem(title: "Search man Page Index in Terminal",
                                 action: NSSelectorFromString("_processRequest:"), keyEquivalent: "A")
        service.keyEquivalentModifierMask = .command
        service.allowsKeyEquivalentWhenHidden = true
        nested.addItem(service)
        let model = ShortcutsViewModel(additionalBindings: {
            Shortcuts.menuBindings(in: menu, servicesMenu: services)
        })

        for hidden in [false, true] {
            for enabled in [false, true] {
                service.isHidden = hidden
                service.isEnabled = enabled
                model.rebuildSections()
                let conflicts = model.conflicts(for: .IDC_TAB_SEARCH)
                if hidden && !enabled {
                    XCTAssertTrue(conflicts.isEmpty)
                    XCTAssertFalse(try item(.IDC_TAB_SEARCH, in: model).hasConflict)
                } else {
                    XCTAssertEqual(conflicts.map(\.name), [service.title])
                    XCTAssertEqual(conflicts.first?.keys, ["⇧⌘A"])
                }
            }
        }

        // The same selector outside the Services tree must not be filtered.
        service.isHidden = true
        service.isEnabled = false
        XCTAssertEqual(Shortcuts.menuBindings(in: menu, servicesMenu: nil).count, 1)
    }

    func testMenuSnapshotIncludesHiddenKeysUsedByChromiumMatching() throws {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let parent = NSMenuItem()
        parent.submenu = NSMenu()
        parent.submenu?.autoenablesItems = false
        menu.addItem(parent)
        let item = NSMenuItem(title: "Find", action: NSSelectorFromString("performFindPanelAction:"), keyEquivalent: "f")
        item.tag = CommandWrapper.IDC_FIND.rawValue
        item.keyEquivalentModifierMask = .command
        parent.submenu?.addItem(item)
        XCTAssertEqual(Shortcuts.menuBindings(in: menu).map(\.commandID), [item.tag])
        item.isHidden = true
        XCTAssertEqual(Shortcuts.menuBindings(in: menu).count, 1)
        item.allowsKeyEquivalentWhenHidden = true
        XCTAssertEqual(Shortcuts.menuBindings(in: menu).count, 1)
        item.isEnabled = false
        XCTAssertEqual(Shortcuts.menuBindings(in: menu).count, 1)
        install([.IDC_OPTIONS: .custom(.init(characters: "f", modifiers: .command))])
        let model = ShortcutsViewModel(additionalBindings: { Shortcuts.menuBindings(in: menu) })
        XCTAssertTrue(try self.item(.IDC_OPTIONS, in: model).hasConflict)
        XCTAssertTrue(try self.item(.IDC_FIND, in: model).hasConflict)
        item.keyEquivalent = ""
        XCTAssertTrue(Shortcuts.menuBindings(in: menu).isEmpty)
    }
}
