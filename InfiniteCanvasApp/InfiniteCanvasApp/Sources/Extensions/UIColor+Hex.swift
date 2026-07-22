import UIKit

/// 図形オブジェクトの線/塗り色や CustomPen の色を文字列(Hex)で永続化するための変換。
/// 既存コードは system 定数中心で hex 変換が無かったため新設(要件: 図形/カスタムペン)。
extension UIColor {
    /// `#RRGGBB` / `#RRGGBBAA`(先頭 `#` は省略可)から色を生成する。
    /// アルファ省略時は不透明。塗りつぶし「透明」は `#RRGGBB00`(アルファ 0)で表す。
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8,
              let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value & 0xFF00_0000) >> 24) / 255
            g = CGFloat((value & 0x00FF_0000) >> 16) / 255
            b = CGFloat((value & 0x0000_FF00) >> 8) / 255
            a = CGFloat(value & 0x0000_00FF) / 255
        } else {
            r = CGFloat((value & 0xFF0000) >> 16) / 255
            g = CGFloat((value & 0x00FF00) >> 8) / 255
            b = CGFloat(value & 0x0000FF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    /// `#RRGGBBAA` 形式へ変換する(アルファ込みで往復できる)。
    var hexStringRGBA: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // sRGB へ変換してから読み出す(system 動的色でも安定した値を得る)
        let resolved = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000FF" }
        let clamp: (CGFloat) -> Int = { Int((max(0, min(1, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", clamp(r), clamp(g), clamp(b), clamp(a))
    }
}
