import Foundation
import Observation
import PencilKit

struct NoteMeta: Codable, Equatable {
    var title: String
    var background: Background
    var pageCount: Int
    var pdfPages: [PDFPageRef] = []
    /// Later images are drawn on top.
    var images: [ImageItem] = []
    var texts: [TextItem] = []
}

extension NoteMeta {
    /// Notes saved before PDFs, images and text existed have no `pdfPages`, `images` or `texts`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        background = try container.decode(Background.self, forKey: .background)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        pdfPages = try container.decodeIfPresent([PDFPageRef].self, forKey: .pdfPages) ?? []
        images = try container.decodeIfPresent([ImageItem].self, forKey: .images) ?? []
        texts = try container.decodeIfPresent([TextItem].self, forKey: .texts) ?? []
    }

    /// See `PKDrawing.rearranged(_:)`. An index of -1 adds a blank page.
    func rearranged(_ order: [Int]) -> NoteMeta {
        var meta = self
        meta.pageCount = order.count
        meta.pdfPages = order.enumerated().flatMap { new, old in
            pdfPages.filter { $0.page == old }.map { PDFPageRef(page: new, file: $0.file, index: $0.index) }
        }
        meta.images = order.enumerated().flatMap { new, old in
            images.filter { $0.page == old }.map { ImageItem(file: $0.file, frame: $0.frame.offsetBy(dx: 0, dy: CGFloat(new - old) * Page.stride)) }
        }
        meta.texts = order.enumerated().flatMap { new, old in
            texts.filter { $0.page == old }.map { var text = $0; text.origin.y += CGFloat(new - old) * Page.stride; return text }
        }
        return meta
    }
}

/// Page `index` (from 0) of a PDF in the note's files folder, shown as the background of note page `page`.
struct PDFPageRef: Codable, Equatable {
    var page: Int
    var file: String
    var index: Int
}

/// An image in the note's files folder. The frame is in note coordinates, like the ink.
struct ImageItem: Codable, Equatable {
    var file: String
    var frame: CGRect
    var page: Int { Page.index(at: frame.midY) }
}

enum TextSize: String, Codable {
    case small, medium, large

    var points: CGFloat {
        switch self {
        case .small: 24
        case .medium: 36
        case .large: 56
        }
    }

    var next: TextSize {
        switch self {
        case .small: .medium
        case .medium: .large
        case .large: .small
        }
    }
}

/// A typed text box in note coordinates. It grows with the text up to the page's right margin, then the text wraps.
struct TextItem: Codable, Equatable {
    var text: String
    var origin: CGPoint
    var size: TextSize
    /// Red, green, blue and alpha in PencilKit's light style, like the ink.
    var color: [CGFloat]
    /// The ink this text was recognized from, in PencilKit's data format, so it can turn back into handwriting.
    var handwriting: Data?

    static let margin: CGFloat = 40

    /// The page the box starts on. Its bottom can grow past the page.
    var page: Int { Page.index(at: origin.y) }

    func attributes(dark: Bool) -> [NSAttributedString.Key: Any] {
        let light = UIColor(red: color[0], green: color[1], blue: color[2], alpha: color[3])
        return [.font: UIFont.systemFont(ofSize: size.points), .foregroundColor: dark ? PKInkingTool.convertColor(light, from: .light, to: .dark) : light]
    }

    var frame: CGRect {
        let available = max(Page.size.width - Self.margin - origin.x, size.points)
        // A trailing newline starts a line that would otherwise not be measured.
        let measured = text.isEmpty || text.hasSuffix("\n") ? text + " " : text
        let box = NSAttributedString(string: measured, attributes: attributes(dark: false))
            .boundingRect(with: CGSize(width: available, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, context: nil)
        return CGRect(origin: origin, size: CGSize(width: max(ceil(box.width), size.points), height: ceil(box.height)))
    }
}

/// A note is a `<uuid>.slate` folder with note.json, drawing.data, thumbnail.png and a files folder for PDFs and images.
enum NoteFile {
    static let ext = "slate"

    static func meta(at url: URL) throws -> NoteMeta {
        try JSONDecoder().decode(NoteMeta.self, from: Data(contentsOf: url.appending(path: "note.json")))
    }

    static func drawing(at url: URL) -> PKDrawing {
        (try? PKDrawing(data: Data(contentsOf: url.appending(path: "drawing.data")))) ?? PKDrawing()
    }

    static func thumbnail(at url: URL) -> URL { url.appending(path: "thumbnail.png") }

    static func file(_ name: String, in url: URL) -> URL { url.appending(path: "files/\(name)") }

