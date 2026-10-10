import AppKit
import XCTest
@testable import Phi

@MainActor
final class ScreenshotEditorInteractionTests: XCTestCase {
    private func model() -> ScreenshotEditorModel {
        let c = ScreenshotSceneRenderer.bitmapContext(width: 1000, height: 800)!
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
        return ScreenshotEditorModel(canvas: c.makeImage()!)
    }
    private func draw(_ m: ScreenshotEditorModel, _ tool: ScreenshotTool, _ a: CGPoint, _ b: CGPoint) {
        m.selectTool(tool); m.beginInteraction(at: a, tolerance: 6); m.continueInteraction(at: b); m.endInteraction()
    }
    private func marquee(_ m: ScreenshotEditorModel, _ a: CGPoint, _ b: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
        m.beginInteraction(at: a, tolerance: 6, modifiers: flags)
        m.continueInteraction(at: b, modifiers: flags); m.endInteraction()
    }
    private func twoObjects(_ m: ScreenshotEditorModel) -> [UUID] {
        draw(m, .rectangle, CGPoint(x: 40, y: 40), CGPoint(x: 100, y: 100))
        draw(m, .rectangle, CGPoint(x: 220, y: 40), CGPoint(x: 280, y: 100))
        return m.annotations.map(\.id)
    }
    func testNewDocumentIsOrdinaryAndEveryCompletedCreationReturnsToIt() {
        let m = model(); XCTAssertEqual(m.tool, .select)
        for tool in [ScreenshotTool.arrow, .freehand, .rectangle, .ellipse] {
            draw(m, tool, CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 300))
            XCTAssertEqual(m.tool, .select); XCTAssertFalse(m.isInteracting)
            XCTAssertEqual(m.selected?.kind.rawValue, tool.rawValue)
        }
        m.selectTool(.text); m.commitText("Hello", frame: CGRect(x: 100, y: 100, width: 280, height: 40))
        XCTAssertEqual(m.tool, .select)
        m.undo(); m.redo(); XCTAssertEqual(m.tool, .select)
    }
    func testShiftExplicitlyRepeatsToolAndReleaseReturnsToOrdinary() {
        let m = model(); m.selectTool(.arrow)
        m.beginInteraction(at: CGPoint(x: 100, y: 100), tolerance: 6, modifiers: .shift)
        m.continueInteraction(at: CGPoint(x: 300, y: 200), modifiers: .shift); m.endInteraction()
        XCTAssertEqual(m.tool, .arrow)
        m.beginInteraction(at: CGPoint(x: 100, y: 300), tolerance: 6)
        m.continueInteraction(at: CGPoint(x: 300, y: 400), modifiers: []); m.endInteraction()
        XCTAssertEqual(m.annotations.count, 2); XCTAssertEqual(m.tool, .select)
    }
    func testSelectingDrawingToolCannotResizePreviouslySelectedEndpoint() {
        let m = model(); draw(m, .arrow, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200))
        let original = m.annotations[0]
        m.selectTool(.freehand); XCTAssertFalse(m.hasSelection)
        m.beginInteraction(at: CGPoint(x: 300, y: 200), tolerance: 8)
        m.continueInteraction(at: CGPoint(x: 400, y: 300)); m.endInteraction()
        XCTAssertEqual(m.annotations[0], original); XCTAssertEqual(m.annotations.count, 2)
    }
    func testInvalidArrowAndSinglePointStrokeLeaveNoUndoObject() {
        let m = model()
        for tool in [ScreenshotTool.arrow, .freehand] {
            m.selectTool(tool); m.beginInteraction(at: CGPoint(x: 100, y: 100), tolerance: 6); m.endInteraction()
            XCTAssertTrue(m.annotations.isEmpty); XCTAssertFalse(m.canUndo); XCTAssertEqual(m.tool, .select)
        }
    }
    func testMarqueePreviewPreservesHistoryAndShiftAddsWhileCommandSubtracts() {
        let m = model(), ids = twoObjects(m)
        m.select(nil)
        m.beginInteraction(at: CGPoint(x: 5, y: 5), tolerance: 6)
        m.continueInteraction(at: CGPoint(x: 120, y: 120))
        XCTAssertTrue(m.selectedIDs.isEmpty); XCTAssertEqual(m.displayedSelection, [ids[0]])
        m.endInteraction(); XCTAssertEqual(m.selectedIDs, [ids[0]])
        marquee(m, CGPoint(x: 180, y: 5), CGPoint(x: 320, y: 120), [.shift, .command])
        XCTAssertEqual(m.selectedIDs, Set(ids), "Shift wins for marquee")
        marquee(m, CGPoint(x: 5, y: 5), CGPoint(x: 120, y: 120), .command)
        XCTAssertEqual(m.selectedIDs, [ids[1]])
        marquee(m, CGPoint(x: 5, y: 5), CGPoint(x: 120, y: 120), .command)
        XCTAssertEqual(m.selectedIDs, [ids[1]], "Command subtracts, never toggles absent objects on")
        XCTAssertEqual(m.generation, 2)
    }
    func testCancelledMarqueeRestoresPersistentSelection() {
        let m = model(), ids = twoObjects(m); m.select(ids: [ids[1]])
        m.beginInteraction(at: CGPoint(x: 5, y: 5), tolerance: 6)
        m.continueInteraction(at: CGPoint(x: 120, y: 120)); m.cancelInteraction()
        XCTAssertEqual(m.selectedIDs, [ids[1]]); XCTAssertNil(m.marquee); XCTAssertTrue(m.previewSelection.isEmpty)
    }
    func testClickCommandTogglesButShiftPreservesAndPlainClickCollapsesGroup() {
        let m = model(), ids = twoObjects(m); m.select(ids: Set(ids))
        func click(_ flags: NSEvent.ModifierFlags) {
            m.beginInteraction(at: CGPoint(x: 70, y: 40), tolerance: 2, modifiers: flags); m.endInteraction()
        }
        click(.command); XCTAssertEqual(m.selectedIDs, [ids[1]])
        click(.command); XCTAssertEqual(m.selectedIDs, Set(ids))
        click(.shift); XCTAssertEqual(m.selectedIDs, Set(ids))
        click([]); XCTAssertEqual(m.selectedIDs, [ids[0]])
        XCTAssertEqual(m.generation, 2)
    }
    func testShortMoveRollsBackButCumulativeDistanceUsesAllStepsAtPreviewScale() {
        let m = model(); draw(m, .arrow, CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100)); m.setZoomExact(0.5)
        let original = m.annotations
        m.beginInteraction(at: CGPoint(x: 300, y: 100), tolerance: 6)
        m.continueInteraction(at: CGPoint(x: 304, y: 100)); m.endInteraction()
        XCTAssertEqual(m.annotations, original); XCTAssertEqual(m.generation, 1)
        m.beginInteraction(at: CGPoint(x: 300, y: 100), tolerance: 6)
        m.continueInteraction(at: CGPoint(x: 310, y: 100))
        m.continueInteraction(at: CGPoint(x: 302, y: 100)); m.endInteraction()
        XCTAssertEqual(m.annotations[0].points[0].x, 102); XCTAssertEqual(m.generation, 2)
        m.undo(); XCTAssertEqual(m.annotations, original)
    }
    func testGroupMoveResizeDeleteAndUndoPreserveRelativeGeometryAsOneOperation() {
        let m = model(), ids = twoObjects(m); m.select(ids: Set(ids))
        let original = m.annotations
        m.beginInteraction(at: CGPoint(x: 70, y: 40), tolerance: 2)
        m.continueInteraction(at: CGPoint(x: 90, y: 60)); m.endInteraction()
        XCTAssertEqual(m.annotations[0].bounds.origin, CGPoint(x: 60, y: 60))
        XCTAssertEqual(m.annotations[1].bounds.origin, CGPoint(x: 240, y: 60))
        XCTAssertEqual(m.selectedIDs, Set(ids)); m.undo(); XCTAssertEqual(m.annotations, original)
        m.beginInteraction(at: CGPoint(x: 280, y: 100), tolerance: 6)
        m.continueInteraction(at: CGPoint(x: 380, y: 200), mirrored: true); m.endInteraction()
        XCTAssertEqual(m.selectionBounds, CGRect(x: -60, y: -60, width: 440, height: 260))
        m.undo(); XCTAssertEqual(m.annotations, original)
        m.deleteSelection(); XCTAssertTrue(m.annotations.isEmpty)
        m.undo(); XCTAssertEqual(m.annotations, original); XCTAssertEqual(m.selectedIDs, Set(ids))
    }
    func testCrossedFrameHandleReflectsFreehandPointsWithoutMinimumClamp() {
        let item = ScreenshotAnnotation(kind: .freehand, points: [CGPoint(x: 40, y: 40), CGPoint(x: 70, y: 80), CGPoint(x: 140, y: 60)])
        let resized = item.editing(handle: .right, at: CGPoint(x: 20, y: 60))
        XCTAssertEqual(resized.bounds, CGRect(x: 20, y: 40, width: 20, height: 40))
        XCTAssertEqual(resized.points[0].x, 40); XCTAssertEqual(resized.points[2].x, 20)
        XCTAssertEqual(item.editing(handle: .right, at: CGPoint(x: 41, y: 60)).bounds.width, 1)
        let mirror = item.editing(handle: .right, at: CGPoint(x: 160, y: 60), mirrored: true)
        XCTAssertEqual(mirror.bounds, CGRect(x: 20, y: 40, width: 140, height: 40))
    }
    func testArrowUsesOpen45DegreeWingsAndFreehandKeepsLineSegments() throws {
        var arrow = ScreenshotAnnotation(kind: .arrow, points: [.zero, CGPoint(x: 100, y: 0)])
        arrow.style.arrowHeadLength = 32
        var types: [CGPathElementType] = [], points: [CGPoint] = []
        try XCTUnwrap(arrow.arrowHead).applyWithBlock { e in types.append(e.pointee.type); points.append(e.pointee.points[0]) }
        XCTAssertEqual(types, [.moveToPoint, .addLineToPoint, .addLineToPoint])
        XCTAssertEqual(points[0].x, 100 - 30 / sqrt(2), accuracy: 0.00001)
        XCTAssertEqual(abs(points[0].y), 30 / sqrt(2), accuracy: 0.00001)
        let freehand = ScreenshotAnnotation(kind: .freehand, points: [.zero, CGPoint(x: 10, y: 30), CGPoint(x: 40, y: 5)])
        types = []; freehand.path.applyWithBlock { types.append($0.pointee.type) }
        XCTAssertEqual(types, [.moveToPoint, .addLineToPoint, .addLineToPoint])
    }
    func testMultiSelectionStyleChangesOnlyRequestedFieldAndUndoIsAggregate() {
        let m = model(), ids = twoObjects(m)
        m.select(ids[0]); m.brushSize = 16
        m.select(ids[1]); m.brushSize = 8
        m.select(ids: Set(ids)); let before = m.annotations
        m.foreground = ScreenshotColor(red: 0, green: 0, blue: 1)
        XCTAssertEqual(m.annotations.map { $0.style.width }, [16, 8])
        XCTAssertTrue(m.annotations.allSatisfy { $0.style.color.blue == 1 })
        m.undo(); XCTAssertEqual(m.annotations, before)
    }
    func testMultilineTextShrinksAndCommandKeypadEnterCommitsThenReturnsToSelect() throws {
        let m = model(), canvas = ScreenshotCanvasView()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; canvas.model = m; window.contentView = canvas; canvas.invalidateCanvasSize()
        defer { window.close() }
        m.selectTool(.text); canvas.beginText(at: CGPoint(x: 100, y: 100))
        let entry = try XCTUnwrap(canvas.textEntry)
        entry.insertText("One\nTwo\nThree\nFour", replacementRange: NSRange(location: NSNotFound, length: 0))
        let expanded = entry.frame.height
        entry.insertText("One", replacementRange: NSRange(location: 0, length: entry.string.utf16.count))
        XCTAssertLessThan(entry.frame.height, expanded)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 76))
        entry.keyDown(with: event)
        XCTAssertNil(canvas.textEntry); XCTAssertFalse(m.isEditingText); XCTAssertEqual(m.tool, .select)
        XCTAssertEqual(m.selected?.text, "One"); XCTAssertEqual(m.generation, 1)
        m.undo(); XCTAssertTrue(m.annotations.isEmpty)
    }
    func testHandleHitSlopDoesNotMoveGeometryWithoutPointerTranslation() {
        let m = model(); draw(m, .arrow, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200))
        let before = m.annotations, generation = m.generation
        m.beginInteraction(at: CGPoint(x: 304, y: 204), tolerance: 7)
        m.continueInteraction(at: CGPoint(x: 304, y: 204)); m.endInteraction()
        XCTAssertEqual(m.annotations, before); XCTAssertEqual(m.generation, generation)
        m.beginInteraction(at: CGPoint(x: 304, y: 204), tolerance: 7)
        m.continueInteraction(at: CGPoint(x: 314, y: 214)); m.endInteraction()
        XCTAssertEqual(m.annotations[0].points[1], CGPoint(x: 310, y: 210))
    }
    func testTextFontFitsSmallerBoxWithoutChangingStoredFontOrOrigin() {
        var item = ScreenshotAnnotation(kind: .text, frame: CGRect(x: 50, y: 60, width: 240, height: 90), text: "A paragraph that wraps on multiple lines.")
        item.style.fontSize = 44
        let font = ScreenshotSceneRenderer.fittedFontSize(for: item)
        let smaller = item.editing(handle: .bottom, at: CGPoint(x: 170, y: 100))
        XCTAssertLessThan(ScreenshotSceneRenderer.fittedFontSize(for: smaller), font)
        XCTAssertEqual(smaller.style.fontSize, 44); XCTAssertEqual(smaller.frame.origin, item.frame.origin)
    }
    func testOptionMirrorReflectionUsesOriginalExtentThreshold() {
        let item = ScreenshotAnnotation(kind: .freehand, points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200)])
        let resized = item.editing(handle: .right, at: CGPoint(x: 140, y: 150), mirrored: true)
        XCTAssertEqual(resized.bounds, CGRect(x: 140, y: 100, width: 20, height: 100))
        XCTAssertEqual(resized.points[0].x, 140, "Reflection compares against original width before mirror adjustment")
        XCTAssertEqual(resized.points[1].x, 160)
    }
    func testOutOfBoundsDragIsNotMisclassifiedAsCommandClick() {
        let m = model(); draw(m, .arrow, CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 500))
        let id = m.selectedID
        m.beginInteraction(at: CGPoint(x: 0, y: 300), tolerance: 2, modifiers: .command)
        m.continueInteraction(at: CGPoint(x: -20, y: 300), modifiers: .command); m.endInteraction()
        XCTAssertEqual(m.selectedID, id)
    }
    func testShortTextFrameStillDrawsGlyphsAfterNativeEditingCommits() throws {
        let m = model(), canvas = ScreenshotCanvasView()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; canvas.model = m; window.contentView = canvas; canvas.zoom = 0.36
        canvas.invalidateCanvasSize(); defer { window.close() }
        canvas.beginText(at: CGPoint(x: 100, y: 100))
        let entry = try XCTUnwrap(canvas.textEntry)
        XCTAssertFalse(m.textCanUndo); XCTAssertFalse(m.textCanRedo)
        entry.insertText("Editable text", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.refreshTextHistory(); XCTAssertTrue(m.textCanUndo); XCTAssertFalse(m.textCanRedo)
        entry.undoManager?.undo(); canvas.refreshTextHistory()
        XCTAssertFalse(m.textCanUndo); XCTAssertTrue(m.textCanRedo)
        entry.undoManager?.redo(); canvas.commitText()
        XCTAssertFalse(m.isEditingText); XCTAssertFalse(m.textCanRedo)
        let object = try XCTUnwrap(m.selected)
        XCTAssertEqual(object.text, "Editable text")
        let image = try XCTUnwrap(ScreenshotImageExport.decode(data: ScreenshotImageExport.encode(m.snapshot(), format: .jpg)))
        let context = ScreenshotSceneRenderer.bitmapContext(width: 1000, height: 800)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var redPixels = 0
        for y in 100..<Int(ceil(object.frame.maxY)) {
            for x in 100..<380 {
                let offset = y * context.bytesPerRow + x * 4
                if Int(pixels[offset]) > Int(pixels[offset + 1]) + 70 { redPixels += 1 }
            }
        }
        XCTAssertGreaterThan(redPixels, 40, "A committed short text frame must render glyphs, not an empty selection box")
    }
    func testNativePointerSecondGestureDoesNotCreateAnotherArrow() throws {
        let m = model(), canvas = ScreenshotCanvasView()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; canvas.model = m; window.contentView = canvas; canvas.invalidateCanvasSize()
        defer { window.close() }
        func event(_ type: NSEvent.EventType, _ p: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        m.selectTool(.arrow)
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 300, y: 200)))
        XCTAssertEqual(m.tool, .select)
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 500, y: 500)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 700, y: 700)))
        XCTAssertEqual(m.annotations.count, 1); XCTAssertFalse(m.hasSelection)
    }
}
