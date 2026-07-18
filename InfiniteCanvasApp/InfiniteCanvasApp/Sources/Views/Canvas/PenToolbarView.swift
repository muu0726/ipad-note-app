import SwiftUI
import PencilKit

/// 自由ノート風のアプリ固定カスタムツールバー(PKToolPicker 不使用)。
/// 並び: `[戻る][進む] | [投げ縄][ペン●][マーカー●][消しゴム][テキスト] | [図形アシスト] | [＋]`
/// 太さ・色は常時表示せず、選択中ツールを **再タップ** したときにそのツール直上へ
/// 「太さスライダー + カラーパレット」の設定ポップオーバーを出す。
struct PenToolbarView: View {
    @ObservedObject var toolState: PenToolState
    @ObservedObject var undoBridge: CanvasUndoBridge
    @Binding var isCollapsed: Bool
    var onInsertText: () -> Void = {}
    var onInsertImage: () -> Void = {}
    var onInsertPDF: () -> Void = {}
    var onInsertNoteLink: () -> Void = {}
    var onInsertTodo: () -> Void = {}
    /// ライブラリ一覧へ戻る(タブ・分割は維持したまま)。
    var onOpenLibrary: () -> Void = {}
    /// 選択中テキストのフォントサイズ変更(新しい絶対サイズを渡す)
    var onFontSizeChange: (CGFloat) -> Void = { _ in }
    @State private var customColor: Color = .black
    /// 設定ポップオーバーを開いているツール(再タップで開く)。nil で閉じる。
    @State private var settingsPopoverTool: CanvasTool?

    var body: some View {
        HStack(spacing: 0) {
            if !isCollapsed {
                libraryButton
                barDivider
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
                insertMenu
            }
            Spacer(minLength: 8)
            // 折りたたみボタンは常に右端
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
        .onChange(of: toolState.tool) { _, _ in
            customColor = Color(uiColor: toolState.currentColor)
        }
    }

    private var barDivider: some View {
        Divider().frame(height: 24).padding(.horizontal, 10)
    }

    // MARK: - ライブラリへ戻る(タブ・分割は維持)

    /// 一覧へ戻る導線。分割中もサイドバートグルが出ず一覧へ戻れなくなるため、
    /// キャンバス左端に常設する(session.showLibrary は openNotes/分割状態を保持する)。
    private var libraryButton: some View {
        Button {
            onOpenLibrary()
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 16))
                .frame(width: 36, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("canvas-to-library")
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

    // MARK: - ツール切替(投げ縄 / ペン / マーカー / 消しゴム / テキスト)

    private var toolButtons: some View {
        HStack(spacing: 4) {
            toolButton(.lasso, icon: "lasso")
            toolButton(.pen, icon: "pencil.tip")
            toolButton(.marker, icon: "highlighter")
            toolButton(.eraser, icon: "eraser")
            // テキストはタップ位置配置ツール(手書きは遮断)。アイコンは四角囲みT。
            toolButton(.text, icon: "t.square")
        }
    }

    /// ツールボタン。未選択→切替のみ / 選択中に再タップ→設定ポップオーバー(ペン・マーカー・消しゴム)。
    private func toolButton(_ tool: CanvasTool, icon: String) -> some View {
        Button {
            if toolState.tool == tool, !toolState.isSelectMode {
                // 描画モードで同じツールを再タップ → 設定ポップオーバー
                if hasSettings(tool) { settingsPopoverTool = tool }
            } else {
                // 別ツールへの切替、または選択/編集モードからの復帰。
                // どちらの場合もオブジェクト選択/テキスト編集は解除して描画へ戻す。
                toolState.tool = tool
                toolState.isSelectMode = false
            }
        } label: {
            toolIcon(tool, icon: icon)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("toolbar-tool-\(tool.rawValue)")
        .popover(isPresented: popoverBinding(for: tool), arrowEdge: .top) {
            toolSettingsPopover(for: tool)
        }
    }

    private func toolIcon(_ tool: CanvasTool, icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18))
            .frame(width: 40, height: 34)
            .background(
                toolState.tool == tool ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            // ペン・マーカーは現在のインク色を小さなドットで示す
            .overlay(alignment: .bottom) {
                if tool == .pen || tool == .marker {
                    Circle()
                        .fill(Color(uiColor: inkColor(for: tool)))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1))
                        .padding(.bottom, 1)
                }
            }
            .contentShape(Rectangle())
    }

