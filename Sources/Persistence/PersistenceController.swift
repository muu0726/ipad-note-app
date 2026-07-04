import CoreData

/// Core Data + CloudKit スタックの管理。
/// モデル名は `InfiniteCanvas.xcdatamodeld` と一致させること。
struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "InfiniteCanvas")

        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("永続ストアの記述が見つかりません")
        }
        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
            description.cloudKitContainerOptions = nil
        }
        // CloudKit 同期に必須のオプション
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("永続ストアの読み込みに失敗: \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - プレビュー用(メモリ内ストア + サンプルデータ)

    @MainActor
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        func makeFolder(_ name: String, parent: Folder? = nil) -> Folder {
            let folder = Folder(context: context)
            folder.id = UUID()
            folder.name = name
            folder.createdAt = .now
            folder.updatedAt = .now
            folder.parent = parent
            return folder
        }
        func makeNote(_ title: String, folder: Folder? = nil) {
            let note = NoteFile(context: context)
            note.id = UUID()
            note.title = title
            note.createdAt = .now
            note.updatedAt = .now
            note.folder = folder
        }

        let university = makeFolder("大学ノート")
        let math = makeFolder("数学", parent: university)
        _ = makeFolder("物理", parent: university)
        _ = makeFolder("仕事")
        makeNote("微積分", folder: math)
        makeNote("線形代数", folder: math)
        makeNote("アイデアメモ")
        try? context.save()
        return controller
    }()
}
