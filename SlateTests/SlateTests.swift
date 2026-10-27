import Foundation
import PencilKit
import Testing
import UIKit
@testable import Slate

private func line(atY y: CGFloat) -> PKStroke {
    let points = [CGPoint(x: 100, y: y), CGPoint(x: 300, y: y)].enumerated().map { index, point in
        PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))
}

private func heights(_ drawing: PKDrawing) -> [CGFloat] {
    drawing.strokes.map { $0.renderBounds.midY.rounded() }
}

private func emptyLibrary() throws -> Library {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return Library(root: root)
}

@Test func movingTheLastPageToTheFrontCarriesItsInk() {
    let drawing = PKDrawing(strokes: [line(atY: 100), line(atY: 2 * 1446 + 100)])
    #expect(heights(drawing.rearranged([2, 0, 1])) == [100, 1546])
}

@Test func duplicatingAPageCopiesItsInkOntoTheNextPage() {
    let drawing = PKDrawing(strokes: [line(atY: 100)])
    #expect(heights(drawing.rearranged([0, 0])) == [100, 1546])
}

@Test func deletingAPageRemovesItsInkAndPullsLaterPagesUp() {
    let drawing = PKDrawing(strokes: [line(atY: 100), line(atY: 1546), line(atY: 2 * 1446 + 200)])
    #expect(heights(drawing.rearranged([0, 2])) == [100, 1646])
}

@Test func deletingAFolderKeepsItsNotes() throws {
    let library = try emptyLibrary()
    _ = try library.createNote(background: .grid, in: nil)
    try library.createFolder("School")
    try library.rename(library.notes[0], to: "Maths")
    try library.move(library.notes[0], to: "School")
    #expect(library.notes.map { "\($0.folder ?? "-") \($0.title)" } == ["School Maths"])

    _ = try Library(root: library.root).createNote(background: .grid, in: "School")
    try Data("scan".utf8).write(to: library.root.appending(path: "School/scan.pdf"))

    try library.deleteFolder("School")
    #expect(library.folders == [])
    #expect(library.notes.map(\.folder) == [nil, nil])
    #expect(library.notes.map(\.title).contains("Maths"))
    #expect(try String(contentsOf: library.root.appending(path: "scan.pdf"), encoding: .utf8) == "scan")
}

@Test func aFolderNameCannotLeaveTheLibrary() throws {
    let library = try emptyLibrary()
    try library.createFolder("Work")
    _ = try library.createNote(background: .grid, in: "Work")
    #expect(throws: CocoaError.self) { try library.renameFolder("Work", to: "School/Work") }
    #expect(throws: CocoaError.self) { try library.createFolder(".hidden") }
    #expect(library.folders == ["Work"])
    #expect(library.notes.map(\.folder) == ["Work"])
}

@Test func openingANoteWithoutChangingItKeepsItsPlace() throws {
    let library = try emptyLibrary()
    let old = try library.createNote(background: .grid, in: nil)
    let new = try library.createNote(background: .grid, in: nil)
    NoteModel(url: old).save()
    library.reload()
    #expect(library.notes.map(\.url.lastPathComponent) == [new.lastPathComponent, old.lastPathComponent])
}

@Test func aTextBoxThatGrowsPastItsPageMovesWithThatPage() {
    var meta = NoteMeta(title: "", background: .grid, pageCount: 1)
    meta.texts = [TextItem(text: Array(repeating: "line", count: 10).joined(separator: "\n"), origin: CGPoint(x: 50, y: 1320), size: .large, color: [0, 0, 0, 1])]
    #expect(meta.rearranged([0, 0]).texts.map(\.origin.y) == [1320, 1320 + 1446])
}

@Test func duplicatingANoteCopiesItsInk() throws {
    let library = try emptyLibrary()
    let url = try library.createNote(background: .black, in: nil)
    try NoteFile.save(NoteFile.meta(at: url), drawing: PKDrawing(strokes: [line(atY: 100)]), to: url)
    library.reload()
    try library.duplicate(library.notes[0])

    let copy = try #require(library.notes.first { $0.title.hasSuffix(" copy") })
    #expect(copy.url != url)
    #expect(heights(NoteFile.drawing(at: copy.url)) == [100])
}

private func pdf(pages: Int) -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
        for _ in 0..<pages { context.beginPage() }
    }
}

