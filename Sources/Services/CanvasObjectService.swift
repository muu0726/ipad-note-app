import CoreData
import UIKit
import PencilKit

/// キャンバス上のオブジェクト(テキスト / 画像 / PDF)の作成・ストローク追従を担うサービス。
enum CanvasObjectService {

    // MARK: - 作成

    @discardableResult
    static func createText(in note: NoteFile, at center: CGPoint, context: NSManagedObjectContext) -> CanvasObject {
        let frame = CGRect(x: center.x - 120, y: center.y - 32, width: 240, height: 64)
        let object = make(type: .text, frame: frame, note: note, context: context)
        object.textContent = ""
        save(context)
        return object
    }

    @discardableResult
    static func createImage(_ image: UIImage, in note: NoteFile, at center: CGPoint, context: NSManagedObjectContext) -> CanvasObject {
        let maxDimension: CGFloat = 320
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let frame = CGRect(
            origin: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            size: size)
        let object = make(type: .image, frame: frame, note: note, context: context)
        object.content = downscaledJPEGData(from: image)
        save(context)
        return object
    }

    @discardableResult
    static func createPDF(data: Data, in note: NoteFile, at center: CGPoint, context: NSManagedObjectContext) -> CanvasObject {
        let frame = CGRect(x: center.x - 200, y: center.y - 260, width: 400, height: 520)
        let object = make(type: .pdf, frame: frame, note: note, context: context)
        object.content = data
        save(context)
        return object
    }

    // MARK: - 単一レイヤー要件(要件③)

    /// オブジェクト移動時、旧フレーム内に書かれたストロークを一緒に平行移動する。
    /// (画像の上に書いた手書き文字が、画像の移動に追従する)
    static func translateStrokes(in drawing: PKDrawing, within rect: CGRect, by delta: CGPoint) -> (drawing: PKDrawing, didMove: Bool) {
        guard delta != .zero else { return (drawing, false) }
        var didMove = false
        var strokes = drawing.strokes
        for index in strokes.indices {
            let bounds = strokes[index].renderBounds
            if rect.contains(CGPoint(x: bounds.midX, y: bounds.midY)) {
                strokes[index].transform = strokes[index].transform
                    .concatenating(CGAffineTransform(translationX: delta.x, y: delta.y))
                didMove = true
            }
        }
        return didMove ? (PKDrawing(strokes: strokes), true) : (drawing, false)
    }

    // MARK: - private

    private static func make(type: CanvasObjectType, frame: CGRect, note: NoteFile, context: NSManagedObjectContext) -> CanvasObject {
        let object = CanvasObject(context: context)
        object.id = UUID()
        object.type = type.rawValue
        object.frame = frame
        object.createdAt = .now
        object.updatedAt = .now
        object.sortOrder = nextSortOrder(for: note)
        object.note = note
        return object
    }

    private static func nextSortOrder(for note: NoteFile) -> Int64 {
        let existing = (note.objects as? Set<CanvasObject>) ?? []
        return (existing.map(\.sortOrder).max() ?? 0) + 1
    }

    /// 保存容量を抑えるため長辺 2048px に縮小して JPEG 化
    private static func downscaledJPEGData(from image: UIImage) -> Data? {
        let maxPixels: CGFloat = 2048
        let scale = min(1, maxPixels / max(image.size.width, image.size.height))
        if scale >= 1 { return image.jpegData(compressionQuality: 0.85) }
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }

    private static func save(_ context: NSManagedObjectContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            assertionFailure("オブジェクトの保存に失敗: \(error)")
        }
    }
}
