import SwiftUI
import CoreData
import Combine
import PDFKit
import UIKit

/// テキストオブジェクトの中身。ダブルタップ(編集モード)で TextEditor に切り替わる。
struct TextObjectContent: View {
    @ObservedObject var object: CanvasObject
    let isEditing: Bool
    let zoom: CGFloat
    @Environment(\.managedObjectContext) private var context
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: Binding(
                    get: { object.textContent ?? "" },
                    set: { object.textContent = $0 }
                ))
                .font(.system(size: 17 * zoom))
                .scrollContentBackground(.hidden)
                .background(Color(.systemBackground).opacity(0.85))
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onDisappear {
                    object.updatedAt = .now
                    try? context.save()
                }
            } else {
                Text(displayText)
                    .font(.system(size: 17 * zoom))
                    .foregroundStyle(hasText ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(5 * zoom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var hasText: Bool { object.textContent?.isEmpty == false }
    private var displayText: String { hasText ? (object.textContent ?? "") : "テキストを入力" }
}

/// 画像オブジェクトの中身
struct ImageObjectContent: View {
    @ObservedObject var object: CanvasObject
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
            } else {
                ZStack {
                    Color(.secondarySystemBackground)
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
        .onAppear {
            if image == nil, let data = object.content {
                image = UIImage(data: data)
            }
        }
    }
}

/// PDF オブジェクトの中身(PDFKit)。
/// ダブルタップで編集モードにするとページめくり等の操作が有効になる(要件③)。
struct PDFObjectContent: UIViewRepresentable {
    let data: Data?
    let isInteractive: Bool

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.usePageViewController(true)
        if let data {
            view.document = PDFDocument(data: data)
        }
        view.isUserInteractionEnabled = isInteractive
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.isUserInteractionEnabled = isInteractive
    }
}
