import SwiftUI
import DropCore

@MainActor
final class ShelfModel: ObservableObject {
    @Published var query = ""
    @Published var kind: ClipKind?
    @Published var board: String?          // nil = History
    @Published var app: String?            // source-app filter
    @Published var picks = false           // show suggestions for targetApp instead of history
    @Published var targetApp: String?      // the app a paste would go into
    var log = PasteLog()
    @Published var apps: [String] = []
    @Published var selection = 0
    @Published var focusTick = 0           // bumped each time the shelf opens so search regains focus
    @Published var items: [ClipItem] = []
    @Published var boards: [String] = []
    @Published var stack = PasteStack()
    @Published var previewing: ClipItem?
    @Published var settings: AppSettings
    let store: HistoryStore
    var onPick: ((ClipItem, Bool) -> Void)?   // item, plain text only
    var onClose: (() -> Void)?
    var onShare: ((ClipItem) -> Void)?
    var onPreview: ((ClipItem) -> Void)?
    var onClear: (() -> Void)?
    var onDrop: (([NSItemProvider]) -> Bool)?
    var onSettingsChanged: (() -> Void)?

    init(store: HistoryStore, settings: AppSettings = AppSettings()) {
        self.store = store; self.settings = settings; refresh()
    }

    func refresh() {
        if picks {
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            items = PickRanker(log: log).rank(store.all, for: targetApp, limit: 12).filter {
                (kind == nil || $0.kind == kind) && (q.isEmpty || $0.title.lowercased().contains(q) || ($0.text?.lowercased().contains(q) ?? false))
            }
        } else {
            items = store.search(query, kind: kind, pinboard: board, app: app)
        }
        boards = store.pinboards(); apps = store.apps()
        selection = items.isEmpty ? 0 : min(selection, items.count - 1)
    }

    func move(_ delta: Int) { guard !items.isEmpty else { return }; selection = min(max(selection + delta, 0), items.count - 1) }
    var selected: ClipItem? { items.indices.contains(selection) ? items[selection] : nil }
    func pickSelected(plain: Bool) { if let i = selected { onPick?(i, plain) } }
    func pick(number n: Int) { if items.indices.contains(n - 1) { onPick?(items[n - 1], false) } }
    func deleteSelected() { if let i = selected { delete(i) } }

