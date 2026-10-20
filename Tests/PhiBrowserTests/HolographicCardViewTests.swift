// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import XCTest
@testable import Phi

@MainActor
final class HolographicCardViewTests: XCTestCase {
    func testPointerClampsOutsideCardAndHandlesEmptyLayout() {
        let bounds = CGRect(x: 20, y: 40, width: 292, height: 423)
        XCTAssertEqual(HolographicCardMotion.normalizedPointer(CGPoint(x: bounds.midX, y: bounds.midY), in: bounds), .zero)
        XCTAssertEqual(HolographicCardMotion.normalizedPointer(CGPoint(x: -100, y: 900), in: bounds), CGPoint(x: -1, y: 1))
        XCTAssertEqual(HolographicCardMotion.normalizedPointer(CGPoint(x: 10, y: 10), in: .zero), .zero)
    }

    func testPointerResponseIsIndependentOfRefreshRate() {
        let pointer = CGPoint(x: 0.7, y: -0.4)
        var sixty = HolographicCardMotion()
        var oneTwenty = HolographicCardMotion()
        for _ in 0..<60 { sixty.advance(by: 1.0 / 60, pointer: pointer) }
        for _ in 0..<120 { oneTwenty.advance(by: 1.0 / 120, pointer: pointer) }
        XCTAssertEqual(sixty.position.x, oneTwenty.position.x, accuracy: 0.000001)
        XCTAssertEqual(sixty.position.y, oneTwenty.position.y, accuracy: 0.000001)
    }

    func testReducedMotionCompletesEntranceWithoutStartingOver() {
        var motion = HolographicCardMotion()
        motion.advance(by: 0.2, pointer: nil)
        motion.finishEntrance()
        XCTAssertEqual(motion.entrance, 1)
        motion.advance(by: 0.1, pointer: nil)
        XCTAssertEqual(motion.entrance, 1)
        motion.advance(by: .nan, pointer: nil)
        XCTAssertTrue(motion.position.x.isFinite)
    }

    func testJoinDateAcceptsFractionalSecondsAndRejectsMissingDates() {
        XCTAssertEqual(HolographicCardView.formattedJoinDate("2026-10-15T12:00:00Z"), "2026.10")
        XCTAssertEqual(HolographicCardView.formattedJoinDate("2026-10-15T12:00:00.123Z"), "2026.10")
        XCTAssertEqual(HolographicCardView.formattedJoinDate(""), "")
        XCTAssertEqual(HolographicCardView.formattedJoinDate("invalid"), "")
    }

