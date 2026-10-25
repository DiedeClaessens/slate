import PhotosUI
import SwiftUI

struct NoteScreen: View {
    @State private var model: NoteModel
    @State private var showPages = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showExport = false
    @State private var exported: URL?
    @State private var photo: PhotosPickerItem?
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    init(url: URL) {
        _model = State(initialValue: NoteModel(url: url))
    }

    var body: some View {
        NoteCanvas(
            model: model, meta: model.meta, drawingVersion: model.drawingVersion, scrollTarget: model.scrollTarget,
            mode: model.mode, textSize: model.textSize,
            focused: !showPages && !showPhotos && !showFiles && !showExport && exported == nil
        )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle($model.meta.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle("Text", systemImage: "textformat", isOn: toggle(.text))
                    if model.mode == .text {
                        Button { model.textSize = model.textSize.next } label: {
                            Text(model.textSize.rawValue.capitalized)
                        }
                        .accessibilityLabel("Text size")
                    }
                    Toggle("Handwriting to text", systemImage: "text.viewfinder", isOn: toggle(.convert))
                    Button("Background", systemImage: "circle.lefthalf.filled") {
                        model.meta.background = model.meta.background == .black ? .grid : .black
                    }
                    Button("Insert photo", systemImage: "photo") { showPhotos = true }
                    Button("Insert PDF or image", systemImage: "doc.richtext") { showFiles = true }
                    Button("Pages", systemImage: "square.grid.2x2") { showPages = true }
                    Button("Add page", systemImage: "doc.badge.plus") { model.addPage() }
                    Button("Export", systemImage: "square.and.arrow.up") { showExport = true }
                        .confirmationDialog("Export", isPresented: $showExport) {
                            Button("Whole note as PDF") { share(model.exportPDF) }
                            Button("This page as PNG") { share(model.exportPNG) }
                        }
                }
            }
            .sheet(isPresented: $showPages) { PageOverview(model: model) }
            .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
            .onChange(of: photo) {
                guard let photo else { return }
                self.photo = nil
                Task {
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self) else { return }
                        try model.insertImage(data)
                    } catch {
                        model.message = "This photo could not be inserted."
                    }
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    try UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true ? model.insertPDF(data) : model.insertImage(data)
                } catch {
                    model.message = "This file could not be inserted."
                }
            }
            .alert(model.message ?? "", isPresented: Binding { model.message != nil } set: { if !$0 { model.message = nil } }) {}
            .sheet(isPresented: Binding { exported != nil } set: { if !$0 { exported = nil } }) {
                if let exported {
                    ShareSheet(url: exported) { self.exported = nil }
                }
            }
            .onChange(of: scenePhase) {
                if scenePhase != .active { model.save() }
            }
            .onDisappear {
                model.save()
                library.reload()
            }
    }

    private func toggle(_ mode: CanvasMode) -> Binding<Bool> {
        Binding { model.mode == mode } set: { model.mode = $0 ? mode : .draw }
    }

    private func share(_ export: () throws -> URL) {
        do {
            exported = try export()
        } catch {
            model.message = "The note could not be exported."
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let done: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in done() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct PageOverview: View {
    let model: NoteModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let count = model.meta.pageCount
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 24) {
                    ForEach(0..<count, id: \.self) { page in
                        VStack {
                            Image(uiImage: Page.image(of: model.drawing, page: page, meta: model.meta, note: model.url, width: 160))
                                .clipShape(.rect(cornerRadius: 6))
                                .shadow(radius: 2)
                            Text("\(page + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Page \(page + 1)")
                        .onTapGesture {
                            model.scrollTarget = page
                            dismiss()
                        }
                        .contextMenu {
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                var order = Array(0..<count)
                                order.insert(page, at: page)
                                model.rearrange(order)
                            }
                            if count > 1 {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    model.rearrange((0..<count).filter { $0 != page })
                                }
                            }
                        }
                        .draggable(String(page))
                        .dropDestination(for: String.self) { items, _ in
                            guard let from = items.first.flatMap({ Int($0) }), from != page else { return false }
                            var order = Array(0..<count)
                            order.move(fromOffsets: [from], toOffset: page > from ? page + 1 : page)
                            model.rearrange(order)
                            return true
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Pages")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
