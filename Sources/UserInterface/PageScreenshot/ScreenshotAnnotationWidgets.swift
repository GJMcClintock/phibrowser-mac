// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import SwiftUI

/// The only dispatch point for annotation-specific property widgets.
struct ScreenshotAnnotationProperties: View {
    let model: ScreenshotEditorModel

    var body: some View {
        widget(for: model.selected?.kind)
            .font(.system(size: 12)).padding(12).fixedSize()
    }

    @ViewBuilder
    private func widget(for kind: ScreenshotAnnotation.Kind?) -> some View {
        switch kind {
        case .arrow: ScreenshotArrowWidget(model: model)
        case .freehand: ScreenshotFreehandWidget(model: model)
        case .text: ScreenshotTextWidget(model: model)
        case .rectangle: ScreenshotRectangleWidget(model: model)
        case .ellipse: ScreenshotEllipseWidget(model: model)
        case nil: ScreenshotSelectionWidget(model: model)
        }
    }
}

struct ScreenshotArrowWidget: View {
    let model: ScreenshotEditorModel
    var body: some View {
        HStack(spacing: 12) {
            ScreenshotColorControl(model: model)
            Divider().frame(height: 22)
            ScreenshotSizeControl(model: model, text: false)
        }
    }
}

struct ScreenshotFreehandWidget: View {
    let model: ScreenshotEditorModel
    var body: some View {
        HStack(spacing: 12) {
            ScreenshotColorControl(model: model)
            Divider().frame(height: 22)
            ScreenshotSizeControl(model: model, text: false)
        }
    }
}

struct ScreenshotTextWidget: View {
    let model: ScreenshotEditorModel
    var body: some View {
        HStack(spacing: 12) {
            ScreenshotColorControl(model: model)
            Divider().frame(height: 22)
            ScreenshotSizeControl(model: model, text: true)
        }
    }
}

struct ScreenshotRectangleWidget: View {
    let model: ScreenshotEditorModel
    var body: some View {
        HStack(spacing: 12) {
            ScreenshotColorControl(model: model)
            Divider().frame(height: 22)
            ScreenshotSizeControl(model: model, text: false)
            ScreenshotFillControl(model: model)
        }
    }
}

struct ScreenshotEllipseWidget: View {
    let model: ScreenshotEditorModel
    var body: some View {
        HStack(spacing: 12) {
            ScreenshotColorControl(model: model)
            Divider().frame(height: 22)
            ScreenshotSizeControl(model: model, text: false)
            ScreenshotFillControl(model: model)
        }
    }
}

/// Mixed selections expose only properties that apply to every selected object.
private struct ScreenshotSelectionWidget: View {
    let model: ScreenshotEditorModel
    var body: some View {
        HStack(spacing: 12) {
            ScreenshotColorControl(model: model)
            if model.selectedObjects.allSatisfy({ $0.kind == .text }) {
                Divider().frame(height: 22)
                ScreenshotSizeControl(model: model, text: true)
            } else if model.selectedObjects.allSatisfy({ $0.kind != .text }) {
                Divider().frame(height: 22)
                ScreenshotSizeControl(model: model, text: false)
            }
            if model.selectedObjects.allSatisfy({ [.rectangle, .ellipse].contains($0.kind) }) {
                ScreenshotFillControl(model: model)
            }
        }
    }
}

private struct ScreenshotColorControl: View {
    @Bindable var model: ScreenshotEditorModel
    private let swatches: [ScreenshotColor] = [
        .red, ScreenshotColor(red: 0.96, green: 0.7, blue: 0.15),
        ScreenshotColor(red: 0.25, green: 0.65, blue: 0.32),
        ScreenshotColor(red: 0.25, green: 0.45, blue: 0.96),
        ScreenshotColor(red: 0.15, green: 0.15, blue: 0.17),
        ScreenshotColor(red: 1, green: 1, blue: 1)
    ]
    private var commonColor: ScreenshotColor? {
        guard let first = model.selectedObjects.first?.style.color,
              model.selectedObjects.allSatisfy({ $0.style.color == first }) else { return nil }
        return first
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(swatches.indices, id: \.self) { index in
                let swatch = swatches[index]
                Button { model.foreground = swatch } label: {
                    Circle().fill(Color(nsColor: swatch.nsColor))
                        .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
                        .frame(width: 18, height: 18).padding(4)
                        .overlay(Circle().strokeBorder(commonColor == swatch ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.nsColor.accessibilityName)
                .accessibilityAddTraits(commonColor == swatch ? [.isSelected] : [])
            }
            ScreenshotCustomColorControl(model: model).frame(width: 26, height: 26)
        }
    }
}

private struct ScreenshotSizeControl: View {
    let model: ScreenshotEditorModel
    let text: Bool
    private var values: [CGFloat] {
        Array(Set([current] + (text ? [15, 24, 44, 60, 80] : [2.5, 4, 8, 16, 32]))).sorted()
    }
    private var current: CGFloat { text ? model.textSize : model.brushSize }
    private var isMixed: Bool {
        let values = model.selectedObjects.map { text ? $0.style.fontSize : $0.style.width }
        return Set(values).count > 1
    }
    var body: some View {
        Menu {
            ForEach(values, id: \.self) { size in
                Button { if text { model.textSize = size } else { model.brushSize = size } } label: {
                    Text(verbatim: "\(Double(size).formatted(.number.precision(.fractionLength(0...1)))) px")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: text ? "textformat.size" : "lineweight")
                Text(verbatim: isMixed ? "—" : "\(Double(current).formatted(.number.precision(.fractionLength(0...1)))) px")
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel(text
            ? NSLocalizedString("browser.screenshot.textSize", value: "Text Size", comment: "Screenshot editor - Text size in source image pixels")
            : NSLocalizedString("browser.screenshot.width", value: "Width", comment: "Screenshot editor - Stroke width in source image pixels"))
    }
}

private struct ScreenshotFillControl: View {
    let model: ScreenshotEditorModel
    private var allFilled: Bool { model.selectedObjects.allSatisfy { $0.style.filled } }
    var body: some View {
        Toggle(NSLocalizedString("browser.screenshot.fill", value: "Fill", comment: "Screenshot editor - Fill rectangle or ellipse with the annotation color"), isOn: Binding(get: { allFilled }, set: { model.filled = $0 }))
            .toggleStyle(.checkbox).fixedSize()
    }
}

/// Keep the system color picker inside the object widget without a full-size color well.
private struct ScreenshotCustomColorControl: NSViewRepresentable {
    let model: ScreenshotEditorModel
    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell()
        well.colorWellStyle = .minimal
        well.target = context.coordinator; well.action = #selector(Coordinator.changeColor(_:))
        well.setAccessibilityLabel(NSLocalizedString("browser.screenshot.color", value: "Color", comment: "Screenshot editor - Annotation color control"))
        well.toolTip = NSLocalizedString("browser.screenshot.customColor", value: "Custom color", comment: "Screenshot editor - Open the system color picker for the selected annotations")
        return well
    }
    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.model = model
        if well.color != model.foreground.nsColor { well.color = model.foreground.nsColor }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    @MainActor final class Coordinator: NSObject {
        var model: ScreenshotEditorModel
        init(model: ScreenshotEditorModel) { self.model = model }
        @objc func changeColor(_ sender: NSColorWell) {
            guard let rgb = sender.color.usingColorSpace(.sRGB) else { return }
            model.foreground = ScreenshotColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
        }
    }
}
