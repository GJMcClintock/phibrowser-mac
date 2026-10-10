import AppKit
@MainActor final class BrowserState { var windowId = 7; var focusingTab: Tab?; var pageCommandTarget: Tab? { focusingTab } }
@MainActor final class Tab { var guid = 1; var isShowingNativeNTP = false; var title = "Fixture"; var url: String?; var isLoading = false; var webContentView: NSView?; var webContentWrapper: Wrapper? }
@MainActor final class Wrapper { var devToolsTargetId: String? = "fixture" }
@MainActor final class ChromiumLauncher { static func sharedInstance() -> ChromiumLauncher { ChromiumLauncher() }; var bridge: Int? = 1 }
@MainActor enum PageScreenshotPresenter { static func showCopied(jpegData: Data, title: String, windowId: Int, area: Bool = false) {}; static func edit(jpegData: Data, title: String, windowId: Int) {} }
enum OverlayToastTarget { case windowId(Int) }
@MainActor final class OverlayToastCenter { static let shared = OverlayToastCenter(); func show(title: String, in target: OverlayToastTarget) {} }
func AppLogDebug(_ value: String) {}; func AppLogWarn(_ value: String) {}; func AppLogError(_ value: String) {}
final class AppDevToolsPageSession {
    enum SessionError: Error { case timedOut, commandFailed(String), connectionClosed, upgradeFailed }
    static func open(targetId: String, timeout: TimeInterval, maxMessageBytes: Int) async throws -> AppDevToolsPageSession { throw SessionError.connectionClosed }
    func command(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] { throw SessionError.connectionClosed }
    func close() {}
}
