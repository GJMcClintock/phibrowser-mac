// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
import Combine

struct ShortcutsSettingsView: View {
    @StateObject private var viewModel = ShortcutsViewModel()
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ShortcutsSearchSection(
                    searchText: $viewModel.searchText,
                    searchedKey: viewModel.searchedKey,
                    isCapturing: viewModel.capture == .search,
                    isFocused: $isSearchFieldFocused,
                    clearKeys: { viewModel.searchedKey = nil },
                    recordKeys: toggleSearchCapture
                )
                ShortcutsFilterMenu(
                    selection: $viewModel.filter,
                    sections: viewModel.sections.map(\.category),
                    hasReservedShortcuts: !viewModel.reservedShortcuts.isEmpty
                )
            }
            ShortcutsStatusSection(viewModel: viewModel)
            HStack(alignment: .top, spacing: 16) {
                ShortcutsListSection(
                    sections: viewModel.filteredSections,
                    reserved: viewModel.filteredReservedShortcuts,
                    selection: Binding(get: { viewModel.selectedCommand }, set: selectCommand),
                    canRecord: viewModel.canEdit,
                    record: startRecording
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let item = viewModel.selectedItem {
                    ShortcutDetailSection(
                        item: item,
                        conflicts: viewModel.conflicts(for: item.command),
                        isRecording: viewModel.editingCommand == item.command,
                        recordingModifiers: viewModel.recordingModifiers,
                        canAnimateRelease: viewModel.persistenceFailure == nil,
                        canRecord: viewModel.canEdit,
                        record: { toggleRecording(for: item.command) },
                        restore: { viewModel.restoreDefaultShortcut(for: item.command) },
                        selectConflict: selectConflict
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(NSLocalizedString("settings.shortcuts.detail.empty", value: "Select a shortcut to view its details.", comment: "Shortcuts settings - Detail pane when no editable command is selected"))
                        .font(.system(size: 13))
                        .themedForeground(.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(36)
        .background {
            if viewModel.capture != nil {
                let sessionID = viewModel.captureSessionID
                KeyCaptureView(onKeyEvent: viewModel.handleCaptureEvent,
                               onCancel: { viewModel.cancelCapture(sessionID: sessionID) },
                               onModifiersChanged: viewModel.handleCaptureModifiers)
                    .id(sessionID)
                    .allowsHitTesting(false)
            } else {
                CommandShortcutCaptureView(onKeyEvent: handleGlobalShortcut)
                    .allowsHitTesting(false)
            }
        }
        .onDisappear { viewModel.capture = nil }
    }

    private func toggleSearchCapture() {
        viewModel.searchText = ""
        isSearchFieldFocused = false
        viewModel.capture = viewModel.capture == .search ? nil : .search
    }

    private func toggleRecording(for command: CommandWrapper) {
        if viewModel.editingCommand == command {
            viewModel.capture = nil
        } else {
            startRecording(for: command)
        }
    }

    private func startRecording(for command: CommandWrapper) {
        isSearchFieldFocused = false
        viewModel.startRecording(for: command)
    }

    private func selectCommand(_ command: CommandWrapper?) {
        isSearchFieldFocused = false
        viewModel.selectedCommand = command
    }

    private func selectConflict(_ command: CommandWrapper) {
        isSearchFieldFocused = false
        viewModel.selectConflict(command)
    }

    private func handleGlobalShortcut(_ event: NSEvent) {
        guard viewModel.capture == nil else { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            isSearchFieldFocused = true
        } else if event.keyCode == 53 && modifiers.isEmpty {
            isSearchFieldFocused = false
        }
    }
}

// MARK: - Key Capture View

struct KeyCaptureView: NSViewRepresentable {
    let onKeyEvent: (NSEvent) -> Void
    let onCancel: () -> Void
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)? = nil
    
    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyEvent = onKeyEvent
        view.onCancel = onCancel
        view.onModifiersChanged = onModifiersChanged
        return view
    }
    
    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyEvent = onKeyEvent
        nsView.onCancel = onCancel
        nsView.onModifiersChanged = onModifiersChanged
    }
}

final class KeyCaptureNSView: NSView {
    var onKeyEvent: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
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
        guard eventMonitor != nil, let window, window.isKeyWindow, NSApp.isActive,
              event.window === window, window.firstResponder === self,
              let onKeyEvent else { return event }
        if event.type == .flagsChanged {
            onModifiersChanged?(event.modifierFlags)
            return event
        }
        guard event.type == .keyDown else { return event }
        onKeyEvent(event)
        return nil
    }
    
    private func startMonitoring() {
        stopMonitoring()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
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
