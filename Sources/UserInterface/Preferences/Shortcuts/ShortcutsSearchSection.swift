// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct ShortcutsSearchSection: View {
    @Binding var searchText: String
    let searchedKey: ShortcutsKey?
    let isCapturing: Bool
    let isFocused: FocusState<Bool>.Binding
    let clearKeys: () -> Void
    let recordKeys: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .themedForeground(.textSecondary)
            TextField(NSLocalizedString("settings.shortcuts.searchField.placeholder", value: "Find shortcut keys", comment: "Shortcuts settings - Search field placeholder to find shortcuts"), text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("shortcuts.search")
                .focused(isFocused)
            if let searchedKey {
                Text(searchedKey.displayString)
                    .font(.system(size: 12, weight: .medium))
                Button(NSLocalizedString("settings.shortcuts.search.clearKeys", value: "Clear keys", comment: "Shortcuts settings - Remove the captured-key search filter"), action: clearKeys)
                    .font(.system(size: 11))
            }
            Button(isCapturing
                   ? NSLocalizedString("settings.shortcuts.search.pressKeys", value: "Press keys…", comment: "Shortcuts settings - Waiting for a key combination to search without executing it")
                   : NSLocalizedString("settings.shortcuts.search.recordKeys", value: "Record keys", comment: "Shortcuts settings - Search for bindings by pressing their key combination"), action: recordKeys)
                .font(.system(size: 11, weight: .medium))
                .accessibilityIdentifier("shortcuts.recordSearch")
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 34)
        .settingsCardChrome()
    }
}
