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
        for tool in [ScreenshotTool.arrow, .freehand, .rectangle, .ellipse, .mosaic] {
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
    func testArrowUsesOpen45DegreeWings() throws {
        var arrow = ScreenshotAnnotation(kind: .arrow, points: [.zero, CGPoint(x: 100, y: 0)])
        arrow.style.arrowHeadLength = 32
        var types: [CGPathElementType] = [], points: [CGPoint] = []
        try XCTUnwrap(arrow.arrowHead).applyWithBlock { e in types.append(e.pointee.type); points.append(e.pointee.points[0]) }
        XCTAssertEqual(types, [.moveToPoint, .addLineToPoint, .addLineToPoint])
        XCTAssertEqual(points[0].x, 100 - 30 / sqrt(2), accuracy: 0.00001)
        XCTAssertEqual(abs(points[0].y), 30 / sqrt(2), accuracy: 0.00001)
    }
    func testFreehandSmoothsCornersAndHitTestsVisibleCurve() {
        let samples = [CGPoint(x: 20, y: 100), CGPoint(x: 100, y: 20), CGPoint(x: 180, y: 100)]
        let stroke = ScreenshotAnnotation(kind: .freehand, points: samples)
        var types: [CGPathElementType] = []
        stroke.path.applyWithBlock { types.append($0.pointee.type) }
        XCTAssertEqual(types, [.moveToPoint, .addLineToPoint, .addQuadCurveToPoint, .addLineToPoint])
        XCTAssertTrue(stroke.contains(CGPoint(x: 100, y: 40), tolerance: 1))
        XCTAssertFalse(stroke.contains(samples[1], tolerance: 1), "The original sharp corner is no longer painted")
        XCTAssertTrue(stroke.contains(samples[0], tolerance: 1))
        XCTAssertTrue(stroke.contains(samples[2], tolerance: 1))
        XCTAssertEqual(stroke.points, samples)
        XCTAssertEqual(stroke.path.currentPoint, samples[2])
        XCTAssertTrue(stroke.bounds.contains(stroke.path.boundingBoxOfPath))
    }
    func testFreehandHandlesEmptyShortAndRepeatedSamples() {
        XCTAssertTrue(ScreenshotAnnotation(kind: .freehand).path.isEmpty)
        let a = CGPoint(x: 20, y: 30), b = CGPoint(x: 140, y: 90)
        for samples in [[a], [a, b], [a, a, a], [a, a, b, b]] {
            let stroke = ScreenshotAnnotation(kind: .freehand, points: samples)
            XCTAssertEqual(stroke.path.currentPoint, samples.last)
            XCTAssertEqual(stroke.points, samples)
            XCTAssertTrue(stroke.path.boundingBoxOfPath.origin.x.isFinite)
            if samples.count == 2 {
                var types: [CGPathElementType] = []
                stroke.path.applyWithBlock { types.append($0.pointee.type) }
                XCTAssertEqual(types, [.moveToPoint, .addLineToPoint])
                XCTAssertTrue(stroke.contains(CGPoint(x: 80, y: 60), tolerance: 1))
            }
        }
    }
    func testFreehandCompletionAndUndoPreserveSmoothedPreview() throws {
        let m = model()
        let samples = [CGPoint(x: 20, y: 100), CGPoint(x: 100, y: 20),
                       CGPoint(x: 180, y: 100), CGPoint(x: 240, y: 40)]
        m.selectTool(.freehand); m.beginInteraction(at: samples[0], tolerance: 2)
        for point in samples.dropFirst() { m.continueInteraction(at: point) }
        let preview = try XCTUnwrap(m.annotations.first)
        m.endInteraction()
        XCTAssertEqual(m.selected?.path, preview.path, "Finishing must not reshape the preview")
        XCTAssertEqual(m.selected?.points, samples)
        m.undo(); XCTAssertTrue(m.annotations.isEmpty)
        m.redo(); XCTAssertEqual(m.selected, preview)
        let moved = preview.translated(by: CGPoint(x: 30, y: 50))
        XCTAssertTrue(moved.contains(CGPoint(x: 130, y: 90), tolerance: 1))
        let resized = preview.resized(to: CGRect(x: 20, y: 20, width: 440, height: 160))
        XCTAssertTrue(resized.contains(CGPoint(x: 180, y: 60), tolerance: 1))
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
    func testTextWidthHandlesReflowAtFixedFontAndPreserveTopEdge() throws {
        let m = model()
        m.textSize = 44
        m.commitText("A paragraph that wraps on multiple lines.", frame: CGRect(x: 50, y: 60, width: 480, height: 1))
        let original = try XCTUnwrap(m.selected)
        XCTAssertEqual(m.selectionHandles.map(\.0), [.left, .right])
        let right = try XCTUnwrap(m.selectionHandles.last?.1)
        m.beginInteraction(at: right, tolerance: 2)
        m.continueInteraction(at: CGPoint(x: right.x - 240, y: right.y + 100))
        m.endInteraction()
        let narrow = try XCTUnwrap(m.selected)
        XCTAssertEqual(narrow.frame.width, 240)
        XCTAssertGreaterThan(narrow.frame.height, original.frame.height)
        XCTAssertEqual(narrow.style.fontSize, 44)
        XCTAssertEqual(narrow.frame.origin, original.frame.origin)
        XCTAssertEqual(narrow.editing(handle: .bottom, at: .zero), narrow)
        let left = narrow.editing(handle: .left, at: CGPoint(x: 100, y: 700))
        XCTAssertEqual(left.frame.maxX, narrow.frame.maxX)
        XCTAssertEqual(left.frame.minY, narrow.frame.minY)
        let minimum = narrow.editing(handle: .right, at: .zero)
        XCTAssertEqual(minimum.frame.width, 12)
        XCTAssertEqual(minimum.style.fontSize, 44)
        let mirrored = narrow.editing(handle: .left, at: CGPoint(x: 100, y: 700), mirrored: true)
        XCTAssertEqual(mirrored.frame.midX, narrow.frame.midX)
        XCTAssertEqual(mirrored.frame.minY, narrow.frame.minY)
        m.undo(); XCTAssertEqual(m.selected, original)
        m.redo(); XCTAssertEqual(m.selected, narrow)
    }

    func testTextHeightTracksFontChangesContentAndGroupResize() throws {
        let m = model()
        m.commitText("First line\nSecond line\n", frame: CGRect(x: 50, y: 60, width: 240, height: 1))
        let original = try XCTUnwrap(m.selected)
        m.textSize = 48
        let enlarged = try XCTUnwrap(m.selected)
        XCTAssertGreaterThan(enlarged.frame.height, original.frame.height)
        XCTAssertEqual(enlarged.frame.width, original.frame.width)
        m.undo(); XCTAssertEqual(m.selected, original)
        m.redo(); XCTAssertEqual(m.selected, enlarged)
        m.commitText("Short", frame: enlarged.frame, id: enlarged.id)
        XCTAssertLessThan(try XCTUnwrap(m.selected).frame.height, enlarged.frame.height)
        let transformed = original.transformed(from: original.frame,
            to: CGRect(x: 20, y: 30, width: 120, height: 1))
        XCTAssertEqual(transformed.style.fontSize, original.style.fontSize)
        XCTAssertGreaterThan(transformed.frame.height, 1)
        XCTAssertEqual(transformed.frame.width, 120)
    }

    func testNativeTextHeightGrowsPastImageBottomAndReservesTrailingLine() throws {
        let m = model(), canvas = ScreenshotCanvasView()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; canvas.model = m; window.contentView = canvas
        defer { window.close() }
        canvas.beginText(at: CGPoint(x: 100, y: 780))
        let entry = try XCTUnwrap(canvas.textEntry)
        entry.insertText("One", replacementRange: NSRange(location: NSNotFound, length: 0))
        let oneLineHeight = entry.frame.height
        entry.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(entry.string, "One\n")
        XCTAssertGreaterThan(entry.frame.height, oneLineHeight)
        XCTAssertGreaterThan(entry.frame.maxY, CGFloat(m.height))
        XCTAssertEqual(entry.font?.pointSize, 24)
        let editingHeight = entry.frame.height
        canvas.commitText()
        XCTAssertEqual(m.selected?.frame.height, editingHeight)
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
    func testContextMenuTargetsClickedObjectAndPreservesSelectedGroup() throws {
        let m = model(), ids = twoObjects(m), canvas = ScreenshotCanvasView()
        canvas.model = m
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.close() }
        func menu(at point: CGPoint) throws -> NSMenu? {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            return canvas.menu(for: event)
        }
        m.select(ids[1])
        let context = try XCTUnwrap(menu(at: CGPoint(x: 40, y: 70)))
        XCTAssertEqual(m.selectedID, ids[0])
        XCTAssertEqual(context.items.filter { !$0.isSeparatorItem }.count, 4)
        canvas.menuWillOpen(context); XCTAssertTrue(canvas.isShowingContextMenu)
        let front = try XCTUnwrap(context.items.first)
        _ = canvas.perform(try XCTUnwrap(front.action), with: front)
        XCTAssertEqual(m.annotations.last?.id, ids[0])
        m.undo(); XCTAssertEqual(m.annotations.map(\.id), ids)
        m.select(ids: Set(ids)); _ = try menu(at: CGPoint(x: 220, y: 70))
        XCTAssertEqual(m.selectedIDs, Set(ids))
        canvas.menuDidClose(context); XCTAssertFalse(canvas.isShowingContextMenu)
        XCTAssertNil(try menu(at: CGPoint(x: 700, y: 700))); XCTAssertFalse(m.hasSelection)
        m.selectTool(.crop); XCTAssertNil(try menu(at: CGPoint(x: 40, y: 70)))
    }

    func testPopoverPlacementTracksEdgesAndAvoidsToolbar() throws {
        let viewport = CGRect(x: 0, y: 0, width: 850, height: 400), size = CGSize(width: 420, height: 64)
        let toolbar = CGRect(x: 185, y: 320, width: 480, height: 56)
        let top = CGRect(x: 780, y: 0, width: 60, height: 60)
        let frame = try XCTUnwrap(ScreenshotPopoverPlacement.frame(anchor: top, size: size, viewport: viewport, avoiding: [toolbar]))
        XCTAssertTrue(viewport.contains(frame)); XCTAssertGreaterThan(frame.minY, top.maxY)
        XCTAssertFalse(frame.intersects(toolbar))
        let bottom = CGRect(x: 350, y: 260, width: 100, height: 40)
        let above = try XCTUnwrap(ScreenshotPopoverPlacement.frame(anchor: bottom, size: size, viewport: viewport, avoiding: [toolbar]))
        XCTAssertLessThan(above.maxY, bottom.minY); XCTAssertFalse(above.intersects(toolbar))
        XCTAssertNil(ScreenshotPopoverPlacement.frame(anchor: CGRect(x: -300, y: -200, width: 100, height: 60), size: size, viewport: viewport, avoiding: []))
        XCTAssertNotNil(ScreenshotPopoverPlacement.frame(anchor: CGRect(x: 200, y: 160, width: 180, height: 0), size: size, viewport: viewport, avoiding: []), "A horizontal arrow still has an anchor")
    }

    func testViewportPopoverFollowsSelectionAndHidesDuringGestureAndTextEntry() {
        let m = model(), canvas = ScreenshotCanvasView(), scroll = NSScrollView()
        canvas.model = m; scroll.documentView = canvas
        let viewport = ScreenshotEditorViewport(scrollView: scroll, model: m, export: { _ in })
        viewport.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        viewport.layoutSubtreeIfNeeded()
        draw(m, .rectangle, CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 400))
        canvas.synchronize(); viewport.updatePresentation()
        XCTAssertFalse(viewport.annotationPopover.isHidden)
        m.beginInteraction(at: CGPoint(x: 100, y: 300), tolerance: 6); canvas.synchronize()
        XCTAssertTrue(viewport.annotationPopover.isHidden)
        m.continueInteraction(at: CGPoint(x: 200, y: 300)); m.endInteraction(); canvas.synchronize()
        XCTAssertFalse(viewport.annotationPopover.isHidden)
        m.isEditingText = true; viewport.updatePresentation(); XCTAssertTrue(viewport.annotationPopover.isHidden)
        m.isEditingText = false; m.select(nil); canvas.synchronize(); XCTAssertTrue(viewport.annotationPopover.isHidden)
    }

    func testSizeShortcutsAdjustShapesAndTextWithoutZoomingAndSupportUndo() throws {
        let editor = ScreenshotEditorWindowController(canvas: model().source, fileName: "Fixture.jpg")
        let window = try XCTUnwrap(editor.window as? ScreenshotEditorWindow)
        defer { window.close() }
        let m = editor.model
        func key(_ characters: String, flags: NSEvent.ModifierFlags = .command, code: UInt16 = 24) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        for tool in [ScreenshotTool.rectangle, .ellipse, .arrow, .freehand, .text] {
            if tool == .text { m.commitText("Hello", frame: CGRect(x: 100, y: 100, width: 280, height: 80)) }
            else { draw(m, tool, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)) }
            let before = try XCTUnwrap(m.selected), zoom = m.zoom
            XCTAssertTrue(window.performKeyEquivalent(with: try key("=")))
            let enlarged = try XCTUnwrap(m.selected)
            XCTAssertEqual(enlarged.style.width, before.style.width + (tool == .text ? 0 : 1))
            XCTAssertEqual(enlarged.style.fontSize, before.style.fontSize + (tool == .text ? 1 : 0))
            XCTAssertEqual(m.zoom, zoom)
            m.undo(); XCTAssertEqual(m.selected, before)
            m.redo(); XCTAssertEqual(m.selected, enlarged)
            XCTAssertTrue(window.performKeyEquivalent(with: try key("-", code: 27)))
            XCTAssertEqual(m.selected, before)
            XCTAssertTrue(window.performKeyEquivalent(with: try key("+", flags: [.command, .shift])))
            XCTAssertEqual(m.selected, enlarged)
            m.undo()
            XCTAssertTrue(window.performKeyEquivalent(with: try key("+", code: 69)))
            XCTAssertEqual(m.selected, enlarged)
        }
        let before = m.annotations
        _ = window.performKeyEquivalent(with: try key("=", flags: [.command, .option]))
        XCTAssertEqual(m.annotations, before)
        let textEntry = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        window.contentView = textEntry
        XCTAssertTrue(window.makeFirstResponder(textEntry))
        _ = window.performKeyEquivalent(with: try key("="))
        XCTAssertEqual(m.annotations, before)
    }

    func testSizeAdjustmentPreservesMixedStylesAndGroupsUndo() throws {
        let m = model()
        draw(m, .rectangle, CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 100)); m.brushSize = 2
        draw(m, .ellipse, CGPoint(x: 150, y: 50), CGPoint(x: 200, y: 100)); m.brushSize = 8
        m.commitText("Hello", frame: CGRect(x: 100, y: 200, width: 280, height: 80)); m.textSize = 24
        draw(m, .arrow, CGPoint(x: 300, y: 50), CGPoint(x: 400, y: 100))
        draw(m, .freehand, CGPoint(x: 500, y: 50), CGPoint(x: 600, y: 100))
        m.selectAll()
        let before = m.annotations, generation = m.generation
        XCTAssertTrue(m.adjustSelectionSize(by: 1))
        XCTAssertEqual(m.annotations[0].style.width, 3)
        XCTAssertEqual(m.annotations[1].style.width, 9)
        XCTAssertEqual(m.annotations[2].style.fontSize, 25)
        for i in [3, 4] {
            XCTAssertEqual(m.annotations[i].style.width, before[i].style.width + 1)
            XCTAssertEqual(m.annotations[i].points, before[i].points)
            XCTAssertEqual(m.annotations[i].style.arrowHeadLength, before[i].style.arrowHeadLength)
        }
        XCTAssertEqual(m.generation, generation + 1)
        m.undo(); XCTAssertEqual(m.annotations, before)
        XCTAssertTrue(m.adjustSelectionSize(by: -100))
        XCTAssertEqual(m.annotations[0].style.width, 1)
        XCTAssertEqual(m.annotations[1].style.width, 1)
        XCTAssertEqual(m.annotations[2].style.fontSize, 1)
        XCTAssertEqual(m.annotations[3].style.width, 1)
        XCTAssertEqual(m.annotations[4].style.width, 1)
        let atMinimum = m.generation
        XCTAssertTrue(m.adjustSelectionSize(by: -1))
        XCTAssertEqual(m.generation, atMinimum)
        m.select(m.annotations[0].id); m.brushSize = 0.5
        XCTAssertTrue(m.adjustSelectionSize(by: -1))
        XCTAssertEqual(m.selected?.style.width, 0.5)
    }

    func testSizeAdjustmentIgnoresEmptySelectionAndActiveEditing() {
        let m = model()
        XCTAssertFalse(m.adjustSelectionSize(by: 1))
        draw(m, .rectangle, CGPoint(x: 200, y: 200), CGPoint(x: 400, y: 400))
        m.isEditingText = true
        XCTAssertFalse(m.adjustSelectionSize(by: 1))
        m.isEditingText = false
        m.beginInteraction(at: CGPoint(x: 300, y: 300), tolerance: 6)
        XCTAssertTrue(m.isInteracting); XCTAssertFalse(m.adjustSelectionSize(by: 1))
        m.cancelInteraction()
    }

    func testPopoverBackgroundConsumesClicksWithoutClearingSelection() throws {
        let m = model(), canvas = ScreenshotCanvasView(), scroll = NSScrollView()
        canvas.model = m; scroll.documentView = canvas
        let viewport = ScreenshotEditorViewport(scrollView: scroll, model: m, export: { _ in })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = viewport
        defer { window.close() }
        viewport.layoutSubtreeIfNeeded()
        draw(m, .rectangle, CGPoint(x: 250, y: 300), CGPoint(x: 450, y: 500))
        canvas.synchronize(); viewport.layoutSubtreeIfNeeded()
        let popover = viewport.annotationPopover, selected = m.selectedIDs
        XCTAssertFalse(popover.isHidden)
        for offset in [CGPoint(x: 12, y: 12), CGPoint(x: 4, y: 4)] {
            let point = CGPoint(x: popover.frame.minX + offset.x, y: popover.frame.minY + offset.y)
            let target = try XCTUnwrap(viewport.hitTest(viewport.convert(point, to: viewport.superview)))
            XCTAssertTrue(target === popover || target.isDescendant(of: popover))
            let location = viewport.convert(point, to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            target.mouseDown(with: down); target.mouseUp(with: up)
            XCTAssertEqual(m.selectedIDs, selected); XCTAssertFalse(m.isInteracting)
            XCTAssertFalse(popover.isHidden)
        }
    }

}
