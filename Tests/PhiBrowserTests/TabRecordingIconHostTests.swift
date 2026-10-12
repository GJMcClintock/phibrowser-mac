// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI
import XCTest
@testable import Phi

/// The recording badge pulses with a `repeatForever` animation, and SwiftUI
/// keeps that animation running inside a hidden `NSHostingView`. A tab cell
/// that is not recording must therefore carry no badge at all rather than a
/// hidden one, or every tab in every window re-renders it on every frame.
@MainActor
final class TabRecordingIconHostTests: XCTestCase {
    func test_tabItemThatIsNotRecordingCarriesNoRecordingIcon() {
        let view = makeCompactTabItem(guid: 1, recording: false)

        XCTAssertEqual(
            recordingIconHosts(in: view).count,
            0,
            "A tab that is not recording must not keep a hidden, animating "
                + "recording icon."
        )
    }

    func test_recordingCompactTabItemShowsItsRecordingIcon() throws {
        let view = makeCompactTabItem(guid: 1, recording: true)

        let hosts = recordingIconHosts(in: view)
        XCTAssertEqual(hosts.count, 1)
        let host = try XCTUnwrap(hosts.first)
        XCTAssertFalse(host.isHidden)
        XCTAssertFalse(host.frame.isEmpty)
    }

    func test_tabItemReusedForATabThatIsNotRecordingDropsTheIcon() {
        let view = makeCompactTabItem(guid: 1, recording: true)
        XCTAssertEqual(recordingIconHosts(in: view).count, 1, "Precondition.")

        configure(view, guid: 2, recording: false)

        XCTAssertEqual(recordingIconHosts(in: view).count, 0)
    }

    func test_splitPairCellShowsOnlyTheRecordingPanesIcon() {
        let leftTab = Tab(
            guid: 1,
            url: "https://example.com/1",
            isActive: false,
            index: 0
        )
        leftTab.setCaptureStateForTesting(video: true)
        let rightTab = Tab(
            guid: 2,
            url: "https://example.com/2",
            isActive: false,
            index: 1
        )
        let cell = SidebarSplitPairCellView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 36)
        )
        cell.configure(with: SplitPairSidebarItem(
            groupId: "split-1-2",
            leftTab: leftTab,
            rightTab: rightTab,
            browserState: nil
        ))

        XCTAssertTrue(cell.isRecordingIndicatorVisible(isLeft: true))
        XCTAssertFalse(cell.isRecordingIndicatorVisible(isLeft: false))
        XCTAssertEqual(
            recordingIconHosts(in: cell).count,
            1,
            "The pane that is not recording must not keep a hidden, "
                + "animating recording icon."
        )
    }

    // MARK: - Helpers

    /// Compact, because that is where a tab item shows the centred
    /// recording icon; a normal-width item shows a badge on its favicon.
    private func makeCompactTabItem(guid: Int, recording: Bool) -> TabItemView {
        let view = TabItemView()
        view.frame = CGRect(
            x: 0,
            y: 0,
            width: TabStripMetrics.Content.compactModeThreshold - 1,
            height: TabStripMetrics.Strip.tabHeight
        )
        configure(view, guid: guid, recording: recording)
        return view
    }

    /// Configures `view` for a new tab and lays it out. `Tab` stays out of
    /// the signatures: with SwiftUI imported the bare type name is ambiguous.
    private func configure(_ view: TabItemView, guid: Int, recording: Bool) {
        let tab = Tab(
            guid: guid,
            url: "https://example.com/\(guid)",
            isActive: false,
            index: guid
        )
        tab.setCaptureStateForTesting(video: recording)
        view.configure(with: TabRenderData(
            id: "tab-\(tab.guid)",
            title: "Example",
            url: tab.url ?? "",
            isActive: false,
            isPinned: false,
            isSplitGroupActive: false,
            sourceTab: tab
        ))
        view.layout()
    }

    /// Hosting views anywhere under `root` whose content is the recording
    /// icon, hidden or not.
    private func recordingIconHosts(in root: NSView) -> [NSView] {
        let iconName = String(describing: UnifiedTabRecordingIcon.self)
        var hosts: [NSView] = []
        var pending = [root]
        while let view = pending.popLast() {
            if let host = view as? NSHostingView<AnyView>,
               String(describing: host.rootView).contains(iconName) {
                hosts.append(host)
            }
            pending.append(contentsOf: view.subviews)
        }
        return hosts
    }
}
