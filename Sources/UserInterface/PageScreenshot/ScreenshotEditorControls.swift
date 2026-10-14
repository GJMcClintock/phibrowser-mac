// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import SwiftUI

struct ScreenshotEditorToolbar: View {
    let model: ScreenshotEditorModel
    let export: (ScreenshotExportFormat) -> Void
    let move: (CGSize, Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ScreenshotToolbarDragHandle(move: move).frame(width: 22, height: 36)
            if model.tool == .crop {
                Image(systemName: "crop").frame(width: 28)
                if let rect = model.cropRect {
                    Text(verbatim: "\(Int(rect.width)) × \(Int(rect.height)) px").monospacedDigit()
                } else {
                    Text(NSLocalizedString("browser.screenshot.cropHint", value: "Drag to select an area", comment: "Screenshot editor - Instruction before drawing a crop selection"))
                }
                Divider().frame(height: 22).padding(.horizontal, 8)
                Button(NSLocalizedString("browser.screenshot.cancelCrop", value: "Cancel", comment: "Screenshot editor - Leave crop mode without changing the image")) { model.selectTool(.select) }
                    .buttonStyle(.plain).padding(.horizontal, 8)
                Button(NSLocalizedString("browser.screenshot.applyCrop", value: "Apply", comment: "Screenshot editor - Apply the selected crop"), action: model.cropToSelection)
                    .buttonStyle(.borderedProminent).tint(.primary).disabled(!model.canCrop)
                    .accessibilityIdentifier("screenshot.crop.confirm")
            } else {
                ForEach(ScreenshotTool.allCases, id: \.self) { tool in
                    ScreenshotToolButton(tool: tool, selected: model.tool == tool) { model.selectTool(tool) }
                }
                Divider().frame(height: 22).padding(.horizontal, 8)
                Menu {
                    Button { export(.jpg) } label: { Text(verbatim: "JPG…") }
                    Button { export(.pdf) } label: { Text(verbatim: "PDF…") }
                } label: {
                    Text(NSLocalizedString("browser.screenshot.export", value: "Export…", comment: "Screenshot editor - Save the edited image to a file"))
                }
                .menuStyle(.button).buttonStyle(.borderedProminent).tint(.primary).fixedSize()
                .accessibilityIdentifier("screenshot.export")
            }
        }
        .font(.system(size: 13)).padding(8)
        .screenshotGlass(cornerRadius: 16)
    }
}

private struct ScreenshotToolButton: View {
    let tool: ScreenshotTool
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol).font(.system(size: 18, weight: .regular))
                .frame(width: 36, height: 36)
                .background(selected ? Color.accentColor.opacity(0.2) : hovered ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .help("\(tool.title) (\(tool.shortcut))").accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("screenshot.tool.\(tool.rawValue)")
    }
}

struct ScreenshotZoomWidget: View {
    let model: ScreenshotEditorModel

    var body: some View {
        Menu {
            Button(NSLocalizedString("browser.screenshot.fit", value: "Fit", comment: "Screenshot editor - Fit the complete screenshot in the window"), action: model.fit)
            Button(NSLocalizedString("browser.screenshot.actualSize", value: "100%", comment: "Screenshot editor - Show one source image pixel per preview point")) { model.zoomBy(1 / model.zoom) }
            Divider()
            Button(NSLocalizedString("browser.screenshot.zoomIn", value: "Zoom In", comment: "Screenshot editor - Increase preview magnification")) { model.zoomBy(1.25) }
            Button(NSLocalizedString("browser.screenshot.zoomOut", value: "Zoom Out", comment: "Screenshot editor - Reduce preview magnification")) { model.zoomBy(0.8) }
        } label: {
            Text(verbatim: "\(Int((model.zoom * 100).rounded()))%")
                .monospacedDigit().frame(minWidth: 34)
        }
        .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 14).padding(.vertical, 10)
        .screenshotGlass(cornerRadius: 12)
        .accessibilityIdentifier("screenshot.zoom")
    }
}

extension View {
    @ViewBuilder
    func screenshotGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

extension ScreenshotTool {
    var title: String {
        switch self {
        case .select: return NSLocalizedString("browser.screenshot.select", value: "Select", comment: "Screenshot editor - Select and move annotations")
        case .crop: return NSLocalizedString("browser.screenshot.crop", value: "Crop", comment: "Screenshot editor - Crop the image to the selected rectangular region")
        case .arrow: return NSLocalizedString("browser.screenshot.arrow", value: "Arrow", comment: "Screenshot editor - Arrow drawing tool")
        case .freehand: return NSLocalizedString("browser.screenshot.freehand", value: "Freehand", comment: "Screenshot editor - Freehand drawing tool")
        case .text: return NSLocalizedString("browser.screenshot.text", value: "Text", comment: "Screenshot editor - Text annotation tool")
        case .rectangle: return NSLocalizedString("browser.screenshot.rectangle", value: "Rectangle", comment: "Screenshot editor - Rectangle annotation tool")
        case .ellipse: return NSLocalizedString("browser.screenshot.ellipse", value: "Ellipse", comment: "Screenshot editor - Ellipse annotation tool")
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .freehand: return "pencil.tip"
        case .text: return "textformat"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        }
    }
    var shortcut: String {
        switch self {
        case .select: return "V"
        case .crop: return "C"
        case .arrow: return "A"
        case .freehand: return "P"
        case .text: return "T"
        case .rectangle: return "R"
        case .ellipse: return "O"
        }
    }
}

/// Window coordinates keep drag translation stable while the hosting view itself moves.
private struct ScreenshotToolbarDragHandle: NSViewRepresentable {
    let move: (CGSize, Bool) -> Void
    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        view.contentTintColor = .secondaryLabelColor
        view.toolTip = NSLocalizedString("browser.screenshot.moveToolbar", value: "Drag to move the toolbar", comment: "Screenshot editor - Floating toolbar drag handle")
        view.setAccessibilityLabel(view.toolTip)
        view.move = move
        return view
    }
    func updateNSView(_ view: HandleView, context: Context) { view.move = move }
    @MainActor final class HandleView: NSImageView {
        var move: ((CGSize, Bool) -> Void)?
        private var start: CGPoint?
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { start = event.locationInWindow }
        override func mouseDragged(with event: NSEvent) { report(event, ended: false) }
        override func mouseUp(with event: NSEvent) { report(event, ended: true); start = nil }
        private func report(_ event: NSEvent, ended: Bool) {
            guard let start else { return }
            move?(CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y), ended)
        }
    }
}
