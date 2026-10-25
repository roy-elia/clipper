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
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
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
                        .buttonStyle(.plain).padding(6).background(.quaternary, in: Circle())
                        .accessibilityLabel("New pinboard").accessibilityIdentifier("shelf.addBoard")
                }
                Spacer()
                if !model.stack.isEmpty {
                    Label("\(model.stack.items.count) in stack", systemImage: "square.stack.3d.up")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                TextField("Search clips", text: $model.query)
                    .textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.quaternary, in: Capsule())
                    .focused($searchFocused)
                    .onSubmit { model.pickSelected(plain: false) }
                    .accessibilityIdentifier("shelf.search")
                chip("All", nil)
                ForEach(ClipKind.allCases, id: \.self) { chip($0.rawValue.capitalized, $0) }
                appMenu
            }
            if model.items.isEmpty {
                Text(model.picks ? "No suggestions yet" : model.board == nil ? "Nothing copied yet" : "Right-click a clip, then Pin to, to add it here")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                                Card(item: item, number: idx < 9 ? idx + 1 : nil, selected: idx == model.selection)
                                    .id(item.id)
                                    .onTapGesture { model.selection = idx; model.onPick?(item, false) }
                                    .contextMenu { menu(for: item) }
                                    .accessibilityIdentifier("shelf.card.\(item.id)")
                            }
                        }.padding(.vertical, 4)
                    }.frame(height: 142)
                    .onChange(of: model.selection) { if let i = model.selected { if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { proxy.scrollTo(i.id) } else { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { proxy.scrollTo(i.id) } } } }
                }
            }
        }
        .padding(14)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusTick) { searchFocused = true }
        .frame(width: 760, height: 252)
        .clipperStyle()
        .background { ShelfBackdrop() }
        .onChange(of: model.query) { model.refresh() }
        .onChange(of: model.kind) { model.refresh() }
        .onChange(of: model.board) { model.refresh() }
        .onChange(of: model.app) { model.refresh() }
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

struct Card: View {
    let item: ClipItem
    var number: Int? = nil
    var selected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let b = item.sourceBundleID, let icon = AppInfo.icon(b) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text(item.kind.rawValue.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if item.pinboard != nil { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint) }
                if item.isRich { Image(systemName: "textformat").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Formatted") }
            }
            content
            Spacer(minLength: 0)
            HStack {
                Text(item.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let n = number { Text("⌘\(n)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .padding(10).frame(width: 150, height: 130, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { if selected { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.lilac.opacity(0.35)) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder var content: some View {
        if item.isSecret {
            VStack(alignment: .leading, spacing: 4) {
                Label("Secret", systemImage: "lock.fill").font(.callout.weight(.semibold))
                Text("••••••••••").font(.callout).foregroundStyle(.secondary)
            }
        } else if item.kind == .color, let t = item.text, let c = Color(hex: t) {
            RoundedRectangle(cornerRadius: 8).fill(c).frame(height: 44).overlay(Text(t).font(.caption.monospaced()).padding(2).background(.thinMaterial, in: Capsule()))
        } else if item.kind == .image, let d = item.data, let img = NSImage(data: d) {
            Image(nsImage: img).resizable().scaledToFill().frame(height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
        } else if item.kind == .file {
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: "doc.fill").foregroundStyle(.secondary)
                Text(item.fileNames.joined(separator: "\n")).font(.callout).lineLimit(3)
            }
        } else {
            Text(item.text ?? item.title).font(.callout).lineLimit(4)
        }
    }
}

/// App names and icons for source-app badges and the filter menu.
@MainActor
enum AppInfo {
    private static var icons: [String: NSImage?] = [:]
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
