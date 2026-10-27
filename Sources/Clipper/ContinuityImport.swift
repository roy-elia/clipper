import AppKit

/// Import from iPhone: a view that accepts images from Continuity Camera (Take Photo, Scan Documents, Add Sketch).
/// macOS fills the menu's import item with the nearby devices; the result arrives through readSelection(from:).
final class ContinuityImportView: NSView, @preconcurrency NSServicesMenuRequestor {
    var onImage: ((Data) -> Void)?
    private let button = NSButton(title: "Choose iPhone or iPad…", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "Take a photo or scan a document with a nearby iPhone or iPad signed in to your Apple Account. It is saved as a new clip.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.target = self; button.action = #selector(showMenu(_:)); button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("import.choose")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [note, button]); stack.orientation = .vertical; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     note.widthAnchor.constraint(equalToConstant: 300)])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc func showMenu(_ sender: NSButton) {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let r = returnType, NSImage.imageTypes.contains(r.rawValue) || r == .png || r == .tiff || r == .pdf { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        if let d = pboard.data(forType: .png) { onImage?(d); return true }
        if let img = NSImage(pasteboard: pboard), let t = img.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
            onImage?(png); return true
        }
        return false
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
}
