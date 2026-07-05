import CoreData
import UIKit
import PencilKit

/// 削除・追加の Undo/Redo でオブジェクトを再構築するための全属性スナップショット
struct CanvasObjectSnapshot {
    let id: UUID
    let kind: String?
    let text: String?
    let fontSize: Double
    let payload: Data?
    let frame: CGRect
    let zOrder: Int64
    let createdAt: Date?
    let noteID: NSManagedObjectID

    init?(object: CanvasObject) {
        guard let id = object.id, let note = object.note else { return nil }
        self.id = id
        kind = object.kind
        text = object.text
        fontSize = object.fontSize
        payload = object.payload
        frame = object.contentFrame
        zOrder = object.zOrder
        createdAt = object.createdAt
        noteID = note.objectID
    }
}

/// キャンバスオブジェクト操作(追加・削除・移動・リサイズ・テキスト編集)を
/// PencilKit の描画と同じ UndoManager(PKCanvasView.undoManager)へ登録するヘルパー。
/// 各 register 系メソッドは「変更を適用した後」に呼び、逆操作を積む。
///
/// - registerUndo の target には app-lifetime の viewContext を渡す
///   (UndoManager は target を unowned 参照するため、短命なオブジェクトは渡せない)。
/// - オブジェクトの特定は NSManagedObjectID ではなく UUID で行う
///   (削除 → Undo 復元で NSManagedObjectID が変わるため)。
/// - Undo 実行時は Core Data を直接更新して保存する。ビュー側は @FetchRequest 経由で
///   変更を受け取り、ObjectLayerUIView.sync(items:) で表示へ反映される。
enum CanvasObjectUndo {
    /// 移動・リサイズ・テキスト自動拡張のフレーム変更
    static func registerFrameChange(
        objectUUID: UUID,
        previousFrame: CGRect,
        in manager: UndoManager?,
        context: NSManagedObjectContext,
        bridge: CanvasUndoBridge?
    ) {
        guard let manager else { return }
        manager.registerUndo(withTarget: context) { [weak manager, weak bridge] context in
            MainActor.assumeIsolated {
                guard let object = fetchObject(objectUUID, in: context) else { return }
                let current = object.contentFrame
                object.contentFrame = previousFrame
                object.updatedAt = .now
                saveAndRefresh(context: context, bridge: bridge)
                // Undo 中の再登録は Redo として積まれる(Redo 中なら Undo に戻る)
                registerFrameChange(
                    objectUUID: objectUUID, previousFrame: current,
                    in: manager, context: context, bridge: bridge
                )
            }
        }
        bridge?.refresh()
    }

    /// テキスト編集終了時の内容変更
    static func registerTextChange(
        objectUUID: UUID,
        previousText: String,
        in manager: UndoManager?,
        context: NSManagedObjectContext,
        bridge: CanvasUndoBridge?
    ) {
        guard let manager else { return }
        manager.registerUndo(withTarget: context) { [weak manager, weak bridge] context in
            MainActor.assumeIsolated {
                guard let object = fetchObject(objectUUID, in: context) else { return }
                let current = object.text ?? ""
                object.text = previousText
                object.updatedAt = .now
                saveAndRefresh(context: context, bridge: bridge)
                registerTextChange(
                    objectUUID: objectUUID, previousText: current,
                    in: manager, context: context, bridge: bridge
                )
            }
        }
        bridge?.refresh()
    }

    /// テキストのフォントサイズ変更(高さの自動調整はビュー側が追従して保存する)
    static func registerFontSizeChange(
        objectUUID: UUID,
        previousFontSize: Double,
        in manager: UndoManager?,
        context: NSManagedObjectContext,
        bridge: CanvasUndoBridge?
    ) {
        guard let manager else { return }
        manager.registerUndo(withTarget: context) { [weak manager, weak bridge] context in
            MainActor.assumeIsolated {
                guard let object = fetchObject(objectUUID, in: context) else { return }
                let current = object.fontSize
                object.fontSize = previousFontSize
                object.updatedAt = .now
                saveAndRefresh(context: context, bridge: bridge)
                registerFontSizeChange(
                    objectUUID: objectUUID, previousFontSize: current,
                    in: manager, context: context, bridge: bridge
                )
            }
        }
        bridge?.refresh()
    }

