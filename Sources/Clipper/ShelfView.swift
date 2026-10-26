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
    var onCopy: ((ClipItem) -> Void)?
    var onEdit: ((ClipItem) -> Void)?
    var onRename: ((ClipItem) -> Void)?
    var onRenameBoard: ((String) -> Void)?
    var onCommand: ((ShelfCommand) -> Void)?
    @Published var modifierHeld = false     // quick-paste modifier is down: show the 1…9 badges
    @Published var isKey = true             // shelf has keyboard focus: selection ring in accent, else grey
    @Published var pausedUntil: String?     // menu text when capture is paused

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
    /// ⌘] and ⌘[ : step through Picks, History and the pinboards in tab order.
    func cycleBoard(_ d: Int) {
        let order: [String?] = [nil] + boards.map { Optional($0) }
        let current = order.firstIndex { $0 == board } ?? 0
        let tabs = order.count + 1                      // Picks is position 0
        let pos = picks ? 0 : current + 1
        let next = ((pos + d) % tabs + tabs) % tabs
        if next == 0 { picks = true; board = nil } else { picks = false; board = order[next - 1] }
        selection = 0; refresh()
    }
    func deleteSelected() { if let i = selected { delete(i) } }

    func pin(_ item: ClipItem, to name: String?) { store.setPinboard(name, for: item.id); refresh() }
    func delete(_ item: ClipItem) { store.delete(item.id); stack.remove(item.id); refresh() }
    func addBoard(_ name: String) { if store.createPinboard(name) { board = name.trimmingCharacters(in: .whitespaces); refresh() } }
    func renameBoard(_ old: String, _ new: String) { if store.renamePinboard(old, to: new) { board = new; refresh() } }
    func boardColor(_ name: String) -> Color { Color(hex: store.boardColor(name)) ?? .red }
    func deleteBoard(_ name: String) { store.deletePinboard(name); if board == name { board = nil }; refresh() }
    func updateSettings(_ f: (inout AppSettings) -> Void) { f(&settings); store.capacity = settings.historyCapacity; onSettingsChanged?() }
}

