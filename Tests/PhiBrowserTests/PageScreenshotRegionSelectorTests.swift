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
        window.orderFront(nil)
        return (window, host, page)
    }

    private var viewport: PageScreenshotViewport {
        PageScreenshotViewport(rect: CGRect(x: 10, y: 500, width: 600, height: 400),
                               viewSize: CGSize(width: 600, height: 400), scale: 1)
    }

    private func event(_ type: NSEvent.EventType, _ point: CGPoint, in overlay: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: overlay.convert(point, to: nil), modifierFlags: [],
                                        timestamp: 0, windowNumber: overlay.window!.windowNumber, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testDraggingInAnUnflippedHostReturnsDocumentCoordinatesAndRemovesOverlay() async throws {
        let (window, host, page) = fixture()
        defer { window.close() }
        let selection = Task { await PageScreenshotRegionSelector.select(over: page, viewport: viewport, scroll: { _ in self.viewport }, isValid: { true }) }
        await Task.yield()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? PageScreenshotRegionSelector }.first)
        overlay.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 60, y: 80), in: overlay))
        overlay.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 240, y: 240), in: overlay))
        let result = await selection.value
        let region = try XCTUnwrap(result)
        XCTAssertEqual(region.rect, CGRect(x: 70, y: 580, width: 180, height: 160))
        XCTAssertNil(overlay.superview)
    }

    func testEscapeCancelsTinySelectionAndOriginInvalidationCancelsWithoutRetainingOverlay() async throws {
        let (window, host, page) = fixture()
        defer { window.close() }
        var valid = true
        let selection = Task { await PageScreenshotRegionSelector.select(over: page, viewport: viewport, scroll: { _ in self.viewport }, isValid: { valid }) }
        await Task.yield()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? PageScreenshotRegionSelector }.first)
        overlay.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 30, y: 30), in: overlay))
        overlay.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 30, y: 30), in: overlay))
        XCTAssertNotNil(overlay.superview)
        overlay.cancelOperation(nil)
        let cancelled = await selection.value
        XCTAssertNil(cancelled)
        XCTAssertNil(overlay.superview)
        let invalidated = Task { await PageScreenshotRegionSelector.select(over: page, viewport: viewport, scroll: { _ in self.viewport }, isValid: { valid }) }
        await Task.yield()
        valid = false
        let result = await invalidated.value
        XCTAssertNil(result)
        XCTAssertFalse(host.subviews.contains { $0 is PageScreenshotRegionSelector })
    }
    private func wheel(_ delta: Int32) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: delta, wheel2: 0, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    func testWheelScrollWaitsForInFlightMoveBeforeCompletingSelection() async throws {
        let (window, host, page) = fixture()
        defer { window.close() }
        var resumeScroll: CheckedContinuation<PageScreenshotViewport, Error>?
        let started = expectation(description: "Scroll started")
        let selection = Task {
            await PageScreenshotRegionSelector.select(over: page, viewport: viewport, scroll: { delta in
                XCTAssertGreaterThan(delta.height, 0)
                started.fulfill()
                return try await withCheckedThrowingContinuation { resumeScroll = $0 }
            }, isValid: { true })
        }
        await Task.yield()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? PageScreenshotRegionSelector }.first)
        overlay.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 60, y: 80), in: overlay))
        overlay.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 240, y: 240), in: overlay))
        overlay.scrollWheel(with: try wheel(-100))
        await fulfillment(of: [started], timeout: 2)
        overlay.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 240, y: 240), in: overlay))
        XCTAssertNotNil(overlay.superview)
        resumeScroll?.resume(returning: PageScreenshotViewport(rect: CGRect(x: 10, y: 1500, width: 600, height: 400),
                                                              viewSize: CGSize(width: 600, height: 400), scale: 1))
        let result = await selection.value
        XCTAssertEqual(result?.rect, CGRect(x: 70, y: 580, width: 180, height: 1160))
        XCTAssertNil(overlay.superview)
    }

    func testEdgeScrollExtendsSelectionUpwardWithoutMoreMouseMovement() async throws {
        let (window, host, page) = fixture()
        defer { window.close() }
        var count = 0
        let scrolled = expectation(description: "Edge scrolled twice")
        scrolled.expectedFulfillmentCount = 2
        let selection = Task {
            await PageScreenshotRegionSelector.select(over: page, viewport: viewport, scroll: { delta in
                XCTAssertLessThan(delta.height, 0)
                count += 1
                scrolled.fulfill()
                return PageScreenshotViewport(rect: CGRect(x: 10, y: 500 - 100 * count, width: 600, height: 400),
                                              viewSize: CGSize(width: 600, height: 400), scale: 1)
            }, isValid: { true })
        }
        await Task.yield()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? PageScreenshotRegionSelector }.first)
        overlay.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 300, y: 250), in: overlay))
        overlay.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 100, y: 0), in: overlay))
        // The same path is invoked repeatedly by the common-mode timer.
        overlay.updateScrolling()
        await Task.yield()
        overlay.updateScrolling()
        await fulfillment(of: [scrolled], timeout: 2)
        overlay.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 100, y: 0), in: overlay))
        let result = await selection.value
        XCTAssertEqual(result?.rect, CGRect(x: 110, y: 500 - 100 * count, width: 200, height: 250 + 100 * count))
        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertNil(overlay.superview)
    }

    func testCancelDuringScrollDiscardsLateResultAndDoesNotRestartScrolling() async throws {
        let (window, host, page) = fixture()
        defer { window.close() }
        var resumeScroll: CheckedContinuation<PageScreenshotViewport, Error>?
        let started = expectation(description: "Scroll started")
        var scrollCount = 0
        let selection = Task {
            await PageScreenshotRegionSelector.select(over: page, viewport: viewport, scroll: { _ in
                scrollCount += 1
                started.fulfill()
                return try await withCheckedThrowingContinuation { resumeScroll = $0 }
            }, isValid: { true })
        }
        await Task.yield()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? PageScreenshotRegionSelector }.first)
        overlay.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 60, y: 80), in: overlay))
        overlay.scrollWheel(with: try wheel(-100))
        await fulfillment(of: [started], timeout: 2)
        overlay.scrollWheel(with: try wheel(-100))
        overlay.cancelOperation(nil)
        let result = await selection.value
        XCTAssertNil(result)
        resumeScroll?.resume(returning: viewport)
        await Task.yield()
        overlay.updateScrolling()
        XCTAssertEqual(scrollCount, 1)
        XCTAssertNil(overlay.superview)
    }

    func testEdgeScrollIsBoundedAndInactiveInTheMiddle() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertEqual(PageScreenshotRegionSelector.edgeScrollDelta(at: CGPoint(x: 300, y: 200), in: bounds), .zero)
        XCTAssertEqual(PageScreenshotRegionSelector.edgeScrollDelta(at: CGPoint(x: -100, y: 1000), in: bounds),
                       CGSize(width: -40, height: 40))
    }

    func testLosingWindowFocusStopsAutomaticScrollingAndRemovesOverlay() async throws {
        let (window, host, page) = fixture()
        defer { window.close() }
        var scrollCount = 0
        let selection = Task {
            await PageScreenshotRegionSelector.select(over: page, viewport: viewport, scroll: { _ in
                scrollCount += 1
                return self.viewport
            }, isValid: { true })
        }
        await Task.yield()
        let overlay = try XCTUnwrap(host.subviews.compactMap { $0 as? PageScreenshotRegionSelector }.first)
        overlay.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 60, y: 80), in: overlay))
        overlay.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 240, y: 400), in: overlay))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertNil(overlay.superview)
        // Also clean up on failure so this regression does not leave a continuation suspended.
        if overlay.superview != nil { overlay.cancelOperation(nil) }
        let result = await selection.value
        XCTAssertNil(result)
        overlay.updateScrolling()
        await Task.yield()
        XCTAssertEqual(scrollCount, 0)
    }

}
