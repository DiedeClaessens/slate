import PencilKit
import UIKit

enum Background: String, Codable {
    case black, grid

    var pageColor: UIColor { self == .black ? .black : .white }
    var gapColor: UIColor { self == .black ? UIColor(white: 0.15, alpha: 1) : UIColor(white: 0.88, alpha: 1) }
    /// PencilKit shows ink in the dark style as inverted, so black ink turns white on a black page.
    var style: UIUserInterfaceStyle { self == .black ? .dark : .light }
}

/// All pages of a note share one drawing, stacked top to bottom `Page.stride` apart.
enum Page {
    /// A4 proportions. The width is 210 mm, so 42 grid squares of 5 mm fit across.
    static let size = CGSize(width: 1000, height: 1414)
    static let gap: CGFloat = 32
    static let stride = size.height + gap
    static let gridSpacing = size.width / 42
    static let gridColor = UIColor(white: 0, alpha: 0.08)

    static func rect(_ index: Int) -> CGRect {
        CGRect(origin: CGPoint(x: 0, y: CGFloat(index) * stride), size: size)
    }

    static func height(of count: Int) -> CGFloat { CGFloat(count) * stride - gap }

    static func index(at y: CGFloat) -> Int { Int(y / stride) }

    static func gridPath(width: CGFloat, height: CGFloat, spacing: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for x in Swift.stride(from: spacing, to: width, by: spacing) {
            path.addLines(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: height)])
        }
        for y in Swift.stride(from: spacing, to: height, by: spacing) {
            path.addLines(between: [CGPoint(x: 0, y: y), CGPoint(x: width, y: y)])
        }
        return path
    }

    /// Draws the PDF page as large as fits, centered in `rect`. `context` has UIKit's flipped coordinates.
    nonisolated static func draw(_ pdf: CGPDFPage, in rect: CGRect, context: CGContext) {
        let box = pdf.getBoxRect(.cropBox)
        let turned = pdf.rotationAngle % 180 != 0
        let source = CGRect(origin: .zero, size: turned ? CGSize(width: box.height, height: box.width) : box.size)
        let scale = min(rect.width / source.width, rect.height / source.height)
        context.saveGState()
        context.translateBy(x: rect.midX - source.width * scale / 2, y: rect.midY + source.height * scale / 2)
        context.scaleBy(x: scale, y: -scale)
        context.concatenate(pdf.getDrawingTransform(.cropBox, rect: source, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(pdf)
        context.restoreGState()
    }

    /// The parts of the note that export as pages: its A4 pages, or everything on a whiteboard as one page.
    static func rects(of drawing: PKDrawing, meta: NoteMeta) -> [CGRect] {
        meta.whiteboard ? [Board.rect(of: drawing, meta: meta)] : (0..<meta.pageCount).map(rect)
    }

    /// Draws the part `bounds` of the note with its top-left corner at the origin, at `scale` points per note point, like the screen shows it.
    /// The ink is a bitmap with `pixels` pixels per point. With `jpeg` set, opaque images are drawn as JPEG, which keeps PDFs small.
    static func draw(_ bounds: CGRect, of drawing: PKDrawing, meta: NoteMeta, note: URL, scale: CGFloat, pixels: CGFloat = 2, jpeg: Bool = false, in context: CGContext) {
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.clip(to: bounds)
        meta.background.pageColor.setFill()
        context.fill(bounds)
        if meta.background == .grid {
            context.saveGState()
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.addPath(gridPath(width: bounds.width, height: bounds.height, spacing: gridSpacing))
            context.setStrokeColor(gridColor.cgColor)
            context.setLineWidth(0.5 / scale)
            context.strokePath()
            context.restoreGState()
        }
        if let ref = meta.pdfPages.first(where: { rect($0.page) == bounds }),
           let pdf = CGPDFDocument(NoteFile.file(ref.file, in: note) as CFURL)?.page(at: ref.index + 1) {
            UIColor.white.setFill()
            context.fill(bounds)
            draw(pdf, in: bounds, context: context)
        }
        for item in meta.images where item.frame.intersects(bounds) {
            guard var image = UIImage(contentsOfFile: NoteFile.file(item.file, in: note).path) else { continue }
            if jpeg, image.cgImage?.isOpaque == true, let data = image.jpegData(compressionQuality: 0.85), let compressed = UIImage(data: data) {
                image = compressed
            }
            image.draw(in: item.frame)
        }
        // Only the area with ink becomes a bitmap, which keeps exported PDFs small.
        // A large whiteboard gets coarser ink, so the bitmap stays under about 50 million pixels.
        let ink = PKDrawing(strokes: drawing.strokes.filter { $0.renderBounds.intersects(bounds) }).bounds.intersection(bounds)
        if !ink.isEmpty {
            let resolution = min(scale * pixels, (50_000_000 / (ink.width * ink.height)).squareRoot())
            UITraitCollection(userInterfaceStyle: meta.background.style).performAsCurrent {
                drawing.image(from: ink, scale: resolution).draw(in: ink)
            }
        }
        for item in meta.texts {
            let frame = item.frame(whiteboard: meta.whiteboard)
            guard frame.intersects(bounds) else { continue }
            NSAttributedString(string: item.text, attributes: item.attributes(dark: meta.background == .black))
                .draw(with: frame, options: .usesLineFragmentOrigin, context: nil)
        }
        context.restoreGState()
    }

    static func image(of drawing: PKDrawing, in bounds: CGRect, meta: NoteMeta, note: URL, scale: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: bounds.width * scale, height: bounds.height * scale)).image { context in
            draw(bounds, of: drawing, meta: meta, note: note, scale: scale, in: context.cgContext)
        }
    }

    /// The whole note as A4 PDF pages, or a whiteboard as one page of the same scale. The ink is about 290 dpi.
    static func pdf(of drawing: PKDrawing, meta: NoteMeta, note: URL) -> Data {
        let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let scale = a4.width / size.width
        return UIGraphicsPDFRenderer(bounds: a4).pdfData { context in
            for bounds in rects(of: drawing, meta: meta) {
                context.beginPage(withBounds: meta.whiteboard ? CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale) : a4, pageInfo: [:])
                draw(bounds, of: drawing, meta: meta, note: note, scale: scale, pixels: 4, jpeg: true, in: context.cgContext)
            }
        }
    }
}

