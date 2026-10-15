// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
import UniformTypeIdentifiers

private enum LiquidGlassAdaptor {
    private static let fallbackCornerRadius = LiquidGlassCompatible.webContentInnerComponentsCornerRadius

    static func wrappingContent(_ content: NSView, cornerRadius: CGFloat = fallbackCornerRadius) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            content.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            return glass
        }

        let fx = NSVisualEffectView()
        fx.translatesAutoresizingMaskIntoConstraints = false
        fx.material = .hudWindow
        fx.blendingMode = .withinWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
        fx.addSubview(content)
        content.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        return fx
    }
}

private final class CircularHoverButton: NSView {
    private let button = NSButton()
    private let hoverLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private let diameter: CGFloat

    weak var target: AnyObject? {
        get { button.target }
        set { button.target = newValue }
    }

    var action: Selector? {
        get { button.action }
        set { button.action = newValue }
    }

    var isButtonEnabled: Bool {
        get { button.isEnabled }
        set {
            button.isEnabled = newValue
            button.alphaValue = newValue ? 1.0 : 0.4
            if !newValue {
                hoverLayer.backgroundColor = NSColor.clear.cgColor
            }
        }
    }

    init(
        symbolName: String,
        accessibilityDescription: String,
        diameter: CGFloat = 28,
        symbolPointSize: CGFloat = 14,
        contentVerticalOffset: CGFloat = 0
    ) {
        self.diameter = diameter
        super.init(frame: .zero)

        wantsLayer = true

        hoverLayer.cornerRadius = diameter / 2
        hoverLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(hoverLayer)

        let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(config)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        button.toolTip = accessibilityDescription
        button.focusRingType = .none
        button.contentTintColor = .labelColor
        button.setAccessibilityLabel(accessibilityDescription)
        addSubview(button)

        snp.makeConstraints { make in
            make.width.height.equalTo(diameter)
        }
        button.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.bottom.equalToSuperview().offset(contentVerticalOffset)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        hoverLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isButtonEnabled else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hoverLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hoverLayer.backgroundColor = NSColor.clear.cgColor
        }
    }
}

final class ImagePreviewViewController: NSViewController {
    private final class PreviewRootView: NSVisualEffectView {
        override var acceptsFirstResponder: Bool { true }
    }

    private static let fallbackControlInset: CGFloat = 1
    private static let fallbackNavigationContainerSize: CGFloat = 30
    private static let fallbackBottomToolbarHeight: CGFloat = 26
    private static let fallbackNavigationCornerRadius: CGFloat = fallbackNavigationContainerSize / 2
    private static let fallbackBottomToolbarCornerRadius: CGFloat = fallbackBottomToolbarHeight / 2

    private let state: BrowserImagePreviewState
    private let showsPanelFrame: Bool
    private var cancellables = Set<AnyCancellable>()
    private var isExporting = false
    var onOpenInWindow: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let previousButton: CircularHoverButton
    private let nextButton: CircularHoverButton
    private let zoomOutButton: CircularHoverButton
    private let zoomInButton: CircularHoverButton
    private let exportButton = CircularHoverButton(
        symbolName: "arrow.down.to.line",
        accessibilityDescription: NSLocalizedString(
            "imagePreview.exportButtonAccessibilityLabel",
            value: "Export Image",
            comment: "Image preview - Tooltip and accessibility label for saving the current image to a file"
        ),
        diameter: 24,
        symbolPointSize: 12,
        contentVerticalOffset: -1
    )
    private let openInWindowButton = CircularHoverButton(
        symbolName: "arrow.up.forward.square",
        accessibilityDescription: NSLocalizedString(
            "imagePreview.openInWindowButtonAccessibilityLabel",
            value: "Open in New Window",
            comment: "Image preview - Button that opens the current image list in a separate window"
        )
    )
    private let zoomPercentLabel = NSTextField(labelWithString: "100%")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = ZoomableImageScrollView()

    private let leftNavStack = NSStackView()
    private let rightNavStack = NSStackView()
    private let bottomToolbarStack = NSStackView()
    private let exportButtonStack = NSStackView()
    private let centerOverlayStack = NSStackView()

