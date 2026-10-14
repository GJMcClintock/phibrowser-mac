// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit
import QuartzCore

/// Retained layers are independent of the immutable screenshot background.
@MainActor
final class ScreenshotCanvasView: NSView, NSTextViewDelegate, NSMenuDelegate {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { model?.undoManager }
    var model: ScreenshotEditorModel? {
        didSet {
            if oldValue !== model {
                background.contents = model?.source
                rendered.removeAll(); objectLayers.values.forEach { $0.removeFromSuperlayer() }; objectLayers.removeAll()
            }
            synchronize()
        }
    }
    var zoom: Double = 1 { didSet { guard zoom != oldValue else { return }; invalidateCanvasSize(); synchronize(); layoutTextEditor() } }
    private let scene = CALayer()
    private let background = CALayer()
    private let selection = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()
    private let cropShade = CAShapeLayer()
    private let cropGrid = CAShapeLayer()
    private let cropHandles = CAShapeLayer()
    var onPresentationChange: (() -> Void)?
    private(set) var isShowingContextMenu = false
    var isPanningImage: Bool { isPanning || spaceHeld }
    private var objectLayers: [UUID: CALayer] = [:]
    private var rendered: [UUID: ScreenshotAnnotation] = [:]
    private var renderedTextScale = 0.0
    private(set) var textEntry: ScreenshotTextEntryView?
    private var editingID: UUID?
    private var textFrame: CGRect = .zero
    private var textStyle = ScreenshotAnnotationStyle()
    private var autoscrollTimer: Timer?
    private var autoscrollEvent: NSEvent?
    private var isPanning = false
    private var spaceHeld = false
    private var lastPan: CGPoint = .zero
    private var previousPanCursor: NSCursor?
    private var observers: [NSObjectProtocol] = []
    private var textHistoryObservers: [NSObjectProtocol] = []
    private(set) var objectLayerUpdateCount = 0
    var backgroundImage: CGImage? { background.contents.map { $0 as! CGImage } }
    var annotationPasteboard = NSPasteboard.general
    var hasPasteableAnnotation: Bool { annotationPasteboard.data(forType: Self.annotationPasteboardType) != nil }
    static let annotationPasteboardType = NSPasteboard.PasteboardType("com.phibrowser.screenshot.annotation")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        scene.anchorPoint = .zero
        scene.masksToBounds = true
        layer?.addSublayer(scene)
        background.anchorPoint = .zero
        background.contentsGravity = .resize
        background.minificationFilter = .trilinear
        scene.addSublayer(background)
        selection.fillColor = nil
        selection.strokeColor = NSColor.controlAccentColor.cgColor
        selection.lineWidth = 1
        cropShade.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        cropShade.fillRule = .evenOdd
        layer?.addSublayer(cropShade)
        layer?.addSublayer(selection)
        marqueeLayer.strokeColor = NSColor.controlAccentColor.cgColor
        marqueeLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        marqueeLayer.lineWidth = 1
        layer?.addSublayer(marqueeLayer)
        cropGrid.strokeColor = NSColor.white.withAlphaComponent(0.4).cgColor
        cropGrid.fillColor = nil; cropGrid.lineWidth = 0.5
        cropHandles.fillColor = NSColor.white.cgColor
        cropHandles.strokeColor = NSColor.black.withAlphaComponent(0.3).cgColor
        layer?.addSublayer(cropGrid); layer?.addSublayer(cropHandles)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { autoscrollTimer?.invalidate(); (observers + textHistoryObservers).forEach { NotificationCenter.default.removeObserver($0) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        guard let window else { finishInterruptedInput(); return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishInterruptedInput() }
            })
        }
        model?.prepareForCommand = { [weak self] in self?.prepareForCommand() }
        if let clip = enclosingScrollView?.contentView {
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCropOverlay() }
            })
        }
    }
    func sourcePoint(from viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / zoom, y: viewPoint.y / zoom)
    }
    func invalidateCanvasSize() {
        guard let model else { return }
        let size = CGSize(width: Double(model.width) * zoom, height: Double(model.height) * zoom)
        if frame.size != size { setFrameSize(size) }
    }
    func repaintIfChanged(revision: Int) { synchronize() }
    func synchronize() {
        guard let model else { return }
        invalidateCanvasSize()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if backgroundImage !== model.source { background.contents = model.source }
        scene.bounds = CGRect(x: 0, y: 0, width: model.width, height: model.height)
        scene.position = .zero
        scene.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
        background.frame = scene.bounds
        let ids = Set(model.annotations.map(\.id))
        for id in Array(objectLayers.keys) where !ids.contains(id) {
            objectLayers.removeValue(forKey: id)?.removeFromSuperlayer(); rendered.removeValue(forKey: id)
        }
        let textScale = min(2, zoom * (window?.backingScaleFactor ?? 2))
        let textScaleChanged = renderedTextScale != textScale
        renderedTextScale = textScale
        for (index, annotation) in model.annotations.enumerated() {
            let item = objectLayers[annotation.id] ?? makeObjectLayer(annotation)
            item.zPosition = CGFloat(index + 1)
            item.isHidden = editingID == annotation.id
            item.contentsScale = max(0.02, zoom * (window?.backingScaleFactor ?? 2))
            item.sublayers?.forEach { $0.contentsScale = item.contentsScale }
            if rendered[annotation.id] != annotation || (annotation.kind == .text && textScaleChanged) {
                update(item, annotation: annotation); rendered[annotation.id] = annotation
                objectLayerUpdateCount += 1
            }
        }
        updateSelection()
        updateCropOverlay()
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
        onPresentationChange?()
    }
    private func makeObjectLayer(_ annotation: ScreenshotAnnotation) -> CALayer {
        let item: CALayer = annotation.kind == .text ? CALayer() : CAShapeLayer()
        item.anchorPoint = .zero
        scene.addSublayer(item); objectLayers[annotation.id] = item
        if annotation.kind == .arrow { item.addSublayer(CAShapeLayer()) }
        return item
    }
    private func update(_ item: CALayer, annotation: ScreenshotAnnotation) {
        if let shape = item as? CAShapeLayer {
            // Layers use source coordinates; the scene transform alone controls magnification.
            let padding = max(annotation.style.width * 2, annotation.style.arrowHeadLength, 16)
            let rect = annotation.bounds.insetBy(dx: -padding, dy: -padding)
            shape.frame = rect
            var transform = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            shape.path = annotation.path.copy(using: &transform)
            shape.strokeColor = annotation.style.color.cgColor
            shape.fillColor = annotation.style.filled && [.rectangle, .ellipse].contains(annotation.kind) ? annotation.style.color.nsColor.withAlphaComponent(0.8 * annotation.style.color.alpha).cgColor : nil
            shape.lineWidth = annotation.style.width; shape.lineCap = .round; shape.lineJoin = .round
            if let head = shape.sublayers?.first as? CAShapeLayer {
                head.frame = shape.bounds; head.path = annotation.arrowHead?.copy(using: &transform)
                head.fillColor = nil; head.strokeColor = annotation.style.color.cgColor
                head.lineWidth = annotation.style.width; head.lineCap = .round; head.lineJoin = .round
                head.contentsScale = max(0.02, zoom * (window?.backingScaleFactor ?? 2))
            }
        } else {
            item.frame = annotation.frame
            // Rasterize only this text object using the same CoreText layout as export.
            let requestedScale = max(0.02, renderedTextScale)
            let width = max(1, annotation.frame.width), height = max(1, annotation.frame.height)
            // Large text boxes remain visible at 100% without a source-sized preview allocation.
            // This affects only preview sharpness; export always lays out the source-size text.
            let scale = min(requestedScale, 8192 / width, 8192 / height, sqrt(4_000_000 / (width * height)))
            let w = max(1, Int(ceil(annotation.frame.width * scale))), h = max(1, Int(ceil(annotation.frame.height * scale)))
            if let context = ScreenshotSceneRenderer.bitmapContext(width: w, height: h) {
                context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: 1, y: -1)
                context.scaleBy(x: scale, y: scale)
                var local = annotation; local.frame = CGRect(origin: .zero, size: annotation.frame.size)
                ScreenshotSceneRenderer.draw(local, in: context)
                item.contents = context.makeImage()
            }
        }
        item.contentsScale = max(0.02, zoom * (window?.backingScaleFactor ?? 2))
    }
    private func updateSelection() {
        let path = CGMutablePath(), transform = CGAffineTransform(scaleX: zoom, y: zoom)
        if let model, textEntry == nil, model.tool == .select {
            for annotation in model.annotations where model.displayedSelection.contains(annotation.id) {
                if annotation.kind != .arrow { path.addRect(annotation.bounds.applying(transform)) }
            }
            if model.marquee == nil {
                if model.selectedIDs.count > 1, let bounds = model.selectionBounds { path.addRect(bounds.applying(transform)) }
                for (_, point) in model.selectionHandles {
                    path.addRect(CGRect(x: point.x * zoom - 3, y: point.y * zoom - 3, width: 6, height: 6))
                }
            }
        }
        selection.frame = bounds; selection.path = path
        marqueeLayer.frame = bounds
        let rect = model?.tool == .crop ? model?.cropRect : model?.marquee
        marqueeLayer.path = rect.map { CGPath(rect: $0.applying(transform), transform: nil) }
        marqueeLayer.fillColor = model?.tool == .crop ? nil : NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        marqueeLayer.lineDashPattern = nil
        marqueeLayer.strokeColor = model?.tool == .crop ? NSColor.white.cgColor : NSColor.controlAccentColor.cgColor
    }
    private func updateCropOverlay() {
        guard let model, model.tool == .crop, let cropRect = model.cropRect else {
            cropShade.path = nil; cropGrid.path = nil; cropHandles.path = nil; return
        }
        let rect = cropRect.applying(CGAffineTransform(scaleX: zoom, y: zoom))
        let shade = CGMutablePath(); shade.addRect(bounds); shade.addRect(rect)
        cropShade.frame = bounds; cropShade.path = shade
        let grid = CGMutablePath()
        for fraction: CGFloat in [1 / 3, 2 / 3] {
            grid.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            grid.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            grid.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            grid.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        cropGrid.frame = bounds; cropGrid.path = grid
        let handles = CGMutablePath()
        for (_, point) in model.cropHandles {
            handles.addRect(CGRect(x: point.x * zoom - 4, y: point.y * zoom - 4, width: 8, height: 8))
        }
        cropHandles.frame = bounds; cropHandles.path = handles
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, model.tool != .crop else { return nil }
        prepareForCommand()
        let point = sourcePoint(from: convert(event.locationInWindow, from: nil))
        guard let object = model.hitTest(point, tolerance: 15 / max(zoom, 0.02)) else {
            model.select(nil); synchronize(); return nil
        }
        model.selectTool(.select)
        if !model.selectedIDs.contains(object.id) { model.select(object.id) }
        synchronize()
        let menu = NSMenu(); menu.delegate = self
        let front = NSMenuItem(title: NSLocalizedString("browser.screenshot.bringToFront", value: "Bring to Front", comment: "Screenshot editor - Move selected annotation above others"), action: #selector(bringSelectionToFront(_:)), keyEquivalent: "")
        let back = NSMenuItem(title: NSLocalizedString("browser.screenshot.sendToBack", value: "Send to Back", comment: "Screenshot editor - Move selected annotation below others"), action: #selector(sendSelectionToBack(_:)), keyEquivalent: "")
        let duplicate = NSMenuItem(title: NSLocalizedString("browser.screenshot.duplicate", value: "Duplicate", comment: "Screenshot editor - Duplicate selected annotation"), action: #selector(duplicateAnnotation(_:)), keyEquivalent: "d")
        let delete = NSMenuItem(title: NSLocalizedString("browser.screenshot.delete", value: "Delete", comment: "Screenshot editor - Delete selected annotation"), action: #selector(deleteAnnotation(_:)), keyEquivalent: "\u{8}")
        delete.keyEquivalentModifierMask = []
        for item in [front, back, NSMenuItem.separator(), duplicate, delete] { item.target = self; menu.addItem(item) }
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { isShowingContextMenu = true; onPresentationChange?() }
    func menuDidClose(_ menu: NSMenu) { isShowingContextMenu = false; onPresentationChange?() }
    @objc private func bringSelectionToFront(_ sender: Any?) { model?.reorderSelection(front: true); synchronize() }
    @objc private func sendSelectionToBack(_ sender: Any?) { model?.reorderSelection(front: false); synchronize() }
    @objc private func duplicateAnnotation(_ sender: Any?) { model?.duplicateSelection(); synchronize() }
    @objc private func deleteAnnotation(_ sender: Any?) { model?.deleteSelection(); synchronize() }
    private var handleTolerance: CGFloat { 7 / max(zoom, 0.02) }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: spaceHeld ? .openHand : model?.tool == .text ? .iBeam : model?.tool == .select ? .arrow : .crosshair)
        if let model, model.tool == .select || model.tool == .crop {
            for (handle, point) in model.tool == .crop ? model.cropHandles : model.selectionHandles {
                let cursor: NSCursor = [.top, .bottom].contains(handle) ? .resizeUpDown : [.left, .right].contains(handle) ? .resizeLeftRight : .crosshair
                addCursorRect(CGRect(x: point.x * zoom - 7, y: point.y * zoom - 7, width: 14, height: 14), cursor: cursor)
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        stopAutoscroll()
        commitText()
        window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        if spaceHeld {
            isPanning = true; lastPan = event.locationInWindow; previousPanCursor = NSCursor.current; NSCursor.closedHand.set(); onPresentationChange?(); return
        }
        let point = sourcePoint(from: local)
        if model.tool == .select, event.clickCount == 2, let object = model.hitTest(point, tolerance: 15 / max(zoom, 0.02)), object.kind == .text {
            model.select(object.id); beginText(at: point, object: object); return
        }
        if model.tool == .text { beginText(at: point); return }
        model.beginInteraction(at: point, tolerance: handleTolerance, modifiers: event.modifierFlags)
        synchronize()
    }
    override func mouseDragged(with event: NSEvent) {
        if isPanning, let clip = enclosingScrollView?.contentView {
            let point = event.locationInWindow
            clip.scroll(to: CGPoint(x: clip.bounds.minX + lastPan.x - point.x, y: clip.bounds.minY + point.y - lastPan.y))
            enclosingScrollView?.reflectScrolledClipView(clip); lastPan = point; return
        }
        guard model?.isInteracting == true else { return }
        autoscrollEvent = event
        autoscroll(with: event)
        updatePointerPreview(with: event)
        if autoscrollTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.continueAutoscroll() }
            }
            autoscrollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func updatePointerPreview(with event: NSEvent) {
        model?.continueInteraction(at: sourcePoint(from: convert(event.locationInWindow, from: nil)), mirrored: event.modifierFlags.contains(.option), modifiers: event.modifierFlags)
        synchronize()
    }
    private func continueAutoscroll() {
        guard model?.isInteracting == true, window != nil, let event = autoscrollEvent else { stopAutoscroll(); return }
        if autoscroll(with: event) { updatePointerPreview(with: event) }
    }
    private func stopAutoscroll() {
        autoscrollTimer?.invalidate(); autoscrollTimer = nil; autoscrollEvent = nil
    }
    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        if isPanning { endPan(); window?.invalidateCursorRects(for: self); onPresentationChange?(); return }
        if model?.isInteracting == true {
            model?.continueInteraction(at: sourcePoint(from: convert(event.locationInWindow, from: nil)), mirrored: event.modifierFlags.contains(.option), modifiers: event.modifierFlags)
            model?.endInteraction(); synchronize()
        }
    }
    override func cancelOperation(_ sender: Any?) {
        if textEntry != nil { cancelText() }
        else if model?.isInteracting == true { model?.cancelInteraction() }
        else { model?.selectTool(.select); model?.select(nil) }
        model?.selectTool(.select)
        finishPointerInput(); synchronize()
    }
    private func endPan() {
        isPanning = false
        previousPanCursor?.set(); previousPanCursor = nil
    }
    private func finishPointerInput() {
        stopAutoscroll()
        model?.cancelInteraction(); endPan(); spaceHeld = false
    }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        // A same-window control can receive the Space key-up instead of this canvas.
        // Leave native text focus transitions to NSTextView's own editing delegate.
        finishPointerInput(); synchronize()
        return true
    }
    func prepareForCommand() { commitText(); finishPointerInput(); synchronize() }
    func finishInterruptedInput() { prepareForCommand() }
    override func keyDown(with event: NSEvent) {
        guard let model else { return }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 { cancelOperation(nil); return }
        if event.keyCode == 49, flags.isEmpty { spaceHeld = true; window?.invalidateCursorRects(for: self); onPresentationChange?(); return }
        if [36, 76].contains(event.keyCode), flags.isEmpty, model.tool == .crop { model.cropToSelection(); synchronize(); return }
        if flags == [.command], key == "a" { model.selectAll(); synchronize(); return }
        if flags == [.command], key == "d" { model.duplicateSelection(); synchronize(); return }
        if event.keyCode == 51 || event.keyCode == 117 { model.deleteSelection(); synchronize(); return }
        if [123, 124, 125, 126].contains(event.keyCode) {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let delta = CGPoint(x: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                y: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
            model.moveSelection(by: delta); synchronize(); return
        }
        if flags.isEmpty, let tool = ["v": ScreenshotTool.select, "c": .crop, "a": .arrow, "p": .freehand, "t": .text, "r": .rectangle, "o": .ellipse][key] {
            model.selectTool(tool); synchronize(); return
        }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false; endPan(); window?.invalidateCursorRects(for: self); onPresentationChange?() }
        else { super.keyUp(with: event) }
    }
    private func copyAnnotation() -> Bool {
        guard let objects = model?.selectedObjects, !objects.isEmpty, objects.allSatisfy(validForPaste),
              let data = try? JSONEncoder().encode(objects), data.count <= 1_000_000 else { return false }
        annotationPasteboard.clearContents()
        return annotationPasteboard.setData(data, forType: Self.annotationPasteboardType)
    }
    @objc func copy(_ sender: Any?) { if !copyAnnotation() { NSSound.beep() } }
    @objc func cut(_ sender: Any?) {
        guard copyAnnotation() else { NSSound.beep(); return }
        model?.deleteSelection(); synchronize()
    }
    @objc func paste(_ sender: Any?) {
        guard let data = annotationPasteboard.data(forType: Self.annotationPasteboardType), data.count <= 1_000_000 else { return }
        let decoder = JSONDecoder()
        let objects = (try? decoder.decode([ScreenshotAnnotation].self, from: data)) ??
            (try? decoder.decode(ScreenshotAnnotation.self, from: data)).map { [$0] } ?? []
        guard !objects.isEmpty, objects.count <= 1000, objects.allSatisfy(validForPaste) else { return }
        model?.paste(objects); synchronize()
    }
    private func validForPaste(_ object: ScreenshotAnnotation) -> Bool {
        let values = [object.frame.minX, object.frame.minY, object.frame.width, object.frame.height, object.style.width, object.style.fontSize]
        return values.allSatisfy { $0.isFinite && abs($0) <= 32768 } && object.frame.width >= 0 && object.frame.height >= 0 &&
            object.style.arrowHeadLength.isFinite && object.style.arrowHeadLength >= 0 && object.style.arrowHeadLength <= 32768 &&
            object.style.width > 0 && object.style.width <= 1000 && object.style.fontSize > 0 && object.style.fontSize <= 1000 &&
            object.points.count <= 100_000 && object.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 32768 && abs($0.y) <= 32768 } &&
            (object.kind != .arrow || object.points.count == 2) && (object.kind != .freehand || !object.points.isEmpty) && object.text.utf8.count <= 100_000 &&
            [object.style.color.red, object.style.color.green, object.style.color.blue, object.style.color.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    func zoomFromGesture(by factor: Double, atWindowPoint point: CGPoint) {
        guard factor > 0, let model, let clip = enclosingScrollView?.contentView else { return }
        let oldPoint = convert(point, from: nil), source = sourcePoint(from: oldPoint)
        let offset = CGPoint(x: oldPoint.x - clip.bounds.minX, y: oldPoint.y - clip.bounds.minY)
        model.zoomBy(factor); zoom = model.zoom
        clip.scroll(to: CGPoint(x: source.x * zoom - offset.x, y: source.y * zoom - offset.y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    func beginText(at input: CGPoint, object: ScreenshotAnnotation? = nil) {
        guard let model else { return }
        commitText(); model.cancelInteraction()
        model.isEditingText = true
        editingID = object?.id
        textStyle = object?.style ?? model.style
        let origin = CGPoint(x: max(0, min(CGFloat(model.width) - 12, input.x)), y: max(0, min(CGFloat(model.height) - 12, input.y)))
        textFrame = object?.frame ?? CGRect(origin: origin, size: CGSize(width: min(280, CGFloat(model.width) - origin.x), height: min(40, CGFloat(model.height) - origin.y)))
        let entry = ScreenshotTextEntryView(frame: .zero)
        entry.isRichText = false; entry.isAutomaticQuoteSubstitutionEnabled = false
        entry.isAutomaticDashSubstitutionEnabled = false; entry.allowsUndo = true
        entry.drawsBackground = true; entry.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9)
        entry.textContainerInset = CGSize(width: 4 * zoom, height: 4 * zoom)
        entry.textContainer?.lineFragmentPadding = 0
        entry.textContainer?.widthTracksTextView = true
        entry.isVerticallyResizable = false
        entry.font = .systemFont(ofSize: textStyle.fontSize * zoom)
        entry.textColor = textStyle.color.nsColor
        entry.string = object?.text ?? ""
        entry.undoManager?.removeAllActions()
        entry.delegate = self
        entry.onCancel = { [weak self] in self?.cancelText() }
        entry.onCommit = { [weak self] in self?.commitText(); self?.window?.makeFirstResponder(self) }
        textEntry = entry
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, NSNotification.Name.NSUndoManagerDidRedoChange, NSNotification.Name.NSUndoManagerDidCloseUndoGroup] {
            textHistoryObservers.append(NotificationCenter.default.addObserver(forName: name, object: entry.undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTextHistory() }
            })
        }
        refreshTextHistory(); addSubview(entry); layoutTextEditor(); synchronize()
        window?.makeFirstResponder(entry)
    }
    private func layoutTextEditor() {
        textEntry?.font = .systemFont(ofSize: textStyle.fontSize * zoom)
        textEntry?.textContainerInset = CGSize(width: 4 * zoom, height: 4 * zoom)
        textEntry?.frame = textFrame.applying(CGAffineTransform(scaleX: zoom, y: zoom))
        textEntry?.textContainer?.containerSize = CGSize(width: max(1, textFrame.width * zoom - 8 * zoom), height: .greatestFiniteMagnitude)
    }
    func refreshTextHistory() {
        model?.textCanUndo = textEntry?.undoManager?.canUndo ?? false
        model?.textCanRedo = textEntry?.undoManager?.canRedo ?? false
    }
    private func detachTextHistory() {
        textHistoryObservers.forEach { NotificationCenter.default.removeObserver($0) }; textHistoryObservers.removeAll()
        model?.textCanUndo = false; model?.textCanRedo = false
    }
    func textDidChange(_ notification: Notification) {
        refreshTextHistory()
        guard let entry = textEntry, let manager = entry.layoutManager, let container = entry.textContainer, let model else { return }
        manager.ensureLayout(for: container)
        let needed = manager.usedRect(for: container).height / zoom + 8
        textFrame.size.height = min(CGFloat(model.height) - textFrame.minY, max(textStyle.fontSize + 8, needed))
        layoutTextEditor()
    }
    func textDidEndEditing(_ notification: Notification) { commitText() }
    func commitText() {
        guard let entry = textEntry else { return }
        let text = entry.string, id = editingID, frame = textFrame
        detachTextHistory()
        model?.isEditingText = false
        textEntry = nil; editingID = nil
        let wasFirstResponder = window?.firstResponder === entry
        entry.delegate = nil; entry.removeFromSuperview()
        if wasFirstResponder { window?.makeFirstResponder(self) }
        model?.commitText(text, frame: frame, id: id); synchronize()
    }
    func cancelText() {
        guard let entry = textEntry else { return }
        detachTextHistory()
        model?.isEditingText = false
        textEntry = nil; editingID = nil; entry.delegate = nil; entry.removeFromSuperview()
        window?.makeFirstResponder(self); model?.selectTool(.select); synchronize()
    }
}

@MainActor
final class ScreenshotTextEntryView: NSTextView {
    private let typingUndoManager = UndoManager()
    override var undoManager: UndoManager? { typingUndoManager }
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command { onCommit?(); return }
        super.keyDown(with: event)
    }
}
