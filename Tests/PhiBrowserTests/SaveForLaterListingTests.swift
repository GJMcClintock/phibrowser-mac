// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation
import XCTest
@testable import Phi

final class SaveForLaterListingTests: XCTestCase {
    func testListingFrontmatterPrefixStopsAtTheClosingLine() {
        let head = Data("---\ntitle: A\nsource: https://example.com\n---\n\n# A\n\nBody".utf8)
        XCTAssertEqual(String(decoding: SaveForLaterService.frontmatterPrefix(head), as: UTF8.self),
                       "---\ntitle: A\nsource: https://example.com\n---\n")
        XCTAssertTrue(SaveForLaterService.frontmatterPrefix(Data("# No frontmatter".utf8)).isEmpty)
        XCTAssertTrue(SaveForLaterService.frontmatterPrefix(Data("---\ntitle: cut off".utf8)).isEmpty)
    }
}
