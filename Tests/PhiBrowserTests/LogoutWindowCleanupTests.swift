import AppKit
import XCTest
@testable import Phi

@MainActor
final class LogoutWindowCleanupTests: XCTestCase {
    private final class CloseObserver: NSObject, NSWindowDelegate {
        var closedWindows: [NSWindow] = []

        func windowWillClose(_ notification: Notification) {
            if let window = notification.object as? NSWindow {
                closedWindows.append(window)
            }
        }
    }

    private func makeWindow(styleMask: NSWindow.StyleMask = [.titled, .closable]) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: styleMask, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    func testClosesAuxiliaryWindowsIncludingNonClosablePanels() {
        let settings = makeWindow()
        let invitation = makeWindow()
        let importPanel = makeWindow(styleMask: [.borderless])
        let observer = CloseObserver()
        let windows = [settings, invitation, importPanel]
        windows.forEach { $0.delegate = observer }

        SpaceSessionControllersManager.closeNonBrowserWindows(in: windows, excluding: [])

        XCTAssertEqual(observer.closedWindows, windows)
    }

    func testPreservesBrowserWindowsAndShellForTheirExistingCloseLifecycle() {
        let auxiliary = makeWindow()
        let browser = makeWindow()
        let hiddenChromiumWindow = makeWindow()
        let danglingBrowser = makeWindow()
        let shell = ShellWindow(
            contentRect: .zero, styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        shell.isReleasedWhenClosed = false
        let observer = CloseObserver()
        let windows = [auxiliary, browser, hiddenChromiumWindow, danglingBrowser, shell]
        windows.forEach { $0.delegate = observer }
        defer {
            windows.forEach {
                $0.delegate = nil
                $0.close()
            }
        }

        SpaceSessionControllersManager.closeNonBrowserWindows(
            in: windows, excluding: [browser, hiddenChromiumWindow, danglingBrowser]
        )

        XCTAssertEqual(observer.closedWindows, [auxiliary])
    }
}
