// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
import Combine
struct ShortcutsSettingsView: View {
    @StateObject private var viewModel = ShortcutsViewModel()
    @State private var searchText: String = ""
    @FocusState private var isSearchFieldFocused: Bool
    
    private var filteredSections: [(category: String, subtitle: String?, items: [ShortcutItem])] {
        let query = searchText.lowercased()
        return viewModel.sections.compactMap { section in
            let filteredItems = section.items.filter { item in
                viewModel.matchesSearch(.command(item.command.rawValue)) && (query.isEmpty ||
                item.name.lowercased().contains(query) ||
                item.shortcutDisplay.lowercased().contains(query) ||
                item.aliases.contains { $0.displayString.lowercased().contains(query) } ||
                item.searchKeywords.contains(where: { $0.contains(query) }))
            }
            
            return filteredItems.isEmpty ? nil : (category: section.category, subtitle: section.subtitle, items: filteredItems)
        }
    }

    private var filteredReservedShortcuts: [ReservedShortcutItem] {
        viewModel.reservedShortcuts.filter { item in
            viewModel.matchesSearch(item.id) && (searchText.isEmpty ||
                item.name.localizedStandardContains(searchText) ||
                item.keys.contains { $0.displayString.localizedStandardContains(searchText) })
        }
    }
    
