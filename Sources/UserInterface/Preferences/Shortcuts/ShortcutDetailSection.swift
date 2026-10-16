// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct ShortcutDetailSection: View {
    let item: ShortcutItem
    let conflicts: [ShortcutConflictItem]
    let isRecording: Bool
    let recordingModifiers: NSEvent.ModifierFlags
    let canAnimateRelease: Bool
    let canRecord: Bool
    let record: () -> Void
    let restore: () -> Void
    let selectConflict: (CommandWrapper) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ShortcutRecordingSection(
                    item: item, isRecording: isRecording, recordingModifiers: recordingModifiers,
                    canAnimateRelease: canAnimateRelease, record: record
                )
                    .id(item.command)
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
