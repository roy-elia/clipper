import AppKit
import SwiftUI
import Vision
import CoreImage
import DropCore

/// What an editor hands back: the new text, image data and formatting for a clip.
struct ClipEdit { var text: String?; var data: Data?; var extras: [String: Data]? }

/// Edit ▸ opens the editor for the clip's kind: formatted text, image, colour or link.
/// With "Save automatically" on, every change is kept as you make it; otherwise Save or Discard.
struct ClipEditorView: View {
    let item: ClipItem
    var autosave: Bool
    var onAutosaveChanged: (Bool) -> Void
    var onSave: (ClipEdit) -> Void
    var onClose: () -> Void

    @State private var edit: ClipEdit
    @State private var dirty = false

    init(item: ClipItem, autosave: Bool, onAutosaveChanged: @escaping (Bool) -> Void, onSave: @escaping (ClipEdit) -> Void, onClose: @escaping () -> Void) {
        self.item = item; self.autosave = autosave; self.onAutosaveChanged = onAutosaveChanged; self.onSave = onSave; self.onClose = onClose
        _edit = State(initialValue: ClipEdit(text: item.text, data: item.data, extras: item.extras))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Toggle("Save automatically", isOn: Binding(get: { autosave }, set: { onAutosaveChanged($0) }))
                    .toggleStyle(.checkbox).accessibilityIdentifier("editor.autosave")
            }
            Group {
                switch item.kind {
                case .image: ImageEditor(data: Binding(get: { edit.data }, set: { change(ClipEdit(text: nil, data: $0, extras: nil)) }))
                case .color: ColorEditor(hex: Binding(get: { edit.text ?? "#000000" }, set: { change(ClipEdit(text: $0, data: nil, extras: nil)) }))
                case .link: LinkEditor(url: Binding(get: { edit.text ?? "" }, set: { change(ClipEdit(text: $0, data: nil, extras: nil)) }))
                default:
                    FormattedTextEditor(item: item) { text, rtf in change(ClipEdit(text: text, data: nil, extras: rtf.map { ["public.rtf": $0] })) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(item.lastUsed.map { "Last used " + Relative.string(from: $0) } ?? "Never used").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("editor.lastUsed")
                Spacer()
                if autosave {
                    Button("Done") { onClose() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("editor.done")
                } else {
                    Button("Discard Changes") { onClose() }.accessibilityIdentifier("editor.discard")
                    Button("Save Changes") { onSave(edit); onClose() }.keyboardShortcut(.defaultAction).disabled(!dirty)
                        .accessibilityIdentifier("editor.save")
                }
            }
        }
        .padding(16).frame(minWidth: 520, minHeight: 420)
    }

    var title: String {
        switch item.kind { case .image: "Edit Image"; case .color: "Edit Color"; case .link: "Edit Link"; default: "Edit Text" }
    }

    func change(_ e: ClipEdit) {
        edit = e; dirty = true
        if autosave { onSave(e) }
    }
}

// MARK: text

/// A rich text view with Bold, Italic, Underline and Strikethrough for the selection.
struct FormattedTextEditor: View {
    let item: ClipItem
    var onChange: (String, Data?) -> Void
    @State private var view = NSTextView()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                style("bold", "Bold", "b") { toggleTrait(.boldFontMask) }
                style("italic", "Italic", "i") { toggleTrait(.italicFontMask) }
                style("underline", "Underline", "u") { toggleAttr(.underlineStyle) }
                style("strikethrough", "Strikethrough", "x") { toggleAttr(.strikethroughStyle) }
                if #available(macOS 15.2, *) {
                    Button { view.window?.makeFirstResponder(view); NSApp.sendAction(Selector(("showWritingTools:")), to: nil, from: nil) } label: {
                        Label("Writing Tools", systemImage: "apple.intelligence")
                    }.buttonStyle(.bordered).accessibilityIdentifier("editor.writingTools")
                }
            }
            TextViewHost(view: view, item: item, onChange: report)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    func style(_ symbol: String, _ label: String, _ key: KeyEquivalent, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 18) }
            .buttonStyle(.bordered).help(label).accessibilityLabel(label)
            .keyboardShortcut(key, modifiers: .command)
            .accessibilityIdentifier("editor.\(label.lowercased())")
    }

    func report() {
        // The editor shows text in the system text colour; keep that out of the saved formatting so a paste into
        // a light document doesn't come out white. Colours the text really has are kept.
        let s = NSMutableAttributedString(attributedString: view.attributedString())
        let all = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.foregroundColor, in: all) { v, r, _ in
            if let c = v as? NSColor, c.type == .catalog { s.removeAttribute(.foregroundColor, range: r) }
        }
        let rtf = s.length > 0 ? s.rtf(from: all) : nil
        onChange(s.string, rtf)
    }

    func toggleTrait(_ t: NSFontTraitMask) {
        guard let storage = view.textStorage else { return }
        let r = view.selectedRange(); guard r.length > 0 else { return }
        let fm = NSFontManager.shared
        let first = (storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 14)
        let adding = !fm.traits(of: first).contains(t)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: r) { v, sub, _ in
            let f = (v as? NSFont) ?? .systemFont(ofSize: 14)
            storage.addAttribute(.font, value: adding ? fm.convert(f, toHaveTrait: t) : fm.convert(f, toNotHaveTrait: t), range: sub)
        }
        storage.endEditing(); report()
    }

    func toggleAttr(_ key: NSAttributedString.Key) {
        guard let storage = view.textStorage else { return }
        let r = view.selectedRange(); guard r.length > 0 else { return }
        let on = (storage.attribute(key, at: r.location, effectiveRange: nil) as? Int ?? 0) != 0
        if on { storage.removeAttribute(key, range: r) } else { storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: r) }
        report()
    }
}

