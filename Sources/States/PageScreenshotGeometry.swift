// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation
import CoreGraphics

/// A selection in page-view proportions, independent of AppKit backing scale.
struct PageScreenshotRegion: Equatable {
    let rect: CGRect

    init?(selection: CGRect, bounds: CGRect, isFlipped: Bool) {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.maxX.isFinite, bounds.maxY.isFinite,
              bounds.width > 0, bounds.height > 0,
              selection.origin.x.isFinite, selection.origin.y.isFinite,
              selection.width.isFinite, selection.height.isFinite else { return nil }
        let clipped = selection.standardized.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        let top = isFlipped ? clipped.minY - bounds.minY : bounds.maxY - clipped.maxY
        rect = CGRect(x: (clipped.minX - bounds.minX) / bounds.width,
                      y: top / bounds.height,
                      width: clipped.width / bounds.width, height: clipped.height / bounds.height)
    }

    func cssClip(viewport: CGRect, viewSize: CGSize? = nil) -> CGRect? {
        let size = viewSize ?? viewport.size
        guard viewport.origin.x.isFinite, viewport.origin.y.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              size.width.isFinite, size.height.isFinite,
              viewport.width > 0, viewport.height > 0, size.width > 0, size.height > 0 else { return nil }
        // A native page view includes classic scrollbars; the visual viewport does not.
        let clip = CGRect(x: viewport.minX + rect.minX * size.width,
                          y: viewport.minY + rect.minY * size.height,
                          width: rect.width * size.width, height: rect.height * size.height).intersection(viewport)
        guard !clip.isNull, clip.width > 0, clip.height > 0 else { return nil }
        return clip
    }
}
