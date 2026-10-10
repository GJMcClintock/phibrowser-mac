import AppKit
@testable import Phi

@MainActor
@objc(ScreenshotFixtureApplication)
final class ScreenshotFixtureApplication: NSApplication {
    var fixtureSource: CGImage?
    @objc func newScreenshot(_ sender: Any?) {
        guard let fixtureSource else { return }
        ScreenshotEditorWindowController(canvas: fixtureSource, fileName: "Screenshot Fixture.jpg").showWindow(nil)
    }
    override func terminate(_ sender: Any?) {
        if reviewScreenshotEditorsForTermination(completion: { [weak self] approved in
            if approved { self?.finishTermination(sender) }
        }) { return }
        finishTermination(sender)
    }
    private func finishTermination(_ sender: Any?) { super.terminate(sender) }
}

@main
struct ScreenshotFixture {
    @MainActor static func main() throws {
        let app = ScreenshotFixtureApplication.shared as! ScreenshotFixtureApplication
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "New Screenshot", action: #selector(ScreenshotFixtureApplication.newScreenshot(_:)), keyEquivalent: "n").target = app
        appMenu.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""), editMenu = NSMenu(title: "Edit")
        for (title, key) in [("Undo", "z"), ("Redo", "z"), ("Cut", "x"), ("Copy", "c"), ("Paste", "v")] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString("commandDispatch:"), keyEquivalent: key)
            item.keyEquivalentModifierMask = title == "Redo" ? [.command, .shift] : [.command]
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu; menu.addItem(editItem); app.mainMenu = menu
        let context = ScreenshotSceneRenderer.bitmapContext(width: 1000, height: 800)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
        context.translateBy(x: 0, y: 800); context.scaleBy(x: 1, y: -1)
        context.setFillColor(NSColor(srgbRed: 0.11, green: 0.24, blue: 0.39, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 110))
        context.setFillColor(NSColor(srgbRed: 0.89, green: 0.94, blue: 0.98, alpha: 1).cgColor)
        context.fill(CGRect(x: 50, y: 190, width: 540, height: 350))
        context.setFillColor(NSColor(srgbRed: 0.95, green: 0.90, blue: 0.82, alpha: 1).cgColor)
        context.fill(CGRect(x: 650, y: 190, width: 290, height: 410))
        var title = ScreenshotAnnotation(kind: .text, frame: CGRect(x: 45, y: 22, width: 910, height: 70), text: "Phi Screenshot Editor")
        title.style.fontSize = 36; title.style.color = ScreenshotColor(red: 1, green: 1, blue: 1)
        ScreenshotSceneRenderer.draw(title, in: context)
        var body = ScreenshotAnnotation(kind: .text, frame: CGRect(x: 65, y: 220, width: 500, height: 280), text: "Draw once, then select and edit.\n\nV Select   C Crop   A Arrow   P Freehand\nT Text   R Rectangle   O Ellipse\n\nShift adds; Command marquee removes.\nOption resizes from the center.\nCrop changes JPG and PDF dimensions.")
        body.style.fontSize = 23; body.style.color = ScreenshotColor(red: 0.1, green: 0.15, blue: 0.2)
        ScreenshotSceneRenderer.draw(body, in: context)
        app.fixtureSource = context.makeImage()!
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let editor = ScreenshotEditorWindowController(canvas: app.fixtureSource!, fileName: "Fixture.jpg")
            let model = editor.model
            model.selectTool(.arrow); model.beginInteraction(at: CGPoint(x: 620, y: 660), tolerance: 5)
            model.continueInteraction(at: CGPoint(x: 795, y: 300)); model.endInteraction()
            model.select(nil); model.selectTool(.rectangle)
            model.beginInteraction(at: CGPoint(x: 640, y: 180), tolerance: 5)
            model.continueInteraction(at: CGPoint(x: 950, y: 610)); model.endInteraction()
            model.select(nil); model.selectTool(.text)
            model.commitText("Editable objects", frame: CGRect(x: 80, y: 610, width: 370, height: 80))
            try ScreenshotImageExport.write(model.snapshot(), format: .jpg, to: directory.appendingPathComponent("scene.jpg"))
            try ScreenshotImageExport.write(model.snapshot(), format: .pdf, to: directory.appendingPathComponent("scene.pdf"))
            for (name, size) in [("editor-layout.png", CGSize(width: 1100, height: 780)), ("editor-minimum-layout.png", CGSize(width: 850, height: 400))] {
                editor.window?.setContentSize(size)
                editor.window?.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
                if let view = editor.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
                }
            }
            editor.window?.close()
            print("Rendered local fixture, scene JPG, and single-page PDF to \(directory.path). This is offscreen rendering, not GUI acceptance.")
            return
        }
        app.newScreenshot(nil); app.windows.first?.title = "Phi Screenshot Editor — Synthetic Fixture"; app.activate(ignoringOtherApps: true); app.run()
    }
}
