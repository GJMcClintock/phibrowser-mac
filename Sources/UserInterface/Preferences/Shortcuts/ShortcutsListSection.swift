// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct ShortcutsListSection: View {
    let sections: [(category: String, subtitle: String?, items: [ShortcutItem])]
    let reserved: [ReservedShortcutItem]
    @Binding var selection: CommandWrapper?
    let canRecord: Bool
    let record: (CommandWrapper) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(sections, id: \.category) { section in
                    Section {
                        ForEach(section.items) { item in
                            ShortcutListRow(item: item, isSelected: selection == item.command,
                                            canRecord: canRecord, record: { record(item.command) })
                                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                                .listRowBackground(selection == item.command ? Color.accentColor : Color.clear)
                                .tag(item.command)
                                .id(item.command)
                        }
                    } header: {
                        ShortcutListSectionHeader(title: section.category, subtitle: section.subtitle)
                    }
                }
                if !reserved.isEmpty {
                    Section {
                        ForEach(reserved) { item in
                            HStack {
                                Text(item.name)
                                Spacer(minLength: 8)
                                Text(Array(Set(item.keys.map(\.displayString))).sorted().joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11))
                            .padding(.vertical, 6)
                            .selectionDisabled()
                        }
                    } header: {
                        Text(NSLocalizedString("settings.shortcuts.reservedSection", value: "Other active shortcuts (read-only)", comment: "Shortcuts settings - Active native and browser bindings that this settings page cannot reassign"))
                    }
                }
            }
            .listStyle(.plain)
            .listSectionSeparator(.hidden)
            .environment(\.defaultMinListRowHeight, 34)
            .scrollContentBackground(.hidden)
            .onChange(of: selection) { _, command in
                if let command { proxy.scrollTo(command) }
            }
            .overlay {
                if sections.isEmpty && reserved.isEmpty {
                    Text(NSLocalizedString("settings.shortcuts.searchResults.emptyMessage", value: "No Results", comment: "Shortcuts settings - Empty state text when no shortcuts match search"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsCardChrome()
        .accessibilityIdentifier("shortcuts.list")
    }
}

private struct ShortcutListSectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }
}

private struct ShortcutListRow: View {
    let item: ShortcutItem
    let isSelected: Bool
    let canRecord: Bool
    let record: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(item.name)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.hasSystemConflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.yellow)
                    .help(ShortcutConflictItem.systemMessage)
                    .accessibilityLabel(ShortcutConflictItem.systemMessage)
                    .accessibilityIdentifier("shortcuts.systemConflict.\(item.command.rawValue)")
            }
            if !item.conflictingCommandNames.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white : Color.orange)
                    .help(item.conflictingCommandNames.joined(separator: ", "))
            }
            Button(action: record) {
                Text(item.shortcutDisplay)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .fixedSize()
                    .padding(.vertical, 4)
                    .padding(.horizontal, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canRecord)
            .accessibilityIdentifier("shortcuts.listRecord.\(item.command.rawValue)")
            .help(NSLocalizedString("settings.shortcuts.detail.recordHelp", value: "Click the shortcut to record a new combination.", comment: "Shortcuts settings - Hint below the shortcut recording button"))
        }
        .font(.system(size: 13))
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shortcuts.command.\(item.command.rawValue)")
    }
}
