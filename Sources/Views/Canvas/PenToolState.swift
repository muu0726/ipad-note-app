import SwiftUI
import PencilKit
import Combine
import UIKit

enum CanvasTool: String, CaseIterable {
    case selector, pen, marker, eraser
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

    /// カラーパレット(「＋」の ColorPicker で任意色も選択可能)
    @Published var palette: [UIColor] = [.black, .systemRed, .systemBlue, .systemGreen, .systemOrange]

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

    func setColor(_ color: UIColor) {
        switch tool {
        case .pen: penColor = color
        case .marker: markerColor = color
        case .eraser: break
        }
    }

    /// 現在の状態から PKCanvasView に渡すツールを生成
    var pkTool: PKTool {
        switch tool {
        case .pen, .selector:
            // 選択モード中はキャンバス操作が無効なのでツールは使われない(ペンを返しておく)
            return PKInkingTool(.pen, color: penColor, width: currentWidth)
        case .marker:
            return PKInkingTool(.marker, color: markerColor, width: currentWidth)
        case .eraser:
            return PKEraserTool(.vector, width: currentWidth)
        }
    }
}
