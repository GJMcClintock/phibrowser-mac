// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import UniformTypeIdentifiers

/// Presents export UI for the exact image copied by the screenshot service.
@MainActor
enum PageScreenshotPresenter {
    static func suggestedFileName(title: String) -> String {
        let fallback = NSLocalizedString("browser.screenshot.fileName", value: "Screenshot",
                                         comment: "Screenshot - Fallback PNG file name when the page title is empty or unusable")
        let base = ReaderExportService.sanitizedBaseName(title: title, fallbackName: fallback)
        return "\(base).png"
    }

    static func showCopied(
        pngData: Data, title: String, windowId: Int, area: Bool = false,
        toastCenter: OverlayToastCenter = .shared,
        save: @escaping @MainActor (Data, String, Int) -> Void = savePNG
    ) {
        let fileName = suggestedFileName(title: title)
        let action = OverlayToastAction(
            title: NSLocalizedString("browser.screenshot.saveAction", value: "Save",
                                     comment: "Screenshot - Button on the copied screenshot toast to save the PNG to a file"),
            isBordered: true,
            handler: { save(pngData, fileName, windowId) })
        toastCenter.show(
            title: area ? NSLocalizedString("browser.screenshot.areaCopied", value: "Area screenshot copied",
                                           comment: "Screenshot - Success after copying a selected page area") : NSLocalizedString("browser.screenshot.copied", value: "Full page screenshot copied",
                                     comment: "Screenshot - Success toast after copying the PNG to the clipboard"),
            duration: 6, in: .windowId(windowId), action: action)
    }

    static func edit(pngData: Data, title: String, windowId: Int) {
        guard let owner = SpaceSessionControllersManager.shared.controller(for: windowId),
              owner.isPresentedOrLegacy, let parent = owner.window,
              parent.isVisible, !parent.isMiniaturized else { return }
        Task { @MainActor [weak owner, weak parent] in
            let bitmap = await Task.detached(priority: .userInitiated) { ScreenshotImageExport.decode(data: pngData) }.value
            // Decoding can outlive a browser close or a Space leaving the shared shell.
            guard let owner, let parent, owner.window === parent, owner.isPresentedOrLegacy,
                  parent.isVisible, !parent.isMiniaturized else { return }
            guard let bitmap else {
                OverlayToastCenter.shared.show(
                    title: NSLocalizedString("browser.screenshot.editFailed", value: "This screenshot is too large to edit. You can still save the original PNG.",
                                             comment: "Screenshot - Editing failed because the image exceeds the editor's safe size limit"),
                    duration: 8, in: .windowId(windowId), action: OverlayToastAction(
                        title: NSLocalizedString("browser.screenshot.saveAction", value: "Save",
                                                 comment: "Screenshot - Button on the copied screenshot toast to save the PNG to a file"),
                        isBordered: true,
                        handler: { savePNG(pngData, suggestedFileName(title: title), windowId) }))
                return
            }
            ScreenshotEditorWindowController(canvas: bitmap, fileName: suggestedFileName(title: title), parent: parent).showWindow(nil)
        }
    }

    private static func savePNG(_ pngData: Data, _ fileName: String, _ windowId: Int) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await Task.detached {
                        try pngData.write(to: url, options: .atomic)
                    }.value
                } catch {
                    AppLogError("[Screenshot] PNG export failed: \(error)")
                    OverlayToastCenter.shared.show(
                        title: NSLocalizedString("browser.screenshot.saveFailed", value: "Could not save the screenshot",
                                                 comment: "Screenshot - Error toast when writing the selected PNG file fails"),
                        in: .windowId(windowId))
                }
            }
        }
        if let window = SpaceSessionControllersManager.shared.controller(for: windowId)?.window,
           window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