struct TextViewHost: NSViewRepresentable {
    let view: NSTextView
    let item: ClipItem
    var onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: () -> Void
        init(onChange: @escaping () -> Void) { self.onChange = onChange }
        func textDidChange(_ n: Notification) { onChange() }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        view.isRichText = true; view.allowsUndo = true; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.font = .systemFont(ofSize: 14); view.textColor = .labelColor
        if let rtf = item.extras?["public.rtf"], let s = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            view.textStorage?.setAttributedString(s)
        } else {
            view.string = item.text ?? ""
        }
        view.delegate = context.coordinator
        view.setAccessibilityIdentifier("editor.text")
        scroll.documentView = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }
    func updateNSView(_ v: NSScrollView, context: Context) {}
}

// MARK: image

/// Rotate left or right; remove the background (keep the subject) and put it back.
struct ImageEditor: View {
    @Binding var data: Data?
    @State private var original: Data?
    @State private var working = false
    @State private var note: String?

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Checkerboard()
                if let d = data, let img = NSImage(data: d) { Image(nsImage: img).resizable().scaledToFit().padding(8) }
                if working { ProgressView() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Button { rotate(left: true) } label: { Label("Rotate Left", systemImage: "rotate.left") }.accessibilityIdentifier("editor.rotateLeft")
                Button { rotate(left: false) } label: { Label("Rotate Right", systemImage: "rotate.right") }.accessibilityIdentifier("editor.rotateRight")
                Spacer()
                if original != nil {
                    Button { data = original; original = nil } label: { Label("Restore Background", systemImage: "arrow.uturn.backward") }
                        .accessibilityIdentifier("editor.restoreBackground")
                } else {
                    Button { removeBackground() } label: { Label("Remove Background", systemImage: "person.crop.rectangle") }
                        .disabled(working).accessibilityIdentifier("editor.removeBackground")
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    func rotate(left: Bool) {
        guard let d = data, let src = NSImage(data: d)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let w = src.height, h = src.width
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: left ? .pi / 2 : -.pi / 2)
        ctx.draw(src, in: CGRect(x: -CGFloat(src.width) / 2, y: -CGFloat(src.height) / 2, width: CGFloat(src.width), height: CGFloat(src.height)))
        if let out = ctx.makeImage() { data = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) }
    }

    func removeBackground() {
        guard let d = data, let cg = NSImage(data: d)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        working = true; note = nil
        Task.detached {
            let result = ImageEditor.subjectOnly(cg)
            await MainActor.run {
                working = false
                if let result { original = d; data = result } else { note = "No subject found to keep." }
            }
        }
    }

    /// Vision's subject mask applied to the image; nil when no subject is found.
    nonisolated static func subjectOnly(_ cg: CGImage) -> Data? {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        guard (try? handler.perform([req])) != nil, let obs = req.results?.first,
              let buf = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false) else { return nil }
        let ci = CIImage(cvPixelBuffer: buf)
        guard let out = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}

// MARK: colour and link

struct ColorEditor: View {
    @Binding var hex: String
    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: hex) ?? .clear).frame(height: 160)
            HStack {
                ColorPicker("Colour", selection: Binding(get: { Color(hex: hex) ?? .black }, set: { hex = ColorEditor.hex($0) }), supportsOpacity: false)
                    .accessibilityIdentifier("editor.colorPicker")
                Spacer()
                TextField("#RRGGBB", text: $hex).textFieldStyle(.roundedBorder).frame(width: 120).font(.body.monospaced())
                    .accessibilityIdentifier("editor.hex")
            }
            Spacer()
        }
    }
    static func hex(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(round(n.redComponent * 255)), Int(round(n.greenComponent * 255)), Int(round(n.blueComponent * 255)))
    }
}

struct LinkEditor: View {
    @Binding var url: String
    var valid: Bool { URL(string: url.trimmingCharacters(in: .whitespaces)).map { $0.scheme != nil && $0.host != nil } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("https://", text: $url).textFieldStyle(.roundedBorder).accessibilityIdentifier("editor.url")
            Text(valid ? (URL(string: url)?.host ?? "") : "Not a full web address yet").font(.caption).foregroundStyle(valid ? Color.secondary : Color.orange)
            Spacer()
        }
    }
}
