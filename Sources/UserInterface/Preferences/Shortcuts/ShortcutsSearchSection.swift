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
    let isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .themedForeground(.textSecondary)
            TextField(NSLocalizedString("settings.shortcuts.searchField.placeholder", value: "Find shortcut keys", comment: "Shortcuts settings - Search field placeholder to find shortcuts"), text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("shortcuts.search")
                .focused(isFocused)
                .help(NSLocalizedString("settings.shortcuts.search.help", value: "Search by name or keys, such as cmd ctrl S or ⌘⌃S.", comment: "Shortcuts settings - Search supports modifier names, abbreviations, symbols, and key characters"))
        }
        .font(.system(size: 13))
        .controlSize(.small)
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
                        .themedFill(selection != .all || isHovered ? .hover : .clear)
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