    private let leftNavigation: NSView
    private let rightNavigation: NSView
    private let bottomToolbar: NSView
    private let exportControl: NSView

    init(state: BrowserImagePreviewState, showsPanelFrame: Bool = true) {
        self.showsPanelFrame = showsPanelFrame
        self.previousButton = CircularHoverButton(
            symbolName: "chevron.left",
            accessibilityDescription: NSLocalizedString("imagePreview.previousButtonAccessibilityLabel", value: "Previous image",
                comment: "Image preview: accessibility label for previous image control"
            )
        )
        self.nextButton = CircularHoverButton(
            symbolName: "chevron.right",
            accessibilityDescription: NSLocalizedString("imagePreview.nextButtonAccessibilityLabel", value: "Next image",
                comment: "Image preview: accessibility label for next image control"
            )
        )
        self.zoomOutButton = CircularHoverButton(
            symbolName: "minus.magnifyingglass",
            accessibilityDescription: NSLocalizedString("imagePreview.zoomOutButtonAccessibilityLabel", value: "Zoom out",
                comment: "Image preview: accessibility label for zoom out control"
            ),
            diameter: 24
        )
        
        self.zoomInButton = CircularHoverButton(
            symbolName: "plus.magnifyingglass",
            accessibilityDescription: NSLocalizedString("imagePreview.zoomButtonAccessibilityLabel", value: "Zoom in",
                comment: "Image preview: accessibility label for zoom in control"
            ),
            diameter: 24
        )

        Self.configureNavStack(leftNavStack)
        Self.configureNavStack(rightNavStack)
        Self.configureBottomToolbarStack(bottomToolbarStack)
        Self.configureNavStack(exportButtonStack)
        Self.configureCenterOverlayStack(centerOverlayStack)

        let navigationCornerRadius = SystemUtils.isMacOS26OrLater ? 28 : Self.fallbackNavigationCornerRadius
        let bottomToolbarCornerRadius = SystemUtils.isMacOS26OrLater ? 24 : Self.fallbackBottomToolbarCornerRadius

        self.leftNavigation = LiquidGlassAdaptor.wrappingContent(leftNavStack, cornerRadius: navigationCornerRadius)
        self.rightNavigation = LiquidGlassAdaptor.wrappingContent(rightNavStack, cornerRadius: navigationCornerRadius)
        self.bottomToolbar = LiquidGlassAdaptor.wrappingContent(bottomToolbarStack, cornerRadius: bottomToolbarCornerRadius)
        self.exportControl = LiquidGlassAdaptor.wrappingContent(exportButtonStack, cornerRadius: bottomToolbarCornerRadius)

        self.state = state
        super.init(nibName: nil, bundle: nil)

        previousButton.target = self
        previousButton.action = #selector(showPrevious)
        nextButton.target = self
        nextButton.action = #selector(showNext)
        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutFromToolbar)
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInFromToolbar)
        exportButton.target = self
        exportButton.action = #selector(exportImage)
        exportButton.isButtonEnabled = false
        openInWindowButton.target = self
        openInWindowButton.action = #selector(openInWindow)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let visualEffectView = PreviewRootView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        if showsPanelFrame {
            visualEffectView.layer?.cornerRadius = 18
            visualEffectView.layer?.borderWidth = 1
            visualEffectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        }
        self.view = visualEffectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        leftNavStack.addArrangedSubview(previousButton)
        rightNavStack.addArrangedSubview(nextButton)
        bottomToolbarStack.addArrangedSubview(zoomOutButton)
        bottomToolbarStack.addArrangedSubview(zoomPercentLabel)
        bottomToolbarStack.addArrangedSubview(zoomInButton)
        exportButtonStack.addArrangedSubview(exportButton)
        centerOverlayStack.addArrangedSubview(statusLabel)
        centerOverlayStack.addArrangedSubview(retryButton)

        setupUI()
        bindState()
    }

    func zoomIn() {
        scrollView.zoomIn()
    }

    func zoomOut() {
        scrollView.zoomOut()
    }

    func resetZoom() {
        scrollView.resetToFit()
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) {
            super.keyDown(with: event)
        }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        switch Int(event.keyCode) {
        case 53: // esc
            if let onClose { onClose() } else { state.close() }
        case 123: // left
            state.showPrevious()
        case 124: // right
            state.showNext()
        case 24, 69: // = / keypad +
            zoomIn()
        case 27, 78: // - / keypad -
            zoomOut()
        case 18, 29: // 1 / 0
            resetZoom()
        default:
            return false
        }
        return true
    }

    private static func configureNavStack(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        if #available(macOS 26.0, *) {
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        } else {
            stack.edgeInsets = NSEdgeInsets(
                top: fallbackControlInset,
                left: fallbackControlInset,
                bottom: fallbackControlInset,
                right: fallbackControlInset
            )
        }
    }

    private static func configureBottomToolbarStack(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        if #available(macOS 26.0, *) {
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        } else {
            stack.edgeInsets = NSEdgeInsets(
                top: fallbackControlInset,
                left: fallbackControlInset,
                bottom: fallbackControlInset,
                right: fallbackControlInset
            )
        }
    }

    private static func configureCenterOverlayStack(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
    }

    private func setupUI() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .left
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        retryButton.target = self
        retryButton.action = #selector(retryCurrentItem)
        retryButton.isHidden = true

        zoomPercentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomPercentLabel.textColor = .labelColor
        zoomPercentLabel.alignment = .center
        zoomPercentLabel.isSelectable = false
        zoomPercentLabel.setContentHuggingPriority(.required, for: .horizontal)
        zoomPercentLabel.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(42)
        }

        view.addSubview(scrollView)
        view.addSubview(centerOverlayStack)
        view.addSubview(titleLabel)
        view.addSubview(leftNavigation)
        view.addSubview(rightNavigation)
        view.addSubview(bottomToolbar)
        view.addSubview(exportControl)
        openInWindowButton.isHidden = onOpenInWindow == nil
        view.addSubview(openInWindowButton)

        openInWindowButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(8)
            make.trailing.equalToSuperview().offset(-10)
        }

        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(12)
            make.leading.equalToSuperview().offset(14)
            make.trailing.lessThanOrEqualTo(openInWindowButton.snp.leading).offset(-8)
        }

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        centerOverlayStack.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
            make.leading.greaterThanOrEqualToSuperview().offset(32)
            make.trailing.lessThanOrEqualToSuperview().offset(-32)
        }

        leftNavigation.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(14)
            make.centerY.equalTo(scrollView)
            if !SystemUtils.isMacOS26OrLater {
                make.width.height.equalTo(Self.fallbackNavigationContainerSize)
            }
        }

        rightNavigation.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-14)
            make.centerY.equalTo(scrollView)
            if !SystemUtils.isMacOS26OrLater {
                make.width.height.equalTo(Self.fallbackNavigationContainerSize)
            }
        }

        bottomToolbar.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().offset(-16)
            if !SystemUtils.isMacOS26OrLater {
                make.height.equalTo(Self.fallbackBottomToolbarHeight)
            }
        }

        exportControl.snp.makeConstraints { make in
            make.leading.equalTo(bottomToolbar.snp.trailing).offset(8)
            make.centerY.equalTo(bottomToolbar)
            make.width.height.equalTo(bottomToolbar.snp.height)
        }

        scrollView.onZoomChanged = { [weak self] scale, fitScale, minScale in
            guard let self else { return }
            state.updateZoom(scale: scale, fitScale: fitScale, minScale: minScale)
            zoomPercentLabel.stringValue = Self.zoomText(for: scale)
        }
    }

    private func bindState() {
        state.$currentIndex
            .combineLatest(state.$items)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] currentIndex, items in
                guard let self else { return }
                updateTitle(currentIndex: currentIndex, items: items)
                updateChrome(for: items)
            }
            .store(in: &cancellables)

        state.$loadState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loadState in
                self?.render(loadState: loadState)
            }
            .store(in: &cancellables)
    }

    private func updateTitle(currentIndex: Int, items: [ImagePreviewItem]) {
        let currentItem = items.indices.contains(currentIndex) ? items[currentIndex] : nil
        titleLabel.stringValue = currentItem?.title ?? currentItem?.suggestedFilename ?? currentItem?.source.url?.lastPathComponent ?? ""
    }

    private func updateChrome(for items: [ImagePreviewItem]) {
        let multiple = items.count > 1
        leftNavigation.isHidden = !multiple
        rightNavigation.isHidden = !multiple
        previousButton.isButtonEnabled = state.canShowPrevious
        nextButton.isButtonEnabled = state.canShowNext
    }

    private func render(loadState: ImagePreviewLoadState) {
        updateExportButton()
        switch loadState {
        case .idle:
            scrollView.clear()
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            retryButton.isHidden = true
        case .loading:
            scrollView.clear()
            statusLabel.stringValue = NSLocalizedString("imagePreview.loadingStatus", value: "Loading image…", comment: "Image preview loading")
            statusLabel.isHidden = false
            retryButton.isHidden = true
        case .loaded(let asset):
            statusLabel.isHidden = true
            retryButton.isHidden = true
            scrollView.display(asset: asset)
        case .failed(let error):
            scrollView.clear()
            statusLabel.stringValue = error.message
            statusLabel.isHidden = false
            retryButton.isHidden = false
        }
    }

    private static func zoomText(for scale: CGFloat) -> String {
        let percent = max(Int((scale * 100).rounded()), 1)
        return "\(percent)%"
    }

    @objc private func showPrevious() {
        state.showPrevious()
    }

    @objc private func showNext() {
        state.showNext()
    }

    @objc private func zoomInFromToolbar() {
        zoomIn()
    }

    @objc private func zoomOutFromToolbar() {
        zoomOut()
    }

    @objc private func retryCurrentItem() {
        state.retryCurrentItem()
    }

    @objc private func openInWindow() {
        onOpenInWindow?()
    }

    private func updateExportButton() {
        if case .loaded = state.loadState {
            exportButton.isButtonEnabled = !isExporting
        } else {
            exportButton.isButtonEnabled = false
        }
    }

    static func suggestedExportFilename(for item: ImagePreviewItem, contentType: UTType?) -> String {
        let fallback = NSLocalizedString(
            "imagePreview.exportFallbackFilename",
            value: "Image",
            comment: "Image preview - Default export filename when the image has no usable name"
        )
        let name = [item.suggestedFilename, item.source.url?.lastPathComponent, item.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fallback
        let filename = ReaderExportService.sanitizedBaseName(title: name, fallbackName: fallback)
        guard let contentType, let preferredExtension = contentType.preferredFilenameExtension else {
            return filename
        }
        let providedExtension = (filename as NSString).pathExtension
        if UTType(filenameExtension: providedExtension) == contentType {
            return filename
        }
        let base = (filename as NSString).deletingPathExtension
        return "\(base).\(preferredExtension)"
    }

    @objc private func exportImage() {
        guard !isExporting,
              case .loaded(let asset) = state.loadState,
              let item = state.activeItem else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.suggestedExportFilename(for: item, contentType: asset.contentType)
        if let contentType = asset.contentType {
            panel.allowedContentTypes = [contentType]
        }
        isExporting = true
        updateExportButton()
        // Capture the loaded bytes before the panel opens, independently of later navigation.
        let data = asset.originalData
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else {
                self?.isExporting = false
                self?.updateExportButton()
                return
            }
            Task { @MainActor [weak self] in
                defer {
                    self?.isExporting = false
                    self?.updateExportButton()
                }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try data.write(to: url, options: .atomic)
                    }.value
                } catch {
                    if let self {
                        self.presentExportError(error)
                    } else {
                        NSApp.presentError(error)
                    }
                }
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func presentExportError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "imagePreview.exportFailed",
            value: "Could not export the image",
            comment: "Image preview - Error shown when writing the exported image file fails"
        )
        alert.informativeText = error.localizedDescription
        if let window = view.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.presentError(error)
        }
    }

#if DEBUG
    @objc private func openFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.title = "Select Images"
        panel.message = "Choose one or more local images to append to the current preview list."

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            let newItems = panel.urls.enumerated().map { index, url in
                ImagePreviewItem(
                    id: "debug-local-\(UUID().uuidString)-\(index)",
                    source: .localFile(url),
                    title: url.lastPathComponent,
                    mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
                    suggestedFilename: url.lastPathComponent
                )
            }
            self.state.append(items: newItems)
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
#endif
}
