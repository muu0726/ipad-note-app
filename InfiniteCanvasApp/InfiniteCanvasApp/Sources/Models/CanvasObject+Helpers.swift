import CoreData
import UIKit
import PDFKit

/// キャンバス上に配置できるオブジェクトの種類(要件③)
enum CanvasObjectKind: String {
    case text, image, pdf
}

extension CanvasObject {
    var objectKind: CanvasObjectKind {
        CanvasObjectKind(rawValue: kind ?? "") ?? .text
    }

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
        case .text:
            return nil
        }
    }
}
