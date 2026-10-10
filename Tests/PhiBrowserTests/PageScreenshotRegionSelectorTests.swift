import AppKit
import XCTest
@testable import Phi

@MainActor
final class PageScreenshotRegionSelectorTests: XCTestCase {
    private func fixture() -> (NSWindow, NSView, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let page = NSView(frame: NSRect(x: 100, y: 100, width: 600, height: 400))
        window.contentView = host
        host.addSubview(page)
        return (window, host, page)
    }

    private func event(_ type: NSEvent.EventType, _ point: CGPoint, in overlay: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: overlay.convert(point, to: nil), modifierFlags: [],
                                        timestamp: 0, windowNumber: overlay.window!.windowNumber, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testDraggingInAnUnflippedHostReturnsTopLeftProportionsAndRemovesOverlay() async throws {
        let (window, host, page) = fixture()
        defer { window.close() }
        let selection = Task { await PageScreenshotRegionSelector.select(over: page, isValid: { true }) }
        await Task.yield()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? PageScreenshotRegionSelector }.first)
        overlay.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 60, y: 80), in: overlay))
        overlay.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 240, y: 240), in: overlay))
        let result = await selection.value
        let region = try XCTUnwrap(result)
        XCTAssertEqual(region.rect, CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertNil(overlay.superview)
    }

    func testEscapeCancelsTinySelectionAndOriginInvalidationCancelsWithoutRetainingOverlay() async throws {
        let (window, host, page) = fixture()
        defer { window.close() }
        var valid = true
        let selection = Task { await PageScreenshotRegionSelector.select(over: page, isValid: { valid }) }
        await Task.yield()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? PageScreenshotRegionSelector }.first)
        overlay.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 30, y: 30), in: overlay))
        overlay.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 30, y: 30), in: overlay))
        XCTAssertNotNil(overlay.superview)
        overlay.cancelOperation(nil)
        let cancelled = await selection.value
        XCTAssertNil(cancelled)
        XCTAssertNil(overlay.superview)
        let invalidated = Task { await PageScreenshotRegionSelector.select(over: page, isValid: { valid }) }
        await Task.yield()
        valid = false
        let result = await invalidated.value
        XCTAssertNil(result)
        XCTAssertFalse(host.subviews.contains { $0 is PageScreenshotRegionSelector })
    }
}
