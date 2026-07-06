import Foundation
import Combine
import CoreData
import CoreGraphics

/// アプリ内スプリットビューの左右
enum SplitSide { case left, right }

/// 開いているノート(タブ)の状態を管理するセッションオブジェクト。
/// タブの並び・選択中タブ・キャンバス表示状態を保持し、UserDefaults に永続化する。
final class OpenNotesSession: ObservableObject {
    @Published private(set) var openNotes: [NoteFile] = []
    @Published var selectedNote: NoteFile? {
        didSet { persistState() }
    }
    /// true のときディテール領域にキャンバス(タブ)を表示する
    @Published var isCanvasVisible = false {
        didSet { persistState() }
    }

    // MARK: - アプリ内スプリットビュー(2画面分割)

    /// 分割表示が有効か
    @Published var isSplitActive = false
    /// 左側でアクティブなノート
    @Published var leftNoteID: NSManagedObjectID?
    /// 右側でアクティブなノート
    @Published var rightNoteID: NSManagedObjectID?
    /// 分割比率(左の占有幅。0.2〜0.8 にクランプ)
    @Published var splitDividerRatio: CGFloat = 0.5
    /// ツールバー(Undo/Redo・挿入)が作用する側
    @Published var activeSide: SplitSide = .left
    /// タブごとのビューポート(スクロール位置・ズーム)。
    /// 描画のたびに更新されるため @Published にはしない(再描画ループ防止)
    var viewports: [NSManagedObjectID: CanvasViewport] = [:]

    /// ビューポート保存のデバウンス(スクロール中の高頻度書き込みを防ぐ)
    private var viewportSaveTask: Task<Void, Never>?

