// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Carbon.HIToolbox
import XCTest

/// Preconditions for deterministic XCTest shortcut synthesis. IME acceptance
/// runs separately with physical input; XCTest switches and restores sources
/// around synthesized keys, which can open Keyboard Settings on this host.
enum ShortcutUITestEnvironment {
    /// The data-directory override does not isolate UserDefaults or Keychain.
    /// Guest startup clears the Canary credential stores, including its shared
    /// app-group token. Require an explicit disposable-session opt-in first.
    static func requireDisposableGuestSession(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PHI_SHORTCUT_GUEST_TESTS"] == "1",
            "Shortcut Guest UI tests share Canary authentication stores. "
                + "Use a dedicated signed-out test session, then pass "
                + "TEST_RUNNER_PHI_SHORTCUT_GUEST_TESTS=1 to xcodebuild. "
                + "A temporary --user-data-dir does not protect a signed-in account.",
            file: file, line: line)
    }

    static func requireDirectKeyboardLayout(file: StaticString = #filePath, line: UInt = #line) throws {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let layout = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let identifier = stringProperty(source, kTISPropertyInputSourceID)
        let type = stringProperty(source, kTISPropertyInputSourceType)
        try XCTSkipUnless(
            type == kTISTypeKeyboardLayout as String
                && identifier == stringProperty(layout, kTISPropertyInputSourceID),
            "Shortcut UI synthesis requires a directly selected keyboard layout (for example ABC). "
                + "Current input source: \(identifier). Select a layout before rerunning; "
                + "the test does not change system input settings.",
            file: file, line: line)
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String {
        guard let value = TISGetInputSourceProperty(source, key) else { return "unknown" }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
}
