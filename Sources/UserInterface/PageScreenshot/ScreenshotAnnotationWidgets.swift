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
        case .mosaic: EmptyView()
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

/// A compact palette button activates a native color well without displaying its large bezel.
private struct ScreenshotCustomColorControl: NSViewRepresentable {
    let model: ScreenshotEditorModel
    func makeNSView(context: Context) -> PaletteView { PaletteView(model: model) }
    func updateNSView(_ view: PaletteView, context: Context) { view.update(model: model) }

    @MainActor final class PaletteView: NSView {
        private let button = NSButton()
        private let well = NSColorWell()
        private var model: ScreenshotEditorModel
        private var editedIDs: Set<UUID> = []

        init(model: ScreenshotEditorModel) {
            self.model = model
            super.init(frame: .zero)
            button.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
            button.imagePosition = .imageOnly; button.isBordered = false
            button.focusRingType = .none; button.contentTintColor = .labelColor
            button.toolTip = NSLocalizedString("browser.screenshot.customColor", value: "Custom color", comment: "Screenshot editor - Open the system color picker for the selected annotations")
            button.setAccessibilityLabel(button.toolTip)
            button.setAccessibilityIdentifier("screenshot.customColor")
            button.target = self; button.action = #selector(openColors(_:))
            well.isHidden = true; well.target = self; well.action = #selector(changeColor(_:))
            addSubview(well); addSubview(button)
            update(model: model)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }
        override func layout() { super.layout(); button.frame = bounds }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { well.deactivate() }
        }
        func update(model: ScreenshotEditorModel) {
            self.model = model
            if editedIDs != model.selectedIDs { well.deactivate() }
            if well.color != model.foreground.nsColor { well.color = model.foreground.nsColor }
        }
        @objc private func openColors(_ sender: Any?) {
            editedIDs = model.selectedIDs
            well.color = model.foreground.nsColor
            well.activate(true)
            NSColorPanel.shared.makeKeyAndOrderFront(nil)
        }
        @objc private func changeColor(_ sender: NSColorWell) {
            guard !editedIDs.isEmpty, editedIDs == model.selectedIDs,
                  let rgb = sender.color.usingColorSpace(.sRGB) else { return }
            model.foreground = ScreenshotColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
        }
    }
}
