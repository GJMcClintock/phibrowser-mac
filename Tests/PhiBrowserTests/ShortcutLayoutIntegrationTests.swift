// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Phi

@MainActor
final class ShortcutLayoutIntegrationTests: XCTestCase {
    private let commandQWERTY = "com.apple.keylayout.DVORAK-QWERTYCMD"

    func testCommandQWERTYProjectsEverySupportedModifierCombination() throws {
        for source in [commandQWERTY, "com.apple.keylayout.Dhivehi-QWERTY",
                       "com.apple.keylayout.Inuktitut-QWERTY", "com.apple.keylayout.Cherokee-QWERTY"] {
            for flags in [NSEvent.ModifierFlags.command, .control, .option, [.control, .option]] {
                let event = try event(characters: ";", semantic: ";", flags: flags, code: kVK_ANSI_Z)
                let expected = ShortcutsKey(characters: "z", modifiers: flags)
                XCTAssertEqual(ShortcutsKey.recordingKey(for: event, inputSourceIdentifier: source), expected)
                XCTAssertEqual(CommandDispatcher.matchedPhiCommand(for: event,
                    shortcutMap: [expected: .PHI_COPY_URL], inputSourceIdentifier: source), .PHI_COPY_URL)
            }
        }
    }

    func testCommandQWERTYProjectionWinsOverAnASCIIEventFallback() throws {
        let event = try event(characters: "c", semantic: "\u{0421}", flags: .control, code: kVK_ANSI_Z)
        XCTAssertEqual(ShortcutsKey.recordingKey(for: event, inputSourceIdentifier: commandQWERTY),
                       .init(characters: "z", modifiers: .control))
        let shifted = try self.event(characters: "+", semantic: "+", flags: [.control, .shift], code: kVK_ANSI_RightBracket)
        XCTAssertEqual(ShortcutsKey.recordingKey(for: shifted, inputSourceIdentifier: commandQWERTY),
                       .init(characters: "}", modifiers: [.control, .shift]))
    }

    func testCommandNumberRowProjectionKeepsTheFrameworkModifierBoundary() throws {
        let source = "com.apple.keylayout.Czech"
        let event = try event(characters: "+", semantic: "+", flags: .command, code: kVK_ANSI_1)
        let keys = try XCTUnwrap(ShortcutsKey.eventKeys(for: event, inputSourceIdentifier: source))
        XCTAssertEqual(keys.canonical, .init(characters: "1", modifiers: .command))
        XCTAssertEqual(keys.legacy, .init(characters: "+", modifiers: .command))
        for flags in [NSEvent.ModifierFlags.control, [.command, .option], [.command, .shift],
                      [.command, .capsLock], [.command, .numericPad], [.command, .function]] {
            let modified = try self.event(characters: "+", semantic: "+", flags: flags, code: kVK_ANSI_1)
            XCTAssertEqual(ShortcutsKey.eventKeys(for: modified, inputSourceIdentifier: source)?.canonical.characters, "+")
        }
    }

    func testOneHandedDvorakNumberKeysAndSemanticLetterLayoutsRemainUnchanged() throws {
        for source in ["com.apple.keylayout.Dvorak-Left", "com.apple.keylayout.Dvorak-Right"] {
            let event = try event(characters: "+", semantic: "+", flags: .command, code: kVK_ANSI_1)
            XCTAssertEqual(ShortcutsKey.recordingKey(for: event, inputSourceIdentifier: source),
                           .init(characters: "+", modifiers: .command))
        }
        for source in ["com.apple.keylayout.Dvorak", "com.apple.keylayout.German", "com.apple.keylayout.US"] {
            let event = try event(characters: ";", semantic: ";", flags: .control, code: kVK_ANSI_Z)
            XCTAssertEqual(ShortcutsKey.recordingKey(for: event, inputSourceIdentifier: source),
                           .init(characters: ";", modifiers: .control))
        }
    }

    func testPairedFrameworkMatchesCommandQWERTYRecordedKeys() throws {
        try withInputSource(commandQWERTY) {
            for flags in [NSEvent.ModifierFlags.command, .control, .option, [.control, .option]] {
                let event = try event(characters: ";", semantic: ";", flags: flags, code: kVK_ANSI_Z)
                try assertPairedMatch(event, source: commandQWERTY, expected: .init(characters: "z", modifiers: flags))
            }
            let event = try event(characters: "+", semantic: "+", flags: [.control, .shift], code: kVK_ANSI_RightBracket)
            try assertPairedMatch(event, source: commandQWERTY, expected: .init(characters: "}", modifiers: [.control, .shift]))
        }
    }