private func describe(_ meta: NoteMeta) -> [String] {
    meta.pdfPages.map { "page \($0.page) pdf \($0.index)" }
        + meta.images.map { "page \($0.page) image at \(Int($0.frame.minY))" }
        + meta.texts.map { "page \($0.page) text at \(Int($0.origin.y))" }
}

@Test func notesSavedBeforePDFsAndImagesStillOpen() throws {
    let json = Data(#"{"title":"Old","background":"black","pageCount":2}"#.utf8)
    let meta = try JSONDecoder().decode(NoteMeta.self, from: json)
    #expect(meta == NoteMeta(title: "Old", background: .black, pageCount: 2))
}

@Test func insertingAPDFPutsItsPagesAfterTheCurrentPageAndMovesLaterInkDown() throws {
    let library = try emptyLibrary()
    let url = try library.createNote(background: .grid, in: nil)
    try NoteFile.save(NoteMeta(title: "Maths", background: .grid, pageCount: 2), drawing: PKDrawing(strokes: [line(atY: 100), line(atY: 1546)]), to: url)
    let model = NoteModel(url: url)
    try model.insertPDF(pdf(pages: 2))

    #expect(model.meta.pageCount == 4)
    #expect(describe(model.meta) == ["page 1 pdf 0", "page 2 pdf 1"])
    #expect(heights(model.drawing) == [100, 3 * 1446 + 100])
    model.save()
    #expect(describe(NoteModel(url: url).meta) == ["page 1 pdf 0", "page 2 pdf 1"])
}

@Test func insertingAPDFIntoAnEmptyNoteReplacesTheBlankPage() throws {
    let library = try emptyLibrary()
    let model = NoteModel(url: try library.createNote(background: .black, in: nil))
    try model.insertPDF(pdf(pages: 3))

    #expect(model.meta.pageCount == 3)
    #expect(describe(model.meta) == ["page 0 pdf 0", "page 1 pdf 1", "page 2 pdf 2"])
}

@Test func insertingSomethingThatIsNotAPDFFails() throws {
    let library = try emptyLibrary()
    let model = NoteModel(url: try library.createNote(background: .grid, in: nil))
    #expect(throws: CocoaError.self) { try model.insertPDF(Data("not a pdf".utf8)) }
    #expect(model.meta.pageCount == 1)
}

@Test func anImageGoesOnThePageYouAreLookingAt() throws {
    let library = try emptyLibrary()
    let url = try library.createNote(background: .grid, in: nil)
    let model = NoteModel(url: url)
    model.addPage()
    model.visibleCenter = CGPoint(x: 500, y: 1446 + 700)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let photo = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800), format: format).image { _ in }
    try model.insertImage(try #require(photo.pngData()))

    #expect(model.meta.images.map(\.frame) == [CGRect(x: 200, y: 1446 + 500, width: 600, height: 400)])
    #expect(UIImage(contentsOfFile: NoteFile.file(model.meta.images[0].file, in: url).path)?.size == CGSize(width: 1200, height: 800))
}

@Test func movingAPageCarriesItsPDFPageImagesAndText() {
    var meta = NoteMeta(title: "", background: .grid, pageCount: 2)
    meta.pdfPages = [PDFPageRef(page: 0, file: "a.pdf", index: 4)]
    meta.images = [ImageItem(file: "b.heic", frame: CGRect(x: 0, y: 1446 + 10, width: 100, height: 100))]
    meta.texts = [TextItem(text: "Hi", origin: CGPoint(x: 50, y: 20), size: .medium, color: [0, 0, 0, 1])]
    #expect(describe(meta.rearranged([1, 0])) == ["page 1 pdf 4", "page 0 image at 10", "page 1 text at 1466"])
    #expect(describe(meta.rearranged([0, 1, 1])) == ["page 0 pdf 4", "page 1 image at 1456", "page 2 image at 2902", "page 0 text at 20"])
}

