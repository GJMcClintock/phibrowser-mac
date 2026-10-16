// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit
import SwiftUI

/// Viewport-owned controls never move with the scrollable image or enter exported pixels.
@MainActor
final class ScreenshotEditorViewport: NSView {
    override var isFlipped: Bool { true }
    let scrollView: NSScrollView
    private let model: ScreenshotEditorModel
    private var toolbar: NSHostingView<ScreenshotEditorToolbar>!
    private let zoomControl: NSHostingView<ScreenshotZoomWidget>
    let annotationPopover: ScreenshotAnnotationPopover
    private var boundsObserver: NSObjectProtocol?
    private var updating = false

    init(scrollView: NSScrollView, model: ScreenshotEditorModel, export: @escaping (ScreenshotExportFormat) -> Void) {
        self.scrollView = scrollView
        self.model = model
        zoomControl = NSHostingView(rootView: ScreenshotZoomWidget(model: model))
        annotationPopover = ScreenshotAnnotationPopover(model: model)
        super.init(frame: .zero)
        toolbar = NSHostingView(rootView: ScreenshotEditorToolbar(model: model, export: export))
        addSubview(scrollView)
        addSubview(annotationPopover)
        addSubview(zoomControl)
        addSubview(toolbar)
        (scrollView.documentView as? ScreenshotCanvasView)?.onPresentationChange = { [weak self] in self?.updatePresentation() }
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePresentation() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        updatePresentation()
    }

    func updatePresentation() {
        guard !updating, bounds.width > 0, bounds.height > 0, let toolbar else { return }
        updating = true
        defer { updating = false }
        let size = toolbar.fittingSize
        let center = CGPoint(x: bounds.midX, y: bounds.maxY - 24 - size.height / 2)
        toolbar.frame = ScreenshotPopoverPlacement.clamp(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), to: bounds.insetBy(dx: 12, dy: 12))
        let zoomSize = zoomControl.fittingSize
        var zoomFrame = CGRect(x: 20, y: bounds.maxY - zoomSize.height - 24, width: zoomSize.width, height: zoomSize.height)
        if zoomFrame.intersects(toolbar.frame.insetBy(dx: -8, dy: -8)) { zoomFrame.origin.y = toolbar.frame.minY - zoomSize.height - 12 }
        zoomControl.frame = ScreenshotPopoverPlacement.clamp(zoomFrame, to: bounds.insetBy(dx: 12, dy: 12))
        guard let canvas = scrollView.documentView as? ScreenshotCanvasView,
              model.tool == .select, !model.isInteracting, !model.isEditingText,
              !model.selectedObjects.contains(where: { $0.kind == .mosaic }),
              !canvas.isShowingContextMenu, !canvas.isPanningImage,
              let sourceBounds = model.selectionBounds else {
            annotationPopover.isHidden = true
            return
        }
        let anchor = canvas.convert(sourceBounds.applying(CGAffineTransform(scaleX: model.zoom, y: model.zoom)), to: self)
        guard let frame = ScreenshotPopoverPlacement.frame(anchor: anchor, size: annotationPopover.preferredSize,
                                                           viewport: bounds, avoiding: [toolbar.frame, zoomControl.frame]) else {
            annotationPopover.isHidden = true
            return
        }
        annotationPopover.frame = frame
        annotationPopover.point(to: CGPoint(x: anchor.midX, y: anchor.midY))
        annotationPopover.isHidden = false
    }
}

/// Geometry is in the flipped viewport's coordinates, independent of image zoom and scrolling.
enum ScreenshotPopoverPlacement {
    static func clamp(_ rect: CGRect, to viewport: CGRect) -> CGRect {
        CGRect(x: max(viewport.minX, min(rect.minX, viewport.maxX - rect.width)),
               y: max(viewport.minY, min(rect.minY, viewport.maxY - rect.height)),
               width: rect.width, height: rect.height)
    }

