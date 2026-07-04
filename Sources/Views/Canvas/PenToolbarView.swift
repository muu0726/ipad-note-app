import SwiftUI
import PencilKit
import UIKit

/// Goodnotes 風のアプリ固定カスタムツールバー(PKToolPicker 不使用)。
/// 左: ツール切替 / 中央: 太さ3スロット / 右: カラーパレット + カスタム色 + 折りたたみ。
struct PenToolbarView: View {
    @ObservedObject var toolState: PenToolState
    @Binding var isCollapsed: Bool
    @State private var customColor: Color = .black

    var body: some View {
        HStack(spacing: 0) {
            if !isCollapsed {
                toolButtons
                if toolState.tool != .selector {
                    barDivider
                    widthSlots
                    barDivider
                    colorPalette
                }
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() }
            } label: {
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCollapsed ? 0 : 6)
        .background(.bar)
    }

    private var barDivider: some View {
        Divider().frame(height: 24).padding(.horizontal, 10)
    }

    // MARK: - ツール切替

    private var toolButtons: some View {
        HStack(spacing: 4) {
            toolButton(.selector, icon: "cursorarrow")
            toolButton(.pen, icon: "pencil.tip")
            toolButton(.marker, icon: "highlighter")
            toolButton(.eraser, icon: "eraser")
        }
    }

    private func toolButton(_ tool: CanvasTool, icon: String) -> some View {
        Button {
            toolState.tool = tool
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 40, height: 34)
                .background(
                    toolState.tool == tool ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 太さ3スロット

    private var widthSlots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                let isSelected = (toolState.selectedSlot[toolState.tool] ?? 1) == index
                Button {
                    toolState.selectedSlot[toolState.tool] = index
                } label: {
                    Circle()
                        .fill(isSelected ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: 7 + CGFloat(index) * 4, height: 7 + CGFloat(index) * 4)
                        .frame(width: 28, height: 28)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.18) : .clear,
                            in: Circle()
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - カラーパレット

    private var colorPalette: some View {
        HStack(spacing: 8) {
            ForEach(Array(toolState.palette.enumerated()), id: \.offset) { _, color in
                Button {
                    toolState.setColor(color)
                } label: {
                    Circle()
                        .fill(Color(uiColor: color))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(
                                isCurrent(color) ? Color.accentColor : Color(.separator),
                                lineWidth: isCurrent(color) ? 2.5 : 0.5
                            )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            // カスタム色(HSB ピッカー)
            ColorPicker("カスタム色", selection: $customColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30)
                .onChange(of: customColor) { _, newValue in
                    toolState.setColor(UIColor(newValue))
                }
        }
        .disabled(toolState.tool == .eraser)
        .opacity(toolState.tool == .eraser ? 0.35 : 1)
    }

    private func isCurrent(_ color: UIColor) -> Bool {
        toolState.currentColor == color
    }
}
