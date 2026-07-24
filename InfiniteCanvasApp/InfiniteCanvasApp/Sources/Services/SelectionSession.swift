import CoreData
import CoreGraphics

/// 投げ縄で一括選択した「インク(PKDrawing のストロークのインデックス)」と
/// 「オブジェクト(CanvasObject の ID)」を1つのセッションとして束ねる。
/// ストロークには永続IDが無いため `strokeIndices` はセッション限定(次の描画変更で無効化)。
/// 幾何(合成バウンディングボックス)は `SelectionGeometry` を使い、インク・オブジェクトを
/// 同一のコンテンツ座標の矩形として一体に扱う。
struct SelectionSession {
    /// 選択中のストローク(`PKDrawing.strokes` のインデックス)。
    var strokeIndices: Set<Int> = []
    /// 選択中のオブジェクト。
    var objectIDs: Set<NSManagedObjectID> = []

    var isEmpty: Bool { strokeIndices.isEmpty && objectIDs.isEmpty }

    /// インク(ストローク)とオブジェクトの矩形をまとめた合成バウンディングボックス。
    /// どちらも空なら nil。
    static func combinedBoundingBox(strokeBounds: [CGRect], objectFrames: [CGRect]) -> CGRect? {
        SelectionGeometry.boundingBox(of: strokeBounds + objectFrames)
    }
}
