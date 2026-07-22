import Testing
import UIKit
@testable import InfiniteCanvasApp

// MARK: - 図形 payload と Hex カラー変換

@Suite("ShapePayload / UIColor(hex:)")
struct ShapePayloadTests {

    @Test("ShapePayload は JSON で往復できる")
    func shapePayloadRoundTrips() throws {
        let original = ShapePayload(
            shapeType: .star, strokeColor: "#112233FF", fillColor: "#00000000", lineWidth: 3.5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShapePayload.self, from: data)
        #expect(decoded == original)
    }

    @Test("全 ShapeType が payload に保存・復元できる")
    func allShapeTypesRoundTrip() throws {
        for type in ShapeType.allCases {
            let payload = ShapePayload(
                shapeType: type, strokeColor: "#000000FF", fillColor: "#FF000080", lineWidth: 2
            )
            let data = try JSONEncoder().encode(payload)
            let decoded = try JSONDecoder().decode(ShapePayload.self, from: data)
            #expect(decoded.shapeType == type)
        }
    }

    @Test("#RRGGBB を不透明色として解釈する")
    func hexRGBParses() throws {
        let color = try #require(UIColor(hex: "#FF0000"))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(r - 1) < 0.01)
        #expect(abs(g) < 0.01)
        #expect(abs(b) < 0.01)
        #expect(abs(a - 1) < 0.01)
    }

    @Test("#RRGGBBAA のアルファを解釈する(透明塗り)")
    func hexRGBAAlphaParses() throws {
        let transparent = try #require(UIColor(hex: "#00000000"))
        #expect(transparent.cgColor.alpha < 0.01)
    }

    @Test("先頭の # は省略できる")
    func hexWithoutHashParses() {
        #expect(UIColor(hex: "0000FF") != nil)
    }

    @Test("不正な Hex は nil を返す")
    func invalidHexReturnsNil() {
        #expect(UIColor(hex: "#XYZ") == nil)
        #expect(UIColor(hex: "12345") == nil)  // 6/8桁でない
    }

    @Test("hexStringRGBA は UIColor(hex:) と往復する")
    func hexStringRoundTrips() throws {
        let source = try #require(UIColor(hex: "#3A7BD5C0"))
        let restored = try #require(UIColor(hex: source.hexStringRGBA))
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        source.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        restored.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        #expect(abs(r1 - r2) < 0.02)
        #expect(abs(g1 - g2) < 0.02)
        #expect(abs(b1 - b2) < 0.02)
        #expect(abs(a1 - a2) < 0.02)
    }
}
