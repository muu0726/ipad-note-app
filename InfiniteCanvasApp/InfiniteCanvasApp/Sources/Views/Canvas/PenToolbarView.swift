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
    var onInsertNoteLink: () -> Void = {}
    var onInsertTodo: () -> Void = {}
    /// 選択中テキストのフォントサイズ変更(新しい絶対サイズを渡す)
    var onFontSizeChange: (CGFloat) -> Void = { _ in }
    @State private var customColor: Color = .black
    @State private var isWidthPopoverPresented = false

    var body: some View {
        HStack(spacing: 0) {
            if !isCollapsed {
                undoRedoButtons
                barDivider
                toolButtons
                barDivider
                shapeAssistButton
                // テキスト選択中はフォントサイズ変更UIを差し込む
                if toolState.isSelectMode, toolState.selectedTextObject != nil {
                    barDivider
                    fontSizeControl
                }
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
        // ツール切替のたびにカスタムカラーピッカーの表示を今のツールの色へ同期する。
        // (customColor はローカル @State のため、切替なしだと前のツールで選んだ色が
        //  表示に残り、選び直しても toolState.currentColor と一致して onChange が
        //  発火せず反映されないことがあった)
        .onChange(of: toolState.tool) { _, _ in
            customColor = Color(uiColor: toolState.currentColor)
        }
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
            .accessibilityIdentifier("toolbar-undo")

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
            .accessibilityIdentifier("toolbar-redo")
        }
    }

    // MARK: - ツール切替

    private var toolButtons: some View {
        HStack(spacing: 4) {
            toolButton(.lasso, icon: "lasso")
            toolButton(.pen, icon: "pencil.tip")
            toolButton(.marker, icon: "highlighter")
            toolButton(.eraser, icon: "eraser")
        }
    }

    private func toolButton(_ tool: CanvasTool, icon: String) -> some View {
        Button {
            toolState.tool = tool
            // 描画/消しゴム/投げ縄を選んだら、直前のオブジェクト選択は解除して描画に戻す。
            // (選択解除はオブジェクトレイヤーへ伝播し、描画ジェスチャが再び有効になる)
            toolState.isSelectMode = false
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
        .accessibilityIdentifier("toolbar-tool-\(tool.rawValue)")
    }

    // MARK: - フォントサイズ(テキスト選択中のみ表示)

    private var currentFontSize: CGFloat {
        toolState.selectedTextObject?.fontSize ?? 24
    }

    private var fontSizeControl: some View {
        HStack(spacing: 8) {
            Button { adjustFontSize(by: -2) } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 18))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toolbar-font-decrease")

            Text("\(Int(currentFontSize.rounded()))")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 28)
                .accessibilityIdentifier("toolbar-font-size")

            Button { adjustFontSize(by: 2) } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 18))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toolbar-font-increase")
        }
    }

    private func adjustFontSize(by delta: CGFloat) {
        let range = PenToolState.fontSizeRange
        let next = min(max(currentFontSize + delta, range.lowerBound), range.upperBound)
        onFontSizeChange(next)
    }

    // MARK: - 図形認識アシスト(要件: ON/OFF トグル)

    /// ON のとき、描き終えた手書きが直線・楕円・矩形に近ければきれいな図形へ自動置換する
    private var shapeAssistButton: some View {
        Button {
            toolState.isShapeAssistEnabled.toggle()
        } label: {
            Image(systemName: "square.on.circle")
                .font(.system(size: 18))
                .frame(width: 40, height: 34)
                .background(
                    toolState.isShapeAssistEnabled ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("toolbar-shape-assist")
        .accessibilityLabel("図形アシスト")
        .accessibilityAddTraits(toolState.isShapeAssistEnabled ? [.isSelected] : [])
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
                    // カスタムカラーピッカーの表示も同期(次に開いたときに実際の色を示す)
                    customColor = Color(uiColor: color)
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
            Button(action: onInsertTodo) {
                Label("Todoリスト", systemImage: "checklist")
            }
            .accessibilityIdentifier("toolbar-insert-todo")
            Button(action: onInsertNoteLink) {
                Label("ノートリンク", systemImage: "link")
            }
        } label: {
            Image(systemName: "plus.square.on.square")
                .font(.system(size: 18))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("toolbar-insert-menu")
    }
}
