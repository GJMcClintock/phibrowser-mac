// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Records what `BrowserState` hands the Chromium bridge for the AI Chat panel.
private final class FakeAIChatPanelBridge: AIChatPanelBridging {
    var pushes: [(record: String?, tabId: Int)] = []
    var panelRequests: [(url: String, customGuid: String, windowId: Int)] = []

    func setAIChatPanelRecord(_ record: String?, forTabId tabId: Int) {
        pushes.append((record, tabId))
    }

    func createAIChatPanelTab(url: String, customGuid: String, windowId: Int) {
        panelRequests.append((url, customGuid, windowId))
    }

    /// Decoded pushes for `tabId`; a clear reads as nil.
    func records(forTabId tabId: Int) -> [AIChatPanelRecord?] {
        pushes.filter { $0.tabId == tabId }.map { $0.record.flatMap(AIChatPanelRecord.init(encoded:)) }
    }
}

/// Undo close brings a tab back with the AI Chat panel it had (chromium ADR
/// 0017). Out: the window's `BrowserState` pushes each page tab's panel record
/// to Chromium as it changes. In: a restored tab that arrives with an
/// expanded record gets its panel back on the same conversation.
@MainActor
final class BrowserStateAIChatPanelRecordTests: XCTestCase {
    private let conversationX = "3f2a8c1e-5b7d-4e9a-8c6f-1d2e3f4a5b6c"
    private let conversationY = "9b8a7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d"
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState(bridge: FakeAIChatPanelBridge) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default",
                            aiChatPanelBridge: bridge)
    }

    private func seed(_ state: BrowserState, guids: [Int]) -> [Tab] {
        let tabs = guids.map { Tab(guid: $0, url: "https://e\($0).example", isActive: false, index: 0) }
        state.tabs = tabs
        state.updateNormalTabs()
        return tabs
    }

    /// Gives `tab` a panel tab showing `url`, as `handleNewTabFromChromium`
    /// files one.
    @discardableResult
    private func addPanel(to tab: Tab, in state: BrowserState, url: String) -> Tab {
        let chat = Tab(guid: tab.guid * 100, url: url, isActive: false, index: 0)
        state.aiChatTabs[state.getTabIdentifier(for: tab)] = chat
        return chat
    }

    private func conversationURL(_ id: String, tabId: Int) -> String {
        "chrome://conversation/\(id)?is_sidebar=1&tabId=\(tabId)"
    }

    private func newChatURL(tabId: Int) -> String {
        "chrome://conversation/index.html?is_sidebar=1&tabId=\(tabId)"
    }

    private func record(expanded: Bool, _ conversationId: String?) -> AIChatPanelRecord? {
        AIChatPanelRecord(isExpanded: expanded, conversationId: conversationId)
    }

    // MARK: - Out: pushing the record

    func testExpandingPushesAnExpandedRecordWithoutAConversation() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]

        tab.aiChatCollapsed = false

        XCTAssertEqual(bridge.records(forTabId: 1), [record(expanded: true, nil)])
    }

    func testAConversationInThePanelURLIsPushed() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        let chat = addPanel(to: tab, in: state, url: newChatURL(tabId: 1))

        chat.url = conversationURL(conversationX, tabId: 1)

        XCTAssertEqual(bridge.records(forTabId: 1),
                       [record(expanded: true, nil), record(expanded: true, conversationX)])
    }

    func testSwitchingConversationPushesTheNewOne() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        let chat = addPanel(to: tab, in: state, url: conversationURL(conversationX, tabId: 1))

        chat.url = conversationURL(conversationY, tabId: 1)

        XCTAssertEqual(bridge.records(forTabId: 1).last, record(expanded: true, conversationY))
    }

    /// The page's own URL form, in case Chromium hands it over unrewritten.
    func testAConversationInTheExtensionURLFormIsPushed() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false

        addPanel(to: tab, in: state,
                 url: "chrome-extension://fenmfiepnpdlhplemgijlimpbebebljo/index.html?is_sidebar=1&tabId=1&conv_id=\(conversationX)")

        XCTAssertEqual(bridge.records(forTabId: 1).last, record(expanded: true, conversationX))
    }

    func testCollapsingPushesACollapsedRecordWithItsConversation() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        addPanel(to: tab, in: state, url: conversationURL(conversationX, tabId: 1))

        tab.aiChatCollapsed = true

        XCTAssertEqual(bridge.records(forTabId: 1).last, record(expanded: false, conversationX))
    }

    func testCollapsingWithoutAConversationClearsTheRecord() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        addPanel(to: tab, in: state, url: newChatURL(tabId: 1))

        tab.aiChatCollapsed = true

        XCTAssertEqual(bridge.records(forTabId: 1), [record(expanded: true, nil), nil])
        XCTAssertNil(bridge.pushes.last?.record)
    }

    func testATabThatNeverOpenedItsPanelPushesNothing() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tabs = seed(state, guids: [1, 2])

        tabs[1].aiChatCollapsed = true
        tabs[0].aiChatCollapsed = false

        XCTAssertEqual(bridge.pushes.map(\.tabId), [1])
    }

    func testAnUnchangedRecordIsNotPushedAgain() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        let chat = addPanel(to: tab, in: state, url: conversationURL(conversationX, tabId: 1))

        tab.aiChatCollapsed = false
        chat.url = conversationURL(conversationX, tabId: 1)

        XCTAssertEqual(bridge.records(forTabId: 1),
                       [record(expanded: true, nil), record(expanded: true, conversationX)])
    }

    func testClosingThePageTabPushesNoClear() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        addPanel(to: tab, in: state, url: conversationURL(conversationX, tabId: 1))
        XCTAssertEqual(bridge.records(forTabId: 1).last, record(expanded: true, conversationX))
        let pushesBeforeClose = bridge.pushes.count

        state.closeTab(1)

        XCTAssertNil(state.aiChatTabs[state.getTabIdentifier(for: tab)])
        XCTAssertEqual(bridge.pushes.count, pushesBeforeClose)
    }

    // MARK: - In: a restored tab arrives with its record

    private func arrive(_ state: BrowserState, guid: Int, record: AIChatPanelRecord?,
                        isActiveAtCreation: Bool) -> Tab {
        let tab = Tab(guid: guid, url: "https://e\(guid).example", isActive: false, index: 0)
        tab.restoredAIChatPanel = record
        state.handleNewTabFromChromium(
            tab,
            context: NativeTabCreationContext(isActiveAtCreation: isActiveAtCreation,
                                              creationKind: .restore))
        return tab
    }

    func testTheCurrentTabArrivingExpandedAsksForItsPanelOnTheSameConversation() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])

        let tab = arrive(state, guid: 5, record: record(expanded: true, conversationX),
                         isActiveAtCreation: true)

        XCTAssertFalse(tab.aiChatCollapsed)
        XCTAssertEqual(bridge.panelRequests.count, 1)
        let request = try XCTUnwrap(bridge.panelRequests.first)
        XCTAssertEqual(request.customGuid, BrowserState.aiChatId(for: "5"))
        XCTAssertEqual(request.windowId, 7)
        let query = URLComponents(string: request.url)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "is_sidebar" })?.value, "1")
        XCTAssertEqual(query.first(where: { $0.name == "tabId" })?.value, "5")
        XCTAssertEqual(query.first(where: { $0.name == "conv_id" })?.value, conversationX)
    }

    func testTakingOverAnExpandedRecordPushesItBack() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])

        _ = arrive(state, guid: 5, record: record(expanded: true, conversationX),
                   isActiveAtCreation: true)

        // Chromium stops handing the record back once the client pushes it.
        XCTAssertEqual(bridge.records(forTabId: 5), [record(expanded: true, conversationX)])
    }

    func testABackgroundTabArrivingExpandedGetsItsPanelOnTheSameConversationWhenShown() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])

        let tab = arrive(state, guid: 5, record: record(expanded: true, conversationX),
                         isActiveAtCreation: false)
        XCTAssertFalse(tab.aiChatCollapsed)
        XCTAssertTrue(bridge.panelRequests.isEmpty)

        // The chat pane asks for the panel the first time the tab is shown.
        state.createAIChatTab(for: state.chatIdentifier(for: tab), chromeTabId: tab.guid)

        let request = try XCTUnwrap(bridge.panelRequests.first)
        let query = URLComponents(string: request.url)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "conv_id" })?.value, conversationX)
    }

    func testARecordInAnotherVersionOrNamingNoValidConversationReadsAsNone() {
        XCTAssertNotNil(AIChatPanelRecord(encoded: #"{"conversationId":"\#(conversationX)","expanded":true,"v":1}"#))
        XCTAssertNil(AIChatPanelRecord(encoded: #"{"conversationId":"\#(conversationX)","expanded":true,"v":2}"#))
        XCTAssertNil(AIChatPanelRecord(encoded: #"{"conversationId":"x&tabId=1","expanded":true,"v":1}"#))
    }

    func testACollapsedRecordArrivingLeavesThePanelAlone() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])

        let tab = arrive(state, guid: 5, record: record(expanded: false, conversationX),
                         isActiveAtCreation: true)

        XCTAssertTrue(tab.aiChatCollapsed)
        XCTAssertTrue(bridge.panelRequests.isEmpty)
        XCTAssertTrue(bridge.pushes.isEmpty)
    }
}
