// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit

/// Settings pane for link-opening behavior. It hosts the Kiosk, Peek, and URL
/// Rules controls that apply across Spaces.
class NavigationsSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier: Settings.PaneIdentifier = .navigations
    var paneTitle: String = NSLocalizedString("settings.navigation.navigationsTitle",
                                              value: "Navigation",
                                              comment: "Settings - Tab title for link-opening behavior")
    var toolbarItemIcon: NSImage = NSImage(resource: .settingLinkIcon)
    let hostingController = NavigationsSettingHostingViewController()

    // AppKit only synthesizes an empty view for a nib-less `loadView` on
    // macOS 14+; macOS 12/13 raise an NSNib exception instead. Panes are
    // built purely in code, so provide the view explicitly.
    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}
