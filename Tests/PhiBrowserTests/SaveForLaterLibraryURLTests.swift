// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The library-page URL binding: how the Library's Folio pane surface is
/// bound back to the request it answers (`pane=`), and how a plain library
/// tab (File > Open Folio) is told apart from it. Mirrors the reader-surface
/// shape in `ReaderExtensionBridgeURLTests`.
final class SaveForLaterLibraryURLTests: XCTestCase {
    private let libraryBase =
        "chrome-extension://\(ReaderExtensionBridge.extensionId)/library.html"

    func testPaneURLRoundTripsItsRequestToken() {
        let url = SaveForLaterService.libraryPaneURL(token: "7B2A-REQUEST")
        XCTAssertTrue(url.hasPrefix(libraryBase))
        XCTAssertEqual(SaveForLaterService.libraryPaneToken(fromLibraryPageURL: url), "7B2A-REQUEST")
        // A pane surface is the Library's, never the reader overlay's.
        XCTAssertNil(BrowserState.pageOverlaySurfaceOriginTabId(url))
    }

    func testPlainLibraryPageIsNotAPaneSurface() {
        XCTAssertNil(SaveForLaterService.libraryPaneToken(fromLibraryPageURL: SaveForLaterService.libraryPageURL))
        XCTAssertNil(BrowserState.pageOverlaySurfaceOriginTabId(SaveForLaterService.libraryPageURL))
    }

    func testPaneTokenRefusesForeignAndMalformedURLs() {
        // Another extension serving an identically named page must not bind.
        XCTAssertNil(SaveForLaterService.libraryPaneToken(
            fromLibraryPageURL: "chrome-extension://aaaabbbbccccddddeeeeffffgggghhhh/library.html#pane=x"))
        // A web page can never be a library surface.
        XCTAssertNil(SaveForLaterService.libraryPaneToken(
            fromLibraryPageURL: "https://example.com/library.html#pane=x"))
        // The reader page is the reader's, not the library's.
        XCTAssertNil(SaveForLaterService.libraryPaneToken(
            fromLibraryPageURL: "chrome-extension://\(ReaderExtensionBridge.extensionId)/reader.html#pane=x"))
        // A reader-style binding on the library page names no request.
        XCTAssertNil(SaveForLaterService.libraryPaneToken(fromLibraryPageURL: "\(libraryBase)#tab=42"))
        // An empty token names no request either.
        XCTAssertNil(SaveForLaterService.libraryPaneToken(fromLibraryPageURL: "\(libraryBase)#pane="))
    }

    func testReaderSurfaceStillResolvesThroughTheSharedParser() {
        XCTAssertEqual(
            BrowserState.pageOverlaySurfaceOriginTabId(
                "chrome-extension://\(ReaderExtensionBridge.extensionId)/reader.html#tab=7&src=https%3A%2F%2Fexample.com"),
            7
        )
    }
}