    func pin(_ item: ClipItem, to name: String?) { store.setPinboard(name, for: item.id); refresh() }
    func delete(_ item: ClipItem) { store.delete(item.id); stack.remove(item.id); refresh() }
    func addBoard(_ name: String) { if store.createPinboard(name) { board = name.trimmingCharacters(in: .whitespaces); refresh() } }
    func renameBoard(_ old: String, _ new: String) { if store.renamePinboard(old, to: new) { board = new; refresh() } }
    func deleteBoard(_ name: String) { store.deletePinboard(name); if board == name { board = nil }; refresh() }
    func updateSettings(_ f: (inout AppSettings) -> Void) { f(&settings); store.capacity = settings.historyCapacity; onSettingsChanged?() }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @State private var newBoard = ""
    @State private var adding = false
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    static let cardSize = CGSize(width: 232, height: 228)

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                picksTab
                tab("History", nil)
                ForEach(model.boards, id: \.self) { b in
                    tab(b, b).contextMenu {
                        Button("Delete Pinboard", role: .destructive) { model.deleteBoard(b) }
                    }
                }
                if adding {
                    TextField("Name", text: $newBoard).textFieldStyle(.roundedBorder).frame(width: 110)
                        .accessibilityIdentifier("shelf.newBoardField")
                        .onSubmit { model.addBoard(newBoard); newBoard = ""; adding = false }
                } else {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).padding(8).background(.quaternary, in: Circle())
                        .accessibilityLabel("New pinboard").accessibilityIdentifier("shelf.addBoard")
                }
                Spacer()
                if !model.stack.isEmpty {
                    Label("\(model.stack.items.count) in stack", systemImage: "square.stack.3d.up")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.items.count == 1 ? "1 clip" : "\(model.items.count) clips").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("shelf.count")
                Button { model.onClear?() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).padding(9).background(.quaternary, in: Circle())
                    .help("Clear all saved clips").accessibilityLabel("Clear history").accessibilityIdentifier("shelf.clear")
            }
            HStack(spacing: 8) {
                TextField("Search clips", text: $model.query)
                    .textFieldStyle(.plain).padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.quaternary, in: Capsule())
                    .focused($searchFocused)
                    .onSubmit { model.pickSelected(plain: false) }
                    .accessibilityIdentifier("shelf.search")
                chip("All", nil)
                ForEach(ClipKind.allCases, id: \.self) { chip($0.rawValue.capitalized, $0) }
                appMenu
            }
            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: dropTargeted ? "arrow.down.circle" : "tray").font(.title).foregroundStyle(.secondary)
                    Text(model.picks ? "No suggestions yet" : model.board == nil ? "Nothing copied yet. Drop images, files or text here to save them." : "Right-click a clip, then Pin to, to add it here")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(spacing: 10) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                                Card(item: item, number: idx < 9 ? idx + 1 : nil, selected: idx == model.selection)
                                    .id(item.id)
                                    .onTapGesture { model.selection = idx; model.onPick?(item, false) }
                                    .onDrag { provider(for: item) }
                                    .contextMenu { menu(for: item) }
                                    .accessibilityIdentifier("shelf.card.\(item.id)")
                            }
                        }.padding(.vertical, 8).padding(.horizontal, 10)
                    }
                    .onChange(of: model.selection) { if let i = model.selected { if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { proxy.scrollTo(i.id) } else { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { proxy.scrollTo(i.id) } } } }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, minHeight: 384, maxHeight: 384)
        .background { ShelfBackdrop() }
        .clipperStyle()
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Palette.accent.opacity(0.14)).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $dropTargeted) { model.onDrop?($0) ?? false }
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusTick) { searchFocused = true }
        .onChange(of: model.query) { model.refresh() }
        .onChange(of: model.kind) { model.refresh() }
        .onChange(of: model.board) { model.refresh() }
        .onChange(of: model.app) { model.refresh() }
    }

    /// What leaves the shelf when a card is dragged: the image, the files, or the text.
    func provider(for item: ClipItem) -> NSItemProvider {
        if item.isSecret { return NSItemProvider() }
        if let urls = item.fileURLs, let u = urls.first.flatMap({ URL(string: $0) }) { return NSItemProvider(contentsOf: u) ?? NSItemProvider() }
        if let d = item.data, let img = NSImage(data: d) { return NSItemProvider(object: img) }
        return NSItemProvider(object: (item.text ?? item.title) as NSString)
    }

    func handleKey(_ p: KeyPress) -> KeyPress.Result {
        let cmd = p.modifiers.contains(.command)
        switch p.key {
        case .leftArrow: model.move(-1); return .handled
        case .rightArrow: model.move(1); return .handled
        case .return: model.pickSelected(plain: p.modifiers.contains(.shift)); return .handled
        case .escape: model.onClose?(); return .handled
        case .delete where cmd: model.deleteSelected(); return .handled
        default: break
        }
        if cmd, let n = Int(p.characters), (1...9).contains(n) { model.pick(number: n); return .handled }
        if cmd, p.characters == "y", let i = model.selected { model.onPreview?(i); return .handled }
        return .ignored
    }

    var appMenu: some View {
        Menu {
            Button("All apps") { model.app = nil }
            Divider()
            ForEach(model.apps, id: \.self) { b in Button { model.app = b } label: { Label(AppInfo.name(b), systemImage: "app") } }
        } label: {
            if let b = model.app, let icon = AppInfo.icon(b) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else { Image(systemName: "app.dashed") }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 5).background(.quaternary, in: Capsule())
        .accessibilityLabel("Filter by app").accessibilityIdentifier("shelf.appFilter")
    }

    @ViewBuilder func menu(for item: ClipItem) -> some View {
        Button("Paste") { model.onPick?(item, false) }
        Button("Paste as Plain Text") { model.onPick?(item, true) }
        Button("Preview") { model.onPreview?(item) }
        Button("Add to Paste Stack") { model.stack.push(item) }
        if !item.isSecret { Button("Share…") { model.onShare?(item) } }
        if item.isSecret { Button("Not a Secret") { model.store.markSecret(item.id, false); model.refresh() } }
        else if item.kind == .text { Button("Mark as Secret") { model.store.markSecret(item.id); model.refresh() } }
        Menu("Pin to") {
            ForEach(model.boards, id: \.self) { b in Button(b) { model.pin(item, to: b) } }
            if item.pinboard != nil { Divider(); Button("Unpin") { model.pin(item, to: nil) } }
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(item) }
    }

    var picksTab: some View {
        Button { model.picks = true; model.board = nil; model.refresh() } label: { Label("Picks", systemImage: "sparkles") }
            .buttonStyle(.plain).font(.callout.weight(model.picks ? .semibold : .regular))
            .capsuleChip(selected: model.picks)
            .accessibilityIdentifier("shelf.tab.Picks")
    }

    func tab(_ title: String, _ b: String?) -> some View {
        Button(title) { model.picks = false; model.board = b; model.refresh() }
            .buttonStyle(.plain).font(.callout.weight(!model.picks && model.board == b ? .semibold : .regular))
            .capsuleChip(selected: !model.picks && model.board == b)
            .accessibilityIdentifier("shelf.tab.\(title)")
    }

    func chip(_ title: String, _ k: ClipKind?) -> some View {
        Button(title) { model.kind = k }
            .buttonStyle(.plain).font(.callout)
            .capsuleChip(selected: model.kind == k, hPad: 10)
            .accessibilityIdentifier("shelf.chip.\(title)")
    }
}

/// A saved clip: a header in the source app's colour with the kind, age and app icon, the content, then a footer with
/// the details (size, length, host) and the ⌘ number that pastes it.
struct Card: View {
    let item: ClipItem
    var number: Int? = nil
    var selected = false

