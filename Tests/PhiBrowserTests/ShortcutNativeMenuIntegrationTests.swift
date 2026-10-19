// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import ObjectiveC
import XCTest
@testable import Phi

private final class ShortcutMenuActionTarget: NSObject {
    var invocationCount = 0
    @objc func invokeShortcut(_ sender: Any?) { invocationCount += 1 }
    @objc(_processRequest:) func processService(_ sender: Any?) { invocationCount += 1 }
}

@MainActor
final class ShortcutNativeMenuIntegrationTests: XCTestCase {
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