    var body: some View {
        let sections = filteredSections
        let reserved = filteredReservedShortcuts
        let isEmpty = sections.isEmpty && reserved.isEmpty
        
        return VStack(spacing: 0) {
            VStack {
                HStack {
                    Text(NSLocalizedString("settings.shortcuts.sectionTitle", value: "Shortcuts", comment: "Shortcuts settings - Section title for keyboard shortcuts"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                    
                    Spacer()
                    
                    Button {
                        viewModel.restoreAllShortcuts()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                            Text(NSLocalizedString("settings.shortcuts.restoreDefaultsButton", value: "Restore all shortcuts", comment: "Shortcuts settings - Button to reset all shortcuts to default"))
                                .font(.system(size: 13))
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if let failure = viewModel.persistenceFailure {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(failure.message)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if failure == .load {
                            Button(NSLocalizedString("settings.shortcuts.persistence.retry", value: "Retry", comment: "Shortcuts settings - Retry reading the saved configuration")) {
                                viewModel.retryLoadingShortcuts()
                            }
                        } else {
                            Button(NSLocalizedString("settings.shortcuts.persistence.dismiss", value: "Dismiss", comment: "Shortcuts settings - Dismiss a save failure without changing any shortcuts")) {
                                viewModel.dismissSaveFailure()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                if let message = viewModel.recordingMessage {
                    HStack {
                        Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(NSLocalizedString("settings.shortcuts.recording.dismiss", value: "Dismiss", comment: "Shortcuts settings - Dismiss a shortcut recording message")) {
                            viewModel.recordingMessage = nil
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                // Container with search bar and list
                VStack(spacing: 0) {
                    // Search bar
                    HStack(spacing: 8) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .frame(width: 16, height: 16)
                                .padding(.leading, 12)
                                .padding(.top, 12)
                                .padding(.bottom, 12)
                            
                            TextField(NSLocalizedString("settings.shortcuts.searchField.placeholder", value: "Find shortcut keys", comment: "Shortcuts settings - Search field placeholder to find shortcuts"), text: $searchText)
                                .textFieldStyle(.plain)
                                .accessibilityIdentifier("shortcuts.search")
                                .padding(.vertical, 6)
                                .focused($isSearchFieldFocused)
                            if let key = viewModel.searchedKey {
                                Text(key.displayString).font(.system(size: 12, weight: .medium))
                                Button(NSLocalizedString("settings.shortcuts.search.clearKeys", value: "Clear keys", comment: "Shortcuts settings - Remove the captured-key search filter")) {
                                    viewModel.searchedKey = nil
                                }
                            }
                            Button(viewModel.capture == .search
                                   ? NSLocalizedString("settings.shortcuts.search.pressKeys", value: "Press keys…", comment: "Shortcuts settings - Waiting for a key combination to search without executing it")
                                   : NSLocalizedString("settings.shortcuts.search.recordKeys", value: "Record keys", comment: "Shortcuts settings - Search for bindings by pressing their key combination")) {
                                searchText = ""
                                isSearchFieldFocused = false
                                viewModel.capture = viewModel.capture == .search ? nil : .search
                            }
                            .accessibilityIdentifier("shortcuts.recordSearch")
                            .padding(.trailing, 12)
                        }
                    }
                    // separator between searchbar and list
                    Rectangle()
                        .fill(Color(.separatorColor))
                        .frame(height: 1)
                        .padding(.leading, 0)
                        .padding(.trailing, 0)
                    
                    // Shortcuts list with empty state
                    ZStack {
                        List {
                            ForEach(sections, id: \.category) { section in
                                VStack(alignment: .leading, spacing: 0) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(section.category)
                                            .font(.system(size: 12, weight: .semibold))
                                        if let subtitle = section.subtitle {
                                            Text(subtitle)
                                                .font(.system(size: 11))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .foregroundColor(.secondary)
                                    .frame(minHeight: 35)
                                    .padding(.vertical, 8)
                                    
                                    Rectangle()
                                        .fill(Color(.separatorColor))
                                        .frame(height: 1)
                                    
                                    ForEach(section.items) { item in
                                        ShortcutRowView(
                                            item: item,
                                            isEditing: viewModel.editingCommand == item.command,
                                            handler: { action in
                                                handleAction(for: item, action: action)
                                            }
                                        )
                                        .disabled(!viewModel.canEdit)
                                        .overlay(alignment: .bottom) {
                                            Rectangle()
                                                .fill(Color(.separatorColor))
                                                .frame(height: 1)
                                        }
                                    }
                                }
                                // macOS list rows add 4pt padding by default, so use 4pt
                                // here to land on the designed 12pt visual spacing.
                                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                                .listRowSeparator(.hidden)
                            }
                            if !reserved.isEmpty {
                                Section {
                                    ForEach(reserved) { item in
                                        HStack {
                                            Text(item.name)
                                            Spacer()
                                            Text(Array(Set(item.keys.map(\.displayString))).sorted().joined(separator: ", "))
                                                .foregroundStyle(.secondary)
                                        }
                                        .font(.system(size: 12))
                                        .padding(.vertical, 6)
                                    }
                                } header: {
                                    Text(NSLocalizedString("settings.shortcuts.reservedSection", value: "Other active shortcuts (read-only)", comment: "Shortcuts settings - Active native and browser bindings that this settings page cannot reassign"))
                                }
                            }
                        }
                        .listStyle(.plain)
                        .listSectionSeparator(.hidden)
                        .scrollContentBackground(.hidden)
                        .opacity(isEmpty ? 0 : 1)
                        
                        if isEmpty {
                            Text(NSLocalizedString("settings.shortcuts.searchResults.emptyMessage", value: "No Results", comment: "Shortcuts settings - Empty state text when no shortcuts match search"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .themedBackground(ThemedColor(light: .white,
                                              dark: NSColor(hex: 0xFFFFFF, alpha: 0.02)))
                .cornerRadius(8)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.commonBorder), lineWidth: 1)
                }
            }
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .background {
            if viewModel.capture != nil {
                KeyCaptureView(onKeyEvent: viewModel.handleCaptureEvent,
                               onCancel: { viewModel.capture = nil })
                    .allowsHitTesting(false)
            } else {
                CommandShortcutCaptureView { event in
                    handleGlobalShortcut(event)
                }
                .allowsHitTesting(false)
            }
        }
        .onDisappear { viewModel.capture = nil }
        .alert(NSLocalizedString("settings.shortcuts.reassignment.title", value: "Shortcut already in use", comment: "Shortcuts settings - Title when a recorded key is already owned by another action"),
               isPresented: Binding(get: { viewModel.reassignment != nil }, set: { if !$0 { viewModel.reassignment = nil } }),
               presenting: viewModel.reassignment) { pending in
            if pending.canReassign {
                Button(NSLocalizedString("settings.shortcuts.reassignment.confirm", value: "Reassign", comment: "Shortcuts settings - Assign the recorded key and disable all bindings of the conflicting commands")) {
                    viewModel.confirmReassignment(pending)
                }
            }
            Button(NSLocalizedString("settings.shortcuts.reassignment.cancel", value: "Cancel", comment: "Shortcuts settings - Keep all existing bindings without assigning the recorded key"), role: .cancel) {}
        } message: { pending in
            Text(String(format: pending.canReassign
                        ? NSLocalizedString("settings.shortcuts.reassignment.message", value: "%@ is used by %@. Reassigning disables all shortcuts for those commands.", comment: "Shortcuts settings - Conflict confirmation; first placeholder is the recorded key, second is a list of command names")
                        : NSLocalizedString("settings.shortcuts.reassignment.reserved", value: "%@ is used by %@. These shortcuts cannot be changed here. Choose a different key.", comment: "Shortcuts settings - Conflict with read-only bindings; first placeholder is the recorded key, second is their names"),
                        pending.key.displayString, pending.names.joined(separator: ", ")))
        }
    }
    
    private func handleAction(for item: ShortcutItem, action: ShortcutRowView.Action) {
        switch action {
        case .restoreTapped:
            viewModel.restoreDefaultShortcut(for: item.command)
            cancelEditing()
        case .editTapped:
            if viewModel.editingCommand == item.command {
                cancelEditing()
            } else {
                isSearchFieldFocused = false
                viewModel.recordingMessage = nil
                viewModel.editingCommand = item.command
            }
        }
    }
    
    private func cancelEditing() {
        viewModel.editingCommand = nil
        if isSearchFieldFocused {
            isSearchFieldFocused = false
        }
    }
    
    private func handleGlobalShortcut(_ event: NSEvent) {
        guard viewModel.capture == nil else { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command,
            event.charactersIgnoringModifiers?.lowercased() == "f" {
            isSearchFieldFocused = true
        } else if event.keyCode == 53 && modifiers.isEmpty {
            // esc
            isSearchFieldFocused = false
        }
    }
}

// MARK: - Row View
struct ShortcutRowView: View {
    enum Action {
        case restoreTapped
        case editTapped
    }
    
    let item: ShortcutItem
    let isEditing: Bool
    let handler: (Action) -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.primary)
                    .frame(height: 16)
                
                if item.hasConflict {
                    Text(String(format: NSLocalizedString("settings.shortcuts.conflictMessage", value: "Conflicts with: %@", comment: "Shortcuts settings - Warning text showing conflicting shortcuts"), item.conflictingCommandNames.joined(separator: ", ")))
                        .font(.system(size: 11))
                        .foregroundColor(.yellow)
                }
                let aliases = item.aliases.filter { $0.menuKeyEquivalent != item.shortcutKey?.menuKeyEquivalent }
                if !aliases.isEmpty {
                    Text(String(format: NSLocalizedString("settings.shortcuts.aliases", value: "Also: %@", comment: "Shortcuts settings - Additional effective key combinations for the same command"),
                                aliases.map(\.displayString).joined(separator: ", ")))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.vertical, 10)
            
            Spacer()
            
            if item.isOverridden {
                Button(NSLocalizedString("settings.shortcuts.restoreShortcutButton", value: "Restore", comment: "Shortcuts settings - Button to restore single shortcut to default")) {
                    handler(.restoreTapped)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("shortcuts.restore.\(item.command.rawValue)")
            }
            
            Button(action: { handler(.editTapped) }) {
                Text(isEditing ? NSLocalizedString("settings.shortcuts.recordingPrompt", value: "Press shortcut…", comment: "Shortcuts settings - Prompt text when recording new shortcut") : item.shortcutDisplay)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(isEditing ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .frame(minWidth: 80)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isEditing ?
                                      Color.accentColor.opacity(0.1) :
                                        Color(NSColor.controlBackgroundColor)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(
                                            isEditing ?
                                            Color.accentColor :
                                                Color(NSColor.separatorColor),
                                            lineWidth: isEditing ? 1.5 : 0.5
                                        )
                                )
                        }
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("shortcuts.record.\(item.command.rawValue)")
            .scaleEffect(isEditing ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isEditing)
        }
        .frame(minHeight: 42)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Key Capture View

struct KeyCaptureView: NSViewRepresentable {
    let onKeyEvent: (NSEvent) -> Void
    let onCancel: () -> Void
    
    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyEvent = onKeyEvent
        view.onCancel = onCancel
        return view
    }
    
    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyEvent = onKeyEvent
        nsView.onCancel = onCancel
    }
}

final class KeyCaptureNSView: NSView {
    var onKeyEvent: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        stopMonitoring()
        guard let window else { return }
        guard window.isKeyWindow, window.makeFirstResponder(self) else {
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            return
        }
        startMonitoring()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.stopMonitoring()
            self?.onCancel?()
        }
    }

    override func resignFirstResponder() -> Bool {
        stopMonitoring()
        DispatchQueue.main.async { [weak self] in self?.onCancel?() }
        return super.resignFirstResponder()
    }

    func process(_ event: NSEvent) -> NSEvent? {
        guard eventMonitor != nil, event.type == .keyDown, let window, window.isKeyWindow, NSApp.isActive,
              event.window === window, window.firstResponder === self,
              let onKeyEvent else { return event }
        onKeyEvent(event)
        return nil
    }
    
    private func startMonitoring() {
        stopMonitoring()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.process(event)
        }
    }
    
    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
    
    deinit {
        stopMonitoring()
    }
}

// MARK: - Command Shortcut Capture View

struct CommandShortcutCaptureView: NSViewRepresentable {
    let onKeyEvent: (NSEvent) -> Void
    
    func makeNSView(context: Context) -> CommandShortcutCaptureNSView {
        let view = CommandShortcutCaptureNSView()
        view.onKeyEvent = onKeyEvent
        return view
    }
    
    func updateNSView(_ nsView: CommandShortcutCaptureNSView, context: Context) {
        nsView.onKeyEvent = onKeyEvent
    }
}

final class CommandShortcutCaptureNSView: NSView {
    var onKeyEvent: ((NSEvent) -> Void)?
    private var eventMonitor: Any?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    func process(_ event: NSEvent) -> NSEvent {
        if event.type == .keyDown, let window, window.isKeyWindow,
           NSApp.isActive, event.window === window {
            onKeyEvent?(event)
        }
        return event
    }
    
    private func startMonitoring() {
        stopMonitoring()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.process(event) ?? event
        }
    }
    
    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    deinit {
        stopMonitoring()
    }
}

extension View {
    func debugBorder(_ color: Color = .red) -> some View {
        self.overlay(
            Rectangle()
                .stroke(color, lineWidth: 1)
        )
    }
}

#Preview {
    ShortcutsSettingsView()
}
