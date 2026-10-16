// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest

final class ShortcutSettingsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var settings: XCUIElement { app.windows["Shortcuts"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try ShortcutUITestEnvironment.requireDisposableGuestSession()
        try ShortcutUITestEnvironment.requireDirectKeyboardLayout()
        app = XCUIApplication()
        app.launchArguments += [
            "-uitest", "1", "-skip-onboarding", "-AppleLanguages", "(en)",
            "--user-data-dir=\(NSTemporaryDirectory())PhiShortcutsUITest-\(UUID().uuidString)",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 120))
        app.activate()
        try ShortcutUITestEnvironment.requireDirectKeyboardLayout()
        openSettings()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    private func openSettings() {
        app.typeKey(",", modifierFlags: .command)
        let pane = app.toolbars.buttons["Shortcuts"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.click()
        XCTAssertTrue(settings.textFields["shortcuts.search"].waitForExistence(timeout: 5))
    }

    private func search(_ text: String) {
        let field = settings.textFields["shortcuts.search"]
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    func testRecordedKeySearchFindsHiddenAliasWithoutExecutingIt() {
        settings.buttons["shortcuts.recordSearch"].click()
        app.typeKey(.pageDown, modifierFlags: .control)
        XCTAssertTrue(settings.buttons["Clear keys"].waitForExistence(timeout: 5))
        XCTAssertTrue(settings.buttons["shortcuts.record.34016"].exists)
        XCTAssertFalse(settings.buttons["shortcuts.record.40015"].exists)
        XCTAssertEqual(settings.buttons["shortcuts.recordSearch"].label, "Record keys")
    }

    func testSwitchingWindowCancelsRecordingAndPreservesOtherWindowInput() throws {
        app.typeKey("n", modifierFlags: .command)
        openSettings()
        settings.buttons["shortcuts.recordSearch"].click()
        let windowMenu = app.menuBars.menuBarItems["Window"]
        windowMenu.click()
        // The standard Window menu exposes each window by its title.
        let otherWindow = try XCTUnwrap(app.windows.allElementsBoundByIndex.first { !$0.title.isEmpty && $0.title != "Shortcuts" })
        windowMenu.menuItems.matching(identifier: otherWindow.title).firstMatch.click()
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(app.textFields["Search or Enter URL"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        openSettings()
        XCTAssertEqual(settings.buttons["shortcuts.recordSearch"].label, "Record keys")
        XCTAssertFalse(settings.buttons["Clear keys"].exists)
    }

    func testLeavingShortcutsPaneStopsCaptureAndDoesNotRestartIt() {
        settings.buttons["shortcuts.recordSearch"].click()
        settings.toolbars.buttons["General"].click()
        app.typeKey("f", modifierFlags: .command)
        app.toolbars.buttons["Shortcuts"].click()
        XCTAssertEqual(settings.buttons["shortcuts.recordSearch"].label, "Record keys")
        XCTAssertFalse(settings.buttons["Clear keys"].exists)
    }

    func testSelectingRowsStartsRecordingAndSwitchesTarget() {
        let newWindow = settings.descendants(matching: .any).matching(identifier: "shortcuts.command.34000").firstMatch
        let newTab = settings.descendants(matching: .any).matching(identifier: "shortcuts.command.34014").firstMatch
        XCTAssertTrue(newWindow.waitForExistence(timeout: 5))
        newWindow.click()
        XCTAssertEqual(settings.buttons["shortcuts.record.34000"].label, "Press shortcut…")
        newTab.click()
        XCTAssertEqual(settings.buttons["shortcuts.record.34014"].label, "Press shortcut…")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(settings.buttons["shortcuts.record.34014"].label, "⌘T")
        newTab.click()
        XCTAssertEqual(settings.buttons["shortcuts.record.34014"].label, "Press shortcut…")
        app.typeKey(.escape, modifierFlags: [])
        search("New Window")
        XCTAssertEqual(settings.buttons["shortcuts.record.34000"].label, "⌘N")
    }

    func testDetailRestoreAndConflictNavigation() {
        search("Duplicate Tab")
        let duplicateRestore = settings.buttons["shortcuts.restore.34027"]
        XCTAssertTrue(duplicateRestore.waitForExistence(timeout: 5))
        XCTAssertFalse(duplicateRestore.isEnabled)
        settings.buttons["shortcuts.record.34027"].click()
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(settings.buttons["shortcuts.conflict.33002"].waitForExistence(timeout: 5))
        XCTAssertFalse(settings.sheets.firstMatch.exists)
        XCTAssertTrue(duplicateRestore.isEnabled)

        search("Reload Page")
        let reloadRestore = settings.buttons["shortcuts.restore.33002"]
        XCTAssertFalse(reloadRestore.isEnabled)
        let conflict = settings.buttons["shortcuts.conflict.34027"]
        XCTAssertTrue(conflict.waitForExistence(timeout: 5))
        conflict.click()
        XCTAssertEqual(settings.textFields["shortcuts.search"].value as? String, "")
        XCTAssertTrue(settings.buttons["shortcuts.record.34027"].waitForExistence(timeout: 5))
        XCTAssertTrue(duplicateRestore.isEnabled)
        duplicateRestore.click()
        XCTAssertFalse(duplicateRestore.isEnabled)
        XCTAssertFalse(settings.buttons["shortcuts.conflict.33002"].exists)
    }

    func testRecordingConflictingNewWindowKeyKeepsNewTabBinding() {
        search("New Window")
        let recorder = settings.buttons["shortcuts.record.34000"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 5))
        recorder.click()
        app.typeKey("t", modifierFlags: .command)
        let conflict = settings.buttons["shortcuts.conflict.34014"]
        XCTAssertTrue(conflict.waitForExistence(timeout: 5))
        XCTAssertFalse(settings.sheets.firstMatch.exists)
        XCTAssertEqual(recorder.label, "⌘T")
        conflict.click()
        XCTAssertEqual(settings.buttons["shortcuts.record.34014"].label, "Press shortcut…")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(settings.buttons["shortcuts.record.34014"].label, "⌘T")
        XCTAssertFalse(settings.buttons["shortcuts.restore.34014"].isEnabled)
        settings.buttons["shortcuts.conflict.34000"].click()
        settings.buttons["shortcuts.restore.34000"].click()
        XCTAssertEqual(settings.buttons["shortcuts.record.34000"].label, "⌘N")
        XCTAssertFalse(settings.buttons["shortcuts.conflict.34014"].exists)
    }
}
