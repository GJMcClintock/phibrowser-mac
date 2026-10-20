// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

final class ProfileCardViewController: NSViewController {
    private let cardView = HolographicCardView()
    private var accentColor = NSColor.black

    var userName: String? {
        didSet { cardView.name = userName ?? profile?.name ?? "Phi" }
    }

    var profile: Profile? {
        didSet {
            cardView.name = userName ?? profile?.name ?? "Phi"
            cardView.memberID = profile.map { String($0.id) } ?? ""
            cardView.joinedDate = HolographicCardView.formattedJoinDate(profile?.created_at ?? "")
        }
    }

    override func loadView() { view = cardView }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Theme initialization can post notifications while restoring preferences.
        applyCurrentTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyCurrentTheme), name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyCurrentTheme), name: .appearanceDidChange, object: nil)
        if profile == nil, let defaults = AccountController.shared.account?.userDefaults {
            profile = defaults.codableValue(forKey: AccountUserDefaults.DefaultsKey.cachedProfile.rawValue)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyCurrentTheme() {
        let theme = ThemeManager.shared.currentTheme
        let color = theme.color(for: .windowOverlayBackground, appearance: ThemeManager.shared.currentAppearance)
            .withAlphaComponent(1).usingColorSpace(.deviceRGB) ?? .gray
        var style: HolographicCardStyle = AccountController.shared.account?.userDefaults.codableValue(
            forKey: AccountUserDefaults.DefaultsKey.profileCardStyle.rawValue) ?? .default
        style.palette = .init(themeID: theme.id)
        cardView.style = style
        accentColor = theme == .pure ? .black : NSColor(hue: color.hueComponent, saturation: 0.65, brightness: 0.28, alpha: 1)
    }

    func snapshotAndExport() {
        guard let front = cardView.frontImage() else { return }
        let cardSize = HolographicCardView.designSize
        let canvasSize = NSSize(width: cardSize.width * 2, height: cardSize.height * 2)
        let composed = NSImage(size: canvasSize)
        composed.lockFocus()
        accentColor.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()
        front.draw(in: NSRect(x: cardSize.width / 2, y: cardSize.height / 2, width: cardSize.width, height: cardSize.height))
        composed.unlockFocus()
        guard let tiff = composed.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(userName ?? profile?.name ?? "Phi").png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try png.write(to: url) }
            catch { NSApp.presentError(error) }
        }
    }
}
