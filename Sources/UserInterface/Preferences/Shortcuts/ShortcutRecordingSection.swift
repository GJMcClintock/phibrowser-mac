// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct ShortcutRecordingSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRaised = true

    let item: ShortcutItem
    let isRecording: Bool
    let recordingModifiers: NSEvent.ModifierFlags
    let canAnimateRelease: Bool
    let record: () -> Void

    private var aliases: [ShortcutsKey] {
        item.aliases.filter { $0.menuKeyEquivalent != item.shortcutKey?.menuKeyEquivalent }
    }

    private var tokens: [String] {
        if recordingModifiers.isEmpty && !item.shortcutKeycapTokens.isEmpty {
            return item.shortcutKeycapTokens
        }
        if isRecording {
            return Array(ShortcutsKey(characters: "", modifiers: recordingModifiers).keycapTokens.dropLast()) + ["…"]
        }
        return item.shortcutKeycapTokens
    }

    private var recordingPrompt: String {
        NSLocalizedString("settings.shortcuts.recordingPrompt", value: "Press shortcut…", comment: "Shortcuts settings - Prompt text when recording new shortcut")
    }

    var body: some View {
        VStack(spacing: 10) {
            Button(action: record) {
                ZStack {
                    Ellipse()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 180, height: 64)
                        .blur(radius: 20)
                        .opacity(isRecording ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isRecording)
                    if tokens.isEmpty {
                        Text(item.shortcutDisplay)
                            .font(.system(size: 13, weight: .medium))
                            .themedForeground(.textSecondary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        ViewThatFits(in: .horizontal) {
                            ShortcutKeycapCombination(tokens: tokens, isRaised: isRaised && !isRecording, compact: false)
                            ShortcutKeycapCombination(tokens: tokens, isRaised: isRaised && !isRecording, compact: true)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 112)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording ? recordingPrompt : item.shortcutDisplay)
            .accessibilityValue(isRecording ? tokens.joined() : "")
            .accessibilityIdentifier("shortcuts.record.\(item.command.rawValue)")

            Text(isRecording
                 ? NSLocalizedString("settings.shortcuts.detail.recordingHelp", value: "Press Escape to cancel, or Delete to remove the shortcut.", comment: "Shortcuts settings - Instructions while recording a shortcut")
                 : NSLocalizedString("settings.shortcuts.detail.recordHelp", value: "Click the shortcut to record a new combination.", comment: "Shortcuts settings - Hint below the shortcut recording button"))
                .font(.system(size: 11))
                .themedForeground(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 30, alignment: .top)
            if !aliases.isEmpty {
                Text(String(format: NSLocalizedString("settings.shortcuts.aliases", value: "Also: %@", comment: "Shortcuts settings - Additional effective key combinations for the same command"), aliases.map(\.displayString).joined(separator: ", ")))
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .task(id: isRecording) {
            if isRecording {
                isRaised = false
                return
            }
            guard !isRaised else { return }
            guard !reduceMotion, canAnimateRelease, item.shortcutKey != nil else {
                isRaised = true
                return
            }
            // Mount the completed combination in its pressed state before releasing it.
            // The task is cancelled when recording restarts or the selected command changes.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            withAnimation(.spring(duration: 0.38, bounce: 0.1)) { isRaised = true }
        }
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }
}

private struct ShortcutKeycapCombination: View {
    let tokens: [String]
    let isRaised: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 5 : 8) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                ShortcutKeycap(token: token, isRaised: isRaised, compact: compact)
            }
        }
        .fixedSize()
    }
}

private struct ShortcutKeycap: View {
    @Environment(\.colorScheme) private var colorScheme
    let token: String
    let isRaised: Bool
    let compact: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: compact ? 8 : 11) }
    private var edge: Color { Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.7 : 0.4) }

    var body: some View {
        Text(verbatim: token)
            .font(.system(size: compact ? 21 : 28, weight: .medium))
            .themedForeground(token == "…" ? .textSecondary : .textPrimary)
            .frame(minWidth: compact ? 30 : 44)
            .padding(.horizontal, compact ? 3 : 5)
            .frame(height: compact ? 48 : 58)
            .background {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        shape.fill(LinearGradient(
                            colors: [Color.primary.opacity(0), Color.primary.opacity(0.035)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .opacity(isRaised ? 1 : 0)
                    }
            }
            .overlay { shape.strokeBorder(edge, lineWidth: 1) }
            .compositingGroup()
            .shadow(color: edge.opacity(isRaised ? 1 : 0), radius: 0, y: isRaised ? 4 : 0)
            .shadow(color: .black.opacity(isRaised ? (colorScheme == .dark ? 0.25 : 0.1) : 0), radius: isRaised ? 5 : 0, y: isRaised ? 7 : 0)
            .offset(y: isRaised ? 0 : 4)
    }
}
