# Slate design

Slate is a personal iPad app for handwriting with the Apple Pencil on pages, PDFs and images. It is built for one person and is not published on the App Store.

## Platform

- Native Swift app (SwiftUI, PencilKit, PDFKit) for iPadOS 27.
- Installed from Xcode with a free Apple ID. The app must be reinstalled every 7 days. Notes survive a reinstall.
- Notes are saved automatically on the iPad, in the app's folder in the Files app, a second after the last change and straight away when you leave the note or the app. A failed save shows an alert and is tried again when you leave the note. There is no iCloud sync.

## Home screen

- A grid of note thumbnails sorted by last edited.
- Folders, one level deep. Search matches note titles.
- A new note is named after its date ("25 Oct 2026"). Tap the title to rename it.
- Long-press a note to rename, move to a folder, duplicate or delete it.
- Long-press a folder to rename it or delete it. Deleting a folder moves everything in it, notes and other files, to the top level first.
- A folder or note action that fails, such as a folder name with a slash or one that already exists, shows the reason.

## Notes and pages

- A note is a stack of A4 portrait pages. Scrolling is continuous and vertical. Pinch zooms, never smaller than the page width.
- The background is set per note: plain black, or white with a faint 5 mm light-gray grid. It is chosen when the note is created and can be switched later. The default pen is white on black and black on white.
- "Add page" adds a page at the end with the note's background.
- A page overview shows page thumbnails. You can jump to a page, delete it, duplicate it or drag it to reorder.

## Input

- Only the Pencil draws. The finger scrolls, zooms and moves objects.
- Apple's tool picker (pens, colors, eraser, lasso, ruler, undo) plus custom buttons for text, text size, handwriting to text, background, photo, PDF or image, pages, add page and export.
- The eraser removes ink only, never text boxes, images or PDF content.
- Apple's lasso selects handwriting. Drag the selection to move it, or tap it for cut, copy, delete, duplicate and copy as text.
- Double-tap and squeeze on the Pencil follow Apple's tool picker behavior.

## Text

- The Aa button turns on text mode. Tap anywhere to place a text box and type. The box grows while typing and wraps at the right margin of the page. Tap an existing box to edit it. An empty box disappears when you stop editing it.
- In text mode the Pencil writes into a text box with Scribble instead of drawing. Tap Aa again to go back to drawing.
- One font in three sizes. The size button next to Aa switches between small, medium and large, for new boxes and the box you are editing.
- The text takes the pen color picked in the tool picker. Like ink, black text shows white on a black note.
- Text boxes sit above the ink. Outside text mode, tap a text box with a finger to select it, drag it to move it, or tap the cross to delete it.
- The handwriting button turns ink into text. Circle the handwriting with the Pencil and it becomes a text box in the same spot and color. Recognition is English only and runs on the device.
- A text box made from handwriting keeps that handwriting. Select it and tap the arrow next to the cross to turn it back into the handwriting, at the place the box is now. This works any time, also after reopening the note.

## Images and PDFs

- Inserting a PDF puts its pages after the page you are looking at, and later pages move down. In a note that is still one empty page, the PDF replaces that page. Start a note from a PDF by creating a note and inserting the PDF.
- A PDF page is the page background, with no grid. It is drawn as large as fits on the A4 page and stays white paper on a black note, so use a colored pen there.
- Images come from Photos or Files. They are placed in the middle of the page you are looking at, and drawn on top of with the Pencil.
- Tap an image with a finger to select it. Drag it to move it, drag its bottom-right corner to resize it, or tap the cross to delete it. Tap elsewhere to deselect.
- The PDFs and images are copied into the note, so the note keeps working when the original is deleted.

## Export

- The whole note as a PDF, or the current page as a PNG, through the share sheet.
- The export looks exactly like the screen: black pages stay black and the grid stays visible.
- PDF pages are A4. The ink is a bitmap of about 290 dpi, PDF pages stay vector and photos are stored as JPEG. The PNG is 2480 pixels wide, A4 at 300 dpi.

## Build order

1. Notes with pages, both backgrounds, Pencil drawing, autosave, and the home screen with folders.
2. Text boxes, Scribble and handwriting to text.
3. Image and PDF import.
4. PDF and PNG export.

## Out of scope for now

- Typed text outside text boxes, iCloud sync, Dutch handwriting recognition, a grid size setting, a white "print" export, PDF pages in their own size, inserting from the camera, drawing with a finger, a long-press menu to duplicate or reorder images and text boxes.
