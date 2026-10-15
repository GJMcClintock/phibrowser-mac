// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Phi

@MainActor
final class ImagePreviewExportTests: XCTestCase {
    func testLocalImageRetainsOriginalBytesAfterSourceIsRemoved() async throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = ImagePreviewItem(
            id: "local", source: .localFile(url), title: nil, mimeType: nil, suggestedFilename: "Photo.jpg"
        )
        let asset = try await ImagePreviewLoader().load(item)
        try FileManager.default.removeItem(at: url)

        XCTAssertEqual(asset.originalData, png)
        XCTAssertEqual(asset.contentType, .png)
        XCTAssertEqual(ImagePreviewViewController.suggestedExportFilename(for: item, contentType: asset.contentType), "Photo.png")
    }

    func testAnimatedGIFRetainsAllFramesAndOriginalEncodingOnCacheHit() async throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for color in [NSColor.red, NSColor.blue] {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            let frame = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = data as Data
        let item = ImagePreviewItem(
            id: "animation", source: .rawData(original, mimeType: "image/gif"),
            title: "Animation", mimeType: nil, suggestedFilename: nil
        )
        let loader = ImagePreviewLoader()
        _ = try await loader.load(item)
        let cached = try await loader.load(item)

        XCTAssertTrue(cached.isAnimated)
        XCTAssertEqual(cached.originalData, original)
        XCTAssertEqual(cached.contentType, .gif)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(cached.originalData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        XCTAssertEqual(ImagePreviewViewController.suggestedExportFilename(for: item, contentType: cached.contentType), "Animation.gif")
    }

    func testExportNameKeepsCompatibleExtensionAndSuppliesMissingName() {
        let named = ImagePreviewItem(
            id: "named", source: .remoteURL(URL(string: "https://example.com/image?id=1")!),
            title: nil, mimeType: nil, suggestedFilename: "Photo.jpeg"
        )
        XCTAssertEqual(ImagePreviewViewController.suggestedExportFilename(for: named, contentType: .jpeg), "Photo.jpeg")

        let unnamed = ImagePreviewItem(
            id: "unnamed", source: .rawData(Data(), mimeType: nil),
            title: nil, mimeType: nil, suggestedFilename: nil
        )
        let filename = ImagePreviewViewController.suggestedExportFilename(for: unnamed, contentType: .png)
        XCTAssertEqual((filename as NSString).pathExtension, "png")
        XCTAssertFalse((filename as NSString).deletingPathExtension.isEmpty)
    }
}