    /// オブジェクト追加(Undo = 削除)
    static func registerInsert(
        objectUUID: UUID,
        in manager: UndoManager?,
        context: NSManagedObjectContext,
        bridge: CanvasUndoBridge?
    ) {
        guard let manager else { return }
        manager.registerUndo(withTarget: context) { [weak manager, weak bridge] context in
            MainActor.assumeIsolated {
                guard let object = fetchObject(objectUUID, in: context),
                      // Undo 時点の状態(移動・編集済みかもしれない)で復元できるよう撮り直す
                      let snapshot = CanvasObjectSnapshot(object: object)
                else { return }
                context.delete(object)
                saveAndRefresh(context: context, bridge: bridge)
                registerDelete(snapshot: snapshot, in: manager, context: context, bridge: bridge)
            }
        }
        bridge?.refresh()
    }

    /// オブジェクト削除(Undo = スナップショットから復元)。削除実行前に snapshot を取ること。
    static func registerDelete(
        snapshot: CanvasObjectSnapshot,
        in manager: UndoManager?,
        context: NSManagedObjectContext,
        bridge: CanvasUndoBridge?
    ) {
        guard let manager else { return }
        manager.registerUndo(withTarget: context) { [weak manager, weak bridge] context in
            MainActor.assumeIsolated {
                restore(snapshot, context: context, bridge: bridge)
                registerInsert(
                    objectUUID: snapshot.id, in: manager, context: context, bridge: bridge
                )
            }
        }
        bridge?.refresh()
    }

    /// ページ削除に伴う「ページ数」と「手書き描画」の一括変更を Undo に積む。
    /// 同一ラン内で登録される各オブジェクトの削除 Undo と自動的に1グループへまとまる。
    /// - toRestore: Undo で戻す状態 / - toReapply: Redo で再適用する状態
    static func registerPageStructureChange(
        noteID: NSManagedObjectID,
        drawingToRestore: PKDrawing,
        pageCountToRestore: Int16,
        drawingToReapply: PKDrawing,
        pageCountToReapply: Int16,
        in manager: UndoManager?,
        context: NSManagedObjectContext,
        bridge: CanvasUndoBridge?
    ) {
        guard let manager else { return }
        manager.registerUndo(withTarget: context) { [weak manager, weak bridge] context in
            MainActor.assumeIsolated {
                if let note = (try? context.existingObject(with: noteID)) as? NoteFile {
                    note.pageCount = pageCountToRestore
                    note.updatedAt = .now
                }
                bridge?.replaceDrawing(drawingToRestore)
                if context.hasChanges { try? context.save() }
                bridge?.refresh()
                // Undo 中の登録は Redo として積まれる(状態を入れ替えて再登録)
                registerPageStructureChange(
                    noteID: noteID,
                    drawingToRestore: drawingToReapply, pageCountToRestore: pageCountToReapply,
                    drawingToReapply: drawingToRestore, pageCountToReapply: pageCountToRestore,
                    in: manager, context: context, bridge: bridge
                )
            }
        }
        bridge?.refresh()
    }

    // MARK: - 内部処理

    private static func fetchObject(
        _ uuid: UUID, in context: NSManagedObjectContext
    ) -> CanvasObject? {
        let request = NSFetchRequest<CanvasObject>(entityName: "CanvasObject")
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private static func restore(
        _ snapshot: CanvasObjectSnapshot,
        context: NSManagedObjectContext,
        bridge: CanvasUndoBridge?
    ) {
        guard let note = (try? context.existingObject(with: snapshot.noteID)) as? NoteFile,
              !note.isDeleted
        else { return }
        let object = CanvasObject(context: context)
        object.id = snapshot.id
        object.kind = snapshot.kind
        object.text = snapshot.text
        object.fontSize = snapshot.fontSize
        object.payload = snapshot.payload
        object.contentFrame = snapshot.frame
        object.zOrder = snapshot.zOrder
        object.createdAt = snapshot.createdAt
        object.updatedAt = .now
        object.note = note
        // 保存前後で objectID が変わるとレイヤーのビューが作り直されるため先に確定させる
        try? context.obtainPermanentIDs(for: [object])
        saveAndRefresh(context: context, bridge: bridge)
    }

    private static func saveAndRefresh(
        context: NSManagedObjectContext, bridge: CanvasUndoBridge?
    ) {
        if context.hasChanges {
            try? context.save()
        }
        bridge?.refresh()
    }
}
