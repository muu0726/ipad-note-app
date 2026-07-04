import SwiftUI
import CoreData
import UIKit

/// グリッドのフォルダタイル
struct FolderCell: View {
    @ObservedObject var folder: Folder
    @ObservedObject var actions: LibraryActionCoordinator
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemBackground))
                        .aspectRatio(4 / 3, contentMode: .fit)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                }
                Text(folder.displayName)
                    .font(.callout)
                    .lineLimit(1)
                Text("\(folder.visibleItemCount) 項目")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            ItemContextMenu(item: .folder(folder), actions: actions)
        }
    }
}

/// グリッドのノートタイル(サムネイルは ② キャンバス実装後に thumbnailData から生成)
struct NoteCell: View {
    @ObservedObject var note: NoteFile
    @ObservedObject var actions: LibraryActionCoordinator
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemBackground))
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color(.separator), lineWidth: 0.5)
                        )
                    if let data = note.thumbnailData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Image(systemName: "scribble.variable")
                            .font(.system(size: 36))
                            .foregroundStyle(.quaternary)
                    }
                }
                Text(note.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                Text(note.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            ItemContextMenu(item: .note(note), actions: actions)
        }
    }
}

/// グリッド末尾の「＋ 新規作成」タイル
struct AddNoteTile: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                        .foregroundStyle(.tertiary)
                        .aspectRatio(4 / 3, contentMode: .fit)
                    Image(systemName: "plus")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
                Text("新規ノート")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("")
                    .font(.caption2)
            }
        }
        .buttonStyle(.plain)
    }
}