    var body: some View {
        let header = AppInfo.color(item.sourceBundleID)
        let ink = AppInfo.ink(on: header)
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                header
                VStack(alignment: .leading, spacing: 1) {
                    Text(kindTitle).font(.title3.weight(.semibold))
                    Text(Relative.string(from: item.createdAt)).font(.caption).opacity(0.82)
                }
                .foregroundStyle(ink).padding(.leading, 16).padding(.top, 12)
                HStack(spacing: 4) {
                    if item.pinboard != nil { Image(systemName: "pin.fill").font(.caption2) }
                    if item.isRich { Image(systemName: "textformat").font(.caption2).accessibilityLabel("Formatted") }
                }.foregroundStyle(ink).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 68).padding(.top, 16)
                if let b = item.sourceBundleID, let icon = AppInfo.icon(b) {
                    Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 12).padding(.top, 10)
                }
            }.frame(height: 64)
            content.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
            HStack {
                Spacer(minLength: 0)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .overlay(alignment: .trailing) {
                if let n = number {
                    Text("⌘\(n)").font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 10).frame(height: 34).background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        }
        .frame(width: ShelfView.cardSize.width, height: ShelfView.cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
        .padding(6)
        .overlay { if selected { RoundedRectangle(cornerRadius: 27, style: .continuous).strokeBorder(Palette.accent, lineWidth: 3) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kindTitle), \(item.isSecret ? "hidden secret" : item.title), \(item.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var kindTitle: String { item.isSecret ? "Secret" : item.kind.rawValue.capitalized }

    @ViewBuilder var content: some View {
        if item.isSecret {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "lock.fill").font(.title2)
                Text("••••••••••").foregroundStyle(.secondary)
            }
        } else if item.kind == .color, let t = item.text, let c = Color(hex: t) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c).frame(maxHeight: .infinity)
                .overlay(Text(t).font(.callout.monospaced()).padding(4).background(.thinMaterial, in: Capsule()))
        } else if item.kind == .image, let d = item.data, let img = NSImage(data: d) {
            Color.clear.overlay { Image(nsImage: img).resizable().scaledToFill() }
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if item.kind == .file {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "doc.fill").font(.title2).foregroundStyle(.secondary)
                Text(item.fileNames.joined(separator: "\n")).font(.callout).lineLimit(4)
            }
        } else if item.kind == .link {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "link").font(.title3).foregroundStyle(.secondary)
                Text(item.text ?? item.title).font(.callout).lineLimit(5)
            }
        } else {
            Text(item.text ?? item.title).font(.system(size: 14)).lineLimit(8)
        }
    }
}

enum Relative {
    static func string(from date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 15 { return "now" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}

/// App names, icons and header colours (the average colour of the app's icon) for source-app badges.
@MainActor
enum AppInfo {
    private static var icons: [String: NSImage?] = [:]
    private static var colors: [String: Color] = [:]
    static func url(_ bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static func name(_ bundleID: String) -> String {
        guard let u = url(bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }
    static func icon(_ bundleID: String) -> NSImage? {
        if let c = icons[bundleID] { return c }
        let img = url(bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleID] = img
        return img
    }

    /// Average of the icon's saturated, mid-brightness pixels; neutral grey when there is no icon or it is colourless.
    static func color(_ bundleID: String?) -> Color {
        guard let id = bundleID else { return Color(white: 0.45) }
        if let c = colors[id] { return c }
        let c = icon(id).flatMap(dominant) ?? Color(white: 0.45)
        colors[id] = c
        return c
    }

    static func dominant(_ image: NSImage) -> Color? {
        let n = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: n, height: n)); NSGraphicsContext.restoreGraphicsState()
        var r = 0.0, g = 0.0, b = 0.0, w = 0.0
        for y in 0..<n { for x in 0..<n {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.8 else { continue }
            let mx = max(c.redComponent, c.greenComponent, c.blueComponent), mn = min(c.redComponent, c.greenComponent, c.blueComponent)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            guard sat > 0.25, mx > 0.25, mx < 0.99 || sat > 0.5 else { continue }
            let weight = Double(sat)
            r += Double(c.redComponent) * weight; g += Double(c.greenComponent) * weight; b += Double(c.blueComponent) * weight; w += weight
        } }
        guard w > 0 else { return nil }
        // Darken a little so white header text stays readable on bright icons.
        return Color(.sRGB, red: r / w * 0.82, green: g / w * 0.82, blue: b / w * 0.82)
    }

    /// White or near-black, whichever reads better on the header colour.
    static func ink(on c: Color) -> Color {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        func lin(_ v: CGFloat) -> Double { let d = Double(v); return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4) }
        let L = 0.2126 * lin(ns.redComponent) + 0.7152 * lin(ns.greenComponent) + 0.0722 * lin(ns.blueComponent)
        let white = 1.05 / (L + 0.05), black = (L + 0.05) / 0.0575
        return white >= black ? .white : Color(red: 0.07, green: 0.07, blue: 0.07)
    }
}

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let a = h.count == 8 ? Double(v & 0xFF) / 255 : 1
        let rgb = h.count == 8 ? v >> 8 : v
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: a)
    }
}

/// The shelf floats over other apps, so it needs its own backdrop: system Liquid Glass, with a material before macOS 26.
struct ShelfBackdrop: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
        }
    }
}
