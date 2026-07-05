import CoreGraphics

/// スナップ時に表示するガイド線(コンテンツ空間)
struct SnapGuide: Equatable {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    /// vertical なら x 座標、horizontal なら y 座標
    let position: CGFloat
}

struct SnapResult {
    var frame: CGRect
    var guides: [SnapGuide]
}

/// オブジェクト移動時の吸着計算(要件④)。
/// 他オブジェクトの端・中心、および背景グリッド(40pt)へ吸着する。
/// すべてコンテンツ空間で計算し、しきい値は呼び出し側でズームを考慮して渡す。
enum SnapEngine {
    static let gridSpacing: CGFloat = 40

    static func snap(
        moving frame: CGRect,
        others: [CGRect],
        snapToGrid: Bool,
        threshold: CGFloat
    ) -> SnapResult {
        var guides: [SnapGuide] = []
        var result = frame

        // X軸: 自分の [minX, midX, maxX] を他オブジェクトの同3点と突き合わせ、
        // しきい値内で最も近いものへ吸着する
        let (dx, guideX) = bestDelta(
            own: [frame.minX, frame.midX, frame.maxX],
            targets: others.flatMap { [$0.minX, $0.midX, $0.maxX] },
            snapToGrid: snapToGrid,
            threshold: threshold
        )
        if let dx {
            result.origin.x += dx
            if let guideX { guides.append(SnapGuide(axis: .vertical, position: guideX)) }
        }

        let (dy, guideY) = bestDelta(
            own: [frame.minY, frame.midY, frame.maxY],
            targets: others.flatMap { [$0.minY, $0.midY, $0.maxY] },
            snapToGrid: snapToGrid,
            threshold: threshold
        )
        if let dy {
            result.origin.y += dy
            if let guideY { guides.append(SnapGuide(axis: .horizontal, position: guideY)) }
        }

        return SnapResult(frame: result, guides: guides)
    }

    /// 吸着すべき最小の移動量と、ガイド線位置(グリッド吸着時はガイドを出さないので nil)を返す
    private static func bestDelta(
        own: [CGFloat],
        targets: [CGFloat],
        snapToGrid: Bool,
        threshold: CGFloat
    ) -> (delta: CGFloat?, guide: CGFloat?) {
        var best: (delta: CGFloat, guide: CGFloat?)?

        for o in own {
            // 他オブジェクトへの吸着(ガイド線あり)
            for t in targets {
                let d = t - o
                if abs(d) <= threshold, abs(d) < abs(best?.delta ?? .infinity) {
                    best = (d, t)
                }
            }
            // グリッド線への吸着(ガイド線なし。オブジェクト優先なので僅かに不利にする)
            if snapToGrid {
                let nearest = (o / gridSpacing).rounded() * gridSpacing
                let d = nearest - o
                if abs(d) <= threshold * 0.75, abs(d) < abs(best?.delta ?? .infinity) {
                    best = (d, nil)
                }
            }
        }
        return (best?.delta, best?.guide)
    }
}