    private func inkColor(for tool: CanvasTool) -> UIColor {
        tool == .marker ? toolState.markerColor : toolState.penColor
    }

    /// 設定ポップオーバーを持つツール(太さ or 色を調整できる)
    private func hasSettings(_ tool: CanvasTool) -> Bool {
        tool == .pen || tool == .marker || tool == .eraser
    }

    private func popoverBinding(for tool: CanvasTool) -> Binding<Bool> {
        Binding(
            get: { settingsPopoverTool == tool },
            set: { if !$0 { settingsPopoverTool = nil } }
        )
    }

    // MARK: - ツール設定ポップオーバー(太さ + 色)

    @ViewBuilder
    private func toolSettingsPopover(for tool: CanvasTool) -> some View {
        VStack(spacing: 16) {
            // 太さ
            VStack(spacing: 10) {
                Text("太さ: \(widthText)")
                    .font(.headline.monospacedDigit())
                Slider(
                    value: Binding(
                        get: { toolState.currentWidth },
                        set: { toolState.currentWidth = ($0 * 2).rounded() / 2 }  // 0.5pt 刻み
                    ),
                    in: toolState.widthRange
                )
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 220, height: min(toolState.currentWidth, 40))
                    .animation(.easeOut(duration: 0.1), value: toolState.currentWidth)
            }
            // 色(ペン・マーカーのみ)
            if tool == .pen || tool == .marker {
                Divider()
                colorPaletteRow
            }
        }
        .padding(20)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }

    private var widthText: String {
        String(format: "%.1f pt", toolState.currentWidth)
    }

    // MARK: - カラーパレット(ポップオーバー内。6色 + カスタム)

    private var colorPaletteRow: some View {
        HStack(spacing: 10) {
            ForEach(Array(toolState.palette.enumerated()), id: \.offset) { _, color in
                Button {
                    toolState.setColor(color)
                    customColor = Color(uiColor: color)
                } label: {
                    Circle()
                        .fill(Color(uiColor: color))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle().strokeBorder(
                                isCurrent(color) ? Color.accentColor : Color(.separator),
                                lineWidth: isCurrent(color) ? 2.5 : 0.5
                            )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("toolbar-color-\(colorIdentifier(color))")
            }
            // カスタム色(HSB ピッカー)
            ColorPicker("カスタム色", selection: $customColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30)
                .onChange(of: customColor) { _, newValue in
                    toolState.setColor(UIColor(newValue))
                }
        }
    }

    private func isCurrent(_ color: UIColor) -> Bool {
        toolState.currentColor == color
    }

    private func colorIdentifier(_ color: UIColor) -> String {
        (toolState.palette.firstIndex(of: color)).map(String.init) ?? "x"
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

    // MARK: - 図形認識アシスト(ON/OFF トグル)

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

    // MARK: - オブジェクト挿入(画像 / PDF / Todo / ノートリンク。テキストはメインツールへ移設)

    private var insertMenu: some View {
        Menu {
            Button(action: onInsertImage) {
                Label("画像", systemImage: "photo")
            }
            Button(action: onInsertPDF) {
                Label("PDF", systemImage: "doc.text")
            }
            Button {
                // 即挿入ではなく Todo 配置ツールへ(次のタップ位置に配置)
                toolState.tool = .todo
                toolState.isSelectMode = false
            } label: {
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
