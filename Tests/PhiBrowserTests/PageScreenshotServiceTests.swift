import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Phi

@MainActor
final class PageScreenshotServiceTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.setString("original clipboard", forType: .string)
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    private func png(size: Int = 2, noise: Bool = false) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(bitmap.bitmapData!, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
        if noise {
            var seed: UInt32 = 0x12345678
            for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
                seed ^= seed << 13
                seed ^= seed >> 17
                seed ^= seed << 5
                bitmap.bitmapData![index] = UInt8(truncatingIfNeeded: seed)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testSnapshotsTargetAndRejectsRepeatedInvocationUntilCompletion() async throws {
        let board = pasteboard(), image = try png()
        let started = expectation(description: "Capture starts")
        let completed = expectation(description: "Capture completes")
        var resume: CheckedContinuation<String?, Error>?
        var capturedTarget: String?
        let service = PageScreenshotService(pasteboard: board, capturePNG: { targetId, timeout in
            capturedTarget = targetId
            XCTAssertEqual(timeout, 60)
            return try await withCheckedThrowingContinuation {
                resume = $0
                started.fulfill()
            }
        })
        XCTAssertFalse(service.start(targetId: "", windowId: 7) { _ in XCTFail() })
        XCTAssertFalse(service.start(targetId: "page-42", windowId: -1) { _ in XCTFail() })
        XCTAssertTrue(service.start(targetId: "page-42", windowId: 7) { outcome in
            XCTAssertEqual(outcome, .copied(image))
            completed.fulfill()
        })
        XCTAssertTrue(service.isCapturing)
        XCTAssertFalse(service.start(targetId: "page-99", windowId: 8) { _ in XCTFail() })
        // Let the capture start while its response remains suspended.
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(capturedTarget, "page-42")
        try XCTUnwrap(resume).resume(returning: image.base64EncodedString())
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(service.isCapturing)
        XCTAssertEqual(board.data(forType: NSPasteboard.PasteboardType(UTType.png.identifier)), image)
    }

    func testSuccessCopiesBinaryPNGAndCompletesOnce() async throws {
        let board = pasteboard(), image = try png()
        let completed = expectation(description: "PNG copied")
        var outcomes: [PageScreenshotService.Outcome] = []
        let service = PageScreenshotService(pasteboard: board, capturePNG: { _, _ in image.base64EncodedString() })
        service.start(targetId: "page-42", windowId: 7) { outcome in
            outcomes.append(outcome)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(board.data(forType: NSPasteboard.PasteboardType(UTType.png.identifier)), image)
        XCTAssertNil(board.string(forType: .string))
        XCTAssertNotNil(NSImage(pasteboard: board))
        XCTAssertNil(board.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)))
        XCTAssertEqual(outcomes, [.copied(image)])
        XCTAssertFalse(service.isCapturing)
    }

    func testCaptureFailurePreservesClipboardAndAllowsRetry() async throws {
        let board = pasteboard(), image = try png()
        let failed = expectation(description: "Capture fails")
        let retried = expectation(description: "Retry succeeds")
        var shouldFail = true
        let service = PageScreenshotService(pasteboard: board, capturePNG: { _, _ in
            if shouldFail { throw AppDevToolsPageSession.SessionError.connectionClosed }
            return image.base64EncodedString()
        })
        let count = board.changeCount
        service.start(targetId: "page-42", windowId: 7) { outcome in
            XCTAssertEqual(outcome, .captureFailed)
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(service.isCapturing)
        XCTAssertEqual(board.changeCount, count)
        shouldFail = false
        XCTAssertTrue(service.start(targetId: "page-99", windowId: 8) { outcome in
            XCTAssertEqual(outcome, .copied(image))
            retried.fulfill()
        })
        await fulfillment(of: [retried], timeout: 2)
    }

    func testNewerUserCopyIsPreserved() async throws {
        let board = pasteboard(), image = try png()
        let completed = expectation(description: "New clipboard preserved")
        let service = PageScreenshotService(pasteboard: board, capturePNG: { _, _ in
            board.clearContents()
            board.setString("newer user copy", forType: .string)
            return image.base64EncodedString()
        })
        service.start(targetId: "page-42", windowId: 7) { outcome in
            XCTAssertEqual(outcome, .clipboardChanged)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(board.string(forType: .string), "newer user copy")
        XCTAssertNil(board.data(forType: NSPasteboard.PasteboardType(UTType.png.identifier)))
    }

    func testExpiredDeadlineRejectsLateResponseAndPreservesClipboard() async throws {
        let board = pasteboard(), image = try png()
        var time: TimeInterval = 100
        let completed = expectation(description: "Late response rejected")
        let service = PageScreenshotService(pasteboard: board, uptime: { time }, capturePNG: { _, _ in
            time = 160
            return image.base64EncodedString()
        })
        let count = board.changeCount
        service.start(targetId: "page-42", windowId: 7) { outcome in
            XCTAssertEqual(outcome, .timedOut)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(board.changeCount, count)
        XCTAssertFalse(service.isCapturing)
    }

    func testCDPTimeoutPreservesClipboardAndReleasesCapture() async {
        let board = pasteboard()
        let completed = expectation(description: "CDP timeout reported")
        let service = PageScreenshotService(pasteboard: board, capturePNG: { _, _ in
            throw AppDevToolsPageSession.SessionError.timedOut
        })
        let count = board.changeCount
        service.start(targetId: "page-42", windowId: 7) { outcome in
            XCTAssertEqual(outcome, .timedOut)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(board.changeCount, count)
        XCTAssertFalse(service.isCapturing)
    }

    func testMissingAndInvalidPNGResponsesPreserveClipboard() async throws {
        for data in [nil, "not base64", Data("not a PNG".utf8).base64EncodedString()] as [String?] {
            let board = pasteboard()
            let completed = expectation(description: "Invalid image rejected")
            let service = PageScreenshotService(pasteboard: board, capturePNG: { _, _ in data })
            let count = board.changeCount
            service.start(targetId: "page-42", windowId: 7) { outcome in
                XCTAssertEqual(outcome, .invalidImage)
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertEqual(board.changeCount, count)
            XCTAssertFalse(service.isCapturing)
        }
    }

    func testPNGValidationRejectsTruncatedOversizedAndExcessiveDimensions() throws {
        let image = try png()
        XCTAssertEqual(PageScreenshotService.validatedPNG(image.base64EncodedString()), image)
        XCTAssertNil(PageScreenshotService.validatedPNG(image.prefix(33).base64EncodedString()))
        XCTAssertNil(PageScreenshotService.validatedPNG(String(repeating: "A", count: PageScreenshotService.maxBase64Bytes + 1)))
        XCTAssertNil(PageScreenshotService.validatedPNG(image.dropLast(2).base64EncodedString()))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: image))
        let jpeg = try XCTUnwrap(decoded.representation(using: .jpeg, properties: [:]))
        XCTAssertNil(PageScreenshotService.validatedPNG(jpeg.base64EncodedString()))
        // Patch IHDR dimensions and its CRC without allocating an oversized bitmap.
        for (width, height) in [(0, 2), (32_769, 1), (8_001, 8_000)] {
            var bytes = image
            for (offset, value) in [(16, width), (20, height)] {
                bytes.replaceSubrange(offset..<(offset + 4), with: bigEndianBytes(UInt32(value)))
            }
            var crc: UInt32 = 0xffffffff
            for byte in bytes[12..<29] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
            }
            bytes.replaceSubrange(29..<33, with: bigEndianBytes(crc ^ 0xffffffff))
            XCTAssertNil(PageScreenshotService.validatedPNG(bytes.base64EncodedString()))
        }
    }

    private func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }


    private final class CDPFixture {
        var calls: [(method: String, params: [String: Any], timeout: TimeInterval)] = []
        var openedTargets: [String] = []
        var openTimeout: TimeInterval?
        var closeCount = 0
        var frameCount = 0
        var size: [String: Any] = ["x": 0, "y": 0, "width": 1200, "height": 4000]
        var viewport: [String: Any] = ["pageX": 10, "pageY": 500, "clientWidth": 800, "clientHeight": 600]
        var afterViewport: [String: Any]?
        var viewportInfo: [String: Any] = ["scrollbarWidth": 0, "scrollbarHeight": 0, "scale": 1]
        var afterViewportInfo: [String: Any]?
        var infoCount = 0
        var onScroll: (() -> Void)?
        var scrollFails = false
        var onScreenshot: (() -> Void)?
        var onViewportInfo: ((Int) -> Void)?
        var metricsCount = 0
        var dpr: Any = 1
        var data: Any?
        var frame: [String: Any] = ["id": "frame-1", "loaderId": "loader-1", "url": "https://example.invalid/"]
        var afterFrame: [String: Any]?
        var failingMethod: String?
        var failFinalFrameQuery = false
        var openFails = false
        var commandDelay: UInt64 = 0

        init(data: String) { self.data = data }

        func open(_ target: String, _ timeout: TimeInterval) async throws -> PageScreenshotService.CaptureSession {
            openedTargets.append(target)
            openTimeout = timeout
            if openFails { throw AppDevToolsPageSession.SessionError.upgradeFailed }
            return .init(command: { method, params, timeout in
                self.calls.append((method, params, timeout))
                if self.commandDelay > 0 { try await Task.sleep(nanoseconds: self.commandDelay) }
                if self.failingMethod == method || (method == "Page.getFrameTree" && self.frameCount == 1 && self.failFinalFrameQuery) {
                    throw AppDevToolsPageSession.SessionError.connectionClosed
                }
                switch method {
                case "Page.createIsolatedWorld": return ["executionContextId": 42]
                case "Page.getFrameTree":
                    self.frameCount += 1
                    return ["frameTree": ["frame": self.frameCount == 1 ? self.frame : (self.afterFrame ?? self.frame)]]
                case "Page.getLayoutMetrics":
                    self.metricsCount += 1
                    return ["cssContentSize": self.size,
                            "cssVisualViewport": self.metricsCount == 1 ? self.viewport : (self.afterViewport ?? self.viewport)]
                case "Runtime.evaluate":
                    if params["contextId"] as? Int == 42 {
                        self.onScroll?()
                        return self.scrollFails ? ["exceptionDetails": [:]] : ["result": ["value": true]]
                    }
                    if params["expression"] as? String == "window.devicePixelRatio" { return ["result": ["value": self.dpr]] }
                    self.infoCount += 1
                    self.onViewportInfo?(self.infoCount)
                    return ["result": ["value": self.infoCount == 1 ? self.viewportInfo : (self.afterViewportInfo ?? self.viewportInfo)]]
                case "Page.captureScreenshot": self.onScreenshot?(); return self.data.map { ["data": $0] } ?? [:]
                default: XCTFail("Unexpected CDP method: \(method)"); return [:]
                }
            }, close: { self.closeCount += 1 })
        }
    }

    private func capture(_ fixture: CDPFixture, timeout: TimeInterval = 60) async throws -> String? {
        try await PageScreenshotService.capturePage(targetId: "page-42", timeout: timeout, openSession: fixture.open)
    }

    func testCDPCaptureUsesLosslessPNGAndFullDocumentClip() async throws {
        let image = try png(), fixture = CDPFixture(data: image.base64EncodedString())
        fixture.size = ["x": 1.25, "y": -3.5, "width": 1200.1, "height": 4000.2]
        let result = try await capture(fixture)
        XCTAssertEqual(result, image.base64EncodedString())
        XCTAssertEqual(PageScreenshotService.validatedPNG(try XCTUnwrap(result)), image)
        XCTAssertEqual(fixture.openedTargets, ["page-42"])
        XCTAssertEqual(fixture.openTimeout, 10)
        XCTAssertEqual(fixture.closeCount, 1)
        XCTAssertEqual(fixture.calls.map(\.method), ["Page.getFrameTree", "Page.getLayoutMetrics", "Runtime.evaluate", "Page.captureScreenshot", "Page.getFrameTree"])
        let params = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params)
        XCTAssertEqual(params["format"] as? String, "png")
        XCTAssertNil(params["quality"])
        XCTAssertEqual(params["fromSurface"] as? Bool, true)
        XCTAssertEqual(params["captureBeyondViewport"] as? Bool, true)
        let clip = try XCTUnwrap(params["clip"] as? [String: Double])
        XCTAssertEqual(clip, ["x": 1.25, "y": -3.5, "width": 1201, "height": 4001, "scale": 1])
        XCTAssertEqual(fixture.calls[2].params["expression"] as? String, "window.devicePixelRatio")
        XCTAssertEqual(fixture.calls[2].params["returnByValue"] as? Bool, true)
        XCTAssertTrue(fixture.calls.allSatisfy { $0.timeout > 0 && $0.timeout <= 15 })
    }

    func testCDPCaptureFitsRetinaLongPagesInBothOrientations() async throws {
        for (width, height) in [(1719, 8718), (8718, 1719)] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.size = ["x": 0, "y": 0, "width": width, "height": height]
            fixture.dpr = 2
            _ = try await capture(fixture)
            let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
            XCTAssertEqual(try XCTUnwrap(clip["scale"]), 16384.0 / (8718 * 2), accuracy: 0.0000001)
            XCTAssertEqual(clip["width"], Double(width))
            XCTAssertEqual(clip["height"], Double(height))
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureKeepsUnitScaleAt16KBoundaryAndForNonRetinaPage() async throws {
        for (height, dpr) in [(8192, 2), (8718, 1)] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.size = ["x": 0, "y": 0, "width": 1719, "height": height]
            fixture.dpr = dpr
            _ = try await capture(fixture)
            let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
            XCTAssertEqual(clip["scale"], 1)
        }
    }

    func testCDPCaptureRejectsInvalidDimensionsBeforeScreenshotAndCloses() async throws {
        for (key, value) in [("x", Double.nan as Any), ("y", "0" as Any), ("width", 0 as Any), ("height", -1 as Any), ("width", true as Any), ("height", NSNull() as Any)] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.size[key] = value
            do { _ = try await capture(fixture); XCTFail("Accepted invalid \(key)") }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) { XCTAssertEqual(message, "Invalid screenshot page dimensions") }
            XCTAssertFalse(fixture.calls.contains { $0.method == "Page.captureScreenshot" })
            XCTAssertEqual(fixture.closeCount, 1)
        }
        for value: Any in [0, -1, Double.infinity, "2", true, NSNull()] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.dpr = value
            do { _ = try await capture(fixture); XCTFail("Accepted invalid DPR") }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) { XCTAssertEqual(message, "Invalid screenshot page dimensions") }
            XCTAssertFalse(fixture.calls.contains { $0.method == "Page.captureScreenshot" })
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureScalesWideRetinaPagesBeforeApplyingPixelLimits() async throws {
        for width in [1719, 1904] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.size = ["x": 0, "y": 0, "width": width, "height": 9519]
            fixture.dpr = 2
            _ = try await capture(fixture)
            let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
            let scale = try XCTUnwrap(clip["scale"])
            XCTAssertEqual(clip["width"], Double(width))
            XCTAssertEqual(clip["height"], 9519)
            XCTAssertEqual(scale, 16384.0 / (9519 * 2), accuracy: 0.0000001)
            XCTAssertLessThanOrEqual(ceil(Double(width) * 2 * scale) * ceil(9519 * 2 * scale), 64_000_000)
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureScalesOversizedPagesWithinRoundedOutputBudget() async throws {
        for (width, height, dpr) in [(16385, 1, 2), (1, 16385, 2), (8001, 8000, 1), (10000, 10000, 2), (20000, 10000, 1), (10000, 20000, 1)] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.size = ["x": 0, "y": 0, "width": width, "height": height]
            fixture.dpr = dpr
            _ = try await capture(fixture)
            let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
            let scale = try XCTUnwrap(clip["scale"])
            let outputWidth = ceil(Double(width * dpr) * scale)
            let outputHeight = ceil(Double(height * dpr) * scale)
            XCTAssertGreaterThan(scale, 0)
            XCTAssertLessThan(scale, 1)
            XCTAssertLessThanOrEqual(outputWidth, 16_384)
            XCTAssertLessThanOrEqual(outputHeight, 16_384)
            XCTAssertLessThanOrEqual(outputWidth * outputHeight, 64_000_000)
            XCTAssertEqual(clip["width"], Double(width))
            XCTAssertEqual(clip["height"], Double(height))
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCapturePreservesUnitScaleAtPixelBudget() async throws {
        let fixture = CDPFixture(data: try png().base64EncodedString())
        fixture.size = ["x": 0, "y": 0, "width": 8000, "height": 8000]
        fixture.dpr = 1
        _ = try await capture(fixture)
        let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
        XCTAssertEqual(clip["scale"], 1)
    }

    func testCDPCaptureRejectsOverflowingPhysicalDimensions() async throws {
        let fixture = CDPFixture(data: try png().base64EncodedString())
        fixture.size = ["x": 0, "y": 0, "width": Double.greatestFiniteMagnitude, "height": 100]
        fixture.dpr = 2
        do { _ = try await capture(fixture); XCTFail("Accepted overflowing dimensions") }
        catch AppDevToolsPageSession.SessionError.commandFailed {}
        XCTAssertFalse(fixture.calls.contains { $0.method == "Page.captureScreenshot" })
        XCTAssertEqual(fixture.closeCount, 1)
    }

    func testCDPCaptureChecksEveryDocumentIdentityFieldAndCloses() async throws {
        for key in ["id", "loaderId", "url"] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.afterFrame = fixture.frame
            fixture.afterFrame?[key] = "changed"
            do { _ = try await capture(fixture); XCTFail("Accepted changed \(key)") }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) { XCTAssertEqual(message, "Page navigated while taking the screenshot") }
            XCTAssertEqual(fixture.frameCount, 2)
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureRejectsMissingDocumentIdentityBeforeScreenshot() async throws {
        for key in ["id", "loaderId", "url"] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.frame[key] = ""
            do { _ = try await capture(fixture); XCTFail("Accepted empty \(key)") }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) { XCTAssertEqual(message, "Unable to identify the page document") }
            XCTAssertTrue(fixture.calls.allSatisfy { $0.method == "Page.getFrameTree" })
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureClosesAfterFailureAtEveryCommand() async throws {
        for method in ["Page.getFrameTree", "Page.getLayoutMetrics", "Runtime.evaluate", "Page.captureScreenshot"] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.failingMethod = method
            do { _ = try await capture(fixture); XCTFail("Ignored command failure") }
            catch AppDevToolsPageSession.SessionError.connectionClosed {}
            XCTAssertEqual(fixture.calls.last?.method, method)
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureRejectsInvalidPNGReplyBeforeFinalFrameQuery() async throws {
        for data: Any? in [nil, 42, "not a PNG", "iVBORw0KGgo" + String(repeating: "A", count: PageScreenshotService.maxBase64Bytes)] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.data = data
            do { _ = try await capture(fixture); XCTFail("Accepted invalid image") }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) { XCTAssertEqual(message, "Invalid or oversized screenshot image") }
            XCTAssertEqual(fixture.frameCount, 1)
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCDPCaptureClosesWhenTotalBudgetExpiresBetweenCommands() async throws {
        let fixture = CDPFixture(data: try png().base64EncodedString())
        fixture.commandDelay = 20_000_000
        do { _ = try await capture(fixture, timeout: 0.01); XCTFail("Ignored deadline") }
        catch AppDevToolsPageSession.SessionError.timedOut {}
        XCTAssertEqual(fixture.closeCount, 1)
        XCTAssertEqual(fixture.openTimeout, 0.01)
    }

    func testCDPCaptureDoesNotCloseAnUnacquiredSession() async throws {
        let fixture = CDPFixture(data: try png().base64EncodedString())
        fixture.openFails = true
        do { _ = try await capture(fixture); XCTFail("Ignored attach failure") }
        catch AppDevToolsPageSession.SessionError.upgradeFailed {}
        XCTAssertEqual(fixture.closeCount, 0)
        XCTAssertTrue(fixture.calls.isEmpty)
    }


    func testCDPCaptureClosesAfterFinalFrameQueryFailureOrInvalidIdentity() async throws {
        for fails in [true, false] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.failFinalFrameQuery = fails
            fixture.afterFrame = [:]
            do { _ = try await capture(fixture); XCTFail("Accepted failed final frame query") }
            catch AppDevToolsPageSession.SessionError.connectionClosed { XCTAssertTrue(fails) }
            catch AppDevToolsPageSession.SessionError.commandFailed(let message) {
                XCTAssertFalse(fails)
                XCTAssertEqual(message, "Unable to identify the page document")
            }
            XCTAssertEqual(fixture.calls.map(\.method), ["Page.getFrameTree", "Page.getLayoutMetrics", "Runtime.evaluate", "Page.captureScreenshot", "Page.getFrameTree"])
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testAreaCaptureMapsVisibleSelectionToScrolledCSSClipWithoutScalingTheFullPage() async throws {
        let fixture = CDPFixture(data: try png().base64EncodedString())
        fixture.size = ["x": 0, "y": 0, "width": 1904, "height": 90000]
        fixture.dpr = 2.5 // Retina at 125% page zoom.
        _ = try await PageScreenshotService.capturePage(targetId: "area", timeout: 60, selectRegion: { viewport, _ in
            let bounds = CGRect(x: 0, y: 0, width: 1000, height: 750)
            let start = viewport.pagePoint(from: CGPoint(x: 100, y: 150), in: bounds)
            let end = viewport.pagePoint(from: CGPoint(x: 300, y: 250), in: bounds)
            return try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)))
        }, openSession: fixture.open)
        let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
        XCTAssertEqual(clip["x"], 90)
        XCTAssertEqual(clip["y"], 620)
        XCTAssertEqual(try XCTUnwrap(clip["width"]), 160, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(clip["height"]), 80, accuracy: 0.0001)
        XCTAssertEqual(clip["scale"], 1)
        XCTAssertFalse(fixture.calls.contains { $0.method == "Emulation.setDeviceMetricsOverride" })
        XCTAssertEqual(fixture.closeCount, 1)
    }

    func testAreaCancellationAndViewportChangesNeverCaptureAndCloseTheSession() async throws {
        for scenario in 0..<4 {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            let region = try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: 10, y: 500, width: 30, height: 40)))
            do {
                _ = try await PageScreenshotService.capturePage(targetId: "area", timeout: 60, selectRegion: { _, _ in
                    if scenario == 0 { throw CancellationError() }
                    if scenario == 1 { fixture.afterFrame = ["id": "frame-1", "loaderId": "reload", "url": "https://example.invalid/"] }
                    if scenario == 2 { fixture.afterViewport = ["pageX": 10, "pageY": 501, "clientWidth": 800, "clientHeight": 600] }
                    if scenario == 3 { fixture.dpr = 2 }
                    return region
                }, openSession: fixture.open)
                XCTFail("Accepted cancelled or stale area")
            } catch is CancellationError {}
            XCTAssertFalse(fixture.calls.contains { $0.method == "Page.captureScreenshot" })
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testCancelledOriginPreservesClipboardAndAllowsRetry() async throws {
        let board = pasteboard(), image = try png()
        let completed = expectation(description: "Origin closed")
        let service = PageScreenshotService(pasteboard: board, capturePNG: { _, _ in image.base64EncodedString() })
        let count = board.changeCount
        service.start(targetId: "area", windowId: 7, isValid: { false }) { outcome in
            XCTAssertEqual(outcome, .cancelled)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(board.changeCount, count)
        XCTAssertFalse(service.isCapturing)
    }

    func testAreaCaptureAccountsForClassicScrollbarsAndPinchScale() async throws {
        let fixture = CDPFixture(data: try png().base64EncodedString())
        fixture.viewport = ["pageX": 10, "pageY": 500, "clientWidth": 400, "clientHeight": 300]
        fixture.viewportInfo = ["scrollbarWidth": 16, "scrollbarHeight": 12, "scale": 2]
        _ = try await PageScreenshotService.capturePage(targetId: "area", timeout: 60, selectRegion: { viewport, _ in
            let bounds = CGRect(x: 0, y: 0, width: 1000, height: 750)
            let start = viewport.pagePoint(from: CGPoint(x: 100, y: 150), in: bounds)
            let end = viewport.pagePoint(from: CGPoint(x: 300, y: 250), in: bounds)
            return try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)))
        }, openSession: fixture.open)
        let clip = try XCTUnwrap(fixture.calls.first { $0.method == "Page.captureScreenshot" }?.params["clip"] as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(clip["x"]), 50.8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(clip["y"]), 561.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(clip["width"]), 81.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(clip["height"]), 40.8, accuracy: 0.001)
    }

    func testAreaViewportChangesWhileScreenshotIsAwaitedRejectTheResultAndCloseSession() async throws {
        let fixture = CDPFixture(data: try png().base64EncodedString())
        let region = try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: 20, y: 510, width: 100, height: 100)))
        fixture.onScreenshot = { fixture.afterViewportInfo = ["scrollbarWidth": 0, "scrollbarHeight": 0, "scale": 1.25] }
        do {
            _ = try await PageScreenshotService.capturePage(targetId: "area", timeout: 60, selectRegion: { _, _ in region }, openSession: fixture.open)
            XCTFail("Accepted a changed viewport")
        } catch is CancellationError {}
        XCTAssertEqual(fixture.closeCount, 1)
        XCTAssertTrue(fixture.calls.contains { $0.method == "Page.captureScreenshot" })
    }

    func testNavigationDuringFinalViewportReadIsRejected() async throws {
        let fixture = CDPFixture(data: try png().base64EncodedString())
        let region = try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: 20, y: 510, width: 100, height: 100)))
        fixture.onViewportInfo = { count in
            if count == 3 { fixture.afterFrame = ["id": "frame-1", "loaderId": "new-loader", "url": "https://example.invalid/"] }
        }
        do {
            _ = try await PageScreenshotService.capturePage(targetId: "area", timeout: 60, selectRegion: { _, _ in region }, openSession: fixture.open)
            XCTFail("Accepted a navigation during final viewport validation")
        } catch AppDevToolsPageSession.SessionError.commandFailed(let message) {
            XCTAssertEqual(message, "Page navigated while taking the screenshot")
        }
        XCTAssertEqual(fixture.closeCount, 1)
    }

    func testSelectionScrollExtendsDocumentClipWithOneScreenshot() async throws {
        let fixture = CDPFixture(data: try png().base64EncodedString())
        fixture.onScroll = {
            fixture.afterViewport = ["pageX": 10, "pageY": 1500, "clientWidth": 800, "clientHeight": 600]
        }
        _ = try await PageScreenshotService.capturePage(targetId: "area", timeout: 60, selectRegion: { initial, scroll in
            let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            let anchor = initial.pagePoint(from: CGPoint(x: 100, y: 100), in: bounds)
            let moved = try await scroll(CGSize(width: 0, height: 1000))
            let endpoint = moved.pagePoint(from: CGPoint(x: 500, y: 500), in: bounds)
            return try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: anchor.x, y: anchor.y, width: endpoint.x - anchor.x, height: endpoint.y - anchor.y)))
        }, openSession: fixture.open)
        let shots = fixture.calls.filter { $0.method == "Page.captureScreenshot" }
        XCTAssertEqual(shots.count, 1)
        let clip = try XCTUnwrap(shots.first?.params["clip"] as? [String: Double])
        XCTAssertEqual(clip, ["x": 110, "y": 600, "width": 400, "height": 1400, "scale": 1])
        let scrollCall = try XCTUnwrap(fixture.calls.first { $0.params["contextId"] as? Int == 42 })
        XCTAssertEqual(scrollCall.params["awaitPromise"] as? Bool, true)
        XCTAssertTrue((scrollCall.params["expression"] as? String)?.contains("behavior: 'instant'") == true)
        XCTAssertEqual(fixture.closeCount, 1)
    }

    func testSelectionScrollRejectsNavigationZoomResizeAndScriptFailure() async throws {
        for scenario in 0..<5 {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            fixture.onScroll = {
                if scenario == 0 { fixture.afterFrame = ["id": "frame-1", "loaderId": "new", "url": "https://example.invalid/"] }
                if scenario == 1 { fixture.dpr = 2 }
                if scenario == 2 { fixture.afterViewport = ["pageX": 10, "pageY": 700, "clientWidth": 700, "clientHeight": 600] }
                if scenario == 3 { fixture.afterViewportInfo = ["scrollbarWidth": 0, "scrollbarHeight": 0, "scale": 2] }
                if scenario == 4 { fixture.scrollFails = true }
            }
            do {
                _ = try await PageScreenshotService.capturePage(targetId: "area", timeout: 60, selectRegion: { _, scroll in
                    _ = try await scroll(CGSize(width: 0, height: 200))
                    return try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: 20, y: 510, width: 100, height: 800)))
                }, openSession: fixture.open)
                XCTFail("Accepted invalid scrolling selection \(scenario)")
            } catch is CancellationError {}
            XCTAssertFalse(fixture.calls.contains { $0.method == "Page.captureScreenshot" })
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

    func testScrollAfterSelectionStillRejectsScreenshot() async throws {
        let fixture = CDPFixture(data: try png().base64EncodedString())
        fixture.onScreenshot = { fixture.afterViewport = ["pageX": 10, "pageY": 900, "clientWidth": 800, "clientHeight": 600] }
        do {
            _ = try await PageScreenshotService.capturePage(targetId: "area", timeout: 60, selectRegion: { _, _ in
                try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: 20, y: 510, width: 100, height: 800)))
            }, openSession: fixture.open)
            XCTFail("Accepted post-selection scrolling")
        } catch is CancellationError {}
        XCTAssertEqual(fixture.closeCount, 1)
    }

    func testNavigationDuringScrollContextCreationNeverOpensSelection() async throws {
        let fixture = CDPFixture(data: try png().base64EncodedString())
        fixture.afterFrame = ["id": "frame-1", "loaderId": "new-loader", "url": "https://example.invalid/"]
        do {
            _ = try await PageScreenshotService.capturePage(targetId: "area", timeout: 60, selectRegion: { _, _ in
                XCTFail("Opened selection on a replacement document")
                throw CancellationError()
            }, openSession: fixture.open)
            XCTFail("Accepted navigation during scroll context creation")
        } catch is CancellationError {}
        XCTAssertFalse(fixture.calls.contains { $0.method == "Page.captureScreenshot" || $0.params["contextId"] != nil })
        XCTAssertEqual(fixture.closeCount, 1)
    }

    func testUnrequestedScrollBeforeRefreshOrWheelInputCancelsWithoutMovingPage() async throws {
        for delta in [CGSize.zero, CGSize(width: 0, height: 100)] {
            let fixture = CDPFixture(data: try png().base64EncodedString())
            do {
                _ = try await PageScreenshotService.capturePage(targetId: "area", timeout: 60, selectRegion: { _, scroll in
                    // The page moved after the initial snapshot, before the user began dragging.
                    fixture.afterViewport = ["pageX": 10, "pageY": 900, "clientWidth": 800, "clientHeight": 600]
                    _ = try await scroll(delta)
                    return try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: 20, y: 510, width: 100, height: 800)))
                }, openSession: fixture.open)
                XCTFail("Accepted a stale selection anchor")
            } catch is CancellationError {}
            XCTAssertFalse(fixture.calls.contains { $0.method == "Page.captureScreenshot" || $0.params["contextId"] != nil })
            XCTAssertEqual(fixture.closeCount, 1)
        }
    }

}
