import CoreData

/// ノートの形式。無限キャンバス or 固定サイズページが縦に並ぶ通常ノート。
enum CanvasNoteType: String, CaseIterable {
    case infinite   // 無限キャンバス
    case paged      // 通常ノート(A4 固定ページ)

    var label: String {
        switch self {
        case .infinite: "無限キャンバス"
        case .paged: "通常ノート"
        }
    }
}

extension NoteFile {
    var displayTitle: String { title ?? "無題ノート" }

    /// 作成時に選んだ用紙の色(白 / 黒)
    var canvasPageColor: CanvasPageColor {
        CanvasPageColor(rawValue: pageColor ?? "") ?? .white
    }

    /// ノート形式。既存ノート(未設定)は無限キャンバス扱い
    var canvasNoteType: CanvasNoteType {
        CanvasNoteType(rawValue: noteType ?? "") ?? .infinite
    }

    /// ページ数(通常ノート用)。最低1ページを保証する
    var resolvedPageCount: Int {
        max(1, Int(pageCount))
    }
}
