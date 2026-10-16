import CoreGraphics
import XCTest
@testable import Phi

final class PageScreenshotGeometryTests: XCTestCase {
    func testPageCoordinatesRoundTripThroughOffsetBoundsAndScrolledViewport() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let viewport = PageScreenshotViewport(rect: CGRect(x: 150, y: 1500, width: 640, height: 480),
                                              viewSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertEqual(viewport.pagePoint(from: CGPoint(x: 90, y: 80), in: bounds), CGPoint(x: 214, y: 1548))
        XCTAssertEqual(viewport.viewRect(for: CGRect(x: 214, y: 1548, width: 128, height: 96), in: bounds),
                       CGRect(x: 90, y: 80, width: 160, height: 120))
    }

    func testSelectionCanSpanViewportsInEitherDirectionAndClampsOnlyToDocument() throws {
        let region = try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: 300, y: 2200, width: -200, height: -2000)))
        XCTAssertEqual(region.rect, CGRect(x: 100, y: 200, width: 200, height: 2000))
        XCTAssertEqual(region.cssClip(content: CGRect(x: 0, y: 0, width: 800, height: 1800)),
                       CGRect(x: 100, y: 200, width: 200, height: 1600))
        for rect in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 5, height: 5),
                     CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 5)] {
            XCTAssertNil(PageScreenshotRegion(selection: rect))
        }
        XCTAssertNil(region.cssClip(content: CGRect(x: 0, y: 0, width: 80, height: 100)))
    }

    func testScrollbarAndOutOfViewPointersClampToVisiblePagePixels() {
        let viewport = PageScreenshotViewport(rect: CGRect(x: 10, y: 200, width: 400, height: 300),
                                              viewSize: CGSize(width: 408, height: 306), scale: 2)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 750)
        XCTAssertEqual(viewport.pagePoint(from: CGPoint(x: 1000, y: 750), in: bounds), CGPoint(x: 410, y: 500))
        XCTAssertEqual(viewport.pagePoint(from: CGPoint(x: 1200, y: -50), in: bounds), CGPoint(x: 410, y: 200))
        XCTAssertEqual(viewport.pageDelta(from: CGSize(width: 100, height: 100), in: bounds), CGSize(width: 40.8, height: 40.8))
    }

    func testOffscreenAnchorRemainsOutsideVisibleProjectionAfterScrolling() {
        let viewport = PageScreenshotViewport(rect: CGRect(x: 0, y: 1000, width: 800, height: 600),
                                              viewSize: CGSize(width: 800, height: 600), scale: 1)
        XCTAssertEqual(viewport.viewRect(for: CGRect(x: 100, y: 100, width: 400, height: 1400),
                                        in: CGRect(x: 0, y: 0, width: 800, height: 600)),
                       CGRect(x: 100, y: -900, width: 400, height: 1400))
    }
}
