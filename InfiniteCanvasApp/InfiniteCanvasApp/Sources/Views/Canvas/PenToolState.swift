import SwiftUI
import PencilKit
import Combine
import CoreData

enum CanvasTool: String, CaseIterable, Codable {
    case lasso, pen, marker, eraser, text, todo
    case shape  // タップ位置へ図形を配置するモード(配置後 lasso へ自動復帰)
    case table  // タップ位置へ表を配置するモード(配置後 lasso へ自動復帰)

    /// 描画(手書き)ではなく、タップ位置へのオブジェクト配置モードのツールか。
    var isPlacementTool: Bool {
        self == .text || self == .todo || self == .shape || self == .table
    }
}

/// 表配置モードで保持する行数・列数(グリッドピッカーの確定値)。
struct TableGridSize: Equatable {
    var rows: Int
    var cols: Int
}

/// ツールバーに並べるお気に入りペン(ペン/マーカーの太さ・色の組み合わせ)。
/// UserDefaults に JSON で永続化する(要件: カスタムペンホルダー)。
struct CustomPen: Identifiable, Codable, Equatable {
    var id: UUID
    var toolType: CanvasTool  // .pen または .marker
    var color: String          // Hex カラーコード(例: "#FF0000FF")
    var width: CGFloat
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

    /// 選択中のテキストオブジェクト(なければ nil)。
    /// これが非nilかつ選択モードのときツールバーにフォントサイズ変更UIを出す。
    @Published var selectedTextObject: SelectedTextObject?

    /// お気に入りペン一覧(ツールバーに動的表示)。変更のたび UserDefaults へ永続化する。
    @Published var favoritePens: [CustomPen] {
        didSet { PenToolState.saveFavorites(favoritePens) }
    }

    /// 現在アクティブなお気に入りペンの ID(青枠ハイライト用)。
    @Published var activePenID: UUID?

    /// 図形配置モード中に保持する図形種別(＋メニューで選択 → タップ位置に配置)。
    @Published var pendingShapeType: ShapeType?

    /// 表配置モード中に保持する行数・列数(グリッドピッカーで選択 → タップ位置に配置)。
    @Published var pendingTableSize: TableGridSize?

    /// オブジェクトの選択・移動モードかどうか。
    /// 専用の「選択ツール」は廃止し、指でオブジェクトをタップして選択している間だけ true になる
    /// (真実のソースはオブジェクトレイヤーの選択状態。選択/解除のたびに書き戻される)。
    /// 選択中は描画ジェスチャを止め、単指はオブジェクト操作・スクロールは2本指に切り替わる。
    @Published var isSelectMode = false

    /// フォントサイズの調整範囲(pt)
    static let fontSizeRange: ClosedRange<CGFloat> = 12...72

    init() {
        let pens = PenToolState.loadFavorites()
        favoritePens = pens
        activePenID = nil
    }

    // MARK: - お気に入りペンの永続化・適用

    private static let favoritesKey = "favoritePens"

    /// プリセット3本: 黒細ペン 3pt / 赤中ペン 5pt / 黄太マーカー 14pt。
    static func defaultFavorites() -> [CustomPen] {
        [
            CustomPen(id: UUID(), toolType: .pen, color: "#000000FF", width: 3),
            CustomPen(id: UUID(), toolType: .pen, color: "#FF0000FF", width: 5),
            CustomPen(id: UUID(), toolType: .marker, color: "#FFCC00FF", width: 14),
        ]
    }

    /// UserDefaults から読み込む。無ければプリセット。UIテスト(RESET_STORE)は毎回プリセットへ。
    static func loadFavorites() -> [CustomPen] {
        if PersistenceController.shouldResetStore {
            UserDefaults.standard.removeObject(forKey: favoritesKey)
            return defaultFavorites()
        }
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let pens = try? JSONDecoder().decode([CustomPen].self, from: data), !pens.isEmpty {
            return pens
        }
        return defaultFavorites()
    }

    static func saveFavorites(_ pens: [CustomPen]) {
        guard let data = try? JSONEncoder().encode(pens) else { return }
        UserDefaults.standard.set(data, forKey: favoritesKey)
    }

    /// お気に入りペンを選択し、その種別・色・太さを現在のツール状態へ反映する。
    func activatePen(_ pen: CustomPen) {
        activePenID = pen.id
        tool = pen.toolType
        isSelectMode = false
        let color = UIColor(hex: pen.color) ?? .black
        if pen.toolType == .marker { markerColor = color } else { penColor = color }
        widths[pen.toolType] = pen.width
    }

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
        case .lasso, .text, .todo, .shape, .table: 1...1  // 未使用(太さ UI を無効化)
        }
    }

    var currentColor: UIColor {
        switch tool {
        case .pen, .eraser, .lasso, .text, .todo, .shape, .table: penColor
        case .marker: markerColor
        }
    }

    /// 太さ・色の調整 UI が意味を持たないツールかどうか
    var isWidthAdjustable: Bool {
        tool == .pen || tool == .marker || tool == .eraser
    }

    func setColor(_ color: UIColor) {
        switch tool {
        case .pen: penColor = color
        case .marker: markerColor = color
        case .eraser, .lasso, .text, .todo, .shape, .table: break
        }
    }

    /// 現在の状態から PKCanvasView に渡すツールを生成
    var pkTool: PKTool {
        switch tool {
        case .pen:
            return PKInkingTool(.pen, color: penColor, width: currentWidth)
        case .marker:
            // 標準 PencilKit マーカー(半透明はツール側が付与)。前面キャンバスへ直接描く。
            return PKInkingTool(.marker, color: markerColor, width: currentWidth)
        case .eraser:
            // .bitmap = なぞった部分だけ消える(ストローク丸ごと消える .vector ではなく)
            return PKEraserTool(.bitmap, width: currentWidth)
        case .lasso:
            // 手書きストロークを囲って選択 → ドラッグ移動、タップでカット/コピー/削除メニュー
            return PKLassoTool()
        case .text, .todo, .shape, .table:
            // タップ配置モード。手書きジェスチャは無効化するため実質未使用(無害な投げ縄を返す)
            return PKLassoTool()
        }
    }
}
