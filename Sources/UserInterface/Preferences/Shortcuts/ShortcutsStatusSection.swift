// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct ShortcutsStatusSection: View {
    @ObservedObject var viewModel: ShortcutsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("settings.shortcuts.sectionTitle", value: "Shortcuts", comment: "Shortcuts settings - Section title for keyboard shortcuts"))
                    .font(.system(size: 12, weight: .medium))
                    .themedForeground(.textSecondary)
                Spacer()
                Button(action: viewModel.restoreAllShortcuts) {
                    Label(NSLocalizedString("settings.shortcuts.restoreDefaultsButton", value: "Restore all shortcuts", comment: "Shortcuts settings - Button to reset all shortcuts to default"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .controlSize(.small)
                .themedForeground(.textSecondary)
            }
            if let failure = viewModel.persistenceFailure {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(failure.message).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if failure == .load {
                        Button(NSLocalizedString("settings.shortcuts.persistence.retry", value: "Retry", comment: "Shortcuts settings - Retry reading the saved configuration"), action: viewModel.retryLoadingShortcuts)
                    } else {
                        Button(NSLocalizedString("settings.shortcuts.persistence.dismiss", value: "Dismiss", comment: "Shortcuts settings - Dismiss a save failure without changing any shortcuts"), action: viewModel.dismissSaveFailure)
                    }
                }
                .font(.system(size: 11))
            }
            if let message = viewModel.recordingMessage {
                HStack(alignment: .top) {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(NSLocalizedString("settings.shortcuts.recording.dismiss", value: "Dismiss", comment: "Shortcuts settings - Dismiss a shortcut recording message")) {
                        viewModel.recordingMessage = nil
                    }
                }
                .font(.system(size: 11))
            }
        }
    }
}