    static func frame(anchor: CGRect, size: CGSize, viewport: CGRect, avoiding obstacles: [CGRect]) -> CGRect? {
        let visible = anchor.insetBy(dx: -1, dy: -1).intersection(viewport)
        guard !visible.isNull, !visible.isEmpty, size.width <= viewport.width - 16, size.height <= viewport.height - 16 else { return nil }
        let safe = viewport.insetBy(dx: 8, dy: 8), gap: CGFloat = 8
        let candidates = [
            CGRect(x: visible.midX - size.width / 2, y: visible.minY - size.height - gap, width: size.width, height: size.height),
            CGRect(x: visible.midX - size.width / 2, y: visible.maxY + gap, width: size.width, height: size.height),
            CGRect(x: visible.maxX + gap, y: visible.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: visible.minX - size.width - gap, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        ].map { clamp($0, to: safe) }
        func overlap(_ rect: CGRect, _ other: CGRect) -> CGFloat {
            let intersection = rect.intersection(other)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        // Prefer no occlusion; for a viewport-sized object, minimize covered artwork.
        return candidates.min { lhs, rhs in
            func score(_ frame: CGRect) -> CGFloat {
                overlap(frame, visible) + obstacles.reduce(0) { $0 + overlap(frame, $1.insetBy(dx: -6, dy: -6)) * 100 }
            }
            return score(lhs) < score(rhs)
        }
    }
}

/// A nonactivating in-window popover preserves canvas/text focus and follows the selected object.
@MainActor
final class ScreenshotAnnotationPopover: NSView {
    override var isFlipped: Bool { true }
    private let content: NSHostingView<ScreenshotAnnotationProperties>
    private let material = NSVisualEffectView()
    private let pointer = CAShapeLayer()
    var preferredSize: CGSize {
        let size = content.fittingSize
        return CGSize(width: size.width + 16, height: size.height + 16)
    }

    init(model: ScreenshotEditorModel) {
        content = NSHostingView(rootView: ScreenshotAnnotationProperties(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16; layer?.shadowRadius = 8; layer?.shadowOffset = CGSize(width: 0, height: -2)
        material.material = .popover; material.blendingMode = .withinWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 12; material.layer?.masksToBounds = true
        addSubview(material); material.addSubview(content)
        layer?.addSublayer(pointer)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        guard bounds.width >= 16, bounds.height >= 16 else { return }
        material.frame = bounds.insetBy(dx: 8, dy: 8)
        content.frame = material.bounds
    }
    func point(to anchor: CGPoint) {
        let point = CGPoint(x: anchor.x - frame.minX, y: anchor.y - frame.minY)
        let body = bounds.insetBy(dx: 8, dy: 8), path = CGMutablePath()
        let x = max(body.minX + 16, min(body.maxX - 16, point.x))
        let y = max(body.minY + 16, min(body.maxY - 16, point.y))
        if point.y < body.minY {
            path.move(to: CGPoint(x: x - 6, y: body.minY)); path.addLine(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x + 6, y: body.minY))
        } else if point.y > body.maxY {
            path.move(to: CGPoint(x: x - 6, y: body.maxY)); path.addLine(to: CGPoint(x: x, y: bounds.maxY)); path.addLine(to: CGPoint(x: x + 6, y: body.maxY))
        } else if point.x < body.minX {
            path.move(to: CGPoint(x: body.minX, y: y - 6)); path.addLine(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: body.minX, y: y + 6))
        } else if point.x > body.maxX {
            path.move(to: CGPoint(x: body.maxX, y: y - 6)); path.addLine(to: CGPoint(x: bounds.maxX, y: y)); path.addLine(to: CGPoint(x: body.maxX, y: y + 6))
        }
        path.closeSubpath()
        pointer.frame = bounds; pointer.path = path; pointer.fillColor = NSColor.windowBackgroundColor.cgColor
        needsLayout = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        // SwiftUI can return no hit for padding between controls. The popover still
        // owns that click, so the canvas cannot interpret it as a deselection.
        return super.hitTest(point) ?? self
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
}