@Test func deletingTheLastImageRemovesItsFile() throws {
    let library = try emptyLibrary()
    let url = try library.createNote(background: .grid, in: nil)
    let model = NoteModel(url: url)
    let photo = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
    try model.insertImage(try #require(photo.pngData()))
    let file = NoteFile.file(model.meta.images[0].file, in: url)
    #expect(FileManager.default.fileExists(atPath: file.path))

    model.meta.images = []
    model.save()
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

private func outlines(of text: String, at origin: CGPoint, size: CGFloat) -> [PKStroke] {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    var strokes: [PKStroke] = []
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &positions)
        for (glyph, position) in zip(glyphs, positions) {
            guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
            var points: [CGPoint] = []
            func finish() {
                if points.count > 1 { strokes.append(stroke(through: points)) }
                points = []
            }
            path.applyWithBlock { element in
                let p = element.pointee.points
                let put = { (q: CGPoint) in points.append(CGPoint(x: origin.x + position.x + q.x, y: origin.y - q.y)) }
                switch element.pointee.type {
                case .moveToPoint: finish(); put(p[0])
                case .addLineToPoint: put(p[0])
                case .addQuadCurveToPoint: put(p[1])
                case .addCurveToPoint: put(p[2])
                case .closeSubpath: if let first = points.first { points.append(first) }
                @unknown default: break
                }
            }
            finish()
        }
    }
    return strokes
}

