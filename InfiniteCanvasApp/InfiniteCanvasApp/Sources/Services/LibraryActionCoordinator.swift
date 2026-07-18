import SwiftUI
import CoreData
import Combine

/// 作成・名前変更・移動・削除ダイアログの状態を一元管理するコーディネータ。
/// サイドバーとグリッドの両方から共有される。
@MainActor
final class LibraryActionCoordinator: ObservableObject {

    struct CreateRequest: Identifiable {
        enum Kind { case folder, note }
        let id = UUID()
        let kind: Kind
        let parent: Folder?
    }

    @Published var createRequest: CreateRequest?
    @Published var renameTarget: LibraryItem?
    @Published var moveTarget: LibraryItem?
    @Published var trashTarget: LibraryItem?
    /// 作成・名前変更ダイアログのテキストフィールド用
    @Published var nameText = ""

    // MARK: - PDF 直接インポート
    /// PDF ファイルピッカーの表示フラグ
    @Published var isPDFPickerPresented = false
    /// PDF から作成する新規ノートの親フォルダ(ピッカー確定時に使用)
    @Published var pdfImportParentFolder: Folder?

    /// PDF インポートを開始する(親フォルダを保持してファイルピッカーを開く)。
    func beginImportPDF(in parent: Folder?) {
        pdfImportParentFolder = parent
        isPDFPickerPresented = true
    }

    func beginCreateFolder(in parent: Folder?) {
        nameText = ""
        createRequest = CreateRequest(kind: .folder, parent: parent)
    }

    func beginCreateNote(in parent: Folder?) {
        nameText = ""
        createRequest = CreateRequest(kind: .note, parent: parent)
    }

    func beginRename(_ item: LibraryItem) {
        nameText = item.displayName
        renameTarget = item
    }

    func beginMove(_ item: LibraryItem) {
        moveTarget = item
    }

    func beginTrash(_ item: LibraryItem) {
        trashTarget = item
    }
}
