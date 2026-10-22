// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit

/// Owns selection interaction; the service performs and validates document scrolling.
@MainActor
final class PageScreenshotRegionSelector: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var retainedWhileSelecting: PageScreenshotRegionSelector?
    private var viewport = PageScreenshotViewport(rect: .zero, viewSize: .zero, scale: 1)
    private var scroll: PageScreenshotService.SelectionScroll?
    private var isValid: () -> Bool = { false }
    private var anchor: CGPoint?
    private var pointer: CGPoint?
    private var isDragging = false
    private var hasDragged = false
    private var isFinishing = false
    private var pendingScroll = CGSize.zero
    private var scrollTask: Task<Void, Never>?
    private var lastRefresh: TimeInterval = 0
    private var lastWheelTime: TimeInterval = -.infinity
    private var selection: CGRect?
    private var completion: ((PageScreenshotRegion?) -> Void)?
    private var validityTimer: Timer?
    private var eventMonitor: Any?
    private var focusObserver: NSObjectProtocol?
    private weak var previousResponder: NSResponder?

    static func select(over pageView: NSView, viewport: PageScreenshotViewport,
                       scroll: @escaping PageScreenshotService.SelectionScroll,
                       isValid: @escaping () -> Bool) async -> PageScreenshotRegion? {
        guard let host = pageView.superview, let window = pageView.window, isValid() else { return nil }
        return await withCheckedContinuation { continuation in
            let overlay = PageScreenshotRegionSelector(frame: pageView.convert(pageView.bounds, to: host))
            overlay.viewport = viewport
            overlay.scroll = scroll
            overlay.isValid = isValid
            overlay.retainedWhileSelecting = overlay
            overlay.previousResponder = window.firstResponder
            overlay.completion = { continuation.resume(returning: $0) }
            host.addSubview(overlay, positioned: .above, relativeTo: pageView)
            window.makeFirstResponder(overlay)
            overlay.focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                            object: window, queue: .main) { [weak overlay] _ in
                MainActor.assumeIsolated { overlay?.finish(nil) }
            }
            overlay.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak overlay, weak window] event in
                guard let overlay else { return event }
                if event.type == .keyDown && event.keyCode == 53 {
                    overlay.finish(nil)
                    return nil
                }
                if event.type == .rightMouseDown || event.window !== window {
                    overlay.finish(nil)
                }
                return event
            }
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak overlay, weak window] _ in
                MainActor.assumeIsolated {
                    guard let overlay else { return }
                    if window?.isVisible != true || !isValid() { overlay.finish(nil); return }
                    overlay.updateScrolling()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            overlay.validityTimer = timer
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func scrollWheel(with event: NSEvent) {
        guard isDragging, !isFinishing else { return }
        // Coarse wheel events use line units; trackpad deltas are already view points.
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 20
        lastWheelTime = ProcessInfo.processInfo.systemUptime
        enqueueScroll(CGSize(width: -event.scrollingDeltaX * multiplier,
                             height: -event.scrollingDeltaY * multiplier))
    }

    override func mouseDown(with event: NSEvent) {
        guard !isFinishing, scrollTask == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        anchor = viewport.pagePoint(from: point, in: bounds)
        selection = nil
        isDragging = true
        hasDragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, !isFinishing else { return }
        pointer = convert(event.locationInWindow, from: nil)
        hasDragged = true
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        mouseDragged(with: event)
        isDragging = false
        isFinishing = true
        // Finish only after the in-flight scroll and queued wheel deltas settle.
        completeSelectionIfReady()
    }

    private func updateSelection() {
        guard let anchor, let pointer else { return }
        let endpoint = viewport.pagePoint(from: pointer, in: bounds)
        selection = CGRect(x: min(anchor.x, endpoint.x), y: min(anchor.y, endpoint.y),
                           width: abs(endpoint.x - anchor.x), height: abs(endpoint.y - anchor.y))
        needsDisplay = true
    }

    /// Called by the common-mode timer so holding the pointer at an edge keeps scrolling.
    func updateScrolling() {
        guard completion != nil, !isFinishing, scrollTask == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if isDragging, hasDragged, let pointer, now - lastWheelTime > 0.25 {
            let delta = Self.edgeScrollDelta(at: pointer, in: bounds)
            if delta != .zero { enqueueScroll(delta); return }
        }
        // Validate the viewport during a drag even without wheel input.
        if isDragging, now - lastRefresh >= 0.1 { enqueueScroll(.zero) }
    }

    static func edgeScrollDelta(at point: CGPoint, in bounds: CGRect) -> CGSize {
        func step(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            let margin = min(32, (upper - lower) / 4)
            guard margin > 0 else { return 0 }
            if value < lower + margin { return -40 * min(1, (lower + margin - value) / margin) }
            if value > upper - margin { return 40 * min(1, (value - upper + margin) / margin) }
            return 0
        }
        return CGSize(width: step(point.x, bounds.minX, bounds.maxX), height: step(point.y, bounds.minY, bounds.maxY))
    }

    private func enqueueScroll(_ delta: CGSize) {
        guard completion != nil, isValid() else { finish(nil); return }
        pendingScroll.width += delta.width
        pendingScroll.height += delta.height
        guard scrollTask == nil, let scroll else { return }
        let pageDelta = viewport.pageDelta(from: pendingScroll, in: bounds)
        pendingScroll = .zero
        scrollTask = Task { @MainActor [weak self] in
            do {
                let updated = try await scroll(pageDelta)
                guard let self, self.completion != nil else { return }
                guard self.isValid(), updated.hasSameGeometry(as: self.viewport) else { self.finish(nil); return }
                self.viewport = updated
                self.lastRefresh = ProcessInfo.processInfo.systemUptime
                self.scrollTask = nil
                self.updateSelection()
                if self.pendingScroll != .zero {
                    self.enqueueScroll(.zero)
                } else {
                    self.completeSelectionIfReady()
                }
            } catch {
                self?.finish(nil)
            }
        }
    }

    private func completeSelectionIfReady() {
        guard isFinishing, scrollTask == nil else { return }
        guard isValid() else { finish(nil); return }
        let minimum = viewport.pageDelta(from: CGSize(width: 2, height: 2), in: bounds)
        guard let selection, let result = PageScreenshotRegion(selection: selection, minimumSize: minimum) else {
            anchor = nil
            pointer = nil
            self.selection = nil
            isFinishing = false
            needsDisplay = true
            return
        }
        finish(result)
    }
    override func cancelOperation(_ sender: Any?) { finish(nil) }

    private func finish(_ result: PageScreenshotRegion?) {
        guard let completion else { return }
        self.completion = nil
        scrollTask?.cancel()
        scrollTask = nil
        pendingScroll = .zero
        scroll = nil
        validityTimer?.invalidate()
        validityTimer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        let window = window
        removeFromSuperview()
        window?.makeFirstResponder(previousResponder)
        completion(result)
        retainedWhileSelecting = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let visibleSelection = selection.map { viewport.viewRect(for: $0, in: bounds).intersection(bounds) }
        let shade = NSBezierPath(rect: bounds)
        if let visibleSelection, !visibleSelection.isNull { shade.appendRect(visibleSelection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        shade.fill()
        if let selection {
            NSColor.white.setStroke()
            // Draw the document rectangle, clipped by this view, without inventing an edge
            // where the selected area continues beyond the visible viewport.
            let border = NSBezierPath(rect: viewport.viewRect(for: selection, in: bounds))
            border.lineWidth = 1
            border.stroke()
        }
        let text = NSLocalizedString("browser.screenshot.areaHint", value: "Drag to select · Scroll or drag to an edge to extend · Escape to cancel",
                                     comment: "Screenshot - Instructions above the page during area selection")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: max(8, (bounds.width - size.width) / 2), y: 16, width: size.width, height: size.height)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -8, dy: -6), xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}
