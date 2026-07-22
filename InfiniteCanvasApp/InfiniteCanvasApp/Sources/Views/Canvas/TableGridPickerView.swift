import SwiftUI

/// Excel 風の「行 × 列」グリッドピッカー。マス目を指でなぞると選択範囲がハイライトされ、
/// 離すと確定して onSelect(rows, cols) を呼ぶ。
struct TableGridPickerView: View {
    /// 確定した (rows, cols) を渡す。
    var onSelect: (Int, Int) -> Void

    private let maxRows = 8
    private let maxCols = 8
    private let cell: CGFloat = 26
    private let spacing: CGFloat = 4
    private var pitch: CGFloat { cell + spacing }

    @State private var rows = 0
    @State private var cols = 0

    var body: some View {
        VStack(spacing: 12) {
            Text(rows > 0 ? "\(rows) × \(cols)" : "表のサイズ")
                .font(.headline.monospacedDigit())
                .accessibilityIdentifier("table-grid-label")

            grid
        }
        .padding(20)
        .presentationCompactAdaptation(.popover)
    }

    private var grid: some View {
        VStack(spacing: spacing) {
            ForEach(0..<maxRows, id: \.self) { r in
                HStack(spacing: spacing) {
                    ForEach(0..<maxCols, id: \.self) { c in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isSelected(r, c) ? Color.accentColor.opacity(0.4) : Color(uiColor: .systemGray5))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .coordinateSpace(name: "grid")
        .accessibilityIdentifier("table-grid-picker")
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("grid"))
                .onChanged { value in
                    cols = min(maxCols, max(1, Int(value.location.x / pitch) + 1))
                    rows = min(maxRows, max(1, Int(value.location.y / pitch) + 1))
                }
                .onEnded { _ in
                    if rows > 0, cols > 0 { onSelect(rows, cols) }
                }
        )
    }

    private func isSelected(_ r: Int, _ c: Int) -> Bool {
        r < rows && c < cols
    }
}
