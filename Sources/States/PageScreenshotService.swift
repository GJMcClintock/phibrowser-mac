// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Captures a page through an app-owned CDP session and copies a validated JPEG.
@MainActor
final class PageScreenshotService {
    static let shared = PageScreenshotService()
    static let maxBase64Bytes = 30 * 1024 * 1024

    enum Outcome: Equatable {
        case copied(Data)
        case captureFailed, timedOut, invalidImage, clipboardChanged, clipboardWriteFailed, cancelled
    }

    private let pasteboard: NSPasteboard
    private let captureJPEG: @MainActor (String, TimeInterval) async throws -> String?
    private let uptime: () -> TimeInterval
    private let timeoutInterval: TimeInterval
    private(set) var isCapturing = false

    init(pasteboard: NSPasteboard = .general,
         timeoutInterval: TimeInterval = 60,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         captureJPEG: @escaping @MainActor (String, TimeInterval) async throws -> String? = {
             try await PageScreenshotService.capturePage(targetId: $0, timeout: $1)
         }) {
        self.pasteboard = pasteboard
        self.timeoutInterval = timeoutInterval
        self.uptime = uptime
        self.captureJPEG = captureJPEG
    }

    func canCapture(in state: BrowserState, area: Bool = false) -> Bool {
        guard !isCapturing, ChromiumLauncher.sharedInstance().bridge != nil,
              state.windowId >= 0, let tab = state.pageCommandTarget,
              tab.guid >= 0, !tab.isShowingNativeNTP,
              let targetId = tab.webContentWrapper?.devToolsTargetId,
              !targetId.isEmpty else { return false }
        if area {
            return !tab.isLoading && tab.webContentView?.window?.isVisible == true && tab.webContentView?.superview != nil
        }
        return true
    }

    /// Snap the page target, title, and destination window before the first suspension.
    func capture(in state: BrowserState, area: Bool = false) {
        guard canCapture(in: state, area: area),
              let tab = state.pageCommandTarget,
              let targetId = tab.webContentWrapper?.devToolsTargetId else { return }
        let windowId = state.windowId
        let title = tab.title
        let pageView = tab.webContentView
        let host = pageView?.superview
        let window = pageView?.window
        let frame = pageView?.frame
        let bounds = pageView?.bounds
        let url = tab.url
        let selectionDeadline = uptime() + timeoutInterval
        let isValid: () -> Bool = { [weak state, weak tab, weak pageView, weak host, weak window] in
            guard area else { return true }
            return state?.pageCommandTarget === tab && tab != nil && tab?.url == url && tab?.isLoading == false
                && tab?.webContentWrapper?.devToolsTargetId == targetId
                && pageView?.superview === host && host != nil
                && pageView?.window === window && window?.isVisible == true
                && pageView?.frame == frame && pageView?.bounds == bounds
                && ProcessInfo.processInfo.systemUptime < selectionDeadline
        }
        let operation: (@MainActor (String, TimeInterval) async throws -> String?)?
        if area {
            operation = { target, timeout in
                try await Self.capturePage(targetId: target, timeout: timeout, selectRegion: { viewport, scroll in
                    guard let pageView, isValid() else { throw CancellationError() }
                    guard let region = await PageScreenshotRegionSelector.select(over: pageView, viewport: viewport, scroll: scroll, isValid: isValid),
                          isValid() else { throw CancellationError() }
                    return region
                })
            }
        } else {
            operation = nil
        }
        if start(targetId: targetId, windowId: windowId, operation: operation, isValid: isValid, completion: { outcome in
            if case .copied(let jpeg) = outcome {
                PageScreenshotPresenter.showCopied(jpegData: jpeg, title: title, windowId: windowId, area: area)
                PageScreenshotPresenter.edit(jpegData: jpeg, title: title, windowId: windowId)
                return
            }
            guard outcome != .cancelled else { return }
            OverlayToastCenter.shared.show(title: Self.title(for: outcome), in: .windowId(windowId))
        }) {
            if !area {
                OverlayToastCenter.shared.show(
                    title: NSLocalizedString("browser.screenshot.capturing", value: "Taking full page screenshot…",
                                             comment: "Screenshot - Progress toast while capturing the current webpage"),
                    in: .windowId(windowId))
            }
        }
    }

