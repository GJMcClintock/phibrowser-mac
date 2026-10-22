// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotExportFormat: String, CaseIterable, Sendable {
    case png, jpg, pdf

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpg: return .jpeg
        case .pdf: return .pdf
        }
    }
}

enum ScreenshotImageExport {
    enum ExportError: Error { case unsupportedSize, imageCreationFailed, encodingFailed }
    static func isSizeSupported(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 32768 && height <= 32768 && width <= 64_000_000 / height
    }
    static func decode(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              isSizeSupported(width: width, height: height) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    static func composite(_ snapshot: ScreenshotSnapshot) throws -> CGImage {
        guard let context = ScreenshotSceneRenderer.bitmapContext(width: snapshot.width, height: snapshot.height) else { throw ExportError.unsupportedSize }
        // White is the export backdrop for transparent source images and annotations.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
        context.draw(snapshot.source, in: CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
        context.translateBy(x: 0, y: CGFloat(snapshot.height)); context.scaleBy(x: 1, y: -1)
        for annotation in snapshot.annotations { ScreenshotSceneRenderer.draw(annotation, in: context, source: snapshot.source) }
        guard let image = context.makeImage() else { throw ExportError.imageCreationFailed }
        return image
    }
    static func encode(_ snapshot: ScreenshotSnapshot, format: ScreenshotExportFormat) throws -> Data {
        guard isSizeSupported(width: snapshot.width, height: snapshot.height) else { throw ExportError.unsupportedSize }
        let data = NSMutableData()
        switch format {
        case .png, .jpg:
            guard let destination = CGImageDestinationCreateWithData(data, format.contentType.identifier as CFString, 1, nil) else { throw ExportError.encodingFailed }
            let properties: [CFString: Any] = format == .jpg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
            CGImageDestinationAddImage(destination, try composite(snapshot), properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
        case .pdf:
            var box = CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
            guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ExportError.encodingFailed }
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
            let needsFlattening = snapshot.annotations.contains { annotation in
                if annotation.kind == .mosaic { return true }
                if annotation.kind == .text {
                    return !box.contains(ScreenshotSceneRenderer.textDrawingBounds(for: annotation))
                }
                // Include stroke and arrowhead extents when checking for clipped artwork.
                let padding = annotation.style.width / 2
                    + (annotation.kind == .arrow ? annotation.style.arrowHeadLength : 0)
                return !box.contains(annotation.bounds.insetBy(dx: -padding, dy: -padding))
            }
            if needsFlattening {
                // Page bounds and clipping paths do not remove recoverable PDF content.
                // Flatten obscured or clipped objects without changing the editable document.
                context.draw(try composite(snapshot), in: box)
            } else {
                context.draw(snapshot.source, in: box)
                context.translateBy(x: 0, y: CGFloat(snapshot.height)); context.scaleBy(x: 1, y: -1)
                for annotation in snapshot.annotations { ScreenshotSceneRenderer.draw(annotation, in: context) }
            }
            context.endPDFPage(); context.closePDF()
        }
        return data as Data
    }
    static func write(_ snapshot: ScreenshotSnapshot, format: ScreenshotExportFormat, to url: URL) throws {
        try encode(snapshot, format: format).write(to: url, options: .atomic)
    }
}
