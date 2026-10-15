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

    func testReassignmentCanBeCanceledThenConfirmedWithBothRowsUpdated() {
        search("Duplicate Tab")
        settings.buttons["shortcuts.record.34027"].click()
        app.typeKey("r", modifierFlags: .command)
        let confirmation = settings.sheets.firstMatch
        XCTAssertTrue(confirmation.buttons["Cancel"].waitForExistence(timeout: 5))
        confirmation.buttons["Cancel"].click()
        XCTAssertEqual(settings.buttons["shortcuts.record.34027"].label, "Add New")
        settings.buttons["shortcuts.record.34027"].click()
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(confirmation.buttons["Reassign"].waitForExistence(timeout: 5))
        confirmation.buttons["Reassign"].click()
        XCTAssertEqual(settings.buttons["shortcuts.record.34027"].label, "⌘R")
        search("Reload Page")
        XCTAssertEqual(settings.buttons["shortcuts.record.33002"].label, "Add New")
        XCTAssertTrue(settings.buttons["shortcuts.restore.33002"].exists)
    }
}
