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
    var isLocked: Bool = false  // システムロック(PDF 背景など): 完全非対話
    var isUserLocked: Bool = false  // ユーザーロック: 選択可・南京錠・移動/リサイズ/削除/編集不可
    var parentGroupID: UUID? = nil  // 同じ UUID を持つオブジェクト同士は同一グループ
    var linkTitle: String = ""  // noteLink: リンク先ノートのタイトル
    var todoItems: [TodoItem] = []  // todo: チェックリストの項目
    var shapePayload: ShapePayload? = nil  // shape: 図形パラメータ
    var tablePayload: TablePayload? = nil  // table: 表の構造
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
    /// 図形のダブルタップで編集ポップオーバーを開く要求
    var onShapeEdit: ((NSManagedObjectID) -> Void)?
    /// 表のセル編集・列幅/行高変更の保存(payload 変更・Undo あり)
    var onTableChanged: ((NSManagedObjectID, TablePayload) -> Void)?
    /// 表の列幅/行高ドラッグ確定(新フレーム + 新 payload を 1つの Undo グループで保存)
    var onTableResized: ((NSManagedObjectID, CGRect, TablePayload) -> Void)?
    /// ユーザーロックのトグル(ロック/ロック解除)要求
    var onToggleUserLock: ((NSManagedObjectID) -> Void)?
    /// 選択中の複数オブジェクトを1グループにまとめる要求
    var onGroupObjects: (([NSManagedObjectID]) -> Void)?
    /// グループを解除する要求(渡された全 ID の parentGroupID を消す)
    var onUngroupObjects: (([NSManagedObjectID]) -> Void)?

    /// 現在のズーム倍率。オブジェクトはコンテンツ空間に直接配置され、スクロール/ズーム追従は
    /// スクロールビュー(PKCanvasView)の合成に任せるため、この値はスナップ閾値・タッチ判定の
    /// 「スクリーン上の見かけの距離」を保つためだけに使う(ズーム時のみ更新)。
    private(set) var zoom: CGFloat = 1
    /// 選択中のオブジェクト集合(複数選択・グループ選択)
    private(set) var selectedIDs: Set<NSManagedObjectID> = []
    /// 単体選択のときだけその ID(テキストツールバー表示・リサイズ・再タップ編集の判定に使う)
    var selectedID: NSManagedObjectID? { selectedIDs.count == 1 ? selectedIDs.first : nil }
    private var objectViews: [NSManagedObjectID: CanvasObjectUIView] = [:]
    private let guideLayer = CAShapeLayer()
    /// 複数選択(2個以上)時に出す統一バウンディングボックス + 8方向リサイズハンドル。
    private let selectionOverlay = SelectionOverlayView()
    /// リサイズ開始時の各オブジェクトのフレームと選択枠(比例スケールの基準)。
    private var resizeStartFrames: [NSManagedObjectID: CGRect] = [:]
    private var resizeStartBox: CGRect = .zero

    /// 自前投げ縄でインク+オブジェクトを一括選択したときのオーバーレイ(投げ縄パス+統一枠+削除)。
    let lassoView = LassoSelectionView()
    /// 投げ縄選択中は複数選択のリサイズ枠(selectionOverlay)を抑止する(統一枠は lassoView が担う)。
    private var suppressResizeOverlay = false
    /// 投げ縄選択のインク側(ストローク)の移動・削除を Coordinator へ委譲するクロージャ。
    var onLassoStrokesMove: ((CGVector, UIGestureRecognizer.State) -> Void)?
    var onLassoStrokesDelete: (() -> Void)?
    /// 投げ縄選択のボックス移動開始時の基準ボックス。
    private var lassoMoveStartBox: CGRect?

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

        selectionOverlay.frame = bounds
        selectionOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        selectionOverlay.onResize = { [weak self] handle, translation, state in
            self?.resizeSelection(handle: handle, translation: translation, state: state)
        }
        addSubview(selectionOverlay)

        lassoView.frame = bounds
        lassoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        lassoView.onMove = { [weak self] t, state in self?.moveLassoSelection(t, state: state) }
        lassoView.onDelete = { [weak self] in self?.deleteLassoSelection() }
        addSubview(lassoView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - ビューポート追従

    /// ズーム変更時のみ呼ばれ、スナップ閾値やタッチ判定の倍率を更新する。
    /// スクロール・ズームによるオブジェクトの再配置はスクロールビューの合成が行うため不要。
    func applyZoom(_ zoom: CGFloat) {
        self.zoom = zoom
        if !selectionOverlay.isHidden {
            selectionOverlay.update(box: selectionOverlay.box, zoom: zoom)
        }
        lassoView.applyZoom(zoom)
    }

    // MARK: - モデル同期

    func sync(items: [CanvasObjectItem]) {
        let ids = Set(items.map(\.id))
        for (id, view) in objectViews where !ids.contains(id) {
            view.removeFromSuperview()
            objectViews[id] = nil
            selectedIDs.remove(id)
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
        // オブジェクトを前面へ出したあとも統一枠は最前面に保つ(選択中のとき)
        if !selectionOverlay.isHidden {
            bringSubviewToFront(selectionOverlay)
            // 移動/リサイズでフレームが変わった選択に追従(操作中でなければ再計算)
            if resizeStartFrames.isEmpty { refreshSelectionOverlay() }
        }
        // 投げ縄の統一枠も最前面に保つ
        if !lassoView.isHidden { bringSubviewToFront(lassoView) }
    }

    // MARK: - 選択(単体・複数・グループ)

    /// グループに属していれば同一グループの全 ID、そうでなければ自身のみ。
    private func groupOrSelf(_ id: NSManagedObjectID) -> Set<NSManagedObjectID> {
        guard let gid = objectViews[id]?.parentGroupID else { return [id] }
        let members = objectViews.filter { $0.value.parentGroupID == gid }.map(\.key)
        return Set(members)
    }

    /// 選択集合を差し替え、各ビューの選択枠・リサイズハンドルを更新する。
    private func setSelection(_ ids: Set<NSManagedObjectID>) {
        guard ids != selectedIDs else { return }
        let hadSelection = !selectedIDs.isEmpty
        for old in selectedIDs.subtracting(ids) { objectViews[old]?.setSelected(false) }
        for new in ids.subtracting(selectedIDs) { objectViews[new]?.setSelected(true) }
        selectedIDs = ids
        // 単体/複数でリサイズハンドルの出方が変わるので、選択中の全ビューを更新する
        for id in ids { objectViews[id]?.refreshSelectionChrome() }
        refreshSelectionOverlay()
        notifyTextSelection()
        if (!ids.isEmpty) != hadSelection {
            onSelectionChanged?(!ids.isEmpty)
        }
    }

    // MARK: - 統一選択枠(複数選択の一括リサイズ)

    /// 選択集合のうち、移動・リサイズ可能な(非ロック)オブジェクトのフレーム。
    private func selectableSelectedFrames() -> [NSManagedObjectID: CGRect] {
        var frames: [NSManagedObjectID: CGRect] = [:]
        for id in selectedIDs {
            if let view = objectViews[id], !view.isMovementLocked {
                frames[id] = view.contentFrame
            }
        }
        return frames
    }

    /// 複数選択(非ロック2個以上)のとき統一枠を表示し、そうでなければ隠す。
    /// 単体選択は従来どおり各オブジェクトの右下ハンドルでリサイズする(枠は出さない)。
    private func refreshSelectionOverlay() {
        // 投げ縄選択中は統一枠を lassoView が担うため、複数選択のリサイズ枠は出さない。
        if suppressResizeOverlay { selectionOverlay.setActive(false); return }
        let frames = selectableSelectedFrames()
        guard frames.count >= 2, let box = SelectionGeometry.boundingBox(of: Array(frames.values)) else {
            selectionOverlay.setActive(false)
            return
        }
        selectionOverlay.setActive(true)
        selectionOverlay.update(box: box, zoom: zoom)
        bringSubviewToFront(selectionOverlay)
    }

    /// 統一枠のハンドルドラッグで選択全体を比例リサイズする。
    /// 一括移動(moveSelection)と同じ「同一イベント内で複数 onFrameChanged → 1つの Undo グループ」パターン。
    func resizeSelection(handle: SelectionHandle, translation t: CGVector, state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            resizeStartFrames = selectableSelectedFrames()
            resizeStartBox = SelectionGeometry.boundingBox(of: Array(resizeStartFrames.values)) ?? .zero
            for id in resizeStartFrames.keys { objectViews[id]?.setInteractingExternally(true) }
        case .changed:
            guard resizeStartBox.width > 0, resizeStartBox.height > 0 else { return }
            let newBox = SelectionGeometry.resizedBox(resizeStartBox, handle: handle, translation: t)
            for (id, start) in resizeStartFrames {
                objectViews[id]?.moveContentFrame(to: SelectionGeometry.rescale(start, from: resizeStartBox, to: newBox))
            }
            selectionOverlay.update(box: newBox, zoom: zoom)
        case .ended, .cancelled, .failed:
            for (id, _) in resizeStartFrames {
                objectViews[id]?.setInteractingExternally(false)
                if let frame = objectViews[id]?.contentFrame { onFrameChanged?(id, frame) }
            }
            resizeStartFrames = [:]
            refreshSelectionOverlay()
        default:
            break
        }
    }

    // MARK: - 自前投げ縄によるインク+オブジェクト一括選択

    /// ドラッグ中の投げ縄パス(コンテンツ空間の頂点列)を描画する。
    func updateLassoDrawing(points: [CGPoint]) {
        bringSubviewToFront(lassoView)
        lassoView.updateLassoPath(points)
    }

    /// 投げ縄確定: 囲んだオブジェクトを選択状態にし、統一枠(box=インク+オブジェクトの外接)を表示する。
    /// リサイズ枠(selectionOverlay)は抑止し、統一枠は lassoView が担う。
    func beginLassoSelection(objectIDs: Set<NSManagedObjectID>, box: CGRect) {
        suppressResizeOverlay = true
        setSelection(objectIDs)
        lassoView.showSelection(box: box, zoom: zoom)
        bringSubviewToFront(lassoView)
    }

    /// 投げ縄選択を解除する(選択解除・ツール変更・新しい投げ縄開始時)。
    func clearLassoSelection() {
        guard suppressResizeOverlay || !lassoView.isHidden else { return }
        suppressResizeOverlay = false
        lassoView.clear()
        setSelection([])
    }

    /// 投げ縄選択中か。
    var hasLassoSelection: Bool { !lassoView.isHidden && lassoView.box != nil }

    /// コンテンツ座標が「投げ縄の当たり判定を横取りすべき要素(オブジェクト or 投げ縄枠)」の上か。
    /// 自前投げ縄ジェスチャは、これが false(=空き領域)のときだけ開始する。
    func lassoShouldYield(atContentPoint point: CGPoint) -> Bool {
        if lassoViewContains(contentPoint: point) { return true }
        for view in objectViews.values where view.frame.contains(point) { return true }
        return false
    }

    /// コンテンツ座標が投げ縄の統一枠(ボックス内部 or 削除ボタン)の上か。
    /// 背景タップでの選択解除は、これが false(=枠の外)のときだけ行う(削除ボタンのタップを潰さない)。
    func lassoViewContains(contentPoint point: CGPoint) -> Bool {
        !lassoView.isHidden && lassoView.point(inside: convert(point, to: lassoView), with: nil)
    }

    /// 統一枠ドラッグでインク+オブジェクトを一括移動する(オブジェクトは既存 moveSelection、インクは Coordinator)。
    private func moveLassoSelection(_ t: CGVector, state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            lassoMoveStartBox = lassoView.box
        case .changed:
            if let start = lassoMoveStartBox {
                lassoView.showSelection(box: start.offsetBy(dx: t.dx, dy: t.dy), zoom: zoom)
            }
        default:
            break
        }
        moveSelection(translation: CGPoint(x: t.dx, y: t.dy), state: state)  // オブジェクト
        onLassoStrokesMove?(t, state)                                        // インク(Coordinator)
        if state == .ended || state == .cancelled || state == .failed { lassoMoveStartBox = nil }
    }

    /// 削除ボタンでインク+オブジェクトを一括削除する(同一イベントで1 Undo グループ)。
    private func deleteLassoSelection() {
        onLassoStrokesDelete?()  // インク(Coordinator)を先に
        deleteSelection()        // オブジェクト
        clearLassoSelection()
    }

    /// タップ選択: グループ化済みならグループ全体、そうでなければ単体を選択(置換)。
    func selectTapped(_ id: NSManagedObjectID) {
        setSelection(groupOrSelf(id))
    }

    /// 長押し選択: グループはグループ全体、単体は既存選択へ追加(2つ以上ためてグループ化できる)。
    func longPressSelect(_ id: NSManagedObjectID) {
        if objectViews[id]?.parentGroupID != nil {
            setSelection(groupOrSelf(id))
        } else {
            // 既存選択がグループ(全員同一 group)なら置換、そうでなければ追加
            let existingGrouped = selectedIDs.contains { objectViews[$0]?.parentGroupID != nil }
            setSelection(existingGrouped ? [id] : selectedIDs.union([id]))
        }
    }

    /// 単体選択/全解除(挿入直後フォーカス・背景タップ解除で使う)。
    func select(_ id: NSManagedObjectID?) {
        setSelection(id.map { [$0] } ?? [])
    }

    /// 選択が2つ以上か(グループ化アクションの可否)
    var hasMultipleSelection: Bool { selectedIDs.count >= 2 }

    /// 選択中のオブジェクトがグループに属しているか(グループ解除アクションの可否)
    var selectionIsGrouped: Bool {
        selectedIDs.contains { objectViews[$0]?.parentGroupID != nil }
    }

    // MARK: - 複数選択の一括移動(グループ/複数選択)

    private var groupMoveStart: [NSManagedObjectID: CGRect] = [:]

    /// 選択中の全オブジェクトを anchor のドラッグ量だけ平行移動する(スナップは無し)。
    func moveSelection(translation t: CGPoint, state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            groupMoveStart = [:]
            for id in selectedIDs {
                // ロック済みメンバーは一括移動から除外(ロックの保護を優先)
                if let view = objectViews[id], !view.isMovementLocked {
                    groupMoveStart[id] = view.contentFrame
                    view.setInteractingExternally(true)
                }
            }
        case .changed:
            for (id, start) in groupMoveStart {
                objectViews[id]?.moveContentFrame(to: start.offsetBy(dx: t.x, dy: t.y))
            }
            if !selectionOverlay.isHidden,
               let box = SelectionGeometry.boundingBox(of: Array(selectableSelectedFrames().values)) {
                selectionOverlay.update(box: box, zoom: zoom)
            }
        case .ended, .cancelled, .failed:
            for (id, _) in groupMoveStart {
                objectViews[id]?.setInteractingExternally(false)
                if let frame = objectViews[id]?.contentFrame { onFrameChanged?(id, frame) }
            }
            groupMoveStart = [:]
            refreshSelectionOverlay()
        default:
            break
        }
    }

    /// 選択中の全オブジェクトを削除する(グループ/複数選択の一括削除)。ロック済みは残す。
    func deleteSelection() {
        for id in selectedIDs where !(objectViews[id]?.isMovementLocked ?? false) {
            onDelete?(id)
        }
        selectedIDs = []
        onSelectionChanged?(false)
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
    /// 指定オブジェクトを選択し、テキスト編集を開始する。
    /// 挿入直後は @FetchRequest 反映前でビューが未生成のことがある。その場合は false を返し、
    /// 呼び出し側(handleAutoFocus)が次の更新で再試行できるようにする。
    @discardableResult
    func focus(on id: NSManagedObjectID) -> Bool {
        select(id)
        guard let view = objectViews[id] else { return false }
        view.beginTextEditing()
        return true
    }

    /// タップ配置(テキスト/Todo)専用: タップのタッチ文脈内でビューを生成し、選択・編集開始する。
    /// render 経由の autoFocus では becomeFirstResponder がタッチ文脈外になりソフトキーボードが
    /// 表示されないため、タップハンドラから同期的に呼ぶ。同 id の既存ビューがあれば再利用し、
    /// 次の syncObjects でも重複しない(objectID をキーにしているため)。
    func placeAndFocus(item: CanvasObjectItem) {
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
        bringSubviewToFront(view)
        layoutIfNeeded()          // 編集開始前にレイアウトを確定させる
        select(item.id)
        view.beginTextEditing()   // 配置と同時に編集開始(実機ではソフトキーボードも表示)
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
    let isLocked: Bool               // システムロック(PDF背景など): 完全非対話
    private var isUserLocked: Bool   // ユーザーロック: 選択可・南京錠・移動/削除/編集不可
    private(set) var parentGroupID: UUID?  // 同じ UUID 同士は同一グループ
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
    private let shapeView = ShapeContentView()
    private let tableView = TableObjectContentView()
    private let resizeHandle = UIView()
    /// ユーザーロック中に隅へ出す南京錠バッジ(タップで解除)
    private let lockBadge = UIButton(type: .system)
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
        self.isUserLocked = item.isUserLocked
        self.parentGroupID = item.parentGroupID
        self.contentFrame = item.frame
        self.fontSize = item.fontSize
        self.layerView = layerView
        super.init(frame: .zero)
        // システムロック(PDF背景など)は移動・リサイズ・選択・削除・編集を一切受け付けない。
        // ユーザーロックは選択・南京錠タップ・メニューのために対話は残す(操作側で個別に拒否)。
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
            updateTextAccessibility()
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
        case .shape:
            shapeView.payload = item.shapePayload
            addSubview(shapeView)
        case .table:
            tableView.onCellChanged = { [weak self] payload in
                guard let self else { return }
                self.layerView?.onTableChanged?(self.objectID, payload)
            }
            // 列/行リサイズ: ドラッグ中は自分の contentFrame を追従、確定で Undo グループ保存。
            tableView.onResizeLive = { [weak self] size in
                guard let self else { return }
                self.isInteracting = true
                self.contentFrame.size = size
                self.applyPlacement()
            }
            tableView.onResizeEnded = { [weak self] payload in
                guard let self else { return }
                self.isInteracting = false
                self.layerView?.onTableResized?(self.objectID, self.contentFrame, payload)
            }
            tableView.payload = item.tablePayload
            addSubview(tableView)
        }

        // 選択チップ: リサイズハンドル(右下)。角に半分かかる配置
        resizeHandle.backgroundColor = .systemBackground
        resizeHandle.layer.cornerRadius = 11
        resizeHandle.layer.borderWidth = 2
        resizeHandle.layer.borderColor = UIColor.systemBlue.cgColor
        resizeHandle.isHidden = true
        addSubview(resizeHandle)

        // 南京錠バッジ(ユーザーロック中のみ表示、タップで解除)。右上の角に半分かかる配置。
        let lockSymbol = UIImage(systemName: "lock.fill",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        lockBadge.setImage(lockSymbol, for: .normal)
        lockBadge.tintColor = .white
        lockBadge.backgroundColor = .systemBlue
        lockBadge.layer.cornerRadius = 11
        lockBadge.imageView?.contentMode = .scaleAspectFit
        lockBadge.isHidden = true
        lockBadge.accessibilityIdentifier = "object-lock-badge"
        lockBadge.addTarget(self, action: #selector(handleLockBadgeTap), for: .touchUpInside)
        addSubview(lockBadge)

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

        // ノートリンクはダブルタップでリンク先へジャンプ。
        // require(toFail:) が無いと単タップ(1回目のタップで即成立)が毎回先に発火し、
        // ジャンプの直前に選択状態のフリッカーが入ってしまう。
        if kind == .noteLink {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleNoteLinkJump))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.allowedTouchTypes = fingerOnly
            addGestureRecognizer(doubleTap)
            tap.require(toFail: doubleTap)
        }

        // 図形はダブルタップで編集ポップオーバー(線色/塗り/太さ)を開く。
        if kind == .shape {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleShapeEditDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.allowedTouchTypes = fingerOnly
            addGestureRecognizer(doubleTap)
            tap.require(toFail: doubleTap)
        }

        // 表はセルのダブルタップでそのセルのテキスト編集に入る。
        if kind == .table {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleTableCellDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.allowedTouchTypes = fingerOnly
            addGestureRecognizer(doubleTap)
            tap.require(toFail: doubleTap)
        }

        configureLockState()
    }

    /// ユーザーロック状態に応じて南京錠バッジの表示・コンテンツ編集可否を更新する。
    private func configureLockState() {
        lockBadge.isHidden = !isUserLocked
        if isUserLocked { bringSubviewToFront(lockBadge) }
        // Todo はロック中チェック/編集させない(テキスト・画像は元々編集開始まで非対話)
        if kind == .todo { todoListView.isUserInteractionEnabled = !isUserLocked }
        setNeedsLayout()
    }

    @objc private func handleLockBadgeTap() {
        layerView?.onToggleUserLock?(objectID)
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
        shapeView.frame = bounds
        tableView.frame = bounds
        resizeHandle.frame = CGRect(x: bounds.width - 11, y: bounds.height - 11, width: 22, height: 22)
        lockBadge.frame = CGRect(x: bounds.width - 11, y: -11, width: 22, height: 22)  // 右上の角

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
        parentGroupID = item.parentGroupID
        if isUserLocked != item.isUserLocked {
            isUserLocked = item.isUserLocked
            if isUserLocked { endTextEditing() }
            configureLockState()
            refreshSelectionChrome()  // ロック中はリサイズハンドルを出さない(選択枠は残す)
        }
        if kind == .text, !textView.isFirstResponder, textView.text != item.text {
            textView.text = item.text
        }
        if kind == .text { updateTextAccessibility() }
        // 編集中はビュー側が真値なので上書きしない(テキストと同様のガード)
        if kind == .todo, !todoListView.isEditing {
            todoListView.setItems(item.todoItems)
        }
        if kind == .shape {
            shapeView.payload = item.shapePayload
            shapeView.setNeedsDisplay()
        }
        if kind == .table {
            tableView.payload = item.tablePayload
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
        if kind == .noteLink {
            // ノートリンクは角丸カード自体の枠を青く太くして選択を示す(矩形の外枠は出さない)
            layer.borderWidth = 0
            linkCard.layer.borderColor = (selected ? UIColor.systemBlue : UIColor.separator).cgColor
            linkCard.layer.borderWidth = selected ? 2.0 : 0.5
        }
        if !selected { endTextEditing() }
        refreshSelectionChrome()
    }

    /// リサイズハンドルの表示可否を現在の選択状況から更新する。
    /// リサイズは「単体選択かつ非ロック」のときだけ(複数選択/グループ選択では出さない)。
    func refreshSelectionChrome() {
        let single = layerView?.selectedID == objectID
        let show = isSelected && single && !isUserLocked
        // 表は列/行の個別リサイズハンドルで調整するため、四隅の一括リサイズは出さない。
        resizeHandle.isHidden = !show || kind == .table
        if kind == .table { tableView.setResizeHandlesVisible(show) }
    }

    /// 移動・削除から保護されているか(システム/ユーザーどちらのロックでも)
    var isMovementLocked: Bool { isLocked || isUserLocked }

    /// レイヤー主導の一括移動用: 対話フラグと配置を外部から設定する。
    func setInteractingExternally(_ value: Bool) { isInteracting = value }
    func moveContentFrame(to frame: CGRect) {
        contentFrame = frame
        applyPlacement()
    }

    /// 移動パンは「このオブジェクトが選択済み」のときだけ開始する(選択してから移動)。
    /// 未選択オブジェクト上の指ドラッグはパンを開始させず、スクロールビューのスクロールに委ねる。
    /// (UIView 自身も同名メソッドを持つため override が必要)
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === movePan {
            // 選択済み(単体 or 複数選択の一員)かつ非ロックのときだけ移動を開始する
            return (layerView?.selectedIDs.contains(objectID) ?? false) && !isUserLocked
        }
        return true
    }

    // Todo の行内コントロール(チェックボックス/テキスト欄)へのタップは、
    // 親のタップ(=再選択・編集開始)に横取りさせずコントロールへ渡す。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard kind == .todo || kind == .table else { return true }
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
        case .table: tableView.updatePageColor(pageColor)
        default: break
        }
    }

    /// テキストの内容を、編集していないときでも XCUITest / VoiceOver から取得できるようにする。
    /// 非編集時は isUserInteractionEnabled=false で UITextView が「Disabled」になり、既定では
    /// テキストを accessibility value として公開しなくなる(選択解除後に要素が value 検索で
    /// 見つからなくなる)。ここで identifier と value を明示して常時参照可能にする。
    private func updateTextAccessibility() {
        guard kind == .text else { return }
        textView.isAccessibilityElement = true
        textView.accessibilityIdentifier = "canvas-object-text"
        textView.accessibilityValue = textView.text
    }

    // MARK: - テキスト編集

    func beginTextEditing() {
        guard !isUserLocked else { return }  // ロック中は編集不可
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
            // 入力内容を resignFirstResponder より先に永続化する。
            // resign から textViewDidEndEditing までの間に選択変更由来の再描画で
            // apply(_:) が走ると、まだ空のモデル値で入力済みテキストを上書き消去して
            // しまう競合があるため、ここで先にモデルへ確定させて競合を断つ。
            layerView?.onTextChanged?(objectID, textView.text ?? "")
            textView.resignFirstResponder()
        } else if kind == .todo {
            todoListView.endEditing(true)
        } else if kind == .table {
            tableView.endActiveEditing()
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
        updateTextAccessibility()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        textView.isEditable = false
        textView.isUserInteractionEnabled = false
        updateTextAccessibility()
        layerView?.onTextChanged?(objectID, textView.text ?? "")
        layerView?.onFrameChanged?(objectID, contentFrame)  // 自動拡張した高さを保存
    }

    // MARK: - ジェスチャ

    @objc private func handleTap() {
        // 指タップはツールに関係なくオブジェクトを選択できる(hitTest が指タッチを通す)。
        guard let layerView else { return }
        if layerView.selectedID == objectID {
            // 単体選択中の再タップ → テキスト/Todoを編集開始
            if kind == .text || kind == .todo { beginTextEditing() }
        } else {
            // グループ化済みならグループ全体、そうでなければ単体を選択
            layerView.selectTapped(objectID)
        }
    }

    /// ノートリンクのダブルタップ → リンク先ノートを開く
    @objc private func handleNoteLinkJump() {
        guard let layerView, kind == .noteLink else { return }
        layerView.onNoteLinkActivated?(objectID)
    }

    /// 図形のダブルタップ → 選択したうえで編集ポップオーバーを要求する
    @objc private func handleShapeEditDoubleTap() {
        guard let layerView, kind == .shape else { return }
        if layerView.selectedID != objectID { layerView.selectTapped(objectID) }
        layerView.onShapeEdit?(objectID)
    }

    /// 表のダブルタップ → 選択したうえで、タップしたセルのテキスト編集に入る。
    @objc private func handleTableCellDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let layerView, kind == .table else { return }
        if layerView.selectedID != objectID { layerView.selectTapped(objectID) }
        tableView.beginEditingCell(at: gesture.location(in: tableView))
    }

    @objc private func handleMovePan(_ gesture: UIPanGestureRecognizer) {
        guard let layerView, layerView.selectedIDs.contains(objectID) else { return }
        // 複数選択/グループ選択のときは選択全体を一括で動かす(レイヤーが調整)
        if layerView.selectedIDs.count > 1 {
            if gesture.state == .began { endTextEditing() }
            layerView.moveSelection(translation: gesture.translation(in: layerView), state: gesture.state)
            return
        }
        // 以下は単体選択の移動(スナップあり)
        switch gesture.state {
        case .began:
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
            } else if kind == .shape || kind == .table {
                // 図形は縦横を自由にリサイズ(アスペクト固定しない)。
                // 表は選択中に列/行ハンドルで個別調整するため通常は四隅ハンドルを出さない(下記 refreshSelectionChrome)。
                newWidth = max(20, newWidth)
                newHeight = max(20, newHeight)
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
            // リサイズ中に行の増減があると、todoListView.onHeightChanged は
            // isInteracting ガードで無視され続けていた。ここで isInteracting を
            // false にした直後に高さを再計算させ、取りこぼしを解消する。
            if kind == .todo { todoListView.reportHeight() }
            layerView.onFrameChanged?(objectID, contentFrame)
        default:
            break
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        // 指の長押しはツールに関係なくメニューを出せる(hitTest が指タッチを通す)。
        // グループはグループ全体、単体は既存選択へ追加(2つ以上ためてグループ化できる)。
        guard gesture.state == .began, let layerView else { return }
        layerView.longPressSelect(objectID)
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
        guard let layerView else { return nil }
        let multi = layerView.selectedIDs.count > 1

        // 単体ロック中は解除のみ(削除は受け付けない)
        if isUserLocked, !multi {
            return UIMenu(children: [
                UIAction(title: "ロック解除", image: UIImage(systemName: "lock.open")) { [weak self] _ in
                    guard let self else { return }
                    self.layerView?.onToggleUserLock?(self.objectID)
                }
            ])
        }

        var actions: [UIMenuElement] = []
        let ids = Array(layerView.selectedIDs)
        if layerView.selectionIsGrouped {
            actions.append(UIAction(title: "グループ解除", image: UIImage(systemName: "rectangle.on.rectangle.slash")) {
                [weak self] _ in self?.layerView?.onUngroupObjects?(ids)
            })
        } else if multi {
            actions.append(UIAction(title: "グループ化", image: UIImage(systemName: "square.on.square")) {
                [weak self] _ in self?.layerView?.onGroupObjects?(ids)
            })
        }
        if !multi {
            actions.append(UIAction(title: "ロック", image: UIImage(systemName: "lock")) {
                [weak self] _ in guard let self else { return }
                self.layerView?.onToggleUserLock?(self.objectID)
            })
        }
        // 削除: 複数選択は一括、単体は個別
        actions.append(UIAction(title: "削除", image: UIImage(systemName: "trash"), attributes: .destructive) {
            [weak self] _ in
            guard let self, let layerView = self.layerView else { return }
            if layerView.selectedIDs.count > 1 { layerView.deleteSelection() }
            else { layerView.onDelete?(self.objectID) }
        })
        return UIMenu(children: actions)
    }
}

