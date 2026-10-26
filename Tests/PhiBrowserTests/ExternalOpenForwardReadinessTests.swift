// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Pins when a batch of external opens may go to Chromium
/// (`AppController.mayForwardExternalOpenNow`). What the rule cannot reach,
/// that the immediate forward, the coalesced queue and the retries all ask
/// it, rests on the call sites.
final class ExternalOpenForwardReadinessTests: XCTestCase {
    /// The defaults describe a batch that may go: rules loaded, a window
    /// registered, Kiosk off, no visible regular window required and no
    /// windowless restore in flight. Each test flips what its name says.
    private static func forwards(
        hasLoadedURLRules: Bool = true,
        opensInKiosk: Bool = false,
        hasWindow: Bool = true,
        requiresVisibleRegularWindow: Bool = false,
        hasVisibleRegularBrowserWindow: Bool = true,
        isSessionRestoreInFlight: Bool = false
    ) -> Bool {
        AppController.mayForwardExternalOpenNow(
            hasLoadedURLRules: hasLoadedURLRules,
            opensInKiosk: opensInKiosk,
            hasWindow: hasWindow,
            requiresSpaceReadiness: true,
            requiresVisibleRegularWindow: requiresVisibleRegularWindow,
            hasVisibleRegularBrowserWindow: hasVisibleRegularBrowserWindow,
            isSessionRestoreInFlight: isSessionRestoreInFlight)
    }

    func testAReadyBatchForwards() {
        XCTAssertTrue(Self.forwards())
    }

    func testARestoreInFlightHoldsALinkThoughAWindowIsOpen() {
        // The defect: with several windows coming back, the first one let the
        // link go mid-restore. Its Show was dropped, so Phi never came to the
        // front, and it landed by Chromium's last-used profile of the moment.
        XCTAssertFalse(Self.forwards(isSessionRestoreInFlight: true))
    }

    func testARestoreInFlightHoldsAKioskLink() {
        // A Kiosk open starts no restore, but a Dock click may have started
        // one just before; the link waits for it like any other.
        XCTAssertFalse(Self.forwards(opensInKiosk: true, hasWindow: false,
                                     isSessionRestoreInFlight: true))
    }

    func testRulesNotYetLoadedHoldTheBatch() {
        // Forwarded earlier, the URL would meet an empty routing table.
        XCTAssertFalse(Self.forwards(hasLoadedURLRules: false))
    }

    func testAStandardLinkWaitsForAWindow() {
        XCTAssertFalse(Self.forwards(hasWindow: false))
    }

    func testAKioskLinkNeedsNoWindow() {
        XCTAssertTrue(Self.forwards(opensInKiosk: true, hasWindow: false))
    }

    func testAColdKioskOpenWaitsForAVisibleRegularWindow() {
        // So the Kiosk window's own activating Show comes last.
        XCTAssertFalse(Self.forwards(opensInKiosk: true, hasWindow: false,
                                     requiresVisibleRegularWindow: true,
                                     hasVisibleRegularBrowserWindow: false))
    }

    func testAColdKioskOpenForwardsOnceARegularWindowShows() {
        XCTAssertTrue(Self.forwards(opensInKiosk: true,
                                    requiresVisibleRegularWindow: true))
    }
}
