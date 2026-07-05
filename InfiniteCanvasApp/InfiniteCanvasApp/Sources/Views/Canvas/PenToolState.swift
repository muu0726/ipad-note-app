import SwiftUI
import PencilKit
import Combine

enum CanvasTool: String, CaseIterable {
    case selector, pen, marker, eraser
}

/// ノート作成時に選ぶ用紙の色(白 / 黒)。
/// 白紙は黒い罫線・ドット、黒紙は白い罫線・ドットになる(自由ノート風)。
enum CanvasPageColor: String, CaseIterable {
    case white, black

    var label: String {
        switch self {
        case .white: "白"
        case .black: "黒"
        }
    }

    /// 用紙(背景)の色
    var backgroundUIColor: UIColor {
        switch self {
        case .white: .white
        case .black: .black
        }
    }

    /// 方眼・ドットの色
    var patternUIColor: UIColor {
        switch self {
        case .white: UIColor.black.withAlphaComponent(0.45)
        case .black: UIColor.white.withAlphaComponent(0.55)
        }
    }

    /// テキストオブジェクトなどコンテンツの標準色
    var contentUIColor: UIColor {
        switch self {
        case .white: .black
        case .black: .white
        }
    }
}

enum CanvasBackgroundStyle: String, CaseIterable {
    case blank, grid, dots

    var label: String {
        switch self {
        case .blank: "白紙"
        case .grid: "方眼"
        case .dots: "ドット"
        }
    }
}

/// カスタムペンツールバーの状態。PKToolPicker は使わず、
/// ここから PKCanvasView.tool をプログラム制御する(要件③)。
@MainActor
final class PenToolState: ObservableObject {
    @Published var tool: CanvasTool = .pen

    /// ツールごとの太さ3スロット(pt)
    @Published var widthSlots: [CanvasTool: [CGFloat]] = [
        .pen: [1.5, 3, 6],
        .marker: [8, 14, 20],
        .eraser: [12, 28, 56],
    ]
    /// ツールごとの選択中スロット(太さはツールごとに独立して記憶)
    @Published var selectedSlot: [CanvasTool: Int] = [.pen: 1, .marker: 1, .eraser: 1]

    /// ペン・マーカーの色(ツールごとに独立して記憶)
    @Published var penColor: UIColor = .black
    @Published var markerColor: UIColor = .systemYellow

    /// カラーパレット(「＋」の ColorPicker で任意色も選択可能)。黒い用紙用に白も用意
    @Published var palette: [UIColor] = [.black, .white, .systemRed, .systemBlue, .systemGreen, .systemOrange]

    var currentWidth: CGFloat {
        let slots = widthSlots[tool] ?? [3, 6, 9]
        let index = min(selectedSlot[tool] ?? 1, slots.count - 1)
        return slots[index]
    }

    var currentColor: UIColor {
        switch tool {
        case .pen, .eraser, .selector: penColor
        case .marker: markerColor
        }
    }

    /// オブジェクトの選択・移動モードかどうか(要件③)
    var isSelectMode: Bool { tool == .selector }

    func setColor(_ color: UIColor) {
        switch tool {
        case .pen: penColor = color
        case .marker: markerColor = color
        case .eraser, .selector: break
        }
    }

    /// 現在の状態から PKCanvasView に渡すツールを生成
    var pkTool: PKTool {
        switch tool {
        case .pen:
            return PKInkingTool(.pen, color: penColor, width: currentWidth)
        case .marker:
            return PKInkingTool(.marker, color: markerColor, width: currentWidth)
        case .eraser:
            // .bitmap = なぞった部分だけ消える(ストローク丸ごと消える .vector ではなく)
            return PKEraserTool(.bitmap, width: currentWidth)
        case .selector:
            // 選択モード中は描画ジェスチャ自体を無効化するため実際には使われない
            return PKInkingTool(.pen, color: penColor, width: currentWidth)
        }
    }
}
