// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import Phi

private final class ShortcutMenuActionTarget: NSObject {
    var invocationCount = 0
    @objc func invokeShortcut(_ sender: Any?) { invocationCount += 1 }
    @objc(_processRequest:) func processService(_ sender: Any?) { invocationCount += 1 }
}

@MainActor
final class ShortcutNativeMenuIntegrationTests: XCTestCase {
    func testMenuTrackingPreservesCustomHostingViewsWithoutCopyingThem() throws {
        try XCTUnwrap(AppController.shared).startObservingServiceShortcuts()
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        Shortcuts.configuration = ShortcutConfiguration()
        let menu = NSMenu()
        let submenu = NSMenu()
        let parent = NSMenuItem()
        parent.submenu = submenu
        menu.addItem(parent)

        let editor = NSMenuItem()
        let hostingView = ThemedHostingView(rootView: Text("Theme editor"), themeSource: ThemeManager.shared)
        editor.view = hostingView
        submenu.addItem(editor)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)

        // Items inserted during tracking must also avoid copying a hosting
        // view, even when a known shortcut would otherwise create an alias.
        let added = NSMenuItem(title: "Custom action",
                              action: #selector(ShortcutMenuActionTarget.invokeShortcut(_:)), keyEquivalent: "!")
        added.tag = CommandWrapper.PHI_CAPTURE_FULL_PAGE.rawValue
        let addedView = ThemedHostingView(rootView: Text("Custom action"), themeSource: ThemeManager.shared)
        added.view = addedView
        submenu.addItem(added)
        XCTAssertEqual(added.keyEquivalent, "!")
        XCTAssertEqual(submenu.items.count, 2)
        XCTAssertTrue(editor.view === hostingView)
        XCTAssertTrue(added.view === addedView)
        XCTAssertEqual(Shortcuts.menuBindings(in: menu).map(\.commandID), [added.tag])

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(submenu.items.count, 2)
        XCTAssertTrue(editor.view === hostingView)
        XCTAssertTrue(added.view === addedView)
        XCTAssertEqual(added.keyEquivalent, "!")
    }

