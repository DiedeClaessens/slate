import PencilKit
import SwiftUI

/// The passed values are only there so SwiftUI calls `updateUIViewController` when they change.
struct NoteCanvas: UIViewControllerRepresentable {
    let model: NoteModel
    let meta: NoteMeta
    let drawingVersion: Int
    let scrollTarget: Int?
    let mode: CanvasMode
    let textSize: TextSize
    /// Off while a sheet covers the canvas. A focused canvas brings up the keyboard when a menu opens.
    let focused: Bool

    func makeUIViewController(context: Context) -> CanvasController { CanvasController(model: model) }

    func updateUIViewController(_ controller: CanvasController, context: Context) {
        controller.apply()
        controller.focus(focused)
    }
}

final class CanvasController: UIViewController, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    private let model: NoteModel
    let canvas = PKCanvasView()
    private let pages = PagesView()
    private let objects = ObjectsView()
    private let toolPicker = PKToolPicker()
    private let tap = UITapGestureRecognizer()
    private let drag = UIPanGestureRecognizer()
    private let textTap = UITapGestureRecognizer()
    private let loop = UIPanGestureRecognizer()
    private let loopLayer = CAShapeLayer()
    private var loopPath = CGMutablePath()
    private var drawingVersion = -1
    private var focused = true
    /// Nil until the first `apply`, which turns the gestures for the model's mode on.
    private var mode: CanvasMode?
    private var textSize = TextSize.medium

    init(model: NoteModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = .pencilOnly
        #endif
        canvas.insertSubview(pages, at: 0)
        canvas.insertSubview(objects, at: 1)
        canvas.addSubview(objects.textLayer)
        objects.textLayer.layer.addSublayer(loopLayer)
        loopLayer.fillColor = nil
        loopLayer.strokeColor = view.tintColor.cgColor
        loopLayer.lineWidth = 2
        loopLayer.lineDashPattern = [6, 4]
        objects.imagesChanged = { [model] in model.meta.images = $0 }
        objects.textsChanged = { [model] in model.meta.texts = $0 }
        objects.revertRequested = { [model] in model.revertToHandwriting($0) }
        objects.editingBegan = { [unowned self] size in
            textSize = size
            model.textSize = size
        }
        objects.editingEnded = { [unowned self] in
            DispatchQueue.main.async { if self.focused, !self.objects.editing { self.canvas.becomeFirstResponder() } }
        }
        let finger = [UITouch.TouchType.direct.rawValue as NSNumber]
        let any = finger + [UITouch.TouchType.pencil.rawValue as NSNumber]
        tap.addTarget(self, action: #selector(tapped))
        tap.allowedTouchTypes = finger
        tap.delegate = self
        drag.addTarget(objects, action: #selector(ObjectsView.dragged))
        drag.allowedTouchTypes = finger
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        textTap.addTarget(self, action: #selector(textTapped))
        textTap.allowedTouchTypes = any
        loop.addTarget(self, action: #selector(circled))
        loop.allowedTouchTypes = any
        loop.maximumNumberOfTouches = 1
        [tap, drag, textTap, loop].forEach(canvas.addGestureRecognizer)
        canvas.panGestureRecognizer.require(toFail: drag)
        view.addSubview(canvas)
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        apply()
        canvas.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvas.becomeFirstResponder()
        // PencilKit shows its Select All menu on a finger tap and takes the keyboard focus for it.
        // Its taps wait for ours, so tapping an image or text box, or placing text, doesn't open that menu.
        func taps(in view: UIView) -> [UIGestureRecognizer] {
            (view.gestureRecognizers ?? []).filter { $0 is UITapGestureRecognizer } + view.subviews.flatMap(taps)
        }
        for pencilKitTap in canvas.subviews.filter({ $0 !== objects.textLayer }).flatMap(taps) {
            pencilKitTap.require(toFail: tap)
            pencilKitTap.require(toFail: textTap)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.endEditing(true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let fit = canvas.bounds.width / Page.size.width
        guard fit > 0, fit != canvas.minimumZoomScale else { return }
        canvas.minimumZoomScale = fit
        canvas.maximumZoomScale = fit * 4
        canvas.zoomScale = fit
        layoutPages()
    }

    func apply() {
        let background = model.meta.background
        view.backgroundColor = background.gapColor
        canvas.overrideUserInterfaceStyle = background.style
        toolPicker.colorUserInterfaceStyle = background.style
        if drawingVersion != model.drawingVersion {
            drawingVersion = model.drawingVersion
            canvas.drawing = model.drawing
        }
        if mode != model.mode {
            if mode == .text {
                view.endEditing(true)
                canvas.becomeFirstResponder()
            }
            let mode = model.mode
            self.mode = mode
            canvas.drawingGestureRecognizer.isEnabled = mode == .draw
            canvas.isScrollEnabled = mode != .convert
            tap.isEnabled = mode == .draw
            drag.isEnabled = mode == .draw
            textTap.isEnabled = mode == .text
            loop.isEnabled = mode == .convert
        }
        if textSize != model.textSize {
            textSize = model.textSize
            objects.resizeEditedText(to: textSize)
        }
        layoutPages()
        if let target = model.scrollTarget {
            view.layoutIfNeeded()
            scroll(to: target)
            DispatchQueue.main.async { self.model.scrollTarget = nil }
        }
    }

    func focus(_ focused: Bool) {
        guard focused != self.focused else { return }
        self.focused = focused
        _ = focused ? canvas.becomeFirstResponder() : canvas.resignFirstResponder()
    }

    private func layoutPages() {
        let zoom = canvas.zoomScale
        canvas.contentSize = CGSize(width: Page.size.width * zoom, height: Page.height(of: model.meta.pageCount) * zoom)
        pages.layout(count: model.meta.pageCount, background: model.meta.background, zoom: zoom)
        objects.update(meta: model.meta, note: model.url, zoom: zoom, mode: mode ?? .draw)
        canvas.bringSubviewToFront(objects.textLayer)
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) { objects.tapped(at: tap.location(in: objects)) }

    @objc private func textTapped(_ tap: UITapGestureRecognizer) {
        let color = (canvas.tool as? PKInkingTool)?.color ?? .black
        objects.editText(at: tap.location(in: objects), size: textSize, color: color)
    }

    @objc private func circled(_ loop: UIPanGestureRecognizer) {
        let point = loop.location(in: objects)
        switch loop.state {
        case .began:
            loopPath = CGMutablePath()
            loopPath.move(to: point)
        case .changed:
            loopPath.addLine(to: point)
        case .ended:
            loopPath.closeSubpath()
            let path = loopPath
            Task {
                if await !model.convertHandwriting(in: path) {
                    model.message = "The circled ink could not be turned into text."
                }
                loopLayer.path = nil
                model.mode = .draw
            }
        default:
            loopLayer.path = nil
            return
        }
        var zoom = CGAffineTransform(scaleX: canvas.zoomScale, y: canvas.zoomScale)
        loopLayer.path = loopPath.copy(using: &zoom)
    }

    /// The tap only counts on an image or text box, or to clear a selection, so PencilKit's menu still opens elsewhere.
    /// The drag only starts on the selected image or text box. Everywhere else the finger scrolls.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === tap { return objects.takesTap(at: tap.location(in: objects)) }
        let now = drag.location(in: objects), moved = drag.translation(in: objects)
        return objects.grabs(at: CGPoint(x: now.x - moved.x, y: now.y - moved.y))
    }

    private func scroll(to page: Int) {
        let insets = canvas.adjustedContentInset
        let bottom = canvas.contentSize.height + insets.bottom - canvas.bounds.height
        let y = min(Page.rect(page).minY * canvas.zoomScale - insets.top, max(bottom, -insets.top))
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: true)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { layoutPages() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let zoom = canvas.zoomScale
        model.visibleCenter = CGPoint(x: canvas.bounds.midX / zoom, y: canvas.bounds.midY / zoom)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { model.drawingChanged(canvasView.drawing) }
}

/// The page backgrounds under the ink. Redrawn at each zoom level so the grid stays sharp.
final class PagesView: UIView {
    func layout(count: Int, background: Background, zoom: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = CGRect(x: 0, y: 0, width: Page.size.width * zoom, height: Page.height(of: count) * zoom)
        var pages = layer.sublayers ?? []
        while pages.count < count {
            let page = CALayer()
            page.addSublayer(CAShapeLayer())
            layer.addSublayer(page)
            pages.append(page)
        }
        pages.dropFirst(count).forEach { $0.removeFromSuperlayer() }
        let width = Page.size.width * zoom, height = Page.size.height * zoom
        let grid = Page.gridPath(width: width, height: height, spacing: Page.gridSpacing * zoom)
        for (index, page) in pages.prefix(count).enumerated() {
            page.frame = CGRect(x: 0, y: Page.rect(index).minY * zoom, width: width, height: height)
            page.backgroundColor = background.pageColor.cgColor
            let lines = page.sublayers?.first as? CAShapeLayer
            lines?.isHidden = background != .grid
            lines?.path = grid
            lines?.strokeColor = Page.gridColor.cgColor
            lines?.lineWidth = 0.5
        }
        CATransaction.commit()
    }
}

/// PDF pages and images between the page backgrounds and the ink, and text boxes above the ink.
/// It works in note coordinates and is scaled by the zoom.
/// In draw mode a finger taps an image or text box to select it. Then it drags it, drags an image's bottom-right corner
/// to resize it, or taps the cross to delete it. The taps and drags come from recognizers on the canvas,
/// because PencilKit's views above this one take all touches.
final class ObjectsView: UIView, UITextViewDelegate {
    enum Selection: Equatable {
        case image(Int), text(Int)

        var isImage: Bool { if case .image = self { true } else { false } }
    }

    var imagesChanged: (([ImageItem]) -> Void)?
    var textsChanged: (([TextItem]) -> Void)?
    var revertRequested: ((Int) -> Void)?
    var editingBegan: ((TextSize) -> Void)?
    var editingEnded: (() -> Void)?
    /// Holds the text boxes. It is not scaled but laid out at the zoom, so text stays sharp.
    /// The controller keeps it above PencilKit's views, so text boxes can take the keyboard and Scribble.
    let textLayer = TextLayer()
    private var pdfPages: [PDFPageRef] = []
    private var images: [ImageItem]?
    private var texts: [TextItem] = []
    private var imageViews: [UIImageView] = []
    private var textViews: [UITextView] = []
    private var documents: [String: CGPDFDocument] = [:]
    private let selection = SelectionView()
    private var selected: Selection? { didSet { layoutSelection() } }
    private var zoom: CGFloat = 1
    private var dark = false
    private var resizing = false

    var editing: Bool { textViews.contains(where: \.isFirstResponder) }

    init() {
        super.init(frame: .zero)
        layer.anchorPoint = .zero
        isUserInteractionEnabled = false
        addSubview(selection)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(meta: NoteMeta, note: URL, zoom: CGFloat, mode: CanvasMode) {
        let zoomed = self.zoom != zoom
        self.zoom = zoom
        bounds = CGRect(x: 0, y: 0, width: Page.size.width, height: Page.height(of: meta.pageCount))
        layer.position = .zero
        transform = CGAffineTransform(scaleX: zoom, y: zoom)
        textLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * zoom, height: bounds.height * zoom)
        textLayer.isUserInteractionEnabled = mode == .text
        if meta.pdfPages != pdfPages {
            pdfPages = meta.pdfPages
            subviews.filter { $0 is PDFPageView }.forEach { $0.removeFromSuperview() }
            for ref in pdfPages {
                let document = documents[ref.file] ?? CGPDFDocument(NoteFile.file(ref.file, in: note) as CFURL)
                documents[ref.file] = document
                guard let pdf = document?.page(at: ref.index + 1) else { continue }
                insertSubview(PDFPageView(pdf: pdf, frame: Page.rect(ref.page)), at: 0)
            }
        }
        if meta.images != images {
            let added = images.map { meta.images.count == $0.count + 1 } ?? false
            images = meta.images
            imageViews.forEach { $0.removeFromSuperview() }
            imageViews = meta.images.map { item in
                let view = UIImageView(image: UIImage(contentsOfFile: NoteFile.file(item.file, in: note).path))
                view.frame = item.frame
                insertSubview(view, belowSubview: selection)
                return view
            }
            selected = added ? .image(meta.images.count - 1) : nil
        }
        let darkChanged = dark != (meta.background == .black)
        dark = meta.background == .black
        if meta.texts != texts {
            texts = meta.texts
            textViews.forEach { $0.removeFromSuperview() }
            textViews = texts.map { _ in makeTextView() }
            textViews.indices.forEach { style($0, text: true) }
            if case .text = selected { selected = nil }
        } else if zoomed || darkChanged {
            textViews.indices.forEach { style($0, text: false) }
        }
        if mode != .draw { selected = nil }
        layoutSelection()
    }

    /// Lays out text box `index` at the zoom. With `text` false it keeps what is being typed and only rescales it.
    private func style(_ index: Int, text: Bool) {
        let item = texts[index], view = textViews[index]
        var attributes = item.attributes(dark: dark)
        attributes[.font] = UIFont.systemFont(ofSize: item.size.points * zoom)
        let range = view.selectedRange
        view.attributedText = NSAttributedString(string: text ? item.text : view.text, attributes: attributes)
        view.typingAttributes = attributes
        view.selectedRange = range
        place(index)
    }

    /// Zoomed text is not exactly as wide as the measured box, so the view gets one character of room and measures its own height.
    private func place(_ index: Int) {
        let item = texts[index], view = textViews[index]
        let available = (Page.size.width - TextItem.margin - item.origin.x) * zoom
        let width = min((item.frame.width + item.size.points) * zoom, max(available, item.size.points * zoom))
        let height = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        view.frame = CGRect(x: item.origin.x * zoom, y: item.origin.y * zoom, width: width, height: height)
    }

    func tapped(at point: CGPoint) {
        if let selected, selection.deleteFrame.contains(convert(point, to: selection)) {
            switch selected {
            case .image(let index):
                var images = images ?? []
                images.remove(at: index)
                imagesChanged?(images)
            case .text(let index):
                var texts = texts
                texts.remove(at: index)
                textsChanged?(texts)
            }
        } else if case .text(let index) = selected, texts[index].handwriting != nil, selection.revertFrame.contains(convert(point, to: selection)) {
            revertRequested?(index)
        } else if let index = texts.lastIndex(where: { $0.frame.contains(point) }) {
            selected = .text(index)
        } else {
            selected = images?.lastIndex { $0.frame.contains(point) }.map { .image($0) }
        }
    }

    func takesTap(at point: CGPoint) -> Bool {
        selected != nil || texts.contains { $0.frame.contains(point) } || images?.contains { $0.frame.contains(point) } == true
    }

    /// Edits the text box at `point`, or places a new one there.
    func editText(at point: CGPoint, size: TextSize, color: UIColor) {
        if let index = texts.lastIndex(where: { $0.frame.contains(point) }) {
            textViews[index].becomeFirstResponder()
            return
        }
        let page = Page.rect(Page.index(at: point.y))
        let x = min(max(point.x, TextItem.margin), Page.size.width - TextItem.margin - size.points)
        let y = min(max(point.y - size.points * 0.6, page.minY), page.maxY - size.points * 1.2)
        texts.append(TextItem(text: "", origin: CGPoint(x: x, y: y), size: size, color: color.components))
        textViews.append(makeTextView())
        style(texts.count - 1, text: true)
        textViews[texts.count - 1].becomeFirstResponder()
        textsChanged?(texts)
    }

    private func makeTextView() -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = self
        textLayer.addSubview(view)
        return view
    }

    func resizeEditedText(to size: TextSize) {
        guard let index = textViews.firstIndex(where: \.isFirstResponder), texts[index].size != size else { return }
        texts[index].size = size
        style(index, text: false)
        textsChanged?(texts)
    }

    func textViewDidBeginEditing(_ view: UITextView) {
        guard let index = textViews.firstIndex(of: view) else { return }
        editingBegan?(texts[index].size)
    }

    func textViewDidChange(_ view: UITextView) {
        guard let index = textViews.firstIndex(of: view) else { return }
        texts[index].text = view.text
        place(index)
        textsChanged?(texts)
    }

    /// An empty text box is removed when you stop editing it.
    func textViewDidEndEditing(_ view: UITextView) {
        guard let index = textViews.firstIndex(of: view) else { return }
        if view.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            texts.remove(at: index)
            textViews.remove(at: index).removeFromSuperview()
        }
        textsChanged?(texts)
        editingEnded?()
    }

    private func frame(of selection: Selection) -> CGRect? {
        switch selection {
        case .image(let index): images?[index].frame
        case .text(let index): texts[index].frame
        }
    }

    /// Whether a finger drag from `point` moves the selection, or resizes it when it is an image.
    func grabs(at point: CGPoint) -> Bool {
        guard let selected, let frame = frame(of: selected) else { return false }
        resizing = selected.isImage && hypot(frame.maxX - point.x, frame.maxY - point.y) < 44 / zoom
        return resizing || frame.contains(point)
    }

    @objc func dragged(_ drag: UIPanGestureRecognizer) {
        let delta = drag.translation(in: self)
        drag.setTranslation(.zero, in: self)
        let done = drag.state == .ended || drag.state == .cancelled
        switch selected {
        case .image(let index):
            guard var frame = images?[index].frame else { return }
            if resizing {
                let width = max(80, frame.width + delta.x)
                frame.size = CGSize(width: width, height: frame.height * width / frame.width)
            } else {
                frame = frame.offsetBy(dx: delta.x, dy: delta.y)
            }
            if done { frame.origin = inside(frame) }
            images?[index].frame = frame
            imageViews[index].frame = frame
            if done, let images { imagesChanged?(images) }
        case .text(let index):
            texts[index].origin.x += delta.x
            texts[index].origin.y += delta.y
            if done { texts[index].origin = inside(texts[index].frame) }
            style(index, text: false)
            if done { textsChanged?(texts) }
        case nil:
            return
        }
        layoutSelection()
    }

    /// Where `frame` goes when it is dropped, so it stays on the note and moves along when pages are rearranged.
    private func inside(_ frame: CGRect) -> CGPoint {
        CGPoint(x: max(min(frame.minX, bounds.width - frame.width), 0), y: max(min(frame.minY, bounds.height - frame.height), 0))
    }

    private func layoutSelection() {
        selection.isHidden = selected == nil
        guard let selected, let frame = frame(of: selected) else { return }
        selection.frame = frame
        let revertible = if case .text(let index) = selected { texts[index].handwriting != nil } else { false }
        selection.layout(zoom: zoom, handle: selected.isImage, revert: revertible)
    }
}

/// Only text boxes take touches. Everywhere else the touch goes to the canvas.
final class TextLayer: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }
}

final class SelectionView: UIView {
    private let handle = UIView()
    private let delete = UIImageView(image: UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)))
    private let revert = UIImageView(image: UIImage(systemName: "arrow.uturn.backward.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)))
    var deleteFrame: CGRect { delete.frame }
    var revertFrame: CGRect { revert.frame }

    init() {
        super.init(frame: .zero)
        layer.borderColor = tintColor.cgColor
        handle.backgroundColor = tintColor
        delete.contentMode = .center
        revert.contentMode = .center
        addSubview(handle)
        addSubview(delete)
        addSubview(revert)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Keeps the border and controls the same size on screen at every zoom.
    /// `revert` shows the button that turns text made from handwriting back into handwriting.
    func layout(zoom: CGFloat, handle shown: Bool, revert revertible: Bool) {
        handle.isHidden = !shown
        revert.isHidden = !revertible
        layer.borderWidth = 2 / zoom
        let unzoom = CGAffineTransform(scaleX: 1 / zoom, y: 1 / zoom)
        handle.bounds.size = CGSize(width: 22, height: 22)
        handle.layer.cornerRadius = 11
        handle.transform = unzoom
        handle.center = CGPoint(x: bounds.maxX - 11 / zoom, y: bounds.maxY - 11 / zoom)
        delete.bounds.size = CGSize(width: 44, height: 44)
        delete.transform = unzoom
        // Above the box, so text never covers it.
        delete.center = CGPoint(x: bounds.maxX - 22 / zoom, y: -24 / zoom)
        revert.bounds.size = delete.bounds.size
        revert.transform = unzoom
        revert.center = CGPoint(x: bounds.maxX - 70 / zoom, y: -24 / zoom)
    }
}

/// Draws its PDF page in tiles, so it stays sharp at every zoom.
final class PDFPageView: UIView {
    override class var layerClass: AnyClass { CATiledLayer.self }
    private let pdf: CGPDFPage

    init(pdf: CGPDFPage, frame: CGRect) {
        self.pdf = pdf
        super.init(frame: frame)
        backgroundColor = .white
        isUserInteractionEnabled = false
        (layer as? CATiledLayer)?.levelsOfDetailBias = 3
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        Page.draw(pdf, in: bounds, context: context)
    }
}
