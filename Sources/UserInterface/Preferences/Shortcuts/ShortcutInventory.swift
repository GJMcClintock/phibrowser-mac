// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct ShortcutBinding: Hashable {
    enum Owner: Hashable {
        case command(Int)
        case nativeAction(String)

        var commandID: Int? {
            if case .command(let id) = self { return id }
            return nil
        }

        func precedes(_ other: Owner) -> Bool {
            switch (self, other) {
            case (.command(let lhs), .command(let rhs)): return lhs < rhs
            case (.command, .nativeAction): return true
            case (.nativeAction, .command): return false
            case (.nativeAction(let lhs), .nativeAction(let rhs)): return lhs < rhs
            }
        }
    }

    struct Scope: OptionSet, Hashable {
        let rawValue: Int
        static let browser = Scope(rawValue: 1 << 0)
        static let kiosk = Scope(rawValue: 1 << 1)
        static let nonBrowser = Scope(rawValue: 1 << 2)
        static let all: Scope = [.browser, .kiosk, .nonBrowser]
    }

    enum Source: Int, Hashable {
        case configured, menu, hidden, webContents
    }

    let owner: Owner
    let key: ShortcutsKey
    let scope: Scope
    let source: Source
    let title: String?

    var commandID: Int? { owner.commandID }

    init(commandID: Int, key: ShortcutsKey, scope: Scope, source: Source, title: String? = nil) {
        self.init(owner: .command(commandID), key: key, scope: scope, source: source, title: title)
    }

    init(owner: Owner, key: ShortcutsKey, scope: Scope, source: Source, title: String? = nil) {
        self.owner = owner
        self.key = key
        self.scope = scope
        self.source = source
        self.title = title
    }
}

/// A snapshot of effective bindings, shared by conflict detection and key search.
struct ShortcutInventory {
    let bindings: [ShortcutBinding]

    init(bindings: [ShortcutBinding]) {
        self.bindings = Set(bindings).sorted {
            if $0.owner != $1.owner { return $0.owner.precedes($1.owner) }
            if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
            if $0.key.characters != $1.key.characters { return $0.key.characters < $1.key.characters }
            if $0.key.modifiersRaw != $1.key.modifiersRaw { return $0.key.modifiersRaw < $1.key.modifiersRaw }
            if $0.scope != $1.scope { return $0.scope.rawValue < $1.scope.rawValue }
            return ($0.title ?? "") < ($1.title ?? "")
        }
    }

    func occupants(of key: ShortcutsKey, in scope: ShortcutBinding.Scope = .all) -> [ShortcutBinding] {
        bindings.filter {
            !$0.scope.intersection(scope).isEmpty && $0.key.menuKeyEquivalent == key.menuKeyEquivalent
        }
    }

    func conflicts(
        for commandID: Int,
        key: ShortcutsKey,
        in scope: ShortcutBinding.Scope
    ) -> [ShortcutBinding] {
        occupants(of: key, in: scope).filter { $0.owner != .command(commandID) }
    }

    func bindings(for commandID: Int) -> [ShortcutBinding] {
        bindings.filter { $0.owner == .command(commandID) }
    }
}