private func stroke(through points: [CGPoint]) -> PKStroke {
    let path = points.enumerated().map { index, point in
        PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKStroke(ink: PKInk(.pen, color: .blue), path: PKStrokePath(controlPoints: path, creationDate: .now))
}

@Test func circledHandwritingBecomesATextBoxInItsPlace() async throws {
    let library = try emptyLibrary()
    let url = try library.createNote(background: .grid, in: nil)
    let drawing = PKDrawing(strokes: outlines(of: "HELLO", at: CGPoint(x: 100, y: 300), size: 90) + [line(atY: 1000)])
    try NoteFile.save(NoteFile.meta(at: url), drawing: drawing, to: url)
    let model = NoteModel(url: url)

    #expect(await model.convertHandwriting(in: CGPath(rect: CGRect(x: 50, y: 150, width: 700, height: 250), transform: nil)))
    #expect(model.meta.texts.map(\.text) == ["HELLO"])
    #expect(model.meta.texts.map(\.size) == [.large])
    #expect(heights(model.drawing) == [1000])
    model.save()
    #expect(NoteModel(url: url).meta.texts.map(\.text) == ["HELLO"])
}

@Test func circlingEmptyPaperChangesNothing() async throws {
    let library = try emptyLibrary()
    let url = try library.createNote(background: .grid, in: nil)
    try NoteFile.save(NoteFile.meta(at: url), drawing: PKDrawing(strokes: [line(atY: 1000)]), to: url)
    let model = NoteModel(url: url)

    #expect(await !model.convertHandwriting(in: CGPath(rect: CGRect(x: 0, y: 0, width: 500, height: 500), transform: nil)))
    #expect(model.meta.texts.isEmpty)
    #expect(heights(model.drawing) == [1000])
}

@Test func aTextBoxNearTheRightEdgeWrapsInsideThePage() {
    let short = TextItem(text: "one", origin: CGPoint(x: 700, y: 0), size: .medium, color: [0, 0, 0, 1])
    let long = TextItem(text: "one two three four five", origin: CGPoint(x: 700, y: 0), size: .medium, color: [0, 0, 0, 1])
    #expect(long.frame.maxX <= 960)
    #expect(long.frame.height >= short.frame.height * 2)
}

@Test func exportingANoteGivesOneA4PDFPagePerPage() throws {
    let library = try emptyLibrary()
    let model = NoteModel(url: try library.createNote(background: .grid, in: nil))
    model.meta.title = "Maths 3/4"
    model.addPage()
    model.addPage()
    let url = try model.exportPDF()

    #expect(url.lastPathComponent == "Maths 3-4.pdf")
    let pdf = try #require(CGPDFDocument(url as CFURL))
    #expect(pdf.numberOfPages == 3)
    #expect(pdf.page(at: 1)?.getBoxRect(.mediaBox).size == CGSize(width: 595.28, height: 841.89))
}

private func pixel(of image: CGImage, at point: CGPoint) -> [UInt8] {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.draw(image, in: CGRect(x: -point.x, y: point.y + 1 - CGFloat(image.height), width: CGFloat(image.width), height: CGFloat(image.height)))
    return pixel
}

@Test func anExportedPageLooksLikeTheScreenAtPrintSize() throws {
    let library = try emptyLibrary()
    let black = try #require(UIImage(contentsOfFile: NoteModel(url: library.createNote(background: .black, in: nil)).exportPNG().path)?.cgImage)
    let grid = try #require(UIImage(contentsOfFile: NoteModel(url: library.createNote(background: .grid, in: nil)).exportPNG().path)?.cgImage)

    #expect(black.width == 2480)
    #expect(pixel(of: black, at: CGPoint(x: 10, y: 10)) == [0, 0, 0, 255])
    #expect(pixel(of: grid, at: CGPoint(x: 10, y: 10)) == [255, 255, 255, 255])
}

@Test func textMadeFromHandwritingTurnsBackIntoThatHandwritingWhereTheBoxIs() async throws {
    let library = try emptyLibrary()
    let url = try library.createNote(background: .grid, in: nil)
    try NoteFile.save(NoteFile.meta(at: url), drawing: PKDrawing(strokes: outlines(of: "HELLO", at: CGPoint(x: 100, y: 300), size: 90)), to: url)
    let model = NoteModel(url: url)
    let before = model.drawing.bounds
    #expect(await model.convertHandwriting(in: CGPath(rect: CGRect(x: 50, y: 150, width: 700, height: 250), transform: nil)))
    model.meta.texts[0].origin.y += 500

    model.revertToHandwriting(0)
    #expect(model.meta.texts.isEmpty)
    #expect(model.drawing.bounds.integral == before.offsetBy(dx: 0, dy: 500).integral)
    model.save()
    #expect(NoteModel(url: url).drawing.strokes.count == model.drawing.strokes.count)
}

@Test func aNoteWithOnlyTextKeepsItsTextWhenAPDFIsInserted() throws {
    let model = NoteModel(url: try emptyLibrary().createNote(background: .grid, in: nil))
    model.meta.texts = [TextItem(text: "Lecture 3", origin: CGPoint(x: 50, y: 50), size: .large, color: [0, 0, 0, 1])]
    try model.insertPDF(pdf(pages: 1))
    #expect(model.meta.pageCount == 2)
    #expect(model.meta.texts.map(\.text) == ["Lecture 3"])
}

@Test func deletingTheSelectedImageRemovesItFromTheScreen() {
    let objects = ObjectsView()
    let note = FileManager.default.temporaryDirectory
    var meta = NoteMeta(title: "", background: .grid, pageCount: 1)
    meta.images = [ImageItem(file: "a.heic", frame: CGRect(x: 100, y: 100, width: 200, height: 200))]
    objects.imagesChanged = { meta.images = $0 }
    objects.update(meta: meta, note: note, zoom: 1, mode: .draw)
    objects.tapped(at: CGPoint(x: 150, y: 150))
    objects.tapped(at: CGPoint(x: 278, y: 76))
    objects.update(meta: meta, note: note, zoom: 1, mode: .draw)
    #expect(meta.images.isEmpty)
    #expect(objects.subviews.filter { $0 is UIImageView }.isEmpty)
}

@Test func aNewTextBoxSurvivesAddingAPageBeforeAnythingIsTyped() throws {
    let window = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow)
    let objects = ObjectsView()
    window.addSubview(objects.textLayer)
    defer { objects.textLayer.removeFromSuperview() }
    let note = FileManager.default.temporaryDirectory
    var meta = NoteMeta(title: "", background: .grid, pageCount: 1)
    objects.textsChanged = { meta.texts = $0 }
    objects.update(meta: meta, note: note, zoom: 1, mode: .text)
    objects.editText(at: CGPoint(x: 100, y: 100), size: .medium, color: .black)
    meta.pageCount = 2
    objects.update(meta: meta, note: note, zoom: 1, mode: .text)
    #expect(objects.editing)
    objects.textLayer.endEditing(true)
    #expect(meta.texts.isEmpty)
}

@Test func aPDFPageOnScreenDrawsItsContent() async throws {
    let window = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow)
    let red = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { context in
        context.beginPage()
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    }
    let page = try #require(CGPDFDocument(CGDataProvider(data: red as CFData)!)?.page(at: 1))
    let view = PDFPageView(pdf: page, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    window.addSubview(view)
    defer { view.removeFromSuperview() }
    try await Task.sleep(for: .seconds(2))
    let screen = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: false) }
    #expect(pixel(of: try #require(screen.cgImage), at: CGPoint(x: 100, y: 100)) == [255, 0, 0, 255])
}
