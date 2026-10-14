import AppKit
import XCTest
@testable import Phi

@MainActor
final class ScreenshotCropTests: XCTestCase {
    private func model() -> ScreenshotEditorModel {
        let context = ScreenshotSceneRenderer.bitmapContext(width: 1000, height: 800)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
        context.translateBy(x: 0, y: 800); context.scaleBy(x: 1, y: -1)
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 100, y: 100, width: 80, height: 80))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 100, y: 400, width: 80, height: 80))
        return ScreenshotEditorModel(canvas: context.makeImage()!)
    }
    private func draw(_ m: ScreenshotEditorModel, _ tool: ScreenshotTool, _ a: CGPoint, _ b: CGPoint) {
        m.selectTool(tool); m.beginInteraction(at: a, tolerance: 6); m.continueInteraction(at: b); m.endInteraction()
    }
    private func selectCrop(_ m: ScreenshotEditorModel, _ a: CGPoint = CGPoint(x: 100, y: 100), _ b: CGPoint = CGPoint(x: 500, y: 500)) {
        m.selectTool(.crop); m.beginInteraction(at: a, tolerance: 6); m.continueInteraction(at: b); m.endInteraction()
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let context = ScreenshotSceneRenderer.bitmapContext(width: image.width, height: image.height)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self), offset = y * context.bytesPerRow + x * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
    func testCropOverObjectsAndHandlesIgnoresSelectionModifiersUntilConfirmation() {
        let m = model()
        draw(m, .rectangle, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300))
        m.commitText("Still editable", frame: CGRect(x: 120, y: 120, width: 160, height: 50))
        let before = m.annotations, source = m.source, generation = m.generation
        for flags: NSEvent.ModifierFlags in [[], .shift, .command, [.shift, .command, .option]] {
            m.selectTool(.crop)
            m.beginInteraction(at: CGPoint(x: 100, y: 100), tolerance: 20, moving: true, modifiers: flags)
            m.continueInteraction(at: CGPoint(x: 400, y: 400), mirrored: true, modifiers: flags)
            XCTAssertFalse(m.canCrop); XCTAssertTrue(m.selectedIDs.isEmpty); XCTAssertTrue(m.displayedSelection.isEmpty)
            m.endInteraction(); m.selectAll(); m.select(ids: Set(before.map(\.id)))
            XCTAssertTrue(m.canCrop); XCTAssertTrue(m.selectedIDs.isEmpty); XCTAssertEqual(m.tool, .crop)
            XCTAssertEqual(m.cropRect, CGRect(x: 100, y: 100, width: 300, height: 300))
            XCTAssertEqual(m.annotations, before); XCTAssertTrue(m.source === source); XCTAssertEqual(m.generation, generation)
        }
    }
    func testReverseSelectionClampsAndRoundsToSourcePixelsIndependentOfZoom() {
        let m = model(); m.setZoomExact(0.5)
        selectCrop(m, CGPoint(x: 400.4, y: 320.2), CGPoint(x: -40, y: 70.8))
        XCTAssertEqual(m.cropRect, CGRect(x: 0, y: 70, width: 401, height: 251))
        m.cropToSelection(); XCTAssertEqual(m.width, 401); XCTAssertEqual(m.height, 251)
        XCTAssertEqual(m.tool, .select); XCTAssertNil(m.cropRect)
    }
    func testCropWithoutAnnotationsIsOneUndoableImageTransaction() {
        let m = model(), original = m.source, snapshot = m.snapshot()
        selectCrop(m); XCTAssertFalse(m.canUndo); XCTAssertEqual(m.generation, 0)
        m.cropToSelection(); let cropped = m.source
        XCTAssertEqual(m.width, 400); XCTAssertEqual(m.height, 400); XCTAssertEqual(m.generation, 1)
        XCTAssertEqual(m.undoManager.undoActionName, "Crop"); XCTAssertTrue(m.annotations.isEmpty)
        XCTAssertEqual(snapshot.width, 1000); XCTAssertTrue(snapshot.source === original)
        m.undo(); XCTAssertTrue(m.source === original); XCTAssertFalse(m.canUndo); XCTAssertTrue(m.canRedo)
        XCTAssertEqual(m.width, 1000); XCTAssertEqual(m.height, 800)
        m.redo(); XCTAssertTrue(m.source === cropped); XCTAssertEqual(m.width, 400); XCTAssertFalse(m.canRedo)
    }
    func testCropRetainsEditableOverlappingObjectsAndUndoRestoresRemovedObjects() {
        let m = model()
        draw(m, .arrow, CGPoint(x: 50, y: 200), CGPoint(x: 350, y: 200))
        draw(m, .rectangle, CGPoint(x: 200, y: 250), CGPoint(x: 300, y: 350))
        draw(m, .ellipse, CGPoint(x: 650, y: 600), CGPoint(x: 750, y: 700))
        m.commitText("Inside", frame: CGRect(x: 220, y: 120, width: 180, height: 60))
        let original = m.annotations, source = m.source
        selectCrop(m); m.cropToSelection()
        let expected = [original[0], original[1], original[3]].map { $0.translated(by: CGPoint(x: -100, y: -100)) }
        XCTAssertEqual(m.annotations, expected)
        XCTAssertEqual(m.annotations[0].points[0].x, -50)
        m.select(expected[0].id); m.moveSelection(by: CGPoint(x: 1, y: 0))
        XCTAssertEqual(m.annotations[0].points[0].x, -49, "A clipped object must not jump back inside the new canvas")
        m.undo(); XCTAssertEqual(m.annotations, expected)
        m.undo(); XCTAssertTrue(m.source === source); XCTAssertEqual(m.annotations, original)
        m.redo(); XCTAssertEqual(m.annotations, expected); XCTAssertEqual(m.width, 400)
    }
    func testMultipleCropsAndAnnotationEditsShareTheSameUndoOrder() {
        let m = model(), original = m.source
        selectCrop(m); m.cropToSelection(); let first = m.source
        draw(m, .rectangle, CGPoint(x: 120, y: 120), CGPoint(x: 200, y: 200)); let objects = m.annotations
        selectCrop(m, CGPoint(x: 50, y: 50), CGPoint(x: 300, y: 300)); m.cropToSelection(); let second = m.source
        m.undo(); XCTAssertTrue(m.source === first); XCTAssertEqual(m.annotations, objects)
        m.undo(); XCTAssertTrue(m.annotations.isEmpty); XCTAssertTrue(m.source === first)
        m.undo(); XCTAssertTrue(m.source === original); XCTAssertFalse(m.canUndo)
        m.redo(); m.redo(); m.redo(); XCTAssertTrue(m.source === second); XCTAssertEqual(m.width, 250)
        m.undo(); selectCrop(m, .zero, CGPoint(x: 200, y: 200)); m.cropToSelection()
        XCTAssertFalse(m.canRedo); XCTAssertEqual(m.width, 200)
    }
    func testCancelledTinyAndWholeImageSelectionsDoNotAddUndoHistory() {
        let m = model(), original = m.source
        selectCrop(m); let previous = m.cropRect
        m.beginInteraction(at: CGPoint(x: 20, y: 20), tolerance: 6)
        m.continueInteraction(at: CGPoint(x: 60, y: 60)); m.cancelInteraction()
        XCTAssertEqual(m.cropRect, previous)
        m.selectTool(.select); XCTAssertNil(m.cropRect); XCTAssertFalse(m.canUndo)
        selectCrop(m, .zero, CGPoint(x: 1, y: 400)); XCTAssertNil(m.cropRect)
        selectCrop(m, .zero, CGPoint(x: 2000, y: 2000)); m.cropToSelection()
        XCTAssertTrue(m.source === original); XCTAssertEqual(m.tool, .select); XCTAssertFalse(m.canUndo); XCTAssertEqual(m.generation, 0)
    }
    func testCroppedExportUsesNewPixelBoundsTopLeftOriginAndTranslatedAnnotations() throws {
        let m = model()
        m.foreground = ScreenshotColor(red: 0, green: 0.8, blue: 0); m.filled = true
        draw(m, .rectangle, CGPoint(x: 300, y: 200), CGPoint(x: 380, y: 280))
        selectCrop(m); m.cropToSelection(); m.setZoomExact(0.2)
        let snapshot = m.snapshot()
        let jpg = try XCTUnwrap(ScreenshotImageExport.decode(data: ScreenshotImageExport.encode(snapshot, format: .jpg)))
        XCTAssertEqual(jpg.width, 400); XCTAssertEqual(jpg.height, 400)
        XCTAssertGreaterThan(pixel(jpg, x: 20, y: 20).r, 230); XCTAssertLessThan(pixel(jpg, x: 20, y: 20).b, 30)
        XCTAssertGreaterThan(pixel(jpg, x: 20, y: 320).b, 230); XCTAssertLessThan(pixel(jpg, x: 20, y: 320).r, 30)
        XCTAssertGreaterThan(pixel(jpg, x: 230, y: 130).g, 180); XCTAssertLessThan(pixel(jpg, x: 230, y: 130).r, 100)
        let pdf = try ScreenshotImageExport.encode(snapshot, format: .pdf)
        let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: pdf as CFData))))
        let page = try XCTUnwrap(document.page(at: 1)); XCTAssertEqual(document.numberOfPages, 1)
        XCTAssertEqual(page.getBoxRect(.mediaBox), CGRect(x: 0, y: 0, width: 400, height: 400))
        let context = ScreenshotSceneRenderer.bitmapContext(width: 400, height: 400)!; context.drawPDFPage(page)
        let rendered = try XCTUnwrap(context.makeImage())
        XCTAssertGreaterThan(pixel(rendered, x: 20, y: 20).r, 230)
        XCTAssertGreaterThan(pixel(rendered, x: 20, y: 320).b, 230)
        XCTAssertGreaterThan(pixel(rendered, x: 230, y: 130).g, 180)
    }
    private func fixture(zoom: Double = 1) -> (ScreenshotEditorModel, ScreenshotCanvasView, NSScrollView, NSWindow) {
        let m = model(), canvas = ScreenshotCanvasView(), scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        m.setZoomExact(zoom); canvas.zoom = zoom; canvas.model = m
        scroll.documentView = canvas; scroll.contentView.postsBoundsChangedNotifications = true
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; canvas.invalidateCanvasSize()
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        return (m, canvas, scroll, window)
    }
    private func event(_ type: NSEvent.EventType, window: NSWindow, point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func testCanvasShowsConfirmationOnlyAfterMouseUpAndUpdatesImageOnCropAndUndo() throws {
        let (m, canvas, _, window) = fixture(); defer { window.close() }
        draw(m, .rectangle, CGPoint(x: 20, y: 20), CGPoint(x: 200, y: 180))
        let objects = m.annotations, original = m.source
        m.selectTool(.crop)
        canvas.mouseDown(with: event(.leftMouseDown, window: window, point: canvas.convert(CGPoint(x: 20, y: 20), to: nil)))
        let end = canvas.convert(CGPoint(x: 200, y: 180), to: nil)
        canvas.mouseDragged(with: event(.leftMouseDragged, window: window, point: end))
        XCTAssertFalse(m.canCrop); XCTAssertTrue(m.selectedIDs.isEmpty); XCTAssertEqual(m.annotations, objects)
        canvas.mouseUp(with: event(.leftMouseUp, window: window, point: end))
        XCTAssertTrue(m.canCrop)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        canvas.keyDown(with: enter)
        XCTAssertEqual(m.width, 180); XCTAssertEqual(m.height, 160); XCTAssertEqual(m.tool, .select)
        XCTAssertFalse(m.canCrop); XCTAssertTrue(canvas.backgroundImage === m.source)
        XCTAssertEqual(canvas.frame.size, CGSize(width: 180, height: 160))
        m.undo(); canvas.synchronize(); XCTAssertTrue(canvas.backgroundImage === original); XCTAssertEqual(m.annotations, objects)
        selectCrop(m); canvas.synchronize(); canvas.cancelOperation(nil)
        XCTAssertFalse(m.canCrop); XCTAssertNil(m.cropRect); XCTAssertEqual(m.tool, .select)
    }
    func testStationaryDragAutoscrollsBothAxesAndStopsAfterMouseUp() throws {
        let (m, canvas, scroll, window) = fixture(); defer { window.close() }
        m.selectTool(.crop)
        let anchor = CGPoint(x: 30, y: 30)
        canvas.mouseDown(with: event(.leftMouseDown, window: window, point: canvas.convert(anchor, to: nil)))
        let outside = canvas.convert(CGPoint(x: 340, y: 260), to: nil)
        canvas.mouseDragged(with: event(.leftMouseDragged, window: window, point: outside))
        let initial = scroll.contentView.bounds.origin
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.18))
        let continued = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(continued.x, initial.x); XCTAssertGreaterThan(continued.y, initial.y)
        let rect = try XCTUnwrap(m.cropRect)
        XCTAssertEqual(rect.origin, anchor); XCTAssertGreaterThan(rect.maxX, 340); XCTAssertGreaterThan(rect.maxY, 260)
        canvas.mouseUp(with: event(.leftMouseUp, window: window, point: outside)); let stopped = scroll.contentView.bounds.origin
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        XCTAssertEqual(scroll.contentView.bounds.origin, stopped); XCTAssertTrue(m.canCrop)
    }
    func testAutoscrollSupportsReverseDragAtZoomAndStopsWhenCancelled() throws {
        let (m, canvas, scroll, window) = fixture(zoom: 2); defer { window.close() }
        scroll.contentView.scroll(to: CGPoint(x: 300, y: 300)); scroll.reflectScrolledClipView(scroll.contentView)
        m.selectTool(.crop)
        let anchor = CGPoint(x: 500, y: 450)
        canvas.mouseDown(with: event(.leftMouseDown, window: window, point: canvas.convert(anchor, to: nil)))
        let outside = canvas.convert(CGPoint(x: 280, y: 280), to: nil)
        canvas.mouseDragged(with: event(.leftMouseDragged, window: window, point: outside))
        let initial = scroll.contentView.bounds.origin
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.14))
        XCTAssertLessThan(scroll.contentView.bounds.minX, initial.x); XCTAssertLessThan(scroll.contentView.bounds.minY, initial.y)
        let rect = try XCTUnwrap(m.cropRect)
        XCTAssertEqual(rect.maxX, anchor.x / 2); XCTAssertEqual(rect.maxY, anchor.y / 2)
        canvas.cancelOperation(nil); let stopped = scroll.contentView.bounds.origin
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        XCTAssertEqual(scroll.contentView.bounds.origin, stopped); XCTAssertNil(m.cropRect); XCTAssertFalse(m.isInteracting)
    }
    func testOrdinaryMarqueeUsesTheSameContinuousAutoscrollAndToolChangeStopsIt() {
        let (m, canvas, scroll, window) = fixture(); defer { window.close() }
        canvas.mouseDown(with: event(.leftMouseDown, window: window, point: canvas.convert(CGPoint(x: 30, y: 30), to: nil)))
        let outside = canvas.convert(CGPoint(x: 340, y: 260), to: nil)
        canvas.mouseDragged(with: event(.leftMouseDragged, window: window, point: outside))
        let initial = scroll.contentView.bounds.origin
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, initial.y); XCTAssertNotNil(m.marquee)
        m.selectTool(.arrow); let stopped = scroll.contentView.bounds.origin
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        XCTAssertEqual(scroll.contentView.bounds.origin, stopped); XCTAssertFalse(m.isInteracting)
    }
    func testCropCanMoveAndResizeWithoutChangingDocumentUntilApplied() {
        let m = model()
        selectCrop(m)
        let original = m.source
        m.beginInteraction(at: CGPoint(x: 250, y: 250), tolerance: 6)
        m.continueInteraction(at: CGPoint(x: 950, y: 750)); m.endInteraction()
        XCTAssertEqual(m.cropRect, CGRect(x: 600, y: 400, width: 400, height: 400))
        XCTAssertTrue(m.source === original); XCTAssertFalse(m.canUndo)
        m.beginInteraction(at: CGPoint(x: 602, y: 402), tolerance: 6)
        m.continueInteraction(at: CGPoint(x: 502, y: 302)); m.endInteraction()
        XCTAssertEqual(m.cropRect, CGRect(x: 500, y: 300, width: 500, height: 500))
        XCTAssertFalse(m.canUndo); XCTAssertEqual(m.generation, 0)
        m.cropToSelection(); XCTAssertEqual(m.width, 500); XCTAssertEqual(m.height, 500)
        m.undo(); XCTAssertTrue(m.source === original); XCTAssertFalse(m.canUndo)
    }
    func testCancelCropHandleDragRestoresPreviousSelection() {
        let m = model(); selectCrop(m)
        let before = m.cropRect
        m.beginInteraction(at: CGPoint(x: 100, y: 100), tolerance: 6)
        m.continueInteraction(at: CGPoint(x: 40, y: 50)); m.cancelInteraction()
        XCTAssertEqual(m.cropRect, before); XCTAssertTrue(m.canCrop); XCTAssertFalse(m.canUndo)
    }

}