    @discardableResult
    func start(targetId: String, windowId: Int,
               operation: (@MainActor (String, TimeInterval) async throws -> String?)? = nil,
               isValid: @escaping () -> Bool = { true },
               completion: @escaping (Outcome) -> Void) -> Bool {
        guard !isCapturing, !targetId.isEmpty, windowId >= 0 else { return false }
        isCapturing = true
        let started = uptime()
        let deadline = started + timeoutInterval
        AppLogDebug("[Screenshot] capture.begin window=\(windowId) timeout=\(timeoutInterval)s")
        let changeCount = pasteboard.changeCount
        Task { @MainActor in
            let outcome: Outcome
            do {
                let base64 = try await (operation ?? captureJPEG)(targetId, timeoutInterval)
                if !isValid() {
                    outcome = .cancelled
                } else if uptime() >= deadline {
                    outcome = .timedOut
                } else if let base64, let jpeg = Self.validatedJPEG(base64) {
                    // Decoding can consume time; check again before committing.
                    outcome = uptime() >= deadline ? .timedOut : copy(jpeg, changeCount: changeCount)
                } else {
                    outcome = .invalidImage
                }
            } catch is CancellationError {
                outcome = .cancelled
            } catch AppDevToolsPageSession.SessionError.timedOut {
                AppLogWarn("[Screenshot] capture.error reason=timedOut elapsed=\(uptime() - started)s")
                outcome = .timedOut
            } catch {
                AppLogWarn("[Screenshot] capture.error reason=\(error) elapsed=\(uptime() - started)s")
                outcome = .captureFailed
            }
            if case .copied(let jpeg) = outcome {
                AppLogDebug("[Screenshot] capture.end outcome=copied bytes=\(jpeg.count) elapsed=\(uptime() - started)s")
            } else {
                AppLogWarn("[Screenshot] capture.end outcome=\(outcome) elapsed=\(uptime() - started)s")
            }
            isCapturing = false
            completion(outcome)
        }
        return true
    }

    struct CaptureSession {
        var command: (String, [String: Any], TimeInterval) async throws -> [String: Any]
        var close: () -> Void
    }

    typealias SelectionScroll = (CGSize) async throws -> PageScreenshotViewport
    typealias SelectRegion = (PageScreenshotViewport, @escaping SelectionScroll) async throws -> PageScreenshotRegion

