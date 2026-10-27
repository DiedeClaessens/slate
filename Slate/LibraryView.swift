import SwiftUI

@main
struct SlateApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            LibraryView().environment(library)
        }
    }
}

enum Route: Hashable {
    case folder(String)
    case note(URL)
}

struct LibraryView: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            NotesGrid(folder: nil, path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .folder(let name): NotesGrid(folder: name, path: $path)
                    case .note(let url): NoteScreen(url: url)
                    }
                }
        }
    }
}

private enum Prompt {
    case newFolder, renameFolder(String), renameNote(NoteItem)

    var title: String {
        switch self {
        case .newFolder: "New folder"
        case .renameFolder: "Rename folder"
        case .renameNote: "Rename note"
        }
    }
}

struct NotesGrid: View {
    let folder: String?
    @Binding var path: [Route]
    @Environment(Library.self) private var library
    @State private var search = ""
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var deleting: NoteItem?
    @State private var failure: String?

    /// Searching from the top level looks through every folder.
    private var notes: [NoteItem] {
        library.notes.filter { note in
            if search.isEmpty { return note.folder == folder }
            return (folder == nil || note.folder == folder) && note.title.localizedStandardContains(search)
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 28)], spacing: 28) {
                if folder == nil && search.isEmpty {
                    ForEach(library.folders, id: \.self) { name in
                        Button { path.append(.folder(name)) } label: {
                            Tile(title: name, subtitle: "\(library.notes.count { $0.folder == name }) notes") {
                                Image(systemName: "folder.fill").font(.system(size: 64)).foregroundStyle(.tint)
                            }
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { ask(.renameFolder(name), name) }
                            Button("Delete folder, keep notes", systemImage: "folder.badge.minus", role: .destructive) {
                                attempt { try library.deleteFolder(name) }
                            }
                        }
                    }
                }
                ForEach(notes) { note in
                    Button { path.append(.note(note.url)) } label: {
                        Tile(title: note.title, subtitle: note.modified.formatted(date: .abbreviated, time: .shortened)) {
                            if let image = UIImage(contentsOfFile: NoteFile.thumbnail(at: note.url).path) {
                                Image(uiImage: image).resizable().scaledToFit()
                            }
                        }
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { ask(.renameNote(note), note.title) }
                        Menu("Move to", systemImage: "folder") {
                            Button("No folder") { attempt { try library.move(note, to: nil) } }.disabled(note.folder == nil)
                            ForEach(library.folders, id: \.self) { name in
                                Button(name) { attempt { try library.move(note, to: name) } }.disabled(note.folder == name)
                            }
                        }
                        Button("Duplicate", systemImage: "plus.square.on.square") { attempt { try library.duplicate(note) } }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = note }
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(28)
        }
        .navigationTitle(folder ?? "Slate")
        .searchable(text: $search)
        .toolbar {
            if folder == nil {
                Button("New folder", systemImage: "folder.badge.plus") { ask(.newFolder, "") }
            }
            Menu("New note", systemImage: "square.and.pencil") {
                Button("Black", systemImage: "square.fill") { newNote(.black) }
                Button("Grid", systemImage: "squareshape.split.3x3") { newNote(.grid) }
            }
        }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { answer() }
        }
        .alert("That didn't work", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {} message: {
            Text(failure ?? "")
        }
        .confirmationDialog(
            "Delete \"\(deleting?.title ?? "")\"?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete note", role: .destructive) {
                if let deleting { attempt { try library.delete(deleting) } }
            }
        }
    }

    private func ask(_ newPrompt: Prompt, _ text: String) {
        promptText = text
        prompt = newPrompt
    }

    private func answer() {
        let text = promptText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let prompt else { return }
        switch prompt {
        case .newFolder: attempt { try library.createFolder(text) }
        case .renameFolder(let name): attempt { try library.renameFolder(name, to: text) }
        case .renameNote(let note): attempt { try library.rename(note, to: text) }
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { failure = error.localizedDescription }
    }

    private func newNote(_ background: Background) {
        attempt { path.append(.note(try library.createNote(background: background, in: folder))) }
    }
}

private struct Tile<Preview: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let preview: Preview

    var body: some View {
        VStack(spacing: 6) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(Page.size.width / Page.size.height, contentMode: .fit)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .clipShape(.rect(cornerRadius: 8))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }
}
