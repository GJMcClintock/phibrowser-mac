// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import SwiftUI

struct ScreenshotEditorToolbar: View {
    let model: ScreenshotEditorModel
    let export: (ScreenshotExportFormat) -> Void

    var body: some View {
        HStack(spacing: 4) {
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
                    .buttonStyle(.plain).fontWeight(.medium)
                    .foregroundStyle(model.canCrop ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4).disabled(!model.canCrop)
                    .accessibilityIdentifier("screenshot.crop.confirm")
            } else {
                ForEach([ScreenshotTool.select, .arrow, .freehand, .text, .rectangle, .ellipse, .mosaic, .crop], id: \.self) { tool in
                    ScreenshotToolButton(tool: tool, selected: model.tool == tool) { model.selectTool(tool) }
                }
                Divider().frame(height: 22).padding(.horizontal, 8)
                Menu {
                    Button { export(.jpg) } label: { Text(verbatim: "JPG…") }
                    Button { export(.pdf) } label: { Text(verbatim: "PDF…") }
                } label: {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 18, weight: .regular))
                        .hidden()
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 36, height: 36)
                // Draw outside the native menu label so its secondary tint cannot dim the icon.
                .overlay {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Color.primary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .help(NSLocalizedString("browser.screenshot.export", value: "Export…", comment: "Screenshot editor - Save the edited image to a file"))
                .accessibilityLabel(NSLocalizedString("browser.screenshot.export", value: "Export…", comment: "Screenshot editor - Save the edited image to a file"))
                .accessibilityIdentifier("screenshot.export")
            }
        }
        .font(.system(size: 13)).padding(8)
        .screenshotGlass()
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
                .foregroundStyle(selected ? Color.accentColor : hovered ? Color.accentColor.opacity(0.75) : Color.primary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .help(Text(verbatim: "\(tool.title) (\(tool.shortcut))")).accessibilityLabel(tool.title)
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
                .font(.system(size: 12)).monospacedDigit()
        }
        .menuStyle(.borderlessButton).controlSize(.small).fixedSize().padding(.horizontal, 9).padding(.vertical, 7)
        .screenshotGlass()
        .accessibilityIdentifier("screenshot.zoom")
    }
}

extension View {
    @ViewBuilder
    func screenshotGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

extension ScreenshotTool {
    var title: String {
        switch self {
        case .select: return NSLocalizedString("browser.screenshot.select", value: "Select", comment: "Screenshot editor - Select and move annotations")
        case .mosaic: return NSLocalizedString("browser.screenshot.mosaic", value: "Blur", comment: "Screenshot editor - Cover a rectangular area with pixelated image blocks")
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
        case .mosaic: return "square.grid.3x3.fill"
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
        case .mosaic: return "M"
        case .crop: return "C"
        case .arrow: return "A"
        case .freehand: return "P"
        case .text: return "T"
        case .rectangle: return "R"
        case .ellipse: return "O"
        }
    }
}
