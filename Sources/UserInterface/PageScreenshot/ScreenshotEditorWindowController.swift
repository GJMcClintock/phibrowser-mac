// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns one independent screenshot editor. No browser or Chromium state enters this window.
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

    init(canvas: CGImage, fileName: String) {
        model = ScreenshotEditorModel(canvas: canvas)
        self.fileName = fileName
        let window = ScreenshotEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                            backing: .buffered, defer: false)
        window.title = NSLocalizedString("browser.screenshot.editorTitle", value: "Edit Screenshot",
                                         comment: "Screenshot editor - Window title")
        window.contentMinSize = NSSize(width: 850, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.editor = self
        window.contentViewController = NSHostingController(rootView: ScreenshotEditorView(model: model, undo: { [weak window] in window?.replayUndo(redo: false) }, redo: { [weak window] in window?.replayUndo(redo: true) }, export: { [weak self] format in
            self?.export(format: format)
        }))
        model.onChange = { [weak self] in
            guard let self else { return }
            self.window?.isDocumentEdited = self.model.generation != self.savedGeneration
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        retainedWhileOpen = self
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
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
        model.prepareForCommand = nil
        model.onChange = nil
        window?.contentViewController = nil
        retainedWhileOpen = nil
    }

    func export(format: ScreenshotExportFormat) {
        guard !isExporting, !isReviewingTermination, let window, window.attachedSheet == nil else { return }
        _ = model.snapshot() // Commit active text before the save panel takes focus.
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .jpg ? .jpeg : .pdf]
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
final class ScreenshotEditorWindow: NSWindow {
    weak var editor: ScreenshotEditorWindowController?

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
        if flags == [.command] || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" {
            replayUndo(redo: flags.contains(.shift))
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

@MainActor
private struct ScreenshotEditorView: View {
    @Bindable var model: ScreenshotEditorModel
    let undo: () -> Void
    let redo: () -> Void
    let export: (ScreenshotExportFormat) -> Void
    @State private var format = ScreenshotExportFormat.jpg

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                toolButton(.select, title: NSLocalizedString("browser.screenshot.select", value: "Select", comment: "Screenshot editor - Select and move annotations"), symbol: "cursorarrow")
                toolButton(.crop, title: NSLocalizedString("browser.screenshot.crop", value: "Crop", comment: "Screenshot editor - Crop the image to the selected rectangular region"), symbol: "lasso")
                toolButton(.arrow, title: NSLocalizedString("browser.screenshot.arrow", value: "Arrow", comment: "Screenshot editor - Arrow drawing tool"), symbol: "arrow.up.right")
                toolButton(.freehand, title: NSLocalizedString("browser.screenshot.freehand", value: "Freehand", comment: "Screenshot editor - Freehand drawing tool"), symbol: "pencil.tip")
                toolButton(.text, title: NSLocalizedString("browser.screenshot.text", value: "Text", comment: "Screenshot editor - Text annotation tool"), symbol: "textformat")
                toolButton(.rectangle, title: NSLocalizedString("browser.screenshot.rectangle", value: "Rectangle", comment: "Screenshot editor - Rectangle annotation tool"), symbol: "rectangle")
                toolButton(.ellipse, title: NSLocalizedString("browser.screenshot.ellipse", value: "Ellipse", comment: "Screenshot editor - Ellipse annotation tool"), symbol: "circle")
                Divider().frame(height: 22)
                ColorPicker(NSLocalizedString("browser.screenshot.color", value: "Color", comment: "Screenshot editor - Annotation color control"), selection: Binding(get: {
                    Color(.sRGB, red: model.foreground.red, green: model.foreground.green, blue: model.foreground.blue, opacity: model.foreground.alpha)
                }, set: { color in
                    if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                        model.foreground = ScreenshotColor(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
                    }
                })).labelsHidden().frame(width: 28)
                Picker(NSLocalizedString("browser.screenshot.width", value: "Width", comment: "Screenshot editor - Stroke width in source image pixels"), selection: $model.brushSize) {
                    ForEach(Array(Set([model.brushSize] + [CGFloat(model.width) / 1000 * 2.5, 2.5, 4, 8, 16, 32])).sorted(), id: \.self) { size in Text(verbatim: String(format: "%.1f px", Double(size))).tag(size) }
                }.labelsHidden().frame(width: 85)
                Picker(NSLocalizedString("browser.screenshot.textSize", value: "Text Size", comment: "Screenshot editor - Text size in source image pixels"), selection: $model.textSize) {
                    ForEach(Array(Set([Double(model.textSize), 15.0, 24.0, 44.0, 60.0, 80.0])).sorted(), id: \.self) { size in Text(verbatim: "\(Int(size)) px").tag(CGFloat(size)) }
                }.labelsHidden().frame(width: 85)
                Toggle(NSLocalizedString("browser.screenshot.fill", value: "Fill", comment: "Screenshot editor - Fill rectangle or ellipse with the annotation color"), isOn: $model.filled)
                    .toggleStyle(.checkbox)
                Spacer(minLength: 4)
                Picker(NSLocalizedString("browser.screenshot.format", value: "Format", comment: "Screenshot editor - Export file format"), selection: $format) {
                    Text(verbatim: "JPG").tag(ScreenshotExportFormat.jpg)
                    Text(verbatim: "PDF").tag(ScreenshotExportFormat.pdf)
                }.labelsHidden().frame(width: 65)
                Button(NSLocalizedString("browser.screenshot.export", value: "Export…", comment: "Screenshot editor - Save the edited image to a file")) { export(format) }
            }.padding(10)
            HStack(spacing: 12) {
                iconButton(NSLocalizedString("browser.screenshot.undo", value: "Undo", comment: "Screenshot editor - Undo the last edit"), symbol: "arrow.uturn.backward", action: undo).disabled(model.isEditingText ? !model.textCanUndo : !model.canUndo)
                iconButton(NSLocalizedString("browser.screenshot.redo", value: "Redo", comment: "Screenshot editor - Redo the last undone edit"), symbol: "arrow.uturn.forward", action: redo).disabled(model.isEditingText ? !model.textCanRedo : !model.canRedo)
                Button(NSLocalizedString("browser.screenshot.duplicate", value: "Duplicate", comment: "Screenshot editor - Duplicate selected annotation"), action: model.duplicateSelection).disabled(!model.hasSelection)
                Button(NSLocalizedString("browser.screenshot.delete", value: "Delete", comment: "Screenshot editor - Delete selected annotation"), action: model.deleteSelection).disabled(!model.hasSelection)
                Button(NSLocalizedString("browser.screenshot.bringToFront", value: "Bring to Front", comment: "Screenshot editor - Move selected annotation above others")) { model.reorderSelection(front: true) }.disabled(!model.hasSelection)
                Button(NSLocalizedString("browser.screenshot.sendToBack", value: "Send to Back", comment: "Screenshot editor - Move selected annotation below others")) { model.reorderSelection(front: false) }.disabled(!model.hasSelection)
                Spacer()
            }.padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            ScreenshotCanvasScrollView(model: model)
            Divider()
            HStack {
                Text(verbatim: "\(model.width) × \(model.height) px")
                Spacer()
                iconButton(NSLocalizedString("browser.screenshot.zoomOut", value: "Zoom Out", comment: "Screenshot editor - Reduce preview magnification"), symbol: "minus.magnifyingglass") { model.zoomBy(0.8) }
                Text(verbatim: "\(Int((model.zoom * 100).rounded()))%")
                iconButton(NSLocalizedString("browser.screenshot.zoomIn", value: "Zoom In", comment: "Screenshot editor - Increase preview magnification"), symbol: "plus.magnifyingglass") { model.zoomBy(1.25) }
                Button(NSLocalizedString("browser.screenshot.fit", value: "Fit", comment: "Screenshot editor - Fit the complete screenshot in the window"), action: model.fit)
                Button(NSLocalizedString("browser.screenshot.actualSize", value: "100%", comment: "Screenshot editor - Show one source image pixel per preview point")) { model.zoomBy(1 / model.zoom) }
            }.font(.system(size: 12)).padding(8)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func toolButton(_ tool: ScreenshotTool, title: String, symbol: String) -> some View {
        Button { model.selectTool(tool) } label: {
            Image(systemName: symbol).frame(width: 24, height: 24).padding(6)
                .background(model.tool == tool ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.tool == tool ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .accessibilityAddTraits(model.tool == tool ? [.isSelected] : [])
    }
    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.help(title).accessibilityLabel(title)
    }
}
