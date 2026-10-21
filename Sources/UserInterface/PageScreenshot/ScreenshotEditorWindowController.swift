// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns one image document, presented over its browser or in the standalone fixture.
@MainActor
final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    let model: ScreenshotEditorModel
    private let fileName: String
    private var retainedWhileOpen: ScreenshotEditorWindowController?
    private var savedGeneration = 0
    private var isExporting = false
    private var exportTask: Task<Void, Never>?
    fileprivate var isReviewingTermination = false
    private var allowsDiscard = false
    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private var parentObservers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private let host: NSHostingController<ScreenshotCanvasScrollView>

    init(canvas: CGImage, fileName: String, parent: NSWindow? = nil) {
        model = ScreenshotEditorModel(canvas: canvas)
        self.fileName = fileName
        self.parent = parent
        host = NSHostingController(rootView: ScreenshotCanvasScrollView(model: model))
        let window = ScreenshotEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                            backing: .buffered, defer: false)
        window.title = NSLocalizedString("browser.screenshot.editorTitle", value: "Edit Screenshot",
                                         comment: "Screenshot editor - Window title")
        window.contentMinSize = NSSize(width: 850, height: 400)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.editor = self
        host.rootView = ScreenshotCanvasScrollView(model: model, export: { [weak self] format in
            self?.export(format: format)
        })
        host.sizingOptions = []
        model.onChange = { [weak self] in
            guard let self else { return }
            self.window?.isDocumentEdited = self.model.generation != self.savedGeneration
        }
        if let parent {
            configureOverlay(in: parent, window: window)
        } else {
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1100, height: 780))
            window.center()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }
        guard (window as? ScreenshotEditorWindow)?.isOverlay != true || parent != nil else { return }
        if let parent {
            guard parent.isVisible, !parent.isMiniaturized else { return }
            if window.parent == nil {
                previousResponder = parent.firstResponder
                layoutOverlay()
                announceVisibility(true, in: parent)
                parent.addChildWindow(window, ordered: .above)
            }
        }
        retainedWhileOpen = self
        super.showWindow(sender)
        window.makeKeyAndOrderFront(sender)
        if let canvas = (window as? ScreenshotEditorWindow)?.canvasResponder {
            window.makeFirstResponder(canvas)
        }
    }

    private func configureOverlay(in parent: NSWindow, window: ScreenshotEditorWindow) {
        window.isOverlay = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.contentMinSize = .zero
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.appearance = parent.appearance
        appearanceObservation = parent.observe(\.appearance, options: [.new]) { [weak window] parent, _ in
            MainActor.assumeIsolated { window?.appearance = parent.appearance }
        }
        let container = NSViewController()
        let overlay = ScreenshotEditorOverlayView(card: host.view)
        overlay.dismiss = { [weak window] in window?.performClose(nil) }
        container.view = overlay
        container.addChild(host)
        window.contentViewController = container
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            parentObservers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutOverlay() }
            })
        }
        if let content = parent.contentView {
            content.postsFrameChangedNotifications = true
            parentObservers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutOverlay() }
            })
        }
        parentObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.parentWillClose() }
        })
        layoutOverlay()
    }

    private func layoutOverlay() {
        guard let parent, let content = parent.contentView, let window else { return }
        let rounded = parent.styleMask.contains(.titled) && !parent.styleMask.contains(.fullScreen)
        let style: NSWindow.StyleMask = rounded ? [.titled, .fullSizeContentView] : [.borderless, .fullSizeContentView]
        if window.styleMask != style { window.styleMask = style }
        window.setFrame(parent.convertToScreen(content.convert(content.bounds, to: nil)), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func stopObservingParent() {
        parentObservers.forEach(NotificationCenter.default.removeObserver)
        parentObservers.removeAll()
        appearanceObservation = nil
    }

    private func announceVisibility(_ visible: Bool, in parent: NSWindow) {
        NotificationCenter.default.post(name: .phiInWindowOverlayVisibilityChanged, object: parent,
                                        userInfo: ["surface": "screenshotEditor", "visible": visible])
    }

    private func detachOverlay(restoreFocus: Bool) {
        stopObservingParent()
        guard let parent, let window else { return }
        let ownsFocus = window.isKeyWindow
        parent.removeChildWindow(window)
        let anotherEditorIsVisible = parent.childWindows?.contains { ($0 as? ScreenshotEditorWindow)?.isOverlay == true } == true
        if !anotherEditorIsVisible { announceVisibility(false, in: parent) }
        if restoreFocus, ownsFocus {
            parent.makeKey()
            parent.makeFirstResponder(previousResponder)
        }
        previousResponder = nil
        self.parent = nil
    }

    private func parentWillClose() {
        _ = model.snapshot()
        guard requiresTerminationReview, let window = window as? ScreenshotEditorWindow else {
            detachOverlay(restoreFocus: false)
            close()
            return
        }
        // Browser teardown cannot be vetoed from willClose. Keep unsaved work and
        // confirmed exports available using the existing standalone presentation.
        detachOverlay(restoreFocus: false)
        host.removeFromParent()
        host.view.removeFromSuperview()
        host.view.layer?.cornerRadius = 0
        window.isOverlay = false
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.isMovable = true
        window.contentMinSize = NSSize(width: 850, height: 400)
        window.collectionBehavior = []
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
    }

    deinit {
        parentObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var hasConfirmedExport: Bool { isExporting }

    func waitForConfirmedExport() async {
        if let exportTask { await exportTask.value }
    }

    var requiresTerminationReview: Bool {
        isExporting || model.generation != savedGeneration || window?.attachedSheet != nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isExporting, !isReviewingTermination, sender.attachedSheet == nil else { return false }
        _ = model.snapshot()
        guard !allowsDiscard, model.generation != savedGeneration else { return true }
        isReviewingTermination = true
        Task { @MainActor [self] in
            let approved = await confirmDiscardChanges()
            isReviewingTermination = false
            guard approved else { return }
            allowsDiscard = true
            close()
        }
        return false
    }

    /// Wait for a confirmed write, then review the current document rather than its exported snapshot.
    func prepareForTermination(confirmDiscard: () async -> Bool) async -> Bool {
        await waitForConfirmedExport()
        guard let window, window.attachedSheet == nil else { return false }
        _ = model.snapshot()
        if model.generation == savedGeneration { return true }
        return await confirmDiscard()
    }

    /// End the reviewed document before browser prompts can allow new unapproved edits.
    func closeAfterApprovedTermination(generation: Int) -> Bool {
        guard model.generation == generation, !isExporting else { return false }
        window?.close()
        return true
    }

    fileprivate func confirmDiscardChanges() async -> Bool {
        guard let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("browser.screenshot.discardTitle", value: "Close without saving your edits?",
                                              comment: "Screenshot editor - Confirmation before discarding unsaved annotations")
        alert.informativeText = NSLocalizedString("browser.screenshot.discardMessage", value: "Export the screenshot as JPG or PDF to keep your edits.",
                                                  comment: "Screenshot editor - Explanation in the unsaved edits confirmation")
        alert.addButton(withTitle: NSLocalizedString("browser.screenshot.closeWithoutSaving", value: "Close Without Saving",
                                                     comment: "Screenshot editor - Discard edits and close the window"))
        alert.addButton(withTitle: NSLocalizedString("browser.screenshot.keepEditing", value: "Keep Editing",
                                                     comment: "Screenshot editor - Cancel closing to continue editing or export"))
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
    func windowWillClose(_ notification: Notification) {
        detachOverlay(restoreFocus: !isReviewingTermination)
        model.prepareForCommand = nil
        model.onChange = nil
        window?.contentViewController = nil
        retainedWhileOpen = nil
    }

    func export(format: ScreenshotExportFormat) {
        guard !isExporting, !isReviewingTermination, let window, window.attachedSheet == nil else { return }
        _ = model.snapshot() // Commit active text before the save panel takes focus.
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = (fileName as NSString).deletingPathExtension + "." + format.rawValue
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.completeExportSelection(response: response, url: panel.url, format: format)
        }
    }

    func completeExportSelection(response: NSApplication.ModalResponse, url: URL?, format: ScreenshotExportFormat) {
        guard response == .OK, let url else { return }
        writeSnapshot(model.snapshot(), format: format, to: url)
    }

    /// The save sheet and termination review share this image-scoped write lifecycle.
    func writeSnapshot(_ snapshot: ScreenshotSnapshot, format: ScreenshotExportFormat, to url: URL,
                       write: @escaping @Sendable (ScreenshotSnapshot, ScreenshotExportFormat, URL) async throws -> Void = { bitmap, format, url in
                           try await Task.detached(priority: .userInitiated) {
                               try ScreenshotImageExport.write(bitmap, format: format, to: url)
                           }.value
                       }) {
        guard !isExporting, !isReviewingTermination, let window else { return }
        let generation = model.generation
        isExporting = true
        exportTask = Task { @MainActor [self] in
            defer { isExporting = false; exportTask = nil }
            do {
                try await write(snapshot, format, url)
                savedGeneration = generation
                window.isDocumentEdited = model.generation != savedGeneration
            } catch {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("browser.screenshot.saveFailed", value: "Could not save the screenshot",
                                                      comment: "Screenshot - Error when writing the selected screenshot file fails")
                alert.informativeText = NSLocalizedString("browser.screenshot.exportRetry", value: "Your edits are still available. Choose another location and try again.",
                                                          comment: "Screenshot editor - Recovery advice after a failed file export")
                alert.beginSheetModal(for: window, completionHandler: { _ in })
                AppLogError("[Screenshot] Edited image export failed: \(error)")
            }
        }
    }
}

/// The full-window scrim owns background input without filtering browser mouse events.
@MainActor
private final class ScreenshotEditorOverlayView: NSView {
    let card: NSView
    var dismiss: (() -> Void)?

    init(card: NSView) {
        self.card = card
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        guard bounds.width > 72, bounds.height > 72 else { return }
        card.frame = bounds.insetBy(dx: 36, dy: 36)
    }
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss?() }
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

@MainActor
extension NSApplication {
    /// Returns whether screenshot windows are handling this quit before Chromium tears down browser windows.
    @objc(reviewScreenshotEditorsForTerminationWithCompletion:)
    func reviewScreenshotEditorsForTermination(completion: @escaping (Bool) -> Void) -> Bool {
        let editors = windows.compactMap { $0.windowController as? ScreenshotEditorWindowController }
        guard !editors.contains(where: { $0.isReviewingTermination }) else { return true }
        editors.forEach { _ = $0.model.snapshot() }
        guard editors.contains(where: { $0.requiresTerminationReview }) else {
            editors.forEach { _ = $0.closeAfterApprovedTermination(generation: $0.model.generation) }
            return false
        }
        editors.forEach { $0.isReviewingTermination = true }
        Task { @MainActor in
            defer { editors.forEach { $0.isReviewingTermination = false } }
            var approvedGenerations: [ObjectIdentifier: Int] = [:]
            for editor in editors {
                guard await editor.prepareForTermination(confirmDiscard: editor.confirmDiscardChanges) else {
                    completion(false)
                    return
                }
                approvedGenerations[ObjectIdentifier(editor)] = editor.model.generation
            }
            // A different editor can change or open while another window's sheet is up.
            let current = self.windows.compactMap { $0.windowController as? ScreenshotEditorWindowController }
            current.forEach { _ = $0.model.snapshot() }
            let approved = current.allSatisfy { editor in
                !editor.requiresTerminationReview || approvedGenerations[ObjectIdentifier(editor)] == editor.model.generation
            }
            guard approved else { completion(false); return }
            // Close every approved image in the same actor turn, before downstream browser prompts.
            // Canceling a later browser prompt cannot expose a reviewed document to new edits.
            for editor in current {
                guard editor.closeAfterApprovedTermination(generation: editor.model.generation) else {
                    completion(false)
                    return
                }
            }
            completion(true)
        }
        return true
    }
}

/// The app's menu uses commandDispatch:, so route editing commands locally through this native window.
@MainActor
final class ScreenshotEditorWindow: NSPanel {
    weak var editor: ScreenshotEditorWindowController?
    var isOverlay = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { !isOverlay }

    override func performClose(_ sender: Any?) {
        guard editor?.windowShouldClose(self) == true else { return }
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        guard isOverlay else { super.cancelOperation(sender); return }
        canvasResponder?.cancelOperation(sender)
    }

    private enum EditingAction { case undo, redo, close, cut, copy, paste, selectAll }
    // These standard editing commands are not exported by the browser command wrapper.
    // Resolve native menu equivalents rather than introducing Chromium constants here.
    private func editingAction(_ item: NSMenuItem) -> EditingAction? {
        let flags = item.keyEquivalentModifierMask.intersection([.command, .shift, .control, .option])
        let key = item.keyEquivalent.lowercased()
        if key == "z", flags == [.command, .shift] { return .redo }
        guard flags == [.command] else { return nil }
        switch key {
        case "z": return .undo
        case "w": return .close
        case "x": return .cut
        case "c": return .copy
        case "v": return .paste
        case "a": return .selectAll
        default: return nil
        }
    }
    var canvasResponder: ScreenshotCanvasView? {
        func find(in view: NSView) -> ScreenshotCanvasView? {
            if let canvas = view as? ScreenshotCanvasView { return canvas }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return contentView.flatMap { find(in: $0) }
    }
    @objc func commandDispatch(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let action = editingAction(item) else { return }
        switch action {
        case .undo: replayUndo(redo: false)
        case .redo: replayUndo(redo: true)
        case .close: performClose(sender)
        case .cut: if let text = firstResponder as? NSTextView { text.cut(sender) } else { canvasResponder?.cut(sender) }
        case .copy: if let text = firstResponder as? NSTextView { text.copy(sender) } else { canvasResponder?.copy(sender) }
        case .paste: if let text = firstResponder as? NSTextView { text.paste(sender) } else { canvasResponder?.paste(sender) }
        case .selectAll: if let text = firstResponder as? NSTextView { text.selectAll(sender) } else { editor?.model.selectAll() }
        }
    }
    @objc func commandDispatchUsingKeyModifiers(_ sender: Any?) { commandDispatch(sender) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(commandDispatch(_:)) || item.action == #selector(commandDispatchUsingKeyModifiers(_:)) else {
            return super.validateUserInterfaceItem(item)
        }
        guard let menuItem = item as? NSMenuItem, let action = editingAction(menuItem) else { return false }
        switch action {
        case .undo: return (firstResponder as? NSTextView)?.undoManager?.canUndo ?? editor?.model.canUndo ?? false
        case .redo: return (firstResponder as? NSTextView)?.undoManager?.canRedo ?? editor?.model.canRedo ?? false
        case .close: return true
        case .cut, .copy: return firstResponder is NSTextView || editor?.model.hasSelection == true
        case .paste: return firstResponder is NSTextView || canvasResponder?.hasPasteableAnnotation == true
        case .selectAll: return firstResponder is NSTextView || editor?.model.annotations.isEmpty == false
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let key = event.charactersIgnoringModifiers ?? ""
        if !(firstResponder is NSTextView), flags == [.command] || flags == [.command, .shift] {
            let delta: CGFloat? = (key == "+" || key == "=") ? 1 : (key == "-" && flags == [.command]) ? -1 : nil
            if let delta, editor?.model.adjustSelectionSize(by: delta) == true {
                canvasResponder?.synchronize()
                return true
            }
        }
        // IMEs can retain local-script characters in charactersIgnoringModifiers.
        // Use the shared layout-aware identity while preserving text undo ownership.
        if let shortcut = ShortcutsKey.eventKeys(for: event)?.canonical,
           shortcut.characters == "z",
           shortcut.modifiers == [.command] || shortcut.modifiers == [.command, .shift] {
            replayUndo(redo: shortcut.modifiers.contains(.shift))
            return true
        }
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    fileprivate func replayUndo(redo: Bool) {
        if let text = canvasResponder?.textEntry ?? firstResponder as? NSTextView, let undo = text.undoManager {
            if redo { undo.redo() } else { undo.undo() }
        } else if redo { editor?.model.redo() } else { editor?.model.undo() }
    }
}