    func testPairedFrameworkMatchesCzechNumberRowAndKeypadAlias() throws {
        let source = "com.apple.keylayout.Czech"
        try withInputSource(source) {
            let digit = try event(characters: "+", semantic: "+", flags: .command, code: kVK_ANSI_1)
            try assertPairedMatch(digit, source: source, expected: .init(characters: "1", modifiers: .command))
            let control = try event(characters: "+", semantic: "+", flags: .control, code: kVK_ANSI_1)
            try assertPairedMatch(control, source: source, expected: .init(characters: "+", modifiers: .control))
            let keypad = try event(characters: "1", semantic: "1", flags: [.command, .numericPad], code: kVK_ANSI_Keypad1)
            try assertPairedMatch(keypad, source: source, expected: .init(characters: "1", modifiers: .command))
        }
    }

    func testPairedFrameworkDistinguishesShiftedPrintableKeypadBindings() throws {
        let keypadKeys = [
            (kVK_ANSI_Keypad0, "0"), (kVK_ANSI_Keypad1, "1"), (kVK_ANSI_Keypad2, "2"),
            (kVK_ANSI_Keypad3, "3"), (kVK_ANSI_Keypad4, "4"), (kVK_ANSI_Keypad5, "5"),
            (kVK_ANSI_Keypad6, "6"), (kVK_ANSI_Keypad7, "7"), (kVK_ANSI_Keypad8, "8"),
            (kVK_ANSI_Keypad9, "9"), (kVK_ANSI_KeypadPlus, "+"), (kVK_ANSI_KeypadMinus, "-"),
            (kVK_ANSI_KeypadMultiply, "*"), (kVK_ANSI_KeypadDivide, "/"),
            (kVK_ANSI_KeypadEquals, "="), (kVK_ANSI_KeypadDecimal, "."), (kVK_JIS_KeypadComma, ",")
        ]
        for source in ["com.apple.keylayout.US", commandQWERTY] {
            try withInputSource(source) {
                for (code, character) in keypadKeys {
                    // Command-QWERTY maps keypad '=' through OEM_PLUS and
                    // has no JIS keypad-comma mapping. Those pre-existing
                    // character-projection gaps are separate from Shift loss.
                    if source == commandQWERTY && [kVK_ANSI_KeypadEquals, kVK_JIS_KeypadComma].contains(code) {
                        continue
                    }
                    let shiftedEvent = try event(characters: character, semantic: character,
                        flags: [.control, .shift, .numericPad], code: code)
                    let shifted = ShortcutsKey(characters: character, modifiers: [.control, .shift], preservesShift: true)
                    try assertPairedMatch(shiftedEvent, source: source, expected: shifted)
                    let unshiftedEvent = try event(characters: character, semantic: character,
                        flags: [.control, .numericPad], code: code)
                    let unshifted = ShortcutsKey(characters: character, modifiers: .control)
                    try assertPairedMatch(unshiftedEvent, source: source, expected: unshifted)
                    XCTAssertFalse(try frameworkMatches(unshifted, event: shiftedEvent))
                    XCTAssertFalse(try frameworkMatches(shifted, event: unshiftedEvent))
                    let map: [ShortcutsKey: CommandWrapper] = [shifted: .PHI_COPY_URL, unshifted: .PHI_SELECT_SPACE_0]
                    XCTAssertEqual(CommandDispatcher.matchedPhiCommand(for: shiftedEvent,
                        shortcutMap: map, inputSourceIdentifier: source), .PHI_COPY_URL)
                    XCTAssertEqual(CommandDispatcher.matchedPhiCommand(for: unshiftedEvent,
                        shortcutMap: map, inputSourceIdentifier: source), .PHI_SELECT_SPACE_0)
                }
                let mainDigit = try event(characters: "!", semantic: "!", flags: [.control, .shift], code: kVK_ANSI_1)
                try assertPairedMatch(mainDigit, source: source, expected: .init(characters: "!", modifiers: [.control, .shift]))
                let mainPlus = try event(characters: "+", semantic: "+", flags: [.control, .shift], code: kVK_ANSI_Equal)
                try assertPairedMatch(mainPlus, source: source, expected: .init(characters: "+", modifiers: [.control, .shift]))
                for (code, character) in [(kVK_UpArrow, "\u{F700}"), (kVK_ANSI_KeypadEnter, "\u{3}")] {
                    // The Framework projects keypad Enter to Return under
                    // Command-QWERTY; this test does not change that mapping.
                    if source == commandQWERTY && code == kVK_ANSI_KeypadEnter { continue }
                    let special = try event(characters: character, semantic: character,
                        flags: [.control, .shift, .numericPad], code: code)
                    try assertPairedMatch(special, source: source, expected: .init(characters: character, modifiers: [.control, .shift]))
                }
            }
        }
    }

    func testPairedFrameworkPreservesSemanticGermanAndDvorakKeys() throws {
        for (source, character, keyCode) in [
            ("com.apple.keylayout.German", "z", kVK_ANSI_Y),
            ("com.apple.keylayout.Dvorak", ";", kVK_ANSI_Z)
        ] {
            try withInputSource(source) {
                let event = try event(characters: character, semantic: character, flags: .control, code: keyCode)
                try assertPairedMatch(event, source: source, expected: .init(characters: character, modifiers: .control))
            }
        }
    }