    func testExportIsReadableEvenBeforeEntranceAndPreservesTicketCutouts() throws {
        let view = HolographicCardView(frame: .zero)
        view.name = "任凯 — A very long profile name"
        view.memberID = "12345"
        view.joinedDate = "2026.10"
        let image = try XCTUnwrap(view.frontImage(scale: 1))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        XCTAssertEqual(rep.pixelsWide, 292)
        XCTAssertEqual(rep.pixelsHigh, 423)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 1, y: 292)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 146, y: 211)).alphaComponent, 0.99)
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 10, y: 180)).alphaComponent, 0.99)
        XCTAssertFalse(view.isAnimating)
        XCTAssertNil(view.frontImage(scale: 0))
    }

    func testDetachedCardDoesNotRetainAnAnimationTimer() {
        weak var released: HolographicCardView?
        autoreleasepool {
            let view = HolographicCardView(frame: CGRect(origin: .zero, size: HolographicCardView.designSize))
            released = view
            XCTAssertFalse(view.isAnimating)
            view.isPresentationActive = false
            XCTAssertFalse(view.isAnimating)
        }
        XCTAssertNil(released)
    }

    func testVisibleCardPausesWhenHiddenAndDetached() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("The system's Reduce Motion preference disables animation.")
        }
        let view = HolographicCardView(frame: CGRect(origin: .zero, size: HolographicCardView.designSize))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(view.isAnimating)
        view.isHidden = true
        XCTAssertFalse(view.isAnimating)
        view.isHidden = false
        XCTAssertTrue(view.isAnimating)
        view.isPresentationActive = false
        XCTAssertFalse(view.isAnimating)
        view.isPresentationActive = true
        XCTAssertTrue(view.isAnimating)
        view.removeFromSuperview()
        XCTAssertFalse(view.isAnimating)
    }

    func testProfileControllerUpdatesTheSharedCardWithRealProfileData() throws {
        let controller = ProfileCardViewController()
        let card = try XCTUnwrap(controller.view as? HolographicCardView)
        controller.profile = Profile(id: 12345, auth0_id: "fixture", email: "fixture@example.com",
            name: "任凯", picture: "", last_login: "", created_at: "2026-10-15T12:00:00.123Z")
        XCTAssertEqual(card.name, "任凯")
        XCTAssertEqual(card.memberID, "12345")
        XCTAssertEqual(card.joinedDate, "2026.10")
        controller.profile?.name = "Updated Name"
        XCTAssertEqual(card.name, "Updated Name")
    }

    func testWelcomeUsesTheSameNativeCardWithinItsExistingLayout() throws {
        let controller = OnboardingWelcomeViewController()
        controller.userName = "Welcome Fixture"
        controller.view.frame = CGRect(x: 0, y: 0, width: 640, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? HolographicCardView }.first)
        XCTAssertEqual(card.name, "Welcome Fixture")
        XCTAssertEqual(card.frame.width, 292, accuracy: 0.5)
        XCTAssertEqual(card.frame.height, 423, accuracy: 0.5)
        XCTAssertTrue(controller.view.bounds.contains(card.frame))
        XCTAssertEqual(card.joinedDate, "")
    }
    func testReferenceDefaultsAndThemeMapping() {
        XCTAssertEqual(HolographicCardStyle.default.palette, .silver)
        XCTAssertEqual(HolographicCardStyle.default.texture, .arcs)
        XCTAssertEqual(HolographicCardStyle.default.ornament, .lace)
        XCTAssertEqual(HolographicCardStyle.gradientAngle, 200)
        XCTAssertEqual(HolographicCardStyle.textureOpacity, 0.72)
        XCTAssertEqual(HolographicCardStyle.iridescenceOpacity, 0.78)
        XCTAssertEqual(HolographicCardStyle.textureContrast, 1.18)
        XCTAssertEqual(Set(HolographicCardStyle.Palette.allCases.map(\.themeID)), Set(Theme.builtInThemes.map(\.id)))
        XCTAssertEqual(HolographicCardStyle.Palette(themeID: Theme.default.id), .silver)
        XCTAssertEqual(HolographicCardStyle.Palette(themeID: "custom"), .silver)
        XCTAssertEqual(HolographicCardStyle.Palette.blue.colors, [0x63CFFD, 0x83E4C5, 0xA777E8])
        XCTAssertEqual(HolographicCardStyle.Palette.aqua.themeID, "aqua")
        XCTAssertEqual(HolographicCardStyle.Palette.blue.themeID, "mist")
    }

    func testRandomSelectionReachesEveryIndependentCombination() {
        struct Seeded: RandomNumberGenerator {
            var state: UInt64 = 91
            mutating func next() -> UInt64 {
                state &+= 0x9e3779b97f4a7c15
                var value = state
                value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
                value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
                return value ^ (value >> 31)
            }
        }
        var generator = Seeded()
        var selected = Set<HolographicCardStyle>()
        for _ in 0..<10_000 { selected.insert(.random(using: &generator)) }
        XCTAssertEqual(selected.count, 8 * 6 * 6)
    }

    func testEveryTextureHasDistinctCachedArtwork() throws {
        var data = Set<Data>()
        for texture in HolographicCardStyle.Texture.allCases {
            let image = try XCTUnwrap(HolographicCardArtwork.foil(texture))
            XCTAssertEqual(image.width, 584)
            XCTAssertEqual(image.height, 846)
            XCTAssertTrue(image === HolographicCardArtwork.foil(texture))
            data.insert(try XCTUnwrap(image.dataProvider?.data) as Data)
        }
        XCTAssertEqual(data.count, 6)
    }

    func testFormulaOrnamentsStayOpenAndNoneIsEmpty() {
        for ornament in HolographicCardStyle.Ornament.allCases {
            let path = HolographicCardArtwork.sealPath(ornament)
            var closed = 0, moves = 0, lines = 0
            path.applyWithBlock { element in
                switch element.pointee.type {
                case .closeSubpath: closed += 1
                case .moveToPoint: moves += 1
                case .addLineToPoint: lines += 1
                default: break
                }
            }
            if ornament == .none {
                XCTAssertTrue(path.isEmpty)
            } else if ornament == .lace || ornament == .lotus {
                XCTAssertEqual(closed, 6)
                XCTAssertEqual(moves, 6)
                XCTAssertEqual(lines, 6 * 2880)
            } else {
                XCTAssertEqual(closed, 0)
                XCTAssertEqual(moves, 1)
                XCTAssertEqual(lines, (ornament == .epicycloid ? 16 : 20) * 720)
            }
        }
    }

    func testCardStylePersistsAcrossReloadAndIsAccountScoped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let account = Account(userID: UUID().uuidString)
        let url = folder.appendingPathComponent("card.plist")
        let defaults = AccountUserDefaults(account: account, storeURL: url)
        let key = AccountUserDefaults.DefaultsKey.profileCardStyle.rawValue
        let style = HolographicCardStyle(palette: .gold, texture: .brushed, ornament: .modulated)
        XCTAssertTrue(defaults.set(style, forCodableKey: key))
        let reloaded: HolographicCardStyle? = AccountUserDefaults(account: account, storeURL: url).codableValue(forKey: key)
        XCTAssertEqual(reloaded, style)
        let other = AccountUserDefaults(account: Account(userID: UUID().uuidString), storeURL: folder.appendingPathComponent("other.plist"))
        let missing: HolographicCardStyle? = other.codableValue(forKey: key)
        XCTAssertNil(missing)
    }

    func testWelcomeStartsWithDefaultsAndRandomButtonUpdatesTheTheme() throws {
        let originalTheme = ThemeManager.shared.currentTheme.id
        defer { ThemeManager.shared.switchTheme(to: originalTheme) }
        let controller = OnboardingWelcomeViewController()
        controller.view.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? HolographicCardView }.first)
        XCTAssertEqual(card.style, .default)
        let random = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("randomizeCard") })
        XCTAssertFalse(random.frame.intersects(card.frame))
        for _ in 0..<5 {
            random.performClick(nil)
            XCTAssertEqual(ThemeManager.shared.currentTheme.id, card.style.palette.themeID)
        }
        let selection = card.style
        controller.viewWillDisappear()
        controller.viewWillAppear()
        XCTAssertEqual(card.style, selection, "Revisiting must not reroll or reset the selected texture.")
        controller.viewWillDisappear()
    }

    #if DEBUG
    func testDebugControlsPreviewEveryOptionWithoutChangingBrowserTheme() throws {
        let originalTheme = ThemeManager.shared.currentTheme.id
        let controller = HolographicCardDebugViewController()
        _ = controller.view
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let controls = descendants(controller.view).compactMap { $0 as? NSPopUpButton }
        XCTAssertEqual(controls.map(\.numberOfItems), [8, 6, 6])
        for control in controls {
            for index in 0..<control.numberOfItems {
                control.selectItem(at: index)
                NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control)
            }
        }
        XCTAssertEqual(controller.cardView.style, HolographicCardStyle(palette: .gold, texture: .stardust, ornament: .none))
        let reset = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Restore Defaults" })
        reset.performClick(nil)
        XCTAssertEqual(controller.cardView.style, .default)
        XCTAssertEqual(ThemeManager.shared.currentTheme.id, originalTheme)
    }
    #endif
}