/// Commands from the shelf's ⋯ menu, handled by the app.
enum ShelfCommand { case about, newClip, settings, gettingStarted, shortcuts, pause(TimeInterval?), resume, clear, quit }

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @State private var newBoard = ""
    @State private var adding = false
    @State private var dropTargeted = false
    @State private var filtering = false
    @FocusState private var searchFocused: Bool

    static let cardSize = CGSize(width: 234, height: 234)
    static let height: CGFloat = 332

    var body: some View {
        VStack(spacing: 8) {
            bar
            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: dropTargeted ? "arrow.down.circle" : "tray").font(.title).foregroundStyle(.secondary)
                    Text(model.picks ? "No suggestions yet" : model.board == nil ? (model.query.isEmpty ? "Nothing copied yet. Drop images, files or text here to save them." : "No clips match") : "Right-click a clip, then Pin, to add it here")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 18) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                                Card(item: item, number: model.modifierHeld && idx < 9 ? idx + 1 : nil, selected: idx == model.selection, active: model.isKey,
                                     quickSymbol: model.settings.quickModifier.symbol)
                                    .id(item.id)
                                    .onTapGesture { model.selection = idx; model.onPick?(item, NSEvent.modifierFlags.contains(.shift)) }
                                    .onDrag { provider(for: item) }
                                    .contextMenu { menu(for: item) }
                                    .accessibilityIdentifier("shelf.card.\(item.id)")
                            }
                        }.padding(.vertical, 6).padding(.horizontal, 22)
                    }
                    .onChange(of: model.selection) { if let i = model.selected { if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { proxy.scrollTo(i.id) } else { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { proxy.scrollTo(i.id) } } } }
                }
            }
        }
        .padding(.top, 10).padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
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

    // MARK: control row

    var bar: some View {
        ZStack {
            HStack(spacing: 6) {
                iconButton(model.picks ? "sparkles" : "sparkles", label: "Suggestions", selected: model.picks) {
                    model.picks.toggle(); if model.picks { model.board = nil }; model.refresh()
                }.accessibilityIdentifier("shelf.tab.Picks")
                Spacer()
                if !model.stack.isEmpty {
                    Label("\(model.stack.items.count) in stack", systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary)
                }
                Text(model.items.count == 1 ? "1 clip" : "\(model.items.count) clips").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("shelf.count")
                iconButton("trash", label: "Clear history") { model.onClear?() }.accessibilityIdentifier("shelf.clear")
                moreMenu
            }
            HStack(spacing: 6) {
                searchField
                iconButton("line.3.horizontal.decrease", label: "Filter", selected: model.kind != nil || model.app != nil) { filtering.toggle() }
                    .accessibilityIdentifier("shelf.filter")
                    .popover(isPresented: $filtering, arrowEdge: .top) { FilterPopover(model: model) }
                tab("Clipboard", nil, symbol: "clock.arrow.circlepath")
                ForEach(model.boards, id: \.self) { b in
                    tab(b, b, dot: model.boardColor(b)).contextMenu {
                        Button("Rename…") { model.onRenameBoard?(b) }
                        Menu("Colour") {
                            ForEach(HistoryStore.boardPalette, id: \.self) { hex in
                                Button { model.store.setBoardColor(b, hex); model.refresh() } label: {
                                    Label(colorName(hex), systemImage: model.store.boardColor(b) == hex ? "checkmark.circle.fill" : "circle.fill")
                                }
                            }
                        }
                        Divider()
                        Button("Delete Pinboard", role: .destructive) { model.deleteBoard(b) }
                    }
                }
                if adding {
                    TextField("Name", text: $newBoard).textFieldStyle(.roundedBorder).frame(width: 110)
                        .accessibilityIdentifier("shelf.newBoardField")
                        .onSubmit { model.addBoard(newBoard); newBoard = ""; adding = false }
                } else {
                    iconButton("plus", label: "New pinboard") { adding = true }.accessibilityIdentifier("shelf.addBoard")
                }
            }
        }
        .padding(.horizontal, 18).frame(height: 36)
    }

    var searchField: some View {
        let open = searchFocused || !model.query.isEmpty
        return HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { model.pickSelected(plain: false) }
                .accessibilityIdentifier("shelf.search")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: open ? 200 : 110)
        .background(open ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
        .animation(.easeOut(duration: 0.15), value: open)
    }

    var moreMenu: some View {
        Menu {
            Button("About Clipper") { model.onCommand?(.about) }
            Divider()
            Button("New Clip…") { model.onCommand?(.newClip) }.keyboardShortcut("n")
            Button("Settings…") { model.onCommand?(.settings) }.keyboardShortcut(",")
            Menu("Help") {
                Button("Getting Started") { model.onCommand?(.gettingStarted) }
                Button("Keyboard Shortcuts") { model.onCommand?(.shortcuts) }
            }
            Divider()
            if let p = model.pausedUntil {
                Button("Resume Capture (\(p))") { model.onCommand?(.resume) }
            } else {
                Menu("Pause Capture") {
                    Button("Until I Resume") { model.onCommand?(.pause(nil)) }
                    Divider()
                    ForEach(CapturePause.durations, id: \.1) { d in Button("For \(d.0)") { model.onCommand?(.pause(d.1)) } }
                }
            }
            Button("Clear History…") { model.onCommand?(.clear) }
            Divider()
            Button("Quit Clipper") { model.onCommand?(.quit) }.keyboardShortcut("q")
        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More").accessibilityIdentifier("shelf.more")
    }

    func iconButton(_ symbol: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 28).contentShape(Circle()) }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? Palette.accent : Color.primary)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Circle())
            .help(label).accessibilityLabel(label)
    }

    func tab(_ title: String, _ b: String?, symbol: String? = nil, dot: Color? = nil) -> some View {
        let on = !model.picks && model.board == b
        return Button { model.picks = false; model.board = b; model.refresh() } label: {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
                Text(title)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(on ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).font(.callout.weight(on ? .semibold : .regular))
        .accessibilityIdentifier("shelf.tab.\(b == nil ? "History" : title)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func colorName(_ hex: String) -> String {
        ["#FF5F57": "Red", "#FFB340": "Orange", "#FFD84D": "Yellow", "#34C759": "Green", "#30B0C7": "Teal", "#3D7BFF": "Blue", "#AF52DE": "Purple", "#FF6FAF": "Pink"][hex] ?? hex
    }

    /// What leaves the shelf when a card is dragged: the image, the files, or the text.
    func provider(for item: ClipItem) -> NSItemProvider {
        if item.isSecret { return NSItemProvider() }
        if let urls = item.fileURLs, let u = urls.first.flatMap({ URL(string: $0) }) { return NSItemProvider(contentsOf: u) ?? NSItemProvider() }
        if let d = item.data, let img = NSImage(data: d) { return NSItemProvider(object: img) }
        return NSItemProvider(object: (item.text ?? item.title) as NSString)
    }

    func handleKey(_ p: KeyPress) -> KeyPress.Result {
        switch p.key {
        case .leftArrow where p.modifiers.contains(.command): model.cycleBoard(-1); return .handled
        case .rightArrow where p.modifiers.contains(.command): model.cycleBoard(1); return .handled
        case .leftArrow: model.move(-1); return .handled
        case .rightArrow: model.move(1); return .handled
        case .return: model.pickSelected(plain: p.modifiers.contains(.shift)); return .handled
        case .escape: model.onClose?(); return .handled
        default: return .ignored
        }
    }

    @ViewBuilder func menu(for item: ClipItem) -> some View {
        Button("Paste to \(model.targetApp.map(AppInfo.name) ?? "Front App")") { model.onPick?(item, false) }
        Button("Paste as Plain Text") { model.onPick?(item, true) }
        Button("Copy") { model.onCopy?(item) }
        Divider()
        if item.data == nil && item.fileURLs == nil && !item.isSecret { Button("Edit") { model.onEdit?(item) } }
        Button("Rename…") { model.onRename?(item) }
        Button("Duplicate") { model.store.duplicate(item.id); model.refresh() }
        Button("Delete", role: .destructive) { model.delete(item) }
        Divider()
        Menu("Pin") {
            ForEach(model.boards, id: \.self) { b in Button(b) { model.pin(item, to: b) } }
            if item.pinboard != nil { Divider(); Button("Unpin") { model.pin(item, to: nil) } }
        }
        Button("Add to Paste Stack") { model.stack.push(item) }
        if item.isSecret { Button("Not a Secret") { model.store.markSecret(item.id, false); model.refresh() } }
        else if item.kind == .text { Button("Mark as Secret") { model.store.markSecret(item.id); model.refresh() } }
        Divider()
        Button("Preview") { model.onPreview?(item) }
        if !item.isSecret { Button("Share…") { model.onShare?(item) } }
    }
}

/// Type, app and pinboard filters, shown from the filter button.
struct FilterPopover: View {
    @ObservedObject var model: ShelfModel
    let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Type")
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(ClipKind.allCases, id: \.self) { k in
                    chip(k.rawValue.capitalized, symbol: symbol(k), on: model.kind == k) { model.kind = model.kind == k ? nil : k }
                }
            }
            if !model.apps.isEmpty {
                section("App")
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(model.apps, id: \.self) { b in
                        chip(AppInfo.name(b), icon: AppInfo.icon(b), on: model.app == b) { model.app = model.app == b ? nil : b }
                    }
                }
            }
            if !model.boards.isEmpty {
                section("Pinboard")
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(model.boards, id: \.self) { b in
                        chip(b, dot: model.boardColor(b), on: model.board == b) { model.picks = false; model.board = model.board == b ? nil : b; model.refresh() }
                    }
                }
            }
            if model.kind != nil || model.app != nil {
                Button("Clear Filters") { model.kind = nil; model.app = nil }.buttonStyle(.link)
            }
        }
        .padding(14).frame(width: 440)
    }

    func section(_ t: String) -> some View { Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }

    func symbol(_ k: ClipKind) -> String {
        switch k { case .text: "text.alignleft"; case .link: "link"; case .image: "photo"; case .file: "doc"; case .color: "paintpalette"; default: "questionmark.square" }
    }

    func chip(_ title: String, symbol: String? = nil, icon: NSImage? = nil, dot: Color? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                if let icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(on ? Palette.inkOn : Color.primary)
            .background(on ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(.quaternary), in: Capsule())
            .contentShape(Capsule())
        }.buttonStyle(.plain)
        .accessibilityIdentifier("filter.\(title)")
    }
}

