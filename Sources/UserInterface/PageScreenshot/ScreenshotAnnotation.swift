// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit
import CoreText

struct ScreenshotColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1
    static let red = Self(red: 0.95, green: 0.12, blue: 0.12)
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

enum ScreenshotTool: String, CaseIterable, Sendable { case select, crop, arrow, freehand, text, rectangle, ellipse, mosaic }

struct ScreenshotAnnotationStyle: Codable, Equatable, Sendable {
    var color = ScreenshotColor.red
    var width: CGFloat = 2.5
    var arrowHeadLength: CGFloat = 32
    var fontSize: CGFloat = 24
    var filled = false
}

/// Geometry is retained in original image pixels, with an upper-left origin.
struct ScreenshotAnnotation: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case arrow, freehand, rectangle, ellipse, text, mosaic }
    var id = UUID()
    var kind: Kind
    var points: [CGPoint] = []
    var frame: CGRect = .zero
    var text = ""
    var style = ScreenshotAnnotationStyle()

    var bounds: CGRect {
        guard kind == .arrow || kind == .freehand, let first = points.first else { return frame }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { result, point in
            CGRect(x: min(result.minX, point.x), y: min(result.minY, point.y),
                   width: max(result.maxX, point.x) - min(result.minX, point.x),
                   height: max(result.maxY, point.y) - min(result.minY, point.y))
        }
    }

    func translated(by delta: CGPoint) -> Self {
        var result = self
        result.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        result.frame = frame.offsetBy(dx: delta.x, dy: delta.y)
        return result
    }

    func resized(to rect: CGRect) -> Self {
        var result = self
        let old = bounds
        result.points = points.map { point in
            CGPoint(x: rect.minX + (old.width > 0 ? (point.x - old.minX) / old.width : 0.5) * rect.width,
                    y: rect.minY + (old.height > 0 ? (point.y - old.minY) / old.height : 0.5) * rect.height)
        }
        result.frame = rect
        return result.fittingText()
    }

    func fittingText() -> Self {
        guard kind == .text else { return self }
        var result = self
        result.frame.size.width = max(12, frame.width)
        result.frame.size.height = ScreenshotSceneRenderer.textHeight(for: result)
        return result
    }

    var path: CGPath {
        let path = CGMutablePath()
        switch kind {
        case .rectangle: path.addRoundedRect(in: frame, cornerWidth: 4, cornerHeight: 4)
        case .ellipse: path.addEllipse(in: frame)
        case .arrow:
            guard points.count == 2 else { return path }
            path.move(to: points[0]); path.addLine(to: points[1])
        case .freehand:
            guard let first = points.first else { return path }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        case .text, .mosaic: path.addRect(frame)
        }
        return path
    }

    var arrowHead: CGPath? {
        guard kind == .arrow, points.count == 2 else { return nil }
        let start = points[0], end = points[1]
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 0 else { return nil }
        // Open arrowhead with round-joined 45-degree wings.
        let h = min(0.3 * distance, style.arrowHeadLength)
        let ux = (start.x - end.x) * h / distance, uy = (start.y - end.y) * h / distance
        let c = CGFloat(Double(bitPattern: 0x3fe6a09e667f3bcd))
        let s = CGFloat(Double(bitPattern: 0x3fe6a09e667f3bcc))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: end.x + c * ux - s * uy, y: end.y + s * ux + c * uy))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x + c * ux + s * uy, y: end.y + c * uy - s * ux))
        return path
    }

    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if kind == .text || kind == .mosaic { return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        if (kind == .rectangle || kind == .ellipse), path.contains(point) { return true }
        if arrowHead?.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point) == true { return true }
        return path.copy(strokingWithWidth: style.width + tolerance * 2, lineCap: .round,
                         lineJoin: .round, miterLimit: 10).contains(point)
    }

    enum Handle: Int, CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, start, end }
    var handles: [(Handle, CGPoint)] {
        if kind == .arrow, points.count == 2 { return [(.start, points[0]), (.end, points[1])] }
        let b = bounds
        if kind == .text {
            return [(.left, CGPoint(x: b.minX, y: b.midY)), (.right, CGPoint(x: b.maxX, y: b.midY))]
        }
        return [(.topLeft, CGPoint(x: b.minX, y: b.minY)), (.top, CGPoint(x: b.midX, y: b.minY)),
                (.topRight, CGPoint(x: b.maxX, y: b.minY)), (.right, CGPoint(x: b.maxX, y: b.midY)),
                (.bottomRight, CGPoint(x: b.maxX, y: b.maxY)), (.bottom, CGPoint(x: b.midX, y: b.maxY)),
                (.bottomLeft, CGPoint(x: b.minX, y: b.maxY)), (.left, CGPoint(x: b.minX, y: b.midY))]
    }
    func handle(at point: CGPoint, tolerance: CGFloat) -> Handle? {
        handles.min(by: { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) })
            .flatMap { hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance ? $0.0 : nil }
    }
    func editing(handle: Handle, at point: CGPoint, mirrored: Bool = false) -> Self {
        var result = self
        if kind == .arrow {
            if handle == .start { result.points[0] = point }
            if handle == .end { result.points[1] = point }
            return result
        }
        let b = bounds
        if kind == .text {
            guard handle == .left || handle == .right else { return self }
            let minimumWidth: CGFloat = 12
            if mirrored {
                let halfWidth = max(minimumWidth / 2, handle == .left ? b.midX - point.x : point.x - b.midX)
                result.frame.origin.x = b.midX - halfWidth
                result.frame.size.width = halfWidth * 2
            } else if handle == .left {
                result.frame.origin.x = min(point.x, b.maxX - minimumWidth)
                result.frame.size.width = b.maxX - result.frame.minX
            } else {
                result.frame.size.width = max(minimumWidth, point.x - b.minX)
            }
            return result.fittingText()
        }
        var x1 = b.minX, x2 = b.maxX, y1 = b.minY, y2 = b.maxY
        if [.topLeft, .left, .bottomLeft].contains(handle) { x1 = point.x }
        if [.topRight, .right, .bottomRight].contains(handle) { x2 = point.x }
        if [.topLeft, .top, .topRight].contains(handle) { y1 = point.y }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { y2 = point.y }
        let flipX = x1 > x2, flipY = y1 > y2
        if mirrored {
            if [.topLeft, .left, .bottomLeft].contains(handle) { x2 = b.maxX - (x1 - b.minX) }
            if [.topRight, .right, .bottomRight].contains(handle) { x1 = b.minX - (x2 - b.maxX) }
            if [.topLeft, .top, .topRight].contains(handle) { y2 = b.maxY - (y1 - b.minY) }
            if [.bottomLeft, .bottom, .bottomRight].contains(handle) { y1 = b.minY - (y2 - b.maxY) }
        }
        let target = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        return transformed(from: b, to: target, flipX: flipX, flipY: flipY)
    }

    func transformed(from old: CGRect, to rect: CGRect, flipX: Bool = false, flipY: Bool = false) -> Self {
        func map(_ p: CGPoint) -> CGPoint {
            let x = old.width > 0 ? (p.x - old.minX) / old.width : 0.5
            let y = old.height > 0 ? (p.y - old.minY) / old.height : 0.5
            return CGPoint(x: rect.minX + (flipX ? 1 - x : x) * rect.width,
                           y: rect.minY + (flipY ? 1 - y : y) * rect.height)
        }
        var result = self
        result.points = points.map(map)
        let a = map(frame.origin), b = map(CGPoint(x: frame.maxX, y: frame.maxY))
        result.frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        return result.fittingText()
    }
}

