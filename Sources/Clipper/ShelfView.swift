import SwiftUI
import DropCore

@MainActor
final class ShelfModel: ObservableObject {
    @Published var query = ""
    @Published var kind: ClipKind?
    @Published var board: String?          // nil = History
    @Published var items: [ClipItem] = []
    @Published var boards: [String] = []
    @Published var stack = PasteStack()
    @Published var previewing: ClipItem?
    @Published var settings: AppSettings
    let store: HistoryStore
    var onPick: ((ClipItem) -> Void)?
    var onPreview: ((ClipItem) -> Void)?
    var onSettingsChanged: (() -> Void)?

    init(store: HistoryStore, settings: AppSettings = AppSettings()) {
        self.store = store; self.settings = settings; refresh()
    }

    func refresh() { items = store.search(query, kind: kind, pinboard: board); boards = store.pinboards() }

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

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
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
                    .accessibilityIdentifier("shelf.search")
                chip("All", nil)
                ForEach(ClipKind.allCases, id: \.self) { chip($0.rawValue.capitalized, $0) }
            }
            if model.items.isEmpty {
                Text(model.board == nil ? "Nothing copied yet" : "Right-click a clip, then Pin to, to add it here")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(model.items) { item in
                            Card(item: item)
                                .onTapGesture { model.onPick?(item) }
                                .contextMenu { menu(for: item) }
                                .accessibilityIdentifier("shelf.card.\(item.id)")
                        }
                    }.padding(.vertical, 4)
                }.frame(height: 142)
            }
        }
        .padding(14).frame(width: 760, height: 252)
        .onChange(of: model.query) { model.refresh() }
        .onChange(of: model.kind) { model.refresh() }
        .onChange(of: model.board) { model.refresh() }
    }

    @ViewBuilder func menu(for item: ClipItem) -> some View {
        Button("Paste") { model.onPick?(item) }
        Button("Preview") { model.onPreview?(item) }
        Button("Add to Paste Stack") { model.stack.push(item) }
        Menu("Pin to") {
            ForEach(model.boards, id: \.self) { b in Button(b) { model.pin(item, to: b) } }
            if item.pinboard != nil { Divider(); Button("Unpin") { model.pin(item, to: nil) } }
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(item) }
    }

    func tab(_ title: String, _ b: String?) -> some View {
        Button(title) { model.board = b }
            .buttonStyle(.plain).foregroundStyle(.primary).font(.callout.weight(model.board == b ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(model.board == b ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.quaternary), in: Capsule())
            .accessibilityIdentifier("shelf.tab.\(title)")
    }

    func chip(_ title: String, _ k: ClipKind?) -> some View {
        Button(title) { model.kind = k }
            .buttonStyle(.plain).foregroundStyle(.primary).font(.callout).padding(.horizontal, 10).padding(.vertical, 5)
            .background(model.kind == k ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.quaternary), in: Capsule())
            .accessibilityIdentifier("shelf.chip.\(title)")
    }
}

struct Card: View {
    let item: ClipItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.kind.rawValue.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if item.pinboard != nil { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint) }
            }
            content
            Spacer(minLength: 0)
            Text(item.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10).frame(width: 150, height: 130, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder var content: some View {
        if item.kind == .color, let t = item.text, let c = Color(hex: t) {
            RoundedRectangle(cornerRadius: 8).fill(c).frame(height: 44).overlay(Text(t).font(.caption.monospaced()).padding(2).background(.thinMaterial, in: Capsule()))
        } else if item.kind == .image, let d = item.data, let img = NSImage(data: d) {
            Image(nsImage: img).resizable().scaledToFill().frame(height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Text(item.text ?? item.title).font(.callout).lineLimit(4)
        }
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