    static func capturePage(
        targetId: String, timeout: TimeInterval,
        selectRegion: SelectRegion? = nil,
        openSession: (String, TimeInterval) async throws -> CaptureSession = { targetId, timeout in
            let session = try await AppDevToolsPageSession.open(
                targetId: targetId, timeout: timeout,
                maxMessageBytes: maxBase64Bytes + 4096)
            return CaptureSession(command: { method, params, timeout in
                try await session.command(method, params: params, timeout: timeout)
            }, close: { session.close() })
        }
    ) async throws -> String? {
        let started = ProcessInfo.processInfo.systemUptime
        AppLogDebug("[Screenshot] session.open timeout=\(min(10, timeout))s")
        let session = try await openSession(targetId, min(10, timeout))
        defer {
            session.close()
            AppLogDebug("[Screenshot] session.close elapsed=\(ProcessInfo.processInfo.systemUptime - started)s")
        }

        func send(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
            try Task.checkCancellation()
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 0 else { throw AppDevToolsPageSession.SessionError.timedOut }
            AppLogDebug("[Screenshot] cdp.begin method=\(method) timeout=\(min(15, remaining))s")
            do {
                return try await session.command(method, params, min(15, remaining))
            } catch {
                AppLogWarn("[Screenshot] cdp.error method=\(method) reason=\(error)")
                throw error
            }
        }

        let before = try documentIdentity(await send("Page.getFrameTree"))
        let metrics = try await send("Page.getLayoutMetrics")
        let pixelRatio = try await send("Runtime.evaluate", params: [
            "expression": "window.devicePixelRatio", "returnByValue": true,
        ])
        guard let size = metrics["cssContentSize"] as? [String: Any],
              let x = finiteNumber(size["x"]), let y = finiteNumber(size["y"]),
              let rawWidth = finiteNumber(size["width"]),
              let rawHeight = finiteNumber(size["height"]),
              let result = pixelRatio["result"] as? [String: Any],
              let dpr = finiteNumber(result["value"]),
              rawWidth > 0, rawHeight > 0, dpr > 0 else {
            AppLogWarn("[Screenshot] dimensions.reject reason=invalidMetricsOrDPR")
            throw AppDevToolsPageSession.SessionError.commandFailed("Invalid screenshot page dimensions")
        }
        var clipRect = CGRect(x: x, y: y, width: rawWidth, height: rawHeight)
        func readViewport(_ metrics: [String: Any]) async throws -> PageScreenshotViewport {
            let info = try await send("Runtime.evaluate", params: [
                "expression": "({scrollbarWidth: Math.max(0, window.innerWidth - document.documentElement.clientWidth), scrollbarHeight: Math.max(0, window.innerHeight - document.documentElement.clientHeight), scale: window.visualViewport ? window.visualViewport.scale : 1})",
                "returnByValue": true,
            ])
            return try viewportSnapshot(metrics, info: info)
        }
        var selectionViewport: PageScreenshotViewport?
        if let selectRegion {
            let viewport = try await readViewport(metrics)
            // Pin scrolling to this document so a navigation cannot receive an old scroll request.
            let world = try await send("Page.createIsolatedWorld", params: [
                "frameId": before.0, "worldName": "phi-screenshot-selection",
            ])
            guard let contextId = world["executionContextId"] as? Int,
                  try documentIdentity(await send("Page.getFrameTree")) == before else { throw CancellationError() }
            var currentViewport = viewport
            let region = try await selectRegion(viewport, { delta in
                guard delta.width.isFinite, delta.height.isFinite else { throw CancellationError() }
                // An unsolicited scroll can make the anchor stale before the first drag or
                // between input events. Only accept offsets produced by this selection.
                let startingMetrics = try await send("Page.getLayoutMetrics")
                let startingViewport = try await readViewport(startingMetrics)
                guard startingViewport == currentViewport else { throw CancellationError() }
                if delta != .zero {
                    let response = try await send("Runtime.evaluate", params: [
                        "expression": "new Promise(resolve => { window.scrollBy({left: \(delta.width), top: \(delta.height), behavior: 'instant'}); requestAnimationFrame(() => requestAnimationFrame(() => resolve(true))); })",
                        "contextId": contextId, "awaitPromise": true, "returnByValue": true,
                    ])
                    guard response["exceptionDetails"] == nil else { throw CancellationError() }
                }
                let identity = try documentIdentity(await send("Page.getFrameTree"))
                let updatedMetrics = delta == .zero ? startingMetrics : try await send("Page.getLayoutMetrics")
                let ratio = try await send("Runtime.evaluate", params: [
                    "expression": "window.devicePixelRatio", "returnByValue": true,
                ])
                let updatedViewport = delta == .zero ? startingViewport : try await readViewport(updatedMetrics)
                guard identity == before, updatedViewport.hasSameGeometry(as: viewport),
                      let result = ratio["result"] as? [String: Any],
                      finiteNumber(result["value"]) == dpr else { throw CancellationError() }
                currentViewport = updatedViewport
                return updatedViewport
            })
            // The accepted rectangle is already in document coordinates. Only selection-time
            // scrolling is allowed; a later scroll, zoom, resize or navigation still cancels.
            let selectedIdentity = try documentIdentity(await send("Page.getFrameTree"))
            let selectedMetrics = try await send("Page.getLayoutMetrics")
            let selectedRatio = try await send("Runtime.evaluate", params: [
                "expression": "window.devicePixelRatio", "returnByValue": true,
            ])
            let selectedViewport = try await readViewport(selectedMetrics)
            guard before == selectedIdentity, selectedViewport == currentViewport,
                  let selectedResult = selectedRatio["result"] as? [String: Any],
                  finiteNumber(selectedResult["value"]) == dpr,
                  let content = selectedMetrics["cssContentSize"] as? [String: Any],
                  let contentX = finiteNumber(content["x"]), let contentY = finiteNumber(content["y"]),
                  let contentWidth = finiteNumber(content["width"]), let contentHeight = finiteNumber(content["height"]),
                  contentWidth > 0, contentHeight > 0,
                  let regionClip = region.cssClip(content: CGRect(x: contentX, y: contentY, width: contentWidth, height: contentHeight)) else { throw CancellationError() }
            clipRect = regionClip
            selectionViewport = selectedViewport
        }
        let width = selectRegion == nil ? ceil(clipRect.width) : clipRect.width
        let height = selectRegion == nil ? ceil(clipRect.height) : clipRect.height
        let pixelWidth = width * dpr, pixelHeight = height * dpr
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0 else {
            AppLogWarn("[Screenshot] dimensions.reject reason=invalidPhysicalDimensions")
            throw AppDevToolsPageSession.SessionError.commandFailed("Invalid screenshot page dimensions")
        }
        var scale = min(1, 16_384 / pixelWidth, 16_384 / pixelHeight)
        let boundedWidth = ceil(pixelWidth * scale), boundedHeight = ceil(pixelHeight * scale)
        if boundedWidth * boundedHeight > 64_000_000 {
            let areaScale = sqrt(64_000_000 / (boundedWidth * boundedHeight))
            // Leave one pixel per axis for Chromium's integer-size rounding.
            scale *= min((floor(boundedWidth * areaScale) - 1) / boundedWidth,
                         (floor(boundedHeight * areaScale) - 1) / boundedHeight)
        }
        if scale < 1 { scale = scale.nextDown }
        let outputWidth = ceil(pixelWidth * scale), outputHeight = ceil(pixelHeight * scale)
        AppLogDebug("[Screenshot] dimensions css=\(width)x\(height) dpr=\(dpr) originalPixels=\(pixelWidth * pixelHeight) scale=\(scale) output=\(outputWidth)x\(outputHeight) projectedPixels=\(outputWidth * outputHeight)")
        guard scale.isFinite, scale > 0,
              outputWidth >= 1, outputHeight >= 1,
              outputWidth <= 16_384, outputHeight <= 16_384,
              outputWidth * outputHeight <= 64_000_000 else {
            AppLogWarn("[Screenshot] dimensions.reject reason=outputPixelLimit output=\(outputWidth)x\(outputHeight) maxDimension=16384 maxPixels=64000000 beforeCapture=true")
            throw AppDevToolsPageSession.SessionError.commandFailed("Page is too large to copy as one screenshot")
        }
        let shot = try await send("Page.captureScreenshot", params: [
            "format": "jpeg", "quality": 85, "fromSurface": true, "captureBeyondViewport": true,
            "clip": ["x": clipRect.minX, "y": clipRect.minY, "width": width, "height": height, "scale": scale],
        ])
        guard let base64 = shot["data"] as? String,
              base64.hasPrefix("/9j/"), base64.utf8.count <= maxBase64Bytes else {
            AppLogWarn("[Screenshot] image.reject reason=invalidJPEGPrefixOrPayloadSize")
            throw AppDevToolsPageSession.SessionError.commandFailed("Invalid or oversized screenshot image")
        }
        AppLogDebug("[Screenshot] image.received base64Bytes=\(base64.utf8.count) elapsed=\(ProcessInfo.processInfo.systemUptime - started)s")
        if let selectionViewport {
            let finalMetrics = try await send("Page.getLayoutMetrics")
            let finalRatio = try await send("Runtime.evaluate", params: [
                "expression": "window.devicePixelRatio", "returnByValue": true,
            ])
            let finalViewport = try await readViewport(finalMetrics)
            guard finalViewport == selectionViewport,
                  let finalResult = finalRatio["result"] as? [String: Any],
                  finiteNumber(finalResult["value"]) == dpr else { throw CancellationError() }
        }
        let after = try documentIdentity(await send("Page.getFrameTree"))
        guard before == after else {
            AppLogWarn("[Screenshot] document.reject frameChanged=\(before.0 != after.0) loaderChanged=\(before.1 != after.1) urlChanged=\(before.2 != after.2)")
            throw AppDevToolsPageSession.SessionError.commandFailed("Page navigated while taking the screenshot")
        }
        return base64
    }