    /// スクロール/ズーム時に呼ぶ。メモリを更新し、デバウンスして UserDefaults へ保存する。
    func updateViewport(_ viewport: CanvasViewport, for objectID: NSManagedObjectID) {
        viewports[objectID] = viewport
        viewportSaveTask?.cancel()
        viewportSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.persistState()
        }
    }

    /// 保留中のビューポート保存を即時確定させる(タブ切替・アプリ終了時)。
    func flushViewports() {
        viewportSaveTask?.cancel()
        persistState()
    }

    // MARK: - タブ操作

    /// ノートをタブで開く。既に開いていればそのタブへ切り替える(重複タブは作らない)。
    /// 分割中はアクティブ側のノートを差し替える。
    func open(_ note: NoteFile) {
        if !openNotes.contains(note) {
            openNotes.append(note)
        }
        if isSplitActive {
            assignActiveSide(note)
        }
        selectedNote = note
        isCanvasVisible = true
        persistState()
    }

    func close(_ note: NoteFile) {
        guard let index = openNotes.firstIndex(of: note) else { return }
        openNotes.remove(at: index)

        // 分割中に片側のノートを閉じたら、もう片方の全画面表示へ畳む
        if isSplitActive, note.objectID == leftNoteID || note.objectID == rightNoteID {
            let survivingID = note.objectID == leftNoteID ? rightNoteID : leftNoteID
            let surviving = survivingID.flatMap { id in openNotes.first { $0.objectID == id } }
            deactivateSplit()
            selectedNote = surviving ?? openNotes.last
        } else if selectedNote == note {
            // 閉じたタブの右隣(なければ末尾)を選択
            selectedNote = openNotes.indices.contains(index) ? openNotes[index] : openNotes.last
        }
        if openNotes.isEmpty {
            isCanvasVisible = false
        }
        persistState()
    }

    /// ゴミ箱行き・削除されたノートのタブを閉じる
    func closeTrashedNotes() {
        // 分割中の左右がゴミ箱行きなら先に分割を畳む(ダングリング防止)
        if isSplitActive {
            let deadSide = openNotes.contains { ($0.isTrashed || $0.isDeleted)
                && ($0.objectID == leftNoteID || $0.objectID == rightNoteID) }
            if deadSide {
                let keep = openNotes.first {
                    !($0.isTrashed || $0.isDeleted)
                    && ($0.objectID == leftNoteID || $0.objectID == rightNoteID)
                }
                deactivateSplit()
                if let keep { selectedNote = keep }
            }
        }
        for note in openNotes.filter({ $0.isTrashed || $0.isDeleted }) {
            close(note)
        }
    }

    // MARK: - スプリットビュー制御

    /// note を右側に配置して2画面分割を開始する(現在の選択ノートが左側になる)。
    /// 左に据える相手がいない/同一ノートのときは通常オープンにフォールバックする。
    func openRight(_ note: NoteFile) {
        guard let current = selectedNote, current != note else {
            open(note)
            return
        }
        if !openNotes.contains(note) { openNotes.append(note) }
        leftNoteID = current.objectID
        rightNoteID = note.objectID
        isSplitActive = true
        activeSide = .right
        selectedNote = note
        isCanvasVisible = true
        persistState()
    }

    /// 分割を解除して1画面へ戻す。keep 指定があればそのノートを、無ければアクティブ側を残す。
    func closeSplit(keeping keep: NoteFile? = nil) {
        guard isSplitActive else { return }
        let keepID = keep?.objectID ?? (activeSide == .left ? leftNoteID : rightNoteID)
        deactivateSplit()
        if let keepID, let note = openNotes.first(where: { $0.objectID == keepID }) {
            selectedNote = note
        }
        persistState()
    }

    /// 分割中に、指定側をアクティブにしてナビゲーション対象も合わせる。
    /// 既にアクティブなら何もしない(描画のたびの selectedNote 再代入=永続化を防ぐ)。
    func activateSide(_ side: SplitSide) {
        guard isSplitActive, activeSide != side else { return }
        activeSide = side
        let id = side == .left ? leftNoteID : rightNoteID
        if let id, let note = openNotes.first(where: { $0.objectID == id }) {
            selectedNote = note
        }
    }

    /// 分割状態をクリアする(内部用)
    private func deactivateSplit() {
        isSplitActive = false
        leftNoteID = nil
        rightNoteID = nil
        activeSide = .left
    }

    /// アクティブ側のノートIDを差し替える(内部用)
    private func assignActiveSide(_ note: NoteFile) {
        if activeSide == .left { leftNoteID = note.objectID }
        else { rightNoteID = note.objectID }
    }

    /// タブを維持したままライブラリへ戻る
    func showLibrary() {
        isCanvasVisible = false
    }

    /// ライブラリから最後に開いていたタブへ復帰
    func returnToCanvas() {
        if selectedNote != nil {
            isCanvasVisible = true
        }
    }

    // MARK: - 永続化(アプリ再起動後のタブ復元)

    private enum DefaultsKey {
        static let openNoteURIs = "session.openNoteURIs"
        static let selectedNoteURI = "session.selectedNoteURI"
        static let isCanvasVisible = "session.isCanvasVisible"
        static let viewports = "session.viewports"
    }

    /// 復元前に persistState が走って保存済みデータを消さないようにするフラグ
    private var isRestored = false

    /// 起動時に前回のタブ状態を復元する(RootView.onAppear から一度だけ呼ぶ)
    func restore(in context: NSManagedObjectContext) {
        guard !isRestored else { return }
        isRestored = true

        let defaults = UserDefaults.standard
        restoreViewports(from: defaults, in: context)  // タブの有無に関わらずビューポートは読む

        guard let uris = defaults.stringArray(forKey: DefaultsKey.openNoteURIs),
              !uris.isEmpty else { return }

        // selectedNote の didSet → persistState が保存値を上書きする前に全て読み切る
        let selectedURI = defaults.string(forKey: DefaultsKey.selectedNoteURI)
        let wasCanvasVisible = defaults.bool(forKey: DefaultsKey.isCanvasVisible)

        let notes = uris.compactMap { note(forURI: $0, in: context) }
        guard !notes.isEmpty else { return }

        openNotes = notes
        if let selectedURI, let selected = note(forURI: selectedURI, in: context) {
            selectedNote = selected
        } else {
            selectedNote = notes.last
        }
        isCanvasVisible = wasCanvasVisible && selectedNote != nil
    }

    /// URI 表現からノートを引き当てる(削除済み・ゴミ箱内は復元しない)
    private func note(forURI uri: String, in context: NSManagedObjectContext) -> NoteFile? {
        guard let url = URL(string: uri),
              let coordinator = context.persistentStoreCoordinator,
              let objectID = coordinator.managedObjectID(forURIRepresentation: url),
              let note = (try? context.existingObject(with: objectID)) as? NoteFile,
              !note.isTrashed, !note.isDeleted else { return nil }
        return note
    }

    private func persistState() {
        guard isRestored else { return }
        let defaults = UserDefaults.standard
        let uris = openNotes
            .filter { !$0.objectID.isTemporaryID }
            .map { $0.objectID.uriRepresentation().absoluteString }
        defaults.set(uris, forKey: DefaultsKey.openNoteURIs)
        defaults.set(
            selectedNote?.objectID.uriRepresentation().absoluteString,
            forKey: DefaultsKey.selectedNoteURI
        )
        defaults.set(isCanvasVisible, forKey: DefaultsKey.isCanvasVisible)
        defaults.set(serializedViewports(), forKey: DefaultsKey.viewports)
    }

    // MARK: - ビューポートの永続化

    /// NSManagedObjectID は永続キーにできないため URI 文字列をキーに辞書化する。
    /// 形式: ["<uri>": ["x": .., "y": .., "zoom": ..]]
    private func serializedViewports() -> [String: [String: Double]] {
        var result: [String: [String: Double]] = [:]
        for (objectID, viewport) in viewports where !objectID.isTemporaryID {
            let uri = objectID.uriRepresentation().absoluteString
            result[uri] = [
                "x": Double(viewport.contentOffset.x),
                "y": Double(viewport.contentOffset.y),
                "zoom": Double(viewport.zoomScale),
            ]
        }
        return result
    }

    private func restoreViewports(from defaults: UserDefaults, in context: NSManagedObjectContext) {
        guard let stored = defaults.dictionary(forKey: DefaultsKey.viewports) as? [String: [String: Double]],
              let coordinator = context.persistentStoreCoordinator else { return }
        for (uri, values) in stored {
            guard let url = URL(string: uri),
                  let objectID = coordinator.managedObjectID(forURIRepresentation: url) else { continue }
            viewports[objectID] = CanvasViewport(
                contentOffset: CGPoint(x: values["x"] ?? 0, y: values["y"] ?? 0),
                zoomScale: CGFloat(values["zoom"] ?? 1)
            )
        }
    }
}
