import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Phi

@MainActor
final class ScreenshotEditorTests: XCTestCase {
    private func image(width: Int = 400, height: Int = 300) -> CGImage {
        let context = ScreenshotSceneRenderer.bitmapContext(width: width, height: height)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
    private func stroke(_ model: ScreenshotEditorModel, tool: ScreenshotTool, from: CGPoint, to: CGPoint) {
        model.select(nil); model.selectTool(tool)
        model.beginInteraction(at: from, tolerance: 2); model.continueInteraction(at: to); model.endInteraction()
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        // A fresh bitmap context normalizes byte order and row alignment.
        let context = ScreenshotSceneRenderer.bitmapContext(width: image.width, height: image.height)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self), offset = y * context.bytesPerRow + x * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
    func testEachObjectCreationIsOneNativeUndoAndObjectsRemainEditableThroughRedo() {
        let model = ScreenshotEditorModel(canvas: image())
        var states: [[ScreenshotAnnotation]] = [[]]
        for (index, tool) in [ScreenshotTool.arrow, .freehand, .rectangle, .ellipse].enumerated() {
            stroke(model, tool: tool, from: CGPoint(x: 20, y: 20 + index * 50), to: CGPoint(x: 180, y: 40 + index * 50))
            states.append(model.annotations)
        }
        model.commitText("Phi", frame: CGRect(x: 25, y: 240, width: 180, height: 50)); states.append(model.annotations)
        XCTAssertEqual(model.generation, 5)
        for i in (0..<5).reversed() { model.undo(); XCTAssertEqual(model.annotations, states[i]) }
        XCTAssertFalse(model.canUndo)
        for i in 1...5 { model.redo(); XCTAssertEqual(model.annotations, states[i]) }
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.annotations.map(\.kind), [.arrow, .freehand, .rectangle, .ellipse, .text])
    }
    func testCancelledInteractionRestoresSceneWithoutNewHistoryAndNewEditClearsRedo() {
        let model = ScreenshotEditorModel(canvas: image())
        stroke(model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 70))
        let committed = model.annotations
        model.beginInteraction(at: CGPoint(x: 180, y: 70), tolerance: 5)
        model.continueInteraction(at: CGPoint(x: 250, y: 190)); model.cancelInteraction()
        XCTAssertEqual(model.annotations, committed); XCTAssertEqual(model.generation, 1)
        model.undo(); XCTAssertTrue(model.canRedo)
        stroke(model, tool: .rectangle, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 70))
        XCTAssertFalse(model.canRedo)
    }
    func testArrowEndpointMoveAndBodyMovePreserveIdentityAndUndoEachGestureOnce() throws {
        let model = ScreenshotEditorModel(canvas: image())
        stroke(model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 80))
        let first = try XCTUnwrap(model.selected)
        model.beginInteraction(at: first.points[1], tolerance: 5)
        for i in 1...100 { model.continueInteraction(at: CGPoint(x: 180 + i, y: 80 + i)) }
        model.endInteraction()
        let resized = try XCTUnwrap(model.selected)
        XCTAssertEqual(resized.id, first.id); XCTAssertEqual(resized.points[0], first.points[0])
        XCTAssertEqual(model.generation, 2)
        model.selectTool(.select)
        model.beginInteraction(at: CGPoint(x: 150, y: 100), tolerance: 10)
        model.continueInteraction(at: CGPoint(x: 160, y: 110)); model.endInteraction()
        let moved = model.annotations
        model.undo(); XCTAssertEqual(model.selected, resized)
        model.undo(); XCTAssertEqual(model.selected, first)
        model.redo(); model.redo(); XCTAssertEqual(model.annotations, moved)
    }
    func testBoundingBoxResizeAndStyleAreObjectEditsWithSourcePointsRetained() throws {
        let model = ScreenshotEditorModel(canvas: image())
        stroke(model, tool: .freehand, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 140, y: 140))
        let first = try XCTUnwrap(model.selected)
        model.beginInteraction(at: CGPoint(x: 140, y: 140), tolerance: 3)
        model.continueInteraction(at: CGPoint(x: 240, y: 240)); model.endInteraction()
        XCTAssertEqual(model.selected?.points, [CGPoint(x: 40, y: 40), CGPoint(x: 240, y: 240)])
        model.brushSize = 16
        XCTAssertEqual(model.selected?.style.width, 16)
        model.undo(); XCTAssertEqual(model.selected?.style.width, first.style.width)
        model.undo(); XCTAssertEqual(model.selected, first)
    }
    func testOutlineHitTestingUsesTopmostPathAndFilledInteriors() throws {
        let model = ScreenshotEditorModel(canvas: image())
        stroke(model, tool: .rectangle, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 220, y: 180))
        let bottom = try XCTUnwrap(model.selected)
        XCTAssertEqual(model.hitTest(CGPoint(x: 100, y: 100), tolerance: 3)?.id, bottom.id)
        model.filled = true
        XCTAssertEqual(model.hitTest(CGPoint(x: 100, y: 100), tolerance: 3)?.id, bottom.id)
        stroke(model, tool: .ellipse, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 190, y: 160))
        let top = try XCTUnwrap(model.selected)
        XCTAssertEqual(model.hitTest(CGPoint(x: 100, y: 100), tolerance: 3)?.id, top.id)
        model.reorderSelection(front: false)
        XCTAssertEqual(model.hitTest(CGPoint(x: 100, y: 100), tolerance: 3)?.id, bottom.id)
        model.undo(); XCTAssertEqual(model.annotations.last?.id, top.id)
    }
    func testDuplicatePasteDeleteAndLayerOrderUndoRetainObjects() throws {
        let model = ScreenshotEditorModel(canvas: image())
        model.commitText("Editable", frame: CGRect(x: 20, y: 30, width: 220, height: 80))
        let first = try XCTUnwrap(model.selected)
        model.duplicateSelection(); let copy = try XCTUnwrap(model.selected)
        XCTAssertNotEqual(copy.id, first.id); XCTAssertEqual(copy.text, first.text)
        model.deleteSelection(); XCTAssertEqual(model.annotations, [first])
        model.undo(); XCTAssertEqual(model.selected, copy)
        model.paste(first); XCTAssertEqual(model.annotations.count, 3)
        model.undo(); model.undo(); XCTAssertEqual(model.annotations, [first])
    }
    func testSnapshotIsImmutablePreviewChangesDoNotReplaceOrAlterOriginalPixels() {
        let source = image(), model = ScreenshotEditorModel(canvas: image())
        stroke(model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 80))
        let snapshot = model.snapshot()
        model.setZoomExact(0.125); model.filled = true; model.foreground = ScreenshotColor(red: 0, green: 0, blue: 1)
        XCTAssertEqual(snapshot.annotations[0].style.color, .red)
        XCTAssertTrue(snapshot.source === model.source)
        XCTAssertEqual(pixel(source, x: 30, y: 30).r, pixel(model.source, x: 30, y: 30).r)
        model.select(nil); model.beginInteraction(at: CGPoint(x: 20, y: 170), tolerance: 3)
        model.continueInteraction(at: CGPoint(x: 170, y: 220))
        XCTAssertEqual(model.snapshot().annotations.count, 1, "Export must cancel an incomplete gesture")
        XCTAssertFalse(model.isInteracting)
    }
    func testAllExportFormatsKeepSourceDimensionsOrientationAndAnnotationsAtAnyZoom() throws {
        let context = ScreenshotSceneRenderer.bitmapContext(width: 400, height: 300)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.translateBy(x: 0, y: 300); context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 240, width: 80, height: 60))
        let model = ScreenshotEditorModel(canvas: context.makeImage()!)
        model.foreground = ScreenshotColor(red: 0, green: 0.8, blue: 0); model.filled = true
        stroke(model, tool: .rectangle, from: CGPoint(x: 150, y: 20), to: CGPoint(x: 220, y: 80))
        model.setZoomExact(0.1)
        for format in [ScreenshotExportFormat.png, .jpg] {
            let raster = try XCTUnwrap(ScreenshotImageExport.decode(data: ScreenshotImageExport.encode(model.snapshot(), format: format)))
            XCTAssertEqual(raster.width, 400); XCTAssertEqual(raster.height, 300)
            XCTAssertGreaterThan(pixel(raster, x: 30, y: 30).r, 230)
            XCTAssertGreaterThan(pixel(raster, x: 30, y: 270).b, 230)
            XCTAssertGreaterThan(pixel(raster, x: 180, y: 50).g, 180)
        }
        let pdf = try ScreenshotImageExport.encode(model.snapshot(), format: .pdf)
        let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: pdf as CFData))))
        XCTAssertEqual(document.numberOfPages, 1)
        let page = try XCTUnwrap(document.page(at: 1))
        XCTAssertEqual(page.getBoxRect(.mediaBox), CGRect(x: 0, y: 0, width: 400, height: 300))
        let pdfContext = ScreenshotSceneRenderer.bitmapContext(width: 400, height: 300)!
        pdfContext.drawPDFPage(page); let rendered = pdfContext.makeImage()!
        XCTAssertGreaterThan(pixel(rendered, x: 30, y: 30).r, 230)
        XCTAssertGreaterThan(pixel(rendered, x: 30, y: 270).b, 230)
        XCTAssertGreaterThan(pixel(rendered, x: 180, y: 50).g, 180)
    }
    func testSmoothedFreehandExportsCurveInsteadOfOriginalCornerInEveryFormat() throws {
        let model = ScreenshotEditorModel(canvas: image())
        model.brushSize = 6
        model.selectTool(.freehand); model.beginInteraction(at: CGPoint(x: 20, y: 100), tolerance: 2)
        model.continueInteraction(at: CGPoint(x: 100, y: 20))
        model.continueInteraction(at: CGPoint(x: 180, y: 100)); model.endInteraction()
        model.setZoomExact(0.25)
        for format in ScreenshotExportFormat.allCases {
            let data = try ScreenshotImageExport.encode(model.snapshot(), format: format)
            let raster: CGImage
            if format == .pdf {
                let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
                let context = try XCTUnwrap(ScreenshotSceneRenderer.bitmapContext(width: 400, height: 300))
                context.drawPDFPage(try XCTUnwrap(document.page(at: 1)))
                raster = try XCTUnwrap(context.makeImage())
            } else {
                raster = try XCTUnwrap(ScreenshotImageExport.decode(data: data))
            }
            XCTAssertLessThan(pixel(raster, x: 100, y: 40).g, 100, "\(format): the smoothed curve is painted")
            XCTAssertGreaterThan(pixel(raster, x: 100, y: 20).g, 230, "\(format): the old corner remains white")
        }
    }
    func testPNGExportPreservesCompositePixelsAndWritesPNGFile() throws {
        let model = ScreenshotEditorModel(canvas: image(width: 80, height: 60))
        model.foreground = ScreenshotColor(red: 0.2, green: 0.6, blue: 0.8)
        stroke(model, tool: .arrow, from: CGPoint(x: 5, y: 10), to: CGPoint(x: 65, y: 45))
        let snapshot = model.snapshot()
        let expected = try ScreenshotImageExport.composite(snapshot)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("edited.png")
        try ScreenshotImageExport.write(snapshot, format: .png, to: url)
        let data = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let decoded = try XCTUnwrap(ScreenshotImageExport.decode(data: data))
        XCTAssertEqual(decoded.width, expected.width)
        XCTAssertEqual(decoded.height, expected.height)
        for y in 0..<expected.height {
            for x in 0..<expected.width {
                let actual = pixel(decoded, x: x, y: y), original = pixel(expected, x: x, y: y)
                XCTAssertEqual(actual.r, original.r)
                XCTAssertEqual(actual.g, original.g)
                XCTAssertEqual(actual.b, original.b)
            }
        }
    }

    func testFailedWritePreservesSceneAndLimitsAreCheckedBeforeDecode() {
        let model = ScreenshotEditorModel(canvas: image())
        stroke(model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 80))
        let snapshot = model.snapshot()
        XCTAssertThrowsError(try ScreenshotImageExport.write(snapshot, format: .jpg, to: URL(fileURLWithPath: "/nonexistent-phi-fixture-folder/image.jpg")))
        XCTAssertEqual(model.annotations, snapshot.annotations); XCTAssertTrue(model.canUndo)
        XCTAssertFalse(ScreenshotImageExport.isSizeSupported(width: 32769, height: 1))
        XCTAssertFalse(ScreenshotImageExport.isSizeSupported(width: 8001, height: 8000))
        XCTAssertTrue(ScreenshotImageExport.isSizeSupported(width: 3438, height: 8192))
        XCTAssertNil(ScreenshotImageExport.decode(data: Data()))
    }
    private func canvasFixture(zoom: Double = 1) -> (NSWindow, ScreenshotCanvasView, ScreenshotEditorModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let model = ScreenshotEditorModel(canvas: image()), canvas = ScreenshotCanvasView()
        model.selectTool(.arrow)
        canvas.model = model; canvas.zoom = zoom; model.setZoomExact(zoom); window.contentView = canvas
        canvas.invalidateCanvasSize(); model.prepareForCommand = { [weak canvas] in canvas?.prepareForCommand() }
        return (window, canvas, model)
    }
    private func pointerEvent(_ type: NSEvent.EventType, at point: CGPoint, canvas: NSView, clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }
    func testDirectPointerInputScalesInSourcePixelsAndFocusLossCancelsOneGesture() throws {
        for zoom in [0.25, 1.0, 2.0] {
            let (window, canvas, model) = canvasFixture(zoom: zoom); defer { window.close() }
            canvas.mouseDown(with: try pointerEvent(.leftMouseDown, at: CGPoint(x: 20 * zoom, y: 30 * zoom), canvas: canvas))
            canvas.mouseUp(with: try pointerEvent(.leftMouseUp, at: CGPoint(x: 180 * zoom, y: 80 * zoom), canvas: canvas))
            XCTAssertEqual(model.selected?.points, [CGPoint(x: 20, y: 30), CGPoint(x: 180, y: 80)])
            XCTAssertEqual(model.generation, 1)
            let original = model.annotations
            canvas.mouseDown(with: try pointerEvent(.leftMouseDown, at: CGPoint(x: 180 * zoom, y: 80 * zoom), canvas: canvas))
            canvas.mouseDragged(with: try pointerEvent(.leftMouseDragged, at: CGPoint(x: 220 * zoom, y: 150 * zoom), canvas: canvas))
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            XCTAssertEqual(model.annotations, original); XCTAssertEqual(model.generation, 1)
            XCTAssertTrue(canvas.backgroundImage === model.source)
        }
    }
    func testNativeTextCommitsOnCommandRemainsEditableAndEscapeRestoresPreviousObject() throws {
        let (window, canvas, model) = canvasFixture(); defer { window.close() }
        model.selectTool(.text); canvas.beginText(at: CGPoint(x: 30, y: 100))
        let entry = try XCTUnwrap(canvas.textEntry)
        entry.insertText("First\nSecond", replacementRange: NSRange(location: NSNotFound, length: 0))
        let snapshot = model.snapshot(); let object = try XCTUnwrap(snapshot.annotations.first)
        XCTAssertEqual(object.text, "First\nSecond"); XCTAssertNil(canvas.textEntry); XCTAssertEqual(model.generation, 1)
        canvas.beginText(at: object.frame.origin, object: object)
        canvas.textEntry?.insertText("changed", replacementRange: NSRange(location: 0, length: object.text.utf16.count))
        canvas.cancelText(); XCTAssertEqual(model.selected, object)
        canvas.beginText(at: object.frame.origin, object: object)
        canvas.textEntry?.insertText("Reedited", replacementRange: NSRange(location: 0, length: object.text.utf16.count))
        canvas.commitText(); XCTAssertEqual(model.selected?.text, "Reedited"); XCTAssertEqual(model.selected?.id, object.id)
        model.undo(); XCTAssertEqual(model.selected, object)
    }
    func testConsecutiveTextSessionsOwnIndependentNativeUndoManagers() throws {
        let (window, canvas, model) = canvasFixture(); defer { window.close() }
        canvas.beginText(at: CGPoint(x: 30, y: 40))
        let first = try XCTUnwrap(canvas.textEntry); first.insertText("First", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(first.undoManager!.canUndo); canvas.commitText()
        canvas.beginText(at: CGPoint(x: 30, y: 150)); let second = try XCTUnwrap(canvas.textEntry)
        XCTAssertFalse(second.undoManager!.canUndo); XCTAssertFalse(first.undoManager === second.undoManager)
        second.insertText("Second", replacementRange: NSRange(location: NSNotFound, length: 0)); second.undoManager?.undo()
        XCTAssertEqual(second.string, ""); XCTAssertEqual(model.annotations.first?.text, "First")
        canvas.cancelText()
    }
    func testTextFocusLossCommitsButToolChangeCancelsAnUnfinishedDrawing() throws {
        let (window, canvas, model) = canvasFixture(); defer { window.close() }
        canvas.beginText(at: CGPoint(x: 30, y: 40)); canvas.textEntry?.insertText("Saved text", replacementRange: NSRange(location: NSNotFound, length: 0))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(model.annotations.first?.text, "Saved text")
        model.select(nil); model.beginInteraction(at: CGPoint(x: 30, y: 150), tolerance: 3)
        model.continueInteraction(at: CGPoint(x: 180, y: 240)); model.selectTool(.freehand)
        XCTAssertFalse(model.isInteracting); XCTAssertEqual(model.annotations.count, 1)
    }
    func testMenuUndoAndRedoStayInScreenshotDocument() throws {
        let editor = ScreenshotEditorWindowController(canvas: image(), fileName: "Fixture.jpg")
        let window = try XCTUnwrap(editor.window as? ScreenshotEditorWindow); defer { window.close() }
        stroke(editor.model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 80))
        let marked = editor.model.annotations
        let undo = NSMenuItem(title: "Undo", action: NSSelectorFromString("commandDispatch:"), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.command]
        let redo = NSMenuItem(title: "Redo", action: undo.action, keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        XCTAssertTrue(window.validateUserInterfaceItem(undo)); XCTAssertFalse(window.validateUserInterfaceItem(redo))
        window.commandDispatch(undo); XCTAssertTrue(editor.model.annotations.isEmpty)
        window.commandDispatch(redo); XCTAssertEqual(editor.model.annotations, marked)
    }

    private func browserWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
                              styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func testOverlayFollowsBrowserContentAndRestoresFocusOnClose() throws {
        let parent = browserWindow()
        defer { parent.close() }
        let responder = NSTextView(frame: NSRect(x: 10, y: 10, width: 100, height: 40))
        parent.contentView?.addSubview(responder)
        XCTAssertTrue(parent.makeFirstResponder(responder))
        let editor = ScreenshotEditorWindowController(canvas: image(), fileName: "Fixture.jpg", parent: parent)
        let window = try XCTUnwrap(editor.window as? ScreenshotEditorWindow)
        defer { window.close() }
        editor.showWindow(nil)
        XCTAssertTrue(window.parent === parent)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.firstResponder === window.canvasResponder)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertFalse(window.isMovable)
        XCTAssertFalse(window.styleMask.contains(.resizable))
        for size in [NSSize(width: 1200, height: 800), NSSize(width: 960, height: 600)] {
            parent.setContentSize(size)
            parent.setFrameOrigin(NSPoint(x: size.width / 10, y: 160))
            let content = try XCTUnwrap(parent.contentView)
            XCTAssertEqual(window.frame, parent.convertToScreen(content.convert(content.bounds, to: nil)))
            XCTAssertEqual(window.contentView?.subviews.first?.frame, window.contentView?.bounds.insetBy(dx: 36, dy: 36))
        }
        parent.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        let backgroundClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        window.contentView?.mouseDown(with: backgroundClick)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(window.parent)
        XCTAssertTrue(parent.isVisible)
        XCTAssertTrue(parent.firstResponder === responder)
        XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
    }

    func testOverlayEscapeCancelsCropBeforeClosingAndCommandWClosesOnlyEditor() throws {
        let parent = browserWindow()
        defer { parent.close() }
        for useCommandW in [false, true] {
            let editor = ScreenshotEditorWindowController(canvas: image(), fileName: "Fixture.jpg", parent: parent)
            let window = try XCTUnwrap(editor.window as? ScreenshotEditorWindow)
            defer { window.close() }
            editor.showWindow(nil)
            let canvas = try XCTUnwrap(window.canvasResponder)
            editor.model.selectTool(.crop)
            editor.model.beginInteraction(at: CGPoint(x: 20, y: 20), tolerance: 2)
            editor.model.continueInteraction(at: CGPoint(x: 160, y: 100))
            editor.model.endInteraction()
            canvas.cancelOperation(nil)
            XCTAssertNil(editor.model.cropRect)
            XCTAssertEqual(editor.model.tool, .select)
            XCTAssertTrue(window.isVisible)
            if useCommandW {
                let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "w",
                    charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
                XCTAssertTrue(window.performKeyEquivalent(with: key))
            } else {
                canvas.cancelOperation(nil)
            }
            XCTAssertFalse(window.isVisible)
            XCTAssertTrue(parent.isVisible)
        }
    }

    func testOverlayUnsavedCloseCanKeepEditing() async throws {
        let parent = browserWindow()
        defer { parent.close() }
        let editor = ScreenshotEditorWindowController(canvas: image(), fileName: "Fixture.jpg", parent: parent)
        let window = try XCTUnwrap(editor.window)
        defer { window.close() }
        editor.showWindow(nil)
        stroke(editor.model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 80))
        window.performClose(nil)
        for _ in 0..<100 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        for _ in 0..<100 where window.attachedSheet != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        await Task.yield()
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.parent === parent)
        XCTAssertEqual(editor.model.annotations.count, 1)
        XCTAssertTrue(editor.requiresTerminationReview)
    }

    func testBrowserCloseRemovesCleanOverlayAndPreservesUnsavedDocument() throws {
        for dirty in [false, true] {
            let parent = browserWindow()
            let editor = ScreenshotEditorWindowController(canvas: image(), fileName: "Fixture.jpg", parent: parent)
            let window = try XCTUnwrap(editor.window as? ScreenshotEditorWindow)
            defer { window.close() }
            editor.showWindow(nil)
            if dirty { stroke(editor.model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 80)) }
            parent.close()
            XCTAssertNil(window.parent)
            XCTAssertEqual(window.isVisible, dirty)
            if dirty {
                XCTAssertFalse(window.isOverlay)
                XCTAssertTrue(window.canBecomeMain)
                XCTAssertTrue(window.styleMask.contains(.closable))
                XCTAssertEqual(editor.model.annotations.count, 1)
                XCTAssertTrue(editor.model.canUndo)
                XCTAssertNotNil(window.canvasResponder)
            }
        }
    }

    func testBrowserClosePreservesConfirmedOverlayExport() async throws {
        let parent = browserWindow()
        let editor = ScreenshotEditorWindowController(canvas: image(), fileName: "Fixture.jpg", parent: parent)
        let window = try XCTUnwrap(editor.window as? ScreenshotEditorWindow)
        defer { window.close() }
        editor.showWindow(nil)
        let gate = ExportGate()
        editor.writeSnapshot(editor.model.snapshot(), format: .jpg, to: URL(fileURLWithPath: "/unused-fixture.jpg")) { _, _, _ in
            await gate.wait()
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        parent.close()
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(window.parent)
        XCTAssertTrue(editor.hasConfirmedExport)
        gate.finish()
        await editor.waitForConfirmedExport()
        XCTAssertFalse(editor.requiresTerminationReview)
    }
    func testRetainedLayerUpdatesAtLargeImageSizesDoNotRedrawBackgroundOrOtherObjects() throws {
        for size in [(2400, 3600), (3200, 7500)] {
            let model = ScreenshotEditorModel(canvas: image(width: size.0, height: size.1)), canvas = ScreenshotCanvasView()
            canvas.model = model; canvas.zoom = 600 / Double(size.1); canvas.invalidateCanvasSize()
            stroke(model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 400, y: 700)); canvas.synchronize()
            let baseline = canvas.objectLayerUpdateCount
            let start = CFAbsoluteTimeGetCurrent()
            model.beginInteraction(at: CGPoint(x: 400, y: 700), tolerance: 5)
            for i in 1...200 {
                model.continueInteraction(at: CGPoint(x: 400 + i, y: 700 + i)); canvas.synchronize()
            }
            model.endInteraction(); canvas.synchronize()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 200
            print("Retained layers \(size.0)x\(size.1): \(elapsed) ms per endpoint update (Debug, offscreen)")
            XCTAssertLessThan(elapsed, 10)
            XCTAssertEqual(canvas.objectLayerUpdateCount - baseline, 200)
            XCTAssertTrue(canvas.backgroundImage === model.source)
            XCTAssertEqual(model.generation, 2)
        }
    }
    @MainActor private final class ExportGate {
        var continuation: CheckedContinuation<Void, Never>?
        let entered = XCTestExpectation(description: "The export reached its suspension gate")
        func wait() async {
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        func finish() { continuation?.resume(); continuation = nil }
    }

    func testTerminationWaitsForExportAndStillReviewsEditsMadeDuringEncoding() async throws {
        let editor = ScreenshotEditorWindowController(canvas: image(width: 200, height: 100), fileName: "Fixture.jpg")
        defer { editor.window?.close() }
        stroke(editor.model, tool: .freehand, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 40))
        let gate = ExportGate()
        editor.writeSnapshot(editor.model.snapshot(), format: .jpg, to: URL(fileURLWithPath: "/unused-fixture.jpg")) { _, _, _ in
            await gate.wait()
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertNotNil(gate.continuation)
        var reviewed = false
        let review = Task { await editor.prepareForTermination(confirmDiscard: { reviewed = true; return false }) }
        await Task.yield()
        XCTAssertFalse(reviewed, "Quit proceeded before the confirmed export finished")
        stroke(editor.model, tool: .freehand, from: CGPoint(x: 20, y: 70), to: CGPoint(x: 100, y: 70))
        gate.finish()
        let approved = await review.value
        XCTAssertFalse(approved)
        XCTAssertTrue(reviewed)
        XCTAssertTrue(editor.requiresTerminationReview)
        XCTAssertEqual(editor.model.annotations.count, 2)
    }

    func testTerminationNeedsNoDiscardPromptAfterTheCurrentDocumentFinishesExporting() async throws {
        let editor = ScreenshotEditorWindowController(canvas: image(width: 200, height: 100), fileName: "Fixture.jpg")
        defer { editor.window?.close() }
        stroke(editor.model, tool: .freehand, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 40))
        let gate = ExportGate()
        editor.writeSnapshot(editor.model.snapshot(), format: .pdf, to: URL(fileURLWithPath: "/unused-fixture.pdf")) { _, _, _ in
            await gate.wait()
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        let review = Task { await editor.prepareForTermination(confirmDiscard: { XCTFail("Saved document asked to discard edits"); return false }) }
        await Task.yield()
        gate.finish()
        let approved = await review.value
        XCTAssertTrue(approved)
        XCTAssertFalse(editor.requiresTerminationReview)
    }

    func testTerminationDiscardApprovalDoesNotBypassLaterDocumentReview() async {
        let editor = ScreenshotEditorWindowController(canvas: image(width: 200, height: 100), fileName: "Fixture.jpg")
        defer { editor.window?.close() }
        stroke(editor.model, tool: .freehand, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 40))
        let first = await editor.prepareForTermination(confirmDiscard: { true })
        XCTAssertTrue(first)
        var promptedAgain = false
        let second = await editor.prepareForTermination(confirmDiscard: { promptedAgain = true; return false })
        XCTAssertFalse(second)
        XCTAssertTrue(promptedAgain, "Another editor canceling Quit must not leave discard permission latched")
        XCTAssertTrue(editor.requiresTerminationReview)
    }

    func testApprovedTerminationClosesImageBeforeDownstreamBrowserPrompts() throws {
        let editor = ScreenshotEditorWindowController(canvas: image(width: 200, height: 100), fileName: "Fixture.jpg")
        let window = try XCTUnwrap(editor.window)
        defer { window.close() }
        stroke(editor.model, tool: .freehand, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 40))
        let approvedGeneration = editor.model.generation
        stroke(editor.model, tool: .freehand, from: CGPoint(x: 20, y: 70), to: CGPoint(x: 100, y: 70))
        XCTAssertFalse(editor.closeAfterApprovedTermination(generation: approvedGeneration))
        XCTAssertNotNil(window.contentViewController, "Changed document must stay available for another review")
        XCTAssertTrue(editor.closeAfterApprovedTermination(generation: editor.model.generation))
        XCTAssertNil(window.contentViewController, "An approved document remained editable during beforeunload")
    }

    func testLateTerminationWaitIncludesAnExportStartedAfterEarlierReview() async {
        let editor = ScreenshotEditorWindowController(canvas: image(width: 200, height: 100), fileName: "Fixture.jpg")
        defer { editor.window?.close() }
        let initiallyApproved = await editor.prepareForTermination(confirmDiscard: { false })
        XCTAssertTrue(initiallyApproved)
        let gate = ExportGate()
        editor.writeSnapshot(editor.model.snapshot(), format: .jpg, to: URL(fileURLWithPath: "/unused-fixture.jpg")) { _, _, _ in
            await gate.wait()
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        var finished = false
        let wait = Task { await editor.waitForConfirmedExport(); finished = true }
        await Task.yield()
        XCTAssertTrue(editor.hasConfirmedExport)
        XCTAssertFalse(finished)
        gate.finish()
        await wait.value
        XCTAssertTrue(finished)
        XCTAssertFalse(editor.hasConfirmedExport)
    }



    func testDoubleClickExistingTextFromSelectRemainsOpenThroughHostedViewUpdates() throws {
        let editor = ScreenshotEditorWindowController(canvas: image(), fileName: "Fixture.jpg")
        defer { editor.window?.close() }
        let model = editor.model
        model.commitText("Existing text", frame: CGRect(x: 30, y: 50, width: 220, height: 90))
        model.selectTool(.select)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        func canvas(in view: NSView?) -> ScreenshotCanvasView? {
            guard let view else { return nil }
            if let result = view as? ScreenshotCanvasView { return result }
            return view.subviews.compactMap { canvas(in: $0) }.first
        }
        let view = try XCTUnwrap(canvas(in: editor.window?.contentView))
        view.mouseDown(with: try pointerEvent(.leftMouseDown, at: CGPoint(x: 70 * view.zoom, y: 70 * view.zoom), canvas: view, clicks: 2))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertNotNil(view.textEntry, "Hosted view update closed text reopened from Select")
        XCTAssertEqual(view.textEntry?.string, "Existing text")
        view.cancelText()
    }
    func testSaveSelectionCancellationDoesNotWriteOrMarkEditsSaved() {
        let editor = ScreenshotEditorWindowController(canvas: image(), fileName: "Fixture.jpg")
        defer { editor.window?.close() }
        stroke(editor.model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 80))
        let scene = editor.model.annotations, generation = editor.model.generation
        editor.completeExportSelection(response: .cancel, url: URL(fileURLWithPath: "/unused-cancelled-fixture.jpg"), format: .jpg)
        XCTAssertFalse(editor.hasConfirmedExport); XCTAssertTrue(editor.requiresTerminationReview)
        XCTAssertEqual(editor.model.annotations, scene); XCTAssertEqual(editor.model.generation, generation)
    }
    func testFailedAsyncExportKeepsDirtySceneAndUndoHistory() async {
        let editor = ScreenshotEditorWindowController(canvas: image(), fileName: "Fixture.jpg")
        defer {
            if let sheet = editor.window?.attachedSheet { editor.window?.endSheet(sheet) }
            editor.window?.close()
        }
        stroke(editor.model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 80))
        let scene = editor.model.annotations
        editor.writeSnapshot(editor.model.snapshot(), format: .jpg, to: URL(fileURLWithPath: "/unused-fixture.jpg")) { _, _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        await editor.waitForConfirmedExport()
        XCTAssertFalse(editor.hasConfirmedExport); XCTAssertTrue(editor.requiresTerminationReview)
        XCTAssertEqual(editor.model.annotations, scene); XCTAssertTrue(editor.model.canUndo)
        XCTAssertTrue(editor.window?.isDocumentEdited == true)
    }
    func testLargeImageOffscreenCompositingIncludesRetainedLayersAndKeepsSource() throws {
        for size in [(2400, 3600), (3200, 7500)] {
            let model = ScreenshotEditorModel(canvas: image(width: size.0, height: size.1)), canvas = ScreenshotCanvasView()
            canvas.model = model; canvas.zoom = 600 / Double(size.1); canvas.invalidateCanvasSize()
            let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = canvas; canvas.invalidateCanvasSize()
            defer { window.close() }
            stroke(model, tool: .arrow, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 700, y: 1600)); canvas.synchronize()
            canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
            var samples: [Double] = [], lastImage: CGImage?
            for i in 1...3 {
                model.beginInteraction(at: model.selected!.points[1], tolerance: 5)
                model.continueInteraction(at: CGPoint(x: 700 + i * 20, y: 1600 + i * 20)); model.endInteraction(); canvas.synchronize()
                let start = CFAbsoluteTimeGetCurrent()
                let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                canvas.cacheDisplay(in: canvas.bounds, to: rep); lastImage = rep.cgImage
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            let median = samples.sorted()[1], output = try XCTUnwrap(lastImage)
            let scale = Double(output.height) / Double(size.1)
            let midpoint = CGPoint(x: 430 * scale, y: 880 * scale)
            let reds = (-3...3).flatMap { dx in (-3...3).map { dy in
                pixel(output, x: Int(midpoint.x) + dx, y: Int(midpoint.y) + dy)
            }}.filter { $0.r > $0.g + 20 }
            XCTAssertFalse(reds.isEmpty, "Native cache did not include the edited arrow")
            print("Native offscreen cache \(size.0)x\(size.1): \(median) ms median at 600pt height (Debug, \(output.width)x\(output.height) backing pixels)")
            XCTAssertLessThan(median, 250)
            XCTAssertTrue(canvas.backgroundImage === model.source)
        }
    }
    func testPasteFromLargerScreenshotAndEdgeDuplicateNudgeStayReachable() throws {
        let model = ScreenshotEditorModel(canvas: image())
        var object = ScreenshotAnnotation(kind: .rectangle, frame: CGRect(x: 1000, y: 1000, width: 800, height: 600))
        object.style.filled = true
        model.paste(object)
        let pasted = try XCTUnwrap(model.selected)
        XCTAssertEqual(pasted.bounds, CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertNotNil(model.hitTest(CGPoint(x: 200, y: 150), tolerance: 3))
        model.moveSelection(by: CGPoint(x: 1000, y: 1000)); XCTAssertEqual(model.selected?.bounds, pasted.bounds)
        model.duplicateSelection(); XCTAssertEqual(model.selected?.bounds, pasted.bounds)
        model.undo(); XCTAssertEqual(model.selected, pasted)
        model.undo(); XCTAssertTrue(model.annotations.isEmpty)
    }
    func testZoomOnlyUpdatesRetainedShapeAndArrowHeadScaleWithoutRebuildingPaths() throws {
        let (_, canvas, model) = canvasFixture(zoom: 0.25)
        stroke(model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 80)); canvas.synchronize()
        let scene = try XCTUnwrap(canvas.layer?.sublayers?.first)
        let shape = try XCTUnwrap(scene.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let count = canvas.objectLayerUpdateCount, oldScale = shape.contentsScale
        canvas.zoom = 2
        XCTAssertGreaterThan(shape.contentsScale, oldScale)
        XCTAssertEqual(shape.sublayers?.first?.contentsScale, shape.contentsScale)
        XCTAssertEqual(canvas.objectLayerUpdateCount, count)
        XCTAssertLessThan(shape.bounds.width, CGFloat(model.width))
    }

    func testNativeTextAutoFitZoomUpdatesFontAndInsetsWithoutChangingSourceSize() throws {
        let (window, canvas, model) = canvasFixture(zoom: 0.5); defer { window.close() }
        canvas.beginText(at: CGPoint(x: 30, y: 40))
        let entry = try XCTUnwrap(canvas.textEntry)
        entry.insertText("Unchanged source size", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(entry.font?.pointSize, 12)
        canvas.zoom = 1
        XCTAssertEqual(entry.font?.pointSize, 24)
        XCTAssertEqual(entry.textContainerInset, CGSize(width: 4, height: 4))
        canvas.commitText(); XCTAssertEqual(model.selected?.style.fontSize, 24)
    }

    func testObjectMenuResolvesCanvasAfterToolbarOwnsFocus() throws {
        let editor = ScreenshotEditorWindowController(canvas: image(), fileName: "Fixture.jpg")
        let window = try XCTUnwrap(editor.window as? ScreenshotEditorWindow); defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let canvas = try XCTUnwrap(window.canvasResponder)
        let control = NSButton(title: "Focusable fixture control", target: nil, action: nil)
        window.contentView?.addSubview(control)
        window.makeFirstResponder(control)
        XCTAssertTrue(window.canvasResponder === canvas)
        XCTAssertFalse(window.firstResponder is ScreenshotCanvasView)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        canvas.annotationPasteboard = board
        stroke(editor.model, tool: .arrow, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 80))
        let copy = NSMenuItem(title: "Copy", action: NSSelectorFromString("commandDispatch:"), keyEquivalent: "c")
        XCTAssertTrue(window.validateUserInterfaceItem(copy)); window.commandDispatch(copy)
        XCTAssertNotNil(board.data(forType: ScreenshotCanvasView.annotationPasteboardType))
        let paste = NSMenuItem(title: "Paste", action: copy.action, keyEquivalent: "v")
        XCTAssertTrue(window.validateUserInterfaceItem(paste)); window.commandDispatch(paste)
        XCTAssertEqual(editor.model.annotations.count, 2)
        let cut = NSMenuItem(title: "Cut", action: copy.action, keyEquivalent: "x")
        window.commandDispatch(cut); XCTAssertEqual(editor.model.annotations.count, 1)
    }
    func testFreehandExportUsesSourceWidthAndUndoRemovesOnlyItsObject() throws {
        let model = ScreenshotEditorModel(canvas: image())
        model.brushSize = 16
        stroke(model, tool: .freehand, from: CGPoint(x: 40, y: 150), to: CGPoint(x: 300, y: 150))
        let object = try XCTUnwrap(model.selected)
        let output = try ScreenshotImageExport.composite(model.snapshot())
        let width = (130...170).filter { y in
            let value = pixel(output, x: 150, y: y)
            return value.r > value.g + 30
        }.count
        XCTAssertGreaterThanOrEqual(width, 14)
        model.undo(); XCTAssertTrue(model.annotations.isEmpty)
        model.redo(); XCTAssertEqual(model.selected, object)
    }
    func testEscapeCancelsPointerChangeAndRearmedToolDraws() throws {
        let (window, canvas, model) = canvasFixture(); defer { window.close() }
        canvas.mouseDown(with: try pointerEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), canvas: canvas))
        canvas.mouseDragged(with: try pointerEvent(.leftMouseDragged, at: CGPoint(x: 180, y: 80), canvas: canvas))
        canvas.cancelOperation(nil)
        XCTAssertTrue(model.annotations.isEmpty); XCTAssertFalse(model.canUndo)
        XCTAssertEqual(model.tool, .select)
        model.selectTool(.arrow)
        canvas.mouseDown(with: try pointerEvent(.leftMouseDown, at: CGPoint(x: 20, y: 140), canvas: canvas))
        canvas.mouseUp(with: try pointerEvent(.leftMouseUp, at: CGPoint(x: 180, y: 230), canvas: canvas))
        XCTAssertEqual(model.annotations.count, 1); XCTAssertEqual(model.generation, 1)
    }
    func testSceneLayerRenderingPreservesTopLeftSourceAndShapeCoordinates() throws {
        let context = ScreenshotSceneRenderer.bitmapContext(width: 400, height: 300)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.translateBy(x: 0, y: 300); context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 60, height: 50))
        let model = ScreenshotEditorModel(canvas: context.makeImage()!), canvas = ScreenshotCanvasView()
        canvas.model = model; canvas.zoom = 0.5; canvas.invalidateCanvasSize()
        model.filled = true
        stroke(model, tool: .rectangle, from: CGPoint(x: 100, y: 20), to: CGPoint(x: 180, y: 80)); canvas.synchronize()
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; canvas.invalidateCanvasSize()
        defer { window.close() }
        canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let output = try XCTUnwrap(rep.cgImage)
        print("Native canvas cache \(output.width)x\(output.height), layer \(String(describing: canvas.layer?.bounds))")
        let sx = output.width / 200, sy = output.height / 150
        XCTAssertGreaterThan(pixel(output, x: 10 * sx, y: 10 * sy).b, 230)
        XCTAssertLessThan(pixel(output, x: 10 * sx, y: 10 * sy).r, 50)
        XCTAssertGreaterThan(pixel(output, x: 70 * sx, y: 25 * sy).r, 220)
        XCTAssertLessThan(pixel(output, x: 70 * sx, y: 25 * sy).g, 100)
    }

    func testMalformedObjectClipboardIsRejectedWithoutChangingHistory() throws {
        let (window, canvas, model) = canvasFixture(); defer { window.close() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        canvas.annotationPasteboard = board
        for object in [ScreenshotAnnotation(kind: .arrow, points: [CGPoint(x: 2, y: 2)]),
                       ScreenshotAnnotation(kind: .freehand),
                       ScreenshotAnnotation(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100_000, height: 100))] {
            board.clearContents(); board.setData(try JSONEncoder().encode(object), forType: ScreenshotCanvasView.annotationPasteboardType)
            canvas.paste(nil)
        }
        XCTAssertTrue(model.annotations.isEmpty); XCTAssertFalse(model.canUndo)
    }

    func testSameWindowFocusLossClearsHeldSpaceAndInterruptedPanCursor() throws {
        let (window, canvas, model) = canvasFixture(); defer { window.close() }
        window.makeFirstResponder(canvas)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        let before = NSCursor.current
        canvas.keyDown(with: space)
        canvas.mouseDown(with: try pointerEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), canvas: canvas))
        let control = NSButton(title: "Local control", target: nil, action: nil)
        canvas.addSubview(control); window.makeFirstResponder(control)
        XCTAssertEqual(NSCursor.current, before)
        window.makeFirstResponder(canvas)
        canvas.mouseDown(with: try pointerEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), canvas: canvas))
        canvas.mouseUp(with: try pointerEvent(.leftMouseUp, at: CGPoint(x: 180, y: 80), canvas: canvas))
        XCTAssertEqual(model.annotations.count, 1)
        canvas.keyDown(with: space)
        model.selectTool(.freehand)
        canvas.mouseDown(with: try pointerEvent(.leftMouseDown, at: CGPoint(x: 30, y: 150), canvas: canvas))
        canvas.mouseUp(with: try pointerEvent(.leftMouseUp, at: CGPoint(x: 200, y: 230), canvas: canvas))
        XCTAssertEqual(model.annotations.count, 2)
    }

    func testRejectedOversizedCopyAndCutPreserveObjectAndExistingClipboard() throws {
        let (window, canvas, model) = canvasFixture(); defer { window.close() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        canvas.annotationPasteboard = board
        board.setString("Existing isolated clipboard", forType: .string)
        model.commitText(String(repeating: "x", count: 100_001), frame: CGRect(x: 20, y: 20, width: 200, height: 80))
        let object = try XCTUnwrap(model.selected), generation = model.generation
        canvas.copy(nil); canvas.cut(nil)
        XCTAssertEqual(model.selected, object); XCTAssertEqual(model.generation, generation)
        XCTAssertEqual(board.string(forType: .string), "Existing isolated clipboard")
    }
    func testLongFreehandRetainsSamplesWithOneUndoWithinInteractiveBudget() throws {
        let model = ScreenshotEditorModel(canvas: image(width: 2400, height: 3600)), canvas = ScreenshotCanvasView()
        canvas.model = model; canvas.zoom = 1.0 / 6; canvas.invalidateCanvasSize()
        model.selectTool(.freehand); model.beginInteraction(at: CGPoint(x: 50, y: 100), tolerance: 3)
        var lateSamples: [Double] = []
        for i in 1...5000 {
            let point = CGPoint(x: 50 + i % 1000, y: 100 + i / 1000 * 60)
            let start = CFAbsoluteTimeGetCurrent()
            model.continueInteraction(at: point); canvas.synchronize()
            if i > 4500 { lateSamples.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
        }
        model.endInteraction(); canvas.synchronize()
        let object = try XCTUnwrap(model.selected)
        XCTAssertEqual(object.points.count, 5001); XCTAssertEqual(model.generation, 1)
        let median = lateSamples.sorted()[lateSamples.count / 2], maximum = lateSamples.max()!
        print("Long freehand 5000 samples: \(median) ms late update median, \(maximum) ms max (Debug, model + path/layer submission)")
        XCTAssertLessThan(median, 16.7)
        model.undo(); XCTAssertTrue(model.annotations.isEmpty)
        model.redo(); XCTAssertEqual(model.selected, object)
        XCTAssertTrue(canvas.backgroundImage === model.source)
    }

    func testLargeTextPreviewHasBoundedAllocationAndKeepsSourceGeometry() throws {
        let model = ScreenshotEditorModel(canvas: image(width: 3200, height: 7500)), canvas = ScreenshotCanvasView()
        canvas.model = model; canvas.zoom = 1
        model.commitText("Large source-size text box", frame: CGRect(x: 0, y: 0, width: 3200, height: 7500))
        canvas.synchronize()
        let scene = try XCTUnwrap(canvas.layer?.sublayers?.first)
        let textLayer = try XCTUnwrap(scene.sublayers?.last)
        let preview = try XCTUnwrap(textLayer.contents) as! CGImage
        XCTAssertLessThanOrEqual(preview.width * preview.height, 4_010_000)
        XCTAssertEqual(model.selected?.frame.width, 3200)
        XCTAssertLessThan(try XCTUnwrap(model.selected).frame.height, 100)
        XCTAssertEqual(model.selected?.style.fontSize, 24)
        XCTAssertTrue(canvas.backgroundImage === model.source)
    }
    private func mosaicSource() -> CGImage {
        let context = ScreenshotSceneRenderer.bitmapContext(width: 200, height: 160)!
        context.translateBy(x: 0, y: 160); context.scaleBy(x: 1, y: -1)
        for x in 0..<200 {
            context.setFillColor(CGColor(srgbRed: x.isMultiple(of: 2) ? 1 : 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 80))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: x.isMultiple(of: 2) ? 1 : 0, alpha: 1))
            context.fill(CGRect(x: x, y: 80, width: 1, height: 80))
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 140, y: 0, width: 60, height: 80))
        return context.makeImage()!
    }

    func testMosaicCreationMoveResizeDeleteAndCropShareUndoHistory() throws {
        let model = ScreenshotEditorModel(canvas: mosaicSource())
        stroke(model, tool: .mosaic, from: CGPoint(x: 101.5, y: 61.5), to: CGPoint(x: 20.5, y: 20.5))
        let original = try XCTUnwrap(model.selected)
        XCTAssertEqual(original.frame, CGRect(x: 20, y: 20, width: 82, height: 42))
        XCTAssertEqual(model.tool, .select); XCTAssertEqual(model.generation, 1)
        XCTAssertEqual(model.hitTest(CGPoint(x: 60, y: 40), tolerance: 1)?.id, original.id)
        model.moveSelection(by: CGPoint(x: 10, y: 10))
        model.beginInteraction(at: CGPoint(x: 112, y: 72), tolerance: 2)
        model.continueInteraction(at: CGPoint(x: 130, y: 90)); model.endInteraction()
        XCTAssertEqual(model.selected?.frame, CGRect(x: 30, y: 30, width: 100, height: 60))
        model.undo(); model.undo(); XCTAssertEqual(model.selected, original)
        model.deleteSelection(); XCTAssertTrue(model.annotations.isEmpty)
        model.undo(); XCTAssertEqual(model.selected, original)
        stroke(model, tool: .crop, from: CGPoint(x: 40, y: 30), to: CGPoint(x: 160, y: 140))
        model.cropToSelection()
        XCTAssertEqual(model.annotations.first?.frame, original.frame.offsetBy(dx: -40, dy: -30))
        XCTAssertEqual(model.width, 120)
        model.undo(); XCTAssertEqual(model.annotations, [original]); XCTAssertEqual(model.width, 200)
        model.undo(); XCTAssertTrue(model.annotations.isEmpty)
        model.redo(); XCTAssertEqual(model.annotations, [original])
    }

    func testMosaicRejectsEmptyGesturesAndCancellationAndSupportsRepeatShortcut() throws {
        let model = ScreenshotEditorModel(canvas: mosaicSource()), canvas = ScreenshotCanvasView()
        canvas.model = model
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "m", charactersIgnoringModifiers: "m",
            isARepeat: false, keyCode: 46))
        canvas.keyDown(with: key); XCTAssertEqual(model.tool, .mosaic)
        model.beginInteraction(at: CGPoint(x: 20, y: 20), tolerance: 2); model.endInteraction()
        XCTAssertTrue(model.annotations.isEmpty); XCTAssertFalse(model.canUndo)
        model.selectTool(.mosaic)
        model.beginInteraction(at: CGPoint(x: 20, y: 20), tolerance: 2)
        model.continueInteraction(at: CGPoint(x: 100, y: 20)); model.endInteraction()
        XCTAssertTrue(model.annotations.isEmpty); XCTAssertFalse(model.canUndo)
        model.selectTool(.mosaic)
        model.beginInteraction(at: CGPoint(x: 20, y: 20), tolerance: 2)
        model.continueInteraction(at: CGPoint(x: 100, y: 60)); model.cancelInteraction()
        XCTAssertTrue(model.annotations.isEmpty); XCTAssertFalse(model.canUndo)
        model.beginInteraction(at: CGPoint(x: 20, y: 20), tolerance: 2, modifiers: .shift)
        model.continueInteraction(at: CGPoint(x: 100, y: 60), modifiers: .shift); model.endInteraction()
        XCTAssertEqual(model.tool, .mosaic); XCTAssertEqual(model.annotations.count, 1)
    }

    func testMosaicExportsPixelateOnlyCoveredAreaAndFlattenPDF() throws {
        let model = ScreenshotEditorModel(canvas: mosaicSource())
        model.commitText("Hidden annotation", frame: CGRect(x: 25, y: 25, width: 70, height: 30))
        stroke(model, tool: .mosaic, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 140))
        model.setZoomExact(0.5)
        let snapshot = model.snapshot()
        for format in ScreenshotExportFormat.allCases {
            let data = try ScreenshotImageExport.encode(snapshot, format: format)
            let output: CGImage
            if format == .pdf {
                let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
                let page = try XCTUnwrap(document.page(at: 1))
                var resources: CGPDFDictionaryRef?, images: CGPDFDictionaryRef?, fonts: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(page.dictionary), "Resources", &resources))
                XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &images))
                XCTAssertEqual(CGPDFDictionaryGetCount(try XCTUnwrap(images)), 1)
                XCTAssertFalse(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "Font", &fonts))
                let context = ScreenshotSceneRenderer.bitmapContext(width: 200, height: 160)!
                context.drawPDFPage(page); output = try XCTUnwrap(context.makeImage())
            } else {
                output = try XCTUnwrap(ScreenshotImageExport.decode(data: data))
            }
            XCTAssertEqual(output.width, 200); XCTAssertEqual(output.height, 160)
            let top = pixel(output, x: 30, y: 40), adjacent = pixel(output, x: 31, y: 40)
            XCTAssertGreaterThan(top.r, 50); XCTAssertLessThan(top.r, 205)
            XCTAssertEqual(top.r, adjacent.r, accuracy: format == .jpg ? 12 : 1)
            XCTAssertLessThan(top.b, 20)
            let bottom = pixel(output, x: 30, y: 120)
            XCTAssertGreaterThan(bottom.b, 50); XCTAssertLessThan(bottom.r, 20)
            let outside = pixel(output, x: 150, y: 10)
            XCTAssertGreaterThan(outside.r, 220)
        }
        XCTAssertEqual(pixel(model.source, x: 30, y: 40).r, 255)
        XCTAssertEqual(pixel(model.source, x: 31, y: 40).r, 0)
    }

    func testMosaicPreviewMatchesExportAfterMovingCroppingAndUndo() throws {
        let model = ScreenshotEditorModel(canvas: mosaicSource()), canvas = ScreenshotCanvasView()
        canvas.model = model
        stroke(model, tool: .mosaic, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 60))
        model.select(nil); canvas.synchronize()
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.close() }
        func verify(x: Int, y: Int) throws {
            canvas.invalidateCanvasSize(); canvas.synchronize(); canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
            let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            let preview = try XCTUnwrap(rep.cgImage)
            let expected = pixel(try ScreenshotImageExport.composite(model.snapshot()), x: x, y: y)
            let actual = pixel(preview, x: x * preview.width / model.width, y: y * preview.height / model.height)
            XCTAssertEqual(actual.r, expected.r, accuracy: 2)
            XCTAssertEqual(actual.b, expected.b, accuracy: 2)
        }
        try verify(x: 30, y: 30)
        model.select(model.annotations.first?.id); model.moveSelection(by: CGPoint(x: 0, y: 80)); model.select(nil)
        try verify(x: 30, y: 110)
        stroke(model, tool: .crop, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 160, y: 120))
        model.cropToSelection(); try verify(x: 30, y: 110)
        model.undo(); model.select(nil); try verify(x: 30, y: 110)
    }

    func testMosaicPreviewDoesNotOutlineWhiteRegionsAtFractionalZoom() throws {
        let model = ScreenshotEditorModel(canvas: image()), canvas = ScreenshotCanvasView()
        canvas.model = model
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.close() }
        stroke(model, tool: .mosaic, from: CGPoint(x: 41, y: 31), to: CGPoint(x: 261, y: 151))
        model.select(nil)
        for zoom in [0.73, 0.97, 1.37] {
            canvas.zoom = zoom; canvas.synchronize(); canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
            let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            let output = try XCTUnwrap(rep.cgImage)
            let context = try XCTUnwrap(ScreenshotSceneRenderer.bitmapContext(width: output.width, height: output.height))
            context.draw(output, in: CGRect(x: 0, y: 0, width: output.width, height: output.height))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let scaleX = CGFloat(output.width) / canvas.bounds.width * zoom
            let scaleY = CGFloat(output.height) / canvas.bounds.height * zoom
            var darkest: UInt8 = 255
            for y in Int(29 * scaleY)...Int(153 * scaleY) {
                for x in Int(39 * scaleX)...Int(263 * scaleX) {
                    let offset = y * context.bytesPerRow + x * 4
                    darkest = min(darkest, bytes[offset], bytes[offset + 1], bytes[offset + 2])
                }
            }
            XCTAssertGreaterThanOrEqual(darkest, 250, "White mosaic must blend into the white canvas at zoom \(zoom)")
        }
    }

}
