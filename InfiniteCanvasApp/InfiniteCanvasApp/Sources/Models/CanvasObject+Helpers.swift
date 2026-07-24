import CoreData
import UIKit
import PDFKit

/// キャンバス上に配置できるオブジェクトの種類(要件③)
enum CanvasObjectKind: String {
    case text, image, pdf
    case noteLink  // 他のノートへのショートカット(カード型UI)
    case todo      // チェックリスト(タスク管理)
    case shape     // 図形(矩形・楕円・三角・直線・矢印・星)
    case table     // 表(Excel風・可変列幅/行高)
    case stickyNote  // 付箋(カラー・角丸・影・ダブルタップ編集)
    case connector   // 2オブジェクトを結ぶ自動追従コネクタ線
}

/// コネクタ線のパラメータ。payload に JSON で保存する。
/// 接続先はオブジェクトの UUID 文字列で参照し、位置は描画時に都度解決する
/// (既存の linkedNoteUUID と同じ「UUID参照+都度解決」パターン)。
struct ConnectorPayload: Codable, Equatable {
    var sourceID: String  // 接続元オブジェクトの UUID
    var targetID: String  // 接続先オブジェクトの UUID
    var hasArrow: Bool = true
}

/// 付箋の色(Freeform 準拠の6色)。payload の StickyNotePayload に保持する。
enum StickyNoteColor: String, Codable, CaseIterable {
    case yellow, green, pink, blue, purple, gray

    /// ＋メニューでの表示名。
    var displayName: String {
        switch self {
        case .yellow: "イエロー"
        case .green: "グリーン"
        case .pink: "ピンク"
        case .blue: "ブルー"
        case .purple: "パープル"
        case .gray: "グレー"
        }
    }

    /// 付箋の背景色(淡いパステル)。
    var backgroundUIColor: UIColor {
        switch self {
        case .yellow: UIColor(red: 1.00, green: 0.92, blue: 0.55, alpha: 1)
        case .green:  UIColor(red: 0.78, green: 0.93, blue: 0.68, alpha: 1)
        case .pink:   UIColor(red: 1.00, green: 0.78, blue: 0.85, alpha: 1)
        case .blue:   UIColor(red: 0.72, green: 0.87, blue: 1.00, alpha: 1)
        case .purple: UIColor(red: 0.85, green: 0.80, blue: 0.98, alpha: 1)
        case .gray:   UIColor(red: 0.88, green: 0.89, blue: 0.90, alpha: 1)
        }
    }

    /// 付箋上の文字色(パステル背景で読みやすい濃色)。
    var textUIColor: UIColor { UIColor(white: 0.13, alpha: 1) }
}

/// 付箋オブジェクトのパラメータ。payload に JSON で保存する。
struct StickyNotePayload: Codable, Equatable {
    var color: StickyNoteColor
}

/// Todoリストの1項目。payload に [TodoItem] を JSON で保存する。
struct TodoItem: Codable, Equatable {
    var text: String
    var done: Bool
}

/// 図形の種別。payload の ShapePayload に保持する。
enum ShapeType: String, Codable, CaseIterable {
    case rectangle, ellipse, triangle, line, arrow, star

    /// 塗りつぶしが意味を持つ図形か(線・矢印はストロークのみ)。
    var isFillable: Bool {
        switch self {
        case .rectangle, .ellipse, .triangle, .star: true
        case .line, .arrow: false
        }
    }

    /// ＋メニューでの表示名。
    var displayName: String {
        switch self {
        case .rectangle: "四角"
        case .ellipse: "円"
        case .triangle: "三角"
        case .line: "直線"
        case .arrow: "矢印"
        case .star: "星"
        }
    }

    /// ＋メニューのアイコン(SF Symbols)。
    var symbolName: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .triangle: "triangle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .star: "star"
        }
    }

    /// 指定矩形いっぱいに図形パスを構築する(呼び出し側で lineWidth 分を inset 済みの前提)。
    func path(in rect: CGRect) -> UIBezierPath {
        switch self {
        case .rectangle:
            return UIBezierPath(roundedRect: rect, cornerRadius: 4)
        case .ellipse:
            return UIBezierPath(ovalIn: rect)
        case .triangle:
            let p = UIBezierPath()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.close()
            return p
        case .line:
            let p = UIBezierPath()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        case .arrow:
            let p = UIBezierPath()
            let midY = rect.midY
            p.move(to: CGPoint(x: rect.minX, y: midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: midY))
            // 右端の三角ヘッド(矢印)
            let head = min(rect.width, rect.height) * 0.32
            p.move(to: CGPoint(x: rect.maxX - head, y: midY - head))
            p.addLine(to: CGPoint(x: rect.maxX, y: midY))
            p.addLine(to: CGPoint(x: rect.maxX - head, y: midY + head))
            return p
        case .star:
            let p = UIBezierPath()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outer = min(rect.width, rect.height) / 2
            let inner = outer * 0.42
            for i in 0..<10 {
                let radius = i.isMultiple(of: 2) ? outer : inner
                // 頂点を上向きにするため -90° から開始
                let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let pt = CGPoint(x: center.x + radius * cos(angle),
                                 y: center.y + radius * sin(angle))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.close()
            return p
        }
    }
}

