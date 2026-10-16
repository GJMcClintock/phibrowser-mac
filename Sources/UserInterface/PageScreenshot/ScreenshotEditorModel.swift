// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit
import Observation

/// Retained document with a reversible preview session and aggregate undo per edit.
@MainActor @Observable
final class ScreenshotEditorModel {
    private(set) var source: CGImage
    private(set) var annotations: [ScreenshotAnnotation] = []
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var previewSelection: Set<UUID> = []
    private(set) var marquee: CGRect?
    private(set) var cropRect: CGRect?
    var canCrop: Bool { tool == .crop && cropRect != nil && !isInteracting }
    private(set) var revision = 0
    private(set) var generation = 0
    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var prepareForCommand: (() -> Void)?
    @ObservationIgnored var hasUserZoomed = false
    @ObservationIgnored private var synchronizingStyle = false
    @ObservationIgnored private var gesture: Gesture?
    private(set) var tool: ScreenshotTool = .select
    var foreground = ScreenshotColor.red { didSet { updateStyle(\.color, foreground) } }
    var brushSize: CGFloat = 2.5 { didSet { updateStyle(\.width, brushSize) } }
    var textSize: CGFloat = 24 { didSet { updateStyle(\.fontSize, textSize) } }
    var filled = false { didSet { updateStyle(\.filled, filled) } }
    var isEditingText = false
    var textCanUndo = false
    var textCanRedo = false
    var zoom = 1.0
    var width: Int { source.width }
    var height: Int { source.height }
    var selectedID: UUID? { selectedIDs.count == 1 ? selectedIDs.first : nil }
    var selected: ScreenshotAnnotation? { annotations.first { $0.id == selectedID } }
    var selectedObjects: [ScreenshotAnnotation] { annotations.filter { selectedIDs.contains($0.id) } }
    var hasSelection: Bool { !selectedIDs.isEmpty }
    var isInteracting: Bool { gesture != nil }
    var style: ScreenshotAnnotationStyle {
        ScreenshotAnnotationStyle(color: foreground, width: brushSize, arrowHeadLength: CGFloat(width) / 1000 * 32,
                                  fontSize: textSize, filled: filled)
    }
    var selectionBounds: CGRect? { bounds(of: selectedObjects) }
    var cropHandles: [(ScreenshotAnnotation.Handle, CGPoint)] {
        guard let cropRect else { return [] }
        return ScreenshotAnnotation(kind: .rectangle, frame: cropRect).handles
    }
    var selectionHandles: [(ScreenshotAnnotation.Handle, CGPoint)] {
        if let selected { return selected.handles }
        guard let frame = selectionBounds else { return [] }
        return ScreenshotAnnotation(kind: .rectangle, frame: frame).handles
    }
    var displayedSelection: Set<UUID> {
        guard let gesture, case .marquee = gesture.mode else { return selectedIDs }
        return combine(gesture.before.selectedIDs, previewSelection, flags: gesture.flags)
    }

    private struct State {
        var source: CGImage
        var annotations: [ScreenshotAnnotation]
        var selectedIDs: Set<UUID>
    }
    private struct Gesture {
        enum Mode { case draw(ScreenshotTool, UUID), move(UUID), handle(ScreenshotAnnotation.Handle), marquee, crop, moveCrop, resizeCrop(ScreenshotAnnotation.Handle) }
        var before: State
        var originals: [ScreenshotAnnotation]
        var start: CGPoint
        var previous: CGPoint
        var distance: CGFloat = 0
        var mode: Mode
        var flags: NSEvent.ModifierFlags
        var previousCropRect: CGRect?
    }
    private var state: State { State(source: source, annotations: annotations, selectedIDs: selectedIDs) }