// MARK: - 図形(矩形・楕円・三角・直線・矢印・星)

/// 図形を UIBezierPath で描画するコンテンツビュー。移動・リサイズ・選択・編集ジェスチャは
/// 親 CanvasObjectUIView が持つため、このビュー自身はタッチを受けない(描画専用)。
final class ShapeContentView: UIView {
    var payload: ShapePayload?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw  // リサイズで再描画されるように
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let payload else { return }
        let lw = max(0.5, payload.lineWidth)
        let inset = bounds.insetBy(dx: lw / 2, dy: lw / 2)
        guard inset.width > 0, inset.height > 0 else { return }

        let path = payload.shapeType.path(in: inset)
        path.lineWidth = lw
        path.lineJoinStyle = .round
        path.lineCapStyle = .round

        if payload.shapeType.isFillable,
           let fill = UIColor(hex: payload.fillColor), fill.cgColor.alpha > 0 {
            fill.setFill()
            path.fill()
        }
        if let stroke = UIColor(hex: payload.strokeColor) {
            stroke.setStroke()
            path.stroke()
        }
    }
}

// MARK: - 表(Excel風・可変列幅/行高)

/// 表をグリッド描画し、各セルに透明な UITextField を重ねる。列/行境界のハンドルで
/// 個別に幅・高さを変更できる(Excel仕様)。フレーム/選択/移動は親 CanvasObjectUIView が持つ。
final class TableObjectContentView: UIView, UITextFieldDelegate {
    var payload: TablePayload? { didSet { rebuild() } }
    /// セルテキスト変更の保存(payload を渡す)
    var onCellChanged: ((TablePayload) -> Void)?
    /// 列/行リサイズ中: 表全体の新サイズを親へ伝える(親が contentFrame を更新)
    var onResizeLive: ((CGSize) -> Void)?
    /// 列/行リサイズ確定: 最終 payload を親へ伝える(親が Undo グループで保存)
    var onResizeEnded: ((TablePayload) -> Void)?

