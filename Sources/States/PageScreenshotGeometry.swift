// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation
import CoreGraphics

/// The visible page and native-view extent in CSS pixels, including classic scrollbars.
struct PageScreenshotViewport: Equatable {
    let rect: CGRect
    let viewSize: CGSize
    let scale: Double

    func hasSameGeometry(as other: Self) -> Bool {
        rect.size == other.rect.size && viewSize == other.viewSize && scale == other.scale
    }

    func pagePoint(from point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + min(rect.width, max(0, point.x - bounds.minX) * viewSize.width / bounds.width),
                y: rect.minY + min(rect.height, max(0, point.y - bounds.minY) * viewSize.height / bounds.height))
    }

    func viewRect(for pageRect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + (pageRect.minX - rect.minX) * bounds.width / viewSize.width,
               y: bounds.minY + (pageRect.minY - rect.minY) * bounds.height / viewSize.height,
               width: pageRect.width * bounds.width / viewSize.width,
               height: pageRect.height * bounds.height / viewSize.height)
    }

    func pageDelta(from delta: CGSize, in bounds: CGRect) -> CGSize {
        CGSize(width: delta.width * viewSize.width / bounds.width,
               height: delta.height * viewSize.height / bounds.height)
    }
}

/// A document-space selection. Scrolling changes its endpoint, never its anchor.
struct PageScreenshotRegion: Equatable {
    let rect: CGRect

    init?(selection: CGRect, minimumSize: CGSize = CGSize(width: 1, height: 1)) {
        guard selection.origin.x.isFinite, selection.origin.y.isFinite,
              selection.width.isFinite, selection.height.isFinite,
              selection.maxX.isFinite, selection.maxY.isFinite else { return nil }
        let rect = selection.standardized
        guard rect.width >= minimumSize.width, rect.height >= minimumSize.height else { return nil }
        self.rect = rect
    }

    func cssClip(content: CGRect) -> CGRect? {
        let clip = rect.intersection(content)
        guard !clip.isNull, clip.width > 0, clip.height > 0 else { return nil }
        return clip
    }
}