/// A whiteboard has no pages. It is so large that you never reach its edge, and a new one opens in the middle.
enum Board {
    static let size = CGSize(width: 100_000, height: 100_000)
    static let start = CGPoint(x: 50_000, y: 50_000)

    /// Everything on the board with a margin, on grid lines so an export's grid matches the screen. An empty board gives an empty A4 page.
    static func rect(of drawing: PKDrawing, meta: NoteMeta) -> CGRect {
        let content = ([drawing.bounds] + meta.images.map(\.frame) + meta.texts.map { $0.frame(whiteboard: true) })
            .filter { !$0.isEmpty }
            .reduce(CGRect.null) { $0.union($1) }
        let area = content.isNull ? CGRect(origin: start, size: Page.size) : content.insetBy(dx: -40, dy: -40)
        let step = Page.gridSpacing
        let x = floor(area.minX / step) * step, y = floor(area.minY / step) * step
        return CGRect(x: x, y: y, width: ceil((area.maxX - x) / step) * step, height: ceil((area.maxY - y) / step) * step)
    }
}

extension PKDrawing {
    /// Returns a drawing whose page `n` holds the ink of old page `order[n]`.
    /// Leaving a page out deletes it and listing it twice duplicates it.
    func rearranged(_ order: [Int]) -> PKDrawing {
        let byPage = Dictionary(grouping: strokes) { Page.index(at: $0.renderBounds.midY) }
        var result: [PKStroke] = []
        for (new, old) in order.enumerated() {
            let shift = CGAffineTransform(translationX: 0, y: CGFloat(new - old) * Page.stride)
            for var stroke in byPage[old] ?? [] {
                stroke.transform = stroke.transform.concatenating(shift)
                result.append(stroke)
            }
        }
        return PKDrawing(strokes: result)
    }
}
