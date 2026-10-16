// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum ShortcutOverride: Equatable {
    case disabled
    case custom(ShortcutsKey)
    case excluding([ShortcutsKey])

    var excludedKeys: [ShortcutsKey] {
        if case .excluding(let keys) = self { return keys }
        return []
    }

    func excludes(_ key: ShortcutsKey) -> Bool {
        excludedKeys.contains { $0.menuKeyEquivalent == key.menuKeyEquivalent }
    }

    var inheritsDefaults: Bool {
        if case .excluding = self { return true }
        return false
    }

    var key: ShortcutsKey? {
        switch self {
        case .disabled, .excluding: return nil
        case .custom(let key): return key
        }
    }
}

/// Owns one account's durable overrides. Missing entries inherit their defaults.
struct ShortcutConfiguration {
    struct FileAccess {
        var read: (URL) throws -> Data
        var write: (Data, URL) throws -> Void
        var backup: (URL, URL) throws -> Void

        static let live = FileAccess(
            read: { try Data(contentsOf: $0) },
            write: { data, url in
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            },
            backup: { try FileManager.default.copyItem(at: $0, to: $1) }
        )
    }

    enum Failure: Error {
        case unreadableConfiguration
        case duplicateCommand(Int)
    }

    private struct Record: Codable {
        let commandId: Int
        let key: ShortcutsKey?
        let excludedKeys: [ShortcutsKey]?

        enum CodingKeys: String, CodingKey {
            case commandId, key, excludedKeys
        }

        init(commandId: Int, state: ShortcutOverride) {
            self.commandId = commandId
            key = state.key
            excludedKeys = state.inheritsDefaults ? state.excludedKeys : nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            commandId = try container.decode(Int.self, forKey: .commandId)
            key = try container.decodeIfPresent(ShortcutsKey.self, forKey: .key)
            excludedKeys = try container.decodeIfPresent([ShortcutsKey].self, forKey: .excludedKeys)
            if excludedKeys != nil && key != nil {
                throw DecodingError.dataCorruptedError(forKey: .excludedKeys, in: container,
                    debugDescription: "A shortcut cannot replace and exclude defaults simultaneously")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(commandId, forKey: .commandId)
            try container.encode(key, forKey: .key)
            try container.encodeIfPresent(excludedKeys, forKey: .excludedKeys)
        }
    }

    private(set) var overrides: [Int: ShortcutOverride] = [:]
    private(set) var fileURL: URL?
    private(set) var loadError: Error?
    private(set) var recoveryURL: URL?
    private let files: FileAccess

    init(
        overrides: [Int: ShortcutOverride] = [:],
        fileURL: URL? = nil,
        files: FileAccess = .live
    ) {
        self.overrides = overrides
        self.fileURL = fileURL?.standardizedFileURL
        self.files = files
    }

    mutating func reload(from url: URL) throws {
        let url = url.standardizedFileURL
        if fileURL != url {
            // Never carry one account's bindings into another account on failure.
            overrides = [:]
            recoveryURL = nil
        }
        fileURL = url
        do {
            let records: [Record]
            do {
                records = try JSONDecoder().decode([Record].self, from: files.read(url))
            } catch {
                let error = error as NSError
                guard error.domain == NSCocoaErrorDomain,
                      error.code == NSFileReadNoSuchFileError
                        || error.code == NSFileNoSuchFileError else {
                    throw error
                }
                overrides = [:]
                loadError = nil
                return
            }

            var loaded: [Int: ShortcutOverride] = [:]
            for record in records {
                guard loaded[record.commandId] == nil else {
                    throw Failure.duplicateCommand(record.commandId)
                }
                loaded[record.commandId] = record.excludedKeys.map(ShortcutOverride.excluding)
                    ?? record.key.map(ShortcutOverride.custom) ?? .disabled
            }
            overrides = loaded
            loadError = nil
        } catch {
            loadError = error
            throw error
        }
    }

    mutating func set(
        _ override: ShortcutOverride?,
        for commandId: Int,
        updating conflicts: [Int: ShortcutOverride] = [:],
        at url: URL
    ) throws {
        try prepareForWrite(at: url)
        var updated = overrides
        for (conflict, state) in conflicts where conflict != commandId {
            updated[conflict] = state
        }
        updated[commandId] = override
        try commit(updated, at: url)
    }

    /// An explicit reset preserves unreadable contents before replacing them.
    mutating func restoreDefaults(at url: URL) throws {
        let url = url.standardizedFileURL
        if fileURL != url {
            do {
                try reload(from: url)
            } catch {
                // Recovery below must preserve the source before any write.
            }
        }
        if loadError != nil {
            let backupURL = url.deletingPathExtension()
                .appendingPathExtension("recovery-" + UUID().uuidString + ".json")
            try files.backup(url, backupURL)
            recoveryURL = backupURL
        }
        try commit([:], at: url)
    }

    private mutating func prepareForWrite(at url: URL) throws {
        if fileURL != url.standardizedFileURL {
            try reload(from: url)
        }
        guard loadError == nil else {
            throw Failure.unreadableConfiguration
        }
    }

    private mutating func commit(_ updated: [Int: ShortcutOverride], at url: URL) throws {
        let records = updated.sorted { $0.key < $1.key }.map {
            Record(commandId: $0.key, state: $0.value)
        }
        let data = try JSONEncoder().encode(records)
        try files.write(data, url.standardizedFileURL)
        overrides = updated
        fileURL = url.standardizedFileURL
        loadError = nil
    }
}
