import Observation
import PencilKit
import Vision

enum CanvasMode {
    /// The Pencil draws. A finger selects, moves and deletes images and text boxes.
    case draw
    /// A tap places a text box. The Pencil writes into text boxes with Scribble.
    case text
    /// The Pencil circles handwriting to turn it into a text box.
    case convert
}

@Observable final class NoteModel {
    let url: URL
    var meta: NoteMeta { didSet { saveSoon() } }
    var mode = CanvasMode.draw
    var textSize = TextSize.medium
    /// Shown to the user as an alert.
    var message: String?
    private(set) var drawing: PKDrawing
    /// Goes up when the drawing is replaced from outside the canvas, so the canvas reloads it.
    private(set) var drawingVersion = 0
    var scrollTarget: Int?
    /// The middle of the screen in note coordinates. New PDF pages and images go where you are looking.
    @ObservationIgnored var visibleCenter = CGPoint.zero
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        meta = (try? NoteFile.meta(at: url)) ?? NoteMeta(title: "", background: .grid, pageCount: 1)
        drawing = NoteFile.drawing(at: url)
    }

    func drawingChanged(_ drawing: PKDrawing) {
        self.drawing = drawing
        saveSoon()
    }

    /// Saves a second after the last change instead of on every one. Leaving the note or the app saves straight away.
    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { save() }
        }
    }

    func save() {
        saveTask?.cancel()
        do {
            try NoteFile.save(meta, drawing: drawing, to: url)
        } catch {
            message = "This note could not be saved: \(error.localizedDescription)"
        }
    }

    func addPage() {
        meta.pageCount += 1
        scrollTarget = meta.pageCount - 1
    }

    /// See `PKDrawing.rearranged(_:)`.
    func rearrange(_ order: [Int]) {
        drawing = drawing.rearranged(order)
        drawingVersion += 1
        meta = meta.rearranged(order)
    }

    var currentPage: Int { min(max(Page.index(at: visibleCenter.y), 0), meta.pageCount - 1) }

    /// Inserts the PDF's pages after the current page. In a note that is still one empty page, they replace it.
    func insertPDF(_ data: Data) throws {
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), pdf.numberOfPages > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let file = try NoteFile.store(data, ext: "pdf", in: url)
        let empty = meta.pageCount == 1 && drawing.strokes.isEmpty && meta.images.isEmpty && meta.texts.isEmpty && meta.pdfPages.isEmpty
        let at = empty ? 0 : currentPage + 1
        let order = Array(0..<at) + Array(repeating: -1, count: pdf.numberOfPages) + Array(at..<(empty ? 0 : meta.pageCount))
        var newMeta = meta.rearranged(order)
        newMeta.pdfPages += (0..<pdf.numberOfPages).map { PDFPageRef(page: at + $0, file: file, index: $0) }
        drawing = drawing.rearranged(order)
        drawingVersion += 1
        meta = newMeta
        scrollTarget = at
    }

    /// Places the image in the middle of the current page, at most 600 points wide or high.
    func insertImage(_ data: Data) throws {
        guard let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        let pixels = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * pixels, height: image.size.height * pixels)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = image.cgImage?.isOpaque ?? false
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let heic = resized.heicData() else { throw CocoaError(.fileWriteUnknown) }
        let file = try NoteFile.store(heic, ext: "heic", in: url)
        let fit = min(1, 600 / size.width, 600 / size.height)
        let width = size.width * fit, height = size.height * fit
        let page = Page.rect(currentPage)
        let y = min(max(visibleCenter.y - height / 2, page.minY), page.maxY - height)
        meta.images.append(ImageItem(file: file, frame: CGRect(x: page.midX - width / 2, y: y, width: width, height: height)))
    }

    /// Replaces the ink inside `loop` with a text box of the recognized handwriting, in the same spot and color.
    /// Returns false when there is no ink inside, nothing was recognized, or the drawing changed during recognition.
    func convertHandwriting(in loop: CGPath) async -> Bool {
        let original = drawing
        let inside = drawing.strokes.map { loop.contains(CGPoint(x: $0.renderBounds.midX, y: $0.renderBounds.midY)) }
        let strokes = zip(drawing.strokes, inside).filter(\.1).map(\.0)
        guard let first = strokes.first, let lines = await Handwriting.recognize(PKDrawing(strokes: strokes)), drawing == original else { return false }
        let bounds = PKDrawing(strokes: strokes).bounds
        let lineHeight = bounds.height / CGFloat(lines.count)
        let size = [TextSize.small, .medium, .large].min { abs($0.points - lineHeight * 0.75) < abs($1.points - lineHeight * 0.75) } ?? .medium
        drawing = PKDrawing(strokes: zip(drawing.strokes, inside).filter { !$0.1 }.map(\.0))
        drawingVersion += 1
        meta.texts.append(TextItem(
            text: lines.joined(separator: "\n"), origin: bounds.origin, size: size, color: first.ink.color.components,
            handwriting: PKDrawing(strokes: strokes).dataRepresentation()
        ))
        return true
    }

    /// Replaces a text box made from handwriting with that handwriting again, where the box is now.
    func revertToHandwriting(_ index: Int) {
        let item = meta.texts[index]
        guard let data = item.handwriting, let ink = try? PKDrawing(data: data) else { return }
        let move = CGAffineTransform(translationX: item.origin.x - ink.bounds.minX, y: item.origin.y - ink.bounds.minY)
        drawing = PKDrawing(strokes: drawing.strokes + ink.transformed(using: move).strokes)
        drawingVersion += 1
        meta.texts.remove(at: index)
    }

    /// Writes the whole note as a PDF to a temporary file named after the note.
    func exportPDF() throws -> URL {
        try export(Page.pdf(of: drawing, meta: meta, note: url), as: "\(meta.title).pdf")
    }

    /// Writes the page you are looking at as a PNG of 2480 pixels wide, A4 at 300 dpi.
    func exportPNG() throws -> URL {
        let image = Page.image(of: drawing, page: currentPage, meta: meta, note: url, width: 1240)
        guard let png = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return try export(png, as: "\(meta.title) page \(currentPage + 1).png")
    }

    private func export(_ data: Data, as name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name.replacingOccurrences(of: "/", with: "-"))
        try data.write(to: file)
        return file
    }
}

enum Handwriting {
    /// The recognized lines from top to bottom, English only, on the device. Nil when nothing was recognized.
    static func recognize(_ drawing: PKDrawing) async -> [String]? {
        let bounds = drawing.bounds.insetBy(dx: -20, dy: -20)
        let image = UIGraphicsImageRenderer(size: bounds.size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawing.image(from: bounds, scale: 2).draw(in: CGRect(origin: .zero, size: bounds.size))
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        let observations = (try? await request.perform(on: cgImage)) ?? []
        let lines = observations
            .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines
    }
}

extension CGImage {
    var isOpaque: Bool { [.none, .noneSkipFirst, .noneSkipLast].contains(alphaInfo) }
}

extension UIColor {
    var components: [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }
}