/// 図形オブジェクトのパラメータ。payload に JSON で保存する。
struct ShapePayload: Codable, Equatable {
    var shapeType: ShapeType
    var strokeColor: String  // Hex(例: "#000000FF")
    var fillColor: String    // Hex(例: "#00000000" = 透明)
    var lineWidth: CGFloat   // 1.0〜10.0pt
}

/// 表の1セル。空文字セルは保存しない(疎行列)。
struct TableCell: Codable, Equatable {
    var row: Int
    var col: Int
    var text: String
}

/// 表オブジェクトの構造。payload に JSON で保存する(Excel風の可変列幅・行高)。
struct TablePayload: Codable, Equatable {
    var rowCount: Int
    var columnCount: Int
    var columnWidths: [CGFloat]  // 各列の幅(pt)
    var rowHeights: [CGFloat]    // 各行の高さ(pt)
    var cells: [TableCell]       // 非空セルのみ

    /// 指定サイズの空の表を作る(列幅 100 / 行高 40 の既定)。
    static func make(rows: Int, cols: Int, columnWidth: CGFloat = 100, rowHeight: CGFloat = 40) -> TablePayload {
        TablePayload(
            rowCount: rows, columnCount: cols,
            columnWidths: Array(repeating: columnWidth, count: cols),
            rowHeights: Array(repeating: rowHeight, count: rows),
            cells: []
        )
    }

    /// 表全体の外接サイズ(列幅合計 × 行高合計)。
    var totalSize: CGSize {
        CGSize(width: columnWidths.reduce(0, +), height: rowHeights.reduce(0, +))
    }

    /// (row, col) のセルテキスト(未設定は空文字)。
    func text(row: Int, col: Int) -> String {
        cells.first { $0.row == row && $0.col == col }?.text ?? ""
    }
}

extension CanvasObject {
    var objectKind: CanvasObjectKind {
        CanvasObjectKind(rawValue: kind ?? "") ?? .text
    }

    /// 移動・リサイズ・削除・投げ縄操作から保護されているか。
    /// システムロック(PDF背景など: 完全非対話)とユーザーロック(南京錠・解除可)の両方を含む。
    var isMovementLocked: Bool { isLocked || isUserLocked }

