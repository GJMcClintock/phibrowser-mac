// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct ShortcutDetailSection: View {
    let item: ShortcutItem
    let conflicts: [ShortcutConflictItem]
    let isRecording: Bool
    let canRecord: Bool
    let record: () -> Void
    let restore: () -> Void
    let selectConflict: (CommandWrapper) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ShortcutRecordingSection(item: item, isRecording: isRecording, record: record)
                    .disabled(!canRecord)
                Divider()
                ShortcutDescriptionSection(item: item)
                ShortcutConflictsSection(conflicts: conflicts, selectCommand: selectConflict)
                Divider()
                ShortcutRestoreSection(item: item, restore: restore)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .settingsCardChrome()
        .accessibilityIdentifier("shortcuts.detail.\(item.command.rawValue)")
    }
}

struct ShortcutRecordingSection: View {
    @State private var isHovered = false
    let item: ShortcutItem
    let isRecording: Bool
    let record: () -> Void

    private var aliases: [ShortcutsKey] {
        item.aliases.filter { $0.menuKeyEquivalent != item.shortcutKey?.menuKeyEquivalent }
    }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: record) {
                Text(isRecording
                     ? NSLocalizedString("settings.shortcuts.recordingPrompt", value: "Press shortcut…", comment: "Shortcuts settings - Prompt text when recording new shortcut")
                     : item.shortcutDisplay)
                    .font(.system(size: item.shortcutKey == nil || isRecording ? 13 : 24, weight: .medium))
                    .foregroundStyle(isRecording ? Color.accentColor : .primary)
                    .padding(.horizontal, 18)
                    .frame(minWidth: 112, minHeight: 52)
                    .background(isRecording ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor.opacity(isRecording ? 1 : isHovered ? 0.5 : 0), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityIdentifier("shortcuts.record.\(item.command.rawValue)")
            Text(isRecording
                 ? NSLocalizedString("settings.shortcuts.detail.recordingHelp", value: "Press Escape to cancel, or Delete to remove the shortcut.", comment: "Shortcuts settings - Instructions while recording a shortcut")
                 : NSLocalizedString("settings.shortcuts.detail.recordHelp", value: "Click the shortcut to record a new combination.", comment: "Shortcuts settings - Hint below the shortcut recording button"))
                .font(.system(size: 11))
                .themedForeground(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !aliases.isEmpty {
                Text(String(format: NSLocalizedString("settings.shortcuts.aliases", value: "Also: %@", comment: "Shortcuts settings - Additional effective key combinations for the same command"), aliases.map(\.displayString).joined(separator: ", ")))
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

struct ShortcutDescriptionSection: View {
    let item: ShortcutItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.system(size: 16, weight: .semibold))
                .themedForeground(.textPrimary)
            Text(item.command.shortcutDescription)
                .font(.system(size: 13))
                .lineSpacing(2)
                .themedForeground(.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ShortcutConflictsSection: View {
    let conflicts: [ShortcutConflictItem]
    let selectCommand: (CommandWrapper) -> Void

    var body: some View {
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(NSLocalizedString("settings.shortcuts.detail.conflicts", value: "This shortcut conflicts with:", comment: "Shortcuts settings - Heading above commands sharing an active shortcut"))
                        .themedForeground(.textSecondary)
                }
                .font(.system(size: 11, weight: .medium))
                ForEach(conflicts) { conflict in
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conflict.name)
                                .font(.system(size: 12, weight: .medium))
                                .themedForeground(.textPrimary)
                            Text(conflict.keys.joined(separator: ", "))
                                .font(.system(size: 11))
                                .themedForeground(.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let command = conflict.command {
                            Button { selectCommand(command) } label: {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 26, height: 26)
                                    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(format: NSLocalizedString("settings.shortcuts.detail.goToCommand", value: "Go to %@", comment: "Shortcuts settings - Navigate to a conflicting command; %@ is its name"), conflict.name))
                            .accessibilityIdentifier("shortcuts.conflict.\(command.rawValue)")
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ShortcutRestoreSection: View {
    let item: ShortcutItem
    let restore: () -> Void

    var body: some View {
        Button(NSLocalizedString("settings.shortcuts.restoreShortcutButton", value: "Restore", comment: "Shortcuts settings - Button to restore single shortcut to default"), action: restore)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 12))
            .disabled(!item.isOverridden)
            .accessibilityIdentifier("shortcuts.restore.\(item.command.rawValue)")
    }
}
