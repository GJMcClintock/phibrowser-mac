import CoreGraphics
import XCTest
@testable import Phi

final class PageScreenshotGeometryTests: XCTestCase {
    func testFlippedAndUnflippedViewsProduceTheSameTopLeftSelection() throws {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let flipped = try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: 90, y: 80, width: 160, height: 120), bounds: bounds, isFlipped: true))
        let unflipped = try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: 90, y: 440, width: 160, height: 120), bounds: bounds, isFlipped: false))
        XCTAssertEqual(flipped, unflipped)
        XCTAssertEqual(flipped.rect, CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(flipped.cssClip(viewport: CGRect(x: 150, y: 1500, width: 640, height: 480)),
                       CGRect(x: 214, y: 1548, width: 128, height: 96))
    }

    func testSelectionClampsToVisibleBoundsAndRejectsEmptyOrNonfiniteInput() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let clipped = try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: -10, y: 80, width: 200, height: 50), bounds: bounds, isFlipped: true))
        XCTAssertEqual(clipped.rect, CGRect(x: 0, y: 0.8, width: 1, height: 0.2))
        for rect in [CGRect.zero, CGRect(x: 110, y: 0, width: 10, height: 10), CGRect(x: CGFloat.nan, y: 0, width: 5, height: 5)] {
            XCTAssertNil(PageScreenshotRegion(selection: rect, bounds: bounds, isFlipped: true))
        }
        XCTAssertNil(clipped.cssClip(viewport: CGRect(x: 0, y: 0, width: 0, height: 100)))
    }
    func testScrollbarOnlySelectionIsRejectedAndPartialOverlapClampsToPagePixels() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 750)
        let bar = try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: 990, y: 10, width: 10, height: 100), bounds: bounds, isFlipped: true))
        XCTAssertNil(bar.cssClip(viewport: CGRect(x: 0, y: 200, width: 400, height: 300), viewSize: CGSize(width: 408, height: 300)))
        let overlap = try XCTUnwrap(PageScreenshotRegion(selection: CGRect(x: 900, y: 10, width: 100, height: 100), bounds: bounds, isFlipped: true))
        let clipped = try XCTUnwrap(overlap.cssClip(viewport: CGRect(x: 0, y: 200, width: 400, height: 300), viewSize: CGSize(width: 408, height: 300)))
        XCTAssertEqual(clipped.maxX, 400)
        XCTAssertEqual(clipped.width, 32.8, accuracy: 0.001)
    }

}
