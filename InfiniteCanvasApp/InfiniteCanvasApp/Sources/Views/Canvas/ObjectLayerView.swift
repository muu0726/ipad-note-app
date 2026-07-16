import UIKit
import CoreData

/// ノートリンクカードの「開く」ボタン。非選択モードでもこのボタンだけはタッチを通すため、
/// ObjectAccessibleCanvasView.hitTest / 描画ジェスチャのゲートが型で識別できるよう専用クラスにする。
final class NoteLinkOpenButton: UIButton {}

/// オブジェクトレイヤーへ渡す表示用スナップショット(zOrder 昇順で渡す)
struct CanvasObjectItem {
    let id: NSManagedObjectID
    let kind: CanvasObjectKind
    var frame: CGRect        // コンテンツ空間
    var text: String
    var fontSize: CGFloat
    var image: UIImage?      // image / pdf のレンダリング済み画像(noteLink ではサムネイル)
    var isLocked: Bool = false  // PDF 背景など: 移動・リサイズ・削除・選択を禁止
    var linkTitle: String = ""  // noteLink: リンク先ノートのタイトル
    var todoItems: [TodoItem] = []  // todo: チェックリストの項目
}

/// テキスト / 画像 / PDF オブジェクトの表示・選択・移動・リサイズを担うレイヤー(要件③④)。
/// 背景パターンと同じくスクリーン空間のビューで、contentOffset / zoomScale に追従する。
/// PKCanvasView の下(背景の上)に置かれるため、インクは常にオブジェクトの上に描かれる。
/// タッチは選択モード時のみ CanvasContainerUIView.hitTest から転送される。
final class ObjectLayerUIView: UIView {
    // Core Data への書き戻しは Coordinator 経由で行う
    var onFrameChanged: ((NSManagedObjectID, CGRect) -> Void)?
    var onTextChanged: ((NSManagedObjectID, String) -> Void)?
    /// Todoリストの項目が変わったときの書き戻し
    var onTodoChanged: ((NSManagedObjectID, [TodoItem]) -> Void)?
    var onDelete: ((NSManagedObjectID) -> Void)?
    /// フォントサイズ変更時の高さ自動調整を Undo 無しで保存するための書き戻し
    var onAutoHeightChanged: ((NSManagedObjectID, CGFloat) -> Void)?
    /// 選択が変わったときに「選択中テキストの (id, fontSize)」を通知(テキスト以外や未選択は nil)
    var onTextSelectionChanged: (((objectID: NSManagedObjectID, fontSize: CGFloat)?) -> Void)?
    /// 何か選択中(true)か未選択(false)かの変化を通知。選択モードの真実のソースになる。
    var onSelectionChanged: ((Bool) -> Void)?
    /// ノートリンクのダブルタップでリンク先へジャンプする要求
    var onNoteLinkActivated: ((NSManagedObjectID) -> Void)?

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
        let hadSelection = selectedID != nil
        if let old = selectedID { objectViews[old]?.setSelected(false) }
        selectedID = id
        if let id { objectViews[id]?.setSelected(true) }
        notifyTextSelection()
        // 選択の有無が切り替わったときだけ選択モードの ON/OFF を伝える
        if (id != nil) != hadSelection {
            onSelectionChanged?(id != nil)
        }
    }

    /// 選択中テキストのフォントサイズ等が変わったときにツールバー表示を更新する(Undo/Redo 追従)
    func refreshSelectionInfo() {
        notifyTextSelection()
    }

    /// 選択中がテキストなら (id, fontSize) を、そうでなければ nil をツールバーへ通知
    private func notifyTextSelection() {
        if let id = selectedID, let view = objectViews[id], view.kind == .text {
            onTextSelectionChanged?((objectID: id, fontSize: view.currentFontSize))
        } else {
            onTextSelectionChanged?(nil)
        }
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
final class CanvasObjectUIView: UIView, UITextViewDelegate, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    let objectID: NSManagedObjectID
    let kind: CanvasObjectKind
    let isLocked: Bool
    private(set) var contentFrame: CGRect  // コンテンツ空間
    private(set) var isInteracting = false

    private weak var layerView: ObjectLayerUIView?
    private var fontSize: CGFloat
    private var isSelected = false
    private var gestureStartFrame: CGRect = .zero
    /// 移動用パン。選択済みのときだけ開始させる判定(gestureRecognizerShouldBegin)に使う
    private weak var movePan: UIPanGestureRecognizer?

    private let imageView = UIImageView()
    private let textView = UITextView()
    private let todoListView = TodoListView()
    private let resizeHandle = UIView()
    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)

    // ノートリンク用カードUI
    private let linkCard = UIView()
    private let linkIcon = UIImageView()
    private let linkTitleLabel = UILabel()
    private let linkThumb = UIImageView()
    /// カード右上の「開く」ボタン。選択モードでなくてもリンク先へ飛べるようにする専用の当たり判定。
    private let linkOpenButton = NoteLinkOpenButton(type: .system)

    init(item: CanvasObjectItem, layerView: ObjectLayerUIView) {
        self.objectID = item.id
        self.kind = item.kind
        self.isLocked = item.isLocked
        self.contentFrame = item.frame
        self.fontSize = item.fontSize
        self.layerView = layerView
        super.init(frame: .zero)
        // ロック(PDF背景など)は移動・リサイズ・選択・削除・編集を一切受け付けない
        isUserInteractionEnabled = !item.isLocked

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
        case .noteLink:
            setUpLinkCard()
        case .todo:
            todoListView.onItemsChanged = { [weak self] items in
                guard let self else { return }
                self.layerView?.onTodoChanged?(self.objectID, items)
            }
            // 行の増減でカードの高さを内容に追従させる(Undo なしで保存)
            todoListView.onHeightChanged = { [weak self] height in
                guard let self, !self.isInteracting else { return }
                guard abs(height - self.contentFrame.height) > 0.5 else { return }
                self.contentFrame.size.height = height
                self.applyPlacement()
                self.layerView?.onAutoHeightChanged?(self.objectID, height)
            }
            addSubview(todoListView)
        }

        // 選択チップ: リサイズハンドル(右下)。角に半分かかる配置
        resizeHandle.backgroundColor = .systemBackground
        resizeHandle.layer.cornerRadius = 11
        resizeHandle.layer.borderWidth = 2
        resizeHandle.layer.borderColor = UIColor.systemBlue.cgColor
        resizeHandle.isHidden = true
        addSubview(resizeHandle)

        // オブジェクト操作(選択・移動・リサイズ・長押し・リンクジャンプ)はすべて「指」で行う。
        // Apple Pencil のタッチはこれらを起動せず、祖先の PKCanvasView が描画として受け取る。
        let fingerOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self  // Todo の行内コントロールへのタップは横取りしない
        tap.allowedTouchTypes = fingerOnly
        addGestureRecognizer(tap)
        let movePan = UIPanGestureRecognizer(target: self, action: #selector(handleMovePan(_:)))
        movePan.maximumNumberOfTouches = 1
        movePan.allowedTouchTypes = fingerOnly
        // 移動パンは「選択済みのオブジェクト」でのみ開始する(gestureRecognizerShouldBegin)。
        // 未選択オブジェクト上の指ドラッグはパンを開始させず、スクロールへ委ねる(選択してから移動)。
        movePan.delegate = self
        self.movePan = movePan
        addGestureRecognizer(movePan)
        let resizePan = UIPanGestureRecognizer(target: self, action: #selector(handleResizePan(_:)))
        resizePan.allowedTouchTypes = fingerOnly
        resizeHandle.addGestureRecognizer(resizePan)

        // 長押しで削除メニューを出す(要件: 画像等のオブジェクトは長押しで消す)
        addInteraction(editMenuInteraction)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.allowedTouchTypes = fingerOnly
        addGestureRecognizer(longPress)

        // ノートリンクはダブルタップでリンク先へジャンプ
        if kind == .noteLink {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleNoteLinkJump))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.allowedTouchTypes = fingerOnly
            addGestureRecognizer(doubleTap)
        }
    }

    /// ノートリンクのカードUIを構築する(角丸・影・境界線・アイコン+タイトル+サムネイル)
    private func setUpLinkCard() {
        linkCard.backgroundColor = .secondarySystemBackground
        linkCard.layer.cornerRadius = 12
        linkCard.layer.borderWidth = 0.5
        linkCard.layer.borderColor = UIColor.separator.cgColor
        linkCard.layer.shadowColor = UIColor.black.cgColor
        linkCard.layer.shadowOpacity = 0.12
        linkCard.layer.shadowRadius = 4
        linkCard.layer.shadowOffset = CGSize(width: 0, height: 2)
        linkCard.isUserInteractionEnabled = false
        addSubview(linkCard)

        linkThumb.contentMode = .scaleAspectFill
        linkThumb.clipsToBounds = true
        linkThumb.layer.cornerRadius = 8
        linkThumb.backgroundColor = .tertiarySystemFill
        linkCard.addSubview(linkThumb)

        linkIcon.image = UIImage(systemName: "doc.text.fill")
        linkIcon.tintColor = .systemBlue
        linkIcon.contentMode = .scaleAspectFit
        linkCard.addSubview(linkIcon)

        linkTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        linkTitleLabel.textColor = .label
        linkTitleLabel.numberOfLines = 2
        linkCard.addSubview(linkTitleLabel)

        // 「開く」ボタンは linkCard(タッチ無効)ではなく self に載せ、どのツールでも押せるようにする。
        // 非選択モードでのタッチ転送は ObjectAccessibleCanvasView.hitTest が担う。
        linkOpenButton.setImage(UIImage(systemName: "arrow.up.forward.circle.fill"), for: .normal)
        linkOpenButton.tintColor = .systemBlue
        linkOpenButton.accessibilityIdentifier = "notelink-open"
        linkOpenButton.accessibilityLabel = "リンク先を開く"
        linkOpenButton.addTarget(self, action: #selector(handleOpenButtonTap), for: .touchUpInside)
        addSubview(linkOpenButton)
    }

    /// 「開く」ボタン: 選択モードを問わずリンク先へジャンプする(ダブルタップと違い単タップ)。
    @objc private func handleOpenButtonTap() {
        guard kind == .noteLink else { return }
        layerView?.onNoteLinkActivated?(objectID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        textView.frame = bounds
        todoListView.frame = bounds
        resizeHandle.frame = CGRect(x: bounds.width - 11, y: bounds.height - 11, width: 22, height: 22)

        if kind == .noteLink {
            linkCard.frame = bounds
            linkCard.layer.shadowPath = UIBezierPath(
                roundedRect: linkCard.bounds, cornerRadius: linkCard.layer.cornerRadius
            ).cgPath
            let inset: CGFloat = 12
            // 右上に「開く」ボタンを配置し、タイトルはその分だけ手前で折り返す
            let openSide: CGFloat = 28
            linkOpenButton.frame = CGRect(x: bounds.width - openSide - 8, y: 8, width: openSide, height: openSide)
            let titleTrailing = bounds.width - (openSide + 8) - 6  // ボタン左端の少し手前まで
            let hasThumb = linkThumb.image != nil
            if hasThumb {
                let side = bounds.height - inset * 2
                linkThumb.frame = CGRect(x: inset, y: inset, width: side, height: side)
                linkThumb.isHidden = false
                linkIcon.isHidden = true
                let textX = linkThumb.frame.maxX + 12
                linkTitleLabel.frame = CGRect(x: textX, y: inset, width: max(0, titleTrailing - textX), height: bounds.height - inset * 2)
            } else {
                linkThumb.isHidden = true
                linkIcon.isHidden = false
                let iconSide: CGFloat = 24
                linkIcon.frame = CGRect(x: inset, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
                let textX = linkIcon.frame.maxX + 10
                linkTitleLabel.frame = CGRect(x: textX, y: inset, width: max(0, titleTrailing - textX), height: bounds.height - inset * 2)
            }
        }
    }

    /// 角に半分はみ出した削除ボタン/ハンドルも押せるよう当たり判定を広げる。
    /// コンテンツ空間なので、スクリーン上で概ね一定(約16pt)になるようズームで補正する。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let margin = 16 / max(layerView?.zoom ?? 1, 0.01)
        return bounds.insetBy(dx: -margin, dy: -margin).contains(point)
    }

    // MARK: - モデル反映

    /// 現在のフォントサイズ(ツールバーの表示・選択通知に使う)
    var currentFontSize: CGFloat { fontSize }

    func apply(_ item: CanvasObjectItem) {
        guard !isInteracting else { return }
        let fontChanged = kind == .text && fontSize != item.fontSize
        contentFrame = item.frame
        fontSize = item.fontSize
        if kind == .text, !textView.isFirstResponder, textView.text != item.text {
            textView.text = item.text
        }
        // 編集中はビュー側が真値なので上書きしない(テキストと同様のガード)
        if kind == .todo, !todoListView.isEditing {
            todoListView.setItems(item.todoItems)
        }
        if kind == .noteLink {
            linkTitleLabel.text = item.linkTitle.isEmpty ? "(削除されたノート)" : item.linkTitle
            linkThumb.image = item.image
            setNeedsLayout()
        } else if let image = item.image {
            imageView.image = image
        }
        // フォントサイズが変わったら、幅は保ったまま高さを自動拡張して再配置する
        if fontChanged {
            recomputeTextHeight()
            if isSelected { layerView?.refreshSelectionInfo() }  // ツールバー表示も更新
        }
        applyPlacement()
    }

    /// フォントサイズや文字数に合わせて高さを再計算し、変わっていれば保存(Undo なし)。
    /// テキストは現在の幅で折り返すため、A4幅(paged)をはみ出さず縦に伸びる。
    private func recomputeTextHeight() {
        textView.font = .systemFont(ofSize: fontSize)
        let fitting = textView.sizeThatFits(
            CGSize(width: contentFrame.width, height: .greatestFiniteMagnitude)
        )
        let newHeight = max(40, fitting.height)
        if abs(newHeight - contentFrame.height) > 0.5 {
            contentFrame.size.height = newHeight
            layerView?.onAutoHeightChanged?(objectID, newHeight)
        }
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

    /// 移動パンは「このオブジェクトが選択済み」のときだけ開始する(選択してから移動)。
    /// 未選択オブジェクト上の指ドラッグはパンを開始させず、スクロールビューのスクロールに委ねる。
    /// (UIView 自身も同名メソッドを持つため override が必要)
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === movePan {
            return layerView?.selectedID == objectID
        }
        return true
    }

    // Todo の行内コントロール(チェックボックス/テキスト欄)へのタップは、
    // 親のタップ(=再選択・編集開始)に横取りさせずコントロールへ渡す。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard kind == .todo else { return true }
        var view = touch.view
        while let current = view, current !== self {
            if current is UIControl || current is UITextField { return false }
            view = current.superview
        }
        return true
    }

    /// 用紙色に合わせてテキストの文字色を切り替える(黒紙では白文字)
    func updatePageColor(_ pageColor: CanvasPageColor) {
        switch kind {
        case .text: textView.textColor = pageColor.contentUIColor
        case .todo: todoListView.updatePageColor(pageColor)
        default: break
        }
    }

    // MARK: - テキスト編集

    func beginTextEditing() {
        switch kind {
        case .text:
            textView.isEditable = true
            textView.isUserInteractionEnabled = true
            textView.becomeFirstResponder()
        case .todo:
            todoListView.beginEditingLastRow()
        default:
            break
        }
    }

    private func endTextEditing() {
        if kind == .text, textView.isFirstResponder {
            textView.resignFirstResponder()
        } else if kind == .todo {
            todoListView.endEditing(true)
        }
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
        // 指タップはツールに関係なくオブジェクトを選択できる(hitTest が指タッチを通す)。
        guard let layerView else { return }
        if layerView.selectedID != objectID {
            layerView.select(objectID)
        } else if kind == .text || kind == .todo {
            beginTextEditing()  // 選択済みのテキスト/Todoを再タップで編集開始
        }
    }

    /// ノートリンクのダブルタップ → リンク先ノートを開く
    @objc private func handleNoteLinkJump() {
        guard let layerView, kind == .noteLink else { return }
        layerView.onNoteLinkActivated?(objectID)
    }

    @objc private func handleMovePan(_ gesture: UIPanGestureRecognizer) {
        // 選択済みのオブジェクトだけを移動する(未選択は shouldBegin で弾かれスクロールになる)
        guard let layerView, layerView.selectedID == objectID else { return }
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
        // リサイズハンドルは選択中のみ表示されるが、念のため選択中のオブジェクトに限定する
        guard let layerView, layerView.selectedID == objectID else { return }
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
            } else if kind == .todo {
                // 高さは行数(内容)で決まるので幅だけ変える
                newWidth = max(160, newWidth)
                newHeight = contentFrame.height
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
        // 指の長押しはツールに関係なく、選択+削除メニューを出せる(hitTest が指タッチを通す)。
        guard gesture.state == .began, let layerView else { return }
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

// MARK: - Todoリスト(チェックリスト)

/// 空欄でのバックスペースを検知して「行削除」に使うテキストフィールド。
private final class TodoRowTextField: UITextField {
    var onDeleteBackwardWhenEmpty: (() -> Void)?
    override func deleteBackward() {
        let wasEmpty = (text ?? "").isEmpty
        super.deleteBackward()
        if wasEmpty { onDeleteBackwardWhenEmpty?() }
    }
}

/// Todoの1行(チェックボックス + テキスト欄)。
private final class TodoRowView: UIView, UITextFieldDelegate {
    let checkbox = UIButton(type: .system)
    let textField = TodoRowTextField()

    var onToggle: (() -> Void)?
    var onTextChanged: ((String) -> Void)?
    var onCommit: (() -> Void)?     // 編集終了(保存点)
    var onReturn: (() -> Void)?     // 改行 → 次の行を追加
    var onDeleteEmpty: (() -> Void)?  // 空行でバックスペース → 行削除

    override init(frame: CGRect) {
        super.init(frame: frame)
        checkbox.addTarget(self, action: #selector(handleToggle), for: .touchUpInside)
        addSubview(checkbox)

        textField.borderStyle = .none
        textField.font = .systemFont(ofSize: 16)
        textField.returnKeyType = .next
        textField.autocorrectionType = .no
        textField.delegate = self
        textField.addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)
        textField.onDeleteBackwardWhenEmpty = { [weak self] in self?.onDeleteEmpty?() }
        addSubview(textField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let checkSide: CGFloat = 24
        checkbox.frame = CGRect(x: 0, y: (bounds.height - checkSide) / 2, width: checkSide + 6, height: checkSide)
        let textX = checkbox.frame.maxX + 4
        textField.frame = CGRect(x: textX, y: 0, width: max(0, bounds.width - textX), height: bounds.height)
    }

    /// 項目内容と用紙色を反映(完了は打ち消し線 + 淡色)。
    func configure(item: TodoItem, pageColor: CanvasPageColor) {
        let base = pageColor.contentUIColor
        let symbol = item.done ? "checkmark.square.fill" : "square"
        checkbox.setImage(UIImage(systemName: symbol), for: .normal)
        checkbox.tintColor = item.done ? .systemGreen : base.withAlphaComponent(0.7)
        checkbox.accessibilityIdentifier = "todo-checkbox"
        checkbox.accessibilityValue = item.done ? "done" : "todo"

        let font = UIFont.systemFont(ofSize: 16)
        if item.done {
            textField.attributedText = NSAttributedString(string: item.text, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: base.withAlphaComponent(0.5),
                .font: font
            ])
        } else {
            textField.attributedText = nil
            textField.text = item.text
            textField.textColor = base
            textField.font = font
        }
    }

    @objc private func handleToggle() { onToggle?() }
    @objc private func handleEditingChanged() { onTextChanged?(textField.text ?? "") }

    func textFieldDidEndEditing(_ textField: UITextField) { onCommit?() }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn?()
        return false
    }
}

/// キャンバスに置くチェックリスト本体。行の追加/削除/チェックを管理し、変更を通知する。
final class TodoListView: UIView {
    /// 項目が変わった(保存すべき)ときに呼ばれる
    var onItemsChanged: (([TodoItem]) -> Void)?
    /// 行数に応じた必要高さ(コンテンツ空間)が変わったときに呼ばれる
    var onHeightChanged: ((CGFloat) -> Void)?

    private(set) var items: [TodoItem] = []
    private var pageColor: CanvasPageColor = .white
    private var rows: [TodoRowView] = []
    private let addButton = UIButton(type: .system)

    private static let rowHeight: CGFloat = 34
    private static let vInset: CGFloat = 8
    private static let hInset: CGFloat = 10

    /// いずれかの行を編集中か(apply による上書きを避ける判定に使う)
    var isEditing: Bool { rows.contains { $0.textField.isFirstResponder } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        clipsToBounds = true

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "plus.circle")
        config.title = "項目を追加"
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        addButton.configuration = config
        addButton.contentHorizontalAlignment = .leading
        addButton.titleLabel?.font = .systemFont(ofSize: 15)
        addButton.accessibilityIdentifier = "todo-add-item"
        addButton.addTarget(self, action: #selector(handleAdd), for: .touchUpInside)
        addSubview(addButton)

        updateCardColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - モデル反映

    func setItems(_ newItems: [TodoItem]) {
        items = newItems
        if rows.count != newItems.count {
            rebuildRows()
        } else {
            for (i, item) in newItems.enumerated() {
                rows[i].configure(item: item, pageColor: pageColor)
            }
        }
        setNeedsLayout()
        reportHeight()
    }

    func updatePageColor(_ pageColor: CanvasPageColor) {
        self.pageColor = pageColor
        updateCardColor()
        for (i, row) in rows.enumerated() where items.indices.contains(i) {
            row.configure(item: items[i], pageColor: pageColor)
        }
    }

    private func updateCardColor() {
        // 用紙色に対してうっすら浮かぶカード。文字色は用紙色から取る。
        backgroundColor = pageColor == .black
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(white: 0, alpha: 0.05)
        addButton.tintColor = pageColor.contentUIColor.withAlphaComponent(0.6)
        addButton.setTitleColor(pageColor.contentUIColor.withAlphaComponent(0.6), for: .normal)
    }

    // MARK: - レイアウト

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width - Self.hInset * 2
        var y = Self.vInset
        for row in rows {
            row.frame = CGRect(x: Self.hInset, y: y, width: width, height: Self.rowHeight)
            y += Self.rowHeight
        }
        addButton.frame = CGRect(x: Self.hInset, y: y, width: width, height: Self.rowHeight)
    }

    /// 行数から必要高さを算出して通知する。
    private func reportHeight() {
        let height = Self.vInset * 2 + Self.rowHeight * CGFloat(items.count + 1)
        onHeightChanged?(height)
    }

    // MARK: - 行の構築

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.map { item in
            let row = TodoRowView()
            row.configure(item: item, pageColor: pageColor)
            row.onToggle = { [weak self, weak row] in
                guard let self, let row, let idx = self.rows.firstIndex(of: row) else { return }
                self.items[idx].done.toggle()
                self.rows[idx].configure(item: self.items[idx], pageColor: self.pageColor)
                self.notify()
            }
            row.onTextChanged = { [weak self, weak row] text in
                guard let self, let row, let idx = self.rows.firstIndex(of: row) else { return }
                self.items[idx].text = text  // 保存は編集終了時(onCommit)にまとめて行う
            }
            row.onCommit = { [weak self] in self?.notify() }
            row.onReturn = { [weak self, weak row] in
                guard let self, let row, let idx = self.rows.firstIndex(of: row) else { return }
                self.insertItem(after: idx)
            }
            row.onDeleteEmpty = { [weak self, weak row] in
                guard let self, let row, let idx = self.rows.firstIndex(of: row) else { return }
                self.deleteItem(at: idx)
            }
            addSubview(row)
            return row
        }
        setNeedsLayout()
    }

    // MARK: - 操作

    @objc private func handleAdd() {
        items.append(TodoItem(text: "", done: false))
        rebuildRows()
        notify()
        reportHeight()
        focusRow(items.count - 1)
    }

    func beginEditingLastRow() {
        if rows.isEmpty { handleAdd() } else { focusRow(rows.count - 1) }
    }

    private func insertItem(after index: Int) {
        let newIndex = index + 1
        items.insert(TodoItem(text: "", done: false), at: newIndex)
        rebuildRows()
        notify()
        reportHeight()
        focusRow(newIndex)
    }

    private func deleteItem(at index: Int) {
        guard items.count > 1 else { return }  // 最後の1行は残す
        items.remove(at: index)
        rebuildRows()
        notify()
        reportHeight()
        focusRow(max(0, index - 1))
    }

    private func focusRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        layoutIfNeeded()
        rows[index].textField.becomeFirstResponder()
    }

    private func notify() { onItemsChanged?(items) }
}