    func testCustomViewWithoutShortcutIsSafeForInventoryAndServiceNotifications() throws {
        try XCTUnwrap(AppController.shared).startObservingServiceShortcuts()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Custom service",
                              action: NSSelectorFromString("_processRequest:"), keyEquivalent: "")
        let hostingView = ThemedHostingView(rootView: Text("Custom service"), themeSource: ThemeManager.shared)
        item.view = hostingView
        menu.addItem(item)
        XCTAssertTrue(Shortcuts.menuBindings(in: menu).isEmpty)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertTrue(Shortcuts.menuBindings(in: menu).isEmpty)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertTrue(item.view === hostingView)
        XCTAssertTrue(item.keyEquivalent.isEmpty)
        XCTAssertEqual(menu.items.count, 1)
    }

    func testAllShiftedDigitsUseSharedMenuPresentationAndRestoreMatchingKeys() throws {
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        try XCTUnwrap(AppController.shared).startObservingServiceShortcuts()
        let digits: [(String, String, UInt16)] = [
            ("1", "!", 18), ("2", "@", 19), ("3", "#", 20), ("4", "$", 21),
            ("5", "%", 23), ("6", "^", 22), ("7", "&", 26), ("8", "*", 28),
            ("9", "(", 25), ("0", ")", 29)
        ]
        for modifiers in [NSEvent.ModifierFlags.command, .control, .option, [.command, .option]] {
            for (digit, symbol, code) in digits {
                let menu = NSMenu()
                menu.autoenablesItems = false
                let target = ShortcutMenuActionTarget()
                let item = NSMenuItem(title: "Native action",
                    action: #selector(ShortcutMenuActionTarget.invokeShortcut(_:)), keyEquivalent: symbol)
                let key = ShortcutsKey(characters: symbol, modifiers: modifiers.union(.shift))
                item.tag = CommandWrapper.IDC_RELOAD.rawValue
                Shortcuts.configuration = ShortcutConfiguration(overrides: [item.tag: .custom(key)])
                item.keyEquivalentModifierMask = modifiers
                item.target = target
                menu.addItem(item)
                let before = Shortcuts.menuBindings(in: menu)
                XCTAssertEqual(key.keycapTokens.last, digit)
                XCTAssertTrue(key.keycapTokens.contains("⇧"))
                XCTAssertEqual(key.menuKeyEquivalent.characters, symbol)
                XCTAssertEqual(key.menuKeyEquivalent.modifiers, modifiers)

                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
                XCTAssertEqual(item.keyEquivalent, digit)
                XCTAssertEqual(item.keyEquivalentModifierMask, modifiers.union(.shift))
                XCTAssertEqual(Shortcuts.menuBindings(in: menu), before)
                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
                XCTAssertEqual(Shortcuts.menuBindings(in: menu), before)

                let keyboardEvent = try XCTUnwrap(CGEvent(
                    keyboardEventSource: nil, virtualKey: code, keyDown: true))
                keyboardEvent.flags = CGEventFlags(rawValue: UInt64(modifiers.union(.shift).rawValue))
                let event = try XCTUnwrap(NSEvent(cgEvent: keyboardEvent))
                XCTAssertTrue(menu.performKeyEquivalent(with: event))
                XCTAssertEqual(target.invocationCount, 1)

                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
                XCTAssertEqual(item.keyEquivalent, symbol)
                XCTAssertEqual(item.keyEquivalentModifierMask, modifiers)
                XCTAssertEqual(Shortcuts.menuBindings(in: menu), before)
                XCTAssertEqual(menu.items.count, 1)
            }
        }
    }

    func testMenuPresentationPreservesPairedFrameworkMatching() throws {
        let selector = NSSelectorFromString("cr_matchesKeyEquivalentEvent:")
        let item = NSMenuItem(title: "Matching", action: nil, keyEquivalent: "!")
        guard item.responds(to: selector) else {
            throw XCTSkip("The paired Framework does not expose cr_matchesKeyEquivalentEvent:")
        }
        try XCTUnwrap(AppController.shared).startObservingServiceShortcuts()
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        Shortcuts.configuration = ShortcutConfiguration()
        item.tag = CommandWrapper.PHI_CAPTURE_FULL_PAGE.rawValue
        let menu = NSMenu()
        menu.addItem(item)
        let implementation = try XCTUnwrap(item.method(for: selector))
        typealias Match = @convention(c) (AnyObject, Selector, NSEvent) -> Bool
        let matches = unsafeBitCast(implementation, to: Match.self)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "!", charactersIgnoringModifiers: "!", isARepeat: false, keyCode: 18))
        XCTAssertTrue(matches(item, selector, event))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertEqual(item.keyEquivalent, "1")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertTrue(matches(item, selector, event))
    }

    func testMenuPresentationHandlesNestedAndDynamicItemsWithoutRestoringStaleBindings() throws {
        try XCTUnwrap(AppController.shared).startObservingServiceShortcuts()
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        Shortcuts.configuration = ShortcutConfiguration(overrides: [
            CommandWrapper.IDC_RELOAD.rawValue: .custom(.init(characters: "#", modifiers: [.command, .shift]))
        ])
        let menu = NSMenu()
        let parent = NSMenuItem()
        let submenu = NSMenu()
        parent.submenu = submenu
        menu.addItem(parent)
        let item = NSMenuItem(title: "Visible", action: #selector(ShortcutMenuActionTarget.invokeShortcut(_:)),
                              keyEquivalent: "!")
        item.tag = CommandWrapper.PHI_CAPTURE_FULL_PAGE.rawValue
        submenu.addItem(item)
        let hidden = NSMenuItem(title: "Hidden", action: item.action, keyEquivalent: "@")
        hidden.tag = CommandWrapper.PHI_CAPTURE_AREA.rawValue
        hidden.isHidden = true
        submenu.addItem(hidden)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertEqual(item.keyEquivalent, "1")
        XCTAssertEqual(hidden.keyEquivalent, "@")
        let added = NSMenuItem(title: "Added", action: item.action, keyEquivalent: "#")
        added.tag = CommandWrapper.IDC_RELOAD.rawValue
        submenu.addItem(added)
        XCTAssertEqual(added.keyEquivalent, "3")
        item.keyEquivalent = "j"
        item.keyEquivalentModifierMask = [.command, .control]
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(item.keyEquivalent, "j")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .control])
        XCTAssertEqual(added.keyEquivalent, "#")
        XCTAssertEqual(added.keyEquivalentModifierMask, .command)
        XCTAssertEqual(hidden.keyEquivalent, "@")
        XCTAssertEqual(submenu.items.count, 3)
    }

    func testMenuPresentationDoesNotInferShiftFromUnknownOrReassignedSymbols() throws {
        try XCTUnwrap(AppController.shared).startObservingServiceShortcuts()
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        Shortcuts.configuration = ShortcutConfiguration()
        let menu = NSMenu()
        for tag in [0, CommandWrapper.PHI_CAPTURE_FULL_PAGE.rawValue] {
            let item = NSMenuItem(title: "Symbol", action: nil, keyEquivalent: "*")
            item.tag = tag
            menu.addItem(item)
        }
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertEqual(menu.items.map(\.keyEquivalent), ["*", "*"])
        XCTAssertEqual(menu.items.map(\.keyEquivalentModifierMask), [.command, .command])
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
    }

    func testProjectedMenuAliasFollowsAvailabilityAndRemoval() throws {
        try XCTUnwrap(AppController.shared).startObservingServiceShortcuts()
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        let command = CommandWrapper.IDC_RELOAD
        Shortcuts.configuration = ShortcutConfiguration(overrides: [
            command.rawValue: .custom(.init(characters: "*", modifiers: [.command, .shift]))
        ])
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = ShortcutMenuActionTarget()
        let item = NSMenuItem(title: "Multiply", action: #selector(ShortcutMenuActionTarget.invokeShortcut(_:)),
                              keyEquivalent: "*")
        item.tag = command.rawValue
        item.target = target
        menu.addItem(item)
        let keyboardEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 67, keyDown: true))
        keyboardEvent.flags = [.maskCommand, .maskNumericPad]
        let event = try XCTUnwrap(NSEvent(cgEvent: keyboardEvent))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(target.invocationCount, 1)
        item.isEnabled = false
        XCTAssertFalse(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(target.invocationCount, 1)
        item.isEnabled = true
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        menu.removeItem(item)
        XCTAssertTrue(menu.items.isEmpty)
        XCTAssertEqual(item.keyEquivalent, "*")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertFalse(menu.performKeyEquivalent(with: event))
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
    }

    func testServiceShortcutIsClearedOnInsertionAndReassignment() throws {
        try XCTUnwrap(AppController.shared).startObservingServiceShortcuts()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let service = NSMenuItem(title: "Localized service", action: NSSelectorFromString("_processRequest:"),
                                 keyEquivalent: "A")
        service.keyEquivalentModifierMask = .command
        menu.addItem(service)
        XCTAssertTrue(service.keyEquivalent.isEmpty)
        XCTAssertTrue(try XCTUnwrap(service.copy() as? NSMenuItem).keyEquivalent.isEmpty)
        XCTAssertNotNil(service.action)
        for hidden in [false, true] {
            service.isHidden = hidden
            service.isEnabled = !hidden
            service.keyEquivalentModifierMask = [.command, .shift]
            service.keyEquivalent = "a"
            XCTAssertTrue(service.keyEquivalent.isEmpty)
            XCTAssertTrue(try XCTUnwrap(service.copy() as? NSMenuItem).keyEquivalent.isEmpty)
        }
        service.keyEquivalentModifierMask = .command
        service.keyEquivalent = "M"
        XCTAssertEqual(service.keyEquivalent, "M")
    }

    func testServiceSuppressionCoversReplacementSubmenusAndMenuTracking() throws {
        try XCTUnwrap(AppController.shared).startObservingServiceShortcuts()
        let menu = NSMenu()
        let submenu = NSMenu(title: "Replacement")
        let service = NSMenuItem(title: "Localized service", action: nil, keyEquivalent: "A")
        service.keyEquivalentModifierMask = .command
        submenu.addItem(service)
        // Target/action can be installed after the key, without a key-change notification.
        service.action = NSSelectorFromString("_processRequest:")
        let parent = NSMenuItem()
        parent.submenu = submenu
        menu.addItem(parent)
        XCTAssertTrue(service.keyEquivalent.isEmpty)
        service.action = nil
        service.keyEquivalentModifierMask = .command
        service.keyEquivalent = "A"
        service.action = NSSelectorFromString("_processRequest:")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertTrue(service.keyEquivalent.isEmpty)
    }

    func testReservedChordInvokesBrowserActionInsteadOfService() throws {
        try XCTUnwrap(AppController.shared).startObservingServiceShortcuts()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let serviceTarget = ShortcutMenuActionTarget()
        let browserTarget = ShortcutMenuActionTarget()
        let service = NSMenuItem(title: "Service", action: NSSelectorFromString("_processRequest:"),
                                 keyEquivalent: "A")
        service.target = serviceTarget
        service.keyEquivalentModifierMask = .command
        menu.addItem(service)
        let browser = NSMenuItem(title: "Tab Search", action: #selector(ShortcutMenuActionTarget.invokeShortcut(_:)),
                                 keyEquivalent: "A")
        browser.tag = CommandWrapper.IDC_TAB_SEARCH.rawValue
        browser.target = browserTarget
        browser.keyEquivalentModifierMask = .command
        menu.addItem(browser)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "A", charactersIgnoringModifiers: "A", isARepeat: false, keyCode: 0))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(browserTarget.invocationCount, 1)
        XCTAssertEqual(serviceTarget.invocationCount, 0)
        XCTAssertEqual(Shortcuts.menuBindings(in: menu).map(\.commandID), [browser.tag])
    }

    private func dispatcher(handlingPriority: Int32?) throws -> NSObject {
        let base = try XCTUnwrap(NSClassFromString("ChromeCommandDispatcherDelegate") as? NSObject.Type)
        guard let handlingPriority else { return base.init() }
        let name = "ShortcutPriorityTest_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let subclass = try XCTUnwrap(objc_allocateClassPair(base, name, 0))
        let selector = NSSelectorFromString("eventHandledByViewsFocusManager:priority:")
        let method = try XCTUnwrap(class_getInstanceMethod(base, selector))
        let handler: @convention(block) (NSObject, NSEvent, Int32) -> Bool = { _, _, priority in
            priority == handlingPriority
        }
        XCTAssertTrue(class_addMethod(subclass, selector, imp_implementationWithBlock(handler), method_getTypeEncoding(method)))
        objc_registerClassPair(subclass)
        return try XCTUnwrap(subclass as? NSObject.Type).init()
    }

    // Call the real companion dispatcher without adding a test-only bridge API.
    // Its Objective-C entry points return ui::PerformKeyEquivalentResult (int).
    private func postResult(_ dispatcher: NSObject, event: NSEvent,
                            window: NSWindow, redispatch: Bool) throws -> Int32 {
        let selector = NSSelectorFromString("postPerformKeyEquivalent:window:isRedispatch:")
        XCTAssertTrue(dispatcher.responds(to: selector))
        let implementation = try XCTUnwrap(dispatcher.method(for: selector))
        typealias Invoke = @convention(c) (AnyObject, Selector, NSEvent, NSWindow, Bool) -> Int32
        return unsafeBitCast(implementation, to: Invoke.self)(dispatcher, selector, event, window, redispatch)
    }

    private func assertNativeOwnership(characters: String, modifiers: NSEvent.ModifierFlags,
                                       keyCode: UInt16, enabled: Bool,
                                       command: CommandWrapper = .IDC_OPTIONS,
                                       extensionPriority: Int32? = nil) throws {
        let dispatcher = try dispatcher(handlingPriority: extensionPriority)
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }

        let target = ShortcutMenuActionTarget()
        let menu = NSMenu(title: "Shortcut integration test")
        menu.autoenablesItems = false
        let submenu = NSMenu(title: "Native")
        submenu.autoenablesItems = false
        let parent = NSMenuItem(title: "Native", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
        let item = NSMenuItem(title: "Native action", action: #selector(ShortcutMenuActionTarget.invokeShortcut(_:)),
                              keyEquivalent: characters)
        item.target = target
        item.tag = command.rawValue
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = enabled
        submenu.addItem(item)
        NSApp.mainMenu = menu

        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))

        let preSelector = NSSelectorFromString("prePerformKeyEquivalent:window:")
        let preImplementation = try XCTUnwrap(dispatcher.method(for: preSelector))
        typealias PreInvoke = @convention(c) (AnyObject, Selector, NSEvent, NSWindow) -> Int32
        let preResult = unsafeBitCast(preImplementation, to: PreInvoke.self)(dispatcher, preSelector, event, window)
        XCTAssertEqual(preResult, extensionPriority == 1 ? 1 : 0)
        XCTAssertEqual(target.invocationCount, 0)
        if extensionPriority == 1 { return }

        for redispatch in [false, true] {
            // kPassToMainMenu, not hidden command dispatch or kUnhandled.
            XCTAssertEqual(try postResult(dispatcher, event: event, window: window, redispatch: redispatch),
                           extensionPriority == 0 ? 1 : 2)
            XCTAssertEqual(target.invocationCount, 0)
        }
        if extensionPriority == 0 { return }
        // AppKit consumes even a disabled match, but must not invoke its action.
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(target.invocationCount, enabled ? 1 : 0)
    }

    func testNativeSelectorOwnsHiddenNextTabKeyAndRunsItsTargetOnce() throws {
        try assertNativeOwnership(characters: "\u{F72D}", modifiers: .control, keyCode: 121, enabled: true)
    }

    func testSelectionCommandTagsKeepNativeDispatchWhenReboundToHiddenKey() throws {
        for command in [CommandWrapper.IDS_EDIT_USE_SELECTION_MAC, .IDS_EDIT_JUMP_TO_SELECTION_MAC] {
            try assertNativeOwnership(characters: "\u{F72D}", modifiers: .control,
                                      keyCode: 121, enabled: true, command: command)
            try assertNativeOwnership(characters: "\u{F72D}", modifiers: .control,
                                      keyCode: 121, enabled: false, command: command)
        }
    }

    func testDisabledNativeSelectorDoesNotFallBackToHiddenNextTab() throws {
        try assertNativeOwnership(characters: "\u{F72D}", modifiers: .control, keyCode: 121, enabled: false)
    }

    func testNativeSelectorAlsoOwnsDelayedBackKeyOnRedispatch() throws {
        try assertNativeOwnership(characters: "\u{F702}", modifiers: .command, keyCode: 123, enabled: true)
    }

    func testHighPriorityExtensionGateStillPrecedesNativeMenu() throws {
        try assertNativeOwnership(characters: "\u{F72D}", modifiers: .control, keyCode: 121,
                                  enabled: true, extensionPriority: 1)
    }

    func testNormalPriorityExtensionGateStillPrecedesNativeMenuOnRedispatch() throws {
        try assertNativeOwnership(characters: "\u{F702}", modifiers: .command, keyCode: 123,
                                  enabled: true, extensionPriority: 0)
    }

    func testBookmarkBarShortcutReachesNativeActionWithoutOpeningViewMenu() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        let defaults = UserDefaults.standard
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let visibilityKey = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.rawValue
        let previousLayout = defaults.object(forKey: layoutKey)
        let previousVisibility = defaults.object(forKey: visibilityKey)
        defer {
            defaults.set(previousLayout, forKey: layoutKey)
            defaults.set(previousVisibility, forKey: visibilityKey)
            bridge.requestRebuildMainMenu()
        }
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        defaults.set(false, forKey: visibilityKey)
        bridge.requestRebuildMainMenu()
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let viewMenu = try XCTUnwrap(ChromiumMainMenuRole.view.item(in: menu)?.submenu)
        let item = try XCTUnwrap(viewMenu.items.first {
            $0.tag == CommandWrapper.IDC_SHOW_BOOKMARK_BAR.rawValue
        })
        XCTAssertEqual(item.action, NSSelectorFromString("toggleBookmarkBar:"))

        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "B", charactersIgnoringModifiers: "B", isARepeat: false, keyCode: 11))
        let dispatcher = try dispatcher(handlingPriority: nil)
        for redispatch in [false, true] {
            XCTAssertEqual(try postResult(dispatcher, event: event, window: window, redispatch: redispatch), 2)
        }
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertTrue(PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue())
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertFalse(PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue())
    }
}