    /// Writes the data under a new name and returns that name.
    static func store(_ data: Data, ext: String, in url: URL) throws -> String {
        let name = "\(UUID().uuidString).\(ext)"
        try FileManager.default.createDirectory(at: url.appending(path: "files"), withIntermediateDirectories: true)
        try data.write(to: file(name, in: url))
        return name
    }

    static func save(_ meta: NoteMeta, drawing: PKDrawing, to url: URL) throws {
        try JSONEncoder().encode(meta).write(to: url.appending(path: "note.json"), options: .atomic)
        try drawing.dataRepresentation().write(to: url.appending(path: "drawing.data"), options: .atomic)
        let image = Page.image(of: drawing, page: 0, meta: meta, note: url, width: 200)
        try image.pngData()?.write(to: thumbnail(at: url), options: .atomic)
        let used = Set(meta.pdfPages.map(\.file) + meta.images.map(\.file))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: "files").path)) ?? []
        for name in files where !used.contains(name) {
            try? FileManager.default.removeItem(at: file(name, in: url))
        }
    }
}

struct NoteItem: Identifiable, Hashable {
    let url: URL
    let folder: String?
    let title: String
    let modified: Date
    var id: URL { url }
}

/// The notes and folders in the app's Documents folder. Folders are one level deep.
@Observable final class Library {
    let root: URL
    private(set) var folders: [String] = []
    private(set) var notes: [NoteItem] = []

    init(root: URL = .documentsDirectory) {
        self.root = root
        reload()
    }

    func reload() {
        let fm = FileManager.default
        func contents(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        let top = contents(root)
        folders = top
            .filter { $0.pathExtension != NoteFile.ext && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let candidates = top.map { ($0, String?.none) } + folders.flatMap { name in contents(root.appending(path: name)).map { ($0, name) } }
        notes = candidates
            .compactMap { url, folder in
                guard url.pathExtension == NoteFile.ext, let meta = try? NoteFile.meta(at: url) else { return nil }
                let values = try? url.appending(path: "note.json").resourceValues(forKeys: [.contentModificationDateKey])
                return NoteItem(url: url, folder: folder, title: meta.title, modified: values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    private func directory(_ folder: String?) -> URL {
        folder.map { root.appending(path: $0) } ?? root
    }

    private func newNoteURL(in directory: URL) -> URL {
        directory.appending(path: "\(UUID().uuidString).\(NoteFile.ext)")
    }

    func createNote(background: Background, in folder: String?) throws -> URL {
        let url = newNoteURL(in: directory(folder))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let title = Date.now.formatted(.dateTime.day().month(.abbreviated).year())
        try NoteFile.save(NoteMeta(title: title, background: background, pageCount: 1), drawing: PKDrawing(), to: url)
        reload()
        return url
    }

    func rename(_ note: NoteItem, to title: String) throws {
        var meta = try NoteFile.meta(at: note.url)
        meta.title = title
        try JSONEncoder().encode(meta).write(to: note.url.appending(path: "note.json"), options: .atomic)
        reload()
    }

    func move(_ note: NoteItem, to folder: String?) throws {
        try FileManager.default.moveItem(at: note.url, to: directory(folder).appending(path: note.url.lastPathComponent))
        reload()
    }

    func duplicate(_ note: NoteItem) throws {
        let copy = newNoteURL(in: note.url.deletingLastPathComponent())
        try FileManager.default.copyItem(at: note.url, to: copy)
        try rename(NoteItem(url: copy, folder: note.folder, title: note.title, modified: .now), to: "\(note.title) copy")
    }

    func delete(_ note: NoteItem) throws {
        try FileManager.default.removeItem(at: note.url)
        reload()
    }

    /// A folder name must stay one visible folder in the library, so no slash, no leading dot and no note extension.
    private func newFolder(_ name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), URL(filePath: name).pathExtension != NoteFile.ext else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return root.appending(path: name)
    }

    func createFolder(_ name: String) throws {
        try FileManager.default.createDirectory(at: newFolder(name), withIntermediateDirectories: false)
        reload()
    }

    func renameFolder(_ name: String, to newName: String) throws {
        try FileManager.default.moveItem(at: directory(name), to: newFolder(newName))
        reload()
    }

    /// Moves the folder's notes to the top level before removing it, so no note is lost.
    /// It looks again first, because notes can be added in the Files app.
    func deleteFolder(_ name: String) throws {
        reload()
        for note in notes where note.folder == name {
            try FileManager.default.moveItem(at: note.url, to: root.appending(path: note.url.lastPathComponent))
        }
        try FileManager.default.removeItem(at: directory(name))
        reload()
    }
}
