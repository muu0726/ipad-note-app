import SwiftUI
import PencilKit
import Combine
import CoreData

enum CanvasTool: String, CaseIterable {
    case selector, lasso, pen, marker, eraser
}

/// 選択中のテキストオブジェクト情報(ツールバーのフォントサイズ UI 用)
struct SelectedTextObject: Equatable {
    let objectID: NSManagedObjectID
    var fontSize: CGFloat
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
    case blank, grid, dots, lines

    var label: String {
        switch self {
        case .blank: "白紙"
        case .grid: "方眼"
        case .dots: "ドット"
        case .lines: "横線"
        }
    }
}

/// カスタムペンツールバーの状態。PKToolPicker は使わず、
/// ここから PKCanvasView.tool をプログラム制御する(要件③)。
@MainActor
final class PenToolState: ObservableObject {
    @Published var tool: CanvasTool = .pen

    /// ツールごとの太さ(pt)。数値で管理し、スライダーで調整する(Goodnotes 風)
    @Published var widths: [CanvasTool: CGFloat] = [
        .pen: 3,
        .marker: 14,
        .eraser: 28,
    ]

    /// ペン・マーカーの色(ツールごとに独立して記憶)
    @Published var penColor: UIColor = .black
    @Published var markerColor: UIColor = .systemYellow

    /// カラーパレット(「＋」の ColorPicker で任意色も選択可能)。黒い用紙用に白も用意
    @Published var palette: [UIColor] = [.black, .white, .systemRed, .systemBlue, .systemGreen, .systemOrange]

    /// 図形認識アシスト。ON のとき、描き終えたストロークが直線・楕円・矩形に近ければ
    /// きれいな図形へ自動置換する。誤判定を嫌うユーザー向けに既定は OFF。
    @Published var isShapeAssistEnabled = false

    /// 選択ツールで選択中のテキストオブジェクト(なければ nil)。
    /// これが非nilかつ選択モードのときツールバーにフォントサイズ変更UIを出す。
    @Published var selectedTextObject: SelectedTextObject?

    /// フォントサイズの調整範囲(pt)
    static let fontSizeRange: ClosedRange<CGFloat> = 12...72

    var currentWidth: CGFloat {
        get { widths[tool] ?? 3 }
        set { widths[tool] = min(max(newValue, widthRange.lowerBound), widthRange.upperBound) }
    }

    /// ツールごとの太さの可動域(pt)
    var widthRange: ClosedRange<CGFloat> {
        switch tool {
        case .pen: 0.5...20
        case .marker: 2...40
        case .eraser: 4...80
        case .selector, .lasso: 1...1  // 未使用(太さ UI を無効化)
        }
    }

    var currentColor: UIColor {
        switch tool {
        case .pen, .eraser, .selector, .lasso: penColor
        case .marker: markerColor
        }
    }

    /// オブジェクトの選択・移動モードかどうか(要件③)
    var isSelectMode: Bool { tool == .selector }

    /// 太さ・色の調整 UI が意味を持たないツールかどうか
    var isWidthAdjustable: Bool {
        tool == .pen || tool == .marker || tool == .eraser
    }

    func setColor(_ color: UIColor) {
        switch tool {
        case .pen: penColor = color
        case .marker: markerColor = color
        case .eraser, .selector, .lasso: break
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
        case .lasso:
            // 手書きストロークを囲って選択 → ドラッグ移動、タップでカット/コピー/削除メニュー
            return PKLassoTool()
        case .selector:
            // 選択モード中は描画ジェスチャ自体を無効化するため実際には使われない
            return PKInkingTool(.pen, color: penColor, width: currentWidth)
        }
    }
}