    init(canvas: CGImage) {
        source = canvas
        brushSize = CGFloat(canvas.width) / 1000 * 2.5
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 100
    }
    private func changed(committed: Bool = false) {
        revision &+= 1
        if committed { generation &+= 1 }
        canUndo = undoManager.canUndo; canRedo = undoManager.canRedo
        onChange?()
    }
    private func register(_ before: State, action: String) {
        guard before.source !== source || before.annotations != annotations else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in target.restore(before, action: action) }
        undoManager.setActionName(action); undoManager.endUndoGrouping()
        changed(committed: true)
    }
    private func restore(_ value: State, action: String) {
        let inverse = state
        if source !== value.source { hasUserZoomed = false }
        source = value.source; annotations = value.annotations; selectedIDs = value.selectedIDs
        cropRect = nil
        undoManager.registerUndo(withTarget: self) { target in target.restore(inverse, action: action) }
        undoManager.setActionName(action)
        tool = .select; syncStyle(); changed(committed: true)
    }
    private func command(_ action: String, mutate: () -> Void) {
        prepareForCommand?(); cancelInteraction()
        let before = state
        mutate(); register(before, action: action); syncStyle(); changed()
    }
    func selectTool(_ value: ScreenshotTool) {
        prepareForCommand?(); cancelInteraction(); cropRect = nil; tool = value
        if value != .select { selectedIDs.removeAll() }
        changed()
    }
    func select(_ id: UUID?) { select(ids: Set(id.map { [$0] } ?? [])) }
    func select(ids: Set<UUID>) {
        guard tool != .crop else { return }
        selectedIDs = ids.intersection(Set(annotations.map(\.id))); syncStyle(); changed()
    }
    func selectAll() { guard tool != .crop else { return }; prepareForCommand?(); cancelInteraction(); tool = .select; select(ids: Set(annotations.map(\.id))) }
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> ScreenshotAnnotation? {
        annotations.reversed().first { $0.contains(point, tolerance: tolerance) }
    }
    private func syncStyle() {
        guard let selected else { return }
        synchronizingStyle = true
        foreground = selected.style.color; brushSize = selected.style.width
        textSize = selected.style.fontSize; filled = selected.style.filled
        synchronizingStyle = false
    }
    private func updateStyle<Value>(_ key: WritableKeyPath<ScreenshotAnnotationStyle, Value>, _ value: Value) {
        guard !synchronizingStyle else { return }
        command(NSLocalizedString("browser.screenshot.styleEdit", value: "Change Style", comment: "Screenshot editor - Undo action for annotation style")) {
            for i in annotations.indices where selectedIDs.contains(annotations[i].id) && annotations[i].kind != .mosaic {
                annotations[i].style[keyPath: key] = value
                annotations[i] = annotations[i].fittingText()
            }
        }
    }
    @discardableResult
    func adjustSelectionSize(by delta: CGFloat) -> Bool {
        guard !isEditingText, !isInteracting, hasSelection else { return false }
        command(NSLocalizedString("browser.screenshot.styleEdit", value: "Change Style", comment: "Screenshot editor - Undo action for annotation style")) {
            for i in annotations.indices where selectedIDs.contains(annotations[i].id) {
                switch annotations[i].kind {
                case .rectangle, .ellipse, .arrow, .freehand:
                    let current = annotations[i].style.width
                    annotations[i].style.width = max(min(1, current), current + delta)
                case .mosaic: break
                case .text:
                    let current = annotations[i].style.fontSize
                    annotations[i].style.fontSize = max(min(1, current), current + delta)
                    annotations[i] = annotations[i].fittingText()
                }
            }
        }
        return true
    }
    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(CGFloat(width), p.x)), y: max(0, min(CGFloat(height), p.y)))
    }
    private func bounds(of objects: [ScreenshotAnnotation]) -> CGRect? {
        guard let first = objects.first else { return nil }
        return objects.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }
    private func combine(_ persistent: Set<UUID>, _ preview: Set<UUID>, flags: NSEvent.ModifierFlags) -> Set<UUID> {
        if flags.contains(.shift) { return persistent.union(preview) }
        if flags.contains(.command) { return persistent.subtracting(preview) }
        return preview
    }
    func beginInteraction(at input: CGPoint, tolerance: CGFloat, moving: Bool = false, modifiers: NSEvent.ModifierFlags = []) {
        cancelInteraction()
        let point = clamped(input), before = state
        if tool == .crop {
            let previous = cropRect
            let mode: Gesture.Mode
            if let handle = cropHandles.first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance })?.0 {
                mode = .resizeCrop(handle)
            } else if let previous, previous.contains(point) {
                mode = .moveCrop
            } else {
                mode = .crop
                cropRect = CGRect(origin: point, size: .zero)
            }
            gesture = Gesture(before: before, originals: [], start: point, previous: point, mode: mode, flags: modifiers, previousCropRect: previous)
        } else if tool == .select || moving {
            if modifiers.intersection([.shift, .command]).isEmpty,
               let handle = selectionHandles.first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance })?.0 {
                gesture = Gesture(before: before, originals: selectedObjects, start: point, previous: point, mode: .handle(handle), flags: modifiers)
            } else if let object = hitTest(point, tolerance: 15 / max(zoom, 0.02)) {
                if !selectedIDs.contains(object.id) {
                    if modifiers.intersection([.shift, .command]).isEmpty { selectedIDs = [object.id] }
                    else { selectedIDs.insert(object.id) }
                }
                gesture = Gesture(before: before, originals: selectedObjects, start: point, previous: point, mode: .move(object.id), flags: modifiers)
            } else {
                marquee = CGRect(origin: point, size: .zero)
                gesture = Gesture(before: before, originals: [], start: point, previous: point, mode: .marquee, flags: modifiers)
            }
        } else if tool != .text, let kind = ScreenshotAnnotation.Kind(rawValue: tool.rawValue) {
            let object = ScreenshotAnnotation(kind: kind, points: kind == .arrow ? [point, point] : kind == .freehand ? [point] : [],
                                              frame: CGRect(origin: point, size: .zero), style: style)
            annotations.append(object); selectedIDs = [object.id]
            gesture = Gesture(before: before, originals: [object], start: point, previous: point, mode: .draw(tool, object.id), flags: modifiers)
        }
        changed()
    }
    func continueInteraction(at input: CGPoint, mirrored: Bool = false, modifiers: NSEvent.ModifierFlags? = nil) {
        guard var active = gesture else { return }
        let point = clamped(input)
        active.distance += hypot(input.x - active.previous.x, input.y - active.previous.y) * zoom
        active.previous = input
        if let modifiers { active.flags = modifiers }
        gesture = active
        switch active.mode {
        case .moveCrop:
            guard let rect = active.previousCropRect else { return }
            cropRect = CGRect(x: max(0, min(CGFloat(width) - rect.width, rect.minX + point.x - active.start.x)),
                              y: max(0, min(CGFloat(height) - rect.height, rect.minY + point.y - active.start.y)),
                              width: rect.width, height: rect.height)
        case .resizeCrop(let handle):
            guard let rect = active.previousCropRect else { return }
            let guide = ScreenshotAnnotation(kind: .rectangle, frame: rect)
            guard let anchor = guide.handles.first(where: { $0.0 == handle })?.1 else { return }
            let target = clamped(CGPoint(x: anchor.x + point.x - active.start.x, y: anchor.y + point.y - active.start.y))
            cropRect = guide.editing(handle: handle, at: target).bounds.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        case .crop:
            cropRect = CGRect(x: min(point.x, active.start.x), y: min(point.y, active.start.y),
                              width: abs(point.x - active.start.x), height: abs(point.y - active.start.y))
        case .marquee:
            let rect = CGRect(x: min(point.x, active.start.x), y: min(point.y, active.start.y),
                              width: abs(point.x - active.start.x), height: abs(point.y - active.start.y))
            marquee = rect
            // Preview includes objects whose bounds intersect the selection rectangle.
            previewSelection = Set(annotations.filter { rect.intersects($0.bounds.insetBy(dx: -0.01, dy: -0.01)) }.map(\.id))
        case .move:
            let delta = boundedDelta(CGPoint(x: point.x - active.start.x, y: point.y - active.start.y), objects: active.originals)
            apply(active.originals.map { $0.translated(by: delta) })
        case .handle(let handle):
            guard let old = bounds(of: active.originals) else { return }
            let handles = active.originals.count == 1 ? active.originals[0].handles : ScreenshotAnnotation(kind: .rectangle, frame: old).handles
            guard let anchor = handles.first(where: { $0.0 == handle })?.1 else { return }
            let handlePoint = CGPoint(x: anchor.x + point.x - active.start.x, y: anchor.y + point.y - active.start.y)
            if active.originals.count == 1 {
                apply([active.originals[0].editing(handle: handle, at: handlePoint, mirrored: mirrored)])
            } else {
                // Transform a guide and two diagonal reference points to retain reflection direction.
                let guide = ScreenshotAnnotation(kind: .freehand, points: [old.origin, CGPoint(x: old.maxX, y: old.maxY)])
                    .editing(handle: handle, at: handlePoint, mirrored: mirrored)
                let flipX = guide.points[0].x > guide.points[1].x, flipY = guide.points[0].y > guide.points[1].y
                apply(active.originals.map { $0.transformed(from: old, to: guide.bounds, flipX: flipX, flipY: flipY) })
            }
        case .draw(let tool, let id):
            guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
            if tool == .arrow { annotations[i].points = [active.start, point] }
            else if tool == .freehand {
                if annotations[i].points.last != point { annotations[i].points.append(point) }
            } else {
                annotations[i].frame = CGRect(x: min(point.x, active.start.x), y: min(point.y, active.start.y),
                                              width: abs(point.x - active.start.x), height: abs(point.y - active.start.y))
            }
        }
        changed()
    }
    private func apply(_ objects: [ScreenshotAnnotation]) {
        let replacement = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
        for i in annotations.indices { if let value = replacement[annotations[i].id] { annotations[i] = value } }
    }
    func endInteraction() {
        guard let active = gesture else { return }
        gesture = nil
        defer { marquee = nil; previewSelection.removeAll(); syncStyle(); changed() }
        switch active.mode {
        case .crop, .moveCrop, .resizeCrop:
            if let rect = cropRect, rect.width * zoom >= 2, rect.height * zoom >= 2 {
                cropRect = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            } else { cropRect = nil }
            return
        case .marquee:
            selectedIDs = combine(active.before.selectedIDs, previewSelection, flags: active.flags)
            return
        case .move(let id) where active.distance <= 3:
            annotations = active.before.annotations
            selectedIDs = active.before.selectedIDs
            if active.flags.contains(.command), selectedIDs.contains(id) { selectedIDs.remove(id) }
            else if !active.flags.intersection([.shift, .command]).isEmpty { selectedIDs.insert(id) }
            else { selectedIDs = [id] }
            return
        case .draw(let tool, let id):
            self.tool = active.flags.contains(.shift) ? tool : .select
            guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
            let object = annotations[i]
            if tool == .arrow && hypot(object.bounds.width, object.bounds.height) * zoom < 3 ||
                tool == .freehand && object.points.count < 2 {
                annotations = active.before.annotations; selectedIDs = active.before.selectedIDs; return
            }
            if tool == .mosaic {
                guard object.frame.width * zoom >= 2, object.frame.height * zoom >= 2 else {
                    annotations = active.before.annotations; selectedIDs = active.before.selectedIDs; return
                }
                annotations[i].frame = object.frame.integral
            }
            if (tool == .rectangle || tool == .ellipse), max(object.bounds.width, object.bounds.height) * zoom < 3 {
                let size = min(200, CGFloat(width), CGFloat(height))
                annotations[i].frame = CGRect(x: max(0, min(CGFloat(width) - size, active.start.x - size / 2)),
                                              y: max(0, min(CGFloat(height) - size, active.start.y - size / 2)), width: size, height: size)
            }
        default: break
        }
        register(active.before, action: NSLocalizedString("browser.screenshot.annotationEdit", value: "Edit Annotation", comment: "Screenshot editor - Undo action for creating or transforming an annotation"))
    }
    func cancelInteraction() {
        guard let active = gesture else { return }
        gesture = nil; annotations = active.before.annotations; selectedIDs = active.before.selectedIDs
        switch active.mode {
        case .crop, .moveCrop, .resizeCrop: cropRect = active.previousCropRect
        default: break
        }
        marquee = nil; previewSelection.removeAll(); syncStyle(); changed()
    }
    /// Crop the immutable background and rebase retained objects in one document transaction.
    func cropToSelection() {
        guard canCrop, let rect = cropRect else { return }
        prepareForCommand?()
        let before = state
        if rect != CGRect(x: 0, y: 0, width: width, height: height) {
            guard let cropped = source.cropping(to: rect) else { return }
            annotations = annotations.filter { object in
                var bounds = object.kind == .text ? object.frame : object.path.boundingBoxOfPath
                if let head = object.arrowHead { bounds = bounds.union(head.boundingBoxOfPath) }
                let padding = object.kind == .text ? 0 : max(0.01, object.style.width / 2)
                return bounds.insetBy(dx: -padding, dy: -padding).intersects(rect)
            }.map { $0.translated(by: CGPoint(x: -rect.minX, y: -rect.minY)) }
            source = cropped
        }
        cropRect = nil; selectedIDs.removeAll(); tool = .select; hasUserZoomed = false
        register(before, action: NSLocalizedString("browser.screenshot.crop", value: "Crop", comment: "Screenshot editor - Crop the image to the selected rectangular region"))
        changed()
    }
    func commitText(_ text: String, frame: CGRect, id: UUID? = nil) {
        cancelInteraction()
        let before = state
        if let id, let index = annotations.firstIndex(where: { $0.id == id }) {
            if text.isEmpty { annotations.remove(at: index); selectedIDs.remove(id) }
            else {
                annotations[index].text = text; annotations[index].frame = frame
                annotations[index] = annotations[index].fittingText(); selectedIDs = [id]
            }
        } else if !text.isEmpty {
            let object = ScreenshotAnnotation(kind: .text, frame: frame, text: text, style: style).fittingText()
            annotations.append(object); selectedIDs = [object.id]
        }
        tool = .select
        register(before, action: NSLocalizedString("browser.screenshot.textEdit", value: "Edit Text", comment: "Screenshot editor - Undo action for a text annotation"))
        changed()
    }
    func deleteSelection() {
        command(NSLocalizedString("browser.screenshot.delete", value: "Delete", comment: "Screenshot editor - Delete selected annotation")) {
            annotations.removeAll { selectedIDs.contains($0.id) }; selectedIDs.removeAll()
        }
    }
    private func boundedDelta(_ delta: CGPoint, objects: [ScreenshotAnnotation]) -> CGPoint {
        guard let b = bounds(of: objects) else { return .zero }
        return CGPoint(x: max(min(0, -b.minX), min(max(0, CGFloat(width) - b.maxX), delta.x)),
                       y: max(min(0, -b.minY), min(max(0, CGFloat(height) - b.maxY), delta.y)))
    }
    func duplicateSelection() {
        command(NSLocalizedString("browser.screenshot.duplicate", value: "Duplicate", comment: "Screenshot editor - Duplicate selected annotation")) {
            let objects = selectedObjects, delta = boundedDelta(CGPoint(x: 12, y: 12), objects: objects)
            let copies = objects.map { object in var copy = object.translated(by: delta); copy.id = UUID(); return copy }
            annotations += copies; selectedIDs = Set(copies.map(\.id))
        }
    }
    func moveSelection(by delta: CGPoint) {
        command(NSLocalizedString("browser.screenshot.move", value: "Move", comment: "Screenshot editor - Undo action for moving an annotation")) {
            let objects = selectedObjects, delta = boundedDelta(delta, objects: objects)
            apply(objects.map { $0.translated(by: delta) })
        }
    }
    func reorderSelection(front: Bool) {
        command(front ? NSLocalizedString("browser.screenshot.bringToFront", value: "Bring to Front", comment: "Screenshot editor - Move selected annotation above others") : NSLocalizedString("browser.screenshot.sendToBack", value: "Send to Back", comment: "Screenshot editor - Move selected annotation below others")) {
            let objects = selectedObjects
            annotations.removeAll { selectedIDs.contains($0.id) }
            annotations.insert(contentsOf: objects, at: front ? annotations.count : 0)
        }
    }
    func paste(_ object: ScreenshotAnnotation) { paste([object]) }
    func paste(_ objects: [ScreenshotAnnotation]) {
        command(NSLocalizedString("browser.screenshot.paste", value: "Paste", comment: "Screenshot editor - Paste copied annotation")) {
            guard let b = bounds(of: objects) else { return }
            let scale = min(1, CGFloat(width) / max(1, b.width), CGFloat(height) / max(1, b.height))
            let target = CGRect(origin: CGPoint(x: max(0, min(CGFloat(width) - b.width * scale, b.minX)),
                                               y: max(0, min(CGFloat(height) - b.height * scale, b.minY))),
                                size: CGSize(width: b.width * scale, height: b.height * scale))
            var copies = objects.map { item in
                var copy = item.transformed(from: b, to: target); copy.id = UUID()
                return copy
            }
            let delta = boundedDelta(CGPoint(x: 12, y: 12), objects: copies)
            copies = copies.map { $0.translated(by: delta) }
            annotations += copies; selectedIDs = Set(copies.map(\.id)); tool = .select
        }
    }
    func undo() { prepareForCommand?(); cancelInteraction(); cropRect = nil; tool = .select; undoManager.undo(); changed() }
    func redo() { prepareForCommand?(); cancelInteraction(); cropRect = nil; tool = .select; undoManager.redo(); changed() }
    func setZoomExact(_ value: Double) { if value.isFinite { zoom = max(0.02, min(32, value)) } }
    func zoomBy(_ factor: Double) { prepareForCommand?(); cancelInteraction(); hasUserZoomed = true; setZoomExact(zoom * factor) }
    func fit() { prepareForCommand?(); cancelInteraction(); hasUserZoomed = false }
    func snapshot() -> ScreenshotSnapshot {
        prepareForCommand?(); cancelInteraction()
        return ScreenshotSnapshot(source: source, annotations: annotations)
    }
}