    func testHeldFunctionIsNotLostOrRecordedAsAnOrdinaryMenuShortcut() throws {
        let source = "com.apple.keylayout.US"
        try withInputSource(source) {
            for flags in [NSEvent.ModifierFlags.function, [.control, .function], [.control, .shift, .function]] {
                let event = try event(characters: flags.contains(.shift) ? "E" : "e",
                    semantic: flags.contains(.shift) ? "E" : "e", flags: flags, code: kVK_ANSI_E)
                let key = ShortcutsKey(characters: "e", modifiers: flags)
                XCTAssertEqual(ShortcutsKey.eventKeys(for: event, inputSourceIdentifier: source)?.canonical, key)
                XCTAssertEqual(ShortcutsKey.recordingAction(for: event, inputSourceIdentifier: source), .unsupported)
                let withoutFunction = ShortcutsKey(characters: "e", modifiers: flags.subtracting(.function))
                XCTAssertFalse(try XCTUnwrap(ShortcutsKey.eventKeys(for: event, inputSourceIdentifier: source)).matches(withoutFunction))
                XCTAssertFalse(try frameworkMatches(withoutFunction, event: event))
                XCTAssertTrue(KioskGlobalShortcutRegistrar.configurations(for: key, isEnabled: true).isEmpty,
                             "Carbon must not silently register the chord without its Function modifier")
            }
            for (characters, code) in [("\u{F72D}", kVK_PageDown), ("\u{F700}", kVK_UpArrow), ("\u{F704}", kVK_F1)] {
                let event = try event(characters: characters, semantic: characters, flags: [.control, .function], code: code)
                try assertPairedMatch(event, source: source, expected: .init(characters: characters, modifiers: .control))
            }
            let noSemanticString = try event(characters: "e", semantic: "", flags: [.control, .function], code: kVK_ANSI_E)
            try assertPairedMatch(noSemanticString, source: source, expected: .init(characters: "e", modifiers: .control))
        }
    }

    private func assertPairedMatch(_ event: NSEvent, source: String, expected: ShortcutsKey) throws {
        let recorded = try XCTUnwrap(ShortcutsKey.recordingKey(for: event, inputSourceIdentifier: source))
        XCTAssertEqual(recorded, expected)
        XCTAssertTrue(try XCTUnwrap(ShortcutsKey.eventKeys(for: event, inputSourceIdentifier: source)).matches(recorded))
        XCTAssertTrue(try frameworkMatches(recorded, event: event), "Framework rejected \(source): \(recorded)")
    }

    private func frameworkMatches(_ key: ShortcutsKey, event: NSEvent) throws -> Bool {
        let equivalent = key.menuKeyEquivalent
        let item = NSMenuItem(title: "Layout contract", action: nil, keyEquivalent: equivalent.characters)
        item.keyEquivalentModifierMask = equivalent.modifiers
        let selector = NSSelectorFromString("cr_matchesKeyEquivalentEvent:")
        XCTAssertTrue(item.responds(to: selector))
        let implementation = try XCTUnwrap(item.method(for: selector))
        typealias Invoke = @convention(c) (AnyObject, Selector, NSEvent) -> Bool
        return unsafeBitCast(implementation, to: Invoke.self)(item, selector, event)
    }

    /// Exercises the loaded Framework with the real OS input-source identity.
    /// The key events are explicit fixtures, not physical keyboard input. Any
    /// temporary enablement and selection are restored before the test returns.
    private func withInputSource(_ identifier: String, _ body: () throws -> Void) throws {
        let sources = TISCreateInputSourceList([kTISPropertyInputSourceID as String: identifier] as CFDictionary, true)
            .takeRetainedValue() as! [TISInputSource]
        guard let source = sources.first else { throw XCTSkip("Input source not installed: \(identifier)") }
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let property = try XCTUnwrap(TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled))
        let wasEnabled = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(property).takeUnretainedValue())
        if !wasEnabled { XCTAssertEqual(TISEnableInputSource(source), noErr) }
        defer {
            XCTAssertEqual(TISSelectInputSource(original), noErr)
            if !wasEnabled { XCTAssertEqual(TISDisableInputSource(source), noErr) }
            NotificationCenter.default.post(name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        }
        XCTAssertEqual(TISSelectInputSource(source), noErr)
        // Initialize the Framework's listener before explicitly synchronizing
        // the notification; the OS notification may otherwise arrive later.
        _ = try frameworkMatches(.init(characters: "x", modifiers: .command),
            event: event(characters: "x", semantic: "x", flags: .command, code: kVK_ANSI_X))
        NotificationCenter.default.post(name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        try body()
    }

    private func event(characters: String, semantic: String, flags: NSEvent.ModifierFlags, code: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: semantic, isARepeat: false, keyCode: UInt16(code)))
    }
}