/// CGImage is immutable; annotation arrays are copied by value before background export.
struct ScreenshotSnapshot: @unchecked Sendable {
    let source: CGImage
    let annotations: [ScreenshotAnnotation]
    var width: Int { source.width }
    var height: Int { source.height }
}

/// Both the export compositor and retained text layers use this text layout.
enum ScreenshotSceneRenderer {
    /// Height is derived from the configured font and width, never used to shrink the font.
    static func textHeight(for annotation: ScreenshotAnnotation) -> CGFloat {
        // Include the empty final line so Return leaves room for the insertion point.
        let text = annotation.text.isEmpty || annotation.text.hasSuffix("\n") || annotation.text.hasSuffix("\r")
            ? annotation.text + " " : annotation.text
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(".AppleSystemUIFont" as CFString, annotation.style.fontSize, nil)
        ])
        let size = CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(attributed),
            CFRange(location: 0, length: 0), nil,
            CGSize(width: max(4, annotation.frame.width - 8), height: .greatestFiniteMagnitude), nil)
        return ceil(size.height) + 8
    }
    /// Generate only the coarse pixels, keeping interactive previews small even for large areas.
    /// White compositing makes the mosaic opaque over transparent sources and earlier annotations.
    static func mosaicImage(source: CGImage, rect: CGRect) -> CGImage? {
        guard !rect.isEmpty, !rect.isNull, let cropped = source.cropping(to: rect),
              let context = bitmapContext(width: max(1, Int(ceil(rect.width / 20))),
                                          height: max(1, Int(ceil(rect.height / 20)))) else { return nil }
        let target = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
        context.interpolationQuality = .high
        context.draw(cropped, in: target)
        return context.makeImage()
    }
    static func mosaicRect(_ annotation: ScreenshotAnnotation, source: CGImage) -> CGRect {
        annotation.frame.integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
    }
    static func draw(_ annotation: ScreenshotAnnotation, in context: CGContext, source: CGImage? = nil) {
        context.saveGState()
        defer { context.restoreGState() }
        if annotation.kind == .mosaic {
            let rect = source.map { mosaicRect(annotation, source: $0) } ?? annotation.frame.integral
            guard !rect.isEmpty, !rect.isNull else { return }
            // Fail closed if bitmap creation fails; never expose the original through a missing mosaic.
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(rect)
            if let source, let image = mosaicImage(source: source, rect: rect) {
                context.interpolationQuality = .none
                context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            }
            return
        }
        context.setStrokeColor(annotation.style.color.cgColor)
        context.setFillColor(annotation.style.color.nsColor.withAlphaComponent(0.8 * annotation.style.color.alpha).cgColor)
        context.setLineWidth(annotation.style.width)
        context.setLineCap(.round); context.setLineJoin(.round)
        if annotation.kind == .text {
            let rect = annotation.frame.insetBy(dx: 4, dy: 4)
            guard rect.width > 0, rect.height > 0 else { return }
            let attributed = NSAttributedString(string: annotation.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(".AppleSystemUIFont" as CFString, annotation.style.fontSize, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.style.color.cgColor,
            ])
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        } else {
            context.addPath(annotation.path)
            context.drawPath(using: annotation.style.filled && [.rectangle, .ellipse].contains(annotation.kind) ? .fillStroke : .stroke)
            if let head = annotation.arrowHead { context.addPath(head); context.strokePath() }
        }
    }
    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        guard ScreenshotImageExport.isSizeSupported(width: width, height: height),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
