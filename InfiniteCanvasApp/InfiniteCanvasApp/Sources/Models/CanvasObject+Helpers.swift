import CoreData
import UIKit
import PDFKit

/// キャンバス上に配置できるオブジェクトの種類(要件③)
enum CanvasObjectKind: String {
    case text, image, pdf
    case noteLink  // 他のノートへのショートカット(カード型UI)
    case todo      // チェックリスト(タスク管理)
}

/// Todoリストの1項目。payload に [TodoItem] を JSON で保存する。
struct TodoItem: Codable, Equatable {
    var text: String
    var done: Bool
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
        case .text, .noteLink, .todo:
            return nil
        }
    }
}