    private static func viewportSnapshot(_ reply: [String: Any], info: [String: Any]) throws -> PageScreenshotViewport {
        guard let viewport = reply["cssVisualViewport"] as? [String: Any],
              let x = finiteNumber(viewport["pageX"]), let y = finiteNumber(viewport["pageY"]),
              let width = finiteNumber(viewport["clientWidth"]), let height = finiteNumber(viewport["clientHeight"]),
              let result = info["result"] as? [String: Any], let value = result["value"] as? [String: Any],
              let scrollbarWidth = finiteNumber(value["scrollbarWidth"]), let scrollbarHeight = finiteNumber(value["scrollbarHeight"]),
              let scale = finiteNumber(value["scale"]), scale > 0,
              scrollbarWidth >= 0, scrollbarHeight >= 0, width > 0, height > 0 else {
            throw AppDevToolsPageSession.SessionError.commandFailed("Invalid screenshot viewport")
        }
        let viewSize = CGSize(width: width + scrollbarWidth / scale, height: height + scrollbarHeight / scale)
        guard viewSize.width.isFinite, viewSize.height.isFinite else { throw CancellationError() }
        return PageScreenshotViewport(rect: CGRect(x: x, y: y, width: width, height: height), viewSize: viewSize, scale: scale)
    }

    private static func documentIdentity(_ reply: [String: Any]) throws -> (String, String, String) {
        guard let tree = reply["frameTree"] as? [String: Any],
              let frame = tree["frame"] as? [String: Any],
              let id = frame["id"] as? String, !id.isEmpty,
              let loaderId = frame["loaderId"] as? String, !loaderId.isEmpty,
              let url = frame["url"] as? String, !url.isEmpty else {
            throw AppDevToolsPageSession.SessionError.commandFailed("Unable to identify the page document")
        }
        return (id, loaderId, url)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private func copy(_ jpeg: Data, changeCount: Int) -> Outcome {
        let item = NSPasteboardItem()
        guard item.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) else { return .clipboardWriteFailed }
        // No suspension between this check and the write: preserve a newer copy.
        guard pasteboard.changeCount == changeCount else { return .clipboardChanged }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return .clipboardWriteFailed }
        return .copied(jpeg)
    }

    static func validatedJPEG(_ base64: String) -> Data? {
        guard base64.utf8.count <= maxBase64Bytes,
              let data = Data(base64Encoded: base64),
              data.starts(with: [0xff, 0xd8, 0xff]),
              data.suffix(2).elementsEqual([0xff, 0xd9]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let w = width.int64Value, h = height.int64Value
        AppLogDebug("[Screenshot] image.validate width=\(w) height=\(h) bytes=\(data.count)")
        guard w > 0, h > 0, w <= 32_768, h <= 32_768, w * h <= 64_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return data
    }

    private static func title(for outcome: Outcome) -> String {
        switch outcome {
        case .copied:
            return NSLocalizedString("browser.screenshot.copied", value: "Full page screenshot copied",
                                     comment: "Screenshot - Success toast after copying the JPEG to the clipboard")
        case .timedOut:
            return NSLocalizedString("browser.screenshot.timedOut", value: "Screenshot timed out. Please try again.",
                                     comment: "Screenshot - Error toast when the page capture does not finish in time")
        case .clipboardChanged:
            return NSLocalizedString("browser.screenshot.clipboardChanged", value: "Screenshot not copied because the clipboard changed",
                                     comment: "Screenshot - Toast when preserving content the user copied during capture")
        case .clipboardWriteFailed:
            return NSLocalizedString("browser.screenshot.copyFailed", value: "Could not copy the screenshot",
                                     comment: "Screenshot - Error toast when the system clipboard write fails")
        case .cancelled:
            return "" // Cancellation is silent.
        case .captureFailed, .invalidImage:
            return NSLocalizedString("browser.screenshot.captureFailed", value: "Could not take a screenshot of this page",
                                     comment: "Screenshot - Error toast when page capture fails or returns an invalid image")
        }
    }
}
