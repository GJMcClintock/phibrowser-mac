// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

private enum ShortcutsSearchLayout {
    static let controlHeight: CGFloat = 30
}

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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: ShortcutsSearchLayout.controlHeight)
        .themedBackground(.settingItemBackground)
        .clipShape(Capsule())
        .overlay {
            Capsule().themedStroke(.border)
        }
    }
}

struct ShortcutsFilterMenu: View {
    @State private var isHovered = false
    @Binding var selection: ShortcutsViewModel.Filter
    let sections: [String]
    let hasReservedShortcuts: Bool

    private var label: String {
        NSLocalizedString("settings.shortcuts.filter.label", value: "Filter Shortcuts", comment: "Shortcuts settings - Accessibility label and tooltip for the shortcut filter menu")
    }

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach([ShortcutsViewModel.Filter.all, .customized, .conflicting], id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
                Divider()
                ForEach(sections, id: \.self) { section in
                    Text(section).tag(ShortcutsViewModel.Filter.section(section))
                }
                if hasReservedShortcuts {
                    Text(ShortcutsViewModel.Filter.reserved.title)
                        .tag(ShortcutsViewModel.Filter.reserved)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .medium))
                .frame(width: ShortcutsSearchLayout.controlHeight, height: ShortcutsSearchLayout.controlHeight)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .themedFill(isHovered ? .hover : .clear)
                }
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
        // Preserve the full label as the hit target instead of a native popup's icon-sized control.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(selection.title)
        .accessibilityIdentifier("shortcuts.filter")
    }
}