    private var cellFields: [[UITextField]] = []
    private var columnHandles: [UIView] = []
    private var rowHandles: [UIView] = []
    private var handlesVisible = false
    private var textColor: UIColor = .label
    private var resizeStartWidths: [CGFloat] = []
    private var resizeStartHeights: [CGFloat] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: 構築・反映

    private func rebuild() {
        guard let payload else { return }
        let structureChanged = cellFields.count != payload.rowCount
            || (cellFields.first?.count ?? 0) != payload.columnCount
        if structureChanged {
            cellFields.flatMap { $0 }.forEach { $0.removeFromSuperview() }
            cellFields = (0..<payload.rowCount).map { _ in
                (0..<payload.columnCount).map { _ -> UITextField in
                    let tf = UITextField()
                    tf.font = .systemFont(ofSize: 14)
                    tf.borderStyle = .none
                    tf.backgroundColor = .clear
                    tf.textColor = textColor
                    tf.textAlignment = .center
                    tf.autocorrectionType = .no
                    tf.isUserInteractionEnabled = false  // 編集開始(ダブルタップ)まで親がタッチを受ける
                    tf.delegate = self
                    tf.addTarget(self, action: #selector(cellEditingChanged), for: .editingChanged)
                    addSubview(tf)
                    return tf
                }
            }
            rebuildHandles()
        }
        for r in 0..<payload.rowCount {
            for c in 0..<payload.columnCount {
                let tf = cellFields[r][c]
                let text = payload.text(row: r, col: c)
                if !tf.isFirstResponder, tf.text != text { tf.text = text }
            }
        }
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func rebuildHandles() {
        (columnHandles + rowHandles).forEach { $0.removeFromSuperview() }
        columnHandles = []
        rowHandles = []
        guard let payload else { return }
        for i in 0..<payload.columnCount {
            let h = makeHandle(vertical: true)
            h.tag = i
            h.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleColumnPan(_:))))
            addSubview(h)
            columnHandles.append(h)
        }
        for i in 0..<payload.rowCount {
            let h = makeHandle(vertical: false)
            h.tag = i
            h.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleRowPan(_:))))
            addSubview(h)
            rowHandles.append(h)
        }
        setResizeHandlesVisible(handlesVisible)
    }

    private func makeHandle(vertical: Bool) -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.6)
        v.layer.cornerRadius = 3
        v.isHidden = true
        return v
    }

    func setResizeHandlesVisible(_ visible: Bool) {
        handlesVisible = visible
        (columnHandles + rowHandles).forEach { $0.isHidden = !visible }
        if visible { (columnHandles + rowHandles).forEach { bringSubviewToFront($0) } }
    }

    func updatePageColor(_ pageColor: CanvasPageColor) {
        textColor = pageColor.contentUIColor
        cellFields.flatMap { $0 }.forEach { $0.textColor = textColor }
    }

    // MARK: レイアウト・描画

    /// 列/行の境界座標(0..n)。合計が bounds に一致しない場合はスケールして合わせる。
    private func edges(_ sizes: [CGFloat], total: CGFloat) -> [CGFloat] {
        let sum = sizes.reduce(0, +)
        let scale = sum > 0 ? total / sum : 1
        var acc: [CGFloat] = [0]
        var running: CGFloat = 0
        for s in sizes { running += s * scale; acc.append(running) }
        return acc
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let payload, !cellFields.isEmpty else { return }
        let xs = edges(payload.columnWidths, total: bounds.width)
        let ys = edges(payload.rowHeights, total: bounds.height)
        for r in 0..<min(payload.rowCount, cellFields.count) {
            for c in 0..<min(payload.columnCount, cellFields[r].count) {
                cellFields[r][c].frame = CGRect(
                    x: xs[c] + 4, y: ys[r],
                    width: max(0, (xs[c + 1] - xs[c]) - 8), height: max(0, ys[r + 1] - ys[r])
                )
            }
        }
        for (i, h) in columnHandles.enumerated() where i + 1 < xs.count {
            h.frame = CGRect(x: xs[i + 1] - 4, y: 0, width: 8, height: 20)
        }
        for (i, h) in rowHandles.enumerated() where i + 1 < ys.count {
            h.frame = CGRect(x: 0, y: ys[i + 1] - 4, width: 20, height: 8)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let payload else { return }
        let xs = edges(payload.columnWidths, total: bounds.width)
        let ys = edges(payload.rowHeights, total: bounds.height)
        UIColor.separator.setStroke()
        let inner = UIBezierPath()
        for x in xs.dropFirst().dropLast() {
            inner.move(to: CGPoint(x: x, y: 0)); inner.addLine(to: CGPoint(x: x, y: bounds.height))
        }
        for y in ys.dropFirst().dropLast() {
            inner.move(to: CGPoint(x: 0, y: y)); inner.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        inner.lineWidth = 0.5
        inner.stroke()
        let border = UIBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    // MARK: セル編集

    /// 指定座標(このビュー座標)のセルを編集開始する。
    func beginEditingCell(at point: CGPoint) {
        guard let payload else { return }
        let xs = edges(payload.columnWidths, total: bounds.width)
        let ys = edges(payload.rowHeights, total: bounds.height)
        guard let col = (0..<payload.columnCount).first(where: { point.x >= xs[$0] && point.x < xs[$0 + 1] }),
              let row = (0..<payload.rowCount).first(where: { point.y >= ys[$0] && point.y < ys[$0 + 1] }),
              row < cellFields.count, col < cellFields[row].count else { return }
        let tf = cellFields[row][col]
        tf.isUserInteractionEnabled = true
        tf.becomeFirstResponder()
    }

    @objc private func cellEditingChanged() { /* ライブ反映は終了時にまとめて保存 */ }

    func textFieldDidEndEditing(_ textField: UITextField) {
        textField.isUserInteractionEnabled = false
        writeBackCells()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func writeBackCells() {
        guard var updated = payload else { return }
        var cells: [TableCell] = []
        for r in 0..<min(updated.rowCount, cellFields.count) {
            for c in 0..<min(updated.columnCount, cellFields[r].count) {
                let t = cellFields[r][c].text ?? ""
                if !t.isEmpty { cells.append(TableCell(row: r, col: c, text: t)) }
            }
        }
        guard cells != updated.cells else { return }
        updated.cells = cells
        onCellChanged?(updated)
    }

    /// 外部(親)から編集を終了させる(選択解除時など)。
    func endActiveEditing() {
        endEditing(true)
    }

    // MARK: 列/行リサイズ

    @objc private func handleColumnPan(_ gesture: UIPanGestureRecognizer) {
        guard let index = gesture.view?.tag, var p = payload, index < p.columnWidths.count else { return }
        switch gesture.state {
        case .began:
            resizeStartWidths = p.columnWidths
        case .changed:
            let dx = gesture.translation(in: self).x
            let start = index < resizeStartWidths.count ? resizeStartWidths[index] : p.columnWidths[index]
            p.columnWidths[index] = max(40, start + dx)
            payload = p
            onResizeLive?(p.totalSize)
        case .ended, .cancelled, .failed:
            onResizeEnded?(p)
        default:
            break
        }
    }

    @objc private func handleRowPan(_ gesture: UIPanGestureRecognizer) {
        guard let index = gesture.view?.tag, var p = payload, index < p.rowHeights.count else { return }
        switch gesture.state {
        case .began:
            resizeStartHeights = p.rowHeights
        case .changed:
            let dy = gesture.translation(in: self).y
            let start = index < resizeStartHeights.count ? resizeStartHeights[index] : p.rowHeights[index]
            p.rowHeights[index] = max(24, start + dy)
            payload = p
            onResizeLive?(p.totalSize)
        case .ended, .cancelled, .failed:
            onResizeEnded?(p)
        default:
            break
        }
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
    /// リサイズ操作終了時に外側(CanvasObjectUIView)から明示的に再計算させるため fileprivate。
    fileprivate func reportHeight() {
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
