// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit

/// Presentation only: the service translates the normalized result into page coordinates.
@MainActor
final class PageScreenshotRegionSelector: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var retainedWhileSelecting: PageScreenshotRegionSelector?
    private var anchor: CGPoint?
    private var selection: CGRect?
    private var completion: ((PageScreenshotRegion?) -> Void)?
    private var validityTimer: Timer?
    private var eventMonitor: Any?
    private weak var previousResponder: NSResponder?

    static func select(over pageView: NSView, isValid: @escaping () -> Bool) async -> PageScreenshotRegion? {
        guard let host = pageView.superview, let window = pageView.window, isValid() else { return nil }
        return await withCheckedContinuation { continuation in
            let overlay = PageScreenshotRegionSelector(frame: pageView.convert(pageView.bounds, to: host))
            overlay.retainedWhileSelecting = overlay
            overlay.previousResponder = window.firstResponder
            overlay.completion = { continuation.resume(returning: $0) }
            host.addSubview(overlay, positioned: .above, relativeTo: pageView)
            window.makeFirstResponder(overlay)
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
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak overlay, weak window] _ in
                MainActor.assumeIsolated {
                    guard let overlay else { return }
                    if window?.isVisible != true || !isValid() { overlay.finish(nil) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            overlay.validityTimer = timer
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func scrollWheel(with event: NSEvent) {} // Freeze user scrolling while choosing the viewport clip.
    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let selection, let result = PageScreenshotRegion(selection: selection, bounds: bounds, isFlipped: true) else {
            anchor = nil
            needsDisplay = true
            return
        }
        finish(result)
    }
    override func cancelOperation(_ sender: Any?) { finish(nil) }

    private func finish(_ result: PageScreenshotRegion?) {
        guard let completion else { return }
        self.completion = nil
        validityTimer?.invalidate()
        validityTimer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        let window = window
        removeFromSuperview()
        window?.makeFirstResponder(previousResponder)
        completion(result)
        retainedWhileSelecting = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if let selection { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        shade.fill()
        if let selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 1
            border.stroke()
        }
        let text = NSLocalizedString("browser.screenshot.areaHint", value: "Drag to capture an area · Escape to cancel",
                                     comment: "Screenshot - Instructions above the page during area selection")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: max(8, (bounds.width - size.width) / 2), y: 16, width: size.width, height: size.height)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -8, dy: -6), xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}
