import UIKit
import CoreData

/// オブジェクトレイヤーへ渡す表示用スナップショット(zOrder 昇順で渡す)
struct CanvasObjectItem {
    let id: NSManagedObjectID
    let kind: CanvasObjectKind
    var frame: CGRect        // コンテンツ空間
    var text: String
    var fontSize: CGFloat
    var image: UIImage?      // image / pdf のレンダリング済み画像(Coordinator がキャッシュ)
}

/// テキスト / 画像 / PDF オブジェクトの表示・選択・移動・リサイズを担うレイヤー(要件③④)。
/// 背景パターンと同じくスクリーン空間のビューで、contentOffset / zoomScale に追従する。
/// PKCanvasView の下(背景の上)に置かれるため、インクは常にオブジェクトの上に描かれる。
/// タッチは選択モード時のみ CanvasContainerUIView.hitTest から転送される。
final class ObjectLayerUIView: UIView {
    // Core Data への書き戻しは Coordinator 経由で行う
    var onFrameChanged: ((NSManagedObjectID, CGRect) -> Void)?
    var onTextChanged: ((NSManagedObjectID, String) -> Void)?
    var onDelete: ((NSManagedObjectID) -> Void)?

    /// 現在のズーム倍率。オブジェクトはコンテンツ空間に直接配置され、スクロール/ズーム追従は
    /// スクロールビュー(PKCanvasView)の合成に任せるため、この値はスナップ閾値・タッチ判定の
    /// 「スクリーン上の見かけの距離」を保つためだけに使う(ズーム時のみ更新)。
    private(set) var zoom: CGFloat = 1
    private(set) var selectedID: NSManagedObjectID?
    private var objectViews: [NSManagedObjectID: CanvasObjectUIView] = [:]
    private let guideLayer = CAShapeLayer()

    /// グリッドスナップの有効判定に使う(白紙のときはグリッドへ吸着しない)
    var backgroundStyle: CanvasBackgroundStyle = .blank

    /// 用紙色(テキストオブジェクトの文字色に反映)
    var pageColor: CanvasPageColor = .white {
        didSet {
            guard pageColor != oldValue else { return }
            for view in objectViews.values { view.updatePageColor(pageColor) }
        }
    }

