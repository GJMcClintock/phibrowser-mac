// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class FeedbackPasteImageTests: XCTestCase {
    private var window: NSWindow!
    private var pasteboard: NSPasteboard!
    private var coordinator: FeedbackPasteImageMonitor.Coordinator!
    private var pastedImages: [NSImage] = []

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        pasteboard = NSPasteboard.withUniqueName()
        coordinator = FeedbackPasteImageMonitor.Coordinator { [weak self] image in
            self?.pastedImages.append(image)
        }
        coordinator.view = window.contentView
    }

    override func tearDown() {
        coordinator = nil
        pasteboard.releaseGlobally(); pasteboard = nil
        window.close(); window = nil
        pastedImages.removeAll()
        super.tearDown()
    }

    private func writeImage() {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill()
            return true
        }
        XCTAssertTrue(pasteboard.writeObjects([image]))
    }

    private func key(semantic: String, characters: String = "v",
                     flags: NSEvent.ModifierFlags = .command, code: UInt16 = 9,
                     windowNumber: Int? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: windowNumber ?? window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: semantic, isARepeat: false, keyCode: code))
    }

    func testNonLatinCommandPasteAddsImageAndConsumesEvent() throws {
        writeImage()
        // Synthetic kana, Hangul, Cyrillic, and empty IME semantic characters.
        for semantic in ["ひ", "ㅍ", "м", "", "v"] {
            let previousCount = pastedImages.count
            XCTAssertNil(coordinator.handleKeyDown(try key(semantic: semantic), pasteboard: pasteboard))
            XCTAssertEqual(pastedImages.count, previousCount + 1)
            XCTAssertEqual(pastedImages.last?.size, NSSize(width: 8, height: 8))
        }
        // Preserve semantic letter layouts rather than requiring the physical ANSI V key.
        XCTAssertNil(coordinator.handleKeyDown(try key(semantic: "v", code: 47), pasteboard: pasteboard))
        XCTAssertEqual(pastedImages.count, 6)
    }

    func testTextAndEmptyPasteboardsPassThroughToNativeTextEditing() throws {
        let event = try key(semantic: "ㅍ")
        XCTAssertTrue(coordinator.handleKeyDown(event, pasteboard: pasteboard) === event)
        pasteboard.setString("Feedback text", forType: .string)
        XCTAssertTrue(coordinator.handleKeyDown(event, pasteboard: pasteboard) === event)
        XCTAssertTrue(pastedImages.isEmpty)
    }

    func testImagePasteDoesNotInterceptOtherWindowsOrDetachedViews() throws {
        writeImage()
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        let otherEvent = try key(semantic: "ㅍ", windowNumber: otherWindow.windowNumber)
        XCTAssertTrue(coordinator.handleKeyDown(otherEvent, pasteboard: pasteboard) === otherEvent)
        coordinator.view = nil
        let detachedEvent = try key(semantic: "ㅍ", windowNumber: 0)
        XCTAssertTrue(coordinator.handleKeyDown(detachedEvent, pasteboard: pasteboard) === detachedEvent)
        XCTAssertTrue(pastedImages.isEmpty)
    }

    func testImagePasteRejectsOtherChordsAndPreservesSemanticLayouts() throws {
        writeImage()
        for flags: NSEvent.ModifierFlags in [[], .shift, [.command, .shift], [.command, .option],
                                           [.command, .control], [.command, .function]] {
            let event = try key(semantic: "ㅍ", flags: flags)
            XCTAssertTrue(coordinator.handleKeyDown(event, pasteboard: pasteboard) === event)
        }
        let semanticEvent = try key(semantic: ".", characters: ".")
        XCTAssertTrue(coordinator.handleKeyDown(semanticEvent, pasteboard: pasteboard) === semanticEvent)
        XCTAssertTrue(pastedImages.isEmpty)
        XCTAssertNil(coordinator.handleKeyDown(try key(semantic: "ㅍ", flags: [.command, .capsLock]),
                                               pasteboard: pasteboard))
        XCTAssertEqual(pastedImages.count, 1)
    }
}
