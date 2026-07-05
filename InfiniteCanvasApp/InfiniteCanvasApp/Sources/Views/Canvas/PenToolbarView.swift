import SwiftUI
import PencilKit

/// 自由ノート風のアプリ固定カスタムツールバー(PKToolPicker 不使用)。
/// 左: 戻る / やり直し → ツール切替(選択 / ペン / マーカー / 消しゴム)/ 中央: 太さ3スロット /
/// 右: カラーパレット + カスタム色 + オブジェクト挿入メニュー + 折りたたみ。
struct PenToolbarView: View {
    @ObservedObject var toolState: PenToolState
    @ObservedObject var undoBridge: CanvasUndoBridge
    @Binding var isCollapsed: Bool
    var onInsertText: () -> Void = {}
    var onInsertImage: () -> Void = {}
    var onInsertPDF: () -> Void = {}
    @State private var customColor: Color = .black
    @State private var isWidthPopoverPresented = false

    var body: some View {
        HStack(spacing: 0) {
            if !isCollapsed {
                undoRedoButtons
                barDivider
                toolButtons
                barDivider
                widthControl
                barDivider
                colorPalette
                barDivider
                insertMenu
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

    // MARK: - 戻る / やり直し

    private var undoRedoButtons: some View {
        HStack(spacing: 4) {
            Button {
                undoBridge.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!undoBridge.canUndo)
            .opacity(undoBridge.canUndo ? 1 : 0.35)

            Button {
                undoBridge.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!undoBridge.canRedo)
            .opacity(undoBridge.canRedo ? 1 : 0.35)
        }
    }

    // MARK: - ツール切替

    private var toolButtons: some View {
        HStack(spacing: 4) {
            toolButton(.selector, icon: "hand.point.up.left")
            toolButton(.lasso, icon: "lasso")
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

    // MARK: - 太さ(数値管理。Goodnotes 風にタップでスライダーポップオーバー)

    private var widthControl: some View {
        Button {
            isWidthPopoverPresented = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.primary)
                    .frame(width: widthPreviewDiameter, height: widthPreviewDiameter)
                    .frame(width: 22, height: 22)
                Text(widthText)
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 48, alignment: .leading)
            }
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isWidthPopoverPresented, arrowEdge: .top) {
            widthPopover
        }
        .disabled(!toolState.isWidthAdjustable)
        .opacity(toolState.isWidthAdjustable ? 1 : 0.35)
    }

    private var widthPopover: some View {
        VStack(spacing: 14) {
            Text("太さ: \(widthText)")
                .font(.headline.monospacedDigit())
            Slider(
                value: Binding(
                    get: { toolState.currentWidth },
                    set: { toolState.currentWidth = ($0 * 2).rounded() / 2 }  // 0.5pt 刻み
                ),
                in: toolState.widthRange
            )
            // 実際の太さのプレビュー
            Capsule()
                .fill(Color.primary)
                .frame(width: 180, height: min(toolState.currentWidth, 44))
                .animation(.easeOut(duration: 0.1), value: toolState.currentWidth)
        }
        .padding(20)
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
    }

    private var widthText: String {
        String(format: "%.1f pt", toolState.currentWidth)
    }

    /// ツールバー内に収まるよう 6〜18pt に正規化した見本サイズ
    private var widthPreviewDiameter: CGFloat {
        let range = toolState.widthRange
        let span = max(range.upperBound - range.lowerBound, 0.1)
        let t = (toolState.currentWidth - range.lowerBound) / span
        return 6 + t * 12
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
        .disabled(!isColorSelectable)
        .opacity(isColorSelectable ? 1 : 0.35)
    }

    private func isCurrent(_ color: UIColor) -> Bool {
        toolState.currentColor == color
    }

    /// 色が選べるのはペン・マーカーのみ
    private var isColorSelectable: Bool {
        toolState.tool == .pen || toolState.tool == .marker
    }

    // MARK: - オブジェクト挿入(要件③)

    private var insertMenu: some View {
        Menu {
            Button(action: onInsertText) {
                Label("テキスト", systemImage: "textformat")
            }
            Button(action: onInsertImage) {
                Label("画像", systemImage: "photo")
            }
            Button(action: onInsertPDF) {
                Label("PDF", systemImage: "doc.text")
            }
        } label: {
            Image(systemName: "plus.square.on.square")
                .font(.system(size: 18))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