    /// コンテンツ空間(キャンバス座標)でのフレーム
    var contentFrame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.origin.x
            y = newValue.origin.y
            width = newValue.width
            height = newValue.height
        }
    }

    /// Todoリストの項目。payload に JSON で保存する(未設定は空配列)
    var todoItems: [TodoItem] {
        get { payload.flatMap { try? JSONDecoder().decode([TodoItem].self, from: $0) } ?? [] }
        set { payload = try? JSONEncoder().encode(newValue) }
    }

    /// 図形のパラメータ。payload に JSON で保存する(未設定は nil)
    var shapePayload: ShapePayload? {
        get { payload.flatMap { try? JSONDecoder().decode(ShapePayload.self, from: $0) } }
        set { payload = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// 表の構造。payload に JSON で保存する(未設定は nil)
    var tablePayload: TablePayload? {
        get { payload.flatMap { try? JSONDecoder().decode(TablePayload.self, from: $0) } }
        set { payload = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// 付箋のパラメータ。payload に JSON で保存する(未設定は nil)
    var stickyNotePayload: StickyNotePayload? {
        get { payload.flatMap { try? JSONDecoder().decode(StickyNotePayload.self, from: $0) } }
        set { payload = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// コネクタ線のパラメータ。payload に JSON で保存する(未設定は nil)
    var connectorPayload: ConnectorPayload? {
        get { payload.flatMap { try? JSONDecoder().decode(ConnectorPayload.self, from: $0) } }
        set { payload = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// ノートリンクの場合、リンク先の NoteFile を UUID から引く(ゴミ箱・削除済みは nil)
    var resolvedLinkedNote: NoteFile? {
        guard objectKind == .noteLink,
              let uuidString = linkedNoteUUID,
              let uuid = UUID(uuidString: uuidString),
              let context = managedObjectContext else { return nil }
        let request = NoteFile.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        guard let note = (try? context.fetch(request))?.first,
              !note.isTrashed, !note.isDeleted else { return nil }
        return note
    }

    /// サムネイル(ライブラリ一覧・ページマネージャー)へこのオブジェクトを簡易描画する。
    /// コンテキストは既にコンテンツ座標へスケール/平行移動済みである前提。
    func drawInThumbnail(pageColor: CanvasPageColor) {
        switch objectKind {
        case .text:
            ((text ?? "") as NSString).draw(
                in: contentFrame.insetBy(dx: 4, dy: 4),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: fontSize > 0 ? fontSize : 24),
                    .foregroundColor: pageColor.contentUIColor,
                ]
            )
        case .image, .pdf:
            makeDisplayImage()?.draw(in: contentFrame)
        case .todo:
            let path = UIBezierPath(roundedRect: contentFrame, cornerRadius: 10)
            UIColor.secondarySystemBackground.setFill()
            path.fill()
            let lines = todoItems.map { ($0.done ? "☑ " : "☐ ") + $0.text }.joined(separator: "\n")
            (lines as NSString).draw(
                in: contentFrame.insetBy(dx: 10, dy: 8),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 15),
                    .foregroundColor: pageColor.contentUIColor,
                ]
            )
        case .noteLink:
            let path = UIBezierPath(roundedRect: contentFrame, cornerRadius: 10)
            UIColor.secondarySystemBackground.setFill()
            path.fill()
            ((resolvedLinkedNote?.displayTitle ?? "ノート") as NSString).draw(
                in: contentFrame.insetBy(dx: 10, dy: 10),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                    .foregroundColor: pageColor.contentUIColor,
                ]
            )
        case .stickyNote:
            let color = stickyNotePayload?.color ?? .yellow
            let path = UIBezierPath(roundedRect: contentFrame, cornerRadius: 8)
            color.backgroundUIColor.setFill()
            path.fill()
            ((text ?? "") as NSString).draw(
                in: contentFrame.insetBy(dx: 8, dy: 8),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 15),
                    .foregroundColor: color.textUIColor,
                ]
            )
        case .connector:
            break  // コネクタは接続先の位置に依存するためサムネイルには描かない
        case .shape:
            guard let shape = shapePayload else { break }
            let lw = max(0.5, shape.lineWidth)
            let rect = contentFrame.insetBy(dx: lw / 2, dy: lw / 2)
            guard rect.width > 0, rect.height > 0 else { break }
            let path = shape.shapeType.path(in: rect)
            path.lineWidth = lw
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            if shape.shapeType.isFillable,
               let fill = UIColor(hex: shape.fillColor), fill.cgColor.alpha > 0 {
                fill.setFill()
                path.fill()
            }
            if let stroke = UIColor(hex: shape.strokeColor) {
                stroke.setStroke()
                path.stroke()
            }
        case .table:
            guard let table = tablePayload else { break }
            let origin = contentFrame.origin
            let total = table.totalSize
            let sx = total.width > 0 ? contentFrame.width / total.width : 1
            let sy = total.height > 0 ? contentFrame.height / total.height : 1
            // グリッド線
            UIColor.separator.setStroke()
            let grid = UIBezierPath()
            var x = origin.x
            grid.move(to: CGPoint(x: x, y: origin.y)); grid.addLine(to: CGPoint(x: x, y: origin.y + contentFrame.height))
            for w in table.columnWidths { x += w * sx; grid.move(to: CGPoint(x: x, y: origin.y)); grid.addLine(to: CGPoint(x: x, y: origin.y + contentFrame.height)) }
            var y = origin.y
            grid.move(to: CGPoint(x: origin.x, y: y)); grid.addLine(to: CGPoint(x: origin.x + contentFrame.width, y: y))
            for h in table.rowHeights { y += h * sy; grid.move(to: CGPoint(x: origin.x, y: y)); grid.addLine(to: CGPoint(x: origin.x + contentFrame.width, y: y)) }
            grid.lineWidth = 0.5
            grid.stroke()
            // セルテキスト
            var cy = origin.y
            for r in 0..<table.rowCount {
                let rh = (r < table.rowHeights.count ? table.rowHeights[r] : 40) * sy
                var cx = origin.x
                for c in 0..<table.columnCount {
                    let cw = (c < table.columnWidths.count ? table.columnWidths[c] : 100) * sx
                    let t = table.text(row: r, col: c)
                    if !t.isEmpty {
                        (t as NSString).draw(
                            in: CGRect(x: cx + 3, y: cy + 3, width: max(0, cw - 6), height: max(0, rh - 6)),
                            withAttributes: [
                                .font: UIFont.systemFont(ofSize: 12),
                                .foregroundColor: pageColor.contentUIColor,
                            ]
                        )
                    }
                    cx += cw
                }
                cy += rh
            }
        }
    }

    /// 表示用画像を生成する。image は payload をそのまま、pdf は1ページ目をレンダリング。
    /// 呼び出し側(Coordinator)でキャッシュすること。
    func makeDisplayImage() -> UIImage? {
        guard let payload else { return nil }
        switch objectKind {
        case .image:
            return UIImage(data: payload)
        case .pdf:
            guard let page = PDFDocument(data: payload)?.page(at: 0) else { return nil }
            // 高倍率ズームでも粗くならない程度の固定解像度でレンダリング
            let box = page.bounds(for: .mediaBox)
            let scale = 1024 / max(box.width, box.height)
            return page.thumbnail(
                of: CGSize(width: box.width * scale, height: box.height * scale),
                for: .mediaBox
            )
        case .text, .noteLink, .todo, .shape, .table, .stickyNote, .connector:
            return nil
        }
    }
}
