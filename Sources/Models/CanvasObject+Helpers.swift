import CoreData
import CoreGraphics

enum CanvasObjectType: String {
    case text, image, pdf
}

extension CanvasObject {
    var objectType: CanvasObjectType? {
        CanvasObjectType(rawValue: type ?? "")
    }

    /// コンテンツ座標系でのフレーム(x, y, width, height の複合アクセサ)
    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.minX
            y = newValue.minY
            width = newValue.width
            height = newValue.height
        }
    }
}
