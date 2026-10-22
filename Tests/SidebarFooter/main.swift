// Copyright 2026 Phinomenon Inc.
import AppKit
import SwiftUI

@main
struct FooterTests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let state = SidebarBottomBarState()
        let cards = NotificationCardManager()
        let root = SidebarBottomBarSwiftUI(state: state, downloadViewModel: DownloadButtonViewModel(),
            cardManager: cards, onFeedbackTap: {}, onBookmarkTap: {},
            onChatTap: {}, onCardEntryTap: {}, onMemoryTap: {}, onDownloadTap: {})
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 193, height: 24),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Phi Sidebar Footer Fixture"
        var cases = 0
        let threshold = ChatButton.preferredContentWidth + 160
        for width: CGFloat in [193, 217, 218, 260, 500, threshold - 1, threshold, threshold + 1] {
            for mask in 0..<16 {
                state.isMemoryHidden = mask & 1 != 0
                state.isFeedbackHidden = mask & 2 != 0
                state.isChatHidden = mask & 4 != 0
                cards.latestCard = mask & 8 != 0 ? nil : 1
                Probe.frames = [:]
                let host = NSHostingView(rootView: root)
                host.sizingOptions = []
                window.contentView = host
                window.setContentSize(NSSize(width: width, height: 24))
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
                let frames = Probe.frames
                let iconCount = 2 + (state.isMemoryHidden ? 0 : 1) + (cards.latestCard == nil ? 0 : 1)
                let chatWidth = state.isChatHidden ? 0 : ChatButton.preferredContentWidth
                let allWidth = CGFloat(iconCount + 1) * 24 + chatWidth + 16
                    + CGFloat(iconCount + 1 + (state.isChatHidden ? 0 : 1)) * 4
                let feedbackVisible = !state.isFeedbackHidden && width >= allWidth
                precondition((frames["feedback"] != nil) == feedbackVisible, "Feedback must hide only when the full row does not fit: width \(width), mask \(mask), threshold \(allWidth)")
                let expectedCount = 2 + (state.isMemoryHidden ? 0 : 1) + (feedbackVisible ? 1 : 0)
                    + (state.isChatHidden ? 0 : 1) + (cards.latestCard == nil ? 0 : 1)
                precondition(frames.count == expectedCount, "Missing controls: \(frames)")
                for (name, frame) in frames {
                    if name == "chat" {
                        precondition(abs(frame.width - ChatButton.preferredContentWidth) <= 1, "Chat title must remain complete")
                    } else {
                        precondition(frame.width == 24 && frame.height == 24, "Icon frame must stay 24 points")
                    }
                    precondition(frame.minX >= 8 - 0.01 && frame.maxX <= width - 8 + 0.01,
                                 "\(name) overflows at \(width), mask \(mask): \(frame)")
                    for (otherName, other) in frames where name != otherName {
                        precondition(!frame.intersects(other), "\(name) overlaps \(otherName)")
                    }
                }
                if mask == 0, width == 193 {
                    precondition(abs(frames["chat"]!.width - ChatButton.preferredContentWidth) <= 1, "Narrow footer must retain the full Chat title")
                    print("193pt all controls: \(frames)")
                }
                if mask == 0, width >= 260 {
                    precondition(frames["chat"]!.width > 24, "Wide footer must retain the localized Chat title")
                }
                cases += 1
            }
        }
        state.isMemoryHidden = false
        state.isFeedbackHidden = false
        state.isChatHidden = false
        cards.latestCard = 1
        let liveHost = NSHostingView(rootView: root)
        liveHost.sizingOptions = []
        window.contentView = liveHost
        for width: CGFloat in [193, 260, threshold - 1, threshold, threshold + 1, 193] {
            window.setContentSize(NSSize(width: width, height: 24))
            liveHost.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            for frame in Probe.frames.values {
                precondition(frame.minX >= 7.99 && frame.maxX <= width - 7.99, "Live resize must retain margins")
            }
            precondition(abs(Probe.frames["chat"]!.width - ChatButton.preferredContentWidth) <= 1,
                         "Chat title must survive live resizing")
            precondition((Probe.frames["feedback"] != nil) == (width >= threshold), "Feedback must adapt during live resizing")
        }
        let fiveEntryWidth = ChatButton.preferredContentWidth + 132
        window.setContentSize(NSSize(width: fiveEntryWidth, height: 24))
        for hasCard in [false, true, false] {
            cards.latestCard = hasCard ? 1 : nil
            liveHost.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            precondition(Probe.frames["chat"]!.width > 24, "Chat title must survive notification changes")
            precondition((Probe.frames["feedback"] != nil) == !hasCard, "Feedback must adapt to notification entry changes")
        }
        print("PASS: \(cases) rendered layouts plus live resize/card updates; title \(NSLocalizedString("sidebar.chatButton.title", comment: "")); language \(Locale.preferredLanguages.first ?? "unknown")")
        if CommandLine.arguments.contains("--preview") {
            state.isMemoryHidden = false
            state.isFeedbackHidden = false
            state.isChatHidden = false
            cards.latestCard = 1
            window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
                Text("Sidebar footer · all six entries").font(.headline)
                Text("193 pt · Feedback hidden")
                root.frame(width: 193, height: 24).border(Color.gray.opacity(0.4))
                Text("260 pt · full Chat title")
                root.frame(width: 260, height: 24).border(Color.gray.opacity(0.4))
                Text("Local fixture · actions disabled").font(.caption).foregroundStyle(.secondary)
            }.padding(24))
            window.setContentSize(NSSize(width: 340, height: 280))
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            app.run()
        }
    }
}