    var isSelectMode = false {
        didSet { if !isSelectMode { select(nil) } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        guideLayer.strokeColor = UIColor.systemOrange.cgColor
        guideLayer.lineWidth = 1
        guideLayer.fillColor = nil
        layer.addSublayer(guideLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - ビューポート追従

    /// ズーム変更時のみ呼ばれ、スナップ閾値やタッチ判定の倍率を更新する。
    /// スクロール・ズームによるオブジェクトの再配置はスクロールビューの合成が行うため不要。
    func applyZoom(_ zoom: CGFloat) {
        self.zoom = zoom
    }

    // MARK: - モデル同期

    func sync(items: [CanvasObjectItem]) {
        let ids = Set(items.map(\.id))
        for (id, view) in objectViews where !ids.contains(id) {
            view.removeFromSuperview()
            objectViews[id] = nil
            if selectedID == id { selectedID = nil }
        }
        for item in items {
            let view: CanvasObjectUIView
            if let existing = objectViews[item.id] {
                view = existing
            } else {
                view = CanvasObjectUIView(item: item, layerView: self)
                objectViews[item.id] = view
                addSubview(view)
                view.updatePageColor(pageColor)
            }
            view.apply(item)
            bringSubviewToFront(view)  // items は zOrder 昇順なので前面順が保たれる
        }
    }

    // MARK: - 選択

    func select(_ id: NSManagedObjectID?) {
        guard selectedID != id else { return }
        if let old = selectedID { objectViews[old]?.setSelected(false) }
        selectedID = id
        if let id { objectViews[id]?.setSelected(true) }
    }

    /// 挿入直後のフォーカス。テキストならそのまま編集を開始する
    func focus(on id: NSManagedObjectID) {
        select(id)
        objectViews[id]?.beginTextEditing()
    }

    /// 選択モード中、オブジェクトのない場所のタップで選択解除(コンテナから呼ばれる)
    func handleBackgroundTap(at point: CGPoint) {
        guard isSelectMode else { return }
        let hit = hitTest(point, with: nil)
        if hit == nil || hit === self { select(nil) }
    }

    // MARK: - スナップ(要件④)

    func snapResult(moving frame: CGRect, excluding id: NSManagedObjectID) -> SnapResult {
        let others = objectViews.filter { $0.key != id }.map(\.value.contentFrame)
        return SnapEngine.snap(
            moving: frame,
            others: others,
            snapToGrid: backgroundStyle != .blank,
            threshold: 8 / zoom  // スクリーン上で常に約8ptの吸着距離
        )
    }

    func showGuides(_ guides: [SnapGuide]) {
        guard !guides.isEmpty else {
            guideLayer.path = nil
            return
        }
        // ガイドもコンテンツ空間。ビューはコンテンツ全体サイズなので端から端まで引く
        // (可視範囲外はスクロールビューがクリップする)。線幅はズームで見かけが変わらないよう補正
        let path = UIBezierPath()
        for guide in guides {
            switch guide.axis {
            case .vertical:
                path.move(to: CGPoint(x: guide.position, y: 0))
                path.addLine(to: CGPoint(x: guide.position, y: bounds.height))
            case .horizontal:
                path.move(to: CGPoint(x: 0, y: guide.position))
                path.addLine(to: CGPoint(x: bounds.width, y: guide.position))
            }
        }
        guideLayer.lineWidth = 1 / max(zoom, 0.01)
        guideLayer.path = path.cgPath
    }
}

/// 1つのオブジェクトを表すビュー。移動・リサイズ・長押し削除・テキスト編集のジェスチャを持つ。
final class CanvasObjectUIView: UIView, UITextViewDelegate, UIEditMenuInteractionDelegate {
    let objectID: NSManagedObjectID
    let kind: CanvasObjectKind
    private(set) var contentFrame: CGRect  // コンテンツ空間
    private(set) var isInteracting = false

    private weak var layerView: ObjectLayerUIView?
    private var fontSize: CGFloat
    private var isSelected = false
    private var gestureStartFrame: CGRect = .zero

    private let imageView = UIImageView()
    private let textView = UITextView()
    private let resizeHandle = UIView()
    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)

    init(item: CanvasObjectItem, layerView: ObjectLayerUIView) {
        self.objectID = item.id
        self.kind = item.kind
        self.contentFrame = item.frame
        self.fontSize = item.fontSize
        self.layerView = layerView
        super.init(frame: .zero)

        layer.borderColor = UIColor.systemBlue.cgColor

        switch kind {
        case .text:
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear
            textView.textColor = .label
            textView.isEditable = false
            textView.isUserInteractionEnabled = false  // 編集開始まで自分がタッチを受ける
            textView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            textView.delegate = self
            addSubview(textView)
        case .image, .pdf:
            imageView.contentMode = .scaleToFill  // アスペクト比はフレーム側で維持する
            imageView.clipsToBounds = true
            addSubview(imageView)
        }

        // 選択チップ: リサイズハンドル(右下)。角に半分かかる配置
        resizeHandle.backgroundColor = .systemBackground
        resizeHandle.layer.cornerRadius = 11
        resizeHandle.layer.borderWidth = 2
        resizeHandle.layer.borderColor = UIColor.systemBlue.cgColor
        resizeHandle.isHidden = true
        addSubview(resizeHandle)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        let movePan = UIPanGestureRecognizer(target: self, action: #selector(handleMovePan(_:)))
        movePan.maximumNumberOfTouches = 1
        addGestureRecognizer(movePan)
        resizeHandle.addGestureRecognizer(
            UIPanGestureRecognizer(target: self, action: #selector(handleResizePan(_:)))
        )

        // 長押しで削除メニューを出す(要件: 画像等のオブジェクトは長押しで消す)
        addInteraction(editMenuInteraction)
        addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        textView.frame = bounds
        resizeHandle.frame = CGRect(x: bounds.width - 11, y: bounds.height - 11, width: 22, height: 22)
    }

    /// 角に半分はみ出した削除ボタン/ハンドルも押せるよう当たり判定を広げる。
    /// コンテンツ空間なので、スクリーン上で概ね一定(約16pt)になるようズームで補正する。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let margin = 16 / max(layerView?.zoom ?? 1, 0.01)
        return bounds.insetBy(dx: -margin, dy: -margin).contains(point)
    }

    // MARK: - モデル反映

    func apply(_ item: CanvasObjectItem) {
        guard !isInteracting else { return }
        contentFrame = item.frame
        fontSize = item.fontSize
        if kind == .text, !textView.isFirstResponder, textView.text != item.text {
            textView.text = item.text
        }
        if let image = item.image { imageView.image = image }
        applyPlacement()
    }

    /// コンテンツ空間へ直接配置する。スクロール/ズームへの追従はスクロールビューの合成が行う
    /// ため、オフセットやズームの計算は不要(= スクロール中の再配置コストがゼロ)。
    func applyPlacement() {
        frame = contentFrame
        if kind == .text {
            textView.font = .systemFont(ofSize: fontSize)
        }
        setNeedsLayout()
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        layer.borderWidth = selected ? 2 : 0
        resizeHandle.isHidden = !selected
        if !selected { endTextEditing() }
    }

    /// 用紙色に合わせてテキストの文字色を切り替える(黒紙では白文字)
    func updatePageColor(_ pageColor: CanvasPageColor) {
        guard kind == .text else { return }
        textView.textColor = pageColor.contentUIColor
    }

    // MARK: - テキスト編集

    func beginTextEditing() {
        guard kind == .text else { return }
        textView.isEditable = true
        textView.isUserInteractionEnabled = true
        textView.becomeFirstResponder()
    }

    private func endTextEditing() {
        guard kind == .text, textView.isFirstResponder else { return }
        textView.resignFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        // 入力に合わせて高さを自動拡張。テキストはコンテンツ空間のフォントサイズなので
        // sizeThatFits の結果はそのままコンテンツ空間の高さになる(ズーム換算は不要)
        let fitting = textView.sizeThatFits(
            CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        )
        let newHeight = max(40, fitting.height)
        if abs(newHeight - contentFrame.height) > 0.5 {
            contentFrame.size.height = newHeight
            applyPlacement()
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        textView.isEditable = false
        textView.isUserInteractionEnabled = false
        layerView?.onTextChanged?(objectID, textView.text ?? "")
        layerView?.onFrameChanged?(objectID, contentFrame)  // 自動拡張した高さを保存
    }

    // MARK: - ジェスチャ

    @objc private func handleTap() {
        guard let layerView, layerView.isSelectMode else { return }
        if layerView.selectedID != objectID {
            layerView.select(objectID)
        } else if kind == .text {
            beginTextEditing()  // 選択済みのテキストを再タップで編集開始
        }
    }

    @objc private func handleMovePan(_ gesture: UIPanGestureRecognizer) {
        guard let layerView, layerView.isSelectMode else { return }
        switch gesture.state {
        case .began:
            layerView.select(objectID)
            endTextEditing()
            isInteracting = true
            gestureStartFrame = contentFrame
        case .changed:
            // layerView はコンテンツ空間(ズームで拡縮される)なので、そこで測った
            // translation はコンテンツ空間の移動量そのもの(ズーム除算は不要)
            let t = gesture.translation(in: layerView)
            let proposed = gestureStartFrame.offsetBy(dx: t.x, dy: t.y)
            let result = layerView.snapResult(moving: proposed, excluding: objectID)
            contentFrame = result.frame
            layerView.showGuides(result.guides)
            applyPlacement()
        case .ended, .cancelled, .failed:
            isInteracting = false
            layerView.showGuides([])
            layerView.onFrameChanged?(objectID, contentFrame)
        default:
            break
        }
    }

    @objc private func handleResizePan(_ gesture: UIPanGestureRecognizer) {
        guard let layerView, layerView.isSelectMode else { return }
        switch gesture.state {
        case .began:
            isInteracting = true
            gestureStartFrame = contentFrame
        case .changed:
            let t = gesture.translation(in: layerView)
            var newWidth = gestureStartFrame.width + t.x
            var newHeight = gestureStartFrame.height + t.y
            if kind == .text {
                newWidth = max(60, newWidth)
                newHeight = max(40, newHeight)
            } else {
                // 画像 / PDF はアスペクト比を維持
                let ratio = gestureStartFrame.height / max(gestureStartFrame.width, 1)
                newWidth = max(40, newWidth)
                newHeight = newWidth * ratio
            }
            contentFrame.size = CGSize(width: newWidth, height: newHeight)
            applyPlacement()
        case .ended, .cancelled, .failed:
            isInteracting = false
            layerView.onFrameChanged?(objectID, contentFrame)
        default:
            break
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let layerView, layerView.isSelectMode else { return }
        layerView.select(objectID)
        endTextEditing()
        let config = UIEditMenuConfiguration(
            identifier: nil,
            sourcePoint: gesture.location(in: self)
        )
        editMenuInteraction.presentEditMenu(with: config)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        UIMenu(children: [
            UIAction(title: "削除", image: UIImage(systemName: "trash"), attributes: .destructive) {
                [weak self] _ in
                guard let self else { return }
                self.layerView?.onDelete?(self.objectID)
            }
        ])
    }
}
