import SwiftUI

/// 図形オブジェクトの編集ポップオーバー(線色 / 塗りつぶし色 / 線の太さ)。
/// 変更はリアルタイムで onUpdate に流し、呼び出し側が Core Data へ反映する。
/// Undo はポップオーバーを閉じるときに呼び出し側が 1つだけ積む。
struct ShapeEditPopover: View {
    let initial: ShapePayload
    let palette: [UIColor]
    let onUpdate: (ShapePayload) -> Void

    @State private var strokeColor: Color
    @State private var fillColor: Color
    @State private var fillIsTransparent: Bool
    @State private var lineWidth: CGFloat

    init(initial: ShapePayload, palette: [UIColor], onUpdate: @escaping (ShapePayload) -> Void) {
        self.initial = initial
        self.palette = palette
        self.onUpdate = onUpdate
        _strokeColor = State(initialValue: Color(uiColor: UIColor(hex: initial.strokeColor) ?? .black))
        let fill = UIColor(hex: initial.fillColor)
        let transparent = (fill?.cgColor.alpha ?? 0) <= 0
        _fillIsTransparent = State(initialValue: transparent)
        _fillColor = State(initialValue: Color(uiColor: (transparent ? nil : fill) ?? .white))
        _lineWidth = State(initialValue: initial.lineWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 線の色
            VStack(alignment: .leading, spacing: 8) {
                Text("線の色").font(.subheadline.weight(.semibold))
                swatchRow(selection: $strokeColor, includeTransparent: false)
            }
            // 塗りつぶし色(塗りが意味を持つ図形のみ)
            if initial.shapeType.isFillable {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("塗りつぶし").font(.subheadline.weight(.semibold))
                    swatchRow(selection: $fillColor, includeTransparent: true)
                }
            }
            Divider()
            // 線の太さ
            VStack(alignment: .leading, spacing: 8) {
                Text("線の太さ: \(String(format: "%.1f pt", lineWidth))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Slider(value: $lineWidth, in: 1...10, step: 0.5)
                    .accessibilityIdentifier("shape-line-width")
            }
        }
        .padding(20)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
        // 注: コンテナに .accessibilityIdentifier を付けると子(スライダー等)の識別子を
        // 上書きしてしまうため付けない。個別要素の識別子(shape-line-width 等)を活かす。
        .onChange(of: strokeColor) { _, _ in emit() }
        .onChange(of: fillColor) { _, _ in emit() }
        .onChange(of: fillIsTransparent) { _, _ in emit() }
        .onChange(of: lineWidth) { _, _ in emit() }
    }

    /// パレット 6色 + カスタム ColorPicker(塗りは先頭に「透明」)。
    @ViewBuilder
    private func swatchRow(selection: Binding<Color>, includeTransparent: Bool) -> some View {
        HStack(spacing: 10) {
            if includeTransparent {
                Button {
                    fillIsTransparent = true
                } label: {
                    ZStack {
                        Circle().fill(Color(.systemBackground))
                        Image(systemName: "slash.circle").foregroundStyle(.secondary)
                    }
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(
                        fillIsTransparent ? Color.accentColor : Color(.separator),
                        lineWidth: fillIsTransparent ? 2.5 : 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("shape-fill-transparent")
            }
            ForEach(Array(palette.enumerated()), id: \.offset) { _, uiColor in
                let color = Color(uiColor: uiColor)
                Button {
                    if includeTransparent { fillIsTransparent = false }
                    selection.wrappedValue = color
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: selection, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30)
                .onChange(of: selection.wrappedValue) { _, _ in
                    if includeTransparent { fillIsTransparent = false }
                }
        }
    }

    private func emit() {
        let stroke = UIColor(strokeColor).hexStringRGBA
        let fill: String = (!initial.shapeType.isFillable || fillIsTransparent)
            ? "#00000000"
            : UIColor(fillColor).hexStringRGBA
        onUpdate(ShapePayload(
            shapeType: initial.shapeType,
            strokeColor: stroke,
            fillColor: fill,
            lineWidth: lineWidth
        ))
    }
}
