import CoreData

/// Core Data スタックの管理(現在は **ローカル保存のみ**)。
/// モデル名は `InfiniteCanvas.xcdatamodeld` と一致させること。
///
/// 無料アカウント(Personal Team)では iCloud Capability を追加できないため
/// `NSPersistentContainer` を使用している。
/// 有料 Developer アカウント取得後に CloudKit 同期へ切り替える手順:
///   1. Signing & Capabilities で iCloud (CloudKit) + Background Modes (Remote notifications) を追加
///   2. 下の `NSPersistentContainer` を `NSPersistentCloudKitContainer` に変更
///   (履歴トラッキング等のオプションは設定済みのため、他の変更は不要)

/// モデル(.momd)を含むバンドルを解決するためのトークン(アプリ/テストどちらのプロセスでも app バンドルを指す)。
private final class BundleToken {}

struct PersistenceController {
    static let shared = PersistenceController()

    /// Core Data モデルは **1度だけ** ロードして全コンテナで共有する。
    /// 複数の `NSPersistentContainer(name:)` がそれぞれモデルを読み込むと、生成された
    /// NSManagedObject サブクラス(`NoteFile` 等)に対して複数の `NSEntityDescription` が
    /// 名乗りを上げ、`+[NoteFile entity]` が一意に解決できず
    /// 「Multiple NSEntityDescriptions claim the NSManagedObject subclass」警告や
    /// 「Failed to find a unique match」エラー(テスト時のクラッシュ/不安定化)の原因になる。
    /// テストは `PersistenceController(inMemory:)` を多数生成するため、この共有が必須。
    private static let managedObjectModel: NSManagedObjectModel = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "InfiniteCanvas", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url) else {
            fatalError("Core Data モデル 'InfiniteCanvas.momd' が見つかりません")
        }
        return model
    }()

    let container: NSPersistentContainer

    /// UIテスト等でクリーンな状態から始めたいときの起動フラグ。
    /// `launchEnvironment["RESET_STORE"] = "1"` もしくは `launchArguments` に `-ResetStore` を渡すと有効。
    /// 製品ビルドでは常に無効(フラグを渡す手段がない)。
    static var shouldResetStore: Bool {
        let info = ProcessInfo.processInfo
        return info.environment["RESET_STORE"] == "1" || info.arguments.contains("-ResetStore")
    }

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "InfiniteCanvas", managedObjectModel: Self.managedObjectModel)

        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("永続ストアの記述が見つかりません")
        }
        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
        } else if Self.shouldResetStore {
            // UIテスト用: 起動時に既存ストアを破棄してノートの蓄積をクリアする。
            // これを入れないと同一シミュレータでテストを繰り返すたびにライブラリへノートが
            // 溜まり、グリッド末尾の `add-note-tile` が画面外へ押し出されて作成系が落ちる。
            Self.destroyStore(at: description.url, model: Self.managedObjectModel)
        }
        // 将来の CloudKit 切り替えに備えて履歴トラッキングを最初から有効化しておく
        // (途中から有効化するとストア移行が必要になるため。ローカル運用でも無害)
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

    /// 指定 URL の SQLite ストア(と付随する -wal / -shm)を破棄する。UIテストの初期化用。
    private static func destroyStore(at url: URL?, model: NSManagedObjectModel) {
        guard let url else { return }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try? coordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
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
