import CoreData

extension NoteFile {
    var displayTitle: String { title ?? "無題ノート" }

    /// 作成時に選んだ用紙の色(白 / 黒)
    var canvasPageColor: CanvasPageColor {
        CanvasPageColor(rawValue: pageColor ?? "") ?? .white
    }
}