/// A saved clip: a header in the source app's colour with its name or kind, age and an oversized app icon cropped
/// by the header edge; the content (text fades out, images fill the card); and a centred detail at the bottom.
struct Card: View {
    let item: ClipItem
    var number: Int? = nil
    var selected = false
    var active = true
    var quickSymbol = "⌘"

    var body: some View {
        let header = AppInfo.color(item.sourceBundleID)
        let ink = AppInfo.ink(on: header)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                header
                if let b = item.sourceBundleID, let icon = AppInfo.icon(b) {
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                        .frame(maxWidth: .infinity, alignment: .trailing).offset(x: 8, y: -6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title).font(.headline).lineLimit(1)
                        if item.pinboard != nil { Image(systemName: "pin.fill").font(.caption2) }
                    }
                    Text(Relative.string(from: item.createdAt)).font(.caption).opacity(0.85)
                }
                .foregroundStyle(ink).padding(.leading, 14).padding(.top, 8).padding(.trailing, 60)
            }
            .frame(height: 48, alignment: .top).clipped()
            ZStack(alignment: .bottom) {
                content
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.62))
        }
        .frame(width: ShelfView.cardSize.width, height: ShelfView.cardSize.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(4)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(active ? Palette.accent : Color.secondary, lineWidth: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(item.isSecret ? "hidden secret" : item.title), \(item.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var title: String { item.customTitle ?? (item.isSecret ? "Secret" : item.kind.rawValue.capitalized) }
    var fullBleed: Bool { !item.isSecret && (item.kind == .image || item.kind == .color) }

    @ViewBuilder var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Text(item.detail).font(.caption).foregroundStyle(fullBleed ? Color.primary : Color.secondary).lineLimit(1)
                .padding(.horizontal, fullBleed ? 8 : 0).padding(.vertical, fullBleed ? 3 : 0)
                .background { if fullBleed { Capsule().fill(.ultraThinMaterial) } }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .trailing) {
            if let n = number {
                Text("\(quickSymbol)\(n)").font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2).background(.thinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 9)
    }

    @ViewBuilder var content: some View {
        if item.isSecret {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "lock.fill").font(.title2)
                Text("••••••••••").foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if item.kind == .color, let t = item.text, let c = Color(hex: t) {
            c.overlay(alignment: .center) { Text(t).font(.callout.monospaced()).padding(.horizontal, 8).padding(.vertical, 3).background(.thinMaterial, in: Capsule()).padding(.bottom, 24) }
        } else if item.kind == .image, let d = item.data, let img = NSImage(data: d) {
            Checkerboard().overlay { Image(nsImage: img).resizable().scaledToFit() }.clipped()
        } else if item.kind == .file {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "doc.fill").font(.title2).foregroundStyle(.secondary)
                Text(item.fileNames.joined(separator: "\n")).font(.callout).lineLimit(5)
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if item.kind == .link {
            VStack(alignment: .leading, spacing: 4) {
                if let t = item.extras?["linkTitle"].flatMap({ String(data: $0, encoding: .utf8) }) {
                    Text(t).font(.callout.weight(.semibold)).lineLimit(3)
                    Text(item.text ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Text(item.text ?? item.title).font(.callout).lineLimit(5)
                }
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text(item.text ?? item.title).font(.system(size: 14)).lineSpacing(1)
                .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.62), .init(color: .clear, location: 0.86)], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// Grey checks behind images so transparent areas read as transparent.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.14)))
                }
            }
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
