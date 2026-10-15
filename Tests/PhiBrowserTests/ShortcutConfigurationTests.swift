// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import AppKit
#if !SHORTCUTS_HOSTLESS_TESTS
@testable import Phi
#endif

final class ShortcutConfigurationTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("CustomShortcuts.json") }
    private let reloadID = CommandWrapper.IDC_RELOAD.rawValue
    private let custom = ShortcutOverride.custom(ShortcutsKey(characters: "r", modifiers: [.control]))
    private let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func seed() throws -> ShortcutConfiguration {
        var configuration = ShortcutConfiguration()
        try configuration.set(custom, for: reloadID, at: url)
        return configuration
    }

    func testMissingFileInheritsDefaultsWithoutWriting() throws {
        var configuration = ShortcutConfiguration()
        try configuration.reload(from: url)
        XCTAssertTrue(configuration.overrides.isEmpty)
        XCTAssertNil(configuration.loadError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testExplicitDisabledAndRestoredDefaultRemainDistinctAfterReload() throws {
        var configuration = try seed()
        try configuration.set(.disabled, for: reloadID, at: url)
        var loaded = ShortcutConfiguration()
        try loaded.reload(from: url)
        XCTAssertEqual(loaded.overrides[reloadID], .disabled)
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertTrue(items.first?["key"] is NSNull)

        try loaded.set(nil, for: reloadID, at: url)
        try configuration.reload(from: url)
        XCTAssertNil(configuration.overrides[reloadID])
    }

    func testLegacyOmittedKeyAndUnknownCommandSurviveAnotherEdit() throws {
        let legacy = Data("[{\"commandId\":999991},{\"commandId\":999992,\"key\":{\"characters\":\"x\",\"modifiersRaw\":1048576}}]".utf8)
        try legacy.write(to: url)
        var configuration = ShortcutConfiguration()
        try configuration.reload(from: url)
        try configuration.set(custom, for: reloadID, at: url)
        var loaded = ShortcutConfiguration()
        try loaded.reload(from: url)
        XCTAssertEqual(loaded.overrides[999991], .disabled)
        XCTAssertEqual(loaded.overrides[999992], .custom(ShortcutsKey(characters: "x", modifiers: .command)))
        XCTAssertEqual(loaded.overrides[reloadID], custom)
    }

    func testWriteFailureKeepsRuntimeAndDiskAndCanRetry() throws {
        _ = try seed()
        let original = try Data(contentsOf: url)
        var rejectWrite = true
        var files = ShortcutConfiguration.FileAccess.live
        files.write = { [denied] data, url in
            if rejectWrite { throw denied }
            try ShortcutConfiguration.FileAccess.live.write(data, url)
        }
        var configuration = ShortcutConfiguration(files: files)
        try configuration.reload(from: url)
        XCTAssertThrowsError(try configuration.set(.disabled, for: reloadID, at: url))
        XCTAssertEqual(configuration.overrides[reloadID], custom)
        XCTAssertEqual(try Data(contentsOf: url), original)
        rejectWrite = false
        try configuration.set(.disabled, for: reloadID, at: url)
        XCTAssertEqual(configuration.overrides[reloadID], .disabled)
    }

    func testCorruptReloadPreservesSameAccountAndBlocksSubsequentWrites() throws {
        var configuration = try seed()
        let corrupt = Data("not valid json".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try configuration.reload(from: url))
        XCTAssertEqual(configuration.overrides[reloadID], custom)
        XCTAssertNotNil(configuration.loadError)
        XCTAssertThrowsError(try configuration.set(.disabled, for: reloadID, at: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testReadPermissionFailureIsNotTreatedAsMissing() throws {
        var files = ShortcutConfiguration.FileAccess.live
        files.read = { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
        var writes = 0
        files.write = { _, _ in writes += 1 }
        var configuration = ShortcutConfiguration(files: files)
        XCTAssertThrowsError(try configuration.reload(from: url))
        XCTAssertNotNil(configuration.loadError)
        XCTAssertThrowsError(try configuration.set(custom, for: reloadID, at: url))
        XCTAssertEqual(writes, 0)
    }

    func testFailedAccountSwitchDoesNotExposePreviousAccountBindings() throws {
        var configuration = try seed()
        let other = directory.appendingPathComponent("OtherAccount.json")
        try Data("broken".utf8).write(to: other)
        XCTAssertThrowsError(try configuration.reload(from: other))
        XCTAssertTrue(configuration.overrides.isEmpty)
        XCTAssertEqual(configuration.fileURL, other.standardizedFileURL)
        XCTAssertThrowsError(try configuration.set(custom, for: reloadID, at: other))
        var originalAccount = ShortcutConfiguration()
        try originalAccount.reload(from: url)
        XCTAssertEqual(originalAccount.overrides[reloadID], custom)
    }

    func testExplicitResetPreservesDamagedBytesInRecoveryFile() throws {
        let damaged = Data("[{ partial json".utf8)
        try damaged.write(to: url)
        var configuration = ShortcutConfiguration()
        XCTAssertThrowsError(try configuration.reload(from: url))
        try configuration.restoreDefaults(at: url)
        let backup = try XCTUnwrap(configuration.recoveryURL)
        XCTAssertEqual(try Data(contentsOf: backup), damaged)
        XCTAssertEqual(try Data(contentsOf: url), Data("[]".utf8))
        XCTAssertTrue(configuration.overrides.isEmpty)
        XCTAssertNil(configuration.loadError)
    }

    func testBackupFailurePreventsResettingDamagedConfiguration() throws {
        let damaged = Data("broken".utf8)
        try damaged.write(to: url)
        var files = ShortcutConfiguration.FileAccess.live
        files.backup = { [denied] _, _ in throw denied }
        var writes = 0
        files.write = { _, _ in writes += 1 }
        var configuration = ShortcutConfiguration(files: files)
        XCTAssertThrowsError(try configuration.restoreDefaults(at: url))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        XCTAssertEqual(writes, 0)
        XCTAssertNotNil(configuration.loadError)
    }

    func testResetWriteFailurePreservesOriginalAndRecovery() throws {
        let damaged = Data("broken".utf8)
        try damaged.write(to: url)
        var files = ShortcutConfiguration.FileAccess.live
        files.write = { [denied] _, _ in throw denied }
        var configuration = ShortcutConfiguration(files: files)
        XCTAssertThrowsError(try configuration.restoreDefaults(at: url))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(configuration.recoveryURL)), damaged)
        XCTAssertNotNil(configuration.loadError)
    }

    func testRestoreAllWriteFailureRetainsValidOverrides() throws {
        _ = try seed()
        let original = try Data(contentsOf: url)
        var files = ShortcutConfiguration.FileAccess.live
        files.write = { [denied] _, _ in throw denied }
        var configuration = ShortcutConfiguration(files: files)
        try configuration.reload(from: url)
        XCTAssertThrowsError(try configuration.restoreDefaults(at: url))
        XCTAssertEqual(configuration.overrides[reloadID], custom)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testDuplicateCommandIDsRejectAmbiguousConfiguration() throws {
        try Data("[{\"commandId\":1,\"key\":null},{\"commandId\":1,\"key\":null}]".utf8).write(to: url)
        var configuration = ShortcutConfiguration()
        XCTAssertThrowsError(try configuration.reload(from: url))
        XCTAssertNotNil(configuration.loadError)
        XCTAssertThrowsError(try configuration.set(custom, for: reloadID, at: url))
    }

    func testSuccessfulReloadAfterRepairAllowsWritesAgain() throws {
        try Data("broken".utf8).write(to: url)
        var configuration = ShortcutConfiguration()
        XCTAssertThrowsError(try configuration.reload(from: url))
        try Data("[]".utf8).write(to: url, options: .atomic)
        try configuration.reload(from: url)
        try configuration.set(custom, for: reloadID, at: url)
        XCTAssertNil(configuration.loadError)
        XCTAssertEqual(configuration.overrides[reloadID], custom)
    }

    func testSerializationOrdersCommandsDeterministically() throws {
        var configuration = ShortcutConfiguration()
        try configuration.set(.disabled, for: 99, at: url)
        try configuration.set(.disabled, for: 3, at: url)
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["commandId"] as? Int }, [3, 99])
    }

    func testReassignmentPersistsTargetAndDisablesAllConflictingCommandsTogether() throws {
        var configuration = try seed()
        try configuration.set(custom, for: 99, disabling: [reloadID, 100, 99], at: url)
        var loaded = ShortcutConfiguration()
        try loaded.reload(from: url)
        XCTAssertEqual(loaded.overrides[99], custom)
        XCTAssertEqual(loaded.overrides[reloadID], .disabled)
        XCTAssertEqual(loaded.overrides[100], .disabled)
    }

    func testFailedReassignmentDoesNotDisableAnyPreviousOwner() throws {
        _ = try seed()
        let original = try Data(contentsOf: url)
        var files = ShortcutConfiguration.FileAccess.live
        files.write = { [denied] _, _ in throw denied }
        var configuration = ShortcutConfiguration(files: files)
        try configuration.reload(from: url)
        XCTAssertThrowsError(try configuration.set(custom, for: 99, disabling: [reloadID, 100], at: url))
        XCTAssertEqual(configuration.overrides[reloadID], custom)
        XCTAssertNil(configuration.overrides[99])
        XCTAssertNil(configuration.overrides[100])
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
